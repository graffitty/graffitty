extends SceneTree
## Raw graph input must yield to fixed panels despite workspace zoom/pan.
var failures: Array[String] = []

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-panel-input-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	_run.call_deferred()

func expect(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func _run() -> void:
	test_panels_block_raw_graph_clicks_independently_of_camera()
	for message in failures: push_error(message)
	if failures.is_empty(): print("PASS panel priority: scaled panel, zoom/pan, left/right click, release and hidden panel")
	quit(0 if failures.is_empty() else 1)

class DockSurface extends Control:
	var side := "left"

class PanelStub extends Window:
	var _desktop: Control

class GraphView extends Control:
	var host: Node
	func graph_pointer_allowed(point: Vector2) -> bool:
		return not preload("res://scenes/mods/PanelWindow.gd").blocks_workspace_pointer(host, point)

class ClickOverlay extends Control:
	var editing := true
	var queries := 0
	var pane_screen_bounds := {}
	func clear_edge_hover() -> void: pass
	func redraw() -> void: pass
	func queue_hit(_point: Vector2) -> String:
		queries += 1
		return "t1>t2"

func test_panels_block_raw_graph_clicks_independently_of_camera() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	root.gui_embed_subwindows = true
	var host := Control.new()
	root.add_child(host)
	var dock := DockSurface.new()
	dock.position = Vector2(30, 40)
	dock.size = Vector2(180, 300)
	dock.scale = Vector2(1.5, 1.5)
	root.add_child(dock)
	var panel := PanelStub.new()
	panel._desktop = dock
	panel.hide()
	panel.add_to_group("panel_window")
	root.add_child(panel)
	var view := GraphView.new()
	view.host = host
	var overlay := ClickOverlay.new()
	var tools := preload("res://scenes/GraphWorkspaceTools.gd").new()
	tools.overlay = overlay
	tools.view = view
	for camera_scale in [1.0, 0.3, 2.0]:
		host.scale = Vector2.ONE * camera_scale
		host.position = Vector2(250, -100)
		for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			var event := InputEventMouseButton.new()
			event.position = Vector2(270, 80)
			event.button_index = button
			event.pressed = true
			tools._input(event)
			expect(overlay.queries == 0 and tools.gesture.is_empty(), "A scaled Sessions panel wins over graph picking at camera scale %s" % camera_scale)
	var release := InputEventMouseButton.new()
	release.position = Vector2(80, 80)
	release.button_index = MOUSE_BUTTON_LEFT
	for kind in ["inspect_wire", "new_input", "reconnect", "pick_input"]:
		tools.gesture = {"kind":kind, "key":"t1>t2"}
		tools._input(release)
		expect(tools.gesture.is_empty(), "Releasing over a panel cancels " + kind)
	dock.hide()
	expect(view.graph_pointer_allowed(Vector2(80, 80)), "A hidden panel no longer blocks the workspace")
	panel._desktop.side = ""
	panel.position = Vector2i(50, 50)
	panel.size = Vector2i(180, 120)
	panel.show()
	expect(not view.graph_pointer_allowed(Vector2(80, 80)), "A floating panel takes precedence too")
	panel.hide()
	var popup := Window.new()
	popup.position = Vector2i(50, 50)
	popup.size = Vector2i(180, 120)
	root.add_child(popup)
	popup.show()
	expect(not view.graph_pointer_allowed(Vector2(80, 80)), "An embedded popup blocks graph picking regardless of panel membership")
	popup.free()
	tools.free()
	overlay.free()
	view.free()
	panel.free()
	dock.free()
	host.free()
