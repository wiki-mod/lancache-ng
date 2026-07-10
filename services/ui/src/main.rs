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
mod nats_config;
mod nginx_client;
mod routes;
mod session;

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
}

const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;
const MAX_UI_SESSION_TTL_SECONDS: u64 = 365 * 24 * 60 * 60;

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

// Panics on any missing/malformed template rather than returning a Result:
// a broken template is a deploy-time defect, not a runtime condition to
// recover from, and failing at startup (before the listener binds) is far
// preferable to a page-specific 500 the first time a user visits that route.
fn load_templates(dir: &str) -> Tera {
    let mut t = Tera::default();
    t.autoescape_on(vec!["html"]);
    for name in TEMPLATE_NAMES {
        let path = format!("{}/{}", dir, name);
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
        let result = if cfg.nats_ui_user.is_empty() || cfg.nats_ui_password.is_empty() {
            async_nats::connect(&cfg.nats_url).await
        } else {
            async_nats::ConnectOptions::with_user_and_password(
                cfg.nats_ui_user.clone(),
                cfg.nats_ui_password.clone(),
            )
            .connect(&cfg.nats_url)
            .await
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

fn preflight_startup_config(cfg: &config::Config) -> Result<Duration, String> {
    validate_ui_session_ttl_seconds(cfg.ui_session_ttl_seconds)?;
    nats_config::validate_runtime_nats_credentials(cfg)?;
    Ok(Duration::from_secs(cfg.ui_session_ttl_seconds))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "lancache_ui=info,warn".parse().unwrap()),
        )
        .init();

    let cfg = match config::Config::from_env() {
        Ok(cfg) => cfg,
        Err(message) => {
            tracing::error!("{message}");
            std::process::exit(1);
        }
    };

    // SECONDARY_REGISTRATION_TOKEN must be non-empty; an empty token allows
    // unauthenticated registration (empty string matches empty string).
    if cfg.secondary_registration_token.is_empty() {
        tracing::error!(
            "SECONDARY_REGISTRATION_TOKEN is not set or empty — refusing to start. \
             Generate one with: openssl rand -hex 32"
        );
        std::process::exit(1);
    }

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

    let templates = load_templates(&cfg.template_dir);
    let docker = docker_client::connect_from_env()?;
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let nats = connect_nats_with_retry(&cfg).await;
    let ui_session_secret = load_or_create_session_secret()?;

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
    });

    // Write initial nats.conf with auth tokens and restart NATS so it picks up
    // the shared config without requiring Docker exec.
    if let Err(e) = routes::secondaries::reload_nats_conf(&state).await {
        tracing::warn!("Could not reload initial nats.conf: {}", e);
    }

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
        .route("/dhcp/static/add", post(routes::dhcp::add_reservation))
        .route(
            "/dhcp/static/remove",
            post(routes::dhcp::remove_reservation),
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
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
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
        cfg.nats_ui_password = "still-invalid".to_string();

        assert_eq!(
            preflight_startup_config(&cfg),
            Err("UI_SESSION_TTL_SECONDS must be greater than zero".to_string())
        );
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
