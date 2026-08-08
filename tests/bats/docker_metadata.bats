#!/usr/bin/env bats
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
    [ "$output" = "abcdef0123456" ]
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
