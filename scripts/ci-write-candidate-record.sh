#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
set -euo pipefail

[[ $# -eq 10 ]] || {
    echo "usage: ci-write-candidate-record.sh SCOPE SERVICE IMAGE CANDIDATE_SOURCE_SHA ARTIFACT_SOURCE_SHA SOURCE_FINGERPRINT PLATFORM DIGEST MODE OUTPUT" >&2
    exit 2
}

scope="$1"; service="$2"; image="$3"; candidate_source_sha="$4"; artifact_source_sha="$5"
source_fingerprint="$6"; platform="$7"; digest="$8"; mode="$9"; output="${10}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"

ci_ai_require_sha "$candidate_source_sha"
ci_ai_require_sha "$artifact_source_sha"
ci_ai_require_digest "$source_fingerprint"
ci_ai_require_digest "$digest"
[[ "$scope" == runtime || "$scope" == tooling ]] || ci_ai_fail "invalid scope $scope"
[[ "$platform" == linux/amd64 || "$platform" == linux/arm64 ]] || ci_ai_fail "invalid platform $platform"
[[ "$mode" == built || "$mode" == reused ]] || ci_ai_fail "invalid mode $mode"
if [[ "$mode" == built && "$artifact_source_sha" != "$candidate_source_sha" ]]; then
    ci_ai_fail "a newly built candidate must originate from the candidate source SHA"
fi

mkdir -p "$(dirname "$output")"
jq -n \
  --arg scope "$scope" \
  --arg service "$service" \
  --arg image "$image" \
  --arg candidate_source_sha "$candidate_source_sha" \
  --arg artifact_source_sha "$artifact_source_sha" \
  --arg source_fingerprint "$source_fingerprint" \
  --arg platform "$platform" \
  --arg digest "$digest" \
  --arg mode "$mode" \
  '{
    schema: "image-candidate-platform/v1",
    scope: $scope,
    service: $service,
    image: $image,
    candidate_source_sha: $candidate_source_sha,
    artifact_source_sha: $artifact_source_sha,
    source_fingerprint: $source_fingerprint,
    platform: $platform,
    digest: $digest,
    mode: $mode
  }' >"$output"
ci_ai_validate_platform_record "$output"
