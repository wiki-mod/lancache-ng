//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! NATS JetStream subscriber: consumes DNS record updates and applies them to PowerDNS API.

mod nats_publish;
mod rollback_listener;
mod zone_snapshots;

use async_nats::jetstream;
use futures::StreamExt;
// DNSRecord/RRset/ZoneUpdate/ZoneInfo/dns_record_to_zone_update now live in
// lib.rs (see its module doc comment) so fuzz/ can link them without faking a
// NATS/PowerDNS connection -- this binary uses the exact same types/function,
// not a redefinition of them.
use nats_subscriber::{DNSRecord, ZoneInfo, dns_record_to_zone_update};
use reqwest::Client;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::env;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;

/// Shared configuration + coordination for the zone/record known-good
/// snapshot adapter (#628). `lock` is held for the whole
/// read-modify-snapshot sequence by every caller (the post-PATCH trigger in
/// `handle_dns_record`, the periodic `zone_snapshot_watcher`, and
/// `rollback_listener.rs`'s rollback handler) so a snapshot-creation tick
/// and an in-progress rollback for the same zone never interleave -- see
/// `zone_snapshots.rs`'s module doc comment for why that matters
/// (concurrent `create_snapshot` calls would otherwise race retention
/// pruning and could emit spurious FATAL log lines).
#[derive(Clone)]
struct SnapshotContext {
    base_dir: PathBuf,
    keep_n: u32,
    lock: Arc<AsyncMutex<()>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecordWriteMode {
    Enabled,
    Disabled,
}

impl RecordWriteMode {
    fn from_env() -> Self {
        Self::from_env_value(&env::var("NATS_RECORD_WRITES").unwrap_or_else(|_| "1".to_string()))
    }

    fn from_env_value(value: &str) -> Self {
        match value.to_ascii_lowercase().as_str() {
            "0" | "false" | "no" | "off" => Self::Disabled,
            _ => Self::Enabled,
        }
    }

    fn allows_writes(self) -> bool {
        matches!(self, Self::Enabled)
    }
}

// Missing/non-numeric/non-positive KEEP_KNOWN_GOOD_CONFIGS falls back to
// `default` here at the env-parsing boundary; `zone_snapshots::
// prune_snapshots`'s own `clamp_keep_n` re-clamps a raw 0 as a second,
// belt-and-suspenders guard for any future caller that constructs a
// SnapshotContext without going through this function.
fn env_u32_clamped(key: &str, default: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|&n| n >= 1)
        .unwrap_or(default)
}

/// Exports the current data rrsets (SOA/NS excluded, see
/// `zone_snapshots::filter_data_rrsets`) for `zone` (canonical, dotted form)
/// from PowerDNS's own API and records a fresh known-good snapshot if the
/// content differs from the most recently stored one. Used by both
/// snapshot triggers the design requires: the post-PATCH hook in
/// `handle_dns_record` (the NATS-applied path) and `zone_snapshot_watcher`
/// (the periodic export-and-diff trigger covering Kea's direct-to-PowerDNS
/// DDNS updates, which bypass NATS/this consumer entirely). Every failure
/// path here is logged via `zone_snapshots::kgs_log` and otherwise swallowed
/// -- non-fatal by design (docs/known-good-config-snapshots.md): a snapshot
/// failure must never turn an already-applied, already-confirmed PowerDNS
/// write into a NATS redelivery loop.
async fn maybe_snapshot_zone(
    zone: &str,
    http_client: &Client,
    pdns_api_key: &str,
    ctx: &SnapshotContext,
) {
    if !zone_snapshots::is_rollback_zone(zone) {
        return;
    }

    let url = format!(
        "http://127.0.0.1:8081/api/v1/servers/localhost/zones/{}",
        zone_snapshots::zone_api_id(zone)
    );
    let resp = match http_client
        .get(&url)
        .header("X-API-Key", pdns_api_key)
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            zone_snapshots::kgs_log(
                "FATAL",
                &format!(
                    "failed to export zone {zone} for snapshotting: PowerDNS returned {}",
                    r.status()
                ),
            );
            return;
        }
        Err(e) => {
            zone_snapshots::kgs_log(
                "FATAL",
                &format!("failed to export zone {zone} for snapshotting: {e}"),
            );
            return;
        }
    };

    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            zone_snapshots::kgs_log(
                "FATAL",
                &format!("failed to decode zone {zone} export for snapshotting: {e}"),
            );
            return;
        }
    };
    let rrsets = body
        .get("rrsets")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let data_rrsets = zone_snapshots::filter_data_rrsets(&rrsets);

    let _guard = ctx.lock.lock().await;
    let root = zone_snapshots::zone_snapshot_root(&ctx.base_dir, zone);
    if zone_snapshots::matches_latest_snapshot(&root, &data_rrsets) {
        return;
    }
    if let Err(e) = zone_snapshots::create_snapshot(&root, ctx.keep_n, &data_rrsets) {
        zone_snapshots::kgs_log("FATAL", &format!("failed to snapshot zone {zone}: {e}"));
    }
}

/// Periodic export-and-diff trigger (docs/known-good-config-snapshots.md's
/// "Trigger point"): Kea's DDNS updates (`services/dhcp/kea-dhcp-ddns.conf`)
/// go straight to PowerDNS over TSIG-authenticated DNS UPDATE, bypassing
/// NATS and this process's own consumer loop entirely, for every zone in
/// `zone_snapshots::ROLLBACK_ZONES` (not just `local.lan.`/the reverse
/// zones -- `lan.` also receives direct DDNS writes for DHCP lease
/// hostnames, alongside its separate NATS-applied path for Admin-UI-driven
/// writes). Runs unconditionally on every node (unlike the existing
/// `reconciler()`, which only runs when `NATS_RECONCILER=1`): this watcher
/// is not about NATS record replication, it is about noticing PowerDNS
/// state that changed without ever going through this process at all, which
/// is true on every node identically. Mirrors the existing `reconciler`'s
/// 60-second interval shape (main.rs:442-541 in the pre-#628 layout).
async fn zone_snapshot_watcher(
    http_client: Arc<Client>,
    pdns_api_key: String,
    ctx: SnapshotContext,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(60));
    loop {
        interval.tick().await;
        for &zone in zone_snapshots::ROLLBACK_ZONES {
            maybe_snapshot_zone(zone, &http_client, &pdns_api_key, &ctx).await;
        }
    }
}

#[tokio::main]
async fn main() {
    let nats_url = env::var("NATS_URL").unwrap_or_else(|_| "nats://nats:4222".to_string());
    let nats_user = env::var("NATS_USER").ok().filter(|user| !user.is_empty());
    let nats_password = env::var("NATS_PASSWORD")
        .ok()
        .filter(|password| !password.is_empty());
    let nats_token = env::var("NATS_TOKEN")
        .ok()
        .filter(|token| !token.is_empty());
    let nats_consumer = match env::var("NATS_CONSUMER") {
        Ok(val) => val,
        Err(_) => {
            eprintln!("NATS_CONSUMER environment variable is required");
            std::process::exit(1);
        }
    };

    let pdns_api_key = match env::var("PDNS_API_KEY") {
        Ok(val) => val,
        Err(_) => {
            eprintln!("PDNS_API_KEY environment variable is required");
            std::process::exit(1);
        }
    };
    let record_write_mode = RecordWriteMode::from_env();

    let nats_reconciler = env::var("NATS_RECONCILER").ok();

    // Connect to NATS with reconnect settings
    let mut opts = async_nats::ConnectOptions::new()
        .max_reconnects(None)
        .reconnect_delay_callback(|_| Duration::from_secs(3));

    if let (Some(user), Some(password)) = (nats_user, nats_password) {
        opts = opts.user_and_password(user, password);
    } else if let Some(token) = nats_token {
        opts = opts.token(token);
    }

    let client = match opts.connect(&nats_url).await {
        Ok(conn) => conn,
        Err(e) => {
            eprintln!("Failed to connect to NATS: {}", e);
            std::process::exit(1);
        }
    };

    println!("Connected to NATS at {}", nats_url);

    // Get JetStream context
    let js = async_nats::jetstream::new(client);

    // Create or update stream LANCACHE_DNS
    let _stream = match js.get_stream("LANCACHE_DNS").await {
        Ok(s) => s,
        Err(_) => {
            match js
                .create_stream(jetstream::stream::Config {
                    name: "LANCACHE_DNS".to_string(),
                    subjects: vec!["lancache.dns.>".to_string()],
                    storage: jetstream::stream::StorageType::File,
                    max_age: Duration::from_secs(7 * 24 * 60 * 60),
                    discard: jetstream::stream::DiscardPolicy::Old,
                    ..Default::default()
                })
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("Failed to create stream: {}", e);
                    std::process::exit(1);
                }
            }
        }
    };

    println!("Stream LANCACHE_DNS ready");

    // Create or get durable pull consumer
    let consumer: async_nats::jetstream::consumer::Consumer<
        async_nats::jetstream::consumer::pull::Config,
    > = match _stream
        .get_or_create_consumer(
            &nats_consumer,
            async_nats::jetstream::consumer::pull::Config {
                durable_name: Some(nats_consumer.clone()),
                filter_subject: "lancache.dns.>".to_string(),
                ..Default::default()
            },
        )
        .await
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to create consumer: {}", e);
            std::process::exit(1);
        }
    };

    println!("Created durable subscriber: {}", nats_consumer);

    // Create shared HTTP client (#68 fix)
    let http_client = Arc::new(
        Client::builder()
            .timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(90))
            .tcp_keepalive(Duration::from_secs(60))
            .build()
            .expect("failed to build shared HTTP client"),
    );

    // Start reconciler if enabled
    if nats_reconciler.as_deref() == Some("1") {
        let js_clone = js.clone();
        let pdns_api_key_clone = pdns_api_key.clone();
        let client_clone = http_client.clone();
        tokio::spawn(async move {
            reconciler(js_clone, &pdns_api_key_clone, client_clone).await;
        });
    }

    // ── Zone/record known-good snapshots (#628) ─────────────────────────
    // DNS_CONFIG_SNAPSHOT_DIR/KEEP_KNOWN_GOOD_CONFIGS are the same env vars
    // entrypoint.sh already uses for the recursor.conf/pdns.conf static-file
    // adapter (#615); this adapter nests its own snapshots under a `zones/`
    // subdirectory of the same base dir (see zone_snapshots::zone_snapshot_root)
    // so both live in the same persistent volume without colliding.
    let dns_config_snapshot_dir = env::var("DNS_CONFIG_SNAPSHOT_DIR")
        .unwrap_or_else(|_| "/var/lib/lancache-dns/config-snapshots".to_string());
    let keep_known_good_configs = env_u32_clamped("KEEP_KNOWN_GOOD_CONFIGS", 3);
    let snapshot_ctx = SnapshotContext {
        base_dir: PathBuf::from(dns_config_snapshot_dir),
        keep_n: keep_known_good_configs,
        lock: Arc::new(AsyncMutex::new(())),
    };

    // Periodic export-and-diff trigger: runs on every node unconditionally
    // (not gated by NATS_RECONCILER, see zone_snapshot_watcher's doc
    // comment -- it is not about NATS replication, it is about noticing
    // Kea's direct-to-PowerDNS DDNS writes, which happen on every node).
    {
        let client_clone = http_client.clone();
        let pdns_api_key_clone = pdns_api_key.clone();
        let ctx_clone = snapshot_ctx.clone();
        tokio::spawn(async move {
            zone_snapshot_watcher(client_clone, pdns_api_key_clone, ctx_clone).await;
        });
    }

    // Local rollback listener: a new port (default 0.0.0.0:8083, see
    // rollback_listener.rs's module doc comment for why 0.0.0.0 and not
    // 127.0.0.1) the Admin UI calls to list zone snapshots and trigger an
    // operator-selected rollback.
    {
        let rollback_listen_addr =
            env::var("DNS_ROLLBACK_LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8083".to_string());
        let rollback_state = Arc::new(rollback_listener::RollbackState {
            http_client: http_client.clone(),
            pdns_api_key: pdns_api_key.clone(),
            snapshot_base_dir: snapshot_ctx.base_dir.clone(),
            keep_n: snapshot_ctx.keep_n,
            snapshot_lock: snapshot_ctx.lock.clone(),
            js: js.clone(),
        });
        tokio::spawn(async move {
            rollback_listener::serve(&rollback_listen_addr, rollback_state).await;
        });
    }

    // Main fetch loop with exponential backoff (#87 fix)
    let mut backoff_secs = 1u64;
    const MAX_BACKOFF_SECS: u64 = 30;

    // Per-key applied-sequence watermarks for the cross-batch stale-write guard
    // (issue #772; see `AppliedSequences`). Owned solely by this fetch loop,
    // which is a single task processing messages sequentially with `.await`, so
    // no locking is needed -- the snapshot watcher, reconciler, and rollback
    // listener only ever publish records, they never apply them here.
    let mut applied_seqs = AppliedSequences::default();

    loop {
        let fetch_result = consumer
            .fetch()
            .max_messages(10)
            .expires(Duration::from_secs(5))
            .messages()
            .await;

        match fetch_result {
            Ok(mut messages) => {
                let mut had_stream_error = false;
                // What: fetch() no_wait returns immediately.
                // Why: must use explicit backoff to avoid busy-spin.
                // From: PR #738
                let mut had_retryable_batch_stop = false;

                while let Some(msg_result) = messages.next().await {
                    match msg_result {
                        Ok(msg) => {
                            let result = handle_message(
                                &msg,
                                &pdns_api_key,
                                &http_client,
                                &snapshot_ctx,
                                &mut applied_seqs,
                                record_write_mode,
                            )
                            .await;
                            // #653 fix: what to do with THIS message is decided by the pure
                            // `decide_msg` (unit-tested below via `simulate_batch_processing`)
                            // so the ack/nak decision itself -- not just this call site -- is
                            // covered by tests without a real NATS connection.
                            match decide_msg(result) {
                                MsgDecision::AckAndContinue => {
                                    if let Err(e) = msg.ack().await {
                                        eprintln!("Error acknowledging message: {}", e);
                                    }
                                }
                                MsgDecision::NakAndContinue => {
                                    // What: flush failures continue batch.
                                    // Why: flush has no ordering hazard.
                                    // From: PR #738
                                    if let Err(e) = msg
                                        .ack_with(jetstream::AckKind::Nak(Some(
                                            Duration::from_millis(100),
                                        )))
                                        .await
                                    {
                                        eprintln!("Error naking message: {}", e);
                                    }
                                }
                                MsgDecision::NakAndStopBatch => {
                                    // What: NAK and stop batch on failure.
                                    // Why: prevent stale-write batch race.
                                    // From: PR #738 | Issue #653
                                    if let Err(e) = msg
                                        .ack_with(jetstream::AckKind::Nak(Some(
                                            Duration::from_millis(100),
                                        )))
                                        .await
                                    {
                                        eprintln!("Error naking message: {}", e);
                                    }
                                    had_retryable_batch_stop = true;
                                    break;
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("Message error: {}", e);
                            had_stream_error = true;
                            // Break out of the inner loop so the outer backoff fires.
                            // Continuing to call messages.next() on a broken stream
                            // would busy-spin inside the Ok(messages) arm.
                            break;
                        }
                    }
                }

                // What: apply backoff on stream/batch errors.
                // Why: prevents busy-spin in fetch() no_wait.
                // From: PR #738
                if had_stream_error {
                    eprintln!(
                        "Stream error(s); backing off for {} second(s)",
                        backoff_secs
                    );
                    tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                    backoff_secs = (backoff_secs * 2).min(MAX_BACKOFF_SECS);
                } else if had_retryable_batch_stop {
                    eprintln!(
                        "Retryable PDNS failure stopped batch processing; backing off for {} second(s)",
                        backoff_secs
                    );
                    tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                    backoff_secs = (backoff_secs * 2).min(MAX_BACKOFF_SECS);
                } else {
                    backoff_secs = 1;
                }
            }
            // #87 fix: exponential backoff on fetch error to prevent busy-spin loop
            Err(e) => {
                eprintln!(
                    "Fetch error: {} (backing off for {} second(s))",
                    e, backoff_secs
                );
                tokio::time::sleep(Duration::from_secs(backoff_secs)).await;

                // Double backoff for next iteration, capped at MAX_BACKOFF_SECS
                backoff_secs = (backoff_secs * 2).min(MAX_BACKOFF_SECS);
            }
        }
    }
}

/// What: retryable outcomes (ordering hazard vs. none).
/// Why: flush safe to continue; records need batch stop.
/// From: PR #738 | Issue #653
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HandleOutcome {
    /// Succeeded (or was an unrecoverable/malformed message already logged
    /// and intentionally not retried): ack it.
    Ack,
    /// Retryable failure with no batch-ordering hazard (currently: flush):
    /// nak with delay, but keep consuming the rest of the batch.
    RetryContinueBatch,
    /// Retryable failure that COULD create a stale-record-clobber race if
    /// later same-batch messages were allowed to proceed (currently: record
    /// updates): nak with delay and stop consuming the rest of the batch.
    RetryStopBatch,
}

/// What to do with a single fetched message, given its `HandleOutcome`. This
/// is the actual decision `main`'s batch loop acts on (see the
/// `match decide_msg(result)` call site) -- pulled out as a pure function so
/// the #653 fix ("on a retryable record-update failure, nak this message AND
/// stop consuming the rest of the batch") is unit-testable without a real
/// NATS connection, and so a test exercising it is exercising the same logic
/// the production loop runs, not a reimplementation of it.
#[derive(Debug, PartialEq, Eq)]
enum MsgDecision {
    /// `handle_message` succeeded: ack this message, keep consuming the batch.
    AckAndContinue,
    /// `handle_message` returned a retryable failure with no ordering
    /// hazard (e.g. a flush failure): nak this message (with delay) but
    /// keep consuming the rest of the batch.
    NakAndContinue,
    /// `handle_message` returned a retryable (5xx/network) record-update
    /// failure: nak this message (with delay) and stop consuming the rest
    /// of the batch, so no later same-batch message (e.g. a newer update
    /// for the same zone/name/type) can get acked ahead of this pending
    /// retry.
    NakAndStopBatch,
}

fn decide_msg(outcome: HandleOutcome) -> MsgDecision {
    match outcome {
        HandleOutcome::Ack => MsgDecision::AckAndContinue,
        HandleOutcome::RetryContinueBatch => MsgDecision::NakAndContinue,
        HandleOutcome::RetryStopBatch => MsgDecision::NakAndStopBatch,
    }
}

/// Identifies one DNS record for stale-write detection: normalized
/// `(zone, name, type)`. Normalization is deliberate: the different publishers
/// of the same logical record -- the Admin UI routes
/// (`services/ui/src/routes/domains.rs`, which sends `zone: "lan"` and a name
/// like `host.lan.`), this binary's own `reconciler`, and `rollback_listener`'s
/// post-rollback re-publish -- do not all emit byte-identical `zone`/`name`
/// strings (e.g. `host.lan.` vs `host.lan`, differing case). A non-normalized
/// key would silently treat those as different records and fail to guard the
/// very clobber this exists to prevent (issue #772). DNS names are
/// case-insensitive and a trailing dot is not a semantic distinction, so
/// stripping the trailing dot and lowercasing can never merge two genuinely
/// different records.
type RecordKey = (String, String, String);

fn record_key(zone: &str, name: &str, record_type: &str) -> RecordKey {
    (
        zone.trim_end_matches('.').to_ascii_lowercase(),
        name.trim_end_matches('.').to_ascii_lowercase(),
        record_type.to_ascii_uppercase(),
    )
}

/// What: per-key highest applied JetStream sequence.
/// Why: prevent stale reapplication across batches.
/// From: Issue #772
#[derive(Default)]
struct AppliedSequences {
    last_applied: HashMap<RecordKey, u64>,
}

impl AppliedSequences {
    /// Returns true if applying `seq` for `key` would be a stale write -- a
    /// sequence `>=` it has already been applied for the same key. `>=` (not
    /// `>`) so an exact redelivery of the already-applied message is skipped
    /// idempotently instead of needlessly re-PATCHed.
    fn is_stale(&self, key: &RecordKey, seq: u64) -> bool {
        matches!(self.last_applied.get(key), Some(&applied) if seq <= applied)
    }

    /// Records that `seq` was successfully applied for `key`. `max` guards
    /// against ever lowering an existing watermark (e.g. if two messages for
    /// the same key were applied out of publish order within one batch).
    fn record_applied(&mut self, key: RecordKey, seq: u64) {
        let entry = self.last_applied.entry(key).or_insert(0);
        *entry = (*entry).max(seq);
    }
}

async fn handle_message(
    msg: &async_nats::jetstream::Message,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
    snapshot_ctx: &SnapshotContext,
    applied_seqs: &mut AppliedSequences,
    record_write_mode: RecordWriteMode,
) -> HandleOutcome {
    let subject = msg.subject.as_ref();

    if subject.starts_with("lancache.dns.heartbeat") {
        // Ignore heartbeat messages
        return HandleOutcome::Ack;
    }

    if subject == "lancache.dns.record" {
        if !record_write_mode.allows_writes() {
            println!(
                "Acking DNS record message without local PowerDNS write because NATS_RECORD_WRITES is disabled on this node"
            );
            return HandleOutcome::Ack;
        }
        return if handle_dns_record(msg, pdns_api_key, http_client, snapshot_ctx, applied_seqs)
            .await
        {
            HandleOutcome::Ack
        } else {
            // Record updates carry the stale-clobber ordering hazard -- stop
            // the batch (see `HandleOutcome::RetryStopBatch` doc comment).
            HandleOutcome::RetryStopBatch
        };
    }

    if subject == "lancache.dns.flush" {
        return if handle_dns_flush(msg, pdns_api_key, http_client).await {
            HandleOutcome::Ack
        } else {
            // Flush has no ordering hazard -- retry without blocking the
            // rest of the batch (see `HandleOutcome::RetryContinueBatch`).
            HandleOutcome::RetryContinueBatch
        };
    }

    println!("Unknown subject: {}", subject);
    HandleOutcome::Ack
}

// What: construct PowerDNS API URL stripping trailing zone dot.
// Why: prevents silent 404 when zone sent with trailing dot.
fn dns_record_patch_url(zone: &str) -> String {
    format!(
        "http://127.0.0.1:8081/api/v1/servers/localhost/zones/{}",
        zone_snapshots::zone_api_id(zone)
    )
}

// dns_zone_notify_url <zone>
// PowerDNS exposes zone notification as a separate HTTP endpoint from the
// RRset PATCH itself. Keeping the URL construction alongside
// dns_record_patch_url() makes the primary-side "write then notify
// secondaries" contract explicit and unit-testable under the same
// zone-id-normalization rules.
fn dns_zone_notify_url(zone: &str) -> String {
    format!(
        "http://127.0.0.1:8081/api/v1/servers/localhost/zones/{}/notify",
        zone_snapshots::zone_api_id(zone)
    )
}

async fn notify_zone_secondaries(
    zone: &str,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
) -> bool {
    let url = dns_zone_notify_url(zone);
    match http_client
        .put(&url)
        .header("X-API-Key", pdns_api_key)
        .send()
        .await
    {
        Ok(resp) if resp.status().is_success() => true,
        Ok(resp) => {
            eprintln!(
                "PDNS notify error (will retry): {} {} for zone={}",
                resp.status(),
                resp.status().canonical_reason().unwrap_or(""),
                zone
            );
            false
        }
        Err(e) => {
            eprintln!(
                "Error sending PDNS notify request (will retry) for zone={}: {}",
                zone, e
            );
            false
        }
    }
}

async fn handle_dns_record(
    msg: &async_nats::jetstream::Message,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
    snapshot_ctx: &SnapshotContext,
    applied_seqs: &mut AppliedSequences,
) -> bool {
    let record: DNSRecord = match serde_json::from_slice(&msg.payload) {
        Ok(r) => r,
        Err(e) => {
            // P2 fix: Ack unrecoverable parse failures (e.g., malformed delete events missing ttl/records).
            // Nacking would cause infinite retry of malformed messages.
            eprintln!(
                "Acking unrecoverable DNS record parse failure (malformed message): {}",
                e
            );
            return true;
        }
    };

    let update = match dns_record_to_zone_update(&record) {
        Ok(u) => u,
        Err(e) => {
            // P2 fix: Ack unrecoverable parse failures (unknown action).
            // Nacking would cause infinite retry of malformed messages.
            eprintln!("Acking unrecoverable DNS record parse failure ({})", e);
            return true;
        }
    };

    let payload = match serde_json::to_string(&update) {
        Ok(p) => p,
        Err(e) => {
            // P2 fix: Ack unrecoverable serialization failures.
            // Nacking would cause infinite retry of malformed messages.
            eprintln!(
                "Acking unrecoverable DNS record serialization failure (malformed message): {}",
                e
            );
            return true;
        }
    };

    // Cross-batch stale-write guard (issue #772; see `AppliedSequences`). A
    // redelivered older-sequence update for a key whose newer sequence was
    // already applied must be dropped, not replayed over the newer state.
    let key = record_key(&record.zone, &record.name, &record.record_type);
    let stream_seq = match msg.info() {
        Ok(info) => Some(info.stream_sequence),
        Err(e) => {
            // A consumer-fetched JetStream message always carries a $JS.ACK
            // reply subject, so info() should never fail on this path. If it
            // somehow does we cannot order this write, so apply it unguarded
            // (no worse than the pre-#772 behavior) rather than silently
            // dropping what may be a real update.
            eprintln!(
                "Could not read JetStream message info for stale-write guard (applying unguarded): {e}"
            );
            None
        }
    };
    if let Some(seq) = stream_seq
        && applied_seqs.is_stale(&key, seq)
    {
        // Ack (return true): the message has been superseded by a newer
        // sequence for the same key, so there is nothing left to apply and
        // JetStream must stop redelivering it.
        println!(
            "Skipping stale DNS record redelivery: zone={} name={} type={} seq={} (a newer sequence for this key was already applied)",
            record.zone, record.name, record.record_type, seq
        );
        return true;
    }

    let url = dns_record_patch_url(&record.zone);

    // What: hold snapshot lock across PATCH to prevent TOCTOU.
    // Why: rollback TOCTOU: computed from stale, applies over live write.
    let result = {
        let _snapshot_guard = snapshot_ctx.lock.lock().await;

        // #68 fix: use shared client instead of creating new one
        http_client
            .patch(&url)
            .header("X-API-Key", pdns_api_key)
            .header("Content-Type", "application/json")
            .body(payload)
            .send()
            .await
    };

    match result {
        Ok(resp) => {
            if resp.status().is_success() {
                println!(
                    "Updated DNS record: zone={} name={} type={} action={}",
                    record.zone, record.name, record.record_type, record.action
                );
                // Local primary writes are not enough on their own for the
                // dns-ssl/remote-secondary topology: AXFR consumers need a
                // real zone notify so they pull the new state promptly
                // instead of staying stale until some later periodic check.
                if !notify_zone_secondaries(&record.zone, pdns_api_key, http_client).await {
                    return false;
                }
                // Post-PATCH known-good snapshot trigger (#628). Validated
                // by construction: this only runs after PowerDNS's own
                // PATCH already returned 2xx, so there is no separate
                // pre-snapshot check to run (docs/known-good-config-
                // snapshots.md's "Validation" point). Best-effort/non-fatal
                // by design -- `maybe_snapshot_zone` only ever logs on
                // failure, never changes this function's return value, so a
                // snapshot-volume outage can never turn an already-applied
                // write into a NATS redelivery loop.
                maybe_snapshot_zone(
                    &zone_snapshots::canonical_zone(&record.zone),
                    http_client,
                    pdns_api_key,
                    snapshot_ctx,
                )
                .await;
                // Record the applied watermark only after PowerDNS confirmed
                // the write (2xx). A failed/retried write must not advance the
                // watermark, or a later legitimate retry of this same message
                // would be wrongly skipped as stale (issue #772).
                if let Some(seq) = stream_seq {
                    applied_seqs.record_applied(key, seq);
                }
                true
            } else if resp.status().is_client_error() {
                // P2 fix: Ack on 4xx client errors (invalid data, permanent failure).
                // Retrying won't help; the record data itself is malformed.
                eprintln!(
                    "PDNS client error (acking, won't retry): {} {} for zone={} name={} type={}",
                    resp.status(),
                    resp.status().canonical_reason().unwrap_or(""),
                    record.zone,
                    record.name,
                    record.record_type
                );
                true
            } else {
                // 5xx or other server errors: retry by returning false
                eprintln!(
                    "PDNS server error (will retry): {} {} for zone={} name={} type={}",
                    resp.status(),
                    resp.status().canonical_reason().unwrap_or(""),
                    record.zone,
                    record.name,
                    record.record_type
                );
                false
            }
        }
        Err(e) => {
            // P2 fix: Network errors are retriable (transient), return false to retry
            eprintln!("Error sending PATCH request (will retry): {}", e);
            false
        }
    }
}

#[derive(Debug, Deserialize)]
struct FlushRequest {
    domain: String,
    #[serde(default)]
    zone: Option<String>,
    #[serde(default)]
    record_type: Option<String>,
    #[serde(default)]
    expected_content: Option<Vec<String>>,
}

// What: bounds in-process wait before Nak-redelivery.
// Why: a longer sleep holds the message, risks ack_wait.
// From: Issue #1095
const FLUSH_CONFIRM_FAST_PATH_ATTEMPTS: u32 = 3;
const FLUSH_CONFIRM_FAST_PATH_DELAY: Duration = Duration::from_millis(100);
// What: caps delivery attempts before flushing unconfirmed.
// Why: bounds an unlimited max_deliver retry loop.
// From: Issue #1095
const FLUSH_CONFIRM_MAX_DELIVERIES: i64 = 100;

// What: pure comparison, no network -- unit-testable in isolation.
// Why: separates the HTTP fetch from the state-matching logic.
// From: Issue #1095
fn rrset_matches_expected(
    found: Option<&nats_subscriber::RRset>,
    expected_content: Option<&[String]>,
) -> bool {
    match (found, expected_content) {
        (None, None) => true,
        (Some(_), None) | (None, Some(_)) => false,
        (Some(rrset), Some(expected)) => {
            let mut actual: Vec<String> = rrset
                .records
                .as_ref()
                .map(|recs| {
                    recs.iter()
                        .filter_map(|r| r.get("content").and_then(|c| c.as_str()))
                        .map(|s| s.to_string())
                        .collect()
                })
                .unwrap_or_default();
            actual.sort();
            let mut expected_sorted = expected.to_vec();
            expected_sorted.sort();
            actual == expected_sorted
        }
    }
}

// What: checks if the local zone matches the expected state.
// Why: proves AXFR landed here before trusting a flush.
// From: Issue #1095
async fn local_rrset_matches_expected(
    zone: &str,
    name: &str,
    record_type: &str,
    expected_content: Option<&[String]>,
    pdns_api_key: &str,
    http_client: &Client,
) -> bool {
    let url = dns_record_patch_url(zone);
    let resp = match http_client
        .get(&url)
        .header("X-API-Key", pdns_api_key)
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        _ => return false,
    };
    let zone_info: ZoneInfo = match resp.json().await {
        Ok(zi) => zi,
        Err(_) => return false,
    };
    let found = zone_info
        .rrsets
        .iter()
        .find(|rr| rr.name == name && rr.record_type == record_type);
    rrset_matches_expected(found, expected_content)
}

async fn handle_dns_flush(
    msg: &async_nats::jetstream::Message,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
) -> bool {
    // PowerDNS Recursor's cache/flush endpoint requires a `domain` query
    // parameter and only flushes an exact name match, not a subtree --
    // confirmed live while building issue #400's integration test:
    // `?type=packet` (the previous call) always returned 422 Unprocessable
    // Entity, and even `?domain=.` (root) leaves a just-changed leaf record
    // resolving from cache until its TTL naturally expires. The publisher
    // (services/ui/src/routes/domains.rs's flush_recursor_cache) now sends
    // the exact domain that changed; fall back to "." only for messages
    // published by a publisher version that predates the `domain` field, or
    // from any other future publisher that doesn't include one.
    let req = serde_json::from_slice::<FlushRequest>(&msg.payload).ok();
    let domain = req
        .as_ref()
        .map(|r| r.domain.clone())
        .unwrap_or_else(|| ".".to_string());

    // What: confirms the local zone before flushing, when known.
    // Why: else a lost AXFR race re-caches the stale answer at TTL.
    // From: Issue #1095
    if let Some(req) = req.as_ref()
        && let (Some(zone), Some(record_type)) = (req.zone.as_deref(), req.record_type.as_deref())
    {
        let mut confirmed = false;
        for _ in 0..FLUSH_CONFIRM_FAST_PATH_ATTEMPTS {
            if local_rrset_matches_expected(
                zone,
                &domain,
                record_type,
                req.expected_content.as_deref(),
                pdns_api_key,
                http_client,
            )
            .await
            {
                confirmed = true;
                break;
            }
            tokio::time::sleep(FLUSH_CONFIRM_FAST_PATH_DELAY).await;
        }

        if !confirmed {
            let delivered = msg.info().map(|info| info.delivered).unwrap_or(0);
            if delivered < FLUSH_CONFIRM_MAX_DELIVERIES {
                println!(
                    "Deferring recursor flush for {domain} ({record_type}): local zone not yet confirmed (delivery {delivered}); retrying via redelivery"
                );
                return false;
            }
            eprintln!(
                "Recursor flush for {domain} ({record_type}): local zone still unconfirmed after {delivered} deliveries; flushing anyway"
            );
        }
    }

    let url = format!("http://127.0.0.1:8082/api/v1/servers/localhost/cache/flush?domain={domain}");

    // #68 fix: use shared client instead of creating new one
    let result = http_client
        .put(&url)
        .header("X-API-Key", pdns_api_key)
        .send()
        .await;

    match result {
        Ok(resp) => {
            if resp.status().is_success() {
                println!("Flushed PDNS cache");
                true
            } else {
                eprintln!(
                    "PDNS flush error: {} {}",
                    resp.status(),
                    resp.status().canonical_reason().unwrap_or("")
                );
                false
            }
        }
        Err(e) => {
            eprintln!("Error sending flush request: {}", e);
            false
        }
    }
}

async fn reconciler(
    js: async_nats::jetstream::Context,
    pdns_api_key: &str,
    http_client: Arc<Client>,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(60));

    loop {
        interval.tick().await;

        let url = "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan";

        // #68 fix: use shared client instead of creating new one
        let result = http_client
            .get(url)
            .header("X-API-Key", pdns_api_key)
            .send()
            .await;

        match result {
            Ok(resp) => {
                if !resp.status().is_success() {
                    eprintln!(
                        "Reconciler: PDNS error: {} {}",
                        resp.status(),
                        resp.status().canonical_reason().unwrap_or("")
                    );
                    continue;
                }

                let zone_info: ZoneInfo = match resp.json().await {
                    Ok(zi) => zi,
                    Err(e) => {
                        eprintln!("Reconciler: error decoding zone info: {}", e);
                        continue;
                    }
                };

                for rrset in &zone_info.rrsets {
                    if rrset.record_type == "SOA" || rrset.record_type == "NS" {
                        continue;
                    }

                    let msg_id = format!(
                        "reconcile-lan-{}-{}",
                        rrset.name.trim_end_matches('.'),
                        rrset.record_type
                    );

                    // #628: factored into nats_publish::publish_dns_record
                    // so this reconciler and rollback_listener.rs's
                    // post-rollback re-publish (the design doc's answer for
                    // how a lan. rollback interacts with existing NATS
                    // replication) write the exact same message shape.
                    let ttl = rrset.ttl.map(|t| json!(t)).unwrap_or(Value::Null);
                    let records = rrset
                        .records
                        .clone()
                        .map(|r| json!(r))
                        .unwrap_or(Value::Null);
                    nats_publish::publish_dns_record(
                        &js,
                        &msg_id,
                        nats_publish::DnsRecordMessage {
                            action: "replace",
                            zone: "lan",
                            name: &rrset.name,
                            record_type: &rrset.record_type,
                            ttl,
                            records,
                        },
                    )
                    .await;
                }

                println!(
                    "Reconciler: published {} records",
                    zone_info
                        .rrsets
                        .iter()
                        .filter(|r| r.record_type != "SOA" && r.record_type != "NS")
                        .count()
                );
            }
            Err(e) => {
                eprintln!("Reconciler: error fetching zone: {}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // RRset is only constructed/inspected directly in these tests --
    // production code in this file only names DNSRecord/ZoneInfo/
    // dns_record_to_zone_update directly (see the crate-level import above),
    // so it needs its own explicit import here to avoid an unused-import
    // warning on the non-test build. ZoneUpdate itself is only ever used via
    // type inference in these tests (never named directly), so it does not
    // need the same treatment.
    use nats_subscriber::RRset;

    // What: old publishers omit the new fields entirely.
    // Why: proves the flush still fires unconditionally then.
    // From: Issue #1095
    #[test]
    fn flush_request_deserializes_without_the_new_optional_fields() {
        let req: FlushRequest = serde_json::from_str(r#"{"domain": "host.lan."}"#).unwrap();
        assert_eq!(req.domain, "host.lan.");
        assert_eq!(req.zone, None);
        assert_eq!(req.record_type, None);
        assert_eq!(req.expected_content, None);
    }

    #[test]
    fn flush_request_deserializes_with_the_new_optional_fields() {
        let req: FlushRequest = serde_json::from_str(
            r#"{"domain": "host.lan.", "zone": "lan", "record_type": "A", "expected_content": ["10.0.0.5"]}"#,
        )
        .unwrap();
        assert_eq!(req.zone, Some("lan".to_string()));
        assert_eq!(req.record_type, Some("A".to_string()));
        assert_eq!(req.expected_content, Some(vec!["10.0.0.5".to_string()]));
    }

    fn rrset_with_content(content: &str) -> RRset {
        let mut record = HashMap::new();
        record.insert("content".to_string(), json!(content));
        RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(60),
            changetype: None,
            records: Some(vec![record]),
        }
    }

    // What: absent name/type and "expect absent" is a match.
    // Why: the delete case -- AXFR already caught up locally.
    // From: Issue #1095
    #[test]
    fn rrset_matches_expected_when_absent_and_absence_expected() {
        assert!(rrset_matches_expected(None, None));
    }

    #[test]
    fn rrset_matches_expected_rejects_still_present_when_absence_expected() {
        let rrset = rrset_with_content("10.0.0.5");
        assert!(!rrset_matches_expected(Some(&rrset), None));
    }

    #[test]
    fn rrset_matches_expected_rejects_still_absent_when_content_expected() {
        let expected = vec!["10.0.0.5".to_string()];
        assert!(!rrset_matches_expected(None, Some(&expected)));
    }

    #[test]
    fn rrset_matches_expected_accepts_matching_content_regardless_of_order() {
        let mut record_a = HashMap::new();
        record_a.insert("content".to_string(), json!("10.0.0.5"));
        let mut record_b = HashMap::new();
        record_b.insert("content".to_string(), json!("10.0.0.6"));
        let rrset = RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(60),
            changetype: None,
            records: Some(vec![record_b, record_a]),
        };
        let expected = vec!["10.0.0.5".to_string(), "10.0.0.6".to_string()];
        assert!(rrset_matches_expected(Some(&rrset), Some(&expected)));
    }

    #[test]
    fn rrset_matches_expected_rejects_stale_content() {
        let rrset = rrset_with_content("10.0.0.5");
        let expected = vec!["10.0.0.9".to_string()];
        assert!(!rrset_matches_expected(Some(&rrset), Some(&expected)));
    }

    // What: PATCH URL always strips zone trailing dot.
    // Why: prevents silent 404 when zone sent with trailing dot.
    #[test]
    fn dns_record_patch_url_strips_trailing_dot_regardless_of_input_form() {
        assert_eq!(
            dns_record_patch_url("lan"),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan"
        );
        assert_eq!(
            dns_record_patch_url("lan."),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan"
        );
        assert_eq!(
            dns_record_patch_url("1.168.192.in-addr.arpa."),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/1.168.192.in-addr.arpa"
        );
    }

    #[test]
    fn dns_zone_notify_url_strips_trailing_dot_regardless_of_input_form() {
        assert_eq!(
            dns_zone_notify_url("lan"),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan/notify"
        );
        assert_eq!(
            dns_zone_notify_url("lan."),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan/notify"
        );
        assert_eq!(
            dns_zone_notify_url("1.168.192.in-addr.arpa."),
            "http://127.0.0.1:8081/api/v1/servers/localhost/zones/1.168.192.in-addr.arpa/notify"
        );
    }

    // PDNS GET /zones/{zone} responses do NOT include changetype.
    // This test guards against regressions where changetype becomes
    // a required field again, which would break the reconciler.
    #[test]
    fn zone_info_deserializes_without_changetype() {
        let json = r#"{
            "rrsets": [
                {"name": "test.lan.", "type": "A", "ttl": 300, "records": [{"content": "192.168.1.1", "disabled": false}]},
                {"name": "test.lan.", "type": "SOA", "ttl": 3600, "records": [{"content": "ns1.lan. admin.lan. 1 3600 900 604800 60", "disabled": false}]}
            ]
        }"#;
        let info: ZoneInfo =
            serde_json::from_str(json).expect("ZoneInfo must deserialize without changetype");
        assert_eq!(info.rrsets.len(), 2);
        assert!(info.rrsets[0].changetype.is_none());
    }

    // PDNS PATCH requests require changetype to be present and serialized.
    #[test]
    fn rrset_serializes_with_changetype_for_patch() {
        let rrset = RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(300),
            changetype: Some("REPLACE".to_string()),
            records: Some(vec![]),
        };
        let json = serde_json::to_string(&rrset).expect("RRset must serialize");
        assert!(json.contains("changetype"));
        assert!(json.contains("REPLACE"));
    }

    // skip_serializing_if must suppress changetype when None (GET context).
    #[test]
    fn rrset_omits_changetype_when_none() {
        let rrset = RRset {
            name: "host.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(300),
            changetype: None,
            records: None,
        };
        let json = serde_json::to_string(&rrset).expect("RRset must serialize");
        assert!(!json.contains("changetype"));
    }

    // DNSRecord must parse the exact message format published by NATS subscribers,
    // ensuring the serialization contract with record-publishing callers remains stable.
    #[test]
    fn dns_record_deserializes_from_nats_message() {
        let json = r#"{
            "action": "replace",
            "zone": "lan",
            "name": "myhost.lan.",
            "type": "A",
            "ttl": 60,
            "records": [{"content": "10.0.0.5", "disabled": false}]
        }"#;
        let record: DNSRecord = serde_json::from_str(json).expect("DNSRecord must deserialize");
        assert_eq!(record.action, "replace");
        assert_eq!(record.zone, "lan");
    }

    // What: covers the secondary-node NATS record-write gate.
    // Why: AXFR is authoritative for secondaries; gate controls writes
    #[test]
    fn record_write_mode_disables_common_false_spellings() {
        for value in ["0", "false", "no", "off"] {
            assert_eq!(
                RecordWriteMode::from_env_value(value),
                RecordWriteMode::Disabled
            );
        }
        assert_eq!(
            RecordWriteMode::from_env_value("1"),
            RecordWriteMode::Enabled
        );
        assert_eq!(
            RecordWriteMode::from_env_value("unexpected"),
            RecordWriteMode::Enabled
        );
    }

    // REPLACE action must produce a zone update with all required fields (ttl, records)
    // to ensure PowerDNS can apply the record update correctly.
    #[test]
    fn dns_record_to_zone_update_replace_action() {
        let record = DNSRecord {
            action: "replace".to_string(),
            zone: "lan".to_string(),
            name: "test.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: Some(300),
            records: Some(vec![{
                let mut m = HashMap::new();
                m.insert("content".to_string(), json!("10.0.0.1"));
                m.insert("disabled".to_string(), json!(false));
                m
            }]),
        };

        let update = dns_record_to_zone_update(&record).expect("must succeed");
        assert_eq!(update.rrsets.len(), 1);
        let rrset = &update.rrsets[0];
        assert_eq!(rrset.name, "test.lan.");
        assert_eq!(rrset.record_type, "A");
        assert_eq!(rrset.changetype, Some("REPLACE".to_string()));
        assert_eq!(rrset.ttl, Some(300));
        assert!(rrset.records.is_some());
    }

    // DELETE action must clear ttl and records fields as required by PowerDNS API;
    // sending them would violate the API contract and potentially cause silent failures.
    #[test]
    fn dns_record_to_zone_update_delete_action() {
        let record = DNSRecord {
            action: "delete".to_string(),
            zone: "lan".to_string(),
            name: "old.lan.".to_string(),
            record_type: "CNAME".to_string(),
            ttl: Some(600),
            records: Some(vec![]),
        };

        let update = dns_record_to_zone_update(&record).expect("must succeed");
        assert_eq!(update.rrsets.len(), 1);
        let rrset = &update.rrsets[0];
        assert_eq!(rrset.name, "old.lan.");
        assert_eq!(rrset.record_type, "CNAME");
        assert_eq!(rrset.changetype, Some("DELETE".to_string()));
        // For DELETE, ttl and records must be None
        assert!(rrset.ttl.is_none());
        assert!(rrset.records.is_none());
    }

    // Unknown action strings must be rejected immediately with a clear error,
    // preventing silent acceptance of typos that would corrupt DNS state.
    #[test]
    fn dns_record_to_zone_update_invalid_action() {
        let record = DNSRecord {
            action: "invalid".to_string(),
            zone: "lan".to_string(),
            name: "test.lan.".to_string(),
            record_type: "A".to_string(),
            ttl: None,
            records: None,
        };

        let result = dns_record_to_zone_update(&record);
        assert!(result.is_err());
        assert!(result.err().unwrap().contains("unknown action"));
    }

    // What: REPLACE with no TTL must default, not omit field.
    // Why: PowerDNS requires TTL for REPLACE, unlike DELETE.
    #[test]
    fn dns_record_to_zone_update_replace_without_ttl_defaults_instead_of_omitting() {
        let record = DNSRecord {
            action: "replace".to_string(),
            zone: "lan".to_string(),
            name: "nottl.lan.".to_string(),
            record_type: "TXT".to_string(),
            ttl: None,
            records: Some(vec![{
                let mut m = HashMap::new();
                m.insert("content".to_string(), json!("v=spf1 -all"));
                m
            }]),
        };

        let update = dns_record_to_zone_update(&record).expect("must succeed");
        let rrset = &update.rrsets[0];
        assert_eq!(rrset.changetype, Some("REPLACE".to_string()));
        assert_eq!(
            rrset.ttl,
            Some(300),
            "a REPLACE rrset must always carry a real TTL -- PowerDNS documents it as a required field, not optional-for-REPLACE"
        );
        assert!(rrset.records.is_some());
    }

    // Empty records lists must be preserved in the zone update (not converted to None),
    // ensuring PowerDNS receives the correct "delete all records of this type" semantics.
    #[test]
    fn dns_record_to_zone_update_replace_empty_records() {
        let record = DNSRecord {
            action: "replace".to_string(),
            zone: "lan".to_string(),
            name: "empty.lan.".to_string(),
            record_type: "MX".to_string(),
            ttl: Some(3600),
            records: Some(vec![]),
        };

        let update = dns_record_to_zone_update(&record).expect("must succeed");
        let rrset = &update.rrsets[0];
        assert_eq!(rrset.changetype, Some("REPLACE".to_string()));
        assert_eq!(rrset.ttl, Some(3600));
        // Empty records list should still be present
        assert!(rrset.records.is_some());
        assert_eq!(rrset.records.as_ref().unwrap().len(), 0);
    }

    // Per-message outcome of replaying a batch through the SAME `decide_msg`
    // the production loop calls (see the `match decide_msg(result)` in
    // `main`). This is a thin test harness around real production logic,
    // not a reimplementation of it: `SkippedDueToEarlierFailure` models
    // "never handed to handle_message this cycle because an earlier message
    // in the batch already returned NakAndStopBatch", i.e. the `break` in
    // `main`'s loop, which `decide_msg` itself cannot express (it only
    // decides one message at a time).
    #[derive(Debug, PartialEq, Eq)]
    enum BatchOutcome {
        Acked,
        NakedAndContinued,
        NakedAndBatchStopped,
        SkippedDueToEarlierFailure,
    }

    // Replays `decide_msg` -- the exact function the production batch loop
    // calls -- over a synthetic ordered sequence of `handle_message`
    // outcomes, and additionally models the loop's `break` on
    // `NakAndStopBatch` (a real NATS `Messages` stream can't be driven from
    // a plain unit test, so this is the closest test double for "the rest of
    // the batch is left unconsumed").
    fn simulate_batch_processing(handle_results: &[HandleOutcome]) -> Vec<BatchOutcome> {
        let mut outcomes = Vec::with_capacity(handle_results.len());
        let mut stopped = false;

        for &outcome in handle_results {
            if stopped {
                outcomes.push(BatchOutcome::SkippedDueToEarlierFailure);
                continue;
            }

            match decide_msg(outcome) {
                MsgDecision::AckAndContinue => outcomes.push(BatchOutcome::Acked),
                MsgDecision::NakAndContinue => outcomes.push(BatchOutcome::NakedAndContinued),
                MsgDecision::NakAndStopBatch => {
                    outcomes.push(BatchOutcome::NakedAndBatchStopped);
                    stopped = true;
                }
            }
        }

        outcomes
    }

    // Record-update failures must stop batch processing immediately (see #653) to prevent
    // later messages for the same zone/name/type from reaching handlers and getting acked
    // while earlier stale retries are still pending redelivery.
    #[test]
    fn decide_msg_acks_on_success_and_naks_and_stops_on_record_failure() {
        assert_eq!(decide_msg(HandleOutcome::Ack), MsgDecision::AckAndContinue);
        assert_eq!(
            decide_msg(HandleOutcome::RetryStopBatch),
            MsgDecision::NakAndStopBatch
        );
    }

    // What: flush failures NAK but keep batch going.
    // Why: flush has no ordering hazard unlike record updates.
    // From: PR #738
    #[test]
    fn decide_msg_naks_and_continues_on_no_hazard_failure() {
        assert_eq!(
            decide_msg(HandleOutcome::RetryContinueBatch),
            MsgDecision::NakAndContinue
        );
    }

    // Proves the #653 fix: a retryable record-update failure for an earlier
    // message in a batch (e.g. message A, an older update for
    // zone/name/type X) must stop the rest of that batch from being
    // consumed -- otherwise a later message for the same key (message B, a
    // newer update for X) could reach handle_message, succeed, and get
    // acked while A is still pending redelivery. A's later redelivery would
    // then reapply stale data over B's newer state. This test uses a
    // synthetic handle_message result sequence (no real NATS connection) to
    // check that nothing after the first `RetryStopBatch` is ever processed
    // ("Acked") within the same batch.
    #[test]
    fn batch_processing_stops_after_first_retryable_record_failure() {
        // Index 0: unrelated message succeeds.
        // Index 1: message A fails transiently (simulated 5xx).
        // Index 2: message B, a newer update for the same key as A, is
        //          later in this same batch and must NOT be acked now.
        // Index 3: any further message in the batch must also be skipped.
        let handle_results = vec![
            HandleOutcome::Ack,
            HandleOutcome::RetryStopBatch,
            HandleOutcome::Ack,
            HandleOutcome::Ack,
        ];

        let outcomes = simulate_batch_processing(&handle_results);

        assert_eq!(
            outcomes,
            vec![
                BatchOutcome::Acked,
                BatchOutcome::NakedAndBatchStopped,
                BatchOutcome::SkippedDueToEarlierFailure,
                BatchOutcome::SkippedDueToEarlierFailure,
            ]
        );
    }

    // Baseline: when nothing in the batch fails, every message is acked and
    // consumption never stops early. Guards against a fix that over-eagerly
    // halts batches even without a failure.
    #[test]
    fn batch_processing_continues_when_all_succeed() {
        let handle_results = vec![HandleOutcome::Ack, HandleOutcome::Ack, HandleOutcome::Ack];

        let outcomes = simulate_batch_processing(&handle_results);

        assert_eq!(
            outcomes,
            vec![
                BatchOutcome::Acked,
                BatchOutcome::Acked,
                BatchOutcome::Acked,
            ]
        );
    }

    // A record-update failure as the very first message in the batch must
    // stop immediately -- nothing at all gets acked this cycle.
    #[test]
    fn batch_processing_stops_immediately_on_first_record_failure() {
        let handle_results = vec![
            HandleOutcome::RetryStopBatch,
            HandleOutcome::Ack,
            HandleOutcome::Ack,
        ];

        let outcomes = simulate_batch_processing(&handle_results);

        assert_eq!(
            outcomes,
            vec![
                BatchOutcome::NakedAndBatchStopped,
                BatchOutcome::SkippedDueToEarlierFailure,
                BatchOutcome::SkippedDueToEarlierFailure,
            ]
        );
    }

    // What: flush failure continues batch, record failure stops it.
    // Why: only record updates have ordering hazard.
    // From: PR #738
    #[test]
    fn batch_processing_continues_past_flush_failure_but_stops_on_record_failure() {
        // Index 0: flush fails transiently (e.g. recursor 5xx) -- has no
        //          ordering hazard, so processing must continue.
        // Index 1: unrelated record update succeeds right after it.
        // Index 2: a record update fails transiently -- THIS must stop the
        //          batch, unlike the flush failure at index 0.
        // Index 3: must be skipped, since it's after the record failure.
        let handle_results = vec![
            HandleOutcome::RetryContinueBatch,
            HandleOutcome::Ack,
            HandleOutcome::RetryStopBatch,
            HandleOutcome::Ack,
        ];

        let outcomes = simulate_batch_processing(&handle_results);

        assert_eq!(
            outcomes,
            vec![
                BatchOutcome::NakedAndContinued,
                BatchOutcome::Acked,
                BatchOutcome::NakedAndBatchStopped,
                BatchOutcome::SkippedDueToEarlierFailure,
            ]
        );
    }

    // Issue #772: the applied-sequence watermark must treat any sequence <= the
    // highest already applied for a key as stale, so a redelivered older
    // message -- or an exact re-delivery of the same one -- is skipped instead
    // of clobbering newer state. This is the core invariant the cross-batch
    // guard in handle_dns_record relies on.
    #[test]
    fn applied_sequences_marks_older_and_equal_as_stale() {
        let mut seqs = AppliedSequences::default();
        let key = record_key("lan", "host.lan.", "A");
        assert!(
            !seqs.is_stale(&key, 100),
            "the first sight of a key can never be stale"
        );
        seqs.record_applied(key.clone(), 100);
        assert!(
            seqs.is_stale(&key, 100),
            "an exact redelivery (equal seq) must be treated as stale"
        );
        assert!(seqs.is_stale(&key, 99), "an older seq must be stale");
        assert!(!seqs.is_stale(&key, 101), "a newer seq must not be stale");
    }

    // Issue #772 core scenario, modeled without a live NATS connection: message
    // B (newer, seq 105) for key X is applied first -- as happens when it
    // arrives in the fetch batch right after message A's failure stopped the
    // previous batch -- and then message A (older, seq 100) for the SAME key
    // redelivers after its NAK. The guard must classify A as stale so it is
    // dropped rather than reapplying its old state over B.
    #[test]
    fn applied_sequences_closes_cross_batch_clobber_scenario() {
        let mut seqs = AppliedSequences::default();
        let key = record_key("lan", "host.lan.", "A");
        assert!(!seqs.is_stale(&key, 105));
        seqs.record_applied(key.clone(), 105);
        assert!(
            seqs.is_stale(&key, 100),
            "A's post-NAK redelivery at the older seq must be recognized as stale"
        );
    }

    // Guards against an overly-coarse key: applying a newer seq for one record
    // must never make an unrelated record (different name, or same name but a
    // different record type) look stale and get its legitimate update dropped.
    #[test]
    fn applied_sequences_are_per_key_independent() {
        let mut seqs = AppliedSequences::default();
        let a_v4 = record_key("lan", "a.lan.", "A");
        let a_v6 = record_key("lan", "a.lan.", "AAAA");
        let b_v4 = record_key("lan", "b.lan.", "A");
        seqs.record_applied(a_v4.clone(), 200);
        assert!(
            !seqs.is_stale(&a_v6, 1),
            "same name, different type is an independent key"
        );
        assert!(
            !seqs.is_stale(&b_v4, 1),
            "a different name is an independent key"
        );
        assert!(seqs.is_stale(&a_v4, 200));
    }

    // Issue #772: the key must be normalized so the same logical record
    // published with a trailing dot or different case (as the reconciler and
    // the Admin UI routes can each do) maps to ONE watermark. If these produced
    // different keys, a stale redelivery under one spelling could clobber newer
    // state written under the other, defeating the guard entirely.
    #[test]
    fn record_key_normalizes_trailing_dot_and_case() {
        assert_eq!(
            record_key("lan", "Host.LAN.", "a"),
            record_key("lan.", "host.lan", "A")
        );
    }
}
