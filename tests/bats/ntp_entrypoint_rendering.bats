#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for services/ntp/entrypoint.sh's config-rendering
# functions (`is_ip_literal`, `render_ntp_config`, `validate_ntp_config`).
# Loads the real functions (not a reimplementation) and asserts on the
# rendered chrony.conf content, independent of a real chronyd (there is no
# offline "config test" mode for chrony -- see validate_ntp_config's own
# comment in entrypoint.sh for why this project's structural check is what
# it is, and manual verification against a real chronyd build is what
# actually validates full syntax correctness).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/ntp-entrypoint-helpers.sh"

    # shellcheck source=tests/bats/helpers/ntp-entrypoint-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/ntp-entrypoint-helpers.sh"
    load_ntp_entrypoint_helpers "$repo_root" "$helper_file"

    template="$BATS_TEST_TMPDIR/chrony.conf.template"
    printf 'driftfile /var/lib/chrony/chrony.drift\n' > "$template"
    target="$BATS_TEST_TMPDIR/chrony.conf"
}

@test "is_ip_literal accepts IPv4 and IPv6 literals, rejects hostnames" {
    run is_ip_literal "192.0.2.1"
    [ "$status" -eq 0 ]

    run is_ip_literal "2606:4700:f1::1"
    [ "$status" -eq 0 ]

    run is_ip_literal "0.debian.pool.ntp.org"
    [ "$status" -eq 1 ]

    run is_ip_literal "time.cloudflare.com"
    [ "$status" -eq 1 ]
}

@test "render_ntp_config renders a pool line for a hostname entry" {
    # shellcheck disable=SC2034 # NTP_UPSTREAM_SERVERS/NTP_ALLOWED_CLIENT_CIDRS
    # are read as globals inside render_ntp_config(), which this test loads
    # from services/ntp/entrypoint.sh at runtime via load_ntp_entrypoint_helpers
    # (see setup() above) -- shellcheck analyzes this .bats file in isolation
    # and cannot see that dynamically-sourced function body, so it cannot trace
    # the read and reports these assignments as unused.
    NTP_UPSTREAM_SERVERS="0.debian.pool.ntp.org"
    # shellcheck disable=SC2034 # see NTP_UPSTREAM_SERVERS comment above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"pool 0.debian.pool.ntp.org iburst"* ]]
    [[ "$output" != *"server 0.debian.pool.ntp.org"* ]]
}

@test "render_ntp_config renders a server line for an IPv4/IPv6 literal entry" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1 2606:4700:f1::1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"server 192.0.2.1 iburst"* ]]
    [[ "$output" == *"server 2606:4700:f1::1 iburst"* ]]
}

# Matches services/proxy's PROXY_ALLOWED_CLIENT_CIDRS convention: empty
# means allow any client that can reach the bound port, not deny everyone --
# chrony denies all NTP clients by default without at least one explicit
# `allow`, which would silently defeat requirement 3 (LAN exposure) for any
# operator who never touches this setting.
@test "render_ntp_config defaults to allow-all when NTP_ALLOWED_CLIENT_CIDRS is empty" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"allow 0.0.0.0/0"* ]]
    [[ "$output" == *"allow ::/0"* ]]
}

@test "render_ntp_config scopes allow to each configured CIDR when set" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS="192.168.0.0/16 10.0.0.0/8"

    render_ntp_config "$target" "$template"

    run cat "$target"
    [[ "$output" == *"allow 192.168.0.0/16"* ]]
    [[ "$output" == *"allow 10.0.0.0/8"* ]]
    [[ "$output" != *"allow 0.0.0.0/0"* ]]
}

@test "validate_ntp_config rejects a config with no pool/server directive" {
    printf 'allow 0.0.0.0/0\n' > "$target"

    run validate_ntp_config "$target"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no pool/server directive"* ]]
}

@test "validate_ntp_config rejects a config with no allow directive" {
    printf 'server 192.0.2.1 iburst\n' > "$target"

    run validate_ntp_config "$target"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no allow directive"* ]]
}

@test "validate_ntp_config accepts a fully rendered config" {
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_UPSTREAM_SERVERS="192.0.2.1"
    # shellcheck disable=SC2034 # see the "renders a pool line" test above
    NTP_ALLOWED_CLIENT_CIDRS=""
    render_ntp_config "$target" "$template"

    run validate_ntp_config "$target"
    [ "$status" -eq 0 ]
}
