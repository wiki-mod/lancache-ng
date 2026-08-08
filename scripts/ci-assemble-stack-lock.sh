#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
set -euo pipefail

[[ $# -eq 4 ]] || {
    echo "usage: ci-assemble-stack-lock.sh SOURCE_SHA CANDIDATE_TAG INDEX_DIR OUTPUT" >&2
    exit 2
}
source_sha="$1"; candidate_tag="$2"; index_dir="$3"; output="$4"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_require_sha "$source_sha"

catalog="$("$repo_root/scripts/query-stack-images.sh" all)"
lock="$(jq -n --arg source_sha "$source_sha" --arg candidate_tag "$candidate_tag" '{
  schema: "stack-lock/v1",
  source_sha: $source_sha,
  candidate_tag: $candidate_tag,
  runtime: {},
  tooling: {}
}')"

while IFS= read -r entry; do
    service="$(jq -r '.service' <<<"$entry")"
    scope="$(jq -r '.scope' <<<"$entry")"
    index_file="$index_dir/${service}.json"
    [[ -f "$index_file" ]] || ci_ai_fail "missing index record for $service"
    ci_ai_validate_index_record "$index_file"
    [[ "$(jq -r '.candidate_source_sha' "$index_file")" == "$source_sha" ]] || ci_ai_fail "candidate source SHA mismatch for $service"
    [[ "$(jq -r '.scope' "$index_file")" == "$scope" ]] || ci_ai_fail "scope mismatch for $service"
    record="$(jq -c '{image, digest, platforms, candidate_ref, artifact_source_sha}' "$index_file")"
    lock="$(jq -c --arg scope "$scope" --arg service "$service" --argjson record "$record" '.[$scope][$service] = $record' <<<"$lock")"
done < <(jq -c '.include[]' <<<"$catalog")

mkdir -p "$(dirname "$output")"
jq '.' <<<"$lock" >"$output"
ci_ai_validate_stack_lock "$output"
