#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# ShellSpec helper that loads setup.sh .env parsing and validation helpers
# without executing setup.sh's install/update entrypoint.

load_setup_env_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
        awk '
            /^_compose_parse_env_value\(\)/ { capture = 1 }
            /^set_env_key\(\)/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
