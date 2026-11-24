//! Godot values only. Server attention and pending receipts live in client-core.
use crate::graph_client::{from_variant, to_variant};
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::agent_attention::AgentAttention;
use std::collections::HashSet;

fn keys(values: &PackedStringArray) -> HashSet<String> {
    values.as_slice().iter().map(|key| key.to_string()).collect()
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AgentAttentionCore {
    base: Base<RefCounted>,
    state: AgentAttention,
}

#[godot_api]
impl IRefCounted for AgentAttentionCore {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, state: AgentAttention::default() }
    }
}

#[godot_api]
impl AgentAttentionCore {
    /// `nodes` maps pane keys to graph nodes; `visible` panes are in front of
    /// the user; `live` lists every pane that exists. Returns whether a marker
    /// changed. Invalid input changes nothing and is reported.
    #[func]
    fn observe(&mut self, nodes: VarDictionary, visible: PackedStringArray, live: PackedStringArray) -> bool {
        match from_variant(&nodes.to_variant()) {
            Ok(nodes) => self.state.observe(&nodes, &keys(&visible), &keys(&live)),
            Err(error) => {
                godot_error!("Agent attention ignored an invalid graph view: {error}");
                false
            }
        }
    }

    /// `{state: "waiting" | "completed" | "", count}` for one tab's panes.
    #[func]
    fn marker(&self, panes: PackedStringArray) -> VarDictionary {
        let panes: Vec<String> = panes.as_slice().iter().map(|key| key.to_string()).collect();
        to_variant(&self.state.marker(panes.iter().map(String::as_str))).to()
    }

    /// Effective server attention, including a pending local read, or null.
    #[func]
    fn attention(&self, key: GString) -> Variant {
        to_variant(&self.state.attention(&key.to_string()))
    }

    /// Apply existing pending receipts to a server attention field from any session.
    #[func]
    fn project_attention(&mut self, attention: Variant) -> Variant {
        match from_variant(&attention) {
            Ok(attention) => to_variant(&self.state.project_attention(&attention)),
            Err(error) => {
                godot_error!("Agent attention ignored an invalid attention field: {error}");
                Variant::nil()
            }
        }
    }

    /// Current matching receipts to retry until the server broadcasts seen.
    #[func]
    fn acknowledgements(&self) -> Variant {
        to_variant(&self.state.acknowledgements())
    }
}
