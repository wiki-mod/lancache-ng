#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Single authoritative CI 2.0 engine (skeleton).
# Why: All CI decisions live here, YAML only orchestrates.
# From: Issue #1683

set -euo pipefail

# =========================================================
# CONSTANTS / EXIT HANDLING
# =========================================================

# What: Absolute path of this script's directory.
# Why: Find the SOT manifest regardless of caller CWD.
# From: Issue #1683
CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# What: Path to the single source-of-truth build manifest.
# Why: One machine-readable owner for services and versions.
# From: Issue #1683
CI_MANIFEST="${CI_MANIFEST:-${CI_SCRIPT_DIR}/../yaml/build-manifest.yml}"

# What: Repository root (.github/scripts/../..).
# Why: Identity hashes git-tracked content from the root.
# From: Issue #1683
CI_REPO_ROOT="$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)"

# What: The known ci.sh subcommands (docs section 9 CLI).
# Why: One list drives dispatch and error text.
# From: Issue #1683
CI_COMMANDS="plan impact identity resolve build publish verify test scan assemble validate promote gc variables"

# =========================================================
# LOGGING
# =========================================================

# What: Emit one structured log line with a stable id.
# Why: Ids must be unique and greppable (Contract 52).
# From: Issue #1683
ci_log() {
    local message_id="$1"
    shift
    printf '%s %s\n' "${message_id}" "$*" >&2
}

# What: Emit a command failure with its raw output.
# Why: Command raw stderr MUST always show (Contract 55).
# From: Issue #1683
ci_error() {
    local message_id="$1" context="$2" raw="$3"
    ci_log "${message_id}" "${context}"
    printf 'raw:\n%s\n' "${raw}" >&2
}

# What: Report an unimplemented dispatch target.
# Why: Scaffold must fail closed, never silently succeed.
# From: Issue #1683
ci_not_implemented() {
    ci_log "[CI-ERROR-CORE-0001]" "command=$* state=SCAFFOLD reason=\"not yet implemented\""
    return 2
}

# What: Fail closed unless the SOT manifest exists.
# Why: Every real operation derives state from the manifest.
# From: Issue #1683
ci_require_manifest() {
    [ -f "${CI_MANIFEST}" ] && return 0
    ci_log "[CI-ERROR-CORE-0003]" "manifest=\"${CI_MANIFEST}\" reason=\"build manifest not found\""
    return 2
}

# =========================================================
# SERVICE INVENTORY
# =========================================================

# What: List direct child keys under a top-level block.
# Why: One awk reader, no yq/python (AG-REL-001/006).
# From: Issue #1683
_ci_block_keys() {
    local block="$1"
    awk -v block="$block" '
        $0 ~ ("^" block ":[[:space:]]*$") { inb = 1; next }
        inb && /^[^[:space:]]/ { inb = 0 }
        inb && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            key = $1; sub(/:$/, "", key); print key
        }
    ' "${CI_MANIFEST}"
}

# What: Print the 10 product-stack service names.
# Why: The one service list; everything derives from it.
# From: Issue #1683
ci_services() {
    _ci_block_keys "services"
}

# What: Print every build target (services + toolchain).
# Why: build-tools builds but is never a product service.
# From: Issue #1683
ci_build_targets() {
    ci_services
    _ci_block_keys "build_toolchain"
}

# =========================================================
# SEMANTIC PARSERS
# =========================================================

# What: Print one scalar field of a service entry.
# Why: Read build_type/runner/final_base without a copy.
# From: Issue #1683
ci_service_field() {
    local service="$1" field="$2"
    awk -v svc="$service" -v field="$field" '
        /^services:[[:space:]]*$/ { ins = 1; next }
        ins && /^[^[:space:]]/ { ins = 0 }
        ins && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); insvc = (cur == svc)
        }
        ins && insvc && $1 == (field ":") {
            val = $0; sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, "", val)
            print val; exit
        }
    ' "${CI_MANIFEST}"
}

# What: Print the named contexts a service rebuilds on.
# Why: dependency_graph is the SOT edge set (Finding 93).
# From: Issue #1683
ci_service_contexts() {
    local service="$1"
    awk -v svc="$service" '
        /^dependency_graph:[[:space:]]*$/ { ind = 1; next }
        ind && /^[^[:space:]]/ { ind = 0 }
        ind && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); insvc = (cur == svc); incx = 0
        }
        ind && insvc && /^    contexts:[[:space:]]*\[/ {
            line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            gsub(/[[:space:],]+/, " ", line)
            n = split(line, a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            exit
        }
    ' "${CI_MANIFEST}"
}

# What: Print a named context's path from named_contexts.
# Why: Map a context name to the repo path it covers.
# From: Issue #1683
ci_context_path() {
    local context="$1"
    awk -v ctx="$context" '
        /^named_contexts:[[:space:]]*$/ { inc = 1; next }
        inc && /^[^[:space:]]/ { inc = 0 }
        inc && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); inctx = (cur == ctx)
        }
        inc && inctx && $1 == "path:" {
            val = $0; sub(/^[[:space:]]*path:[[:space:]]*/, "", val)
            print val; exit
        }
    ' "${CI_MANIFEST}"
}

# =========================================================
# PLATFORMS
# =========================================================

# What: Print a target's own platforms override, if any.
# Why: A target may narrow the one authoritative list.
# From: Issue #1683
_ci_service_platforms_override() {
    local service="$1"
    awk -v svc="$service" '
        /^(services|build_toolchain):[[:space:]]*$/ { inb = 1; next }
        inb && /^[A-Za-z]/ { inb = 0 }
        inb && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); insvc = (cur == svc)
        }
        inb && insvc && /^    platforms:[[:space:]]*\[/ {
            line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            gsub(/[[:space:],]+/, " ", line)
            n = split(line, a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            exit
        }
    ' "${CI_MANIFEST}"
}

# What: Print the authoritative build_matrix platform list.
# Why: The one list every target defaults to.
# From: Issue #1683
_ci_build_matrix_platforms() {
    awk '
        /^build_matrix:[[:space:]]*$/ { inb = 1; next }
        inb && /^[A-Za-z]/ { inb = 0 }
        inb && /^  platforms:[[:space:]]*\[/ {
            line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            gsub(/[[:space:],]+/, " ", line)
            n = split(line, a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            exit
        }
    ' "${CI_MANIFEST}"
}

# What: Print a target's platforms, one per line.
# Why: build_matrix is authoritative; a target may override.
# From: Issue #1683
_ci_platforms() {
    local service="$1" out
    out="$(_ci_service_platforms_override "${service}")"
    [ -n "${out}" ] || out="$(_ci_build_matrix_platforms)"
    if [ -z "${out}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0003]" "service=\"${service}\" reason=\"no platforms in SOT (override or build_matrix)\""
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: True if a platform is in a target's platform set.
# Why: An unknown platform fails closed, never builds all.
# From: Issue #1683
_ci_valid_platform() {
    local service="$1" platform="$2" p
    while IFS= read -r p; do
        [ "${p}" = "${platform}" ] && return 0
    done < <(_ci_platforms "${service}")
    return 1
}

# What: Print the known arch-suffix aliases of a platform.
# Why: SOT mixes amd64/x86_64 and arm64/aarch64.
# From: Issue #1683
_ci_platform_arch_aliases() {
    case "$1" in
        */amd64|amd64) printf 'amd64 x86_64\n' ;;
        */arm64|arm64) printf 'arm64 aarch64\n' ;;
        *) printf '%s\n' "${1##*/}" ;;
    esac
}

# =========================================================
# IMPACT ENGINE
# =========================================================

# What: Read the changed-path list for this run.
# Why: CHANGED_FILES (file) or args; no hidden git walk.
# From: Issue #1683
_ci_changed_files() {
    if [ -n "${CHANGED_FILES:-}" ] && [ -f "${CHANGED_FILES}" ]; then
        cat -- "${CHANGED_FILES}"
        return 0
    fi
    printf '%s\n' "$@"
}

# What: True if any changed path is under a prefix.
# Why: Path membership only SELECTS a rebuild candidate.
# From: Issue #1683
_ci_paths_touch() {
    local prefix="$1"; shift
    local p
    for p in "$@"; do
        case "$p" in
            "${prefix}"|"${prefix}"/*) return 0 ;;
        esac
    done
    return 1
}

# What: Plan phase: pick rebuild CANDIDATES per service.
# Why: Path picks candidates; identity/CAS decides build.
# From: Issue #1683
ci_cmd_plan() {
    local -a changed=()
    while IFS= read -r line; do
        [ -n "${line}" ] && changed+=("${line}")
    done < <(_ci_changed_files "$@")

    local service context ctx_path candidate
    for service in $(ci_build_targets); do
        candidate="false"
        context="$(ci_service_field "${service}" context)"
        [ -z "${context}" ] && context="services/${service}"
        if _ci_paths_touch "${context}" "${changed[@]}"; then
            candidate="true"
        else
            for ctx in $(ci_service_contexts "${service}"); do
                ctx_path="$(ci_context_path "${ctx}")"
                [ -n "${ctx_path}" ] || continue
                if _ci_paths_touch "${ctx_path}" "${changed[@]}"; then
                    candidate="true"; break
                fi
            done
        fi
        printf '%s=%s\n' "${service}" "${candidate}"
    done
    ci_log "[CI-INFO-PLAN-0001]" "phase=plan changed=${#changed[@]} note=\"candidates only; identity/CAS decides build\""
}

# =========================================================
# IDENTITY ENGINE
# =========================================================

# What: Print a manifest top-level scalar (schema, etc.).
# Why: Identity mixes in pinned SOT values, one reader.
# From: Issue #1683
_ci_manifest_scalar() {
    local path_re="$1"
    awk -v re="$path_re" '$0 ~ re { val=$0; sub(/^[^:]*:[[:space:]]*/, "", val); print val; exit }' "${CI_MANIFEST}"
}

# What: True only for compiled sources, not copied.
# Why: Only compiled code has non-semantic comments.
# From: Issue #1683
_ci_source_is_normalizable() {
    case "$1" in
        *.rs) return 0 ;;
        *) return 1 ;;
    esac
}

# What: Hash a Rust source, comments and blanks cut.
# Why: A comment-only edit must not shift identity.
# From: Issue #1683
_ci_rust_content_hash() {
    tr -d '\r' \
        | awk '/^[[:space:]]*\/\// { next } /^[[:space:]]*$/ { next } { print }' \
        | sha256sum | cut -d' ' -f1
}

# What: Emit content ids of git-tracked files under a path.
# Why: Content, not raw bytes, is the build input.
# From: Issue #1683
_ci_tracked_content_ids() {
    local root="$1" listing line path meta oid norm
    listing="$( cd -- "${CI_REPO_ROOT}" && git ls-files -s -- "${root}" 2>/dev/null )" || return
    [ -n "${listing}" ] || return 0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        path="${line#*$'\t'}"
        if _ci_source_is_normalizable "${path}"; then
            meta="${line%%$'\t'*}"
            oid="${meta#* }"
            oid="${oid%% *}"
            norm="$( cd -- "${CI_REPO_ROOT}" && git cat-file blob "${oid}" 2>/dev/null | _ci_rust_content_hash )"
            printf '%s\t%s\n' "${path}" "${norm}"
        else
            printf '%s\n' "${line}"
        fi
    done <<< "${listing}"
}

# What: Print netdata's digest for exactly this platform.
# Why: Another arch's digest change must not shift this id.
# From: Issue #1683
_ci_install_digest_pin() {
    local platform="$1" arch re=""
    for arch in $(_ci_platform_arch_aliases "${platform}"); do
        re="${re:+${re}|}sha256_${arch}"
    done
    awk -v re="${re}" '
        /^external_versions:[[:space:]]*$/ { inev = 1; next }
        inev && /^[A-Za-z]/ { inev = 0 }
        inev && /^  netdata:[[:space:]]*$/ { nn = 1; next }
        inev && nn && /^  [A-Za-z]/ { nn = 0 }
        inev && nn && $1 ~ ("^(" re "):$") { print }
    ' "${CI_MANIFEST}"
}

# What: Print the SOT value a build type keys on.
# Why: apk keys base digest, install keys upstream digest.
# From: Issue #1683
_ci_identity_pins() {
    local service="$1" build_type="$2" platform="$3"
    case "${build_type}" in
        rust|toolchain)
            _ci_manifest_scalar "^  alpine:"
            grep -E '^(  build-tools:|    tag:|    image:)' "${CI_MANIFEST}" | head -3
            ;;
        apk)
            _ci_manifest_scalar "^  alpine:"
            if [ "${service}" = "syslog" ]; then
                _ci_manifest_scalar "^  fluent_bit:"
            fi
            ;;
        install)
            _ci_install_digest_pin "${platform}"
            ;;
    esac
}

# What: Print the bare id of one target+platform.
# Why: Platform mixed in so arches never collide.
# From: Issue #1683
_ci_identity_for() {
    local service="$1" platform="$2"
    local build_type context ctx ctx_path
    build_type="$(ci_service_field "${service}" build_type)"
    [ -n "${build_type}" ] || build_type="toolchain"
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    {
        printf 'service=%s\nbuild_type=%s\nplatform=%s\n' "${service}" "${build_type}" "${platform}"
        _ci_tracked_content_ids "${context}"
        for ctx in $(ci_service_contexts "${service}"); do
            ctx_path="$(ci_context_path "${ctx}")"
            [ -n "${ctx_path}" ] && _ci_tracked_content_ids "${ctx_path}"
        done
        _ci_identity_pins "${service}" "${build_type}" "${platform}"
    } | sha256sum | cut -d' ' -f1
}

# What: Print a target's id per platform, keyed.
# Why: Default = all platforms; one selectable.
# From: Issue #1683
ci_cmd_identity() {
    local service="${1:-}" platform="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-IDENTITY-0001]" "reason=\"service arg required\""; return 2; }
    local p
    if [ -n "${platform}" ]; then
        if ! _ci_valid_platform "${service}" "${platform}"; then
            ci_log "[CI-ERROR-IDENTITY-0002]" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""
            return 2
        fi
        printf 'platform=%s identity=%s\n' "${platform}" "$(_ci_identity_for "${service}" "${platform}")"
        return 0
    fi
    local plats
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        printf 'platform=%s identity=%s\n' "${p}" "$(_ci_identity_for "${service}" "${p}")"
    done <<< "${plats}"
}

# =========================================================
# ARTIFACT RESOLVER
# =========================================================

# What: Probe the acceptance/registry state for an identity.
# Why: Injectable so logic tests need no live GHCR.
# From: Issue #1683
_ci_resolve_probe() {
    local service="$1" identity="$2"
    if [ -n "${CI_RESOLVE_PROBE_CMD:-}" ]; then
        "${CI_RESOLVE_PROBE_CMD}" "${service}" "${identity}"
        return 0
    fi
    # What: no probe wired -> report UNKNOWN.
    # Why: unknown is not missing; never assume built.
    printf 'UNKNOWN\n'
}

# What: Map a resolver state to its one action.
# Why: DEFAULT=NOOP; UNKNOWN escalates, never builds.
# From: Issue #1683
_ci_resolve_action() {
    case "$1" in
        PRESENT_ACCEPTED)   printf 'noop\n' ;;
        MISSING_CONFIRMED)  printf 'build\n' ;;
        MISMATCH)           printf 'build\n' ;;
        PRODUCED_UNVERIFIED) printf 'verify\n' ;;
        BUILD_IN_PROGRESS)  printf 'wait\n' ;;
        *)                  printf 'escalate\n' ;;
    esac
}

# What: Resolve one target+platform to a state + action.
# Why: NOOP/reuse decided per platform first.
# From: Issue #1683
_ci_resolve_one() {
    local service="$1" platform="$2"
    local identity state action
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    state="$(_ci_resolve_probe "${service}" "${identity}")"
    case "${state}" in
        PRESENT_ACCEPTED|MISSING_CONFIRMED|MISMATCH|PRODUCED_UNVERIFIED|BUILD_IN_PROGRESS|UNKNOWN) ;;
        *)
            ci_log "[CI-ERROR-RESOLVE-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"probe returned unknown state\" got=\"${state}\""
            state="UNKNOWN"
            ;;
    esac
    action="$(_ci_resolve_action "${state}")"
    printf 'service=%s platform=%s state=%s action=%s identity=%s\n' "${service}" "${platform}" "${state}" "${action}" "${identity}"
    if [ "${state}" = "UNKNOWN" ]; then
        ci_log "[CI-INFO-RESOLVE-0003]" "service=\"${service}\" platform=\"${platform}\" state=UNKNOWN note=\"escalate; UNKNOWN is never treated as build-needed\""
    fi
}

# What: Resolve a target per platform.
# Why: Default = all platforms; one selectable.
# From: Issue #1683
ci_cmd_resolve() {
    local service="${1:-}" platform="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RESOLVE-0001]" "reason=\"service arg required\""; return 2; }
    local p
    if [ -n "${platform}" ]; then
        if ! _ci_valid_platform "${service}" "${platform}"; then
            ci_log "[CI-ERROR-RESOLVE-0004]" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""
            return 2
        fi
        _ci_resolve_one "${service}" "${platform}"
        return "$?"
    fi
    local plats
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        _ci_resolve_one "${service}" "${p}" || return "$?"
    done <<< "${plats}"
}

# =========================================================
# ACCEPTANCE INDEX
# =========================================================

# =========================================================
# RETRY CLASSIFIER
# =========================================================

# What: Classify a failure as transient or permanent (§67).
# Why: One rule replaces 5+ retry wrappers' own splits.
# From: Issue #1683
_ci_classify_failure() {
    local raw="$1"
    # What: auth/malformed/compile are permanent.
    # Why: retrying a fixed outcome wastes budget.
    case "${raw}" in
        *"HTTP 401"*|*"unauthorized"*|*"denied: requested access"*) printf 'permanent\n'; return 0 ;;
        *"HTTP 400"*|*"HTTP 422"*|*"invalid reference format"*) printf 'permanent\n'; return 0 ;;
        *"pull access denied"*|*"manifest unknown"*|*"not found: manifest"*) printf 'permanent\n'; return 0 ;;
        *"error: could not compile"*|*"Dockerfile parse error"*|*"failed to solve"*"parse"*) printf 'permanent\n'; return 0 ;;
    esac
    # What: rate-limit/5xx/network are transient.
    # Why: these recover on a retry with backoff.
    case "${raw}" in
        *"HTTP 403"*|*"HTTP 429"*|*"toomanyrequests"*|*"rate limit"*) printf 'transient\n'; return 0 ;;
        *"HTTP 5"[0-9][0-9]*|*"i/o timeout"*|*"connection refused"*|*"TLS handshake timeout"*) printf 'transient\n'; return 0 ;;
        *"EOF"*|*"connection reset by peer"*|*"temporary failure"*) printf 'transient\n'; return 0 ;;
    esac
    # What: an unclassified failure is transient.
    # Why: a missed transient is worse than a retry.
    printf 'transient\n'
}

# =========================================================
# CACHE CONFIGURATION
# =========================================================

# What: Print the reuse order, cheapest first (§7).
# Why: Maximal caching never means build is preferred.
# From: Issue #1683
ci_reuse_order() {
    printf 'noop accepted binary_cas build_cache compiler_cache compile\n'
}

# =========================================================
# BUILD ENGINE
# =========================================================

# What: Fail unless GHCR credentials are present.
# Why: Every GHCR action authenticates, never anonymous.
# From: Issue #1683
_ci_require_ghcr_auth() {
    [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] && return 0
    ci_log "[CI-ERROR-BUILD-0002]" "reason=\"GHCR credentials required; anonymous is rate-limited\""
    return 2
}

# What: Look up a prebuilt binary in the compiled CAS.
# Why: Reuse an identical binary before compiling (§7).
# From: Issue #1683
_ci_cas_lookup() {
    local identity="$1"
    if [ -n "${CI_CAS_LOOKUP_CMD:-}" ]; then
        "${CI_CAS_LOOKUP_CMD}" "${identity}"
        return "$?"
    fi
    return 1
}

# What: Run the real (or injected) image build+push.
# Why: Injectable so build logic tests without Docker.
# From: Issue #1683
_ci_do_build() {
    local service="$1" identity="$2" platform="$3"
    if [ -n "${CI_BUILD_CMD:-}" ]; then
        "${CI_BUILD_CMD}" "${service}" "${identity}" "${platform}"
        return "$?"
    fi
    ci_log "[CI-ERROR-BUILD-0003]" "service=\"${service}\" reason=\"no build backend wired (CI_BUILD_CMD unset)\""
    return 2
}

# What: Build one target+platform, honoring resolve + reuse.
# Why: NOOP/reuse/CAS precede compile; UNKNOWN never builds.
# From: Issue #1683
_ci_build_one() {
    local service="$1" platform="$2"
    local resolved action identity build_type
    resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
    action="${resolved#*action=}"; action="${action%% *}"
    identity="${resolved#*identity=}"; identity="${identity%% *}"
    build_type="$(ci_service_field "${service}" build_type)"

    case "${action}" in
        noop)
            printf 'service=%s platform=%s result=reuse-accepted identity=%s\n' "${service}" "${platform}" "${identity}"
            return 0
            ;;
        escalate|wait|verify)
            ci_log "[CI-INFO-BUILD-0004]" "service=\"${service}\" platform=\"${platform}\" action=\"${action}\" note=\"not building; resolve action is not build\""
            printf 'service=%s platform=%s result=%s identity=%s\n' "${service}" "${platform}" "${action}" "${identity}"
            [ "${action}" = "escalate" ] && return 2 || return 0
            ;;
        build) ;;
        *)
            ci_log "[CI-ERROR-BUILD-0005]" "service=\"${service}\" platform=\"${platform}\" reason=\"unrecognized resolve action\" got=\"${action}\""
            return 2
            ;;
    esac

    # What: reuse a CAS binary before compiling.
    # Why: an identical binary need not rebuild.
    if [ "${build_type}" = "rust" ] && _ci_cas_lookup "${identity}" >/dev/null 2>&1; then
        printf 'service=%s platform=%s result=reuse-binary-cas identity=%s\n' "${service}" "${platform}" "${identity}"
        return 0
    fi

    _ci_require_ghcr_auth || return "$?"
    _ci_do_build "${service}" "${identity}" "${platform}" || return "$?"
    printf 'service=%s platform=%s result=built identity=%s\n' "${service}" "${platform}" "${identity}"
}

# What: Build a target per platform.
# Why: Default = all platforms; one selectable.
# From: Issue #1683
ci_cmd_build() {
    local service="${1:-}" platform="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-BUILD-0001]" "reason=\"service arg required\""; return 2; }
    local p
    if [ -n "${platform}" ]; then
        if ! _ci_valid_platform "${service}" "${platform}"; then
            ci_log "[CI-ERROR-BUILD-0006]" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""
            return 2
        fi
        _ci_build_one "${service}" "${platform}"
        return "$?"
    fi
    local plats
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        _ci_build_one "${service}" "${p}" || return "$?"
    done <<< "${plats}"
}

# =========================================================
# VERIFY / TEST / SCAN
# =========================================================

# What: Publish one target+platform to its per-identity ref.
# Why: Publish is authenticated and injectable for tests.
# From: Issue #1683
_ci_publish_one() {
    local service="$1" platform="$2"
    local identity digest
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    if [ -z "${CI_PUBLISH_CMD:-}" ]; then
        ci_log "[CI-ERROR-PUBLISH-0003]" "service=\"${service}\" reason=\"no publish backend wired (CI_PUBLISH_CMD unset)\""
        return 2
    fi
    if ! digest="$("${CI_PUBLISH_CMD}" "${service}" "${identity}" "${platform}")"; then
        ci_log "[CI-ERROR-PUBLISH-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"publish backend failed\""
        return 2
    fi
    printf 'service=%s platform=%s published=%s identity=%s\n' "${service}" "${platform}" "${digest}" "${identity}"
}

# What: Publish a target per platform.
# Why: Default = all platforms; one selectable.
# From: Issue #1683
ci_cmd_publish() {
    local service="${1:-}" platform="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-PUBLISH-0001]" "reason=\"service arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local p
    if [ -n "${platform}" ]; then
        if ! _ci_valid_platform "${service}" "${platform}"; then
            ci_log "[CI-ERROR-PUBLISH-0004]" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""
            return 2
        fi
        _ci_publish_one "${service}" "${platform}"
        return "$?"
    fi
    local plats
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        _ci_publish_one "${service}" "${p}" || return "$?"
    done <<< "${plats}"
}

# What: Read a published ref back and confirm its digest.
# Why: BUILT != ACCEPTED; a MISMATCH must fail (§7).
# From: Issue #1683
ci_cmd_verify() {
    local service="${1:-}" expected="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-VERIFY-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${expected}" ] || { ci_log "[CI-ERROR-VERIFY-0002]" "reason=\"expected digest arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local seen
    if [ -n "${CI_READBACK_CMD:-}" ]; then
        seen="$("${CI_READBACK_CMD}" "${service}")" || {
            ci_log "[CI-ERROR-VERIFY-0003]" "service=\"${service}\" reason=\"readback failed\""
            return 2
        }
    else
        ci_log "[CI-ERROR-VERIFY-0004]" "service=\"${service}\" reason=\"no readback backend wired (CI_READBACK_CMD unset)\""
        return 2
    fi
    if [ "${seen}" != "${expected}" ]; then
        ci_error "[CI-ERROR-VERIFY-0005]" "service=\"${service}\" reason=\"digest MISMATCH; produced != accepted\" expected=\"${expected}\"" "readback=${seen}"
        return 2
    fi
    printf 'service=%s verified=%s\n' "${service}" "${seen}"
}

# What: Run a service's tests via an injectable backend.
# Why: A failed test run is a failed run, never skipped.
# From: Issue #1683
ci_cmd_test() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-TEST-0001]" "reason=\"service arg required\""; return 2; }
    if [ -z "${CI_TEST_CMD:-}" ]; then
        ci_log "[CI-ERROR-TEST-0002]" "service=\"${service}\" reason=\"no test backend wired (CI_TEST_CMD unset)\""
        return 2
    fi
    local raw status
    if raw="$("${CI_TEST_CMD}" "${service}" 2>&1)"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-TEST-0003]" "service=\"${service}\" reason=\"tests failed\" retry=$(_ci_classify_failure "${raw}")" "${raw}"
        return 2
    fi
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Scan a published digest for vulnerabilities.
# Why: /var/tmp staging (no tmpfs OOM), authed, fail-closed.
# From: Issue #1683
ci_cmd_scan() {
    local service="${1:-}" digest="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-SCAN-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${digest}" ] || { ci_log "[CI-ERROR-SCAN-0002]" "reason=\"digest arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    # What: stage scans under /var/tmp.
    # Why: /tmp is tmpfs; large exports risk OOM.
    local scan_tmp="${CI_TMPDIR:-/var/tmp}"
    case "${scan_tmp}" in
        /var/tmp|/var/tmp/*) ;;
        *) ci_log "[CI-ERROR-SCAN-0003]" "reason=\"scan TMPDIR must be under /var/tmp, not tmpfs /tmp\" got=\"${scan_tmp}\""; return 2 ;;
    esac
    if [ -z "${CI_SCAN_CMD:-}" ]; then
        ci_log "[CI-ERROR-SCAN-0004]" "service=\"${service}\" reason=\"no scan backend wired (CI_SCAN_CMD unset)\""
        return 2
    fi
    local raw status
    if raw="$(TMPDIR="${scan_tmp}" "${CI_SCAN_CMD}" "${service}" "${digest}" 2>&1)"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-SCAN-0005]" "service=\"${service}\" reason=\"scan reported findings or failed\" retry=$(_ci_classify_failure "${raw}")" "${raw}"
        return 2
    fi
    printf 'service=%s scanned=clean digest=%s tmpdir=%s\n' "${service}" "${digest}" "${scan_tmp}"
}

# =========================================================
# ASSEMBLY
# =========================================================

# What: Look up an ACCEPTED per-platform digest.
# Why: The digest source is the ledger; testable without it.
# From: Issue #1683
_ci_accepted_digest() {
    local service="$1" platform="$2"
    if [ -n "${CI_ACCEPTED_DIGEST_CMD:-}" ]; then
        "${CI_ACCEPTED_DIGEST_CMD}" "${service}" "${platform}"
        return "$?"
    fi
    return 1
}

# What: Look up an existing multi-arch index (injectable).
# Why: Idempotency: reuse an identical index.
# From: Issue #1683
_ci_index_lookup() {
    local service="$1"
    if [ -n "${CI_INDEX_LOOKUP_CMD:-}" ]; then
        "${CI_INDEX_LOOKUP_CMD}" "${service}"
        return "$?"
    fi
    return 1
}

# What: Collect a target's accepted per-platform digests.
# Why: A non-accepted platform blocks assembly, no rebuild.
# From: Issue #1683
_ci_collect_accepted_digests() {
    local service="$1" plats p line state digest
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        line="$(_ci_resolve_one "${service}" "${p}")" || return "$?"
        state="${line#*state=}"; state="${state%% *}"
        if [ "${state}" != "PRESENT_ACCEPTED" ]; then
            ci_error "[CI-ERROR-ASSEMBLE-0002]" "service=\"${service}\" platform=\"${p}\" reason=\"platform not ACCEPTED; not assembling, not rebuilding\" state=\"${state}\"" "resolve: ${line}"
            return 2
        fi
        if ! digest="$(_ci_accepted_digest "${service}" "${p}")"; then
            ci_log "[CI-ERROR-ASSEMBLE-0003]" "service=\"${service}\" platform=\"${p}\" reason=\"no accepted digest for an ACCEPTED platform\""
            return 2
        fi
        printf '%s=%s\n' "${p}" "${digest}"
    done <<< "${plats}"
}

# What: Reuse an identical index or reject a divergent one.
# Why: Idempotent retry; never overwrite an index.
# From: Issue #1683
_ci_reconcile_index() {
    local service="$1" want="$2" existing ex_digest ex_have
    existing="$(_ci_index_lookup "${service}")" || return 0
    ex_digest="${existing%% *}"
    ex_have="$(printf '%s\n' ${existing#* } | sort | tr '\n' ' ')"
    if [ "${want}" = "${ex_have}" ]; then
        printf '%s\n' "${ex_digest}"
        return 0
    fi
    ci_error "[CI-ERROR-ASSEMBLE-0004]" "service=\"${service}\" reason=\"existing index has different platform digests; refusing to overwrite\" existing=\"${ex_digest}\"" "existing: ${existing#* }"
    return 2
}

# What: Assemble accepted per-platform digests.
# Why: Index only when every platform is ACCEPTED.
# From: Issue #1683
ci_cmd_assemble() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-ASSEMBLE-0001]" "reason=\"service arg required\""; return 2; }
    local inputs want count reused index
    inputs="$(_ci_collect_accepted_digests "${service}")" || return "$?"
    want="$(printf '%s\n' ${inputs} | sort | tr '\n' ' ')"
    count="$(printf '%s\n' ${inputs} | grep -c '=')"
    if ! reused="$(_ci_reconcile_index "${service}" "${want}")"; then
        return 2
    fi
    if [ -n "${reused}" ]; then
        printf 'service=%s result=reuse-index assembled=%s platforms=%s\n' "${service}" "${reused}" "${count}"
        return 0
    fi
    _ci_require_ghcr_auth || return "$?"
    if [ -z "${CI_ASSEMBLE_CMD:-}" ]; then
        ci_log "[CI-ERROR-ASSEMBLE-0006]" "service=\"${service}\" reason=\"no assemble backend wired (CI_ASSEMBLE_CMD unset)\""
        return 2
    fi
    if ! index="$("${CI_ASSEMBLE_CMD}" "${service}" ${inputs})"; then
        ci_log "[CI-ERROR-ASSEMBLE-0005]" "service=\"${service}\" reason=\"assemble backend failed\""
        return 2
    fi
    printf 'service=%s result=assembled assembled=%s platforms=%s\n' "${service}" "${index}" "${count}"
}

# =========================================================
# PROMOTION
# =========================================================

# What: Print the SOT's mutable release channels.
# Why: One channel list; promote never invents a second.
# From: Issue #1683
_ci_mutable_channels() {
    awk '
        /^release:[[:space:]]*$/ { inr = 1; next }
        inr && /^[A-Za-z]/ { inr = 0; inc = 0 }
        inr && /^  channels:[[:space:]]*$/ { inc = 1; next }
        inr && inc && /^  [A-Za-z]/ { inc = 0 }
        inc && /^    [A-Za-z0-9_.-]+:[[:space:]]*$/ { ch = $1; sub(/:$/, "", ch); next }
        inc && ch != "" && /^      mutable:[[:space:]]*true[[:space:]]*$/ { print ch; ch = "" }
    ' "${CI_MANIFEST}"
}

# What: True if a channel is a known mutable channel.
# Why: promote moves mutable refs only (docs section 51).
# From: Issue #1683
_ci_valid_channel() {
    local channel="$1" c
    while IFS= read -r c; do
        [ "${c}" = "${channel}" ] && return 0
    done < <(_ci_mutable_channels)
    return 1
}

# What: Read the accepted stack candidate (injectable).
# Why: consumes a candidate; no ledger to test it.
# From: Issue #1683
_ci_stack_candidate() {
    if [ -n "${CI_STACK_CANDIDATE_CMD:-}" ]; then
        "${CI_STACK_CANDIDATE_CMD}"
        return "$?"
    fi
    return 1
}

# What: True only if the stack validated (docs section 50).
# Why: Fail-closed without validate; never assume success.
# From: Issue #1683
_ci_stack_validated() {
    [ "${CI_STACK_VALIDATED:-}" = "SUCCESS" ]
}

# What: Move every candidate ref and read each back.
# Why: One locked section; the caller always unlocks.
# From: Issue #1683
_ci_promote_move_all() {
    local channel="$1" cand="$2" line svc digest seen
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; digest="${line#*=}"
        if ! "${CI_PROMOTE_MOVE_CMD}" "${svc}" "${channel}" "${digest}"; then
            ci_log "[CI-ERROR-PROMOTE-0007]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel ref move failed\""
            return 2
        fi
        seen="$("${CI_CHANNEL_READBACK_CMD}" "${svc}" "${channel}")" || seen=""
        if [ -z "${seen}" ]; then
            ci_log "[CI-ERROR-PROMOTE-0008]" "service=\"${svc}\" channel=\"${channel}\" reason=\"readback unknown; blocking\""
            return 2
        fi
        if [ "${seen}" != "${digest}" ]; then
            ci_error "[CI-ERROR-PROMOTE-0009]" "service=\"${svc}\" channel=\"${channel}\" reason=\"readback MISMATCH; failing closed, not rolling back\" expected=\"${digest}\"" "readback=${seen}"
            return 2
        fi
    done <<< "${cand}"
}

# What: True if the candidate holds every product service.
# Why: Promotion is stack-atomic; 8/9 does not promote.
# From: Issue #1683
_ci_promote_stack_complete() {
    local channel="$1" cand="$2" svcs svc
    svcs="$(ci_services)" || return "$?"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        if ! printf '%s\n' "${cand}" | grep -q "^${svc}="; then
            ci_log "[CI-ERROR-PROMOTE-0004]" "channel=\"${channel}\" service=\"${svc}\" reason=\"incomplete stack; no promotion (docs section 50)\""
            return 2
        fi
    done <<< "${svcs}"
}

# What: True if every ref already points at its digest.
# Why: An idempotent re-run needs no lock or move.
# From: Issue #1683
_ci_promote_all_current() {
    local channel="$1" cand="$2" line svc digest seen
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; digest="${line#*=}"
        seen="$("${CI_CHANNEL_READBACK_CMD}" "${svc}" "${channel}")" || seen=""
        [ "${seen}" = "${digest}" ] || return 1
    done <<< "${cand}"
}

# What: Atomically move a channel to an accepted stack.
# Why: Stack-atomic; moves refs only, never builds.
# From: Issue #1683
ci_cmd_promote() {
    local channel="${1:-}"
    [ -n "${channel}" ] || { ci_log "[CI-ERROR-PROMOTE-0001]" "reason=\"channel arg required\""; return 2; }
    if ! _ci_valid_channel "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0002]" "channel=\"${channel}\" reason=\"not a known mutable release channel\""
        return 2
    fi
    local cand
    if ! cand="$(_ci_stack_candidate)"; then
        ci_log "[CI-ERROR-PROMOTE-0003]" "channel=\"${channel}\" reason=\"no accepted stack candidate\""
        return 2
    fi
    _ci_promote_stack_complete "${channel}" "${cand}" || return "$?"
    if ! _ci_stack_validated; then
        ci_log "[CI-ERROR-PROMOTE-0005]" "channel=\"${channel}\" reason=\"stack not validated; promotion blocked\""
        return 2
    fi
    _ci_require_ghcr_auth || return "$?"
    if [ -z "${CI_PROMOTE_LOCK_CMD:-}" ] || [ -z "${CI_PROMOTE_UNLOCK_CMD:-}" ] || \
       [ -z "${CI_PROMOTE_MOVE_CMD:-}" ] || [ -z "${CI_CHANNEL_READBACK_CMD:-}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0006]" "channel=\"${channel}\" reason=\"promote backends not wired\""
        return 2
    fi
    if _ci_promote_all_current "${channel}" "${cand}"; then
        printf 'channel=%s result=already-promoted services=%s\n' "${channel}" "$(printf '%s\n' "${cand}" | grep -c '=')"
        return 0
    fi
    if ! "${CI_PROMOTE_LOCK_CMD}" "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0010]" "channel=\"${channel}\" reason=\"could not acquire promotion lock\""
        return 2
    fi
    # What: capture rc so the unlock still runs on failure.
    # Why: a failed move must never leak the promotion lock.
    local rc
    if _ci_promote_move_all "${channel}" "${cand}"; then rc=0; else rc=$?; fi
    "${CI_PROMOTE_UNLOCK_CMD}" "${channel}" || ci_log "[CI-WARN-PROMOTE-0011]" "channel=\"${channel}\" reason=\"lock release failed\""
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf 'channel=%s result=promoted services=%s\n' "${channel}" "$(printf '%s\n' "${cand}" | grep -c '=')"
}

# =========================================================
# NIGHTLY / RELEASE
# =========================================================

# =========================================================
# GC
# =========================================================

# What: Read the SOT artifact deletion policy value.
# Why: Default is dry-run unless policy allows automation.
# From: Issue #1683
_ci_deletion_policy() {
    _ci_manifest_scalar '^[[:space:]]+deletion_policy:[[:space:]]'
}

# What: List protected GC roots (injectable backend).
# Why: Empty roots must fail, not mark all unreachable.
# From: Issue #1683
_ci_gc_roots() {
    if [ -n "${CI_GC_ROOTS_CMD:-}" ]; then
        "${CI_GC_ROOTS_CMD}"
        return "$?"
    fi
    ci_log "[CI-ERROR-GC-0001]" "reason=\"no roots backend wired (CI_GC_ROOTS_CMD unset)\""
    return 2
}

# What: List GC candidate artifacts (injectable backend).
# Why: SQLite only suggests; it never deletes (§97).
# From: Issue #1683
_ci_gc_candidates() {
    if [ -n "${CI_GC_CANDIDATES_CMD:-}" ]; then
        "${CI_GC_CANDIDATES_CMD}"
        return "$?"
    fi
    ci_log "[CI-ERROR-GC-0002]" "reason=\"no candidate source wired (CI_GC_CANDIDATES_CMD unset)\""
    return 2
}

# What: Probe one candidate against the OCI ref graph.
# Why: Registry truth, not SQLite, decides reachability.
# From: Issue #1683
_ci_gc_reachable() {
    local candidate="$1"
    if [ -n "${CI_GC_REACHABLE_CMD:-}" ]; then
        "${CI_GC_REACHABLE_CMD}" "${candidate}"
        return "$?"
    fi
    ci_log "[CI-ERROR-GC-0003]" "candidate=\"${candidate}\" reason=\"no reachability backend wired (CI_GC_REACHABLE_CMD unset)\""
    return 2
}

# What: Classify one candidate KEEP / DELETE / fail.
# Why: UNKNOWN never deletes and never silently keeps.
# From: Issue #1683
_ci_gc_classify() {
    local candidate="$1" verdict
    if ! verdict="$(_ci_gc_reachable "${candidate}")"; then
        ci_log "[CI-ERROR-GC-0004]" "candidate=\"${candidate}\" reason=\"reachability probe failed\""
        return 2
    fi
    case "${verdict}" in
        referenced) printf 'KEEP\n' ;;
        unreachable) printf 'DELETE\n' ;;
        *)
            ci_log "[CI-ERROR-GC-0005]" "candidate=\"${candidate}\" verdict=\"${verdict}\" reason=\"unknown reachability; fix probe, never delete or keep\""
            return 2
            ;;
    esac
}

# What: Classify GC candidates; delete only when applied.
# Why: Repo-wide reachability is the named §98 exception.
# From: Issue #1683
ci_cmd_gc() {
    local mode="dry-run" arg roots cands line action policy
    local del=0 keep=0 deleted=0 to_delete=""
    for arg in "$@"; do
        case "${arg}" in
            --apply) mode="apply" ;;
            *)
                ci_log "[CI-ERROR-GC-0006]" "arg=\"${arg}\" reason=\"unknown gc argument\""
                return 2
                ;;
        esac
    done
    if ! roots="$(_ci_gc_roots)"; then return 2; fi
    if [ -z "${roots}" ]; then
        ci_log "[CI-ERROR-GC-0007]" "reason=\"empty protected-roots set; refusing to treat all as unreachable\""
        return 2
    fi
    if ! cands="$(_ci_gc_candidates)"; then return 2; fi
    if [ -z "${cands}" ]; then
        printf 'gc result=noop candidates=0 mode=%s\n' "${mode}"
        return 0
    fi
    if [ "${mode}" = "apply" ]; then
        policy="$(_ci_deletion_policy)"
        case "${policy}" in
            # What: Exact allow-list, not substring match.
            # Why: A negated policy must not pass the gate.
            # From: Issue #1683
            manual-or-approved-automation-only) : ;;
            *)
                ci_log "[CI-ERROR-GC-0008]" "policy=\"${policy}\" reason=\"deletion policy forbids automated delete\""
                return 2
                ;;
        esac
        _ci_require_ghcr_auth || return 2
        if [ -z "${CI_GC_DELETE_CMD:-}" ]; then
            ci_log "[CI-ERROR-GC-0010]" "reason=\"apply mode but no delete backend (CI_GC_DELETE_CMD unset)\""
            return 2
        fi
    fi
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        if ! action="$(_ci_gc_classify "${line}")"; then return 2; fi
        if [ "${action}" = "DELETE" ]; then
            del=$((del + 1))
            to_delete="${to_delete}${line}"$'\n'
            printf 'gc candidate=%s action=DELETE mode=%s\n' "${line}" "${mode}"
        else
            keep=$((keep + 1))
            printf 'gc candidate=%s action=KEEP\n' "${line}"
        fi
    done <<< "${cands}"
    if [ "${mode}" = "apply" ] && [ -n "${to_delete}" ]; then
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            # What: Re-check reachability before delete.
            # Why: Re-check closes a TOCTOU delete gap.
            # From: Issue #1683
            if ! action="$(_ci_gc_classify "${line}")"; then return 2; fi
            if [ "${action}" != "DELETE" ]; then
                ci_log "[CI-INFO-GC-0011]" "candidate=\"${line}\" reason=\"referenced at delete time; skipped\""
                continue
            fi
            if ! "${CI_GC_DELETE_CMD}" "${line}"; then
                ci_log "[CI-ERROR-GC-0009]" "candidate=\"${line}\" reason=\"delete backend failed\""
                return 2
            fi
            deleted=$((deleted + 1))
        done <<< "${to_delete}"
    fi
    printf 'gc result=classified keep=%s delete=%s deleted=%s mode=%s\n' "${keep}" "${del}" "${deleted}" "${mode}"
    return 0
}

# =========================================================
# VALIDATION
# =========================================================

# What: Run the full-setup stack validation (injectable).
# Why: Testable without a live compose stack or Docker.
# From: Issue #1683
_ci_validate_run() {
    local cand="$1" raw status
    if [ -z "${CI_VALIDATE_CMD:-}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0003]" "reason=\"no validation backend wired (CI_VALIDATE_CMD unset)\""
        return 2
    fi
    if raw="$("${CI_VALIDATE_CMD}" "${cand}")"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-VALIDATE-0004]" "reason=\"stack validation failed\"" "${raw}"
        return "${status}"
    fi
    printf 'validate result=STACK_ACCEPTED\n'
}

# What: Validate the accepted stack candidate end to end.
# Why: promote needs a validated stack first (§49/§50).
# From: Issue #1683
ci_cmd_validate() {
    local cand
    if ! cand="$(_ci_stack_candidate)"; then
        ci_log "[CI-ERROR-VALIDATE-0001]" "reason=\"no stack candidate (CI_STACK_CANDIDATE_CMD unset/failed)\""
        return 2
    fi
    if [ -z "${cand}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0002]" "reason=\"empty stack candidate\""
        return 2
    fi
    _ci_require_ghcr_auth || return 2
    _ci_validate_run "${cand}"
}

# =========================================================
# VARIABLES
# =========================================================

# What: Read a CI variable: env override or SOT default.
# Why: One rule, no hardcode (AG-CI-006, CARGO_BUILD_JOBS).
# From: Issue #1683
_ci_variable() {
    local name="$1" val
    if [ -z "${name}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0003]" "reason=\"no variable name given\""
        return 2
    fi
    val="${!name:-}"
    if [ -n "${val}" ]; then printf '%s\n' "${val}"; return 0; fi
    val="$(_ci_manifest_scalar "^  ${name}:[[:space:]]")"
    if [ -n "${val}" ]; then printf '%s\n' "${val}"; return 0; fi
    ci_log "[CI-ERROR-VARIABLES-0001]" "name=\"${name}\" reason=\"no env value and no SOT fallback\""
    return 2
}

# What: Print one CI variable value for callers.
# Why: Workflows read values via ci.sh, no second source.
# From: Issue #1683
ci_cmd_variables() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        get) _ci_variable "${1:-}" ;;
        *)
            ci_log "[CI-ERROR-VARIABLES-0002]" "sub=\"${sub}\" reason=\"unknown variables subcommand\""
            return 2
            ;;
    esac
}

# =========================================================
# DISPATCH
# =========================================================

# What: Route a subcommand to its engine function.
# Why: One-list membership avoids a duplicate list.
# From: Issue #1683
ci_main() {
    local command="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case " ${CI_COMMANDS} " in
        *" ${command} "*)
            ci_require_manifest || return "$?"
            case "${command}" in
                plan) ci_cmd_plan "$@" ;;
                identity) ci_cmd_identity "$@" ;;
                resolve) ci_cmd_resolve "$@" ;;
                build) ci_cmd_build "$@" ;;
                publish) ci_cmd_publish "$@" ;;
                verify) ci_cmd_verify "$@" ;;
                test) ci_cmd_test "$@" ;;
                scan) ci_cmd_scan "$@" ;;
                assemble) ci_cmd_assemble "$@" ;;
                validate) ci_cmd_validate "$@" ;;
                promote) ci_cmd_promote "$@" ;;
                gc) ci_cmd_gc "$@" ;;
                variables) ci_cmd_variables "$@" ;;
                *) ci_not_implemented "${command}" "$@" ;;
            esac
            ;;
        *)
            ci_log "[CI-ERROR-CORE-0002]" "command=\"${command}\" reason=\"unknown subcommand\" known=\"${CI_COMMANDS}\""
            return 2
            ;;
    esac
}

# What: Run the dispatcher only on direct execution.
# Why: Lets ci.bats source the functions to test them.
# From: Issue #1683
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ci_main "$@"
fi
