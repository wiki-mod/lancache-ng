#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Declares single source for lowercased GHCR repo path.
# Why: Prevents silent divergence from independent recomputation.
# From: Issue #1095 (G1) | PR #1503

# What: Derives lowercased GHCR repo path from GITHUB_REPOSITORY.
# Why: GHCR requires lowercase; github.repository may not be.
# From: Issue #1095 (G1) | PR #1503
dmeta_ghcr_repo() {
    printf '%s\n' "${GITHUB_REPOSITORY,,}"
}
