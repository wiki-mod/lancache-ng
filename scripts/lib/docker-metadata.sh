#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: single declared derivation for the short commit SHA (dmeta_short_sha)
#   and the lowercased GHCR owner/repo (dmeta_ghcr_repo) used across this
#   project's GHCR tags.
# Why: every call site independently recomputing either value risks silent
#   divergence once one copy is edited and the others are not.
# From: Issue #1095 (G1, G2) | PR #1503

# What: derives the short SHA using DOCKER_METADATA_SHORT_SHA_LENGTH (falls
#   back to 7 if unset/empty); fails closed on a non-positive-integer length.
# Why: a silently-wrong truncation would produce a GHCR tag that looks
#   plausible while actually identifying a different commit.
# From: Issue #1095 (G2) | PR #1503
dmeta_short_sha() {
    local full_sha="$1"
    local length="${DOCKER_METADATA_SHORT_SHA_LENGTH:-7}"

    if ! [[ "$length" =~ ^[0-9]+$ ]] || [ "$length" -lt 1 ]; then
        echo "::error::DOCKER_METADATA_SHORT_SHA_LENGTH must be a positive integer, got '${length}'." >&2
        return 1
    fi

    # What: forces base-10 interpretation of $length before the slice.
    # Why: a leading-zero value (e.g. "08") is otherwise read as octal by
    #   bash's arithmetic-context substring slice, aborting on "08"/"09".
    # From: Issue #1095 (G2) | PR #1503
    length=$((10#${length}))

    printf '%s\n' "${full_sha:0:length}"
}

# What: derives the lowercased GHCR owner/repo path from GITHUB_REPOSITORY,
#   for bash-reachable call sites only (a pure YAML-expression input has no
#   equivalent, since Actions expressions have no toLower()).
# Why: GHCR requires an all-lowercase path, but github.repository is not
#   guaranteed lowercase.
# From: Issue #1095 (G1) | PR #1503
dmeta_ghcr_repo() {
    printf '%s\n' "${GITHUB_REPOSITORY,,}"
}
