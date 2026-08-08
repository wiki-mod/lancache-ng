//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI route modules, plus shared helpers used across them: Tera
//! template rendering with dev/prod error detail, and CSRF token
//! insertion/verification against the per-session token carried in request
//! headers by the `basic_auth` middleware.

pub mod cache;
pub mod dashboard;
pub mod dhcp;
pub mod dns_snapshots;
pub mod domains;
pub mod logs;
pub mod netdata_proxy;
pub mod ntp;
pub mod secondaries;
pub mod setup;
pub mod stats;

use axum::http::HeaderMap;
use axum::response::Html;
use subtle::ConstantTimeEq;
use tera::{Context, Tera};
use tracing::error;

pub fn render(templates: &Tera, name: &str, ctx: &Context, dev_mode: bool) -> Html<String> {
    match templates.render(name, ctx) {
        Ok(html) => Html(html),
        Err(e) => {
            error!(template = name, error = %e, "template rendering failed");
            if dev_mode {
                Html(format!(
                    "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
                    <h2>Template error: {}</h2><p>{}</p></body></html>",
                    name, e
                ))
            } else {
                Html(
                    "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
                    <h2>Template Rendering Failed</h2><p>An error occurred while rendering the page. \
                    Please check the application logs for details.</p></body></html>"
                        .to_string()
                )
            }
        }
    }
}

pub fn insert_csrf_token(ctx: &mut Context, headers: &HeaderMap) {
    let token = crate::session::csrf_header_value(headers).unwrap_or_else(|| {
        // Every real page handler this is called from sits behind the
        // `basic_auth` middleware, which always sets the internal CSRF
        // header for a valid session before routing to any handler --
        // reaching this function with no header present means that
        // invariant broke somewhere upstream, not a normal "no session
        // yet" state this function should quietly tolerate. A real
        // session's own csrf_token is always 32 random bytes
        // (session::issue_session_at), never empty, so silently embedding
        // "" here with zero diagnostic could only ever become exploitable
        // if some other bug also let a session's csrf_token become empty
        // -- and with no diagnostic, that combination would go unnoticed
        // until actually exploited. Logging loudly turns a theoretical
        // defense-in-depth gap into an observable failure instead.
        tracing::error!(
            "insert_csrf_token: no session CSRF header present on this request; \
             the basic_auth middleware should have set one before reaching this \
             handler. Embedding an empty CSRF token, which only passes \
             verify_csrf_token/verify_csrf_header if the session's own token is \
             also empty (never true for a real, correctly-issued session)."
        );
        ""
    });
    ctx.insert("csrf_token", token);
}

pub fn verify_csrf_token(headers: &HeaderMap, token: &str) -> Result<(), axum::http::StatusCode> {
    let session_token =
        crate::session::csrf_header_value(headers).ok_or(axum::http::StatusCode::FORBIDDEN)?;

    if bool::from(session_token.as_bytes().ct_eq(token.as_bytes())) {
        Ok(())
    } else {
        Err(axum::http::StatusCode::FORBIDDEN)
    }
}

pub fn verify_csrf_header(headers: &axum::http::HeaderMap) -> Result<(), axum::http::StatusCode> {
    let session_token =
        crate::session::csrf_header_value(headers).ok_or(axum::http::StatusCode::FORBIDDEN)?;
    let token = headers
        .get("x-csrf-token")
        .and_then(|value| value.to_str().ok());

    if token.is_some_and(|token| bool::from(session_token.as_bytes().ct_eq(token.as_bytes()))) {
        Ok(())
    } else {
        Err(axum::http::StatusCode::FORBIDDEN)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Dev-mode error pages must reveal the actual error text and template name so developers can diagnose template failures locally.
    #[test]
    fn render_error_returns_full_details_in_dev_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "{{ undefined_var }}")
            .expect("failed to add template");

        let ctx = Context::new();
        let html = render(&tera, "test.html", &ctx, true);
        let response = html.0;

        assert!(response.contains("Template error: test.html"));
        assert!(response.contains("undefined_var"));
    }

    // Prod-mode error pages must hide all implementation details so template errors never leak to end users — this guards against accidental exposure.
    #[test]
    fn render_error_returns_generic_message_in_prod_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "{{ undefined_var }}")
            .expect("failed to add template");

        let ctx = Context::new();
        let html = render(&tera, "test.html", &ctx, false);
        let response = html.0;

        assert!(response.contains("Template Rendering Failed"));
        assert!(response.contains("An error occurred while rendering the page"));
        assert!(!response.contains("undefined_var"));
        assert!(!response.contains("test.html"));
    }

    // Successful template renders must produce identical output in both dev and prod modes — dev_mode only affects error handling.
    #[test]
    fn render_success_ignores_dev_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "<h1>Hello {{ name }}</h1>")
            .expect("failed to add template");

        let mut ctx = Context::new();
        ctx.insert("name", "World");

        let html_dev = render(&tera, "test.html", &ctx, true);
        let html_prod = render(&tera, "test.html", &ctx, false);

        assert_eq!(html_dev.0, html_prod.0);
        assert!(html_dev.0.contains("<h1>Hello World</h1>"));
    }

    // CSRF helpers must enforce that the session header token matches the client-provided token via constant-time comparison to prevent token-guessing attacks.
    #[test]
    fn csrf_token_helpers_use_the_session_header() {
        let empty_headers = HeaderMap::new();
        assert!(verify_csrf_token(&empty_headers, "session-token-a").is_err());
        assert!(verify_csrf_header(&empty_headers).is_err());

        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::HeaderName::from_static(crate::session::INTERNAL_CSRF_HEADER_NAME),
            axum::http::HeaderValue::from_static("session-token-a"),
        );
        headers.insert(
            "x-csrf-token",
            axum::http::HeaderValue::from_static("session-token-a"),
        );

        let mut ctx = Context::new();
        insert_csrf_token(&mut ctx, &headers);
        assert_eq!(
            ctx.get("csrf_token").and_then(|value| value.as_str()),
            Some("session-token-a")
        );

        assert!(verify_csrf_token(&headers, "session-token-a").is_ok());
        assert!(verify_csrf_header(&headers).is_ok());

        headers.insert(
            "x-csrf-token",
            axum::http::HeaderValue::from_static("session-token-b"),
        );
        assert!(verify_csrf_token(&headers, "session-token-b").is_err());
        assert!(verify_csrf_header(&headers).is_err());
    }

    // Reaching insert_csrf_token with no session CSRF header present (an
    // invariant violation this function cannot itself repair) must still
    // insert an empty context value rather than panicking or leaving the
    // template variable undefined -- Tera errors on an undefined variable,
    // so degrading gracefully here still matters even for a logged, loud
    // failure. Locks the fallback value's own behavior; the
    // tracing::error! call itself has no return value to assert on
    // directly.
    #[test]
    fn insert_csrf_token_degrades_to_empty_value_without_a_session_header() {
        let empty_headers = HeaderMap::new();
        let mut ctx = Context::new();
        insert_csrf_token(&mut ctx, &empty_headers);
        assert_eq!(
            ctx.get("csrf_token").and_then(|value| value.as_str()),
            Some("")
        );
    }
}
