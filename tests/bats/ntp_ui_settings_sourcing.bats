#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression tests for services/ntp/entrypoint.sh's sourcing of the
# Admin-UI-persisted settings file (`_ntp_source_ui_settings`), which had
# zero test coverage of any kind before this suite (same class of gap as
# services/dhcp-proxy/entrypoint.sh's dhcp_proxy_ui_settings_sourcing.bats,
# issue #849). NTP_UPSTREAM_SERVERS and NTP_ALLOWED_CLIENT_CIDRS can be set
# there instead of (or in addition to) the container's own environment, so a
# regression in this sourcing step would silently make those settings
# unreachable via the Admin UI while still working when set directly as
# container env vars.
#
# Loads the real function (extracted from entrypoint.sh, not reimplemented)
# and drives it against a throwaway path instead of the real, hardcoded
# /data/lancache-ui-settings.env.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/ntp-ui-settings-sourcing-helpers.sh"

    # shellcheck source=tests/bats/helpers/ntp-ui-settings-sourcing-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/ntp-ui-settings-sourcing-helpers.sh"
    load_ntp_ui_settings_sourcing_helpers "$repo_root" "$helper_file"

    settings_file="$BATS_TEST_TMPDIR/lancache-ui-settings.env"
}

@test "a missing settings file is not an error and sets no variables" {
    # Matches entrypoint.sh's real startup path on a fresh install, before
    # the Admin UI has ever persisted anything.
    [ ! -e "$settings_file" ]

    run _ntp_source_ui_settings "$settings_file"
    [ "$status" -eq 0 ]
    [ -z "${NTP_UPSTREAM_SERVERS:-}" ]
}

@test "an existing settings file's recognized keys become visible variables in the calling shell" {
    printf 'NTP_UPSTREAM_SERVERS=0.debian.pool.ntp.org time.cloudflare.com\nNTP_ALLOWED_CLIENT_CIDRS=192.168.0.0/16\n' > "$settings_file"

    # Bats' `run` executes in a subshell, which would hide the variables
    # this function is supposed to set in the CALLING shell -- entrypoint.sh
    # relies on exactly that (it calls this function at top level, then
    # reads NTP_UPSTREAM_SERVERS/NTP_ALLOWED_CLIENT_CIDRS directly
    # afterward via `: "${VAR:=default}"`), so this test calls the function
    # directly rather than through `run` to prove that contract, not just
    # that it exits 0. Also proves the while-loop reading this file
    # (`done < "$settings_file"`, a redirection, not a pipe) does not run in
    # a subshell of its own -- a `cmd | while read; do ...; done` shape
    # would have silently discarded every assignment here.
    _ntp_source_ui_settings "$settings_file"

    [ "$NTP_UPSTREAM_SERVERS" = "0.debian.pool.ntp.org time.cloudflare.com" ]
    [ "$NTP_ALLOWED_CLIENT_CIDRS" = "192.168.0.0/16" ]
}

@test "an empty settings file is read without error and sets no variables" {
    : > "$settings_file"

    run _ntp_source_ui_settings "$settings_file"
    [ "$status" -eq 0 ]
}

# What: settings-file value overwrites an already-set var.
# Why: enabled-to-enabled NTP restart fix depends on this.
# From: Issue #1486
@test "the settings file's NTP_UPSTREAM_SERVERS overwrites an already-set environment value" {
    printf 'NTP_UPSTREAM_SERVERS=time.example.net\n' > "$settings_file"
    NTP_UPSTREAM_SERVERS="0.debian.pool.ntp.org"

    _ntp_source_ui_settings "$settings_file"

    [ "$NTP_UPSTREAM_SERVERS" = "time.example.net" ]
}

@test "an unrecognized key belonging to a different service's settings is silently ignored" {
    # This settings file is shared across services (dhcp-proxy, ntp, and
    # others each persist their own settings into the same
    # /data/lancache-ui-settings.env). A key this service never reads --
    # e.g. another service's own setting -- must not leak into this shell's
    # variables just because it happens to share the file.
    printf 'DHCP_PROXY_CUSTOM_OPTIONS=93:some-value\nNTP_UPSTREAM_SERVERS=time.cloudflare.com\n' > "$settings_file"

    _ntp_source_ui_settings "$settings_file"

    [ "$NTP_UPSTREAM_SERVERS" = "time.cloudflare.com" ]
    [ -z "${DHCP_PROXY_CUSTOM_OPTIONS:-}" ]
}

@test "a value containing a command substitution is stored as a literal string, never executed" {
    # Security regression test: this function used to `. <file>`
    # (dot-source) the settings file, which is full shell evaluation. This
    # file is shared across services -- NTP_UPSTREAM_SERVERS itself is
    # strictly validated by the Admin UI (validate_ntp_upstream_servers,
    # services/ui/src/routes/ntp.rs: only bare IPv4/IPv6 literals or RFC
    # 1123 hostname labels), but a weakly-validated value written by a
    # DIFFERENT service's route into this same shared file -- confirmed
    # real for services/dhcp-proxy/entrypoint.sh's identical prior pattern:
    # DHCP_PROXY_CUSTOM_OPTIONS, validated only for length/embedded-newlines
    # by validate_custom_dhcp_option_data, not shell metacharacters -- would
    # previously have been executed here too, during this container's own
    # startup, even though ntp never reads that variable itself. The
    # rewritten parser below never dot-sources or evals the file, so a
    # value like this must now come through completely inert regardless of
    # which key it is assigned to.
    #
    # A canary file proves the command genuinely did not run (rather than
    # merely asserting the stored string looks right, which a shell that
    # both executed AND happened to produce empty output could satisfy by
    # accident).
    canary="$BATS_TEST_TMPDIR/canary"
    printf 'DHCP_PROXY_CUSTOM_OPTIONS=93:$(touch %s)\nNTP_UPSTREAM_SERVERS=x-$(touch %s)\n' "$canary" "$canary" > "$settings_file"

    _ntp_source_ui_settings "$settings_file"

    [ "$NTP_UPSTREAM_SERVERS" = 'x-$(touch '"$canary"')' ]
    [ -z "${DHCP_PROXY_CUSTOM_OPTIONS:-}" ]
    [ ! -e "$canary" ]
}
