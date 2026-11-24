extends "res://tests/unit/test_case.gd"
const Protocol := preload("res://scenes/remote/RemoteProtocol.gd")
const Presentation := preload("res://scenes/remote/RemotePresentation.gd")


func test_graph_snapshot_maps_node_and_wire_identities() -> void:
	var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
	connection.namespace_ids = true
	connection.local_ids = {1: 101, 2: 102}
	var edge := {"from": "t1", "to": "t2", "from_port": "send", "to_port": "in"}
	var manifest := {"inputs": [], "outputs": [{"id": "send", "name": "Send", "color": "#89ddbd"}]}
	var mapped: Dictionary = connection._map_topology({
		"panes": [], "tabs": [],
		"graph": {"nodes": [{"node": "t1", "manifest": manifest}], "edges": [edge],
			"journal": {"events": [{"source": "t1", "target": "t2", "edge": "t1/send>t2/in"}], "by_edge": {"t1/send>t2/in": {"pending": 1, "total": 1}}},
			"limits": {"pending_per_node": 17, "run_messages": 23}},
	})
	expect(mapped.graph.edges[0].from == "t101" and mapped.graph.edges[0].to == "t102", "Wires use this connection's pane namespace")
	expect(mapped.graph.nodes[0].node == "t101", "Nodes use the same mapped identity")
	expect(mapped.graph.nodes[0].manifest == manifest, "Server socket definitions are preserved")
	expect(mapped.graph.journal.events[0].edge == "t101/send>t102/in", "Delivery rows use the connection's pane namespace")
	expect(mapped.graph.journal.by_edge.has("t101/send>t102/in"), "Journal counts use the same mapped connection keys")
	expect(mapped.graph.limits.pending_per_node == 17 and mapped.graph.limits.run_messages == 23, "Server limits pass through without frontend defaults")
	connection.free()


func test_topology_mapping_cache_preserves_edits_and_namespace_changes() -> void:
	var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
	connection.namespace_ids = true
	connection.local_ids = {1: 101}
	var source := {"panes": [{"id": 1, "tab": 1}], "tabs": [{"id": 1, "sessions": [1]}], "graph": {"nodes": [{"node": "t1", "status": "idle"}]},
		"workspace_state": {"layout": {"tabs": {"1": {"focused": "t1"}}}, "tabs": {"1": {}}, "order": [1], "active": 1}}
	var first: Dictionary = connection._map_topology(source)
	expect(source.panes[0].id == 1 and source.tabs[0].sessions == [1] and first.panes[0].id == 101, "Mapping detaches mutable pane and tab lists from the owner message")
	first.graph.nodes[0].status = "mutated"
	first.workspace_state.layout.tabs["101"].focused = "t999"
	var again: Dictionary = connection._map_topology(source)
	expect(again.graph.nodes[0].status == "idle" and again.workspace_state.layout.tabs["101"].focused == "t101", "Presentation mutations cannot poison cached owner snapshots")
	source.graph.nodes[0].status = "working"
	expect(connection._map_topology(source).graph.nodes[0].status == "working", "Changed graph content replaces its cached mapping")
	connection.local_ids = {1: 201}
	var remapped: Dictionary = connection._map_topology(source)
	expect(remapped.graph.nodes[0].node == "t201" and remapped.workspace_state.order == [201], "Namespace replacement invalidates both cached mappings")
	connection.free()


func test_binary_input_preserves_arbitrary_bytes() -> void:
	var input := "한글 é".to_utf8_buffer()
	input.append_array(PackedByteArray([0, 27, 255]))
	var decoded := Protocol.unpack(Protocol.pack({ "type": "input", "session": 7 }, input))
	expect(
		decoded.header.type == "input" and int(decoded.header.session) == 7,
		"Envelope carries routing metadata",
	)
	expect(decoded.payload == input, "Binary input is not coerced through a text encoding")


func test_native_metadata_preserves_integer_types_and_precision() -> void:
	var metadata := '{"type":"terminal","session":7,"scene":{"revision":9007199254740993,"offset":0}}'
	var packet := PackedByteArray()
	packet.resize(8)
	packet.encode_u32(0, Protocol.MAGIC)
	packet.encode_u32(4, metadata.to_utf8_buffer().size())
	packet.append_array(metadata.to_utf8_buffer())
	var decoded := Protocol.unpack(packet)
	expect(decoded.header_json == metadata, "Native scene decoder receives integer metadata without float conversion or precision loss")


func test_packet_bounds_reject_truncated_and_invalid_headers() -> void:
	var packet := Protocol.pack({ "type": "input" }, PackedByteArray())
	expect(Protocol.unpack(packet.slice(0, 7)) == null, "Truncated envelope is rejected")
	packet.encode_u32(4, 0xffffffff)
	expect(Protocol.unpack(packet) == null, "Header length cannot exceed the packet")
	packet.encode_u32(4, 2)
	packet.resize(10)
	packet[8] = 91
	packet[9] = 93
	expect(Protocol.unpack(packet) == null, "JSON arrays cannot act as routing objects")


func test_wide_spacers_and_combining_text_keep_cell_positions() -> void:
	var frame := {
		"foreground": "#ffffff",
		"background": "#000000",
		"cursor": [4, 0],
		"input_modes": [],
		"kitty_keys": 0,
	}
	var row := [
		[0, 2, "한", "#ffffff", "#ff0000", 0],
		[1, 1, "", "#ffffff", "#ff0000", 0],
		[2, 1, "é", "#ffffff", "#000000", 0],
	]
	var encoded := Presentation.encode(frame, [[0, row]], true).get_string_from_utf8()
	expect(
		encoded.contains("한") and encoded.contains("é"),
		"Graphemes remain whole in the presentation stream",
	)
	expect(
		not encoded.contains("\u001b[1;2H"),
		"A wide-tail background never erases half the glyph",
	)
