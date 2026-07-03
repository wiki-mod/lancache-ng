//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Route for viewing and filtering nginx access logs.

use crate::{nginx_client, AppState};
use axum::extract::{Query, State};
use axum::response::Html;
use serde::Deserialize;
use std::sync::Arc;
use tera::Context;

#[derive(Deserialize)]
pub struct LogFilter {
    pub filter: Option<String>,
}

pub async fn logs_page(
    State(state): State<Arc<AppState>>,
    Query(params): Query<LogFilter>,
) -> Html<String> {
    let mut all_logs = if state.config.standard_log == state.config.ssl_log {
        let mut shared_logs = tokio::task::spawn_blocking({
            let path = state.config.standard_log.clone();
            move || nginx_client::parse_log_tail(&path, 200)
        })
        .await
        .unwrap_or_default();

        for entry in &mut shared_logs {
            entry.source = "Shared".to_string();
        }

        shared_logs
    } else {
        let (standard_logs, ssl_logs) = tokio::join!(
            tokio::task::spawn_blocking({
                let p = state.config.standard_log.clone();
                move || nginx_client::parse_log_tail(&p, 100)
            }),
            tokio::task::spawn_blocking({
                let p = state.config.ssl_log.clone();
                move || nginx_client::parse_log_tail(&p, 100)
            }),
        );

        let mut standard_logs = standard_logs.unwrap_or_default();
        for entry in &mut standard_logs {
            entry.source = "Standard".to_string();
        }

        let mut ssl_logs = ssl_logs.unwrap_or_default();
        for entry in &mut ssl_logs {
            entry.source = "SSL".to_string();
        }

        standard_logs.into_iter().chain(ssl_logs).collect()
    };

    // Show most recent first
    all_logs.reverse();
    all_logs.truncate(200);

    // Apply cache status filter if provided
    if let Some(filter) = &params.filter {
        all_logs.retain(|entry| &entry.cache_status == filter);
    }

    let mut ctx = Context::new();
    ctx.insert("logs", &all_logs);
    ctx.insert("active_page", "logs");
    crate::routes::render(&state.templates, "logs.html", &ctx, state.config.dev_mode)
}
