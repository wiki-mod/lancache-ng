#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads scripts/untracked/select-utilities-image.sh's
# select_utilities_trusted_fallback_allowed() function in isolation, without
# sourcing or executing the rest of that script -- same technique and same
# reason as tests/bats/helpers/select-build-tools-image-helpers.sh (that
# script's own top-level lines have real side effects: GHCR pulls, buildx
# calls). The function itself is fully self-contained (plain string
# comparisons only), so capturing just its definition is safe.

load_select_utilities_image_functions() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^select_utilities_trusted_fallback_allowed\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}/ { capture = 0 }
    ' "$repo_root/scripts/untracked/select-utilities-image.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
