//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Proxy route for forwarding requests to Netdata monitoring endpoints.

use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Response,
};
use futures_util::StreamExt;
// build_netdata_url/resolve_proxy_content_type now live in the lancache_ui
// library crate (see services/ui/src/netdata_url.rs) so fuzz/'s cargo-fuzz
// harness can link build_netdata_url directly against client-controlled
// path/query-parameter input, and so resolve_proxy_content_type's pure
// decision logic can be unit-tested without an axum handler -- this module
// uses the exact same functions, not a redefinition of either.
use lancache_ui::netdata_url::{build_netdata_url, resolve_proxy_content_type};
use std::{collections::HashMap, sync::Arc};

// Finding #7 (docs/bug-hunt/ui-routes.md, issue #849): the upstream Netdata
// response used to be buffered via a bare `.bytes()` call with no size
// limit at all. `netdata_url` itself is server configuration, not
// client-controlled, but the query parameters this proxy forwards to it ARE
// (a `/data` chart request can legitimately ask for a very wide time range
// or a very high point count) -- an operator-reachable request shaped to
// make Netdata return an unusually large response would still be buffered
// into this process's memory in full before any status/size check runs.
// Capped generously above any real dashboard chart payload (Netdata's own
// `/api/v1/data`/`/api/v1/charts` responses are JSON metric series, not bulk
// data transfer) so this never rejects genuine Admin UI traffic, while
// still bounding the worst case instead of leaving it fully unbounded.
const MAX_NETDATA_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

pub async fn proxy(
    State(state): State<Arc<AppState>>,
    Path(path): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Response<Body>, StatusCode> {
    let target = build_netdata_url(&state.config.netdata_url, &path, &params)?;

    let upstream = state
        .http_client
        .get(target)
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let status = upstream.status();
    // #849 bug-hunt finding observability.md#11: read the upstream's own
    // Content-Type before consuming the response body below (read_bounded_body
    // takes ownership of `upstream`), so the caller-requested `format=`
    // (json/csv/html/...) is reflected honestly instead of every response
    // being hardcoded to application/json regardless of what was actually
    // returned.
    let upstream_content_type = upstream
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let body_bytes = read_bounded_body(upstream, MAX_NETDATA_RESPONSE_BYTES).await?;

    let content_type = resolve_proxy_content_type(upstream_content_type.as_deref());

    Response::builder()
        .status(status.as_u16())
        .header("content-type", content_type)
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

// Streams `response`'s body and accumulates it into a single buffer,
// rejecting with 502 Bad Gateway the moment the accumulated size would
// exceed `limit` -- unlike a bare `.bytes()` call, this never allocates
// more than `limit` bytes for the response body regardless of how large
// the real upstream response turns out to be. 502, not 413/507: from this
// proxy's caller's perspective, the upstream (Netdata) is the thing that
// misbehaved by returning an oversized response, the same category as any
// other upstream failure this function already reports as BAD_GATEWAY.
//
// `reqwest::Response` has no public constructor usable from a unit test
// (no `From<http::Response<_>>` the other direction, only the reverse), so
// this function's own streaming loop cannot be exercised without a real
// HTTP server -- the size-check boundary condition it depends on is pulled
// out into `would_exceed_limit` below specifically so that arithmetic has
// a real unit test regardless.
async fn read_bounded_body(
    response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, StatusCode> {
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| StatusCode::BAD_GATEWAY)?;
        if would_exceed_limit(body.len(), chunk.len(), limit) {
            return Err(StatusCode::BAD_GATEWAY);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

// Pure boundary check for read_bounded_body's accumulation loop: would
// adding `chunk_len` more bytes on top of `current_len` already-buffered
// bytes exceed `limit`? Off-by-one correctness here (`>` vs. `>=`) is the
// actual risk in this kind of function, which is exactly why it has its
// own dedicated unit test below rather than being inlined and left
// untested along with the rest of the streaming loop.
fn would_exceed_limit(current_len: usize, chunk_len: usize, limit: usize) -> bool {
    current_len + chunk_len > limit
}

#[cfg(test)]
mod tests {
    use super::*;

    // Finding #7 (docs/bug-hunt/ui-routes.md, issue #849): the actual
    // boundary this fix depends on. A chunk that lands exactly at the
    // limit must be accepted (this is a size cap, not a strictly-less-than
    // cap); one byte over must be rejected.
    #[test]
    fn would_exceed_limit_boundary_is_exact() {
        assert!(!would_exceed_limit(0, 10, 10));
        assert!(!would_exceed_limit(5, 5, 10));
        assert!(would_exceed_limit(5, 6, 10));
        assert!(would_exceed_limit(0, 11, 10));
    }

    // A limit of 0 must reject any non-empty chunk, and accept nothing
    // ever accumulating -- the degenerate case a naive `>=`-vs-`>` mixup
    // could get backwards.
    #[test]
    fn would_exceed_limit_zero_limit_rejects_any_nonempty_chunk() {
        assert!(!would_exceed_limit(0, 0, 0));
        assert!(would_exceed_limit(0, 1, 0));
    }
}
