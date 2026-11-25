extends SceneTree
const Service := preload("res://scenes/AppNotifications.gd")
const Card := preload("res://scenes/NotificationCard.gd")
const Overlay := preload("res://scenes/NotificationOverlay.gd")
var failures := 0
class Host extends Node:
	var application: Node
class Application extends Node:
	var notifications: Node
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	var app := Application.new()
	root.add_child(app)
	app.notifications = Service.new()
	app.add_child(app.notifications)
	var host := Host.new()
	host.application = app
	app.add_child(host)
	var overlay := Overlay.new()
	overlay.host = host
	host.add_child(overlay)
	var progress := {"id": "test", "name": "test.png", "received": 4096, "total": 8192, "state": "receiving"}
	app.notifications.upload_progress(progress, host, 7)
	check(overlay.cards.size() == 1, "Upload opens one notification")
	var card: Card = overlay.cards[0]
	check(card.progress_bar.value == 50 and "50%" in card.progress_label.text, "Received bytes drive progress and percentage")
	overlay._process_body(60)
	check(not card.leaving, "Active transfer survives the ordinary notification lifetime")
	progress.received = 8192
	progress.state = "complete"
	app.notifications.upload_progress(progress, host, 7)
	check(overlay.cards.size() == 1 and app.notifications.history.size() == 1, "Completion updates the same toast and history entry")
	check(card.progress_bar.value == 100 and card.remaining == Service.DEFAULT_TIMEOUT and not card.entry.active, "Completion starts the full default timeout")
	overlay._process_body(Service.DEFAULT_TIMEOUT + 1)
	check(card.leaving, "Completed transfer dismisses after default lifetime")
	progress.id = "interrupted"
	progress.received = 4096
	progress.state = "receiving"
	app.notifications.upload_progress(progress, host, 8)
	app.notifications.fail_uploads(host, 7)
	check(app.notifications.history[-1].active, "Other pane disconnect does not cancel this transfer")
	app.notifications.fail_uploads(host, 8)
	check(not app.notifications.history[-1].active and app.notifications.history[-1].level == "error", "Disconnect finishes the transfer with an error")
	progress.id = "empty"
	progress.total = 0
	progress.received = 0
	progress.state = "complete"
	app.notifications.upload_progress(progress, host, 7)
	check(overlay.cards[-1].progress_bar.value == 100, "Empty upload completes at 100 percent")
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
