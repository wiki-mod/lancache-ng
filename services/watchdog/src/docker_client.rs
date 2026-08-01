//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! HTTP client for the narrow subset of the Docker API
//! `scripts/docker-socket-proxy.sh`'s HAProxy allowlist actually permits:
//! reading a container's health JSON, restarting a container, and pinging
//! docker-socket-proxy itself. Mirrors watchdog.sh's `get_health()`/
//! `restart_container()`/`probe_docker_socket_proxy()` curl invocations.
//!
//! Deliberately plain `reqwest`, not `bollard` (the Docker SDK
//! `services/ui/src/docker_client.rs` uses): bollard's own client can issue
//! any Docker Engine API call, but this daemon must only ever hit exactly
//! three allowlisted paths -- a hand-rolled client with exactly three
//! methods makes "watchdog cannot accidentally call an unallowlisted Docker
//! endpoint" true by construction (there is no method that would let it),
//! rather than true only by convention.

use std::time::Duration;

use crate::health::HealthReading;

/// Runs `fut` under `timeout` when one is set. `None` means "no bound at
/// all" -- see [`crate::config::parse_curl_timeout`]'s own doc comment for
/// why a `CURL_MAX_TIME`/`CURL_MAX_TIME_RESTART` of `0` must resolve to
/// "unbounded" here, never to `Duration::ZERO` passed through this
/// function (a zero-duration `tokio::time::timeout` does not reliably mean
/// "never times out"; it means "times out almost immediately").
///
/// This wrapper exists because reqwest's own per-request `.timeout()`
/// covers the `send()` call, which resolves as soon as response headers
/// arrive -- the response body is a separate stream the caller must
/// explicitly read, and nothing automatically re-applies that same budget
/// to the read. curl's `--max-time` (what every one of watchdog.sh's `curl`
/// calls uses) bounds the WHOLE transfer, connect through the last body
/// byte. Wrapping the entire fetch (send + body read) in one outer
/// `tokio::time::timeout` removes any dependency on exactly how far
/// reqwest's per-request timeout extends into body consumption, and
/// matches curl's semantics precisely: a gateway that answers headers and
/// then stalls before finishing the body is bounded the same way a gateway
/// that never answers at all is.
async fn bounded<T>(timeout: Option<Duration>, fut: impl std::future::Future<Output = T>) -> Option<T> {
    match timeout {
        Some(t) => tokio::time::timeout(t, fut).await.ok(),
        None => Some(fut.await),
    }
}

// Applies `timeout` to a request builder if one is set, otherwise returns
// the builder unchanged (reqwest's own per-request `.timeout()` is skipped
// entirely for "no timeout" rather than ever being called with
// Duration::ZERO -- see bounded()'s doc comment for why zero is not a safe
// stand-in for "unbounded").
fn apply_timeout(builder: reqwest::RequestBuilder, timeout: Option<Duration>) -> reqwest::RequestBuilder {
    match timeout {
        Some(t) => builder.timeout(t),
        None => builder,
    }
}

/// A thin wrapper around a `reqwest::Client` pointed at `DOCKER_PROXY_URL`.
/// One shared client (connection pooling is reqwest's default and costs
/// nothing extra here), with the timeout supplied per call -- matching
/// watchdog.sh's two distinct budgets (`CURL_MAX_TIME` for health/ping
/// reads, `CURL_MAX_TIME_RESTART` for the restart POST, since a restart
/// includes both Docker's stop grace period and the container's own
/// startup time; see watchdog.sh's `restart_container()` comment for why
/// these two timeouts must not share one value). Every method takes
/// `Option<Duration>` rather than a bare `Duration`: `None` represents
/// curl's own "0 means no timeout" semantics for these two knobs.
pub struct DockerProxyClient {
    client: reqwest::Client,
    base_url: String,
}

impl DockerProxyClient {
    pub fn new(base_url: impl Into<String>) -> reqwest::Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder().build()?,
            base_url: base_url.into(),
        })
    }

    /// watchdog.sh's `get_health()`: reads `/containers/<name>/json` and
    /// extracts `.State.Health.Status`, falling back to the literal
    /// `"none"` when Docker reports no health status at all (jq's `//
    /// "none"`). Every failure mode -- connection refused, the timeout this
    /// function itself enforces, a non-2xx response, or a body that isn't
    /// valid JSON -- collapses to [`HealthReading::Unreachable`], matching
    /// `curl -sf`'s own `-f` (fail on HTTP error) semantics plus the bash's
    /// explicit `|| { echo "unreachable"; return; }`/`|| echo
    /// "unreachable"` fallbacks on both the curl call and the jq parse.
    pub async fn get_health(&self, container_name: &str, timeout: Option<Duration>) -> HealthReading {
        let url = format!("{}/containers/{container_name}/json", self.base_url);
        let body: Option<serde_json::Value> = bounded(timeout, async {
            let response = apply_timeout(self.client.get(&url), timeout).send().await.ok()?;
            if !response.status().is_success() {
                return None;
            }
            response.json().await.ok()
        })
        .await
        .flatten();

        let Some(body) = body else {
            return HealthReading::Unreachable;
        };
        let raw_status = body
            .pointer("/State/Health/Status")
            .and_then(|v| v.as_str())
            .unwrap_or("none");
        HealthReading::from_docker_status(raw_status)
    }

    /// watchdog.sh's `restart_container()`: `POST
    /// /containers/<name>/restart?t=2` (`t=2` tells Docker to wait 2s for
    /// SIGTERM before SIGKILL, coordinated with `timeout` the same way the
    /// bash's `CURL_MAX_TIME_RESTART` is). Returns whether the call
    /// succeeded; the bash only logs a warning on failure and never feeds
    /// that failure back into the failure counter, so this deliberately
    /// returns a plain `bool` rather than a `Result` the caller might be
    /// tempted to propagate.
    pub async fn restart(&self, container_name: &str, timeout: Option<Duration>) -> bool {
        let url = format!("{}/containers/{container_name}/restart?t=2", self.base_url);
        let success = bounded(timeout, async {
            apply_timeout(self.client.post(&url), timeout)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success())
        })
        .await;
        success.unwrap_or(false)
    }

    /// watchdog.sh's `probe_docker_socket_proxy()`: `GET /_ping`. Already
    /// permitted by the allowlist's `safe_ping` ACL (the same one
    /// `get_health()` relies on), needs no new privilege.
    ///
    /// Consumes the full response body under the same timeout, then checks
    /// it names the expected `OK` payload (Docker's real `/_ping` returns
    /// that literal string with no JSON wrapper) -- not just the HTTP
    /// status. A gateway that accepts the connection and sends a 200
    /// status line but then stalls before delivering the body would
    /// otherwise be reported healthy: `send()` resolves as soon as headers
    /// arrive, and if nothing ever reads the body, the stall is invisible.
    /// Detecting exactly that "alive but unresponsive" case is this
    /// alert-only probe's whole reason to exist, so silently dropping an
    /// unread response stream would defeat its own purpose. `.trim()`
    /// tolerates a trailing newline some HTTP stacks add without
    /// over-fitting to Docker's exact byte-for-byte framing.
    pub async fn ping(&self, timeout: Option<Duration>) -> bool {
        let url = format!("{}/_ping", self.base_url);
        let body: Option<String> = bounded(timeout, async {
            let response = apply_timeout(self.client.get(&url), timeout).send().await.ok()?;
            if !response.status().is_success() {
                return None;
            }
            response.text().await.ok()
        })
        .await
        .flatten();

        matches!(body.as_deref().map(str::trim), Some("OK"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    // Hand-rolled one-shot HTTP server: accepts exactly one connection,
    // discards the request, and writes back `response_bytes` verbatim.
    // Deliberately not a mocking crate dependency (this repository has none
    // today, see this module's own doc comment on why a hand-rolled client
    // was preferred over bollard for a similar minimalism reason) -- the
    // three request shapes this client makes are simple enough that a raw
    // TCP responder is less machinery than pulling in wiremock/mockito for
    // a handful of tests.
    async fn serve_one_response(response_bytes: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind an ephemeral local port");
        let addr = listener
            .local_addr()
            .expect("listener must have a local address");
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                // Best-effort read of the request; ignored beyond draining
                // it so the client doesn't block writing past a full
                // socket buffer on some platforms.
                let _ = socket.read(&mut buf).await;
                let _ = socket.write_all(response_bytes.as_bytes()).await;
                let _ = socket.shutdown().await;
            }
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    // Confirms the full success path end to end: a real HTTP response
    // parses as JSON, and a present .State.Health.Status maps to Healthy.
    // Deliberately no Content-Length header: relies on "Connection:
    // close" + the socket shutdown in serve_one_response() to delimit the
    // body (a real, RFC 7230-valid close-delimited message), rather than a
    // hand-counted byte length -- an earlier version of this test
    // hardcoded a wrong Content-Length and the response body was silently
    // never delivered to completion, failing the test with a misleadingly
    // plausible-looking "Unreachable" result instead of an obviously-wrong
    // byte count.
    async fn get_health_parses_a_real_healthy_response() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\"}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-proxy", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Healthy);
    }

    #[tokio::test]
    // A container with no configured HEALTHCHECK omits .State.Health
    // entirely -- jq's `// "none"` fallback, mirrored here.
    async fn get_health_falls_back_to_none_when_health_is_absent() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-nats", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::None);
    }

    #[tokio::test]
    // A non-2xx response (e.g. the allowlist rejecting an unknown
    // container name, or docker-socket-proxy itself erroring) must map to
    // Unreachable, matching curl -sf's own fail-on-HTTP-error behavior.
    async fn get_health_treats_non_2xx_as_unreachable() {
        let base_url =
            serve_one_response("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n").await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("does-not-exist", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Unreachable);
    }

    #[tokio::test]
    // Nothing listening at all (connection refused) is the other real-world
    // shape of "docker-socket-proxy is unreachable" -- distinct code path
    // from the 404 case above (a connection error vs. a completed request
    // with a bad status), both must land on the same Unreachable outcome.
    async fn get_health_treats_connection_refused_as_unreachable() {
        // Bind then immediately drop the listener so the port is real but
        // guaranteed nothing is accepting connections on it.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let client = DockerProxyClient::new(format!("http://{addr}")).unwrap();
        let reading = client
            .get_health("lancache-proxy", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Unreachable);
    }

    #[tokio::test]
    // get_health() must still work when the resolved timeout is "none" at
    // all (CURL_MAX_TIME=0's curl-parity meaning) -- confirms the `None`
    // branch of both apply_timeout() and bounded() is exercised, not just
    // reasoned about, against a real (fast, successful) response.
    async fn get_health_succeeds_with_no_timeout_configured() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\"}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client.get_health("lancache-proxy", None).await;
        assert_eq!(reading, HealthReading::Healthy);
    }

    #[tokio::test]
    // Verifies a 2xx restart response is reported as success -- the only
    // outcome check_and_maybe_restart's Action::Restart branch relies on
    // to decide whether to log a "restart call failed" warning.
    async fn restart_reports_success_from_2xx_response() {
        let base_url =
            serve_one_response("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(
            client
                .restart("lancache-proxy", Some(Duration::from_secs(2)))
                .await
        );
    }

    #[tokio::test]
    // Confirms the probe requires the real Docker /_ping payload ("OK"),
    // not merely a 2xx status -- this is the fix for a gateway that
    // answers headers successfully but never finishes the body: consuming
    // and checking the body content is what would catch that stall.
    async fn ping_reports_success_from_plain_ok_body() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(client.ping(Some(Duration::from_secs(2))).await);
    }

    #[tokio::test]
    // A 2xx response whose body is NOT the expected "OK" (corrupted,
    // truncated, or simply wrong) must not be reported healthy -- this is
    // exactly the distinction a status-code-only check would miss.
    async fn ping_rejects_2xx_response_with_wrong_body() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nWRONG",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(!client.ping(Some(Duration::from_secs(2))).await);
    }
}
