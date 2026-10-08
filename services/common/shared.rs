//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: behavior used by more than one service binary.
//! Why: one owner per shared rule; services call it.
//! From: Issue #1683 | PR #1858

pub mod config;

use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

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

// What: create a new file mode 0600, write, fsync.
// Why: exclusive create loses no concurrent start's secret.
// From: Issue #871
pub fn create_secret_file(path: &str, contents: &str) -> std::io::Result<()> {
    let mut open_options = OpenOptions::new();
    open_options.create_new(true).write(true);
    #[cfg(unix)]
    open_options.mode(0o600);
    let mut file = open_options.open(path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()
}

// What: N-byte hex secret; created once, then reused.
// Why: restarts must not rotate it; a bad file fails.
// From: Issue #871
pub fn load_or_create_hex_secret<const N: usize>(path: &str) -> anyhow::Result<[u8; N]> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            let decoded = hex::decode(contents.trim())?;
            let bytes: [u8; N] = decoded.try_into().map_err(|_| {
                anyhow::anyhow!("secret at {path} must be exactly {N} bytes encoded as hex")
            })?;
            Ok(bytes)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let secret: [u8; N] = rand::random();
            create_secret_file(path, &hex::encode(secret))?;
            Ok(secret)
        }
        Err(err) => Err(err.into()),
    }
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

    // What: a created secret reloads unchanged, mode 0600.
    // Why: sessions and credentials must survive a restart.
    // From: Issue #871
    #[test]
    fn hex_secret_persists_and_reloads_same_value() {
        let dir =
            std::env::temp_dir().join(format!("lancache-common-secret-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("temp dir should be creatable");
        let path = dir.join("x.secret");
        let path = path.to_str().expect("temp path is UTF-8");
        let first = load_or_create_hex_secret::<32>(path).expect("first call creates");
        let second = load_or_create_hex_secret::<32>(path).expect("second call reloads");
        assert_eq!(first, second);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(path)
                .expect("secret file exists")
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert!(
            create_secret_file(path, "x").is_err(),
            "create is exclusive"
        );
        fs::remove_dir_all(&dir).ok();
    }
}
