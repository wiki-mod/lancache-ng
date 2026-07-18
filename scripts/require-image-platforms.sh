#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Shared release/promotion guard: inspects a published image with
# `docker buildx imagetools` and fails closed if it does not expose all of
# the given comma-separated required platforms. Avoids external JSON parsers
# since this runs directly on self-hosted release/promotion runners.
set -euo pipefail

image=${1:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}
required_platforms=${2:?usage: require-image-platforms.sh <image> <comma-separated-platforms>}

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

# #822: GHCR_RETRY_USERNAME/GHCR_RETRY_PASSWORD are optional -- every call
# site wired up after the "Pattern D" fix passes them (the same
# github.actor/GITHUB_TOKEN the caller's own "Log in to GHCR" step already
# used), so a transient GHCR 401 here retries with a fresh login instead of
# failing a promotion/release job outright. A caller that leaves them unset
# (this script is also documented as safe to run ad hoc directly on a
# release/promotion runner) still gets ghcr_retry's backoff+retry, just
# without the relogin step -- see ghcr_retry's own comment in
# scripts/lib/ghcr-retry.sh.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"

# docker buildx imagetools prints single-platform images differently from
# multi-platform indexes. Current lancache-ng prebuilt images are amd64-only,
# so first read the single-platform image fields. If those are not populated,
# fall back to the plain multi-platform "Platform:" lines. This deliberately
# avoids external JSON parsers because release/promotion jobs run directly on
# self-hosted runners.
single_platform="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$image" --format '{{if .Image}}{{.Image.OS}}/{{.Image.Architecture}}{{end}}' 2>&1)" \
  || fail "Failed to inspect image platform for $image: $single_platform"

if [[ -n "$single_platform" && "$single_platform" != "<no value>/<no value>" && "$single_platform" != "unknown/unknown" ]]; then
  discovered_platforms="$single_platform"
else
  inspect_text="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$image" 2>&1)" \
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
