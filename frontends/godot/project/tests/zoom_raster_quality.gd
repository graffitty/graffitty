extends "res://tests/session_effects_smoke.gd"
## Run with tests/godot/test_session_effects.py --case raster.

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		printerr("Requires an isolated session-effects fixture")
		quit(2)
		return
	root.size = Vector2i(1600, 1000)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-3d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	var world: Node = host.world
	var view: Control = host.workspace_view
	world.set_process(false)
	var pair: Dictionary = host.sessions[host.active_session_id]
	var shell_command := "printf '\\033[2J\\033[12;1HZoom quality: ABC xyz 0123456789\\033[13;20H'; read -r done"
	if OS.get_name() == "Windows":
		shell_command = "[Console]::Write(\"`e[2J`e[12;1HZoom quality: ABC xyz 0123456789`e[13;20H\"); [Console]::ReadLine()"
	client.connection.send_input(host.active_session_id, (shell_command + "\r").to_utf8_buffer())
	check(await until(func(): return pair.term.get_cursor_cell() == Vector2i(19, 12)), "Shell fixture is ready")
	var grid: Vector2i = pair.term.get_grid_size()
	var font: int = pair.term.get_live_font_size()
	world.fx_last_key = -1e8
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "typing")
	world.fx_cfg.set_option("scene.camera", "dof_blur_amount", 0.0)
	world.fx_cfg.set_option("state.idle", "camera.tilt_limit_deg", 0.0)
	world.fx_cfg.set_option("state.idle", "sheet.curvature_deg", 0.0)
	world.fx_cfg.set_option("state.idle", "sheet.ripple", 0.0)
	var received := { 'point': Vector2.INF }
	pair.term.gui_input.connect(
		func(event):
			if event is InputEventMouseButton:
				received.point = event.position,
	)
	var backing: float = view.get_viewport().get_final_transform().get_scale().x
	var base_density := ceilf(maxf(backing, 1.0) * 2.0) / 2.0
	for zoom in [1.0, 2.0, 4.0, 6.0, 1.0]:
		world.fx_cfg.set_option("state.idle", "camera.zoom", zoom)
		for i in 180:
			world._fx_step(1.0 / 60)
		world._update_ink_view()
		for i in 4:
			await process_frame
		var density: float = view.canvas_scale()
		if zoom == 1.0:
			var pane: Control = view.panes[host.pane_focus]
			var canvas_pixels := Vector2i(view.raster_region.size * base_density)
			var pane_pixels := Vector2i(pane._layout_region.size * base_density)
			check(view.canvas.size == canvas_pixels and pair.vp.size == pane_pixels,
				"Rest at %.2f backing: canvas %s × %.1f = %s, pane %s × %.1f = %s" % [
					backing, view.raster_region.size, base_density, view.canvas.size,
					pane._layout_region.size, base_density, pair.vp.size])
			check(view.canvas.use_hdr_2d and pair.vp.use_hdr_2d, "Both live textures use linear HDR")
		else:
			check(
				density > base_density * zoom * .65,
				'Raster density follows %.0fx zoom (%.2f texels per layout pixel)' % [zoom, density],
			)
		check(
			pair.term.get_grid_size() == grid and pair.term.get_live_font_size() == font,
			'%.0fx zoom preserves terminal grid and font metrics' % zoom,
		)
		check(
			view.canvas.size.x * view.canvas.size.y <= 20_000_000,
			'Canvas stays within its raster budget',
		)
		# Exercise both canvas and terminal crop transforms through real GUI input.
		var sheet_cursor: Vector2 = world._camera_cursor_uv() * world._sheet_size()
		var screen: Vector2 = view.window_point(sheet_cursor)
		var motion := InputEventMouseButton.new()
		motion.button_index = MOUSE_BUTTON_LEFT
		motion.pressed = true
		motion.position = view.pointer.get_global_transform_with_canvas().affine_inverse() * screen
		received.point = Vector2.INF
		view._forward_pointer(motion)
		motion.pressed = false
		view._forward_pointer(motion)
		var wanted: Vector2 = sheet_cursor - view.terminal_origin(host.pane_focus) - pair.term.position
		check(
			received.point.distance_to(wanted) < 2.0,
			'%.0fx zoom preserves terminal pointer coordinates: actual %s wanted %s screen %s'
			% [zoom, received.point, wanted, screen],
		)
		if DisplayServer.get_name() != 'headless':
			RenderingServer.force_draw()
			var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
			root.get_texture().get_image().save_png(evidence.path_join("raster-%dx.png" % int(zoom)))
	print(preload("res://graffitty/render_stats.gd").report(self))
	client.queue_free()
	await process_frame
	await process_frame
	print('ZOOM_RASTER_PASS' if failures.is_empty() else 'ZOOM_RASTER_FAIL: ' + str(failures))
	quit(0 if failures.is_empty() else 1)
