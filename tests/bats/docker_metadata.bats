#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Docker-free unit coverage for scripts/lib/docker-metadata.sh.
# Why: this is the single shared derivation every GHCR-repo call site across
#   build-push.yml and build-tools.yml now reads from. dmeta_short_sha() and
#   its own tests were removed here: short SHAs are banned outright, not
#   merely truncated by a single declared derivation.
# From: Issue #1095 (G1, G2)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/docker-metadata.sh
    source "$repo_root/scripts/lib/docker-metadata.sh"
}

@test "dmeta_ghcr_repo: lowercases an already-lowercase GITHUB_REPOSITORY (no-op case)" {
    # What: proves an already-lowercase value passes through unchanged.
    # From: PR #1503
    export GITHUB_REPOSITORY="wiki-mod/lancache-ng"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}

@test "dmeta_ghcr_repo: lowercases a mixed-case GITHUB_REPOSITORY" {
    # What: proves a mixed-case GITHUB_REPOSITORY is lowercased.
    # From: PR #1503
    export GITHUB_REPOSITORY="wiki-mod/LanCache-NG"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}
