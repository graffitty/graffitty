extends "Tabs.gd"

func assert_state(ok: bool, label: String) -> bool:
	print(label, ": ", ok)
	if not ok: quit(1)
	return ok

func move_pointer(to: Vector2, count: int, dragging: bool) -> void:
	var origin := pointer_position
	for i in count:
		pointer_position = origin.lerp(to, smoothstep(0, 1, float(i+1)/count))
		if dragging: app.update_drag(pointer_position)
		await capture()

func seed_preview(_tab: int) -> void:
	pass # Each PTY starts with its own fixture already on screen.

func run_transfer(tab: int) -> void:
	await first.set_pane_title(first.pane_focus, "Preview")
	var strip: Control = first.workspace_view.tab_bar.tabs
	var notes: int = first.get_tabs()[0].id
	var notes_button: Button = strip.buttons[notes]
	await hold(22)
	await start_drag(first)
	var hover := ScreenSpace.of(notes_button, notes_button.size * .45)
	await travel(hover, 22)
	# Let the production spring-loaded hover select the receiving tab.
	app._hover_tab(first, notes)
	await hold(34)
	if not assert_state(first.workspace_layout.active == notes,"Notes opens under the drag"): return
	var view: Control = first.workspace_view
	var drop := ScreenSpace.of(view, view.size * Vector2(.82,.52))
	await travel(drop, 25)
	if not assert_state(app.drag.get("mode") == app.DragMode.MERGE,"Tab previews a pane split"): return
	await hold(12)
	await end_drag(drop)
	await settled(first)
	await hold(35)
	if not assert_state(first.get_tabs().size()==1 and view.pane_rects.size()==2,"One tab contains both panes"): return
	var key := PaneAddress.key(tab)
	var pane: Control = view.panes[key]
	var grip: Vector2 = view.window_point(view.pane_rects[key].position + Vector2(65,13))
	await move_pointer(app.screen_point(root,grip), 20, false)
	app.begin_pane_drag(first,pane,key)
	var target := ScreenSpace.of(strip,Vector2(strip.size.x*.76,strip.size.y*.5))
	await move_pointer(target, 35, true)
	if not assert_state(app.drag.get("mode")==app.DragMode.DOCKED,"Pane previews a new tab"): return
	await hold(8)
	app.finish_drag(target)
	# Capture every frame through the live regroup, including the server round trip.
	for i in 60:
		await capture()
		if not assert_drop_frame(first, key, notes): return
	if not assert_state(first.get_tabs().size() == 2 and view.pane_rects.has(key) and view.pane_rects.size() == 1, "Drop lands directly on the restored Preview tab"): return
	if not assert_state(first.get_tabs().size()==2 and app.hosts.size()==1,"Two tabs restored in one window"): return
	FileAccess.open(OS.get_environment("TAKE")+"/motion.json", FileAccess.WRITE).store_string(JSON.stringify(frames))
	quit(0)

func assert_drop_frame(host: Node, key: String, source_tab: int) -> bool:
	if host.world.tab_fx_t >= 0:
		return assert_state(false, "Pane docking must not play a tab switch")
	if host.workspace_layout.active == source_tab and not host.workspace_view.pane_rects.has(key):
		return assert_state(false, "Source must not resize before the new tab appears")
	return true
