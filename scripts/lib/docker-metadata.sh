#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Single source of truth for deriving the short (truncated) commit SHA used
# in human-readable GHCR tags (sha-<short>, sha-<short>-amd64/-arm64,
# pr-<N>-sha-<short>, and the staging-ancestor-fallback candidate tags).
# GITHUB_SHA (the full, untruncated commit SHA) stays this project's one
# canonical identity reference for every ancestry/diff/revision-label check
# (issue #1095 gap G1/G2's own "matching numbers" principle: a value that
# identifies one specific build must stay the exact same value everywhere
# that build is referenced, not a value that different call sites are each
# free to recompute their own way) -- this helper exists ONLY to derive the
# shorter, human-readable tag suffix from it, at exactly one declared length,
# so a future change to that length (e.g. widening past 7 hex characters to
# reduce GHCR tag collision risk as this repository's commit count grows)
# takes effect everywhere by construction instead of needing many
# independent call sites to be found and edited in sync by hand.
#
# Before this file existed, issue #1095's G2 gap-map finding recorded eight
# independent `${VAR::7}`/`${VAR:0:7}` hardcodes inside
# .github/workflows/build-push.yml alone, plus further, previously
# unflagged instances discovered while fixing G2 in
# .github/workflows/build-tools.yml, .github/workflows/build-push-hosted-
# fallback.yml, scripts/lib/validation-image-tag.sh, and
# scripts/lib/staging-ancestor-fallback.sh -- every one computing the
# identical 7-character truncation independently, with no single site any of
# them actually read. That divergence risk is exactly what this shared
# function removes: every call site now reads the same computed value
# instead of repeating the literal length.
#
# The length is read from DOCKER_METADATA_SHORT_SHA_LENGTH, the workflow-level
# `env:` key .github/workflows/build-push.yml (and the other workflow files
# that call into this library) already declare -- this function does not
# hardcode that length itself, it hardcodes only the FALLBACK used if the
# variable is genuinely unset (e.g. a bats test, or a local developer
# invocation outside any workflow's own env context), matching this
# project's long-standing established length of 7.

# Derive the short SHA from a full commit SHA using
# DOCKER_METADATA_SHORT_SHA_LENGTH (falls back to 7 if unset/empty). Fails
# closed (non-zero exit, ::error:: annotation) rather than silently
# truncating to a wrong length if that variable holds something other than a
# positive integer -- a malformed length is a configuration bug, not a
# recoverable input, and a GHCR tag built from a silently-wrong truncation
# would look plausible while actually being a different, colliding value.
# Echoes the truncated value on success.
dmeta_short_sha() {
    local full_sha="$1"
    local length="${DOCKER_METADATA_SHORT_SHA_LENGTH:-7}"

    if ! [[ "$length" =~ ^[0-9]+$ ]] || [ "$length" -lt 1 ]; then
        echo "::error::DOCKER_METADATA_SHORT_SHA_LENGTH must be a positive integer, got '${length}'." >&2
        return 1
    fi

    # Force base-10 interpretation: a decimal literal with a leading zero
    # (e.g. "08") is otherwise read as octal by bash's arithmetic-context
    # substring slice below, and "08"/"09" are not valid octal digits at
    # all, aborting the whole step with "value too great for base" instead
    # of returning the intended 8/9-character short SHA.
    length=$((10#${length}))

    printf '%s\n' "${full_sha:0:length}"
}

# Issue #1095 gap G1: the owner/repo segment of every ghcr.io/<repo>/<service>
# path this workflow constructs in shell. GHCR (and the OCI distribution spec
# generally) requires an all-lowercase repository path -- `github.repository`
# itself is NOT guaranteed lowercase (confirmed live during this project's own
# rename to LanCache-NG, when one GitHub Actions context still resolved the
# old `wiki-mod/lancache-ng` casing while another had already picked up
# `wiki-mod/LanCache-NG` -- see scripts/lib/validation-image-tag.sh's
# vit_pr_staging_available() for the full incident). Rather than passing
# `github.repository` into yet another `REPOSITORY: ${{ github.repository }}`
# step env (as dozens of call sites previously did, each trusting it was
# already correctly cased), every bash call site now reads this one function,
# which lowercases $GITHUB_REPOSITORY itself. GITHUB_REPOSITORY is a default
# environment variable GitHub Actions sets in every job/step automatically --
# https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
# -- so no per-step `env:` passthrough, and no cross-job `needs:`/output
# wiring, is required to reach it.
#
# NON-EXPANSION NOTE: this function covers bash-reachable GHCR-path
# construction only. A pure YAML expression context (a `subject-name:`,
# `image-ref:`, or `images:` action input that cannot run bash) has no
# equivalent -- GitHub Actions expressions have no toLower() function at all
# (confirmed against GitHub's own expressions documentation) -- so those
# sites still read the live github.repository context directly and are a
# deliberately separate, tracked follow-up (see the introducing PR's Scope
# Boundaries section), not silently left inconsistent with this function by
# oversight.
dmeta_ghcr_repo() {
    printf '%s\n' "${GITHUB_REPOSITORY,,}"
}
