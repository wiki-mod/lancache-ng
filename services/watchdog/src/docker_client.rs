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

/// A thin wrapper around a `reqwest::Client` pointed at `DOCKER_PROXY_URL`.
/// One shared client (connection pooling is reqwest's default and costs
/// nothing extra here), with the timeout supplied per call -- matching
/// watchdog.sh's two distinct budgets (`CURL_MAX_TIME` for health/ping
/// reads, `CURL_MAX_TIME_RESTART` for the restart POST, since a restart
/// includes both Docker's stop grace period and the container's own
/// startup time; see watchdog.sh's `restart_container()` comment and issue
/// #1166 for why these two timeouts must not share one value).
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
    pub async fn get_health(&self, container_name: &str, timeout: Duration) -> HealthReading {
        let url = format!("{}/containers/{container_name}/json", self.base_url);
        let response = match self.client.get(&url).timeout(timeout).send().await {
            Ok(r) => r,
            Err(_) => return HealthReading::Unreachable,
        };
        if !response.status().is_success() {
            return HealthReading::Unreachable;
        }
        let body: serde_json::Value = match response.json().await {
            Ok(v) => v,
            Err(_) => return HealthReading::Unreachable,
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
    /// bash's `CURL_MAX_TIME_RESTART` is -- see #1166). Returns whether the
    /// call succeeded; the bash only logs a warning on failure and never
    /// feeds that failure back into the failure counter, so this
    /// deliberately returns a plain `bool` rather than a `Result` the
    /// caller might be tempted to propagate.
    pub async fn restart(&self, container_name: &str, timeout: Duration) -> bool {
        let url = format!("{}/containers/{container_name}/restart?t=2", self.base_url);
        match self.client.post(&url).timeout(timeout).send().await {
            Ok(response) => response.status().is_success(),
            Err(_) => false,
        }
    }

    /// watchdog.sh's `probe_docker_socket_proxy()`: `GET /_ping`. Already
    /// permitted by the allowlist's `safe_ping` ACL (the same one
    /// `get_health()` relies on), needs no new privilege. Docker's `/_ping`
    /// returns a bare `OK` string with no JSON body on success, so unlike
    /// `get_health()`, only the HTTP status matters here.
    pub async fn ping(&self, timeout: Duration) -> bool {
        let url = format!("{}/_ping", self.base_url);
        match self.client.get(&url).timeout(timeout).send().await {
            Ok(response) => response.status().is_success(),
            Err(_) => false,
        }
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
    // three tests.
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
    async fn get_health_parses_a_real_healthy_response() {
        // Deliberately no Content-Length header: relies on "Connection:
        // close" + the socket shutdown in serve_one_response() to
        // delimit the body (a real, RFC 7230-valid close-delimited
        // message), rather than a hand-counted byte length -- an earlier
        // version of this test hardcoded a wrong Content-Length and the
        // response body was silently never delivered to completion,
        // failing the test with a misleadingly plausible-looking
        // "Unreachable" result instead of an obviously-wrong byte count.
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\"}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-proxy", Duration::from_secs(2))
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
            .get_health("lancache-nats", Duration::from_secs(2))
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
            .get_health("does-not-exist", Duration::from_secs(2))
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
            .get_health("lancache-proxy", Duration::from_secs(2))
            .await;
        assert_eq!(reading, HealthReading::Unreachable);
    }

    #[tokio::test]
    async fn restart_reports_success_from_2xx_response() {
        let base_url =
            serve_one_response("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(
            client
                .restart("lancache-proxy", Duration::from_secs(2))
                .await
        );
    }

    #[tokio::test]
    async fn ping_reports_success_from_plain_ok_body() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOK",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(client.ping(Duration::from_secs(2)).await);
    }
}
