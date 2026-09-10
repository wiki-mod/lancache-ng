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

# === CLUSTER 2: SOURCE FINGERPRINT ===

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

# === CLUSTER 3: SERVICE INVENTORY + IMPACT DETECTION ===

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

# === PUSH-REUSE DECISION (NOOP-first bridge) ===

# What: Named reuse verdict codes, idempotent re-source.
# Why: readonly re-declaration would error on a re-source.
# From: Issue #1095 | Issue #1835
if [[ -z "${CI_REUSE_VERIFIED:-}" ]]; then
  readonly CI_REUSE_VERIFIED=0
  readonly CI_REUSE_REBUILD=1
  readonly CI_REUSE_UNKNOWN=2
fi

# ci_push_reuse_decide <service_key> <channel_image> <github_sha>
#                      [<dep_keys>] [<ignore_workflow_gate>]
#
# What: verified-reuse probe; NOOP unless change is proven.
# Why: names the reuse path, never orders a build.
# From: Issue #1095 | Issue #1835
ci_push_reuse_decide() {
  local service_key="${1:?ci_push_reuse_decide: service_key is required}"
  local channel_image="${2:?ci_push_reuse_decide: channel_image is required}"
  local github_sha="${3:?ci_push_reuse_decide: github_sha is required}"
  local dep_keys="${4:-}"
  local ignore_workflow_gate="${5:-}"

  # What: event-agnostic; stdout bool, code splits why.
  # Why: UNKNOWN (no verdict) must not become BUILD.
  # From: Issue #1095 | Issue #1835
  ci_ensure_registry_lib

  # What: revision unreadable = no verdict, not a change.
  # Why: absent/error collapse: UNKNOWN, never BUILD.
  # From: Issue #1095 | Issue #1835
  local revision
  if ! revision="$(sif_image_revision "$channel_image")"; then
    echo "ci_push_reuse_decide: $channel_image has no readable revision label (missing image, registry error, or absent label) -- no reuse verdict (UNKNOWN)." >&2
    printf 'false\n'
    return "$CI_REUSE_UNKNOWN"
  fi

  # What: keep real status: 1=rebuild, 2/3=UNKNOWN.
  # Why: '! cmd' would invert $? to 0 and hide it.
  # From: Issue #1095 | Issue #1835
  local ancestor_status=0
  sif_is_ancestor_or_equal "$revision" "$github_sha" || ancestor_status=$?
  if [[ "$ancestor_status" == "1" ]]; then
    echo "ci_push_reuse_decide: $revision is not a git ancestor of $github_sha -- real rebuild verdict." >&2
    printf 'false\n'
    return "$CI_REUSE_REBUILD"
  fi
  if [[ "$ancestor_status" != "0" ]]; then
    echo "ci_push_reuse_decide: ancestry unprovable for $revision..$github_sha (status $ancestor_status; shallow/missing history) -- no reuse verdict (UNKNOWN)." >&2
    printf 'false\n'
    return "$CI_REUSE_UNKNOWN"
  fi

  # What: one classifier over the full revision..sha span.
  # Why: inject seam reuses the script; never a 2nd copy.
  # From: Issue #1095
  local classify_output
  if [[ -n "${PUSH_REUSE_CLASSIFY_CMD:-}" ]]; then
    classify_output="$("$PUSH_REUSE_CLASSIFY_CMD" "$revision" "$github_sha" 2>/dev/null)" || {
      echo "ci_push_reuse_decide: classify command failed for $revision..$github_sha -- no reuse verdict (UNKNOWN)." >&2
      printf 'false\n'
      return "$CI_REUSE_UNKNOWN"
    }
  else
    local dir classify_script
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    classify_script="${PUSH_REUSE_CLASSIFY_SCRIPT:-$dir/../untracked/classify-image-impact.sh}"
    classify_output="$(bash "$classify_script" "$revision" "$github_sha" 2>/dev/null)" || {
      echo "ci_push_reuse_decide: $classify_script failed for $revision..$github_sha -- no reuse verdict (UNKNOWN)." >&2
      printf 'false\n'
      return "$CI_REUSE_UNKNOWN"
    }
  fi

  # What: this service's own path changed = real rebuild.
  # Why: anything but 'false' fails closed to build.
  # From: Issue #1095
  local changed_flag
  changed_flag="$(grep -m1 "^${service_key}=" <<<"$classify_output" | cut -d= -f2 || true)"
  if [[ "$changed_flag" != "false" ]]; then
    echo "ci_push_reuse_decide: classify reported '${service_key}=${changed_flag:-<missing>}' for $revision..$github_sha -- real rebuild verdict." >&2
    printf 'false\n'
    return "$CI_REUSE_REBUILD"
  fi

  # What: workflow-scope gate over the full revision span.
  # Why: a build-affecting workflow change forces rebuild.
  # From: Issue #1095 | PR #1378
  if [[ "$ignore_workflow_gate" != "true" ]]; then
    local workflow_flag
    workflow_flag="$(grep -m1 '^workflow_reuse_scope=' <<<"$classify_output" | cut -d= -f2 || true)"
    if [[ "$workflow_flag" != "false" ]]; then
      echo "ci_push_reuse_decide: classify reported 'workflow_reuse_scope=${workflow_flag:-<missing>}' for $revision..$github_sha -- real rebuild verdict." >&2
      printf 'false\n'
      return "$CI_REUSE_REBUILD"
    fi
  fi

  # What: a declared dependency key changed = real rebuild.
  # Why: this key can't see a first-party base image bump.
  # From: Issue #1095
  local dep_key dep_flag
  for dep_key in $dep_keys; do
    dep_flag="$(grep -m1 "^${dep_key}=" <<<"$classify_output" | cut -d= -f2 || true)"
    if [[ "$dep_flag" != "false" ]]; then
      echo "ci_push_reuse_decide: classify reported '${dep_key}=${dep_flag:-<missing>}' for $revision..$github_sha -- real rebuild verdict." >&2
      printf 'false\n'
      return "$CI_REUSE_REBUILD"
    fi
  done

  printf 'true\n'
  return "$CI_REUSE_VERIFIED"
}

# === BUILD-TOOLS IMAGE SELECTION ===

# ci_build_tools_channel <channel_ref>
#
# What: build-tools tooling-image channel for a ref.
# Why: master ships 'latest'; all else tracks 'nightly'.
# From: Issue #1095 | Issue #1153
ci_build_tools_channel() {
  # What: empty ref is a real input, maps to nightly.
  # Why: caller's GITHUB_BASE_REF/REF_NAME can be empty.
  # From: Issue #1095 | Issue #1153
  local channel_ref="${1-}"
  case "$channel_ref" in
    master) printf 'latest\n' ;;
    *) printf 'nightly\n' ;;
  esac
}

# ci_build_tools_fallback_allowed <event> <head_repo> <base_repo>
#
# What: may this ref build a branch-local build-tools image?
# Why: only trusted refs; a fork PR must never build it.
# From: Issue #1095 | Issue #842
ci_build_tools_fallback_allowed() {
  # What: bare $2/$3 = exact original 3-arg contract.
  # Why: a faithful port; robustness is a separate change.
  # From: Issue #1095 | Issue #842
  local event_name="${1:?ci_build_tools_fallback_allowed: event is required}"
  local head_repository="$2"
  local base_repository="$3"
  if [[ "$event_name" == "pull_request" ]]; then
    # What: case-insensitive; same-repo PR stays trusted.
    # Why: a repo rename can make head/base casing disagree.
    # From: Issue #1095 | Issue #842
    [[ -n "$head_repository" \
      && "${head_repository,,}" == "${base_repository,,}" ]]
  else
    return 0
  fi
}

# === CLUSTER 4: ACCEPTANCE LEDGER + ATTESTATION BOUNDARY ===

# What: Named readback verdict codes, idempotent re-source.
# Why: readonly re-declaration would error on a re-source.
# From: Issue #1095
if [[ -z "${CI_ARTIFACT_READBACK_SUCCESS:-}" ]]; then
  readonly CI_ARTIFACT_READBACK_SUCCESS=0
  readonly CI_ARTIFACT_READBACK_MISMATCH=1
  readonly CI_ARTIFACT_READBACK_NOT_FOUND=2
  readonly CI_ARTIFACT_READBACK_UNKNOWN=3
fi

# What: Named ledger query codes, idempotent on re-source.
# Why: readonly re-declaration would error on a re-source.
# From: Issue #1095
if [[ -z "${CI_LEDGER_PRESENT:-}" ]]; then
  readonly CI_LEDGER_PRESENT=0
  readonly CI_LEDGER_ABSENT=1
  readonly CI_LEDGER_UNKNOWN=2
  readonly CI_LEDGER_REJECTED=3
fi

# ci_post_build_readback <expected_digest> <ref>
#
# What: doc 23 readback; digest vs expected value.
# Why: every non-match outcome fails closed, no rebuild.
# From: Issue #1095
ci_post_build_readback() {
  local expected="${1:?ci_post_build_readback: expected_digest is required}"
  local ref="${2:?ci_post_build_readback: ref is required}"
  if ! ci_require_digest "$expected"; then
    printf 'ci_post_build_readback: bad expected_digest: %s\n' \
      "$expected" >&2
    return "$CI_ARTIFACT_READBACK_UNKNOWN"
  fi
  local observed status
  # What: Capture status via if, not a bare assignment.
  # Why: set -e would abort before we read a nonzero code.
  # From: Issue #1095
  if observed="$(ci_resolve_ref_state "$ref")"; then
    status="$CI_STATE_PRESENT"
  else
    status=$?
  fi
  case "$status" in
    "$CI_STATE_PRESENT")
      if [[ "$observed" == "$expected" ]]; then
        printf 'SUCCESS\n'
        return "$CI_ARTIFACT_READBACK_SUCCESS"
      fi
      # What: doc 23.3; wrong digest is MISMATCH.
      # Why: a rebuild could paper over real corruption.
      # From: Issue #1095
      printf 'MISMATCH\n'
      return "$CI_ARTIFACT_READBACK_MISMATCH"
      ;;
    "$CI_STATE_ABSENT")
      # What: doc 23.2; missing publish, no rebuild.
      # Why: a publish/index failure, not a build failure.
      # From: Issue #1095
      printf 'NOT_FOUND\n'
      return "$CI_ARTIFACT_READBACK_NOT_FOUND"
      ;;
    *)
      printf 'UNKNOWN\n'
      return "$CI_ARTIFACT_READBACK_UNKNOWN"
      ;;
  esac
}

# ci_attestation_state
#
# What: v1 attestation probe; always reports unverifiable.
# Why: pinned gh 2.46.0 has no `attestation` subcommand yet.
# From: Issue #1095
ci_attestation_state() {
  printf 'unverifiable\n'
  return 0
}

# ci_artifact_admission <readback_verdict> <attestation_state>
#
# What: doc 24.2 ARTIFACT ACK; digest gate only, v1.
# Why: ACCEPTED here means digest-verified, NOT attested.
# From: Issue #1095
ci_artifact_admission() {
  local readback="${1:?ci_artifact_admission: readback_verdict is required}"
  local attestation="${2:?ci_artifact_admission: attestation_state is required}"
  # What: doc 25 REJECTED, before attestation checks.
  # Why: a bad attestation input must not mask a MISMATCH.
  # From: Issue #1095
  if [[ "$readback" == "MISMATCH" ]]; then
    printf 'verdict=REJECTED attestation=%s\n' "$attestation"
    return 1
  fi
  case "$attestation" in
    verified|absent_confirmed|unverifiable) : ;;
    *)
      # What: unrecognized attestation fails closed.
      # Why: doc 2.3; garbage input is never ACCEPTED.
      # From: Issue #1095
      printf 'verdict=BLOCK attestation=%s\n' "$attestation"
      return 1
      ;;
  esac
  case "$readback" in
    SUCCESS)
      printf 'verdict=ACCEPTED attestation=%s\n' "$attestation"
      return 0
      ;;
    NOT_FOUND|UNKNOWN)
      printf 'verdict=BLOCK attestation=%s\n' "$attestation"
      return 1
      ;;
    *)
      # What: unrecognized readback verdict fails closed.
      # Why: doc 2.3; garbage must never reach ACCEPTED.
      # From: Issue #1095
      printf 'verdict=BLOCK attestation=%s\n' "$attestation"
      return 1
      ;;
  esac
}

# ci_ledger_encode_digest <digest>
#
# What: sha256:<hex> -> sha256-<hex> ref path form.
# Why: git refs forbid ':'; keeps full 64 hex (doc 15).
# From: Issue #1095
ci_ledger_encode_digest() {
  local digest="${1:?ci_ledger_encode_digest: digest is required}"
  ci_require_digest "$digest" || return 1
  printf 'sha256-%s\n' "${digest#sha256:}"
}

# ci_ledger_decode_digest <encoded>
#
# What: Inverse of ci_ledger_encode_digest; round-trip.
# Why: A malformed encoded form fails closed, no guess.
# From: Issue #1095
ci_ledger_decode_digest() {
  local encoded="${1:?ci_ledger_decode_digest: encoded is required}"
  if [[ ! "$encoded" =~ ^sha256-[0-9a-f]{64}$ ]]; then
    printf 'ci_ledger_decode_digest: not sha256-<64hex>: %s\n' \
      "$encoded" >&2
    return 1
  fi
  printf 'sha256:%s\n' "${encoded#sha256-}"
}

# ci_ledger_ref <service> <platform> <build_identity>
#
# What: doc 26.1 ledger key -> one git-ref-CAS ref path.
# Why: One ref per (service,platform,build_identity) triple.
# From: Issue #1095
ci_ledger_ref() {
  local service="${1:?ci_ledger_ref: service is required}"
  local platform="${2:?ci_ledger_ref: platform is required}"
  local build_identity="${3:?ci_ledger_ref: build_identity is required}"
  ci_known_service "$service" || {
    printf 'ci_ledger_ref: unknown service: %s\n' "$service" >&2
    return 1
  }
  local arch
  case "$platform" in
    linux/amd64) arch=amd64 ;;
    linux/arm64) arch=arm64 ;;
    *)
      printf 'ci_ledger_ref: bad platform: %s\n' "$platform" >&2
      return 1
      ;;
  esac
  local encoded
  encoded="$(ci_ledger_encode_digest "$build_identity")" || return 1
  printf 'refs/ci-acceptance-ledger/%s/%s/%s\n' \
    "$service" "$arch" "$encoded"
}

# ci_validate_ledger_record <file>
#
# What: Fail-closed jq gate for a ledger record.
# Why: verdict/attestation always explicit, never BUILD.
# From: Issue #1095
ci_validate_ledger_record() {
  local file="${1:?ci_validate_ledger_record: file is required}"
  jq -e '
    try (
      .schema == "ci-acceptance-ledger-record/v1"
      and (.service | type == "string" and length > 0)
      and (.platform == "linux/amd64" or .platform == "linux/arm64")
      and (.build_identity | test("^sha256:[0-9a-f]{64}$"))
      and (.artifact_digest | test("^sha256:[0-9a-f]{64}$"))
      and (.source_sha | test("^[0-9a-f]{40}$"))
      and (
        .verdict == "ACCEPTED" or .verdict == "REJECTED"
        or .verdict == "BLOCK"
      )
      and (
        .attestation == "verified" or .attestation == "absent_confirmed"
        or .attestation == "unverifiable"
      )
      and (.recorded_at | type == "number" and . > 0)
    ) catch false
  ' "$file" >/dev/null
}

# ci_ensure_ledger_lib
#
# What: Sources the shared git-ref-CAS lock primitives.
# Why: Reuse promote_lock_remote_sha; no CAS rebuild.
# From: Issue #1095
ci_ensure_ledger_lib() {
  declare -F promote_lock_remote_sha >/dev/null && return 0
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib/promote-lock.sh
  source "$dir/../lib/promote-lock.sh"
}

# ci_ledger_read <remote> <service> <platform> <build_identity>
#
# What: doc 26.1 read-only ledger query; no writer yet.
# Why: unqueryable is never absent (doc 26).
# From: Issue #1095
ci_ledger_read() {
  local remote="${1:?ci_ledger_read: remote is required}"
  local service="${2:?ci_ledger_read: service is required}"
  local platform="${3:?ci_ledger_read: platform is required}"
  local build_identity="${4:?ci_ledger_read: build_identity is required}"
  # What: a lib load failure must not fall through.
  # Why: an unguarded exit must never read as ABSENT.
  # From: Issue #1095
  ci_ensure_ledger_lib || return "$CI_LEDGER_UNKNOWN"
  local ref
  ref="$(ci_ledger_ref "$service" "$platform" "$build_identity")" \
    || return "$CI_LEDGER_UNKNOWN"
  local status
  # What: Discards the SHA; only presence matters here.
  # Why: A read-only v1 never needs it for a lease/takeover.
  # From: Issue #1095
  if promote_lock_remote_sha "$remote" "$ref" >/dev/null; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    return "$CI_LEDGER_ABSENT"
  fi
  if (( status != 0 )); then
    # What: a query failure is UNKNOWN, not absence.
    # Why: doc 26; unknown must never become BUILD=ACK.
    # From: Issue #1095
    return "$CI_LEDGER_UNKNOWN"
  fi
  if ! git fetch --quiet --depth=1 "$remote" "$ref" >/dev/null 2>&1; then
    return "$CI_LEDGER_UNKNOWN"
  fi
  local payload tmp_file
  payload="$(git log -1 --format=%s FETCH_HEAD 2>/dev/null)"
  tmp_file="$(mktemp)" || return "$CI_LEDGER_UNKNOWN"
  printf '%s' "$payload" > "$tmp_file"
  # What: fetches, then validates before trusting it.
  # Why: a corrupted ref must never read as ACCEPTED.
  # From: Issue #1095
  if ! ci_validate_ledger_record "$tmp_file"; then
    rm -f "$tmp_file"
    printf 'ci_ledger_read: malformed record at %s\n' "$ref" >&2
    return "$CI_LEDGER_UNKNOWN"
  fi
  # What: the record must describe the exact key queried.
  # Why: a misplaced record must never leak a wrong digest.
  # From: Issue #1095
  if ! jq -e --arg svc "$service" --arg plat "$platform" \
      --arg bid "$build_identity" \
      '.service == $svc and .platform == $plat
        and .build_identity == $bid' \
      "$tmp_file" >/dev/null; then
    rm -f "$tmp_file"
    printf 'ci_ledger_read: key mismatch at %s\n' "$ref" >&2
    return "$CI_LEDGER_UNKNOWN"
  fi
  local verdict
  verdict="$(jq -r '.verdict' "$tmp_file")"
  rm -f "$tmp_file"
  printf '%s\n' "$payload"
  # What: only an ACCEPTED record may ever count PRESENT.
  # Why: doc 25; REJECTED/BLOCK must never look reusable.
  # From: Issue #1095
  if [[ "$verdict" != "ACCEPTED" ]]; then
    return "$CI_LEDGER_REJECTED"
  fi
  return "$CI_LEDGER_PRESENT"
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
    exit 0=changed 1=unchanged 2=error; a bare call under set -e
    aborts on the (non-error) unchanged case -- guard the call
  service-impact <base_sha> <service> [<path>...]
  impact <base_sha> [<path>...]
  push-reuse-decide <service_key> <channel_image> <github_sha> \
    [<dep_keys>] [<ignore_workflow_gate>]
    exit 0=reuse verified 1=real rebuild verdict 2=UNKNOWN (no
    verdict); stdout 'true' only on 0, else 'false' fail-closed
  build-tools-channel <channel_ref>
  build-tools-fallback-allowed <event> <head_repo> <base_repo>
    exit 0=allowed 1=denied; a bare call under set -e aborts on
    the (non-error) denied case -- guard the call
  post-build-readback <expected_digest> <ref>
    exit 0=SUCCESS 1=MISMATCH 2=NOT_FOUND 3=UNKNOWN; all 4 fail
    closed, none of them may ever trigger a rebuild
  attestation-state
  artifact-admission <readback_verdict> <attestation_state>
  ledger-encode-digest <digest>
  ledger-decode-digest <encoded>
  ledger-ref <service> <platform> <build_identity>
  validate-ledger-record <file>
  ledger-read <remote> <service> <platform> <build_identity>
    exit 0=PRESENT 1=ABSENT 2=UNKNOWN 3=not accepted (matching
    key, verdict REJECTED or BLOCK); only PRESENT is an ACCEPTED
    record; read-only, v1 has no write path
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
    push-reuse-decide) ci_push_reuse_decide "$@" ;;
    build-tools-channel) ci_build_tools_channel "$@" ;;
    build-tools-fallback-allowed) ci_build_tools_fallback_allowed "$@" ;;
    post-build-readback) ci_post_build_readback "$@" ;;
    attestation-state) ci_attestation_state "$@" ;;
    artifact-admission) ci_artifact_admission "$@" ;;
    ledger-encode-digest) ci_ledger_encode_digest "$@" ;;
    ledger-decode-digest) ci_ledger_decode_digest "$@" ;;
    ledger-ref) ci_ledger_ref "$@" ;;
    validate-ledger-record) ci_validate_ledger_record "$@" ;;
    ledger-read) ci_ledger_read "$@" ;;
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
