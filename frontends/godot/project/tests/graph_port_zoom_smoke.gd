extends SceneTree
## Graph ports stay on their panes on every zoomed frame: eased mouse wheel,
## pinch, and direct zoom. Each pane gets one input and one output port.
##
##     godot --path . --script tests/graph_port_zoom_smoke.gd -- --no-focus-skip --shell=/bin/sh [--plugin=flat-3d]
##
## Before every draw, each visible port must sit where the displayed camera
## projects its sheet anchor. A port that trails the camera by a frame fails.
var host: Node
var view: Control
var failures: Array[String] = []
var samples := 0
var lagging_frames := 0
var worst := 0.0

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graph-port-zoom-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated.path_join("config"))
	OS.set_environment("XDG_STATE_HOME", isolated.path_join("state"))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func sample() -> void:
	var links: Control = view.agent_links
	if not links.editing: return
	var lagging := false
	for key in links.ports:
		for slot in links.ports[key]:
			var button: Button = links.ports[key][slot]
			if not button.visible or not button.has_meta("sheet_anchor"): continue
			var expected: Vector2 = view.view_point(button.get_meta("sheet_anchor")) - button.size * .5
			var error := expected.distance_to(button.position)
			samples += 1
			worst = maxf(worst, error)
			if error > 1.0: lagging = true
	if lagging: lagging_frames += 1

func zoom_frames(label: String, step: Callable) -> void:
	samples = 0
	lagging_frames = 0
	worst = 0.0
	RenderingServer.frame_pre_draw.connect(sample)
	for i in 120:
		# Power saving draws only changed frames; sample every frame.
		OS.low_processor_usage_mode = false
		step.call(i)
		await process_frame
	RenderingServer.frame_pre_draw.disconnect(sample)
	check(samples > 0 and lagging_frames == 0, "%s: ports follow the zoom on every frame (%d lagging frames, worst %.1f px, %d samples)" % [label, lagging_frames, worst, samples])

func run() -> void:
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	while wrapper.host == null: await process_frame
	host = wrapper.host
	view = host.workspace_view
	await create_timer(2).timeout
	host.create_terminal_window(host.pane_focus)
	await create_timer(1.5).timeout
	view.show_overview()
	var graph = host.agent_api.graph
	for key in graph.nodes:
		graph.nodes[key]["manifest"] = {"inputs": [{"id": "", "color": "#89ddbd", "name": "in"}], "outputs": [{"id": "", "color": "#8ab4f8", "name": "out"}]}
	view._projection_changed()
	await create_timer(1).timeout
	var center: Vector2 = view.size * 0.5
	# Wheel notches ease over several frames inside WorkspaceView._process.
	await zoom_frames("Mouse wheel", func(i: int):
		if i % 10 == 0: view.wheel_zoom(1.0 if (i / 40) % 2 == 0 else -1.0, center))
	await zoom_frames("Pinch", func(i: int):
		var pinch := InputEventMagnifyGesture.new()
		pinch.factor = 1.03 if (i / 30) % 2 == 0 else 0.97
		pinch.position = Vector2(root.size) * 0.5
		root.push_input(pinch))
	await zoom_frames("Direct zoom", func(i: int):
		view.zoom_workspace(1.02 if (i / 30) % 2 == 0 else 0.98, center))
	print("GRAPH_PORT_ZOOM_PASS" if failures.is_empty() else "GRAPH_PORT_ZOOM_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
