//! Queue delivery to verified existing Codex sessions. Never launches or rewrites Codex.
use crate::agent_bridge::Result;
use graffitty_protocol::{CodexCancelOutcome, CodexQueueStatus};
use serde_json::{Value, json};
use std::path::Path;

/// Submit through Codex's native queue; never read or modify the terminal composer.
pub fn queue(target: &Value, text: &str, event_id: &str) -> Result<Value> {
    queue_request(target, "thread/queue/add", json!({"input":[{"type":"text","text":text,"text_elements":[]}],"clientUserMessageId":uuid::Uuid::parse_str(event_id)?.to_string()}))
}

pub fn cancel_queue(target: &Value, submission_id: &str) -> Result<Value> {
    let deletion = queue_request(target, "thread/queue/delete", json!({"queuedSubmissionId":submission_id}));
    match &deletion {
        Ok(reply) if reply["deleted"] == true => return Ok(json!(CodexCancelOutcome::Deleted)),
        Ok(reply) if reply["deleted"] == false => return Ok(json!(CodexCancelOutcome::Absent)),
        Err(error) if error.is::<ProcessEnded>() => return Ok(json!(CodexCancelOutcome::ProcessEnded)),
        _ => {}
    }
    // A lost reply can follow an effective delete. Only a complete queue
    // listing for this same verified target can establish absence.
    match queued_ids(target) {
        Ok(ids) if ids.iter().all(|id| id != submission_id) => return Ok(json!(CodexCancelOutcome::Absent)),
        Err(error) if error.is::<ProcessEnded>() => return Ok(json!(CodexCancelOutcome::ProcessEnded)),
        _ => {}
    }
    deletion.and_then(|_| Err("Codex did not confirm queue deletion".into()))
}

pub fn queue_status(target: &Value) -> Result<Value> {
    match queued_ids(target) {
        Ok(queued_ids) => Ok(json!(CodexQueueStatus::Listed { queued_ids })),
        Err(error) if error.is::<ProcessEnded>() => Ok(json!(CodexQueueStatus::ProcessEnded)),
        Err(error) => Err(error),
    }
}

/// Return a complete queue snapshot; errors must never be treated as an empty queue.
fn queued_ids(target: &Value) -> Result<Vec<String>> {
    let mut ids = Vec::new();
    let mut cursor = Value::Null;
    let mut seen = std::collections::HashSet::new();
    for _ in 0..128 {
        let page = queue_request(target, "thread/queue/list", json!({"cursor":cursor,"limit":100}))?;
        for item in page["data"].as_array().ok_or("Invalid Codex queue response")? {
            ids.push(item["id"].as_str().ok_or("Missing queued submission ID")?.to_owned());
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() { return Ok(ids); }
        let next = cursor.as_str().ok_or("Invalid Codex queue cursor")?;
        if !seen.insert(next.to_owned()) { return Err("Repeated Codex queue cursor".into()); }
    }
    Err("Codex queue snapshot exceeded page limit".into())
}

#[derive(Debug)]
struct ProcessEnded;
impl std::fmt::Display for ProcessEnded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("Original Codex process ended") }
}
impl std::error::Error for ProcessEnded {}

fn definitely_missing(pid: i64, error: &std::io::Error) -> bool {
    #[cfg(unix)]
    {
        // A missing /proc entry or failed process inventory can reflect access
        // restrictions. Confirm PID absence directly without sending a signal.
        (error.kind() == std::io::ErrorKind::NotFound || error.raw_os_error() == Some(libc::ESRCH))
            && unsafe { libc::kill(pid as libc::pid_t, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }
    #[cfg(windows)]
    {
        let _ = pid;
        // process() maps an exited PID or a confirmed process exit to NotFound.
        error.kind() == std::io::ErrorKind::NotFound
    }
}

fn verified_owner(target: &Value) -> Result<crate::sessions::Process> {
    let pid = target["pid"].as_f64().filter(|n| n.fract() == 0.0 && *n > 0.0 && *n <= i32::MAX as f64)
        .ok_or("Invalid Codex PID")? as i64;
    let birth = target["started"].as_str().filter(|s| !s.is_empty()).ok_or("Codex process start time missing")?;
    match crate::sessions::process(pid) {
        Ok(owner) if owner.pid != pid || owner.started.is_empty() => Err("Could not verify Codex process identity".into()),
        Ok(owner) if owner.started != birth || owner.state == "Z" => Err(ProcessEnded.into()),
        Ok(owner) => Ok(owner),
        Err(e) if definitely_missing(pid, &e) => Err(ProcessEnded.into()),
        Err(e) => Err(e.into()),
    }
}

fn queue_request(target: &Value, method: &str, mut params: Value) -> Result<Value> {
    #[cfg(unix)]
    use std::os::unix::net::UnixStream;
    #[cfg(windows)]
    use uds_windows::UnixStream;
    use tungstenite::Message;
    let thread = target["session_id"].as_str().ok_or("Codex thread not resolved from process evidence")?;
    uuid::Uuid::parse_str(thread)?;
    let owner = verified_owner(target)?;
    if target["discovery_transport"] == "codex_tui_listener" {
        let home = Path::new(target["provider_home"].as_str().ok_or("Codex home missing")?);
        let mut rpc = crate::codex_discovery::verify(target, home, owner.pid)?;
        params["threadId"] = json!(thread);
        return rpc.call(method, params);
    }
    let endpoint = {
        if let Some(reason) = target["queue_error"].as_str() { return Err(reason.into()); }
        if target["integrated"] != true {
            return Err("Codex thread has no verified queue binding; no message was sent".into());
        }
        let home = Path::new(target["provider_home"].as_str().ok_or("Codex home not discovered")?);
        let owned_lock = home.join("thread-writer-locks").join(format!("{thread}.lock"));
        if crate::sessions::open_paths(owner.pid).contains(&owned_lock) {
            return Err("Codex --no-daemon has no external queue endpoint; no message was sent".into());
        }
        home.join("app-server-control/app-server-control.sock")
    };
    // Connect only to an existing server. Never start/resume a second writer.
    let stream = UnixStream::connect(endpoint)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(std::time::Duration::from_secs(5)))?;
    let (mut client, _) = tungstenite::client("ws://localhost/", stream)?;
    params["threadId"] = json!(thread);
    for request in [
        json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"graffitty","version":env!("GRAFFITTY_VERSION")},"capabilities":{"experimentalApi":true}}}),
        json!({"id":2,"method":method,"params":params}),
    ] {
        client.send(Message::Text(request.to_string().into()))?;
        loop {
            if let Message::Text(text) = client.read()? {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"] == request["id"] {
                    if response.get("error").is_some() { return Err(response["error"].to_string().into()); }
                    if request["id"] == 2 { return Ok(response["result"].clone()); }
                    client.send(Message::Text(json!({"method":"initialized"}).to_string().into()))?;
                    break;
                }
            }
        }
    }
    Err("Codex queue did not respond".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io, process::{Command, Stdio}};

    #[test]
    fn cancellation_distinguishes_retired_processes_from_unavailable_identity_evidence() {
        let pid = i64::from(std::process::id());
        let current = crate::sessions::process(pid).unwrap();
        let mut target = json!({"session_id":uuid::Uuid::new_v4().to_string(),"pid":pid,"started":current.started});
        assert!(verified_owner(&target).is_ok());
        assert!(!definitely_missing(pid, &io::ErrorKind::PermissionDenied.into()));
        #[cfg(unix)]
        assert!(!definitely_missing(pid, &io::ErrorKind::NotFound.into()), "hidden process metadata cannot prove exit");
        target["started"] = Value::Null;
        assert!(cancel_queue(&target, "submission").is_err());
        target["started"] = json!("different birth");
        assert_eq!(queue_status(&target).unwrap(), json!(CodexQueueStatus::ProcessEnded));
        assert_eq!(cancel_queue(&target, "submission").unwrap(), json!(CodexCancelOutcome::ProcessEnded));
        let mut child = Command::new(std::env::current_exe().unwrap()).arg("--list")
            .stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        target["pid"] = json!(child.id());
        child.wait().unwrap();
        assert_eq!(cancel_queue(&target, "submission").unwrap(), json!(CodexCancelOutcome::ProcessEnded));
    }
}
