//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: env value reading shared by the services.
//! Why: one rule for what counts as a set value.
//! From: Issue #1683 | PR #1858

// What: an empty value counts as unset.
// Why: env files ship KEY= to mean unset.
// From: Issue #871 | PR #1858
pub fn non_empty(raw: Option<&str>) -> Option<&str> {
    raw.filter(|v| !v.is_empty())
}

// What: env var as a String; empty counts as unset.
// Why: the live-env reader of the non_empty rule.
// From: Issue #871 | PR #1858
pub fn env_opt(name: &str) -> Option<String> {
    non_empty(std::env::var(name).ok().as_deref()).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: empty and absent are unset; other values pass.
    // Why: blank KEY= falls back like a missing key.
    // From: Issue #871 | PR #1858
    #[test]
    fn empty_value_counts_as_unset() {
        assert_eq!(non_empty(Some("")), None);
        assert_eq!(non_empty(None), None);
        assert_eq!(non_empty(Some("persistent")), Some("persistent"));
    }
}
