//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: supervisor of every program in one container.
//! Why: one Rust supervisor starts every image's programs.
//! From: Issue #842 | PR #1912

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::os::unix::fs::MetadataExt as _;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use dhcproto::v4::{DhcpOption, Flags, Message, MessageType, OptionCode};
use dhcproto::{Decodable, Decoder, Encodable, Encoder};

use lancache_ng::config::{
    self, DhcpMode, NatsLogin, NatsRoles, OutOfRange, PROXY_ACCESS_LOG_PATTERN, Uint, env_opt,
    render_nats_conf,
};
use lancache_ng::{
    ALARM_INGEST_PATH, ALARM_TOKEN_HEADER, Backoff, COMPOSE_PROJECT_LABEL, COMPOSE_SERVICE_LABEL,
    CaFiles, CertSpec, ClientCheck, ConflictCheck, DOCKER_UNIX_PREFIX, DesiredRunState,
    DesiredState, Detail, DiskHealth, DiskInfo, DockerApi, NetdataAlarm, Place, ProbeAnswer,
    ProbeReport, ServiceHealth, WatchdogStatus, df, files_under, hex32, is_placeholder,
    metadata_if_present, need_secs, openssl_ca, openssl_leaf, openssl_x509, own, probe_health,
    probe_health_tls, resolve_shared_secret, run_program, sha256_hex, shared_secret_file_name,
    terminate, unix_nanos, unix_secs, write_file, write_if_changed,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

// What: central-control settings, read once at start.
// Why: a deployment change recreates this container.
// From: Issue #1683 | PR #1912
struct Settings {
    docker_host: String,
    check_interval: Duration,
    restart_after: u32,
    // What: None means no timeout; 0 in the env.
    // Why: ZERO would mean "instant" to the HTTP client.
    // From: Issue #1683 | PR #1912
    api_timeout: Option<Duration>,
    restart_timeout: Option<Duration>,
    // What: seconds Docker waits for TERM before KILL.
    // Why: stays inside the restart call's own API budget.
    // From: Issue #1683 | PR #1912
    restart_grace: u32,
    disk_warn_pct: u32,
    disk_alarm_pct: u32,
    status_file: PathBuf,
    cache_dir: PathBuf,
    // What: log root and syslog-ng control socket.
    // Why: the log-loss check compares both.
    // From: Issue #1683 | PR #1912
    syslog_root: PathBuf,
    syslog_ctl: PathBuf,
    // What: this container's id, Docker's default hostname.
    // Why: its compose project label names the stack.
    // From: Issue #1683 | PR #1912
    own_id: String,
}

// What: seconds as a timeout; 0 means no timeout (None).
// Why: fractions stay valid; 0 must not time out at once.
// From: Issue #1683 | PR #1912
fn api_timeout(raw: Option<&str>, name: &str) -> Result<Option<Duration>, String> {
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
// Why: watch and retention read knobs by one rule.
// From: Issue #1683 | PR #1858
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

// What: settings from an env reader, plus startup warnings.
// Why: Err is fatal; a reader arg keeps tests env-free.
// From: Issue #849 | PR #1912
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
    let restart_grace = knob("DOCKER_RESTART_GRACE", 0, u32::MAX.into())?;
    let disk_warn_pct = knob("DISK_WARN_PCT", 0, u32::MAX.into())?;
    let disk_alarm_pct = knob("DISK_ALARM_PCT", 0, u32::MAX.into())?;
    let api = api_timeout(get("DOCKER_API_TIMEOUT").as_deref(), "DOCKER_API_TIMEOUT")?;
    let restart = api_timeout(
        get("DOCKER_RESTART_TIMEOUT").as_deref(),
        "DOCKER_RESTART_TIMEOUT",
    )?;
    let need = |name: &str| config::need(&env, name).map_err(|e| format!("FATAL: {e}."));
    let settings = Settings {
        docker_host: format!("{DOCKER_UNIX_PREFIX}{}", need("DOCKER_SOCKET")?),
        check_interval: Duration::from_secs(check_interval),
        restart_after: restart_after as u32,
        api_timeout: api,
        restart_timeout: restart,
        restart_grace: restart_grace as u32,
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file: PathBuf::from(need("STATUS_FILE")?),
        cache_dir: PathBuf::from(need("CACHE_DIR")?),
        syslog_root: PathBuf::from(need("SYSLOG_LOG_ROOT")?),
        syslog_ctl: Path::new(&need("SUPERVISE_RUN_DIR")?).join(SYSLOG_NG_CTL),
        own_id: need("HOSTNAME")?,
    };
    Ok((settings, warnings))
}

// What: typed Docker health plus watchdog's own outcomes.
// Why: restarts use Healthy/Unhealthy; alerts is_alert_ok.
// From: Issue #1683 | PR #1858
#[derive(Debug, Clone, PartialEq, Eq)]
enum Reading {
    Healthy,
    Unhealthy,
    Starting,
    // What: Docker reports no health status at all.
    // Why: a valid answer, unlike an unreachable proxy.
    // From: Issue #1683 | PR #1858
    None,
    // What: no reading at all (network, timeout, non-2xx).
    // Why: not a Docker-reported state.
    // From: Issue #1683 | PR #1858
    Unreachable,
    // What: an unknown Docker health string, verbatim.
    // Why: never coerce it into a known variant.
    // From: Issue #1683 | PR #1858
    Other(String),
    // What: healthy, but the check printed DEGRADED: text.
    // Why: reduced guarantees must stay visible (ntp).
    // From: Issue #1683 | PR #1858
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
        // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn is_alert_ok(&self) -> bool {
        matches!(
            self,
            Self::Healthy | Self::Starting | Self::None | Self::Degraded
        )
    }
}

// What: what the loop logs or does after one reading.
// Why: None covers steady health and all inert readings.
// From: Issue #1683 | PR #1858
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Event {
    None,
    Failing(u32),
    // What: restart, then the counter resets to 0.
    // Why: reset even if the restart call itself fails.
    // From: Issue #1683 | PR #1858
    Restart,
    Recovered,
}

// What: consecutive failures of one monitored service.
// Why: a restart fires only after RESTART_AFTER misses.
// From: Issue #1683 | PR #1858
#[derive(Debug, Default)]
struct Counter(u32);

impl Counter {
    // What: reset to zero; Recovered if a streak ran.
    // Why: RECOVERED is logged once per outage, not cycle.
    // From: Issue #1683 | PR #1858
    fn clear(&mut self) -> Event {
        if std::mem::take(&mut self.0) > 0 {
            Event::Recovered
        } else {
            Event::None
        }
    }

    // What: count one reading of a restart-capable service.
    // Why: inert readings keep the counter; no restart.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn observe_alert(&mut self, ok: bool) -> Event {
        if ok {
            return self.clear();
        }
        self.0 = self.0.saturating_add(1);
        Event::Failing(self.0)
    }
}

// What: UTC time as YYYY-MM-DDTHH:MM:SSZ, no fractions.
// Why: status.json's `updated` format is a fixed contract.
// From: Issue #1683 | PR #1858
fn stamp(at: OffsetDateTime) -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    at.format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

tokio::task_local! {
    // What: log tag of the task writing a line.
    // Why: watch, retention, supervise share one process.
    // From: Issue #1683
    static TAG: &'static str;
}

// What: the "[tag] HH:MM:SS" line prefix.
// Why: operators grep the logs for this exact shape.
// From: Issue #1683 | PR #1912
fn prefix() -> String {
    let tag = TAG.try_with(|t| *t).unwrap_or("watchdog");
    format!("[{tag}] {}", &stamp(OffsetDateTime::now_utc())[11..19])
}

// What: one prefixed line to stdout or stderr.
// Why: Docker sends both streams on to syslog-ng.
// From: Issue #1683
fn emit(msg: &str, to_stderr: bool) {
    let line = format!("{} {msg}", prefix());
    if to_stderr {
        eprintln!("{line}");
    } else {
        println!("{line}");
    }
}

// What: write one info line.
// Why: callers need no stream choice for normal output.
// From: Issue #1683 | PR #1858
fn log(msg: &str) {
    emit(msg, false);
}

// What: write one error line to stderr.
// Why: errors stay visible apart from normal output.
// From: Issue #1683 | PR #1858
fn log_err(msg: &str) {
    emit(msg, true);
}

// What: the color of a disk use percent.
// Why: alarm outranks warn; below both is green.
// From: Issue #1683 | PR #1858
fn disk_status(pct: u32, warn_pct: u32, alarm_pct: u32) -> &'static str {
    if pct >= alarm_pct {
        "red"
    } else if pct >= warn_pct {
        "yellow"
    } else {
        "green"
    }
}

// What: true for an existing dir; a stat fault is logged.
// Why: "does not exist" must not hide a permission fault.
// From: Issue #1683 | PR #1912
fn dir_present(dir: &Path) -> bool {
    match metadata_if_present(dir) {
        Ok(meta) => meta.is_some_and(|meta| meta.is_dir()),
        Err(e) => {
            log_err(&format!("ERROR: {e}"));
            false
        }
    }
}

// What: true for an existing file; a stat fault is Err.
// Why: a key or CA must not be made again on a fault.
// From: Issue #1683 | PR #1912
fn file_present(path: &Path) -> Result<bool, String> {
    Ok(metadata_if_present(path)
        .map_err(|e| e.to_string())?
        .is_some_and(|meta| meta.is_file()))
}

// What: cache disk use as a traffic-light status.
// Why: a missing directory or failed df is unknown.
// From: Issue #1683 | PR #1912
fn disk_info(dir: &Path, warn_pct: u32, alarm_pct: u32) -> DiskHealth {
    let unknown = DiskHealth {
        pct: 0,
        status: "unknown".to_string(),
    };
    if !dir_present(dir) {
        return unknown;
    }
    // What: a failed df is unknown, logged with its cause.
    // Why: "unknown" alone does not say what went wrong.
    // From: Issue #1683 | PR #1912
    match df(dir) {
        Ok(d) => DiskHealth {
            pct: d.used_pct,
            status: disk_status(d.used_pct, warn_pct, alarm_pct).to_string(),
        },
        Err(e) => {
            log_err(&format!("WARNING: cache disk use unknown: {e}"));
            unknown
        }
    }
}

// What: seconds of one day, the stamp rate limit.
// Why: purge and syslog prune run at most once a day.
// From: Issue #1683 | PR #1858
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
    let interval = knob(Uint {
        below: OutOfRange::Clamp,
        ..Uint::strict("CHECK_INTERVAL", 1, u64::MAX)
    })?;
    let cache_valid_days = knob(Uint::strict("CACHE_VALID_DAYS", 0, u64::MAX))?;
    let syslog_days = knob(Uint::strict("SYSLOG_RETENTION_DAYS", 0, u64::MAX))?;
    let syslog_gb = knob(config::SYSLOG_MAX_GB)?;
    let syslog_cooldown = knob(Uint {
        above: OutOfRange::Clamp,
        ..Uint::strict("SYSLOG_PRUNE_RETRY_COOLDOWN", 0, DAY)
    })?;
    let retention = Retention {
        interval: Duration::from_secs(interval),
        cache_dir: need("CACHE_DIR")?,
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
// From: Issue #1683 | PR #1858
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
                    // From: Issue #1683 | PR #1858
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
        return Err(format!(
            "FATAL: {name} is empty; refusing to guess a target."
        ));
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

// What: a file's mtime since the epoch, or why not.
// Why: one owner for both mtime readers in this file.
// From: Issue #1683 | PR #1912
fn file_time(meta: &fs::Metadata) -> Result<Duration, String> {
    let modified = meta.modified().map_err(|e| e.to_string())?;
    modified
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|e| e.to_string())
}

// What: a file's mtime in epoch seconds, else now, logged.
// Why: an unreadable mtime must never look old.
// From: Issue #1683 | PR #1912
fn mtime_secs(meta: &fs::Metadata, now: u64) -> u64 {
    match file_time(meta) {
        Ok(d) => d.as_secs(),
        Err(e) => {
            log_err(&format!("WARNING: file time unreadable, taken as now: {e}"));
            now
        }
    }
}

// What: whole days since the file's last change.
// Why: find -mtime +N counts days the same way.
// From: Issue #1683 | PR #1858
fn age_days(meta: &fs::Metadata, now: u64) -> u64 {
    now.saturating_sub(mtime_secs(meta, now)) / DAY
}

// What: remove a path only while it is a regular file.
// Why: a path replaced since the scan stays untouched.
// From: Issue #1683 | PR #1858
fn remove_file_if_regular(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() => match fs::remove_file(path) {
            Ok(()) => true,
            Err(e) => {
                log_err(&format!("ERROR: cannot remove {}: {e}", path.display()));
                false
            }
        },
        Ok(_) => false,
        // What: a path gone since the scan is skipped.
        // Why: any other stat error is logged, not hidden.
        // From: Issue #1683 | PR #1912
        Err(e) if e.kind() == io::ErrorKind::NotFound => false,
        Err(e) => {
            log_err(&format!("ERROR: cannot stat {}: {e}", path.display()));
            false
        }
    }
}

// What: last run from a stamp; junk or future reads 0.
// Why: a broken stamp must not block the daily run.
// From: Issue #1683 | PR #1858
fn read_stamp(path: &Path, now: u64) -> u64 {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return 0,
        Err(e) => {
            log_err(&format!(
                "ERROR: cannot read {}: {e}; resetting",
                path.display()
            ));
            return 0;
        }
    };
    let raw = raw.trim();
    let digits = !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit());
    match raw.parse::<u64>() {
        Ok(last) if digits && last <= now => last,
        Ok(_) if digits => {
            log(&format!(
                "{}={raw} is in the future; resetting",
                path.display()
            ));
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
// From: Issue #1683 | PR #1858
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
    if !dir_present(&dir) {
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
// Why: syslog-ng still writes today's per-program files.
// From: Issue #1683 | PR #1858
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
    if !dir_present(&root) {
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
            log_err(&format!(
                "ERROR: cannot scan {} ({what}): {e}",
                root.display()
            ))
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
        log(&format!(
            "Syslog size within budget: {size} <= {budget} bytes"
        ));
        return write_stamp(&r.syslog_stamp, now);
    }
    log(&format!(
        "Syslog size budget exceeded: {size} > {budget} bytes; pruning oldest first"
    ));
    // What: oldest first by mtime_secs; unreadable is now.
    // Why: an unreadable mtime must not be deleted first.
    // From: Issue #1683 | PR #1912
    files.sort_by_key(|(_, meta)| mtime_secs(meta, now));
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
        write_stamp(
            &r.syslog_stamp,
            (now + r.syslog_cooldown).saturating_sub(DAY),
        );
    } else {
        write_stamp(&r.syslog_stamp, now);
    }
}

// What: the suffix of a compressed log file.
// Why: compressed files are skipped; the ui reads them.
// From: Issue #1683
const XZ_SUFFIX: &str = ".xz";

// What: xz compression preset 6 for closed log files.
// Why: fixed constant, not a configured knob.
// From: Issue #1683 | PR #1912
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
    if !dir_present(&root) {
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

// What: retention settings, then the loop until stop.
// Why: a bad setting must stop the task before deletes.
// From: Issue #842 | PR #1912
async fn retention() -> Result<(), String> {
    let (r, warnings) = load_retention(config::process_env)?;
    warnings.iter().for_each(|w| log(w));
    log(&format!(
        "Retention started. Cache: {} (valid {}d, prefix {}) | Syslog: {} (xz, prefix {}) | Interval: {}s",
        r.cache_dir,
        r.cache_valid_days,
        r.cache_prefix.display(),
        r.syslog_root,
        r.syslog_prefix.display(),
        r.interval.as_secs(),
    ));
    run_retention(&r, std::future::pending()).await;
    Ok(())
}

// What: the stack's compose project, from this container.
// Why: no project name is configured; the label names it.
// From: Issue #1683 | PR #1912
async fn own_project(docker: &DockerApi, s: &Settings) -> Result<(String, String), String> {
    let body = docker
        .inspect(&s.own_id, s.api_timeout)
        .await
        .map_err(|e| format!("cannot inspect own container {}: {e}", s.own_id))?;
    let label = format!("/Config/Labels/{COMPOSE_PROJECT_LABEL}");
    let project = body.pointer(&label).and_then(Value::as_str);
    let name = body.pointer("/Name").and_then(Value::as_str);
    match (project, name) {
        (Some(project), Some(name)) => Ok((project.to_string(), container_name(name))),
        _ => Err(format!("container {} has no compose project", s.own_id)),
    }
}

// What: a container name without Docker's leading slash.
// Why: list and inspect answers both carry the slash.
// From: Issue #1683 | PR #1912
fn container_name(raw: &str) -> String {
    raw.trim_start_matches('/').to_string()
}

// What: name and compose service of one list entry.
// Why: status.json is keyed by service, calls by name.
// From: Issue #1683 | PR #1912
fn listed(entry: &Value) -> Option<(String, String)> {
    let name = entry.pointer("/Names/0")?.as_str()?;
    let service = entry.get("Labels")?.get(COMPOSE_SERVICE_LABEL)?.as_str()?;
    Some((container_name(name), service.to_string()))
}

// What: check every stack container; restart failures.
// Why: one actor with the socket; its own box only alerts.
// From: Issue #842 | PR #1912
async fn watch() -> Result<(), String> {
    let (s, warnings) = load_settings(config::process_env)?;
    warnings.iter().for_each(|w| log(w));
    let docker = DockerApi::new(&s.docker_host);
    let (project, own_name) = own_project(&docker, &s).await?;
    log(&format!(
        "Watchdog started. Project: {project} | Interval: {}s | Restart after: {} | Disk warn: {}% alarm: {}% | Cache: {}",
        s.check_interval.as_secs(),
        s.restart_after,
        s.disk_warn_pct,
        s.disk_alarm_pct,
        s.cache_dir.display(),
    ));
    let mut counters: HashMap<String, Counter> = HashMap::new();
    let mut last_sample: Option<LogSample> = None;
    let mut loss_streak = 0;
    loop {
        // What: log writing is one more status row.
        // Why: a silent loss must not stay silent.
        // From: Issue #1428 | PR #1912
        let sample = log_sample(&s);
        let (log_health, streak) = log_row(last_sample, sample, loss_streak);
        if streak > loss_streak {
            log_err(
                "ALERT: silent log loss: syslog-ng processed messages but no log file was written",
            );
        }
        loss_streak = streak;
        last_sample = sample.or(last_sample);
        let mut services: HashMap<String, ServiceHealth> = HashMap::new();
        services.insert(LOG_ROW.to_string(), log_health);
        let listing = match docker.project_containers(&project, s.api_timeout).await {
            Ok(listing) => listing,
            Err(e) => {
                log_err(&format!("WARNING: cannot list the stack containers: {e}"));
                write_status(&s, services)?;
                tokio::time::sleep(s.check_interval).await;
                continue;
            }
        };
        for (name, service) in listing.iter().filter_map(listed) {
            // What: failed inspect is unreachable.
            // Why: counter acts; the cause is logged.
            // From: Issue #1683 | PR #1912
            let reading = match docker.inspect(&name, s.api_timeout).await {
                Ok(body) => Reading::from_inspect(&body),
                Err(e) => {
                    log_err(&format!("WARNING: cannot inspect {name}: {e}"));
                    Reading::Unreachable
                }
            };
            // What: own container only alerts.
            // Why: a self-restart ends this restart call.
            // From: Issue #1683 | PR #1912
            let restart = name != own_name;
            let counter = counters.entry(name.clone()).or_default();
            let event = if restart {
                counter.observe(&reading, s.restart_after)
            } else {
                counter.observe_alert(reading.is_alert_ok())
            };
            match event {
                Event::None => {}
                Event::Recovered => log(&format!("RECOVERED {name}")),
                Event::Failing(count) => {
                    log(&format!("UNHEALTHY {name} ({count}/{})", s.restart_after));
                }
                Event::Restart => {
                    log(&format!("RESTARTING {name}"));
                    if let Err(e) = docker
                        .restart(&name, s.restart_grace, s.restart_timeout)
                        .await
                    {
                        log_err(&format!("WARNING: restart of {name} failed: {e}"));
                    }
                }
            }
            let (health, color) = reading.describe();
            services.insert(
                service,
                ServiceHealth {
                    status: color.to_string(),
                    health: health.to_string(),
                    failures: counter.0,
                },
            );
        }
        write_status(&s, services)?;
        tokio::time::sleep(s.check_interval).await;
    }
}

// What: write status.json for the ui, atomically.
// Why: a failed write ends the task; health turns red.
// From: Issue #1683 | PR #1912
fn write_status(s: &Settings, services: HashMap<String, ServiceHealth>) -> Result<(), String> {
    let status = WatchdogStatus {
        updated: stamp(OffsetDateTime::now_utc()),
        services,
        disk: DiskInfo {
            cache: disk_info(&s.cache_dir, s.disk_warn_pct, s.disk_alarm_pct),
        },
        interval_secs: s.check_interval.as_secs(),
    };
    let body =
        serde_json::to_string_pretty(&status).expect("WatchdogStatus has only serializable fields");
    write_file(&s.status_file, body.as_bytes(), 0o644, Place::Replace)
        .map_err(|e| format!("cannot write {}: {e}", s.status_file.display()))
}

// What: supervisor times: tick, backoff, stop grace.
// Why: the SOT owns each value; Rust names only keys.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy)]
struct Timing {
    // What: how often the supervisor converges.
    // Why: every program is re-checked once per tick.
    // From: Issue #1683 | PR #1912
    tick: Duration,
    // What: restart pauses, RETRY_BACKOFF_START up to _MAX.
    // Why: a crash loop must slow down, not spin.
    // From: Issue #1683 | PR #1912
    backoff: Backoff,
    // What: a run this long resets the restart backoff.
    // Why: one late crash must not keep the long pause.
    // From: Issue #1683 | PR #1912
    backoff_reset: Duration,
    // What: wait for a stopped program before SIGKILL.
    // Why: TERM needs time to flush state before the kill.
    // From: Issue #1683 | PR #1912
    stop_grace: Duration,
}

impl Timing {
    // What: every supervisor time from the env, seconds.
    // Why: a missing or junk value stops the supervisor.
    // From: Issue #1683 | PR #1912
    fn load() -> Result<Self, String> {
        let secs = |key| bounded(key, 1, u32::MAX.into()).map(Duration::from_secs);
        Ok(Self {
            tick: secs("SUPERVISE_TICK")?,
            backoff: Backoff::load(&config::process_env)?,
            backoff_reset: secs("SUPERVISE_BACKOFF_RESET")?,
            stop_grace: secs("SUPERVISE_STOP_GRACE")?,
        })
    }
}

// What: inputs every program reads at render time.
// Why: a saved setting beats the env; the file is optional.
// From: Issue #1683 | PR #1912
struct Ctx {
    run_dir: PathBuf,
    settings_file: Option<PathBuf>,
    desired_file: Option<PathBuf>,
}

impl Ctx {
    // What: the saved ui setting, else the env value.
    // Why: operators change settings live in the ui.
    // From: Issue #1683 | PR #1912
    fn setting(&self, key: &str) -> Option<String> {
        // What: an unreadable file is logged; env wins.
        // Why: a render must still use the known values.
        // From: Issue #1683 | PR #1912
        let saved = self.settings_file.as_deref().and_then(|file| {
            config::saved_setting(file, key).unwrap_or_else(|e| {
                log_err(&format!(
                    "WARNING: {key} not read from the settings file: {e}"
                ));
                None
            })
        });
        config::non_empty(saved.as_deref())
            .map(str::to_string)
            .or_else(|| env_opt(key))
            .or_else(|| config::dhcp_dns_fallback(&config::process_env, key))
    }

    // What: a required value from the env.
    // Why: no defaults in Rust; the SOT bakes them in.
    // From: Issue #1683 | PR #1912
    fn need(&self, key: &str) -> Result<String, String> {
        config::need(&config::process_env, key)
    }

    // What: a DHCP DNS IP from env, else its LAN address.
    // Why: compose derives no fallback; config owns it.
    // From: Issue #1683 | PR #1912
    fn need_dns(&self, key: &str) -> Result<String, String> {
        env_opt(key)
            .or_else(|| config::dhcp_dns_fallback(&config::process_env, key))
            .ok_or_else(|| config::not_set(key))
    }

    // What: a file in the run dir, written fresh.
    // Why: each start renders from the current settings.
    // From: Issue #1683 | PR #1912
    fn render(&self, file: &str, body: &str) -> Result<String, String> {
        let path = self.run_dir.join(file);
        write_file(&path, body.as_bytes(), 0o644, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        Ok(path.display().to_string())
    }
}

// What: one program or task the supervisor keeps alive.
// Why: one list; build-manifest.yml owns the names.
// From: Issue #1683 | PR #1912
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Watch,
    Retention,
    SyslogNg,
    Chronyd,
    Netdata,
    Pdns,
    DnsHttp,
    DnsHttps,
    NatsServer,
    NatsSubscriber,
    Soa,
    KeaDhcp4,
    KeaCtrlAgent,
    KeaDhcpDdns,
    Dnsmasq,
    DhcpProbe,
    Nginx,
}

impl Kind {
    // What: the kind of one LANCACHE_PROCESSES entry.
    // Why: an unknown name is a config error; fail closed.
    // From: Issue #1683 | PR #1912
    fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "watch" => Self::Watch,
            "retention" => Self::Retention,
            "syslog-ng" => Self::SyslogNg,
            "chronyd" => Self::Chronyd,
            "netdata" => Self::Netdata,
            "pdns" => Self::Pdns,
            "dns-http" => Self::DnsHttp,
            "dns-https" => Self::DnsHttps,
            "nats-server" => Self::NatsServer,
            "nats-subscriber" => Self::NatsSubscriber,
            "soa" => Self::Soa,
            "kea-dhcp4" => Self::KeaDhcp4,
            "kea-ctrl-agent" => Self::KeaCtrlAgent,
            "kea-dhcp-ddns" => Self::KeaDhcpDdns,
            "dnsmasq" => Self::Dnsmasq,
            "dhcp-probe" => Self::DhcpProbe,
            "nginx" => Self::Nginx,
            _ => return None,
        })
    }

    // What: the name as LANCACHE_PROCESSES spells it.
    // Why: logs and the status file use the same name.
    // From: Issue #1683 | PR #1912
    fn name(self) -> &'static str {
        match self {
            Self::Watch => "watch",
            Self::Retention => "retention",
            Self::SyslogNg => "syslog-ng",
            Self::Chronyd => "chronyd",
            Self::Netdata => "netdata",
            Self::Pdns => "pdns",
            Self::DnsHttp => DNS_HTTP.name,
            Self::DnsHttps => DNS_HTTPS.name,
            Self::NatsServer => "nats-server",
            Self::NatsSubscriber => "nats-subscriber",
            Self::Soa => "soa",
            Self::KeaDhcp4 => "kea-dhcp4",
            Self::KeaCtrlAgent => "kea-ctrl-agent",
            Self::KeaDhcpDdns => "kea-dhcp-ddns",
            Self::Dnsmasq => "dnsmasq",
            Self::DhcpProbe => "dhcp-probe",
            Self::Nginx => "nginx",
        }
    }

    // What: whether this kind should run right now.
    // Why: ui sets NTP, DHCP; a primary runs nats, soa.
    // From: Issue #1437 | PR #1912
    fn wanted(self, ctx: &Ctx) -> bool {
        let secondary = || env_opt("DNS_REPLICATION_ROLE").as_deref() == Some("secondary");
        let dhcp = || DhcpMode::parse(&ctx.setting("DHCP_MODE").unwrap_or_default());
        // What: the dock's run request for one service.
        // Why: "stopped" overrides the saved setting.
        // From: Issue #1683 | PR #1912
        let desired = || {
            ctx.desired_file
                .as_deref()
                .map(DesiredState::read)
                .unwrap_or_default()
        };
        let dhcp_on = || desired().dhcp != Some(DesiredRunState::Stopped);
        match self {
            Self::KeaDhcp4 | Self::KeaCtrlAgent | Self::KeaDhcpDdns => dhcp().is_kea() && dhcp_on(),
            Self::Dnsmasq => dhcp().is_dnsmasq() && dhcp_on(),
            Self::NatsServer | Self::Soa => !secondary(),
            Self::DnsHttps => DNS_HTTPS.runs(),
            Self::Chronyd => {
                let on = ctx
                    .setting("NTP_ENABLED")
                    .as_deref()
                    .and_then(config::parse_bool);
                on == Some(true) && desired().ntp != Some(DesiredRunState::Stopped)
            }
            _ => true,
        }
    }

    // What: render the config, return what to start.
    // Why: a render error keeps the program stopped.
    // From: Issue #1683 | PR #1912
    fn launch(self, ctx: &Ctx) -> Result<Run, String> {
        match self {
            Self::Watch | Self::Retention | Self::Soa | Self::DhcpProbe => Ok(Run::default()),
            Self::KeaDhcp4 => kea_dhcp4(ctx),
            Self::KeaCtrlAgent => kea_ctrl_agent(ctx),
            Self::KeaDhcpDdns => kea_dhcp_ddns(ctx),
            Self::Nginx => nginx(ctx),
            Self::Dnsmasq => dnsmasq(
                ctx,
                DhcpMode::parse(&ctx.setting("DHCP_MODE").unwrap_or_default()).is_dnsmasq_relay(),
            ),
            Self::SyslogNg => syslog_ng(ctx),
            Self::Chronyd => chronyd(ctx),
            Self::Netdata => netdata(ctx),
            Self::Pdns => pdns_auth(ctx),
            Self::DnsHttp => recursor(ctx, &DNS_HTTP),
            Self::DnsHttps => recursor(ctx, &DNS_HTTPS),
            Self::NatsServer => nats_server(ctx),
            Self::NatsSubscriber => nats_subscriber(ctx),
        }
    }
}

// What: what the supervisor starts for one kind.
// Why: a program gets argv and env; inputs restart it.
// From: Issue #1683
#[derive(Debug, Default)]
struct Run {
    argv: Vec<String>,
    env: Vec<(String, String)>,
    // What: files whose change restarts the program.
    // Why: the ui writes files; the program converges.
    // From: Issue #1683 | PR #1912
    watch: Vec<PathBuf>,
}

// What: size and mtime of each watched file, if any.
// Why: a changed input means a restart; absent is a state.
// From: Issue #1683 | PR #1912
fn fingerprint(files: &[PathBuf]) -> Vec<Option<(u64, i64, i64)>> {
    files
        .iter()
        .map(|f| match fs::metadata(f) {
            Ok(m) => Some((m.len(), m.mtime(), m.mtime_nsec())),
            // What: absent is a state; errors log.
            // Why: a stat fault is not "absent".
            // From: Issue #1683 | PR #1912
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => {
                log_err(&format!("WARNING: cannot stat {}: {e}", f.display()));
                None
            }
        })
        .collect()
}

// What: the syslog-ng destination id of the log files.
// Why: the config and the log-loss check name one id.
// From: Issue #1428 | PR #1912
const SYSLOG_NG_DESTINATION: &str = "d_store";

// What: the zones with snapshots, for the SOT's local zone.
// Why: DHCP_DOMAIN names the local zone; no literal here.
// From: Issue #1683 | PR #1912
fn rollback_zones() -> Result<Vec<String>, String> {
    Ok(config::rollback_zones(&config::lan_zone(
        &config::process_env,
    )?))
}

// What: env var that hands the AAAA marker path to the lua.
// Why: filter-aaaa.lua cannot read the SOT; it reads this.
// From: Issue #1683 | PR #1912
const AAAA_FILTER_PATH_ENV: &str = "AAAA_FILTER_MARKER_PATH";

// What: glob of the day files syslog-ng writes per program.
// Why: syslog_ng_conf names them <day>.log; netdata reads.
// From: Issue #1683 | PR #1912
const SYSLOG_FILE_GLOB: &str = "*.log";

// What: file name of the syslog-ng control socket.
// Why: syslog-ng binds it and the log-loss check reads it.
// From: Issue #1428 | PR #1912
const SYSLOG_NG_CTL: &str = "syslog-ng.ctl";

// What: file name of the supervisor status in the run dir.
// Why: supervisor writes it and the health check reads it.
// From: Issue #1683 | PR #1912
const SUPERVISE_STATUS_FILE: &str = "supervise.json";

// What: the status row name of syslog-ng log writing.
// Why: the dashboard lists every row of the status file.
// From: Issue #1428 | PR #1912
const LOG_ROW: &str = "syslog-ng";

// What: the processed counter and the log bytes now.
// Why: a rising counter with flat bytes is a loss.
// From: Issue #1428 | PR #1912
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct LogSample {
    processed: u64,
    newest: u128,
}

// What: the processed counter of one destination.
// Why: a stats line is type;id;instance;state;kind;count.
// From: Issue #1428 | PR #1912
fn processed_count(stats: &str, destination: &str) -> Option<u64> {
    stats.lines().find_map(|line| {
        let f: Vec<&str> = line.split(';').collect();
        let ours =
            f.len() >= 6 && f[0] == "destination" && f[1] == destination && f[4] == "processed";
        ours.then(|| f[5].trim().parse().ok()).flatten()
    })
}

// What: newest plain-file modification below root, in ns.
// Why: a write moves it; retention and packing do not.
// From: Issue #1428 | PR #1912
fn newest_write(root: &Path) -> u128 {
    // What: a failed scan is logged and reads as 0.
    // Why: 0 shows no write; the cause must stay visible.
    // From: Issue #1683 | PR #1912
    let files = match files_under(root) {
        Ok(files) => files,
        Err(e) => {
            log_err(&format!("WARNING: cannot scan {}: {e}", root.display()));
            return 0;
        }
    };
    files
        .iter()
        .filter(|(path, _)| !path.to_string_lossy().ends_with(XZ_SUFFIX))
        // What: a file with no readable time is logged.
        // Why: one bad file must not hide the newest write.
        // From: Issue #1683 | PR #1912
        .filter_map(|(path, meta)| {
            file_time(meta)
                .inspect_err(|e| log_err(&format!("WARNING: {} time: {e}", path.display())))
                .ok()
        })
        .map(|d| d.as_nanos())
        .max()
        .unwrap_or(0)
}

// What: syslog-ng's counter and the newest log write.
// Why: only a write moves it; None if no stats.
// From: Issue #1428 | PR #1912
fn log_sample(s: &Settings) -> Option<LogSample> {
    let ctl = format!("--control={}", s.syslog_ctl.display());
    // What: a failed stats read or no counter is logged.
    // Why: None alone hides why no sample was taken.
    // From: Issue #1683 | PR #1912
    let stats = run_program("syslog-ng-ctl", &["stats", &ctl], None)
        .inspect_err(|e| log_err(&format!("WARNING: syslog-ng stats not read: {e}")))
        .ok()?;
    let Some(processed) = processed_count(&stats, SYSLOG_NG_DESTINATION) else {
        log_err(&format!(
            "WARNING: syslog-ng stats have no processed count for {SYSLOG_NG_DESTINATION}"
        ));
        return None;
    };
    Some(LogSample {
        processed,
        newest: newest_write(&s.syslog_root),
    })
}

// What: true if messages came but nothing was written.
// Why: a mount or permission fault swallows writes.
// From: Issue #1428 | PR #1912
fn log_lost(before: LogSample, after: LogSample) -> bool {
    after.processed > before.processed && after.newest <= before.newest
}

// What: the status row for log writing, and the streak.
// Why: a loss must show on the dashboard.
// From: Issue #1428 | PR #1912
fn log_row(
    before: Option<LogSample>,
    after: Option<LogSample>,
    failures: u32,
) -> (ServiceHealth, u32) {
    let (status, health, failures) = if let Some(a) = after {
        if before.is_some_and(|b| log_lost(b, a)) {
            ("red", "silent log loss", failures + 1)
        } else {
            ("green", "healthy", 0)
        }
    } else {
        ("yellow", "unreachable", 0)
    };
    let row = ServiceHealth {
        status: status.to_string(),
        health: health.to_string(),
        failures,
    };
    (row, failures)
}

// What: syslog-ng.conf for the Docker syslog input.
// Why: one file per container and day; the group reads.
// From: Issue #1683
fn syslog_ng_conf(
    port: u16,
    root: &str,
    group: &str,
    off: &[&str],
    reap: u64,
) -> Result<String, String> {
    if !root.starts_with('/') || root.contains(['"', '\n', '\r', '$']) {
        return Err(format!("SYSLOG_LOG_ROOT={root} is no plain absolute path"));
    }
    let name = |c: char| c.is_ascii_alphanumeric() || "_-".contains(c);
    if group.is_empty() || !group.chars().all(name) {
        return Err(format!("LOG_READER_GROUP={group} is no group name"));
    }
    if off.iter().any(|p| !p.chars().all(name)) {
        return Err(format!("switched-off program {off:?} is no plain name"));
    }
    let skip = if off.is_empty() {
        String::new()
    } else {
        format!(r#" and not program("^({})$" type(pcre))"#, off.join("|"))
    };
    Ok(format!(
        r#"@version: current
options {{ create-dirs(yes); dir-group("{group}"); dir-perm(0750); group("{group}"); perm(0640); keep-hostname(yes); time-reap({reap}); }};
source s_docker {{ network(transport("udp") port({port}) flags(syslog-protocol)); }};
filter f_named {{ program("^[A-Za-z0-9_-]+$" type(pcre)){skip}; }};
destination {SYSLOG_NG_DESTINATION} {{ file("{root}/${{PROGRAM}}/${{YEAR}}${{MONTH}}${{DAY}}.log" template("${{ISODATE}} ${{HOST}} ${{PROGRAM}}: ${{MSGONLY}}\n")); }};
log {{ source(s_docker); filter(f_named); destination({SYSLOG_NG_DESTINATION}); }};
"#
    ))
}

// What: programs whose logging is switched off.
// Why: the services container itself always logs.
// From: Issue #1683 | PR #1912
fn logging_off(
    ctx: &Ctx,
    program_of: &dyn Fn(&str) -> Result<String, String>,
) -> Result<Vec<String>, String> {
    let mut off = Vec::new();
    for (key, program_key) in config::LOG_SWITCHES {
        let on = ctx
            .setting(key)
            .as_deref()
            .and_then(config::parse_bool)
            .ok_or_else(|| format!("{key} must be a boolean"))?;
        if !on {
            off.push(program_of(program_key)?);
        }
    }
    Ok(off)
}

// What: render syslog-ng.conf; the syslog-ng command.
// Why: state files live in the private run dir.
// From: Issue #1683 | PR #1912
fn syslog_ng(ctx: &Ctx) -> Result<Run, String> {
    let off = logging_off(ctx, &|key| ctx.need(key))?;
    let off: Vec<&str> = off.iter().map(String::as_str).collect();
    let conf = syslog_ng_conf(
        env_port("LANCACHE_LOG_PORT")?,
        &ctx.need("SYSLOG_LOG_ROOT")?,
        &ctx.need("LOG_READER_GROUP")?,
        &off,
        bounded("SYSLOG_TIME_REAP", 1, u32::MAX.into())?,
    )?;
    let conf = ctx.render("syslog-ng.conf", &conf)?;
    let run = |file: &str| ctx.run_dir.join(file).display().to_string();
    let argv = vec![
        "syslog-ng".into(),
        "-F".into(),
        "--no-caps".into(),
        "-f".into(),
        conf,
        "-R".into(),
        run("syslog-ng.persist"),
        "-p".into(),
        run("syslog-ng.pid"),
        "-c".into(),
        run(SYSLOG_NG_CTL),
    ];
    Ok(Run {
        argv,
        watch: ctx.settings_file.iter().cloned().collect(),
        ..Run::default()
    })
}

// What: daemon and health log to stderr, the rest off.
// Why: Docker hands stderr to the one syslog-ng.
// From: Issue #1683
const NETDATA_CONF: &str =
    "[logs]\n    daemon = stderr\n    health = stderr\n    collector = off\n    access = off\n";

// What: netdata custom_sender that POSTs alarms to the ui.
// Why: fields come from NetdataAlarm; no second list.
// From: Issue #858
fn alarm_notify_conf(
    ui_url: &str,
    token_file: &str,
    max_time: u64,
    recipient: &str,
) -> Result<String, String> {
    for value in [ui_url, token_file, recipient] {
        let plain = |c: char| c.is_ascii_alphanumeric() || "-._:/".contains(c);
        if value.is_empty() || !value.chars().all(plain) {
            return Err(format!("{value:?} is no plain URL or path"));
        }
    }
    let sample = serde_json::to_value(NetdataAlarm::default()).map_err(|e| e.to_string())?;
    let fields = sample.as_object().ok_or("alarm is no JSON object")?;
    let json: Vec<String> = fields
        .iter()
        .map(|(key, value)| {
            if value.is_string() {
                format!("\\\"{key}\\\":\\\"$(_lancache_json_escape \"${{{key}}}\")\\\"")
            } else {
                format!("\\\"{key}\\\":${{{key}}}")
            }
        })
        .collect();
    let json = json.join(",");
    Ok(format!(
        r#"SEND_CUSTOM="YES"
DEFAULT_RECIPIENT_CUSTOM="{recipient}"
_lancache_json_escape() {{
  printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}}
custom_sender() {{
  local token httpcode
  token="$(cat "{token_file}")" || return 1
  httpcode="$(docurl --max-time {max_time} -X POST -H "Content-Type: application/json" -H "{ALARM_TOKEN_HEADER}: ${{token}}" -d "{{{json}}}" "{ui_url}{ALARM_INGEST_PATH}")" || {{
    error "lancache-ui alarm POST failed: HTTP ${{httpcode}}"
    return 1
  }}
  case "${{httpcode}}" in 2??) return 0 ;; esac
  error "lancache-ui alarm POST returned HTTP ${{httpcode}}"
  return 1
}}
"#
    ))
}

// What: go.d web_log job over the proxy's syslog files.
// Why: live request charts; the glob follows the day.
// From: Issue #1246
fn web_log_conf(path: &str) -> Result<String, String> {
    if !path.starts_with('/') || path.contains(['\'', '"', '\n', '\r', ' ', '#']) {
        return Err(format!("web log path {path} is no plain absolute path"));
    }
    Ok(format!(
        "jobs:\n  - name: nginx_proxy\n    path: {path}\n    log_type: regexp\n    \
         regexp_config:\n      pattern: '{PROXY_ACCESS_LOG_PATTERN}'\n"
    ))
}

// What: alarm token, sender, logs, web_log; then netdata.
// Why: netdata has no hook of ours; it drops root itself.
// From: Issue #1683
fn netdata(ctx: &Ctx) -> Result<Run, String> {
    let dir = PathBuf::from(ctx.need("NETDATA_CONFIG_DIR")?);
    let token_file = dir.join(".netdata-alarm-token");
    let sender = alarm_notify_conf(
        &ctx.need("NETDATA_ALARM_UI_URL")?,
        &token_file.display().to_string(),
        bounded("NETDATA_ALARM_MAX_TIME", 1, 300)?,
        &ctx.need("NETDATA_ALARM_RECIPIENT")?,
    )?;
    let web_log = web_log_conf(&format!(
        "{}/{SYSLOG_FILE_GLOB}",
        config::proxy_log_dir(&config::process_env)?
    ))?;
    let token = stack_secret(
        "NETDATA_ALARM_TOKEN",
        &shared_secret_file_name("NETDATA_ALARM_TOKEN"),
        hex32,
    )?;
    let put = |file: &str, body: &str, mode: u32| {
        let path = dir.join(file);
        write_if_changed(&path, body.as_bytes(), mode, None)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
            .map(|_| path)
    };
    let token_file = put(".netdata-alarm-token", &token, 0o600)?;
    own(
        &token_file,
        Some(account_id("passwd", "netdata")?),
        Some(account_id("group", "netdata")?),
        Some(0o600),
    )
    .map_err(|e| e.to_string())?;
    put("health_alarm_notify.conf", &sender, 0o644)?;
    put("netdata.conf", NETDATA_CONF, 0o644)?;
    put("go.d/web_log.conf", &web_log, 0o644)?;
    Ok(Run {
        argv: vec!["netdata".into(), "-D".into()],
        ..Run::default()
    })
}

// What: an IP literal (server) or a name (pool).
// Why: a name may resolve to many hosts; pool covers them.
// From: Issue #1683 | PR #1912
fn is_ip_literal(entry: &str) -> bool {
    entry.parse::<std::net::IpAddr>().is_ok()
}

// What: chrony.conf from upstreams and client CIDRs.
// Why: no upstream means no NTP; empty CIDRs allow all.
// From: Issue #1683 | PR #1912
fn chrony_conf(upstreams: &str, cidrs: &str, drift: &str, port: u16) -> Result<String, String> {
    let plain = |v: &str| {
        v.chars()
            .all(|c| c.is_ascii_alphanumeric() || ".:/-_".contains(c))
    };
    let servers: Vec<&str> = upstreams.split_whitespace().collect();
    if servers.is_empty() {
        return Err("NTP_UPSTREAM_SERVERS is empty; NTP never runs alone".into());
    }
    let allowed: Vec<&str> = cidrs.split_whitespace().collect();
    if let Some(bad) = servers.iter().chain(&allowed).find(|v| !plain(v)) {
        return Err(format!("NTP value {bad:?} has unsafe characters"));
    }
    if !drift.starts_with('/') || !plain(drift) {
        return Err(format!("NTP_DRIFT_FILE={drift} is no plain absolute path"));
    }
    // What: step on large early offsets; sync the RTC.
    // Why: stale start clock; kernel copies time to RTC.
    // From: Issue #1683 | PR #1912
    let mut conf = format!("driftfile {drift}\nport {port}\nmakestep 1.0 3\nrtcsync\n");
    for entry in servers {
        let kind = if is_ip_literal(entry) {
            "server"
        } else {
            "pool"
        };
        conf.push_str(&format!("{kind} {entry} iburst\n"));
    }
    if allowed.is_empty() {
        conf.push_str("allow 0.0.0.0/0\nallow ::/0\n");
    }
    for cidr in allowed {
        conf.push_str(&format!("allow {cidr}\n"));
    }
    Ok(conf)
}

// What: render chrony.conf; chronyd in the foreground.
// Why: -d logs to stderr; a ui change restarts it.
// From: Issue #1683 | PR #1912
fn chronyd(ctx: &Ctx) -> Result<Run, String> {
    let conf = chrony_conf(
        &ctx.setting("NTP_UPSTREAM_SERVERS").unwrap_or_default(),
        &ctx.setting("NTP_ALLOWED_CLIENT_CIDRS").unwrap_or_default(),
        &ctx.need("NTP_DRIFT_FILE")?,
        env_port("NTP_PORT")?,
    )?;
    let conf = ctx.render("chrony.conf", &conf)?;
    Ok(Run {
        argv: vec!["chronyd".into(), "-d".into(), "-f".into(), conf],
        watch: ctx.settings_file.iter().cloned().collect(),
        ..Run::default()
    })
}

// What: the dns role of this node.
// Why: a primary owns the zones; a secondary copies them.
// From: Issue #1164
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DnsRole {
    Primary,
    Secondary,
}

// What: DNS_REPLICATION_ROLE as a role.
// Why: an unknown spelling must never start a server.
// From: Issue #1683 | PR #1912
fn dns_role(raw: &str) -> Result<DnsRole, String> {
    match raw {
        "primary" => Ok(DnsRole::Primary),
        "secondary" => Ok(DnsRole::Secondary),
        _ => Err(format!(
            "DNS_REPLICATION_ROLE={raw} is neither primary nor secondary"
        )),
    }
}

// What: a port from the env, 1 to 65535.
// Why: the SOT owns the ports; compose passes them on.
// From: Issue #1683 | PR #1912
fn env_port(key: &'static str) -> Result<u16, String> {
    config::port(&config::process_env, key)
}

// What: env keys of the PowerDNS ports here.
// Why: the SOT owns each port; Rust only names the key.
// From: Issue #1683 | PR #1912
const AUTH_API_PORT_KEY: &str = "PDNS_AUTH_API_PORT";
const AUTH_PORT_KEY: &str = "PDNS_AUTH_PORT";
const ROLLBACK_PORT_KEY: &str = "DNS_ROLLBACK_PORT";

// What: one recursor: name, answer IP, ports.
// Why: dns-http and dns-https differ only in these.
// From: Issue #1683
struct Recursor {
    name: &'static str,
    ip_key: &'static str,
    port_key: &'static str,
    api_port_key: &'static str,
}

impl Recursor {
    // What: a recursor runs only when its answer IP is set.
    // Why: presence of the IP env decides, not the role.
    // From: Issue #1683 | PR #1912
    fn runs(&self) -> bool {
        env_opt(self.ip_key).is_some()
    }

    // What: the answer port the env names here.
    // Why: http and https differ in the key, not the code.
    // From: Issue #1683 | PR #1912
    fn port(&self) -> Result<u16, String> {
        env_port(self.port_key)
    }

    // What: the API port the env names for this recursor.
    // Why: the ui and the flush calls use the same key.
    // From: Issue #1683 | PR #1912
    fn api_port(&self) -> Result<u16, String> {
        env_port(self.api_port_key)
    }
}

// What: dns-http uses IP_HTTP, dns-https IP_HTTPS.
// Why: one cache per proxy IP keeps the answers apart.
// From: Issue #1683 | PR #1912
const DNS_HTTP: Recursor = Recursor {
    name: "dns-http",
    ip_key: "IP_HTTP",
    port_key: "DNS_PORT",
    api_port_key: "PDNS_HTTP_API_PORT",
};
const DNS_HTTPS: Recursor = Recursor {
    name: "dns-https",
    ip_key: "IP_HTTPS",
    port_key: "DNS_HTTPS_PORT",
    api_port_key: "PDNS_HTTPS_API_PORT",
};

// What: DNS render values: SOA, RPZ, recursor, nets.
// Why: the SOT owns each value; Rust names only keys.
// From: Issue #1683 | PR #1912
struct DnsKnobs {
    xfr_cycle: u64,
    soa_mname: String,
    soa_rname: String,
    soa_expire: u64,
    soa_minimum: u64,
    auth_loglevel: u64,
    api_allow: Vec<String>,
    query_allow: Vec<String>,
    loopback_nets: Vec<String>,
    rpz_rname: String,
    rpz_ttl: u64,
    rpz_refresh: u64,
    rpz_retry: u64,
    root_servers: Vec<String>,
    root_refresh: u64,
    root_retry: u64,
    minimum_ttl_override: u64,
    recordcache_max: u64,
    refresh_on_ttl_perc: u64,
    serve_stale_extensions: u64,
    negative_ttl: u64,
    packetcache_max: u64,
    packetcache_ttl: u64,
    servfail_ttl: u64,
    loglevel: u64,
    loglevel_queries: u64,
}

impl DnsKnobs {
    // What: every DNS render value from the env.
    // Why: a missing or junk value stops the render.
    // From: Issue #1683 | PR #1912
    fn load() -> Result<Self, String> {
        let secs = |key| bounded(key, 0, u32::MAX.into());
        let count = |key| bounded(key, 1, u32::MAX.into());
        let level = |key| bounded(key, 0, 9);
        let words = |key: &str| {
            config::need(&config::process_env, key)
                .map(|v| v.split_whitespace().map(str::to_string).collect())
        };
        let text = |key: &str| config::need(&config::process_env, key);
        Ok(Self {
            xfr_cycle: bounded("PDNS_XFR_CYCLE_INTERVAL", 1, u32::MAX.into())?,
            soa_mname: text("PDNS_SOA_MNAME")?,
            soa_rname: text("PDNS_SOA_RNAME")?,
            soa_expire: secs("PDNS_SOA_EXPIRE")?,
            soa_minimum: secs("PDNS_SOA_MINIMUM")?,
            auth_loglevel: level("PDNS_AUTH_LOGLEVEL")?,
            api_allow: words("DNS_API_ALLOW_FROM")?,
            query_allow: words("DNS_QUERY_ALLOW_FROM")?,
            loopback_nets: words("LOOPBACK_NETS")?,
            rpz_rname: text("RPZ_SOA_RNAME")?,
            rpz_ttl: secs("RPZ_TTL")?,
            rpz_refresh: secs("RPZ_SOA_REFRESH")?,
            rpz_retry: secs("RPZ_SOA_RETRY")?,
            root_servers: words("ROOT_ZONE_MIRROR_SERVERS")?,
            root_refresh: secs("ROOT_ZONE_MIRROR_REFRESH")?,
            root_retry: secs("ROOT_ZONE_MIRROR_RETRY")?,
            minimum_ttl_override: secs("RECURSOR_MINIMUM_TTL_OVERRIDE")?,
            recordcache_max: count("RECURSOR_RECORDCACHE_MAX_ENTRIES")?,
            refresh_on_ttl_perc: bounded("RECURSOR_REFRESH_ON_TTL_PERC", 0, 100)?,
            serve_stale_extensions: secs("RECURSOR_SERVE_STALE_EXTENSIONS")?,
            negative_ttl: secs("RECURSOR_MAX_NEGATIVE_TTL")?,
            packetcache_max: count("RECURSOR_PACKETCACHE_MAX_ENTRIES")?,
            packetcache_ttl: secs("RECURSOR_PACKETCACHE_TTL")?,
            servfail_ttl: secs("RECURSOR_SERVFAIL_TTL")?,
            loglevel: level("RECURSOR_LOGLEVEL")?,
            loglevel_queries: level("RECURSOR_LOGLEVEL_QUERIES")?,
        })
    }
}

// What: YAML list rows of one value list.
// Why: recursor.conf lists nets one per row.
// From: Issue #1683 | PR #1912
fn yaml_rows(items: &[String]) -> String {
    items.iter().map(|i| format!("    - {i}\n")).collect()
}

// What: TSIG key name and algorithm of DDNS and AXFR.
// Why: Kea signs with the same name; the SOT owns both.
// From: Issue #858 | PR #1858
struct TsigId {
    name: String,
    algorithm: String,
}

impl TsigId {
    // What: both TSIG values from the env.
    // Why: a missing value stops the render.
    // From: Issue #1683 | PR #1858
    fn load() -> Result<Self, String> {
        let text = |key: &str| config::need(&config::process_env, key);
        Ok(Self {
            name: text("DDNS_TSIG_NAME")?,
            algorithm: text("DDNS_TSIG_ALGORITHM")?,
        })
    }
}

// What: the local API root of a PowerDNS server.
// Why: the supervisor and nats-subscriber share it.
// From: Issue #1683 | PR #1912
fn api_root(loopback: &str, port: u16) -> String {
    format!("http://{loopback}:{port}{}", config::PDNS_API_PATH)
}

// What: 32 random bytes in base64, a TSIG secret.
// Why: Kea and PowerDNS read the key in this form.
// From: Issue #1683 | PR #1912
fn base64_32() -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(rand::random::<[u8; 32]>())
}

// What: a configured secret, else the shared file.
// Why: every container and the ui agree on one value.
// From: Issue #858
fn stack_secret(var: &str, file: &str, make: fn() -> String) -> Result<String, String> {
    let need = |key: &str| config::need(&config::process_env, key);
    let dir = need("LANCACHE_SHARED_SECRET_DIR")?;
    let gid = config::runtime_gid()?;
    let configured = env_opt(var).unwrap_or_default();
    let current = if is_placeholder(&configured) {
        ""
    } else {
        configured.as_str()
    };
    resolve_shared_secret(Path::new(&dir), file, current, gid, make)
        .map_err(|e| format!("{var}: {e}"))
}

// What: the PowerDNS API key, at least 16 characters.
// Why: it guards the zone and cache APIs of the stack.
// From: Issue #858
fn pdns_api_key() -> Result<String, String> {
    let key = stack_secret(
        "PDNS_API_KEY",
        &shared_secret_file_name("PDNS_API_KEY"),
        hex32,
    )?;
    if key.len() < 16 {
        return Err(format!(
            "PDNS_API_KEY has {} characters; 16 is the minimum",
            key.len()
        ));
    }
    Ok(key)
}

// What: one whole-number process env knob in [min, max].
// Why: out-of-range knobs would render invalid configs.
// From: Issue #1683 | PR #1912
fn bounded(key: &'static str, min: u64, max: u64) -> Result<u64, String> {
    config::uint(&config::process_env, key, min, max)
}

// What: SOA refresh, retry and resync seconds.
// Why: retry below refresh (RFC 1912); all bounded.
// From: Issue #1095
fn soa_knobs() -> Result<(u64, u64, u64), String> {
    let refresh = bounded("PDNS_SOA_REFRESH", 10, 86_400)?;
    let retry = bounded("PDNS_SOA_RETRY", 1, refresh - 1)?;
    let resync = bounded("PDNS_SOA_RESYNC_INTERVAL", 60, 86_400)?;
    Ok((refresh, retry, resync))
}

// What: this container's own non-loopback IPv4 address.
// Why: DDNS from dhcp cannot reach a loopback-only bind.
// From: Issue #706
fn own_address() -> Result<std::net::Ipv4Addr, String> {
    // What: a connected UDP socket names the route source.
    // Why: connect() sends no packet; no ip tool needed.
    // From: Issue #1683 | PR #1912
    let any = config::any_bind(&config::process_env)?;
    let target = config::need(&config::process_env, "ROUTE_PROBE_TARGET")?;
    let socket = std::net::UdpSocket::bind((any.as_str(), 0))
        .and_then(|s| s.connect(target.as_str()).map(|()| s))
        .map_err(|e| format!("no route to find the own address: {e}"))?;
    match socket.local_addr() {
        Ok(std::net::SocketAddr::V4(a)) if !a.ip().is_loopback() && !a.ip().is_unspecified() => {
            Ok(*a.ip())
        }
        other => Err(format!("no own non-loopback IPv4 address: {other:?}")),
    }
}

// What: host:port with the host resolved to IPv4.
// Why: PowerDNS needs IP:port, not a name; retry later.
// From: Issue #1164 | PR #1775
fn endpoint(raw: &str, key: &'static str) -> Result<std::net::SocketAddrV4, String> {
    use std::net::ToSocketAddrs as _;
    let (host, port) = raw
        .rsplit_once(':')
        .filter(|(h, p)| !h.is_empty() && !p.is_empty())
        .ok_or_else(|| format!("{key}={raw} is not host:port"))?;
    let port = config::port(&|_| Some(port.to_string()), key)
        .map_err(|e| format!("{key}={raw} has no valid port: {e}"))?;
    (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("{key} host {host} does not resolve: {e}"))?
        .find_map(|a| match a {
            std::net::SocketAddr::V4(v4) => Some(v4),
            std::net::SocketAddr::V6(_) => None,
        })
        .ok_or_else(|| format!("{key} host {host} has no IPv4 address"))
}

// What: the comma or space list of DNS_XFR_NOTIFY_TARGETS.
// Why: a primary notifies and allows AXFR to each one.
// From: Issue #1683 | PR #1912
fn notify_targets() -> Result<Vec<std::net::SocketAddrV4>, String> {
    env_opt("DNS_XFR_NOTIFY_TARGETS")
        .unwrap_or_default()
        .split([',', ' '])
        .filter(|t| !t.is_empty())
        .map(|t| endpoint(t, "DNS_XFR_NOTIFY_TARGETS"))
        .collect()
}

// What: pdns.conf for the authoritative server.
// Why: values are filled in code; no template tool runs.
// From: Issue #1683
struct AuthConf<'a> {
    local: std::net::Ipv4Addr,
    database: &'a str,
    role: DnsRole,
    notify_from: &'a str,
    axfr_ips: &'a str,
    allow_from: &'a str,
    seed_serial: &'a str,
    refresh: u64,
    retry: u64,
    auth_port: u16,
    api_port: u16,
    api_key: &'a str,
    loopback: &'a str,
    any: &'a str,
    knobs: &'a DnsKnobs,
}

impl AuthConf<'_> {
    fn render(&self) -> String {
        let yes = |on: bool| if on { "yes" } else { "no" };
        // What: pdns accepts unsigned updates globally.
        // Why: per-zone TSIG metadata is the real gate.
        // From: Issue #1683 | PR #1912
        format!(
            "local-address={lo},{local}\nlocal-port={auth_port}\nlaunch=gsqlite3\n\
             gsqlite3-database={db}\nprimary={primary}\nsecondary={secondary}\n\
             xfr-cycle-interval={xfr}\nallow-notify-from={notify}\n\
             allow-axfr-ips={axfr}\ndnsupdate=yes\nallow-dnsupdate-from={allow}\n\
             dnsupdate-require-tsig=no\n\
             default-soa-content={mname} {rname} {seed} {refresh} {retry} {expire} {minimum}\n\
             webserver=yes\nwebserver-address={any}\nwebserver-port={api_port}\n\
             webserver-allow-from={api_allow}\n\
             api=yes\napi-key={key}\nloglevel={loglevel}\nguardian=no\ndaemon=no\n",
            lo = self.loopback,
            local = self.local,
            any = self.any,
            db = self.database,
            primary = yes(self.role == DnsRole::Primary),
            secondary = yes(self.role == DnsRole::Secondary),
            notify = self.notify_from,
            axfr = self.axfr_ips,
            allow = self.allow_from,
            seed = self.seed_serial,
            refresh = self.refresh,
            retry = self.retry,
            auth_port = self.auth_port,
            api_port = self.api_port,
            key = self.api_key,
            xfr = self.knobs.xfr_cycle,
            mname = self.knobs.soa_mname,
            rname = self.knobs.soa_rname,
            expire = self.knobs.soa_expire,
            minimum = self.knobs.soa_minimum,
            api_allow = self.knobs.api_allow.join(","),
            loglevel = self.knobs.auth_loglevel,
        )
    }
}

// What: true when a config check command exits 0.
// Why: the pdns config checks have no side effects.
// From: Issue #1683 | PR #1912
fn conf_ok(check: &[String]) -> bool {
    let args: Vec<&str> = check[1..].iter().map(String::as_str).collect();
    match run_program(&check[0], &args, None) {
        Ok(_) => true,
        Err(e) => {
            log_err(&format!("ERROR: config check failed: {e}"));
            false
        }
    }
}

// What: write candidate sets; keep the first that checks.
// Why: a bad render falls back to the newest good set.
// From: Issue #415 | PR #1912
fn first_good(
    what: &str,
    candidates: impl IntoIterator<Item = (String, Vec<(PathBuf, String)>)>,
    check: &[String],
) -> Result<String, String> {
    for (label, files) in candidates {
        for (path, text) in &files {
            write_file(path, text.as_bytes(), 0o640, Place::Replace)
                .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        }
        if conf_ok(check) {
            return Ok(label);
        }
    }
    Err(format!(
        "{what} fails its check and no known-good snapshot passes"
    ))
}

// What: each readable snapshot, newest first.
// Why: a restore re-applies what this start owns.
// From: Issue #1683 | PR #1912
fn snapshots<T>(
    store: &lancache_ng::SnapshotStore,
    read: &dyn Fn(Value) -> Option<T>,
) -> Vec<(String, T)> {
    let ids = store.ids().unwrap_or_else(|e| {
        log_err(&format!("WARNING: cannot list snapshots: {e}"));
        Vec::new()
    });
    // What: a skipped snapshot is logged with its cause.
    // Why: a restore must show why a target was left out.
    // From: Issue #1683 | PR #1912
    let usable = |id: String| match store.read(&id) {
        Ok(value) => match read(value) {
            Some(item) => Some((id, item)),
            None => {
                log_err(&format!("WARNING: snapshot {id} has no usable payload"));
                None
            }
        },
        Err(e) => {
            log_err(&format!("WARNING: {e:#}"));
            None
        }
    };
    ids.into_iter().rev().filter_map(usable).collect()
}

// What: no file may be missing from a snapshot.
// Why: filling gaps from a failed render hides the damage.
// From: Issue #1683 | PR #1912
fn no_backfill(_: &Value, _: &str) -> Option<String> {
    None
}

// What: proxy map file name in legacy snapshots.
// Why: its snapshots hold the map under this name.
// From: Issue #1683 | PR #1912
const LEGACY_PROXY_MAP: &str = "00-ssl-map.conf";

// What: old cert variable name and its new name.
// Why: https.conf reads the new name; old maps set the old.
// From: Issue #1683 | PR #1912
const LEGACY_CERT_VAR: (&str, &str) = ("$ssl_cert_name", "$https_cert_name");

// What: backfill for a wholly old snapshot; None otherwise.
// Why: old sets keep the map under an old name.
// From: Issue #1683 | PR #1912
fn legacy_backfill<'a>(
    names: &'a [String],
    renamed: (&'a str, &'a str),
    stub: &'a dyn Fn(&str) -> String,
) -> impl Fn(&Value, &str) -> Option<String> + 'a {
    move |set, file| {
        if !names.iter().any(|n| n == file) || names.iter().any(|n| set.get(n).is_some()) {
            return None;
        }
        if file == renamed.0 {
            let (old, new) = LEGACY_CERT_VAR;
            return set
                .get(renamed.1)?
                .as_str()
                .map(|text| text.replace(old, new));
        }
        Some(stub(file))
    }
}

// What: write rendered files; record the set if it checks.
// Why: the newest good render is the next rollback target.
// From: Issue #1683 | PR #1912
fn checked_files(
    files: &[(PathBuf, String)],
    check: &[String],
    store: &lancache_ng::SnapshotStore,
    restamp: &dyn Fn(&str) -> String,
    backfill: &dyn Fn(&Value, &str) -> Option<String>,
    record: bool,
) -> Result<(), String> {
    let name = |path: &Path| path.file_name().map(|n| n.to_string_lossy().into_owned());
    let what = files
        .iter()
        .map(|(path, _)| path.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    // What: a file the snapshot lacks comes from backfill.
    // Why: an unlisted gap makes the snapshot incomplete.
    // From: Issue #1683 | PR #1912
    let named = |set: Value| -> Option<Vec<(PathBuf, String)>> {
        files
            .iter()
            .map(|(path, _)| {
                let file = name(path)?;
                let text = match set.get(&file) {
                    Some(text) => restamp(text.as_str()?),
                    None => backfill(&set, &file)?,
                };
                Some((path.clone(), text))
            })
            .collect()
    };
    // What: convert old shell snapshots before use.
    // Why: an update keeps its rollback targets.
    // From: Issue #1683 | PR #1912
    store.adopt_legacy();
    let fresh = ("new".to_string(), files.to_vec());
    let used = first_good(
        &what,
        std::iter::once(fresh).chain(snapshots(store, &named)),
        check,
    )?;
    if used != "new" {
        log_err(&format!(
            "WARNING: {what} runs from known-good snapshot {used}, not the new render"
        ));
        return Ok(());
    }
    if !record {
        log_err(&format!(
            "WARNING: {what} has skipped input rows; not saved as known-good"
        ));
        return Ok(());
    }
    let set: serde_json::Map<String, Value> = files
        .iter()
        .filter_map(|(path, text)| Some((name(path)?, Value::String(text.clone()))))
        .collect();
    if let Err(e) = store.create(
        &Value::Object(set),
        config::keep_known_good(&config::process_env)?,
    ) {
        log_err(&format!("WARNING: {what} not saved as known-good: {e:#}"));
    }
    Ok(())
}

// What: replace each line that starts with a key.
// Why: a restored snapshot gets this start's values.
// From: Issue #1683 | PR #1912
fn restamp_lines(text: &str, lines: &[(&str, String)]) -> String {
    text.lines()
        .map(|line| {
            lines
                .iter()
                .find(|(key, _)| line.trim_start().starts_with(key))
                .map_or_else(|| line.to_string(), |(_, new)| new.clone())
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

// What: the --config-dir argument of a pdns program.
// Why: pdnsutil, the check and the launch name one way.
// From: Issue #1683 | PR #1912
fn pdns_config_dir(dir: &Path) -> String {
    lancache_ng::pdns_config_dir_arg(&dir.display().to_string())
}

// What: the side-effect-free config check of pdns.
// Why: the auth and recursor checks differ by name only.
// From: Issue #1683 | PR #1912
fn pdns_check(program: &str, config_dir: &str) -> [String; 3] {
    [program.into(), "--config=check".into(), config_dir.into()]
}

// What: run pdnsutil on the auth config; text or error.
// Why: every zone and key change goes through one call.
// From: Issue #1683 | PR #1912
fn pdnsutil(dir: &Path, args: &[&str]) -> Result<String, String> {
    lancache_ng::pdnsutil(&dir.display().to_string(), args, None)
}

// What: true for pdnsutil's "exists already" refusal.
// Why: a restart finds every zone; only that is fine.
// From: Issue #1683 | PR #1912
fn exists_already(error: &str) -> bool {
    error.to_ascii_lowercase().contains("exists already")
}

// What: the sqlite database, created once from schema.
// Why: Alpine's backend ships no schema; the image does.
// From: Issue #815
fn pdns_database(data_dir: &Path) -> Result<PathBuf, String> {
    let db = data_dir.join("pdns.sqlite3");
    // What: a stat error stops the start, not a rebuild.
    // Why: an existing database must never be replaced.
    // From: Issue #1683 | PR #1912
    if db
        .try_exists()
        .map_err(|e| format!("cannot check {}: {e}", db.display()))?
    {
        return Ok(db);
    }
    let schema_file = config::need(&config::process_env, "PDNS_SCHEMA_FILE")?;
    let schema =
        fs::read_to_string(&schema_file).map_err(|e| format!("cannot read {schema_file}: {e}"))?;
    let created = rusqlite::Connection::open(&db)
        .and_then(|conn| conn.execute_batch(&schema))
        .map_err(|e| format!("cannot create {} from {schema_file}: {e}", db.display()));
    // What: a half-made database file is removed.
    // Why: the next start would skip a file that exists.
    // From: Issue #1683 | PR #1912
    if let Err(e) = created {
        if let Err(rm) = fs::remove_file(&db)
            && rm.kind() != io::ErrorKind::NotFound
        {
            log_err(&format!("WARNING: {} not removed: {rm}", db.display()));
        }
        return Err(e);
    }
    // What: the owner changes; the mode SQLite chose stays.
    // Why: own with no mode leaves the mode alone.
    // From: Issue #1683 | PR #1912
    own(
        &db,
        Some(account_id("passwd", "pdns")?),
        Some(account_id("group", "pdns")?),
        None,
    )
    .map_err(|e| e.to_string())?;
    log(&format!("Created {}", db.display()));
    Ok(db)
}

// What: TSIG rights for DDNS on every LAN zone.
// Why: an empty key revokes; the ui marker relaxes.
// From: Issue #1683 | PR #1912
fn ddns_tsig(
    dir: &Path,
    zones: &[String],
    tsig: &str,
    id: &TsigId,
    unsigned: &Path,
) -> Result<(), String> {
    if tsig.is_empty() {
        for zone in zones {
            pdnsutil(dir, &["set-meta", zone, "TSIG-ALLOW-DNSUPDATE"])?;
        }
        if let Err(e) = pdnsutil(dir, &["delete-tsig-key", id.name.as_str()]) {
            log(&format!("No TSIG key to delete: {e}"));
        }
        log("DDNS_TSIG_KEY is empty; DDNS stays loopback-only, TSIG rights revoked");
        return Ok(());
    }
    pdnsutil(
        dir,
        &[
            "import-tsig-key",
            id.name.as_str(),
            id.algorithm.as_str(),
            tsig,
        ],
    )?;
    // What: an unreadable marker is logged; signed stays.
    // Why: strict is the safe side; the cause is shown.
    // From: Issue #1683 | PR #1912
    let relaxed = unsigned.try_exists().unwrap_or_else(|e| {
        log_err(&format!(
            "WARNING: cannot check {}: {e}",
            unsigned.display()
        ));
        false
    });
    if relaxed {
        log_err("WARNING: the ui allows unsigned DNS UPDATE for LAN zones");
    }
    for zone in zones {
        let mut args = vec!["set-meta", zone.as_str(), "TSIG-ALLOW-DNSUPDATE"];
        if !relaxed {
            args.push(id.name.as_str());
        }
        pdnsutil(dir, &args)?;
    }
    Ok(())
}

// What: zones as primary or AXFR secondary, keyed.
// Why: one writer; NOTIFY and polling converge on it.
// From: Issue #1164
fn dns_zones(
    dir: &Path,
    role: DnsRole,
    tsig: &str,
    primary: Option<std::net::SocketAddrV4>,
    notify: &[std::net::SocketAddrV4],
) -> Result<(), String> {
    let zones = rollback_zones()?;
    let id = TsigId::load()?;
    if let (DnsRole::Secondary, Some(primary)) = (role, primary) {
        if tsig.is_empty() {
            return Err("DDNS_TSIG_KEY is required for AXFR from the primary".into());
        }
        pdnsutil(
            dir,
            &[
                "import-tsig-key",
                id.name.as_str(),
                id.algorithm.as_str(),
                tsig,
            ],
        )?;
        let primary = primary.to_string();
        for zone in &zones {
            match pdnsutil(dir, &["zone", "create-secondary", zone, &primary]) {
                Ok(_) => {}
                Err(e) if exists_already(&e) => {
                    pdnsutil(dir, &["zone", "set-kind", zone, "secondary"])?;
                    pdnsutil(dir, &["zone", "change-primary", zone, &primary])?;
                }
                Err(e) => return Err(e),
            }
            pdnsutil(
                dir,
                &["tsigkey", "activate", zone, id.name.as_str(), "secondary"],
            )?;
        }
        return Ok(());
    }
    for zone in &zones {
        match pdnsutil(dir, &["create-zone", zone]) {
            Ok(_) => {}
            Err(e) if exists_already(&e) => {}
            Err(e) => return Err(e),
        }
    }
    ddns_tsig(dir, &zones, tsig, &id, &ddns_unsigned_marker()?)?;
    let targets: Vec<String> = notify.iter().map(ToString::to_string).collect();
    for zone in &zones {
        pdnsutil(dir, &["zone", "set-kind", zone, "primary"])?;
        // What: SOA bump and NOTIFY on API and DDNS writes.
        // Why: secondaries converge via NOTIFY and AXFR.
        // From: Issue #1683 | PR #1912
        pdnsutil(dir, &["set-meta", zone, "SOA-EDIT-DNSUPDATE", "INCREASE"])?;
        pdnsutil(dir, &["set-meta", zone, "SOA-EDIT-API", "INCREASE"])?;
        pdnsutil(dir, &["set-meta", zone, "NOTIFY-DNSUPDATE", "1"])?;
        if !tsig.is_empty() {
            pdnsutil(
                dir,
                &["tsigkey", "activate", zone, id.name.as_str(), "primary"],
            )?;
        }
        if !targets.is_empty() {
            let mut args = vec!["set-meta", zone.as_str(), "ALSO-NOTIFY"];
            args.extend(targets.iter().map(String::as_str));
            pdnsutil(dir, &args)?;
        }
    }
    Ok(())
}

// What: the ui's unsigned-DDNS marker in the state dir.
// Why: pdns watches it; a toggle restarts and re-keys.
// From: Issue #815 | PR #1912
fn ddns_unsigned_marker() -> Result<PathBuf, String> {
    let state = config::need(&config::process_env, "DNS_STATE_DIR")?;
    Ok(Path::new(&state).join(config::DDNS_UNSIGNED_MARKER))
}

// What: today's date serial, YYMMDD000 (UTC).
// Why: under 2^31 (RFC 1982); 1000 changes per day.
// From: Issue #1095
fn date_serial() -> u64 {
    let today = OffsetDateTime::now_utc();
    (u64::from(today.year().rem_euclid(100) as u16) * 10_000
        + u64::from(u8::from(today.month())) * 100
        + u64::from(today.day()))
        * 1000
}

// What: render, check and key the authoritative server.
// Why: pdns serves only a checked config; errors retry.
// From: Issue #1683
fn pdns_auth(ctx: &Ctx) -> Result<Run, String> {
    let role = dns_role(&ctx.need("DNS_REPLICATION_ROLE")?)?;
    let api_key = pdns_api_key()?;
    // What: TSIG off when the shared key cannot persist.
    // Why: a key only this container knows signs nothing.
    // From: Issue #1683 | PR #1912
    let tsig = ddns_tsig_key().unwrap_or_else(|e| {
        log_err(&format!("WARNING: DDNS TSIG is off: {e}"));
        String::new()
    });
    // What: no key or a replica: DDNS only from loopback.
    // Why: unsigned or replica LAN updates are refused.
    // From: Issue #1683 | PR #1912
    let loopback = config::loopback()?;
    let allow_from = if tsig.is_empty() || role == DnsRole::Secondary {
        loopback.clone()
    } else {
        [Some(ctx.need("IP_HTTP")?), env_opt("IP_HTTPS")]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(",")
    };
    let (refresh, retry, _) = soa_knobs()?;
    let local = own_address()?;
    let (primary, notify) = match role {
        DnsRole::Secondary => (
            Some(endpoint(&ctx.need("DNS_XFR_PRIMARY")?, "DNS_XFR_PRIMARY")?),
            Vec::new(),
        ),
        DnsRole::Primary => (None, notify_targets()?),
    };
    let notify_from = primary.map(|p| p.ip().to_string()).unwrap_or_default();
    let knobs = DnsKnobs::load()?;
    let axfr_ips = knobs
        .loopback_nets
        .iter()
        .cloned()
        .chain(notify.iter().map(|t| t.ip().to_string()))
        .collect::<Vec<_>>()
        .join(",");
    let data_dir = PathBuf::from(ctx.need("PDNS_DATA_DIR")?);
    let database = pdns_database(&data_dir)?;
    let database = database.display().to_string();
    let any = config::any_bind(&config::process_env)?;
    let seed = date_serial().to_string();
    let conf = AuthConf {
        any: &any,
        knobs: &knobs,
        local,
        database: &database,
        role,
        notify_from: &notify_from,
        axfr_ips: &axfr_ips,
        allow_from: &allow_from,
        loopback: &loopback,
        seed_serial: &seed,
        refresh,
        retry,
        auth_port: env_port(AUTH_PORT_KEY)?,
        api_port: env_port(AUTH_API_PORT_KEY)?,
        api_key: &api_key,
    };
    let dir = ctx.run_dir.join("auth");
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DNS_CONFIG_SNAPSHOT_DIR")?).join("auth"),
        ctx.need("DNS_AUTH_CONFIG_SNAPSHOT_FILE")?,
        "dns-auth",
    );
    let restamp = |old: &str| {
        restamp_lines(
            old,
            &[
                (
                    "local-address=",
                    format!("local-address={loopback},{local}"),
                ),
                ("api-key=", format!("api-key={api_key}")),
            ],
        )
    };
    let config_dir = pdns_config_dir(&dir);
    checked_files(
        &[(dir.join("pdns.conf"), conf.render())],
        &pdns_check("pdns_server", &config_dir),
        &store,
        &restamp,
        &no_backfill,
        true,
    )?;
    dns_zones(&dir, role, &tsig, primary, &notify)?;
    Ok(Run {
        argv: vec![
            "pdns_server".into(),
            config_dir,
            "--guardian=no".into(),
            "--daemon=no".into(),
        ],
        watch: if primary.is_none() {
            vec![ddns_unsigned_marker()?]
        } else {
            Vec::new()
        },
        ..Run::default()
    })
}

// What: RPZ zone mapping each CDN name to the proxy.
// Why: "." marks a wildcard-only row, "!" a disabled one.
// From: Issue #1683 | PR #1912
fn rpz_zone(
    domains: &str,
    proxy: std::net::Ipv4Addr,
    serial: u64,
    knobs: &DnsKnobs,
) -> (String, usize) {
    // What: locals feed the template as plain captures.
    // Why: CodeQL misses captures beside named args.
    // From: Issue #1683 | PR #1912
    let (ttl, mname, rname) = (knobs.rpz_ttl, &knobs.soa_mname, &knobs.rpz_rname);
    let (refresh, retry, expire) = (knobs.rpz_refresh, knobs.rpz_retry, knobs.soa_expire);
    let mut zone = format!(
        "$ORIGIN rpz.\n$TTL {ttl}\n\
         @ SOA {mname} {rname} {serial} {refresh} {retry} {expire} {ttl}\n\
         @ NS {mname}\n\n"
    );
    let (rows, invalid) = cdn_rows(domains);
    for row in invalid {
        log_err(&format!("WARNING: skipping invalid RPZ entry {row:?}"));
    }
    for (name, wildcard) in &rows {
        let owner = if *wildcard {
            format!("*.{name}")
        } else {
            name.clone()
        };
        zone.push_str(&format!("{owner} {ttl} IN A {proxy}\n"));
    }
    (zone, rows.len())
}

// What: valid cdn-domains rows as (name, wildcard-only).
// Why: dns and proxy read one file with one rule set.
// From: Issue #1072 | PR #1912
fn cdn_rows(domains: &str) -> (Vec<(String, bool)>, Vec<String>) {
    let (mut rows, mut invalid) = (Vec::new(), Vec::new());
    for row in domains.lines().map(str::trim) {
        if row.is_empty() || row.starts_with('#') || row.starts_with('!') {
            continue;
        }
        match config::cdn_entry(row) {
            Some(entry) => rows.push(entry),
            None => invalid.push(row.to_string()),
        }
    }
    (rows, invalid)
}

// What: the optional upstream resolver of the recursors.
// Why: a router may know LAN names LanCache cannot.
// From: Issue #1918 | PR #1858
#[derive(Debug, Default)]
struct Upstream {
    servers: Vec<String>,
    zones: Vec<String>,
    unsigned: Vec<String>,
}

// What: one DNS_UPSTREAM_* list, space or comma split.
// Why: setup.sh and operators write either separator.
// From: Issue #1918 | PR #1858
fn upstream_list(key: &str) -> Vec<String> {
    env_opt(key)
        .unwrap_or_default()
        .split([' ', ','])
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

// What: one forwarder as ip or ip:port, checked.
// Why: this host, its container or LanCache would loop.
// From: Issue #1918 | PR #1858
fn upstream_server(entry: &str, own: std::net::Ipv4Addr) -> Result<String, String> {
    let (ip, text) = match entry.parse::<std::net::IpAddr>() {
        Ok(ip) => (ip, ip.to_string()),
        Err(_) => match entry.parse::<std::net::SocketAddr>() {
            Ok(addr) if addr.port() != 0 => (addr.ip(), addr.to_string()),
            _ => {
                return Err(format!(
                    "DNS_UPSTREAM_SERVERS entry {entry} is no IP or IP:port"
                ));
            }
        },
    };
    if ip.is_loopback() || ip.is_unspecified() || ip == own || is_lancache_ip(&ip.to_string()) {
        return Err(format!(
            "DNS_UPSTREAM_SERVERS entry {entry} is this host or LanCache and would loop"
        ));
    }
    Ok(text)
}

// What: one zone list, lower case, without duplicates.
// Why: local zones stay with the local auth server.
// From: Issue #1918 | PR #1858
fn upstream_zones(key: &str, local: &[String]) -> Result<Vec<String>, String> {
    let mut zones: Vec<String> = Vec::new();
    for raw in upstream_list(key) {
        let lower = raw.to_ascii_lowercase();
        let zone = if lower == "." {
            lower
        } else {
            lower.trim_end_matches('.').to_string()
        };
        if zone != "." && !config::is_dns_name(&zone, false, false) {
            return Err(format!("{key} entry {raw} is no DNS zone name"));
        }
        let dotted = config::canonical_zone(&zone);
        if local
            .iter()
            .any(|l| dotted == *l || dotted.ends_with(&format!(".{l}")))
        {
            return Err(format!(
                "{key} entry {raw} is served by the local auth server"
            ));
        }
        if !zones.contains(&zone) {
            zones.push(zone);
        }
    }
    Ok(zones)
}

// What: DNS_UPSTREAM_* as forwarders and zone lists.
// Why: a bad value must never reach recursor.conf.
// From: Issue #1918 | PR #1858
fn upstream(local: &[String]) -> Result<Upstream, String> {
    let entries = upstream_list("DNS_UPSTREAM_SERVERS");
    if entries.is_empty() {
        return Ok(Upstream::default());
    }
    let own = own_address()?;
    let servers = entries
        .iter()
        .map(|entry| upstream_server(entry, own))
        .collect::<Result<Vec<_>, _>>()?;
    let zones = upstream_zones("DNS_UPSTREAM_ZONES", local)?;
    if zones.is_empty() {
        return Err(config::not_set("DNS_UPSTREAM_ZONES"));
    }
    let unsigned = upstream_zones("DNS_UPSTREAM_UNSIGNED_ZONES", local)?;
    let inside = |name: &str| {
        name != "."
            && zones
                .iter()
                .any(|z| z == "." || z == name || name.ends_with(&format!(".{z}")))
    };
    if let Some(bad) = unsigned.iter().find(|name| !inside(name)) {
        return Err(format!(
            "DNS_UPSTREAM_UNSIGNED_ZONES entry {bad} is \".\" or outside DNS_UPSTREAM_ZONES"
        ));
    }
    Ok(Upstream {
        servers,
        zones,
        unsigned,
    })
}

// What: recursor.lua: RPZ, LAN trust anchors, root copy.
// Why: one render per recursor; the RPZ path differs.
// From: Issue #1683
fn recursor_lua(
    rpz: &str,
    zones: &[String],
    root_mirror: bool,
    knobs: &DnsKnobs,
    upstream: &Upstream,
) -> String {
    let mut lua = format!("rpzFile(\"{rpz}\", {{ policyName=\"lancache-rpz\" }})\n");
    for zone in zones {
        lua.push_str(&format!(
            "addNTA(\"{}\", \"lancache-ng: locally forwarded, intentionally unsigned zone\")\n",
            zone.trim_end_matches('.')
        ));
    }
    // What: NTA only for the private upstream zones.
    // Why: forwarded public names stay validated.
    // From: Issue #1918 | PR #1858
    for zone in &upstream.unsigned {
        lua.push_str(&format!(
            "addNTA(\"{zone}\", \"lancache-ng: unsigned zone of the upstream resolver\")\n"
        ));
    }
    // What: no root copy while "." goes to the upstream.
    // Why: the copy would answer what the upstream should.
    // From: Issue #1918 | PR #1858
    if root_mirror && !upstream.zones.iter().any(|z| z == ".") {
        for ip in &knobs.root_servers {
            lua.push_str(&format!(
                "zoneToCache(\".\", \"axfr\", \"{ip}\", {{ refreshPeriod={}, retryOnError={} }})\n",
                knobs.root_refresh, knobs.root_retry
            ));
        }
    }
    lua
}

// What: recursor.conf (YAML) of one recursor.
// Why: LAN zones go to the local auth on PDNS_AUTH_PORT.
// From: Issue #1683
struct RecursorConf<'a> {
    port: u16,
    auth_port: u16,
    api_port: u16,
    api_key: &'a str,
    negative_ttl: u64,
    loglevel: u64,
    lua_config: &'a str,
    lua_dns: &'a str,
    zones: &'a [String],
    loopback: &'a str,
    any: &'a str,
    knobs: &'a DnsKnobs,
    upstream: &'a Upstream,
}

impl RecursorConf<'_> {
    fn render(&self) -> String {
        let mut forwards: String = self
            .zones
            .iter()
            .map(|z| {
                format!(
                    "    - zone: {}\n      forwarders: [{}:{}]\n",
                    z.trim_end_matches('.'),
                    self.loopback,
                    self.auth_port
                )
            })
            .collect();
        // What: forward_zones_recurse only with servers.
        // Why: no setting keeps resolving from the roots.
        // From: Issue #1918 | PR #1858
        if !self.upstream.servers.is_empty() {
            let servers = self
                .upstream
                .servers
                .iter()
                .map(|s| format!("\"{s}\""))
                .collect::<Vec<_>>()
                .join(", ");
            forwards.push_str("  forward_zones_recurse:\n");
            for zone in &self.upstream.zones {
                forwards.push_str(&format!(
                    "    - zone: \"{zone}\"\n      forwarders: [{servers}]\n"
                ));
            }
        }
        // What: locals feed the template as plain captures.
        // Why: CodeQL misses captures beside named args.
        // From: Issue #1683 | PR #1912
        let RecursorConf {
            port,
            api_port,
            api_key: key,
            negative_ttl: ttl,
            loglevel,
            lua_config,
            lua_dns,
            any,
            knobs: k,
            ..
        } = *self;
        let (query, api) = (yaml_rows(&k.query_allow), yaml_rows(&k.api_allow));
        let (min_ttl, rc_max) = (k.minimum_ttl_override, k.recordcache_max);
        let (perc, stale) = (k.refresh_on_ttl_perc, k.serve_stale_extensions);
        let (pc_max, pc_ttl) = (k.packetcache_max, k.packetcache_ttl);
        let servfail = k.servfail_ttl;
        format!(
            "incoming:\n  listen:\n    - {any}\n  port: {port}\n  allow_from:\n{query}\
             recursor:\n  forward_zones:\n{forwards}  lua_config_file: {lua_config}\n\
             \x20 lua_dns_script: {lua_dns}\n  minimum_ttl_override: {min_ttl}\n\
             recordcache:\n  max_entries: {rc_max}\n  refresh_on_ttl_perc: {perc}\n\
             \x20 serve_stale_extensions: {stale}\n  max_negative_ttl: {ttl}\n\
             packetcache:\n  max_entries: {pc_max}\n  ttl: {pc_ttl}\n  negative_ttl: {ttl}\n\
             \x20 servfail_ttl: {servfail}\n\
             webservice:\n  webserver: true\n  address: {any}\n  port: {api_port}\n\
             \x20 allow_from:\n{api}  api_key: {key}\n\
             logging:\n  loglevel: {loglevel}\n"
        )
    }
}

// What: render RPZ, lua and conf; start one recursor.
// Why: cdn-domains.txt changes restart it with new RPZ.
// From: Issue #1683
fn recursor(ctx: &Ctx, rec: &Recursor) -> Result<Run, String> {
    let api_key = pdns_api_key()?;
    let ip = ctx.need(rec.ip_key)?;
    let proxy: std::net::Ipv4Addr = ip
        .parse()
        .map_err(|_| format!("{}={ip} is no IPv4 address", rec.ip_key))?;
    let role = dns_role(&ctx.need("DNS_REPLICATION_ROLE")?)?;
    let knobs = DnsKnobs::load()?;
    // What: secondary negative TTL = AXFR cycle.
    // Why: a pre-AXFR miss must not outlive the sync.
    // From: Issue #1683 | PR #1912
    let negative_ttl = if role == DnsRole::Secondary {
        knobs.xfr_cycle
    } else {
        knobs.negative_ttl
    };
    let flag = |key: &str| env_opt(key).as_deref().and_then(config::parse_bool);
    let loglevel = if flag("LOG_QUERIES") == Some(true) {
        knobs.loglevel_queries
    } else {
        knobs.loglevel
    };
    let domains_file = PathBuf::from(ctx.need("CDN_DOMAINS_FILE")?);
    let domains = fs::read_to_string(&domains_file)
        .map_err(|e| format!("cannot read {}: {e}", domains_file.display()))?;
    let dir = ctx.run_dir.join(rec.name);
    let (rpz, count) = rpz_zone(&domains, proxy, unix_secs(), &knobs);
    let rpz_file = dir.join("rpz.zone");
    let lua_file = dir.join("recursor.lua");
    let zones = rollback_zones()?;
    // What: a bad DNS_UPSTREAM_* starts without upstream.
    // Why: a typo must not take DNS away; the log names it.
    // From: Issue #1918 | PR #1858
    let upstream = upstream(&zones).unwrap_or_else(|e| {
        log_err(&format!(
            "ERROR: {e}; starting WITHOUT an upstream resolver. \
             Fix it with: ./setup.sh configure-upstream-dns"
        ));
        Upstream::default()
    });
    write_file(&rpz_file, rpz.as_bytes(), 0o644, Place::Replace)
        .map_err(|e| format!("cannot write {}: {e}", rpz_file.display()))?;
    let lua = |upstream: &Upstream| {
        recursor_lua(
            &rpz_file.display().to_string(),
            &zones,
            flag("ROOT_ZONE_MIRROR") != Some(false),
            &knobs,
            upstream,
        )
    };
    // What: a snapshot without recursor.lua is an old one.
    // Why: its lua had no upstream; rebuild it that way.
    // From: Issue #1918 | PR #1858
    let plain_lua = lua(&Upstream::default());
    let lua_name = lua_file
        .file_name()
        .map(|n| n.to_string_lossy().into_owned());
    let backfill =
        |_: &Value, file: &str| (lua_name.as_deref() == Some(file)).then(|| plain_lua.clone());
    log(&format!("{}: RPZ holds {count} records", rec.name));
    let lua_dns = ctx.need("PDNS_LUA_DNS_SCRIPT")?;
    let any = config::any_bind(&config::process_env)?;
    let loopback = config::loopback()?;
    let conf = RecursorConf {
        loopback: &loopback,
        any: &any,
        port: rec.port()?,
        auth_port: env_port(AUTH_PORT_KEY)?,
        api_port: rec.api_port()?,
        api_key: &api_key,
        negative_ttl,
        loglevel,
        lua_config: &lua_file.display().to_string(),
        lua_dns: &lua_dns,
        zones: &zones,
        knobs: &knobs,
        upstream: &upstream,
    };
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DNS_CONFIG_SNAPSHOT_DIR")?).join(rec.name),
        ctx.need("DNS_RECURSOR_CONFIG_SNAPSHOT_FILE")?,
        "dns-recursor",
    );
    let restamp = |old: &str| restamp_lines(old, &[("api_key:", format!("  api_key: {api_key}"))]);
    let config_dir = pdns_config_dir(&dir);
    // What: recursor.lua joins the checked snapshot set.
    // Why: a rollback must restore conf and lua together.
    // From: Issue #1918 | PR #1858
    checked_files(
        &[
            (dir.join("recursor.conf"), conf.render()),
            (lua_file.clone(), lua(&upstream)),
        ],
        &pdns_check("pdns_recursor", &config_dir),
        &store,
        &restamp,
        &backfill,
        true,
    )?;
    Ok(Run {
        argv: vec![
            "pdns_recursor".into(),
            config_dir,
            format!("--socket-dir={}", dir.display()),
        ],
        env: vec![(
            AAAA_FILTER_PATH_ENV.into(),
            Path::new(&ctx.need("DNS_STATE_DIR")?)
                .join(config::AAAA_FILTER_MARKER)
                .display()
                .to_string(),
        )],
        watch: vec![domains_file],
    })
}

// What: nats.conf from the roles, then nats-server.
// Why: the ui writes only the callout; a change restarts.
// From: Issue #811 | PR #1912
fn nats_server(ctx: &Ctx) -> Result<Run, String> {
    let conf = ctx.need("NATS_CONF_PATH")?;
    let fragment = ctx.need("NATS_AUTH_CALLOUT_PATH")?;
    // What: wait for the fragment; a stat error is named.
    // Why: "waiting" must not hide a permission fault.
    // From: Issue #1683 | PR #1912
    let written = Path::new(&fragment)
        .try_exists()
        .map_err(|e| format!("cannot check {fragment}: {e}"))?;
    if !written {
        return Err(format!("waiting for the ui to write {fragment}"));
    }
    let roles = NatsRoles::read(&|user_key, password_key| {
        Ok(NatsLogin {
            user: env_opt(user_key).unwrap_or_default(),
            password: Some(stack_secret(
                password_key,
                &shared_secret_file_name(password_key),
                hex32,
            )?),
        })
    })?;
    let port = env_port("NATS_MONITOR_PORT")?;
    let body = render_nats_conf(&roles, &ctx.need("NATS_STORE_DIR")?, port, &conf, &fragment)?;
    write_file(Path::new(&conf), body.as_bytes(), 0o600, Place::Replace)
        .map_err(|e| format!("cannot write {conf}: {e}"))?;
    Ok(Run {
        argv: vec!["nats-server".into(), "-c".into(), conf.clone()],
        watch: vec![PathBuf::from(conf), PathBuf::from(fragment)],
        ..Run::default()
    })
}

// What: nats-subscriber with resolved secrets and URLs.
// Why: it flushes every running recursor, writes zones.
// From: Issue #1683
fn nats_subscriber(ctx: &Ctx) -> Result<Run, String> {
    let loopback = config::loopback()?;
    let recursors = [&DNS_HTTP, &DNS_HTTPS]
        .iter()
        .filter(|r| r.runs())
        .map(|r| r.api_port().map(|port| api_root(&loopback, port)))
        .collect::<Result<Vec<_>, _>>()?;
    let mut env = vec![
        ("PDNS_API_KEY".to_string(), pdns_api_key()?),
        (
            "PDNS_AUTH_API_URL".to_string(),
            api_root(&loopback, env_port(AUTH_API_PORT_KEY)?),
        ),
        ("PDNS_REC_API_URLS".to_string(), recursors.join(" ")),
        (
            "PDNS_AUTH_CONFIG_DIR".to_string(),
            ctx.run_dir.join("auth").display().to_string(),
        ),
        (
            "DNS_ROLLBACK_LISTEN_ADDR".to_string(),
            format!(
                "{}:{}",
                config::any_bind(&config::process_env)?,
                env_port(ROLLBACK_PORT_KEY)?
            ),
        ),
    ];
    // What: writer's NATS password from the shared file.
    // Why: a remote secondary has its own; no file is used.
    // From: Issue #1683 | PR #1912
    if let Some(file) = env_opt("NATS_PASSWORD_SHARED_SECRET") {
        env.push((
            "NATS_PASSWORD".to_string(),
            stack_secret("NATS_PASSWORD", &file, hex32)?,
        ));
    }
    Ok(Run {
        argv: vec!["nats-subscriber".into()],
        env,
        watch: Vec::new(),
    })
}

// What: the SOA of one zone: date serial, our timers.
// Why: migrates refresh; a NOTIFY resyncs secondaries.
// From: Issue #1095
async fn soa_bump(
    pdns: &lancache_ng::PowerDns,
    root: &str,
    zone: &str,
    refresh: u64,
    retry: u64,
) -> Result<(), String> {
    let rrsets = pdns.zone_rrsets(root, zone).await?;
    let content = rrsets
        .iter()
        .find(|r| r.get("type").and_then(Value::as_str) == Some("SOA"))
        .and_then(|r| r.pointer("/records/0/content"))
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{zone} has no SOA yet"))?;
    let fields: Vec<&str> = content.split_whitespace().collect();
    let [mname, rname, serial, _, _, expire, minimum] = fields.as_slice() else {
        return Err(format!("{zone} SOA has an odd shape: {content}"));
    };
    let serial: u64 = serial
        .parse()
        .map_err(|_| format!("{zone} SOA serial {serial} is no number"))?;
    let want = date_serial();
    let next = if serial < want { want } else { serial + 1 };
    let ttl: u64 = minimum
        .parse()
        .map_err(|e| format!("{zone} SOA minimum {minimum} is no number: {e}"))?;
    let name = config::canonical_zone(zone);
    let body = serde_json::json!({"rrsets": [{
        "name": name, "type": "SOA", "ttl": ttl, "changetype": "REPLACE",
        "records": [{"content": format!("{mname} {rname} {next} {refresh} {retry} {expire} {minimum}"),
                     "disabled": false}]
    }]});
    let url = config::zone_url(root, zone);
    let response = pdns
        .call(reqwest::Method::PATCH, &url, Some(body.to_string()))
        .await?;
    if !response.status().is_success() {
        return Err(format!("{zone} SOA PATCH returned {}", response.status()));
    }
    let notify = pdns
        .call(reqwest::Method::PUT, &format!("{url}/notify"), None)
        .await?;
    if !notify.status().is_success() {
        log_err(&format!(
            "WARNING: {zone} NOTIFY returned {}",
            notify.status()
        ));
    }
    Ok(())
}

// What: keep every primary zone's SOA current.
// Why: a lost NOTIFY heals within one resync period.
// From: Issue #1095
async fn soa_upkeep() -> Result<(), String> {
    let (refresh, retry, resync) = soa_knobs()?;
    let cold = bounded("PDNS_SOA_COLD_RETRY", 1, u32::MAX.into())?;
    let http = lancache_ng::http_client(&config::process_env)?;
    let pdns = lancache_ng::PowerDns::new(http, pdns_api_key()?);
    let root = api_root(&config::loopback()?, env_port(AUTH_API_PORT_KEY)?);
    loop {
        let mut ok = 0;
        for zone in rollback_zones()? {
            match soa_bump(&pdns, &root, &zone, refresh, retry).await {
                Ok(()) => ok += 1,
                Err(e) => log_err(&format!("WARNING: {e}")),
            }
        }
        // What: retry soon while no zone could be written.
        // Why: a cold auth server must not wait an hour.
        // From: Issue #1683 | PR #1912
        let pause = if ok == 0 { cold } else { resync };
        tokio::time::sleep(Duration::from_secs(pause)).await;
    }
}

// What: env key of the kea-dhcp4 control socket path.
// Why: the healthcheck and the configs name one socket.
// From: Issue #1683 | PR #1912
const KEA4_SOCKET_KEY: &str = "KEA4_SOCKET";

// What: Kea render values: sockets, hook, fence, logs.
// Why: the SOT owns each value; Rust names only keys.
// From: Issue #1683 | PR #1912
struct KeaKnobs {
    socket_dir: String,
    dhcp4_socket: String,
    ddns_socket: String,
    ctrl_allow: Vec<String>,
    ctrl_chain: String,
    ctrl_realm: String,
    hooks_root: String,
    lease_cmds_hook: String,
    hooks_depth: u32,
    lease_file: String,
    ncr_max_queue: u64,
    generated_prefix: String,
    replace_client_name: String,
    log_severity: String,
    packet_log_severity: String,
    log_debuglevel: u64,
}

impl KeaKnobs {
    // What: every Kea render value from the env.
    // Why: a missing or junk value stops the render.
    // From: Issue #1683 | PR #1912
    fn load() -> Result<Self, String> {
        let text = |key: &str| config::need(&config::process_env, key);
        Ok(Self {
            socket_dir: text("KEA_SOCKET_DIR")?,
            dhcp4_socket: text(KEA4_SOCKET_KEY)?,
            ddns_socket: text("KEA_DDNS_SOCKET")?,
            ctrl_allow: text("KEA_CTRL_ALLOW_FROM")?
                .split_whitespace()
                .map(str::to_string)
                .collect(),
            ctrl_chain: text("KEA_CTRL_CHAIN")?,
            ctrl_realm: text("KEA_CTRL_REALM")?,
            hooks_root: text("KEA_HOOKS_ROOT")?,
            lease_cmds_hook: text("KEA_LEASE_CMDS_HOOK")?,
            hooks_depth: bounded("KEA_HOOKS_SEARCH_DEPTH", 1, u8::MAX.into())? as u32,
            lease_file: text("KEA_LEASE_FILE")?,
            ncr_max_queue: bounded("KEA_NCR_MAX_QUEUE", 1, u32::MAX.into())?,
            generated_prefix: text("KEA_DDNS_GENERATED_PREFIX")?,
            replace_client_name: text("KEA_DDNS_REPLACE_CLIENT_NAME")?,
            log_severity: text("KEA_LOG_SEVERITY")?,
            packet_log_severity: text("KEA_DHCP4_PACKET_LOG_SEVERITY")?,
            log_debuglevel: bounded("KEA_LOG_DEBUGLEVEL", 0, 99)?,
        })
    }
}

// What: env key of the kea-dhcp-ddns loopback port.
// Why: kea-dhcp4 sends its name change requests there.
// From: Issue #1683 | PR #1912
const KEA_NCR_PORT_KEY: &str = "KEA_NCR_PORT";

// What: the shared DDNS TSIG key, or the error.
// Why: dns signs zones with it, Kea signs updates.
// From: Issue #1683 | PR #1912
fn ddns_tsig_key() -> Result<String, String> {
    stack_secret(
        "DDNS_TSIG_KEY",
        &shared_secret_file_name("DDNS_TSIG_KEY"),
        base64_32,
    )
}

// What: the first file of this name below dir, by depth.
// Why: the lease_cmds hook path differs per Kea build.
// From: Issue #1683 | PR #1912
fn find_file(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    // What: unreadable entries are logged.
    // Why: "not found" must not hide a permission fault.
    // From: Issue #1683 | PR #1912
    let skipped = |e: io::Error| log_err(&format!("WARNING: {} not read: {e}", dir.display()));
    let entries = fs::read_dir(dir).inspect_err(|e| {
        log_err(&format!("WARNING: {} not listed: {e}", dir.display()));
    });
    let mut dirs = Vec::new();
    for entry in entries.ok()? {
        let Ok(entry) = entry.map_err(skipped) else {
            continue;
        };
        let path = entry.path();
        if entry.file_name() == name {
            return Some(path);
        }
        if depth > 0 && entry.file_type().map_err(skipped).is_ok_and(|t| t.is_dir()) {
            dirs.push(path);
        }
    }
    dirs.into_iter()
        .find_map(|d| find_file(&d, name, depth - 1))
}

// What: DHCP_NTP_SERVERS as IPv4 addresses; names resolve.
// Why: DHCP option 42 carries addresses, never names.
// From: Issue #1683
fn dhcp_ntp_servers(raw: &str, port: u16) -> Result<Vec<std::net::Ipv4Addr>, String> {
    use std::net::ToSocketAddrs as _;
    raw.split([',', ' '])
        .filter(|s| !s.is_empty())
        .map(|host| {
            if let Ok(ip) = host.parse() {
                return Ok(ip);
            }
            (host, port)
                .to_socket_addrs()
                .map_err(|e| format!("DHCP_NTP_SERVERS: cannot resolve {host}: {e}"))?
                .find_map(|addr| match addr {
                    std::net::SocketAddr::V4(v4) => Some(*v4.ip()),
                    std::net::SocketAddr::V6(_) => None,
                })
                .ok_or_else(|| format!("DHCP_NTP_SERVERS: {host} has no IPv4 address"))
        })
        .collect()
}

// What: Kea loggers that write to stdout only.
// Why: Docker hands stdout to the one syslog-ng.
// From: Issue #1683 | PR #1912
fn kea_loggers(loggers: &[(&str, &str)], debuglevel: u64) -> Value {
    loggers
        .iter()
        .map(|(name, severity)| {
            serde_json::json!({
                "name": name,
                "output-options": [{"output": "stdout"}],
                "severity": severity,
                "debuglevel": debuglevel
            })
        })
        .collect()
}

// What: kea-dhcp4.conf of a first start, from the env.
// Why: afterwards the ui edits Kea through its API only.
// From: Issue #815 | PR #1912
fn kea_dhcp4_first(ctx: &Ctx, kea: &KeaKnobs) -> Result<Value, String> {
    let limits = config::LeaseLimits::load(&config::process_env)?;
    let lease = limits.lease(&config::process_env, "DHCP_LEASE_TIME")?;
    let domain = config::lan_zone(&config::process_env)?;
    let mut options = vec![
        serde_json::json!({"name": config::OPTION_ROUTERS.name, "data": ctx.need("DHCP_GATEWAY")?}),
        serde_json::json!({
            "name": config::OPTION_DNS.name,
            "data": format!("{}, {}", ctx.need_dns("DHCP_DNS_PRIMARY")?, ctx.need_dns("DHCP_DNS_SECONDARY")?)
        }),
        serde_json::json!({"name": config::OPTION_DOMAIN.name, "data": domain}),
        serde_json::json!({"name": config::OPTION_SEARCH.name, "data": domain}),
    ];
    let ntp = dhcp_ntp_servers(
        &env_opt("DHCP_NTP_SERVERS").unwrap_or_default(),
        env_port("NTP_PORT")?,
    )?;
    if !ntp.is_empty() {
        let list: Vec<String> = ntp.iter().map(ToString::to_string).collect();
        options.push(serde_json::json!({"name": config::OPTION_NTP.name, "data": list.join(",")}));
    }
    Ok(serde_json::json!({
        "Dhcp4": {
            "interfaces-config": {"interfaces": ["*"], "re-detect": false},
            "lease-database": {
                "type": "memfile",
                "persist": true,
                "name": kea.lease_file
            },
            "subnet4": [{
                "id": 1,
                "subnet": ctx.need("DHCP_SUBNET")?,
                "pools": [{"pool": format!("{} - {}", ctx.need("DHCP_RANGE_START")?, ctx.need("DHCP_RANGE_END")?)}],
                "option-data": options,
                "valid-lifetime": lease,
                "max-valid-lifetime": limits.max_lifetime(lease)
            }]
        }
    }))
}

// What: force socket, hook, logs; default DDNS keys.
// Why: socket, hook, logs must match the image.
// From: Issue #815 | PR #1912
fn kea_dhcp4_own(
    conf: &mut Value,
    hook: &Path,
    domain: &str,
    ddns: bool,
    ncr: (&str, u16),
    kea: &KeaKnobs,
) -> Result<(), String> {
    let dhcp4 = conf
        .get_mut("Dhcp4")
        .and_then(Value::as_object_mut)
        .ok_or("the Kea config has no Dhcp4 object")?;
    dhcp4.insert(
        "control-socket".into(),
        serde_json::json!({"socket-type": "unix", "socket-name": kea.dhcp4_socket}),
    );
    let lease_cmds = std::ffi::OsStr::new(&kea.lease_cmds_hook);
    let mut hooks: Vec<Value> = dhcp4
        .get("hooks-libraries")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    hooks.retain(|h| {
        h.get("library")
            .and_then(Value::as_str)
            .is_none_or(|lib| Path::new(lib).file_name() != Some(lease_cmds))
    });
    hooks.push(serde_json::json!({"library": hook.display().to_string()}));
    dhcp4.insert("hooks-libraries".into(), Value::Array(hooks));
    // What: set DDNS and threading keys only if absent.
    // Why: a saved UI choice must survive restarts.
    // From: Issue #1683 | PR #1912
    let defaults = [
        (
            "multi-threading",
            serde_json::json!({"enable-multi-threading": false}),
        ),
        (
            "dhcp-ddns",
            serde_json::json!({
                "enable-updates": ddns,
                "server-ip": ncr.0,
                "server-port": ncr.1,
                "sender-ip": ncr.0,
                "max-queue-size": kea.ncr_max_queue,
                "ncr-protocol": "UDP",
                "ncr-format": "JSON"
            }),
        ),
        ("ddns-send-updates", Value::Bool(true)),
        ("ddns-override-no-update", Value::Bool(true)),
        ("ddns-override-client-update", Value::Bool(true)),
        (
            "ddns-replace-client-name",
            kea.replace_client_name.as_str().into(),
        ),
        (
            "ddns-generated-prefix",
            kea.generated_prefix.as_str().into(),
        ),
        ("ddns-qualifying-suffix", domain.into()),
    ];
    for (key, value) in defaults {
        dhcp4.entry(key).or_insert(value);
    }
    dhcp4.insert(
        "loggers".into(),
        kea_loggers(
            &[
                ("kea-dhcp4", &kea.log_severity),
                ("kea-dhcp4.dhcp4", &kea.packet_log_severity),
            ],
            kea.log_debuglevel,
        ),
    );
    Ok(())
}

// What: the Kea socket dir, private to Kea.
// Why: Kea refuses a socket dir others can enter.
// From: Issue #1683 | PR #1912
fn kea_socket_dir(kea: &KeaKnobs) -> Result<(), String> {
    let dir = &kea.socket_dir;
    fs::create_dir_all(dir)
        .and_then(|()| own(Path::new(dir), None, None, Some(0o750)))
        .map_err(|e| format!("cannot prepare {dir}: {e}"))
}

// What: the Kea snapshot dir, group-writable, others read.
// Why: the ui writes snapshots here; setup.sh reads them.
// From: Issue #614 | PR #1912
fn kea_snapshot_dir(dir: &Path) -> Result<(), String> {
    let gid = config::runtime_gid()?;
    fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    own(dir, None, Some(gid), Some(0o775)).map_err(|e| e.to_string())
}

// What: kea-dhcp4 on its checked config, else a snapshot.
// Why: a bad render falls back to the newest good snapshot.
// From: Issue #815 | PR #1912
fn kea_dhcp4(ctx: &Ctx) -> Result<Run, String> {
    let kea = KeaKnobs::load()?;
    kea_socket_dir(&kea)?;
    let dir = PathBuf::from(ctx.need("KEA_DATA_DIR")?);
    let path = dir.join("kea-dhcp4.conf");
    let hook = find_file(
        Path::new(&kea.hooks_root),
        &kea.lease_cmds_hook,
        kea.hooks_depth,
    )
    .ok_or_else(|| {
        format!(
            "{} is missing under {}",
            kea.lease_cmds_hook, kea.hooks_root
        )
    })?;
    let domain = config::lan_zone(&config::process_env)?;
    let ddns = env_opt("DHCP_DDNS_ENABLED")
        .as_deref()
        .and_then(config::parse_bool)
        == Some(true);
    let loopback = config::loopback()?;
    let ncr_port = env_port(KEA_NCR_PORT_KEY)?;
    // What: a config that cannot take our keys is logged.
    // Why: the fallback to a snapshot must show its cause.
    // From: Issue #1683 | PR #1912
    let owned = |mut conf: Value| -> Option<String> {
        let warn = |e: &dyn std::fmt::Display| log_err(&format!("WARNING: Kea config: {e}"));
        kea_dhcp4_own(&mut conf, &hook, &domain, ddns, (&loopback, ncr_port), &kea)
            .inspect_err(|e| warn(e))
            .ok()?;
        serde_json::to_string_pretty(&conf)
            .inspect_err(|e| warn(e))
            .ok()
    };
    let current = match fs::read_to_string(&path) {
        Ok(raw) => serde_json::from_str(&raw)
            .inspect_err(|e| log_err(&format!("WARNING: {} is no JSON: {e}", path.display())))
            .ok(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Some(kea_dhcp4_first(ctx, &kea)?),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    let snap_dir = PathBuf::from(ctx.need("KEA_CONFIG_SNAPSHOT_DIR")?);
    kea_snapshot_dir(&snap_dir)?;
    let snap_file = ctx.need("KEA_CONFIG_SNAPSHOT_FILE")?;
    let store = lancache_ng::SnapshotStore::new(snap_dir, snap_file, "kea");
    let fresh = current
        .and_then(owned)
        .map(|text| ("current".to_string(), text));
    let set = |(label, text): (String, String)| (label, vec![(path.clone(), text)]);
    let used = first_good(
        &path.display().to_string(),
        fresh.into_iter().chain(snapshots(&store, &owned)).map(set),
        &["kea-dhcp4".into(), "-t".into(), path.display().to_string()],
    )?;
    if used != "current" {
        log_err(&format!(
            "WARNING: kea-dhcp4 runs from known-good snapshot {used}, not its last config"
        ));
    }
    Ok(Run {
        argv: vec!["kea-dhcp4".into(), "-c".into(), path.display().to_string()],
        ..Run::default()
    })
}

// What: fence the Kea control port with one iptables chain.
// Why: host networking would expose the API to the LAN.
// From: Issue #1683
fn kea_ctrl_fence(port: &str, kea: &KeaKnobs) -> Result<(), String> {
    let chain = kea.ctrl_chain.as_str();
    let jump = ["-p", "tcp", "--dport", port, "-j", chain];
    let iptables = |args: &[&str]| run_program("iptables", args, None).map(|_| ());
    if iptables(&["-N", chain]).is_err() {
        iptables(&["-F", chain])?;
    }
    while iptables(&[&["-D", "INPUT"][..], &jump].concat()).is_ok() {}
    iptables(&[&["-I", "INPUT", "1"][..], &jump].concat())?;
    for net in &kea.ctrl_allow {
        iptables(&["-A", chain, "-s", net, "-j", "ACCEPT"])?;
    }
    iptables(&["-A", chain, "-j", "DROP"])
}

// What: the Kea Control Agent behind its token and fence.
// Why: the ui manages Kea through this API alone.
// From: Issue #815 | PR #1912
fn kea_ctrl_agent(ctx: &Ctx) -> Result<Run, String> {
    let kea = KeaKnobs::load()?;
    kea_socket_dir(&kea)?;
    let token = stack_secret(
        "KEA_CTRL_TOKEN",
        &shared_secret_file_name("KEA_CTRL_TOKEN"),
        hex32,
    )?;
    let port_number = env_port("KEA_CTRL_PORT")?;
    let port = port_number.to_string();
    kea_ctrl_fence(&port, &kea)?;
    let conf = serde_json::json!({
        "Control-agent": {
            "http-host": config::any_bind(&config::process_env)?,
            "http-port": port_number,
            "authentication": {
                "type": "basic",
                "realm": kea.ctrl_realm,
                "clients": [{"user": ctx.need("KEA_CTRL_USER")?, "password": token}]
            },
            "control-sockets": {
                "dhcp4": {"socket-type": "unix", "socket-name": kea.dhcp4_socket}
            },
            "loggers": kea_loggers(&[("kea-ctrl-agent", &kea.log_severity)], kea.log_debuglevel)
        }
    });
    let path = ctx.render("kea-ctrl-agent.conf", &conf.to_string())?;
    Ok(Run {
        argv: vec!["kea-ctrl-agent".into(), "-c".into(), path],
        ..Run::default()
    })
}

// What: kea-dhcp-ddns signing A and PTR updates for leases.
// Why: dns accepts them only with the shared TSIG key.
// From: Issue #1076 | PR #1912
fn kea_dhcp_ddns(ctx: &Ctx) -> Result<Run, String> {
    let kea = KeaKnobs::load()?;
    kea_socket_dir(&kea)?;
    let tsig = ddns_tsig_key()?;
    let id = TsigId::load()?;
    let server = serde_json::json!([{
        "ip-address": ctx.need_dns("DHCP_DNS_SERVER_IP")?,
        "port": env_port(AUTH_PORT_KEY)?
    }]);
    let domain = |name: String| serde_json::json!({"name": name, "key-name": id.name, "dns-servers": server});
    let reverse: Vec<Value> = config::reverse_zones().into_iter().map(domain).collect();
    let conf = serde_json::json!({
        "DhcpDdns": {
            "ip-address": config::loopback()?,
            "port": env_port(KEA_NCR_PORT_KEY)?,
            "control-socket": {
                "socket-type": "unix",
                "socket-name": kea.ddns_socket
            },
            "tsig-keys": [{"name": id.name, "algorithm": id.algorithm, "secret": tsig}],
            "forward-ddns": {
                "ddns-domains": [domain(config::canonical_zone(&config::lan_zone(&config::process_env)?))]
            },
            "reverse-ddns": {"ddns-domains": reverse},
            "loggers": kea_loggers(&[("kea-dhcp-ddns", &kea.log_severity)], kea.log_debuglevel)
        }
    });
    let path = ctx.render("kea-dhcp-ddns.conf", &conf.to_string())?;
    Ok(Run {
        argv: vec!["kea-dhcp-ddns".into(), "-c".into(), path],
        ..Run::default()
    })
}

// What: one dnsmasq.conf line per set value, else none.
// Why: a line break would inject a second directive.
// From: Issue #1683 | PR #1912
fn dnsmasq_line(lines: &mut String, key: &str, values: &[&str], line: String) {
    if values.iter().any(|v| v.contains(['\n', '\r'])) {
        log_err(&format!("WARNING: {key} holds a line break; not rendered"));
    } else {
        lines.push_str(&line);
        lines.push('\n');
    }
}

// What: dnsmasq.conf of proxy or relay mode.
// Why: values come from the ui settings, then the env.
// From: Issue #1683 | PR #1912
fn dnsmasq_conf(set: &dyn Fn(&str) -> String, relay: bool, log_dhcp: bool) -> String {
    // What: DHCP-only dnsmasq: no DNS, no resolv.conf.
    // Why: avoids port 53 binding conflicts.
    // From: Issue #485
    let mut conf = String::from("port=0\nno-resolv\nno-poll\nlog-facility=-\n");
    // What: option logging follows the DHCP logging switch.
    // Why: every service has one switch; log-dhcp is extra.
    // From: Issue #1683 | PR #1912
    if log_dhcp {
        conf.push_str("log-dhcp\n");
    }
    let upstream = set("UPSTREAM_DHCP_IP");
    if relay {
        let local = set("DHCP_RELAY_LOCAL_ADDR");
        let line = format!("dhcp-relay={local},{upstream}");
        dnsmasq_line(
            &mut conf,
            "DHCP_RELAY_LOCAL_ADDR",
            &[&local, &upstream],
            line,
        );
        return conf;
    }
    let start = set("DHCP_SUBNET_START");
    dnsmasq_line(
        &mut conf,
        "DHCP_SUBNET_START",
        &[&start],
        format!("dhcp-range={start},proxy"),
    );
    let primary = set("DHCP_DNS_PRIMARY");
    let secondary = set("DHCP_DNS_SECONDARY");
    // What: dhcp-option-pxe prefix of one managed option.
    // Why: its code comes from the one ManagedOption owner.
    // From: Issue #1683 | PR #1912
    let pxe = |option: config::ManagedOption| format!("dhcp-option-pxe={},", option.code);
    let dns = format!("{}{primary},{secondary}", pxe(config::OPTION_DNS));
    dnsmasq_line(&mut conf, "DHCP_DNS_PRIMARY", &[&primary, &secondary], dns);
    let fields = [
        ("DHCP_PROXY_INTERFACE", "interface=".to_string()),
        ("DHCP_PROXY_ROUTER", pxe(config::OPTION_ROUTERS)),
        ("DHCP_NTP_SERVERS", pxe(config::OPTION_NTP)),
        ("DHCP_PROXY_DOMAIN", pxe(config::OPTION_DOMAIN)),
    ];
    for (key, prefix) in fields {
        let value = set(key);
        if !value.is_empty() {
            dnsmasq_line(&mut conf, key, &[&value], format!("{prefix}{value}"));
        }
    }
    let file = set("DHCP_PROXY_BOOT_FILENAME");
    let server = set("DHCP_PROXY_BOOT_SERVER");
    if !file.is_empty() {
        let line = format!("dhcp-boot={file},,{server}");
        dnsmasq_line(
            &mut conf,
            "DHCP_PROXY_BOOT_FILENAME",
            &[&file, &server],
            line,
        );
    }
    match config::parse_custom_options(&set("DHCP_PROXY_CUSTOM_OPTIONS").replace(';', "\n")) {
        Ok(stored) => {
            for entry in stored.split(';').filter(|e| !e.is_empty()) {
                let line = format!("dhcp-option-pxe={}", entry.replacen(':', ",", 1));
                dnsmasq_line(&mut conf, "DHCP_PROXY_CUSTOM_OPTIONS", &[], line);
            }
        }
        Err(e) => log_err(&format!(
            "WARNING: DHCP_PROXY_CUSTOM_OPTIONS not rendered: {e}"
        )),
    }
    let pxe = set("DHCP_PROXY_PXE_BOOT_SERVER");
    let bios = set("DHCP_PROXY_PXE_BOOT_FILENAME_BIOS");
    let uefi = set("DHCP_PROXY_PXE_BOOT_FILENAME_UEFI");
    if pxe.is_empty() || (bios.is_empty() && uefi.is_empty()) {
        return conf;
    }
    let mut lines = String::new();
    if !bios.is_empty() {
        lines.push_str(&format!(
            "pxe-service=x86PC,\"lancache-ng PXE boot (BIOS)\",{bios},{pxe}\n\
             dhcp-match=set:lancache-pxe-bios,option:client-arch,0\n\
             dhcp-boot=tag:lancache-pxe-bios,{bios},,{pxe}\n"
        ));
    }
    if !uefi.is_empty() {
        lines.push_str(&format!(
            "dhcp-match=set:lancache-pxe-uefi,option:client-arch,7\n\
             dhcp-match=set:lancache-pxe-uefi,option:client-arch,11\n\
             dhcp-boot=tag:lancache-pxe-uefi,{uefi},,{pxe}\n"
        ));
    }
    // What: inert pxe-service when BIOS is not set.
    // Why: dnsmasq needs one pxe-service to reply.
    // From: Issue #1683 | PR #1912
    if bios.is_empty() {
        lines.push_str("pxe-service=IA64_EFI,\"lancache-ng PXE proxy active\",0\n");
    }
    let key = "DHCP_PROXY_PXE_BOOT_SERVER";
    dnsmasq_line(
        &mut conf,
        key,
        &[&pxe, &bios, &uefi],
        lines.trim_end().to_string(),
    );
    conf
}

// What: dnsmasq proxy or relay on its checked config.
// Why: a saved ui setting restarts it with the new file.
// From: Issue #1683 | PR #1912
fn dnsmasq(ctx: &Ctx, relay: bool) -> Result<Run, String> {
    let set = |key: &str| ctx.setting(key).unwrap_or_default();
    let log_dhcp = ctx
        .setting("LOGGING_DHCP_ENABLED")
        .as_deref()
        .and_then(config::parse_bool)
        .ok_or("LOGGING_DHCP_ENABLED must be a boolean")?;
    let body = dnsmasq_conf(&set, relay, log_dhcp);
    let path = ctx.run_dir.join("dnsmasq.conf");
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DHCP_CONFIG_SNAPSHOT_DIR")?),
        ctx.need("DHCP_CONFIG_SNAPSHOT_FILE")?,
        "dnsmasq",
    );
    let check = [
        "dnsmasq".into(),
        "--test".into(),
        "-C".into(),
        path.display().to_string(),
    ];
    checked_files(
        &[(path.clone(), body)],
        &check,
        &store,
        &|old| old.to_string(),
        &no_backfill,
        true,
    )?;
    Ok(Run {
        argv: vec![
            "dnsmasq".into(),
            "-k".into(),
            "-C".into(),
            path.display().to_string(),
        ],
        watch: ctx.settings_file.iter().cloned().collect(),
        ..Run::default()
    })
}

// What: the ICANN part of the public suffix list.
// Why: one wildcard cert per registrable CDN domain.
// From: Issue #1683
#[derive(Default)]
struct Psl {
    rules: HashSet<String>,
    wildcards: HashSet<String>,
    exceptions: HashSet<String>,
}

impl Psl {
    // What: rules up to the private section, by kind.
    // Why: a private CDN suffix must not split a platform.
    // From: Issue #1683 | PR #1912
    fn parse(text: &str) -> Self {
        let mut psl = Self::default();
        for line in text.lines().map(str::trim) {
            if line == "// ===BEGIN PRIVATE DOMAINS===" {
                break;
            }
            if line.is_empty() || line.starts_with("//") {
                continue;
            }
            if let Some(rule) = line.strip_prefix('!') {
                psl.exceptions.insert(rule.to_string());
            } else if let Some(rule) = line.strip_prefix("*.") {
                psl.wildcards.insert(rule.to_string());
            } else {
                psl.rules.insert(line.to_string());
            }
        }
        psl
    }

    // What: the public suffix plus one label.
    // Why: None when the name is itself a public suffix.
    // From: Issue #1683 | PR #1912
    fn root(&self, domain: &str) -> Option<String> {
        let labels: Vec<&str> = domain.split('.').collect();
        let n = labels.len();
        let tail = |k: usize| labels[n - k..].join(".");
        let mut suffix = 0;
        for k in (1..=n).rev() {
            if self.exceptions.contains(&tail(k)) {
                suffix = k - 1;
                break;
            }
            if self.rules.contains(&tail(k)) || (k >= 2 && self.wildcards.contains(&tail(k - 1))) {
                suffix = k;
                break;
            }
        }
        let root = suffix.max(1) + 1;
        (root <= n).then(|| tail(root))
    }
}

// What: the names the proxy maps, certifies and allows.
// Why: maps, certificates and ACLs cover one host set.
// From: Issue #1683
#[derive(Debug, Default, PartialEq)]
struct CdnHosts {
    // What: registrable roots; root and *.root.
    // Why: the cert, allow and stream maps start from them.
    // From: Issue #1683 | PR #1912
    roots: Vec<String>,
    // What: wildcard-only rows below a root; *.base.
    // Why: one wildcard cert covers every host below.
    // From: Issue #1683 | PR #1912
    bases: Vec<String>,
    // What: exact rows two or more labels below a root.
    // Why: a wildcard cannot cover them; each gets a cert.
    // From: Issue #1683 | PR #1912
    exact: Vec<String>,
    // What: roots that are themselves a wildcard-only row.
    // Why: the https dispatch treats them like a base.
    // From: Issue #1683 | PR #1912
    root_wildcards: HashSet<String>,
    // What: true when a row was invalid or had no root.
    // Why: a skipped row blocks the known-good save.
    // From: Issue #1683 | PR #1912
    skipped: bool,
}

// What: append a name once, keeping the file order.
// Why: maps and certificates list each name once.
// From: Issue #1683 | PR #1912
fn push_new(list: &mut Vec<String>, name: &str) {
    if !list.iter().any(|known| known == name) {
        list.push(name.to_string());
    }
}

// What: sort cdn-domains rows into the proxy host set.
// Why: one level below a root is covered by *.root.
// From: Issue #1683
fn cdn_hosts(domains: &str, psl: &Psl) -> CdnHosts {
    let (rows, invalid) = cdn_rows(domains);
    let mut hosts = CdnHosts {
        skipped: !invalid.is_empty(),
        ..CdnHosts::default()
    };
    for row in invalid {
        log_err(&format!("WARNING: skipping invalid domain entry {row:?}"));
    }
    for (name, wildcard) in rows {
        let Some(root) = psl.root(&name) else {
            log_err(&format!("WARNING: no registrable root for {name}"));
            hosts.skipped = true;
            continue;
        };
        push_new(&mut hosts.roots, &root);
        if wildcard && name == root {
            hosts.root_wildcards.insert(root);
        } else if wildcard {
            push_new(&mut hosts.bases, &name);
        } else if name != root && name.split_once('.').map(|(_, rest)| rest) != Some(&root) {
            push_new(&mut hosts.exact, &name);
        }
    }
    hosts
}

// What: a bounded certificate file name for one host.
// Why: deep names would exceed file name limits.
// From: Issue #1683
fn cert_name(host: &str, kind: &str) -> String {
    sha256_hex(&format!("{kind}:{host}"))[..32].to_string()
}

impl CdnHosts {
    // What: (hostnames key, certificate name) pairs.
    // Why: the cert, allow and stream maps share the keys.
    // From: Issue #1683 | PR #1912
    fn keys(&self) -> Vec<(String, String)> {
        let mut keys = Vec::new();
        for root in &self.roots {
            keys.push((format!("*.{root}"), root.clone()));
            keys.push((root.clone(), root.clone()));
        }
        for base in &self.bases {
            keys.push((format!("*.{base}"), cert_name(base, "wildcard")));
        }
        for host in &self.exact {
            keys.push((host.clone(), cert_name(host, "exact")));
        }
        keys
    }
}

// What: first line of every generated nginx file.
// Why: an operator must not hand-edit a rendered file.
// From: Issue #1683 | PR #1912
const NGINX_GENERATED: &str = "# Generated by lancache-watchdog; do not edit\n";

// What: the sink for SNI-less or refused TLS clients.
// Why: the discard port closes the connection at once.
// From: Issue #1683 | PR #1912
fn nginx_refuse(loopback: &str) -> String {
    format!("{loopback}:{NGINX_DISCARD_PORT}")
}

// What: the discard service port (RFC 863).
// Why: the protocol fixes it; it is no deployment value.
// From: Issue #1683 | PR #1912
const NGINX_DISCARD_PORT: u16 = 9;

// What: the CDN origin's HTTPS port that passthrough uses.
// Why: the protocol fixes it; it is no deployment value.
// From: Issue #1683 | PR #1858
const NGINX_ORIGIN_PASS: &str = "$ssl_preread_server_name:443";

// What: loopback ports and relay timeouts of https.
// Why: the SOT owns them; dispatch and listens use them.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy, Default)]
struct NginxPorts {
    mitm: u16,
    mitm_relay: u16,
    passthrough_relay: u16,
    passthrough: u16,
    https: u16,
    connect_secs: u64,
    idle_secs: u64,
}

impl NginxPorts {
    fn from_env() -> Result<Self, String> {
        let secs = |key: &'static str| need_secs(&config::process_env, key).map(|d| d.as_secs());
        Ok(Self {
            mitm: env_port("NGINX_MITM_PORT")?,
            mitm_relay: env_port("NGINX_MITM_RELAY_PORT")?,
            passthrough_relay: env_port("NGINX_PASSTHROUGH_RELAY_PORT")?,
            passthrough: env_port("NGINX_PASSTHROUGH_PORT")?,
            https: env_port("PROXY_HTTPS_PORT")?,
            connect_secs: secs("NGINX_UPSTREAM_CONNECT_TIMEOUT")?,
            idle_secs: secs("NGINX_UPSTREAM_IDLE_TIMEOUT")?,
        })
    }
}

// What: NGINX_DIR paths of the rendered nginx files.
// Why: render, dir setup and backfill name the same files.
// From: Issue #1683 | PR #1912
const NGINX_STREAM_TARGETS: &str = "stream.d/00-stream-targets.conf";
const NGINX_HTTPS_DISPATCH: &str = "stream.d/01-https-dispatch.conf";
const NGINX_HTTPS_MAP: &str = "conf.d/00-https-map.conf";
const NGINX_CLIENT_ACL: &str = "stream.d/access.d/00-stream-client-acl.conf";

// What: the CA dir: NGINX_DIR joined with NGINX_SUBDIR_CA.
// Why: one owner for the signer and the health probe.
// From: Issue #1683 | PR #1912
fn nginx_ca_dir() -> Result<PathBuf, String> {
    let need = |key: &str| config::need(&config::process_env, key);
    Ok(Path::new(&need("NGINX_DIR")?).join(need("NGINX_SUBDIR_CA")?))
}

// What: CA and leaf certificate values.
// Why: the SOT owns each value; Rust names only keys.
// From: Issue #1683 | PR #1912
struct CertKnobs {
    ca_cert_file: String,
    ca_key_file: String,
    ca_serial_file: String,
    ca_subject: String,
    ca_key_type: String,
    ca_days: String,
    leaf_key_type: String,
    leaf_subject: String,
    leaf_days: String,
    default_cert_name: String,
    default_cert_dns: String,
}

impl CertKnobs {
    // What: every certificate value from the env.
    // Why: a missing or junk value stops the render.
    // From: Issue #1683 | PR #1912
    fn load() -> Result<Self, String> {
        let text = |key: &str| config::need(&config::process_env, key);
        let days = |key| bounded(key, 1, u32::MAX.into()).map(|d| d.to_string());
        Ok(Self {
            ca_cert_file: text("CA_CERT_FILE")?,
            ca_key_file: text("CA_KEY_FILE")?,
            ca_serial_file: text("CA_SERIAL_FILE")?,
            ca_subject: text("CA_SUBJECT")?,
            ca_key_type: text("CA_KEY_TYPE")?,
            ca_days: days("CA_DAYS")?,
            leaf_key_type: text("LEAF_KEY_TYPE")?,
            leaf_subject: text("LEAF_SUBJECT")?,
            leaf_days: days("LEAF_DAYS")?,
            default_cert_name: text("DEFAULT_CERT_NAME")?,
            default_cert_dns: text("DEFAULT_CERT_DNS")?,
        })
    }
}

// What: one aligned "key value;" map line.
// Why: rendered maps stay readable for operators.
// From: Issue #1683 | PR #1912
fn map_line(key: &str, value: &str) -> String {
    format!("    {key:<45} {value};\n")
}

// What: cert map, host allow map and client geo.
// Why: strict allows only listed hosts; CIDRs gate all.
// From: Issue #1683
fn nginx_https_map(hosts: &CdnHosts, strict: bool, cidrs: &[String], default_cert: &str) -> String {
    let keys = hosts.keys();
    let mut out =
        format!("{NGINX_GENERATED}map $ssl_server_name $https_cert_name {{\n    hostnames;\n");
    for (key, cert) in &keys {
        out.push_str(&map_line(key, cert));
    }
    out.push_str(&format!(
        "    default {default_cert};\n}}\n\nmap $host $cdn_host_allowed {{\n    hostnames;\n"
    ));
    if strict {
        out.push_str("    default 0;\n");
        for (key, _) in &keys {
            out.push_str(&map_line(key, "1"));
        }
    } else {
        out.push_str("    default 1;\n");
    }
    out.push_str("}\n\ngeo $lancache_client_allowed {\n");
    if cidrs.is_empty() {
        out.push_str("    default 1;\n");
    } else {
        out.push_str("    default 0;\n");
        for cidr in cidrs {
            out.push_str(&map_line(cidr, "1"));
        }
    }
    out.push_str("}\n");
    out
}

// What: the two relay timeout lines of a stream server.
// Why: all stream servers share one source for the values.
// From: Issue #1683 | PR #1912
fn nginx_relay_timeouts(ports: NginxPorts) -> String {
    format!(
        "    proxy_connect_timeout {}s;\n    proxy_timeout        {}s;\n",
        ports.connect_secs, ports.idle_secs
    )
}

// What: the SNI passthrough backend map and its server.
// Why: lazy forwards any SNI; strict only listed hosts.
// From: Issue #1683
fn nginx_stream_targets(
    hosts: &CdnHosts,
    strict: bool,
    loopback: &str,
    acl: &Path,
    ports: NginxPorts,
) -> String {
    let pass = NGINX_ORIGIN_PASS;
    let refuse = nginx_refuse(loopback);
    let mut out = format!(
        "{NGINX_GENERATED}map $ssl_preread_server_name $stream_backend {{\n    hostnames;\n{}",
        map_line("\"\"", &refuse)
    );
    if strict {
        out.push_str(&format!("    default {refuse};\n"));
        for (key, _) in hosts.keys() {
            out.push_str(&map_line(&key, pass));
        }
    } else {
        out.push_str(&format!("    default {pass};\n"));
    }
    out.push_str("}\n");
    // What: the SNI passthrough server on the public port.
    // Why: one owner renders every stream server.
    // From: Issue #1683 | PR #1912
    let (port, acl) = (ports.passthrough, acl.display());
    out.push_str(&format!(
        "\nserver {{\n    listen {port};\n    listen [::]:{port};\n    include {acl};\n    \
         ssl_preread on;\n    proxy_pass $stream_backend;\n{}}}\n",
        nginx_relay_timeouts(ports)
    ));
    out
}

// What: stream allow lines; empty CIDRs allow all.
// Why: the http geo cannot gate stream listeners.
// From: Issue #1683
fn nginx_client_acl(cidrs: &[String]) -> String {
    let mut out = NGINX_GENERATED.to_string();
    if !cidrs.is_empty() {
        for cidr in cidrs {
            out.push_str(&format!("allow {cidr};\n"));
        }
        out.push_str("deny all;\n");
    }
    out
}

// What: the port of a loopback health URL.
// Why: the URL stays the one value; nginx listens on it.
// From: Issue #1683 | PR #1912
fn url_port(url: &str) -> Result<u16, String> {
    url.rsplit_once(':')
        .and_then(|(_, rest)| rest.split('/').next()?.parse().ok())
        .ok_or_else(|| format!("{url} names no port"))
}

// What: the two loopback listens of the https server.
// Why: ports come from the SOT; nginx.conf has no env.
// From: Issue #1683 | PR #1912
fn nginx_https_listen(loopback: &str, mitm_port: u16, health_port: u16) -> String {
    format!(
        "{NGINX_GENERATED}listen {loopback}:{mitm_port} ssl proxy_protocol default_server;\n\
         listen {loopback}:{health_port} ssl;\n"
    )
}

// What: the HTTPS port dispatcher: MITM, relay, refuse.
// Why: a cert covers one label; deeper names pass through.
// From: Issue #1683 | PR #1912
fn nginx_https_dispatch(
    hosts: &CdnHosts,
    strict: bool,
    acl: &Path,
    ports: NginxPorts,
    loopback: &str,
) -> String {
    let refuse = nginx_refuse(loopback);
    let mitm = format!("{loopback}:{}", ports.mitm_relay);
    let passthrough = format!("{loopback}:{}", ports.passthrough_relay);
    let escape = |name: &str| name.replace('.', "\\.");
    let one_level = |name: &str| format!("\"~^[^.]+\\.{}$\"", escape(name));
    let mut bases: Vec<&String> = hosts
        .bases
        .iter()
        .chain(
            hosts
                .roots
                .iter()
                .filter(|r| hosts.root_wildcards.contains(*r)),
        )
        .collect();
    bases.sort_by(|a, b| b.len().cmp(&a.len()).then(b.cmp(a)));
    let mut out = format!(
        "{NGINX_GENERATED}map $ssl_preread_server_name $https_dispatch_backend {{\n{}",
        map_line("\"\"", &refuse)
    );
    for root in &hosts.roots {
        out.push_str(&map_line(root, &mitm));
        if !hosts.root_wildcards.contains(root) {
            out.push_str(&map_line(&one_level(root), &mitm));
        }
    }
    for host in &hosts.exact {
        out.push_str(&map_line(host, &mitm));
    }
    for base in bases {
        out.push_str(&map_line(&one_level(base), &mitm));
        out.push_str(&map_line(
            &format!("\"~^.+\\.{}$\"", escape(base)),
            &passthrough,
        ));
    }
    let default = if strict {
        refuse.as_str()
    } else {
        passthrough.as_str()
    };
    // What: locals feed the template as plain captures.
    // Why: CodeQL misses captures beside named args.
    // From: Issue #1683 | PR #1912
    let (acl, mitm_port, https) = (acl.display(), ports.mitm, ports.https);
    let timeouts = nginx_relay_timeouts(ports);
    out.push_str(&format!(
        "    default {default};\n}}\n\n\
         server {{\n    listen {https};\n    listen [::]:{https};\n    include {acl};\n    \
         ssl_preread on;\n    proxy_pass $https_dispatch_backend;\n    proxy_protocol on;\n\
         {timeouts}}}\n\n\
         server {{\n    listen {mitm} proxy_protocol;\n    set_real_ip_from {loopback};\n    \
         proxy_protocol on;\n    proxy_pass {loopback}:{mitm_port};\n\
         {timeouts}}}\n\n\
         server {{\n    listen {passthrough} proxy_protocol;\n    set_real_ip_from {loopback};\n    \
         ssl_preread on;\n    proxy_pass {NGINX_ORIGIN_PASS};\n\
         {timeouts}}}\n"
    ));
    out
}

// What: replace each ${KEY} of a template with its value.
// Why: the image templates name .env values; one filler.
// From: Issue #1683
fn fill(template: &str, values: &[(&str, String)]) -> String {
    values
        .iter()
        .fold(template.to_string(), |text, (key, value)| {
            text.replace(&format!("${{{key}}}"), value)
        })
}

// What: a resolver token without brackets or port.
// Why: nginx takes [v6] and ip:port; compare bare IPs.
// From: Issue #1683 | PR #1912
fn resolver_host(token: &str) -> &str {
    if let Some(rest) = token.strip_prefix('[') {
        rest.split(']').next().unwrap_or(rest)
    } else if token.matches(':').count() == 1 {
        token.split(':').next().unwrap_or(token)
    } else {
        token
    }
}

// What: true for an IP that LanCache DNS answers on.
// Why: nginx and recursor upstreams there would loop.
// From: Issue #1918 | PR #1858
fn is_lancache_ip(host: &str) -> bool {
    let parsed = host.parse::<std::net::IpAddr>().ok();
    let same = |own: String| match (own.parse::<std::net::IpAddr>().ok(), parsed) {
        (Some(own), Some(host)) => own == host,
        _ => own == host,
    };
    ["IP_HTTP", "IP_HTTPS", "LISTEN_IP", "LISTEN_IP_HTTPS"]
        .into_iter()
        .filter_map(env_opt)
        .any(same)
}

// What: the numeric id of a passwd or group entry.
// Why: chown takes ids; the image names user and group.
// From: Issue #1683
fn account_id(db: &str, name: &str) -> Result<u32, String> {
    let path = format!("/etc/{db}");
    let text = fs::read_to_string(&path).map_err(|e| format!("cannot read {path}: {e}"))?;
    text.lines()
        .map(|line| line.split(':').collect::<Vec<_>>())
        .find(|fields| fields.first() == Some(&name))
        .and_then(|fields| fields.get(2)?.parse().ok())
        .ok_or_else(|| format!("{name} is not in {path}"))
}

// What: sign one leaf certificate with the stack CA.
// Why: the proxy presents it for an intercepted host.
// From: Issue #1683
fn sign_leaf(
    ca: &Path,
    run: &Path,
    (key, crt): (&Path, &Path),
    san: &str,
    cert: &CertKnobs,
) -> Result<(), String> {
    let (csr, ext) = (run.join("leaf.csr"), run.join("leaf.ext"));
    let (ca_crt, ca_key, serial) = (
        ca.join(&cert.ca_cert_file),
        ca.join(&cert.ca_key_file),
        ca.join(&cert.ca_serial_file),
    );
    let signed = openssl_leaf(
        &CaFiles {
            crt: &ca_crt,
            key: &ca_key,
            serial: &serial,
        },
        (key, crt),
        (&csr, &ext),
        san,
        &CertSpec {
            key_type: &cert.leaf_key_type,
            subject: &cert.leaf_subject,
            days: &cert.leaf_days,
        },
    );
    // What: drop temp and failed files; log what stays.
    // Why: a failed sign must not leave a half key pair.
    // From: Issue #1683 | PR #1912
    let mut leftovers = vec![csr.as_path(), ext.as_path()];
    if signed.is_err() {
        leftovers.extend([key, crt]);
    }
    for file in leftovers {
        if let Err(e) = fs::remove_file(file)
            && e.kind() != io::ErrorKind::NotFound
        {
            log_err(&format!("WARNING: {} not removed: {e}", file.display()));
        }
    }
    signed
}

// What: drop the nginx package's stock default.conf.
// Why: conf.d/*.conf would serve its page beside ours.
// From: Issue #1683 | PR #1912
fn remove_stock_server(nginx: &Path) -> Result<(), String> {
    let stock = nginx.join("conf.d/default.conf");
    match fs::remove_file(&stock) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            Err(format!("cannot remove {}: {e}", stock.display()))
        }
        _ => Ok(()),
    }
}

// What: CA, default and per-host leaf certificates.
// Why: HTTPS mode intercepts TLS for every proxied host.
// From: Issue #1683
fn nginx_certs(
    ca: &Path,
    certs: &Path,
    run: &Path,
    hosts: &CdnHosts,
    ip_https: &str,
    gid: u32,
    cert: &CertKnobs,
) -> Result<(), String> {
    let (ca_crt, ca_key) = (ca.join(&cert.ca_cert_file), ca.join(&cert.ca_key_file));
    let path = |p: &Path| p.display().to_string();
    // What: make a CA only when its files are absent.
    // Why: a stat fault must not replace the clients' CA.
    // From: Issue #1683 | PR #1912
    if !(file_present(&ca_crt)? && file_present(&ca_key)?) {
        fs::create_dir_all(ca).map_err(|e| format!("cannot create {}: {e}", ca.display()))?;
        openssl_ca(
            &ca_key,
            &ca_crt,
            &CertSpec {
                key_type: &cert.ca_key_type,
                subject: &cert.ca_subject,
                days: &cert.ca_days,
            },
        )?;
        own(&ca_key, None, Some(0), Some(0o600)).map_err(|e| e.to_string())?;
        log(&format!(
            "ACTION REQUIRED: a new CA is in {}; every HTTPS client must install it \
             once (docs/install-ca-cert.md)",
            path(&ca_crt)
        ));
    }
    fs::create_dir_all(certs).map_err(|e| format!("cannot create {}: {e}", certs.display()))?;
    own(certs, None, Some(gid), Some(0o2750)).map_err(|e| e.to_string())?;
    // What: drop every leaf when the CA changed.
    // Why: leaves of an old CA would fail on every client.
    // From: Issue #1683 | PR #1912
    let print = openssl_x509(&ca_crt, &["-fingerprint", "-sha256"])?;
    let stamp = certs.join(".ca-fingerprint");
    // What: an unreadable stamp counts as a changed CA.
    // Why: new leaves are safe; the read error is logged.
    // From: Issue #1683 | PR #1912
    let stamped = match fs::read_to_string(&stamp) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => {
            log_err(&format!("WARNING: cannot read {}: {e}", stamp.display()));
            None
        }
    };
    if stamped.as_deref() != Some(print.as_str()) {
        for entry in
            fs::read_dir(certs).map_err(|e| format!("cannot list {}: {e}", certs.display()))?
        {
            let file = entry.map_err(|e| e.to_string())?.path();
            if matches!(
                file.extension().and_then(|x| x.to_str()),
                Some("crt" | "key")
            ) {
                fs::remove_file(&file)
                    .map_err(|e| format!("cannot remove {}: {e}", file.display()))?;
            }
        }
        write_file(&stamp, print.as_bytes(), 0o644, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", stamp.display()))?;
    }
    let serial = ca.join(&cert.ca_serial_file);
    // What: start a serial file only when it is absent.
    // Why: a stat fault must not reset the serial count.
    // From: Issue #1683 | PR #1912
    if !file_present(&serial)? {
        let nanos = unix_nanos();
        write_file(
            &serial,
            format!("{nanos:016x}\n").as_bytes(),
            0o600,
            Place::Replace,
        )
        .map_err(|e| format!("cannot write {}: {e}", serial.display()))?;
    }
    let default_key = certs.join(format!("{}.key", cert.default_cert_name));
    let default_crt = certs.join(format!("{}.crt", cert.default_cert_name));
    // What: no readable default cert means no SAN rows.
    // Why: a missing or broken cert is signed again below.
    // From: Issue #1683 | PR #1912
    let san = openssl_x509(&default_crt, &["-ext", "subjectAltName"]).unwrap_or_else(|e| {
        if !matches!(metadata_if_present(&default_crt), Ok(None)) {
            log_err(&format!(
                "WARNING: default cert not read, signed again: {e}"
            ));
        }
        String::new()
    });
    let has_ip = ip_https.is_empty()
        || san
            .split([',', '\n'])
            .any(|entry| entry.trim() == format!("IP Address:{ip_https}"));
    if !file_present(&default_key)? || !san.contains("DNS:") || !has_ip {
        let mut names = format!("DNS:{}", cert.default_cert_dns);
        if !ip_https.is_empty() {
            names.push_str(&format!(",IP:{ip_https}"));
        }
        sign_leaf(ca, run, (&default_key, &default_crt), &names, cert)?;
    }
    let leaves = hosts
        .roots
        .iter()
        .map(|root| (root.clone(), format!("DNS:{root},DNS:*.{root}")))
        .chain(
            hosts
                .bases
                .iter()
                .map(|base| (cert_name(base, "wildcard"), format!("DNS:*.{base}"))),
        )
        .chain(
            hosts
                .exact
                .iter()
                .map(|host| (cert_name(host, "exact"), format!("DNS:{host}"))),
        );
    for (file, names) in leaves {
        let (key, crt) = (
            certs.join(format!("{file}.key")),
            certs.join(format!("{file}.crt")),
        );
        if !(file_present(&key)? && file_present(&crt)?) {
            log(&format!("Generating certificate {file} for {names}"));
            sign_leaf(ca, run, (&key, &crt), &names, cert)?;
        }
    }
    for entry in fs::read_dir(certs).map_err(|e| format!("cannot list {}: {e}", certs.display()))? {
        let file = entry.map_err(|e| e.to_string())?.path();
        match file.extension().and_then(|x| x.to_str()) {
            Some("key") => own(&file, None, Some(gid), Some(0o640)).map_err(|e| e.to_string())?,
            Some("crt") => own(&file, None, Some(gid), Some(0o644)).map_err(|e| e.to_string())?,
            _ => {}
        }
    }
    Ok(())
}

// What: render, certify, check and start nginx.
// Why: a domain edit re-renders and restarts nginx.
// From: Issue #1683
fn nginx(ctx: &Ctx) -> Result<Run, String> {
    let cert = CertKnobs::load()?;
    let dir = PathBuf::from(ctx.need("NGINX_DIR")?);
    let domains_file = PathBuf::from(ctx.need("CDN_DOMAINS_FILE")?);
    let read = |path: &Path| {
        fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))
    };
    // What: IP_HTTP must be set for the loop check below.
    // Why: an unset IP would let a LanCache resolver pass.
    // From: Issue #1918 | PR #1858
    ctx.need("IP_HTTP")?;
    let ip_https = env_opt("IP_HTTPS").unwrap_or_default();
    let https_on =
        config::parse_bool(&ctx.need("HTTPS_ENABLED")?).ok_or("HTTPS_ENABLED is no boolean")?;
    let resolver = ctx.need("NGINX_UPSTREAM_RESOLVER")?;
    // What: the upstream resolver must not be LanCache.
    // Why: the LanCache DNS would loop back.
    // From: Issue #1683 | PR #1912
    for token in resolver.split_whitespace().map(resolver_host) {
        if is_lancache_ip(token) {
            return Err(format!(
                "NGINX_UPSTREAM_RESOLVER must not point to a LanCache IP ({token})"
            ));
        }
    }
    let strict = match ctx.need("PROXY_SECURITY_MODE")?.as_str() {
        "strict" => true,
        "lazy" => false,
        other => {
            return Err(format!(
                "PROXY_SECURITY_MODE must be lazy or strict, not {other}"
            ));
        }
    };
    let cidrs: Vec<String> = env_opt("PROXY_ALLOWED_CLIENT_CIDRS")
        .unwrap_or_default()
        .split_whitespace()
        .map(String::from)
        .collect();
    let template = read(&dir.join("nginx.conf.template"))?;
    let worker = template
        .lines()
        .find_map(|line| line.trim().strip_prefix("user ")?.strip_suffix(';'))
        .ok_or("nginx.conf.template names no worker user")?
        .trim()
        .to_string();
    let worker_gid = account_id("group", &worker)?;
    let hosts = cdn_hosts(
        &read(&domains_file)?,
        &Psl::parse(&read(&dir.join("public_suffix_list.dat"))?),
    );
    let https = dir.join("conf.d/https.conf");
    let listen_file = ctx.need("NGINX_HTTPS_LISTEN_FILE")?;
    let healthz_file = ctx.need("NGINX_HEALTHZ_FILE")?;
    let ca_dir = nginx_ca_dir()?;
    let subdir = ctx.need("NGINX_SUBDIR_CERTS")?;
    let cert_dir = dir.join(&subdir);
    if https_on {
        if ip_https.is_empty() {
            return Err("HTTPS_ENABLED needs IP_HTTPS".into());
        }
        nginx_certs(
            &ca_dir,
            &cert_dir,
            &ctx.run_dir,
            &hosts,
            &ip_https,
            worker_gid,
            &cert,
        )?;
    } else {
        // What: remove stale https.conf if there.
        // Why: a stat error must not keep HTTPS mode on.
        // From: Issue #1683 | PR #1912
        match fs::remove_file(&https) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => {
                return Err(format!("cannot remove {}: {e}", https.display()));
            }
            _ => {}
        }
    }
    for file in [NGINX_HTTPS_MAP, NGINX_CLIENT_ACL] {
        let sub = dir.join(file);
        let sub = sub.parent().unwrap_or(&dir);
        fs::create_dir_all(sub).map_err(|e| format!("cannot create {}: {e}", sub.display()))?;
    }
    remove_stock_server(&dir)?;
    // What: render the server confs from image templates.
    // Why: the paths come from the SOT, not from the text.
    // From: Issue #1683 | PR #1912
    let loopback = config::loopback()?;
    let server_values = [
        ("NGINX_DIR", dir.display().to_string()),
        ("NGINX_SUBDIR_CERTS", subdir.clone()),
        ("NGINX_HTTPS_LISTEN_FILE", listen_file.clone()),
        ("NGINX_HEALTHZ_FILE", healthz_file.clone()),
        ("PROXY_HEALTH_PATH", ctx.need("PROXY_HEALTH_PATH")?),
        ("PROXY_STATUS_PATH", ctx.need("PROXY_STATUS_PATH")?),
        ("PROXY_HTTP_PORT", env_port("PROXY_HTTP_PORT")?.to_string()),
        ("DOCKER_BRIDGE_NET", ctx.need("DOCKER_BRIDGE_NET")?),
        ("LOOPBACK_BIND_IP", loopback.clone()),
    ];
    for (template, out, on) in [
        ("http.conf.template", dir.join("conf.d/http.conf"), true),
        ("https.conf.template", https.clone(), https_on),
    ] {
        if !on {
            continue;
        }
        let text = fill(&read(&dir.join(template))?, &server_values);
        write_file(&out, text.as_bytes(), 0o640, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", out.display()))?;
    }
    let healthz = dir.join(&healthz_file);
    write_file(&healthz, b"ok\n", 0o644, Place::Replace)
        .map_err(|e| format!("cannot write {}: {e}", healthz.display()))?;
    let value = |key: &'static str| ctx.need(key).map(|v| (key, v));
    let acl = dir.join(NGINX_CLIENT_ACL);
    let conf = dir.join("nginx.conf");
    let ports = NginxPorts::from_env()?;
    let health_port = if https_on {
        url_port(&ctx.need("PROXY_HEALTH_HTTPS_URL")?)?
    } else {
        0
    };
    // What: the https listen file text.
    // Why: a rolled-back old set still needs the listener.
    // From: Issue #1683 | PR #1912
    let listen = if https_on {
        nginx_https_listen(&loopback, ports.mitm, health_port)
    } else {
        NGINX_GENERATED.to_string()
    };
    // What: proxy-params values: server plus cache keys.
    // Why: its nested /healthz names the server keys.
    // From: Issue #1683 | PR #1858
    let mut params = server_values.to_vec();
    params.extend([
        value("CACHE_SLICE_SIZE")?,
        value("CACHE_VALID_HIT")?,
        value("CACHE_VALID_ANY")?,
        value("NGINX_UPSTREAM_CONNECT_TIMEOUT")?,
        value("NGINX_UPSTREAM_IDLE_TIMEOUT")?,
        value("NGINX_CACHE_LOCK_TIMEOUT")?,
        value("NGINX_SSL_VERIFY_DEPTH")?,
        value("NGINX_MAX_TEMP_FILE_SIZE")?,
        value("NGINX_TEMP_FILE_WRITE_SIZE")?,
    ]);
    let files = vec![
        (
            conf.clone(),
            fill(
                &template,
                &[
                    value("CACHE_MEM_MB")?,
                    value("CACHE_MAX_SIZE")?,
                    value("CACHE_MIN_FREE")?,
                    value("CACHE_INACTIVE")?,
                    ("NGINX_UPSTREAM_RESOLVER", resolver),
                    ("NGINX_DIR", dir.display().to_string()),
                    ("NGINX_CACHE_DIR", ctx.need("NGINX_CACHE_DIR")?),
                ],
            ),
        ),
        (
            dir.join("proxy-params.conf"),
            fill(&read(&dir.join("proxy-params.conf.template"))?, &params),
        ),
        (
            dir.join(NGINX_HTTPS_MAP),
            nginx_https_map(&hosts, strict, &cidrs, &cert.default_cert_name),
        ),
        (
            dir.join(NGINX_STREAM_TARGETS),
            nginx_stream_targets(&hosts, strict, &loopback, &acl, ports),
        ),
        (acl.clone(), nginx_client_acl(&cidrs)),
        (
            dir.join(NGINX_HTTPS_DISPATCH),
            if https_on {
                nginx_https_dispatch(&hosts, strict, &acl, ports, &loopback)
            } else {
                NGINX_GENERATED.to_string()
            },
        ),
        (dir.join(&listen_file), listen.clone()),
    ];
    // What: names of the files older snapshots lack.
    // Why: only a snapshot with none of them is old.
    // From: Issue #1683 | PR #1912
    let new_files: Vec<String> = [NGINX_HTTPS_MAP, NGINX_HTTPS_DISPATCH, listen_file.as_str()]
        .iter()
        .filter_map(|p| Path::new(p).file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .collect();
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("PROXY_CONFIG_SNAPSHOT_DIR")?),
        ctx.need("PROXY_CONFIG_SNAPSHOT_FILE")?,
        "proxy",
    );
    // What: backfill takes dispatch, listen from here.
    // Why: a snapshot without them gets the current files.
    // From: Issue #1683 | PR #1912
    checked_files(
        &files,
        &[
            "nginx".into(),
            "-t".into(),
            "-c".into(),
            conf.display().to_string(),
        ],
        &store,
        &|old| old.to_string(),
        &legacy_backfill(&new_files, (&new_files[0], LEGACY_PROXY_MAP), &|file| {
            files
                .iter()
                .find(|(path, _)| path.file_name().is_some_and(|n| n == file))
                .map_or_else(|| NGINX_GENERATED.to_string(), |(_, text)| text.clone())
        }),
        !hosts.skipped,
    )?;
    Ok(Run {
        argv: vec!["nginx".into(), "-g".into(), "daemon off;".into()],
        watch: vec![domains_file],
        ..Run::default()
    })
}

// What: DHCP client and server UDP ports (RFC 2131).
// Why: the protocol fixes both ports; probe is a client.
// From: Issue #1683 | PR #1912
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_SERVER_PORT: u16 = 67;

// What: DHCP probe times: offer window, ACK wait, sends.
// Why: the SOT owns each value; Rust names only keys.
// From: Issue #1683 | PR #1912
struct ProbeTiming {
    // What: how long offers are collected after a DISCOVER.
    // Why: several servers answer; first offer is not all.
    // From: Issue #1683 | PR #1912
    window: Duration,
    // What: how long the REQUEST waits for an ACK or NAK.
    // Why: a silent server must not block the probe.
    // From: Issue #1683 | PR #1912
    request_timeout: Duration,
    // What: DISCOVER sends in one window, spread evenly.
    // Why: UDP loses packets; one send may vanish.
    // From: Issue #1683 | PR #1912
    retransmits: u32,
}

impl ProbeTiming {
    // What: the probe times from the env, seconds.
    // Why: a missing or junk value makes the probe fail.
    // From: Issue #1683 | PR #1912
    fn load() -> Result<Self, String> {
        let secs = |key| bounded(key, 1, u32::MAX.into()).map(Duration::from_secs);
        Ok(Self {
            window: secs("DHCP_PROBE_WINDOW")?,
            request_timeout: secs("DHCP_PROBE_REQUEST_TIMEOUT")?,
            retransmits: bounded("DHCP_PROBE_RETRANSMITS", 1, u8::MAX.into())? as u32,
        })
    }
}

// What: option fields shown per offer, as (label, code).
// Why: None is the offered address; the rest are options.
// From: Issue #1683 | PR #1912
const OFFER_FIELDS: [(&str, Option<OptionCode>); 10] = [
    ("Server Identifier", Some(OptionCode::ServerIdentifier)),
    ("IP Offered", None),
    (
        "IP Address Lease Time (seconds)",
        Some(OptionCode::AddressLeaseTime),
    ),
    ("Renewal Time (seconds)", Some(OptionCode::Renewal)),
    ("Rebinding Time (seconds)", Some(OptionCode::Rebinding)),
    ("Subnet Mask", Some(OptionCode::SubnetMask)),
    ("Router", Some(OptionCode::Router)),
    ("Domain Name Server", Some(OptionCode::DomainNameServer)),
    ("Domain Name", Some(OptionCode::DomainName)),
    ("Broadcast Address", Some(OptionCode::BroadcastAddr)),
];

// What: what the probe keeps of one OFFER or ACK.
// Why: REQUEST needs address and server; page needs rows.
// From: Issue #1683 | PR #1912
struct Offer {
    address: Option<Ipv4Addr>,
    server: Option<Ipv4Addr>,
    details: Vec<Detail>,
}

// What: read an OFFER or ACK into address, server, rows.
// Why: both message types carry the same option set.
// From: Issue #1683 | PR #1912
fn read_offer(msg: &Message) -> Offer {
    let opts = msg.opts();
    let address = Some(msg.yiaddr()).filter(|a| !a.is_unspecified());
    let option_text = |code: OptionCode| -> Option<String> {
        Some(match opts.get(code)? {
            DhcpOption::ServerIdentifier(a)
            | DhcpOption::SubnetMask(a)
            | DhcpOption::BroadcastAddr(a) => a.to_string(),
            DhcpOption::AddressLeaseTime(s) | DhcpOption::Renewal(s) | DhcpOption::Rebinding(s) => {
                s.to_string()
            }
            DhcpOption::Router(list) => list.first()?.to_string(),
            DhcpOption::DomainNameServer(list) => list
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(", "),
            DhcpOption::DomainName(name) => name.clone(),
            _ => return None,
        })
    };
    let details = OFFER_FIELDS
        .iter()
        .filter_map(|(label, code)| {
            let value = match code {
                Some(code) => option_text(*code),
                None => address.map(|a| a.to_string()),
            }?;
            (!value.is_empty()).then(|| Detail {
                label: label.to_string(),
                value,
            })
        })
        .collect();
    let server = match opts.get(OptionCode::ServerIdentifier) {
        Some(DhcpOption::ServerIdentifier(a)) => Some(*a),
        _ => None,
    };
    Offer {
        address,
        server,
        details,
    }
}

// What: true when a message has the given DHCP type.
// Why: replies of other types on the segment are ignored.
// From: Issue #1683 | PR #1912
fn is_kind(msg: &Message, kind: MessageType) -> bool {
    matches!(msg.opts().get(OptionCode::MessageType), Some(DhcpOption::MessageType(t)) if t == &kind)
}

// What: build a DHCP message of one type.
// Why: one builder for all three; flags follow the type.
// From: Issue #1683 | PR #1912
fn dhcp_message(
    xid: u32,
    chaddr: &[u8; 6],
    ciaddr: Ipv4Addr,
    kind: MessageType,
    options: Vec<DhcpOption>,
) -> Message {
    let none = Ipv4Addr::UNSPECIFIED;
    let mut msg = Message::new_with_id(xid, ciaddr, none, none, none, chaddr);
    // What: set the broadcast flag on all but the RELEASE.
    // Why: no client address, so replies must broadcast.
    // From: Issue #1683 | PR #1912
    if !matches!(kind, MessageType::Release) {
        msg.set_flags(Flags::default().set_broadcast());
    }
    msg.opts_mut().insert(DhcpOption::MessageType(kind));
    for option in options {
        msg.opts_mut().insert(option);
    }
    msg
}

// What: the options asked of every server.
// Why: exactly the fields the probe can show.
// From: Issue #1683 | PR #1912
fn request_list() -> DhcpOption {
    DhcpOption::ParameterRequestList(
        OFFER_FIELDS
            .iter()
            .filter_map(|(_, code)| *code)
            .filter(|code| !matches!(code, OptionCode::ServerIdentifier))
            .collect(),
    )
}

// What: encode and send one message.
// Why: all probe traffic goes out through this one path.
// From: Issue #1683 | PR #1912
fn send_dhcp(socket: &UdpSocket, msg: &Message, to: SocketAddrV4) -> io::Result<()> {
    let mut buffer = Vec::new();
    msg.encode(&mut Encoder::new(&mut buffer))
        .map_err(io::Error::other)?;
    socket.send_to(&buffer, to).map(|_| ())
}

// What: feed replies of one exchange to a handler.
// Why: stops at the deadline or when the handler says done.
// From: Issue #1683 | PR #1912
fn listen(
    socket: &UdpSocket,
    xid: u32,
    until: Instant,
    mut handle: impl FnMut(&Message) -> bool,
) -> io::Result<()> {
    let mut buffer = [0u8; 1500];
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(());
        }
        socket.set_read_timeout(Some(left))?;
        match socket.recv_from(&mut buffer) {
            // What: skip datagrams that are not ours.
            // Why: others share the broadcast domain.
            // From: Issue #1683 | PR #1912
            Ok((n, _)) => {
                if let Ok(msg) = Message::decode(&mut Decoder::new(&buffer[..n]))
                    && msg.xid() == xid
                    && handle(&msg)
                {
                    return Ok(());
                }
            }
            // What: a signal only restarts the wait.
            // Why: the loop recomputes the deadline.
            // From: Issue #1683 | PR #1912
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(());
            }
            Err(e) => return Err(e),
        }
    }
}

// What: REQUEST the first offer, wait for the ACK, release.
// Why: proves a client can get a lease; it is returned.
// From: Issue #1683 | PR #1912
fn dry_run(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    offer: &Offer,
    destination: SocketAddrV4,
    timeout: Duration,
) -> ClientCheck {
    let (Some(address), Some(server)) = (offer.address, offer.server) else {
        return ClientCheck::Failed {
            output: "the DHCPOFFER was missing a requested IP or server identifier, \
                     so no DHCPREQUEST could be built"
                .into(),
        };
    };
    let request = dhcp_message(
        xid,
        chaddr,
        Ipv4Addr::UNSPECIFIED,
        MessageType::Request,
        vec![
            DhcpOption::RequestedIpAddress(address),
            DhcpOption::ServerIdentifier(server),
            request_list(),
        ],
    );
    if let Err(e) = send_dhcp(socket, &request, destination) {
        return ClientCheck::Unavailable {
            reason: format!("failed to send DHCPREQUEST: {e}"),
        };
    }
    let mut verdict: Result<Offer, &str> = Err("no ACK received before the timeout");
    let heard = listen(socket, xid, Instant::now() + timeout, |msg| {
        if is_kind(msg, MessageType::Ack) {
            let ack = read_offer(msg);
            if ack.server == Some(server) {
                verdict = Ok(ack);
                return true;
            }
            verdict = Err("received an ACK, but not from the expected server identifier");
        } else if is_kind(msg, MessageType::Nak) {
            verdict = Err("server sent DHCPNAK for the requested address");
            return true;
        }
        false
    });
    if let Err(e) = heard {
        return ClientCheck::Unavailable {
            reason: format!("failed while waiting for DHCPACK: {e}"),
        };
    }
    let ack = match verdict {
        Ok(ack) => ack,
        Err(reason) => {
            return ClientCheck::Failed {
                output: reason.into(),
            };
        }
    };
    // What: return the leased address to the server's pool.
    // Why: best effort; the lease would expire on its own.
    // From: Issue #1683 | PR #1912
    if let Some(leased) = ack.address {
        let release = dhcp_message(
            rand::random(),
            chaddr,
            leased,
            MessageType::Release,
            vec![DhcpOption::ServerIdentifier(server)],
        );
        if let Err(e) = send_dhcp(
            socket,
            &release,
            SocketAddrV4::new(server, DHCP_SERVER_PORT),
        ) {
            log_err(&format!("WARNING: DHCP release to {server} not sent: {e}"));
        }
    }
    ClientCheck::Passed {
        output: match ack.address {
            Some(ip) => format!("DHCP client dry-run succeeded, assigned {ip}"),
            None => "DHCP client dry-run succeeded".into(),
        },
        details: ack.details,
    }
}

// What: one broadcast round answering both checks.
// Why: offers expose rogue servers; first one dry-runs.
// From: Issue #1683 | PR #1912
fn run_probe() -> ProbeReport {
    let timing = match ProbeTiming::load() {
        Ok(timing) => timing,
        Err(e) => return ProbeReport::unavailable(e),
    };
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, DHCP_CLIENT_PORT)).and_then(|socket| {
        socket.set_broadcast(true)?;
        Ok(socket)
    });
    let socket = match socket {
        Ok(socket) => socket,
        Err(e) => {
            return ProbeReport::unavailable(format!(
                "could not open a DHCP broadcast socket: {e}"
            ));
        }
    };
    let destination = SocketAddrV4::new(Ipv4Addr::BROADCAST, DHCP_SERVER_PORT);
    // What: one transaction id for DISCOVER and REQUEST.
    // Why: a server honours a REQUEST only for its offer.
    // From: Issue #1683 | PR #1912
    let xid: u32 = rand::random();
    // What: a random locally administered unicast MAC.
    // Why: the probe must not look like a real device.
    // From: Issue #1683 | PR #1912
    let mut chaddr: [u8; 6] = rand::random();
    chaddr[0] = (chaddr[0] | 0x02) & !0x01;

    let discover = dhcp_message(
        xid,
        &chaddr,
        Ipv4Addr::UNSPECIFIED,
        MessageType::Discover,
        vec![request_list()],
    );
    let end = Instant::now() + timing.window;
    let mut offers: Vec<Offer> = Vec::new();
    for attempt in 1..=timing.retransmits {
        if let Err(e) = send_dhcp(&socket, &discover, destination) {
            return ProbeReport::unavailable(format!("failed to broadcast DHCPDISCOVER: {e}"));
        }
        let slice = Instant::now() + timing.window / timing.retransmits;
        let until = if attempt == timing.retransmits {
            end
        } else {
            slice.min(end)
        };
        // What: a failed read ends the slice only, logged.
        // Why: later retransmits may still collect offers.
        // From: Issue #1683 | PR #1912
        let heard = listen(&socket, xid, until, |msg| {
            if is_kind(msg, MessageType::Offer) {
                let offer = read_offer(msg);
                // What: count each server once.
                // Why: answering twice is no second rogue.
                // From: Issue #1683 | PR #1912
                let seen = offers
                    .iter()
                    .any(|o| o.server.is_some() && o.server == offer.server);
                if !seen {
                    offers.push(offer);
                }
            }
            false
        });
        if let Err(e) = heard {
            log_err(&format!("WARNING: DHCP offer read {attempt} failed: {e}"));
        }
    }

    let conflict = match offers.first() {
        None => ConflictCheck::NotFound,
        Some(first) => ConflictCheck::Found {
            output: first
                .server
                .map_or_else(|| "unknown".to_string(), |ip| ip.to_string()),
            details: offers.iter().flat_map(|o| o.details.clone()).collect(),
        },
    };
    let client = match offers.first() {
        None => ClientCheck::Failed {
            output: format!(
                "no DHCPOFFER received within {:.0}s",
                timing.window.as_secs_f64()
            ),
        },
        Some(first) => dry_run(
            &socket,
            xid,
            &chaddr,
            first,
            destination,
            timing.request_timeout,
        ),
    };
    ProbeReport { conflict, client }
}

// What: answer each new probe request with one probe run.
// Why: the ui has no Docker; the dhcp container probes.
// From: Issue #947 | PR #1912
async fn probe_upkeep() -> Result<(), String> {
    let need = |key: &str| config::need(&config::process_env, key);
    let request = PathBuf::from(need("DHCP_PROBE_REQUEST_FILE")?);
    let answer = PathBuf::from(need("DHCP_PROBE_RESULT_FILE")?);
    // What: the answered id; read or parse faults logged.
    // Why: no id reruns the probe; the cause must show.
    // From: Issue #1683 | PR #1912
    let read_id = || {
        let raw = match fs::read_to_string(&answer) {
            Ok(raw) => raw,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return None,
            Err(e) => {
                log_err(&format!("WARNING: cannot read {}: {e}", answer.display()));
                return None;
            }
        };
        serde_json::from_str::<ProbeAnswer>(&raw)
            .inspect_err(|e| log_err(&format!("WARNING: {} is no answer: {e}", answer.display())))
            .ok()
            .map(|a| a.id)
    };
    let tick = bounded("SUPERVISE_TICK", 1, u32::MAX.into()).map(Duration::from_secs)?;
    let mut answered = read_id();
    loop {
        tokio::time::sleep(tick).await;
        // What: no request waits; a read fault is logged.
        // Why: a permission fault is not "no ask".
        // From: Issue #1683 | PR #1912
        let id = match fs::read_to_string(&request) {
            Ok(id) => id,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => {
                log_err(&format!("WARNING: cannot read {}: {e}", request.display()));
                continue;
            }
        };
        let id = id.trim().to_string();
        if id.is_empty() || answered.as_deref() == Some(id.as_str()) {
            continue;
        }
        let report = tokio::task::spawn_blocking(run_probe)
            .await
            .unwrap_or_else(|e| ProbeReport::unavailable(format!("the probe task failed: {e}")));
        let body = serde_json::to_vec(&ProbeAnswer {
            id: id.clone(),
            page: report.page(),
        })
        .map_err(|e| e.to_string())?;
        write_file(&answer, &body, 0o644, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", answer.display()))?;
        answered = Some(id);
    }
}

// What: one supervised slot and its restart state.
// Why: the loop converges each slot to wanted state.
// From: Issue #1683 | PR #1912
struct Slot {
    kind: Kind,
    // What: watched inputs and their state at the start.
    // Why: a differing state restarts the program.
    // From: Issue #1683 | PR #1912
    watch: Vec<PathBuf>,
    seen: Vec<Option<(u64, i64, i64)>>,
    child: Option<tokio::process::Child>,
    task: Option<tokio::task::JoinHandle<Result<(), String>>>,
    started: Option<std::time::Instant>,
    not_before: std::time::Instant,
    backoff: Duration,
    restarts: u32,
    timing: Timing,
}

impl Slot {
    // What: true while the program or task is alive.
    // Why: the status file and healthcheck report it.
    // From: Issue #1683 | PR #1912
    fn running(&self) -> bool {
        self.child.is_some() || self.task.as_ref().is_some_and(|t| !t.is_finished())
    }

    // What: start the program or task once.
    // Why: a failed start sets the backoff for next try.
    // From: Issue #1683 | PR #1912
    fn start(&mut self, ctx: &Ctx) {
        let name = self.kind.name();
        let run = match self.kind.launch(ctx) {
            Ok(run) => run,
            Err(e) => return self.failed(&format!("{name}: {e}")),
        };
        let task = match self.kind {
            Kind::Watch => Some(tokio::spawn(TAG.scope("watch", watch()))),
            Kind::Retention => Some(tokio::spawn(TAG.scope("retention", retention()))),
            Kind::Soa => Some(tokio::spawn(TAG.scope("soa", soa_upkeep()))),
            Kind::DhcpProbe => Some(tokio::spawn(TAG.scope("dhcp-probe", probe_upkeep()))),
            _ => None,
        };
        self.seen = fingerprint(&run.watch);
        self.watch = run.watch;
        if task.is_none() {
            match tokio::process::Command::new(&run.argv[0])
                .args(&run.argv[1..])
                .envs(run.env)
                .spawn()
            {
                Ok(child) => self.child = Some(child),
                Err(e) => return self.failed(&format!("{name}: cannot start: {e}")),
            }
        }
        self.task = task;
        self.started = Some(std::time::Instant::now());
        log(&format!("STARTED {name}"));
    }

    // What: log a failure and schedule the next start.
    // Why: the delay doubles up to the backoff maximum.
    // From: Issue #1683 | PR #1912
    fn failed(&mut self, why: &str) {
        log_err(&format!(
            "ERROR: {why}; next start in {}s",
            self.backoff.as_secs()
        ));
        self.not_before = std::time::Instant::now() + self.backoff;
        self.backoff = self.timing.backoff.next(self.backoff);
        self.restarts = self.restarts.saturating_add(1);
    }

    // What: notice an exited program or task.
    // Why: an exit is a failure; a long run resets backoff.
    // From: Issue #1683 | PR #1912
    async fn reap(&mut self) {
        let name = self.kind.name();
        let ran_long = self
            .started
            .is_some_and(|at| at.elapsed() >= self.timing.backoff_reset);
        let exit = if let Some(child) = &mut self.child {
            match child.try_wait() {
                Ok(Some(status)) => Some(format!("{name} exited: {status}")),
                Ok(None) => None,
                Err(e) => Some(format!("{name}: cannot read exit: {e}")),
            }
        } else if let Some(task) = self.task.take_if(|t| t.is_finished()) {
            Some(match task.await {
                Ok(Ok(())) => format!("{name} ended"),
                Ok(Err(e)) => format!("{name}: {e}"),
                Err(e) => format!("{name} panicked: {e}"),
            })
        } else {
            None
        };
        if let Some(why) = exit {
            self.child = None;
            if ran_long {
                self.backoff = self.timing.backoff.start;
            }
            self.failed(&why);
        }
    }

    // What: stop the program: TERM, wait, then KILL.
    // Why: a clean stop lets daemons flush their state.
    // From: Issue #1683 | PR #1912
    async fn stop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        let Some(mut child) = self.child.take() else {
            return;
        };
        if let Some(pid) = child.id()
            && let Err(e) = terminate(pid)
        {
            log_err(&format!("WARNING: SIGTERM to {pid}: {e}"));
        }
        if tokio::time::timeout(self.timing.stop_grace, child.wait())
            .await
            .is_err()
        {
            log_err(&format!(
                "WARNING: {} ignored TERM; killing",
                self.kind.name()
            ));
            if let Err(e) = child.kill().await {
                log_err(&format!("WARNING: cannot kill {}: {e}", self.kind.name()));
            }
        }
        log(&format!("STOPPED {}", self.kind.name()));
    }
}

// What: the supervisor's report for the healthcheck.
// Why: the healthcheck runs as its own process.
// From: Issue #1683 | PR #1912
#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
struct SuperviseStatus {
    updated: u64,
    // What: wanted programs that are not running now.
    // Why: one red entry makes the container unhealthy.
    // From: Issue #1683 | PR #1912
    down: Vec<String>,
    // What: programs running now.
    // Why: the healthcheck probes their listeners.
    // From: Issue #1683 | PR #1912
    running: Vec<String>,
    restarts: HashMap<String, u32>,
}

// What: the kinds this container runs, in order.
// Why: an unknown or doubled name fails the start.
// From: Issue #1683 | PR #1912
fn kinds(raw: &str) -> Result<Vec<Kind>, String> {
    let mut out: Vec<Kind> = Vec::new();
    for name in raw.split_whitespace() {
        let kind = Kind::from_name(name)
            .ok_or_else(|| format!("LANCACHE_PROCESSES names unknown {name:?}"))?;
        if out.contains(&kind) {
            return Err(format!("LANCACHE_PROCESSES names {name:?} twice"));
        }
        out.push(kind);
    }
    if out.is_empty() {
        return Err("LANCACHE_PROCESSES is empty".into());
    }
    Ok(out)
}

// What: keep every wanted program running until TERM.
// Why: one supervisor per container starts every program.
// From: Issue #1683
async fn supervise() -> Result<(), String> {
    use tokio::signal::unix::{SignalKind, signal};
    let need = |key: &str| config::need(&config::process_env, key);
    let kinds = kinds(&need("LANCACHE_PROCESSES")?)?;
    let timing = Timing::load()?;
    let ctx = Ctx {
        run_dir: PathBuf::from(need("SUPERVISE_RUN_DIR")?),
        settings_file: env_opt("UI_SETTINGS_FILE").map(PathBuf::from),
        desired_file: env_opt("DESIRED_STATE_FILE").map(PathBuf::from),
    };
    let status_file = ctx.run_dir.join(SUPERVISE_STATUS_FILE);
    fs::create_dir_all(&ctx.run_dir)
        .map_err(|e| format!("cannot create {}: {e}", ctx.run_dir.display()))?;
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut int = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    let now = std::time::Instant::now();
    let mut slots: Vec<Slot> = kinds
        .into_iter()
        .map(|kind| Slot {
            kind,
            watch: Vec::new(),
            seen: Vec::new(),
            child: None,
            task: None,
            started: None,
            not_before: now,
            backoff: timing.backoff.start,
            restarts: 0,
            timing,
        })
        .collect();
    let names: Vec<&str> = slots.iter().map(|s| s.kind.name()).collect();
    log(&format!("Supervisor started: {}", names.join(" ")));
    loop {
        let mut status = SuperviseStatus {
            updated: unix_secs(),
            ..SuperviseStatus::default()
        };
        for slot in &mut slots {
            slot.reap().await;
            let wanted = slot.kind.wanted(&ctx);
            if wanted && !slot.running() && std::time::Instant::now() >= slot.not_before {
                slot.start(&ctx);
            } else if slot.running() && (!wanted || fingerprint(&slot.watch) != slot.seen) {
                // What: stop on changed input or unwanted.
                // Why: a start reads its inputs anew.
                // From: Issue #1683 | PR #1912
                if wanted {
                    log(&format!("{}: input changed; restarting", slot.kind.name()));
                }
                slot.stop().await;
            }
            if wanted && !slot.running() {
                status.down.push(slot.kind.name().to_string());
            }
            if slot.running() {
                status.running.push(slot.kind.name().to_string());
            }
            status
                .restarts
                .insert(slot.kind.name().to_string(), slot.restarts);
        }
        let body = serde_json::to_vec(&status).expect("SuperviseStatus serializes");
        if let Err(e) = write_file(&status_file, &body, 0o644, Place::Replace) {
            log_err(&format!(
                "WARNING: cannot write {}: {e}",
                status_file.display()
            ));
        }
        tokio::select! {
            _ = term.recv() => break,
            _ = int.recv() => break,
            () = tokio::time::sleep(timing.tick) => {}
        }
    }
    log("TERM received; stopping all programs");
    for slot in &mut slots {
        slot.stop().await;
    }
    Ok(())
}

// What: healthy when the supervisor is fresh and all up.
// Why: Docker health then covers every program inside.
// From: Issue #1683
async fn healthcheck() -> Result<(), String> {
    let need = |key: &str| config::need(&config::process_env, key);
    let dir = need("SUPERVISE_RUN_DIR")?;
    let path = Path::new(&dir).join(SUPERVISE_STATUS_FILE);
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let status: SuperviseStatus =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let max_age = bounded("SUPERVISE_STATUS_MAX_AGE", 1, u32::MAX.into())?;
    health_verdict(&status, unix_secs(), max_age)?;
    // What: a running listener program must accept.
    // Why: running is not bound; clients use it at once.
    // From: Issue #1683 | PR #1912
    for (kind, key) in [
        (Kind::NatsSubscriber, ROLLBACK_PORT_KEY),
        (Kind::KeaCtrlAgent, "KEA_CTRL_PORT"),
    ] {
        if status.running.iter().any(|name| name == kind.name()) {
            let addr = format!("{}:{}", config::loopback()?, env_port(key)?);
            tokio::net::TcpStream::connect(&addr)
                .await
                .map_err(|e| format!("{} at {addr}: {e}", kind.name()))?;
        }
    }
    // What: kea-dhcp4 must accept on its control socket.
    // Why: the agent forwards every command through it.
    // From: Issue #1683 | PR #1912
    if status
        .running
        .iter()
        .any(|name| name == Kind::KeaDhcp4.name())
    {
        let socket = config::need(&config::process_env, KEA4_SOCKET_KEY)?;
        tokio::net::UnixStream::connect(&socket)
            .await
            .map_err(|e| format!("{} at {socket}: {e}", Kind::KeaDhcp4.name()))?;
    }
    // What: nginx must answer its health page as well.
    // Why: a running nginx process can still serve nothing.
    // From: Issue #1683 | PR #1912
    if kinds(&need("LANCACHE_PROCESSES")?)?.contains(&Kind::Nginx) {
        let https = config::need_flag(&config::process_env, "HTTPS_ENABLED")?;
        let http_url = need("PROXY_HEALTH_URL")?;
        let wait = need_secs(&config::process_env, "HEALTH_PROBE_TIMEOUT")?;
        if !https {
            return probe_health(&http_url, wait).await;
        }
        let https_url = need("PROXY_HEALTH_HTTPS_URL")?;
        let cert = CertKnobs::load()?;
        let ca_file = nginx_ca_dir()?.join(&cert.ca_cert_file);
        let ca_pem = fs::read(&ca_file).map_err(|e| format!("{}: {e}", ca_file.display()))?;
        let (http, tls) = tokio::join!(
            probe_health(&http_url, wait),
            probe_health_tls(&https_url, &ca_pem, &cert.default_cert_dns, wait)
        );
        http?;
        tls?;
    }
    Ok(())
}

// What: the verdict for one status at one time.
// Why: pure, so tests feed it any status and clock.
// From: Issue #1683 | PR #1912
fn health_verdict(status: &SuperviseStatus, now: u64, max_age: u64) -> Result<(), String> {
    let age = now.saturating_sub(status.updated);
    if age > max_age {
        return Err(format!("supervisor status is {age}s old"));
    }
    if !status.down.is_empty() {
        return Err(format!("not running: {}", status.down.join(" ")));
    }
    Ok(())
}

// What: one probe run, printed as the page JSON.
// Why: setup.sh looks for a DHCP server before Kea starts.
// From: Issue #1683 | PR #1912
fn probe_print() -> Result<(), String> {
    println!("{}", run_probe().page());
    Ok(())
}

// What: supervise (default), healthcheck, probe or get KEY.
// Why: one binary per container, four entry points.
// From: Issue #1683 | PR #1912
#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] | ["supervise"] => TAG.scope("supervise", supervise()).await,
        ["healthcheck"] => healthcheck().await,
        ["probe"] => probe_print(),
        ["get", key] => config::need(&config::process_env, key).map(|v| println!("{v}")),
        _ => Err("usage: lancache-watchdog [supervise|healthcheck|probe|get KEY]".to_string()),
    };
    if let Err(e) = result {
        log_err(&format!("FATAL: {e}"));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: syslog-ng time-reap seconds of the tests.
    // Why: the render copies it; any value does.
    // From: Issue #1683 | PR #1912
    const REAP: u64 = 7;

    // What: a fresh random number in [lo, hi].
    // Why: no fixed value in a test; each run differs.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn gen_name() -> String {
        format!("v{:x}", rnd(0, u64::MAX))
    }

    // What: deleting or packing old logs is no loss.
    // Why: only a plain-file write clears the loss alarm.
    // From: Issue #1428 | PR #1912
    #[test]
    fn newest_write_ignores_deleted_old_files() {
        let root = scratch();
        let (old, new) = (root.join(gen_name()), root.join(gen_name()));
        fs::write(&old, gen_name()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&new, gen_name()).unwrap();
        let before = newest_write(&root);
        assert!(before > 0);
        fs::remove_file(&old).unwrap();
        assert_eq!(newest_write(&root), before);
        std::thread::sleep(std::time::Duration::from_millis(20));
        let packed = root.join(format!("{}{XZ_SUFFIX}", gen_name()));
        fs::write(&packed, gen_name()).unwrap();
        assert_eq!(newest_write(&root), before);
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&new, gen_name()).unwrap();
        assert!(newest_write(&root) > before);
        assert_eq!(newest_write(&root.join(gen_name())), 0);
        fs::remove_dir_all(&root).unwrap();
    }

    // What: restart at threshold; inert reads never count.
    // Why: restarting an unreachable service is unsafe.
    // From: Issue #1683 | PR #1858
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

    // What: chronyd follows the saved flag and the dock.
    // Why: the ui is dumb; the supervisor converges NTP.
    // From: Issue #1437 | PR #1912
    #[test]
    fn chronyd_follows_the_setting_and_desired_state() {
        let root = scratch();
        let ctx = Ctx {
            run_dir: root.join(gen_name()),
            settings_file: Some(root.join(gen_name())),
            desired_file: Some(root.join(gen_name())),
        };
        let set = |on: bool, desired: &str| {
            fs::write(
                ctx.settings_file.as_ref().expect("settings path"),
                format!("NTP_ENABLED={}\n", u8::from(on)),
            )
            .expect("settings");
            fs::write(ctx.desired_file.as_ref().expect("desired path"), desired).expect("desired");
            Kind::Chronyd.wanted(&ctx)
        };
        assert!(set(true, "{}"));
        assert!(set(true, r#"{"ntp":"running"}"#));
        assert!(!set(true, r#"{"ntp":"stopped"}"#));
        assert!(!set(false, r#"{"ntp":"running"}"#));
        assert!(Kind::SyslogNg.wanted(&ctx) && Kind::Netdata.wanted(&ctx));
    }

    // What: web_log job parses the proxy's syslog lines.
    // Why: a wrong pattern collects nothing, fails quiet.
    // From: Issue #1683 | PR #1912
    #[test]
    fn web_log_job_reads_the_proxy_syslog_files() {
        let path = format!("/{}/{}/*.log", gen_name(), gen_name());
        let conf = web_log_conf(&path).expect("conf");
        assert!(conf.contains(&format!("    path: {path}\n    log_type: regexp\n")));
        assert!(conf.contains(&format!("      pattern: '{PROXY_ACCESS_LOG_PATTERN}'\n")));
        let nginx =
            fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../proxy/nginx.conf"))
                .expect("nginx.conf");
        assert!(nginx.contains(
            "log_format cache '$remote_addr - [$time_local] \"$request\" '\n                     '$status $body_bytes_sent '\n                     '\"$upstream_cache_status\" \"$host\"';"
        ));
        assert!(nginx.contains("access_log /dev/stdout cache;"));
        let syslog = syslog_ng_conf(514, "/r", "g", &[], REAP).expect("conf");
        assert!(syslog.contains(r#"template("${ISODATE} ${HOST} ${PROGRAM}: ${MSGONLY}\n")"#));
        for bad in ["relative.log", "/a b", "/a'b", "/a\nb"] {
            assert!(web_log_conf(bad).is_err(), "{bad:?}");
        }
    }

    // What: health is red when stale or a program is down.
    // Why: Docker health must cover every program inside.
    // From: Issue #1683
    #[test]
    fn health_needs_a_fresh_status_and_no_program_down() {
        let max_age = rnd(1, DAY);
        let now = rnd(max_age + 1, DAY + max_age);
        let fresh = SuperviseStatus {
            updated: now - rnd(0, max_age),
            ..SuperviseStatus::default()
        };
        assert!(health_verdict(&fresh, now, max_age).is_ok());
        let stale = SuperviseStatus {
            updated: now - max_age - 1,
            ..SuperviseStatus::default()
        };
        assert!(health_verdict(&stale, now, max_age).is_err());
        let name = gen_name();
        let down = SuperviseStatus {
            down: vec![name.clone()],
            ..fresh
        };
        assert!(
            health_verdict(&down, now, max_age)
                .expect_err("down")
                .contains(&name)
        );
    }

    // What: disk colors follow the warn and alarm limits.
    // Why: alarm outranks warn; equal to a limit counts.
    // From: Issue #1683 | PR #1858
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

    // What: the timestamp keeps its fixed UTC shape.
    // Why: status.json's `updated` field is a contract.
    // From: Issue #1683 | PR #1858
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

    // What: a canonical scratch root for one test.
    // Why: targets resolve symlinks; the prefix must too.
    // From: Issue #1683 | PR #1858
    fn scratch() -> PathBuf {
        fs::canonicalize(lancache_ng::unique_temp_dir(&gen_name())).expect("scratch root")
    }

    // What: retention settings on a scratch tree.
    // Why: each test owns its paths and fresh limits.
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
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
    // From: Issue #1683 | PR #1858
    fn past(days: u64) -> u64 {
        (days + 1) * DAY + rnd(1, DAY - 1)
    }

    // What: the stamp a run left, as a number.
    // Why: the daily gate and retry read this value.
    // From: Issue #1683 | PR #1858
    fn stamp_of(path: &Path) -> u64 {
        fs::read_to_string(path)
            .expect("stamp")
            .trim()
            .parse()
            .expect("number")
    }

    // What: purge deletes files past the limit, once a day.
    // Why: newer files stay; a broken stamp must not block.
    // From: Issue #1683 | PR #1858
    #[test]
    fn purge_deletes_past_the_limit_once_a_day() {
        let root = scratch();
        let r = scratch_retention(&root);
        let dir = PathBuf::from(&r.cache_dir);
        let old = dir.join(gen_name()).join(gen_name());
        let new = dir.join(gen_name()).join(gen_name());
        let (days, now) = (r.cache_valid_days, unix_secs());
        file_at(&old, rnd(1, u8::MAX.into()), now - past(days));
        file_at(
            &new,
            rnd(1, u8::MAX.into()),
            now - days * DAY - rnd(0, DAY - 1),
        );
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
        fs::remove_dir_all(&root).expect("remove scratch dir");
    }

    // What: age floor, then oldest-first to the budget.
    // Why: a file written today stays even over budget.
    // From: Issue #1683 | PR #1858
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
        assert!(
            !aged.exists() && !older.exists(),
            "floor or budget not applied"
        );
        assert!(live.exists() && newer.exists(), "pruned beyond the budget");
        assert_eq!(stamp_of(&r.syslog_stamp), now);
        fs::remove_file(&newer).expect("remove");
        let later = now + DAY + rnd(0, DAY);
        file_at(
            &live,
            budget + rnd(1, budget),
            rnd(later - later % DAY, later),
        );
        prune_syslog(&r, later);
        assert!(live.exists(), "the file written today was pruned");
        assert_eq!(stamp_of(&r.syslog_stamp), later + r.syslog_cooldown - DAY);
        fs::remove_dir_all(&root).expect("remove scratch dir");
    }

    // What: closed files become .xz; today's stay plain.
    // Why: syslog-ng still writes today's program files.
    // From: Issue #1683 | PR #1912
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

    // What: the loop ends when stop fires mid-sleep
    // Why: docker stop sends TERM; a hang ends in a kill
    // From: Issue #1683 | PR #1858
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

    // What: a random IPv4 address for a proxy IP.
    // Why: render tests must not depend on one address.
    // From: Issue #1683 | PR #1912
    fn gen_ipv4() -> std::net::Ipv4Addr {
        std::net::Ipv4Addr::from(rnd(1, u32::MAX.into()) as u32)
    }

    // What: template keys, resolver tokens, account ids.
    // Why: each feeds nginx or chown verbatim.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nginx_helpers_fill_strip_and_look_up() {
        let [key, value] = std::array::from_fn(|_| gen_name());
        let key = key.to_uppercase();
        assert_eq!(
            fill(
                &format!("a ${{{key}}} $host ${{{key}}}"),
                &[(key.as_str(), value.clone())]
            ),
            format!("a {value} $host {value}")
        );
        let ip = gen_ipv4().to_string();
        assert_eq!(resolver_host(&format!("{ip}:53")), ip);
        assert_eq!(resolver_host("[2001:db8::1]:53"), "2001:db8::1");
        assert_eq!(resolver_host("2001:db8::1"), "2001:db8::1");
        assert_eq!(account_id("passwd", "root"), Ok(0));
        assert!(account_id("group", &gen_name()).is_err());
    }

    // What: restamp swaps keyed lines, keeps the rest.
    // Why: a restored snapshot must use this start's key.
    // From: Issue #1683 | PR #1912
    #[test]
    fn restamp_replaces_only_keyed_lines() {
        let (old, new, other) = (gen_name(), gen_name(), gen_name());
        let text = format!("a={other}\n  api_key: {old}\nb=1");
        let out = restamp_lines(&text, &[("api_key:", format!("  api_key: {new}"))]);
        assert_eq!(out, format!("a={other}\n  api_key: {new}\nb=1\n"));
    }

    // What: roles and IPv4 endpoints parse; others fail.
    // Why: an unknown role or bad endpoint must not start.
    // From: Issue #1683 | PR #1912
    #[test]
    fn dns_role_and_endpoint_parse() {
        assert_eq!(dns_role("primary"), Ok(DnsRole::Primary));
        assert_eq!(dns_role("secondary"), Ok(DnsRole::Secondary));
        assert!(dns_role(&gen_name()).is_err());
        let ip = gen_ipv4();
        let port = rnd(1, u16::MAX.into()) as u16;
        let got = endpoint(&format!("{ip}:{port}"), "K").expect("endpoint");
        assert_eq!(got, std::net::SocketAddrV4::new(ip, port));
        assert!(endpoint(&ip.to_string(), "K").is_err());
        assert!(endpoint(&format!("{ip}:x"), "K").is_err());
    }

    // What: the date serial is YYMMDD000 below 2^31.
    // Why: RFC 1982 compares serials in 32-bit space.
    // From: Issue #1683 | PR #1912
    #[test]
    fn date_serial_has_the_date_shape() {
        let serial = date_serial();
        assert_eq!(serial % 1000, 0);
        assert!(serial < 1 << 31);
        let day = (serial / 1000) % 100;
        let month = (serial / 100_000) % 100;
        assert!((1..=31).contains(&day) && (1..=12).contains(&month));
    }

    // What: a changed watched file changes the print.
    // Why: that difference is what restarts a program.
    // From: Issue #1683 | PR #1912
    #[test]
    fn fingerprint_sees_a_changed_file() {
        let dir = scratch();
        let file = dir.join(gen_name());
        let files = vec![file.clone()];
        let absent = fingerprint(&files);
        fs::write(&file, gen_name()).expect("write");
        let first = fingerprint(&files);
        assert_ne!(absent, first);
        fs::write(&file, format!("{}{}", gen_name(), gen_name())).expect("write");
        assert_ne!(first, fingerprint(&files));
    }

    // What: files are found below a dir, depth limited.
    // Why: the Kea hook path differs per build.
    // From: Issue #1683 | PR #1912
    #[test]
    fn find_file_walks_down_to_its_depth() {
        let root = scratch();
        let deep = root.join("a").join("b");
        fs::create_dir_all(&deep).expect("dirs");
        let name = gen_name();
        fs::write(deep.join(&name), "").expect("file");
        assert_eq!(find_file(&root, &name, 2), Some(deep.join(&name)));
        assert_eq!(find_file(&root, &name, 1), None);
    }
}
