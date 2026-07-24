//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! Proxy route for forwarding requests to Netdata monitoring endpoints.

use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Response,
};
use reqwest::Url;
use std::{collections::HashMap, sync::Arc};

const ALLOWED_NETDATA_ENDPOINTS: &[&str] = &["data", "charts"];

fn build_netdata_url(
    base_url: &str,
    path: &str,
    params: &HashMap<String, String>,
) -> Result<Url, StatusCode> {
    if path.is_empty() || path.contains('/') || path.contains("..") {
        return Err(StatusCode::BAD_REQUEST);
    }

    if !ALLOWED_NETDATA_ENDPOINTS.contains(&path) {
        return Err(StatusCode::NOT_FOUND);
    }

    let mut url = Url::parse(base_url).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        segments.pop_if_empty();
        segments.extend(["api", "v1", path]);
    }

    if !params.is_empty() {
        url.query_pairs_mut().extend_pairs(params.iter());
    }

    Ok(url)
}

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

#[cfg(test)]
mod tests {
    use super::*;

    fn params(values: &[(&str, &str)]) -> HashMap<String, String> {
        values
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    #[test]
    fn builds_allowed_data_url_with_query_params() {
        let url = build_netdata_url(
            "http://netdata:19999",
            "data",
            &params(&[
                ("chart", "system.cpu"),
                ("points", "60"),
                ("group", "average"),
                ("format", "json"),
            ]),
        )
        .expect("data endpoint should be allowed");

        assert_eq!(
            url.as_str().split('?').next(),
            Some("http://netdata:19999/api/v1/data")
        );
        let pairs: HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(pairs.get("chart"), Some(&"system.cpu".to_string()));
        assert_eq!(pairs.get("points"), Some(&"60".to_string()));
        assert_eq!(pairs.get("group"), Some(&"average".to_string()));
        assert_eq!(pairs.get("format"), Some(&"json".to_string()));
    }

    #[test]
    fn encodes_query_params_with_url_builder() {
        let url = build_netdata_url(
            "http://netdata:19999/",
            "data",
            &params(&[("chart name", "system.cpu & memory=used%")]),
        )
        .expect("data endpoint should be allowed");

        assert_eq!(url.path(), "/api/v1/data");
        assert!(
            url.as_str()
                .contains("chart+name=system.cpu+%26+memory%3Dused%25")
        );
        let pairs: HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(
            pairs.get("chart name"),
            Some(&"system.cpu & memory=used%".to_string())
        );
    }

    #[test]
    fn allows_charts_endpoint() {
        let url = build_netdata_url("http://netdata:19999", "charts", &HashMap::new())
            .expect("charts endpoint should be allowed");

        assert_eq!(url.as_str(), "http://netdata:19999/api/v1/charts");
    }

    #[test]
    fn rejects_unsafe_or_unapproved_paths() {
        for path in ["", "data/anything", "../data", "foo", "api/v1/data"] {
            assert!(
                build_netdata_url("http://netdata:19999", path, &HashMap::new()).is_err(),
                "{path} should be rejected"
            );
        }
    }
}
