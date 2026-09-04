#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: pure helpers for the read-only SHA retention audit.
# Why: Never mutates; kept pure for direct unit testing always.
# From: Issue #1095 | PR #1586

if [[ -n "${SHA_RETENTION_AUDIT_LIB_LOADED:-}" ]]; then
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 0
  fi
  return 0
fi
SHA_RETENTION_AUDIT_LIB_LOADED=1

# What: reads one "  <key>: <int>" line from manifest.
# Why: Shared parsing rule avoids duplication (AG-CODE-011).
# From: Issue #1095 | PR #1586
_sra_read_manifest_positive_integer() {
  local manifest="${1:?_sra_read_manifest_positive_integer: manifest is required}"
  local key="${2:?_sra_read_manifest_positive_integer: key is required}"
  local matches value

  if matches="$(awk -v k="  ${key}: " 'index($0, k) == 1 { print }' "$manifest")"; then
    :
  else
    return 1
  fi
  [[ -n "$matches" ]] || return 1
  [[ "$(wc -l <<<"$matches" | tr -d '[:space:]')" == "1" ]] || return 1

  value="${matches#"  ${key}: "}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$value"
}

# What: reads retention.accepted_ordinary_roots_per_package.
# Why: Per-package budget for ordinary sha roots before deletion.
# From: Issue #1095 | PR #1586
sra_read_retention_keep() {
  local manifest="${1:?sra_read_retention_keep: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "accepted_ordinary_roots_per_package"
}

# What: reads retention.minimum_stable_releases from the manifest.
# Why: Minimum stable releases must remain protected indefinitely.
# From: Issue #1095 | PR #1586
sra_read_minimum_stable_releases() {
  local manifest="${1:?sra_read_minimum_stable_releases: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "minimum_stable_releases"
}

# What: reads retention.channel_buffer_versions from the manifest.
# Why: Fallback safety buffer when tags match no protected channel.
# From: Issue #1585
sra_read_channel_buffer_versions() {
  local manifest="${1:?sra_read_channel_buffer_versions: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "channel_buffer_versions"
}

# What: reads a `<key>:` block-list, one item per line.
# Why: Shared rule for list parsing; future keys will reuse it.
# From: Issue #1095 | PR #1586
_sra_read_manifest_list() {
  local manifest="${1:?_sra_read_manifest_list: manifest is required}"
  local key="${2:?_sra_read_manifest_list: key is required}"
  local allow_empty="${3:-false}"
  local header="  ${key}:"
  local header_count items

  if header_count="$(awk -v header="$header" '$0 == header { n++ } END { print n + 0 }' "$manifest")"; then
    :
  else
    return 1
  fi
  if [[ "$header_count" == "0" ]]; then
    [[ "$allow_empty" == "true" ]] || return 1
    return 0
  fi
  [[ "$header_count" == "1" ]] || return 1

  if items="$(awk -v header="$header" '
    $0 == header { in_list = 1; next }
    in_list && /^    - / { line = $0; sub(/^    - /, "", line); print line; next }
    in_list { in_list = 0 }
  ' "$manifest")"; then
    :
  else
    return 1
  fi
  if [[ -z "$items" ]]; then
    [[ "$allow_empty" == "true" ]] || return 1
    return 0
  fi
  printf '%s\n' "$items"
}

# What: reads retention.rollback_anchors, one digest per line.
# Why: Steady state empty; entries added only after regressions.
# From: Issue #1095 | PR #1586
sra_read_rollback_anchors() {
  local manifest="${1:?sra_read_rollback_anchors: manifest is required}"
  _sra_read_manifest_list "$manifest" rollback_anchors true
}

# What: checks for sha256:<64-hex> digest shape exactly.
# Why: Digests prevent anchor staleness from tag moves or deletes.
# From: Issue #1095 | PR #1586
sra_is_rollback_anchor_digest() {
  local value="${1:?sra_is_rollback_anchor_digest: value is required}"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# What: exact-match digest membership in anchor set.
# Why: Exact match only, consistent with other tag/digest checks.
# From: Issue #1095 | PR #1586
sra_digest_is_rollback_anchor() {
  local digest="${1:?sra_digest_is_rollback_anchor: digest is required}"
  shift
  local anchor
  for anchor in "$@"; do
    [[ "$digest" == "$anchor" ]] && return 0
  done
  return 1
}

# What: validates rollback_anchors list, entry by entry.
# Why: Pure function; CI and runtime share one validation rule.
# From: Issue #1095 | PR #1586
sra_validate_rollback_anchors_list() {
  local anchors_raw="${1:-}" entry
  [[ -z "$anchors_raw" ]] && return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || {
      printf 'must not contain a blank entry\n'
      return 1
    }
    if sra_is_rollback_anchor_digest "$entry"; then
      :
    else
      printf 'entry is not an exact sha256:<64-hex> digest: %s\n' "$entry"
      return 1
    fi
  done <<<"$anchors_raw"
}

# What: lists packages by class/name from manifest sections.
# Why: Audit and GC share one parser; default remains separate.
# From: Issue #1095
sra_manifest_packages() {
  local manifest="${1:?sra_manifest_packages: manifest is required}"
  local sections="${2:-runtime tooling metadata}"

  awk -v wanted="$sections" '
    BEGIN {
      count=split(wanted, requested, " ")
      for (i=1; i<=count; i++) allowed[requested[i]]=1
    }
    /^[[:alnum:]_-]+:$/ {
      candidate=$0
      sub(/:$/, "", candidate)
      section=(candidate in allowed) ? candidate : ""
      next
    }
    section != "" && /^  - name: / {
      name=$0
      sub(/^  - name: /, "", name)
      print section "\t" name
    }
  ' "$manifest"
}

# What: validates GHCR versions page against shape needs.
# Why: Prevents misclassification of malformed page data as result.
# From: Issue #1095 | PR #1586
sra_validate_version_page() {
  local page_file="${1:?sra_validate_version_page: page file is required}"
  command -v jq >/dev/null 2>&1 || return 1

  jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.id | type == "number") and
      (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.metadata | type == "object") and
      (.metadata.container | type == "object") and
      (.metadata.container.tags | type == "array") and
      all(.metadata.container.tags[];
        type == "string" and
        length > 0 and
        (explode | all(.[]; . >= 32 and . != 127))
      )
    )
  ' "$page_file" >/dev/null
}

# What: classifies tag as root, per-platform child, other.
# Why: Centralized classification drives all downstream decisions.
# From: Issue #1095 | PR #1586
sra_tag_kind() {
  local tag="${1:?sra_tag_kind: tag is required}"
  if [[ "$tag" =~ ^sha-([0-9a-f]{7,40})$ ]]; then
    printf 'root\t%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$tag" =~ ^sha-([0-9a-f]{7,40})-(amd64|arm64)$ ]]; then
    printf 'child\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf 'other\t%s\n' "$tag"
  fi
}

# What: resolves hex commit prefix to 40-char commit.
# Why: Unresolvable prefix fails closed to prevent false ranking.
# From: Issue #1095 | PR #1586
sra_resolve_commit_prefix() {
  local git_dir="${1:?sra_resolve_commit_prefix: git directory is required}"
  local prefix="${2:?sra_resolve_commit_prefix: prefix is required}"
  local resolved

  [[ "$prefix" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  if resolved="$(git -C "$git_dir" rev-parse --verify --quiet "${prefix}^{commit}")"; then
    :
  else
    return 1
  fi
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$resolved"
}

# What: checks if commit is ancestor of history_ref.
# Why: Commits outside audited history can't rank; protect always.
# From: Issue #1095 | PR #1501
sra_commit_is_on_history_ref() {
  local git_dir="${1:?sra_commit_is_on_history_ref: git directory is required}"
  local commit="${2:?sra_commit_is_on_history_ref: commit is required}"
  local history_ref="${3:?sra_commit_is_on_history_ref: history ref is required}"
  git -C "$git_dir" merge-base --is-ancestor "$commit" "$history_ref"
}

# What: validates GHCR created_at format (YYYY-MM-DDTHH:MM:SSZ).
# Why: Hot loop validates; avoids second per-version jq call.
# From: Issue #1095 | PR #1586
sra_validate_created_at_string() {
  local created_at="${1?sra_validate_created_at_string: value argument is required}"
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# What: extracts GHCR build timestamp for one package version.
# Why: Display-only; ranking is purely git-history-derived always.
# From: Issue #1095 | PR #1586
sra_version_created_at() {
  local version_json="${1:?sra_version_created_at: version JSON is required}"
  local created_at

  command -v jq >/dev/null 2>&1 || return 1
  if created_at="$(jq -r '.created_at // empty' <<<"$version_json")"; then
    :
  else
    return 1
  fi
  sra_validate_created_at_string "$created_at" || return 1
  printf '%s\n' "$created_at"
}

# What: formats AUDIT report line for classified version.
# Why: Pure formatter; unit-testable; correctly handles empty tags.
# From: Issue #1095 | PR #1586
sra_emit_record() {
  local class="${1:?sra_emit_record: class is required}"
  local package="${2:?sra_emit_record: package is required}"
  local id="${3:?sra_emit_record: id is required}"
  local digest="${4:?sra_emit_record: digest is required}"
  local tags="${5?sra_emit_record: tags argument is required}"
  local built="${6:?sra_emit_record: built is required}"
  local legacy_rank="${7:?sra_emit_record: legacy_rank is required}"
  local budget="${8:?sra_emit_record: budget is required}"
  local decision="${9:?sra_emit_record: decision is required}"
  local reason="${10:?sra_emit_record: reason is required}"
  printf 'AUDIT\tclass=%s\tpackage=%s\tid=%s\tdigest=%s\ttags=%s\tbuilt=%s\tlegacy_rank=%s\tbudget=%s\tacceptance=not-required-for-storage-retention\tdecision=%s\treason=%s\n' \
    "$class" "$package" "$id" "$digest" "$tags" "$built" "$legacy_rank" "$budget" "$decision" "$reason"
}

# What: counts a version's tags by sra_tag_kind (root/child/other).
# Why: Compute once; keeps branching logic simple in orchestrator.
# From: Issue #1095 | PR #1501
sra_version_tag_facts() {
  local version_json="${1:?sra_version_tag_facts: version JSON is required}"
  local encoded_tags encoded_tag tag kind root_count=0 child_count=0 other_count=0

  command -v jq >/dev/null 2>&1 || return 1
  jq -e '
    type == "object" and
    (.metadata.container.tags | type == "array") and
    all(.metadata.container.tags[];
      type == "string" and
      length > 0 and
      (explode | all(.[]; . >= 32 and . != 127))
    )
  ' <<<"$version_json" >/dev/null || return 1

  if encoded_tags="$(jq -r '.metadata.container.tags[] | @base64' <<<"$version_json")"; then
    :
  else
    return 1
  fi

  while IFS= read -r encoded_tag; do
    [[ -n "$encoded_tag" ]] || continue
    if tag="$(jq -Rr '@base64d' <<<"$encoded_tag")"; then
      :
    else
      return 1
    fi
    kind="$(sra_tag_kind "$tag")" || return 1
    case "$kind" in
      root$'\t'*) (( root_count += 1 )) ;;
      child$'\t'*) (( child_count += 1 )) ;;
      other$'\t'*) (( other_count += 1 )) ;;
      *) return 1 ;;
    esac
  done <<<"$encoded_tags"

  printf '%s\t%s\t%s\n' "$root_count" "$child_count" "$other_count"
}

# What: checks tag for stable-release shape vX.Y.Z (no suffix).
# Why: Distinguishes stable from RC tags; counts toward minimum.
# From: Issue #1095 | PR #1586
sra_is_stable_release_tag() {
  local tag="${1:?sra_is_stable_release_tag: tag is required}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# What: converts vX.Y.Z tag to zero-padded sortable key.
# Why: Zero-padding lets plain sort order releases newest-first.
# From: Issue #1095 | PR #1586
sra_release_sort_key() {
  local tag="${1:?sra_release_sort_key: tag is required}"
  local major minor patch
  sra_is_stable_release_tag "$tag" || return 1
  IFS='.' read -r major minor patch <<<"${tag#v}"
  printf '%020d.%020d.%020d\n' "$major" "$minor" "$patch"
}

# What: prints newest `count` stable-release tags.
# Why: Avoids SIGPIPE misreport under set -o pipefail with sort.
# From: Issue #1095 | PR #1586
sra_select_supported_release_tags() {
  local count="${1:?sra_select_supported_release_tags: count is required}"
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1

  local tag key
  local -a keyed=()
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    key="$(sra_release_sort_key "$tag")" || return 1
    keyed+=("${key}|${tag}")
  done

  (( ${#keyed[@]} > 0 )) || return 0
  local sorted selected
  sorted="$(printf '%s\n' "${keyed[@]}" | sort -r)"
  selected="$(head -n "$count" <<<"$sorted")"
  cut -d'|' -f2- <<<"$selected"
}

# What: classifies "other"-kind tag to its protected channel.
# Why: Separates channels so caller reports specific, not generic.
# From: Issue #1095 | PR #1586
sra_classify_channel_tag() {
  local tag="${1:?sra_classify_channel_tag: tag is required}"
  case "$tag" in
    nightly) printf 'nightly\n' ;;
    latest) printf 'latest\n' ;;
    *)
      if sra_is_stable_release_tag "$tag"; then
        printf 'stable-release\n'
      else
        printf 'other\n'
      fi
      ;;
  esac
}

# What: extracts "other"-kind tags from comma-joined list.
# Why: Bash split avoids jq/base64; comma safe in OCI tag grammar.
# From: Issue #1095 | PR #1586
sra_other_tags_from_csv() {
  local tags_csv="${1?sra_other_tags_from_csv: tags CSV argument is required}"
  local tag kind
  local -a tag_array=()

  IFS=',' read -r -a tag_array <<<"$tags_csv"
  for tag in "${tag_array[@]}"; do
    [[ -n "$tag" ]] || continue
    kind="$(sra_tag_kind "$tag")" || return 1
    [[ "$kind" == other$'\t'* ]] || continue
    printf '%s\n' "$tag"
  done
}

# What: returns reasons covering all matching protected channels.
# Why: Multiple channels can match; report all to preserve info.
# From: Issue #1095 | PR #1586
sra_protected_reference_reason() {
  local other_tags="${1?sra_protected_reference_reason: other tags argument is required}"
  local supported_releases="${2?sra_protected_reference_reason: supported releases argument is required}"
  local tag channel has_nightly=0 has_latest=0 has_stable=0

  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    channel="$(sra_classify_channel_tag "$tag")" || return 1
    case "$channel" in
      nightly) has_nightly=1 ;;
      latest) has_latest=1 ;;
      stable-release)
        if [[ -n "$supported_releases" ]] && grep -qxF "$tag" <<<"$supported_releases"; then
          has_stable=1
        fi
        ;;
    esac
  done <<<"$other_tags"

  local -a reasons=()
  (( has_nightly )) && reasons+=("nightly-channel-protected")
  (( has_latest )) && reasons+=("latest-channel-protected")
  (( has_stable )) && reasons+=("stable-release-protected")
  (( ${#reasons[@]} > 0 )) || return 1

  local joined
  joined="$(IFS='+'; printf '%s' "${reasons[*]}")"
  printf '%s\n' "$joined"
}

# What: classifies ranked candidate position against budget.
# Why: Shared by budget loops to avoid arithmetic code duplication.
# From: Issue #1585
sra_budget_decision() {
  local position="${1:?sra_budget_decision: position is required}"
  local budget="${2:?sra_budget_decision: budget is required}"
  [[ "$position" =~ ^[0-9]+$ ]] || return 1
  [[ "$budget" =~ ^[0-9]+$ ]] || return 1
  if (( position <= budget )); then
    printf 'protect\twithin-%s\n' "$budget"
  else
    printf 'would-delete\tbeyond-%s\n' "$budget"
  fi
}

# --- Incremental classification cache (v1.2 point 4) ---------
#
# What: SQLite cache of expensive per-version resolution results.
# Why: Resolution is cached, not decision; pool shifts rankings.
# From: Issue #1585

# What: the cache's schema, as a plain printable string.
# Why: Keeps schema unit-testable without live sqlite3 invocation.
# From: Issue #1585

# What: Identifies ref-set; primary key part prevents row eviction.
# Why: Separates caller rows; prevents INSERT OR REPLACE eviction.
# From: Issue #1095

# What: table: version_cache → version_cache_v2 for change.
# Why: Old schema incompatible; new name prevents write breakage.
# From: Issue #1095
sra_cache_schema_sql() {
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS version_cache_v2 (
  package TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  digest TEXT NOT NULL,
  tags TEXT NOT NULL,
  resolution TEXT NOT NULL,
  history_fingerprint TEXT NOT NULL,
  history_ref_names TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (package, version_id, history_fingerprint)
);
SQL
}

# What: builds "ref@resolved-commit;..." fingerprint for ref set.
# Why: Ref-set drift causes cache miss; stable order needed always.
# From: Issue #1095
sra_history_refs_fingerprint() {
  local repo_root="${1:?sra_history_refs_fingerprint: repo root is required}"
  shift
  local ref resolved fingerprint=""
  (( $# > 0 )) || return 1
  for ref in "$@"; do
    resolved="$(git -C "$repo_root" rev-parse --verify --quiet "${ref}^{commit}")" || return 1
    fingerprint+="${fingerprint:+;}${ref}@${resolved}"
  done
  printf '%s\n' "$fingerprint"
}

# What: creates the cache database (idempotent) at the given path.
# Why: Cache-miss runs must succeed; fallback init needed always.
# From: Issue #1585
sra_cache_init() {
  local db_path="${1:?sra_cache_init: db path is required}"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sra_cache_schema_sql | sqlite3 "$db_path"
}

# What: escapes value for single-quoted SQL literal inclusion.
# Why: Doubling quotes is SQL's escape for ad hoc statements.
# From: Issue #1585
sra_sql_quote() {
  local value="${1?sra_sql_quote: value argument is required}"
  printf '%s' "${value//\'/\'\'}"
}

# What: bulk-reads package's cached rows for history_fingerprint.
# Why: One call per package; server-side filter isolates rows.
# From: Issue #1585
sra_cache_read_package() {
  local db_path="${1:?sra_cache_read_package: db path is required}"
  local package="${2:?sra_cache_read_package: package is required}"
  local history_fingerprint="${3:?sra_cache_read_package: history fingerprint is required}"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db_path" ]] || return 1
  sqlite3 -separator "$(printf '\t')" "$db_path" \
    "SELECT version_id, digest, tags, resolution FROM version_cache_v2 WHERE package = '$(sra_sql_quote "$package")' AND history_fingerprint = '$(sra_sql_quote "$history_fingerprint")';"
}

# What: bulk-writes package's cache rows in single transaction.
# Why: One call per package; caller controls TSV file lifecycle.
# From: Issue #1585
sra_cache_write_package() {
  local db_path="${1:?sra_cache_write_package: db path is required}"
  local package="${2:?sra_cache_write_package: package is required}"
  local rows_file="${3:?sra_cache_write_package: rows file is required}"
  local history_fingerprint="${4:?sra_cache_write_package: history fingerprint is required}"
  local now version_id digest tags resolution sql_file history_ref_names fp_entry
  local -a fp_entries
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$rows_file" ]] || return 1

  history_ref_names=""
  IFS=';' read -ra fp_entries <<<"$history_fingerprint"
  for fp_entry in "${fp_entries[@]}"; do
    [[ -n "$fp_entry" ]] || continue
    history_ref_names+="${history_ref_names:+;}${fp_entry%%@*}"
  done

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sql_file="$(mktemp)"
  {
    printf 'BEGIN TRANSACTION;\n'
    while IFS=$'\t' read -r version_id digest tags resolution; do
      [[ "$version_id" =~ ^[0-9]+$ ]] || continue
      printf "INSERT OR REPLACE INTO version_cache_v2 (package, version_id, digest, tags, resolution, history_fingerprint, history_ref_names, updated_at) VALUES ('%s', %s, '%s', '%s', '%s', '%s', '%s', '%s');\n" \
        "$(sra_sql_quote "$package")" "$version_id" "$(sra_sql_quote "$digest")" "$(sra_sql_quote "$tags")" "$(sra_sql_quote "$resolution")" "$(sra_sql_quote "$history_fingerprint")" "$(sra_sql_quote "$history_ref_names")" "$now"
    done <"$rows_file"
    # What: prunes a superseded same-caller cache row.
    # Why: keeps old/new generations from colliding forever.
    # From: Issue #1095
    printf "DELETE FROM version_cache_v2 WHERE package = '%s' AND history_ref_names = '%s' AND history_fingerprint != '%s';\n" \
      "$(sra_sql_quote "$package")" "$(sra_sql_quote "$history_ref_names")" "$(sra_sql_quote "$history_fingerprint")"
    printf 'COMMIT;\n'
  } >"$sql_file"
  if sqlite3 "$db_path" <"$sql_file"; then
    rm -f -- "$sql_file"
  else
    rm -f -- "$sql_file"
    return 1
  fi
}


# What: extracts digests from Dockerfile's FROM lines.
# Why: Pure text parsing; unit-testable; covers grammar variants.
# From: Issue #1613
sra_dockerfile_from_digests() {
  local dockerfile_content="${1?sra_dockerfile_from_digests: dockerfile content argument is required}"
  local from_lines
  from_lines="$(grep -ioE '^[[:space:]]*from([[:space:]]+--[^[:space:]]+)*[[:space:]]+[^[:space:]]+@sha256:[0-9a-f]{64}' <<<"$dockerfile_content")" || true
  [[ -n "$from_lines" ]] || return 0
  grep -oiE 'sha256:[0-9a-f]{64}' <<<"$from_lines"
}
