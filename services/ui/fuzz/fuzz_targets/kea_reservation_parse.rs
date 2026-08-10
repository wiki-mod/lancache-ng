//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! cargo-fuzz target (issue #1252): exercises the real
//! `serde_json::from_slice::<Value>` + `parse_reservation_entry` sequence
//! `routes/dhcp.rs`'s `fetch_reservations_from_config` runs against every
//! reservation entry in Kea's `config-get` API response -- an external,
//! not-fully-trusted input path distinct from the NATS-sourced records
//! `nats-subscriber`'s own fuzz targets cover.
#![no_main]

use lancache_ui::kea_response_parse::parse_reservation_entry;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(data) {
        let _ = parse_reservation_entry(0, &value);
    }
});
