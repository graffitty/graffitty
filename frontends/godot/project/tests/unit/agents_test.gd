extends "res://tests/unit/test_case.gd"

const PaneAddress := preload("res://scenes/PaneAddress.gd")

class Connection extends Node:
	var connected := false
	var url := "test://server"
	var epoch := "test-epoch"
	var server_hostname := "fixture-server"
	var display_name := "Office fixture"
	var workspace := "$2"
	var catalog_revision := 1
	var available_sessions := [{"id": "$1", "name": "other"}, {"id": "$2", "automatic_name": "graffitty"}]
	func wire_id(_id: int) -> int: return 7

class Host extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var presentation_active := true
	var pane_focus := "t1"
	var sessions: Dictionary = {}
	var chromiums: Dictionary = {}
	func is_terminal_pane(key: String) -> bool: return PaneAddress.id(key) > 0
	func pane_is_presented(_key: String) -> bool: return true
	func is_chromium_pane(_key: String) -> bool: return false
	func pane_title(_key: String) -> String: return "Agent task"

class Graph extends RefCounted:
	var nodes := {}
	var remote_owners := {}
	var edges := {}

class API extends RefCounted:
	var graph: Object = Graph.new()

class Application extends Node:
	var agents: Node
	var hosts: Array = []
	var agent_api := API.new()
	var agent_attention := preload("res://scenes/AgentAttention.gd").new()
	func _init() -> void:
		agent_attention.application = self
		add_child(agent_attention)

func test_recorded_view_clears_tab_and_agent_completion_together() -> void:
	var app := Application.new()
	var host := Host.new()
	var connection := Connection.new()
	app.hosts = [host]
	host.workspace_layout.tabs = [
		{"id":1, "focused":"t1", "tree":{"type":"windows", "windows":[{"pane":"t1", "shown":true}]}},
		{"id":2, "focused":"t2", "tree":{"type":"windows", "windows":[{"pane":"t2", "shown":true}]}},
	]
	host.workspace_layout.active = 1
	app.agent_api.graph.nodes = {"t1": {"provider":"pi", "status":"busy"}}
	app.agent_api.graph.remote_owners = {"t1": connection}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	var refresh := func():
		app.agent_attention.refresh()
		controller.refresh()
	refresh.call()
	app.agent_api.graph.nodes["t1"].status = "idle"
	app.agent_api.graph.nodes["t1"].attention = {"event":"finish-1", "kind":"completed", "seen":false}
	refresh.call()
	expect(app.agent_attention.marker(["t1"]).state == "completed" and controller.rows[0].status == "done",
		"Without native focus, both surfaces mark the completion unseen")
	app.agent_attention.in_view = func(view): return view == host and view.presentation_active
	refresh.call()
	expect(app.agent_attention.marker(["t1"]).state == "" and controller.rows[0].status == "idle",
		"The recorded view clears both markers without native window focus")
	app.agent_api.graph.nodes["t1"].status = "busy"
	app.agent_api.graph.nodes["t1"].attention = null
	refresh.call()
	app.agent_api.graph.nodes["t1"].status = "idle"
	app.agent_api.graph.nodes["t1"].attention = {"event":"finish-2", "kind":"completed", "seen":false}
	refresh.call()
	expect(app.agent_attention.marker(["t1"]).state == "" and controller.rows[0].status == "idle",
		"A completion displayed in the recording never becomes unread")
	host.workspace_layout.active = 2
	app.agent_api.graph.nodes["t1"].status = "busy"
	app.agent_api.graph.nodes["t1"].attention = null
	refresh.call()
	app.agent_api.graph.nodes["t1"].status = "idle"
	app.agent_api.graph.nodes["t1"].attention = {"event":"finish-3", "kind":"completed", "seen":false}
	refresh.call()
	expect(app.agent_attention.marker(["t1"]).state == "completed" and controller.rows[0].status == "done",
		"A background tab still marks an unseen completion")
	host.workspace_layout.active = 1
	refresh.call()
	expect(app.agent_attention.marker(["t1"]).state == "" and controller.rows[0].status == "idle",
		"Returning to the recorded tab clears both surfaces")
	controller.free()
	connection.free()
	host.free()
	app.free()

func test_controller_keeps_pins_across_local_id_remapping() -> void:
	var app := Application.new()
	var host := Host.new()
	var connection := Connection.new()
	app.hosts = [host]
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	for key in ["t1", "t999"]:
		host.pane_focus = key
		host.workspace_layout.tabs = [{"id":1, "focused":key, "tree":{"type":"windows", "windows":[{"pane":key, "shown":true}]}}]
		app.agent_api.graph.nodes = {key: {"provider":"pi", "status":"busy"}}
		app.agent_api.graph.remote_owners = {key: connection}
		controller.refresh()
		expect(controller.rows.size() == 1 and controller.rows[0].key == key, "Current local pane is listed")
		expect(controller.rows[0].remote == "Office fixture", "Agent row carries its configured remote display name")
		expect(controller.rows[0].session == "graffitty", "Agent row carries its server-owned automatic session name")
		if key == "t1": controller.pin(controller.rows[0].id, true)
		else: expect(controller.rows[0].pinned, "Wire identity preserves pin after reconnect remapping")
	connection.url = "shared://local"
	controller.refresh()
	expect(controller.rows.size() == 1 and controller.rows[0].remote.is_empty(), "Local agents remain listed without a connection label")
	expect(controller.rows[0].session == "graffitty", "Local agents still show their session")
	connection.available_sessions[1].name = "manual"
	controller.refresh()
	expect(controller.rows[0].session == "manual", "A user-set session name wins over the automatic name")
	connection.available_sessions = []
	controller.refresh()
	expect(controller.rows[0].session == "2", "Unknown session metadata falls back to its ID")
	connection.url = "test://server"
	controller.refresh()
	expect(controller.rows[0].remote == "Office fixture", "Remote agents keep their connection label")
	connection.epoch = "new-epoch"
	controller.refresh()
	expect(not controller.rows[0].pinned, "A new server epoch cannot inherit another terminal's pin")
	controller.free()
	connection.free()
	host.free()
	app.free()

class Peer extends Node:
	signal sessions_changed
	func session_view_ready(id: String) -> bool: return workspace == id
	var url := "test://server"
	var epoch := "test-epoch"
	var display_name := "Office fixture"
	var server_hostname := "fixture-server"
	var connected := true
	var workspace := "$2"
	var catalog_revision := 1
	var available_sessions := [
		{"id": "$1", "name": "other", "agents": [
			{"pane": 3, "provider": "claude", "status": "waiting", "title": "", "program": null},
			{"pane": 4, "provider": "shell", "status": "unintegrated", "title": "", "program": {"state": "working", "app": "codex", "title": "", "msg": "Refactor"}}]},
		{"id": "$2", "automatic_name": "graffitty", "agents": [
			{"pane": 7, "provider": "pi", "status": "busy", "title": "", "program": null}]}]
	func wire_id(id: int) -> int: return 7 if id == 1 else id
	func local_id(id: int) -> int: return 1 if id == 7 else id

class Backend extends RefCounted:
	var is_remote := true
	var connection: Node

class SessionHost extends Host:
	var session_backend := Backend.new()
	var revealed := ""
	func reveal_pane(key: String) -> void: revealed = key

func test_catalog_only_agent_keeps_local_focus_and_traversal() -> void:
	var app := Application.new()
	var host := SessionHost.new()
	var peer := Peer.new()
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [{"id":1, "tree":{"windows":[{"pane":"t1","shown":true},{"pane":"t8","shown":true}]}}]
	host.workspace_layout.active = 1
	app.agent_attention.in_view = func(h): return h == host
	peer.available_sessions = [{"id":"$2","agents":[
		{"pane":7,"provider":"pi","status":"idle"}, {"pane":8,"provider":"claude","status":"idle"}]}]
	var panel := preload("res://scenes/Agents.gd").new()
	panel.application = app
	panel._sounds = {"enabled": false}
	panel.refresh()
	var focused := panel.rows.filter(func(row): return row.focused)
	expect(focused.size() == 1 and focused[0].key == "t1", "Wire t7 highlights the locally focused t1 before graph delivery")
	panel.step(1)
	expect(host.revealed == "t8", "Keyboard traversal advances from the catalog-only focused pane")
	panel.free()
	app.free()
	host.free()
	peer.free()


func test_catalog_completion_updates_panel_after_visible_receipt() -> void:
	var app := Application.new()
	app.agent_attention.free()
	app.agent_attention = preload("res://tests/unit/agent_attention_test.gd").CapturedAttention.new()
	app.agent_attention.application = app
	app.add_child(app.agent_attention)
	var host := SessionHost.new()
	var peer := Peer.new()
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [{"id":1, "tree":{"type":"windows", "windows":[{"pane":"t1","shown":true}]}}]
	host.workspace_layout.active = 1
	app.agent_api.graph.nodes = {"t1":{"provider":"pi","status":"busy","activity_revision":1}}
	app.agent_api.graph.remote_owners = {"t1":peer}
	app.agent_attention.in_view = func(h): return h == host
	var panel := preload("res://scenes/Agents.gd").new()
	panel.application = app
	panel._sounds = {"enabled":false}
	app.agents = panel
	app.agent_attention.refresh()
	var statuses := []
	panel.changed.connect(func():
		for row in panel.rows:
			if row.key == "t1": statuses.append(row.status))
	peer.available_sessions[1].agents[0].status = "idle"
	peer.available_sessions[1].agents[0].activity_revision = 2
	peer.available_sessions[1].agents[0].attention = {"event":"finished", "kind":"completed", "seen":false}
	peer.sessions_changed.emit()
	expect(app.agent_attention.calls.size() == 1, "The visible pane acknowledges the catalog before focus can move")
	expect(statuses == ["idle"], "The panel goes directly from working to idle on catalog delivery")
	expect(app.agent_attention.marker(["t1"]).count == 0, "The remapped visible pane keeps its tab clear")
	app.agent_attention.in_view = func(_h): return false
	app.agent_api.graph.nodes.t1 = peer.available_sessions[1].agents[0].duplicate()
	app.agent_attention.refresh()
	expect(panel.rows.filter(func(row): return row.key == "t1")[0].status == "idle", "Focus loss before graph delivery preserves the read")
	panel.free()
	app.free()
	host.free()
	peer.free()


func test_duplicate_catalogs_share_the_latest_background_activity() -> void:
	var app := Application.new()
	var first := SessionHost.new()
	var second := SessionHost.new()
	var fresh := Peer.new()
	var representative := Peer.new()
	first.session_backend.connection = fresh
	second.session_backend.connection = representative
	app.hosts = [first, second]
	var panel := preload("res://scenes/Agents.gd").new()
	panel.application = app
	panel._sounds = {"enabled":false}
	app.agents = panel
	var busy := {"pane":7,"provider":"pi","status":"busy","activity_revision":1}
	fresh.available_sessions = [{"id":"$1","agents":[busy.duplicate()]}]
	representative.available_sessions = [{"id":"$1","agents":[busy.merged({"title":"Background task"})]}]
	app.agent_attention.refresh()
	expect(panel.rows.size() == 1 and panel.rows[0].status == "working", "One background row represents both connections")
	var done := busy.duplicate()
	done.merge({"status":"idle","activity_revision":2,"attention":{"event":"finished","kind":"completed","seen":false}}, true)
	fresh.catalog_revision += 1
	done.title = "Updated title"
	fresh.available_sessions[0].agents = [done]
	fresh.sessions_changed.emit()
	expect(app.agent_attention.marker(["t1"]).count == 1 and panel.rows[0].status == "done",
		"The catalog completion updates both the remapped pane marker and the representative peer's row")
	expect(panel.rows[0].title == "Updated title" and panel._away[panel.rows[0].id].peer == representative,
		"The latest background descriptor supplies its title and the representative can navigate")
	representative.sessions_changed.emit()
	expect(panel.rows[0].status == "done", "Repeating the older catalog keeps the completion")
	var replacement := busy.merged({"provider":"claude","activity_revision":3}, true)
	representative.catalog_revision = fresh.catalog_revision + 1
	representative.available_sessions[0].agents = [replacement]
	representative.sessions_changed.emit()
	expect(app.agent_attention.marker(["t1"]).count == 0 and panel.rows[0].status == "working" and panel.rows[0].provider == "claude",
		"A replacement at the same pane address supersedes the former agent even when the removal was missed")
	expect(app.agent_attention.activity_node("t1", done, fresh, "$other") == done, "Another session cannot override this row")
	panel.free()
	app.free()
	first.free()
	second.free()
	fresh.free()
	representative.free()


func test_split_catalog_delivery_adds_moves_and_removes_background_agents() -> void:
	for reversed in [false, true]:
		var app := Application.new()
		var first := SessionHost.new()
		var second := SessionHost.new()
		var fresh := preload("res://scenes/remote/RemoteConnection.gd").new()
		var delayed := preload("res://scenes/remote/RemoteConnection.gd").new()
		for peer in [fresh, delayed]:
			peer.url = "test://split"
			peer.epoch = "test-epoch"
			peer.workspace = "$3"
			peer.connected = true
		first.session_backend.connection = fresh
		second.session_backend.connection = delayed
		app.hosts = [second, first] if reversed else [first, second]
		var panel := preload("res://scenes/Agents.gd").new()
		panel.application = app
		panel._sounds = {"enabled": false}
		app.agents = panel
		app.agent_attention.refresh()
		var deliver := func(peer, revision, sessions):
			peer._receive({"type":"session_list", "revision":revision, "sessions":sessions, "stops_when_empty":false})
		var busy := {"pane":7,"provider":"pi","status":"busy","activity_revision":4}
		var done := busy.merged({"status":"idle","activity_revision":6,"attention":{"event":"finished","kind":"completed","seen":false}}, true)
		var origin := [{"id":"$1","agents":[busy]}]
		var moved := [{"id":"$1","agents":[]},{"id":"$2","agents":[done]}]
		deliver.call(delayed, 1, [])
		deliver.call(fresh, 2, origin)
		expect(panel.rows.size() == 1 and panel.rows[0].status == "working", "First delivery adds a previously absent agent")
		deliver.call(fresh, 3, moved)
		deliver.call(delayed, 2, origin)
		expect(panel.rows.size() == 1 and panel.rows[0].status == "done" and panel._away[panel.rows[0].id].session == "$2",
			"A delayed pre-transfer catalog preserves the new destination and completion")
		expect(app.agent_attention.marker(["t7"]).count == 1, "The moved panel row agrees with the marker")
		deliver.call(fresh, 4, [])
		deliver.call(delayed, 3, moved)
		expect(panel.rows.is_empty() and app.agent_attention.marker(["t7"]).count == 0, "Late delivery cannot resurrect a removed pane")
		fresh.connected = false
		app.agent_attention.refresh()
		expect(panel.rows.is_empty(), "Losing the fresher socket cannot roll back the inventory")
		panel.free()
		app.free()
		first.free()
		second.free()
		fresh.free()
		delayed.free()


class SwitchPeer extends "res://scenes/remote/RemoteConnection.gd":
	var switch_to: Callable
	func request_action(kind: String, values: Dictionary = {}, _timeout_msec: int = 10000) -> Dictionary:
		switch_to.call(kind, values.name)
		return {"type":"ack"}


func test_transferred_agent_in_retained_layout_uses_connected_destination() -> void:
	for reversed in [false, true]:
		var app := Application.new()
		var graph := preload("res://scenes/AgentGraph.gd").new()
		app.agent_api.graph = graph
		var old_host := SessionHost.new()
		var live_host := SessionHost.new()
		var old := SwitchPeer.new()
		var live := SwitchPeer.new()
		old_host.session_backend.connection = old
		live_host.session_backend.connection = live
		var tab := {"id":1, "tree":{"windows":[{"pane":"t2", "shown":true}]}}
		old_host.workspace_layout.tabs = [tab]
		old_host.workspace_layout.active = 1
		old_host.pane_focus = "t2"
		app.hosts = [live_host, old_host] if reversed else [old_host, live_host]
		for peer in [old, live]:
			peer.url = "test://transfer"
			peer.epoch = "epoch"
			peer.connected = true
		old.workspace = "$1"
		live.workspace = "$3"
		var busy := {"node":"t2","pane":2,"provider":"pi","status":"busy","activity_revision":4}
		old.topology = {"workspace":"$1", "tabs":[], "panes":[], "graph":{"nodes":[busy]}}
		graph.import_remote(old, old.topology.graph)
		var panel := preload("res://scenes/Agents.gd").new()
		panel.application = app
		panel._sounds = {"enabled":false}
		app.agents = panel
		app.agent_attention.in_view = func(h): return h == old_host
		app.agent_attention.refresh()
		old._receive({"type":"session_list","revision":4,"sessions":[{"id":"$1","agents":[busy]}],"stops_when_empty":false})
		old.server_fonts.ready = true
		var former_id: String = panel.rows[0].id
		live._receive({"type":"session_list","revision":5,"sessions":[{"id":"$1","agents":[]}],"stops_when_empty":false})
		expect(panel.rows.is_empty() and not panel._owners.has(former_id), "A complete removal hides a still-connected window's cached row")
		panel.focus(former_id)
		panel.step(1)
		expect(old_host.revealed.is_empty(), "Neither the old row ID nor keyboard navigation selects the closed pane")
		old._network_failed("offline")
		live._network_failed("offline")
		app.agent_attention.refresh()
		expect(panel.rows.is_empty(), "Losing both transports preserves the confirmed closure")
		app.hosts = [old_host]
		app.agent_attention.refresh()
		panel.focus(former_id)
		panel.step(-1)
		expect(panel.rows.is_empty() and old_host.revealed.is_empty(), "Closing the newer window cannot resurrect its confirmed removal")
		app.hosts = [live_host, old_host] if reversed else [old_host, live_host]
		old.connected = true
		live.connected = true
		var replacement := busy.merged({"activity_revision":7, "provider":"claude"}, true)
		old.topology.graph.nodes = [replacement]
		graph.import_remote(old, old.topology.graph)
		app.agent_attention.refresh()
		expect(panel.rows.size() == 1 and panel.rows[0].provider == "claude", "A new graph-first agent can reuse the closed pane ID")
		var done := replacement.merged({"status":"idle","activity_revision":8,"attention":{"event":"cached","kind":"completed","seen":false}}, true)
		live._receive({"type":"session_list","revision":9,"sessions":[{"id":"$1","agents":[done]}],"stops_when_empty":false})
		old._network_failed("offline")
		live._network_failed("offline")
		app.agent_attention.refresh()
		app.hosts = [old_host]
		app.agent_attention.refresh()
		panel.focus(former_id)
		expect(panel.rows.size() == 1 and panel.rows[0].status == "done" and old_host.revealed == "t2", "A genuine cached replacement remains selectable offline")
		old_host.revealed = ""
		old.connected = true
		live.connected = true
		app.hosts = [live_host, old_host] if reversed else [old_host, live_host]
		done = done.merged({"activity_revision":10,"attention":{"event":"moved","kind":"completed","seen":false}}, true)
		live._receive({"type":"session_list","revision":11,"sessions":[{"id":"$1","agents":[]},{"id":"$2","agents":[done]}],"stops_when_empty":false})
		expect(panel.rows.size() == 1 and panel.rows[0].session == "2", "A still-connected stale layout yields to the transfer")
		old.connected = false
		app.agent_attention.refresh()
		expect(panel.rows.size() == 1 and panel.rows[0].status == "done" and not panel.rows[0].focused,
			"The cached former layout cannot own or focus the moved result")
		expect(app.agent_attention.marker(["t2"]).count == 1, "The moved completion stays unread")
		var switches := []
		live.switch_to = func(kind, session):
			switches.append([kind, session])
			live.workspace = session
			live.topology.workspace = session
			live.server_fonts.ready = true
			live_host.workspace_layout.tabs = [tab]
		for action in ["focus", "next", "previous"]:
			live.workspace = "$3"
			live_host.workspace_layout.tabs = []
			live_host.revealed = ""
			if action == "focus": panel.focus(panel.rows[0].id)
			else: panel.step(1 if action == "next" else -1)
			expect(live_host.revealed == "t2" and old_host.revealed.is_empty(), "Moved pane opens in the connected window: " + action)
		expect(switches == [["session_switch","$2"], ["session_switch","$2"], ["session_switch","$2"]], "All three actions switch to the latest catalog destination")
		old.topology.graph = {}
		graph.import_remote(old, {})
		live._receive({"type":"session_list","revision":12,"sessions":[{"id":"$2","agents":[]}],"stops_when_empty":false})
		expect(panel.rows.is_empty() and app.agent_attention.marker(["t2"]).count == 0, "Confirmed closure clears the previously unread completion")
		app.hosts = []
		app.agent_attention.refresh()
		expect(app.agent_attention._catalogs.is_empty(), "Releasing the final view releases the epoch inventory")
		panel.free()
		graph.free()
		app.free()
		old_host.free()
		live_host.free()
		old.free()
		live.free()


func test_agents_in_other_sessions_and_servers_are_listed() -> void:
	var app := Application.new()
	var host := SessionHost.new()
	var peer := Peer.new()
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [{"id":1, "focused":"t1", "tree":{"type":"windows", "windows":[{"pane":"t1", "shown":true}]}}]
	app.agent_api.graph.nodes = {"t1": {"provider":"pi", "status":"busy"}}
	app.agent_api.graph.remote_owners = {"t1": peer}
	app.agent_api.graph.nodes["t1"].status_history = [{"status":"busy", "at":"2027-01-15T08:00:00Z"}]
	peer.available_sessions[0].agents[0].status_history = [{"status":"waiting", "at":"2027-01-15T08:05:00Z"}]
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	controller.refresh()
	expect(controller.rows.size() == 3, "Shown agent plus both agents of the unshown session are listed")
	var by_key := {}
	for row in controller.rows: by_key[row.key] = row
	expect(by_key.has("t1") and not by_key.has("t7"), "The shown view of an agent wins over its session summary")
	expect(by_key.has("t3") and by_key["t3"].session == "other" and by_key["t3"].remote == "Office fixture", "Unshown agents carry server and session captions")
	expect(by_key["t3"].status == "blocked", "Summary status maps like a shown agent's")
	expect(by_key["t1"].at == 1800000000 and by_key["t3"].at == 1800000300, "Visible and unshown sessions both use the server's transition time")
	expect(by_key.has("t4") and by_key["t4"].provider == "codex" and by_key["t4"].title == "Refactor", "OSC-reported agents use their program app and message")
	peer.available_sessions[0].agent_tree = {
		"nodes": [{"key":"t3","kind":"agent","provider":"claude"}, {"key":"t4","kind":"agent","provider":"codex"}],
		"edges": [{"from":"t3","to":"t4"}]}
	controller.refresh()
	expect(controller.rows.size() == 2, "A linked background agent appears under its root")
	var child: Dictionary = controller.trees[by_key["t3"].id][0]
	expect(child.row_id == by_key["t4"].id and child.status == "working", "The background child retains identity and status")
	expect(controller._away[child.away_id].session == "$1", "Selecting the child targets its own session")
	peer.available_sessions[0].agents[0].status = "idle"
	controller.refresh()
	expect(controller.rows.any(func(row): return row.key == "t3" and row.status == "idle" and row.section == "Working"),
		"A background session catalog places an idle leader with a busy child in Working")
	peer.available_sessions[0].agents[0].status = "unknown"
	controller.refresh()
	expect(controller.rows.any(func(row): return row.key == "t3") and controller.trees[by_key["t3"].id][0].row_id == by_key["t4"].id, "A background leader with unknown status keeps its active child connected")
	var leader_summary: Dictionary = peer.available_sessions[0].agents.pop_front()
	controller.refresh()
	expect(controller.rows.any(func(row): return row.key == "t4"), "A missing background leader summary promotes its listed child")
	peer.available_sessions[0].agents.push_front(leader_summary)
	peer.available_sessions[0].agents[0].status = "waiting"
	peer.available_sessions[0].agents[1].provider = "codex"
	peer.available_sessions[0].agents[1].status = "offline"
	controller.refresh()
	expect(controller.trees[by_key["t3"].id][0].status == "offline", "An offline child retains its status in the background tree")
	peer.available_sessions[0].agents[1].status = "busy"
	peer.available_sessions[0].agent_tree.edges.clear()
	controller.refresh()
	expect(controller.rows.size() == 3, "Disconnecting the wire restores separate rows while away")
	peer.url = "shared://local"
	controller.refresh()
	var local_row: Dictionary = controller.rows.filter(func(row): return row.key == "t3")[0]
	expect(local_row.remote.is_empty() and local_row.session == "other", "Local unshown agents show only their session")
	peer.connected = false
	app.agent_api.graph.remote_owners = {}
	controller.refresh()
	expect(controller.rows.is_empty(), "A disconnected server lists no stale agents")
	controller.free()
	host.free()
	peer.free()
	app.free()

func test_agents_command_and_bridge_states() -> void:
	expect("Agents" in preload("res://scenes/HostActions.gd").names(), "Agents is a registered command")
	var core: RefCounted = ClassDB.instantiate("AgentsCore")
	var input := [{"id":"test/epoch/1", "key":"t1", "title":"Test agent", "provider":"pi", "status":"busy", "looking":false, "focused":false}]
	var first: Dictionary = core.observe(input, 100)
	expect(first.rows[0].section == "Working" and first.sounds.is_empty(), "Working begins silently")
	input[0].status = "waiting"
	input[0].attention = {"event":"wait-1", "kind":"waiting", "seen":false}
	var wait: Dictionary = core.observe(input, 110)
	expect(wait.rows[0].section == "Needs you" and wait.sounds == ["blocked"], "Awaiting input raises attention")
	expect(core.observe(input, 111).sounds.is_empty(), "Repeated snapshots do not play a sound")
	input[0].status = "idle"
	input[0].attention = {"event":"finish-1", "kind":"completed", "seen":false}
	var done: Dictionary = core.observe(input, 120)
	expect(done.rows[0].section == "Done" and done.sounds == ["done"], "An unseen completion is Done")
	input[0].looking = true
	input[0].focused = true
	input[0].attention.seen = true
	var seen: Dictionary = core.observe(input, 130)
	expect(seen.rows[0].section == "Done" and seen.rows[0].status == "idle" and seen.rows[0].at == 120, "Focused completed row holds its group and duration")
	core.pin("test/epoch/1", true)
	expect(core.observe(input, 140).rows[0].section == "Pinned", "Pinning takes precedence")
	var restored: RefCounted = ClassDB.instantiate("AgentsCore")
	expect(restored.restore(core.save()).is_empty(), "Current schema restores")
	expect(restored.observe(input, 150).rows[0].pinned, "Pins survive restart")

func test_native_attention_output_rejects_invalid_input_without_opening_device() -> void:
	var audio: RefCounted = ClassDB.instantiate("AttentionAudio")
	expect(not audio.play(PackedVector2Array(), 44100).is_empty(), "Empty audio is rejected")
	expect(not audio.play(PackedVector2Array([Vector2.ONE]), 0).is_empty(), "Invalid sample rate is rejected")
	expect(not audio.play(PackedVector2Array([Vector2(NAN, 0)]), 44100).is_empty(), "Non-finite audio is rejected")
	var state: Dictionary = audio.poll()
	expect(state.active == 0 and state.completed == 0, "Invalid input never opens a native output")

func test_session_sound_toggle() -> void:
	var client := preload("res://scenes/Agents.gd").new()
	client._sounds = {"enabled": true, "blocked": "custom.ogg"}
	expect(client.sounds_enabled(), "Sound starts enabled from client configuration")
	client.toggle_sounds()
	expect(not client.sounds_enabled(), "Unchecking disables client sounds")
	client._play("blocked")
	expect(client._audio == null and client._streams.is_empty(), "Disabled toggle prevents playback")
	client.toggle_sounds()
	expect(client.sounds_enabled() and client._sounds.blocked == "custom.ogg", "Checking enables sounds without changing custom clips")
	client._sounds = {"enabled": false}
	client.toggle_sounds()
	expect(client.sounds_enabled(), "Session toggle can override a disabled saved setting")
	client.free()

func test_compressed_sound_and_client_settings() -> void:
	var sound: AudioStream = load("res://scenes/sounds/agent-attention.ogg")
	expect(sound is AudioStreamOggVorbis and sound.get_length() > 1.0 and sound.get_length() < 2.0, "Only the compressed notification is needed at runtime")
	var client := preload("res://scenes/Agents.gd").new()
	client._sounds = {"enabled":false}
	client._play("blocked")
	expect(client._streams.is_empty() and client._audio == null, "Disabled client audio does not load or play sounds")
	client.free()


class TreeTerm extends Node:
	pass

class TreeSession extends RefCounted:
	var foreground_app: Dictionary = {}

class TreeHost extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var pane_focus := "t1"
	var sessions: Dictionary = {}
	var chromiums: Dictionary = {}
	var titles: Dictionary = {}
	var focused := ""
	func pane_is_presented(_key: String) -> bool: return true
	func is_terminal_pane(key: String) -> bool: return PaneAddress.id(key) > 0 and not chromiums.has(PaneAddress.id(key))
	func is_chromium_pane(key: String) -> bool: return chromiums.has(PaneAddress.id(key))
	func pane_title(key: String) -> String: return titles.get(key, key)
	var revealed := ""
	func focus_pane(key: String) -> void: focused = key
	# Hidden `gft pane run` children must be shown, as every other go-to-pane path does.
	func reveal_pane(key: String) -> void:
		revealed = key
		focus_pane(key)
	func terminal(id: int, spawned_by := -1, app := "") -> void:
		var term := TreeTerm.new()
		add_child(term)
		term.set_meta("spawned_by", spawned_by)
		var model := TreeSession.new()
		if not app.is_empty(): model.foreground_app = {"id": app}
		sessions[id] = {"term": term, "model": model}

class TreeChromium extends RefCounted:
	var owner_id := -1

class TreeConnection extends Connection:
	func wire_id(id: int) -> int: return id

func test_connected_panes_form_a_tree_under_the_first_agent() -> void:
	var app := Application.new()
	var host := TreeHost.new()
	var connection := TreeConnection.new()
	app.hosts = [host]
	host.terminal(1)
	host.terminal(2, 1, "python3")
	host.terminal(3, 2)
	host.terminal(4)
	host.terminal(6, 1)
	host.sessions[6].term.set_meta("filetree_owner", 1)
	var chromium := TreeChromium.new()
	chromium.owner_id = 1
	host.chromiums[5] = chromium
	host.titles = {"t1": "lead", "t2": "server", "t3": "logs", "t4": "helper", "t5": "docs"}
	var windows := []
	for item in [["t1", 0], ["t2", 300], ["t3", 300], ["t4", 900], ["t5", 600], ["t6", 1200]]:
		windows.append({"pane": item[0], "shown": true, "rect": Rect2(item[1], 0, 200, 100)})
	host.workspace_layout.tabs = [{"id": 1, "focused": "t1", "tree": {"type": "windows", "windows": windows}}]
	app.agent_api.graph.nodes = {"t1": {"provider": "pi", "status": "busy"}, "t4": {"provider": "claude", "status": "idle"}}
	app.agent_api.graph.remote_owners = {"t1": connection, "t4": connection}
	app.agent_api.graph.edges = {"t1/send>t4/in": {"from": "t1", "to": "t4", "send": true}}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	controller.refresh()
	expect(controller.rows.size() == 1 and controller.rows[0].key == "t1", "The agent another agent points at leaves the top level")
	var subs: Array = controller.trees.get(controller.rows[0].id, [])
	expect(subs.map(func(s): return s.key) == ["t2", "t3", "t5", "t4"], "Children follow spawn, chromium and graph wires in reading order: %s" % [subs.map(func(s): return s.key)])
	expect(subs.map(func(s): return s.icon) == ["python", "terminal", "chromium", "claude"], "Programs, chromiums and agents get their own glyphs: %s" % [subs.map(func(s): return s.icon)])
	expect(subs[1].lines == ["│", "└"] and subs[3].lines == ["└"], "Tree lines nest grandchildren")
	expect(subs[3].status == "idle" and subs[3].has("row_id"), "A sub-agent carries its list status and identity")
	app.agent_api.graph.nodes["t4"].status = "offline"
	controller.refresh()
	var offline_subs: Array = controller.trees.get(controller.rows[0].id, [])
	var offline: Dictionary = offline_subs.filter(func(s): return s.key == "t4")[0]
	expect(offline.status == "offline" and offline.icon == "claude", "A closed connected agent keeps its identity and offline status for grayscale artwork")
	expect(not subs.any(func(s): return s.key == "t6"), "Filetree connections are hidden even when spawned by an agent")
	controller.focus_key(subs[0].host_id, subs[0].key)
	expect(host.focused == "t2" and host.revealed == "t2", "Clicking a connected pane reveals and focuses it")
	controller.free()
	connection.free()
	host.free()
	app.free()

func test_panel_groups_busy_grandchild_without_changing_individual_status() -> void:
	var app := Application.new()
	var host := TreeHost.new()
	var peer := TreeConnection.new()
	app.hosts = [host]
	var windows := []
	for id in range(1, 7):
		var key := PaneAddress.key(id)
		host.terminal(id)
		windows.append({"pane":key, "shown":true, "rect":Rect2(id * 150, 0, 120, 90)})
		var node := {"provider":"claude", "status":"busy" if id == 3 else "idle"}
		if id in [4, 5, 6]: node.attention = {"event":"finished-" + key, "kind":"completed", "seen":false}
		app.agent_api.graph.nodes[key] = node
		app.agent_api.graph.remote_owners[key] = peer
	host.workspace_layout.tabs = [{"id":1, "tree":{"type":"windows", "windows":windows}}]
	host.workspace_layout.active = 1
	host.pane_focus = "t3"
	app.agent_api.graph.edges = {"a":{"from":"t1","to":"t2"}, "b":{"from":"t2","to":"t3"},
		"c":{"from":"t1","to":"t4"}, "d":{"from":"t1","to":"t5"}}
	var panel := preload("res://scenes/Agents.gd").new()
	app.agents = panel
	panel.application = app
	panel._sounds = {"enabled":false}
	app.agent_attention.in_view = func(_h): return true
	panel.refresh()
	var roots: Array = panel.rows.filter(func(row): return row.key == "t1")
	expect(roots.size() == 1 and panel.rows.size() == 2, "The nested tree and the standalone completion each contribute one root")
	if roots.size() == 1:
		var lead: Dictionary = roots[0]
		expect(lead.section == "Working" and lead.status == "idle", "The working grandchild moves its idle leader to Working while the leader keeps its idle ring")
		var subs: Array = panel.trees[lead.id]
		expect(subs.map(func(row): return row.key) == ["t2","t3","t4","t5"], "The panel keeps both branches and both completed siblings")
		expect(subs.map(func(row): return row.status) == ["idle","working","done","done"],
			"The intermediate ring, grandchild spinner and sibling completion dots keep their individual states")
		expect(subs[1].parent == "t2" and subs[1].focused, "The busy grandchild keeps its depth and focused row")
		var service := preload("res://scenes/mods/ModService.gd").new()
		service.application = app
		service.host = ClassDB.instantiate("ModHost")
		service.available = service.host.setup("").is_empty()
		service.host.set_theme(JSON.stringify(service.THEME))
		service._publish_agents()
		var view: Control = ClassDB.instantiate("ModView")
		view.size = Vector2(550,700)
		expect(service.load_into(view, "agents", {}).is_empty(), "The bundled Agents mod loads with the controller's tree")
		view.render_now()
		expect((tr("Working") + "  1") in view.texts() and (tr("Done") + "  1") in view.texts() and not view.hit_rect("sec-Idle").has_area(),
			"The rendered headings count each group once and reserve Done for the standalone result")
		var grandchild := "sub-" + str(lead.id) + "|t3"
		expect(view.hit_rect(grandchild).has_area(), "The focused grandchild has its own rendered row")
		expect(view.click("fold-" + str(lead.id)), "The group can be folded from its rendered control")
		view.render_now()
		expect(not view.hit_rect(grandchild).has_area() and "4" in view.texts() and (tr("Working") + "  1") in view.texts(),
			"Folding hides all four connected rows while the group remains in Working")
		app.agent_attention.in_view = func(_h): return false
		panel.refresh()
		expect(panel.rows.any(func(row): return row.key == "t1" and row.section == "Working") and not panel.trees[lead.id][1].focused,
			"The same work keeps its section after its window loses focus")
		app.agent_api.graph.nodes.t3.status = "idle"
		panel.refresh()
		service._publish_agents()
		view.render_now()
		expect((tr("Idle") + "  1") in view.texts() and (tr("Done") + "  1") in view.texts() and not view.hit_rect("sec-Working").has_area(),
			"A folded background group returns to Idle when its last worker finishes")
		view.click("fold-" + str(lead.id))
		view.render_now()
		expect(view.hit_rect(grandchild).has_area() and panel.trees[lead.id][2].status == "done",
			"Expanding restores the nested rows and the sibling's unread completion")
		view.set_props('{"compact":true}')
		view.render_now()
		expect(view.hit_rect("ag-sub-" + str(lead.id) + "|t3").has_area() and "6" in view.texts(),
			"The compact panel numbers the two leaders and all four connected agents")
		view.free()
		service.free()
	panel.free()
	peer.free()
	host.free()
	app.free()


func test_newer_blocked_child_orders_its_group_before_an_older_request() -> void:
	var app := Application.new()
	var host := TreeHost.new()
	var peer := TreeConnection.new()
	app.hosts = [host]
	app.agent_attention.in_view = func(h): return h == host
	var windows := []
	for id in [1, 2, 3]:
		var key := PaneAddress.key(id)
		var state: String = ["unknown", "busy", "waiting"][id - 1]
		host.terminal(id)
		windows.append({"pane":key, "shown":true, "rect":Rect2(150 * id, 0, 100, 90)})
		app.agent_api.graph.nodes[key] = {"provider":"claude", "status":state,
			"status_history":[{"status":state, "at":"2026-11-24T00:00:10Z"}]}
		app.agent_api.graph.remote_owners[key] = peer
	host.workspace_layout.tabs = [{"id":1, "tree":{"type":"windows","windows":windows}}]
	host.workspace_layout.active = 1
	host.pane_focus = ""
	app.agent_api.graph.edges = {"a":{"from":"t1","to":"t2"}}
	var panel := preload("res://scenes/Agents.gd").new()
	panel.application = app
	panel._sounds = {"enabled":false}
	panel.refresh()
	expect(panel.rows.map(func(row): return row.key) == ["t3","t1"], "The older standalone blocker precedes the still-working group")
	var leader: Dictionary = panel.rows.filter(func(row): return row.key == "t1")[0]
	app.agent_api.graph.nodes.t2.status = "waiting"
	app.agent_api.graph.nodes.t2.status_history = [{"status":"waiting", "at":"2026-11-24T00:00:50Z"}]
	panel.refresh()
	expect(panel.rows.map(func(row): return [row.key, row.section]) == [["t1","Needs you"],["t3","Needs you"]],
		"The newest blocked request moves its whole group to the first visible position")
	var current: Dictionary = panel.rows.filter(func(row): return row.key == "t1")[0]
	var child: Dictionary = panel.trees[current.id][0]
	expect(current.status == "unknown" and current.at == 0 and current.at == leader.at,
		"The unknown leader retains its own glyph and empty age after its child blocks")
	expect(child.status == "blocked" and child.icon == "claude" and child.at == int(Time.get_unix_time_from_datetime_string("2026-11-24T00:00:50")),
		"The child's blocked glyph and timestamp stay on its own row")
	for key in ["t1","t2","t3"]:
		panel.step(1)
		expect(host.revealed == key, "NextAgent follows the visible group, child and older request in order: " + key)
		host.pane_focus = host.revealed
		panel.refresh()
	panel.free()
	peer.free()
	host.free()
	app.free()


func test_unknown_leader_keeps_each_branch_and_keyboard_order() -> void:
	var app := Application.new()
	var host := TreeHost.new()
	var peer := TreeConnection.new()
	app.hosts = [host]
	app.agent_attention.in_view = func(view): return view == host
	var windows := []
	for id in [2, 17, 18, 22]:
		var key := PaneAddress.key(id)
		host.terminal(id)
		windows.append({"pane": key, "shown": true, "rect": Rect2(id, 0, 100, 100)})
		app.agent_api.graph.nodes[key] = {"provider": "claude", "status": "unknown" if id == 2 else "idle"}
		app.agent_api.graph.remote_owners[key] = peer
	host.workspace_layout.tabs = [{"id": 1, "tree": {"type": "windows", "windows": windows}}]
	host.workspace_layout.active = 1
	host.pane_focus = "t17"
	app.agent_api.graph.edges = {"a": {"from": "t2", "to": "t17"}, "b": {"from": "t17", "to": "t18"}, "c": {"from": "t2", "to": "t22"}}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	controller.refresh()
	var by_key := {}
	for row in controller.rows: by_key[row.key] = row
	expect(by_key.has("t2") and by_key.size() == 1, "The unknown leader remains the one visible group root")
	if by_key.has("t2"):
		var children: Array = controller.trees[by_key.t2.id]
		expect(children.map(func(child): return child.key) == ["t17", "t18", "t22"], "The leader retains both connected branches in graph order")
		expect(children[1].parent == "t17" and children[1].lines.size() == 2, "The grandchild retains its parent and depth")
		controller.refresh()
		expect(controller.trees[by_key.t2.id] == children, "Repeated refreshes preserve order and metadata")
		controller.step(1)
		expect(host.revealed == "t18", "NextAgent moves from the branch parent to its child")
		host.pane_focus = "t18"
		controller.refresh()
		controller.step(-1)
		expect(host.revealed == "t17", "PreviousAgent returns from the nested child to its parent")
		controller.step(1)
		expect(host.revealed == "t22", "NextAgent reaches the other branch from the nested child")
		app.agent_api.graph.nodes.t18.status = "offline"
		host.revealed = ""
		controller.refresh()
		controller.step(1)
		expect(host.revealed == "t22", "A focused offline child still advances to the next displayed agent")
		for key in app.agent_api.graph.nodes: app.agent_api.graph.nodes[key].status = "offline"
		controller.refresh()
		expect(controller.rows.is_empty() and controller.trees.is_empty(), "An entirely unavailable component leaves no empty group")
	controller.free()
	peer.free()
	host.free()
	app.free()

func test_malformed_provider_entry_leaves_peers_visible() -> void:
	var core: RefCounted = ClassDB.instantiate("AgentsCore")
	var working := {"id": "working", "key": "t17", "title": "Review", "provider": "codex",
		"status": "busy", "looking": false, "focused": false}
	var malformed := working.duplicate()
	malformed.id = "broken"
	malformed.program = {"state": []}
	var snapshot: Dictionary = core.observe([malformed, working], 1)
	expect(snapshot.rows.size() == 1 and snapshot.rows[0].id == "working", "A malformed provider report cannot suppress its healthy peer")
	var tree: Array = core.tree({
		"nodes": [{"key":"t17","kind":"agent","provider":"codex"}, {"key":"t18","kind":"agent","provider":"codex"}, {"key":"t2","rect":true}],
		"edges": [{"from":"t17","to":"t18"}, {"from":null}],
	})
	expect(tree.size() == 1 and tree[0].rows[0].key == "t18", "Valid tree nodes and wires survive a malformed neighbor")
