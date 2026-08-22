//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! The health-check/restart state machine: watchdog.sh's
//! `check_and_maybe_restart()` and `probe_docker_socket_proxy()`,
//! `health_color()`, and the `get_health()`-produced health-string domain,
//! reshaped into typed, pure, unit-testable pieces. No I/O lives here --
//! `docker_client` produces a [`HealthReading`] from a real HTTP call, and
//! this module only decides what that reading means for a service's
//! failure counter.

use serde::{Deserialize, Serialize};

/// The full domain of values watchdog.sh's `get_health()` can produce,
/// typed instead of left as a bare string. Docker's own container health
/// API returns `starting`/`healthy`/`unhealthy`, or omits `.State.Health`
/// entirely for a container with no configured healthcheck (`get_health()`
/// falls back to the literal string `"none"` for that case via jq's `//`
/// operator). `Unreachable` is not a Docker value at all -- it is
/// watchdog's own synthetic result for "the request to docker-socket-proxy
/// itself failed" (connection refused, timeout, non-2xx response, or an
/// unparseable body), the exact case `get_health()`'s own comment describes
/// at length as the bug this shape was built to avoid (an empty string that
/// `check_and_maybe_restart()` would then silently ignore forever).
///
/// **Only `Healthy` and `Unhealthy` ever change a failure counter.**
/// `Starting`, `None`, and `Other` are inert passthrough readings, exactly
/// like the bash: `check_and_maybe_restart()`'s `if .../elif ...` only
/// matches the literal strings `"unhealthy"`/`"healthy"`, so a `starting`
/// (or any other) reading is written into `status.json` as-is but never
/// touches `_fcount`. This is also, deliberately, today's *entire* startup
/// grace period: a container that reports `starting` for a while after
/// boot never accumulates a failure count during that window, with no
/// separate timer needed or present. See `config::MonitoredService`'s
/// `grace_period` field doc comment for why a real timer is not added here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthReading {
    Healthy,
    Unhealthy,
    Starting,
    /// Docker reports no health status at all for this container (no
    /// `HEALTHCHECK` configured). Distinct from `Unreachable`: this is a
    /// successful API call that legitimately has nothing to report.
    None,
    /// watchdog could not get a health reading at all (network failure,
    /// timeout, non-2xx, or an unparseable response body from
    /// docker-socket-proxy) -- not a Docker-reported state.
    Unreachable,
    /// A Docker health string that is none of the above. Never observed in
    /// practice (Docker's own documented enum is exactly
    /// starting/healthy/unhealthy, or absent), but the bash would still
    /// write it into `status.json`'s `health` field verbatim and leave the
    /// failure counter untouched -- kept for the same forward-compatible
    /// fidelity rather than silently coercing an unexpected value into one
    /// of the known variants.
    Other(String),
    /// A container that Docker itself reports "healthy" (it is running and
    /// functioning, and must never be mistaken for broken/needing a
    /// restart -- Docker's own health ternary has no fourth state to
    /// express this directly), but which has told watchdog through its own
    /// healthcheck output that it is intentionally operating with reduced
    /// guarantees. First used by `ntp` (issue #1296, maintainer decision:
    /// a plain "healthy" dot was explicitly rejected for this case): a
    /// nested/LXC host that denies `CAP_SYS_TIME` makes `chronyd` start in
    /// `-x` mode (never step/slew the clock) instead of crash-looping --
    /// genuinely working as an NTP relay, but never disciplining the host
    /// clock, a real, ongoing difference from full health that must stay
    /// visible in the dashboard, not just a one-time startup log line. See
    /// [`crate::docker_client::DockerProxyClient::get_health`] for how
    /// this is detected (a `DEGRADED: <reason>` line in the healthcheck's
    /// own captured output, re-checked every cycle). The `String` is the
    /// reason text after that prefix, verbatim.
    Degraded(String),
}

impl HealthReading {
    /// Parses a raw Docker health string (already extracted from
    /// `.State.Health.Status`, with jq's `// "none"` fallback already
    /// applied by the caller) into a typed reading. A caller that could not
    /// reach docker-socket-proxy at all should use
    /// [`HealthReading::Unreachable`] directly rather than calling this.
    pub fn from_docker_status(raw: &str) -> Self {
        match raw {
            "healthy" => Self::Healthy,
            "unhealthy" => Self::Unhealthy,
            "starting" => Self::Starting,
            "none" => Self::None,
            other => Self::Other(other.to_string()),
        }
    }

    /// The exact string watchdog.sh writes into `status.json`'s `health`
    /// field (`H_PROXY`/etc.) for this reading -- `services/ui/src/
    /// watchdog_status.rs` deserializes this as a plain `String` and shows
    /// it verbatim as a tooltip/detail, so this must match the bash's
    /// literal strings exactly, not just be human-readable.
    pub fn as_status_str(&self) -> &str {
        match self {
            Self::Healthy => "healthy",
            Self::Unhealthy => "unhealthy",
            Self::Starting => "starting",
            Self::None => "none",
            Self::Unreachable => "unreachable",
            Self::Other(s) => s,
            // Fixed constant, not the carried reason text: keeps
            // status.json's `health` field a short, stable enum-like value
            // (matching every other variant here) rather than embedding a
            // free-text sentence a future consumer might not expect. The
            // full reason stays real, visible data in `docker inspect`'s
            // `.State.Health.Log` and this project's own container logs --
            // exactly where an operator digging into "why is this dot
            // amber" already knows to look, the same way a plain Docker
            // "unhealthy" dot also does not carry its own failure reason
            // inline.
            Self::Degraded(_) => "degraded",
        }
    }

    /// watchdog.sh's `health_color()`: the dashboard-card color this
    /// reading maps to. Every unmatched case (Docker's `starting`, the
    /// synthetic `none`/`unreachable`, and any unexpected `Other` string)
    /// falls through to the bash's `*) echo "yellow"` default -- "not
    /// known-good, not known-bad" is the correct, cautious default for an
    /// operator dashboard. `Degraded` deliberately gets its OWN color
    /// (`amber`), not `yellow`: `yellow` means "unknown, transitional, not
    /// yet classified" (the container might turn out green or red any
    /// moment), whereas `Degraded` is a KNOWN, deliberate, stable state --
    /// conflating the two would hide a real, ongoing reduced-security
    /// condition behind a color an operator already reads as "wait and
    /// see," exactly the maintainer feedback (issue #1296) this variant
    /// exists to address. `services/ui/src/templates/dashboard.html` (both
    /// the server-rendered Tera markup and the `refreshWatchdogStatus()`
    /// JS poller) must recognize this color explicitly -- update both
    /// together with any future change here.
    pub fn color(&self) -> &'static str {
        match self {
            Self::Healthy => "green",
            Self::Unhealthy => "red",
            Self::Starting | Self::None | Self::Unreachable | Self::Other(_) => "yellow",
            Self::Degraded(_) => "amber",
        }
    }

    /// Collapses a reading into the simple "is this alert-only service okay
    /// right now" boolean [`AlertCounter`] needs (issue #842: `ui`, `dhcp`,
    /// `dhcp-proxy`, `syslog` -- plus `ntp`, issue #1296 -- all monitored for
    /// dashboard visibility only, never auto-restarted; see `main.rs`'s own
    /// alert-only loop for why none of these go through
    /// [`FailureCounter`]/[`Action::Restart`] at all). `netdata` moved OFF
    /// this alert-only list (issue #842's 2026-08-07 restart-capability
    /// decision) -- it is real restart-capable now via [`FailureCounter`]
    /// directly, so it never reaches this function. `Healthy` and
    /// `Starting` are both "not currently a problem", matching how
    /// [`FailureCounter::record`] already treats `Starting` as inert rather
    /// than alarm-worthy. `None` (no Docker `HEALTHCHECK` configured, but
    /// the container inspect itself succeeded) is also treated as okay --
    /// confirmed against every one of these services' actual compose
    /// definitions before writing this (`ui`'s `/health` curl probe,
    /// `dhcp`'s Kea control-API check, `dhcp-proxy`'s `dnsmasq --test`,
    /// `syslog`'s dual-process fluent-bit+syslog-ng healthcheck, `ntp`'s
    /// `chronyc tracking` probe added by issue #1296) already have a real
    /// `healthcheck:` block, so `None` is not actually reachable for any of
    /// them in practice -- but treating it as "okay" rather than "alarm" is
    /// still the right default if that ever changes (a missing healthcheck is a
    /// documentation/compose gap to fix, not something this alert-only
    /// probe should misrepresent as a live service outage). `Unreachable`
    /// (container doesn't exist, or docker-socket-proxy rejected/couldn't
    /// answer the inspect call) and `Unhealthy` are the only two "something
    /// is actually wrong" cases -- for a service this function is called on
    /// at all, its container is expected to exist (callers only add a
    /// profile-gated service, e.g. `dhcp`/`dhcp-proxy`/`syslog`/`ntp`, to
    /// the alert-only set once its enabling env var already confirms it
    /// should be deployed), so `Unreachable` here means "should be running
    /// and isn't", not "legitimately not deployed". `Other` is
    /// never produced by a real Docker health string (see this enum's own
    /// doc comment) but is treated as alarm-worthy on the cautious
    /// assumption that an unrecognized value is more likely a real problem
    /// than a benign one. `Degraded` is also "ok" for this purpose: it is a
    /// known, expected, non-crashed state (see this variant's own doc
    /// comment) -- exactly the kind of "not currently a problem" condition
    /// `Healthy`/`Starting`/`None` already represent, not a new failure
    /// mode this alert-only probe should page on.
    pub fn is_alert_ok(&self) -> bool {
        matches!(
            self,
            Self::Healthy | Self::Starting | Self::None | Self::Degraded(_)
        )
    }
}

/// Per-service consecutive-failure counter driving watchdog.sh's
/// `check_and_maybe_restart()` restart decision. One instance per
/// restart-capable monitored service (`proxy`/`dns-standard`/`dns-ssl`/
/// `nats`) -- see `docker_client`'s main-loop orchestration for how this is
/// paired with a [`HealthReading`] each cycle.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailureCounter(pub u32);

/// What the caller should do after recording a reading, matching
/// watchdog.sh's own three outcomes (log "UNHEALTHY n/threshold" with no
/// action; log "UNHEALTHY n/threshold" AND restart+reset; log "RECOVERED").
/// `None` covers both "still healthy, nothing changed" (bash logs nothing
/// at all in this case) and every inert reading (`Starting`/`None`/
/// `Unreachable`/`Other`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing to log or do this cycle.
    None,
    /// Log `UNHEALTHY <name> (<count>/<threshold>)`; no restart yet.
    Unhealthy { count: u32, threshold: u32 },
    /// Log `UNHEALTHY <name> (<threshold>/<threshold>)`, then restart the
    /// container and reset the counter to 0 -- matches the bash's
    /// `restart_container "$name"; _fcount=0`, which resets the counter
    /// unconditionally after *issuing* the restart call, regardless of
    /// whether that restart call itself succeeds (watchdog.sh's
    /// `restart_container()` only logs a warning on failure; it never
    /// feeds that failure back into the counter).
    Restart { threshold: u32 },
    /// Log `RECOVERED <name>` -- only emitted when the counter was nonzero
    /// before this healthy reading, matching the bash's
    /// `[ "$_fcount" -gt 0 ] && log "RECOVERED $name"`.
    Recovered,
}

impl FailureCounter {
    /// Records one reading and returns the resulting [`Action`], mutating
    /// the counter in place exactly the way watchdog.sh's nameref-bound
    /// `_fcount` is mutated by `check_and_maybe_restart()`.
    pub fn record(&mut self, reading: &HealthReading, restart_after: u32) -> Action {
        match reading {
            HealthReading::Unhealthy => {
                self.0 = self.0.saturating_add(1);
                if self.0 >= restart_after {
                    self.0 = 0;
                    Action::Restart {
                        threshold: restart_after,
                    }
                } else {
                    Action::Unhealthy {
                        count: self.0,
                        threshold: restart_after,
                    }
                }
            }
            HealthReading::Healthy => {
                let recovered = self.0 > 0;
                self.0 = 0;
                if recovered {
                    Action::Recovered
                } else {
                    Action::None
                }
            }
            // Starting/None/Unreachable/Other/Degraded: the bash's if/elif
            // matches neither branch, so the counter and status stay
            // untouched. Degraded added here for the same reason as
            // is_alert_ok() above: get_health() only ever produces it when
            // the real Docker Status is "healthy" underneath, so treating
            // it as inert rather than restart-triggering is correct --
            // there is nothing to restart, the container is running
            // exactly as intended for the environment it detected.
            HealthReading::Starting
            | HealthReading::None
            | HealthReading::Unreachable
            | HealthReading::Other(_)
            | HealthReading::Degraded(_) => Action::None,
        }
    }
}

/// Failure counter for `probe_docker_socket_proxy()`'s alert-only
/// reachability probe. Deliberately a distinct type from [`FailureCounter`]
/// rather than the same type reused with an unreachable restart threshold:
/// this counter genuinely never resets via a restart (there is none --
/// watchdog cannot restart its own Docker API gateway, by design) and
/// climbs for as long as docker-socket-proxy stays unreachable, which is
/// itself useful operator-visible information, not a bug to cap.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlertCounter(pub u32);

/// What `probe_docker_socket_proxy()`'s own inline logging needs to know:
/// whether this reading is a recovery (nonzero counter transitioning to
/// reachable) worth a "RECOVERED" log line, distinct from an ordinary
/// steady-state "still reachable" cycle that logs nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertAction {
    /// Still/newly reachable, counter was already 0 -- nothing to log.
    None,
    /// Newly reachable after `count` prior consecutive failures --
    /// matches `log "RECOVERED $C_DOCKER_PROXY"`.
    Recovered,
    /// Unreachable this cycle; `count` is the counter's new value after
    /// this reading, for the "UNHEALTHY ... (n consecutive failures)"
    /// log line.
    Unreachable { count: u32 },
}

impl AlertCounter {
    pub fn record(&mut self, reachable: bool) -> AlertAction {
        if reachable {
            let recovered = self.0 > 0;
            self.0 = 0;
            if recovered {
                AlertAction::Recovered
            } else {
                AlertAction::None
            }
        } else {
            self.0 = self.0.saturating_add(1);
            AlertAction::Unreachable { count: self.0 }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // Pins the exact mapping get_health() relies on, including the two
    // synthetic/fallback cases ("none" for an absent healthcheck, and any
    // unrecognized string collapsing into Other rather than panicking or
    // silently coercing to a known variant).
    fn from_docker_status_maps_known_values() {
        assert_eq!(
            HealthReading::from_docker_status("healthy"),
            HealthReading::Healthy
        );
        assert_eq!(
            HealthReading::from_docker_status("unhealthy"),
            HealthReading::Unhealthy
        );
        assert_eq!(
            HealthReading::from_docker_status("starting"),
            HealthReading::Starting
        );
        assert_eq!(
            HealthReading::from_docker_status("none"),
            HealthReading::None
        );
        assert_eq!(
            HealthReading::from_docker_status("weird"),
            HealthReading::Other("weird".to_string())
        );
    }

    #[test]
    // Pins watchdog.sh's health_color() case statement exactly, including
    // its default branch (every non-healthy/non-unhealthy reading, known
    // or not, must fall through to yellow, never green or red).
    fn color_matches_health_color_case_statement() {
        assert_eq!(HealthReading::Healthy.color(), "green");
        assert_eq!(HealthReading::Starting.color(), "yellow");
        assert_eq!(HealthReading::Unhealthy.color(), "red");
        assert_eq!(HealthReading::None.color(), "yellow");
        assert_eq!(HealthReading::Unreachable.color(), "yellow");
        assert_eq!(HealthReading::Other("huh".into()).color(), "yellow");
    }

    #[test]
    // Degraded (issue #1296) must render as its own distinct "amber" color,
    // never collapsed into "yellow" (transitional/unknown) or "green"
    // (fully healthy) -- see the variant's own doc comment for why
    // conflating it with yellow would defeat the point of adding it.
    fn degraded_gets_its_own_amber_color_and_status_string() {
        let reading = HealthReading::Degraded("CAP_SYS_TIME denied".to_string());
        assert_eq!(reading.color(), "amber");
        assert_eq!(reading.as_status_str(), "degraded");
    }

    #[test]
    // Only literal healthy/unhealthy readings ever touch the counter --
    // this is the single most important behavioral quirk to pin, since a
    // typed rewrite "helpfully" collapsing Unreachable into Unhealthy (they
    // sound similar) would silently start restarting containers watchdog
    // simply cannot currently reach, which is exactly the opposite of safe.
    fn inert_readings_never_change_the_counter() {
        for reading in [
            HealthReading::Starting,
            HealthReading::None,
            HealthReading::Unreachable,
            HealthReading::Other("huh".into()),
            HealthReading::Degraded("CAP_SYS_TIME denied".into()),
        ] {
            let mut counter = FailureCounter(2);
            let action = counter.record(&reading, 3);
            assert_eq!(counter.0, 2, "counter must not change for {reading:?}");
            assert_eq!(action, Action::None);
        }
    }

    #[test]
    // Verifies the restart threshold triggers exactly on the configured
    // count (not one before or after) and that reaching it resets the
    // counter to 0 in the same step, matching watchdog.sh's
    // `restart_container "$name"; _fcount=0` sequencing.
    fn unhealthy_increments_and_restarts_at_threshold() {
        let mut counter = FailureCounter::default();
        assert_eq!(
            counter.record(&HealthReading::Unhealthy, 3),
            Action::Unhealthy {
                count: 1,
                threshold: 3
            }
        );
        assert_eq!(
            counter.record(&HealthReading::Unhealthy, 3),
            Action::Unhealthy {
                count: 2,
                threshold: 3
            }
        );
        // Third consecutive unhealthy reading reaches the threshold: the
        // bash restarts AND resets the counter to 0 in the same step.
        assert_eq!(
            counter.record(&HealthReading::Unhealthy, 3),
            Action::Restart { threshold: 3 }
        );
        assert_eq!(counter.0, 0);
    }

    #[test]
    // A healthy reading while the counter is already 0 must stay silent
    // (Action::None) -- only a transition FROM a nonzero counter counts as
    // a real recovery worth logging, matching the bash's
    // `[ "$_fcount" -gt 0 ] && log "RECOVERED"` guard.
    fn healthy_resets_and_only_reports_recovered_if_counter_was_nonzero() {
        let mut counter = FailureCounter::default();
        // Already healthy -> healthy: no RECOVERED spam on every steady
        // cycle, matching the bash's `[ "$_fcount" -gt 0 ] && log ...`.
        assert_eq!(counter.record(&HealthReading::Healthy, 3), Action::None);

        counter.0 = 2;
        assert_eq!(
            counter.record(&HealthReading::Healthy, 3),
            Action::Recovered
        );
        assert_eq!(counter.0, 0);
    }

    #[test]
    // Pins is_alert_ok()'s exact classification for issue #842's
    // remaining alert-only services (ui/dhcp/dhcp-proxy/syslog/ntp --
    // netdata moved to real restart-capability, see this file's own
    // is_alert_ok() doc comment): Healthy/Starting/None are "not a problem" (the
    // same three states FailureCounter already treats as either healthy or
    // inert), while Unhealthy/Unreachable/Other are alarm-worthy.
    fn is_alert_ok_matches_documented_classification() {
        assert!(HealthReading::Healthy.is_alert_ok());
        assert!(HealthReading::Starting.is_alert_ok());
        assert!(HealthReading::None.is_alert_ok());
        assert!(!HealthReading::Unhealthy.is_alert_ok());
        assert!(!HealthReading::Unreachable.is_alert_ok());
        assert!(!HealthReading::Other("huh".into()).is_alert_ok());
        // Degraded (issue #1296): a known, deliberate reduced-guarantee
        // state, not a failure -- see the variant's own doc comment.
        assert!(HealthReading::Degraded("CAP_SYS_TIME denied".into()).is_alert_ok());
    }

    #[test]
    // Confirms the alert-only probe's counter has no restart-triggered
    // reset path at all (unlike FailureCounter) and keeps climbing across
    // repeated failures, then verifies a single reachable reading resets
    // it to 0 and reports a recovery exactly once.
    fn alert_counter_never_resets_via_restart_and_climbs_unbounded() {
        let mut counter = AlertCounter::default();
        assert_eq!(counter.record(false), AlertAction::Unreachable { count: 1 });
        assert_eq!(counter.record(false), AlertAction::Unreachable { count: 2 });
        assert_eq!(counter.record(false), AlertAction::Unreachable { count: 3 });
        assert_eq!(
            counter.0, 3,
            "no restart-threshold exists to reset this counter"
        );
        assert_eq!(counter.record(true), AlertAction::Recovered);
        assert_eq!(counter.0, 0);
        // Reachable again while already at 0: no recovery to report.
        assert_eq!(counter.record(true), AlertAction::None);
    }
}
