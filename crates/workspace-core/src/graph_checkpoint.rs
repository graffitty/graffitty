//! Recovery preserves wiring, ports and attention, never process identities or queued work.
use super::*;

impl Graph {
    pub fn checkpoint(&self) -> Value {
        self.wiring(false)
    }

    /// Read-only RPCs reuse the private wiring snapshot until a graph mutation.
    pub fn owner_wiring(&mut self) -> Option<std::sync::Arc<Value>> {
        if self.edges.is_empty() { self.owner_wiring = None; return None; }
        if let Some((revision, limit, saved)) = &self.owner_wiring {
            if (*revision, *limit) == (self.revision, self.default_run_limit) {
                return Some(saved.clone());
            }
        }
        let saved = std::sync::Arc::new(self.wiring(true));
        self.owner_wiring = Some((self.revision, self.default_run_limit, saved.clone()));
        Some(saved)
    }

    fn wiring(&self, owner: bool) -> Value {
        let mut connected = HashMap::<&str, (BTreeMap<&str, &str>, std::collections::BTreeSet<&str>)>::new();
        for edge in self.edges.values() {
            let mode = if edge["turn_completed"] == true { "turn_completed" }
                else if edge["send"] == true { "send" } else { "read" };
            connected.entry(string(edge, "from")).or_default().0.insert(string(edge, "from_port"), mode);
            connected.entry(string(edge, "to")).or_default().1.insert(string(edge, "to_port"));
        }
        let nodes: Vec<_> = self.nodes.iter().filter_map(|(key, node)| {
            let wired = connected.get(key.as_str());
            if owner && wired.is_none() { return None; }
            let mut inputs = ports(node, false);
            let mut outputs = ports(node, true);
            if let Some((from, to)) = wired {
                let input_ids: HashSet<_> = inputs.iter().map(|p| string(p, "id").to_owned()).collect();
                let output_ids: HashSet<_> = outputs.iter().map(|p| string(p, "id").to_owned()).collect();
                inputs.extend(to.iter().filter(|id| !input_ids.contains(**id)).map(|id| json!({"id":id})));
                outputs.extend(from.iter().filter(|(id, _)| !output_ids.contains(**id))
                    .map(|(id, mode)| json!({"id":id,"mode":mode})));
            }
            let mut saved = json!({"node":key,"manifest":{"inputs":inputs,"outputs":outputs}});
            if owner {
                saved["advertised"] = json!(node["manifest"].is_object());
            } else {
                saved["attention"] = node["attention"].clone();
            }
            Some(saved)
        }).collect();
        let edges: Vec<_> = self
            .edges
            .values()
            .map(|edge| {
                let mut edge = edge.clone();
                edge.as_object_mut().unwrap().remove("revision");
                edge
            })
            .collect();
        json!({"nodes":nodes,"edges":edges,"run_messages":self.default_run_limit})
    }

    /// Validate the entire saved graph before changing any live ports or links.
    /// Only mapped nodes already belonging to this graph can receive wiring.
    pub fn restore_checkpoint(
        &mut self,
        saved: &Value,
        ids: &HashMap<String, String>,
    ) -> Result<()> {
        let nodes = saved["nodes"]
            .as_array()
            .ok_or("Invalid saved graph nodes")?;
        let edges = saved["edges"]
            .as_array()
            .ok_or("Invalid saved graph connections")?;
        let mut staged = Self::with_settings(self.settings.clone());
        let mut seen = HashSet::new();
        for node in nodes {
            let old = node["node"].as_str().ok_or("Invalid saved graph node")?;
            let key = ids
                .get(old)
                .ok_or("Saved graph node has no restored pane")?;
            let id = crate::pane_id::parse(key).ok_or("Invalid restored pane")?;
            if !seen.insert(key.clone()) || !self.nodes.contains_key(key) {
                return Err("Duplicate or foreign restored graph node".into());
            }
            staged.add(id, String::new());
            staged.nodes.get_mut(key).unwrap()["manifest"] = manifest(&node["manifest"])?;
            staged.nodes.get_mut(key).unwrap()["attention"] = json!(attention::validate(&node["attention"])?);
        }
        for edge in edges {
            let mut edge = edge.clone();
            for field in ["from", "to"] {
                let old = edge[field]
                    .as_str()
                    .ok_or("Invalid saved connection endpoint")?;
                edge[field] = json!(
                    ids.get(old)
                        .ok_or("Saved connection has no restored pane")?
                );
            }
            let id =
                crate::pane_id::parse(string(&edge, "from")).ok_or("Invalid saved connection")?;
            staged.dispatch(id, "graph.connect", &edge)?;
        }
        let limit = saved
            .get("run_messages")
            .map(|v| {
                v.as_u64()
                    .filter(|v| *v > 0 && *v <= i64::MAX as u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .ok_or("Invalid saved run limit")
            })
            .transpose()?;
        // Synthesized ports validate a saved connection. An adopted shell must
        // still acquire the built-in ports of the provider discovered later.
        for saved_node in nodes.iter().filter(|node| node["advertised"] == false) {
            let key = &ids[string(saved_node, "node")];
            staged.nodes.get_mut(key).unwrap().as_object_mut().unwrap().remove("manifest");
        }
        for (key, node) in staged.nodes {
            let live = self.nodes.get_mut(&key).unwrap();
            // Preserve active provider registration if the resumed agent beat us.
            if live["provider"] == "shell" && !node["manifest"].is_null() {
                live["manifest"] = node["manifest"].clone();
            }
            // A fresh lifecycle event that arrived during restoration wins.
            if live["status"] == "unintegrated" && live["attention"].is_null() && !node["attention"].is_null() {
                live["attention"] = node["attention"].clone();
                self.activity_clock.advance(live);
            }
        }
        for (_, mut edge) in staged.edges {
            self.revision += 1;
            edge["revision"] = json!(self.revision);
            self.edges.insert(edge_key(&edge), edge);
        }
        if let Some(limit) = limit {
            self.default_run_limit = limit;
        }
        self.revoke();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_handover_reuses_wiring_and_keeps_discovered_ports_dynamic() {
        let mut source = Graph::default();
        for id in 1..=3 { source.add(id, format!("Pane {id}")); }
        for id in 1..=2 { source.observe_agent(id, &json!({"provider":"codex","status":"idle"})); }
        let wire = json!({"from":"t1","to":"t2","read":true});
        source.dispatch(1, "graph.connect", &wire).unwrap();
        let saved = source.owner_wiring().unwrap();
        source.dispatch(1, "graph.list", &json!({})).unwrap();
        assert!(std::sync::Arc::ptr_eq(&saved, &source.owner_wiring().unwrap()));
        assert_eq!(saved["nodes"].as_array().unwrap().len(), 2);
        let mut target = Graph::default();
        for id in 1..=3 { target.add(id, format!("Adopted {id}")); }
        let ids = target.nodes.keys().map(|key| (key.clone(), key.clone())).collect();
        target.restore_checkpoint(&saved, &ids).unwrap();
        target.dispatch(3, "agent.event", &json!({"provider":"claude","event":"SessionStart"})).unwrap();
        assert!(target.can_read("t1", "t2"), "An unrelated registration preserves the wire");
        for id in 1..=3 {
            assert!(target.nodes[&format!("t{id}")].get("manifest").is_none());
            target.observe_agent(id, &json!({"provider":"codex","status":"idle"}));
        }
        target.dispatch(3, "graph.connect", &json!({"from":"t3","to":"t2","read":true})).unwrap();
        assert!(target.can_read("t3", "t2"));
    }

    #[test]
    fn restores_ports_and_connection_options_with_new_ids_without_replaying_work() {
        let mut source = Graph::default();
        for id in [1, 2] {
            source.add(id, format!("Pane {id}"));
            source
                .dispatch(
                    id,
                    "agent.event",
                    &json!({"provider":"claude","event":"SessionStart"}),
                )
                .unwrap();
        }
        source
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"t1","to":"t2","send":true,"muted":true,
            "contains":"important","outcome":"success","stop_at":4102444800u64}),
            )
            .unwrap();
        source.nodes.get_mut("t1").unwrap()["provider"] = json!("shell");
        source.nodes.get_mut("t2").unwrap()["provider"] = json!("shell");
        let saved = source.checkpoint();
        let mut target = Graph::default();
        target.add(10, "New shell".into());
        target.add(20, "New shell".into());
        let ids = HashMap::from([("t1".into(), "t10".into()), ("t2".into(), "t20".into())]);
        target.restore_checkpoint(&saved, &ids).unwrap();
        let edge = &target.checkpoint()["edges"][0];
        assert_eq!(edge["from"], "t10");
        assert_eq!(edge["to"], "t20");
        assert_eq!(edge["muted"], true);
        assert_eq!(edge["contains"], "important");
        assert_eq!(edge["stop_at"].as_f64(), Some(4102444800.));
        assert_eq!(target.nodes["t10"]["provider"], "shell");
        assert!(target.queues.is_empty());
        let before = target.snapshot();
        let mut invalid = saved;
        invalid["edges"][0]["to"] = json!("t999");
        assert!(target.restore_checkpoint(&invalid, &ids).is_err());
        assert_eq!(target.snapshot(), before);
    }
}
