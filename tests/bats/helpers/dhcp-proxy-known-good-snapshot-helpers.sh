#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the dhcp-proxy entrypoint's known-good-snapshot
# library and its `_dhcp_proxy_validate_snapshot_or_rollback` adapter
# function without executing the full entrypoint (env var requirements,
# /data/lancache-ui-settings.env sourcing, etc.).

load_dhcp_proxy_known_good_snapshot_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        awk '
            /^# BEGIN known-good-snapshot library/ { capture = 1; next }
            /^# END known-good-snapshot library/ { capture = 0 }
            capture { print }
            /^_dhcp_proxy_validate_snapshot_or_rollback\(\) \{/ { in_fn = 1 }
            in_fn { print }
            in_fn && /^\}$/ { exit }
        ' "$repo_root/services/dhcp-proxy/entrypoint.sh"
    } > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
