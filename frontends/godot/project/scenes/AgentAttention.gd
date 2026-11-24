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
var _remote_cores := {}
var _queued := false
var _acknowledging: Dictionary = {}
var _receipt_owners: Dictionary = {}
var _activity: Dictionary = {}
var _receipt_panes: Dictionary = {}
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


static func identity(peer: Node, session: String, wire: int) -> String:
	return JSON.stringify([peer.url, peer.epoch, session, wire])


static func _host_peer(host: Node, key: String) -> Node:
	var backend: Variant = host.get("session_backend")
	if backend == null or not backend.is_remote: return null
	var connection: Node = backend.connection
	if not is_instance_valid(connection): return null
	var pane := PaneAddress.id(key)
	return connection.owners.get(pane) if "owners" in connection else connection


static func _host_key(host: Node, key: String) -> String:
	var peer := _host_peer(host, key)
	if is_instance_valid(peer): return identity(peer, peer.workspace, peer.wire_id(PaneAddress.id(key)))
	var backend: Variant = host.get("session_backend")
	return "" if backend != null and backend.is_remote else key


func refresh() -> void:
	_queued = false
	if _core == null or application == null or application.agent_api == null: return
	var live := {}
	var visible := {}
	var graph: Object = application.agent_api.graph
	var nodes: Dictionary = {}
	for key in graph.nodes:
		if not graph.remote_owners.has(key): nodes[key] = graph.nodes[key]
	var previous_owners := _receipt_owners
	_receipt_owners = {}
	_receipt_panes = {}
	var visible_views := {}
	var peers := {}
	for host in application.hosts:
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var found := panes(host)
		var backend: Variant = host.get("session_backend")
		if backend == null or not backend.is_remote:
			for key in found.live: live[key] = []
			for key in found.visible: visible[key] = true
			continue
		var connection: Node = backend.connection
		if not is_instance_valid(connection): continue
		for peer in connection.connections if "connections" in connection else [connection]:
			peers[peer] = true
		for key in found.live:
			var owner: Node = connection.owners.get(PaneAddress.id(key)) if "owners" in connection else connection
			if is_instance_valid(owner):
				var scoped := identity(owner, owner.workspace, owner.wire_id(PaneAddress.id(key)))
				live[scoped] = _domain(owner)
				if key in found.visible: visible_views.get_or_add(owner, []).append(key)
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
			_merge_activity(peer, snapshot_session, peer.wire_id(PaneAddress.id(key)), view_nodes[key], nodes)
		if snapshot_session != peer.workspace: view_nodes.clear()
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
					var scoped := identity(peer, session.id, pane)
					live[scoped] = _domain(peer)
					var row: Dictionary = summary.duplicate()
					row.program_status = summary.get("program")
					_merge_activity(peer, session.id, pane, row, nodes)
		# Only this window's own graph or ready catalog describes what it showed.
		# A disconnected screen can authorize its cached UUID via another route.
		if peer.connected and not peer.session_view_ready(peer.workspace): continue
		for key in visible_views.get(peer, []):
			var row: Dictionary = view_nodes.get(key, {})
			var event: Variant = row.get("attention")
			if event is Dictionary:
				var scoped := identity(peer, peer.workspace, peer.wire_id(PaneAddress.id(key)))
				displayed_events[[scoped, event.event]] = [peer, PaneAddress.id(key)]
	# A retained layout can outlive the inventory entry for a closed or moved pane.
	for scoped in previous_owners:
		if nodes.has(scoped): continue
		var scope: Array = JSON.parse_string(scoped)
		var catalog: Dictionary = _catalogs.get(scope.slice(0, 2), {})
		if outside_catalog(catalog, scope[3], scope[2], _activity.get(scoped, {})): nodes[scoped] = {}
	for scoped in _receipt_owners:
		var prior: Dictionary = _activity.get(scoped, {})
		if _newer(prior, nodes[scoped]): nodes[scoped] = prior
		var event: Variant = nodes[scoped].get("attention")
		if event is Dictionary and displayed_events.has([scoped, event.event]):
			visible[scoped] = true
			var source: Array = displayed_events[[scoped, event.event]]
			var viewed: Node = source[0]
			if viewed.connected:
				_receipt_owners[scoped] = viewed
				_receipt_panes[scoped] = source[1]
	_activity = nodes
	# Server event UUIDs survive tab transfers; independent epochs own separate pending receipts.
	var observations := {}
	for key in live:
		var domain: Array = live[key]
		if not observations.has(domain): observations[domain] = {"nodes":{}, "visible":PackedStringArray(), "live":PackedStringArray()}
		var batch: Dictionary = observations[domain]
		batch.live.append(key)
		if visible.has(key): batch.visible.append(key)
		if nodes.has(key): batch.nodes[key] = nodes[key]
	var updated := false
	for domain in _remote_cores.keys():
		if not retained_scopes.has(domain):
			_remote_cores.erase(domain)
			updated = true
	for domain in retained_scopes:
		if not _remote_cores.has(domain): _remote_cores[domain] = ClassDB.instantiate("AgentAttentionCore")
	var domains: Array = _remote_cores.keys()
	domains.append([])
	for domain in domains:
		var core: RefCounted = _core if domain.is_empty() else _remote_cores[domain]
		var batch: Dictionary = observations.get(domain, {})
		if core.observe(batch.get("nodes", {}), batch.get("visible", PackedStringArray()), batch.get("live", PackedStringArray())): updated = true
		_send_receipts(core, domain)
	if updated: changed.emit()
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


## Shared graph keys are client-local. Only the same attachment's evidence
## can supersede its catalog, even when several windows reuse a local key.
static func graph_node_for(peer: Node, local_id: int, owner: Node, node: Dictionary) -> Dictionary:
	if node.is_empty() or not is_instance_valid(peer) or not is_instance_valid(owner): return {}
	if owner.url != peer.url or owner.epoch != peer.epoch or owner.workspace != peer.workspace: return {}
	if "topology" in owner and owner.topology.get("workspace", "") != peer.workspace: return {}
	var pane: int = peer.wire_id(local_id)
	if pane <= 0 or owner.wire_id(local_id) != pane: return {}
	return node


## A newer graph can report an agent before its catalog arrives. Otherwise the
## complete inventory decides whether the pane still belongs to this session.
static func outside_catalog(catalog: Dictionary, pane: int, session: String, node: Dictionary) -> bool:
	return not catalog.is_empty() and int(node.get("activity_revision", 0)) <= int(catalog.revision) \
		and catalog.destinations.get(pane, "") != session


static func _newer(candidate: Dictionary, current: Dictionary) -> bool:
	return current.is_empty() or int(candidate.get("activity_revision", 0)) > int(current.get("activity_revision", 0))


func _merge_activity(peer: Node, session: String, wire: int, row: Dictionary, nodes: Dictionary) -> void:
	var scoped := identity(peer, session, wire)
	var current: Dictionary = nodes.get(scoped, {})
	var route: Node = _receipt_owners.get(scoped)
	var now_connected: bool = peer.connected and is_instance_valid(route) and not route.connected
	var same_revision := int(row.get("activity_revision", 0)) == int(current.get("activity_revision", 0))
	if _newer(row, current) or (now_connected and same_revision): nodes[scoped] = row
	if not is_instance_valid(route) or (peer.connected and not route.connected):
		_receipt_owners[scoped] = peer
		_receipt_panes[scoped] = peer.local_id(wire)


func activity_node(key: String, node: Dictionary, peer: Node, session: String) -> Dictionary:
	var scoped := identity(peer, session, peer.wire_id(PaneAddress.id(key)))
	var current: Dictionary = _activity.get(scoped, {})
	return current if not current.is_empty() and _newer(current, node) else node


static func _domain(peer: Node) -> Array:
	return [peer.url, peer.epoch] if is_instance_valid(peer) else []


func _projection(peer: Node) -> RefCounted:
	return _remote_cores.get(_domain(peer)) if is_instance_valid(peer) else _core


func attention(host: Node, key: String) -> Variant:
	var core := _projection(_host_peer(host, key))
	return core.attention(_host_key(host, key)) if core != null else null


func project_attention(value: Variant, peer: Node = null) -> Variant:
	var core := _projection(peer)
	return core.project_attention(value) if core != null else value


func _send_receipts(core: RefCounted, domain: Array) -> void:
	for receipt in core.acknowledgements():
		var event: String = receipt.event
		if _acknowledging.has([domain, event]): continue
		# Leave capacity for terminal actions on the same connection.
		if _acknowledging.size() >= 8: break
		var connection: Node = _receipt_owners.get(receipt.key)
		if not is_instance_valid(connection) or not connection.connected: continue
		_acknowledging[[domain, event]] = true
		_send_receipt(connection, int(_receipt_panes[receipt.key]), event)


func _send_receipt(connection: Node, pane: int, event: String) -> void:
	var token := [_domain(connection), event]
	await connection.acknowledge_agent(pane, event)
	# Only a server snapshot clears the Rust pending receipt. Retry after errors
	# or reconnects, including when the user has already looked away.
	await get_tree().create_timer(REPAIR_INTERVAL).timeout
	_acknowledging.erase(token)


## `{state: "waiting" | "completed" | "", count}`; waiting wins.
func marker(host: Node, keys: Array) -> Dictionary:
	var groups := {}
	for key in keys:
		var core := _projection(_host_peer(host, key))
		if core != null: groups.get_or_add(core, []).append(_host_key(host, key))
	var waiting := 0
	var completed := 0
	for core in groups:
		var result: Dictionary = core.marker(PackedStringArray(groups[core]))
		if result.state == "waiting": waiting += int(result.count)
		if result.state == "completed": completed += int(result.count)
	if waiting > 0: return {"state":"waiting", "count":waiting}
	return {"state":"completed" if completed > 0 else "", "count":completed}


func marker_for(peer: Node, session: String, wire: int) -> Dictionary:
	var core := _projection(peer)
	return core.marker(PackedStringArray([identity(peer, session, wire)])) if core != null else {"state":"", "count":0}


static func describe(attention: Dictionary) -> String:
	var count := int(attention.get("count", 0))
	match str(attention.get("state", "")):
		"waiting":
			return "%d agent%s awaiting input" % [count, "" if count == 1 else "s"]
		"completed":
			return "%d unseen agent completion%s" % [count, "" if count == 1 else "s"]
	return ""
