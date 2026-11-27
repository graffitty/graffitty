extends Node
## Flat 2D's flying text and dust, drawn in real 3D over the 2D world.
##
## The viewport exists only while a transition holds it (`acquire`/`release`),
## so a resting Flat 2D world renders no 3D at all. `warm` draws every piece
## variant once at the overlay's formats, so the first switch compiles nothing.
##
## Its camera is fixed: the z = 0 plane shows the world viewport's 2D
## coordinates one to one. Pieces follow their pane by updating their plane
## from the 2D transform each frame (`plane`).
const Pieces := preload("res://scenes/CellShatter.gd")
const FOV := 40.0
const DISTANCE := 10.0

## Holds the overlay above the workspace canvas, inside its clip.
var clip: Control
var viewport: SubViewport
var camera: Camera3D
var view: TextureRect
var _users := 0


func _init(workspace_clip: Control) -> void:
	clip = workspace_clip


## The 3D root for a transition's pieces. Pair every call with `release`.
func acquire() -> SubViewport:
	_users += 1
	if viewport == null:
		viewport = _make_viewport(Vector2i(get_viewport().size).max(Vector2i.ONE))
		camera = viewport.get_child(0)
		add_child(viewport)
		view = TextureRect.new()
		view.name = "FlightOverlay3D"
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.texture = viewport.get_texture()
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.material = _composite(viewport)
		clip.add_child(view)
		sync()
	return viewport


func release() -> void:
	_users -= 1
	if _users > 0 or viewport == null: return
	_users = 0
	viewport.queue_free()
	view.queue_free()
	viewport = null
	camera = null
	view = null


## Follow window resizes and the workspace clip. Call once per frame.
func sync() -> void:
	if viewport == null: return
	var pixels := Vector2i(get_viewport().size).max(Vector2i.ONE)
	if viewport.size != pixels: viewport.size = pixels
	view.position = -clip.position
	view.size = get_viewport().get_visible_rect().size


## World viewport 2D coordinates -> the overlay's z = 0 plane.
func point(screen: Vector2) -> Vector3:
	var extent := get_viewport().get_visible_rect().size
	var unit := 2.0 * DISTANCE * tan(deg_to_rad(FOV) * 0.5) / maxf(extent.y, 1.0)
	return Vector3(screen.x - extent.x * 0.5, extent.y * 0.5 - screen.y, 0.0) * unit


## The rectangle `local` of the 2D item `anchor` on the overlay plane:
## [origin, du, dv], the CellShatter plane map.
func frame(anchor: CanvasItem, local: Rect2) -> Array[Vector3]:
	var to_screen := anchor.get_global_transform_with_canvas()
	var origin := point(to_screen * local.position)
	return [origin,
		point(to_screen * (local.position + Vector2(local.size.x, 0.0))) - origin,
		point(to_screen * (local.position + Vector2(0.0, local.size.y))) - origin]


## Place `piece` on the rectangle `local` of the 2D item `anchor`.
func plane(piece: Node, anchor: CanvasItem, local: Rect2) -> void:
	var map := frame(anchor, local)
	piece.set_planes(map[0], map[1], map[2], map[0], map[1], map[2])


func eye() -> Vector3:
	return camera.global_position if camera != null else Vector3(0.0, 0.0, DISTANCE)


func _composite(source: SubViewport) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/flight_overlay_composite.gdshader")
	material.set_shader_parameter("overlay", source.get_texture())
	return material


func _make_viewport(size: Vector2i) -> SubViewport:
	var result := SubViewport.new()
	result.own_world_3d = true
	result.transparent_bg = true
	# 8-bit sRGB output (half of a float target); the composite shader
	# converts it to the world canvas's linear colour.
	result.use_hdr_2d = false
	# Glyph edges come from their soft texture; MSAA would only add memory.
	result.msaa_3d = Viewport.MSAA_DISABLED
	result.positional_shadow_atlas_size = 0
	result.size = size
	result.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var lens := Camera3D.new()
	lens.fov = FOV
	lens.near = 0.05
	lens.far = DISTANCE * 10.0
	lens.position = Vector3(0.0, 0.0, DISTANCE)
	result.add_child(lens)
	lens.current = true
	return result


## Draw each piece mesh variant (plain, per-instance color, extruded glyph)
## and the composite once at the overlay's formats, then free everything.
func warm() -> void:
	# Nothing compiles without a GPU, and a headless frame never posts its draw.
	if DisplayServer.get_name() == "headless": return
	var target := _make_viewport(Vector2i(16, 16))
	add_child(target)
	var source := SubViewport.new()
	source.size = Vector2i(8, 8)
	source.disable_3d = true
	source.transparent_bg = true
	source.use_hdr_2d = true
	source.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(source)
	var whole := Rect2(Vector2.ZERO, Vector2(8, 8))
	for variant in 3:
		var piece := Pieces.new()
		target.add_child(piece)
		piece.build_regions(source, [whole], whole, Vector3(-1, 1, 0), Vector3(2, 0, 0), Vector3(0, -2, 0), Vector2.ZERO, 0, variant == 1)
		if variant == 2: piece.enable_flight_volume()
		piece.set_fly(Vector3(0.0, 0.0, DISTANCE), 0.1)
	# Zero modulate: the composite runs but adds nothing to the canvas.
	var shown := TextureRect.new()
	shown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shown.texture = target.get_texture()
	shown.material = _composite(target)
	shown.modulate = Color(0, 0, 0, 0)
	shown.size = Vector2.ONE
	clip.add_child(shown)
	for i in 2:
		preload("res://scenes/RenderUpdates.gd").before_draw(func(): pass)
		await RenderingServer.frame_post_draw
	shown.queue_free()
	target.queue_free()
	source.queue_free()
