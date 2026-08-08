#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Creates one multi-platform candidate index from already-built or reused child
# digests. This is a reference assembly operation, never a rebuild.
set -euo pipefail

[[ $# -eq 6 ]] || {
    echo "usage: ci-assemble-service-index.sh SERVICE IMAGE SOURCE_SHA CANDIDATE_TAG RECORD_DIR OUTPUT" >&2
    exit 2
}
service="$1"; image="$2"; source_sha="$3"; candidate_tag="$4"; record_dir="$5"; output="$6"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
source "$repo_root/scripts/lib/ghcr-retry.sh"

ci_ai_require_sha "$source_sha"
amd64_file="$record_dir/${service}__amd64.json"
arm64_file="$record_dir/${service}__arm64.json"
ci_ai_validate_platform_record "$amd64_file"
ci_ai_validate_platform_record "$arm64_file"

for file in "$amd64_file" "$arm64_file"; do
    [[ "$(jq -r '.service' "$file")" == "$service" ]] || ci_ai_fail "service mismatch in $file"
    [[ "$(jq -r '.image' "$file")" == "$image" ]] || ci_ai_fail "image mismatch in $file"
    [[ "$(jq -r '.candidate_source_sha' "$file")" == "$source_sha" ]] || ci_ai_fail "candidate source SHA mismatch in $file"
done

scope="$(jq -r '.scope' "$amd64_file")"
[[ "$(jq -r '.scope' "$arm64_file")" == "$scope" ]] || ci_ai_fail "scope mismatch for $service"
artifact_source_sha="$(jq -r '.artifact_source_sha' "$amd64_file")"
[[ "$(jq -r '.artifact_source_sha' "$arm64_file")" == "$artifact_source_sha" ]] || ci_ai_fail "artifact source SHA mismatch between platforms for $service"
ci_ai_require_sha "$artifact_source_sha"
amd64_digest="$(jq -r '.digest' "$amd64_file")"
arm64_digest="$(jq -r '.digest' "$arm64_file")"
ci_ai_require_digest "$amd64_digest"
ci_ai_require_digest "$arm64_digest"

target="${image}:${candidate_tag}"
metadata="$(mktemp)"
trap 'rm -f "$metadata"' EXIT

ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- \
    docker buildx imagetools create \
      --tag "$target" \
      "${image}@${amd64_digest}" \
      "${image}@${arm64_digest}" \
      --metadata-file "$metadata"

index_digest="$(jq -r '."containerimage.descriptor".digest // empty' "$metadata")"
ci_ai_require_digest "$index_digest"

actual_amd64="$(ci_ai_platform_digest "${image}@${index_digest}" linux/amd64)"
actual_arm64="$(ci_ai_platform_digest "${image}@${index_digest}" linux/arm64)"
[[ "$actual_amd64" == "$amd64_digest" ]] || ci_ai_fail "$service amd64 digest changed during index assembly"
[[ "$actual_arm64" == "$arm64_digest" ]] || ci_ai_fail "$service arm64 digest changed during index assembly"

mkdir -p "$(dirname "$output")"
jq -n \
  --arg scope "$scope" \
  --arg service "$service" \
  --arg image "$image" \
  --arg candidate_source_sha "$source_sha" \
  --arg artifact_source_sha "$artifact_source_sha" \
  --arg digest "$index_digest" \
  --arg amd64 "$amd64_digest" \
  --arg arm64 "$arm64_digest" \
  --arg candidate_ref "$target" \
  '{
    schema: "image-candidate-index/v1",
    scope: $scope,
    service: $service,
    image: $image,
    candidate_source_sha: $candidate_source_sha,
    artifact_source_sha: $artifact_source_sha,
    digest: $digest,
    candidate_ref: $candidate_ref,
    platforms: {
      "linux/amd64": $amd64,
      "linux/arm64": $arm64
    }
  }' >"$output"
ci_ai_validate_index_record "$output"
