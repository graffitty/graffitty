//! Godot adapter for the frontend-neutral Herdr-derived agent list model.
use crate::graph_client::{from_variant, to_variant};
use godot::{classes::{IRefCounted, RefCounted}, prelude::*};
use graffitty_client_core::agents::{Agents, Input};

/// Bad provider data invalidates only its own row. Other panes in this
/// snapshot still supply current status and topology.
fn entries<T: serde::de::DeserializeOwned>(value: &Variant) -> Result<Vec<T>, String> {
    let array = value.try_to::<godot::builtin::AnyArray>().map_err(|e| e.to_string())?;
    Ok(array.iter_shared().filter_map(|entry| {
        serde_json::from_value(from_variant(&entry).ok()?).ok()
    }).collect())
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AgentsCore { base: Base<RefCounted>, state: Agents }
#[godot_api]
impl IRefCounted for AgentsCore {
    fn init(base: Base<RefCounted>) -> Self { Self { base, state: Agents::default() } }
}
#[godot_api]
impl AgentsCore {
    #[func]
    fn observe(&mut self, input: Variant, now: i64) -> VarDictionary {
        let result = entries::<Input>(&input);
        match result {
            Ok(input) => {
                let (rows, sounds) = self.state.observe(input, now.max(0) as u64);
                to_variant(&serde_json::json!({"rows":rows,"sounds":sounds})).to()
            }
            Err(e) => { godot_error!("Invalid agents snapshot: {e}"); VarDictionary::new() }
        }
    }
    /// Connected groups as trees: `{nodes, edges}` in, `[{root, rows}]` out.
    #[func]
    fn tree(&self, input: Variant) -> Variant {
        use graffitty_client_core::agents_tree::{Edge, Node, trees};
        let parsed = input.try_to::<VarDictionary>().map_err(|e| e.to_string()).and_then(|tree| {
            let nodes = entries::<Node>(&tree.get("nodes").ok_or("Missing tree nodes")?)?;
            let edges = entries::<Edge>(&tree.get("edges").ok_or("Missing tree edges")?)?;
            Ok((nodes, edges))
        });
        match parsed {
            Ok((nodes, edges)) => to_variant(&serde_json::json!(trees(&nodes, &edges))),
            Err(e) => { godot_error!("Invalid agents tree input: {e}"); Variant::nil() }
        }
    }
    /// The Resource Monitor's rows: panes with their samples in, groups by
    /// computer and session out (`pane_resources::groups`).
    #[func]
    fn pane_resources(input: Variant) -> Variant {
        use graffitty_client_core::pane_resources::{groups, Input};
        match from_variant(&input).and_then(|v| serde_json::from_value::<Vec<Input>>(v).map_err(|e| e.to_string())) {
            Ok(inputs) => to_variant(&serde_json::json!(groups(&inputs))),
            Err(e) => { godot_error!("Invalid pane resources input: {e}"); Variant::nil() }
        }
    }
    #[func]
    fn pin(&mut self, id: GString, pinned: bool) { self.state.pin(id.to_string(), pinned); }
    #[func]
    fn save(&self) -> GString { self.state.save().as_str().into() }
    #[func]
    fn restore(&mut self, json: GString) -> GString {
        self.state.restore(&json.to_string()).err().unwrap_or_default().as_str().into()
    }
}
