#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: read-only GHCR audit: inventories, ranks, classifies
# Why: GC consumes would-delete identities only after revalidation
# From: Issue #1095 | PR #1586
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# What: `shellcheck source=` lines are linter directives
# Why: Tells linter which file dynamic source calls resolve to
# From: Issue #1095 | PR #1586
# shellcheck source=scripts/lib/github-api-retry.sh
source "$repo_root/scripts/lib/github-api-retry.sh"
# What: reuses gcps age-check + manifest-fetch helpers
# Why: avoids a second copy of either, per AG-CODE-011
# From: Issue #1095
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$repo_root/scripts/lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/gc-pr-staging-images.sh
source "$repo_root/scripts/lib/gc-pr-staging-images.sh"
# shellcheck source=scripts/lib/sha-retention-audit.sh
source "$repo_root/scripts/lib/sha-retention-audit.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

manifest="${SRA_MANIFEST:-$repo_root/release/stack-images.yml}"
history_refs_raw="${SRA_HISTORY_REFS:-${SRA_HISTORY_REF:-origin/current_dev}}"
package_filter="${SRA_PACKAGE_FILTER:-}"
version_snapshot_file="${SRA_VERSION_SNAPSHOT_FILE:-}"
max_pages_per_package="${SRA_MAX_PAGES_PER_PACKAGE:-500}"
# What: Bounds concurrent package audit batch size
# Why: Enables full registry audits within CI timeout via batching
# From: Issue #1585
audit_concurrency="${SRA_CONCURRENCY:-2}"
# What: optional path to the v1.2 incremental classification cache
# Why: Opt-in/fail-safe cache: misses fall back to classification
# From: Issue #1585
#
# What: Cache sqlite3 connection omits busy_timeout on purpose
# Why: Workers hitting SQLITE_BUSY fall back to full classification
# From: Issue #1585
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
# What: Reads how many newest version tags count as supported
# Why: needed for protected-reference classification below.
# From: Issue #1095 | PR #1586
if minimum_stable_releases="$(sra_read_minimum_stable_releases "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid minimum_stable_releases value from $manifest." >&2
  exit 1
fi
# What: Reads v1.2 non-ordinary-version safety-buffer count
# Why: Needed for inverted-protection buffer ranking
# From: Issue #1585
if channel_buffer="$(sra_read_channel_buffer_versions "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid channel_buffer_versions value from $manifest." >&2
  exit 1
fi

# What: Validates retention.rollback_anchors format defensively
# Why: Maintainer-curated digest list re-validated before use
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
# What: Tracks which rollback anchors were actually observed
# Why: Post-loop check fails closed on any unobserved anchor
# From: Issue #1095 | PR #1586
declare -A retention_rollback_anchor_found=()

# What: Discovers digests that live Dockerfile FROM lines build from
# Why: Extends protection to build dependencies dynamically
# From: Issue #1613
declare -A live_dockerfile_from_digests=()
while IFS= read -r live_dockerfile_path; do
  [[ -n "$live_dockerfile_path" ]] || continue
  live_dockerfile_content="$(cat "$repo_root/$live_dockerfile_path")"
  while IFS= read -r live_dockerfile_from_digest; do
    [[ -n "$live_dockerfile_from_digest" ]] || continue
    live_dockerfile_from_digests["$live_dockerfile_from_digest"]=1
  done < <(sra_dockerfile_from_digests "$live_dockerfile_content")
done < <(git -C "$repo_root" ls-files -- '*Dockerfile*')

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/lancache-ng-sha-retention-audit.XXXXXX")"
# What: Removes work_dir on exit guarded by path prefix check
# Why: Guard prevents rm -rf from touching anything but mktemp
# From: Issue #1095 | PR #1501
cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == */lancache-ng-sha-retention-audit.* ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

packages_file="$work_dir/packages.tsv"
# What: Filtered mode includes legacy packages for per-package GC
# Why: Audit scope remains first-party; GC can retire legacy
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

# What: Fingerprints run's managed-history ref set for cache
# Why: Gates cache reads in audit_package per SRA_CACHE_DB
# From: Issue #1095
if history_fingerprint="$(sra_history_refs_fingerprint "$repo_root" "${history_refs[@]}")"; then
  :
else
  echo "::error::Cannot compute a history-refs fingerprint for the managed ref set." >&2
  exit 1
fi

# What: Audits single package: fetches, classifies, prints AUDIT
# Why: Single per-package entry point; sets up credentials
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

  # What: Loads package's cached v1.2 resolutions (or miss)
  # Why: Cache miss falls back to full classification path
  # From: Issue #1585
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

  # What: Exports normalized inventory for filtered audit snapshot
  # Why: Collector reuses snapshot to avoid re-listing versions
  # From: Issue #1585 | PR #1586
  if [[ -n "$version_snapshot_file" ]]; then
    if cp -- "$versions_file" "$version_snapshot_file"; then
      :
    else
      echo "::error::Cannot export the filtered package-version snapshot for ${repository_name}/${package}." >&2
      return 1
    fi
  fi

  # What: Computes stable-release tag set once via one jq pass
  # Why: Per-version jq calls caused timeout; single pass avoids
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

  # What: builds root manifests' child-digest reference set
  # Why: old 'separate pass' only ever covers PR-staging
  # From: Issue #1095
  declare -A closure_referenced_children=()
  local closure_check_ok=1
  local closure_registry_token=""
  if closure_registry_token="$(ghcr_retry ghcr.io "" "" -- gcps_registry_anon_token "$package" "$GITHUB_REPOSITORY")" && [[ -n "$closure_registry_token" ]]; then
    local root_digest root_manifest root_children_output root_child
    while IFS= read -r root_digest; do
      [[ -n "$root_digest" ]] || continue
      if ! root_manifest="$(ghcr_retry ghcr.io "" "" -- gcps_fetch_manifest "$package" "$root_digest" "$GITHUB_REPOSITORY" "$closure_registry_token")" \
          || [[ -z "$root_manifest" ]] || ! gcps_manifest_looks_valid "$root_manifest"; then
        echo "::warning::Cannot fetch/validate root manifest $root_digest for ${repository_name}/${package}; disabling the non-ordinary-version closure check for this package (falls back to unconditional protect)." >&2
        closure_check_ok=0
        break
      fi
      if ! root_children_output="$(gcps_extract_manifest_children "$root_manifest")"; then
        echo "::warning::Cannot extract manifest children for root $root_digest in ${repository_name}/${package}; disabling the non-ordinary-version closure check for this package." >&2
        closure_check_ok=0
        break
      fi
      while IFS= read -r root_child; do
        [[ -n "$root_child" ]] || continue
        closure_referenced_children["$root_child"]=1
      done <<<"$root_children_output"
    done < <(jq -r 'select((.metadata.container.tags // []) | any(test("^sha-[0-9a-f]{7,40}$"))) | .name' "$versions_file")
  else
    echo "::warning::Cannot obtain an anonymous pull token for ${repository_name}/${package}; disabling the non-ordinary-version closure check for this package." >&2
    closure_check_ok=0
  fi

  local root_candidates="$package_dir/root-candidates.tsv"
  : >"$root_candidates"
  # What: V1.2 buffer pool ranks rootless non-channel versions
  # Why: Replaces permanent protection with newest-first buffer
  # From: Issue #1585
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
    # What: Extracts id/digest/tags/created_at in one jq call
    # Why: One call avoids per-version subprocess cost
    # From: Issue #1095 | PR #1501
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

    # What: Reports missing build date as separate warning
    # Why: Flags data-quality defects in image pipeline
    # From: Issue #1095 | PR #1501
    if sra_validate_created_at_string "$created_at_raw"; then
      built="$created_at_raw"
    else
      built="unknown"
      (( missing_build_date_count += 1 ))
      echo "::warning::Package version $id (digest $digest) in ${repository_name}/${package} has no usable GHCR build date; this is a build-pipeline defect, not audit absence." >&2
    fi

    # What: Checks rollback-anchor membership first
    # Why: Explicit anchor overrides tag/class/history budget
    # From: Issue #1095 | PR #1586
    if sra_digest_is_rollback_anchor "$digest" "${!retention_rollback_anchor_digests[@]}"; then
      printf '%s\n' "$digest" >>"$anchor_result_file"
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "explicit-rollback-anchor"
      continue
    fi
    # What: Reuses check against live Dockerfile FROM digests
    # Why: Extends protection to build dependencies
    # From: Issue #1613
    if sra_digest_is_rollback_anchor "$digest" "${!live_dockerfile_from_digests[@]}"; then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "live-dockerfile-from-reference"
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
      # What: ages a merge-orphaned child past safety margin
      # Why: a real merge job cannot run this long anymore
      # From: Issue #1095
      local closure_epoch=""
      if [[ "$built" != "unknown" ]]; then
        closure_epoch="$(gcps_created_at_to_epoch "$built")" || closure_epoch=""
      fi
      if [[ -n "$closure_epoch" ]] && gcps_is_old_enough_to_delete "$closure_epoch" "$now_epoch" "$orphan_closure_min_age_seconds"; then
        sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "closure" "would-delete" "artifact-child-closure-orphaned-past-safety-margin"
        direct_would_delete_count=$((direct_would_delete_count + 1))
      else
        sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "closure" "protect" "artifact-child-closure-unresolved"
      fi
      continue
    fi
    # What: checks untagged version against root children
    # Why: referenced or unverifiable -- stays protected
    # From: Issue #1585 | Issue #1095
    if (( root_count == 0 && other_count == 0 )); then
      if (( closure_check_ok == 1 )) && [[ -z "${closure_referenced_children[$digest]+x}" ]]; then
        local nonord_epoch=""
        if [[ "$built" != "unknown" ]]; then
          nonord_epoch="$(gcps_created_at_to_epoch "$built")" || nonord_epoch=""
        fi
        if [[ -n "$nonord_epoch" ]] && gcps_is_old_enough_to_delete "$nonord_epoch" "$now_epoch" "$orphan_closure_min_age_seconds"; then
          sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "would-delete" "non-ordinary-version-unreferenced-past-safety-margin"
          direct_would_delete_count=$((direct_would_delete_count + 1))
          continue
        fi
      fi
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
        # What: Buffers candidate for build-date-ranked pass below
        # Why: Unknown date sorts first, treated conservatively
        # From: Issue #1585
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
    # What: Classifies root tag's extra tags into protect reason
    # Why: Retags reuse existing digest; only channel matches protect
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

    # What: Reuses cached git-history resolution from cache_hits
    # Why: Avoids per-root-tag rev-parse/merge-base computation
    # From: Issue #1585
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
          # What: Falls through on malformed cache value
          # Why: Fail-safe: corrupt cache never skips classification
          # From: Issue #1585
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

  # What: Persists resolutions to v1.2 cache database
  # Why: No-op when cache_db unset; soft warning on failure
  # From: Issue #1585
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
    # What: Marks roots outside retention budget deletable
    # Why: GC consumes identities after revalidation gates
    # From: Issue #1095
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

  # What: Ranks v1.2 rootless versions by build date newest
  # Why: Replaces permanent protect with bounded buffer pattern
  # From: Issue #1585
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

# What: Audits packages in bounded batches, merges workers
# Why: Per-worker files preserve output and state across shell
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

# What: Fails closed on unobserved declared rollback anchors
# Why: Detects typos and deleted digests in anchor list
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
