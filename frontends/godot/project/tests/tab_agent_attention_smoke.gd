extends "res://tests/tab_close_selection_smoke.gd"
## Real workspace and tab bar with server-owned lifecycle events and receipts.
##
## Headless windows never hold focus, so "in view" here means the host is
## presenting; focus itself is covered in unit/agent_attention_test.gd.
##
##     godot --headless --path . --script tests/tab_agent_attention_smoke.gd -- --shell=/bin/sh

func _event(key: String, name: String) -> void:
	var result: Dictionary = await connection.remote_call(PaneAddress.id(key), "agent.event",
		{"provider":"claude","session_id":"tab-attention-smoke","integrated":true,"event":name})
	check(not result.has("error"), "Server accepted " + name)
	await settled()


func _dot(tab: int) -> Control:
	var button: Button = host.workspace_view.tab_bar.tabs.buttons.get(tab)
	return button.get_node_or_null("Attention") if button != null else null


func _marker(tab: int) -> String:
	var dot := _dot(tab)
	return dot.state if dot != null and dot.visible else ""


func _sync() -> void:
	host.application.agent_attention.refresh()
	for i in 3: await process_frame


func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null: check(false, "Startup host"); quit(1); return
	host = wrapper.host
	connection = wrapper.connection
	await settled()
	var attention: Node = host.application.agent_attention
	check(attention != null, "Application owns the attention tracker")
	if attention == null: quit(1); return
	attention.in_view = func(h): return h.presentation_active
	var first: int = host.workspace_layout.active
	var key: String = host.pane_focus
	var graph: Node = host.agent_api.graph
	await _event(key, "SessionStart")
	await _event(key, "UserPromptSubmit")
	await _sync()
	var second := await add_tab()
	check(host.workspace_layout.active == second, "The agent's tab is in the background")
	check(_marker(first) == "", "A running agent has no marker")
	await _event(key, "Stop")
	await _sync()
	check(_marker(first) == "completed", "A background completion marks its tab green")
	check(_dot(first) != null and _dot(first).count == 1, "One completed agent counts once")
	check("unseen agent completion" in host.workspace_view.tab_bar.tabs.buttons[first].tooltip_text, "The tooltip explains the marker")
	check(_marker(second) == "", "Other tabs stay unmarked")
	await _event(key, "UserPromptSubmit")
	await _event(key, "AwaitingInput")
	await _sync()
	check(_marker(first) == "waiting", "Awaiting input replaces green with yellow")
	host.select_workspace(first, true)
	await settled()
	await _sync()
	check(_marker(first) == "", "Entering the tab with the pane visible clears it")
	host.select_workspace(second, true)
	await settled()
	await _sync()
	check(_marker(first) == "", "A seen wait does not return after leaving")
	await _event(key, "UserPromptSubmit")
	await _event(key, "Stop")
	await _sync()
	check(_marker(first) == "completed", "The next unseen completion marks again")
	graph.import_remote(connection, {})
	await _sync()
	check(_marker(first) == "completed", "A detached graph snapshot is not evidence the result was seen")
	check(error_watch.errors.is_empty(), "No engine or script errors: " + str(error_watch.errors))
	print("TAB_AGENT_ATTENTION_PASS" if failures.is_empty() else "TAB_AGENT_ATTENTION_FAIL")
	quit(0 if failures.is_empty() else 1)
