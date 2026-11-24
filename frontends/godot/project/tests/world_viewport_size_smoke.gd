extends SceneTree
const Host := preload("res://scenes/TerminalHost.gd")


class BudgetWorld extends "res://scenes/TerminalWorld.gd":
	var output_pixels := 0
	var scale_updates := 0
	func _ready() -> void:
		add_child(fx_camera)
	func _process(_dt: float) -> void: pass
	func _notification(_what: int) -> void: pass
	func _display_pixel_count() -> int: return output_pixels
	func _apply_render_scale() -> void:
		scale_updates += 1
		super._apply_render_scale()


func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-resize-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()


func run() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	var viewport := SubViewport.new()
	container.add_child(viewport)
	root.add_child(container)
	var observed: Array[Vector2i] = []
	var failures: Array[String] = []
	viewport.size_changed.connect(func(): observed.append(viewport.size))
	# A small simulated device limit makes the real resize notifications safe
	# to inspect without allocating an oversized GPU image.
	for size: Vector2 in [Vector2(800, 500), Vector2(1024, 1024), Vector2(1025, 1024), Vector2(1500, 900), Vector2(3200, 100), Vector2(100, 3200), Vector2(800, 500)]:
		observed.clear()
		Host._resize_world_container(container, size, 1024)
		for actual in observed:
			if maxi(actual.x, actual.y) > 1024:
				failures.append("Resize to %s allocated oversized intermediate %s" % [size, actual])
		var expected_shrink := maxi(1, ceili(maxf(size.x, size.y) / 1024.0))
		if container.stretch_shrink != expected_shrink or viewport.size != Vector2i(size / expected_shrink):
			failures.append("Final viewport does not preserve bounded size")
	container.free()
	# A 4K surface moves between a 1080p and 4K output without a resize.
	# Output modes are already pixels, independent of the window's UI density.
	var target := SubViewport.new()
	target.size = Vector2i(3840, 2160)
	var world := BudgetWorld.new()
	target.add_child(world)
	root.add_child(target)
	for ui_scale: float in [1.0, 1.25, 2.0]:
		root.content_scale_factor = ui_scale
		for sample in [[1920 * 1080, 0.4], [3840 * 2160, 0.8], [2160 * 3840, 0.8], [0, 0.8]]:
			world.output_pixels = sample[0]
			world._refresh_display_budget()
			if not is_equal_approx(target.scaling_3d_scale, sample[1]):
				failures.append("Output budget %d at UI scale %s produced %s" % [sample[0], ui_scale, target.scaling_3d_scale])
			var updates := world.scale_updates
			world._refresh_display_budget()
			if world.scale_updates != updates:
				failures.append("Unchanged output budget reapplied the render scale")
	# A display move must repaint scenery even after its idle cache stopped drawing.
	world.scenery_vp = SubViewport.new()
	world.scenery_vp.size = target.size
	world.add_child(world.scenery_vp)
	world.cam = Camera3D.new()
	world.add_child(world.cam)
	world.ink_active = true
	world._apply_render_scale()
	for i in 3: world._update_scenery_view()
	if world.scenery_vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		failures.append("Scenery fixture did not settle into its idle cache")
	world.output_pixels = 1920 * 1080
	world._refresh_display_budget()
	world._update_scenery_view()
	if not is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.4) or world.scenery_vp.render_target_update_mode != SubViewport.UPDATE_ONCE:
		failures.append("Moving displays did not repaint idle scenery at its new scale")
	target.free()
	print("WORLD_VIEWPORT_SIZE failures=", failures)
	quit(0 if failures.is_empty() else 1)
