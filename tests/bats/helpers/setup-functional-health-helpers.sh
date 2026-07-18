#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the real setup.sh post-update functional health
# gate -- require_functional_check_tool, verify_stack_functional_health,
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
}
