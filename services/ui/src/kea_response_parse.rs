
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Pure Kea DHCPv4 API response-parsing helpers, extracted from
//! `routes/dhcp.rs` (issue #1252) so `parse_reservation_entry` -- the read
//! path that turns one raw Kea `config-get` reservation JSON entry into the
//! Admin UI's `Reservation` read-model -- can be linked directly by a
//! `cargo-fuzz` harness (`fuzz/fuzz_targets/kea_reservation_parse.rs`)
//! without pulling in the whole Admin UI's `AppState`/axum/Docker/NATS
//! surface, which only `main.rs`'s binary target needs. `routes/dhcp.rs`
//! imports these same items from this crate rather than redefining them, so
//! the fuzz harness and the production binary exercise identical code.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One Kea static host reservation (fixed IP for a given MAC), as rendered
/// on the Admin UI's `/dhcp` page. Parsed out of Kea's own JSON config shape
/// by `parse_reservation_entry` below, not a direct deserialization of it --
/// Kea's real reservation entries can carry other fields (client-id,
/// per-reservation option-data, etc.) this read-model does not expose.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Reservation {
    pub subnet_id: u32,
    pub ip: String,
    pub mac: String,
    pub hostname: String,
}

/// Accepts common operator input styles (`aa:bb`, `aa-bb`, `aabb`) by keeping
/// only hex digits, then rebuilds the canonical colon-separated form used by
/// Kea reservations. Validation (rejecting a malformed length) happens
/// separately in `routes/dhcp.rs`'s `is_valid_mac` before this is called on
/// operator-submitted form input; `parse_reservation_entry` below also calls
/// this on Kea's own `hw-address` field, which is external-API input rather
/// than a validated form submission, so this must never panic regardless of
/// what string it receives.
pub fn normalize_mac(mac: &str) -> String {
    let hex: String = mac
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();

    // Reinsert a colon before every byte boundary after the first byte.
    hex.chars()
        .enumerate()
        .flat_map(|(i, c)| {
            if i > 0 && i % 2 == 0 {
                vec![':', c]
            } else {
                vec![c]
            }
        })
        .collect()
}

/// Converts one Kea reservation JSON entry (from a `config-get` response
/// this process fetched over the Kea Control Agent's HTTP API -- external,
/// not-fully-trusted input, per issue #1252) into the Admin UI's
/// `Reservation` read-model. Always returns `Some` (never `None`) despite
/// the `Option` return type -- kept as `Option` to match
/// `fetch_reservations_from_config`'s `filter_map` call site in
/// `routes/dhcp.rs`, which is written generically enough to skip an entry in
/// the future if a stricter reservation shape check is ever added here.
/// Every field access below is defensive (`.and_then`/`.unwrap_or`), so a
/// missing or wrong-typed key degrades to a placeholder value rather than
/// panicking -- this is exactly the property a fuzz harness verifies against
/// arbitrary, not just well-formed, JSON shapes.
pub fn parse_reservation_entry(subnet_id: u32, reservation: &Value) -> Option<Reservation> {
    Some(Reservation {
        subnet_id,
        ip: reservation
            .get("ip-address")
            .and_then(|v| v.as_str())
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "?".to_string()),
        mac: reservation
            .get("hw-address")
            .and_then(|v| v.as_str())
            .map(normalize_mac)
            .unwrap_or_else(|| "?".to_string()),
        hostname: reservation
            .get("hostname")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Locks in the exact colon-reinsertion behavior routes/dhcp.rs's
    // reservation forms and parse_reservation_entry both depend on: mixed
    // separators/case normalize to one canonical lowercase colon-separated
    // form.
    #[test]
    fn normalize_mac_accepts_mixed_separators_and_case() {
        assert_eq!(normalize_mac("AA:BB:CC:DD:EE:FF"), "aa:bb:cc:dd:ee:ff");
        assert_eq!(normalize_mac("aa-bb-cc-dd-ee-ff"), "aa:bb:cc:dd:ee:ff");
        assert_eq!(normalize_mac("aabbccddeeff"), "aa:bb:cc:dd:ee:ff");
    }

    // A fuzz-relevant edge case, not just a happy path: garbage input with no
    // hex digits at all must degrade to an empty string, never panic. Every
    // character here is deliberately outside 0-9/a-f (unlike e.g. "not-a-mac",
    // which contains real hex digits 'a'/'c' and would not exercise this case).
    #[test]
    fn normalize_mac_returns_empty_for_non_hex_input() {
        assert_eq!(normalize_mac("xyz!!!"), "");
    }

    #[test]
    fn parse_reservation_entry_reads_a_well_formed_kea_entry() {
        let entry = json!({
            "ip-address": "10.0.0.5",
            "hw-address": "aa:bb:cc:dd:ee:ff",
            "hostname": "myhost"
        });
        let reservation = parse_reservation_entry(1, &entry).expect("must always return Some");
        assert_eq!(reservation.subnet_id, 1);
        assert_eq!(reservation.ip, "10.0.0.5");
        assert_eq!(reservation.mac, "aa:bb:cc:dd:ee:ff");
        assert_eq!(reservation.hostname, "myhost");
    }

    // Every field is independently optional/defensive against Kea returning
    // an unexpected shape (a wrong-typed value, or a missing key) -- this is
    // the exact property the cargo-fuzz harness re-checks against arbitrary
    // byte input; this test pins the same contract for plain `cargo test`.
    #[test]
    fn parse_reservation_entry_degrades_gracefully_on_missing_or_wrong_typed_fields() {
        let entry = json!({"ip-address": 12345, "hostname": null});
        let reservation = parse_reservation_entry(2, &entry).expect("must always return Some");
        assert_eq!(reservation.ip, "?");
        assert_eq!(reservation.mac, "?");
        assert_eq!(reservation.hostname, "");
    }

    #[test]
    fn parse_reservation_entry_handles_a_completely_empty_object() {
        let reservation = parse_reservation_entry(3, &json!({})).expect("must always return Some");
        assert_eq!(reservation.subnet_id, 3);
        assert_eq!(reservation.ip, "?");
        assert_eq!(reservation.mac, "?");
        assert_eq!(reservation.hostname, "");
    }
}
