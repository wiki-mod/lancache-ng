use crate::AppState;
use axum::extract::State;
use axum::response::Html;
use std::sync::Arc;
use tera::Context;

pub async fn stats_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "stats");
    crate::routes::render(&state.templates, "stats.html", &ctx, state.config.dev_mode)
}
