//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Reader for `services/watchdog/watchdog.sh`'s `status.json` (issue #870,
//! bug-hunt findings #2/#3 in `docs/bug-hunt/observability.md`). Watchdog
//! already computes per-service health color and cache-disk usage color
//! into this file every `CHECK_INTERVAL` (default 30s), but nothing in the
//! Admin UI read it before this module -- `docs/architecture-ng.md` and
//! `docs/threat-model.md`'s T9 both documented the resulting dashboard
//! "traffic light bar" as if it existed. This module is a pure, read-only
//! consumer: it never writes `status.json` (watchdog remains the sole
//! writer) and never restarts or mutates anything, so it carries none of
//! the AG-OP-006..013 idempotence/convergence obligations that apply to
//! stateful write paths.
//!
//! Deliberately tolerant of every failure mode: a missing file (an install
//! that doesn't run watchdog, or the `ui` container started before
//! watchdog's first 30s write), a malformed/partial file (caught mid-write
//! without the atomic rename -- shouldn't happen given watchdog's
//! write-to-`.tmp`-then-`rename` pattern, but a reader must not assume a
//! writer it doesn't control never races), and a stale file (watchdog
//! crashed or was stopped, leaving old content behind) all resolve to
//! `None`/`Stale` rather than a panic or a misleadingly "healthy" render.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::time::{Duration, SystemTime};

// If status.json's mtime is older than this, treat it as stale rather than
// trusting its content. Watchdog's default CHECK_INTERVAL is 30s and it
// writes status.json twice per loop iteration (see watchdog.sh's main loop),
// so a healthy watchdog never leaves this file older than ~30s. 90s (3x the
// default interval) tolerates a slow cycle (e.g. a `maybe_purge()` scan
// running long) without false-flagging a live watchdog as stale, while still
// catching a genuinely stopped/crashed watchdog well before an operator would
// otherwise notice. Using the file's mtime (not the JSON `updated` field)
// means a stale read never depends on successfully parsing the file first.
const STALE_AFTER: Duration = Duration::from_secs(90);

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ServiceHealth {
    // health_color()'s output in watchdog.sh: "green"/"yellow"/"red". Passed
    // through verbatim rather than re-derived here -- watchdog is the single
    // source of truth for what each color means (see its own health_color()
    // doc comment), and duplicating that mapping in Rust would risk the two
    // drifting the same way SYSLOG_ENABLED's parsing once did (#877).
    pub status: String,
    // Raw Docker health string ("healthy"/"unhealthy"/"starting"/"none"/
    // "unreachable") -- shown as a tooltip/detail, not the color itself.
    pub health: String,
    pub failures: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DiskHealth {
    pub pct: u32,
    pub status: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct DiskInfo {
    pub cache: DiskHealth,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct WatchdogStatus {
    pub updated: String,
    // HashMap, not a fixed struct with named proxy/dns_standard/dns_ssl
    // fields: watchdog.sh omits the dns-ssl entry entirely when
    // SSL_ENABLED=0 (see write_status()'s `ssl_services` construction), so
    // the *set* of keys present is itself meaningful and must be rendered
    // as-is rather than assumed to always be exactly three fixed names.
    pub services: HashMap<String, ServiceHealth>,
    pub disk: DiskInfo,
}

// Three-way outcome the dashboard renders distinctly (see templates/
// dashboard.html): a missing/unparseable file is a different situation from
// a stale-but-parseable one, which is different again from fresh data --
// collapsing "no file" and "stale file" into one "unknown" state would hide
// the difference between "watchdog was never wired up here" and "watchdog
// was working and then stopped," which is exactly the operator-visibility
// gap this feature exists to close.
pub enum WatchdogStatusReadResult {
    Fresh(WatchdogStatus),
    // Carries the parsed content too -- a stale reading is still worth
    // showing (grayed out) with its last-known values and an explicit
    // "last updated Ns ago", rather than blanking the whole card.
    Stale(WatchdogStatus, Duration),
    Unavailable,
}

// Reads and parses `path` (STATUS_FILE, see config.rs's
// `watchdog_status_file`), classifying the result as Fresh/Stale/
// Unavailable. Never panics: every failure mode (missing file, permission
// error, malformed JSON, a metadata() call that itself fails) folds into
// `Unavailable` rather than propagating an error the dashboard route would
// have to handle specially. This mirrors how `dashboard.rs`'s other
// collectors (get_cache_size_gb, get_log_stats) already treat their own
// blocking I/O -- see AppState callers wrapping this in spawn_blocking.
pub fn read_status(path: &str) -> WatchdogStatusReadResult {
    let metadata = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return WatchdogStatusReadResult::Unavailable,
    };

    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return WatchdogStatusReadResult::Unavailable,
    };

    let parsed: WatchdogStatus = match serde_json::from_str(&content) {
        Ok(p) => p,
        Err(_) => return WatchdogStatusReadResult::Unavailable,
    };

    let age = match metadata.modified() {
        Ok(modified) => SystemTime::now()
            .duration_since(modified)
            .unwrap_or(Duration::ZERO),
        // A filesystem that can't report mtime at all (unusual, but not this
        // module's business to assume away) is treated the same as "can't
        // prove freshness" -- fail toward Stale, not toward trusting an
        // unverifiable timestamp as Fresh.
        Err(_) => return WatchdogStatusReadResult::Stale(parsed, STALE_AFTER),
    };

    if age > STALE_AFTER {
        WatchdogStatusReadResult::Stale(parsed, age)
    } else {
        WatchdogStatusReadResult::Fresh(parsed)
    }
}

// Human-friendly label for a container name watchdog.sh reports. Falls back
// to the raw key for anything unrecognized (e.g. an operator-renamed
// container, or a future service watchdog starts monitoring) rather than
// hiding it -- see watchdog.sh's own C_PROXY/C_DNS_STD/C_DNS_SSL comment for
// why these exact literal names are the only ones watchdog can actually
// report today (renaming isn't wired through the socket-proxy allowlist).
pub fn display_label(container_name: &str) -> String {
    match container_name {
        "lancache-proxy" => "Proxy".to_string(),
        "lancache-dns-standard" => "DNS (standard)".to_string(),
        "lancache-dns-ssl" => "DNS (SSL)".to_string(),
        other => other.to_string(),
    }
}

// Fixed priority for the three names watchdog.sh can currently report (see
// its C_PROXY/C_DNS_STD/C_DNS_SSL comment), lowest sorts first. Anything
// unrecognized sorts after all three, alphabetically among itself.
fn display_priority(container_name: &str) -> (u8, &str) {
    match container_name {
        "lancache-proxy" => (0, container_name),
        "lancache-dns-standard" => (1, container_name),
        "lancache-dns-ssl" => (2, container_name),
        other => (3, other),
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct ServiceHealthView {
    pub name: String,
    pub label: String,
    pub status: String,
    pub health: String,
    pub failures: u32,
}

// Converts the HashMap `WatchdogStatus.services` into a stably-ordered Vec
// for template/JSON rendering. A plain HashMap must never be iterated
// directly for user-facing display: Rust's default hasher randomizes
// iteration order per process, so the same dashboard could list services in
// a different order on every container restart with no code change --
// confusing for an operator comparing two screenshots, and pointlessly
// flaky for any UI test asserting on rendered order.
pub fn sorted_service_views(status: &WatchdogStatus) -> Vec<ServiceHealthView> {
    let mut entries: Vec<ServiceHealthView> = status
        .services
        .iter()
        .map(|(name, health)| ServiceHealthView {
            name: name.clone(),
            label: display_label(name),
            status: health.status.clone(),
            health: health.health.clone(),
            failures: health.failures,
        })
        .collect();
    entries.sort_by(|a, b| display_priority(&a.name).cmp(&display_priority(&b.name)));
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;
    use std::time::{SystemTime as StdSystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> std::path::PathBuf {
        let stamp = StdSystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "lancache-ng-watchdog-status-test-{name}-{}-{stamp}",
            process::id()
        ))
    }

    // A never-written path (no watchdog container mounted, or watchdog
    // hasn't completed its first write yet) must render as "unavailable,"
    // not panic or silently show a fabricated healthy state.
    #[test]
    fn missing_file_is_unavailable() {
        let path = temp_path("missing");
        let result = read_status(path.to_str().unwrap());
        assert!(matches!(result, WatchdogStatusReadResult::Unavailable));
    }

    // A partially-written or corrupted file (should not happen given
    // watchdog's atomic rename, but a reader must not trust its writer
    // blindly) must also fail closed to Unavailable, not panic the request.
    #[test]
    fn malformed_json_is_unavailable() {
        let path = temp_path("malformed");
        fs::write(&path, "{ not valid json").unwrap();
        let result = read_status(path.to_str().unwrap());
        assert!(matches!(result, WatchdogStatusReadResult::Unavailable));
        fs::remove_file(&path).ok();
    }

    // A freshly-written, well-formed file (the common case) must parse into
    // exactly the services/disk data watchdog wrote, including a service
    // that is entirely absent from the map (dns-ssl when SSL_ENABLED=0) --
    // this must not be padded in with a fabricated "unknown" entry.
    #[test]
    fn fresh_file_parses_and_omits_absent_ssl_service() {
        let path = temp_path("fresh");
        fs::write(
            &path,
            r#"{
  "updated": "2026-07-22T00:00:00Z",
  "services": {
    "lancache-proxy": {"status": "green", "health": "healthy", "failures": 0},
    "lancache-dns-standard": {"status": "green", "health": "healthy", "failures": 0}
  },
  "disk": {
    "cache": {"pct": 42, "status": "green"}
  }
}"#,
        )
        .unwrap();

        let result = read_status(path.to_str().unwrap());
        match result {
            WatchdogStatusReadResult::Fresh(status) => {
                assert_eq!(status.services.len(), 2);
                assert!(!status.services.contains_key("lancache-dns-ssl"));
                assert_eq!(status.services["lancache-proxy"].status, "green");
                assert_eq!(status.disk.cache.pct, 42);
            }
            _ => panic!("expected Fresh, got a non-Fresh result"),
        }
        fs::remove_file(&path).ok();
    }

    // A file older than STALE_AFTER must be reported as Stale (with its
    // parsed content still attached for a grayed-out "last known" render),
    // not silently treated as current -- this is the exact gap (a crashed
    // watchdog leaving a stale-but-present status.json reading as healthy
    // forever) that motivated using mtime rather than trusting the file's
    // own "updated" field blindly.
    #[test]
    fn stale_file_is_reported_as_stale_not_fresh() {
        let path = temp_path("stale");
        fs::write(
            &path,
            r#"{"updated":"2020-01-01T00:00:00Z","services":{},"disk":{"cache":{"pct":0,"status":"green"}}}"#,
        )
        .unwrap();

        // Backdate the file's mtime well past STALE_AFTER. filetime isn't a
        // dependency of this crate, so this shells out to `touch -d`, which
        // is only available in the CI/build-tools Linux environment this
        // test runs in (never on a developer's Windows host per this
        // project's "no local Windows testing" convention) -- acceptable
        // here because the test is skipped (not failed) if `touch` itself is
        // unavailable, rather than asserting a false pass.
        let touch_ok = std::process::Command::new("touch")
            .arg("-d")
            .arg("2020-01-01T00:00:00")
            .arg(&path)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !touch_ok {
            fs::remove_file(&path).ok();
            eprintln!(
                "skipping stale_file_is_reported_as_stale_not_fresh: `touch -d` unavailable on this host"
            );
            return;
        }

        let result = read_status(path.to_str().unwrap());
        match result {
            WatchdogStatusReadResult::Stale(status, age) => {
                assert!(age >= STALE_AFTER);
                assert_eq!(status.disk.cache.pct, 0);
            }
            _ => panic!("expected Stale, got a different variant"),
        }
        fs::remove_file(&path).ok();
    }

    #[test]
    fn display_label_maps_known_container_names_and_falls_back_for_unknown() {
        assert_eq!(display_label("lancache-proxy"), "Proxy");
        assert_eq!(display_label("lancache-dns-standard"), "DNS (standard)");
        assert_eq!(display_label("lancache-dns-ssl"), "DNS (SSL)");
        assert_eq!(display_label("some-future-service"), "some-future-service");
    }
}
