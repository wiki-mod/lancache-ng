//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI secondary-node routes: lists registered secondaries, issues each
//! one its own unique NATS auth-callout credential on registration (issue
//! #583), rotates or revokes that one secondary's credential without
//! touching any other secondary, and generates the static `nats.conf` (UI/
//! DNS-writer/DNS-replica/callout-bypass roles plus the `auth_callout {}`
//! stanza) at process startup only -- see `nats_auth_callout.rs` for why
//! register/rotate/remove no longer need to rewrite that file or restart NATS.

use crate::{docker_client, nats_auth_callout, nats_config, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, Json};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path as FsPath;
use std::process;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;
use tera::Context;

#[derive(Deserialize)]
pub struct RegisterForm {
    pub token: String,
    pub name: String,
}

#[derive(Deserialize)]
pub struct RotateForm {
    pub token: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub nats_url: String,
    pub nats_user: String,
    pub nats_password: String,
    pub consumer_name: String,
    pub proxy_ip: String,
    pub pdns_api_key: String,
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

#[derive(Serialize, Clone)]
pub struct Secondary {
    pub name: String,
    pub consumer_name: String,
    pub registered_at: i64,
    pub last_seen: Option<i64>,
}

// ─── Handlers ───

pub async fn secondaries_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Html<String>, StatusCode> {
    let db = state
        .db
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let secondaries = db
        .prepare("SELECT name, consumer_name, registered_at, last_seen FROM secondaries ORDER BY registered_at DESC")
        .and_then(|mut stmt| {
            stmt.query_map([], |row| {
                Ok(Secondary {
                    name: row.get(0)?,
                    consumer_name: row.get(1)?,
                    registered_at: row.get(2)?,
                    last_seen: row.get(3)?,
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

    // Issue #583: each secondary gets its own NATS identity now, not the old
    // shared DNS-reader credential. `name` doubles as the NATS username --
    // it already passed the same alphanumeric+dash charset check NATS
    // usernames require (see nats_config::validate_nats_username), and it's
    // already the table's primary key, so no separate uniqueness check is
    // needed. Only the password's hash is ever persisted; the plaintext is
    // returned exactly once, here, and never stored.
    let nats_user = form.name.clone();
    let nats_password = generate_nats_password();
    let nats_password_hash = nats_auth_callout::hash_nats_password(&nats_password);
    let consumer_name = form.name.clone();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

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
            "INSERT OR REPLACE INTO secondaries (name, consumer_name, nats_token, nats_user, nats_password_hash, registered_at, last_seen)
             VALUES (?1, ?2, '', ?3, ?4, ?5, NULL)",
            rusqlite::params![form.name, consumer_name, nats_user, nats_password_hash, now],
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
        db.execute("DELETE FROM secondaries WHERE name = ?", [name])
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
    Ok(Json(serde_json::json!({"ok": true})))
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
    let nats_password_hash = nats_auth_callout::hash_nats_password(&nats_password);

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

    Ok(Json(serde_json::json!({
        "nats_user": nats_user,
        "nats_password": nats_password
    })))
}

// ─── Helper Functions ───
// The NATS auth-callout config is static for the lifetime of the process
// (issue #583): the Admin UI writes it once at startup (see main.rs), then
// never touches it again. Registering, rotating, or removing a secondary only
// ever writes to the `secondaries` table -- the auth-callout responder
// (nats_auth_callout.rs) reads that table live on every connection attempt, so
// nothing in the config needs to change per secondary.
//
// Since issue #811 the Admin UI writes ONLY the `auth_callout {}` fragment (to
// config.nats_auth_callout_path, i.e. /etc/nats/auth_callout.conf), NOT the
// whole nats.conf. The nats container's own entrypoint owns nats.conf (the
// static roles, jetstream, log_file) and `include`s our fragment inside its
// authorization {} block. This is the fix's core: the entrypoint can now keep
// regenerating its static config idempotently on every restart (the same
// convergence discipline pdns/kea/nginx/dhcp-proxy follow) without clobbering
// the fragment the way it used to when the UI wrote the whole file. The
// restart in reload_nats_conf below is still required to apply the fragment,
// because nats-server explicitly refuses to hot-reload auth_callout ("config
// reload not supported for AuthCallout", verified against nats-server 2.14.3),
// but it is now safe -- the restart re-runs the entrypoint, which regenerates
// nats.conf and leaves auth_callout.conf untouched.

pub async fn reload_nats_conf(
    state: &AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    update_nats_conf(state).await?;
    docker_client::restart_service(&state.docker, &state.config.nats_service)
        .await
        .map_err(|e| format!("Failed to restart NATS service: {e}").into())
}

pub async fn update_nats_conf(
    state: &AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
        &state.nats_issuer_public_key,
    );

    write_nats_conf_atomically(&state.config.nats_auth_callout_path, &fragment)
}

// Pulled out of update_nats_conf as a pure, I/O-free function (#640, follow-
// up to #583's per-secondary identity decision) so the repeat-run/idempotence
// property #640 requires -- that starting up twice with an unchanged Config
// renders byte-identical config content -- is directly unit-testable.
// update_nats_conf's own AppState carries a live Docker client, NATS
// connection, and SQLite handle, none of which a unit test can construct
// without a running stack, so this function takes only the plain string values
// it actually needs instead of the whole AppState.
//
// Since issue #811 this renders ONLY the `auth_callout {}` fragment that the
// nats entrypoint `include`s inside its authorization {} block -- hence only
// the static usernames (for auth_users) and the issuer public key are needed,
// not passwords or log_file, which the entrypoint owns. auth_users must list
// every static user by name so nats-server keeps authenticating them against
// its own static `users` list; only names absent from both are routed through
// the callout (verified against nats-server 2.14.3; see nats_auth_callout.rs).
fn render_nats_auth_callout(
    ui_user: &str,
    writer_user: &str,
    replica_user: &str,
    callout_user: &str,
    issuer_public_key: &str,
) -> String {
    // This is the fragment `include`d by the nats container's own nats.conf
    // INSIDE its authorization {} block (issue #811). It must therefore be the
    // bare `auth_callout {}` stanza only -- no jetstream, log_file, users, or
    // wrapping authorization {} (those are the entrypoint's, in nats.conf).
    format!(
        r#"# lancache-ng auth_callout fragment -- DO NOT edit by hand.
# Written solely by the Admin UI (services/ui/src/routes/secondaries.rs::
# update_nats_conf) and `include`d by the nats container's nats.conf inside its
# authorization {{}} block. It is split out from nats.conf on purpose so the
# nats entrypoint can idempotently regenerate its own static config on every
# restart without ever clobbering this file (issue #811). Only the Admin UI
# knows the issuer public key below, which is why this cannot live in the
# entrypoint-generated nats.conf.
auth_callout {{
  issuer: "{issuer_public_key}"
  # Every static user in nats.conf's `users` list must be listed here, not just
  # the callout responder itself: nats-server only checks a connecting user's
  # password against that static list for names in auth_users. Any username
  # *not* listed here -- including one that happens to match a static entry --
  # is routed through the callout instead (verified against a real nats-server
  # 2.14.3; see nats_auth_callout.rs's module docs). Only external secondaries,
  # deliberately absent from both this list and nats.conf's static `users`
  # list, are meant to go through the callout.
  auth_users: ["{ui_user}", "{writer_user}", "{replica_user}", "{callout_user}"]
}}
"#
    )
}

fn write_nats_conf_atomically(
    path: &str,
    content: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let target = FsPath::new(path);
    let parent = target
        .parent()
        .ok_or_else(|| format!("nats.conf path has no parent directory: {path}"))?;
    let file_name = target
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("nats.conf");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("System clock is before UNIX_EPOCH: {e}"))?
        .as_nanos();
    let tmp_path = parent.join(format!(".{file_name}.tmp-{}-{stamp}", process::id()));

    fs::write(&tmp_path, content)
        .map_err(|e| format!("Failed to write temporary nats.conf: {e}"))?;

    if let Err(err) = fs::rename(&tmp_path, target) {
        let _ = fs::remove_file(&tmp_path);
        return Err(format!("Failed to atomically replace nats.conf: {err}").into());
    }

    Ok(())
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
        std::env::temp_dir().join(format!("lancache-ng-{name}-{}-{stamp}", process::id()))
    }

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

    #[test]
    fn register_response_serializes_image_tag_for_secondary_setup() {
        let response = RegisterResponse {
            nats_url: "nats://primary:4222".to_string(),
            nats_user: "secondary-a".to_string(),
            nats_password: "per-secondary-secret".to_string(),
            consumer_name: "secondary-a".to_string(),
            proxy_ip: "192.168.1.100".to_string(),
            pdns_api_key: "pdns-secret".to_string(),
            image_registry: "registry.example.test:5000".to_string(),
            image_prefix: "mirror/lancache-ng".to_string(),
            image_channel: "nightly".to_string(),
            image_tag: "v1.2.3".to_string(),
        };

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["image_registry"], "registry.example.test:5000");
        assert_eq!(value["image_prefix"], "mirror/lancache-ng");
        assert_eq!(value["image_channel"], "nightly");
        assert_eq!(value["image_tag"], "v1.2.3");
    }

    #[test]
    fn nats_conf_write_replaces_file_atomically() {
        let dir = temp_dir("nats-conf-atomic");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nats.conf");
        fs::write(&path, "old").unwrap();

        write_nats_conf_atomically(path.to_str().unwrap(), "new").unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), "new");
        let leftovers = fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0);
        fs::remove_dir_all(dir).unwrap();
    }

    // #640: closes the one real gap the #456 convergence/idempotence audit
    // flagged for NATS -- render_nats_auth_callout/write_nats_conf_atomically
    // are the write path #583's per-secondary-identity decision settled on (a
    // static config written once at startup; see this module's own header
    // comment and secondaries.rs's `update_nats_conf` doc comment), but nothing
    // previously proved that path is actually a stable fixed point across
    // repeated container starts with an unchanged Config. A prior version of
    // this code path (the now-removed shared DNS-reader role, #380/#426/#473)
    // *was* a documented no-op, so this repeat-run test intentionally targets
    // real, non-trivial content (the interpolated issuer + auth_users) rather
    // than assuming that history still applies today. (Test names retain the
    // `nats_conf` marker the #640 idempotence-coverage guard keys on -- see
    // scripts/check-idempotence-test-coverage.sh -- even though since #811 this
    // writer emits the auth_callout.conf fragment rather than the whole file.)
    #[test]
    fn nats_conf_auth_callout_fragment_render_is_byte_identical_across_repeated_calls() {
        let render = || {
            render_nats_auth_callout(
                "lancache-ui",
                "lancache-dns-writer",
                "lancache-dns-replica",
                "lancache-nats-callout",
                "issuer-public-key-abc123",
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
            "issuer-public-key-abc123",
            "auth_callout",
            "auth_users",
        ] {
            assert!(
                first.contains(needle),
                "rendered auth_callout fragment is missing expected value {needle:?}"
            );
        }

        // The fragment is `include`d INSIDE the entrypoint's authorization {}
        // block (issue #811), so it must carry ONLY the auth_callout stanza --
        // no static `users = [` list, no passwords, no log_file, no jetstream
        // (all of those are the nats entrypoint's, in nats.conf). Guard against
        // a regression that reintroduces the whole-file render here. (We match
        // directive-shaped substrings, not the bare word "authorization", so
        // this doc-comment's own mention of the authorization {} block above
        // doesn't trip it.)
        for forbidden in ["users = [", "password:", "log_file", "jetstream"] {
            assert!(
                !first.contains(forbidden),
                "auth_callout fragment must not contain {forbidden:?} -- that belongs in the entrypoint-owned nats.conf, not the UI fragment"
            );
        }
    }

    // End-to-end version of the test above: drives the real
    // render_nats_auth_callout -> write_nats_conf_atomically pipeline twice in
    // a row (simulating two container starts with an unchanged Config, the same
    // shape setup_update_idempotence.bats and dns_config_snapshot_idempotence.bats
    // already prove for setup.sh and PowerDNS respectively) and asserts the
    // on-disk fragment converges to byte-identical content with no leftover
    // `.tmp-*` file from either write.
    #[test]
    fn nats_conf_auth_callout_fragment_write_converges_across_repeated_writes_of_unchanged_config()
    {
        let dir = temp_dir("nats-conf-repeat-run");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("auth_callout.conf");
        let path_str = path.to_str().unwrap();

        let rendered_first = render_nats_auth_callout(
            "lancache-ui",
            "lancache-dns-writer",
            "lancache-dns-replica",
            "lancache-nats-callout",
            "issuer-public-key-abc123",
        );
        write_nats_conf_atomically(path_str, &rendered_first).unwrap();
        let first_write = fs::read_to_string(&path).unwrap();

        // Second "startup": same inputs, freshly re-rendered (not the cached
        // `rendered_first` string) so this also exercises render_nats_auth_callout
        // a second time, not just write_nats_conf_atomically writing the same
        // string object twice.
        let rendered_second = render_nats_auth_callout(
            "lancache-ui",
            "lancache-dns-writer",
            "lancache-dns-replica",
            "lancache-nats-callout",
            "issuer-public-key-abc123",
        );
        write_nats_conf_atomically(path_str, &rendered_second).unwrap();
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
