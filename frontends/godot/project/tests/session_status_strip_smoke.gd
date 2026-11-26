extends "res://tests/session_effects_smoke.gd"
## A session switch fades status strips with the pane backing; only text
## flies. The live strips stay hidden until the arrival lands.

func flight_layers(world: Node, path: String, arriving: bool) -> Array:
	if path == "flat-2d":
		var layer: Node = world._transition_in if arriving else world._transition_out
		return [] if not is_instance_valid(layer) else layer.pane_groups.filter(func(group): return group.has_meta("workspace_chrome"))
	return (world.tab_fx_in if arriving else world.tab_fx_out).filter(func(layer): return layer.has_meta("workspace_chrome"))

func faded_2d(group: Node2D) -> bool:
	return group.scale.x < 1.0 and is_equal_approx(group.get_child(0).material.get_shader_parameter("progress"), 1.0)

func faded_3d(layer: Node, world: Node) -> bool:
	var material: ShaderMaterial = layer._material()
	return layer.has_meta("panel") and not material.get_shader_parameter("grouped_flight") and is_equal_approx(world._layer_fly(layer, 0.3), 1.0)

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		printerr("Requires an isolated session-effects fixture")
		quit(2)
		return
	root.size = Vector2i(1200, 800)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-2d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	# Sessions shown in overview earlier in this run arrive with status strips.
	var visited := {"alpha": true}
	for path in ["flat-2d", "flat-3d"]:
		check(host.switch_world(path), "Open world " + path)
		await create_timer(0.5).timeout
		var world: Node = host.world
		var view: Control = host.workspace_view
		host.set_session_transition_effect("fly_away_and_in")
		for incoming in ["beta", "alpha"]:
			view.overview = true
			view.navigation_zoom = 0.45
			view._apply_navigation()
			var shown: bool = await until(func(): return view.status_strips.values().any(func(strip): return strip.visible), 4.0)
			check(shown, path + " overview shows a status strip before switching to " + incoming)
			if not shown: continue
			var seen := {"flight": false, "live": 0, "departure": false, "arrival": false}
			var observe := func():
				if world.tab_fx_t < 0.0 and not world.tab_fx_preparing: return
				seen.flight = true
				for strip in view.status_strips.values():
					if strip.is_visible_in_tree() and strip.modulate.a > 0.0: seen.live += 1
				seen.departure = seen.departure or not flight_layers(world, path, false).is_empty()
				seen["arrival"] = seen["arrival"] or not flight_layers(world, path, true).is_empty()
			process_frame.connect(observe)
			var result: Dictionary = await client.connection.request_action("session_switch", {"name": incoming})
			check(result.get("type") != "error", path + " switches to " + incoming)
			check(await until(func(): return world.tab_fx_t >= 0.0), path + " session flight starts")
			var departing: Array = flight_layers(world, path, false)
			if visited.has(incoming):
				# Freeze the clock and record departure frames as evidence.
				world.set_process(false)
				for phase in [0.0, 0.2, 0.4, 0.7]:
					world.tab_fx_t = world._tab_departure_duration() * phase
					if path == "flat-2d": world._update_transition_2d(0.0)
					else: world._update_tab_transition(0.0)
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_TEST_EVIDENCE").path_join("%s-%s-%.1f.png" % [path, incoming, phase]))
				world.set_process(true)
			if path == "flat-2d" and is_instance_valid(world._transition_out):
				world._transition_out.set_progress(0.3)
				check(departing.all(faded_2d), "2D strips fade and recede with the pane backing before most text departs")
			elif path == "flat-3d":
				check(departing.all(faded_3d.bind(world)), "3D strips fade with the pane backing before most text departs")
			check(await until(func(): return world.tab_fx_t < 0.0 and not world.tab_fx_preparing), path + " arrival lands")
			process_frame.disconnect(observe)
			check(seen.flight and seen.departure, path + " departure captures status strips")
			if visited.has(incoming): check(seen["arrival"], path + " arrival captures status strips")
			visited[incoming] = true
			check(seen.live == 0, path + " live status strips stay hidden during the flight (%d visible frames)" % seen.live)
			await create_timer(0.5).timeout
	client.queue_free()
	await process_frame
	print("SESSION_STATUS_STRIP_PASS" if failures.is_empty() else "SESSION_STATUS_STRIP_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
