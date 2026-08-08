#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/.github/actions/shellcheck-and-standing-guards/action.yml"
}

@test "every standing-guard build-tools container has an inner kill timeout" {
    image_line='"${{ inputs.build-tools-image }}" \'
    actual="$(grep -cF "$image_line" "$ACTION")"
    [ "$actual" -gt 0 ]

    covered="$(grep -F -A1 "$image_line" "$ACTION" | grep -cF 'timeout --kill-after=30' || true)"
    [ "$covered" -eq "$actual" ]
}
