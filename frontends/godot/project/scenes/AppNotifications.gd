extends Node
## In-app notices only. Engine diagnostics and desktop OSC notifications keep
## their existing routes. History is shared by all windows for this app session.
signal posted(entry: Dictionary)
signal updated(entry: Dictionary)
signal cleared
const DEFAULT_TIMEOUT := 8.0
const MAX_HISTORY := 1000
var history: Array[Dictionary] = []
var serial := 0
var _seen: Dictionary = {}

func post(title: String, body: String, owner: Node, level := "info", timeout := DEFAULT_TIMEOUT, event_id := "", localization: Dictionary = {}) -> Dictionary:
	if not event_id.is_empty() and _seen.has(event_id): return _seen[event_id]
	serial += 1
	var entry := {"id": serial, "title": title.left(200), "body": body.left(16384),
		"level": level if level in ["info", "success", "warning", "error"] else "info",
		"time": Time.get_datetime_string_from_system(false, true),
		"owner": owner.get_instance_id() if is_instance_valid(owner) else 0,
		"timeout": clampf(timeout, 1.0, 60.0), "event_id": event_id, "localization": localization.duplicate(true)}
	history.append(entry)
	if not event_id.is_empty(): _seen[event_id] = entry
	if history.size() > MAX_HISTORY: _seen.erase(history.pop_front().event_id)
	posted.emit(entry)
	return entry

func clear_history() -> void:
	history.clear()
	_seen.clear()
	cleared.emit()

## One history entry and toast per transfer, updated from server acknowledgments.
func upload_progress(progress: Dictionary, owner: Node, pane: int) -> void:
	var key := "upload:%d:%d:%s" % [owner.get_instance_id(), pane, progress.id]
	var active := str(progress.state) == "receiving"
	var source := "Uploading file" if active else ("Upload complete" if str(progress.state) == "complete" else "Upload failed")
	var level := "info" if active else ("success" if str(progress.state) == "complete" else "error")
	var entry: Dictionary = _seen.get(key, {})
	var fresh := entry.is_empty()
	if fresh:
		# Populate before emitting so even a one-chunk transfer has its bar.
		serial += 1
		entry = {"id": serial, "time": Time.get_datetime_string_from_system(false, true), "owner": owner.get_instance_id(), "event_id": key}
		_seen[key] = entry
		history.append(entry)
		if history.size() > MAX_HISTORY: _seen.erase(history.pop_front().event_id)
	entry.merge({"title": source, "body": str(progress.name).left(255), "level": level,
		"timeout": DEFAULT_TIMEOUT, "localization": {"title": source},
		"progress": progress.duplicate(true), "active": active, "pane": pane}, true)
	if fresh: posted.emit(entry)
	else: updated.emit(entry)

func fail_uploads(owner: Node, pane := -1) -> void:
	if not is_instance_valid(owner): return
	for entry in history:
		if entry.owner != owner.get_instance_id() or not entry.get("active", false): continue
		if pane >= 0 and int(entry.get("pane", -1)) != pane: continue
		var progress: Dictionary = entry.progress.duplicate(true)
		progress.state = "failed"
		upload_progress(progress, owner, int(entry.pane))
