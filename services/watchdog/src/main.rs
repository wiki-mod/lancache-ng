//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: watchdog health loop, restarts and status.json.
//! Why: one daemon keeps core services up, reports health.
//! From: Issue #842 | PR #1858

use std::collections::HashMap;
use std::fs;
use std::io::{self, Write as _};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime};

use lancache_ng::config::{self, DhcpMode, OutOfRange, Uint, env_opt};
use lancache_ng::{
    DesiredRunState, DesiredState, DiskHealth, DiskInfo, DockerProxy, Place, ServiceHealth,
    WatchdogStatus, df, unix_secs, write_file,
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

// What: one Uint knob from the env; a clamp warns.
// Why: both modes read their knobs by one rule.
fn read_knob(
    get: &dyn Fn(&str) -> Option<String>,
    spec: Uint,
    warnings: &mut Vec<String>,
) -> Result<u64, String> {
    let (value, warning) = spec
        .parse(get(spec.name).as_deref())
        .map_err(|e| format!("FATAL: {e}."))?;
    warnings.extend(warning);
    Ok(value)
}

// What: CACHE_DIR, else the one split cache dir.
// Why: watch and retention must name the same cache.
fn cache_dir(get: &dyn Fn(&str) -> Option<String>) -> Result<String, String> {
    if let Some(dir) = get("CACHE_DIR") {
        return Ok(dir);
    }
    let (standard, ssl) = (get("CACHE_DIR_STANDARD"), get("CACHE_DIR_SSL"));
    if let (Some(std), Some(ssl)) = (&standard, &ssl)
        && std != ssl
    {
        return Err(format!(
            "FATAL: CACHE_DIR_STANDARD={std} and CACHE_DIR_SSL={ssl} point to different paths without CACHE_DIR. Set CACHE_DIR to one shared cache directory."
        ));
    }
    standard
        .or(ssl)
        .ok_or_else(|| format!("FATAL: {}.", config::not_set("CACHE_DIR")))
}

// What: settings from an env reader, plus startup warnings.
// Why: Err is fatal; a reader arg keeps tests env-free.
// From: Issue #849 | PR #1858
fn load_settings(env: impl Fn(&str) -> Option<String>) -> Result<(Settings, Vec<String>), String> {
    let get = |name: &str| config::opt(&env, name);
    let mut warnings = Vec::new();
    let mut knob = |name: &'static str, min: u64, max: u64| {
        let spec = Uint {
            name,
            min,
            max,
            below: OutOfRange::Clamp,
            above: OutOfRange::Reject,
        };
        read_knob(&get, spec, &mut warnings)
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

    let cache_dir = cache_dir(&get)?;

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

// What: log tag of the running mode, set once at start.
// Why: retention lines keep their own [retention] tag.
static MODE: OnceLock<&'static str> = OnceLock::new();

// What: the "[mode] HH:MM:SS" line prefix.
// Why: operators grep the docker logs for this exact shape.
fn prefix() -> String {
    let mode = MODE.get().copied().unwrap_or("watchdog");
    format!("[{mode}] {}", &stamp(OffsetDateTime::now_utc())[11..19])
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

// What: seconds of one day, the stamp rate limit.
// Why: purge and syslog prune run at most once a day.
const DAY: u64 = time::Duration::DAY.whole_seconds() as u64;

// What: retention settings, read once from the env.
// Why: the env owners set every path, limit and gate.
// From: Issue #842 | PR #1858
struct Retention {
    interval: Duration,
    cache_dir: String,
    cache_prefix: PathBuf,
    cache_valid_days: u64,
    purge_stamp: PathBuf,
    syslog_root: String,
    syslog_prefix: PathBuf,
    syslog_days: u64,
    syslog_max_bytes: u64,
    syslog_cooldown: u64,
    syslog_stamp: PathBuf,
}

// What: retention settings from an env reader.
// Why: a destructive budget below its minimum is fatal.
// From: Issue #842 | PR #1858
fn load_retention(
    env: impl Fn(&str) -> Option<String>,
) -> Result<(Retention, Vec<String>), String> {
    let get = |name: &str| config::opt(&env, name);
    let need = |name: &str| config::need(&env, name).map_err(|e| format!("FATAL: {e}."));
    let absolute = |name: &str| -> Result<PathBuf, String> {
        let raw = need(name)?;
        if !raw.starts_with('/') {
            return Err(format!("FATAL: {name}={raw} is not an absolute path."));
        }
        Ok(PathBuf::from(raw))
    };
    let mut warnings = Vec::new();
    let mut knob = |spec: Uint| read_knob(&get, spec, &mut warnings);
    let at_least = |name: &'static str, min: u64, max: u64| Uint {
        name,
        min,
        max,
        below: OutOfRange::Reject,
        above: OutOfRange::Reject,
    };
    let interval = knob(Uint {
        below: OutOfRange::Clamp,
        ..at_least("CHECK_INTERVAL", 1, u64::MAX)
    })?;
    let cache_valid_days = knob(at_least("CACHE_VALID_DAYS", 0, u64::MAX))?;
    let syslog_days = knob(at_least("SYSLOG_RETENTION_DAYS", 0, u64::MAX))?;
    let syslog_gb = knob(config::SYSLOG_MAX_GB)?;
    let syslog_cooldown = knob(Uint {
        above: OutOfRange::Clamp,
        ..at_least("SYSLOG_PRUNE_RETRY_COOLDOWN", 0, DAY)
    })?;
    let retention = Retention {
        interval: Duration::from_secs(interval),
        cache_dir: cache_dir(&get)?,
        cache_prefix: absolute("CACHE_DIR_ALLOWED_PREFIX")?,
        cache_valid_days,
        purge_stamp: absolute("PURGE_STAMP")?,
        syslog_root: need("SYSLOG_LOG_ROOT")?,
        syslog_prefix: absolute("SYSLOG_LOG_ROOT_ALLOWED_PREFIX")?,
        syslog_days,
        syslog_max_bytes: syslog_gb << 30,
        syslog_cooldown,
        syslog_stamp: absolute("SYSLOG_PRUNE_STAMP")?,
    };
    Ok((retention, warnings))
}

// What: absolute path, symlinks and dots resolved.
// Why: like realpath -m; a target may not exist yet.
fn canonical(path: &Path) -> io::Result<PathBuf> {
    let mut out = PathBuf::from(Component::RootDir.as_os_str());
    for part in path.components() {
        match part {
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(name) => {
                let next = out.join(name);
                out = match fs::canonicalize(&next) {
                    Ok(real) => real,
                    // What: a dangling link fails
                    // Why: its prefix is unknown
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {
                        if fs::symlink_metadata(&next).is_ok() {
                            return Err(io::Error::other("dangling symbolic link"));
                        }
                        next
                    }
                    Err(e) => return Err(e),
                };
            }
        }
    }
    Ok(out)
}

// What: the canonical target, strictly inside its prefix.
// Why: a bad value must never reach a delete or rotate.
// From: Issue #842 | PR #1858
fn retention_target(name: &str, raw: &str, prefix: &Path) -> Result<PathBuf, String> {
    if raw.is_empty() {
        return Err(format!("FATAL: {name} is empty; refusing to guess a target."));
    }
    if !raw.starts_with('/') {
        return Err(format!(
            "FATAL: {name}={raw} is not an absolute path; refusing."
        ));
    }
    let resolved = canonical(Path::new(raw))
        .map_err(|e| format!("FATAL: {name}={raw} could not be canonicalized: {e}"))?;
    if resolved == prefix {
        return Err(format!(
            "FATAL: {name} resolves to '{}', which is {} itself, not a subdirectory; refusing.",
            resolved.display(),
            prefix.display()
        ));
    }
    if !resolved.starts_with(prefix) {
        return Err(format!(
            "FATAL: {name}={raw} resolves to '{}', which is outside the expected {} tree; refusing.",
            resolved.display(),
            prefix.display()
        ));
    }
    Ok(resolved)
}

// What: regular files under root, never across mounts.
// Why: like find -xdev -type f; no symlink is followed.
fn files_under(root: &Path) -> io::Result<Vec<(PathBuf, fs::Metadata)>> {
    let dev = fs::symlink_metadata(root)?.dev();
    let (mut files, mut dirs) = (Vec::new(), vec![root.to_path_buf()]);
    while let Some(dir) = dirs.pop() {
        let entries = match fs::read_dir(&dir) {
            Err(e) if e.kind() == io::ErrorKind::NotFound && dir != root => continue,
            other => other?,
        };
        for entry in entries {
            let path = entry?.path();
            // What: an entry gone since listing is skipped
            // Why: cache and logs change during a scan
            let meta = match fs::symlink_metadata(&path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                other => other?,
            };
            if meta.dev() != dev {
                continue;
            }
            if meta.is_dir() {
                dirs.push(path);
            } else if meta.is_file() {
                files.push((path, meta));
            }
        }
    }
    Ok(files)
}

// What: a file's mtime in epoch seconds, else now.
// Why: an unreadable mtime must never look old.
fn mtime_secs(meta: &fs::Metadata, now: u64) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map_or(now, |d| d.as_secs())
}

// What: whole days since the file's last change.
// Why: find -mtime +N counts days the same way.
fn age_days(meta: &fs::Metadata, now: u64) -> u64 {
    now.saturating_sub(mtime_secs(meta, now)) / DAY
}

// What: remove a path only while it is a regular file.
// Why: a path replaced since the scan stays untouched.
fn remove_file_if_regular(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() => match fs::remove_file(path) {
            Ok(()) => true,
            Err(e) => {
                log_err(&format!("ERROR: cannot remove {}: {e}", path.display()));
                false
            }
        },
        _ => false,
    }
}

// What: last run from a stamp; junk or future reads 0.
// Why: a broken stamp must not block the daily run.
fn read_stamp(path: &Path, now: u64) -> u64 {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return 0,
        Err(e) => {
            log_err(&format!("ERROR: cannot read {}: {e}; resetting", path.display()));
            return 0;
        }
    };
    let raw = raw.trim();
    let digits = !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit());
    match raw.parse::<u64>() {
        Ok(last) if digits && last <= now => last,
        Ok(_) if digits => {
            log(&format!("{}={raw} is in the future; resetting", path.display()));
            0
        }
        _ => {
            log(&format!("Invalid {}={raw}; resetting", path.display()));
            0
        }
    }
}

// What: write a stamp; a failed write is logged.
// Why: the next cycle then retries instead of skipping.
fn write_stamp(path: &Path, value: u64) {
    let written = path
        .parent()
        .map_or(Ok(()), fs::create_dir_all)
        .and_then(|()| fs::write(path, format!("{value}\n")));
    if let Err(e) = written {
        log_err(&format!("ERROR: cannot write {}: {e}", path.display()));
    }
}

// What: daily: delete cache files past CACHE_VALID_DAYS.
// Why: a refused, missing or unread dir leaves no stamp.
// From: Issue #842 | PR #1858
fn purge_cache(r: &Retention, now: u64) {
    if now - read_stamp(&r.purge_stamp, now) < DAY {
        return;
    }
    let dir = match retention_target("CACHE_DIR", &r.cache_dir, &r.cache_prefix) {
        Ok(dir) => dir,
        Err(e) => return log_err(&e),
    };
    if !dir.is_dir() {
        return log(&format!(
            "CACHE_DIR={} does not exist; skipping purge",
            dir.display()
        ));
    }
    log(&format!(
        "Daily purge: removing cache files older than {} days",
        r.cache_valid_days
    ));
    let files = match files_under(&dir) {
        Ok(files) => files,
        Err(e) => return log_err(&format!("ERROR: cannot scan {}: {e}", dir.display())),
    };
    let removed = files
        .iter()
        .filter(|(path, meta)| {
            age_days(meta, now) > r.cache_valid_days && remove_file_if_regular(path)
        })
        .count();
    log(&format!("Purged {removed} files from {}", dir.display()));
    write_stamp(&r.purge_stamp, now);
}

// What: whether a file changed since UTC midnight.
// Why: syslog-ng still writes today's per-host files.
fn written_today(meta: &fs::Metadata, now: u64) -> bool {
    mtime_secs(meta, now) >= now - now % DAY
}

// What: daily: age floor, then size budget oldest-first.
// Why: the budget wins over the floor; today's log stays.
// From: Issue #633 | PR #1858
fn prune_syslog(r: &Retention, now: u64) {
    if now - read_stamp(&r.syslog_stamp, now) < DAY {
        return;
    }
    let root = match retention_target("SYSLOG_LOG_ROOT", &r.syslog_root, &r.syslog_prefix) {
        Ok(root) => root,
        Err(e) => return log_err(&e),
    };
    if !root.is_dir() {
        return log(&format!(
            "SYSLOG_LOG_ROOT={} does not exist yet; skipping syslog prune",
            root.display()
        ));
    }
    let budget = r.syslog_max_bytes;
    log(&format!(
        "Syslog prune: retention={}d budget={budget} bytes root={}",
        r.syslog_days,
        root.display()
    ));
    let scan = |what: &str| {
        files_under(&root).map_err(|e| {
            log_err(&format!("ERROR: cannot scan {} ({what}): {e}", root.display()))
        })
    };
    let Ok(files) = scan("age") else { return };
    let mut aged = 0;
    for (path, meta) in &files {
        if age_days(meta, now) > r.syslog_days && remove_file_if_regular(path) {
            aged += 1;
            log(&format!(
                "Pruned syslog file (age > {}d): {}",
                r.syslog_days,
                path.display()
            ));
        }
    }
    log(&format!("Age-based syslog prune: removed {aged} file(s)"));
    let Ok(mut files) = scan("size") else { return };
    let mut size: u64 = files.iter().map(|(_, meta)| meta.len()).sum();
    if size <= budget {
        log(&format!("Syslog size within budget: {size} <= {budget} bytes"));
        return write_stamp(&r.syslog_stamp, now);
    }
    log(&format!(
        "Syslog size budget exceeded: {size} > {budget} bytes; pruning oldest first"
    ));
    files.sort_by_key(|(_, meta)| meta.modified().ok());
    let mut sized = 0;
    for (path, meta) in &files {
        if size <= budget {
            break;
        }
        if written_today(meta, now) {
            continue;
        }
        if remove_file_if_regular(path) {
            size = size.saturating_sub(meta.len());
            sized += 1;
            log(&format!(
                "Pruned syslog file (size budget, oldest-first): {}",
                path.display()
            ));
        }
    }
    log(&format!(
        "Size-based syslog prune: removed {sized} file(s), size now {size} bytes"
    ));
    if size > budget {
        log(&format!(
            "WARNING: syslog size budget still exceeded; today's per-host files stay open in syslog-ng; retry in {}s",
            r.syslog_cooldown
        ));
        write_stamp(&r.syslog_stamp, (now + r.syslog_cooldown).saturating_sub(DAY));
    } else {
        write_stamp(&r.syslog_stamp, now);
    }
}

// What: the suffix of a compressed log file.
// Why: compressed files are skipped; the ui reads them.
// From: Issue #1683
const XZ_SUFFIX: &str = ".xz";

// What: xz preset 6, the xz command line default.
// Why: the maintainer set xz as the default compression.
// From: Issue #1683
const XZ_PRESET: u32 = 6;

// What: xz-compress one closed log file, then drop it.
// Why: a failed copy keeps the original; no half file.
// From: Issue #1683
fn compress_file(path: &Path) -> Result<PathBuf, String> {
    let mut packed = path.as_os_str().to_owned();
    packed.push(XZ_SUFFIX);
    let packed = PathBuf::from(packed);
    let written = fs::File::open(path).and_then(|mut src| {
        let dst = fs::File::create_new(&packed)?;
        let mut xz = liblzma::write::XzEncoder::new(dst, XZ_PRESET);
        io::copy(&mut src, &mut xz)?;
        xz.finish()?.sync_all()
    });
    if let Err(e) = written {
        let cleanup = match fs::remove_file(&packed) {
            Ok(()) => String::new(),
            Err(gone) if gone.kind() == io::ErrorKind::NotFound => String::new(),
            Err(gone) => format!("; cannot remove {}: {gone}", packed.display()),
        };
        return Err(format!(
            "ERROR: cannot compress {}: {e}{cleanup}",
            path.display()
        ));
    }
    fs::remove_file(path).map_err(|e| {
        format!(
            "ERROR: compressed {} but cannot remove it: {e}",
            path.display()
        )
    })?;
    Ok(packed)
}

// What: xz every closed syslog file under the root.
// Why: today's files are still open in syslog-ng.
// From: Issue #1683
fn compress_syslog(r: &Retention, now: u64) {
    let root = match retention_target("SYSLOG_LOG_ROOT", &r.syslog_root, &r.syslog_prefix) {
        Ok(root) => root,
        Err(e) => return log_err(&e),
    };
    if !root.is_dir() {
        return;
    }
    let files = match files_under(&root) {
        Ok(files) => files,
        Err(e) => return log_err(&format!("ERROR: cannot scan {}: {e}", root.display())),
    };
    for (path, meta) in &files {
        let done = path.as_os_str().to_string_lossy().ends_with(XZ_SUFFIX);
        if done || !meta.is_file() || written_today(meta, now) {
            continue;
        }
        match compress_file(path) {
            Ok(packed) => log(&format!("Compressed syslog file: {}", packed.display())),
            Err(e) => log_err(&e),
        }
    }
}

// What: run all three jobs each interval until stop.
// Why: docker stop sends TERM; the stop must not hang.
// From: Issue #1683 | PR #1858
async fn run_retention(r: &Retention, stop: impl std::future::Future<Output = ()>) {
    tokio::pin!(stop);
    loop {
        let now = unix_secs();
        purge_cache(r, now);
        compress_syslog(r, now);
        prune_syslog(r, now);
        tokio::select! {
            () = &mut stop => {
                return log("SIGTERM/SIGINT received; retention stopping");
            }
            () = tokio::time::sleep(r.interval) => {}
        }
    }
}

// What: retention mode, its own container and process.
// Why: deletes must never share a fate with health checks.
// From: Issue #842 | PR #1858
async fn retention() {
    use tokio::signal::unix::{SignalKind, signal};
    let _ = MODE.set("retention");
    let (r, warnings) = load_retention(config::process_env).unwrap_or_else(|msg| {
        log_err(&msg);
        std::process::exit(1);
    });
    warnings.iter().for_each(|w| log(w));
    // What: TERM and INT handlers exist before any work.
    // Why: PID 1 has no default TERM action to rely on
    let (mut term, mut int) = match (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
    ) {
        (Ok(term), Ok(int)) => (term, int),
        (Err(e), _) | (_, Err(e)) => {
            log_err(&format!("FATAL: cannot install TERM/INT handlers: {e}"));
            std::process::exit(1);
        }
    };
    log(&format!(
        "Retention daemon started. Cache: {} (valid {}d, prefix {}) | Syslog: {} (xz, prefix {}) | Interval: {}s",
        r.cache_dir,
        r.cache_valid_days,
        r.cache_prefix.display(),
        r.syslog_root,
        r.syslog_prefix.display(),
        r.interval.as_secs(),
    ));
    let stop = async move {
        tokio::select! {
            _ = term.recv() => {}
            _ = int.recv() => {}
        }
    };
    run_retention(&r, stop).await;
}

// What: the watch mode, or retention with --retention.
// Why: one binary; each mode runs in its own container.
// From: Issue #842 | PR #1858
#[tokio::main]
async fn main() {
    match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [] => watch().await,
        [mode] if mode == "--retention" => retention().await,
        _ => {
            log_err("FATAL: usage: lancache-watchdog [--retention]");
            std::process::exit(2);
        }
    }
}

// What: load settings, then run the watch loop.
// Why: a bad setting must stop the service before it acts.
async fn watch() {
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

    // What: a fresh random number in [lo, hi].
    // Why: no fixed value in a test; each run differs.
    fn rnd(lo: u64, hi: u64) -> u64 {
        use std::hash::{BuildHasher as _, Hasher as _};
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(lancache_ng::unix_nanos());
        match (hi - lo).checked_add(1) {
            Some(span) => lo + h.finish() % span,
            None => h.finish(),
        }
    }

    // What: a fresh name, never a fixed word.
    // Why: no test value stands in for an owner's value.
    fn gen_name() -> String {
        format!("v{:x}", rnd(0, u64::MAX))
    }

    // What: a fresh absolute path that does not exist.
    // Why: settings tests touch no real file.
    fn gen_path() -> String {
        format!("/{}/{}", gen_name(), gen_name())
    }

    // What: a fresh boolean in the env grammar.
    // Why: gates must hold for either value.
    fn gen_flag() -> bool {
        rnd(0, 1) == 1
    }

    // What: the value one generated env holds for key.
    // Why: assertions compare with what was loaded.
    fn value<'a>(env: &'a [(&str, String)], key: &str) -> &'a str {
        env.iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v.as_str())
            .expect("generated key")
    }

    // What: an env reader: pairs first, then env.
    // Why: tests set no process env; "" blanks a value.
    fn reader<'a>(
        env: &'a [(&'a str, String)],
        pairs: &'a [(&'a str, &'a str)],
    ) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| {
            pairs
                .iter()
                .map(|(k, v)| (*k, v.to_string()))
                .chain(env.iter().map(|(k, v)| (*k, v.clone())))
                .find(|(key, _)| *key == name)
                .map(|(_, v)| v)
        }
    }

    // What: one generated value per watchdog key.
    // Why: Rust keeps no defaults; every load needs them.
    fn base_env() -> Vec<(&'static str, String)> {
        let warn = rnd(0, u64::from(u32::MAX) - 1);
        let mode = DhcpMode::ALL[rnd(0, DhcpMode::ALL.len() as u64 - 1) as usize];
        vec![
            (
                "DOCKER_PROXY_URL",
                format!("http://{}:{}", gen_name(), rnd(1, u16::MAX.into())),
            ),
            ("CHECK_INTERVAL", rnd(1, DAY).to_string()),
            ("RESTART_AFTER", rnd(1, u32::MAX.into()).to_string()),
            ("DISK_WARN_PCT", warn.to_string()),
            ("DISK_ALARM_PCT", rnd(warn + 1, u32::MAX.into()).to_string()),
            ("CURL_MAX_TIME", rnd(1, DAY).to_string()),
            ("CURL_MAX_TIME_RESTART", rnd(1, DAY).to_string()),
            ("CACHE_DIR", gen_path()),
            ("STATUS_FILE", gen_path()),
            ("DESIRED_STATE_FILE", gen_path()),
            ("SSL_ENABLED", gen_flag().to_string()),
            ("DHCP_MODE", mode.as_str().to_string()),
            ("LOGGING_ENABLED", gen_flag().to_string()),
            ("NTP_ENABLED", gen_flag().to_string()),
        ]
    }

    // What: watchdog settings from a fresh env plus pairs.
    // Why: most tests need only the overridden keys.
    fn load(pairs: &[(&str, &str)]) -> Result<(Settings, Vec<String>), String> {
        load_settings(reader(&base_env(), pairs))
    }

    // What: knobs take the owner's value, floor, or fail.
    // Why: a bad knob must not busy-loop or restart.
    #[test]
    fn knobs_floor_and_reject() {
        let env = base_env();
        let num = |key: &str| value(&env, key).parse::<u64>().expect("number");
        let (s, warnings) = load_settings(reader(&env, &[])).expect("settings");
        assert!(warnings.is_empty(), "{warnings:?}");
        assert_eq!(s.check_interval, Duration::from_secs(num("CHECK_INTERVAL")));
        assert_eq!(
            (
                u64::from(s.restart_after),
                u64::from(s.disk_warn_pct),
                u64::from(s.disk_alarm_pct)
            ),
            (
                num("RESTART_AFTER"),
                num("DISK_WARN_PCT"),
                num("DISK_ALARM_PCT")
            )
        );
        assert_eq!(
            (s.curl_max_time, s.curl_max_time_restart),
            (
                Some(Duration::from_secs(num("CURL_MAX_TIME"))),
                Some(Duration::from_secs(num("CURL_MAX_TIME_RESTART")))
            )
        );
        assert_eq!(s.cache_dir, PathBuf::from(value(&env, "CACHE_DIR")));

        let interval = "0".repeat(rnd(1, u8::MAX.into()) as usize);
        let restart = "0".repeat(rnd(1, u8::MAX.into()) as usize);
        let floored = [("CHECK_INTERVAL", interval.as_str()), ("RESTART_AFTER", restart.as_str())];
        let (s, warnings) = load_settings(reader(&env, &floored)).expect("floored");
        assert_eq!((s.check_interval, s.restart_after), (Duration::from_secs(1), 1));
        for (key, raw) in floored {
            let want = format!("{key}={raw}");
            assert!(warnings.iter().any(|w| w.contains(&want)), "{want}: {warnings:?}");
        }

        let junk = gen_name();
        let over = (u64::from(u32::MAX) + rnd(1, DAY)).to_string();
        let negative = format!("-{}", rnd(1, DAY));
        for (name, bad) in [
            ("CHECK_INTERVAL", junk.as_str()),
            ("RESTART_AFTER", over.as_str()),
            ("DISK_WARN_PCT", negative.as_str()),
            ("DISK_ALARM_PCT", ""),
        ] {
            let err = load_settings(reader(&env, &[(name, bad)])).err().expect("fails");
            assert!(err.contains(name), "{name}={bad}: {err}");
        }
    }

    // What: curl timeouts keep fractions; 0 is unbounded.
    // Why: 0 must not time out at once; junk is fatal.
    #[test]
    fn curl_timeouts_handle_zero_fractions_and_junk() {
        let fraction = format!("{}.{}", rnd(0, DAY), rnd(1, u32::MAX.into()));
        let pairs = [("CURL_MAX_TIME", "0"), ("CURL_MAX_TIME_RESTART", fraction.as_str())];
        let (s, warnings) = load(&pairs).expect("settings");
        let secs: f64 = fraction.parse().expect("number");
        assert_eq!(s.curl_max_time, None);
        assert_eq!(s.curl_max_time_restart, Some(Duration::from_secs_f64(secs)));
        assert!(warnings.is_empty(), "{warnings:?}");
        let overflow = format!("1e{}", rnd((f64::MAX_10_EXP + 1) as u64, u16::MAX.into()));
        let negative = format!("-{fraction}");
        for bad in [gen_name(), negative, overflow, String::new()] {
            let err = load(&[("CURL_MAX_TIME", bad.as_str())]).err().expect("fails");
            assert!(err.contains("CURL_MAX_TIME"), "{bad}: {err}");
        }
    }

    // What: unset or junk owner values are fatal.
    // Why: the watchdog has no defaults to fall back on.
    #[test]
    fn missing_or_junk_owner_values_are_fatal() {
        let env = base_env();
        for (var, _) in &env {
            let err = load_settings(reader(&env, &[(*var, "")])).err().expect("fails");
            assert!(err.contains(var), "{var}: {err}");
        }
        for var in ["SSL_ENABLED", "LOGGING_ENABLED", "NTP_ENABLED"] {
            assert!(load(&[(var, gen_name().as_str())]).is_err(), "{var}");
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
        let ssl = [("SSL_ENABLED", "true")];
        for var in vars {
            let renamed = gen_name();
            assert!(load(&[(var, renamed.as_str()), ssl[0]]).is_err(), "{var}");
        }
        assert!(load(&[("CONTAINER_PROXY", config::CONTAINER_PROXY)]).is_ok());
        let other = gen_name();
        let off = [("SSL_ENABLED", "false"), ("CONTAINER_DNS_SSL", other.as_str())];
        assert!(load(&off).is_ok());
        let (a, b, c) = (gen_path(), gen_path(), gen_path());
        let split = [("CACHE_DIR", ""), ("CACHE_DIR_STANDARD", b.as_str()), ("CACHE_DIR_SSL", c.as_str())];
        let err = load(&split).err().expect("fails");
        assert!(err.contains(&b) && err.contains(&c), "{err}");
        let (s, _) = load(&[("CACHE_DIR", a.as_str()), ("CACHE_DIR_SSL", c.as_str())]).expect("settings");
        assert_eq!(s.cache_dir, PathBuf::from(&a));
        let (s, _) = load(&[("CACHE_DIR", ""), ("CACHE_DIR_SSL", c.as_str())]).expect("settings");
        assert_eq!(s.cache_dir, PathBuf::from(&c));
    }

    // What: inspect bodies map to readings and colors.
    // Why: only the newest check-log entry marks Degraded.
    // From: Issue #1296
    #[test]
    fn inspect_bodies_map_to_readings_and_colors() {
        let old = format!("DEGRADED: {}", gen_name());
        let read = |status: &str, last_output: &str| {
            let log = serde_json::json!([{"Output": old}, {"Output": last_output}]);
            let health = serde_json::json!({"Status": status, "Log": log});
            Reading::from_inspect(&serde_json::json!({"State": {"Health": health}}))
        };
        let degraded = format!("{}\nDEGRADED: {}", gen_name(), gen_name());
        let unknown = gen_name();
        assert_eq!(read("healthy", &gen_name()), Reading::Healthy);
        assert_eq!(read("healthy", &degraded), Reading::Degraded);
        assert_eq!(read("unhealthy", &degraded), Reading::Unhealthy);
        assert_eq!(read(&unknown, ""), Reading::Other(unknown.clone()));
        let bare = serde_json::json!({"State": {}});
        assert_eq!(Reading::from_inspect(&bare), Reading::None);
        let colors = [
            (Reading::Healthy, "green"),
            (Reading::Unhealthy, "red"),
            (Reading::Starting, "yellow"),
            (Reading::None, "yellow"),
            (Reading::Unreachable, "yellow"),
            (Reading::Other(unknown.clone()), "yellow"),
            (Reading::Degraded, "amber"),
        ];
        for (reading, color) in colors {
            assert_eq!(reading.describe().1, color);
        }
        assert_eq!(Reading::Degraded.describe().0, "degraded");
        assert!(Reading::Degraded.is_alert_ok() && Reading::None.is_alert_ok());
        assert!(!Reading::Unreachable.is_alert_ok());
        assert!(!Reading::Other(unknown).is_alert_ok());
    }

    // What: restart at threshold; inert reads never count.
    // Why: restarting an unreachable service is unsafe.
    #[test]
    fn counters_restart_at_threshold_and_recover_once() {
        let n = rnd(2, u8::MAX.into()) as u32;
        let inert = [
            Reading::Starting,
            Reading::None,
            Reading::Unreachable,
            Reading::Degraded,
        ];
        for reading in inert {
            let mut counter = Counter(n - 1);
            assert_eq!(counter.observe(&reading, n), Event::None);
            assert_eq!(counter.0, n - 1);
        }
        let mut counter = Counter::default();
        for i in 1..n {
            assert_eq!(counter.observe(&Reading::Unhealthy, n), Event::Failing(i));
        }
        assert_eq!(counter.observe(&Reading::Unhealthy, n), Event::Restart);
        assert_eq!(counter.0, 0);
        counter.0 = n - 1;
        assert_eq!(counter.observe(&Reading::Healthy, n), Event::Recovered);
        assert_eq!(counter.observe(&Reading::Healthy, n), Event::None);

        let k = rnd(1, u8::MAX.into()) as u32;
        for i in 1..=k {
            assert_eq!(counter.observe_alert(false), Event::Failing(i));
        }
        assert_eq!(counter.observe_alert(true), Event::Recovered);
        assert_eq!(counter.observe_alert(true), Event::None);
    }

    // What: targets follow the SSL, DHCP, log, NTP gates.
    // Why: a gated service that is off must raise no alarm.
    // From: Issue #842
    #[test]
    fn targets_follow_the_gates() {
        let names = |pairs: &[(&str, &str)]| {
            let (s, _) = load(pairs).expect("settings");
            targets(&s).into_iter().map(|t| t.0).collect::<Vec<_>>()
        };
        let off = [
            ("SSL_ENABLED", "true"),
            ("DHCP_MODE", DhcpMode::Disabled.as_str()),
            ("LOGGING_ENABLED", "false"),
            ("NTP_ENABLED", "false"),
        ];
        let base = [
            config::CONTAINER_PROXY,
            config::CONTAINER_DNS_STANDARD,
            config::CONTAINER_DNS_SSL,
            config::CONTAINER_NATS,
            config::CONTAINER_NETDATA,
            config::CONTAINER_DOCKER_SOCKET_PROXY,
            config::CONTAINER_UI,
        ];
        assert_eq!(names(&off), base);
        let no_ssl = [("SSL_ENABLED", "false"), off[1], off[2], off[3]];
        assert!(!names(&no_ssl).contains(&config::CONTAINER_DNS_SSL));
        for mode in DhcpMode::ALL {
            let all = [
                off[0],
                ("DHCP_MODE", mode.as_str()),
                ("LOGGING_ENABLED", "true"),
                ("NTP_ENABLED", "true"),
            ];
            let tail = names(&all).split_off(base.len());
            let want: Vec<&str> = mode
                .container()
                .into_iter()
                .chain([config::CONTAINER_SYSLOG, config::CONTAINER_NTP])
                .collect();
            assert_eq!(tail, want, "{}", mode.as_str());
        }
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
        let warn = rnd(1, u64::from(u32::MAX) / 2) as u32;
        let alarm = rnd(u64::from(warn) + 1, u64::from(u32::MAX) - 1) as u32;
        assert_eq!(disk_status(warn - 1, warn, alarm), "green");
        assert_eq!(disk_status(warn, warn, alarm), "yellow");
        assert_eq!(disk_status(alarm - 1, warn, alarm), "yellow");
        assert_eq!(disk_status(alarm, warn, alarm), "red");
        assert_eq!(disk_status(alarm + 1, warn, alarm), "red");
    }

    // What: a missing cache dir reads unknown, not green.
    // Why: no reading must not look like a healthy disk.
    #[test]
    fn disk_info_is_unknown_for_a_missing_dir() {
        let info = disk_info(Path::new(&gen_path()), 0, 1);
        assert_eq!((info.pct, info.status.as_str()), (0, "unknown"));
    }

    // What: the timestamp keeps its fixed UTC shape.
    // Why: status.json's `updated` field is a contract.
    #[test]
    fn stamp_has_the_fixed_shape() {
        let secs = rnd(0, i32::MAX as u64) as i64;
        let at = OffsetDateTime::from_unix_timestamp(secs).expect("time");
        let want = format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            at.year(),
            u8::from(at.month()),
            at.day(),
            at.hour(),
            at.minute(),
            at.second()
        );
        assert_eq!(stamp(at), want);
    }

    // What: curl timeouts refuse inf, NaN, negatives.
    // Why: only a finite positive number is a real limit.
    #[test]
    fn curl_timeout_refuses_non_finite_and_negative_numbers() {
        let negative = format!("-{}.{}", rnd(0, DAY), rnd(1, u32::MAX.into()));
        for bad in ["inf", "NaN", negative.as_str()] {
            assert_eq!(
                curl_timeout(Some(bad), "CURL_MAX_TIME"),
                Err(format!("FATAL: invalid CURL_MAX_TIME={bad}."))
            );
        }
    }

    // What: an existing cache dir reads a real status.
    // Why: only a missing dir or failed df is unknown.
    #[test]
    fn disk_info_reads_an_existing_dir() {
        let warn = rnd(u8::MAX.into(), u64::from(u32::MAX) - 1) as u32;
        let info = disk_info(&std::env::temp_dir(), warn, warn + 1);
        assert_eq!(info.status, "green");
        assert!(info.pct <= 100);
    }

    // What: one generated value per retention key.
    // Why: no defaults; every load needs every key
    fn retention_env() -> Vec<(&'static str, String)> {
        let gb = config::SYSLOG_MAX_GB;
        vec![
            ("CHECK_INTERVAL", rnd(1, DAY).to_string()),
            ("CACHE_DIR", gen_path()),
            ("CACHE_DIR_ALLOWED_PREFIX", gen_path()),
            ("CACHE_VALID_DAYS", rnd(0, DAY).to_string()),
            ("PURGE_STAMP", gen_path()),
            ("SYSLOG_LOG_ROOT", gen_path()),
            ("SYSLOG_LOG_ROOT_ALLOWED_PREFIX", gen_path()),
            ("SYSLOG_RETENTION_DAYS", rnd(0, DAY).to_string()),
            ("SYSLOG_MAX_GB", rnd(gb.min, gb.max).to_string()),
            ("SYSLOG_PRUNE_RETRY_COOLDOWN", rnd(0, DAY).to_string()),
            ("SYSLOG_PRUNE_STAMP", gen_path()),
        ]
    }

    // What: retention settings fail closed on unsafe input.
    // Why: a zero budget would delete every log at once.
    #[test]
    fn retention_settings_load_and_reject_unsafe_values() {
        let env = retention_env();
        let num = |key: &str| value(&env, key).parse::<u64>().expect("number");
        let (r, warnings) = load_retention(reader(&env, &[])).expect("settings");
        assert!(warnings.is_empty(), "{warnings:?}");
        assert_eq!(r.syslog_max_bytes, num("SYSLOG_MAX_GB") << 30);
        assert_eq!(
            (r.cache_valid_days, r.syslog_days, r.syslog_cooldown),
            (
                num("CACHE_VALID_DAYS"),
                num("SYSLOG_RETENTION_DAYS"),
                num("SYSLOG_PRUNE_RETRY_COOLDOWN")
            )
        );
        assert_eq!(r.purge_stamp, PathBuf::from(value(&env, "PURGE_STAMP")));
        for (key, _) in &env {
            assert!(load_retention(reader(&env, &[(*key, "")])).is_err(), "{key} blank");
        }
        let (junk, relative) = (gen_name(), format!("{}/{}", gen_name(), gen_name()));
        let bad = [
            ("SYSLOG_MAX_GB", "0"),
            ("CACHE_VALID_DAYS", junk.as_str()),
            ("CACHE_DIR_ALLOWED_PREFIX", relative.as_str()),
            ("PURGE_STAMP", relative.as_str()),
        ];
        for (key, raw) in bad {
            assert!(load_retention(reader(&env, &[(key, raw)])).is_err(), "{key}={raw}");
        }
        let above = (config::SYSLOG_MAX_GB.max + rnd(1, DAY)).to_string();
        let long = (DAY + rnd(1, DAY)).to_string();
        let high = [("SYSLOG_MAX_GB", above.as_str()), ("SYSLOG_PRUNE_RETRY_COOLDOWN", long.as_str())];
        let (r, warnings) = load_retention(reader(&env, &high)).expect("clamped");
        assert_eq!(
            (r.syslog_max_bytes, r.syslog_cooldown),
            (config::SYSLOG_MAX_GB.max << 30, DAY)
        );
        assert_eq!(warnings.len(), high.len(), "{warnings:?}");
    }

    // What: a canonical scratch root for one test.
    // Why: targets resolve symlinks; the prefix must too.
    fn scratch() -> PathBuf {
        fs::canonicalize(lancache_ng::unique_temp_dir(&gen_name())).expect("scratch root")
    }

    // What: retention settings on a scratch tree.
    // Why: each test owns its paths and fresh limits.
    fn scratch_retention(root: &Path) -> Retention {
        let max_days = unix_secs() / DAY / 2;
        let under = |prefix: &Path| prefix.join(gen_name()).display().to_string();
        let (cache, syslog) = (root.join(gen_name()), root.join(gen_name()));
        Retention {
            interval: Duration::from_secs(rnd(DAY, 2 * DAY)),
            cache_dir: under(&cache),
            cache_prefix: cache,
            cache_valid_days: rnd(1, max_days),
            purge_stamp: root.join(gen_name()),
            syslog_root: under(&syslog),
            syslog_prefix: syslog,
            syslog_days: rnd(1, max_days),
            syslog_max_bytes: rnd(4, u16::MAX.into()),
            syslog_cooldown: rnd(0, DAY),
            syslog_stamp: root.join(gen_name()),
        }
    }

    // What: a file of len bytes with mtime at epoch secs.
    // Why: age tests need a known mtime, not a sleep.
    fn file_at(path: &Path, len: u64, mtime: u64) {
        fs::create_dir_all(path.parent().expect("parent")).expect("parent dir");
        fs::write(path, vec![0; len as usize]).expect("write");
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(mtime);
        fs::File::options()
            .write(true)
            .open(path)
            .and_then(|f| f.set_modified(at))
            .expect("set mtime");
    }

    // What: seconds that put a file past days whole days.
    // Why: find -mtime +N needs more than N whole days.
    fn past(days: u64) -> u64 {
        (days + 1) * DAY + rnd(1, DAY - 1)
    }

    // What: the stamp a run left, as a number.
    // Why: the daily gate and retry read this value.
    fn stamp_of(path: &Path) -> u64 {
        fs::read_to_string(path)
            .expect("stamp")
            .trim()
            .parse()
            .expect("number")
    }

    // What: each target input maps or fails, one table.
    // Why: a bad value must never reach a delete.
    #[test]
    fn retention_target_maps_each_input() {
        let root = scratch();
        let prefix = root.join(gen_name());
        let (real, sub, missing) = (prefix.join(gen_name()), gen_name(), gen_name());
        let outside = root.join(gen_name());
        fs::create_dir_all(real.join(&sub)).expect("tree");
        fs::create_dir_all(&outside).expect("outside");
        let (escape, dangling) = (prefix.join(gen_name()), prefix.join(gen_name()));
        std::os::unix::fs::symlink(&outside, &escape).expect("symlink");
        std::os::unix::fs::symlink(root.join(gen_name()), &dangling).expect("symlink");
        let at = |p: &Path| p.display().to_string();
        let back = format!("{}/{sub}/../../{}", at(&real), real.file_name().unwrap().to_string_lossy());
        let ok = [
            (at(&real), real.clone()),
            (at(&prefix.join(&missing)), prefix.join(&missing)),
            (back, real.clone()),
        ];
        for (raw, want) in ok {
            assert_eq!(retention_target("CACHE_DIR", &raw, &prefix), Ok(want), "{raw}");
        }
        let bad = [
            (String::new(), "is empty"),
            (format!("{}/{}", gen_name(), gen_name()), "is not an absolute path"),
            (at(&outside), "outside the expected"),
            (format!("{}/../../{}", at(&real), outside.file_name().unwrap().to_string_lossy()), "outside the expected"),
            (at(&escape.join(gen_name())), "outside the expected"),
            (at(&dangling.join(gen_name())), "could not be canonicalized"),
            (at(&prefix), "itself, not a subdirectory"),
        ];
        for (raw, want) in bad {
            let got = retention_target("CACHE_DIR", &raw, &prefix);
            assert!(got.as_ref().is_err_and(|e| e.contains(want)), "{raw}: {got:?}");
        }
    }

    // What: purge outside its prefix deletes nothing.
    // Why: the refusal leaves no stamp, so a fix retries.
    #[test]
    fn purge_refuses_a_dir_outside_its_prefix() {
        let root = scratch();
        let mut r = scratch_retention(&root);
        let outside = root.join(gen_name());
        r.cache_dir = outside.display().to_string();
        let old = outside.join(gen_name());
        let now = unix_secs();
        file_at(&old, rnd(1, u8::MAX.into()), now - past(r.cache_valid_days));
        purge_cache(&r, now);
        assert!(old.exists(), "a refused purge deleted a file");
        assert!(!r.purge_stamp.exists(), "a refused purge wrote a stamp");
    }

    // What: purge deletes files past the limit, once a day.
    // Why: newer files stay; a broken stamp must not block.
    #[test]
    fn purge_deletes_past_the_limit_once_a_day() {
        let root = scratch();
        let r = scratch_retention(&root);
        let dir = PathBuf::from(&r.cache_dir);
        let old = dir.join(gen_name()).join(gen_name());
        let new = dir.join(gen_name()).join(gen_name());
        let (days, now) = (r.cache_valid_days, unix_secs());
        file_at(&old, rnd(1, u8::MAX.into()), now - past(days));
        file_at(&new, rnd(1, u8::MAX.into()), now - days * DAY - rnd(0, DAY - 1));
        purge_cache(&r, now);
        assert!(!old.exists() && new.exists(), "wrong files purged");
        assert_eq!(stamp_of(&r.purge_stamp), now);
        file_at(&old, rnd(1, u8::MAX.into()), now - past(days));
        purge_cache(&r, now + rnd(0, DAY - 1));
        assert!(old.exists(), "a second purge within a day ran");
        for broken in [gen_name(), (now + rnd(1, DAY)).to_string()] {
            fs::write(&r.purge_stamp, &broken).expect("stamp");
            purge_cache(&r, now);
            assert!(!old.exists(), "stamp {broken} blocked the purge");
            file_at(&old, rnd(1, u8::MAX.into()), now - past(days));
        }
    }

    // What: age floor, then oldest-first to the budget.
    // Why: a file written today stays even over budget.
    #[test]
    fn syslog_prune_keeps_floor_budget_and_today() {
        let root = scratch();
        let r = scratch_retention(&root);
        let dir = PathBuf::from(&r.syslog_root).join(gen_name());
        let (aged, live) = (dir.join(gen_name()), dir.join(gen_name()));
        let (older, newer) = (dir.join(gen_name()), dir.join(gen_name()));
        let budget = r.syslog_max_bytes;
        let live_len = rnd(1, budget / 2);
        let newer_len = rnd(1, budget - live_len);
        let older_len = rnd(budget - live_len - newer_len + 1, budget);
        let quarter = DAY / 4;
        let midnight = (unix_secs() / DAY - 1) * DAY;
        let now = midnight + rnd(DAY / 2, DAY - 1);
        let newer_at = midnight - rnd(1, quarter);
        file_at(&aged, rnd(1, u8::MAX.into()), now - past(r.syslog_days));
        file_at(&live, live_len, rnd(midnight, now));
        file_at(&newer, newer_len, newer_at);
        file_at(&older, older_len, newer_at - rnd(1, quarter));
        prune_syslog(&r, now);
        assert!(!aged.exists() && !older.exists(), "floor or budget not applied");
        assert!(live.exists() && newer.exists(), "pruned beyond the budget");
        assert_eq!(stamp_of(&r.syslog_stamp), now);
        fs::remove_file(&newer).expect("remove");
        let later = now + DAY + rnd(0, DAY);
        file_at(&live, budget + rnd(1, budget), rnd(later - later % DAY, later));
        prune_syslog(&r, later);
        assert!(live.exists(), "the file written today was pruned");
        assert_eq!(stamp_of(&r.syslog_stamp), later + r.syslog_cooldown - DAY);
    }

    // What: closed files become .xz; today's stay plain.
    // Why: syslog-ng still writes today's per-host files.
    #[test]
    fn syslog_files_compress_to_xz_except_today() {
        let root = scratch();
        let r = scratch_retention(&root);
        let dir = PathBuf::from(&r.syslog_root).join(gen_name());
        let (closed, live) = (dir.join(gen_name()), dir.join(gen_name()));
        let midnight = unix_secs() / DAY * DAY;
        let now = midnight + rnd(1, DAY - 1);
        let content: Vec<u8> = (0..rnd(1, u16::MAX.into()))
            .map(|_| rnd(0, u8::MAX.into()) as u8)
            .collect();
        fs::create_dir_all(&dir).expect("dir");
        fs::write(&closed, &content).expect("closed");
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(midnight - rnd(1, DAY));
        fs::File::options()
            .write(true)
            .open(&closed)
            .and_then(|f| f.set_modified(at))
            .expect("set mtime");
        file_at(&live, rnd(1, u8::MAX.into()), rnd(midnight, now));
        compress_syslog(&r, now);
        let mut packed = closed.as_os_str().to_owned();
        packed.push(XZ_SUFFIX);
        let packed = PathBuf::from(packed);
        assert!(!closed.exists() && live.exists(), "wrong file compressed");
        let mut decoded = Vec::new();
        let file = fs::File::open(&packed).expect("xz file");
        io::Read::read_to_end(&mut liblzma::read::XzDecoder::new(file), &mut decoded)
            .expect("xz decode");
        assert_eq!(decoded, content);
        compress_syslog(&r, now);
        assert!(packed.exists(), "an .xz file was compressed again");
    }

    // What: a failed compression keeps the original file.
    // Why: no log line may vanish; no half .xz may stay.
    #[test]
    fn a_failed_compression_keeps_the_original() {
        let root = scratch();
        let path = root.join(gen_name());
        fs::write(&path, gen_name()).expect("file");
        let mut packed = path.as_os_str().to_owned();
        packed.push(XZ_SUFFIX);
        fs::create_dir(PathBuf::from(&packed)).expect("blocker");
        let err = compress_file(&path).expect_err("compressed over a dir");
        assert!(err.contains(&path.display().to_string()), "{err}");
        assert!(path.exists(), "the original was removed");
    }

    // What: the loop ends when stop fires mid-sleep
    // Why: docker stop sends TERM; a hang ends in a kill
    #[tokio::test]
    async fn retention_stops_at_once_mid_sleep() {
        let r = scratch_retention(&scratch());
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let run = tokio::spawn(async move {
            run_retention(&r, async {
                let _ = rx.await;
            })
            .await;
        });
        tokio::time::sleep(Duration::from_millis(rnd(1, u8::MAX.into()))).await;
        tx.send(()).expect("stop");
        tokio::time::timeout(Duration::from_secs(rnd(1, u8::MAX.into())), run)
            .await
            .expect("still running after stop")
            .expect("retention task");
    }
}
