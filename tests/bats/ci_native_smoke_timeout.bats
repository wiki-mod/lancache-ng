#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "candidate and release native smokes bound the command inside the product container" {
  for workflow in \
    "$REPO_ROOT/.github/workflows/ci-artifact-v2.yml" \
    "$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"; do
    run grep -F "-c 'timeout -k 30 60 /bin/sh -c true'" "$workflow"
    [ "$status" -eq 0 ]
  done
}
