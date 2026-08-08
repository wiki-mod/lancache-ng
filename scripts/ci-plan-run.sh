#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces one matrix row per service/platform. A service is reused only when
# an accepted baseline lock exists, the baseline source is an ancestor of the
# candidate source, classify-image-impact proves that service unchanged, and
# the accepted lock contains both required child digests. Any uncertainty builds.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_sha="${SOURCE_SHA:-${GITHUB_SHA:-}}"
baseline_lock="${BASELINE_STACK_LOCK:-}"
catalog="$("$repo_root/scripts/query-stack-images.sh" all)"

source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_require_sha "$source_sha"

classification=""
baseline_usable=false
baseline_sha=""
if [[ -n "$baseline_lock" && -f "$baseline_lock" ]]; then
    ci_ai_validate_stack_lock "$baseline_lock"
    baseline_sha="$(jq -r '.source_sha' "$baseline_lock")"
    if git cat-file -e "${baseline_sha}^{commit}" 2>/dev/null \
        && git merge-base --is-ancestor "$baseline_sha" "$source_sha"; then
        classification="$("$repo_root/scripts/classify-image-impact.sh" "$baseline_sha" "$source_sha")"
        baseline_usable=true
    else
        echo "::notice::Accepted baseline source $baseline_sha is not a usable ancestor of $source_sha; building every image." >&2
    fi
fi

rows='[]'
while IFS= read -r entry; do
    service="$(jq -r '.service' <<<"$entry")"
    entry_scope="$(jq -r '.scope' <<<"$entry")"
    image="$(jq -r '.image' <<<"$entry")"
    source_path="$(jq -r '.source' <<<"$entry")"
    context="$(jq -r '.context' <<<"$entry")"
    build_contexts="$(jq -r '.build_contexts' <<<"$entry")"

    mode=build
    if [[ "$baseline_usable" == true ]]; then
        key="${service//-/_}"
        changed="$(awk -F= -v key="$key" '$1 == key { print $2; exit }' <<<"$classification")"
        if [[ -z "$changed" ]]; then
            changed="$(awk -F= -v key="${key}_image" '$1 == key { print $2; exit }' <<<"$classification")"
        fi
        if [[ "$changed" == false ]]; then
            if jq -e --arg scope "$entry_scope" --arg service "$service" '
                .[$scope][$service].digest
                and .[$scope][$service].artifact_source_sha
                and .[$scope][$service].platforms["linux/amd64"]
                and .[$scope][$service].platforms["linux/arm64"]
              ' "$baseline_lock" >/dev/null; then
                mode=reuse
            fi
        fi
    fi

    for platform in linux/amd64 linux/arm64; do
        arch="$(ci_ai_arch_from_platform "$platform")"
        if [[ "$platform" == linux/amd64 ]]; then
            runner='["self-hosted","linux","lancache","lancache-heavy"]'
        else
            runner='"ubuntu-24.04-arm"'
        fi
        reused_digest=""
        artifact_source_sha="$source_sha"
        if [[ "$mode" == reuse ]]; then
            reused_digest="$(jq -r --arg scope "$entry_scope" --arg service "$service" --arg platform "$platform" '.[$scope][$service].platforms[$platform]' "$baseline_lock")"
            artifact_source_sha="$(jq -r --arg scope "$entry_scope" --arg service "$service" '.[$scope][$service].artifact_source_sha' "$baseline_lock")"
            ci_ai_require_digest "$reused_digest"
            ci_ai_require_sha "$artifact_source_sha"
        fi
        row="$(
          jq -cn \
            --arg scope "$entry_scope" \
            --arg service "$service" \
            --arg image "$image" \
            --arg source "$source_path" \
            --arg context "$context" \
            --arg build_contexts "$build_contexts" \
            --arg platform "$platform" \
            --arg arch "$arch" \
            --arg mode "$mode" \
            --arg reused_digest "$reused_digest" \
            --arg artifact_source_sha "$artifact_source_sha" \
            --argjson runner "$runner" \
            '{
              scope: $scope,
              service: $service,
              image: $image,
              source: $source,
              context: $context,
              build_contexts: $build_contexts,
              platform: $platform,
              arch: $arch,
              mode: $mode,
              reused_digest: $reused_digest,
              artifact_source_sha: $artifact_source_sha,
              runner: $runner
            }'
        )"
        rows="$(jq -c --argjson row "$row" '. + [$row]' <<<"$rows")"
    done
done < <(jq -c '.include[]' <<<"$catalog")

jq -c \
  --arg source_sha "$source_sha" \
  --arg baseline_sha "$baseline_sha" \
  --argjson baseline_usable "$baseline_usable" \
  '{source_sha: $source_sha, baseline_sha: $baseline_sha, baseline_usable: $baseline_usable, include: .}' \
  <<<"$rows"
