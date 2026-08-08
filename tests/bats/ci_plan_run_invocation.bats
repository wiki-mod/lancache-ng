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

@test "source fingerprint invokes the canonical catalog through bash" {
  script="$REPO_ROOT/scripts/ci-source-fingerprint.sh"

  run grep -F 'catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"' "$script"
  [ "$status" -eq 0 ]
  run grep -F '$("$repo_root/scripts/query-stack-images.sh"' "$script"
  [ "$status" -ne 0 ]
}

@test "v2 workflow supersedes only eligible first-attempt PR runs" {
  workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"

  run grep -F "github.run_attempt == 1" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "github.event.pull_request.head.repo.full_name == github.repository" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "contains(github.event.pull_request.labels.*.name, 'ci-v2-test')" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "(github.event.action != 'labeled' || github.event.label.name == 'ci-v2-test')" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "format('{0}-pr-{1}', github.workflow, github.ref)" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "format('{0}-run-{1}-{2}', github.workflow, github.run_id, github.run_attempt)" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'cancel-in-progress: >-' "$workflow"
  [ "$status" -eq 0 ]
}

@test "v2 reuse carries the accepted service index digest into platform records" {
  workflow="$REPO_ROOT/.github/workflows/ci-artifact-v2.yml"

  run grep -F 'REUSED_INDEX_DIGEST: ${{ matrix.reused_index_digest }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'reused_index_digest: $reused_index_digest' "$REPO_ROOT/scripts/ci-plan-run.sh"
  [ "$status" -eq 0 ]
}
