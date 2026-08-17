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
# Given the raw JSON body of a manifest fetched from the GHCR registry API
# (GET /v2/<repo>/<service>/manifests/<digest>), prints one child digest per
# line: every entry in `.manifests[]` (the image-index case: a multi-arch
# tag's per-platform manifests AND its own Buildx-embedded provenance/SBOM
# attestation manifests -- Buildx lists both kinds inside the same
# `manifests[]` array, distinguished only by a `platform: unknown/unknown`
# value and a `vnd.docker.reference.type: attestation-manifest` annotation
# neither this function nor its caller needs to inspect, since every entry in
# this array is unconditionally a child of the parent index regardless of
# that annotation), plus `.subject.digest` if present (the OCI Referrers-API
# attestation case: a manifest fetched directly can itself declare which
# other digest it is "about" via a top-level `subject` field). Prints nothing
# for a plain single-platform manifest with neither field, which is a normal,
# expected result (not a failure) -- the caller should check the raw HTTP
# fetch's own success separately from this function ever printing output.
#
# NOTE: this only walks ONE level. This project's own image-building pipeline
# (build-push.yml/build-tools.yml, confirmed via a repo-wide grep for
# `actions/attest`/`--provenance`/`--sbom`) never produces a nested index
# (an index whose own `manifests[]` children are themselves indices), so a
# single level is sufficient for every real artifact shape this project
# currently produces; if that ever changes, this function -- and its
# caller's single-pass child collection -- would need to walk recursively
# instead.
#
# Returns non-zero (and prints nothing) if EITHER jq extraction itself
# genuinely fails (a broken/missing jq, or a manifest body that passed the
# caller's own gcps_manifest_looks_valid check yet still trips a jq error on
# this specific query) -- distinct from a legitimate, successful extraction
# that simply finds no children (a plain single-platform manifest), which
# still returns 0 with empty output. This distinction matters because an
# UNDER-populated children set is dangerous (a still-referenced platform
# manifest would look orphaned), so the caller must be able to tell "really
# has no children" apart from "we don't actually know" and treat the latter
# as a reason to abort orphan classification for the whole service, the same
# way it already does for an outright manifest-fetch failure.
#
# Deliberately does NOT handle GHCR/Buildx's OTHER attestation-association
# convention, the `sha256-<64-hex>` fallback TAG scheme (an attestation
# manifest naming its subject via its own tag string instead of a `subject`
# field in its body) -- confirmed live (2026-08-06, real lancache-ng/proxy
# package) that a manifest using this scheme has no `subject` field
# whatsoever, so there is nothing in the JSON body this function receives
# for it to find; the association only exists in that version's TAG, which
# this function is never given (it only ever sees a manifest body). The
# caller (scripts/untracked/gc-pr-staging-images.sh's process_service(), in its Pass 1
# tag loop) handles that case itself, directly off the tag string, for
# exactly this reason -- see its own comment at the `sha256-<hex>` tag-shape
# check for the full live-verified rationale.
gcps_extract_manifest_children() {
  local manifest_json="$1"
  local manifests_children subject_child
  if ! manifests_children="$(printf '%s' "$manifest_json" | jq -r '(.manifests // [])[]?.digest // empty' 2>/dev/null)"; then
    return 1
  fi
  if ! subject_child="$(printf '%s' "$manifest_json" | jq -r '.subject.digest // empty' 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$manifests_children" ]] && printf '%s\n' "$manifests_children"
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
  # from cache_ref (the single source of truth) in both branches below;
  # named lookup_state below, not pr_state, so a caller passing the literal
  # name "pr_state" (the real one does) can't collide with this function's
  # own same-named local and silently write back into that instead.
  # Why: a caller invoking this as a plain statement (not `$(...)`) needs
  # cache_ref written by reference (command substitution would fork a
  # subshell and lose it), so the result must reach it by reference too.
  # From: Issue #1557 | PR #1559
  local api_output lookup_state

  if [[ -n "${cache_ref[$pr_number]:-}" ]]; then
    printf '%s\n' "${cache_ref[$pr_number]}"
    if [[ -n "$result_var_name" ]]; then
      local -n result_ref="$result_var_name"
      # shellcheck disable=SC2034 # nameref write-only output param, read by the caller through result_var_name
      result_ref="${cache_ref[$pr_number]}"
    fi
    return
  fi

  # `api_output="$(gh api ...)"` as a bare assignment statement is itself a
  # "simple command" under `set -e`: if `gh api` returns non-zero, THIS
  # SCRIPT (not just the function) would exit right here, before a
  # separately-captured `$?` on the next line could ever be read. Putting the
  # assignment directly in the `if` condition makes it a tested context, so a
  # failure is handled by the `else` branches below instead of aborting the
  # whole GC run.
  if api_output="$(gh api "repos/${repository}/pulls/${pr_number}" 2>&1)"; then
    if lookup_state="$(printf '%s' "$api_output" | jq -r '.state // empty' 2>&1)"; then
      if [[ "$lookup_state" == "open" ]]; then
        cache_ref["$pr_number"]="OPEN"
      else
        cache_ref["$pr_number"]="CLOSED"
      fi
    else
      # gh api succeeded (a real response came back) but jq itself failed to
      # parse it -- same "don't let this bare assignment trip set -e"
      # reasoning as the gh api call above, applied to every other jq call
      # in this script.
      echo "::warning::Could not parse PR #$pr_number's state from a successful API response via jq: $lookup_state" >&2
      cache_ref["$pr_number"]="LOOKUP_FAILED"
    fi
  elif [[ "$api_output" == *"HTTP 404"* ]]; then
    # Confirmed: this PR number genuinely does not exist (deleted,
    # renumbered, whatever) -- a real answer, not an ambiguous one.
    cache_ref["$pr_number"]="CLOSED"
  else
    echo "::warning::Could not determine PR #$pr_number's state (not a 404): $api_output" >&2
    cache_ref["$pr_number"]="LOOKUP_FAILED"
  fi

  if [[ -n "$result_var_name" ]]; then
    local -n result_ref="$result_var_name"
    # shellcheck disable=SC2034 # nameref write-only output param, read by the caller through result_var_name
    result_ref="${cache_ref[$pr_number]}"
  fi
  printf '%s\n' "${cache_ref[$pr_number]}"
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
