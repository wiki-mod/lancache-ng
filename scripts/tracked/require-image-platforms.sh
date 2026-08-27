#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
source "$script_dir/../lib/ghcr-retry.sh"

# docker buildx imagetools prints single-platform images differently from
# multi-platform indexes. Current lancache-ng prebuilt images are amd64-only,
# so first read the single-platform image fields. If those are not populated,
# fall back to the plain multi-platform "Platform:" lines. This deliberately
# avoids external JSON parsers because release/promotion jobs run directly on
# self-hosted runners.
#
# stderr is captured to a scratch file per call, not merged in via a second
# `2>&1` on the command substitution: ghcr_retry itself writes retry/relogin
# diagnostics ("::warning::...", "Login Succeeded") to stderr on every failed
# attempt before a later attempt succeeds (scripts/lib/ghcr-retry.sh), so a
# `2>&1` capture would splice that noise into what this script treats as the
# real inspect output -- caught live: a single transient 403 on attempt 1
# followed by a successful attempt 2 left $single_platform holding the retry
# warning text concatenated with the real "<no value>/<no value>" result,
# which then failed the exact-string check below and reported a present
# platform as missing. Same stdout/stderr-separation fix already applied to
# scripts/lib/staging-image-freshness.sh's _sif_inspect for the identical
# reason.
single_platform_err="$(mktemp)" || fail "Failed to create a scratch file for $image inspect diagnostics."
# `if var=$(cmd); then status=0; else status=$?; fi`, not a bare
# `var=$(cmd); status=$?` split across two statements: under this script's
# own `set -e`, a plain assignment statement is NOT exempt the way an
# `if`/`||`-guarded one is -- a failing command substitution on its own line
# aborts the script right there, before the status-capture line beneath it
# ever runs, so `fail` never fires and the script exits silently with no
# diagnostic at all. Same reasoning as ghcr_retry's own `if "$@"; then ...`
# in scripts/lib/ghcr-retry.sh.
if single_platform="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$image" --format '{{if .Image}}{{.Image.OS}}/{{.Image.Architecture}}{{end}}' 2>"$single_platform_err")"; then
  single_platform_status=0
else
  single_platform_status=$?
fi
single_platform_err_text="$(cat "$single_platform_err" 2>/dev/null)"
rm -f "$single_platform_err"
(( single_platform_status == 0 )) \
  || fail "Failed to inspect image platform for $image: $single_platform_err_text"

if [[ -n "$single_platform" && "$single_platform" != "<no value>/<no value>" && "$single_platform" != "unknown/unknown" ]]; then
  discovered_platforms="$single_platform"
else
  inspect_text_err="$(mktemp)" || fail "Failed to create a scratch file for $image inspect diagnostics."
  if inspect_text="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$image" 2>"$inspect_text_err")"; then
    inspect_text_status=0
  else
    inspect_text_status=$?
  fi
  inspect_text_err_text="$(cat "$inspect_text_err" 2>/dev/null)"
  rm -f "$inspect_text_err"
  (( inspect_text_status == 0 )) \
    || fail "Failed to inspect image manifest for $image: $inspect_text_err_text"
  discovered_platforms="$(printf '%s\n' "$inspect_text" | awk '$1 == "Platform:" && $2 != "unknown/unknown" { print $2 }' | sort -u)"
fi

[[ -n "$discovered_platforms" ]] \
  || fail "$image did not expose any usable platform metadata."

for expected in $(printf '%s\n' "$required_platforms" | tr ',' ' '); do
  # Here-string, not a live pipe into grep -q -- $discovered_platforms can
  # list several platforms (issue #1377's repo-wide pipefail/SIGPIPE audit).
  if ! grep -Eq "^${expected}(/.*)?$" <<<"$discovered_platforms"; then
    fail "$image is missing required platform $expected; discovered: ${discovered_platforms//$'\n'/, }"
  fi
done

printf 'require-image-platforms: %s has all required platforms (%s)\n' "$image" "$required_platforms"
