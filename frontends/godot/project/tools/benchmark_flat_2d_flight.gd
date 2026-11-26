extends SceneTree
## Flat 2D session flight cost: letters and dust in the 3D overlay.
##
##     godot --path . --script tools/benchmark_flat_2d_flight.gd -- --no-focus-skip --shell=/bin/sh [--side=-1]
##
## --side=-1 flies right, as a switch to an earlier session does.
##
## Builds the world's own TabTransition2D captures and steps them through
## fixed poses (one per frame), departing alone and departing with an
## arrival. Records idle and flight frame times, build time, the first
## frames (shader compilation would show here) and the overlay's memory.
##
## Prints `FLIGHT {json}` lines and writes flight.json and screenshots to
## GRAFFITTY_2D_ARTIFACTS (default: the OS cache folder).
const PaneAddress := preload("res://scenes/PaneAddress.gd")
const Transition2D := preload("res://scenes/TabTransition2D.gd")
const STEPS := 180
var folder := OS.get_environment("GRAFFITTY_2D_ARTIFACTS")
var host: Node
var world: Node
var samples: Array[Dictionary] = []

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("flat-flight-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated.path_join("config"))
	OS.set_environment("XDG_STATE_HOME", isolated.path_join("state"))
	if folder.is_empty(): folder = OS.get_cache_dir().path_join("graffitty-flat-2d")
	DirAccess.make_dir_recursive_absolute(folder)
	run.call_deferred()

func run() -> void:
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	while wrapper.host == null: await process_frame
	host = wrapper.host
	await create_timer(2).timeout
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1600, 1000)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# Power saving draws only changed frames; measure every frame instead.
	OS.low_processor_usage_mode = false
	host.switch_world("flat-2d")
	world = host.world
	world.fx_cfg.scene.session_switch.effect = "fly_away_and_in"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--side="): world.session_flight_side = float(arg.substr(7))
	await create_timer(1).timeout
	for count in [1, 4]:
		while host.workspace_view.panes.size() < count:
			host.create_terminal_window(host.pane_focus)
			await create_timer(0.5).timeout
		for key in world._shown_panes():
			if not host.is_terminal_pane(key): continue
			var term: Node = host.sessions[PaneAddress.id(key)].term
			term.send_text("clear; i=0; while [ $i -lt 60 ]; do printf '\\033[38;2;255;%dm%03d FLIGHT dense text ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 ()[]{}\\033[0m\\n' $((i*4)) $i; i=$((i+1)); done\r")
		await create_timer(2).timeout
		world._settle_camera_at_rest()
		world._apply_camera_fx()
		await create_timer(0.5).timeout
		samples.append(await idle(count))
		for round_index in 2:
			for both in [false, true]:
				samples.append(await flight(count, both, round_index))
	var file := FileAccess.open(folder.path_join("flight.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"godot": Engine.get_version_info().string, "os": OS.get_name(),
		"cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
		"driver": RenderingServer.get_current_rendering_driver_name(), "window": root.size,
		"vsync": "disabled", "steps_per_flight": STEPS, "samples": samples}, "  "))
	print("FLIGHT_DONE " + folder.path_join("flight.json"))
	quit()

func stats(frames: Array[float]) -> Dictionary:
	var sorted := frames.duplicate()
	sorted.sort()
	var total := 0.0
	for ms in frames: total += ms
	return {"frames": frames.size(), "mean_ms": total / frames.size(), "p50_ms": sorted[sorted.size() / 2],
		"p95_ms": sorted[int(sorted.size() * 0.95)], "worst_ms": sorted.back()}

func idle(count: int) -> Dictionary:
	var frames: Array[float] = []
	var previous := Time.get_ticks_usec()
	for i in STEPS:
		OS.low_processor_usage_mode = false
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frames.append((now - previous) / 1000.0)
		previous = now
	var sample := {"panes": count, "case": "idle", "vram_mib": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0}
	sample.merge(stats(frames))
	print("FLIGHT " + JSON.stringify(sample))
	return sample

func flight(count: int, both: bool, round_index: int) -> Dictionary:
	var vram_before: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	var built := Time.get_ticks_usec()
	world.session_transition_active = true
	var layers: Array[Node2D] = []
	for arriving in ([false, true] if both else [false]):
		var layer := Transition2D.new()
		layer.arriving = arriving
		world._foreground_canvas_2d.add_child(layer)
		world._building_switch_arrival = arriving
		layer.build(world)
		layers.append(layer)
	world._building_switch_arrival = false
	var build_ms := (Time.get_ticks_usec() - built) / 1000.0
	var frames: Array[float] = []
	var vram_peak := vram_before
	var previous := Time.get_ticks_usec()
	var shots := {0: "start", STEPS / 4: "quarter", STEPS / 2: "half"}
	for i in STEPS:
		var p := float(i) / float(STEPS - 1)
		for layer in layers: layer.set_progress(1.0 - p if layer.arriving else p)
		OS.low_processor_usage_mode = false
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frames.append((now - previous) / 1000.0)
		vram_peak = maxf(vram_peak, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
		previous = now
		if round_index == 0 and count == 1 and shots.has(i):
			root.get_texture().get_image().save_png(folder.path_join("flight-%s-%s.png" % ["both" if both else "out", shots[i]]))
			previous = Time.get_ticks_usec()
			frames.pop_back()
	var pieces := 0
	for layer in layers:
		for piece in layer.glyphs: pieces += piece.multimesh.instance_count
		layer.queue_free()
	world.session_transition_active = false
	var sample := {"panes": count, "case": "out-and-in" if both else "out", "round": round_index,
		"pieces": pieces, "build_ms": build_ms, "first_frame_ms": frames[0], "first5_worst_ms": frames.slice(0, 5).max(),
		"flight_vram_mib": (vram_peak - vram_before) / 1048576.0}
	sample.merge(stats(frames.slice(5)))
	print("FLIGHT " + JSON.stringify(sample))
	await create_timer(0.3).timeout
	return sample
