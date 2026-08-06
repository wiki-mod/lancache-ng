//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI routes for the PowerDNS zone/record known-good snapshot rollback
//! mechanism (#628). Mirrors the existing Kea snapshot list/rollback UI
//! (`routes/dhcp.rs`'s `fetch_kea_snapshot_summaries`/`rollback_kea_snapshot`,
//! `templates/dhcp.html`'s snapshot table) -- see those for the pattern this
//! follows. Unlike Kea, the actual snapshot storage/retention/rollback logic
//! all lives in a separate process (`services/dns/nats-subscriber`'s
//! `zone_snapshots.rs`/`rollback_listener.rs`), reached over
//! `DNS_ROLLBACK_URL` (default `http://dns-standard:8083`) -- this module is
//! a thin HTTP forwarder to that listener, not a second implementation of
//! its logic.
//!
//! Scoped to `dns-standard` only for now, the same single-primary
//! convention `PDNS_AUTH_URL`/`PDNS_REC_URL`/`fetch_lan_records` already use
//! (`config.rs`'s `pdns_auth_url`/`pdns_rec_url` defaults, `routes/
//! domains.rs`'s `fetch_lan_records`). The rollback listener itself runs
//! identically on every dns node (`nats-subscriber` is in every `dns-*`
//! container), so pointing this at `dns-ssl` too later needs no backend
//! change, only another URL/route here -- not done in this PR because
//! `local.lan.`/the private reverse zones aren't NATS-replicated between
//! `dns-standard` and `dns-ssl` in the first place (see
//! docs/known-good-config-snapshots.md's "Secondary nodes and NATS
//! replication"), so a `dns-ssl`-side rollback UI would need its own
//! explicit scoping decision, not a reflexive copy of this one -- real
//! scope creep for this issue, tracked as a follow-up rather than solved
//! here.

use crate::AppState;
use axum::extract::{Form, State};
use axum::http::HeaderMap;
use axum::response::Redirect;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Serialize, Clone)]
pub struct ZoneSnapshotSummary {
    pub id: String,
    pub created_unix: u64,
}

#[derive(Serialize, Clone)]
pub struct ZoneSnapshotGroup {
    pub zone: String,
    pub snapshots: Vec<ZoneSnapshotSummary>,
}

#[derive(Deserialize)]
pub struct RollbackZoneForm {
    pub csrf_token: String,
    pub zone: String,
    pub snapshot_id: String,
}

/// Fetches every rollback-managed zone's snapshot list from
/// `nats-subscriber`'s listener (`GET {DNS_ROLLBACK_URL}/snapshots`). Never
/// errors outward: an unreachable listener (container restarting, network
/// hiccup) renders as "no snapshots available yet" on the `/domains` page
/// rather than failing the whole page -- matches `fetch_kea_snapshot_
/// summaries`'s own fail-soft treatment of a missing/unreadable snapshot
/// store.
pub async fn fetch_zone_snapshot_groups(state: &AppState) -> Vec<ZoneSnapshotGroup> {
    let url = format!("{}/snapshots", state.config.dns_rollback_url);
    let resp = match state
        .http_client
        .get(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        _ => return Vec::new(),
    };
    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let Some(zones) = body.get("zones").and_then(Value::as_object) else {
        return Vec::new();
    };

    let mut groups: Vec<ZoneSnapshotGroup> = zones
        .iter()
        .map(|(zone, snaps)| ZoneSnapshotGroup {
            zone: zone.clone(),
            snapshots: parse_zone_snapshot_summaries(snaps),
        })
        .collect();
    // Stable, deterministic ordering for template rendering -- the listener
    // returns a JSON object (unordered from serde_json's default BTreeMap
    // representation, which happens to already be alphabetical, but this
    // makes that an explicit contract of this function rather than an
    // incidental side effect of the underlying map's iteration order).
    groups.sort_by(|a, b| a.zone.cmp(&b.zone));
    groups
}

/// Parses one zone's snapshot array from the listener's response shape
/// (`[{"id": "...", "created_unix": 123}, ...]`), skipping any entry missing
/// its `id` rather than failing the whole group -- a partially-malformed
/// response from a mismatched/older `nats-subscriber` version should degrade
/// to "fewer snapshots shown," not "no snapshots for any zone."
fn parse_zone_snapshot_summaries(snapshots: &Value) -> Vec<ZoneSnapshotSummary> {
    snapshots
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|entry| {
                    let id = entry.get("id")?.as_str()?.to_string();
                    let created_unix = entry
                        .get("created_unix")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    Some(ZoneSnapshotSummary { id, created_unix })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Forwards an operator-selected rollback to `nats-subscriber`'s listener
/// (`POST {DNS_ROLLBACK_URL}/rollback`). All of the actual validation
/// (zone whitelist, snapshot-id membership, diff/PATCH/check-zone/flush/
/// republish) happens there -- this handler's only responsibilities are
/// CSRF verification (this project's own per-session token, unrelated to
/// the listener's own `X-API-Key` requirement) and relaying the result.
///
/// Finding #10 (docs/bug-hunt/ui-routes.md, issue #849): this used to always
/// redirect to a plain `/domains` regardless of outcome, logging a non-2xx
/// response or a network failure server-side but giving the operator no
/// visible signal on the page itself that the rollback they just clicked
/// never actually happened. Now reuses `domains.rs`'s existing
/// `?error=<code>` banner mechanism (`domains_page_error_message`) for that
/// specific case -- the same mechanism `add_dns`'s own validation-failure
/// redirect already uses, just not previously wired up here. Deliberately
/// scoped to the two *hard* failure cases only (non-2xx status, or the
/// request never reaching `nats-subscriber` at all): the softer case just
/// below (a 2xx response whose body reports `flush_ok: false` or
/// `zone_check_passed: false` -- the rollback itself was applied, but a
/// downstream step degraded) still only logs, matching this module's own
/// original reasoning that a single fixed banner code cannot usefully
/// distinguish "rollback failed entirely" from "rollback applied, cache
/// flush partially failed" without a real per-request detail channel this
/// UI does not have yet.
pub async fn rollback_zone_snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RollbackZoneForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;

    let url = format!("{}/rollback", state.config.dns_rollback_url);
    let payload = json!({"zone": form.zone, "snapshot_id": form.snapshot_id}).to_string();
    let result = state
        .http_client
        .post(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .header("Content-Type", "application/json")
        .body(payload)
        .send()
        .await;

    // Finding #10: tracks whether the rollback request itself reached
    // nats-subscriber and was accepted (2xx) -- the redirect target below
    // depends on this, separate from the softer flush_ok/zone_check_passed
    // nuance handled entirely within the success arm's own logging.
    let rollback_request_succeeded = matches!(&result, Ok(resp) if resp.status().is_success());

    match result {
        Ok(resp) if resp.status().is_success() => {
            // A 2xx here only means `nats-subscriber` applied the rollback
            // PATCH and returned a response -- `rollback_response_body`
            // (rollback_listener.rs) can still carry `flush_ok: false` /
            // `zone_check_passed: false` in that same 2xx body when the
            // post-rollback cache-flush or the `pdnsutil check-zone`
            // confirmation failed. This still redirects as success (no
            // flash-message/banner mechanism exists in this UI today to
            // surface a partial failure inline -- adding one is a real
            // follow-up, not done here), but the body is now at least
            // parsed and logged so the operator's own log tail or `journalctl`
            // shows exactly which names failed to flush, instead of that
            // signal being read from the response and then thrown away
            // entirely.
            match resp.json::<Value>().await {
                Ok(body) => {
                    let flush_ok = body
                        .get("flush_ok")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    let zone_check_passed = body
                        .get("zone_check_passed")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    if !flush_ok {
                        tracing::error!(
                            zone = %form.zone,
                            snapshot_id = %form.snapshot_id,
                            flush_failed_names = %body.get("flush_failed_names").cloned().unwrap_or(json!([])),
                            "zone rollback applied but the post-rollback cache-flush failed for one or more names -- affected clients may see stale answers until TTL expiry"
                        );
                    }
                    if !zone_check_passed {
                        tracing::error!(
                            zone = %form.zone,
                            snapshot_id = %form.snapshot_id,
                            "zone rollback applied but pdnsutil check-zone failed post-rollback -- inspect the zone manually"
                        );
                    }
                }
                Err(e) => {
                    tracing::error!(
                        error = %e,
                        zone = %form.zone,
                        snapshot_id = %form.snapshot_id,
                        "zone rollback succeeded but its response body could not be decoded, so flush/zone-check status is unknown"
                    );
                }
            }
        }
        Ok(resp) => {
            tracing::error!(
                status = %resp.status(),
                zone = %form.zone,
                snapshot_id = %form.snapshot_id,
                "zone rollback request rejected by nats-subscriber"
            );
        }
        Err(e) => {
            tracing::error!(
                error = %e,
                zone = %form.zone,
                snapshot_id = %form.snapshot_id,
                "zone rollback request failed to reach nats-subscriber"
            );
        }
    }

    Ok(Redirect::to(zone_rollback_redirect_location(
        rollback_request_succeeded,
    )))
}

// Finding #10 (docs/bug-hunt/ui-routes.md, issue #849): the actual
// success/failure redirect decision, pulled out as a pure function so it
// has a unit test independent of a live nats-subscriber connection (which
// the surrounding handler cannot practically be tested against without a
// mock HTTP server this codebase does not otherwise use).
fn zone_rollback_redirect_location(succeeded: bool) -> &'static str {
    if succeeded {
        "/domains"
    } else {
        "/domains?error=zone_rollback_failed"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Finding #10 (docs/bug-hunt/ui-routes.md, issue #849): the actual bug
    // this test locks in -- a failed rollback must redirect with the
    // error-banner query parameter, not the plain success URL, so the
    // operator gets a visible signal instead of a silent, misleadingly
    // "successful"-looking redirect.
    #[test]
    fn zone_rollback_redirect_location_signals_failure_via_query_param() {
        assert_eq!(zone_rollback_redirect_location(true), "/domains");
        assert_eq!(
            zone_rollback_redirect_location(false),
            "/domains?error=zone_rollback_failed"
        );
    }

    // Snapshots missing the "id" field must be silently skipped so a partially-malformed response degrades gracefully instead of losing all snapshots.
    #[test]
    fn parse_zone_snapshot_summaries_skips_entries_missing_an_id() {
        let snaps = json!([
            {"id": "00000000001000000000", "created_unix": 1000},
            {"created_unix": 2000},
            {"id": "00000000002000000000", "created_unix": 3000}
        ]);
        let parsed = parse_zone_snapshot_summaries(&snaps);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].id, "00000000001000000000");
        assert_eq!(parsed[1].id, "00000000002000000000");
    }

    // Missing created_unix must default to 0 instead of failing, allowing older/partially-specified snapshot formats to parse gracefully.
    #[test]
    fn parse_zone_snapshot_summaries_defaults_a_missing_created_unix_to_zero() {
        let snaps = json!([{"id": "abc"}]);
        let parsed = parse_zone_snapshot_summaries(&snaps);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].created_unix, 0);
    }

    // Non-array values (null, objects) must return an empty vector instead of panicking, allowing robust handling of unexpected response shapes.
    #[test]
    fn parse_zone_snapshot_summaries_returns_empty_for_a_non_array_value() {
        assert!(parse_zone_snapshot_summaries(&json!(null)).is_empty());
        assert!(parse_zone_snapshot_summaries(&json!({})).is_empty());
    }
}
