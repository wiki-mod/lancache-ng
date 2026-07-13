#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads restore_clear_stale_env_local_if_unarchived() (the
# helper cmd_restore calls to keep a stale, un-restored .env.local from
# shadowing a just-restored .env) without executing setup.sh's interactive
# install/update entrypoint or its top-level CLI dispatcher.
#
# The captured range is a single function definition
# (restore_clear_stale_env_local_if_unarchived() to just before cmd_restore()
# right after it), matching the extraction pattern setup-update-helpers.sh
# already uses. The function only depends on print_warn (stubbed here, same
# as setup-update-helpers.sh does for die/print_ok/print_step) plus
# core-utils (mv, date, basename), so nothing else from setup.sh needs to be
# captured.

load_setup_restore_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'print_warn() { :; }'
        awk '
            /^restore_clear_stale_env_local_if_unarchived\(\)/ { capture = 1 }
            /^cmd_restore\(\)/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
