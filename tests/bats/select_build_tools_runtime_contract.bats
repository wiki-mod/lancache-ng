#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    selector="$REPO_ROOT/scripts/select-build-tools-image.sh"
}

@test "published build-tools digest resolution uses shared GHCR retry" {
    body="$BATS_TEST_TMPDIR/published-image-reference.txt"
    awk '/^published_image_reference\(\) \{/,/^}/' "$selector" >"$body"
    [ -s "$body" ]

    run grep -F 'ghcr_retry ghcr.io' "$body"
    [ "$status" -eq 0 ]
    run grep -F 'docker buildx imagetools inspect "$image"' "$body"
    [ "$status" -eq 0 ]
    run grep -F '2>/dev/null || true' "$body"
    [ "$status" -ne 0 ]
}

@test "published build-tools smoke has an in-container kill timeout" {
    body="$BATS_TEST_TMPDIR/smoke-test-image.txt"
    awk '/^smoke_test_image\(\) \{/,/^}/' "$selector" >"$body"
    [ -s "$body" ]

    run grep -F 'timeout --kill-after=30 300 bash -lc' "$body"
    [ "$status" -eq 0 ]
}
