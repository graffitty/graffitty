extends SceneTree
## The Sessions menu restores in this app: one new window, no success dialog.
## Run by tests/godot/test_single_app.py with -- --checkpoint=<file> on a private server.
var failures: Array[String] = []


func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var app: Node = root.get_node("TerminalApplication")
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 20000
	while (wrapper.host == null or wrapper.host.active_terminal() == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if wrapper.host == null:
		check(false, "The first window opens")
		quit(1)
		return
	var checkpoint := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--checkpoint="): checkpoint = argument.trim_prefix("--checkpoint=")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(checkpoint))
	app.checkpoints.menu_action(wrapper.host, {"action": "RestoreCheckpoint", "tag": "manual", "checkpoint": checkpoint})
	deadline = Time.get_ticks_msec() + 40000
	while (app.hosts.size() < 2 or app.checkpoints.importing or app.checkpoints.busy) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(.5).timeout
	check(app.hosts.size() == 2, "Restore opens exactly one window: %d" % app.hosts.size())
	check(app.checkpoints.restored_sessions.size() == saved.windows.size(), "Every saved session is restored: " + str(app.checkpoints.restored_sessions))
	await wrapper.connection.request_action("sync")
	var listed: Array = wrapper.connection.available_sessions.map(func(row): return str(row.id))
	check(app.checkpoints.restored_sessions.all(func(id): return id in listed), "Windowless sessions are listed under Sessions")
	var dialogs: Array = root.find_children("*", "AcceptDialog", true, false).filter(func(dialog): return dialog.visible and dialog.title == "Checkpoints")
	check(dialogs.is_empty(), "A successful restore shows no dialog")
	print("CHECKPOINT_MENU_RESTORE " + ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
