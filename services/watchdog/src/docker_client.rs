//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! HTTP client for the narrow subset of the Docker API
//! `scripts/untracked/docker-socket-proxy.sh`'s HAProxy allowlist actually permits:
//! reading a container's health/running-state JSON, restarting/starting/
//! stopping a container, and pinging docker-socket-proxy itself. Mirrors
//! watchdog.sh's `get_health()`/`restart_container()`/
//! `probe_docker_socket_proxy()` curl invocations, plus `start()`/`stop()`/
//! `is_running()` -- this crate's main loop is now the sole actor
//! reconciling `dhcp`/`ntp` against an operator-written desired-state
//! file, so it needs the start/stop verbs the allowlist already granted
//! this same `DOCKER_PROXY_URL` endpoint for those two services -- see
//! `main.rs`'s `reconcile_desired_state`).
//!
//! Deliberately plain `reqwest`, not `bollard` (the Docker SDK
//! `services/ui/src/docker_client.rs` uses): bollard's own client can issue
//! any Docker Engine API call, but this daemon must only ever hit the
//! narrow, explicitly allowlisted set of paths below -- a hand-rolled
//! client whose every method maps to one allowlisted path/verb pair makes
//! "watchdog cannot accidentally call an unallowlisted Docker endpoint"
//! true by construction (there is no method that would let it), rather
//! than true only by convention. That same "only these allowlisted paths"
//! guarantee is why the client below disables HTTP redirects entirely: a
//! misconfigured or compromised `docker-socket-proxy` (or an
//! operator-supplied `DOCKER_PROXY_URL`) returning a 3xx would otherwise
//! send reqwest's default client on to whatever arbitrary `Location` it
//! names, which would defeat exactly the "only these endpoints, never
//! anything else" property this module exists to guarantee. The bash
//! implementation never had this exposure: plain `curl` without `-L` never
//! follows redirects either. With redirects disabled, a 3xx response is
//! not an error to reqwest -- it is returned as an ordinary response whose
//! status is not `2xx`, so the existing `is_success()` checks below already
//! treat it the same as any other
//! failed/unreachable response.

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
            // No-redirect policy: see this module's own doc comment above
            // for why silently following a 3xx would defeat the "only
            // these allowlisted paths" guarantee this client exists to
            // provide.
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
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
    ///
    /// Issue #1296: when the real Status is "healthy", also checks the SAME
    /// already-fetched response body for a [`HealthReading::Degraded`]
    /// marker (see [`degraded_reason_from_health_log`]) before returning --
    /// no second request, no new docker-socket-proxy allowlist entry, since
    /// `.State.Health.Log` is already part of this exact JSON body. Only
    /// checked on a genuinely "healthy" Status: a stale marker left over in
    /// an old log entry must never override a real unhealthy/starting
    /// reading (see this function's own tests for that ordering).
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

    /// watchdog.sh's `restart_container()`: `POST
    /// /containers/<name>/restart?t=2` (`t=2` tells Docker to wait 2s for
    /// SIGTERM before SIGKILL, coordinated with `timeout` the same way the
    /// bash's `CURL_MAX_TIME_RESTART` is). Returns whether the call
    /// succeeded; the bash only logs a warning on failure and never feeds
    /// that failure back into the failure counter, so this deliberately
    /// returns a plain `bool` rather than a `Result` the caller might be
    /// tempted to propagate.
    ///
    /// Unlike `get_health`/`ping`, this method never reads a response body
    /// (`.send()` plus a status check is the whole exchange), so the
    /// specific "body can stall after headers arrive" race `bounded()` was
    /// built for does not apply here -- `apply_timeout()`'s own
    /// per-`send()` reqwest timeout already bounds this call on its own.
    /// The outer `bounded()` wrapper is kept anyway, purely for a uniform
    /// call shape across all three client methods; it applies the exact
    /// same `timeout` duration as `apply_timeout()`, starting at
    /// essentially the same instant, so it can only ever fire together
    /// with (not meaningfully before) reqwest's own timeout -- it does not
    /// shrink the 2s-stop-grace-period-plus-startup budget
    /// `CURL_MAX_TIME_RESTART` was sized for, and reintroduce the false
    /// "restart failed" positive that budget exists to avoid.
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
    ///
    /// `POST /containers/<name>/start`, already permitted by
    /// `scripts/untracked/docker-socket-proxy.sh`'s `safe_dhcp_action`/
    /// `safe_ntp_action` ACLs for exactly the two services this crate calls
    /// this on (`services/ui/src/docker_client.rs::start_service` already
    /// uses the identical endpoint for the same two services' settings-save
    /// path) -- no allowlist change needed. Same shape as `restart()`
    /// above: no response body read, so `bounded()` is kept only for a
    /// uniform call shape, not because the body-stall race applies here.
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
    ///
    /// `POST /containers/<name>/stop`, same allowlist coverage as
    /// `start()` above (`safe_dhcp_action`/`safe_ntp_action` permit both
    /// verbs on the same two container names).
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
    ///
    /// `GET /containers/<name>/json`, the identical allowlisted endpoint
    /// `get_health()` already uses (`safe_container_inspect`) -- extracts
    /// `.State.Running` instead of `.State.Health.Status`. A container can
    /// be running with no health check configured at all (`get_health()`
    /// would report `None` for it), so `Running` is the only field that
    /// reliably answers "should I call start or stop" regardless of
    /// whether the container has a `HEALTHCHECK`. Returns `None` (not
    /// `Some(false)`) on any failure to reach/parse this endpoint --
    /// `reconcile_desired_state` must skip acting this tick rather than
    /// risk calling `start()` on a container that is actually already
    /// running but merely unreachable through a flaky proxy right now.
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

    // Hand-rolled one-shot HTTP server: accepts exactly one connection,
    // discards the request, and writes back `response_bytes` verbatim.
    // Deliberately not a mocking crate dependency (this repository has none
    // today, see this module's own doc comment on why a hand-rolled client
    // was preferred over bollard for a similar minimalism reason) -- the
    // request shapes this client makes are simple enough that a raw TCP
    // responder is less machinery than pulling in wiremock/mockito for a
    // handful of tests.
    //
    // Takes an owned `impl Into<String>` rather than `&'static str` so a
    // caller can build the response body at runtime (e.g. embedding a
    // second ephemeral server's address in a `Location` header for the
    // redirect test below) -- a plain string literal still works at every
    // existing call site via `Into`.
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
