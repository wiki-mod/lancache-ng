#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "v2 planner invokes repository helper scripts through bash" {
  planner="$REPO_ROOT/scripts/ci-plan-run.sh"

  run grep -F 'catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"' "$planner"
  [ "$status" -eq 0 ]

  run grep -F 'classification="$(bash "$repo_root/scripts/classify-image-impact.sh" "$baseline_sha" "$source_sha")"' "$planner"
  [ "$status" -eq 0 ]

  run grep -F 'source_fingerprint="$(bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$source_sha")"' "$planner"
  [ "$status" -eq 0 ]

  run grep -F '$("$repo_root/scripts/ci-source-fingerprint.sh"' "$planner"
  [ "$status" -ne 0 ]
}
