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
        nats_url: state.config.nats_url.clone(),
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
// nats.conf is now static for the lifetime of the process (issue #583):
// it's written once at startup (see main.rs) with the UI/DNS-writer/
// DNS-replica/callout-bypass static roles plus the `auth_callout {}` stanza,
// then never touched again. Registering, rotating, or removing a secondary
// only ever writes to the `secondaries` table -- the auth-callout responder
// (nats_auth_callout.rs) reads that table live on every connection attempt,
// so there is nothing in nats.conf that could need to change per secondary.
// `reload_nats_conf`/`update_nats_conf` remain as the one-time startup path.

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
    nats_config::validate_runtime_nats_credentials(&state.config)?;

    // .as_deref().unwrap_or_default() below is defensive only: the
    // validate_runtime_nats_credentials call above already guarantees every
    // one of these is Some by the time render_nats_conf runs.
    let nats_conf = render_nats_conf(
        &state.config.nats_ui_user,
        state.config.nats_ui_password.as_deref().unwrap_or_default(),
        &state.config.nats_dns_writer_user,
        state
            .config
            .nats_dns_writer_password
            .as_deref()
            .unwrap_or_default(),
        &state.config.nats_dns_replica_user,
        state
            .config
            .nats_dns_replica_password
            .as_deref()
            .unwrap_or_default(),
        &state.config.nats_callout_user,
        state
            .config
            .nats_callout_password
            .as_deref()
            .unwrap_or_default(),
        &state.nats_issuer_public_key,
    );

    write_nats_conf_atomically(&state.config.nats_conf_path, &nats_conf)
}

// Pulled out of update_nats_conf as a pure, I/O-free function (#640, follow-
// up to #583's per-secondary identity decision) so the repeat-run/
// idempotence property #640 requires -- that starting up twice with an
// unchanged Config renders byte-identical nats.conf content -- is directly
// unit-testable. update_nats_conf's own AppState carries a live Docker
// client, NATS connection, and SQLite handle, none of which a unit test can
// construct without a running stack, so this function takes only the plain
// string values it actually needs instead of the whole AppState.
#[allow(clippy::too_many_arguments)]
fn render_nats_conf(
    ui_user: &str,
    ui_password: &str,
    writer_user: &str,
    writer_password: &str,
    replica_user: &str,
    replica_password: &str,
    callout_user: &str,
    callout_password: &str,
    issuer_public_key: &str,
) -> String {
    format!(
        r#"jetstream {{
  store_dir: /data
}}

authorization {{
  users = [
    {{
      user: "{ui_user}"
      password: "{ui_password}"
      permissions = {{
        publish = ["lancache.dns.record", "lancache.dns.flush"]
      }}
    }}
    {{
      user: "{writer_user}"
      password: "{writer_password}"
      permissions = {{
        publish = [
          "lancache.dns.record",
          "$JS.API.STREAM.INFO.LANCACHE_DNS",
          "$JS.API.STREAM.CREATE.LANCACHE_DNS",
          "$JS.API.CONSUMER.INFO.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>",
          "$JS.ACK.LANCACHE_DNS.>"
        ]
        subscribe = ["lancache.dns.>", "_INBOX.>"]
      }}
    }}
    {{
      # The primary's own co-located dns-ssl container -- always exactly one
      # instance, so a static credential is fine here (see config.rs's
      # nats_dns_replica_user docs for why this is NOT the same role external
      # secondaries used to share).
      user: "{replica_user}"
      password: "{replica_password}"
      permissions = {{
        publish = [
          "$JS.API.STREAM.INFO.LANCACHE_DNS",
          "$JS.API.CONSUMER.INFO.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>",
          "$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>",
          "$JS.ACK.LANCACHE_DNS.>"
        ]
        subscribe = ["lancache.dns.>", "_INBOX.>"]
      }}
    }}
    {{
      # This process's own connection for answering auth-callout requests
      # (see nats_auth_callout.rs).
      user: "{callout_user}"
      password: "{callout_password}"
    }}
  ]
  auth_callout {{
    issuer: "{issuer_public_key}"
    # Every static user above must be listed here, not just the callout
    # responder itself: nats-server only checks a connecting user's password
    # against the static `users` list above for names in this list. Any
    # username *not* listed here -- including one that happens to match a
    # static entry above -- is routed through the callout instead (verified
    # against a real nats-server 2.14.3; see nats_auth_callout.rs's module
    # docs). Only external secondaries, which are deliberately absent from
    # both this list and the static `users` list above, are meant to go
    # through the callout.
    auth_users: ["{ui_user}", "{writer_user}", "{replica_user}", "{callout_user}"]
  }}
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
            image_channel: "edge".to_string(),
            image_tag: "v1.2.3".to_string(),
        };

        let value = serde_json::to_value(response).unwrap();
        assert_eq!(value["image_registry"], "registry.example.test:5000");
        assert_eq!(value["image_prefix"], "mirror/lancache-ng");
        assert_eq!(value["image_channel"], "edge");
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
    // flagged for NATS -- render_nats_conf/write_nats_conf_atomically are the
    // write path #583's per-secondary-identity decision settled on (a static
    // nats.conf written once at startup; see this module's own header comment
    // and secondaries.rs's `update_nats_conf` doc comment), but nothing
    // previously proved that path is actually a stable fixed point across
    // repeated container starts with an unchanged Config. A prior version of
    // this code path (the now-removed shared DNS-reader role, #380/#426/#473)
    // *was* a documented no-op, so this repeat-run test intentionally targets
    // real, non-trivial per-role content (nine format! placeholders, four
    // roles) rather than assuming that history still applies today.
    #[test]
    fn render_nats_conf_is_byte_identical_across_repeated_calls_with_unchanged_inputs() {
        let render = || {
            render_nats_conf(
                "lancache-ui",
                "ui-secret",
                "lancache-dns-writer",
                "writer-secret",
                "lancache-dns-replica",
                "replica-secret",
                "lancache-nats-callout",
                "callout-secret",
                "issuer-public-key-abc123",
            )
        };

        let first = render();
        let second = render();
        assert_eq!(
            first, second,
            "render_nats_conf must be a pure function of its inputs: same credentials in, byte-identical config out, every call"
        );

        // Sanity check that the comparison above isn't trivially true because
        // both calls returned empty/placeholder output -- every interpolated
        // value must actually appear in the rendered config.
        for needle in [
            "lancache-ui",
            "ui-secret",
            "lancache-dns-writer",
            "writer-secret",
            "lancache-dns-replica",
            "replica-secret",
            "lancache-nats-callout",
            "callout-secret",
            "issuer-public-key-abc123",
        ] {
            assert!(
                first.contains(needle),
                "rendered nats.conf is missing expected value {needle:?}"
            );
        }
    }

    // End-to-end version of the test above: drives the real
    // render_nats_conf -> write_nats_conf_atomically pipeline twice in a row
    // (simulating two container starts with an unchanged Config, the same
    // shape setup_update_idempotence.bats and dns_config_snapshot_idempotence.bats
    // already prove for setup.sh and PowerDNS respectively) and asserts the
    // on-disk file converges to byte-identical content with no leftover
    // `.tmp-*` file from either write.
    #[test]
    fn nats_conf_write_converges_to_the_same_file_across_repeated_writes_of_unchanged_config() {
        let dir = temp_dir("nats-conf-repeat-run");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nats.conf");
        let path_str = path.to_str().unwrap();

        let rendered_first = render_nats_conf(
            "lancache-ui",
            "ui-secret",
            "lancache-dns-writer",
            "writer-secret",
            "lancache-dns-replica",
            "replica-secret",
            "lancache-nats-callout",
            "callout-secret",
            "issuer-public-key-abc123",
        );
        write_nats_conf_atomically(path_str, &rendered_first).unwrap();
        let first_write = fs::read_to_string(&path).unwrap();

        // Second "startup": same inputs, freshly re-rendered (not the cached
        // `rendered_first` string) so this also exercises render_nats_conf a
        // second time, not just write_nats_conf_atomically writing the same
        // string object twice.
        let rendered_second = render_nats_conf(
            "lancache-ui",
            "ui-secret",
            "lancache-dns-writer",
            "writer-secret",
            "lancache-dns-replica",
            "replica-secret",
            "lancache-nats-callout",
            "callout-secret",
            "issuer-public-key-abc123",
        );
        write_nats_conf_atomically(path_str, &rendered_second).unwrap();
        let second_write = fs::read_to_string(&path).unwrap();

        assert_eq!(
            first_write, second_write,
            "nats.conf must converge to the same content across repeated startups with an unchanged Config"
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
