#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for the issue #450 dnsmasq relay/proxy optional-option
# rendering in services/dhcp-proxy/entrypoint.sh
# (`_dhcp_proxy_render_optional_directives`,
# `_dhcp_proxy_render_custom_options`). Loads the real functions (not a
# reimplementation) and asserts on the raw lines they append, independent of
# `dnsmasq --test` (covered separately by dhcp_proxy_known_good_snapshot.bats
# and manual verification against a real dnsmasq build).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dhcp-proxy-optional-directives-helpers.sh"

    # shellcheck source=tests/bats/helpers/dhcp-proxy-optional-directives-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dhcp-proxy-optional-directives-helpers.sh"
    load_dhcp_proxy_optional_directives_helpers "$repo_root" "$helper_file"

    dest_conf="$BATS_TEST_TMPDIR/dnsmasq.conf"
    : > "$dest_conf"

    # All optional vars default unset, matching entrypoint.sh's `: "${VAR:=}"`
    # defaults, so each test only needs to set the ones it exercises.
    DHCP_PROXY_INTERFACE=""
    DHCP_PROXY_ROUTER=""
    DHCP_NTP_SERVERS=""
    DHCP_PROXY_DOMAIN=""
    DHCP_PROXY_BOOT_FILENAME=""
    DHCP_PROXY_BOOT_SERVER=""
    DHCP_PROXY_CUSTOM_OPTIONS=""
}

@test "no optional directives are rendered when every var is unset" {
    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [ ! -s "$dest_conf" ]
}

@test "interface, router, ntp, and domain each render their own line" {
    # shellcheck disable=SC2034 # read by _dhcp_proxy_render_optional_directives,
    # sourced dynamically into this shell by load_dhcp_proxy_optional_directives_helpers
    # (see setup() above) -- shellcheck cannot see the cross-file read.
    DHCP_PROXY_INTERFACE="eth0"
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment above
    DHCP_PROXY_ROUTER="10.0.0.1"
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment above
    DHCP_NTP_SERVERS="10.0.0.20,10.0.0.21"
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment above
    DHCP_PROXY_DOMAIN="lan.local"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]

    run cat "$dest_conf"
    [[ "$output" == *"interface=eth0"* ]]
    [[ "$output" == *"dhcp-option-pxe=3,10.0.0.1"* ]]
    [[ "$output" == *"dhcp-option-pxe=42,10.0.0.20,10.0.0.21"* ]]
    [[ "$output" == *"dhcp-option-pxe=15,lan.local"* ]]
}

@test "boot filename and server render a single dhcp-boot line" {
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment in the
    # "interface, router, ntp, and domain" test above
    DHCP_PROXY_BOOT_FILENAME="pxelinux.0"
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment above
    DHCP_PROXY_BOOT_SERVER="10.0.0.5"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-boot=pxelinux.0,,10.0.0.5"* ]]
}

@test "boot server without a filename is not rendered and warns" {
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment in the
    # "interface, router, ntp, and domain" test above
    DHCP_PROXY_BOOT_SERVER="10.0.0.5"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"boot server address alone is not meaningful"* ]]

    run cat "$dest_conf"
    [[ "$output" != *"dhcp-boot="* ]]
}

@test "custom options render one dhcp-option-pxe line per valid entry" {
    DHCP_PROXY_CUSTOM_OPTIONS="60:PXEClient;93:0"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXEClient"* ]]
    [[ "$output" == *"dhcp-option-pxe=93,0"* ]]
}

@test "custom options with an out-of-range or non-numeric code are skipped with a warning, not written" {
    DHCP_PROXY_CUSTOM_OPTIONS="abc:bad;9999:outofrange;60:PXEClient"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"option code must be numeric"* ]]
    [[ "$output" == *"WARNING"*"outside the valid DHCP option range"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXEClient"* ]]
    [[ "$output" != *"abc"* ]]
    [[ "$output" != *"9999"* ]]
}

@test "a custom option entry with no colon is skipped with an actionable warning" {
    DHCP_PROXY_CUSTOM_OPTIONS="justbroken;60:PXEClient"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"expected CODE:VALUE"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXEClient"* ]]
    [[ "$output" != *"justbroken"* ]]
}

@test "custom option values keep internal whitespace, only the whole entry is outer-trimmed" {
    # Leading/trailing whitespace around the *whole* entry is trimmed (from
    # the "  ...  " padding around it in the ';'-joined spec below), but the
    # internal space between "PXE" and "Client" in the value must survive --
    # this is the regression a naive `xargs`-based trim (which also
    # collapses internal whitespace) would reintroduce.
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment in the
    # "interface, router, ntp, and domain" test above
    DHCP_PROXY_CUSTOM_OPTIONS="  60:PXE Client  ;93:0"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXE Client"* ]]
    [[ "$output" == *"dhcp-option-pxe=93,0"* ]]
}
