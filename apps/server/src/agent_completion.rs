//! Native providers without lifecycle hooks are observed by the owner. Transcript
//! reads run through Workers, never in the PTY actor, and retain process identity.
use graffitty_workspace_core::graph::{Graph, OutcomeRoutes};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

#[derive(Default)]
pub struct Completions {
    pending: VecDeque<(String, Pending)>,
}
enum Outcome {
    Read { path: String, target: Option<Value> },
    Failed(Value),
}
struct Pending {
    workspace: String,
    id: u64,
    identity: Value,
    routes: OutcomeRoutes,
    outcome: Outcome,
    run_id: String,
    launched: bool,
    retries: u8,
    retry_at: Option<Instant>,
}
fn identity(node: &Value) -> Value {
    json!([
        node["provider"], node["pid"],
        node["started"],
        node["session_id"],
        node["transcript_path"]
    ])
}
impl Pending {
    fn matches(&self, graph: &Graph) -> bool {
        let failed = matches!(self.outcome, Outcome::Failed(_));
        graph.nodes.get(&format!("t{}", self.id)).is_some_and(|node|
            identity(node) == self.identity && (failed || node["integrated"] != true))
            && graph.has_outcome_route(self.id, failed, &self.routes)
    }
}
impl Completions {
    /// Once a scan advances its cursor, every completion in it must be kept.
    /// Apply backpressure before taking the next sample.
    pub fn ready_for_scan(&self) -> bool { self.pending.len() < 1024 }

    /// The graph and PTYs have moved. Keep queued outcomes, worker keys and
    /// retry deadlines attached to their live source pane.
    pub fn transfer(&mut self, source: &str, target: &str, moved: &HashSet<u64>, destination: &Graph) {
        self.pending.retain_mut(|(_, pending)| {
            if pending.workspace != source || !moved.contains(&pending.id) { return true; }
            if !pending.matches(destination) { return false; }
            pending.workspace = target.to_owned();
            true
        });
    }

    pub fn retain_current(&mut self, graphs: &HashMap<String, Graph>) {
        self.pending.retain(|(_, p)| graphs.get(&p.workspace).is_some_and(|graph| p.matches(graph)));
    }

    /// Publish ready errors in source order. A read, including one awaiting a
    /// retry, blocks only the subsequent outcomes of its own pane.
    pub fn advance(&mut self, graphs: &mut HashMap<String, Graph>) {
        self.retain_current(graphs);
        let mut reading = HashSet::new();
        self.pending.retain(|(_, job)| {
            let pane = (job.workspace.clone(), job.id);
            match &job.outcome {
                Outcome::Read { .. } => { reading.insert(pane); true }
                Outcome::Failed(turn) if !reading.contains(&pane) => {
                    let _ = graphs.get_mut(&job.workspace).unwrap().discovered_failure(job.id, turn, &job.run_id, &job.routes);
                    false
                }
                Outcome::Failed(_) => true,
            }
        });
    }

    pub fn observe(&mut self, workspace: &str, id: u64, before: &Value, graph: &Graph) {
        let after = &graph.nodes[&format!("t{id}")];
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
        self.enqueue_read(workspace, id, graph, after, target, after["run_id"].as_str().unwrap_or(""));
    }

    pub fn observe_turns(&mut self, workspace: &str, id: u64, before: &Value, graph: &Graph, outcomes: Vec<(Value, String)>) {
        let after = &graph.nodes[&format!("t{id}")];
        for (turn, run) in outcomes {
            if turn["status"] == "failed" {
                self.enqueue(workspace, id, graph, after, Outcome::Failed(turn), &run);
            } else if after["integrated"] != true && identity(before) == identity(after) {
                let target = json!({"turn_id":turn["id"],"checkpoint":turn["completion_checkpoint"]});
                self.enqueue_read(workspace, id, graph, after, Some(target), &run);
            }
        }
    }

    fn enqueue_read(&mut self, workspace: &str, id: u64, graph: &Graph, after: &Value, target: Option<Value>, run_id: &str) {
        if let Some(path) = after["transcript_path"].as_str().filter(|p| !p.is_empty()) {
            self.enqueue(workspace, id, graph, after, Outcome::Read { path: path.into(), target }, run_id);
        }
    }

    fn enqueue(&mut self, workspace: &str, id: u64, graph: &Graph, after: &Value, outcome: Outcome, run_id: &str) {
        let routes = graph.outcome_routes(id, matches!(outcome, Outcome::Failed(_)));
        if routes.is_empty() { return; }
        self.pending.push_back((
            format!("completion:{}", uuid::Uuid::new_v4().simple()),
            Pending {
                workspace: workspace.into(),
                id,
                identity: identity(after),
                routes,
                outcome,
                run_id: run_id.into(),
                launched: false,
                retries: 0,
                retry_at: None,
            },
        ));
    }
    pub fn requests(&self) -> Vec<(String, Value)> {
        let now = Instant::now();
        let mut panes = HashSet::new();
        self.pending
            .iter()
            .filter(|(_, p)| panes.insert((&p.workspace, p.id)) && !p.launched && p.retry_at.is_none_or(|at| at <= now))
            .filter_map(|(key, p)| {
                let Outcome::Read { path, target } = &p.outcome else { return None; };
                let request = match target {
                    Some(target) => json!({"op":"codex_completion","path":path,"target":target}),
                    None => json!({"op":"read","path":path}),
                };
                Some((key.clone(), request))
            })
            .collect()
    }
    pub fn launched(&mut self, key: &str) {
        if let Some((_, pending)) = self.pending.iter_mut().find(|(id, _)| id == key) {
            pending.launched = true;
        }
    }
    pub fn finish(&mut self, key: &str, result: &Value, graphs: &mut HashMap<String, Graph>) {
        let Some(index) = self.pending.iter().position(|(id, _)| id == key) else { return; };
        let pending = &mut self.pending[index].1;
        let graph = graphs.get_mut(&pending.workspace);
        if !graph.as_deref().is_some_and(|g| pending.matches(g)) {
            self.pending.remove(index);
            return;
        }
        // Daemon metadata may precede the terminal record on disk. Keep the
        // original turn at the front of its pane's queue while waiting for it.
        let Outcome::Read { target, .. } = &pending.outcome else { return; };
        if result["status"] == "awaiting_record" && target.as_ref().is_some_and(|target|
            target["turn_id"].is_string() && target["checkpoint"].is_null()) && pending.retries < 8 {
            let delay = Duration::from_millis(125 << pending.retries.min(5));
            pending.retry_at = Some(Instant::now() + delay);
            pending.retries += 1;
            pending.launched = false;
            return;
        }
        let (_, pending) = self.pending.remove(index).unwrap();
        let graph = graph.unwrap();
        if result.get("error").is_some() { return; }
        let (Some(text), Some(size)) = (result["last_message"].as_str(), result["size"].as_u64())
        else {
            return;
        };
        if let Outcome::Read { target: Some(target), .. } = &pending.outcome {
            if !result["completion_checkpoint"].is_u64()
                || target["checkpoint"].is_u64() && target["checkpoint"] != result["completion_checkpoint"]
                || target["turn_id"].is_string() && target["turn_id"] != result["turn_id"] {
                return;
            }
        }
        let checkpoint = result["completion_checkpoint"].as_u64().unwrap_or(size);
        let _ = graph.discovered_completion(pending.id, text, checkpoint, &pending.run_id, &pending.routes);
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
    fn delayed_daemon_record_retries_before_later_turns_and_preserves_read_boundary() {
        let (mut jobs, mut graphs, mut before) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.dispatch(1, "graph.connect", &json!({"from":"t1","to":"t2","read":true})).unwrap();
        before["observed_turn"] = Value::Null;
        let node = graph.nodes.get_mut("t1").unwrap();
        node["observed_turn"] = json!({"id":"A","status":"completed"});
        jobs.observe("main", 1, &before, graph);
        let after_a = graph.nodes["t1"].clone();
        graph.nodes.get_mut("t1").unwrap()["observed_turn"] = json!({"id":"B","status":"completed"});
        jobs.observe("main", 1, &after_a, graph);
        let requests = jobs.requests();
        assert_eq!(requests.len(), 1);
        let (key, request) = &requests[0];
        assert_eq!(request["target"]["turn_id"], "A");
        jobs.launched(key);
        jobs.finish(key, &json!({"status":"awaiting_record"}), &mut graphs);
        assert!(jobs.requests().is_empty());
        let a = &mut jobs.pending.front_mut().unwrap().1;
        assert!(a.retry_at.unwrap() > Instant::now());
        a.retry_at = None; // advance across the backoff without sleeping
        assert_eq!(jobs.requests(), requests);
        jobs.launched(key);
        jobs.finish(key, &json!({"turn_id":"A","completion_checkpoint":245,"last_message":"Answer A","size":416}), &mut graphs);
        let (key, request) = jobs.requests().pop().unwrap();
        assert_eq!(request["target"]["turn_id"], "B");
        jobs.launched(&key);
        jobs.finish(&key, &json!({"turn_id":"B","completion_checkpoint":416,"last_message":"Answer B","size":450}), &mut graphs);
        let graph = graphs.get_mut("main").unwrap();
        let events = graph.dispatch(2, "graph.take", &json!({})).unwrap()["events"].as_array().unwrap().clone();
        assert_eq!(events.len(), 2);
        for (event, (answer, end)) in events.iter().zip([("Answer A",245), ("Answer B",416)]) {
            assert_eq!(event["text"], answer);
            assert_eq!(event["sessions"][0]["checkpoint"]["byte_offset"], end);
            assert_eq!(event["sessions"][0]["path"], after_a["transcript_path"]);
        }
        assert!(jobs.requests().is_empty());
    }

    #[test]
    fn unavailable_daemon_records_expire_and_identity_changes_cancel_backoff() {
        for replaced in [false, true] {
            let (mut jobs, mut graphs, before) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            let node = graph.nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"A","status":"completed"});
            jobs.observe("main", 1, &before, graph);
            for attempt in 0..9 {
                let (key, _) = jobs.requests().pop().unwrap();
                jobs.launched(&key);
                jobs.finish(&key, &json!({"status":"awaiting_record"}), &mut graphs);
                if replaced {
                    graphs.get_mut("main").unwrap().nodes.get_mut("t1").unwrap()["session_id"] = json!("replacement");
                    jobs.retain_current(&graphs);
                    break;
                }
                if attempt < 8 { jobs.pending.front_mut().unwrap().1.retry_at = None; }
            }
            assert!(jobs.pending.is_empty());
            assert!(graphs["main"].queues.values().all(Vec::is_empty));
        }
    }

    #[test]
    fn daemon_turn_id_survives_a_superseded_tail_and_claude_retains_its_reader() {
        let (mut jobs, mut graphs, mut before) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        let node = graph.nodes.get_mut("t1").unwrap();
        before["observed_turn"] = json!({"id":"A","status":"inProgress"});
        node["observed_turn"] = json!({"id":"A","status":"completed"});
        node["completion_checkpoint"] = json!(900); // the independently sampled tail now ends at B
        jobs.observe("main", 1, &before, graph);
        let (key, request) = jobs.requests().pop().unwrap();
        assert_eq!(request["target"], json!({"turn_id":"A","checkpoint":null}));
        let node = graph.nodes.get_mut("t1").unwrap();
        node["observed_turn"] = json!({"id":"B","status":"inProgress"});
        node["status"] = json!("busy");
        jobs.finish(&key, &json!({"turn_id":"A","completion_checkpoint":500,"last_message":"finished A","size":940}), &mut graphs);
        assert_eq!(graphs["main"].queues["t2"][0]["text"], "finished A");
        assert_eq!(graphs["main"].nodes["t1"]["status"], "busy");
        let (mut jobs, mut graphs, mut before) = fixture();
        let after = graphs.get_mut("main").unwrap().nodes.get_mut("t1").unwrap();
        before["provider"] = json!("claude");
        after["provider"] = json!("claude");
        jobs.observe("main", 1, &before, &graphs["main"]);
        assert_eq!(jobs.requests()[0].1, json!({"op":"read","path":graphs["main"].nodes["t1"]["transcript_path"]}));
    }

    #[test]
    fn transfer_preserves_inflight_and_retrying_reads_and_uses_destination_wires() {
        for scenario in ["launched", "retrying", "split", "disconnected", "reconnected", "replaced"] {
            let (mut jobs, mut graphs, before) = fixture();
            let source = graphs.get_mut("main").unwrap();
            source.dispatch(1, "graph.connect", &json!({"from":"t1","to":"t2","send":true})).unwrap();
            let delivers = matches!(scenario, "launched" | "retrying");
            if delivers {
                source.dispatch(1, "graph.connect", &json!({"from":"t1","from_port":"error","to":"t2"})).unwrap();
            }
            let completion_wire = json!({"from":"t1","to":"t2","turn_completed":true});
            let old_edge = source.edges.values().find(|edge| edge["turn_completed"] == true).unwrap().clone();
            source.dispatch(1, "graph.disconnect", &old_edge).unwrap();
            let observed_edge = source.dispatch(1, "graph.connect", &completion_wire).unwrap();
            let run = source.dispatch(1, "graph.send", &json!({"to":"t2","text":"start"})).unwrap()["run_id"].clone();
            source.queues.clear();
            let sender = source.nodes.get_mut("t1").unwrap();
            sender["observed_turn"] = json!({"id":"A","status":"completed"});
            sender["run_id"] = run.clone();
            jobs.observe("main", 1, &before, source);
            if delivers {
                jobs.observe_turns("main", 1, &before, source, vec![(json!({
                    "id":"B","status":"failed","error":{"message":"B failed"}
                }), run.as_str().unwrap().into())]);
            }
            let (key, request) = jobs.requests().pop().unwrap();
            jobs.launched(&key);
            if scenario == "retrying" { jobs.finish(&key, &json!({"status":"awaiting_record"}), &mut graphs); }
            let deadline = jobs.pending[0].1.retry_at;
            let moved = if scenario == "split" { HashSet::from([1]) } else { HashSet::from([1,2]) };
            let mut destination = Graph::default();
            graphs.get_mut("main").unwrap().transfer_nodes_to(&moved, &mut destination);
            jobs.transfer("main", "destination", &moved, &destination);
            if matches!(scenario, "disconnected" | "reconnected") {
                let edge = destination.edges.values().find(|e| e["turn_completed"] == true).unwrap().clone();
                assert_eq!(edge["revision"], observed_edge["revision"]);
                destination.dispatch(1, "graph.disconnect", &edge).unwrap();
                if scenario == "reconnected" {
                    let replacement = destination.dispatch(1, "graph.connect", &completion_wire).unwrap();
                    assert!(replacement["revision"].as_u64() > observed_edge["revision"].as_u64());
                }
            }
            if scenario == "replaced" { destination.nodes.get_mut("t1").unwrap()["session_id"] = json!("new provider session"); }
            graphs.insert("destination".into(), destination);
            jobs.advance(&mut graphs);
            if scenario == "retrying" {
                assert!(deadline.is_some());
                assert_eq!(jobs.pending[0].1.retry_at, deadline);
                jobs.pending[0].1.retry_at = None;
                assert_eq!(jobs.requests(), vec![(key.clone(), request)]);
                jobs.launched(&key);
            } else { assert!(jobs.requests().is_empty()); }
            jobs.finish(&key, &json!({"turn_id":"A","completion_checkpoint":245,"last_message":"Answer A","size":416}), &mut graphs);
            jobs.advance(&mut graphs);
            assert!(jobs.pending.is_empty());
            assert!(graphs["main"].queues.values().all(Vec::is_empty));
            let destination = graphs.get_mut("destination").unwrap();
            if delivers {
                let events = destination.dispatch(2, "graph.take", &json!({})).unwrap();
                let event = &events["events"][0];
                assert_eq!(events["events"].as_array().unwrap().len(), 2);
                assert_eq!(events["events"][1]["kind"], "agent.error");
                assert_eq!(events["events"][1]["text"], "B failed");
                assert_eq!(events["events"][1]["run_id"], run);
                assert_eq!(event["text"], "Answer A");
                assert_eq!(event["run_id"], run);
                assert_eq!(event["sessions"][0]["checkpoint"]["byte_offset"], 245);
            } else {
                assert!(destination.queues.values().all(Vec::is_empty), "{scenario}");
            }
        }
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
            jobs.observe("main", 1, &before, graph);
            let key = jobs.requests()[0].0.clone();
            let node = graph.nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"B","status":"inProgress"});
            jobs.finish(&key, &result, &mut graphs);
            assert!(graphs["main"].queues.values().all(Vec::is_empty));
        }
    }

    #[test]
    fn failures_wait_for_earlier_reads_without_blocking_another_source() {
        for materialized in [true, false] {
            let (mut jobs, mut graphs, _) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            graph.add(3, "Third agent".into());
            graph.dispatch(3,"agent.event",&json!({"event":"SessionStart","provider":"codex","session_id":"third","pid":103})).unwrap();
            for source in ["t1", "t3"] {
                graph.dispatch(2,"graph.connect",&json!({"from":source,"to":"t2","from_port":"error"})).unwrap();
            }
            let node = graph.nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"a","status":"inProgress"});
            node["status"] = json!("busy");
            let before = node.clone();
            let mut state = before.clone();
            state["turn_outcomes"] = json!([{"id":"a","status":"completed"},
                {"id":"b","status":"failed","error":{"message":"B failed"}}]);
            state["observed_turn"] = json!({"id":"c","status":"inProgress"});
            let outcomes = graph.observe_agent_outcomes(1, &state);
            jobs.observe_turns("main",1,&before,graph,outcomes);
            let third = &graph.nodes["t3"];
            jobs.observe_turns("main",3,third,graph,vec![(json!({"id":"x","status":"failed","error":{"message":"independent"}}),String::new())]);
            jobs.advance(&mut graphs);
            let first = graphs.get_mut("main").unwrap().dispatch(2,"graph.take",&json!({})).unwrap();
            assert_eq!(first["events"].as_array().unwrap().len(),1);
            assert_eq!(first["events"][0]["text"],"independent");
            graphs.get_mut("main").unwrap().queues.get_mut("t2").unwrap().clear();
            let (key, _) = jobs.requests().pop().unwrap();
            jobs.launched(&key);
            jobs.finish(&key,&json!({"status":"awaiting_record"}),&mut graphs);
            jobs.advance(&mut graphs);
            assert!(graphs["main"].queues["t2"].is_empty());
            jobs.pending.front_mut().unwrap().1.retry_at = None;
            jobs.launched(&key);
            let response = if materialized {
                json!({"turn_id":"a","completion_checkpoint":245,"last_message":"A answer","size":500})
            } else { json!({"error":"read failed"}) };
            jobs.finish(&key,&response,&mut graphs);
            jobs.advance(&mut graphs);
            let delivered = graphs.get_mut("main").unwrap().dispatch(2,"graph.take",&json!({})).unwrap();
            let texts: Vec<_> = delivered["events"].as_array().unwrap().iter().map(|e| e["text"].as_str().unwrap()).collect();
            assert_eq!(texts, if materialized { vec!["A answer","B failed"] } else { vec!["B failed"] });
            jobs.advance(&mut graphs);
            assert!(jobs.pending.is_empty());
            assert_eq!(graphs["main"].queues["t2"].len(),texts.len());
        }
    }

    #[test]
    fn revoked_read_releases_the_next_error_and_ignores_late_worker_replies() {
        for timing in ["before_launch", "in_flight", "awaiting_record"] {
            let (mut jobs, mut graphs, before) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t2","from_port":"error"})).unwrap();
            jobs.observe_turns("main",1,&before,graph,vec![
                (json!({"id":"A","status":"completed"}),String::new()),
                (json!({"id":"B","status":"failed","error":{"message":"quota"}}),String::new()),
            ]);
            let (key, _) = jobs.requests().pop().unwrap();
            if timing != "before_launch" { jobs.launched(&key); }
            if timing == "awaiting_record" {
                jobs.finish(&key,&json!({"status":"awaiting_record"}),&mut graphs);
                assert!(jobs.pending[0].1.retry_at.is_some());
            }
            let graph = graphs.get_mut("main").unwrap();
            let edge = graph.edges.values().find(|edge| edge["turn_completed"] == true).unwrap().clone();
            graph.dispatch(1,"graph.disconnect",&edge).unwrap();
            graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t2","from_port":"turn_completed"})).unwrap();
            jobs.advance(&mut graphs);
            assert!(jobs.pending.is_empty() && jobs.requests().is_empty(), "{timing}");
            for reply in [json!({"status":"awaiting_record"}),json!({"turn_id":"A","last_message":"old","completion_checkpoint":42,"size":42})] {
                jobs.finish(&key,&reply,&mut graphs);
                jobs.advance(&mut graphs);
            }
            let events = &graphs["main"].queues["t2"];
            assert_eq!(events.len(),1,"{timing}");
            assert_eq!(events[0]["text"],"quota");
        }
    }

    #[test]
    fn a_read_keeps_its_place_while_one_captured_recipient_remains() {
        let (mut jobs, mut graphs, before) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.add(3, "Other recipient".into());
        graph.dispatch(3,"agent.event",&json!({"event":"SessionStart","provider":"codex"})).unwrap();
        graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t3","from_port":"turn_completed"})).unwrap();
        graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t2","from_port":"error"})).unwrap();
        jobs.observe_turns("main",1,&before,graph,vec![
            (json!({"id":"A","status":"completed"}),String::new()),
            (json!({"id":"B","status":"failed","error":{"message":"quota"}}),String::new()),
        ]);
        let (key, _) = jobs.requests().pop().unwrap();
        jobs.launched(&key);
        let edge = graph.edges.values().find(|edge| edge["turn_completed"] == true && edge["to"] == "t2").unwrap().clone();
        graph.dispatch(1,"graph.disconnect",&edge).unwrap();
        jobs.advance(&mut graphs);
        assert_eq!(jobs.pending.len(),2);
        assert!(graphs["main"].queues.values().all(Vec::is_empty));
        jobs.finish(&key,&json!({"turn_id":"A","last_message":"answer","completion_checkpoint":42,"size":42}),&mut graphs);
        jobs.advance(&mut graphs);
        assert_eq!(graphs["main"].queues["t3"][0]["text"],"answer");
        assert_eq!(graphs["main"].queues["t2"][0]["text"],"quota");
    }

    #[test]
    fn later_wires_do_not_receive_already_observed_outcomes() {
        let (mut jobs, mut graphs, before) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.add(3, "Later recipient".into());
        graph.dispatch(3, "agent.event", &json!({"event":"SessionStart","provider":"codex"})).unwrap();
        let failure = || vec![(json!({"id":"b","status":"failed","error":{"message":"B failed"}}),String::new())];
        jobs.observe_turns("main",1,&before,graph,failure());
        assert!(jobs.pending.is_empty(), "No Error wire exists yet");
        graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t2","from_port":"error"})).unwrap();
        jobs.observe("main",1,&before,graph);
        jobs.observe_turns("main",1,&before,graph,failure());
        for port in ["turn_completed", "error"] {
            graph.dispatch(1,"graph.connect",&json!({"from":"t1","to":"t3","from_port":port})).unwrap();
        }
        let (key, _) = jobs.requests().pop().unwrap();
        jobs.finish(&key,&json!({"completion_checkpoint":500,"size":500,"last_message":"A answer"}),&mut graphs);
        jobs.advance(&mut graphs);
        assert_eq!(graphs["main"].queues["t2"].len(),2);
        assert!(graphs["main"].queues.get("t3").is_none_or(Vec::is_empty));
        for edge in graphs["main"].edges.values().cloned().collect::<Vec<_>>() {
            graphs.get_mut("main").unwrap().dispatch(1,"graph.disconnect",&edge).unwrap();
        }
        jobs.observe("main",1,&before,&graphs["main"]);
        assert!(jobs.requests().is_empty(), "Without a Turn completed wire no read starts");
    }

    #[test]
    fn batched_successes_deliver_in_turn_order_with_the_original_runs_while_busy() {
        let (mut completions, mut graphs, _) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.dispatch(2, "graph.connect", &json!({"from":"t2","to":"t1","send":true})).unwrap();
        let mut runs = Vec::new();
        for turn in ["a", "b"] {
            let event = graph.dispatch(2, "graph.send", &json!({"to":"t1","text":"work"})).unwrap();
            let run = event["run_id"].as_str().unwrap();
            graph.dispatch(1, "agent.event", &json!({"provider":"codex","event":"UserPromptSubmit",
                "turn_id":turn,"prompt":format!("[Graffitty message; run {run}]\nwork")})).unwrap();
            runs.push(run.to_owned());
        }
        let node = graph.nodes.get_mut("t1").unwrap();
        node["observed_turn"] = json!({"id":"a","status":"inProgress"});
        let before = node.clone();
        let mut state = before.clone();
        state["observed_turn"] = json!({"id":"c","status":"inProgress"});
        state["turn_outcomes"] = json!([{"id":"a","status":"completed","completion_checkpoint":245},
            {"id":"b","status":"completed","completion_checkpoint":416}]);
        let successes = graph.observe_agent(1, &state);
        let after = graph.nodes["t1"].clone();
        completions.observe_turns("main", 1, &before, graph, successes);
        assert_eq!(after["status"], "busy");
        state["turn_outcomes"] = json!([]);
        let repeated = graph.observe_agent(1, &state);
        completions.observe_turns("main", 1, &after, graph, repeated);
        for (turn, end) in [("a",245),("b",416)] {
            let jobs = completions.requests();
            assert_eq!(jobs.len(), 1);
            assert_eq!(jobs[0].1["target"], json!({"turn_id":turn,"checkpoint":end}));
            completions.finish(&jobs[0].0, &json!({"turn_id":turn,"last_message":format!("Answer {turn}"),"size":500,"completion_checkpoint":end}), &mut graphs);
        }
        assert!(completions.requests().is_empty());
        let queue = &graphs["main"].queues["t2"];
        assert_eq!(queue.len(), 2);
        assert_eq!((queue[0]["text"].as_str(),queue[1]["text"].as_str()),(Some("Answer a"),Some("Answer b")));
        assert_eq!(queue[0]["run_id"],runs[0]);
        assert_eq!(queue[1]["run_id"],runs[1]);
    }

    #[test]
    fn failed_and_interrupted_discovery_do_not_emit_success_completions() {
        for status in ["failed", "interrupted"] {
            let (mut completions, mut graphs, before) = fixture();
            let graph = graphs.get_mut("main").unwrap();
            let node = graph.nodes.get_mut("t1").unwrap();
            node["observed_turn"] = json!({"id":"turn","status":status});
            completions.observe("main", 1, &before, graph);
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
            completions.observe("main", 1, &before, graph);
            let verified = matches!(baseline, "pre-turn" | "running" | "interrupted" | "failed");
            assert_eq!(after["attention"]["kind"] == "completed", verified, "{baseline}");
            assert_eq!(completions.requests().len(), usize::from(verified), "{baseline}");
            graph.observe_agent(1, &scan);
            completions.observe("main", 1, &after, graph);
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
        completions.observe("main", 1, &before, graph);
        let requests = completions.requests();
        assert_eq!(requests.len(), 1);
        completions.finish(&requests[0].0, &json!({"last_message":"fast answer","size":250,"completion_checkpoint":200}), &mut graphs);
        assert_eq!(graphs["main"].queues["t2"][0]["text"], "fast answer");
        let after = graphs["main"].nodes["t1"].clone();
        completions.observe("main", 1, &after, &graphs["main"]);
        assert!(completions.requests().is_empty());
        let mut initial = after.clone();
        initial.as_object_mut().unwrap().remove("completion_checkpoint");
        completions.observe("main", 1, &initial, &graphs["main"]);
        assert!(completions.requests().is_empty(), "First discovery must not replay old turns");
    }
    #[test]
    fn discovered_stop_reads_once_and_preserves_newer_busy_status() {
        let (mut completions, mut graphs, before) = fixture();
        let idle = graphs["main"].nodes["t1"].clone();
        completions.observe("main", 1, &before, &graphs["main"]);
        completions.observe("main", 1, &idle, &graphs["main"]);
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
            completions.observe("main", 1, &before, &graphs["main"]);
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
        let (mut completions, mut graphs, before) = fixture();
        graphs.get_mut("main").unwrap().nodes.get_mut("t1").unwrap()["integrated"] = json!(true);
        completions.observe("main", 1, &before, &graphs["main"]);
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
        completions.observe("main", 1, &before, graph);
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
            completions.observe("main", 1, &before, &graphs["main"]);
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
