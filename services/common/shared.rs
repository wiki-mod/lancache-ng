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
use std::time::{SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

// What: health of one service in watchdog's status.json.
// Why: watchdog writes it and the ui reads it; one schema.
// From: Issue #870
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceHealth {
    // What: color: green, yellow, amber or red.
    // Why: the ui passes it through, never re-derives it.
    pub status: String,
    // What: raw health string shown as detail.
    // Why: shown as detail next to the color.
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
    let text = String::from_utf8_lossy(&output.stdout);
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

// What: one lancache.dns.record message on NATS.
// Why: ui and subscriber publish it; the subscriber reads it.
// From: Issue #1252
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
    // Why: operators search the logs for this exact vocabulary.
    pub fn log(&self, level: &str, message: &str) {
        eprintln!("[known-good-snapshot][{}][{level}] {message}", self.service);
    }

    // What: snapshot ids, oldest first; none if no root yet.
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
    // Why: the id is joined onto a path, so it must be safe.
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
    // Why: staging plus rename; a crash leaves no partial one.
    pub fn create(&self, data: &Value, keep_n: u32) -> anyhow::Result<String> {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let id = format!("{nanos:020}");
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
    // Why: a failed removal is logged, never fails the write.
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
// Why: the ui shows it; ids are nanoseconds since the epoch.
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
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
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
    // What: converge mode and owner on an unchanged file too.
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

#[cfg(test)]
mod tests {
    use super::*;

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

    // What: record and flush messages keep their wire shape.
    // Why: publishers omit unset fields; consumers default them.
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
        let full = r#"{"domain":"h.lan.","zone":"lan","record_type":"A","expected_content":["10.0.0.5"],"expected_ttl":60}"#;
        let req: FlushRequest = serde_json::from_str(full).unwrap();
        assert_eq!(req.expected_ttl, Some(60));
        assert_eq!(req.expected_content, Some(vec!["10.0.0.5".to_string()]));
    }

    // What: an id yields its second; non-numbers yield none.
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
