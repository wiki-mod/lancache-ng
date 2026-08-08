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

# Artifact-producing v2/release callers pass the exact external build-input
# contract from the plan. Older source-only callers are still representable by
# an empty object, but must not accidentally opt into the strict per-service
# external-input validator merely because this writer stores that empty object.
build_inputs_explicit=false
if [[ -v CI_SOURCE_BUILD_INPUTS_JSON ]]; then
    build_inputs_explicit=true
    build_inputs_raw="$CI_SOURCE_BUILD_INPUTS_JSON"
    bash "$repo_root/scripts/ci-build-inputs.sh" "$service" validate "$build_inputs_raw"
else
    build_inputs_raw='{"build_args":{},"build_contexts":{}}'
fi
build_inputs="$(jq -cS . <<<"$build_inputs_raw")"

fingerprint_with_inputs() {
    local apt_cache_bust="$1"
    if [[ "$build_inputs_explicit" == true ]]; then
        CI_SOURCE_BUILD_INPUTS_JSON="$build_inputs" \
        CI_SOURCE_APT_CACHE_BUST="$apt_cache_bust" \
        CI_SOURCE_REQUIRE_APT_CACHE_BUST=true \
            bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha"
    else
        CI_SOURCE_APT_CACHE_BUST="$apt_cache_bust" \
        CI_SOURCE_REQUIRE_APT_CACHE_BUST=true \
            bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha"
    fi
}

fingerprint_reused() {
    if [[ "$build_inputs_explicit" == true ]]; then
        CI_SOURCE_BUILD_INPUTS_JSON="$build_inputs" \
            bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha"
    else
        bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$candidate_source_sha"
    fi
}

if [[ "$mode" == built ]]; then
    # The build action writes a digest-keyed marker after the successful push.
    # Read that producer evidence rather than recomputing a time-dependent
    # refresh value here. A build crossing an ISO-week boundary therefore keeps
    # the exact APT_CACHE_BUST it consumed.
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

    source_fingerprint="$(fingerprint_with_inputs "$apt_cache_bust")"
else
    source_fingerprint="$(fingerprint_reused)"
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
  --argjson build_inputs "$build_inputs" \
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
    build_inputs: $build_inputs,
    platform: $platform,
    digest: $digest,
    mode: $mode,
    reused_index_digest: $reused_index_digest
  }' >"$output"
ci_ai_validate_platform_record "$output"
