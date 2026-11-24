extends SceneTree

const PaneAddress := preload("res://scenes/PaneAddress.gd")
## One real client per process, driven by test_agent_receipts.py. The only
## injected behavior delays an outgoing receipt to exercise an old mobile read.
var client: Node
var directory := ""
var control := {}
var viewed := false
var published := ""
var created_session := false
var panned_away := false

class Connection extends "res://scenes/remote/RemoteConnection.gd":
	var hold_receipts := false
	var held: Array[String] = []
	var sent: Array[String] = []
	var rejected: Array[String] = []
	var reject_held := false
	var released := false
	func acknowledge_agent(id: int, event: String) -> Dictionary:
		if hold_receipts:
			held.append(event)
			while not released: await get_tree().process_frame
			if reject_held:
				rejected.append(event)
				return {"type": "error", "message": "Injected transport failure before sending receipt"}
		var response: Dictionary = await super.acknowledge_agent(id, event)
		if response.get("type") != "error": sent.append(event)
		return response

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	# Headless startup otherwise supplies a 64-pixel window, too short to present the workspace.
	root.size = Vector2i(1280, 720)
	directory = OS.get_environment("GRAFFITTY_TEST_PEER_DIRECTORY")
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_TEST_REMOTE_DESCRIPTOR")))
	client = preload("res://scenes/remote/RemoteClient.gd").new()
	client.connection.free()
	client.connection = Connection.new()
	client.managed = true
	client.settings = {"url": descriptor.url, "token": descriptor.token, "transient": true, "initial_session": "main"}
	root.add_child(client)
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		var path := directory.path_join("control.json")
		if FileAccess.file_exists(path):
			var next: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if next is Dictionary: control = next
		if control.get("stop", false):
			client.connection.disconnect_remote()
			client.queue_free()
			await process_frame
			quit(0)
			return
		viewed = bool(control.get("viewed", false))
		client.connection.hold_receipts = bool(control.get("hold", false))
		client.connection.released = bool(control.get("release", false))
		client.connection.reject_held = bool(control.get("reject_held", false))
		if control.get("create_session", false) and not created_session:
			created_session = true
			await client.connection.request_action("session_new", {"name": "elsewhere"})
		if is_instance_valid(client.host):
			var app: Node = client.host.application
			var view: Control = client.host.workspace_view
			if view != null and bool(control.get("pan_away", false)) != panned_away:
				panned_away = bool(control.pan_away)
				if panned_away:
					view.overview = true
					view.navigation_center = Vector2(5000, 5000)
					view.navigation_zoom = 1.0
					view._apply_navigation()
				else:
					view.show_main()
			var key: String = PaneAddress.key(client.connection.local_id(int(control.wire_pane))) if control.has("wire_pane") else client.host.pane_focus
			if viewed and control.has("wire_pane") and client.host.pane_focus != key:
				client.host.focus_pane(key)
			app.agents._sounds = {"enabled": false}
			app.agent_attention.in_view = func(host): return viewed and host == client.host and host.presentation_active
			app.agent_attention.refresh()
			var node: Dictionary = app.agent_api.graph.nodes.get(key, {})
			var row_status := ""
			for row in app.agents.rows:
				if row.key == key: row_status = row.status
			var projected: Variant = app.agent_attention.attention(client.host, key)
			var state := JSON.stringify({"connected": client.connection.connected,
				"presented": client.host.pane_is_presented(key), "status": row_status, "marker": app.agent_attention.marker(client.host, [key]).state,
				"attention": node.get("attention"), "projected_event": projected.event if projected is Dictionary else null, "held": client.connection.held, "sent": client.connection.sent,
				"rejected": client.connection.rejected, "workspace": client.connection.workspace,
				"control": control, "provider": node.get("provider"),
				"sessions": client.connection.available_sessions})
			if state != published:
				var file := FileAccess.open(directory.path_join("state.tmp"), FileAccess.WRITE)
				file.store_string(state)
				file.close()
				DirAccess.rename_absolute(directory.path_join("state.tmp"), directory.path_join("state.json"))
				published = state
		await process_frame
	push_error("Agent receipt peer timed out")
	quit(1)
