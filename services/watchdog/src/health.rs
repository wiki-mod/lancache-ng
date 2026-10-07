//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: pure health-reading and failure-counter logic.
//! Why: docker_client does I/O; decisions here stay tested.

use serde::{Deserialize, Serialize};

/// What: typed Docker health plus watchdog's own outcomes.
/// Why: only Healthy and Unhealthy move a failure counter.
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
    /// What: an unknown Docker health string, verbatim.
    /// Why: never coerce it into a known variant.
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
    /// What: raw health status (or "none") to a reading.
    /// Why: no answer at all uses Unreachable instead.
    pub fn from_docker_status(raw: &str) -> Self {
        match raw {
            "healthy" => Self::Healthy,
            "unhealthy" => Self::Unhealthy,
            "starting" => Self::Starting,
            "none" => Self::None,
            other => Self::Other(other.to_string()),
        }
    }

    /// What: the status.json `health` string for a reading.
    /// Why: the ui shows it verbatim; keep values stable.
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

    /// What: card color; unknown yellow, Degraded amber.
    /// Why: dashboard.html matches these exact color names.
    /// From: Issue #1296
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
    /// never produced by a real Docker health string but is treated as
    /// alarm-worthy on the cautious
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

/// What: consecutive failures of one restartable service.
/// Why: a restart fires only after RESTART_AFTER misses.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailureCounter(pub u32);

/// What: what main.rs logs or does after one reading.
/// Why: None covers steady health and all inert readings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing to log or do this cycle.
    None,
    /// Log `UNHEALTHY <name> (<count>/<threshold>)`; no restart yet.
    Unhealthy { count: u32, threshold: u32 },
    /// What: restart, then the counter resets to 0.
    /// Why: reset even if the restart call itself fails.
    Restart { threshold: u32 },
    /// What: first healthy reading after a nonzero count.
    /// Why: a steady healthy cycle must not log RECOVERED.
    Recovered,
}

impl FailureCounter {
    /// What: record a reading and return its Action.
    /// Why: only Unhealthy counts up; Healthy resets to 0.
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
            // What: inert readings keep the counter.
            // Why: Degraded is healthy; never restart it.
            HealthReading::Starting
            | HealthReading::None
            | HealthReading::Unreachable
            | HealthReading::Other(_)
            | HealthReading::Degraded(_) => Action::None,
        }
    }
}

/// What: failure count of the docker proxy probe.
/// Why: watchdog cannot restart its own Docker API gateway.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlertCounter(pub u32);

/// What: what the proxy probe should log this cycle.
/// Why: only a recovery from a nonzero count is logged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertAction {
    /// Still/newly reachable, counter was already 0 -- nothing to log.
    None,
    /// What: reachable again after prior failures.
    /// Why: one RECOVERED line per outage, not per cycle.
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
    // What: healthy green, unhealthy red, all else yellow.
    // Why: unknown states must never read as green or red.
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
    // What: restart fires exactly at the threshold, resets.
    // Why: off by one either way changes restart timing.
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
        assert_eq!(
            counter.record(&HealthReading::Unhealthy, 3),
            Action::Restart { threshold: 3 }
        );
        assert_eq!(counter.0, 0);
    }

    #[test]
    // What: RECOVERED only after a nonzero counter.
    // Why: steady healthy cycles must stay silent.
    fn healthy_resets_and_only_reports_recovered_if_counter_was_nonzero() {
        let mut counter = FailureCounter::default();
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

    // What: one full unhealthy cycle (threshold 3).
    // Why: shared by the repeat-cycle test below.
    // From: Issue #1683
    fn unhealthy_cycle(counter: &mut FailureCounter) -> Vec<Action> {
        (0..3)
            .map(|_| counter.record(&HealthReading::Unhealthy, 3))
            .collect()
    }

    #[test]
    // What: repeat cycles restart once each, then reset.
    // Why: AG-OP-006; repeats must not drift or stack.
    // From: Issue #1683
    fn repeated_cycles_restart_once_each_and_converge() {
        let mut counter = FailureCounter::default();
        let first = unhealthy_cycle(&mut counter);
        let restarts = first
            .iter()
            .filter(|a| matches!(a, Action::Restart { .. }))
            .count();
        assert_eq!(restarts, 1);
        for _ in 0..4 {
            assert_eq!(unhealthy_cycle(&mut counter), first);
            assert_eq!(counter.0, 0);
        }
        for _ in 0..3 {
            counter.record(&HealthReading::Unhealthy, 3);
            counter.record(&HealthReading::Unhealthy, 3);
            assert_eq!(
                counter.record(&HealthReading::Healthy, 3),
                Action::Recovered
            );
            assert_eq!(counter.0, 0);
        }
    }
}
