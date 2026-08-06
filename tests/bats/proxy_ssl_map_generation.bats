#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/proxy/entrypoint.sh's _render_ssl_map(),
# specifically the two 403-gating maps it generates: $cdn_host_allowed
# (PROXY_SECURITY_MODE=strict/lazy) and $lancache_client_allowed
# (PROXY_ALLOWED_CLIENT_CIDRS). Before this file, neither the strict-mode
# code path nor the CIDR-allowlist code path had any automated test
# coverage anywhere in the suite -- confirmed via `git grep` across
# tests/bats for both variable names before writing this file (bug-hunt
# #849, finding #9's fourth sub-part). Asserts against the real generated
# nginx map text (the same text conf.d/http.conf's `location /` block's
# `if ($cdn_host_allowed = 0) { return 403; }` and
# `if ($lancache_client_allowed = 0) { return 403; }` actually evaluate at
# runtime), not a reimplementation of the generation logic.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/proxy-ssl-map-generation-helpers.sh"

    # shellcheck source=tests/bats/helpers/proxy-ssl-map-generation-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/proxy-ssl-map-generation-helpers.sh"
    load_proxy_ssl_map_generation_helpers "$repo_root" "$helper_file"
}

# ────────────────────────────────────────────────────────────────────────────
# $cdn_host_allowed (PROXY_SECURITY_MODE)
# ────────────────────────────────────────────────────────────────────────────

@test "lazy mode (default) allows every host by default in cdn_host_allowed" {
    PROXY_SECURITY_MODE="lazy"
    run _render_ssl_map
    [ "$status" -eq 0 ]
    [[ "$output" == *'map $host $cdn_host_allowed {'* ]]
    [[ "$output" == *'default 1;'* ]]
}

@test "strict mode denies every host by default in cdn_host_allowed" {
    PROXY_SECURITY_MODE="strict"
    run _render_ssl_map
    [ "$status" -eq 0 ]
    # Isolate the cdn_host_allowed map's own body from ssl_cert_name's
    # (which legitimately contains a different "default default;" line
    # above it) by grepping only the lines between the two map headers.
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 0;'* ]]
}

@test "strict mode allowlists a cdn-domains.txt root domain and its wildcard in cdn_host_allowed" {
    PROXY_SECURITY_MODE="strict"
    _UNIQUE_DOMAINS=(steamcontent.com)
    _DOMAIN_IS_ROOT[steamcontent.com]=1

    run _render_ssl_map
    [ "$status" -eq 0 ]
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'*.steamcontent.com'*' 1;'* ]]
    [[ "$body" == *'steamcontent.com'*' 1;'* ]]
}

@test "strict mode does NOT allowlist an unlisted host in cdn_host_allowed" {
    PROXY_SECURITY_MODE="strict"
    _UNIQUE_DOMAINS=(steamcontent.com)
    _DOMAIN_IS_ROOT[steamcontent.com]=1

    run _render_ssl_map
    [ "$status" -eq 0 ]
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" != *'evil.example.com'* ]]
}

# ────────────────────────────────────────────────────────────────────────────
# $lancache_client_allowed (PROXY_ALLOWED_CLIENT_CIDRS)
# ────────────────────────────────────────────────────────────────────────────

@test "empty PROXY_ALLOWED_CLIENT_CIDRS allows every client by default (lazy default, AG-OP-003/005)" {
    PROXY_ALLOWED_CLIENT_CIDRS=""
    run _render_ssl_map
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 1;'* ]]
}

@test "a configured PROXY_ALLOWED_CLIENT_CIDRS denies by default and allowlists only the listed CIDRs" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8"
    run _render_ssl_map
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 0;'* ]]
    [[ "$body" == *'192.168.1.0/24'*' 1;'* ]]
    [[ "$body" == *'10.0.0.0/8'*' 1;'* ]]
}

@test "a configured PROXY_ALLOWED_CLIENT_CIDRS does not allowlist an unrelated CIDR" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24"
    run _render_ssl_map
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" != *'10.0.0.0/8'* ]]
}

# strict PROXY_SECURITY_MODE and PROXY_ALLOWED_CLIENT_CIDRS are independent
# axes (host allowlist vs. client-IP allowlist) -- this proves neither one
# silently disables or duplicates the other's map when both are configured
# together, the realistic "maximum hardening" deployment shape.
@test "strict mode and a client CIDR allowlist combine independently without interfering" {
    PROXY_SECURITY_MODE="strict"
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24"
    _UNIQUE_DOMAINS=(steamcontent.com)
    _DOMAIN_IS_ROOT[steamcontent.com]=1

    run _render_ssl_map
    [ "$status" -eq 0 ]

    host_body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$host_body" == *'default 0;'* ]]
    [[ "$host_body" == *'steamcontent.com'* ]]

    client_body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$client_body" == *'default 0;'* ]]
    [[ "$client_body" == *'192.168.1.0/24'*' 1;'* ]]
}
