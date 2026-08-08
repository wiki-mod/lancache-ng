#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces a stable SHA-256 fingerprint of the source-controlled Docker inputs
# for one first-party image at one Git commit. The commit SHA itself is not part
# of the hash, so two different commits can prove source equivalence when the
# relevant build context and named build contexts are byte-identical.
#
# This is intentionally a source-equivalence fingerprint, not a promise that a
# fresh rebuild at a later date would be byte-identical. Mutable upstream base
# images and explicit refresh inputs are separate lifecycle concerns. Reuse is
# allowed only for a previously accepted digest and only when this fingerprint
# plus the repository's path classifier both prove the source-controlled image
# inputs unchanged.
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

catalog="$("$repo_root/scripts/query-stack-images.sh" all)"
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

# Keep the source Dockerfile path explicit in the canonical material even
# though it normally lives inside the context tree. This catches an accidental
# catalog/context mismatch and makes the proof reviewable without reverse
# engineering the tree.
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

material="$(jq -cnS \
    --arg schema 'image-source-fingerprint-material/v1' \
    --arg scope "$scope" \
    --arg service "$service" \
    --arg image "$image" \
    --arg source "$source_path" \
    --arg source_oid "$source_oid" \
    --arg context "$context" \
    --arg context_oid "$context_oid" \
    --argjson named "$named" \
    '{
      schema:$schema,
      scope:$scope,
      service:$service,
      image:$image,
      dockerfile:{path:$source,git_oid:$source_oid},
      context:{path:$context,git_oid:$context_oid},
      named_contexts:($named | sort_by(.name,.path))
    }')"

fingerprint="$(printf '%s' "$material" | sha256sum | awk '{print $1}')"
printf 'sha256:%s\n' "$fingerprint"
