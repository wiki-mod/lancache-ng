#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Read-only GHCR retention audit. It inventories first-party package versions,
# validates every version/tag shape, ranks legacy ordinary roots from Git
# history, and reports protection reasons. Ordinary roots beyond the accepted
# budget are labeled would-delete with their real build date as a dry-run
# report only; this script never issues a package-version DELETE call.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=scripts/lib/github-api-retry.sh
source "$repo_root/scripts/lib/github-api-retry.sh"
# shellcheck source=scripts/lib/sha-retention-audit.sh
source "$repo_root/scripts/lib/sha-retention-audit.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

manifest="${SRA_MANIFEST:-$repo_root/release/stack-images.yml}"
history_ref="${SRA_HISTORY_REF:-origin/current_dev}"
max_pages_per_package="${SRA_MAX_PAGES_PER_PACKAGE:-500}"
per_page=100

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

for required_command in awk curl git jq mktemp sort uniq; do
  command -v "$required_command" >/dev/null 2>&1 || {
    echo "::error::Required command is unavailable: $required_command" >&2
    exit 1
  }
done

[[ -f "$manifest" ]] || {
  echo "::error::Retention manifest is missing: $manifest" >&2
  exit 1
}
git -C "$repo_root" rev-parse --verify --quiet "${history_ref}^{commit}" >/dev/null || {
  echo "::error::History ref is unavailable in the full checkout: $history_ref" >&2
  exit 1
}

if retention_keep="$(sra_read_retention_keep "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid accepted_ordinary_roots_per_package value from $manifest." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/lancache-ng-sha-retention-audit.XXXXXX")"
cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == */lancache-ng-sha-retention-audit.* ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

packages_file="$work_dir/packages.tsv"
if sra_manifest_packages "$manifest" >"$packages_file"; then
  :
else
  echo "::error::Cannot derive first-party package inventory from $manifest." >&2
  exit 1
fi
[[ -s "$packages_file" ]] || {
  echo "::error::First-party package inventory is empty." >&2
  exit 1
}

duplicate_packages="$(sort "$packages_file" | uniq -d)"
[[ -z "$duplicate_packages" ]] || {
  echo "::error::Duplicate first-party package inventory entries were found: $duplicate_packages" >&2
  exit 1
}
for required_class in runtime tooling metadata; do
  if awk -F '\t' -v wanted="$required_class" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }' "$packages_file"; then
    :
  else
    echo "::error::Manifest inventory has no $required_class package." >&2
    exit 1
  fi
done

history_file="$work_dir/history.txt"
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

declare -A history_rank=()
history_position=0
while IFS= read -r history_commit; do
  [[ "$history_commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "::error::Unexpected commit value in $history_ref history: $history_commit" >&2
    exit 1
  }
  (( history_position += 1 ))
  history_rank["$history_commit"]="$history_position"
done <"$history_file"

audit_package() {
  local class="${1:?audit_package: class is required}"
  local package="${2:?audit_package: package is required}"
  local package_dir="$work_dir/${class}-${package}"
  local versions_file="$package_dir/versions.jsonl"
  local body_file="$package_dir/page.json"
  local page count url package_path

  mkdir -p "$package_dir"
  : >"$versions_file"
  package_path="${repository_name}%2F${package}"

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

  local root_candidates="$package_dir/root-candidates.tsv"
  : >"$root_candidates"
  local version_json id digest tags built facts root_count child_count other_count
  local encoded_tags encoded_tag tag kind prefix full_commit rank min_rank
  local root_resolution_failed
  local missing_build_date_count=0
  declare -A seen_id_digest=()
  declare -A seen_digest_id=()

  while IFS= read -r version_json; do
    [[ -n "$version_json" ]] || continue
    id="$(jq -r '.id' <<<"$version_json")"
    digest="$(jq -r '.name' <<<"$version_json")"
    tags="$(jq -r '.metadata.container.tags | join(",")' <<<"$version_json")"

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

    # Why: a missing/malformed build date is a real data-quality defect in
    # the image-publish pipeline (e.g. a dropped OCI created label), not an
    # absence to fold silently into an unrelated classification -- it is
    # named here as its own finding rather than left out of the report.
    if built="$(sra_version_created_at "$version_json")"; then
      :
    else
      built="unknown"
      (( missing_build_date_count += 1 ))
      echo "::warning::Package version $id (digest $digest) in ${repository_name}/${package} has no usable GHCR build date; this is a build-pipeline defect, not audit absence." >&2
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

    if [[ "$class" == "metadata" ]]; then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "metadata-stack-identity"
      continue
    fi
    if (( root_count == 0 && child_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "closure" "protect" "artifact-child-closure-unresolved"
      continue
    fi
    if (( root_count == 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "non-ordinary-version"
      continue
    fi
    if (( child_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "mixed-root-and-child-tags"
      continue
    fi
    if (( other_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "non-sha-tag-attached"
      continue
    fi

    if encoded_tags="$(jq -r '.metadata.container.tags[] | @base64' <<<"$version_json")"; then
      :
    else
      echo "::error::Cannot enumerate root tags for package version $id in ${repository_name}/${package}." >&2
      return 1
    fi
    min_rank=0
    root_resolution_failed=false
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
      if sra_commit_is_on_history_ref "$repo_root" "$full_commit" "$history_ref"; then
        :
      else
        root_resolution_failed=true
        break
      fi
      rank="${history_rank[$full_commit]:-}"
      if [[ -z "$rank" ]]; then
        root_resolution_failed=true
        break
      fi
      if (( min_rank == 0 || rank < min_rank )); then
        min_rank="$rank"
      fi
    done <<<"$encoded_tags"

    if [[ "$root_resolution_failed" == "true" || "$min_rank" == "0" ]]; then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "unknown" "protected" "protect" "sha-resolution-or-history-unknown"
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$min_rank" "$id" "$digest" "$tags" "$built" >>"$root_candidates"
  done <"$versions_file"

  local sorted_candidates="$package_dir/root-candidates.sorted.tsv"
  if sort -n -k1,1 "$root_candidates" >"$sorted_candidates"; then
    :
  else
    echo "::error::Cannot sort legacy ordinary root identities for ${repository_name}/${package}." >&2
    return 1
  fi

  local legacy_position=0 budget decision would_delete_count=0
  while IFS=$'\t' read -r rank id digest tags built; do
    [[ -n "$id" ]] || continue
    (( legacy_position += 1 ))
    # Why: beyond-budget ordinary roots are reported as dry-run "would
    # delete" candidates (never actually deleted -- see the no-DELETE-path
    # Bats guard) so a maintainer reading the report sees exactly which
    # builds are past the accepted-roots budget, not just a protect count.
    if (( legacy_position <= retention_keep )); then
      budget="within-${retention_keep}"
      decision="protect"
    else
      budget="beyond-${retention_keep}"
      decision="would-delete"
      (( would_delete_count += 1 ))
    fi
    sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "$legacy_position" "$budget" "$decision" "acceptance-evidence-unavailable"
  done <"$sorted_candidates"

  printf 'SUMMARY\tclass=%s\tpackage=%s\tlegacy_roots=%s\tretention_keep=%s\twould_delete_count=%s\tmissing_build_date_count=%s\tdecision=protect-only\n' \
    "$class" "$package" "$legacy_position" "$retention_keep" "$would_delete_count" "$missing_build_date_count"
  if (( would_delete_count > 0 )); then
    echo "::notice::${repository_name}/${package}: $would_delete_count ordinary root(s) past the accepted-roots budget of $retention_keep in this dry-run report; no deletion was performed." >&2
  fi
}

overall_status=0
while IFS=$'\t' read -r package_class package_name; do
  [[ -n "$package_class" && -n "$package_name" ]] || {
    echo "::error::Malformed first-party package inventory entry." >&2
    overall_status=1
    continue
  }
  echo "::notice::Auditing read-only GHCR retention state for $package_class package ${repository_name}/${package_name}." >&2
  if audit_package "$package_class" "$package_name"; then
    :
  else
    overall_status=1
  fi
done <"$packages_file"

if (( overall_status != 0 )); then
  echo "::error::SHA retention audit was incomplete or encountered invalid required data. No destructive conclusion is permitted." >&2
  exit 1
fi

echo "::notice::SHA retention audit completed in protect-only mode. Beyond-budget candidates are labeled would-delete for this dry-run report only; nothing was deleted. Legacy budget position is informational because canonical acceptance evidence is not yet available to this audit." >&2
