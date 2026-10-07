//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: reqwest client for the allowlisted Docker calls.
//! Why: one method per granted path; no redirects followed.

use std::time::Duration;

use crate::health::HealthReading;

/// What: run fut under timeout; None means no bound.
/// Why: reqwest's timeout may end at headers, not body.
async fn bounded<T>(
    timeout: Option<Duration>,
    fut: impl std::future::Future<Output = T>,
) -> Option<T> {
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
fn apply_timeout(
    builder: reqwest::RequestBuilder,
    timeout: Option<Duration>,
) -> reqwest::RequestBuilder {
    match timeout {
        Some(t) => builder.timeout(t),
        None => builder,
    }
}

/// What: shared client; the timeout is passed per call.
/// Why: restart needs a longer budget than health reads.
pub struct DockerProxyClient {
    client: reqwest::Client,
    base_url: String,
}

impl DockerProxyClient {
    pub fn new(base_url: impl Into<String>) -> reqwest::Result<Self> {
        Ok(Self {
            // What: never follow a redirect.
            // Why: a 3xx could reach an ungranted path.
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            base_url: base_url.into(),
        })
    }

    /// What: container health; Degraded only if healthy.
    /// Why: any request or parse failure reads Unreachable.
    /// From: Issue #1296
    pub async fn get_health(
        &self,
        container_name: &str,
        timeout: Option<Duration>,
    ) -> HealthReading {
        let url = format!("{}/containers/{container_name}/json", self.base_url);
        let body: Option<serde_json::Value> = bounded(timeout, async {
            let response = apply_timeout(self.client.get(&url), timeout)
                .send()
                .await
                .ok()?;
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
        if raw_status == "healthy"
            && let Some(reason) = degraded_reason_from_health_log(&body)
        {
            return HealthReading::Degraded(reason);
        }
        HealthReading::from_docker_status(raw_status)
    }

    /// What: POST restart?t=2; true on a 2xx answer.
    /// Why: a failed restart is only logged, never counted.
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

    /// What: starts a container via the socket-proxy allowlist
    /// Why: reconcile_desired_state acts on operator overrides
    /// From: Issue #1437
    pub async fn start(&self, container_name: &str, timeout: Option<Duration>) -> bool {
        let url = format!("{}/containers/{container_name}/start", self.base_url);
        let success = bounded(timeout, async {
            apply_timeout(self.client.post(&url), timeout)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success())
        })
        .await;
        success.unwrap_or(false)
    }

    /// What: stops a container via the socket-proxy allowlist
    /// Why: reconcile_desired_state acts on operator overrides
    /// From: Issue #1437
    pub async fn stop(&self, container_name: &str, timeout: Option<Duration>) -> bool {
        let url = format!("{}/containers/{container_name}/stop", self.base_url);
        let success = bounded(timeout, async {
            apply_timeout(self.client.post(&url), timeout)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success())
        })
        .await;
        success.unwrap_or(false)
    }

    /// What: reads whether a container is actually running now
    /// Why: reconcile_desired_state must not act on stale info
    /// From: Issue #1437
    pub async fn is_running(
        &self,
        container_name: &str,
        timeout: Option<Duration>,
    ) -> Option<bool> {
        let url = format!("{}/containers/{container_name}/json", self.base_url);
        let body: Option<serde_json::Value> = bounded(timeout, async {
            let response = apply_timeout(self.client.get(&url), timeout)
                .send()
                .await
                .ok()?;
            if !response.status().is_success() {
                return None;
            }
            response.json().await.ok()
        })
        .await
        .flatten();

        body.and_then(|b| b.pointer("/State/Running").and_then(|v| v.as_bool()))
    }

    /// What: GET /_ping; true only for the body "OK".
    /// Why: a 200 stalling before the body must fail.
    pub async fn ping(&self, timeout: Option<Duration>) -> bool {
        let url = format!("{}/_ping", self.base_url);
        let body: Option<String> = bounded(timeout, async {
            let response = apply_timeout(self.client.get(&url), timeout)
                .send()
                .await
                .ok()?;
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

/// Issue #1296: looks for a `DEGRADED: <reason>` line anywhere in the LAST
/// entry of `.State.Health.Log` (the most recent healthcheck run's own
/// captured stdout+stderr, already part of the `/containers/<name>/json`
/// body every `get_health()` call fetches -- see that function's own
/// comment). This is a deliberately generic, service-agnostic convention
/// (not hardcoded to any one container name): any service's healthcheck
/// command can opt into it by printing this exact prefix on a line of its
/// own output while still exiting 0, the same way `ntp`'s compose
/// healthcheck does (see `deploy/prod/docker-compose.yml`'s `ntp` service).
/// Only the LAST log entry is checked, not the whole history: a container
/// that recovered from a past degraded episode must not keep showing
/// amber forever because an old entry still contains the marker text --
/// Docker's own `Log` array is bounded (keeps the most recent 5 entries by
/// default) and already ordered oldest-to-newest, so `.last()` is exactly
/// "what did the most recent healthcheck run report."
fn degraded_reason_from_health_log(body: &serde_json::Value) -> Option<String> {
    const MARKER: &str = "DEGRADED: ";
    let output = body
        .pointer("/State/Health/Log")?
        .as_array()?
        .last()?
        .get("Output")?
        .as_str()?;
    output
        .lines()
        .find_map(|line| line.strip_prefix(MARKER))
        .map(|reason| reason.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    // What: one-shot raw TCP responder for client tests.
    // Why: simple requests need no mocking crate.
    async fn serve_one_response(response_bytes: impl Into<String>) -> String {
        let response_bytes = response_bytes.into();
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
    // Issue #1296: a "healthy" Status plus a `DEGRADED: ` line in the most
    // recent healthcheck run's own captured output must produce a
    // Degraded reading, not plain Healthy -- this is the exact real shape
    // `ntp`'s compose healthcheck now emits when CAP_SYS_TIME is denied.
    async fn get_health_detects_a_degraded_marker_in_the_healthcheck_log_output() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\",\"Log\":[{\"Output\":\"Reference ID    : 00000000 ()\\nDEGRADED: CAP_SYS_TIME denied -- clock not disciplined (issue #1296)\\n\"}]}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-ntp", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(
            reading,
            HealthReading::Degraded(
                "CAP_SYS_TIME denied -- clock not disciplined (issue #1296)".to_string()
            )
        );
    }

    #[tokio::test]
    // A stale `DEGRADED: ` marker sitting in an old/irrelevant log entry
    // must never override a genuinely non-healthy Status -- Degraded is
    // only ever a refinement OF "healthy," never a replacement for
    // "unhealthy"/"starting". Confirms the ordering in get_health() checks
    // Status first and only consults the log when Status is "healthy".
    async fn get_health_ignores_a_degraded_marker_when_status_is_not_healthy() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"unhealthy\",\"Log\":[{\"Output\":\"DEGRADED: leftover text\"}]}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-ntp", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Unhealthy);
    }

    #[tokio::test]
    // A plain "healthy" Status with ordinary healthcheck output (no marker
    // line at all) must still parse as plain Healthy -- confirms the new
    // degraded_reason_from_health_log() check is additive, not a
    // regression for every service that never uses this convention.
    async fn get_health_treats_ordinary_healthy_output_as_plain_healthy() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\",\"Log\":[{\"Output\":\"Reference ID    : ABCD1234 (some.pool.server)\\n\"}]}}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-ntp", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Healthy);
    }

    #[tokio::test]
    // What: no .State.Health reads as None.
    // Why: no HEALTHCHECK is not an unreachable proxy.
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
    // What: a non-2xx answer reads as Unreachable.
    // Why: a failed inspect is not a health state.
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
    // What: a 2xx restart answer is reported as success.
    // Why: main.rs logs a warning only when this is false.
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
    // What: 2xx from POST .../start is reported as success
    // Why: reconcile_desired_state's only success signal
    // From: Issue #1437
    async fn start_reports_success_from_2xx_response() {
        let base_url =
            serve_one_response("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(
            client
                .start("lancache-dhcp", Some(Duration::from_secs(2)))
                .await
        );
    }

    #[tokio::test]
    // What: 2xx from POST .../stop is reported as success
    // Why: reconcile_desired_state's only success signal
    // From: Issue #1437
    async fn stop_reports_success_from_2xx_response() {
        let base_url =
            serve_one_response("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert!(
            client
                .stop("lancache-ntp", Some(Duration::from_secs(2)))
                .await
        );
    }

    #[tokio::test]
    // What: a running container's State.Running parses as Some(true)
    // Why: reconcile_desired_state's start/stop decision depends on it
    // From: Issue #1437
    async fn is_running_parses_true_from_a_real_response() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Running\":true}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert_eq!(
            client
                .is_running("lancache-dhcp", Some(Duration::from_secs(2)))
                .await,
            Some(true)
        );
    }

    #[tokio::test]
    // What: a stopped container's State.Running parses as Some(false)
    // Why: this is the exact case reconcile_desired_state acts on
    // From: Issue #1437
    async fn is_running_parses_false_from_a_real_response() {
        let base_url = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Running\":false}}",
        )
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        assert_eq!(
            client
                .is_running("lancache-dhcp", Some(Duration::from_secs(2)))
                .await,
            Some(false)
        );
    }

    #[tokio::test]
    // What: an unreachable proxy yields None, not a guessed bool
    // Why: caller must skip acting this tick, never assume a state
    // From: Issue #1437
    async fn is_running_returns_none_when_unreachable() {
        let client = DockerProxyClient::new("http://127.0.0.1:1").unwrap();
        assert_eq!(
            client
                .is_running("lancache-dhcp", Some(Duration::from_millis(200)))
                .await,
            None
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

    #[tokio::test]
    // Regression test for the no-redirect policy documented on
    // DockerProxyClient::new(): a 3xx response must never be followed to
    // an arbitrary Location, since that would defeat the "only these
    // allowlisted paths" guarantee this module exists to provide. The
    // redirect target below is a real, otherwise-healthy server -- if the
    // client ever followed the redirect, this test would wrongly observe
    // HealthReading::Healthy instead of the expected Unreachable, proving
    // this is a real behavioral check and not just a status-code parse.
    async fn get_health_does_not_follow_a_redirect_response() {
        let redirect_target = serve_one_response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"State\":{\"Health\":{\"Status\":\"healthy\"}}}",
        )
        .await;
        let base_url = serve_one_response(format!(
            "HTTP/1.1 302 Found\r\nLocation: {redirect_target}/containers/lancache-proxy/json\r\nConnection: close\r\n\r\n"
        ))
        .await;
        let client = DockerProxyClient::new(base_url).unwrap();
        let reading = client
            .get_health("lancache-proxy", Some(Duration::from_secs(2)))
            .await;
        assert_eq!(reading, HealthReading::Unreachable);
    }
}
