//! Typed public pane addresses and their numeric transport keys.
//! The disjoint ranges let a renderer index both t1 and c1 by integer.
pub const CHROMIUM_BASE: u64 = 1 << 30;

pub fn address(id: u64) -> String {
    if id > CHROMIUM_BASE {
        format!("c{}", id - CHROMIUM_BASE)
    } else {
        format!("t{id}")
    }
}

pub fn parse(key: &str) -> Option<u64> {
    let (prefix, number) = key.split_at_checked(1)?;
    if !number.starts_with(|c: char| matches!(c, '1'..='9')) {
        return None;
    }
    let n = number.parse::<u64>().ok().filter(|n| *n < CHROMIUM_BASE)?;
    match prefix {
        "t" => Some(n),
        "c" => Some(CHROMIUM_BASE + n),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_types_have_independent_ordinals() {
        for (key, id) in [("t1", 1), ("t20", 20), ("c1", CHROMIUM_BASE + 1)] {
            assert_eq!(parse(key), Some(id));
            assert_eq!(address(id), key);
        }
        for invalid in ["%1", "t0", "c0", "t01", "t1a", "c-1", "t1073741824", "값"] {
            assert_eq!(parse(invalid), None);
        }
    }
}
