extends "res://tests/client_scenarios/workspace.gd"
## Android uses real window visibility and native ADB row taps. The runner
## coordinates a separate desktop process through private phase files.

func phase(name: String, extra := {}) -> bool:
	published = {"phase": name, "wire_pane": transport.wire_id(initial_id)}
	published.merge(extra)
	return await until(func(): return FileAccess.file_exists("user://agent-receipts-" + name + ".json"), "Desktop verifies " + name, 45.0)

func attention(pane: String) -> Dictionary:
	var value: Variant = host.agent_api.graph.nodes.get(pane, {}).get("attention")
	return value if value is Dictionary else {}

func row_status(pane: String) -> String:
	for row in host.application.agents.rows:
		if row.key == pane: return row.status
	return ""

func finish_turn(pane: String) -> bool:
	var event := {"provider": "pi", "event": "UserPromptSubmit", "session_id": "receipts-fixture", "prompt": "fixture"}
	await transport.remote_call(initial_id, "agent.event", event)
	if not await until(func(): return row_status(pane) == "working", "Working transition clears the previous completion"): return false
	event.event = "Stop"
	await transport.remote_call(initial_id, "agent.event", event)
	if not await until(func(): return row_status(pane) == "done", "Unviewed completion appears in Android Agents"): return false
	return expect(host.application.agent_attention.marker([pane]).state == "completed" and not attention(pane).get("seen", true), "Android tab and Agents share the unread completion")

func agent_receipts() -> void:
	var pane: String = host.pane_focus
	host.application.agents._sounds.enabled = false
	await run_python("import os,json,subprocess,time\np={'provider':'pi','event':'SessionStart','pid':os.getpid(),'session_id':'receipts-fixture','integrated':True}\nsubprocess.run([os.environ['GRAFFITTY_BIN'],'rpc','agent.event','--params',json.dumps(p)],check=True)\ntime.sleep(180)")
	if not await until(func(): return host.agent_api.graph.nodes.get(pane, {}).get("provider") == "pi", "Real server process registers the fixture agent"): return
	host.create_session()
	if not await until(func(): return host.active_session_id != initial_id, "Android looks away before the agent finishes"): return
	var elsewhere: String = host.pane_focus
	# The command toggles the panel. Start closed, as in agent_attention.
	var existing: Window = preload("res://scenes/AgentsDialog.gd").find(host)
	if existing != null:
		existing._close_panel()
		await wait()
	host.open_command_line("Agents")
	await wait()
	host.command_line._accept()
	await wait()
	var dialog: Window = preload("res://scenes/AgentsDialog.gd").find(host)
	if not expect(dialog != null, "Production Agents panel is open"): return
	# Expand a compact dock so the native tap exercises the full agent row.
	dialog.raise_panel()
	await wait()
	if not await phase("ready"): return
	if not await finish_turn(pane): return
	var first: Dictionary = attention(pane).duplicate()
	await wait(.5)
	var rows: Array = host.application.agents.rows.filter(func(row): return row.key == pane)
	var row_rect: Rect2 = dialog.view.hit_rect("ag-" + str(rows[0].id)) if not rows.is_empty() else Rect2()
	if not expect(row_rect.has_area(), "Unread agent has a rendered touch target"): return
	var at: Vector2 = dialog.view.get_global_transform_with_canvas() * row_rect.get_center()
	if dialog.view.get_window() != root: at += Vector2(dialog.view.get_window().position)
	at = root.get_final_transform() * at
	# Android returns cached bounds while scheduling its UI-thread query.
	if not await until(func(): return JSON.parse_string(manager.terminal_ime.bridge.surfaceBounds()).size() == 4, "Native Android surface bounds are available"): return
	var bounds: Array = JSON.parse_string(manager.terminal_ime.bridge.surfaceBounds())
	published["target"] = {"point": [at.x, at.y], "surface_bounds": bounds}
	if not expect(bounds.size() == 4 and Rect2(0, 0, bounds[2] - bounds[0], bounds[3] - bounds[1]).has_point(at), "Agent row is inside the native Android surface"): return
	if not await phase("unread-phone", {"attention": first, "tap": [roundi(at.x + bounds[0]), roundi(at.y + bounds[1])]}): return
	if not await until(func(): return host.pane_focus == pane, "Native Android tap focuses the agent pane"): return
	if not await until(func(): return attention(pane).get("seen", false), "Server confirms the Android read receipt"): return
	expect(row_status(pane) == "idle" and host.application.agent_attention.marker([pane]).state.is_empty(), "Android removes its completed row and tab marker")
	if not await phase("read-phone", {"attention": attention(pane)}): return
	host.focus_pane(elsewhere)
	await wait()
	if not await finish_turn(pane): return
	expect(attention(pane).event != first.event, "A later completion has a fresh unread event")
	if not await phase("unread-desktop", {"attention": attention(pane)}): return
	if not await until(func(): return attention(pane).get("seen", false), "Desktop receipt reaches Android while another pane is focused"): return
	expect(host.pane_focus == elsewhere, "Remote receipt leaves Android pane focus unchanged")
	expect(row_status(pane) == "idle" and host.application.agent_attention.marker([pane]).state.is_empty(), "Desktop read clears Android Agents and tab markers")
	await phase("read-desktop", {"attention": attention(pane)})
