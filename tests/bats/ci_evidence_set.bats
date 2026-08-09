#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK="$BATS_TEST_TMPDIR/lock.json"
  EVIDENCE="$BATS_TEST_TMPDIR/evidence"
  mkdir -p "$EVIDENCE"

  catalog="$(bash "$REPO_ROOT/scripts/query-stack-images.sh" all)"
  jq -n --argjson catalog "$catalog" '
    def digest($char): "sha256:" + ($char * 64);
    reduce $catalog.include[] as $entry (
      {
        schema:"stack-lock/v1",
        source_sha:("1" * 40),
        candidate_tag:"candidate-v2-test",
        runtime:{},
        tooling:{}
      };
      .[$entry.scope][$entry.service] = {
        image:$entry.image,
        artifact_source_sha:("1" * 40),
        source_fingerprint:digest("a"),
        build_inputs:{build_args:{},build_contexts:{}},
        digest:digest("b"),
        platforms:{
          "linux/amd64":digest("c"),
          "linux/arm64":digest("d")
        }
      }
    )
  ' >"$LOCK"
}

write_candidate_evidence() {
  local service=$1 platform=$2 digest=$3 file=$4
  jq -n \
    --arg service "$service" \
    --arg platform "$platform" \
    --arg digest "$digest" '
      {
        schema:"candidate-evidence/v1",
        service:$service,
        platform:$platform,
        digest:$digest,
        trivy:"passed",
        native_smoke:"passed"
      }
    ' >"$file"
}

write_complete_candidate_evidence() {
  local rows service platform digest arch
  rows="$(jq -r '
    (.runtime + .tooling)
    | to_entries[]
    | .key as $service
    | .value.platforms
    | to_entries[]
    | [$service,.key,.value]
    | @tsv
  ' "$LOCK")"
  while IFS=$'\t' read -r service platform digest; do
    arch="${platform#linux/}"
    write_candidate_evidence "$service" "$platform" "$digest" "$EVIDENCE/${service}__${arch}.json"
  done <<<"$rows"
}

@test "stack lock catalog verifier accepts exactly the canonical service set" {
  run bash "$REPO_ROOT/scripts/ci-verify-stack-lock-catalog.sh" "$LOCK"
  [ "$status" -eq 0 ]
}

@test "stack lock catalog verifier rejects a schema-valid extra service" {
  jq '.runtime.evil = .runtime.proxy | .runtime.evil.image = "ghcr.io/wiki-mod/lancache-ng/evil"' "$LOCK" >"$LOCK.tmp"
  mv "$LOCK.tmp" "$LOCK"
  run bash "$REPO_ROOT/scripts/ci-verify-stack-lock-catalog.sh" "$LOCK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"service set differs from canonical catalog"* ]]
}

@test "candidate evidence verifier accepts one exact record per locked tuple" {
  write_complete_candidate_evidence
  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence-set.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -eq 0 ]
}

@test "duplicate candidate tuple cannot hide a missing different tuple" {
  write_complete_candidate_evidence
  rm -f "$EVIDENCE/proxy__arm64.json"
  cp "$EVIDENCE/proxy__amd64.json" "$EVIDENCE/proxy__amd64-duplicate.json"

  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence-set.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate candidate evidence tuple: proxy/linux/amd64"* ]]
}

@test "candidate evidence with the wrong locked digest fails even when tuple count matches" {
  write_complete_candidate_evidence
  jq '.digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
    "$EVIDENCE/proxy__amd64.json" >"$EVIDENCE/proxy__amd64.json.tmp"
  mv "$EVIDENCE/proxy__amd64.json.tmp" "$EVIDENCE/proxy__amd64.json"

  run bash "$REPO_ROOT/scripts/ci-verify-platform-evidence-set.sh" "$LOCK" "$EVIDENCE" candidate
  [ "$status" -ne 0 ]
  [[ "$output" == *"evidence tuple/digest set differs from stack lock"* ]]
}
