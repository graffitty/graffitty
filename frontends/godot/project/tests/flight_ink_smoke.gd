extends SceneTree
const Dust := preload("res://scenes/DustPieces.gd")
const Pieces := preload("res://scenes/CellShatter.gd")

var failed := false

func expect(ok: bool, message: String) -> bool:
	if not ok:
		failed = true
		printerr(message)
	return ok

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var passed := check_ink() and not failed
	if passed: print("FLIGHT_INK_PASS")
	quit(0 if passed else 1)

func check_ink() -> bool:
	# This face gives the record and gear a one-cell advance but a much wider
	# bitmap. The gear also has a negative left bearing. All hosts use the same
	# outlines, including hosts without a system CJK or Nerd Font.
	var path := ProjectSettings.globalize_path("res://../../../tests/fixtures/flight-ink.ttf")
	var font := FontFile.new()
	if not expect(font.load_dynamic_font(path) == OK, "Load the controlled ink extents"): return false
	var term: Control = ClassDB.instantiate("Terminal")
	term.remote_mode = true
	term.font_size = 20
	term.font_paths = PackedStringArray([path])
	term.size = Vector2(500, 160)
	root.add_child(term)
	# The printed spaces and the visible cursor occupy icon overhangs.
	term.remote_feed("\u001b[2;5H⏺ \u001b[2;13H漢\u001b[2;21H😀\u001b[2;28H  \u001b[2;6H".to_utf8_buffer(), 45, 6)
	var cells := Dust.cells(term, 512)
	var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(term)
	if not expect(snapshot != null and cells.size() == 4, "Four disjoint owners include the spaces, cursor and wide tails, got %s" % str(cells)):
		term.free()
		return false
	var grid: Rect2 = snapshot.flight_grid()
	var ts := TextServerManager.get_primary_interface()
	var rid := font.get_rids()[0]
	var rects: Array[Rect2] = []
	var runs := Pieces.cell_runs(Dust.letters(cells, 1.0), 3)
	for i in runs.positions.size():
		rects.append(Rect2(grid.position + Vector2(runs.positions[i]) * grid.size,
			Vector2(runs.widths[i], runs.heights[i]) * grid.size))
	var columns := [4, 12, 20, 28]
	var symbols := ["⏺", "漢", "😀", ""]
	var ranks := PackedFloat32Array([0.1, 0.2, 0.3, 0.4])
	var fragments := Dust.particles(term, Rect2(Vector2.ZERO, term.size), cells, 512, ranks, 0.0)
	for i in symbols.size():
		# Read the opaque pixels of the font's CPU atlas independently of the
		# production cut calculation (which only uses cached metric rectangles).
		var index := ts.font_get_glyph_index(rid, 20, symbols[i].unicode_at(0), 0)
		var strike := Vector2i(20, 0)
		var uv := Rect2i(ts.font_get_glyph_uv_rect(rid, strike, index))
		var image := ts.font_get_texture_image(rid, strike, ts.font_get_glyph_texture_idx(rid, strike, index))
		var used := Rect2(image.get_region(uv).get_used_rect())
		var scale := ts.font_get_glyph_size(rid, strike, index) / Vector2(uv.size)
		var top := grid.position + grid.size * Vector2(columns[i], 1)
		var baseline := top + Vector2.DOWN * roundf(font.get_ascent(20) + (grid.size.y - font.get_height(20)) / 2.0)
		var ink := Rect2(baseline + ts.font_get_glyph_offset(rid, strike, index) + used.position * scale, used.size * scale)
		expect(ink.has_area(), symbols[i] + " has visible ink")
		if i == 0 or i == 3: expect(ink.end.x > top.x + grid.size.x, symbols[i] + " crosses the right cut")
		if i == 3: expect(ink.position.x < top.x, "The gear crosses the left cut too")
		var owners := rects.filter(func(rect): return rect.intersects(ink))
		expect(owners.size() == 1 and owners[0].encloses(ink), symbols[i] + " has one whole flying owner")
		if i == 1 or i == 2:
			expect(owners.size() == 1 and owners[0].encloses(Rect2(top, grid.size * Vector2(2, 1))), "Wide head owns both VT cells")
		var covered := 0.0
		for fragment: Rect2 in fragments.rects: covered += fragment.intersection(ink).get_area()
		expect(is_equal_approx(covered, ink.get_area()), symbols[i] + " has exactly one layer of dust coverage")
	# A text-presentation cluster and the nonblank cell under its right edge
	# must also stay together when that neighbor has a different style.
	term.remote_feed("\u001b[2J\u001b[?25l\u001b[2;5H⏺\ufe0e\u001b[1mM".to_utf8_buffer(), 45, 6)
	var heads: Array = term.cell_glyphs()
	expect(heads.any(func(g): return g.cp == 0x23fa and g.cluster == 2), "Exercise the shaped cluster path")
	var adjacent: Array = term.capture_render_state().flight_cells()
	expect(adjacent == [Vector4i(4, 1, 2, 1)], "A styled neighbor under the same ink travels in the same rectangle")
	term.free()
	return true
