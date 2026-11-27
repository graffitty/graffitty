extends "res://tests/session_effects_smoke.gd"
## Clicking an agent in another session switches session and pans to it in one
## flight: the arrival is already framed on the agent's pane, with no second pan
## after landing.

const Layout := preload("res://scenes/WorkspaceLayout.gd")
const PaneAddress := preload("res://scenes/PaneAddress.gd")

func settled(host: Node) -> bool:
	return not host.session_switch_in_progress and host.world.tab_fx_t < 0.0 and not host.world.tab_fx_preparing and host.active_terminal() != null

func in_view(view: Control, key: String) -> bool:
	return view.pane_rects.has(key) and view.workspace_region().canvas_rect(view.navigation_center, view.navigation_zoom).grow(1.0).encloses(view.pane_rects[key])

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		printerr("Requires an isolated session-effects fixture")
		quit(2)
		return
	root.size = Vector2i(1200, 800)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	var peer: Node = client.connection
	for path in ["flat-2d", "flat-3d"]:
		check(host.switch_world(path), "Open world " + path)
		await create_timer(0.5).timeout
		var world: Node = host.world
		var view: Control = host.workspace_view
		host.set_session_transition_effect("fly_away_and_in")
		# In beta, put a second window far outside the saved view.
		await peer.request_action("session_switch", {"name": "beta"})
		check(await until(func(): return settled(host)), path + " prepares beta")
		var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
		group.tree["tiling"] = false
		var keys: Array = Layout.keys(group.tree).filter(func(key): return host.is_terminal_pane(key))
		if keys.size() < 2:
			host.create_terminal_window(host.pane_focus)
			check(await until(func(): return Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree).filter(func(key): return host.is_terminal_pane(key)).size() >= 2, 5.0), path + " beta has two windows")
			group = host.workspace_layout.tab(host.workspace_layout.active)
			group.tree["tiling"] = false
			keys = Layout.keys(group.tree).filter(func(key): return host.is_terminal_pane(key))
		var home: String = keys[0]
		var agent: String = keys[1]
		Layout.find(group.tree, home)["rect"] = Rect2(100, 100, 900, 600)
		var far := Layout.find(group.tree, agent)
		far["rect"] = Rect2(4000, 2500, 400, 300)
		far["stashed"] = false
		far["graph_floating"] = true
		group.focused = home
		host.select_workspace(host.workspace_layout.active, true)
		view.overview = true
		view.navigation_zoom = 0.8
		view.navigation_center = Vector2(550, 400)
		view.refresh()
		view._apply_navigation()
		host.session_backend.commit_workspace(host)
		await create_timer(0.7).timeout
		view.save_navigation()
		check(not in_view(view, agent), path + " the agent's pane starts outside beta's saved view")
		var wire: int = peer.wire_id(PaneAddress.id(agent))
		await peer.request_action("session_switch", {"name": "alpha"})
		check(await until(func(): return settled(host)), path + " returns to alpha")
		# Same request the Agents panel makes for an agent in another session.
		var seen := {"arrival": false, "framed": false, "tween_after_landing": false, "landed": false}
		var observe := func():
			var arriving: bool = (is_instance_valid(world._transition_in) if path == "flat-2d" else not world.tab_fx_in.is_empty())
			if arriving and not seen["arrival"]:
				seen["arrival"] = true
				seen.framed = in_view(view, PaneAddress.key(peer.local_id(wire)))
			if seen.landed and view._inspect_tween != null: seen.tween_after_landing = true
		process_frame.connect(observe)
		host.application.agents._focus_away({"host": host, "peer": peer, "session": "beta", "pane": wire})
		check(await until(func(): return seen["arrival"] and settled(host)), path + " switch to the agent's session lands")
		seen.landed = true
		await create_timer(1.0).timeout
		process_frame.disconnect(observe)
		var key: String = PaneAddress.key(peer.local_id(wire))
		check(host.pane_focus == key, path + " the agent's pane is focused")
		check(seen.framed, path + " the arrival flight is already framed on the agent's pane")
		check(not seen.tween_after_landing, path + " no second pan after the flight lands")
		check(in_view(view, key), path + " the agent's pane is in view")
		await peer.request_action("session_switch", {"name": "alpha"})
		await until(func(): return settled(host))
	client.queue_free()
	await process_frame
	print("AGENT_SESSION_REVEAL_PASS" if failures.is_empty() else "AGENT_SESSION_REVEAL_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
