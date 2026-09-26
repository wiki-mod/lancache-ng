#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Retry mechanism for GitHub API reads with TTL cache
# Why: API reads need no login recovery; token protected via stdin
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
GITHUB_API_MAX_RETRY_DELAY_SECONDS="${GITHUB_API_MAX_RETRY_DELAY_SECONDS:-60}"
GITHUB_API_HTTP_STATUS=""
GITHUB_API_RETRY_AFTER=""
GITHUB_API_RATE_LIMIT_REMAINING=""
GITHUB_API_RATE_LIMIT_RESET=""
# What: TTL file cache for successful GET responses, keyed by URL
# Why: Reusing cache across runs avoids rate-limit exhaustion
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
  # What: Checks for fresh, non-empty cached response within TTL
  # Why: mtime-based freshness allows safe cache reuse across runs
  # From: Issue #1095 | PR #1501.
  local url="${1:?_github_api_cache_hit: url is required}"
  local body_file="${2:?_github_api_cache_hit: body file is required}"
  [[ -n "$GITHUB_API_CACHE_DIR" ]] || return 1
  local cache_file age_seconds now mtime
  cache_file="$(_github_api_cache_path "$url")" || return 1
  [[ -s "$cache_file" ]] || return 1
  now="$(date +%s)" || return 1
  # What: Reads cache mtime with the build-tools stat interface
  # Why: The supported build-tools image provides GNU-compatible stat
  # From: Issue #1095 | PR #1501.
  mtime="$(stat -c %Y "$cache_file" 2>/dev/null)" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  age_seconds=$(( now - mtime ))
  (( age_seconds >= 0 && age_seconds < GITHUB_API_CACHE_TTL_SECONDS )) || return 1
  cp -- "$cache_file" "$body_file"
}

_github_api_cache_store() {
  # What: Writes successful GET body to cache, best-effort
  # Why: Caching optimizes rate-limit; write failure is non-fatal
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
  local accept="${3:-application/vnd.github+json}"

  command -v curl >/dev/null 2>&1 || return 127

  local header_config curl_status headers_file github_token
  headers_file="$(mktemp "${TMPDIR:-/var/tmp}/github-api-headers.XXXXXX")" || return 1
  header_config="$(printf 'header = "Accept: %s"\nheader = "X-GitHub-Api-Version: 2022-11-28"' "$accept")"
  github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$github_token" ]]; then
    printf -v header_config '%s\nheader = "Authorization: Bearer %s"' "$header_config" "$github_token"
  fi

  GITHUB_API_HTTP_STATUS=""
  GITHUB_API_RETRY_AFTER=""
  GITHUB_API_RATE_LIMIT_REMAINING=""
  GITHUB_API_RATE_LIMIT_RESET=""
  if GITHUB_API_HTTP_STATUS="$(curl -sS --connect-timeout 10 --max-time 30 \
      --location -D "$headers_file" -o "$body_file" -w '%{http_code}' \
      -K - "$url" <<<"$header_config")"; then
    curl_status=0
  else
    curl_status=$?
  fi

  GITHUB_API_RETRY_AFTER="$(awk -F ': *' 'tolower($1) == "retry-after" { value=$2 } END { sub(/\r$/, "", value); print value }' "$headers_file")"
  GITHUB_API_RATE_LIMIT_REMAINING="$(awk -F ': *' 'tolower($1) == "x-ratelimit-remaining" { value=$2 } END { sub(/\r$/, "", value); print value }' "$headers_file")"
  GITHUB_API_RATE_LIMIT_RESET="$(awk -F ': *' 'tolower($1) == "x-ratelimit-reset" { value=$2 } END { sub(/\r$/, "", value); print value }' "$headers_file")"
  rm -f -- "$headers_file"

  if (( curl_status != 0 )); then
    GITHUB_API_HTTP_STATUS=""
    return "$curl_status"
  fi

  [[ "$GITHUB_API_HTTP_STATUS" =~ ^[0-9]{3}$ ]] || return 1
  return 0
}

_github_api_retry_delay() {
  local attempt="${1:?_github_api_retry_delay: attempt is required}"
  local http_status="${2:?_github_api_retry_delay: HTTP status is required}"
  local delay="$GITHUB_API_RETRY_DELAY_SECONDS" candidate now multiplier

  if [[ "$http_status" == "403" || "$http_status" == "429" ]]; then
    if [[ "$GITHUB_API_RETRY_AFTER" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$GITHUB_API_RETRY_AFTER"
      return 0
    elif [[ "$GITHUB_API_RATE_LIMIT_REMAINING" == "0" && "$GITHUB_API_RATE_LIMIT_RESET" =~ ^[0-9]+$ ]]; then
      now="$(date +%s)" || return 1
      candidate=$(( GITHUB_API_RATE_LIMIT_RESET - now ))
      (( candidate > 0 )) || candidate=0
    else
      candidate=60
    fi
    (( candidate > delay )) && delay="$candidate"
  fi

  multiplier=$(( 1 << (attempt - 1) ))
  delay=$(( delay * multiplier ))
  (( delay > GITHUB_API_MAX_RETRY_DELAY_SECONDS )) && delay="$GITHUB_API_MAX_RETRY_DELAY_SECONDS"

  printf '%s\n' "$delay"
}

_github_api_is_rate_limited() {
  local body_file="${1:?_github_api_is_rate_limited: body file is required}"
  [[ "$GITHUB_API_RETRY_AFTER" =~ ^[0-9]+$ ]] ||
    [[ "$GITHUB_API_RATE_LIMIT_REMAINING" == "0" ]] ||
    grep -qiE 'secondary rate limit|rate limit exceeded|api rate limit exceeded' "$body_file"
}

github_api_get_with_retry() {
  local url="${1:?github_api_get_with_retry: url is required}"
  local body_file="${2:?github_api_get_with_retry: body file is required}"
  local report_failure="${3:-true}"
  local accept="${4:-application/vnd.github+json}"

  [[ "$GITHUB_API_RETRY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::GITHUB_API_RETRY_ATTEMPTS must be a positive integer." >&2
    return 1
  }
  [[ "$GITHUB_API_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || {
    echo "::error::GITHUB_API_RETRY_DELAY_SECONDS must be a non-negative integer." >&2
    return 1
  }
  [[ "$GITHUB_API_MAX_RETRY_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::GITHUB_API_MAX_RETRY_DELAY_SECONDS must be a positive integer." >&2
    return 1
  }
  [[ "$report_failure" == "true" || "$report_failure" == "false" ]] || {
    echo "::error::github_api_get_with_retry: report_failure must be true or false." >&2
    return 1
  }

  if _github_api_cache_hit "$url" "$body_file"; then
    echo "::notice::Serving GitHub REST API response for $url from the local rate-limit cache (age < ${GITHUB_API_CACHE_TTL_SECONDS}s)." >&2
    return 0
  fi

  local attempt call_status http_status retry_delay
  for (( attempt=1; attempt<=GITHUB_API_RETRY_ATTEMPTS; attempt++ )); do
    : >"$body_file"
    if _github_api_get_once "$url" "$body_file" "$accept"; then
      call_status=0
    else
      call_status=$?
    fi
    http_status="$GITHUB_API_HTTP_STATUS"

    if (( call_status == 0 )) && [[ "$http_status" == "200" ]]; then
      _github_api_cache_store "$url" "$body_file"
      return 0
    fi

    # What: Fails immediately on definitive request or auth statuses
    # Why: Retrying cannot repair an invalid request, token, or missing path
    # From: Issue #1095 | PR #1501.
    if (( call_status == 0 )) && [[ "$http_status" == "400" || "$http_status" == "401" || "$http_status" == "404" || "$http_status" == "422" ]] ||
       { (( call_status == 0 )) && [[ "$http_status" == "403" ]] && ! _github_api_is_rate_limited "$body_file"; }; then
      if [[ "$report_failure" == "true" ]]; then
        echo "::error::GitHub REST GET failed permanently with HTTP $http_status for $url; refusing to interpret this response as an empty result." >&2
      fi
      return 1
    fi

    if (( attempt == GITHUB_API_RETRY_ATTEMPTS )); then
      if [[ "$report_failure" == "true" && -n "$http_status" ]]; then
        echo "::error::GitHub REST GET failed after $attempt attempts with HTTP $http_status for $url." >&2
      elif [[ "$report_failure" == "true" ]]; then
        echo "::error::GitHub REST GET failed after $attempt attempts with curl status $call_status for $url." >&2
      fi
      return 1
    fi

    retry_delay="$(_github_api_retry_delay "$attempt" "$http_status")" || return 1
    # What: Logs rate-aware retry attempts as ::notice::, not warnings
    # Why: Recovered transient attempts remain observable without a warning
    # From: Issue #1095 | PR #1501.
    if [[ -n "$http_status" ]]; then
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS returned HTTP $http_status; retrying after ${retry_delay}s." >&2
    else
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS failed with curl status $call_status; retrying after ${retry_delay}s." >&2
    fi
    sleep "$retry_delay"
  done

  return 1
}
