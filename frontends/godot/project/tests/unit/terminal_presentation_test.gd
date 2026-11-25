extends "res://tests/unit/test_case.gd"
const Motion := preload("res://scenes/TabDepthMotion.gd")

func screen_fraction(camera: Transform3D, frustum: Vector4, point: Vector3) -> Vector2:
	var local := camera.affine_inverse() * point
	return (Vector2(local.x, local.y) / -local.z - Vector2(frustum.x, frustum.y)) / Vector2(frustum.z, frustum.w)

func test_cursor_follows_dolly_with_off_axis_camera_pan_tilt_and_zoom() -> void:
	var reference := Transform3D(Basis.from_euler(Vector3(.12, -.3, .05)), Vector3(2, 1, 10))
	var camera := Transform3D(Basis.from_euler(Vector3(-.1, .4, -.08)), Vector3(-3, 2, 8))
	var captured := Vector4(-.7, -.3, 1.1, .8)
	var current := Vector4(-.25, -.6, .8, 1.0)
	for point in [Vector3(-2, 1, -10), Vector3(3, -2, -7)]:
		var world: Vector3 = reference * point
		var before := screen_fraction(reference, captured, world)
		for direction in [-1.0, 1.0]:
			for arriving in [false, true]:
				for progress in [0.0, .25, .5, .75, 1.0]:
					var zoom := Motion.magnification(progress, direction, arriving)
					var transform := Motion.presentation_transform(reference, camera, captured, current, zoom)
					var actual := screen_fraction(camera, current, transform * world)
					var expected := Vector2(.5, .5) + (before - Vector2(.5, .5)) * zoom
					expect(actual.distance_to(expected) < .00001, "Cursor and pane retain the captured screen framing throughout push/pull")

class Grid extends Control:
	var cell_padding := 4
	func get_visible_area() -> Dictionary: return {"grid_origin": Vector2(4, -3)}
	func get_grid_size() -> Vector2i: return Vector2i(80, 24)
	func get_cell_size() -> Vector2: return Vector2(12, 28)

func test_cursor_uses_native_grid_origin_including_fractional_scroll() -> void:
	var terminal := Grid.new()
	terminal.position = Vector2(9, 13)
	var point := preload("res://scenes/TerminalPresentation.gd").grid_point(terminal, Vector2(4.5 / 80, 2.5 / 24))
	expect(point.is_equal_approx(Vector2(67, 80)), "Logical cursor pixels include terminal offset and the native scrolled grid origin")
	terminal.free()

func test_world_menu_replaces_same_target_and_keeps_names_literal() -> void:
	var configured: Array[Dictionary] = [{"label": "View::World::Flat", "action": "SwitchWorld", "path": "flat-3d"}]
	var builtins: Array[Dictionary] = [
		{"label": "View::World::Flat 3D", "action": "SwitchWorld", "path": "flat-3d"},
		{"label": "View::World::Flat 2D", "action": "SwitchWorld", "path": "flat-2d"},
	]
	builtins.append({"label": "View::Test", "action": func(): pass})
	var entries := preload("res://scenes/TerminalHost.gd").merge_menu_entries(configured, builtins)
	expect(entries.size() == 3 and entries[0].label == "View::World::Flat", "A configured world replaces the automatic entry even under a different label")
	for entry in entries.slice(0, 2): expect(entry.literal_label, "Built-in and configured world names are never translated")

class FlatFlight extends "res://scenes/FlatTerminalSpaceWorld.gd":
	func _ready() -> void: pass
	func _process(_dt: float) -> void: pass

class FlightLayer extends Node3D:
	var material := ShaderMaterial.new()
	func _init() -> void: material.shader = preload("res://scenes/cell_shatter.gdshader")
	func _material() -> ShaderMaterial: return material
	func update_raster(_camera: Camera3D) -> void: pass

## Requires a live SceneTree; run by flat_session_projection_smoke.gd.
func check_flat_fly_away_retains_departing_projection_and_flight_axes() -> void:
	var world := FlatFlight.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(world)
	world.cam = Camera3D.new()
	world.add_child(world.cam)
	world.session_transition_active = true
	var layer := FlightLayer.new()
	world.add_child(layer)
	var reference := Transform3D(Basis.from_euler(Vector3(.1, -.2, .04)), Vector3(2, 1, 10))
	var captured := Vector4(-.5, -.3, 1.0, .6)
	world.cam.global_transform = reference
	world.proj_rect = captured
	world._bind_transition_camera(layer, reference)
	# The departure keeps its contract after the new session is already live.
	world.session_transition_active = false
	for zoom in [.3, .6, 1.0, 2.0]:
		world.cam.global_transform = Transform3D(Basis.from_euler(Vector3(-.2, .3, -.1)), Vector3(-4, 2, 7))
		world.proj_rect = Vector4(-.4, -.2, .8, .5) / zoom
		world._update_transition_camera(layer)
		var transform: Transform3D = layer.material.get_shader_parameter("flight_camera_transform")
		for point in [Vector3(-2, 1, -10), Vector3(3, -2, -7), Vector3(-1, 2, -3)]:
			var original: Vector3 = reference * point
			var expected := screen_fraction(reference, captured, original)
			var actual := screen_fraction(world.cam.global_transform, world.proj_rect, transform * original)
			expect(actual.distance_to(expected) < .00001, "Flat departure retains its original screen geometry while the destination zooms")
		expect((layer.material.get_shader_parameter("flight_camera_axes") as Basis).is_equal_approx(reference.basis), "Wind and dust use captured camera axes, not the scaled projection transform")
	world.free()

func test_flat_2d_flight_cancels_camera_scale_before_compositing() -> void:
	var parent := Node2D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(parent)
	var layer := preload("res://scenes/TabTransition2D.gd").new()
	parent.add_child(layer)
	parent.transform = Transform2D(0.0, Vector2(2, 2), 0.0, Vector2(100, 50))
	layer.depth_projection = parent.global_transform
	layer.screen_space = true
	for zoom in [.3, .6, 1.0, 2.0]:
		parent.transform = Transform2D(0.0, Vector2(zoom, zoom), 0.0, Vector2(-200, 100))
		for phase in [0.0, .2, .5]:
			layer.set_progress(phase)
			expect(layer.global_transform.is_equal_approx(layer.depth_projection), "Flat 2D flight remains in captured screen coordinates at every phase")
	parent.free()

func test_authored_worlds_keep_world_space_session_flights() -> void:
	for script in [preload("res://scenes/FlatTerminalSpaceWorld.gd"), preload("res://scenes/Flat2DWorld.gd"), preload("res://scenes/TerminalWorld3D.gd")]:
		var world: Node = script.new()
		world.session_transition_active = false
		expect(not world.screen_space_session_flight(), "Ordinary tab navigation is unchanged")
		world.session_transition_active = true
		expect(world.screen_space_session_flight() == (script != preload("res://scenes/TerminalWorld3D.gd")), "Only Flat worlds opt into screen-space session flight; scenery kit retains camera travel")
		world.free()
