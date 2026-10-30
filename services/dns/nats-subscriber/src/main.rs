//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: NATS consumer, zone snapshots, rollback listener.
//! Why: one process applies updates and rolls zones back.
//! From: Issue #628 | PR #1858

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_nats::jetstream;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::StreamExt;
use futures::future::join_all;
use lancache_ng::config::{
    DEFAULT_RECORD_TTL, NATS_STREAM_DNS, NATS_SUBJECT_DNS, NATS_SUBJECT_FLUSH, NATS_SUBJECT_RECORD,
    canonical_zone, env_opt, is_dns_name, is_rollback_zone, keep_known_good, lan_zone,
    local_reverse, need, need_flag, process_env, rollback_zones, uint, zone_url,
};
use lancache_ng::{
    Backoff, DnsRecord, FlushRequest, PDNS_API_KEY_HEADER, PowerDns, SnapshotStore, ct_eq, die,
    http_client, need_millis, need_secs, rrset_delete, rrset_replace, rrsets_patch,
    snapshot_created_unix, unix_nanos,
};
use reqwest::Method;
use serde::Deserialize;
use serde_json::{Value, json};

// What: log tag of start errors.
// Why: the log shows which service refused to start.
// From: Issue #1683 | PR #1858
const TAG: &str = "nats-subscriber";
// What: the subscriber's waits, from the SOT defaults.
// Why: no wait is a literal; the image bakes each value.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy, Debug)]
struct Times {
    // What: pause between two NATS reconnect attempts.
    // Why: a restarting server is retried, no busy loop.
    // From: Issue #1683 | PR #1912
    reconnect: Duration,
    // What: delay before a Nak'd message is redelivered.
    // Why: a retry must not spin at full speed.
    // From: Issue #1683 | PR #1912
    nak: Duration,
    // What: pause between two confirmation reads of a zone.
    // Why: AXFR needs a moment to land on this node.
    // From: Issue #1683 | PR #1912
    confirm_pause: Duration,
    // What: how long one fetch waits for messages.
    // Why: an idle fetch ends after the wait.
    // From: Issue #1683 | PR #1912
    fetch_wait: Duration,
    // What: period of the snapshot watcher and reconciler.
    // Why: a missed message converges on the next tick.
    // From: Issue #1683 | PR #1912
    tick: Duration,
    // What: limit of one pdnsutil check-zone run.
    // Why: a hung pdnsutil must not stall the subscriber.
    // From: Issue #1683 | PR #1912
    zone_check: Duration,
    // What: limit of one cache-flush publish.
    // Why: serial acks would exceed the ui's HTTP timeout.
    // From: Issue #1683 | PR #1912
    flush: Duration,
    // What: age after which the DNS stream drops messages.
    // Why: messages survive a restart; the oldest go first.
    // From: Issue #1683 | PR #1912
    stream_max_age: Duration,
}

impl Times {
    // What: every subscriber wait from a reader.
    // Why: a missing or junk value stops the start.
    // From: Issue #1683 | PR #1912
    fn load(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        Ok(Self {
            reconnect: need_secs(get, "NATS_RECONNECT_DELAY")?,
            nak: need_millis(get, "NATS_NAK_DELAY_MS")?,
            confirm_pause: need_millis(get, "DNS_CONFIRM_PAUSE_MS")?,
            fetch_wait: need_secs(get, "NATS_FETCH_WAIT")?,
            tick: need_secs(get, "DNS_SYNC_TICK")?,
            zone_check: need_secs(get, "PDNS_ZONE_CHECK_TIMEOUT")?,
            flush: need_secs(get, "DNS_FLUSH_TIMEOUT")?,
            stream_max_age: need_secs(get, "NATS_DNS_STREAM_MAX_AGE")?,
        })
    }
}

// What: state shared by the consumer and the helper tasks.
// Why: one lock orders zone writes, snapshots, rollbacks.
// From: Issue #1683 | PR #1858
struct Ctx {
    pdns: PowerDns,
    times: Times,
    // What: auth and recursor API roots, auth config dir.
    // Why: the dns supervisor owns the layout, passes it.
    // From: Issue #1683 | PR #1858
    pdns_auth_url: String,
    pdns_rec_urls: Vec<String>,
    pdns_auth_config_dir: String,
    // What: in-process confirmation tries before a Nak.
    // Why: a longer sleep holds the message past ack_wait.
    // From: Issue #1095
    confirm_tries: u32,
    // What: deliveries after which a flush no longer waits.
    // Why: bounds a retry loop that has no max_deliver.
    // From: Issue #1095
    confirm_max_deliveries: i64,
    snapshot_dir: PathBuf,
    snapshot_file: String,
    keep_n: u32,
    // What: the local zone name, from DHCP_DOMAIN.
    // Why: the SOT owns it; no literal in this crate.
    // From: Issue #1683 | PR #1912
    lan_zone: String,
    // What: DNS_LOCAL_REVERSE_ZONES, reverse zone switch.
    // Why: rollback and snapshots follow the served zones.
    // From: Issue #1918 | PR #1858
    reverse: bool,
    lock: tokio::sync::Mutex<()>,
    js: jetstream::Context,
}

impl Ctx {
    // What: the context from an env reader, times and NATS.
    // Why: the program and the tests build it one way.
    // From: Issue #1683 | PR #1912
    fn load(
        get: &dyn Fn(&str) -> Option<String>,
        times: Times,
        js: jetstream::Context,
    ) -> Result<Self, String> {
        Ok(Self {
            pdns: PowerDns::new(http_client(get)?, need(get, "PDNS_API_KEY")?),
            times,
            pdns_auth_url: need(get, "PDNS_AUTH_API_URL")?,
            pdns_rec_urls: need(get, "PDNS_REC_API_URLS")?
                .split_whitespace()
                .map(str::to_string)
                .collect(),
            pdns_auth_config_dir: need(get, "PDNS_AUTH_CONFIG_DIR")?,
            confirm_tries: uint(get, "DNS_CONFIRM_TRIES", 1, u32::MAX.into())? as u32,
            confirm_max_deliveries: uint(get, "DNS_CONFIRM_MAX_DELIVERIES", 1, i64::MAX as u64)?
                as i64,
            snapshot_dir: PathBuf::from(need(get, "DNS_CONFIG_SNAPSHOT_DIR")?),
            snapshot_file: need(get, "DNS_ZONE_SNAPSHOT_FILE")?,
            keep_n: keep_known_good(get)?,
            lan_zone: lan_zone(get)?,
            reverse: local_reverse(get)?,
            lock: tokio::sync::Mutex::new(()),
            js,
        })
    }

    // What: the snapshot store of one dotted zone.
    // Why: every zone has its own directory under zones/.
    // From: Issue #1683 | PR #1858
    fn store(&self, zone: &str) -> SnapshotStore {
        let root = self.snapshot_dir.join("zones").join(zone);
        SnapshotStore::new(root, self.snapshot_file.as_str(), "dns")
    }

    // What: the rrsets array of one zone, as a JSON array.
    // Why: snapshots, rollback and the reconciler read it.
    // From: Issue #1683 | PR #1858
    async fn zone_rrsets(&self, zone: &str) -> Result<Value, String> {
        let rrsets = self.pdns.zone_rrsets(&self.pdns_auth_url, zone).await;
        rrsets.map(Value::Array)
    }
}

// What: publish to JetStream and await the stream ack.
// Why: a permission denial only shows as a missing ack.
// From: Issue #1683 | PR #1858
async fn publish(
    js: &jetstream::Context,
    subject: &str,
    msg_id: Option<&str>,
    payload: Vec<u8>,
) -> Result<(), String> {
    let ack = match msg_id {
        Some(id) => {
            let mut headers = async_nats::HeaderMap::new();
            headers.insert(async_nats::header::NATS_MESSAGE_ID, id);
            js.publish_with_headers(subject.to_string(), headers, payload.into())
                .await
        }
        None => js.publish(subject.to_string(), payload.into()).await,
    };
    ack.map_err(|e| e.to_string())?
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
}

// What: publish one record; true once JetStream acked it.
// Why: replication is best-effort; the next tick retries.
// From: Issue #1683 | PR #1912
async fn publish_record(js: &jetstream::Context, msg_id: &str, record: &DnsRecord) -> bool {
    let payload = match serde_json::to_vec(record) {
        Ok(payload) => payload,
        Err(e) => {
            eprintln!("encoding of {msg_id} failed, not published: {e}");
            return false;
        }
    };
    if let Err(e) = publish(js, NATS_SUBJECT_RECORD, Some(msg_id), payload).await {
        eprintln!("publish of {msg_id} failed: {e}");
        return false;
    }
    true
}

// What: a record message from one PowerDNS rrset.
// Why: reconciler and rollback share the message shape.
// From: Issue #1683 | PR #1858
fn rrset_record(action: &str, zone: &str, rrset: &Value) -> Option<DnsRecord> {
    // What: undecodable records drop the rrset, logged.
    // Why: a replace without them would empty the set.
    // From: Issue #1683 | PR #1912
    let records = match rrset
        .get("records")
        .map(|r| serde_json::from_value(r.clone()))
    {
        Some(Err(e)) => {
            let name = rrset_key(rrset).0;
            eprintln!("[{TAG}] WARNING: records of rrset {name} not decoded: {e}");
            return None;
        }
        other => other.and_then(Result::ok),
    };
    Some(DnsRecord {
        action: action.to_string(),
        zone: zone.to_string(),
        name: rrset.get("name")?.as_str()?.to_string(),
        record_type: rrset.get("type")?.as_str()?.to_string(),
        ttl: rrset
            .get("ttl")
            .and_then(Value::as_i64)
            .and_then(|ttl| i32::try_from(ttl).ok()),
        records,
    })
}

// What: PowerDNS PATCH body for one record message.
// Why: unknown actions fail before anything is sent.
// From: Issue #1683 | PR #1858
fn patch_body(record: &DnsRecord) -> Result<Value, String> {
    let rrset = match record.action.as_str() {
        "delete" => rrset_delete(&record.name, &record.record_type),
        "replace" => rrset_replace(
            &record.name,
            &record.record_type,
            record.ttl.unwrap_or(DEFAULT_RECORD_TTL),
            record.records.as_ref().map(|records| json!(records)),
        ),
        other => return Err(format!("unknown action: {other}")),
    };
    Ok(rrsets_patch(vec![rrset]))
}

// What: rrsets without SOA and NS.
// Why: a rollback must never rewrite the SOA serial or NS.
// From: Issue #1683 | PR #1858
fn data_rrsets(rrsets: &Value) -> Value {
    let kept = rrsets.as_array().into_iter().flatten().filter(|rrset| {
        !matches!(
            rrset.get("type").and_then(Value::as_str),
            Some("SOA" | "NS")
        )
    });
    Value::Array(kept.cloned().collect())
}

// What: (name, type) of an rrset, empty if missing.
// Why: the identity PowerDNS uses for one rrset.
// From: Issue #1683 | PR #1858
fn rrset_key(rrset: &Value) -> (String, String) {
    let text = |field: &str| rrset.get(field).and_then(Value::as_str).unwrap_or("");
    (text("name").to_string(), text("type").to_string())
}

// What: rrsets sorted by key, records sorted by content.
// Why: equal zones compare equal in any PowerDNS order.
// From: Issue #1683 | PR #1858
fn canonicalize(rrsets: &Value) -> Vec<Value> {
    let mut list = rrsets.as_array().cloned().unwrap_or_default();
    list.sort_by_key(rrset_key);
    for rrset in &mut list {
        if let Some(records) = rrset.get_mut("records").and_then(Value::as_array_mut) {
            records.sort_by_key(|r| r.get("content").and_then(Value::as_str).map(str::to_string));
        }
    }
    list
}

// What: true if candidate equals the newest snapshot.
// Why: the tick watcher must not evict history with copies.
// From: Issue #1683 | PR #1858
fn matches_latest(store: &SnapshotStore, candidate: &Value) -> bool {
    // What: a failed list or read is logged as no match.
    // Why: a new snapshot is safe; a silent skip hides it.
    // From: Issue #1683 | PR #1912
    let ids = match store.ids() {
        Ok(ids) => ids,
        Err(e) => {
            store.log("WARNING", &format!("cannot list snapshots: {e}"));
            return false;
        }
    };
    let Some(latest) = ids.last() else {
        return canonicalize(candidate).is_empty();
    };
    match store.read(latest) {
        Ok(snapshot) => canonicalize(&snapshot) == canonicalize(candidate),
        Err(e) => {
            store.log("WARNING", &format!("{e:#}"));
            false
        }
    }
}

// What: PATCH body that rolls current back to a snapshot.
// Why: unchanged rrsets stay out, so flushes stay precise.
// From: Issue #1683 | PR #1858
fn rollback_patch(snapshot: &Value, current: &Value) -> Value {
    let (snapshot, current) = (canonicalize(snapshot), canonicalize(current));
    let current_by_key: HashMap<_, _> = current.iter().map(|r| (rrset_key(r), r)).collect();
    let snapshot_keys: HashSet<_> = snapshot.iter().map(rrset_key).collect();
    let mut out = Vec::new();
    for rrset in &snapshot {
        if current_by_key.get(&rrset_key(rrset)) != Some(&rrset) {
            let mut replace = rrset.clone();
            replace["changetype"] = json!("REPLACE");
            out.push(replace);
        }
    }
    for rrset in &current {
        let (name, record_type) = rrset_key(rrset);
        if !snapshot_keys.contains(&(name.clone(), record_type.clone())) {
            out.push(rrset_delete(&name, &record_type));
        }
    }
    rrsets_patch(out)
}

// What: names a patch touches, first occurrence only.
// Why: each name is flushed from the recursor caches once.
// From: Issue #1683 | PR #1858
fn changed_names(patch: &Value) -> Vec<String> {
    let mut seen = HashSet::new();
    let names = patch["rrsets"].as_array().into_iter().flatten();
    let names = names.filter_map(|rrset| rrset.get("name")?.as_str());
    names
        .filter(|name| seen.insert(*name))
        .map(str::to_string)
        .collect()
}

// What: snapshot a zone if its data changed.
// Why: also covers Kea DDNS writes that bypass NATS.
// From: Issue #628
async fn snapshot_zone(ctx: &Ctx, zone: &str) {
    if !is_rollback_zone(&ctx.lan_zone, ctx.reverse, zone) {
        return;
    }
    let store = ctx.store(zone);
    let rrsets = match ctx.zone_rrsets(zone).await {
        Ok(rrsets) => rrsets,
        Err(e) => {
            store.log(
                "FATAL",
                &format!("failed to export zone {zone} for snapshotting: {e}"),
            );
            return;
        }
    };
    let data = data_rrsets(&rrsets);
    let _guard = ctx.lock.lock().await;
    if !matches_latest(&store, &data)
        && let Err(e) = store.create(&data, ctx.keep_n)
    {
        store.log("FATAL", &format!("failed to snapshot zone {zone}: {e}"));
    }
}

// What: every DNS_SYNC_TICK, snapshot all managed zones.
// Why: runs on every node, unlike the NATS reconciler.
// From: Issue #1683 | PR #1912
async fn snapshot_watcher(ctx: Arc<Ctx>) {
    let mut interval = tokio::time::interval(ctx.times.tick);
    loop {
        interval.tick().await;
        for zone in rollback_zones(&ctx.lan_zone, ctx.reverse) {
            snapshot_zone(&ctx, &zone).await;
        }
    }
}

// What: every DNS_SYNC_TICK, republish the lan zone.
// Why: a node that missed messages converges again.
// From: Issue #1683 | PR #1912
async fn reconciler(ctx: Arc<Ctx>) {
    let mut interval = tokio::time::interval(ctx.times.tick);
    loop {
        interval.tick().await;
        let rrsets = match ctx.zone_rrsets(&ctx.lan_zone).await {
            Ok(rrsets) => data_rrsets(&rrsets),
            Err(e) => {
                eprintln!("Reconciler: cannot read the lan zone: {e}");
                continue;
            }
        };
        let records: Vec<DnsRecord> = rrsets
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|rrset| rrset_record("replace", &ctx.lan_zone, rrset))
            .collect();
        for record in &records {
            let name = record.name.trim_end_matches('.');
            let msg_id = format!("reconcile-lan-{name}-{}", record.record_type);
            publish_record(&ctx.js, &msg_id, record).await;
        }
        println!("Reconciler: published {} records", records.len());
    }
}

// What: record key: zone, name and type, normalized.
// Why: publishers differ in dots and case for one record.
// From: Issue #772
fn record_key(record: &DnsRecord) -> (String, String, String) {
    (
        record.zone.trim_end_matches('.').to_ascii_lowercase(),
        record.name.trim_end_matches('.').to_ascii_lowercase(),
        record.record_type.to_ascii_uppercase(),
    )
}

// What: highest applied stream sequence per record key.
// Why: a redelivered old message must not undo a newer one.
// From: Issue #772
#[derive(Default)]
struct AppliedSequences(HashMap<(String, String, String), u64>);

impl AppliedSequences {
    // What: true if seq is not newer than the applied one.
    // Why: an exact redelivery is skipped, not re-patched.
    // From: Issue #1683 | PR #1858
    fn is_stale(&self, key: &(String, String, String), seq: u64) -> bool {
        self.0.get(key).is_some_and(|applied| seq <= *applied)
    }

    // What: remember seq as applied; never lowers a mark.
    // Why: out-of-order applies within a batch stay safe.
    // From: Issue #1683 | PR #1858
    fn record(&mut self, key: (String, String, String), seq: u64) {
        let entry = self.0.entry(key).or_insert(0);
        *entry = (*entry).max(seq);
    }
}

// What: how one message is settled.
// Why: record failures stop the batch; flush ones do not.
// From: Issue #653
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Ack,
    // What: Nak with delay, keep consuming the batch.
    // Why: a flush has no ordering hazard.
    // From: Issue #1683 | PR #1858
    Retry,
    // What: Nak with delay, stop the batch.
    // Why: a later same-key update must not overtake it.
    // From: Issue #1683 | PR #1858
    RetryStop,
}

// What: true for a zone name safe in an API URL path.
// Why: the zone comes from a NATS message, not a file.
// From: Issue #1683 | PR #1858
fn zone_is_safe(zone: &str) -> bool {
    is_dns_name(zone.trim_end_matches('.'), false, false)
}

// What: the recursor flush URL for one domain.
// Why: the domain is message text; & or # would split it.
// From: Issue #1683 | PR #1858
fn flush_url(rec_url: &str, domain: &str) -> Result<reqwest::Url, String> {
    reqwest::Url::parse_with_params(&format!("{rec_url}/cache/flush"), [("domain", domain)])
        .map_err(|e| e.to_string())
}

// What: apply one record message to PowerDNS.
// Why: 4xx and malformed ack; 5xx and network errors retry.
// From: Issue #1683 | PR #1858
async fn apply_record(
    ctx: &Ctx,
    msg: &jetstream::Message,
    applied: &mut AppliedSequences,
) -> Outcome {
    let record: DnsRecord = match serde_json::from_slice(&msg.payload) {
        Ok(record) => record,
        Err(e) => {
            eprintln!("Acking unrecoverable DNS record parse failure (malformed message): {e}");
            return Outcome::Ack;
        }
    };
    let body = match patch_body(&record) {
        Ok(body) => body,
        Err(e) => {
            eprintln!("Acking unrecoverable DNS record parse failure ({e})");
            return Outcome::Ack;
        }
    };
    if !zone_is_safe(&record.zone) {
        eprintln!("Acking DNS record with an invalid zone: {:?}", record.zone);
        return Outcome::Ack;
    }
    let key = record_key(&record);
    // What: no stream info is logged; no stale check then.
    // Why: the write applies; the cause is logged.
    // From: Issue #1683 | PR #1912
    let seq = match msg.info() {
        Ok(info) => Some(info.stream_sequence),
        Err(e) => {
            eprintln!("No stream sequence for zone={}: {e}", record.zone);
            None
        }
    };
    if let Some(seq) = seq
        && applied.is_stale(&key, seq)
    {
        println!(
            "Skipping stale DNS record redelivery: zone={} name={} type={} seq={seq}",
            record.zone, record.name, record.record_type
        );
        return Outcome::Ack;
    }
    // What: the lock covers the PATCH itself.
    // Why: rollback must not diff data this write replaces.
    // From: Issue #1683 | PR #1858
    let sent = {
        let _guard = ctx.lock.lock().await;
        ctx.pdns
            .call(
                Method::PATCH,
                &zone_url(&ctx.pdns_auth_url, &record.zone),
                Some(body.to_string()),
            )
            .await
    };
    let (zone, name, kind) = (&record.zone, &record.name, &record.record_type);
    let status = match sent {
        Ok(response) => response.status(),
        Err(e) => {
            eprintln!("Error sending PATCH request (will retry): {e}");
            return Outcome::RetryStop;
        }
    };
    if status.is_client_error() {
        eprintln!(
            "PDNS client error (acking, won't retry): {status} for zone={zone} name={name} type={kind}"
        );
        return Outcome::Ack;
    }
    if !status.is_success() {
        eprintln!(
            "PDNS server error (will retry): {status} for zone={zone} name={name} type={kind}"
        );
        return Outcome::RetryStop;
    }
    println!(
        "Updated DNS record: zone={zone} name={name} type={kind} action={}",
        record.action
    );
    // What: tell secondaries to pull the zone.
    // Why: AXFR consumers would stay stale until a recheck.
    // From: Issue #1683 | PR #1858
    let notify = ctx
        .pdns
        .call(
            Method::PUT,
            &format!("{}/notify", zone_url(&ctx.pdns_auth_url, zone)),
            None,
        )
        .await;
    // What: a failed notify retries; its cause is logged.
    // Why: the operator must see why secondaries lag.
    // From: Issue #1683 | PR #1912
    let failed = match notify {
        Ok(response) if response.status().is_success() => None,
        Ok(response) => Some(response.status().to_string()),
        Err(e) => Some(e),
    };
    if let Some(cause) = failed {
        eprintln!("PDNS notify failed (will retry) for zone={zone}: {cause}");
        return Outcome::RetryStop;
    }
    snapshot_zone(ctx, &canonical_zone(zone)).await;
    // What: mark applied only after PowerDNS confirmed.
    // Why: a failed write must not make a retry look stale.
    // From: Issue #1683 | PR #1858
    if let Some(seq) = seq {
        applied.record(key, seq);
    }
    Outcome::Ack
}

// What: true if the rrset equals the expected content.
// Why: proves AXFR landed here before a flush is trusted.
// From: Issue #1095
fn rrset_matches_expected(
    found: Option<&Value>,
    expected: Option<&[String]>,
    record_type: &str,
    expected_ttl: Option<i32>,
) -> bool {
    let (Some(rrset), Some(expected)) = (found, expected) else {
        return found.is_none() && expected.is_none();
    };
    // What: false if the TTL differs from expected_ttl.
    // Why: content alone confirms before AXFR lands it.
    // From: Issue #1683 | PR #1912
    if let Some(ttl) = expected_ttl
        && rrset.get("ttl").and_then(Value::as_i64) != Some(i64::from(ttl))
    {
        return false;
    }
    // What: A and AAAA text is parsed and printed again.
    // Why: AXFR rebuilds canonical RDATA, the ui may not.
    // From: Issue #1683 | PR #1858
    let canon = |content: &str| {
        match record_type {
            "AAAA" => content.parse::<std::net::Ipv6Addr>().map(|a| a.to_string()),
            "A" => content.parse::<std::net::Ipv4Addr>().map(|a| a.to_string()),
            _ => Ok(content.to_string()),
        }
        .unwrap_or_else(|_| content.to_string())
    };
    let contents = rrset.get("records").and_then(Value::as_array);
    let mut actual: Vec<String> = contents
        .into_iter()
        .flatten()
        .filter_map(|r| r.get("content")?.as_str())
        .map(canon)
        .collect();
    let mut wanted: Vec<String> = expected.iter().map(|s| canon(s)).collect();
    actual.sort();
    wanted.sort();
    actual == wanted
}

// What: flush each local recursor cache for one domain.
// Why: confirm the zone first, else a stale answer caches.
// From: Issue #1095
async fn apply_flush(ctx: &Ctx, msg: &jetstream::Message) -> Outcome {
    let request = serde_json::from_slice::<FlushRequest>(&msg.payload)
        .inspect_err(|e| eprintln!("Unreadable flush message, flushing \".\": {e}"))
        .ok();
    // What: unreadable flush message flushes name ".".
    // Why: old publishers send no domain field.
    // From: Issue #1683 | PR #1912
    let domain = request.as_ref().map_or(".", |r| r.domain.as_str());
    if let Some(request) = &request
        && let (Some(zone), Some(kind)) = (&request.zone, &request.record_type)
    {
        if !zone_is_safe(zone) {
            eprintln!("Acking recursor flush with an invalid zone: {zone:?}");
            return Outcome::Ack;
        }
        let mut confirmed = false;
        for _ in 0..ctx.confirm_tries {
            // What: a failed zone read counts unconfirmed.
            // Why: "absent" must not come from an error.
            // From: Issue #1683 | PR #1858
            let rrsets = ctx
                .zone_rrsets(zone)
                .await
                .inspect_err(|e| eprintln!("Zone {zone} not read for the flush check: {e}"))
                .ok();
            let expected = request.expected_content.as_deref();
            let key = (domain.to_string(), kind.clone());
            confirmed = rrsets.is_some_and(|rrsets| {
                let found = rrsets
                    .as_array()
                    .and_then(|l| l.iter().find(|r| rrset_key(r) == key));
                rrset_matches_expected(found, expected, kind, request.expected_ttl)
            });
            if confirmed {
                break;
            }
            tokio::time::sleep(ctx.times.confirm_pause).await;
        }
        if !confirmed {
            // What: no stream info is logged as delivery 0.
            // Why: the flush defers; the cause is logged.
            // From: Issue #1683 | PR #1912
            let delivered = match msg.info() {
                Ok(info) => info.delivered,
                Err(e) => {
                    eprintln!("No delivery count for the flush of {domain}: {e}");
                    0
                }
            };
            if delivered < ctx.confirm_max_deliveries {
                println!(
                    "Deferring recursor flush for {domain} ({kind}): zone not yet confirmed (delivery {delivered})"
                );
                return Outcome::Retry;
            }
            eprintln!(
                "Recursor flush for {domain} ({kind}): still unconfirmed after {delivered} deliveries; flushing anyway"
            );
        }
    }
    // What: flush every recursor; one failure retries all.
    // Why: each recursor caches apart; retries are safe.
    // From: Issue #1683 | PR #1912
    let mut outcome = Outcome::Ack;
    for rec_url in &ctx.pdns_rec_urls {
        let url = match flush_url(rec_url, domain) {
            Ok(url) => url,
            Err(e) => {
                eprintln!("Skipping recursor flush, bad PDNS_REC_API_URLS entry: {e}");
                continue;
            }
        };
        match ctx.pdns.call(Method::PUT, url.as_str(), None).await {
            Ok(response) if response.status().is_success() => {
                println!("Flushed PDNS cache at {rec_url}");
            }
            Ok(response) => {
                eprintln!("PDNS flush error at {rec_url}: {}", response.status());
                outcome = Outcome::Retry;
            }
            Err(e) => {
                eprintln!("Error sending flush request to {rec_url}: {e}");
                outcome = Outcome::Retry;
            }
        }
    }
    outcome
}

// What: route one message by subject.
// Why: unknown subjects are logged, acked and ignored.
// From: Issue #1683 | PR #1858
async fn handle(
    ctx: &Ctx,
    msg: &jetstream::Message,
    applied: &mut AppliedSequences,
    record_writes: bool,
) -> Outcome {
    let subject = msg.subject.as_str();
    if subject == NATS_SUBJECT_RECORD {
        if !record_writes {
            println!(
                "Acking DNS record message without a local PowerDNS write: secondary node, NATS_RECORD_WRITES is off"
            );
            return Outcome::Ack;
        }
        return apply_record(ctx, msg, applied).await;
    }
    if subject == NATS_SUBJECT_FLUSH {
        return apply_flush(ctx, msg).await;
    }
    println!("Unknown subject: {subject}");
    Outcome::Ack
}

// What: constant-time check of the X-API-Key header.
// Why: the listener changes zone data; network is no trust.
// From: Issue #1683 | PR #1858
fn authorized(headers: &HeaderMap, key: &str) -> bool {
    let sent = headers
        .get(PDNS_API_KEY_HEADER)
        .and_then(|v| v.to_str().ok());
    sent.is_some_and(|sent| ct_eq(sent, key))
}

// What: a JSON error reply.
// Why: the ui reads the error field of every failure.
// From: Issue #1683 | PR #1858
fn failure(status: StatusCode, message: impl Into<String>) -> (StatusCode, Json<Value>) {
    (status, Json(json!({"error": message.into()})))
}

// What: a REJECT audit line plus the JSON error reply.
// Why: log and reply of a refusal come from one place.
// From: Issue #628 | PR #1912
fn rejected(
    store: &SnapshotStore,
    status: StatusCode,
    log: &str,
    message: impl Into<String>,
) -> (StatusCode, Json<Value>) {
    store.log("REJECT", log);
    failure(status, message)
}

// What: GET /snapshots: ids and times per managed zone.
// Why: the ui lists them newest first for the operator.
// From: Issue #1683 | PR #1858
async fn list_snapshots(State(ctx): State<Arc<Ctx>>, headers: HeaderMap) -> Response {
    if !authorized(&headers, ctx.pdns.api_key()) {
        return failure(
            StatusCode::UNAUTHORIZED,
            format!("missing or invalid {PDNS_API_KEY_HEADER}"),
        )
        .into_response();
    }
    let mut zones = HashMap::new();
    for zone in rollback_zones(&ctx.lan_zone, ctx.reverse) {
        // What: an unlisted store fails the whole request.
        // Why: an error must not show as "no snapshots".
        // From: Issue #1683 | PR #1912
        let store = ctx.store(&zone);
        let ids = match store.ids() {
            Ok(ids) => ids,
            Err(e) => {
                let message = format!("cannot list snapshots of {zone}: {e}");
                store.log("WARNING", &message);
                return failure(StatusCode::INTERNAL_SERVER_ERROR, message).into_response();
            }
        };
        let list: Vec<Value> = ids
            .into_iter()
            .rev()
            .map(|id| json!({"created_unix": snapshot_created_unix(&id).unwrap_or(0), "id": id}))
            .collect();
        zones.insert(zone, list);
    }
    Json(json!({"zones": zones})).into_response()
}

// What: body of POST /rollback.
// Why: the ui sends the zone and the chosen snapshot id.
// From: Issue #1683 | PR #1858
#[derive(Deserialize)]
struct RollbackRequest {
    zone: String,
    snapshot_id: String,
}

// What: pdnsutil check-zone under the zone_check limit.
// Why: a wedged auth database must not hang the rollback.
// From: Issue #1683 | PR #1912
async fn check_zone(ctx: &Ctx, store: &SnapshotStore, zone: &str) -> bool {
    let config_dir = ctx.pdns_auth_config_dir.clone();
    let (limit, zone_name) = (ctx.times.zone_check, zone.to_owned());
    let checked = tokio::task::spawn_blocking(move || {
        lancache_ng::pdnsutil(&config_dir, &["check-zone", &zone_name], Some(limit))
    })
    .await
    .unwrap_or_else(|e| Err(format!("check-zone task failed: {e}")));
    match checked {
        Ok(_) => true,
        Err(e) => {
            store.log(
                "WARNING",
                &format!("pdnsutil check-zone for {zone} failed: {e}"),
            );
            false
        }
    }
}

// What: republish a lan rollback patch; true if all acked.
// Why: other nodes converge now, not at the next tick.
// From: Issue #1683 | PR #1912
async fn publish_patch(js: &jetstream::Context, lan_zone: &str, patch: &Value) -> bool {
    let stamp = unix_nanos();
    let mut all_published = true;
    for rrset in patch["rrsets"].as_array().into_iter().flatten() {
        let delete = rrset.get("changetype").and_then(Value::as_str) == Some("DELETE");
        let action = if delete { "delete" } else { "replace" };
        // What: an rrset with no record fails publish.
        // Why: other nodes would miss it without a trace.
        // From: Issue #1683 | PR #1912
        let Some(record) = rrset_record(action, lan_zone, rrset) else {
            let (name, kind) = rrset_key(rrset);
            eprintln!("Rollback rrset {name} {kind} not republished: no record message");
            all_published = false;
            continue;
        };
        let name = record.name.trim_end_matches('.');
        // What: a fresh message id per republish.
        // Why: the dedup window absorbs a repeated id.
        // From: Issue #1683 | PR #1912
        let msg_id = format!("rollback-{stamp}-{name}-{}", record.record_type);
        all_published &= publish_record(js, &msg_id, &record).await;
    }
    all_published
}

// What: roll one zone back to a stored snapshot.
// Why: operator-selected, never automatic; see design doc.
// From: Issue #628
async fn rollback(ctx: &Ctx, request: RollbackRequest) -> Result<Value, (StatusCode, Json<Value>)> {
    let zone = canonical_zone(&request.zone);
    if !is_rollback_zone(&ctx.lan_zone, ctx.reverse, &zone) {
        let message = format!("zone {zone} is not managed by this rollback mechanism");
        return Err(failure(StatusCode::BAD_REQUEST, message));
    }
    let store = ctx.store(&zone);
    let ids = store.ids().map_err(|e| {
        failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to list known-good snapshots: {e}"),
        )
    })?;
    // What: only listed ids are read.
    // Why: the id list is the path-traversal guard.
    // From: Issue #1683 | PR #1858
    if !ids.contains(&request.snapshot_id) {
        return Err(failure(
            StatusCode::NOT_FOUND,
            "unknown or no-longer-available snapshot",
        ));
    }
    let snapshot = store.read(&request.snapshot_id).map_err(|e| {
        let log = format!(
            "rejected known-good snapshot {} for zone {zone}: unreadable ({e})",
            request.snapshot_id
        );
        rejected(
            &store,
            StatusCode::INTERNAL_SERVER_ERROR,
            &log,
            format!("stored snapshot could not be read: {e}"),
        )
    })?;
    let snapshot = data_rrsets(&snapshot);

    // What: the lock is taken before the state is read.
    // Why: else a live write lands between diff and apply.
    // From: Issue #1683 | PR #1858
    let _guard = ctx.lock.lock().await;
    let current = ctx.zone_rrsets(&zone).await.map_err(|e| {
        failure(
            StatusCode::BAD_GATEWAY,
            format!("failed to fetch current zone state: {e}"),
        )
    })?;
    let patch = rollback_patch(&snapshot, &data_rrsets(&current));
    let patch_len = patch["rrsets"].as_array().map_or(0, Vec::len);
    if patch_len > 0 {
        let sent = ctx
            .pdns
            .call(
                Method::PATCH,
                &zone_url(&ctx.pdns_auth_url, &zone),
                Some(patch.to_string()),
            )
            .await;
        let refusal = match sent {
            Ok(response) if response.status().is_success() => None,
            Ok(response) => Some(format!(
                "PowerDNS rejected rollback PATCH: {}",
                response.status()
            )),
            Err(e) => Some(format!("failed to apply rollback PATCH: {e}")),
        };
        if let Some(message) = refusal {
            let log = format!(
                "rollback PATCH for zone {zone} snapshot {} failed: {message}",
                request.snapshot_id
            );
            return Err(rejected(&store, StatusCode::BAD_GATEWAY, &log, message));
        }
    }
    store.log("SELECT", &format!("selected known-good snapshot {} for rollback of zone {zone} ({patch_len} rrset(s) changed)", request.snapshot_id));

    let zone_check_passed = check_zone(ctx, &store, &zone).await;
    if !zone_check_passed {
        store.log("REJECT", &format!("post-rollback pdnsutil check-zone failed for zone {zone}; the PATCH is applied and NOT reverted, inspect the zone by hand"));
    }
    let changed = changed_names(&patch);

    // What: records go out before any flush.
    // Why: else a flushed cache refills from stale data.
    // From: Issue #1683 | PR #1858
    let republished = zone == canonical_zone(&ctx.lan_zone)
        && patch_len > 0
        && publish_patch(&ctx.js, &ctx.lan_zone, &patch).await;

    // What: all flushes at once, each DNS_FLUSH_TIMEOUT.
    // Why: serial acks would exceed the ui's HTTP timeout.
    // From: Issue #1683 | PR #1912
    let logger = &store;
    let flushes = changed.iter().map(|name| async move {
        let payload = json!({"domain": name}).to_string().into_bytes();
        let sent = publish(&ctx.js, NATS_SUBJECT_FLUSH, None, payload);
        match tokio::time::timeout(ctx.times.flush, sent).await {
            Ok(Ok(())) => None,
            Ok(Err(e)) => {
                logger.log(
                    "WARNING",
                    &format!("cache-flush for {name} was not acknowledged by JetStream: {e}"),
                );
                Some(name.clone())
            }
            Err(_) => {
                logger.log(
                    "WARNING",
                    &format!(
                        "cache-flush for {name} did not complete within {:?}",
                        ctx.times.flush
                    ),
                );
                Some(name.clone())
            }
        }
    });
    let flush_failed_names: Vec<String> = join_all(flushes).await.into_iter().flatten().collect();

    if patch_len > 0
        && !matches_latest(&store, &snapshot)
        && let Err(e) = store.create(&snapshot, ctx.keep_n)
    {
        store.log(
            "FATAL",
            &format!("failed to record post-rollback known-good snapshot for zone {zone}: {e}"),
        );
    }
    Ok(json!({
        "applied": true,
        "changed_names": changed,
        "zone_check_passed": zone_check_passed,
        "republished_to_nats": republished,
        "flush_ok": flush_failed_names.is_empty(),
        "flush_failed_names": flush_failed_names,
    }))
}

// What: POST /rollback: auth first, then the body.
// Why: unauthenticated callers must not reach parse errors.
// From: Issue #1683 | PR #1858
async fn rollback_handler(
    State(ctx): State<Arc<Ctx>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    if !authorized(&headers, ctx.pdns.api_key()) {
        return failure(
            StatusCode::UNAUTHORIZED,
            format!("missing or invalid {PDNS_API_KEY_HEADER}"),
        )
        .into_response();
    }
    let request: RollbackRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(e) => {
            return failure(
                StatusCode::BAD_REQUEST,
                format!("invalid request body: {e}"),
            )
            .into_response();
        }
    };
    match rollback(&ctx, request).await {
        Ok(body) => Json(body).into_response(),
        Err(reply) => reply.into_response(),
    }
}

// What: the rollback listener on DNS_ROLLBACK_LISTEN_ADDR.
// Why: ANY_BIND_IP, as the ui is in another namespace.
// From: Issue #1683 | PR #1858
async fn serve_rollback(ctx: Arc<Ctx>, addr: String) {
    let router = Router::new()
        .route("/snapshots", get(list_snapshots))
        .route("/rollback", post(rollback_handler))
        .with_state(ctx);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!(
                "[known-good-snapshot][dns][FATAL] zone-rollback listener failed to bind {addr}: {e}"
            );
            return;
        }
    };
    println!("Zone-rollback listener ready on {addr}");
    if let Err(e) = axum::serve(listener, router).await {
        eprintln!("[known-good-snapshot][dns][FATAL] zone-rollback listener stopped: {e}");
    }
}

// What: a required env value, or exit with a message.
// Why: an empty URL, consumer or address starts unsafely.
// From: Issue #1683 | PR #1858
fn required(name: &str) -> String {
    need(&process_env, name).unwrap_or_else(|e| die(TAG, &e))
}

// What: connect to NATS, start helpers, apply records.
// Why: one process owns apply, reconcile and rollback.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() {
    let nats_url = required("NATS_URL");
    let consumer_name = required("NATS_CONSUMER");
    // What: record-write and reconciler switches, required
    // Why: no hidden default; a bad value stops it
    // From: Issue #1683 | PR #1858
    let record_writes =
        need_flag(&process_env, "NATS_RECORD_WRITES").unwrap_or_else(|e| die(TAG, &e));
    let reconcile = need_flag(&process_env, "NATS_RECONCILER").unwrap_or_else(|e| die(TAG, &e));
    let times = Times::load(&process_env).unwrap_or_else(|error| die(TAG, &error));
    // What: messages per fetch.
    // Why: caps a batch; NATS_FETCH_WAIT ends idle fetch.
    // From: Issue #1683 | PR #1912
    let fetch_batch = uint(&process_env, "NATS_FETCH_BATCH", 1, u32::MAX.into())
        .unwrap_or_else(|e| die(TAG, &e)) as usize;
    let rollback_addr = required("DNS_ROLLBACK_LISTEN_ADDR");

    let mut options = async_nats::ConnectOptions::new()
        .max_reconnects(None)
        .reconnect_delay_callback(move |_| times.reconnect);
    // What: the secondary login, else the dns writer login.
    // Why: the writer name has one owner, the SOT default.
    // From: Issue #1683 | PR #1912
    let user = env_opt("NATS_USER").or_else(|| env_opt("NATS_DNS_WRITER_USER"));
    if let (Some(user), Some(password)) = (user, env_opt("NATS_PASSWORD")) {
        options = options.user_and_password(user, password);
    }
    let client = options
        .connect(&nats_url)
        .await
        .unwrap_or_else(|e| die(TAG, &format!("failed to connect to NATS: {e}")));
    println!("Connected to NATS at {nats_url}");
    let js = jetstream::new(client);
    let ctx = Arc::new(Ctx::load(&process_env, times, js).unwrap_or_else(|e| die(TAG, &e)));

    // What: a file-backed stream, NATS_DNS_STREAM_MAX_AGE.
    // Why: messages survive a restart; the oldest go first.
    // From: Issue #1683 | PR #1912
    let stream_config = jetstream::stream::Config {
        name: NATS_STREAM_DNS.to_string(),
        subjects: vec![NATS_SUBJECT_DNS.to_string()],
        storage: jetstream::stream::StorageType::File,
        max_age: times.stream_max_age,
        discard: jetstream::stream::DiscardPolicy::Old,
        ..Default::default()
    };
    let stream = ctx
        .js
        .get_or_create_stream(stream_config)
        .await
        .unwrap_or_else(|e| die(TAG, &format!("failed to create stream: {e}")));
    println!("Stream {NATS_STREAM_DNS} ready");
    let consumer_config = jetstream::consumer::pull::Config {
        durable_name: Some(consumer_name.clone()),
        filter_subject: NATS_SUBJECT_DNS.to_string(),
        ..Default::default()
    };
    let consumer = stream
        .get_or_create_consumer(&consumer_name, consumer_config)
        .await
        .unwrap_or_else(|e| die(TAG, &format!("failed to create consumer: {e}")));
    println!("Created durable subscriber: {consumer_name}");

    if reconcile {
        tokio::spawn(reconciler(ctx.clone()));
    }
    tokio::spawn(snapshot_watcher(ctx.clone()));
    tokio::spawn(serve_rollback(ctx.clone(), rollback_addr));

    // What: this loop alone applies records.
    // Why: so `applied` needs no lock.
    // From: Issue #1683 | PR #1858
    let mut applied = AppliedSequences::default();
    let policy = Backoff::load(&process_env).unwrap_or_else(|error| die(TAG, &error));
    let mut backoff = policy.start;
    loop {
        let fetched = consumer
            .fetch()
            .max_messages(fetch_batch)
            .expires(times.fetch_wait)
            .messages()
            .await;
        let mut messages = match fetched {
            Ok(messages) => messages,
            Err(e) => {
                eprintln!("Fetch error: {e} (backing off for {backoff:?})");
                tokio::time::sleep(backoff).await;
                backoff = policy.next(backoff);
                continue;
            }
        };
        let mut failed = false;
        while let Some(next) = messages.next().await {
            let msg = match next {
                Ok(msg) => msg,
                Err(e) => {
                    eprintln!("Message error: {e}");
                    failed = true;
                    break;
                }
            };
            let outcome = handle(&ctx, &msg, &mut applied, record_writes).await;
            let settled = match outcome {
                Outcome::Ack => msg.ack().await,
                _ => msg.ack_with(jetstream::AckKind::Nak(Some(times.nak))).await,
            };
            if let Err(e) = settled {
                eprintln!("Error settling message: {e}");
            }
            if outcome == Outcome::RetryStop {
                failed = true;
                break;
            }
        }
        if failed {
            eprintln!("Stream error or retryable PDNS failure; backing off for {backoff:?}");
            tokio::time::sleep(backoff).await;
            backoff = policy.next(backoff);
        } else {
            backoff = policy.start;
        }
    }
}
