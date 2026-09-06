#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: One authoritative CI image-identity helper.
# Why: Workflows call this, not per-runner duplicated logic.
# From: Issue #1095

# What: No strict mode at top level, only inside ci_main.
# Why: tests/bats/ci.bats sources this file for unit tests.
# From: Issue #1095

# What: Named 3-state read codes, idempotent on re-source.
# Why: readonly re-declaration would error on a re-source.
# From: Issue #1095
if [[ -z "${CI_STATE_PRESENT:-}" ]]; then
  readonly CI_STATE_PRESENT=0
  readonly CI_STATE_AMBIGUOUS=1
  readonly CI_STATE_ABSENT=2
fi

# ci_require_digest <value>
ci_require_digest() {
  local value="${1:-}"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] && return 0
  printf 'ci_require_digest: not a strict sha256 digest: %s\n' \
    "${value:-<empty>}" >&2
  return 1
}

# ci_require_source_sha <value>
ci_require_source_sha() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] && return 0
  printf 'ci_require_source_sha: not a 40-hex commit sha: %s\n' \
    "${value:-<empty>}" >&2
  return 1
}

# ci_validate_platform_record <file> <amd64|arm64>
#
# What: Fail-closed jq gate for one arch's record.
# Why: Platform is a parameter, never a duplicated function.
# From: Issue #1095
ci_validate_platform_record() {
  local file="${1:?ci_validate_platform_record: file is required}"
  local platform="${2:?ci_validate_platform_record: platform is required}"
  local expected
  case "$platform" in
    amd64|arm64) expected="linux/$platform" ;;
    *)
      printf 'ci_validate_platform_record: bad platform: %s\n' \
        "$platform" >&2
      return 1
      ;;
  esac
  jq -e --arg platform "$expected" '
    try (
      .schema == "image-candidate-platform/v1"
      and (.scope == "runtime" or .scope == "tooling")
      and (.service | type == "string" and length > 0)
      and (.image | type == "string" and length > 0)
      and (.platform == $platform)
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (.source_fingerprint | test("^sha256:[0-9a-f]{64}$"))
      and (.digest | test("^sha256:[0-9a-f]{64}$"))
      and (.mode == "built" or .mode == "reused")
      and (
        if .mode == "reused"
        then (.reused_index_digest | test("^sha256:[0-9a-f]{64}$"))
        else (.reused_index_digest == "")
        end
      )
    ) catch false
  ' "$file" >/dev/null
}

# ci_validate_index_record <file>
#
# What: Fail-closed jq gate for a multi-platform index.
# Why: Digest is identity; a malformed index must reject.
# From: Issue #1095
ci_validate_index_record() {
  local file="${1:?ci_validate_index_record: file is required}"
  jq -e '
    try (
      (.image) as $img
      | (.digest) as $dg
      | (.candidate_ref) as $ref
      | .schema == "image-candidate-index/v1"
      and (.scope == "runtime" or .scope == "tooling")
      and (.service | type == "string" and length > 0)
      and ($img | type == "string" and length > 0)
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (.source_fingerprint | test("^sha256:[0-9a-f]{64}$"))
      and ($dg | test("^sha256:[0-9a-f]{64}$"))
      and ($ref | type == "string" and length > 0)
      and (
        ($ref == ($img + "@" + $dg))
        or (
          ($ref | startswith($img + ":"))
          and (($ref | ltrimstr($img + ":"))
               | test("^[A-Za-z0-9._-]+$"))
        )
      )
      and (.platforms | type == "object")
      and ((.platforms | keys) == ["linux/amd64","linux/arm64"])
      and (.platforms["linux/amd64"] | test("^sha256:[0-9a-f]{64}$"))
      and (.platforms["linux/arm64"] | test("^sha256:[0-9a-f]{64}$"))
    ) catch false
  ' "$file" >/dev/null
}

# ci_ensure_registry_lib
#
# What: Sources the shared registry read/classify helpers.
# Why: Reuse _sif_inspect's 3-state read, never rebuild it.
# From: Issue #1095
ci_ensure_registry_lib() {
  declare -F _sif_inspect >/dev/null && return 0
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib/ghcr-retry.sh
  source "$dir/../lib/ghcr-retry.sh"
  # shellcheck source=scripts/lib/staging-image-freshness.sh
  source "$dir/../lib/staging-image-freshness.sh"
}

# ci_resolve_ref_state <image-ref>
#
# What: 3-state digest read; caller decides on the code.
# Why: Forward-built; absent must never become a wait loop.
# From: Issue #1095
ci_resolve_ref_state() {
  local ref="${1:?ci_resolve_ref_state: ref is required}"
  ci_ensure_registry_lib
  local out status digest
  # What: Capture status via if, not a bare assignment.
  # Why: set -e would abort before we read a nonzero code.
  # From: Issue #1095
  if out="$(_sif_inspect "$ref" \
      --format '{{json .Manifest.Digest}}')"; then
    status=0
  else
    status=$?
  fi
  if (( status == 0 )); then
    digest="${out%\"}"
    digest="${digest#\"}"
    # What: Reject a present ref whose digest is malformed.
    # Why: An unverifiable identity must fail closed.
    # From: Issue #1095
    ci_require_digest "$digest" || return "$CI_STATE_AMBIGUOUS"
    printf '%s\n' "$digest"
    return "$CI_STATE_PRESENT"
  fi
  # What: Map a confirmed 404 to absent, else ambiguous.
  # Why: Auth, network, and timeout must stay fail-closed.
  # From: Issue #1095
  if (( status == 2 )); then
    return "$CI_STATE_ABSENT"
  fi
  return "$CI_STATE_AMBIGUOUS"
}

# === CLUSTER 2: SOURCE FINGERPRINT (Issue #1095) ===

# ci_normalize <file>
#
# What: Drops comment/blank lines, CRLF->LF, canon bytes.
# Why: v1 semantic scope only (doc 12.5), not full AST.
# From: Issue #1095
ci_normalize() {
  local file="${1:?ci_normalize: file is required}"
  if [[ ! -f "$file" ]]; then
    printf 'ci_normalize: file not found: %s\n' "$file" >&2
    return 1
  fi
  # What: Markdown carries no v1 semantic identity here.
  # Why: doc 12.4 treats .md as NOOP until a real input.
  # From: Issue #1095
  case "$file" in
    *.md) return 0 ;;
  esac
  local content
  # What: A '#'-led heredoc body line is stripped too.
  # Why: v1 has no parser context; doc 12.5 known gap.
  # From: Issue #1095
  content="$(sed -e 's/\r$//' -e '/^[[:space:]]*$/d' \
    -e '/^[[:space:]]*#/d' "$file")"
  if [[ -n "$content" ]]; then
    printf '%s\n' "$content"
  fi
  return 0
}

# ci_build_identity <platform> <file...>
#
# What: sha256 over platform + each file's canon bytes.
# Why: doc 16 identity; branch/PR/run/time stay excluded.
# From: Issue #1095
ci_build_identity() {
  local platform="${1:?ci_build_identity: platform is required}"
  shift || true
  case "$platform" in
    linux/amd64|linux/arm64) : ;;
    *)
      printf 'ci_build_identity: bad platform: %s\n' \
        "$platform" >&2
      return 1
      ;;
  esac
  if (( $# == 0 )); then
    printf 'ci_build_identity: at least one file required\n' >&2
    return 1
  fi
  # What: Sort input paths so caller order can't matter.
  # Why: doc 16 identity must be a pure content function.
  # From: Issue #1095
  local sorted_files
  sorted_files="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  local combined="platform=$platform"
  local f normalized file_hash
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    normalized="$(ci_normalize "$f")" || return 1
    # What: Hash content first; bind a fixed-width token.
    # Why: Raw content could forge a fake 'file=' boundary.
    # From: Issue #1095
    file_hash="$(printf '%s' "$normalized" | sha256sum | awk '{print $1}')"
    combined+=$'\n'"file=$f sha256:$file_hash"
  done <<< "$sorted_files"
  local -a ext_digests=()
  if [[ -n "${CI_EXTERNAL_PINNED_DIGESTS:-}" ]]; then
    # What: Newlines become spaces; read stops at first.
    # Why: A newline list must not silently get truncated.
    # From: Issue #1095
    read -ra ext_digests <<< "${CI_EXTERNAL_PINNED_DIGESTS//$'\n'/ }"
  fi
  if (( ${#ext_digests[@]} > 0 )); then
    local d sorted_ext
    for d in "${ext_digests[@]}"; do
      # What: Rejects a malformed external digest input.
      # Why: doc 17 resolves it elsewhere, not here.
      # From: Issue #1095
      ci_require_digest "$d" || return 1
    done
    sorted_ext="$(printf '%s\n' "${ext_digests[@]}" | LC_ALL=C sort)"
    combined+=$'\n'"external="$'\n'"$sorted_ext"
  fi
  local digest
  digest="sha256:$(printf '%s' "$combined" | sha256sum | awk '{print $1}')"
  ci_require_digest "$digest" || return 1
  printf '%s\n' "$digest"
}

# ci_build_admission <impact> <resolver_state>
#
# What: Pure decision: impact+resolver -> NOOP/REUSE/etc.
# Why: doc 19/2.3; UNKNOWN must never become BUILD.
# From: Issue #1095
ci_build_admission() {
  local impact="${1:?ci_build_admission: impact is required}"
  local resolver="${2:?ci_build_admission: resolver_state is required}"
  # What: impact=none never reaches resolution at all.
  # Why: doc 19 diagram routes NOOP before RESOLVE.
  # From: Issue #1095
  if [[ "$impact" == "none" ]]; then
    printf 'NOOP\n'
    return 0
  fi
  if [[ "$impact" != "yes" ]]; then
    printf 'BLOCK\n'
    return 1
  fi
  case "$resolver" in
    present)
      printf 'REUSE\n'
      return 0
      ;;
    absent)
      printf 'BUILD\n'
      return 0
      ;;
    *)
      # What: ambiguous/unknown resolver fails closed here.
      # Why: doc 2.3 UNKNOWN must never become BUILD.
      # From: Issue #1095
      printf 'BLOCK\n'
      return 1
      ;;
  esac
}

ci_usage() {
  cat >&2 <<'EOF'
usage: ci.sh <command> [args]
commands:
  require-digest <value>
  require-source-sha <value>
  validate-platform-record <file> <amd64|arm64>
  validate-index-record <file>
  resolve-ref-state <image-ref>
  normalize <file>
  build-identity <platform> <file...>
  admission <impact> <resolver_state>
EOF
}

# ci_main <command> [args]
#
# What: Strict mode is set here, not at file top level.
# Why: A sourcing test shell keeps its own options.
# From: Issue #1095
ci_main() {
  set -euo pipefail
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    require-digest) ci_require_digest "$@" ;;
    require-source-sha) ci_require_source_sha "$@" ;;
    validate-platform-record) ci_validate_platform_record "$@" ;;
    validate-index-record) ci_validate_index_record "$@" ;;
    resolve-ref-state) ci_resolve_ref_state "$@" ;;
    normalize) ci_normalize "$@" ;;
    build-identity) ci_build_identity "$@" ;;
    admission) ci_build_admission "$@" ;;
    ""|-h|--help) ci_usage; return 2 ;;
    *)
      printf 'ci.sh: unknown command: %s\n' "$cmd" >&2
      ci_usage
      return 2
      ;;
  esac
}

# What: Run the dispatcher only when executed directly.
# Why: Sourcing for tests must not trigger the dispatcher.
# From: Issue #1095
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ci_main "$@"
fi
