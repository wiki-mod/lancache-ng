//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: netdata alarm webhook and its alarm sender.
//! Why: one owner of header, path and alarm fields.
//! From: Issue #858 | PR #1858

use crate::AppState;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use std::sync::Arc;
use subtle::ConstantTimeEq;

pub(crate) const ALARM_TOKEN_HEADER: &str = "X-Netdata-Alarm-Token";
pub(crate) const INGEST_PATH: &str = "/api/netdata-alarms";

// What: netdata custom_sender that POSTs alarms to the ui.
// Why: fields come from NetdataAlarmEvent; no second list.
// From: Issue #858 | PR #1858
pub(crate) fn render_alarm_notify_conf(
    ui_url: &str,
    token_file: &str,
    max_time: &str,
    recipient: &str,
) -> Result<String, String> {
    for value in [ui_url, token_file, max_time, recipient] {
        let plain = |c: char| c.is_ascii_alphanumeric() || "-._:/".contains(c);
        if value.is_empty() || !value.chars().all(plain) {
            return Err(format!("{value:?} is no plain URL or path"));
        }
    }
    let sample = serde_json::to_value(crate::netdata_alarms::NetdataAlarmEvent::default())
        .map_err(|e| format!("cannot list alarm fields: {e}"))?;
    let fields = sample.as_object().ok_or("alarm event is no JSON object")?;
    let json: Vec<String> = fields
        .iter()
        .map(|(key, value)| {
            if value.is_string() {
                format!("\\\"{key}\\\":\\\"$(_lancache_json_escape \"${{{key}}}\")\\\"")
            } else {
                format!("\\\"{key}\\\":${{{key}}}")
            }
        })
        .collect();
    let json = json.join(",");
    let ok = StatusCode::OK.as_u16();
    Ok(format!(
        r#"SEND_CUSTOM="YES"
DEFAULT_RECIPIENT_CUSTOM="{recipient}"
_lancache_json_escape() {{
  printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}}
custom_sender() {{
  local token httpcode
  token="$(cat "{token_file}")" || return 1
  httpcode="$(docurl --max-time {max_time} -X POST -H "Content-Type: application/json" -H "{ALARM_TOKEN_HEADER}: ${{token}}" -d "{{{json}}}" "{ui_url}{INGEST_PATH}")" || {{
    error "lancache-ui alarm POST failed: HTTP ${{httpcode}}"
    return 1
  }}
  [ "${{httpcode}}" = "{ok}" ] && return 0
  error "lancache-ui alarm POST returned HTTP ${{httpcode}}"
  return 1
}}
"#
    ))
}

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
    // What: an empty configured token rejects everything.
    // Why: an unset token must never mean an open endpoint.
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

    // What: an empty token rejects, even an empty header.
    // Why: unconfigured must never mean auth disabled.
    // From: Issue #858
    #[test]
    fn empty_configured_token_always_rejects() {
        assert!(!alarm_token_is_valid(&HeaderMap::new(), ""));
        assert!(!alarm_token_is_valid(&headers_with_token(""), ""));
        assert!(!alarm_token_is_valid(&headers_with_token("anything"), ""));
    }

    // What: sender uses header, path, token, all fields.
    // Why: a mismatch with the route loses alarms silently.
    // From: Issue #858 | PR #1858
    #[test]
    fn alarm_sender_matches_route_and_fields_and_rejects_shell_text() {
        let conf = render_alarm_notify_conf("http://peer.test:1", "/cfg/tok", "7", "rcpt").unwrap();
        for needle in [
            ALARM_TOKEN_HEADER,
            INGEST_PATH,
            "\"/cfg/tok\"",
            "--max-time 7",
            "\"rcpt\"",
            "docurl",
        ] {
            assert!(conf.contains(needle), "missing {needle:?}");
        }
        let sample =
            serde_json::to_value(crate::netdata_alarms::NetdataAlarmEvent::default()).unwrap();
        for field in sample.as_object().unwrap().keys() {
            assert!(conf.contains(&format!("${{{field}}}")), "missing {field}");
        }
        assert!(!conf.contains("/dev/null"));
        assert!(render_alarm_notify_conf("http://peer.test:1$(id)", "/t", "7", "r").is_err());
        assert!(render_alarm_notify_conf("http://peer.test:1", "/t f", "7", "r").is_err());
        assert!(render_alarm_notify_conf("http://peer.test:1", "/t", "7;x", "r").is_err());
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
