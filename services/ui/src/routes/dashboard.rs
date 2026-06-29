use crate::{nginx_client, AppState};
use axum::extract::State;
use axum::response::{Html, Json};
use serde_json::json;
use std::sync::Arc;
use tera::Context;

pub async fn dashboard(State(state): State<Arc<AppState>>) -> Html<String> {
    let cfg = &state.config;

    let standard_status =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url).await;
    let ssl_status = if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
    };

    let standard_used_gb = tokio::task::spawn_blocking({
        let d = cfg.standard_cache_dir.clone();
        move || nginx_client::get_cache_size_gb(&d)
    })
    .await
    .unwrap_or(0.0);
    let ssl_used_gb = if cfg.standard_cache_dir == cfg.ssl_cache_dir {
        standard_used_gb
    } else {
        tokio::task::spawn_blocking({
            let d = cfg.ssl_cache_dir.clone();
            move || nginx_client::get_cache_size_gb(&d)
        })
        .await
        .unwrap_or(0.0)
    };
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

    let standard_pct = ((standard_used_gb / cfg.standard_cache_max_gb) * 100.0).min(100.0) as u64;
    let ssl_pct = ((ssl_used_gb / cfg.ssl_cache_max_gb) * 100.0).min(100.0) as u64;

    let mut ctx = Context::new();
    ctx.insert("standard_status", &standard_status);
    ctx.insert("ssl_status", &ssl_status);
    ctx.insert("standard_used_gb", &format!("{:.1}", standard_used_gb));
    ctx.insert("ssl_used_gb", &format!("{:.1}", ssl_used_gb));
    ctx.insert("standard_max_gb", &cfg.standard_cache_max_gb);
    ctx.insert("ssl_max_gb", &cfg.ssl_cache_max_gb);
    ctx.insert("standard_pct", &standard_pct);
    ctx.insert("ssl_pct", &ssl_pct);
    ctx.insert("log_stats", &log_stats);
    ctx.insert("recent_logs", &recent_logs);
    ctx.insert("active_page", "dashboard");

    crate::routes::render(&state.templates, "dashboard.html", &ctx)
}

pub async fn metrics_api(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let cfg = &state.config;
    let standard_status =
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_standard_url).await;
    let ssl_status = if cfg.proxy_standard_url == cfg.proxy_ssl_url {
        standard_status.clone()
    } else {
        nginx_client::get_stub_status(&state.http_client, &cfg.proxy_ssl_url).await
    };
    Json(json!({
        "standard": standard_status,
        "ssl": ssl_status,
    }))
}
