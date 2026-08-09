#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/ci-promote-accepted-v2.yml"
}

line_of() {
  grep -nF "$1" "$WORKFLOW" | head -n1 | cut -d: -f1
}

@test "promotion verifies accepted identity before acquiring the global writer lock" {
  extract_line="$(line_of 'bash scripts/ci-extract-stack-lock.sh')"
  first_tip_line="$(line_of 'Prove accepted source is the current channel branch tip')"
  lock_line="$(line_of 'Acquire the cross-workflow promote lock')"

  [ -n "$extract_line" ]
  [ -n "$first_tip_line" ]
  [ -n "$lock_line" ]
  [ "$extract_line" -lt "$first_tip_line" ]
  [ "$first_tip_line" -lt "$lock_line" ]
}

@test "promotion rechecks branch tip under the writer lock before moving GHCR refs" {
  lock_line="$(line_of 'Acquire the cross-workflow promote lock')"
  recheck_line="$(line_of 'Re-prove accepted source after promote lock acquisition')"
  mutate_line="$(line_of 'Move channel references without rebuild, roll back on partial failure')"

  [ -n "$lock_line" ]
  [ -n "$recheck_line" ]
  [ -n "$mutate_line" ]
  [ "$lock_line" -lt "$recheck_line" ]
  [ "$recheck_line" -lt "$mutate_line" ]

  run grep -F 'git fetch --no-tags origin "$CHANNEL_BRANCH"' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'origin/$CHANNEL_BRANCH moved to $branch_tip before publication' "$WORKFLOW"
  [ "$status" -eq 0 ]
}
