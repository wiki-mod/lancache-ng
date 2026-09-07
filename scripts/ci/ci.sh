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

# === CLUSTER 3: SERVICE INVENTORY + IMPACT DETECTION (Issue #1095) ===

# What: Frozen CI_SERVICES + metadata tables (doc 7/8).
# Why: guards readonly re-declaration on a re-source.
# From: Issue #1095
if [[ -z "${CI_SERVICE_TABLE_LOADED:-}" ]]; then
  readonly CI_SERVICE_TABLE_LOADED=1

  # What: The 10 build-push.yml services, plus netdata.
  # Why: netdata has a real first-party Dockerfile (doc 7).
  # From: Issue #1095
  readonly -a CI_SERVICES=(
    proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools
    cachehamster netdata
  )

  # What: each service's own build-context directory.
  # Why: "-g" makes this global; setup() sources ci.sh.
  # From: Issue #1095
  declare -gA CI_SERVICE_CONTEXT=(
    [proxy]="services/proxy" [dns]="services/dns"
    [watchdog]="services/watchdog" [dhcp]="services/dhcp"
    [dhcp-proxy]="services/dhcp-proxy" [ntp]="services/ntp"
    [syslog]="services/syslog" [ui]="services/ui"
    [build-tools]="tools/build-tools"
    [cachehamster]="services/cachehamster" [netdata]="services/netdata"
  )
  readonly -A CI_SERVICE_CONTEXT

  # What: linux/ platforms actually built per service.
  # Why: netdata pins amd64 only, no arm64 build.
  # From: Issue #1095
  declare -gA CI_SERVICE_PLATFORMS=(
    [proxy]="linux/amd64,linux/arm64" [dns]="linux/amd64,linux/arm64"
    [watchdog]="linux/amd64,linux/arm64" [dhcp]="linux/amd64,linux/arm64"
    [dhcp-proxy]="linux/amd64,linux/arm64" [ntp]="linux/amd64,linux/arm64"
    [syslog]="linux/amd64,linux/arm64" [ui]="linux/amd64,linux/arm64"
    [build-tools]="linux/amd64,linux/arm64"
    [cachehamster]="linux/amd64,linux/arm64" [netdata]="linux/amd64"
  )
  readonly -A CI_SERVICE_PLATFORMS

  # What: AG-CI-002 tier, from each Dockerfile compile step.
  # Why: only a real BUILD_TOOLS_IMAGE stage earns heavy.
  # From: Issue #1095
  declare -gA CI_SERVICE_RUNNER=(
    [proxy]="light" [dns]="heavy" [watchdog]="heavy" [dhcp]="light"
    [dhcp-proxy]="light" [ntp]="light" [syslog]="light" [ui]="heavy"
    [build-tools]="heavy" [cachehamster]="heavy" [netdata]="light"
  )
  readonly -A CI_SERVICE_RUNNER

  # What: named external context(s) this service consumes.
  # Why: empty string means no external context (doc 8).
  # From: Issue #1095
  declare -gA CI_SERVICE_EXTERNAL_CONTEXT=(
    [proxy]="dns-domains=services/dns shared-scripts=scripts/lib"
    [dns]="shared-scripts=scripts/lib"
    [watchdog]="shared-scripts=scripts/lib"
    [dhcp]="shared-scripts=scripts/lib"
    [dhcp-proxy]="shared-scripts=scripts/lib"
    [ntp]="" [syslog]=""
    [ui]="shared-scripts=scripts/lib"
    [build-tools]="" [cachehamster]="" [netdata]=""
  )
  readonly -A CI_SERVICE_EXTERNAL_CONTEXT
fi

# ci_known_service <name>
#
# What: True only for a name present in CI_SERVICES.
# Why: A typo must fail closed, never report a silent NOOP.
# From: Issue #1095
ci_known_service() {
  local name="${1:?ci_known_service: name is required}" s
  for s in "${CI_SERVICES[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

# ci_service_meta <service> <context|platforms|runner|external-context>
#
# What: One central service-metadata lookup (doc 8).
# Why: One table, not duplicated per workflow/matrix job.
# From: Issue #1095
ci_service_meta() {
  local service="${1:?ci_service_meta: service is required}"
  local field="${2:?ci_service_meta: field is required}"
  ci_known_service "$service" || {
    printf 'ci_service_meta: unknown service: %s\n' "$service" >&2
    return 1
  }
  case "$field" in
    context) printf '%s\n' "${CI_SERVICE_CONTEXT[$service]}" ;;
    platforms) printf '%s\n' "${CI_SERVICE_PLATFORMS[$service]}" ;;
    runner) printf '%s\n' "${CI_SERVICE_RUNNER[$service]}" ;;
    external-context)
      printf '%s\n' "${CI_SERVICE_EXTERNAL_CONTEXT[$service]}" ;;
    *)
      printf 'ci_service_meta: unknown field: %s\n' "$field" >&2
      return 1
      ;;
  esac
}

# ci_impact_classify <path>
#
# What: Maps one changed path to its impacted service(s).
# Why: doc 13; a file path is never the service boundary.
# From: Issue #1095
ci_impact_classify() {
  local path="${1:?ci_impact_classify: path is required}"
  case "$path" in
    # What: proxy's dns-domains context copies this file.
    # Why: doc 13's own cross-service dependency example.
    # From: Issue #1095
    services/dns/cdn-domains.txt)
      printf 'dns proxy\n' ;;
    # What: the only file any shared-scripts consumer COPYs.
    # Why: grep-verified; no other scripts/lib file is used.
    # From: Issue #1095
    scripts/lib/verify-version-banner.sh)
      printf 'proxy dns watchdog dhcp dhcp-proxy ui\n' ;;
    # What: root Cargo.lock shared by dns/watchdog/ui.
    # Why: --locked needs one consistent workspace lockfile.
    # From: Issue #1095
    Cargo.toml | Cargo.lock)
      printf 'dns watchdog ui\n' ;;
    # What: rust-accel actions shared by dns/ui/watchdog.
    # Why: matches classify-image-impact.sh's service map.
    # From: Issue #1095
    .github/actions/rust-acceleration-preflight/* \
      | .github/actions/configure-rust-sccache/* \
      | .github/actions/cargo-with-sccache-fallback/*)
      printf 'dns watchdog ui\n' ;;
    # What: smoke-tests a build-tools image candidate.
    # Why: matches classify-image-impact.sh's own rule.
    # From: Issue #1095
    .github/actions/build-tools-candidate-smoke/*)
      printf 'build-tools\n' ;;
    # What: markdown has no build/runtime identity here.
    # Why: doc 12.4: docs are NOOP unless a build input.
    # From: Issue #1095
    *.md)
      printf 'NONE\n' ;;
    services/proxy/*) printf 'proxy\n' ;;
    services/dns/*) printf 'dns\n' ;;
    services/watchdog/*) printf 'watchdog\n' ;;
    services/dhcp-proxy/*) printf 'dhcp-proxy\n' ;;
    services/dhcp/*) printf 'dhcp\n' ;;
    services/ntp/*) printf 'ntp\n' ;;
    services/syslog/*) printf 'syslog\n' ;;
    services/ui/*) printf 'ui\n' ;;
    services/cachehamster/*) printf 'cachehamster\n' ;;
    services/netdata/*) printf 'netdata\n' ;;
    tools/build-tools/*) printf 'build-tools\n' ;;
    *)
      # What: unclassified path, service impact unproven.
      # Why: AG-INT-002 floor: never silent-NOOP on doubt.
      # From: Issue #1095
      printf 'ALL\n' ;;
  esac
}

# ci_semantic_changed <base_sha> <path>
#
# What: True if $path's content changed vs base_sha.
# Why: doc 12.5 normalization; comment-only skips a build.
# From: Issue #1095
ci_semantic_changed() {
  local base_sha="${1:?ci_semantic_changed: base_sha is required}"
  local path="${2:?ci_semantic_changed: path is required}"
  ci_require_source_sha "$base_sha" || return 2
  # What: a missing working-tree file is a real change.
  # Why: a removed build input is never a silent NOOP.
  # From: Issue #1095
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  local old_dir old_tmp
  old_dir="$(mktemp -d)" || return 2
  # What: keeps $path's real basename for the baseline copy.
  # Why: a bare mktemp file has no ext, breaking *.md rule.
  # From: Issue #1095
  old_tmp="$old_dir/$(basename -- "$path")"
  # What: reads $path as of base_sha, if it existed there.
  # Why: a brand-new path has no prior baseline to compare.
  # From: Issue #1095
  if ! git show "${base_sha}:${path}" >"$old_tmp" 2>/dev/null; then
    rm -rf "$old_dir"
    return 0
  fi
  local new_norm old_norm
  if ! new_norm="$(ci_normalize "$path")"; then
    rm -rf "$old_dir"
    return 2
  fi
  if ! old_norm="$(ci_normalize "$old_tmp")"; then
    rm -rf "$old_dir"
    return 2
  fi
  rm -rf "$old_dir"
  [[ "$new_norm" != "$old_norm" ]]
}

# ci_service_impact <base_sha> <service> [<path>...]
#
# What: NOOP/IMPACTED for one service over changed paths.
# Why: doc 11 front-sieve; NOOP by default, no silent skip.
# From: Issue #1095
ci_service_impact() {
  local base_sha="${1:?ci_service_impact: base_sha is required}"
  local service="${2:?ci_service_impact: service is required}"
  shift 2 || true
  ci_require_source_sha "$base_sha" || return 1
  ci_known_service "$service" || {
    printf 'ci_service_impact: unknown service: %s\n' "$service" >&2
    return 1
  }
  local -a paths=("$@")
  if (( ${#paths[@]} == 0 )); then
    # What: no args, CHANGED_FILES unset: no diff was given.
    # Why: doc 2.3; UNKNOWN must never become a silent NOOP.
    # From: Issue #1095
    if [[ -z "${CHANGED_FILES+x}" ]]; then
      printf 'IMPACTED\n'
      return 0
    fi
    # What: falls back to CHANGED_FILES when no args given.
    # Why: doc 9; caller may pass args or the env list.
    # From: Issue #1095
    read -ra paths <<< "${CHANGED_FILES//$'\n'/ }"
  fi
  local p classes cls
  for p in "${paths[@]}"; do
    [[ -n "$p" ]] || continue
    classes="$(ci_impact_classify "$p")"
    [[ "$classes" == "NONE" ]] && continue
    if [[ "$classes" == "ALL" ]]; then
      # What: fail-closed ALL skips the semantic check.
      # Why: an unclassified path is never "just a comment".
      # From: Issue #1095
      printf 'IMPACTED\n'
      return 0
    fi
    for cls in $classes; do
      if [[ "$cls" == "$service" ]] \
          && ci_semantic_changed "$base_sha" "$p"; then
        printf 'IMPACTED\n'
        return 0
      fi
    done
  done
  printf 'NOOP\n'
}

# ci_impact <base_sha> [<path>...]
#
# What: per-service NOOP/IMPACTED over CI_SERVICES.
# Why: doc 9/10; one machine-readable line per service.
# From: Issue #1095
ci_impact() {
  local base_sha="${1:?ci_impact: base_sha is required}"
  shift || true
  local svc state
  for svc in "${CI_SERVICES[@]}"; do
    state="$(ci_service_impact "$base_sha" "$svc" "$@")" || return 1
    printf '%s=%s\n' "$svc" "$state"
  done
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
  service-meta <service> <context|platforms|runner|external-context>
  impact-classify <path>
  semantic-changed <base_sha> <path>
  service-impact <base_sha> <service> [<path>...]
  impact <base_sha> [<path>...]
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
    service-meta) ci_service_meta "$@" ;;
    impact-classify) ci_impact_classify "$@" ;;
    semantic-changed) ci_semantic_changed "$@" ;;
    service-impact) ci_service_impact "$@" ;;
    impact) ci_impact "$@" ;;
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
