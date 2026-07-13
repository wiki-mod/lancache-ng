#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/plan-deep-validation.sh (#715): the glue that turns a
# triggering event into the deep suite's plan (image_tag / pr_staging_available
# / should_run / per-service flags) written to $GITHUB_OUTPUT. The tag maths
# themselves are covered by validation_image_tag.bats and the path rules by
# detect_full_setup_changes.bats; this asserts the two are wired together
# correctly for both a manual dispatch and a real PR.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/plan-deep-validation.sh"
    out="$BATS_TEST_TMPDIR/out.txt"
    : > "$out"
    files="$BATS_TEST_TMPDIR/changed.txt"
}

val() {
    grep -E "^$1=" "$out" | cut -d= -f2-
}

@test "workflow_dispatch: honours the input tag and always runs" {
    EVENT_NAME=workflow_dispatch REPOSITORY=wiki-mod/lancache-ng \
        DISPATCH_TAG=edge GITHUB_OUTPUT="$out" \
        run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val image_tag)" = "edge" ]
    [ "$(val should_run)" = "true" ]
    [ "$(val pr_staging_available)" = "false" ]
}

@test "same-repo PR: resolves its own staging tag and per-service flags" {
    printf 'services/proxy/nginx.conf\n' > "$files"
    EVENT_NAME=pull_request REPOSITORY=wiki-mod/lancache-ng BASE_REF=master \
        PR_NUMBER=715 BUILD_SHA=abcdef0123456 ACTOR=someuser \
        HEAD_REPO=wiki-mod/lancache-ng CHANGED_FILES="$files" \
        GITHUB_OUTPUT="$out" run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val pr_staging_available)" = "true" ]
    [ "$(val image_tag)" = "pr-715-sha-abcdef0" ]
    [ "$(val base_channel_tag)" = "edge" ]
    [ "$(val proxy)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "docs-only PR: does not run the deep suite" {
    printf 'docs/x.md\n' > "$files"
    EVENT_NAME=pull_request REPOSITORY=wiki-mod/lancache-ng BASE_REF=master \
        PR_NUMBER=716 BUILD_SHA=abcdef0123456 ACTOR=someuser \
        HEAD_REPO=wiki-mod/lancache-ng CHANGED_FILES="$files" \
        GITHUB_OUTPUT="$out" run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val should_run)" = "false" ]
}
