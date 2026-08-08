#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads the dhcp-proxy entrypoint's Admin-UI-settings
# sourcing function (`_dhcp_proxy_source_ui_settings`) directly from
# services/dhcp-proxy/entrypoint.sh, without executing the rest of the
# entrypoint (env var requirements, dnsmasq --test, known-good-snapshot
# rollback, etc.) and without touching the real, hardcoded
# /data/lancache-ui-settings.env path.

load_dhcp_proxy_ui_settings_sourcing_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_dhcp_proxy_source_ui_settings\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "$repo_root/services/dhcp-proxy/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
