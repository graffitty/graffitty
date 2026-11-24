extends "res://tests/unit/test_case.gd"
const View := preload("res://scenes/WorkspaceView.gd")
const Pane := preload("res://scenes/WorkspacePane.gd")

func test_navigation_keeps_small_pane_crop_stable_at_every_edge() -> void:
	var full := Rect2(0, 0, 700, 470)
	for position in [Vector2(-1592, 0), Vector2(692, 0), Vector2(0, -992), Vector2(0, 462)]:
		var view := Rect2(position, Vector2(1600, 1000))
		expect(Pane.navigation_raster_region(view, full) == full, "Even an eight-pixel visible slice retains the pane's full crop without stretching")
	for position in [Vector2(-1600, 0), Vector2(700, 0), Vector2(0, -1000), Vector2(0, 470)]:
		expect(not Pane.navigation_raster_region(Rect2(position, Vector2(1600, 1000)), full).has_area(), "Entirely offscreen panes still release their rendering resources")

func test_large_pane_uses_a_bounded_sliding_crop() -> void:
	var full := Rect2(0, 0, 10000, 8000)
	var previous := Rect2()
	for position in [Vector2(-1500, -900), Vector2(0, 0), Vector2(4000, 3000), Vector2(9900, 7900), Vector2(0, 0)]:
		var view := Rect2(position, Vector2(1600, 1000))
		var region := Pane.navigation_raster_region(view, full, previous)
		expect(region.size == view.size, "Panning reuses a viewport-sized crop, never the whole huge pane")
		expect(full.encloses(region) and region.encloses(view.intersection(full)), "The sliding crop contains all visible content and stays inside the pane")
		previous = region

func test_navigation_crop_grows_only_when_more_content_is_needed() -> void:
	var full := Rect2(0, 0, 10000, 8000)
	var region := Pane.navigation_raster_region(Rect2(0, 0, 1600, 1000), full)
	region = Pane.navigation_raster_region(Rect2(100, 100, 1632, 1032), full, region)
	expect(region.size == Vector2(1632, 1032), "Zooming out or a larger camera bound can grow the crop")
	region = Pane.navigation_raster_region(Rect2(200, 200, 1600, 1000), full, region)
	expect(region.size == Vector2(1632, 1032), "Small bound fluctuations do not resize an in-flight texture repeatedly")


class Host extends Node:
	var world: Node
	var workspace_view: Control
	var pane_focus := "t1"


class StandaloneWorld extends "res://scenes/TerminalWorld.gd":
	var window_pixels := Vector2(1600, 900)

	func _window_render_size() -> Vector2:
		return window_pixels


class ProjectedWorld extends StandaloneWorld:
	var shown := 1.0
	var pane_center := Vector2.ZERO

	func sheet_window_fraction(point: Vector2) -> Vector2:
		# Only the focused pane has this local magnification.
		var offset := point - pane_center
		var zoom := shown if offset.length() <= 64.0 else 1.0
		return Vector2(0.5, 0.5) + offset * zoom / host.workspace_view.size


class GlyphControl extends Control:
	var font_size := 16
	var raster_scale := 0.0

	func set_raster_scale(value: float) -> void:
		raster_scale = value


func test_canvas_starts_at_backing_density_and_rerasterizes_zoom_in_half_steps() -> void:
	var view := View.new()
	var host := Host.new()
	var world := StandaloneWorld.new()
	view.host = host
	host.world = world
	host.workspace_view = view
	world.host = host
	view.raster_region = Rect2(-32, -32, 320, 240)
	expect(view._canvas_raster_size(1.0) == Vector2i(320, 240), "1× backing at rest")
	expect(view._canvas_raster_size(2.0) == Vector2i(640, 480), "2× backing at rest")
	expect(view._canvas_raster_size(1.25) == Vector2i(480, 360), "Fractional backing rounds up to a half step")
	world.fx_cam_zoom = 1.16
	expect(view._canvas_raster_size(2.0) == Vector2i(800, 600), "Large zoom still refines immediately")
	world.fx_cam_zoom = 1.0
	view.overview = true
	view.navigation_zoom = 1.03
	expect(view._canvas_raster_size(2.0) == Vector2i(800, 600), "Explicit overview uses navigation zoom even below the mild threshold")
	view.overview = false
	world.fx_cam_zoom = 0.94
	view.navigation_zoom = 1.75
	expect(view._canvas_raster_size(2.0) == Vector2i(1120, 840), "Implicit overview also uses navigation zoom")
	world.fly_dur = 0.1
	expect(view._canvas_raster_size(2.0) == Vector2i(640, 480), "Flight keeps the full sheet at its baseline")
	world.fly_dur = 0.0
	world.tab_fx_t = 0.1
	expect(view._canvas_raster_size(2.0) == Vector2i(640, 480), "Tab effects also keep the baseline")


func test_settled_zoom_samples_the_focused_sheet_and_reuses_the_density_bucket() -> void:
	var view := View.new()
	var host := Host.new()
	var world := ProjectedWorld.new()
	view.host = host
	host.world = world
	host.workspace_view = view
	world.host = host
	view.size = Vector2(900, 600)
	view.raster_region = Rect2(-32, -32, 320, 240)
	var pane := Control.new()
	pane.position = Vector2(420, 200)
	pane.size = Vector2(480, 240)
	pane.scale = Vector2(1.5, 1.5)
	view.panes[host.pane_focus] = pane
	world.pane_center = pane.get_transform() * (pane.size * 0.5)
	var native := Vector2i(640, 480)
	var raised := Vector2i(800, 600)

	world.shown = 1.09
	expect(view._canvas_raster_size(2.0) == native, "1.09× stays native even with an enlarged pane")
	world.shown = 1.10 - 0.000001
	if OS.has_feature("android") or OS.has_feature("ios"):
		world.fx_cam_zoom = 1.14
		expect(view._canvas_raster_size(2.0) == native, "Mobile keeps its existing camera threshold")
		return
	expect(view._canvas_raster_size(2.0) == raised, "Settled 1.10× is inclusive within projection precision")
	world.shown = 1.10
	expect(view._canvas_raster_size(2.0) == raised, "Exactly 1.10× uses the raised bucket")
	world.shown = 1.0998
	expect(view._canvas_raster_size(2.0) == raised and view._raster_settle_timer.is_stopped(), "Subpixel jitter keeps the raised bucket")
	world.shown = 1.09
	expect(view._canvas_raster_size(2.0) == native, "Settled 1.09× restores native density")
	world.fx_cam_zoom = 1.5
	world.shown = 1.14
	expect(view._canvas_raster_size(2.0) == raised, "Settled 1.14× uses the projected half-step bucket")
	expect(view._canvas_raster_size(2.0) == raised and view._raster_settle_timer.is_stopped(), "Repeated reconciliation needs no resize or timer")


func test_canvas_bounds_native_and_zoomed_allocations() -> void:
	var view := View.new()
	view.host = Host.new()
	view.raster_region = Rect2(0, 0, 6400, 100)
	expect(view._canvas_raster_size(2.0) == Vector2i(8192, 128), "A long narrow canvas reaches the side cap")
	view.raster_region.size = Vector2(5000, 4000)
	var size := view._canvas_raster_size(2.0)
	var mobile := OS.has_feature("android") or OS.has_feature("ios")
	var expected := Vector2i(2236, 1788) if mobile else Vector2i(5000, 4000)
	expect(size == expected, "Canvas fits the platform area budget at the crop's aspect")


func test_standalone_sheet_covers_the_physical_window_and_caps_only_its_raster() -> void:
	var world := StandaloneWorld.new()
	var glyphs := GlyphControl.new()
	world.term = glyphs
	world.term_vp = SubViewport.new()
	world._sync_terminal_viewport_size()
	expect(world.term_vp.size == Vector2i(1600, 1000), "The 1.6-aspect sheet covers the window in backing pixels")
	expect(world.term_vp.size_2d_override == world.term_vp.size, "Native allocation matches authored layout")
	expect(glyphs.raster_scale == 1.0, "A returning standalone terminal resets glyphs to native density")
	world.window_pixels = Vector2(8000, 5000)
	world._sync_terminal_viewport_size()
	expect(world.term_vp.size_2d_override == Vector2i(8000, 5000), "Area limits preserve the PTY layout")
	var mobile := OS.has_feature("android") or OS.has_feature("ios")
	var expected := Vector2i(2529, 1581) if mobile else Vector2i(5656, 3535)
	expect(world.term_vp.size == expected, "Standalone targets share the platform area limit")
	expect(absi(floori(8000 * glyphs.raster_scale) - expected.x) <= 1, "The glyph renderer receives the capped density")
