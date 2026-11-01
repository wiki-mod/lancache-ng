//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later

// What: watchdog: looks at the stack, writes alarms.
// Why: it only watches; it starts and changes nothing.
// From: Issue #1683 | PR #1858

use lancache_ng::config::{process_env, Settings};
use lancache_ng::{cert, clock, dns, docker, fs, http, pdns};
use serde::Serialize;
use std::collections::BTreeMap;
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

// What: Docker state and health of each service.
// Why: a stopped or sick container is an alarm.
// From: Issue #1683 | PR #1858
async fn containers(s: &Settings, f: &mut Findings) -> Result<(), String> {
    let api = docker::Api::new(&s.text("DOCKER_ENDPOINT")?)?;
    let limit = Duration::from_secs(s.uint("DOCKER_TIMEOUT")?);
    let project = s.text("COMPOSE_PROJECT")?;
    let dhcp_off = s.text("DHCP_MODE")? == "off";
    let dhcp_service = s.text("DHCP_SERVICE")?;
    let list = api.project(&project, limit).await.map_err(|e| e.to_string())?;
    for c in &list {
        let Some(service) = c["Labels"][docker::SERVICE_LABEL].as_str() else {
            continue;
        };
        let state = c["State"].as_str().unwrap_or("unknown");
        if state != "running" && !(dhcp_off && service == dhcp_service) {
            f.crit(service, format!("container is {state}"));
        }
        let status = c["Status"].as_str().unwrap_or_default();
        if status.contains("(unhealthy)") {
            f.crit(service, "health check says unhealthy");
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
async fn round(s: &Settings) -> Findings {
    let mut f = Findings::default();
    if let Err(e) = containers(s, &mut f).await {
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
    loop {
        match load() {
            Ok(s) => settings = s,
            Err(e) => eprintln!("watchdog: settings kept: {e}"),
        }
        match settings.uint("WATCHDOG_INTERVAL") {
            Ok(v) => pause = Duration::from_secs(v),
            Err(e) => eprintln!("watchdog: interval kept: {e}"),
        }
        let found = round(&settings).await;
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
