#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"
}

@test "release tag is resolved once and every downstream checkout uses the frozen commit" {
  run awk '
    /ref: \$\{\{ inputs\.release_tag \}\}/ { tag_refs++ }
    /ref: \$\{\{ needs\.plan\.outputs\.source_sha \}\}/ { frozen_refs++ }
    END {
      if (tag_refs != 1 || frozen_refs != 4) {
        printf "tag_refs=%d frozen_refs=%d\n", tag_refs, frozen_refs > "/dev/stderr"
        exit 1
      }
    }
  ' "$WORKFLOW"
  [ "$status" -eq 0 ]

  run grep -F 'name: Checkout the exact release-tag source' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'name: Checkout frozen release source commit' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
