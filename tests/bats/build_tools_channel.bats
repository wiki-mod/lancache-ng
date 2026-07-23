#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for scripts/lib/build-tools-channel.sh's
# resolve_build_tools_channel (issue #1035, short-term "option 2"): the
# build-tools *tooling*-image channel a given target ref resolves to. Tested
# directly as a pure function with zero I/O (no docker pull/smoke-test
# involved) -- the same reasoning setup.sh's lancache_stack_pointer_channel_for
# is tested this way in tests/bats/setup_channel_stable_nightly.bats, and the
# same "sourced directly, no top-level execution" shape as
# scripts/lib/ghcr-retry.sh (tests/bats/ghcr_retry.bats).
#
# Before #1035's fix, `master` resolved to `nightly` (renamed from `edge` by
# #1056), a channel nothing actively publishes -- the real registry-pull
# smoke-test path stays covered by CI itself (every workflow job that
# actually invokes scripts/select-build-tools-image.sh), not re-mocked here.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/build-tools-channel.sh
    source "$repo_root/scripts/lib/build-tools-channel.sh"
}

@test "resolve_build_tools_channel maps master to the actively-maintained dev channel, not the unwritten nightly channel" {
    run resolve_build_tools_channel "master"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "resolve_build_tools_channel maps v0.2.0 to dev" {
    run resolve_build_tools_channel "v0.2.0"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "resolve_build_tools_channel maps current_dev to dev" {
    run resolve_build_tools_channel "current_dev"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "resolve_build_tools_channel maps an arbitrary feature branch ref to dev" {
    run resolve_build_tools_channel "claude/issue1035-build-tools-channel"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "resolve_build_tools_channel maps an empty ref to dev, matching the script's own GITHUB_BASE_REF/GITHUB_REF_NAME fallback-to-empty case" {
    run resolve_build_tools_channel ""
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}
