#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACTION="$REPO_ROOT/.github/actions/ghcr-build-once-push-retry/action.yml"
}

@test "build-once publisher executes Dockerfile stages through exactly one build action" {
  count="$(grep -Fc 'uses: docker/build-push-action@' "$ACTION")"
  [ "$count" -eq 1 ]
  run grep -F 'push: false' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'load: true' "$ACTION"
  [ "$status" -eq 0 ]
}

@test "registry retry republishes the already-loaded local tag" {
  run grep -F 'docker image push "$TARGET_TAG"' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'digest="$(ci_ai_ref_digest "$TARGET_TAG")"' "$ACTION"
  [ "$status" -eq 0 ]
}

@test "loaded quarantine image is removed even when a later action step fails" {
  cleanup_line="$(grep -nF 'name: Remove local quarantine image after publication attempt' "$ACTION" | cut -d: -f1)"
  always_line="$(grep -nF 'if: always()' "$ACTION" | tail -n1 | cut -d: -f1)"
  remove_line="$(grep -nF 'docker image rm "$TARGET_TAG"' "$ACTION" | cut -d: -f1)"
  [[ "$cleanup_line" =~ ^[0-9]+$ ]]
  [[ "$always_line" =~ ^[0-9]+$ ]]
  [[ "$remove_line" =~ ^[0-9]+$ ]]
  [ "$cleanup_line" -lt "$always_line" ]
  [ "$always_line" -lt "$remove_line" ]
}
