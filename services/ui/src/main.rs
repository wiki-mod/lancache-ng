mod config;
mod docker_client;
mod nginx_client;
mod routes;

use anyhow::Result;
use axum::{
    routing::{get, post},
    Router,
};
use base64::Engine as _;
use bollard::Docker;
use std::sync::Arc;
use tera::Tera;

pub struct AppState {
    pub templates: Tera,
    pub config: config::Config,
    pub docker: Docker,
    pub http_client: reqwest::Client,
    pub file_lock: std::sync::Mutex<()>,
}

const TEMPLATE_NAMES: &[&str] = &[
    "base.html",
    "dashboard.html",
    "dhcp.html",
    "domains.html",
    "stats.html",
    "logs.html",
    "setup.html",
];

async fn basic_auth(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let (user, pass) = match (&state.config.auth_user, &state.config.auth_password) {
        (Some(u), Some(p)) => (u.as_str(), p.as_str()),
        _ => return next.run(req).await,
    };

    let ok = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Basic "))
        .and_then(|enc| base64::engine::general_purpose::STANDARD.decode(enc).ok())
        .and_then(|dec| String::from_utf8(dec).ok())
        .and_then(|creds| {
            let mut it = creds.splitn(2, ':');
            Some(it.next()? == user && it.next()? == pass)
        })
        .unwrap_or(false);

    if ok {
        next.run(req).await
    } else {
        axum::http::Response::builder()
            .status(axum::http::StatusCode::UNAUTHORIZED)
            .header("WWW-Authenticate", r#"Basic realm="LanCache Admin""#)
            .body(axum::body::Body::from("Unauthorized"))
            .unwrap()
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

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "lancache_ui=info,warn".parse().unwrap()),
        )
        .init();

    let cfg = config::Config::from_env();
    let templates = load_templates(&cfg.template_dir);
    let docker = Docker::connect_with_socket_defaults()?;
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let state = Arc::new(AppState {
        templates,
        config: cfg,
        docker,
        http_client,
        file_lock: std::sync::Mutex::new(()),
    });

    let app = Router::new()
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
        .route("/domains/aaaa-filter", post(routes::domains::toggle_aaaa_filter))
        .route("/domains/lan/add", post(routes::domains::add_lan_record))
        .route("/domains/lan/remove", post(routes::domains::remove_lan_record))
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
        .route("/api/metrics", get(routes::dashboard::metrics_api))
        .route("/api/netdata/*path", get(routes::netdata_proxy::proxy))
        .layer(axum::middleware::from_fn_with_state(Arc::clone(&state), basic_auth))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    tracing::info!("LanCache Admin UI läuft auf http://0.0.0.0:8080");
    axum::serve(listener, app).await?;
    Ok(())
}
