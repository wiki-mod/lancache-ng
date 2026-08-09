#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's REAL pxe_boot_pointer_answers_are_complete()
# and is_valid_dhcp_proxy_boot_filename() via awk extraction, mirroring
# tests/bats/helpers/setup-dhcp-helpers.sh's established technique for this
# file. setup.sh cannot be sourced directly (it is a flat procedural script
# that runs its install flow immediately), so tests drive the real named
# functions extracted from it instead of a hand-copied duplicate.

load_setup_dhcp_proxy_pxe_wizard_helpers() {
    local repo_root="$1" helper_file="$2"

    awk '
        function want(name) {
            return name == "pxe_boot_pointer_answers_are_complete" \
                || name == "is_valid_dhcp_proxy_boot_filename"
        }
        !capture && /^[a-z0-9_]+\(\) \{/ {
            fname = $0
            sub(/\(\).*/, "", fname)
            if (want(fname)) { capture = 1; print; next }
        }
        capture {
            print
            if ($0 == "}") { capture = 0 }
        }
    ' "$repo_root/setup.sh" > "$helper_file"

    # shellcheck disable=SC1090
    source "$helper_file"
}
