//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Runtime state file I/O for this crate's main loop, in both directions:
//!
//! - `status.json` production: watchdog.sh's `write_status()`/`disk_info()`,
//!   reshaped as typed structs that deliberately mirror
//!   `services/ui/src/watchdog_status.rs`'s own `WatchdogStatus`/
//!   `ServiceHealth`/`DiskInfo`/`DiskHealth` field-for-field (that module is
//!   the sole reader of this file, so its expected shape is the contract,
//!   not this crate's own preference). The two definitions are intentionally
//!   duplicated rather than shared via a common crate: this project has no
//!   existing shared-library pattern between `services/ui` and any other
//!   service, and introducing one for a handful of struct fields would be a
//!   disproportionate coupling for the benefit gained.
//! - `desired-state.json` consumption (issue #1437): the reverse direction
//!   of the same runtime-state-exchange concern -- `services/ui` is the sole
//!   writer, this crate's main loop is the sole reader, read fresh on every
//!   iteration (see `main.rs`'s `reconcile_desired_state`). Same tolerant-
//!   reader philosophy as `read_status`-equivalent code elsewhere in this
//!   project: a missing or malformed file must never stall or crash the
//!   main loop, and collapses to "no entries", which `reconcile_one`
//!   treats as "no opinion, take no action" -- not "should run". An install
//!   with no such file yet (or one that predates this feature) therefore
//!   behaves exactly as before: watchdog never starts or stops dhcp/ntp on
//!   its own initiative, only when the dock has explicitly said so.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::health::HealthReading;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceHealth {
    /// `health_color()`'s output ("green"/"yellow"/"red") -- watchdog is
    /// the single source of truth for what each color means; the Admin UI
    /// passes this through verbatim rather than re-deriving it.
    pub status: String,
    /// Raw health string ("healthy"/"unhealthy"/"starting"/"none"/
    /// "unreachable") shown as a tooltip/detail.
    pub health: String,
    pub failures: u32,
}

impl ServiceHealth {
    pub fn from_reading(reading: &HealthReading, failures: u32) -> Self {
        Self {
            status: reading.color().to_string(),
            health: reading.as_status_str().to_string(),
            failures,
        }
    }
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchdogStatus {
    pub updated: String,
    // HashMap, not a fixed struct with named proxy/dns_standard/dns_ssl
    // fields -- watchdog.sh omits the dns-ssl entry entirely when
    // SSL_ENABLED=0 (see write_status()'s `ssl_services` construction), so
    // the *set* of keys present is itself meaningful, exactly matching
    // services/ui/src/watchdog_status.rs's own reader-side HashMap.
    pub services: HashMap<String, ServiceHealth>,
    pub disk: DiskInfo,
}

/// Operator-requested run state for a service the main loop now reconciles
/// against reality (issue #1437), written by `services/ui/src/routes/
/// setup.rs`'s `set_service_desired_state`. `serde(rename_all = "lowercase")`
/// makes the on-disk JSON read `"running"`/`"stopped"`, matching this
/// project's existing lowercase-string convention for status/health fields
/// (`ServiceHealth::status`, `HealthReading::as_status_str`) rather than
/// Rust's default `PascalCase` variant names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DesiredRunState {
    Running,
    Stopped,
}

impl DesiredRunState {
    pub fn should_run(self) -> bool {
        matches!(self, Self::Running)
    }
}

/// Sparse override map: an absent key (missing file, or a key the operator
/// never touched) means "no opinion" -- `reconcile_one` takes no start/stop
/// action at all for that service, the always-off-by-default behavior every
/// install already had before this file could exist. Deliberately NOT
/// treated as "should run": `dhcp_mode`/`ntp_enabled` are resolved once at
/// watchdog startup, so a mode switch in progress (settings-reconcile
/// stopping the old container) can leave a stale target here for several
/// minutes -- defaulting an absent entry to "running" would make watchdog
/// fight that in-progress switch and restart what was just deliberately
/// stopped. Only an explicit dock action justifies either action. Only
/// `dhcp` and `ntp` are reconciled today (see `main.rs`'s
/// `reconcile_desired_state`); `dhcp` covers whichever of Kea/dnsmasq is
/// actually provisioned, resolved via `config::dhcp_alert_container`, so
/// this file is keyed by stable service concept rather than by the
/// container name that happens to be active.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct DesiredState {
    #[serde(default)]
    pub dhcp: Option<DesiredRunState>,
    #[serde(default)]
    pub ntp: Option<DesiredRunState>,
}

/// Tolerant reader for `desired-state.json`, called fresh on every main-loop
/// iteration. Every failure mode (missing file, unreadable, malformed JSON)
/// collapses to `DesiredState::default()` (both fields `None`, i.e. "no
/// opinion, take no action" -- see `DesiredState`'s own doc comment) rather
/// than propagating an error -- a transient read glitch or an install that
/// predates this feature must never stop or crash the main loop, mirroring
/// `services/ui/src/watchdog_status.rs`'s own missing-file-is-a-normal-state
/// philosophy for the reverse-direction file.
pub fn read_desired_state(path: &Path) -> DesiredState {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return DesiredState::default(),
    };
    serde_json::from_str(&content).unwrap_or_default()
}

/// Renders the current UTC time as watchdog.sh's `date -u
/// +%Y-%m-%dT%H:%M:%SZ` would -- no fractional seconds, no timezone offset
/// beyond the literal `Z`, matching the exact format `status.json`'s
/// `updated` field has always had.
pub fn format_updated_timestamp(now: time::OffsetDateTime) -> String {
    const FORMAT: &[time::format_description::FormatItem] =
        time::macros::format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    // OffsetDateTime always formats successfully against a fixed, valid
    // format description with no external input -- an Err here would mean
    // the format description itself is broken, a compile-time-checkable
    // programmer error, not a runtime condition callers need to handle.
    now.to_offset(time::UtcOffset::UTC)
        .format(FORMAT)
        .expect("fixed UTC format description must always succeed")
}

/// watchdog.sh's `disk_info()`: percentage-full and traffic-light status
/// for the filesystem backing `dir`. Missing directory -> `{pct: 0, status:
/// "unknown"}`, matching the bash's own early-return for that case
/// (distinct from a `df` command failure with the directory present,
/// which falls through to `pct: 0` with the normal green/yellow/red
/// classification applied to that 0 -- same as the bash's `|| pct=0`
/// fallback keeping the rest of the function's logic running).
///
/// Shells out to the real `df -P` binary rather than reimplementing
/// filesystem-usage math (e.g. via `statvfs`) in Rust: this keeps the
/// exact same rounding/derivation `df` itself uses, so a future dashboard
/// reader can never observe a threshold crossing differently than an
/// operator running `df` by hand would -- reimplementing the percentage
/// calculation independently risked a subtle off-by-one against `df`'s own
/// rounding rules for no real benefit. `-P` forces POSIX output format (one
/// line per filesystem): without it, a long device name (common for
/// overlay/mapper devices) can wrap onto its own line, which would break
/// the fixed line/field parsing below exactly the way it would break the
/// bash's `awk 'NR==2'`.
pub fn disk_info(dir: &Path, warn_pct: u32, alarm_pct: u32) -> DiskHealth {
    if !dir.is_dir() {
        return DiskHealth {
            pct: 0,
            status: "unknown".to_string(),
        };
    }

    let pct = df_percent_full(dir).unwrap_or(0);

    let status = if pct >= alarm_pct {
        "red"
    } else if pct >= warn_pct {
        "yellow"
    } else {
        "green"
    };

    DiskHealth {
        pct,
        status: status.to_string(),
    }
}

// Runs `df -P <dir>` and parses the second line's fifth whitespace-
// separated field (the "Use%" column), stripping the trailing '%' --
// exactly `awk 'NR==2 {gsub(/%/,"",$5); print $5}'`. Returns None on any
// failure (command not found, nonzero exit, unexpected output shape,
// unparseable percentage) so the caller can apply disk_info()'s own
// "treat as 0" fallback uniformly, matching the bash's `|| pct=0`.
fn df_percent_full(dir: &Path) -> Option<u32> {
    let output = Command::new("df").arg("-P").arg(dir).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let data_line = stdout.lines().nth(1)?;
    let use_pct_field = data_line.split_whitespace().nth(4)?;
    use_pct_field.trim_end_matches('%').parse::<u32>().ok()
}

/// Writes `status.json` atomically: same file written to `<path>.tmp` then
/// `rename`d into place, matching watchdog.sh's `write_status()` exactly --
/// a concurrent reader (the Admin UI's `watchdog_status.rs`) must never
/// observe a half-written file.
pub fn write_status(path: &Path, status: &WatchdogStatus) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp_path: PathBuf = {
        let mut p = path.as_os_str().to_owned();
        p.push(".tmp");
        PathBuf::from(p)
    };
    let body = serde_json::to_string_pretty(status).expect(
        "WatchdogStatus contains no non-serializable value (all fields are String/u32/HashMap)",
    );
    fs::write(&tmp_path, body)?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    // Pins the exact "updated" field format status.json has always had:
    // no fractional seconds, no numeric offset, just a literal trailing Z.
    fn format_updated_timestamp_matches_date_dash_u_shape() {
        // Built via the calendar-date constructor (not a hand-computed
        // Unix timestamp) so the expected instant is unambiguous and never
        // depends on getting epoch-seconds arithmetic right by hand.
        let date = time::Date::from_calendar_date(2026, time::Month::January, 2).unwrap();
        let dt = date.with_hms(3, 4, 5).unwrap().assume_utc();
        assert_eq!(format_updated_timestamp(dt), "2026-01-02T03:04:05Z");
    }

    #[test]
    fn disk_info_reports_unknown_for_missing_directory() {
        // A directory name virtually guaranteed not to exist -- built from
        // the current unique test-run timestamp, matching this project's
        // own convention (see AGENTS.md's syslog-forwarding-simulation.sh
        // reference) of deriving disposable unique paths from a real clock
        // read rather than a hardcoded literal that could collide.
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let missing = std::env::temp_dir().join(format!("lancache-watchdog-test-missing-{nonce}"));
        let info = disk_info(&missing, 85, 95);
        assert_eq!(info.pct, 0);
        assert_eq!(info.status, "unknown");
    }

    #[test]
    fn disk_info_classifies_percentage_into_traffic_light_colors() {
        // The real temp dir always exists and is always well under any
        // sane warn/alarm threshold in CI, so pinning warn/alarm at 0
        // deterministically forces the "red" branch without depending on
        // the test host's actual disk usage.
        let dir = std::env::temp_dir();
        let info = disk_info(&dir, 0, 0);
        assert_eq!(info.status, "red");

        let info = disk_info(&dir, 101, 101);
        assert_eq!(info.status, "green");
    }

    #[test]
    // End-to-end round trip: what write_status() writes must be valid JSON
    // that deserializes back into the same shape services/ui/src/
    // watchdog_status.rs expects, and the atomic-rename path must leave no
    // stray .tmp file behind for a concurrent reader to ever observe.
    fn write_status_is_readable_back_with_identical_content() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("lancache-watchdog-test-{nonce}"));
        let path = dir.join("status.json");

        let mut services = HashMap::new();
        services.insert(
            "lancache-proxy".to_string(),
            ServiceHealth {
                status: "green".to_string(),
                health: "healthy".to_string(),
                failures: 0,
            },
        );
        let status = WatchdogStatus {
            updated: "2026-01-02T03:04:05Z".to_string(),
            services,
            disk: DiskInfo {
                cache: DiskHealth {
                    pct: 12,
                    status: "green".to_string(),
                },
            },
        };

        write_status(&path, &status)
            .expect("write_status should create parent dirs and write the file");
        let readback =
            fs::read_to_string(&path).expect("status.json must exist after write_status");
        let parsed: WatchdogStatus =
            serde_json::from_str(&readback).expect("status.json must be valid JSON");
        assert_eq!(parsed.updated, "2026-01-02T03:04:05Z");
        assert_eq!(parsed.services.len(), 1);
        assert_eq!(parsed.disk.cache.pct, 12);
        // Confirms the atomic-rename path: no leftover .tmp file after a
        // successful write (write_status writes to "<path>.tmp" then
        // renames it away).
        let tmp_path = dir.join("status.json.tmp");
        assert!(
            !tmp_path.exists(),
            "the .tmp file must be renamed away, not left behind"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    fn desired_state_temp_path(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "lancache-watchdog-desired-state-{name}-{nonce}.json"
        ))
    }

    // A never-written desired-state file (no install has ever used a dock
    // control, or this install predates the feature) must resolve to "no
    // opinion" for every service -- reconcile_one then takes no start/stop
    // action at all, the same behavior every install already had before
    // this file could exist.
    #[test]
    fn read_desired_state_missing_file_defaults_to_no_action() {
        let path = desired_state_temp_path("missing");
        let state = read_desired_state(&path);
        assert!(state.dhcp.is_none());
        assert!(state.ntp.is_none());
    }

    // A corrupted file must fail closed to "no opinion" (the safe default),
    // not stop the main loop from reconciling other services.
    #[test]
    fn read_desired_state_malformed_json_defaults_to_no_action() {
        let path = desired_state_temp_path("malformed");
        fs::write(&path, "{ not valid json").unwrap();
        let state = read_desired_state(&path);
        assert!(state.dhcp.is_none());
        assert!(state.ntp.is_none());
        let _ = fs::remove_file(&path);
    }

    // The common case: a real operator override round-trips, and an
    // omitted key (ntp here) stays None rather than being padded in as a
    // fabricated "running" value.
    #[test]
    fn read_desired_state_parses_a_real_override() {
        let path = desired_state_temp_path("real");
        fs::write(&path, r#"{"dhcp":"stopped"}"#).unwrap();
        let state = read_desired_state(&path);
        assert_eq!(state.dhcp, Some(DesiredRunState::Stopped));
        assert!(state.ntp.is_none());
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn desired_run_state_should_run_matches_variant() {
        assert!(DesiredRunState::Running.should_run());
        assert!(!DesiredRunState::Stopped.should_run());
    }
}
