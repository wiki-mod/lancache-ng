
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! `POST /api/netdata-alarms`: ingest endpoint for the `netdata` container's
//! `custom_sender()` alarm-notify integration (bug hunt #849,
//! `docs/bug-hunt/observability.md` finding #3: Netdata's own health.d
//! alarms had no notification integration or Admin UI surface of their
//! own). Registered in `main.rs`'s `public_routes` group -- not because it
//! is unauthenticated, but because it is a machine webhook call from a peer
//! container rather than a browser session: it carries no session cookie
//! and cannot present the CSRF token `protected_routes`'s `basic_auth`
//! middleware requires for mutating requests.
//!
//! It is still not an open endpoint. Every request must present a matching
//! `X-Netdata-Alarm-Token` header, checked in constant time against the
//! shared `NETDATA_ALARM_TOKEN` value (see `config.rs` and
//! `deploy/*/docker-compose.yml`'s `netdata:` service command block for how
//! both sides resolve the exact same value via the shared-secrets volume,
//! issue #858). This fails closed the same way
//! `routes/secondaries.rs::register_secondary` already does for
//! `SECONDARY_REGISTRATION_TOKEN`: an empty/unconfigured token on this side
//! is rejected outright, never silently treated as "auth disabled" -- bug
//! hunt finding #20 already established that every container on the
//! `lancache` Docker network can reach Netdata's own unauthenticated REST
//! API directly, so an unauthenticated *write* endpoint into the Admin UI
//! would be a NEW attack surface (any compromised/malicious container could
//! inject fabricated alarms into the dashboard), not a pre-existing one.

use crate::AppState;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use std::sync::Arc;
use subtle::ConstantTimeEq;

const ALARM_TOKEN_HEADER: &str = "X-Netdata-Alarm-Token";

// Constant-time, fail-closed token check -- same idiom and rationale as
// `routes/secondaries.rs::register_secondary`'s `SECONDARY_REGISTRATION_TOKEN`
// check (an established pattern in this codebase for a machine-to-machine
// shared-secret header), reusing the `subtle` crate already in this crate's
// default `runtime` feature set rather than hand-rolling a new constant-time
// comparison. A byte-length mismatch alone (via `ct_eq` on unequal-length
// slices) would already return "not equal" in non-constant time proportional
// to a length check, not a byte-by-byte guess -- acceptable, since the
// token's fixed generated length is not itself a secret worth hiding.
fn alarm_token_is_valid(headers: &HeaderMap, configured: &str) -> bool {
    // An empty/placeholder-cleared configured token must never be treated as
    // "no auth required" -- see this module's doc comment for why a silent
    // open endpoint here would be worse than simply refusing every request
    // until an operator (or the shared-secret bootstrap) actually resolves
    // a real value.
    if configured.is_empty() {
        return false;
    }
    let presented = match headers
        .get(ALARM_TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
    {
        Some(v) => v,
        None => return false,
    };
    bool::from(presented.as_bytes().ct_eq(configured.as_bytes()))
}

// Accepts `Bytes` rather than axum's `Json<T>` extractor deliberately: the
// default `Json` extractor's built-in rejection handling would already
// avoid a panic on malformed input, but reading the raw body first lets
// this handler check the auth header before spending any work parsing a
// body from an unauthenticated caller, and log a rejection reason instead
// of returning axum's generic rejection body.
pub async fn ingest_alarm(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    if !alarm_token_is_valid(&headers, &state.config.netdata_alarm_token) {
        return StatusCode::UNAUTHORIZED;
    }

    let event: crate::netdata_alarms::NetdataAlarmEvent = match serde_json::from_slice(&body) {
        Ok(e) => e,
        Err(e) => {
            // Malformed input from a peer container is worth a log line (a
            // future Netdata version changing its custom_sender() field
            // set, a truncated body from a network hiccup) but never a
            // reason to fail loudly -- this endpoint's whole job is to
            // survive whatever alarm-notify.sh's shell-built JSON sends it,
            // matching AG-CODE-002's WHY-comment intent: the "why" here is
            // that a peer container's malformed request must never be able
            // to take down or panic the Admin UI process.
            tracing::warn!("rejecting malformed netdata alarm payload: {}", e);
            return StatusCode::BAD_REQUEST;
        }
    };

    let path = state.config.netdata_alarms_file.clone();
    // Holds the dedicated alarms-file lock for the read-modify-write inside
    // append_alarm -- see that function's own doc comment for why this
    // mutual exclusion is required (a lost-update race between two
    // concurrent POSTs), not merely nice-to-have. A dedicated lock, not
    // AppState::file_lock, since that one already serializes an unrelated
    // resource (routes/domains.rs's cdn-domains.txt writes) and conflating
    // the two would add pointless contention between two features that
    // share nothing but "some file write happens here".
    let result = {
        let _guard = state
            .netdata_alarms_lock
            .lock()
            .expect("netdata alarms lock poisoned");
        crate::netdata_alarms::append_alarm(&path, event)
    };

    match result {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::warn!("failed to persist netdata alarm: {}", e);
            StatusCode::SERVICE_UNAVAILABLE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers_with_token(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(ALARM_TOKEN_HEADER, token.parse().unwrap());
        headers
    }

    // The core fail-closed contract: an unconfigured (empty) token must
    // never be treated as "auth disabled", even if the caller happens to
    // present an empty header too -- see this module's doc comment (bug
    // hunt finding #20) for why an open endpoint here would be a real new
    // attack surface, not a harmless default.
    #[test]
    fn empty_configured_token_always_rejects() {
        assert!(!alarm_token_is_valid(&HeaderMap::new(), ""));
        assert!(!alarm_token_is_valid(&headers_with_token(""), ""));
        assert!(!alarm_token_is_valid(&headers_with_token("anything"), ""));
    }

    // Baseline correctness: the exact right token is accepted; a wrong or
    // absent header is rejected.
    #[test]
    fn matching_token_accepts_mismatched_or_missing_rejects() {
        let configured = "real-token-value";
        assert!(alarm_token_is_valid(
            &headers_with_token(configured),
            configured
        ));
        assert!(!alarm_token_is_valid(
            &headers_with_token("wrong-token"),
            configured
        ));
        assert!(!alarm_token_is_valid(&HeaderMap::new(), configured));
    }
}
