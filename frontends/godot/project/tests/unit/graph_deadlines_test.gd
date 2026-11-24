extends "res://tests/unit/test_case.gd"
const Graph := preload("res://scenes/AgentGraph.gd")

func test_expired_edges_are_displayed_without_frontend_cancellation() -> void:
	var graph := Graph.new()
	var owner := Node.new()
	var edge := {"from":"t1", "to":"t2", "from_port":"send", "to_port":"in", "send":true, "stop_at":1.0, "revision":1}
	var event := {"source":"t1", "target":"t2", "source_port":"send", "target_port":"in", "event_id":"pending", "edge_revision":1}
	graph.import_remote(owner, {"nodes":[{"node":"t1"},{"node":"t2"}], "edges":[edge], "queues":{"t2":[event]}})
	expect(graph.connection_expired(edge), "View can style the server's expired deadline")
	expect(graph.queues["t2"].size() == 1, "The view waits for authoritative cancellation instead of consuming a queue")
	expect(not graph.connection_expired({}), "No deadline remains active")
	graph.import_remote(owner, {"nodes":[{"node":"t1"},{"node":"t2"}], "edges":[edge], "queues":{"t2":[]}})
	expect(graph.queues["t2"].is_empty() and graph.edges.size() == 1, "Server cancellation clears the queue while retaining the visible edge")
	graph.free()
	owner.free()
