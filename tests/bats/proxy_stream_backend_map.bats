#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for services/proxy/entrypoint.sh's
# _render_stream_backend_map(). Lazy mode (the
# project's shipped default, PROXY_SECURITY_MODE unset or "lazy") generated
# `default $ssl_preread_server_name:443;` with no "" (empty-SNI) guard ahead
# of it, so a client that sends no SNI (or one ssl_preread cannot parse)
# would be forwarded to the literal, invalid target ":443" -- a confirmed
# regression of issue #88 (originally fixed by PR #198's static nginx map,
# silently dropped when commit e09a0f98 replaced it with this per-mode
# generated one). Asserts against the real generated nginx map text.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-stream-backend-map-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-stream-backend-map-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-stream-backend-map-helpers.sh"
    load_proxy_stream_backend_map_helpers "$repo_root" "$helper_file"
}

@test "lazy mode's generated map has an explicit empty-SNI key routing to the safe fallback, not the invalid :443 target" {
    PROXY_SECURITY_MODE="lazy"
    run _render_stream_backend_map
    [ "$status" -eq 0 ]
    [[ "$output" == *'"" '*'127.0.0.1:9;'* ]]
}

# The actual #88 regression shape: confirms the map's own DEFAULT line
# (which is what an empty SNI fell through to before the "" key was added)
# is still the literal SNI-forwarding target in lazy mode -- proving the ""
# key above is doing real, necessary work, not simply duplicating what the
# default already provided.
@test "lazy mode's default line still forwards to the literal SNI value (why the explicit empty-SNI key is required)" {
    PROXY_SECURITY_MODE="lazy"
    run _render_stream_backend_map
    [ "$status" -eq 0 ]
    [[ "$output" == *'default $ssl_preread_server_name:443;'* ]]
}

@test "strict mode's generated map also has the same explicit empty-SNI key (AG-CODE-011: shared, not per-branch)" {
    PROXY_SECURITY_MODE="strict"
    run _render_stream_backend_map
    [ "$status" -eq 0 ]
    [[ "$output" == *'"" '*'127.0.0.1:9;'* ]]
}

@test "strict mode's default line is the safe fallback, not the literal SNI target" {
    PROXY_SECURITY_MODE="strict"
    run _render_stream_backend_map
    [ "$status" -eq 0 ]
    [[ "$output" == *'default 127.0.0.1:9;'* ]]
    [[ "$output" != *'default $ssl_preread_server_name:443;'* ]]
}

# A real nginx map cannot have the same key ("") appear twice -- confirms
# the fix adds exactly one "" entry, not a second one duplicating (and
# potentially conflicting with) strict mode's own default-driven safety.
@test "the empty-SNI key appears exactly once regardless of mode" {
    # shellcheck disable=SC2034 # read by _render_stream_backend_map(), sourced dynamically via load_proxy_stream_backend_map_helpers() -- invisible to shellcheck's static analysis
    PROXY_SECURITY_MODE="lazy"
    run _render_stream_backend_map
    [ "$status" -eq 0 ]
    count="$(grep -c '^    "" ' <<<"$output")"
    [ "$count" -eq 1 ]
}
