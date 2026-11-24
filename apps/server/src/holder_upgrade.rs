//! Adopt the 0.0.3 holder workspace layout during the first month after the 0.0.4 release.
//! Only Graffitty-owned address fields are visited. Node state and commands are opaque.
use graffitty_protocol::pane_id::{CHROMIUM_BASE, address};
use serde_json::{Value, json};

fn old_number(key: &str) -> Option<u64> {
    let text = key.strip_prefix('%')?;
    let id = text.parse::<u64>().ok()?;
    (id < CHROMIUM_BASE && id.to_string() == text).then_some(id)
}

pub(super) fn layout(value: &mut Value) {
    match value {
        Value::Array(items) => items.iter_mut().for_each(|item| layout(item)),
        Value::Object(fields) => {
            for (field, item) in fields {
                match field.as_str() {
                    "pane" | "focused" | "physics_anchor" | "key" => reference(item),
                    "windows" | "tiles" | "children" | "tree" | "graph_visual" => layout(item),
                    "routes" => {
                        if let Some(routes) = item.as_object_mut() {
                            for (edge, route) in std::mem::take(routes) {
                                let ends: Vec<_> = edge
                                    .split('>')
                                    .map(|end| {
                                        let (pane, port) = end.split_once('/').unwrap_or((end, ""));
                                        match old_number(pane) {
                                            Some(id) if !port.is_empty() => {
                                                format!("{}/{port}", address(id))
                                            }
                                            _ => end.to_owned(),
                                        }
                                    })
                                    .collect();
                                routes.insert(ends.join(">"), route);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn reference(value: &mut Value) {
    if let Some(id) = value.as_str().and_then(old_number) {
        *value = json!(address(id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adopts_high_terminal_ids_without_changing_the_holder_identity() {
        let mut tab = json!({"focused":"%4294967295","windows":[{"key":"%4294967295"}]});
        layout(&mut tab);
        assert_eq!(tab["focused"], "t4294967295");
        assert_eq!(tab["windows"][0]["key"], "t4294967295");
    }
}

/// A running process keeps the environment its holder gave it. Resolve only
/// its own old address, after authenticating its original pane capability.
pub(super) fn inherited_target(session: &crate::session::Session, params: &mut Value) {
    if !session.inherited_percent_id {
        return;
    }
    let old = format!("%{}", session.id);
    for field in ["target", "of", "node", "from", "to"] {
        if params[field].as_str() == Some(&old) {
            params[field] = json!(address(session.id));
        }
    }
}
