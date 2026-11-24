extends SceneTree
## Real owner, failed spawns, and delayed replies exercise automatic first shells.
var client: Node
var failures := 0
var peers: Array[Node] = []

class DelayedConnection extends "res://scenes/remote/RemoteConnection.gd":
	var hold_creations := false
	var creations := 0
	var completions: Array[Dictionary] = []
	func request_action(kind: String, values: Dictionary = {}, timeout_msec: int = 10000) -> Dictionary:
		if kind == "session_new": creations += 1
		var hold := hold_creations and kind == "session_new"
		var response: Dictionary = await super.request_action(kind, values, timeout_msec)
		if hold:
			var completion := {"released": false, "response": response}
			completions.append(completion)
			while not completion.released: await get_tree().process_frame
		return response

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> bool:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
	return ok

func until(predicate: Callable, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
	return predicate.call()

func observer(descriptor: Dictionary) -> Node:
	var peer := preload("res://scenes/remote/RemoteConnection.gd").new()
	peers.append(peer)
	root.add_child(peer)
	peer.connect_remote(descriptor.url, descriptor.token)
	return peer

func terminal_ready() -> bool:
	return is_instance_valid(client.host) and client.host.layout_root.visible and not client.host.sessions.is_empty() and str(client.host.sessions.values()[0].term.get_text(true).get("text", "")).contains("@@READY@@")

func run() -> void:
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_TEST_REMOTE_DESCRIPTOR")))
	client = preload("res://scenes/remote/RemoteClient.gd").new()
	client.connection.free()
	client.connection = DelayedConnection.new()
	client.managed = true
	client.settings = {"url": descriptor.url, "token": descriptor.token, "transient": true}
	root.add_child(client)
	if not check(await until(terminal_ready), "Connecting to an empty server opens a real shell without confirmation"):
		finish(); return
	check(not client.empty_session.visible, "Successful automatic creation shows no dialog")
	check(client.connection.creations == 1 and client.connection.available_sessions.size() == 1, "Automatic creation starts exactly one session")
	for index in 10: client.connection.sessions_changed.emit()
	await create_timer(.2).timeout
	check(client.connection.creations == 1, "Repeated inventories do not create more sessions")
	await client.connection.request_action("session_kill", {"name": client.connection.workspace})
	if not check(await until(func(): return client.connection.workspace.is_empty() and client.connection.available_sessions.is_empty()), "Last session closes normally"):
		finish(); return
	await create_timer(.2).timeout
	check(client.connection.creations == 1 and not client.creating_session, "Closing the last session does not respawn a shell")
	var a: Node = observer(descriptor)
	var b: Node = observer(descriptor)
	if not check(await until(func(): return a.sessions_known and b.sessions_known), "Concurrent clients both receive the empty inventory"):
		finish(); return
	check(a.available_sessions.is_empty() and b.available_sessions.is_empty(), "Both clients saw zero sessions")
	a.send_action("session_new", -1, {"if_empty": true})
	b.send_action("session_new", -1, {"if_empty": true})
	if not check(await until(func(): return not a.workspace.is_empty() and a.workspace == b.workspace and a.available_sessions.size() == 1 and b.available_sessions.size() == 1), "Concurrent empty-server connections share one session"):
		finish(); return
	var invalid: Dictionary = await a.request_action("session_new", {"if_empty": "yes"})
	check(invalid.get("type") == "error" and a.available_sessions.size() == 1, "Invalid conditional-creation flag is rejected")
	var previous: String = a.workspace
	client.connection.disconnect_remote()
	await a.request_action("session_kill", {"name": previous})
	for peer in peers: peer.disconnect_remote()
	if OS.get_name() != "Windows":
		var shell := OS.get_environment("GRAFFITTY_TEST_SHELL_PATH")
		check(DirAccess.rename_absolute(shell, shell + ".unavailable") == OK, "Temporarily remove the fixture shell")
		await failed_creation(descriptor)
		check(DirAccess.rename_absolute(shell + ".unavailable", shell) == OK, "Restore the fixture shell")
	else:
		print("SKIP Missing-executable injection requires a POSIX fixture")
	client.connection.hold_creations = false
	client.connection.connect_remote(descriptor.url, descriptor.token)
	check(await until(terminal_ready), "Reconnect to an emptied server automatically opens a shell")
	check(client.connection.workspace != previous and client.connection.available_sessions.size() == 1, "Reconnect creates one new session")
	check(not client.empty_session.visible, "Successful reconnect dismisses any creation error")
	finish()

func failed_creation(descriptor: Dictionary) -> void:
	var connection: DelayedConnection = client.connection
	connection.connect_remote(descriptor.url, descriptor.token)
	if not check(await until(func(): return client.empty_session.visible and not client.creating_session), "Failed automatic shell startup shows Retry and Cancel"): return
	var count := connection.creations
	for index in 10: connection.sessions_changed.emit()
	await create_timer(.2).timeout
	check(connection.creations == count, "Failed automatic creation does not retry on every inventory")
	check(client.empty_session.ok_button_text == "Retry", "Creation failure offers Retry")
	connection.hold_creations = true
	client.empty_session.get_ok_button().pressed.emit()
	if not check(await until(func(): return connection.completions.size() == 1), "Retry receives a real server rejection"): return
	client.empty_session.get_cancel_button().pressed.emit()
	connection.completions[0].released = true
	check(await until(func(): return not client.creating_session), "Canceled retry releases its busy state")
	check(not client.empty_session.visible, "Late failure cannot reopen a canceled error dialog")
	var manager: Node = root.get_node("Servers")
	check(manager.visible and manager.cards.size() == 1, "Cancel returns to the isolated server in Servers")
	manager.cards[0].card.select.pressed.emit()
	if not check(await until(func(): return connection.completions.size() == 2), "Selecting the empty server tries automatically again"): return
	count = connection.creations
	client._remote_sessions_changed(true)
	check(client.creating_session and connection.creations == count, "Repeated selection cannot duplicate a pending creation")
	connection.disconnect_remote()
	connection.connect_remote(descriptor.url, descriptor.token)
	if not check(await until(func(): return connection.completions.size() == 3), "Reconnect starts its own automatic request"): return
	connection.completions[1].released = true
	await process_frame
	await process_frame
	check(client.creating_session and not client.empty_session.visible, "Old transport failure cannot alter the new request")
	connection.completions[2].released = true
	check(await until(func(): return not client.creating_session and client.empty_session.visible), "Current transport failure remains retryable")
	client.empty_session.get_ok_button().pressed.emit()
	if not check(await until(func(): return connection.completions.size() == 4), "Another retry reaches the server"): return
	var presentation: RefCounted = root.get_node("TerminalApplication").desktop_presentation(client)
	presentation.park(client)
	connection.completions[3].released = true
	check(await until(func(): return not client.creating_session), "Parked failure clears its busy state")
	check(not client.empty_session.visible, "A parked failure does not open a dialog")
	presentation.restore(root)
	if not check(await until(func(): return connection.completions.size() == 5), "Restoring an empty server retries automatically"): return
	connection.completions[4].released = true
	check(await until(func(): return not client.creating_session and client.empty_session.visible), "Restored failure remains retryable")

func finish() -> void:
	for peer in peers:
		peer.disconnect_remote()
		peer.queue_free()
	if is_instance_valid(client):
		for completion in client.connection.completions: completion.released = true
		client.closing_window = true
		client.connection.disconnect_remote()
		client._release_host()
		client.queue_free()
	await process_frame
	print("REMOTE_EMPTY_SESSION_PASS" if failures == 0 else "REMOTE_EMPTY_SESSION_FAIL")
	quit(0 if failures == 0 else 1)
