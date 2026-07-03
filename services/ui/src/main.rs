//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI service entry point. Wires up the axum HTTP server, shared
//! `AppState` (Docker client, NATS connection, SQLite handle, Tera templates),
//! and the full route table: dashboard, DHCP subnet/reservation management,
//! DNS/SSL/LAN domain records, stats, logs, the first-run setup wizard, a
//! Netdata metrics proxy, and secondary-node management. Also implements this
//! service's own CSRF protection, HTTP Basic auth, and security-header
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

use anyhow::Result;
use axum::{
    body::{to_bytes, Body},
    extract::Request,
    http::{header, HeaderMap, HeaderName, HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use base64::Engine as _;
use bollard::Docker;
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use subtle::ConstantTimeEq;
use tera::Tera;

pub struct AppState {
    pub templates: Tera,
    pub config: config::Config,
    pub docker: Docker,
    pub http_client: reqwest::Client,
    pub file_lock: std::sync::Mutex<()>,
    pub kea_config_lock: tokio::sync::Mutex<()>,
    pub nats: async_nats::Client,
    pub db: Mutex<Connection>,
    pub csrf_token: String,
}

const CSRF_COOKIE_NAME: &str = "lancache_csrf";
const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;

fn generate_csrf_token() -> String {
    let bytes: [u8; 32] = rand::random();
    hex::encode(bytes)
}

fn is_mutating_method(method: &Method) -> bool {
    matches!(
        *method,
        Method::POST | Method::PUT | Method::PATCH | Method::DELETE
    )
}

fn csrf_cookie_value(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|cookie| cookie.strip_prefix("lancache_csrf="))
}

fn csrf_header_value(headers: &HeaderMap) -> Option<&str> {
    headers.get(CSRF_HEADER_NAME)?.to_str().ok()
}

fn set_csrf_cookie(response: &mut axum::response::Response, token: &str) {
    let cookie = format!(
        "{}={}; Path=/; SameSite=Strict; HttpOnly",
        CSRF_COOKIE_NAME, token
    );

    match cookie.parse() {
        Ok(cookie) => {
            response.headers_mut().insert(header::SET_COOKIE, cookie);
        }
        Err(err) => {
            tracing::error!(error = %err, "failed to build csrf cookie header");
        }
    }
}

async fn csrf_protect(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    req: Request<Body>,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let exempt_secondary_registration = method == Method::POST && path == "/api/secondary/register";

    if !is_mutating_method(&method) || exempt_secondary_registration {
        let mut response = next.run(req).await;
        set_csrf_cookie(&mut response, &state.csrf_token);
        return response;
    }

    let cookie_token = csrf_cookie_value(req.headers()).map(str::to_owned);
    let header_token = csrf_header_value(req.headers()).map(str::to_owned);

    let (parts, body) = req.into_parts();
    let body_bytes = match to_bytes(body, MAX_CSRF_BODY_BYTES).await {
        Ok(body_bytes) => body_bytes,
        Err(err) => {
            tracing::warn!(error = %err, "failed to read request body for csrf validation");
            return StatusCode::BAD_REQUEST.into_response();
        }
    };

    let form_token = if header_token.is_none() {
        form_urlencoded::parse(&body_bytes)
            .find_map(|(key, value)| (key == CSRF_FORM_FIELD).then(|| value.into_owned()))
    } else {
        None
    };

    let submitted_token = header_token.or(form_token);
    let valid = cookie_token.as_deref() == Some(state.csrf_token.as_str())
        && submitted_token.as_deref() == Some(state.csrf_token.as_str());

    if !valid {
        return StatusCode::FORBIDDEN.into_response();
    }

    let mut response = next
        .run(Request::from_parts(parts, Body::from(body_bytes)))
        .await;
    set_csrf_cookie(&mut response, &state.csrf_token);
    response
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

async fn basic_auth(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let user = state
        .config
        .auth_user
        .as_deref()
        .expect("UI_AUTH_USER validated at startup");
    let pass = state
        .config
        .auth_password
        .as_deref()
        .expect("UI_AUTH_PASSWORD validated at startup");

    let ok = req
        .headers()
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
        .unwrap_or(false);

    if ok {
        next.run(req).await
    } else {
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
}

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

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "lancache_ui=info,warn".parse().unwrap()),
        )
        .init();

    let cfg = config::Config::from_env();

    // SECONDARY_REGISTRATION_TOKEN must be non-empty; an empty token allows
    // unauthenticated registration (empty string matches empty string).
    if cfg.secondary_registration_token.is_empty() {
        tracing::error!(
            "SECONDARY_REGISTRATION_TOKEN is not set or empty — refusing to start. \
             Generate one with: openssl rand -hex 32"
        );
        std::process::exit(1);
    }

    // Validate before the retry loop so bad env overrides fail closed instead
    // of leaving the UI waiting for a NATS container with an invalid config.
    if let Err(message) = nats_config::validate_runtime_nats_credentials(&cfg) {
        tracing::error!("{message}");
        std::process::exit(1);
    }

    let auth_user = cfg.auth_user.as_deref().filter(|value| !value.is_empty());
    let auth_password = cfg
        .auth_password
        .as_deref()
        .filter(|value| !value.is_empty());

    let auth_enabled =
        match resolve_admin_ui_auth_mode(auth_user, auth_password, cfg.allow_insecure_ui) {
            Ok(enabled) => {
                if !enabled {
                    tracing::warn!(
                        "ALLOW_INSECURE_UI=true — starting Admin-UI without authentication"
                    );
                }
                enabled
            }
            Err(message) => {
                tracing::error!("{message}");
                std::process::exit(1);
            }
        };

    let templates = load_templates(&cfg.template_dir);
    let docker = docker_client::connect_from_env()?;
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let nats = connect_nats_with_retry(&cfg).await;

    let db = {
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
        nats,
        db,
        csrf_token: generate_csrf_token(),
    });

    // Write initial nats.conf with auth tokens and reload NATS
    if let Err(e) = routes::secondaries::update_nats_conf(&state).await {
        tracing::warn!("Could not write initial nats.conf: {}", e);
    } else {
        let _ = docker_client::exec_in_container(
            &state.docker,
            &state.config.nats_service,
            vec!["kill", "-HUP", "1"],
        )
        .await;
    }

    // Routes that are always public (protected by their own token).
    let public_routes = Router::new().route(
        "/api/secondary/register",
        post(routes::secondaries::register_secondary),
    );

    // Routes that are protected by Basic Auth when auth is enabled.
    let protected_routes = Router::new()
        .route("/", get(routes::dashboard::dashboard))
        .route("/dhcp", get(routes::dhcp::dhcp_page))
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
        .route("/domains/ssl/add", post(routes::domains::add_ssl))
        .route("/domains/ssl/remove", post(routes::domains::remove_ssl))
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
            csrf_protect,
        ));

    let protected_routes = if auth_enabled {
        protected_routes.layer(axum::middleware::from_fn_with_state(
            Arc::clone(&state),
            basic_auth,
        ))
    } else {
        protected_routes
    };

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
}
