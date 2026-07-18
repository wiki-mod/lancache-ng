#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the real setup.sh create-logs-for-issue subsystem
# (#762) -- logbundle_secret_env_keys, logbundle_key_looks_like_secret,
# logbundle_collect_secret_values, logbundle_redact_stream,
# logbundle_redact_env_file, logbundle_select_compressor,
# logbundle_named_volume_listing, logbundle_host_path_listing, and
# cmd_create_logs_for_issue itself -- without executing setup.sh's
# interactive install/update entrypoint or its top-level CLI dispatcher.
#
# The captured range starts at is_valid_ipv4() (same start point every other
# setup.sh helper in this directory uses) and ends right before
# cmd_update_ip(), the first helper defined after cmd_create_logs_for_issue()
# in setup.sh. This is a wider slice than setup-backup-restore-helpers.sh's
# (which stops at print_usage()) because the create-logs-for-issue
# functions live further down the file, after print_usage/print_command_help
# and cmd_update/cmd_debug -- all of which are included incidentally. That
# extra content is pure function definitions and heredoc bodies (`cat
# <<EOF ... EOF` help text) with no top-level executable statements, the
# same property setup-backup-restore-helpers.sh's own comment already
# documents for its narrower range, just verified over the wider span too.
#
# A few globals/helpers this range depends on are defined earlier in setup.sh
# (outside the captured range) and are stubbed here instead of captured, the
# same pattern every other setup.sh bats helper in this directory uses for
# die/print_ok/print_step/print_warn.
#
# Tests that exercise Docker-dependent behavior (logbundle_named_volume_listing,
# cmd_create_logs_for_issue's docker compose ps/config/logs collection) must
# provide their own `docker` stub/mock as a shell function -- this helper does
# not fake Docker itself, since the right mock shape differs per test.

load_setup_create_logs_for_issue_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        printf '%s\n' 'print_ok() { printf "OK: %s\n" "$*"; }'
        printf '%s\n' 'print_step() { printf "STEP: %s\n" "$*"; }'
        printf '%s\n' 'print_warn() { printf "WARN: %s\n" "$*" >&2; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "$repo_root"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^cmd_update_ip\(\)/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
