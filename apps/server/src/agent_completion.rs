//! Native providers without lifecycle hooks are observed by the owner. Transcript
//! reads run through Workers, never in the PTY actor, and retain process identity.
use graffitty_workspace_core::graph::Graph;
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Default)]
pub struct Completions {
    pending: HashMap<String, Pending>,
}
struct Pending {
    workspace: String,
    id: u64,
    identity: Value,
    path: String,
    target: Option<Value>,
    run_id: String,
    launched: bool,
}
fn identity(node: &Value) -> Value {
    json!([
        node["provider"], node["pid"],
        node["started"],
        node["session_id"],
        node["transcript_path"]
    ])
}
impl Completions {
    pub fn observe(&mut self, workspace: &str, id: u64, before: &Value, after: &Value) {
        let successful = match after["provider"].as_str() {
            Some("codex") => graffitty_workspace_core::graph::discovered_codex_success(before, after),
            Some("claude") => {
                let advanced = before["completion_checkpoint"].as_u64().zip(after["completion_checkpoint"].as_u64())
                    .is_some_and(|(old, new)| new > old);
                after["status"] == "idle" && (before["status"] == "busy" || advanced)
            }
            _ => false,
        };
        if !successful || after["integrated"] == true || identity(before) != identity(after) {
            return;
        }
        let Some(path) = after["transcript_path"].as_str().filter(|p| !p.is_empty()) else {
            return;
        };
        let target = if after["provider"] == "codex" {
            let turn = &after["observed_turn"];
            let id = turn["id"].as_str().filter(|_| turn["status"] == "completed");
            // The daemon's transcript tail may already belong to a newer turn.
            // Only the local scanner binds a byte offset directly to a turn ID.
            let checkpoint = if id.is_some() {
                turn["completion_checkpoint"].as_u64()
            } else {
                after["completion_checkpoint"].as_u64().filter(|end| *end > before["completion_checkpoint"].as_u64().unwrap_or(0))
            }.filter(|end| *end > 0);
            if id.is_none() && checkpoint.is_none() { return; }
            Some(json!({"turn_id":id,"checkpoint":checkpoint}))
        } else { None };
        if self.pending.len() >= 1024 {
            return;
        }
        self.pending.insert(
            format!("completion:{}", uuid::Uuid::new_v4().simple()),
            Pending {
                workspace: workspace.into(),
                id,
                identity: identity(after),
                path: path.into(),
                target,
                run_id: after["run_id"].as_str().unwrap_or("").into(),
                launched: false,
            },
        );
    }
    pub fn requests(&self) -> Vec<(String, Value)> {
        self.pending
            .iter()
            .filter(|(_, p)| !p.launched)
            .map(|(key, p)| {
                let request = match &p.target {
                    Some(target) => json!({"op":"codex_completion","path":p.path,"target":target}),
                    None => json!({"op":"read","path":p.path}),
                };
                (key.clone(), request)
            })
            .collect()
    }
    pub fn launched(&mut self, key: &str) {
        if let Some(pending) = self.pending.get_mut(key) {
            pending.launched = true;
        }
    }
    pub fn finish(&mut self, key: &str, result: &Value, graphs: &mut HashMap<String, Graph>) {
        let Some(pending) = self.pending.remove(key) else {
            return;
        };
        if result.get("error").is_some() {
            return;
        }
        let Some(graph) = graphs.get_mut(&pending.workspace) else {
            return;
        };
        let Some(node) = graph.nodes.get(&format!("t{}", pending.id)) else {
            return;
        };
        if identity(node) != pending.identity || node["integrated"] == true {
            return;
        }
        let (Some(text), Some(size)) = (result["last_message"].as_str(), result["size"].as_u64())
        else {
            return;
        };
        if let Some(target) = &pending.target {
            if !result["completion_checkpoint"].is_u64()
                || target["checkpoint"].is_u64() && target["checkpoint"] != result["completion_checkpoint"]
                || target["turn_id"].is_string() && target["turn_id"] != result["turn_id"] {
                return;
            }
        }
        let checkpoint = result["completion_checkpoint"].as_u64().unwrap_or(size);
        let _ = graph.discovered_completion(pending.id, text, &checkpoint.to_string(), &pending.run_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Completions, HashMap<String, Graph>, Value) {
        let mut graph = Graph::default();
        for id in [1, 2] {
            graph.add(id, format!("Terminal {id}"));
            graph.dispatch(id, "agent.event", &json!({"provider":"codex","event":"SessionStart","pid":100+id,"session_id":format!("session-{id}")})).unwrap();
        }
        graph
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"t1","to":"t2","turn_completed":true}),
            )
            .unwrap();
        let node = graph.nodes.get_mut("t1").unwrap();
        node["started"] = json!("stable process start");
        node["transcript_path"] = json!("/private/test/session.jsonl");
        node["status"] = json!("busy");
        let before = node.clone();
        node["status"] = json!("idle");
        node["completion_checkpoint"] = json!(500);
        (
            Completions::default(),
            HashMap::from([("main".into(), graph)]),
            before,
        )
    }
    #[test]
    fn daemon_turn_id_survives_a_superseded_tail_and_claude_retains_its_reader() {
        let (mut jobs, mut graphs, mut before) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        let node = graph.nodes.get_mut("t1").unwrap();
        before["observed_turn"] = json!({"id":"A","status":"inProgress"});
        node["observed_turn"] = json!({"id":"A","status":"completed"});
        node["completion_checkpoint"] = json!(900); // the independently sampled tail now ends at B
        jobs.observe("main", 1, &before, node);
        let (key, request) = jobs.requests().pop().unwrap();
        assert_eq!(request["target"], json!({"turn_id":"A","checkpoint":null}));
        node["observed_turn"] = json!({"id":"B","status":"inProgress"});
        node["status"] = json!("busy");
        jobs.finish(&key, &json!({"turn_id":"A","completion_checkpoint":500,"last_message":"finished A","size":940}), &mut graphs);
        assert_eq!(graphs["main"].queues["t2"][0]["text"], "finished A");
        assert_eq!(graphs["main"].nodes["t1"]["status"], "busy");
        let (mut jobs, graphs, mut before) = fixture();
        let mut after = graphs["main"].nodes["t1"].clone();
        before["provider"] = json!("claude");
        after["provider"] = json!("claude");
        jobs.observe("main", 1, &before, &after);
        assert_eq!(jobs.requests()[0].1, json!({"op":"read","path":after["transcript_path"]}));
    }

    #[test]
    fn delayed_worker_must_return_the_requested_completion() {
        for result in [
            json!({"last_message":"B draft","size":900,"turn_id":"B","completion_checkpoint":500}),
            json!({"last_message":"later output","size":900,"turn_id":"A","completion_checkpoint":900}),
        ] {
            let (mut jobs, mut graphs, before) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            let node = graph.nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"A","status":"completed","completion_checkpoint":500});
            jobs.observe("main", 1, &before, node);
            let key = jobs.requests()[0].0.clone();
            node["observed_turn"] = json!({"id":"B","status":"inProgress"});
            jobs.finish(&key, &result, &mut graphs);
            assert!(graphs["main"].queues.values().all(Vec::is_empty));
        }
    }

    #[test]
    fn failed_and_interrupted_discovery_do_not_emit_success_completions() {
        for status in ["failed", "interrupted"] {
            let (mut completions, mut graphs, before) = fixture();
            let node = graphs.get_mut("main").unwrap().nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"turn","status":status});
            completions.observe("main", 1, &before, node);
            assert!(completions.requests().is_empty());
        }
    }

    #[test]
    fn first_rollout_success_produces_one_receipt_and_one_read_after_a_verified_baseline() {
        for baseline in ["pre-turn", "interrupted", "failed", "running", "historical", "attaching", "rewound"] {
            let (mut completions, mut graphs, _) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            let node = graph.nodes.get_mut("t1").unwrap();
            node["status"] = json!(if baseline == "running" { "busy" } else { "unknown" });
            match baseline {
                "historical" => {}
                "attaching" => node["rollout_scan"] = json!({"attachment_end":300,"rollout_offset":50}),
                "pre-turn" => node["observed_turn"] = json!({"rollout_offset":50}),
                "rewound" => node["observed_turn"] = json!({"rollout_offset":500}),
                kind => {
                    node["observed_turn"] = json!({"id":"previous","status":if kind == "running" { "inProgress" } else { kind },"rollout_offset":50});
                    if kind != "running" { node["status"] = json!("idle"); }
                }
            }
            let before = node.clone();
            let mut scan = before.clone();
            scan["rollout_scan"] = Value::Null;
            scan["status"] = json!("idle");
            scan["completion_checkpoint"] = json!(213);
            scan["observed_turn"] = json!({"id":"first-success","status":"completed","completion_checkpoint":213,"rollout_offset":220});
            graph.observe_agent(1, &scan);
            let after = graph.nodes["t1"].clone();
            completions.observe("main", 1, &before, &after);
            let verified = matches!(baseline, "pre-turn" | "running" | "interrupted" | "failed");
            assert_eq!(after["attention"]["kind"] == "completed", verified, "{baseline}");
            assert_eq!(completions.requests().len(), usize::from(verified), "{baseline}");
            graph.observe_agent(1, &scan);
            completions.observe("main", 1, &after, &graph.nodes["t1"]);
            assert_eq!(graph.nodes["t1"]["attention"], after["attention"], "{baseline}");
            assert_eq!(completions.requests().len(), usize::from(verified), "{baseline}");
        }
    }

    #[test]
    fn idle_to_idle_checkpoint_detects_a_turn_missed_between_polls() {
        let (mut completions, mut graphs, _) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.nodes.get_mut("t1").unwrap()["completion_checkpoint"] = json!(100);
        let before = graph.nodes["t1"].clone();
        graph.nodes.get_mut("t1").unwrap()["completion_checkpoint"] = json!(200);
        completions.observe("main", 1, &before, &graph.nodes["t1"]);
        let requests = completions.requests();
        assert_eq!(requests.len(), 1);
        completions.finish(&requests[0].0, &json!({"last_message":"fast answer","size":250,"completion_checkpoint":200}), &mut graphs);
        assert_eq!(graphs["main"].queues["t2"][0]["text"], "fast answer");
        let after = graphs["main"].nodes["t1"].clone();
        completions.observe("main", 1, &after, &after);
        assert!(completions.requests().is_empty());
        let mut initial = after.clone();
        initial.as_object_mut().unwrap().remove("completion_checkpoint");
        completions.observe("main", 1, &initial, &after);
        assert!(completions.requests().is_empty(), "First discovery must not replay old turns");
    }
    #[test]
    fn discovered_stop_reads_once_and_preserves_newer_busy_status() {
        let (mut completions, mut graphs, before) = fixture();
        let idle = graphs["main"].nodes["t1"].clone();
        completions.observe("main", 1, &before, &idle);
        completions.observe("main", 1, &idle, &idle);
        let requests = completions.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].1,
            json!({"op":"codex_completion","path":"/private/test/session.jsonl","target":{"turn_id":null,"checkpoint":500}})
        );
        completions.launched(&requests[0].0);
        assert!(completions.requests().is_empty());
        graphs
            .get_mut("main")
            .unwrap()
            .nodes
            .get_mut("t1")
            .unwrap()["status"] = json!("busy");
        completions.finish(
            &requests[0].0,
            &json!({"last_message":"actual assistant output","size":500,"completion_checkpoint":500}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].nodes["t1"]["status"], "busy");
        assert_eq!(graphs["main"].queues["t2"].len(), 1);
        assert_eq!(
            graphs["main"].queues["t2"][0]["text"],
            "actual assistant output"
        );
        assert_eq!(
            graphs["main"].queues["t2"][0]["type"],
            "turn.completed"
        );
        completions.finish(
            &requests[0].0,
            &json!({"last_message":"actual assistant output","size":500,"completion_checkpoint":500}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].queues["t2"].len(), 1);
    }
    #[test]
    fn replaced_process_or_integrated_hooks_cannot_deliver_stale_discovery() {
        for change in ["pid", "session_id", "transcript_path", "integrated"] {
            let (mut completions, mut graphs, before) = fixture();
            let idle = graphs["main"].nodes["t1"].clone();
            completions.observe("main", 1, &before, &idle);
            let key = completions.requests()[0].0.clone();
            graphs
                .get_mut("main")
                .unwrap()
                .nodes
                .get_mut("t1")
                .unwrap()[change] = if change == "integrated" {
                json!(true)
            } else {
                json!("replacement")
            };
            completions.finish(
                &key,
                &json!({"last_message":"stale","size":500,"completion_checkpoint":500}),
                &mut graphs,
            );
            assert!(
                graphs["main"].queues.values().all(Vec::is_empty),
                "{change}"
            );
        }
        let (mut completions, graphs, before) = fixture();
        let mut idle = graphs["main"].nodes["t1"].clone();
        idle["integrated"] = json!(true);
        completions.observe("main", 1, &before, &idle);
        assert!(completions.requests().is_empty());
    }
    #[test]
    fn delayed_completion_retains_its_causal_run_after_a_new_user_prompt() {
        let (mut completions, mut graphs, _) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"t1","to":"t2","send":true}),
            )
            .unwrap();
        let event = graph
            .dispatch(1, "graph.send", &json!({"to":"t2","text":"start"}))
            .unwrap();
        let run = event["run_id"].as_str().unwrap().to_owned();
        graph.queues.clear();
        graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"UserPromptSubmit","prompt":format!("[Graffitty message; run {run}]\nstart")})).unwrap();
        let before = graph.nodes["t1"].clone();
        graph.nodes.get_mut("t1").unwrap()["status"] = json!("idle");
        graph.nodes.get_mut("t1").unwrap()["completion_checkpoint"] = json!(700);
        completions.observe("main", 1, &before, &graph.nodes["t1"]);
        let key = completions.requests()[0].0.clone();
        graph
            .dispatch(
                1,
                "agent.event",
                &json!({"provider":"codex","event":"UserPromptSubmit","prompt":"new user input"}),
            )
            .unwrap();
        assert!(graph.nodes["t1"].get("run_id").is_none());
        completions.finish(
            &key,
            &json!({"last_message":"prior turn result","size":700,"completion_checkpoint":700}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].queues["t2"][0]["run_id"], run);
        assert_eq!(graphs["main"].nodes["t1"]["status"], "busy");
    }

    #[test]
    fn repeated_answer_in_a_later_checkpoint_is_a_distinct_turn() {
        let (mut completions, mut graphs, before) = fixture();
        for size in [500, 500, 800] {
            graphs.get_mut("main").unwrap().nodes.get_mut("t1").unwrap()["completion_checkpoint"] = json!(size);
            let idle = graphs["main"].nodes["t1"].clone();
            completions.observe("main", 1, &before, &idle);
            let key = completions.requests()[0].0.clone();
            completions.finish(
                &key,
                &json!({"last_message":"same answer","size":size,"completion_checkpoint":size}),
                &mut graphs,
            );
        }
        assert_eq!(graphs["main"].queues["t2"].len(), 2);
    }
}
