extends Control
## Editable transcript with a sticky end. Layout changes never count as user
## scrolling; only gestures/scrollbar input change whether new words are followed.
## The shared Rust scroller owns drag, momentum and rubber-band motion.

const DRAG_SLOP := 12.0
var view := TextEdit.new()
var elastic: RefCounted = ClassDB.instantiate("ElasticScroller")
var follow_end := true
var _review_offset := 0.0
var _restoring := false
var _restore_pending := false
var _finger := -1
var _origin := Vector2.ZERO
var _dragging := false
var _bar_dragging := false
var _bar_skin: Control


func _init() -> void:
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.scroll_past_end_of_file = false
	view.scroll_smooth = false
	add_child(view)
	view.gui_input.connect(_view_input)
	view.resized.connect(_queue_restore)
	var bar := view.get_v_scroll_bar()
	bar.changed.connect(_queue_restore)
	bar.value_changed.connect(func(_value):
		if _bar_dragging and not _restoring: _remember_scroll())
	visibility_changed.connect(func():
		if not is_visible_in_tree(): _stop())
	set_process(false)


func set_transcript(text: String) -> void:
	if view.text == text: return
	_review_offset = view.scroll_vertical
	_restoring = true
	view.text = text
	view.scroll_vertical = _review_offset
	_restoring = false
	_queue_restore(true)


func reset() -> void:
	_stop()
	follow_end = true
	_review_offset = 0.0


func _end() -> float:
	var bar := view.get_v_scroll_bar()
	return maxf(bar.max_value - bar.page, 0.0)


func _at_end() -> bool:
	# Less than one pixel of rounding, not a whole wrapped line.
	return (_end() - view.scroll_vertical) * view.get_line_height() <= 1.0


func _queue_restore(force := false) -> void:
	# Draft editing keeps TextEdit's normal caret/selection scrolling.
	if view.editable and not _restoring and not force: return
	if _restore_pending: return
	_restore_pending = true
	_restore.call_deferred()


func _restore() -> void:
	_restore_pending = false
	_restoring = true
	# The range includes soft-wrapped rows and is read after text/layout changes.
	if follow_end and not elastic.is_active() and not _bar_dragging:
		view.scroll_vertical = _end()
	else:
		view.scroll_vertical = _review_offset
	_review_offset = view.scroll_vertical
	_restoring = false


func _remember_scroll() -> void:
	_review_offset = view.scroll_vertical
	follow_end = _at_end()


func _offset() -> float:
	return view.scroll_vertical * view.get_line_height()


func _limits() -> Vector2:
	return Vector2(_end() * view.get_line_height(), size.y)


func _draw_offset(offset: float) -> void:
	var row := maxf(view.get_line_height(), 1.0)
	view.scroll_vertical = offset / row
	var pull: float = elastic.get_stretch()
	# Move both edges together: changing offsets separately momentarily resizes
	# TextEdit and clamps away the fractional last row at the bottom.
	view.position.y = -pull
	if _bar_skin == null and pull != 0.0:
		_bar_skin = preload("res://scenes/ElasticBarSkin.gd").attach(view.get_v_scroll_bar(), elastic)
	if _bar_skin != null: _bar_skin.set_stretch(pull / row)
	set_process(elastic.is_active())


func _scroll_to(offset: float) -> void:
	_draw_offset(offset)
	_remember_scroll()


func _process(_dt: float) -> void:
	var limits := _limits()
	var before := _offset()
	var offset: float = elastic.advance(before, limits.x, limits.y)
	_draw_offset(offset)
	# A stationary finger/pull must not change follow state just because the
	# transcript grew. A moving fling is still the user's scroll.
	if not is_equal_approx(before, offset): _remember_scroll()
	if not elastic.is_active(): _queue_restore()


func _stop() -> void:
	elastic.stop()
	_finger = -1
	_dragging = false
	_bar_dragging = false
	_draw_offset(_offset())


func _view_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		var limits := _limits()
		var offset: float = elastic.pan(event, event.delta.y, _offset(), limits.x, limits.y)
		if event.delta.y != 0.0: _scroll_to(offset)
		else: _draw_offset(offset)
		view.accept_event()
	elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			_stop()
			var limits := _limits()
			var delta: float = view.get_line_height() * 3.0 * event.factor * (-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
			_scroll_to(elastic.step(delta, _offset(), limits.x, limits.y))
		view.accept_event()
	elif event is InputEventScreenTouch and event.pressed and _finger == -1:
		_finger = event.index
		_origin = view.get_global_transform_with_canvas() * event.position
		_dragging = false
		elastic.touch_begin()
		set_process(true)
		view.accept_event()
	elif event is InputEventScreenTouch and not event.pressed:
		view.accept_event()
	elif event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION and (_finger != -1 or _dragging or not view.editable):
		view.accept_event()


func _input(event: InputEvent) -> void:
	# Observe scrollbar presses before native handling; leave thumb movement
	# and hit testing to the control.
	if is_visible_in_tree() and get_viewport().gui_get_hovered_control() == view.get_v_scroll_bar():
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_stop()
			_bar_dragging = true
			follow_end = false
		elif event is InputEventPanGesture or (event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]):
			_view_input(event)
			get_viewport().set_input_as_handled()
	if _bar_dragging and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_bar_dragging = false
		_remember_scroll()
		_queue_restore()
	if _finger == -1: return
	if event is InputEventScreenDrag and event.index == _finger:
		var relative: Vector2 = event.relative
		if not _dragging:
			var travel: Vector2 = event.position - _origin
			if travel.length() <= DRAG_SLOP: return
			_dragging = true
			relative = travel - travel.normalized() * DRAG_SLOP
		var limits := _limits()
		_scroll_to(elastic.touch_move(get_global_transform_with_canvas().affine_inverse().basis_xform(relative), _offset(), limits.x, limits.y))
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and event.index == _finger and not event.pressed:
		_finger = -1
		var limits := _limits()
		elastic.touch_end(_offset(), limits.x, limits.y, not event.canceled)
		set_process(true)
		# Let GUI routing see the lift too, so its touch/mouse capture clears.
