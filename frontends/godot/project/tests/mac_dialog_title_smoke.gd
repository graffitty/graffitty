extends SceneTree
## macOS native dialogs draw their own title bar and move themselves.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() != "macOS":
		print("SKIP macOS dialog title bar: needs the macOS display server")
		quit()
		return
	TranslationServer.set_locale("en")
	root.gui_embed_subwindows = false
	var dialog := AcceptDialog.new()
	dialog.title = "Remote Access Settings"
	dialog.dialog_text = "Graffitty moves this dialog while its title is held."
	root.add_child(dialog)
	dialog.popup_centered(Vector2i(640, 260))
	for i in 6: await process_frame
	var bar: Control = dialog.get_meta(&"mac_dialog_title")
	assert(is_instance_valid(bar) and bar.is_inside_tree(), "the dialog gets a title bar")
	assert(dialog.extend_to_title, "content extends under the native title bar")
	var id := dialog.get_window_id()
	# The content fills the frame, so the window is no taller than a native one.
	assert(DisplayServer.window_get_size_with_decorations(id) == DisplayServer.window_get_size(id))
	assert(DisplayServer.window_get_size(id) == dialog.size, "Godot and AppKit agree on the size")
	var band := bar.size.y
	assert(bar.position == Vector2.ZERO and is_equal_approx(bar.size.x, dialog.size.x / dialog.content_scale_factor), "the bar spans the top edge")
	assert(band >= 28.0 * DisplayServer.screen_get_max_scale() / dialog.content_scale_factor - 1.0)
	assert(dialog.get_label().position.y >= band, "content starts below the title bar")
	assert(dialog.get_ok_button().get_global_rect().end.y <= dialog.size.y / dialog.content_scale_factor)
	# A press detaches the dialog for the gesture; release reattaches it.
	assert(dialog.transient)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(bar.size.x * 0.5, band * 0.5)
	bar._gui_input(press)
	assert(not dialog.transient, "the drag detaches the dialog from its parent")
	for i in 3: await process_frame
	assert(dialog.transient, "releasing reattaches the dialog")
	await RenderingServer.frame_post_draw
	dialog.get_texture().get_image().save_png("/tmp/graffitty-mac-dialog-title.png")
	dialog.queue_free()
	# Tool windows such as Servers lay out below height() and paint the bar.
	var tool := Window.new()
	tool.title = "Servers"
	tool.transient = true
	root.add_child(tool)
	var MacDialogTitle := preload("res://scenes/MacDialogTitle.gd")
	MacDialogTitle.attach(tool, Color("101720"))
	tool.popup_centered(Vector2i(840, 620))
	for i in 6: await process_frame
	var tool_id := tool.get_window_id()
	assert(tool.extend_to_title and MacDialogTitle.height(tool) >= band - 1.0)
	assert(DisplayServer.window_get_size_with_decorations(tool_id) == DisplayServer.window_get_size(tool_id))
	assert(not tool.has_theme_stylebox_override(&"panel"), "only dialogs get a panel margin")
	tool.queue_free()
	await process_frame
	print("PASS macOS dialog draws its title bar and moves itself")
	quit()
