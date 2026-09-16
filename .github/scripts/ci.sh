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
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)}"

# What: The ci.sh subcommand dispatch table.
# Why: One table is membership, dispatch and error text.
# From: Issue #1683
declare -A CI_DISPATCH=(
    [plan]=ci_cmd_plan [impact]=ci_cmd_impact [identity]=ci_cmd_identity
    [resolve]=ci_cmd_resolve [build]=ci_cmd_build [build-args]=ci_cmd_build_args
    [build-tools]=ci_cmd_build_tools [publish]=ci_cmd_publish [verify]=ci_cmd_verify
    [test]=ci_cmd_test [scan]=ci_cmd_scan [assemble]=ci_cmd_assemble
    [validate]=ci_cmd_validate [promote]=ci_cmd_promote [release]=ci_cmd_release
    [gc]=ci_cmd_gc [variables]=ci_cmd_variables
)

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

# What: Print one field of a block entry.
# Why: One parser, no per-block duplicate.
# From: Issue #1683
_ci_block_entry_field() {
    local block="$1" entry="$2" field="$3"
    awk -v block="$block" -v entry="$entry" -v field="$field" '
        $0 ~ ("^" block ":[[:space:]]*$") { inb = 1; next }
        inb && /^[^[:space:]]/ { inb = 0 }
        inb && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); inentry = (cur == entry)
        }
        inb && inentry && $1 == (field ":") {
            val = $0; sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, "", val)
            print val; exit
        }
    ' "${CI_MANIFEST}"
}

# What: Print a block->entry->field list, one item per line.
# Why: One list reader; inline [..] and block - items alike.
# From: Issue #1683
_ci_block_entry_list() {
    local block="$1" entry="$2" field="$3"
    # What: entry="" reads a 2-level block->field list.
    # Why: build_matrix has no entry level; one reader.
    # From: Issue #1683
    awk -v block="$block" -v entry="$entry" -v field="$field" '
        BEGIN { fi = (entry == "") ? "  " : "    "; ii = (entry == "") ? "    " : "      " }
        $0 ~ ("^" block ":[[:space:]]*$") { inb = 1; inentry = (entry == ""); next }
        inb && /^[^[:space:]]/ { inb = 0 }
        inb && entry != "" && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); inentry = (cur == entry); inlist = 0
        }
        inb && inentry && $0 ~ ("^" fi field ":[[:space:]]*\\[") {
            line = $0; sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
            gsub(/[[:space:],]+/, " ", line)
            n = split(line, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            exit
        }
        inb && inentry && $0 ~ ("^" fi field ":[[:space:]]*$") { inlist = 1; next }
        inlist && $0 ~ ("^" ii "-[[:space:]]") {
            it = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", it); print it; next
        }
        inlist && $0 ~ ("^" fi "[^[:space:]]") { inlist = 0 }
        inlist && /^  [^[:space:]]/ { inlist = 0 }
    ' "${CI_MANIFEST}"
}

# What: Print one scalar field of a service entry.
# Why: Read build_type/runner/final_base without a copy.
# From: Issue #1683
ci_service_field() {
    _ci_block_entry_field "services" "$1" "$2"
}

# What: Print the named contexts a service rebuilds on.
# Why: dependency_graph is the SOT edge set (Finding 93).
# From: Issue #1683
ci_service_contexts() {
    _ci_block_entry_list dependency_graph "$1" contexts
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
    local service="$1" out
    out="$(_ci_block_entry_list services "${service}" platforms)"
    [ -n "${out}" ] || out="$(_ci_block_entry_list build_toolchain "${service}" platforms)"
    printf '%s' "${out}"
}

# What: Print the authoritative build_matrix platform list.
# Why: The one list every target defaults to.
# From: Issue #1683
_ci_build_matrix_platforms() {
    _ci_block_entry_list build_matrix "" platforms
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

# What: Map a platform to its apk arch, fail-closed.
# Why: One owner of the platform->apk-arch fact.
# From: Issue #1683
_ci_platform_apk_arch() {
    case "$1" in
        */amd64|amd64) printf 'x86_64\n' ;;
        */arm64|arm64) printf 'aarch64\n' ;;
        *) return 2 ;;
    esac
}

# What: Print the known arch-suffix aliases of a platform.
# Why: SOT mixes amd64/x86_64 and arm64/aarch64.
# From: Issue #1683
_ci_platform_arch_aliases() {
    local apk
    if apk="$(_ci_platform_apk_arch "$1")"; then
        printf '%s %s\n' "${1##*/}" "${apk}"
    else
        printf '%s\n' "${1##*/}"
    fi
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

# What: True if line-strip cannot touch string payload.
# Why: Raw or multiline strings make //-strip unsafe.
# From: Issue #1683
_ci_rust_strip_is_safe() {
    awk '
        /r#*"/ { bad = 1; exit }
        { if (gsub(/"/, "") % 2 == 1) { bad = 1; exit } }
        END { exit bad }
    '
}

# What: Emit path-keyed content ids of tracked files.
# Why: Content, not raw bytes or order, is the input.
# From: Issue #1683
_ci_tracked_content_ids() {
    local root="$1" ref="${2:-}" listing line path oid blob norm
    if [ -n "${ref}" ]; then
        listing="$( cd -- "${CI_REPO_ROOT}" && git ls-tree -r "${ref}" -- "${root}" 2>/dev/null \
            | awk -F'\t' '{ split($1, a, " "); print $2 "\t" a[3] }' | LC_ALL=C sort )" || return
    else
        listing="$( cd -- "${CI_REPO_ROOT}" && git ls-files -s -- "${root}" 2>/dev/null \
            | awk -F'\t' '{ split($1, a, " "); print $2 "\t" a[2] }' | LC_ALL=C sort )" || return
    fi
    [ -n "${listing}" ] || return 0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        path="${line%%$'\t'*}"
        oid="${line#*$'\t'}"
        if _ci_source_is_normalizable "${path}"; then
            blob="$( cd -- "${CI_REPO_ROOT}" && git cat-file blob "${oid}" 2>/dev/null )"
            if printf '%s' "${blob}" | _ci_rust_strip_is_safe; then
                norm="$(printf '%s' "${blob}" | _ci_rust_content_hash)"
                printf '%s\t%s\n' "${path}" "${norm}"
                continue
            fi
        fi
        printf '%s\t%s\n' "${path}" "${oid}"
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
    local service="$1" platform="$2" ref="${3:-}"
    local build_type context ctx ctx_path
    build_type="$(ci_service_field "${service}" build_type)"
    [ -n "${build_type}" ] || build_type="toolchain"
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    {
        printf 'service=%s\nbuild_type=%s\nplatform=%s\n' "${service}" "${build_type}" "${platform}"
        _ci_tracked_content_ids "${context}" "${ref}"
        for ctx in $(ci_service_contexts "${service}"); do
            ctx_path="$(ci_context_path "${ctx}")"
            [ -n "${ctx_path}" ] && _ci_tracked_content_ids "${ctx_path}" "${ref}"
        done
        _ci_identity_pins "${service}" "${build_type}" "${platform}"
    } | sha256sum | cut -d' ' -f1
}

# What: Run one_fn per platform, or one selected platform.
# Why: One fanout for identity/resolve/build/publish.
# From: Issue #1683
_ci_for_platforms() {
    local service="$1" platform="$2" invalid_id="$3" one_fn="$4" p plats
    if [ -n "${platform}" ]; then
        if ! _ci_valid_platform "${service}" "${platform}"; then
            ci_log "${invalid_id}" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""
            return 2
        fi
        "${one_fn}" "${service}" "${platform}"
        return "$?"
    fi
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        "${one_fn}" "${service}" "${p}" || return "$?"
    done <<< "${plats}"
}

# What: Print one target+platform identity line.
# Why: The per-platform unit the fanout calls.
# From: Issue #1683
_ci_identity_one() {
    printf 'platform=%s identity=%s\n' "$2" "$(_ci_identity_for "$1" "$2")"
}

# What: Print a target's id per platform, keyed.
# Why: Default = all platforms; one selectable.
# From: Issue #1683
ci_cmd_identity() {
    local service="${1:-}" platform="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-IDENTITY-0001]" "reason=\"service arg required\""; return 2; }
    _ci_for_platforms "${service}" "${platform}" "[CI-ERROR-IDENTITY-0002]" _ci_identity_one
}

# =========================================================
# IMPACT
# =========================================================

# What: Write the SOT as it stood at a git ref.
# Why: Base pins must reflect base, not head.
# From: Issue #1683
_ci_manifest_at() {
    local ref="$1" dest="$2"
    ( cd -- "${CI_REPO_ROOT}" && git show "${ref}:.github/yaml/build-manifest.yml" ) > "${dest}" 2>/dev/null
}

# What: Emit NOOP or BUILD per target and platform.
# Why: Equal identity base-vs-head is the no-build rule.
# From: Issue #1683
_ci_impact_run() {
    local base="$1" head="$2" base_manifest="$3"
    local base_missing=0 t p plats hid bid build=0 noop=0 unknown=0
    if ! _ci_manifest_at "${base}" "${base_manifest}" || [ ! -s "${base_manifest}" ]; then
        base_missing=1
        ci_log "[CI-INFO-IMPACT-0002]" "base=\"${base}\" reason=\"no SOT at base; UNKNOWN, escalate, BUILD DISACK\""
    fi
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        plats="$(_ci_platforms "${t}")" || return "$?"
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            if [ "${base_missing}" -eq 1 ]; then
                # What: no base SOT -> UNKNOWN, escalate.
                # Why: no base truth -> no BUILD.
                # From: Issue #1683
                printf 'target=%s platform=%s impact=UNKNOWN\n' "${t}" "${p}"
                unknown=$((unknown+1))
                continue
            fi
            hid="$(_ci_identity_for "${t}" "${p}" "${head}")"
            bid="$(CI_MANIFEST="${base_manifest}" _ci_identity_for "${t}" "${p}" "${base}")"
            if [ "${hid}" = "${bid}" ]; then
                printf 'target=%s platform=%s impact=NOOP\n' "${t}" "${p}"
                noop=$((noop+1))
            else
                printf 'target=%s platform=%s impact=BUILD\n' "${t}" "${p}"
                build=$((build+1))
            fi
        done <<< "${plats}"
    done <<< "$(ci_build_targets)"
    printf 'impact result=classified build=%s noop=%s unknown=%s base=%s\n' "${build}" "${noop}" "${unknown}" "${base}"
    # What: base-missing escalates; UNKNOWN never builds.
    # Why: base-SOT-unavailable stays DISACK, escalates.
    # From: Issue #1683
    [ "${base_missing}" -eq 1 ] && return 3
    return 0
}

# What: Compare base vs head; clean up the temp SOT.
# Why: base is required; fail-closed if base has no SOT.
# From: Issue #1683
ci_cmd_impact() {
    local base="${1:-}" head="${2:-HEAD}" base_manifest rc=0
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-IMPACT-0001]" "reason=\"base ref arg required\""
        return 2
    fi
    base_manifest="$(mktemp)"
    _ci_impact_run "${base}" "${head}" "${base_manifest}" || rc=$?
    rm -f "${base_manifest}"
    return "${rc}"
}

# =========================================================
# ARTIFACT RESOLVER
# =========================================================

# What: Probe the acceptance/registry state, fail-closed.
# Why: A failed probe is UNKNOWN, never a trusted state.
# From: Issue #1683
_ci_resolve_probe() {
    local service="$1" identity="$2"
    if [ -n "${CI_RESOLVE_PROBE_CMD:-}" ]; then
        # What: Capture probe output; keep its exit code.
        # Why: errexit must not skip rc check (AG-VAL-030).
        # From: Issue #1683
        local out rc=0
        out="$("${CI_RESOLVE_PROBE_CMD}" "${service}" "${identity}")" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            ci_log "[CI-INFO-RESOLVE-0005]" "service=\"${service}\" reason=\"probe backend failed; treating as UNKNOWN\" rc=${rc}"
            printf 'UNKNOWN\n'
            return 0
        fi
        printf '%s\n' "${out}"
        return 0
    fi
    # What: no probe wired -> report UNKNOWN.
    # Why: unknown is not missing; never assume built.
    printf 'UNKNOWN\n'
}

# What: Map a resolver state to its one action.
# Why: MISMATCH fails; UNKNOWN escalates; neither builds.
# From: Issue #1683
_ci_resolve_action() {
    case "$1" in
        PRESENT_ACCEPTED)   printf 'noop\n' ;;
        MISSING_CONFIRMED)  printf 'build\n' ;;
        MISMATCH)           printf 'fail\n' ;;
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
    _ci_for_platforms "${service}" "${platform}" "[CI-ERROR-RESOLVE-0004]" _ci_resolve_one
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

# What: Read the semantic build-impact verdict, fail-closed.
# Why: BUILD needs proven impact; unset/failed -> UNKNOWN.
# From: Issue #1683
_ci_semantic_impact() {
    local service="$1" platform="$2" identity="$3"
    if [ -n "${CI_IMPACT_CMD:-}" ]; then
        # What: Capture impact output; keep its exit code.
        # Why: errexit must not skip rc check (AG-VAL-030).
        # From: Issue #1683
        local out rc=0
        out="$("${CI_IMPACT_CMD}" "${service}" "${platform}" "${identity}")" || rc=$?
        if [ "${rc}" -ne 0 ]; then printf 'UNKNOWN\n'; return 0; fi
        case "${out}" in
            BUILD|NOOP|UNKNOWN) printf '%s\n' "${out}" ;;
            *) printf 'UNKNOWN\n' ;;
        esac
        return 0
    fi
    printf 'UNKNOWN\n'
}

# What: Emit BUILD_ACK only for the full admission set.
# Why: impact+MISSING_CONFIRMED+identity, bound to identity.
# From: Issue #1683
_ci_build_ack() {
    local service="$1" platform="$2" identity="$3" state="$4" impact="$5"
    [ "${impact}" = "BUILD" ] || return 1
    [ "${state}" = "MISSING_CONFIRMED" ] || return 1
    [ -n "${identity}" ] || return 1
    printf 'state=BUILD_ACK service=%s platform=%s identity=%s reason="impact=BUILD & MISSING_CONFIRMED & identity-known"\n' "${service}" "${platform}" "${identity}"
}

# What: Build one target+platform, honoring resolve + reuse.
# Why: NOOP/reuse/CAS precede compile; UNKNOWN never builds.
# From: Issue #1683
_ci_build_one() {
    local service="$1" platform="$2"
    local resolved action identity state build_type impact ack
    resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
    action="${resolved#*action=}"; action="${action%% *}"
    identity="${resolved#*identity=}"; identity="${identity%% *}"
    state="${resolved#*state=}"; state="${state%% *}"
    build_type="$(ci_service_field "${service}" build_type)"

    case "${action}" in
        noop)
            printf 'service=%s platform=%s result=reuse-accepted identity=%s\n' "${service}" "${platform}" "${identity}"
            return 0
            ;;
        fail)
            # What: MISMATCH is a detected contradiction.
            # Why: FAIL, no build, no replacement build.
            # From: Issue #1683
            ci_error "[CI-ERROR-BUILD-0010]" "service=\"${service}\" platform=\"${platform}\" state=\"${state}\" reason=\"MISMATCH: FAIL, no build, no replacement build\"" "${resolved}"
            printf 'service=%s platform=%s result=fail-mismatch identity=%s\n' "${service}" "${platform}" "${identity}"
            return 2
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

    # What: Prove semantic build impact before admission.
    # Why: MISSING_CONFIRMED alone MUST NOT build.
    # From: Issue #1683
    impact="$(_ci_semantic_impact "${service}" "${platform}" "${identity}")"
    case "${impact}" in
        NOOP)
            ci_log "[CI-INFO-BUILD-0007]" "service=\"${service}\" platform=\"${platform}\" note=\"no semantic impact; not building despite MISSING_CONFIRMED\""
            printf 'service=%s platform=%s result=no-build-no-impact identity=%s\n' "${service}" "${platform}" "${identity}"
            return 0
            ;;
        BUILD) ;;
        *)
            ci_log "[CI-INFO-BUILD-0008]" "service=\"${service}\" platform=\"${platform}\" note=\"semantic impact UNKNOWN; escalate, no build\""
            printf 'service=%s platform=%s result=escalate identity=%s\n' "${service}" "${platform}" "${identity}"
            return 2
            ;;
    esac

    # What: Derive BUILD_ACK bound to the exact identity.
    # Why: Positive admission MUST precede any build.
    # From: Issue #1683
    ack="$(_ci_build_ack "${service}" "${platform}" "${identity}" "${state}" "${impact}")" || {
        ci_log "[CI-ERROR-BUILD-0009]" "service=\"${service}\" platform=\"${platform}\" reason=\"admission conjunction incomplete; no BUILD_ACK\""
        return 2
    }
    printf '%s\n' "${ack}"

    # What: reuse a CAS binary before compiling.
    # Why: an identical binary need not rebuild.
    # From: Issue #1683
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
    _ci_for_platforms "${service}" "${platform}" "[CI-ERROR-BUILD-0006]" _ci_build_one
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
    _ci_for_platforms "${service}" "${platform}" "[CI-ERROR-PUBLISH-0004]" _ci_publish_one
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

# What: Read the candidate validation-fresh verdict.
# Why: AG-REL-011 verdict is read, never recomputed.
# From: Issue #1683
_ci_release_validation_valid() {
    if [ -n "${CI_RELEASE_VALIDATION_CMD:-}" ]; then
        "${CI_RELEASE_VALIDATION_CMD}"
        return "$?"
    fi
    return 1
}

# What: Verify freshness, then promote latest for release.
# Why: One acceptance model; latest plus AG-REL-011.
# From: Issue #1683
ci_cmd_release() {
    if ! _ci_release_validation_valid; then
        ci_log "[CI-ERROR-RELEASE-0001]" "reason=\"candidate validation not valid or unverified; not releasing\""
        return 2
    fi
    ci_cmd_promote latest
}

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

# What: The build-time secret mount ids (one source).
# Why: set-runtime, mounts and the guard share one list.
# From: Issue #1683
_ci_runtime_secret_ids() {
    printf '%s\n' \
        project_selfhosted_proxy_ca \
        sccache_redis_url ccache_redis_url \
        sccache_dist_config distcc_potential_hosts
}

# What: Forbidden env-key prefixes for the bake guard.
# Why: One source the guard and set-runtime both use.
# From: Issue #1683
_ci_bake_env_patterns() {
    printf '%s\n' \
        HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
        GOPROXY SCCACHE_ CCACHE_ DISTCC_
}

# What: Fail if a build-only secret/var is baked in.
# Why: A baked CA/proxy/accel var leaks and breaks runtime.
# From: Issue #1683
_ci_bake_check() {
    local image="$1" raw status line kind rest key patt bad=0
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0008]" "reason=\"no image ref given\""
        return 2
    fi
    _ci_require_ghcr_auth || return 2
    if [ -z "${CI_BAKE_INSPECT_CMD:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0004]" "reason=\"no image-inspect backend (CI_BAKE_INSPECT_CMD unset)\""
        return 2
    fi
    if raw="$("${CI_BAKE_INSPECT_CMD}" "${image}")"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-VARIABLES-0005]" "image=\"${image}\" reason=\"image inspect failed\"" "${raw}"
        return 2
    fi
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        kind="${line%% *}"
        rest="${line#* }"
        case "${kind}" in
            env)
                key="${rest%%=*}"
                while IFS= read -r patt; do
                    case "${key}" in
                        "${patt}"*)
                            ci_log "[CI-ERROR-VARIABLES-0006]" "image=\"${image}\" key=\"${key}\" reason=\"build-only var baked into image\""
                            bad=1
                            ;;
                    esac
                done <<< "$(_ci_bake_env_patterns)"
                ;;
            extra_ca)
                case "${rest}" in
                    0) : ;;
                    ''|*[!0-9]*)
                        ci_log "[CI-ERROR-VARIABLES-0007]" "image=\"${image}\" reason=\"malformed extra_ca from inspect\""
                        bad=1
                        ;;
                    *)
                        ci_log "[CI-ERROR-VARIABLES-0007]" "image=\"${image}\" extra_ca=\"${rest}\" reason=\"proxy CA baked into cert store\""
                        bad=1
                        ;;
                esac
                ;;
            *)
                ci_log "[CI-ERROR-VARIABLES-0009]" "image=\"${image}\" kind=\"${kind}\" reason=\"unrecognized inspect line; fail closed\""
                bad=1
                ;;
        esac
    done <<< "${raw}"
    if [ "${bad}" -ne 0 ]; then return 2; fi
    printf 'bake-check result=clean image=%s\n' "${image}"
}

# What: Path of the dir holding runtime secret files.
# Why: set-runtime writes here; clear-runtime removes it.
# From: Issue #1683
_ci_runtime_secret_dir() {
    printf '%s\n' "${CI_RUNTIME_SECRET_DIR:-${RUNNER_TEMP:-/tmp}/ci-runtime-secrets}"
}

# What: Escape a value for a double-quoted TOML string.
# Why: Scheduler URL and token go into the dist config.
# From: Issue #1683
_ci_toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# What: Write a secret value to a 0600 file.
# Why: Secrets go via file mounts, never env or args.
# From: Issue #1683
_ci_write_secret() {
    local path="$1" val="$2"
    ( umask 077; printf '%s' "${val}" > "${path}" )
}

# What: Assemble the sccache dist config TOML file.
# Why: One place builds it; token stays out of logs.
# From: Issue #1683
_ci_write_dist_config() {
    local path="$1"
    ( umask 077
      {
        printf '[dist]\n'
        printf 'scheduler_url = "%s"\n' "$(_ci_toml_escape "${SCCACHE_DIST_SCHEDULER_URL:-}")"
        printf 'toolchains = []\n'
        printf 'toolchain_cache_size = 5368709120\n'
        printf '\n[dist.auth]\n'
        printf 'type = "token"\n'
        printf 'token = "%s"\n' "$(_ci_toml_escape "${SCCACHE_DIST_AUTH_TOKEN:-}")"
      } > "${path}" )
}

# What: Emit a --secret ref for an already-written file.
# Why: One place formats the mount; id stays validated.
# From: Issue #1683
_ci_emit_secret_ref() {
    local dir="$1" id="$2" ids
    ids="$(_ci_runtime_secret_ids)"
    if ! grep -qx "${id}" <<< "${ids}"; then
        ci_log "[CI-ERROR-VARIABLES-0014]" "id=\"${id}\" reason=\"secret id not in the central list\""
        return 2
    fi
    printf -- '--secret id=%s,src=%s\n' "${id}" "${dir}/${id}"
}

# What: Write a plain secret value then emit its ref.
# Why: One place does write+mount for every plain secret.
# From: Issue #1683
_ci_emit_secret() {
    _ci_write_secret "$1/$2" "$3"
    _ci_emit_secret_ref "$1" "$2"
}

# What: Prepare build-time secret files + --secret args.
# Why: One place provides all build-only secrets, leak-safe.
# From: Issue #1683
_ci_set_runtime() {
    local dir mode sccache_enabled=1 redis_enabled=1
    dir="$(_ci_runtime_secret_dir)"
    mode="${SCCACHE_REDIS_MODE:-required}"
    case "${mode}" in
        required|optional|off) : ;;
        *)
            ci_log "[CI-ERROR-VARIABLES-0010]" "mode=\"${mode}\" reason=\"SCCACHE_REDIS_MODE must be required|optional|off\""
            return 2
            ;;
    esac
    if [ "${mode}" = "off" ]; then sccache_enabled=0; redis_enabled=0; fi
    if [ "${sccache_enabled}" = "1" ] && [ -n "${SCCACHE_DIST_SCHEDULER_URL:-}" ] && [ -z "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0011]" "reason=\"scheduler set without auth token\""
        return 2
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -z "${SCCACHE_DIST_SCHEDULER_URL:-}" ] && [ -n "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0011]" "reason=\"auth token set without scheduler\""
        return 2
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -z "${SCCACHE_REDIS_URL:-}" ]; then
        if [ "${mode}" = "optional" ]; then
            redis_enabled=0
        else
            ci_log "[CI-ERROR-VARIABLES-0012]" "reason=\"SCCACHE_REDIS_URL required when mode=required\""
            return 2
        fi
    fi
    ( umask 077; mkdir -p "${dir}" )
    if [ "${redis_enabled}" = "1" ]; then
        _ci_emit_secret "${dir}" sccache_redis_url "${SCCACHE_REDIS_URL:-}" || return "$?"
        _ci_emit_secret "${dir}" ccache_redis_url "${SCCACHE_REDIS_URL:-}" || return "$?"
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -n "${SCCACHE_DIST_SCHEDULER_URL:-}" ]; then
        _ci_write_dist_config "${dir}/sccache_dist_config"
        _ci_emit_secret_ref "${dir}" sccache_dist_config || return "$?"
    fi
    if [ -n "${DISTCC_POTENTIAL_HOSTS:-}" ]; then
        case "${DISTCC_POTENTIAL_HOSTS}" in
            *,cpp*) : ;;
            *)
                ci_log "[CI-ERROR-VARIABLES-0013]" "reason=\"DISTCC_POTENTIAL_HOSTS needs a pump host (,cpp)\""
                return 2
                ;;
        esac
        _ci_emit_secret "${dir}" distcc_potential_hosts "${DISTCC_POTENTIAL_HOSTS:-}" || return "$?"
    fi
    if [ -n "${PROJECT_SELFHOSTED_PROXY_CA:-}" ]; then
        _ci_emit_secret "${dir}" project_selfhosted_proxy_ca "${PROJECT_SELFHOSTED_PROXY_CA:-}" || return "$?"
    fi
}

# What: Remove all runtime secret files after the build.
# Why: Secrets must not linger on the runner.
# From: Issue #1683
_ci_clear_runtime() {
    local dir
    dir="$(_ci_runtime_secret_dir)"
    rm -rf "${dir}"
    printf 'clear-runtime result=cleared dir=%s\n' "${dir}"
}

# What: Print one CI variable value for callers.
# Why: Workflows read values via ci.sh, no second source.
# From: Issue #1683
ci_cmd_variables() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        get) _ci_variable "${1:-}" ;;
        set-runtime) _ci_set_runtime ;;
        clear-runtime) _ci_clear_runtime ;;
        bake-check) _ci_bake_check "${1:-}" ;;
        *)
            ci_log "[CI-ERROR-VARIABLES-0002]" "sub=\"${sub}\" reason=\"unknown variables subcommand\""
            return 2
            ;;
    esac
}

# What: Emit build-tools base + dhclient + apk build-args.
# Why: SOT owns them; the Dockerfile pins nothing itself.
# From: Issue #1683
_ci_build_tools_build_args() {
    local fmt="${1:-}" platform="${2:-}" prefix="--build-arg " out="" argname key val pkgs apk_arch sha
    [ "${fmt}" = "--bare" ] && prefix=""
    # What: base_images.alpine -> ALPINE_IMAGE.
    # Why: Final stage pins its base from the one owner.
    # From: Issue #1683
    val="$(_ci_manifest_scalar '^  alpine:')"
    val="${val%\"}"; val="${val#\"}"
    if [ -z "${val}" ]; then
        ci_log "[CI-ERROR-BUILDARGS-0003]" "arg=\"ALPINE_IMAGE\" key=\"base_images.alpine\" reason=\"missing central base image; FAIL CLOSED\""
        return 2
    fi
    out="${out}${prefix}ALPINE_IMAGE=${val}"$'\n'
    # What: platform-independent dhclient version+branch.
    # Why: The reused v3.20 apk pins these for every arch.
    # From: Issue #1683
    while IFS=: read -r argname key; do
        [ -n "${argname}" ] || continue
        val="$(_ci_block_entry_field external_versions dhclient "${key}")"
        if [ -z "${val}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0004]" "arg=\"${argname}\" key=\"external_versions.dhclient.${key}\" reason=\"missing central dhclient value; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}${argname}=${val}"$'\n'
    done <<'DHPAIRS'
DHCLIENT_VERSION:version
DHCLIENT_ALPINE_BRANCH:alpine_branch
DHPAIRS
    if [ -n "${platform}" ]; then
        # What: ci.sh resolves one apk-arch + its checksum.
        # Why: the Dockerfile consumes them; no arch case.
        # From: Issue #1683
        apk_arch="$(_ci_platform_apk_arch "${platform}")" || {
            ci_log "[CI-ERROR-BUILDARGS-0006]" "platform=\"${platform}\" reason=\"no apk arch mapping; FAIL CLOSED\""
            return 2
        }
        sha="$(_ci_block_entry_field external_versions dhclient "sha256_${platform##*/}")"
        if [ -z "${sha}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0004]" "arg=\"DHCLIENT_SHA256\" key=\"external_versions.dhclient.sha256_${platform##*/}\" reason=\"missing central dhclient value; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}DHCLIENT_APK_ARCH=${apk_arch}"$'\n'
        out="${out}${prefix}DHCLIENT_SHA256=${sha}"$'\n'
    else
        # What: no platform -> both shas, for the signature.
        # Why: the input signature covers every arch.
        # From: Issue #1683
        while IFS=: read -r argname key; do
            [ -n "${argname}" ] || continue
            val="$(_ci_block_entry_field external_versions dhclient "${key}")"
            if [ -z "${val}" ]; then
                ci_log "[CI-ERROR-BUILDARGS-0004]" "arg=\"${argname}\" key=\"external_versions.dhclient.${key}\" reason=\"missing central dhclient value; FAIL CLOSED\""
                return 2
            fi
            out="${out}${prefix}${argname}=${val}"$'\n'
        done <<'DHSHAS'
DHCLIENT_SHA256_AMD64:sha256_amd64
DHCLIENT_SHA256_ARM64:sha256_arm64
DHSHAS
    fi
    # What: append the SOT apk list as a build-arg.
    # Why: Dockerfile consumes it; it never owns the list.
    # From: Issue #1683
    pkgs="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    pkgs="${pkgs% }"
    out="${out}${prefix}APK_PACKAGES=${pkgs}"$'\n'
    printf '%s' "${out}"
}

# What: Emit SOT-owned docker build-args for a target.
# Why: One version owner; the Dockerfile pins nothing.
# From: Issue #1683
ci_cmd_build_args() {
    local service="${1:-}" fmt="${2:-}" platform="${3:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-BUILDARGS-0001]" "reason=\"service arg required\""; return 2; }
    case "${fmt}" in
        ""|--bare) : ;;
        *) ci_log "[CI-ERROR-BUILDARGS-0005]" "fmt=\"${fmt}\" reason=\"format must be empty or --bare\""; return 2 ;;
    esac
    case "${service}" in
        build-tools) _ci_build_tools_build_args "${fmt}" "${platform}" ;;
        # What: Non-toolchain targets carry no SOT arg.
        # Why: Only build-tools pins central versions now.
        # From: Issue #1683
        *) : ;;
    esac
}

# What: Print the build-tools apk package list.
# Why: One SOT source feeds the input check.
# From: Issue #1683
_ci_build_tools_packages() {
    local pkgs
    # What: read the exact SOT apk list via the one reader.
    # Why: SOT is the owner; no parse-back, no new parser.
    # From: Issue #1683
    pkgs="$(_ci_block_entry_list build_toolchain build-tools packages | LC_ALL=C sort -u)"
    # What: fail closed if the SOT list is empty.
    # Why: an empty list would blind the input check.
    # From: Issue #1683
    if [ -z "${pkgs}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0006]" "reason=\"no packages in SOT build_toolchain.build-tools.packages; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${pkgs}"
}

# What: Print the build-tools input signature.
# Why: Weekly check rebuilds only on a changed input.
# From: Issue #1683
_ci_build_tools_signature() {
    local versions="$1" args ids trimmed
    # What: fail closed on an empty apk version state.
    # Why: a blank scan must never mint a stable signature.
    # From: Issue #1683
    trimmed="$(printf '%s' "${versions}" | tr -d '[:space:]')"
    if [ -z "${trimmed}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0004]" "reason=\"empty apk version state; FAIL CLOSED\""
        return 2
    fi
    # What: every emitted build-arg feeds the signature.
    # Why: a base/dhclient change must move the sig.
    # From: Issue #1683
    args="$(_ci_build_tools_build_args --bare)" || return 2
    ids="$(_ci_tracked_content_ids tools/build-tools)"
    if [ -z "${ids}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0005]" "reason=\"no tracked build-tools source; FAIL CLOSED\""
        return 2
    fi
    printf 'args<<\n%s\nids<<\n%s\nversions<<\n%s\n' "${args}" "${ids}" "${versions}" \
        | sha256sum | cut -d' ' -f1
}

# What: Print the apk arch for each build_matrix platform.
# Why: the lifecycle signature must cover every arch.
# From: Issue #1683
_ci_build_tools_arches() {
    local platform out="" apk
    while IFS= read -r platform; do
        [ -n "${platform}" ] || continue
        # What: map via the one platform->apk-arch owner.
        # Why: no second arch table; fail-closed on unknown.
        # From: Issue #1683
        if ! apk="$(_ci_platform_apk_arch "${platform}")"; then
            ci_log "[CI-ERROR-BUILDTOOLS-0007]" "platform=\"${platform}\" reason=\"no apk arch mapping; FAIL CLOSED\""
            return 2
        fi
        out="${out}${apk}"$'\n'
    done <<< "$(_ci_build_matrix_platforms)"
    if [ -z "${out}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0008]" "reason=\"no build matrix platforms; FAIL CLOSED\""
        return 2
    fi
    printf '%s' "${out}" | LC_ALL=C sort -u
}

# What: Resolve one arch's apk versions (injectable).
# Why: real apk runs in a container; tests inject it.
# From: Issue #1683
_ci_apk_resolve() {
    local base="$1" arch="$2" packages="$3"
    if [ -n "${CI_APK_RESOLVE_CMD:-}" ]; then
        "${CI_APK_RESOLVE_CMD}" "${base}" "${arch}" "${packages}"
        return "$?"
    fi
    docker run --rm "${base}" sh -c "
        sed -i 's|^https://|http://|' /etc/apk/repositories
        apk --arch '${arch}' update >/dev/null 2>&1
        apk --arch '${arch}' add --no-cache --simulate ${packages} 2>&1 \
          | sed -n 's/^.*Installing \([^ ]*\) (\([^)]*\)).*/\1-\2/p' \
          | LC_ALL=C sort | tr '\n' ' '"
}

# What: Resolve every arch's apk state, then sign it.
# Why: the whole signature is computed here, not in YAML.
# From: Issue #1683
_ci_build_tools_resolve_signature() {
    local base packages arches arch av versions=""
    base="$(_ci_build_tools_build_args --bare | sed -n 's/^ALPINE_IMAGE=//p')"
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0009]" "reason=\"no ALPINE_IMAGE from SOT; FAIL CLOSED\""
        return 2
    fi
    packages="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    arches="$(_ci_build_tools_arches)" || return 2
    for arch in ${arches}; do
        av="$(_ci_apk_resolve "${base}" "${arch}" "${packages}")" || return 2
        if [ -z "${av}" ]; then
            ci_log "[CI-ERROR-BUILDTOOLS-0011]" "arch=\"${arch}\" reason=\"no apk versions; FAIL CLOSED\""
            return 2
        fi
        versions="${versions}${arch}:${av} "
    done
    _ci_build_tools_signature "${versions}"
}

# What: Read the signature label off a published image.
# Why: registry read lives here; tests inject the reader.
# From: Issue #1683
_ci_build_tools_published_signature() {
    local image="$1" json
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0012]" "reason=\"image ref required\""
        return 2
    fi
    if [ -n "${CI_PUBLISHED_SIG_CMD:-}" ]; then
        "${CI_PUBLISHED_SIG_CMD}" "${image}"
        return "$?"
    fi
    json="$(docker buildx imagetools inspect "${image}" --format '{{json .Image}}' 2>/dev/null)" || { printf ''; return 0; }
    printf '%s' "${json}" | jq -r '
        [.. | objects | .config?.Labels? // empty
         | ."org.lancache-ng.build-tools.signature" // empty]
        | map(select(. != "")) | first // ""'
}

# What: Append one arch entry to the build matrix JSON.
# Why: the dynamic matrix is built here, not in YAML.
# From: Issue #1683
_ci_matrix_append() {
    printf '%s' "$1" | jq -c --arg a "$2" --arg r "$3" --arg p "$4" \
        '. + [{"arch":$a,"runner":$r,"platform":$p}]'
}

# What: Decide arches to build and emit the matrix.
# Why: BUILD/NOOP + matrix logic lives here, not in YAML.
# From: Issue #1683
_ci_build_tools_gate() {
    local arch="$1" mode="$2" current="$3" published="$4"
    if [ -z "${current}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0013]" "reason=\"empty current signature; FAIL CLOSED\""
        return 2
    fi
    local need=false amd=false arm=false include='[]'
    if [ "${mode}" = "build" ] || [ "${current}" != "${published}" ]; then
        need=true
    fi
    if [ "${need}" = "true" ]; then
        case "${arch}" in
            amd64) amd=true ;;
            arm64) arm=true ;;
            both) amd=true; arm=true ;;
            *) ci_log "[CI-ERROR-BUILDTOOLS-0014]" "arch=\"${arch}\" reason=\"unknown arch\""; return 2 ;;
        esac
    fi
    [ "${amd}" = "true" ] && include="$(_ci_matrix_append "${include}" amd64 ubuntu-latest linux/amd64)"
    [ "${arm}" = "true" ] && include="$(_ci_matrix_append "${include}" arm64 ubuntu-24.04-arm linux/arm64)"
    printf 'build-amd64=%s\nbuild-arm64=%s\nmatrix={"include":%s}\n' "${amd}" "${arm}" "${include}"
}

# What: Assemble the multi-arch manifest (injectable).
# Why: registry assembly lives here, not in YAML.
# From: Issue #1683
_ci_build_tools_merge() {
    local sha="${1:-${GITHUB_SHA:-}}" image amd64 arm64 tag
    if [ -z "${sha}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0015]" "reason=\"commit sha required\""
        return 2
    fi
    if [ -n "${CI_MERGE_CMD:-}" ]; then
        "${CI_MERGE_CMD}" "${sha}"
        return "$?"
    fi
    image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE required}"
    # What: per-arch children use sha-<full>-<arch>.
    # Why: AG-REL-015 bans the -standalone- form.
    # From: Issue #1683
    amd64="${image}:sha-${sha}-amd64"
    arm64="${image}:sha-${sha}-arm64"
    for tag in "sha-${sha}" latest; do
        docker buildx imagetools create --tag "${image}:${tag}" "${amd64}" "${arm64}"
    done
}

# What: Format a multiline value as a GITHUB_OUTPUT block.
# Why: Actions multiline outputs need a heredoc delimiter.
# From: Issue #1683
_ci_emit_multiline() {
    local key="$1" value="$2"
    local delim="__CI_EOF_${key}__"
    # What: fail closed if the value contains the delimiter.
    # Why: a delimiter collision would corrupt the output.
    # From: Issue #1683
    case "${value}" in
        *"${delim}"*)
            ci_log "[CI-ERROR-CORE-0004]" "key=\"${key}\" reason=\"value contains output delimiter; FAIL CLOSED\""
            return 2
            ;;
    esac
    printf '%s<<%s\n%s\n%s' "${key}" "${delim}" "${value}" "${delim}"
}

# What: Resolve, decide, emit the determine outputs.
# Why: One call keeps the YAML run-block pure per AG-CI-023.
# From: Issue #1683
_ci_build_tools_plan() {
    local arch="${BT_ARCH:-both}" mode="${BT_MODE:-check}"
    local image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE required}"
    local out="${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    local current published gate_lines
    current="$(_ci_build_tools_resolve_signature)" || return 2
    published="$(_ci_build_tools_published_signature "${image}:latest")" || return 2
    gate_lines="$(_ci_build_tools_gate "${arch}" "${mode}" "${current}" "${published}")" || return 2
    # What: append resolved outputs to the step file.
    # Why: each build job resolves its own platform args.
    # From: Issue #1683
    {
        printf 'signature=%s\n' "${current}"
        printf '%s\n' "${gate_lines}"
    } >> "${out}"
}

# What: Emit one platform's build-args to the step file.
# Why: each build job resolves its own arch's args + sha.
# From: Issue #1683
_ci_build_tools_build_args_emit() {
    local platform="${1:-}" bare block out
    out="${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    if [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0016]" "reason=\"platform arg required\""
        return 2
    fi
    bare="$(_ci_build_tools_build_args --bare "${platform}")" || return 2
    block="$(_ci_emit_multiline build-args-bare "${bare}")" || return 2
    printf '%s\n' "${block}" >> "${out}"
}

# What: build-tools lifecycle helpers for the workflow.
# Why: all gate logic lives here; YAML only orchestrates.
# From: Issue #1683
ci_cmd_build_tools() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        packages) _ci_build_tools_packages ;;
        arches) _ci_build_tools_arches ;;
        signature) _ci_build_tools_signature "${1:-}" ;;
        resolve-signature) _ci_build_tools_resolve_signature ;;
        published-signature) _ci_build_tools_published_signature "${1:-}" ;;
        gate) _ci_build_tools_gate "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
        plan) _ci_build_tools_plan ;;
        build-args-out) _ci_build_tools_build_args_emit "${1:-}" ;;
        merge) _ci_build_tools_merge "${1:-}" ;;
        *)
            ci_log "[CI-ERROR-BUILDTOOLS-0003]" "sub=\"${sub}\" reason=\"unknown build-tools subcommand\""
            return 2
            ;;
    esac
}

# =========================================================
# DISPATCH
# =========================================================

# What: Route a subcommand to its engine function.
# Why: One table is membership and dispatch; no second list.
# From: Issue #1683
ci_main() {
    local command="${1:-}" fn
    if [ "$#" -gt 0 ]; then shift; fi
    fn="${CI_DISPATCH[${command}]:-}"
    if [ -z "${fn}" ]; then
        ci_log "[CI-ERROR-CORE-0002]" "command=\"${command}\" reason=\"unknown subcommand\" known=\"${!CI_DISPATCH[*]}\""
        return 2
    fi
    ci_require_manifest || return "$?"
    "${fn}" "$@"
}

# What: Run the dispatcher only on direct execution.
# Why: Lets ci.bats source the functions to test them.
# From: Issue #1683
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ci_main "$@"
fi
