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
CI_COMMANDS="plan impact identity resolve test build publish verify assemble validate promote gc variables"

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

# ============================================================
# ACCEPTANCE INDEX
# ============================================================

# ============================================================
# RETRY CLASSIFIER
# ============================================================

# ============================================================
# CACHE CONFIGURATION
# ============================================================

# ============================================================
# BUILD ENGINE
# ============================================================

# ============================================================
# VERIFY / TEST / SCAN
# ============================================================

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
