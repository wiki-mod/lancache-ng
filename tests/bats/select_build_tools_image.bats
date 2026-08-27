#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free unit coverage for scripts/tracked/select-build-tools-image.sh's
# select_build_tools_trusted_fallback_allowed() -- the trust-boundary
# decision that gates whether a pull_request event is allowed to trigger a
# branch-local fallback build of tools/build-tools's own Dockerfile (a real
# supply-chain risk if an untrusted fork PR could reach it). See that
# function's own header comment for the full case-insensitivity incident
# (issue #842 PR #1360, 2026-08-01) this file's regression tests cover.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=helpers/select-build-tools-image-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/select-build-tools-image-helpers.sh"
    load_select_build_tools_image_functions "$repo_root" "$BATS_TEST_TMPDIR/select-build-tools-image-functions.sh"
}

@test "trusted fallback: same-repo pull_request is trusted" {
    run select_build_tools_trusted_fallback_allowed "pull_request" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: fork pull_request is not trusted" {
    run select_build_tools_trusted_fallback_allowed "pull_request" "fork/lancache-ng" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}

@test "trusted fallback: empty head_repository is not trusted" {
    run select_build_tools_trusted_fallback_allowed "pull_request" "" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}

@test "trusted fallback: a push event is always trusted regardless of repo values" {
    run select_build_tools_trusted_fallback_allowed "push" "" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: same-repo pull_request stays trusted when head/base disagree only in casing" {
    # Regression test for issue #842 PR #1360 (2026-08-01): this repository's
    # own rename to LanCache-NG produced exactly this real mismatch -- one
    # context value resolved to "wiki-mod/LanCache-NG" while the other still
    # resolved to "wiki-mod/lancache-ng" in the same job. Before the `${x,,}`
    # fix, this exact input combination returned non-trusted, silently
    # misclassifying a genuine same-repo PR as an untrusted fork PR and
    # disabling its fallback build entirely -- confirmed by temporarily
    # reverting the fix locally and re-running this test, which then failed.
    run select_build_tools_trusted_fallback_allowed "pull_request" "wiki-mod/LanCache-NG" "wiki-mod/lancache-ng"
    [ "$status" -eq 0 ]
}

@test "trusted fallback: casing mismatch does not launder an actual fork PR into trust" {
    # Negative control for the fix above: lowercasing both sides must not
    # make two genuinely different repositories compare equal.
    run select_build_tools_trusted_fallback_allowed "pull_request" "fork/LanCache-NG" "wiki-mod/lancache-ng"
    [ "$status" -ne 0 ]
}
