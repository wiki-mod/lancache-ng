#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for setup.sh DHCP-mode selection and mutual exclusion, plus
# rendering of the dnsmasq-proxy config template (issue #343). These guard the
# invariant that Kea mode and dnsmasq-proxy mode can never both be active.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-dhcp-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-dhcp-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-dhcp-helpers.sh"
    load_setup_dhcp_helpers "$repo_root" "$helper_file"
}

# ─── DHCP mode validation ───

# These three values—disabled, kea, and dnsmasq-proxy—are the exact valid
# values that setup.sh's DHCP_MODE config variable accepts.
@test "is_valid_dhcp_mode accepts the three supported modes" {
    run is_valid_dhcp_mode disabled
    [ "$status" -eq 0 ]
    run is_valid_dhcp_mode kea
    [ "$status" -eq 0 ]
    run is_valid_dhcp_mode dnsmasq-proxy
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
@test "compose_profiles_for_runtime emits dhcp-kea for kea mode" {
    run compose_profiles_for_runtime "" 0 kea
    [ "$status" -eq 0 ]
    [ "$output" = "dhcp-kea" ]
}

@test "compose_profiles_for_runtime emits dhcp-proxy for dnsmasq-proxy mode" {
    run compose_profiles_for_runtime "" 0 dnsmasq-proxy
    [ "$status" -eq 0 ]
    [ "$output" = "dhcp-proxy" ]
}

@test "compose_profiles_for_runtime emits no DHCP profile when disabled" {
    run compose_profiles_for_runtime "" 0 disabled
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compose_profiles_for_runtime never emits both DHCP profiles at once" {
    # Even when both profiles are already present in the existing value (e.g. a
    # hand-edited or migrated .env), selecting one mode must strip the other so
    # Kea and dnsmasq can never both claim UDP port 67.
    for mode in kea dnsmasq-proxy disabled; do
        run compose_profiles_for_runtime "dhcp-kea,dhcp-proxy" 0 "$mode"
        [ "$status" -eq 0 ]
        # Not both.
        if [[ ",$output," == *,dhcp-kea,* && ",$output," == *,dhcp-proxy,* ]]; then
            printf 'mode %s produced both DHCP profiles: %s\n' "$mode" "$output" >&2
            return 1
        fi
    done
}

@test "compose_profiles_for_runtime preserves unrelated profiles and ssl" {
    run compose_profiles_for_runtime "logging,dhcp-kea" 1 dnsmasq-proxy
    [ "$status" -eq 0 ]
    [ "$output" = "logging,ssl,dhcp-proxy" ]
}

# ─── dnsmasq-proxy template rendering ───

@test "dnsmasq.conf.template renders required proxy directives via envsubst" {
    export DHCP_SUBNET_START=10.0.0.0
    export DHCP_DNS_PRIMARY=10.0.0.10
    export DHCP_DNS_SECONDARY=10.0.0.11
    export UPSTREAM_DHCP_IP=10.0.0.1

    run envsubst < "$repo_root/services/dhcp-proxy/dnsmasq.conf.template"
    [ "$status" -eq 0 ]

    # DNS must stay disabled and the proxy must target the upstream server.
    [[ "$output" == *"port=0"* ]]
    [[ "$output" == *"dhcp-range=10.0.0.0,proxy"* ]]
    [[ "$output" == *"dhcp-option-pxe=6,10.0.0.10,10.0.0.11"* ]]
    [[ "$output" == *"dhcp-proxy=10.0.0.1"* ]]

    # No placeholder may survive rendering; an unexpanded ${VAR} would mean a
    # required value was silently dropped into the running config.
    [[ "$output" != *'${'* ]]
}
