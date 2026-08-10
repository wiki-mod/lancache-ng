//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Library surface for `nats-subscriber`, split out from the binary crate
//! (`src/main.rs`) purely so the pure, external-input-parsing types and
//! functions below can be linked by a `cargo-fuzz` harness (`fuzz/`) without
//! that harness also needing to fake a real NATS/PowerDNS connection.
//! `main.rs` still owns the actual JetStream consumer loop, HTTP client, and
//! every other module (`nats_publish`, `rollback_listener`, `zone_snapshots`)
//! -- this crate root only re-exports what those fuzz targets need:
//!
//!   - `DNSRecord`/`dns_record_to_zone_update`: parses NATS
//!     `lancache.dns.record` message payloads (issue #1252's top
//!     candidate -- the least-trusted external input this process consumes).
//!   - `ZoneInfo`/`RRset`: parses PowerDNS's own zone-export API response
//!     (`reconciler()`'s `GET .../zones/lan` call in `main.rs`), a second,
//!     independent external-input boundary named in the same issue.
//!
//! `main.rs` imports these same types from this crate (`use
//! nats_subscriber::...`) rather than redefining them, so the fuzz harness
//! and the production binary exercise identical code, not a fork of it.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// One `lancache.dns.record` NATS message payload -- published by the Admin
/// UI's route handlers, this binary's own `reconciler`, and
/// `rollback_listener`'s post-rollback re-publish. Every field beyond
/// `action`/`zone`/`name`/`type` is optional (`ttl`/`records` are absent for
/// a `delete` action), so this is intentionally permissive at the
/// deserialization boundary -- `dns_record_to_zone_update` below is what
/// rejects a structurally-valid-but-semantically-unknown `action`.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DNSRecord {
    pub action: String,
    pub zone: String,
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(default)]
    pub ttl: Option<i32>,
    #[serde(default)]
    pub records: Option<Vec<HashMap<String, serde_json::Value>>>,
}

/// One PowerDNS rrset, shared by both directions this crate talks to
/// PowerDNS's HTTP API: `ZoneUpdate` (outgoing `PATCH` bodies this process
/// builds from a `DNSRecord`) and `ZoneInfo` (incoming `GET` zone-export
/// responses `reconciler()` reads). `changetype` is only meaningful for the
/// outgoing `PATCH` direction (`skip_serializing_if` keeps it out of a
/// `GET`-derived value that never had one).
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct RRset {
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changetype: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub records: Option<Vec<HashMap<String, serde_json::Value>>>,
}

/// Body this process `PATCH`es to PowerDNS's `.../zones/{zone}` endpoint,
/// built from a `DNSRecord` by `dns_record_to_zone_update`.
#[derive(Debug, Serialize, Deserialize)]
pub struct ZoneUpdate {
    pub rrsets: Vec<RRset>,
}

/// Body PowerDNS returns from `GET .../zones/{zone}` -- an external API
/// response this process (`reconciler()`) parses directly, distinct from the
/// NATS-sourced `DNSRecord` above (issue #1252 names both as separate
/// untrusted-input parsing paths).
#[derive(Debug, Serialize, Deserialize)]
pub struct ZoneInfo {
    pub rrsets: Vec<RRset>,
}

/// Converts one `DNSRecord` (already deserialized from a NATS message
/// payload) into the PowerDNS `PATCH` body that applies it. Rejects any
/// `action` other than `"replace"`/`"delete"` -- this is the semantic
/// validation step that sits after JSON deserialization succeeds but before
/// anything is sent to PowerDNS, so a structurally well-formed but
/// unrecognized `action` value fails here rather than silently no-op'ing or
/// panicking downstream.
// Bug-hunt finding #7 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
// PowerDNS's PATCH API requires a TTL whenever changetype=REPLACE; this
// crate's own `RRset` skips serializing `ttl` at all when it's `None`
// (`skip_serializing_if = "Option::is_none"`), so a "replace" DNSRecord
// with no ttl used to produce a PATCH body PowerDNS would reject with a
// 4xx -- which `handle_dns_record` then Acks (won't retry) as an
// unrecoverable client error, silently dropping the update. Every current
// caller of this function always supplies a ttl for "replace" today (see
// `services/ui/src/routes/domains.rs`'s own `ttl.unwrap_or(DEFAULT_TTL)`),
// so this was a latent landmine rather than a live bug -- but nothing in
// *this* function enforced that invariant, leaving it one new/future
// caller (or a malformed/crafted NATS message on this least-trusted
// external-input boundary, see this module's own doc comment) away from
// triggering. Default it here instead, so the invariant this module's own
// header comment already documents ("ttl is absent only for a delete
// action") is actually enforced at this boundary, not merely assumed.
const DEFAULT_REPLACE_TTL: i32 = 300;

pub fn dns_record_to_zone_update(record: &DNSRecord) -> Result<ZoneUpdate, String> {
    let (changetype, ttl_val, records_val) = match record.action.as_str() {
        "delete" => (Some("DELETE".to_string()), None, None),
        "replace" => (
            Some("REPLACE".to_string()),
            Some(record.ttl.unwrap_or(DEFAULT_REPLACE_TTL)),
            record.records.clone(),
        ),
        action => {
            return Err(format!("unknown action: {}", action));
        }
    };

    let rrset = RRset {
        name: record.name.clone(),
        record_type: record.record_type.clone(),
        ttl: ttl_val,
        changetype,
        records: records_val,
    };

    Ok(ZoneUpdate {
        rrsets: vec![rrset],
    })
}
