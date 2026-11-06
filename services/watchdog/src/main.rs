//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: watchdog: decides when to check and tidy.
// Why: the how lives in shared.rs; no config here.
// From: Issue #1683 | PR #1858

use lancache_ng::config::{Settings, process_env};
use lancache_ng::{cert, clock, dns, docker, fs, http, pdns, tidy};
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Duration;

// What: env name of the saved settings file.
// Why: needed before any setting can be read.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: weight of one finding.
// Why: the ui sorts and colours by it.
// From: Issue #1683 | PR #1858
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
enum Level {
    Warn,
    Crit,
}

// What: one finding.
// Why: same row in the alarm file and the log.
// From: Issue #1683 | PR #1858
#[derive(Debug, Serialize)]
struct Alarm {
    level: Level,
    source: String,
    text: String,
}

// What: findings and facts of one round.
// Why: a check adds rows and never stops others.
// From: Issue #1683 | PR #1858
#[derive(Default)]
struct Findings {
    alarms: Vec<Alarm>,
    containers: Vec<Value>,
    cache: Value,
}

impl Findings {
    fn add(&mut self, level: Level, source: &str, text: impl Into<String>) {
        let (source, text) = (source.to_string(), text.into());
        self.alarms.push(Alarm {
            level,
            source,
            text,
        });
    }
    fn warn(&mut self, source: &str, text: impl Into<String>) {
        self.add(Level::Warn, source, text);
    }
    fn crit(&mut self, source: &str, text: impl Into<String>) {
        self.add(Level::Crit, source, text);
    }
}

// What: body of the alarm file.
// Why: the ui shows it; the stamp proves life.
// From: Issue #1683 | PR #1858
#[derive(Serialize)]
struct Report<'a> {
    written: u64,
    alarms: &'a [Alarm],
    containers: &'a [Value],
    cache: &'a Value,
}

// What: Docker health of one container.
// Why: degraded and starting are not failures.
// From: Issue #1683 | PR #1858
#[derive(Debug, PartialEq)]
enum Health {
    Healthy,
    Degraded,
    Starting,
    Unhealthy,
    Stopped(String),
    Unknown(String),
}

impl Health {
    // What: read docker inspect State.
    // Why: newest check output DEGRADED: refines ok.
    // From: Issue #1296
    fn from_inspect(inspect: &Value) -> Self {
        let state = inspect.pointer("/State/Status").and_then(Value::as_str);
        if state != Some("running") {
            return Health::Stopped(state.unwrap_or("unknown").into());
        }
        let status = inspect
            .pointer("/State/Health/Status")
            .and_then(Value::as_str);
        let last = inspect
            .pointer("/State/Health/Log")
            .and_then(Value::as_array)
            .and_then(|log| log.last())
            .and_then(|e| e["Output"].as_str())
            .unwrap_or_default();
        let degraded = last.lines().any(|l| l.starts_with("DEGRADED: "));
        match status.unwrap_or("none") {
            "healthy" if degraded => Health::Degraded,
            "healthy" | "none" => Health::Healthy,
            "starting" => Health::Starting,
            "unhealthy" => Health::Unhealthy,
            other => Health::Unknown(other.into()),
        }
    }

    fn word_and_colour(&self) -> (String, &'static str) {
        match self {
            Health::Healthy => ("healthy".into(), "green"),
            Health::Degraded => ("degraded".into(), "amber"),
            Health::Starting => ("starting".into(), "yellow"),
            Health::Unhealthy => ("unhealthy".into(), "red"),
            Health::Stopped(s) => (s.clone(), "red"),
            Health::Unknown(s) => (s.clone(), "yellow"),
        }
    }

    fn failing(&self) -> bool {
        matches!(self, Health::Unhealthy | Health::Stopped(_))
    }
}

// What: failure streaks and restart times.
// Why: restart after RESTART_AFTER misses, capped.
// From: Issue #1683 | PR #1858
#[derive(Default)]
struct Memory {
    streak: BTreeMap<String, u64>,
    restarts: BTreeMap<String, VecDeque<u64>>,
    log_counter: Option<(u64, u64)>,
}

impl Memory {
    // What: may this container restart now.
    // Why: at most LIMIT restarts per WINDOW.
    // From: Issue #1683 | PR #1858
    fn restart_allowed(&mut self, s: &Settings, name: &str) -> Result<bool, String> {
        let max = s.uint("WATCHDOG_RESTART_LIMIT")?;
        let window = s.uint("WATCHDOG_RESTART_WINDOW")?;
        let now = clock::unix_secs();
        let times = self.restarts.entry(name.to_string()).or_default();
        times.retain(|t| now.saturating_sub(*t) <= window);
        if times.len() as u64 >= max {
            return Ok(false);
        }
        times.push_back(now);
        Ok(true)
    }
}

// What: settings from env and the saved file.
// Why: ui changes reach the watchdog via the file.
fn load() -> Result<Settings, String> {
    let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
    Settings::load(&process_env, saved.as_deref())
}

// What: check every container; heal on a streak.
// Why: one miss is noise; RESTART_AFTER is a fault.
// From: Issue #1683 | PR #1858
async fn containers(s: &Settings, f: &mut Findings, m: &mut Memory) -> Result<(), String> {
    let api = docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?;
    let limit = Duration::from_secs(s.uint("DOCKER_TIMEOUT")?);
    let grace = u32::try_from(s.uint("WATCHDOG_STOP_GRACE")?).map_err(|e| e.to_string())?;
    let after = s.uint("RESTART_AFTER")?;
    let project = s.text("COMPOSE_PROJECT")?;
    let stopped = s.list("SERVICES_STOPPED");
    let dhcp_off = s.text("DHCP_MODE")? == "off";
    let dhcp_service = s.text("DHCP_SERVICE")?;
    for row in api
        .project(&project, limit)
        .await
        .map_err(|e| e.to_string())?
    {
        let Some(service) = row["Labels"][docker::SERVICE_LABEL].as_str() else {
            continue;
        };
        let name = row["Names"][0]
            .as_str()
            .unwrap_or(service)
            .trim_start_matches('/');
        let inspect = api.inspect(name, limit).await.map_err(|e| e.to_string())?;
        let health = Health::from_inspect(&inspect);
        let (word, colour) = health.word_and_colour();
        let by_user = stopped.iter().any(|x| x == service);
        let wanted = !by_user && !(dhcp_off && service == dhcp_service);
        f.containers.push(serde_json::json!({
            "service": service, "name": name, "health": word,
            "colour": colour, "stopped_by_user": by_user,
        }));
        if health == Health::Degraded {
            f.warn(service, "running with reduced function");
        }
        if !wanted || !health.failing() {
            m.streak.remove(name);
            continue;
        }
        let count = m.streak.entry(name.to_string()).or_default();
        *count += 1;
        if *count < after {
            f.warn(service, format!("{word}, check {count} of {after}"));
            continue;
        }
        *count = 0;
        if !m.restart_allowed(s, name)? {
            f.crit(service, format!("{word}; restart limit reached"));
            continue;
        }
        match api.act(name, docker::Action::Restart, grace, limit).await {
            Ok(()) => f.warn(service, format!("{word}; restarted")),
            Err(e) => f.crit(service, format!("{word}; restart failed: {e}")),
        }
    }
    Ok(())
}

// What: daily: drop cache files past their days.
// Why: CACHE_VALID_DAYS keeps the disk usable.
// From: Issue #1683 | PR #1858
fn purge_cache(s: &Settings, f: &mut Findings, now: u64) -> Result<(), String> {
    let stamp = PathBuf::from(s.text("PURGE_STAMP")?);
    if !tidy::is_due(&stamp, now) {
        return Ok(());
    }
    let dir = tidy::inside(&s.text("CACHE_DIR")?, &s.text("CACHE_DIR_ALLOWED_PREFIX")?)?;
    let (gone, errs) = tidy::drop_older(&dir, s.uint("CACHE_VALID_DAYS")?, now);
    eprintln!("watchdog: cache purge removed {gone} files");
    for e in errs {
        f.warn("cache purge", e);
    }
    tidy::save_stamp(&stamp, now)
}

// What: log root, only inside the allowed prefix.
// Why: cleanup must never delete outside the logs.
fn log_root(s: &Settings) -> Result<PathBuf, String> {
    tidy::inside(
        &s.text("SYSLOG_LOG_ROOT")?,
        &s.text("SYSLOG_LOG_ROOT_ALLOWED_PREFIX")?,
    )
}

// What: daily: log age limit, then size budget.
// Why: over budget retries after the cooldown.
// From: Issue #1683 | PR #1858
fn prune_logs(s: &Settings, f: &mut Findings, now: u64) -> Result<(), String> {
    let stamp = PathBuf::from(s.text("SYSLOG_PRUNE_STAMP")?);
    if !tidy::is_due(&stamp, now) {
        return Ok(());
    }
    let root = log_root(s)?;
    let budget = s.uint("SYSLOG_MAX_GB")?.saturating_mul(1 << 30);
    let (_, mut errs) = tidy::drop_older(&root, s.uint("SYSLOG_RETENTION_DAYS")?, now);
    let (size, more) = tidy::fit_budget(&root, budget, now);
    errs.extend(more);
    for e in errs {
        f.warn("log prune", e);
    }
    if size <= budget {
        return tidy::save_stamp(&stamp, now);
    }
    f.warn("logs", format!("log size {size} bytes is over the budget"));
    let wait = s.uint("SYSLOG_PRUNE_RETRY_COOLDOWN")?;
    tidy::save_stamp(&stamp, (now + wait).saturating_sub(tidy::DAY))
}

// What: pack closed log files with xz.
// Why: saves log disk; open files stay plain.
// From: Issue #1683 | PR #1858
fn pack_logs(s: &Settings, f: &mut Findings, now: u64) -> Result<(), String> {
    for e in tidy::pack_closed(&log_root(s)?, s.uint("SYSLOG_XZ_PRESET")?, now) {
        f.warn("log pack", e);
    }
    Ok(())
}

// What: logs arrive but nothing is written.
// Why: a full or read-only log disk hides itself.
// From: Issue #1683 | PR #1858
fn log_writing(s: &Settings, f: &mut Findings, m: &mut Memory) -> Result<(), String> {
    let newest = tidy::newest(Path::new(&s.text("SYSLOG_LOG_ROOT")?));
    let count = tidy::syslog_processed()?;
    if let Some((was_count, was_newest)) = m.log_counter
        && count > was_count
        && newest == was_newest
    {
        f.crit("logs", "messages arrive but no log file is written");
    }
    m.log_counter = Some((count, newest));
    Ok(())
}

// What: cache disk use as a traffic light.
// Why: the ui shows green, yellow or red.
// From: Issue #1683 | PR #1858
fn cache_light(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let dir = s.text("CACHE_DIR")?;
    let sp = fs::space(Path::new(&dir)).map_err(|e| format!("{dir}: {e}"))?;
    let used = sp.total.saturating_sub(sp.free);
    let pct = used.saturating_mul(100) / sp.total.max(1);
    let (warn, alarm) = (s.uint("DISK_WARN_PCT")?, s.uint("DISK_ALARM_PCT")?);
    let colour = if pct >= alarm {
        f.crit(&dir, format!("cache disk {pct}% full"));
        "red"
    } else if pct >= warn {
        f.warn(&dir, format!("cache disk {pct}% full"));
        "yellow"
    } else {
        "green"
    };
    f.cache = serde_json::json!({"pct": pct, "used_bytes": used, "status": colour});
    Ok(())
}

// What: free space of each other watched path.
// Why: a full log disk stops the logs.
// From: Issue #1683 | PR #1858
fn disks(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let min = s.uint("WATCHDOG_DISK_MIN_FREE_PERCENT")?;
    for path in s.list("WATCHDOG_DISK_PATHS") {
        match fs::space(Path::new(&path)) {
            Err(e) => f.crit(&path, e.to_string()),
            Ok(sp) if sp.total == 0 => f.warn(&path, "reports size 0"),
            Ok(sp) => {
                let free = sp.free.saturating_mul(100) / sp.total;
                if free < min {
                    f.crit(&path, format!("{free}% free, minimum {min}%"));
                }
            }
        }
    }
    Ok(())
}

// What: expiry of each watched certificate.
// Why: warn before clients reject proxy or ui.
// From: Issue #1683 | PR #1858
fn certs(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let within = s.uint("WATCHDOG_CERT_WARN_SECS")?;
    for path in s.list("WATCHDOG_CERT_FILES") {
        match cert::valid_for(Path::new(&path), within) {
            Ok(true) => {}
            Ok(false) => match cert::expiry(Path::new(&path)) {
                Ok((day, n)) => f.warn(&path, format!("expires in {n} days ({day})")),
                Err(e) => f.crit(&path, e),
            },
            Err(e) => f.crit(&path, e),
        }
    }
    Ok(())
}

// What: zone serials, primary against secondary.
// Why: shows a lost NOTIFY or a broken AXFR.
// From: Issue #1683 | PR #1858
async fn dns_sync(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let far = s.text("PDNS_SECONDARY_API_URL").unwrap_or_default();
    if far.is_empty() {
        return Ok(());
    }
    let key = s.text("PDNS_API_KEY")?;
    let client = http::client(s)?;
    let near = pdns::Api::new(client.clone(), &s.text("PDNS_PRIMARY_API_URL")?, &key);
    let far = pdns::Api::new(client, &far, &key);
    let ours = near.zones().await.map_err(|e| format!("primary: {e}"))?;
    let theirs = far.zones().await.map_err(|e| format!("secondary: {e}"))?;
    let seen: BTreeMap<&str, u32> = theirs.iter().map(|z| (z.name.as_str(), z.serial)).collect();
    for z in &ours {
        let Some(&other) = seen.get(z.name.as_str()) else {
            f.crit(&z.name, "zone missing on secondary");
            continue;
        };
        let state = dns::sync_state(z.serial, other);
        if state != dns::Sync::InSync {
            f.warn(
                &z.name,
                format!("{state:?}: primary {} secondary {other}", z.serial),
            );
        }
    }
    Ok(())
}

// What: run every duty of one round.
// Why: a broken duty is itself an alarm.
// From: Issue #1683 | PR #1858
async fn round(s: &Settings, m: &mut Memory) -> Findings {
    let mut f = Findings::default();
    let now = clock::unix_secs();
    if let Err(e) = containers(s, &mut f, m).await {
        f.crit("docker", e);
    }
    let steps: [(&str, Result<(), String>); 6] = [
        ("cache", cache_light(s, &mut f)),
        ("disks", disks(s, &mut f)),
        ("certs", certs(s, &mut f)),
        ("cache purge", purge_cache(s, &mut f, now)),
        ("log prune", prune_logs(s, &mut f, now)),
        ("log pack", pack_logs(s, &mut f, now)),
    ];
    for (name, result) in steps {
        if let Err(e) = result {
            f.crit(name, e);
        }
    }
    if let Err(e) = log_writing(s, &mut f, m) {
        f.crit("logs", e);
    }
    if let Err(e) = dns_sync(s, &mut f).await {
        f.crit("dns", e);
    }
    f.alarms
        .sort_by(|a, b| b.level.cmp(&a.level).then_with(|| a.source.cmp(&b.source)));
    f
}

// What: write the alarm file for the ui.
// Why: whole-file replace; no half reads.
// From: Issue #1683 | PR #1858
fn publish(s: &Settings, f: &Findings) -> Result<(), String> {
    let path = PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?);
    let mode = u32::from_str_radix(&s.text("WATCHDOG_ALARM_FILE_MODE")?, 8)
        .map_err(|e| format!("WATCHDOG_ALARM_FILE_MODE: {e}"))?;
    let report = Report {
        written: clock::unix_secs(),
        alarms: &f.alarms,
        containers: &f.containers,
        cache: &f.cache,
    };
    let body = serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?;
    let owner = fs::Owner {
        uid: None,
        gid: None,
    };
    fs::write(&path, &body, mode, fs::Place::Replace, owner)
        .map_err(|e| format!("{}: {e}", path.display()))
}

// What: healthcheck mode for the container probe.
// Why: fresh alarm file means the watch loop runs.
// From: Issue #1683 | PR #1980
fn healthcheck() -> Result<(), String> {
    let s = load()?;
    let limit = s.uint("CHECK_INTERVAL")? * s.uint("RESTART_AFTER")?.max(1);
    let path = PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?);
    let raw = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let v: serde_json::Value = serde_json::from_slice(&raw).map_err(|e| e.to_string())?;
    let written = v["written"].as_u64().ok_or("written missing")?;
    let age = clock::unix_secs().saturating_sub(written);
    if age > limit {
        return Err(format!("alarm file {age}s old, limit {limit}s"));
    }
    Ok(())
}

// What: healthcheck command, else the check loop.
// Why: settings are reread; a bad round never exits.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() -> Result<(), String> {
    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        if let Err(e) = healthcheck() {
            eprintln!("watchdog healthcheck: {e}");
            std::process::exit(1);
        }
        return Ok(());
    }
    use tokio::signal::unix::{SignalKind, signal};
    let mut settings = load()?;
    let mut pause = Duration::from_secs(settings.uint("CHECK_INTERVAL")?);
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut memory = Memory::default();
    loop {
        match load() {
            Ok(s) => settings = s,
            Err(e) => eprintln!("watchdog: settings kept: {e}"),
        }
        match settings.uint("CHECK_INTERVAL") {
            Ok(v) => pause = Duration::from_secs(v),
            Err(e) => eprintln!("watchdog: interval kept: {e}"),
        }
        let found = round(&settings, &mut memory).await;
        for a in &found.alarms {
            eprintln!("watchdog: {:?} {}: {}", a.level, a.source, a.text);
        }
        if let Err(e) = publish(&settings, &found) {
            eprintln!("watchdog: alarm file: {e}");
        }
        tokio::select! {
            () = tokio::time::sleep(pause) => {}
            _ = term.recv() => return Ok(()),
        }
    }
}
