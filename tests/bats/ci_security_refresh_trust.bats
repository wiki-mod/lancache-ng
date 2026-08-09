#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/ci-security-refresh-v2.yml"
}

@test "security refresh accepts attestations only from protected product workflow refs" {
  run grep -F 'refs/heads/current_dev|refs/heads/master)' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F '[[ "$REF_PROTECTED" == true ]]' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'Security refresh must be dispatched from protected current_dev or master' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
