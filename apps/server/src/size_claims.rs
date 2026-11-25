//! Track which client last sized each tab's shared main area.
//! A frontend can claim the tabs it presents when it fits the main
//! view to its window. The latest claim wins.
//!
//! Other clients letterbox that area. Closing the claimant ends the
//! claim and preserves the last size.
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Default)]
pub struct Claims {
    views: BTreeMap<u64, (String, u64, String)>,
    owners: BTreeMap<(String, u64), u64>,
}

impl Claims {
    pub fn claim(&mut self, workspace: &str, tab: u64, client: u64) {
        self.owners.insert((workspace.into(), tab), client);
    }
    pub fn present(&mut self, client: u64, view: Option<(String, u64, String)>) {
        if let Some(view) = view {
            self.views.insert(client, view);
        } else {
            self.views.remove(&client);
        }
    }
    fn other_panes<'a>(&'a self, workspace: &'a str, tab: u64, client: u64) -> impl Iterator<Item = &'a String> {
        self.views.iter().filter_map(move |(peer, (name, id, pane))|
            (*peer != client && name == workspace && *id == tab).then_some(pane))
    }
    pub fn owns(&self, workspace: &str, tab: u64, client: u64) -> bool {
        self.owners.get(&(workspace.to_owned(), tab)) == Some(&client)
    }
    pub fn can_fit(&self, workspace: &str, tab: u64, client: u64) -> bool {
        let Some((name, id, focus)) = self.views.get(&client) else { return false };
        name == workspace && *id == tab && !focus.is_empty()
            && self.other_panes(workspace, tab, client).all(|pane| focus == pane)
    }
    pub fn release(&mut self, client: u64) {
        self.views.remove(&client);
        self.owners.retain(|_, owner| *owner != client);
    }
    /// Mark each topology tab "self", "other" or "none" for the receiving client,
    /// forgetting claims on tabs that closed or moved to another workspace.
    pub fn annotate(&mut self, topology: &mut Value, workspace: &str, client: u64) {
        let Some(tabs) = topology.get_mut("tabs").and_then(Value::as_array_mut) else { return };
        let live: Vec<u64> = tabs.iter().filter_map(|tab| tab["id"].as_u64()).collect();
        self.owners.retain(|(name, tab), _| name != workspace || live.contains(tab));
        for tab in tabs {
            let Some(id) = tab["id"].as_u64() else { continue };
            tab["other_main_panes"] = serde_json::json!(self.other_panes(workspace, id, client).collect::<std::collections::BTreeSet<_>>());
            tab["size_owner"] = match self.owners.get(&(workspace.to_string(), id)) {
                Some(owner) if *owner == client => "self",
                Some(_) => "other",
                None => "none",
            }
            .into();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn roles(claims: &mut Claims, client: u64) -> Vec<String> {
        let mut topology = json!({"tabs":[{"id":1},{"id":2}]});
        claims.annotate(&mut topology, "main", client);
        topology["tabs"].as_array().unwrap().iter()
            .map(|tab| tab["size_owner"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn the_latest_claim_wins_and_each_client_sees_its_own_role() {
        let mut claims = Claims::default();
        assert_eq!(roles(&mut claims, 10), ["none", "none"]);
        claims.claim("main", 1, 10);
        claims.claim("main", 2, 10);
        assert_eq!(roles(&mut claims, 10), ["self", "self"]);
        assert_eq!(roles(&mut claims, 11), ["other", "other"]);
        claims.claim("main", 1, 11);
        assert_eq!(roles(&mut claims, 10), ["other", "self"]);
        assert_eq!(roles(&mut claims, 11), ["self", "other"]);
    }

    #[test]
    fn a_departing_client_leaves_its_tabs_unclaimed_rather_than_handing_them_over() {
        let mut claims = Claims::default();
        claims.claim("main", 1, 10);
        claims.claim("main", 2, 11);
        claims.release(10);
        assert_eq!(roles(&mut claims, 11), ["none", "self"]);
    }

    #[test]
    fn only_other_presentations_of_the_same_tab_can_block_a_fit() {
        let mut claims = Claims::default();
        claims.present(10, Some(("a".into(), 1, "t2".into())));
        for (workspace, tab, pane, allowed) in [
            ("b", 1, "t1", true), ("a", 2, "t1", true), ("a", 1, "t1", false),
            ("a", 1, "", false), ("a", 1, "t2", true),
        ] {
            claims.present(11, Some((workspace.into(), tab, pane.into())));
            assert_eq!(claims.can_fit("a", 1, 10), allowed);
        }
        claims.release(11);
        assert!(claims.can_fit("a", 1, 10));
    }

    #[test]
    fn closed_tabs_are_forgotten_without_touching_other_workspaces() {
        let mut claims = Claims::default();
        claims.claim("main", 3, 10);
        claims.claim("other", 3, 10);
        roles(&mut claims, 10);
        assert!(!claims.owners.contains_key(&("main".to_string(), 3)));
        assert!(claims.owners.contains_key(&("other".to_string(), 3)));
    }
}
