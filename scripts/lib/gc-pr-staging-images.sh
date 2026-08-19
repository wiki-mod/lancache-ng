#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: shared classification/lookup functions for the GHCR PR-staging-image
# reaper (scripts/untracked/gc-pr-staging-images.sh).
# Why: an untagged version (a per-platform/attestation sub-manifest) is only
# provably orphaned by reading the real manifest graph, not by tag state
# alone -- gcps_extract_manifest_children() below is that check.
# From: Issue #1095 | PR #1586

# gcps_version_name_is_digest <name>
#
# What: checks a GHCR package version's `.name` matches sha256:<64 hex>.
# Why: orphan classification below compares `.name` against manifest-child
# digests; a failure here must skip classification for the WHOLE service --
# a partially-populated protected-digest set is worse than an empty one.
# From: Issue #1095 | PR #1586
gcps_version_name_is_digest() {
  local name="$1"
  [[ "$name" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# gcps_extract_manifest_children <manifest-json>
#
# What: prints forward `.manifests[].digest` child edges of an image index.
# Why: `.subject.digest` points the opposite direction (referrer to
# subject) and must never count as a child, or a stale attestation could
# keep an otherwise-orphaned subject alive; walks one level only.
# From: Issue #1095 | PR #1586
gcps_extract_manifest_children() {
  local manifest_json="$1"
  local manifests_children
  if ! manifests_children="$(printf '%s' "$manifest_json" | jq -r '(.manifests // [])[]?.digest // empty' 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$manifests_children" ]] && printf '%s\n' "$manifests_children"
  return 0
}

# gcps_extract_manifest_subject <manifest-json>
#
# What: prints the top-level OCI `.subject.digest` when present.
# Why: kept separate from gcps_extract_manifest_children -- a subject is a
# reverse referrer edge, and must not by itself make an otherwise-dead
# subject immortal while the referrer that names it remains live.
# From: Issue #1585 | PR #1586
gcps_extract_manifest_subject() {
  local manifest_json="$1"
  local subject_child
  if ! subject_child="$(printf '%s' "$manifest_json" | jq -r '.subject.digest // empty' 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$subject_child" ]] && printf '%s\n' "$subject_child"
  return 0
}

# gcps_manifest_looks_valid <manifest-json>
#
# What: returns 0 only when the input is well-formed JSON carrying `mediaType`.
# Why: distinguishes "fetched fine, genuinely no children" from "the fetch
# nominally succeeded but returned something untrustworthy" (an HTML error
# page, a truncated body) -- the latter must abort orphan classification.
# From: Issue #1095 | PR #1586
gcps_manifest_looks_valid() {
  local manifest_json="$1"
  local media_type
  media_type="$(printf '%s' "$manifest_json" | jq -r '.mediaType // empty' 2>/dev/null)" || return 1
  [[ -n "$media_type" ]]
}

# gcps_created_at_to_epoch <iso8601-timestamp>
#
# What: converts a GHCR `.created_at` timestamp to Unix epoch seconds.
# Why: a parse failure must be treated as "too young to delete" (fail
# closed), never as satisfying the configurable safety margin every
# deletion category requires.
# From: Issue #1095 | PR #1586
gcps_created_at_to_epoch() {
  local created_at="$1"
  date -u -d "$created_at" +%s 2>/dev/null
}

# gcps_is_old_enough_to_delete <created-at-epoch> <now-epoch> <min-age-seconds>
#
# What: checks whether now minus created_at meets the configured safety margin.
# Why: applies uniformly to every deletion category (closed-PR and orphan
# alike) -- a version can look deletable by tag/reference state alone while
# still being the output of a build still actively in flight elsewhere.
# From: Issue #1095 | PR #1586
gcps_is_old_enough_to_delete() {
  local created_at_epoch="$1" now_epoch="$2" min_age_seconds="$3"
  (( now_epoch - created_at_epoch >= min_age_seconds ))
}

# gcps_pr_lookup_state <pr-number> <repository> <cache-array-name> [<result-var-name>]
#
# What: prints OPEN/CLOSED/LOOKUP_FAILED for a PR, caching per-call via nameref.
# Why: a real HTTP 404 (PR truly gone) reads as CLOSED, but every other API
# failure stays LOOKUP_FAILED (never CLOSED) -- an ambiguous lookup must
# never license a deletion; the caller tracks a run-wide LOOKUP_FAILED count.
# From: Issue #1095 | PR #1586
gcps_pr_lookup_state() {
  local pr_number="$1" repository="$2" cache_array_name="$3" result_var_name="${4:-}"
  local -n cache_ref="$cache_array_name"
  local api_output lookup_state shared_cache_dir="" shared_cache_file="" shared_cache_lock=""
  local shared_cache_tmp="" wait_attempt=0 lock_owned=0

  lookup_state="${cache_ref[$pr_number]:-}"

  # What: optionally reuses confirmed OPEN/CLOSED states across package workers.
  # Why: package workers are separate shells, so their associative arrays
  # cannot deduplicate the same PR across services; a run-local file cache
  # bounds that API amplification without persisting state between sweeps.
  # From: Issue #1585 | PR #1586
  if [[ -z "$lookup_state" && -n "${GCPS_PR_STATE_CACHE_DIR:-}" ]]; then
    shared_cache_dir="${GCPS_PR_STATE_CACHE_DIR%/}"
    shared_cache_file="${shared_cache_dir}/${pr_number}.state"
    if [[ -r "$shared_cache_file" ]] && IFS= read -r lookup_state <"$shared_cache_file"; then
      case "$lookup_state" in
        OPEN | CLOSED)
          cache_ref["$pr_number"]="$lookup_state"
          ;;
        *)
          lookup_state=""
          ;;
      esac
    else
      lookup_state=""
    fi

    # What: serializes only the first live lookup for one PR number.
    # Why: an atomic result file alone still lets concurrent workers miss it
    # at the same time and issue duplicate pulls API requests. mkdir is the
    # lock primitive so no extra flock dependency is required.
    # From: Issue #1585 | PR #1586
    if [[ -z "$lookup_state" ]]; then
      shared_cache_lock="${shared_cache_file}.lock"
      for (( wait_attempt=1; wait_attempt<=100; wait_attempt++ )); do
        # What: re-reads the cache file right after taking the lock.
        # Why: another owner may have written and released it between this
        # worker's first read and this mkdir, avoiding a wasted API call.
        # From: Issue #1585 | PR #1586
        if mkdir "$shared_cache_lock" 2>/dev/null; then
          lock_owned=1
          if [[ -r "$shared_cache_file" ]] && IFS= read -r lookup_state <"$shared_cache_file"; then
            case "$lookup_state" in
              OPEN | CLOSED)
                cache_ref["$pr_number"]="$lookup_state"
                ;;
              *)
                lookup_state=""
                ;;
            esac
          else
            lookup_state=""
          fi
          break
        fi
        if [[ -r "$shared_cache_file" ]] && IFS= read -r lookup_state <"$shared_cache_file"; then
          case "$lookup_state" in
            OPEN | CLOSED)
              cache_ref["$pr_number"]="$lookup_state"
              break
              ;;
            *)
              lookup_state=""
              ;;
          esac
        fi
        sleep 0.1
      done
    fi
  fi

  # What: the live `gh api` call's assignment stays inside the if-condition.
  # Why: a failed call must be classified below, not trip a caller's `set -e`.
  # From: Issue #1095 | PR #1586
  if [[ -z "$lookup_state" ]]; then
    if api_output="$(gh api "repos/${repository}/pulls/${pr_number}" 2>&1)"; then
      if lookup_state="$(printf '%s' "$api_output" | jq -r '.state // empty' 2>&1)"; then
        if [[ "$lookup_state" == "open" ]]; then
          lookup_state="OPEN"
        elif [[ "$lookup_state" == "closed" ]]; then
          lookup_state="CLOSED"
        else
          echo "::warning::Could not classify PR #$pr_number's state from a successful API response: $lookup_state" >&2
          lookup_state="LOOKUP_FAILED"
        fi
      else
        echo "::warning::Could not parse PR #$pr_number's state from a successful API response via jq: $lookup_state" >&2
        lookup_state="LOOKUP_FAILED"
      fi
    elif [[ "$api_output" == *"HTTP 404"* ]]; then
      lookup_state="CLOSED"
    else
      echo "::warning::Could not determine PR #$pr_number's state (not a 404): $api_output" >&2
      lookup_state="LOOKUP_FAILED"
    fi
    cache_ref["$pr_number"]="$lookup_state"

    # What: shares only confirmed answers, written atomically.
    # Why: LOOKUP_FAILED must remain retriable; a transient API failure must
    # not poison every other package worker for the rest of the sweep.
    # From: Issue #1585 | PR #1586
    if [[ "$lock_owned" == "1" && -n "$shared_cache_file" && -d "$shared_cache_dir" && "$lookup_state" != "LOOKUP_FAILED" ]]; then
      shared_cache_tmp="${shared_cache_file}.${BASHPID}.tmp"
      if printf '%s\n' "$lookup_state" >"$shared_cache_tmp"; then
        mv -f -- "$shared_cache_tmp" "$shared_cache_file" 2>/dev/null || rm -f -- "$shared_cache_tmp"
      else
        rm -f -- "$shared_cache_tmp"
      fi
    fi
  fi

  if (( lock_owned == 1 )); then
    rm -rf -- "$shared_cache_lock"
  fi

  if [[ -n "$result_var_name" ]]; then
    local -n result_ref="$result_var_name"
    # shellcheck disable=SC2034 # nameref write-only output param, read by the caller through result_var_name
    result_ref="$lookup_state"
  else
    printf '%s\n' "$lookup_state"
  fi
}

# gcps_registry_anon_token <service> <repository>
#
# What: fetches an anonymous read-only pull-scoped Bearer token from GHCR.
# Why: checks curl's own exit status before handing output to jq -- a live
# `curl -f | jq -r '.token'` pipe would report success even on a failed
# curl, since jq treats empty input as an empty value, not a parse error.
# From: Issue #1095 | PR #1586
gcps_registry_anon_token() {
  local service="$1" repository="$2"
  local raw_response
  if ! raw_response="$(curl -fsSL --connect-timeout 10 --max-time 30 \
      "https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}/${service}:pull")"; then
    return 1
  fi
  printf '%s' "$raw_response" | jq -r '.token'
}

# gcps_fetch_manifest <service> <digest> <repository> <token>
#
# What: fetches the raw manifest JSON for <digest> via the registry v2 API.
# Why: requests all four Buildx-relevant media types in one Accept header --
# asking for only one risks the registry silently returning a CONVERTED
# single-platform manifest for an index that genuinely has children.
# From: Issue #1095 | PR #1586
gcps_fetch_manifest() {
  local service="$1" digest="$2" repository="$3" token="$4"
  curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repository}/${service}/manifests/${digest}"
}

# What: performs one GitHub package-version DELETE attempt and classifies it.
# Why: ghcr_retry needs permanent-vs-transient signaling; gcps_delete_result
# is a cross-file output var the sourced caller reads after return (SC2034);
# 404 is an idempotent success when another cleanup path already removed it.
# From: Issue #1095 | PR #1586
gcps_delete_package_version_once() {
  local endpoint="${1:?gcps_delete_package_version_once: endpoint is required}"
  local output http_status

  gcps_delete_result="FAILED"
  if output="$(gh api -X DELETE "$endpoint" 2>&1)"; then
    gcps_delete_result="DELETED"
    return 0
  fi
  if [[ "$output" == *"HTTP 404"* ]]; then
    # shellcheck disable=SC2034 # cross-file output var, see function header
    gcps_delete_result="ALREADY_ABSENT"
    return 0
  fi

  if [[ "$output" =~ HTTP\ ([0-9]{3}) ]]; then
    http_status="${BASH_REMATCH[1]}"
    if [[ "$http_status" == 4?? && "$http_status" != "429" ]] \
        && ! { [[ "$http_status" == "403" ]] && [[ "${output,,}" == *"rate limit"* ]]; }; then
      echo "::error::GitHub package-version DELETE failed permanently with HTTP $http_status for $endpoint: $output" >&2
      return "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE"
    fi
  fi

  echo "::notice::GitHub package-version DELETE attempt failed for $endpoint: $output" >&2
  return 1
}

# What: probes whether one package exists and classifies the API result.
# Why: manifest-declared legacy names may be intentionally absent; transient/
# auth failures must still use the shared bounded retry contract; the output
# var is read by the sourced caller after return (SC2034).
# From: Issue #1095 | PR #1586
gcps_package_presence_once() {
  local endpoint="${1:?gcps_package_presence_once: endpoint is required}"
  local output http_status

  gcps_package_presence="FAILED"
  if output="$(gh api "$endpoint" 2>&1)"; then
    gcps_package_presence="EXISTS"
    return 0
  fi
  if [[ "$output" == *"HTTP 404"* ]]; then
    # shellcheck disable=SC2034 # cross-file output var, see function header
    gcps_package_presence="ABSENT"
    return 0
  fi
  if [[ "$output" =~ HTTP\ ([0-9]{3}) ]]; then
    http_status="${BASH_REMATCH[1]}"
    if [[ "$http_status" == 4?? && "$http_status" != "429" ]] \
        && ! { [[ "$http_status" == "403" ]] && [[ "${output,,}" == *"rate limit"* ]]; }; then
      echo "::error::GitHub package presence probe failed permanently with HTTP $http_status for $endpoint: $output" >&2
      return "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE"
    fi
  fi
  echo "::notice::GitHub package presence probe attempt failed for $endpoint: $output" >&2
  return 1
}

