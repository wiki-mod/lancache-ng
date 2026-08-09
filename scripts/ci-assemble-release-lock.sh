#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Creates the release stack lock without rebuilding any accepted runtime image.
# The only identity replaced is build-tools, which is freshly built from the
# release-tag source and already represented by an image-candidate-index record.
set -euo pipefail

[[ $# -eq 6 ]] || {
    echo "usage: ci-assemble-release-lock.sh ACCEPTED_LOCK ACCEPTED_POINTER_DIGEST BUILD_TOOLS_INDEX RELEASE_TAG RELEASE_CANDIDATE_TAG OUTPUT" >&2
    exit 2
}

accepted_lock="$1"
accepted_pointer_digest="$2"
build_tools_index="$3"
release_tag="$4"
release_candidate_tag="$5"
output="$6"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"

ci_ai_validate_stack_lock "$accepted_lock"
ci_ai_require_digest "$accepted_pointer_digest"
ci_ai_validate_index_record "$build_tools_index"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || ci_ai_fail "invalid release tag: $release_tag"
[[ "$release_candidate_tag" =~ ^release-v2-[A-Za-z0-9._-]+$ ]] \
    || ci_ai_fail "invalid release candidate tag: $release_candidate_tag"

source_sha="$(jq -r '.source_sha' "$accepted_lock")"
accepted_lock_hash="$(sha256sum "$accepted_lock" | awk '{print $1}')"
ci_ai_require_sha "$source_sha"
[[ "$accepted_lock_hash" =~ ^[0-9a-f]{64}$ ]] \
    || ci_ai_fail "could not hash accepted runtime lock"
[[ "$(jq -r '.service' "$build_tools_index")" == build-tools ]] \
    || ci_ai_fail "release tooling record is not build-tools"
[[ "$(jq -r '.scope' "$build_tools_index")" == tooling ]] \
    || ci_ai_fail "release build-tools record does not have tooling scope"
[[ "$(jq -r '.candidate_source_sha' "$build_tools_index")" == "$source_sha" ]] \
    || ci_ai_fail "release build-tools source does not match accepted runtime source"
[[ "$(jq -r '.artifact_source_sha' "$build_tools_index")" == "$source_sha" ]] \
    || ci_ai_fail "release build-tools artifact source does not match release source"

image="$(jq -r '.image' "$build_tools_index")"
digest="$(jq -r '.digest' "$build_tools_index")"
fingerprint="$(jq -r '.source_fingerprint' "$build_tools_index")"
build_inputs="$(jq -cS '.build_inputs' "$build_tools_index")"
amd64="$(jq -r '.platforms["linux/amd64"]' "$build_tools_index")"
arm64="$(jq -r '.platforms["linux/arm64"]' "$build_tools_index")"
candidate_ref="$(jq -r '.candidate_ref' "$build_tools_index")"
ci_ai_require_digest "$digest"
ci_ai_require_digest "$fingerprint"
ci_ai_require_digest "$amd64"
ci_ai_require_digest "$arm64"
[[ "$image" == ghcr.io/wiki-mod/lancache-ng/build-tools ]] \
    || ci_ai_fail "unexpected release build-tools image: $image"
[[ "$candidate_ref" == "${image}:${release_candidate_tag}" ]] \
    || ci_ai_fail "release build-tools candidate ref does not match the planned immutable transport tag"

mkdir -p "$(dirname "$output")"
jq \
  --arg release_tag "$release_tag" \
  --arg candidate_tag "$release_candidate_tag" \
  --arg accepted_runtime_pointer_digest "$accepted_pointer_digest" \
  --arg accepted_runtime_lock_sha256 "$accepted_lock_hash" \
  --arg image "$image" \
  --arg artifact_source_sha "$source_sha" \
  --arg source_fingerprint "$fingerprint" \
  --argjson build_inputs "$build_inputs" \
  --arg digest "$digest" \
  --arg candidate_ref "$candidate_ref" \
  --arg amd64 "$amd64" \
  --arg arm64 "$arm64" '
    .candidate_tag = $candidate_tag
    | .release = {
        tag: $release_tag,
        runtime_origin: "accepted-stack",
        accepted_runtime_pointer_digest: $accepted_runtime_pointer_digest,
        accepted_runtime_lock_sha256: $accepted_runtime_lock_sha256,
        build_tools_origin: "fresh-release-build"
      }
    | .runtime |= with_entries(
        .value.candidate_ref = (.value.image + "@" + .value.digest)
      )
    | .tooling["build-tools"] = {
        image: $image,
        artifact_source_sha: $artifact_source_sha,
        source_fingerprint: $source_fingerprint,
        build_inputs: $build_inputs,
        digest: $digest,
        candidate_ref: $candidate_ref,
        platforms: {
          "linux/amd64": $amd64,
          "linux/arm64": $arm64
        }
      }
  ' "$accepted_lock" >"$output"

ci_ai_validate_stack_lock "$output"
jq -e --arg release_tag "$release_tag" --arg pointer_digest "$accepted_pointer_digest" --arg lock_hash "$accepted_lock_hash" '
  .release.tag == $release_tag
  and .release.runtime_origin == "accepted-stack"
  and .release.accepted_runtime_pointer_digest == $pointer_digest
  and .release.accepted_runtime_lock_sha256 == $lock_hash
  and .release.build_tools_origin == "fresh-release-build"
' "$output" >/dev/null \
    || ci_ai_fail "release metadata is incomplete in $output"
