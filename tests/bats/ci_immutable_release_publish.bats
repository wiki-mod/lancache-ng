#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ci-publish-immutable-release-refs.sh"
}

@test "immutable release publisher performs full preflight before any write loop" {
  preflight_line="$(grep -nF '# Phase 1:' "$SCRIPT" | cut -d: -f1)"
  write_line="$(grep -nF '# Phase 2:' "$SCRIPT" | cut -d: -f1)"
  readback_line="$(grep -nF '# Phase 3:' "$SCRIPT" | cut -d: -f1)"
  [[ "$preflight_line" =~ ^[0-9]+$ ]]
  [[ "$write_line" =~ ^[0-9]+$ ]]
  [[ "$readback_line" =~ ^[0-9]+$ ]]
  [ "$preflight_line" -lt "$write_line" ]
  [ "$write_line" -lt "$readback_line" ]
}

@test "existing conflicting immutable release ref is a hard error" {
  run grep -F 'immutable release ref $target already exists at $actual, expected $desired' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'state_by_target["$target"]=existing' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'state_by_target["$target"]=missing' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "immutable release publisher never deletes or rewrites an already existing tag" {
  run grep -F '[[ "${state_by_target[$target]}" == missing ]] || continue' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E 'docker (image|manifest).*(rm|delete)|gh api .*DELETE|rollback_release_refs' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "immutable release publisher uses shared GHCR retry and exact post-write readback" {
  run grep -F 'ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" --' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -F 'actual="$(ci_ai_ref_digest "$target")"' "$SCRIPT"
  [ "$status" -eq 0 ]
}
