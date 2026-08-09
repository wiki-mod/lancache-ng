
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//!
//! Library surface for `lancache-ui`, split out from the binary crate
//! (`src/main.rs`) purely so the pure, client/external-input-parsing
//! functions below can be linked by a `cargo-fuzz` harness (`fuzz/`) without
//! that harness also needing to construct a real `AppState`, axum router,
//! Docker/NATS/Kea client, or database connection. `main.rs` still owns the
//! whole Admin UI application (routes, session/auth, Docker/NATS wiring,
//! templates) -- this crate root only re-exports the two pure modules issue
//! #1252 names as fuzz targets:
//!
//!   - `kea_response_parse`: parses one Kea DHCPv4 API reservation entry
//!     (`routes::dhcp`'s `parse_reservation_entry`), external-input-shaped
//!     JSON returned by the Kea Control Agent.
//!   - `netdata_url`: builds the allowlisted Netdata proxy URL
//!     (`routes::netdata_proxy`'s `build_netdata_url`) from client-controlled
//!     path/query-parameter input.
//!
//! `main.rs`'s `routes::dhcp`/`routes::netdata_proxy` modules import these
//! same items from this crate (`use lancache_ui::...`) rather than
//! redefining them, so the fuzz harnesses and the production binary exercise
//! identical code, not a fork of it.

pub mod kea_response_parse;
pub mod netdata_url;

// The native DHCP probe (issue #1288) depends on the `dhcproto` crate for
// DHCPv4 wire-format encode/decode, which is only pulled in behind the
// default-on `runtime` feature (see Cargo.toml's `[features]` section) --
// the same reason every other real-server dependency (tokio, bollard, ...)
// is gated the same way: `fuzz/Cargo.toml` links this crate with
// `default-features = false` to avoid a real rustc ICE hit under
// cargo-fuzz's sanitizer instrumentation (see this file's own doc comment
// above), and a new mandatory dependency here would silently widen that
// fuzz build again even though the fuzz harnesses never call into this
// module at all.
#[cfg(feature = "runtime")]
pub mod dhcp_probe_native;
