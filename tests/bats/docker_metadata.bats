#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Docker-free unit coverage for docker-metadata.sh.
# Why: single shared GHCR-repo derivation; no short SHAs.
# From: Issue #1095

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/docker-metadata.sh
    source "$repo_root/scripts/lib/docker-metadata.sh"
}

@test "dmeta_ghcr_repo: lowercases an already-lowercase GITHUB_REPOSITORY (no-op case)" {
    # What: proves an already-lowercase value passes through.
    # Why: confirms the no-op case doesn't mangle good input.
    # From: PR #1503
    export GITHUB_REPOSITORY="wiki-mod/lancache-ng"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}

@test "dmeta_ghcr_repo: lowercases a mixed-case GITHUB_REPOSITORY" {
    # What: proves a mixed-case GITHUB_REPOSITORY is lowercased.
    # Why: GHCR requires a lowercase repository path.
    # From: PR #1503
    export GITHUB_REPOSITORY="wiki-mod/LanCache-NG"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}
