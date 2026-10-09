//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: behavior used by more than one service binary.
//! Why: one owner per shared rule; services call it.
//! From: Issue #1683 | PR #1858

pub mod config;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskHealth {
    pub pct: u32,
    pub status: String,
}

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

// What: write a whole file; readers see all of it or none.
// Why: one write path for secrets, settings and status.
pub fn write_file(path: &Path, contents: &[u8], mode: u32, place: Place) -> io::Result<()> {
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
            file.sync_all()
        })
        .and_then(|()| match place {
            Place::Exclusive => fs::hard_link(&tmp, path),
            // What: a busy target is rewritten in place.
            // Why: a single-file bind mount refuses a rename.
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
    // Why: the result above is the outcome, not the cleanup.
    let _ = fs::remove_file(&tmp);
    placed
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
                // What: a concurrent start created it first.
                // Why: the first writer's secret is the one.
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
}
