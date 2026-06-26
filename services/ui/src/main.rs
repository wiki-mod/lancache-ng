#![deny(warnings)]

mod config;
mod docker_client;
mod nginx_client;
mod routes;

use anyhow::Result;
use axum::{
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use base64::Engine as _;
use bollard::Docker;
use rusqlite::Connection;
use std::sync::{Arc, Mutex};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tera::Tera;

pub struct AppState {
    pub templates: Tera,
    pub config: config::Config,
    pub docker: Docker,
    pub http_client: reqwest::Client,
    pub file_lock: std::sync::Mutex<()>,
    pub nats: async_nats::Client,
    pub db: Mutex<Connection>,
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
            let mut it = creds.splitn(2, ':');
            let provided_user = it.next()?;
            let provided_pass = it.next()?;
            // Hash both sides to fixed-size 32-byte digests before comparing.
            // subtle's ct_eq on raw slices aborts early on length mismatch,
            // leaking credential length. Digests are always 32 bytes regardless
            // of input length, eliminating that timing side-channel.
            let user_match = Sha256::digest(provided_user.as_bytes())
                .ct_eq(&Sha256::digest(user.as_bytes()));
            let pass_match = Sha256::digest(provided_pass.as_bytes())
                .ct_eq(&Sha256::digest(pass.as_bytes()));
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
        let result = if cfg.nats_local_token.is_empty() {
            async_nats::connect(&cfg.nats_url).await
        } else {
            async_nats::ConnectOptions::new()
                .token(cfg.nats_local_token.clone())
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

    // Auth is optional: only activate if both vars are non-empty.
    let auth_enabled = cfg.auth_user.as_deref().map(|s| !s.is_empty()).unwrap_or(false)
        && cfg.auth_password.as_deref().map(|s| !s.is_empty()).unwrap_or(false);
    if !auth_enabled {
        tracing::warn!(
            "UI_AUTH_USER or UI_AUTH_PASSWORD is not set — starting without authentication"
        );
    }

    let templates = load_templates(&cfg.template_dir);
    let docker = Docker::connect_with_socket_defaults()?;
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let nats = connect_nats_with_retry(&cfg).await;

    let db = {
        let conn = Connection::open("/data/lancache-ui.db")
            .expect("Cannot open UI database");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS secondaries (
                name TEXT PRIMARY KEY,
                nats_token TEXT NOT NULL,
                consumer_name TEXT NOT NULL UNIQUE,
                registered_at INTEGER NOT NULL,
                last_seen INTEGER
            );"
        ).expect("Cannot init database schema");
        Mutex::new(conn)
    };

    let state = Arc::new(AppState {
        templates,
        config: cfg,
        docker,
        http_client,
        file_lock: std::sync::Mutex::new(()),
        nats,
        db,
    });

    // Write initial nats.conf with auth tokens and reload NATS
    if let Err(e) = routes::secondaries::update_nats_conf(&state).await {
        tracing::warn!("Could not write initial nats.conf: {}", e);
    } else {
        let _ = docker_client::exec_in_container(
            &state.docker,
            &state.config.nats_service,
            vec!["kill", "-HUP", "1"],
        ).await;
    }

    // Routes that are always public (protected by their own token).
    let public_routes = Router::new()
        .route("/api/secondary/register", post(routes::secondaries::register_secondary));

    // Routes that are protected by Basic Auth when auth is enabled.
    let protected_routes = Router::new()
        .route("/", get(routes::dashboard::dashboard))
        .route("/dhcp", get(routes::dhcp::dhcp_page))
        .route("/dhcp/subnet/add", post(routes::dhcp::add_subnet))
        .route("/dhcp/subnet/update", post(routes::dhcp::update_subnet))
        .route("/dhcp/subnet/remove", post(routes::dhcp::remove_subnet))
        .route("/dhcp/static/add", post(routes::dhcp::add_reservation))
        .route("/dhcp/static/remove", post(routes::dhcp::remove_reservation))
        .route("/api/dhcp/check", get(routes::dhcp::check_dhcp_conflict))
        .route("/domains", get(routes::domains::domains_page))
        .route("/domains/dns/add", post(routes::domains::add_dns))
        .route("/domains/dns/remove", post(routes::domains::remove_dns))
        .route("/domains/ssl/add", post(routes::domains::add_ssl))
        .route("/domains/ssl/remove", post(routes::domains::remove_ssl))
        .route("/domains/lan/add", post(routes::domains::add_lan_record))
        .route("/domains/lan/remove", post(routes::domains::remove_lan_record))
        .route("/domains/aaaa-filter", post(routes::domains::toggle_aaaa_filter))
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
        .route("/api/metrics", get(routes::dashboard::metrics_api))
        .route("/api/netdata/{*path}", get(routes::netdata_proxy::proxy))
        .route("/secondaries", get(routes::secondaries::secondaries_page))
        .route("/api/secondary/{name}", axum::routing::delete(routes::secondaries::remove_secondary))
        .route("/api/secondary/{name}/rotate-token", post(routes::secondaries::rotate_token));

    let protected_routes = if auth_enabled {
        protected_routes
            .layer(axum::middleware::from_fn_with_state(Arc::clone(&state), basic_auth))
    } else {
        protected_routes
    };

    let app = Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    tracing::info!("LanCache Admin UI running on http://0.0.0.0:8080");
    axum::serve(listener, app).await?;
    Ok(())
}
