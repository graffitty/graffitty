extends CanvasLayer
## UI adapter for the shared Rust page motion. Retained pages are input-free.
const Retained := preload("res://scenes/RetainedPresentation.gd")
var _motion: RefCounted = ClassDB.instantiate("ScenePageTransition")
var _list: TextureRect
var _workspace: Control
var _live_material: ShaderMaterial
var _shade: ColorRect
var _started := -1
var _entering := true
var _ready_frame := false
var _window: Window

func prepare(manager: Control, entering: bool) -> void:
	_entering = entering
	_window = manager.get_window()
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.POINTER_CAPTURE
	# The live destination lays out beneath the outgoing list. Copy its rendered
	# pixels before drawing the overlay so script-drawn controls and docked
	# panels slide exactly as they will appear when the overlay is removed.
	if entering:
		var backdrop := BackBufferCopy.new()
		backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
		add_child(backdrop)
	var list_page := Retained.page(manager.get_viewport(), [manager.chooser])
	add_child(list_page)
	_list = _surface(list_page)
	_shade = ColorRect.new()
	_shade.color = Color(0, 0, 0, 0)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_shade)
	if entering:
		_live_material = ShaderMaterial.new()
		_live_material.shader = preload("res://scenes/remote/workspace_slide.gdshader")
		_workspace = ColorRect.new()
		_workspace.material = _live_material
		_workspace.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_workspace)
	else:
		var workspace_page := _retain_workspace(manager)
		add_child(workspace_page)
		_workspace = _surface(workspace_page)
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	_apply(0.0)

func _retain_workspace(manager: Control) -> SubViewport:
	var host: Node = manager.view.host
	var surfaces: Array[Node] = [host.layout_root]
	for child in host.get_children():
		if child is CanvasLayer and child.visible: surfaces.append(child)
	if _window.has_meta(&"list_dock_space"):
		var dock: Control = _window.get_meta(&"list_dock_space")
		if dock.is_visible_in_tree(): surfaces.append(dock.get_parent())
	if is_instance_valid(manager.floating): surfaces.append(manager.floating)
	var keybar: Control = manager.get("keybar")
	if is_instance_valid(keybar) and keybar.visible: surfaces.append(keybar)
	return Retained.page(manager.get_viewport(), surfaces, [host])

func _surface(page: SubViewport) -> TextureRect:
	var surface := TextureRect.new()
	surface.texture = page.get_texture()
	surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(surface)
	return surface

func _ready() -> void:
	_window.size_changed.connect(finish)
	# Do not spend animation time preparing the first retained frame.
	if DisplayServer.get_name() == "headless":
		get_tree().process_frame.connect(_frame_ready, CONNECT_ONE_SHOT)
	else:
		RenderingServer.frame_post_draw.connect(_frame_ready, CONNECT_ONE_SHOT)

func _frame_ready() -> void:
	_ready_frame = true
	_started = Time.get_ticks_usec()

func _process(_dt: float) -> void:
	if not _ready_frame: return
	_apply((Time.get_ticks_usec() - _started) / 1000000.0)

func _apply(elapsed: float) -> void:
	var frame: Vector4 = _motion.sample(elapsed, _entering)
	var extent := _window.get_visible_rect().size
	_list.size = extent
	_workspace.size = extent
	_shade.size = extent
	_list.position.x = frame.y * extent.x
	_shade.position = _list.position
	_shade.color.a = frame.z
	_workspace.position.x = frame.x * extent.x
	if _live_material != null: _live_material.set_shader_parameter("slide", frame.x)
	if frame.w > 0.0: finish()

func _input(_event: InputEvent) -> void:
	get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT]: finish()

func finish() -> void:
	hide()
	set_process(false)
	set_process_input(false)
	queue_free()
