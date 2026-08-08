#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Produces one matrix row per service/platform. Reuse requires accepted identity,
# source/path equivalence and identical frozen external build inputs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_sha="${SOURCE_SHA:-${GITHUB_SHA:-}}"
baseline_lock="${BASELINE_STACK_LOCK:-}"
catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"

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
        classification="$(bash "$repo_root/scripts/classify-image-impact.sh" "$baseline_sha" "$source_sha")"
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
    catalog_build_contexts="$(jq -r '.build_contexts' <<<"$entry")"

    build_inputs="$(bash "$repo_root/scripts/ci-build-inputs.sh" "$service" json)"
    build_args="$(bash "$repo_root/scripts/ci-build-inputs.sh" "$service" build-args)"
    external_build_contexts="$(bash "$repo_root/scripts/ci-build-inputs.sh" "$service" build-contexts)"
    build_contexts="$catalog_build_contexts"
    if [[ -n "$external_build_contexts" ]]; then
        if [[ -n "$build_contexts" ]]; then
            build_contexts+=$'\n'
        fi
        build_contexts+="$external_build_contexts"
    fi

    source_fingerprint="$(
        CI_SOURCE_BUILD_INPUTS_JSON="$build_inputs" \
            bash "$repo_root/scripts/ci-source-fingerprint.sh" "$service" "$source_sha"
    )"
    ci_ai_require_digest "$source_fingerprint"

    mode=build
    reused_index_digest=""
    if [[ "$baseline_usable" == true ]]; then
        key="${service//-/_}"
        changed="$(awk -F= -v key="$key" '$1 == key { print $2; exit }' <<<"$classification")"
        if [[ -z "$changed" ]]; then
            changed="$(awk -F= -v key="${key}_image" '$1 == key { print $2; exit }' <<<"$classification")"
        fi

        baseline_fingerprint="$(jq -r --arg scope "$entry_scope" --arg service "$service" '.[$scope][$service].source_fingerprint // empty' "$baseline_lock")"
        if [[ "$changed" == false && "$baseline_fingerprint" == "$source_fingerprint" ]]; then
            if jq -e --arg scope "$entry_scope" --arg service "$service" '
                .[$scope][$service].digest
                and .[$scope][$service].artifact_source_sha
                and .[$scope][$service].source_fingerprint
                and (.[$scope][$service].build_inputs | type == "object")
                and .[$scope][$service].platforms["linux/amd64"]
                and .[$scope][$service].platforms["linux/arm64"]
              ' "$baseline_lock" >/dev/null; then
                reused_index_digest="$(jq -r --arg scope "$entry_scope" --arg service "$service" '.[$scope][$service].digest' "$baseline_lock")"
                ci_ai_require_digest "$reused_index_digest"
                mode=reuse
            fi
        elif [[ "$changed" == false && -n "$baseline_fingerprint" ]]; then
            echo "::notice::$service path classification is unchanged but effective build fingerprint differs; rebuilding fail-closed." >&2
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
            ci_ai_require_digest "$reused_index_digest"
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
            --arg build_args "$build_args" \
            --argjson build_inputs "$build_inputs" \
            --arg platform "$platform" \
            --arg arch "$arch" \
            --arg mode "$mode" \
            --arg reused_digest "$reused_digest" \
            --arg reused_index_digest "$reused_index_digest" \
            --arg artifact_source_sha "$artifact_source_sha" \
            --arg source_fingerprint "$source_fingerprint" \
            --argjson runner "$runner" \
            '{
              scope: $scope,
              service: $service,
              image: $image,
              source: $source,
              context: $context,
              build_contexts: $build_contexts,
              build_args: $build_args,
              build_inputs: $build_inputs,
              platform: $platform,
              arch: $arch,
              mode: $mode,
              reused_digest: $reused_digest,
              reused_index_digest: $reused_index_digest,
              artifact_source_sha: $artifact_source_sha,
              source_fingerprint: $source_fingerprint,
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
