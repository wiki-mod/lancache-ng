#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces a stable SHA-256 fingerprint of the effective source-controlled
# Docker inputs for one first-party image at one Git commit. The commit SHA
# itself is not part of the hash, so different commits can prove source
# equivalence when their relevant build inputs are byte-identical.
#
# The fingerprint also includes refresh inputs that materially change the
# build. Today that means the same ISO-week APT_CACHE_BUST value the candidate
# workflow passes whenever the Dockerfile declares ARG APT_CACHE_BUST. Without
# this, an accepted image could be reused forever across week boundaries and
# silently bypass the repository's intentional package-refresh mechanism.
#
# This is a source/build-input equivalence fingerprint, not a claim that a
# fresh rebuild at an arbitrary later date would be byte-identical. Reuse is
# allowed only for a previously accepted digest and only when this fingerprint
# plus the repository path classifier both prove the relevant inputs unchanged.
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

# Keep the Dockerfile path explicit even though it normally lives inside the
# context tree. This catches an accidental catalog/context mismatch and makes
# the proof reviewable without reverse engineering the tree.
source_oid="$(git -C "$repo_root" rev-parse "${source_sha}:${source_path}" 2>/dev/null)" \
    || ci_ai_fail "Dockerfile $source_path does not exist at $source_sha for $service"
[[ "$source_oid" =~ ^[0-9a-f]{40,64}$ ]] || ci_ai_fail "invalid git object id for $service Dockerfile: $source_oid"

dockerfile_text="$(git -C "$repo_root" show "${source_sha}:${source_path}")" \
    || ci_ai_fail "could not read Dockerfile $source_path at $source_sha"

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

refresh_inputs='{}'
if grep -Eq '^ARG[[:space:]]+APT_CACHE_BUST(=|[[:space:]]|$)' <<<"$dockerfile_text"; then
    # Must remain byte-identical to ci-artifact-v2.yml's build-args step.
    apt_cache_bust="$(date -u +%G-W%V)"
    refresh_inputs="$(jq -cn --arg value "$apt_cache_bust" '{APT_CACHE_BUST:$value}')"
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
    --argjson refresh_inputs "$refresh_inputs" \
    '{
      schema:$schema,
      scope:$scope,
      service:$service,
      image:$image,
      dockerfile:{path:$source,git_oid:$source_oid},
      context:{path:$context,git_oid:$context_oid},
      named_contexts:($named | sort_by(.name,.path)),
      refresh_inputs:$refresh_inputs
    }')"

fingerprint="$(printf '%s' "$material" | sha256sum | awk '{print $1}')"
printf 'sha256:%s\n' "$fingerprint"
