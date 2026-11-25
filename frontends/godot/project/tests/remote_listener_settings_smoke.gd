extends SceneTree
## Real IPC owner and encrypted clients. The Python harness owns the server.
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Settings := preload("res://scenes/remote/RemoteAccessSettings.gd")
var failures := 0

class HostApp extends Node:
	var remote_control := preload("res://scenes/remote/RemoteAccessControl.gd").new()
	var hosts := []
	func _init() -> void: add_child(remote_control)
	func refresh_remote_access() -> Error: return await remote_control.refresh()
	func remote_access_enabled() -> bool: return remote_control.enabled

func wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures += 1

func dialog(app: Node) -> Window:
	var window := Settings.new()
	window.application = app
	root.add_child(window)
	await wait_for(func(): return window.visible and window.get_ok_button() != null and is_instance_valid(window.listen_ip))
	return window

func _initialize() -> void: run.call_deferred()

func run() -> void:
	root.gui_embed_subwindows = true
	var file := OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR")
	var owner: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(file))
	var local := Connection.new()
	root.add_child(local)
	local.workspace = "main"
	local.connect_remote(owner.local.url, owner.local.token)
	if not await wait_for(func(): return local.connected):
		check(false, "Private session owner attaches")
		quit(1)
		return
	var app := HostApp.new()
	root.add_child(app)
	app.remote_control.connection = local
	var window := await dialog(app)
	check(window.path == OS.get_environment("GRAFFITTY_TEST_AUTH_PATH"), "Dialog uses the actual owner's private auth file")
	var port := OS.get_environment("GRAFFITTY_TEST_LISTEN_PORT").to_int()
	check(not window.sharing.button_pressed and not window.listen_ip.editable and not window.listen_port.editable and window.password_mode.disabled and window.temporary_length.disabled and window.telegram.disabled and window.temporary.toggle.disabled, "Sharing off locks listener, password, and Telegram controls")
	window.sharing.button_pressed = true
	check(window.listen_ip.editable and window.listen_port.editable and not window.password_mode.disabled and not window.temporary.toggle.disabled and not window.temporary.editable, "Enabling sharing unlocks settings and keeps the generated password read-only")
	window.listen_ip.text = "127.0.0.1"
	window.listen_port.value = port
	window.password_mode.select(window.MANUAL_ONLY)
	window.password.text = "first test-only password"
	window.confirm.text = window.password.text
	await window._save()
	await process_frame
	check(app.remote_control.enabled and app.remote_control.listen_port == port and app.remote_control.token.is_empty(), "Saving opens the requested listener in manual-password mode")
	var remote := Connection.new()
	root.add_child(remote)
	var url := "ws://127.0.0.1:%d" % port
	remote.connect_remote(url,"first test-only password")
	check(await wait_for(func(): return remote.connected), "First manual password authenticates over an encrypted connection")
	window = await dialog(app)
	await window._save()
	await process_frame
	var after_noop: Dictionary = await remote.request_action("sync")
	check(remote.connected and after_noop.type == "ack", "Unchanged Save keeps the remote connection")
	window = await dialog(app)
	window.listen_port.value = OS.get_environment("GRAFFITTY_TEST_TAKEN_PORT").to_int()
	window.password.text = "unapplied test-only password"
	window.confirm.text = window.password.text
	await window._save()
	check(window.visible and not window.status.text.is_empty() and app.remote_control.listen_port == port, "An occupied port leaves the existing listener and dialog open")
	var still_connected: Dictionary = await remote.request_action("sync")
	check(still_connected.type == "ack", "Failed rebind leaves the authenticated remote client connected")
	window.listen_port.value = port
	window.listen_ip.text = "0.0.0.0"
	window.password.text = "second test-only password"
	window.confirm.text = window.password.text
	await window._save()
	await process_frame
	check(app.remote_control.address == "ws://0.0.0.0:%d" % port, "Same-port wildcard rebind takes effect immediately")
	remote.disconnect_remote()
	remote.connect_remote(url,"first test-only password")
	check(await wait_for(func(): return not remote.enabled and not remote.last_error.is_empty()), "The replaced password is rejected")
	remote.connect_remote(url,"second test-only password")
	check(await wait_for(func(): return remote.connected), "New password authenticates on the same owner")
	window = await dialog(app)
	check(not window.status.visible and not window.mode_help.visible, "Manual mode omits redundant password labels")
	var saved_auth := FileAccess.get_file_as_string(window.path)
	window.listen_ip.text = "unfinished"
	window.password.text = "unfinished edit"
	window.sharing.button_pressed = false
	check(not window.password.editable and window.password.toggle.disabled and not window.get_ok_button().disabled, "Disabled password fields leave Save available")
	await window._save()
	await process_frame
	check(not app.remote_control.enabled and local.connected, "Stopping sharing leaves the private client attached")
	check(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_TEST_AUTH_PATH")) == saved_auth, "Disabling sharing preserves the authentication settings")
	local.disconnect_remote()
	remote.disconnect_remote()
	window = await dialog(app)
	check(window.path.is_empty() and window.get_ok_button().disabled, "Disconnected owner cannot fall back to a different auth file")
	window._save()
	window.free()
	for node in [app,remote,local]: node.free()
	await process_frame
	quit(0 if failures == 0 else 1)
