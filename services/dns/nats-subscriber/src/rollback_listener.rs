//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Local HTTP listener (#628) the Admin UI calls to list PowerDNS zone/
//! record known-good snapshots and trigger an operator-selected rollback.
//! See docs/known-good-config-snapshots.md's "Zones, records, and TSIG/DDNS
//! metadata" section, "Applying a rollback stays operator-selected, never
//! automatic" and "The rollback listener must require authentication".
//!
//! Runs inside the `dns-standard`/`dns-ssl` container alongside PowerDNS's
//! own Authoritative (8081) and Recursor (8082) HTTP APIs, on a new port
//! (`DNS_ROLLBACK_LISTEN_ADDR`, default `0.0.0.0:8083`). Bound to `0.0.0.0`,
//! not `127.0.0.1`: containers have separate network namespaces, so a
//! loopback-only bind would make this unreachable from the Admin UI's own
//! container. "container-local" in the design doc's defense-in-depth note
//! means not published to the host/LAN via docker-compose `ports:` --
//! `deploy/*/docker-compose.yml` uses `expose:` for this port, the same
//! treatment PowerDNS's own 8081/8082 already get, so it stays reachable
//! only from other containers on the same Compose network, never from the
//! LAN directly. Every request still requires `X-API-Key` regardless (see
//! `check_api_key`) -- network placement is defense-in-depth here, not the
//! trust boundary itself.
//!
//! Every request must include `X-API-Key: <PDNS_API_KEY>`, the same
//! convention `handle_dns_record`/`reconciler` already use to call
//! PowerDNS's own API, and the same header `services/ui/src/routes/
//! domains.rs` sends. This is a control-plane endpoint (list + mutate zone
//! data), not a read-only status page, so it is never trusted on Compose
//! network placement alone -- matching every other comparable internal
//! surface in this project (PowerDNS's own API, the NATS auth-callout, #583).

use crate::{nats_publish, zone_snapshots};
use async_nats::jetstream;
use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use futures::future::join_all;
use reqwest::Client;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

pub struct RollbackState {
    pub http_client: Arc<Client>,
    pub pdns_api_key: String,
    pub snapshot_base_dir: PathBuf,
    pub keep_n: u32,
    // Shared with the periodic zone-snapshot watcher and the NATS consumer
    // loop's post-PATCH snapshot trigger AND its live-write PATCH itself
    // (main.rs), so a rollback in progress never interleaves with an
    // unrelated snapshot-creation tick for the same zone, and -- since
    // bug-hunt finding #5's fix (docs/bug-hunt/dns.md, re-verified
    // 2026-08-06) -- never interleaves with a concurrent live DNS record
    // write either, closing a TOCTOU window where a rollback could
    // compute its revert-to-known-good patch from already-stale data and
    // silently undo a legitimate concurrent write.
    pub snapshot_lock: Arc<Mutex<()>>,
    pub js: jetstream::Context,
}

#[derive(Deserialize)]
struct RollbackRequest {
    zone: String,
    snapshot_id: String,
}

/// Constant-time-ish comparison for the `X-API-Key` header against the
/// configured `PDNS_API_KEY`: XORs every byte instead of short-circuiting on
/// the first mismatch, so a timing side channel can't be used to guess the
/// key one byte at a time. The length check does still leak key length via
/// timing, same accepted trade-off `subtle`-style constant-time comparisons
/// make; not worth a new dependency for a container-internal control-plane
/// listener that's also gated by Compose network placement (see module doc).
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn check_api_key(headers: &HeaderMap, expected: &str) -> bool {
    headers
        .get("X-API-Key")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|got| constant_time_eq(got, expected))
}

fn unauthorized() -> axum::response::Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({"error": "missing or invalid X-API-Key"})),
    )
        .into_response()
}

async fn list_snapshots_handler(
    State(state): State<Arc<RollbackState>>,
    headers: HeaderMap,
) -> axum::response::Response {
    if !check_api_key(&headers, &state.pdns_api_key) {
        return unauthorized();
    }

    let mut zones: HashMap<&str, Vec<Value>> = HashMap::new();
    for &zone in zone_snapshots::ROLLBACK_ZONES {
        let root = zone_snapshots::zone_snapshot_root(&state.snapshot_base_dir, zone);
        let ids = zone_snapshots::list_snapshot_ids(&root).unwrap_or_default();
        // Newest first for display, matching the Kea snapshot list's
        // ordering on the /dhcp page.
        let summaries: Vec<Value> = ids
            .into_iter()
            .rev()
            .map(|id| {
                let created_unix = zone_snapshots::snapshot_created_unix(&id).unwrap_or(0);
                json!({"id": id, "created_unix": created_unix})
            })
            .collect();
        zones.insert(zone, summaries);
    }

    (StatusCode::OK, Json(json!({ "zones": zones }))).into_response()
}

// Runs `pdnsutil check-zone` as the secondary structural sanity check
// docs/known-good-config-snapshots.md describes: SOA serial sanity,
// dangling CNAME targets, delegation consistency -- none of which the API's
// per-RR validation catches. This is informational/confirmation-only, run
// AFTER the rollback PATCH already succeeded: a failure here does not (and
// cannot, without a second rollback-the-rollback mechanism this design does
// not build) automatically revert the already-applied change. It is logged
// as a REJECT and surfaced in the response body so an operator knows to
// inspect the zone by hand.
// Bug-hunt finding #16 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
// `.output()` blocks until the child exits with no timeout at all -- a
// stuck `pdnsutil check-zone` (e.g. a wedged/locked PowerDNS auth database,
// the exact failure class the known-good-snapshot rollback mechanism exists
// to recover from) would hang the calling `tokio::task::spawn_blocking`
// thread forever, silently consuming a blocking-pool slot per stuck call
// with no operator-visible symptom beyond the rollback response itself
// never completing. `std::process::Command` has no built-in timeout, so
// this polls `try_wait()` on a manually spawned child instead of adding a
// new crate dependency (Rule-Ref: AG-REL-001) for one call site. 10s
// mirrors this file's own reqwest client timeout convention
// (nats-subscriber/src/main.rs's `.timeout(Duration::from_secs(10))`) --
// `check-zone` is a local, in-process AXFR-free validation pass over an
// already-loaded zone, not a network call, so 10s is generous rather than
// tight for the real, expected case.
const CHECK_ZONE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

fn run_check_zone(zone: &str) -> bool {
    match std::process::Command::new("pdnsutil")
        .args(["--config-dir=/etc/pdns/auth", "check-zone", zone])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => wait_with_timeout(
            child,
            CHECK_ZONE_TIMEOUT,
            &format!("pdnsutil check-zone for {zone}"),
        ),
        Err(e) => {
            eprintln!(
                "[known-good-snapshot][dns][WARNING] failed to run pdnsutil check-zone for {zone}: {e}"
            );
            false
        }
    }
}

// wait_with_timeout <child> <timeout> <description_for_log>
// Polls an already-spawned child for exit, killing it and returning `false`
// if it hasn't exited by the deadline. Split out from run_check_zone() so
// the actual timeout/kill mechanism (the part bug-hunt finding #16 is
// about) can be exercised directly in tests against a real, controllable
// child process, without needing to fake the `pdnsutil` binary itself on
// PATH.
fn wait_with_timeout(
    mut child: std::process::Child,
    timeout: std::time::Duration,
    description: &str,
) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    eprintln!(
                        "[known-good-snapshot][dns][WARNING] {description} did not finish within {timeout:?}, killing it and treating the check as failed"
                    );
                    // Best-effort: the process may have already exited in
                    // the race between try_wait() and here, or already be
                    // gone -- either way there's nothing further to clean
                    // up on this path, and returning `false` (check failed)
                    // is the safe verdict for an unverifiable zone.
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Err(e) => {
                eprintln!(
                    "[known-good-snapshot][dns][WARNING] failed to poll {description}: {e}"
                );
                return false;
            }
        }
    }
}

// Re-publishes the applied rollback patch's REPLACE/DELETE entries onto
// `lancache.dns.record`, only ever called for the `lan.` zone (see the call
// site in `rollback_handler`). This is the "how does a rollback on the
// primary interact with existing NATS replication" answer
// docs/known-good-config-snapshots.md's "Secondary nodes and NATS
// replication" section leaves open for the implementation PR: `lan.` is the
// one zone with existing NATS replication (every dns-standard/dns-ssl/
// dns-secondary node runs its own nats-subscriber consuming the same
// stream), so without this, a rollback would only ever change the node
// `nats-subscriber`'s own listener is running in, silently leaving every
// other node's `lan.` data diverged from the just-rolled-back state until
// the next 60-second reconciler tick happens to paper over it (the
// reconciler only republishes the CURRENT state, so it eventually converges
// on its own, but this closes the gap immediately rather than leaving it to
// chance timing).
//
// Each entry gets a fresh, rollback-specific message id (`rollback-<nanos
// batch stamp>-<name>-<type>`) rather than reusing the reconciler's stable
// `reconcile-lan-<name>-<type>` id: JetStream's ~120s duplicate-message
// window could otherwise silently absorb this explicit republish if the
// periodic reconciler happened to publish an identical id moments earlier,
// which would defeat the whole point of "re-publish immediately after a
// rollback" (the doc's rationale for adding this republish step in the
// first place).
async fn publish_rollback_records(js: &jetstream::Context, zone_field: &str, patch: &Value) {
    let batch_stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let Some(rrsets) = patch.get("rrsets").and_then(Value::as_array) else {
        return;
    };
    for rrset in rrsets {
        let (Some(name), Some(record_type)) = (
            rrset.get("name").and_then(Value::as_str),
            rrset.get("type").and_then(Value::as_str),
        ) else {
            continue;
        };
        let changetype = rrset
            .get("changetype")
            .and_then(Value::as_str)
            .unwrap_or("REPLACE");
        let action = if changetype == "DELETE" {
            "delete"
        } else {
            "replace"
        };
        let ttl = rrset.get("ttl").cloned().unwrap_or(Value::Null);
        let records = rrset.get("records").cloned().unwrap_or(Value::Null);
        let msg_id = format!(
            "rollback-{batch_stamp}-{}-{record_type}",
            name.trim_end_matches('.')
        );
        nats_publish::publish_dns_record(
            js,
            &msg_id,
            nats_publish::DnsRecordMessage {
                action,
                zone: zone_field,
                name,
                record_type,
                ttl,
                records,
            },
        )
        .await;
    }
}

/// Rollback sequence (docs/known-good-config-snapshots.md): auth check ->
/// zone against the `ROLLBACK_ZONES` whitelist -> `snapshot_id` against
/// `list_snapshot_ids` (this handler's path-traversal guard, mirroring
/// `services/ui/src/routes/dhcp.rs::rollback_kea_snapshot`'s identical
/// membership check before ever reading the snapshot file) -> diff (SOA/NS
/// excluded from both sides) -> `PATCH` -> `pdnsutil check-zone` as a
/// post-apply confirmation -> for `lan.` only, re-publish the restored
/// records so replicated secondaries converge -> flush every changed name
/// from both recursors (via one `lancache.dns.flush` publish per name --
/// both dns-standard's and dns-ssl's own `nats-subscriber` consume that
/// subject and flush their own local recursor, so this single publish
/// reaches both without this process reaching across containers itself) ->
/// record a fresh known-good snapshot of the now-current (post-rollback)
/// state, mirroring Kea's own rollback behavior of snapshotting the
/// restored config. The record republish runs to completion before the
/// flush starts (not the other way around): flushing first would let a
/// query in the gap between the flush and the record update repopulate a
/// node's packet cache from the still-stale pre-rollback answer, with no
/// second flush afterwards to clear it back out.
///
/// The cache-flush publish above requires the running identity
/// (`NATS_DNS_WRITER_USER` on dns-standard, `NATS_DNS_REPLICA_USER` on
/// dns-ssl) to actually hold `publish` on `lancache.dns.flush` in
/// `nats.conf`/the compose-generated equivalent -- previously neither did,
/// so nats-server silently denied every flush and the response still
/// claimed `applied: true` with no way for a caller to tell. Both the JS
/// send AND its ack are awaited per name now (`state.js.publish(...).await`
/// for the send, then the returned `PublishAckFuture` for JetStream's
/// confirmation the message actually reached the stream -- mirroring
/// `nats_publish::publish_dns_record`'s existing double-await pattern),
/// because a permission-denied publish is dropped server-side without a
/// synchronous error on the first await; the failure only ever surfaces as
/// the ack never arriving. Every name's publish+ack runs concurrently and is
/// individually timeout-bounded (see `FLUSH_ACK_TIMEOUT` at the call site);
/// any name whose flush send, ack, or overall wait fails is collected into
/// `flush_failed_names` and surfaced in the response body
/// (`rollback_response_body`) as `flush_ok`/`flush_failed_names`, instead of
/// only an `eprintln!` warning nobody calling this endpoint ever sees.
async fn rollback_handler(
    State(state): State<Arc<RollbackState>>,
    headers: HeaderMap,
    body_bytes: axum::body::Bytes,
) -> axum::response::Response {
    // Auth is checked before the body is even parsed (a raw `Bytes`
    // extractor, not `Json<RollbackRequest>` as a handler parameter): axum
    // extractors run in parameter order and a `Json<T>` extractor rejects
    // malformed input before the handler body ever runs, which would let an
    // UNauthenticated caller reach a JSON-parse error response without ever
    // hitting the X-API-Key check. This listener is a control-plane
    // endpoint (module doc comment), so auth must be the very first thing
    // checked, before anything about the request body is even inspected.
    if !check_api_key(&headers, &state.pdns_api_key) {
        return unauthorized();
    }

    let body: RollbackRequest = match serde_json::from_slice(&body_bytes) {
        Ok(b) => b,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error": format!("invalid request body: {e}")})),
            )
                .into_response();
        }
    };

    let zone = zone_snapshots::canonical_zone(&body.zone);
    if !zone_snapshots::is_rollback_zone(&zone) {
        return (
            StatusCode::BAD_REQUEST,
            Json(
                json!({"error": format!("zone {zone} is not managed by this rollback mechanism")}),
            ),
        )
            .into_response();
    }

    let root = zone_snapshots::zone_snapshot_root(&state.snapshot_base_dir, &zone);
    let known_ids = match zone_snapshots::list_snapshot_ids(&root) {
        Ok(ids) => ids,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": format!("failed to list known-good snapshots: {e}")})),
            )
                .into_response();
        }
    };
    if !known_ids.iter().any(|id| id == &body.snapshot_id) {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"error": "unknown or no-longer-available snapshot"})),
        )
            .into_response();
    }

    let snapshot_data = match zone_snapshots::read_snapshot(&root, &body.snapshot_id) {
        Ok(v) => zone_snapshots::filter_data_rrsets(&v),
        Err(e) => {
            zone_snapshots::kgs_log(
                "REJECT",
                &format!(
                    "rejected known-good snapshot {} for zone {zone}: unreadable ({e})",
                    body.snapshot_id
                ),
            );
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": format!("stored snapshot could not be read: {e}")})),
            )
                .into_response();
        }
    };

    // Bug-hunt finding #5 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
    // this used to be acquired much later, right before applying the patch
    // -- after already reading the zone's current state and computing the
    // revert-to-known-good diff from it below. That left a real TOCTOU
    // window: a live NATS-driven write (main.rs's handle_dns_record, which
    // now also takes this same lock around its own PATCH, see that file)
    // landing between the read here and the old, later lock acquisition
    // meant this handler could compute its patch from data that was
    // already stale by the time it actually applied it, silently
    // reverting a legitimate concurrent write neither side would ever
    // notice happened. Taking the lock before the read instead makes the
    // whole read+diff+apply+confirm+republish sequence atomic with respect
    // to a live write, not just with respect to another concurrent
    // rollback/snapshot (see the `snapshot_lock` field doc comment on
    // `RollbackState` for that original, narrower purpose this extends).
    let _guard = state.snapshot_lock.lock().await;

    let zone_api_id = zone_snapshots::zone_api_id(&zone);
    let get_url = format!("http://127.0.0.1:8081/api/v1/servers/localhost/zones/{zone_api_id}");
    let current_resp = match state
        .http_client
        .get(&get_url)
        .header("X-API-Key", &state.pdns_api_key)
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(json!({"error": format!("PowerDNS returned {} fetching current zone state", r.status())})),
            )
                .into_response()
        }
        Err(e) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(json!({"error": format!("failed to fetch current zone state: {e}")})),
            )
                .into_response()
        }
    };
    let current_json: Value = match current_resp.json().await {
        Ok(v) => v,
        Err(e) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(json!({"error": format!("failed to decode current zone state: {e}")})),
            )
                .into_response();
        }
    };
    let current_rrsets = current_json
        .get("rrsets")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let current_data = zone_snapshots::filter_data_rrsets(&current_rrsets);

    let patch = zone_snapshots::build_rollback_patch(&snapshot_data, &current_data);
    let patch_len = patch
        .get("rrsets")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);

    // `_guard` (acquired above, before the current-state read) is still
    // held here -- it stays in scope for the rest of this function, across
    // the whole read+diff+apply+confirm+republish sequence.
    if patch_len > 0 {
        let patch_url =
            format!("http://127.0.0.1:8081/api/v1/servers/localhost/zones/{zone_api_id}");
        // Manual body/Content-Type, matching main.rs's handle_dns_record
        // PATCH call style (`.body(payload)` + explicit header) rather than
        // reqwest's `.json()` convenience, for one consistent PATCH-building
        // convention across this crate.
        let patch_body = match serde_json::to_string(&patch) {
            Ok(p) => p,
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"error": format!("failed to serialize rollback patch: {e}")})),
                )
                    .into_response();
            }
        };
        let patch_result = state
            .http_client
            .patch(&patch_url)
            .header("X-API-Key", &state.pdns_api_key)
            .header("Content-Type", "application/json")
            .body(patch_body)
            .send()
            .await;
        match patch_result {
            Ok(r) if r.status().is_success() => {}
            Ok(r) => {
                zone_snapshots::kgs_log(
                    "REJECT",
                    &format!(
                        "rollback PATCH for zone {zone} snapshot {} failed: PowerDNS returned {}",
                        body.snapshot_id,
                        r.status()
                    ),
                );
                return (
                    StatusCode::BAD_GATEWAY,
                    Json(json!({"error": format!("PowerDNS rejected rollback PATCH: {}", r.status())})),
                )
                    .into_response();
            }
            Err(e) => {
                zone_snapshots::kgs_log(
                    "REJECT",
                    &format!(
                        "rollback PATCH for zone {zone} snapshot {} failed: {e}",
                        body.snapshot_id
                    ),
                );
                return (
                    StatusCode::BAD_GATEWAY,
                    Json(json!({"error": format!("failed to apply rollback PATCH: {e}")})),
                )
                    .into_response();
            }
        }
    }

    zone_snapshots::kgs_log(
        "SELECT",
        &format!(
            "selected known-good snapshot {} for rollback of zone {zone} ({patch_len} rrset(s) changed)",
            body.snapshot_id
        ),
    );

    let zone_check_passed = tokio::task::spawn_blocking({
        let zone = zone.clone();
        move || run_check_zone(&zone)
    })
    .await
    .unwrap_or(false);
    if !zone_check_passed {
        zone_snapshots::kgs_log(
            "REJECT",
            &format!(
                "post-rollback pdnsutil check-zone failed for zone {zone} -- the rollback PATCH was already applied and is NOT automatically reverted; inspect the zone manually"
            ),
        );
    }

    let changed = zone_snapshots::changed_names(&patch);

    // Re-publish restored `lan.` records to NATS BEFORE flushing any
    // recursor cache below, and awaited to completion before the flush loop
    // starts: every dns-standard/dns-ssl node's own nats-subscriber consumes
    // `lancache.dns.record` and `lancache.dns.flush` independently, so if a
    // node's flush arrived first, a query landing in the window between the
    // flush and the record update would repopulate that node's packet cache
    // from the still-stale pre-rollback answer -- and since each name below
    // is only flushed once, that stale entry would then persist until its
    // own TTL, not until the record update actually arrived moments later.
    // Doing the record republish first means every node's authoritative
    // data is already updated by the time its cache gets cleared, so
    // whatever a query repopulates the cache with next is the correct,
    // post-rollback answer.
    let mut republished_to_nats = false;
    if zone == "lan." && patch_len > 0 {
        publish_rollback_records(&state.js, "lan", &patch).await;
        republished_to_nats = true;
    }

    // Cache-flush publish per changed name. Names whose flush did not both
    // send AND get JetStream-acked (or that didn't finish within
    // `FLUSH_ACK_TIMEOUT`) are surfaced in the response body below
    // (`flush_ok`/`flush_failed_names`) instead of only logged, since a
    // NATS-permission gap or a down recursor previously left `applied: true`
    // with no way for a caller to tell the flush never really happened.
    // Note what this signal does and doesn't prove: a JetStream ack only
    // confirms the message reached the stream durably, not that a consumer
    // (`handle_dns_flush` in main.rs) actually executed the recursor flush
    // -- a consumer-side failure there is only NAKed and retried in the
    // background, with no path back to this response. Closing that
    // remaining gap needs a request-reply protocol (a reply subject this
    // handler could await, aggregated across however many consumer
    // instances are subscribed), which is a bigger change than this
    // response alone can make; `flush_ok` here means "durably queued for
    // delivery", not "every recursor definitively cleared its cache".
    //
    // Published concurrently rather than one `for` loop `.await` at a time:
    // async-nats' JetStream context defaults to a 5s timeout for the send
    // and up to another 5s for the ack, so N names in serial could take up
    // to N * 10s -- exceeding the Admin UI's own 10s HTTP client timeout for
    // this call once N reaches 3. Running every name's publish+ack
    // concurrently bounds the whole batch's wall time to roughly one name's
    // worst case instead of the sum of all of them. Each future is also
    // capped at `FLUSH_ACK_TIMEOUT` (3s -- comfortably inside that 10s
    // budget even after accounting for the PATCH/check-zone/snapshot work
    // already done above, since the flush phase now runs as one bounded
    // concurrent batch rather than a per-name multiple of the JetStream
    // default): a name that times out is treated the same as an explicit
    // publish/ack failure, so a slow ack can never silently read as success
    // just because this future gave up waiting for it.
    const FLUSH_ACK_TIMEOUT: Duration = Duration::from_secs(3);
    let flush_futures = changed.iter().map(|name| {
        // Cloned per name rather than moving `state` itself into the
        // future: `state` (the whole `Arc<RollbackState>`) is still needed
        // after this batch completes (e.g. `state.keep_n` below), and this
        // closure runs once per changed name, so it can't move the same
        // `Arc` out of its environment more than once. `jetstream::Context`
        // is designed to be cheaply cloneable (it's the same pattern
        // `nats_publish`'s callers already rely on when sharing one
        // connection across many publishes).
        let js = state.js.clone();
        async move {
            let flush_payload = json!({"domain": name});
            let bytes = match serde_json::to_vec(&flush_payload) {
                Ok(b) => b,
                Err(e) => {
                    eprintln!(
                        "[known-good-snapshot][dns][WARNING] failed to marshal cache-flush for {name}: {e}"
                    );
                    return Some(name.clone());
                }
            };
            let flush_result = tokio::time::timeout(FLUSH_ACK_TIMEOUT, async {
                // Two awaits, matching `nats_publish::publish_dns_record`'s
                // established pattern: the first only confirms the message was
                // handed to the connection, not that nats-server accepted it. A
                // subject-permission denial is enforced server-side and dropped
                // silently -- it never comes back as an error on this first
                // await, only as the second await's ack never arriving.
                match js.publish("lancache.dns.flush", bytes.into()).await {
                    Ok(publish_ack) => publish_ack.await.map_err(|e| e.to_string()),
                    Err(e) => Err(e.to_string()),
                }
            })
            .await;
            match flush_result {
                Ok(Ok(_)) => None,
                Ok(Err(e)) => {
                    eprintln!(
                        "[known-good-snapshot][dns][WARNING] cache-flush for {name} after rollback was not acknowledged by JetStream (missing publish permission or an unreachable stream): {e}"
                    );
                    Some(name.clone())
                }
                Err(_) => {
                    eprintln!(
                        "[known-good-snapshot][dns][WARNING] cache-flush for {name} after rollback did not complete within {FLUSH_ACK_TIMEOUT:?}; treating it as failed rather than letting a slow ack silently pass as a success"
                    );
                    Some(name.clone())
                }
            }
        }
    });
    let flush_failed_names: Vec<String> = join_all(flush_futures)
        .await
        .into_iter()
        .flatten()
        .collect();

    // Record the restored state as a fresh known-good snapshot, mirroring
    // Kea's own rollback behavior (services/ui/src/routes/dhcp.rs's
    // kea_config_modify chain snapshots on every confirmed write, including
    // a rollback). Post-rollback current == snapshot_data by construction
    // (every differing rrset was REPLACEd from it, every extra current
    // rrset not in it was DELETEd), so no fresh GET is needed here -- but it
    // still goes through the normal skip-if-unchanged check, since the
    // snapshot being rolled back to could already equal the most recently
    // recorded one (e.g. rolling back to undo unrelated DDNS drift that
    // happened to leave the zone matching an already-captured point).
    if patch_len > 0
        && !zone_snapshots::matches_latest_snapshot(&root, &snapshot_data)
        && let Err(e) = zone_snapshots::create_snapshot(&root, state.keep_n, &snapshot_data)
    {
        zone_snapshots::kgs_log(
            "FATAL",
            &format!("failed to record post-rollback known-good snapshot for zone {zone}: {e}"),
        );
    }

    (
        StatusCode::OK,
        Json(rollback_response_body(
            &changed,
            zone_check_passed,
            republished_to_nats,
            &flush_failed_names,
        )),
    )
        .into_response()
}

/// Builds the `/rollback` JSON response body. Pulled out as its own pure
/// function (no `RollbackState`/network access) so a cache-flush failure
/// actually reaching the response as `flush_ok: false` /
/// `flush_failed_names: [...]`, rather than only an `eprintln!` warning
/// with the body still claiming unqualified success, is unit-testable
/// without a live NATS/PowerDNS connection. `applied` keeps its existing
/// meaning ("the rollback PATCH itself was applied to PowerDNS"); flush
/// success is a separate, independently-checkable signal now, not folded
/// into it, since a caller that only checks `applied` today must keep
/// working unchanged.
fn rollback_response_body(
    changed_names: &[String],
    zone_check_passed: bool,
    republished_to_nats: bool,
    flush_failed_names: &[String],
) -> Value {
    json!({
        "applied": true,
        "changed_names": changed_names,
        "zone_check_passed": zone_check_passed,
        "republished_to_nats": republished_to_nats,
        "flush_ok": flush_failed_names.is_empty(),
        "flush_failed_names": flush_failed_names,
    })
}

pub fn router(state: Arc<RollbackState>) -> Router {
    Router::new()
        .route("/snapshots", get(list_snapshots_handler))
        .route("/rollback", post(rollback_handler))
        .with_state(state)
}

pub async fn serve(addr: &str, state: Arc<RollbackState>) {
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!(
                "[known-good-snapshot][dns][FATAL] zone-rollback listener failed to bind {addr}: {e}"
            );
            return;
        }
    };
    println!("Zone-rollback listener ready on {addr}");
    if let Err(e) = axum::serve(listener, router(state)).await {
        eprintln!("[known-good-snapshot][dns][FATAL] zone-rollback listener stopped: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    // Constant-time comparison must never short-circuit on mismatch, preventing
    // timing-side-channel attacks that could allow guessing the API key byte-by-byte.
    #[test]
    fn constant_time_eq_matches_equal_strings_and_rejects_mismatches() {
        assert!(constant_time_eq("secret-key", "secret-key"));
        assert!(!constant_time_eq("secret-key", "different-key"));
        assert!(!constant_time_eq("short", "muchlongerkey"));
        assert!(!constant_time_eq("", "nonempty"));
        assert!(constant_time_eq("", ""));
    }

    // API key validation must reject partial/wrong headers and missing headers,
    // preventing unauthorized access to this control-plane rollback endpoint.
    #[test]
    fn check_api_key_requires_exact_header_match() {
        let mut headers = HeaderMap::new();
        headers.insert("X-API-Key", HeaderValue::from_static("correct-key"));
        assert!(check_api_key(&headers, "correct-key"));
        assert!(!check_api_key(&headers, "wrong-key"));

        let empty_headers = HeaderMap::new();
        assert!(!check_api_key(&empty_headers, "correct-key"));
    }

    // The request struct must parse the exact JSON format the Admin UI sends,
    // ensuring the serialization contract between the UI and this rollback handler is stable.
    #[test]
    fn rollback_request_deserializes_from_the_json_body_the_admin_ui_sends() {
        let body = r#"{"zone": "lan.", "snapshot_id": "00000000001234567890"}"#;
        let req: RollbackRequest = serde_json::from_str(body).expect("must deserialize");
        assert_eq!(req.zone, "lan.");
        assert_eq!(req.snapshot_id, "00000000001234567890");
    }

    // Missing snapshot_id must fail deserialization, preventing incomplete requests
    // from reaching the handler where they'd cause confusing errors downstream.
    #[test]
    fn rollback_request_rejects_a_body_missing_snapshot_id() {
        let body = r#"{"zone": "lan."}"#;
        assert!(serde_json::from_str::<RollbackRequest>(body).is_err());
    }

    // These two cover the actual bug: the `/rollback` response body used to
    // claim `applied: true` with zero signal of whether the post-rollback
    // cache-flush actually reached the recursor. Both go through the exact
    // function `rollback_handler` calls to build its response, not a
    // reimplementation of it.
    #[test]
    fn rollback_response_reports_flush_ok_when_every_name_flushed() {
        let changed = vec!["steamcontent.com".to_string(), "akamai.net".to_string()];
        let body = rollback_response_body(&changed, true, false, &[]);
        assert_eq!(body["applied"], json!(true));
        assert_eq!(body["flush_ok"], json!(true));
        assert_eq!(body["flush_failed_names"], json!(Vec::<String>::new()));
        assert_eq!(body["changed_names"], json!(changed));
        assert_eq!(body["zone_check_passed"], json!(true));
        assert_eq!(body["republished_to_nats"], json!(false));
    }

    // Cache-flush failures must be reported separately from the PATCH success,
    // preventing callers from misinterpreting a partial failure as complete success.
    #[test]
    fn rollback_response_surfaces_flush_failure_instead_of_silently_claiming_success() {
        let changed = vec!["steamcontent.com".to_string(), "akamai.net".to_string()];
        let flush_failed = vec!["steamcontent.com".to_string()];
        let body = rollback_response_body(&changed, true, true, &flush_failed);
        // The PATCH itself still applied -- that part of the claim is true --
        // but the flush signal must now be distinguishable from success,
        // instead of the response uniformly claiming everything succeeded.
        assert_eq!(body["applied"], json!(true));
        assert_eq!(body["flush_ok"], json!(false));
        assert_eq!(body["flush_failed_names"], json!(flush_failed));
    }

    // Complete flush failure (all names) must be reported as flush_ok: false
    // so callers can distinguish between partial and total cache-flush failures.
    #[test]
    fn rollback_response_flush_ok_is_false_when_every_name_fails() {
        let changed = vec!["steamcontent.com".to_string()];
        let body = rollback_response_body(&changed, true, false, &changed);
        assert_eq!(body["flush_ok"], json!(false));
        assert_eq!(body["flush_failed_names"], json!(changed));
    }

    // Bug-hunt finding #16 (docs/bug-hunt/dns.md, re-verified 2026-08-06):
    // these exercise wait_with_timeout() directly against a real, spawned
    // `sh` child (not the `pdnsutil` binary itself, which isn't guaranteed
    // present in a plain `cargo test` environment) -- proving the actual
    // timeout/kill mechanism the fix adds, not a reimplementation of it.

    // The common, expected case: a process that exits well within the
    // timeout must report its real exit status, not be treated as timed out.
    #[test]
    fn wait_with_timeout_returns_true_for_a_fast_successful_process() {
        let child = std::process::Command::new("sh")
            .args(["-c", "exit 0"])
            .spawn()
            .expect("sh must be available to run this test");
        assert!(wait_with_timeout(
            child,
            std::time::Duration::from_secs(5),
            "test"
        ));
    }

    // A process that exits quickly but with a real failure status must
    // still be reported as failed, not conflated with a timeout.
    #[test]
    fn wait_with_timeout_returns_false_for_a_fast_failing_process() {
        let child = std::process::Command::new("sh")
            .args(["-c", "exit 1"])
            .spawn()
            .expect("sh must be available to run this test");
        assert!(!wait_with_timeout(
            child,
            std::time::Duration::from_secs(5),
            "test"
        ));
    }

    // This is the actual regression case finding #16 is about: before this
    // fix, a hung child (e.g. a wedged pdnsutil against a locked PowerDNS
    // database) would block the caller forever. A short timeout here proves
    // the function returns `false` promptly instead of hanging, and that
    // the child is actually killed rather than left running.
    #[test]
    fn wait_with_timeout_kills_and_returns_false_for_a_process_that_never_exits() {
        let mut child = std::process::Command::new("sh")
            .args(["-c", "sleep 60"])
            .spawn()
            .expect("sh must be available to run this test");
        let pid = child.id();

        let started = std::time::Instant::now();
        // Reuse the same child handle wait_with_timeout will kill, but keep
        // our own copy of the pid (taken above) so this test can still
        // verify the process is really gone afterward, since
        // wait_with_timeout() consumes `child` by value.
        let timed_out_result = wait_with_timeout(child, std::time::Duration::from_millis(100), "test");
        let elapsed = started.elapsed();

        assert!(!timed_out_result);
        // Generous upper bound: the real timeout is 100ms plus at most one
        // 20ms poll interval: this asserts it returned promptly rather than
        // waiting anywhere near the 60s the child's own sleep would take if
        // it were never actually killed.
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "wait_with_timeout took {elapsed:?}, expected well under 5s -- the timeout/kill path did not work"
        );

        // Confirm the process is actually gone, not merely abandoned still
        // running in the background: on Unix, sending signal 0 to a dead
        // pid fails with ESRCH, which `kill -0` surfaces as a non-zero exit.
        #[cfg(unix)]
        {
            let still_alive = std::process::Command::new("kill")
                .args(["-0", &pid.to_string()])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            assert!(!still_alive, "child pid {pid} is still running after wait_with_timeout was supposed to kill it");
        }
    }
}
