extends Node2D

const PaneAddress := preload("res://scenes/PaneAddress.gd")
## Live terminal textures for whole-pane transitions; retained drawing state
## for glyph transitions, and copied UI rasterized at projected density.
## Letters and dust fly in real 3D (FlightOverlay3D); backings, chrome and
## graph wires stay 2D panels.
const Core := preload("res://scenes/TerminalEffects.gd")
const Motion := preload("res://scenes/ScatterMotion.gd")
const DepthMotion := preload("res://scenes/TabDepthMotion.gd")
const Capture := preload("res://scenes/CellShatter.gd")
const TransitionShader := preload("res://scenes/tab_scatter_2d.gdshader")
var captures: Array[SubViewport] = []
var terminal_captures := {}
var panels: Array[CanvasItem] = []
var raster_items: Array[Node2D] = []
## Flying letters and dust: CellShatter pieces in the 3D overlay.
var glyphs: Array[Node] = []
var overlay: Node
## Each terminal's letters as a flat 2D panel in its own pane, shown instead
## of the overlay while the pieces rest, so later panes still cover them.
var rest_ink: Array[Sprite2D] = []
var pane_groups: Array[Node2D] = []
var ui_groups: Array[Node2D] = []
var dust_mode := false
var effect_control: RefCounted
var depth_mode := false
var screen_space := false
var depth_direction := 1.0
## 1 flies left, -1 mirrors every lateral path right.
var flight_side := 1.0
var depth_center := Vector2.ZERO
var depth_projection := Transform2D.IDENTITY
var depth_retirement := -1.0
var progress := 0.0
var arriving := false
var retirement_time := -1.0
var retirement_phase := 0.0
var live_panels: Array[Dictionary] = []

func presentation_point(viewport: SubViewport, point: Vector2, target: Node2D) -> Variant:
	for item in live_panels:
		if item.source.get_ref() != viewport: continue
		var sprite: Sprite2D = item.sprite
		if float(sprite.material.get_shader_parameter("depth_alpha")) <= 0.0001: return null
		var local := (point / Vector2(item.size) - Vector2(0.5, 0.5)) * Vector2(sprite.texture.get_size())
		return target.to_local(sprite.to_global(local))
	return null

func _exit_tree() -> void:
	for piece in glyphs:
		if is_instance_valid(piece): piece.queue_free()
	glyphs.clear()
	if is_instance_valid(overlay): overlay.release()
	overlay = null
	for item in live_panels.duplicate(): _release_live_panel(item)
	for viewport in captures:
		if is_instance_valid(viewport): viewport.queue_free()

func capture(source: SubViewport, mask: int, parent: Node = null) -> Texture2D:
	var key := "%d:%d" % [source.get_instance_id(), mask]
	if terminal_captures.has(key): return terminal_captures[key].get_texture()
	var viewport := preload("res://scenes/RetainedViewport.gd").capture_state(source, mask, parent)
	captures.append(viewport)
	terminal_captures[key] = viewport
	return viewport.get_texture()

func panel(texture: Texture2D, rect: Rect2, parent: Node2D) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	_track_raster(sprite, texture)
	sprite.position = rect.get_center()
	_resize_panel(sprite, rect.size)
	texture.changed.connect(_resize_panel.bind(sprite, rect.size))
	var material := ShaderMaterial.new()
	material.shader = TransitionShader
	sprite.material = material
	parent.add_child(sprite)
	panels.append(sprite)

func _resize_panel(sprite: Sprite2D, extent: Vector2) -> void:
	# The frame's captures share their allocation before the first draw.
	# Changing raster density must not change the panel's logical geometry.
	if is_instance_valid(sprite):
		sprite.scale = extent / Vector2(sprite.texture.get_size()).max(Vector2.ONE)

func build(world: Node) -> void:
	dust_mode = world.dust_effect()
	effect_control = world.effect_control
	depth_mode = world.depth_effect()
	screen_space = world.screen_space_session_flight()
	depth_direction = world.tab_fx_direction
	flight_side = world._flight_side()
	depth_center = world.camera_2d.position
	depth_projection = get_parent().global_transform
	var view: Control = world.host.workspace_view
	for border in world._workspace_border_captures(not arriving):
		var rect: Rect2 = border.rect
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.disable_3d = true
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.size_2d_override = Vector2i(rect.size.ceil()).max(Vector2i.ONE)
		still.size_2d_override_stretch = true
		preload("res://scenes/EffectCaptureBudget.gd").fit(still, still.size_2d_override)
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(border.drawing)
		view.canvas.add_child(still)
		captures.append(still)
		var group := Node2D.new()
		group.position = rect.get_center()
		group.z_index = -1
		group.set_meta("border_layer", border.kind)
		add_child(group)
		pane_groups.append(group)
		panel(still.get_texture(), Rect2(-rect.size * 0.5, rect.size), group)
	# Preserve the same graph and screen-space chrome as the 3D transition.
	var wires: Node2D = view.agent_links.wire_layer.still_copy(false, true)
	var owners: Node2D = view.chromium_links.wire_layer.still_copy()
	wires.commands.append_array(owners.commands)
	owners.free()
	var sockets: Node2D = view.agent_links.wire_layer.get_script().new()
	sockets.frozen = true
	sockets.unproject = view.agent_links.wire_layer.unproject
	for output in [false, true]:
		for button in view.agent_links.sockets(output).values():
			if button.visible:
				sockets.circle(button.position + button.size * 0.5, 4.0, button.get_meta("port_color"))
	for drawing in [wires, sockets]:
		if drawing.commands.is_empty():
			drawing.free()
			continue
		var group := ui_group(view.canvas_size() * 0.5, view.canvas_size())
		group.set_meta("graph_layer", "wires" if drawing == wires else "sockets")
		group.z_index = -1 if drawing == wires else 1
		drawing.position = -group.position
		group.add_child(drawing)
	var controls: Array = view.status_strips.values()
	for control in controls:
		if not control.visible or control.size.x <= 0 or control.size.y <= 0: continue
		var still := Capture.capture_control(control)
		view.canvas.add_child(still)
		captures.append(still)
		var rect: Rect2 = view.control_canvas_rect(control)
		# Strips fade and recede with the pane backing; only text flies.
		var group := Node2D.new()
		group.position = rect.get_center()
		group.z_index = 2
		group.set_meta("workspace_chrome", true)
		add_child(group)
		pane_groups.append(group)
		panel(still.get_texture(), Rect2(-rect.size * 0.5, rect.size), group)
	for key in world._shown_panes():
		var pane: Control = view.panes[key]
		var group := Node2D.new()
		group.position = pane.get_transform() * (pane.size * 0.5)
		group.scale = pane.scale
		group.set_meta("pane_scale", pane.scale)
		add_child(group)
		pane_groups.append(group)
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.disable_3d = true
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.size_2d_override = Vector2i(pane.size.ceil()).max(Vector2i.ONE)
		still.size_2d_override_stretch = true
		preload("res://scenes/EffectCaptureBudget.gd").fit(still, Vector2i((pane.size * minf(maxf(view.canvas_scale(), 1.0), 8192.0 / maxf(pane.size.x, pane.size.y))).ceil()).max(Vector2i.ONE))
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(pane.still_copy())
		view.canvas.add_child(still)
		captures.append(still)
		panel(still.get_texture(), Rect2(-pane.size * 0.5, pane.size), group)
		if not world.host.is_terminal_pane(key): continue
		var pair: Dictionary = world.host.sessions.get(PaneAddress.id(key), {})
		if pair.is_empty(): continue
		var layout := Vector2(Core.layout_size(pair.vp))
		var origin: Vector2 = (view.terminal_origin(key) - group.position) / pane.scale
		if depth_mode:
			preload("res://scenes/TerminalViewportUpdates.gd").retain_live(pair.vp)
			# Expand a zoomed crop before focus hides the departing pane.
			pane._resize_terminal_preview()
			panel(pair.vp.get_texture(), Rect2(origin, layout), group)
			var item := {"sprite": panels.back(), "source": weakref(pair.vp), "size": layout}
			live_panels.append(item)
			pair.vp.tree_exiting.connect(_freeze_live_panel.bind(item))
			continue
		panel(capture(pair.vp, (1 << 17) | (1 << 19)), Rect2(origin, layout), group)
		_build_pieces(world, pair, group, Rect2(origin, layout))
	if depth_mode:
		for group in pane_groups + ui_groups:
			group.set_meta("depth_origin", group.position)
			group.set_meta("depth_scale", group.scale)
		set_progress(1.0 if arriving else 0.0)
		return
	Capture.assign_release_ranks(glyphs.filter(func(piece): return piece.get_meta("glyph_layer", false)), flight_side)
	visibility_changed.connect(_update_pieces)
	# An arrival waits fully scattered until its clock starts.
	if arriving: progress = 1.0
	_update_pieces()

## The letters and dust Flat 3D flies for this terminal, built in the 3D
## overlay. `local` is the terminal texture's rectangle in `group`.
func _build_pieces(world: Node, pair: Dictionary, group: Node2D, local: Rect2) -> void:
	var fly_ratio: float = world.dust_flying_ratio(pair.term) if dust_mode else -1.0
	var cells: Array = Capture.limit_layers(world._transition_cells(pair.term, fly_ratio), world.scatter_block_budget())
	var rect := Rect2(pair.term.position, pair.term.size)
	var built := glyphs.size()
	var map: Array[Vector3] = world.flight_overlay.frame(group, local)
	# Like Flat 3D, grouped travel scales with the whole workspace sheet.
	var sheet: Array[Vector3] = world.flight_overlay.frame(self, Rect2(Vector2.ZERO, world.host.workspace_view.canvas_size()))
	for i in world.LAYERS.size():
		if cells[i].is_empty(): continue
		if overlay == null:
			overlay = world.flight_overlay
			overlay.acquire()
		var piece := Capture.new()
		piece.visible = false
		piece.flight_side = flight_side
		overlay.viewport.add_child(piece)
		# _update_pieces keeps this plane on the pane every frame.
		if piece.build_cells(pair.term, pair.vp, rect, map[0], map[1], map[2], cells[i], world.LAYERS[i]["motion"], Vector2.ZERO, 3, dust_mode and i == 0, world.dust_particle_budget(), fly_ratio) <= 0:
			piece.free()
			continue
		piece.set_progress(1.0)
		world._group_transition_layer(piece, i, true)
		# As in Flat 3D: appearance after thickness keeps the live ink's colour
		# on every face (it resets thickness_shade).
		piece.set_thickness(world.TAB_FX_THICKNESS)
		piece.set_appearance(world.ink_gain, world.tonemap_exposure)
		var mat: ShaderMaterial = piece._material()
		mat.set_shader_parameter("group_travel_du", sheet[1])
		mat.set_shader_parameter("group_travel_dv", sheet[2])
		mat.set_shader_parameter("arrival_flight", arriving)
		mat.set_shader_parameter("retire_flight_pieces", true)
		mat.set_shader_parameter("flight_side", flight_side)
		piece.set_meta("anchor", group)
		piece.set_meta("local_rect", local)
		glyphs.append(piece)
	if glyphs.size() > built:
		panel(glyphs[built]._material().get_shader_parameter("terminal_tex"), local, group)
		rest_ink.append(panels.back())

func _update_pieces() -> void:
	if overlay == null: return
	overlay.sync()
	var shown := is_visible_in_tree()
	var resting := progress <= 0.0 and retirement_time < 0.0
	for ink in rest_ink: ink.visible = resting
	for piece in glyphs:
		piece.visible = shown and not resting
		if not piece.visible: continue
		overlay.plane(piece, piece.get_meta("anchor"), piece.get_meta("local_rect"))
		var mat: ShaderMaterial = piece._material()
		mat.set_shader_parameter("retirement_time", retirement_time)
		mat.set_shader_parameter("retirement_phase", retirement_phase)
		piece.set_fly(overlay.eye(), progress)
		piece.update_raster(overlay.camera)

func ui_group(center: Vector2, extent: Vector2) -> Node2D:
	var group := Node2D.new()
	group.position = center
	group.set_meta("origin", center)
	group.set_meta("camera_offset", center - extent * 0.5)
	var radial := center / extent - Vector2(0.5, 0.5)
	group.set_meta("rank", clampf(1.0 - radial.length() * sqrt(2.0), 0.0, 1.0))
	var jitter := Vector2(randf(), randf())
	var wind := Motion.wind(center / extent, jitter)
	group.set_meta("wind", wind)
	group.set_meta("drift", Motion.drift(center / extent, jitter, wind))
	group.set_meta("span", minf(extent.x, extent.y))
	group.set_meta("spin", radial.x * 0.3)
	add_child(group)
	ui_groups.append(group)
	return group

func set_progress(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	if depth_mode or screen_space:
		transform = get_parent().global_transform.affine_inverse() * depth_projection
	if depth_mode:
		var phase := DepthMotion.phase(progress)
		var magnification := DepthMotion.magnification(progress, depth_direction, arriving)
		var opacity := (1.0 - phase) * (1.0 - DepthMotion.phase(depth_retirement / DepthMotion.RETIRE_DURATION) if depth_retirement >= 0.0 else 1.0)
		# Cancel the live camera's saved pan/zoom. The whole captured workspace
		# keeps its original projection and moves with one common dolly scale.
		for group in pane_groups + ui_groups:
			group.position = depth_center + (Vector2(group.get_meta("depth_origin")) - depth_center) * magnification
			group.scale = Vector2(group.get_meta("depth_scale")) * magnification
			if group.has_meta("graph_layer"): group.modulate.a = opacity
		var blur := phase * 6.0 if effect_control.allows("camera.dof") else 0.0
		for item in panels:
			item.material.set_shader_parameter("depth_alpha", opacity)
			item.material.set_shader_parameter("depth_blur", blur)
		_update_raster()
		return
	for group in ui_groups:
		if group.has_meta("graph_layer"):
			group.modulate.a = 1.0 - smoothstep(0.0, 0.3, progress)
			continue
		if dust_mode:
			group.modulate.a = 1.0 - smoothstep(0.0, 0.7, progress)
			continue
		var rank: float = group.get_meta("rank")
		var flight := Motion.retire_flight(retirement_phase, rank, retirement_time) if retirement_time >= 0.0 else Motion.clock(progress, rank, arriving)
		# Emulate the 3D near plane: past the eye is invisible, never mirrored.
		var depth := 1.5 * flight
		group.scale = Vector2.ONE / maxf(1.0 - depth, 0.01)
		var wind: Vector2 = group.get_meta("wind")
		var drift: Vector2 = group.get_meta("drift")
		var lateral := drift * flight + wind * Motion.wind_distance(flight)
		lateral.x *= -flight_side if arriving else flight_side
		group.position = group.get_meta("origin") + lateral * float(group.get_meta("span")) * group.scale.x
		group.rotation = group.get_meta("spin") * flight
		group.modulate.a = 1.0 if depth < 0.99 else 0.0
	var backing_flight := smoothstep(0.0, 0.3, progress)
	for item in panels:
		if item.material is ShaderMaterial: item.material.set_shader_parameter("progress", backing_flight)
		else: item.modulate.a = 1.0 - backing_flight
	for group in pane_groups: group.scale = group.get_meta("pane_scale", Vector2.ONE) * (1.0 - 0.06 * backing_flight)
	_update_pieces()
	_update_raster()


func _track_raster(item: Node2D, texture: Texture2D, logical := Vector2.ZERO) -> void:
	for viewport in captures:
		if viewport.get_texture() == texture:
			item.set_meta("presentation_viewport", weakref(viewport))
			item.set_meta("presentation_size", logical)
			raster_items.append(item)
			return


func _update_raster() -> void:
	for item in raster_items:
		var viewport: SubViewport = item.get_meta("presentation_viewport").get_ref()
		if not is_instance_valid(viewport): continue
		var scale := item.get_global_transform_with_canvas().get_scale().abs()
		var logical: Vector2 = item.get_meta("presentation_size")
		# Sprites compensate texture size in their own scale; glyph batches use
		# logical cell geometry and normalized UVs at every raster density.
		if logical == Vector2.ZERO: logical = Vector2(viewport.size)
		viewport.request_extent(logical * scale)

func _release_live_panel(item: Dictionary) -> void:
	var source: SubViewport = item.source.get_ref()
	if is_instance_valid(source):
		var callback := _freeze_live_panel.bind(item)
		if source.tree_exiting.is_connected(callback): source.tree_exiting.disconnect(callback)
		preload("res://scenes/TerminalViewportUpdates.gd").release_live(source)
	live_panels.erase(item)

func _freeze_live_panel(item: Dictionary) -> void:
	var source: SubViewport = item.source.get_ref()
	if is_instance_valid(source):
		var sprite: Sprite2D = item.sprite
		sprite.texture.changed.disconnect(_resize_panel.bind(sprite, item.size))
		sprite.texture = capture(source, (1 << 17) | (1 << 18) | (1 << 19), self)
		_track_raster(sprite, sprite.texture)
		_resize_panel(sprite, item.size)
		sprite.texture.changed.connect(_resize_panel.bind(sprite, item.size))
	_release_live_panel(item)

func retire() -> void:
	# An interrupted layer retains its last view before its source is reused.
	for item in live_panels.duplicate(): _freeze_live_panel(item)
	if depth_mode:
		depth_retirement = 0.0
		return
	if arriving and retirement_time < 0.0:
		retirement_time = 0.0
		retirement_phase = progress

func advance_retirement(dt: float) -> bool:
	if depth_mode:
		depth_retirement += dt
		set_progress(progress)
		return depth_retirement < DepthMotion.RETIRE_DURATION
	if retirement_time >= 0.0:
		retirement_time += dt
		set_progress(Motion.retire_pose(retirement_phase, -1.0 / Motion.ARRIVAL, retirement_time))
		return retirement_time < Motion.DEPARTURE
	set_progress(progress + dt / Motion.DEPARTURE)
	return progress < 1.0
