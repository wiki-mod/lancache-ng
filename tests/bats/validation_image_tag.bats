#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free unit coverage for scripts/lib/validation-image-tag.sh (#715) --
# the pure tag-resolution helpers that decide which image the deep full-setup
# validation suite tests. These mirror build-push.yml's inline staging-tag
# logic, so a drift between the two (e.g. the pr-<N>-sha-<short> format, or
# the base-channel mapping) is exactly the kind of regression that would
# silently make the deep gate test the wrong image; this keeps it honest in
# fast CI without needing a runner with a registry.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/validation-image-tag.sh
    source "$repo_root/scripts/lib/validation-image-tag.sh"
}

@test "base channel: master publishes latest" {
    run vit_base_channel_tag "master"
    [ "$status" -eq 0 ]
    [ "$output" = "latest" ]
}

@test "base channel: current_dev publishes nightly" {
    run vit_base_channel_tag "current_dev"
    [ "$status" -eq 0 ]
    [ "$output" = "nightly" ]
}

@test "base channel: an archived vX.Y.Z release branch has no live channel, falls back to latest" {
    # #825/#1141: archived vY.X.Z release branches no longer publish a live
    # channel (the old 'dev' channel mapping was retired), so they get the
    # same generic fallback as any other non-current_dev branch.
    run vit_base_channel_tag "v0.2.0"
    [ "$output" = "latest" ]
}

@test "base channel: anything else falls back to latest" {
    run vit_base_channel_tag "some-feature-branch"
    [ "$output" = "latest" ]
}

@test "pr-staging: same-repo non-Dependabot PR is eligible" {
    run vit_pr_staging_available "pull_request" "someuser" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng"
    [ "$output" = "true" ]
}

@test "pr-staging: Dependabot PR is not eligible" {
    run vit_pr_staging_available "pull_request" "dependabot[bot]" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng"
    [ "$output" = "false" ]
}

@test "pr-staging: fork PR is not eligible" {
    run vit_pr_staging_available "pull_request" "someuser" "fork/lancache-ng" "wiki-mod/lancache-ng"
    [ "$output" = "false" ]
}

@test "pr-staging: non-PR events are never eligible" {
    run vit_pr_staging_available "workflow_dispatch" "someuser" "" "wiki-mod/lancache-ng"
    [ "$output" = "false" ]
}

@test "resolve tag: eligible PR resolves to its own pr-<N>-sha-<short7> tag" {
    run vit_resolve_tag "pull_request" "master" "715" "abcdef0123456789" \
        "someuser" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng" ""
    [ "$output" = "pr-715-sha-abcdef0" ]
}

@test "resolve tag: Dependabot PR falls back to the base channel" {
    run vit_resolve_tag "pull_request" "master" "715" "abcdef0123456789" \
        "dependabot[bot]" "wiki-mod/lancache-ng" "wiki-mod/lancache-ng" ""
    [ "$output" = "latest" ]
}

@test "resolve tag: fork PR against an archived v0.2.0 branch falls back to latest" {
    # #825/#1141: v0.2.0 no longer has a live channel of its own (the old
    # 'dev' channel mapping was retired), so it falls to the same generic
    # fallback as any other non-current_dev branch.
    run vit_resolve_tag "pull_request" "v0.2.0" "715" "abcdef0123456789" \
        "someuser" "fork/lancache-ng" "wiki-mod/lancache-ng" ""
    [ "$output" = "latest" ]
}

@test "resolve tag: workflow_dispatch honours the operator's chosen tag" {
    run vit_resolve_tag "workflow_dispatch" "" "" "" "someuser" "" "wiki-mod/lancache-ng" "nightly"
    [ "$output" = "nightly" ]
}

@test "resolve tag: workflow_dispatch with no input defaults to nightly" {
    run vit_resolve_tag "workflow_dispatch" "" "" "" "someuser" "" "wiki-mod/lancache-ng" ""
    [ "$output" = "nightly" ]
}

@test "should-have-staging: a touched service is expected to have a tag" {
    run vit_service_should_have_staging_tag "proxy" "true" "false"
    [ "$output" = "true" ]
}

@test "should-have-staging: an untouched service is not" {
    run vit_service_should_have_staging_tag "dns" "false" "false"
    [ "$output" = "false" ]
}

@test "should-have-staging: a workflow change forces every service except build-tools" {
    run vit_service_should_have_staging_tag "ui" "false" "true"
    [ "$output" = "true" ]
}

@test "should-have-staging: build-tools keeps its narrower scoping even on a workflow change" {
    run vit_service_should_have_staging_tag "build-tools" "false" "true"
    [ "$output" = "false" ]
}

@test "build-push.yml calls this file's functions instead of reimplementing them (#822 pattern)" {
    workflow_file="$repo_root/.github/workflows/build-push.yml"
    [ -f "$workflow_file" ] || fail "build-push.yml not found"

    grep -q 'source "\$GITHUB_WORKSPACE/scripts/lib/validation-image-tag.sh"' "$workflow_file" \
        || fail "build-push.yml no longer sources scripts/lib/validation-image-tag.sh"
    grep -q 'vit_base_channel_tag' "$workflow_file" \
        || fail "build-push.yml no longer calls vit_base_channel_tag"
    grep -q 'vit_pr_staging_available' "$workflow_file" \
        || fail "build-push.yml no longer calls vit_pr_staging_available"
    grep -q 'vit_resolve_tag' "$workflow_file" \
        || fail "build-push.yml no longer calls vit_resolve_tag"
    grep -q 'vit_service_should_have_staging_tag' "$workflow_file" \
        || fail "build-push.yml no longer calls vit_service_should_have_staging_tag"

    # The old inline reimplementation used this exact conditional shape for
    # the base-channel mapping -- if it reappears (in either the pre-#825
    # master->nightly form or a naive post-#825 master->latest rewrite),
    # someone re-duplicated the logic instead of calling vit_base_channel_tag.
    ! grep -qF 'base_channel_tag=nightly' "$workflow_file" \
        || fail "build-push.yml appears to reimplement the base-channel mapping inline again"
    ! grep -qF 'base_channel_tag=latest' "$workflow_file" \
        || fail "build-push.yml appears to reimplement the base-channel mapping inline again"
}
