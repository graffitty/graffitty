extends Node

const PaneAddress := preload("res://scenes/PaneAddress.gd")
## Presentation and sounds for the Herdr-derived Rust model. Read receipts come
## from the session server; one application instance owns all windows' alerts.
signal changed
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Paths := preload("res://graffitty/paths.gd")
var application: Node
var rows: Array = []
## Sub-rows per top row id: every pane connected to that agent in its tab (gft
## run children, chromiums, graph peers; excluding filetrees), as herdr lists
## sub-agents.
##
## Agents that appear under another agent leave the top level.
var trees: Dictionary = {}
var _core: RefCounted = ClassDB.instantiate("AgentsCore")
var _owners: Dictionary = {}
var _selected: Dictionary = {}

func selected_id(host: Node) -> String:
	return _selected.get(host.get_instance_id(), "") if is_instance_valid(host) else ""

## Rows from sessions no window shows: id → {host, peer, session, pane}.
var _away: Dictionary = {}
var _audio: RefCounted
var audio_state := {"active": 0, "completed": 0, "skipped": 0, "error": ""}
var _pcm: Dictionary = {}
var _sounds: Dictionary = {}
var _streams: Dictionary = {}
var _saved := ""
var _path := ""

func _ready() -> void:
	set_process(false)
	_path = Paths.stdpath("state").path_join("agents.json")
	if FileAccess.file_exists(_path):
		var error: String = _core.restore(FileAccess.get_file_as_string(_path))
		if not error.is_empty(): push_warning("Invalid agent list state: " + error)
	_saved = _core.save()
	_sounds = preload("res://config/UserConfig.gd").resolved(OS.get_cmdline_user_args()).settings.get("sounds", {})
	# AgentAttention refreshes receipts before forwarding each graph transition
	# here, so rows and sounds see the same event as the tab markers.

func refresh() -> void:
	var profiled_started := Time.get_ticks_usec()
	refresh_body()
	preload("res://graffitty/frame_profile.gd").add("Agents.refresh", Time.get_ticks_usec() - profiled_started)


func refresh_body() -> void:
	var input: Dictionary = {}
	var remotes: Dictionary = {}
	var sessions: Dictionary = {}
	_owners.clear()
	var host_trees: Array = []
	var catalog_views := {}
	var selected := {}
	var groups := preload("res://scenes/session/SessionsList.gd").collect(application.hosts, [])
	var membership := {}
	var connected_scopes := {}
	for group in groups:
		if not group.connected: continue
		var peer: Node = group.peer
		connected_scopes[[peer.url, peer.epoch]] = true
	# Sessions groups by URL. Two live windows may still present different epochs.
	for host in application.hosts:
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var backend: Variant = host.get("session_backend")
		if backend == null or not backend.is_remote or not is_instance_valid(backend.connection): continue
		var connection: Node = backend.connection
		for peer in connection.connections if "connections" in connection else [connection]:
			if not is_instance_valid(peer) or not peer.connected or connected_scopes.has([peer.url,peer.epoch]): continue
			var group_index := groups.find_custom(func(group): return group.id == peer.url)
			if group_index < 0: continue
			var group: Dictionary = groups[group_index].duplicate()
			group.merge({"peer":peer,"host":host,"connected":true},true)
			groups.append(group)
			connected_scopes[[peer.url,peer.epoch]] = true
	for host in application.hosts:
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var looking: bool = application.agent_attention.in_view.call(host)
		var visible_keys: Array = application.agent_attention.panes(host).visible
		var backend: Variant = host.get("session_backend")
		var transport: Node = backend.connection if backend != null and backend.is_remote else null
		var ids_by_key: Dictionary = {}
		var stale_keys := {}
		var selected_key: String = host.pane_focus
		var active_tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
		if not host.get("presentation_active") or selected_key not in Layout.keys(active_tab.get("tree", {}), true):
			selected_key = ""
		for tab in host.workspace_layout.tabs:
			for key in Layout.keys(tab.tree):
				if not host.is_terminal_pane(key): continue
				var node: Dictionary = application.agent_api.graph.nodes.get(key, {})
				var shown: bool = key in visible_keys
				var focused: bool = looking and key == host.pane_focus
				var connection: Node = application.agent_api.graph.remote_owners.get(key)
				var local_id := PaneAddress.id(key)
				var peer: Node = transport.owners.get(local_id) if is_instance_valid(transport) and "owners" in transport else transport
				if is_instance_valid(peer):
					var scope := [peer.url, peer.epoch]
					if not membership.has(scope): membership[scope] = application.agent_attention.catalog_snapshot(peer)
					var catalog: Dictionary = membership[scope]
					var pane: int = peer.wire_id(local_id)
					if connected_scopes.has(scope) and not peer.connected:
						stale_keys[key] = true
						continue
					# The graph cache is shared across windows. Resolve selection through
					# this layout's own transport and attachment.
					node = application.agent_attention.graph_node_for(peer, local_id, connection, node)
					connection = peer
					if application.agent_attention.outside_catalog(catalog, pane, peer.workspace, node):
						if catalog.destinations.has(pane): stale_keys[key] = true
						continue
					if peer.connected and catalog.destinations.has(pane) and not peer.session_view_ready(peer.workspace):
						stale_keys[key] = true
						continue

				if key == selected_key and tab.id == host.workspace_layout.active:
					var route: Node = peer if backend != null and backend.is_remote else connection
					if is_instance_valid(route) and route.connected and route.session_view_ready(route.workspace):
						selected[host.get_instance_id()] = JSON.stringify([route.url, route.epoch, route.wire_id(local_id)])
				if node.is_empty() or not is_instance_valid(connection):
					if not is_instance_valid(peer) or not peer.connected or not peer.session_view_ready(peer.workspace): continue
					var identity := [peer.url, peer.epoch, peer.workspace, peer.wire_id(local_id)]
					var prior: Dictionary = catalog_views.get(identity, {})
					if prior.get("focused", false) or (prior.get("looking", false) and not focused): continue
					catalog_views[identity] = {"key": key, "host": host, "peer": peer, "looking": shown, "focused": focused}
					continue
				node = application.agent_attention.activity_node(key, node, connection, connection.workspace)
				# Never persist client-local remapped IDs; scope pins to the server epoch.
				var id := JSON.stringify([connection.url, connection.epoch, connection.wire_id(PaneAddress.id(key))])
				# Two views of the same server terminal are still one agent. Prefer
				# its focused/visible owner for seen rules and subsequent selection.
				ids_by_key[key] = id
				if input.has(id) and (input[id].focused or (input[id].looking and not focused)): continue
				_owners[id] = host
				remotes[id] = preload("res://scenes/remote/ConnectionName.gd").display({
					"name": connection.display_name if "display_name" in connection else "",
					"hostname": connection.server_hostname if "server_hostname" in connection else "",
					"url": connection.url}) if connection.url != "shared://local" else ""
				sessions[id] = session_label(connection)
				input[id] = {"id": id, "key": key, "title": host.pane_title(key),
					"provider": node.get("provider", ""), "status": node.get("status", ""),
					"program": node.get("program_status"),
					"status_history": node.get("status_history", []),
					"attention": application.agent_attention.project_attention(node.get("attention"), connection),
					"looking": shown, "focused": focused}
		host_trees.append([host, ids_by_key, stale_keys])
	var topologies := _add_away(input, remotes, sessions, catalog_views, groups)
	var next_trees := _build_trees(host_trees, topologies, input)
	for id in next_trees:
		for sub in next_trees[id]:
			var child: String = sub.get("row_id", "")
			if input.has(child): input[child].group = id
	var result: Dictionary = _core.observe(input.values(), int(Time.get_unix_time_from_system()))
	var next: Array = result.get("rows", [])
	var by_id := {}
	for row in next:
		row.remote = remotes.get(row.id, "")
		row.session = sessions.get(row.id, "")
		by_id[row.id] = row
	var hidden := {}
	for id in next_trees.keys():
		if not by_id.has(id):
			next_trees.erase(id)
			continue
		for sub in next_trees[id]:
			var child: String = sub.get("row_id", "")
			if sub.kind == "agent" and by_id.has(child):
				sub.merge(by_id[child], true)
				hidden[child] = true
			elif sub.kind == "agent" and input.has(child):
				sub.focused = input[child].focused
				hidden[child] = true
	next = next.filter(func(row): return not hidden.has(row.id))
	for host_id in selected.keys():
		if not by_id.has(selected[host_id]) and not hidden.has(selected[host_id]): selected.erase(host_id)
	if next != rows or next_trees != trees or selected != _selected:
		_selected = selected
		rows = next
		trees = next_trees
		changed.emit()
	for sound in result.get("sounds", []): _play(sound)
	_save()

## Agents in every other session of every connected server, from the session
## descriptors' server-owned agent summaries. Shown views win: their rows carry
## live titles and looking/focused state.
func _add_away(input: Dictionary, remotes: Dictionary, sessions: Dictionary, catalog_views: Dictionary, groups: Array) -> Dictionary:
	var topologies := {}
	_away.clear()
	for group in groups:
		var peer: Node = group.get("peer")
		if not group.connected or not is_instance_valid(peer) or not is_instance_valid(group.get("host")): continue
		# The peer publishes other sessions' agents through its live catalog.
		for value in application.agent_attention.catalog_snapshot(peer).sessions:
			if not value is Dictionary: continue
			var label := preload("res://scenes/session/SessionLabel.gd").name_of(value)
			for agent in value.get("agents", []):
				if not agent is Dictionary: continue
				var pane := int(agent.get("pane", -1))
				var id := JSON.stringify([peer.url, peer.epoch, pane])
				if pane < 0 or input.has(id): continue
				var view: Dictionary = catalog_views.get([peer.url, peer.epoch, value.id, pane], {})
				_away[id] = {"host": view.get("host", group.host), "peer": view.get("peer", peer), "session": str(value.id), "pane": pane}
				remotes[id] = "" if group.local else str(group.name)
				sessions[id] = label if not label.is_empty() else str(value.id).trim_prefix("$")
				var program: Variant = agent.get("program")
				var title := str(agent.get("title", ""))
				if title.is_empty() and program is Dictionary: title = str(program.get("msg", ""))
				var activity: Dictionary = application.agent_attention.activity_node(
					PaneAddress.key(peer.local_id(pane)), agent, peer, str(value.id))
				input[id] = {"id": id, "key": view.get("key", PaneAddress.key(pane)), "title": title,
					"provider": str(activity.get("provider", "")), "status": str(activity.get("status", "")),
					"program": activity.get("program_status", activity.get("program")), "status_history": activity.get("status_history", []),
					"attention": application.agent_attention.project_attention(activity.get("attention"), peer),
					"looking": view.get("looking", false), "focused": view.get("focused", false)}

			var topology: Dictionary = value.get("agent_tree", {})
			if topology.is_empty(): continue
			# A closing root may already lack a catalog summary. Removing it
			# lets the tree builder choose a remaining agent for each branch.
			var nodes: Array = topology.get("nodes", []).filter(func(node):
				return node is Dictionary and (node.get("kind") != "agent" or
					input.has(JSON.stringify([peer.url, peer.epoch, PaneAddress.id(str(node.get("key", "")))]))))
			var scoped_nodes := {}
			for node in nodes: scoped_nodes[node.key] = node
			# The catalog lists agents even before their first graph wire exists.
			for agent in value.get("agents", []):
				var pane := int(agent.pane)
				var wire := PaneAddress.key(pane)
				var row: Dictionary = input.get(JSON.stringify([peer.url,peer.epoch,pane]), {})
				var entry: Dictionary = scoped_nodes.get(wire, {"key":wire,"title":row.get("title","")}).duplicate()
				if _classify_agent(entry,row): scoped_nodes[wire] = entry
			topologies[[peer.url, peer.epoch, value.id]] = {"nodes":scoped_nodes, "edges":topology.edges.duplicate(),
				"graph_revision":int(topology.graph_revision), "routes":{}, "host":group.host, "peer":peer, "session":str(value.id)}
	return topologies

## Server-owned session label (manual or automatic name), falling back to its ID.
static func session_label(connection: Object) -> String:
	var current := str(connection.get("workspace")) if connection.get("workspace") != null else ""
	var catalog: Variant = connection.get("available_sessions")
	if catalog is Array:
		for value in catalog:
			if value is Dictionary and str(value.get("id", "")) == current:
				var label := preload("res://scenes/session/SessionLabel.gd").name_of(value)
				return label if not label.is_empty() else current.trim_prefix("$")
	return current.trim_prefix("$")

## The peer snapshot contains local addresses. Compare only revisions from the
## same server, epoch and workspace, then translate its graph edges to wire IDs.
func _merge_graph_snapshot(topology: Dictionary, peer: Node) -> void:
	if not "topology" in peer or peer.topology.get("workspace") != topology.session: return
	var snapshot: Variant = peer.topology.get("graph")
	if not snapshot is Dictionary: return
	var revision := int(snapshot.get("revision", -1))
	if revision <= topology.graph_revision: return
	topology.graph_revision = revision
	topology.edges = topology.edges.filter(func(edge): return edge.get("kind") != "graph")
	for edge in snapshot.get("edges", []):
		var source := PaneAddress.id(str(edge.get("from", "")))
		var target := PaneAddress.id(str(edge.get("to", "")))
		if source < 0 or target < 0: continue
		var source_wire: int = peer.wire_id(source)
		var target_wire: int = peer.wire_id(target)
		if source_wire > 0 and target_wire > 0:
			topology.edges.append({"from":PaneAddress.key(source_wire),"to":PaneAddress.key(target_wire),"kind":"graph"})

func _classify_agent(entry: Dictionary, row: Dictionary) -> bool:
	var provider: String = row.get("provider", "")
	var status: String = row.get("status", "")
	var program: Variant = row.get("program")
	if provider not in ["pi", "claude", "codex", "opencode"]:
		if not program is Dictionary or program.get("app", "") not in ["pi", "claude", "codex", "opencode"]: return false
		provider = program.app
		status = {"working":"busy","blocked":"waiting","error":"waiting"}.get(program.get("state", ""), "idle")
	entry.kind = "agent"
	entry.provider = provider
	entry.status = {"busy":"working","waiting":"blocked","error":"blocked","offline":"offline"}.get(status, "idle")
	return true

## One graph per host: nodes for every pane in its tabs and the wires among
## them. The Rust model picks each group's leading agent and orders children.
func _build_trees(host_trees: Array, topologies: Dictionary, input: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for pair in host_trees:
		var host: Node = pair[0]
		var ids_by_key: Dictionary = pair[1]
		var graph = application.agent_api.graph
		var nodes: Array = []
		var edges: Array = []
		var keys: Dictionary = {}
		var wire_keys := {}
		var pane_peers := {}
		var backend: Variant = host.get("session_backend")
		var transport: Node = backend.connection if backend != null and backend.is_remote else null
		if is_instance_valid(transport):
			for peer in transport.connections if "connections" in transport else [transport]:
				if not is_instance_valid(peer) or not peer.connected: continue
				var scope := [peer.url,peer.epoch,peer.workspace]
				if topologies.has(scope): _merge_graph_snapshot(topologies[scope],peer)
		for tab in host.workspace_layout.tabs:
			for window in Layout.windows(tab.tree):
				var key: String = window.pane
				if pair[2].has(key): continue
				var rect: Rect2 = window.get("rect", Rect2())
				var entry := {"key": key, "kind": "terminal", "title": host.pane_title(key), "provider": "", "app": "", "status": "",
					"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]}
				var id := PaneAddress.id(key)
				var peer: Node = transport.owners.get(id) if is_instance_valid(transport) and "owners" in transport else transport
				var scope := []
				var wire := ""
				if is_instance_valid(peer) and peer.connected and peer.session_view_ready(peer.workspace):
					pane_peers[key] = peer
					scope = [peer.url,peer.epoch,peer.workspace]
					wire = PaneAddress.key(peer.wire_id(id))
					if topologies.has(scope):
						wire_keys[key] = [scope,wire]
						var routes: Dictionary = topologies[scope].routes
						var agent_id := JSON.stringify([peer.url,peer.epoch,peer.wire_id(id)])
						var preferred: Node = _owners.get(agent_id, _away.get(agent_id, {}).get("host"))
						if not routes.has(wire) or preferred == host:
							routes[wire] = {"host_id":host.get_instance_id(),"key":key}
				if host.is_chromium_pane(key):
					entry.kind = "chromium"
					var owner_id: int = host.chromiums[id].owner_id if host.chromiums.has(id) else id
					if owner_id != id: edges.append({"from": PaneAddress.key(owner_id), "to": key, "kind": "chromium"})
				elif host.is_terminal_pane(key) and host.sessions.has(id):
					var agent_id: String = ids_by_key.get(key, "")
					if wire_keys.has(key): agent_id = JSON.stringify([peer.url,peer.epoch,peer.wire_id(id)])
					var term: Node = host.sessions[id].term
					var filetree_owner: int = term.get_meta("filetree_owner", -1)
					var spawned_by: int = term.get_meta("spawned_by", -1)
					if filetree_owner >= 0:
						continue
					if not _classify_agent(entry, input.get(agent_id, {})):
						entry.app = str(host.sessions[id].model.foreground_app.get("id", ""))
					if spawned_by >= 0 and spawned_by != id: edges.append({"from": PaneAddress.key(spawned_by), "to": key, "kind": "spawned"})
				else: continue
				keys[key] = true
				if wire_keys.has(key):
					entry.key = wire
					var catalog_nodes: Dictionary = topologies[scope].nodes
					if entry.kind == "agent" or catalog_nodes.get(wire, {}).get("kind") != "agent":
						catalog_nodes[wire] = entry
				else: nodes.append(entry)
		for edge in graph.edges.values():
			if wire_keys.has(edge.from) or wire_keys.has(edge.to): continue
			if not keys.has(edge.from) or not keys.has(edge.to): continue
			var matches := true
			for key in [edge.from,edge.to]:
				if not pane_peers.has(key): continue
				var owner: Node = graph.remote_owners.get(key)
				if application.agent_attention.graph_node_for(pane_peers[key], PaneAddress.id(key), owner, graph.nodes.get(key, {})).is_empty():
					matches = false
			if matches: edges.append({"from":edge.from,"to":edge.to,"kind":"graph"})
		var local_edges := []
		for edge in edges:
			if not wire_keys.has(edge.from) and not wire_keys.has(edge.to):
				local_edges.append(edge)
			elif wire_keys.has(edge.from) and wire_keys.has(edge.to):
				var source: Array = wire_keys[edge.from]
				var target: Array = wire_keys[edge.to]
				if source[0] == target[0]:
					topologies[source[0]].edges.append({"from":source[1],"to":target[1],"kind":edge.kind})
		var computed: Variant = _core.tree({"nodes": nodes, "edges": local_edges})
		if not computed is Array: continue
		for tree in computed:
			var root_id = ids_by_key.get(str(tree.root))
			if root_id == null: continue
			var subs: Array = []
			for sub in tree.rows:
				var item: Dictionary = sub.duplicate()
				item["host_id"] = host.get_instance_id()
				if ids_by_key.has(item.key):
					item["row_id"] = ids_by_key[item.key]
				subs.append(item)
			result[root_id] = subs
	for topology in topologies.values():
		var peer: Node = topology.peer
		for tree in _core.tree({"nodes":topology.nodes.values(),"edges":topology.edges}):
			var root_id := JSON.stringify([peer.url,peer.epoch,PaneAddress.id(tree.root)])
			for sub in tree.rows:
				var pane := PaneAddress.id(sub.key)
				var id := JSON.stringify([peer.url,peer.epoch,pane])
				sub.parent = topology.routes.get(sub.parent, {}).get("key",sub.parent)
				if topology.routes.has(sub.key):
					sub.merge(topology.routes[sub.key],true)
				else:
					sub.away_id = id
					_away.get_or_add(id, {"host":topology.host,"peer":peer,"session":topology.session,"pane":pane})
				if sub.kind == "agent": sub.row_id = id
				if input.has(id):
					sub.title = input[id].title
					if input[id].status == "offline": sub.status = "offline"
			result[root_id] = tree.rows
	return result

func focus_key(host_id: int, key: String) -> void:
	var host: Object = instance_from_id(host_id)
	if not is_instance_valid(host): return
	var window: Window = host.get_window() if host.is_inside_tree() else null
	if window != null: window.grab_focus()
	_reveal(host, key)

func _save() -> void:
	var data: String = _core.save()
	if data == _saved or _path.is_empty(): return
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var file := FileAccess.open(_path + ".tmp", FileAccess.WRITE)
	if file == null: return
	file.store_string(data)
	file.close()
	if DirAccess.rename_absolute(_path + ".tmp", _path) == OK: _saved = data

func pin(id: String, pinned: bool) -> void:
	_core.pin(id, pinned)
	refresh()

## NextAgent and PreviousAgent: the focus moves one row along the list the
## Agents panel shows, wrapping at the ends.
##
## With no agent focused it starts at the first row, or the last when stepping
## back.
func step(direction: int) -> void:
	var order: Array = []
	for row in rows:
		order.append(row)
		for sub in trees.get(row.id, []):
			if sub.kind == "agent" and sub.has("row_id"): order.append(sub)
	if order.is_empty(): return
	var current := order.find_custom(func(row): return row.get("focused", false))
	var index := posmod(current + direction, order.size()) if current >= 0 else (0 if direction > 0 else order.size() - 1)
	var target: Dictionary = order[index]
	if target.has("host_id"): focus_key(target.host_id, target.key)
	else: focus(str(target.get("away_id", target.get("id", ""))))

func focus(id: String) -> void:
	if _away.has(id) and not _owners.has(id):
		_focus_away(_away[id])
		return
	var host: Node = _owners.get(id)
	if not is_instance_valid(host): return
	for row in rows:
		if row.id == id:
			focus_key(host.get_instance_id(), row.key)
			return

## The shared host of several servers decides whether this crosses to another
## server's session (a flight) or stays a tab switch.
func _reveal(host: Node, key: String) -> void:
	var client: Node = host.get_parent()
	if is_instance_valid(client) and client.get("federated") == true:
		client.get_parent().reveal_pane(key)
	else:
		host.reveal_pane(key)
	# Share prefix navigation's framing: return tiled panes to Main, or pan
	# clipped/offscreen panes into view without fitting one pane to the screen.
	if is_instance_valid(host.workspace_view):
		host.workspace_view.reveal_navigation_target(key)

## Switch the server's view to the agent's session, then focus its pane once
## the new topology presents it.
func _focus_away(target: Dictionary) -> void:
	var peer: Node = target.peer
	var host: Node = target.host
	if not is_instance_valid(peer) or not peer.connected or not is_instance_valid(host): return
	if peer.workspace != target.session:
		# Land the session's one flight on this agent, not on its last tab
		# followed by a second tab switch mid-transition.
		host.set_meta("session_switch_focus", target.pane)
		var result: Dictionary = await peer.request_action("session_switch", {"name": target.session})
		if result.get("type") == "error":
			if is_instance_valid(host): host.remove_meta("session_switch_focus")
			push_warning("Could not switch to session " + target.session)
			return
	var deadline := Time.get_ticks_msec() + 5000
	while is_instance_valid(host) and is_instance_valid(peer) and peer.connected and Time.get_ticks_msec() < deadline:
		var key := PaneAddress.key((peer.local_id(target.pane) if peer.has_method("local_id") else target.pane))
		if peer.session_view_ready(target.session) and host.workspace_layout.containing(key) >= 0:
			if host.is_inside_tree():
				host.get_window().show()
				host.get_window().grab_focus()
			host.reveal_pane(key)
			# The arrival normally lands framed on the pane already; pan if not.
			if is_instance_valid(host.workspace_view):
				host.workspace_view.reveal_navigation_target(key)
			return
		await get_tree().process_frame

func open(host: Node) -> void:
	refresh()
	preload("res://scenes/AgentsDialog.gd").open(host)

func sounds_enabled() -> bool:
	return bool(_sounds.get("enabled", true))

func toggle_sounds() -> void:
	# Session-only override; never write back to the user's configuration.
	_sounds["enabled"] = not sounds_enabled()

func test_sound() -> void:
	_play("blocked")

func _play(kind: String) -> void:
	if not sounds_enabled(): return
	if not _streams.has(kind):
		var path: String = _sounds.get(kind, "")
		var stream: AudioStream
		if not path.is_empty():
			if not path.is_absolute_path(): path = Paths.config_path().get_base_dir().path_join(path)
			if FileAccess.file_exists(path):
				match path.get_extension().to_lower():
					"ogg": stream = AudioStreamOggVorbis.load_from_file(path)
					"mp3": stream = AudioStreamMP3.load_from_file(path)
					"wav": stream = AudioStreamWAV.load_from_file(path)
			if stream == null: push_warning("Could not load custom agent sound; using bundled sound")
		if stream == null: stream = load("res://scenes/sounds/agent-attention.ogg")
		_streams[kind] = stream
	if not _pcm.has(kind):
		var stream: AudioStream = _streams[kind]
		var playback := stream.instantiate_playback()
		if playback == null:
			push_error("Could not decode attention sound")
			return
		playback.start()
		var frames := PackedVector2Array()
		var remaining := int(ceil(minf(stream.get_length(), 10.0) * AudioServer.get_mix_rate()))
		while remaining > 0:
			var count := mini(remaining, 2048)
			frames.append_array(playback.mix_audio(1.0, count))
			remaining -= count
		playback.stop()
		_pcm[kind] = frames
	if _audio == null: _audio = ClassDB.instantiate("AttentionAudio")
	_report_audio(_audio.play(_pcm[kind], int(AudioServer.get_mix_rate())))
	set_process(true)

func _process(_delta: float) -> void:
	if _audio == null: return
	audio_state = _audio.poll()
	if audio_state.skipped > 0: print_verbose("Attention sound skipped because audio output stopped responding")
	_report_audio(audio_state.error)
	if audio_state.active == 0: set_process(false)

## A machine without usable audio output (no device, no reachable sound
## server, an unsupported format) is not an error: the sound is just not heard.
func _report_audio(failure: String) -> void:
	if failure.is_empty(): return
	if failure.begins_with("No audio output device") or failure.begins_with("Unsupported audio output format: "):
		print_verbose("Attention sound: " + failure)
	else:
		push_error("Attention sound: " + failure)
