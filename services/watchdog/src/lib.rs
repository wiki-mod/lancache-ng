//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! What: watchdog health state machine, config and status.
//! Why: main.rs stays the thin loop; logic here is tested.

pub mod config;
pub mod docker_client;
pub mod health;
pub mod status;
