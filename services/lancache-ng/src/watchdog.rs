//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// BINDING MAINTAINER DECISION [AG-WF-029]
//
// This Rust source file MUST be restricted exclusively to its
// designated functional responsibility.
//
// Functionality outside its designated responsibility MUST NOT
// be implemented in this file. Shared functionality MUST be
// implemented in the designated shared Rust source file.
//
// This notice is mandatory and MUST be retained verbatim.
//
// Any modification, rewording, shortening, relocation, or removal
// of this notice is explicitly DISACK.

// What: watchdog: decides when to check and tidy.
// Why: shared.rs holds the how; it renders no config.
// From: Issue #1683 | PR #2020

use crate::config::Settings;
use crate::shared::docker::Health;
use crate::shared::{cert, clock, docker, fs, tidy};
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Duration;

// What: weight of one finding.
// Why: the ui sorts and colours by it.
// From: Issue #1683 | PR #1980
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
// From: Issue #1683 | PR #1980
#[derive(Default)]
struct Findings {
    alarms: Vec<Alarm>,
    containers: Vec<Value>,
    cache: Value,
}

impl Findings {
    // What: records one alarm with level and source.
    // Why: a check reports here and keeps running.
    // From: Issue #1683 | PR #1980
    fn add(&mut self, level: Level, source: &str, text: impl Into<String>) {
        let (source, text) = (source.to_string(), text.into());
        self.alarms.push(Alarm {
            level,
            source,
            text,
        });
    }
    // What: records a warning.
    // Why: most callers need only source and text.
    // From: Issue #1683 | PR #1980
    fn warn(&mut self, source: &str, text: impl Into<String>) {
        self.add(Level::Warn, source, text);
    }
    // What: records a critical alarm.
    // Why: most callers need only source and text.
    // From: Issue #1683 | PR #1980
    fn crit(&mut self, source: &str, text: impl Into<String>) {
        self.add(Level::Crit, source, text);
    }
}

// What: body of the alarm file.
// Why: the ui shows it; the stamp proves life.
// From: Issue #1683 | PR #1980
#[derive(Serialize)]
struct Report<'a> {
    written: u64,
    alarms: &'a [Alarm],
    containers: &'a [Value],
    cache: &'a Value,
}

// What: failure streaks and restart times.
// Why: restart after RESTART_AFTER misses, capped.
// From: Issue #1683 | PR #1980
#[derive(Default)]
struct Memory {
    streak: BTreeMap<String, u64>,
    restarts: BTreeMap<String, VecDeque<u64>>,
    log_counter: Option<(u64, u64)>,
}

impl Memory {
    // What: may this container restart now.
    // Why: at most LIMIT restarts per WINDOW.
    // From: Issue #1683 | PR #1980
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

// What: check every container; heal on a streak.
// Why: one miss is noise; RESTART_AFTER is a fault.
// From: Issue #1683 | PR #1980
async fn containers(s: &Settings, f: &mut Findings, m: &mut Memory) -> Result<(), String> {
    let api = docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?;
    let limit = Duration::from_secs(s.uint("DOCKER_TIMEOUT")?);
    let grace = s.num::<u32>("WATCHDOG_STOP_GRACE")?;
    let after = s.uint("RESTART_AFTER")?;
    for member in docker::members(&api, s).await? {
        // What: an inspect error stops this round.
        // Why: no restart on a state that was not read.
        // From: Issue #1683 | PR #2020
        let inspect = member.inspect.clone()?;
        let (service, name) = (member.service.as_str(), member.name.as_str());
        let health = Health::from_inspect(&inspect);
        let by_user = member.stopped_by_user;
        let wanted = member.wanted();
        let (word, colour) = (health.word(), health.colour(wanted));
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
// From: Issue #1683 | PR #1980
fn purge_cache(s: &Settings, f: &mut Findings, now: u64) -> Result<(), String> {
    let stamp = PathBuf::from(s.text("PURGE_STAMP")?);
    if !tidy::is_due(&stamp, now) {
        return Ok(());
    }
    let dir = tidy::cache_root(s)?;
    let (gone, errs) = tidy::drop_older(&dir, s.uint("CACHE_VALID_DAYS")?, now);
    eprintln!("watchdog: cache purge removed {gone} files");
    for e in errs {
        f.warn("cache purge", e);
    }
    tidy::save_stamp(&stamp, now)
}

// What: log root, only inside the allowed prefix.
// Why: cleanup must never delete outside the logs.
// From: Issue #1683 | PR #1980
fn log_root(s: &Settings) -> Result<PathBuf, String> {
    tidy::inside(
        &s.text("SYSLOG_LOG_ROOT")?,
        &s.text("SYSLOG_LOG_ROOT_ALLOWED_PREFIX")?,
    )
}

// What: daily: log age limit, then size budget.
// Why: over budget retries after the cooldown.
// From: Issue #1683 | PR #1980
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
// From: Issue #1683 | PR #1980
fn pack_logs(s: &Settings, f: &mut Findings, now: u64) -> Result<(), String> {
    for e in tidy::pack_closed(&log_root(s)?, s.uint("SYSLOG_XZ_PRESET")?, now) {
        f.warn("log pack", e);
    }
    Ok(())
}

// What: logs arrive but nothing is written.
// Why: a full or read-only log disk hides itself.
// From: Issue #1683 | PR #1980
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
// From: Issue #1683 | PR #1980
fn cache_light(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let dir = s.text("CACHE_DIR")?;
    let sp = tidy::cache_space(s)?;
    let used = sp.used();
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
// From: Issue #1683 | PR #1980
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

// What: host conntrack use against its maximum.
// Why: a full table drops new connections.
// From: Issue #1683 | PR #1985
fn conntrack(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let path = Path::new(&s.text("HOST_NET_STAT_DIR")?).join("nf_conntrack");
    let Ok(stat) = std::fs::read_to_string(&path) else {
        return Ok(());
    };
    let used = stat
        .lines()
        .nth(1)
        .and_then(|l| l.split_whitespace().next())
        .and_then(|h| u64::from_str_radix(h, 16).ok())
        .ok_or_else(|| format!("{}: no entries column", path.display()))?;
    let max_file = s.text("CONNTRACK_MAX_FILE")?;
    let max: u64 = std::fs::read_to_string(&max_file)
        .map_err(|e| format!("{max_file}: {e}"))?
        .trim()
        .parse()
        .map_err(|e| format!("{max_file}: {e}"))?;
    let pct = used.saturating_mul(100) / max.max(1);
    let warn = s.uint("WATCHDOG_CONNTRACK_WARN_PCT")?;
    if pct >= warn {
        f.warn("conntrack", format!("{pct}% used ({used} of {max})"));
    }
    Ok(())
}

// What: expiry of each watched certificate.
// Why: warn before clients reject proxy or ui.
// From: Issue #1683 | PR #1980
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
// From: Issue #1683 | PR #1980
async fn dns_sync(s: &Settings, f: &mut Findings) -> Result<(), String> {
    use crate::shared::peer;
    // What: the registered secondaries, not a lone URL.
    // Why: one list owns the peers; each gets a check.
    // From: Issue #1683 | PR #2019
    let peers = crate::shared::pdns_conf::secondaries(s);
    if peers.is_empty() {
        return Ok(());
    }
    let ours = peer::own_api(s)?
        .zones()
        .await
        .map_err(|e| format!("primary: {e}"))?;
    for (name, address) in peers {
        let theirs = match peer::zones_at(s, &address).await {
            Ok(z) => z,
            Err(e) => {
                f.crit(&name, format!("secondary unreachable: {e}"));
                continue;
            }
        };
        for z in peer::peer_zones(s, &ours, &theirs)? {
            let state = peer::zone_state(&z);
            if state != peer::ZoneState::InSync {
                f.warn(
                    &name,
                    format!(
                        "zone {} {}: primary {:?} secondary {:?}",
                        z.zone,
                        state.word(),
                        z.primary,
                        z.secondary
                    ),
                );
            }
        }
        // What: a zone the primary no longer serves.
        // Why: a stale slave keeps answering old names.
        // From: Issue #1683 | PR #2019
        for z in &theirs {
            if z.kind == "Slave" && peer::serial_of(&ours, &z.name).is_none() {
                f.warn(&name, format!("extra zone {} not on the primary", z.name));
            }
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
    let steps: [(&str, Result<(), String>); 7] = [
        ("cache", cache_light(s, &mut f)),
        ("disks", disks(s, &mut f)),
        ("conntrack", conntrack(s, &mut f)),
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
    let mode = s.mode("WATCHDOG_ALARM_FILE_MODE")?;
    let report = Report {
        written: clock::unix_secs(),
        alarms: &f.alarms,
        containers: &f.containers,
        cache: &f.cache,
    };
    let body = serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?;
    fs::write(&path, &body, mode, fs::Place::Replace, fs::Owner::default())
        .map_err(|e| format!("{}: {e}", path.display()))
}

// What: the last alarm report the watchdog wrote.
// Why: ui, REST, CLI and healthcheck read one way.
// From: Issue #1683 | PR #2020
pub(crate) fn report(s: &Settings) -> Result<Option<Value>, String> {
    fs::read_json(&PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?))
}

// What: healthcheck mode for the container probe.
// Why: fresh alarm file means the watch loop runs.
// From: Issue #1683 | PR #1980
fn healthcheck() -> Result<(), String> {
    let s = Settings::from_process()?;
    let limit = s.uint("CHECK_INTERVAL")? * s.uint("RESTART_AFTER")?.max(1);
    let v = report(&s)?
        .ok_or_else(|| format!("{}: missing", s.text_or_empty("WATCHDOG_ALARM_FILE")))?;
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
pub async fn run(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        None => {}
        Some("healthcheck") => {
            if let Err(e) = healthcheck() {
                eprintln!("watchdog healthcheck: {e}");
                std::process::exit(1);
            }
            return Ok(());
        }
        // What: the last alarm report as JSON on stdout.
        // Why: the CLI reads what the ui and REST show.
        // From: Issue #1683 | PR #2020
        Some("alarms") => {
            let s = Settings::from_process()?;
            let v = report(&s)?.ok_or("no alarm report written yet")?;
            println!("{v}");
            return Ok(());
        }
        // What: an unknown word fails with the list.
        // Why: it must not start a second check loop.
        // From: Issue #1683 | PR #2020
        Some(_) => return Err("commands: healthcheck alarms (none: check loop)".into()),
    }
    use tokio::signal::unix::{SignalKind, signal};
    let mut settings = Settings::from_process()?;
    let mut pause = Duration::from_secs(settings.uint("CHECK_INTERVAL")?);
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut memory = Memory::default();
    loop {
        match Settings::from_process() {
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
