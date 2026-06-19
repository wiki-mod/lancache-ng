use crate::{nginx_client, AppState};
use axum::extract::State;
use axum::response::Html;
use std::sync::Arc;
use tera::Context;

pub async fn logs_page(State(state): State<Arc<AppState>>) -> Html<String> {
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

    let mut all_logs: Vec<_> = standard_logs
        .unwrap_or_default()
        .into_iter()
        .chain(ssl_logs.unwrap_or_default())
        .collect();

    // Show most recent first
    all_logs.reverse();
    all_logs.truncate(200);

    let mut ctx = Context::new();
    ctx.insert("logs", &all_logs);
    ctx.insert("active_page", "logs");
    crate::routes::render(&state.templates, "logs.html", &ctx)
}
