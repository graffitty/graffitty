extends RefCounted
const Store := preload("res://scenes/remote/CredentialStore.gd")
const Paths := preload("res://graffitty/paths.gd")


static func account(url: String, credential_id := "") -> String:
	# Endpoint-scoped: never reuse a password for another server automatically.
	return credential_id if not credential_id.is_empty() else url.strip_edges().trim_suffix("/")


static func connection_path() -> String:
	return Paths.stdpath("state").path_join("remote-connections.json")


static func read_connections() -> Dictionary:
	return JSON.parse_string(ClassDB.instantiate("RemoteAuth").saved_connections(connection_path()))


static func saved_connections() -> Array:
	return read_connections().get("connections", [])


## The SSH process owns its temporary WebSocket. Only its destination identifies the profile.
static func profile_url(settings: Dictionary) -> String:
	var identity := str(settings.get("credential_id", ""))
	if settings.get("transient", false) and identity.begins_with("ssh:") and identity.length() > 4:
		return "ssh://" + identity.substr(4)
	return str(settings.get("url", ""))


static func launch_connections(args: PackedStringArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for arg in args:
		var multiple := arg.begins_with("--remote-connections=")
		if not multiple and not arg.begins_with("--remote-connection="): continue
		var path := arg.substr(arg.find("=") + 1)
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not value is Dictionary: continue
		var connections: Variant = value.get("connections", []) if multiple else [value]
		if not connections is Array: continue
		for settings in connections:
			if settings is Dictionary and settings.get("url") is String:
				result.append(settings)
	return result


static func reorder_servers(source: String, target: String, before: bool) -> String:
	var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").reorder_connections(connection_path(), source, target, before))
	var error := str(result.get("error", ""))
	if error.is_empty():
		_notify_connections()
		Engine.get_main_loop().call_group_flags(SceneTree.GROUP_CALL_DEFERRED, &"server_order_views", &"saved_servers_reordered")
	return error


static func remember(settings: Dictionary, password: String) -> String:
	var result := Store.new().credential("set", account(str(settings.url), str(settings.get("credential_id", ""))), password)
	if not result.get("ok", false):
		return str(result.get("error", "System credential store operation failed"))
	# SSH owns its temporary tunnel. Remember the host secret, not the dead port.
	if bool(settings.get("transient", false)):
		return ""
	return save_connection(settings.merged({"remember": true}, true))


static func save_connection(settings: Dictionary) -> String:
	if bool(settings.get("transient", false)): return ""
	var ssh := str(settings.url).begins_with("ssh://")
	if not ssh:
		var error := normalize_address(settings)
		if not error.is_empty(): return error
	var entry := {"alias": settings.get("alias", ""), "chromium_stream": settings.get("chromium_stream", {}), "url": settings.url, "name": settings.get("name", ""), "hostname": settings.get("hostname", ""), "platform": settings.get("platform", ""), "username": settings.get("username", ""), "remember": bool(settings.get("remember", false))}
	if ssh: entry.initial_session = str(settings.get("initial_session", ""))
	var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").save_connection(connection_path(), entry))
	if result.has("connection"): settings.alias = result.connection.alias
	if str(result.get("error", "")).is_empty(): _notify_connections()
	return str(result.get("error", ""))


static func normalize_address(settings: Dictionary) -> String:
	var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").normalize_server_url(str(settings.get("url", ""))))
	if result.has("error"): return str(result.error)
	settings.url = result.url
	return ""


static func remove_connection(settings: Dictionary) -> String:
	return forget(str(settings.url), str(settings.get("credential_id", "")))


static func clear_password(url: String, credential_id := "") -> String:
	var result := Store.new().credential("delete", account(url, credential_id))
	return "" if result.get("ok", false) else str(result.get("error", "Cannot remove saved password"))


static func forget(url: String, credential_id := "") -> String:
	if not url.begins_with("ssh://"):
		var error := clear_password(url, credential_id)
		if not error.is_empty(): return error
	var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").remove_connection(connection_path(), url))
	if result.get("changed", false): _notify_connections()
	return str(result.get("error", ""))


static func _notify_connections() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null: tree.call_group(&"mod_data_views", &"saved_connections_changed")


static func password(url: String, credential_id := "") -> Dictionary:
	return Store.new().credential("get", account(url, credential_id))


static func bind(owner: Node, connection: Node, settings: Dictionary, remember_password: bool, on_save_error: Callable) -> void:
	var url := profile_url(settings)
	if url.begins_with("ssh://"):
		connection.session_switched.connect(func():
			var result: Dictionary = JSON.parse_string(ClassDB.instantiate("RemoteAuth").update_saved_session(connection_path(), url, connection.workspace))
			if result.has("error"): on_save_error.call(str(result.error))
			elif result.get("changed", false):
				_notify_connections()
				owner.get_tree().call_group_flags(SceneTree.GROUP_CALL_DEFERRED, &"server_order_views", &"saved_servers_reordered"))
	connection.authenticated.connect(func():
		for field in ["hostname", "platform", "username"]:
			settings[field] = connection.get("server_" + field)
		var save_error := save_connection(settings)
		if not save_error.is_empty(): on_save_error.call(save_error)
		connection.server_alias = str(settings.get("alias", ""))
		if remember_password:
			var error := remember(settings, connection.token)
			if not error.is_empty():
				on_save_error.call(error)
	)
	connection.code_required.connect(func():
		var dialog := ConfirmationDialog.new()
		dialog.title = "Telegram two-factor authentication (2FA)"
		dialog.ok_button_text = "Verify"
		var code := LineEdit.new()
		code.placeholder_text = "6-digit code from Telegram"
		code.max_length = 6
		code.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
		code.custom_minimum_size.x = 300
		dialog.add_child(code)
		owner.add_child(dialog)
		dialog.confirmed.connect(func():
			connection.submit_code(code.text)
			code.clear()
			dialog.queue_free()
		)
		dialog.canceled.connect(func():
			connection.disconnect_remote()
			dialog.queue_free()
		)
		connection.tree_exiting.connect(func():
			if is_instance_valid(dialog):
				dialog.queue_free()
		, CONNECT_ONE_SHOT)
		dialog.popup_centered()
		code.grab_focus()
	)
