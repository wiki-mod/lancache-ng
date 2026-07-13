//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! NATS JetStream subscriber: consumes DNS record updates and applies them to PowerDNS API.

use async_nats::jetstream;
use futures::StreamExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Serialize, Deserialize, Clone)]
struct DNSRecord {
    action: String,
    zone: String,
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    #[serde(default)]
    ttl: Option<i32>,
    #[serde(default)]
    records: Option<Vec<HashMap<String, serde_json::Value>>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct RRset {
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    ttl: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    changetype: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    records: Option<Vec<HashMap<String, serde_json::Value>>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneUpdate {
    rrsets: Vec<RRset>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ZoneInfo {
    rrsets: Vec<RRset>,
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

    // Main fetch loop with exponential backoff (#87 fix)
    let mut backoff_secs = 1u64;
    const MAX_BACKOFF_SECS: u64 = 30;

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
                // Codex review (PR #738) finding 1: `consumer.fetch()` uses
                // async-nats's `no_wait: true` batch mode (confirmed in
                // async-nats 0.49.1's `FetchBuilder::messages()`), so it
                // returns immediately with whatever is already available
                // instead of waiting up to `expires` for new messages. If a
                // retryable PDNS failure stops a batch below, the NAK'd
                // message (and, during a real outage, likely more backlog
                // behind it) can be immediately available again on the very
                // next iteration of this outer `loop`, with nothing pacing
                // the fetch/HTTP-call rate. Track that here so we can apply
                // the same backoff used for stream/fetch errors instead of
                // busy-spinning HTTP calls at a down PDNS.
                let mut had_retryable_batch_stop = false;

                while let Some(msg_result) = messages.next().await {
                    match msg_result {
                        Ok(msg) => {
                            let result = handle_message(&msg, &pdns_api_key, &http_client).await;
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
                                    // Codex review (PR #738) finding 3: a retryable
                                    // `lancache.dns.flush` failure (recursor cache-flush
                                    // endpoint down/erroring) does NOT create the same
                                    // stale-record-clobber hazard that a `lancache.dns.record`
                                    // failure does -- flush order relative to other flushes
                                    // isn't safety-critical the way record-update order is.
                                    // Stopping the whole batch behind a flush failure would
                                    // needlessly delay unrelated, healthy record updates later
                                    // in the same batch. So: NAK with a short delay (still
                                    // better than the pre-#653 "just don't ack" approach) but
                                    // keep consuming the rest of the batch, matching the
                                    // pre-#653 behavior for this message class.
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
                                    // A retryable (5xx) failure must not let a LATER message
                                    // in this SAME fetched batch get acked ahead of it. Example
                                    // race this closes: message A (older update for
                                    // zone/name/type X) fails transiently here; message B (a
                                    // newer update for that same X) is later in the batch and
                                    // would otherwise succeed and get acked. A then sits unacked
                                    // until AckWait, gets redelivered, and reapplies --
                                    // clobbering B's newer state with stale data. The previous
                                    // fix only added a 100ms sleep before the *next fetch loop
                                    // iteration*, which did nothing to stop the rest of the
                                    // *current* batch (already pulled via messages.next()) from
                                    // being processed and acked.
                                    //
                                    // Fix: NAK this message with an explicit delay (a precise
                                    // server-side "retry me later" signal, rather than relying
                                    // on implicit AckWait timeout) and immediately stop
                                    // consuming the rest of the batch. Messages left unconsumed
                                    // here were already pulled from the server but never
                                    // acked/nakked, so JetStream simply redelivers them on its
                                    // own after AckWait -- no message is lost, they're just
                                    // deferred to a later fetch cycle where ordering relative
                                    // to this retry is no longer at risk.
                                    //
                                    // NOTE (Codex review, PR #738, finding 2): a narrower,
                                    // *cross-batch* version of this same race is still
                                    // possible -- an even-newer update for the same key could
                                    // arrive in the *next* fetch (issued immediately after this
                                    // `break`, since `fetch()` is `no_wait`) and get acked
                                    // before this abandoned tail redelivers via AckWait. Closing
                                    // that fully requires either strict single-message
                                    // processing or key-aware/sequence-aware writes and is out
                                    // of scope for this targeted fix; see the reply on that
                                    // review thread for why NAK-ing the tail to a short delay
                                    // (which looks like an obvious fix) would actually make
                                    // ordering *worse*, not better, by racing this abandoned
                                    // message's redelivery against the same short delay used by
                                    // the message that triggered the stop.
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

                // Apply backoff on stream errors or a retryable-failure batch
                // stop, or reset on a fully clean batch. Stream errors surface
                // via messages.next(), not fetch(), so we must handle them
                // here rather than in the Err(fetch) arm. The batch-stop case
                // is handled the same way (Codex review, PR #738, finding 1):
                // without this, a PDNS outage with backlogged messages causes
                // an immediate re-fetch (see the `had_retryable_batch_stop`
                // comment above on why `fetch()` doesn't wait on its own) and
                // this loop busy-spins HTTP calls at a service that's down.
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

/// Outcome of handling a single fetched message, distinguishing WHICH kind
/// of retry is needed. Codex review (PR #738) finding 3: the original #653
/// fix mapped every `handle_message` failure to a full batch-stop, but the
/// stale-record-clobber hazard that justifies stopping the batch (see
/// `MsgDecision::NakAndStopBatch` below) is specific to `lancache.dns.record`
/// updates, which are keyed by zone/name/type and can race against a newer
/// update for that same key. `lancache.dns.flush` (PDNS Recursor cache
/// flush) has no such key-ordering hazard -- flushing late doesn't clobber a
/// newer flush -- so a flush failure blocking unrelated, healthy record
/// updates later in the same batch would be an unnecessary regression versus
/// the pre-#653 behavior (which never stopped the batch for ANY failure
/// type).
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

async fn handle_message(
    msg: &async_nats::jetstream::Message,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
) -> HandleOutcome {
    let subject = msg.subject.as_ref();

    if subject.starts_with("lancache.dns.heartbeat") {
        // Ignore heartbeat messages
        return HandleOutcome::Ack;
    }

    if subject == "lancache.dns.record" {
        return if handle_dns_record(msg, pdns_api_key, http_client).await {
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

fn dns_record_to_zone_update(record: &DNSRecord) -> Result<ZoneUpdate, String> {
    let (changetype, ttl_val, records_val) = match record.action.as_str() {
        "delete" => (Some("DELETE".to_string()), None, None),
        "replace" => (
            Some("REPLACE".to_string()),
            record.ttl,
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

async fn handle_dns_record(
    msg: &async_nats::jetstream::Message,
    pdns_api_key: &str,
    http_client: &Arc<Client>,
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

    let url = format!(
        "http://127.0.0.1:8081/api/v1/servers/localhost/zones/{}",
        record.zone
    );

    // #68 fix: use shared client instead of creating new one
    let result = http_client
        .patch(&url)
        .header("X-API-Key", pdns_api_key)
        .header("Content-Type", "application/json")
        .body(payload)
        .send()
        .await;

    match result {
        Ok(resp) => {
            if resp.status().is_success() {
                println!(
                    "Updated DNS record: zone={} name={} type={} action={}",
                    record.zone, record.name, record.record_type, record.action
                );
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
    // published before this fix, or from any other future publisher that
    // doesn't include one.
    let domain = match serde_json::from_slice::<FlushRequest>(&msg.payload) {
        Ok(req) => req.domain,
        Err(_) => ".".to_string(),
    };
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

                    let record_payload = json!({
                        "action": "replace",
                        "zone": "lan",
                        "name": rrset.name,
                        "type": rrset.record_type,
                        "ttl": rrset.ttl,
                        "records": rrset.records,
                    });

                    let payload = match serde_json::to_vec(&record_payload) {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("Reconciler: error marshaling record: {}", e);
                            continue;
                        }
                    };

                    let mut headers = async_nats::HeaderMap::new();
                    headers.insert(async_nats::header::NATS_MESSAGE_ID, msg_id.as_str());

                    // #69 fix: properly await the PublishAckFuture
                    match js
                        .publish_with_headers("lancache.dns.record", headers, payload.into())
                        .await
                    {
                        Ok(publish_ack) => match publish_ack.await {
                            Ok(_) => {}
                            Err(e) => {
                                eprintln!("Reconciler: error waiting for publish ack: {}", e);
                            }
                        },
                        Err(e) => {
                            eprintln!("Reconciler: error publishing record: {}", e);
                        }
                    }
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

    #[test]
    fn dns_record_to_zone_update_replace_without_ttl() {
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
        assert!(rrset.ttl.is_none());
        assert!(rrset.records.is_some());
    }

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

    #[test]
    fn decide_msg_acks_on_success_and_naks_and_stops_on_record_failure() {
        assert_eq!(decide_msg(HandleOutcome::Ack), MsgDecision::AckAndContinue);
        assert_eq!(
            decide_msg(HandleOutcome::RetryStopBatch),
            MsgDecision::NakAndStopBatch
        );
    }

    // Codex review (PR #738) finding 3: a retryable failure with no
    // ordering hazard (flush) must NAK but keep the batch going, unlike a
    // record-update failure.
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

    // Codex review (PR #738) finding 3 regression test: a flush failure
    // must NOT stop the batch -- a later, unrelated record update in the
    // same batch must still be processed and acked, unlike the record-
    // failure case above.
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
}
