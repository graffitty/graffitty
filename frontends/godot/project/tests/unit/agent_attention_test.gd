extends "res://tests/unit/test_case.gd"

const PaneAddress := preload("res://scenes/PaneAddress.gd")
## Tab agent markers: real Rust evidence core, fake hosts and graph.
const Attention := preload("res://scenes/AgentAttention.gd")
const TabStrip := preload("res://scenes/TabStrip.gd")


class Graph extends RefCounted:
	signal changed
	var nodes: Dictionary = {}
	var remote_owners: Dictionary = {}


class API extends RefCounted:
	var graph := Graph.new()


class Application extends RefCounted:
	var hosts: Array = []
	var agent_api := API.new()


class Host extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var in_view := true
	func is_terminal_pane(key: String) -> bool: return PaneAddress.id(key) > 0
	func pane_is_presented(_key: String) -> bool: return true


class Peer extends Node:
	var url := "test://receipts"
	var epoch := "same-server"
	var connected := false
	var workspace := "$1"
	var catalog_revision := 1
	var available_sessions: Array = []
	var view_ready := true
	func session_view_ready(id: String) -> bool: return view_ready and id == workspace
	func local_id(id: int) -> int: return id
	func wire_id(id: int) -> int: return id


class Backend extends RefCounted:
	var is_remote := true
	var connection: Node


class RemoteHost extends Host:
	var session_backend := Backend.new()


class CapturedAttention extends "res://scenes/AgentAttention.gd":
	var calls: Array = []
	func _send_receipt(connection: Node, pane: int, event: String) -> void:
		calls.append({"connection": connection, "pane": pane, "event": event})
		_acknowledging.erase([_domain(connection), event])


func test_connected_catalog_retries_cached_read_without_reading_unshown_results() -> void:
	for scenario in ["same", "newer", "missing"]:
		var app := Application.new()
		var cached := RemoteHost.new()
		var other := RemoteHost.new()
		var disconnected := Peer.new()
		var connected := Peer.new()
		connected.connected = true
		connected.workspace = "$2"
		cached.session_backend.connection = disconnected
		other.session_backend.connection = connected
		cached.workspace_layout.tabs = [_tab(1, ["t1"])]
		cached.workspace_layout.active = 1
		other.workspace_layout.tabs = [_tab(2, ["t2"])]
		other.workspace_layout.active = 2
		other.in_view = false
		app.hosts = [cached, other]
		var old_event := {"event":"first", "kind":"completed", "seen":false}
		var catalog_event: Dictionary = old_event.duplicate()
		if scenario == "newer": catalog_event.event = "second"
		connected.available_sessions = [{"id":"$1", "agents":[{"pane":1, "status":"idle", "attention":catalog_event}]}, {"id":"$2", "agents":[]}]
		if scenario != "missing": app.agent_api.graph.nodes = {"t1":{"status":"idle", "attention":old_event}}
		app.agent_api.graph.remote_owners = {"t1":disconnected}
		var attention := CapturedAttention.new()
		attention.application = app
		attention.in_view = func(host): return host.in_view
		attention.refresh()
		if scenario == "same":
			expect(attention.calls == [{"connection":connected, "pane":1, "event":"first"}], "A connected view carries the cached pane's exact receipt")
			expect(attention.marker(cached, ["t1"]).state == "", "Reading the cached event clears its local marker")
		else:
			expect(attention.calls.is_empty(), "Catalog-only evidence cannot acknowledge an unshown result: " + scenario)
			expect(attention.marker(cached, ["t1"]).state == "completed", "The unseen catalog event stays unread: " + scenario)
		attention.free()
		cached.free()
		other.free()
		disconnected.free()
		connected.free()


func test_last_view_gap_retries_only_the_original_epochs_unconfirmed_read() -> void:
	var app := Application.new()
	var attention := CapturedAttention.new()
	attention.application = app
	attention.in_view = func(host): return host.in_view
	var original := RemoteHost.new()
	var restored := RemoteHost.new()
	var first := Peer.new()
	var reconnected := Peer.new()
	first.connected = true
	reconnected.connected = true
	original.session_backend.connection = first
	restored.session_backend.connection = reconnected
	for host in [original, restored]:
		host.workspace_layout.tabs.assign([_tab(1, ["t1"])])
		host.workspace_layout.active = 1
	var event := {"event":"pending", "kind":"completed", "seen":false}
	var row := {"pane":1, "status":"idle", "attention":event, "activity_revision":1}
	for peer in [first, reconnected]:
		peer.available_sessions = [{"id":"$1", "agents":[row.duplicate(true)]}]
	app.hosts = [original]
	attention.refresh()
	expect(attention.calls.size() == 1, "The first view queues its completion receipt")
	app.hosts = []
	attention.refresh()
	expect(attention._remote_cores.size() == 1 and attention.attention(original, "t1") == null,
		"The last view releases its presentation while its receipt remains pending")

	restored.in_view = false
	reconnected.epoch = "replacement"
	app.hosts = [restored]
	attention.refresh()
	expect(attention.calls.size() == 1 and attention.marker(restored, ["t1"]).state == "completed",
		"A replacement epoch showing the same UUID stays unread")
	app.hosts = []
	attention.refresh()
	expect(attention._remote_cores.size() == 1, "The detached epoch with no pending receipts is released")

	reconnected.epoch = first.epoch
	app.hosts = [restored]
	attention.refresh()
	expect(attention.calls.size() == 2 and attention.calls[1] == {"connection":reconnected, "pane":1, "event":"pending"},
		"An offscreen reconnect retries the matching original receipt")
	expect(attention.marker(restored, ["t1"]).count == 0, "The already-viewed result stays read")
	reconnected.available_sessions[0].agents[0].attention.seen = true
	reconnected.available_sessions[0].agents[0].activity_revision += 1
	reconnected.catalog_revision += 1
	attention.refresh()
	app.hosts = []
	attention.refresh()
	expect(attention._remote_cores.is_empty() and attention.calls.size() == 2,
		"After server confirmation the detached epoch is released")
	for item in [attention, original, restored, first, reconnected]: item.free()


class PannedView extends "res://scenes/WorkspaceView.gd":
	func viewport_content_rect() -> Rect2: return Rect2(0, 36, 1280, 684)

class PaneCamera extends Node:
	var origin := Vector2.ZERO
	func sheet_window_fraction(point: Vector2) -> Vector2:
		return (point - origin) / Vector2(1280, 720)

class PannedHost extends RemoteHost:
	var world := PaneCamera.new()
	var workspace_view := PannedView.new()
	func _init() -> void:
		workspace_view.host = self
		workspace_view.size = Vector2(1280, 720)
	func pane_is_presented(key: String) -> bool: return workspace_view.pane_in_content(key)

func test_offscreen_completion_waits_for_the_pane_to_enter_the_content_area() -> void:
	var app := Application.new()
	var host := PannedHost.new()
	var peer := Peer.new()
	peer.connected = true
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [_tab(1, ["t1", "t2"])]
	host.workspace_layout.active = 1
	var pane := Control.new()
	pane.position = Vector2(5000, 5000)
	pane.size = Vector2(240, 160)
	host.workspace_view.panes.t2 = pane
	var event := {"event": "stashed-completion", "kind": "completed", "seen": false}
	peer.available_sessions = [{"id": "$1", "agents": [{"pane": 2, "status": "idle", "attention": event}]}]
	var attention := CapturedAttention.new()
	attention.application = app
	attention.in_view = func(_host): return true
	attention.refresh()
	expect(attention.calls.is_empty() and attention.marker(host, ["t2"]).count == 1, "A shown pane stashed outside the camera keeps its completion")
	host.world.origin = Vector2(5000, 5124)
	attention.refresh()
	expect(attention.calls.is_empty() and attention.marker(host, ["t2"]).count == 1, "A pane touching the content edge behind the tabs stays unread")
	host.world.origin.y -= 1
	attention.refresh()
	expect(attention.calls == [{"connection": peer, "pane": 2, "event": "stashed-completion"}], "Panning part of the pane into content sends its exact receipt")
	expect(attention.marker(host, ["t2"]).count == 0, "The viewed completion clears its marker")
	pane.free()
	host.workspace_view.free()
	host.world.free()
	host.free()
	peer.free()
	attention.free()


func test_floating_panes_cover_only_their_visible_union() -> void:
	var host := PannedHost.new()
	var view := host.workspace_view
	var canvas := Control.new()
	for key in ["t1", "t2", "t3"]:
		var control := Control.new()
		canvas.add_child(control)
		view.panes[key] = control
	var pane: Control = view.panes.t1
	var left: Control = view.panes.t2
	var right: Control = view.panes.t3
	pane.position = Vector2(100, 100)
	pane.size = Vector2(200, 100)
	left.position = pane.position
	left.size = Vector2(100, 100)
	right.position = Vector2(200, 100)
	right.size = left.size
	var app := Application.new()
	var peer := Peer.new()
	peer.connected = true
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [_tab(1, ["t1", "t2", "t3"])]
	host.workspace_layout.active = 1
	var event := {"event": "covered-completion", "kind": "completed", "seen": false}
	peer.available_sessions = [{"id": "$1", "agents": [{"pane": 1, "status": "idle", "attention": event}]}]
	var attention := CapturedAttention.new()
	attention.application = app
	attention.in_view = func(_host): return true
	attention.refresh()
	expect(attention.calls.is_empty() and attention.marker(host, ["t1"]).count == 1, "Jointly covered completion stays unread")
	right.position.x += 1
	attention.refresh()
	expect(attention.calls == [{"connection": peer, "pane": 1, "event": "covered-completion"}], "A narrow gap sends the covered pane’s exact receipt")
	right.position.x -= 1
	right.rotation = PI
	right.position += right.size
	expect(not view.pane_in_content("t1"), "Rotated cover geometry hides the entire result")
	right.visible = false
	expect(view.pane_in_content("t1"), "Hidden covers expose the result")
	host.world.origin.x = 201
	right.visible = true
	left.visible = false
	expect(not view.pane_in_content("t1"), "An uncovered area outside the viewport cannot count as viewed")
	right.z_index = -1
	expect(view.pane_in_content("t1"), "A pane behind the result cannot cover it")
	host.world.origin = Vector2.ZERO
	pane.size = Vector2(100, 100)
	right.position = pane.position
	right.size = pane.size
	right.pivot_offset = right.size / 2
	right.rotation = PI / 4
	right.z_index = 1
	expect(view.pane_in_content("t1"), "A rotated cover's bounding box cannot hide exposed corners")
	attention.free()
	peer.free()
	canvas.free()
	view.free()
	host.world.free()
	host.free()


func test_live_completion_receipt_in_either_snapshot_order() -> void:
	for scenario in ["catalog_first", "graph_first", "unfocused", "switching", "other_session"]:
		var app := Application.new()
		var host := RemoteHost.new()
		var peer := Peer.new()
		peer.connected = true
		peer.view_ready = scenario != "switching"
		host.session_backend.connection = peer
		host.workspace_layout.tabs = [_tab(1, ["t1"])]
		host.workspace_layout.active = 1
		host.in_view = scenario != "unfocused"
		app.hosts = [host]
		var event := {"event":"completion", "kind":"completed", "seen":false}
		var agent := {"pane":1, "status":"idle", "attention":event, "activity_revision":2}
		var catalog := [{"id":"$2" if scenario == "other_session" else "$1", "agents":[agent]}]
		if scenario == "catalog_first":
			app.agent_api.graph.nodes["t1"] = {"status":"busy","activity_revision":1}
			app.agent_api.graph.remote_owners["t1"] = peer
		if scenario == "graph_first":
			peer.available_sessions = [{"id":"$1","agents":[{"pane":1,"status":"busy","activity_revision":1}]}]
			app.agent_api.graph.nodes["t1"] = agent
			app.agent_api.graph.remote_owners["t1"] = peer
		else:
			peer.available_sessions = catalog
		var attention := CapturedAttention.new()
		attention.application = app
		attention.in_view = func(h): return h.in_view
		attention.refresh()
		var watched: bool = scenario in ["catalog_first", "graph_first"]
		expect(attention.marker(host, ["t1"]).count == (0 if watched or scenario == "other_session" else 1), "Tab marker: " + scenario)
		expect(attention.project_attention(event, peer).seen == watched, "Agents panel receipt: " + scenario)
		expect(attention.calls.size() == int(watched), "Only the presented pane sends a receipt: " + scenario)
		if watched:
			host.in_view = false
			peer.available_sessions = catalog
			app.agent_api.graph.nodes["t1"] = agent
			app.agent_api.graph.remote_owners["t1"] = peer
			attention.refresh()
			expect(attention.marker(host, ["t1"]).count == 0 and attention.attention(host, "t1").seen, "The second update keeps both projections seen")
		attention.free()
		host.free()
		peer.free()


class ViewPeer extends Peer:
	var topology := {"workspace":"$1", "graph":{"nodes":[]}}


class WirePeer extends ViewPeer:
	var wire := 7
	func wire_id(_id: int) -> int: return wire


func test_only_matching_graph_attachment_may_override_catalog_membership() -> void:
	var peer := WirePeer.new()
	var owner := WirePeer.new()
	var row := {"activity_revision": 100}
	var catalog := {"revision": 2, "destinations": {7: "$2"}}
	for mismatch in ["none", "server", "epoch", "workspace", "snapshot", "wire", "missing"]:
		owner.url = "test://other" if mismatch == "server" else peer.url
		owner.epoch = "other" if mismatch == "epoch" else peer.epoch
		owner.workspace = "$2" if mismatch == "workspace" else peer.workspace
		owner.topology.workspace = "$2" if mismatch == "snapshot" else peer.workspace
		owner.wire = 8 if mismatch == "wire" else peer.wire
		var candidate := Attention.graph_node_for(peer, 1, null if mismatch == "missing" else owner, row)
		expect(Attention.outside_catalog(catalog, peer.wire, peer.workspace, candidate) == (mismatch != "none"),
			"Only the matching graph revision overrides the inventory: " + mismatch)
	peer.free()
	owner.free()


func test_disconnected_visible_window_cannot_read_another_windows_new_graph() -> void:
	var app := Application.new()
	var cached := RemoteHost.new()
	var current := RemoteHost.new()
	var old := ViewPeer.new()
	var new_peer := ViewPeer.new()
	new_peer.connected = true
	cached.session_backend.connection = old
	current.session_backend.connection = new_peer
	current.in_view = false
	for host in [cached, current]:
		host.workspace_layout.tabs.assign([_tab(1, ["t1"])])
		host.workspace_layout.active = 1
	app.hosts = [cached, current]
	old.topology.graph.nodes = [{"node":"t1","status":"idle","activity_revision":2,
		"attention":{"event":"cached", "kind":"completed","seen":false}}]
	var newest := {"node":"t1","status":"idle","activity_revision":4,
		"attention":{"event":"new", "kind":"completed","seen":false}}
	new_peer.topology.graph.nodes = [newest]
	app.agent_api.graph.nodes = {"t1":newest}
	app.agent_api.graph.remote_owners = {"t1":new_peer}
	var attention := CapturedAttention.new()
	attention.application = app
	attention.in_view = func(host): return host.in_view
	attention.refresh()
	expect(attention.calls.is_empty() and attention.marker(current, ["t1"]).count == 1,
		"A cached window cannot read a UUID that only an unfocused window received")
	current.in_view = true
	attention.refresh()
	expect(attention.calls.size() == 1 and attention.calls[0].event == "new", "Showing the current view reads its own event")
	attention.free()
	cached.free()
	current.free()
	old.free()
	new_peer.free()


func test_replacement_epoch_uses_visible_receipt_even_with_lower_revision() -> void:
	for old_first in [false, true]:
		var app := Application.new()
		var cached := RemoteHost.new()
		var current := RemoteHost.new()
		var old := ViewPeer.new()
		var replacement := ViewPeer.new()
		replacement.epoch = "replacement"
		replacement.connected = true
		cached.session_backend.connection = old
		current.session_backend.connection = replacement
		cached.in_view = false
		for host in [cached, current]:
			host.workspace_layout.tabs.assign([_tab(1, ["t1"])])
			host.workspace_layout.active = 1
		app.hosts = [cached, current] if old_first else [current, cached]
		old.topology.graph.nodes = [{"node":"t1","status":"idle","activity_revision":20,
			"attention":{"event":"old", "kind":"completed","seen":false}}]
		replacement.topology.graph.nodes = [{"node":"t1","status":"idle","activity_revision":3,
			"attention":{"event":"replacement", "kind":"completed","seen":false}}]
		app.agent_api.graph.nodes = {"t1":old.topology.graph.nodes[0]}
		app.agent_api.graph.remote_owners = {"t1":old}
		var attention := CapturedAttention.new()
		attention.application = app
		attention.in_view = func(host): return host.in_view
		attention.refresh()
		expect(attention.calls == [{"connection":replacement,"pane":1,"event":"replacement"}], "Only the replacement peer receives its visible event")
		expect(attention.attention(current, "t1").event == "replacement", "The replacement activity wins regardless of host order")
		for entry in [attention, cached, current, old, replacement]: entry.free()


class NamespacedPeer extends "res://scenes/remote/RemoteConnection.gd":
	func fonts_ready() -> bool: return true


func test_colliding_window_keys_keep_independent_markers_and_receipts() -> void:
	for same_epoch in [true, false]:
		for hidden_newer in [true, false]:
			var app := Application.new()
			var hidden := RemoteHost.new()
			var shown := RemoteHost.new()
			var direct := NamespacedPeer.new()
			var mapped := NamespacedPeer.new()
			mapped.namespace_ids = true
			var wire := 2002
			var local := mapped.local_id(wire)
			var key := PaneAddress.key(local)
			var waiting := {"pane":local,"status":"waiting","activity_revision":50 if hidden_newer else 2,
				"attention":{"event":"hidden-request","kind":"waiting","seen":false}}
			var completed := {"pane":wire,"status":"idle","activity_revision":20,
				"attention":{"event":"visible-result","kind":"completed","seen":false}}
			for peer in [direct, mapped]:
				peer.connected = true
				peer.url = "test://receipts"
				peer.epoch = "shared" if same_epoch or peer == direct else "replacement"
				peer.workspace = "$1"
				peer.catalog_revision = 100
				peer.available_sessions = [{"id":"$1","agents":[waiting, completed]}]
				peer.topology = {"workspace":"$1","graph":{"nodes":[]}}
				for row in [waiting, completed]:
					peer.topology.graph.nodes.append(row.merged({"node":PaneAddress.key(peer.local_id(row.pane))}))
			hidden.session_backend.connection = direct
			shown.session_backend.connection = mapped
			for host in [hidden, shown]:
				host.in_view = false
				host.workspace_layout.tabs.assign([_tab(1, [key])])
				host.workspace_layout.active = 1
			app.hosts = [hidden, shown]
			var attention := CapturedAttention.new()
			attention.application = app
			attention.in_view = func(host): return host.in_view
			attention.refresh()
			expect(attention.marker(hidden, [key]).state == "waiting" and attention.marker(shown, [key]).state == "completed",
				"Each window shows only its own pane's marker")
			shown.in_view = true
			attention.refresh()
			expect(attention.calls == [{"connection":mapped,"pane":local,"event":"visible-result"}],
				"Only the viewed attachment sends its exact wire receipt")
			expect(attention.marker(hidden, [key]).state == "waiting" and attention.marker(shown, [key]).count == 0,
				"Reading the completion preserves the other view's waiting marker")
			for item in [attention, hidden, shown, direct, mapped]: item.free()


func _tab(id: int, keys: Array, shown := []) -> Dictionary:
	var children := []
	for key in keys:
		children.append({"pane": key, "shown": shown.is_empty() or key in shown})
	return {"id": id, "focused": keys[0], "tree": {"type": "windows", "windows": children}}


func _node(status: String, history: Array) -> Dictionary:
	var entries := []
	for entry in history:
		entries.append({"at": "2030-01-01T00:00:%s.000+00:00" % entry[0], "status": entry[1]})
	var attention: Variant = null
	if status in ["idle", "waiting"]:
		attention = {"event": status + str(history), "kind": "waiting" if status == "waiting" else "completed", "seen": false}
	return {"provider": "claude", "status": status, "status_history": entries, "attention": attention}


func _setup() -> Array:
	var app := Application.new()
	var host := Host.new()
	app.hosts.append(host)
	var attention := Attention.new()
	attention.application = app
	attention.in_view = func(h): return h.in_view
	return [attention, app, host]


func test_tabs_show_unseen_outcomes_and_clear_only_after_every_pane_is_seen() -> void:
	var parts := _setup()
	var attention: Node = parts[0]
	var app: Application = parts[1]
	var host: Host = parts[2]
	host.workspace_layout.tabs = [_tab(1, ["t1"]), _tab(2, ["t2", "t3", "t4"], ["t2", "t3"])]
	host.workspace_layout.active = 1
	var busy := _node("busy", [["01", "busy"]])
	app.agent_api.graph.nodes = {"t1": busy, "t2": busy, "t3": busy, "t4": busy}
	attention.refresh()
	expect(attention.marker(host, ["t2", "t3", "t4"]).state == "", "Running agents have no marker")
	var done := _node("idle", [["01", "busy"], ["02", "idle"]])
	var ask := _node("waiting", [["01", "busy"], ["02", "waiting"]])
	app.agent_api.graph.nodes = {"t1": done, "t2": done, "t3": done, "t4": ask}
	var emitted := [0]
	attention.changed.connect(func(): emitted[0] += 1)
	attention.refresh()
	expect(emitted[0] == 1, "A marker change emits once")
	expect(attention.marker(host, ["t1"]).state == "", "The visible active tab's completion is already seen")
	expect(attention.marker(host, ["t2", "t3", "t4"]) == {"state": "waiting", "count": 1}, "Waiting wins over completions")
	attention.refresh()
	expect(emitted[0] == 1, "Re-observing unchanged evidence changes nothing")
	host.workspace_layout.active = 2
	attention.refresh()
	expect(attention.marker(host, ["t2", "t3", "t4"]) == {"state": "waiting", "count": 1}, "A hidden pane in the active tab is not seen")
	host.workspace_layout.tabs[1] = _tab(2, ["t2", "t3", "t4"])
	attention.refresh()
	expect(attention.marker(host, ["t2", "t3", "t4"]).state == "", "Showing every pane clears the tab")
	host.free()
	attention.free()


func test_unfocused_window_does_not_count_as_seen_and_closed_panes_are_forgotten() -> void:
	var parts := _setup()
	var attention: Node = parts[0]
	var app: Application = parts[1]
	var host: Host = parts[2]
	host.workspace_layout.tabs = [_tab(1, ["t1"])]
	host.workspace_layout.active = 1
	host.in_view = false
	app.agent_api.graph.nodes = {"t1": _node("busy", [["01", "busy"]])}
	attention.refresh()
	app.agent_api.graph.nodes = {"t1": _node("idle", [["01", "busy"], ["02", "idle"]])}
	attention.refresh()
	expect(attention.marker(host, ["t1"]) == {"state": "completed", "count": 1}, "An unfocused window's active tab still marks")
	host.workspace_layout.tabs = []
	attention.refresh()
	expect(attention.marker(host, ["t1"]).state == "", "A closed pane leaves no marker")
	host.free()
	attention.free()


func test_tab_strip_draws_one_pointer_transparent_dot() -> void:
	var strip: ScrollContainer = TabStrip.new()
	Engine.get_main_loop().root.add_child(strip)
	strip.reconcile([{"id": 1, "title": "a", "attention": {"state": "completed", "count": 1}}], 1)
	var dot: Control = strip.buttons[1].get_node_or_null("Attention")
	expect(dot != null and dot.visible and dot.state == "completed", "Completed tab shows a green dot")
	expect(dot != null and dot.mouse_filter == Control.MOUSE_FILTER_IGNORE, "The dot never steals tab clicks")
	strip.reconcile([{"id": 1, "title": "a", "attention": {"state": "waiting", "count": 3}}], 1)
	expect(dot.state == "waiting" and dot.count == 3 and strip.buttons[1].get_children().filter(func(c): return c.name == "Attention").size() == 1, "State changes reuse one marker")
	strip.reconcile([{"id": 1, "title": "a"}], 1)
	expect(not dot.visible, "No attention hides the marker")
	strip.free()
