#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the real setup.sh post-update functional health
# gate -- require_functional_check_tool, _tcp_port_reachable,
# _verify_healthz_endpoint, verify_stack_functional_health,
# service_container_is_healthy, wait_for_stack_health, rollback_stack_update,
# install_missing_tools, and package_name_for_tool -- without executing
# setup.sh's interactive install/update entrypoint or its top-level CLI
# dispatcher.
#
# The captured range starts at is_valid_ipv4() (same start point
# setup-update-helpers.sh and setup-backup-restore-helpers.sh already use)
# and ends right before cmd_update(), the first helper defined after
# perform_stack_update_flow() in setup.sh. That range is pure
# function/variable definitions with no top-level executable statements
# (same property the two narrower existing helpers already rely on for
# their own sub-ranges of this same block), so sourcing it has no side
# effects beyond defining functions.
#
# A few globals/helpers this range depends on are defined earlier in
# setup.sh (outside the captured range) and are stubbed here instead of
# captured, the same pattern the other setup.sh bats helpers already use for
# die/print_ok/print_step/print_warn/print_error.
#
# Tests that exercise verify_stack_functional_health's curl/dig probes must
# put their own stub curl/dig on PATH (or empty the PATH entirely to
# simulate a tool that is really missing) -- this helper does not fake those
# tools itself, since the right stub shape (success, HTTP failure, empty DNS
# answer, absent) differs per test.

load_setup_functional_health_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { printf "OK: %s\n" "$*"; }'
        printf '%s\n' 'print_step() { printf "STEP: %s\n" "$*"; }'
        printf '%s\n' 'print_warn() { printf "WARN: %s\n" "$*" >&2; }'
        printf '%s\n' 'print_error() { printf "ERROR: %s\n" "$*" >&2; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "$repo_root"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^cmd_update\(\)/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"

    # The captured range's own `declare -A _REGRESSED_SERVICE_SYSLOG_HOST=(...)`
    # (setup.sh's dhcp-proxy/nats/syslog -> syslog-ng-host mapping) just ran
    # as part of the `source` above -- but that happens inside THIS function,
    # so a plain `declare` without `-g` scopes it local to
    # load_setup_functional_health_helpers, and it evaporates the instant
    # this function returns, before any caller (e.g. a bats setup()) even
    # gets a chance to see it -- a caller-side `declare -p`/promote trick
    # would be too late by then; it has to happen here, one level in, while
    # the local value is still alive. Unlike _UPDATE_HEALTH_BASELINE (which
    # callers re-declare fresh+empty themselves, since tests populate it
    # per-test), this array must keep setup.sh's own real content, so it is
    # promoted via `declare -p` + re-eval with `-gA` substituted in, not
    # re-declared empty. Guarded on the array actually existing, since not
    # every captured range this helper might load in the future necessarily
    # defines it.
    if declare -p _REGRESSED_SERVICE_SYSLOG_HOST &>/dev/null; then
        eval "$(declare -p _REGRESSED_SERVICE_SYSLOG_HOST | sed 's/^declare -A/declare -gA/')"
    fi
}
