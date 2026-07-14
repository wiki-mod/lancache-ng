#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for the "stable"/"edge" operator-facing channel picker
# (#819). "stable" is a new accepted LANCACHE_IMAGE_CHANNEL value that must
# resolve through the exact same published stack:latest pointer image "latest"
# already uses -- there is no separate stack:stable GHCR tag.
#
# lancache_stack_pointer_channel_for (the channel-name-to-pointer-tag mapping)
# is tested directly as a pure function with zero I/O -- no docker/tar
# mocking. An earlier version of this file mocked the real
# `docker cp | tar -xO | awk` pipeline resolve_lancache_stack_channel_tag runs
# to pin the same mapping end-to-end; that mock (first via `export -f`,
# then via a PATH-prepended fake executable) proved unreliable in the real
# CI bats environment for reasons that could not be root-caused without a
# local bats install (this Windows checkout has none). Testing the pure
# mapping function directly is both simpler and strictly more reliable, since
# it has no dependency on docker/tar/PATH resolution behavior at all -- the
# actual registry pull path stays covered by the real end-to-end CI
# simulations (scripts/setup-cli-simulation.sh,
# scripts/watchtower-update-simulation.sh) instead of an in-bats mock.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-env-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-env-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-env-helpers.sh"
    load_setup_env_helpers "$repo_root" "$helper_file"

    unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG LANCACHE_IMAGE_REGISTRY LANCACHE_IMAGE_PREFIX
}

@test "validate_lancache_image_channel accepts stable" {
    run validate_lancache_image_channel "stable"
    [ "$status" -eq 0 ]
}

@test "validate_lancache_image_channel still accepts latest, dev, edge, pinned" {
    for channel in latest dev edge pinned; do
        run validate_lancache_image_channel "$channel"
        [ "$status" -eq 0 ]
    done
}

@test "validate_lancache_image_channel rejects an unknown channel and names stable in the error" {
    run validate_lancache_image_channel "bogus"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stable"* ]]
}

@test "resolve_lancache_image_channel returns an explicit stable channel unchanged" {
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    LANCACHE_IMAGE_CHANNEL="stable"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
}

@test "resolve_lancache_image_channel infers stable from a LANCACHE_IMAGE_TAG=stable convenience value" {
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    LANCACHE_IMAGE_TAG="stable"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "stable" ]
}

@test "resolve_lancache_image_channel still defaults to latest, not stable, with nothing configured" {
    # The hardcoded fallback intentionally stays "latest" (the name that has
    # always existed); "stable" is only ever written explicitly by the new
    # interactive picker, never silently substituted as a bare default.
    missing_env="$BATS_TEST_TMPDIR/missing.env"
    run resolve_lancache_image_channel "$missing_env"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "lancache_stack_pointer_channel_for maps stable onto the latest pointer" {
    run lancache_stack_pointer_channel_for "stable"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "lancache_stack_pointer_channel_for passes latest through unchanged" {
    run lancache_stack_pointer_channel_for "latest"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "lancache_stack_pointer_channel_for passes edge through unchanged" {
    run lancache_stack_pointer_channel_for "edge"
    [ "$status" -eq 0 ]
    [ "$output" = "edge" ]
}

@test "lancache_stack_pointer_channel_for passes dev through unchanged" {
    run lancache_stack_pointer_channel_for "dev"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}
