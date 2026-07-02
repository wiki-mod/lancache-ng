use crate::AppState;
use axum::extract::State;
use axum::response::Html;
use std::sync::Arc;
use tera::Context;

pub async fn setup_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("standard_ip", &state.config.standard_ip);
    ctx.insert("ssl_ip", &state.config.ssl_ip);
    ctx.insert("active_page", "setup");
    crate::routes::render(&state.templates, "setup.html", &ctx, state.config.dev_mode)
}
