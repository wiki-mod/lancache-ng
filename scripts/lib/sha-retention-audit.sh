#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Pure helpers for the read-only SHA retention audit. The functions validate
# the exact manifest/version shapes the audit relies on, classify whether a
# version's digest is protected by the nightly/latest channels or a
# supported stable release, and never mutate GHCR.

if [[ -n "${SHA_RETENTION_AUDIT_LIB_LOADED:-}" ]]; then
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 0
  fi
  return 0
fi
SHA_RETENTION_AUDIT_LIB_LOADED=1

_sra_read_manifest_positive_integer() {
  # What: reads exactly one "  <key>: <positive-integer>" top-level-indented
  # scalar line from the manifest and returns its integer value.
  # Why: sra_read_retention_keep and sra_read_minimum_stable_releases both
  # parse the identical two-space-indented top-level-scalar shape, just
  # under different keys; sharing the exactly-one-match/positive-integer
  # parsing rule here avoids a second, driftable copy of it (AG-CODE-011).
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
  # of a package's own vX.Y.Z tags are still "supported" stable releases for
  # protected-reference classification (docs/release-versioning.md's
  # Retention section). From: Issue #1095 | PR #1501.
  local manifest="${1:?sra_read_minimum_stable_releases: manifest is required}"
  _sra_read_manifest_positive_integer "$manifest" "minimum_stable_releases"
}

sra_manifest_packages() {
  local manifest="${1:?sra_manifest_packages: manifest is required}"

  awk '
    /^(runtime|tooling|metadata):$/ {
      section=$0
      sub(/:$/, "", section)
      next
    }
    section != "" && /^[[:alnum:]_-]+:/ {
      section=""
    }
    section != "" && /^  - name: / {
      name=$0
      sub(/^  - name: /, "", name)
      print section "\t" name
    }
  ' "$manifest"
}

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

sra_commit_is_on_history_ref() {
  local git_dir="${1:?sra_commit_is_on_history_ref: git directory is required}"
  local commit="${2:?sra_commit_is_on_history_ref: commit is required}"
  local history_ref="${3:?sra_commit_is_on_history_ref: history ref is required}"
  git -C "$git_dir" merge-base --is-ancestor "$commit" "$history_ref"
}

sra_validate_created_at_string() {
  # What: checks an already-extracted string against the expected GHCR
  # created_at shape (YYYY-MM-DDTHH:MM:SSZ), with no jq call of its own.
  # Why: split out from sra_version_created_at so the orchestrator's hot loop
  # can validate a value it already extracted via one combined jq call per
  # version instead of paying a second per-version jq subprocess just for
  # this field (a real live-audit timeout, run 31774741729, was traced to
  # exactly this kind of avoidable per-version subprocess overhead).
  local created_at="${1?sra_validate_created_at_string: value argument is required}"
  [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

sra_version_created_at() {
  # What: extracts the GHCR-reported build timestamp for one package version.
  # Why: display-only -- the dry-run report shows a real build date per
  # candidate, but ranking must stay 100% git-history-derived (see the
  # created_at-reuse defect this audit was rebuilt to avoid), so this helper
  # is never called from the ranking path. Kept for direct unit testing and
  # for any future caller that only has the raw JSON, not already-extracted
  # fields; the orchestrator's own hot loop calls
  # sra_validate_created_at_string directly instead (see that function's Why).
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
  # Why: a pure formatter (no I/O beyond stdout) so the dry-run would-delete
  # labeling and the built/decision fields are directly unit-testable,
  # instead of only reachable through a full live-GHCR orchestrator run.
  local class="${1:?sra_emit_record: class is required}"
  local package="${2:?sra_emit_record: package is required}"
  local id="${3:?sra_emit_record: id is required}"
  local digest="${4:?sra_emit_record: digest is required}"
  # Why: a GHCR package version can legitimately have zero tags (e.g. an
  # untagged attestation/referrer manifest) -- "${5:?}" would wrongly reject
  # that as a missing argument, since bash's :? form triggers on empty too,
  # not only unset. "${5?}" (no colon) still catches a genuinely missing
  # 5th positional argument, which is the actual bug this guard exists for.
  local tags="${5?sra_emit_record: tags argument is required}"
  local built="${6:?sra_emit_record: built is required}"
  local legacy_rank="${7:?sra_emit_record: legacy_rank is required}"
  local budget="${8:?sra_emit_record: budget is required}"
  local decision="${9:?sra_emit_record: decision is required}"
  local reason="${10:?sra_emit_record: reason is required}"
  printf 'AUDIT\tclass=%s\tpackage=%s\tid=%s\tdigest=%s\ttags=%s\tbuilt=%s\tlegacy_rank=%s\tbudget=%s\tacceptance=unknown\tdecision=%s\treason=%s\n' \
    "$class" "$package" "$id" "$digest" "$tags" "$built" "$legacy_rank" "$budget" "$decision" "$reason"
}

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
  # Why: distinct from a release-candidate tag (vX.Y.Z-rc.N, see
  # release/stack-images.yml's release_candidate channel) -- only a genuine
  # stable release counts toward retention.minimum_stable_releases. From:
  # Issue #1095 | PR #1501.
  local tag="${1:?sra_is_stable_release_tag: tag is required}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

sra_release_sort_key() {
  # What: converts a vX.Y.Z tag into a zero-padded, lexically-sortable key.
  # Why: bash has no native semver comparator; zero-padding each numeric
  # component lets a plain `sort -r` order releases newest-first without a
  # per-component numeric comparison loop. From: Issue #1095 | PR #1501.
  local tag="${1:?sra_release_sort_key: tag is required}"
  local major minor patch
  sra_is_stable_release_tag "$tag" || return 1
  IFS='.' read -r major minor patch <<<"${tag#v}"
  printf '%020d.%020d.%020d\n' "$major" "$minor" "$patch"
}

sra_select_supported_release_tags() {
  # What: reads stable-release tags (one per line) from stdin and prints the
  # newest `count` of them, one per line, newest first.
  # Why: retention.minimum_stable_releases (release/stack-images.yml) defines
  # how many of a package's own recent stable releases stay protected; this
  # is computed per package from tags already fetched during the audit,
  # avoiding a separate GitHub Releases API call (AG-VAL-005 prefers a native
  # local computation over an API call whenever both do the same job). From:
  # Issue #1095 | PR #1501.
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
  # Why: `sort -r | head -n "$count"` would pipe a live producer into an
  # early-exiting consumer under the caller's `set -o pipefail`, which can
  # report pipeline failure via SIGPIPE even though `head` itself matched
  # correctly (AG-VAL-032, enforced repo-wide by
  # scripts/check-pipefail-early-exit-grep.sh). Capturing into a variable
  # first and applying `head`/`cut` via here-strings avoids the live pipe
  # entirely.
  local sorted selected
  sorted="$(printf '%s\n' "${keyed[@]}" | sort -r)"
  selected="$(head -n "$count" <<<"$sorted")"
  cut -d'|' -f2- <<<"$selected"
}

sra_classify_channel_tag() {
  # What: classifies one non-SHA ("other"-kind) tag into the protected
  # channel it identifies, if any.
  # Why: separates "this is literally the nightly/latest pointer" from "this
  # is a stable release tag" from "this is some other, unrecognized tag" so
  # the caller can report a specific protection reason instead of a single
  # generic bucket (docs/release-versioning.md's Retention section). From:
  # Issue #1095 | PR #1501.
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
  # already comma-joined tag list -- i.e. every tag that is not a
  # sha-<commit> root or sha-<commit>-<arch> child alias -- one per line.
  # Why: the orchestrator's hot per-version loop already extracts a
  # comma-joined tag list via one combined jq call per version (see
  # gc-sha-retention-audit.sh's own Why comment on the per-version jq
  # timeout, run 31774741729, that combined call was already built to
  # avoid). Deriving "other" tags in pure bash from that value, instead of
  # a second jq/base64 round-trip per version, avoids reintroducing exactly
  # that per-version jq overhead for every one of the tens of thousands of
  # package versions a live audit classifies. Splitting on a literal comma
  # (rather than the @base64-per-tag encoding sra_version_tag_facts uses) is
  # safe only because the OCI distribution spec's tag-name grammar
  # ([a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}) forbids commas in a real tag; this
  # function must not be reused for a delimiter that isn't grammar-excluded
  # this way. From: Issue #1095 | PR #1501.
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
  # What: given a version's "other"-kind tags and a package's supported
  # stable-release tag set, returns a "+"-joined, specific protection reason
  # (nightly-channel-protected, latest-channel-protected,
  # stable-release-protected) covering every protected channel that actually
  # applies to this version, or fails when none apply.
  # Why: a digest can legitimately be nightly AND latest AND a just-cut
  # stable release all at once (e.g. immediately after a promotion, when
  # current_dev and master briefly share a commit) -- collapsing that into
  # one arbitrarily-picked reason would hide real information a maintainer
  # reading the report needs. Returning failure (not a reason string) lets
  # the caller fall back to its own existing, still-honest generic reason
  # when the extra tag matches none of these specific channels. From: Issue
  # #1095 | PR #1501.
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
  # into the single call the orchestrator's root_count==0 branch needs,
  # falling back to a caller-supplied generic reason when no specific
  # protected channel matches. Why: a version with no sha-<commit> alias at
  # all has nothing a git-history root rank could apply to, so it always
  # stays protect -- only the reason text varies; this differs from the
  # orchestrator's other_count>0-with-a-root-tag case (which must be able to
  # fall through to ordinary ranking instead of always protecting, per the
  # maintainer's protected-reference scope clarification on Issue #1095 | PR #1501, so
  # that branch calls sra_protected_reference_reason directly and checks its
  # own success/failure rather than using this always-succeeds wrapper).
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
