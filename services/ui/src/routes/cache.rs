//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI cache-resize control (issue #1069 part 3): lets an operator
//! request a new `CACHE_MAX_SIZE` from the dashboard, re-validating the
//! request against real free disk space at `CACHE_DIR` with the same
//! buffer-scaled safety check `setup.sh`'s initial "Cache size in GiB" prompt
//! already enforces at install time (see nginx_client.rs's
//! cache_size_buffer_mib/cache_size_fits_available_mib/largest_valid_cache_gb).
//!
//! Unlike routes/domains.rs's AAAA-filter toggle or CDN domain add/remove,
//! this container cannot make the change take effect itself: `CACHE_MAX_SIZE`
//! reaches the proxy container via the real deployment `.env`
//! (`deploy/quickstart/docker-compose.yml`'s
//! `environment: - CACHE_MAX_SIZE=${CACHE_MAX_SIZE}`), a file this container
//! has no filesystem access to, and `docker_client` deliberately has no exec
//! capability to send nginx a reload signal even if it did. This instead
//! follows the same host-bridged model routes/setup.rs's release-channel
//! control already established for #819: the validated request is persisted
//! to the `ui-data`-backed settings file (via
//! routes/dhcp.rs's persist_cache_settings), and setup.sh's
//! `cmd_converge_reconcile` (running on the host every ~5 minutes via
//! `lancache-converge.service`) folds it into the real `.env` and lets the
//! existing `docker compose up -d --remove-orphans` convergence step recreate
//! the proxy container with the new value. See that function's own comment
//! in setup.sh for the exact write path and its deploy/prod scope boundary.
//!
//! Empirical finding on nginx itself (not just this project's wiring): a
//! plain `nginx -s reload` DOES pick up a changed `proxy_cache_path
//! ... max_size=` for an already-running cache zone -- verified against
//! nginx's own source (`ngx_http_file_cache_init` in
//! `src/http/ngx_http_file_cache.c` reuses the existing shared-memory zone
//! across a reload while recalculating `max_size` from the new config, and
//! `ngx_master_process_cycle` in `src/os/unix/ngx_process_cycle.c` respawns
//! fresh cache manager/loader processes with that new config on `SIGHUP`).
//! It is this project's own entrypoint (`services/proxy/entrypoint.sh` only
//! renders `nginx.conf` from its template once, before `exec nginx`, with no
//! signal handler to re-render and reload) and the docker-socket-proxy's
//! deliberately exec-free allowlist (`docker_client.rs`) that make a full
//! container recreate the only available mechanism here today, not a
//! limitation of nginx itself.

use crate::{AppState, nginx_client};
use axum::extract::{Form, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Deserialize)]
pub struct ResizeCacheForm {
    pub csrf_token: String,
    pub cache_gb: String,
}

// Deliberately separate from routes/setup.rs's SettingsError (that type's
// constructor is private to that module) and from routes/dhcp.rs's
// DhcpError (whose html_escape exists for a reason this handler doesn't
// share: every message this type ever renders is built entirely from
// trusted values -- the operator-configured cache_dir and numbers this
// process itself computed -- never from unescaped free-form request input).
#[derive(Debug)]
pub struct CacheError {
    status: StatusCode,
    message: String,
}

impl CacheError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for CacheError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for CacheError {}

impl IntoResponse for CacheError {
    fn into_response(self) -> Response {
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>Cache Resize Error</title></head>\n\
             <body><h1>Cache Resize Error</h1>\n<p>{}</p>\n\
             <p><a href=\"/\">Return to dashboard</a></p>\n</body>\n</html>",
            self.message
        );
        (self.status, Html(body)).into_response()
    }
}

// Parses and range-checks the "New cache size (GB)" form field: must be a
// plain positive whole number, matching setup.sh's own `is_positive_integer`
// gate for the equivalent CLI prompt. Rust's `str::parse::<u64>` already
// rejects a leading '-', decimals, and non-digit characters outright (unlike
// bash's `(( ))`, there is no octal-leading-zero surprise to guard against
// here either).
fn parse_requested_cache_gb(raw: &str) -> Option<u64> {
    let trimmed = raw.trim();
    let value: u64 = trimmed.parse().ok()?;
    (value > 0).then_some(value)
}

// Builds the same rejection message shape as setup.sh's own "Cache size in
// GiB" prompt (`cache_size_fits_available_mib`'s die() path), so an operator
// who has seen the CLI's error message recognizes this one -- see setup.sh's
// prompt loop for the original wording this mirrors.
fn resize_rejection_message(cache_dir: &str, cache_gb: u64, avail_mib: u64) -> String {
    let avail_gb = avail_mib / 1024;
    match nginx_client::largest_valid_cache_gb(avail_mib) {
        Some(largest) if largest >= 1 => format!(
            "{cache_gb} GB would not leave a safety buffer at {cache_dir} (only {avail_gb} GB \
             free there). The largest value that currently passes is {largest} GB."
        ),
        _ => format!(
            "Not enough free space at {cache_dir} for any cache size with a safety buffer (only \
             {avail_gb} GB free there). Free up disk space or choose a smaller size."
        ),
    }
}

// Validates a resize request against real free disk space and, on success,
// persists it (issue #1069 part 3). See this module's own header comment for
// why this can only ever persist an override for the host-side convergence
// tick to apply, never take effect synchronously with this request.
pub async fn resize_cache(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<ResizeCacheForm>,
) -> Result<Redirect, CacheError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)
        .map_err(|status| CacheError::new(status, "Invalid or missing CSRF token."))?;

    let cache_gb = parse_requested_cache_gb(&form.cache_gb).ok_or_else(|| {
        CacheError::new(
            StatusCode::BAD_REQUEST,
            "Please enter a positive whole number of GB.",
        )
    })?;

    // Fail closed: a `df` failure (e.g. an unexpected mount layout) must
    // never be silently treated as "unlimited free space" -- see
    // nginx_client::available_space_mib_at's own doc comment.
    let avail_mib =
        nginx_client::available_space_mib_at(&state.config.cache_dir).ok_or_else(|| {
            CacheError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!(
                    "Could not determine free disk space at {}. Refusing to resize.",
                    state.config.cache_dir
                ),
            )
        })?;

    if !nginx_client::cache_size_fits_available_mib(cache_gb, avail_mib) {
        return Err(CacheError::new(
            StatusCode::BAD_REQUEST,
            resize_rejection_message(&state.config.cache_dir, cache_gb, avail_mib),
        ));
    }

    crate::routes::dhcp::persist_cache_settings(&state, cache_gb)
        .map_err(|err| CacheError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    Ok(Redirect::to("/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_accepts_a_plain_positive_integer() {
        assert_eq!(parse_requested_cache_gb("50"), Some(50));
        assert_eq!(parse_requested_cache_gb(" 75 "), Some(75));
    }

    #[test]
    fn parse_rejects_zero_negative_decimal_and_garbage() {
        assert_eq!(parse_requested_cache_gb("0"), None);
        assert_eq!(parse_requested_cache_gb("-5"), None);
        assert_eq!(parse_requested_cache_gb("50.5"), None);
        assert_eq!(parse_requested_cache_gb(""), None);
        assert_eq!(parse_requested_cache_gb("fifty"), None);
        assert_eq!(parse_requested_cache_gb("50; rm -rf /"), None);
    }

    #[test]
    fn rejection_message_suggests_the_largest_passing_value() {
        // 50 GB requested against only 50 GB free: the 2048 MiB buffer means
        // this must fail, and the message must name a concrete smaller value
        // that would currently pass.
        let msg = resize_rejection_message("/var/cache/proxy", 50, 50 * 1024);
        assert!(msg.contains("50 GB would not leave a safety buffer"));
        assert!(msg.contains("/var/cache/proxy"));
        assert!(msg.contains("largest value that currently passes"));
    }

    #[test]
    fn rejection_message_handles_a_disk_too_small_for_any_size() {
        // 400 MiB free is below even the smallest (512 MiB) buffer band --
        // no whole-GB size can ever pass, so the message must say so plainly
        // instead of naming a bogus "largest passing value".
        let msg = resize_rejection_message("/var/cache/proxy", 5, 400);
        assert!(msg.contains("Not enough free space"));
        assert!(!msg.contains("largest value"));
    }
}
