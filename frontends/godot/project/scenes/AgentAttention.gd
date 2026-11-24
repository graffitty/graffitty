extends Node
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
				if host.is_terminal_pane(key): visible.append(key)
	return {"live": live, "visible": visible}


func refresh() -> void:
	_queued = false
	if _core == null or application == null or application.agent_api == null: return
	var live := PackedStringArray()
	var visible := PackedStringArray()
	var nodes: Dictionary = application.agent_api.graph.nodes.duplicate()
	_receipt_owners = application.agent_api.graph.remote_owners.duplicate()
	for host in application.hosts:
		# unregister_host drops a closing window before it is freed.
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var found := panes(host)
		live.append_array(PackedStringArray(found.live))
		visible.append_array(PackedStringArray(found.visible))
	# A session switch removes panes from this window, not from the server.
	# Catalog evidence keeps their receipts retryable without reopening them.
	for group in preload("res://scenes/session/SessionsList.gd").collect(application.hosts, []):
		var peer: Node = group.get("peer")
		if not group.connected or not is_instance_valid(peer): continue
		for session in peer.available_sessions:
			for agent in session.get("agents", []):
				var pane := int(agent.get("pane", -1))
				if pane < 0: continue
				var key := "%%%d" % peer.local_id(pane)
				if not live.has(key): live.append(key)
				var owner: Node = _receipt_owners.get(key)
				var unavailable_owner: bool = is_instance_valid(owner) and not owner.connected and owner.url == peer.url and owner.epoch == peer.epoch and owner.wire_id(int(key.substr(1))) == pane
				if not nodes.has(key) or unavailable_owner:
					# Catalogs can deliver a pending read but cannot make a newer
					# result visible in a disconnected terminal's cached screen.
					if nodes.get(key, {}).get("attention") != agent.get("attention"):
						var index := visible.find(key)
						if index >= 0: visible.remove_at(index)
					nodes[key] = {"attention": agent.get("attention"), "status": agent.get("status", "")}
					_receipt_owners[key] = peer
	if _core.observe(nodes, visible, live):
		changed.emit()
	_send_receipts()
	if "agents" in application and is_instance_valid(application.agents):
		application.agents.refresh()


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
		_send_receipt(connection, int(str(receipt.key).substr(1)), event)


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
