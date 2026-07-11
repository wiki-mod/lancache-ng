//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Kea's known-good configuration snapshot adapter (#614, follow-up to
//! #415). See `docs/known-good-config-snapshots.md` for the full contract
//! this reimplements: validate-before-snapshot, `KEEP_KNOWN_GOOD_CONFIGS`
//! retention (default 3, oldest pruned first), and the
//! `[known-good-snapshot][<service>][<LEVEL>]` log vocabulary
//! (`CREATE`/`PRUNE`/`SELECT`/`REJECT`/`FATAL`) shared with the nginx/
//! dnsmasq/PowerDNS shell adapters (`scripts/lib/known-good-snapshots.sh`).
//!
//! This is NOT a byte-identical embedded copy of that shell library like the
//! other three adapters carry, and `tests/bats/known_good_snapshots_sync.bats`
//! deliberately does not cover this file: Kea's config is mutated live
//! through this Admin UI's own HTTP client against the Kea Control Agent
//! (see `routes/dhcp.rs`'s `kea_config_modify`), not regenerated from a
//! shell template at container startup, so there is nothing here to embed
//! into a shell entrypoint. This module is the Rust-native equivalent of
//! that shared shell contract, operating on Kea's JSON `Dhcp4` config value
//! instead of flat config files.
//!
//! Snapshot layout on disk, rooted at `<snapshot_root>` (the persistent
//! `kea-data` volume's `config-snapshots/` subdirectory, shared with the
//! `dhcp` container -- see `services/dhcp/entrypoint.sh` for why that
//! subdirectory is chowned to the Admin UI's fixed UID/GID):
//!   `<snapshot_root>/<id>/dhcp4.json`   one file per validated snapshot
//! `<id>` is a fixed-width, lexicographically sortable, monotonically
//! increasing decimal string (nanoseconds since the Unix epoch), so plain
//! string comparison gives chronological order without a separate index
//! file or a chrono/date dependency -- the same reasoning the shell
//! library's `date -u +%Y%m%dT%H%M%S.%N` id serves there.

use serde_json::Value;
use std::fmt;
use std::fs;
use std::io;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const SNAPSHOT_FILE_NAME: &str = "dhcp4.json";
const STAGING_PREFIX: &str = ".staging.";
pub const DEFAULT_KEEP_KNOWN_GOOD_CONFIGS: u32 = 3;

#[derive(Debug)]
pub struct KeaSnapshotError(String);

impl fmt::Display for KeaSnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for KeaSnapshotError {}

fn snapshot_err(message: impl Into<String>) -> KeaSnapshotError {
    KeaSnapshotError(message.into())
}

/// Emits one explicit, greppable log line for every snapshot lifecycle event
/// (create, prune, rollback-select, reject), matching the shell adapters'
/// `[known-good-snapshot][<service>][<LEVEL>]` vocabulary so operators can
/// grep container logs for this pattern across every adapter (nginx,
/// dnsmasq, PowerDNS, Kea) the same way. `level` is intentionally a bare
/// `&str`, not an enum, to keep this a direct, low-ceremony match for the
/// shell library's own `kgs_log` -- the log line itself is the contract,
/// not a typed level.
pub fn kgs_log(level: &str, message: &str) {
    let line = format!("[known-good-snapshot][kea][{level}] {message}");
    match level {
        "FATAL" => tracing::error!("{line}"),
        "REJECT" => tracing::warn!("{line}"),
        _ => tracing::info!("{line}"),
    }
}

fn new_snapshot_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    // u128 nanoseconds-since-epoch currently needs 19 digits; 20 zero-padded
    // digits keeps ids fixed-width (so lexicographic == chronological order)
    // for centuries past today.
    format!("{nanos:020}")
}

/// Recovers the Unix epoch second a snapshot id was created at, for display
/// only. The Admin UI renders this client-side with the same
/// `Intl.DateTimeFormat` helper already used for DHCP lease expiries
/// (`formatDhcpExpiries()` in `templates/dhcp.html`) rather than showing the
/// raw nanosecond id to an operator.
pub fn snapshot_created_unix(id: &str) -> Option<u64> {
    let nanos: u128 = id.parse().ok()?;
    Some((nanos / 1_000_000_000) as u64)
}

// A missing/non-numeric/non-positive keep_n is clamped to the documented
// default of 3 rather than trusted as-is, mirroring the shell library's own
// `kgs_snapshot_prune` clamp -- so a misconfigured KEEP_KNOWN_GOOD_CONFIGS
// can never silently disable retention (this is also clamped once already
// at config load time in `config.rs`'s `env_u32_clamped`; re-clamping here
// is a cheap belt-and-suspenders check for any future caller that passes a
// raw value directly).
fn clamp_keep_n(keep_n: u32) -> u32 {
    if keep_n == 0 {
        DEFAULT_KEEP_KNOWN_GOOD_CONFIGS
    } else {
        keep_n
    }
}

/// Existing snapshot ids under `snapshot_root`, oldest first. Empty (not an
/// error) when `snapshot_root` does not exist yet. Skips `.staging.*`
/// entries (`create_snapshot` assembles a new snapshot there before the
/// final atomic rename, so a process killed mid-write can leave one behind)
/// and any finalized directory missing its `dhcp4.json` payload (should not
/// happen given that atomic rename, but a snapshot with no readable payload
/// is worse than no snapshot at rollback time, so it is excluded rather than
/// surfaced as a phantom, unusable entry).
pub fn list_snapshot_ids(snapshot_root: &Path) -> io::Result<Vec<String>> {
    if !snapshot_root.is_dir() {
        return Ok(Vec::new());
    }

    let mut ids = Vec::new();
    for entry in fs::read_dir(snapshot_root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(STAGING_PREFIX) {
            continue;
        }
        if !entry.path().join(SNAPSHOT_FILE_NAME).is_file() {
            continue;
        }
        ids.push(name);
    }
    ids.sort();
    Ok(ids)
}

/// Reads and parses a previously created snapshot's config back into a
/// `Value`. Callers must only pass an `id` obtained from
/// `list_snapshot_ids` for the same `snapshot_root` (see
/// `routes/dhcp.rs::rollback_kea_snapshot`, which checks membership before
/// calling this) -- that membership check is this module's path-traversal
/// guard, since an unchecked id would otherwise be joined directly onto
/// `snapshot_root`.
pub fn read_snapshot(snapshot_root: &Path, id: &str) -> Result<Value, KeaSnapshotError> {
    let path = snapshot_root.join(id).join(SNAPSHOT_FILE_NAME);
    let raw = fs::read_to_string(&path)
        .map_err(|e| snapshot_err(format!("cannot read known-good snapshot {id}: {e}")))?;
    serde_json::from_str(&raw)
        .map_err(|e| snapshot_err(format!("known-good snapshot {id} is not valid JSON: {e}")))
}

/// Deletes the oldest snapshots beyond `keep_n`, logging one `PRUNE` line
/// per removed snapshot (or `FATAL` if removal itself fails -- pruning
/// failures are logged but do not abort the caller, mirroring the shell
/// adapters' non-fatal treatment of prune errors: a valid, just-created
/// snapshot staying on disk longer than intended is not itself a reason to
/// fail the mutation that produced it).
pub fn prune_snapshots(snapshot_root: &Path, keep_n: u32) -> io::Result<()> {
    let keep_n = clamp_keep_n(keep_n);
    let ids = list_snapshot_ids(snapshot_root)?;
    let excess = ids.len().saturating_sub(keep_n as usize);

    for id in ids.into_iter().take(excess) {
        let dir = snapshot_root.join(&id);
        match fs::remove_dir_all(&dir) {
            Ok(()) => kgs_log(
                "PRUNE",
                &format!("pruned known-good snapshot {id} (retention={keep_n})"),
            ),
            Err(e) => kgs_log("FATAL", &format!("failed to prune snapshot {id}: {e}")),
        }
    }
    Ok(())
}

/// Creates a new known-good snapshot of `config` and prunes beyond
/// `keep_n`. `config` is assumed already validated by the caller's own
/// `config-test` -> `config-set` -> `config-write` chain (see
/// `routes/dhcp.rs::kea_config_modify`) -- this module does not re-validate
/// at creation time, matching issue #614's scope note that the existing
/// rollback path from PR #380 already gates this.
///
/// Assembly happens in a `.staging.<id>` sibling directory that is only
/// `rename`d into its final `<id>` name once the payload is fully written,
/// so a process killed mid-write never leaves a partial snapshot visible to
/// `list_snapshot_ids`/`read_snapshot` (mirrors `kgs_snapshot_create`'s
/// staging-then-atomic-rename in the shell library).
pub fn create_snapshot(
    snapshot_root: &Path,
    keep_n: u32,
    config: &Value,
) -> Result<String, KeaSnapshotError> {
    fs::create_dir_all(snapshot_root).map_err(|e| {
        snapshot_err(format!(
            "cannot create snapshot root {}: {e}",
            snapshot_root.display()
        ))
    })?;

    let id = new_snapshot_id();
    let staging = snapshot_root.join(format!("{STAGING_PREFIX}{id}"));
    fs::create_dir(&staging).map_err(|e| {
        snapshot_err(format!(
            "cannot create staging directory {}: {e}",
            staging.display()
        ))
    })?;

    let payload = serde_json::to_vec_pretty(config)
        .map_err(|e| snapshot_err(format!("cannot serialize candidate config: {e}")))?;
    if let Err(e) = fs::write(staging.join(SNAPSHOT_FILE_NAME), payload) {
        let _ = fs::remove_dir_all(&staging);
        return Err(snapshot_err(format!(
            "failed to write known-good snapshot payload: {e}"
        )));
    }

    let dest = snapshot_root.join(&id);
    if let Err(e) = fs::rename(&staging, &dest) {
        let _ = fs::remove_dir_all(&staging);
        return Err(snapshot_err(format!(
            "failed to finalize known-good snapshot {id}: {e}"
        )));
    }

    kgs_log("CREATE", &format!("created known-good snapshot {id}"));
    if let Err(e) = prune_snapshots(snapshot_root, keep_n) {
        kgs_log(
            "FATAL",
            &format!("prune after creating snapshot {id} failed: {e}"),
        );
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ng-{name}-{stamp}"))
    }

    // Fixed width matters, not just "is a number": `list_snapshot_ids` relies
    // on plain string sorting to equal chronological order, with no separate
    // index file recording creation time. A variable-width decimal (no
    // leading zeros) would sort "10" before "9", silently reordering
    // snapshots and making retention/rollback pick the wrong one.
    #[test]
    fn snapshot_ids_are_fixed_width_and_sort_chronologically() {
        let a = new_snapshot_id();
        let b = new_snapshot_id();
        assert_eq!(a.len(), 20);
        assert!(a.chars().all(|c| c.is_ascii_digit()));
        assert!(b >= a, "later id must sort at or after the earlier one");
    }

    // The Admin UI displays snapshot timestamps client-side (via the same
    // Intl.DateTimeFormat helper used for lease expiries), so the id -> epoch
    // recovery must round-trip correctly, and must fail closed (None, not a
    // panic or a garbage timestamp) for a non-numeric id -- e.g. a stray
    // directory an operator created by hand inside the snapshot root.
    #[test]
    fn snapshot_created_unix_recovers_a_plausible_epoch_second() {
        let id = new_snapshot_id();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let recovered = snapshot_created_unix(&id).expect("id must parse");
        assert!(recovered.abs_diff(now) <= 2);
        assert_eq!(snapshot_created_unix("not-a-number"), None);
    }

    // A fresh install (or a first-ever Kea DHCP mutation) has no
    // config-snapshots directory at all yet -- that must read as "zero
    // snapshots", not an I/O error, so `fetch_kea_snapshot_summaries` can
    // render an empty list instead of failing the whole `/dhcp` page.
    #[test]
    fn list_snapshot_ids_is_empty_for_a_missing_root() {
        let root = temp_dir("kea-snapshots-missing");
        assert_eq!(list_snapshot_ids(&root).unwrap(), Vec::<String>::new());
    }

    // Locks in the basic contract every caller depends on: what
    // `create_snapshot` writes is exactly what `read_snapshot` returns later,
    // and the new id shows up in `list_snapshot_ids` immediately.
    #[test]
    fn create_read_and_list_round_trip() {
        let root = temp_dir("kea-snapshots-roundtrip");
        let config = json!({"Dhcp4": {"subnet4": []}});

        let id = create_snapshot(&root, 3, &config).expect("create must succeed");
        let ids = list_snapshot_ids(&root).unwrap();
        assert_eq!(ids, vec![id.clone()]);

        let loaded = read_snapshot(&root, &id).expect("read must succeed");
        assert_eq!(loaded, config);

        let _ = fs::remove_dir_all(&root);
    }

    // Retention must prune the OLDEST snapshots first, keeping the most
    // recent ones -- pruning newest-first (or in the wrong order) would
    // throw away exactly the configs an operator is most likely to want to
    // roll back to, while keeping stale ones nobody asked to preserve.
    #[test]
    fn create_snapshot_prunes_beyond_retention_oldest_first() {
        let root = temp_dir("kea-snapshots-prune");
        let mut ids = Vec::new();
        for i in 0..5 {
            let config = json!({"Dhcp4": {"generation": i}});
            let id = create_snapshot(&root, 3, &config).expect("create must succeed");
            ids.push(id);
            // Snapshot ids are nanosecond timestamps; without a tiny sleep,
            // back-to-back creates in the same test run can (rarely, on a
            // very fast machine) land on the same value and silently
            // collide in `list_snapshot_ids`' sort, making this test flaky.
            std::thread::sleep(std::time::Duration::from_micros(10));
        }

        let remaining = list_snapshot_ids(&root).unwrap();
        assert_eq!(remaining.len(), 3, "only the newest 3 must remain");
        assert_eq!(
            remaining,
            ids[2..].to_vec(),
            "the two oldest snapshots must be the ones pruned"
        );

        let _ = fs::remove_dir_all(&root);
    }

    // `keep_n=0` (from an unset/empty/non-numeric KEEP_KNOWN_GOOD_CONFIGS,
    // per `config.rs`'s `env_u32_clamped`, or a raw `0` passed directly)
    // must NOT be interpreted as "keep zero snapshots" -- that would prune
    // away every snapshot on every single create, including the one that
    // create_snapshot just finished writing, leaving nothing to roll back to
    // the moment a config change is made. It must clamp to the documented
    // default of 3 instead, mirroring the shell library's own
    // `kgs_snapshot_prune` clamp.
    #[test]
    fn prune_clamps_a_zero_keep_n_to_the_documented_default() {
        let root = temp_dir("kea-snapshots-clamp");
        for i in 0..4 {
            create_snapshot(&root, 0, &json!({"Dhcp4": {"generation": i}}))
                .expect("create must succeed");
            std::thread::sleep(std::time::Duration::from_micros(10));
        }

        let remaining = list_snapshot_ids(&root).unwrap();
        assert_eq!(
            remaining.len(),
            DEFAULT_KEEP_KNOWN_GOOD_CONFIGS as usize,
            "keep_n=0 must clamp to the default retention, not disable pruning"
        );

        let _ = fs::remove_dir_all(&root);
    }

    // A `.staging.*` directory is a snapshot `create_snapshot` was still
    // assembling when the process was killed (see its doc comment: files
    // are written into staging first, then renamed into place atomically),
    // and a finalized directory with no `dhcp4.json` payload is likewise
    // unusable. Either one must never be treated as a real snapshot --
    // `read_snapshot`/rollback would either fail outright or, worse, apply a
    // half-written config that was never actually validated as a whole.
    #[test]
    fn list_snapshot_ids_skips_staging_and_incomplete_directories() {
        let root = temp_dir("kea-snapshots-skip");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(root.join(".staging.123")).unwrap();
        fs::create_dir_all(root.join("incomplete-no-payload")).unwrap();
        let real_id =
            create_snapshot(&root, 3, &json!({"Dhcp4": {}})).expect("create must succeed");

        let ids = list_snapshot_ids(&root).unwrap();
        assert_eq!(ids, vec![real_id]);

        let _ = fs::remove_dir_all(&root);
    }

    // `rollback_kea_snapshot` only calls `read_snapshot` for an id it just
    // confirmed via `list_snapshot_ids`, but the two calls are not atomic --
    // this locks in that a missing id still fails with a normal `Err`
    // (rather than panicking) so a snapshot removed between those two calls
    // surfaces as an ordinary rollback failure, not a crash.
    #[test]
    fn read_snapshot_reports_an_error_for_an_unknown_id() {
        let root = temp_dir("kea-snapshots-unknown");
        fs::create_dir_all(&root).unwrap();
        assert!(read_snapshot(&root, "does-not-exist").is_err());
        let _ = fs::remove_dir_all(&root);
    }
}
