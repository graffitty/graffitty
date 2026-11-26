//! Server-qualified control belongs to the authenticated viewer capability,
//! never a pane token. Resolve on the owner so GUI focus cannot redirect it.
use crate::{Error, Server, api, terminal_api, workspace};
use graffitty_protocol::controller::Request;
use serde_json::{Value, json};

pub fn dispatch(server: &mut Server, value: &Value) -> Result<api::Reply, Error> {
    let request: Request = serde_json::from_value(value.clone())
        .map_err(|e| api::error("invalid_request", &e.to_string()))?;
    request
        .validate()
        .map_err(|e| api::error("invalid_request", e))?;
    let target = request
        .params
        .get("target")
        .map(|v| {
            v.as_str()
                .ok_or_else(|| api::error("invalid_target", "target must be a string"))
        })
        .transpose()?;
    if request.method == "pane.list" {
        if request
            .params
            .as_object()
            .unwrap()
            .keys()
            .any(|key| key != "target")
        {
            return Err(api::error(
                "invalid_params",
                "pane.list accepts only target",
            ));
        }
        return Ok(api::Reply::Ready(json!({"result":list_panes(server, target)?})));
    }
    let target = target
        .filter(|s| !s.is_empty())
        .ok_or_else(|| api::error("invalid_target", "Specify tN or cN or session:tab.pane"))?;
    let id = if let Some(id) = graffitty_workspace_core::pane_id::parse(target) {
        id
    } else {
        let (name, position) = target
            .rsplit_once(':')
            .filter(|(name, position)| !name.is_empty() && !position.is_empty())
            .ok_or_else(|| {
                api::error(
                    "invalid_target",
                    "Remote targets require tN or cN or session:tab.pane",
                )
            })?;
        let key = server
            .workspaces
            .resolve(name)
            .map_err(|e| api::error("invalid_target", &e.to_string()))?;
        workspace::sync(server, &key)?;
        let pane = terminal_api::resolve(
            &server.workspace_state.snapshot(&key),
            &format!(":{position}"),
        )
        .ok_or_else(|| {
            api::error(
                "invalid_target",
                "Unknown pane target (pane numbers start at 1)",
            )
        })?;
        graffitty_workspace_core::pane_id::parse(&pane)
            .ok_or_else(|| api::error("invalid_target", "Invalid pane identity"))?
    };
    if !server.sessions.contains_key(&id) {
        return Err(api::error("invalid_target", "Unknown terminal pane"));
    }
    dispatch_target(id, request, |id, method, params| server.request(id, method, params))
}

/// Every pane on this server, or one session's (`target` = name or `$N`).
///
/// Pane and viewer capabilities share this listing.
pub fn list_panes(server: &mut Server, target: Option<&str>) -> Result<Value, Error> {
    let selected = target
        .filter(|s| !s.is_empty())
        .map(|s| server.workspaces.resolve(s))
        .transpose()
        .map_err(|e| api::error("invalid_target", &e.to_string()))?;
    let keys: Vec<_> = server
        .workspaces
        .iter()
        .filter(|k| selected.as_ref().is_none_or(|s| s == *k))
        .cloned()
        .collect();
    let mut panes = Vec::new();
    for key in keys {
        workspace::sync(server, &key)?;
        let state = server.workspace_state.snapshot(&key);
        let session = server.workspaces.id(&key);
        for (tab_index, tab) in state.order.iter().enumerate() {
            for (pane_index, pane) in state.layout.tabs[tab].numbered_keys().iter().enumerate()
            {
                let id = graffitty_workspace_core::pane_id::parse(pane);
                let kind = if id.is_some_and(|id| server.sessions.contains_key(&id)) {
                    "terminal"
                } else {
                    "chromium"
                };
                panes.push(json!({"id":pane,"pane":pane,"type":kind,"session":session,
                    "session_name":server.workspaces.info(&key).name,"tab":format!("@{tab}"),
                    "target":pane,"position_target":format!("{session}:{}.{}", tab_index+1, pane_index+1)}));
            }
        }
    }
    Ok(json!({"panes":panes}))
}

fn dispatch_target(
    id: u64,
    request: Request,
    dispatch: impl FnOnce(u64, &str, &Value) -> Result<api::Reply, Error>,
) -> Result<api::Reply, Error> {
    let mut params = request.params;
    if request.method == "agent.seen" {
        // The graph API takes only the event; pane authority comes from the
        // controller's resolved target, even after the viewer switches sessions.
        params.as_object_mut().unwrap().remove("target");
    } else {
        params["target"] = json!(format!("t{id}"));
    }
    // The viewer selected a terminal with its server capability; reuse all
    // input validation, pacing, mode encoding and completion handling.
    dispatch(id, &request.method, &params)
}

#[cfg(test)]
mod tests {
    use super::*;
    use graffitty_workspace_core::graph::Graph;
    use std::collections::HashMap;

    #[test]
    fn agent_seen_routes_across_workspaces_and_rejects_stale_or_malformed_receipts() {
        let mut graphs = HashMap::new();
        for (id, workspace) in [(1, "shown"), (2, "previous")] {
            let mut graph = Graph::default();
            graph.add(id, "Task".into());
            for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
                graph.dispatch(id, "agent.event", &json!({"provider":"pi","event":event})).unwrap();
            }
            graphs.insert(workspace, graph);
        }
        let source = graphs["shown"].snapshot();
        let first = graphs["previous"].nodes["t2"]["attention"].clone();
        let send = |graphs: &mut HashMap<&str, Graph>, id, params: Value| {
            let request = Request { version: 1, method: "agent.seen".into(), params };
            request.validate().unwrap();
            dispatch_target(id, request, |id, method, params| {
                let workspace = match id { 1 => "shown", 2 => "previous", _ => return Err("Unknown terminal pane".into()) };
                let result = graphs.get_mut(workspace).unwrap().dispatch(id, method, params)?;
                Ok(api::Reply::Ready(json!({"result":result})))
            })
        };
        let api::Reply::Ready(reply) = send(&mut graphs, 2, json!({"target":"t2","event":first["event"]})).unwrap() else { panic!("Receipt is immediate") };
        assert_eq!(reply["result"]["attention"]["seen"], true);
        assert_eq!(graphs["shown"].snapshot(), source, "Current viewer workspace cannot redirect a receipt");
        let before = graphs["previous"].notification_revision();
        send(&mut graphs, 2, json!({"target":"t2","event":first["event"]})).unwrap();
        assert_eq!(graphs["previous"].notification_revision(), before);
        for event in ["UserPromptSubmit", "Stop"] {
            graphs.get_mut("previous").unwrap().dispatch(2, "agent.event", &json!({"event":event})).unwrap();
        }
        let current = graphs["previous"].snapshot();
        send(&mut graphs, 2, json!({"target":"t2","event":first["event"]})).unwrap();
        assert_eq!(graphs["previous"].snapshot(), current);
        for params in [json!({"target":"t2"}), json!({"target":"t2","event":7}),
            json!({"target":"t2","event":first["event"],"pane":1})] {
            assert!(send(&mut graphs, 2, params).is_err());
            assert_eq!(graphs["previous"].snapshot(), current);
        }
        assert!(send(&mut graphs, 99, json!({"target":"t99","event":first["event"]})).is_err());
    }
}
