#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's lancache_ui_dhcp_mode_override_is_valid()
# in isolation. Zero dependency on docker/systemd (pure string-match logic),
# same reasoning as setup-ui-channel-override-helpers.sh, which this mirrors:
# extracted standalone so this gate is directly testable without mocking
# docker.

load_setup_ui_dhcp_mode_override_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^lancache_ui_dhcp_mode_override_is_valid\(\)/ { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
