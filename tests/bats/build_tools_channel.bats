#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression tests for scripts/lib/build-tools-channel.sh's
# resolve_build_tools_channel (issue #1153, follow-through of #1142/#825): the
# build-tools *tooling*-image channel a given target ref resolves to. Tested
# directly as a pure function with zero I/O (no docker pull/smoke-test
# involved) -- the same reasoning setup.sh's lancache_stack_pointer_channel_for
# is tested this way in tests/bats/setup_channel_stable_nightly.bats, and the
# same "sourced directly, no top-level execution" shape as
# scripts/lib/ghcr-retry.sh (tests/bats/ghcr_retry.bats).
#
# Before #1153's fix, every ref resolved to `dev` (issue #1035's short-term
# fix) -- a channel #1142 retired outright, making every job that calls
# scripts/select-build-tools-image.sh with BUILD_TOOLS_REQUIRE_PUBLISHED=true
# fail with a hard "denied" pull. The real registry-pull smoke-test path stays
# covered by CI itself (every workflow job that actually invokes
# scripts/select-build-tools-image.sh), not re-mocked here.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/lib/build-tools-channel.sh
    source "$repo_root/scripts/lib/build-tools-channel.sh"
}

@test "resolve_build_tools_channel maps master to the actively-maintained latest channel" {
    run resolve_build_tools_channel "master"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "resolve_build_tools_channel maps v0.2.0 to nightly" {
    run resolve_build_tools_channel "v0.2.0"
    [ "$status" -eq 0 ]
    [ "$output" = "nightly" ]
}

@test "resolve_build_tools_channel maps current_dev to the actively-maintained nightly channel" {
    run resolve_build_tools_channel "current_dev"
    [ "$status" -eq 0 ]
    [ "$output" = "nightly" ]
}

@test "resolve_build_tools_channel maps an arbitrary feature branch ref to nightly" {
    run resolve_build_tools_channel "claude/issue1035-build-tools-channel"
    [ "$status" -eq 0 ]
    [ "$output" = "nightly" ]
}

@test "resolve_build_tools_channel maps an empty ref to nightly, matching the script's own GITHUB_BASE_REF/GITHUB_REF_NAME fallback-to-empty case" {
    run resolve_build_tools_channel ""
    [ "$status" -eq 0 ]
    [ "$output" = "nightly" ]
}
