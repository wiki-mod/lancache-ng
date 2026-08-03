//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Active NATS connection termination for a removed/rotated secondary (issue
//! #681, follow-up to #621's per-secondary auth-callout identity).
//!
//! ## The gap this closes
//! `nats_auth_callout.rs`'s responder re-checks the `secondaries` table on
//! every connection *attempt*, so deleting a row (`remove_secondary`) or
//! rotating its password (`rotate_token`) already revokes a secondary's
//! access on its very next reconnect -- immediately, with zero effect on any
//! other secondary. But a secondary that holds its streaming NATS connection
//! open at the exact moment it is removed/rotated does not reconnect on its
//! own; it keeps using its already-issued user JWT (`USER_JWT_TTL_SECS` in
//! `nats_auth_callout.rs`, 90 days) until something forces it to. This module
//! adds that "something": actively kicking the live connection off the NATS
//! server the moment the DB-level revocation lands, instead of waiting for a
//! natural reconnect or JWT expiry that may never come.
//!
//! ## Why this needs a NATS system account (new architecture, confirmed live)
//! Disconnecting a specific connection requires nats-server's
//! `$SYS.REQ.SERVER.<server_id>.KICK` request (payload `{"cid": <connection
//! id>}` -- `KickClientReq` in nats-server's own `server/events.go`), and
//! finding that connection's ID for a given username requires
//! `$SYS.REQ.SERVER.PING.CONNZ` (payload `{"auth": true, "user": "<name>"}`).
//! Both live in NATS's **system account** subject space, which this project
//! did not have before this issue: every existing static role (UI, DNS-writer,
//! DNS-replica, callout-bypass) and every callout-authenticated secondary
//! lives in the implicit default account (`$G`), and nats-server does not
//! expose `$SYS.REQ.SERVER.*` to `$G` clients at all -- confirmed against the
//! NATS docs (`running-a-nats-service/configuration/sys_accounts`: "the
//! default global account `$G` does not publish advisories" / system events
//! require "a user belonging to the designated system account") and
//! empirically, against a real `nats-server:2.14.3` container (the exact
//! version this project pins via `nats:2-alpine@sha256:c11af9...` in every
//! `deploy/*/docker-compose.yml`) on a throwaway test rig: a `$G` client
//! could not reach `$SYS.REQ.SERVER.PING.CONNZ`/`KICK` at all, while a client
//! authenticated into a newly added, minimal `accounts { SYS: {...} }
//! system_account: SYS` block could -- and that addition coexists with the
//! existing flat `authorization {}` block with no observed effect on where
//! the four static roles/secondaries live (still `$G`) or on JetStream's
//! `LANCACHE_DNS` stream (still owned by `$G`, unaffected). `NATS_SYS_USER`/
//! `NATS_SYS_PASSWORD` (`Config`, `services/nats/nats.conf`) is the sole
//! member of that `SYS` account; it carries no application subject
//! permissions and is used by nothing except this module.
//!
//! `nats_auth_callout.rs`'s own `$SYS.REQ.USER.AUTH` responder does NOT need
//! any of this: nats-server special-cases the auth-callout request/response
//! round trip into the callout's own account (`$G` here), which is a
//! narrower, different mechanism than the general `$SYS.REQ.SERVER.*`
//! system-services API this module depends on.
//!
//! ## Why CONNZ's `user` filter is safe to key on for a callout-authenticated
//! connection
//! A secondary's live connection is authenticated via a per-connection user
//! JWT the callout responder issues (see `nats_auth_callout.rs`), but the
//! *client* still presents its own plaintext username (the `nats_user` DB
//! column -- see `routes/secondaries.rs`) in its CONNECT frame, same as any
//! other client. nats-server's own `getRawAuthUser()` (`server/client.go`)
//! checks `c.opts.Username` -- the CONNECT-frame username -- *before* ever
//! falling back to a JWT-derived identity, so `connz`'s `authorized_user`
//! field (and the `{"auth": true, "user": "<name>"}` CONNZ filter this module
//! sends) reports and matches exactly that CONNECT-frame username for a
//! callout-authenticated connection, not some JWT subject/NKey. Confirmed
//! against the real nats-server source for the pinned 2.14.3 version, and
//! exercised end-to-end (not just read from source) by
//! `scripts/nats-secondary-auth-callout-simulation.sh`.
//!
//! ## Ordering is load-bearing: revoke in the DB first, kick second
//! `KICK` alone does not revoke anything -- a kicked client with still-valid
//! credentials simply reconnects and passes auth-callout again. The DB write
//! (`DELETE FROM secondaries` / `UPDATE ... SET nats_password_hash`) MUST
//! commit before `disconnect_secondary` runs, so the reconnect KICK forces
//! fails auth-callout instead of quietly succeeding. Both call sites in
//! `routes/secondaries.rs` already do the DB write first and call this
//! module strictly afterward -- do not reorder that.
//!
//! ## Fire-and-forget by design
//! Both call sites spawn this as a background task rather than awaiting it
//! inline: the DB-level revocation (the property #621 already delivers) has
//! already committed by the time this runs, so a slow or unreachable NATS
//! system account must not add multi-second latency to the Admin UI's
//! remove/rotate HTTP response. A connection that cannot be reached or kicked
//! right now still cannot authenticate on its next reconnect attempt -- this
//! module only shrinks the exposure window for an already-open connection,
//! it is not the sole revocation mechanism.

use crate::AppState;
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Duration;

const CONNZ_REQUEST_SUBJECT: &str = "$SYS.REQ.SERVER.PING.CONNZ";
const NATS_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const NATS_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
struct ConnzEnvelope {
    server: ServerInfo,
    #[serde(default)]
    data: Option<ConnzData>,
    #[serde(default)]
    error: Option<Value>,
}

#[derive(Deserialize)]
struct ServerInfo {
    id: String,
}

#[derive(Deserialize)]
struct ConnzData {
    #[serde(default)]
    connections: Vec<ConnEntry>,
}

#[derive(Deserialize)]
struct ConnEntry {
    cid: u64,
}

#[derive(Deserialize)]
struct KickEnvelope {
    #[serde(default)]
    error: Option<Value>,
}

/// Looks up every currently-live NATS connection authenticated as
/// `nats_user` (CONNZ, filtered server-side) and force-disconnects each one
/// (KICK). Returns the number actually kicked -- `Ok(0)` is the common,
/// expected case (the secondary was not connected at the moment it was
/// removed/rotated), not an error; only a genuine failure to reach the NATS
/// system-services API itself returns `Err`. See the module docs above for
/// why callers treat both as non-fatal to the request that triggered this.
pub async fn disconnect_secondary(state: &AppState, nats_user: &str) -> Result<usize, String> {
    if state.config.nats_sys_user.is_empty() {
        return Err(
            "NATS_SYS_USER is not configured -- cannot reach the NATS system-services API"
                .to_string(),
        );
    }
    let sys_password = state.config.nats_sys_password.clone().unwrap_or_default();

    // A short-lived connection per call, not a shared/background one: removal
    // and rotation are rare, interactive Admin UI actions, so the added
    // connect latency is a fair trade for not having to keep a second
    // long-lived NATS connection (and its own reconnect/retry loop, mirroring
    // connect_nats_with_retry/run_auth_callout) alive for the entire process
    // lifetime just for this occasional operation.
    let client = tokio::time::timeout(
        NATS_CONNECT_TIMEOUT,
        async_nats::ConnectOptions::new()
            .user_and_password(state.config.nats_sys_user.clone(), sys_password)
            .connect(&state.config.nats_url),
    )
    .await
    .map_err(|_| "timed out connecting to NATS as the system account".to_string())?
    .map_err(|e| format!("failed to connect to NATS as the system account: {e}"))?;

    let connz_request = serde_json::to_vec(&json!({"auth": true, "user": nats_user}))
        .map_err(|e| format!("failed to serialize CONNZ request: {e}"))?;

    let connz_response = tokio::time::timeout(
        NATS_REQUEST_TIMEOUT,
        client.request(CONNZ_REQUEST_SUBJECT, connz_request.into()),
    )
    .await
    .map_err(|_| "timed out waiting for a CONNZ response".to_string())?
    .map_err(|e| format!("CONNZ request failed: {e}"))?;

    let envelope: ConnzEnvelope = serde_json::from_slice(&connz_response.payload)
        .map_err(|e| format!("failed to parse CONNZ response: {e}"))?;
    if let Some(err) = envelope.error {
        return Err(format!("CONNZ request returned an error: {err}"));
    }
    // No `data` field is the same "nothing matched" shape nats-server uses
    // elsewhere in this response family; either way, no connections means
    // nothing to kick -- the common, expected case, not an error.
    let Some(data) = envelope.data else {
        return Ok(0);
    };
    let server_id = envelope.server.id;

    let mut kicked = 0usize;
    for conn in data.connections {
        let kick_subject = format!("$SYS.REQ.SERVER.{server_id}.KICK");
        let kick_request = match serde_json::to_vec(&json!({"cid": conn.cid})) {
            Ok(bytes) => bytes,
            Err(err) => {
                tracing::warn!(
                    "nats_kick: failed to serialize KICK request for cid {} (secondary {}): {}",
                    conn.cid,
                    nats_user,
                    err
                );
                continue;
            }
        };

        // Best-effort per connection: one failed/timed-out KICK must not
        // abort kicking any remaining connections the same secondary holds
        // open (a secondary can legitimately have more than one).
        match tokio::time::timeout(
            NATS_REQUEST_TIMEOUT,
            client.request(kick_subject, kick_request.into()),
        )
        .await
        {
            Ok(Ok(kick_response)) => {
                match serde_json::from_slice::<KickEnvelope>(&kick_response.payload) {
                    Ok(parsed) if parsed.error.is_some() => tracing::warn!(
                        "nats_kick: KICK for cid {} (secondary {}) returned an error: {:?}",
                        conn.cid,
                        nats_user,
                        parsed.error
                    ),
                    Ok(_) => {
                        kicked += 1;
                        tracing::info!(
                            "nats_kick: disconnected cid {} for secondary {}",
                            conn.cid,
                            nats_user
                        );
                    }
                    Err(err) => tracing::warn!(
                        "nats_kick: failed to parse KICK response for cid {} (secondary {}): {}",
                        conn.cid,
                        nats_user,
                        err
                    ),
                }
            }
            Ok(Err(err)) => tracing::warn!(
                "nats_kick: KICK request failed for cid {} (secondary {}): {}",
                conn.cid,
                nats_user,
                err
            ),
            Err(_) => tracing::warn!(
                "nats_kick: KICK request timed out for cid {} (secondary {})",
                conn.cid,
                nats_user
            ),
        }
    }

    // Best-effort graceful close of this short-lived connection; it is about
    // to be dropped regardless, so a failure here changes nothing.
    let _ = client.drain().await;

    Ok(kicked)
}

#[cfg(test)]
mod tests {
    use super::*;

    // These two structs are the shapes disconnect_secondary parses off the
    // wire; exercising them directly (without a real nats-server, which the
    // real end-to-end proof is scripts/nats-secondary-auth-callout-simulation.sh's
    // job) catches a field-name/shape regression -- e.g. an accidental rename
    // of `cid`/`user_id`/`server`/`data` -- at unit-test speed.

    #[test]
    fn connz_envelope_parses_a_real_shaped_success_response() {
        let raw = json!({
            "server": {"id": "NSERVERID123"},
            "data": {
                "connections": [{"cid": 42}, {"cid": 7}]
            }
        });
        let parsed: ConnzEnvelope = serde_json::from_value(raw).unwrap();
        assert_eq!(parsed.server.id, "NSERVERID123");
        assert!(parsed.error.is_none());
        let data = parsed.data.expect("data present");
        let cids: Vec<u64> = data.connections.iter().map(|c| c.cid).collect();
        assert_eq!(cids, vec![42, 7]);
    }

    #[test]
    fn connz_envelope_with_no_connections_parses_to_empty_list_not_an_error() {
        // The no-live-connection case: the response still carries a `data`
        // object, just with an empty `connections` array -- must not be
        // confused with the envelope's own `error` field.
        let raw = json!({
            "server": {"id": "NSERVERID123"},
            "data": {"connections": []}
        });
        let parsed: ConnzEnvelope = serde_json::from_value(raw).unwrap();
        assert!(parsed.error.is_none());
        assert!(parsed.data.expect("data present").connections.is_empty());
    }

    #[test]
    fn connz_envelope_surfaces_a_server_side_error() {
        let raw = json!({
            "server": {"id": "NSERVERID123"},
            "error": {"code": 400, "description": "invalid filter"}
        });
        let parsed: ConnzEnvelope = serde_json::from_value(raw).unwrap();
        assert!(parsed.error.is_some());
        assert!(parsed.data.is_none());
    }

    #[test]
    fn kick_envelope_parses_success_and_error_shapes() {
        let success: KickEnvelope = serde_json::from_value(json!({"server": {"id": "X"}})).unwrap();
        assert!(success.error.is_none());

        let failure: KickEnvelope =
            serde_json::from_value(json!({"error": {"code": 404, "description": "no such cid"}}))
                .unwrap();
        assert!(failure.error.is_some());
    }
}
