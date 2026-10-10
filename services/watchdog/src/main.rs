//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: watchdog health loop, restarts and status.json.
//! Why: one daemon keeps core services up, reports health.
//! From: Issue #842 | PR #1858

use std::collections::HashMap;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime};

use lancache_ng::config::{self, OutOfRange, Uint, env_opt};
use lancache_ng::{
    COMPOSE_PROJECT_LABEL, COMPOSE_SERVICE_LABEL, DesiredRunState, DesiredState, DiskHealth,
    DiskInfo, DockerApi, Place, ServiceHealth, WatchdogStatus, df, unix_secs, write_file,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

// What: seconds Docker waits for SIGTERM before SIGKILL.
// Why: stays inside the restart call's own curl budget.
const RESTART_GRACE_SECS: u32 = 2;

// What: central-control settings, read once at start.
// Why: a deployment change recreates this container.
struct Settings {
    docker_host: String,
    check_interval: Duration,
    restart_after: u32,
    // What: None means no timeout; 0 in the env.
    // Why: ZERO would mean "instant" to the HTTP client.
    api_timeout: Option<Duration>,
    restart_timeout: Option<Duration>,
    disk_warn_pct: u32,
    disk_alarm_pct: u32,
    status_file: PathBuf,
    cache_dir: PathBuf,
    // What: this container's id, Docker's default hostname.
    // Why: its compose project label names the stack.
    own_id: String,
}

// What: seconds as a timeout; 0 means no timeout (None).
// Why: fractions stay valid; 0 must not time out at once.
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
// From: Issue #849 | Issue #1683
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
    let api = api_timeout(get("DOCKER_API_TIMEOUT").as_deref(), "DOCKER_API_TIMEOUT")?;
    let restart = api_timeout(
        get("DOCKER_RESTART_TIMEOUT").as_deref(),
        "DOCKER_RESTART_TIMEOUT",
    )?;
    let need = |name: &str| config::need(&env, name).map_err(|e| format!("FATAL: {e}."));
    let settings = Settings {
        docker_host: need("DOCKER_HOST")?,
        check_interval: Duration::from_secs(check_interval),
        restart_after: restart_after as u32,
        api_timeout: api,
        restart_timeout: restart,
        disk_warn_pct: disk_warn_pct as u32,
        disk_alarm_pct: disk_alarm_pct as u32,
        status_file: PathBuf::from(need("STATUS_FILE")?),
        cache_dir: PathBuf::from(need("CACHE_DIR")?),
        own_id: need("HOSTNAME")?,
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

// What: UTC time as YYYY-MM-DDTHH:MM:SSZ, no fractions.
// Why: status.json's `updated` format is a fixed contract.
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
fn log(msg: &str) {
    emit(msg, false);
}

// What: write one error line to stderr.
// Why: errors stay visible apart from normal output.
fn log_err(msg: &str) {
    emit(msg, true);
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

// What: retention settings, then the loop until stop.
// Why: a bad setting must stop the task before deletes.
// From: Issue #842 | Issue #1683
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
// Why: the watchdog checks what compose started; no list.
// From: Issue #1683
async fn own_project(docker: &DockerApi, s: &Settings) -> Result<(String, String), String> {
    let body = docker
        .inspect(&s.own_id, s.api_timeout)
        .await
        .ok_or_else(|| format!("cannot inspect own container {}", s.own_id))?;
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
fn container_name(raw: &str) -> String {
    raw.trim_start_matches('/').to_string()
}

// What: name and compose service of one list entry.
// Why: status.json is keyed by service, calls by name.
fn listed(entry: &Value) -> Option<(String, String)> {
    let name = entry.pointer("/Names/0")?.as_str()?;
    let service = entry.get("Labels")?.get(COMPOSE_SERVICE_LABEL)?.as_str()?;
    Some((container_name(name), service.to_string()))
}

// What: check every stack container; restart failures.
// Why: one actor with the socket; its own box only alerts.
// From: Issue #842 | Issue #1683
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
    loop {
        let mut services: HashMap<String, ServiceHealth> = HashMap::new();
        let listing = docker.project_containers(&project, s.api_timeout).await;
        let Some(listing) = listing else {
            log_err("WARNING: cannot list the stack containers");
            write_status(&s, services)?;
            tokio::time::sleep(s.check_interval).await;
            continue;
        };
        for (name, service) in listing.iter().filter_map(listed) {
            let reading = match docker.inspect(&name, s.api_timeout).await {
                Some(body) => Reading::from_inspect(&body),
                None => Reading::Unreachable,
            };
            // What: the watchdog's own container is alert-only.
            // Why: restarting itself would end the restart call.
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
                        .restart(&name, RESTART_GRACE_SECS, s.restart_timeout)
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

// What: pause before a program or task starts again.
// Why: a crash loop must not spin; it caps at 30 s.
const BACKOFF_MAX: Duration = Duration::from_secs(30);

// What: a run this long resets the restart backoff.
// Why: a crash after a good run is a fresh failure.
const BACKOFF_RESET: Duration = Duration::from_secs(60);

// What: how often the supervisor converges.
// Why: a settings change applies within one tick.
const TICK: Duration = Duration::from_secs(2);

// What: wait for a stopped program before SIGKILL.
// Why: Docker's own stop grace is 10 s; stay inside it.
const STOP_GRACE: Duration = Duration::from_secs(8);

// What: oldest supervisor status the healthcheck accepts.
// Why: a hung supervisor stops writing; that is red.
const STATUS_MAX_AGE: u64 = 30;

// What: inputs every program reads at render time.
// Why: settings file beats env; the run dir is private.
// From: Issue #1683
struct Ctx {
    run_dir: PathBuf,
    settings_file: PathBuf,
    desired_file: PathBuf,
}

impl Ctx {
    // What: the saved ui setting, else the env value.
    // Why: operators change settings live in the ui.
    fn setting(&self, key: &str) -> Option<String> {
        config::non_empty(config::saved_setting(&self.settings_file, key).as_deref())
            .map(str::to_string)
            .or_else(|| env_opt(key))
    }

    // What: a required value from the env.
    // Why: no defaults in Rust; the env files own them.
    fn need(&self, key: &str) -> Result<String, String> {
        config::need(&config::process_env, key)
    }

    // What: a file in the run dir, written fresh.
    // Why: each start renders from the current settings.
    fn render(&self, file: &str, body: &str) -> Result<String, String> {
        let path = self.run_dir.join(file);
        write_file(&path, body.as_bytes(), 0o644, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        Ok(path.display().to_string())
    }
}

// What: one program or task the supervisor keeps alive.
// Why: LANCACHE_PROCESSES names them; the SOT owns it.
// From: Issue #1683
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Watch,
    Retention,
    SyslogNg,
    Chronyd,
    Netdata,
}

impl Kind {
    // What: the kind of one LANCACHE_PROCESSES entry.
    // Why: an unknown name is a build error; fail closed.
    fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "watch" => Self::Watch,
            "retention" => Self::Retention,
            "syslog-ng" => Self::SyslogNg,
            "chronyd" => Self::Chronyd,
            "netdata" => Self::Netdata,
            _ => return None,
        })
    }

    // What: the name as LANCACHE_PROCESSES spells it.
    // Why: logs and the status file use the same name.
    fn name(self) -> &'static str {
        match self {
            Self::Watch => "watch",
            Self::Retention => "retention",
            Self::SyslogNg => "syslog-ng",
            Self::Chronyd => "chronyd",
            Self::Netdata => "netdata",
        }
    }

    // What: whether this kind should run right now.
    // Why: NTP follows the saved setting and desired state.
    // From: Issue #1437 | Issue #1683
    fn wanted(self, ctx: &Ctx) -> bool {
        match self {
            Self::Chronyd => {
                let on = ctx
                    .setting("NTP_ENABLED")
                    .as_deref()
                    .and_then(config::parse_bool);
                let desired = DesiredState::read(&ctx.desired_file).ntp;
                on == Some(true) && desired != Some(DesiredRunState::Stopped)
            }
            _ => true,
        }
    }

    // What: render the config, return the command line.
    // Why: a render error keeps the program stopped.
    fn launch(self, ctx: &Ctx) -> Result<Vec<String>, String> {
        match self {
            Self::Watch | Self::Retention => Ok(Vec::new()),
            Self::SyslogNg => syslog_ng(ctx),
            Self::Chronyd => chronyd(ctx),
            Self::Netdata => Ok(vec!["netdata".into(), "-D".into()]),
        }
    }
}

// What: syslog-ng.conf for the Docker syslog input.
// Why: one file per container and day; xz comes later.
// From: Issue #1683
fn syslog_ng_conf(port: &str, root: &str) -> Result<String, String> {
    if port.parse::<u16>().map_or(true, |p| p == 0) {
        return Err(format!("LANCACHE_LOG_PORT={port} is no port"));
    }
    if !root.starts_with('/') || root.contains(['"', '\n', '\r', '$']) {
        return Err(format!("SYSLOG_LOG_ROOT={root} is no plain absolute path"));
    }
    Ok(format!(
        r#"@version: current
options {{ create-dirs(yes); dir-perm(0750); perm(0640); keep-hostname(yes); time-reap(30); }};
source s_docker {{ network(transport("udp") port({port}) flags(syslog-protocol)); }};
filter f_named {{ program("^[A-Za-z0-9_-]+$" type(pcre)); }};
destination d_store {{ file("{root}/${{PROGRAM}}/${{YEAR}}${{MONTH}}${{DAY}}.log" template("${{ISODATE}} ${{HOST}} ${{PROGRAM}}: ${{MSGONLY}}\n")); }};
log {{ source(s_docker); filter(f_named); destination(d_store); }};
"#
    ))
}

// What: render syslog-ng.conf; the syslog-ng command.
// Why: state files live in the private run dir.
fn syslog_ng(ctx: &Ctx) -> Result<Vec<String>, String> {
    let conf = syslog_ng_conf(
        &ctx.need("LANCACHE_LOG_PORT")?,
        &ctx.need("SYSLOG_LOG_ROOT")?,
    )?;
    let conf = ctx.render("syslog-ng.conf", &conf)?;
    let run = |file: &str| ctx.run_dir.join(file).display().to_string();
    Ok(vec![
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
        run("syslog-ng.ctl"),
    ])
}

// What: an IP literal (server) or a name (pool).
// Why: chrony needs pool for names, server for IPs.
fn is_ip_literal(entry: &str) -> bool {
    entry.parse::<std::net::IpAddr>().is_ok()
}

// What: chrony.conf from upstreams and client CIDRs.
// Why: NTP never runs alone; no CIDR serves everyone.
// From: Issue #1683
fn chrony_conf(upstreams: &str, cidrs: &str, drift: &str) -> Result<String, String> {
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
    let mut conf = format!("driftfile {drift}\nmakestep 1.0 3\nrtcsync\n");
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
// Why: -d keeps it attached and logging to stderr.
fn chronyd(ctx: &Ctx) -> Result<Vec<String>, String> {
    let conf = chrony_conf(
        &ctx.setting("NTP_UPSTREAM_SERVERS").unwrap_or_default(),
        &ctx.setting("NTP_ALLOWED_CLIENT_CIDRS").unwrap_or_default(),
        &ctx.need("NTP_DRIFT_FILE")?,
    )?;
    let conf = ctx.render("chrony.conf", &conf)?;
    Ok(vec!["chronyd".into(), "-d".into(), "-f".into(), conf])
}

// What: one supervised slot and its restart state.
// Why: the loop converges each slot to wanted state.
struct Slot {
    kind: Kind,
    child: Option<tokio::process::Child>,
    task: Option<tokio::task::JoinHandle<Result<(), String>>>,
    started: Option<std::time::Instant>,
    not_before: std::time::Instant,
    backoff: Duration,
    restarts: u32,
}

impl Slot {
    // What: true while the program or task is alive.
    // Why: the status file and healthcheck report it.
    fn running(&self) -> bool {
        self.child.is_some() || self.task.as_ref().is_some_and(|t| !t.is_finished())
    }

    // What: start the program or task once.
    // Why: a failed start waits out the backoff first.
    fn start(&mut self, ctx: &Ctx) {
        let name = self.kind.name();
        let argv = match self.kind.launch(ctx) {
            Ok(argv) => argv,
            Err(e) => return self.failed(&format!("{name}: {e}")),
        };
        let task = match self.kind {
            Kind::Watch => Some(tokio::spawn(TAG.scope("watch", watch()))),
            Kind::Retention => Some(tokio::spawn(TAG.scope("retention", retention()))),
            _ => None,
        };
        if task.is_none() {
            match tokio::process::Command::new(&argv[0])
                .args(&argv[1..])
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
    // Why: the delay doubles up to BACKOFF_MAX.
    fn failed(&mut self, why: &str) {
        log_err(&format!(
            "ERROR: {why}; next start in {}s",
            self.backoff.as_secs()
        ));
        self.not_before = std::time::Instant::now() + self.backoff;
        self.backoff = (self.backoff * 2).min(BACKOFF_MAX);
        self.restarts = self.restarts.saturating_add(1);
    }

    // What: notice an exited program or task.
    // Why: an exit is a failure; a long run resets backoff.
    async fn reap(&mut self) {
        let name = self.kind.name();
        let ran_long = self.started.is_some_and(|at| at.elapsed() >= BACKOFF_RESET);
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
                self.backoff = Duration::from_secs(1);
            }
            self.failed(&why);
        }
    }

    // What: stop the program: TERM, wait, then KILL.
    // Why: a clean stop lets daemons flush their state.
    async fn stop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        let Some(mut child) = self.child.take() else {
            return;
        };
        if let Some(pid) = child.id() {
            let _ = tokio::process::Command::new("kill")
                .args(["-TERM", &pid.to_string()])
                .status()
                .await
                .inspect_err(|e| log_err(&format!("WARNING: kill -TERM {pid}: {e}")));
        }
        if tokio::time::timeout(STOP_GRACE, child.wait())
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
#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
struct SuperviseStatus {
    updated: u64,
    // What: wanted programs that are not running now.
    // Why: one red entry makes the container unhealthy.
    down: Vec<String>,
    restarts: HashMap<String, u32>,
}

// What: the kinds this container runs, in order.
// Why: an unknown or doubled name fails the start.
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
// Why: one supervisor per container replaces entrypoints.
// From: Issue #1683
async fn supervise() -> Result<(), String> {
    use tokio::signal::unix::{SignalKind, signal};
    let need = |key: &str| config::need(&config::process_env, key);
    let kinds = kinds(&need("LANCACHE_PROCESSES")?)?;
    let ctx = Ctx {
        run_dir: PathBuf::from(need("SUPERVISE_RUN_DIR")?),
        settings_file: PathBuf::from(need("UI_SETTINGS_FILE")?),
        desired_file: PathBuf::from(need("DESIRED_STATE_FILE")?),
    };
    let status_file = ctx.run_dir.join("supervise.json");
    fs::create_dir_all(&ctx.run_dir)
        .map_err(|e| format!("cannot create {}: {e}", ctx.run_dir.display()))?;
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut int = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    let now = std::time::Instant::now();
    let mut slots: Vec<Slot> = kinds
        .into_iter()
        .map(|kind| Slot {
            kind,
            child: None,
            task: None,
            started: None,
            not_before: now,
            backoff: Duration::from_secs(1),
            restarts: 0,
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
            } else if !wanted && slot.running() {
                slot.stop().await;
            }
            if wanted && !slot.running() {
                status.down.push(slot.kind.name().to_string());
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
            () = tokio::time::sleep(TICK) => {}
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
fn healthcheck() -> Result<(), String> {
    let dir = config::need(&config::process_env, "SUPERVISE_RUN_DIR")?;
    let path = Path::new(&dir).join("supervise.json");
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let status: SuperviseStatus =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    health_verdict(&status, unix_secs())
}

// What: the verdict for one status at one time.
// Why: pure, so tests feed it any status and clock.
fn health_verdict(status: &SuperviseStatus, now: u64) -> Result<(), String> {
    let age = now.saturating_sub(status.updated);
    if age > STATUS_MAX_AGE {
        return Err(format!("supervisor status is {age}s old"));
    }
    if !status.down.is_empty() {
        return Err(format!("not running: {}", status.down.join(" ")));
    }
    Ok(())
}

// What: supervise (default) or healthcheck.
// Why: one binary per container, two entry points.
// From: Issue #1683
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
        ["healthcheck"] => healthcheck(),
        _ => Err("usage: lancache-watchdog [supervise|healthcheck]".to_string()),
    };
    if let Err(e) = result {
        log_err(&format!("FATAL: {e}"));
        std::process::exit(1);
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
        vec![
            ("DOCKER_HOST", format!("unix://{}", gen_path())),
            ("CHECK_INTERVAL", rnd(1, DAY).to_string()),
            ("RESTART_AFTER", rnd(1, u32::MAX.into()).to_string()),
            ("DISK_WARN_PCT", warn.to_string()),
            ("DISK_ALARM_PCT", rnd(warn + 1, u32::MAX.into()).to_string()),
            ("DOCKER_API_TIMEOUT", rnd(1, DAY).to_string()),
            ("DOCKER_RESTART_TIMEOUT", rnd(1, DAY).to_string()),
            ("CACHE_DIR", gen_path()),
            ("STATUS_FILE", gen_path()),
            ("HOSTNAME", gen_name()),
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
            (s.api_timeout, s.restart_timeout),
            (
                Some(Duration::from_secs(num("DOCKER_API_TIMEOUT"))),
                Some(Duration::from_secs(num("DOCKER_RESTART_TIMEOUT")))
            )
        );
        assert_eq!(s.cache_dir, PathBuf::from(value(&env, "CACHE_DIR")));
        assert_eq!(s.docker_host, value(&env, "DOCKER_HOST"));
        assert_eq!(s.own_id, value(&env, "HOSTNAME"));

        let interval = "0".repeat(rnd(1, u8::MAX.into()) as usize);
        let restart = "0".repeat(rnd(1, u8::MAX.into()) as usize);
        let floored = [
            ("CHECK_INTERVAL", interval.as_str()),
            ("RESTART_AFTER", restart.as_str()),
        ];
        let (s, warnings) = load_settings(reader(&env, &floored)).expect("floored");
        assert_eq!(
            (s.check_interval, s.restart_after),
            (Duration::from_secs(1), 1)
        );
        for (key, raw) in floored {
            let want = format!("{key}={raw}");
            assert!(
                warnings.iter().any(|w| w.contains(&want)),
                "{want}: {warnings:?}"
            );
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
            let err = load_settings(reader(&env, &[(name, bad)]))
                .err()
                .expect("fails");
            assert!(err.contains(name), "{name}={bad}: {err}");
        }
    }

    // What: API timeouts keep fractions; 0 is unbounded.
    // Why: 0 must not time out at once; junk is fatal.
    #[test]
    fn api_timeouts_handle_zero_fractions_and_junk() {
        let fraction = format!("{}.{}", rnd(0, DAY), rnd(1, u32::MAX.into()));
        let pairs = [
            ("DOCKER_API_TIMEOUT", "0"),
            ("DOCKER_RESTART_TIMEOUT", fraction.as_str()),
        ];
        let (s, warnings) = load(&pairs).expect("settings");
        let secs: f64 = fraction.parse().expect("number");
        assert_eq!(s.api_timeout, None);
        assert_eq!(s.restart_timeout, Some(Duration::from_secs_f64(secs)));
        assert!(warnings.is_empty(), "{warnings:?}");
        let overflow = format!("1e{}", rnd((f64::MAX_10_EXP + 1) as u64, u16::MAX.into()));
        let negative = format!("-{fraction}");
        for bad in [gen_name(), negative, overflow, String::new()] {
            let err = load(&[("DOCKER_API_TIMEOUT", bad.as_str())])
                .err()
                .expect("fails");
            assert!(err.contains("DOCKER_API_TIMEOUT"), "{bad}: {err}");
        }
    }

    // What: unset or junk owner values are fatal.
    // Why: the watchdog has no defaults to fall back on.
    #[test]
    fn missing_or_junk_owner_values_are_fatal() {
        let env = base_env();
        for (var, _) in &env {
            let err = load_settings(reader(&env, &[(*var, "")]))
                .err()
                .expect("fails");
            assert!(err.contains(var), "{var}: {err}");
        }
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

    // What: list entries yield name and compose service.
    // Why: an entry without labels must be skipped.
    // From: Issue #1683
    #[test]
    fn list_entries_yield_name_and_service() {
        let (name, service) = (gen_name(), gen_name());
        let entry = serde_json::json!({
            "Names": [format!("/{name}")],
            "Labels": {COMPOSE_SERVICE_LABEL: service},
        });
        assert_eq!(listed(&entry), Some((name.clone(), service)));
        let bare = serde_json::json!({"Names": [format!("/{name}")]});
        assert_eq!(listed(&bare), None);
        assert_eq!(container_name(&format!("/{name}")), name);
    }

    // What: LANCACHE_PROCESSES parses, refuses junk.
    // Why: an unknown or doubled name is a build error.
    // From: Issue #1683
    #[test]
    fn process_lists_parse_and_refuse_junk() {
        let all = [
            Kind::Watch,
            Kind::Retention,
            Kind::SyslogNg,
            Kind::Chronyd,
            Kind::Netdata,
        ];
        let text: Vec<&str> = all.iter().map(|k| k.name()).collect();
        assert_eq!(kinds(&text.join(" ")).expect("kinds"), all);
        assert!(kinds("").is_err());
        assert!(kinds(&gen_name()).is_err());
        assert!(kinds("watch watch").is_err());
    }

    // What: chrony.conf has the pools, servers, allows.
    // Why: no upstream or an unsafe value must not start.
    // From: Issue #1683
    #[test]
    fn chrony_conf_lists_upstreams_and_clients() {
        let (pool, drift) = (format!("{}.example", gen_name()), gen_path());
        let ip = format!("192.0.2.{}", rnd(1, 254));
        let cidr = format!("10.{}.0.0/16", rnd(0, 255));
        let conf = chrony_conf(&format!("{pool} {ip}"), &cidr, &drift).expect("conf");
        assert!(conf.contains(&format!("pool {pool} iburst\n")), "{conf}");
        assert!(conf.contains(&format!("server {ip} iburst\n")), "{conf}");
        assert!(conf.contains(&format!("allow {cidr}\n")), "{conf}");
        assert!(conf.contains(&format!("driftfile {drift}\n")), "{conf}");
        let open = chrony_conf(&pool, "", &drift).expect("conf");
        assert!(open.contains("allow 0.0.0.0/0\n") && open.contains("allow ::/0\n"));
        assert!(chrony_conf(" ", "", &drift).is_err());
        assert!(chrony_conf(&format!("{pool};allow"), "", &drift).is_err());
        assert!(chrony_conf(&pool, "", &gen_name()).is_err());
    }

    // What: syslog-ng.conf takes a port and a root path.
    // Why: a junk port or path must not reach the config.
    // From: Issue #1683
    #[test]
    fn syslog_ng_conf_takes_a_port_and_a_root() {
        let (port, root) = (rnd(1, u16::MAX.into()).to_string(), gen_path());
        let conf = syslog_ng_conf(&port, &root).expect("conf");
        assert!(conf.contains(&format!("port({port})")), "{conf}");
        assert!(
            conf.contains(&format!("file(\"{root}/${{PROGRAM}}/")),
            "{conf}"
        );
        assert!(syslog_ng_conf("0", &root).is_err());
        assert!(syslog_ng_conf(&gen_name(), &root).is_err());
        assert!(syslog_ng_conf(&port, &gen_name()).is_err());
        assert!(syslog_ng_conf(&port, &format!("{root}\"")).is_err());
    }

    // What: chronyd follows the saved flag and the dock.
    // Why: the ui is dumb; the supervisor converges NTP.
    // From: Issue #1437 | Issue #1683
    #[test]
    fn chronyd_follows_the_setting_and_desired_state() {
        let root = scratch();
        let ctx = Ctx {
            run_dir: root.join(gen_name()),
            settings_file: root.join(gen_name()),
            desired_file: root.join(gen_name()),
        };
        let set = |on: bool, desired: &str| {
            fs::write(
                &ctx.settings_file,
                format!("NTP_ENABLED={}\n", u8::from(on)),
            )
            .expect("settings");
            fs::write(&ctx.desired_file, desired).expect("desired");
            Kind::Chronyd.wanted(&ctx)
        };
        assert!(set(true, "{}"));
        assert!(set(true, r#"{"ntp":"running"}"#));
        assert!(!set(true, r#"{"ntp":"stopped"}"#));
        assert!(!set(false, r#"{"ntp":"running"}"#));
        assert!(Kind::SyslogNg.wanted(&ctx) && Kind::Netdata.wanted(&ctx));
    }

    // What: health is red when stale or a program is down.
    // Why: Docker health must cover every program inside.
    // From: Issue #1683
    #[test]
    fn health_needs_a_fresh_status_and_no_program_down() {
        let now = rnd(STATUS_MAX_AGE + 1, DAY);
        let fresh = SuperviseStatus {
            updated: now - rnd(0, STATUS_MAX_AGE),
            ..SuperviseStatus::default()
        };
        assert!(health_verdict(&fresh, now).is_ok());
        let stale = SuperviseStatus {
            updated: now - STATUS_MAX_AGE - 1,
            ..SuperviseStatus::default()
        };
        assert!(health_verdict(&stale, now).is_err());
        let name = gen_name();
        let down = SuperviseStatus {
            down: vec![name.clone()],
            ..fresh
        };
        assert!(
            health_verdict(&down, now)
                .expect_err("down")
                .contains(&name)
        );
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

    // What: API timeouts refuse inf, NaN, negatives.
    // Why: only a finite positive number is a real limit.
    #[test]
    fn api_timeout_refuses_non_finite_and_negative_numbers() {
        let negative = format!("-{}.{}", rnd(0, DAY), rnd(1, u32::MAX.into()));
        for bad in ["inf", "NaN", negative.as_str()] {
            assert_eq!(
                api_timeout(Some(bad), "DOCKER_API_TIMEOUT"),
                Err(format!("FATAL: invalid DOCKER_API_TIMEOUT={bad}."))
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
            assert!(
                load_retention(reader(&env, &[(*key, "")])).is_err(),
                "{key} blank"
            );
        }
        let (junk, relative) = (gen_name(), format!("{}/{}", gen_name(), gen_name()));
        let bad = [
            ("SYSLOG_MAX_GB", "0"),
            ("CACHE_VALID_DAYS", junk.as_str()),
            ("CACHE_DIR_ALLOWED_PREFIX", relative.as_str()),
            ("PURGE_STAMP", relative.as_str()),
        ];
        for (key, raw) in bad {
            assert!(
                load_retention(reader(&env, &[(key, raw)])).is_err(),
                "{key}={raw}"
            );
        }
        let above = (config::SYSLOG_MAX_GB.max + rnd(1, DAY)).to_string();
        let long = (DAY + rnd(1, DAY)).to_string();
        let high = [
            ("SYSLOG_MAX_GB", above.as_str()),
            ("SYSLOG_PRUNE_RETRY_COOLDOWN", long.as_str()),
        ];
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
        let back = format!(
            "{}/{sub}/../../{}",
            at(&real),
            real.file_name().unwrap().to_string_lossy()
        );
        let ok = [
            (at(&real), real.clone()),
            (at(&prefix.join(&missing)), prefix.join(&missing)),
            (back, real.clone()),
        ];
        for (raw, want) in ok {
            assert_eq!(
                retention_target("CACHE_DIR", &raw, &prefix),
                Ok(want),
                "{raw}"
            );
        }
        let bad = [
            (String::new(), "is empty"),
            (
                format!("{}/{}", gen_name(), gen_name()),
                "is not an absolute path",
            ),
            (at(&outside), "outside the expected"),
            (
                format!(
                    "{}/../../{}",
                    at(&real),
                    outside.file_name().unwrap().to_string_lossy()
                ),
                "outside the expected",
            ),
            (at(&escape.join(gen_name())), "outside the expected"),
            (at(&dangling.join(gen_name())), "could not be canonicalized"),
            (at(&prefix), "itself, not a subdirectory"),
        ];
        for (raw, want) in bad {
            let got = retention_target("CACHE_DIR", &raw, &prefix);
            assert!(
                got.as_ref().is_err_and(|e| e.contains(want)),
                "{raw}: {got:?}"
            );
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
