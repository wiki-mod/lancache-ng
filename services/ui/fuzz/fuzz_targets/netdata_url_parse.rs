//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! cargo-fuzz target (issue #1252): exercises the real `build_netdata_url`
//! allowlisted-path builder `routes/netdata_proxy.rs::proxy` calls against
//! the incoming request's `path`/query-parameter axum extractors -- the
//! exact client-controlled input this function already has unit tests for
//! known-bad shapes (see netdata_url.rs's own test module), but not yet
//! fuzzed for unknown ones. `base_url` is fixed to a representative
//! configured value rather than fuzzed, since it is server configuration
//! (`state.config.netdata_url`), never client-controlled -- fuzzing it would
//! not exercise any additional trust boundary.
#![no_main]

use arbitrary::Arbitrary;
use lancache_ui::netdata_url::build_netdata_url;
use libfuzzer_sys::fuzz_target;
use std::collections::HashMap;

#[derive(Debug, Arbitrary)]
struct FuzzInput {
    path: String,
    params: Vec<(String, String)>,
}

fuzz_target!(|input: FuzzInput| {
    let params: HashMap<String, String> = input.params.into_iter().collect();
    let _ = build_netdata_url("http://netdata:19999", &input.path, &params);
});
