pub mod dashboard;
pub mod dhcp;
pub mod domains;
pub mod logs;
pub mod netdata_proxy;
pub mod setup;
pub mod stats;

use axum::response::Html;
use tera::{Context, Tera};

pub fn render(templates: &Tera, name: &str, ctx: &Context) -> Html<String> {
    match templates.render(name, ctx) {
        Ok(html) => Html(html),
        Err(e) => Html(format!(
            "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
            <h2>Template-Fehler: {}</h2><p>{}</p></body></html>",
            name, e
        )),
    }
}
