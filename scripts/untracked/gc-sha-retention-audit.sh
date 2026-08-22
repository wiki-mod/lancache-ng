#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: read-only GHCR retention audit -- inventories, ranks, and classifies.
# Why: never issues DELETE; the destructive GC may consume only its exact
# would-delete identities after independent live safety revalidation.
# From: Issue #1095 | PR #1586
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# What: the `# shellcheck source=` lines below are shellcheck directives.
# Why: not commented-out code -- they tell the linter which file a dynamic
# `source` call resolves to, since shellcheck cannot infer that itself.
# From: Issue #1095 | PR #1586
# shellcheck source=scripts/lib/github-api-retry.sh
source "$repo_root/scripts/lib/github-api-retry.sh"
# shellcheck source=scripts/lib/sha-retention-audit.sh
source "$repo_root/scripts/lib/sha-retention-audit.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

manifest="${SRA_MANIFEST:-$repo_root/release/stack-images.yml}"
history_refs_raw="${SRA_HISTORY_REFS:-${SRA_HISTORY_REF:-origin/current_dev}}"
package_filter="${SRA_PACKAGE_FILTER:-}"
version_snapshot_file="${SRA_VERSION_SNAPSHOT_FILE:-}"
max_pages_per_package="${SRA_MAX_PAGES_PER_PACKAGE:-500}"
# What: bounds how many packages are audited concurrently in one batch.
# Why: package listings/classifications are independent and dominate live
# runtime; a background-worker batch (see the main loop below) is what
# makes a full ~26,000-version registry audit finish inside CI's job
# timeout instead of the single-package-at-a-time run that originally
# timed out at this issue's opening.
# From: Issue #1585.
audit_concurrency="${SRA_CONCURRENCY:-2}"
# What: optional path to the v1.2 incremental classification cache.
# Why: opt-in/fail-safe -- unset, or any cache failure/miss, falls back to
# full classification; a read also requires an exact history_fingerprint
# match (see sra_history_refs_fingerprint), not just digest+tags, since two
# real callers here classify against different managed-history ref sets.
# From: Issue #1585 | Issue #1095.
#
# What: sra_cache_write_package's sqlite3 connection sets no busy_timeout.
# Why: concurrent workers writing the same cache_db can hit SQLITE_BUSY,
# handled as a soft ::warning:: (falls back to full classification next
# run), never a hard error or corrupted decision. Flagged for follow-up.
# From: Issue #1585.
cache_db="${SRA_CACHE_DB:-}"
per_page=100

if [[ -n "$version_snapshot_file" && -z "$package_filter" ]]; then
  echo "::error::SRA_VERSION_SNAPSHOT_FILE requires SRA_PACKAGE_FILTER so one snapshot maps to exactly one package." >&2
  exit 1
fi

[[ "$GITHUB_REPOSITORY" == */* ]] || {
  echo "::error::GITHUB_REPOSITORY must be in owner/repository form." >&2
  exit 1
}
owner="${GITHUB_REPOSITORY%%/*}"
repository_name="${GITHUB_REPOSITORY#*/}"
[[ -n "$owner" && -n "$repository_name" ]] || {
  echo "::error::GITHUB_REPOSITORY must contain a non-empty owner and repository." >&2
  exit 1
}
[[ "$max_pages_per_package" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::SRA_MAX_PAGES_PER_PACKAGE must be a positive integer." >&2
  exit 1
}
[[ "$audit_concurrency" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::SRA_CONCURRENCY must be a positive integer." >&2
  exit 1
}

for required_command in awk cp curl git jq mktemp sort uniq; do
  command -v "$required_command" >/dev/null 2>&1 || {
    echo "::error::Required command is unavailable: $required_command" >&2
    exit 1
  }
done

[[ -f "$manifest" ]] || {
  echo "::error::Retention manifest is missing: $manifest" >&2
  exit 1
}

if retention_keep="$(sra_read_retention_keep "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid accepted_ordinary_roots_per_package value from $manifest." >&2
  exit 1
fi
# What: reads how many newest vX.Y.Z tags per package still count as supported.
# Why: needed for protected-reference classification below.
# From: Issue #1095 | PR #1586
if minimum_stable_releases="$(sra_read_minimum_stable_releases "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid minimum_stable_releases value from $manifest." >&2
  exit 1
fi
# What: reads the v1.2 non-ordinary-version safety-buffer count.
# Why: needed below for the inverted-protection buffer/would-delete ranking.
# From: Issue #1585.
if channel_buffer="$(sra_read_channel_buffer_versions "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid channel_buffer_versions value from $manifest." >&2
  exit 1
fi

# What: reads and format-validates retention.rollback_anchors defensively.
# Why: an explicit, maintainer-curated digest list, independent of git
# history/tags/release status; re-validated here since this script has no
# guarantee validate-stack-images.sh's static CI check already ran first.
# From: Issue #1095 | PR #1586
if retention_rollback_anchors_raw="$(sra_read_rollback_anchors "$manifest")"; then
  :
else
  echo "::error::Cannot read a valid (possibly empty) rollback_anchors list from $manifest." >&2
  exit 1
fi
if retention_rollback_anchors_error="$(sra_validate_rollback_anchors_list "$retention_rollback_anchors_raw")"; then
  :
else
  echo "::error::Manifest retention.rollback_anchors ${retention_rollback_anchors_error}" >&2
  exit 1
fi
declare -A retention_rollback_anchor_digests=()
if [[ -n "$retention_rollback_anchors_raw" ]]; then
  while IFS= read -r retention_rollback_anchor_entry; do
    [[ -n "$retention_rollback_anchor_entry" ]] || continue
    retention_rollback_anchor_digests["$retention_rollback_anchor_entry"]=1
  done <<<"$retention_rollback_anchors_raw"
fi
# What: tracks which declared rollback anchors were actually observed.
# Why: an anchor is proven real only by being seen among a package's fetched
# GHCR versions; the post-loop check below fails closed on any unobserved one.
# From: Issue #1095 | PR #1586
declare -A retention_rollback_anchor_found=()

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/lancache-ng-sha-retention-audit.XXXXXX")"
# What: removes work_dir on exit, guarded by an own-prefix path check.
# Why: the guard keeps this rm -rf from ever touching anything but this
# script's own mktemp path, even if work_dir were somehow reassigned.
# From: Issue #1095 | PR #1501.
cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == */lancache-ng-sha-retention-audit.* ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

packages_file="$work_dir/packages.tsv"
# What: filtered mode includes declared legacy packages for per-package GC.
# Why: standalone audit keeps its original first-party scope while the GC
# can intentionally retire manifest-declared historical package names.
# From: Issue #1095 | PR #1586
if [[ -n "$package_filter" ]]; then
  sra_manifest_packages "$manifest" "runtime tooling metadata legacy" >"$packages_file"
elif sra_manifest_packages "$manifest" >"$packages_file"; then
  :
else
  echo "::error::Cannot derive first-party package inventory from $manifest." >&2
  exit 1
fi
[[ -s "$packages_file" ]] || {
  echo "::error::First-party package inventory is empty." >&2
  exit 1
}

if [[ -n "$package_filter" ]]; then
  filtered_packages="$work_dir/packages.filtered.tsv"
  awk -F '\t' -v wanted="$package_filter" '$2 == wanted { print }' "$packages_file" >"$filtered_packages"
  mv -- "$filtered_packages" "$packages_file"
  [[ -s "$packages_file" ]] || {
    echo "::error::SRA_PACKAGE_FILTER is not declared in $manifest: $package_filter" >&2
    exit 1
  }
fi

duplicate_packages="$(sort "$packages_file" | uniq -d)"
[[ -z "$duplicate_packages" ]] || {
  echo "::error::Duplicate first-party package inventory entries were found: $duplicate_packages" >&2
  exit 1
}
if [[ -z "$package_filter" ]]; then
  for required_class in runtime tooling metadata; do
    if awk -F '\t' -v wanted="$required_class" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }' "$packages_file"; then
      :
    else
      echo "::error::Manifest inventory has no $required_class package." >&2
      exit 1
    fi
  done
fi

read -r -a history_refs <<<"$history_refs_raw"
(( ${#history_refs[@]} > 0 )) || {
  echo "::error::No managed Git history refs were supplied." >&2
  exit 1
}

declare -A history_rank=()
history_index=0
for history_ref in "${history_refs[@]}"; do
  git -C "$repo_root" rev-parse --verify --quiet "${history_ref}^{commit}" >/dev/null || {
    echo "::error::Managed history ref is unavailable in the full checkout: $history_ref" >&2
    exit 1
  }
  history_index=$((history_index + 1))
  history_file="$work_dir/history-${history_index}.txt"
  if git -C "$repo_root" rev-list --first-parent "$history_ref" >"$history_file"; then
    :
  else
    echo "::error::Cannot enumerate first-parent history for $history_ref." >&2
    exit 1
  fi
  [[ -s "$history_file" ]] || {
    echo "::error::First-parent history is empty for $history_ref." >&2
    exit 1
  }

  history_position=0
  while IFS= read -r history_commit; do
    [[ "$history_commit" =~ ^[0-9a-f]{40}$ ]] || {
      echo "::error::Unexpected commit value in $history_ref history: $history_commit" >&2
      exit 1
    }
    history_position=$((history_position + 1))
    if [[ -z "${history_rank[$history_commit]:-}" ]] || (( history_position < history_rank[$history_commit] )); then
      history_rank["$history_commit"]="$history_position"
    fi
  done <"$history_file"
done

# What: fingerprints this run's managed-history ref set for the cache.
# Why: gates every cache read in audit_package (see SRA_CACHE_DB above).
# From: Issue #1095.
if history_fingerprint="$(sra_history_refs_fingerprint "$repo_root" "${history_refs[@]}")"; then
  :
else
  echo "::error::Cannot compute a history-refs fingerprint for the managed ref set." >&2
  exit 1
fi

# What: audits one package -- fetches, classifies, prints AUDIT/SUMMARY lines.
# Why: the single per-package entry point; everything else in this file only
# sets up its inputs (manifest, history, credentials) or loops over it.
# From: Issue #1095 | PR #1586
audit_package() {
  local class="${1:?audit_package: class is required}"
  local package="${2:?audit_package: package is required}"
  local anchor_result_file="${3:?audit_package: anchor result file is required}"
  local package_dir="$work_dir/${class}-${package}"
  local versions_file="$package_dir/versions.jsonl"
  local body_file="$package_dir/page.json"
  local page count url package_path
  local cache_rows_out

  mkdir -p "$package_dir"
  : >"$versions_file"
  package_path="${repository_name}%2F${package}"

  # What: loads this package's cached resolutions (v1.2 point 4).
  # Why: a fresh row set every run means a cache miss (no cache_db, no
  # sqlite3, first run, or a rotated-key restore-keys fallback with no
  # matching data) degrades to a plain empty array -- every version below
  # then simply takes the existing full-classification path unchanged.
  # From: Issue #1585.
  declare -A cache_hits=()
  cache_rows_out="$package_dir/cache-rows-out.tsv"
  : >"$cache_rows_out"
  if [[ -n "$cache_db" ]]; then
    local cache_version_id cache_digest cache_tags cache_resolution
    while IFS=$'\t' read -r cache_version_id cache_digest cache_tags cache_resolution; do
      [[ "$cache_version_id" =~ ^[0-9]+$ ]] || continue
      cache_hits["$cache_version_id"]="${cache_digest}"$'\t'"${cache_tags}"$'\t'"${cache_resolution}"
    done < <(sra_cache_read_package "$cache_db" "$package" "$history_fingerprint" 2>/dev/null || true)
  fi

  for (( page=1; page<=max_pages_per_package; page++ )); do
    url="https://api.github.com/orgs/${owner}/packages/container/${package_path}/versions?per_page=${per_page}&page=${page}"
    if github_api_get_with_retry "$url" "$body_file"; then
      :
    else
      echo "::error::Cannot read package versions for ${repository_name}/${package}; audit for this package is incomplete." >&2
      return 1
    fi
    if sra_validate_version_page "$body_file"; then
      :
    else
      echo "::error::Package-version page $page has an unexpected schema for ${repository_name}/${package}; refusing to classify partial data." >&2
      return 1
    fi
    if count="$(jq -r 'length' "$body_file")"; then
      :
    else
      echo "::error::Cannot count package-version page $page for ${repository_name}/${package}." >&2
      return 1
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || {
      echo "::error::Package-version page $page returned an invalid item count for ${repository_name}/${package}: $count" >&2
      return 1
    }
    if ! jq -c '.[]' "$body_file" >>"$versions_file"; then
      echo "::error::Cannot normalize package-version page $page for ${repository_name}/${package}." >&2
      return 1
    fi
    if (( count < per_page )); then
      break
    fi
    if (( page == max_pages_per_package )); then
      echo "::error::Package-version pagination budget of $max_pages_per_package pages was exhausted for ${repository_name}/${package}; refusing to classify a truncated inventory." >&2
      return 1
    fi
  done

  [[ -s "$versions_file" ]] || {
    echo "::error::Package ${repository_name}/${package} returned no versions; retention state cannot be proven." >&2
    return 1
  }

  # What: exports the exact normalized inventory used for this filtered audit.
  # Why: the destructive collector can reuse the same snapshot for graph/PR/
  # orphan classification instead of immediately listing thousands of package
  # versions a second time; fresh per-version GETs still guard each DELETE.
  # From: Issue #1585 | PR #1586
  if [[ -n "$version_snapshot_file" ]]; then
    if cp -- "$versions_file" "$version_snapshot_file"; then
      :
    else
      echo "::error::Cannot export the filtered package-version snapshot for ${repository_name}/${package}." >&2
      return 1
    fi
  fi

  # What: computes this package's stable-release tag set once via one jq pass.
  # Why: avoids a per-version jq call (the cost class that made run
  # 31774741729 time out); a nonzero pipeline exit is treated as an empty
  # result, since `grep` alone exits 1 on zero matches under pipefail.
  # From: Issue #1095 | PR #1586
  local release_tags_file="$package_dir/release-tags.txt"
  if jq -r '.metadata.container.tags[]? // empty' "$versions_file" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u >"$release_tags_file"; then
    :
  else
    : >"$release_tags_file"
  fi
  local supported_releases
  supported_releases="$(sra_select_supported_release_tags "$minimum_stable_releases" <"$release_tags_file")" || {
    echo "::error::Cannot select supported stable-release tags for ${repository_name}/${package}." >&2
    return 1
  }

  local root_candidates="$package_dir/root-candidates.tsv"
  : >"$root_candidates"
  # What: v1.2 buffer pool for a rootless, non-channel-matched
  # version -- ranked by build date instead of git history (it has none).
  # Why: replaces the old unconditional "non-ordinary-version" permanent
  # protect; only the newest channel_buffer_versions such versions per
  # package stay protected, the rest become would-delete candidates.
  # From: Issue #1585.
  local other_tag_candidates="$package_dir/other-tag-candidates.tsv"
  : >"$other_tag_candidates"
  local version_json id digest tags built facts root_count child_count other_count
  local encoded_tags encoded_tag tag kind prefix full_commit rank min_rank
  local root_resolution_failed reason other_tags managed_root_count unmanaged_root_count
  local sort_key
  local cache_resolution cache_digest cache_tags
  local missing_build_date_count=0
  local direct_would_delete_count=0
  declare -A seen_id_digest=()
  declare -A seen_digest_id=()

  local version_fields created_at_raw
  while IFS= read -r version_json; do
    [[ -n "$version_json" ]] || continue
    # What: extracts id/digest/tags/created_at via one combined jq call.
    # Why: one call instead of four avoids the per-version subprocess cost;
    # "|"-joined (not @tsv) since bash `read` treats a literal tab as IFS
    # whitespace, silently collapsing an empty middle field.
    # From: Issue #1095 | PR #1501.
    if version_fields="$(jq -r '[.id, .name, (.metadata.container.tags | sort | join(",")), (.created_at // "")] | join("|")' <<<"$version_json")"; then
      :
    else
      echo "::error::Cannot extract identity/tag/date fields for a package version in ${repository_name}/${package}." >&2
      return 1
    fi
    IFS='|' read -r id digest tags created_at_raw <<<"$version_fields"

    if [[ -n "${seen_id_digest[$id]+x}" && "${seen_id_digest[$id]}" != "$digest" ]]; then
      echo "::error::Package version id $id mapped to more than one digest in ${repository_name}/${package}." >&2
      return 1
    fi
    if [[ -n "${seen_digest_id[$digest]+x}" && "${seen_digest_id[$digest]}" != "$id" ]]; then
      echo "::error::Digest $digest mapped to more than one package version id in ${repository_name}/${package}." >&2
      return 1
    fi
    if [[ -n "${seen_id_digest[$id]+x}" ]]; then
      continue
    fi
    seen_id_digest["$id"]="$digest"
    seen_digest_id["$digest"]="$id"

    # What: reports a missing/malformed build date as its own ::warning::.
    # Why: it is a real data-quality defect in the image-publish pipeline,
    # not something to fold silently into an unrelated classification.
    # From: Issue #1095 | PR #1501.
    if sra_validate_created_at_string "$created_at_raw"; then
      built="$created_at_raw"
    else
      built="unknown"
      (( missing_build_date_count += 1 ))
      echo "::warning::Package version $id (digest $digest) in ${repository_name}/${package} has no usable GHCR build date; this is a build-pipeline defect, not audit absence." >&2
    fi

    # What: checks rollback-anchor membership before every other classification.
    # Why: an explicit, maintainer-curated anchor is the highest-priority
    # protect signal and overrides tag/class/history-budget classification;
    # a match also marks this anchor "observed" for the post-loop check below.
    # From: Issue #1095 | PR #1586
    if sra_digest_is_rollback_anchor "$digest" "${!retention_rollback_anchor_digests[@]}"; then
      printf '%s\n' "$digest" >>"$anchor_result_file"
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "explicit-rollback-anchor"
      continue
    fi

    if facts="$(sra_version_tag_facts "$version_json")"; then
      :
    else
      echo "::error::Cannot classify tags for package version $id in ${repository_name}/${package}." >&2
      return 1
    fi
    IFS=$'\t' read -r root_count child_count other_count <<<"$facts"
    [[ "$root_count" =~ ^[0-9]+$ && "$child_count" =~ ^[0-9]+$ && "$other_count" =~ ^[0-9]+$ ]] || {
      echo "::error::Invalid tag classification counters for package version $id in ${repository_name}/${package}." >&2
      return 1
    }

    if (( root_count == 0 && child_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "closure" "protect" "artifact-child-closure-unresolved"
      continue
    fi
    # What: classifies a rootless version -- a truly untagged version
    # (other_count==0) stays permanently protected exactly as before; a
    # matched protected channel/release also stays protected; only a
    # rootless version that HAS tags but matches no protected channel
    # becomes a channel_buffer_versions-ranked candidate below.
    # Why: v1.2 targets "any historical or otherwise-
    # unanticipated tag FORMAT" -- a genuinely untagged version has no tag
    # format to be unanticipated, and is almost always a manifest-list's
    # own untagged amd64/arm64 platform child (this reaper's own separate
    # orphan-closure pass, not this classifier, is the correct place to
    # decide whether such a child is truly orphaned -- it already checks
    # forward-reference edges from a still-retained parent manifest, which
    # this classifier cannot see). Only "has tags, none recognized" is the
    # actual gap this rule inverts; an absence of tags is not that gap.
    # From: Issue #1585.
    if (( root_count == 0 && other_count == 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "non-ordinary-version"
      continue
    fi
    if (( root_count == 0 )); then
      other_tags="$(sra_other_tags_from_csv "$tags")" || {
        echo "::error::Cannot classify non-root tags for package version $id in ${repository_name}/${package}." >&2
        return 1
      }
      if reason="$(sra_protected_reference_reason "$other_tags" "$supported_releases")"; then
        sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "$reason"
      else
        # What: buffers this candidate for a build-date-ranked pass below.
        # Why: an "unknown" build date sorts first (oldest) on purpose, so a
        # missing date is treated conservatively as an early would-delete
        # candidate rather than accidentally winning the newest-first buffer.
        # From: Issue #1585.
        sort_key="$built"
        [[ "$sort_key" == "unknown" ]] && sort_key="0000-00-00T00:00:00Z"
        printf '%s\t%s\t%s\t%s\t%s\n' "$sort_key" "$id" "$digest" "$tags" "$built" >>"$other_tag_candidates"
      fi
      continue
    fi
    if (( child_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "mixed-root-and-child-tags"
      continue
    fi
    # What: classifies a root tag's extra tags into a protect reason, if any.
    # Why: promote retags an existing digest rather than rebuilding, so only
    # a recognized active channel/release may protect here.
    # From: Issue #1095 | PR #1586
    if (( other_count > 0 )); then
      other_tags="$(sra_other_tags_from_csv "$tags")" || {
        echo "::error::Cannot classify non-root tags for package version $id in ${repository_name}/${package}." >&2
        return 1
      }
      if reason="$(sra_protected_reference_reason "$other_tags" "$supported_releases")"; then
        sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "$reason"
        continue
      fi
    fi

    # What: reuses a cached git-history resolution instead of recomputing it.
    # Why: avoids one `git rev-parse`/`merge-base` pair per root tag; a hit
    # requires exact digest+tags (cache_hits is already fingerprint-filtered
    # by sra_cache_read_package above, per Issue #1095).
    # From: Issue #1585 | Issue #1095.
    cache_resolution=""
    if [[ -n "${cache_hits[$id]:-}" ]]; then
      IFS=$'\t' read -r cache_digest cache_tags cache_resolution <<<"${cache_hits[$id]}"
      if [[ "$cache_digest" != "$digest" || "$cache_tags" != "$tags" ]]; then
        cache_resolution=""
      fi
    fi

    if [[ -n "$cache_resolution" ]]; then
      case "$cache_resolution" in
        resolution-unknown)
          sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "sha-resolution-unknown"
          continue
          ;;
        outside-managed-history)
          sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "outside-managed-history" "outside-managed-history" "would-delete" "sha-not-on-managed-history"
          direct_would_delete_count=$((direct_would_delete_count + 1))
          continue
          ;;
        mixed-managed-unmanaged)
          sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "mixed-managed-and-unmanaged-root-tags"
          continue
          ;;
        rank-unknown)
          sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "sha-history-rank-unknown"
          continue
          ;;
        rank:*)
          min_rank="${cache_resolution#rank:}"
          if [[ "$min_rank" =~ ^[0-9]+$ ]]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$min_rank" "$id" "$digest" "$tags" "$built" >>"$root_candidates"
            printf '%s\t%s\t%s\t%s\n' "$id" "$digest" "$tags" "$cache_resolution" >>"$cache_rows_out"
            continue
          fi
          # What: falls through to full recomputation on a malformed cache value.
          # Why: fail-safe -- a corrupt/unexpected cached string must never
          # silently skip real classification (AG-INT-002).
          # From: Issue #1585.
          ;;
      esac
    fi

    if encoded_tags="$(jq -r '.metadata.container.tags[] | @base64' <<<"$version_json")"; then
      :
    else
      echo "::error::Cannot enumerate root tags for package version $id in ${repository_name}/${package}." >&2
      return 1
    fi
    min_rank=0
    root_resolution_failed=false
    managed_root_count=0
    unmanaged_root_count=0
    while IFS= read -r encoded_tag; do
      [[ -n "$encoded_tag" ]] || continue
      tag="$(jq -Rr '@base64d' <<<"$encoded_tag")" || {
        root_resolution_failed=true
        break
      }
      kind="$(sra_tag_kind "$tag")" || {
        root_resolution_failed=true
        break
      }
      [[ "$kind" == root$'\t'* ]] || continue
      prefix="${kind#root$'\t'}"
      if full_commit="$(sra_resolve_commit_prefix "$repo_root" "$prefix")"; then
        :
      else
        root_resolution_failed=true
        break
      fi
      rank="${history_rank[$full_commit]:-}"
      if [[ -z "$rank" ]]; then
        unmanaged_root_count=$((unmanaged_root_count + 1))
        continue
      fi
      managed_root_count=$((managed_root_count + 1))
      if (( min_rank == 0 || rank < min_rank )); then
        min_rank="$rank"
      fi
    done <<<"$encoded_tags"

    if [[ "$root_resolution_failed" == "true" ]]; then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "sha-resolution-unknown"
      printf '%s\t%s\t%s\t%s\n' "$id" "$digest" "$tags" "resolution-unknown" >>"$cache_rows_out"
      continue
    fi

    if (( managed_root_count == 0 && unmanaged_root_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "outside-managed-history" "outside-managed-history" "would-delete" "sha-not-on-managed-history"
      direct_would_delete_count=$((direct_would_delete_count + 1))
      printf '%s\t%s\t%s\t%s\n' "$id" "$digest" "$tags" "outside-managed-history" >>"$cache_rows_out"
      continue
    fi

    if (( unmanaged_root_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "mixed-managed-and-unmanaged-root-tags"
      printf '%s\t%s\t%s\t%s\n' "$id" "$digest" "$tags" "mixed-managed-unmanaged" >>"$cache_rows_out"
      continue
    fi

    if (( min_rank == 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "sha-history-rank-unknown"
      printf '%s\t%s\t%s\t%s\n' "$id" "$digest" "$tags" "rank-unknown" >>"$cache_rows_out"
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$min_rank" "$id" "$digest" "$tags" "$built" >>"$root_candidates"
    printf '%s\t%s\t%s\trank:%s\n' "$id" "$digest" "$tags" "$min_rank" >>"$cache_rows_out"
  done <"$versions_file"

  # What: persists this run's resolutions back to the cache database.
  # Why: a no-op when cache_db is unset, sqlite3 is unavailable, or nothing
  # was written this run (e.g. every version hit the cache already);
  # sra_cache_write_package's own command -v/[[ -f ]] guards make this safe
  # to call unconditionally in either case.
  # From: Issue #1585.
  if [[ -n "$cache_db" && -s "$cache_rows_out" ]]; then
    if sra_cache_init "$cache_db" && sra_cache_write_package "$cache_db" "$package" "$cache_rows_out" "$history_fingerprint"; then
      :
    else
      echo "::warning::Could not persist the v1.2 classification cache for ${repository_name}/${package}; the next run will fully reclassify it instead of using an incremental cache." >&2
    fi
  fi

  local sorted_candidates="$package_dir/root-candidates.sorted.tsv"
  if sort -n -k1,1 "$root_candidates" >"$sorted_candidates"; then
    :
  else
    echo "::error::Cannot sort legacy ordinary root identities for ${repository_name}/${package}." >&2
    return 1
  fi

  local legacy_position=0 budget decision reason would_delete_count="$direct_would_delete_count" package_retention_keep="$retention_keep"
  if [[ "$class" == "legacy" ]]; then
    package_retention_keep=0
  fi
  local budget_decision_line
  while IFS=$'\t' read -r rank id digest tags built; do
    [[ -n "$id" ]] || continue
    (( legacy_position += 1 ))
    # What: marks only roots outside the manifest's storage budget deletable.
    # Why: the destructive GC consumes these exact identities after its
    # independent age, tag, PR-state, graph, and live-revalidation gates.
    # From: Issue #1095.
    if budget_decision_line="$(sra_budget_decision "$legacy_position" "$package_retention_keep")"; then
      :
    else
      echo "::error::Cannot classify retention-budget position for package version $id in ${repository_name}/${package}." >&2
      return 1
    fi
    IFS=$'\t' read -r decision budget <<<"$budget_decision_line"
    if [[ "$decision" == "protect" ]]; then
      reason="ordinary-root-within-retention-budget"
    else
      reason="ordinary-root-beyond-retention-budget"
      (( would_delete_count += 1 ))
    fi
    sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "$legacy_position" "$budget" "$decision" "$reason"
  done <"$sorted_candidates"

  # What: ranks the v1.2 rootless/non-channel-matched
  # candidate pool by build date, newest first (no git-history root exists
  # to rank these by, unlike the ordinary sha-* roots above).
  # Why: replaces the old permanent "non-ordinary-version" protect with a
  # real, bounded buffer -- mirrors root_candidates' own plain sort-to-file
  # pattern immediately above (a direct redirect, not a pipe, so AG-VAL-032
  # does not apply here).
  # From: Issue #1585.
  local other_tag_sorted="$package_dir/other-tag-candidates.sorted.tsv"
  if sort -t $'\t' -k1,1r "$other_tag_candidates" >"$other_tag_sorted"; then
    :
  else
    echo "::error::Cannot sort non-ordinary-version candidates for ${repository_name}/${package}." >&2
    return 1
  fi
  local other_tag_position=0 other_tag_decision other_tag_budget other_tag_reason
  while IFS=$'\t' read -r rank id digest tags built; do
    [[ -n "$id" ]] || continue
    (( other_tag_position += 1 ))
    if budget_decision_line="$(sra_budget_decision "$other_tag_position" "$channel_buffer")"; then
      :
    else
      echo "::error::Cannot classify non-ordinary-version buffer position for package version $id in ${repository_name}/${package}." >&2
      return 1
    fi
    IFS=$'\t' read -r other_tag_decision other_tag_budget <<<"$budget_decision_line"
    if [[ "$other_tag_decision" == "protect" ]]; then
      other_tag_reason="non-ordinary-version-within-buffer"
    else
      other_tag_reason="non-ordinary-version-beyond-buffer"
      (( would_delete_count += 1 ))
    fi
    sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "$other_tag_position" "$other_tag_budget" "$other_tag_decision" "$other_tag_reason"
  done <"$other_tag_sorted"

  printf 'SUMMARY\tclass=%s\tpackage=%s\tlegacy_roots=%s\tretention_keep=%s\tchannel_buffer=%s\tnon_ordinary_versions=%s\twould_delete_count=%s\tmissing_build_date_count=%s\tdecision=protect-only\n' \
    "$class" "$package" "$legacy_position" "$package_retention_keep" "$channel_buffer" "$other_tag_position" "$would_delete_count" "$missing_build_date_count"
  if (( would_delete_count > 0 )); then
    echo "::notice::${repository_name}/${package}: $would_delete_count version(s) past their storage-retention budget (ordinary sha-* roots beyond $package_retention_keep, and/or non-ordinary-version candidates beyond the $channel_buffer-version buffer); this read-only audit performed no deletion." >&2
  fi
}

# What: audits packages in bounded batches and merges each worker deterministically.
# Why: package listings are independent and dominate the live runtime, while
# per-worker files preserve output, failures, and rollback-anchor evidence
# across the background-shell boundary under set -euo pipefail.
# From: Issue #1585
overall_status=0
mapfile -t package_targets <"$packages_file"
package_count="${#package_targets[@]}"
(( audit_concurrency <= package_count )) || audit_concurrency="$package_count"
for (( offset=0; offset<package_count; offset+=audit_concurrency )); do
  batch_end=$((offset + audit_concurrency))
  (( batch_end <= package_count )) || batch_end="$package_count"
  worker_pids=()
  worker_outputs=()
  worker_errors=()
  worker_anchors=()

  for (( index=offset; index<batch_end; index++ )); do
    IFS=$'\t' read -r package_class package_name <<<"${package_targets[$index]}"
    if [[ -z "$package_class" || -z "$package_name" ]]; then
      echo "::error::Malformed first-party package inventory entry." >&2
      overall_status=1
      continue
    fi
    worker_output="$work_dir/worker-${index}.out"
    worker_error="$work_dir/worker-${index}.err"
    worker_anchor="$work_dir/worker-${index}.anchors"
    : >"$worker_anchor"
    echo "::notice::Auditing read-only GHCR retention state for $package_class package ${repository_name}/${package_name}." >&2
    audit_package "$package_class" "$package_name" "$worker_anchor" >"$worker_output" 2>"$worker_error" &
    worker_pids+=("$!")
    worker_outputs+=("$worker_output")
    worker_errors+=("$worker_error")
    worker_anchors+=("$worker_anchor")
  done

  for worker_index in "${!worker_pids[@]}"; do
    if wait "${worker_pids[$worker_index]}"; then
      :
    else
      overall_status=1
    fi
    cat "${worker_outputs[$worker_index]}"
    cat "${worker_errors[$worker_index]}" >&2
    while IFS= read -r retention_rollback_anchor_entry; do
      [[ -n "$retention_rollback_anchor_entry" ]] || continue
      retention_rollback_anchor_found["$retention_rollback_anchor_entry"]=1
    done <"${worker_anchors[$worker_index]}"
  done
done

# What: fails closed on any declared rollback anchor never observed live.
# Why: an unobserved anchor is a typo, an already-deleted digest, or one
# that never existed; the error message itself notes an earlier package
# failure above as a possible cause, so this stays silent on that nuance.
# From: Issue #1095 | PR #1586
if [[ -z "$package_filter" ]]; then
for retention_rollback_anchor_entry in "${!retention_rollback_anchor_digests[@]}"; do
  if [[ -z "${retention_rollback_anchor_found[$retention_rollback_anchor_entry]+x}" ]]; then
    echo "::error::retention.rollback_anchors entry does not exist as a real package version digest in any audited first-party package: $retention_rollback_anchor_entry (if any package above failed to be audited this run, this may be a fetch failure rather than a genuinely missing digest -- resolve those errors before removing this entry)" >&2
    overall_status=1
  fi
done
fi

if (( overall_status != 0 )); then
  echo "::error::SHA retention audit was incomplete or encountered invalid required data. No destructive conclusion is permitted." >&2
  exit 1
fi

echo "::notice::SHA retention audit completed in read-only mode. would-delete records are storage-retention candidates for the separate destructive GC; this audit itself never deletes package versions." >&2
