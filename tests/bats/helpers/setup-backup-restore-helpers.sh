#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the real setup.sh backup/restore subsystem --
# compose_stack_stop/start/running, compose_project_name,
# compose_cache_volume_name, compose_volume_names, backup_compose_volumes,
# restore_compose_volumes, guard_restore_shared_project_volumes,
# backup_manifest, cmd_backup, cmd_restore, and
# pause/resume_lancache_convergence_for_update -- without executing setup.sh's
# interactive install/update entrypoint or its top-level CLI dispatcher.
#
# The captured range starts at is_valid_ipv4() (same start point
# setup-update-helpers.sh already uses) and ends right before print_usage(),
# the first helper defined after cmd_restore() in setup.sh. That range is
# pure function/variable definitions with no top-level executable
# statements (verified by scanning for non-indented, non-function-def,
# non-comment lines), so sourcing it has no side effects beyond defining
# functions -- same property setup-update-helpers.sh already relies on, just
# a wider slice of the same block.
#
# A few globals/helpers this range depends on are defined earlier in setup.sh
# (outside the captured range) and are stubbed here instead of captured, the
# same pattern setup-update-helpers.sh and setup-env-helpers.sh already use
# for die/print_ok/print_step/print_warn.
#
# Tests that exercise Docker-dependent behavior (compose_volume_names,
# backup_compose_volumes, restore_compose_volumes,
# guard_restore_shared_project_volumes) must provide their own `docker`
# stub/mock on PATH or as a shell function -- this helper does not fake
# Docker itself, since the right mock shape differs per test.

load_setup_backup_restore_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { printf "OK: %s\n" "$*"; }'
        printf '%s\n' 'print_step() { printf "STEP: %s\n" "$*"; }'
        printf '%s\n' 'print_warn() { printf "WARN: %s\n" "$*" >&2; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "$repo_root"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^print_usage\(\)/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
