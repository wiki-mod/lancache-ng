#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: bounded retry for authenticated read-only GitHub REST GETs, with an
# optional TTL file cache in front of the retry loop.
# Why: separate from the registry helper since API GETs need no login
# recovery; the token goes to curl via stdin, never argv or diagnostics.
# From: Issue #1095 | PR #1501.

if [[ -n "${GITHUB_API_RETRY_SH_LOADED:-}" ]]; then
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 0
  fi
  return 0
fi
GITHUB_API_RETRY_SH_LOADED=1

GITHUB_API_RETRY_ATTEMPTS="${GITHUB_API_RETRY_ATTEMPTS:-4}"
GITHUB_API_RETRY_DELAY_SECONDS="${GITHUB_API_RETRY_DELAY_SECONDS:-5}"
GITHUB_API_HTTP_STATUS=""
# What: optional TTL file cache for successful GET responses, keyed by URL.
# Why: repeated report runs close together (e.g. two PRs' synchronize-
# triggered audits) would otherwise re-fetch identical, unchanged GHCR pages
# and burn shared rate-limit budget. Disabled (empty dir) by default.
# From: Issue #1095 | PR #1501.
GITHUB_API_CACHE_DIR="${GITHUB_API_CACHE_DIR:-}"
GITHUB_API_CACHE_TTL_SECONDS="${GITHUB_API_CACHE_TTL_SECONDS:-600}"

_github_api_cache_path() {
  local url="${1:?_github_api_cache_path: url is required}"
  command -v sha256sum >/dev/null 2>&1 || return 1
  local digest
  digest="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/%s.json\n' "$GITHUB_API_CACHE_DIR" "$digest"
}

_github_api_cache_hit() {
  # What: checks for a fresh (within TTL), non-empty cached response.
  # Why: mtime-based freshness lets a cache directory be safely reused across
  # runs (e.g. restored by actions/cache) without serving stale data.
  # From: Issue #1095 | PR #1501.
  local url="${1:?_github_api_cache_hit: url is required}"
  local body_file="${2:?_github_api_cache_hit: body file is required}"
  [[ -n "$GITHUB_API_CACHE_DIR" ]] || return 1
  local cache_file age_seconds now mtime
  cache_file="$(_github_api_cache_path "$url")" || return 1
  [[ -s "$cache_file" ]] || return 1
  now="$(date +%s)" || return 1
  # What: reads mtime with GNU stat's `-c` form only, no BSD `stat -f` branch.
  # Why: this project's build-tools image stays Debian-based (AG-KD-009), so
  # a BSD fallback would be untested, unreachable dead code.
  # From: Issue #1095 | PR #1501.
  mtime="$(stat -c %Y "$cache_file" 2>/dev/null)" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  age_seconds=$(( now - mtime ))
  (( age_seconds >= 0 && age_seconds < GITHUB_API_CACHE_TTL_SECONDS )) || return 1
  cp -- "$cache_file" "$body_file"
}

_github_api_cache_store() {
  # What: writes the successful GET's body into the cache, best-effort.
  # Why: caching is a rate-limit optimization, never a correctness
  # requirement, so a write failure must not fail the GET that already
  # succeeded.
  # From: Issue #1095 | PR #1501.
  local url="${1:?_github_api_cache_store: url is required}"
  local body_file="${2:?_github_api_cache_store: body file is required}"
  [[ -n "$GITHUB_API_CACHE_DIR" ]] || return 0
  local cache_file
  cache_file="$(_github_api_cache_path "$url")" || return 0
  mkdir -p -- "$GITHUB_API_CACHE_DIR" 2>/dev/null || return 0
  cp -- "$body_file" "$cache_file" 2>/dev/null || true
}

_github_api_get_once() {
  local url="${1:?_github_api_get_once: url is required}"
  local body_file="${2:?_github_api_get_once: body file is required}"
  : "${GH_TOKEN:?_github_api_get_once: GH_TOKEN is required}"

  command -v curl >/dev/null 2>&1 || return 127

  local header_config curl_status
  header_config="$(printf 'header = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\nheader = "Authorization: Bearer %s"\n' "$GH_TOKEN")"

  GITHUB_API_HTTP_STATUS=""
  if GITHUB_API_HTTP_STATUS="$(curl -sS --connect-timeout 10 --max-time 30 \
      -o "$body_file" -w '%{http_code}' -K - "$url" <<<"$header_config")"; then
    curl_status=0
  else
    curl_status=$?
  fi

  if (( curl_status != 0 )); then
    GITHUB_API_HTTP_STATUS=""
    return "$curl_status"
  fi

  [[ "$GITHUB_API_HTTP_STATUS" =~ ^[0-9]{3}$ ]] || return 1
  return 0
}

github_api_get_with_retry() {
  local url="${1:?github_api_get_with_retry: url is required}"
  local body_file="${2:?github_api_get_with_retry: body file is required}"

  [[ "$GITHUB_API_RETRY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::GITHUB_API_RETRY_ATTEMPTS must be a positive integer." >&2
    return 1
  }
  [[ "$GITHUB_API_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || {
    echo "::error::GITHUB_API_RETRY_DELAY_SECONDS must be a non-negative integer." >&2
    return 1
  }

  if _github_api_cache_hit "$url" "$body_file"; then
    echo "::notice::Serving GHCR API response for $url from the local rate-limit cache (age < ${GITHUB_API_CACHE_TTL_SECONDS}s)." >&2
    return 0
  fi

  local attempt call_status http_status
  for (( attempt=1; attempt<=GITHUB_API_RETRY_ATTEMPTS; attempt++ )); do
    : >"$body_file"
    if _github_api_get_once "$url" "$body_file"; then
      call_status=0
    else
      call_status=$?
    fi
    http_status="$GITHUB_API_HTTP_STATUS"

    if (( call_status == 0 )) && [[ "$http_status" == "200" ]]; then
      _github_api_cache_store "$url" "$body_file"
      return 0
    fi

    # What: fails immediately on HTTP 401/404 instead of retrying.
    # Why: retrying an auth failure or a not-found cannot establish the
    # positive proof this audit requires; treating either as retryable would
    # risk silently reading it as an empty result later.
    # From: Issue #1095 | PR #1501.
    if (( call_status == 0 )) && [[ "$http_status" == "401" || "$http_status" == "404" ]]; then
      echo "::error::GitHub REST GET failed permanently with HTTP $http_status for $url; refusing to interpret this response as an empty result." >&2
      return 1
    fi

    if (( attempt == GITHUB_API_RETRY_ATTEMPTS )); then
      if [[ -n "$http_status" ]]; then
        echo "::error::GitHub REST GET failed after $attempt attempts with HTTP $http_status for $url." >&2
      else
        echo "::error::GitHub REST GET failed after $attempt attempts with curl status $call_status for $url." >&2
      fi
      return 1
    fi

    # What: logs a mid-retry attempt as ::notice::, not ::warning::.
    # Why: a recovered transient is not a warning under this repository's
    # warnings-as-errors policy; only the exhausted-retries failure above
    # becomes an ::error::.
    # From: Issue #1095 | PR #1501.
    if [[ -n "$http_status" ]]; then
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS returned HTTP $http_status; retrying after ${GITHUB_API_RETRY_DELAY_SECONDS}s." >&2
    else
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS failed with curl status $call_status; retrying after ${GITHUB_API_RETRY_DELAY_SECONDS}s." >&2
    fi
    sleep "$GITHUB_API_RETRY_DELAY_SECONDS"
  done

  return 1
}
