#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces one multi-platform candidate index identity from platform records.
# Newly built services assemble an index from their recorded child digests.
# Fully reused services retain the exact accepted index digest and never create
# a replacement wrapper around unchanged children.
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
source_fingerprint="$(jq -r '.source_fingerprint' "$amd64_file")"
[[ "$(jq -r '.source_fingerprint' "$arm64_file")" == "$source_fingerprint" ]] || ci_ai_fail "source fingerprint mismatch between platforms for $service"
ci_ai_require_digest "$source_fingerprint"
build_inputs="$(jq -cS '.build_inputs' "$amd64_file")"
[[ "$(jq -cS '.build_inputs' "$arm64_file")" == "$build_inputs" ]] || ci_ai_fail "build inputs mismatch between platforms for $service"
bash "$repo_root/scripts/ci-build-inputs.sh" "$service" validate "$build_inputs" || {
    # Legacy source-only records are representable only with a genuinely empty
    # object. Artifact-producing v2 records are expected to use the exact
    # service-specific contract and will therefore pass the validator above.
    [[ "$build_inputs" == '{"build_args":{},"build_contexts":{}}' ]] \
        || ci_ai_fail "invalid build inputs for $service"
}
amd64_digest="$(jq -r '.digest' "$amd64_file")"
arm64_digest="$(jq -r '.digest' "$arm64_file")"
ci_ai_require_digest "$amd64_digest"
ci_ai_require_digest "$arm64_digest"

amd64_mode="$(jq -r '.mode' "$amd64_file")"
arm64_mode="$(jq -r '.mode' "$arm64_file")"
[[ "$amd64_mode" == "$arm64_mode" ]] \
    || ci_ai_fail "platform records mix built/reused identity for $service"
mode="$amd64_mode"

if [[ "$mode" == reused ]]; then
    amd64_index="$(jq -r '.reused_index_digest' "$amd64_file")"
    arm64_index="$(jq -r '.reused_index_digest' "$arm64_file")"
    ci_ai_require_digest "$amd64_index"
    ci_ai_require_digest "$arm64_index"
    [[ "$amd64_index" == "$arm64_index" ]] \
        || ci_ai_fail "reused platform records disagree on accepted index digest for $service"
    index_digest="$amd64_index"
    candidate_ref="${image}@${index_digest}"
else
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
    candidate_ref="$target"
fi

actual_amd64="$(ci_ai_platform_digest "${image}@${index_digest}" linux/amd64)"
actual_arm64="$(ci_ai_platform_digest "${image}@${index_digest}" linux/arm64)"
[[ "$actual_amd64" == "$amd64_digest" ]] || ci_ai_fail "$service amd64 digest differs from index identity"
[[ "$actual_arm64" == "$arm64_digest" ]] || ci_ai_fail "$service arm64 digest differs from index identity"

mkdir -p "$(dirname "$output")"
jq -n \
  --arg scope "$scope" \
  --arg service "$service" \
  --arg image "$image" \
  --arg candidate_source_sha "$source_sha" \
  --arg artifact_source_sha "$artifact_source_sha" \
  --arg source_fingerprint "$source_fingerprint" \
  --argjson build_inputs "$build_inputs" \
  --arg digest "$index_digest" \
  --arg amd64 "$amd64_digest" \
  --arg arm64 "$arm64_digest" \
  --arg candidate_ref "$candidate_ref" \
  '{
    schema: "image-candidate-index/v1",
    scope: $scope,
    service: $service,
    image: $image,
    candidate_source_sha: $candidate_source_sha,
    artifact_source_sha: $artifact_source_sha,
    source_fingerprint: $source_fingerprint,
    build_inputs: $build_inputs,
    digest: $digest,
    candidate_ref: $candidate_ref,
    platforms: {
      "linux/amd64": $amd64,
      "linux/arm64": $arm64
    }
  }' >"$output"
ci_ai_validate_index_record "$output"
