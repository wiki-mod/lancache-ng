#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's lancache_auto_update_should_proceed()
# in isolation. It has zero dependency on docker, systemd, or any other
# setup.sh internal (pure string/comparison logic), so it is extracted
# standalone rather than through the wider setup-env-helpers.sh range.

load_setup_auto_update_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^lancache_auto_update_should_proceed\(\)/ { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
