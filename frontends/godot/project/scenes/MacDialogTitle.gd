extends Control
## Title bar for native macOS dialogs and tool windows. Graffitty moves the
## window itself.
##
## A Godot subwindow dragged by the native macOS title bar moves only a few
## times a second on macOS 27. A move set each frame from the app stays smooth,
## as dockable panels already show. The window extends its content under the
## title bar and keeps the real traffic lights. This bar draws the title and
## moves the window while the left button is held.
##
## Dialogs (AcceptDialog) get their content pushed below the bar here. Other
## windows lay out their content below `height(window)` themselves.

## Godot centers the traffic lights 14 pt below the top edge.
const BAR_POINTS := 28.0
const TITLE_POINTS := 13.0
const META := &"mac_dialog_title"

var window: Window
## Painted behind the title; dialogs leave it clear over their own panel.
var background := Color.TRANSPARENT
var _base_panel: StyleBox
var _grab := Vector2i.ZERO
var _restore_transient := false
var _dragging := false


static func applies(target: Window) -> bool:
	return (
		DisplayServer.get_name() == "macOS"
		and DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE)
		and target.is_inside_tree() and not target.is_embedded()
	)


## Adds the bar once, then refits it to the window's current scale.
static func attach(target: Window, fill := Color.TRANSPARENT) -> void:
	if not applies(target): return
	var bar: Control = target.get_meta(META) if target.has_meta(META) else null
	if not is_instance_valid(bar):
		bar = new()
		bar.window = target
		bar.background = fill
		target.set_meta(META, bar)
		# Called from node_added, before the window's own children enter the tree.
		target.add_child.call_deferred(bar, false, Node.INTERNAL_MODE_BACK)
		target.visibility_changed.connect(bar._visibility_changed)
		# Runs after the owner's own popup handlers have set the content scale.
		target.about_to_popup.connect(bar.fit)
	bar.fit()


## The bar's height in the window's logical units; 0 without a bar.
static func height(target: Window) -> float:
	var bar: Control = target.get_meta(META) if target.has_meta(META) else null
	return bar.bar_height() if is_instance_valid(bar) else 0.0


func _ready() -> void:
	name = "MacDialogTitle"
	mouse_filter = MOUSE_FILTER_STOP
	window.title_changed.connect(queue_redraw)
	window.titlebar_changed.connect(queue_redraw)
	resized.connect(queue_redraw)
	window.size_changed.connect(_place)
	_place()


## Pixels per macOS point in the window's logical units.
func points() -> float:
	return DisplayServer.screen_get_max_scale() / window.content_scale_factor


func bar_height() -> float:
	return ceilf(BAR_POINTS * points())


func fit() -> void:
	window.extend_to_title = true
	# AcceptDialog lays out every child that is not top-level as content.
	set_as_top_level(true)
	_place()
	if window is AcceptDialog:
		# AcceptDialog places its content below the panel's top margin.
		if _base_panel == null:
			_base_panel = window.get_theme_stylebox(&"panel", &"AcceptDialog")
		var panel: StyleBox = _base_panel.duplicate()
		panel.content_margin_top = _base_panel.get_margin(SIDE_TOP) + bar_height()
		window.add_theme_stylebox_override(&"panel", panel)
	queue_redraw()


func _place() -> void:
	position = Vector2.ZERO
	size = Vector2(window.size.x / window.content_scale_factor, bar_height())


## Runs right after Godot creates the native window, before the first frame.
func _visibility_changed() -> void:
	if not window.visible:
		_finish()
		return
	var id := window.get_window_id()
	if id < 0: return
	# Godot applies extend_to_title after creating the window, which keeps the
	# frame and grows the content before Godot listens for resizes. Restore the
	# planned content size so the content again equals the whole frame.
	DisplayServer.window_set_size(window.size, id)
	if window is AcceptDialog:
		var frame: RefCounted = ClassDB.instantiate(&"NativeWindowFrame") if ClassDB.class_exists(&"NativeWindowFrame") else null
		if frame != null and frame.has_method(&"dialog_buttons"):
			frame.dialog_buttons(DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, id))
	queue_redraw()


func _draw() -> void:
	if background.a > 0.0: draw_rect(Rect2(Vector2.ZERO, size), background)
	var text := window.atr(window.title)
	if text.is_empty(): return
	var font := get_theme_font(&"title_font", &"Window")
	var scale := points()
	# Center over the whole bar, as AppKit does, but never under the buttons.
	var reserved := 0.0
	if window.get_window_id() >= 0:
		reserved = DisplayServer.window_get_safe_title_margins(window.get_window_id()).x / window.content_scale_factor
	var inset := reserved + 8.0 * scale
	var line := TextLine.new()
	line.add_string(text, font, roundi(TITLE_POINTS * scale))
	line.width = maxf(0.0, size.x - inset * 2.0)
	line.alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.draw(get_canvas_item(), Vector2(inset, (size.y - line.get_size().y) * 0.5), get_theme_color(&"title_color", &"Window"))


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed: return
	accept_event()
	if event.double_click:
		# Dialogs cannot zoom; other windows zoom like the main window's title.
		if not window is AcceptDialog and not window.unresizable:
			preload("res://scenes/WindowGeometry.gd").toggle_fit(window)
		return
	if _dragging: return
	_dragging = true
	_grab = DisplayServer.mouse_get_position() - window.position
	# AppKit throttles child-window moves; detach for this gesture only.
	_restore_transient = window.transient
	window.transient = false
	get_tree().process_frame.connect(_drag_frame)


func _drag_frame() -> void:
	if not is_instance_valid(window) or not window.visible:
		_finish()
		return
	var target := DisplayServer.mouse_get_position() - _grab
	if window.position != target: window.position = target
	if not DisplayServer.mouse_get_button_state() & MOUSE_BUTTON_MASK_LEFT: _finish()


func _finish() -> void:
	if not _dragging: return
	_dragging = false
	if get_tree().process_frame.is_connected(_drag_frame):
		get_tree().process_frame.disconnect(_drag_frame)
	if _restore_transient and is_instance_valid(window): window.transient = true
	_restore_transient = false


func _exit_tree() -> void:
	_finish()
