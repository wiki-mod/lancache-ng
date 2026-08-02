//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Proxy route for forwarding requests to Netdata monitoring endpoints.

use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Response,
};
// build_netdata_url now lives in the lancache_ui library crate (see
// services/ui/src/netdata_url.rs) so fuzz/'s cargo-fuzz harness can link it
// directly against client-controlled path/query-parameter input -- this
// module uses the exact same function, not a redefinition of it.
use lancache_ui::netdata_url::build_netdata_url;
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
    let body_bytes = upstream
        .bytes()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;

    Response::builder()
        .status(status.as_u16())
        .header("content-type", "application/json")
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
