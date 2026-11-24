extends "res://tests/tab_window_session_smoke.gd"
var terminal: Control
var marker := Control.new()
var frame := 0
var top_pull := 0.0
var bottom_pull := 0.0

func capture() -> void:
	await process_frame
	var stretch: float = terminal.get_scroll_stretch()
	top_pull = minf(top_pull, stretch)
	bottom_pull = maxf(bottom_pull, stretch)
	RenderingServer.force_draw()
	root.get_texture().get_image().save_jpg(OS.get_environment("TAKE") + "/main-%04d.jpg" % frame, .97)
	frame += 1

func hold(count: int) -> void:
	for i in count: await capture()

func scroll_row() -> float:
	return float(terminal.get_ui_state().scroll_offset) + terminal.get_scroll_fraction()

func flick(direction: float) -> bool:
	var viewport_size := root.get_visible_rect().size
	var start := viewport_size * Vector2(.75, .63 if direction > 0 else .36)
	var before := scroll_row()
	marker.position = start
	marker.show()
	pan(0, "scroll_phase", "began")
	await hold(5)
	var speed := 0.0
	for i in 5:
		speed = direction * (13 + i * 13)
		marker.position.y -= speed
		pan(speed, "scroll_phase", "changed")
		await capture()
	marker.hide()
	pan(0, "scroll_phase", "ended")
	var release := scroll_row()
	# AppKit sends decaying momentum deltas after the fingers lift.
	for i in 58:
		pan(speed * exp(-float(i) / 24.0), "momentum_phase", "began" if i == 0 else "changed")
		await capture()
	pan(0, "momentum_phase", "ended")
	await hold(30)
	var coast := absf(scroll_row() - release)
	var contact := absf(release - before)
	print("Flick rows during contact / after lift: ", contact, " / ", coast)
	return coast >= 20 and coast > contact * 1.5

func _initialize() -> void:
	Background.install(self)
	run.call_deferred()

func pan(amount: float, kind: String, phase: String) -> void:
	var event := InputEventPanGesture.new()
	event.position = terminal.get_global_transform_with_canvas() * (terminal.size * .5)
	event.delta = Vector2(0, amount * .03)
	event.set_meta(kind, phase)
	event.set_meta("event_time", float(frame) / 60.0)
	terminal.get_viewport().push_input(event, true)

func run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	for i in 600:
		if wrapper.host != null: break
		await process_frame
	if not check_host(wrapper): return
	var host: Node = wrapper.host
	await settled(host)
	root.content_scale_size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.content_scale_factor = 1.0
	await host.set_pane_title(host.pane_focus, "~/cli")
	await wrapper.connection.remote_call(host.active_session_id, "tab.set_title", {"id":host.workspace_layout.active, "title":"Shell"})
	terminal = host.sessions[host.active_session_id].term
	for i in 90: await process_frame
	if not preload("res://scenes/input/InteractionProfile.gd").touch_controls() or host.workspace_view.tab_bar._title_margins != Vector3.ZERO:
		push_error("Expected the mobile tab strip with no desktop title margins")
		quit(1)
		return
	terminal.scroll_to_row(0)
	var overlay := CanvasLayer.new()
	overlay.layer = 120
	root.add_child(overlay)
	overlay.add_child(marker)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.draw.connect(func():
		marker.draw_circle(Vector2.ZERO, 25, Color(.15,.75,1,.22))
		marker.draw_arc(Vector2.ZERO, 25, 0, TAU, 48, Color(.55,.9,1,.95), 3, true)
		marker.draw_circle(Vector2.ZERO, 5, Color.WHITE))
	marker.hide()
	await hold(32)
	var down := await flick(1.0)
	var up := await flick(-1.0)
	print("Terminal edge displacement: ", top_pull, " / ", bottom_pull)
	quit(0 if down and up and top_pull < -1 and bottom_pull > 1 and absf(terminal.get_scroll_stretch()) < 1 else 1)
