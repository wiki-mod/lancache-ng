#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Shared bounded retry support for authenticated read-only GitHub REST GETs.
# The token is read from GH_TOKEN and fed to curl over stdin so it never
# appears in argv or in this helper's retry diagnostics. This is separate
# from the registry retry helper because API GETs have no registry-login
# recovery step, and a recovered transient must remain a notice rather than
# the warning emitted by the registry-oriented helper.

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
      return 0
    fi

    # Authentication failure and Not Found are not converted into absence.
    # Retrying them cannot establish the positive proof this audit requires.
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

    # A recovered transient is not a warning under the repository's
    # warnings-as-errors policy. The final exhausted failure above is the
    # point where this becomes an error.
    if [[ -n "$http_status" ]]; then
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS returned HTTP $http_status; retrying after ${GITHUB_API_RETRY_DELAY_SECONDS}s." >&2
    else
      echo "::notice::GitHub REST GET attempt $attempt/$GITHUB_API_RETRY_ATTEMPTS failed with curl status $call_status; retrying after ${GITHUB_API_RETRY_DELAY_SECONDS}s." >&2
    fi
    sleep "$GITHUB_API_RETRY_DELAY_SECONDS"
  done

  return 1
}
