//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
