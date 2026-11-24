//! Native queue worker results retain the original event, receiver and provider target.
use crate::{graph::Graph, pane_address};
use graffitty_protocol::{CodexCancelOutcome, CodexQueueStatus};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

pub(super) struct Submission {
    pub record: Value,
    pub cancelling: bool,
    process_ended: bool,
    retry_at: Option<Instant>,
    retry_delay: Duration,
}

type Pending = HashMap<String, Submission>;

const CAPACITY: usize = 1024;
pub(super) fn has_capacity(pending: &Pending) -> bool { pending.len() < CAPACITY }

pub(super) fn prompt_started(submission: &Submission, id: u64, params: &Value) -> bool {
    let record = &submission.record;
    let target = &record["target"];
    record["id"] == id && params["prompt"] == record["text"]
        && params["session_id"].is_string() && params["session_id"] == target["session_id"]
        && ["pid", "started"].iter().all(|field| params[*field].is_null() || params[*field] == target[*field])
}

pub(super) fn move_record(record: &mut Value, source: &str, target: &str, moved: &HashSet<u64>) {
    if record["workspace"] == source && record["id"].as_u64().is_some_and(|id| moved.contains(&id)) {
        record["workspace"] = json!(target);
    }
}

pub(super) fn allowed(graph: &Graph, record: &Value) -> bool {
    let event = &record["event"];
    event["target"].as_str().is_some_and(|key| graph.nodes.contains_key(key)
        && record["inbox_generation"] == graph.inbox_generation(key)) && graph.allowed(event)
}

pub(super) fn cancellations(pending: &mut Pending, graphs: &HashMap<String, Graph>) -> Vec<(String, Value)> {
    cancellations_at(pending, graphs, Instant::now())
}

fn cancellations_at(pending: &mut Pending, graphs: &HashMap<String, Graph>, now: Instant) -> Vec<(String, Value)> {
    let mut revoked = Vec::new();
    pending.retain(|id, submission| {
        if submission.cancelling || submission.retry_at.is_some_and(|deadline| now < deadline) { return true; }
        let record = &submission.record;
        if submission.retry_at.is_none() && let Some(graph) = graphs.get(record["workspace"].as_str().unwrap_or(""))
            && allowed(graph, record) {
            return graph.native_pending(id);
        }
        revoked.push((id.clone(), record.clone()));
        true
    });
    revoked
}

pub(super) fn finish_submit(pending: &mut Pending, graphs: &mut HashMap<String, Graph>,
    mut record: Value, result: &Value) {
    let id = record["id"].as_u64().unwrap_or(0);
    let event_id = record["event"]["event_id"].clone();
    let graph = graphs.get_mut(record["workspace"].as_str().unwrap_or(""));
    let authorized = graph.filter(|g| allowed(g, &record)
        && g.queues.get(&pane_address(id)).is_some_and(|q| q.iter().any(|e| e["event_id"] == event_id)));
    let submission = result["queuedSubmission"]["id"].as_str();
    if let Some(submission) = submission {
        // Even a late acceptance of a revoked event needs its original target for cancellation.
        record["submission_id"] = json!(submission);
        pending.insert(event_id.as_str().unwrap_or("").to_owned(), Submission {
            record, cancelling: false, process_ended: false, retry_at: None, retry_delay: Duration::from_secs(1),
        });
    }
    if let Some(graph) = authorized {
        let status = if result.get("error").is_some() {
            format!("failed: {}", result["error"]["message"].as_str().unwrap_or("delivery failed"))
        } else if submission.is_some() { "queued in Codex".into() } else { "submitted".into() };
        let _ = graph.dispatch(id, "graph.ack", &json!({"event_id":event_id,"status":status}));
    }
}

pub(super) fn finish_poll(pending: &mut Pending, graphs: &mut HashMap<String, Graph>,
    context: &Value, result: &Value) {
    let Ok(status) = serde_json::from_value::<CodexQueueStatus>(result.clone()) else { return; };
    if result.get("error").is_some() { return; }
    for sampled in context["records"].as_array().into_iter().flatten() {
        let Some(id) = sampled["event"]["event_id"].as_str() else { continue; };
        let Some(submission) = pending.get_mut(id) else { continue; };
        let current = &submission.record;
        if current["submission_id"] != sampled["submission_id"] { continue; }
        // An earlier queue poll may finish while the delete RPC is still
        // running. Its process observation cannot settle the provider's reply.
        if submission.cancelling {
            if status == CodexQueueStatus::ProcessEnded { submission.process_ended = true; }
            continue;
        }
        let graph = graphs.get_mut(current["workspace"].as_str().unwrap_or(""));
        let final_status = match &status {
            CodexQueueStatus::Listed { queued_ids } => {
                if queued_ids.iter().any(|id| current["submission_id"] == *id)
                    || !graph.as_deref().is_some_and(|g| allowed(g, current)) { continue; }
                "started or removed in Codex"
            }
            CodexQueueStatus::ProcessEnded if submission.retry_at.is_some()
                || !graph.as_deref().is_some_and(|g| allowed(g, current)) =>
                "cancellation unconfirmed: original Codex process ended",
            CodexQueueStatus::ProcessEnded => "delivery unconfirmed: original Codex process ended",
        };
        if let Some(graph) = graph { graph.record_delivery(&current["event"], final_status, false); }
        pending.remove(id);
    }
}

pub(super) fn finish_cancel(pending: &mut Pending, graphs: &mut HashMap<String, Graph>, record: &Value, result: &Value) {
    let Some(id) = record["event"]["event_id"].as_str() else { return; };
    let Some(submission) = pending.get_mut(id) else { return; };
    if submission.record["submission_id"] != record["submission_id"] { return; }
    let graph = graphs.get_mut(submission.record["workspace"].as_str().unwrap_or(""));
    let outcome = serde_json::from_value::<CodexCancelOutcome>(result.clone()).ok()
        .filter(|_| result.get("error").is_none())
        .or_else(|| submission.process_ended.then_some(CodexCancelOutcome::ProcessEnded));
    let status = match outcome {
        Some(CodexCancelOutcome::Deleted) => "cancelled in Codex".to_owned(),
        Some(CodexCancelOutcome::Absent) => "already started or removed in Codex; cannot recall".to_owned(),
        Some(CodexCancelOutcome::ProcessEnded) => "cancellation unconfirmed: original Codex process ended".to_owned(),
        None => {
            submission.cancelling = false;
            submission.retry_at = Some(Instant::now() + submission.retry_delay);
            submission.retry_delay = (submission.retry_delay * 2).min(Duration::from_secs(30));
            format!("cancellation pending: {}", result["error"]["message"].as_str().unwrap_or("unconfirmed queue response"))
        }
    };
    if let Some(graph) = graph { graph.record_delivery(&record["event"], &status, outcome.is_none()); }
    if outcome.is_some() { pending.remove(id); }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_reply_settles_the_submission_when_a_process_exit_poll_races_it() {
        for poll_first in [false, true] {
            for (reply, expected) in [
                (json!(CodexCancelOutcome::Deleted), "cancelled in Codex"),
                (json!(CodexCancelOutcome::Absent), "already started or removed in Codex; cannot recall"),
                (json!(CodexCancelOutcome::Absent), "sent to receiver"),
                (json!(CodexCancelOutcome::ProcessEnded), "cancellation unconfirmed: original Codex process ended"),
                (json!({"error":{"message":"lost reply"}}), "cancellation unconfirmed: original Codex process ended"),
            ] {
                let mut graph = Graph::default();
                for id in [1,2] {
                    graph.add(id, "Agent".into());
                    graph.dispatch(id, "agent.event", &json!({"provider":"codex","event":"SessionStart","pid":id,"session_id":format!("s{id}")})).unwrap();
                }
                let wire = graph.dispatch(1, "graph.connect", &json!({"from":"t1","to":"t2","send":true})).unwrap();
                graph.dispatch(1, "graph.send", &json!({"to":"t2","text":"test"})).unwrap();
                let event = graph.queues["t2"][0].clone();
                let id = event["event_id"].as_str().unwrap();
                let record = json!({"workspace":"one","id":2,"target":graph.nodes["t2"],"event":event,"inbox_generation":graph.inbox_generation("t2"),"text":graph.delivery_prompt(&event)});
                let mut graphs = HashMap::from([("one".into(), graph)]);
                let mut pending = HashMap::new();
                finish_submit(&mut pending, &mut graphs, record, &json!({"queuedSubmission":{"id":"sub-A"}}));
                let poll = json!({"records":[pending[id].record]});
                graphs.get_mut("one").unwrap().dispatch(1, "graph.disconnect", &wire).unwrap();
                let cancel = cancellations(&mut pending, &graphs).pop().unwrap().1;
                pending.get_mut(id).unwrap().cancelling = true;
                let gone = json!(CodexQueueStatus::ProcessEnded);
                if poll_first {
                    finish_poll(&mut pending, &mut graphs, &poll, &gone);
                    assert!(pending[id].cancelling);
                    assert!(cancellations(&mut pending, &graphs).is_empty());
                }
                // The receiver can move again after either worker launched.
                let moved = HashSet::from([1,2]);
                let mut destination = Graph::default();
                graphs.get_mut("one").unwrap().transfer_nodes_to(&moved, &mut destination);
                graphs.insert("two".into(), destination);
                move_record(&mut pending.get_mut(id).unwrap().record, "one", "two", &moved);
                if expected == "sent to receiver" {
                    let hook = json!({"provider":"codex","event":"UserPromptSubmit","session_id":"s2","pid":2,"prompt":cancel["text"]});
                    pending.retain(|_, submission| !prompt_started(submission, 2, &hook));
                    graphs.get_mut("two").unwrap().dispatch(2, "agent.event", &hook).unwrap();
                }
                finish_cancel(&mut pending, &mut graphs, &cancel, &reply);
                if !poll_first { finish_poll(&mut pending, &mut graphs, &poll, &gone); }
                assert!(pending.is_empty());
                assert_eq!(graphs["two"].snapshot()["journal"]["events"][0]["status"], expected, "{poll_first} / {reply}");
            }
        }
    }

    #[test]
    fn retired_process_releases_native_admission_with_unconfirmed_provider_outcome() {
        let mut graph = Graph::default();
        graph.add(1, "Old receiver".into());
        let mut graphs = HashMap::from([("one".into(), graph)]);
        let mut pending = HashMap::new();
        for index in 0..CAPACITY {
            let id = format!("event-{index}");
            let record = json!({"id":1,"workspace":"one","event":{"event_id":id,"source":"t0","source_port":"send","target":"t1","target_port":"in","edge_revision":1,"type":"message"}});
            finish_submit(&mut pending, &mut graphs, record, &json!({"queuedSubmission":{"id":format!("old-{index}")}}));
        }
        assert!(!has_capacity(&pending));
        for (_, record) in cancellations(&mut pending, &graphs) {
            finish_cancel(&mut pending, &mut graphs, &record, &json!(CodexCancelOutcome::ProcessEnded));
        }
        assert!(pending.is_empty() && cancellations(&mut pending, &graphs).is_empty());
        assert!(has_capacity(&pending));
        let journal = graphs["one"].snapshot()["journal"].clone();
        assert_eq!(journal["pending"], 0);
        assert!(journal["events"].as_array().unwrap().iter().all(|row| row["status"] == "cancellation unconfirmed: original Codex process ended"));
        let graph = graphs.get_mut("one").unwrap();
        for id in [2,3] {
            graph.add(id, "Healthy agent".into());
            graph.dispatch(id,"agent.event",&json!({"provider":"codex","event":"SessionStart","pid":id,"session_id":format!("s{id}")})).unwrap();
        }
        graph.dispatch(2, "graph.connect", &json!({"from":"t2","to":"t3","send":true})).unwrap();
        graph.dispatch(2, "graph.send", &json!({"to":"t3","text":"healthy delivery"})).unwrap();
        let event = graph.queues["t3"][0].clone();
        let record = json!({"workspace":"one","id":3,"event":event,"target":graph.nodes["t3"],"inbox_generation":graph.inbox_generation("t3")});
        finish_submit(&mut pending, &mut graphs, record, &json!({"queuedSubmission":{"id":"healthy-submission"}}));
        assert!(graphs["one"].native_pending(event["event_id"].as_str().unwrap()));
        let id = event["event_id"].as_str().unwrap();
        let poll = json!({"records":[pending[id].record]});
        finish_poll(&mut pending, &mut graphs, &poll, &json!({"error":{"message":"permission denied"}}));
        assert!(graphs["one"].native_pending(id));
        finish_poll(&mut pending, &mut graphs, &poll, &json!(CodexQueueStatus::ProcessEnded));
        assert!(pending.is_empty() && !graphs["one"].native_pending(id));
        assert_eq!(graphs["one"].receipts.last().unwrap()["status"], "delivery unconfirmed: original Codex process ended");
    }

    #[test]
    fn revoked_submission_retries_only_its_original_thread_after_binding_returns() {
        for deleted in [true, false] {
            let mut graph = Graph::default();
            for id in [1,2] {
                graph.add(id, "Terminal".into());
                graph.dispatch(id, "agent.event", &json!({"provider":"codex","event":"SessionStart",
                    "pid":id,"started":"birth","session_id":format!("s{id}"),"transport":"native"})).unwrap();
            }
            graph.dispatch(1, "graph.connect", &json!({"from":"t1","from_port":"error","to":"t2"})).unwrap();
            graph.discovered_failure(1, &json!({"id":"turn","error":{"message":"Quota exceeded"}}), "", &graph.outcome_routes(1, true)).unwrap();
            let event = graph.queues["t2"][0].clone();
            let id = event["event_id"].as_str().unwrap();
            let original = json!({"workspace":"one","id":2,"target":graph.nodes["t2"],"event":event,
                "inbox_generation":graph.inbox_generation("t2"),"text":graph.delivery_prompt(&event)});
            let mut graphs = HashMap::from([("one".into(), graph)]);
            let mut pending = HashMap::new();
            finish_submit(&mut pending, &mut graphs, original.clone(), &json!({"queuedSubmission":{"id":"submission-A"}}));
            graphs.get_mut("one").unwrap().observe_agent(2, &json!({"provider":"codex","pid":2,"started":"birth","session_id":"B"}));
            let (_, first) = cancellations(&mut pending, &graphs).pop().unwrap();
            pending.get_mut(id).unwrap().cancelling = true;
            assert!(cancellations(&mut pending, &graphs).is_empty());
            finish_cancel(&mut pending, &mut graphs, &first, &json!({"error":{"message":"Codex frontend thread binding changed"}}));
            assert!(cancellations(&mut pending, &graphs).is_empty());
            for _ in 0..8 {
                let deadline = pending[id].retry_at.unwrap();
                let retry = cancellations_at(&mut pending, &graphs, deadline).pop().unwrap().1;
                assert_eq!(retry["target"], original["target"]);
                pending.get_mut(id).unwrap().cancelling = true;
                finish_cancel(&mut pending, &mut graphs, &retry, &json!({"error":{"message":"binding unavailable"}}));
            }
            assert_eq!(pending[id].retry_delay, Duration::from_secs(30));
            assert!(graphs["one"].receipts.last().unwrap()["status"].as_str().unwrap().starts_with("cancellation pending"));
            graphs.get_mut("one").unwrap().observe_agent(2, &json!({"provider":"codex","pid":2,"started":"birth","session_id":"s2"}));
            let hook = |session: &str| json!({"session_id":session,"pid":2,"started":"birth","prompt":original["text"]});
            assert!(!prompt_started(&pending[id], 2, &hook("B")));
            assert!(prompt_started(&pending[id], 2, &hook("s2")));
            let deadline = pending[id].retry_at.unwrap();
            let retry = cancellations_at(&mut pending, &graphs, deadline).pop().unwrap().1;
            assert_eq!(retry["target"], original["target"]);
            assert_eq!(retry["submission_id"], "submission-A");
            finish_cancel(&mut pending, &mut graphs, &retry, &json!(if deleted { CodexCancelOutcome::Deleted } else { CodexCancelOutcome::Absent }));
            assert!(pending.is_empty());
            assert!(cancellations(&mut pending, &graphs).is_empty());
            assert_eq!(graphs["one"].receipts.last().unwrap()["status"], if deleted {
                "cancelled in Codex" } else { "already started or removed in Codex; cannot recall" });
        }
    }

    #[test]
    fn queued_codex_submission_follows_its_receiver_through_transfer() {
        for scenario in ["acknowledged", "accept_in_flight", "poll_in_flight", "cancel_in_flight",
            "receiver_moves", "sender_moves", "replacement", "accept_after_replacement", "prompt_before_ack"] {
            let mut graph = Graph::default();
            for id in [1,2] {
                graph.add(id, "Terminal".into());
                graph.dispatch(id, "agent.event", &json!({"provider":"codex","event":"SessionStart",
                    "pid":id,"session_id":format!("s{id}"),"transport":"native"})).unwrap();
            }
            let wire = graph.dispatch(1, "graph.connect", &json!({"from":"t1","from_port":"error","to":"t2"})).unwrap();
            let routes = graph.outcome_routes(1, true);
            graph.discovered_failure(1, &json!({"id":"turn","error":{"message":"Quota exceeded"}}), "", &routes).unwrap();
            let event = graph.queues["t2"][0].clone();
            let id = event["event_id"].as_str().unwrap();
            let mut context = json!({"workspace":"one","id":2,"target":graph.nodes["t2"],"event":event,
                "inbox_generation":graph.inbox_generation("t2"),"text":graph.delivery_prompt(&event)});
            let accepted = json!({"queuedSubmission":{"id":"submission-A"}});
            let mut graphs = HashMap::from([("one".into(), graph)]);
            let mut pending = HashMap::new();
            let late = matches!(scenario, "accept_in_flight" | "accept_after_replacement" | "prompt_before_ack");
            if !late {
                finish_submit(&mut pending, &mut graphs, context.clone(), &accepted);
                assert!(graphs["one"].native_pending(id));
            }
            if scenario == "prompt_before_ack" {
                graphs.get_mut("one").unwrap().dispatch(2, "agent.event", &json!({"provider":"codex",
                    "event":"UserPromptSubmit","prompt":context["text"]})).unwrap();
            }
            if scenario == "cancel_in_flight" {
                graphs.get_mut("one").unwrap().dispatch(1, "graph.disconnect", &wire).unwrap();
                context = cancellations(&mut pending, &graphs).pop().unwrap().1;
                pending.get_mut(id).unwrap().cancelling = true;
            }
            let poll = json!({"records":[pending.get(id).map(|s| &s.record)]}); // retained before the workspace changes
            let moved = match scenario {
                "sender_moves" => HashSet::from([1]), "receiver_moves" => HashSet::from([2]), _ => HashSet::from([1,2])
            };
            let mut destination = Graph::default();
            graphs.get_mut("one").unwrap().transfer_nodes_to(&moved, &mut destination);
            graphs.insert("two".into(), destination);
            move_record(&mut context, "one", "two", &moved);
            for record in pending.values_mut() { move_record(&mut record.record, "one", "two", &moved); }
            let owner = if moved.contains(&2) { "two" } else { "one" };
            if matches!(scenario, "replacement" | "accept_after_replacement") {
                graphs.get_mut(owner).unwrap().observe_agent(2, &json!({"provider":"codex","session_id":"new","pid":99}));
            }
            if late { finish_submit(&mut pending, &mut graphs, context.clone(), &accepted); }
            if scenario == "cancel_in_flight" {
                finish_cancel(&mut pending, &mut graphs, &context, &json!(CodexCancelOutcome::Deleted));
                assert!(!graphs[owner].native_pending(id));
                assert_eq!(graphs[owner].receipts.last().unwrap()["status"], "cancelled in Codex");
                continue;
            }
            if matches!(scenario, "sender_moves" | "receiver_moves" | "replacement" | "accept_after_replacement") {
                let revoked = cancellations(&mut pending, &graphs);
                assert_eq!(revoked.len(), 1, "{scenario}");
                assert_eq!(revoked[0].1["submission_id"], "submission-A");
                assert_eq!(revoked[0].1["target"]["session_id"], "s2");
                continue;
            }
            assert!(cancellations(&mut pending, &graphs).is_empty(), "{scenario}");
            assert!(!graphs["one"].native_pending(id));
            if scenario == "prompt_before_ack" { assert!(pending.is_empty()); continue; }
            assert!(graphs[owner].native_pending(id));
            if scenario == "poll_in_flight" {
                finish_poll(&mut pending, &mut graphs, &poll, &json!({"outcome":"listed","queued_ids":["submission-A"]}));
                assert!(graphs[owner].native_pending(id));
                finish_poll(&mut pending, &mut graphs, &poll, &json!({"outcome":"listed","queued_ids":[]}));
                assert!(pending.is_empty());
                assert_eq!(graphs[owner].receipts.last().unwrap()["status"], "started or removed in Codex");
            }
        }
    }
}
