#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads the ntp entrypoint's Admin-UI-settings sourcing
# function (`_ntp_source_ui_settings`) directly from
# services/ntp/entrypoint.sh, without executing the rest of the entrypoint
# (the fail-closed empty-upstream-list check, config rendering/validation,
# the final `exec chronyd`) and without touching the real, hardcoded
# /data/lancache-ui-settings.env path.

load_ntp_ui_settings_sourcing_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^_ntp_source_ui_settings\(\) \{/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn = 0 }
    ' "$repo_root/services/ntp/entrypoint.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
