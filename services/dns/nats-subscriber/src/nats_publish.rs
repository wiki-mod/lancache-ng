//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Shared JetStream publish helper for `lancache.dns.record` messages.
//! Factored out so both the existing periodic `lan.` reconciler (`main.rs`'s
//! `reconciler()`) and the zone-rollback listener's post-rollback re-publish
//! for `lan.` (`rollback_listener.rs`, #628) write the exact same message
//! shape the Admin UI's own publisher (`services/ui/src/routes/domains.rs`'s
//! `add_lan_record`/`remove_lan_record`) and `handle_dns_record`'s consumer
//! side already agree on -- one place defines that shape, instead of two
//! call sites independently reconstructing it and risking drift.

use async_nats::jetstream;
use serde_json::{json, Value};

/// The `lancache.dns.record` message fields, grouped into one struct rather
/// than individual function parameters purely to keep `publish_dns_record`
/// under clippy's default `too_many_arguments` threshold (7) -- 6 fields
/// plus the JetStream context and message id would otherwise make 8. `ttl`/
/// `records` are taken as `Value` (not the typed `Option<i32>`/
/// `Option<Vec<...>>` `main.rs`'s `DNSRecord` uses) so this stays usable
/// from `rollback_listener.rs`, which only ever has an already-JSON rrset in
/// hand (from a stored snapshot or a live PowerDNS export) and would
/// otherwise need to round-trip it through those typed fields for no
/// benefit. Pass `Value::Null` for a `delete` action's ttl/records --
/// `DNSRecord`'s fields are `#[serde(default)]`, so a `null` value and an
/// absent key deserialize to the same `None` on the consumer side.
pub struct DnsRecordMessage<'a> {
    pub action: &'a str,
    pub zone: &'a str,
    pub name: &'a str,
    pub record_type: &'a str,
    pub ttl: Value,
    pub records: Value,
}

/// Publishes one `lancache.dns.record` message -- see `DnsRecordMessage`'s
/// doc comment for the field shape.
pub async fn publish_dns_record(js: &jetstream::Context, msg_id: &str, msg: DnsRecordMessage<'_>) {
    let record_payload = json!({
        "action": msg.action,
        "zone": msg.zone,
        "name": msg.name,
        "type": msg.record_type,
        "ttl": msg.ttl,
        "records": msg.records,
    });

    let payload = match serde_json::to_vec(&record_payload) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("publish_dns_record: error marshaling record: {}", e);
            return;
        }
    };

    let mut headers = async_nats::HeaderMap::new();
    headers.insert(async_nats::header::NATS_MESSAGE_ID, msg_id);

    match js
        .publish_with_headers("lancache.dns.record", headers, payload.into())
        .await
    {
        Ok(publish_ack) => {
            if let Err(e) = publish_ack.await {
                eprintln!("publish_dns_record: error waiting for publish ack: {}", e);
            }
        }
        Err(e) => {
            eprintln!("publish_dns_record: error publishing record: {}", e);
        }
    }
}
