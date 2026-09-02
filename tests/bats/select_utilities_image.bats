#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free unit coverage for scripts/untracked/select-utilities-image.sh's
# select_utilities_trusted_fallback_allowed() -- the same case-insensitive
# same-repo-PR trust boundary as select-build-tools-image.sh's own
# select_build_tools_trusted_fallback_allowed() (issue #842 PR #1360), gating
# whether a pull_request event may trigger a branch-local fallback build of
# services/utilities's own Dockerfile.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=helpers/select-utilities-image-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/select-utilities-image-helpers.sh"
    load_select_utilities_image_functions "$repo_root" "$BATS_TEST_TMPDIR/select-utilities-image-functions.sh"
}

@test "trusted fallback: same-repo pull_request is trusted" {
    run select_utilities_trusted_fallback_allowed "pull_request" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: fork pull_request is not trusted" {
    run select_utilities_trusted_fallback_allowed "pull_request" "fork/lancache-ng" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}

@test "trusted fallback: empty head_repository is not trusted" {
    run select_utilities_trusted_fallback_allowed "pull_request" "" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}

@test "trusted fallback: a push event is always trusted regardless of repo values" {
    run select_utilities_trusted_fallback_allowed "push" "" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: same-repo pull_request stays trusted when head/base disagree only in casing" {
    run select_utilities_trusted_fallback_allowed "pull_request" "wiki-mod/LanCache-NG" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: casing mismatch does not launder an actual fork PR into trust" {
    run select_utilities_trusted_fallback_allowed "pull_request" "fork/LanCache-NG" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}
