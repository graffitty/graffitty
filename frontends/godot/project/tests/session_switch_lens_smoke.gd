extends "res://tests/session_effects_smoke.gd"
## Compare idle and mid-keystroke switches through the actual Forward+ cameras.
## Run with tests/godot/test_session_effects.py --case switch-lens.

var world: Node

func type_into_terminal() -> void:
	world.term.grab_focus()
	for i in 14:
		var key := InputEventKey.new()
		key.keycode = KEY_X
		key.unicode = 120
		key.pressed = true
		root.push_input(key, true)
		key = key.duplicate()
		key.pressed = false
		root.push_input(key, true)
		await create_timer(0.05).timeout

## Repeated strokes give the focal and far regions comparable spatial detail.
func paint_rows() -> void:
	var row := "M".repeat(40)
	var command := "printf '\\033[2J\\033[H'; i=0; while [ $i -lt 10 ]; do echo %s; i=$((i+1)); done; read -r line" % row
	if OS.get_name() == "Windows":
		command = "Clear-Host; 1..10 | ForEach-Object { [Console]::WriteLine('%s') }; [Console]::ReadLine()" % row
	client.connection.send_input(client.host.active_session_id, PackedByteArray([3]))
	client.connection.send_input(client.host.active_session_id, (command + "\r").to_utf8_buffer())
	check(await until(func(): return world.term.get_text(false).get("text", "").count(row) >= 10), "Painted the stroke chart")
	await create_timer(0.15).timeout

func radius_at(lens: Vector4, floor_px: float, depth: float) -> float:
	return minf(lens.w, maxf(floor_px, absf(1.0 - lens.x / depth) * lens.y / lens.z))

## Pick two visible text patches from the last live frame by optical depth.
func chart_regions(lens: Vector4) -> Array:
	var near := {}
	var far := {}
	var size: Vector2i = world.ink_vp.size
	for row in range(1, 10):
		for col in range(3, 38, 3):
			var uv := Vector2(col + 0.5, row + 0.5) / Vector2(world.term.get_grid_size())
			var point: Vector3 = world._effect_surface_frame(world.terminal_effects.to_sheet_uv(uv)).origin
			var center: Vector2 = world.ink_cam.unproject_position(point)
			var rect := Rect2i(Vector2i(center) - Vector2i(96, 64), Vector2i(192, 128))
			if not Rect2i(Vector2i.ZERO, size - Vector2i.ONE).encloses(rect): continue
			var depth: float = (point - world.ink_cam.global_position).dot(-world.ink_cam.global_basis.z)
			var radius := radius_at(lens, 0.0, depth)
			var patch := {"rect": rect, "depth": depth, "radius": radius}
			if near.is_empty() or radius < near.radius: near = patch
			if far.is_empty() or radius > far.radius: far = patch
	return [near, far]

## Normalized gradient energy over identical ink-target pixels. Blurring a
## stroke reduces its edge energy. Normalize by the amount of edge in the patch.
func sharpness(image: Image, rect: Rect2i) -> float:
	var edge := 0.0
	var variation := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := image.get_pixel(x, y).r
			var dx := c - image.get_pixel(x + 1, y).r
			var dy := c - image.get_pixel(x, y + 1).r
			edge += dx * dx + dy * dy
			variation += absf(dx) + absf(dy)
	return edge / maxf(variation, 0.000001)

func read_patches(view: SubViewport, regions: Array) -> Vector2:
	var image := view.get_texture().get_image()
	return Vector2(sharpness(image, regions[0].rect), sharpness(image, regions[1].rect))

func measure_switch(destination: String, typing: bool) -> void:
	var reference := {"lens": Vector4.ZERO, "regions": [], "pixels": Vector2.ZERO}
	var samples: Array = []
	var pixels := {}
	var seen := {"preparing": false, "flying": false, "outgoing": false, "incoming": false}
	var peaks := {"other": 0.0, "floor_error": 0.0, "arrival": 0.0}
	var observe := func():
		var live: CompositorEffect = world.ink_dof
		if world.session_transition_capture.is_empty() and world.tab_fx_wall == null and world.tab_fx_stale.is_empty():
			if samples.is_empty():
				reference.lens = live.lens
				if typing:
					reference.regions = chart_regions(live.lens)
					reference.pixels = read_patches(world.ink_vp, reference.regions)
			return
		var outgoing := live
		var view: SubViewport = world.ink_vp
		var binding: bool = not world.session_transition_capture.is_empty()
		seen.preparing = seen.preparing or world.tab_fx_preparing
		seen.flying = seen.flying or world.tab_fx_t > 0.0
		if not binding: peaks.other = maxf(peaks.other, live.lens.y)
		var native: Array = world.cam.attributes.get_meta("presentation_dof", [])
		if not native.is_empty() and (native[0] or native[3]):
			peaks.other = maxf(peaks.other, float(native[6]) * 64.0)
		for id in world.transition_ink.passes:
			var pass_data: Dictionary = world.transition_ink.passes[id]
			var lens: CompositorEffect = pass_data.lens
			if not world.tab_fx_out.is_empty() and id == world.tab_fx_out[0].get_instance_id():
				outgoing = lens
				view = pass_data.view
				seen.outgoing = true
			else:
				peaks.other = maxf(peaks.other, lens.lens.y)
			var expected_floor := 0.0
			if not world.tab_fx_in.is_empty() and id == world.tab_fx_in[0].get_instance_id():
				seen.incoming = true
				var layer: Node = world.tab_fx_in[0]
				if layer.get_meta("depth_mode", false):
					expected_floor = 6.0 * float(layer._material().get_shader_parameter("fly"))
					peaks.arrival = maxf(peaks.arrival, lens.minimum_radius)
			peaks.floor_error = maxf(peaks.floor_error, absf(lens.minimum_radius - expected_floor))
		if binding or not world.tab_fx_out.is_empty():
			var t := maxf(world.tab_fx_t, 0.0)
			samples.append({"t": t, "duration": world.tab_fx_dur, "lens": outgoing.lens, "floor": outgoing.minimum_radius})
			var stage := "binding" if binding else "retained"
			if typing and t == 0.0 and not pixels.has(stage):
				pixels[stage] = read_patches(view, reference.regions)
	RenderingServer.frame_post_draw.connect(observe)
	await RenderingServer.frame_post_draw
	var result: Dictionary = await client.connection.request_action("session_switch", {"name": destination})
	check(result.get("type") != "error", "Session switch accepted")
	check(await until(func(): return seen.flying and world.tab_fx_wall == null and world.tab_fx_stale.is_empty()), "Session flight and retirement complete")
	RenderingServer.frame_post_draw.disconnect(observe)
	check(not seen.values().has(false), "Observed preparation, flight and both retained cameras")
	check(peaks.other < 0.001, "No typing aperture on other flight cameras (%.3f px)" % peaks.other)
	check(peaks.floor_error < 0.001, "No added floor on focused glyphs (maximum floor error %.3f px)" % peaks.floor_error)
	if world.fly_away_effect():
		check(is_equal_approx(peaks.arrival, 6.0), "Fly Away retains its 0–6 px phase-driven arrival")
	if typing:
		check_handoff(reference, pixels, samples)
	else:
		check(samples.all(func(s): return is_zero_approx(s.lens.y)), "Idle scatter uses no typing blur")
	var cursor_world: Vector3 = world._effect_surface_frame(world.terminal_effects.to_sheet_uv(world.fx_cursor)).origin
	var cursor_depth := maxf((cursor_world - world.cam.global_position).dot(-world.cam.global_basis.z), 0.051)
	check(is_equal_approx(world.terminal_effects.focus_depth, cursor_depth), "Destination cursor is focused after handoff")

func check_handoff(reference: Dictionary, pixels: Dictionary, samples: Array) -> void:
	check(pixels.has("retained"), "Sampled the first retained frame")
	var regions: Array = reference.regions
	check(regions[0].radius < 1.0 and regions[1].radius > 3.0, "Chart spans focal and far glyphs (%.2f, %.2f px)" % [regions[0].radius, regions[1].radius])
	for stage in pixels:
		var ratio: Vector2 = pixels[stage] / reference.pixels
		check(absf(ratio.x - 1.0) < 0.05 and absf(ratio.y - 1.0) < 0.05, "%s focal/far stroke sharpness ratios %s" % [stage, ratio])
	var boundary_error := 0.0
	var focal_blur := 0.0
	var increasing := false
	var too_fast := false
	var intermediate := false
	var filtering_late := false
	var last: Vector4 = reference.lens
	var last_t := 0.0
	var last_far: float = regions[1].radius
	for sample in samples:
		var lens: Vector4 = sample.lens
		var far := radius_at(lens, sample.floor, regions[1].depth)
		if sample.t >= sample.duration * 0.75 and lens.y > 0.0: filtering_late = true
		focal_blur = maxf(focal_blur, radius_at(lens, sample.floor, reference.lens.x))
		if sample.t == 0.0:
			boundary_error = maxf(boundary_error, absf(lens.y - reference.lens.y))
			for region in regions:
				boundary_error = maxf(boundary_error, absf(radius_at(lens, sample.floor, region.depth) - region.radius))
		increasing = increasing or far > last_far + 0.02 or lens.y > last.y + 0.02
		# Allow dropped draws, but bound the change by elapsed flight time.
		# A shorter switch can close its aperture by mid-flight.
		var max_rate := maxf(5.0, 3.1 / sample.duration)
		too_fast = too_fast or (last.y - lens.y) > reference.lens.y * max_rate * (sample.t - last_t) + 0.05
		intermediate = intermediate or (lens.y > reference.lens.y * 0.15 and lens.y < reference.lens.y * 0.85)
		last = lens
		last_t = sample.t
		last_far = far
	check(boundary_error < 0.15, "Aperture and focal/far radii match the last typing frame throughout preparation (max %.3f px)" % boundary_error)
	check(not filtering_late, "Closed departure skips the GPU filter for the rest of the flight")
	check(focal_blur < 0.15, "No extra blur at the captured focal depth during departure (max %.3f px)" % focal_blur)
	check(not increasing and not too_fast and intermediate and last.y == 0.0, "Departure eases monotonically through intermediate apertures to idle, with bounded change per second")

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		quit(2)
		return
	root.size = Vector2i(1680, 1050)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-3d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Flat 3D fixture attaches")
		quit(1)
		return
	world = client.host.world
	if world.ink_dof == null:
		check(false, "Switch lens test requires Forward+")
		quit(1)
		return
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "typing")
	var typing := "state." + str(world.fx_cfg.behavior.active_state)
	world.fx_cfg.set_option(typing, "camera.zoom", 1.8)
	world.fx_cfg.set_option(typing, "camera.tilt_limit_deg", 18.0)
	world.fx_cfg.set_option(typing, "typing.particles", "none")
	for effect in ["fly_away_and_in", "fly_away"]:
		print("Testing ", effect)
		client.host.set_session_transition_effect(effect)
		await create_timer(0.4).timeout
		await measure_switch("beta", false)
		await paint_rows()
		await type_into_terminal()
		check(world.fx_cam_zoom > 1.1 and world.fx_cam_tilt.length() > 0.01 and world.ink_dof.lens.y > 1.0,
			"Live keystrokes activate tilt, zoom and depth of field before " + effect)
		await measure_switch("alpha", true)
	await type_into_terminal()
	check(world.ink_dof.lens.y > 1.0, "Fresh input enables typing depth of field after landing")
	client.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
