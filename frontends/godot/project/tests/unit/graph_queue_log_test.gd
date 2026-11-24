extends "res://tests/unit/test_case.gd"
const Journal := preload("res://scenes/GraphQueueLog.gd")
const Graph := preload("res://tests/support/ServerGraph.gd")

class ObservedInspector extends "res://scenes/GraphQueueInspector.gd":
	var refresh_count := 0
	func refresh(force := false) -> void:
		refresh_count += 1
		super.refresh(force)

func test_inspector_coalesces_changes_and_does_not_poll_hidden_or_unrelated_queues() -> void:
	var graph := Graph.new()
	var inspector := ObservedInspector.new()
	inspector._ready()
	inspector._bind_graph(graph)
	inspector.edge_key = "t1>t2"
	inspector.visible = true
	inspector.refresh()
	var count := inspector.refresh_count
	record(graph.queue_log, event("a"), "queued", true)
	record(graph.queue_log, event("a"), "sent", false)
	expect(inspector.refresh_count == count, "Queue bursts do not rebuild the tree synchronously")
	inspector._flush_refresh()
	expect(inspector.refresh_count == count + 1 and inspector.rows[0].status == "sent", "A coalesced refresh shows the latest delivery state")
	count = inspector.refresh_count
	var other := event("b")
	other.target = "t3"
	record(graph.queue_log, other, "queued", true)
	graph.changed.emit()
	inspector._flush_refresh()
	expect(inspector.refresh_count == count, "Unrelated queues and graph metadata do not snapshot the journal")
	inspector.visible = false
	record(graph.queue_log, event("c"), "queued", true)
	inspector._flush_refresh()
	expect(inspector.refresh_count == count, "Hidden inspectors perform no journal refresh")
	inspector.visible = true
	# Unit windows are outside a SceneTree, which normally sends this event.
	inspector.visibility_changed.emit()
	inspector._flush_refresh()
	expect(inspector.rows.size() == 2, "Reopening catches changes made while hidden")
	inspector._disconnect_graph()
	expect(not graph.queue_log.changed.is_connected(inspector._journal_changed), "Inspector releases its journal subscription")
	inspector.free()
	graph.free()

func event(id: String) -> Dictionary:
	return {"event_id":id, "edge_revision":1, "source":"t1", "target":"t2", "kind":"test", "created":1.0, "text":"private", "payload":{"secret":"private"}, "sessions":[{"path":"/private"}]}

func test_connection_inspector_updates_in_place_and_excludes_other_wires() -> void:
	var g := Graph.new()
	g.nodes = {"t1":{"provider":"claude"}, "t2":{"provider":"codex"}, "t3":{"provider":"codex"}}
	g.connect_nodes({"from":"t1", "to":"t2", "send":true})
	g.connect_nodes({"from":"t1", "to":"t3", "send":true})
	var sent: Dictionary = g.enqueue("t1", "t2", "private", "message")
	g.enqueue("t1", "t3", "other private", "message")
	var key := g.event_edge(g.queues["t2"][0])
	var inspector := preload("res://scenes/GraphQueueInspector.gd").new()
	inspector._ready()
	inspector.graph = g
	inspector.edge_key = key
	inspector.refresh(true)
	expect(inspector.rows.size() == 1 and inspector.summary.text.contains("pane t1"), "Wire inspector shows only its connection with public pane names")
	expect(inspector.events.get_root().get_first_child().get_text(0).begins_with("[ ]"), "Pending delivery starts unchecked")
	expect(g.queues["t2"].size() == 1, "Opening the inspector does not consume input")
	var item_id := inspector.events.get_root().get_first_child().get_instance_id()
	g.ack("t2", sent.result.event_id, "delivered")
	inspector.refresh()
	expect(inspector.events.get_root().get_first_child().get_instance_id() == item_id, "Delivery status updates preserve the existing TreeItem")
	expect(inspector.rows.size() == 1 and inspector.events.get_root().get_first_child().get_text(0).begins_with("[x]"), "The same row becomes sent")
	expect(inspector.selected == sent.result.event_id and inspector.details.text.contains("queued in Graffitty") and inspector.details.text.contains("sent to receiver"), "Selection and full transition history survive updates")
	expect(not inspector.details.text.contains("private"), "Inspection does not expose message contents")
	inspector.pending_only.button_pressed = true
	expect(inspector.rows.is_empty(), "Pending-only filter hides completed rows")
	inspector.free()
	g.free()

func test_reconnected_wire_tooltip_and_open_inspector_show_only_its_revision() -> void:
	var graph := Graph.new()
	var key := "t1>t2"
	graph.edges[key] = {"from":"t1","to":"t2","revision":1,"created_revision":1}
	var old := event("old")
	record(graph.queue_log, old, "queued in Codex", true)
	graph.receipts = [{"edge":key,"edge_revision":1,"status":"queued in Codex","message":"old delivery"}]
	var overlay := preload("res://scenes/AgentGraphOverlay.gd").new()
	overlay.graph = graph
	var inspector := ObservedInspector.new()
	inspector._ready()
	inspector._bind_graph(graph)
	inspector.edge_key = key
	inspector.visible = true
	inspector.refresh()
	expect(inspector.rows.size() == 1 and "old delivery" in overlay.edge_tooltip(key), "The original connection has its pending event")
	graph.edges[key].revision = 2
	graph.edges[key].muted = true
	graph.changed.emit()
	inspector._flush_refresh()
	expect(inspector.rows.size() == 1 and "old delivery" in overlay.edge_tooltip(key), "Pausing retains prior deliveries and receipts")
	graph.edges[key].erase("created_revision")
	graph.changed.emit()
	inspector._flush_refresh()
	expect(inspector.rows.is_empty() and "old delivery" not in overlay.edge_tooltip(key), "A new optimistic connection has no history")
	graph.edges[key].revision = 4
	graph.edges[key].created_revision = 4
	graph.changed.emit()
	inspector._flush_refresh()
	var hint := overlay.edge_tooltip(key)
	expect(inspector.rows.is_empty() and inspector.last_snapshot.pending == 0, "An open inspector refreshes on replacement even without a journal transition")
	expect("0 pending · 0 recorded deliveries" in hint and "old delivery" not in hint, "The replacement tooltip has no earlier pending work or receipt")
	var current := event("current")
	current.edge_revision = 4
	record(graph.queue_log, current, "queued", true)
	inspector._flush_refresh()
	expect(inspector.rows.size() == 1 and inspector.rows[0].event_id == "current", "The replacement inspector lists its own event")
	expect(graph.queue_log.snapshot(key).events.size() == 2 and graph.queue_log.snapshot().pending == 2, "Aggregate queries retain both revisions")
	inspector._disconnect_graph()
	inspector.free()
	overlay.free()
	graph.free()

func record(log: RefCounted, event: Dictionary, status: String, pending: bool) -> void:
	var id := str(event.event_id)
	var rows: Dictionary = log.entries.duplicate(true)
	rows[id] = {"event_id":id,"edge_revision":event.edge_revision,"source":event.source,"target":event.target,"edge":event.source+">"+event.target,"kind":"test","queued_at":1.0,"updated_at":2.0,"status":status,"pending":pending,"transitions":[],"run_id":""}
	var counts := {}
	var pending_count := 0
	for row in rows.values():
		if not counts.has(row.edge): counts[row.edge] = {"total":0,"pending":0,"by_revision":{}}
		var revision_counts: Dictionary = counts[row.edge].by_revision.get_or_add(str(row.edge_revision), {"total":0,"pending":0})
		revision_counts.total += 1
		counts[row.edge].total += 1
		if row.pending:
			counts[row.edge].pending += 1
			revision_counts.pending += 1
			pending_count += 1
	log.import_snapshot(null, {"events":rows.values(),"pending":pending_count,"omitted":0,"by_edge":counts})
