extends "res://scenes/remote/ConnectionPage.gd"
## Shared responsive server-list presentation. Platform controllers own connections.
signal add_requested
var brand := TextureRect.new()
var connections := VBoxContainer.new()
var list_margin := MarginContainer.new()
var row_scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
var list_items := VBoxContainer.new()
var status := Label.new()
var status_row := HBoxContainer.new()
var empty := Label.new()
var rows := VBoxContainer.new()
var add_server := Button.new()

func _init() -> void:
	scroll_through_controls = true
	max_content_width = 1000.0

func _ready() -> void:
	super()
	heading.hide()
	primary.hide()
	back.hide()
	brand.texture = preload("res://scenes/icons/graffitty-logo.webp")
	brand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	brand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	brand.custom_minimum_size = Vector2(144, 58)
	brand.accessibility_name = "Graffitty"
	header.custom_minimum_size.y = 76
	header.add_child(brand)
	header.show()
	get_viewport().size_changed.connect(_fit_spacing)
	_fit_spacing()
	var layout := scroll.get_parent()
	layout.add_child(list_margin)
	layout.move_child(list_margin, scroll.get_index())
	list_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		list_margin.add_theme_constant_override("margin_" + side, 20)
	var columns := HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	list_margin.add_child(columns)
	connections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connections.custom_maximum_size.x = max_content_width
	columns.add_child(connections)
	scroll.hide()
	row_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row_scroll.begin_touch_drag = func(_travel: Vector2) -> bool: return row_scroll.get_v_scroll_bar().visible
	row_scroll.follow_focus = true
	row_scroll.scroll_deadzone = 8
	list_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_scroll.add_child(list_items)
	list_items.minimum_size_changed.connect(_fit_rows)
	add_child(preload("res://scenes/input/TouchScrollGesture.gd").new(self, row_scroll, connections))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.text = "Connect to a computer running Graffitty."
	connections.add_child(status_row)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(status)
	empty.text = "No saved servers yet."
	empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connections.add_child(row_scroll)
	list_items.add_child(empty)
	rows.add_theme_constant_override("separation", 10)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_items.add_child(rows)
	add_server.text = "+ " + tr("Add server")
	add_server.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	add_server.accessibility_name = tr("Add server")
	add_server.custom_minimum_size.y = 48
	style_button(add_server)
	add_server.pressed.connect(func(): add_requested.emit())
	connections.add_child(add_server)
	get_node("/root/Localization").changed.connect(func():
		add_server.text = "+ " + tr("Add server")
		add_server.accessibility_name = tr("Add server"))

func _fit_spacing() -> void:
	var compact := get_viewport_rect().size.y <= 360
	connections.add_theme_constant_override("separation", 2 if compact else 14)
	var footer := footer_actions.get_parent() as MarginContainer
	for side in ["top", "bottom"]:
		footer.add_theme_constant_override("margin_" + side, 2 if compact else 12)

func _fit_rows() -> void:
	row_scroll.custom_maximum_size.y = list_items.get_combined_minimum_size().y

func available_content_width() -> float:
	if list_margin.is_visible_in_tree():
		return list_items.size.x
	return super()
