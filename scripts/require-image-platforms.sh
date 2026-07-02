#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}
required_platforms=${2:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

# docker buildx imagetools inspect's plain-text output only prints a
# "Platform:" line per entry for multi-platform manifest lists. A
# single-platform image (the current amd64-only release contract) has no
# manifest list to enumerate, so that text-based check silently discovers
# zero platforms and rejects every valid image. --format '{{json .}}' avoids
# this: `.image` is a flat object (with .architecture/.os) for a
# single-platform image, or a map keyed by "os/arch" platform strings for a
# multi-platform manifest list — either way this covers current amd64-only
# releases and any future multi-platform (e.g. arm64) release without
# further changes here.
inspect_json="$(docker buildx imagetools inspect "$image" --format '{{json .}}' 2>&1)" \
  || fail "Failed to inspect image manifest for $image: $inspect_json"

discovered_platforms="$(
  printf '%s' "$inspect_json" | jq -r '
    if (.image | type) == "object" and (.image | has("architecture")) then
      "\(.image.os)/\(.image.architecture)"
    else
      (.image // {} | keys[])
    end
  '
)"

for expected in $(printf '%s\n' "$required_platforms" | tr ',' ' '); do
  if ! printf '%s\n' "$discovered_platforms" | grep -Eq "^${expected}(/.*)?$"; then
    fail "$image is missing required platform $expected; discovered: ${discovered_platforms//$'\n'/, }"
  fi
done

printf 'require-image-platforms: %s has all required platforms (%s)\n' "$image" "$required_platforms"
