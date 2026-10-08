//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: read-only reader of watchdog's status.json.
//! Why: any read failure is Unavailable, never healthy.
//! From: Issue #870

use lancache_common::WatchdogStatus;
use serde::Serialize;
use std::fs;
use std::time::{Duration, SystemTime};

// What: status.json older than this reads as Stale.
// Why: 3x the 30s CHECK_INTERVAL; mtime needs no parse.
const STALE_AFTER: Duration = Duration::from_secs(90);

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

// What: read STATUS_FILE as Fresh, Stale or Unavailable.
// Why: never panics; every failure folds into Unavailable.
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

// What: friendly label for every name watchdog can report
// Why: watchdog now monitors 10 services, was 3.
// From: Issue #1437
pub fn display_label(container_name: &str) -> String {
    match container_name {
        "lancache-proxy" => "Proxy".to_string(),
        "lancache-dns-standard" => "DNS (standard)".to_string(),
        "lancache-dns-ssl" => "DNS (SSL)".to_string(),
        "lancache-nats" => "NATS".to_string(),
        "lancache-ui" => "Admin UI".to_string(),
        "lancache-netdata" => "Netdata".to_string(),
        "lancache-dhcp" => "DHCP (Kea)".to_string(),
        "lancache-dhcp-proxy" => "DHCP (proxy/relay)".to_string(),
        "lancache-syslog" => "Central logging".to_string(),
        "lancache-ntp" => "NTP".to_string(),
        other => other.to_string(),
    }
}

// What: sort order for every name watchdog can report
// Why: restart-capable services sort before alert-only ones
// From: Issue #1437
fn display_priority(container_name: &str) -> (u8, &str) {
    match container_name {
        "lancache-proxy" => (0, container_name),
        "lancache-dns-standard" => (1, container_name),
        "lancache-dns-ssl" => (2, container_name),
        "lancache-nats" => (3, container_name),
        "lancache-ui" => (4, container_name),
        "lancache-dhcp" => (5, container_name),
        "lancache-dhcp-proxy" => (6, container_name),
        "lancache-ntp" => (7, container_name),
        "lancache-syslog" => (8, container_name),
        "lancache-netdata" => (9, container_name),
        other => (10, other),
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

    // What: a file older than STALE_AFTER reads as Stale.
    // Why: a dead watchdog must not show healthy forever.
    #[test]
    fn stale_file_is_reported_as_stale_not_fresh() {
        let path = temp_path("stale");
        fs::write(
            &path,
            r#"{"updated":"2020-01-01T00:00:00Z","services":{},"disk":{"cache":{"pct":0,"status":"green"}}}"#,
        )
        .unwrap();
        let backdated = UNIX_EPOCH + Duration::from_secs(1_577_836_800);
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(backdated)
            .unwrap();

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
        assert_eq!(display_label("lancache-nats"), "NATS");
        assert_eq!(display_label("lancache-ui"), "Admin UI");
        assert_eq!(display_label("lancache-netdata"), "Netdata");
        assert_eq!(display_label("lancache-dhcp"), "DHCP (Kea)");
        assert_eq!(display_label("lancache-dhcp-proxy"), "DHCP (proxy/relay)");
        assert_eq!(display_label("lancache-syslog"), "Central logging");
        assert_eq!(display_label("lancache-ntp"), "NTP");
        assert_eq!(display_label("some-future-service"), "some-future-service");
    }

    // What: alert-only services sort before unrecognized names
    // Why: was missing, they'd sort with undefined HashMap order
    // From: Issue #1437
    #[test]
    fn display_priority_sorts_alert_only_services_before_unknown_names() {
        let mut names = vec![
            "some-future-service",
            "lancache-netdata",
            "lancache-proxy",
            "lancache-nats",
        ];
        names.sort_by(|a, b| display_priority(a).cmp(&display_priority(b)));
        assert_eq!(
            names,
            vec![
                "lancache-proxy",
                "lancache-nats",
                "lancache-netdata",
                "some-future-service",
            ]
        );
    }
}
