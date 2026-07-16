//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI service entry point. Wires up the axum HTTP server, shared
//! `AppState` (Docker client, NATS connection, SQLite handle, Tera templates),
//! and the full route table: dashboard, DHCP subnet/reservation management,
//! DNS/SSL/LAN domain records, stats, logs, the first-run setup wizard, a
//! Netdata metrics proxy, and secondary-node management. Also implements this
//! service's own per-session CSRF protection, HTTP Basic auth, and security-header
//! middleware rather than pulling in an external auth/CSRF crate.
//!
//! See `routes/` for the individual page/API handlers this file wires
//! together, and `config.rs` for how runtime settings are loaded.
#![deny(warnings)]

mod config;
mod docker_client;
mod kea_snapshots;
mod nats_auth_callout;
mod nats_config;
mod nginx_client;
mod routes;
mod session;
mod syslog_client;

use anyhow::Result;
use axum::{
    body::{to_bytes, Body},
    extract::Request,
    http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use base64::Engine as _;
use bollard::Docker;
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
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
    pub kea_config_lock: tokio::sync::Mutex<()>,
    pub dhcp_probe_lock: tokio::sync::Mutex<()>,
    pub nats: async_nats::Client,
    pub db: Mutex<Connection>,
    pub ui_session_secret: [u8; 32],
    pub ui_session_ttl: Duration,
    // The auth-callout issuer account's public NKey, rendered into nats.conf's
    // `auth_callout { issuer: ... }` field (see nats_auth_callout.rs). The
    // matching private seed never leaves the loaded `KeyPair` the callout
    // responder task holds.
    pub nats_issuer_public_key: String,
}

const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;
const MAX_UI_SESSION_TTL_SECONDS: u64 = 365 * 24 * 60 * 60;
const SECONDARY_REGISTRATION_TOKEN_FILE: &str = "/data/lancache-secondary-registration.token";

// Pattern-matches every checked-in placeholder form for SECONDARY_REGISTRATION_TOKEN,
// not just deploy/prod/.env's CHANGE_ME_SECONDARY_REGISTRATION_TOKEN default. An
// exact-literal list previously missed deploy/quickstart/.env's distinct
// YOUR_SECONDARY_REGISTRATION_TOKEN_HERE default, which manual quickstart deploys
// that skip setup.sh ship untouched -- letting anyone who reads this public repo
// register a secondary against it (flagged in review on PR #743). The first
// five checks mirror setup.sh's own secret_value_is_placeholder pattern set
// case-for-case so both checks stay in sync; the trailing `<...>` check is an
// addition beyond that set, added because README.md's own
// `SECONDARY_REGISTRATION_TOKEN=<generate-a-secret>` code-block example (which
// setup.sh's detector does NOT actually recognize, despite README prose
// claiming otherwise -- a pre-existing doc/script inconsistency out of scope
// here) is itself pasteable verbatim by a manual deployer. A real hex/base64
// secret can never match any of these patterns by chance.
fn secondary_registration_token_is_placeholder(token: &str) -> bool {
    token.is_empty()
        || token.starts_with("CHANGE_ME_")
        || (token.starts_with("YOUR_") && token.ends_with("_HERE"))
        || token.starts_with("changeme")
        || token.contains("change-me")
        || (token.starts_with("lancache-") && token.ends_with("-secret"))
        || (token.starts_with('<') && token.ends_with('>'))
}

// Persists the CSRF/session-signing secret across restarts so existing
// sessions don't get invalidated on every container recreate. `create_new`
// makes the write atomic and exclusive (no lost-update race if two processes
// start concurrently), and 0o600 keeps the raw key readable only by the
// container's own user.
fn load_or_create_session_secret() -> Result<[u8; 32]> {
    const SESSION_SECRET_FILE: &str = "/data/lancache-ui-session.secret";

    match fs::read_to_string(SESSION_SECRET_FILE) {
        Ok(contents) => {
            let secret = hex::decode(contents.trim())?;
            if secret.len() != 32 {
                anyhow::bail!(
                    "Session secret at {} must contain exactly 32 bytes encoded as hex",
                    SESSION_SECRET_FILE
                );
            }
            let mut bytes = [0u8; 32];
            bytes.copy_from_slice(&secret);
            Ok(bytes)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let secret: [u8; 32] = rand::random();
            let encoded = hex::encode(secret);
            let mut open_options = OpenOptions::new();
            open_options.create_new(true).write(true);
            #[cfg(unix)]
            open_options.mode(0o600);
            let mut file = open_options.open(SESSION_SECRET_FILE)?;
            file.write_all(encoded.as_bytes())?;
            file.sync_all()?;
            Ok(secret)
        }
        Err(err) => Err(err.into()),
    }
}

// Resolves the effective SECONDARY_REGISTRATION_TOKEN, generating and persisting
// a strong random one when the configured value is missing or a checked-in
// placeholder. setup.sh always generates a real hex32 token
// (`get_or_generate_secret ... hex32`), but the compose header's documented
// manual path ("Or manually: Edit .env ... docker compose up -d") ships either
// an empty default (deploy/quickstart compose's `${SECONDARY_REGISTRATION_TOKEN:-}`)
// or a public placeholder (deploy/quickstart/.env's YOUR_..._HERE,
// deploy/prod/.env's CHANGE_ME_*, deploy/dev compose's lancache-reg-dev-secret).
// Those all previously boot-looped the UI. Generating the same kind of secret
// setup.sh would -- persisted next to the other /data secrets so it never
// rotates across restarts (a rotating token would break an already-registered
// secondary) -- keeps the security invariant intact (registration still needs
// an unguessable secret) while removing both the crash and the guessable public
// default. An operator-supplied real value always wins and is preserved. `path`
// is a parameter so the create branch is unit-testable.
fn load_or_create_secondary_registration_token(
    configured: &str,
    path: &str,
) -> Result<String, String> {
    if !secondary_registration_token_is_placeholder(configured) {
        return Ok(configured.to_string());
    }
    match fs::read_to_string(path) {
        Ok(contents) => {
            let existing = contents.trim();
            if secondary_registration_token_is_placeholder(existing) {
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
            let mut open_options = OpenOptions::new();
            open_options.create_new(true).write(true);
            #[cfg(unix)]
            open_options.mode(0o600);
            let mut file = open_options.open(path).map_err(|e| {
                format!("failed to create secondary registration token file at {path}: {e}")
            })?;
            file.write_all(token.as_bytes()).map_err(|e| {
                format!("failed to write secondary registration token file at {path}: {e}")
            })?;
            file.sync_all().map_err(|e| {
                format!("failed to sync secondary registration token file at {path}: {e}")
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
                delay = std::cmp::min(delay * 2, max_delay);
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

// SECONDARY_REGISTRATION_TOKEN gates the one route
// (`POST /api/secondary/register`) that lets a new secondary DNS node join
// this primary -- see routes/secondaries.rs's own empty-token and
// constant-time comparison checks, which enforce the same invariant again on
// every request as defense in depth. The invariant this guards:
// - an empty token was the original vulnerability (flagged on PR #195):
//   an unset configured token compared equal to an unset/empty request
//   token, so any client could register.
// - a known placeholder is the same problem restated: its value is public,
//   readable straight out of this repository's checked-in deploy/prod/.env
//   and deploy/quickstart/.env defaults.
//
// setup.sh already generates a real SECONDARY_REGISTRATION_TOKEN
// unconditionally for every install (`get_or_generate_secret ... hex32`, same
// ensure_secret_env_key pipeline as PDNS_API_KEY/DDNS_TSIG_KEY). The documented
// manual compose path does not run setup.sh, so main() resolves the token
// through load_or_create_secondary_registration_token first: an operator's real
// value is kept, otherwise a persistent random one is generated -- meaning the
// token reaching this function is already guaranteed real on every path. This
// check therefore stays as a defense-in-depth assertion on the *resolved* value
// (a resolution bug that ever yielded an empty/placeholder token must still fail
// closed rather than start in a silently insecure state, issue #659), not as
// the primary boot gate it once was.
fn validate_secondary_registration_token(token: &str) -> Result<(), String> {
    if token.is_empty() {
        return Err(
            "SECONDARY_REGISTRATION_TOKEN is not set or empty — refusing to start. \
             Generate one with: openssl rand -hex 32"
                .to_string(),
        );
    }
    if secondary_registration_token_is_placeholder(token) {
        return Err(format!(
            "SECONDARY_REGISTRATION_TOKEN is still set to a default placeholder \
             ('{token}') — refusing to start. Generate a real secret with: \
             openssl rand -hex 32"
        ));
    }
    Ok(())
}

fn preflight_startup_config(cfg: &config::Config) -> Result<Duration, String> {
    validate_ui_session_ttl_seconds(cfg.ui_session_ttl_seconds)?;
    nats_config::validate_runtime_nats_credentials(cfg)?;
    Ok(Duration::from_secs(cfg.ui_session_ttl_seconds))
}

// Central logging pipeline (#633): mirrors the existing stdout tracing layer
// with a second layer that appends plain-text events to UI_LOG_FILE, so
// fluent-bit can tail it the same way it already tails nginx's access.log
// (see docs/architecture-ng.md's logging matrix). Runs before config::Config
// is loaded (tracing must exist first, since Config::from_env() failures are
// themselves reported via tracing::error!), so the log path is read directly
// from the environment here rather than through Config. Opening the file is
// best-effort: installs that never mount the shared log volume (i.e. never
// opt into the `logging` compose profile) must still start and log to
// stdout only -- a missing/unwritable log path is never a hard failure.
fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "lancache_ui=info,warn".parse().unwrap());
    let stdout_layer = tracing_subscriber::fmt::layer();

    let ui_log_file =
        std::env::var("UI_LOG_FILE").unwrap_or_else(|_| "/var/log/lancache-ui/ui.log".to_string());
    let file_layer = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ui_log_file)
        .ok()
        .map(|file| {
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

#[tokio::main]
async fn main() -> Result<()> {
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

    let nats = connect_nats_with_retry(&cfg).await;
    let ui_session_secret = load_or_create_session_secret()?;

    // Resolve the effective secondary-registration token alongside the other
    // durable /data secrets: a real operator value is preserved, otherwise a
    // persistent random one is generated so the documented manual compose path
    // starts securely instead of crash-looping (see
    // load_or_create_secondary_registration_token). validate_* then asserts the
    // resolved value is real as defense in depth.
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

    // Loaded before the DB/state so its public key can be baked into the
    // initial nats.conf write below, and its private seed handed to the
    // auth-callout responder task once state exists (see nats_auth_callout.rs).
    // NATS_ISSUER_SEED (a literal seed value) takes precedence over the
    // file-based path when set -- see config.rs's nats_issuer_seed docs for
    // why (deterministic validation harnesses with no persistent /data).
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
        kea_config_lock: tokio::sync::Mutex::new(()),
        dhcp_probe_lock: tokio::sync::Mutex::new(()),
        nats,
        db,
        ui_session_secret,
        ui_session_ttl,
        nats_issuer_public_key,
    });

    // Write initial nats.conf with auth tokens and restart NATS so it picks up
    // the shared config without requiring Docker exec.
    if let Err(e) = routes::secondaries::reload_nats_conf(&state).await {
        tracing::warn!("Could not reload initial nats.conf: {}", e);
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
    ));

    // Routes that are always public (protected by their own token).
    let public_routes = Router::new()
        .route("/health", get(health))
        .route(
            "/api/secondary/register",
            post(routes::secondaries::register_secondary),
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
        .route("/dhcp/proxy", post(routes::dhcp::update_dhcp_proxy))
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
        .route("/api/dhcp/check", get(routes::dhcp::check_dhcp_conflict))
        .route("/domains", get(routes::domains::domains_page))
        .route("/domains/dns/add", post(routes::domains::add_dns))
        .route("/domains/dns/remove", post(routes::domains::remove_dns))
        .route("/domains/lan/add", post(routes::domains::add_lan_record))
        .route(
            "/domains/lan/remove",
            post(routes::domains::remove_lan_record),
        )
        .route(
            "/domains/aaaa-filter",
            post(routes::domains::toggle_aaaa_filter),
        )
        .route(
            "/domains/zones/rollback",
            post(routes::dns_snapshots::rollback_zone_snapshot),
        )
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
        .route("/setup/update", post(routes::setup::update_stack_settings))
        .route("/api/metrics", get(routes::dashboard::metrics_api))
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

    #[test]
    fn csp_keeps_scripts_self_hosted_without_external_cdn_allowances() {
        assert!(ADMIN_UI_CSP.contains("script-src 'self' 'unsafe-inline'"));
        assert!(!ADMIN_UI_CSP.contains("cdn.tailwindcss.com"));
        assert!(!ADMIN_UI_CSP.contains("cdn.jsdelivr.net"));
        assert!(!ADMIN_UI_CSP.contains("'unsafe-eval'"));
    }

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

    #[test]
    fn secondary_registration_token_rejects_empty_and_known_placeholders() {
        assert!(validate_secondary_registration_token("").is_err());
        // Every placeholder form actually checked into the repo's deploy/*/.env
        // templates must be rejected, not just deploy/prod/.env's literal.
        for placeholder in [
            "CHANGE_ME_SECONDARY_REGISTRATION_TOKEN", // deploy/prod/.env
            "YOUR_SECONDARY_REGISTRATION_TOKEN_HERE", // deploy/quickstart/.env
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
        assert!(validate_secondary_registration_token(
            "8f14e45fceea167a5a36dedd4bea2543f5a5d5a2b3f3b8c1e7d6c5b4a3f2e1d"
        )
        .is_ok());
    }

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
        assert!(!secondary_registration_token_is_placeholder(&generated));

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

    #[test]
    fn ui_session_ttl_rejects_zero_and_overflow_prone_values() {
        assert!(validate_ui_session_ttl_seconds(0).is_err());
        assert!(validate_ui_session_ttl_seconds(86_400).is_ok());
        assert!(validate_ui_session_ttl_seconds(MAX_UI_SESSION_TTL_SECONDS).is_ok());
        assert!(validate_ui_session_ttl_seconds(MAX_UI_SESSION_TTL_SECONDS + 1).is_err());
        assert!(validate_ui_session_ttl_seconds(u64::MAX).is_err());
    }

    #[test]
    fn startup_preflight_rejects_invalid_ttl_before_other_static_checks() {
        // `Config::from_env()` reads process-global env vars (CACHE_DIR,
        // CACHE_MAX_GB, and their legacy split-key fallbacks). Hold the same
        // lock config.rs's own env-mutating tests use so this test never
        // observes another thread's in-flight legacy values and hits
        // `resolve_cache_dir`/`resolve_cache_max_gb`'s fail-closed panic.
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

    #[test]
    fn lancache_image_template_functions_render_runtime_config() {
        let _guard = config::env_test_lock().lock().unwrap();

        std::env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        std::env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        std::env::set_var("LANCACHE_IMAGE_CHANNEL", "edge");
        std::env::set_var("LANCACHE_IMAGE_TAG", "v0.2.0-test");

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
            "registry.example.test:5000/mirror/lancache-ng:v0.2.0-test [edge]"
        );

        std::env::remove_var("LANCACHE_IMAGE_REGISTRY");
        std::env::remove_var("LANCACHE_IMAGE_PREFIX");
        std::env::remove_var("LANCACHE_IMAGE_CHANNEL");
        std::env::remove_var("LANCACHE_IMAGE_TAG");
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

        std::env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        std::env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        std::env::set_var("LANCACHE_IMAGE_CHANNEL", "edge");
        std::env::set_var("LANCACHE_IMAGE_TAG", "v0.2.0-test");
        std::env::set_var(
            "TEMPLATE_DIR",
            format!("{}/src/templates", env!("CARGO_MANIFEST_DIR")),
        );

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

        let rendered = templates.render("logs.html", &ctx).unwrap();
        assert!(
            rendered.contains(r#"<option value="watchdog" selected>watchdog</option>"#),
            "expected the watchdog <option> to carry `selected`, got:\n{rendered}"
        );
        assert!(
            rendered.contains(r#"<option value="dns-ssl" >dns-ssl</option>"#),
            "expected the non-selected dns-ssl <option> to be present without `selected`, got:\n{rendered}"
        );

        std::env::remove_var("LANCACHE_IMAGE_REGISTRY");
        std::env::remove_var("LANCACHE_IMAGE_PREFIX");
        std::env::remove_var("LANCACHE_IMAGE_CHANNEL");
        std::env::remove_var("LANCACHE_IMAGE_TAG");
        std::env::remove_var("TEMPLATE_DIR");
    }

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
}
