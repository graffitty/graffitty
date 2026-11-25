extends Node
## Closing the owning pipe tells the CLI to reap its SSH process.
signal prepared(settings: Dictionary, detail: String, exit_code: int)
var _process_info := {}
var _handshake := PackedByteArray()
var _errors := PackedByteArray()
var _ready_sent := false

func start(args: PackedStringArray) -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_process_info = OS.execute_with_pipe(preload("res://graffitty/executables.gd").cli(), args, false)
	if _process_info.is_empty(): _finish.call_deferred("", -1)

func _process(_delta: float) -> void:
	if _process_info.is_empty(): return
	var alive := OS.is_process_running(_process_info.pid)
	var chunk: PackedByteArray = _process_info.stderr.get_buffer(8192)
	if not chunk.is_empty():
		_errors.append_array(chunk)
		if _errors.size() > 8192: _errors = _errors.slice(-8192)
	var data: PackedByteArray = _process_info.stdio.get_buffer(8192)
	if not _ready_sent and not data.is_empty():
		_handshake.append_array(data)
		if _handshake.size() > 65536:
			_finish("", -1)
			return
		if _handshake.find(10) >= 0:
			var packet: Variant = JSON.parse_string(_handshake.get_string_from_utf8())
			_handshake.clear()
			if not packet is Dictionary or not packet.get("connections") is Array or packet.connections.size() != 1 or not packet.connections[0] is Dictionary:
				_finish("", -1)
				return
			_ready_sent = true
			prepared.emit(packet.connections[0], "", 0)
	if not alive and chunk.is_empty() and data.is_empty():
		_finish(_errors.get_string_from_utf8().strip_edges(), OS.get_process_exit_code(_process_info.pid))

func _finish(detail: String, code: int) -> void:
	close()
	if not _ready_sent:
		_ready_sent = true
		prepared.emit({}, detail, code)

func close() -> void:
	set_process(false)
	for key in ["stdio", "stderr"]:
		if _process_info.has(key): _process_info[key].close()
	_process_info.clear()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE: close()
