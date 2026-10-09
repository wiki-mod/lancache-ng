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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use lancache_ng::config::{self, DhcpMode, OutOfRange, Uint, env_opt};
use lancache_ng::{
    DesiredRunState, DesiredState, DiskHealth, DiskInfo, DockerProxy, Place, ServiceHealth,
    WatchdogStatus, df, write_file,
};
use time::OffsetDateTime;

// What: seconds Docker waits for SIGTERM before SIGKILL.
// Why: stays inside the restart call's own curl budget.
const RESTART_GRACE_SECS: u32 = 2;

// What: startup settings, read once from the environment.
// Why: a deployment change recreates this container.
struct Settings {
    docker_proxy_url: String,
    check_interval: Duration,
    restart_after: u32,
    // What: None means no timeout, like curl --max-time 0.
    // Why: ZERO would mean "instant" to the proxy client.
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

// What: curl-style seconds; 0 means no timeout (None).
// Why: fractions stay valid; 0 must not time out at once.
fn curl_timeout(raw: Option<&str>, name: &str) -> Result<Option<Duration>, String> {
    let raw = raw.ok_or_else(|| format!("FATAL: {}.", config::not_set(name)))?;
    let invalid = |why: &str| format!("FATAL: invalid {name}={raw}{why}.");
    match raw.parse::<f64>() {
        Ok(0.0) => Ok(None),
        Ok(secs) if secs.is_finite() && secs > 0.0 => Duration::try_from_secs_f64(secs)
            .map(Some)
            .map_err(|_| invalid(" (out of range)")),
        _ => Err(invalid("")),
    }
}

// What: settings from an env reader, plus startup warnings.
// Why: Err is fatal; a reader arg keeps tests env-free.
// From: Issue #849 | PR #1858
fn load_settings(env: impl Fn(&str) -> Option<String>) -> Result<(Settings, Vec<String>), String> {
    let get = |name: &str| config::opt(&env, name);
    let mut warnings = Vec::new();
    let mut knob = |name: &'static str, min: u64, max: u64| -> Result<u64, String> {
        let spec = Uint {
            name,
            min,
            max,
            below: OutOfRange::Clamp,
            above: OutOfRange::Reject,
        };
        let (value, warning) = spec
            .parse(get(name).as_deref())
            .map_err(|e| format!("FATAL: {e}."))?;
        warnings.extend(warning);
        Ok(value)
    };
    let check_interval = knob("CHECK_INTERVAL", 1, u64::MAX)?;
    let restart_after = knob("RESTART_AFTER", 1, u32::MAX.into())?;
    let disk_warn_pct = knob("DISK_WARN_PCT", 0, u32::MAX.into())?;
    let disk_alarm_pct = knob("DISK_ALARM_PCT", 0, u32::MAX.into())?;
    let curl_max_time = curl_timeout(get("CURL_MAX_TIME").as_deref(), "CURL_MAX_TIME")?;
    let curl_max_time_restart = curl_timeout(
        get("CURL_MAX_TIME_RESTART").as_deref(),
        "CURL_MAX_TIME_RESTART",
    )?;

    // What: a value the env must supply; unset is fatal.
    // Why: watchdog.env and compose own it; no default.
    let need = |name: &str| config::need(&env, name).map_err(|e| format!("FATAL: {e}."));
    // What: a bool the env must supply; junk is fatal.
    // Why: same owner as need; a typo must not flip a gate.
    let need_flag = |name: &str| config::need_flag(&env, name).map_err(|e| format!("FATAL: {e}."));
    let ssl_enabled = need_flag("SSL_ENABLED")?;

    let fixed_names = [
        ("CONTAINER_PROXY", config::CONTAINER_PROXY, true),
        (
            "CONTAINER_DNS_STANDARD",
            config::CONTAINER_DNS_STANDARD,
            true,
        ),
        ("CONTAINER_DNS_SSL", config::CONTAINER_DNS_SSL, ssl_enabled),
        ("CONTAINER_NATS", config::CONTAINER_NATS, true),
    ];
    for (var, expected, active) in fixed_names {
        if let Some(got) = get(var)
            && active
            && got != expected
        {
            return Err(format!(
                "FATAL: {var}={got} is not supported (expected '{expected}'). The docker-socket-proxy allowlist and the Admin UI know only this fixed name. Revert {var} to the default."
            ));
        }
    }

    let cache_dir = match (
        get("CACHE_DIR"),
        get("CACHE_DIR_STANDARD"),
        get("CACHE_DIR_SSL"),
    ) {
        (Some(dir), _, _) => dir,
        (None, Some(std), Some(ssl)) if std != ssl => {
            return Err(format!(
                "FATAL: CACHE_DIR_STANDARD={std} and CACHE_DIR_SSL={ssl} point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
            ));
        }
        (None, Some(dir), _) | (None, None, Some(dir)) => dir,
        (None, None, None) => return Err(format!("FATAL: {}.", config::not_set("CACHE_DIR"))),
    };

    // What: the Docker API address must come from the env.
    // Why: watchdog.env and compose own it; no default.
    let docker_proxy_url = need("DOCKER_PROXY_URL")?;

    let settings = Settings {
        docker_proxy_url,
        check_interval: Duration::from_secs(check_interval),
        restart_after: restart_after as u32,
        curl_max_time,
        curl_max_time_restart,
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file: PathBuf::from(need("STATUS_FILE")?),
        desired_state_file: PathBuf::from(need("DESIRED_STATE_FILE")?),
        cache_dir: PathBuf::from(cache_dir),
        ssl_enabled,
        // What: DHCP_MODE must be set; "disabled" is valid.
        // Why: compose sets it; unknown text fails closed.
        dhcp_mode: DhcpMode::parse(&need("DHCP_MODE")?, false),
        // What: LOGGING_ENABLED gates the syslog container.
        // Why: SYSLOG_ENABLED gates retention only.
        logging_enabled: need_flag("LOGGING_ENABLED")?,
        ntp_enabled: need_flag("NTP_ENABLED")?,
    };
    Ok((settings, warnings))
}

// What: typed Docker health plus watchdog's own outcomes.
// Why: only Healthy and Unhealthy move a failure counter.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Reading {
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

impl Reading {
    // What: a reading from one docker inspect JSON body.
    // Why: Degraded refines healthy, never replaces it.
    // From: Issue #1296
    fn from_inspect(body: &serde_json::Value) -> Self {
        let status = body
            .pointer("/State/Health/Status")
            .and_then(|v| v.as_str())
            .unwrap_or("none");
        // What: only the newest check-log entry counts.
        // Why: an old DEGRADED line must expire with it.
        let degraded = body
            .pointer("/State/Health/Log")
            .and_then(|log| log.as_array())
            .and_then(|log| log.last())
            .and_then(|entry| entry.get("Output"))
            .and_then(|output| output.as_str())
            .is_some_and(|out| out.lines().any(|line| line.starts_with("DEGRADED: ")));
        match status {
            "healthy" if degraded => Self::Degraded,
            "healthy" => Self::Healthy,
            "unhealthy" => Self::Unhealthy,
            "starting" => Self::Starting,
            "none" => Self::None,
            other => Self::Other(other.to_string()),
        }
    }

    // What: the status.json health string and card color.
    // Why: the ui shows both verbatim; dashboard matches.
    // From: Issue #1296
    fn describe(&self) -> (&str, &'static str) {
        match self {
            Self::Healthy => ("healthy", "green"),
            Self::Unhealthy => ("unhealthy", "red"),
            Self::Starting => ("starting", "yellow"),
            Self::None => ("none", "yellow"),
            Self::Unreachable => ("unreachable", "yellow"),
            Self::Other(raw) => (raw, "yellow"),
            Self::Degraded => ("degraded", "amber"),
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
}

// What: what the loop logs or does after one reading.
// Why: None covers steady health and all inert readings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Event {
    None,
    Failing(u32),
    // What: restart, then the counter resets to 0.
    // Why: reset even if the restart call itself fails.
    Restart,
    Recovered,
}

// What: consecutive failures of one monitored service.
// Why: a restart fires only after RESTART_AFTER misses.
#[derive(Debug, Default)]
struct Counter(u32);

impl Counter {
    // What: reset to zero; Recovered if a streak ran.
    // Why: RECOVERED is logged once per outage, not cycle.
    fn clear(&mut self) -> Event {
        if std::mem::take(&mut self.0) > 0 {
            Event::Recovered
        } else {
            Event::None
        }
    }

    // What: count one reading of a restart-capable service.
    // Why: inert readings keep the counter; no restart.
    fn observe(&mut self, reading: &Reading, restart_after: u32) -> Event {
        match reading {
            Reading::Unhealthy => {
                self.0 = self.0.saturating_add(1);
                if self.0 >= restart_after {
                    self.0 = 0;
                    Event::Restart
                } else {
                    Event::Failing(self.0)
                }
            }
            Reading::Healthy => self.clear(),
            _ => Event::None,
        }
    }

    // What: count one reading of an alert-only service.
    // Why: watchdog must not restart these; only reports.
    fn observe_alert(&mut self, ok: bool) -> Event {
        if ok {
            return self.clear();
        }
        self.0 = self.0.saturating_add(1);
        Event::Failing(self.0)
    }
}

// What: monitored containers in probe order, restart flag.
// Why: dns-ssl, dhcp, syslog, ntp exist only when enabled.
// From: Issue #842
fn targets(s: &Settings) -> Vec<(&'static str, bool)> {
    let mut list = vec![
        (config::CONTAINER_PROXY, true),
        (config::CONTAINER_DNS_STANDARD, true),
    ];
    if s.ssl_enabled {
        list.push((config::CONTAINER_DNS_SSL, true));
    }
    list.extend([
        (config::CONTAINER_NATS, true),
        (config::CONTAINER_NETDATA, true),
        (config::CONTAINER_DOCKER_SOCKET_PROXY, false),
        (config::CONTAINER_UI, false),
    ]);
    list.extend(s.dhcp_mode.container().map(|name| (name, false)));
    if s.logging_enabled {
        list.push((config::CONTAINER_SYSLOG, false));
    }
    if s.ntp_enabled {
        list.push((config::CONTAINER_NTP, false));
    }
    list
}

// What: UTC time as YYYY-MM-DDTHH:MM:SSZ, no fractions.
// Why: status.json's `updated` format is a fixed contract.
fn stamp(at: OffsetDateTime) -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    at.format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

// What: the "[watchdog] HH:MM:SS" line prefix.
// Why: operators grep the docker logs for this exact shape.
fn prefix() -> String {
    format!("[watchdog] {}", &stamp(OffsetDateTime::now_utc())[11..19])
}

// What: WATCHDOG_LOG_FILE opened once for append, or none.
// Why: fluent-bit tails the file; compose runs no tee.
// From: Issue #1683 | PR #1858
fn log_file() -> Option<&'static Mutex<fs::File>> {
    static FILE: OnceLock<Option<Mutex<fs::File>>> = OnceLock::new();
    FILE.get_or_init(|| {
        let path = env_opt("WATCHDOG_LOG_FILE")?;
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o640)
            .open(&path)
            .inspect_err(|e| eprintln!("{} WARNING: cannot open {path}: {e}", prefix()))
            .ok()
            .map(Mutex::new)
    })
    .as_ref()
}

// What: a line to its stream and to the log file, if any.
// Why: a failed file write is shown once, never silent.
// From: Issue #1683 | PR #1858
fn emit(msg: &str, to_stderr: bool) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    let line = format!("{} {msg}", prefix());
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
        eprintln!("{} WARNING: cannot write the log file: {e}", prefix());
    }
}

// What: write one info line.
// Why: callers need no stream choice for normal output.
fn log(msg: &str) {
    emit(msg, false);
}

// What: write one error line to stderr.
// Why: errors stay visible apart from normal output.
fn log_err(msg: &str) {
    emit(msg, true);
}

// What: the call that moves a service to its wanted state.
// Why: a service already in that state needs no call.
fn reconcile_step(
    want: DesiredRunState,
    running: bool,
) -> Option<(&'static str, &'static str, &'static str)> {
    match (want, running) {
        (DesiredRunState::Running, false) => Some(("start", "STARTING", "running")),
        (DesiredRunState::Stopped, true) => Some(("stop", "STOPPING", "stopped")),
        _ => None,
    }
}

// What: start or stop dhcp/ntp to the desired state.
// Why: watchdog is the sole actor; no opinion, no action.
// From: Issue #1437
async fn reconcile(client: &DockerProxy, s: &Settings) {
    let desired = DesiredState::read(&s.desired_state_file);
    let mut services = Vec::new();
    if let Some(name) = s.dhcp_mode.container() {
        services.push(("dhcp", name, desired.dhcp));
    }
    if s.ntp_enabled {
        services.push(("ntp", config::CONTAINER_NTP, desired.ntp));
    }
    for (label, name, want) in services {
        let Some(want) = want else {
            continue;
        };
        // What: an unknown running state skips this cycle.
        // Why: acting on a guess could fight a rollback.
        let running = client
            .inspect(name, s.curl_max_time)
            .await
            .and_then(|body| body.pointer("/State/Running")?.as_bool());
        let Some(running) = running else {
            continue;
        };
        let Some((action, verb, state)) = reconcile_step(want, running) else {
            continue;
        };
        log(&format!(
            "{verb} {name} ({label}: desired state is {state})"
        ));
        if client
            .act(name, action, s.curl_max_time_restart)
            .await
            .is_err()
        {
            log_err(&format!("WARNING: {action} call failed for {name}"));
        }
    }
}

// What: the color of a disk use percent.
// Why: alarm outranks warn; below both is green.
fn disk_status(pct: u32, warn_pct: u32, alarm_pct: u32) -> &'static str {
    if pct >= alarm_pct {
        "red"
    } else if pct >= warn_pct {
        "yellow"
    } else {
        "green"
    }
}

// What: cache disk use as a traffic-light status.
// Why: a missing directory or failed df is unknown.
fn disk_info(dir: &Path, warn_pct: u32, alarm_pct: u32) -> DiskHealth {
    let unknown = DiskHealth {
        pct: 0,
        status: "unknown".to_string(),
    };
    if !dir.is_dir() {
        return unknown;
    }
    match df(dir) {
        Some(d) => DiskHealth {
            pct: d.used_pct,
            status: disk_status(d.used_pct, warn_pct, alarm_pct).to_string(),
        },
        None => unknown,
    }
}

// What: load settings, then run the watch loop.
// Why: a bad setting must stop the service before it acts.
#[tokio::main]
async fn main() {
    let (s, warnings) = load_settings(config::process_env).unwrap_or_else(|msg| {
        log_err(&msg);
        std::process::exit(1);
    });
    warnings.iter().for_each(|w| log(w));
    let client = DockerProxy::new(&s.docker_proxy_url);

    let list = targets(&s);
    let names = |restart: bool| {
        let picked: Vec<&str> = list
            .iter()
            .filter(|t| t.1 == restart)
            .map(|t| t.0)
            .collect();
        picked.join(" ")
    };
    log(&format!(
        "Watchdog started. Monitoring: {} (SSL_ENABLED={}); alert-only monitored: {}",
        names(true),
        u8::from(s.ssl_enabled),
        names(false),
    ));
    log(&format!("Cache directory: {}", s.cache_dir.display()));
    log(&format!(
        "Interval: {}s | Restart after: {} | Disk warn: {}% alarm: {}%",
        s.check_interval.as_secs(),
        s.restart_after,
        s.disk_warn_pct,
        s.disk_alarm_pct,
    ));

    let mut counters: HashMap<&str, Counter> = HashMap::new();
    loop {
        // What: apply the dhcp/ntp overrides first.
        // Why: the health report must reflect the result.
        // From: Issue #1437
        reconcile(&client, &s).await;

        let mut services: HashMap<String, ServiceHealth> = HashMap::new();
        for &(name, restart) in &list {
            // What: the socket proxy is probed with /_ping.
            // Why: it is the Docker channel; no inspect.
            let reading = if name == config::CONTAINER_DOCKER_SOCKET_PROXY {
                if client.ping(s.curl_max_time).await {
                    Reading::Healthy
                } else {
                    Reading::Unhealthy
                }
            } else {
                match client.inspect(name, s.curl_max_time).await {
                    Some(body) => Reading::from_inspect(&body),
                    None => Reading::Unreachable,
                }
            };
            let counter = counters.entry(name).or_default();
            let event = if restart {
                counter.observe(&reading, s.restart_after)
            } else {
                counter.observe_alert(reading.is_alert_ok())
            };
            match (event, restart) {
                (Event::None, _) => {}
                (Event::Recovered, _) => log(&format!("RECOVERED {name}")),
                (Event::Failing(count), true) => {
                    log(&format!("UNHEALTHY {name} ({count}/{})", s.restart_after));
                }
                (Event::Failing(count), false) => log(&format!(
                    "UNHEALTHY {name} ({count} consecutive failures) -- alert only, watchdog does not restart this service"
                )),
                (Event::Restart, _) => {
                    let n = s.restart_after;
                    log(&format!("UNHEALTHY {name} ({n}/{n})"));
                    log(&format!("RESTARTING {name}"));
                    if client
                        .restart(name, RESTART_GRACE_SECS, s.curl_max_time_restart)
                        .await
                        .is_err()
                    {
                        log(&format!("WARNING: restart call failed for {name}"));
                    }
                }
            }
            let (health, color) = reading.describe();
            services.insert(
                name.to_string(),
                ServiceHealth {
                    status: color.to_string(),
                    health: health.to_string(),
                    failures: counter.0,
                },
            );
        }

        let status = WatchdogStatus {
            updated: stamp(OffsetDateTime::now_utc()),
            services,
            disk: DiskInfo {
                cache: disk_info(&s.cache_dir, s.disk_warn_pct, s.disk_alarm_pct),
            },
            interval_secs: s.check_interval.as_secs(),
        };
        // What: a failed status write exits the process.
        // Why: compose restarts on exit, not on red health.
        let body = serde_json::to_string_pretty(&status)
            .expect("WatchdogStatus has only serializable fields");
        if let Err(e) = write_file(&s.status_file, body.as_bytes(), 0o644, Place::Replace) {
            log_err(&format!(
                "ERROR: failed to write {}: {e}",
                s.status_file.display()
            ));
            std::process::exit(1);
        }

        tokio::time::sleep(s.check_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: values watchdog.env and compose would supply.
    // Why: Rust keeps no defaults; every load needs them.
    const BASE: [(&str, &str); 14] = [
        ("DOCKER_PROXY_URL", "http://proxy.test:1"),
        ("CHECK_INTERVAL", "30"),
        ("RESTART_AFTER", "3"),
        ("DISK_WARN_PCT", "85"),
        ("DISK_ALARM_PCT", "95"),
        ("CURL_MAX_TIME", "5"),
        ("CURL_MAX_TIME_RESTART", "30"),
        ("CACHE_DIR", "/cache"),
        ("STATUS_FILE", "/run/status.json"),
        ("DESIRED_STATE_FILE", "/data/desired.json"),
        ("SSL_ENABLED", "1"),
        ("DHCP_MODE", "disabled"),
        ("LOGGING_ENABLED", "0"),
        ("NTP_ENABLED", "0"),
    ];

    // What: settings from BASE, overridden by env pairs.
    // Why: tests set no process env; "" blanks a value.
    fn load(pairs: &[(&str, &str)]) -> Result<(Settings, Vec<String>), String> {
        load_settings(|name| {
            pairs
                .iter()
                .chain(BASE.iter())
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        })
    }

    // What: knobs take the owner's value, floor, or fail.
    // Why: a bad knob must not busy-loop or restart.
    #[test]
    fn knobs_floor_and_reject() {
        let (s, warnings) = load(&[]).unwrap();
        assert!(warnings.is_empty());
        assert_eq!(s.check_interval, Duration::from_secs(30));
        assert_eq!(
            (s.restart_after, s.disk_warn_pct, s.disk_alarm_pct),
            (3, 85, 95)
        );
        assert_eq!(s.curl_max_time, Some(Duration::from_secs(5)));
        assert_eq!(s.curl_max_time_restart, Some(Duration::from_secs(30)));
        assert_eq!(s.cache_dir, PathBuf::from("/cache"));

        let floored = [("CHECK_INTERVAL", "0"), ("RESTART_AFTER", "00")];
        let (s, warnings) = load(&floored).unwrap();
        assert_eq!(s.check_interval, Duration::from_secs(1));
        assert_eq!(s.restart_after, 1);
        assert!(warnings.iter().any(|w| w.contains("CHECK_INTERVAL=0")));
        assert!(warnings.iter().any(|w| w.contains("RESTART_AFTER=00")));

        for (name, bad) in [
            ("CHECK_INTERVAL", "abc"),
            ("RESTART_AFTER", "4294967296"),
            ("DISK_WARN_PCT", "-5"),
            ("DISK_ALARM_PCT", ""),
        ] {
            let err = load(&[(name, bad)]).err().unwrap();
            assert!(err.contains(name), "{name}={bad}: {err}");
        }
    }

    // What: curl timeouts keep fractions; 0 is unbounded.
    // Why: 0 must not time out at once; junk is fatal.
    #[test]
    fn curl_timeouts_handle_zero_fractions_and_junk() {
        let pairs = [("CURL_MAX_TIME", "0"), ("CURL_MAX_TIME_RESTART", "2.5")];
        let (s, warnings) = load(&pairs).unwrap();
        assert_eq!(s.curl_max_time, None);
        assert_eq!(s.curl_max_time_restart, Some(Duration::from_secs_f64(2.5)));
        assert!(warnings.is_empty());
        for bad in ["bogus", "-1.5", "1e999", ""] {
            let err = load(&[("CURL_MAX_TIME", bad)]).err().unwrap();
            assert!(err.contains("CURL_MAX_TIME"), "{bad}: {err}");
        }
    }

    // What: unset or junk owner values are fatal.
    // Why: the watchdog has no defaults to fall back on.
    #[test]
    fn missing_or_junk_owner_values_are_fatal() {
        for (var, _) in BASE {
            let err = load(&[(var, "")]).err().unwrap();
            assert!(err.contains(var), "{var}: {err}");
        }
        for var in ["SSL_ENABLED", "LOGGING_ENABLED", "NTP_ENABLED"] {
            assert!(load(&[(var, "maybe")]).is_err(), "{var}");
        }
    }

    // What: renamed containers and split cache dirs fail.
    // Why: the proxy allowlist has fixed names; no guess.
    // From: Issue #849
    #[test]
    fn renames_and_conflicting_cache_dirs_are_fatal() {
        let vars = [
            "CONTAINER_PROXY",
            "CONTAINER_DNS_STANDARD",
            "CONTAINER_DNS_SSL",
            "CONTAINER_NATS",
        ];
        for var in vars {
            assert!(load(&[(var, "renamed")]).is_err(), "{var}");
        }
        assert!(load(&[("CONTAINER_PROXY", "lancache-proxy")]).is_ok());
        assert!(load(&[("SSL_ENABLED", "0"), ("CONTAINER_DNS_SSL", "x")]).is_ok());
        let split = [
            ("CACHE_DIR", ""),
            ("CACHE_DIR_STANDARD", "/b"),
            ("CACHE_DIR_SSL", "/c"),
        ];
        let err = load(&split).err().unwrap();
        assert!(err.contains("/b") && err.contains("/c"));
        let (s, _) = load(&[("CACHE_DIR", "/a"), ("CACHE_DIR_SSL", "/c")]).unwrap();
        assert_eq!(s.cache_dir, PathBuf::from("/a"));
        let (s, _) = load(&[("CACHE_DIR", ""), ("CACHE_DIR_SSL", "/c")]).unwrap();
        assert_eq!(s.cache_dir, PathBuf::from("/c"));
    }

    // What: inspect bodies map to readings and colors.
    // Why: only the newest check-log entry marks Degraded.
    // From: Issue #1296
    #[test]
    fn inspect_bodies_map_to_readings_and_colors() {
        let read = |status: &str, last_output: &str| {
            let log = serde_json::json!([{"Output": "DEGRADED: old"}, {"Output": last_output}]);
            let health = serde_json::json!({"Status": status, "Log": log});
            Reading::from_inspect(&serde_json::json!({"State": {"Health": health}}))
        };
        assert_eq!(read("healthy", "ok"), Reading::Healthy);
        assert_eq!(read("healthy", "x\nDEGRADED: no clock"), Reading::Degraded);
        assert_eq!(read("unhealthy", "DEGRADED: x"), Reading::Unhealthy);
        assert_eq!(read("weird", ""), Reading::Other("weird".to_string()));
        let bare = serde_json::json!({"State": {}});
        assert_eq!(Reading::from_inspect(&bare), Reading::None);
        let colors = [
            (Reading::Healthy, "green"),
            (Reading::Unhealthy, "red"),
            (Reading::Starting, "yellow"),
            (Reading::None, "yellow"),
            (Reading::Unreachable, "yellow"),
            (Reading::Other("huh".into()), "yellow"),
            (Reading::Degraded, "amber"),
        ];
        for (reading, color) in colors {
            assert_eq!(reading.describe().1, color);
        }
        assert_eq!(Reading::Degraded.describe().0, "degraded");
        assert!(Reading::Degraded.is_alert_ok() && Reading::None.is_alert_ok());
        assert!(!Reading::Unreachable.is_alert_ok());
        assert!(!Reading::Other("huh".into()).is_alert_ok());
    }

    // What: restart at threshold; inert reads never count.
    // Why: restarting an unreachable service is unsafe.
    #[test]
    fn counters_restart_at_threshold_and_recover_once() {
        let inert = [
            Reading::Starting,
            Reading::None,
            Reading::Unreachable,
            Reading::Degraded,
        ];
        for reading in inert {
            let mut counter = Counter(2);
            assert_eq!(counter.observe(&reading, 3), Event::None);
            assert_eq!(counter.0, 2);
        }
        let mut counter = Counter::default();
        assert_eq!(counter.observe(&Reading::Unhealthy, 3), Event::Failing(1));
        assert_eq!(counter.observe(&Reading::Unhealthy, 3), Event::Failing(2));
        assert_eq!(counter.observe(&Reading::Unhealthy, 3), Event::Restart);
        assert_eq!(counter.0, 0);
        counter.0 = 2;
        assert_eq!(counter.observe(&Reading::Healthy, 3), Event::Recovered);
        assert_eq!(counter.observe(&Reading::Healthy, 3), Event::None);

        assert_eq!(counter.observe_alert(false), Event::Failing(1));
        assert_eq!(counter.observe_alert(false), Event::Failing(2));
        assert_eq!(counter.observe_alert(true), Event::Recovered);
        assert_eq!(counter.observe_alert(true), Event::None);
    }

    // What: targets follow the SSL, DHCP, log, NTP gates.
    // Why: a gated service that is off must raise no alarm.
    // From: Issue #842
    #[test]
    fn targets_follow_the_gates() {
        let names = |pairs: &[(&str, &str)]| {
            let (s, _) = load(pairs).unwrap();
            targets(&s).into_iter().map(|t| t.0).collect::<Vec<_>>()
        };
        let base = [
            "lancache-proxy",
            "lancache-dns-standard",
            "lancache-dns-ssl",
            "lancache-nats",
            "lancache-netdata",
            "lancache-docker-socket-proxy",
            "lancache-ui",
        ];
        assert_eq!(names(&[]), base);
        assert!(!names(&[("SSL_ENABLED", "0")]).contains(&"lancache-dns-ssl"));
        let all = [
            ("DHCP_MODE", "dnsmasq-relay"),
            ("LOGGING_ENABLED", "1"),
            ("NTP_ENABLED", "yes"),
        ];
        let tail = names(&all).split_off(base.len());
        let want = ["lancache-dhcp-proxy", "lancache-syslog", "lancache-ntp"];
        assert_eq!(tail, want);
    }

    // What: the reconcile step per wanted and running pair.
    // Why: a wrong pair would stop DHCP or NTP by mistake.
    // From: Issue #1437
    #[test]
    fn reconcile_acts_only_on_a_difference() {
        use DesiredRunState::{Running, Stopped};
        assert_eq!(
            reconcile_step(Running, false),
            Some(("start", "STARTING", "running"))
        );
        assert_eq!(
            reconcile_step(Stopped, true),
            Some(("stop", "STOPPING", "stopped"))
        );
        assert_eq!(reconcile_step(Running, true), None);
        assert_eq!(reconcile_step(Stopped, false), None);
    }

    // What: disk colors follow the warn and alarm limits.
    // Why: alarm outranks warn; equal to a limit counts.
    #[test]
    fn disk_status_follows_the_limits() {
        assert_eq!(disk_status(84, 85, 95), "green");
        assert_eq!(disk_status(85, 85, 95), "yellow");
        assert_eq!(disk_status(94, 85, 95), "yellow");
        assert_eq!(disk_status(95, 85, 95), "red");
        assert_eq!(disk_status(100, 85, 95), "red");
    }

    // What: a missing cache dir reads unknown, not green.
    // Why: no reading must not look like a healthy disk.
    #[test]
    fn disk_info_is_unknown_for_a_missing_dir() {
        let gone = Path::new("/nonexistent-lancache-test-dir");
        let info = disk_info(gone, 85, 95);
        assert_eq!((info.pct, info.status.as_str()), (0, "unknown"));
    }

    // What: the timestamp keeps its fixed UTC shape.
    // Why: status.json's `updated` field is a contract.
    #[test]
    fn stamp_has_the_fixed_shape() {
        let date = time::Date::from_calendar_date(2026, time::Month::January, 2).unwrap();
        let at = date.with_hms(3, 4, 5).unwrap().assume_utc();
        assert_eq!(stamp(at), "2026-01-02T03:04:05Z");
    }
}
