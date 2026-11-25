extends SceneTree
const Browser := preload("res://scenes/remote/ServerBrowserPage.gd")
const Desktop := preload("res://scenes/remote/DesktopServers.gd")
const Card := preload("res://scenes/remote/ServerCard.gd")
class RecordingDesktop extends Desktop:
	var ssh_args := PackedStringArray()
	func _connect_ssh(profile: Dictionary, _in_new_window: bool) -> void: ssh_args = _ssh_arguments(profile)
class App extends Node:
	var show_servers_at_startup := false
	func set_show_servers_at_startup(value: bool) -> void: show_servers_at_startup = value
class Connection extends Node:
	signal state_changed(message: String)
	signal changed
	signal authenticated
	signal session_switched
	signal code_required
	var workspace := "$2"
	var connected := true
	var enabled := true
	var status_source := "Connected"
	var status_args: Array = []
class Client extends Node:
	var federated := false
	var settings := {"shared_local": true}
	var connection := Connection.new()
	var local_return: RefCounted
	var host: Node
	func _init() -> void: add_child(connection)
var errors := preload("res://tests/run.gd").ErrorCapture.new()
var failures: Array[String] = []
func _initialize() -> void:
	var directory := OS.get_cache_dir().path_join("gft-browser-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	OS.add_logger(errors)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func settle() -> void:
	await create_timer(.1).timeout
func run() -> void:
	root.gui_embed_subwindows = true
	root.size = Vector2i(1100, 800)
	var app := App.new()
	root.add_child(app)
	var client := Client.new()
	root.add_child(client)
	var desktop := RecordingDesktop.new()
	desktop.application = app
	root.add_child(desktop)
	desktop.present(client)
	await settle()
	check(desktop.chooser is Browser, "Desktop uses shared Android browser")
	for width in [840, 390, 320]:
		desktop.size = Vector2i(width, 620)
		await settle()
		check(desktop.chooser.size.x <= width, "Browser fits width %d" % width)
		check(desktop.chooser.add_server.is_visible_in_tree(), "Add server visible at width %d" % width)
		desktop.chooser.add_server.pressed.emit()
		await settle()
		check(desktop.form.visible and not desktop.chooser.visible, "Add uses separate Android-style editor page")
		check(desktop.editor.is_visible_in_tree(), "Shared editor is visible")
		desktop.editor.endpoint.text = "ws://example.invalid:7183"
		for field in [desktop.editor.label, desktop.editor.server_alias, desktop.editor.endpoint, desktop.editor.token]:
			desktop.editor.form_status.text = ""
			field.grab_focus()
			var enter := InputEventKey.new()
			enter.keycode = KEY_ENTER
			enter.pressed = true
			desktop.push_input(enter, true)
			enter.pressed = false
			desktop.push_input(enter, true)
			check(desktop.editor.form_status.text == "Enter the current password shown on the computer.", "Enter runs Save and connect validation from a text field")
		desktop.editor.token.text = "unsubmitted-fixture"
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		desktop.push_input(escape, true)
		check(desktop.chooser.visible and not desktop.form.visible and desktop.editor.token.text.is_empty(), "Back returns to cards and clears unsubmitted secret")
	var card := Card.new()
	desktop.chooser.rows.add_child(card)
	card.update_identity({"url": "ws://example.invalid:7183", "name": "Fixture"})
	await settle()
	check(card.size.x <= desktop.chooser.available_content_width(), "Shared server card fits narrow layout")
	var auth := preload("res://scenes/remote/ClientAuthentication.gd")
	client.add_to_group("shared_presentations")
	client.settings = {"url": "ws://127.0.0.1:39871", "credential_id": "ssh:dev@fixture",
		"name": "Fixture", "alias": "build", "transient": true, "token": "fixture-secret", "initial_session": "$1"}
	auth.bind(client, client.connection, client.settings, false, func(error): failures.append(str(error)))
	client.connection.session_switched.emit()
	desktop.present(client)
	check(auth.saved_connections().is_empty(), "Opening an SSH tunnel offers a profile without saving it")
	check(desktop.cards.size() == 1 and desktop.cards[0].card.address.text == "ssh://dev@fixture", "SSH card identifies the destination without its forwarded port")
	desktop.cards[0].card.edited.emit()
	var profiles: Array = auth.saved_connections()
	check(profiles.size() == 1 and profiles[0].url == "ssh://dev@fixture" and profiles[0].get("initial_session") == "$2", "Explicit save records the attached session and stable destination")
	check(not "39871" in JSON.stringify(profiles) and not "fixture-secret" in JSON.stringify(profiles), "Saved SSH profile excludes tunnel endpoint and token")
	client.connection.workspace = "$3"
	client.connection.session_switched.emit()
	profiles = auth.saved_connections()
	check(profiles.size() == 1 and profiles[0].get("initial_session") == "$3", "Session switches update only the saved SSH profile")
	client.settings.url = "ws://127.0.0.1:39222"
	desktop.present(client)
	check(desktop.cards.size() == 1, "Replacement tunnel coalesces with the saved host")
	client.connection.connected = false
	client.connection.enabled = false
	desktop.connect_server(client, "ssh://dev@fixture")
	check(desktop.ssh_args == PackedStringArray(["remote", "connect", "--stdio", "--workspace", "$3", "--alias", "build", "dev@fixture"]), "Sessions reopens saved SSH host through an owned tunnel with its session and alias")
	client.connection.connected = true
	auth.remove_connection({"url": "ssh://dev@fixture"})
	client.connection.workspace = "$4"
	client.connection.session_switched.emit()
	check(auth.saved_connections().is_empty(), "Session switching cannot recreate a forgotten profile")
	var close := InputEventKey.new()
	close.keycode = KEY_ESCAPE
	close.pressed = true
	desktop.push_input(close, true)
	check(not desktop.visible and client.connection.connected, "Closing manager preserves client connection")
	desktop.queue_free()
	client.queue_free()
	app.queue_free()
	await settle()
	failures.append_array(errors.take())
	OS.remove_logger(errors)
	print("SERVER_BROWSER_PASS" if failures.is_empty() else "SERVER_BROWSER_FAIL " + str(failures))
	quit(0 if failures.is_empty() else 1)
