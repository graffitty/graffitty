extends "res://videos/main-demo/recording/android/AndroidDemo.gd"

class DemoInsets extends "res://scenes/input/AndroidKeyboardInsets.gd":
	func _ready() -> void:
		pass # The desktop capture supplies the IME height directly.

	func queue_update() -> void:
		pass # There is no native Android IME to poll on macOS.

var capture_frame := 0

func demo_ticks_msec() -> int:
	return roundi(capture_frame * 1000.0 / 60.0)

func capture_surface() -> void:
	RenderingServer.force_draw()
	root.get_texture().get_image().save_jpg(output.get_base_dir().path_join("mobile-%04d.jpg" % capture_frame), .97)
	capture_frame += 1

func navigate() -> void:
	var center: Vector2 = view.get_global_transform_with_canvas() * view.viewport_content_rect().get_center()
	var shift := Vector2(view.size.x * .20, view.size.y * .10)
	var radius := minf(170.0, view.size.x * .24)
	emit_touch(0, true, center - Vector2(radius, 0))
	emit_touch(1, true, center + Vector2(radius, 0))
	await wait(.13)
	# Pinch, then pan with the same pair. Deliver both updated positions before
	# yielding a frame so the centroid travels smoothly along the diagonal.
	var begin := demo_ticks_msec()
	while true:
		var elapsed := (demo_ticks_msec() - begin) / 1000.0
		var pinch := smoothstep(0, .38, elapsed)
		var pan := smoothstep(.32, .92, elapsed)
		var at := center + shift * pan
		var dx := Vector2(lerpf(radius, radius * .32, pinch), 0)
		emit_drag(0, at - dx)
		emit_drag(1, at + dx)
		Input.flush_buffered_events()
		await get_tree().process_frame
		if elapsed >= .92: break
	await wait(.06)
	emit_touch(0, false, center + shift - Vector2(radius * .32, 0))
	emit_touch(1, false, center + shift + Vector2(radius * .32, 0))

func arrange_agents(pane: String) -> void:
	var main: Rect2 = view.content_rect()
	var agents: Array[String] = [pane]
	var names := ["Claude", "Test runner", "Layout reviewer", "Android reviewer"]
	var prompts := ["", "Check the touch tests", "Inspect the pane layout", "Review keyboard insets"]
	for i in range(1, names.size()):
		var added := await split(pane)
		if added.is_empty(): return
		agents.append(added)
		await host.set_pane_title(added, names[i])
		terminal(added).send_text(prompts[i] + "\r")
	if current_tree().get("tiling", false): await toggle_tiling()
	var grid := [Vector2.ZERO, Vector2(-.95, .10), Vector2(-.95, -.80), Vector2(.14, -.80)]
	for i in agents.size():
		var rect := Rect2(main.position + grid[i] * main.size * 1.20, main.size * .95)
		if i == 0:
			rect.size = main.size * Vector2(.90, .46)
			rect.position = main.get_center() - rect.size * .5
		var item := Layout.find(current_tree(), agents[i])
		item.rect = rect
		item.stashed = i != 0
		host.session_backend.resize_pane(host, agents[i], rect)
	view.refresh()
	host.session_backend.commit_workspace(host)
	await wait(1)
	view.inspect_pane(pane)
	expect(view.pane_rects.size() == 4, "Four agent panes share the workspace")

func demo() -> void:
	root.size = Vector2i(1200, 1200)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.6
	mobile.clock_msec = demo_ticks_msec
	await wait(.5)
	var overlay := CanvasLayer.new()
	overlay.layer = 120
	add_child(overlay)
	contacts = Fingers.new()
	contacts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(contacts)
	contacts.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pane: String = host.pane_focus
	await host.set_pane_title(pane, "Claude")
	await arrange_agents(pane)
	await wait(2)
	get_tree().process_frame.connect(capture_surface)
	await wait(.7)
	await navigate()
	await wait(.85)
	var keyboard := preload("DemoKeyboard.gd").new()
	overlay.add_child(keyboard)
	overlay.move_child(contacts,-1)
	keyboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keyboard.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	keyboard.offset_top = -keyboard.HEIGHT
	var insets := DemoInsets.new()
	insets.manager = manager
	add_child(insets)
	insets.update_inset(keyboard.HEIGHT)
	await wait(.4)
	host.focus_pane(pane)
	terminal(pane).grab_focus()
	var before: float = view._displayed_camera_zoom(1)
	for character in "Review the layout":
		var cap := character.to_lower()
		keyboard.pressed = cap
		contacts.positions[0] = keyboard.position + keyboard.centers[cap]
		contacts.queue_redraw()
		keyboard.queue_redraw()
		var code := character.unicode_at(0)
		await key(character.to_upper().unicode_at(0), false, false, code)
		keyboard.typed += character
		keyboard.shifted = false
		keyboard.pressed = ""
		keyboard.queue_redraw()
		contacts.positions.erase(0)
		contacts.queue_redraw()
		await wait(.035)
	expect("Review the layout" in text_in(pane), "Keystrokes reach the focused Claude prompt")
	var during: float = view._displayed_camera_zoom(1)
	await wait(3.5)
	var rest: float = view._displayed_camera_zoom(1)
	expect(before < .5 and during > before * 1.7 and absf(rest-before) < .015, "Pinch, adaptive follow and return: %s" % [[before, during, rest]])
	insets.update_inset(0)
	keyboard.hide()
	await wait(.5)
	get_tree().process_frame.disconnect(capture_surface)
