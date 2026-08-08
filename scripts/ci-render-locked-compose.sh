#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Renders the full-setup Compose model with every first-party runtime image
# replaced by its exact stack-lock digest. External digest-pinned services are
# left unchanged.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: ci-render-locked-compose.sh LOCK OUTPUT" >&2; exit 2; }
lock="$1"; output="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_validate_stack_lock "$lock"

base="$repo_root/deploy/full-setup/docker-compose.yml"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
override="$work_dir/override.json"

base_json="$(LANCACHE_IMAGE_TAG=ci-lock-render docker compose -f "$base" config --format json)"
override_json='{"services":{}}'

while IFS=$'\t' read -r compose_service compose_image; do
    [[ -n "$compose_service" && -n "$compose_image" ]] || continue
    locked_ref=""
    while IFS=$'\t' read -r locked_image locked_digest; do
        if [[ "$compose_image" == "${locked_image}:"* || "$compose_image" == "${locked_image}@"* ]]; then
            ci_ai_require_digest "$locked_digest"
            locked_ref="${locked_image}@${locked_digest}"
            break
        fi
    done < <(jq -r '.runtime[] | [.image, .digest] | @tsv' "$lock")
    if [[ -n "$locked_ref" ]]; then
        override_json="$(jq -c --arg service "$compose_service" --arg image "$locked_ref" '.services[$service].image = $image' <<<"$override_json")"
    fi
done < <(jq -r '.services | to_entries[] | [.key, (.value.image // "")] | @tsv' <<<"$base_json")

runtime_count="$(jq '.runtime | length' "$lock")"
overridden_images="$(jq '[.services[] | select(.image != null)] | length' <<<"$override_json")"
[[ "$overridden_images" -ge "$runtime_count" ]] \
    || ci_ai_fail "only $overridden_images compose services were digest-locked for $runtime_count runtime images"

printf '%s\n' "$override_json" >"$override"
mkdir -p "$(dirname "$output")"
LANCACHE_IMAGE_TAG=ci-lock-render docker compose -f "$base" -f "$override" config >"$output"

rendered_json="$(docker compose -f "$output" config --format json)"
while IFS= read -r image; do
    [[ "$image" == *@sha256:* ]] \
        || ci_ai_fail "rendered first-party image is not digest-qualified: $image"
done < <(jq -r '.services[].image // empty | select(startswith("ghcr.io/wiki-mod/lancache-ng/"))' <<<"$rendered_json")
