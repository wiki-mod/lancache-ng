#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: reaps GHCR container package versions for this project's images --
# closed-PR staging tags and orphaned untagged versions.
# Why: invoked by gc-pr-staging-images.yml; the BASH_SOURCE guard at this
# file's bottom lets Bats source every function without running main().
# From: Issue #1557 | PR #1559
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"

# --- Classification/lookup functions -----------------------------------
# What: every function below inherits this file's `set -euo pipefail`.
# Why: each one already guards its own risky commands explicitly
# (`if ! x="$(...)"`), so strict mode adds no new failure mode.
# From: Issue #1557 | PR #1559

# gcps_version_name_is_digest <name>
# What: checks a version's `.name` matches `sha256:<64 hex>`.
# Why: a failing check must skip orphan classification for the whole
# service -- a partially-populated protected-digest set is more
# dangerous than an empty one.
# From: Issue #1095 | PR #1443
gcps_version_name_is_digest() {
  local name="$1"
  [[ "$name" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# gcps_extract_manifest_children <manifest-json>
# What: prints each direct child digest from `.manifests[]`/
# `.subject.digest`; one level only, no tag-based attestation refs.
# Why: a genuine jq failure returns non-zero so the caller can tell "no
# children" apart from "don't know" and abort orphan classification.
# From: Issue #1095 | PR #1443
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
# What: returns 0 only when the JSON carries `mediaType`, which every
# real manifest response sets.
# Why: an untrustworthy body (an HTML error page, a truncated response)
# must abort orphan classification, not read as "zero children".
# From: Issue #1095 | PR #1443
gcps_manifest_looks_valid() {
  local manifest_json="$1"
  local media_type
  media_type="$(printf '%s' "$manifest_json" | jq -r '.mediaType // empty' 2>/dev/null)" || return 1
  [[ -n "$media_type" ]]
}

# gcps_created_at_to_epoch <iso8601-timestamp>
# What: converts a GHCR package version's `.created_at` to Unix epoch seconds,
# or prints nothing and returns non-zero on a parse failure.
# Why: the caller must treat a parse failure as "too young to delete" (fail
# closed), never as satisfying the age-gate safety margin.
# From: Issue #1095 | PR #1443
gcps_created_at_to_epoch() {
  local created_at="$1"
  date -u -d "$created_at" +%s 2>/dev/null
}

# gcps_is_old_enough_to_delete <created-at-epoch> <now-epoch> <min-age-seconds>
# What: applies the same min-age margin to every deletion category, not
# just orphans.
# Why: a version deletable by tag/reference state alone can still be a
# build/promotion still in flight; age is cheaper than tracking producers.
# From: Issue #1095 | PR #1443
gcps_is_old_enough_to_delete() {
  local created_at_epoch="$1" now_epoch="$2" min_age_seconds="$3"
  (( now_epoch - created_at_epoch >= min_age_seconds ))
}

# gcps_pr_lookup_state <pr-number> <repo> <cache-array-name> [<result-var>]
# What: prints OPEN/CLOSED/LOOKUP_FAILED; the optional 4th arg avoids
# `$(...)`, whose subshell would discard the nameref cache write.
# Why: a confirmed answer stays distinct from an ambiguous one, so a
# transient API hiccup is never treated as safe-to-delete.
# From: Issue #1557 | PR #1559
gcps_pr_lookup_state() {
  local pr_number="$1" repository="$2" cache_array_name="$3" result_var_name="${4:-}"
  local -n cache_ref="$cache_array_name"
  # What: this function's own locals are deliberately not named `pr_state`.
  # Why: a nameref resolves to the nearest matching name, so a same-named
  # local here would shadow the caller's variable and silently write to a
  # throwaway copy instead.
  # From: Issue #1557 | PR #1559
  local api_output parsed_state

  if [[ -n "${cache_ref[$pr_number]:-}" ]]; then
    if [[ -n "$result_var_name" ]]; then
      local -n result_ref="$result_var_name"
      # shellcheck disable=SC2034 # written via the result_ref nameref, read by the caller through $result_var_name
      result_ref="${cache_ref[$pr_number]}"
    fi
    printf '%s\n' "${cache_ref[$pr_number]}"
    return
  fi

  # What: the `gh api` call sits directly in the `if` condition, not a
  # bare assignment before it.
  # Why: a bare assignment is a "simple command" under `set -e` -- a
  # non-zero exit would end the script before `else` could handle it.
  # From: Issue #1095 | PR #1443
  if api_output="$(gh api "repos/${repository}/pulls/${pr_number}" 2>&1)"; then
    if parsed_state="$(printf '%s' "$api_output" | jq -r '.state // empty' 2>&1)"; then
      if [[ "$parsed_state" == "open" ]]; then
        cache_ref["$pr_number"]="OPEN"
      else
        cache_ref["$pr_number"]="CLOSED"
      fi
    else
      # What: a successful `gh api` response that jq still failed to parse is
      # logged and treated as LOOKUP_FAILED.
      # Why: same set -e-safe capture-before-check reasoning as the gh api call
      # above.
      # From: Issue #1095 | PR #1443
      echo "::warning::Could not parse PR #$pr_number's state from a successful API response via jq: $parsed_state" >&2
      cache_ref["$pr_number"]="LOOKUP_FAILED"
    fi
  elif [[ "$api_output" == *"HTTP 404"* ]]; then
    # What: a 404 means this PR number genuinely doesn't exist.
    # Why: a confirmed answer, not an ambiguous one -- safe to mark CLOSED.
    # From: Issue #1095 | PR #1443
    cache_ref["$pr_number"]="CLOSED"
  else
    echo "::warning::Could not determine PR #$pr_number's state (not a 404): $api_output" >&2
    cache_ref["$pr_number"]="LOOKUP_FAILED"
  fi

  if [[ -n "$result_var_name" ]]; then
    local -n result_ref="$result_var_name"
    # shellcheck disable=SC2034 # written via the result_ref nameref, read by the caller through $result_var_name
    result_ref="${cache_ref[$pr_number]}"
  fi
  printf '%s\n' "${cache_ref[$pr_number]}"
}

# gcps_registry_anon_token <service> <repository>
# What: fetches an anonymous Bearer token via capture-then-parse, never a
# live `curl | jq` pipe.
# Why: under `set -o pipefail`, a piped `jq` on empty input still exits 0,
# masking a real curl failure behind the pipeline's rightmost exit status.
# From: Issue #1095 | PR #1443
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
# What: fetches <digest>'s manifest via the registry v2 API, requesting
# all four Buildx media types in one Accept header.
# Why: requesting only one risks the registry silently converting an index
# into a single-platform manifest, indistinguishable from real "no children".
# From: Issue #1095 | PR #1443
gcps_fetch_manifest() {
  local service="$1" digest="$2" repository="$3" token="$4"
  curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repository}/${service}/manifests/${digest}"
}

# --- Reaper entry point (org/config/process_service/main) ---------------

org="wiki-mod"
repo="wiki-mod/lancache-ng"
# What: every service build-push.yml's build/build-arm64 jobs can push a
# PR staging tag for (including dhcp/dhcp-proxy and build-tools).
# Why: check-workflow-service-lists.sh requires this to equal the full
# canonical service set, so it must track build-push.yml's own matrix.
# From: Issue #626 | PR #627
services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)

# What: a PER-SERVICE (not global) deletion cap -- up to 360 deletions
# per run across 9 services.
# Why: a single global cap in fixed iteration order would let the first
# service starve every later one against the large untagged backlog.
# From: Issue #1095 | PR #1443
max_deletions_per_service="${GC_MAX_DELETIONS_PER_SERVICE:-40}"

# What: 24-hour safety margin, applied to every deletion category alike.
# Why: a version deletable by tag/reference state alone can still be a
# build/promotion/backfill still in flight; age is simpler than tracking
# every concurrent producer.
# From: Issue #1095 | PR #1443
min_age_seconds="${GC_MIN_AGE_SECONDS:-86400}"

now_epoch="$(date -u +%s)"

# What: a top-level (not per-service) array -- a PR number is unique
# repo-wide, so a looked-up state stays valid across services.
# Why: passed by bare name into a nameref parameter, which static
# analysis can't trace (hence the disable below).
# From: Issue #1095 | PR #1443
# shellcheck disable=SC2034
declare -A pr_state_cache=()

# What: caps how many LOOKUP_FAILED results a run tolerates before
# failing loudly, default 10.
# Why: nearly every lookup failing would otherwise silently no-op the
# reap path behind a healthy-looking summary.
# From: Issue #1095 | PR #1443
max_pr_lookup_failures="${GC_MAX_PR_LOOKUP_FAILURES:-10}"
pr_lookup_failures=0

# What: counts services hitting "no GHCR package yet" (404 on listing);
# threshold scales off the real service count.
# Why: GitHub's REST docs say 404 can also mean access-denied, so many
# at once reads as a credential problem, not several launches at once.
# From: Issue #1557 | PR #1559
services_not_found=0

had_errors=0
deleted=0
kept=0

# process_service <service>
# What: runs in the current shell -- called as a plain statement, never
# wrapped in `$(...)`.
# Why: top-level had_errors/deleted/kept/pr_state_cache updates must stay
# visible to later calls; a subshell would silently discard them.
# From: Issue #1095 | PR #1443
process_service() {
  local service="$1"
  local package="lancache-ng%2F${service}"
  local versions_json version_list

  # What: had_errors fails the run at the end without aborting other
  # services; stderr is captured to a scratch file, not merged via `2>&1`.
  # Why: merging stderr would risk corrupting the JSON `jq -c '.[]'`
  # depends on, since `--paginate` can write rate-limit notices to stderr.
  # From: Issue #1095 | PR #1443
  local versions_stderr
  versions_stderr="$(mktemp)"
  if ! versions_json="$(gh api --paginate "orgs/${org}/packages/container/${package}/versions" 2>"$versions_stderr")"; then
    local list_error
    list_error="$(cat "$versions_stderr")"
    rm -f "$versions_stderr"
    # What: a real 404 here means the package doesn't exist yet (a new
    # service, no image pushed) -- not a reaper error.
    # Why: `gh api` writes "Package not found. (HTTP 404)" to stderr
    # (hence reading $list_error), never had_errors, for this case.
    # From: Issue #1095 | PR #1443
    if [[ "$list_error" == *"HTTP 404"* ]]; then
      echo "::notice::lancache-ng/${service} has no GHCR package yet (HTTP 404 listing its versions) -- nothing to reap for a service with no images published. Not treated as an error."
      # What: counted via services_not_found, not just logged.
      # Why: a single occurrence is a safe notice, but nearly every service
      # hitting this path in one run must not still read as healthy.
      # From: Issue #1557 | PR #1559
      services_not_found=$((services_not_found + 1))
      return
    fi
    echo "::error::Failed to list package versions for lancache-ng/${service}: $list_error"
    had_errors=1
    return
  fi
  rm -f "$versions_stderr"

  # What: `gh api --paginate` merges every page into one array, not just
  # page 1 (verified: a real 3678-version/37-page package returned all).
  # Why: no truncation heuristic layers on top -- an earlier one warned on
  # exact-multiple-of-100 counts, which fires on a normal round boundary.
  # From: Issue #1095 | PR #1443
  #
  # What: jq's output is captured via checked command substitution, fed to
  # `read` via a here-string, not consumed inside a process substitution.
  # Why: jq's exit status inside `< <(...)` is never checked by `set -e`,
  # so a broken jq would silently report "nothing to clean" instead.
  # From: Issue #1095 | PR #1443
  if ! version_list="$(printf '%s' "$versions_json" | jq -c '.[]' 2>&1)"; then
    echo "::error::Failed to enumerate package versions for lancache-ng/${service} via jq: $version_list"
    had_errors=1
    return
  fi

  local orphan_phase_ok=1
  local registry_token=""
  local -A children_digests=()
  local -A all_digest_set=()
  local service_deletions=0

  # What: Pass 0 validates every version's `.name` matches the digest shape
  # the orphan phase's digest-set comparisons assume.
  # Why: one malformed entry disables orphan classification for the whole
  # service -- a partial digest set is more dangerous than an empty one.
  # From: Issue #1095 | PR #1443
  local version_entry name
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! name="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
      echo "::error::Failed to read a package version's name/digest for $service via jq: $name"
      had_errors=1
      orphan_phase_ok=0
      continue
    fi
    if ! gcps_version_name_is_digest "$name"; then
      # What: a malformed digest shape is `::error::` + had_errors=1
      # (AG-VAL-001), not a soft warning.
      # Why: required classification evidence is unavailable here, same as
      # the jq-read failure above -- the run must not exit 0 looking clean.
      # From: Issue #1557 | PR #1559
      echo "::error::A $service package version's .name ('$name') is not the expected sha256:<64-hex> digest shape -- disabling orphan (untagged-version) classification for this service this run. Closed-PR tagged-version reaping is unaffected."
      had_errors=1
      orphan_phase_ok=0
      continue
    fi
    all_digest_set["$name"]=1
  done <<< "$version_list"

  # What: fetches the anonymous pull token once per service before Pass 1,
  # regardless of tagged-version count.
  # Why: deferring to "the first tagged version Pass 1 sees" would leave it
  # empty for a wholly-untagged service, but Pass 2 needs it either way.
  # From: Issue #1095 | PR #1443
  if [[ "$orphan_phase_ok" == "1" ]]; then
    if ! registry_token="$(ghcr_retry ghcr.io "" "" -- gcps_registry_anon_token "$service" "$repo")" || [[ -z "$registry_token" ]]; then
      echo "::error::Failed to obtain an anonymous registry pull token for $service -- disabling orphan classification for this service this run."
      had_errors=1
      orphan_phase_ok=0
    fi
  fi

  # What: Pass 1 -- closed-PR tagged-version classification, plus (when
  # orphan_phase_ok) collecting manifest children into children_digests.
  # Why: Pass 2 needs children_digests to tell a genuinely orphaned
  # version apart from one still referenced by a live tag's index.
  # From: Issue #1095 | PR #1443
  local version_id tag_list
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      echo "::error::Failed to read a package version's id for $service via jq: $version_id"
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      echo "::error::Failed to enumerate tags for $service version $version_id via jq: $tag_list"
      had_errors=1
      continue
    fi

    if [[ -z "$tag_list" ]]; then
      continue # untagged -- classified in Pass 2 below, not here
    fi

    # What: sha256-<hex> attestation tags are scanned in their own pass,
    # before the protected/has_closed_pr_tag loop below.
    # Why: that loop `break`s on the first decisive tag, which could
    # under-populate children_digests and make a live manifest look orphaned.
    # From: Issue #1095 | PR #1443
    local attestation_tag
    while IFS= read -r attestation_tag; do
      [[ -z "$attestation_tag" ]] && continue
      if [[ "$attestation_tag" =~ ^sha256-([0-9a-f]{64})$ ]]; then
        children_digests["sha256:${BASH_REMATCH[1]}"]=1
      fi
    done <<< "$tag_list"

    local protected=0 has_closed_pr_tag=0 tag
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      if [[ "$tag" =~ ^pr-([0-9]+)-sha-[0-9a-f]{7,}(-amd64|-arm64)?$ ]]; then
        local pr_number="${BASH_REMATCH[1]}"
        # What: called as a plain statement with a result-variable arg,
        # not wrapped in `$(...)`.
        # Why: command substitution forks a subshell, so the nameref cache
        # write would land on a private copy and vanish.
        # From: Issue #1557 | PR #1559
        local pr_state
        gcps_pr_lookup_state "$pr_number" "$repo" pr_state_cache pr_state
        case "$pr_state" in
          OPEN)
            protected=1
            ;;
          LOOKUP_FAILED)
            # What: treated exactly like an open PR (keep, don't delete),
            # but counted separately in pr_lookup_failures.
            # Why: counting separately lets max_pr_lookup_failures catch a
            # run where this happens pervasively, not just once.
            # From: Issue #1095 | PR #1443
            protected=1
            pr_lookup_failures=$((pr_lookup_failures + 1))
            ;;
          CLOSED)
            has_closed_pr_tag=1
            ;;
        esac
        [[ "$protected" == "1" ]] && break
      else
        # What: any non pr-* tag is protected unconditionally.
        # Why: a scan-failed sha-<commit> tag is already deleted upstream
        # by build-push.yml's own cleanup step, so this reaper never
        # needs to re-derive that outcome itself.
        # From: Issue #1095 | PR #1443
        protected=1
        break
      fi
    done <<< "$tag_list"

    if [[ "$orphan_phase_ok" == "1" ]]; then
      local version_digest manifest_json
      # What: `if ! version_digest=...`, not a bare assignment.
      # Why: an unguarded failure here would exit the entire script under
      # `set -euo pipefail` -- no summary, no had_errors, no other services.
      # From: Issue #1095 | PR #1443
      if ! version_digest="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
        echo "::error::Failed to read $service version $version_id's own digest via jq: $version_digest"
        had_errors=1
        orphan_phase_ok=0
        version_digest=""
      fi
      if [[ -n "$version_digest" ]]; then
        if ! manifest_json="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$service" "$version_digest" "$repo" "$registry_token")" \
            || [[ -z "$manifest_json" ]] || ! gcps_manifest_looks_valid "$manifest_json"; then
          echo "::error::Failed to fetch (or received an unrecognizable body for) $service digest $version_digest's own manifest -- disabling orphan classification for this service this run, since a partially-populated protected-digest set is more dangerous than none."
          had_errors=1
          orphan_phase_ok=0
        else
          local child_digest children_output
          # What: gcps_extract_manifest_children failing is treated the
          # same as a fetch failure above.
          # Why: an incomplete children set is what actually protects a
          # live platform manifest from being misclassified as orphaned.
          # From: Issue #1095 | PR #1443
          if ! children_output="$(gcps_extract_manifest_children "$manifest_json")"; then
            echo "::error::Failed to extract manifest children for $service digest $version_digest -- disabling orphan classification for this service this run."
            had_errors=1
            orphan_phase_ok=0
          else
            while IFS= read -r child_digest; do
              [[ -z "$child_digest" ]] && continue
              children_digests["$child_digest"]=1
            done <<< "$children_output"
          fi
        fi
      fi
    fi

    if [[ "$protected" == "1" || "$has_closed_pr_tag" == "0" ]]; then
      kept=$((kept + 1))
      continue
    fi

    local created_at created_epoch
    # What: a malformed/unreadable .created_at flags had_errors, not a
    # silent fail-closed keep.
    # Why: a bad timestamp on a real GHCR record is a "should never
    # happen" data-integrity signal (AG-VAL-001), not a transient blip.
    # From: Issue #1557 | PR #1559
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::error::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::error::Could not parse created_at ('$created_at') for $service version $version_id -- keeping it this run (fail closed) rather than risk deleting something mid-flight."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! gcps_is_old_enough_to_delete "$created_epoch" "$now_epoch" "$min_age_seconds"; then
      kept=$((kept + 1))
      continue
    fi

    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service hit its per-run deletion cap ($max_deletions_per_service) while processing closed-PR tagged versions; the rest are left for a later run."
      kept=$((kept + 1))
      continue
    fi

    # What: tags_display is cosmetic (log message only); a jq failure here
    # degrades the message instead of aborting.
    # Why: this isn't actually blocking the delete, since tag_list above
    # already fully resolved this version's tags.
    # From: Issue #1095 | PR #1443
    local tags_display
    tags_display="$(printf '%s' "$version_entry" | jq -rc '.metadata.container.tags // []' 2>&1)" || tags_display="<jq error: $tags_display>"
    echo "Deleting $service version $version_id (only closed-PR staging tags: $tags_display)."
    local delete_output
    if delete_output="$(gh api -X DELETE "orgs/${org}/packages/container/${package}/versions/${version_id}" 2>&1)"; then
      deleted=$((deleted + 1))
      service_deletions=$((service_deletions + 1))
    else
      # What: a failed delete is `::error::` + had_errors=1, not just a
      # warning.
      # Why: otherwise every delete could fail (PAT lacks delete:packages)
      # while `deleted` stays 0 and the job still exits 0.
      # From: Issue #1095 | PR #1443
      echo "::error::Failed to delete $service version $version_id (tags: $tags_display): $delete_output"
      had_errors=1
    fi
  done <<< "$version_list"

  if [[ "$orphan_phase_ok" != "1" ]]; then
    return
  fi

  # What: Pass 2 -- orphan classification, re-reading the same
  # version_list captured at the top of this function.
  # Why: reusing the listing keeps children_digests a single, internally
  # consistent snapshot of this service's manifest graph.
  # From: Issue #1095 | PR #1443
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -n "$tag_list" ]] && continue # tagged -- already handled in Pass 1

    if ! name="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
      echo "::error::Failed to read a package version's name/digest for $service via jq: $name"
      had_errors=1
      continue
    fi
    if [[ -n "${children_digests[$name]:-}" ]]; then
      # What: still referenced as a child (a platform manifest, or a
      # Buildx-embedded attestation/SBOM manifest) by at least one
      # currently-tagged image index.
      # Why: deleting it would break that live tag.
      # From: Issue #1095 | PR #1443
      kept=$((kept + 1))
      continue
    fi

    local created_at created_epoch
    # What: a jq read failure and an unparseable timestamp both flag
    # had_errors and log why.
    # Why: same required-evidence reasoning as Pass 1's identical check
    # above (AG-VAL-001).
    # From: Issue #1557 | PR #1559
    if ! created_at="$(printf '%s' "$version_entry" | jq -r '.created_at' 2>&1)"; then
      echo "::error::Failed to read created_at for $service version $version_id via jq: $created_at -- keeping it this run (fail closed)."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
      echo "::error::Could not parse created_at ('$created_at') for $service version $version_id -- keeping it this run (fail closed) rather than risk deleting something mid-flight."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if ! gcps_is_old_enough_to_delete "$created_epoch" "$now_epoch" "$min_age_seconds"; then
      kept=$((kept + 1))
      continue
    fi

    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service hit its per-run deletion cap ($max_deletions_per_service) while processing orphan candidates; the rest are left for a later run."
      kept=$((kept + 1))
      continue
    fi

    # What: a candidate with no `manifests[]` reference may still be a
    # REFERRERS-API attestation via its own manifest's `subject` field.
    # Why: one extra GET per candidate is cheap insurance against deleting
    # a still-relevant attestation.
    # From: Issue #1095 | PR #1443
    local candidate_manifest
    # What: a failed fetch here flags had_errors, in addition to keeping
    # the candidate (fail closed).
    # Why: matches Pass 1's manifest-fetch reasoning (AG-VAL-001) -- the
    # exit code must reflect an incomplete required check.
    # From: Issue #1557 | PR #1559
    if ! candidate_manifest="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$service" "$name" "$repo" "$registry_token")" || [[ -z "$candidate_manifest" ]]; then
      echo "::error::Could not fetch $service candidate orphan $name's own manifest to check for a subject reference -- keeping it this run rather than risk deleting a live attestation."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    local subject_digest
    subject_digest="$(printf '%s' "$candidate_manifest" | jq -r '.subject.digest // empty' 2>/dev/null)" || subject_digest=""
    if [[ -n "$subject_digest" ]] && [[ -n "${all_digest_set[$subject_digest]:-}" ]]; then
      # What: a live referrers-API attestation, subject digest still present in
      # this service's package.
      # Why: keep it -- deleting would orphan a still-relevant attestation.
      # From: Issue #1095 | PR #1443
      kept=$((kept + 1))
      continue
    fi

    echo "Deleting $service version $version_id (untagged, unreferenced orphan digest $name)."
    local delete_output
    if delete_output="$(gh api -X DELETE "orgs/${org}/packages/container/${package}/versions/${version_id}" 2>&1)"; then
      deleted=$((deleted + 1))
      service_deletions=$((service_deletions + 1))
    else
      echo "::error::Failed to delete $service orphan version $version_id (digest $name): $delete_output"
      had_errors=1
    fi
  done <<< "$version_list"
}

# main
# What: everything requiring a real GH_TOKEN, real tools, and an actual
# sweep lives here, not at plain top level.
# Why: the bats suite sources this file under mocked gh/curl; main() must
# not run out from under a plain `source` (BASH_SOURCE guard, file bottom).
# From: Issue #1095 | PR #1443
main() {
  # What: this `${var:?message}` error avoids apostrophes/single quotes
  # (shellcheck SC1011).
  # Why: an apostrophe inside the expansion gets misparsed as opening a
  # quoted string that desyncs on the next real quote.
  # From: Issue #1095 | PR #1443
  : "${GH_TOKEN:?GH_TOKEN (the GHCR_PACKAGE_DELETE_PAT secret configured on this repository) is required -- see the calling workflow, specifically its Check for GHCR deletion credentials step, which must gate whether this script ever runs.}"

  # What: fails loud and early (AG-CI-001) if gh/jq/curl/date are missing,
  # not a confusing mid-run parse error.
  # Why: self-hosted lancache-light runners aren't the pinned build-tools
  # container -- no tool beyond the bare OS can be assumed present.
  # From: Issue #1095 | PR #1443
  local required_cmd
  for required_cmd in gh jq curl date; do
    if ! command -v "$required_cmd" >/dev/null 2>&1; then
      echo "::error::Required tool '$required_cmd' was not found on this runner. This script cannot run without it."
      exit 1
    fi
  done

  for service in "${services[@]}"; do
    process_service "$service"
  done

  echo "::notice::PR staging-tag GC complete: deleted $deleted version(s), kept $kept."

  if (( pr_lookup_failures > 0 )); then
    echo "::warning::$pr_lookup_failures PR-state lookup(s) could not be confirmed this run (ambiguous gh api result, not a real 404) -- every one of those tagged versions was kept as a precaution, per gcps_pr_lookup_state's own fail-safe design."
  fi
  if (( pr_lookup_failures >= max_pr_lookup_failures )); then
    echo "::error::$pr_lookup_failures PR-state lookups failed this run (threshold: $max_pr_lookup_failures) -- this many ambiguous lookups is far more consistent with a systemic problem (GHCR_PACKAGE_DELETE_PAT missing its repo/public_repo scope, or the pulls API being rate-limited) than with isolated transient blips. Every one of those versions was still kept safely, but reporting this run as a plain success would hide that the closed-PR tagged-version reap path likely did far less real work than it should have. Investigated live during this mechanism's own 2026-08-06 root-cause pass: the one prior real scheduled run with a suspiciously low delete count (2026-08-02, 10 deleted/21919 kept) was confirmed, via its own actual GitHub Actions log, to have hit ZERO real LOOKUP_FAILED occurrences -- that run's low count was fully explained by the classification-gap defect this whole file's extraction fixes, not by this failure mode. This threshold exists so a FUTURE occurrence of this different failure shape is caught loudly instead of requiring another manual log audit to notice."
    had_errors=1
  fi

  # What: more than half of the configured services hitting "no GHCR
  # package yet" in one run is treated as a real, run-failing error.
  # Why: GitHub's REST docs say a 404 can also hide an authorization
  # failure this reaper can't distinguish from genuine absence.
  # From: Issue #1557 | PR #1559
  local max_services_not_found=$(( (${#services[@]} / 2) + 1 ))
  if (( services_not_found >= max_services_not_found )); then
    echo "::error::$services_not_found of ${#services[@]} configured services reported no GHCR package yet this run (threshold: $max_services_not_found) -- this many simultaneous 404s is far more consistent with GHCR_PACKAGE_DELETE_PAT losing its read:packages scope (which GitHub's own REST docs say can also surface as 404, not just 403) than with that many services genuinely never having published an image. Each one was still safely treated as nothing-to-reap, but reporting this run as a plain success would hide that the reap path likely did far less real work than it should have across the whole services list, not just one service."
    had_errors=1
  fi

  if [[ "$had_errors" == "1" ]]; then
    echo "::error::One or more package-version listings, manifest fetches, or deletions failed (see errors above). Failing this run instead of reporting success -- GHCR_PACKAGE_DELETE_PAT may be missing read:packages/delete:packages scopes, the API may be rate-limited, or GitHub rejected a delete for another reason. A GC run that looks healthy while silently doing nothing would let PR staging tags and orphaned manifests accumulate in GHCR forever undetected."
    exit 1
  fi
}

# What: `"${BASH_SOURCE[0]}" == "${0}"` is true only when this file runs
# directly, not when it's `source`d.
# Why: the bats suite sources this file under mocked gh/curl; main()
# (hard-requiring a real GH_TOKEN) must not run out from under a `source`.
# From: Issue #1095 | PR #1443
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
