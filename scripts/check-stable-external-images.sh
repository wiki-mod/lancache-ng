#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
manifest=${1:-"$repo_root/release/stack-images.yml"}

fail() {
  printf 'check-stable-external-images: %s\n' "$1" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "missing manifest: $manifest"

external_rows=$(
  awk '
    function emit() {
      if (name != "") {
        printf "%s\t%s\t%s\n", name, image, policy
      }
    }

    $0 == "external:" { in_external=1; next }
    in_external && /^[[:alnum:]_-]+:/ { emit(); in_external=0; next }
    in_external && /^  - name: / {
      emit()
      name=$0
      sub(/^  - name: /, "", name)
      image=""
      policy=""
      next
    }
    in_external && /^    image: / {
      image=$0
      sub(/^    image: /, "", image)
      next
    }
    in_external && /^    policy: / {
      policy=$0
      sub(/^    policy: /, "", policy)
      next
    }
    END { emit() }
  ' "$manifest"
)

if [[ -z "$external_rows" ]]; then
  fail "manifest has no external image rows"
fi

failed=0
while IFS=$'\t' read -r name image policy; do
  [[ -n "$name" && -n "$image" && -n "$policy" ]] \
    || fail "external image entry is incomplete: name=${name:-}, image=${image:-}, policy=${policy:-}"

  matches=$(grep -RInF "image: $image" "$repo_root/deploy/prod" "$repo_root/deploy/quickstart" 2>/dev/null || true)
  if [[ -z "$matches" ]]; then
    continue
  fi

  if [[ "$image" != *@sha256:* ]]; then
    printf '::error::Stable release gate: external image %s (%s) uses %s without an immutable digest. Policy: %s.\n' \
      "$name" "$image" "$(printf '%s\n' "$matches" | paste -sd ',' -)" "$policy" >&2
    failed=1
  fi
done <<<"$external_rows"

if [[ "$failed" = "1" ]]; then
  fail "stable releases require external images in supported profiles to be pinned by digest, mirrored, or explicitly removed from the stable profile"
fi

printf 'check-stable-external-images: stable external image gate passed\n'
