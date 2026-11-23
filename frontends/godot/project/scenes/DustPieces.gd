extends RefCounted
const SessionSwitchSettings := preload("res://scenes/SessionSwitchSettings.gd")
## Preserve every occupied glyph. The budget changes subdivision, never coverage.
static func cells(term: Node, _budget: int) -> Array:
	var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(term)
	return snapshot.flight_cells() if snapshot != null else []

static func flying_ratio(count: int, sparse := SessionSwitchSettings.SPARSE_RATIO, dense := SessionSwitchSettings.DENSE_RATIO, dense_count := SessionSwitchSettings.DENSE_COUNT) -> float:
	# Keep the curve built in: short prompts retain more whole letters, while
	# busy tabs mostly break into dust. Endpoints and the density scale suffice.
	var full := maxf(float(dense_count), 1.0)
	return lerpf(sparse, dense, smoothstep(full * 0.05, full, float(count)))

static func letters(cells: Array, ratio := -1.0) -> Array:
	var result: Array = []
	var remaining := roundi(cells.size() * clampf(flying_ratio(cells.size()) if ratio < 0.0 else ratio, 0.0, 1.0))
	var rng := RandomNumberGenerator.new()
	# Both render layers independently request this partition: keep it stable
	# for the same capture so no glyph is duplicated or lost between them.
	rng.seed = hash(cells)
	for i in cells.size():
		if remaining > 0 and rng.randi_range(0, cells.size() - i - 1) < remaining:
			result.append(cells[i])
			remaining -= 1
	return result

static func particles(term: Node, rect: Rect2, cells: Array, budget: int, ranks: PackedFloat32Array, fly_ratio := -1.0) -> Dictionary:
	var result: Array = []
	var release := PackedFloat32Array()
	if cells.is_empty(): return {"rects": result, "ranks": release}
	var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(term)
	var grid: Rect2 = snapshot.flight_grid()
	var cell := grid.size
	var origin := rect.position + grid.position
	var retained := {}
	for item in letters(cells, fly_ratio): retained[item] = true
	# At least four fragments per letter; small budgets never drop text.
	var per_letter := clampi(budget / maxi(snapshot.occupied_cell_count(), 1), 4, 64)
	var columns := maxi(2, floori(sqrt(per_letter * cell.x / cell.y)))
	var rows := maxi(2, per_letter / columns)
	for i in cells.size():
		var item: Vector4i = cells[i]
		if item in retained: continue
		var size := Vector2(item.z, item.w) * cell
		var at := origin + Vector2(item.x, item.y) * cell
		for y in rows:
			for x in columns:
				result.append(Rect2(at + size * Vector2(float(x)/columns, float(y)/rows), size / Vector2(columns, rows)))
				release.append(ranks[i])
	return {"rects": result, "ranks": release}
