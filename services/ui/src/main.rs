mod config;
mod docker_client;
mod nginx_client;
mod routes;

use anyhow::Result;
use axum::{
    routing::{get, post},
    Router,
};
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
    "domains.html",
    "stats.html",
    "logs.html",
    "setup.html",
];

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
        .route("/domains", get(routes::domains::domains_page))
        .route("/domains/dns/add", post(routes::domains::add_dns))
        .route("/domains/dns/remove", post(routes::domains::remove_dns))
        .route("/domains/ssl/add", post(routes::domains::add_ssl))
        .route("/domains/ssl/remove", post(routes::domains::remove_ssl))
        .route("/stats", get(routes::stats::stats_page))
        .route("/logs", get(routes::logs::logs_page))
        .route("/setup", get(routes::setup::setup_page))
        .route("/api/metrics", get(routes::dashboard::metrics_api))
        .route("/api/netdata/*path", get(routes::netdata_proxy::proxy))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    tracing::info!("LanCache Admin UI läuft auf http://0.0.0.0:8080");
    axum::serve(listener, app).await?;
    Ok(())
}
