//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Pure Netdata proxy URL builder, extracted from `routes/netdata_proxy.rs`
//! (issue #1252) so `build_netdata_url` -- the allowlisted-path builder that
//! turns a client-controlled `path`/query-parameter pair into the upstream
//! Netdata request URL -- can be linked directly by a `cargo-fuzz` harness
//! (`fuzz/fuzz_targets/netdata_url_parse.rs`) without pulling in the whole
//! Admin UI's `AppState`/axum extractor surface, which only `main.rs`'s
//! binary target needs. `routes/netdata_proxy.rs` imports this same function
//! from this crate rather than redefining it, so the fuzz harness and the
//! production binary exercise identical code. Already covered by unit tests
//! for the known-bad-input cases the author thought to write (see below);
//! issue #1252 specifically asks for this to also be fuzzed against
//! unknown-shape inputs the author did not anticipate.

use axum::http::StatusCode;
use reqwest::Url;
use std::collections::HashMap;

const ALLOWED_NETDATA_ENDPOINTS: &[&str] = &["data", "charts"];

/// Builds the upstream Netdata request URL for one Admin UI `/netdata/{path}`
/// proxy request. `base_url` is server configuration (`state.config
/// .netdata_url`), never client-controlled; `path` and `params` come
/// directly from the incoming HTTP request (an axum `Path`/`Query`
/// extractor in `routes/netdata_proxy.rs::proxy`) and are exactly the
/// client-controlled input issue #1252 calls out for fuzzing. Rejects an
/// empty path, any path segment separator (`/`), and any `..` substring
/// before checking the fixed allowlist, so path traversal or a
/// non-allowlisted Netdata API endpoint can never reach `Url::parse`'s
/// segment builder below.
pub fn build_netdata_url(
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

#[cfg(test)]
mod tests {
    use super::*;

    fn params(values: &[(&str, &str)]) -> HashMap<String, String> {
        values
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    // Allowed endpoints like "data" must build valid URLs with the /api/v1/ path prefix and attach all query parameters correctly.
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

    // URL builder must properly percent-encode special characters in query parameter names and values to prevent injection attacks.
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

    // The "charts" endpoint must be included in the allowlist and generate the correct /api/v1/charts URL.
    #[test]
    fn allows_charts_endpoint() {
        let url = build_netdata_url("http://netdata:19999", "charts", &HashMap::new())
            .expect("charts endpoint should be allowed");

        assert_eq!(url.as_str(), "http://netdata:19999/api/v1/charts");
    }

    // Path traversal attempts (..), slashes within paths, empty paths, and unapproved endpoints must all be rejected to prevent bypassing the allowlist.
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
