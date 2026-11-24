//! Native queue worker results retain the original event, receiver and provider target.
use crate::{graph::Graph, pane_address};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

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

pub(super) fn cancellations(pending: &mut HashMap<String, Value>, graphs: &HashMap<String, Graph>) -> Vec<(String, Value)> {
    let mut revoked = Vec::new();
    pending.retain(|id, record| {
        if let Some(graph) = graphs.get(record["workspace"].as_str().unwrap_or("")) && allowed(graph, record) {
            return graph.native_pending(id);
        }
        revoked.push((id.clone(), record.clone()));
        true
    });
    revoked
}

pub(super) fn finish_submit(pending: &mut HashMap<String, Value>, graphs: &mut HashMap<String, Graph>,
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
        pending.insert(event_id.as_str().unwrap_or("").to_owned(), record);
    }
    if let Some(graph) = authorized {
        let status = if result.get("error").is_some() {
            format!("failed: {}", result["error"]["message"].as_str().unwrap_or("delivery failed"))
        } else if submission.is_some() { "queued in Codex".into() } else { "submitted".into() };
        let _ = graph.dispatch(id, "graph.ack", &json!({"event_id":event_id,"status":status}));
    }
}

pub(super) fn finish_poll(pending: &mut HashMap<String, Value>, graphs: &mut HashMap<String, Graph>,
    context: &Value, result: &Value) {
    let Some(ids) = result["queued_ids"].as_array() else { return; };
    for sampled in context["records"].as_array().into_iter().flatten() {
        let Some(id) = sampled["event"]["event_id"].as_str() else { continue; };
        let Some(current) = pending.get(id) else { continue; };
        if current["submission_id"] != sampled["submission_id"] || ids.contains(&current["submission_id"]) { continue; }
        let Some(graph) = graphs.get_mut(current["workspace"].as_str().unwrap_or("")) else { continue; };
        if !allowed(graph, current) { continue; }
        graph.record_delivery(&current["event"], "started or removed in Codex", false);
        pending.remove(id);
    }
}

pub(super) fn finish_cancel(graphs: &mut HashMap<String, Graph>, record: &Value, result: &Value) {
    if let Some(graph) = graphs.get_mut(record["workspace"].as_str().unwrap_or("")) {
        let status = if result.get("error").is_some() {
            format!("cancel failed: {}", result["error"]["message"].as_str().unwrap_or("queue error"))
        } else if result["deleted"] == true { "cancelled in Codex".into() }
        else { "already started or removed in Codex; cannot recall".into() };
        graph.record_delivery(&record["event"], &status, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
                pending.remove(id);
            }
            let poll = json!({"records":[pending.get(id)]}); // retained before the workspace changes
            let moved = match scenario {
                "sender_moves" => HashSet::from([1]), "receiver_moves" => HashSet::from([2]), _ => HashSet::from([1,2])
            };
            let mut destination = Graph::default();
            graphs.get_mut("one").unwrap().transfer_nodes_to(&moved, &mut destination);
            graphs.insert("two".into(), destination);
            move_record(&mut context, "one", "two", &moved);
            for record in pending.values_mut() { move_record(record, "one", "two", &moved); }
            let owner = if moved.contains(&2) { "two" } else { "one" };
            if matches!(scenario, "replacement" | "accept_after_replacement") {
                graphs.get_mut(owner).unwrap().observe_agent(2, &json!({"provider":"codex","session_id":"new","pid":99}));
            }
            if late { finish_submit(&mut pending, &mut graphs, context.clone(), &accepted); }
            if scenario == "cancel_in_flight" {
                finish_cancel(&mut graphs, &context, &json!({"deleted":true}));
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
                finish_poll(&mut pending, &mut graphs, &poll, &json!({"queued_ids":["submission-A"]}));
                assert!(graphs[owner].native_pending(id));
                finish_poll(&mut pending, &mut graphs, &poll, &json!({"queued_ids":[]}));
                assert!(pending.is_empty());
                assert_eq!(graphs[owner].receipts.last().unwrap()["status"], "started or removed in Codex");
            }
        }
    }
}
