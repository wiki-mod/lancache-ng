//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: watchdog health loop, restarts and status.json.
//! Why: one daemon keeps core services up, reports health.
//! From: Issue #842 | PR #1858

use std::collections::HashMap;
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use lancache_common::config::{self, DhcpMode, env_opt, non_empty, parse_bool};
use lancache_common::{DiskHealth, DiskInfo, ServiceHealth, WatchdogStatus, write_file_atomic};
use serde::Deserialize;

// What: decimal knob within [min, max], else a fallback.
// Why: junk must not crash; a floor stops busy loops.
fn parse_uint(
    raw: Option<&str>,
    name: &str,
    default: u64,
    min: u64,
    max: u64,
) -> (u64, Vec<String>) {
    let Some(raw) = non_empty(raw) else {
        return (default, Vec::new());
    };
    let fallback = |reason: &str| {
        (
            default,
            vec![format!(
                "Invalid {name}={raw}{reason}; using default {default}"
            )],
        )
    };
    if !raw.bytes().all(|b| b.is_ascii_digit()) {
        return fallback("");
    }
    match raw.parse::<u64>() {
        Ok(v) if v > max => fallback(" (out of range)"),
        Ok(v) if v < min => (
            min,
            vec![format!(
                "{name}={raw} is below the supported minimum ({min}); using {min}"
            )],
        ),
        Ok(v) => (v, Vec::new()),
        Err(_) => fallback(" (out of range)"),
    }
}

// What: curl-style seconds; 0 means no timeout (None).
// Why: fractions stay valid; 0 must not time out at once.
fn parse_curl_timeout(
    raw: Option<&str>,
    name: &str,
    default_secs: u64,
) -> (Option<Duration>, Vec<String>) {
    let default = Some(Duration::from_secs(default_secs));
    let Some(raw) = non_empty(raw) else {
        return (default, Vec::new());
    };
    let invalid = |reason: &str| {
        (
            default,
            vec![format!(
                "Invalid {name}={raw}{reason}; using default {default_secs}"
            )],
        )
    };
    match raw.parse::<f64>() {
        Ok(0.0) => (None, Vec::new()),
        Ok(secs) if secs.is_finite() && secs > 0.0 => match Duration::try_from_secs_f64(secs) {
            Ok(duration) => (Some(duration), Vec::new()),
            Err(_) => invalid(" (out of range)"),
        },
        _ => invalid(""),
    }
}

// What: fail on a CONTAINER_* override that renames one.
// Why: the socket-proxy policy knows the fixed names only.
// From: Issue #849 | PR #1858
fn check_container_overrides(
    ssl_enabled: bool,
    overrides: [Option<&str>; 4],
) -> Result<(), String> {
    let [proxy, dns_standard, dns_ssl, nats] = overrides;
    let checks = [
        ("CONTAINER_PROXY", proxy, config::CONTAINER_PROXY, true),
        (
            "CONTAINER_DNS_STANDARD",
            dns_standard,
            config::CONTAINER_DNS_STANDARD,
            true,
        ),
        (
            "CONTAINER_DNS_SSL",
            dns_ssl,
            config::CONTAINER_DNS_SSL,
            ssl_enabled,
        ),
        ("CONTAINER_NATS", nats, config::CONTAINER_NATS, true),
    ];
    for (var, value, expected, active) in checks {
        if let Some(got) = non_empty(value)
            && active
            && got != expected
        {
            return Err(format!(
                "FATAL: {var}={got} is not supported (expected '{expected}'). The docker-socket-proxy allowlist and the Admin UI know only this fixed name. Revert {var} to the default."
            ));
        }
    }
    Ok(())
}

// What: CACHE_DIR, else the legacy pair, else the default.
// Why: a disagreeing legacy pair is fatal, never guessed.
fn resolve_cache_dir(
    cache_dir: Option<&str>,
    cache_dir_standard: Option<&str>,
    cache_dir_ssl: Option<&str>,
) -> Result<String, String> {
    if let Some(dir) = non_empty(cache_dir) {
        return Ok(dir.to_string());
    }
    match (non_empty(cache_dir_standard), non_empty(cache_dir_ssl)) {
        (Some(std), Some(ssl)) if std != ssl => Err(format!(
            "FATAL: CACHE_DIR_STANDARD={std} and CACHE_DIR_SSL={ssl} point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
        )),
        (Some(dir), _) | (None, Some(dir)) => Ok(dir.to_string()),
        (None, None) => Ok("/var/cache/lancache".to_string()),
    }
}

// What: typed Docker health plus watchdog's own outcomes.
// Why: only Healthy and Unhealthy move a failure counter.
#[derive(Debug, Clone, PartialEq, Eq)]
enum HealthReading {
    Healthy,
    Unhealthy,
    Starting,
    // What: Docker reports no health status at all.
    // Why: a valid answer, unlike an unreachable proxy.
    None,
    // What: no reading at all (network, timeout, non-2xx).
    // Why: not a Docker-reported state.
    Unreachable,
    // What: an unknown Docker health string, verbatim.
    // Why: never coerce it into a known variant.
    Other(String),
    // What: healthy, but the check printed DEGRADED: text.
    // Why: reduced guarantees must stay visible (ntp).
    Degraded,
}

impl HealthReading {
    // What: raw health status (or "none") to a reading.
    // Why: no answer at all uses Unreachable instead.
    fn from_docker_status(raw: &str) -> Self {
        match raw {
            "healthy" => Self::Healthy,
            "unhealthy" => Self::Unhealthy,
            "starting" => Self::Starting,
            "none" => Self::None,
            other => Self::Other(other.to_string()),
        }
    }

    // What: a reading from one docker inspect JSON body.
    // Why: Degraded refines healthy, never replaces it.
    // From: Issue #1296
    fn from_inspect(body: &serde_json::Value) -> Self {
        let status = body
            .pointer("/State/Health/Status")
            .and_then(|v| v.as_str())
            .unwrap_or("none");
        if status == "healthy" && has_degraded_marker(body) {
            return Self::Degraded;
        }
        Self::from_docker_status(status)
    }

    // What: the status.json health string of a reading.
    // Why: the ui shows it verbatim; keep values stable.
    fn as_status_str(&self) -> &str {
        match self {
            Self::Healthy => "healthy",
            Self::Unhealthy => "unhealthy",
            Self::Starting => "starting",
            Self::None => "none",
            Self::Unreachable => "unreachable",
            Self::Other(s) => s,
            Self::Degraded => "degraded",
        }
    }

    // What: card color; unknown yellow, Degraded amber.
    // Why: dashboard.html matches these exact color names.
    // From: Issue #1296
    fn color(&self) -> &'static str {
        match self {
            Self::Healthy => "green",
            Self::Unhealthy => "red",
            Self::Starting | Self::None | Self::Unreachable | Self::Other(_) => "yellow",
            Self::Degraded => "amber",
        }
    }

    // What: true if an alert-only service is not failing.
    // Why: Degraded is known; Other is treated as a fault.
    fn is_alert_ok(&self) -> bool {
        matches!(
            self,
            Self::Healthy | Self::Starting | Self::None | Self::Degraded
        )
    }

    fn service_health(&self, failures: u32) -> ServiceHealth {
        ServiceHealth {
            status: self.color().to_string(),
            health: self.as_status_str().to_string(),
            failures,
        }
    }
}

// What: true if the last check run printed DEGRADED:.
// Why: only the newest log entry counts; old ones expire.
// From: Issue #1296
fn has_degraded_marker(body: &serde_json::Value) -> bool {
    body.pointer("/State/Health/Log")
        .and_then(|log| log.as_array())
        .and_then(|log| log.last())
        .and_then(|entry| entry.get("Output"))
        .and_then(|output| output.as_str())
        .is_some_and(|output| output.lines().any(|l| l.starts_with("DEGRADED: ")))
}

// What: consecutive failures of one restartable service.
// Why: a restart fires only after RESTART_AFTER misses.
#[derive(Debug, Default, Clone, Copy)]
struct FailureCounter(u32);

// What: what the loop logs or does after one reading.
// Why: None covers steady health and all inert readings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    None,
    Unhealthy { count: u32, threshold: u32 },
    // What: restart, then the counter resets to 0.
    // Why: reset even if the restart call itself fails.
    Restart { threshold: u32 },
    // What: first healthy reading after a nonzero count.
    // Why: a steady healthy cycle must not log RECOVERED.
    Recovered,
}

impl FailureCounter {
    // What: record a reading and return its Action.
    // Why: only Unhealthy counts up; Healthy resets to 0.
    fn record(&mut self, reading: &HealthReading, restart_after: u32) -> Action {
        match reading {
            HealthReading::Unhealthy => {
                self.0 = self.0.saturating_add(1);
                if self.0 >= restart_after {
                    self.0 = 0;
                    Action::Restart {
                        threshold: restart_after,
                    }
                } else {
                    Action::Unhealthy {
                        count: self.0,
                        threshold: restart_after,
                    }
                }
            }
            HealthReading::Healthy => {
                let recovered = self.0 > 0;
                self.0 = 0;
                if recovered {
                    Action::Recovered
                } else {
                    Action::None
                }
            }
            // What: inert readings keep the counter.
            // Why: Degraded is healthy; never restart it.
            _ => Action::None,
        }
    }
}

// What: failure count of an alert-only probe.
// Why: watchdog must not restart these; it only reports.
#[derive(Debug, Default, Clone, Copy)]
struct AlertCounter(u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AlertAction {
    None,
    // What: reachable again after prior failures.
    // Why: one RECOVERED line per outage, not per cycle.
    Recovered,
    Unreachable { count: u32 },
}

impl AlertCounter {
    fn record(&mut self, reachable: bool) -> AlertAction {
        if reachable {
            let recovered = self.0 > 0;
            self.0 = 0;
            if recovered {
                AlertAction::Recovered
            } else {
                AlertAction::None
            }
        } else {
            self.0 = self.0.saturating_add(1);
            AlertAction::Unreachable { count: self.0 }
        }
    }
}

// What: run fut under timeout; None means no bound.
// Why: the bound must cover headers and body together.
async fn bounded<T>(
    timeout: Option<Duration>,
    fut: impl std::future::Future<Output = T>,
) -> Option<T> {
    match timeout {
        Some(t) => tokio::time::timeout(t, fut).await.ok(),
        None => Some(fut.await),
    }
}

// What: client for the allowlisted Docker calls.
// Why: restart needs a longer budget than health reads.
struct DockerProxyClient {
    client: reqwest::Client,
    base_url: String,
}

impl DockerProxyClient {
    fn new(base_url: String) -> reqwest::Result<Self> {
        Ok(Self {
            // What: never follow a redirect.
            // Why: a 3xx could reach an ungranted path.
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            base_url,
        })
    }

    // What: send a request; Some only for a 2xx answer.
    // Why: every failure collapses to None for the callers.
    async fn request(&self, method: reqwest::Method, path: &str) -> Option<reqwest::Response> {
        let url = format!("{}{path}", self.base_url);
        let response = self.client.request(method, url).send().await.ok()?;
        response.status().is_success().then_some(response)
    }

    async fn inspect(&self, name: &str, timeout: Option<Duration>) -> Option<serde_json::Value> {
        bounded(timeout, async {
            self.request(reqwest::Method::GET, &format!("/containers/{name}/json"))
                .await?
                .json()
                .await
                .ok()
        })
        .await
        .flatten()
    }

    // What: POST one container action; true on 2xx.
    // Why: a failed action is only logged, never counted.
    async fn post_ok(&self, path: &str, timeout: Option<Duration>) -> bool {
        bounded(timeout, async {
            self.request(reqwest::Method::POST, path).await.is_some()
        })
        .await
        .unwrap_or(false)
    }

    async fn get_health(&self, name: &str, timeout: Option<Duration>) -> HealthReading {
        match self.inspect(name, timeout).await {
            Some(body) => HealthReading::from_inspect(&body),
            None => HealthReading::Unreachable,
        }
    }

    async fn restart(&self, name: &str, timeout: Option<Duration>) -> bool {
        self.post_ok(&format!("/containers/{name}/restart?t=2"), timeout)
            .await
    }

    async fn start(&self, name: &str, timeout: Option<Duration>) -> bool {
        self.post_ok(&format!("/containers/{name}/start"), timeout)
            .await
    }

    async fn stop(&self, name: &str, timeout: Option<Duration>) -> bool {
        self.post_ok(&format!("/containers/{name}/stop"), timeout)
            .await
    }

    // What: whether a container runs now; None if unknown.
    // Why: reconcile skips a tick, never assumes a state.
    // From: Issue #1437
    async fn is_running(&self, name: &str, timeout: Option<Duration>) -> Option<bool> {
        self.inspect(name, timeout)
            .await?
            .pointer("/State/Running")
            .and_then(|v| v.as_bool())
    }

    // What: GET /_ping; true only for the body "OK".
    // Why: a 200 stalling before the body must fail.
    async fn ping(&self, timeout: Option<Duration>) -> bool {
        let body = bounded(timeout, async {
            self.request(reqwest::Method::GET, "/_ping")
                .await?
                .text()
                .await
                .ok()
        })
        .await
        .flatten();
        matches!(body.as_deref().map(str::trim), Some("OK"))
    }
}

// What: operator-requested run state of a service.
// Why: written by the ui dock; lowercase in the JSON file.
// From: Issue #1437
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
enum DesiredRunState {
    Running,
    Stopped,
}

// What: sparse override map; an absent key is no opinion.
// Why: a stale target must not fight a mode switch.
// From: Issue #1437
#[derive(Debug, Clone, Default, Deserialize)]
struct DesiredState {
    #[serde(default)]
    dhcp: Option<DesiredRunState>,
    #[serde(default)]
    ntp: Option<DesiredRunState>,
}

// What: desired-state.json; any read failure is no opinion.
// Why: a read glitch must never stop the main loop.
// From: Issue #1437
fn read_desired_state(path: &Path) -> DesiredState {
    fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
}

// What: UTC time as YYYY-MM-DDTHH:MM:SSZ, no fractions.
// Why: status.json's `updated` format is a fixed contract.
fn format_updated_timestamp(now: time::OffsetDateTime) -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    now.to_offset(time::UtcOffset::UTC)
        .format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

// What: df -P use% of dir as green/yellow/red, or unknown.
// Why: same rounding as df; -P keeps one line per mount.
fn disk_info(dir: &Path, warn_pct: u32, alarm_pct: u32) -> DiskHealth {
    if !dir.is_dir() {
        return DiskHealth {
            pct: 0,
            status: "unknown".to_string(),
        };
    }
    let pct = df_percent_full(dir).unwrap_or(0);
    let status = if pct >= alarm_pct {
        "red"
    } else if pct >= warn_pct {
        "yellow"
    } else {
        "green"
    };
    DiskHealth {
        pct,
        status: status.to_string(),
    }
}

// What: Use% field of `df -P <dir>`, or None on failure.
// Why: disk_info treats every failure uniformly as 0.
fn df_percent_full(dir: &Path) -> Option<u32> {
    let output = Command::new("df").arg("-P").arg(dir).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let field = stdout.lines().nth(1)?.split_whitespace().nth(4)?;
    field.trim_end_matches('%').parse::<u32>().ok()
}

// What: containers watchdog only alerts on, never restarts.
// Why: dhcp/ntp restarts could race their config rollback.
// From: Issue #842
fn resolve_alert_only_targets(
    dhcp_mode: DhcpMode,
    logging_enabled: bool,
    ntp_enabled: bool,
) -> Vec<&'static str> {
    // What: ui always; the rest follow their gates.
    // Why: an off service must not raise an alarm.
    let mut targets = vec![config::CONTAINER_UI];
    targets.extend(dhcp_mode.container());
    if logging_enabled {
        targets.push(config::CONTAINER_SYSLOG);
    }
    if ntp_enabled {
        targets.push(config::CONTAINER_NTP);
    }
    targets
}

// What: dhcp/ntp targets reconcile_desired_state acts on.
// Why: only provisioned services are reconciled.
// From: Issue #1437
fn desired_state_targets(
    dhcp_mode: DhcpMode,
    ntp_enabled: bool,
) -> Vec<(&'static str, &'static str)> {
    let mut targets = Vec::new();
    if let Some(container) = dhcp_mode.container() {
        targets.push(("dhcp", container));
    }
    if ntp_enabled {
        targets.push(("ntp", config::CONTAINER_NTP));
    }
    targets
}

// What: starts/stops one service to its desired state.
// Why: acts on diff; an absent entry is no opinion.
// From: Issue #1437
async fn reconcile_one(
    client: &DockerProxyClient,
    label: &str,
    container_name: &str,
    desired: Option<DesiredRunState>,
    timeout: Option<Duration>,
    action_timeout: Option<Duration>,
) {
    let Some(desired) = desired else {
        return;
    };
    let should_run = desired == DesiredRunState::Running;
    let Some(running) = client.is_running(container_name, timeout).await else {
        return;
    };
    if should_run && !running {
        log(&format!(
            "STARTING {container_name} ({label}: desired state is running)"
        ));
        if !client.start(container_name, action_timeout).await {
            log_err(&format!("WARNING: start call failed for {container_name}"));
        }
    } else if !should_run && running {
        log(&format!(
            "STOPPING {container_name} ({label}: desired state is stopped)"
        ));
        if !client.stop(container_name, action_timeout).await {
            log_err(&format!("WARNING: stop call failed for {container_name}"));
        }
    }
}

// What: reconcile DHCP/NTP to the operator's desired state.
// Why: watchdog is the sole actor for these two services.
// From: Issue #1437
async fn reconcile_desired_state(client: &DockerProxyClient, settings: &Settings) {
    let desired = read_desired_state(&settings.desired_state_file);
    for (label, container_name) in desired_state_targets(settings.dhcp_mode, settings.ntp_enabled) {
        let state = if label == "dhcp" {
            desired.dhcp
        } else {
            desired.ntp
        };
        reconcile_one(
            client,
            label,
            container_name,
            state,
            settings.curl_max_time,
            settings.curl_max_time_restart,
        )
        .await;
    }
}

// What: HH:MM:SS of the "[watchdog] HH:MM:SS msg" lines.
// Why: operators grep the docker logs for this exact shape.
fn timestamp_hms() -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[hour]:[minute]:[second]");
    time::OffsetDateTime::now_utc()
        .format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

// What: WATCHDOG_LOG_FILE opened once for append, or none.
// Why: fluent-bit tails the file; compose runs no tee.
// From: Issue #1683 | PR #1858
fn log_file() -> Option<&'static Mutex<fs::File>> {
    static FILE: OnceLock<Option<Mutex<fs::File>>> = OnceLock::new();
    FILE.get_or_init(|| {
        let path = env_opt("WATCHDOG_LOG_FILE")?;
        let opened = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o640)
            .open(&path);
        match opened {
            Ok(file) => Some(Mutex::new(file)),
            Err(e) => {
                eprintln!(
                    "[watchdog] {} WARNING: cannot open {path}: {e}",
                    timestamp_hms()
                );
                None
            }
        }
    })
    .as_ref()
}

// What: a line to its stream and to the log file, if any.
// Why: a failed file write is shown once, never silent.
// From: Issue #1683 | PR #1858
fn emit(line: &str, to_stderr: bool) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    if to_stderr {
        eprintln!("{line}");
    } else {
        println!("{line}");
    }
    let Some(file) = log_file() else {
        return;
    };
    let written = match file.lock() {
        Ok(mut f) => writeln!(f, "{line}").map_err(|e| e.to_string()),
        Err(e) => Err(e.to_string()),
    };
    if let Err(e) = written
        && !WARNED.swap(true, Ordering::Relaxed)
    {
        eprintln!(
            "[watchdog] {} WARNING: cannot write the log file: {e}",
            timestamp_hms()
        );
    }
}

fn log(msg: &str) {
    emit(&format!("[watchdog] {} {msg}", timestamp_hms()), false);
}

fn log_err(msg: &str) {
    emit(&format!("[watchdog] {} {msg}", timestamp_hms()), true);
}

// What: startup settings, read once from the environment.
// Why: a deployment change recreates this container.
struct Settings {
    docker_proxy_url: String,
    check_interval: Duration,
    restart_after: u32,
    // What: None means no timeout, like curl --max-time 0.
    // Why: ZERO would mean "instant" to bounded().
    curl_max_time: Option<Duration>,
    curl_max_time_restart: Option<Duration>,
    disk_warn_pct: u32,
    disk_alarm_pct: u32,
    status_file: PathBuf,
    // What: read fresh every loop iteration, not once.
    // Why: a dock action must apply without a restart.
    // From: Issue #1437
    desired_state_file: PathBuf,
    cache_dir: PathBuf,
    ssl_enabled: bool,
    dhcp_mode: DhcpMode,
    logging_enabled: bool,
    ntp_enabled: bool,
}

fn load_settings() -> Settings {
    let env = env_opt;
    let warn_all = |warnings: Vec<String>| warnings.iter().for_each(|w| log(w));

    let (interval, warnings) = parse_uint(
        env("CHECK_INTERVAL").as_deref(),
        "CHECK_INTERVAL",
        30,
        1,
        u64::MAX,
    );
    warn_all(warnings);
    let (restart_after, warnings) = parse_uint(
        env("RESTART_AFTER").as_deref(),
        "RESTART_AFTER",
        3,
        1,
        u64::from(u32::MAX),
    );
    warn_all(warnings);
    let (curl_max_time, warnings) =
        parse_curl_timeout(env("CURL_MAX_TIME").as_deref(), "CURL_MAX_TIME", 5);
    warn_all(warnings);
    let (curl_max_time_restart, warnings) = parse_curl_timeout(
        env("CURL_MAX_TIME_RESTART").as_deref(),
        "CURL_MAX_TIME_RESTART",
        30,
    );
    warn_all(warnings);
    let (disk_warn_pct, warnings) = parse_uint(
        env("DISK_WARN_PCT").as_deref(),
        "DISK_WARN_PCT",
        85,
        0,
        u64::from(u32::MAX),
    );
    warn_all(warnings);
    let (disk_alarm_pct, warnings) = parse_uint(
        env("DISK_ALARM_PCT").as_deref(),
        "DISK_ALARM_PCT",
        95,
        0,
        u64::from(u32::MAX),
    );
    warn_all(warnings);

    // What: a bool knob; junk is false, unset is default.
    // Why: keeps the contract these gates always had.
    let flag =
        |name: &str, default: bool| env(name).map_or(default, |v| parse_bool(&v).unwrap_or(false));
    let ssl_enabled = flag("SSL_ENABLED", true);

    if let Err(msg) = check_container_overrides(
        ssl_enabled,
        [
            env("CONTAINER_PROXY").as_deref(),
            env("CONTAINER_DNS_STANDARD").as_deref(),
            env("CONTAINER_DNS_SSL").as_deref(),
            env("CONTAINER_NATS").as_deref(),
        ],
    ) {
        log_err(&msg);
        std::process::exit(1);
    }

    let cache_dir = match resolve_cache_dir(
        env("CACHE_DIR").as_deref(),
        env("CACHE_DIR_STANDARD").as_deref(),
        env("CACHE_DIR_SSL").as_deref(),
    ) {
        Ok(dir) => PathBuf::from(dir),
        Err(msg) => {
            log_err(&msg);
            std::process::exit(1);
        }
    };

    Settings {
        docker_proxy_url: env("DOCKER_PROXY_URL")
            .unwrap_or_else(|| "http://docker-socket-proxy:2375".to_string()),
        check_interval: Duration::from_secs(interval),
        restart_after: restart_after as u32,
        curl_max_time,
        curl_max_time_restart,
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file: env("STATUS_FILE").map_or_else(
            || PathBuf::from("/var/run/watchdog/status.json"),
            PathBuf::from,
        ),
        desired_state_file: env("DESIRED_STATE_FILE")
            .map_or_else(|| PathBuf::from("/data/desired-state.json"), PathBuf::from),
        cache_dir,
        ssl_enabled,
        // What: an unset DHCP_MODE means disabled.
        // Why: no alert for a DHCP container never run.
        dhcp_mode: DhcpMode::parse(&env("DHCP_MODE").unwrap_or_default(), false),
        // What: LOGGING_ENABLED gates the syslog container.
        // Why: SYSLOG_ENABLED gates retention only.
        logging_enabled: flag("LOGGING_ENABLED", false),
        ntp_enabled: flag("NTP_ENABLED", false),
    }
}

#[tokio::main]
async fn main() {
    let settings = load_settings();
    let client = DockerProxyClient::new(settings.docker_proxy_url.clone())
        .expect("building the reqwest client must not fail (no invalid static config)");

    // What: restart-capable services, netdata included.
    // Why: dns-ssl is absent when SSL mode is off.
    let mut monitored = vec![config::CONTAINER_PROXY, config::CONTAINER_DNS_STANDARD];
    if settings.ssl_enabled {
        monitored.push(config::CONTAINER_DNS_SSL);
    }
    monitored.extend([config::CONTAINER_NATS, config::CONTAINER_NETDATA]);

    let mut failure_counters: HashMap<&str, FailureCounter> = monitored
        .iter()
        .map(|name| (*name, FailureCounter::default()))
        .collect();
    let mut docker_proxy_alert_counter = AlertCounter::default();

    // What: alert-only services keep their own counters.
    // Why: an outage must stay visible without any restart.
    let alert_only_targets = resolve_alert_only_targets(
        settings.dhcp_mode,
        settings.logging_enabled,
        settings.ntp_enabled,
    );
    let mut alert_only_counters: HashMap<&str, AlertCounter> = alert_only_targets
        .iter()
        .map(|name| (*name, AlertCounter::default()))
        .collect();

    log(&format!(
        "Watchdog started. Monitoring: {} (SSL_ENABLED={}); alert-only probe: {}; alert-only monitored: {}",
        monitored.join(" "),
        u8::from(settings.ssl_enabled),
        config::CONTAINER_DOCKER_SOCKET_PROXY,
        if alert_only_targets.is_empty() {
            "none".to_string()
        } else {
            alert_only_targets.join(" ")
        },
    ));
    log(&format!(
        "Cache directory: {}",
        settings.cache_dir.display()
    ));
    log(&format!(
        "Interval: {}s | Restart after: {} | Disk warn: {}% alarm: {}%",
        settings.check_interval.as_secs(),
        settings.restart_after,
        settings.disk_warn_pct,
        settings.disk_alarm_pct,
    ));

    loop {
        // What: apply the dhcp/ntp overrides first.
        // Why: the health report must reflect the result.
        // From: Issue #1437
        reconcile_desired_state(&client, &settings).await;

        let mut services_status: HashMap<String, ServiceHealth> = HashMap::new();

        for name in &monitored {
            let reading = client.get_health(name, settings.curl_max_time).await;
            let counter = failure_counters
                .get_mut(name)
                .expect("every monitored service has a counter");

            match counter.record(&reading, settings.restart_after) {
                Action::None => {}
                Action::Unhealthy { count, threshold } => {
                    log(&format!("UNHEALTHY {name} ({count}/{threshold})"));
                }
                Action::Restart { threshold } => {
                    log(&format!("UNHEALTHY {name} ({threshold}/{threshold})"));
                    log(&format!("RESTARTING {name}"));
                    if !client.restart(name, settings.curl_max_time_restart).await {
                        log(&format!("WARNING: restart call failed for {name}"));
                    }
                }
                Action::Recovered => {
                    log(&format!("RECOVERED {name}"));
                }
            }

            services_status.insert((*name).to_string(), reading.service_health(counter.0));
        }

        // What: the Docker proxy is alert-only.
        // Why: it cannot restart its own Docker channel.
        let reachable = client.ping(settings.curl_max_time).await;
        let proxy_name = config::CONTAINER_DOCKER_SOCKET_PROXY;
        match docker_proxy_alert_counter.record(reachable) {
            AlertAction::None => {}
            AlertAction::Recovered => log(&format!("RECOVERED {proxy_name}")),
            AlertAction::Unreachable { count } => log(&format!(
                "UNHEALTHY {proxy_name} ({count} consecutive failures) -- alert only, watchdog cannot restart its own Docker API channel"
            )),
        }
        let proxy_reading = if reachable {
            HealthReading::Healthy
        } else {
            HealthReading::Unhealthy
        };
        services_status.insert(
            proxy_name.to_string(),
            proxy_reading.service_health(docker_proxy_alert_counter.0),
        );

        for name in &alert_only_targets {
            let reading = client.get_health(name, settings.curl_max_time).await;
            let counter = alert_only_counters
                .get_mut(name)
                .expect("every alert-only target has a counter");
            match counter.record(reading.is_alert_ok()) {
                AlertAction::None => {}
                AlertAction::Recovered => log(&format!("RECOVERED {name}")),
                AlertAction::Unreachable { count } => log(&format!(
                    "UNHEALTHY {name} ({count} consecutive failures) -- alert only, watchdog does not restart this service"
                )),
            }
            services_status.insert((*name).to_string(), reading.service_health(counter.0));
        }

        let watchdog_status = WatchdogStatus {
            updated: format_updated_timestamp(time::OffsetDateTime::now_utc()),
            services: services_status,
            disk: DiskInfo {
                cache: disk_info(
                    &settings.cache_dir,
                    settings.disk_warn_pct,
                    settings.disk_alarm_pct,
                ),
            },
        };
        // What: a failed status write exits the process.
        // Why: compose restarts on exit, not on red health.
        let body = serde_json::to_string_pretty(&watchdog_status)
            .expect("WatchdogStatus has only serializable fields");
        if let Err(e) = write_file_atomic(&settings.status_file, body.as_bytes()) {
            log_err(&format!(
                "ERROR: failed to write {}: {e}",
                settings.status_file.display()
            ));
            std::process::exit(1);
        }

        tokio::time::sleep(settings.check_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: knobs parse, floor and fall back.
    // Why: a bad knob must not busy-loop or restart.
    #[test]
    fn parse_uint_floors_falls_back_and_bounds() {
        assert_eq!(parse_uint(None, "X", 30, 1, u64::MAX), (30, vec![]));
        assert_eq!(parse_uint(Some(""), "X", 30, 1, u64::MAX), (30, vec![]));
        assert_eq!(parse_uint(Some("12"), "X", 30, 1, u64::MAX), (12, vec![]));
        for bad in ["abc", "-5"] {
            let (value, warnings) = parse_uint(Some(bad), "X", 30, 1, u64::MAX);
            assert_eq!(value, 30);
            assert!(warnings.iter().any(|w| w.contains(&format!("X={bad}"))));
        }
        for zero in ["0", "00"] {
            let (value, warnings) = parse_uint(Some(zero), "X", 30, 1, u64::MAX);
            assert_eq!(value, 1);
            assert!(warnings.iter().any(|w| w.contains(&format!("X={zero} "))));
        }
        let max = u64::from(u32::MAX);
        assert_eq!(parse_uint(Some("4294967295"), "X", 3, 1, max).0, max);
        let (value, warnings) = parse_uint(Some("4294967296"), "X", 3, 1, max);
        assert_eq!(value, 3);
        assert!(warnings.iter().any(|w| w.contains("X=4294967296")));
        assert_eq!(
            parse_uint(Some("99999999999999999999"), "X", 3, 1, max).0,
            3
        );
    }

    // What: curl timeouts keep fractions; 0 is unbounded.
    // Why: 0 must not time out at once; junk falls back.
    #[test]
    fn parse_curl_timeout_handles_zero_fractions_and_garbage() {
        assert_eq!(parse_curl_timeout(Some("0"), "T", 5), (None, vec![]));
        assert_eq!(
            parse_curl_timeout(Some("2.5"), "T", 5).0,
            Some(Duration::from_secs_f64(2.5))
        );
        assert_eq!(
            parse_curl_timeout(None, "T", 5).0,
            Some(Duration::from_secs(5))
        );
        for bad in ["bogus", "-1.5", "1e999"] {
            let (timeout, warnings) = parse_curl_timeout(Some(bad), "T", 5);
            assert_eq!(timeout, Some(Duration::from_secs(5)));
            assert!(warnings.iter().any(|w| w.contains(&format!("T={bad}"))));
        }
    }

    // What: renamed CONTAINER_* overrides are fatal.
    // Why: the socket-proxy policy knows the fixed names.
    // From: Issue #849
    #[test]
    fn container_overrides_reject_renames_only_when_active() {
        assert!(check_container_overrides(true, [None; 4]).is_ok());
        assert!(check_container_overrides(true, [Some(""); 4]).is_ok());
        for slot in 0..4 {
            let mut overrides = [None; 4];
            overrides[slot] = Some("renamed");
            assert!(check_container_overrides(true, overrides).is_err());
        }
        assert!(check_container_overrides(false, [None, None, Some("renamed"), None]).is_ok());
    }

    // What: CACHE_DIR wins; a split legacy pair is fatal.
    // Why: the real cache filesystem must never be guessed.
    #[test]
    fn cache_dir_resolution_orders_and_rejects_conflicts() {
        let pick = |a, b, c| resolve_cache_dir(a, b, c);
        assert_eq!(pick(Some("/a"), Some("/b"), Some("/c")).unwrap(), "/a");
        assert_eq!(pick(None, Some("/b"), None).unwrap(), "/b");
        assert_eq!(pick(None, None, Some("/c")).unwrap(), "/c");
        assert_eq!(pick(None, Some("/s"), Some("/s")).unwrap(), "/s");
        assert_eq!(
            pick(Some(""), Some(""), Some("")).unwrap(),
            "/var/cache/lancache"
        );
        let err = pick(None, Some("/b"), Some("/c")).unwrap_err();
        assert!(err.contains("/b") && err.contains("/c"));
    }

    // What: health strings map; colors stay correct.
    // Why: unknown stays yellow; Degraded is amber.
    // From: Issue #1296
    #[test]
    fn health_reading_maps_statuses_and_colors() {
        assert_eq!(
            HealthReading::from_docker_status("weird"),
            HealthReading::Other("weird".to_string())
        );
        let colors = [
            (HealthReading::Healthy, "green"),
            (HealthReading::Unhealthy, "red"),
            (HealthReading::Starting, "yellow"),
            (HealthReading::None, "yellow"),
            (HealthReading::Unreachable, "yellow"),
            (HealthReading::Other("huh".into()), "yellow"),
            (HealthReading::Degraded, "amber"),
        ];
        for (reading, color) in colors {
            assert_eq!(reading.color(), color);
        }
        assert_eq!(HealthReading::Degraded.as_status_str(), "degraded");
    }

    // What: only Unhealthy/Healthy move the counter.
    // Why: restarting an unreachable service is unsafe.
    #[test]
    fn failure_counter_restarts_at_threshold_and_ignores_inert_readings() {
        for inert in [
            HealthReading::Starting,
            HealthReading::None,
            HealthReading::Unreachable,
            HealthReading::Other("huh".into()),
            HealthReading::Degraded,
        ] {
            let mut counter = FailureCounter(2);
            assert_eq!(counter.record(&inert, 3), Action::None);
            assert_eq!(counter.0, 2);
        }
        let mut counter = FailureCounter::default();
        let unhealthy = HealthReading::Unhealthy;
        assert_eq!(
            counter.record(&unhealthy, 3),
            Action::Unhealthy {
                count: 1,
                threshold: 3
            }
        );
        counter.record(&unhealthy, 3);
        assert_eq!(
            counter.record(&unhealthy, 3),
            Action::Restart { threshold: 3 }
        );
        assert_eq!(counter.0, 0);
        counter.0 = 2;
        assert_eq!(
            counter.record(&HealthReading::Healthy, 3),
            Action::Recovered
        );
        assert_eq!(counter.record(&HealthReading::Healthy, 3), Action::None);
    }

    // What: the alert counter climbs and recovers once.
    // Why: no restart may reset an alert-only count.
    // From: Issue #842
    #[test]
    fn alert_counter_climbs_and_recovers_once() {
        let mut counter = AlertCounter::default();
        assert_eq!(counter.record(false), AlertAction::Unreachable { count: 1 });
        assert_eq!(counter.record(false), AlertAction::Unreachable { count: 2 });
        assert_eq!(counter.record(true), AlertAction::Recovered);
        assert_eq!(counter.record(true), AlertAction::None);
        for ok in [
            HealthReading::Healthy,
            HealthReading::Starting,
            HealthReading::None,
            HealthReading::Degraded,
        ] {
            assert!(ok.is_alert_ok());
        }
        assert!(!HealthReading::Unhealthy.is_alert_ok());
        assert!(!HealthReading::Unreachable.is_alert_ok());
        assert!(!HealthReading::Other("huh".into()).is_alert_ok());
    }

    // What: targets follow the DHCP, logging and NTP gates.
    // Why: a gated service that is off must raise no alarm.
    // From: Issue #842
    #[test]
    fn alert_and_desired_targets_follow_the_gates() {
        assert_eq!(
            resolve_alert_only_targets(DhcpMode::Disabled, false, false),
            vec!["lancache-ui"]
        );
        assert_eq!(
            resolve_alert_only_targets(DhcpMode::Kea, true, true),
            vec![
                "lancache-ui",
                "lancache-dhcp",
                "lancache-syslog",
                "lancache-ntp"
            ]
        );
        assert!(desired_state_targets(DhcpMode::Disabled, false).is_empty());
        assert_eq!(
            desired_state_targets(DhcpMode::DnsmasqRelay, true),
            vec![("dhcp", "lancache-dhcp-proxy"), ("ntp", "lancache-ntp")]
        );
    }

    // What: the timestamp keeps its fixed UTC shape.
    // Why: status.json's `updated` field is a contract.
    #[test]
    fn updated_timestamp_has_the_fixed_shape() {
        let date = time::Date::from_calendar_date(2026, time::Month::January, 2).unwrap();
        let dt = date.with_hms(3, 4, 5).unwrap().assume_utc();
        assert_eq!(format_updated_timestamp(dt), "2026-01-02T03:04:05Z");
    }
}
