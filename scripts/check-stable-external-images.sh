#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Stable-release gate: every external (third-party) image referenced by the
# prod/quickstart deploy profiles must be declared in release/stack-images.yml
# and pinned by an immutable sha256 digest before a stable release can move
# the "latest" channel. Exits non-zero and prints ::error:: lines for CI when
# an image is missing from the manifest or not digest-pinned.
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

policy_for_image() {
  local needle=$1 _name image policy

  while IFS=$'\t' read -r _name image policy; do
    if [[ "$needle" = "$image" || "$needle" = "$image"@sha256:* ]]; then
      printf '%s\n' "$policy"
      return 0
    fi
  done <<<"$external_rows"

  return 1
}

failed=0
first_party_image_prefix='${LANCACHE_IMAGE_REGISTRY:-'
while IFS= read -r match; do
  location=${match%%:*}
  rest=${match#*:}
  line_no=${rest%%:*}
  line=${rest#*:}
  read -r _ image _ <<<"$line"

  case "$image" in
    "$first_party_image_prefix"*)
      continue
      ;;
  esac

  if ! policy=$(policy_for_image "$image"); then
    printf '::error::Stable release gate: external image %s:%s (%s) is not listed in release/stack-images.yml.\n' \
      "$location" "$line_no" "$image" >&2
    failed=1
    continue
  fi

  if [[ "$image" != *@sha256:* ]]; then
    printf '::error::Stable release gate: external image %s:%s (%s) is not pinned by immutable digest. Policy: %s.\n' \
      "$location" "$line_no" "$image" "$policy" >&2
    failed=1
  fi
done < <(grep -RInE '^[[:space:]]+image:[[:space:]]+' "$repo_root/deploy/prod" "$repo_root/deploy/quickstart")

if [[ "$failed" = "1" ]]; then
  fail "stable releases require external images in supported profiles to be pinned by digest, mirrored, or explicitly removed from the stable profile"
fi

printf 'check-stable-external-images: stable external image gate passed\n'
