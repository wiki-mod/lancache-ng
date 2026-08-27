#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for the issue #705 PXE boot-pointer rendering in
# services/dhcp-proxy/entrypoint.sh (`_dhcp_proxy_render_pxe_service_directives`).
# This function previously had zero test coverage at all (issue #849
# dhcp-proxy.md finding #5) despite being the directive that actually makes
# dnsmasq's ProxyDHCP mode reply to a DHCPDISCOVER in the first place (see
# the function's own header comment in entrypoint.sh). Loads the real
# function (not a reimplementation) and asserts on the raw lines it appends,
# independent of `dnsmasq --test` or a live packet capture (covered
# separately, for the BIOS+UEFI-both-configured case only, by
# scripts/tracked/simulations/dhcp-proxy-pxe-simulation.sh's real Docker-based end-to-end run).
#
# The have_bios=0 (UEFI-only) branch below is the one real gap named in
# finding #8 ("UEFI-only PXE path never tested end-to-end"):
# scripts/tracked/simulations/dhcp-proxy-pxe-simulation.sh always configures BOTH BIOS and UEFI
# filenames together, so it never exercises the IA64_EFI pxe-service
# fallback this function renders specifically when only UEFI is configured.
# These tests give that branch real, deterministic coverage at the
# config-render level; a genuine live-Docker packet-level UEFI-only
# scenario needs its own isolated network (two dnsmasq-proxy instances on
# one broadcast domain would both answer the same broadcast DISCOVER,
# making a "no reply for arch 0" assertion meaningless) and is out of scope
# here -- see the #849 tracking comment for that residual gap.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dhcp-proxy-pxe-service-directives-helpers.sh"

    # shellcheck source=tests/bats/helpers/dhcp-proxy-pxe-service-directives-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dhcp-proxy-pxe-service-directives-helpers.sh"
    load_dhcp_proxy_pxe_service_directives_helpers "$repo_root" "$helper_file"

    dest_conf="$BATS_TEST_TMPDIR/dnsmasq.conf"
    : > "$dest_conf"

    # All PXE vars default unset, matching entrypoint.sh's `: "${VAR:=}"`
    # defaults, so each test only needs to set the ones it exercises.
    DHCP_PROXY_PXE_BOOT_SERVER=""
    DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=""
    DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=""
}

@test "no PXE directives are rendered when every var is unset" {
    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [ ! -s "$dest_conf" ]
    [[ "$output" != *"WARNING"* ]]
}

@test "boot server without any filename warns and renders nothing" {
    # shellcheck disable=SC2034 # read by _dhcp_proxy_render_pxe_service_directives
    DHCP_PROXY_PXE_BOOT_SERVER="10.0.0.5"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"a boot server alone cannot produce a pxe-service directive"* ]]
    [ ! -s "$dest_conf" ]
}

@test "a filename without a boot server warns and renders nothing" {
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="bios.0"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"a boot filename alone cannot produce a pxe-service directive"* ]]
    [ ! -s "$dest_conf" ]
}

@test "BIOS-only configuration renders pxe-service=x86PC plus a tag-scoped dhcp-boot, no UEFI lines" {
    DHCP_PROXY_PXE_BOOT_SERVER="10.0.0.5"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="lancache-pxe-bios.0"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]

    run cat "$dest_conf"
    [[ "$output" == *'pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",lancache-pxe-bios.0,10.0.0.5'* ]]
    [[ "$output" == *"dhcp-match=set:lancache-pxe-bios,option:client-arch,0"* ]]
    [[ "$output" == *"dhcp-boot=tag:lancache-pxe-bios,lancache-pxe-bios.0,,10.0.0.5"* ]]
    [[ "$output" != *"lancache-pxe-uefi"* ]]
    [[ "$output" != *"IA64_EFI"* ]]
}

@test "UEFI-only configuration (have_bios=0) renders dhcp-match/dhcp-boot for arch 7 and 11 plus the IA64_EFI pxe-service fallback, no x86PC line" {
    # This is the never-live-tested branch named in finding #8: without at
    # least one pxe-service directive somewhere in the config, dnsmasq's
    # ProxyDHCP mode does not reply to ANY DHCPDISCOVER at all (see the
    # function's own header comment) -- when only UEFI is configured, the
    # x86PC pxe-service line from the BIOS branch doesn't exist to satisfy
    # that requirement, so this IA64_EFI fallback line must appear instead.
    DHCP_PROXY_PXE_BOOT_SERVER="10.0.0.5"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_UEFI="lancache-pxe-uefi.efi"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]

    run cat "$dest_conf"
    [[ "$output" == *"dhcp-match=set:lancache-pxe-uefi,option:client-arch,7"* ]]
    [[ "$output" == *"dhcp-match=set:lancache-pxe-uefi,option:client-arch,11"* ]]
    [[ "$output" == *"dhcp-boot=tag:lancache-pxe-uefi,lancache-pxe-uefi.efi,,10.0.0.5"* ]]
    [[ "$output" == *'pxe-service=IA64_EFI,"lancache-ng PXE proxy active",0'* ]]
    [[ "$output" != *"x86PC"* ]]
    [[ "$output" != *"lancache-pxe-bios"* ]]
}

@test "both BIOS and UEFI configured render all six lines, no IA64_EFI fallback" {
    # The x86PC pxe-service line alone already satisfies the "at least one
    # pxe-service directive" requirement, so the IA64_EFI fallback used in
    # the UEFI-only case above must NOT also appear here -- it would be a
    # redundant, confusing extra pxe-service entry with no purpose.
    DHCP_PROXY_PXE_BOOT_SERVER="10.0.0.5"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="lancache-pxe-bios.0"
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_UEFI="lancache-pxe-uefi.efi"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]

    run cat "$dest_conf"
    [[ "$output" == *"x86PC"* ]]
    [[ "$output" == *"lancache-pxe-bios"* ]]
    [[ "$output" == *"lancache-pxe-uefi"* ]]
    [[ "$output" != *"IA64_EFI"* ]]
    [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "an embedded newline in any PXE var is rejected with a warning and renders nothing" {
    # Regression test for finding #3 (newline-injection asymmetry): this
    # function's own guard now goes through the shared
    # _dhcp_proxy_reject_embedded_newline helper, same as every other
    # render function in this file.
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_SERVER=$'10.0.0.5\ndhcp-boot=injected,,evil'
    # shellcheck disable=SC2034 # see comment above
    DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="bios.0"

    run _dhcp_proxy_render_pxe_service_directives "$dest_conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"*"embedded newline"* ]]
    [ ! -s "$dest_conf" ]
}
