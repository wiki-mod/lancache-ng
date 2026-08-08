#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free unit coverage for scripts/lib/docker-metadata.sh (issue #1095
# gap G2) -- the single shared derivation every short-SHA call site in
# build-push.yml, build-tools.yml, build-push-hosted-fallback.yml, and the
# staging-tag/ancestor-fallback helper libraries now reads from, instead of
# each independently hardcoding the truncation length.

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
    export DOCKER_METADATA_SHORT_SHA_LENGTH="7"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: falls back to length 7 when the env var is unset" {
    unset DOCKER_METADATA_SHORT_SHA_LENGTH
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: falls back to length 7 when the env var is empty" {
    export DOCKER_METADATA_SHORT_SHA_LENGTH=""
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef0" ]
}

@test "dmeta_short_sha: honours a widened declared length" {
    # Proves the whole point of centralizing this: widening the length in
    # one place (the workflow's own env var) takes effect through this
    # single function without touching any call site.
    export DOCKER_METADATA_SHORT_SHA_LENGTH="12"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef012345" ]
}

@test "dmeta_short_sha: a SHA shorter than the declared length returns the whole SHA" {
    export DOCKER_METADATA_SHORT_SHA_LENGTH="7"
    run dmeta_short_sha "abc"
    [ "$status" -eq 0 ]
    [ "$output" = "abc" ]
}

@test "dmeta_short_sha: fails closed on a non-numeric declared length" {
    export DOCKER_METADATA_SHORT_SHA_LENGTH="seven"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha: fails closed on a zero declared length" {
    export DOCKER_METADATA_SHORT_SHA_LENGTH="0"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha: fails closed on a negative declared length" {
    export DOCKER_METADATA_SHORT_SHA_LENGTH="-1"
    run dmeta_short_sha "abcdef0123456789"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}

@test "dmeta_short_sha real caller shape: build-push-hosted-fallback.yml's short-sha step aborts under set -euo pipefail on a malformed length, before writing value=" {
    # Reproduces build-push-hosted-fallback.yml's "Resolve short commit SHA"
    # step verbatim (bare assignment, then a separate printf into
    # GITHUB_OUTPUT) under the exact shell options that real step runs with,
    # per AG-VAL-030: a `set -e`-dependent construct must be proven under the
    # real caller's own option set, not only via a direct call to the helper
    # function in isolation (the tests above already cover that).
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
    export GITHUB_REPOSITORY="wiki-mod/lancache-ng"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}

@test "dmeta_ghcr_repo: lowercases a mixed-case GITHUB_REPOSITORY" {
    # Reproduces the real 2026 rename incident this function exists to
    # prevent a recurrence of: one GitHub Actions context resolved the old
    # casing while another had already picked up the new one.
    export GITHUB_REPOSITORY="wiki-mod/LanCache-NG"
    run dmeta_ghcr_repo
    [ "$status" -eq 0 ]
    [ "$output" = "wiki-mod/lancache-ng" ]
}
