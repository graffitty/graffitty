extends RefCounted
## One presentation boundary for connection pages and the live workspace.
## Transport state and saved credentials are deliberately not navigation state.
enum Space { MANAGER, EDITOR, WORKSPACE }
var current := Space.MANAGER
var manager: Control
var transition: CanvasLayer

func enter(next: Space) -> void:
	var previous := current
	if previous != next:
		if is_transitioning(): transition.finish()
		if _can_animate(previous, next):
			preload("res://scenes/input/WorkspaceMenus.gd").dismiss(manager.view.host)
			transition = preload("res://scenes/remote/RemotePageTransition.gd").new()
			transition.prepare(manager, next == Space.WORKSPACE)
			manager.add_child(transition)
	current = next
	manager.chooser.visible = next == Space.MANAGER
	manager.dialog.visible = next == Space.EDITOR
	apply_workspace()

func apply_workspace() -> void:
	var shown := current == Space.WORKSPACE
	if is_instance_valid(manager.view) and is_instance_valid(manager.view.host):
		var host: Node = manager.view.host
		if not shown: preload("res://scenes/input/WorkspaceMenus.gd").dismiss(host)
		if is_instance_valid(host.layout_root): host.layout_root.visible = shown
	if not manager.is_inside_tree(): return
	var window := manager.get_window()
	window.set_meta(&"workspace_ui_active", shown)
	if is_instance_valid(manager.view) and is_instance_valid(manager.view.host):
		var host: Node = manager.view.host
		if host.session_backend != null: host.session_backend.sync_window_area(host)
	if window.has_meta(&"list_dock_space"):
		window.get_meta(&"list_dock_space").set_workspace_active(shown)
	for panel in manager.get_tree().get_nodes_in_group(&"workspace_tool_windows"):
		if panel.get_parent().get_window() == window: panel.set_workspace_active(shown)


func is_transitioning() -> bool:
	return is_instance_valid(transition) and not transition.is_queued_for_deletion()

func _can_animate(previous: Space, next: Space) -> bool:
	return (previous in [Space.MANAGER, Space.WORKSPACE]
		and next in [Space.MANAGER, Space.WORKSPACE]
		and manager.is_inside_tree()
		and preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		and is_instance_valid(manager.view) and is_instance_valid(manager.view.host)
		and is_instance_valid(manager.view.host.layout_root))
