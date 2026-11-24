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


class Peer extends Node:
	var url := "test://receipts"
	var epoch := "same-server"
	var connected := false
	var workspace := "$1"
	var available_sessions: Array = []
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
		_acknowledging.erase(event)


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
			expect(attention.marker(["t1"]).state == "", "Reading the cached event clears its local marker")
		else:
			expect(attention.calls.is_empty(), "Catalog-only evidence cannot acknowledge an unshown result: " + scenario)
			expect(attention.marker(["t1"]).state == "completed", "The unseen catalog event stays unread: " + scenario)
		attention.free()
		cached.free()
		other.free()
		disconnected.free()
		connected.free()


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
	expect(attention.marker(["t2", "t3", "t4"]).state == "", "Running agents have no marker")
	var done := _node("idle", [["01", "busy"], ["02", "idle"]])
	var ask := _node("waiting", [["01", "busy"], ["02", "waiting"]])
	app.agent_api.graph.nodes = {"t1": done, "t2": done, "t3": done, "t4": ask}
	var emitted := [0]
	attention.changed.connect(func(): emitted[0] += 1)
	attention.refresh()
	expect(emitted[0] == 1, "A marker change emits once")
	expect(attention.marker(["t1"]).state == "", "The visible active tab's completion is already seen")
	expect(attention.marker(["t2", "t3", "t4"]) == {"state": "waiting", "count": 1}, "Waiting wins over completions")
	attention.refresh()
	expect(emitted[0] == 1, "Re-observing unchanged evidence changes nothing")
	host.workspace_layout.active = 2
	attention.refresh()
	expect(attention.marker(["t2", "t3", "t4"]) == {"state": "waiting", "count": 1}, "A hidden pane in the active tab is not seen")
	host.workspace_layout.tabs[1] = _tab(2, ["t2", "t3", "t4"])
	attention.refresh()
	expect(attention.marker(["t2", "t3", "t4"]).state == "", "Showing every pane clears the tab")
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
	expect(attention.marker(["t1"]) == {"state": "completed", "count": 1}, "An unfocused window's active tab still marks")
	host.workspace_layout.tabs = []
	attention.refresh()
	expect(attention.marker(["t1"]).state == "", "A closed pane leaves no marker")
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
