#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Docker-free unit coverage for scripts/lib/docker-metadata.sh.
# Why: this is the single shared derivation every short-SHA/GHCR-repo call
#   site across build-push.yml, build-tools.yml, and the staging-tag/
#   ancestor-fallback libraries now reads from.
# From: Issue #1095 (G1, G2) | PR #1503

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/docker-metadata.sh
    source "$repo_root/scripts/lib/docker-metadata.sh"
}

fail() {
    echo "$1" >&2
    return 1
}

@test "dmeta_short_sha: truncates to DOCKER_METADATA_SHORT_SHA_LENGTH when set" {
    # What: proves the declared length is honoured.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="7"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: falls back to length 7 when the env var is unset" {
    # What: proves the documented default (7) applies when unset.
    # From: PR #1503
    unset DOCKER_METADATA_SHORT_SHA_LENGTH
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: falls back to length 7 when the env var is empty" {
    # What: proves the documented default (7) applies when empty, not unset.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH=""
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: honours a widened declared length" {
    # What: proves a length change in the declared env var takes effect
    #   through this one function, with no call site to touch.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="12"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef012345" ]
}

@test "dmeta_short_sha: a SHA shorter than the declared length returns the whole SHA" {
    # What: proves bash's own substring semantics apply (no padding/error).
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="7"
    run dmeta_short_sha "abc"
    [ "$status" -eq 0 ]
    [ "$output" = "abc" ]
}

@test "dmeta_short_sha: fails closed on a non-numeric declared length" {
    # What: proves a non-numeric length is rejected, not silently coerced.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="seven"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha: fails closed on a zero declared length" {
    # What: proves a zero length is rejected.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="0"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha: fails closed on a negative declared length" {
    # What: proves a negative length is rejected.
    # From: PR #1503
    export DOCKER_METADATA_SHORT_SHA_LENGTH="-1"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha real caller shape: build-push-hosted-fallback.yml's short-sha step aborts under set -euo pipefail on a malformed length, before writing value=" {
    # What: reproduces the real caller's exact step shape and shell options.
    # Why: a `set -e`-dependent construct must be proven under the real
    #   caller's own option set, not only via a direct call in isolation
    #   (Rule-Ref: AG-VAL-030).
    # From: PR #1503
    local fake_output
    fake_output="$(mktemp)"
    run bash -c '
        set -euo pipefail
        source "$1"
        export DOCKER_METADATA_SHORT_SHA_LENGTH="not-a-number"
        export GITHUB_SHA="abcdef0123456789"
        export GITHUB_OUTPUT="$2"
        short_sha="$(dmeta_short_sha "$GITHUB_SHA")"
        printf "value=%s\n" "$short_sha" >> "$GITHUB_OUTPUT"
    ' _ "$repo_root/scripts/lib/docker-metadata.sh" "$fake_output"

    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]] || fail "did not surface dmeta_short_sha's own fail-closed message: $output"
    [ ! -s "$fake_output" ] || fail "GITHUB_OUTPUT was written to despite the malformed length -- the bare assignment's set -e propagation did not abort the step before the printf line: $(cat "$fake_output")"

    rm -f "$fake_output"
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
