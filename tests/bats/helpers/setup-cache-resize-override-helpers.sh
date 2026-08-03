#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's lancache_ui_cache_max_gb_override_is_valid()
# in isolation. Same reasoning as setup-ui-channel-override-helpers.sh: this is
# pure string/integer-match logic with zero docker/systemd dependency, so it is
# extracted standalone rather than exercising the full cmd_converge_reconcile
# (which needs a live docker/systemd environment this bats suite cannot mock,
# per #827's two failed docker/tar-mocking attempts noted alongside the
# channel-override helper).

load_setup_cache_resize_override_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^lancache_ui_cache_max_gb_override_is_valid\(\)/ { capture = 1 }
        capture { print }
        capture && /^}/ { exit }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
