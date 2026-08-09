#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/scripts/lib/ci-artifact-identity.sh"
}

@test "optional ref snapshot returns a valid existing digest" {
  ci_ai_manifest_json() {
    printf '%s\n' '{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  }

  run ci_ai_ref_digest_optional ghcr.io/wiki-mod/lancache-ng/proxy:latest
  [ "$status" -eq 0 ]
  [ "$output" = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
}

@test "optional ref snapshot reports only explicit absence with dedicated status" {
  ci_ai_manifest_json() {
    echo 'manifest unknown: requested tag was not found' >&2
    return 17
  }

  run ci_ai_ref_digest_optional ghcr.io/wiki-mod/lancache-ng/proxy:first-publication
  [ "$status" -eq "$CI_AI_REF_ABSENT_STATUS" ]
}

@test "optional ref snapshot preserves ambiguous authentication failure" {
  ci_ai_manifest_json() {
    echo 'unauthorized: authentication required' >&2
    return 23
  }

  run ci_ai_ref_digest_optional ghcr.io/wiki-mod/lancache-ng/proxy:latest
  [ "$status" -eq 23 ]
  [[ "$output" == *'unauthorized: authentication required'* ]]
}

@test "promotion and release snapshot before mutation without swallowing read failures" {
  promote="$REPO_ROOT/.github/workflows/ci-promote-accepted-v2.yml"
  release="$REPO_ROOT/.github/workflows/ci-release-accepted-v2.yml"

  for workflow in "$promote" "$release"; do
    run grep -F 'snapshot_previous_ref "$target"' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'status == CI_AI_REF_ABSENT_STATUS' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'previous_refs["$target"]="$(digest_for_ref "$target" || true)"' "$workflow"
    [ "$status" -ne 0 ]
  done
}
