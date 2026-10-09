//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: NATS consumer, zone snapshots, rollback listener.
//! Why: one process applies updates and rolls zones back.
//! From: Issue #628 | PR #1858

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::Stdio;
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
    DEFAULT_RECORD_TTL, LAN_ZONE, NATS_STREAM_DNS, NATS_SUBJECT_DNS, NATS_SUBJECT_FLUSH,
    NATS_SUBJECT_RECORD, OutOfRange, Uint, canonical_zone, env_opt, is_dns_name, is_rollback_zone,
    need, parse_bool, process_env, rollback_zones, zone_url,
};
use lancache_ng::{
    DnsRecord, FlushRequest, PowerDns, SnapshotStore, ct_eq, die, http_client,
    snapshot_created_unix, unix_nanos,
};
use reqwest::Method;
use serde::Deserialize;
use serde_json::{Value, json};

// What: log tag of start errors.
// Why: the log shows which service refused to start.
const TAG: &str = "nats-subscriber";
// What: wait between NATS reconnect attempts.
// Why: a restarting server is retried without a busy loop.
const RECONNECT_DELAY: Duration = Duration::from_secs(3);
// What: delay before a Nak'd message is redelivered.
// Why: a retry must not spin at full speed.
const NAK_DELAY: Duration = Duration::from_millis(100);
// What: pause between two confirmation reads of a zone.
// Why: AXFR needs a moment to land on this node.
const CONFIRM_PAUSE: Duration = Duration::from_millis(100);
// What: messages per fetch, and how long a fetch waits.
// Why: bounds a batch; an idle fetch ends after the wait.
const FETCH_BATCH: usize = 10;
const FETCH_WAIT: Duration = Duration::from_secs(5);
// What: period of the snapshot watcher and the reconciler.
// Why: a missed message converges within a minute.
const TICK: Duration = Duration::from_secs(60);
// What: in-process confirmation tries before a Nak.
// Why: a longer sleep holds the message past ack_wait.
// From: Issue #1095
const CONFIRM_TRIES: u32 = 3;
// What: deliveries after which a flush no longer waits.
// Why: bounds a retry loop that has no max_deliver.
// From: Issue #1095
const CONFIRM_MAX_DELIVERIES: i64 = 100;

// What: state shared by the consumer and the helper tasks.
// Why: one lock orders zone writes, snapshots, rollbacks.
struct Ctx {
    pdns: PowerDns,
    // What: auth and recursor API roots, auth config dir.
    // Why: dns/entrypoint.sh owns the layout, exports it.
    pdns_auth_url: String,
    pdns_rec_url: String,
    pdns_auth_config_dir: String,
    snapshot_dir: PathBuf,
    keep_n: u32,
    lock: tokio::sync::Mutex<()>,
    js: jetstream::Context,
}

impl Ctx {
    // What: the snapshot store of one dotted zone.
    // Why: every zone has its own directory under zones/.
    fn store(&self, zone: &str) -> SnapshotStore {
        let root = self.snapshot_dir.join("zones").join(zone);
        SnapshotStore::new(root, "zone.json", "dns")
    }

    // What: the rrsets array of one zone, as a JSON array.
    // Why: snapshots, rollback and the reconciler read it.
    async fn zone_rrsets(&self, zone: &str) -> Result<Value, String> {
        let rrsets = self.pdns.zone_rrsets(&self.pdns_auth_url, zone).await;
        rrsets.map(Value::Array)
    }
}

// What: publish to JetStream and await the stream ack.
// Why: a permission denial only shows as a missing ack.
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

// What: publish one record message, logging a failure.
// Why: replication is best-effort; the next tick retries.
async fn publish_record(js: &jetstream::Context, msg_id: &str, record: &DnsRecord) {
    let payload = match serde_json::to_vec(record) {
        Ok(payload) => payload,
        Err(e) => {
            eprintln!("encoding of {msg_id} failed, not published: {e}");
            return;
        }
    };
    if let Err(e) = publish(js, NATS_SUBJECT_RECORD, Some(msg_id), payload).await {
        eprintln!("publish of {msg_id} failed: {e}");
    }
}

// What: a record message from one PowerDNS rrset.
// Why: reconciler and rollback share the message shape.
fn rrset_record(action: &str, zone: &str, rrset: &Value) -> Option<DnsRecord> {
    Some(DnsRecord {
        action: action.to_string(),
        zone: zone.to_string(),
        name: rrset.get("name")?.as_str()?.to_string(),
        record_type: rrset.get("type")?.as_str()?.to_string(),
        ttl: rrset
            .get("ttl")
            .and_then(Value::as_i64)
            .and_then(|ttl| i32::try_from(ttl).ok()),
        records: rrset
            .get("records")
            .and_then(|records| serde_json::from_value(records.clone()).ok()),
    })
}

// What: PowerDNS PATCH body for one record message.
// Why: unknown actions fail before anything is sent.
fn patch_body(record: &DnsRecord) -> Result<Value, String> {
    let mut rrset = json!({"name": record.name, "type": record.record_type});
    match record.action.as_str() {
        "delete" => rrset["changetype"] = json!("DELETE"),
        "replace" => {
            rrset["changetype"] = json!("REPLACE");
            rrset["ttl"] = json!(record.ttl.unwrap_or(DEFAULT_RECORD_TTL));
            if let Some(records) = &record.records {
                rrset["records"] = json!(records);
            }
        }
        other => return Err(format!("unknown action: {other}")),
    }
    Ok(json!({"rrsets": [rrset]}))
}

// What: rrsets without SOA and NS.
// Why: a rollback must never rewrite the SOA serial or NS.
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
fn rrset_key(rrset: &Value) -> (String, String) {
    let text = |field: &str| rrset.get(field).and_then(Value::as_str).unwrap_or("");
    (text("name").to_string(), text("type").to_string())
}

// What: rrsets sorted by key, records sorted by content.
// Why: equal zones compare equal in any PowerDNS order.
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
// Why: the 60 s watcher must not evict history with copies.
fn matches_latest(store: &SnapshotStore, candidate: &Value) -> bool {
    let Ok(ids) = store.ids() else {
        return false;
    };
    let Some(latest) = ids.last() else {
        return canonicalize(candidate).is_empty();
    };
    store
        .read(latest)
        .is_ok_and(|snapshot| canonicalize(&snapshot) == canonicalize(candidate))
}

// What: PATCH body that rolls current back to a snapshot.
// Why: unchanged rrsets stay out, so flushes stay precise.
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
            out.push(json!({"name": name, "type": record_type, "changetype": "DELETE"}));
        }
    }
    json!({"rrsets": out})
}

// What: names a patch touches, first occurrence only.
// Why: each name is flushed from the recursor caches once.
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
    if !is_rollback_zone(zone) {
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

// What: every minute, snapshot all managed zones.
// Why: runs on every node, unlike the NATS reconciler.
async fn snapshot_watcher(ctx: Arc<Ctx>) {
    let mut interval = tokio::time::interval(TICK);
    loop {
        interval.tick().await;
        for zone in rollback_zones() {
            snapshot_zone(&ctx, &zone).await;
        }
    }
}

// What: every minute, republish the lan zone to NATS.
// Why: a node that missed messages converges again.
async fn reconciler(ctx: Arc<Ctx>) {
    let mut interval = tokio::time::interval(TICK);
    loop {
        interval.tick().await;
        let rrsets = match ctx.zone_rrsets(LAN_ZONE).await {
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
            .filter_map(|rrset| rrset_record("replace", LAN_ZONE, rrset))
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
    fn is_stale(&self, key: &(String, String, String), seq: u64) -> bool {
        self.0.get(key).is_some_and(|applied| seq <= *applied)
    }

    // What: remember seq as applied; never lowers a mark.
    // Why: out-of-order applies within a batch stay safe.
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
    Retry,
    // What: Nak with delay, stop the batch.
    // Why: a later same-key update must not overtake it.
    RetryStop,
}

// What: true for a zone name safe in an API URL path.
// Why: the zone comes from a NATS message, not a file.
fn zone_is_safe(zone: &str) -> bool {
    is_dns_name(zone.trim_end_matches('.'), false, false)
}

// What: the recursor flush URL for one domain.
// Why: the domain is message text; & or # would split it.
fn flush_url(rec_url: &str, domain: &str) -> Result<reqwest::Url, String> {
    reqwest::Url::parse_with_params(&format!("{rec_url}/cache/flush"), [("domain", domain)])
        .map_err(|e| e.to_string())
}

// What: apply one record message to PowerDNS.
// Why: 4xx and malformed ack; 5xx and network errors retry.
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
    let seq = msg.info().ok().map(|info| info.stream_sequence);
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
    let notify = ctx
        .pdns
        .call(
            Method::PUT,
            &format!("{}/notify", zone_url(&ctx.pdns_auth_url, zone)),
            None,
        )
        .await;
    if !notify.is_ok_and(|response| response.status().is_success()) {
        eprintln!("PDNS notify failed (will retry) for zone={zone}");
        return Outcome::RetryStop;
    }
    snapshot_zone(ctx, &canonical_zone(zone)).await;
    // What: mark applied only after PowerDNS confirmed.
    // Why: a failed write must not make a retry look stale.
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
    // What: a TTL-only replace keeps content, changes TTL.
    // Why: content alone confirms before AXFR lands it.
    if let Some(ttl) = expected_ttl
        && rrset.get("ttl").and_then(Value::as_i64) != Some(i64::from(ttl))
    {
        return false;
    }
    // What: A and AAAA text is parsed and printed again.
    // Why: AXFR rebuilds canonical RDATA, the ui may not.
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

// What: flush the local recursor cache for one domain.
// Why: confirm the zone first, else a stale answer caches.
// From: Issue #1095
async fn apply_flush(ctx: &Ctx, msg: &jetstream::Message) -> Outcome {
    let request = serde_json::from_slice::<FlushRequest>(&msg.payload).ok();
    let domain = request.as_ref().map_or(".", |r| r.domain.as_str());
    if let Some(request) = &request
        && let (Some(zone), Some(kind)) = (&request.zone, &request.record_type)
    {
        if !zone_is_safe(zone) {
            eprintln!("Acking recursor flush with an invalid zone: {zone:?}");
            return Outcome::Ack;
        }
        let mut confirmed = false;
        for _ in 0..CONFIRM_TRIES {
            // What: a failed zone read counts unconfirmed.
            // Why: "absent" must not come from an error.
            let rrsets = ctx.zone_rrsets(zone).await.ok();
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
            tokio::time::sleep(CONFIRM_PAUSE).await;
        }
        if !confirmed {
            let delivered = msg.info().map_or(0, |info| info.delivered);
            if delivered < CONFIRM_MAX_DELIVERIES {
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
    let url = match flush_url(&ctx.pdns_rec_url, domain) {
        Ok(url) => url,
        Err(e) => {
            eprintln!("Acking recursor flush, bad PDNS_REC_API_URL: {e}");
            return Outcome::Ack;
        }
    };
    match ctx.pdns.call(Method::PUT, url.as_str(), None).await {
        Ok(response) if response.status().is_success() => {
            println!("Flushed PDNS cache");
            Outcome::Ack
        }
        Ok(response) => {
            eprintln!("PDNS flush error: {}", response.status());
            Outcome::Retry
        }
        Err(e) => {
            eprintln!("Error sending flush request: {e}");
            Outcome::Retry
        }
    }
}

// What: route one message by subject.
// Why: unknown subjects are logged, acked and ignored.
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
                "Acking DNS record message without a local PowerDNS write: NATS_RECORD_WRITES is off"
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
fn authorized(headers: &HeaderMap, key: &str) -> bool {
    let sent = headers.get("X-API-Key").and_then(|v| v.to_str().ok());
    sent.is_some_and(|sent| ct_eq(sent, key))
}

// What: a JSON error reply.
// Why: the ui reads the error field of every failure.
fn failure(status: StatusCode, message: impl Into<String>) -> (StatusCode, Json<Value>) {
    (status, Json(json!({"error": message.into()})))
}

// What: GET /snapshots: ids and times per managed zone.
// Why: the ui lists them newest first for the operator.
async fn list_snapshots(State(ctx): State<Arc<Ctx>>, headers: HeaderMap) -> Response {
    if !authorized(&headers, ctx.pdns.api_key()) {
        return failure(StatusCode::UNAUTHORIZED, "missing or invalid X-API-Key").into_response();
    }
    let mut zones = HashMap::new();
    for zone in rollback_zones() {
        let ids = ctx.store(&zone).ids().unwrap_or_default();
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
#[derive(Deserialize)]
struct RollbackRequest {
    zone: String,
    snapshot_id: String,
}

// What: pdnsutil check-zone with a 10 second limit.
// Why: a wedged auth database must not hang the rollback.
async fn check_zone(ctx: &Ctx, store: &SnapshotStore, zone: &str) -> bool {
    let status = tokio::process::Command::new("pdnsutil")
        .arg(format!("--config-dir={}", ctx.pdns_auth_config_dir))
        .args(["check-zone", zone])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status();
    match tokio::time::timeout(Duration::from_secs(10), status).await {
        Ok(Ok(status)) => status.success(),
        Ok(Err(e)) => {
            store.log(
                "WARNING",
                &format!("failed to run pdnsutil check-zone for {zone}: {e}"),
            );
            false
        }
        Err(_) => {
            store.log(
                "WARNING",
                &format!("pdnsutil check-zone for {zone} timed out, killed"),
            );
            false
        }
    }
}

// What: republish a rollback patch for the lan zone.
// Why: other nodes converge now, not at the next tick.
async fn publish_patch(js: &jetstream::Context, patch: &Value) {
    let stamp = unix_nanos();
    for rrset in patch["rrsets"].as_array().into_iter().flatten() {
        let delete = rrset.get("changetype").and_then(Value::as_str) == Some("DELETE");
        let action = if delete { "delete" } else { "replace" };
        if let Some(record) = rrset_record(action, LAN_ZONE, rrset) {
            let name = record.name.trim_end_matches('.');
            // What: a fresh message id per republish.
            // Why: the dedup window absorbs a repeated id.
            let msg_id = format!("rollback-{stamp}-{name}-{}", record.record_type);
            publish_record(js, &msg_id, &record).await;
        }
    }
}

// What: roll one zone back to a stored snapshot.
// Why: operator-selected, never automatic; see design doc.
// From: Issue #628
async fn rollback(ctx: &Ctx, request: RollbackRequest) -> Result<Value, (StatusCode, Json<Value>)> {
    let zone = canonical_zone(&request.zone);
    if !is_rollback_zone(&zone) {
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
    if !ids.contains(&request.snapshot_id) {
        return Err(failure(
            StatusCode::NOT_FOUND,
            "unknown or no-longer-available snapshot",
        ));
    }
    let snapshot = store.read(&request.snapshot_id).map_err(|e| {
        store.log(
            "REJECT",
            &format!(
                "rejected known-good snapshot {} for zone {zone}: unreadable ({e})",
                request.snapshot_id
            ),
        );
        failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("stored snapshot could not be read: {e}"),
        )
    })?;
    let snapshot = data_rrsets(&snapshot);

    // What: the lock is taken before the state is read.
    // Why: else a live write lands between diff and apply.
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
        let rejected = match sent {
            Ok(response) if response.status().is_success() => None,
            Ok(response) => Some(format!(
                "PowerDNS rejected rollback PATCH: {}",
                response.status()
            )),
            Err(e) => Some(format!("failed to apply rollback PATCH: {e}")),
        };
        if let Some(message) = rejected {
            store.log(
                "REJECT",
                &format!(
                    "rollback PATCH for zone {zone} snapshot {} failed: {message}",
                    request.snapshot_id
                ),
            );
            return Err(failure(StatusCode::BAD_GATEWAY, message));
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
    let republished = zone == canonical_zone(LAN_ZONE) && patch_len > 0;
    if republished {
        publish_patch(&ctx.js, &patch).await;
    }

    // What: all flushes run at once, 3 s each.
    // Why: serial acks would exceed the ui's 10 s timeout.
    let logger = &store;
    let flushes = changed.iter().map(|name| async move {
        let payload = json!({"domain": name}).to_string().into_bytes();
        let sent = publish(&ctx.js, NATS_SUBJECT_FLUSH, None, payload);
        match tokio::time::timeout(Duration::from_secs(3), sent).await {
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
                    &format!("cache-flush for {name} did not complete within 3s"),
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
async fn rollback_handler(
    State(ctx): State<Arc<Ctx>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    if !authorized(&headers, ctx.pdns.api_key()) {
        return failure(StatusCode::UNAUTHORIZED, "missing or invalid X-API-Key").into_response();
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
// Why: 0.0.0.0, as the ui is in another network namespace.
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

// What: next retry delay, doubled, at most 30 seconds.
// Why: a failing fetch must neither spin nor wait forever.
fn grow(backoff: u64) -> u64 {
    (backoff * 2).min(30)
}

// What: a required env value, or exit with a message.
// Why: an empty key or consumer name would start unsafely.
fn required(name: &str) -> String {
    need(&process_env, name).unwrap_or_else(|e| die(TAG, &e))
}

// What: connect to NATS, start helpers, apply records.
// Why: one process owns apply, reconcile and rollback.
#[tokio::main]
async fn main() {
    let nats_url = required("NATS_URL");
    let consumer_name = required("NATS_CONSUMER");
    let api_key = required("PDNS_API_KEY");
    // What: only a clear "off" disables record writes.
    // Why: an unknown spelling must keep replication on.
    let record_writes = env_opt("NATS_RECORD_WRITES").is_none_or(|v| parse_bool(&v) != Some(false));
    let reconcile = env_opt("NATS_RECONCILER").is_some_and(|v| parse_bool(&v) == Some(true));
    let keep = Uint {
        name: "KEEP_KNOWN_GOOD_CONFIGS",
        min: 1,
        max: u32::MAX.into(),
        below: OutOfRange::Reject,
        above: OutOfRange::Reject,
    };
    let (keep_n, warning) = keep
        .parse(env_opt("KEEP_KNOWN_GOOD_CONFIGS").as_deref())
        .unwrap_or_else(|error| die(TAG, &error));
    if let Some(warning) = warning {
        eprintln!("{warning}");
    }
    let snapshot_dir = required("DNS_CONFIG_SNAPSHOT_DIR");
    let rollback_addr = required("DNS_ROLLBACK_LISTEN_ADDR");

    let mut options = async_nats::ConnectOptions::new()
        .max_reconnects(None)
        .reconnect_delay_callback(|_| RECONNECT_DELAY);
    if let (Some(user), Some(password)) = (env_opt("NATS_USER"), env_opt("NATS_PASSWORD")) {
        options = options.user_and_password(user, password);
    } else if let Some(token) = env_opt("NATS_TOKEN") {
        options = options.token(token);
    }
    let client = options
        .connect(&nats_url)
        .await
        .unwrap_or_else(|e| die(TAG, &format!("failed to connect to NATS: {e}")));
    println!("Connected to NATS at {nats_url}");
    let js = jetstream::new(client);

    // What: a file-backed stream keeping messages 7 days.
    // Why: messages survive a restart; the oldest go first.
    let stream_config = jetstream::stream::Config {
        name: NATS_STREAM_DNS.to_string(),
        subjects: vec![NATS_SUBJECT_DNS.to_string()],
        storage: jetstream::stream::StorageType::File,
        max_age: Duration::from_secs(7 * 24 * 60 * 60),
        discard: jetstream::stream::DiscardPolicy::Old,
        ..Default::default()
    };
    let stream = js
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

    let http =
        http_client().unwrap_or_else(|e| die(TAG, &format!("cannot build HTTP client: {e}")));
    let ctx = Arc::new(Ctx {
        pdns: PowerDns::new(http, api_key),
        pdns_auth_url: required("PDNS_AUTH_API_URL"),
        pdns_rec_url: required("PDNS_REC_API_URL"),
        pdns_auth_config_dir: required("PDNS_AUTH_CONFIG_DIR"),
        snapshot_dir: PathBuf::from(snapshot_dir),
        keep_n: keep_n as u32,
        lock: tokio::sync::Mutex::new(()),
        js,
    });
    if reconcile {
        tokio::spawn(reconciler(ctx.clone()));
    }
    tokio::spawn(snapshot_watcher(ctx.clone()));
    tokio::spawn(serve_rollback(ctx.clone(), rollback_addr));

    // What: this loop alone applies records.
    // Why: so `applied` needs no lock.
    let mut applied = AppliedSequences::default();
    let mut backoff = 1u64;
    loop {
        let fetched = consumer
            .fetch()
            .max_messages(FETCH_BATCH)
            .expires(FETCH_WAIT)
            .messages()
            .await;
        let mut messages = match fetched {
            Ok(messages) => messages,
            Err(e) => {
                eprintln!("Fetch error: {e} (backing off for {backoff} second(s))");
                tokio::time::sleep(Duration::from_secs(backoff)).await;
                backoff = grow(backoff);
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
                _ => msg.ack_with(jetstream::AckKind::Nak(Some(NAK_DELAY))).await,
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
            eprintln!(
                "Stream error or retryable PDNS failure; backing off for {backoff} second(s)"
            );
            tokio::time::sleep(Duration::from_secs(backoff)).await;
            backoff = grow(backoff);
        } else {
            backoff = 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: build one rrset with a single record content.
    // Why: most tests need a small literal rrset.
    fn rrset(name: &str, kind: &str, ttl: i64, contents: &[&str]) -> Value {
        let records: Vec<Value> = contents
            .iter()
            .map(|c| json!({"content": c, "disabled": false}))
            .collect();
        json!({"name": name, "type": kind, "ttl": ttl, "records": records})
    }

    // What: the flush domain is encoded into the query.
    // Why: a message must not add or cut query parameters.
    #[test]
    fn flush_url_encodes_the_domain() {
        let url = flush_url("http://rec:8082/api/v1/servers/localhost", "a.lan.").unwrap();
        assert_eq!(url.query(), Some("domain=a.lan."));
        let url = flush_url("http://rec:8082/x", "a&b=1#c d").unwrap();
        assert_eq!(url.query(), Some("domain=a%26b%3D1%23c+d"));
        assert!(flush_url("not a url", "a.lan.").is_err());
    }

    // What: only the exact API key passes the header check.
    // Why: the key is the only gate of zone changes.
    #[test]
    fn authorized_requires_the_exact_key() {
        let with = |value: &str| {
            let mut headers = HeaderMap::new();
            headers.insert("X-API-Key", value.parse().unwrap());
            headers
        };
        assert!(authorized(&with("k1"), "k1"));
        assert!(!authorized(&with("k2"), "k1"));
        assert!(!authorized(&with(""), "k1"));
        assert!(!authorized(&HeaderMap::new(), "k1"));
    }

    // What: only plain zone names reach an API URL path.
    // Why: a NATS message must not steer the request path.
    #[test]
    fn zone_names_from_messages_must_be_plain() {
        for good in ["lan", "lan.", "10.in-addr.arpa.", "c.f.ip6.arpa."] {
            assert!(zone_is_safe(good), "{good:?} must pass");
        }
        for bad in ["", ".", "../x", "lan/../x", "a?b=1", "a#b", "a b", "lan%2F"] {
            assert!(!zone_is_safe(bad), "{bad:?} must fail");
        }
    }

    // What: a replace message with the TTL and records.
    // Why: patch_body tests share the same record literal.
    fn message(
        action: &str,
        ttl: Option<i32>,
        records: Option<Vec<HashMap<String, Value>>>,
    ) -> DnsRecord {
        DnsRecord {
            action: action.to_string(),
            zone: "lan".to_string(),
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl,
            records,
        }
    }

    // What: actions map to PATCH bodies; unknown ones fail.
    // Why: an unknown action must not reach PowerDNS.
    #[test]
    fn patch_body_covers_replace_delete_and_unknown() {
        let content = HashMap::from([("content".to_string(), json!("192.0.2.5"))]);
        let replace = patch_body(&message("replace", Some(3600), Some(vec![content]))).unwrap();
        let first = &replace["rrsets"][0];
        assert_eq!(first["changetype"], "REPLACE");
        assert_eq!(
            (
                first["ttl"].as_i64(),
                first["records"][0]["content"].as_str()
            ),
            (Some(3600), Some("192.0.2.5"))
        );
        let defaulted = patch_body(&message("replace", None, Some(vec![]))).unwrap();
        assert_eq!(defaulted["rrsets"][0]["ttl"], 300);
        assert_eq!(defaulted["rrsets"][0]["records"], json!([]));
        let bare = patch_body(&message("replace", Some(60), None)).unwrap();
        assert!(bare["rrsets"][0].get("records").is_none());
        let delete = patch_body(&message("delete", None, None)).unwrap();
        assert_eq!(delete["rrsets"][0]["changetype"], "DELETE");
        assert!(delete["rrsets"][0].get("ttl").is_none());
        assert!(patch_body(&message("bogus", None, None)).is_err());
    }

    // What: keys fold case and dots; marks never go down.
    // Why: one record from different publishers collides.
    // From: Issue #772
    #[test]
    fn applied_sequences_guard_stale_redeliveries_per_key() {
        let mut upper = message("replace", None, None);
        upper.zone = "LAN.".to_string();
        upper.name = "Host.LAN".to_string();
        upper.record_type = "a".to_string();
        let key = record_key(&upper);
        assert_eq!(
            key,
            ("lan".to_string(), "host.lan".to_string(), "A".to_string())
        );
        assert_eq!(key, record_key(&message("replace", None, None)));
        let mut applied = AppliedSequences::default();
        assert!(!applied.is_stale(&key, 5));
        applied.record(key.clone(), 10);
        applied.record(key.clone(), 7);
        assert!(applied.is_stale(&key, 7) && applied.is_stale(&key, 10));
        assert!(!applied.is_stale(&key, 11));
        let other = ("lan".to_string(), "other.lan".to_string(), "A".to_string());
        assert!(!applied.is_stale(&other, 1));
    }

    // What: flush confirmation compares content order-free.
    // Why: a stale or early zone must not allow the flush.
    // From: Issue #1095
    #[test]
    fn expected_content_confirmation_rules() {
        let found = rrset("host.lan.", "A", 60, &["192.0.2.6", "192.0.2.5"]);
        let both = ["192.0.2.5".to_string(), "192.0.2.6".to_string()];
        assert!(rrset_matches_expected(None, None, "A", None));
        assert!(!rrset_matches_expected(Some(&found), None, "A", None));
        assert!(!rrset_matches_expected(None, Some(&both), "A", None));
        assert!(rrset_matches_expected(Some(&found), Some(&both), "A", None));
        assert!(!rrset_matches_expected(
            Some(&found),
            Some(&both[..1]),
            "A",
            None
        ));
        assert!(rrset_matches_expected(
            Some(&found),
            Some(&both),
            "A",
            Some(60)
        ));
        assert!(!rrset_matches_expected(
            Some(&found),
            Some(&both),
            "A",
            Some(300)
        ));
        let v6 = rrset("host.lan.", "AAAA", 60, &["2001:db8::1"]);
        let long = ["2001:0DB8:0000:0000:0000:0000:0000:0001".to_string()];
        assert!(rrset_matches_expected(Some(&v6), Some(&long), "AAAA", None));
    }

    // What: SOA/NS drop out; reordered zones compare equal.
    // Why: rollback must not touch SOA/NS or see drift.
    #[test]
    fn data_rrsets_and_canonical_order() {
        let all = json!([
            rrset("lan.", "SOA", 3600, &["x"]),
            rrset("lan.", "NS", 3600, &["ns."]),
            rrset("b.lan.", "A", 60, &["2", "1"]),
            rrset("a.lan.", "A", 60, &["1"]),
        ]);
        let data = data_rrsets(&all);
        assert_eq!(data.as_array().map(Vec::len), Some(2));
        let reordered = json!([
            rrset("a.lan.", "A", 60, &["1"]),
            rrset("b.lan.", "A", 60, &["1", "2"])
        ]);
        assert_eq!(canonicalize(&data), canonicalize(&reordered));
        assert_ne!(
            canonicalize(&data),
            canonicalize(&json!([rrset("a.lan.", "A", 60, &["9"])]))
        );
    }

    // What: rollback replaces changed, deletes extras only.
    // Why: unchanged rrsets stay out; flush names precise.
    #[test]
    fn rollback_patch_replaces_deletes_and_omits_unchanged() {
        let snapshot = json!([
            rrset("same.lan.", "A", 60, &["1"]),
            rrset("old.lan.", "A", 60, &["1"]),
            rrset("gone.lan.", "A", 60, &["3"])
        ]);
        let current = json!([
            rrset("same.lan.", "A", 60, &["1"]),
            rrset("old.lan.", "A", 60, &["2"]),
            rrset("new.lan.", "A", 60, &["4"])
        ]);
        let patch = rollback_patch(&snapshot, &current);
        let list = patch["rrsets"].as_array().unwrap();
        let find = |name: &str| list.iter().find(|r| r["name"] == name);
        assert_eq!(list.len(), 3);
        assert!(find("same.lan.").is_none());
        assert_eq!(find("old.lan.").unwrap()["changetype"], "REPLACE");
        assert_eq!(find("gone.lan.").unwrap()["changetype"], "REPLACE");
        assert_eq!(find("new.lan.").unwrap()["changetype"], "DELETE");
        assert!(find("new.lan.").unwrap().get("records").is_none());
        let restore = rollback_patch(&snapshot, &json!([]));
        assert_eq!(restore["rrsets"].as_array().map(Vec::len), Some(3));
    }

    // What: changed names are unique, in first-seen order.
    // Why: each name is flushed from the caches once.
    #[test]
    fn changed_names_deduplicates_in_order() {
        let patch = json!({"rrsets": [
            {"name": "a.lan.", "type": "A"}, {"name": "b.lan.", "type": "A"}, {"name": "a.lan.", "type": "AAAA"}]});
        assert_eq!(changed_names(&patch), ["a.lan.", "b.lan."]);
        assert!(changed_names(&json!({})).is_empty());
    }

    // What: an rrset becomes a record message when keyed.
    // Why: reconciler and rollback republish through this.
    #[test]
    fn rrset_record_requires_name_and_type() {
        let record = rrset_record("replace", "lan", &rrset("h.lan.", "A", 60, &["1"])).unwrap();
        assert_eq!(
            (record.ttl, record.records.map(|r| r.len())),
            (Some(60), Some(1))
        );
        let delete = rrset_record(
            "delete",
            "lan",
            &json!({"name": "h.lan.", "type": "A", "changetype": "DELETE"}),
        )
        .unwrap();
        assert!(delete.ttl.is_none() && delete.records.is_none());
        assert!(rrset_record("replace", "lan", &json!({"name": "h.lan."})).is_none());
    }

    // What: the retry delay doubles up to 30 seconds.
    // Why: bounded backoff stops a dead stream spinning.
    #[test]
    fn backoff_doubles_and_caps() {
        assert_eq!(grow(1), 2);
        assert_eq!(grow(16), 30);
        assert_eq!(grow(30), 30);
    }
}
