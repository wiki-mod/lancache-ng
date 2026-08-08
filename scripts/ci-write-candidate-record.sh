#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
set -euo pipefail

if [[ $# -ne 9 && $# -ne 10 ]]; then
    echo "usage: ci-write-candidate-record.sh SCOPE SERVICE IMAGE CANDIDATE_SOURCE_SHA ARTIFACT_SOURCE_SHA [SOURCE_FINGERPRINT] PLATFORM DIGEST MODE OUTPUT" >&2
    exit 2
fi

scope="$1"; service="$2"; image="$3"; candidate_source_sha="$4"; artifact_source_sha="$5"
if [[ $# -eq 10 ]]; then
    planned_source_fingerprint="$6"; platform="$7"; digest="$8"; mode="$9"; output="${10}"
else
    platform="$6"; digest="$7"; mode="$8"; output="$9"
    planned_source_fingerprint=""
fi
reused_index_digest="${REUSED_INDEX_DIGEST:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"

ci_ai_require_sha "$candidate_source_sha"
ci_ai_require_sha "$artifact_source_sha"
ci_ai_require_digest "$digest"
[[ "$scope" == runtime || "$scope" == tooling ]] || ci_ai_fail "invalid scope $scope"
[[ "$platform" == linux/amd64 || "$platform" == linux/arm64 ]] || ci_ai_fail "invalid platform $platform"
[[ "$mode" == built || "$mode" == reused ]] || ci_ai_fail "invalid mode $mode"
if [[ "$mode" == built && "$artifact_source_sha" != "$candidate_source_sha" ]]; then
    ci_ai_fail "a newly built candidate must originate from the candidate source SHA"
fi
if [[ "$mode" == reused ]]; then
    [[ -n "$reused_index_digest" ]] \
        || ci_ai_fail "reused candidate is missing the accepted multi-platform index digest"
    ci_ai_require_digest "$reused_index_digest"
else
    [[ -z "$reused_index_digest" ]] \
        || ci_ai_fail "newly built candidate must not carry a reused index digest"
fi

if [[ -n "$planned_source_fingerprint" ]]; then
    ci_ai_require_digest "$planned_source_fingerprint"
fi

if [[ "$mode" == built ]]; then
    # The build action writes a digest-keyed marker after the successful push.
    # Read that producer evidence rather than recomputing a time-dependent
    # refresh value here. A build that begins before an ISO-week boundary and
    # finishes after it therefore keeps the exact APT_CACHE_BUST it actually
    # consumed, while the next run still sees the new week and rebuilds.
    marker="${RUNNER_TEMP:?RUNNER_TEMP is required}/lancache-build-inputs/${digest#sha256:}.env"
    [[ -f "$marker" ]] \
        || ci_ai_fail "exact build-input marker is missing for built digest $digest"

    mapfile -t apt_values < <(sed -n 's/^APT_CACHE_BUST=//p' "$marker")
    (( ${#apt_values[@]} <= 1 )) \
        || ci_ai_fail "build-input marker contains multiple APT_CACHE_BUST values for $digest"
    apt_cache_bust=""
    if (( ${#apt_values[@]} == 1 )); then
        apt_cache_bust="${apt_values[0]}"
    fi

    source_fingerprint="$(
        CI_SOURCE_APT_CACHE_BUST="$apt_cache_bust" \
        CI_SOURCE_REQUIRE_APT_CACHE_BUST=true \
        "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha"
    )"
else
    # Reuse has no new producer. It is valid only while the current effective
    # inputs still equal the fingerprint the planner compared with the accepted
    # baseline. Recompute now as a final fail-closed check before recording it.
    source_fingerprint="$("$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha")"
    [[ -n "$planned_source_fingerprint" ]] \
        || ci_ai_fail "reused candidate is missing its planned source fingerprint"
    [[ "$planned_source_fingerprint" == "$source_fingerprint" ]] \
        || ci_ai_fail "effective source fingerprint changed after planning for reused $service: planned $planned_source_fingerprint, now $source_fingerprint"
fi
ci_ai_require_digest "$source_fingerprint"

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
  --arg reused_index_digest "$reused_index_digest" \
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
    mode: $mode,
    reused_index_digest: $reused_index_digest
  }' >"$output"
ci_ai_validate_platform_record "$output"