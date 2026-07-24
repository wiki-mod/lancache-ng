#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for lancache_auto_update_should_proceed() (#819) -- the
# pure decision that gates cmd_auto_update's scheduled systemd-timer entry
# point: does this tick actually warrant a pull-and-restart, or is it a
# no-op? Kept pure and dependency-free specifically so this decision is
# testable without mocking docker (see #827's own docker/tar-mocking
# lessons: two different mocking techniques both proved unreliable in this
# CI bats environment, so the resolution logic that touches docker
# (resolve_lancache_image_channel, resolve_lancache_stack_channel_tag)
# deliberately stays out of this function entirely).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-auto-update-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-auto-update-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-auto-update-helpers.sh"
    load_setup_auto_update_helpers "$repo_root" "$helper_file"
}

@test "skips when AUTO_UPDATE_ENABLED is not 1" {
    run lancache_auto_update_should_proceed "0" "nightly" "sha-new" "sha-old"
    [ "$status" -eq 1 ]
    [[ "$output" == skip:* ]]
    [[ "$output" == *"AUTO_UPDATE_ENABLED"* ]]
}

@test "skips when AUTO_UPDATE_ENABLED is empty" {
    run lancache_auto_update_should_proceed "" "nightly" "sha-new" "sha-old"
    [ "$status" -eq 1 ]
}

@test "skips a pinned channel even when enabled" {
    # pinned tracks one fixed tag, not a moving channel -- there is nothing
    # for a scheduled tick to detect, regardless of AUTO_UPDATE_ENABLED.
    run lancache_auto_update_should_proceed "1" "pinned" "sha-new" "sha-old"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pinned"* ]]
}

@test "skips when the channel has not moved" {
    run lancache_auto_update_should_proceed "1" "nightly" "sha-abc" "sha-abc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already at sha-abc"* ]]
}

@test "proceeds when enabled, not pinned, and the channel moved" {
    run lancache_auto_update_should_proceed "1" "nightly" "sha-new" "sha-old"
    [ "$status" -eq 0 ]
    [[ "$output" == proceed:* ]]
    [[ "$output" == *"sha-old -> sha-new"* ]]
}

@test "proceeds for the stable channel exactly like any other moving channel" {
    run lancache_auto_update_should_proceed "1" "stable" "sha-new" "sha-old"
    [ "$status" -eq 0 ]
}

@test "disabled takes priority over a moved channel in the reported reason" {
    # Both "disabled" and "pinned" could independently justify skipping;
    # AUTO_UPDATE_ENABLED is checked first, so its reason is what's reported.
    run lancache_auto_update_should_proceed "0" "pinned" "sha-new" "sha-old"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AUTO_UPDATE_ENABLED"* ]]
}
