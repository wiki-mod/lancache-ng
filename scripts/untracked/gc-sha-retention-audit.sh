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
# Why: how many of a package's own newest vX.Y.Z tags still count as a
# "supported stable release" for protected-reference classification (see
# audit_package's supported_releases computation below). From: Issue #1095 | PR #1501.
if minimum_stable_releases="$(sra_read_minimum_stable_releases "$manifest")"; then
  :
else
  echo "::error::Cannot read exactly one valid minimum_stable_releases value from $manifest." >&2
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

  # Why: computed once per package via a single jq pass over the whole
  # already-fetched versions file (not one jq call per version -- see this
  # file's own header comment on the timeout a per-version jq call already
  # caused once, run 31774741729) so the per-version classification loop
  # below can look up whether a given vX.Y.Z tag is still one of this
  # package's `minimum_stable_releases` newest stable releases. From: Issue
  # #1095 | PR #1501.
  local release_tags_file="$package_dir/release-tags.txt"
  if jq -r '.metadata.container.tags[]? // empty' "$versions_file" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u >"$release_tags_file"; then
    :
  else
    # Why: grep exits 1 under `set -o pipefail` when a brand-new package has
    # no stable-release tags at all yet -- that is a legitimate empty
    # result, not a real failure, and must not abort the audit. Proven live:
    # `set -euo pipefail; jq ... | grep -E ... | sort -u >file` exits 1 on a
    # zero-match grep even though `sort` itself succeeds (AG-VAL-030).
    : >"$release_tags_file"
  fi
  local supported_releases
  supported_releases="$(sra_select_supported_release_tags "$minimum_stable_releases" <"$release_tags_file")" || {
    echo "::error::Cannot select supported stable-release tags for ${repository_name}/${package}." >&2
    return 1
  }

  local root_candidates="$package_dir/root-candidates.tsv"
  : >"$root_candidates"
  local version_json id digest tags built facts root_count child_count other_count
  local encoded_tags encoded_tag tag kind prefix full_commit rank min_rank
  local root_resolution_failed reason other_tags
  local missing_build_date_count=0
  declare -A seen_id_digest=()
  declare -A seen_digest_id=()

  local version_fields created_at_raw
  while IFS= read -r version_json; do
    [[ -n "$version_json" ]] || continue
    # Why: id/digest/tags/created_at come from one combined jq call instead
    # of four separate ones -- a real live audit run against the full GHCR
    # inventory (thousands of versions per package) timed out at exactly the
    # 25-minute budget (run 31774741729) once this pass added a per-version
    # created_at lookup on top of the pre-existing per-version jq calls;
    # spawning one fewer jq subprocess per version is a real, measurable fix
    # for that, not a timeout bump. "|" is used instead of jq's built-in
    # @tsv/actual tab: bash's `read` treats a literal tab as IFS "whitespace"
    # regardless of what IFS is set to, silently collapsing/losing an empty
    # middle field (a real, verified-live bug an untagged version's empty
    # tags field would have hit here) -- "|" is not IFS whitespace, so an
    # empty field between two delimiters is preserved correctly. None of
    # id/digest/tags/created_at can legitimately contain "|".
    if version_fields="$(jq -r '[.id, .name, (.metadata.container.tags | join(",")), (.created_at // "")] | join("|")' <<<"$version_json")"; then
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

    # Why: a missing/malformed build date is a real data-quality defect in
    # the image-publish pipeline (e.g. a dropped OCI created label), not an
    # absence to fold silently into an unrelated classification -- it is
    # named here as its own finding rather than left out of the report.
    if sra_validate_created_at_string "$created_at_raw"; then
      built="$created_at_raw"
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
      # Why: a version with no sha-<commit> alias at all has no git-history
      # root to rank by, so it always stays protect regardless of its extra
      # tags -- but classify it by the specific channel/release its attached
      # tag identifies whenever possible, instead of the generic
      # non-ordinary-version bucket. The other_count>0 guard skips the
      # (bash-only, but still non-free) other-tag scan entirely for a
      # completely untagged version -- e.g. an attestation/referrer manifest,
      # the common case among the tens of thousands of versions a live audit
      # classifies -- since sra_extra_tag_protect_reason could only ever
      # return the fallback there anyway. From: Issue #1095 | PR #1501.
      if (( other_count > 0 )); then
        reason="$(sra_extra_tag_protect_reason "$tags" "$supported_releases" "non-ordinary-version")" || {
          echo "::error::Cannot classify non-root tags for package version $id in ${repository_name}/${package}." >&2
          return 1
        }
      else
        reason="non-ordinary-version"
      fi
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "$reason"
      continue
    fi
    if (( child_count > 0 )); then
      sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "mixed-root-and-child-tags"
      continue
    fi
    if (( other_count > 0 )); then
      # Why: this is the common real case -- a sha-<commit> root tag
      # additionally carrying nightly/latest/a release tag, since the
      # promote job retags rather than rebuilds (build-push.yml's `docker
      # buildx imagetools create --prefer-index=false`), so a currently
      # active channel/release always lands on the same digest/version
      # object as its originating sha-<commit> tag. Unlike the root_count==0
      # branch above, this version DOES have a resolvable sha-<commit> root
      # -- per the maintainer's protected-reference scope clarification
      # (Issue #1095 | PR #1501), "protected" means the digest is actually still
      # referenced by nightly/latest/a supported release right now, not
      # merely "carries some extra tag" -- so an unrecognized extra tag (an
      # rc/staging tag, or a release tag past minimum_stable_releases) must
      # NOT unconditionally protect this version anymore; it falls through
      # into the same ordinary root-candidate ranking every plain root goes
      # through below.
      other_tags="$(sra_other_tags_from_csv "$tags")" || {
        echo "::error::Cannot classify non-root tags for package version $id in ${repository_name}/${package}." >&2
        return 1
      }
      if reason="$(sra_protected_reference_reason "$other_tags" "$supported_releases")"; then
        sra_emit_record "$class" "$package" "$id" "$digest" "$tags" "$built" "n/a" "protected" "protect" "$reason"
        continue
      fi
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
    # "acceptance-evidence-unavailable" stays correct for every row reached
    # here: a version whose digest is actually still referenced by nightly/
    # latest/a supported release was already classified above with its own
    # specific nightly-channel-protected/latest-channel-protected/
    # stable-release-protected reason and never reaches this loop; only a
    # plain root (no extra tag) or a root carrying an unrecognized extra tag
    # (an rc/staging tag, or a release tag past minimum_stable_releases)
    # falls through into ordinary ranking here (see audit_package's
    # other_count>0 branch). From: Issue #1095 | PR #1501.
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
