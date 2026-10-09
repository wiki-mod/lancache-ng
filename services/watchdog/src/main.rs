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

use lancache_common::config::{self, DhcpMode, OutOfRange, Uint, env_opt, parse_bool};
use lancache_common::{
    DesiredRunState, DesiredState, DiskHealth, DiskInfo, DockerProxy, Place, ServiceHealth,
    WatchdogStatus, df, write_file,
};
use time::OffsetDateTime;

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
fn curl_timeout(
    raw: Option<&str>,
    name: &str,
    default_secs: u64,
) -> (Option<Duration>, Option<String>) {
    let default = Some(Duration::from_secs(default_secs));
    let Some(raw) = raw else {
        return (default, None);
    };
    let invalid = |why: &str| {
        let warning = format!("Invalid {name}={raw}{why}; using default {default_secs}");
        (default, Some(warning))
    };
    match raw.parse::<f64>() {
        Ok(0.0) => (None, None),
        Ok(secs) if secs.is_finite() && secs > 0.0 => match Duration::try_from_secs_f64(secs) {
            Ok(timeout) => (Some(timeout), None),
            Err(_) => invalid(" (out of range)"),
        },
        _ => invalid(""),
    }
}

// What: settings from an env reader, plus startup warnings.
// Why: Err is fatal; a reader argument keeps tests env-free.
// From: Issue #849 | PR #1858
fn load_settings(env: impl Fn(&str) -> Option<String>) -> Result<(Settings, Vec<String>), String> {
    let get = |name: &str| env(name).filter(|v| !v.is_empty());
    let mut warnings = Vec::new();
    let mut knob = |name: &'static str, default: u64, min: u64, max: u64| {
        let spec = Uint {
            name,
            default,
            min,
            max,
            below: OutOfRange::Clamp,
            above: OutOfRange::Default,
        };
        let (value, warning) = spec.parse(get(name).as_deref());
        warnings.extend(warning);
        value
    };
    let check_interval = knob("CHECK_INTERVAL", 30, 1, u64::MAX);
    let restart_after = knob("RESTART_AFTER", 3, 1, u32::MAX.into());
    let disk_warn_pct = knob("DISK_WARN_PCT", 85, 0, u32::MAX.into());
    let disk_alarm_pct = knob("DISK_ALARM_PCT", 95, 0, u32::MAX.into());
    let (curl_max_time, warn_a) = curl_timeout(get("CURL_MAX_TIME").as_deref(), "CURL_MAX_TIME", 5);
    let (curl_max_time_restart, warn_b) = curl_timeout(
        get("CURL_MAX_TIME_RESTART").as_deref(),
        "CURL_MAX_TIME_RESTART",
        30,
    );
    warnings.extend(warn_a);
    warnings.extend(warn_b);

    // What: a bool knob; junk is false, unset is the default.
    // Why: keeps the contract these gates always had.
    let flag =
        |name: &str, default: bool| get(name).map_or(default, |v| parse_bool(&v).unwrap_or(false));
    let ssl_enabled = flag("SSL_ENABLED", true);

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
        (None, None, None) => "/var/cache/lancache".to_string(),
    };

    let settings = Settings {
        docker_proxy_url: get("DOCKER_PROXY_URL")
            .unwrap_or_else(|| config::DOCKER_PROXY_DEFAULT_URL.to_string()),
        check_interval: Duration::from_secs(check_interval),
        restart_after: restart_after as u32,
        curl_max_time,
        curl_max_time_restart,
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file: get("STATUS_FILE").map_or_else(
            || PathBuf::from("/var/run/watchdog/status.json"),
            PathBuf::from,
        ),
        desired_state_file: get("DESIRED_STATE_FILE")
            .map_or_else(|| PathBuf::from("/data/desired-state.json"), PathBuf::from),
        cache_dir: PathBuf::from(cache_dir),
        ssl_enabled,
        // What: an unset DHCP_MODE means disabled.
        // Why: no alert for a DHCP container never run.
        dhcp_mode: DhcpMode::parse(&get("DHCP_MODE").unwrap_or_default(), false),
        // What: LOGGING_ENABLED gates the syslog container.
        // Why: SYSLOG_ENABLED gates retention only.
        logging_enabled: flag("LOGGING_ENABLED", false),
        ntp_enabled: flag("NTP_ENABLED", false),
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
        // Why: an old DEGRADED line must expire with its entry.
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
    // Why: the ui shows both verbatim; dashboard.html matches.
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
    // What: reset to zero; Recovered if a streak was running.
    // Why: RECOVERED is logged once per outage, not per cycle.
    fn clear(&mut self) -> Event {
        if std::mem::take(&mut self.0) > 0 {
            Event::Recovered
        } else {
            Event::None
        }
    }

    // What: count one reading of a restart-capable service.
    // Why: inert readings keep the counter; never restart them.
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
    // Why: watchdog must not restart these; it only reports.
    fn observe_alert(&mut self, ok: bool) -> Event {
        if ok {
            return self.clear();
        }
        self.0 = self.0.saturating_add(1);
        Event::Failing(self.0)
    }
}

// What: monitored containers in probe order, may-restart flag.
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

fn log(msg: &str) {
    emit(msg, false);
}

fn log_err(msg: &str) {
    emit(msg, true);
}

// What: start or stop dhcp/ntp to the desired state.
// Why: watchdog is the sole actor; no opinion means no action.
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
        // Why: acting on a guessed state could fight a rollback.
        let running = client
            .inspect(name, s.curl_max_time)
            .await
            .and_then(|body| body.pointer("/State/Running")?.as_bool());
        let Some(running) = running else {
            continue;
        };
        let (action, verb, state) = match (want, running) {
            (DesiredRunState::Running, false) => ("start", "STARTING", "running"),
            (DesiredRunState::Stopped, true) => ("stop", "STOPPING", "stopped"),
            _ => continue,
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

// What: cache disk use as a traffic-light status.
// Why: same rounding as df; a missing directory is unknown.
fn disk_info(dir: &Path, warn_pct: u32, alarm_pct: u32) -> DiskHealth {
    if !dir.is_dir() {
        return DiskHealth {
            pct: 0,
            status: "unknown".to_string(),
        };
    }
    let pct = df(dir).map_or(0, |d| d.used_pct);
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

#[tokio::main]
async fn main() {
    let (s, warnings) = load_settings(|name| std::env::var(name).ok()).unwrap_or_else(|msg| {
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
            // Why: it is the Docker channel itself; no inspect.
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
                        .act(name, "restart?t=2", s.curl_max_time_restart)
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

    // What: settings from a fixed list of env pairs.
    // Why: tests read literal values and set no process env.
    fn load(pairs: &[(&str, &str)]) -> Result<(Settings, Vec<String>), String> {
        load_settings(|name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        })
    }

    // What: knobs keep defaults, floor and fall back.
    // Why: a bad knob must not busy-loop or restart every reading.
    #[test]
    fn knobs_floor_fall_back_and_default() {
        let (s, warnings) = load(&[]).unwrap();
        assert!(warnings.is_empty());
        assert_eq!(s.check_interval, Duration::from_secs(30));
        assert_eq!(
            (s.restart_after, s.disk_warn_pct, s.disk_alarm_pct),
            (3, 85, 95)
        );
        assert_eq!(s.curl_max_time, Some(Duration::from_secs(5)));
        assert_eq!(s.curl_max_time_restart, Some(Duration::from_secs(30)));
        assert_eq!(s.cache_dir, PathBuf::from("/var/cache/lancache"));
        let blank = [
            ("CHECK_INTERVAL", ""),
            ("RESTART_AFTER", ""),
            ("SSL_ENABLED", ""),
        ];
        let (s, warnings) = load(&blank).unwrap();
        assert!(warnings.is_empty() && s.ssl_enabled && s.restart_after == 3);

        let floored = [("CHECK_INTERVAL", "0"), ("RESTART_AFTER", "00")];
        let (s, warnings) = load(&floored).unwrap();
        assert_eq!(s.check_interval, Duration::from_secs(1));
        assert_eq!(s.restart_after, 1);
        assert!(warnings.iter().any(|w| w.contains("CHECK_INTERVAL=0")));
        assert!(warnings.iter().any(|w| w.contains("RESTART_AFTER=00")));

        let junk = [
            ("CHECK_INTERVAL", "abc"),
            ("RESTART_AFTER", "4294967296"),
            ("DISK_WARN_PCT", "-5"),
        ];
        let (s, warnings) = load(&junk).unwrap();
        assert_eq!(s.check_interval, Duration::from_secs(30));
        assert_eq!((s.restart_after, s.disk_warn_pct), (3, 85));
        assert_eq!(warnings.len(), 3);
    }

    // What: curl timeouts keep fractions; 0 is unbounded.
    // Why: 0 must not time out at once; junk falls back.
    #[test]
    fn curl_timeouts_handle_zero_fractions_and_junk() {
        let pairs = [("CURL_MAX_TIME", "0"), ("CURL_MAX_TIME_RESTART", "2.5")];
        let (s, warnings) = load(&pairs).unwrap();
        assert_eq!(s.curl_max_time, None);
        assert_eq!(s.curl_max_time_restart, Some(Duration::from_secs_f64(2.5)));
        assert!(warnings.is_empty());
        for bad in ["bogus", "-1.5", "1e999"] {
            let (s, warnings) = load(&[("CURL_MAX_TIME", bad)]).unwrap();
            assert_eq!(s.curl_max_time, Some(Duration::from_secs(5)));
            let needle = format!("CURL_MAX_TIME={bad}");
            assert!(warnings.iter().any(|w| w.contains(&needle)));
        }
    }

    // What: renamed containers and split cache dirs are fatal.
    // Why: the proxy allowlist knows fixed names; no cache guess.
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
        let split = [("CACHE_DIR_STANDARD", "/b"), ("CACHE_DIR_SSL", "/c")];
        let err = load(&split).err().unwrap();
        assert!(err.contains("/b") && err.contains("/c"));
        let (s, _) = load(&[("CACHE_DIR", "/a"), ("CACHE_DIR_SSL", "/c")]).unwrap();
        assert_eq!(s.cache_dir, PathBuf::from("/a"));
        let (s, _) = load(&[("CACHE_DIR_SSL", "/c")]).unwrap();
        assert_eq!(s.cache_dir, PathBuf::from("/c"));
    }

    // What: inspect bodies map to readings and colors.
    // Why: only the newest check-log entry may mark Degraded.
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

    // What: restart at the threshold; inert readings never count.
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

    // What: targets follow the SSL, DHCP, logging, NTP gates.
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

    // What: the timestamp keeps its fixed UTC shape.
    // Why: status.json's `updated` field is a contract.
    #[test]
    fn stamp_has_the_fixed_shape() {
        let date = time::Date::from_calendar_date(2026, time::Month::January, 2).unwrap();
        let at = date.with_hms(3, 4, 5).unwrap().assume_utc();
        assert_eq!(stamp(at), "2026-01-02T03:04:05Z");
    }
}
