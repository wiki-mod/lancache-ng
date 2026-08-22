#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: pure helpers for the read-only SHA retention audit.
# Why: never mutates GHCR; kept pure so every rule is directly unit-testable
# without a live audit run.
# From: Issue #1095 | PR #1586

if [[ -n "${SHA_RETENTION_AUDIT_LIB_LOADED:-}" ]]; then
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 0
  fi
  return 0
fi
SHA_RETENTION_AUDIT_LIB_LOADED=1

# What: reads one "  <key>: <positive-integer>" line from the manifest.
# Why: sra_read_retention_keep and sra_read_minimum_stable_releases share
# this exact parsing rule to avoid a driftable second copy (AG-CODE-011).
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

# What: reads retention.accepted_ordinary_roots_per_package from the manifest.
# Why: this count is the per-package budget of ordinary sha roots kept before
# an over-budget root becomes a would-delete/delete candidate.
# From: Issue #1095 | PR #1586
sra_read_retention_keep() {
  local manifest="${1:?sra_read_retention_keep: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "accepted_ordinary_roots_per_package"
}

# What: reads retention.minimum_stable_releases from the manifest.
# Why: sra_select_supported_release_tags needs this count to know how many
# recent vX.Y.Z tags stay protected (docs/release-versioning.md's Retention
# section).
# From: Issue #1095 | PR #1586
sra_read_minimum_stable_releases() {
  local manifest="${1:?sra_read_minimum_stable_releases: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "minimum_stable_releases"
}

# What: reads retention.channel_buffer_versions from the manifest.
# Why: v1.2 inverts protection for a non-ordinary-version
# fallback (unrecognized tag shape, no protected-channel match) -- this
# count is the per-package safety buffer kept regardless of age instead of
# a permanent protect.
# From: Issue #1585.
sra_read_channel_buffer_versions() {
  local manifest="${1:?sra_read_channel_buffer_versions: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "channel_buffer_versions"
}

# What: reads a `<key>:` block-list from the manifest, one item per line.
# Why: shared parsing rule for every retention list key (today only
# rollback_anchors), so a future second list key reuses it (AG-CODE-011).
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

# What: reads retention.rollback_anchors from the manifest, one digest per line.
# Why: the manifest's steady state is an empty list -- a maintainer only adds
# an entry after a real regression is found, so an absent list is not an error.
# From: Issue #1095 | PR #1586
sra_read_rollback_anchors() {
  local manifest="${1:?sra_read_rollback_anchors: manifest is required}"
  _sra_read_manifest_list "$manifest" rollback_anchors true
}

# What: checks whether a value has the exact sha256:<64-hex> digest shape.
# Why: a rollback anchor is deliberately digest-only, never a git tag/ref --
# a tag can be moved or deleted out from under an anchor unnoticed; a
# content-addressed digest cannot.
# From: Issue #1095 | PR #1586
sra_is_rollback_anchor_digest() {
  local value="${1:?sra_is_rollback_anchor_digest: value is required}"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]]
}

# What: exact-match membership check between a digest and a set of anchors.
# Why: never a substring/prefix match, the same conservative-match philosophy
# as this file's other tag/digest comparisons.
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

# What: validates an already-read rollback_anchors list, entry by entry.
# Why: a pure function (no manifest path, no exit calls) so the CI-time
# static check and the audit's own read-time re-validation share one rule.
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

# What: lists class/name packages from caller-selected manifest sections.
# Why: retention audit and destructive GC need one parser while the default
# remains the current runtime/tooling/metadata first-party inventory.
# From: Issue #1095.
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

# What: validates a fetched GHCR versions page against the shape classification needs.
# Why: refusing a malformed page here, before classification runs, avoids
# misclassifying partial or unexpected data as a real audit result.
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

# What: classifies one tag as a root, a per-platform child, or other shape.
# Why: root vs. child vs. other drives every downstream protect/would-delete
# decision, so this classification is centralized in one place.
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

# What: resolves a short/full hex commit prefix to a real 40-char commit.
# Why: an unresolvable prefix must fail closed, not be silently treated as
# an unknown/unranked commit that could then rank as newest.
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

# What: checks whether a resolved commit is an ancestor of history_ref.
# Why: a root tag pointing at a commit outside the audited history (e.g. a
# rebased-away or force-pushed commit) cannot be ranked and must not be
# treated as deletable.
# From: Issue #1095 | PR #1501.
sra_commit_is_on_history_ref() {
  local git_dir="${1:?sra_commit_is_on_history_ref: git directory is required}"
  local commit="${2:?sra_commit_is_on_history_ref: commit is required}"
  local history_ref="${3:?sra_commit_is_on_history_ref: history ref is required}"
  git -C "$git_dir" merge-base --is-ancestor "$commit" "$history_ref"
}

# What: checks a string against the GHCR created_at shape (YYYY-MM-DDTHH:MM:SSZ).
# Why: split from sra_version_created_at so the hot loop validates an
# already-extracted value instead of paying a second per-version jq call.
# From: Issue #1095 | PR #1586
sra_validate_created_at_string() {
  local created_at="${1?sra_validate_created_at_string: value argument is required}"
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# What: extracts the GHCR-reported build timestamp for one package version.
# Why: display-only -- ranking stays 100% git-history-derived; the
# orchestrator's hot loop calls sra_validate_created_at_string directly
# instead of this helper.
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

# What: formats one AUDIT report line for a classified package version.
# Why: a pure formatter, directly unit-testable without a live run; the tags
# arg uses "${5?}" (no colon) since a legitimately empty tag list must not be
# rejected the way a truly missing arg is.
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
# Why: the orchestrator's classification branches on these three counts
# together, so computing them once here keeps that branching logic simple.
# From: Issue #1095 | PR #1501.
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

# What: checks whether a tag has the stable-release shape vX.Y.Z (no suffix).
# Why: distinct from a release-candidate tag (vX.Y.Z-rc.N) -- only a genuine
# stable release counts toward minimum_stable_releases.
# From: Issue #1095 | PR #1586
sra_is_stable_release_tag() {
  local tag="${1:?sra_is_stable_release_tag: tag is required}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# What: converts a vX.Y.Z tag into a zero-padded, lexically-sortable key.
# Why: bash has no native semver comparator; zero-padding each component
# lets a plain `sort -r` order releases newest-first.
# From: Issue #1095 | PR #1586
sra_release_sort_key() {
  local tag="${1:?sra_release_sort_key: tag is required}"
  local major minor patch
  sra_is_stable_release_tag "$tag" || return 1
  IFS='.' read -r major minor patch <<<"${tag#v}"
  printf '%020d.%020d.%020d\n' "$major" "$minor" "$patch"
}

# What: prints the newest `count` stable-release tags read from stdin.
# Why: sort's output is captured into a variable before head/cut -- piping
# sort directly into an early-exiting consumer under `set -o pipefail` can
# misreport SIGPIPE as failure (AG-VAL-032).
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

# What: classifies one "other"-kind tag into the protected channel it identifies.
# Why: separates nightly/latest/stable-release from an unrecognized tag so
# the caller can report a specific protection reason, not a generic one.
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

# What: extracts every "other"-kind tag from an already comma-joined tag list.
# Why: pure-bash split avoids a second per-version jq/base64 round-trip; a
# literal comma split is safe since OCI's tag grammar forbids commas.
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

# What: returns a "+"-joined reason covering every protected channel that matches.
# Why: a digest can match several channels at once, so picking one would
# hide information; failure means none matched.
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

# What: classifies one already-ranked candidate's position against a budget.
# Why: shared by both the ordinary-sha-root retention-budget loop and the
# v1.2 non-ordinary-version buffer loop in the orchestrator,
# so the same within/beyond-budget arithmetic is not duplicated (AG-CODE-011).
# From: Issue #1585.
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
# What: a small SQLite cache of the expensive-to-recompute per-version
# resolution result (an ordinary sha-<commit> root's git-history rank, or a
# rootless version's channel-match outcome), keyed by (package, version_id)
# and fingerprinted by (digest, tags) so a changed version never reuses a
# stale result.
# Why: the final protect/would-delete decision always depends on a fresh,
# in-memory sort of the current candidate pool (ranks/positions shift as
# versions are added or removed), so nothing about the DELETE-relevant
# decision itself is ever read from cache -- only the deterministic,
# unchanged-if-digest/tags-unchanged *resolution* (git-history rank; or
# "no protected channel matched") is, which is what made the original
# 26,000-version run slow (one `git rev-parse`/`merge-base`
# subprocess pair per candidate root, every run, even for versions whose
# tags have not changed since the previous run).
# From: Issue #1585.

# What: the cache's schema, as a plain printable string.
# Why: keeps the schema itself directly unit-testable without a live
# sqlite3 invocation (its shape can be grepped/asserted on by bats).
# From: Issue #1585.
#
# What: history_fingerprint identifies the managed-ref-set a row was cached
# under and is part of the primary key, not just a stored column.
# Why: two different real callers classify against different ref sets and
# share this cache file; keying by fingerprint keeps each caller's rows
# independent instead of one INSERT OR REPLACE evicting the other's.
# From: Issue #1095.
#
# What: table renamed version_cache -> version_cache_v2 for this change.
# Why: real cache blobs already exist under the old schema (no
# history_fingerprint column); CREATE TABLE IF NOT EXISTS is a no-op
# against them, so reusing the old name would silently break every write.
# From: Issue #1095.
sra_cache_schema_sql() {
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS version_cache_v2 (
  package TEXT NOT NULL,
  version_id INTEGER NOT NULL,
  digest TEXT NOT NULL,
  tags TEXT NOT NULL,
  resolution TEXT NOT NULL,
  history_fingerprint TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (package, version_id, history_fingerprint)
);
SQL
}

# What: builds a "ref@resolved-commit;..." fingerprint for one run's ref set.
# Why: ref-set drift (different caller, or a ref moving) must become a safe
# cache miss, never a silently stale resolution; caller must pass a stable
# ref order so the same ref set always fingerprints identically.
# From: Issue #1095.
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
# Why: a cache-miss run (first run ever, or a rotated-key restore-keys
# fallback with no prior save under this run's exact key) must produce a
# valid, empty, queryable database, not fail -- that clean fallback is the
# cache's own required self-verification per the v1.2 plan.
# From: Issue #1585.
sra_cache_init() {
  local db_path="${1:?sra_cache_init: db path is required}"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sra_cache_schema_sql | sqlite3 "$db_path"
}

# What: escapes a value for safe inclusion inside a single-quoted SQL literal.
# Why: sqlite3's CLI has no separate parameter-binding mode for an ad hoc
# statement string built from a shell script; doubling an embedded single
# quote is SQL's own standard escape for exactly this case.
# From: Issue #1585.
sra_sql_quote() {
  local value="${1?sra_sql_quote: value argument is required}"
  printf '%s' "${value//\'/\'\'}"
}

# What: bulk-reads one package's cached rows for one history_fingerprint.
# Why: one sqlite3 call per package, not per version; filtering by
# fingerprint server-side means a caller only ever sees its own ref-set's
# rows, never a different caller's stale one for the same version.
# From: Issue #1585 | Issue #1095.
sra_cache_read_package() {
  local db_path="${1:?sra_cache_read_package: db path is required}"
  local package="${2:?sra_cache_read_package: package is required}"
  local history_fingerprint="${3:?sra_cache_read_package: history fingerprint is required}"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db_path" ]] || return 1
  sqlite3 -separator "$(printf '\t')" "$db_path" \
    "SELECT version_id, digest, tags, resolution FROM version_cache_v2 WHERE package = '$(sra_sql_quote "$package")' AND history_fingerprint = '$(sra_sql_quote "$history_fingerprint")';"
}

# What: bulk-writes one package's updated cache rows in a single transaction.
# Why: same one-call-per-package reasoning as the read side; rows_file is
# pre-built TSV(version_id, digest, tags, resolution) fed on a real path,
# not stdin, so the caller controls its own temp-file lifecycle.
# From: Issue #1585.
sra_cache_write_package() {
  local db_path="${1:?sra_cache_write_package: db path is required}"
  local package="${2:?sra_cache_write_package: package is required}"
  local rows_file="${3:?sra_cache_write_package: rows file is required}"
  local history_fingerprint="${4:?sra_cache_write_package: history fingerprint is required}"
  local now version_id digest tags resolution sql_file
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$rows_file" ]] || return 1

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sql_file="$(mktemp)"
  {
    printf 'BEGIN TRANSACTION;\n'
    while IFS=$'\t' read -r version_id digest tags resolution; do
      [[ "$version_id" =~ ^[0-9]+$ ]] || continue
      printf "INSERT OR REPLACE INTO version_cache_v2 (package, version_id, digest, tags, resolution, history_fingerprint, updated_at) VALUES ('%s', %s, '%s', '%s', '%s', '%s', '%s');\n" \
        "$(sra_sql_quote "$package")" "$version_id" "$(sra_sql_quote "$digest")" "$(sra_sql_quote "$tags")" "$(sra_sql_quote "$resolution")" "$(sra_sql_quote "$history_fingerprint")" "$now"
    done <"$rows_file"
    printf 'COMMIT;\n'
  } >"$sql_file"
  if sqlite3 "$db_path" <"$sql_file"; then
    rm -f -- "$sql_file"
  else
    rm -f -- "$sql_file"
    return 1
  fi
}

