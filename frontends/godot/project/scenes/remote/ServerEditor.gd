extends VBoxContainer
## The same server fields on desktop and Android; persistence validates in Rust.
signal submitted

var endpoint := LineEdit.new()
var token: LineEdit = preload("res://scenes/SecretInput.gd").new()
var label := LineEdit.new()
var server_alias := LineEdit.new()
var remember := CheckBox.new()
var form_status := Label.new()
var stream_options := {}

var _password_url := ""

func _init() -> void:
	endpoint.focus_exited.connect(_discard_foreign_password)
	token.focus_entered.connect(_discard_foreign_password)
	token.text_changed.connect(func(_value): _password_url = _normalized_endpoint())

func _normalized_endpoint() -> String:
	var address := {"url": endpoint.text.strip_edges()}
	var error := preload("res://scenes/remote/ClientAuthentication.gd").normalize_address(address)
	return str(address.url) if error.is_empty() else ""

func prefill_password(value: String) -> void:
	token.text = value
	_password_url = _normalized_endpoint() if not value.is_empty() else ""

func _discard_foreign_password() -> void:
	if not token.text.is_empty() and not _password_url.is_empty() and _password_url != _normalized_endpoint():
		token.clear()
		_password_url = ""

func password_for_submission() -> String:
	_discard_foreign_password()
	return token.text

func _caption(text: String) -> Label:
	var result := Label.new()
	result.text = text
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return result

func _ready() -> void:
	add_child(_caption("Enable sharing on the computer under Sessions → Remote Access Settings. Enter its network address and password here."))
	for field in [[label, "Server name (optional)", "Use server hostname"], [server_alias, "Server alias (CLI, optional)", "Automatic from hostname"], [endpoint, "Server address", "your-server.local (default port 7183)"], [token, "Password", "Password"]]:
		add_child(_caption(field[1]))
		field[0].placeholder_text = field[2]
		field[0].custom_minimum_size.y = 48
		field[0].text_submitted.connect(func(_text): submitted.emit())
		add_child(field[0])
	remember.text = "Remember password on this device"
	remember.custom_minimum_size.y = 48
	# Wrap on narrow portrait phones instead of widening the form past the screen.
	remember.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(remember)
	for spec in [["max_height", "Chromium stream resolution", [0, 360, 540, 720, 1080, 1440, 2160]], ["fps", "Chromium stream frame rate", [0, 15, 30, 60]], ["bitrate_kbps", "Chromium stream bitrate", [0, 2000, 5000, 10000, 20000, 40000, 80000]]]:
		add_child(_caption(spec[1]))
		var option := OptionButton.new()
		option.custom_minimum_size.y = 48
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for value in spec[2]:
			var title := ("Auto (up to 1440p)" if spec[0] == "max_height" else "Auto") if value == 0 else (str(value) + "p" if spec[0] == "max_height" else str(value) + " FPS" if spec[0] == "fps" else str(value / 1000) + " Mbps")
			option.add_item(title, value)
		stream_options[spec[0]] = option
		add_child(option)
	form_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form_status.add_theme_color_override("font_color", Color("ffc285"))
	add_child(form_status)

func load_settings(settings: Dictionary) -> void:
	label.text = str(settings.get("name", ""))
	server_alias.text = str(settings.get("alias", ""))
	endpoint.text = str(settings.get("url", ""))
	prefill_password("")
	remember.button_pressed = bool(settings.get("remember", true))
	form_status.text = ""
	for key in stream_options:
		var option: OptionButton = stream_options[key]
		option.select(maxi(0, option.get_item_index(int(settings.get("chromium_stream", {}).get(key, 0)))))

func settings() -> Dictionary:
	var stream := {}
	for key in stream_options: stream[key] = stream_options[key].get_selected_id()
	return {"name": label.text.strip_edges(), "alias": server_alias.text.strip_edges(), "url": endpoint.text.strip_edges(), "remember": remember.button_pressed, "chromium_stream": stream}
