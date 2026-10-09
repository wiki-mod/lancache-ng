//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: ui entry; root start, --prepare one-shots, HTTP.
//! Why: one binary owns the ui and its init steps.
//! From: Issue #1683 | PR #1858
#![deny(warnings)]

mod config;
mod dns_probe;
mod docker_client;
mod kea_snapshots;
mod nats_auth_callout;
mod nats_config;
mod nats_kick;
mod netdata_alarms;
mod nginx_client;
mod reverse_dns;
mod routes;
mod session;
mod syslog_client;
mod watchdog_status;

use anyhow::Result;
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::Request,
    http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use base64::Engine as _;
use bollard::Docker;
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use subtle::ConstantTimeEq;
use tera::Tera;
use tracing_subscriber::layer::SubscriberExt as _;
use tracing_subscriber::util::SubscriberInitExt as _;

pub struct AppState {
    pub templates: Tera,
    pub config: config::Config,
    pub docker: Docker,
    pub http_client: reqwest::Client,
    pub file_lock: std::sync::Mutex<()>,
    // Guards the read-modify-write in netdata_alarms::append_alarm -- see
    // that function's own doc comment for why a dedicated lock (not
    // file_lock above, which already serializes the unrelated
    // cdn-domains.txt writes in routes/domains.rs) is required here.
    pub netdata_alarms_lock: std::sync::Mutex<()>,
    pub kea_config_lock: tokio::sync::Mutex<()>,
    pub dhcp_probe_lock: tokio::sync::Mutex<()>,
    pub nats: async_nats::Client,
    pub db: Mutex<Connection>,
    pub ui_session_secret: [u8; 32],
    pub ui_session_ttl: Duration,
    // What: issuer public NKey for the callout fragment.
    // Why: the private seed stays in the responder KeyPair.
    // From: Issue #583
    pub nats_issuer_public_key: String,
    // What: callout xkey public key for the fragment.
    // Why: separate X25519 key; its seed stays in the task.
    // From: Issue #682
    pub nats_callout_xkey_public_key: String,
}

const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;
const MAX_UI_SESSION_TTL_SECONDS: u64 = 365 * 24 * 60 * 60;
const SECONDARY_REGISTRATION_TOKEN_FILE: &str = "/data/lancache-secondary-registration.token";
// What: effective ui log file (UI_LOG_FILE or the default).
// Why: tracing and the root start must agree on one path.
// From: Issue #633 | PR #1858
fn ui_log_file() -> String {
    std::env::var("UI_LOG_FILE").unwrap_or_else(|_| "/var/log/lancache-ui/ui.log".to_string())
}

// What: a real token as is, else a persisted random one.
// Why: placeholders crash-looped the ui; must not rotate.
fn load_or_create_secondary_registration_token(
    configured: &str,
    path: &str,
) -> Result<String, String> {
    if !lancache_common::is_placeholder(configured) {
        return Ok(configured.to_string());
    }
    match fs::read_to_string(path) {
        Ok(contents) => {
            let existing = contents.trim();
            if lancache_common::is_placeholder(existing) {
                return Err(format!(
                    "persisted secondary registration token at {path} is empty or a \
                     placeholder — refusing to start. Delete the file to regenerate it, \
                     or set SECONDARY_REGISTRATION_TOKEN to a real secret"
                ));
            }
            Ok(existing.to_string())
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let token = hex::encode(rand::random::<[u8; 32]>());
            lancache_common::write_file(
                Path::new(path),
                token.as_bytes(),
                0o600,
                lancache_common::Place::Exclusive,
            )
            .map_err(|e| {
                format!("failed to write secondary registration token file at {path}: {e}")
            })?;
            tracing::warn!(
                "SECONDARY_REGISTRATION_TOKEN was unset or a placeholder; generated a \
                 persistent random registration token at {path}. To register a secondary \
                 DNS node, read the value from that file or set SECONDARY_REGISTRATION_TOKEN \
                 explicitly."
            );
            Ok(token)
        }
        Err(err) => Err(format!(
            "failed to read secondary registration token file at {path}: {err}"
        )),
    }
}

// What: dirs the ui writes, derived from its own config.
// Why: chown follows the configured paths, no second list.
// From: Issue #1427 | PR #1858
fn ui_written_dirs(cfg: &config::Config, log_file: &Path) -> Vec<std::path::PathBuf> {
    let files = [
        &cfg.cdn_domains_file,
        &cfg.netdata_alarms_file,
        &cfg.nats_xkey_seed_path,
        &cfg.desired_state_file,
        &cfg.nats_conf_path,
    ];
    let mut dirs: Vec<std::path::PathBuf> = files
        .iter()
        .filter_map(|f| Path::new(f.as_str()).parent().map(Path::to_path_buf))
        .chain([
            std::path::PathBuf::from(&cfg.dns_standard_state_dir),
            std::path::PathBuf::from(&cfg.dns_ssl_state_dir),
        ])
        .chain(log_file.parent().map(Path::to_path_buf))
        .filter(|d| !d.as_os_str().is_empty())
        .collect();
    dirs.sort();
    dirs.dedup();
    dirs
}

// What: lchown a tree recursively, never following links.
// Why: a symlink in a volume must not redirect root's chown.
// From: Issue #1427
fn chown_tree(path: &Path, uid: u32, gid: u32) -> std::io::Result<()> {
    std::os::unix::fs::lchown(path, Some(uid), Some(gid))?;
    if fs::symlink_metadata(path)?.is_dir() {
        for entry in fs::read_dir(path)? {
            chown_tree(&entry?.path(), uid, gid)?;
        }
    }
    Ok(())
}

// What: log dir and files in gid; setgid dir, files g+r.
// Why: the shared log reader gid must keep read access.
// From: Issue #1427 | PR #1670
fn open_log_dir_to_group(dir: &Path, gid: u32) -> std::io::Result<()> {
    std::os::unix::fs::lchown(dir, None, Some(gid))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o2775))?;
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let meta = fs::symlink_metadata(&path)?;
        if meta.is_file() {
            std::os::unix::fs::lchown(&path, None, Some(gid))?;
            fs::set_permissions(&path, fs::Permissions::from_mode(meta.mode() | 0o040))?;
        }
    }
    Ok(())
}

// What: print a FATAL start error and exit 1.
// Why: the root start fails closed before the server runs.
// From: Issue #858
fn container_start_fatal(message: &str) -> ! {
    eprintln!("[lancache-ui] FATAL: {message}");
    std::process::exit(1);
}

// What: a required numeric id from the image environment.
// Why: the Dockerfile owns the runtime uid/gid, not code.
// From: Issue #1427 | PR #1858
fn required_env_id(key: &str) -> u32 {
    let raw =
        std::env::var(key).unwrap_or_else(|_| container_start_fatal(&format!("{key} is not set")));
    raw.parse()
        .unwrap_or_else(|_| container_start_fatal(&format!("{key}={raw} is not an id")))
}

// What: started as root: secrets, ownership, then exec as user.
// Why: the server must never run as root; volumes start root.
// From: Issue #858 | PR #1858
fn container_root_start() {
    let euid = fs::metadata("/proc/self")
        .unwrap_or_else(|e| container_start_fatal(&format!("cannot read /proc/self: {e}")))
        .uid();
    if euid != 0 {
        return;
    }
    let uid = required_env_id("UI_RUNTIME_UID");
    let gid = required_env_id("UI_RUNTIME_GID");
    let cfg = config::Config::from_env().unwrap_or_else(|e| container_start_fatal(&e));
    if let Err(e) = config::ensure_shared_secrets(&cfg.shared_secret_dir, gid, "") {
        container_start_fatal(&format!(
            "cannot resolve shared secret {e}. Mount the shared-secrets volume \
             or set the variable to the value its backend uses."
        ));
    }
    let log_file = std::path::PathBuf::from(ui_log_file());
    for dir in ui_written_dirs(&cfg, &log_file) {
        if fs::symlink_metadata(&dir).is_ok()
            && let Err(e) = chown_tree(&dir, uid, gid)
        {
            container_start_fatal(&format!("cannot chown {}: {e}", dir.display()));
        }
    }
    if let Some(log_dir) = log_file.parent()
        && log_dir.exists()
        && let Err(e) = open_log_dir_to_group(log_dir, gid)
    {
        container_start_fatal(&format!("cannot set {} modes: {e}", log_dir.display()));
    }
    let exe = std::env::current_exe()
        .unwrap_or_else(|e| container_start_fatal(&format!("cannot locate own binary: {e}")));
    let mut args = std::env::args_os();
    let argv0 = args.next().unwrap_or_else(|| exe.clone().into_os_string());
    let err = std::process::Command::new(&exe)
        .arg0(argv0)
        .args(args)
        .uid(uid)
        .gid(gid)
        .exec();
    container_start_fatal(&format!("cannot exec as uid {uid}: {err}"));
}

// Additive-only migration for the `secondaries` table (issue #583): adds
// `nats_user`/`nats_password_hash`, the per-secondary auth-callout identity
// columns, without touching the legacy `nats_token` column (kept as an
// unused, harmless leftover rather than dropped -- SQLite's DROP COLUMN
// requires a table rebuild, and there is nothing to gain from that risk on a
// column register_secondary simply stops reading). A secondary registered
// under the pre-#583 shared-token model has NULL nats_password_hash until it
// is re-registered or rotated, at which point `authorize_secondary` (see
// nats_auth_callout.rs) naturally denies it -- documented in CHANGELOG.md as
// a required manual step after upgrading.
fn migrate_secondaries_table_for_auth_callout(conn: &Connection) -> rusqlite::Result<()> {
    let existing_columns: Vec<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(secondaries)")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    if !existing_columns.iter().any(|c| c == "nats_user") {
        conn.execute("ALTER TABLE secondaries ADD COLUMN nats_user TEXT", [])?;
    }
    if !existing_columns.iter().any(|c| c == "nats_password_hash") {
        conn.execute(
            "ALTER TABLE secondaries ADD COLUMN nats_password_hash TEXT",
            [],
        )?;
    }
    // #1084: the secondary's reachable DNS address, for the active health
    // probe. Same additive, idempotent ALTER pattern as the auth-callout
    // columns above; NULL for a row registered before this column existed (and
    // for any secondary whose setup.sh did not report an address) until the
    // next registration or a manual address override sets it.
    if !existing_columns.iter().any(|c| c == "address") {
        conn.execute("ALTER TABLE secondaries ADD COLUMN address TEXT", [])?;
    }
    // What: a UNIQUE index on nats_user.
    // Why: two rows must never share one NATS identity.
    // From: Issue #849
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_secondaries_nats_user ON secondaries(nats_user)",
        [],
    )?;
    Ok(())
}

fn is_mutating_method(method: &Method) -> bool {
    matches!(
        *method,
        Method::POST | Method::PUT | Method::PATCH | Method::DELETE
    )
}

fn csrf_header_value(headers: &HeaderMap) -> Option<&str> {
    headers.get(CSRF_HEADER_NAME)?.to_str().ok()
}

const TEMPLATE_NAMES: &[&str] = &[
    "base.html",
    "dashboard.html",
    "dhcp.html",
    "domains.html",
    "secondaries.html",
    "stats.html",
    "logs.html",
    "setup.html",
];

// 'unsafe-inline' on script-src/style-src is a deliberate, narrower exception
// to an otherwise strict CSP: the Tera templates use inline `onclick=`
// handlers and inline `<style>` blocks rather than a nonce/hash scheme. Every
// other directive stays locked down (no external hosts, no object/frame
// embedding), so this does not open the page to third-party script injection.
const ADMIN_UI_CSP: &str = "default-src 'self'; \
             base-uri 'self'; \
             object-src 'none'; \
             frame-ancestors 'none'; \
             form-action 'self'; \
             script-src 'self' 'unsafe-inline'; \
             style-src 'self' 'unsafe-inline'; \
             img-src 'self' data:; \
             connect-src 'self'; \
             font-src 'self' data:";

fn forwarded_proto_is_https(headers: &axum::http::HeaderMap) -> bool {
    headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .is_some_and(|proto| proto.eq_ignore_ascii_case("https"))
}

async fn security_headers(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    req: Request<axum::body::Body>,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let is_https = forwarded_proto_is_https(req.headers());

    let mut response = next.run(req).await;
    if !state.config.security_headers_enabled {
        return response;
    }

    let headers = response.headers_mut();

    headers.insert(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_static(ADMIN_UI_CSP),
    );
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
    headers.insert(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    if state.config.hsts_mode.should_send(is_https) {
        headers.insert(
            HeaderName::from_static("strict-transport-security"),
            HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        );
    }

    response
}

// Shallow liveness check for container healthchecks: proves the HTTP server
// is accepting connections, mirroring the proxy service's unauthenticated
// `/healthz` (see services/proxy/conf.d/http.conf) rather than probing NATS,
// Docker, or DNS reachability here.
async fn health() -> &'static str {
    "ok"
}

async fn admin_css() -> impl IntoResponse {
    (
        [(axum::http::header::CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("static/admin.css"),
    )
}

async fn chart_js() -> impl IntoResponse {
    (
        [
            (
                axum::http::header::CONTENT_TYPE,
                "application/javascript; charset=utf-8",
            ),
            (
                axum::http::header::CACHE_CONTROL,
                "public, max-age=31536000",
            ),
        ],
        include_str!("static/chart.umd.min.js"),
    )
}

async fn favicon_ico() -> impl IntoResponse {
    (
        [
            (axum::http::header::CONTENT_TYPE, "image/x-icon"),
            (
                axum::http::header::CACHE_CONTROL,
                "public, max-age=31536000",
            ),
        ],
        include_bytes!("static/favicon.ico").as_slice(),
    )
}

async fn logo_icon() -> impl IntoResponse {
    (
        [
            (axum::http::header::CONTENT_TYPE, "image/png"),
            (
                axum::http::header::CACHE_CONTROL,
                "public, max-age=31536000",
            ),
        ],
        include_bytes!("static/logo-icon.png").as_slice(),
    )
}

fn basic_auth_is_valid(headers: &HeaderMap, user: &str, pass: &str) -> bool {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Basic "))
        .and_then(|enc| base64::engine::general_purpose::STANDARD.decode(enc).ok())
        .and_then(|dec| String::from_utf8(dec).ok())
        .and_then(|creds| {
            let (provided_user, provided_pass) = creds.split_once(':')?;
            // Hash both sides to fixed-size 32-byte digests before comparing.
            // subtle's ct_eq on raw slices aborts early on length mismatch,
            // leaking credential length. Digests are always 32 bytes regardless
            // of input length, eliminating that timing side-channel.
            let user_match =
                Sha256::digest(provided_user.as_bytes()).ct_eq(&Sha256::digest(user.as_bytes()));
            let pass_match =
                Sha256::digest(provided_pass.as_bytes()).ct_eq(&Sha256::digest(pass.as_bytes()));
            Some(bool::from(user_match & pass_match))
        })
        .unwrap_or(false)
}

fn unauthorized_basic_auth_response() -> axum::response::Response {
    match axum::http::Response::builder()
        .status(axum::http::StatusCode::UNAUTHORIZED)
        .header("WWW-Authenticate", r#"Basic realm="LanCache Admin""#)
        .body(axum::body::Body::from("Unauthorized"))
    {
        Ok(response) => response,
        Err(err) => {
            tracing::error!(error = %err, "failed to build basic auth challenge response");
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                "Internal Server Error",
            )
                .into_response()
        }
    }
}

// Basic auth must be re-checked on every request when required, independent
// of any session cookie — see the security comment on the call site in
// `basic_auth` for why the cookie is never allowed to substitute for it.
fn requires_basic_auth_rejection(
    auth_required: bool,
    headers: &HeaderMap,
    state: &AppState,
) -> bool {
    match (&state.config.auth_user, &state.config.auth_password) {
        (Some(user), Some(pass)) if auth_required => !basic_auth_is_valid(headers, user, pass),
        _ => false,
    }
}

async fn basic_auth(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    mut req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let auth_required = state.config.auth_user.is_some() && state.config.auth_password.is_some();
    let secure_cookie = forwarded_proto_is_https(req.headers());
    let now = SystemTime::now();

    // The session cookie only carries CSRF state, never authentication. A
    // stolen/replayed cookie must not substitute for Basic auth, and rotating
    // the Basic password must immediately revoke access — so this check runs
    // on every request when auth is required, regardless of cookie validity.
    if requires_basic_auth_rejection(auth_required, req.headers(), &state) {
        return unauthorized_basic_auth_response();
    }

    let mut needs_cookie = false;
    let session = match session::session_cookie_value(req.headers()).and_then(|cookie_value| {
        session::validate_session_cookie(cookie_value, &state.ui_session_secret, now)
    }) {
        Some(session) => session,
        None => {
            needs_cookie = true;
            session::issue_session(&state.ui_session_secret, state.ui_session_ttl)
        }
    };

    session::set_internal_csrf_header(req.headers_mut(), &session.csrf_token);

    let method = req.method().clone();
    if is_mutating_method(&method) {
        let (parts, body) = req.into_parts();
        let body_bytes = match to_bytes(body, MAX_CSRF_BODY_BYTES).await {
            Ok(body_bytes) => body_bytes,
            Err(err) => {
                tracing::warn!(error = %err, "failed to read request body for csrf validation");
                let mut response = StatusCode::BAD_REQUEST.into_response();
                if needs_cookie {
                    session::set_session_cookie(
                        &mut response,
                        &session,
                        state.ui_session_ttl,
                        secure_cookie,
                    );
                }
                return response;
            }
        };

        let submitted_token = csrf_header_value(&parts.headers)
            .map(str::to_owned)
            .or_else(|| {
                form_urlencoded::parse(&body_bytes)
                    .find_map(|(key, value)| (key == CSRF_FORM_FIELD).then(|| value.into_owned()))
            });

        let valid = submitted_token
            .as_deref()
            .is_some_and(|token| session::token_matches(&session.csrf_token, token));
        if !valid {
            let mut response = StatusCode::FORBIDDEN.into_response();
            if needs_cookie {
                session::set_session_cookie(
                    &mut response,
                    &session,
                    state.ui_session_ttl,
                    secure_cookie,
                );
            }
            return response;
        }

        let mut response = next
            .run(Request::from_parts(parts, Body::from(body_bytes)))
            .await;
        if needs_cookie {
            session::set_session_cookie(
                &mut response,
                &session,
                state.ui_session_ttl,
                secure_cookie,
            );
        }
        response
    } else {
        let mut response = next.run(req).await;
        if needs_cookie {
            session::set_session_cookie(
                &mut response,
                &session,
                state.ui_session_ttl,
                secure_cookie,
            );
        }
        response
    }
}

struct StaticTemplateValue {
    value: String,
}

impl StaticTemplateValue {
    fn new(value: String) -> Self {
        Self { value }
    }
}

impl tera::Function<String> for StaticTemplateValue {
    fn call(&self, _kwargs: tera::Kwargs, _state: &tera::State<'_>) -> String {
        self.value.clone()
    }
}

fn register_lancache_image_template_functions(templates: &mut Tera, cfg: &config::Config) {
    templates.register_function(
        "lancache_image_registry",
        StaticTemplateValue::new(cfg.lancache_image_registry.clone()),
    );
    templates.register_function(
        "lancache_image_prefix",
        StaticTemplateValue::new(cfg.lancache_image_prefix.clone()),
    );
    templates.register_function(
        "lancache_image_channel",
        StaticTemplateValue::new(cfg.lancache_image_channel.clone()),
    );
    templates.register_function(
        "lancache_image_tag",
        StaticTemplateValue::new(cfg.lancache_image_tag.clone()),
    );
}

// Panics on any missing/malformed template rather than returning a Result:
// a broken template is a deploy-time defect, not a runtime condition to
// recover from, and failing at startup (before the listener binds) is far
// preferable to a page-specific 500 the first time a user visits that route.
fn load_templates(cfg: &config::Config) -> Tera {
    let mut t = Tera::default();
    t.autoescape_on(vec!["html"]);
    // Functions must be registered before any template is added: Tera
    // validates function calls at parse time, so a template calling one of
    // these (e.g. base.html) would fail to parse if added first.
    register_lancache_image_template_functions(&mut t, cfg);
    for name in TEMPLATE_NAMES {
        let path = format!("{}/{}", cfg.template_dir, name);
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("Cannot read template {}: {}", path, e));
        t.add_raw_template(name, &content)
            .unwrap_or_else(|e| panic!("Cannot parse template {}: {}", name, e));
    }
    t
}

// NOTE: `main()` awaits this before binding the HTTP listener, so the Admin UI
// serves nothing at all — not even the login page — until NATS is reachable.
// A NATS outage therefore takes down the whole UI, not just NATS-backed
// features; this retry loop with exponential backoff (capped at 30s) is what
// keeps the process alive while waiting, rather than exiting and needing an
// external restart policy to retry the connection.
async fn connect_nats_with_retry(cfg: &config::Config) -> async_nats::Client {
    let mut delay = std::time::Duration::from_secs(1);
    let max_delay = std::time::Duration::from_secs(30);

    loop {
        // preflight_startup_config (called before this fn, see main()) has
        // already rejected a missing/empty nats_ui_password via
        // validate_runtime_nats_credentials, so by this point it's always
        // Some -- the None arm only exists because the field's type doesn't
        // encode that invariant.
        let result = match (cfg.nats_ui_user.is_empty(), cfg.nats_ui_password.as_deref()) {
            (false, Some(password)) if !password.is_empty() => {
                async_nats::ConnectOptions::with_user_and_password(
                    cfg.nats_ui_user.clone(),
                    password.to_string(),
                )
                .connect(&cfg.nats_url)
                .await
            }
            _ => async_nats::connect(&cfg.nats_url).await,
        };

        match result {
            Ok(client) => {
                tracing::info!("Connected to NATS at {}", cfg.nats_url);
                return client;
            }
            Err(err) => {
                tracing::warn!(
                    "Cannot connect to NATS at {}: {}. Retrying in {:?}",
                    cfg.nats_url,
                    err,
                    delay
                );

                tokio::time::sleep(delay).await;
                delay = nats_auth_callout::grow_backoff(delay, max_delay);
            }
        }
    }
}

fn resolve_admin_ui_auth_mode(
    auth_user: Option<&str>,
    auth_password: Option<&str>,
    allow_insecure_ui: bool,
) -> Result<bool, &'static str> {
    match (auth_user, auth_password) {
        (Some(_), Some(_)) => Ok(true),
        (None, None) if allow_insecure_ui => Ok(false),
        (None, None) => Err(
            "Admin-UI authentication is required. Set UI_AUTH_USER and UI_AUTH_PASSWORD, or explicitly set ALLOW_INSECURE_UI=true if you understand the risk.",
        ),
        _ => Err(
            "UI_AUTH_USER and UI_AUTH_PASSWORD must either both be set or both be empty. Refusing to start with a partial Admin-UI auth configuration.",
        ),
    }
}

fn validate_ui_session_ttl_seconds(seconds: u64) -> Result<(), String> {
    if seconds == 0 {
        return Err("UI_SESSION_TTL_SECONDS must be greater than zero".to_string());
    }
    if seconds > MAX_UI_SESSION_TTL_SECONDS {
        return Err(format!(
            "UI_SESSION_TTL_SECONDS ({seconds}) exceeds the maximum of {MAX_UI_SESSION_TTL_SECONDS} seconds (1 year)"
        ));
    }
    Ok(())
}

// What: minimum token length, counted in characters.
// Why: a short or multi-byte value is easy to brute-force.
const MIN_SECONDARY_REGISTRATION_TOKEN_LEN: usize = 32;

fn validate_secondary_registration_token(token: &str) -> Result<(), String> {
    if token.is_empty() {
        return Err(
            "SECONDARY_REGISTRATION_TOKEN is not set or empty — refusing to start. \
             Generate one with: openssl rand -hex 32"
                .to_string(),
        );
    }
    if lancache_common::is_placeholder(token) {
        return Err(format!(
            "SECONDARY_REGISTRATION_TOKEN is still set to a default placeholder \
             ('{token}') — refusing to start. Generate a real secret with: \
             openssl rand -hex 32"
        ));
    }
    let token_char_len = token.chars().count();
    if token_char_len < MIN_SECONDARY_REGISTRATION_TOKEN_LEN {
        return Err(format!(
            "SECONDARY_REGISTRATION_TOKEN is only {token_char_len} character(s), below the \
             required minimum of {MIN_SECONDARY_REGISTRATION_TOKEN_LEN} — refusing to start. \
             This token is the only thing gating remote secondary registration; a short value \
             is practical to brute-force. Generate a real secret with: openssl rand -hex 32"
        ));
    }
    Ok(())
}

fn preflight_startup_config(cfg: &config::Config) -> Result<Duration, String> {
    validate_ui_session_ttl_seconds(cfg.ui_session_ttl_seconds)?;
    nats_config::validate_runtime_nats_credentials(cfg)?;
    Ok(Duration::from_secs(cfg.ui_session_ttl_seconds))
}

// What: open UI_LOG_FILE to append; on error warn, go on.
// Why: tracing is not up yet; stdout-only must still start.
// From: Issue #849
fn open_ui_log_file(path: &str) -> Option<std::fs::File> {
    match OpenOptions::new().create(true).append(true).open(path) {
        Ok(file) => Some(file),
        Err(e) => {
            eprintln!(
                "warning: could not open UI_LOG_FILE at {path:?}: {e} \
                 (continuing with stdout-only logging)"
            );
            None
        }
    }
}

fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "lancache_ui=info,warn".parse().unwrap());
    let stdout_layer = tracing_subscriber::fmt::layer();

    let ui_log_file = ui_log_file();
    let file_layer = open_ui_log_file(&ui_log_file).map(|file| {
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_writer(Mutex::new(file))
    });

    tracing_subscriber::registry()
        .with(filter)
        .with(stdout_layer)
        .with(file_layer)
        .init();
}

// What: root start, unless a one-shot mode runs instead.
// Why: exec needs one thread; one-shots run as root as-is.
// From: Issue #1288 | PR #1858
fn main() -> Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("--prepare") => prepare_runtime(&std::env::args().skip(2).collect::<Vec<_>>()),
        Some("--dhcp-probe") => {}
        _ => container_root_start(),
    }
    run()
}

// What: one-shot root prep for an image we do not build.
// Why: compose holds no logic; the files are written here.
// From: Issue #1683 | PR #1858
fn prepare_runtime(args: &[String]) -> ! {
    let gid = required_env_id("UI_RUNTIME_GID");
    let done = match args {
        [target] if target == "nats" => prepare_nats(gid),
        [target] if target == "netdata" => prepare_netdata(gid),
        [target, dirs @ ..] if target == "logs" && !dirs.is_empty() => {
            dirs.iter().try_for_each(|d| {
                open_log_dir_to_group(Path::new(d), gid).map_err(|e| format!("{d}: {e}"))
            })
        }
        _ => Err("usage: --prepare nats | netdata | logs <dir>...".to_string()),
    };
    match done {
        Ok(()) => std::process::exit(0),
        Err(e) => container_start_fatal(&e),
    }
}

// What: resolve one prefix's secrets, then load Config.
// Why: Config reads a secret file only once it exists.
// From: Issue #1683 | PR #1858
fn prepared_config(gid: u32, prefix: &str) -> std::result::Result<config::Config, String> {
    let cfg = config::Config::from_env()?;
    config::ensure_shared_secrets(&cfg.shared_secret_dir, gid, prefix)?;
    config::Config::from_env()
}

// What: nats.conf, the fragment stub and the nats log dir.
// Why: nats-server reads all of them at its first start.
// From: Issue #1683 | PR #1858
fn prepare_nats(gid: u32) -> std::result::Result<(), String> {
    let uid = required_env_id("UI_RUNTIME_UID");
    let cfg = prepared_config(gid, "NATS_")?;
    let conf = nats_config::render_nats_conf(&cfg)?;
    write_file_if_changed(
        Path::new(&cfg.nats_conf_path),
        &conf,
        0o600,
        Some((uid, gid)),
    )?;
    create_if_absent(
        Path::new(&cfg.nats_auth_callout_path),
        0o644,
        Some((uid, gid)),
    )?;
    let dir = Path::new(&cfg.nats_log_file)
        .parent()
        .ok_or_else(|| format!("NATS_LOG_FILE={} has no directory", cfg.nats_log_file))?;
    open_log_dir_to_group(dir, gid).map_err(|e| format!("{}: {e}", dir.display()))
}

// What: alarm token, sender, log config and log dir.
// Why: the upstream netdata image has no hook of ours.
// From: Issue #1683 | PR #1858
fn prepare_netdata(gid: u32) -> std::result::Result<(), String> {
    let cfg = prepared_config(gid, "NETDATA_")?;
    if cfg.netdata_alarm_token.is_empty() {
        return Err("NETDATA_ALARM_TOKEN resolved to an empty value".to_string());
    }
    let need = |value: &Option<String>, key: &str| {
        value.clone().ok_or_else(|| format!("{key} is not set"))
    };
    let token = need(&cfg.netdata_token_file, "NETDATA_TOKEN_FILE")?;
    let notify = need(&cfg.netdata_notify_file, "NETDATA_NOTIFY_FILE")?;
    let conf = need(&cfg.netdata_conf_file, "NETDATA_CONF_FILE")?;
    let daemon_log = need(&cfg.netdata_daemon_log, "NETDATA_DAEMON_LOG")?;
    let health_log = need(&cfg.netdata_health_log, "NETDATA_HEALTH_LOG")?;
    let sender = routes::netdata_alarms::render_alarm_notify_conf(
        &need(&cfg.netdata_alarm_ui_url, "NETDATA_ALARM_UI_URL")?,
        &token,
        &need(&cfg.netdata_alarm_max_time, "NETDATA_ALARM_MAX_TIME")?,
        &need(&cfg.netdata_alarm_recipient, "NETDATA_ALARM_RECIPIENT")?,
    )?;
    if [&daemon_log, &health_log]
        .iter()
        .any(|p| p.contains(['\n', '\r']))
    {
        return Err("a netdata log path holds a line break".to_string());
    }
    let mut log_dirs: Vec<&Path> = [&daemon_log, &health_log]
        .iter()
        .map(|p| Path::new(p.as_str()).parent())
        .collect::<Option<_>>()
        .ok_or("a netdata log path has no directory")?;
    log_dirs.dedup();
    let logs = format!("[logs]\ndaemon = {daemon_log}\nhealth = {health_log}\n");
    write_file_if_changed(Path::new(&token), &cfg.netdata_alarm_token, 0o600, None)?;
    write_file_if_changed(Path::new(&notify), &sender, 0o644, None)?;
    write_file_if_changed(Path::new(&conf), &logs, 0o644, None)?;
    log_dirs.iter().try_for_each(|dir| {
        open_log_dir_to_group(dir, gid).map_err(|e| format!("{}: {e}", dir.display()))
    })
}

// What: an empty file only when none exists yet.
// Why: the ui owns the fragment; a rerun never clobbers it.
// From: Issue #811 | PR #1858
fn create_if_absent(
    path: &Path,
    mode: u32,
    owner: Option<(u32, u32)>,
) -> std::result::Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            write_file_if_changed(path, "", mode, owner).map(|_| ())
        }
        Err(e) => Err(format!("cannot stat {}: {e}", path.display())),
    }
}

// What: atomic replace of a file whose content differs.
// Why: readers never see a torn file; reruns write nothing.
// From: Issue #1683 | PR #1858
fn write_file_if_changed(
    path: &Path,
    content: &str,
    mode: u32,
    owner: Option<(u32, u32)>,
) -> std::result::Result<bool, String> {
    let changed = fs::read(path).ok().as_deref() != Some(content.as_bytes());
    if changed {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| format!("{} has no file name", path.display()))?;
        let stamp = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let tmp = path.with_file_name(format!(".{name}.tmp-{}-{stamp}", std::process::id()));
        let written = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)
            .and_then(|mut f| {
                f.write_all(content.as_bytes())?;
                f.sync_all()?;
                match owner {
                    Some((uid, gid)) => std::os::unix::fs::fchown(&f, Some(uid), Some(gid)),
                    None => Ok(()),
                }
            })
            .and_then(|()| fs::rename(&tmp, path));
        if let Err(e) = written {
            let cleanup = match fs::remove_file(&tmp) {
                Err(c) if c.kind() != std::io::ErrorKind::NotFound => format!("; {c}"),
                _ => String::new(),
            };
            return Err(format!("cannot replace {}: {e}{cleanup}", path.display()));
        }
    }
    // What: mode and owner converge when unchanged too.
    // Why: an old install may carry other rights.
    // From: Issue #1683 | PR #1858
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|e| format!("cannot chmod {}: {e}", path.display()))?;
    if let Some((uid, gid)) = owner {
        std::os::unix::fs::lchown(path, Some(uid), Some(gid))
            .map_err(|e| format!("cannot chown {}: {e}", path.display()))?;
    }
    Ok(changed)
}

#[tokio::main]
async fn run() -> Result<()> {
    // Alternate CLI mode (issue #1288): this same binary/image is also the
    // `dhcp-probe` container's entrypoint (see deploy/*/docker-compose.yml,
    // `["/usr/local/bin/lancache-ui", "--dhcp-probe"]`), replacing the
    // former separate `dhcp-probe.sh` script. Intercepted before any of the
    // real Admin UI server's config/tracing/AppState setup below because
    // the dhcp-probe container deliberately runs with none of the Admin
    // UI's own environment configured (no `environment:`/`env_file:` entry
    // at all on that compose service) -- this mode must not depend on any
    // of it. Runs the (blocking, socket-only) probe on its own thread via
    // spawn_blocking rather than blocking this async runtime's worker
    // thread directly, then exits 0 unconditionally: see
    // dhcp_probe_native::run_probe's own comment on why every outcome,
    // including an internal failure, must still exit 0 (issues
    // #1155/#1156's one-shot update-health-gate contract).
    if std::env::args().nth(1).as_deref() == Some("--dhcp-probe") {
        tokio::task::spawn_blocking(lancache_ui::dhcp_probe_native::run_cli_and_print)
            .await
            .ok();
        return Ok(());
    }

    init_tracing();

    let mut cfg = match config::Config::from_env() {
        Ok(cfg) => cfg,
        Err(message) => {
            tracing::error!("{message}");
            std::process::exit(1);
        }
    };

    // Validate before the retry loop and secret creation so bad env overrides
    // fail closed without waiting on NATS or creating durable session state.
    let ui_session_ttl = match preflight_startup_config(&cfg) {
        Ok(ui_session_ttl) => ui_session_ttl,
        Err(message) => {
            tracing::error!("{message}");
            std::process::exit(1);
        }
    };

    let auth_user = cfg.auth_user.as_deref().filter(|value| !value.is_empty());
    let auth_password = cfg
        .auth_password
        .as_deref()
        .filter(|value| !value.is_empty());

    match resolve_admin_ui_auth_mode(auth_user, auth_password, cfg.allow_insecure_ui) {
        Ok(false) => {
            tracing::warn!("ALLOW_INSECURE_UI=true — starting Admin-UI without authentication");
        }
        Ok(true) => {}
        Err(message) => {
            tracing::error!("{message}");
            std::process::exit(1);
        }
    }

    let templates = load_templates(&cfg);
    let docker = docker_client::connect_from_env()?;
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    // Resolved and validated before the NATS retry loop below (which retries
    // forever), matching this function's own stated ordering principle
    // above: a bad token configuration must fail closed immediately, not
    // wait behind an indefinite NATS connection retry when NATS also
    // happens to be unavailable. Alongside the other durable /data secrets:
    // a real operator value is preserved, otherwise a persistent random one
    // is generated so the documented manual compose path starts securely
    // instead of crash-looping (see load_or_create_secondary_registration_token).
    // validate_* then asserts the resolved value is real as defense in depth.
    let secondary_registration_token = match load_or_create_secondary_registration_token(
        &cfg.secondary_registration_token,
        SECONDARY_REGISTRATION_TOKEN_FILE,
    ) {
        Ok(token) => token,
        Err(message) => {
            tracing::error!("{message}");
            std::process::exit(1);
        }
    };
    if let Err(message) = validate_secondary_registration_token(&secondary_registration_token) {
        tracing::error!("{message}");
        std::process::exit(1);
    }
    cfg.secondary_registration_token = secondary_registration_token;

    let nats = connect_nats_with_retry(&cfg).await;
    // What: the CSRF/session-signing secret, kept across restarts.
    // Why: a recreate must not invalidate every open session.
    // From: Issue #1683 | PR #1858
    let ui_session_secret =
        lancache_common::load_or_create_hex::<32>(Path::new("/data/lancache-ui-session.secret"))?;

    // What: issuer key from NATS_ISSUER_SEED or its file.
    // Why: the fragment write below needs its public key.
    // From: Issue #583
    let issuer_keypair = match &cfg.nats_issuer_seed {
        Some(seed) => match nkeys::KeyPair::from_seed(seed) {
            Ok(kp) => kp,
            Err(e) => {
                tracing::error!("NATS_ISSUER_SEED is not a valid NKey seed: {e}");
                std::process::exit(1);
            }
        },
        None => {
            match nats_auth_callout::load_or_create_issuer_keypair(&cfg.nats_issuer_seed_path) {
                Ok(kp) => kp,
                Err(message) => {
                    tracing::error!("{message}");
                    std::process::exit(1);
                }
            }
        }
    };
    let nats_issuer_public_key = issuer_keypair.public_key();

    // Same rationale and load-or-create shape as issuer_keypair immediately
    // above, just for the separate xkey encryption keypair (issue #682).
    // NATS_XKEY_SEED (a literal seed value) takes precedence over the
    // file-based path when set, mirroring nats_issuer_seed exactly -- see
    // config.rs's nats_xkey_seed docs.
    let xkey = match &cfg.nats_xkey_seed {
        Some(seed) => match nkeys::XKey::from_seed(seed) {
            Ok(kp) => kp,
            Err(e) => {
                tracing::error!("NATS_XKEY_SEED is not a valid NKey seed: {e}");
                std::process::exit(1);
            }
        },
        None => match nats_auth_callout::load_or_create_xkey(&cfg.nats_xkey_seed_path) {
            Ok(kp) => kp,
            Err(message) => {
                tracing::error!("{message}");
                std::process::exit(1);
            }
        },
    };
    let nats_callout_xkey_public_key = xkey.public_key();

    let db = {
        // This SQLite DB stores Admin-UI-local secondary registration metadata.
        // Runtime DNS/DHCP/proxy state stays in PowerDNS, Kea, NATS, and Docker.
        let conn = Connection::open("/data/lancache-ui.db").expect("Cannot open UI database");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );",
        )
        .expect("Cannot init database schema");
        migrate_secondaries_table_for_auth_callout(&conn)
            .expect("Cannot migrate secondaries table for auth-callout columns");
        Mutex::new(conn)
    };

    let state = Arc::new(AppState {
        templates,
        config: cfg,
        docker,
        http_client,
        file_lock: std::sync::Mutex::new(()),
        netdata_alarms_lock: std::sync::Mutex::new(()),
        kea_config_lock: tokio::sync::Mutex::new(()),
        dhcp_probe_lock: tokio::sync::Mutex::new(()),
        nats,
        db,
        ui_session_secret,
        ui_session_ttl,
        nats_issuer_public_key,
        nats_callout_xkey_public_key,
    });

    // What: write the fragment; restart NATS on change.
    // Why: the docker proxy may not be ready at ui start.
    // From: Issue #811 | PR #1610
    const NATS_CONF_RELOAD_MAX_ATTEMPTS: u32 = 8;
    let nats_conf_reload_max_delay = std::time::Duration::from_secs(8);
    let mut nats_conf_reload_delay = std::time::Duration::from_secs(1);
    let mut last_err = None;
    for attempt in 1..=NATS_CONF_RELOAD_MAX_ATTEMPTS {
        match routes::secondaries::reload_nats_conf(&state).await {
            Ok(()) => {
                last_err = None;
                break;
            }
            Err(e) => {
                tracing::warn!(
                    "Could not apply the auth_callout fragment (attempt {}/{}): {}. Retrying in {:?}",
                    attempt,
                    NATS_CONF_RELOAD_MAX_ATTEMPTS,
                    e,
                    nats_conf_reload_delay
                );
                last_err = Some(e);
                if attempt < NATS_CONF_RELOAD_MAX_ATTEMPTS {
                    tokio::time::sleep(nats_conf_reload_delay).await;
                    nats_conf_reload_delay = nats_auth_callout::grow_backoff(
                        nats_conf_reload_delay,
                        nats_conf_reload_max_delay,
                    );
                }
            }
        }
    }
    if let Some(e) = last_err {
        tracing::error!(
            "Failed to apply the auth_callout fragment after {} attempts -- NATS keeps its previous fragment and may reject this run's callout responses: {}",
            NATS_CONF_RELOAD_MAX_ATTEMPTS,
            e
        );
    }

    // Runs for the lifetime of the process: answers every NATS auth-callout
    // request for secondaries (see nats_auth_callout.rs). Registering,
    // removing, or rotating a secondary only ever touches the `secondaries`
    // table now -- no nats.conf rewrite or NATS restart needed for any of
    // those, since this task re-checks the DB on every single connection
    // attempt.
    tokio::spawn(nats_auth_callout::run_auth_callout(
        Arc::clone(&state),
        Arc::new(issuer_keypair),
        Arc::new(xkey),
    ));

    // Routes that are always public (protected by their own token).
    let public_routes = Router::new()
        .route("/health", get(health))
        .route(
            "/api/secondary/register",
            post(routes::secondaries::register_secondary),
        )
        // What: netdata alarm webhook, token-header gated.
        // Why: no browser session, so no CSRF token exists.
        // From: Issue #858
        .route(
            routes::netdata_alarms::INGEST_PATH,
            post(routes::netdata_alarms::ingest_alarm),
        )
        // Not behind basic_auth on purpose: these are non-sensitive brand
        // assets, not gated content. Serving them through the protected
        // router would attach a session-issuing Set-Cookie to a response
        // already marked publicly cacheable, letting a shared cache in
        // front of the Admin UI replay one client's session cookie to
        // another (see PR #553 review). The browser's own Basic Auth
        // prompt still blocks every request to this origin regardless, so
        // this doesn't change when a client can actually fetch them.
        .route("/favicon.ico", get(favicon_ico))
        .route("/static/logo-icon.png", get(logo_icon));

    // Routes that are protected by Basic Auth when auth is enabled. The
    // middleware also issues per-session CSRF state for every request.
    let protected_routes = Router::new()
        .route("/", get(routes::dashboard::dashboard))
        .route("/dhcp", get(routes::dhcp::dhcp_page))
        .route("/dhcp/mode", post(routes::dhcp::update_dhcp_mode))
        .route("/dhcp/ddns", post(routes::dhcp::update_dhcp_ddns))
        .route("/dhcp/proxy", post(routes::dhcp::update_dhcp_proxy))
        .route("/dhcp/relay", post(routes::dhcp::update_dhcp_relay))
        .route("/dhcp/subnet/add", post(routes::dhcp::add_subnet))
        .route("/dhcp/subnet/update", post(routes::dhcp::update_subnet))
        .route("/dhcp/subnet/remove", post(routes::dhcp::remove_subnet))
        .route(
            "/dhcp/subnet/option/add",
            post(routes::dhcp::add_subnet_option),
        )
        .route(
            "/dhcp/subnet/option/remove",
            post(routes::dhcp::remove_subnet_option),
        )
        .route("/dhcp/static/add", post(routes::dhcp::add_reservation))
        .route(
            "/dhcp/static/remove",
            post(routes::dhcp::remove_reservation),
        )
        .route("/dhcp/lease/release", post(routes::dhcp::release_lease))
        .route(
            "/dhcp/snapshot/rollback",
            post(routes::dhcp::rollback_kea_snapshot),
        )
        // POST, not GET: this route has a real side effect (starts/stops the
        // DHCP conflict-probe container) and CSRF protection in this app's
        // basic_auth middleware only covers mutating methods -- see
        // check_dhcp_conflict's own comment for the header-based CSRF check
        // that pairs with this route now being a mutating method.
        .route("/api/dhcp/check", post(routes::dhcp::check_dhcp_conflict))
        .route("/ntp", get(routes::ntp::ntp_page))
        .route("/ntp/settings", post(routes::ntp::update_ntp_settings))
        .route("/domains", get(routes::domains::domains_page))
        .route("/domains/dns/add", post(routes::domains::add_dns))
        .route("/domains/dns/remove", post(routes::domains::remove_dns))
        .route(
            "/domains/dns/toggle",
            post(routes::domains::toggle_default_domain),
        )
        .route("/domains/lan/add", post(routes::domains::add_lan_record))
        .route(
            "/domains/lan/remove",
            post(routes::domains::remove_lan_record),
        )
        .route("/domains/ptr/add", post(routes::domains::add_ptr_record))
        .route(
            "/domains/ptr/remove",
            post(routes::domains::remove_ptr_record),
        )
        .route(
            "/domains/aaaa-filter",
            post(routes::domains::toggle_aaaa_filter),
        )
        .route(
            "/domains/ddns-allow-unsigned-updates",
            post(routes::domains::toggle_ddns_allow_unsigned_updates),
        )
        .route(
            "/domains/zones/rollback",
            post(routes::dns_snapshots::rollback_zone_snapshot),
        )
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
        .route("/setup/update", post(routes::setup::update_stack_settings))
        .route("/setup/restart-ui", post(routes::setup::restart_ui_service))
        .route(
            "/api/services/{service}/desired-state",
            post(routes::setup::set_service_desired_state),
        )
        .route("/cache/resize", post(routes::cache::resize_cache))
        .route("/api/metrics", get(routes::dashboard::metrics_api))
        .route(
            "/api/watchdog-status",
            get(routes::dashboard::watchdog_status_api),
        )
        .route("/api/netdata/{*path}", get(routes::netdata_proxy::proxy))
        .route("/static/admin.css", get(admin_css))
        .route("/static/chart.umd.min.js", get(chart_js))
        .route("/secondaries", get(routes::secondaries::secondaries_page))
        .route(
            "/api/secondary/{name}",
            axum::routing::delete(routes::secondaries::remove_secondary),
        )
        .route(
            "/api/secondary/{name}/rotate-token",
            post(routes::secondaries::rotate_token),
        )
        .route(
            "/api/secondary/{name}/health",
            post(routes::secondaries::check_secondary_health),
        )
        .route(
            "/api/secondary/{name}/address",
            post(routes::secondaries::set_secondary_address),
        )
        .layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            basic_auth,
        ));

    let app = Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            security_headers,
        ))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    tracing::info!("LanCache Admin UI running on http://0.0.0.0:8080");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: check one placeholder-fixture column against `rule`.
    // Why: one reader; blank/# lines skip like the bash reader.
    // From: Issue #967 | PR #1858
    fn assert_parity_column(column: usize, rule: fn(&str) -> bool) {
        let fixture_path = format!(
            "{}/../../tests/fixtures/placeholder-detection-cases.txt",
            env!("CARGO_MANIFEST_DIR")
        );
        let contents = std::fs::read_to_string(&fixture_path)
            .unwrap_or_else(|e| panic!("could not read shared parity fixture {fixture_path}: {e}"));
        let mut total = 0usize;
        let mut mismatches: Vec<String> = Vec::new();
        for line in contents.lines().map(str::trim_end) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split_whitespace().collect();
            let [value, ..] = fields.as_slice() else {
                panic!("malformed shared parity fixture line: {line:?}");
            };
            let expect = fields
                .get(column)
                .unwrap_or_else(|| panic!("fixture line lacks column {column}: {line:?}"));
            total += 1;
            let actual = if rule(value) { "placeholder" } else { "real" };
            if actual != *expect {
                mismatches.push(format!("'{value}' expected={expect} actual={actual}"));
            }
        }
        assert!(total > 0, "shared parity fixture had zero usable cases");
        assert!(
            mismatches.is_empty(),
            "{} of {total} fixture case(s) disagreed (column {column}):\n{}",
            mismatches.len(),
            mismatches.join("\n")
        );
    }

    // What: a fresh, unique temp dir for one test.
    // Why: parallel tests must not share secret files.
    // From: PR #1858
    fn unique_temp_dir(tag: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("lancache-ng-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    // What: written dirs are the config paths' dirs, deduped.
    // Why: chown must follow configuration, not a fixed list.
    // From: Issue #1427 | PR #1858
    #[test]
    fn ui_written_dirs_follow_the_configured_paths() {
        let _guard = config::env_test_lock().lock().unwrap();
        let mut cfg = config::Config::from_env().unwrap();
        cfg.cdn_domains_file = "/w/data/a".to_string();
        cfg.netdata_alarms_file = "/w/data/b".to_string();
        cfg.nats_xkey_seed_path = "/w/data/c".to_string();
        cfg.desired_state_file = "/w/data/d".to_string();
        cfg.nats_conf_path = "/w/nats/nats.conf".to_string();
        cfg.dns_standard_state_dir = "/w/dns".to_string();
        cfg.dns_ssl_state_dir = "/w/dns".to_string();
        let dirs = ui_written_dirs(&cfg, Path::new("/w/log/ui.log"));
        let want: Vec<std::path::PathBuf> = ["/w/data", "/w/dns", "/w/log", "/w/nats"]
            .iter()
            .map(std::path::PathBuf::from)
            .collect();
        assert_eq!(dirs, want);
    }

    // What: chown walks a tree but never follows a symlink.
    // Why: a dangling link would fail a following chown.
    // From: Issue #1427
    #[test]
    fn chown_tree_does_not_follow_symlinks() {
        let dir = unique_temp_dir("chown-tree");
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        std::fs::write(dir.join("a/b/f"), "x").unwrap();
        std::os::unix::fs::symlink("/nonexistent/lancache-ng-target", dir.join("a/link")).unwrap();
        let meta = std::fs::metadata(&dir).unwrap();
        chown_tree(&dir, meta.uid(), meta.gid()).unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    // What: log dir gets 2775, regular files gain g+r.
    // Why: the shared log reader gid reads ui.log.
    // From: Issue #1427 | PR #1670
    #[test]
    fn open_log_dir_to_group_sets_dir_and_file_modes() {
        let dir = unique_temp_dir("log-dir");
        let file = dir.join("ui.log");
        std::fs::write(&file, "x").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let gid = std::fs::metadata(&dir).unwrap().gid();
        open_log_dir_to_group(&dir, gid).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().mode() & 0o7777, 0o2775);
        assert_eq!(std::fs::metadata(&file).unwrap().mode() & 0o777, 0o640);
        assert_eq!(std::fs::metadata(&dir).unwrap().gid(), gid);
        assert_eq!(std::fs::metadata(&file).unwrap().gid(), gid);
        std::fs::remove_dir_all(dir).unwrap();
    }

    // What: write once, rerun skips, change renames.
    // Why: no torn file; an equal rerun writes nothing.
    // From: Issue #1683 | PR #1858
    #[test]
    fn write_file_if_changed_replaces_atomically_and_only_on_change() {
        let dir = unique_temp_dir("write-if-changed");
        let path = dir.join("nats.conf");
        let meta = std::fs::metadata(&dir).unwrap();
        let owner = Some((meta.uid(), meta.gid()));
        assert!(write_file_if_changed(&path, "v1", 0o600, owner).unwrap());
        let first = std::fs::metadata(&path).unwrap();
        assert_eq!(first.mode() & 0o777, 0o600);
        assert!(!write_file_if_changed(&path, "v1", 0o600, owner).unwrap());
        assert_eq!(std::fs::metadata(&path).unwrap().ino(), first.ino());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!write_file_if_changed(&path, "v1", 0o600, owner).unwrap());
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        assert!(write_file_if_changed(&path, "v2", 0o600, owner).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "v2");
        assert_ne!(std::fs::metadata(&path).unwrap().ino(), first.ino());
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    // What: create empty; an existing file stays as is.
    // Why: the ui's auth_callout fragment must survive.
    // From: Issue #811 | PR #1858
    #[test]
    fn create_if_absent_never_clobbers_an_existing_file() {
        let dir = unique_temp_dir("create-if-absent");
        let path = dir.join("auth_callout.conf");
        create_if_absent(&path, 0o644, None).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "");
        std::fs::write(&path, "auth_callout { issuer: \"x\" }").unwrap();
        create_if_absent(&path, 0o644, None).unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "auth_callout { issuer: \"x\" }"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    // Proves migrate_secondaries_table_for_auth_callout actually adds
    // nats_user/nats_password_hash via ALTER TABLE when a table predates
    // the auth-callout columns, and that the new columns are immediately
    // writable/readable afterwards -- not just that the SQL statement runs
    // without error.
    #[test]
    fn migration_adds_auth_callout_columns_to_a_fresh_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );",
        )
        .unwrap();

        migrate_secondaries_table_for_auth_callout(&conn).unwrap();

        // Must be able to write and read the new columns now.
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at, nats_user, nats_password_hash)
             VALUES ('sec-a', 'sec-a', '', 0, 'sec-a', 'somehash')",
            [],
        )
        .unwrap();
        let stored: String = conn
            .query_row(
                "SELECT nats_password_hash FROM secondaries WHERE name = 'sec-a'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored, "somehash");
    }

    // A container restart re-runs this migration against an already-migrated
    // database, so it must tolerate being applied twice without erroring on
    // "duplicate column name" and must never touch a pre-existing row's
    // original columns (nats_token, registered_at) in the process.
    #[test]
    fn migration_preserves_existing_rows_and_is_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at)
             VALUES ('pre-existing', 'pre-existing', 'old-shared-token', 42)",
            [],
        )
        .unwrap();

        migrate_secondaries_table_for_auth_callout(&conn).unwrap();
        // Running it again (e.g. a second container start after the first
        // already migrated) must not error on "duplicate column name".
        migrate_secondaries_table_for_auth_callout(&conn).unwrap();

        let (nats_token, registered_at): (String, i64) = conn
            .query_row(
                "SELECT nats_token, registered_at FROM secondaries WHERE name = 'pre-existing'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(nats_token, "old-shared-token");
        assert_eq!(registered_at, 42);
    }

    // #1084: the migration adds the nullable `address` column (idempotently),
    // and it must be writable/readable afterwards -- this is what the health
    // check's stored probe target depends on. Applying the migration twice must
    // not error on a duplicate column.
    #[test]
    fn migration_adds_writable_address_column_idempotently() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );",
        )
        .unwrap();

        migrate_secondaries_table_for_auth_callout(&conn).unwrap();
        migrate_secondaries_table_for_auth_callout(&conn).unwrap();

        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at, address)
             VALUES ('sec-a', 'sec-a', '', 0, '192.168.1.20')",
            [],
        )
        .unwrap();
        let stored: Option<String> = conn
            .query_row(
                "SELECT address FROM secondaries WHERE name = 'sec-a'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored.as_deref(), Some("192.168.1.20"));
    }

    // What: the UNIQUE index rejects a duplicate nats_user.
    // Why: a future write path must not share one identity.
    // From: Issue #849
    #[test]
    fn migration_adds_unique_index_rejecting_duplicate_nats_user() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );",
        )
        .unwrap();
        migrate_secondaries_table_for_auth_callout(&conn).unwrap();
        // Applying the migration twice (a real container-restart scenario)
        // must not error on "index already exists".
        migrate_secondaries_table_for_auth_callout(&conn).unwrap();

        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at, nats_user)
             VALUES ('sec-a', 'sec-a', '', 0, 'shared-identity')",
            [],
        )
        .unwrap();

        // A second row that (incorrectly) reuses the same nats_user must be
        // rejected by the index itself, independent of any name collision.
        let result = conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at, nats_user)
             VALUES ('sec-b', 'sec-b', '', 0, 'shared-identity')",
            [],
        );
        assert!(result.is_err());

        // Legacy pre-#583 rows with nats_user still NULL are unaffected:
        // SQLite treats every NULL as distinct under a UNIQUE index, so
        // multiple such rows must coexist without error.
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at)
             VALUES ('legacy-a', 'legacy-a', 'old-token', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO secondaries (name, consumer_name, nats_token, registered_at)
             VALUES ('legacy-b', 'legacy-b', 'old-token', 0)",
            [],
        )
        .unwrap();
    }

    // A writable path must still open successfully and produce a usable
    // `File` -- the diagnostic eprintln! only fires on the failure branch,
    // never on this happy path.
    #[test]
    fn open_ui_log_file_succeeds_for_a_writable_path() {
        let path = std::env::temp_dir().join(format!(
            "lancache-ui-log-file-test-{}.log",
            std::process::id()
        ));
        let path_str = path.to_str().unwrap();
        let _ = std::fs::remove_file(&path);

        assert!(open_ui_log_file(path_str).is_some());

        let _ = std::fs::remove_file(&path);
    }

    // What: an unopenable log path returns None, no panic.
    // Why: a bad UI_LOG_FILE must not stop the ui start.
    // From: Issue #849
    #[test]
    fn open_ui_log_file_fails_open_for_an_unwritable_path() {
        let dir = std::env::temp_dir().join(format!(
            "lancache-ui-log-file-test-dir-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // Opening a directory with OpenOptions::open always fails on Linux
        // (EISDIR) -- exactly the "unwritable/misconfigured path" case this
        // fix adds a diagnostic for.
        assert!(open_ui_log_file(dir.to_str().unwrap()).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    // X-Forwarded-Proto can carry a comma-separated chain when multiple
    // proxies each append their own value; only the first (leftmost, i.e.
    // closest to the original client) entry reflects what the client
    // actually used. Reading a later entry instead could flip HSTS
    // on/off incorrectly for a request that traversed more than one hop.
    #[test]
    fn forwarded_proto_https_detection_uses_first_proxy_value() {
        let mut headers = axum::http::HeaderMap::new();
        assert!(!forwarded_proto_is_https(&headers));

        headers.insert("x-forwarded-proto", HeaderValue::from_static("https"));
        assert!(forwarded_proto_is_https(&headers));

        headers.insert("x-forwarded-proto", HeaderValue::from_static("HTTPS, http"));
        assert!(forwarded_proto_is_https(&headers));

        headers.insert("x-forwarded-proto", HeaderValue::from_static("http, https"));
        assert!(!forwarded_proto_is_https(&headers));
    }

    // Locks in the specific external hosts and directives that must never
    // reappear in ADMIN_UI_CSP: a future change that adds a script tag
    // pulling from a CDN (as earlier revisions of this UI did) must not be
    // "fixed" by loosening the CSP to allow it, since that would reopen the
    // page to third-party script injection.
    #[test]
    fn csp_keeps_scripts_self_hosted_without_external_cdn_allowances() {
        assert!(ADMIN_UI_CSP.contains("script-src 'self' 'unsafe-inline'"));
        assert!(!ADMIN_UI_CSP.contains("cdn.tailwindcss.com"));
        assert!(!ADMIN_UI_CSP.contains("cdn.jsdelivr.net"));
        assert!(!ADMIN_UI_CSP.contains("'unsafe-eval'"));
    }

    // Baseline correctness for basic_auth_is_valid across its three states:
    // no Authorization header, a header with the wrong password, and the
    // matching credentials -- proving the constant-time comparison logic
    // still rejects/accepts the same way plain string equality would.
    #[test]
    fn basic_auth_rejects_wrong_credentials_and_accepts_correct_ones() {
        fn auth_header(user: &str, pass: &str) -> HeaderValue {
            let encoded =
                base64::engine::general_purpose::STANDARD.encode(format!("{user}:{pass}"));
            HeaderValue::from_str(&format!("Basic {encoded}")).unwrap()
        }

        let mut headers = HeaderMap::new();
        assert!(!basic_auth_is_valid(&headers, "admin", "secret"));

        headers.insert(
            axum::http::header::AUTHORIZATION,
            auth_header("admin", "wrong"),
        );
        assert!(!basic_auth_is_valid(&headers, "admin", "secret"));

        headers.insert(
            axum::http::header::AUTHORIZATION,
            auth_header("admin", "secret"),
        );
        assert!(basic_auth_is_valid(&headers, "admin", "secret"));
    }

    // Security invariant: possessing a valid, unexpired session cookie must
    // never be treated as equivalent to presenting valid Basic auth
    // credentials -- see the inline comment below for why a copied/replayed
    // cookie or a rotated password would otherwise silently bypass auth.
    #[test]
    fn a_valid_session_cookie_never_substitutes_for_required_basic_auth() {
        // A session cookie only ever carries CSRF state, never authentication:
        // accepting one in place of Basic auth would let a copied cookie
        // bypass auth, and survive a password rotation, until the session TTL
        // expired.
        let secret = [0x55; 32];
        let now = SystemTime::now();
        let session = session::issue_session_at(now, &secret, Duration::from_secs(300));
        assert!(session::validate_session_cookie(&session.cookie_value, &secret, now).is_some());

        let headers_without_basic_auth = HeaderMap::new();
        assert!(!basic_auth_is_valid(
            &headers_without_basic_auth,
            "admin",
            "secret"
        ));
    }

    // resolve_admin_ui_auth_mode must fail closed by default: no credentials
    // and no explicit ALLOW_INSECURE_UI opt-in is an error, not a silent
    // unauthenticated start. It must also reject a *partial*
    // configuration (only one of UI_AUTH_USER/UI_AUTH_PASSWORD set) even when
    // ALLOW_INSECURE_UI is true, since that combination is almost certainly a
    // misconfiguration rather than an intentional insecure deployment.
    #[test]
    fn admin_ui_auth_requires_explicit_opt_in_for_insecure_mode() {
        assert_eq!(
            resolve_admin_ui_auth_mode(Some("admin"), Some("secret"), false),
            Ok(true)
        );
        assert_eq!(resolve_admin_ui_auth_mode(None, None, true), Ok(false));
        assert!(resolve_admin_ui_auth_mode(None, None, false).is_err());
        assert!(resolve_admin_ui_auth_mode(Some("admin"), None, true).is_err());
        assert!(resolve_admin_ui_auth_mode(None, Some("secret"), true).is_err());
    }

    // What: empty and placeholder tokens are rejected.
    // Why: a public placeholder lets anyone register.
    #[test]
    fn secondary_registration_token_rejects_empty_and_known_placeholders() {
        assert!(validate_secondary_registration_token("").is_err());
        for placeholder in [
            "CHANGE_ME_SECONDARY_REGISTRATION_TOKEN", // deploy/prod/.env
            "YOUR_SECONDARY_REGISTRATION_TOKEN_HERE",
            "changeme",
            "please-change-me-now",
            "lancache-default-secret",
            "<generate-a-secret>", // README.md's SECONDARY_REGISTRATION_TOKEN example
        ] {
            assert!(
                validate_secondary_registration_token(placeholder).is_err(),
                "expected placeholder {placeholder:?} to be rejected"
            );
        }
        // A real generated secret (openssl rand -hex 32 shape) must pass.
        assert!(
            validate_secondary_registration_token(
                "8f14e45fceea167a5a36dedd4bea2543f5a5d5a2b3f3b8c1e7d6c5b4a3f2e1d"
            )
            .is_ok()
        );
    }

    // A token that is neither empty nor a known placeholder, but too short
    // to meaningfully resist brute-forcing, must still be rejected.
    // `MIN_SECONDARY_REGISTRATION_TOKEN_LEN` is the exact boundary this
    // locks -- one character under it must fail, exactly at it must pass.
    #[test]
    fn secondary_registration_token_rejects_short_non_placeholder_values() {
        let too_short = "a".repeat(MIN_SECONDARY_REGISTRATION_TOKEN_LEN - 1);
        let err = validate_secondary_registration_token(&too_short).unwrap_err();
        assert!(err.contains("below the required minimum"));

        let exactly_min = "b".repeat(MIN_SECONDARY_REGISTRATION_TOKEN_LEN);
        assert!(validate_secondary_registration_token(&exactly_min).is_ok());
    }

    // The length floor must count characters, not bytes: a multi-byte UTF-8
    // string can have far more bytes than characters (8 four-byte emoji is
    // 32 bytes but only 8 characters). A byte-count check would silently
    // accept this short, low-entropy value; a character-count check
    // correctly rejects it.
    #[test]
    fn secondary_registration_token_length_floor_counts_characters_not_bytes() {
        let eight_emoji = "\u{1F600}".repeat(8);
        assert_eq!(
            eight_emoji.len(),
            32,
            "test fixture assumption: 8 four-byte emoji = 32 bytes"
        );
        assert_eq!(eight_emoji.chars().count(), 8);
        let err = validate_secondary_registration_token(&eight_emoji).unwrap_err();
        assert!(err.contains("below the required minimum"));

        // Exactly MIN_SECONDARY_REGISTRATION_TOKEN_LEN multi-byte characters
        // (4x the byte length of the ASCII equivalent) must still pass,
        // proving the floor is a real character-count boundary rather than
        // accidentally stricter for multi-byte input.
        let min_chars_emoji = "\u{1F600}".repeat(MIN_SECONDARY_REGISTRATION_TOKEN_LEN);
        assert!(validate_secondary_registration_token(&min_chars_emoji).is_ok());
    }

    // What: the shared-secret rule matches the "shared" column.
    // Why: ui and the dns/dhcp/nats readers must agree.
    // From: Issue #967 | PR #1858
    #[test]
    fn shared_secret_is_placeholder_matches_shared_parity_fixture() {
        assert_parity_column(1, config::shared_secret_is_placeholder);
    }

    // Covers the three states load_or_create_secondary_registration_token
    // must distinguish: a real operator-supplied value passes through
    // untouched without ever touching disk; an unset/empty value generates
    // and persists a fresh random hex32 token; and a later start with a
    // placeholder value reuses the already-persisted token rather than
    // generating a new one. That last case is the one that matters most --
    // rotating the token on every restart would invalidate every already
    // registered secondary's stored credentials.
    #[test]
    fn load_or_create_secondary_registration_token_generates_persists_and_preserves() {
        // A real operator-supplied value is returned unchanged and no file is
        // read or written (path deliberately does not exist).
        let real = "8f14e45fceea167a5a36dedd4bea2543f5a5d5a2b3f3b8c1e7d6c5b4a3f2e1d";
        assert_eq!(
            load_or_create_secondary_registration_token(
                real,
                "/nonexistent/lancache-ng-must-not-be-read.token"
            )
            .unwrap(),
            real
        );

        let dir = std::env::temp_dir().join(format!(
            "lancache-ng-secreg-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("secondary-registration.token");
        let path_str = path.to_str().unwrap();

        // An empty configured value generates a real hex32 token and persists it.
        let generated = load_or_create_secondary_registration_token("", path_str).unwrap();
        assert_eq!(generated.len(), 64, "expected a 32-byte hex token");
        assert!(!lancache_common::is_placeholder(&generated));

        // Idempotent: a later start with a placeholder value reuses the persisted
        // token (must never rotate), whichever placeholder form triggered it.
        let reused = load_or_create_secondary_registration_token(
            "YOUR_SECONDARY_REGISTRATION_TOKEN_HERE",
            path_str,
        )
        .unwrap();
        assert_eq!(generated, reused);

        std::fs::remove_dir_all(dir).unwrap();
    }

    // Zero would issue sessions that expire the instant they are created,
    // and an unbounded value (up to u64::MAX) risks overflow once a session's
    // expiry is computed as `now + ttl` (see session::issue_session_at's
    // checked_add). Pinning both the exact 1-year ceiling and the rejection
    // of pathologically large input keeps that arithmetic safe even if a
    // future change stops going through Duration::from_secs first.
    #[test]
    fn ui_session_ttl_rejects_zero_and_overflow_prone_values() {
        assert!(validate_ui_session_ttl_seconds(0).is_err());
        assert!(validate_ui_session_ttl_seconds(86_400).is_ok());
        assert!(validate_ui_session_ttl_seconds(MAX_UI_SESSION_TTL_SECONDS).is_ok());
        assert!(validate_ui_session_ttl_seconds(MAX_UI_SESSION_TTL_SECONDS + 1).is_err());
        assert!(validate_ui_session_ttl_seconds(u64::MAX).is_err());
    }

    // preflight_startup_config runs several independent validations via `?`,
    // so their order determines which single error message an operator with
    // *multiple* misconfigured values actually sees. This sets both the TTL
    // and the NATS credentials to invalid values at once and asserts the TTL
    // error wins -- pinning the current check order so a future reordering
    // doesn't silently swap which error surfaces first without anyone
    // noticing.
    #[test]
    fn startup_preflight_rejects_invalid_ttl_before_other_static_checks() {
        // `Config::from_env()` reads process-global env vars (CACHE_DIR,
        // CACHE_MAX_GB, and their legacy split-key fallbacks). Hold the same
        // lock config.rs's own env-mutating tests use so this test never
        // observes another thread's in-flight legacy values and hits
        // `resolve_cache_dir`/`resolve_cache_max_gb`'s fail-closed error.
        let _guard = config::env_test_lock().lock().unwrap();
        let mut cfg = config::Config::from_env().unwrap();
        cfg.ui_session_ttl_seconds = 0;
        cfg.nats_ui_user = "invalid user".to_string();
        cfg.nats_ui_password = Some("still-invalid".to_string());

        assert_eq!(
            preflight_startup_config(&cfg),
            Err("UI_SESSION_TTL_SECONDS must be greater than zero".to_string())
        );
    }

    // Tera validates function calls at template-parse time (see
    // load_templates), so a template referencing lancache_image_registry()
    // etc. would fail to load entirely if registration were missing, wired to
    // the wrong config field, or registered after templates were added --
    // this proves the four functions are actually registered and each
    // returns its own configured value, not a copy-pasted mix-up between
    // registry/prefix/channel/tag.
    #[test]
    fn lancache_image_template_functions_render_runtime_config() {
        let _guard = config::env_test_lock().lock().unwrap();

        unsafe {
            std::env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_CHANNEL", "nightly");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_TAG", "v0.2.0-test");
        }

        let cfg = config::Config::from_env().unwrap();
        let mut templates = Tera::default();
        register_lancache_image_template_functions(&mut templates, &cfg);
        templates
            .add_raw_template(
                "runtime.html",
                "{{ lancache_image_registry() }}/{{ lancache_image_prefix() }}:{{ lancache_image_tag() }} [{{ lancache_image_channel() }}]",
            )
            .unwrap();

        let rendered = templates
            .render("runtime.html", &tera::Context::new())
            .unwrap();
        assert_eq!(
            rendered,
            "registry.example.test:5000/mirror/lancache-ng:v0.2.0-test [nightly]"
        );

        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_REGISTRY");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_PREFIX");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_CHANNEL");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_TAG");
        }
    }

    // Regression test for #848: load_templates() parses the *real* on-disk
    // templates (unlike lancache_image_template_functions_render_runtime_config
    // above, which adds a throwaway inline template), so this both proves
    // logs.html still parses after the host-filter dropdown was added and
    // that the dropdown actually reflects a selected host and the full host
    // list passed in the render context.
    #[test]
    fn logs_html_renders_syslog_host_filter_dropdown_with_selection() {
        let _guard = config::env_test_lock().lock().unwrap();

        unsafe {
            std::env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_CHANNEL", "nightly");
        }
        unsafe {
            std::env::set_var("LANCACHE_IMAGE_TAG", "v0.2.0-test");
        }
        unsafe {
            std::env::set_var(
                "TEMPLATE_DIR",
                format!("{}/src/templates", env!("CARGO_MANIFEST_DIR")),
            );
        }

        let cfg = config::Config::from_env().unwrap();
        let templates = load_templates(&cfg);

        let mut ctx = tera::Context::new();
        ctx.insert("active_page", "logs");
        ctx.insert("syslog_mode", &true);
        ctx.insert("syslog_logs", &Vec::<syslog_client::SyslogEntry>::new());
        ctx.insert(
            "syslog_hosts",
            &vec!["dns-ssl".to_string(), "watchdog".to_string()],
        );
        ctx.insert("selected_host", &Some("watchdog".to_string()));
        ctx.insert("logs", &Vec::<nginx_client::LogEntry>::new());
        // What: base.html's beambar form now needs csrf_token too
        // Why: unlike logs_page(), this test builds ctx by hand
        // From: Issue #1437
        ctx.insert("csrf_token", "test-csrf-token");

        let rendered = templates.render("logs.html", &ctx).unwrap();
        assert!(
            rendered.contains(r#"<option value="watchdog" selected>watchdog</option>"#),
            "expected the watchdog <option> to carry `selected`, got:\n{rendered}"
        );
        assert!(
            rendered.contains(r#"<option value="dns-ssl" >dns-ssl</option>"#),
            "expected the non-selected dns-ssl <option> to be present without `selected`, got:\n{rendered}"
        );

        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_REGISTRY");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_PREFIX");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_CHANNEL");
        }
        unsafe {
            std::env::remove_var("LANCACHE_IMAGE_TAG");
        }
        unsafe {
            std::env::remove_var("TEMPLATE_DIR");
        }
    }

    // This crate has two similarly-named CSRF header helpers: main.rs's own
    // csrf_header_value reads the client-facing X-CSRF-Token header, while
    // session::csrf_header_value reads INTERNAL_CSRF_HEADER_NAME, the
    // separate internal header the basic_auth middleware injects with the
    // real session's CSRF token before a request reaches its handler. This
    // pins that the session-module helper reads back exactly that internal
    // header and not the client-facing one, guarding against the two being
    // mixed up.
    #[test]
    fn session_cookie_helper_matches_the_session_header() {
        let empty_headers = HeaderMap::new();
        assert!(session::csrf_header_value(&empty_headers).is_none());

        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::HeaderName::from_static(session::INTERNAL_CSRF_HEADER_NAME),
            HeaderValue::from_static("session-token-a"),
        );

        assert_eq!(
            session::csrf_header_value(&headers),
            Some("session-token-a")
        );
    }

    // ─── basic_auth full-chain integration tests ───
    //
    // The tests above exercise basic_auth's own leaf functions
    // (basic_auth_is_valid, forwarded_proto_is_https, ...) in isolation.
    // These four instead drive real axum::extract::Request values through
    // the actual Router + `from_fn_with_state(state, basic_auth)` layer via
    // tower::ServiceExt::oneshot, the same way a real HTTP request would
    // reach it -- so a bug in how the pieces are wired together (not just a
    // bug in one leaf function) would actually be caught.
    use tower::ServiceExt;

    // Builds a real AppState so the full middleware (which is hardwired to
    // `State<Arc<AppState>>`, not a trimmed-down test double) can run
    // unmodified. `docker`/`nats` are real client objects but never make a
    // network call in these tests: bollard's connect_with_http only builds
    // an HTTP client (no handshake at construction time), and async-nats's
    // `retry_on_initial_connect` makes `connect()` return immediately,
    // retrying the actual TCP handshake in a background task -- fine here
    // because basic_auth itself never touches state.docker or state.nats.
    async fn test_app_state(
        auth_user: Option<&str>,
        auth_password: Option<&str>,
        secret: [u8; 32],
        ttl: Duration,
    ) -> Arc<AppState> {
        // Scoped tightly around the synchronous env read only: clippy (and
        // real deadlock risk under multi-threaded tokio::test) both reject
        // holding a std::sync::MutexGuard across the .await points below.
        let mut cfg = {
            let _guard = config::env_test_lock().lock().unwrap();
            config::Config::from_env().unwrap()
        };
        cfg.auth_user = auth_user.map(str::to_string);
        cfg.auth_password = auth_password.map(str::to_string);

        let docker =
            Docker::connect_with_http("http://127.0.0.1:1", 120, bollard::API_DEFAULT_VERSION)
                .unwrap();
        let nats = async_nats::ConnectOptions::new()
            .retry_on_initial_connect()
            .connect("nats://127.0.0.1:14222")
            .await
            .unwrap();

        Arc::new(AppState {
            templates: Tera::default(),
            config: cfg,
            docker,
            http_client: reqwest::Client::new(),
            file_lock: std::sync::Mutex::new(()),
            netdata_alarms_lock: std::sync::Mutex::new(()),
            kea_config_lock: tokio::sync::Mutex::new(()),
            dhcp_probe_lock: tokio::sync::Mutex::new(()),
            nats,
            db: Mutex::new(Connection::open_in_memory().unwrap()),
            ui_session_secret: secret,
            ui_session_ttl: ttl,
            nats_issuer_public_key: String::new(),
            nats_callout_xkey_public_key: String::new(),
        })
    }

    // A single trivial route standing in for every real protected route --
    // what matters for these tests is only what basic_auth itself does
    // before the request ever reaches a handler, not any specific handler's
    // own behavior.
    fn test_protected_router(state: Arc<AppState>) -> Router {
        async fn dummy_ok() -> &'static str {
            "ok"
        }
        Router::new()
            .route("/protected", get(dummy_ok).post(dummy_ok))
            .layer(axum::middleware::from_fn_with_state(state, basic_auth))
    }

    // A mutating request with no CSRF token anywhere (no header, no form
    // field, no cookie at all) must be rejected outright -- this is the
    // baseline CSRF gate every mutating route relies on, exercised here
    // through the real middleware rather than just its `verify_csrf_token`
    // helper. Basic Auth is left unconfigured so this test isolates the
    // CSRF branch from the separate 401 gate already covered by
    // `basic_auth_rejects_wrong_credentials_and_accepts_correct_ones`.
    #[tokio::test]
    async fn basic_auth_middleware_rejects_mutating_request_without_csrf_token() {
        let secret = [0xAA; 32];
        let ttl = Duration::from_secs(300);
        let state = test_app_state(None, None, secret, ttl).await;
        let router = test_protected_router(state);

        let request = Request::builder()
            .method("POST")
            .uri("/protected")
            .header(
                axum::http::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(Body::from("some=data"))
            .unwrap();

        let response = router.oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    // A mutating request whose body exceeds MAX_CSRF_BODY_BYTES must be
    // rejected with 400 before the CSRF field is ever parsed out of it --
    // this is the fail-closed guard against buffering an unbounded body
    // into memory on every mutating request (axum::body::to_bytes's own
    // cap), not a CSRF-specific check, but it lives in the same code path
    // and was previously only reachable by inspection, not a real request.
    #[tokio::test]
    async fn basic_auth_middleware_rejects_oversized_body_on_mutating_request() {
        let secret = [0xBB; 32];
        let ttl = Duration::from_secs(300);
        let state = test_app_state(None, None, secret, ttl).await;
        let router = test_protected_router(state);

        let oversized = vec![b'a'; MAX_CSRF_BODY_BYTES + 1];
        let request = Request::builder()
            .method("POST")
            .uri("/protected")
            .body(Body::from(oversized))
            .unwrap();

        let response = router.oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    // The middleware accepts a submitted CSRF token from either of two
    // places (see basic_auth's `csrf_header_value(...).or_else(...
    // form_urlencoded...))`): the X-CSRF-Token header (used by this app's
    // own JSON `fetch()` calls, e.g. secondaries.html) or a `csrf_token`
    // form field (used by every plain HTML <form> submit in this app's
    // templates). Both must independently pass through the real request
    // pipeline, not just the leaf comparison function.
    #[tokio::test]
    async fn basic_auth_middleware_accepts_csrf_token_via_header_or_form_field() {
        let secret = [0xCC; 32];
        let ttl = Duration::from_secs(300);
        let state = test_app_state(None, None, secret, ttl).await;
        let session = session::issue_session(&secret, ttl);
        let cookie = format!("{}={}", session::SESSION_COOKIE_NAME, session.cookie_value);

        let router = test_protected_router(Arc::clone(&state));
        let header_request = Request::builder()
            .method("POST")
            .uri("/protected")
            .header(axum::http::header::COOKIE, cookie.clone())
            .header(CSRF_HEADER_NAME, session.csrf_token.clone())
            .body(Body::empty())
            .unwrap();
        let header_response = router.oneshot(header_request).await.unwrap();
        assert_eq!(header_response.status(), StatusCode::OK);

        let router = test_protected_router(state);
        let form_request = Request::builder()
            .method("POST")
            .uri("/protected")
            .header(axum::http::header::COOKIE, cookie)
            .header(
                axum::http::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(Body::from(format!("csrf_token={}", session.csrf_token)))
            .unwrap();
        let form_response = router.oneshot(form_request).await.unwrap();
        assert_eq!(form_response.status(), StatusCode::OK);
    }

    // The full chain, end to end: an unauthenticated request is rejected
    // (the Basic Auth gate runs unconditionally, even for a plain GET with
    // no CSRF involved at all); a first authenticated GET has no session
    // cookie yet, so the middleware issues one via Set-Cookie -- the same
    // thing a real browser's first page load does; and only a follow-up
    // mutating request presenting both correct Basic Auth *and* that real
    // session's own CSRF token reaches the downstream handler.
    #[tokio::test]
    async fn basic_auth_middleware_full_accept_path_with_basic_auth_and_csrf() {
        let secret = [0xDD; 32];
        let ttl = Duration::from_secs(300);
        let state = test_app_state(Some("admin"), Some("secret"), secret, ttl).await;
        let auth_header = format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode("admin:secret")
        );

        let router = test_protected_router(Arc::clone(&state));
        let unauthenticated = Request::builder()
            .method("GET")
            .uri("/protected")
            .body(Body::empty())
            .unwrap();
        let unauthenticated_response = router.oneshot(unauthenticated).await.unwrap();
        assert_eq!(unauthenticated_response.status(), StatusCode::UNAUTHORIZED);

        let router = test_protected_router(Arc::clone(&state));
        let first_get = Request::builder()
            .method("GET")
            .uri("/protected")
            .header(axum::http::header::AUTHORIZATION, auth_header.clone())
            .body(Body::empty())
            .unwrap();
        let first_response = router.oneshot(first_get).await.unwrap();
        assert_eq!(first_response.status(), StatusCode::OK);

        let set_cookie = first_response
            .headers()
            .get(axum::http::header::SET_COOKIE)
            .expect("a fresh session must set a cookie")
            .to_str()
            .unwrap()
            .to_string();
        // Set-Cookie carries attributes (Path=/, SameSite=..., Max-Age=...)
        // after the first `;` -- strip those down to the bare `name=value`
        // pair a request's own Cookie header uses.
        let cookie_pair = set_cookie.split(';').next().unwrap().to_string();
        let cookie_value = cookie_pair
            .strip_prefix(&format!("{}=", session::SESSION_COOKIE_NAME))
            .expect("Set-Cookie must carry the session cookie")
            .to_string();
        let issued_session =
            session::validate_session_cookie(&cookie_value, &secret, SystemTime::now())
                .expect("the issued cookie must itself validate");

        let router = test_protected_router(state);
        let accepted_post = Request::builder()
            .method("POST")
            .uri("/protected")
            .header(axum::http::header::AUTHORIZATION, auth_header)
            .header(axum::http::header::COOKIE, cookie_pair)
            .header(
                axum::http::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(Body::from(format!(
                "csrf_token={}",
                issued_session.csrf_token
            )))
            .unwrap();
        let accepted_response = router.oneshot(accepted_post).await.unwrap();
        assert_eq!(accepted_response.status(), StatusCode::OK);
    }
}
