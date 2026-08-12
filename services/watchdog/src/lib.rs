//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Rust rewrite of `services/watchdog/watchdog.sh`'s health-check/restart
//! logic. The maintainer decided on 2026-07-25 that the bash polling loop
//! should become a real Rust service -- this crate is that rewrite,
//! currently covering only part of watchdog.sh's responsibilities.
//!
//! ## Scope (as of this writing, 2026-08-05)
//!
//! `watchdog.sh` is 952 lines with six distinct responsibilities. This
//! crate currently ports three of them, all pure state/data-flow with no
//! filesystem retention logic:
//!
//! 1. The health-check/restart state machine for the four containers
//!    watchdog currently monitors and can restart: `proxy`, `dns-standard`,
//!    `dns-ssl` (SSL-mode only), `nats` (see [`config`] and [`health`]).
//! 2. `status.json` production (see [`status`]) -- the Admin UI's *only*
//!    source for the dashboard health cards
//!    (`services/ui/src/watchdog_status.rs` reads this file by path, not
//!    via any API), so this is in scope regardless of how the remaining
//!    scope question below is answered: any binary that could eventually
//!    become `services/watchdog/Dockerfile`'s `ENTRYPOINT` must keep
//!    writing it.
//! 3. `probe_docker_socket_proxy()`'s alert-only reachability probe (see
//!    [`health::AlertCounter`]) -- also a `status.json` key, same reasoning.
//! 4. Issue #842's alert-only monitored services -- `ui`, `dhcp`
//!    (when `DHCP_MODE=kea`), `dhcp-proxy` (when `DHCP_MODE=dnsmasq-proxy`/
//!    `dnsmasq-relay`), `netdata`, `syslog` (when `LOGGING_ENABLED` is
//!    truthy -- not `SYSLOG_ENABLED`, which gates only the separate
//!    storage-budget retention engine and can legitimately stay false while
//!    central logging is active; the combined fluent-bit+syslog-ng container since the
//!    syslog+fluent-bit consolidation PR, 2026-08 -- #842 originally listed
//!    `syslog` and `syslog-ng` as two separate monitored targets, merged
//!    into this one entry now that they are one container, see
//!    `main.rs`'s `resolve_alert_only_targets()` and `config.rs`'s
//!    `CONTAINER_SYSLOG` doc comment for the concurrent-merge history) --
//!    plus `ntp` (when `NTP_ENABLED` is truthy, issue #1296: also the only
//!    caller that makes [`health::HealthReading::Degraded`]'s amber
//!    dashboard state reachable against a real container) -- added here
//!    first, in this crate, rather than in `watchdog.sh` directly: this
//!    scaffold was already the designated home for #842's remaining
//!    monitored-service work (see the `ENTRYPOINT` note below), and this
//!    crate's typed
//!    [`health::HealthReading`]/[`health::AlertCounter`] machinery already
//!    generalizes cleanly to "one more per-container inspect, alert-only,
//!    never restarted" without inventing another ad hoc bash variable.
//!    Unlike the four restart-capable services above, none of these are
//!    ever passed to [`docker_client::DockerProxyClient::restart`] -- see
//!    `main.rs`'s alert-only loop and [`health::HealthReading::is_alert_ok`]'s
//!    own doc comment for why (the maintainer's own #842 scope note
//!    explicitly flagged that blind auto-restart is not obviously the right
//!    recovery mechanism for every additional service, e.g. a mid-startup
//!    restart of a dependency can make a dependent service's own reconnect
//!    logic worse, not better -- alert-only visibility is the safe default
//!    until a per-service restart decision is deliberately made).
//!
//! **Deliberately NOT ported**: `maybe_purge()` (daily cache-age purge),
//! `maybe_prune_syslog()` (daily syslog-ng retention), and
//! `maybe_rotate_fluent_bit_selflog()` (per-cycle fluent-bit self-log
//! rotation) never need to be ported into this crate at all: they were
//! extracted out of `watchdog.sh` into their own script
//! (`services/watchdog/retention.sh`), which now runs as its own dedicated
//! `retention` Compose service/container (see
//! `deploy/*/docker-compose.yml`'s `retention:` service block), entirely
//! independent of whatever process ends up being this crate's `ENTRYPOINT`.
//! Swapping `services/watchdog/Dockerfile`'s health-monitor `ENTRYPOINT` to
//! this crate today would therefore NOT regress cache purge or syslog
//! retention for any existing install -- that engine already runs on its
//! own, separately from the health-check/restart loop this crate covers.
//! The `ENTRYPOINT` swap remains a separate, not-yet-made maintainer
//! decision for other reasons (this crate's own remaining scope, and
//! full-stack validation), not because of the file-retention passes above.
//! Concretely, as of this writing, this Dockerfile has no Rust builder
//! stage at all (confirmed directly: `services/watchdog/Dockerfile` only
//! `COPY`s the three shell scripts, never compiles anything from
//! `Cargo.toml`), and `deploy/*/docker-compose.yml`'s `watchdog` service
//! overrides the Dockerfile's `ENTRYPOINT` with its own `command:` (a bash
//! wrapper that explicitly execs `/watchdog.sh` for the central-logging tee)
//! -- so the swap is a real builder-stage-plus-compose-command change, not a
//! one-line edit, tracked as its own follow-up rather than attempted in the
//! same pass that added service #4 above.
//!
//! Also deliberately unchanged from today: no live startup-grace-period
//! timer. `check_and_maybe_restart()` in the bash always publishes the raw
//! reading into the caller's health string, `starting` included -- the
//! *only* thing it (and this crate's [`health::FailureCounter`]) skips for
//! `starting` is touching the failure counter, neither incrementing nor
//! resetting it (see [`health::HealthReading`]'s doc comment) -- that
//! counter omission-by-inaction *is* today's only grace period.
//! [`config::MonitoredService`] carries a `grace_period` field for a future
//! real timer, but it is unused today (see that struct's own doc comment).

pub mod config;
pub mod docker_client;
pub mod health;
pub mod status;
