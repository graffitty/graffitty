extends "res://tests/tab_window_session_smoke.gd"
var frame := 0
var frames: Array = []
var first: Node
var second: Window
var redocked := false

func _initialize() -> void:
	Background.install(self)
	run.call_deferred()

func capture() -> void:
	await process_frame
	RenderingServer.force_draw()
	var dir := OS.get_environment("TAKE")
	root.get_texture().get_image().save_jpg(dir + "/main-%04d.jpg" % frame, .97)
	var win: Window = app.drag_preview if is_instance_valid(app.drag_preview) else second
	var entry := {"pointer": [pointer_position.x-root.position.x, pointer_position.y-root.position.y]}
	var hovering: bool = is_instance_valid(second) and app.drag.get("mode", -1) == app.DragMode.DOCKED
	if hovering: entry.dock_hover = true
	if redocked: entry.docked = true
	if is_instance_valid(win) and win.visible and not redocked:
		win.get_texture().get_image().save_jpg(dir + "/tab-%04d.jpg" % frame, .97)
		var pos := win.position-root.position
		entry.window = [pos.x,pos.y]
	frames.append(entry)
	frame += 1

func hold(count: int) -> void:
	for i in count: await capture()

func travel(to: Vector2, count: int) -> void:
	var origin := pointer_position
	for i in count:
		pointer_position = origin.lerp(to, smoothstep(0, 1, float(i+1)/count))
		move_drag(pointer_position)
		await capture()

func run() -> void:
	root.size = Vector2i(900,560)
	root.content_scale_factor = 1
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	for i in 600:
		if wrapper.host != null: break
		await process_frame
	if not check_host(wrapper): return
	first = wrapper.host
	app = first.application
	app.scripted_pointer = true
	await settled(first)
	await first.set_pane_title(first.pane_focus, "Project notes")
	await wrapper.connection.remote_call(first.active_session_id, "tab.set_title", {"id": first.workspace_layout.active, "title":"Notes"})
	var created: Dictionary = await wrapper.connection.request_action("create", {"kind":"tab"})
	await wrapper.connection.request_action("sync")
	await settled(first)
	var tab := int(created.created)
	await first.set_pane_title(first.pane_focus, "Live preview")
	await wrapper.connection.remote_call(tab, "tab.set_title", {"id":tab, "title":"Preview"})
	seed_preview(tab)
	await settled(first)
	var header: Control = first.workspace_view.tab_bar.tabs.buttons[tab]
	pointer_position = ScreenSpace.of(header, Vector2(40, header.size.y/2))
	await run_transfer(tab)

func run_transfer(_tab: int) -> void:
	await hold(28)
	await start_drag(first)
	# Cross the source window's right edge with the tab held.
	await travel(Vector2(root.position) + Vector2(625, -32), 16)
	await travel(Vector2(root.position) + Vector2(root.size.x + 55, -32), 25)
	await travel(Vector2(root.position) + Vector2(root.size.x + 55, 110), 19)
	var outside := pointer_position
	await end_drag(outside)
	for i in 300:
		if app.hosts.size() == 2: break
		await process_frame
	if app.hosts.size() != 2: push_error("Tab did not detach"); quit(1); return
	var detached: Node = app.hosts.back()
	second = detached.get_window()
	await settled(detached)
	await hold(35)
	await start_drag(detached)
	var bar: Control = first.workspace_view.tab_bar.tabs
	var target := ScreenSpace.of(bar, Vector2(bar.size.x*.68, bar.size.y*.5))
	await travel(target, 45)
	await hold(12)
	await end_drag(target)
	for i in 300:
		if first.get_tabs().size() == 2 and app.hosts.size() == 1: break
		await process_frame
	redocked = first.get_tabs().size() == 2 and app.hosts.size() == 1
	await settled(first)
	second = null
	await hold(48)
	FileAccess.open(OS.get_environment("TAKE")+"/motion.json", FileAccess.WRITE).store_string(JSON.stringify(frames))
	quit(0 if redocked else 1)

func seed_preview(tab: int) -> void:
	first.sessions[tab].term.send_text("printf '\\033[2J\\033[H\\033[38;5;117m●  Preview server\\033[0m\\n\\n  index.html     200 OK\\n  styles.css     200 OK\\n\\n'\r")
