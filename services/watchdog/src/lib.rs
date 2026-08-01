//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Rust rewrite of `services/watchdog/watchdog.sh`'s health-check/restart
//! logic. The maintainer decided on 2026-07-25 that the bash polling loop
//! should become a real Rust service -- this crate is that rewrite,
//! currently covering only part of watchdog.sh's responsibilities.
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
