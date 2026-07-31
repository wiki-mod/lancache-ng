//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Rust rewrite of `services/watchdog/watchdog.sh`'s health-check/restart
//! logic (issue #842). The maintainer decided on 2026-07-25 that the bash
//! polling loop should become a real Rust service -- this crate is that
//! rewrite, currently covering only part of watchdog.sh's responsibilities.
//!
//! ## Scope (as of this writing, 2026-08-01)
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
//!
//! **Deliberately NOT yet ported**: `maybe_purge()` (daily cache-age
//! purge), `maybe_prune_syslog()` (daily syslog-ng retention), and
//! `maybe_rotate_fluent_bit_selflog()` (per-cycle fluent-bit self-log
//! rotation, issue #1236). Whether these belong in this same Rust binary,
//! in a later separate pass, or should stay a bash helper permanently is an
//! open question posed to the maintainer in issue #842's 2026-07-31 WIP
//! comment -- not decided here. Until it is answered, `services/watchdog/
//! Dockerfile`'s `ENTRYPOINT` still points at the bash `watchdog.sh`, and
//! this crate is not wired in as a replacement: swapping it in today would
//! silently regress cache purge and syslog retention for every existing
//! install.
//!
//! Also deliberately unchanged from today: no live startup-grace-period
//! timer. `check_and_maybe_restart()` in the bash never treated a `starting`
//! Docker health status specially beyond leaving both the failure counter
//! and the health string alone (see [`health::HealthReading`]'s doc
//! comment) -- that omission-by-inaction *is* today's only grace period.
//! [`config::MonitoredService`] carries a `grace_period` field for a future
//! real timer, but it is unused today (see that struct's own doc comment).

pub mod config;
pub mod docker_client;
pub mod health;
pub mod status;
