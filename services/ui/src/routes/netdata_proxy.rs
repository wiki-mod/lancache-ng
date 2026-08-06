//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Proxy route for forwarding requests to Netdata monitoring endpoints.

use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Response,
};
// build_netdata_url/resolve_proxy_content_type now live in the lancache_ui
// library crate (see services/ui/src/netdata_url.rs) so fuzz/'s cargo-fuzz
// harness can link build_netdata_url directly against client-controlled
// path/query-parameter input, and so resolve_proxy_content_type's pure
// decision logic can be unit-tested without an axum handler -- this module
// uses the exact same functions, not a redefinition of either.
use lancache_ui::netdata_url::{build_netdata_url, resolve_proxy_content_type};
use std::{collections::HashMap, sync::Arc};

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
    // Content-Type before consuming the response body below (upstream.bytes()
    // takes ownership of `upstream`), so the caller-requested `format=`
    // (json/csv/html/...) is reflected honestly instead of every response
    // being hardcoded to application/json regardless of what was actually
    // returned.
    let upstream_content_type = upstream
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let body_bytes = upstream
        .bytes()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    let content_type = resolve_proxy_content_type(upstream_content_type.as_deref());

    Response::builder()
        .status(status.as_u16())
        .header("content-type", content_type)
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
