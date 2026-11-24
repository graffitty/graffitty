extends SceneTree
## Observe a second client's area claim while the desktop camera is idle.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1260, 780)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	while wrapper.host == null or wrapper.host.world == null or wrapper.host.workspace_view.panes.is_empty():
		await process_frame
	var view: Control = wrapper.host.workspace_view
	var world: Node = wrapper.host.world
	view.show_main()
	await create_timer(0.25).timeout
	world._set_world_awake(false)
	var ready := FileAccess.open(OS.get_environment("GRAFFITTY_TEST_READY"), FileAccess.WRITE)
	ready.close()
	var phone := Rect2(0, 35, 412, 290)
	while view.content_rect() != phone:
		await process_frame
	await process_frame
	var center: Vector2 = world.sheet_window_fraction(phone.get_center()) * view.size
	var expected := Vector2(view.viewport_content_rect().get_center())
	if center.distance_to(expected) > 6 or not view.raster_region.encloses(phone):
		printerr("Phone layout clipped on desktop: center ", center, " expected ", expected, " crop ", view.raster_region)
		quit(1)
	else:
		print("REMOTE_AREA_HANDOFF_PASS")
		quit(0)
