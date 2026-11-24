extends "res://tests/unit/test_case.gd"

const PaneAddress := preload("res://scenes/PaneAddress.gd")

class Transport extends Node:
	var server_fonts := {"ready": true}
	var topology: Dictionary


func test_close_ack_retires_tab_and_panes_before_topology_broadcast() -> void:
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	var first := Transport.new()
	var second := Transport.new()
	first.topology = _topology([1, 2])
	second.topology = _topology([3])
	federation.connections.assign([first, second])
	federation.labels[first] = "First"
	federation.labels[second] = "Second"
	federation.frames = {11: {}, 21: {}, 31: {}}
	federation._merge()
	expect(federation.topology.tabs.size() == 3, "Both servers contribute their tabs")
	# Input/action replies update canonical workspace state before the later
	# broadcast removes the closed tab's stale topology entries.
	first.topology.workspace_state = _topology([1]).workspace_state
	federation._merge()
	expect(federation.topology.tabs.map(func(tab): return tab.id) == [1, 3], "The acknowledgement removes the closed tab immediately")
	expect(federation.topology.panes.map(func(pane): return pane.id) == [11, 31], "Closed terminal panes retire in the same presentation update")
	expect(federation.topology.chromiums.map(func(pane): return pane.id) == [12, 32], "Closed Chromium panes retire with their tab")
	expect(not federation.owners.has(2) and not federation.owners.has(21) and not federation.owners.has(22), "No routing ownership survives for the closed workspace")
	expect(not federation.frames.has(21) and federation.frames.has(31), "Closed frames are released without affecting the other server")
	for tab in federation.topology.tabs:
		expect(not tab.canonical_layout.is_empty(), "No transient empty layout can delete the outgoing presentation before capture")
	var acknowledged: Dictionary = federation.topology.duplicate(true)
	first.topology = _topology([1])
	federation._merge()
	expect(federation.topology == acknowledged, "The subsequent topology broadcast preserves the same membership")
	federation.free()
	first.free()
	second.free()


func _topology(ids: Array) -> Dictionary:
	var result := {"tabs": [], "panes": [], "chromiums": [], "authoritative_layout": true,
		"workspace_state": {"order": ids.duplicate(), "layout": {"tabs": {}}, "tabs": {}}}
	for id in ids:
		result.tabs.append({"id": id, "title": "Shell"})
		result.panes.append({"id": id * 10 + 1, "tab": id})
		result.chromiums.append({"id": id * 10 + 2, "tab": id, "owner": id})
		result.workspace_state.layout.tabs[str(id)] = {"focused": PaneAddress.key((id * 10 + 1))}
	return result

func test_same_session_reconnect_invalidates_only_its_subscriptions() -> void:
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	var first := preload("res://scenes/remote/RemoteConnection.gd").new()
	var second := preload("res://scenes/remote/RemoteConnection.gd").new()
	federation.owners = {1: first, 2: second}
	federation.subscriptions = [1, 2]
	federation.frames = {1: {}, 2: {}}
	federation.selected = first
	first.session_restored = true
	federation._session_switched(first)
	expect(federation.subscriptions == [2] and federation.frames.keys() == [2], "A reconnect requires fresh subscription and frames while preserving the other server")
	expect(federation.selected == first, "The resumed session becomes the presentation target")
	federation.free()
	first.free()
	second.free()


func test_background_restoration_does_not_navigate_but_explicit_switch_does() -> void:
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	var foreground := preload("res://scenes/remote/RemoteConnection.gd").new()
	var background := preload("res://scenes/remote/RemoteConnection.gd").new()
	federation.selected = foreground
	federation.owners = {1: foreground, 2: background}
	background.display_name = "Background fixture"
	background.connected = true
	background.session_switching.connect(federation._session_switching.bind(background))
	background.session_switched.connect(federation._session_switched.bind(background))
	var events: Array = []
	federation.session_switching.connect(func(): events.append("switching"))
	federation.session_switched.connect(func(): events.append("switched"))
	for previous in ["", "$2"]:
		background.workspace = ""
		background._shown_session = previous
		background._selecting_session = 5
		federation.subscriptions = [1, 2]
		federation.frames = {1: {}, 2: {}}
		background._receive({"type": "session_switched", "workspace": "$2"})
		expect(federation.selected == foreground and events.is_empty(), "Initial restore and reconnect cannot capture or replace the foreground view")
		expect(federation.frames.keys() == [1] and federation.subscriptions == [1], "Only the restoring server's stale frames and subscriptions retire")
		expect(federation.labels[background] == "Background fixture / $2", "Background session labels still update")
	background._receive({"type": "session_switched", "workspace": "$3"})
	expect(federation.selected == background and events == ["switching", "switched"], "Explicit navigation to another server still switches and animates normally")
	expect(not background.session_restored and not background.session_reattached, "Navigation is distinguished from automatic reattachment")
	federation.free()
	foreground.free()
	background.free()
