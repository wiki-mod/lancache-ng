#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "release planner buffers validated rows until the full plan succeeds" {
  planner="$REPO_ROOT/scripts/ci-release-ref-plan.sh"
  run grep -F 'validated_rows+=(' "$planner"
  [ "$status" -eq 0 ]
  run grep -F 'printf '\''%s\n'\'' "${validated_rows[@]}"' "$planner"
  [ "$status" -eq 0 ]
}

@test "immutable publisher captures planner exit status before mapfile" {
  publisher="$REPO_ROOT/scripts/ci-publish-immutable-release-refs.sh"
  capture_line="$(grep -nF 'if desired_text="$(bash "$repo_root/scripts/ci-release-ref-plan.sh"' "$publisher" | cut -d: -f1)"
  mapfile_line="$(grep -nF 'mapfile -t desired_rows <<<"$desired_text"' "$publisher" | cut -d: -f1)"
  [[ "$capture_line" =~ ^[0-9]+$ ]]
  [[ "$mapfile_line" =~ ^[0-9]+$ ]]
  [ "$capture_line" -lt "$mapfile_line" ]
  run grep -F 'mapfile -t desired_rows < <(' "$publisher"
  [ "$status" -ne 0 ]
}
