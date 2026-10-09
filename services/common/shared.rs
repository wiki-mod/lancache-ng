//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: behavior used by more than one service binary.
//! Why: one owner per shared rule; services call it.
//! From: Issue #1683 | PR #1858

pub mod config;

use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

// What: health of one service in watchdog's status.json.
// Why: watchdog writes it and the ui reads it; one schema.
// From: Issue #870
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceHealth {
    // What: color: green, yellow, amber or red.
    // Why: the ui passes it through, never re-derives it.
    pub status: String,
    // What: raw health string of the container.
    // Why: the color alone does not say what is wrong.
    pub health: String,
    pub failures: u32,
}

// What: cache disk use in percent and its color.
// Why: the ui renders the color watchdog decided.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskHealth {
    pub pct: u32,
    pub status: String,
}

// What: disk section of status.json; only the cache today.
// Why: a struct keeps room for more volumes later.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskInfo {
    pub cache: DiskHealth,
}

// What: the whole status.json document.
// Why: a map; its keys show whether SSL mode is off.
// From: Issue #870
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchdogStatus {
    pub updated: String,
    pub services: HashMap<String, ServiceHealth>,
    pub disk: DiskInfo,
    // What: the watchdog's check interval in seconds.
    // Why: the ui derives staleness; old files lack it.
    #[serde(default)]
    pub interval_secs: u64,
}

// What: stale limit when the document names no interval.
// Why: an older watchdog wrote none; 90 s was its limit.
const STALE_FALLBACK: Duration = Duration::from_secs(90);

// What: missed check cycles after which status is stale.
// Why: one late cycle is no outage; three are.
const STALE_CYCLES: u32 = 3;

impl WatchdogStatus {
    // What: age beyond which the document counts as stale.
    // Why: the limit follows the watchdog's own interval.
    pub fn stale_after(&self) -> Duration {
        match self.interval_secs {
            0 => STALE_FALLBACK,
            secs => Duration::from_secs(secs).saturating_mul(STALE_CYCLES),
        }
    }
}

// What: operator-requested run state of a service.
// Why: the ui dock writes it, watchdog acts on it.
// From: Issue #1437
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DesiredRunState {
    Running,
    Stopped,
}

// What: desired-state.json; an absent key is no opinion.
// Why: a stale target must not fight a DHCP mode switch.
// From: Issue #1437
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dhcp: Option<DesiredRunState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ntp: Option<DesiredRunState>,
}

impl DesiredState {
    // What: read the file; any failure means no opinion.
    // Why: a read glitch must never stop a caller's loop.
    pub fn read(path: &Path) -> Self {
        fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }
}

// What: space figures of the filesystem holding a path.
// Why: watchdog reads use%, the ui resize check free KiB.
pub struct Df {
    pub avail_kib: u64,
    pub used_pct: u32,
}

// What: figures from `df -Pk <path>`; None on any failure.
// Why: -P keeps one line per mount, so fields never shift.
pub fn df(path: &Path) -> Option<Df> {
    let output = Command::new("df").arg("-Pk").arg(path).output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_df(&String::from_utf8_lossy(&output.stdout))
}

// What: figures from the text of `df -Pk`; None if odd.
// Why: the parse is pure, so a test can feed it any text.
fn parse_df(text: &str) -> Option<Df> {
    let fields: Vec<&str> = text.lines().nth(1)?.split_whitespace().collect();
    Some(Df {
        avail_kib: fields.get(3)?.parse().ok()?,
        used_pct: fields.get(4)?.trim_end_matches('%').parse().ok()?,
    })
}

// What: constant-time equality of two secrets.
// Why: digests first, so a length difference leaks nothing.
pub fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (Sha256::digest(a.as_bytes()), Sha256::digest(b.as_bytes()));
    a.ct_eq(&b).into()
}

// What: nanoseconds since the epoch; 0 for a broken clock.
// Why: ids and temp names need unique, ordered stamps.
pub fn unix_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

// What: seconds since the epoch; 0 for a broken clock.
// Why: callers refuse to issue anything from 1970.
pub fn unix_secs() -> u64 {
    (unix_nanos() / 1_000_000_000) as u64
}

// What: a new empty directory under the temp dir.
// Why: tests of several crates need one scratch path.
pub fn unique_temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "lancache-ng-test-{tag}-{}-{}",
        std::process::id(),
        unix_nanos()
    ));
    fs::create_dir_all(&dir).expect("scratch directory");
    dir
}

// What: print a FATAL start error with its tag, exit 1.
// Why: every service fails closed at start the same way.
pub fn die(tag: &str, message: &str) -> ! {
    eprintln!("[{tag}] FATAL: {message}");
    std::process::exit(1);
}

// What: how long a plain HTTP call may take.
// Why: a stuck peer must not hold a request forever.
pub const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

// What: how long an idle pooled connection is kept.
// Why: a dead peer's connection is not reused for long.
const HTTP_POOL_IDLE: Duration = Duration::from_secs(90);

// What: the interval of TCP keepalive probes.
// Why: a silently dropped peer is noticed on a pooled link.
const HTTP_KEEPALIVE: Duration = Duration::from_secs(60);

// What: the general HTTP client of ui and nats-subscriber.
// Why: one timeout and pool setting for both callers.
pub fn http_client() -> reqwest::Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .pool_idle_timeout(HTTP_POOL_IDLE)
        .tcp_keepalive(HTTP_KEEPALIVE)
        .build()
}

// What: one lancache.dns.record message on NATS.
// Why: ui and subscriber publish it; subscriber reads it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsRecord {
    pub action: String,
    pub zone: String,
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttl: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub records: Option<Vec<HashMap<String, Value>>>,
}

// What: one lancache.dns.flush message on NATS.
// Why: only domain is required; the rest asks to confirm.
// From: Issue #1095
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlushRequest {
    pub domain: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub record_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_content: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_ttl: Option<i32>,
}

// What: known-good snapshots of one JSON document type.
// Why: Kea config and DNS zones share one store and format.
// From: Issue #628
pub struct SnapshotStore {
    pub root: PathBuf,
    file: &'static str,
    service: &'static str,
}

// What: snapshots kept when the setting is 0.
// Why: a bad setting must never disable retention.
const DEFAULT_KEEP: u32 = 3;
// What: marker prefix of a snapshot still being written.
// Why: listing must never show a half-written snapshot.
const STAGING: &str = ".staging.";

impl SnapshotStore {
    // What: a store of `file` payloads under `root`.
    // Why: `service` names the log line vocabulary.
    pub fn new(root: PathBuf, file: &'static str, service: &'static str) -> Self {
        Self {
            root,
            file,
            service,
        }
    }

    // What: one greppable lifecycle line on stderr.
    // Why: operators search the logs for this vocabulary.
    pub fn log(&self, level: &str, message: &str) {
        eprintln!("[known-good-snapshot][{}][{level}] {message}", self.service);
    }

    // What: snapshot ids, oldest first; none without root.
    // Why: fixed-width ids make name order chronological.
    pub fn ids(&self) -> io::Result<Vec<String>> {
        if !self.root.is_dir() {
            return Ok(Vec::new());
        }
        let mut ids = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let complete = entry.file_type()?.is_dir()
                && !name.starts_with(STAGING)
                && entry.path().join(self.file).is_file();
            if complete {
                ids.push(name);
            }
        }
        ids.sort();
        Ok(ids)
    }

    // What: payload of snapshot `id`; only digit ids pass.
    // Why: the id joins onto a path, so it must be safe.
    pub fn read(&self, id: &str) -> anyhow::Result<Value> {
        anyhow::ensure!(
            !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()),
            "rejected known-good snapshot id {id:?}: must be a purely numeric snapshot id"
        );
        let raw = fs::read_to_string(self.root.join(id).join(self.file))
            .with_context(|| format!("cannot read known-good snapshot {id}"))?;
        serde_json::from_str(&raw)
            .with_context(|| format!("known-good snapshot {id} is not valid JSON"))
    }

    // What: write `data` as a new snapshot, then prune.
    // Why: staging plus rename; a crash leaves no partial.
    pub fn create(&self, data: &Value, keep_n: u32) -> anyhow::Result<String> {
        let id = format!("{:020}", unix_nanos());
        let staging = self.root.join(format!("{STAGING}{id}"));
        fs::create_dir_all(&staging)
            .with_context(|| format!("cannot create staging directory {}", staging.display()))?;
        let finish = || -> anyhow::Result<()> {
            fs::write(staging.join(self.file), serde_json::to_vec_pretty(data)?)?;
            Ok(fs::rename(&staging, self.root.join(&id))?)
        };
        if let Err(e) = finish() {
            let _ = fs::remove_dir_all(&staging);
            return Err(e.context(format!("failed to write known-good snapshot {id}")));
        }
        self.log("CREATE", &format!("created known-good snapshot {id}"));
        if let Err(e) = self.prune(keep_n) {
            self.log(
                "FATAL",
                &format!("prune after creating snapshot {id} failed: {e}"),
            );
        }
        Ok(id)
    }

    // What: delete the oldest snapshots beyond keep_n.
    // Why: a failed removal is logged, not a write failure.
    pub fn prune(&self, keep_n: u32) -> io::Result<()> {
        let keep_n = if keep_n == 0 { DEFAULT_KEEP } else { keep_n };
        let ids = self.ids()?;
        let excess = ids.len().saturating_sub(keep_n as usize);
        for id in ids.into_iter().take(excess) {
            match fs::remove_dir_all(self.root.join(&id)) {
                Ok(()) => self.log(
                    "PRUNE",
                    &format!("pruned known-good snapshot {id} (retention={keep_n})"),
                ),
                Err(e) => self.log("FATAL", &format!("failed to prune snapshot {id}: {e}")),
            }
        }
        Ok(())
    }
}

// What: creation time (Unix seconds) encoded in an id.
// Why: the ui shows it; ids are epoch nanoseconds.
pub fn snapshot_created_unix(id: &str) -> Option<u64> {
    Some((id.parse::<u128>().ok()? / 1_000_000_000) as u64)
}

// What: true for empty or a checked-in secret placeholder.
// Why: a public example value must never act as a secret.
// From: Issue #967
pub fn is_placeholder(value: &str) -> bool {
    if value.is_empty() {
        return true;
    }
    let normalized = value.to_lowercase().replace('-', "_");
    normalized.starts_with("change_me_")
        || (normalized.starts_with("your_") && normalized.ends_with("_here"))
        || normalized.starts_with("changeme")
        || normalized.contains("change_me")
        || (normalized.starts_with("lancache_") && normalized.ends_with("_secret"))
        || (value.starts_with('<') && value.ends_with('>'))
}

// What: how write_file treats a file that already exists.
// Why: secrets are created once; settings are replaced.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Place {
    Replace,
    Exclusive,
}

// What: new owner of a written file; None leaves a field.
// Why: root-started services hand files to a runtime user.
pub type Owner = (Option<u32>, Option<u32>);

// What: write a whole file; readers see all of it or none.
// Why: one write path for secrets, settings and status.
pub fn write_file(path: &Path, contents: &[u8], mode: u32, place: Place) -> io::Result<()> {
    write_file_as(path, contents, mode, place, None)
}

// What: write_file that also sets the owner before placing.
// Why: the file must never be visible with the wrong owner.
pub fn write_file_as(
    path: &Path,
    contents: &[u8],
    mode: u32,
    place: Place,
    owner: Option<Owner>,
) -> io::Result<()> {
    // What: create the missing parent directories.
    // Why: a first start finds no state directory yet.
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    let stamp = unix_nanos();
    let tmp = path.with_file_name(format!(
        ".{}.tmp-{}-{stamp}",
        name.to_string_lossy(),
        std::process::id()
    ));
    let placed = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&tmp)
        .and_then(|mut file| {
            file.write_all(contents)?;
            if let Some((uid, gid)) = owner {
                std::os::unix::fs::fchown(&file, uid, gid)?;
            }
            file.sync_all()
        })
        .and_then(|()| match place {
            // What: link the temp file to the final name.
            // Why: a link fails if the name exists; no gap.
            Place::Exclusive => fs::hard_link(&tmp, path),
            // What: a busy target is rewritten in place.
            // Why: a file bind mount refuses a rename.
            Place::Replace => match fs::rename(&tmp, path) {
                Err(e) if e.kind() == io::ErrorKind::ResourceBusy => {
                    let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
                    file.write_all(contents)?;
                    file.sync_all()
                }
                other => other,
            },
        });
    // What: drop the temp name; absent after a rename.
    // Why: the write result stays the outcome.
    let _ = fs::remove_file(&tmp);
    placed
}

// What: replace a file only when its bytes differ.
// Why: reruns write nothing; mode and owner still converge.
pub fn write_if_changed(
    path: &Path,
    contents: &[u8],
    mode: u32,
    owner: Option<Owner>,
) -> io::Result<bool> {
    let changed = fs::read(path).ok().as_deref() != Some(contents);
    if changed {
        write_file_as(path, contents, mode, Place::Replace, owner)?;
    }
    // What: converge mode and owner on unchanged files too.
    // Why: an old install may carry other rights.
    fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(mode))?;
    if let Some((uid, gid)) = owner {
        std::os::unix::fs::lchown(path, uid, gid)?;
    }
    Ok(changed)
}

// What: read a persisted secret, else create it once.
// Why: restarts must not rotate it; a bad file fails.
// From: Issue #871
pub fn load_or_create<T>(
    path: &Path,
    create: impl FnOnce() -> (String, T),
    parse: impl Fn(&str) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    match fs::read_to_string(path) {
        Ok(contents) => parse(contents.trim()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            let (text, value) = create();
            match write_file(path, text.as_bytes(), 0o600, Place::Exclusive) {
                Ok(()) => Ok(value),
                // What: another start created it first.
                // Why: the first writer's secret wins.
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    parse(fs::read_to_string(path)?.trim())
                }
                Err(e) => Err(e.into()),
            }
        }
        Err(err) => Err(err.into()),
    }
}

// What: N-byte hex secret, persisted with load_or_create.
// Why: master and session secrets share this one form.
pub fn load_or_create_hex<const N: usize>(path: &Path) -> anyhow::Result<[u8; N]> {
    load_or_create(
        path,
        || {
            let secret: [u8; N] = rand::random();
            (hex::encode(secret), secret)
        },
        |text| {
            hex::decode(text)?.try_into().map_err(|_| {
                anyhow::anyhow!(
                    "secret at {} must be exactly {N} bytes encoded as hex",
                    path.display()
                )
            })
        },
    )
}

// What: why a Docker call failed.
// Why: callers act on 404 and timeouts, not message text.
#[derive(Debug)]
pub enum DockerError {
    Status(u16),
    Timeout,
    Transport(String),
}

impl std::fmt::Display for DockerError {
    // What: render a DockerError as one line.
    // Why: logs and watchdog output show a short reason.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Status(code) => write!(f, "Docker answered HTTP {code}"),
            Self::Timeout => write!(f, "Docker call timed out"),
            Self::Transport(message) => write!(f, "Docker call failed: {message}"),
        }
    }
}

impl std::error::Error for DockerError {}

// What: Docker log stream text without frame headers.
// Why: a container without a tty multiplexes its streams.
fn log_text(mut bytes: &[u8]) -> String {
    let mut text = String::new();
    while bytes.len() >= 8 {
        let size = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
        let end = bytes.len().min(8usize.saturating_add(size));
        if matches!(bytes[0], 1 | 2) {
            text.push_str(&String::from_utf8_lossy(&bytes[8..end]));
        }
        bytes = &bytes[end..];
    }
    text
}

// What: client of PowerDNS's HTTP API with the API key.
// Why: ui and nats-subscriber call the API the same way.
pub struct PowerDns {
    http: reqwest::Client,
    api_key: String,
}

impl PowerDns {
    // What: a client over an HTTP client and the API key.
    // Why: the key is read once by the service's owner.
    pub fn new(http: reqwest::Client, api_key: String) -> Self {
        Self { http, api_key }
    }

    // What: the API key, for the callers that check it.
    // Why: the same key guards the rollback listener.
    pub fn api_key(&self) -> &str {
        &self.api_key
    }

    // What: one API call carrying the key and a JSON body.
    // Why: every call site shares auth and JSON headers.
    pub async fn call(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<String>,
    ) -> Result<reqwest::Response, String> {
        let mut request = self
            .http
            .request(method, url)
            .header("X-API-Key", &self.api_key);
        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(body);
        }
        request.send().await.map_err(|e| e.to_string())
    }

    // What: the rrsets of one zone, or why there are none.
    // Why: an error body must not read as an empty zone.
    pub async fn zone_rrsets(&self, api_root: &str, zone: &str) -> Result<Vec<Value>, String> {
        let url = config::zone_url(api_root, zone);
        let response = self.call(reqwest::Method::GET, &url, None).await?;
        if !response.status().is_success() {
            return Err(format!("PowerDNS returned {}", response.status()));
        }
        let body: Value = response
            .json()
            .await
            .map_err(|e| format!("cannot decode the zone export: {e}"))?;
        Ok(body
            .get("rrsets")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default())
    }
}

// What: client of the proxy's allowlisted Docker calls.
// Why: ui and watchdog drive containers; one owner.
// From: Issue #1683 | PR #1858
pub struct DockerProxy {
    client: reqwest::Client,
    base_url: String,
}

impl DockerProxy {
    // What: build a client for one proxy base URL.
    // Why: redirects and timeouts must stay under control.
    pub fn new(base_url: &str) -> Self {
        let client = reqwest::Client::builder()
            // What: never follow a redirect.
            // Why: a 3xx could reach an ungranted path.
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("a client without custom TLS settings always builds");
        Self {
            client,
            base_url: base_url.trim().trim_end_matches('/').to_string(),
        }
    }

    // What: one call; the body of a 2xx or 304 answer.
    // Why: 304 means the container already has that state.
    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, DockerError> {
        let failed = |e: reqwest::Error| match e.is_timeout() {
            true => DockerError::Timeout,
            false => DockerError::Transport(e.to_string()),
        };
        let mut request = self
            .client
            .request(method, format!("{}{path}", self.base_url));
        // What: bound connect, headers and body together.
        // Why: a stalled body must not hang the caller.
        if let Some(limit) = timeout {
            request = request.timeout(limit);
        }
        let response = request.send().await.map_err(failed)?;
        let status = response.status();
        if !status.is_success() && status != reqwest::StatusCode::NOT_MODIFIED {
            return Err(DockerError::Status(status.as_u16()));
        }
        response.bytes().await.map(|b| b.to_vec()).map_err(failed)
    }

    // What: container inspect JSON, None on any failure.
    // Why: one read feeds health and running state.
    pub async fn inspect(&self, name: &str, timeout: Option<Duration>) -> Option<Value> {
        let path = format!("/containers/{name}/json");
        let body = self.call(reqwest::Method::GET, &path, timeout).await.ok()?;
        serde_json::from_slice(&body).ok()
    }

    // What: POST one container action like start or stop.
    // Why: one call shape for every state change.
    pub async fn act(
        &self,
        name: &str,
        action: &str,
        timeout: Option<Duration>,
    ) -> Result<(), DockerError> {
        let path = format!("/containers/{name}/{action}");
        self.call(reqwest::Method::POST, &path, timeout)
            .await
            .map(|_| ())
    }

    // What: restart a container after a stop grace period.
    // Why: callers differ in grace; the path is shared.
    pub async fn restart(
        &self,
        name: &str,
        grace_secs: u32,
        timeout: Option<Duration>,
    ) -> Result<(), DockerError> {
        self.act(name, &format!("restart?t={grace_secs}"), timeout)
            .await
    }

    // What: GET /_ping; true only for the body "OK".
    // Why: a 200 stalling before the body must fail.
    pub async fn ping(&self, timeout: Option<Duration>) -> bool {
        matches!(
            self.call(reqwest::Method::GET, "/_ping", timeout).await,
            Ok(body) if body.trim_ascii() == b"OK"
        )
    }

    // What: block until the container stops; its exit code.
    // Why: the DHCP probe is a one-shot container.
    pub async fn wait(&self, name: &str, timeout: Option<Duration>) -> Result<i64, DockerError> {
        let path = format!("/containers/{name}/wait?condition=not-running");
        let body = self.call(reqwest::Method::POST, &path, timeout).await?;
        serde_json::from_slice::<Value>(&body)
            .ok()
            .and_then(|answer| answer.get("StatusCode")?.as_i64())
            .ok_or_else(|| DockerError::Transport("the wait answer has no StatusCode".into()))
    }

    // What: container output since unix time, both streams.
    // Why: the probe result is a line in its output.
    pub async fn logs(
        &self,
        name: &str,
        since: u64,
        timeout: Option<Duration>,
    ) -> Result<String, DockerError> {
        let path = format!("/containers/{name}/logs?stdout=1&stderr=1&since={since}");
        let body = self.call(reqwest::Method::GET, &path, timeout).await?;
        Ok(log_text(&body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: log frames join; other streams, cut tails drop.
    // Why: the probe result line must survive the headers.
    #[test]
    fn log_text_joins_stdout_and_stderr_frames() {
        let frames = [
            &[1, 0, 0, 0, 0, 0, 0, 3][..],
            b"abc",
            &[2, 0, 0, 0, 0, 0, 0, 2][..],
            b"de",
            &[0, 0, 0, 0, 0, 0, 0, 1][..],
            b"x",
            &[1, 0, 0, 0, 0, 0, 0, 9][..],
            b"cut",
        ]
        .concat();
        assert_eq!(log_text(&frames), "abcdecut");
    }

    // What: each known placeholder shape is detected.
    // Why: a shipped example must never pass as a secret.
    // From: Issue #967
    #[test]
    fn is_placeholder_matches_known_shapes() {
        assert!(is_placeholder(""));
        assert!(is_placeholder("CHANGE_ME_now"));
        assert!(is_placeholder("YOUR_STEAM_PASSWORD_HERE"));
        assert!(is_placeholder("<steam-password>"));
        assert!(!is_placeholder("a-real-looking-secret-value"));
    }

    // What: is_placeholder equals the fixture rust column.
    // Why: it must stay in step with the shell detectors.
    // From: Issue #967
    #[test]
    fn is_placeholder_matches_shared_parity_fixture() {
        let path = format!(
            "{}/../../tests/fixtures/placeholder-detection-cases.txt",
            env!("CARGO_MANIFEST_DIR")
        );
        let contents = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("could not read parity fixture {path}: {e}"));
        let mut total = 0usize;
        let mut mismatches: Vec<String> = Vec::new();
        for line in contents.lines().map(str::trim_end) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split_whitespace().collect();
            let [value, _shared, _setup, rust] = fields.as_slice() else {
                panic!("malformed parity fixture line: {line:?}");
            };
            total += 1;
            let actual = if is_placeholder(value) {
                "placeholder"
            } else {
                "real"
            };
            if actual != *rust {
                mismatches.push(format!("'{value}' expected={rust} actual={actual}"));
            }
        }
        assert!(total > 0, "parity fixture had zero usable cases");
        assert!(
            mismatches.is_empty(),
            "{} of {total} fixture case(s) disagreed:\n{}",
            mismatches.len(),
            mismatches.join("\n")
        );
    }

    // What: equal secrets match, any difference does not.
    // Why: callers trust this for API keys and tokens.
    #[test]
    fn ct_eq_matches_only_equal_strings() {
        assert!(ct_eq("secret-key", "secret-key") && ct_eq("", ""));
        assert!(!ct_eq("secret-key", "different-key"));
        assert!(!ct_eq("short", "muchlongerkey") && !ct_eq("", "x"));
    }

    // What: record and flush messages keep the wire shape.
    // Why: publishers omit unset fields; consumers default.
    // From: Issue #1095
    #[test]
    fn dns_messages_round_trip_the_wire_shape() {
        let delete: DnsRecord =
            serde_json::from_str(r#"{"action":"delete","zone":"lan","name":"h.lan.","type":"A"}"#)
                .unwrap();
        assert_eq!((delete.ttl, delete.records.is_none()), (None, true));
        let wire = serde_json::to_value(&delete).unwrap();
        assert_eq!(wire.get("type").and_then(Value::as_str), Some("A"));
        assert!(wire.get("ttl").is_none() && wire.get("records").is_none());
        let old: FlushRequest = serde_json::from_str(r#"{"domain":"host.lan."}"#).unwrap();
        assert_eq!((old.zone, old.expected_content), (None, None));
        let full = r#"{"domain":"h.lan.","zone":"lan","record_type":"A","expected_content":["192.0.2.5"],"expected_ttl":60}"#;
        let req: FlushRequest = serde_json::from_str(full).unwrap();
        assert_eq!(req.expected_ttl, Some(60));
        assert_eq!(req.expected_content, Some(vec!["192.0.2.5".to_string()]));
    }

    // What: stale limit is three intervals, else 90 s.
    // Why: a wrong limit shows live data as stale.
    #[test]
    fn stale_limit_follows_the_interval() {
        let status = |interval_secs| WatchdogStatus {
            updated: String::new(),
            services: HashMap::new(),
            disk: DiskInfo {
                cache: DiskHealth {
                    pct: 0,
                    status: "unknown".into(),
                },
            },
            interval_secs,
        };
        assert_eq!(status(30).stale_after(), Duration::from_secs(90));
        assert_eq!(status(10).stale_after(), Duration::from_secs(30));
        assert_eq!(status(0).stale_after(), Duration::from_secs(90));
        let old: WatchdogStatus = serde_json::from_str(
            r#"{"updated":"x","services":{},"disk":{"cache":{"pct":1,"status":"green"}}}"#,
        )
        .unwrap();
        assert_eq!(old.interval_secs, 0);
    }

    // What: df output parses; odd output gives None.
    // Why: a wrong field would show a wrong disk percent.
    #[test]
    fn df_output_is_parsed_or_refused() {
        let ok = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
                  /dev/sda1 1000 400 600 40% /cache\n";
        let parsed = parse_df(ok).expect("well-formed df output");
        assert_eq!((parsed.avail_kib, parsed.used_pct), (600, 40));
        assert!(parse_df("").is_none());
        assert!(parse_df("header only\n").is_none());
        assert!(parse_df("h\n/dev/sda1 1000 400 x 40% /\n").is_none());
        assert!(parse_df("h\n/dev/sda1 1000 400 600 full /\n").is_none());
    }

    // What: snapshots list oldest first; prune to keep_n.
    // Why: a wrong prune loses the last known-good state.
    // From: Issue #628
    #[test]
    fn snapshot_store_creates_lists_reads_and_prunes() {
        let root = unique_temp_dir("snap");
        let store = SnapshotStore::new(root.join("store"), "data.json", "test");
        assert_eq!(store.ids().unwrap(), Vec::<String>::new());
        let mut made = Vec::new();
        for n in 0..5 {
            made.push(store.create(&serde_json::json!({ "n": n }), 3).unwrap());
            std::thread::sleep(Duration::from_millis(2));
        }
        let kept = store.ids().unwrap();
        assert_eq!(kept, made[2..].to_vec());
        assert_eq!(store.read(&kept[0]).unwrap(), serde_json::json!({ "n": 2 }));
        fs::create_dir_all(root.join("store/.staging.1")).unwrap();
        fs::create_dir_all(root.join("store/00000000000000000009")).unwrap();
        assert_eq!(store.ids().unwrap(), kept);
        for bad in ["", "../x", "12a", "1/2"] {
            assert!(store.read(bad).is_err(), "id {bad:?} must be refused");
        }
        let _ = fs::remove_dir_all(&root);
    }

    // What: keep_n 0 keeps three, never none.
    // Why: a bad retention value must not erase snapshots.
    #[test]
    fn snapshot_store_zero_retention_keeps_three() {
        let root = unique_temp_dir("keep");
        let store = SnapshotStore::new(root.join("store"), "data.json", "test");
        for _ in 0..5 {
            store.create(&serde_json::json!({}), 0).unwrap();
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(store.ids().unwrap().len(), 3);
        let _ = fs::remove_dir_all(&root);
    }

    // What: Exclusive keeps the first file; Replace swaps.
    // Why: secrets are created once; settings are replaced.
    #[test]
    fn write_file_exclusive_keeps_first_and_replace_swaps() {
        use std::os::unix::fs::PermissionsExt;
        let root = unique_temp_dir("write");
        let file = root.join("sub/secret");
        write_file(&file, b"first", 0o600, Place::Exclusive).unwrap();
        let again = write_file(&file, b"second", 0o600, Place::Exclusive);
        assert_eq!(again.unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&file).unwrap(), b"first");
        write_file(&file, b"third", 0o600, Place::Replace).unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"third");
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(fs::read_dir(root.join("sub")).unwrap().count(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    // What: write_if_changed writes once, then fixes mode.
    // Why: reruns write nothing; rights still converge.
    #[test]
    fn write_if_changed_writes_once_and_converges_mode() {
        use std::os::unix::fs::PermissionsExt;
        let root = unique_temp_dir("changed");
        let file = root.join("conf");
        assert!(write_if_changed(&file, b"a", 0o644, None).unwrap());
        assert!(!write_if_changed(&file, b"a", 0o644, None).unwrap());
        assert!(write_if_changed(&file, b"b", 0o644, None).unwrap());
        fs::set_permissions(&file, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(!write_if_changed(&file, b"b", 0o600, None).unwrap());
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = fs::remove_dir_all(&root);
    }

    // What: a secret persists; a bad file is an error.
    // Why: restarts must not rotate it or accept junk.
    #[test]
    fn load_or_create_persists_and_rejects_bad_files() {
        let root = unique_temp_dir("secret");
        let file = root.join("key");
        let first = load_or_create_hex::<4>(&file).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap().len(), 8);
        assert_eq!(load_or_create_hex::<4>(&file).unwrap(), first);
        fs::write(&file, "zz").unwrap();
        assert!(load_or_create_hex::<4>(&file).is_err());
        fs::write(&file, "0011").unwrap();
        assert!(load_or_create_hex::<4>(&file).is_err());
        let _ = fs::remove_dir_all(&root);
    }

    // What: desired state reads, or no opinion on failure.
    // Why: a read glitch must never stop a caller's loop.
    // From: Issue #1437
    #[test]
    fn desired_state_reads_or_gives_no_opinion() {
        let root = unique_temp_dir("desired");
        let file = root.join("desired.json");
        assert_eq!(DesiredState::read(&file), DesiredState::default());
        fs::write(&file, "not json").unwrap();
        assert_eq!(DesiredState::read(&file), DesiredState::default());
        fs::write(&file, r#"{"ntp":"stopped"}"#).unwrap();
        let read = DesiredState::read(&file);
        assert_eq!(
            (read.dhcp, read.ntp),
            (None, Some(DesiredRunState::Stopped))
        );
        let _ = fs::remove_dir_all(&root);
    }

    // What: the proxy client builds and trims its base URL.
    // Why: new() unwraps the builder; this shows it builds.
    #[test]
    fn docker_proxy_builds_and_trims_the_base_url() {
        let proxy = DockerProxy::new(" http://proxy:2375/ ");
        assert_eq!(proxy.base_url, "http://proxy:2375");
    }

    // What: an id yields its second; non-numbers none.
    // Why: the ui lists snapshots by this time.
    #[test]
    fn snapshot_ids_decode_to_unix_seconds() {
        assert_eq!(
            snapshot_created_unix("00000000001700000000000000"),
            Some(1_700_000)
        );
        assert_eq!(snapshot_created_unix("../etc"), None);
    }
}
