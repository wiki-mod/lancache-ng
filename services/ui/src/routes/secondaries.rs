//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: secondary routes and the auth_callout fragment.
//! Why: each secondary has its own revocable NATS login.
//! From: Issue #583

use crate::{AppState, docker_client, nats_auth_callout, nats_config, nats_kick};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Json, Response};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path as FsPath;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;
use tera::Context;

#[derive(Deserialize)]
pub struct RegisterForm {
    pub token: String,
    pub name: String,
    // #1084: the secondary self-reports its own DNS bind IP (setup.sh's
    // detected `listen_ip`) so the primary can later health-probe it. Optional
    // for backward compatibility with an older setup.sh that does not send it;
    // validated as a private IPv4 before storage.
    #[serde(default)]
    pub address: Option<String>,
}

#[derive(Deserialize)]
pub struct RotateForm {
    pub token: String,
}

// #1084: manual address override, the fallback for when auto-detection can't
// determine a usable probe target (NAT, non-standard network paths). Sent as a
// JSON body by the Admin UI's fetch call; CSRF is enforced via the X-CSRF-Token
// header (verify_csrf_header), matching rotate_token / remove_secondary.
#[derive(Deserialize)]
pub struct SetAddressForm {
    pub address: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub nats_url: String,
    pub nats_user: String,
    pub nats_password: String,
    pub consumer_name: String,
    pub proxy_ip: String,
    pub pdns_api_key: String,
    pub ddns_tsig_key: String,
    pub dns_xfr_primary: String,
    pub image_registry: String,
    pub image_prefix: String,
    pub image_channel: String,
    pub image_tag: String,
}

// Generates a fresh, high-entropy per-secondary NATS password: 32 CSPRNG
// bytes, hex-encoded. Mirrors `load_or_create_session_secret`'s secret
// generation in main.rs. Never stored in plaintext -- callers persist only
// `nats_auth_callout::hash_nats_password(&this)`.
fn generate_nats_password() -> String {
    let bytes: [u8; 32] = rand::random();
    hex::encode(bytes)
}

// What: reads the shared TSIG secret returned to DNS secondaries.
// Why: AXFR secondaries must share the primary's DDNS/transfer key.
// From: Issue #1164
fn read_ddns_tsig_key_from_shared_secret_dir(
    shared_secret_dir: &str,
) -> Result<String, StatusCode> {
    let secret_path = FsPath::new(shared_secret_dir).join("ddns-tsig-key");
    let secret = fs::read_to_string(&secret_path).map_err(|err| {
        tracing::error!(
            path = %secret_path.display(),
            error = %err,
            "refusing secondary registration: native AXFR secondaries need the shared DDNS TSIG key"
        );
        StatusCode::SERVICE_UNAVAILABLE
    })?;
    let secret = secret.trim().to_string();
    if secret.is_empty() {
        tracing::error!(
            path = %secret_path.display(),
            "refusing secondary registration: shared DDNS TSIG key file is empty"
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    Ok(secret)
}

#[derive(Serialize, Clone)]
pub struct Secondary {
    pub name: String,
    pub consumer_name: String,
    pub registered_at: i64,
    pub last_seen: Option<i64>,
    // #1084: the secondary's reachable DNS address (NULL until a registration
    // reports one, or an operator sets it manually). The health-check UI shows
    // it and probes it.
    pub address: Option<String>,
}

// ─── Handlers ───

pub async fn secondaries_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let db = state
        .db
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let secondaries = db
        .prepare("SELECT name, consumer_name, registered_at, last_seen, address FROM secondaries ORDER BY registered_at DESC")
        .and_then(|mut stmt| {
            stmt.query_map([], |row| {
                Ok(Secondary {
                    name: row.get(0)?,
                    consumer_name: row.get(1)?,
                    registered_at: row.get(2)?,
                    last_seen: row.get(3)?,
                    address: row.get(4)?,
                })
            })
            .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        })
        .unwrap_or_default();

    let primary_url = format!("http://{}:8080", state.config.standard_ip);
    let reg_token = &state.config.secondary_registration_token;

    let mut ctx = Context::new();
    ctx.insert("active_page", "secondaries");
    ctx.insert("secondaries", &secondaries);
    ctx.insert("primary_url", &primary_url);
    ctx.insert("registration_token", reg_token);
    crate::routes::insert_csrf_token(&mut ctx, &headers);

    Ok(crate::routes::render(
        &state.templates,
        "secondaries.html",
        &ctx,
        state.config.dev_mode,
    ))
}

pub async fn register_secondary(
    State(state): State<Arc<AppState>>,
    axum::extract::Json(form): axum::extract::Json<RegisterForm>,
) -> Result<Json<RegisterResponse>, StatusCode> {
    // Validate token — reject if token is unconfigured (empty) to prevent
    // accidental open registration when SECONDARY_REGISTRATION_TOKEN is unset.
    if state.config.secondary_registration_token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // Constant-time comparison so a byte-by-byte timing side-channel can't be
    // used to recover the registration token one character at a time. Matches
    // the same idiom used for the CSRF token (routes/mod.rs) and the NATS
    // password hash (nats_auth_callout.rs).
    if !bool::from(
        form.token
            .as_bytes()
            .ct_eq(state.config.secondary_registration_token.as_bytes()),
    ) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Validate name: alphanumeric + dash, non-empty, ≤32 chars
    if form.name.is_empty()
        || form.name.len() > 32
        || !form
            .name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    // Issue #866: resolve the address this secondary will actually be told
    // to connect to *before* generating a credential or touching the
    // database, so a primary that isn't configured for remote secondaries
    // fails this request with zero side effects rather than half-registering
    // a secondary it then can't hand a reachable NATS URL to.
    //
    // advertised_nats_url() returning None means neither NATS_ADVERTISE_URL
    // nor NATS_BIND_IP is set on this primary -- there is no address to give
    // out here that could ever resolve from outside this primary's own
    // Docker network (state.config.nats_url is exactly that unreachable
    // internal value; see its own doc comment for why this must not fall
    // back to it). Refusing loudly here, at the one moment the primary
    // actually knows it can't fulfill the request, is the fix: the prior
    // behavior silently handed out nats_url anyway, `setup.sh secondary`
    // wrote it into the new secondary's .env, started the container, and
    // printed an unconditional "is running" with no signal the sync would
    // never work. 503, not 4xx: the request itself (token, name) is valid --
    // it's this primary's own configuration that isn't ready for it yet.
    let Some(nats_url) = state.config.advertised_nats_url() else {
        tracing::error!(
            secondary_name = %form.name,
            "refusing secondary registration: neither NATS_ADVERTISE_URL nor \
             NATS_BIND_IP is configured on this primary, so there is no \
             NATS URL reachable from a remote secondary to hand out (issue \
             #866). Set NATS_BIND_IP to the trusted LAN/VPN interface \
             remote secondaries use (see docs/architecture-ng.md's \
             \"Remote secondary NATS access\"), or NATS_ADVERTISE_URL for a \
             non-default port/scheme/hostname, then retry."
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    };
    let ddns_tsig_key = read_ddns_tsig_key_from_shared_secret_dir(&state.config.shared_secret_dir)?;
    let dns_xfr_primary = format!("{}:5300", state.config.standard_ip);

    // What: name is the NATS user; only the hash is stored.
    // Why: the plaintext is returned once and never kept.
    // From: Issue #583
    let nats_user = form.name.clone();
    let nats_password = generate_nats_password();
    let nats_password_hash = nats_auth_callout::hash_nats_password(&nats_password)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let consumer_name = form.name.clone();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    // #1084: the auto-detected probe address -- the secondary's self-reported
    // bind IP, accepted only if it is a valid private (RFC1918) IPv4 (see
    // dns_probe::parse_private_ipv4). None if not reported or not private, in
    // which case any existing stored address (e.g. a manual override) is kept
    // via the COALESCE below rather than wiped by this re-registration.
    let reported_address: Option<String> = form
        .address
        .as_deref()
        .and_then(crate::dns_probe::parse_private_ipv4)
        .map(|ip| ip.to_string());

    // INSERT OR REPLACE INTO secondaries. `nats_token` is a vestigial NOT
    // NULL column from the pre-#583 shared-token model (see
    // main.rs::migrate_secondaries_table_for_auth_callout) -- nothing reads
    // it anymore, but it must still be supplied to satisfy the column
    // constraint on both fresh and upgraded databases.
    {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        db.execute(
            "INSERT OR REPLACE INTO secondaries (name, consumer_name, nats_token, nats_user, nats_password_hash, registered_at, last_seen, address)
             VALUES (?1, ?2, '', ?3, ?4, ?5, NULL, COALESCE(?6, (SELECT address FROM secondaries WHERE name = ?1)))",
            rusqlite::params![form.name, consumer_name, nats_user, nats_password_hash, now, reported_address],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }

    Ok(Json(RegisterResponse {
        // Resolved above, before any credential/DB write: an explicit
        // NATS_ADVERTISE_URL override, or one derived from NATS_BIND_IP
        // (the same trusted LAN/VPN IP docker-compose.nats-secondary.yml
        // already publishes NATS on for remote secondaries). Never
        // state.config.nats_url directly -- that's the Docker-internal
        // address this container's own connection and dns-standard/dns-ssl
        // use, unreachable from the remote secondary that's the sole
        // consumer of this field (issue #866).
        nats_url,
        nats_user,
        nats_password,
        consumer_name,
        proxy_ip: state.config.standard_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
        ddns_tsig_key,
        dns_xfr_primary,
        image_registry: state.config.lancache_image_registry.clone(),
        image_prefix: state.config.lancache_image_prefix.clone(),
        image_channel: state.config.lancache_image_channel.clone(),
        image_tag: state.config.lancache_image_tag.clone(),
    }))
}

pub async fn remove_secondary(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&headers)?;
    let rows_affected = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        // name.clone(), not a move: the kick call below needs it after this
        // block too (issue #681).
        db.execute("DELETE FROM secondaries WHERE name = ?", [name.clone()])
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };

    // Return 404 if the secondary doesn't exist
    if rows_affected == 0 {
        return Err(StatusCode::NOT_FOUND);
    }

    // No nats.conf rewrite or NATS restart needed (issue #583): the
    // auth-callout responder re-checks this table on every connection
    // attempt, so deleting the row alone revokes this secondary's access on
    // its very next reconnect, with zero effect on any other secondary.
    //
    // Issue #681: the row is already gone at this point, so it's now safe to
    // actively kick this secondary's current live connection, if it has one
    // -- if the kick makes it reconnect, that reconnect now fails
    // auth-callout instead of quietly succeeding (see nats_kick.rs's module
    // docs on why this ordering is load-bearing). Spawned in the background:
    // a slow/unreachable NATS system account must not add latency to this
    // HTTP response -- the DB-level revocation above is what actually
    // matters; this only shrinks the exposure window for an already-open
    // connection, it is not required for correctness.
    let kick_state = state.clone();
    let kick_name = name.clone();
    tokio::spawn(async move {
        match nats_kick::disconnect_secondary(&kick_state, &kick_name).await {
            Ok(0) => tracing::debug!(
                "nats_kick: removed secondary {kick_name} had no live NATS connection to disconnect"
            ),
            Ok(n) => tracing::info!(
                "nats_kick: disconnected {n} live NATS connection(s) for removed secondary {kick_name}"
            ),
            Err(err) => tracing::warn!(
                "nats_kick: failed to actively disconnect removed secondary {kick_name}: {err}"
            ),
        }
    });

    Ok(Json(serde_json::json!({"ok": true})))
}

// #1084: manually set/override a secondary's probe address. The fallback when
// auto-detection did not capture a usable address. Validated as a private
// (RFC1918) IPv4 so it can never become an SSRF probe target.
pub async fn set_secondary_address(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    axum::extract::Json(form): axum::extract::Json<SetAddressForm>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&headers)?;
    let Some(addr) = crate::dns_probe::parse_private_ipv4(&form.address) else {
        return Err(StatusCode::BAD_REQUEST);
    };
    let rows_affected = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        db.execute(
            "UPDATE secondaries SET address = ? WHERE name = ?",
            rusqlite::params![addr.to_string(), name],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };
    if rows_affected == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(
        serde_json::json!({"ok": true, "address": addr.to_string()}),
    ))
}

// #1084: active DNS health probe. Looks up the secondary's stored address and
// sends a real `lan.` SOA query to it (see dns_probe), returning the classified
// status as JSON for the Admin UI. On a healthy authoritative answer this is
// the first and only writer of the `last_seen` column (previously always NULL),
// giving it a real "observed answering at" meaning.
pub async fn check_secondary_health(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&headers)?;

    // Read the stored address (and confirm the row exists) under the lock, then
    // drop the lock before the network probe -- never hold the DB mutex across
    // an await/IO.
    let stored_address: Option<String> = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        match db.query_row(
            "SELECT address FROM secondaries WHERE name = ?",
            [&name],
            |row| row.get::<_, Option<String>>(0),
        ) {
            Ok(addr) => addr,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Err(StatusCode::NOT_FOUND),
            Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR),
        }
    };

    let Some(addr) = stored_address
        .as_deref()
        .and_then(crate::dns_probe::parse_private_ipv4)
    else {
        // No usable stored address: report it as a status rather than an error,
        // so the UI can prompt the operator to set one (the manual fallback).
        return Ok(Json(serde_json::json!({
            "status": "no_address",
            "serial": serde_json::Value::Null,
            "detail": "no reachable address on record for this secondary -- set one to enable the health check",
        })));
    };

    // What: probe the secondary's DNS on standard port 53.
    // Why: 5300 is only the primary's AXFR listener.
    let result = crate::dns_probe::probe_secondary_soa(addr, 53).await;

    // Only a genuinely healthy authoritative answer advances last_seen.
    if result.status == "ok" {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        // DB update is best-effort; a lock/DB error here does not affect the probe result returned to
        // the UI, so we silently ignore failures rather than blocking the response on a transient DB glitch.
        if let Ok(db) = state.db.lock() {
            let _ = db.execute(
                "UPDATE secondaries SET last_seen = ? WHERE name = ?",
                rusqlite::params![now, name],
            );
        }
    }

    Ok(Json(serde_json::json!({
        "status": result.status,
        "serial": result.serial,
        "detail": result.detail,
    })))
}

pub async fn rotate_token(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    axum::extract::Json(form): axum::extract::Json<RotateForm>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    crate::routes::verify_csrf_header(&headers)?;
    // Validate token — reject if token is unconfigured (empty).
    if state.config.secondary_registration_token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }
    // Constant-time comparison, same rationale as register_secondary above.
    if !bool::from(
        form.token
            .as_bytes()
            .ct_eq(state.config.secondary_registration_token.as_bytes()),
    ) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Issue #583: actually regenerates this ONE secondary's own NATS
    // credential (the endpoint's name finally matches its behavior -- see
    // #433's history of `rotate_token` returning an unchanged shared value).
    // `nats_user` (== name) never changes on rotation, only the password;
    // the old password's hash is overwritten in the same UPDATE, so it stops
    // working the instant this commits -- no separate revocation step.
    let nats_user = name.clone();
    let nats_password = generate_nats_password();
    let nats_password_hash = nats_auth_callout::hash_nats_password(&nats_password)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let rows_affected = {
        let db = state
            .db
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        db.execute(
            "UPDATE secondaries SET nats_password_hash = ? WHERE name = ?",
            [nats_password_hash, name.clone()],
        )
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    };

    // Return 404 if the secondary doesn't exist
    if rows_affected == 0 {
        return Err(StatusCode::NOT_FOUND);
    }

    // Issue #681: the password hash is already overwritten at this point, so
    // it's now safe to actively kick this secondary's current live
    // connection, if it has one -- if the kick makes it reconnect, that
    // reconnect now presents the OLD (now-invalid) password and fails
    // auth-callout instead of quietly continuing on the credential this
    // rotation was meant to retire (see nats_kick.rs's module docs on why
    // this ordering is load-bearing). Spawned in the background for the same
    // reason as remove_secondary above: a slow/unreachable NATS system
    // account must not add latency to this HTTP response.
    let kick_state = state.clone();
    let kick_name = nats_user.clone();
    tokio::spawn(async move {
        match nats_kick::disconnect_secondary(&kick_state, &kick_name).await {
            Ok(0) => tracing::debug!(
                "nats_kick: rotated secondary {kick_name} had no live NATS connection to disconnect"
            ),
            Ok(n) => tracing::info!(
                "nats_kick: disconnected {n} live NATS connection(s) for rotated secondary {kick_name}"
            ),
            Err(err) => tracing::warn!(
                "nats_kick: failed to actively disconnect rotated secondary {kick_name}: {err}"
            ),
        }
    });

    Ok(Json(serde_json::json!({
        "nats_user": nats_user,
        "nats_password": nats_password
    })))
}

// ─── Helper Functions ───

// What: rewrite the fragment; restart NATS on a change.
// Why: nats-server cannot hot-reload auth_callout.
// From: Issue #811
pub async fn reload_nats_conf(
    state: &AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if !update_nats_conf(state).await? {
        return Ok(());
    }
    docker_client::restart_service(&state.docker, &state.config.nats_service)
        .await
        // What: uses {e:#} (anyhow's full chain), not {e}.
        // Why: {e} alone hid the real bollard/Docker-API root cause.
        // From: Issue #1590
        .map_err(|e| format!("Failed to restart NATS service: {e:#}").into())
}

// What: returns whether the fragment actually changed on disk.
// Why: restarting NATS on an unchanged fragment drops live clients.
// From: PR #1610
pub async fn update_nats_conf(
    state: &AppState,
) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
    // Keep the full credential preflight even though the fragment itself only
    // references usernames: the responder connects with the callout password
    // and the DNS roles connect with theirs, so a missing credential is still
    // a fatal misconfiguration we want caught here at startup, not later as an
    // opaque auth failure.
    nats_config::validate_runtime_nats_credentials(&state.config)?;

    let fragment = render_nats_auth_callout(
        &state.config.nats_ui_user,
        &state.config.nats_dns_writer_user,
        &state.config.nats_dns_replica_user,
        &state.config.nats_callout_user,
        &state.config.nats_sys_user,
        &state.nats_issuer_public_key,
        &state.nats_callout_xkey_public_key,
    );

    Ok(crate::write_file_if_changed(
        FsPath::new(&state.config.nats_auth_callout_path),
        &fragment,
        0o644,
        None,
    )?)
}

// What: the auth_callout stanza nats.conf includes, pure.
// Why: only the ui knows the issuer and xkey public keys.
// From: Issue #811 | PR #1858
fn render_nats_auth_callout(
    ui_user: &str,
    writer_user: &str,
    replica_user: &str,
    callout_user: &str,
    sys_user: &str,
    issuer_public_key: &str,
    xkey_public_key: &str,
) -> String {
    format!(
        r#"auth_callout {{
  issuer: "{issuer_public_key}"
  xkey: "{xkey_public_key}"
  auth_users: ["{ui_user}", "{writer_user}", "{replica_user}", "{callout_user}", "{sys_user}"]
}}
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ng-{name}-{}-{stamp}", std::process::id()))
    }

    // Generated NATS passwords must be exactly 64 hex characters (32 bytes) and never repeat, proving CSPRNG is working and entropy is sufficient.
    #[test]
    fn generate_nats_password_is_high_entropy_and_never_repeats() {
        let a = generate_nats_password();
        let b = generate_nats_password();
        // 32 random bytes hex-encoded is exactly 64 hex characters.
        assert_eq!(a.len(), 64);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(
            a, b,
            "two consecutive calls produced the same password -- CSPRNG source is broken"
        );
    }

    // RegisterResponse must serialize all image configuration fields so secondaries receive complete image reference details for deployment.
    #[test]
    fn register_response_serializes_image_tag_for_secondary_setup() {
        let response = RegisterResponse {
            nats_url: "nats://primary:4222".to_string(),
            nats_user: "secondary-a".to_string(),
            nats_password: "per-secondary-secret".to_string(),
            consumer_name: "secondary-a".to_string(),
            proxy_ip: "192.168.1.100".to_string(),
            pdns_api_key: "pdns-secret".to_string(),
            ddns_tsig_key: "transfer-secret".to_string(),
            dns_xfr_primary: "192.168.1.100:5300".to_string(),
            image_registry: "registry.example.test:5000".to_string(),
            image_prefix: "mirror/lancache-ng".to_string(),
            image_channel: "nightly".to_string(),
            image_tag: "v1.2.3".to_string(),
        };

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["image_registry"], "registry.example.test:5000");
        assert_eq!(value["ddns_tsig_key"], "transfer-secret");
        assert_eq!(value["dns_xfr_primary"], "192.168.1.100:5300");
        assert_eq!(value["image_prefix"], "mirror/lancache-ng");
        assert_eq!(value["image_channel"], "nightly");
        assert_eq!(value["image_tag"], "v1.2.3");
    }

    // What: equal inputs render a byte-identical fragment.
    // Why: a changed byte would restart NATS each start.
    // From: Issue #640
    #[test]
    fn nats_conf_auth_callout_fragment_render_is_byte_identical_across_repeated_calls() {
        let render = || {
            render_nats_auth_callout(
                "lancache-ui",
                "lancache-dns-writer",
                "lancache-dns-replica",
                "lancache-nats-callout",
                "lancache-nats-sys",
                "issuer-public-key-abc123",
                "xkey-public-key-def456",
            )
        };

        let first = render();
        let second = render();
        assert_eq!(
            first, second,
            "render_nats_auth_callout must be a pure function of its inputs: same values in, byte-identical fragment out, every call"
        );

        // Sanity check that the comparison above isn't trivially true because
        // both calls returned empty/placeholder output -- every interpolated
        // value must actually appear in the rendered fragment.
        for needle in [
            "lancache-ui",
            "lancache-dns-writer",
            "lancache-dns-replica",
            "lancache-nats-callout",
            "lancache-nats-sys",
            "issuer-public-key-abc123",
            "xkey-public-key-def456",
            "auth_callout",
            "auth_users",
        ] {
            assert!(
                first.contains(needle),
                "rendered auth_callout fragment is missing expected value {needle:?}"
            );
        }

        // What: the fragment holds only auth_callout.
        // Why: users, log_file, jetstream are nats.conf's.
        for forbidden in ["users = [", "password:", "log_file", "jetstream"] {
            assert!(
                !first.contains(forbidden),
                "auth_callout fragment must not contain {forbidden:?} -- that belongs in nats.conf, not the UI fragment"
            );
        }
    }

    // What: two unchanged starts write once, then nothing.
    // Why: an unchanged fragment must not restart NATS.
    // From: PR #1610
    #[test]
    fn nats_conf_auth_callout_fragment_write_converges_across_repeated_writes_of_unchanged_config()
    {
        let dir = temp_dir("nats-conf-repeat-run");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("auth_callout.conf");

        let rendered_first = render_nats_auth_callout(
            "lancache-ui",
            "lancache-dns-writer",
            "lancache-dns-replica",
            "lancache-nats-callout",
            "lancache-nats-sys",
            "issuer-public-key-abc123",
            "xkey-public-key-def456",
        );
        assert!(crate::write_file_if_changed(&path, &rendered_first, 0o644, None).unwrap());
        let first_write = fs::read_to_string(&path).unwrap();

        let rendered_second = render_nats_auth_callout(
            "lancache-ui",
            "lancache-dns-writer",
            "lancache-dns-replica",
            "lancache-nats-callout",
            "lancache-nats-sys",
            "issuer-public-key-abc123",
            "xkey-public-key-def456",
        );
        assert!(!crate::write_file_if_changed(&path, &rendered_second, 0o644, None).unwrap());
        let second_write = fs::read_to_string(&path).unwrap();

        assert_eq!(
            first_write, second_write,
            "auth_callout.conf must converge to the same content across repeated startups with an unchanged Config"
        );

        let leftovers = fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0, "no .tmp-* file may survive either write");
        fs::remove_dir_all(dir).unwrap();
    }
}
