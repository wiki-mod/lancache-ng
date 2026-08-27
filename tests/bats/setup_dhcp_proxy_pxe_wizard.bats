#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression coverage for the interactive dnsmasq-proxy wizard's PXE
# boot-pointer opt-in step and migrate_env_for_update()'s equivalent
# convergence check, both of which share
# pxe_boot_pointer_answers_are_complete() as the single source of truth for
# "does this answer set actually activate PXE boot-pointer support." Neither
# scripts/tracked/simulations/setup-cli-simulation.sh nor scripts/tracked/simulations/syslog-forwarding-simulation.sh
# drives the interactive wizard through dnsmasq-proxy mode at all (both
# always answer "disabled" for DHCP mode), so the real, previously
# hand-verified-only combined-invariant decision ("a server needs at least
# one boot filename to matter, and vice versa") had no automated coverage
# before this file. Building a full expect-driven interactive simulation of
# the dnsmasq-proxy + PXE prompt sequence is a materially larger, separate
# undertaking (extending scripts/tracked/simulations/setup-cli-simulation.sh's own generated
# expect_prompt mechanism to a DHCP mode it does not exercise for any mode
# today) -- this file instead drives the real decision function the wizard
# and the update-time migration both call, which is where an actual logic
# bug in this feature would live.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-dhcp-proxy-pxe-wizard-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-dhcp-proxy-pxe-wizard-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-dhcp-proxy-pxe-wizard-helpers.sh"
    load_setup_dhcp_proxy_pxe_wizard_helpers "$repo_root" "$helper_file"
}

@test "pxe_boot_pointer_answers_are_complete accepts a server with a BIOS filename only" {
    run pxe_boot_pointer_answers_are_complete "10.0.0.5" "pxelinux.0" ""
    [ "$status" -eq 0 ]
}

@test "pxe_boot_pointer_answers_are_complete accepts a server with a UEFI filename only" {
    run pxe_boot_pointer_answers_are_complete "10.0.0.5" "" "bootx64.efi"
    [ "$status" -eq 0 ]
}

@test "pxe_boot_pointer_answers_are_complete accepts a server with both filenames" {
    run pxe_boot_pointer_answers_are_complete "10.0.0.5" "pxelinux.0" "bootx64.efi"
    [ "$status" -eq 0 ]
}

# The exact case the wizard's own inline check used to guard: a confirmed
# server with neither filename answered must be treated as incomplete, so
# the caller resets the server rather than persisting a config entrypoint.sh
# can only ever warn about, never actually activate.
@test "pxe_boot_pointer_answers_are_complete rejects a server with neither filename" {
    run pxe_boot_pointer_answers_are_complete "10.0.0.5" "" ""
    [ "$status" -ne 0 ]
}

# migrate_env_for_update's own half of this invariant: a hand-edited .env
# can carry a boot filename with no server at all (the wizard itself cannot
# produce this shape, since it only asks for a filename after a server is
# already given -- but an operator editing .env by hand can).
@test "pxe_boot_pointer_answers_are_complete rejects a filename with no server" {
    run pxe_boot_pointer_answers_are_complete "" "pxelinux.0" ""
    [ "$status" -ne 0 ]
}

@test "pxe_boot_pointer_answers_are_complete rejects an entirely empty answer set" {
    run pxe_boot_pointer_answers_are_complete "" "" ""
    [ "$status" -ne 0 ]
}

# End-to-end sanity for the exact values the wizard actually collects: a
# realistic complete answer set passes both this function AND the filename
# validator the wizard's own retry loop already gates each field with.
@test "a realistic complete PXE answer set passes both the filename validator and the completeness check" {
    run is_valid_dhcp_proxy_boot_filename "pxelinux.0"
    [ "$status" -eq 0 ]
    run is_valid_dhcp_proxy_boot_filename "bootx64.efi"
    [ "$status" -eq 0 ]
    run pxe_boot_pointer_answers_are_complete "10.0.0.5" "pxelinux.0" "bootx64.efi"
    [ "$status" -eq 0 ]
}

# is_valid_dhcp_proxy_boot_filename() must reject every character
# validate_env_value() rejects before writing .env, so the wizard's
# per-field retry loop cannot accept a value that only fails later, deep
# into validate_env_values_for_initial_write()'s pre-write check (after the
# installer has already walked the operator through several more setup
# steps). Covers each rejected character individually, plus a filename
# that was already valid under the whitespace/comma-only check, to prove
# this is a strictly additive tightening, not a behavior change for
# already-valid input.
@test "is_valid_dhcp_proxy_boot_filename rejects every character validate_env_value also rejects" {
    run is_valid_dhcp_proxy_boot_filename 'images/boot#1.efi'
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename 'boot$file.efi'
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename 'boot`file.efi'
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename 'boot"file.efi'
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename "boot'file.efi"
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename 'boot\file.efi'
    [ "$status" -ne 0 ]
    run is_valid_dhcp_proxy_boot_filename "$(printf 'boot\nfile.efi')"
    [ "$status" -ne 0 ]
    # Still accepts a real, already-valid filename shape.
    run is_valid_dhcp_proxy_boot_filename "pxelinux.0"
    [ "$status" -eq 0 ]
}
