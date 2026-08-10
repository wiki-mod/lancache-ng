//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Storage for Netdata alarm-notify events forwarded by the `netdata`
//! container's `custom_sender()` integration (bug hunt #849,
//! `docs/bug-hunt/observability.md` finding #3: Netdata's own health.d
//! alarms had no notification integration or Admin UI surface of their
//! own -- see `deploy/*/docker-compose.yml`'s `netdata:` service command
//! block for the Netdata-side half of this wiring). Unlike
//! `watchdog_status.rs` (a pure, read-only consumer of a file only
//! `watchdog.sh` ever writes), this module is the sole WRITER of its own
//! state file: `routes/netdata_alarms.rs`'s POST handler calls
//! [`append_alarm`] for every incoming alarm event. That makes the
//! AG-OP-006..013 idempotence/convergence obligations apply in full here --
//! see [`append_alarm`]'s own doc comment for the two concrete properties
//! (mutual exclusion and duplicate-delivery idempotence) it must hold.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

// Netdata's alarm-notify.sh can fire many alarms in a short burst (e.g. a
// host reboot re-arms every health.d check at once). Capping the stored
// history bounds both the JSON file's size and the dashboard card's render
// cost. 50 is generous enough to show a real recent-alarm timeline without
// becoming an unbounded log -- the same "recent, not exhaustive" intent
// `dashboard.rs`'s `parse_log_tail(..., 10)` already applies to the nginx
// access-log tail shown on the same page.
pub const MAX_ALARMS: usize = 50;

// One Netdata alarm-notify.sh event, field-for-field matching the variables
// alarm-notify.sh's own custom_sender() integration point receives (see the
// compose command block's health_alarm_notify.conf override) -- deliberately
// not reduced to a smaller subset, since dashboard.html renders most of
// these directly and a future card revision may want the rest.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NetdataAlarmEvent {
    pub unique_id: i64,
    pub alarm_id: i64,
    pub event_id: i64,
    pub when: i64,
    pub name: String,
    pub chart: String,
    pub host: String,
    pub status: String,
    pub old_status: String,
    pub value_string: String,
    pub units: String,
    pub info: String,
    pub duration: i64,
}

// Reads the stored alarm history, newest-first (the order `append_alarm`
// maintains). Every failure mode -- missing file (no alarm has ever arrived,
// or this install predates this feature), unreadable file, or malformed
// JSON -- collapses to an empty Vec rather than propagating an error or
// panicking, mirroring `watchdog_status.rs`'s tolerant-reader philosophy.
// This module is also the sole writer of this same file (unlike
// watchdog_status.rs's reader/writer split across two components), so a
// malformed file here would most likely be this module's own bug rather
// than a foreign writer racing it -- but the dashboard must still degrade to
// "no alarms yet" rather than fail the whole page render either way, and a
// silently-empty recovery gives an operator a working dashboard again on
// the very next successful append instead of a permanent stuck error state.
pub fn read_alarms(path: &str) -> Vec<NetdataAlarmEvent> {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    serde_json::from_str(&content).unwrap_or_default()
}

// Appends one alarm event to the history stored at `path`, keeping only the
// newest MAX_ALARMS entries (newest first). Two properties this function
// must hold, both required by AG-OP-006..013 because -- unlike
// `watchdog.sh`'s single-writer status loop -- this is a genuine concurrent
// write path (multiple POSTs to /api/netdata-alarms can race):
//
//   1. Read-modify-write atomicity: the CALLER must hold a process-wide lock
//      (`AppState::netdata_alarms_lock`) around this call. Without one, two
//      concurrent requests could both read the same starting list, both
//      append their own event, and both rename -- the second rename wins
//      and the first request's event is silently lost. The write-to-temp-
//      then-rename below only protects READERS from ever observing a
//      half-written file mid-write; it does nothing by itself to prevent
//      this lost-update race, which is a different failure mode needing a
//      different fix (mutual exclusion, not write atomicity).
//   2. Idempotence on duplicate delivery: Netdata's built-in `alarm-notify.sh
//      ... test` mode can be re-run, and a real delivery could plausibly be
//      retried (a flaky network hop, an operator re-firing the same test)
//      against the same endpoint for the same event. Deduping on
//      `unique_id` -- Netdata's own claimed-unique identifier for this
//      alarm event -- makes re-appending an already-stored event a no-op
//      instead of a duplicate dashboard entry: the concrete convergence
//      property AG-OP-006 requires of a write path that can be repeated
//      with the same input.
pub fn append_alarm(path: &str, event: NetdataAlarmEvent) -> io::Result<()> {
    let mut events = read_alarms(path);

    if events.iter().any(|e| e.unique_id == event.unique_id) {
        return Ok(());
    }

    events.insert(0, event);
    events.truncate(MAX_ALARMS);

    let json = serde_json::to_string_pretty(&events)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    // Atomic write-then-rename, same pattern watchdog.sh's write_status()
    // uses for status.json: a reader can never observe a partially-written
    // file, since `rename` on the same filesystem is atomic and only ever
    // exposes the old or the new complete content.
    let tmp_path = format!("{path}.tmp");
    fs::write(&tmp_path, json)?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

// Display-only view of a stored alarm event, adding a human-readable UTC
// timestamp string alongside the fields dashboard.html actually renders.
// Mirrors watchdog_status.rs's ServiceHealthView split between "what's
// stored" (NetdataAlarmEvent, field-for-field matching Netdata's own
// alarm-notify.sh variables) and "what a template can render directly" --
// Tera's bundled filter set has no built-in date formatting in this
// project's pinned tera version (see Cargo.toml's `time` dependency comment
// for how that was confirmed), so the timestamp is formatted here instead
// of in the template.
#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct NetdataAlarmView {
    pub unique_id: i64,
    pub name: String,
    pub chart: String,
    pub host: String,
    pub status: String,
    pub value_string: String,
    pub info: String,
    pub when_display: String,
}

// Converts stored events (newest-first, see append_alarm) into their
// template-ready view.
pub fn alarm_views(events: &[NetdataAlarmEvent]) -> Vec<NetdataAlarmView> {
    events
        .iter()
        .map(|e| NetdataAlarmView {
            unique_id: e.unique_id,
            name: e.name.clone(),
            chart: e.chart.clone(),
            host: e.host.clone(),
            status: e.status.clone(),
            value_string: e.value_string.clone(),
            info: e.info.clone(),
            when_display: format_alarm_time(e.when),
        })
        .collect()
}

// Formats a Netdata alarm's Unix timestamp as an RFC 3339 UTC string (e.g.
// "2026-08-06T05:30:00Z"). Falls back to the raw numeric value on any
// conversion failure (an out-of-range timestamp, which should not happen
// for a real Netdata-supplied `when` but must not be trusted blindly given
// this is client-controlled input, per this module's own ingest-robustness
// contract) rather than erroring the whole dashboard render over one
// display field.
fn format_alarm_time(unix_ts: i64) -> String {
    OffsetDateTime::from_unix_timestamp(unix_ts)
        .ok()
        .and_then(|dt| dt.format(&Rfc3339).ok())
        .unwrap_or_else(|| unix_ts.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> std::path::PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "lancache-ng-netdata-alarms-test-{name}-{}-{stamp}.json",
            process::id()
        ))
    }

    fn sample_event(unique_id: i64) -> NetdataAlarmEvent {
        NetdataAlarmEvent {
            unique_id,
            alarm_id: 1,
            event_id: 1,
            when: 1_700_000_000,
            name: "disk_space_usage".to_string(),
            chart: "disk.space_/".to_string(),
            host: "lancache-netdata".to_string(),
            status: "WARNING".to_string(),
            old_status: "CLEAR".to_string(),
            value_string: "85%".to_string(),
            units: "%".to_string(),
            info: "disk space usage".to_string(),
            duration: 0,
        }
    }

    // A never-written path (no alarm has arrived yet) must render as an
    // empty history, not fail the caller -- same "absence is a normal
    // state, not an error" contract as watchdog_status.rs's Unavailable.
    #[test]
    fn missing_file_reads_as_empty() {
        let path = temp_path("missing");
        let events = read_alarms(path.to_str().unwrap());
        assert!(events.is_empty());
    }

    // A corrupted file (should not happen given the atomic rename below, but
    // a reader must not trust its own past writes blindly either) must also
    // fail closed to an empty list rather than panicking the request.
    #[test]
    fn malformed_json_reads_as_empty() {
        let path = temp_path("malformed");
        fs::write(&path, "{ not valid json").unwrap();
        let events = read_alarms(path.to_str().unwrap());
        assert!(events.is_empty());
        fs::remove_file(&path).ok();
    }

    // The common case: appending to an empty/missing history creates it,
    // and the stored event round-trips field-for-field.
    #[test]
    fn append_to_missing_file_creates_it_with_one_event() {
        let path = temp_path("first-append");
        append_alarm(path.to_str().unwrap(), sample_event(1)).unwrap();

        let events = read_alarms(path.to_str().unwrap());
        assert_eq!(events.len(), 1);
        assert_eq!(events[0], sample_event(1));
        fs::remove_file(&path).ok();
    }

    // New events are prepended (newest first), matching the dashboard's
    // "most recent alarm at the top" rendering expectation.
    #[test]
    fn append_orders_newest_first() {
        let path = temp_path("ordering");
        append_alarm(path.to_str().unwrap(), sample_event(1)).unwrap();
        append_alarm(path.to_str().unwrap(), sample_event(2)).unwrap();

        let events = read_alarms(path.to_str().unwrap());
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].unique_id, 2);
        assert_eq!(events[1].unique_id, 1);
        fs::remove_file(&path).ok();
    }

    // Re-appending the exact same unique_id (a retried delivery, or a
    // re-run of Netdata's own `alarm-notify.sh ... test` mode) must be a
    // no-op, not a duplicate entry -- the idempotence property AG-OP-006
    // requires of this write path (see append_alarm's own doc comment).
    #[test]
    fn append_is_idempotent_for_the_same_unique_id() {
        let path = temp_path("idempotent");
        append_alarm(path.to_str().unwrap(), sample_event(42)).unwrap();
        append_alarm(path.to_str().unwrap(), sample_event(42)).unwrap();

        let events = read_alarms(path.to_str().unwrap());
        assert_eq!(events.len(), 1);
        fs::remove_file(&path).ok();
    }

    // A burst beyond MAX_ALARMS must be truncated to the newest MAX_ALARMS
    // entries, not grow the file unbounded -- proves the bounded-cap
    // behavior the module doc comment promises.
    #[test]
    fn append_truncates_history_to_max_alarms() {
        let path = temp_path("bounded");
        for i in 0..(MAX_ALARMS as i64 + 10) {
            append_alarm(path.to_str().unwrap(), sample_event(i)).unwrap();
        }

        let events = read_alarms(path.to_str().unwrap());
        assert_eq!(events.len(), MAX_ALARMS);
        // Newest-first: the last-appended id must be present at the front,
        // and the oldest (id 0) must have been evicted.
        assert_eq!(events[0].unique_id, MAX_ALARMS as i64 + 9);
        assert!(!events.iter().any(|e| e.unique_id == 0));
        fs::remove_file(&path).ok();
    }

    // A known Unix timestamp must format to its exact, well-known RFC 3339
    // UTC representation -- a real regression test, not just "it doesn't
    // panic", since a silently wrong date would mislead an operator
    // comparing this against Netdata's own alarm history.
    #[test]
    fn format_alarm_time_renders_known_timestamp_as_rfc3339() {
        assert_eq!(format_alarm_time(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_alarm_time(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    // alarm_views must carry over every field the template renders,
    // including the formatted timestamp, and preserve order.
    #[test]
    fn alarm_views_maps_fields_and_preserves_order() {
        let events = vec![sample_event(2), sample_event(1)];
        let views = alarm_views(&events);

        assert_eq!(views.len(), 2);
        assert_eq!(views[0].unique_id, 2);
        assert_eq!(views[1].unique_id, 1);
        assert_eq!(views[0].when_display, "2023-11-14T22:13:20Z");
        assert_eq!(views[0].status, "WARNING");
        assert_eq!(views[0].info, "disk space usage");
    }
}
