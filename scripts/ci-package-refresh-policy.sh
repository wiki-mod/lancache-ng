#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Reports whether a first-party Dockerfile resolves packages from a mutable
# distribution repository and whether that Dockerfile already consumes the
# project's weekly APT_CACHE_BUST input inside the package layer. V2 uses the
# latter distinction to retain surgical layer caching where supported and to
# fall back to a no-cache build when package freshness otherwise cannot be
# proven.
set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "usage: ci-package-refresh-policy.sh SERVICE SOURCE_SHA" >&2
    exit 2
}
service="$1"
source_sha="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/ci-artifact-identity.sh"
ci_ai_require_sha "$source_sha"

catalog="$(bash "$repo_root/scripts/query-stack-images.sh" all)"
entry="$(jq -c --arg service "$service" '.include[] | select(.service == $service)' <<<"$catalog")"
[[ -n "$entry" ]] || ci_ai_fail "service is not present in canonical image catalog: $service"
source_path="$(jq -r '.source' <<<"$entry")"
dockerfile_text="$(git -C "$repo_root" show "${source_sha}:${source_path}")" \
    || ci_ai_fail "could not read Dockerfile $source_path at $source_sha"

# Comments document package commands extensively in this repository. Exclude
# them before detecting actual Dockerfile instruction/continuation text so a
# documentation-only mention cannot create a false weekly rebuild requirement.
active_text="$(sed '/^[[:space:]]*#/d' <<<"$dockerfile_text")"
refresh_required=false
if grep -Eiq '(^|[;&|[:space:]\\])((apt-get|apt)[[:space:]]+(update|install|upgrade|dist-upgrade|full-upgrade)|apk[[:space:]]+(update|add|upgrade))([;&|[:space:]\\]|$)' <<<"$active_text"; then
    refresh_required=true
fi

arg_declared=false
arg_consumed=false
if grep -Eq '^ARG[[:space:]]+APT_CACHE_BUST(=|[[:space:]]|$)' <<<"$active_text"; then
    arg_declared=true
fi
if grep -Fq '${APT_CACHE_BUST}' <<<"$active_text"; then
    arg_consumed=true
fi

native_cache_bust=false
if [[ "$refresh_required" == true && "$arg_declared" == true && "$arg_consumed" == true ]]; then
    native_cache_bust=true
fi

force_no_cache=false
if [[ "$refresh_required" == true && "$native_cache_bust" != true ]]; then
    force_no_cache=true
fi

jq -cn \
    --argjson refresh_required "$refresh_required" \
    --argjson native_cache_bust "$native_cache_bust" \
    --argjson force_no_cache "$force_no_cache" \
    '{refresh_required:$refresh_required,native_cache_bust:$native_cache_bust,force_no_cache:$force_no_cache}'
