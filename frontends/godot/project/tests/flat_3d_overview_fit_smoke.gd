extends "res://tests/session_effects_smoke.gd"
## Run with tests/godot/test_session_effects.py --case overview-fit.

class CullerLog extends Logger:
	var errors := 0

	func _log_error(_function: String, file: String, _line: int, _code: String, _rationale: String,
			_notify: bool, _kind: int, _traces: Array[ScriptBacktrace]) -> void:
		if file.ends_with("rendering_light_culler.cpp"):
			errors += 1

var culler_log := CullerLog.new()
var invalid_camera := ""

func _initialize() -> void:
	OS.add_logger(culler_log)
	super()

func valid_frustum(camera: Camera3D) -> bool:
	var pixels := camera.get_viewport().get_texture().get_size()
	if camera.projection != Camera3D.PROJECTION_FRUSTUM or not (camera.size > 0 and pixels.x > 0 and pixels.y > 0):
		return false
	if not (camera.near > 0 and camera.far > camera.near and camera.frustum_offset.is_finite()):
		return false
	# The renderer uses the horizontal frustum size set by CameraMotion.
	# Camera3D.get_frustum() omits the RenderingServer aspect override.
	var projection := Projection.create_frustum_aspect(camera.size, pixels.aspect(), camera.frustum_offset,
		camera.near, camera.far, true)
	for z in [Projection.PLANE_NEAR, Projection.PLANE_FAR]:
		for x in [Projection.PLANE_LEFT, Projection.PLANE_RIGHT]:
			for y in [Projection.PLANE_TOP, Projection.PLANE_BOTTOM]:
				var corner = projection.get_projection_plane(z).intersect_3(
					projection.get_projection_plane(x), projection.get_projection_plane(y))
				if corner == null or not (camera.global_transform * corner).is_finite():
					return false
	return true

func check_draw(world: Node) -> void:
	for camera: Camera3D in [world.cam, world.ink_cam]:
		if invalid_camera.is_empty() and not valid_frustum(camera):
			invalid_camera = "%s size=%s offset=%s" % [camera.get_path(), camera.size, camera.frustum_offset]

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1" or DisplayServer.get_name() == "headless":
		printerr("Requires a windowed renderer and an isolated session-effects fixture")
		quit(2)
		return
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-3d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Flat 3D fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	var world: Node = host.world
	var view: Control = host.workspace_view
	check(host.current_world_id() == "flat-3d", "Flat 3D is active")
	var on_draw := check_draw.bind(world)
	RenderingServer.frame_post_draw.connect(on_draw)
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive")
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_in_seconds", 0.22)
	host.effect_control.pulse()
	view.show_overview()
	for i in 6:
		view.zoom_workspace(0.54, view.size * Vector2(0.82, 0.78))
		await RenderingServer.frame_post_draw
	check(is_equal_approx(view.navigation_zoom, 0.05), "Reached minimum overview zoom")
	var overview_depth: float = world.cam.position.z
	world.term.grab_focus()
	for i in 10:
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = KEY_A
			event.unicode = 97 if pressed else 0
			event.pressed = pressed
			Input.parse_input_event(event)
		await create_timer(0.04).timeout
	check(world.cam.position.z < overview_depth * 0.5, "Typing moved the camera toward the pane")
	view.zoom_workspace(2.0, view.size * 0.5)
	await RenderingServer.frame_post_draw
	view.toggle_fit_pane(host.pane_focus)
	check(await until(func(): return view.navigation_zoom > 0.5), "Zoom to fit moved back from overview")
	await create_timer(0.4).timeout
	RenderingServer.frame_post_draw.disconnect(on_draw)
	check(invalid_camera.is_empty(), "All scenery and ink frustum corners intersect " + invalid_camera)
	check(culler_log.errors == 0, "Light-culler errors during zoom and fit = %d" % culler_log.errors)
	OS.remove_logger(culler_log)
	client.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)
