//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! PowerDNS zone/record known-good snapshot adapter (#628, the zone/record
//! rollback design deferred by #615/#625's static-`pdns.conf`/`recursor.conf`
//! -only PowerDNS adapter). See docs/known-good-config-snapshots.md's "Zones,
//! records, and TSIG/DDNS metadata" section for the full design this
//! implements -- every decision below traces back to a paragraph there.
//!
//! Mirrors services/ui/src/kea_snapshots.rs's pattern exactly (generic over
//! `serde_json::Value`, not a zone-specific typed struct), not the shell
//! `kgs_*` library embedded in services/dns/entrypoint.sh: `nats-subscriber`
//! is a compiled Rust binary in its own process (started as a separate
//! process by entrypoint.sh, see its `run_nats_subscriber()`), so it cannot
//! call entrypoint.sh's shell functions, and `scripts/lib/known-good-
//! snapshots.sh` is not copied into this image's build context at all.
//!
//! Snapshot layout, rooted at `<snapshot_root>` (one root per zone -- see
//! `zone_snapshot_root`, which nests under `${DNS_CONFIG_SNAPSHOT_DIR}/zones/
//! <zone>`, alongside but distinct from the existing `recursor/`/`auth/`
//! static-config snapshot roots that same env var already parents):
//!   `<snapshot_root>/<id>/zone.json`   one file per validated snapshot,
//!     holding the JSON rrsets array from `GET .../zones/<zone>` -- with
//!     SOA/NS excluded (see `filter_data_rrsets`) so a rollback can never
//!     rewrite the zone's own SOA serial or NS records.
//! `<id>` is a fixed-width, lexicographically sortable, monotonically
//! increasing decimal string (nanoseconds since the Unix epoch) -- the exact
//! same scheme as `kea_snapshots.rs`'s `new_snapshot_id`.

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SNAPSHOT_FILE_NAME: &str = "zone.json";
const STAGING_PREFIX: &str = ".staging.";
pub const DEFAULT_KEEP_KNOWN_GOOD_CONFIGS: u32 = 3;

/// Every zone this adapter is allowed to snapshot or roll back, mirroring
/// `services/dns/entrypoint.sh`'s `DDNS_UPDATE_ZONES` array (`LAN_ZONES` +
/// `PRIVATE_REVERSE_ZONES`) exactly. The two lists must be kept in sync by
/// hand -- there is no automated cross-language check comparable to
/// `tests/bats/known_good_snapshots_sync.bats` (one side is bash, the other
/// Rust) -- but `zone_list_matches_entrypoint_ddns_update_zones` below pins
/// the exact expected contents so a future edit to either list that forgets
/// its counterpart fails a test instead of silently drifting.
///
/// Per docs/known-good-config-snapshots.md's "Scope decision": the RPZ zone
/// (`rpz.`, fully reproducible from `cdn-domains.txt` on every restart) and
/// TSIG/DDNS metadata are deliberately NOT in this list and must never be
/// snapshotted or rolled back through this mechanism -- `is_rollback_zone`
/// is the single gate every caller (both snapshot triggers and the rollback
/// listener) must check before touching a zone.
pub const ROLLBACK_ZONES: &[&str] = &[
    "lan.",
    "local.lan.",
    "10.in-addr.arpa.",
    "168.192.in-addr.arpa.",
    "16.172.in-addr.arpa.",
    "17.172.in-addr.arpa.",
    "18.172.in-addr.arpa.",
    "19.172.in-addr.arpa.",
    "20.172.in-addr.arpa.",
    "21.172.in-addr.arpa.",
    "22.172.in-addr.arpa.",
    "23.172.in-addr.arpa.",
    "24.172.in-addr.arpa.",
    "25.172.in-addr.arpa.",
    "26.172.in-addr.arpa.",
    "27.172.in-addr.arpa.",
    "28.172.in-addr.arpa.",
    "29.172.in-addr.arpa.",
    "30.172.in-addr.arpa.",
    "31.172.in-addr.arpa.",
    "c.f.ip6.arpa.",
    "d.f.ip6.arpa.",
];

/// Whether `zone` (expected in canonical, dot-terminated form -- see
/// `canonical_zone`) is one of the zones this adapter manages. Every caller
/// that snapshots or rolls back a zone must check this first: it is the only
/// thing standing between an over-broad request (e.g. `rpz.`, or a typo) and
/// this mechanism silently doing something docs/known-good-config-
/// snapshots.md's scope decision explicitly says it must not do.
pub fn is_rollback_zone(zone: &str) -> bool {
    ROLLBACK_ZONES.contains(&zone)
}

/// Normalizes a zone name to the canonical, dot-terminated form used as
/// `ROLLBACK_ZONES` keys and snapshot directory names. Callers may receive
/// either form: `handle_dns_record`'s `DNSRecord.zone` field (published by
/// the Admin UI/reconciler) uses the bare "lan" form, while
/// `entrypoint.sh`'s zone arrays and `pdnsutil`/AXFR conventions use the
/// dotted "lan." form.
pub fn canonical_zone(zone: &str) -> String {
    if zone.ends_with('.') {
        zone.to_string()
    } else {
        format!("{zone}.")
    }
}

/// PowerDNS's HTTP API zone id in the URL path drops the trailing root dot
/// that `pdnsutil`/zone-file notation uses -- confirmed by the existing,
/// already-working `handle_dns_record`/`reconciler` calls in `main.rs`, both
/// of which address the `lan.` zone as `.../zones/lan`, never `.../zones/
/// lan.`.
pub fn zone_api_id(zone: &str) -> &str {
    zone.trim_end_matches('.')
}

pub fn zone_snapshot_root(base_snapshot_dir: &Path, zone: &str) -> PathBuf {
    base_snapshot_dir.join("zones").join(zone)
}

#[derive(Debug)]
pub struct ZoneSnapshotError(String);

impl fmt::Display for ZoneSnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ZoneSnapshotError {}

fn snapshot_err(message: impl Into<String>) -> ZoneSnapshotError {
    ZoneSnapshotError(message.into())
}

/// Emits one explicit, greppable log line for every snapshot lifecycle event
/// (create, prune, rollback-select, reject/fatal), matching the shell
/// adapters' and `kea_snapshots.rs`'s `[known-good-snapshot][<service>]
/// [<LEVEL>]` vocabulary. `nats-subscriber` has no `tracing` dependency
/// (unlike the `ui` crate) -- every other diagnostic line in `main.rs`
/// already goes through plain `println!`/`eprintln!`, so this matches that
/// convention rather than pulling in a logging crate for one module. Always
/// written to stderr, mirroring the shell library's `kgs_log` (`>&2`).
pub fn kgs_log(level: &str, message: &str) {
    eprintln!("[known-good-snapshot][dns][{level}] {message}");
}

fn new_snapshot_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    // Fixed-width, zero-padded so lexicographic order == chronological order
    // with no separate index file -- identical reasoning to
    // kea_snapshots.rs's own `new_snapshot_id`.
    format!("{nanos:020}")
}

/// Recovers the Unix epoch second a snapshot id was created at, for display
/// only (the Admin UI renders this client-side, same as Kea's snapshot
/// list).
pub fn snapshot_created_unix(id: &str) -> Option<u64> {
    let nanos: u128 = id.parse().ok()?;
    Some((nanos / 1_000_000_000) as u64)
}

// A missing/non-numeric/non-positive keep_n clamps to the documented
// default of 3, mirroring kea_snapshots.rs's own `clamp_keep_n` -- a
// misconfigured KEEP_KNOWN_GOOD_CONFIGS can never silently disable
// retention.
fn clamp_keep_n(keep_n: u32) -> u32 {
    if keep_n == 0 {
        DEFAULT_KEEP_KNOWN_GOOD_CONFIGS
    } else {
        keep_n
    }
}

/// Existing snapshot ids under `snapshot_root`, oldest first. Empty (not an
/// error) when `snapshot_root` does not exist yet -- a zone whose first
/// snapshot has never been taken must read as "zero snapshots", not an I/O
/// error. Skips `.staging.*` entries (mid-write, see `create_snapshot`) and
/// any finalized directory missing its `zone.json` payload.
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

/// Reads and parses a previously created snapshot's rrsets back into a
/// `Value`. Callers must only pass an `id` obtained from
/// `list_snapshot_ids` for the same `snapshot_root` -- that membership check
/// (done by every caller, see `rollback_listener.rs`) is this module's
/// path-traversal guard, since an unchecked id would otherwise be joined
/// directly onto `snapshot_root`.
pub fn read_snapshot(snapshot_root: &Path, id: &str) -> Result<Value, ZoneSnapshotError> {
    let path = snapshot_root.join(id).join(SNAPSHOT_FILE_NAME);
    let raw = fs::read_to_string(&path)
        .map_err(|e| snapshot_err(format!("cannot read known-good snapshot {id}: {e}")))?;
    serde_json::from_str(&raw)
        .map_err(|e| snapshot_err(format!("known-good snapshot {id} is not valid JSON: {e}")))
}

/// Deletes the oldest snapshots beyond `keep_n`, logging one `PRUNE` line per
/// removed snapshot (or `FATAL` if removal itself fails -- non-fatal to the
/// caller, mirroring the shell adapters' and Kea's own treatment: a valid,
/// just-created snapshot staying on disk longer than intended is not a
/// reason to fail the write that produced it).
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

/// Creates a new known-good snapshot of `data_rrsets` (assumed already
/// filtered via `filter_data_rrsets` by the caller -- this module does not
/// re-filter, so a caller that skips that step would snapshot SOA/NS too)
/// and prunes beyond `keep_n`. Validated by construction, per docs/known-
/// good-config-snapshots.md: this is only ever called after PowerDNS's own
/// `PATCH`/`GET` already accepted the data, so there is no separate
/// candidate-file validation step the other (file-based) adapters need.
///
/// Assembly happens in a `.staging.<id>` sibling directory that is only
/// `rename`d into its final `<id>` name once the payload is fully written,
/// so a process killed mid-write never leaves a partial snapshot visible to
/// `list_snapshot_ids`/`read_snapshot` -- mirrors `kea_snapshots.rs`'s
/// `create_snapshot` exactly.
pub fn create_snapshot(
    snapshot_root: &Path,
    keep_n: u32,
    data_rrsets: &Value,
) -> Result<String, ZoneSnapshotError> {
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

    let payload = serde_json::to_vec_pretty(data_rrsets)
        .map_err(|e| snapshot_err(format!("cannot serialize candidate zone data: {e}")))?;
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

/// Excludes SOA/NS rrsets from a raw `GET .../zones/<zone>` rrsets array,
/// mirroring `main.rs`'s existing `reconciler()` filter
/// (`if rrset.record_type == "SOA" || rrset.record_type == "NS" { continue }`).
///
/// This exclusion is load-bearing for rollback safety, not just noise
/// reduction: a snapshot that captured the SOA would rewind the zone's SOA
/// serial on rollback (breaking incremental transfer to secondaries/
/// AXFR consumers), and -- far more seriously -- if a snapshot excluded SOA/
/// NS but the rollback diff (`build_rollback_patch`) were computed against
/// an *unfiltered* live export, every current SOA/NS rrset would look like
/// "present now, absent from the snapshot" and get `DELETE`d, destroying the
/// zone outright. Filtering both sides through this same function before
/// they ever reach `build_rollback_patch` closes that off entirely: SOA/NS
/// are never a snapshot target and never a diff/rollback target.
pub fn filter_data_rrsets(rrsets: &Value) -> Value {
    let filtered: Vec<Value> = rrsets
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter(|r| {
                    !matches!(
                        r.get("type").and_then(Value::as_str),
                        Some("SOA") | Some("NS")
                    )
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    Value::Array(filtered)
}

fn rrset_key(rrset: &Value) -> (String, String) {
    (
        rrset
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        rrset
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    )
}

fn record_content(record: &Value) -> String {
    record
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Canonicalizes an rrsets JSON array for content comparison: sorts the
/// top-level array by (name, type) and each rrset's own `records` array by
/// `content`, so two exports of an unchanged zone compare equal with plain
/// `==` even if PowerDNS returned the same records in a different order.
/// Comparing canonicalized `Value`s directly (rather than hashing serialized
/// bytes) sidesteps caring about JSON object key order at all, since
/// `serde_json::Value`'s default (non-`preserve_order`) map already
/// normalizes that.
pub fn canonicalize_rrsets(rrsets: &Value) -> Value {
    let mut arr: Vec<Value> = rrsets.as_array().cloned().unwrap_or_default();
    arr.sort_by_key(rrset_key);
    for rrset in arr.iter_mut() {
        if let Some(records) = rrset.get_mut("records").and_then(Value::as_array_mut) {
            records.sort_by_key(record_content);
        }
    }
    Value::Array(arr)
}

fn is_empty_rrsets(rrsets: &Value) -> bool {
    match rrsets.as_array() {
        Some(arr) => arr.is_empty(),
        None => true,
    }
}

/// True when `candidate` (already filtered to data rrsets via
/// `filter_data_rrsets`) is content-identical to the newest stored snapshot
/// for this zone. Load-bearing for both snapshot triggers: the existing
/// `reconciler()` republishes every non-SOA/NS `lan.` rrset unconditionally
/// every 60 seconds regardless of whether anything changed, and a periodic
/// snapshot trigger that didn't compare content would burn through the
/// default retention of 3 snapshots within minutes, pushing out genuinely
/// different history (docs/known-good-config-snapshots.md).
///
/// Also true (skip) when no snapshot exists yet AND `candidate` is empty --
/// a brand-new, still-empty zone needs no snapshot of nothing.
pub fn matches_latest_snapshot(snapshot_root: &Path, candidate: &Value) -> bool {
    let Ok(ids) = list_snapshot_ids(snapshot_root) else {
        return false;
    };
    let Some(latest_id) = ids.last() else {
        return is_empty_rrsets(candidate);
    };
    let Ok(latest) = read_snapshot(snapshot_root, latest_id) else {
        return false;
    };
    canonicalize_rrsets(&latest) == canonicalize_rrsets(candidate)
}

/// Computes the PATCH body that rolls a zone's live data rrsets back to a
/// specific stored snapshot: `REPLACE` for every data rrset present in the
/// snapshot whose content actually differs from (or is absent from) the
/// current live zone, `DELETE` for every live data rrset whose (name, type)
/// key doesn't appear in the snapshot at all (a record added after the
/// snapshot was taken). Rrsets identical on both sides are left out of the
/// patch entirely -- they need no operation, and excluding them keeps
/// `changed_names` (used to decide what to flush from recursor caches)
/// precise rather than over-broad.
///
/// SOA/NS must already be excluded from both `snapshot_rrsets` and
/// `current_rrsets` by the caller (see `filter_data_rrsets`'s doc comment
/// for why that matters here specifically). Mirrors `main.rs`'s
/// `dns_record_to_zone_update`'s REPLACE/DELETE rrset shape so PowerDNS's
/// `PATCH` endpoint accepts this the same way.
pub fn build_rollback_patch(snapshot_rrsets: &Value, current_rrsets: &Value) -> Value {
    let snap_canon = canonicalize_rrsets(snapshot_rrsets);
    let curr_canon = canonicalize_rrsets(current_rrsets);
    let empty = Vec::new();
    let snap_arr = snap_canon.as_array().unwrap_or(&empty);
    let curr_arr = curr_canon.as_array().unwrap_or(&empty);

    let curr_by_key: HashMap<(String, String), &Value> =
        curr_arr.iter().map(|r| (rrset_key(r), r)).collect();
    let snap_keys: HashSet<(String, String)> = snap_arr.iter().map(rrset_key).collect();

    let mut out_rrsets: Vec<Value> = Vec::new();

    for rrset in snap_arr {
        let key = rrset_key(rrset);
        let unchanged = curr_by_key
            .get(&key)
            .is_some_and(|current| *current == rrset);
        if unchanged {
            continue;
        }
        let mut replace = rrset.clone();
        if let Some(obj) = replace.as_object_mut() {
            obj.insert(
                "changetype".to_string(),
                Value::String("REPLACE".to_string()),
            );
        }
        out_rrsets.push(replace);
    }

    for rrset in curr_arr {
        let key = rrset_key(rrset);
        if snap_keys.contains(&key) {
            continue;
        }
        out_rrsets.push(serde_json::json!({
            "name": key.0,
            "type": key.1,
            "changetype": "DELETE",
        }));
    }

    serde_json::json!({ "rrsets": out_rrsets })
}

/// Every (name, type) this rollback's patch touches -- both `REPLACE`d and
/// `DELETE`d keys -- for the caller to flush from both recursors' packet
/// caches afterward. `flush_recursor_cache`'s single-exact-name limitation
/// is documented in `services/ui/src/routes/domains.rs`: a whole-zone or
/// root flush leaves an already-changed leaf record cached until its TTL
/// naturally expires.
pub fn changed_names(patch: &Value) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut names = Vec::new();
    if let Some(rrsets) = patch.get("rrsets").and_then(Value::as_array) {
        for rrset in rrsets {
            if let Some(name) = rrset.get("name").and_then(Value::as_str) {
                if seen.insert(name.to_string()) {
                    names.push(name.to_string());
                }
            }
        }
    }
    names
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ng-dns-{name}-{stamp}"))
    }

    // Pins the exact zone list this adapter manages against
    // services/dns/entrypoint.sh's DDNS_UPDATE_ZONES (LAN_ZONES +
    // PRIVATE_REVERSE_ZONES), the two arrays this const must be kept in
    // sync with by hand. A future edit to either side that forgets its
    // counterpart fails this test instead of silently drifting -- there is
    // no automated bash<->Rust check comparable to
    // tests/bats/known_good_snapshots_sync.bats for this pair.
    #[test]
    fn zone_list_matches_entrypoint_ddns_update_zones() {
        let expected = [
            "lan.",
            "local.lan.",
            "10.in-addr.arpa.",
            "168.192.in-addr.arpa.",
            "16.172.in-addr.arpa.",
            "17.172.in-addr.arpa.",
            "18.172.in-addr.arpa.",
            "19.172.in-addr.arpa.",
            "20.172.in-addr.arpa.",
            "21.172.in-addr.arpa.",
            "22.172.in-addr.arpa.",
            "23.172.in-addr.arpa.",
            "24.172.in-addr.arpa.",
            "25.172.in-addr.arpa.",
            "26.172.in-addr.arpa.",
            "27.172.in-addr.arpa.",
            "28.172.in-addr.arpa.",
            "29.172.in-addr.arpa.",
            "30.172.in-addr.arpa.",
            "31.172.in-addr.arpa.",
            "c.f.ip6.arpa.",
            "d.f.ip6.arpa.",
        ];
        assert_eq!(ROLLBACK_ZONES, &expected);
    }

    #[test]
    fn rollback_zone_gate_accepts_managed_zones_and_rejects_rpz_and_unknowns() {
        assert!(is_rollback_zone("lan."));
        assert!(is_rollback_zone("local.lan."));
        assert!(is_rollback_zone("10.in-addr.arpa."));
        // rpz. is fully reproducible from cdn-domains.txt (Scope decision)
        // and must never be treated as a rollback-managed zone.
        assert!(!is_rollback_zone("rpz."));
        assert!(!is_rollback_zone("example.com."));
        // Non-canonical (missing trailing dot) form must not match -- callers
        // must go through canonical_zone first.
        assert!(!is_rollback_zone("lan"));
    }

    #[test]
    fn canonical_zone_adds_trailing_dot_only_when_missing() {
        assert_eq!(canonical_zone("lan"), "lan.");
        assert_eq!(canonical_zone("lan."), "lan.");
        assert_eq!(canonical_zone("local.lan"), "local.lan.");
    }

    #[test]
    fn zone_api_id_strips_trailing_dot_matching_existing_working_calls() {
        assert_eq!(zone_api_id("lan."), "lan");
        assert_eq!(zone_api_id("local.lan."), "local.lan");
        assert_eq!(zone_api_id("10.in-addr.arpa."), "10.in-addr.arpa");
    }

    // Fixed width matters: list_snapshot_ids relies on plain string sorting
    // to equal chronological order.
    #[test]
    fn snapshot_ids_are_fixed_width_and_sort_chronologically() {
        let a = new_snapshot_id();
        let b = new_snapshot_id();
        assert_eq!(a.len(), 20);
        assert!(a.chars().all(|c| c.is_ascii_digit()));
        assert!(b >= a);
    }

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

    #[test]
    fn list_snapshot_ids_is_empty_for_a_missing_root() {
        let root = temp_dir("missing");
        assert_eq!(list_snapshot_ids(&root).unwrap(), Vec::<String>::new());
    }

    #[test]
    fn create_read_and_list_round_trip() {
        let root = temp_dir("roundtrip");
        let rrsets = json!([
            {"name": "host.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);

        let id = create_snapshot(&root, 3, &rrsets).expect("create must succeed");
        let ids = list_snapshot_ids(&root).unwrap();
        assert_eq!(ids, vec![id.clone()]);

        let loaded = read_snapshot(&root, &id).expect("read must succeed");
        assert_eq!(loaded, rrsets);

        let _ = fs::remove_dir_all(&root);
    }

    // Repeat-run/convergence proof for this adapter's stateful writer
    // (#456/#640's convergence-audit pattern, applied here): calling
    // create_snapshot repeatedly against the same snapshot_root must
    // converge to "exactly the newest keep_n snapshots on disk" regardless
    // of how many times it has already run, not just work correctly once.
    #[test]
    fn create_snapshot_repeat_writes_converge_to_retention_limit_oldest_first() {
        let root = temp_dir("prune");
        let mut ids = Vec::new();
        for i in 0..5 {
            let rrsets =
                json!([{"name": format!("host{i}.lan."), "type": "A", "ttl": 300, "records": []}]);
            let id = create_snapshot(&root, 3, &rrsets).expect("create must succeed");
            ids.push(id);
            std::thread::sleep(std::time::Duration::from_micros(10));
        }

        let remaining = list_snapshot_ids(&root).unwrap();
        assert_eq!(remaining.len(), 3, "only the newest 3 must remain");
        assert_eq!(remaining, ids[2..].to_vec());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn prune_clamps_a_zero_keep_n_to_the_documented_default() {
        let root = temp_dir("clamp");
        for i in 0..4 {
            create_snapshot(
                &root,
                0,
                &json!([{"name": format!("h{i}.lan."), "type": "A", "ttl": 300, "records": []}]),
            )
            .expect("create must succeed");
            std::thread::sleep(std::time::Duration::from_micros(10));
        }

        let remaining = list_snapshot_ids(&root).unwrap();
        assert_eq!(remaining.len(), DEFAULT_KEEP_KNOWN_GOOD_CONFIGS as usize);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn list_snapshot_ids_skips_staging_and_incomplete_directories() {
        let root = temp_dir("skip");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(root.join(".staging.123")).unwrap();
        fs::create_dir_all(root.join("incomplete-no-payload")).unwrap();
        let real_id = create_snapshot(&root, 3, &json!([])).expect("create must succeed");

        let ids = list_snapshot_ids(&root).unwrap();
        assert_eq!(ids, vec![real_id]);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn read_snapshot_reports_an_error_for_an_unknown_id() {
        let root = temp_dir("unknown");
        fs::create_dir_all(&root).unwrap();
        assert!(read_snapshot(&root, "does-not-exist").is_err());
        let _ = fs::remove_dir_all(&root);
    }

    // SOA/NS must never survive into a snapshot candidate -- see
    // filter_data_rrsets's doc comment for why this is a rollback-safety
    // requirement, not just tidiness.
    #[test]
    fn filter_data_rrsets_excludes_soa_and_ns_but_keeps_everything_else() {
        let rrsets = json!([
            {"name": "lan.", "type": "SOA", "ttl": 3600, "records": [{"content": "ns1.lan. admin.lan. 1 3600 900 604800 60", "disabled": false}]},
            {"name": "lan.", "type": "NS", "ttl": 3600, "records": [{"content": "ns1.lan.", "disabled": false}]},
            {"name": "host.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);

        let filtered = filter_data_rrsets(&rrsets);
        let arr = filtered.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["type"], "A");
    }

    #[test]
    fn canonicalize_rrsets_makes_reordered_content_compare_equal() {
        let a = json!([
            {"name": "b.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.2", "disabled": false}]},
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [
                {"content": "10.0.0.2", "disabled": false},
                {"content": "10.0.0.1", "disabled": false}
            ]}
        ]);
        let b = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [
                {"content": "10.0.0.1", "disabled": false},
                {"content": "10.0.0.2", "disabled": false}
            ]},
            {"name": "b.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.2", "disabled": false}]}
        ]);

        assert_eq!(canonicalize_rrsets(&a), canonicalize_rrsets(&b));
    }

    #[test]
    fn matches_latest_snapshot_true_when_content_identical_ignoring_order() {
        let root = temp_dir("matches-true");
        let stored = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);
        create_snapshot(&root, 3, &stored).unwrap();

        // Same content, different array/record order.
        let candidate = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);
        assert!(matches_latest_snapshot(&root, &candidate));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn matches_latest_snapshot_false_when_content_differs() {
        let root = temp_dir("matches-false");
        create_snapshot(
            &root,
            3,
            &json!([{"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}]),
        )
        .unwrap();

        let candidate = json!([{"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.2", "disabled": false}]}]);
        assert!(!matches_latest_snapshot(&root, &candidate));

        let _ = fs::remove_dir_all(&root);
    }

    // A brand-new zone with no snapshots yet and no live records needs no
    // snapshot of nothing -- must skip, not create an empty-array snapshot
    // on every single reconciler/watcher tick.
    #[test]
    fn matches_latest_snapshot_true_for_empty_candidate_with_no_prior_snapshot() {
        let root = temp_dir("matches-empty-noop");
        assert!(matches_latest_snapshot(&root, &json!([])));
    }

    // But a NON-empty candidate with no prior snapshot must NOT be treated
    // as a match -- the very first real content for a zone must always get
    // its first snapshot.
    #[test]
    fn matches_latest_snapshot_false_for_nonempty_candidate_with_no_prior_snapshot() {
        let root = temp_dir("matches-nonempty-first");
        let candidate = json!([{"name": "a.lan.", "type": "A", "ttl": 300, "records": []}]);
        assert!(!matches_latest_snapshot(&root, &candidate));
    }

    #[test]
    fn build_rollback_patch_replaces_snapshot_entries_and_deletes_extra_current_ones() {
        // Snapshot (target state): a.lan. A 10.0.0.1
        let snapshot = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);
        // Current (live): a.lan. A has since changed to 10.0.0.9, and a new
        // b.lan. record was added after the snapshot was taken.
        let current = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.9", "disabled": false}]},
            {"name": "b.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.2", "disabled": false}]}
        ]);

        let patch = build_rollback_patch(&snapshot, &current);
        let rrsets = patch["rrsets"].as_array().unwrap();
        assert_eq!(rrsets.len(), 2);

        let replace = rrsets
            .iter()
            .find(|r| r["changetype"] == "REPLACE")
            .expect("must contain a REPLACE for a.lan.");
        assert_eq!(replace["name"], "a.lan.");
        assert_eq!(replace["records"][0]["content"], "10.0.0.1");

        let delete = rrsets
            .iter()
            .find(|r| r["changetype"] == "DELETE")
            .expect("must contain a DELETE for b.lan.");
        assert_eq!(delete["name"], "b.lan.");
        assert!(delete.get("records").is_none());
    }

    // If the snapshot and the live zone already agree on an rrset, the
    // patch must leave it out entirely -- otherwise every rollback would
    // needlessly touch every record in the zone, and changed_names (used to
    // decide what to flush from recursor caches) would be misleadingly
    // broad.
    #[test]
    fn build_rollback_patch_omits_rrsets_unchanged_between_snapshot_and_current() {
        let same = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);
        let patch = build_rollback_patch(&same, &same);
        assert_eq!(patch["rrsets"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn build_rollback_patch_handles_snapshot_restoring_a_fully_deleted_zone() {
        // Current is empty (everything was deleted since the snapshot);
        // rollback must REPLACE every snapshot rrset back in, with no
        // DELETEs (nothing extra is live to remove).
        let snapshot = json!([
            {"name": "a.lan.", "type": "A", "ttl": 300, "records": [{"content": "10.0.0.1", "disabled": false}]}
        ]);
        let current = json!([]);

        let patch = build_rollback_patch(&snapshot, &current);
        let rrsets = patch["rrsets"].as_array().unwrap();
        assert_eq!(rrsets.len(), 1);
        assert_eq!(rrsets[0]["changetype"], "REPLACE");
    }

    #[test]
    fn changed_names_deduplicates_and_covers_both_replace_and_delete() {
        let patch = json!({
            "rrsets": [
                {"name": "a.lan.", "type": "A", "changetype": "REPLACE"},
                {"name": "a.lan.", "type": "AAAA", "changetype": "REPLACE"},
                {"name": "b.lan.", "type": "A", "changetype": "DELETE"}
            ]
        });
        let mut names = changed_names(&patch);
        names.sort();
        assert_eq!(names, vec!["a.lan.".to_string(), "b.lan.".to_string()]);
    }

    #[test]
    fn zone_snapshot_root_nests_under_zones_subdirectory() {
        let base = PathBuf::from("/var/lib/lancache-dns/config-snapshots");
        assert_eq!(
            zone_snapshot_root(&base, "lan."),
            PathBuf::from("/var/lib/lancache-dns/config-snapshots/zones/lan.")
        );
    }
}
