extends SceneTree
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
const Navigation := preload("res://scenes/remote/RemoteNavigation.gd")
var failures := 0

class LivePanel extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color.MAGENTA)

class Host extends Node:
	var layout_root := Control.new()
class View extends Node:
	var host := Host.new()
class Manager extends Control:
	var view := View.new()
	var chooser := ColorRect.new()
	var dialog := Control.new()
	var floating := CanvasLayer.new()
	var keybar: Control

func _initialize() -> void:
	Background.install(self)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func run() -> void:
	root.size = Vector2i(402, 700)
	var manager := Manager.new()
	root.add_child(manager)
	manager.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	manager.add_child(manager.view)
	manager.view.add_child(manager.view.host)
	var host: Node = manager.view.host
	host.add_child(host.layout_root)
	host.layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var content := ColorRect.new()
	content.color = Color("166534")
	host.layout_root.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := LivePanel.new()
	host.layout_root.add_child(panel)
	panel.size = Vector2(34, 34)
	var tabs := Label.new()
	tabs.text = "‹   ⌄    Terminal"
	host.layout_root.add_child(tabs)
	manager.add_child(manager.chooser)
	manager.chooser.color = Color("1e40af")
	manager.chooser.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	manager.add_child(manager.dialog)
	manager.add_child(manager.floating)
	var button := Button.new()
	button.text = "Keyboard"
	button.position = Vector2(270, 630)
	manager.floating.add_child(button)
	var navigation := Navigation.new()
	navigation.manager = manager
	navigation.enter(Navigation.Space.MANAGER)
	await process_frame
	var width := root.get_visible_rect().size.x
	for entering in [true, false]:
		navigation.enter(Navigation.Space.WORKSPACE if entering else Navigation.Space.MANAGER)
		check(navigation.is_transitioning(), "Both navigation directions animate in the touch profile")
		if not navigation.is_transitioning(): continue
		var transition = navigation.transition
		transition.set_process(false)
		check(manager.chooser.visible == not entering, "Live destination changes immediately, independently of retained pages")
		check(transition._workspace.position.x == (width if entering else 0.0), "Workspace starts on the correct side")
		if entering: panel.set_deferred("position", Vector2(24, 100))
		navigation.enter(navigation.current)
		check(navigation.transition == transition, "Repeated topology navigation does not restart the animation")
		await process_frame
		transition._apply(0.15)
		check(transition._workspace.position.x > 0 and transition._workspace.position.x < width, "Entire workspace is between its endpoints")
		check(transition._list.position.x < 0 and transition._list.position.x > -width * 0.3 - 0.01, "List moves beneath workspace with 30 percent parallax")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			if entering:
				var image := root.get_texture().get_image()
				var sample_point := (transition._workspace.position + panel.position + panel.size * 0.5) as Vector2
				var pixel := image.get_pixelv(Vector2i(sample_point * Vector2(image.get_size()) / root.get_visible_rect().size))
				check(pixel.r > 0.8 and pixel.g < 0.2 and pixel.b > 0.8, "Slide renders live custom drawing at its settled layout position")
			var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
			if not evidence.is_empty(): root.get_texture().get_image().save_png(evidence.path_join("page-push.png" if entering else "page-pop.png"))
		transition._apply(1.0)
		check(not navigation.is_transitioning(), "Completion releases input and queues retained pages for disposal")
		await process_frame
		check(not is_instance_valid(transition), "Retained viewport tree is freed")
	navigation.enter(Navigation.Space.WORKSPACE)
	var resized = navigation.transition
	root.size = Vector2i(700, 402)
	await process_frame
	await process_frame
	check(not navigation.is_transitioning(), "Rotation cancels presentation without undoing navigation")
	check(navigation.current == Navigation.Space.WORKSPACE and host.layout_root.visible, "Destination stays usable after resize")
	navigation.enter(Navigation.Space.MANAGER)
	var interrupted = navigation.transition
	navigation.enter(Navigation.Space.EDITOR)
	check(not navigation.is_transitioning() and manager.dialog.visible, "Opening an editor cancels page presentation")
	await process_frame
	check(not is_instance_valid(interrupted) and not is_instance_valid(resized), "Interrupted presentations release their views")
	manager.queue_free()
	await process_frame
	await create_timer(0.3).timeout
	print("REMOTE_PAGE_TRANSITION failures=", failures)
	quit(1 if failures else 0)
