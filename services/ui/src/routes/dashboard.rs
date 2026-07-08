//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Main dashboard route displaying cache statistics and connection metrics.

use crate::{config::DhcpMode, nginx_client, AppState};
use axum::extract::State;
use axum::response::{Html, Json};
use serde_json::json;
use std::sync::Arc;
use tera::Context;

pub async fn dashboard(State(state): State<Arc<AppState>>) -> Html<String> {
    let cfg = &state.config;

    // PROXY_STANDARD_URL and PROXY_SSL_URL default to the same value and
    // only diverge when an operator explicitly runs standard-mode and
    // ssl-mode as two separate proxy services with different stub_status
    // endpoints (see CLAUDE.md's "Two-Mode / Two-IP Architecture"). When
    // they're equal, the second HTTP call would just re-fetch identical
    // stats from the same nginx, so it's skipped and the first result is
    // reused instead.
    let standard_status =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url).await;
    let ssl_status = if !cfg.ssl_enabled {
        None
    } else if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
    };

    // Each of these three stats sources does blocking I/O (`du`, reading
    // full log files) — run in spawn_blocking so a slow disk doesn't stall
    // the async runtime's worker threads for other in-flight requests.
    let cache_used_gb = tokio::task::spawn_blocking({
        let d = cfg.cache_dir.clone();
        move || nginx_client::get_cache_size_gb(&d)
    })
    .await
    .unwrap_or(0.0);
    let log_stats = tokio::task::spawn_blocking({
        let sl = cfg.standard_log.clone();
        let xl = cfg.ssl_log.clone();
        move || nginx_client::get_log_stats(&sl, &xl)
    })
    .await
    .unwrap_or_default();

    let recent_logs = tokio::task::spawn_blocking({
        let path = if cfg.standard_log == cfg.ssl_log {
            cfg.standard_log.clone()
        } else {
            cfg.ssl_log.clone()
        };
        move || nginx_client::parse_log_tail(&path, 10)
    })
    .await
    .unwrap_or_default();

    let cache_pct = cache_usage_pct(cache_used_gb, cfg.cache_max_gb);

    let mut ctx = Context::new();
    ctx.insert("ssl_enabled", &cfg.ssl_enabled);
    let dhcp_mode = cfg.effective_dhcp_mode();
    let has_kea = matches!(dhcp_mode, DhcpMode::Kea);
    ctx.insert("dhcp_mode", &dhcp_mode.as_str());
    ctx.insert("dhcp_mode_has_kea", &has_kea);
    ctx.insert("standard_status", &standard_status);
    ctx.insert("ssl_status", &ssl_status);
    ctx.insert("cache_dir", &cfg.cache_dir);
    ctx.insert("cache_used_gb", &format!("{:.1}", cache_used_gb));
    ctx.insert("cache_max_gb", &cfg.cache_max_gb);
    ctx.insert("cache_pct", &cache_pct);
    ctx.insert("log_stats", &log_stats);
    ctx.insert("recent_logs", &recent_logs);
    ctx.insert("active_page", "dashboard");

    crate::routes::render(
        &state.templates,
        "dashboard.html",
        &ctx,
        state.config.dev_mode,
    )
}

fn cache_usage_pct(used_gb: f64, max_gb: f64) -> u64 {
    if max_gb <= 0.0 {
        0
    } else {
        ((used_gb / max_gb) * 100.0).min(100.0) as u64
    }
}

// JSON counterpart to `dashboard()`'s stub_status section only (registered
// at GET /api/metrics in main.rs). Deliberately omits the cache-size and
// log-parsing work above, which is the expensive part of `dashboard()` —
// intended for cheap polling of just the connection metrics, though nothing
// in this codebase currently calls this endpoint from the frontend.
pub async fn metrics_api(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let cfg = &state.config;
    let standard_status =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url).await;
    let ssl_status = if !cfg.ssl_enabled {
        None
    } else if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
    };
    Json(json!({
        "standard": standard_status,
        "ssl_enabled": cfg.ssl_enabled,
        "ssl": ssl_status,
    }))
}
