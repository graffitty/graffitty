extends "res://tests/unit/test_case.gd"

const PaneAddress := preload("res://scenes/PaneAddress.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")

const App := preload("res://scenes/TerminalApplication.gd")

class Client extends Node:
	var federated := false
	var primary_presentation := true
	var presentation_tabs: Array = []
	var settings := {}
	var connection: Node

class Graph extends Node:
	var edges := {}

class API extends Node:
	var graph := Graph.new()

class Chromium extends RefCounted:
	var owner_id: int
	func _init(owner: int) -> void: owner_id = owner

class Host extends Node:
	var chromiums := {}
	var sessions := {}
	var agent_api := API.new()
	var workspace_layout := Layout.new()
	var close_dialog = null
	var session_backend: Node
	var layout_transaction := false
	func focus_pane(key: String) -> void:
		workspace_layout.active = workspace_layout.containing(key)

class Connection extends Node:
	var url := "ws://owner-a"
	var epoch := "owner-a"
	var host: Node
	var enabled := true
	var calls: Array = []
	func request_action(kind: String, request: Dictionary) -> Dictionary:
		calls.append({"kind": kind, "request": request})
		var layout = host.workspace_layout
		var source: Dictionary = layout.tab(layout.containing(request.pane))
		source.tree.windows = source.tree.windows.filter(func(w): return w.pane != request.pane)
		var id: int = 3 if request.tab == null else int(request.tab)
		if layout.tab(id).is_empty():
			layout.add(id, {"windows": [Layout.leaf(request.pane)], "tiling": enabled})
		else:
			layout.tab(id).tree.windows.append(Layout.leaf(request.pane))
		return {"tab": id}

class Backend extends Node:
	var is_remote := true
	var connection: Node
	var committed := {}
	func commit_workspace(host: Node) -> void:
		committed = host.workspace_layout.tab(host.workspace_layout.active).duplicate(true)

class Federation extends Node:
	var owners := {}

func fixture(count: int, enabled := true) -> Dictionary:
	var app := App.new()
	var client := Client.new()
	var host := Host.new()
	client.add_child(host)
	var backend := Backend.new()
	var connection := Connection.new()
	connection.host = host
	connection.enabled = enabled
	client.connection = connection
	backend.connection = connection
	host.session_backend = backend
	var panes: Array = []
	for i in count: panes.append(Layout.leaf(PaneAddress.key((i + 1))))
	host.workspace_layout.add(1, {"windows": panes, "tiling": not enabled})
	return {"app": app, "host": host, "connection": connection, "backend": backend}

func test_remote_rearrangement_stays_within_its_owner() -> void:
	var a := fixture(2)
	var b := fixture(2)
	b.connection.url = "ws://owner-b"
	expect(a.app._compatible_shared_hosts(a.host, a.host), "Remote clients can regroup their own tabs and panes")
	expect(not a.app._compatible_shared_hosts(a.host, b.host), "Different endpoints cannot transfer panes even if epochs match")
	b.connection.url = a.connection.url
	b.connection.epoch = "owner-b"
	expect(not a.app._compatible_shared_hosts(a.host, b.host), "Different owners cannot receive each other's panes")
	b.connection.epoch = a.connection.epoch
	expect(a.app._compatible_shared_hosts(a.host, b.host), "Presentations of the same endpoint and owner can transfer panes")

func test_federated_tabs_only_merge_on_their_own_transport() -> void:
	var f := fixture(2)
	var other := Connection.new()
	var federation := Federation.new()
	federation.owners = {1: f.connection, 2: f.connection, 3: other}
	f.backend.connection = federation
	f.host.workspace_layout.add(2, {"windows": [Layout.leaf("t9")], "tiling": true})
	expect(f.app._compatible_tab_owners(f.host, 1, f.host, 2), "Tabs on one remote transport can merge")
	expect(not f.app._compatible_tab_owners(f.host, 1, f.host, 3), "Tabs from independent connections cannot merge")
	expect(not f.app._compatible_tab_owners(f.host, 7, f.host, 2), "A missing owner cannot fall back to the selected connection")
	expect(f.app.move_pane(f.host, f.host, "t1", 2), "Federated moves route the regroup request to the source owner")
	expect(f.connection.calls.size() == 1 and other.calls.is_empty(), "Only the owning connection receives the move")

func test_only_pane_cannot_replace_its_own_tab() -> void:
	var f := fixture(1)
	expect(not f.app._can_create_pane_tab(f.host, f.host, "t1"), "No new-tab preview for a sole pane")
	# This exits before any await or owner request.
	expect(not f.app.move_pane(f.host, f.host, "t1"), "The mutation path also rejects a redundant tab")
	expect(f.connection.calls.is_empty(), "No regroup request is sent")
	expect(f.host.workspace_layout.containing("t1") == 1, "Original tab identity remains unchanged")

func test_connected_group_filling_its_tab_cannot_replace_it() -> void:
	var f := fixture(2)
	# A terminal carries its chromium, so dragging either one moves the whole tab.
	f.host.chromiums = {2: Chromium.new(1)}
	for key in ["t1", "t2"]:
		expect(not f.app._can_create_pane_tab(f.host, f.host, key), "No new-tab preview when %s carries its whole tab" % key)
	expect(not f.app.move_pane(f.host, f.host, "t1"), "The mutation path also rejects a tab that would only be renamed")
	expect(f.connection.calls.is_empty() and f.host.workspace_layout.containing("t2") == 1, "No regroup request is sent")
	f.host.chromiums.clear()
	f.host.agent_api.graph.edges = {"wire": {"from": "t1", "to": "t2"}}
	expect(not f.app._can_create_pane_tab(f.host, f.host, "t2"), "Graph-connected panes filling their tab stay put")
	f.host.workspace_layout.tab(1).tree.windows.append(Layout.leaf("t3"))
	expect(f.app._can_create_pane_tab(f.host, f.host, "t1"), "A group leaving a pane behind still opens a new tab")
	expect(f.app._can_create_pane_tab(f.host, f.host, "t3"), "So does the pane it leaves behind")

func test_new_pane_tab_preserves_owner_tiling_default() -> void:
	for enabled in [true, false]:
		var f := fixture(2, enabled)
		expect(f.app.move_pane(f.host, f.host, "t1"), "A pane can split from a multi-pane tab")
		expect(f.backend.committed.tree.tiling == enabled, "The owner default survives the frontend commit")
		expect(f.host.workspace_layout.containing("t2") == 1, "Other pane stays in the source tab")

func test_only_pane_can_move_into_existing_tab_or_another_host() -> void:
	var f := fixture(1)
	f.host.workspace_layout.add(2, {"windows": [Layout.leaf("t2")], "tiling": true})
	expect(f.app._can_create_pane_tab(f.host, Host.new(), "t1"), "New-session/presentation transfer remains available")
	expect(f.app.move_pane(f.host, f.host, "t1", 2), "A sole pane can move into another existing tab")
	expect(f.backend.committed.id == 2 and f.backend.committed.tree.tiling, "Destination tab keeps its layout mode")

func test_connected_group_includes_incoming_muted_and_transitive_edges() -> void:
	var f := fixture(4)
	f.host.agent_api.graph.edges = {
		"a": {"from": "t1", "to": "t2"},
		"b": {"from": "t3", "to": "t2", "muted": true},
		"c": {"from": "t3", "to": "t1"},
	}
	var keys: Array = f.app.pane_transfer_keys(f.host, "t2")
	keys.sort()
	expect(keys == ["t1", "t2", "t3"], "Whole component moves, unrelated pane stays")
	f.app.drag = {"pane": "t2", "rectangles": {
		"t1": Rect2(-500, 70, 400, 300), "t2": Rect2(50, 90, 500, 350), "t3": Rect2(900, 800, 600, 450)}}
	var placed: Dictionary = f.app._pane_group_drop_rectangles(Rect2(200, 400, 500, 350))
	for key in placed:
		expect(placed[key].position - f.app.drag.rectangles[key].position == Vector2(150, 310), "All panes receive one translation")
		expect(placed[key].size == f.app.drag.rectangles[key].size, "Pane sizes remain unchanged")

func test_connected_group_preview_preserves_geometry_inside_tiled_destination() -> void:
	var incoming := {"windows": [Layout.leaf("t1"), Layout.leaf("t2")]}
	for item in incoming.windows: item.graph_floating = true
	var placed := {"t1": Rect2(100, 200, 400, 300), "t2": Rect2(750, 300, 500, 350)}
	var tree := {"windows": [Layout.leaf("t9")], "tiling": true}
	var plan := Layout.preview_placement(tree, incoming, placed["t1"], Rect2(0, 0, 1600, 1000), Vector2(200, 250), placed)
	for key in placed: expect(plan.rectangles[key] == placed[key], "Tiling cannot rearrange a graph group")
	var preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
	preview.present(plan, Rect2(0, 0, 1600, 1000), Vector2(200, 250), true)
	for key in placed: expect(preview.rectangles[key] == placed[key], "Preview shows each group member at its committed position")

func test_all_connection_kinds_form_one_bidirectional_transfer_group() -> void:
	var f := fixture(7)
	f.host.chromiums = {4: Chromium.new(1), 5: Chromium.new(2)}
	for id in [1, 2, 3, 6, 7]:
		var term := Node.new()
		if id == 2: term.set_meta("filetree_owner", 1)
		if id == 3: term.set_meta("filetree_owner", 2)
		f.host.sessions[id] = {"term": term}
	f.host.agent_api.graph.edges = {"a": {"from": "t6", "to": "t3", "muted": true}}
	for start in ["t1", "t2", "t3", "t4", "t5", "t6"]:
		var members: Array = f.app.pane_transfer_keys(f.host, start)
		members.sort()
		expect(members == ["t1", "t2", "t3", "t4", "t5", "t6"], "Dragging either endpoint of any connection carries all its peers: " + start)
	var edges: Array = f.app.pane_transfer_connections(f.host)
	expect(edges.size() == 5, "Preview includes graph, chromiums, filetree and editor links")
	expect(f.app.pane_transfer_keys(f.host, "t7") == ["t7"], "Unrelated panes remain independent")
