extends SceneTree
## Flying ink must stay visible over its own backing and neighbouring panes.
const Pieces := preload("res://scenes/CellShatter.gd")
const Transition2D := preload("res://scenes/TabTransition2D.gd")
const Overlay := preload("res://scenes/FlightOverlay3D.gd")
var failures: Array[String] = []

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures.append(label)

func viewport(is_3d: bool) -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(256, 256)
	view.disable_3d = not is_3d
	view.own_world_3d = is_3d
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	return view

func solid_source(color: Color) -> SubViewport:
	var view := viewport(false)
	var fill := ColorRect.new()
	fill.size = Vector2(view.size)
	fill.color = color
	view.add_child(fill)
	return view

func ink_pixels(view: SubViewport, label: String) -> int:
	for _frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var shot := view.get_texture().get_image()
	var output := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not output.is_empty(): shot.save_png(output.path_join(label + ".png"))
	var count := 0
	for y in shot.get_height():
		for x in shot.get_width():
			var pixel := shot.get_pixel(x, y)
			# The red backing has no green; fading ink mixes into yellow.
			if pixel.g > .25: count += 1
	return count

func run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	var green := solid_source(Color.GREEN)
	var red := solid_source(Color.RED)
	var view := viewport(true)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 5.0
	view.add_child(camera)
	var ink := Pieces.new()
	view.add_child(ink)
	var whole := Rect2(0, 0, 256, 256)
	ink.build_regions(green, [whole], whole, Vector3(-.2, .2, 0), Vector3(.4, 0, 0), Vector3(0, -.4, 0), Vector2.ZERO, 0)
	ink.set_progress(1.0)
	ink.set_appearance(1.0, 1.0)
	ink.set_meta("glyph_layer", true)
	var material: ShaderMaterial = ink._material()
	material.render_priority = 3
	material.set_shader_parameter("grouped_flight", true)
	material.set_shader_parameter("group_motion", Vector4(.3, .2, 0, 0))
	material.set_shader_parameter("group_float", Vector2.ZERO)
	# A corner of the sheet is in the first release cohort, so it is already
	# flying at every sampled phase. The default whole-sheet rect is the centre,
	# which is released last and still rests behind the later pane at 0.15.
	material.set_shader_parameter("source_sheet_rect", Vector4(0, 0, .1, .1))
	material.set_shader_parameter("group_travel_du", Vector3(1, 0, 0))
	material.set_shader_parameter("group_travel_dv", Vector3(0, -1, 0))
	var backing := Pieces.new()
	view.add_child(backing)
	# A later pane is deliberately closer and fully covers the source glyph.
	backing.build_regions(red, [whole], whole, Vector3(-1, 1, .2), Vector3(2, 0, 0), Vector3(0, -2, 0), Vector2.ZERO, 0)
	backing.set_progress(1.0)
	backing.set_appearance(1.0, 1.0)
	backing._material().render_priority = 4
	for phase in [0.0, .3, .15, 0.0]:
		ink.set_fly(Vector3(0, 0, 5), phase)
		var pixels := await ink_pixels(view, "3d-phase-%s" % phase)
		check(pixels > 100 if phase > 0.0 else pixels == 0, "3D flying ink clears pane depth; rest restores stacking at %s: %d pixels" % [phase, pixels])
	# Flat 2D: resting ink is a 2D panel in its own pane, under later panes;
	# flying ink is in the 3D overlay, over every pane.
	var flat := viewport(false)
	var transition := Transition2D.new()
	flat.add_child(transition)
	var clip := Control.new()
	clip.size = Vector2(flat.size)
	flat.add_child(clip)
	var overlay := Overlay.new(clip)
	flat.add_child(overlay)
	transition.overlay = overlay
	var group := Node2D.new()
	group.position = Vector2(128, 128)
	transition.add_child(group)
	var local := Rect2(-20, -20, 40, 40)
	var piece := Pieces.new()
	overlay.acquire().add_child(piece)
	var map := overlay.frame(group, local)
	piece.build_regions(green, [whole], whole, map[0], map[1], map[2], Vector2.ZERO, 0)
	piece.set_progress(1.0)
	piece.set_appearance(1.0, 1.0)
	piece.set_meta("glyph_layer", true)
	piece.set_meta("anchor", group)
	piece.set_meta("local_rect", local)
	for parameter in ["grouped_flight", "retire_flight_pieces"]: piece._material().set_shader_parameter(parameter, true)
	piece._material().set_shader_parameter("group_motion", Vector4(.3, .2, 0, 0))
	piece._material().set_shader_parameter("source_sheet_rect", Vector4(0, 0, .1, .1))
	piece._material().set_shader_parameter("group_travel_du", map[1] * 6.0)
	piece._material().set_shader_parameter("group_travel_dv", map[2] * 6.0)
	transition.glyphs.append(piece)
	transition.panel(green.get_texture(), local, group)
	transition.rest_ink.append(transition.panels.back())
	var cover := Sprite2D.new()
	cover.texture = red.get_texture()
	cover.position = Vector2(128, 128)
	transition.add_child(cover)
	for phase in [0.0, .3, .15, 0.0]:
		transition.set_progress(phase)
		var pixels := await ink_pixels(flat, "2d-phase-%s" % phase)
		check(pixels > 100 if phase > 0.0 else pixels == 0, "2D flying ink clears later panes; rest restores stacking at %s: %d pixels" % [phase, pixels])
	# The overlay composites premultiplied ink exactly once: a translucent
	# source looks the same as a resting 2D panel and as a flying 3D piece.
	cover.hide()
	var glass := solid_source(Color(0.9, 0.6, 0.3, 0.5))
	piece._material().set_shader_parameter("terminal_tex", glass.get_texture())
	transition.rest_ink[0].texture = glass.get_texture()
	# The sheet centre releases last, so this piece is still assembled.
	piece._material().set_shader_parameter("source_sheet_rect", Vector4(.45, .45, .1, .1))
	var colors: Array[Color] = []
	for phase in [0.0, 0.0005]:
		transition.set_progress(phase)
		await ink_pixels(flat, "2d-translucent-%s" % phase)
		colors.append(flat.get_texture().get_image().get_pixel(128, 128))
	var error := maxf(absf(colors[0].r - colors[1].r), maxf(absf(colors[0].g - colors[1].g), absf(colors[0].b - colors[1].b)))
	check(error < 0.03 and absf(colors[0].a - colors[1].a) < 0.03, "Overlay ink matches its 2D panel: %s vs %s" % [colors[0], colors[1]])
	print("SCATTER_VISIBILITY_PASS" if failures.is_empty() else "SCATTER_VISIBILITY_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
