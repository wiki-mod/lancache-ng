#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Bats helper that loads scripts/tracked/select-build-tools-image.sh's
# select_build_tools_trusted_fallback_allowed() function in isolation,
# without sourcing or executing the rest of that script -- which has real
# side effects from its very first non-comment line (sources
# scripts/lib/ghcr-retry.sh/build-tools-channel.sh/docker-buildx-retry.sh,
# resolves a channel, attempts GHCR pulls/logins/buildx calls). The function
# itself is fully self-contained (plain string comparisons only, no calls
# into those sourced libraries), so capturing just its own definition is
# both safe and sufficient to test the case-insensitive trust-boundary
# decision this file's own test cases exist for (issue #842 PR #1360).

load_select_build_tools_image_functions() {
    local repo_root="$1" helper_file="$2"

    awk '
        /^select_build_tools_trusted_fallback_allowed\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}/ { capture = 0 }
    ' "$repo_root/scripts/tracked/select-build-tools-image.sh" > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
