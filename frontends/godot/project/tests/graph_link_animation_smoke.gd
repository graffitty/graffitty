extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0

func check(value: bool, label: String) -> void:
	print("PASS " if value else "FAIL ", label)
	if not value: failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1100, 700)
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	# Advertised ports exercise the same server authority as the application.
	graph.nodes = {"t0": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}, "t1": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}, "t2": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}}
	var canvas := Control.new()
	root.add_child(canvas)
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var rectangles := {"t0": Rect2(80, 280, 200, 150), "t1": Rect2(760, 110, 220, 150), "t2": Rect2(760, 430, 220, 150)}
	for key in rectangles:
		var panel := Panel.new()
		canvas.add_child(panel)
		panel.position = rectangles[key].position
		panel.size = rectangles[key].size
		var label := Label.new()
		panel.add_child(label)
		label.position = Vector2(16, 16)
		label.text = key
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.graph = graph
	for pair in [["t0", "t1"], ["t1", "t0"], ["t2", "t0"]]:
		graph.connect_nodes({"from": pair[0], "to": pair[1], "send": true})
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	check(not overlay.is_processing(), "Idle links do not schedule animation frames")
	var geometry_before: int = overlay.geometry_rebuilds
	var sent: Dictionary = graph.enqueue("t0", "t1", "test", "message")
	check(overlay.waiting.size() == 1 and overlay.pulses.is_empty(), "Queued message blinks without flowing")
	check(overlay.geometry_rebuilds == geometry_before, "Queue changes do not rebuild unchanged wire geometry")
	overlay.hide()
	check(overlay.waiting.is_empty() and not overlay.is_processing(), "Hidden queued links stop scheduling animation frames")
	overlay.show()
	check(overlay.waiting.size() == 1 and overlay.is_processing(), "Showing queued links restores their markers from the visibility event")
	await create_timer(0.2).timeout
	check(overlay.blink_time > 0 and overlay.pulses.is_empty(), "Queue blink advances while its dot stays stationary")
	graph.progress("t1", {"event_id": sent.result.event_id, "message": "Waiting for another branch"})
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	check(overlay.waiting.size() == 1 and overlay.waiting.values()[0].received, "Received-but-pending marker moves to the receiver")
	check(overlay.geometry_rebuilds == geometry_before, "Delivery progress changes marker state without rebuilding wire geometry")
	check(overlay.pulses.is_empty() and graph.queues["t1"].size() == 1, "Progress retains the queued event without a final delivery pulse")
	check("pending" in overlay.edge_tooltip("t0/out>t1/in") and "Waiting for another branch" in overlay.edge_tooltip("t0/out>t1/in"), "Pending edge explains which work it is waiting for")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-queued.png")
	graph.ack("t1", sent.result.event_id, "delivered")
	check(overlay.waiting.is_empty(), "Delivery clears the queued indicator")
	check(overlay.pulses.size() == 1, "Accepted graph delivery starts one pulse")
	var reverse: Dictionary = graph.enqueue("t1", "t0", "reply", "message")
	graph.ack("t0", reverse.result.event_id, "delivered")
	check(not overlay._route("t1", "t0", "t1/out>t0/in").reverse and overlay._route("t1", "t0", "t1/out>t0/in").link.source == "t1", "Reply travels along its own directed return wire")
	var backward: Dictionary = graph.enqueue("t2", "t0", "backward link", "message")
	graph.ack("t0", backward.result.event_id, "delivered")
	await create_timer(0.75).timeout
	check(overlay.pulses.size() == 3 and overlay.pulses[0].distance > 120, "Live processing advances all message pulses")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-animation.png")
	graph.disconnect_nodes("t0", "t1")
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	await process_frame
	await process_frame
	check(overlay.pulses.size() == 2, "Disconnect removes only that direction's pulse")
	var rejected: Dictionary = graph.enqueue("t1", "t0", "rejected", "message")
	graph.ack("t0", rejected.result.event_id, "failed: test")
	check(overlay.pulses.size() == 3 and overlay.pulses[-1].get("failed", false), "Failed delivery starts a red cross instead of a success dot")
	var cancelled: Dictionary = graph.enqueue("t2", "t0", "cancel me", "message")
	graph.disconnect_nodes("t2", "t0")
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	await create_timer(0.6).timeout
	var crosses := overlay.pulses.filter(func(pulse): return pulse.get("failed", false))
	check(crosses.size() == 2, "Both failure and disconnect cancellation produce crosses")
	check(crosses[1].event_id == cancelled.result.event_id and crosses[1].distance > 100, "Cancellation cross keeps moving after its edge is removed")
	check(overlay.waiting.is_empty(), "Cancelled queues stop blinking")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-failed.png")
	await create_timer(7.0).timeout
	check(overlay.pulses.is_empty() and not overlay.is_processing(), "Completed animations release frame processing")
	# A tiny gap previously finished before a person could notice it.
	graph.disconnect_nodes("t1", "t0")
	graph.connect_nodes({"from": "t0", "to": "t1", "send": true})
	rectangles["t1"] = Rect2(312, 280, 220, 150)
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	var short_send: Dictionary = graph.enqueue("t0", "t1", "short link", "message")
	graph.ack("t1", short_send.result.event_id, "delivered")
	await create_timer(0.6).timeout
	check(overlay.pulses.size() == 1 and overlay.pulses[0].distance > 0, "Short link send remains visible for at least 1.2 seconds")
	await create_timer(0.9).timeout
	check(overlay.pulses.is_empty() and not overlay.is_processing(), "One traversal returns the wire to normal without looping")
	# A duplicate receipt must not restart a completed animation.
	graph.ack("t1", short_send.result.event_id, "delivered")
	check(overlay.pulses.is_empty(), "Duplicate acknowledgment does not replay the send")
	# Theme/font minimums can resize a newly added socket after initial sync.
	# Its visible center and the established wire must move in the same layout.
	var socket: Button = overlay.sockets(true)["t0/out"]
	var before_height := socket.size.y
	socket.custom_minimum_size.y = before_height + 32
	socket.add_theme_font_size_override("font_size", 40)
	for i in 3: await process_frame
	check(socket.size.y >= before_height + 32, "A theme change resizes the socket to its new minimum")
	var resized_link: Dictionary = overlay._route("t0", "t1", "t0/out>t1/in").link
	check(resized_link.points[0].is_equal_approx(overlay.port_center("t0/out", true)),
		"Resized socket keeps its wire endpoint on the visible center")
	test_failed_marker_during_zoom()
	test_same_ports_reconnected()
	canvas.free()
	graph.free()
	quit(1 if failures else 0)

func test_failed_marker_during_zoom() -> void:
	var graph := Graph.new()
	graph.nodes = {"t1": {"provider": "codex"}, "t2": {"provider": "codex"}}
	graph.connect_nodes({"from": "t1", "to": "t2", "send": true})
	var parent := Control.new()
	root.add_child(parent)
	var overlay := Overlay.new()
	parent.add_child(overlay)
	overlay.graph = graph
	overlay.sync({"t1": Rect2(0, 0, 200, 200), "t2": Rect2(400, 0, 200, 200)}, graph.edges.values(), func(point): return point, true)
	var route: Dictionary = overlay.sheet_links[0]
	var event: Dictionary = graph.enqueue("t1", "t2", "reject during zoom", "message")
	graph.ack("t2", event.result.event_id, "failed: test")
	var pulse: Dictionary = overlay.pulses.back()
	pulse.age = pulse.duration * 0.45
	var painter := preload("res://scenes/GraphWireLayer.gd").new()
	painter.frozen = true
	var rects := {"t1": Rect2(0, 30, 200, 200), "t2": Rect2(400, 180, 200, 200)}
	for step in 4:
		var zoom := [0.4, 2.5, 0.65, 1.8][step] as float
		var offset := Vector2(250, -120) * step
		var project := func(point): return point * zoom + offset
		painter.unproject = func(point): return (point - offset) / zoom
		if step == 2: graph.disconnect_nodes("t1", "t2")
		overlay.sync(rects, graph.edges.values(), project, true)
		if step < 2: route = overlay.sheet_links[0]
		painter.commands.clear()
		overlay.draw_markers(painter)
		var line: Array = painter.commands.back()[1]
		var center: Vector2 = (line[0] + line[1]) * 0.5
		var expected := Overlay.Geometry.at_distance(route.points, route.lengths, route.lengths[-1] * 0.45)
		check(center.is_equal_approx(expected), "The red cross is centered on the live or last painted wire through zoom and pan")
		if step >= 2:
			check(painter.commands[0][1][0] == route.points, "Cancellation draws its faint wire from the same sheet geometry")
	painter.free()
	parent.free()
	graph.free()


func journal_row(id: String, revision: int, status: String, pending := false) -> Dictionary:
	return {"event_id":id, "source":"t1", "target":"t2", "source_port":"send", "target_port":"in",
		"edge":"t1/send>t2/in", "edge_revision":revision, "status":status, "pending":pending,
		"queued_at":1.0, "updated_at":2.0}


func test_same_ports_reconnected() -> void:
	var graph := preload("res://scenes/AgentGraph.gd").new()
	var owner := Node.new()
	var overlay := Overlay.new()
	root.add_child(overlay)
	overlay.graph = graph
	var edge := {"from":"t1","to":"t2","from_port":"send","to_port":"in","send":true,"revision":1}
	var snapshot := {"nodes":[{"node":"t1","provider":"codex"},{"node":"t2","provider":"codex"}],
		"edges":[edge], "queues":{}, "journal":{"events":[]}}
	var rects := {"t1":Rect2(0,0,200,200), "t2":Rect2(600,0,200,200)}
	var project := func(point): return point
	graph.import_remote(owner, snapshot)
	overlay.sync(rects, graph.edges.values(), project, true)
	var old_path: PackedVector2Array = overlay.sheet_links[0].points
	var pending := journal_row("old-pending", 1, "queued in Codex", true)
	snapshot.journal.events = [pending, journal_row("in-flight", 1, "delivered")]
	graph.import_remote(owner, snapshot)
	check(overlay.waiting.size() == 1 and overlay.pulses.size() == 1, "The original wire has a pending indicator and a moving delivery")

	# One snapshot can coalesce removal and reconnect before the next frame.
	# Move the receiver to give its replacement a visibly different path.
	edge.revision = 2
	graph.import_remote(owner, snapshot)
	rects.t2.position += Vector2(0, 250)
	overlay.sync(rects, graph.edges.values(), project, true)
	overlay._process(0.0)
	check(overlay.waiting.is_empty() and overlay.pulses.is_empty(), "The replacement wire inherits neither a queued indicator nor a moving delivery")
	var fresh := journal_row("fresh", 2, "queued in Codex", true)
	snapshot.journal.events = [pending, fresh, journal_row("late-success", 1, "delivered"),
		journal_row("unseen-failure", 1, "failed: delayed")]
	snapshot.queues = {"t2":[pending, fresh]}
	graph.import_remote(owner, snapshot)
	check(overlay.waiting.size() == 1 and overlay.waiting.values()[0].ids.keys() == ["fresh"],
		"Only the new revision's pending event contributes a queue indicator")
	check(overlay.pulses.is_empty(), "Late unseen outcomes cannot animate the same ports' replacement wire")

	snapshot.queues = {}
	snapshot.journal.events = [journal_row("old-pending", 1, "failed: delayed"), journal_row("fresh", 2, "delivered")]
	graph.import_remote(owner, snapshot)
	var failures_on_old := overlay.pulses.filter(func(p): return p.event_id == "old-pending" and p.get("failed", false))
	var successes_on_new := overlay.pulses.filter(func(p): return p.event_id == "fresh" and not p.get("failed", false))
	check(overlay.waiting.is_empty() and failures_on_old.size() == 1 and successes_on_new.size() == 1,
		"The cached failure and the current delivery each animate once after terminal status arrives")
	if failures_on_old.size() == 1:
		var route: Dictionary = overlay._pulse_route(failures_on_old[0])
		check(route.detached and route.link.points == old_path, "The delayed failure follows its original detached geometry")
	if successes_on_new.size() == 1:
		var route: Dictionary = overlay._pulse_route(successes_on_new[0])
		check(route.link.points == overlay.links[0].points and route.link.points != old_path, "The new success follows the replacement wire")
	overlay.free()
	graph.free()
	owner.free()
