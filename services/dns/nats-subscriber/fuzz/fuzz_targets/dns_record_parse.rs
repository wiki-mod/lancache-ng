
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! cargo-fuzz target (issue #1252): exercises the real
//! `serde_json::from_slice::<DNSRecord>` deserialization + `
//! dns_record_to_zone_update` conversion that `handle_dns_record` in
//! `../src/main.rs` runs against every incoming `lancache.dns.record` NATS
//! message payload -- the top-candidate least-trusted external input this
//! process consumes (Admin UI operators and any other future publisher on
//! this subject control these bytes).
#![no_main]

use libfuzzer_sys::fuzz_target;
use nats_subscriber::{DNSRecord, dns_record_to_zone_update};

fuzz_target!(|data: &[u8]| {
    if let Ok(record) = serde_json::from_slice::<DNSRecord>(data) {
        // Mirrors handle_dns_record's real call sequence exactly: parse,
        // then convert. A malformed/unknown `action` is expected to return
        // Err (see dns_record_to_zone_update's doc comment) -- the fuzz
        // target only needs to prove this never panics.
        let _ = dns_record_to_zone_update(&record);
    }
});
