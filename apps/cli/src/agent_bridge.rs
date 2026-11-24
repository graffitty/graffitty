//! Provider discovery and blocking I/O, run off the Godot main thread.
#[cfg(unix)]
use std::os::unix::{fs::{FileTypeExt, MetadataExt}, net::UnixStream};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::Duration,
};
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

// Godot parses JSON numbers as doubles and writes PIDs/offsets as `123.0`.
// Accept exact whole numbers, rejecting fractions and unsafe float integers.
fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let n = value.as_f64()?;
        (n.is_finite() && n.fract() == 0.0 && n.abs() <= 9_007_199_254_740_991.0)
            .then_some(n as i64)
    })
}

fn home() -> PathBuf {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}
pub(crate) fn provider_home(provider: &str) -> PathBuf {
    let (variable, default) = if provider == "claude" {
        ("CLAUDE_CONFIG_DIR", ".claude")
    } else {
        ("CODEX_HOME", ".codex")
    };
    let path = std::env::var_os(variable)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(default));
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    }
}
fn claude_directory(root: &Value, pid: i64) -> PathBuf {
    // A hook's home belongs to that process, never to the whole workspace.
    if integer(&root["agent_pid"]) == Some(pid) {
        if let Some(path) = root["provider_home"].as_str() {
            return PathBuf::from(path);
        }
    }
    // Also discover unwrapped processes when their transcript is open.
    for path in crate::sessions::open_paths(pid) {
        for ancestor in path.ancestors() {
            if ancestor.file_name().is_some_and(|name| name == "projects") {
                if let Some(dir) = ancestor.parent() {
                    if dir.join(format!("sessions/{pid}.json")).is_file() {
                        return dir.to_path_buf();
                    }
                }
            }
        }
    }
    provider_home("claude")
}
fn read_json(path: &Path) -> Option<Value> {
    read_json_up_to(path, 1024 * 1024)
}
fn read_json_up_to(path: &Path, limit: u64) -> Option<Value> {
    if fs::metadata(path).ok()?.len() > limit {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}
fn find_transcript(dir: &Path, name: &str, depth: u8) -> Option<PathBuf> {
    if depth == 0 {
        return None;
    }
    for entry in fs::read_dir(dir).ok()?.take(5000).flatten() {
        let p = entry.path();
        if entry.file_type().ok()?.is_dir() {
            if let Some(p) = find_transcript(&p, name, depth - 1) {
                return Some(p);
            }
        } else if p.file_name().is_some_and(|s| s == name) {
            return Some(p);
        }
    }
    None
}
/// Bind only files open in this process. A shared daemon's files identify
/// the daemon, so they cannot establish which frontend owns a thread.
fn codex_files(paths: &[PathBuf], root: &Value) -> Value {
    let mut threads = std::collections::BTreeMap::<String, (PathBuf, Option<PathBuf>)>::new();
    let mut subagents = std::collections::HashSet::new();
    for path in paths {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let lock = path.parent().filter(|p| p.file_name().is_some_and(|n| n == "thread-writer-locks"));
        let (id, home, transcript) = if let Some(dir) = lock {
            let Some(id) = name.strip_suffix(".lock").filter(|id| uuid::Uuid::parse_str(id).is_ok()) else { continue };
            (id.to_owned(), dir.parent().unwrap_or(Path::new("/")).to_path_buf(), None)
        } else if name.starts_with("rollout-") && name.ends_with(".jsonl") {
            use std::io::BufRead;
            let record = fs::File::open(path).ok().and_then(|f| {
                std::io::BufReader::new(f.take(65536)).lines().next()?.ok()
            }).and_then(|line| serde_json::from_str::<Value>(&line).ok());
            let Some(id) = record.as_ref().filter(|v| v["type"] == "session_meta")
                .and_then(|v| v["payload"]["id"].as_str())
                .filter(|id| uuid::Uuid::parse_str(id).is_ok() && name.ends_with(&format!("-{id}.jsonl"))) else { continue };
            // Like tmux's agent-sid.sh, exclude subagent rollouts. Inspect the
            // metadata field, not arbitrary text that might contain "subagent".
            let payload = &record.as_ref().unwrap()["payload"];
            if payload["source"].get("subagent").is_some()
                || payload["source"] == "subagent"
                || payload["parent_thread_id"].is_string()
            {
                subagents.insert(id.to_owned());
                continue;
            }
            let Some(home) = path.ancestors().find(|p| p.file_name().is_some_and(|n| n == "sessions")).and_then(Path::parent) else { continue };
            (id.to_owned(), home.to_path_buf(), Some(path.clone()))
        } else { continue };
        let entry = threads.entry(id).or_insert((home, None));
        if transcript.is_some() { entry.1 = transcript; }
    }
    // A subagent lock may occur before or after its rollout in the fd listing.
    threads.retain(|id, _| !subagents.contains(id));
    if threads.len() != 1 {
        return json!({"discovery_note":if threads.is_empty() {
            "Codex PID detected; no process-bound thread evidence yet. No matching daemon thread has been verified."
        } else { "Multiple threads open in this process; refusing to guess the active thread." }});
    }
    let (id, (home, path)) = threads.into_iter().next().unwrap();
    let mut result = json!({"session_id":id,"provider_home":home,
        "queue_error":"This Codex process owns its session locally and has no external queue endpoint (local mode, e.g. --no-daemon or incompatible command-line config overrides). Detection and transcript reading work; native message delivery is unavailable."});
    if let Some(path) = path {
        result["transcript_path"] = json!(path);
        // A long turn can put its start outside the bounded text preview.
        // Reconstruct lifecycle facts independently, including after restart.
        let baseline = root.get("rollout_scan").filter(|scan| scan.is_object()).or(root.get("observed_turn"))
            .filter(|_| root["session_id"] == id);
        match codex_lifecycle(&path, baseline) {
            Ok(lifecycle) => result.as_object_mut().unwrap().extend(lifecycle.as_object().unwrap().clone()),
            Err(error) => result["discovery_note"] = json!(error.to_string()),
        }
    }
    result
}

pub fn scan(roots: &Value) -> Value {
    let pids: Vec<_> = roots.as_array().into_iter().flatten().filter_map(|r| integer(&r["pid"])).collect();
    let table = crate::sessions::pane_processes(&pids);
    let mut result = serde_json::Map::new();
    let mut daemon_inventories = std::collections::HashMap::<PathBuf, std::result::Result<Vec<Value>, String>>::new();
    let baselines = roots.as_array().into_iter().flatten().filter_map(|root| {
        Some((root["session_id"].as_str()?, root.get("observed_turn")?))
    }).collect();
    for root in roots.as_array().into_iter().flatten() {
        let Some(p) = crate::sessions::foreground(integer(&root["pid"]).unwrap_or(-1), &table)
        else {
            // Godot's process-running API only tracks its own children. Agents
            // are grandchildren launched by the PTY shell; use the OS snapshot.
            if let (Some(key), Some(pid)) = (root["node"].as_str(), integer(&root["agent_pid"])) {
                // A registered process can leave the shell tree. Permission errors
                // give no exit evidence, so retain the last observation.
                let offline = match crate::sessions::process(pid) {
                    Ok(p) => p.state == "Z" || root["started"].as_str().is_some_and(|s| s != p.started),
                    Err(e) => e.kind() == std::io::ErrorKind::NotFound
                        || cfg!(unix) && e.raw_os_error() == Some(libc::ESRCH),
                };
                if offline {
                    result.insert(key.into(), json!({"status":"offline"}));
                }
            }
            continue;
        };
        let kind = crate::sessions::agent_name(&p.executable).unwrap_or_default();
        let mut state = json!({"provider":kind,"pid":p.pid,"started":p.started,"status":"unknown"});
        if kind == "claude" {
            let dir = claude_directory(root, p.pid);
            if let Some(r) = read_json(&dir.join(format!("sessions/{}.json", p.pid))) {
                // Registry records are PID-bound; reject recycled process records.
                let normalize = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
                if r["pid"].as_i64().is_some_and(|id| id != p.pid)
                    || r["procStart"]
                        .as_str()
                        .is_some_and(|s| normalize(s) != normalize(&p.started))
                {
                    continue;
                }
                state["session_id"] = r["sessionId"].clone();
                state["socket_path"] = r["messagingSocketPath"].clone();
                state["registry_dir"] = json!(dir.join("sessions"));
                state["status"] = json!(match r["status"].as_str().unwrap_or("unknown") {
                    "idle" => "idle",
                    "busy" | "working" => "busy",
                    "waiting" | "blocked" => "waiting",
                    _ => "unknown",
                });
                if let Some(id) = r["sessionId"]
                    .as_str()
                    .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                {
                    if let Some(path) =
                        find_transcript(&dir.join("projects"), &format!("{id}.jsonl"), 3)
                    {
                        state["transcript_path"] = json!(path);
                    }
                }
            }
        } else if kind == "codex" {
            let open_paths = crate::sessions::open_paths(p.pid);
            let mut discovered = codex_files(&open_paths, root);
            if discovered.get("session_id").is_none() {
                let ports = crate::codex_discovery::listener_ports(p.pid);
                if !ports.is_empty() {
                    let home = if integer(&root["agent_pid"]) == Some(p.pid) && root["started"].as_str() == Some(&p.started) {
                        root["provider_home"].as_str().map(PathBuf::from).unwrap_or_else(|| provider_home("codex"))
                    } else { provider_home("codex") };
                    // SQLite handles also reveal custom CODEX_HOME locations without
                    // reading process environments or assuming the GUI's home.
                    let homes: std::collections::HashSet<_> = open_paths.iter().filter_map(|path| {
                        let name = path.file_name()?.to_str()?;
                        if !(name.starts_with("logs_") || name.starts_with("state_")) || !name.contains(".sqlite") { return None; }
                        let dir = path.parent()?;
                        dir.join("app-server-control/app-server-control.sock").exists().then(|| dir.to_path_buf())
                    }).collect();
                    let home = if homes.len() == 1 { homes.into_iter().next().unwrap() } else { home };
                    let inventory = daemon_inventories.entry(home.clone()).or_insert_with(|| {
                        crate::codex_discovery::Rpc::connect(&home).and_then(|mut rpc| crate::codex_discovery::inventory(&mut rpc, &baselines)).map_err(|e| e.to_string())
                    });
                    match inventory {
                        Ok(records) => match crate::codex_discovery::select(records, &ports, &home) {
                            Ok(found) => discovered = found,
                            Err(e) => discovered["discovery_note"] = json!(e.to_string()),
                        },
                        Err(e) => discovered["discovery_note"] = json!(format!("Codex listener found; daemon discovery failed: {e}")),
                    }
                }
            }
            state.as_object_mut().unwrap().extend(discovered.as_object().unwrap().clone());
        }

        // A short daemon turn can start and finish between discovery polls.
        // Carry a completed-record checkpoint, not just instantaneous status.
        // Reading stays in this worker and is bounded to the transcript tail.
        if kind == "codex" && state["status"] == "idle" && !state["observed_turn"]["rollout_offset"].is_u64() {
            if let Some(path) = state["transcript_path"].as_str() {
                if let Ok(tail) = transcript(Path::new(path), None) {
                    if tail["status"] != "busy" {
                        if let Some(checkpoint) = completed_checkpoint(&tail) {
                            state["completion_checkpoint"] = json!(checkpoint);
                        }
                    }
                }
            }
        }
        if let Some(key) = root["node"].as_str() {
            result.insert(key.into(), state);
        }
    }
    Value::Object(result)
}

/// Stable completion identity, including an observed pre-turn baseline.
fn completed_checkpoint(tail: &Value) -> Option<u64> {
    tail["completion_checkpoint"].as_u64().or_else(|| {
        // Establish a baseline before the first turn. An incomplete tail of
        // an older transcript cannot establish that there were no completions.
        (tail["status"] == "unknown" && tail["offset"] == 0).then_some(0)
    })
}

fn codex_turn_status(payload: &Value) -> Option<&'static str> {
    match payload["type"].as_str()? {
        "task_started" | "turn_started" | "user_message" => Some("inProgress"),
        "task_complete" | "turn_complete" if !payload["error"].is_null() => Some("failed"),
        "task_complete" | "turn_complete" => Some("completed"),
        "turn_aborted" => Some("interrupted"),
        "error" if payload["message"].is_string() && payload["codex_error_info"] != "thread_rollback_failed"
            && payload["codex_error_info"].get("active_turn_not_steerable").is_none() => Some("failed"),
        _ => None,
    }
}

/// Apply a Codex lifecycle record to the turn it belongs to. Some providers
/// store the failure as a standalone error followed by an ordinary task_complete.
fn update_local_turn(turn: &mut Value, payload: &Value, offset: u64) -> bool {
    let Some(mut status) = codex_turn_status(payload) else { return false; };
    let event = payload["type"].as_str().unwrap();
    let previous_id = turn["id"].as_str();
    let native_id = payload["turn_id"].as_str();
    let same_turn = native_id.is_none() || previous_id == native_id
        || previous_id.is_some_and(|id| id.starts_with("record-"));
    if event == "error" && !matches!(turn["status"].as_str(), Some("inProgress" | "failed")) {
        return false;
    }
    let starting = matches!(event, "task_started" | "turn_started")
        || (event == "user_message" && turn["status"] != "inProgress");
    let id = native_id.or(previous_id.filter(|_| !starting)).map(str::to_owned)
        .unwrap_or_else(|| format!("record-{offset}"));
    let mut error = payload["error"].clone();
    if event == "error" {
        error = json!({"message":payload["message"],"codex_error_info":payload["codex_error_info"]});
    }
    if same_turn && status == "completed" && matches!(turn["status"].as_str(), Some("failed" | "interrupted")) {
        status = if turn["status"] == "failed" { "failed" } else { "interrupted" };
        error = turn["error"].clone();
    }
    *turn = json!({"id":id,"status":status,"error":error});
    true
}

/// Scan complete rollout records in file order, including records without lifecycle events.
fn codex_lifecycle(path: &Path, baseline: Option<&Value>) -> Result<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    scan_rollout(path, baseline, || std::time::Instant::now() >= deadline)
}

fn scan_rollout(path: &Path, baseline: Option<&Value>, mut expired: impl FnMut() -> bool) -> Result<Value> {
    const MAX_RECORD: usize = 1024 * 1024;
    let mut file = fs::File::open(path)?;
    let len = file.metadata()?.len();
    let baseline = baseline.filter(|value| value["rollout_offset"].as_u64().is_some_and(|n| n <= len));
    let attaching = baseline.is_none_or(|value| value["attachment_end"].is_u64());
    // Finish the historical snapshot before consuming records appended during attachment.
    let end = baseline.and_then(|value| value["attachment_end"].as_u64()).unwrap_or(len).min(len);
    let mut offset = baseline.and_then(|value| value["rollout_offset"].as_u64()).unwrap_or(0);
    let mut turn = baseline.map(|value| if attaching { &value["turn"] } else { value }).cloned().unwrap_or(Value::Null);
    let mut skip = baseline.is_some_and(|value| value["skip_record"] == true);
    file.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::with_capacity(128 * 1024, file.take(end - offset));
    let mut position = offset;
    let mut line = Vec::new();
    let mut outcomes = Vec::new();
    while position < end {
        let chunk = reader.fill_buf()?;
        if chunk.is_empty() { break; }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let used = newline.map_or(chunk.len(), |index| index + 1);
        position += used as u64;
        if line.len() + used > MAX_RECORD { skip = true; }
        if !skip { line.extend_from_slice(&chunk[..used]); }
        reader.consume(used);
        if newline.is_some() {
            if !skip && let Ok(record) = serde_json::from_slice::<Value>(&line) && record["type"] == "event_msg" {
                let prior_id = turn["id"].clone();
                let prior_status = turn["status"].clone();
                if update_local_turn(&mut turn, &record["payload"], position) {
                    turn["at"] = record["timestamp"].clone();
                    if turn["status"] == "completed" { turn["completion_checkpoint"] = json!(position); }
                    if !attaching && matches!(turn["status"].as_str(), Some("completed" | "failed"))
                        && (turn["id"] != prior_id || turn["status"] != prior_status) {
                        outcomes.push(turn.clone());
                    }
                }
            }
            line.clear();
            skip = false;
            offset = position;
        } else if skip {
            // The oversized record is discarded until its newline, even across polls.
            offset = position;
        } else {
            // Finish this bounded record before yielding, or retry it after an append.
            continue;
        }
        if expired() { break; }
    }
    if attaching && position < end {
        return Ok(json!({"rollout_scan":{"attachment_end":end,"rollout_offset":offset,"skip_record":skip,"turn":turn}}));
    }
    turn["rollout_offset"] = json!(offset);
    if skip { turn["skip_record"] = json!(true); }
    else { turn.as_object_mut().unwrap().remove("skip_record"); }
    let mut state = json!({"observed_turn":turn,"rollout_scan":null,"turn_outcomes":outcomes});
    if turn["completion_checkpoint"].is_u64() { state["completion_checkpoint"] = turn["completion_checkpoint"].clone(); }
    if turn["status"].is_string() {
        state["status"] = json!(if turn["status"] == "inProgress" { "busy" } else { "idle" });
        if !turn["at"].is_null() { state["status_at"] = turn["at"].clone(); }
    }
    Ok(state)
}

#[derive(Debug)]
struct MissingCompletionRecord;

impl std::fmt::Display for MissingCompletionRecord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("No assistant output for the selected Codex completion")
    }
}
impl std::error::Error for MissingCompletionRecord {}

fn codex_completion_response(path: &Path, target: &Value) -> Result<Value> {
    match completed_codex_output(path, target) {
        Err(error) if target["turn_id"].is_string() && target["checkpoint"].is_null()
            && (error.is::<MissingCompletionRecord>() || error.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound)) => Ok(json!({"status":"awaiting_record"})),
        other => other,
    }
}

/// Read only the completed Codex turn selected by discovery. Daemon discovery
/// selects by native turn ID; local discovery also supplies the exact record end.
fn completed_codex_output(path: &Path, target: &Value) -> Result<Value> {
    let requested_id = target["turn_id"].as_str();
    let checkpoint = target["checkpoint"].as_u64();
    if checkpoint.is_none() && requested_id.is_none() { return Err("Missing completed turn identity".into()); }
    let mut file = fs::File::open(path)?;
    let size = file.metadata()?.len();
    let end = checkpoint.unwrap_or(size);
    if end > size { return Err("Rollout truncated before completion".into()); }
    if checkpoint.is_some() {
        let last = end.checked_sub(1).ok_or("Empty Codex checkpoint")?;
        file.seek(SeekFrom::Start(last))?;
        let mut byte = [0];
        file.read_exact(&mut byte)?;
        if byte != *b"\n" { return Err("Incomplete Codex completion record".into()); }
    }

    let mut completion = None;
    let mut native_id = None;
    let mut text = None;
    reverse_records(&mut file, end, |record_end, record| {
        let payload = &record["payload"];
        let event = (record["type"] == "event_msg").then(|| payload["type"].as_str()).flatten();
        let terminal = matches!(event, Some("task_complete" | "turn_complete"));
        if checkpoint.is_some_and(|end| record_end < end) && (completion.is_none() || terminal) {
            return Err("No assistant output within the selected Codex turn".into());
        }
        if checkpoint == Some(record_end) && (!terminal || !payload["error"].is_null()) {
            return Err("Checkpoint is not a successful Codex completion".into());
        }
        if terminal {
            let id = payload["turn_id"].as_str();
            let selected = payload["error"].is_null() && checkpoint.is_none_or(|n| n == record_end)
                && requested_id.zip(id).is_none_or(|(wanted, actual)| wanted == actual);
            completion = selected.then_some(record_end);
            native_id = id.map(str::to_owned);
            text = payload["last_agent_message"].as_str().filter(|s| !s.is_empty()).map(str::to_owned);
        }
        let Some(completion_end) = completion else { return Ok(None); };
        if record["type"] == "response_item" && payload["role"] == "assistant" && text.is_none() {
            let message = payload["content"].as_array().into_iter().flatten()
                .filter_map(|part| part["text"].as_str()).collect::<Vec<_>>().join("\n");
            if !message.is_empty() { text = Some(message); }
        }
        let start = matches!(event, Some("task_started" | "turn_started" | "user_message"));
        let id_from_record = || payload["turn_id"].as_str().map(str::to_owned)
            .unwrap_or_else(|| format!("record-{record_end}"));
        let named_context = record["type"] == "turn_context" && payload["turn_id"].is_string();
        let standalone = terminal && requested_id.is_some_and(|id| id == format!("record-{record_end}"));
        let actual_id = native_id.clone().or_else(|| (start || named_context || standalone).then(id_from_record));
        if let Some(message) = &text && requested_id.is_none_or(|wanted| actual_id.as_deref() == Some(wanted)) {
            return Ok(Some(json!({"last_message":message,"completion_checkpoint":completion_end,"turn_id":actual_id,"size":size})));
        }
        // A user message can follow its task_started. Keep looking for the native
        // start ID only when the answer for this turn has already been captured.
        if matches!(event, Some("error" | "turn_aborted" | "task_started" | "turn_started"))
            || event == Some("user_message") && (text.is_none() || payload["turn_id"].is_string()) {
            completion = None;
        }
        Ok(None)
    })?.ok_or_else(|| MissingCompletionRecord.into())
}

/// Visit complete JSONL records backwards without collecting the entire transcript.
/// The supplied offset is exclusive; an unfinished final record is skipped.
fn reverse_records(file: &mut fs::File, mut position: u64,
    mut visit: impl FnMut(u64, Value) -> Result<Option<Value>>) -> Result<Option<Value>> {
    let mut block = vec![0; 128 * 1024];
    let mut line = Vec::new();
    let mut record_end = None;
    let mut oversized = false;
    while position > 0 {
        let count = position.min(block.len() as u64) as usize;
        position -= count as u64;
        file.seek(SeekFrom::Start(position))?;
        file.read_exact(&mut block[..count])?;
        for (i, &byte) in block[..count].iter().enumerate().rev() {
            let at = position + i as u64;
            if byte != b'\n' && record_end.is_some() && !oversized {
                if line.len() == 1024 * 1024 { oversized = true; } else { line.push(byte); }
            }
            if byte != b'\n' && at != 0 { continue; }
            if let Some(end) = record_end && !oversized {
                line.reverse();
                if let Ok(record) = serde_json::from_slice(&line) && let Some(found) = visit(end, record)? {
                    return Ok(Some(found));
                }
            }
            record_end = Some(at + 1);
            line.clear();
            oversized = false;
        }
    }
    Ok(None)
}

/// Bounded raw JSONL plus normalized assistant text. Never parse a partial last record.
pub fn transcript(path: &Path, offset: Option<u64>) -> Result<Value> {
    let mut f = fs::File::open(path)?;
    let len = f.metadata()?.len();
    let start = offset.unwrap_or(len.saturating_sub(128 * 1024)).min(len);
    f.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    (&mut f).take(128 * 1024).read_to_end(&mut bytes)?;
    // A large JSONL record must not leave readers retrying the same offset forever.
    while !bytes.contains(&b'\n') && start + (bytes.len() as u64) < len {
        if bytes.len() >= 1024 * 1024 {
            return Err("Transcript record exceeds the 1 MiB read limit".into());
        }
        (&mut f).take(128 * 1024).read_to_end(&mut bytes)?;
    }
    let end = bytes
        .iter()
        .rposition(|b| *b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    bytes.truncate(end);
    let raw = String::from_utf8_lossy(&bytes).into_owned();
    let mut last = String::new();
    let mut status = "unknown";
    let mut local_turn = Value::Null;
    let mut completion_checkpoint = None;
    let mut position = start;
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        position += line.len() as u64;
        let Ok(v) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if v["type"] == "event_msg" && update_local_turn(&mut local_turn, &v["payload"], position) {
            match local_turn["status"].as_str() {
                Some("inProgress") => status = "busy",
                Some("completed") => {
                    status = "idle";
                    completion_checkpoint = Some(position);
                    if let Some(s) = v["payload"]["last_agent_message"].as_str() {
                        last = s.into();
                    }
                }
                Some("interrupted" | "failed") => status = "idle",
                _ => {}
            }
        }
        // OpenCode v2 exports retain native message records in append-only JSONL.
        if v["type"] == "idle" { status = "idle"; completion_checkpoint = Some(position); }
        if v["type"] == "user" { status = "busy"; }
        if v["type"] == "assistant" {
            last = v["content"].as_array().into_iter().flatten().filter(|p| p["type"] == "text")
                .filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n");
        }
        let msg = if v["type"] == "response_item" {
            &v["payload"]
        } else {
            &v["message"]
        };
        if msg["role"] == "assistant" {
            let text = msg["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|p| p["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
            if !text.is_empty() {
                last = text;
            }
        }
    }
    Ok(
        json!({"text":raw,"last_message":last,"offset":start,"next_offset":start+end as u64,"size":len,"status":status,"completion_checkpoint":completion_checkpoint}),
    )
}

pub fn send_claude(target: &Value, text: &str, event_id: &str) -> Result<Value> {
    let pid = integer(&target["pid"]).ok_or("Claude PID missing")?;
    let p = crate::sessions::process(pid)?;
    if target["started"].as_str() != Some(&p.started) {
        return Err("Claude process changed".into());
    }
    let path = target["socket_path"]
        .as_str()
        .ok_or("Claude has no messaging socket")?;
    #[cfg(unix)]
    let meta = fs::symlink_metadata(path)?;
    #[cfg(unix)]
    if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
        return Err("Invalid Claude socket owner/type".into());
    }
    // Claude hashes path.resolve(), not realpath(): /tmp and /private/tmp differ.
    if !Path::new(path).is_absolute()
        || Path::new(path)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err("Claude socket path is not absolute and normalized".into());
    }
    #[cfg(windows)]
    if !path.starts_with(r"\\.\pipe\") {
        return Err("Claude messaging endpoint must be a local named pipe".into());
    }
    let hash = claude_endpoint_hash(path)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let dir = Path::new(
        target["registry_dir"]
            .as_str()
            .ok_or("Claude registry unavailable")?,
    );
    let key_path = dir.join(format!("{pid}.{hash}.key"));
    let key_meta = fs::symlink_metadata(&key_path)?;
    if !key_meta.is_file() { return Err("Invalid Claude key file".into()); }
    #[cfg(unix)]
    if key_meta.uid() != meta.uid() || key_meta.mode() & 0o077 != 0 {
        return Err("Invalid Claude key file".into());
    }
    let key = read_json(&key_path).ok_or("Claude key unavailable")?;
    let token = key["peerToken"]
        .as_str()
        .ok_or("Claude peer token unavailable")?;
    let (auth, message) = claude_frames(token, event_id, text)?;
    #[cfg(unix)]
    let mut stream = UnixStream::connect(path)?;
    #[cfg(windows)]
    let mut stream = {
        let pipe = graffitty_session_transport::BlockingStream::connect(&format!("ipc://{path}"))?;
        if i64::from(pipe.server_process_id()?) != pid {
            return Err("Claude pipe process mismatch".into());
        }
        pipe
    };
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    #[cfg(unix)]
    crate::grow_send_buffer(&stream, auth.len() + message.len() + 2);
    #[cfg(target_os = "macos")]
    unsafe {
        use std::os::fd::AsRawFd;
        let mut peer: libc::pid_t = 0;
        let mut size = std::mem::size_of_val(&peer) as libc::socklen_t;
        if libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut peer as *mut libc::pid_t).cast(),
            &mut size,
        ) != 0
            || i64::from(peer) != pid
        {
            return Err("Claude socket process mismatch".into());
        }
    }
    writeln!(stream, "{auth}")?;
    writeln!(stream, "{message}")?;
    #[cfg(unix)]
    stream.shutdown(std::net::Shutdown::Write)?;
    // This protocol acknowledges asynchronously; don't claim model execution.
    Ok(json!({"status":"submitted","transport":"claude_socket"}))
}
fn claude_endpoint_hash(path: &str) -> [u8; 32] {
    // Claude's Windows registry hashes the case-insensitive pipe identity.
    #[cfg(windows)]
    let path = path.to_lowercase();
    Sha256::digest(path.as_bytes()).into()
}
/// Claude's inbox drops a connection once its buffered input exceeds 1,048,576
/// UTF-16 units, auth line included, after our write has already succeeded.
fn claude_frames(token: &str, event_id: &str, text: &str) -> Result<(String, String)> {
    let auth = json!({"type":"auth","token":token}).to_string();
    let message = json!({"type":"user","msg_id":event_id,"message":{"role":"user","content":text},"priority":"next"}).to_string();
    if auth.encode_utf16().count() + message.encode_utf16().count() + 2 > 1_048_576 {
        return Err("Message exceeds Claude's 1 MiB inbox limit; save long content to a file and send its path".into());
    }
    Ok((auth, message))
}
pub fn worker(request: &str) -> Result<Value> {
    // Delivery requests carry whole messages, bounded by the workspace socket.
    let v = read_json_up_to(Path::new(request), crate::MAX_MESSAGE).ok_or("Invalid worker request")?;
    match v["op"].as_str().unwrap_or("") {
        "scan" => Ok(scan(&v["roots"])),
        "codex_queue_status" => crate::codex_transport::queue_status(&v["target"]),
        "codex_cancel" => crate::codex_transport::cancel_queue(
            &v["target"], v["submission_id"].as_str().ok_or("Missing submission ID")?,
        ),
        "codex_queue" => crate::codex_transport::queue(
            &v["target"], v["text"].as_str().ok_or("Missing text")?,
            v["event_id"].as_str().ok_or("Missing event ID")?,
        ),
        "codex_completion" => codex_completion_response(
            Path::new(v["path"].as_str().ok_or("Missing transcript path")?), &v["target"],
        ),
        "read" => transcript(
            Path::new(v["path"].as_str().ok_or("Missing transcript path")?),
            integer(&v["offset"]).and_then(|n| u64::try_from(n).ok()),
        ),
        "claude_send" => send_claude(
            &v["target"],
            v["text"].as_str().ok_or("Missing text")?,
            v["event_id"].as_str().ok_or("Missing event ID")?,
        ),
        _ => Err("Unknown worker operation".into()),
    }
}

#[cfg(test)]
mod claude_send_tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn windows_claude_uses_authenticated_named_pipe_and_case_normalized_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = format!(r"\\.\pipe\LOCAL\cc-msg-test-{}", uuid::Uuid::new_v4());
        let listener = graffitty_session_transport::bind(Path::new(&path)).unwrap();
        let peer = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut stream = loop {
                match graffitty_session_transport::accept(&listener) {
                    Ok(stream) => break stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && std::time::Instant::now() < deadline =>
                        std::thread::sleep(Duration::from_millis(1)),
                    Err(e) => panic!("{e}"),
                }
            };
            let mut bytes = Vec::new();
            while bytes.iter().filter(|b| **b == b'\n').count() < 2 {
                assert!(std::time::Instant::now() < deadline, "Claude pipe message timed out");
                let mut buffer = [0; 4096];
                match stream.read(&mut buffer) {
                    Ok(count) if count > 0 => bytes.extend_from_slice(&buffer[..count]),
                    Ok(_) => std::thread::sleep(Duration::from_millis(1)),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock =>
                        std::thread::sleep(Duration::from_millis(1)),
                    Err(e) => panic!("{e}"),
                }
            }
            String::from_utf8(bytes).unwrap()
        });
        let pid = i64::from(std::process::id());
        let table = crate::sessions::processes();
        let hash = Sha256::digest(path.to_lowercase().as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>();
        fs::write(directory.path().join(format!("{pid}.{hash}.key")), r#"{"peerToken":"fixture-only-token"}"#).unwrap();
        let target = json!({"pid":pid,"started":table[&pid].started,"socket_path":path,"registry_dir":directory.path()});
        let result = send_claude(&target, "Windows pipe message", "11111111-1111-4111-8111-111111111111").unwrap();
        assert_eq!(result["status"], "submitted");
        let wire = peer.join().unwrap();
        let lines: Vec<Value> = wire.lines().map(|s| serde_json::from_str(s).unwrap()).collect();
        assert_eq!(lines[0], json!({"type":"auth","token":"fixture-only-token"}));
        assert_eq!(lines[1]["message"]["content"], "Windows pipe message");
    }
    #[test]
    fn frames_stop_at_the_claude_inbox_line_limit() {
        let (token, id) = ("0".repeat(32), "11111111-1111-4111-8111-111111111111");
        let (auth, message) = claude_frames(&token, id, "").unwrap();
        let room = 1_048_576 - (auth.len() + message.len() + 2);
        assert!(claude_frames(&token, id, &"x".repeat(room)).is_ok());
        assert!(claude_frames(&token, id, &"x".repeat(room + 1)).is_err());
        // Claude counts JavaScript string length: an emoji is two units.
        assert!(claude_frames(&token, id, &"😀".repeat(room / 2)).is_ok());
        assert!(claude_frames(&token, id, &"😀".repeat(room / 2 + 1)).is_err());
    }
}

#[cfg(test)]
mod codex_discovery_tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn scan_checks_registered_process_outside_the_pane_and_rejects_pid_reuse() {
        let mut child = std::process::Command::new("/bin/sleep").arg("20").spawn().unwrap();
        let pid = i64::from(child.id());
        let started = crate::sessions::process(pid).unwrap().started;
        // An exited pane has no shell root. Its registered agent may still live.
        let roots = |start: &str| json!([{"node":"t1","agent_pid":pid,"started":start}]);
        let live = scan(&roots(&started));
        let reused = scan(&roots("different birth time"));
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(live, json!({}));
        assert_eq!(reused["t1"]["status"], "offline");
        assert_eq!(scan(&roots(&started))["t1"]["status"], "offline");
    }

    #[test]
    fn daemon_read_waits_for_the_matching_record_before_returning_its_offset() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let target = json!({"turn_id":"A","checkpoint":null});
        assert_eq!(codex_completion_response(&path, &target).unwrap()["status"], "awaiting_record");
        let mut file = fs::File::create(&path).unwrap();
        let completed = json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"A","last_agent_message":"Answer A"}});
        write!(file, "{completed}").unwrap();
        assert_eq!(codex_completion_response(&path, &target).unwrap()["status"], "awaiting_record");
        writeln!(file).unwrap();
        let end = file.metadata().unwrap().len();
        writeln!(file, "{}", json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"B"}})).unwrap();
        let output = codex_completion_response(&path, &target).unwrap();
        assert_eq!(output["last_message"], "Answer A");
        assert_eq!(output["completion_checkpoint"], end);
    }

    #[test]
    fn completion_read_tracks_the_selected_turn_across_scanner_yields_and_later_drafts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        let lifecycle = |payload: Value| json!({"type":"event_msg","payload":payload});
        let assistant = |text: &str| json!({"type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":text}]}});
        let event = |kind: &str, id: &str| lifecycle(json!({"type":kind,"turn_id":id}));
        writeln!(file, "{}", event("task_started", "a")).unwrap();
        let baseline = codex_lifecycle(&path, None).unwrap();
        // A spans several transcript preview windows. Its terminal record omits
        // the native ID and embeds no answer, requiring its own assistant item.
        let answer = "a".repeat(128 * 1024 + 1);
        writeln!(file, "{}", assistant(&answer)).unwrap();
        writeln!(file, "{}", json!({"type":"response_item","payload":{"type":"function_call_output","output":"x".repeat(1024*1024)}})).unwrap();
        writeln!(file, "{}", lifecycle(json!({"type":"task_complete"}))).unwrap();
        let checkpoint = file.metadata().unwrap().len();
        writeln!(file, "{}", event("task_started", "b")).unwrap();
        writeln!(file, "{}", assistant("unfinished B")).unwrap();
        let mut completed = baseline;
        for _ in 0..32 {
            completed = scan_rollout(&path, completed.get("observed_turn"), || true).unwrap();
            if completed["observed_turn"]["status"] == "completed" { break; }
        }
        assert_eq!(completed["completion_checkpoint"], checkpoint);
        for target in [json!({"turn_id":"a","checkpoint":checkpoint}), json!({"turn_id":"a"}), json!({"checkpoint":checkpoint})] {
            let output = completed_codex_output(&path, &target).unwrap();
            assert_eq!(output["last_message"], answer);
            assert_eq!(output["completion_checkpoint"], checkpoint);
        }
        assert!(completed_codex_output(&path, &json!({"turn_id":"b","checkpoint":checkpoint})).is_err());
        assert!(completed_codex_output(&path, &json!({"turn_id":"b"})).is_err());
        assert!(completed_codex_output(&path, &json!({"checkpoint":checkpoint - 1})).is_err());
        writeln!(file, "{}", event("task_complete", "b")).unwrap();
        let b = completed_codex_output(&path, &json!({"turn_id":"b"})).unwrap();
        assert_eq!(b["last_message"], "unfinished B");
        assert_eq!(completed_codex_output(&path, &json!({"turn_id":"a"})).unwrap()["last_message"], answer);
    }

    #[test]
    fn rollout_deadlines_advance_past_output_and_preserve_a_partial_failure() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        let start = json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"live"}});
        writeln!(file, "{start}").unwrap();
        let mut observed = codex_lifecycle(&path, None).unwrap()["observed_turn"].clone();
        let start_offset = observed["rollout_offset"].as_u64().unwrap();
        for _ in 0..1000 { writeln!(file, r#"{{"type":"response_item","payload":{{"type":"function_call_output"}}}}"#).unwrap(); }
        let complete_offset = file.metadata().unwrap().len();
        let failure = json!({"type":"event_msg","payload":{"type":"error","message":"Quota exceeded"}});
        write!(file, "{failure}").unwrap();
        let mut polls = 0;
        while observed["rollout_offset"] != complete_offset {
            let mut records = 0;
            let scan = scan_rollout(&path, Some(&observed), || { records += 1; records >= 31 }).unwrap();
            let next = &scan["observed_turn"];
            assert!(next["rollout_offset"].as_u64() > observed["rollout_offset"].as_u64());
            assert_eq!(next["status"], "inProgress");
            observed = next.clone();
            polls += 1;
        }
        assert!(polls > 1 && complete_offset > start_offset);
        assert_eq!(codex_lifecycle(&path, Some(&observed)).unwrap()["observed_turn"], observed);
        writeln!(file).unwrap();
        let failed = codex_lifecycle(&path, Some(&observed)).unwrap();
        assert_eq!(failed["status"], "idle");
        assert_eq!(failed["turn_outcomes"][0]["id"], "live");
        assert_eq!(codex_lifecycle(&path, failed.get("observed_turn")).unwrap()["turn_outcomes"], json!([]));
    }

    #[test]
    fn oversized_unterminated_record_resumes_skipping_until_its_newline() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        let mut scan = codex_lifecycle(&path, None).unwrap();
        file.write_all(&vec![b'x'; 2 * 1024 * 1024]).unwrap();
        let end = file.metadata().unwrap().len();
        while scan["observed_turn"]["rollout_offset"] != end {
            let next = scan_rollout(&path, scan.get("observed_turn"), || true).unwrap();
            assert!(next["observed_turn"]["rollout_offset"].as_u64() > scan["observed_turn"]["rollout_offset"].as_u64());
            assert_eq!(next["observed_turn"]["skip_record"], true);
            scan = next;
        }
        writeln!(file).unwrap();
        writeln!(file, "{}", json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"done"}})).unwrap();
        let done = codex_lifecycle(&path, scan.get("observed_turn")).unwrap();
        assert_eq!(done["observed_turn"]["id"], "done");
        assert!(done["observed_turn"].get("skip_record").is_none());
        assert_eq!(done["completion_checkpoint"], file.metadata().unwrap().len());
    }

    #[test]
    fn timed_out_attachment_resumes_without_replaying_history_or_missing_new_records() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        for payload in [json!({"type":"task_started"}), json!({"type":"error","message":"old"}),
            json!({"type":"task_started","turn_id":"new"})] {
            writeln!(file, "{}", json!({"type":"event_msg","payload":payload})).unwrap();
        }
        let first = scan_rollout(&path, None, || true).unwrap();
        assert!(first.get("observed_turn").is_none());
        writeln!(file, "{}", json!({"type":"event_msg","payload":{"type":"error","message":"new failure"}})).unwrap();
        let second = scan_rollout(&path, first.get("rollout_scan"), || true).unwrap();
        assert!(second["rollout_scan"]["rollout_offset"].as_u64() > first["rollout_scan"]["rollout_offset"].as_u64());
        let attached = scan_rollout(&path, second.get("rollout_scan"), || true).unwrap();
        assert_eq!(attached["observed_turn"]["id"], "new");
        assert_eq!(attached["turn_outcomes"], json!([]));
        let live = scan_rollout(&path, attached.get("observed_turn"), || true).unwrap();
        assert_eq!(live["turn_outcomes"][0]["error"]["message"], "new failure");
    }

    #[test]
    fn first_success_after_a_live_rollout_cursor_is_new_to_discovery() {
        use graffitty_workspace_core::graph::{Graph, discovered_codex_success};
        for interrupted in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("rollout.jsonl");
            let mut file = fs::File::create(&path).unwrap();
            writeln!(file, "{}", json!({"type":"session_meta"})).unwrap();
            if interrupted {
                for event in ["task_started", "turn_aborted"] {
                    writeln!(file, "{}", json!({"type":"event_msg","payload":{"type":event,"turn_id":"previous"}})).unwrap();
                }
            }
            let mut graph = Graph::default();
            graph.add(1, "Codex".into());
            let sample = |baseline: Option<&Value>| {
                let mut node = json!({"provider":"codex","status":"unknown","pid":10,"session_id":"session","transcript_path":path});
                node.as_object_mut().unwrap().extend(codex_lifecycle(&path, baseline).unwrap().as_object().unwrap().clone());
                node
            };
            graph.observe_agent(1, &sample(None));
            let before = graph.nodes["t1"].clone();
            assert_eq!(before["status"], if interrupted { "idle" } else { "unknown" });
            assert!(before["attention"].is_null());
            for event in ["task_started", "task_complete"] {
                writeln!(file, "{}", json!({"type":"event_msg","payload":{"type":event,"turn_id":"first-success"}})).unwrap();
            }
            graph.observe_agent(1, &sample(before.get("observed_turn")));
            let after = &graph.nodes["t1"];
            assert_eq!(after["attention"]["kind"], "completed");
            assert!(discovered_codex_success(&before, after));
            assert!(!discovered_codex_success(after, after));
        }
    }

    #[test]
    fn long_turn_recovers_status_and_original_time_outside_the_preview_tail() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("rollout.jsonl");
        let started = json!({"timestamp":"2026-11-22T10:00:00Z", "type":"event_msg", "payload":{"type":"task_started"}});
        let output = json!({"type":"response_item", "payload":{"type":"function_call_output", "output":"x".repeat(2 * 1024 * 1024)}});
        fs::write(&path, format!("{started}\n{output}\n{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\"}}}}\n")).unwrap();
        assert_eq!(transcript(&path, None).unwrap()["status"], "unknown", "The text preview contains no lifecycle event");
        assert_eq!(codex_lifecycle(&path, None).unwrap()["status_at"], "2026-11-22T10:00:00Z");
        let stopped = json!({"timestamp":"2026-11-22T19:00:00+09:00", "type":"event_msg", "payload":{"type":"task_complete"}});
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        write!(file, "{stopped}\n{output}\n{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_started\"}}}}").unwrap();
        assert_eq!(codex_lifecycle(&path, None).unwrap()["status_at"], "2026-11-22T19:00:00+09:00", "An incomplete trailing record cannot start another turn");
    }

    #[test]
    fn completed_record_checkpoint_ignores_later_metadata_and_partial_lines() {
        let path = std::env::temp_dir().join(format!("graffitty-completion-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(&path, "{\"type\":\"session_meta\"}\n").unwrap();
        assert_eq!(completed_checkpoint(&transcript(&path, None).unwrap()), Some(0));
        assert_eq!(completed_checkpoint(&json!({"status":"unknown","offset":100})), None);
        let completed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"빠른 응답\"}}\n";
        fs::write(&path, completed).unwrap();
        let first = transcript(&path, None).unwrap();
        assert_eq!(first["completion_checkpoint"], completed.len() as u64);
        fs::write(&path, format!("{completed}{{\"type\":\"token_count\"}}\n{{\"partial\":" )).unwrap();
        let later = transcript(&path, None).unwrap();
        assert_eq!(later["completion_checkpoint"], first["completion_checkpoint"]);
        assert_eq!(later["last_message"], "빠른 응답");
        // A bounded tail may begin inside a multibyte character. Checkpoints
        // must still count file bytes, not replacement characters in raw text.
        fs::write(&path, format!("한글\n{completed}")).unwrap();
        let tail = transcript(&path, Some(1)).unwrap();
        assert_eq!(tail["completion_checkpoint"], ("한글\n".len() + completed.len()) as u64);
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn local_scan_keeps_every_success_before_a_later_turn_starts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        let mut append = |event: Value| writeln!(file, "{}", json!({"type":"event_msg","payload":event})).unwrap();
        append(json!({"type":"task_started","turn_id":"a"}));
        let before = codex_lifecycle(&path, None).unwrap();
        assert_eq!(before["turn_outcomes"], json!([]));
        for turn in ["a","b"] {
            if turn != "a" { append(json!({"type":"task_started","turn_id":turn})); }
            append(json!({"type":"task_complete","turn_id":turn,"last_agent_message":format!("Answer {turn}")}));
        }
        let idle = codex_lifecycle(&path, before.get("observed_turn")).unwrap();
        assert_eq!(idle["status"], "idle");
        append(json!({"type":"task_started","turn_id":"c"}));
        let after = codex_lifecycle(&path, before.get("observed_turn")).unwrap();
        assert_eq!(after["status"], "busy");
        assert_eq!(idle["turn_outcomes"], after["turn_outcomes"]);
        let successes = after["turn_outcomes"].as_array().unwrap();
        assert_eq!(successes.len(), 2);
        for (turn, result) in ["a","b"].into_iter().zip(successes) {
            assert_eq!(result["id"], turn);
            let read = codex_completion_response(&path, &json!({"turn_id":turn,"checkpoint":result["completion_checkpoint"]})).unwrap();
            assert_eq!(read["last_message"], format!("Answer {turn}"));
            assert_eq!(read["completion_checkpoint"], result["completion_checkpoint"]);
        }
        assert_eq!(codex_lifecycle(&path, after.get("observed_turn")).unwrap()["turn_outcomes"], json!([]));
        assert_eq!(codex_lifecycle(&path, None).unwrap()["turn_outcomes"], json!([]));
    }

    #[test]
    fn local_codex_quota_failures_survive_fast_retries_without_success_checkpoints() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join("sessions");
        fs::create_dir(&sessions).unwrap();
        let id = "11111111-1111-4111-8111-111111111111";
        let path = sessions.join(format!("rollout-test-{id}.jsonl"));
        let mut file = fs::File::create(&path).unwrap();
        writeln!(file, "{}", json!({"type":"session_meta","payload":{"id":id}})).unwrap();
        let scan = |before: &Value| codex_files(std::slice::from_ref(&path), before);
        let append = |file: &mut fs::File, payload: Value| {
            writeln!(file, "{}", json!({"type":"event_msg","payload":payload})).unwrap();
        };
        let failure = |turn: &str| json!({"type":"task_complete","turn_id":turn,
            "error":{"message":"Quota exceeded","codex_error_info":"usage_limit_exceeded"}});
        let start = |turn: &str| json!({"type":"task_started","turn_id":turn});
        let baseline = scan(&Value::Null);
        append(&mut file, start("a"));
        append(&mut file, failure("a"));
        let first = scan(&baseline);
        assert_eq!(first["status"], "idle");
        assert_eq!(first["observed_turn"]["status"], "failed");
        assert_eq!(first["turn_outcomes"][0]["error"]["message"], "Quota exceeded");
        assert!(completed_checkpoint(&transcript(&path, None).unwrap()).is_none());
        append(&mut file, start("b"));
        append(&mut file, failure("b"));
        append(&mut file, start("c"));
        let retry = scan(&first);
        assert_eq!(retry["status"], "busy");
        assert_eq!(retry["turn_outcomes"].as_array().unwrap().len(), 1);
        assert_eq!(retry["turn_outcomes"][0]["id"], "b");
        assert_eq!(scan(&retry)["turn_outcomes"], json!([]));
        append(&mut file, json!({"type":"task_complete","turn_id":"c","last_agent_message":"Done"}));
        let done = scan(&retry);
        assert_eq!(done["observed_turn"]["status"], "completed");
        let tail = transcript(&path, None).unwrap();
        assert_eq!(tail["last_message"], "Done");
        assert_eq!(completed_checkpoint(&tail), Some(file.metadata().unwrap().len()));
    }

    #[test]
    fn local_codex_rollout_preserves_standalone_errors_interrupts_and_unknown_outcomes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        let mut append = |payload: Value| writeln!(file, "{}", json!({"type":"event_msg","payload":payload})).unwrap();
        append(json!({"type":"task_started","turn_id":"a"}));
        append(json!({"type":"token_count","rate_limits":{"primary":{"used_percent":100.0}}}));
        let baseline = codex_lifecycle(&path, None).unwrap();
        assert_eq!(baseline["status"], "busy", "a token count says nothing about the outcome");
        append(json!({"type":"error","message":"Out of credits","codex_error_info":"usage_limit_exceeded"}));
        append(json!({"type":"task_complete","turn_id":"a"}));
        let failed = codex_lifecycle(&path, baseline.get("observed_turn")).unwrap();
        assert_eq!(failed["observed_turn"]["status"], "failed");
        assert_eq!(failed["turn_outcomes"].as_array().unwrap().len(), 1);
        assert!(completed_checkpoint(&transcript(&path, None).unwrap()).is_none());
        let reattached = codex_lifecycle(&path, None).unwrap();
        assert_eq!(reattached["observed_turn"]["status"], "failed");
        assert_eq!(reattached["turn_outcomes"], json!([]));
        append(json!({"type":"task_started","turn_id":"b"}));
        append(json!({"type":"stream_error","message":"retrying"}));
        append(json!({"type":"turn_aborted","turn_id":"b","reason":"interrupted"}));
        let aborted = codex_lifecycle(&path, failed.get("observed_turn")).unwrap();
        assert_eq!(aborted["status"], "idle");
        assert_eq!(aborted["observed_turn"]["status"], "interrupted");
        assert_eq!(aborted["turn_outcomes"], json!([]));
    }

    #[test]
    fn lock_identifies_thread_before_transcript_exists() {
        let id = "11111111-1111-4111-8111-111111111111";
        let v = codex_files(&[PathBuf::from(format!("/custom/codex/thread-writer-locks/{id}.lock"))], &Value::Null);
        assert_eq!(v["session_id"], id);
        assert_eq!(v["provider_home"], "/custom/codex");
        assert!(v.get("transcript_path").is_none());
        assert!(v["queue_error"].as_str().unwrap().contains("no external queue endpoint"));
    }
    #[test]
    fn multiple_threads_and_missing_evidence_never_guess() {
        for paths in [vec![], vec![
            PathBuf::from("/x/thread-writer-locks/11111111-1111-4111-8111-111111111111.lock"),
            PathBuf::from("/x/thread-writer-locks/22222222-2222-4222-8222-222222222222.lock"),
        ], vec![PathBuf::from("/x/thread-writer-locks/not-a-thread.lock")]] {
            let v = codex_files(&paths, &Value::Null);
            assert!(v.get("session_id").is_none());
            assert!(v["discovery_note"].is_string());
        }
    }
    #[test]
    fn subagent_rollouts_and_locks_do_not_hide_the_main_thread() {
        let dir = std::env::temp_dir().join(format!("graffitty-subagents-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("sessions")).unwrap();
        let main = "11111111-1111-4111-8111-111111111111";
        let child = "22222222-2222-4222-8222-222222222222";
        let mut paths = vec![];
        for (id, source) in [(main, json!("cli")), (child, json!({"subagent":{"thread_spawn":{"parent_thread_id":main}}}))] {
            let path = dir.join(format!("sessions/rollout-test-{id}.jsonl"));
            fs::write(&path, format!("{}\n", json!({"type":"session_meta","payload":{"id":id,"source":source}}))).unwrap();
            paths.extend([dir.join(format!("thread-writer-locks/{id}.lock")), path]);
        }
        for _ in 0..2 {
            assert_eq!(codex_files(&paths, &Value::Null)["session_id"], main);
            paths.reverse();
        }
        let child_paths: Vec<_> = paths.into_iter().filter(|p| p.to_string_lossy().contains(child)).collect();
        assert!(codex_files(&child_paths, &Value::Null).get("session_id").is_none());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rollout_and_lock_agree_and_status_comes_from_events() {
        let dir = std::env::temp_dir().join(format!("graffitty-discovery-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("sessions/2026/09/30")).unwrap();
        let id = "11111111-1111-4111-8111-111111111111";
        let path = dir.join(format!("sessions/2026/09/30/rollout-test-{id}.jsonl"));
        fs::write(&path, format!("{}\n{}\n{}\n", json!({"type":"session_meta","payload":{"id":id}}),
            json!({"type":"event_msg","payload":{"type":"task_started"}}),
            json!({"type":"event_msg","payload":{"type":"task_complete"}}))).unwrap();
        let v = codex_files(&[path.clone(), dir.join(format!("thread-writer-locks/{id}.lock"))], &Value::Null);
        assert_eq!(v["session_id"], id);
        assert_eq!(v["status"], "idle");
        assert_eq!(v["transcript_path"], json!(path));
        fs::remove_dir_all(dir).unwrap();
    }
}
