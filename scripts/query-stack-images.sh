#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Emits the first-party image build matrix from release/stack-images.yml.
# The release manifest remains the service catalog. Context paths are derived
# from each declared Dockerfile, so workflows do not carry another service list.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${STACK_IMAGES_MANIFEST:-$repo_root/release/stack-images.yml}"
scope="${1:-all}"

case "$scope" in
    runtime|tooling|all) ;;
    *) printf 'query-stack-images: invalid scope %s\n' "$scope" >&2; exit 2 ;;
esac

[[ -f "$manifest" ]] || { printf 'query-stack-images: missing manifest %s\n' "$manifest" >&2; exit 1; }

records="$(
  awk '
    function flush() {
      if (section != "" && name != "") {
        print section "\t" name "\t" image "\t" source "\t" platforms
      }
      name=""; image=""; source=""; platforms=""; in_platforms=0
    }
    /^(runtime|tooling):$/ {
      flush()
      section=$0
      sub(/:$/, "", section)
      next
    }
    section != "" && /^[a-zA-Z0-9_-]+:$/ {
      flush()
      section=""
      next
    }
    section != "" && /^  - name: / {
      flush()
      name=$0
      sub(/^  - name: /, "", name)
      next
    }
    section != "" && /^    image: / {
      image=$0
      sub(/^    image: /, "", image)
      next
    }
    section != "" && /^    source: / {
      source=$0
      sub(/^    source: /, "", source)
      next
    }
    section != "" && /^    platforms:/ {
      in_platforms=1
      next
    }
    section != "" && in_platforms && /^      - / {
      value=$0
      sub(/^      - /, "", value)
      if (platforms != "") platforms=platforms ","
      platforms=platforms value
      next
    }
    section != "" && in_platforms && /^    [^ ]/ {
      in_platforms=0
    }
    END { flush() }
  ' "$manifest"
)"

[[ -n "$records" ]] || { echo "query-stack-images: manifest yielded no runtime/tooling images" >&2; exit 1; }

matrix='[]'
while IFS=$'\t' read -r record_scope service image source platforms; do
    [[ -n "$service" ]] || continue
    if [[ "$scope" != all && "$record_scope" != "$scope" ]]; then
        continue
    fi
    [[ -n "$image" && -n "$source" && -n "$platforms" ]] \
        || { printf 'query-stack-images: incomplete manifest entry for %s\n' "$service" >&2; exit 1; }
    dockerfile="$repo_root/$source"
    [[ -f "$dockerfile" ]] \
        || { printf 'query-stack-images: Dockerfile not found for %s: %s\n' "$service" "$source" >&2; exit 1; }
    context="$(dirname "$source")"
    build_contexts=""
    if grep -Eq 'COPY[[:space:]].*--from=dns-domains([[:space:]]|$)' "$dockerfile"; then
        [[ -d "$repo_root/services/dns" ]] \
            || { echo "query-stack-images: dns-domains named context has no services/dns directory" >&2; exit 1; }
        build_contexts="dns-domains=services/dns"
    fi
    matrix="$(
      jq -c \
        --arg scope "$record_scope" \
        --arg service "$service" \
        --arg image "$image" \
        --arg source "$source" \
        --arg context "$context" \
        --arg build_contexts "$build_contexts" \
        --arg platforms "$platforms" \
        '. + [{
          scope: $scope,
          service: $service,
          image: $image,
          source: $source,
          context: $context,
          build_contexts: $build_contexts,
          platforms: ($platforms | split(","))
        }]' <<<"$matrix"
    )"
done <<<"$records"

jq -c '{include: .}' <<<"$matrix"
