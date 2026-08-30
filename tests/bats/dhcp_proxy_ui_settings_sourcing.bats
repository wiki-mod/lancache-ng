#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for services/dhcp-proxy/entrypoint.sh's sourcing of the
# Admin-UI-persisted settings file (`_dhcp_proxy_source_ui_settings`), which
# had zero test coverage of any kind before this suite (issue #849
# dhcp-proxy.md finding #9). DHCP_MODE (issue #844) and every
# DHCP_PROXY_*/DHCP_PROXY_PXE_* var this service reads can be set there
# instead of (or in addition to) the container's own environment, so a
# regression in this sourcing step would silently make every one of those
# settings unreachable via the Admin UI while still working when set
# directly as container env vars -- exactly the kind of gap that would not
# show up in any of the other dhcp-proxy bats suites, which all set their
# vars directly rather than through a sourced file.
#
# Loads the real function (extracted from entrypoint.sh, not
# reimplemented) and drives it against a throwaway path instead of the
# real, hardcoded /data/lancache-ui-settings.env.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/dhcp-proxy-ui-settings-sourcing-helpers.sh"

    # shellcheck source=tests/bats/helpers/dhcp-proxy-ui-settings-sourcing-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/dhcp-proxy-ui-settings-sourcing-helpers.sh"
    load_dhcp_proxy_ui_settings_sourcing_helpers "$repo_root" "$helper_file"

    settings_file="$BATS_TEST_TMPDIR/lancache-ui-settings.env"
}

@test "a missing settings file is not an error and sets no variables" {
    # Matches entrypoint.sh's real startup path on a fresh install, before
    # the Admin UI has ever persisted anything.
    [ ! -e "$settings_file" ]

    run _dhcp_proxy_source_ui_settings "$settings_file"
    [ "$status" -eq 0 ]
    [ -z "${DHCP_MODE:-}" ]
}

@test "an existing settings file's recognized keys become visible variables in the calling shell" {
    printf 'DHCP_MODE=dnsmasq-relay\nDHCP_PROXY_ROUTER=10.0.0.1\n' > "$settings_file"

    # Bats' `run` executes in a subshell, which would hide the variables
    # this function is supposed to set in the CALLING shell -- entrypoint.sh
    # relies on exactly that (it calls this function at top level, then
    # reads DHCP_MODE/DHCP_PROXY_* directly afterward), so this test calls
    # the function directly rather than through `run` to prove that
    # contract, not just that it exits 0. Also proves the while-loop reading
    # this file (`done < "$settings_file"`, a redirection, not a pipe) does
    # not run in a subshell of its own -- a `cmd | while read; do ...; done`
    # shape would have silently discarded every assignment here.
    _dhcp_proxy_source_ui_settings "$settings_file"

    [ "$DHCP_MODE" = "dnsmasq-relay" ]
    [ "$DHCP_PROXY_ROUTER" = "10.0.0.1" ]
}

@test "an empty settings file is read without error and sets no variables" {
    : > "$settings_file"

    run _dhcp_proxy_source_ui_settings "$settings_file"
    [ "$status" -eq 0 ]
}

# What: settings-file value overwrites an already-set var.
# Why: ProxyDHCP<->Relay restart fix depends on this.
# From: Issue #1486
@test "the settings file's DHCP_MODE overwrites an already-set environment value" {
    printf 'DHCP_MODE=dnsmasq-relay\n' > "$settings_file"
    DHCP_MODE="dnsmasq-proxy"

    _dhcp_proxy_source_ui_settings "$settings_file"

    [ "$DHCP_MODE" = "dnsmasq-relay" ]
}

@test "a value containing a command substitution is stored as a literal string, never executed" {
    # Security regression test: this function used to `. <file>`
    # (dot-source) the settings file, which is full shell evaluation --
    # confirmed by real execution during this fix's own investigation that
    # a value like `DHCP_PROXY_CUSTOM_OPTIONS="x-$(id)"` actually ran `id`
    # as a live command when dot-sourced, because
    # validate_custom_dhcp_option_data (services/ui/src/routes/dhcp.rs)
    # only rejects an empty/too-long/embedded-newline value, not shell
    # metacharacters, and write_ui_settings_file writes the value raw and
    # unquoted. The rewritten parser below never dot-sources or evals the
    # file, so the same value must now come through completely inert.
    #
    # A canary file proves the command genuinely did not run (rather than
    # merely asserting the stored string looks right, which a shell that
    # both executed AND happened to produce empty output could satisfy
    # by accident).
    canary="$BATS_TEST_TMPDIR/canary"
    printf 'DHCP_PROXY_CUSTOM_OPTIONS=93:$(touch %s)\n' "$canary" > "$settings_file"

    _dhcp_proxy_source_ui_settings "$settings_file"

    [ "$DHCP_PROXY_CUSTOM_OPTIONS" = '93:$(touch '"$canary"')' ]
    [ ! -e "$canary" ]
}
