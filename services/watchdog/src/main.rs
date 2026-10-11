//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: supervisor of every program in one container.
//! Why: it replaces the shell entrypoints of all images.
//! From: Issue #842 | Issue #1683

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
    self, DhcpMode, NatsLogin, NatsRoles, OutOfRange, PDNS_AUTH_PORT, Uint, env_opt,
    render_nats_conf,
};
use lancache_ng::{
    ALARM_INGEST_PATH, ALARM_TOKEN_HEADER, COMPOSE_PROJECT_LABEL, COMPOSE_SERVICE_LABEL,
    ClientCheck, ConflictCheck, DesiredRunState, DesiredState, Detail, DiskHealth, DiskInfo,
    DockerApi, NetdataAlarm, Place, ProbeAnswer, ProbeReport, ServiceHealth, WatchdogStatus, df,
    hex32, resolve_shared_secret, sha256_hex, shared_secret_file_name,
    shared_secret_is_placeholder, unix_secs, write_file, write_if_changed,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

// What: seconds Docker waits for SIGTERM before SIGKILL.
// Why: stays inside the restart call's own API budget.
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
// Why: settings file beats env; a secondary has no ui files.
// From: Issue #1683
struct Ctx {
    run_dir: PathBuf,
    settings_file: Option<PathBuf>,
    desired_file: Option<PathBuf>,
}

impl Ctx {
    // What: the saved ui setting, else the env value.
    // Why: operators change settings live in the ui.
    fn setting(&self, key: &str) -> Option<String> {
        let saved = self
            .settings_file
            .as_deref()
            .and_then(|file| config::saved_setting(file, key));
        config::non_empty(saved.as_deref())
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
    // Why: an unknown name is a build error; fail closed.
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
    // Why: NTP and DHCP follow the ui; NATS a primary only.
    // From: Issue #1437 | Issue #1683
    fn wanted(self, ctx: &Ctx) -> bool {
        let secondary = || env_opt("DNS_REPLICATION_ROLE").as_deref() == Some("secondary");
        let dhcp = || DhcpMode::parse(&ctx.setting("DHCP_MODE").unwrap_or_default());
        // What: the dock's run request for one service.
        // Why: "stopped" overrides the saved setting.
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
    watch: Vec<PathBuf>,
}

// What: size and mtime of each watched file, if any.
// Why: a changed input means a restart; absent is a state.
fn fingerprint(files: &[PathBuf]) -> Vec<Option<(u64, i64, i64)>> {
    files
        .iter()
        .map(|f| {
            fs::metadata(f)
                .ok()
                .map(|m| (m.len(), m.mtime(), m.mtime_nsec()))
        })
        .collect()
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
fn syslog_ng(ctx: &Ctx) -> Result<Run, String> {
    let conf = syslog_ng_conf(
        &ctx.need("LANCACHE_LOG_PORT")?,
        &ctx.need("SYSLOG_LOG_ROOT")?,
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
        run("syslog-ng.ctl"),
    ];
    Ok(Run {
        argv,
        ..Run::default()
    })
}

// What: wait limit and recipient of the alarm POST.
// Why: an unreachable ui must not stall netdata's health.
// From: Issue #858
const NETDATA_ALARM_MAX_TIME: u32 = 15;
const NETDATA_ALARM_RECIPIENT: &str = "lancache-ui";

// What: daemon and health log to stderr, the rest off.
// Why: Docker hands stderr to the one syslog-ng.
// From: Issue #1683
const NETDATA_CONF: &str =
    "[logs]\n    daemon = stderr\n    health = stderr\n    collector = off\n    access = off\n";

// What: fields of the nginx cache log_format.
// Why: go.d web_log has no built-in parser for it.
// From: Issue #1246
const NGINX_CACHE_LOG_PATTERN: &str = r#"^(?P<remote_addr>\S+) - \[(?P<time_local>[^\]]+)\] "(?P<request>[^"]*)" (?P<status>\d+) (?P<body_bytes_sent>\d+) "[^"]*" "(?P<host>[^"]*)""#;

// What: netdata custom_sender that POSTs alarms to the ui.
// Why: fields come from NetdataAlarm; no second list.
// From: Issue #858
fn alarm_notify_conf(ui_url: &str, token_file: &str) -> Result<String, String> {
    for value in [ui_url, token_file] {
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
DEFAULT_RECIPIENT_CUSTOM="{NETDATA_ALARM_RECIPIENT}"
_lancache_json_escape() {{
  printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}}
custom_sender() {{
  local token httpcode
  token="$(cat "{token_file}")" || return 1
  httpcode="$(docurl --max-time {NETDATA_ALARM_MAX_TIME} -X POST -H "Content-Type: application/json" -H "{ALARM_TOKEN_HEADER}: ${{token}}" -d "{{{json}}}" "{ui_url}{ALARM_INGEST_PATH}")" || {{
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

// What: go.d web_log job for the nginx access log.
// Why: live request charts; netdata reads it by group.
// From: Issue #1246
fn web_log_conf(path: &str) -> Result<String, String> {
    if !path.starts_with('/') || path.contains(['\'', '"', '\n', '\r', ' ', '#']) {
        return Err(format!("NETDATA_WEB_LOG={path} is no plain absolute path"));
    }
    Ok(format!(
        "jobs:\n  - name: nginx_proxy\n    path: {path}\n    log_type: regexp\n    \
         regexp_config:\n      pattern: '{NGINX_CACHE_LOG_PATTERN}'\n"
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
    )?;
    let web_log = web_log_conf(&ctx.need("NETDATA_WEB_LOG")?)?;
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
        account_id("group", "netdata")?,
        0o600,
    )?;
    put("health_alarm_notify.conf", &sender, 0o644)?;
    put("netdata.conf", NETDATA_CONF, 0o644)?;
    put("go.d/web_log.conf", &web_log, 0o644)?;
    Ok(Run {
        argv: vec!["netdata".into(), "-D".into()],
        ..Run::default()
    })
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
// Why: -d logs to stderr; a ui change restarts it.
fn chronyd(ctx: &Ctx) -> Result<Run, String> {
    let conf = chrony_conf(
        &ctx.setting("NTP_UPSTREAM_SERVERS").unwrap_or_default(),
        &ctx.setting("NTP_ALLOWED_CLIENT_CIDRS").unwrap_or_default(),
        &ctx.need("NTP_DRIFT_FILE")?,
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
fn dns_role(raw: &str) -> Result<DnsRole, String> {
    match raw {
        "primary" => Ok(DnsRole::Primary),
        "secondary" => Ok(DnsRole::Secondary),
        _ => Err(format!(
            "DNS_REPLICATION_ROLE={raw} is neither primary nor secondary"
        )),
    }
}

// What: ports of the PowerDNS servers in this container.
// Why: compose maps 53 and 1053; the APIs stay inside.
// From: Issue #1683
const AUTH_API_PORT: u16 = 8081;
const ROLLBACK_LISTEN: &str = "0.0.0.0:8083";

// What: one recursor: name, answer IP, ports.
// Why: dns-http and dns-https differ only in these.
// From: Issue #1683
struct Recursor {
    name: &'static str,
    ip_key: &'static str,
    port: u16,
    api_port: u16,
}

impl Recursor {
    // What: a recursor runs only when its answer IP is set.
    // Why: a secondary has one LAN IP and no dns-https.
    fn runs(&self) -> bool {
        env_opt(self.ip_key).is_some()
    }
}

// What: dns-http answers with IP_STANDARD, dns-https SSL.
// Why: one cache per proxy IP keeps the answers apart.
// From: Issue #1683
const DNS_HTTP: Recursor = Recursor {
    name: "dns-http",
    ip_key: "PROXY_IP",
    port: 53,
    api_port: 8082,
};
const DNS_HTTPS: Recursor = Recursor {
    name: "dns-https",
    ip_key: "PROXY_HTTPS_IP",
    port: 1053,
    api_port: 8084,
};

// What: secondary AXFR poll seconds and negative TTL.
// Why: #1164 bounds a missed NOTIFY to this many seconds.
// From: Issue #1164
const XFR_CYCLE_SECS: u64 = 15;

// What: TSIG key name and algorithm of DDNS and AXFR.
// Why: Kea signs with the same name; one spelling.
// From: Issue #858
const TSIG_NAME: &str = "lancache-ddns-key";
const TSIG_ALGORITHM: &str = "hmac-sha256";

// What: the local API root of a PowerDNS server.
// Why: the supervisor and nats-subscriber share it.
fn api_root(port: u16) -> String {
    format!("http://127.0.0.1:{port}{}", config::PDNS_API_PATH)
}

// What: 32 random bytes in base64, a TSIG secret.
// Why: Kea and PowerDNS read the key in this form.
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
    let gid = need("LANCACHE_SHARED_SECRET_GID")?
        .parse::<u32>()
        .map_err(|_| "LANCACHE_SHARED_SECRET_GID is no group id".to_string())?;
    let configured = env_opt(var).unwrap_or_default();
    let current = if shared_secret_is_placeholder(&configured) {
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

// What: one whole-number knob inside [min, max].
// Why: a bad SOA value would render an invalid zone.
fn bounded(key: &str, min: u64, max: u64) -> Result<u64, String> {
    let raw = config::need(&config::process_env, key)?;
    match raw.parse::<u64>() {
        Ok(v) if (min..=max).contains(&v) => Ok(v),
        _ => Err(format!(
            "{key}={raw} must be a whole number in {min}..={max}"
        )),
    }
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
    let socket = std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("1.1.1.1:53").map(|()| s))
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
fn endpoint(raw: &str, key: &str) -> Result<std::net::SocketAddrV4, String> {
    use std::net::ToSocketAddrs as _;
    let (host, port) = raw
        .rsplit_once(':')
        .filter(|(h, p)| !h.is_empty() && !p.is_empty())
        .ok_or_else(|| format!("{key}={raw} is not host:port"))?;
    let port: u16 = port
        .parse()
        .map_err(|_| format!("{key}={raw} has no valid port"))?;
    (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("{key} host {host} does not resolve: {e}"))?
        .find_map(|a| match a {
            std::net::SocketAddr::V4(v4) => Some(v4),
            std::net::SocketAddr::V6(_) => None,
        })
        .ok_or_else(|| format!("{key} host {host} has no IPv4 address"))
}

// What: the comma list of DNS_XFR_NOTIFY_TARGETS.
// Why: a primary notifies and allows AXFR to each one.
fn notify_targets() -> Result<Vec<std::net::SocketAddrV4>, String> {
    env_opt("DNS_XFR_NOTIFY_TARGETS")
        .unwrap_or_default()
        .split([',', ' '])
        .filter(|t| !t.is_empty())
        .map(|t| endpoint(t, "DNS_XFR_NOTIFY_TARGETS"))
        .collect()
}

// What: pdns.conf for the authoritative server.
// Why: one render replaces the envsubst template.
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
    api_key: &'a str,
}

impl AuthConf<'_> {
    fn render(&self) -> String {
        let yes = |on: bool| if on { "yes" } else { "no" };
        format!(
            "local-address=127.0.0.1,{local}\nlocal-port={PDNS_AUTH_PORT}\nlaunch=gsqlite3\n\
             gsqlite3-database={db}\nprimary={primary}\nsecondary={secondary}\n\
             xfr-cycle-interval={XFR_CYCLE_SECS}\nallow-notify-from={notify}\n\
             allow-axfr-ips={axfr}\ndnsupdate=yes\nallow-dnsupdate-from={allow}\n\
             dnsupdate-require-tsig=no\n\
             default-soa-content=localhost. admin.@ {seed} {refresh} {retry} 604800 3600\n\
             webserver=yes\nwebserver-address=0.0.0.0\nwebserver-port={AUTH_API_PORT}\n\
             webserver-allow-from=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16\n\
             api=yes\napi-key={key}\nloglevel=3\nguardian=no\ndaemon=no\n",
            local = self.local,
            db = self.database,
            primary = yes(self.role == DnsRole::Primary),
            secondary = yes(self.role == DnsRole::Secondary),
            notify = self.notify_from,
            axfr = self.axfr_ips,
            allow = self.allow_from,
            seed = self.seed_serial,
            refresh = self.refresh,
            retry = self.retry,
            key = self.api_key,
        )
    }
}

// What: true when a config check command exits 0.
// Why: pdns_server and pdns_recursor check side-effect free.
fn conf_ok(check: &[String]) -> bool {
    match std::process::Command::new(&check[0])
        .args(&check[1..])
        .output()
    {
        Ok(out) if out.status.success() => true,
        Ok(out) => {
            log_err(&format!(
                "ERROR: {} rejected the config: {}",
                check[0],
                String::from_utf8_lossy(&out.stderr).trim()
            ));
            false
        }
        Err(e) => {
            log_err(&format!("ERROR: cannot run {}: {e}", check[0]));
            false
        }
    }
}

// What: KEEP_KNOWN_GOOD_CONFIGS, at least 1.
// Why: a rollback needs one good config to go back to.
// From: Issue #415
fn keep_known_good() -> Result<u32, String> {
    bounded("KEEP_KNOWN_GOOD_CONFIGS", 1, u32::MAX.into()).map(|v| v as u32)
}

// What: write candidate file sets; keep the first that checks.
// Why: a bad render falls back to the newest good set.
// From: Issue #415 | Issue #1683
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
fn snapshots<T>(
    store: &lancache_ng::SnapshotStore,
    read: &dyn Fn(Value) -> Option<T>,
) -> Vec<(String, T)> {
    let ids = store.ids().unwrap_or_else(|e| {
        log_err(&format!("WARNING: cannot list snapshots: {e}"));
        Vec::new()
    });
    ids.into_iter()
        .rev()
        .filter_map(|id| Some((id.clone(), read(store.read(&id).ok()?)?)))
        .collect()
}

// What: write rendered files; record the set when it checks.
// Why: the newest good render is the next rollback target.
// From: Issue #415 | Issue #615 | Issue #1683
fn checked_files(
    files: &[(PathBuf, String)],
    check: &[String],
    store: &lancache_ng::SnapshotStore,
    restamp: &dyn Fn(&str) -> String,
    record: bool,
) -> Result<(), String> {
    let name = |path: &Path| path.file_name().map(|n| n.to_string_lossy().into_owned());
    let what = files
        .iter()
        .map(|(path, _)| path.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    let named = |set: Value| -> Option<Vec<(PathBuf, String)>> {
        files
            .iter()
            .map(|(path, _)| Some((path.clone(), restamp(set.get(name(path)?)?.as_str()?))))
            .collect()
    };
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
    if let Err(e) = store.create(&Value::Object(set), keep_known_good()?) {
        log_err(&format!("WARNING: {what} not saved as known-good: {e:#}"));
    }
    Ok(())
}

// What: replace each line that starts with a key.
// Why: a restored snapshot gets this start's values.
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

// What: run pdnsutil on the auth config; text or error.
// Why: every zone and key change goes through one call.
fn pdnsutil(dir: &Path, args: &[&str]) -> Result<String, String> {
    let config_dir = format!("--config-dir={}", dir.display());
    let mut argv = vec![config_dir.as_str()];
    argv.extend_from_slice(args);
    tool("pdnsutil", &argv)
}

// What: run a tool; its stdout and stderr, or an error.
// Why: setup tools fail the launch with their own words.
// From: Issue #1683
fn tool(program: &str, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("cannot run {program}: {e}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if out.status.success() {
        Ok(text)
    } else {
        Err(format!("{program} {}: {}", args.join(" "), text.trim()))
    }
}

// What: true for pdnsutil's "exists already" refusal.
// Why: a restart finds every zone; only that is fine.
fn exists_already(error: &str) -> bool {
    error.to_ascii_lowercase().contains("exists already")
}

// What: the sqlite database, created once from schema.
// Why: Alpine's backend ships no schema; the image does.
// From: Issue #815
fn pdns_database(data_dir: &Path) -> Result<PathBuf, String> {
    let db = data_dir.join("pdns.sqlite3");
    if db.exists() {
        return Ok(db);
    }
    let schema_file = config::need(&config::process_env, "PDNS_SCHEMA_FILE")?;
    let schema = fs::read(&schema_file).map_err(|e| format!("cannot read {schema_file}: {e}"))?;
    let mut child = std::process::Command::new("sqlite3")
        .arg(&db)
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run sqlite3: {e}"))?;
    use std::io::Write as _;
    child
        .stdin
        .take()
        .ok_or("sqlite3 has no stdin")?
        .write_all(&schema)
        .map_err(|e| format!("cannot feed the schema: {e}"))?;
    let status = child.wait().map_err(|e| format!("sqlite3: {e}"))?;
    if !status.success() {
        return Err(format!("sqlite3 {} failed: {status}", db.display()));
    }
    run_ok(&["chown", "pdns:pdns", &db.display().to_string()])?;
    log(&format!("Created {}", db.display()));
    Ok(db)
}

// What: run a command; a non-zero exit is an error.
// Why: chown and friends must never fail silently.
fn run_ok(argv: &[&str]) -> Result<(), String> {
    let status = std::process::Command::new(argv[0])
        .args(&argv[1..])
        .status()
        .map_err(|e| format!("cannot run {}: {e}", argv[0]))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{} failed: {status}", argv.join(" ")))
    }
}

// What: TSIG rights for DDNS on every LAN zone.
// Why: an empty key revokes; the ui marker relaxes.
// From: Issue #815 | Issue #858
fn ddns_tsig(dir: &Path, zones: &[String], tsig: &str, unsigned: &Path) -> Result<(), String> {
    if tsig.is_empty() {
        for zone in zones {
            pdnsutil(dir, &["set-meta", zone, "TSIG-ALLOW-DNSUPDATE"])?;
        }
        if let Err(e) = pdnsutil(dir, &["delete-tsig-key", TSIG_NAME]) {
            log(&format!("No TSIG key to delete: {e}"));
        }
        log("DDNS_TSIG_KEY is empty; DDNS stays loopback-only, TSIG rights revoked");
        return Ok(());
    }
    pdnsutil(dir, &["import-tsig-key", TSIG_NAME, TSIG_ALGORITHM, tsig])?;
    let relaxed = unsigned.exists();
    if relaxed {
        log_err("WARNING: the ui allows unsigned DNS UPDATE for LAN zones");
    }
    for zone in zones {
        let mut args = vec!["set-meta", zone.as_str(), "TSIG-ALLOW-DNSUPDATE"];
        if !relaxed {
            args.push(TSIG_NAME);
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
    let zones = config::rollback_zones();
    if let (DnsRole::Secondary, Some(primary)) = (role, primary) {
        if tsig.is_empty() {
            return Err("DDNS_TSIG_KEY is required for AXFR from the primary".into());
        }
        pdnsutil(dir, &["import-tsig-key", TSIG_NAME, TSIG_ALGORITHM, tsig])?;
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
            pdnsutil(dir, &["tsigkey", "activate", zone, TSIG_NAME, "secondary"])?;
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
    ddns_tsig(dir, &zones, tsig, &ddns_unsigned_marker()?)?;
    let targets: Vec<String> = notify.iter().map(ToString::to_string).collect();
    for zone in &zones {
        pdnsutil(dir, &["zone", "set-kind", zone, "primary"])?;
        pdnsutil(dir, &["set-meta", zone, "SOA-EDIT-DNSUPDATE", "INCREASE"])?;
        pdnsutil(dir, &["set-meta", zone, "SOA-EDIT-API", "INCREASE"])?;
        pdnsutil(dir, &["set-meta", zone, "NOTIFY-DNSUPDATE", "1"])?;
        if !tsig.is_empty() {
            pdnsutil(dir, &["tsigkey", "activate", zone, TSIG_NAME, "primary"])?;
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
// From: Issue #815 | Issue #1683
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
// Why: replaces dns/entrypoint.sh; any error waits a retry.
// From: Issue #1683
fn pdns_auth(ctx: &Ctx) -> Result<Run, String> {
    let role = dns_role(&ctx.need("DNS_REPLICATION_ROLE")?)?;
    let api_key = pdns_api_key()?;
    // What: TSIG off when the shared key cannot persist.
    // Why: a key only this container knows signs nothing.
    let tsig = ddns_tsig_key().unwrap_or_else(|e| {
        log_err(&format!("WARNING: DDNS TSIG is off: {e}"));
        String::new()
    });
    // What: no key means DDNS only from loopback.
    // Why: unsigned updates from the LAN must be refused.
    let allow_from = if tsig.is_empty() {
        "127.0.0.1".to_string()
    } else {
        ctx.need("DDNS_ALLOW_FROM")?
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
    let axfr_ips = std::iter::once("127.0.0.0/8,::1".to_string())
        .chain(notify.iter().map(|t| t.ip().to_string()))
        .collect::<Vec<_>>()
        .join(",");
    let data_dir = PathBuf::from(ctx.need("PDNS_DATA_DIR")?);
    let database = pdns_database(&data_dir)?;
    let database = database.display().to_string();
    let seed = date_serial().to_string();
    let conf = AuthConf {
        local,
        database: &database,
        role,
        notify_from: &notify_from,
        axfr_ips: &axfr_ips,
        allow_from: &allow_from,
        seed_serial: &seed,
        refresh,
        retry,
        api_key: &api_key,
    };
    let dir = ctx.run_dir.join("auth");
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DNS_CONFIG_SNAPSHOT_DIR")?).join("auth"),
        "pdns.conf",
        "dns-auth",
    );
    let restamp = |old: &str| {
        restamp_lines(
            old,
            &[
                ("local-address=", format!("local-address=127.0.0.1,{local}")),
                ("api-key=", format!("api-key={api_key}")),
            ],
        )
    };
    let config_dir = format!("--config-dir={}", dir.display());
    checked_files(
        &[(dir.join("pdns.conf"), conf.render())],
        &[
            "pdns_server".into(),
            "--config=check".into(),
            config_dir.clone(),
        ],
        &store,
        &restamp,
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
// From: Issue #1072 | Issue #1073
fn rpz_zone(domains: &str, proxy: std::net::Ipv4Addr, serial: u64) -> (String, usize) {
    let mut zone = format!(
        "$ORIGIN rpz.\n$TTL 60\n@ SOA localhost. admin.rpz. {serial} 3600 900 604800 60\n\
         @ NS localhost.\n\n"
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
        zone.push_str(&format!("{owner} 60 IN A {proxy}\n"));
    }
    (zone, rows.len())
}

// What: valid cdn-domains rows as (name, wildcard-only).
// Why: dns and proxy read one file with one rule set.
// From: Issue #1072 | Issue #1683
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

// What: recursor.lua: RPZ, LAN trust anchors, root copy.
// Why: one render per recursor; the RPZ path differs.
// From: Issue #1683
fn recursor_lua(rpz: &str, zones: &[String], root_mirror: bool) -> String {
    let mut lua = format!("rpzFile(\"{rpz}\", {{ policyName=\"lancache-rpz\" }})\n");
    for zone in zones {
        lua.push_str(&format!(
            "addNTA(\"{}\", \"lancache-ng: locally forwarded, intentionally unsigned zone\")\n",
            zone.trim_end_matches('.')
        ));
    }
    if root_mirror {
        for ip in ["199.9.14.201", "192.33.4.12", "192.5.5.241"] {
            lua.push_str(&format!(
                "zoneToCache(\".\", \"axfr\", \"{ip}\", {{ refreshPeriod=3600, retryOnError=3600 }})\n"
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
    api_port: u16,
    api_key: &'a str,
    negative_ttl: u64,
    loglevel: u8,
    lua_config: &'a str,
    lua_dns: &'a str,
    zones: &'a [String],
}

impl RecursorConf<'_> {
    fn render(&self) -> String {
        let forwards: String = self
            .zones
            .iter()
            .map(|z| {
                format!(
                    "    - zone: {}\n      forwarders: [127.0.0.1:{PDNS_AUTH_PORT}]\n",
                    z.trim_end_matches('.')
                )
            })
            .collect();
        let lan =
            "    - 10.0.0.0/8\n    - 172.16.0.0/12\n    - 192.168.0.0/16\n    - 127.0.0.0/8\n";
        format!(
            "incoming:\n  listen:\n    - 0.0.0.0\n  port: {port}\n  allow_from:\n{lan}    - fc00::/7\n\
             recursor:\n  forward_zones:\n{forwards}  lua_config_file: {lua_config}\n\
             \x20 lua_dns_script: {lua_dns}\n  minimum_ttl_override: 60\n\
             recordcache:\n  max_entries: 1000000\n  refresh_on_ttl_perc: 10\n\
             \x20 serve_stale_extensions: 120\n  max_negative_ttl: {ttl}\n\
             packetcache:\n  max_entries: 500000\n  ttl: 3600\n  negative_ttl: {ttl}\n\
             \x20 servfail_ttl: 30\n\
             webservice:\n  webserver: true\n  address: 0.0.0.0\n  port: {api_port}\n\
             \x20 allow_from:\n{lan}  api_key: {key}\n\
             logging:\n  loglevel: {loglevel}\n",
            port = self.port,
            lua_config = self.lua_config,
            lua_dns = self.lua_dns,
            ttl = self.negative_ttl,
            api_port = self.api_port,
            key = self.api_key,
            loglevel = self.loglevel,
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
    let negative_ttl = if role == DnsRole::Secondary {
        XFR_CYCLE_SECS
    } else {
        120
    };
    let flag = |key: &str| env_opt(key).as_deref().and_then(config::parse_bool);
    let loglevel = if flag("LOG_QUERIES") == Some(true) {
        6
    } else {
        3
    };
    let domains_file = PathBuf::from(ctx.need("CDN_DOMAINS_FILE")?);
    let domains = fs::read_to_string(&domains_file)
        .map_err(|e| format!("cannot read {}: {e}", domains_file.display()))?;
    let dir = ctx.run_dir.join(rec.name);
    let (rpz, count) = rpz_zone(&domains, proxy, unix_secs());
    let rpz_file = dir.join("rpz.zone");
    let lua_file = dir.join("recursor.lua");
    let zones = config::rollback_zones();
    for (path, body) in [
        (&rpz_file, rpz),
        (
            &lua_file,
            recursor_lua(
                &rpz_file.display().to_string(),
                &zones,
                flag("ROOT_ZONE_MIRROR") != Some(false),
            ),
        ),
    ] {
        write_file(path, body.as_bytes(), 0o644, Place::Replace)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    }
    log(&format!("{}: RPZ holds {count} records", rec.name));
    let lua_dns = ctx.need("PDNS_LUA_DNS_SCRIPT")?;
    let conf = RecursorConf {
        port: rec.port,
        api_port: rec.api_port,
        api_key: &api_key,
        negative_ttl,
        loglevel,
        lua_config: &lua_file.display().to_string(),
        lua_dns: &lua_dns,
        zones: &zones,
    };
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DNS_CONFIG_SNAPSHOT_DIR")?).join(rec.name),
        "recursor.conf",
        "dns-recursor",
    );
    let restamp = |old: &str| restamp_lines(old, &[("api_key:", format!("  api_key: {api_key}"))]);
    let config_dir = format!("--config-dir={}", dir.display());
    checked_files(
        &[(dir.join("recursor.conf"), conf.render())],
        &[
            "pdns_recursor".into(),
            "--config=check".into(),
            config_dir.clone(),
        ],
        &store,
        &restamp,
        true,
    )?;
    Ok(Run {
        argv: vec![
            "pdns_recursor".into(),
            config_dir,
            format!("--socket-dir={}", dir.display()),
        ],
        watch: vec![domains_file],
        ..Run::default()
    })
}

// What: nats.conf from the roles, then nats-server.
// Why: the ui writes only the callout; a change restarts.
// From: Issue #811 | Issue #1683
fn nats_server(ctx: &Ctx) -> Result<Run, String> {
    let conf = ctx.need("NATS_CONF_PATH")?;
    let fragment = ctx.need("NATS_AUTH_CALLOUT_PATH")?;
    if !Path::new(&fragment).exists() {
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
    let port = ctx.need("NATS_MONITOR_PORT")?;
    let port = port
        .parse::<u16>()
        .map_err(|_| format!("NATS_MONITOR_PORT={port} is no port"))?;
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
    let mut env = vec![
        ("PDNS_API_KEY".to_string(), pdns_api_key()?),
        ("PDNS_AUTH_API_URL".to_string(), api_root(AUTH_API_PORT)),
        (
            "PDNS_REC_API_URLS".to_string(),
            [&DNS_HTTP, &DNS_HTTPS]
                .iter()
                .filter(|r| r.runs())
                .map(|r| api_root(r.api_port))
                .collect::<Vec<_>>()
                .join(" "),
        ),
        (
            "PDNS_AUTH_CONFIG_DIR".to_string(),
            ctx.run_dir.join("auth").display().to_string(),
        ),
        (
            "DNS_ROLLBACK_LISTEN_ADDR".to_string(),
            ROLLBACK_LISTEN.into(),
        ),
    ];
    // What: the writer's NATS password from the shared file.
    // Why: a remote secondary has its own; no file is used.
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
    zone: &str,
    refresh: u64,
    retry: u64,
) -> Result<(), String> {
    let root = api_root(AUTH_API_PORT);
    let rrsets = pdns.zone_rrsets(&root, zone).await?;
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
    let ttl: u64 = minimum.parse().unwrap_or(3600);
    let name = config::canonical_zone(zone);
    let body = serde_json::json!({"rrsets": [{
        "name": name, "type": "SOA", "ttl": ttl, "changetype": "REPLACE",
        "records": [{"content": format!("{mname} {rname} {next} {refresh} {retry} {expire} {minimum}"),
                     "disabled": false}]
    }]});
    let url = config::zone_url(&root, zone);
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
    let http = lancache_ng::http_client().map_err(|e| format!("HTTP client: {e}"))?;
    let pdns = lancache_ng::PowerDns::new(http, pdns_api_key()?);
    loop {
        let mut ok = 0;
        for zone in config::rollback_zones() {
            match soa_bump(&pdns, &zone, refresh, retry).await {
                Ok(()) => ok += 1,
                Err(e) => log_err(&format!("WARNING: {e}")),
            }
        }
        // What: retry soon while no zone could be written.
        // Why: a cold auth server must not wait an hour.
        let pause = if ok == 0 { 5 } else { resync };
        tokio::time::sleep(Duration::from_secs(pause)).await;
    }
}

// What: Kea's socket dir and the kea-dhcp4 control socket.
// Why: Kea accepts control sockets only below /run/kea.
const KEA_SOCKET_DIR: &str = "/run/kea";
const KEA4_SOCKET: &str = "/run/kea/kea4.sock";

// What: kea-dhcp-ddns listens here on loopback.
// Why: kea-dhcp4 sends its name change requests to it.
const KEA_NCR_PORT: u16 = 53001;

// What: networks allowed to reach the Kea control port.
// Why: the ui comes from a Docker bridge; LAN is refused.
const KEA_CTRL_ALLOWED: [&str; 2] = ["172.16.0.0/12", "127.0.0.0/8"];
const KEA_CTRL_CHAIN: &str = "LANCACHE_KEA_CTRL";

// What: the shared DDNS TSIG key; empty when it fails.
// Why: dns signs zones with it, Kea signs updates.
// From: Issue #815 | Issue #858
fn ddns_tsig_key() -> Result<String, String> {
    stack_secret(
        "DDNS_TSIG_KEY",
        &shared_secret_file_name("DDNS_TSIG_KEY"),
        base64_32,
    )
}

// What: the first file of this name below dir, by depth.
// Why: the lease_cmds hook path differs per Kea build.
fn find_file(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    let mut dirs = Vec::new();
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if entry.file_name() == name {
            return Some(path);
        }
        if depth > 0 && entry.file_type().is_ok_and(|t| t.is_dir()) {
            dirs.push(path);
        }
    }
    dirs.into_iter()
        .find_map(|d| find_file(&d, name, depth - 1))
}

// What: DHCP_NTP_SERVERS as IPv4 addresses; names resolve.
// Why: DHCP option 42 carries addresses, never names.
// From: Issue #1683
fn dhcp_ntp_servers(raw: &str) -> Result<Vec<std::net::Ipv4Addr>, String> {
    use std::net::ToSocketAddrs as _;
    raw.split([',', ' '])
        .filter(|s| !s.is_empty())
        .map(|host| {
            if let Ok(ip) = host.parse() {
                return Ok(ip);
            }
            (host, 123)
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
fn kea_loggers(loggers: &[(&str, &str)]) -> Value {
    loggers
        .iter()
        .map(|(name, severity)| {
            serde_json::json!({
                "name": name,
                "output-options": [{"output": "stdout"}],
                "severity": severity,
                "debuglevel": 0
            })
        })
        .collect()
}

// What: kea-dhcp4.conf of a first start, from the env.
// Why: afterwards the ui edits Kea through its API only.
// From: Issue #815 | Issue #1683
fn kea_dhcp4_first(ctx: &Ctx, dir: &Path) -> Result<Value, String> {
    let lease: u64 = ctx
        .need("DHCP_LEASE_TIME")?
        .parse()
        .map_err(|_| "DHCP_LEASE_TIME is no number of seconds".to_string())?;
    let domain = ctx.need("DHCP_DOMAIN")?;
    let mut options = vec![
        serde_json::json!({"name": "routers", "data": ctx.need("DHCP_GATEWAY")?}),
        serde_json::json!({
            "name": "domain-name-servers",
            "data": format!("{}, {}", ctx.need("DHCP_DNS_PRIMARY")?, ctx.need("DHCP_DNS_SECONDARY")?)
        }),
        serde_json::json!({"name": "domain-name", "data": domain}),
        serde_json::json!({"name": "domain-search", "data": domain}),
    ];
    let ntp = dhcp_ntp_servers(&env_opt("DHCP_NTP_SERVERS").unwrap_or_default())?;
    if !ntp.is_empty() {
        let list: Vec<String> = ntp.iter().map(ToString::to_string).collect();
        options.push(serde_json::json!({"name": "ntp-servers", "data": list.join(",")}));
    }
    Ok(serde_json::json!({
        "Dhcp4": {
            "interfaces-config": {"interfaces": ["*"], "re-detect": false},
            "lease-database": {
                "type": "memfile",
                "persist": true,
                "name": dir.join("kea-leases4.csv").display().to_string()
            },
            "subnet4": [{
                "id": 1,
                "subnet": ctx.need("DHCP_SUBNET")?,
                "pools": [{"pool": format!("{} - {}", ctx.need("DHCP_RANGE_START")?, ctx.need("DHCP_RANGE_END")?)}],
                "option-data": options,
                "valid-lifetime": lease,
                "max-valid-lifetime": lease * 2
            }]
        }
    }))
}

// What: set the keys the stack owns in a kea-dhcp4 config.
// Why: socket, hook, DDNS link and logs must match the image.
// From: Issue #815 | Issue #1683
fn kea_dhcp4_own(conf: &mut Value, hook: &Path, domain: &str, ddns: bool) -> Result<(), String> {
    let dhcp4 = conf
        .get_mut("Dhcp4")
        .and_then(Value::as_object_mut)
        .ok_or("the Kea config has no Dhcp4 object")?;
    dhcp4.insert(
        "control-socket".into(),
        serde_json::json!({"socket-type": "unix", "socket-name": KEA4_SOCKET}),
    );
    let lease_cmds = std::ffi::OsStr::new("libdhcp_lease_cmds.so");
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
    let defaults = [
        (
            "multi-threading",
            serde_json::json!({"enable-multi-threading": false}),
        ),
        (
            "dhcp-ddns",
            serde_json::json!({
                "enable-updates": ddns,
                "server-ip": "127.0.0.1",
                "server-port": KEA_NCR_PORT,
                "sender-ip": "127.0.0.1",
                "max-queue-size": 1024,
                "ncr-protocol": "UDP",
                "ncr-format": "JSON"
            }),
        ),
        ("ddns-send-updates", Value::Bool(true)),
        ("ddns-override-no-update", Value::Bool(true)),
        ("ddns-override-client-update", Value::Bool(true)),
        ("ddns-replace-client-name", "when-present".into()),
        ("ddns-generated-prefix", "dhcp".into()),
        ("ddns-qualifying-suffix", domain.into()),
    ];
    for (key, value) in defaults {
        dhcp4.entry(key).or_insert(value);
    }
    dhcp4.insert(
        "loggers".into(),
        kea_loggers(&[("kea-dhcp4", "INFO"), ("kea-dhcp4.dhcp4", "ERROR")]),
    );
    Ok(())
}

// What: the Kea socket dir, private to Kea.
// Why: Kea refuses a socket dir others can enter.
fn kea_socket_dir() -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::create_dir_all(KEA_SOCKET_DIR)
        .and_then(|()| fs::set_permissions(KEA_SOCKET_DIR, fs::Permissions::from_mode(0o750)))
        .map_err(|e| format!("cannot prepare {KEA_SOCKET_DIR}: {e}"))
}

// What: kea-dhcp4 on its checked config, else a snapshot.
// Why: replaces dhcp/entrypoint.sh; no good config = rescue.
// From: Issue #815 | Issue #1683
fn kea_dhcp4(ctx: &Ctx) -> Result<Run, String> {
    kea_socket_dir()?;
    let dir = PathBuf::from(ctx.need("KEA_DATA_DIR")?);
    let path = dir.join("kea-dhcp4.conf");
    let hook = find_file(Path::new("/usr/lib"), "libdhcp_lease_cmds.so", 5)
        .ok_or("libdhcp_lease_cmds.so is missing under /usr/lib")?;
    let domain = ctx.need("DHCP_DOMAIN")?;
    let ddns = env_opt("DHCP_DDNS_ENABLED")
        .as_deref()
        .and_then(config::parse_bool)
        == Some(true);
    let owned = |mut conf: Value| -> Option<String> {
        kea_dhcp4_own(&mut conf, &hook, &domain, ddns).ok()?;
        serde_json::to_string_pretty(&conf).ok()
    };
    let current = match fs::read_to_string(&path) {
        Ok(raw) => serde_json::from_str(&raw).ok(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Some(kea_dhcp4_first(ctx, &dir)?),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("KEA_CONFIG_SNAPSHOT_DIR")?),
        "dhcp4.json",
        "kea",
    );
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
fn kea_ctrl_fence(port: &str) -> Result<(), String> {
    let jump = ["-p", "tcp", "--dport", port, "-j", KEA_CTRL_CHAIN];
    if run_ok(&["iptables", "-N", KEA_CTRL_CHAIN]).is_err() {
        run_ok(&["iptables", "-F", KEA_CTRL_CHAIN])?;
    }
    while run_ok(&[&["iptables", "-D", "INPUT"][..], &jump].concat()).is_ok() {}
    run_ok(&[&["iptables", "-I", "INPUT", "1"][..], &jump].concat())?;
    for net in KEA_CTRL_ALLOWED {
        run_ok(&["iptables", "-A", KEA_CTRL_CHAIN, "-s", net, "-j", "ACCEPT"])?;
    }
    run_ok(&["iptables", "-A", KEA_CTRL_CHAIN, "-j", "DROP"])
}

// What: the Kea Control Agent behind its token and fence.
// Why: the ui manages Kea through this API alone.
// From: Issue #815 | Issue #1683
fn kea_ctrl_agent(ctx: &Ctx) -> Result<Run, String> {
    kea_socket_dir()?;
    let token = stack_secret(
        "KEA_CTRL_TOKEN",
        &shared_secret_file_name("KEA_CTRL_TOKEN"),
        hex32,
    )?;
    let port = ctx.need("KEA_CTRL_PORT")?;
    let port_number: u16 = port
        .parse()
        .map_err(|_| format!("KEA_CTRL_PORT={port} is no port"))?;
    kea_ctrl_fence(&port)?;
    let conf = serde_json::json!({
        "Control-agent": {
            "http-host": "0.0.0.0",
            "http-port": port_number,
            "authentication": {
                "type": "basic",
                "realm": "kea-control",
                "clients": [{"user": ctx.need("KEA_CTRL_USER")?, "password": token}]
            },
            "control-sockets": {
                "dhcp4": {"socket-type": "unix", "socket-name": KEA4_SOCKET}
            },
            "loggers": kea_loggers(&[("kea-ctrl-agent", "INFO")])
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
// From: Issue #1076 | Issue #1683
fn kea_dhcp_ddns(ctx: &Ctx) -> Result<Run, String> {
    kea_socket_dir()?;
    let tsig = ddns_tsig_key()?;
    let server = serde_json::json!([{
        "ip-address": ctx.need("DHCP_DNS_SERVER_IP")?,
        "port": PDNS_AUTH_PORT
    }]);
    let domain = |name: String| serde_json::json!({"name": name, "key-name": TSIG_NAME, "dns-servers": server});
    let reverse: Vec<Value> = config::rollback_zones()
        .into_iter()
        .filter(|zone| zone.ends_with(".in-addr.arpa."))
        .map(domain)
        .collect();
    let conf = serde_json::json!({
        "DhcpDdns": {
            "ip-address": "127.0.0.1",
            "port": KEA_NCR_PORT,
            "control-socket": {
                "socket-type": "unix",
                "socket-name": format!("{KEA_SOCKET_DIR}/kea-ddns.sock")
            },
            "tsig-keys": [{"name": TSIG_NAME, "algorithm": TSIG_ALGORITHM, "secret": tsig}],
            "forward-ddns": {
                "ddns-domains": [domain(config::canonical_zone(&ctx.need("DHCP_DOMAIN")?))]
            },
            "reverse-ddns": {"ddns-domains": reverse},
            "loggers": kea_loggers(&[("kea-dhcp-ddns", "INFO")])
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
// From: Issue #450 | Issue #705 | Issue #844 | Issue #1683
fn dnsmasq_conf(set: &dyn Fn(&str) -> String, relay: bool) -> String {
    let mut conf = String::from("port=0\nno-resolv\nno-poll\nlog-dhcp\nlog-facility=-\n");
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
    let secondary = Some(set("DHCP_DNS_SECONDARY"))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| primary.clone());
    let dns = format!("dhcp-option-pxe=6,{primary},{secondary}");
    dnsmasq_line(&mut conf, "DHCP_DNS_PRIMARY", &[&primary, &secondary], dns);
    let fields = [
        ("DHCP_PROXY_INTERFACE", "interface="),
        ("DHCP_PROXY_ROUTER", "dhcp-option-pxe=3,"),
        ("DHCP_NTP_SERVERS", "dhcp-option-pxe=42,"),
        ("DHCP_PROXY_DOMAIN", "dhcp-option-pxe=15,"),
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
// Why: replaces dhcp-proxy/entrypoint.sh; ui saves restart.
// From: Issue #450 | Issue #844 | Issue #1683
fn dnsmasq(ctx: &Ctx, relay: bool) -> Result<Run, String> {
    let set = |key: &str| ctx.setting(key).unwrap_or_default();
    let body = dnsmasq_conf(&set, relay);
    let path = ctx.run_dir.join("dnsmasq.conf");
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("DHCP_CONFIG_SNAPSHOT_DIR")?),
        "dnsmasq.conf",
        "dhcp-proxy",
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
    roots: Vec<String>,
    // What: wildcard-only rows below a root; *.base.
    bases: Vec<String>,
    // What: exact rows two or more labels below a root.
    exact: Vec<String>,
    // What: roots that are themselves a wildcard-only row.
    root_wildcards: HashSet<String>,
    // What: true when a row was invalid or had no root.
    skipped: bool,
}

// What: append a name once, keeping the file order.
// Why: maps and certificates list each name once.
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
const NGINX_GENERATED: &str = "# Generated by lancache-watchdog; do not edit\n";

// What: the sink for SNI-less or refused TLS clients.
// Why: the discard port closes the connection at once.
const NGINX_REFUSE: &str = "127.0.0.1:9";

// What: loopback relays of the :443 SNI dispatcher.
// Why: MITM goes to 8444 (https.conf); else passthrough.
// From: Issue #1276 | Issue #1322
const NGINX_MITM_RELAY: u16 = 9445;
const NGINX_PASSTHROUGH_RELAY: u16 = 9446;
const NGINX_MITM_PORT: u16 = 8444;

// What: one aligned "key value;" map line.
// Why: rendered maps stay readable for operators.
fn map_line(key: &str, value: &str) -> String {
    format!("    {key:<45} {value};\n")
}

// What: cert map, host allow map and client geo.
// Why: strict allows only listed hosts; CIDRs gate all.
// From: Issue #1683
fn nginx_ssl_map(hosts: &CdnHosts, strict: bool, cidrs: &[String]) -> String {
    let keys = hosts.keys();
    let mut out =
        format!("{NGINX_GENERATED}map $ssl_server_name $ssl_cert_name {{\n    hostnames;\n");
    for (key, cert) in &keys {
        out.push_str(&map_line(key, cert));
    }
    out.push_str("    default default;\n}\n\nmap $host $cdn_host_allowed {\n    hostnames;\n");
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

// What: the :8443 SNI passthrough backend map.
// Why: lazy forwards any SNI; strict only listed hosts.
// From: Issue #1683
fn nginx_stream_targets(hosts: &CdnHosts, strict: bool) -> String {
    let pass = "$ssl_preread_server_name:443";
    let mut out = format!(
        "{NGINX_GENERATED}map $ssl_preread_server_name $stream_backend {{\n    hostnames;\n{}",
        map_line("\"\"", NGINX_REFUSE)
    );
    if strict {
        out.push_str(&format!("    default {NGINX_REFUSE};\n"));
        for (key, _) in hosts.keys() {
            out.push_str(&map_line(&key, pass));
        }
    } else {
        out.push_str(&format!("    default {pass};\n"));
    }
    out.push_str("}\n");
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

// What: the :443 dispatcher: MITM, passthrough, refuse.
// Why: a cert covers one label; deeper names pass through.
// From: Issue #1276 | Issue #1322 | Issue #1683
fn nginx_ssl_dispatch(hosts: &CdnHosts, strict: bool, acl: &Path) -> String {
    let mitm = format!("127.0.0.1:{NGINX_MITM_RELAY}");
    let passthrough = format!("127.0.0.1:{NGINX_PASSTHROUGH_RELAY}");
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
        "{NGINX_GENERATED}map $ssl_preread_server_name $ssl_dispatch_backend {{\n{}",
        map_line("\"\"", NGINX_REFUSE)
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
        NGINX_REFUSE
    } else {
        passthrough.as_str()
    };
    out.push_str(&format!(
        "    default {default};\n}}\n\n\
         server {{\n    listen 443;\n    listen [::]:443;\n    include {acl};\n    \
         ssl_preread on;\n    proxy_pass $ssl_dispatch_backend;\n    proxy_protocol on;\n    \
         proxy_connect_timeout 30s;\n    proxy_timeout        3600s;\n}}\n\n\
         server {{\n    listen {mitm} proxy_protocol;\n    set_real_ip_from 127.0.0.1;\n    \
         proxy_protocol on;\n    proxy_pass 127.0.0.1:{NGINX_MITM_PORT};\n    \
         proxy_connect_timeout 30s;\n    proxy_timeout        3600s;\n}}\n\n\
         server {{\n    listen {passthrough} proxy_protocol;\n    set_real_ip_from 127.0.0.1;\n    \
         ssl_preread on;\n    proxy_pass $ssl_preread_server_name:443;\n    \
         proxy_connect_timeout 30s;\n    proxy_timeout        3600s;\n}}\n",
        acl = acl.display()
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
fn resolver_host(token: &str) -> &str {
    if let Some(rest) = token.strip_prefix('[') {
        rest.split(']').next().unwrap_or(rest)
    } else if token.matches(':').count() == 1 {
        token.split(':').next().unwrap_or(token)
    } else {
        token
    }
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

// What: set owner ids and mode on one path.
// Why: nginx workers read keys only through their group.
fn own(path: &Path, uid: Option<u32>, gid: u32, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt as _;
    std::os::unix::fs::chown(path, uid, Some(gid))
        .and_then(|()| fs::set_permissions(path, fs::Permissions::from_mode(mode)))
        .map_err(|e| format!("cannot set owner and mode of {}: {e}", path.display()))
}

// What: sign one leaf certificate with the stack CA.
// Why: the proxy presents it for an intercepted host.
// From: Issue #1683
fn sign_leaf(ca: &Path, run: &Path, key: &Path, crt: &Path, san: &str) -> Result<(), String> {
    let (csr, ext) = (run.join("leaf.csr"), run.join("leaf.ext"));
    write_file(
        &ext,
        format!("subjectAltName={san}\n").as_bytes(),
        0o600,
        Place::Replace,
    )
    .map_err(|e| format!("cannot write {}: {e}", ext.display()))?;
    let path = |p: &Path| p.display().to_string();
    let (key_s, crt_s, csr_s, ext_s) = (path(key), path(crt), path(&csr), path(&ext));
    let (ca_crt, ca_key, serial) = (
        path(&ca.join("ca.crt")),
        path(&ca.join("ca.key")),
        path(&ca.join("ca.srl")),
    );
    let signed = tool(
        "openssl",
        &[
            "req",
            "-new",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=lancache-ng",
            "-keyout",
            &key_s,
            "-out",
            &csr_s,
        ],
    )
    .and_then(|_| {
        tool(
            "openssl",
            &[
                "x509",
                "-req",
                "-days",
                "3650",
                "-in",
                &csr_s,
                "-CA",
                &ca_crt,
                "-CAkey",
                &ca_key,
                "-CAserial",
                &serial,
                "-extfile",
                &ext_s,
                "-out",
                &crt_s,
            ],
        )
    });
    let _ = fs::remove_file(&csr);
    let _ = fs::remove_file(&ext);
    if signed.is_err() {
        let _ = fs::remove_file(key);
        let _ = fs::remove_file(crt);
    }
    signed.map(|_| ())
}

// What: CA, default and per-host leaf certificates.
// Why: SSL mode intercepts TLS for every proxied host.
// From: Issue #1683
fn nginx_certs(
    nginx: &Path,
    run: &Path,
    hosts: &CdnHosts,
    ip_ssl: &str,
    gid: u32,
) -> Result<(), String> {
    let (ca, certs) = (nginx.join("ssl/ca"), nginx.join("ssl/certs"));
    let (ca_crt, ca_key) = (ca.join("ca.crt"), ca.join("ca.key"));
    let path = |p: &Path| p.display().to_string();
    if !(ca_crt.is_file() && ca_key.is_file()) {
        fs::create_dir_all(&ca).map_err(|e| format!("cannot create {}: {e}", ca.display()))?;
        tool(
            "openssl",
            &[
                "req",
                "-new",
                "-newkey",
                "rsa:4096",
                "-days",
                "3650",
                "-nodes",
                "-x509",
                "-subj",
                "/CN=LanCache-NG CA/O=LanCache-NG/C=DE",
                "-keyout",
                &path(&ca_key),
                "-out",
                &path(&ca_crt),
            ],
        )?;
        own(&ca_key, None, 0, 0o600)?;
        log(
            "ACTION REQUIRED: a new CA is in certs/ca.crt; every SSL client must install it \
             once (docs/install-ca-cert.md)",
        );
    }
    fs::create_dir_all(&certs).map_err(|e| format!("cannot create {}: {e}", certs.display()))?;
    own(&certs, None, gid, 0o2750)?;
    // What: drop every leaf when the CA changed.
    // Why: leaves of an old CA would fail on every client.
    let print = tool(
        "openssl",
        &[
            "x509",
            "-noout",
            "-fingerprint",
            "-sha256",
            "-in",
            &path(&ca_crt),
        ],
    )?;
    let stamp = certs.join(".ca-fingerprint");
    if fs::read_to_string(&stamp).ok().as_deref() != Some(print.as_str()) {
        for entry in
            fs::read_dir(&certs).map_err(|e| format!("cannot list {}: {e}", certs.display()))?
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
    let serial = ca.join("ca.srl");
    if !serial.is_file() {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        write_file(
            &serial,
            format!("{nanos:016x}\n").as_bytes(),
            0o600,
            Place::Replace,
        )
        .map_err(|e| format!("cannot write {}: {e}", serial.display()))?;
    }
    let (default_key, default_crt) = (certs.join("default.key"), certs.join("default.crt"));
    let san = tool(
        "openssl",
        &[
            "x509",
            "-noout",
            "-ext",
            "subjectAltName",
            "-in",
            &path(&default_crt),
        ],
    )
    .unwrap_or_default();
    let has_ip = ip_ssl.is_empty()
        || san
            .split([',', '\n'])
            .any(|entry| entry.trim() == format!("IP Address:{ip_ssl}"));
    if !default_key.is_file() || !san.contains("DNS:") || !has_ip {
        let mut names = "DNS:lancache-default".to_string();
        if !ip_ssl.is_empty() {
            names.push_str(&format!(",IP:{ip_ssl}"));
        }
        sign_leaf(&ca, run, &default_key, &default_crt, &names)?;
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
        if !(key.is_file() && crt.is_file()) {
            log(&format!("Generating certificate {file} for {names}"));
            sign_leaf(&ca, run, &key, &crt, &names)?;
        }
    }
    for entry in
        fs::read_dir(&certs).map_err(|e| format!("cannot list {}: {e}", certs.display()))?
    {
        let file = entry.map_err(|e| e.to_string())?.path();
        match file.extension().and_then(|x| x.to_str()) {
            Some("key") => own(&file, None, gid, 0o640)?,
            Some("crt") => own(&file, None, gid, 0o644)?,
            _ => {}
        }
    }
    Ok(())
}

// What: render, certify, check and start nginx.
// Why: replaces proxy/entrypoint.sh; a domain edit restarts.
// From: Issue #1683
fn nginx(ctx: &Ctx) -> Result<Run, String> {
    let dir = PathBuf::from(ctx.need("NGINX_DIR")?);
    let domains_file = PathBuf::from(ctx.need("CDN_DOMAINS_FILE")?);
    let read = |path: &Path| {
        fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))
    };
    let ip_standard = ctx.need("IP_STANDARD")?;
    let ip_ssl = env_opt("IP_SSL").unwrap_or_default();
    let ssl = config::parse_bool(&ctx.need("SSL_ENABLED")?).ok_or("SSL_ENABLED is no boolean")?;
    let resolver = ctx.need("NGINX_UPSTREAM_RESOLVER")?;
    // What: the upstream resolver must not be LanCache.
    // Why: the LanCache DNS would loop back (AG-OP-002).
    for token in resolver.split_whitespace().map(resolver_host) {
        if token == ip_standard || (!ip_ssl.is_empty() && token == ip_ssl) {
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
    if ssl {
        if ip_ssl.is_empty() {
            return Err("SSL_ENABLED needs IP_SSL".into());
        }
        nginx_certs(&dir, &ctx.run_dir, &hosts, &ip_ssl, worker_gid)?;
    } else if https.exists() {
        fs::remove_file(&https).map_err(|e| format!("cannot remove {}: {e}", https.display()))?;
    }
    for sub in ["conf.d", "stream.d/access.d"] {
        fs::create_dir_all(dir.join(sub))
            .map_err(|e| format!("cannot create {}: {e}", dir.join(sub).display()))?;
    }
    let healthz = dir.join("lancache-healthz-body.txt");
    write_file(&healthz, b"ok\n", 0o644, Place::Replace)
        .map_err(|e| format!("cannot write {}: {e}", healthz.display()))?;
    let value = |key: &'static str| ctx.need(key).map(|v| (key, v));
    let acl = dir.join("stream.d/access.d/00-stream-client-acl.conf");
    let conf = dir.join("nginx.conf");
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
                ],
            ),
        ),
        (
            dir.join("proxy-params.conf"),
            fill(
                &read(&dir.join("proxy-params.conf.template"))?,
                &[
                    value("CACHE_SLICE_SIZE")?,
                    value("CACHE_VALID_HIT")?,
                    value("CACHE_VALID_ANY")?,
                ],
            ),
        ),
        (
            dir.join("conf.d/00-ssl-map.conf"),
            nginx_ssl_map(&hosts, strict, &cidrs),
        ),
        (
            dir.join("stream.d/00-stream-targets.conf"),
            nginx_stream_targets(&hosts, strict),
        ),
        (acl.clone(), nginx_client_acl(&cidrs)),
        (
            dir.join("stream.d/01-ssl-dispatch.conf"),
            if ssl {
                nginx_ssl_dispatch(&hosts, strict, &acl)
            } else {
                NGINX_GENERATED.to_string()
            },
        ),
    ];
    let store = lancache_ng::SnapshotStore::new(
        PathBuf::from(ctx.need("PROXY_CONFIG_SNAPSHOT_DIR")?),
        "nginx.json",
        "proxy",
    );
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
        !hosts.skipped,
    )?;
    // What: the log dir is setgid to the log reader gid.
    // Why: the ui reads access.log through that group.
    // From: Issue #1427
    let logs = PathBuf::from(ctx.need("PROXY_LOG_DIR")?);
    let reader: u32 = ctx
        .need("PROXY_LOG_GID")?
        .parse()
        .map_err(|e| format!("PROXY_LOG_GID: {e}"))?;
    let worker_uid = account_id("passwd", &worker)?;
    fs::create_dir_all(&logs).map_err(|e| format!("cannot create {}: {e}", logs.display()))?;
    own(&logs, Some(worker_uid), reader, 0o2750)?;
    for entry in fs::read_dir(&logs).map_err(|e| format!("cannot list {}: {e}", logs.display()))? {
        let file = entry.map_err(|e| e.to_string())?.path();
        if file.is_file() {
            own(&file, Some(worker_uid), reader, 0o640)?;
        }
    }
    Ok(Run {
        argv: vec!["nginx".into(), "-g".into(), "daemon off;".into()],
        watch: vec![domains_file],
        ..Run::default()
    })
}

// What: DHCP client and server UDP ports (RFC 2131).
// Why: the probe binds the client port and talks to servers
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_SERVER_PORT: u16 = 67;

// What: how long offers are collected after a DISCOVER.
// Why: every offering server counts, so the window runs out
const DISCOVER_WINDOW: Duration = Duration::from_secs(5);

// What: how long the REQUEST waits for an ACK or NAK.
// Why: a server that just offered should answer at once.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

// What: DISCOVER sends within one window, spread evenly.
// Why: one dropped broadcast must not read as a clear LAN.
const DISCOVER_RETRANSMITS: u32 = 3;

// What: option fields shown per offer, as (label, code).
// Why: None is the offered address; the rest are options.
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
struct Offer {
    address: Option<Ipv4Addr>,
    server: Option<Ipv4Addr>,
    details: Vec<Detail>,
}

// What: read an OFFER or ACK into address, server, rows.
// Why: both message types carry the same option set.
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
fn is_kind(msg: &Message, kind: MessageType) -> bool {
    matches!(msg.opts().get(OptionCode::MessageType), Some(DhcpOption::MessageType(t)) if t == &kind)
}

// What: build a DHCP message of one type.
// Why: DISCOVER, REQUEST and RELEASE differ only in options
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
fn send_dhcp(socket: &UdpSocket, msg: &Message, to: SocketAddrV4) -> io::Result<()> {
    let mut buffer = Vec::new();
    msg.encode(&mut Encoder::new(&mut buffer))
        .map_err(io::Error::other)?;
    socket.send_to(&buffer, to).map(|_| ())
}

// What: feed replies of one exchange to a handler.
// Why: stops at the deadline or when the handler says done.
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
            Ok((n, _)) => {
                if let Ok(msg) = Message::decode(&mut Decoder::new(&buffer[..n]))
                    && msg.xid() == xid
                    && handle(&msg)
                {
                    return Ok(());
                }
            }
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
fn dry_run(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    offer: &Offer,
    destination: SocketAddrV4,
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
    let heard = listen(socket, xid, Instant::now() + REQUEST_TIMEOUT, |msg| {
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
    if let Some(leased) = ack.address {
        let release = dhcp_message(
            rand::random(),
            chaddr,
            leased,
            MessageType::Release,
            vec![DhcpOption::ServerIdentifier(server)],
        );
        let _ = send_dhcp(
            socket,
            &release,
            SocketAddrV4::new(server, DHCP_SERVER_PORT),
        );
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
fn run_probe() -> ProbeReport {
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
    let xid: u32 = rand::random();
    // What: a random locally administered unicast MAC.
    // Why: the probe must not look like a real device.
    let mut chaddr: [u8; 6] = rand::random();
    chaddr[0] = (chaddr[0] | 0x02) & !0x01;

    let discover = dhcp_message(
        xid,
        &chaddr,
        Ipv4Addr::UNSPECIFIED,
        MessageType::Discover,
        vec![request_list()],
    );
    let end = Instant::now() + DISCOVER_WINDOW;
    let mut offers: Vec<Offer> = Vec::new();
    for attempt in 1..=DISCOVER_RETRANSMITS {
        if let Err(e) = send_dhcp(&socket, &discover, destination) {
            return ProbeReport::unavailable(format!("failed to broadcast DHCPDISCOVER: {e}"));
        }
        let slice = Instant::now() + DISCOVER_WINDOW / DISCOVER_RETRANSMITS;
        let until = if attempt == DISCOVER_RETRANSMITS {
            end
        } else {
            slice.min(end)
        };
        // What: a failed read ends the slice only.
        // Why: later retransmits may still collect offers.
        let _ = listen(&socket, xid, until, |msg| {
            if is_kind(msg, MessageType::Offer) {
                let offer = read_offer(msg);
                // What: count each server once.
                // Why: answering twice is no second rogue.
                let seen = offers
                    .iter()
                    .any(|o| o.server.is_some() && o.server == offer.server);
                if !seen {
                    offers.push(offer);
                }
            }
            false
        });
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
                DISCOVER_WINDOW.as_secs_f64()
            ),
        },
        Some(first) => dry_run(&socket, xid, &chaddr, first, destination),
    };
    ProbeReport { conflict, client }
}

// What: answer each new probe request with one probe run.
// Why: the ui has no Docker; the dhcp container probes.
// From: Issue #947 | Issue #1683
async fn probe_upkeep() -> Result<(), String> {
    let need = |key: &str| config::need(&config::process_env, key);
    let request = PathBuf::from(need("DHCP_PROBE_REQUEST_FILE")?);
    let answer = PathBuf::from(need("DHCP_PROBE_RESULT_FILE")?);
    let read_id = || {
        fs::read_to_string(&answer)
            .ok()
            .and_then(|raw| serde_json::from_str::<ProbeAnswer>(&raw).ok())
            .map(|a| a.id)
    };
    let mut answered = read_id();
    loop {
        tokio::time::sleep(TICK).await;
        let Ok(id) = fs::read_to_string(&request) else {
            continue;
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
struct Slot {
    kind: Kind,
    // What: watched inputs and their state at the start.
    // Why: a differing state restarts the program.
    watch: Vec<PathBuf>,
    seen: Vec<Option<(u64, i64, i64)>>,
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
        settings_file: env_opt("UI_SETTINGS_FILE").map(PathBuf::from),
        desired_file: env_opt("DESIRED_STATE_FILE").map(PathBuf::from),
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
            watch: Vec::new(),
            seen: Vec::new(),
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
            } else if slot.running() && (!wanted || fingerprint(&slot.watch) != slot.seen) {
                // What: a wanted program restarts next tick.
                // Why: its input changed; it must read it anew.
                if wanted {
                    log(&format!("{}: input changed; restarting", slot.kind.name()));
                }
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
    use std::net::SocketAddr;

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

    // What: the netdata sender script comes from fields.
    // Why: netdata and the ui must agree on the payload.
    // From: Issue #858
    #[test]
    fn alarm_sender_script_names_every_field() {
        let script = alarm_notify_conf("http://ui:8080", "/t/token").unwrap();
        assert!(script.starts_with(&format!(
            "SEND_CUSTOM=\"YES\"\nDEFAULT_RECIPIENT_CUSTOM=\"{NETDATA_ALARM_RECIPIENT}\"\n"
        )));
        assert!(script.contains("token=\"$(cat \"/t/token\")\" || return 1"));
        assert!(script.contains(&format!(
            "docurl --max-time {NETDATA_ALARM_MAX_TIME} -X POST"
        )));
        assert!(script.contains(&format!("-H \"{ALARM_TOKEN_HEADER}: ${{token}}\"")));
        assert!(script.contains(&format!("\"http://ui:8080{ALARM_INGEST_PATH}\")\" || {{")));
        assert!(script.contains("case \"${httpcode}\" in 2??) return 0 ;; esac"));
        let fields = r#"-d "{\"alarm_id\":${alarm_id},\"chart\":\"$(_lancache_json_escape "${chart}")\",\"duration\":${duration},\"event_id\":${event_id},\"host\":\"$(_lancache_json_escape "${host}")\",\"info\":\"$(_lancache_json_escape "${info}")\",\"name\":\"$(_lancache_json_escape "${name}")\",\"old_status\":\"$(_lancache_json_escape "${old_status}")\",\"status\":\"$(_lancache_json_escape "${status}")\",\"unique_id\":${unique_id},\"units\":\"$(_lancache_json_escape "${units}")\",\"value_string\":\"$(_lancache_json_escape "${value_string}")\",\"when\":${when}}""#;
        assert!(script.contains(fields), "{script}");
        for (url, file) in [
            ("", "/t"),
            ("http://ui", ""),
            ("http://ui", "/t y"),
            ("http://u\"i", "/t"),
        ] {
            assert!(alarm_notify_conf(url, file).is_err());
        }
    }

    // What: the web_log job parses the cache log_format.
    // Why: a wrong pattern collects nothing and fails quiet.
    // From: Issue #1246
    #[test]
    fn web_log_job_reads_the_cache_log_format() {
        let path = format!("/{}/{}.log", gen_name(), gen_name());
        let conf = web_log_conf(&path).expect("conf");
        assert!(conf.contains(&format!("    path: {path}\n    log_type: regexp\n")));
        assert!(conf.contains(&format!("      pattern: '{NGINX_CACHE_LOG_PATTERN}'\n")));
        let nginx =
            fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../proxy/nginx.conf"))
                .expect("nginx.conf");
        assert!(nginx.contains(
            "log_format cache '$remote_addr - [$time_local] \"$request\" '\n                     '$status $body_bytes_sent '\n                     '\"$upstream_cache_status\" \"$host\"';"
        ));
        for bad in ["relative.log", "/a b", "/a'b", "/a\nb"] {
            assert!(web_log_conf(bad).is_err(), "{bad:?}");
        }
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

    // What: a random IPv4 address for a proxy IP.
    // Why: render tests must not depend on one address.
    fn gen_ipv4() -> std::net::Ipv4Addr {
        std::net::Ipv4Addr::from(rnd(1, u32::MAX.into()) as u32)
    }

    // What: plain, wildcard, disabled and junk RPZ rows.
    // Why: a bare TLD or "!" row must never redirect.
    // From: Issue #1072 | Issue #1073
    #[test]
    fn rpz_zone_maps_valid_rows_to_the_proxy() {
        let (host, wild, off) = (gen_name(), gen_name(), gen_name());
        let ip = gen_ipv4();
        let serial = rnd(1, u32::MAX.into());
        let rows =
            format!("# c\n\n{host}.example\n .{wild}.EXAMPLE \n!{off}.example\ncom\nb@d.example\n");
        let (zone, count) = rpz_zone(&rows, ip, serial);
        assert_eq!(count, 2, "{zone}");
        assert!(
            zone.contains(&format!("\n{host}.example 60 IN A {ip}\n")),
            "{zone}"
        );
        assert!(
            zone.contains(&format!("\n*.{wild}.example 60 IN A {ip}\n")),
            "{zone}"
        );
        assert!(
            zone.contains(&format!(" {serial} 3600 900 604800 60\n")),
            "{zone}"
        );
        assert!(!zone.contains(&off) && !zone.contains("\ncom ") && !zone.contains("b@d"));
    }

    // What: PSL rules, wildcards, exceptions, private end.
    // Why: a wrong root splits or merges CDN certificates.
    // From: Issue #1683
    #[test]
    fn psl_root_follows_rules_wildcards_and_exceptions() {
        let [tld, sld, wild, except, private, a, b, c] = std::array::from_fn(|_| gen_name());
        let psl = Psl::parse(&format!(
            "// c\n{tld}\n{sld}.{tld}\n*.{wild}\n!{except}.{wild}\n\
             // ===BEGIN PRIVATE DOMAINS===\n{private}.{tld}\n"
        ));
        assert_eq!(
            psl.root(&format!("{a}.{b}.{tld}")),
            Some(format!("{b}.{tld}"))
        );
        assert_eq!(
            psl.root(&format!("{a}.{b}.{sld}.{tld}")),
            Some(format!("{b}.{sld}.{tld}"))
        );
        assert_eq!(psl.root(&format!("{sld}.{tld}")), None);
        assert_eq!(
            psl.root(&format!("{a}.{b}.{c}.{wild}")),
            Some(format!("{b}.{c}.{wild}"))
        );
        assert_eq!(
            psl.root(&format!("{a}.{except}.{wild}")),
            Some(format!("{except}.{wild}"))
        );
        assert_eq!(
            psl.root(&format!("{a}.{private}.{tld}")),
            Some(format!("{private}.{tld}"))
        );
        assert_eq!(psl.root(&format!("{a}.{b}")), Some(format!("{a}.{b}")));
    }

    // What: rows become roots, bases and exact hosts.
    // Why: one label below a root is covered by *.root.
    // From: Issue #1683
    #[test]
    fn cdn_hosts_sort_rows_by_cover() {
        let [tld, r1, r2, r3, a, b, c] = std::array::from_fn(|_| gen_name());
        let psl = Psl::parse(&format!("{tld}\n"));
        let rows = format!(
            "# c\n{a}.{r1}.{tld}\n.{r1}.{tld}\n.{b}.{r2}.{tld}\n{a}.{b}.{r3}.{tld}\n\
             {r3}.{tld}\n!{c}.{tld}\n{tld}\n"
        );
        let hosts = cdn_hosts(&rows, &psl);
        let names = |v: &[&str]| v.iter().map(|n| format!("{n}.{tld}")).collect::<Vec<_>>();
        assert_eq!(hosts.roots, names(&[&r1, &r2, &r3]));
        assert_eq!(hosts.bases, names(&[&format!("{b}.{r2}")]));
        assert_eq!(hosts.exact, names(&[&format!("{a}.{b}.{r3}")]));
        assert_eq!(hosts.root_wildcards, HashSet::from([format!("{r1}.{tld}")]));
        assert!(hosts.skipped, "the bare TLD row must count as skipped");
    }

    // What: strict lists hosts; lazy and CIDR defaults.
    // Why: strict must refuse every unlisted name.
    // From: Issue #1683
    #[test]
    fn nginx_maps_follow_mode_and_cidrs() {
        let [root, base, cidr] = std::array::from_fn(|_| gen_name());
        let hosts = CdnHosts {
            roots: vec![root.clone()],
            bases: vec![base.clone()],
            ..CdnHosts::default()
        };
        let strict = nginx_ssl_map(&hosts, true, std::slice::from_ref(&cidr));
        assert!(strict.contains(&map_line(&format!("*.{root}"), &root)));
        assert!(strict.contains(&map_line(
            &format!("*.{base}"),
            &cert_name(&base, "wildcard")
        )));
        assert!(strict.contains("    default 0;\n") && strict.contains(&map_line(&cidr, "1")));
        let lazy = nginx_ssl_map(&hosts, false, &[]);
        assert_eq!(lazy.matches("    default 1;\n").count(), 2, "{lazy}");
        assert!(
            nginx_stream_targets(&hosts, false).contains("default $ssl_preread_server_name:443;")
        );
        assert!(nginx_stream_targets(&hosts, true).contains(&format!("default {NGINX_REFUSE};")));
        assert_eq!(nginx_client_acl(&[]), NGINX_GENERATED);
        assert!(
            nginx_client_acl(std::slice::from_ref(&cidr))
                .ends_with(&format!("allow {cidr};\ndeny all;\n"))
        );
    }

    // What: deeper names pass through, longest base first.
    // Why: a cert covers one label; regex order decides.
    // From: Issue #1276 | Issue #1683
    #[test]
    fn nginx_dispatch_orders_bases_longest_first() {
        let [root, short, long] = std::array::from_fn(|_| gen_name());
        let long = format!("{long}.{long}.{root}");
        let hosts = CdnHosts {
            roots: vec![root.clone()],
            bases: vec![format!("{short}.{root}"), long.clone()],
            ..CdnHosts::default()
        };
        let out = nginx_ssl_dispatch(&hosts, false, Path::new("/acl"));
        let at = |name: &str| {
            out.find(&format!("\"~^.+\\.{}$\"", name.replace('.', "\\.")))
                .expect(name)
        };
        assert!(at(&long) < at(&format!("{short}.{root}")), "{out}");
        assert!(out.contains(&format!(
            "    default 127.0.0.1:{NGINX_PASSTHROUGH_RELAY};\n"
        )));
        assert!(out.contains("    include /acl;\n"));
        let strict = nginx_ssl_dispatch(&hosts, true, Path::new("/acl"));
        assert!(strict.contains(&format!("    default {NGINX_REFUSE};\n")));
    }

    // What: template keys, resolver tokens, account ids.
    // Why: each feeds nginx or chown verbatim.
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

    // What: a failing set rolls back to the last snapshot.
    // Why: nginx must start from a set that passed -t.
    // From: Issue #415 | Issue #1683
    #[test]
    fn checked_files_roll_back_a_failing_set() {
        let root = scratch();
        let (one, two) = (root.join(gen_name()), root.join(gen_name()));
        let [good, bad, other] = std::array::from_fn(|_| gen_name());
        let store = lancache_ng::SnapshotStore::new(root.join("snap"), "set.json", "test");
        let name = |p: &Path| p.file_name().unwrap().to_string_lossy().into_owned();
        let set = serde_json::json!({ name(&one): good, name(&two): other });
        store.create(&set, 3).expect("snapshot");
        let check: Vec<String> = ["grep", "-q", good.as_str(), &one.display().to_string()]
            .map(String::from)
            .to_vec();
        let files = [(one.clone(), bad), (two.clone(), gen_name())];
        checked_files(&files, &check, &store, &|old| old.to_string(), false).expect("rollback");
        assert_eq!(fs::read_to_string(&one).unwrap(), good);
        assert_eq!(fs::read_to_string(&two).unwrap(), other);
        let empty = lancache_ng::SnapshotStore::new(root.join("none"), "set.json", "test");
        assert!(checked_files(&files, &check, &empty, &|old| old.to_string(), false).is_err());
    }

    // What: lua names the RPZ file, every zone, the root.
    // Why: a missing NTA breaks DNSSEC for LAN names.
    #[test]
    fn recursor_lua_lists_rpz_zones_and_root_copy() {
        let rpz = gen_path();
        let zones = config::rollback_zones();
        let lua = recursor_lua(&rpz, &zones, true);
        assert!(lua.starts_with(&format!("rpzFile(\"{rpz}\"")), "{lua}");
        for zone in &zones {
            assert!(lua.contains(&format!("addNTA(\"{}\"", zone.trim_end_matches('.'))));
        }
        assert_eq!(lua.matches("zoneToCache").count(), 3);
        assert!(!recursor_lua(&rpz, &zones, false).contains("zoneToCache"));
    }

    // What: recursor.conf carries ports, key, TTL, zones.
    // Why: dns-http and dns-https differ only in these.
    #[test]
    fn recursor_conf_renders_its_inputs() {
        let zones = config::rollback_zones();
        let (key, lua_c, lua_d) = (gen_name(), gen_path(), gen_path());
        let ttl = rnd(1, DAY);
        for rec in [&DNS_HTTP, &DNS_HTTPS] {
            let conf = RecursorConf {
                port: rec.port,
                api_port: rec.api_port,
                api_key: &key,
                negative_ttl: ttl,
                loglevel: 6,
                lua_config: &lua_c,
                lua_dns: &lua_d,
                zones: &zones,
            }
            .render();
            for want in [
                format!("  port: {}\n", rec.port),
                format!("  port: {}\n", rec.api_port),
                format!("  api_key: {key}\n"),
                format!("  negative_ttl: {ttl}\n"),
                format!("  lua_config_file: {lua_c}\n"),
                format!("  lua_dns_script: {lua_d}\n"),
                format!("forwarders: [127.0.0.1:{PDNS_AUTH_PORT}]"),
                "  loglevel: 6\n".to_string(),
            ] {
                assert!(conf.contains(&want), "{want:?} missing in {conf}");
            }
            assert_eq!(conf.matches("    - zone: ").count(), zones.len());
        }
    }

    // What: pdns.conf follows the role and its inputs.
    // Why: a secondary must never act as a primary.
    #[test]
    fn auth_conf_renders_role_and_inputs() {
        let (db, key, allow, seed) = (gen_path(), gen_name(), gen_name(), gen_name());
        let local = gen_ipv4();
        let refresh = rnd(10, DAY);
        for (role, primary, secondary) in [
            (DnsRole::Primary, "yes", "no"),
            (DnsRole::Secondary, "no", "yes"),
        ] {
            let conf = AuthConf {
                local,
                database: &db,
                role,
                notify_from: "",
                axfr_ips: "127.0.0.0/8,::1",
                allow_from: &allow,
                seed_serial: &seed,
                refresh,
                retry: refresh - 1,
                api_key: &key,
            }
            .render();
            for want in [
                format!("local-address=127.0.0.1,{local}\n"),
                format!("gsqlite3-database={db}\n"),
                format!("primary={primary}\nsecondary={secondary}\n"),
                format!("allow-dnsupdate-from={allow}\n"),
                format!("admin.@ {seed} {refresh} {} 604800", refresh - 1),
                format!("api-key={key}\n"),
            ] {
                assert!(conf.contains(&want), "{want:?} missing in {conf}");
            }
        }
    }

    // What: restamp swaps keyed lines, keeps the rest.
    // Why: a restored snapshot must use this start's key.
    #[test]
    fn restamp_replaces_only_keyed_lines() {
        let (old, new, other) = (gen_name(), gen_name(), gen_name());
        let text = format!("a={other}\n  api_key: {old}\nb=1");
        let out = restamp_lines(&text, &[("api_key:", format!("  api_key: {new}"))]);
        assert_eq!(out, format!("a={other}\n  api_key: {new}\nb=1\n"));
    }

    // What: roles parse; others and IPv4 endpoints.
    // Why: an unknown role or a bad endpoint must not start.
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

    // What: a test OFFER with a server's option set.
    // Why: read_offer must show exactly the fields present.
    fn offer_message(xid: u32, kind: MessageType, yiaddr: Ipv4Addr, server: Ipv4Addr) -> Message {
        let mut msg = dhcp_message(
            xid,
            &[2, 0, 0, 0, 0, 1],
            Ipv4Addr::UNSPECIFIED,
            kind,
            vec![],
        );
        msg.set_yiaddr(yiaddr);
        let extra = [
            DhcpOption::ServerIdentifier(server),
            DhcpOption::AddressLeaseTime(3600),
            DhcpOption::Renewal(1800),
            DhcpOption::Rebinding(3150),
            DhcpOption::SubnetMask(Ipv4Addr::new(255, 255, 255, 0)),
            DhcpOption::Router(vec![Ipv4Addr::new(10, 0, 0, 1), Ipv4Addr::new(10, 0, 0, 2)]),
            DhcpOption::DomainNameServer(vec![
                Ipv4Addr::new(10, 0, 0, 3),
                Ipv4Addr::new(10, 0, 0, 4),
            ]),
            DhcpOption::DomainName("lan.example".to_string()),
            DhcpOption::BroadcastAddr(Ipv4Addr::new(10, 0, 0, 255)),
        ];
        for option in extra {
            msg.opts_mut().insert(option);
        }
        msg
    }

    // What: an OFFER becomes address, server and rows.
    // Why: REQUEST needs address and server; page, rows.
    #[test]
    fn dhcp_offers_become_labelled_rows() {
        let server = Ipv4Addr::new(10, 0, 0, 9);
        let msg = offer_message(5, MessageType::Offer, Ipv4Addr::new(10, 0, 0, 50), server);
        let offer = read_offer(&msg);
        assert_eq!(offer.address, Some(Ipv4Addr::new(10, 0, 0, 50)));
        assert_eq!(offer.server, Some(server));
        let rows: Vec<(&str, &str)> = offer
            .details
            .iter()
            .map(|d| (d.label.as_str(), d.value.as_str()))
            .collect();
        assert_eq!(
            rows,
            [
                ("Server Identifier", "10.0.0.9"),
                ("IP Offered", "10.0.0.50"),
                ("IP Address Lease Time (seconds)", "3600"),
                ("Renewal Time (seconds)", "1800"),
                ("Rebinding Time (seconds)", "3150"),
                ("Subnet Mask", "255.255.255.0"),
                ("Router", "10.0.0.1"),
                ("Domain Name Server", "10.0.0.3, 10.0.0.4"),
                ("Domain Name", "lan.example"),
                ("Broadcast Address", "10.0.0.255"),
            ]
        );
        let bare = dhcp_message(
            1,
            &[2, 0, 0, 0, 0, 2],
            Ipv4Addr::UNSPECIFIED,
            MessageType::Offer,
            vec![],
        );
        let none = read_offer(&bare);
        assert!(none.address.is_none() && none.server.is_none() && none.details.is_empty());
        assert!(is_kind(&msg, MessageType::Offer));
        assert!(!is_kind(&msg, MessageType::Ack));
        assert!(!is_kind(&Message::default(), MessageType::Offer));
    }

    // What: probe messages carry type, flags and options.
    // Why: RELEASE has a client address and no broadcast.
    #[test]
    fn dhcp_messages_carry_type_flags_and_options() {
        let mac = [2, 1, 2, 3, 4, 5];
        let discover = dhcp_message(
            7,
            &mac,
            Ipv4Addr::UNSPECIFIED,
            MessageType::Discover,
            vec![request_list()],
        );
        assert_eq!(discover.xid(), 7);
        assert!(discover.flags().broadcast());
        assert!(is_kind(&discover, MessageType::Discover));
        assert_eq!(&discover.chaddr()[..6], &mac);
        let release = dhcp_message(
            8,
            &mac,
            Ipv4Addr::new(10, 0, 0, 5),
            MessageType::Release,
            vec![],
        );
        assert!(!release.flags().broadcast());
        assert_eq!(release.ciaddr(), Ipv4Addr::new(10, 0, 0, 5));
        let DhcpOption::ParameterRequestList(codes) = request_list() else {
            panic!("a parameter request list");
        };
        assert_eq!(
            codes,
            [
                OptionCode::AddressLeaseTime,
                OptionCode::Renewal,
                OptionCode::Rebinding,
                OptionCode::SubnetMask,
                OptionCode::Router,
                OptionCode::DomainNameServer,
                OptionCode::DomainName,
                OptionCode::BroadcastAddr
            ]
        );
    }

    // What: a message goes out over UDP, heard by xid.
    // Why: others share the broadcast domain.
    #[test]
    fn dhcp_listening_filters_by_transaction() {
        let receiver = UdpSocket::bind("127.0.0.1:0").unwrap();
        let SocketAddr::V4(to) = receiver.local_addr().unwrap() else {
            panic!("ipv4")
        };
        let sender = UdpSocket::bind("127.0.0.1:0").unwrap();
        let other = dhcp_message(
            1,
            &[2; 6],
            Ipv4Addr::UNSPECIFIED,
            MessageType::Offer,
            vec![],
        );
        let ours = dhcp_message(2, &[2; 6], Ipv4Addr::UNSPECIFIED, MessageType::Ack, vec![]);
        send_dhcp(&sender, &other, to).unwrap();
        send_dhcp(&sender, &ours, to).unwrap();
        let mut seen = Vec::new();
        let until = Instant::now() + Duration::from_secs(2);
        listen(&receiver, 2, until, |msg| {
            seen.push(is_kind(msg, MessageType::Ack));
            true
        })
        .unwrap();
        assert_eq!(seen, [true]);
        let mut calls = 0;
        send_dhcp(&sender, &ours, to).unwrap();
        listen(
            &receiver,
            2,
            Instant::now() + Duration::from_millis(300),
            |_| {
                calls += 1;
                false
            },
        )
        .unwrap();
        assert_eq!(calls, 1);
        let late = Instant::now();
        listen(&receiver, 2, late, |_| panic!("no wait past the deadline")).unwrap();
    }

    // What: a stand-in DHCP server for the dry run.
    // Why: the client side is tested without a network.
    fn dry_run_server(
        reply: Option<(MessageType, Ipv4Addr)>,
    ) -> (SocketAddrV4, std::thread::JoinHandle<Option<Message>>) {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let SocketAddr::V4(addr) = server.local_addr().unwrap() else {
            panic!("ipv4")
        };
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 1500];
            let (n, from) = server.recv_from(&mut buf).ok()?;
            let request = Message::decode(&mut Decoder::new(&buf[..n])).ok()?;
            if let Some((kind, server_id)) = reply {
                let answer =
                    offer_message(request.xid(), kind, Ipv4Addr::new(10, 0, 0, 50), server_id);
                send_dhcp(
                    &server,
                    &answer,
                    match from {
                        SocketAddr::V4(v4) => v4,
                        SocketAddr::V6(_) => return None,
                    },
                )
                .ok()?;
            }
            Some(request)
        });
        (addr, handle)
    }

    fn offer_for(server: Ipv4Addr) -> Offer {
        Offer {
            address: Some(Ipv4Addr::new(10, 0, 0, 50)),
            server: Some(server),
            details: vec![],
        }
    }

    // What: the dry run requests the offer, reads the ACK.
    // Why: it proves a client can get a lease.
    #[test]
    fn dry_run_passes_on_an_ack_from_the_offering_server() {
        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        let server_ip = Ipv4Addr::new(10, 0, 0, 9);
        let (addr, handle) = dry_run_server(Some((MessageType::Ack, server_ip)));
        let check = dry_run(&client, 77, &[2; 6], &offer_for(server_ip), addr);
        let ClientCheck::Passed { output, details } = check else {
            panic!("passed")
        };
        assert_eq!(output, "DHCP client dry-run succeeded, assigned 10.0.0.50");
        assert_eq!(details.len(), 10);
        let request = handle.join().unwrap().unwrap();
        assert_eq!(request.xid(), 77);
        assert!(is_kind(&request, MessageType::Request));
        assert_eq!(
            request.opts().get(OptionCode::RequestedIpAddress),
            Some(&DhcpOption::RequestedIpAddress(Ipv4Addr::new(10, 0, 0, 50)))
        );
        assert_eq!(
            request.opts().get(OptionCode::ServerIdentifier),
            Some(&DhcpOption::ServerIdentifier(server_ip))
        );
        assert!(
            request
                .opts()
                .get(OptionCode::ParameterRequestList)
                .is_some()
        );
    }

    // What: the dry run fails clearly on NAK or bad input.
    // Why: the page tells the operator what went wrong.
    #[test]
    fn dry_run_fails_with_the_reason() {
        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        let server_ip = Ipv4Addr::new(10, 0, 0, 9);
        let (addr, _handle) = dry_run_server(Some((MessageType::Nak, server_ip)));
        let nak = dry_run(&client, 5, &[2; 6], &offer_for(server_ip), addr);
        let ClientCheck::Failed { output } = nak else {
            panic!("failed")
        };
        assert_eq!(output, "server sent DHCPNAK for the requested address");
        let missing = Offer {
            address: None,
            server: Some(server_ip),
            details: vec![],
        };
        let (addr, _handle) = dry_run_server(None);
        let ClientCheck::Failed { output } = dry_run(&client, 5, &[2; 6], &missing, addr) else {
            panic!("failed")
        };
        assert!(
            output.starts_with("the DHCPOFFER was missing a requested IP or server identifier")
        );
        let no_server = Offer {
            address: Some(Ipv4Addr::new(10, 0, 0, 5)),
            server: None,
            details: vec![],
        };
        assert!(matches!(
            dry_run(&client, 5, &[2; 6], &no_server, addr),
            ClientCheck::Failed { .. }
        ));
    }

    // What: a wrong-server ACK or silence times out.
    // Why: only the offering server's ACK counts.
    #[test]
    fn dry_run_times_out_on_silence_or_a_foreign_ack() {
        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        let server_ip = Ipv4Addr::new(10, 0, 0, 9);
        let (addr, _handle) = dry_run_server(Some((MessageType::Ack, Ipv4Addr::new(10, 0, 0, 77))));
        let ClientCheck::Failed { output } =
            dry_run(&client, 5, &[2; 6], &offer_for(server_ip), addr)
        else {
            panic!("failed")
        };
        assert_eq!(
            output,
            "received an ACK, but not from the expected server identifier"
        );
        let (addr, _handle) = dry_run_server(None);
        let ClientCheck::Failed { output } =
            dry_run(&client, 6, &[2; 6], &offer_for(server_ip), addr)
        else {
            panic!("failed")
        };
        assert_eq!(output, "no ACK received before the timeout");
    }

    // What: every SOT process list parses to its kinds.
    // Why: a name the supervisor lacks fails the image.
    // From: Issue #1683
    #[test]
    fn sot_process_lists_name_known_kinds() {
        let sot = include_str!("../../../.github/yaml/build-manifest.yml");
        let lists: Vec<&str> = sot
            .lines()
            .filter_map(|l| l.trim().strip_prefix("processes: ["))
            .filter_map(|l| l.strip_suffix(']'))
            .collect();
        assert!(lists.len() >= 3, "{lists:?}");
        for list in lists {
            let names: Vec<&str> = list.split(',').map(str::trim).collect();
            let parsed = kinds(&names.join(" ")).expect("SOT kinds");
            let back: Vec<&str> = parsed.iter().map(|k| k.name()).collect();
            assert_eq!(back, names);
        }
    }

    // What: the stack-owned Kea keys are set, others kept.
    // Why: an operator subnet must survive a restart.
    // From: Issue #1683
    #[test]
    fn kea_config_gets_the_stack_keys_and_keeps_the_rest() {
        let hook = PathBuf::from(format!("/usr/lib/{}/libdhcp_lease_cmds.so", gen_name()));
        let mut conf = serde_json::json!({"Dhcp4": {
            "subnet4": [{"id": 7}],
            "hooks-libraries": [
                {"library": "/old/libdhcp_lease_cmds.so"},
                {"library": "/x/other.so"}
            ],
            "dhcp-ddns": {"enable-updates": true},
            "loggers": [{"name": "kea-dhcp4", "output-options": [{"output": "/f.log"}]}]
        }});
        kea_dhcp4_own(&mut conf, &hook, "lan", false).expect("own");
        let d = &conf["Dhcp4"];
        assert_eq!(d["subnet4"][0]["id"], 7);
        assert_eq!(d["control-socket"]["socket-name"], KEA4_SOCKET);
        let libs: Vec<&str> = d["hooks-libraries"]
            .as_array()
            .expect("hooks")
            .iter()
            .filter_map(|h| h["library"].as_str())
            .collect();
        assert_eq!(libs, ["/x/other.so", hook.to_str().expect("utf8")]);
        assert_eq!(d["dhcp-ddns"]["enable-updates"], true);
        assert_eq!(d["ddns-qualifying-suffix"], "lan");
        assert_eq!(d["loggers"][0]["output-options"][0]["output"], "stdout");
        assert_eq!(d["loggers"].as_array().map(Vec::len), Some(2));
        assert!(kea_dhcp4_own(&mut serde_json::json!({}), &hook, "lan", false).is_err());
    }

    // What: NTP names resolve; IPs pass; both separators.
    // Why: DHCP option 42 carries addresses only.
    #[test]
    fn dhcp_ntp_servers_are_ipv4_addresses() {
        let a = gen_ipv4();
        let b = gen_ipv4();
        let got = dhcp_ntp_servers(&format!("{a}, {b}")).expect("ips");
        assert_eq!(got, [a, b]);
        assert!(dhcp_ntp_servers("").expect("empty").is_empty());
        assert_eq!(
            dhcp_ntp_servers("localhost").expect("local"),
            [Ipv4Addr::LOCALHOST]
        );
    }

    // What: files are found below a dir, depth limited.
    // Why: the Kea hook path differs per build.
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

    // What: dnsmasq proxy and relay configs from settings.
    // Why: one line per set value; a line break is dropped.
    // From: Issue #450 | Issue #705 | Issue #844
    #[test]
    fn dnsmasq_conf_renders_proxy_and_relay() {
        let values: HashMap<&str, String> = [
            ("UPSTREAM_DHCP_IP", "10.0.0.1"),
            ("DHCP_RELAY_LOCAL_ADDR", "10.0.0.2"),
            ("DHCP_SUBNET_START", "10.0.0.0"),
            ("DHCP_DNS_PRIMARY", "10.0.0.3"),
            ("DHCP_PROXY_ROUTER", "10.0.0.1"),
            ("DHCP_PROXY_DOMAIN", "bad\nline"),
            ("DHCP_PROXY_CUSTOM_OPTIONS", "66:tftp;67:boot.0"),
            ("DHCP_PROXY_PXE_BOOT_SERVER", "10.0.0.9"),
            ("DHCP_PROXY_PXE_BOOT_FILENAME_UEFI", "u.efi"),
        ]
        .into_iter()
        .map(|(k, v)| (k, v.to_string()))
        .collect();
        let set = |key: &str| values.get(key).cloned().unwrap_or_default();
        let relay = dnsmasq_conf(&set, true);
        assert!(relay.ends_with("dhcp-relay=10.0.0.2,10.0.0.1\n"), "{relay}");
        assert!(!relay.contains("dhcp-range"));
        let proxy = dnsmasq_conf(&set, false);
        for line in [
            "log-facility=-",
            "dhcp-range=10.0.0.0,proxy",
            "dhcp-option-pxe=6,10.0.0.3,10.0.0.3",
            "dhcp-option-pxe=3,10.0.0.1",
            "dhcp-option-pxe=66,tftp",
            "dhcp-option-pxe=67,boot.0",
            "dhcp-boot=tag:lancache-pxe-uefi,u.efi,,10.0.0.9",
            "pxe-service=IA64_EFI,\"lancache-ng PXE proxy active\",0",
        ] {
            assert!(proxy.lines().any(|l| l == line), "{line} missing:\n{proxy}");
        }
        assert!(!proxy.contains("bad"), "{proxy}");
        assert!(!proxy.contains("dhcp-relay"));
    }
}
