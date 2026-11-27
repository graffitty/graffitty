extends TextureRect
## A turning loader icon shown while the user has to wait.
## Shares the agent status spinner's icon and phase.
const AgentStatusBadge := preload("res://scenes/AgentStatusBadge.gd")


func _init(diameter := 16.0, tint := Color("a7a9b5")) -> void:
	texture = AgentStatusBadge.icon("loader-circle.svg")
	expand_mode = EXPAND_IGNORE_SIZE
	stretch_mode = STRETCH_KEEP_ASPECT_CENTERED
	custom_minimum_size = Vector2(diameter, diameter)
	size_flags_vertical = SIZE_SHRINK_CENTER
	modulate = tint
	mouse_filter = MOUSE_FILTER_IGNORE
	visibility_changed.connect(_sync)
	resized.connect(func(): pivot_offset = size * 0.5)


func _ready() -> void:
	_sync()


func _sync() -> void:
	set_process(visible)


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		rotation = AgentStatusBadge.spinner_angle(Time.get_ticks_usec() / 1_000_000.0)
