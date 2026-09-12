#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Single authoritative CI 2.0 engine (skeleton).
# Why: All CI decisions live here, YAML only orchestrates.
# From: Issue #1683

set -euo pipefail

# ============================================================
# CONSTANTS / EXIT HANDLING
# ============================================================

# What: Absolute path of this script's directory.
# Why: Find the SOT manifest regardless of caller CWD.
# From: Issue #1683
CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# What: Path to the single source-of-truth build manifest.
# Why: One machine-readable owner for services and versions.
# From: Issue #1683
CI_MANIFEST="${CI_SCRIPT_DIR}/../yaml/build-manifest.yml"

# What: Repository root (.github/scripts/../..).
# Why: Identity hashes git-tracked content from the root.
# From: Issue #1683
CI_REPO_ROOT="$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)"

# What: The known ci.sh subcommands (docs section 9 CLI).
# Why: One list drives dispatch and error text.
# From: Issue #1683
CI_COMMANDS="plan impact identity resolve build publish verify test scan assemble validate promote gc variables"

# ============================================================
# LOGGING
# ============================================================

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

# ============================================================
# SERVICE INVENTORY
# ============================================================

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

# ============================================================
# SEMANTIC PARSERS
# ============================================================

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

# ============================================================
# IMPACT ENGINE
# ============================================================

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

# ============================================================
# IDENTITY ENGINE
# ============================================================

# What: Print a manifest top-level scalar (schema, etc.).
# Why: Identity mixes in pinned SOT values, one reader.
# From: Issue #1683
_ci_manifest_scalar() {
    local path_re="$1"
    awk -v re="$path_re" '$0 ~ re { val=$0; sub(/^[^:]*:[[:space:]]*/, "", val); print val; exit }' "${CI_MANIFEST}"
}

# What: Emit content ids of git-tracked files under a path.
# Why: Content hash, not path-touch, is the build input.
# From: Issue #1683
_ci_tracked_content_ids() {
    local root="$1"
    ( cd -- "${CI_REPO_ROOT}" && git ls-files -s -- "${root}" 2>/dev/null )
}

# What: Print the SOT value a build type keys on.
# Why: apk keys base digest, install keys upstream digest.
# From: Issue #1683
_ci_identity_pins() {
    local service="$1" build_type="$2"
    case "${build_type}" in
        rust|toolchain)
            _ci_manifest_scalar "^  alpine:"
            grep -E '^(  build-tools:|    tag:|    image:)' "${CI_MANIFEST}" | head -3
            ;;
        apk)
            _ci_manifest_scalar "^  alpine:"
            [ "${service}" = "syslog" ] && _ci_manifest_scalar "^  fluent_bit:"
            ;;
        install)
            awk '/^  netdata:/{n=1} n&&/sha256/{print} n&&/^  [a-z]/&&!/netdata/{exit}' "${CI_MANIFEST}"
            ;;
    esac
}

# What: Print a deterministic content-identity for a target.
# Why: Same inputs -> same id -> NOOP/reuse first.
# From: Issue #1683
ci_cmd_identity() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-IDENTITY-0001]" "reason=\"service arg required\""; return 2; }
    local build_type context ctx ctx_path
    build_type="$(ci_service_field "${service}" build_type)"
    [ -n "${build_type}" ] || build_type="toolchain"
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    {
        printf 'service=%s\nbuild_type=%s\n' "${service}" "${build_type}"
        _ci_tracked_content_ids "${context}"
        for ctx in $(ci_service_contexts "${service}"); do
            ctx_path="$(ci_context_path "${ctx}")"
            [ -n "${ctx_path}" ] && _ci_tracked_content_ids "${ctx_path}"
        done
        _ci_identity_pins "${service}" "${build_type}"
    } | sha256sum | cut -d' ' -f1
}

# ============================================================
# ARTIFACT RESOLVER
# ============================================================

# What: Probe the acceptance/registry state for an identity.
# Why: Injectable so logic tests need no live GHCR.
# From: Issue #1683
_ci_resolve_probe() {
    local service="$1" identity="$2"
    if [ -n "${CI_RESOLVE_PROBE_CMD:-}" ]; then
        "${CI_RESOLVE_PROBE_CMD}" "${service}" "${identity}"
        return 0
    fi
    # No probe wired yet: state is genuinely unknown, never
    # assumed missing (UNKNOWN != BUILD, Contract section 4).
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

# What: Resolve one service to a state + action.
# Why: NOOP/reuse decided before any build starts (§7).
# From: Issue #1683
ci_cmd_resolve() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RESOLVE-0001]" "reason=\"service arg required\""; return 2; }
    local identity state action
    identity="$(ci_cmd_identity "${service}")" || return "$?"
    state="$(_ci_resolve_probe "${service}" "${identity}")"
    case "${state}" in
        PRESENT_ACCEPTED|MISSING_CONFIRMED|MISMATCH|PRODUCED_UNVERIFIED|BUILD_IN_PROGRESS|UNKNOWN) ;;
        *)
            ci_log "[CI-ERROR-RESOLVE-0002]" "service=\"${service}\" reason=\"probe returned unknown state\" got=\"${state}\""
            state="UNKNOWN"
            ;;
    esac
    action="$(_ci_resolve_action "${state}")"
    printf 'service=%s state=%s action=%s identity=%s\n' "${service}" "${state}" "${action}" "${identity}"
    if [ "${state}" = "UNKNOWN" ]; then
        ci_log "[CI-INFO-RESOLVE-0003]" "service=\"${service}\" state=UNKNOWN note=\"escalate; UNKNOWN is never treated as build-needed\""
    fi
}

# ============================================================
# ACCEPTANCE INDEX
# ============================================================

# ============================================================
# RETRY CLASSIFIER
# ============================================================

# What: Classify a failure as transient or permanent (§67).
# Why: One rule replaces 5+ retry wrappers' own splits.
# From: Issue #1683
_ci_classify_failure() {
    local raw="$1"
    # Permanent: auth/malformed/real compile errors. Retrying
    # these only burns the backoff budget on a fixed outcome.
    case "${raw}" in
        *"HTTP 401"*|*"unauthorized"*|*"denied: requested access"*) printf 'permanent\n'; return 0 ;;
        *"HTTP 400"*|*"HTTP 422"*|*"invalid reference format"*) printf 'permanent\n'; return 0 ;;
        *"pull access denied"*|*"manifest unknown"*|*"not found: manifest"*) printf 'permanent\n'; return 0 ;;
        *"error: could not compile"*|*"Dockerfile parse error"*|*"failed to solve"*"parse"*) printf 'permanent\n'; return 0 ;;
    esac
    # Transient: rate-limit, 5xx, network, timeout. Retryable.
    case "${raw}" in
        *"HTTP 403"*|*"HTTP 429"*|*"toomanyrequests"*|*"rate limit"*) printf 'transient\n'; return 0 ;;
        *"HTTP 5"[0-9][0-9]*|*"i/o timeout"*|*"connection refused"*|*"TLS handshake timeout"*) printf 'transient\n'; return 0 ;;
        *"EOF"*|*"connection reset by peer"*|*"temporary failure"*) printf 'transient\n'; return 0 ;;
    esac
    # Unclassified: transient is the safe default -- a few
    # extra retries beat giving up on a real transient error.
    printf 'transient\n'
}

# ============================================================
# CACHE CONFIGURATION
# ============================================================

# What: Print the reuse order, cheapest first (§7).
# Why: Maximal caching never means build is preferred.
# From: Issue #1683
ci_reuse_order() {
    printf 'noop accepted binary_cas build_cache compiler_cache compile\n'
}

# ============================================================
# BUILD ENGINE
# ============================================================

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
    local service="$1" identity="$2"
    if [ -n "${CI_BUILD_CMD:-}" ]; then
        "${CI_BUILD_CMD}" "${service}" "${identity}"
        return "$?"
    fi
    ci_log "[CI-ERROR-BUILD-0003]" "service=\"${service}\" reason=\"no build backend wired (CI_BUILD_CMD unset)\""
    return 2
}

# What: Build one service, honoring resolve + reuse order.
# Why: NOOP/reuse/CAS precede compile; UNKNOWN never builds.
# From: Issue #1683
ci_cmd_build() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-BUILD-0001]" "reason=\"service arg required\""; return 2; }
    local resolved action identity build_type
    resolved="$(ci_cmd_resolve "${service}")" || return "$?"
    action="${resolved#*action=}"; action="${action%% *}"
    identity="${resolved#*identity=}"; identity="${identity%% *}"
    build_type="$(ci_service_field "${service}" build_type)"

    case "${action}" in
        noop)
            printf 'service=%s result=reuse-accepted identity=%s\n' "${service}" "${identity}"
            return 0
            ;;
        escalate|wait|verify)
            ci_log "[CI-INFO-BUILD-0004]" "service=\"${service}\" action=\"${action}\" note=\"not building; resolve action is not build\""
            printf 'service=%s result=%s identity=%s\n' "${service}" "${action}" "${identity}"
            [ "${action}" = "escalate" ] && return 2 || return 0
            ;;
        build) ;;
        *)
            ci_log "[CI-ERROR-BUILD-0005]" "service=\"${service}\" reason=\"unrecognized resolve action\" got=\"${action}\""
            return 2
            ;;
    esac

    # Rust targets can reuse an identical compiled binary from
    # the CAS before compiling again (reuse order, §7).
    if [ "${build_type}" = "rust" ] && _ci_cas_lookup "${identity}" >/dev/null 2>&1; then
        printf 'service=%s result=reuse-binary-cas identity=%s\n' "${service}" "${identity}"
        return 0
    fi

    _ci_require_ghcr_auth || return "$?"
    _ci_do_build "${service}" "${identity}" || return "$?"
    printf 'service=%s result=built identity=%s\n' "${service}" "${identity}"
}

# ============================================================
# VERIFY / TEST / SCAN
# ============================================================

# What: Push a built image to its per-identity GHCR ref.
# Why: Publish is authenticated and injectable for tests.
# From: Issue #1683
ci_cmd_publish() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-PUBLISH-0001]" "reason=\"service arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local identity digest
    identity="$(ci_cmd_identity "${service}")" || return "$?"
    if [ -n "${CI_PUBLISH_CMD:-}" ]; then
        digest="$("${CI_PUBLISH_CMD}" "${service}" "${identity}")" || {
            ci_log "[CI-ERROR-PUBLISH-0002]" "service=\"${service}\" reason=\"publish backend failed\""
            return 2
        }
    else
        ci_log "[CI-ERROR-PUBLISH-0003]" "service=\"${service}\" reason=\"no publish backend wired (CI_PUBLISH_CMD unset)\""
        return 2
    fi
    printf 'service=%s published=%s identity=%s\n' "${service}" "${digest}" "${identity}"
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
    # Real disk, never tmpfs /tmp -- large image/db exports there
    # risk filling RAM (OOM). Applies to the scanner's own TMPDIR.
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

# ============================================================
# ASSEMBLY
# ============================================================

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# NIGHTLY / RELEASE
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# DISPATCH
# ============================================================

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
