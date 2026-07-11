#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's .env helpers AND migrate_env_for_update()
# itself (the real update-migration entrypoint invoked by `setup.sh update`),
# without executing setup.sh's interactive install/update entrypoint or its
# top-level CLI dispatcher (`case "${1:-install}" in ...`, further down the
# file). This lets repeat-run idempotence tests call the actual migration
# logic directly instead of re-implementing/approximating it, and instead of
# paying for a full docker-based setup.sh CLI simulation for every case.
#
# The captured range starts at is_valid_ipv4() and ends right before
# install_missing_tools() (the first helper defined after
# migrate_env_for_update() in setup.sh). Everything in between is pure
# function/variable definitions -- no top-level executable statements -- so
# sourcing it has no side effects beyond defining functions. A few globals
# and helpers that migrate_env_for_update() depends on are defined earlier in
# setup.sh (outside this range) and are stubbed here instead of captured, the
# same pattern setup-env-helpers.sh already uses for die/print_ok.

load_setup_update_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { :; }'
        printf '%s\n' 'print_step() { :; }'
        printf '%s\n' 'print_warn() { :; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "$repo_root"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^# Backup\/restore may run on minimal hosts\./ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
