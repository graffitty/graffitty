extends SceneTree
## Render thin strokes against transparency; blur must spread coverage in both
## axes without the sharp silhouettes or square holes of depth-edge rejection.
var failures := 0

class AllocationFailureLens extends "res://scenes/InkDepthOfField.gd":
	var clock_msec := 0
	var failure := ""
	var attempts := Vector3i.ZERO # textures, pipelines, samplers
	var allocated_targets: Array[RID] = []
	func _monotonic_msec() -> int:
		return clock_msec
	func _create_target(format: RDTextureFormat) -> RID:
		attempts.x += 1
		# Fail the third image so both earlier allocations need cleanup.
		if failure == "texture" and footprints.size() == 1: return RID()
		var result := super._create_target(format)
		allocated_targets.append(result)
		return result
	func _create_pipeline() -> RID:
		attempts.y += 1
		return RID() if failure == "pipeline" else super._create_pipeline()
	func _create_sampler() -> RID:
		attempts.z += 1
		return RID() if failure == "sampler" else super._create_sampler()
	func failed_resources_released() -> bool:
		if temporary.is_valid() or not footprints.is_empty() or texture_size != Vector2i.ZERO:
			return false
		for target in allocated_targets:
			if rd.texture_is_valid(target): return false
		return failure == "texture" or (not shader.is_valid() and not pipeline.is_valid() and not sampler.is_valid())
	func exercise_retries(kind: String) -> Array:
		# Called only on the render thread. Simulated frame calls use the real RD
		# and production resource path, without waiting seconds for each deadline.
		failure = kind
		var result := []
		var bounded := true
		var released := true
		var retried := true
		var size := Vector2i(384, 384)
		for delay: int in [250, 500, 1000, 2000, 4000, 4000]:
			var before := attempts
			var ready := _prepare_resources(size)
			retried = retried and not ready and attempts != before
			released = released and failed_resources_released()
			before = attempts
			clock_msec += delay - 1
			for i in 120:
				ready = _prepare_resources(size)
				bounded = bounded and not ready and attempts == before
			clock_msec += 1
		result.append([retried, "%s retries at every backoff deadline, including the 4 s cap" % kind])
		result.append([bounded, "%s makes no extra attempts in 120 calls before each deadline" % kind])
		result.append([released, "%s releases partial resources after every failure" % kind])
		# Only cheaper texture requests may retry before the old deadline.
		# The preceding loop is now exactly at the last deadline; schedule one
		# more failure and change size without advancing the clock.
		_prepare_resources(size)
		var before := attempts
		var growth_bounded := true
		for i in range(1, 121):
			var growing := _prepare_resources(Vector2i(size.x + i, size.y + i))
			growth_bounded = growth_bounded and not growing and attempts == before
		var swapped := _prepare_resources(Vector2i(512, 288))
		result.append([growth_bounded and not swapped and attempts == before, "%s keeps cooldown through 120 growing sizes and an equal-area reshape" % kind])
		var ready := _prepare_resources(Vector2i(256, 256))
		var texture_failure := kind == "texture"
		result.append([not ready and (attempts != before if texture_failure else attempts == before) and failed_resources_released(),
			"texture retries a smaller pixel budget immediately" if texture_failure else "%s retains cooldown even when the size shrinks" % kind])
		before = attempts
		failure = ""
		var cooldown := 250 if texture_failure else 4000
		clock_msec += cooldown - 1
		ready = _prepare_resources(Vector2i(256, 256))
		result.append([not ready and attempts == before, "%s respects cooldown when the fault clears" % kind])
		clock_msec += 1
		ready = _prepare_resources(Vector2i(256, 256))
		result.append([ready and texture_size == Vector2i(256, 256) and footprints.size() == 2, "%s recovers after its %d ms cooldown" % [kind, cooldown]])
		before = attempts
		for i in 120:
			ready = _prepare_resources(Vector2i(256, 256))
		result.append([ready and attempts == before, "%s reuses initialized resources after recovery" % kind])
		# Successful recovery also resets the next allocation failure's delay.
		# Keep the requested size so this cannot pass via the resize reset.
		_release_targets()
		failure = "texture"
		ready = _prepare_resources(Vector2i(256, 256))
		result.append([not ready and failed_resources_released(), "%s releases targets when a later allocation fails" % kind])
		failure = ""
		clock_msec += 250
		ready = _prepare_resources(Vector2i(256, 256))
		result.append([ready and texture_size == Vector2i(256, 256), "%s resets backoff after successful recovery" % kind])
		_prepare_resources(size)
		return result

# Main-thread test orchestration never reads or mutates render-owned state.
func render_action(action: Callable) -> Variant:
	var result := {}
	RenderingServer.call_on_render_thread(func():
		finish_render_action.call_deferred(result, action.call()))
	while not result.has("value"): await process_frame
	return result.value
func finish_render_action(result: Dictionary, value: Variant) -> void:
	result.value = value

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()
func frame(view: SubViewport) -> Image:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()
func coverage(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width(): total += image.get_pixel(x, y).a
	return total
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func run() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(256, 256)
	view.transparent_bg = true
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var display := TextureRect.new()
	display.texture = view.get_texture()
	root.add_child(display)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_CLEAR_COLOR
	camera.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	view.add_child(camera)
	var texture := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	texture.fill(Color.TRANSPARENT)
	texture.fill_rect(Rect2i(124, 100, 8, 56), Color.WHITE)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(4, 4)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always; uniform sampler2D source; void fragment() { vec4 c=texture(source,UV); if(c.a<.001)discard; ALBEDO=c.rgb; ALPHA=c.a; }"
	material.set_shader_parameter("source", ImageTexture.create_from_image(texture))
	quad.material_override = material
	quad.position.z = -2
	view.add_child(quad)
	var sharp := await frame(view)
	var lens := preload("res://scenes/InkDepthOfField.gd").new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [lens]
	lens.set_lens(1, 12, .5, 24)
	var blurred := await frame(view)
	check(sharp.get_pixel(120, 128).a < .001 and blurred.get_pixel(120, 128).a > .02, "Defocus spreads stroke coverage into transparent horizontal pixels")
	check(sharp.get_pixel(128, 96).a < .001 and blurred.get_pixel(128, 96).a > .01, "Defocus spreads stroke coverage into transparent vertical pixels")
	check(blurred.get_pixel(120, 96).a > .001, "Vertical blur carries horizontal coverage into rounded corners")
	check(blurred.get_pixel(124, 128).a < .8, "The original stroke edge is softened, not retained as a sharp silhouette")
	var ratio := coverage(blurred) / coverage(sharp)
	check(absf(ratio - 1.0) < .03, "Normalized blur preserves thin-stroke coverage: %.4f" % ratio)
	for kind: String in ["texture", "pipeline", "sampler"]:
		var retry_lens := AllocationFailureLens.new()
		retry_lens.set_lens(1, 12, .5, 24)
		var results: Array = await render_action(retry_lens.exercise_retries.bind(kind))
		for result: Array in results: check(result[0], result[1])
		view.size = Vector2i(384, 384)
		camera.compositor.compositor_effects = [retry_lens]
		var resized := await frame(view)
		check(resized.get_pixel(182, 192).a > .01, "%s recovery resumes visible blur at the same size" % kind)
		# Exercise failure through the actual compositor callback as well.
		await render_action(func(): retry_lens.failure = "texture")
		view.size = Vector2i(320, 320)
		var unblurred := await frame(view)
		var before: Vector3i = await render_action(func(): return retry_lens.attempts)
		await frame(view)
		var after: Vector3i = await render_action(func(): return retry_lens.attempts)
		check(before == after and unblurred.get_pixel(150, 160).a < .001 and unblurred.get_pixel(160, 160).a > .95, "%s failed resize leaves the core render visible without per-frame retries" % kind)
		await render_action(func(): retry_lens.failure = "")
		view.size = Vector2i(256, 256)
		var smaller := await frame(view)
		check(smaller.get_pixel(120, 128).a > .02, "%s new smaller size recovers visibly before the old cooldown expires" % kind)
	camera.compositor.compositor_effects = [lens]
	view.size = Vector2i(256, 256)
	await frame(view)
	# On this plane the normalized depth offset is one. A uniform floor must
	# produce the same kernel, both exactly on a band and between bands.
	for radius: float in [6.0, 4.5]:
		lens.set_lens(1, radius, .5, 24)
		var variable := await frame(view)
		lens.set_lens(1, 0, .5, 24, radius)
		var uniform := await frame(view)
		var error := 0.0
		for y in range(88, 168):
			for x in range(112, 144):
				error = maxf(error, absf(variable.get_pixel(x, y).a - uniform.get_pixel(x, y).a))
		check(error < .002, "Uniform %.1f px arrival matches the depth kernel (max alpha error %.4f)" % [radius, error])
	lens.set_lens(2, 12, .5, 24)
	var focused := await frame(view)
	check(absf(coverage(focused) / coverage(sharp) - 1.0) < .01 and focused.get_pixel(120, 128).a < .001, "In-focus strokes retain their original footprint")
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not evidence.is_empty():
		sharp.save_png(evidence.path_join("sharp.png"))
		blurred.save_png(evidence.path_join("blurred.png"))
	# A focused stroke overlapping a defocused one must not collapse the vertical
	# footprint at its center into a cross-shaped streak.
	#
	# At (127,96), a normalized radius-12 2D convolution of the six unoccluded
	# columns gives alpha 0.09995; the focused line contributes zero.
	var narrow := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	narrow.fill(Color.TRANSPARENT)
	narrow.fill_rect(Rect2i(127, 100, 2, 56), Color.WHITE)
	var foreground := MeshInstance3D.new()
	foreground.mesh = quad.mesh
	foreground.material_override = material.duplicate()
	foreground.material_override.set_shader_parameter("source", ImageTexture.create_from_image(narrow))
	foreground.position.z = -1
	view.add_child(foreground)
	lens.set_lens(1, 12, .5, 24)
	var mixed := await frame(view)
	if not evidence.is_empty(): mixed.save_png(evidence.path_join("mixed.png"))
	check(absf(mixed.get_pixel(127, 96).a - .09995) < .01, "Mixed depths retain the expected two-dimensional blur coverage")
	# Adjacent release cohorts are only a few percent apart in depth while
	# still reading as a sheet. Their visible blur should agree at that point.
	foreground.visible = false
	quad.position.x = -.5
	var cohort := MeshInstance3D.new()
	cohort.mesh = quad.mesh
	cohort.material_override = material
	cohort.position = Vector3(.5, 0, -1.94)
	view.add_child(cohort)
	var transition := preload("res://scenes/TransitionInk.gd")
	check(transition.departure_lens(.0263, 8, 0).is_equal_approx(Vector2(.0263, 0)), "Departure starts with the exact captured lens")
	var optics := transition.departure_lens(.0263, 8, .08)
	lens.set_lens(2, 8, optics.x, 24, optics.y)
	var cohorts := await frame(view)
	var difference := 0.0
	for y in range(85, 171):
		for x in range(80, 112):
			difference = maxf(difference, absf(cohorts.get_pixel(x, y).a - cohorts.get_pixel(x + 64, y).a))
	check(difference < .015, "Nearby departure cohorts have coherent blur: %.4f" % difference)
	if not evidence.is_empty(): cohorts.save_png(evidence.path_join("cohorts.png"))
	await check_composition()
	view.queue_free()
	for i in 3: await process_frame
	quit(1 if failures else 0)

func solid(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func check_composition() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(16, 16)
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var display := TextureRect.new()
	display.texture = view.get_texture()
	root.add_child(display)
	var ink := TextureRect.new()
	ink.texture = solid(Color.BLUE)
	ink.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ink.size = Vector2(16, 16)
	ink.material = ShaderMaterial.new()
	ink.material.shader = preload("res://scenes/terminal_ink_composite.gdshader")
	ink.material.set_shader_parameter("scenery_texture", solid(Color.BLACK))
	ink.material.set_shader_parameter("transition_0", solid(Color.RED))
	ink.material.set_shader_parameter("transition_count", 1)
	view.add_child(ink)
	var behind := await frame(view)
	check(behind.get_pixel(8, 8).b > .95, "Arriving retained layer stays behind the live pane")
	ink.material.set_shader_parameter("transition_1", solid(Color.GREEN))
	ink.material.set_shader_parameter("transition_count", 2)
	ink.material.set_shader_parameter("transition_foreground_mask", 2)
	var front := await frame(view)
	check(front.get_pixel(8, 8).g > .95 and front.get_pixel(8, 8).b < .01, "Isolated departing fragments remain in front of the arriving/live pane")
	view.queue_free()
	display.queue_free()
