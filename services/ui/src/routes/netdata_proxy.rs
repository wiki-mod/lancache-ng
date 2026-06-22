use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Response,
};
use std::{collections::HashMap, sync::Arc};

pub async fn proxy(
    State(state): State<Arc<AppState>>,
    Path(path): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Response<Body>, StatusCode> {
    // Reject path traversal attempts before reqwest normalises them
    if path.contains("..") {
        return Err(StatusCode::BAD_REQUEST);
    }
    let mut target = format!("{}/api/v1/{}", state.config.netdata_url, path);
    if !params.is_empty() {
        let qs = params
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join("&");
        target = format!("{}?{}", target, qs);
    }

    let upstream = state
        .http_client
        .get(&target)
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
        .header("access-control-allow-origin", "*")
        .body(Body::from(body_bytes))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
