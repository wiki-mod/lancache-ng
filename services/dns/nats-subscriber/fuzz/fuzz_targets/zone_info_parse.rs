
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! cargo-fuzz target (issue #1252): exercises the real
//! `serde_json::from_slice::<ZoneInfo>` deserialization `reconciler()` (see
//! `../src/main.rs`) runs against PowerDNS's own `GET .../zones/{zone}`
//! response body -- a second, independent external-input boundary from the
//! NATS-sourced DNSRecord path (see dns_record_parse.rs), since this bytes
//! come from PowerDNS's HTTP API rather than a NATS message.
#![no_main]

use libfuzzer_sys::fuzz_target;
use nats_subscriber::ZoneInfo;

fuzz_target!(|data: &[u8]| {
    let _ = serde_json::from_slice::<ZoneInfo>(data);
});
