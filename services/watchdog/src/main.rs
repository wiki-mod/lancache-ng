// LanCache-NG (https://github.com/wiki-mod/lancache-ng)
// SPDX-License-Identifier: AGPL-3.0-or-later

// What: watchdog: watches states, raises alarms, restarts.
// Why: watcher only; starts no program, writes no config.
// From: Issue #1683 | PR #1858

use lancache_ng::config::{process_env, Settings};
use lancache_ng::{cert, clock, dns, docker, fs, http, pdns};
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Duration;

// What: env name of the saved settings file path.
// Why: settings load needs the path before settings exist.
// From: Issue #1683 | PR #1858
const SETTINGS_FILE_ENV: &str = "LANCACHE_SETTINGS_FILE";

// What: how bad one finding is.
// Why: ui sorts and colours by it; snmp traps on Crit.
// From: Issue #1683 | PR #1858
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, serde::Serialize)]
enum Level {
    Warn,
    Crit,
}

// What: one alarm row.
// Why: same rows go to the alarm file and to the log.
// From: Issue #1683 | PR #1858
#[derive(Clone, Debug, serde::Serialize)]
struct Alarm {
    level: Level,
    source: String,
    text: String,
}

// What: alarm file body.
// Why: ui shows it; written stamp proves we are alive.
// From: Issue #1683 | PR #1858
#[derive(serde::Serialize)]
struct Report<'a> {
    written: u64,
    alarms: &'a [Alarm],
    restarts: BTreeMap<String, usize>,
}

// What: everything one round needs.
// Why: settings are reread each round; live changes work.
// From: Issue #1683 | PR #1858
struct Watch {
    settings: Settings,
    docker: docker::Api,
    http: reqwest::Client,
    restarts: BTreeMap<String, VecDeque<u64>>,
    serials: BTreeMap<String, u32>,
}

impl Watch {
    // What: build clients from settings.
    // Why: one setup path for start and reload.
    // From: Issue #1683 | PR #1858
    fn new(settings: Settings) -> Result<Self, String> {
        let docker = docker::Api::new(&settings.text("DOCKER_ENDPOINT")?)?;
        let http = http::client(&settings)?;
        Ok(Self {
            settings,
            docker,
            http,
            restarts: BTreeMap::new(),
            serials: BTreeMap::new(),
        })
    }

    // What: seconds setting as Duration.
    // Why: every limit comes from the SOT.
    // From: Issue #1683 | PR #1858
    fn secs(&self, key: &str) -> Result<Duration, String> {
        self.settings.uint(key).map(Duration::from_secs)
    }

    // What: one full round of all checks.
    // Why: each check fails alone; one never blocks another.
    // From: Issue #1683 | PR #1858
    async fn round(&mut self) -> Vec<Alarm> {
        let mut alarms = Vec::new();
        self.containers(&mut alarms).await;
        self.disks(&mut alarms);
        self.certs(&mut alarms);
        self.dns_sync(&mut alarms).await;
        self.secondary_flush(&mut alarms).await;
        alarms.sort_by(|a, b| b.level.cmp(&a.level).then(a.source.cmp(&b.source)));
        alarms
    }

    // What: container state and health via Docker.
    // Why: dead or unhealthy containers get restarted.
    // From: Issue #1683 | PR #1858
    async fn containers(&mut self, alarms: &mut Vec<Alarm>) {
        let limit = match self.secs("DOCKER_TIMEOUT") {
            Ok(v) => v,
            Err(e) => return alarms.push(crit("watchdog", e)),
        };
        let project = match self.settings.text("COMPOSE_PROJECT") {
            Ok(v) => v,
            Err(e) => return alarms.push(crit("watchdog", e)),
        };
        let list = match self.docker.project(&project, limit).await {
            Ok(v) => v,
            Err(e) => return alarms.push(crit("docker", e.to_string())),
        };
        for c in &list {
            let Some(service) = c["Labels"][docker::SERVICE_LABEL].as_str() else {
                continue;
            };
            let name = c["Names"][0]
                .as_str()
                .unwrap_or(service)
                .trim_start_matches('/');
            let run = c["State"].as_str().unwrap_or("unknown");
            let dhcp_off = self.settings.text("DHCP_MODE").as_deref() == Ok("off")
                && self.settings.text("DHCP_SERVICE").as_deref() == Ok(service);
            if dhcp_off && run != "running" {
                continue;
            }
            let mut reasons = Vec::new();
            if run != "running" {
                reasons.push(format!("Docker state {run}"));
            }
            if c["Status"]
                .as_str()
                .is_some_and(|s| s.contains("(unhealthy)"))
            {
                reasons.push("health check unhealthy".to_string());
            }
            if reasons.is_empty() {
                continue;
            }
            let text = reasons.join(", ");
            match self.restart(name, limit).await {
                Ok(true) => alarms.push(warn(service, format!("{text}; restarted"))),
                Ok(false) => alarms.push(crit(service, format!("{text}; restart limit reached"))),
                Err(e) => alarms.push(crit(service, format!("{text}; restart failed: {e}"))),
            }
        }
    }

    // What: restart unless the window limit is used up.
    // Why: limited restarts; a crash loop becomes an alarm.
    // From: Issue #1683 | PR #1858
    async fn restart(&mut self, name: &str, limit: Duration) -> Result<bool, String> {
        let max = self.settings.uint("WATCHDOG_RESTART_LIMIT")?;
        let window = self.settings.uint("WATCHDOG_RESTART_WINDOW")?;
        let grace = self.settings.uint("WATCHDOG_STOP_GRACE")?;
        let grace = u32::try_from(grace).map_err(|e| e.to_string())?;
        let now = clock::unix_secs();
        let seen = self.restarts.entry(name.to_string()).or_default();
        while seen
            .front()
            .is_some_and(|t| now.saturating_sub(*t) > window)
        {
            seen.pop_front();
        }
        if u64::try_from(seen.len()).unwrap_or(u64::MAX) >= max {
            return Ok(false);
        }
        seen.push_back(now);
        self.docker
            .act(name, docker::Action::Restart, grace, limit)
            .await
            .map(|()| true)
            .map_err(|e| e.to_string())
    }

    // What: free space of every watched filesystem.
    // Why: a full cache or log disk stops all services.
    // From: Issue #1683 | PR #1858
    fn disks(&self, alarms: &mut Vec<Alarm>) {
        let min = match self.settings.uint("WATCHDOG_DISK_MIN_FREE_PERCENT") {
            Ok(v) => v,
            Err(e) => return alarms.push(crit("watchdog", e)),
        };
        for path in self.settings.list("WATCHDOG_DISK_PATHS") {
            match fs::space(Path::new(&path)) {
                Ok(s) if s.total == 0 => alarms.push(warn(&path, "size 0 reported".into())),
                Ok(s) => {
                    let pct = s.free.saturating_mul(100) / s.total;
                    if pct < min {
                        alarms.push(crit(&path, format!("{pct}% free, minimum {min}%")));
                    }
                }
                Err(e) => alarms.push(crit(&path, e.to_string())),
            }
        }
    }

    // What: expiry of every watched certificate.
    // Why: alarm before clients reject the proxy or ui.
    // From: Issue #1683 | PR #1858
    fn certs(&self, alarms: &mut Vec<Alarm>) {
        let within = match self.settings.uint("WATCHDOG_CERT_WARN_SECS") {
            Ok(v) => v,
            Err(e) => return alarms.push(crit("watchdog", e)),
        };
        for path in self.settings.list("WATCHDOG_CERT_FILES") {
            match cert::valid_for(Path::new(&path), within) {
                Ok(true) => {}
                Ok(false) => alarms.push(warn(&path, format!("expires within {within} s"))),
                Err(e) => alarms.push(crit(&path, e)),
            }
        }
    }

    // What: serial compare primary against secondary zones.
    // Why: shows a lost NOTIFY or broken AXFR at once.
    // From: Issue #1683 | PR #1858
    async fn dns_sync(&self, alarms: &mut Vec<Alarm>) {
        let secondary = self
            .settings
            .text("PDNS_SECONDARY_API_URL")
            .unwrap_or_default();
        if secondary.is_empty() {
            return;
        }
        let (Ok(primary), Ok(key)) = (
            self.settings.text("PDNS_PRIMARY_API_URL"),
            self.settings.text("PDNS_API_KEY"),
        ) else {
            return alarms.push(crit("dns", "primary API URL or key not set".into()));
        };
        let p = pdns::Api::new(self.http.clone(), &primary, &key);
        let s = pdns::Api::new(self.http.clone(), &secondary, &key);
        let (pz, sz) = match (p.zones().await, s.zones().await) {
            (Ok(a), Ok(b)) => (a, b),
            (Err(e), _) => return alarms.push(crit("dns primary", e)),
            (_, Err(e)) => return alarms.push(crit("dns secondary", e)),
        };
        let theirs: BTreeMap<&str, u32> = sz.iter().map(|z| (z.name.as_str(), z.serial)).collect();
        for z in &pz {
            match theirs.get(z.name.as_str()) {
                None => alarms.push(crit(&z.name, "zone missing on secondary".into())),
                Some(&ser) => match dns::sync_state(z.serial, ser) {
                    dns::Sync::InSync => {}
                    other => alarms.push(warn(
                        &z.name,
                        format!("{other:?}: primary {} secondary {ser}", z.serial),
                    )),
                },
            }
        }
    }

    // What: flush recursor caches after a zone update.
    // Why: secondary: AXFR raised the serial; old answers go.
    // From: Issue #1683 | PR #1858
    async fn secondary_flush(&mut self, alarms: &mut Vec<Alarm>) {
        if self.settings.text("DNS_REPLICATION_ROLE").as_deref() != Ok("secondary") {
            return;
        }
        let (Ok(local), Ok(key)) = (
            self.settings.text("PDNS_PRIMARY_API_URL"),
            self.settings.text("PDNS_API_KEY"),
        ) else {
            return alarms.push(crit("dns", "local API URL or key not set".into()));
        };
        let zones = match pdns::Api::new(self.http.clone(), &local, &key)
            .zones()
            .await
        {
            Ok(z) => z,
            Err(e) => return alarms.push(crit("dns local", e)),
        };
        let recursors: Vec<pdns::Api> = self
            .settings
            .list("RECURSOR_API_URLS")
            .iter()
            .map(|u| pdns::Api::new(self.http.clone(), u, &key))
            .collect();
        for z in zones {
            let before = self.serials.insert(z.name.clone(), z.serial);
            if before.is_none_or(|b| b == z.serial) {
                continue;
            }
            for r in &recursors {
                if let Err(e) = r.flush(&z.name, true).await {
                    alarms.push(warn(&z.name, format!("cache flush failed: {e}")));
                }
            }
        }
    }

    // What: write the alarm file for the ui.
    // Why: atomic replace; readers never see half a file.
    // From: Issue #1683 | PR #1858
    fn publish(&self, alarms: &[Alarm]) -> Result<(), String> {
        let path = PathBuf::from(self.settings.text("WATCHDOG_ALARM_FILE")?);
        let restarts = self
            .restarts
            .iter()
            .map(|(k, v)| (k.clone(), v.len()))
            .collect();
        let report = Report {
            written: clock::unix_secs(),
            alarms,
            restarts,
        };
        let body = serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?;
        let keep = fs::Owner {
            uid: None,
            gid: None,
        };
        fs::write(&path, &body, 0o644, fs::Place::Replace, keep)
            .map_err(|e| format!("{}: {e}", path.display()))
    }
}

// What: warn alarm.
// Why: short constructor.
// From: Issue #1683 | PR #1858
fn warn(source: &str, text: String) -> Alarm {
    Alarm {
        level: Level::Warn,
        source: source.to_string(),
        text,
    }
}

// What: crit alarm.
// Why: short constructor.
// From: Issue #1683 | PR #1858
fn crit(source: &str, text: String) -> Alarm {
    Alarm {
        level: Level::Crit,
        source: source.to_string(),
        text,
    }
}

// What: load settings from env and the saved file.
// Why: saved ui changes apply on the next round.
// From: Issue #1683 | PR #1858
fn load() -> Result<Settings, String> {
    let saved = process_env(SETTINGS_FILE_ENV).map(PathBuf::from);
    Settings::load(&process_env, saved.as_deref())
}

// What: entry: loop rounds until SIGTERM.
// Why: a broken round logs and retries, never exits.
// From: Issue #1683 | PR #1858
#[tokio::main]
async fn main() -> Result<(), String> {
    let mut watch = Watch::new(load()?)?;
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|e| e.to_string())?;
    loop {
        match load() {
            Ok(s) if s.revision() != watch.settings.revision() => match Watch::new(s) {
                Ok(mut w) => {
                    w.restarts = std::mem::take(&mut watch.restarts);
                    w.serials = std::mem::take(&mut watch.serials);
                    watch = w;
                }
                Err(e) => eprintln!("watchdog: settings: {e}"),
            },
            Ok(_) => {}
            Err(e) => eprintln!("watchdog: settings: {e}"),
        }
        let alarms = watch.round().await;
        for a in &alarms {
            eprintln!("watchdog: {:?} {}: {}", a.level, a.source, a.text);
        }
        if let Err(e) = watch.publish(&alarms) {
            eprintln!("watchdog: alarm file: {e}");
        }
        let pause = match watch.secs("WATCHDOG_INTERVAL") {
            Ok(v) => v,
            Err(e) => {
                eprintln!("watchdog: {e}");
                Duration::from_secs(u64::from(u8::MAX))
            }
        };
        tokio::select! {
            () = tokio::time::sleep(pause) => {}
            _ = term.recv() => return Ok(()),
        }
    }
}
