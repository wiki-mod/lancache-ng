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

ci_usage() {
  cat >&2 <<'EOF'
usage: ci.sh <command> [args]
commands:
  require-digest <value>
  require-source-sha <value>
  validate-platform-record <file> <amd64|arm64>
  validate-index-record <file>
  resolve-ref-state <image-ref>
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
