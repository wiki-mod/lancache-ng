#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}
required_platforms=${2:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

# docker buildx imagetools prints single-platform images differently from
# multi-platform indexes. Current lancache-ng prebuilt images are amd64-only,
# so first read the single-platform image fields. If those are not populated,
# fall back to the plain multi-platform "Platform:" lines. This deliberately
# avoids external JSON parsers because release/promotion jobs run directly on
# self-hosted runners.
single_platform="$(docker buildx imagetools inspect "$image" --format '{{if .Image}}{{.Image.OS}}/{{.Image.Architecture}}{{end}}' 2>&1)" \
  || fail "Failed to inspect image platform for $image: $single_platform"

if [[ -n "$single_platform" && "$single_platform" != "<no value>/<no value>" && "$single_platform" != "unknown/unknown" ]]; then
  discovered_platforms="$single_platform"
else
  inspect_text="$(docker buildx imagetools inspect "$image" 2>&1)" \
    || fail "Failed to inspect image manifest for $image: $inspect_text"
  discovered_platforms="$(printf '%s\n' "$inspect_text" | awk '$1 == "Platform:" && $2 != "unknown/unknown" { print $2 }' | sort -u)"
fi

[[ -n "$discovered_platforms" ]] \
  || fail "$image did not expose any usable platform metadata."

for expected in $(printf '%s\n' "$required_platforms" | tr ',' ' '); do
  if ! printf '%s\n' "$discovered_platforms" | grep -Eq "^${expected}(/.*)?$"; then
    fail "$image is missing required platform $expected; discovered: ${discovered_platforms//$'\n'/, }"
  fi
done

printf 'require-image-platforms: %s has all required platforms (%s)\n' "$image" "$required_platforms"
