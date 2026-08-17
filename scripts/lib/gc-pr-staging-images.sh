#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shared classification/lookup functions for scripts/untracked/gc-pr-staging-images.sh
# (the standalone reaper .github/workflows/gc-pr-staging-images.yml now
# calls, extracted from that workflow's own former inline `run:` block --
# see issue #1095 for the root-cause writeup this extraction answers).
#
# Two independent defects motivated this extraction, not just a style
# preference:
#
#   1. CLASSIFICATION GAP: the pre-extraction logic only ever considered a
#      package version deletable when EVERY tag on it was a closed-PR
#      `pr-<N>-sha-<short>` tag. A version with NO tags at all -- the
#      per-platform manifests and buildx attestation/SBOM sub-manifests
#      Buildx automatically creates on every multi-arch push -- never entered
#      that check (the tag-classification loop it depends on never executes
#      for an empty tag list), so it was kept forever regardless of age or
#      whether anything still referenced it. Confirmed live (2026-08-06):
#      roughly 55% of this project's ~24,734 GHCR package versions across 8
#      services are completely untagged, and none of them were ever reachable
#      by the old logic. gcps_extract_manifest_children() below is the fix:
#      it reads the actual manifest graph (which digests a tagged manifest
#      references as children) so an untagged version can be proven either
#      "still referenced by something tagged" (keep) or "genuinely orphaned"
#      (eligible, subject to the age gate in scripts/untracked/gc-pr-staging-images.sh).
#   2. RATE-LIMIT/CONCURRENCY GAP: fixed by the workflow's own new
#      `concurrency:` block, not by anything in this file -- documented here
#      only so a reader of this file's history knows both defects were fixed
#      together, not this one alone.
#
# Deliberately NOT `set -euo pipefail` at the top level, matching every other
# file under scripts/lib/: this file only defines functions for a caller to
# invoke under the caller's own shell options (see scripts/lib/ghcr-retry.sh's
# own header for the identical reasoning). Depends on scripts/lib/ghcr-retry.sh
# (ghcr_retry, GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE) being sourced first by
# the caller -- mirrors scripts/lib/staging-ancestor-fallback.sh's own
# sourcing contract.

# gcps_version_name_is_digest <name>
#
# A GHCR container package version's `.name` field equals the manifest
# digest (`sha256:<64 hex chars>`) -- verified live (2026-08-06) via a
# real, unauthenticated `gh api
# "orgs/wiki-mod/packages/container/lancache-ng%2Fproxy/versions?per_page=2"`
# call against this project's own real `proxy` package, e.g.
# `"name":"sha256:9c4b1dc4751ddc63099f1f65015442240d7de9faae3e3eb3992f3de3287e861b"`
# -- which is exactly what the orphan classification below needs to compare
# against manifest-referenced child digests. This function exists so that
# fact is checked at runtime too, not just trusted forever: if GitHub ever
# changes what `.name` contains (or a malformed response slips through),
# every digest comparison downstream would silently compare against the
# wrong value and could misclassify a still-referenced manifest as an
# orphan. The caller must treat a failing check here as a reason to skip
# orphan classification for the WHOLE service, not just the one malformed
# entry -- a partially-populated protected-digest set is more dangerous than
# an empty one (see scripts/untracked/gc-pr-staging-images.sh's own comment at its
# call site).
gcps_version_name_is_digest() {
  local name="$1"
  [[ "$name" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# gcps_extract_manifest_children <manifest-json>
#
# Prints only forward `.manifests[].digest` edges from an image index to the
# platform/attestation manifests it requires. A top-level `.subject.digest`
# is deliberately NOT a child edge: it points in the opposite direction,
# from a referrer/attestation to the artifact it describes. Treating subject
# as a child makes an otherwise-orphaned subject keep itself alive merely
# because a stale attestation still refers to it.
#
# NOTE: this only walks ONE level. This project's current publishers do not
# produce nested indices; if that changes, the caller must recurse rather
# than trusting this one-level closure.
#
# Returns non-zero on jq failure and 0 with empty output for a valid manifest
# with no `.manifests[]` children.
# From: Issue #1095 | PR #1443 | PR #1586
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
# Prints the top-level OCI `.subject.digest` when present. Kept separate from
# gcps_extract_manifest_children because a subject is a reverse referrer edge:
# the referrer is useful while the subject remains live, but the referrer must
# not by itself make an otherwise-dead subject immortal.
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
# Returns 0 only when <manifest-json> is well-formed JSON that is
# recognizable as SOME kind of manifest response (carries `mediaType`, the
# field every one of the four Accept-header media types this project asks
# for is required to set). Used by the caller to distinguish "fetched fine,
# genuinely has no children" (a real single-platform manifest -- proceed)
# from "the fetch nominally succeeded but returned something we can't trust"
# (an HTML error page, a truncated body, a registry-side redirect target) --
# the latter must abort orphan classification for the whole service rather
# than silently being treated as "zero children" (see this file's own
# gcps_extract_manifest_children comment for why an empty result must never
# be trusted blindly).
gcps_manifest_looks_valid() {
  local manifest_json="$1"
  local media_type
  media_type="$(printf '%s' "$manifest_json" | jq -r '.mediaType // empty' 2>/dev/null)" || return 1
  [[ -n "$media_type" ]]
}

# gcps_created_at_to_epoch <iso8601-timestamp>
#
# Converts a GHCR package version's `.created_at` (ISO-8601, e.g.
# "2026-08-01T12:34:56Z") to Unix epoch seconds, or prints nothing and
# returns non-zero on a parse failure. The caller must treat a parse failure
# as "too young to delete" (fail closed) rather than "old enough" -- an
# unparseable timestamp must never be read as satisfying the 24h safety
# margin every deletion category requires.
gcps_created_at_to_epoch() {
  local created_at="$1"
  date -u -d "$created_at" +%s 2>/dev/null
}

# gcps_is_old_enough_to_delete <created-at-epoch> <now-epoch> <min-age-seconds>
#
# The 24h (or whatever <min-age-seconds> is configured to) safety margin
# applies uniformly to EVERY deletion category this reaper considers
# (closed-PR tagged versions and orphaned untagged versions alike) -- an
# explicit maintainer requirement, not just an orphan-specific guard, because
# a version that looks deletable by tag/reference state alone can still be
# the output of a build or promotion that is still actively in flight
# elsewhere in the pipeline; giving every such race a fixed window to resolve
# before this reaper ever considers deleting it is cheaper and more robust
# than trying to enumerate every possible in-flight producer explicitly.
gcps_is_old_enough_to_delete() {
  local created_at_epoch="$1" now_epoch="$2" min_age_seconds="$3"
  (( now_epoch - created_at_epoch >= min_age_seconds ))
}

# gcps_pr_lookup_state <pr-number> <repository> <cache-array-name>
#
# Prints exactly one of OPEN / CLOSED / LOOKUP_FAILED for PR <pr-number> in
# <repository>, using the caller-provided associative array (referenced by
# name via nameref, so the same cache persists across calls within one
# service's tag loop) to avoid repeat API calls for the same PR number.
#
# Ported verbatim (comments included) from the pre-extraction workflow's
# own pr_lookup_state(): this exact distinction -- a confirmed answer
# (`gh api` succeeded, or failed with a real 404) vs. an ambiguous one (any
# other failure) -- is what stops a transient GitHub/token/rate-limit hiccup
# from being silently treated as "this PR is closed, safe to delete its
# images". Collapsing that distinction was a real bug this project already
# fixed once; re-deriving this function from scratch during the extraction
# would risk reintroducing it.
#
# NOT the same concern as the one this comment used to only cover: treating
# a LOOKUP_FAILED as "protected" is the correct SAFE default for any single
# ambiguous lookup, but if EVERY (or nearly every) lookup in a run fails --
# e.g. GHCR_PACKAGE_DELETE_PAT losing its `repo`/`public_repo` scope in a
# future rotation, since that scope has nothing to do with the
# read:packages/delete:packages scopes this token is documented to need, or
# the pulls API being rate-limited independently of the packages API on the
# same token -- this function would silently keep returning the safe
# LOOKUP_FAILED answer for every single PR number, and the caller would
# report a healthy-looking "GC complete" summary while the closed-PR
# tagged-version reap path did effectively nothing that entire run, for a
# reason nothing in the log surfaces. Investigated live (2026-08-06): the
# one real historical scheduled run with a suspiciously low
# deletion rate (2026-08-02, run 30736443878: 10 deleted, 21919 kept) was
# checked against its own real GitHub Actions log -- zero real runtime
# occurrences of either LOOKUP_FAILED warning message exist in that log
# (the only matches found were the workflow's own pre-run source-code echo,
# not an actual invocation), positively ruling out a systemic PAT/lookup
# failure as that run's cause; that run's low delete count is explained
# entirely by the classification-gap defect this whole extraction
# fixes (the vast majority of "kept" versions there were untagged
# entirely, never reachable by the pre-fix tag-only check, not because
# their PR state was unknown). That verification does not retroactively
# guarantee a FUTURE run can't hit this differently-shaped failure mode,
# though, so scripts/untracked/gc-pr-staging-images.sh's caller now tracks how many
# times this function returns LOOKUP_FAILED across a whole run and treats a
# suspiciously high count as a real, run-failing error (see
# GC_MAX_PR_LOOKUP_FAILURES in that file) -- turning a hypothetically
# silent, healthy-looking no-op into a loud, investigable failure the next
# time it might genuinely occur, rather than relying on another manual log
# audit to notice it again.
gcps_pr_lookup_state() {
  local pr_number="$1" repository="$2" cache_array_name="$3" result_var_name="${4:-}"
  local -n cache_ref="$cache_array_name"
  # What: optional 4th arg is a caller variable name, populated via nameref
  # after local/shared-cache or live-API resolution. When present, stdout
  # stays empty; legacy callers without the 4th arg still receive the state.
  # Why: production calls this as a plain statement so cache writes survive;
  # result output must not also leak raw OPEN/CLOSED lines into workflow logs.
  # From: Issue #1557 | PR #1559 | PR #1586
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
        if mkdir "$shared_cache_lock" 2>/dev/null; then
          lock_owned=1
          # Another owner may have finished between our first read and this
          # mkdir. Re-read before spending a live API request.
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

  if [[ -z "$lookup_state" ]]; then
    # Keep the assignment in an if-condition: a failed gh call must be
    # classified here rather than tripping a caller's `set -e`.
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
# Fetches (and the caller is expected to cache -- see
# scripts/untracked/gc-pr-staging-images.sh's own per-service token cache) an anonymous
# read-only Bearer token scoped to `repository:<repository>/<service>:pull`.
# This project's GHCR packages are public, so an anonymous pull token is
# sufficient for manifest reads -- no GHCR_PACKAGE_DELETE_PAT scope is spent
# on this, and it works even if that PAT is ever scoped down to
# packages-write-only in the future. Wrapped in ghcr_retry by the caller (see
# gcps_fetch_manifest below), not internally here, so a caller needing a
# custom retry policy for the token endpoint specifically still can.
#
# Deliberately a two-step capture-then-parse (curl's own output captured and
# exit status checked FIRST, jq applied to the captured variable second),
# not a live `curl | jq -r '.token'` pipe: `jq -r '.token'` on a genuinely
# EMPTY input (confirmed via real invocation: `printf '' | jq -r '.token'`
# exits 0 with empty output, not a parse error) succeeds even when curl
# itself failed and produced nothing -- under this file's caller's own `set
# -o pipefail`, a live pipe's overall exit status is the RIGHTMOST failing
# command's, so a failed `curl -f` (empty output) feeding a "successful"
# `jq` would make the whole pipeline report success despite the real fetch
# having failed. Capturing curl's output into a variable and checking ITS
# OWN exit status before ever handing anything to jq removes this masking
# entirely.
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
# Fetches the raw manifest JSON for <digest> in <service>'s repository via
# the registry's own v2 API (not the GitHub Packages API, which has no
# manifest-graph endpoint). Requests all four media types a Buildx-produced
# artifact can be stored as (OCI index, Docker manifest list, OCI manifest,
# Docker manifest v2) in a single Accept header -- asking for only one and
# letting the registry pick would risk silently getting back a CONVERTED
# single-platform manifest with no `manifests[]` at all for an index that
# genuinely has children, which would look identical to "no children" and
# defeat the entire protection this mechanism exists to provide.
gcps_fetch_manifest() {
  local service="$1" digest="$2" repository="$3" token="$4"
  curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repository}/${service}/manifests/${digest}"
}

# What: performs one GitHub package-version DELETE attempt and classifies it.
# Why: ghcr_retry needs permanent-vs-transient signaling and 404 is an
# idempotent success when another cleanup path already removed the version.
# From: Issue #1095.
gcps_delete_package_version_once() {
  local endpoint="${1:?gcps_delete_package_version_once: endpoint is required}"
  local output http_status

  gcps_delete_result="FAILED"
  if output="$(gh api -X DELETE "$endpoint" 2>&1)"; then
    gcps_delete_result="DELETED"
    return 0
  fi
  if [[ "$output" == *"HTTP 404"* ]]; then
    # What: suppresses SC2034 for this cross-file output assignment.
    # Why: the sourced caller reads the helper output after the function returns.
    # From: Issue #1095 | PR #1585.
    # shellcheck disable=SC2034
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
# Why: manifest-declared legacy names may be intentionally absent, while
# transient/auth failures must still use the shared bounded retry contract.
# From: Issue #1095.
gcps_package_presence_once() {
  local endpoint="${1:?gcps_package_presence_once: endpoint is required}"
  local output http_status

  gcps_package_presence="FAILED"
  if output="$(gh api "$endpoint" 2>&1)"; then
    gcps_package_presence="EXISTS"
    return 0
  fi
  if [[ "$output" == *"HTTP 404"* ]]; then
    # What: suppresses SC2034 for this cross-file output assignment.
    # Why: the sourced caller reads the helper output after the function returns.
    # From: Issue #1095 | PR #1585.
    # shellcheck disable=SC2034
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
