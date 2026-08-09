#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces a stable SHA-256 fingerprint of the effective build inputs for one
# first-party image at one Git commit. The commit SHA itself is not part of the
# hash, so different commits can prove build-input equivalence when their
# relevant source and frozen external inputs are identical.
#
# Source-controlled inputs are the Docker context tree, Dockerfile blob and
# named source contexts. CI_SOURCE_BUILD_INPUTS_JSON optionally adds the exact
# non-source inputs frozen by an artifact-producing pipeline. When it is
# supplied, the service-specific contract in ci-build-inputs.sh is enforced.
# When omitted, an empty external-input object preserves this helper's existing
# standalone source-only use by older validation/tests; artifact production is
# responsible for always supplying the explicit service contract.
set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "usage: ci-source-fingerprint.sh SERVICE SOURCE_SHA" >&2
    exit 2
}
service="$1"
source_sha="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_require_sha "$source_sha"

git -C "$repo_root" cat-file -e "${source_sha}^{commit}" 2>/dev/null \
    || ci_ai_fail "source commit does not exist locally: $source_sha"

catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"
entry="$(jq -c --arg service "$service" '.include[] | select(.service == $service)' <<<"$catalog")"
[[ -n "$entry" ]] || ci_ai_fail "service is not present in canonical image catalog: $service"
[[ "$(wc -l <<<"$entry" | tr -d ' ')" -eq 1 ]] || ci_ai_fail "service appears more than once in canonical image catalog: $service"

scope="$(jq -r '.scope' <<<"$entry")"
image="$(jq -r '.image' <<<"$entry")"
source_path="$(jq -r '.source' <<<"$entry")"
context="$(jq -r '.context' <<<"$entry")"
build_contexts="$(jq -r '.build_contexts' <<<"$entry")"

context_oid="$(git -C "$repo_root" rev-parse "${source_sha}:${context}" 2>/dev/null)" \
    || ci_ai_fail "Docker context $context does not exist at $source_sha for $service"
[[ "$context_oid" =~ ^[0-9a-f]{40,64}$ ]] || ci_ai_fail "invalid git object id for $service context: $context_oid"

source_oid="$(git -C "$repo_root" rev-parse "${source_sha}:${source_path}" 2>/dev/null)" \
    || ci_ai_fail "Dockerfile $source_path does not exist at $source_sha for $service"
[[ "$source_oid" =~ ^[0-9a-f]{40,64}$ ]] || ci_ai_fail "invalid git object id for $service Dockerfile: $source_oid"

named='[]'
if [[ -n "$build_contexts" ]]; then
    while IFS= read -r mapping; do
        [[ -n "$mapping" ]] || continue
        name="${mapping%%=*}"
        path="${mapping#*=}"
        [[ -n "$name" && -n "$path" && "$name" != "$mapping" ]] \
            || ci_ai_fail "invalid named build context mapping for $service: $mapping"
        oid="$(git -C "$repo_root" rev-parse "${source_sha}:${path}" 2>/dev/null)" \
            || ci_ai_fail "named build context $name=$path does not exist at $source_sha for $service"
        [[ "$oid" =~ ^[0-9a-f]{40,64}$ ]] || ci_ai_fail "invalid git object id for $service named context $name: $oid"
        named="$(jq -c --arg name "$name" --arg path "$path" --arg oid "$oid" '. + [{name:$name,path:$path,git_oid:$oid}]' <<<"$named")"
    done <<<"$build_contexts"
fi

if [[ -v CI_SOURCE_BUILD_INPUTS_JSON ]]; then
    build_inputs_raw="$CI_SOURCE_BUILD_INPUTS_JSON"
    bash "$repo_root/scripts/ci-build-inputs.sh" "$service" validate "$build_inputs_raw"
else
    build_inputs_raw='{"build_args":{},"build_contexts":{}}'
fi
build_inputs="$(jq -cS . <<<"$build_inputs_raw")"

refresh_policy="$(bash "$repo_root/scripts/ci-package-refresh-policy.sh" "$service" "$source_sha")"
refresh_required="$(jq -r '.refresh_required' <<<"$refresh_policy")"
refresh_inputs='{}'
if [[ "$refresh_required" == true ]]; then
    apt_cache_bust="${CI_SOURCE_APT_CACHE_BUST:-}"
    if [[ -z "$apt_cache_bust" ]]; then
        if [[ "${CI_SOURCE_REQUIRE_APT_CACHE_BUST:-false}" == true ]]; then
            ci_ai_fail "exact package refresh bucket is required for $service but was not supplied"
        fi
        apt_cache_bust="$(date -u +%G-W%V)"
    fi
    [[ "$apt_cache_bust" =~ ^[0-9]{4}-W[0-9]{2}$ ]] \
        || ci_ai_fail "invalid package refresh fingerprint input: $apt_cache_bust"
    refresh_inputs="$(jq -cn --arg value "$apt_cache_bust" '{APT_CACHE_BUST:$value}')"
fi

material="$(jq -cnS \
    --arg schema 'image-source-fingerprint-material/v2' \
    --arg scope "$scope" \
    --arg service "$service" \
    --arg image "$image" \
    --arg source "$source_path" \
    --arg source_oid "$source_oid" \
    --arg context "$context" \
    --arg context_oid "$context_oid" \
    --argjson named "$named" \
    --argjson build_inputs "$build_inputs" \
    --argjson refresh_inputs "$refresh_inputs" \
    '{
      schema:$schema,
      scope:$scope,
      service:$service,
      image:$image,
      dockerfile:{path:$source,git_oid:$source_oid},
      context:{path:$context,git_oid:$context_oid},
      named_contexts:($named | sort_by(.name,.path)),
      build_inputs:$build_inputs,
      refresh_inputs:$refresh_inputs
    }')"

fingerprint="$(printf '%s' "$material" | sha256sum | awk '{print $1}')"
printf 'sha256:%s\n' "$fingerprint"
