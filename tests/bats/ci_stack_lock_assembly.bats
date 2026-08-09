#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

write_catalog_indexes() {
  local index_dir="$1" mutation="$2"
  local catalog scope service image recorded_service candidate_ref
  catalog="$(bash "$REPO_ROOT/scripts/query-stack-images.sh" all)"
  while IFS= read -r entry; do
    scope="$(jq -r '.scope' <<<"$entry")"
    service="$(jq -r '.service' <<<"$entry")"
    image="$(jq -r '.image' <<<"$entry")"
    recorded_service="$service"
    candidate_ref="${image}@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    if [[ "$service" == proxy && "$mutation" == service ]]; then
      recorded_service=dns
    fi
    if [[ "$service" == proxy && "$mutation" == transport ]]; then
      candidate_ref="${image}:candidate-v2-wrong"
    fi

    jq -n \
      --arg scope "$scope" \
      --arg service "$recorded_service" \
      --arg image "$image" \
      --arg candidate_ref "$candidate_ref" \
      '{
        schema:"image-candidate-index/v1",
        scope:$scope,
        service:$service,
        image:$image,
        candidate_source_sha:"1111111111111111111111111111111111111111",
        artifact_source_sha:"1111111111111111111111111111111111111111",
        source_fingerprint:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        build_inputs:{build_args:{},build_contexts:{}},
        digest:"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        candidate_ref:$candidate_ref,
        platforms:{
          "linux/amd64":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "linux/arm64":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      }' >"$index_dir/${service}.json"
  done < <(jq -c '.include[]' <<<"$catalog")
}

@test "stack-lock assembly rejects an index record bound to the wrong service" {
  index_dir="$BATS_TEST_TMPDIR/service-indexes"
  output_file="$BATS_TEST_TMPDIR/service-stack-lock.json"
  mkdir -p "$index_dir"
  write_catalog_indexes "$index_dir" service

  run bash "$REPO_ROOT/scripts/ci-assemble-stack-lock.sh" \
    1111111111111111111111111111111111111111 candidate-v2-test \
    "$index_dir" "$output_file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"service identity mismatch for proxy"* ]]
  [ ! -e "$output_file" ]
}

@test "stack-lock assembly rejects a transport ref not bound to digest or candidate tag" {
  index_dir="$BATS_TEST_TMPDIR/transport-indexes"
  output_file="$BATS_TEST_TMPDIR/transport-stack-lock.json"
  mkdir -p "$index_dir"
  write_catalog_indexes "$index_dir" transport

  run bash "$REPO_ROOT/scripts/ci-assemble-stack-lock.sh" \
    1111111111111111111111111111111111111111 candidate-v2-test \
    "$index_dir" "$output_file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate transport reference is not bound to the recorded identity for proxy"* ]]
  [ ! -e "$output_file" ]
}
