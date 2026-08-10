#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for setup.sh DHCP-mode selection and mutual exclusion, plus
# rendering of the dnsmasq-proxy and dnsmasq-relay (#844) config templates
# (issue #343). These guard the invariant that Kea mode and the dnsmasq modes
# can never both be active (both bind UDP port 67).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-dhcp-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-dhcp-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-dhcp-helpers.sh"
    load_setup_dhcp_helpers "$repo_root" "$helper_file"
}

# ─── DHCP mode validation ───

# These four values—disabled, kea, dnsmasq-proxy, and dnsmasq-relay (#844)—are
# the exact valid values that setup.sh's DHCP_MODE config variable accepts.
@test "is_valid_dhcp_mode accepts the four supported modes" {
    run is_valid_dhcp_mode disabled
    [ "$status" -eq 0 ]
    run is_valid_dhcp_mode kea
    [ "$status" -eq 0 ]
    run is_valid_dhcp_mode dnsmasq-proxy
    [ "$status" -eq 0 ]
    run is_valid_dhcp_mode dnsmasq-relay
    [ "$status" -eq 0 ]
}

# Testing "dnsmasq" (not "dnsmasq-proxy") specifically is important because it is
# a plausible typo or confusion for someone who knows the underlying tool is dnsmasq.
@test "is_valid_dhcp_mode rejects unknown modes" {
    run is_valid_dhcp_mode dnsmasq
    [ "$status" -ne 0 ]
    run is_valid_dhcp_mode ""
    [ "$status" -ne 0 ]
    run is_valid_dhcp_mode 1
    [ "$status" -ne 0 ]
}

@test "is_dnsmasq_subnet_start requires a valid network base ending in .0" {
    run is_dnsmasq_subnet_start 10.0.0.0
    [ "$status" -eq 0 ]
    run is_dnsmasq_subnet_start 192.168.1.0
    [ "$status" -eq 0 ]

    # A host address (does not end in .0) must be rejected so proxy-DHCP is not
    # configured against a single host instead of the subnet base.
    run is_dnsmasq_subnet_start 10.0.0.5
    [ "$status" -ne 0 ]
    run is_dnsmasq_subnet_start not-an-ip
    [ "$status" -ne 0 ]
}

# ─── Mutual exclusion (the core #343 safety invariant) ───

# The following three tests establish the basic mode-to-profile mapping baseline:
# each DHCP mode (kea, dnsmasq-proxy, disabled) must emit the correct profile(s).
# The mutual-exclusion test below builds on this baseline by verifying that
# switching modes always removes the unneeded profile.
# Issue #1343: logging_enabled (5th arg) defaults to "1" (on by default), unlike
# ssl/ntp above it which default to "0" -- every call below that is testing DHCP
# mode mapping in isolation passes an explicit "0 0" for ntp_enabled/
# logging_enabled so its expected output stays focused on DHCP behavior instead
# of coupling every DHCP-mode assertion to the separate logging-default
# decision (which has its own dedicated coverage further down and in
# tests/bats/setup_update_idempotence.bats).
@test "compose_profiles_for_runtime emits dhcp-kea for kea mode" {
    run compose_profiles_for_runtime "" 0 kea 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "dhcp-kea" ]
}

@test "compose_profiles_for_runtime emits dhcp-proxy for dnsmasq-proxy mode" {
    run compose_profiles_for_runtime "" 0 dnsmasq-proxy 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "dhcp-proxy" ]
}

# Issue #844: relay mode shares the dhcp-proxy container/profile with ProxyDHCP
# mode (DHCP_MODE tells them apart), so it must map to the same profile.
@test "compose_profiles_for_runtime emits dhcp-proxy for dnsmasq-relay mode" {
    run compose_profiles_for_runtime "" 0 dnsmasq-relay 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "dhcp-proxy" ]
}

@test "compose_profiles_for_runtime emits no DHCP profile when disabled" {
    run compose_profiles_for_runtime "" 0 disabled 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compose_profiles_for_runtime never emits both DHCP profiles at once" {
    # Even when both profiles are already present in the existing value (e.g. a
    # hand-edited or migrated .env), selecting one mode must strip the other so
    # Kea and dnsmasq can never both claim UDP port 67.
    for mode in kea dnsmasq-proxy dnsmasq-relay disabled; do
        run compose_profiles_for_runtime "dhcp-kea,dhcp-proxy" 0 "$mode" 0 0
        [ "$status" -eq 0 ]
        # Not both.
        if [[ ",$output," == *,dhcp-kea,* && ",$output," == *,dhcp-proxy,* ]]; then
            printf 'mode %s produced both DHCP profiles: %s\n' "$mode" "$output" >&2
            return 1
        fi
    done
}

@test "compose_profiles_for_runtime preserves unrelated profiles and ssl" {
    # logging_enabled deliberately left at its "1" default here (not passed
    # explicitly) to also prove the existing "logging" entry in the incoming
    # string is stripped and correctly re-added by the default, not just
    # passed through verbatim -- "ssl,dhcp-proxy,logging" is the real emission
    # order (ssl, then DHCP, then logging last), not the incoming order.
    run compose_profiles_for_runtime "logging,dhcp-kea" 1 dnsmasq-proxy
    [ "$status" -eq 0 ]
    [ "$output" = "ssl,dhcp-proxy,logging" ]
}

# ─── Central logging default (issue #1343) ───
# Central logging is the one profile flag in this function that defaults to
# enabled instead of disabled -- these tests pin down that default, its real
# opt-out, and the omitted-argument fail-safe explicitly, since a regression
# here would silently reintroduce the exact bug #1343 was filed for (a normal
# install never enabling central logging).

@test "compose_profiles_for_runtime enables logging by default when no 5th argument is given" {
    # Mirrors a caller that has not been updated to pass logging_enabled at
    # all -- must fail SAFE toward "still enabled", not toward the old bug.
    run compose_profiles_for_runtime "" 0 disabled 0
    [ "$status" -eq 0 ]
    [ "$output" = "logging" ]
}

@test "compose_profiles_for_runtime respects an explicit logging opt-out" {
    run compose_profiles_for_runtime "" 0 disabled 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compose_profiles_for_runtime keeps logging enabled when explicitly requested" {
    run compose_profiles_for_runtime "" 0 disabled 0 1
    [ "$status" -eq 0 ]
    [ "$output" = "logging" ]
}

@test "compose_profiles_for_runtime is idempotent for an already-present logging profile" {
    # Running the operation twice with identical input must produce identical
    # output (AG-OP-006/the Convergence/Idempotence Checklist) -- feeding
    # logging back in as already-present existing state must not duplicate it.
    run compose_profiles_for_runtime "logging" 0 disabled 0 1
    [ "$status" -eq 0 ]
    [ "$output" = "logging" ]
}

# ─── dnsmasq-proxy template rendering ───

@test "dnsmasq.conf.template renders required proxy directives via envsubst" {
    export DHCP_SUBNET_START=10.0.0.0
    export DHCP_DNS_PRIMARY=10.0.0.10
    export DHCP_DNS_SECONDARY=10.0.0.11
    export UPSTREAM_DHCP_IP=10.0.0.1

    run envsubst < "$repo_root/services/dhcp-proxy/dnsmasq.conf.template"
    [ "$status" -eq 0 ]

    # DNS must stay disabled and the proxy must serve the configured subnet.
    [[ "$output" == *"port=0"* ]]
    [[ "$output" == *"dhcp-range=10.0.0.0,proxy"* ]]
    [[ "$output" == *"dhcp-option-pxe=6,10.0.0.10,10.0.0.11"* ]]

    # Issue #450: `dhcp-proxy=<ip>` means "treat these DHCP-relay agents as
    # full proxies" (RFC 5107) -- it does nothing without --dhcp-relay=,
    # which this service never configures (confirmed against a live
    # `dnsmasq --help`/`--test`). It must not reappear in the template;
    # UPSTREAM_DHCP_IP is documentation-only now (see docs/dhcp-modes.md).
    [[ "$output" != *"dhcp-proxy="* ]]

    # No placeholder may survive rendering; an unexpanded ${VAR} would mean a
    # required value was silently dropped into the running config.
    [[ "$output" != *'${'* ]]
}

# ─── dnsmasq-relay template rendering (issue #844) ───

@test "dnsmasq-relay.conf.template renders a real dhcp-relay directive via envsubst" {
    export DHCP_RELAY_LOCAL_ADDR=192.168.1.2
    export UPSTREAM_DHCP_IP=10.0.0.1

    run envsubst < "$repo_root/services/dhcp-proxy/dnsmasq-relay.conf.template"
    [ "$status" -eq 0 ]

    # DNS stays disabled, and the relay forwards local-addr -> upstream. This is
    # a REAL relay directive, distinct from the ProxyDHCP template's dhcp-range.
    [[ "$output" == *"port=0"* ]]
    [[ "$output" == *"dhcp-relay=192.168.1.2,10.0.0.1"* ]]

    # A relay injects nothing of its own: none of the ProxyDHCP directives. Test
    # the non-comment DIRECTIVE lines only -- the template's header comment
    # legitimately mentions these directive names while explaining their absence.
    directives="$(printf '%s\n' "$output" | grep -v '^[[:space:]]*#' || true)"
    [[ "$directives" != *"dhcp-range="* ]]
    [[ "$directives" != *"dhcp-option-pxe="* ]]
    [[ "$directives" != *"pxe-service="* ]]

    # No placeholder may survive rendering.
    [[ "$output" != *'${'* ]]
}
