extends SceneTree
## Waiting states show a turning spinner, so "Connecting…" reads as in progress.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	TranslationServer.set_locale("en")
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 2.0
	root.size = Vector2i(1040, 260)
	var backdrop := ColorRect.new()
	backdrop.color = Color("101720")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(backdrop)
	var card: Control = preload("res://scenes/remote/ServerCard.gd").new()
	card.position = Vector2(16, 16)
	card.size = Vector2(488, 96)
	root.add_child(card)
	card.update_identity({"name": "Studio Mac", "url": "wss://studio.local:7681"})
	card.status.text = "Connecting to server…"
	for state in ["connecting", "authenticating"]:
		card.update_state(state, true)
		assert(card.spinner.visible and not card.indicator.visible, "%s shows the spinner" % state)
	var start: float = card.spinner.rotation
	for i in 20: await process_frame
	assert(not is_equal_approx(card.spinner.rotation, start), "the spinner turns")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/graffitty-connecting-spinner.png")
	for state in ["connected", "offline", "password"]:
		card.update_state(state, true)
		assert(not card.spinner.visible and card.indicator.visible, "%s shows the status dot" % state)
	# The restore cover pairs its "Connecting…" label with the same spinner.
	var manager_source := FileAccess.get_file_as_string("res://scenes/remote/RemoteManager.gd")
	assert(manager_source.contains("BusySpinner.gd"), "the restore cover shows a spinner")
	card.queue_free()
	await process_frame
	print("PASS waiting states show a turning spinner")
	quit()
