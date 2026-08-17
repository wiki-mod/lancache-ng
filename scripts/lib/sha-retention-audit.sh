#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: pure helpers for the read-only SHA retention audit -- manifest/
# version shape validation and protected-reference classification.
# Why: never mutates GHCR; kept pure so every rule is directly unit-testable
# without a live audit run.
# From: Issue #1095 | PR #1501.

if [[ -n "${SHA_RETENTION_AUDIT_LIB_LOADED:-}" ]]; then
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 0
  fi
  return 0
fi
SHA_RETENTION_AUDIT_LIB_LOADED=1

_sra_read_manifest_positive_integer() {
  # What: reads one "  <key>: <positive-integer>" line from the manifest.
  # Why: sra_read_retention_keep and sra_read_minimum_stable_releases share
  # this exact parsing rule to avoid a driftable second copy (AG-CODE-011).
  # From: Issue #1095 | PR #1501.
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

sra_read_retention_keep() {
  local manifest="${1:?sra_read_retention_keep: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "accepted_ordinary_roots_per_package"
}

sra_read_minimum_stable_releases() {
  # What: reads retention.minimum_stable_releases from the manifest.
  # Why: sra_select_supported_release_tags needs this count to know how many
  # recent vX.Y.Z tags stay protected (docs/release-versioning.md's
  # Retention section).
  # From: Issue #1095 | PR #1501.
  local manifest="${1:?sra_read_minimum_stable_releases: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "minimum_stable_releases"
}

_sra_read_manifest_list() {
  # What: reads a "  <key>:\n    - item\n    - item" block-list from the
  # manifest, one item per output line. A duplicate header always fails
  # closed. allow_empty (3rd arg, default "false") governs both an
  # entirely-absent header and a header with zero items beneath it.
  # Why: shared parsing rule for every retention list key (today only
  # rollback_anchors), so a future second list key does not duplicate this
  # logic (AG-CODE-011).
  # From: Issue #1095 | PR #1501.
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

sra_read_rollback_anchors() {
  # What: reads retention.rollback_anchors from the manifest, one digest per
  # output line; succeeds with empty output when the list is absent or has
  # zero entries.
  # Why: the manifest's steady state is an empty list -- a maintainer only
  # adds an entry after a real regression is found, so "no rollback anchor
  # is currently declared" must not be an error.
  # From: Issue #1095 | PR #1501.
  local manifest="${1:?sra_read_rollback_anchors: manifest is required}"
  _sra_read_manifest_list "$manifest" rollback_anchors true
}

sra_is_rollback_anchor_digest() {
  # What: checks whether a value has the exact sha256:<64-hex> digest shape.
  # Why: a rollback anchor is deliberately digest-only, never a git tag/ref
  # -- a tag can be moved or deleted out from under an anchor without this
  # audit ever noticing; a content-addressed digest cannot.
  # From: Issue #1095 | PR #1501.
  local value="${1:?sra_is_rollback_anchor_digest: value is required}"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]]
}

sra_digest_is_rollback_anchor() {
  # What: exact-match membership check between a candidate digest and a set
  # of declared anchor digests.
  # Why: never a substring/prefix match, the same conservative-match
  # philosophy as this file's other tag/digest comparisons.
  # From: Issue #1095 | PR #1501.
  local digest="${1:?sra_digest_is_rollback_anchor: digest is required}"
  shift
  local anchor
  for anchor in "$@"; do
    [[ "$digest" == "$anchor" ]] && return 0
  done
  return 1
}

sra_validate_rollback_anchors_list() {
  # What: validates an already-read rollback_anchors list (the output shape
  # of sra_read_rollback_anchors): every entry, if any, must be non-blank
  # and pass sra_is_rollback_anchor_digest. Prints one reason on the first
  # violation and returns 1; silent on success.
  # Why: factored out as a pure function (no manifest path, no exit calls)
  # so both the CI-time static check (validate-stack-images.sh) and the
  # audit's own read-time defense-in-depth re-validation
  # (gc-sha-retention-audit.sh) share one canonical acceptance rule
  # (AG-CODE-011).
  # From: Issue #1095 | PR #1501.
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

# What: validates a fetched GHCR versions page against the exact shape the
# orchestrator's classification loop below assumes.
# Why: refusing a malformed page here, before classification runs, avoids
# misclassifying partial or unexpected data as a real audit result.
# From: Issue #1095 | PR #1501.
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

# What: classifies one tag as a root sha-<commit>, a per-platform
# sha-<commit>-<arch> child, or any other tag shape.
# Why: root vs. child vs. other drives every downstream protect/would-delete
# decision, so this classification is centralized in one place.
# From: Issue #1095 | PR #1501.
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

# What: resolves a sha-<commit> tag's short/full hex prefix to a real,
# existing full 40-char commit object in the given repository.
# Why: an unresolvable prefix must fail closed, not be silently treated as
# an unknown/unranked commit that could then rank as newest.
# From: Issue #1095 | PR #1501.
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

sra_validate_created_at_string() {
  # What: checks a string against the GHCR created_at shape (YYYY-MM-DDTHH:MM:SSZ).
  # Why: split from sra_version_created_at so the hot loop validates an
  # already-extracted value instead of paying a second per-version jq call.
  # From: Issue #1095 | PR #1501.
  local created_at="${1?sra_validate_created_at_string: value argument is required}"
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

sra_version_created_at() {
  # What: extracts the GHCR-reported build timestamp for one package version.
  # Why: display-only -- ranking stays 100% git-history-derived, so this
  # helper is never called from the ranking path; the orchestrator's hot
  # loop calls sra_validate_created_at_string directly instead.
  # From: Issue #1095 | PR #1501.
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

sra_emit_record() {
  # What: formats one AUDIT report line for a classified package version.
  # Why: a pure formatter (no I/O beyond stdout) so classification fields
  # stay directly unit-testable instead of reachable only via a live run.
  # From: Issue #1095 | PR #1501.
  local class="${1:?sra_emit_record: class is required}"
  local package="${2:?sra_emit_record: package is required}"
  local id="${3:?sra_emit_record: id is required}"
  local digest="${4:?sra_emit_record: digest is required}"
  # What: validates the tags argument with "${5?}" (no colon), not "${5:?}".
  # Why: a GHCR package version can legitimately have zero tags (e.g. an
  # untagged attestation manifest); the colon form rejects empty as if it
  # were unset, while the no-colon form still catches a truly missing arg.
  # From: Issue #1095 | PR #1501.
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

sra_is_stable_release_tag() {
  # What: checks whether a tag has the stable-release shape vX.Y.Z, with no
  # pre-release suffix.
  # Why: distinct from a release-candidate tag (vX.Y.Z-rc.N) -- only a
  # genuine stable release counts toward minimum_stable_releases.
  # From: Issue #1095 | PR #1501.
  local tag="${1:?sra_is_stable_release_tag: tag is required}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

sra_release_sort_key() {
  # What: converts a vX.Y.Z tag into a zero-padded, lexically-sortable key.
  # Why: bash has no native semver comparator; zero-padding each component
  # lets a plain `sort -r` order releases newest-first.
  # From: Issue #1095 | PR #1501.
  local tag="${1:?sra_release_sort_key: tag is required}"
  local major minor patch
  sra_is_stable_release_tag "$tag" || return 1
  IFS='.' read -r major minor patch <<<"${tag#v}"
  printf '%020d.%020d.%020d\n' "$major" "$minor" "$patch"
}

sra_select_supported_release_tags() {
  # What: reads stable-release tags (one per line) from stdin and prints the
  # newest `count` of them, one per line, newest first.
  # Why: computed from tags already fetched during the audit, avoiding a
  # separate GitHub Releases API call (AG-VAL-005).
  # From: Issue #1095 | PR #1501.
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
  # What: captures the sorted list into a variable before head/cut.
  # Why: piping sort directly into an early-exiting consumer under
  # `set -o pipefail` can misreport SIGPIPE as failure (AG-VAL-032).
  # From: Issue #1095 | PR #1501.
  local sorted selected
  sorted="$(printf '%s\n' "${keyed[@]}" | sort -r)"
  selected="$(head -n "$count" <<<"$sorted")"
  cut -d'|' -f2- <<<"$selected"
}

sra_classify_channel_tag() {
  # What: classifies one non-SHA ("other"-kind) tag into the protected
  # channel it identifies, if any.
  # Why: separates nightly/latest/stable-release from an unrecognized tag so
  # the caller can report a specific protection reason, not a generic one.
  # From: Issue #1095 | PR #1501.
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

sra_other_tags_from_csv() {
  # What: extracts every "other"-kind tag (per sra_tag_kind) from an
  # already comma-joined tag list, one per line.
  # Why: pure-bash split avoids a second per-version jq/base64 round-trip;
  # a literal comma split is safe since OCI's tag grammar forbids commas.
  # From: Issue #1095 | PR #1501.
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

sra_protected_reference_reason() {
  # What: given a version's "other" tags and supported releases, returns a
  # "+"-joined reason covering every protected channel that applies.
  # Why: a digest can match several channels at once, so picking one would
  # hide information; failure means none matched.
  # From: Issue #1095 | PR #1501.
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

sra_extra_tag_protect_reason() {
  # What: combines sra_other_tags_from_csv + sra_protected_reference_reason
  # into one always-succeeding call with a caller-supplied fallback reason.
  # Why: only the root_count==0 branch uses this; a version with a root tag
  # must call sra_protected_reference_reason directly instead.
  # From: Issue #1095 | PR #1501.
  local tags_csv="${1?sra_extra_tag_protect_reason: tags CSV argument is required}"
  local supported_releases="${2?sra_extra_tag_protect_reason: supported releases argument is required}"
  local fallback_reason="${3:?sra_extra_tag_protect_reason: fallback reason is required}"
  local other_tags reason

  other_tags="$(sra_other_tags_from_csv "$tags_csv")" || return 1
  if reason="$(sra_protected_reference_reason "$other_tags" "$supported_releases")"; then
    printf '%s\n' "$reason"
  else
    printf '%s\n' "$fallback_reason"
  fi
}
