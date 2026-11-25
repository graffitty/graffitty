extends AcceptDialog
## Passwords are registered locally; only the OPAQUE verifier is persisted.
const SecretInput := preload("res://scenes/SecretInput.gd")
var password: LineEdit = SecretInput.new()
var confirm: LineEdit = SecretInput.new()
const TEMPORARY := 0
const MANUAL_ONLY := 1
var options := VBoxContainer.new()
var sharing: CheckBox
var listen_ip: LineEdit
var listen_port: SpinBox
var password_mode := OptionButton.new()
var password_fields := VBoxContainer.new()
var temporary_fields := VBoxContainer.new()
var mode_help := Label.new()
var permanent_configured := false
var telegram := CheckBox.new()
var profile := LineEdit.new()
var bot_token: LineEdit = SecretInput.new()
var chat_id := LineEdit.new()
var telegram_fields := VBoxContainer.new()
var telegram_status := Label.new()
var loaded_telegram_credential := ""
var saved_telegram_token := false
var status := Label.new()
var temporary_length := OptionButton.new()
var temporary: LineEdit = SecretInput.new()
var application: Node
var authentication: RefCounted
var path := ""


func _ready() -> void:
	var owner_ready := false
	if application.has_method("refresh_remote_access"):
		owner_ready = await application.refresh_remote_access() == OK
		path = application.remote_control.auth_path if owner_ready else ""
	title = "Remote Access Settings"
	ok_button_text = "Save"
	dialog_hide_on_ok = false
	authentication = ClassDB.instantiate("RemoteAuth")
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(520, maxf(200, minf(600, get_tree().root.get_visible_rect().size.y - 120)))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	status.hide()
	fields.add_child(status)
	if application.has_method("refresh_remote_access"):
		sharing = CheckBox.new()
		listen_ip = LineEdit.new()
		listen_port = SpinBox.new()
		sharing.text = "Enable remote access"
		fields.add_child(sharing)
		sharing.disabled = not owner_ready
		var ip_label := Label.new()
		ip_label.text = "Listen IP address"
		options.add_child(ip_label)
		options.add_child(listen_ip)
		var port_label := Label.new()
		port_label.text = "Listen port"
		options.add_child(port_label)
		listen_port.min_value = 1
		listen_port.max_value = 65535
		options.add_child(listen_port)
		if owner_ready:
			sharing.button_pressed = application.remote_control.enabled
			listen_ip.text = application.remote_control.listen_ip
			listen_port.value = application.remote_control.listen_port
	fields.add_child(options)
	var mode_label := Label.new()
	mode_label.text = "Password access"
	options.add_child(mode_label)
	password_mode.add_item("Temporary password", TEMPORARY)
	password_mode.add_item("Manual password only", MANUAL_ONLY)
	options.add_child(password_mode)
	mode_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	options.add_child(mode_help)
	options.add_child(temporary_fields)
	options.add_child(password_fields)
	password_mode.item_selected.connect(func(_index): _update_password_mode())
	var length_label := Label.new()
	length_label.text = "Temporary password length"
	temporary_fields.add_child(length_label)
	for length in [6, 8, 10]:
		temporary_length.add_item(tr("%d characters") % length, length)
	temporary_fields.add_child(temporary_length)
	temporary.editable = false
	temporary_fields.add_child(temporary)
	temporary.hide()
	if application.remote_access_enabled() and not application.remote_control.token.is_empty():
		temporary.text = application.remote_control.token
		temporary.show()
		var description := Label.new()
		description.text = "Temporary password (changes when sharing restarts)"
		temporary_fields.add_child(description)
		var actions := HBoxContainer.new()
		var copy := Button.new()
		copy.text = "Copy"
		copy.pressed.connect(func(): DisplayServer.clipboard_set(temporary.text))
		actions.add_child(copy)
		var regenerate := Button.new()
		regenerate.text = "Regenerate"
		regenerate.tooltip_text = "Replace the temporary password and disconnect remote clients"
		regenerate.pressed.connect(_regenerate_temporary)
		actions.add_child(regenerate)
		temporary_fields.add_child(actions)
	password.placeholder_text = "New password (leave blank to keep)"
	confirm.placeholder_text = "Confirm new password"
	password_fields.add_child(password)
	password_fields.add_child(confirm)
	telegram.text = "Require Telegram two-factor authentication (2FA)"
	options.add_child(telegram)
	options.add_child(telegram_fields)
	profile.text = "graffitty-2fa"
	bot_token.placeholder_text = "Bot token from @BotFather"
	chat_id.placeholder_text = "Numeric chat ID, e.g. 123456789"
	for field in [["Credential name", profile], ["Telegram bot token", bot_token], ["Destination chat ID", chat_id]]:
		var caption := Label.new()
		caption.text = field[0]
		telegram_fields.add_child(caption)
		telegram_fields.add_child(field[1])
	telegram_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	telegram_fields.add_child(telegram_status)
	telegram.toggled.connect(func(enabled):
		telegram_fields.visible = enabled
		if enabled: _load_telegram_settings()
	)
	profile.focus_exited.connect(_load_telegram_settings)
	var settings: Dictionary = JSON.parse_string(authentication.settings(path)) if not path.is_empty() else {"error":application.remote_control.last_error}
	if settings.has("error"):
		_show_status(settings.error)
		get_ok_button().disabled = true
	else:
		permanent_configured = bool(settings.permanent)
		password_mode.select(MANUAL_ONLY if permanent_configured else TEMPORARY)
		temporary_length.select(temporary_length.get_item_index(int(settings.temporary_password_length)))
		telegram.set_pressed_no_signal(settings.get("telegram_credential") is String)
		if telegram.button_pressed:
			profile.text = settings.telegram_credential
		chat_id.text = str(settings.get("chat_id") if settings.get("chat_id") is String else "")
	if sharing != null:
		sharing.toggled.connect(_set_options_enabled)
		_set_options_enabled(sharing.button_pressed)
	_update_password_mode()
	telegram_fields.visible = telegram.button_pressed
	if telegram.button_pressed: _load_telegram_settings()
	Engine.get_main_loop().root.get_node("Localization").changed.connect(_refresh_language)
	if application.has_method("refresh_remote_access") and not owner_ready:
		_show_status(application.remote_control.last_error)
		get_ok_button().disabled = true
	confirmed.connect(_save)
	canceled.connect(queue_free)
	popup_centered.call_deferred()


func _update_password_mode() -> void:
	temporary.revealed = false
	var manual := password_mode.get_selected_id() == MANUAL_ONLY
	password_fields.visible = manual
	temporary_fields.visible = not manual
	password.placeholder_text = "New manual password (leave blank to keep)" if permanent_configured else "Set manual password (at least 8 characters)"
	mode_help.visible = not manual
	mode_help.text = "A new temporary password is generated when sharing restarts."
	if not manual and permanent_configured:
		mode_help.text = tr(mode_help.text) + " " + tr("Saving this mode removes your manual password.")


func _set_options_enabled(enabled: bool) -> void:
	options.modulate.a = 1.0 if enabled else 0.5
	listen_port.editable = enabled
	for field in options.find_children("*", "LineEdit", true, false):
		field.editable = enabled and field != temporary
		if not enabled and field is SecretInput: field.revealed = false
	for button in options.find_children("*", "BaseButton", true, false):
		button.disabled = not enabled


func _show_status(message: String) -> void:
	status.text = message
	status.visible = not message.is_empty()


func _save() -> void:
	if path.is_empty() or get_ok_button().disabled: return
	var remote := {}
	if application.has_method("refresh_remote_access"):
		if not sharing.button_pressed:
			# Turning sharing off keeps the saved listener and credentials.
			await _apply_remote({"enabled": false, "bind_address": application.remote_control.listen_ip, "port": application.remote_control.listen_port})
			return
		var ip := listen_ip.text.strip_edges()
		if not ip.is_valid_ip_address():
			_show_status("Enter a valid IPv4 or IPv6 address")
			return
		remote = {"enabled":true,"bind_address":ip,"port":int(listen_port.value)}
	var manual := password_mode.get_selected_id() == MANUAL_ONLY
	if manual and not permanent_configured and password.text.is_empty():
		_show_status("Set a manual password before disabling temporary passwords")
		return
	if manual and password.text != confirm.text:
		_show_status("Passwords do not match")
		return
	if telegram.button_pressed and profile.text.strip_edges().is_empty():
		_show_status("Enter a credential name")
		return
	if telegram.button_pressed and (not bot_token.text.is_empty() or saved_telegram_token and not chat_id.text.is_empty()):
		var credentials: Dictionary = JSON.parse_string(authentication.save_telegram_credentials(profile.text.strip_edges(), bot_token.text.strip_edges(), chat_id.text.strip_edges()))
		if credentials.has("error"):
			_show_status(credentials.error)
			return
		bot_token.clear()
	# Build the verifier privately. The owner commits it together with the
	# listener settings, so a rejected address keeps the previous password.
	var staged := path
	if not remote.is_empty():
		staged = path + "." + Crypto.new().generate_random_bytes(12).hex_encode() + ".tmp"
		if FileAccess.file_exists(path) and DirAccess.copy_absolute(path, staged, 384) != OK:
			_show_status("Cannot read remote authentication settings")
			return
	var result: Dictionary = JSON.parse_string(authentication.save_settings(staged, password.text if manual else "", not manual, profile.text.strip_edges() if telegram.button_pressed else "", chat_id.text.strip_edges() if telegram.button_pressed else "", temporary_length.get_selected_id()))
	if result.has("error"):
		if staged != path: DirAccess.remove_absolute(staged)
		_show_status(result.error)
		return
	if not remote.is_empty():
		var auth: Variant = JSON.parse_string(FileAccess.get_file_as_string(staged))
		DirAccess.remove_absolute(staged)
		if not auth is Dictionary:
			_show_status("Cannot read remote authentication settings")
			return
		auth.version = int(auth.version)
		auth.temporary_password_length = int(auth.temporary_password_length)
		await _apply_remote(remote, auth)
		return
	queue_free()


func _apply_remote(remote: Dictionary, auth: Dictionary = {}) -> void:
	get_ok_button().disabled = true
	var error: Error = await application.remote_control.reload(false, remote, auth)
	get_ok_button().disabled = false
	if error != OK:
		_show_status(application.remote_control.last_error)
		return
	for host in application.hosts: host.ui_changed.emit()
	queue_free()


func _load_telegram_settings() -> void:
	if not telegram.button_pressed or profile.text.strip_edges().is_empty(): return
	if loaded_telegram_credential == profile.text.strip_edges(): return
	loaded_telegram_credential = profile.text.strip_edges()
	var saved: Dictionary = JSON.parse_string(authentication.telegram_settings(profile.text.strip_edges()))
	bot_token.clear()
	saved_telegram_token = bool(saved.get("saved", false))
	if saved_telegram_token: chat_id.text = str(saved.get("chat_id", ""))
	bot_token.placeholder_text = "Saved token (leave blank to keep)" if saved.get("saved", false) else "Bot token from @BotFather"
	telegram_status.text = str(saved.get("error", "Bot credentials saved" if saved.get("saved", false) else ""))
	telegram_status.visible = not telegram_status.text.is_empty()


func _regenerate_temporary() -> void:
	if path.is_empty(): return
	temporary.revealed = false
	var current: Dictionary = JSON.parse_string(authentication.settings(path))
	if current.has("error"):
		_show_status(current.error)
		return
	var current_profile: String = current.telegram_credential if current.get("telegram_credential") is String else ""
	var result: Dictionary = JSON.parse_string(authentication.save_settings(path, "", false, current_profile, str(current.get("chat_id") if current.get("chat_id") is String else ""), temporary_length.get_selected_id()))
	if result.has("error"):
		_show_status(result.error)
		return
	var err: Error = await application.remote_control.reload(true)
	temporary.text = application.remote_control.token if err == OK else ""
	_show_status("Temporary password regenerated" if err == OK else tr("Could not update remote access: %s") % error_string(err))

func _refresh_language() -> void:
	for index in temporary_length.item_count:
		temporary_length.set_item_text(index, tr("%d characters") % temporary_length.get_item_id(index))
	_update_password_mode()
