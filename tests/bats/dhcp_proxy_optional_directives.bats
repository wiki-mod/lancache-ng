#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
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

@test "boot filename set with an empty boot server renders an empty saddr field, matching dnsmasq's own documented default-to-own-address behavior" {
    # Regression test for finding #7: docs/dhcp-modes.md claims
    # DHCP_PROXY_BOOT_SERVER "defaults to dnsmasq's own address if left
    # empty while a filename is set" -- confirmed against dnsmasq's own
    # upstream --dhcp-boot man-page text ("Server name and address are
    # optional: if not provided ... the address set to the address of the
    # machine running dnsmasq") before writing this test. This only proves
    # OUR side renders the expected empty saddr field; it does not itself
    # prove dnsmasq's runtime behavior (that would need a live dnsmasq
    # instance, out of scope for this function-level suite).
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment in the
    # "interface, router, ntp, and domain" test above
    DHCP_PROXY_BOOT_FILENAME="pxelinux.0"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-boot=pxelinux.0,,"* ]]
}

@test "an embedded newline in DHCP_PROXY_INTERFACE is rejected with a warning and renders nothing" {
    # Regression test for finding #3 (newline-injection asymmetry): this
    # function's own header comment previously claimed embedded-newline
    # protection for every value here, but the code never actually checked
    # for one outside of _dhcp_proxy_render_custom_options's numeric code
    # check (which only validated the code, never the value). Every value
    # below now goes through the shared _dhcp_proxy_reject_embedded_newline
    # helper.
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_INTERFACE=$'eth0\ninterface=evil0'

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"embedded newline"* ]]
    [ ! -s "$dest_conf" ]
}

@test "an embedded newline in DHCP_PROXY_ROUTER/DHCP_NTP_SERVERS/DHCP_PROXY_DOMAIN is rejected per-field, not all-or-nothing" {
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_ROUTER=$'10.0.0.1\ndhcp-option-pxe=99,evil'
    # shellcheck disable=SC2034 # see comment above
    DHCP_NTP_SERVERS="10.0.0.20"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_DOMAIN="lan.local"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"DHCP_PROXY_ROUTER"*"embedded newline"* ]]

    run cat "$dest_conf"
    # The two clean fields still render even though DHCP_PROXY_ROUTER was
    # rejected -- one bad field must not silently swallow the others.
    [[ "$output" == *"dhcp-option-pxe=42,10.0.0.20"* ]]
    [[ "$output" == *"dhcp-option-pxe=15,lan.local"* ]]
    [[ "$output" != *"dhcp-option-pxe=3,"* ]]
}

@test "an embedded newline in DHCP_PROXY_BOOT_FILENAME or DHCP_PROXY_BOOT_SERVER is rejected and renders no dhcp-boot line" {
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_BOOT_FILENAME="pxelinux.0"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_BOOT_SERVER=$'10.0.0.5\ndhcp-boot=injected,,evil'

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"embedded newline"* ]]

    run cat "$dest_conf"
    [[ "$output" != *"dhcp-boot="* ]]
}

@test "a custom option targeting the always-collided DNS code 6 is skipped with a warning" {
    # Regression test for finding #1: dnsmasq.conf.template always renders
    # dhcp-option-pxe=6 unconditionally, so a custom option for code 6 would
    # always produce a silent duplicate line, independent of whether
    # DHCP_PROXY_ROUTER/DOMAIN/NTP_SERVERS are set.
    DHCP_PROXY_CUSTOM_OPTIONS="6:8.8.8.8;60:PXEClient"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"option code 6 (DNS servers) always collides"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXEClient"* ]]
    [[ "$output" != *"dhcp-option-pxe=6,8.8.8.8"* ]]
}

@test "a custom option targeting router/domain/ntp codes only collides when the matching dedicated field is actually set" {
    # shellcheck disable=SC2034 # see DHCP_PROXY_INTERFACE comment in the
    # "interface, router, ntp, and domain" test above
    DHCP_PROXY_ROUTER="10.0.0.1"
    # Code 15 (domain) has no dedicated field set here, so a custom option
    # for it must NOT be treated as a collision.
    DHCP_PROXY_CUSTOM_OPTIONS="3:10.0.0.9;15:example.com;42:10.0.0.20"

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"option code 3 (router) collides with DHCP_PROXY_ROUTER"* ]]
    [[ "$output" != *"option code 15"*"collides"* ]]

    run cat "$dest_conf"
    # DHCP_PROXY_ROUTER's own dedicated-field line still renders; only the
    # colliding custom-option duplicate for the same code is dropped.
    [[ "$output" == *"dhcp-option-pxe=3,10.0.0.1"* ]]
    [[ "$output" != *"dhcp-option-pxe=3,10.0.0.9"* ]]
    # The non-colliding custom option for code 15 (no dedicated
    # DHCP_PROXY_DOMAIN set) still renders normally.
    [[ "$output" == *"dhcp-option-pxe=15,example.com"* ]]
    # NTP_SERVERS was never set, so custom code 42 is not a collision.
    [[ "$output" == *"dhcp-option-pxe=42,10.0.0.20"* ]]
}

@test "a raw newline anywhere in DHCP_PROXY_CUSTOM_OPTIONS truncates parsing there, never injecting the remainder" {
    # This is NOT primarily a test of _dhcp_proxy_render_custom_options'
    # own per-value _dhcp_proxy_reject_embedded_newline call (confirmed by
    # real execution: that call is defense-in-depth and not reachable via
    # this exact input shape -- see the entrypoint.sh comment right above
    # that call for why). What actually protects against this input is
    # `IFS=';' read -r -a entries <<< "$spec"`'s own line-terminator
    # detection, which stops at the FIRST raw newline anywhere in $spec
    # regardless of IFS -- everything after it (here, a crafted extra
    # directive) is silently dropped before the entry loop ever starts.
    # This test locks in that real, already-relied-upon behavior so a
    # future change to how $spec is parsed cannot silently regress it.
    DHCP_PROXY_CUSTOM_OPTIONS=$'60:PXEClient\ndhcp-option-pxe=99,evil'

    run _dhcp_proxy_render_optional_directives "$dest_conf"
    [ "$status" -eq 0 ]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-option-pxe=60,PXEClient"* ]]
    [[ "$output" != *"dhcp-option-pxe=99,evil"* ]]
}

@test "_dhcp_proxy_reject_embedded_newline itself rejects a value containing a raw newline" {
    # Direct unit test of the shared guard function, independent of
    # whichever caller's own input-shaping (like the `read` truncation
    # above) might or might not let a newline reach it in practice --
    # proves the guard is correct on its own terms, which is what makes it
    # trustworthy as defense-in-depth for callers that can't rely on that
    # same truncation (see _dhcp_proxy_render_pxe_service_directives's own
    # tests in dhcp_proxy_pxe_service_directives.bats for a caller where
    # this guard IS the only protection).
    run _dhcp_proxy_reject_embedded_newline "SOME_LABEL" $'clean-part\ninjected-part'
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARNING"*"SOME_LABEL"*"embedded newline"* ]]
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
