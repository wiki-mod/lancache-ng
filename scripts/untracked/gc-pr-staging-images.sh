#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: garbage-collects unprotected GHCR versions for manifest packages.
# Why: closed PRs and orphans are not enough; ordinary sha-* history must
# also obey the manifest retention budget instead of growing indefinitely.
# From: Issue #1095.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/../lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/gc-pr-staging-images.sh
source "$script_dir/../lib/gc-pr-staging-images.sh"
# shellcheck source=scripts/lib/github-api-retry.sh
source "$script_dir/../lib/github-api-retry.sh"
# shellcheck source=scripts/lib/sha-retention-audit.sh
source "$script_dir/../lib/sha-retention-audit.sh"

# What: disables GET caching inside the destructive collector process.
# Why: immediate pre-delete revalidation must always read current API state.
# From: Issue #1095.
# shellcheck disable=SC2034 # read by github_api_get_with_retry() in the sourced library
GITHUB_API_CACHE_DIR=""

# --- Reaper entry point (org/config/process_service/main) ---------------

org="wiki-mod"
repo="wiki-mod/lancache-ng"
manifest="${GC_RETENTION_MANIFEST:-$repo_root/release/stack-images.yml}"
# What: every service build-push.yml's build/build-arm64 jobs can push a
# PR staging tag for (including dhcp/dhcp-proxy and build-tools).
# Why: check-workflow-service-lists.sh requires this to equal the full
# canonical service set, so it must track build-push.yml's own matrix.
# From: Issue #626 | PR #627
services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools utilities)

# What: keeps the existing per-package deletion cap, default 40.
# Why: each package gets its own bounded drain budget so one large backlog
# cannot starve every later package in the same sweep.
# From: Issue #1095.
max_deletions_per_service="${GC_MAX_DELETIONS_PER_SERVICE:-40}"

# What: caps destructive work across the whole run, independent of package count.
# Why: a large manual per-package cap must not multiply into an unbounded API drain.
# From: Issue #1095.
max_deletions_total="${GC_MAX_DELETIONS_TOTAL:-1500}"

# What: bounds how many packages may be processed concurrently, default 1.
# Why: package-level parallelism attacks listing/audit wall time while every
# individual package still performs DELETE operations serially.
# From: Issue #1095.
gc_concurrency="${GC_CONCURRENCY:-1}"

# What: optionally performs every classification/revalidation but no DELETE.
# Why: workflow_dispatch needs a live safety preview before a large drain.
# From: Issue #1095.
gc_dry_run="${GC_DRY_RUN:-false}"

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
would_delete=0
# Output slots populated by gcps_* helpers sourced above.
gcps_delete_result=""
gcps_package_presence=""

# What: stores exact root-version identities authorized by the read-only audit.
# Why: normal sha-* deletion must consume the existing classifier's result,
# not independently reimplement its release/channel/history policy here.
# From: Issue #1095.
declare -A retention_delete_candidates=()
retention_history_refs=""
# What: package inventory exported by the authoritative filtered audit.
# Why: the collector reuses it instead of immediately listing the same
# package again; fresh exact-version GETs still protect every DELETE.
# From: Issue #1585 | PR #1586
retention_versions_snapshot=""
retention_package_absent=0

# What: runs one DELETE through the existing bounded retry wrapper.
# Why: every destructive category needs the same retry/idempotency behavior,
# while dry-run must exercise classification without touching GHCR state.
# From: Issue #1095.
gc_delete_version() {
  local endpoint="$1" description="$2"
  gc_delete_result="FAILED"

  if [[ "$gc_dry_run" == "true" ]]; then
    echo "::notice::[dry-run] Would delete $description."
    would_delete=$((would_delete + 1))
    gc_delete_result="WOULD_DELETE"
    return 0
  fi

  if ghcr_retry api.github.com "" "" -- gcps_delete_package_version_once "$endpoint"; then
    gc_delete_result="$gcps_delete_result"
    if [[ "$gc_delete_result" == "DELETED" ]]; then
      deleted=$((deleted + 1))
      echo "Deleted $description."
    else
      echo "::notice::$description was already absent when deletion was attempted."
    fi
    return 0
  fi

  had_errors=1
  return 1
}

# What: resolves the Git histories whose sha-* roots share the retention budget.
# Why: current_dev/master, release branches, and v* release refs are all
# legitimate producers; an old root must not become immortal merely because
# it is no longer reachable from current_dev alone.
# From: Issue #1095.
gc_resolve_retention_history_refs() {
  local explicit="${GC_RETENTION_HISTORY_REFS:-}" refs_output ref
  local -a refs=()

  if [[ -n "$explicit" ]]; then
    read -r -a refs <<<"$explicit"
  else
    if refs_output="$(git -C "$repo_root" for-each-ref --format='%(refname:short)' \
        refs/remotes/origin/current_dev \
        refs/remotes/origin/master \
        'refs/remotes/origin/release/*' \
        'refs/remotes/origin/v[0-9]*')"; then
      :
    else
      echo "::error::Could not enumerate managed retention history refs." >&2
      return 1
    fi
    while IFS= read -r ref; do
      [[ -n "$ref" && "$ref" != "origin/HEAD" ]] || continue
      refs+=("$ref")
    done <<<"$refs_output"
  fi

  (( ${#refs[@]} > 0 )) || {
    echo "::error::No managed retention history refs are available." >&2
    return 1
  }

  local normalized=""
  declare -A seen_refs=()
  for ref in "${refs[@]}"; do
    [[ -n "$ref" ]] || continue
    git -C "$repo_root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || {
      echo "::error::Configured retention history ref does not resolve to a commit: $ref" >&2
      return 1
    }
    [[ -z "${seen_refs[$ref]:-}" ]] || continue
    seen_refs["$ref"]=1
    normalized+="${normalized:+ }${ref}"
  done
  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}

# What: builds one package's exact would-delete map with the existing audit.
# Why: filtered audits let package workers run concurrently without creating
# a second retention classifier or serializing the full registry inventory.
# From: Issue #1095.
gc_build_service_retention_plan() {
  local service="$1" audit_output snapshot_file line field package_name version_id digest tags decision package
  local -a audit_fields=()

  retention_delete_candidates=()
  retention_versions_snapshot=""
  retention_package_absent=0
  package="lancache-ng%2F${service}"
  if ! ghcr_retry api.github.com "" "" -- gcps_package_presence_once \
      "orgs/${org}/packages/container/${package}/versions?per_page=1"; then
    echo "::error::Could not establish whether lancache-ng/$service exists before retention planning."
    return 1
  fi
  if [[ "$gcps_package_presence" == "ABSENT" ]]; then
    retention_package_absent=1
    services_not_found=$((services_not_found + 1))
    echo "::notice::lancache-ng/$service has no GHCR package; retention planning has no work."
    return 0
  fi

  audit_output="$(mktemp)"
  snapshot_file="$(mktemp)"
  if ! GITHUB_REPOSITORY="$repo" \
      SRA_MANIFEST="$manifest" \
      SRA_HISTORY_REFS="$retention_history_refs" \
      SRA_PACKAGE_FILTER="$service" \
      SRA_VERSION_SNAPSHOT_FILE="$snapshot_file" \
      GITHUB_API_CACHE_DIR="" \
      bash "$script_dir/gc-sha-retention-audit.sh" >"$audit_output"; then
    rm -f -- "$audit_output" "$snapshot_file"
    echo "::error::Retention planning failed for lancache-ng/$service; keeping the whole package untouched this run."
    return 1
  fi
  if [[ ! -s "$snapshot_file" ]]; then
    rm -f -- "$audit_output" "$snapshot_file"
    echo "::error::Retention planning for lancache-ng/$service returned no reusable package snapshot; refusing a second independent inventory read."
    return 1
  fi
  retention_versions_snapshot="$snapshot_file"

  while IFS= read -r line; do
    [[ "$line" == AUDIT$'\t'* ]] || continue
    package_name=""
    version_id=""
    digest=""
    tags=""
    decision=""
    IFS=$'\t' read -r -a audit_fields <<<"$line"
    for field in "${audit_fields[@]:1}"; do
      case "$field" in
        package=*) package_name="${field#package=}" ;;
        id=*) version_id="${field#id=}" ;;
        digest=*) digest="${field#digest=}" ;;
        tags=*) tags="${field#tags=}" ;;
        decision=*) decision="${field#decision=}" ;;
      esac
    done
    [[ "$package_name" == "$service" && "$decision" == "would-delete" ]] || continue
    [[ "$version_id" =~ ^[0-9]+$ && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      rm -f -- "$audit_output" "$retention_versions_snapshot"
      retention_versions_snapshot=""
      echo "::error::Retention planner emitted an invalid deletion identity for lancache-ng/$service."
      return 1
    }
    retention_delete_candidates["$version_id"]="${digest}"$'\t'"${tags}"
  done <"$audit_output"
  rm -f -- "$audit_output"
}

# What: re-reads one exact package version immediately before any GC deletion.
# Why: digest, complete tags, age, and PR state can change after the sweep
# snapshot; every destructive category needs the same fresh fail-closed gate.
# From: Issue #1095 | Issue #1585 | PR #1586
gc_revalidate_retention_candidate() {
  local service="$1" package="$2" version_id="$3" expected_digest="$4" expected_tags="$5"
  local body_file fields fresh_id fresh_digest fresh_tags fresh_created_at fresh_epoch tag pr_number pr_state
  # What: suppresses SC2034 for a nameref-backed PR-state cache.
  # Why: gcps_pr_lookup_state receives its name and accesses it through local -n.
  # From: Issue #1095 | PR #1585.
  # shellcheck disable=SC2034
  local -A fresh_pr_state_cache=()
  local -a fresh_tag_array=()

  body_file="$(mktemp)"
  if ! github_api_get_with_retry \
      "https://api.github.com/orgs/${org}/packages/container/${package}/versions/${version_id}" \
      "$body_file"; then
    rm -f -- "$body_file"
    echo "::error::Could not revalidate lancache-ng/$service version $version_id immediately before deletion."
    return 1
  fi
  if ! fields="$(jq -r '[.id, .name, (.metadata.container.tags | sort | join(",")), (.created_at // "")] | join("|")' "$body_file")"; then
    rm -f -- "$body_file"
    echo "::error::Could not parse live revalidation data for lancache-ng/$service version $version_id."
    return 1
  fi
  rm -f -- "$body_file"
  IFS='|' read -r fresh_id fresh_digest fresh_tags fresh_created_at <<<"$fields"

  if [[ "$fresh_id" != "$version_id" || "$fresh_digest" != "$expected_digest" || "$fresh_tags" != "$expected_tags" ]]; then
    echo "::notice::Keeping lancache-ng/$service version $version_id because its digest or tags changed after retention planning."
    return 2
  fi
  if ! fresh_epoch="$(gcps_created_at_to_epoch "$fresh_created_at")"; then
    echo "::error::Could not parse live created_at for lancache-ng/$service version $version_id; keeping it."
    return 1
  fi
  if ! gcps_is_old_enough_to_delete "$fresh_epoch" "$now_epoch" "$min_age_seconds"; then
    echo "::notice::Keeping lancache-ng/$service version $version_id because it no longer satisfies the minimum-age gate."
    return 2
  fi

  IFS=',' read -r -a fresh_tag_array <<<"$fresh_tags"
  for tag in "${fresh_tag_array[@]}"; do
    if [[ "$tag" =~ ^pr-([0-9]+)-sha-[0-9a-f]{7,}(-amd64|-arm64)?$ ]]; then
      pr_number="${BASH_REMATCH[1]}"
      # What: bypasses the run-local planning cache for the final safety check.
      # Why: a PR can reopen after planning; only a live answer immediately
      # before DELETE may authorize removal of a PR-associated version.
      # From: Issue #1585 | PR #1586
      GCPS_PR_STATE_CACHE_DIR="" gcps_pr_lookup_state "$pr_number" "$repo" fresh_pr_state_cache pr_state
      if [[ "$pr_state" == "LOOKUP_FAILED" ]]; then
        pr_lookup_failures=$((pr_lookup_failures + 1))
      fi
      if [[ "$pr_state" != "CLOSED" ]]; then
        echo "::notice::Keeping lancache-ng/$service version $version_id because PR #$pr_number is open or could not be revalidated as closed."
        return 2
      fi
    fi
  done
  return 0
}

# process_service <service> [version-snapshot-jsonl]
# What: runs in the current shell -- called as a plain statement, never
# wrapped in `$(...)`.
# Why: top-level had_errors/deleted/kept/pr_state_cache updates must stay
# visible to later calls; a subshell would silently discard them.
# From: Issue #1095 | PR #1443
process_service() {
  local service="$1"
  local version_snapshot_file="${2:-}"
  local package="lancache-ng%2F${service}"
  local versions_json version_list
  local -A protected_children_digests=() deleted_version_ids=() manifest_children_by_version=()
  local -A retained_root_prefixes=() live_subject_digests=()
  local revalidate_status delete_description kind prefix

  # What: production reuses the exact JSONL inventory exported by the
  # authoritative filtered retention audit. Direct unit callers may omit the
  # snapshot and retain the legacy mocked gh-listing path.
  # Why: a live GC previously fetched every multi-thousand-version package
  # twice before deleting anything, multiplying API pressure for no safety gain.
  # From: Issue #1585 | PR #1586
  if [[ -n "$version_snapshot_file" ]]; then
    if [[ ! -s "$version_snapshot_file" ]]; then
      echo "::error::Package snapshot is missing or empty for lancache-ng/${service}: $version_snapshot_file"
      had_errors=1
      return
    fi
    if ! version_list="$(jq -cs 'sort_by((.created_at // ""), .id)[]' "$version_snapshot_file" 2>&1)"; then
      echo "::error::Failed to normalize/sort the audit package snapshot for lancache-ng/${service}: $version_list"
      had_errors=1
      return
    fi
  else
    # What: compatibility path for direct unit tests and standalone sourced use.
    # Why: production workers always pass the audit snapshot; keeping this path
    # avoids coupling process_service() unit coverage to the audit subprocess.
    # From: Issue #1585 | PR #1586
    local versions_stderr
    versions_stderr="$(mktemp)"
    if ! versions_json="$(gh api --paginate "orgs/${org}/packages/container/${package}/versions" 2>"$versions_stderr")"; then
      local list_error
      list_error="$(cat "$versions_stderr")"
      rm -f "$versions_stderr"
      if [[ "$list_error" == *"HTTP 404"* ]]; then
        echo "::notice::lancache-ng/${service} has no GHCR package yet (HTTP 404 listing its versions) -- nothing to reap for a service with no images published. Not treated as an error."
        services_not_found=$((services_not_found + 1))
        return
      fi
      echo "::error::Failed to list package versions for lancache-ng/${service}: $list_error"
      had_errors=1
      return
    fi
    rm -f "$versions_stderr"
    if ! version_list="$(printf '%s' "$versions_json" | jq -c 'sort_by((.created_at // ""), .id)[]' 2>&1)"; then
      echo "::error::Failed to enumerate/sort package versions for lancache-ng/${service} via jq: $version_list"
      had_errors=1
      return
    fi
  fi

  local orphan_phase_ok=1
  local registry_token=""
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
  local version_id tag_list planned_identity planned_digest planned_tags current_digest current_tags retention_candidate
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service reached its per-run deletion cap ($max_deletions_per_service); remaining versions are deferred without further candidate-specific API work."
      return 0
    fi
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

    # What: sha256-<subject> tags are NOT added to the forward child set.
    # Why: they are reverse attestation/referrer edges; allowing a stale
    # attestation to protect its otherwise-orphaned subject creates a cycle
    # in which neither object can ever become garbage.
    # From: Issue #1585 | PR #1586
    local protected=0 has_closed_pr_tag=0 tag
    retention_candidate=0
    if [[ -n "${retention_delete_candidates[$version_id]:-}" ]]; then
      planned_identity="${retention_delete_candidates[$version_id]}"
      IFS=$'\t' read -r planned_digest planned_tags <<<"$planned_identity"
      if ! current_digest="$(jq -r '.name' <<<"$version_entry")" \
          || ! current_tags="$(jq -r '.metadata.container.tags | sort | join(",")' <<<"$version_entry")"; then
        echo "::error::Could not verify the planned retention identity for $service version $version_id; keeping it."
        had_errors=1
        protected=1
      elif [[ "$current_digest" == "$planned_digest" && "$current_tags" == "$planned_tags" ]]; then
        retention_candidate=1
      else
        echo "::notice::Keeping $service version $version_id because its initial GC listing no longer matches the retention plan."
        protected=1
      fi
    fi

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
        if [[ "$retention_candidate" == "1" ]]; then
          continue
        fi
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
              manifest_children_by_version["$version_id"]+="${child_digest}"$'\n'
            done <<< "$children_output"
          fi
        fi
      fi
    fi

    if [[ "$protected" == "1" || ( "$has_closed_pr_tag" == "0" && "$retention_candidate" == "0" ) ]]; then
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

    # What: tags_display is cosmetic (log message only); a jq failure here
    # degrades the message instead of aborting.
    # Why: this isn't actually blocking the delete, since tag_list above
    # already fully resolved this version's tags.
    # From: Issue #1095 | PR #1443
    local tags_display
    tags_display="$(printf '%s' "$version_entry" | jq -rc '.metadata.container.tags // []' 2>&1)" || tags_display="<jq error: $tags_display>"
    if [[ "$retention_candidate" == "1" ]]; then
      if gc_revalidate_retention_candidate "$service" "$package" "$version_id" "$planned_digest" "$planned_tags"; then
        :
      else
        revalidate_status=$?
        if (( revalidate_status == 1 )); then
          had_errors=1
        fi
        kept=$((kept + 1))
        continue
      fi
      delete_description="$service version $version_id (ordinary root beyond retention budget; tags: $tags_display)"
    else
      if ! current_digest="$(jq -r '.name' <<<"$version_entry")" \
          || ! current_tags="$(jq -r '.metadata.container.tags | sort | join(",")' <<<"$version_entry")"; then
        echo "::error::Could not build the fresh-revalidation identity for closed-PR $service version $version_id; keeping it."
        had_errors=1
        kept=$((kept + 1))
        continue
      fi
      if gc_revalidate_retention_candidate "$service" "$package" "$version_id" "$current_digest" "$current_tags"; then
        :
      else
        revalidate_status=$?
        if (( revalidate_status == 1 )); then
          had_errors=1
        fi
        kept=$((kept + 1))
        continue
      fi
      delete_description="$service version $version_id (only closed-PR staging tags: $tags_display)"
    fi

    if gc_delete_version "orgs/${org}/packages/container/${package}/versions/${version_id}" "$delete_description"; then
      service_deletions=$((service_deletions + 1))
      deleted_version_ids["$version_id"]=1
    fi
  done <<< "$version_list"

  # What: protects forward children of every tagged parent that remains after Pass 1.
  # Why: shared platform/attestation closure follows the final simulated/real
  # parent state, not the stale inventory state from before retention deletes.
  # From: Issue #1095 | PR #1586
  local parent_version_id retained_child_digest
  for parent_version_id in "${!manifest_children_by_version[@]}"; do
    [[ -z "${deleted_version_ids[$parent_version_id]:-}" ]] || continue
    while IFS= read -r retained_child_digest; do
      [[ -n "$retained_child_digest" ]] || continue
      protected_children_digests["$retained_child_digest"]=1
    done <<<"${manifest_children_by_version[$parent_version_id]}"
  done

  # What: rebuilds live root/subject identities from the versions that remain
  # after Pass 1 (WOULD_DELETE counts as removed in dry-run simulation).
  # Why: tagged closure must still be collectible on a later sweep when its
  # root was deleted in an earlier run; same-run removed_* maps lose that fact.
  # From: Issue #1585 | PR #1586
  local retained_version_id retained_digest retained_tags
  while IFS= read -r version_entry; do
    [[ -n "$version_entry" ]] || continue
    if ! retained_version_id="$(jq -r '.id' <<<"$version_entry")" \
        || ! retained_digest="$(jq -r '.name' <<<"$version_entry")" \
        || ! retained_tags="$(jq -r '.metadata.container.tags[]? // empty' <<<"$version_entry")"; then
      echo "::error::Could not rebuild retained root/subject identities for $service; disabling closure/orphan deletion this run."
      had_errors=1
      orphan_phase_ok=0
      break
    fi
    [[ -z "${deleted_version_ids[$retained_version_id]:-}" ]] || continue
    if [[ -n "$retained_tags" ]]; then
      live_subject_digests["$retained_digest"]=1
    fi
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      kind="$(sra_tag_kind "$tag")" || continue
      if [[ "$kind" == root$'\t'* ]]; then
        prefix="${kind#root$'\t'}"
        retained_root_prefixes["$prefix"]=1
      fi
    done <<<"$retained_tags"
  done <<<"$version_list"
  for retained_child_digest in "${!protected_children_digests[@]}"; do
    live_subject_digests["$retained_child_digest"]=1
  done

  # What: Pass 1.5 removes tagged closure whose root/subject is no longer live.
  # Why: sha-*-<arch> and sha256-<subject> objects must remain collectible
  # across GC runs instead of requiring their root to be deleted in this run.
  # From: Issue #1095 | Issue #1585 | PR #1586
  if [[ "$orphan_phase_ok" == "1" ]]; then
    local associated_candidate associated_tag_count association_ok candidate_digest expected_tags
    local child_subject_digest
    while IFS= read -r version_entry; do
      [[ -n "$version_entry" ]] || continue
      if (( service_deletions >= max_deletions_per_service )); then
        echo "::notice::$service reached its per-run deletion cap ($max_deletions_per_service); remaining closure/orphan work is deferred without further candidate-specific API work."
        return 0
      fi
      version_id="$(jq -r '.id' <<<"$version_entry")" || { had_errors=1; continue; }
      [[ -n "${deleted_version_ids[$version_id]:-}" ]] && continue
      tag_list="$(jq -r '.metadata.container.tags[]? // empty' <<<"$version_entry")" || { had_errors=1; continue; }
      [[ -n "$tag_list" ]] || continue
      candidate_digest="$(jq -r '.name' <<<"$version_entry")" || { had_errors=1; continue; }
      [[ -z "${protected_children_digests[$candidate_digest]:-}" ]] || continue

      associated_candidate=1
      associated_tag_count=0
      while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        associated_tag_count=$((associated_tag_count + 1))
        association_ok=0
        kind="$(sra_tag_kind "$tag")" || { associated_candidate=0; break; }
        if [[ "$kind" == child$'\t'* ]]; then
          prefix="${kind#child$'\t'}"
          prefix="${prefix%%$'\t'*}"
          [[ -z "${retained_root_prefixes[$prefix]:-}" ]] && association_ok=1
        elif [[ "$tag" =~ ^sha256-([0-9a-f]{64})$ ]]; then
          child_subject_digest="sha256:${BASH_REMATCH[1]}"
          [[ -z "${live_subject_digests[$child_subject_digest]:-}" ]] && association_ok=1
        fi
        if [[ "$association_ok" == "0" ]]; then
          associated_candidate=0
          break
        fi
      done <<<"$tag_list"
      (( associated_candidate == 1 && associated_tag_count > 0 )) || continue

      if ! created_at="$(jq -r '.created_at // empty' <<<"$version_entry")" \
          || ! created_epoch="$(gcps_created_at_to_epoch "$created_at")"; then
        echo "::error::Could not prove age for $service retention-closure version $version_id; keeping it."
        had_errors=1
        kept=$((kept + 1))
        continue
      fi
      if ! gcps_is_old_enough_to_delete "$created_epoch" "$now_epoch" "$min_age_seconds"; then
        kept=$((kept + 1))
        continue
      fi
      expected_tags="$(jq -r '.metadata.container.tags | sort | join(",")' <<<"$version_entry")" || { had_errors=1; kept=$((kept + 1)); continue; }
      if gc_revalidate_retention_candidate "$service" "$package" "$version_id" "$candidate_digest" "$expected_tags"; then
        :
      else
        revalidate_status=$?
        (( revalidate_status == 1 )) && had_errors=1
        kept=$((kept + 1))
        continue
      fi
      delete_description="$service version $version_id (unprotected tagged closure with no live root/subject; tags: $expected_tags)"
      if gc_delete_version "orgs/${org}/packages/container/${package}/versions/${version_id}" "$delete_description"; then
        service_deletions=$((service_deletions + 1))
        deleted_version_ids["$version_id"]=1
        unset "live_subject_digests[$candidate_digest]"
        (( kept > 0 )) && kept=$((kept - 1))
      fi
    done <<<"$version_list"
  fi

  if [[ "$orphan_phase_ok" != "1" ]]; then
    return
  fi

  # What: Pass 2 -- orphan classification against the retained-parent graph.
  # Why: children of roots removed in this or a prior run must not remain
  # protected by stale edges from the beginning of this sweep.
  # From: Issue #1095 | Issue #1585 | PR #1586
  while IFS= read -r version_entry; do
    [[ -z "$version_entry" ]] && continue
    if (( service_deletions >= max_deletions_per_service )); then
      echo "::notice::$service reached its per-run deletion cap ($max_deletions_per_service); remaining orphan work is deferred without further candidate-specific API work."
      return 0
    fi
    if ! version_id="$(printf '%s' "$version_entry" | jq -r '.id' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -z "$version_id" || "$version_id" == "null" ]] && continue
    [[ -n "${deleted_version_ids[$version_id]:-}" ]] && continue

    if ! tag_list="$(printf '%s' "$version_entry" | jq -r '(.metadata.container.tags // [])[]' 2>&1)"; then
      had_errors=1
      continue
    fi
    [[ -n "$tag_list" ]] && continue # tagged -- already handled in Pass 1/1.5

    if ! name="$(printf '%s' "$version_entry" | jq -r '.name' 2>&1)"; then
      echo "::error::Failed to read a package version's name/digest for $service via jq: $name"
      had_errors=1
      continue
    fi
    if [[ -n "${protected_children_digests[$name]:-}" ]]; then
      # What: still referenced as a forward child by a parent that remains.
      # Why: only retained-parent edges protect closure; an edge from a root
      # deleted earlier in this sweep must not make the child immortal.
      # From: Issue #1095 | PR #1586
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

    # What: a candidate with no retained `.manifests[]` parent may still be a
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
    if ! subject_digest="$(gcps_extract_manifest_subject "$candidate_manifest")"; then
      echo "::error::Could not parse $service candidate orphan $name's subject relationship; keeping it."
      had_errors=1
      kept=$((kept + 1))
      continue
    fi
    if [[ -n "$subject_digest" && -n "${live_subject_digests[$subject_digest]:-}" ]]; then
      # What: an OCI referrer is retained only while its subject is itself live.
      # Why: mere existence of an otherwise-orphaned subject must not create a
      # subject<->attestation retention cycle that survives forever.
      # From: Issue #1585 | PR #1586
      kept=$((kept + 1))
      continue
    fi

    # What: revalidates an orphan's exact identity and still-empty tag set.
    # Why: a version can gain a channel/release/root tag after the package
    # snapshot was taken; stale untagged evidence must never authorize DELETE.
    # From: Issue #1585 | PR #1586
    if gc_revalidate_retention_candidate "$service" "$package" "$version_id" "$name" ""; then
      :
    else
      revalidate_status=$?
      (( revalidate_status == 1 )) && had_errors=1
      kept=$((kept + 1))
      continue
    fi

    if gc_delete_version "orgs/${org}/packages/container/${package}/versions/${version_id}" \
        "$service version $version_id (untagged, unreferenced orphan digest $name)"; then
      service_deletions=$((service_deletions + 1))
      deleted_version_ids["$version_id"]=1
    fi
  done <<< "$version_list"
}

# What: runs one package worker and serializes its mutable counters.
# Why: background shells cannot update the parent's globals directly, so
# bounded package concurrency needs an explicit result handoff.
# From: Issue #1095.
gc_run_package_worker() {
  local service="$1" result_file="$2" package_deletion_cap="$3"
  max_deletions_per_service="$package_deletion_cap"
  had_errors=0
  deleted=0
  kept=0
  would_delete=0
  pr_lookup_failures=0
  services_not_found=0
  # What: suppresses SC2034 for the worker-local reset of the nameref cache.
  # Why: gcps_pr_lookup_state accesses pr_state_cache indirectly through local -n.
  # From: Issue #1095 | PR #1585.
  # shellcheck disable=SC2034
  pr_state_cache=()

  if ! gc_build_service_retention_plan "$service"; then
    # What: skips the second collector phase when the authoritative plan failed.
    # Why: retrying the same package through an independent full listing after
    # an API failure increases pressure and cannot restore safe SHA evidence.
    # From: Issue #1585 | PR #1586
    had_errors=1
  elif (( retention_package_absent == 0 )); then
    process_service "$service" "$retention_versions_snapshot"
  fi
  if [[ -n "$retention_versions_snapshot" ]]; then
    rm -f -- "$retention_versions_snapshot"
    retention_versions_snapshot=""
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$had_errors" "$deleted" "$kept" "$would_delete" "$pr_lookup_failures" "$services_not_found" >"$result_file"
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
  for required_cmd in gh jq curl date git awk mkdir mktemp sleep sort uniq; do
    if ! command -v "$required_cmd" >/dev/null 2>&1; then
      echo "::error::Required tool '$required_cmd' was not found on this runner. This script cannot run without it."
      exit 1
    fi
  done

  [[ "$max_deletions_per_service" =~ ^[0-9]+$ ]] || {
    echo "::error::GC_MAX_DELETIONS_PER_SERVICE must be a non-negative integer."
    exit 1
  }
  [[ "$max_deletions_total" =~ ^[0-9]+$ ]] || {
    echo "::error::GC_MAX_DELETIONS_TOTAL must be a non-negative integer."
    exit 1
  }
  [[ "$min_age_seconds" =~ ^[0-9]+$ ]] || {
    echo "::error::GC_MIN_AGE_SECONDS must be a non-negative integer."
    exit 1
  }
  [[ "$gc_concurrency" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::GC_CONCURRENCY must be a positive integer."
    exit 1
  }
  case "$gc_dry_run" in
    true | false) ;;
    *) echo "::error::GC_DRY_RUN must be exactly true or false."; exit 1 ;;
  esac
  [[ -f "$manifest" ]] || {
    echo "::error::Retention manifest is missing: $manifest"
    exit 1
  }
  if retention_history_refs="$(gc_resolve_retention_history_refs)"; then
    :
  else
    echo "::error::Cannot establish the managed Git histories used by GHCR retention."
    exit 1
  fi

  local target_class target_name target_inventory
  local -a package_targets=("${services[@]}")
  if target_inventory="$(sra_manifest_packages "$manifest" "metadata legacy")"; then
    :
  else
    echo "::error::Could not derive metadata/legacy GC targets from $manifest."
    exit 1
  fi
  while IFS=$'\t' read -r target_class target_name; do
    [[ -n "$target_class" && -n "$target_name" ]] || continue
    package_targets+=("$target_name")
  done <<<"$target_inventory"

  local package_count quota_base quota_remainder quota index
  local -a package_quotas=()
  package_count="${#package_targets[@]}"
  quota_base=$((max_deletions_total / package_count))
  quota_remainder=$((max_deletions_total % package_count))
  for (( index=0; index<package_count; index++ )); do
    quota="$quota_base"
    (( index < quota_remainder )) && quota=$((quota + 1))
    (( quota > max_deletions_per_service )) && quota="$max_deletions_per_service"
    package_quotas+=("$quota")
  done

  if (( gc_concurrency > package_count )); then
    gc_concurrency="$package_count"
  fi

  # What: shares confirmed PR planning states across package-worker shells.
  # Why: without a run-local cross-worker cache the same PR is queried once
  # per package, multiplying GitHub API pressure during large registry sweeps.
  # Fresh pre-delete checks bypass this directory explicitly.
  # From: Issue #1585 | PR #1586
  local shared_pr_cache_dir
  shared_pr_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/lancache-ng-gc-pr-state.XXXXXX")"
  GCPS_PR_STATE_CACHE_DIR="$shared_pr_cache_dir"
  export GCPS_PR_STATE_CACHE_DIR

  local offset batch_end pid result_file log_file worker_failed
  local worker_had_errors worker_deleted worker_kept worker_would_delete worker_pr_failures worker_not_found
  local -a worker_pids=() worker_results=() worker_logs=()
  for (( offset=0; offset<${#package_targets[@]}; offset+=gc_concurrency )); do
    worker_pids=()
    worker_results=()
    worker_logs=()
    batch_end=$((offset + gc_concurrency))
    (( batch_end > ${#package_targets[@]} )) && batch_end="${#package_targets[@]}"

    for (( index=offset; index<batch_end; index++ )); do
      result_file="$(mktemp)"
      log_file="$(mktemp)"
      gc_run_package_worker "${package_targets[$index]}" "$result_file" "${package_quotas[$index]}" >"$log_file" 2>&1 &
      worker_pids+=("$!")
      worker_results+=("$result_file")
      worker_logs+=("$log_file")
    done

    for index in "${!worker_pids[@]}"; do
      pid="${worker_pids[$index]}"
      worker_failed=0
      if ! wait "$pid"; then
        worker_failed=1
      fi
      if ! cat "${worker_logs[$index]}"; then
        worker_failed=1
      fi
      if [[ ! -s "${worker_results[$index]}" ]]; then
        echo "::error::GHCR GC package worker $pid produced no result record."
        worker_failed=1
      else
        IFS=$'\t' read -r worker_had_errors worker_deleted worker_kept worker_would_delete worker_pr_failures worker_not_found <"${worker_results[$index]}"
        if [[ ! "$worker_had_errors" =~ ^[0-9]+$ \
            || ! "$worker_deleted" =~ ^[0-9]+$ \
            || ! "$worker_kept" =~ ^[0-9]+$ \
            || ! "$worker_would_delete" =~ ^[0-9]+$ \
            || ! "$worker_pr_failures" =~ ^[0-9]+$ \
            || ! "$worker_not_found" =~ ^[0-9]+$ ]]; then
          echo "::error::GHCR GC package worker $pid produced a malformed result record."
          worker_failed=1
        else
          deleted=$((deleted + worker_deleted))
          kept=$((kept + worker_kept))
          would_delete=$((would_delete + worker_would_delete))
          pr_lookup_failures=$((pr_lookup_failures + worker_pr_failures))
          services_not_found=$((services_not_found + worker_not_found))
          (( worker_had_errors == 0 )) || worker_failed=1
        fi
      fi
      rm -f -- "${worker_results[$index]}" "${worker_logs[$index]}"
      (( worker_failed == 0 )) || had_errors=1
    done
  done

  rm -rf -- "$shared_pr_cache_dir"
  unset GCPS_PR_STATE_CACHE_DIR

  echo "::notice::GHCR GC complete: deleted $deleted version(s), would-delete $would_delete version(s) in dry-run mode, kept $kept classification(s)."

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
  local max_services_not_found=$(( (${#package_targets[@]} / 2) + 1 ))
  if (( services_not_found >= max_services_not_found )); then
    echo "::error::$services_not_found of ${#package_targets[@]} configured packages reported no GHCR package this run (threshold: $max_services_not_found) -- this many simultaneous 404s is consistent with a read:packages credential problem."
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
