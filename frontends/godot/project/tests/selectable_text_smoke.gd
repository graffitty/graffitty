extends SceneTree
## Read-only text and lists select and scroll like a terminal: Ghostty words
## and lines, word-wise dragging, and the rubber band for trackpads and
## fingers. Headless; drives real input events through the viewport.
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)


func _initialize() -> void:
	run.call_deferred()


func frames(count := 1) -> void:
	for i in count: await process_frame


func mouse(at: Vector2, button := MOUSE_BUTTON_LEFT, pressed := true, double := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.double_click = double
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	root.push_input(event, true)
	if pressed and button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]: mouse(at, button, false)


func move(at: Vector2, held := true) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event, true)


func pan(at: Vector2, delta_y: float, phase: String) -> void:
	var event := InputEventPanGesture.new()
	event.position = at
	# Content pixels, as a touch scroll reports them on every platform.
	event.delta = Vector2(0, delta_y * (0.03 if OS.get_name() == "macOS" else 1.0))
	event.set_meta("scroll_phase", phase)
	event.set_meta("touch_travel", Vector2(0, -delta_y))
	root.push_input(event, true)


func touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = at
	event.pressed = pressed
	root.push_input(event, true)


func drag(from: Vector2, to: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = to
	event.relative = to - from
	root.push_input(event, true)


func at_column(text: Node, line: int, column: int) -> Vector2:
	var cell: Rect2i = text.view.get_rect_at_line_column(line, column)
	# Viewport coordinates: every event is pushed in local coordinates.
	return text.view.get_global_transform_with_canvas() * (Vector2(cell.position) + Vector2(cell.size) * 0.5)


func settle(still: Callable, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if still.call(): return true
	return false


func run() -> void:
	root.size = Vector2i(900, 700)
	await check_text_selection()
	await check_text_rubber_band()
	await check_list_text_selection()
	await check_list_touch()
	await check_dictation_preview()
	print("SELECTABLE_TEXT_PASS" if failures.is_empty() else "SELECTABLE_TEXT_FAIL")
	quit(0 if failures.is_empty() else 1)


func check_dictation_preview() -> void:
	var preview := preload("res://scenes/input/DictationPreview.gd").new()
	preview.position = Vector2(20, 20)
	preview.size = Vector2(420, 110)
	preview.view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	preview.view.editable = false
	root.add_child(preview)
	var words := "말하는 동안 이전 내용과 최신 내용을 확인합니다. ".repeat(100)
	preview.set_transcript(words)
	await frames(4)
	var bar := preview.view.get_v_scroll_bar()
	check(preview.view.get_line_count() == 1 and preview.view.get_total_visible_line_count() > 20, "Dictation fixture is one long, soft-wrapped paragraph")
	check(bar.visible and preview._at_end(), "Wrapped dictation follows the actual bottom and shows a scrollbar")
	var inside := preview.get_global_rect().get_center()
	for i in 3: mouse(inside, MOUSE_BUTTON_WHEEL_UP)
	var reviewing := preview.view.scroll_vertical
	check(not preview.follow_end and reviewing < preview._end(), "Wheel scrolling up pauses dictation following")
	preview.set_transcript(words + "더 말합니다. ".repeat(50))
	await frames(4)
	check(is_equal_approx(preview.view.scroll_vertical, reviewing), "New words preserve the reviewed scroll position after layout")
	for i in 100: mouse(inside, MOUSE_BUTTON_WHEEL_DOWN)
	check(preview.follow_end and preview._at_end(), "Reaching the bottom by wheel resumes following")
	preview.set_transcript(words + words)
	await frames(4)
	check(preview._at_end(), "Next transcript follows after returning to the bottom")
	preview.size.x = 270
	await frames(4)
	check(preview._at_end(), "Narrower layout keeps the latest wrapped words visible")
	# A touch arriving between text assignment and deferred layout wins.
	preview.set_transcript(words + words + words)
	touch(inside, true)
	drag(inside, inside + Vector2(0, 60))
	reviewing = preview.view.scroll_vertical
	await frames(4)
	check(not preview.follow_end and is_equal_approx(preview.view.scroll_vertical, reviewing), "A finger drag cancels pending auto-follow before layout settles")
	preview.set_transcript(words.repeat(4))
	await frames(4)
	check(is_equal_approx(preview.view.scroll_vertical, reviewing), "Streaming while a finger stays down never moves its reading position")
	# No release velocity: verify a deliberately stationary lift.
	await create_timer(.12).timeout
	touch(inside + Vector2(0, 60), false)
	await frames(3)
	check(not preview.elastic.is_touching(), "Only the scrolling finger's release ends its gesture")
	for i in 400: mouse(inside, MOUSE_BUTTON_WHEEL_UP)
	pan(inside, 0, "began")
	pan(inside, -100, "changed")
	check(preview.elastic.get_stretch() < 0.0 and preview.view.position.y > 0.0, "Dictation pulls past the top with the shared rubber band")
	check(preview._bar_skin != null and preview._bar_skin.visible, "Dictation scrollbar thumb reflects the elastic pull")
	pan(inside, 0, "ended")
	check(await settle(func(): return not preview.elastic.is_active()), "Dictation top pull springs back and rests")
	for i in 400: mouse(inside, MOUSE_BUTTON_WHEEL_DOWN)
	pan(inside, 0, "began")
	pan(inside, 100, "changed")
	check(preview.elastic.get_stretch() > 0.0, "Dictation also stretches past the bottom")
	preview.set_transcript(words.repeat(5))
	await frames(3)
	check(not preview._at_end(), "New words do not jump to the bottom during an active pan")
	pan(inside, 0, "ended")
	check(await settle(func(): return not preview.elastic.is_active()), "Dictation bottom pull springs back and rests")
	await frames(3)
	check(preview._at_end(), "Following resumes after a bottom pull finishes: %s %s/%s" % [preview.follow_end, preview.view.scroll_vertical, preview._end()])
	# Native thumb dragging must pause following, including when words arrive.
	var thumb_at := bar.get_global_rect().end - Vector2(bar.size.x / 2, maxf(2.0, bar.get_theme_stylebox("grabber").get_minimum_size().y / 2))
	move(thumb_at, false)
	mouse(thumb_at)
	move(thumb_at - Vector2(0, 35))
	await frames()
	reviewing = preview.view.scroll_vertical
	check(not preview.follow_end and reviewing < preview._end(), "Dragging the scrollbar pauses following")
	preview.set_transcript(words.repeat(6))
	await frames(3)
	check(is_equal_approx(preview.view.scroll_vertical, reviewing), "Transcript updates preserve an active scrollbar drag")
	mouse(thumb_at - Vector2(0, 35), MOUSE_BUTTON_LEFT, false)
	preview.reset()
	preview.set_transcript(words)
	await frames(3)
	check(preview.follow_end and preview._at_end(), "A fresh recording resets follow state")
	preview.set_transcript(words + "\n잠정 결과\n")
	preview.set_transcript(words + "\n수정된 마지막 문장")
	await frames(3)
	check(preview._at_end() and preview.view.get_line_count() == 2, "Rapid final corrections with explicit newlines still follow the end")
	preview.view.editable = true
	preview.view.set_caret_line(0)
	preview.view.set_caret_column(0)
	preview.view.insert_text_at_caret("Edited draft ")
	await frames(3)
	check(preview.view.scroll_vertical == 0.0, "Editing a preserved draft keeps normal caret scrolling")
	preview.queue_free()
	await frames()


func check_text_selection() -> void:
	var text := preload("res://scenes/SelectableText.gd").new()
	text.position = Vector2(20, 20)
	text.size = Vector2(700, 300)
	root.add_child(text)
	text.text = "cd ~/project/godot-ghostty; echo $HOME\n  Build 42 (debug)  \nlast line"
	await frames(3)
	var path := at_column(text, 0, 8)
	touch(path, true)
	await create_timer(0.6).timeout
	check(text.get_selected_text() == "~/project/godot-ghostty", "Holding a finger selects the word")
	var end := at_column(text, 0, 29)
	drag(path, end)
	check(text.get_selected_text() == "~/project/godot-ghostty; echo", "Dragging after a hold extends the selection")
	touch(end, false)
	check(text.menu != null and not text.menu.is_item_disabled(0), "Lifting the finger offers Copy")
	if text.menu != null:
		var touch_menu := preload("res://scenes/PopupChrome.gd").presentation(text.menu)
		if touch_menu != null: touch_menu.dismiss()
		else: text.menu.hide()
	await frames()
	text.deselect()
	touch(path, true)
	drag(path, path + Vector2(0, 25))
	await create_timer(0.6).timeout
	check(not text.has_selection(), "Moving before the hold scrolls without selecting")
	touch(path + Vector2(0, 25), false)
	await frames()
	mouse(path)
	mouse(path, MOUSE_BUTTON_LEFT, false)
	mouse(path, MOUSE_BUTTON_LEFT, true, true)
	await frames()
	check(text.get_selected_text() == "~/project/godot-ghostty", "Double click takes a terminal word: '%s'" % text.get_selected_text())
	move(at_column(text, 0, 29))
	await frames()
	check(text.get_selected_text() == "~/project/godot-ghostty; echo", "Dragging extends a whole word at a time: '%s'" % text.get_selected_text())
	move(at_column(text, 0, 1))
	await frames()
	check(text.get_selected_text() == "cd ~/project/godot-ghostty", "Dragging back keeps the first word: '%s'" % text.get_selected_text())
	mouse(at_column(text, 0, 1), MOUSE_BUTTON_LEFT, false)
	var build := at_column(text, 1, 4)
	mouse(build)
	mouse(build, MOUSE_BUTTON_LEFT, false)
	mouse(build, MOUSE_BUTTON_LEFT, true, true)
	mouse(build, MOUSE_BUTTON_LEFT, false)
	mouse(build)
	await frames()
	check(text.get_selected_text() == "Build 42 (debug)", "Triple click takes the line without blanks: '%s'" % text.get_selected_text())
	move(at_column(text, 2, 2))
	await frames()
	check(text.get_selected_text().begins_with("Build 42 (debug)") and text.get_selected_text().ends_with("last line"), "Dragging after a triple click extends by lines")
	mouse(at_column(text, 2, 2), MOUSE_BUTTON_LEFT, false)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set("BEFORE")
		text.copy()
		check(DisplayServer.clipboard_get() == text.get_selected_text(), "Copy takes the selection")
	text.queue_free()
	await frames()


func check_text_rubber_band() -> void:
	var text := preload("res://scenes/SelectableText.gd").new()
	text.position = Vector2(20, 20)
	text.size = Vector2(500, 200)
	root.add_child(text)
	var lines := PackedStringArray()
	for i in 200: lines.append("row %d" % i)
	text.text = "\n".join(lines)
	await frames(3)
	var resting_track := text.view.get_v_scroll_bar().get_global_rect()
	var inside := Vector2(200, 100)
	pan(inside, 0, "began")
	for i in 12: pan(inside, -20, "changed")
	await frames()
	check(text.view.scroll_vertical == 0.0 and text.elastic.get_stretch() < 0.0 and text.view.offset_top > 0.0, "Pulling down at the top stretches the text: %s" % text.elastic.get_stretch())
	check(text._bar_skin != null and text._bar_skin.visible and text._bar_skin.stretch < 0.0, "The text's scrollbar thumb shortens while pulled")
	check(text._bar_skin.get_global_rect().is_equal_approx(resting_track), "The scrollbar stays at its resting track while the text pulls down")
	pan(inside, 0, "ended")
	check(await settle(func(): return text.elastic.get_stretch() == 0.0 and text.view.offset_top == 0.0), "The pull springs back to rest")
	check(not text._bar_skin.visible, "At rest the text's scrollbar draws itself again")
	pan(inside, 0, "began")
	for i in 10: pan(inside, 30, "changed")
	pan(inside, 0, "ended")
	await frames()
	check(is_equal_approx(text.view.scroll_vertical * text.view.get_line_height(), 300.0), "A pan scrolls by the distance travelled: %s rows" % text.view.scroll_vertical)
	text.view.scroll_vertical = text.view.get_v_scroll_bar().max_value
	touch(inside, true)
	drag(inside, inside - Vector2(0, 65))
	await frames()
	check(text.view.offset_top < 0.0 and text._bar_skin.stretch > 0.0, "A finger pulling past the bottom stretches the text and compresses the thumb")
	check(text._bar_skin.get_global_rect().is_equal_approx(resting_track), "The bottom track stays pinned during touch overscroll")
	touch(inside - Vector2(0, 65), false)
	check(await settle(func(): return text.elastic.get_stretch() == 0.0 and not text._bar_skin.visible), "The bottom pull restores the native scrollbar")
	text.queue_free()
	await frames()


func check_list_text_selection() -> void:
	var list := preload("res://scenes/ElasticScrollContainer.gd").new()
	list.position = Vector2(20, 20)
	list.size = Vector2(500, 260)
	var message := preload("res://scenes/SelectableText.gd").new()
	message.fit_content = true
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.text = "Held message body\n".repeat(100)
	list.add_child(message)
	root.add_child(list)
	await frames(4)
	var at := at_column(message, 1, 6)
	touch(at, true)
	await create_timer(0.6).timeout
	check(message.get_selected_text() == "message", "Holding a history message selects its word in the scrolling list")
	drag(at, at + Vector2(32, 40))
	check(list.scroll_offset() == 0 and message.get_selected_text().length() > 7, "A held history selection extends without scrolling its list")
	touch(at + Vector2(32, 40), false)
	if message.menu != null:
		var popup := preload("res://scenes/PopupChrome.gd").presentation(message.menu)
		if popup != null: popup.dismiss()
		else: message.menu.hide()
	message.deselect()
	await frames()
	touch(at + Vector2(0, 60), true)
	drag(at + Vector2(0, 60), at)
	await create_timer(0.6).timeout
	check(list.scroll_offset() > 0 and not message.has_selection(), "Moving before the hold scrolls the history and cancels selection")
	touch(at, false)
	list.queue_free()
	await frames()


func check_list_touch() -> void:
	var list := preload("res://scenes/ElasticScrollContainer.gd").new()
	list.position = Vector2(20, 20)
	list.size = Vector2(300, 240)
	list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pressed := [0]
	for i in 40:
		var row := Button.new()
		row.text = "Row %d" % i
		row.custom_minimum_size.y = 40
		row.pressed.connect(func(): pressed[0] += 1)
		rows.add_child(row)
	list.add_child(rows)
	root.add_child(list)
	await frames(3)
	var start := Vector2(150, 200)
	touch(start, true)
	var point := start
	for i in 10:
		drag(point, point + Vector2(0, -12))
		point += Vector2(0, -12)
		await frames()
	var dragged: float = list.scroll_offset()
	check(dragged > 90.0 and dragged < 120.0, "A finger drag scrolls by its travel past the slop: %s" % dragged)
	touch(point, false)
	await frames(3)
	check(list.scroll_offset() > dragged, "A flick glides on after the finger lifts")
	check(pressed[0] == 0, "Dragging over a row never presses it")
	check(await settle(func(): return not list.elastic.is_active()), "The glide comes to rest")
	list.stop_scrolling()
	list.get_v_scroll_bar().value = 0
	await frames(2)
	start = Vector2(150, 60)
	touch(start, true)
	point = start
	for i in 10:
		drag(point, point + Vector2(0, 20))
		point += Vector2(0, 20)
		await frames()
	check(list.scroll_offset() == 0.0 and list.stretch < 0.0 and rows.position.y > 0.0, "Dragging down at the top pulls the rows past the edge: %s" % rows.position.y)
	var bar := list.get_v_scroll_bar()
	var resting: Vector2 = list.elastic.thumb(240.0, 0.0, bar.max_value - bar.page, bar.page, 0.0, 16.0)
	var pulled: Vector2 = list.elastic.thumb(240.0, 0.0, bar.max_value - bar.page, bar.page, list.stretch, 16.0)
	check(list._bar_skin != null and list._bar_skin.visible and bar.self_modulate.a == 0.0 and pulled.y < resting.y and pulled.x == 0.0, "The scrollbar thumb shortens against the pulled top")
	touch(point, false)
	check(await settle(func(): return list.stretch == 0.0 and is_zero_approx(rows.position.y)), "Released rows spring back to the edge")
	check(not list._bar_skin.visible and bar.self_modulate.a == 1.0, "At rest the scrollbar draws itself again")
	list.queue_free()
	await frames()
