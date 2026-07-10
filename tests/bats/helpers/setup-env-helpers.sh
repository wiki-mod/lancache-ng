#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's .env migration helpers without executing
# setup.sh's install/update entrypoint.

load_setup_env_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { :; }'
        awk '
            /^_compose_parse_env_value\(\)/ { capture = 1 }
            /^# Update migrations/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
