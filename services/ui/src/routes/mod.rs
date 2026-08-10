//! SPDX-License-Identifier: AGPL-3.0-or-later
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
pub mod netdata_alarms;
pub mod netdata_proxy;
pub mod ntp;
pub mod secondaries;
pub mod setup;
pub mod stats;

use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use subtle::ConstantTimeEq;
use tera::{Context, Tera};
use tracing::error;

// Finding #8 (docs/bug-hunt/ui-core.md, issue #849): this used to return a
// bare `Html<String>`, which axum always serves with a 200 OK status --
// even the dev-mode/production error bodies rendered below on a genuine
// template failure went out as "200 OK, here is an error page" rather than
// a real 5xx. That is wrong for any caller that checks the HTTP status
// (health probes, monitoring, a reverse proxy's error-page routing, or an
// operator's own `curl -f`) rather than reading the rendered HTML body.
// Returning a full `Response` lets the error branch attach a real
// `500 Internal Server Error` status while the success branch keeps
// today's plain `200 OK` + rendered HTML behavior unchanged.
pub fn render(templates: &Tera, name: &str, ctx: &Context, dev_mode: bool) -> Response {
    match templates.render(name, ctx) {
        Ok(html) => Html(html).into_response(),
        Err(e) => {
            error!(template = name, error = %e, "template rendering failed");
            let body = if dev_mode {
                format!(
                    "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
                    <h2>Template error: {}</h2><p>{}</p></body></html>",
                    name, e
                )
            } else {
                "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;padding:2rem'>\
                    <h2>Template Rendering Failed</h2><p>An error occurred while rendering the page. \
                    Please check the application logs for details.</p></body></html>"
                    .to_string()
            };
            (StatusCode::INTERNAL_SERVER_ERROR, Html(body)).into_response()
        }
    }
}

pub fn insert_csrf_token(ctx: &mut Context, headers: &HeaderMap) {
    // csrf_header_value returns Some("") for a header that is present but
    // empty, not just None for an absent header -- filter that out too, so
    // the invariant-break diagnostic below fires for both shapes of the
    // same underlying problem instead of only the "header missing entirely"
    // case.
    let token = crate::session::csrf_header_value(headers)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            // Every real page handler this is called from sits behind the
            // `basic_auth` middleware, which always sets the internal CSRF
            // header for a valid session before routing to any handler --
            // reaching this function with no header present, or with one
            // present but empty, means that invariant broke somewhere
            // upstream, not a normal "no session yet" state this function
            // should quietly tolerate. A real session's own csrf_token is
            // always 32 random bytes (session::issue_session_at), never
            // empty, so silently embedding "" here with zero diagnostic
            // could only ever become exploitable if some other bug also
            // let a session's csrf_token become empty -- and with no
            // diagnostic, that combination would go unnoticed until
            // actually exploited. Logging loudly turns a theoretical
            // defense-in-depth gap into an observable failure instead.
            tracing::error!(
                "insert_csrf_token: no session CSRF header present on this request, or \
                 it was present but empty; the basic_auth middleware should have set a \
                 real one before reaching this handler. Embedding an empty CSRF token, \
                 which only passes verify_csrf_token/verify_csrf_header if the session's \
                 own token is also empty (never true for a real, correctly-issued \
                 session)."
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
    use axum::body::to_bytes;

    // render() now returns a full `Response` (Finding #8 fix) instead of a
    // bare `Html<String>` tuple struct, so tests must read the body back out
    // via axum::body::to_bytes (hence #[tokio::test], not #[test]) rather
    // than reaching into a `.0` field that no longer exists on this type.
    async fn body_text(response: Response) -> String {
        let bytes = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("failed to read response body");
        String::from_utf8(bytes.to_vec()).expect("response body was not valid UTF-8")
    }

    // Dev-mode error pages must reveal the actual error text and template name so developers can diagnose template failures locally.
    #[tokio::test]
    async fn render_error_returns_full_details_in_dev_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "{{ undefined_var }}")
            .expect("failed to add template");

        let ctx = Context::new();
        let response = render(&tera, "test.html", &ctx, true);
        let body = body_text(response).await;

        assert!(body.contains("Template error: test.html"));
        assert!(body.contains("undefined_var"));
    }

    // Prod-mode error pages must hide all implementation details so template errors never leak to end users — this guards against accidental exposure.
    #[tokio::test]
    async fn render_error_returns_generic_message_in_prod_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "{{ undefined_var }}")
            .expect("failed to add template");

        let ctx = Context::new();
        let response = render(&tera, "test.html", &ctx, false);
        let body = body_text(response).await;

        assert!(body.contains("Template Rendering Failed"));
        assert!(body.contains("An error occurred while rendering the page"));
        assert!(!body.contains("undefined_var"));
        assert!(!body.contains("test.html"));
    }

    // Successful template renders must produce identical output in both dev and prod modes — dev_mode only affects error handling.
    #[tokio::test]
    async fn render_success_ignores_dev_mode() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "<h1>Hello {{ name }}</h1>")
            .expect("failed to add template");

        let mut ctx = Context::new();
        ctx.insert("name", "World");

        let response_dev = render(&tera, "test.html", &ctx, true);
        let response_prod = render(&tera, "test.html", &ctx, false);

        let body_dev = body_text(response_dev).await;
        let body_prod = body_text(response_prod).await;

        assert_eq!(body_dev, body_prod);
        assert!(body_dev.contains("<h1>Hello World</h1>"));
    }

    // Finding #8 (docs/bug-hunt/ui-core.md, issue #849): the actual bug this
    // fix closes -- a template error must surface as a real HTTP 500, not a
    // 200 OK whose body happens to describe a failure. Every caller that
    // checks the status code (health probes, monitoring, `curl -f`) instead
    // of parsing the rendered HTML depends on this being correct.
    #[tokio::test]
    async fn render_error_returns_500_status_not_200() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "{{ undefined_var }}")
            .expect("failed to add template");
        let ctx = Context::new();

        let response = render(&tera, "test.html", &ctx, true);
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    // Mirrors the above for the success path: a normal render must still be
    // a plain 200 OK, proving the fix did not change the happy-path status.
    #[tokio::test]
    async fn render_success_returns_200_status() {
        let mut tera = Tera::default();
        tera.add_raw_template("test.html", "<h1>Hello</h1>")
            .expect("failed to add template");
        let ctx = Context::new();

        let response = render(&tera, "test.html", &ctx, false);
        assert_eq!(response.status(), StatusCode::OK);
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
    // failure. Locks the fallback value's own behavior only; the
    // diagnostic itself is asserted separately below, via a real
    // subscriber, since deleting the tracing::error! call would otherwise
    // leave this test green.
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

    // Minimal tracing::Subscriber that captures each event's "message"
    // field, so the invariant-break diagnostic itself (not just its
    // side-effecting fallback value) can be asserted on directly --
    // deleting the tracing::error! call in insert_csrf_token must fail
    // this test, unlike the fallback-value test above.
    struct CapturingSubscriber {
        messages: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    }

    struct MessageVisitor(Option<String>);

    impl tracing::field::Visit for MessageVisitor {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            if field.name() == "message" {
                self.0 = Some(format!("{value:?}"));
            }
        }
    }

    impl tracing::Subscriber for CapturingSubscriber {
        fn enabled(&self, _metadata: &tracing::Metadata<'_>) -> bool {
            true
        }
        fn new_span(&self, _span: &tracing::span::Attributes<'_>) -> tracing::span::Id {
            tracing::span::Id::from_u64(1)
        }
        fn record(&self, _span: &tracing::span::Id, _values: &tracing::span::Record<'_>) {}
        fn record_follows_from(&self, _span: &tracing::span::Id, _follows: &tracing::span::Id) {}
        fn event(&self, event: &tracing::Event<'_>) {
            let mut visitor = MessageVisitor(None);
            event.record(&mut visitor);
            if let Some(message) = visitor.0 {
                self.messages.lock().unwrap().push(message);
            }
        }
        fn enter(&self, _span: &tracing::span::Id) {}
        fn exit(&self, _span: &tracing::span::Id) {}
    }

    fn captured_diagnostics(run: impl FnOnce()) -> Vec<String> {
        let messages = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let subscriber = CapturingSubscriber {
            messages: messages.clone(),
        };
        tracing::subscriber::with_default(subscriber, run);
        messages.lock().unwrap().clone()
    }

    #[test]
    fn insert_csrf_token_logs_the_invariant_diagnostic_without_a_session_header() {
        let empty_headers = HeaderMap::new();
        let mut ctx = Context::new();
        let messages = captured_diagnostics(|| {
            insert_csrf_token(&mut ctx, &empty_headers);
        });
        assert!(
            messages
                .iter()
                .any(|message| message.contains("no session CSRF header present")),
            "expected the invariant-break diagnostic to be logged, got: {messages:?}"
        );
    }

    // The invariant break this hardening targets can also show up as a
    // present-but-empty header (csrf_header_value returns Some("")), not
    // just a fully absent one -- must hit the exact same fallback+diagnostic
    // path, not silently pass the empty value through untouched.
    #[test]
    fn insert_csrf_token_logs_the_invariant_diagnostic_for_a_present_but_empty_header() {
        let mut headers = HeaderMap::new();
        headers.insert(
            crate::session::INTERNAL_CSRF_HEADER_NAME,
            "".parse().unwrap(),
        );
        let mut ctx = Context::new();
        let messages = captured_diagnostics(|| {
            insert_csrf_token(&mut ctx, &headers);
        });
        assert_eq!(
            ctx.get("csrf_token").and_then(|value| value.as_str()),
            Some("")
        );
        assert!(
            messages
                .iter()
                .any(|message| message.contains("no session CSRF header present")),
            "expected the invariant-break diagnostic to be logged, got: {messages:?}"
        );
    }
}
