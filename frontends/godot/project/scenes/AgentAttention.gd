extends Node

const PaneAddress := preload("res://scenes/PaneAddress.gd")
## Tab markers for unseen agent outcomes. Evidence and counting live in Rust
## (AgentAttentionCore); this node only gathers what is on screen.
##
## Signals drive normal updates. A slow repair tick re-reads the same graph
## and layout, so a missed signal (focus, minimize, reconnect) cannot leave a
## marker stale.
##
## The server owns each attention event and its read receipt. Rust projects
## those receipts and keeps acknowledgements pending until the server confirms.
signal changed
const WorkspaceLayout := preload("res://scenes/WorkspaceLayout.gd")
const REPAIR_INTERVAL := 1.0
var application  # TerminalApplication: hosts and agent_api
var _core: RefCounted = ClassDB.instantiate("AgentAttentionCore") if ClassDB.class_exists("AgentAttentionCore") else null
var _queued := false
var _acknowledging: Dictionary = {}
var _receipt_owners: Dictionary = {}
var _activity: Dictionary = {}
var _activity_scopes: Dictionary = {}
var _catalogs := {}
## Shared by tab markers and the agent list. Recordings and headless fixtures
## can supply their viewed host without taking native window focus.
var in_view: Callable = host_in_view


func _ready() -> void:
	if _core == null:
		push_error("AgentAttentionCore is unavailable; tab agent markers are disabled")
		return
	var timer := Timer.new()
	timer.wait_time = REPAIR_INTERVAL
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start()


func watch_host(host: Node) -> void:
	host.ui_changed.connect(queue_refresh)
	var window := host.get_window()
	for event in [window.focus_entered, window.focus_exited, window.visibility_changed]:
		if not event.is_connected(queue_refresh): event.connect(queue_refresh)


func watch_graph(graph: Object) -> void:
	if not graph.changed.is_connected(refresh): graph.changed.connect(refresh)


func queue_refresh() -> void:
	if _queued: return
	_queued = true
	refresh.call_deferred()


## True only while the user can actually see the host's active tab.
static func host_in_view(host: Node) -> bool:
	if not host.is_inside_tree(): return false
	var window: Window = host.get_window()
	return bool(host.get("presentation_active")) and window.visible and window.has_focus()


func panes(host: Node) -> Dictionary:
	var live: Array[String] = []
	var visible: Array[String] = []
	var shown: bool = in_view.call(host)
	for group in host.workspace_layout.tabs:
		for key in WorkspaceLayout.keys(group.tree):
			if host.is_terminal_pane(key): live.append(key)
		if shown and group.id == host.workspace_layout.active:
			for key in WorkspaceLayout.keys(group.tree, true):
				if host.is_terminal_pane(key) and host.pane_is_presented(key): visible.append(key)
	return {"live": live, "visible": visible}


func refresh() -> void:
	_queued = false
	if _core == null or application == null or application.agent_api == null: return
	var live := PackedStringArray()
	var visible := PackedStringArray()
	var graph: Object = application.agent_api.graph
	var nodes: Dictionary = graph.nodes.duplicate()
	var previous_owners := _receipt_owners
	_receipt_owners = graph.remote_owners.duplicate()
	# A shared graph row can still belong to the previous attachment. Remote
	# snapshots below carry the peer and epoch that actually supplied the row.
	for key in graph.remote_owners:
		var owner: Node = graph.remote_owners[key]
		if is_instance_valid(owner) and "topology" in owner:
			nodes.erase(key)
			_receipt_owners.erase(key)
	var visible_views := {}
	var peers := {}
	var scopes := {}
	for host in application.hosts:
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var found := panes(host)
		live.append_array(PackedStringArray(found.live))
		var backend: Variant = host.get("session_backend")
		if backend == null or not backend.is_remote:
			visible.append_array(PackedStringArray(found.visible))
			continue
		var connection: Node = backend.connection
		if not is_instance_valid(connection): continue
		for peer in connection.connections if "connections" in connection else [connection]:
			peers[peer] = true
		for key in found.visible:
			var owner: Node = connection.owners.get(PaneAddress.id(key)) if "owners" in connection else connection
			if is_instance_valid(owner):
				visible_views.get_or_add(owner, []).append(key)
	# Parked connections can still confirm or retry a receipt after a session switch.
	for group in preload("res://scenes/session/SessionsList.gd").collect(application.hosts, []):
		if is_instance_valid(group.get("peer")): peers[group.peer] = true
	# A delayed socket can deliver an old full inventory after another socket
	# has already reported a removal or transfer in the same server epoch.
	var retained_scopes := {}
	for peer in peers:
		if not is_instance_valid(peer): continue
		var scope := [peer.url, peer.epoch]
		retained_scopes[scope] = true
		if int(peer.catalog_revision) >= int(_catalogs.get(scope, {}).get("revision", -1)):
			_catalogs[scope] = _catalog_snapshot(peer)
	for scope in _catalogs.keys():
		if not retained_scopes.has(scope): _catalogs.erase(scope)
	var displayed_events := {}
	for peer in peers:
		if not is_instance_valid(peer): continue
		if peer.has_signal("sessions_changed") and not peer.sessions_changed.is_connected(refresh):
			peer.sessions_changed.connect(refresh)
		var view_nodes := {}
		var snapshot_session: String = peer.workspace
		if "topology" in peer:
			snapshot_session = str(peer.topology.get("workspace", ""))
			var snapshot: Variant = peer.topology.get("graph")
			for row in snapshot.get("nodes", []) if snapshot is Dictionary else []:
				view_nodes[row.node] = row
		else:
			for key in graph.nodes:
				if graph.remote_owners.get(key) == peer: view_nodes[key] = graph.nodes[key]
		var catalog: Dictionary = _catalogs.get([peer.url, peer.epoch], {})
		for key in view_nodes:
			if outside_catalog(catalog, peer.wire_id(PaneAddress.id(key)), snapshot_session, view_nodes[key]): continue
			_merge_activity(key, view_nodes[key], peer, snapshot_session, nodes, scopes, visible_views)
		if peer.connected:
			if peer.session_view_ready(peer.workspace):
				for session in peer.available_sessions:
					if session.id != peer.workspace: continue
					for row in session.get("agents", []):
						var key := PaneAddress.key(peer.local_id(int(row.pane)))
						if _newer(row, view_nodes.get(key, {})): view_nodes[key] = row
			for session in catalog.sessions:
				for summary in session.get("agents", []):
					var pane := int(summary.get("pane", -1))
					if pane < 0: continue
					var key := PaneAddress.key(peer.local_id(pane))
					if not live.has(key): live.append(key)
					var row: Dictionary = summary.duplicate()
					row.program_status = summary.get("program")
					_merge_activity(key, row, peer, session.id, nodes, scopes, visible_views)
		# Only this window's own graph or ready catalog describes what it showed.
		# A disconnected screen can authorize its cached UUID via another route.
		if peer.connected and not peer.session_view_ready(peer.workspace): continue
		for key in visible_views.get(peer, []):
			var row: Dictionary = view_nodes.get(key, {})
			var event: Variant = row.get("attention")
			if event is Dictionary and (snapshot_session == peer.workspace or peer.connected):
				displayed_events[[key, peer.url, peer.epoch, peer.workspace, event.event]] = true
	# A retained layout can outlive both the closed pane and its graph row.
	# Explicitly retire its previous event when the complete inventory omits it.
	for key in _activity_scopes:
		if nodes.has(key): continue
		var scope: Array = _activity_scopes[key]
		var peer: Node = previous_owners.get(key)
		if not is_instance_valid(peer) or [peer.url, peer.epoch] != scope.slice(0, 2): continue
		var catalog: Dictionary = _catalogs.get([peer.url, peer.epoch], {})
		if outside_catalog(catalog, peer.wire_id(PaneAddress.id(key)), scope[2], _activity[key]): nodes[key] = {}
	for key in scopes:
		if scopes[key] == _activity_scopes.get(key) and _newer(_activity[key], nodes[key]):
			nodes[key] = _activity[key]
		var event: Variant = nodes[key].get("attention")
		if event is Dictionary and displayed_events.has([key] + scopes[key] + [event.event]):
			visible.append(key)
	_activity = nodes
	_activity_scopes = scopes
	if _core.observe(nodes, visible, live):
		changed.emit()
	_send_receipts()
	if "agents" in application and is_instance_valid(application.agents):
		application.agents.refresh()


static func _catalog_snapshot(peer: Node) -> Dictionary:
	var destinations := {}
	for session in peer.available_sessions:
		for agent in session.get("agents", []):
			if agent is Dictionary: destinations[int(agent.get("pane", -1))] = session.id
	return {"revision": peer.catalog_revision, "sessions": peer.available_sessions, "destinations": destinations}


func catalog_snapshot(peer: Node) -> Dictionary:
	var known: Dictionary = _catalogs.get([peer.url, peer.epoch], {})
	return known if not known.is_empty() else _catalog_snapshot(peer)


## A newer graph can report an agent before its catalog arrives. Otherwise the
## complete inventory decides whether the pane still belongs to this session.
static func outside_catalog(catalog: Dictionary, pane: int, session: String, node: Dictionary) -> bool:
	return not catalog.is_empty() and int(node.get("activity_revision", 0)) <= int(catalog.revision) \
		and catalog.destinations.get(pane, "") != session


static func _newer(candidate: Dictionary, current: Dictionary) -> bool:
	return current.is_empty() or int(candidate.get("activity_revision", 0)) > int(current.get("activity_revision", 0))


func _merge_activity(key: String, row: Dictionary, peer: Node, session: String, nodes: Dictionary, scopes: Dictionary, visible_views: Dictionary) -> void:
	var current: Dictionary = nodes.get(key, {})
	var route: Node = _receipt_owners.get(key)
	var live_route: bool = peer.connected and (not is_instance_valid(route) or not route.connected)
	# Raw (non-namespaced) views can reuse a key on a replacement server.
	# Revisions are comparable only within one server epoch.
	if is_instance_valid(route) and (route.url != peer.url or route.epoch != peer.epoch):
		if peer.connected != route.connected:
			if not peer.connected: return
		elif key not in visible_views.get(peer, []) or key in visible_views.get(route, []):
			return
		current = {}
	if _newer(row, current) or (int(row.get("activity_revision", 0)) == int(current.get("activity_revision", 0)) and live_route):
		nodes[key] = row
		_receipt_owners[key] = peer
		scopes[key] = [peer.url, peer.epoch, session]
	elif peer == route and not scopes.has(key) and int(row.get("activity_revision", 0)) == int(current.get("activity_revision", 0)):
		scopes[key] = [peer.url, peer.epoch, session]


func activity_node(key: String, node: Dictionary, peer: Node, session: String) -> Dictionary:
	if _activity_scopes.get(key) != [peer.url, peer.epoch, session]: return node
	var current: Dictionary = _activity.get(key, {})
	return current if not current.is_empty() and _newer(current, node) else node


## Both the agent panel and tab markers use the same optimistic read receipt.
func attention(key: String) -> Variant:
	return _core.attention(key) if _core != null else null


func project_attention(value: Variant) -> Variant:
	return _core.project_attention(value) if _core != null else value


func _send_receipts() -> void:
	for receipt in _core.acknowledgements():
		var event: String = receipt.event
		if _acknowledging.has(event): continue
		# Leave capacity for terminal actions on the same connection.
		if _acknowledging.size() >= 8: break
		var connection: Node = _receipt_owners.get(receipt.key)
		if not is_instance_valid(connection) or not connection.connected: continue
		_acknowledging[event] = true
		_send_receipt(connection, PaneAddress.id(str(receipt.key)), event)


func _send_receipt(connection: Node, pane: int, event: String) -> void:
	await connection.acknowledge_agent(pane, event)
	# Only a server snapshot clears the Rust pending receipt. Retry after errors
	# or reconnects, including when the user has already looked away.
	await get_tree().create_timer(REPAIR_INTERVAL).timeout
	_acknowledging.erase(event)


## `{state: "waiting" | "completed" | "", count}`; waiting wins.
func marker(keys: Array) -> Dictionary:
	if _core == null: return {"state": "", "count": 0}
	return _core.marker(PackedStringArray(keys))


static func describe(attention: Dictionary) -> String:
	var count := int(attention.get("count", 0))
	match str(attention.get("state", "")):
		"waiting":
			return "%d agent%s awaiting input" % [count, "" if count == 1 else "s"]
		"completed":
			return "%d unseen agent completion%s" % [count, "" if count == 1 else "s"]
	return ""
