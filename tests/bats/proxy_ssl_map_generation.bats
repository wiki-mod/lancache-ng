#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/proxy/entrypoint.sh's _render_ssl_map(),
# specifically the two 403-gating maps it generates: $cdn_host_allowed
# (PROXY_SECURITY_MODE=strict/lazy) and $lancache_client_allowed
# (PROXY_ALLOWED_CLIENT_CIDRS). These security-relevant defaults and
# allowlist entries need direct assertions because request-level tests can
# otherwise conceal which generated map supplied a matching value. These
# tests assert against the real generated nginx map text (the same text
# conf.d/http.conf's `location /` block's
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
    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    [[ "$output" == *'map $host $cdn_host_allowed {'* ]]
    # Isolated to cdn_host_allowed's own body, not the full $output: with no
    # PROXY_ALLOWED_CLIENT_CIDRS set, $lancache_client_allowed's own geo
    # block also emits "default 1;" further down, which would let this
    # assertion pass by accident even if lazy mode's own host map regressed
    # to "default 0;".
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 1;'* ]]
}

@test "strict mode denies every host by default in cdn_host_allowed" {
    PROXY_SECURITY_MODE="strict"
    run run_render_ssl_map_with_production_options
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

    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    grep -qE '^[[:space:]]*\*\.steamcontent\.com[[:space:]]+1;' <<<"$body"
    # A substring check here (e.g. *'steamcontent.com'*' 1;'*) would also
    # match inside the "*.steamcontent.com ... 1;" wildcard line just
    # asserted above, since that line itself contains "steamcontent.com"
    # followed eventually by " 1;" -- passing even if _render_ssl_map
    # stopped emitting the exact-root entry entirely. Matched as a
    # complete, anchored map line instead.
    grep -qE '^[[:space:]]*steamcontent\.com[[:space:]]+1;' <<<"$body"
}

@test "strict mode does NOT allowlist an unlisted host in cdn_host_allowed" {
    PROXY_SECURITY_MODE="strict"
    _UNIQUE_DOMAINS=(steamcontent.com)
    _DOMAIN_IS_ROOT[steamcontent.com]=1

    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" != *'evil.example.com'* ]]
}

# ────────────────────────────────────────────────────────────────────────────
# $lancache_client_allowed (PROXY_ALLOWED_CLIENT_CIDRS)
# ────────────────────────────────────────────────────────────────────────────

@test "empty PROXY_ALLOWED_CLIENT_CIDRS allows every client by default (lazy default, AG-OP-003/005)" {
    PROXY_ALLOWED_CLIENT_CIDRS=""
    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 1;'* ]]
}

@test "a configured PROXY_ALLOWED_CLIENT_CIDRS denies by default and allowlists only the listed CIDRs" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8"
    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" == *'default 0;'* ]]
    # Anchored lines keep one CIDR's allowed value from satisfying the other
    # assertion after Bash's glob matcher spans the newline between them.
    grep -qE '^[[:space:]]*192\.168\.1\.0/24[[:space:]]+1;' <<<"$body"
    grep -qE '^[[:space:]]*10\.0\.0\.0/8[[:space:]]+1;' <<<"$body"
}

@test "a configured PROXY_ALLOWED_CLIENT_CIDRS does not allowlist an unrelated CIDR" {
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24"
    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]
    body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$body" != *'10.0.0.0/8'* ]]
}

# strict PROXY_SECURITY_MODE and PROXY_ALLOWED_CLIENT_CIDRS are independent
# axes (host allowlist vs. client-IP allowlist) -- this proves neither one
# silently disables or duplicates the other's map when both are configured
# together, the realistic "maximum hardening" deployment shape.
@test "strict mode and a client CIDR allowlist combine independently without interfering" {
    # The real function body is extracted and sourced at runtime, so ShellCheck
    # cannot connect these globals to the reads inside _render_ssl_map.
    # shellcheck disable=SC2034
    PROXY_SECURITY_MODE="strict"
    # shellcheck disable=SC2034
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24"
    _UNIQUE_DOMAINS=(steamcontent.com)
    _DOMAIN_IS_ROOT[steamcontent.com]=1

    run run_render_ssl_map_with_production_options
    [ "$status" -eq 0 ]

    host_body="$(awk '/map \$host \$cdn_host_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$host_body" == *'default 0;'* ]]
    [[ "$host_body" == *'steamcontent.com'* ]]

    client_body="$(awk '/geo \$lancache_client_allowed/{f=1} f{print} f&&/^}$/{exit}' <<<"$output")"
    [[ "$client_body" == *'default 0;'* ]]
    [[ "$client_body" == *'192.168.1.0/24'*' 1;'* ]]
}
