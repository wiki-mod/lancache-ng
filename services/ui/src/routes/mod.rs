pub mod dashboard;
pub mod dhcp;
pub mod domains;
pub mod logs;
pub mod netdata_proxy;
pub mod secondaries;
pub mod setup;
pub mod stats;

use axum::response::Html;
use tera::{Context, Tera};

pub fn render(templates: &Tera, name: &str, ctx: &Context) -> Html<String> {
    match templates.render(name, ctx) {
        Ok(html) => Html(html),
        Err(e) => Html(format!(
            "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
            <h2>Template error: {}</h2><p>{}</p></body></html>",
            name, e
        )),
    }
}

pub fn insert_csrf_token(ctx: &mut Context, state: &crate::AppState) {
    ctx.insert("csrf_token", &state.csrf_token);
}

pub fn verify_csrf_token(
    state: &crate::AppState,
    token: &str,
) -> Result<(), axum::http::StatusCode> {
    if token == state.csrf_token {
        Ok(())
    } else {
        Err(axum::http::StatusCode::FORBIDDEN)
    }
}

pub fn verify_csrf_header(
    state: &crate::AppState,
    headers: &axum::http::HeaderMap,
) -> Result<(), axum::http::StatusCode> {
    let token = headers
        .get("x-csrf-token")
        .and_then(|value| value.to_str().ok());

    if token == Some(state.csrf_token.as_str()) {
        Ok(())
    } else {
        Err(axum::http::StatusCode::FORBIDDEN)
    }
}
