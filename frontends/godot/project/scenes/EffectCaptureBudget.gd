extends RefCounted
## All transient effect targets share a pixel allowance across worlds/windows.
## Weak references ensure the budget never extends a capture's lifetime.
static var _targets: Array[WeakRef] = []

static func limit() -> int:
	return 16_000_000 if OS.has_feature("android") or OS.has_feature("ios") else 64_000_000

static func texture_limit() -> int:
	var device := RenderingServer.get_rendering_device()
	return mini(device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D), 16384) if device != null else 8192

static func fit(viewport: SubViewport, desired: Vector2i) -> void:
	_targets = _targets.filter(func(reference): return is_instance_valid(reference.get_ref()) and not reference.get_ref().is_queued_for_deletion())
	var frame := Engine.get_process_frames()
	viewport.set_meta("capture_budget_frame", frame)
	var extent := Vector2(desired.max(Vector2i(2, 2)))
	extent *= minf(1.0, float(texture_limit()) / maxf(extent.x, extent.y))
	viewport.set_meta("capture_requested_size", Vector2i(extent.floor()).max(Vector2i(2, 2)))
	var found := false
	for reference in _targets:
		if reference.get_ref() == viewport: found = true
	if not found: _targets.append(weakref(viewport))
	var used := 0
	var requested := 0
	var pending: Array[SubViewport] = []
	for reference in _targets:
		var target: SubViewport = reference.get_ref()
		if target.get_meta("capture_budget_frame") == frame:
			pending.append(target)
			var request: Vector2i = target.get_meta("capture_requested_size")
			requested += request.x * request.y
		else:
			used += target.size.x * target.size.y
	# Allocate the complete frame together before its first draw. Greedy
	# allocation let pane backings consume everything before glyphs arrived.
	# Reserve room for two retiring snapshots and the next arriving frame.
	var available := maxi(4 * pending.size(), mini(limit() / 3, limit() - used))
	var minimum := 4 * pending.size()
	for target in pending:
		var request: Vector2i = target.get_meta("capture_requested_size")
		var pixels := request.x * request.y
		var share := mini(pixels, 4 + floori(float(available - minimum) * (pixels - 4) / maxi(requested - minimum, 1)))
		var scale := sqrt(float(share) / pixels)
		var raster := Vector2i((Vector2(request) * scale).floor()).max(Vector2i(2, 2))
		# A sliver's short axis still needs two pixels after scaling.
		if raster.x >= raster.y: raster.x = mini(raster.x, share / raster.y)
		else: raster.y = mini(raster.y, share / raster.x)
		target.size = raster
