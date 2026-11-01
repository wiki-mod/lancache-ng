//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: watchdog: checks the stack, raises alarms.
// Why: restarts sick containers; writes no config.
// From: Issue #1683 | PR #1858

use lancache_ng::config::{process_env, Settings};
use lancache_ng::{cert, clock, dns, docker, fs, http, pdns};
use serde::Serialize;
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

// What: findings of one round.
// Why: a check adds rows and never stops others.
// From: Issue #1683 | PR #1858
#[derive(Default)]
struct Findings(Vec<Alarm>);

impl Findings {
    fn add(&mut self, level: Level, source: &str, text: impl Into<String>) {
        let (source, text) = (source.to_string(), text.into());
        self.0.push(Alarm { level, source, text });
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
}

fn load() -> Result<Settings, String> {
    let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
    Settings::load(&process_env, saved.as_deref())
}

// What: restart times per container.
// Why: a crash loop stops at the SOT limit.
// From: Issue #1683 | PR #1858
#[derive(Default)]
struct Restarts(BTreeMap<String, VecDeque<u64>>);

impl Restarts {
    // What: may this container restart now.
    // Why: at most LIMIT restarts per WINDOW.
    // From: Issue #1683 | PR #1858
    fn allow(&mut self, s: &Settings, name: &str) -> Result<bool, String> {
        let max = s.uint("WATCHDOG_RESTART_LIMIT")?;
        let window = s.uint("WATCHDOG_RESTART_WINDOW")?;
        let now = clock::unix_secs();
        let times = self.0.entry(name.to_string()).or_default();
        times.retain(|t| now.saturating_sub(*t) <= window);
        if times.len() as u64 >= max {
            return Ok(false);
        }
        times.push_back(now);
        Ok(true)
    }
}

// What: why a container needs help, if at all.
// Why: stopped or unhealthy; healthcheck = programs.
// From: Issue #1683 | PR #1858
fn trouble(c: &serde_json::Value) -> Option<String> {
    let state = c["State"].as_str().unwrap_or("unknown");
    let sick = c["Status"].as_str().unwrap_or_default().contains("(unhealthy)");
    match (state == "running", sick) {
        (true, false) => None,
        (true, true) => Some("health check unhealthy".into()),
        (false, _) => Some(format!("container is {state}")),
    }
}

// What: watch containers; restart in trouble.
// Why: keeps the stack up; loops become alarms.
// From: Issue #1683 | PR #1858
async fn containers(s: &Settings, f: &mut Findings, r: &mut Restarts) -> Result<(), String> {
    let api = docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?;
    let limit = Duration::from_secs(s.uint("DOCKER_TIMEOUT")?);
    let grace = u32::try_from(s.uint("WATCHDOG_STOP_GRACE")?).map_err(|e| e.to_string())?;
    let project = s.text("COMPOSE_PROJECT")?;
    let dhcp_off = s.text("DHCP_MODE")? == "off";
    let dhcp_service = s.text("DHCP_SERVICE")?;
    let list = api.project(&project, limit).await.map_err(|e| e.to_string())?;
    for c in &list {
        let Some(service) = c["Labels"][docker::SERVICE_LABEL].as_str() else {
            continue;
        };
        let Some(why) = trouble(c) else { continue };
        if dhcp_off && service == dhcp_service {
            continue;
        }
        let name = c["Names"][0].as_str().unwrap_or(service).trim_start_matches('/');
        if !r.allow(s, name)? {
            f.crit(service, format!("{why}; restart limit reached"));
            continue;
        }
        match api.act(name, docker::Action::Restart, grace, limit).await {
            Ok(()) => f.warn(service, format!("{why}; restarted")),
            Err(e) => f.crit(service, format!("{why}; restart failed: {e}")),
        }
    }
    Ok(())
}

// What: free space of each watched path.
// Why: a full disk stops cache and logs.
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
            Ok(false) => f.warn(&path, format!("expires within {within} s")),
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
            let text = format!("{state:?}: primary {} secondary {other}", z.serial);
            f.warn(&z.name, text);
        }
    }
    Ok(())
}

// What: run every check of one round.
// Why: a broken check is itself an alarm.
// From: Issue #1683 | PR #1858
async fn round(s: &Settings, r: &mut Restarts) -> Findings {
    let mut f = Findings::default();
    if let Err(e) = containers(s, &mut f, r).await {
        f.crit("docker", e);
    }
    if let Err(e) = disks(s, &mut f) {
        f.crit("disks", e);
    }
    if let Err(e) = certs(s, &mut f) {
        f.crit("certs", e);
    }
    if let Err(e) = dns_sync(s, &mut f).await {
        f.crit("dns", e);
    }
    f.0.sort_by(|a, b| b.level.cmp(&a.level).then_with(|| a.source.cmp(&b.source)));
    f
}

// What: write the alarm file for the ui.
// Why: whole-file replace; no half reads.
// From: Issue #1683 | PR #1858
fn publish(s: &Settings, alarms: &[Alarm]) -> Result<(), String> {
    let path = PathBuf::from(s.text("WATCHDOG_ALARM_FILE")?);
    let mode = u32::from_str_radix(&s.text("WATCHDOG_ALARM_FILE_MODE")?, 8)
        .map_err(|e| format!("WATCHDOG_ALARM_FILE_MODE: {e}"))?;
    let report = Report { written: clock::unix_secs(), alarms };
    let body = serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?;
    let owner = fs::Owner { uid: None, gid: None };
    fs::write(&path, &body, mode, fs::Place::Replace, owner)
        .map_err(|e| format!("{}: {e}", path.display()))
}

// What: endless rounds until SIGTERM.
// Why: settings are reread; a bad round never exits.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() -> Result<(), String> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut settings = load()?;
    let mut pause = Duration::from_secs(settings.uint("WATCHDOG_INTERVAL")?);
    let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut restarts = Restarts::default();
    loop {
        match load() {
            Ok(s) => settings = s,
            Err(e) => eprintln!("watchdog: settings kept: {e}"),
        }
        match settings.uint("WATCHDOG_INTERVAL") {
            Ok(v) => pause = Duration::from_secs(v),
            Err(e) => eprintln!("watchdog: interval kept: {e}"),
        }
        let found = round(&settings, &mut restarts).await;
        for a in &found.0 {
            eprintln!("watchdog: {:?} {}: {}", a.level, a.source, a.text);
        }
        if let Err(e) = publish(&settings, &found.0) {
            eprintln!("watchdog: alarm file: {e}");
        }
        tokio::select! {
            () = tokio::time::sleep(pause) => {}
            _ = term.recv() => return Ok(()),
        }
    }
}
