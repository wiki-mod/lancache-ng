#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: single declared derivation for the lowercased GHCR owner/repo
#   (dmeta_ghcr_repo) used across this project's GHCR tags.
# Why: every call site independently recomputing this value risks silent
#   divergence once one copy is edited and the others are not.
# From: Issue #1095 (G1) | PR #1503

# What: derives the lowercased GHCR owner/repo path from GITHUB_REPOSITORY,
#   for bash-reachable call sites only (a pure YAML-expression input has no
#   equivalent, since Actions expressions have no toLower()).
# Why: GHCR requires an all-lowercase path, but github.repository is not
#   guaranteed lowercase.
# From: Issue #1095 (G1) | PR #1503
dmeta_ghcr_repo() {
    printf '%s\n' "${GITHUB_REPOSITORY,,}"
}
