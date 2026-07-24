#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for lancache_ui_dhcp_mode_override_is_valid() (issue
# #1068 item 6) -- the pure gate cmd_converge_reconcile uses before ever
# folding an Admin-UI-written DHCP_MODE override into .env's DHCP_MODE and
# COMPOSE_PROFILES. Mirrors setup_ui_channel_override.bats exactly: this
# control only ever writes one of the three values
# parse_dhcp_mode_input in services/ui/src/routes/dhcp.rs accepts, and must
# silently no-op (never die()) on anything else, since it runs inside a
# scheduled systemd service tick that must not abort over an unexpected or
# stale value.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-ui-dhcp-mode-override-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-ui-dhcp-mode-override-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-ui-dhcp-mode-override-helpers.sh"
    load_setup_ui_dhcp_mode_override_helpers "$repo_root" "$helper_file"
}

@test "accepts disabled" {
    run lancache_ui_dhcp_mode_override_is_valid "disabled"
    [ "$status" -eq 0 ]
}

@test "accepts kea" {
    run lancache_ui_dhcp_mode_override_is_valid "kea"
    [ "$status" -eq 0 ]
}

@test "accepts dnsmasq-proxy" {
    run lancache_ui_dhcp_mode_override_is_valid "dnsmasq-proxy"
    [ "$status" -eq 0 ]
}

# The legacy DHCP_ENABLED=true boolean (pre-DHCP_MODE installs) implied Kea
# but is not itself a DHCP_MODE value -- must not be accepted by accident.
@test "rejects the legacy true/false boolean spellings" {
    run lancache_ui_dhcp_mode_override_is_valid "true"
    [ "$status" -eq 1 ]
    run lancache_ui_dhcp_mode_override_is_valid "false"
    [ "$status" -eq 1 ]
}

@test "rejects an empty value" {
    run lancache_ui_dhcp_mode_override_is_valid ""
    [ "$status" -eq 1 ]
}

@test "rejects garbage input without matching by accident" {
    run lancache_ui_dhcp_mode_override_is_valid "kea; rm -rf /"
    [ "$status" -eq 1 ]
}
