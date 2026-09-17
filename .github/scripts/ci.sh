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
    [plan]=ci_cmd_plan [plan-matrix]=ci_cmd_plan_matrix [impact]=ci_cmd_impact [identity]=ci_cmd_identity
    [resolve]=ci_cmd_resolve [build]=ci_cmd_build [build-args]=ci_cmd_build_args
    [build-tools]=ci_cmd_build_tools [publish]=ci_cmd_publish [verify]=ci_cmd_verify
    [test]=ci_cmd_test [scan]=ci_cmd_scan [assemble]=ci_cmd_assemble
    [aggregate]=ci_cmd_aggregate
    [validate]=ci_cmd_validate [promote]=ci_cmd_promote [release]=ci_cmd_release
    [gc]=ci_cmd_gc [variables]=ci_cmd_variables [check]=ci_cmd_check
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
    _ci_block_entry_field named_contexts "$1" path
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

# What: Map a platform to its GitHub-hosted runner label.
# Why: One owner; gate and Base-CI must not both hardcode.
# From: Issue #1683
_ci_platform_runner() {
    case "$1" in
        */amd64|amd64) printf 'ubuntu-latest\n' ;;
        */arm64|arm64) printf 'ubuntu-24.04-arm\n' ;;
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

# What: Collect changed files into a named array.
# Why: One owner; plan and plan-matrix share it.
# From: Issue #1683
_ci_collect_changed() {
    local -n _arr="$1"; shift
    _arr=()
    local line
    while IFS= read -r line; do
        [ -n "${line}" ] && _arr+=("${line}")
    done < <(_ci_changed_files "$@")
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

# What: True if a target's contexts touch changed paths.
# Why: One candidate rule for plan and Base-CI matrix.
# From: Issue #1683
_ci_plan_candidate() {
    local service="$1"; shift
    local context ctx ctx_path
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    _ci_paths_touch "${context}" "$@" && return 0
    for ctx in $(ci_service_contexts "${service}"); do
        ctx_path="$(ci_context_path "${ctx}")"
        [ -n "${ctx_path}" ] || continue
        _ci_paths_touch "${ctx_path}" "$@" && return 0
    done
    return 1
}

# What: Plan phase: pick rebuild CANDIDATES per service.
# Why: Path picks candidates; identity/CAS decides build.
# From: Issue #1683
ci_cmd_plan() {
    local -a changed=()
    _ci_collect_changed changed "$@"

    local service
    for service in $(ci_build_targets); do
        if _ci_plan_candidate "${service}" "${changed[@]}"; then
            printf '%s=true\n' "${service}"
        else
            printf '%s=false\n' "${service}"
        fi
    done
    ci_log "[CI-INFO-PLAN-0001]" "phase=plan changed=${#changed[@]} note=\"candidates only; identity/CAS decides build\""
}

# What: Emit a resolve-filtered matrix to GITHUB_OUTPUT.
# Why: Base-CI builds only what identity proves needs work.
# From: Issue #1683
ci_cmd_plan_matrix() {
    local out="${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    local -a changed=()
    _ci_collect_changed changed "$@"
    local service platform include='[]' any=false resolved paction runner
    for service in $(ci_build_targets); do
        _ci_plan_candidate "${service}" "${changed[@]}" || continue
        while IFS= read -r platform; do
            [ -n "${platform}" ] || continue
            resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
            paction="$(_ci_record_field "${resolved}" action)"
            [ "${paction}" = "build" ] || continue
            if ! runner="$(_ci_platform_runner "${platform}")"; then
                ci_log "[CI-ERROR-PLAN-0002]" "platform=\"${platform}\" reason=\"no runner label for platform\""
                return 2
            fi
            include="$(_ci_matrix_append "${include}" service="${service}" arch="${platform##*/}" runner="${runner}" platform="${platform}")" || return 2
            any=true
        done <<< "$(_ci_platforms "${service}")"
    done
    {
        printf 'any-build=%s\n' "${any}"
        printf 'matrix={"include":%s}\n' "${include}"
    } >> "${out}"
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
    local platform="$1" arch val
    for arch in $(_ci_platform_arch_aliases "${platform}"); do
        val="$(_ci_block_entry_field external_versions netdata "sha256_${arch}")"
        [ -n "${val}" ] && printf 'sha256_%s: %s\n' "${arch}" "${val}"
    done
}

# What: Print the SOT value a build type keys on.
# Why: apk keys base digest, install keys upstream digest.
# From: Issue #1683
_ci_identity_pins() {
    local service="$1" build_type="$2" platform="$3"
    case "${build_type}" in
        rust|toolchain)
            # What: rust keys the whole build-tools sig.
            # Why: one owner; input change moves the id.
            # From: Issue #1683
            _ci_build_tools_resolve_signature
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
    local build_type context ctx ctx_path pins
    build_type="$(ci_service_field "${service}" build_type)"
    [ -n "${build_type}" ] || build_type="toolchain"
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    # What: compute pins first so a failed pin fails the id.
    # Why: a swallowed sig error must not mint an id.
    # From: Issue #1683
    pins="$(_ci_identity_pins "${service}" "${build_type}" "${platform}")" || return "$?"
    {
        printf 'service=%s\nbuild_type=%s\nplatform=%s\n' "${service}" "${build_type}" "${platform}"
        _ci_tracked_content_ids "${context}" "${ref}"
        for ctx in $(ci_service_contexts "${service}"); do
            ctx_path="$(ci_context_path "${ctx}")"
            [ -n "${ctx_path}" ] && _ci_tracked_content_ids "${ctx_path}" "${ref}"
        done
        printf '%s\n' "${pins}"
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
    local service="$1" identity="$2" platform="${3:-}"
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
    _ci_resolve_state "${service}" "${identity}" "${platform}"
}

# What: Combine ledger policy + registry artifact truth.
# Why: §26 three-truths; UNKNOWN on any unreadable truth.
# From: Issue #1683
_ci_resolve_state() {
    local service="$1" identity="$2" platform="$3"
    [ -n "${platform}" ] || { printf 'UNKNOWN\n'; return 0; }
    local lrec lrc=0 grc=0 gdig tag lstate ldig
    lrec="$(_ci_ledger_read "$(_ci_ledger_remote)" "${identity}")" || lrc=$?
    [ "${lrc}" -eq 2 ] && { printf 'UNKNOWN\n'; return 0; }
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")"
    gdig="$(_ci_registry_probe "${tag}")" || grc=$?
    [ "${grc}" -eq 2 ] && { printf 'UNKNOWN\n'; return 0; }
    if [ "${lrc}" -eq 1 ]; then
        [ "${grc}" -eq 1 ] && { printf 'MISSING_CONFIRMED\n'; return 0; }
        printf 'PRODUCED_UNVERIFIED\n'
        return 0
    fi
    lstate="$(printf '%s' "${lrec}" | cut -f1)"
    ldig="$(printf '%s' "${lrec}" | cut -f2)"
    if [ "${lstate}" = ACCEPTED ]; then
        if [ "${grc}" -eq 1 ]; then
            ci_log "[CI-ERROR-RESOLVE-0006]" "service=\"${service}\" identity=\"${identity}\" reason=\"ACCEPTED in ledger but artifact missing in registry\" ledger_digest=\"${ldig}\""
            printf 'MISMATCH\n'
            return 0
        fi
        [ "${gdig}" = "${ldig}" ] && { printf 'PRESENT_ACCEPTED\n'; return 0; }
        printf 'MISMATCH\n'
        return 0
    fi
    printf 'PRODUCED_UNVERIFIED\n'
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

# What: Read one key=value field from a record line.
# Why: One owner of the resolve record format.
# From: Issue #1683
_ci_record_field() {
    local rec="$1" key="$2"
    rec="${rec#*"${key}"=}"
    printf '%s' "${rec%% *}"
}

# What: Resolve one target+platform to a state + action.
# Why: NOOP/reuse decided per platform first.
# From: Issue #1683
_ci_resolve_one() {
    local service="$1" platform="$2"
    local identity state action
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    state="$(_ci_resolve_probe "${service}" "${identity}" "${platform}")"
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
# RETRY CLASSIFIER
# =========================================================

# What: Classify a failure: transient, permanent, not_found.
# Why: operation-typed; not_found may build, permanent may not.
# From: Issue #1683
_ci_classify_failure() {
    local raw="$1" op="${2:-registry}" low
    # What: lowercased match surface for the whole function.
    # Why: Go/curl/gh vary "Connection reset"-style casing.
    # From: Issue #1683
    low="${raw,,}"
    # What: a GitHub-API 404 is permanent, never not_found.
    # Why: unlike a registry miss, an API 404 is fatal here.
    # From: Issue #1683
    if [ "${op}" = "github-api" ]; then
        case "${low}" in
            *"http 404"*|*"not found"*) printf 'permanent\n'; return 0 ;;
        esac
    fi
    # What: a genuinely missing registry artifact.
    # Why: only not_found may drive a build; auth may not.
    if [ "${op}" = "registry" ]; then
        case "${low}" in
            *"manifest unknown"*|*"not found: manifest"*|*"manifest_unknown"*|*"not found: name unknown"*|*"name_unknown"*) printf 'not_found\n'; return 0 ;;
        esac
    fi
    # What: auth/malformed/compile are permanent.
    # Why: retrying a fixed outcome wastes budget.
    case "${low}" in
        *"http 401"*|*"unauthorized"*|*"denied: requested access"*) printf 'permanent\n'; return 0 ;;
        *"http 400"*|*"http 422"*|*"invalid reference format"*) printf 'permanent\n'; return 0 ;;
        *"pull access denied"*) printf 'permanent\n'; return 0 ;;
        *"error: could not compile"*|*"dockerfile parse error"*|*"failed to solve"*"parse"*) printf 'permanent\n'; return 0 ;;
        *"couldn't find remote ref"*|*"fatal: repository"*"not found"*) printf 'permanent\n'; return 0 ;;
    esac
    # What: buildx's own narrow known-transient signatures.
    # Why: scoped like legacy wrappers; never a real compile fail.
    # From: Issue #1683
    if [ "${op}" = "buildx" ]; then
        case "${low}" in
            *"code = unavailable"*"locked for"*) printf 'transient\n'; return 0 ;;
            *"panic: methodref has no signature"*) printf 'transient\n'; return 0 ;;
        esac
    fi
    # What: rate-limit/5xx/network are transient.
    # Why: these recover on a retry with backoff.
    case "${low}" in
        *"http 403"*|*"http 429"*|*"toomanyrequests"*|*"rate limit"*) printf 'transient\n'; return 0 ;;
        *"http 5"[0-9][0-9]*|*"i/o timeout"*|*"connection refused"*|*"tls handshake timeout"*) printf 'transient\n'; return 0 ;;
        *"eof"*|*"connection reset by peer"*|*"temporary failure"*) printf 'transient\n'; return 0 ;;
        *"unexpected disconnect"*|*"remote end hung up"*|*"connection timed out"*) printf 'transient\n'; return 0 ;;
        *"could not resolve host"*|*"could not connect to server"*) printf 'transient\n'; return 0 ;;
        *"rpc failed; curl 92"*|*"rpc failed; curl 5"*) printf 'transient\n'; return 0 ;;
        *"gnutls recv error"*|*"tls connection"*"closed"*) printf 'transient\n'; return 0 ;;
    esac
    # What: an unclassified failure is transient.
    # Why: a missed transient is worse than a retry.
    printf 'transient\n'
}

# =========================================================
# GIT-REF CAS (coordination lock; §20/§52)
# =========================================================

# What: Empty tree object a CAS head points at.
# Why: A lock head carries a note, not tracked content.
# From: Issue #1683
CI_CAS_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# What: Print a ref's remote sha; 1 absent, 2 unknown.
# Why: A failed query is UNKNOWN, never a free lock.
# From: Issue #1683
_ci_cas_ref_sha() {
    local remote="$1" ref="$2" out rc=0
    out="$(git ls-remote --exit-code "${remote}" "${ref}" 2>/dev/null)" || rc=$?
    [ "${rc}" -eq 0 ] && { printf '%s\n' "${out%%$'\t'*}"; return 0; }
    [ "${rc}" -eq 2 ] && return 1
    return 2
}

# What: Run git under the synthetic CAS identity.
# Why: Runners have no git user; one identity owner.
# From: Issue #1683
_ci_cas_git() {
    GIT_AUTHOR_NAME=ci-cas GIT_AUTHOR_EMAIL=ci-cas@lancache-ng.invalid \
    GIT_COMMITTER_NAME=ci-cas GIT_COMMITTER_EMAIL=ci-cas@lancache-ng.invalid \
        git "$@"
}

# What: Build an empty-tree commit carrying a note.
# Why: A lock head carries a note, not a real tree.
# From: Issue #1683
_ci_cas_note_commit() {
    _ci_cas_git commit-tree "${CI_CAS_EMPTY_TREE}" -m "$1" 2>/dev/null
}

# What: Classify a failed CAS push: race vs real fail.
# Why: A moved ref means re-read, not a plain retry.
# From: Issue #1683
_ci_cas_push_class() {
    case "$1" in
        *non-fast-forward*|*"failed to push some refs"*|*"cannot lock ref"*|*"stale info"*|*"fetch first"*|*rejected*) printf 'race\n' ;;
        *) _ci_classify_failure "$1" ;;
    esac
}

# What: One non-blocking lock acquisition attempt.
# Why: Create or stale-takeover, both atomic server-side.
# From: Issue #1683
_ci_lock_try() {
    local remote="$1" ref="$2" note="$3" stale="$4"
    local cur="" sha raw rc=0 committed prev now age
    cur="$(_ci_cas_ref_sha "${remote}" "${ref}")" || rc=$?
    if [ "${rc}" -eq 1 ]; then
        sha="$(_ci_cas_note_commit "${note}")" || return 3
        rc=0; raw="$(git push "${remote}" "${sha}:${ref}" 2>&1)" || rc=$?
        [ "${rc}" -eq 0 ] && return 0
        [ "$(_ci_cas_push_class "${raw}")" = race ] && return 2
        return 3
    fi
    [ "${rc}" -eq 0 ] || return 3
    # What: not routed through _ci_retry (deliberate).
    # Why: _ci_lock_acquire already retries this whole attempt.
    # From: Issue #1683
    git fetch --quiet --depth=1 "${remote}" "${ref}" >/dev/null 2>&1 || return 3
    committed="$(git log -1 --format=%ct FETCH_HEAD 2>/dev/null)" || committed=0
    committed="${committed:-0}"
    prev="$(git log -1 --format=%s FETCH_HEAD 2>/dev/null)" || prev=""
    now="$(date +%s)"; age=$(( now - committed ))
    [ "${age}" -lt "${stale}" ] && return 1
    sha="$(_ci_cas_note_commit "${note}")" || return 3
    rc=0; raw="$(git push --force-with-lease="${ref}:${cur}" "${remote}" "${sha}:${ref}" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-INFO-CAS-0001]" "ref=\"${ref}\" note=\"stale lock taken over\" age=\"${age}\" prev=\"${prev}\""
        return 0
    fi
    [ "$(_ci_cas_push_class "${raw}")" = race ] && return 2
    return 3
}

# What: Retry lock acquisition; fail closed at the end.
# Why: Proceeding unlocked would race the guarded section.
# From: Issue #1683
_ci_lock_acquire() {
    local remote="$1" ref="$2" note="$3" max="$4" backoff="$5" stale="$6"
    local n=1 rc=0
    while [ "${n}" -le "${max}" ]; do
        rc=0; _ci_lock_try "${remote}" "${ref}" "${note}" "${stale}" || rc=$?
        [ "${rc}" -eq 0 ] && return 0
        [ "${n}" -ge "${max}" ] && break
        if [ "${rc}" -eq 2 ]; then sleep 2; else sleep "${backoff}"; fi
        n=$(( n + 1 ))
    done
    ci_error "[CI-ERROR-CAS-0002]" "ref=\"${ref}\" reason=\"lock not acquired in ${max} attempts; fail closed\"" "note=${note} last_rc=${rc}"
    return 1
}

# What: Release a lock only if this note still holds it.
# Why: Never delete a lock a takeover reassigned.
# From: Issue #1683
_ci_lock_release() {
    local remote="$1" ref="$2" note="$3" cur="" held rc=0
    cur="$(_ci_cas_ref_sha "${remote}" "${ref}")" || rc=$?
    [ "${rc}" -eq 0 ] || return 0
    # What: this fetch had no retry at any level (unlike acquire).
    # Why: op=git gives it the shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${ref}" >/dev/null || return 1
    held="$(git log -1 --format=%s FETCH_HEAD 2>/dev/null)" || held=""
    [ "${held}" = "${note}" ] || return 0
    git push --force-with-lease="${ref}:${cur}" "${remote}" ":${ref}" >/dev/null 2>&1 || return 1
    return 0
}

# =========================================================
# ACCEPTANCE LEDGER (policy truth; §26)
# =========================================================

# What: The git ref holding the acceptance ledger.
# Why: One ledger; §26 policy truth, not GHCR.
# From: Issue #1683
CI_LEDGER_REF="${CI_LEDGER_REF:-refs/ci/acceptance/ledger}"

# What: The ledger blob path inside its tree.
# Why: One tracked file holding the whole record set.
# From: Issue #1683
CI_LEDGER_FILE="records"

# What: The remote holding the CAS lock and ledger.
# Why: One remote name; a test overrides it.
# From: Issue #1683
_ci_ledger_remote() {
    printf '%s' "${CI_LEDGER_REMOTE:-origin}"
}

# What: Print the ledger blob text; 1 empty, 2 unknown.
# Why: A failed read is UNKNOWN, never "no records".
# From: Issue #1683
_ci_ledger_blob() {
    local remote="$1" rc=0
    _ci_cas_ref_sha "${remote}" "${CI_LEDGER_REF}" >/dev/null 2>&1 || rc=$?
    [ "${rc}" -eq 1 ] && return 1
    [ "${rc}" -eq 0 ] || return 2
    # What: this fetch had no retry at any level.
    # Why: op=git gives it the shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${CI_LEDGER_REF}" >/dev/null || return 2
    git cat-file -p "FETCH_HEAD:${CI_LEDGER_FILE}" 2>/dev/null || return 2
}

# What: Read one identity's record: state + digest.
# Why: One reader; resolve/digest/index share it (§26).
# From: Issue #1683
_ci_ledger_read() {
    local remote="$1" identity="$2" blob rc=0 out
    blob="$(_ci_ledger_blob "${remote}")" || rc=$?
    [ "${rc}" -eq 1 ] && return 1
    [ "${rc}" -eq 0 ] || return 2
    out="$(printf '%s\n' "${blob}" | awk -F'\t' -v id="${identity}" '$1==id {print $4"\t"$5; exit}')"
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}"
}

# What: Build a ledger commit over a real tree.
# Why: The ledger carries records, not an empty tree.
# From: Issue #1683
_ci_ledger_commit() {
    local tree="$1" parent="$2" msg="$3"
    local -a pa=()
    [ -n "${parent}" ] && pa=(-p "${parent}")
    _ci_cas_git commit-tree "${tree}" "${pa[@]}" -m "${msg}" 2>/dev/null
}

# What: Upsert record lines from stdin in one CAS write.
# Why: §26.1 one atomic ledger write per workflow.
# From: Issue #1683
_ci_ledger_upsert() {
    local remote="$1" new blob rc=0 parent="" ids kept merged blobsha treesha commitsha raw
    new="$(cat)"
    new="$(printf '%s\n' "${new}" | awk 'NF>0')"
    [ -n "${new}" ] || return 0
    blob="$(_ci_ledger_blob "${remote}")" || rc=$?
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-LEDGER-0001]" "reason=\"ledger read UNKNOWN; refusing to write\""
        return 3
    fi
    ids="$(printf '%s\n' "${new}" | awk -F'\t' '{print $1}')"
    if [ "${rc}" -eq 1 ]; then
        kept=""
    else
        parent="$(git rev-parse FETCH_HEAD 2>/dev/null)" || return 3
        kept="$(printf '%s\n' "${blob}" | awk -F'\t' -v ids="${ids}" '
            BEGIN { n = split(ids, a, "\n"); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
            NF > 0 && !($1 in drop)')"
    fi
    # What: sort the merged record set deterministically.
    # Why: same inputs -> same blob; §26.4 idempotency.
    merged="$(printf '%s\n%s\n' "${kept}" "${new}" | awk 'NF>0' | LC_ALL=C sort -u)"
    blobsha="$(printf '%s\n' "${merged}" | git hash-object -w --stdin)" || return 3
    treesha="$(printf '100644 blob %s\t%s\n' "${blobsha}" "${CI_LEDGER_FILE}" | git mktree)" || return 3
    commitsha="$(_ci_ledger_commit "${treesha}" "${parent}" "ledger aggregate")" || return 3
    rc=0
    if [ -n "${parent}" ]; then
        raw="$(git push --force-with-lease="${CI_LEDGER_REF}:${parent}" "${remote}" "${commitsha}:${CI_LEDGER_REF}" 2>&1)" || rc=$?
    else
        raw="$(git push "${remote}" "${commitsha}:${CI_LEDGER_REF}" 2>&1)" || rc=$?
    fi
    [ "${rc}" -eq 0 ] && return 0
    [ "$(_ci_cas_push_class "${raw}")" = race ] && return 2
    return 3
}

# What: Upsert a single record via the batch writer.
# Why: One writer; convenience for one identity.
# From: Issue #1683
_ci_ledger_append() {
    local remote="$1" identity="$2" service="$3" platform="$4" state="$5" digest="$6"
    printf '%s\t%s\t%s\t%s\t%s\n' "${identity}" "${service}" "${platform}" "${state}" "${digest}" \
        | _ci_ledger_upsert "${remote}"
}

# =========================================================
# AGGREGATOR (single ledger write; §26.1)
# =========================================================

# What: Parse one result.json into a ledger record.
# Why: fail closed on a malformed or partial result.
# From: Issue #1683
_ci_result_record() {
    local f="$1" service platform identity state digest
    service="$(jq -er '.service' "${f}")" || return 2
    platform="$(jq -er '.platform' "${f}")" || return 2
    identity="$(jq -er '.build_identity' "${f}")" || return 2
    state="$(jq -er '.state' "${f}")" || return 2
    digest="$(jq -er '.digest' "${f}")" || return 2
    printf '%s\t%s\t%s\t%s\t%s\n' "${identity}" "${service}" "${platform}" "${state}" "${digest}"
}

# What: Merge matrix result.json files into one write.
# Why: §26.1 aggregator: many jobs, one CAS ledger write.
# From: Issue #1683
ci_cmd_aggregate() {
    local dir="${1:-}"
    [ -n "${dir}" ] || { ci_log "[CI-ERROR-AGGREGATE-0001]" "reason=\"results dir arg required\""; return 2; }
    [ -d "${dir}" ] || { ci_log "[CI-ERROR-AGGREGATE-0002]" "reason=\"results dir not found\" dir=\"${dir}\""; return 2; }
    local f records="" line
    for f in "${dir}"/*.json; do
        [ -e "${f}" ] || continue
        line="$(_ci_result_record "${f}")" || {
            ci_log "[CI-ERROR-AGGREGATE-0004]" "file=\"${f}\" reason=\"malformed or incomplete result.json\""
            return 2
        }
        records="${records}${line}"$'\n'
    done
    [ -n "${records}" ] || { ci_log "[CI-ERROR-AGGREGATE-0003]" "reason=\"no result.json in dir\" dir=\"${dir}\""; return 2; }
    local rc=0
    printf '%s' "${records}" | _ci_ledger_upsert "$(_ci_ledger_remote)" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        printf 'aggregate result=written records=%s\n' "$(printf '%s' "${records}" | grep -c .)"
        return 0
    fi
    return "${rc}"
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

# What: Lowercased owner/repo for GHCR image refs.
# Why: GHCR paths are case-sensitive and must be lower.
# From: Issue #1683
_ci_repo() {
    local r="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    printf '%s' "${r,,}"
}

# What: Run any command, retrying only a transient failure.
# Why: RETRY OPERATION != REBUILD; classify before retry.
# From: Issue #1683
_ci_retry() {
    local op="$1"; shift
    local n=0 max="${CI_RETRY_MAX_ATTEMPTS:-4}" backoff="${CI_RETRY_BACKOFF_BASE_SECONDS:-1}" raw cls
    while :; do
        n=$((n + 1))
        if raw="$("$@" 2>&1)"; then
            printf '%s\n' "${raw}"
            return 0
        fi
        cls="$(_ci_classify_failure "${raw}" "${op}")"
        if [ "${cls}" != "transient" ] || [ "${n}" -ge "${max}" ]; then
            ci_error "[CI-ERROR-BUILD-0011]" "reason=\"command failed cls=${cls} attempt=${n}/${max} op=${op}\"" "${raw}"
            # What: surface the raw failure to the caller too.
            # Why: an op-specific reason may need caller interpretation.
            # From: Issue #1683
            printf '%s\n' "${raw}"
            return 2
        fi
        sleep "$((n * n * backoff))"
    done
}

# What: The per-identity per-arch tag for a build.
# Why: One tag owner; build/publish/verify must agree.
# From: Issue #1683
_ci_image_tag() {
    printf 'ghcr.io/%s/%s:sha-%s-%s' "$(_ci_repo)" "$1" "$3" "${2##*/}"
}

# What: OCI image labels from the SOT and env.
# Why: Provenance labels set once, not per Dockerfile.
# From: Issue #1683
_ci_oci_labels() {
    local service="$1" prefix source base created
    prefix="$(_ci_manifest_scalar '^  image_prefix:')"
    source="https://github.com/${prefix}"
    base="$(_ci_manifest_scalar '^  alpine:')"
    base="${base#\"}"; base="${base%\"}"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'org.opencontainers.image.created=%s\n' "${created}"
    [ -n "${GITHUB_SHA:-}" ] && printf 'org.opencontainers.image.revision=%s\n' "${GITHUB_SHA}"
    printf 'org.opencontainers.image.source=%s\n' "${source}"
    printf 'org.opencontainers.image.url=%s\n' "${source}"
    printf 'org.opencontainers.image.documentation=%s\n' "${source}"
    printf 'org.opencontainers.image.licenses=%s\n' 'AGPL-3.0-or-later'
    printf 'org.opencontainers.image.vendor=%s\n' "${prefix%%/*}"
    printf 'org.opencontainers.image.title=%s\n' "${service}"
    if [ -n "${base}" ]; then
        printf 'org.opencontainers.image.base.name=%s\n' "${base%@*}"
        printf 'org.opencontainers.image.base.digest=%s\n' "${base#*@}"
    fi
}

# What: Build one service image once and load it locally.
# Why: BUILD != PUBLISH; a push failure must not rebuild.
# From: Issue #1683
_ci_docker_build() {
    local service="$1" identity="$2" platform="$3"
    local context tag a
    context="$(ci_service_field "${service}" context)"
    [ -z "${context}" ] && context="services/${service}"
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")"
    local -a args=()
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--label "${a}")
    done < <(_ci_oci_labels "${service}")
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-arg "${a}")
    done < <(ci_cmd_build_args "${service}" --bare "${platform}")
    # What: retries buildx; captures its output, never doubles it.
    # Why: on failure ci_error already shows raw; avoid a 2nd copy.
    # From: Issue #1683
    local buildlog rc=0
    buildlog="$(_ci_retry buildx docker buildx build --load --platform "${platform}" --tag "${tag}" "${args[@]}" "${context}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf '%s\n' "${buildlog}" >&2
    printf '%s\n' "${tag}"
}

# What: Read a pushed tag's immutable registry digest.
# Why: One digest reader for publish and verify readback.
# From: Issue #1683
_ci_registry_digest() {
    docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
}

# What: Probe a tag's digest; 1 not-found, 2 unknown.
# Why: only a real miss may build; auth stays UNKNOWN.
# From: Issue #1683
_ci_registry_probe() {
    local tag="$1" raw rc=0
    raw="$(docker buildx imagetools inspect "${tag}" --format '{{.Manifest.Digest}}' 2>&1)" || rc=$?
    [ "${rc}" -eq 0 ] && { printf '%s\n' "${raw}"; return 0; }
    [ "$(_ci_classify_failure "${raw}")" = not_found ] && return 1
    return 2
}

# What: Create or update a multi-arch index from sources.
# Why: One imagetools writer for assemble and build-tools.
# From: Issue #1683
_ci_imagetools_create() {
    local target="$1"; shift
    _ci_retry registry docker buildx imagetools create --tag "${target}" "$@"
}

# What: Push a built tag, retrying transient push failures.
# Why: publish retries the same digest (§22), no rebuild.
# From: Issue #1683
_ci_docker_publish() {
    local service="$1" identity="$2" platform="$3" tag
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")"
    _ci_retry registry docker push "${tag}" >/dev/null || return "$?"
    _ci_registry_digest "${tag}"
}

# What: Classify a trivy failure with no report file.
# Why: A DB-download miss retries; other errors do not.
# From: Issue #1683
_ci_trivy_error_kind() {
    case "$1" in
        *"failed to download vulnerability DB"*|*"database is not initialized"*|*"unable to initialize"*|*"failed to download artifact"*) printf 'db-missing\n' ;;
        *) printf 'pre-report-error\n' ;;
    esac
}

# What: Probe a dir with a real file+subdir write/read.
# Why: A stale/listable mount may still fail real I/O.
# From: Issue #1683
_ci_trivy_dir_writable() {
    local dir="$1" probe subdir
    [ -d "${dir}" ] || return 1
    probe="${dir}/.trivy-cache-dir-write-probe.$$.${RANDOM}"
    subdir="${dir}/.trivy-cache-dir-write-probe-dir.$$.${RANDOM}"
    ( set -e
      printf 'probe' > "${probe}"
      [ "$(cat "${probe}")" = "probe" ]
      rm -f "${probe}"
      mkdir "${subdir}"
      printf 'probe' > "${subdir}/probe"
      [ "$(cat "${subdir}/probe")" = "probe" ]
      rm -rf "${subdir}"
    ) 2>/dev/null
}

# What: Resolve a persistent Trivy DB cache-dir.
# Why: NFS-shared or real local disk, never tmpfs/tmp.
# From: Issue #1683
_ci_trivy_cache_dir() {
    if [ -n "${CI_TRIVY_CACHE_DIR_CMD:-}" ]; then
        "${CI_TRIVY_CACHE_DIR_CMD}"
        return "$?"
    fi
    local shared="${CI_TRIVY_SHARED_DIR:-/mnt/trivy-db}"
    local fallback="${CI_TRIVY_FALLBACK_DIR:-/var/tmp/lancache-ng-trivy-cache-fallback}"
    case "${shared}" in
        /tmp|/tmp/*) ci_log "[CI-ERROR-SCAN-0007]" "reason=\"shared trivy cache-dir must not be tmpfs /tmp\" got=\"${shared}\""; return 2 ;;
    esac
    case "${fallback}" in
        /tmp|/tmp/*) ci_log "[CI-ERROR-SCAN-0007]" "reason=\"fallback trivy cache-dir must not be tmpfs /tmp\" got=\"${fallback}\""; return 2 ;;
    esac
    if _ci_trivy_dir_writable "${shared}"; then
        printf 'dir=%s source=nfs-shared\n' "${shared}"
        return 0
    fi
    ci_log "[CI-INFO-SCAN-0008]" "shared=\"${shared}\" reason=\"not mounted/writable; falling back to local disk\""
    mkdir -p "${fallback}" 2>/dev/null || {
        ci_log "[CI-ERROR-SCAN-0009]" "dir=\"${fallback}\" reason=\"could not create local fallback trivy cache-dir\""
        return 2
    }
    if ! _ci_trivy_dir_writable "${fallback}"; then
        ci_log "[CI-ERROR-SCAN-0009]" "dir=\"${fallback}\" reason=\"fallback trivy cache-dir failed write probe\""
        return 2
    fi
    printf 'dir=%s source=local-fallback\n' "${fallback}"
}

# What: True if cache-dir's trivy.db is present and fresh.
# Why: skip-db-update never re-validates staleness itself.
# From: Issue #1683
_ci_trivy_db_fresh() {
    local cache_dir="$1" db_file meta next_update next_epoch now_epoch
    db_file="${cache_dir}/db/trivy.db"
    meta="${cache_dir}/db/metadata.json"
    [ -s "${db_file}" ] || return 1
    next_update="$(jq -r '.NextUpdate // empty' "${meta}" 2>/dev/null)" || return 1
    [ -n "${next_update}" ] || return 1
    next_epoch="$(date -d "${next_update}" +%s 2>/dev/null)" || return 1
    [ -n "${next_epoch}" ] || return 1
    now_epoch="$(date +%s)"
    [ "${now_epoch}" -lt "${next_epoch}" ]
}

# What: mkdir-mutex around a Trivy DB cache-dir write.
# Why: Two writers must never race the same BoltDB file.
# From: Issue #1683
_ci_trivy_db_lock_run() {
    local cache_dir="$1" lock_timeout="$2" stale_after="$3"; shift 3
    [ "${1:-}" = "--" ] && shift
    local lock_dir="${cache_dir}/.trivy-db-update.lock"
    local poll="${CI_TRIVY_LOCK_POLL:-5}" waited=0 lock_mtime age
    while ! mkdir "${lock_dir}" 2>/dev/null; do
        if [ -d "${lock_dir}" ]; then
            lock_mtime="$(stat -c %Y "${lock_dir}" 2>/dev/null || echo 0)"
            age=$(( $(date +%s) - lock_mtime ))
            if [ "${age}" -gt "${stale_after}" ]; then
                ci_log "[CI-WARN-SCAN-0010]" "lock=\"${lock_dir}\" age=${age} stale_after=${stale_after} reason=\"reclaiming stale trivy DB refresh lock\""
                rm -rf -- "${lock_dir}"
                continue
            fi
        fi
        if [ "${waited}" -ge "${lock_timeout}" ]; then
            ci_log "[CI-ERROR-SCAN-0011]" "lock=\"${lock_dir}\" timeout=${lock_timeout} reason=\"timed out waiting for trivy DB refresh lock\""
            return 2
        fi
        sleep "${poll}"
        waited=$(( waited + poll ))
    done
    # What: releases the lock on any return from this call.
    # Why: an unreleased lock wedges every later caller.
    # shellcheck disable=SC2064
    trap "rm -rf -- '${lock_dir}'" RETURN
    "$@"
}

# What: Ensure cache-dir's Trivy DB is present and fresh.
# Why: Freshness != presence; skip-db-update needs proof.
# From: Issue #1683
_ci_trivy_db_ensure_fresh() {
    local cache_dir="$1" rc=0
    local lock_timeout="${CI_TRIVY_LOCK_TIMEOUT:-900}"
    local stale_after="${CI_TRIVY_LOCK_STALE:-1200}"
    if _ci_trivy_db_fresh "${cache_dir}"; then
        printf 'present=true\n'
        return 0
    fi
    _ci_trivy_db_lock_run "${cache_dir}" "${lock_timeout}" "${stale_after}" -- \
        "${CI_TRIVY_DB_DOWNLOAD_CMD:-trivy}" image --download-db-only --cache-dir "${cache_dir}" || rc=$?
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-SCAN-0012]" "reason=\"lock timeout; refusing an unlocked concurrent DB write\""
        return 2
    fi
    if _ci_trivy_db_fresh "${cache_dir}"; then
        printf 'present=true\n'
        return 0
    fi
    printf 'present=false\n'
}

# What: Scan an image digest with Trivy on the runner.
# Why: A written report is a finding; only DB miss retries.
# From: Issue #1683
_ci_trivy_scan() {
    local service="$1" digest="$2" ref report n=0 raw
    local max="${CI_TRIVY_MAX:-4}"
    local scanners="${CI_TRIVY_SCANNERS:-vuln,secret}"
    local ignore="${CI_TRIVY_IGNOREFILE:-.trivyignore.yaml}"
    local cache_rec cache_dir fresh_rec skip_db=0
    cache_rec="$(_ci_trivy_cache_dir)" || return 3
    cache_dir="$(_ci_record_field "${cache_rec}" dir)"
    fresh_rec="$(_ci_trivy_db_ensure_fresh "${cache_dir}")" || return 3
    [ "$(_ci_record_field "${fresh_rec}" present)" = "true" ] && skip_db=1
    ref="ghcr.io/$(_ci_repo)/${service}@${digest}"
    report="$(mktemp "${TMPDIR:-/var/tmp}/ci-trivy.XXXXXX")"
    local -a targs=(trivy image --severity "HIGH,CRITICAL" --exit-code 1
        --ignore-unfixed --scanners "${scanners}" --cache-dir "${cache_dir}")
    [ "${skip_db}" -eq 1 ] && targs+=(--skip-db-update)
    [ -f "${ignore}" ] && targs+=(--trivyignores "${ignore}")
    [ -n "${CI_TRIVY_TIMEOUT:-}" ] && targs+=(--timeout "${CI_TRIVY_TIMEOUT}")
    while :; do
        n=$((n + 1))
        : > "${report}"
        if raw="$("${targs[@]}" --output "${report}" "${ref}" 2>&1)"; then
            rm -f "${report}"
            return 0
        fi
        # What: A written report means trivy scanned.
        # Why: A finding is deterministic; no retry.
        # From: Issue #1683
        if [ -s "${report}" ]; then
            cat "${report}" >&2
            rm -f "${report}"
            return 1
        fi
        if [ "$(_ci_trivy_error_kind "${raw}")" = "db-missing" ] && [ "${n}" -lt "${max}" ]; then
            sleep "${CI_TRIVY_BACKOFF:-$((n * n))}"
            continue
        fi
        rm -f "${report}"
        printf '%s\n' "${raw}" >&2
        return 3
    done
}

# What: Run the real (or injected) image build+push.
# Why: injected for tests; docker buildx is the default.
# From: Issue #1683
_ci_do_build() {
    local service="$1" identity="$2" platform="$3"
    if [ -n "${CI_BUILD_CMD:-}" ]; then
        "${CI_BUILD_CMD}" "${service}" "${identity}" "${platform}"
        return "$?"
    fi
    _ci_docker_build "${service}" "${identity}" "${platform}"
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
    action="$(_ci_record_field "${resolved}" action)"
    identity="$(_ci_record_field "${resolved}" identity)"
    state="$(_ci_record_field "${resolved}" state)"
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
    if [ -n "${CI_PUBLISH_CMD:-}" ]; then
        digest="$("${CI_PUBLISH_CMD}" "${service}" "${identity}" "${platform}")" || {
            ci_log "[CI-ERROR-PUBLISH-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"publish backend failed\""
            return 2
        }
    else
        digest="$(_ci_docker_publish "${service}" "${identity}" "${platform}")" || {
            ci_log "[CI-ERROR-PUBLISH-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"docker publish failed\""
            return 2
        }
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
    local service="${1:-}" expected="${2:-}" platform="${3:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-VERIFY-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${expected}" ] || { ci_log "[CI-ERROR-VERIFY-0002]" "reason=\"expected digest arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local seen identity tag
    if [ -n "${CI_READBACK_CMD:-}" ]; then
        seen="$("${CI_READBACK_CMD}" "${service}")" || {
            ci_log "[CI-ERROR-VERIFY-0003]" "service=\"${service}\" reason=\"readback failed\""
            return 2
        }
    else
        [ -n "${platform}" ] || { ci_log "[CI-ERROR-VERIFY-0004]" "service=\"${service}\" reason=\"platform arg required for default readback\""; return 2; }
        identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
        tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")"
        seen="$(_ci_registry_digest "${tag}")" || {
            ci_log "[CI-ERROR-VERIFY-0003]" "service=\"${service}\" reason=\"readback failed\""
            return 2
        }
    fi
    if [ "${seen}" != "${expected}" ]; then
        ci_error "[CI-ERROR-VERIFY-0005]" "service=\"${service}\" reason=\"digest MISMATCH; produced != accepted\" expected=\"${expected}\"" "readback=${seen}"
        return 2
    fi
    printf 'service=%s verified=%s\n' "${service}" "${seen}"
}

# What: Run AG-VAL-008 cargo checks for a rust service.
# Why: fmt/check/clippy/test run nowhere else in ci.sh.
# From: Issue #1683 | PR #1858
_ci_test_rust() {
    local service="$1" ctx
    if [ -n "${CI_RUST_TEST_CMD:-}" ]; then
        "${CI_RUST_TEST_CMD}" "${service}"
        return "$?"
    fi
    ctx="$(ci_service_field "${service}" context)"
    if [ -z "${ctx}" ]; then
        ci_log "[CI-ERROR-TEST-0005]" "service=\"${service}\" reason=\"no context in SOT\""
        return 2
    fi
    ( cd "${CI_REPO_ROOT:-.}/${ctx}" \
        && cargo fmt --check \
        && cargo check \
        && cargo clippy -- -D warnings \
        && cargo test ) || return 1
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Assert every smoke tool exists in the image.
# Why: A missing accel tool must fail, not build broken.
# From: Issue #1683
_ci_toolchain_smoke() {
    local image="$1" tools="$2"
    local -a tl=()
    local t
    while IFS= read -r t; do
        [ -n "${t}" ] && tl+=("${t}")
    done <<< "${tools}"
    docker run --rm "${image}" timeout --kill-after=30s --signal=TERM 14m \
        sh -c 'for t in "$@"; do command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }; done' _ "${tl[@]}"
}

# What: Smoke the build-tools image tool inventory.
# Why: The SOT owns the list; ci.sh runs it in the image.
# From: Issue #1683 | PR #1858
_ci_test_toolchain() {
    local service="$1" image tools
    if [ -n "${CI_TOOLCHAIN_TEST_CMD:-}" ]; then
        "${CI_TOOLCHAIN_TEST_CMD}" "${service}"
        return "$?"
    fi
    image="${CI_TOOLCHAIN_IMAGE:-}"
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-TEST-0006]" "service=\"${service}\" reason=\"CI_TOOLCHAIN_IMAGE required for the smoke\""
        return 2
    fi
    tools="$(_ci_build_tools_smoke_tools)" || return 2
    _ci_toolchain_smoke "${image}" "${tools}" || return 1
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Dispatch a service's test by its build type.
# Why: rust runs cargo; apk has no unit test to run.
# From: Issue #1683 | PR #1858
_ci_default_test() {
    local service="$1" build_type
    build_type="$(ci_service_field "${service}" build_type)"
    [ -n "${build_type}" ] || build_type="toolchain"
    case "${build_type}" in
        rust) _ci_test_rust "${service}" ;;
        apk|install) printf 'service=%s tested=SKIP build_type=%s reason=no unit test; runtime in validate\n' "${service}" "${build_type}" ;;
        toolchain) _ci_test_toolchain "${service}" ;;
        *) ci_log "[CI-ERROR-TEST-0004]" "service=\"${service}\" build_type=\"${build_type}\" reason=\"unknown build_type\""; return 2 ;;
    esac
}

# What: Run a service's tests via the wired backend.
# Why: A failed test run is a failed run, never skipped.
# From: Issue #1683
ci_cmd_test() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-TEST-0001]" "reason=\"service arg required\""; return 2; }
    local raw status
    if raw="$("${CI_TEST_CMD:-_ci_default_test}" "${service}" 2>&1)"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-TEST-0003]" "service=\"${service}\" reason=\"tests failed\" retry=$(_ci_classify_failure "${raw}")" "${raw}"
        return 2
    fi
    printf '%s\n' "${raw}"
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
    local scan_cmd="${CI_SCAN_CMD:-_ci_trivy_scan}"
    local raw status
    if raw="$(TMPDIR="${scan_tmp}" "${scan_cmd}" "${service}" "${digest}" 2>&1)"; then status=0; else status=$?; fi
    # What: DB-unavailable is not a finding; escalate it.
    # Why: A DB outage must not read as a finding.
    # From: Issue #1683
    if [ "${status}" -eq 3 ]; then
        ci_error "[CI-ERROR-SCAN-0006]" "service=\"${service}\" reason=\"scan DB unavailable after retries; not a finding, escalate\"" "${raw}"
        return 3
    fi
    if [ "${status}" -ne 0 ]; then
        ci_error "[CI-ERROR-SCAN-0005]" "service=\"${service}\" reason=\"scan reported findings\"" "${raw}"
        return 2
    fi
    printf 'service=%s scanned=clean digest=%s tmpdir=%s\n' "${service}" "${digest}" "${scan_tmp}"
}

# =========================================================
# ASSEMBLY
# =========================================================

# What: Look up an ACCEPTED per-platform digest.
# Why: The digest source is the ledger; a mock swaps it.
# From: Issue #1683
_ci_accepted_digest() {
    local service="$1" platform="$2"
    if [ -n "${CI_ACCEPTED_DIGEST_CMD:-}" ]; then
        "${CI_ACCEPTED_DIGEST_CMD}" "${service}" "${platform}"
        return "$?"
    fi
    local identity rec rc=0
    identity="$(_ci_identity_for "${service}" "${platform}")" || return 2
    rec="$(_ci_ledger_read "$(_ci_ledger_remote)" "${identity}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    [ "$(printf '%s' "${rec}" | cut -f1)" = ACCEPTED ] || return 1
    printf '%s' "${rec}" | cut -f2
}

# What: Inspect an index raw; 1 not-found, 2 unknown.
# Why: One reader; transient must not read as absent.
# From: Issue #1683
_ci_index_raw() {
    local ref="$1" raw rc=0
    raw="$(docker buildx imagetools inspect "${ref}" --raw 2>&1)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        [ "$(_ci_classify_failure "${raw}")" = not_found ] && return 1
        return 2
    fi
    printf '%s' "${raw}"
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
    local repo sha tag idx grc=0 raw plats
    repo="$(_ci_repo)"
    sha="${GITHUB_SHA:?GITHUB_SHA required}"
    tag="ghcr.io/${repo}/${service}:sha-${sha}"
    idx="$(_ci_registry_probe "${tag}")" || grc=$?
    [ "${grc}" -eq 0 ] || return 1
    raw="$(_ci_index_raw "${tag}")" || return 1
    plats="$(printf '%s' "${raw}" | jq -r '.manifests[]? | select(.platform.os=="linux" and .platform.architecture!="unknown") | "linux/\(.platform.architecture)=\(.digest)"' | tr '\n' ' ')"
    printf '%s %s\n' "${idx}" "${plats% }"
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

# What: Merge accepted per-platform digests into an index.
# Why: Default assemble backend; shares the index writer.
# From: Issue #1683
_ci_docker_assemble() {
    local service="$1"; shift
    local repo sha target kv
    repo="$(_ci_repo)"
    sha="${GITHUB_SHA:?GITHUB_SHA required}"
    target="ghcr.io/${repo}/${service}:sha-${sha}"
    local -a srcs=()
    for kv; do
        srcs+=("ghcr.io/${repo}/${service}@${kv#*=}")
    done
    _ci_imagetools_create "${target}" "${srcs[@]}" >/dev/null || return "$?"
    _ci_registry_digest "${target}"
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
    local asm_cmd="${CI_ASSEMBLE_CMD:-_ci_docker_assemble}"
    if ! index="$("${asm_cmd}" "${service}" ${inputs})"; then
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

# What: The per-channel promotion lock ref.
# Why: serialize movers of one channel (§52).
# From: Issue #1683
_ci_promote_lock_ref() {
    printf 'refs/ci/promote-lock/%s' "$1"
}

# What: Default promote lock: take the channel lock.
# Why: the cross-host CAS mutex, reused for promotion.
# From: Issue #1683
_ci_default_promote_lock() {
    _ci_lock_acquire "$(_ci_ledger_remote)" "$(_ci_promote_lock_ref "$1")" "promote $1 run=${GITHUB_RUN_ID:-local}" 30 10 900
}

# What: Default promote unlock: free the channel lock.
# Why: the same holder note the acquire path used.
# From: Issue #1683
_ci_default_promote_unlock() {
    _ci_lock_release "$(_ci_ledger_remote)" "$(_ci_promote_lock_ref "$1")" "promote $1 run=${GITHUB_RUN_ID:-local}"
}

# What: Default channel move: point svc:channel at digest.
# Why: shares the one index writer; moves, never builds.
# From: Issue #1683
_ci_default_channel_move() {
    local svc="$1" channel="$2" digest="$3" repo
    repo="$(_ci_repo)"
    _ci_imagetools_create "ghcr.io/${repo}/${svc}:${channel}" "ghcr.io/${repo}/${svc}@${digest}" >/dev/null
}

# What: Default channel readback: the channel's digest.
# Why: one digest reader; empty output means unknown.
# From: Issue #1683
_ci_default_channel_readback() {
    local svc="$1" channel="$2" repo
    repo="$(_ci_repo)"
    _ci_registry_digest "ghcr.io/${repo}/${svc}:${channel}" 2>/dev/null
}

# What: Resolve the move backend, mock or default.
# Why: one dispatch point for the channel move.
# From: Issue #1683
_ci_promote_move() {
    "${CI_PROMOTE_MOVE_CMD:-_ci_default_channel_move}" "$@"
}

# What: Resolve the readback backend, mock or default.
# Why: one dispatch point for the channel readback.
# From: Issue #1683
_ci_channel_readback() {
    "${CI_CHANNEL_READBACK_CMD:-_ci_default_channel_readback}" "$@"
}

# What: Move every candidate ref and read each back.
# Why: One locked section; the caller always unlocks.
# From: Issue #1683
_ci_promote_move_all() {
    local channel="$1" cand="$2" line svc digest seen
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; digest="${line#*=}"
        if ! _ci_promote_move "${svc}" "${channel}" "${digest}"; then
            ci_log "[CI-ERROR-PROMOTE-0007]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel ref move failed\""
            return 2
        fi
        seen="$(_ci_channel_readback "${svc}" "${channel}")" || seen=""
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
        if ! grep -q "^${svc}=" <<< "${cand}"; then
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
        seen="$(_ci_channel_readback "${svc}" "${channel}")" || seen=""
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
    if _ci_promote_all_current "${channel}" "${cand}"; then
        printf 'channel=%s result=already-promoted services=%s\n' "${channel}" "$(printf '%s\n' "${cand}" | grep -c '=')"
        return 0
    fi
    if ! "${CI_PROMOTE_LOCK_CMD:-_ci_default_promote_lock}" "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0010]" "channel=\"${channel}\" reason=\"could not acquire promotion lock\""
        return 2
    fi
    # What: capture rc so the unlock still runs on failure.
    # Why: a failed move must never leak the promotion lock.
    local rc
    if _ci_promote_move_all "${channel}" "${cand}"; then rc=0; else rc=$?; fi
    "${CI_PROMOTE_UNLOCK_CMD:-_ci_default_promote_unlock}" "${channel}" || ci_log "[CI-WARN-PROMOTE-0011]" "channel=\"${channel}\" reason=\"lock release failed\""
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

# What: Emit the transitive protected-root digest set.
# Why: Ledger + channels + their index children (§101).
# From: Issue #1683
_ci_default_gc_roots() {
    local remote repo blob rc=0 pairs="" out="" svc channel dig prc line s d raw
    remote="$(_ci_ledger_remote)"
    repo="$(_ci_repo)"
    blob="$(_ci_ledger_blob "${remote}")" || rc=$?
    # What: A failed ledger read refuses, never empties.
    # Why: UNKNOWN roots would delete live artifacts.
    # From: Issue #1683
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-GC-0012]" "reason=\"ledger read UNKNOWN; refusing empty roots\""
        return 2
    fi
    # What: Every ledger record is a root, all states.
    # Why: PRODUCED_UNVERIFIED is pending, not garbage.
    # From: Issue #1683
    [ "${rc}" -eq 0 ] && pairs="$(printf '%s\n' "${blob}" | awk -F'\t' 'NF>=5 && $2!="" && $5!="" {print $2"\t"$5}')"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        while IFS= read -r channel; do
            [ -n "${channel}" ] || continue
            prc=0
            dig="$(_ci_registry_probe "ghcr.io/${repo}/${svc}:${channel}")" || prc=$?
            # What: A transient probe refuses the run.
            # Why: A flaky miss must not drop a channel.
            # From: Issue #1683
            [ "${prc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0013]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel probe UNKNOWN; refusing roots\""; return 2; }
            [ "${prc}" -eq 0 ] && pairs="${pairs}"$'\n'"${svc}"$'\t'"${dig}"
        done < <(_ci_mutable_channels)
    done < <(ci_services)
    pairs="$(printf '%s\n' "${pairs}" | awk 'NF>0' | LC_ALL=C sort -u)"
    while IFS=$'\t' read -r s d; do
        [ -n "${d}" ] || continue
        out="${out}${d}"$'\n'
        rc=0
        raw="$(_ci_index_raw "ghcr.io/${repo}/${s}@${d}")" || rc=$?
        # What: A transient child read refuses the run.
        # Why: Dropping children orphan-deletes arches.
        # From: Issue #1683
        [ "${rc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0014]" "service=\"${s}\" digest=\"${d}\" reason=\"index child read UNKNOWN; refusing roots\""; return 2; }
        [ "${rc}" -eq 0 ] && out="${out}$(printf '%s' "${raw}" | jq -r '.manifests[]? | select(.platform.architecture!="unknown") | .digest')"$'\n'
    done <<< "${pairs}"
    printf '%s\n' "${out}" | awk 'NF>0' | LC_ALL=C sort -u
}

# What: List protected GC roots (injectable backend).
# Why: Empty roots must fail, not mark all unreachable.
# From: Issue #1683
_ci_gc_roots() {
    "${CI_GC_ROOTS_CMD:-_ci_default_gc_roots}"
}

# What: List a package's versions; 1 not-found, 2 unknown.
# Why: One discriminating GHCR reader; 404 is not transient.
# From: Issue #1683
_ci_gh_versions() {
    local owner="$1" pkg="$2" out rc=0
    # What: retry a transient GH-API read; 404 fails on attempt 1.
    # Why: op=github-api classifies HTTP 404 permanent, not not_found.
    # From: Issue #1683
    out="$(_ci_retry github-api gh api --paginate "/orgs/${owner}/packages/container/${pkg}/versions?per_page=100" --jq '.[] | [.name, .id, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv')" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '%s' "${out}" | grep -qiE 'HTTP 404|Not Found' && return 1
        ci_error "[CI-ERROR-GC-0018]" "owner=\"${owner}\" pkg=\"${pkg}\" reason=\"GHCR version listing failed\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: Enumerate GHCR versions of every built package.
# Why: SOT-scoped candidates; org-wide would delete others.
# From: Issue #1683
_ci_default_gc_candidates() {
    local prefix owner pkgbase svc vers grc found=0
    prefix="$(_ci_manifest_scalar '^  image_prefix:[[:space:]]')"
    [ -n "${prefix}" ] || { ci_log "[CI-ERROR-GC-0017]" "reason=\"SOT image_prefix missing\""; return 2; }
    owner="${prefix%%/*}"
    pkgbase="${prefix#*/}"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        grc=0
        # What: A 404 package is skipped, not a failure.
        # Why: External services (netdata) have no package.
        # From: Issue #1683
        vers="$(_ci_gh_versions "${owner}" "${pkgbase}%2F${svc}")" || grc=$?
        [ "${grc}" -eq 2 ] && return 2
        [ "${grc}" -eq 1 ] && continue
        found=$((found + 1))
        # What: Append the service so delete can target it.
        # Why: Delete path is package-scoped, not id-only.
        # From: Issue #1683
        [ -n "${vers}" ] && printf '%s\n' "${vers}" | awk -v s="${svc}" 'NF{print $0"\t"s}'
    done < <(ci_build_targets)
    # What: No package found anywhere is a config error.
    # Why: All-404 must refuse, not read as a clean noop.
    # From: Issue #1683
    [ "${found}" -gt 0 ] || { ci_log "[CI-ERROR-GC-0020]" "reason=\"no GHCR package for any target; check image_prefix/owner/token\""; return 2; }
}

# What: Delete one GHCR version by id (destructive).
# Why: The one delete surface; package-scoped by service.
# From: Issue #1683
_ci_default_gc_delete() {
    local candidate="$1" id svc prefix owner pkgbase
    id="$(printf '%s' "${candidate}" | awk -F'\t' '{print $2}')"
    svc="$(printf '%s' "${candidate}" | awk -F'\t' '{print $5}')"
    case "${id}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-GC-0019]" "candidate=\"${candidate}\" reason=\"no numeric version id\""
            return 2
            ;;
    esac
    [ -n "${svc}" ] || { ci_log "[CI-ERROR-GC-0019]" "candidate=\"${candidate}\" reason=\"no service for delete path\""; return 2; }
    prefix="$(_ci_manifest_scalar '^  image_prefix:[[:space:]]')"
    [ -n "${prefix}" ] || { ci_log "[CI-ERROR-GC-0017]" "reason=\"SOT image_prefix missing\""; return 2; }
    owner="${prefix%%/*}"
    pkgbase="${prefix#*/}"
    # What: retry a transient GH-API delete.
    # Why: a destructive op still deserves the shared classifier.
    # From: Issue #1683
    _ci_retry github-api gh api -X DELETE "/orgs/${owner}/packages/container/${pkgbase}%2F${svc}/versions/${id}" >/dev/null
}

# What: List GC candidate artifacts (injectable backend).
# Why: GHCR enumeration is the candidate truth (§97).
# From: Issue #1683
_ci_gc_candidates() {
    "${CI_GC_CANDIDATES_CMD:-_ci_default_gc_candidates}"
}

# What: Classify a candidate against the root digest set.
# Why: Membership or recency floor decides; else garbage.
# From: Issue #1683
_ci_default_gc_reachable() {
    local candidate="$1" digest created window created_epoch now floor
    digest="$(printf '%s' "${candidate}" | awk -F'\t' '{print $1}')"
    created="$(printf '%s' "${candidate}" | awk -F'\t' '{print $3}')"
    # What: Roots must be materialized by the caller.
    # Why: No roots file means we cannot judge; refuse.
    # From: Issue #1683
    { [ -n "${CI_GC_ROOTS_FILE:-}" ] && [ -f "${CI_GC_ROOTS_FILE}" ]; } || return 2
    if grep -qxF "${digest}" "${CI_GC_ROOTS_FILE}"; then
        printf 'referenced\n'
        return 0
    fi
    # What: An attestation is live iff its subject is.
    # Why: sha256-<subj> referrers guard live provenance.
    # From: Issue #1683
    local tags tag subj
    tags="$(printf '%s' "${candidate}" | awk -F'\t' '{print $4}')"
    if [ -n "${tags}" ]; then
        while IFS= read -r tag; do
            case "${tag}" in
                sha256-*)
                    subj="sha256:${tag#sha256-}"; subj="${subj%%.*}"
                    grep -qxF "${subj}" "${CI_GC_ROOTS_FILE}" && { printf 'referenced\n'; return 0; }
                    ;;
            esac
        done <<< "$(printf '%s' "${tags}" | tr ',' '\n')"
    fi
    # What: Fail closed unless grace is a positive integer.
    # Why: Empty grace makes floor=now and deletes all.
    # From: Issue #1683
    window="$(_ci_manifest_scalar '^[[:space:]]+unaggregated_grace_minutes:[[:space:]]')"
    case "${window}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-GC-0015]" "value=\"${window}\" reason=\"unaggregated_grace_minutes not a positive integer\""
            return 2
            ;;
    esac
    [ "${window}" -gt 0 ] || { ci_log "[CI-ERROR-GC-0015]" "value=\"${window}\" reason=\"grace must be greater than zero\""; return 2; }
    # What: A candidate needs created_at for the floor.
    # Why: No timestamp is UNKNOWN, never a delete.
    # From: Issue #1683
    [ -n "${created}" ] || { ci_log "[CI-ERROR-GC-0016]" "digest=\"${digest}\" reason=\"missing created_at; cannot apply recency floor\""; return 2; }
    created_epoch="$(date -d "${created}" +%s 2>/dev/null)" || created_epoch=""
    case "${created_epoch}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-GC-0016]" "created=\"${created}\" reason=\"created_at unparseable\""
            return 2
            ;;
    esac
    now="$(date +%s)"
    floor=$(( now - window * 60 ))
    [ "${created_epoch}" -ge "${floor}" ] && { printf 'referenced\n'; return 0; }
    printf 'unreachable\n'
}

# What: Probe one candidate against the OCI ref graph.
# Why: Registry truth, not SQLite, decides reachability.
# From: Issue #1683
_ci_gc_reachable() {
    local candidate="$1"
    "${CI_GC_REACHABLE_CMD:-_ci_default_gc_reachable}" "${candidate}"
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
    local mode="dry-run" arg roots rc=0
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
    # What: Materialize roots once for the default probe.
    # Why: One read; avoids re-deriving roots per candidate.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="$(mktemp "${TMPDIR:-/var/tmp}/ci-gc-roots.XXXXXX")" || return 2
    export CI_GC_ROOTS_FILE
    printf '%s\n' "${roots}" | awk 'NF>0' > "${CI_GC_ROOTS_FILE}"
    _ci_gc_run "${mode}" || rc=$?
    rm -f "${CI_GC_ROOTS_FILE}"
    unset CI_GC_ROOTS_FILE
    return "${rc}"
}

# What: Classify and, in apply mode, delete candidates.
# Why: Wrapper owns the roots file; this owns the policy.
# From: Issue #1683
_ci_gc_run() {
    local mode="$1" cands line action policy
    local del=0 keep=0 deleted=0 to_delete=""
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
            if ! "${CI_GC_DELETE_CMD:-_ci_default_gc_delete}" "${line}"; then
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

# What: Print the SOT DNS test domains, one per line.
# Why: Real dig targets live in the SOT, not in code.
# From: Issue #1683 | PR #1858
_ci_validation_dns_domains() {
    _ci_block_entry_list validation "" dns_test_domains
}

# What: Print the SOT proxy cache-probe URL.
# Why: One cacheable HTTP target proves the HIT path.
# From: Issue #1683 | PR #1858
_ci_validation_proxy_probe_url() {
    _ci_manifest_scalar '^  proxy_cache_probe_url:[[:space:]]'
}

# What: Emit "service<TAB>image" for each compose service.
# Why: Injectable so pin/drift needs no daemon in tests.
# From: Issue #1683 | PR #1858
_ci_validate_compose_images() {
    if [ -n "${CI_COMPOSE_IMAGES_CMD:-}" ]; then
        "${CI_COMPOSE_IMAGES_CMD}"
        return "$?"
    fi
    docker compose -f "${CI_COMPOSE_FILE:-deploy/prod/docker-compose.yml}" config --format json \
        | jq -r '.services | to_entries[] | [.key, .value.image] | @tsv'
}

# What: Warn on candidates without a first-party image.
# Why: Third-party images stay visible, never silent.
# From: Issue #1683 | PR #1858
_ci_validate_report_unpinned() {
    local candidate="$1" matched="$2" slug _digest
    while IFS='=' read -r slug _digest; do
        [ -n "${slug}" ] || continue
        case "${matched}" in
            *" ${slug} "*) : ;;
            *) ci_log "[CI-WARN-VALIDATE-0008]" "unpinned=\"${slug}\" reason=\"third-party-compose-image\"" ;;
        esac
    done <<< "${candidate}"
}

# What: Print a compose override pinning first-party images.
# Why: Validate candidate digests, never a mutable :latest.
# From: Issue #1683 | PR #1858
_ci_validate_pin_override() {
    local candidate="$1" prefix images svc image slug digest reg matched=" "
    prefix="$(_ci_manifest_scalar '^  image_prefix:[[:space:]]')"
    if [ -z "${prefix}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0005]" "reason=\"no image_prefix in SOT\""
        return 2
    fi
    if ! images="$(_ci_validate_compose_images)"; then
        ci_log "[CI-ERROR-VALIDATE-0006]" "reason=\"compose config read failed\""
        return 2
    fi
    printf 'services:\n'
    while IFS=$'\t' read -r svc image; do
        [ -n "${svc}" ] && [ -n "${image}" ] || continue
        case "${image}" in
            *"/${prefix}/"*)
                slug="${image##*/"${prefix}"/}"
                slug="${slug%%:*}"
                slug="${slug%%@*}"
                digest="$(printf '%s\n' "${candidate}" | awk -F= -v s="${slug}" '$1==s{print $2; exit}')"
                if [ -z "${digest}" ]; then
                    ci_log "[CI-ERROR-VALIDATE-0007]" "service=\"${svc}\" slug=\"${slug}\" reason=\"first-party compose image without candidate digest; refusing mutable tag\""
                    return 2
                fi
                reg="${image%%/"${prefix}"/*}"
                printf '  %s:\n    image: %s/%s/%s@%s\n' "${svc}" "${reg}" "${prefix}" "${slug}" "${digest}"
                matched="${matched}${slug} "
                ;;
            *) : ;;
        esac
    done <<< "${images}"
    _ci_validate_report_unpinned "${candidate}" "${matched}"
}

# What: Seed a validate reservation attempt.
# Why: attempt 1 unsalted; a retry re-slots.
# From: Issue #1683
_ci_validate_seed() {
    local run_id="$1" run_attempt="$2" n="$3"
    if [ "${n}" -le 1 ]; then
        printf '%s-%s' "${run_id}" "${run_attempt}"
    else
        printf '%s-%s-retry%s' "${run_id}" "${run_attempt}" "${n}"
    fi
}

# What: Derive a collision-free /27 in 172.16/12.
# Why: The full private B block gives ~32k /27 slots.
# From: Issue #1683
_ci_validate_subnet() {
    local seed="$1" h o2 o3 sub
    h="$(printf '%s' "${seed}" | sha256sum)"
    o2=$(( 16 + (16#$(printf '%s' "${h}" | cut -c1-4) % 16) ))
    o3=$(( 16#$(printf '%s' "${h}" | cut -c5-10) % 256 ))
    sub=$(( 16#$(printf '%s' "${h}" | cut -c11-12) % 8 ))
    printf '172.%s.%s.%s/27' "${o2}" "${o3}" "$(( sub * 32 ))"
}

# What: Host-lock one /27; print the holder pid.
# Why: Per-slot flock; runs never share a /27.
# From: Issue #1683
_ci_validate_slot_lock() {
    local subnet="$1" root key holder
    root="${TMPDIR:-/var/tmp}/ci-validate-locks"
    key="$(printf '%s' "${subnet}" | tr './' '__')"
    mkdir -p "${root}"
    (
        exec >/dev/null 2>&1
        exec 9>"${root}/${key}.lock"
        flock -n 9 || exit 1
        exec sleep infinity
    ) &
    holder=$!
    sleep 0.3
    if kill -0 "${holder}" 2>/dev/null; then
        printf '%s\n' "${holder}"
        return 0
    fi
    wait "${holder}" 2>/dev/null || true
    return 1
}

# What: Release a held validate slot lock.
# Why: Frees the mutex; safe if already gone.
# From: Issue #1683
_ci_validate_release() {
    local holder="${1:-}"
    [ -n "${holder}" ] || return 0
    kill "${holder}" 2>/dev/null || true
    wait "${holder}" 2>/dev/null || true
}

# What: Convert an IPv4 address to an integer.
# Why: Integer masking proves a /27 overlap.
# From: Issue #1683
_ci_ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%s' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

# What: True if a /27 overlaps a live network.
# Why: CIDR overlap by integer mask; no python.
# From: Issue #1683
_ci_validate_subnet_conflicts() {
    local target="$1" tip tm net sub sip sm m
    tip="$(_ci_ipv4_to_int "${target%/*}")"
    tm="${target#*/}"
    while IFS= read -r net; do
        [ -n "${net}" ] || continue
        while IFS= read -r sub; do
            case "${sub}" in
                *.*.*.*/*)
                    sip="$(_ci_ipv4_to_int "${sub%/*}")"
                    sm="${sub#*/}"
                    m=$(( tm < sm ? tm : sm ))
                    if [ "$(( tip >> (32 - m) ))" = "$(( sip >> (32 - m) ))" ]; then
                        printf '%s\n' "${sub}"
                        return 0
                    fi
                    ;;
            esac
        done < <(docker network inspect "${net}" --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null)
    done < <(docker network ls -q 2>/dev/null)
    return 1
}

# What: Reserve a free /27; print subnet + holder.
# Why: Retry a fresh slot on a locked candidate.
# From: Issue #1683
_ci_validate_reserve() {
    local run_id run_attempt max n seed subnet holder
    run_id="${GITHUB_RUN_ID:-$$}"
    run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
    max="${CI_VALIDATE_MAX_SLOTS:-10}"
    for (( n=1; n<=max; n++ )); do
        seed="$(_ci_validate_seed "${run_id}" "${run_attempt}" "${n}")"
        subnet="$(_ci_validate_subnet "${seed}")"
        _ci_validate_subnet_conflicts "${subnet}" >/dev/null 2>&1 && continue
        if holder="$(_ci_validate_slot_lock "${subnet}")"; then
            printf 'subnet=%s holder=%s\n' "${subnet}" "${holder}"
            return 0
        fi
    done
    return 1
}

# What: The per-run validation project name.
# Why: A per-slot project isolates its /27 net.
# From: Issue #1683
_ci_validate_project() {
    printf 'lancache-ng-validate-%s' "$(printf '%s' "${1}" | tr './' '__')"
}

# What: The resolved compose config as JSON.
# Why: One source; every service list derives from it.
# From: Issue #1683
_ci_validate_config_json() {
    if [ -n "${CI_COMPOSE_CONFIG_CMD:-}" ]; then
        "${CI_COMPOSE_CONFIG_CMD}"
        return "$?"
    fi
    docker compose -f "${CI_COMPOSE_FILE:-deploy/prod/docker-compose.yml}" config --format json
}

# What: Compose service names passing one jq filter.
# Why: One owner; startable + health lists share it.
# From: Issue #1683
_ci_validate_service_list() {
    local filter="$1"
    _ci_validate_config_json | jq -r ".services|to_entries[]|select(${filter})|.key"
}

# What: Services validate starts: bridge, never host-mode.
# Why: host-mode host-port bindings cannot be isolated.
# From: Issue #1683
_ci_validate_startable() {
    _ci_validate_service_list '.value.network_mode != "host"'
}

# What: Override that isolates the stack in one /27.
# Why: Per-run subnet; reset host ports + fixed names.
# From: Issue #1683
_ci_validate_net_override() {
    local subnet="$1" svc
    printf 'networks:\n  default:\n    ipam:\n      config:\n        - subnet: %s\n' "${subnet}"
    printf 'services:\n'
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        printf '  %s:\n    container_name: !reset null\n    ports: !reset []\n' "${svc}"
    done < <(_ci_validate_startable)
}

# What: The /27 IP of a compose service container.
# Why: Checks target the runtime IP, never a fixed one.
# From: Issue #1683
_ci_validate_container_ip() {
    local project="$1" svc="$2" net cid ip
    net="${project}_default"
    cid="$(docker compose -p "${project}" ps -q "${svc}" 2>/dev/null)"
    [ -n "${cid}" ] || return 1
    ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${cid}" 2>/dev/null)"
    case "${ip}" in
        *.*.*.*) printf '%s' "${ip}" ;;
        *) return 1 ;;
    esac
}

# What: Wait until a network has no containers.
# Why: rm before detach hits 'active endpoints'.
# From: Issue #1683 | PR #1858
_ci_validate_await_detached() {
    local name="$1" deadline count
    deadline=$(( SECONDS + ${CI_VALIDATE_DETACH_TIMEOUT:-30} ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        count="$(docker network inspect "${name}" --format '{{len .Containers}}' 2>/dev/null)" || return 0
        [ "${count}" = "0" ] && return 0
        sleep 1
    done
    return 1
}

# What: Remove one validation network safely.
# Why: Await detach; a stale net poisons reruns.
# From: Issue #1683 | PR #1858
_ci_validate_network_teardown() {
    local net_id="$1" name
    name="$(docker network inspect "${net_id}" --format '{{.Name}}' 2>/dev/null)" || return 0
    _ci_validate_await_detached "${name}" || true
    docker network rm "${name}" >/dev/null 2>&1 || true
}

# What: True for a retryable subnet collision.
# Why: Distinct from a real image/config fail.
# From: Issue #1683 | PR #1858
_ci_validate_is_collision() {
    case "$1" in
        *"Pool overlaps"*|*"already in use"*) return 0 ;;
    esac
    return 1
}

# What: Tear the stack down and free the slot.
# Why: One cleanup point; runs on the fail path.
# From: Issue #1683 | PR #1858
_ci_validate_teardown() {
    local holder="$1" project="$2" net_id
    docker compose -p "${project}" \
        -f "${CI_COMPOSE_FILE:-deploy/prod/docker-compose.yml}" \
        down -v --remove-orphans >/dev/null 2>&1 || true
    while IFS= read -r net_id; do
        [ -n "${net_id}" ] || continue
        _ci_validate_network_teardown "${net_id}"
    done < <(docker network ls --filter "label=com.docker.compose.project=${project}" -q 2>/dev/null)
    _ci_validate_release "${holder}"
}

# What: Bring the isolated prod stack up detached.
# Why: net override /27-isolates; pin override pins.
# From: Issue #1683 | PR #1858
_ci_validate_up() {
    local project="$1" net_override="$2" pin_override="$3" svc
    local -a svcs=()
    while IFS= read -r svc; do
        [ -n "${svc}" ] && svcs+=("${svc}")
    done < <(_ci_validate_startable)
    if [ "${#svcs[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0018]" "reason=\"no startable services from compose config\""
        return 2
    fi
    docker compose -p "${project}" \
        -f "${CI_COMPOSE_FILE:-deploy/prod/docker-compose.yml}" \
        -f "${net_override}" -f "${pin_override}" up -d "${svcs[@]}"
}

# What: Started services that also have a healthcheck.
# Why: Poll only what up started; skip host-mode.
# From: Issue #1683
_ci_validate_health_services() {
    _ci_validate_service_list \
        '.value.network_mode != "host" and .value.healthcheck != null'
}

# What: Started services with no healthcheck defined.
# Why: These still need crash-loop coverage (AG-VAL-027).
# From: Issue #1683
_ci_validate_no_health_services() {
    _ci_validate_service_list \
        '.value.network_mode != "host" and .value.healthcheck == null'
}

# What: Wait for one container to report healthy.
# Why: A crash-loop only shows after up exits 0.
# From: Issue #1683 | PR #1858
_ci_validate_wait_one() {
    local project="$1" svc="$2" deadline cid status
    deadline=$(( SECONDS + ${CI_VALIDATE_HEALTH_TIMEOUT:-180} ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        cid="$(docker compose -p "${project}" ps -q "${svc}" 2>/dev/null)"
        if [ -n "${cid}" ]; then
            status="$(docker inspect --format '{{.State.Health.Status}}' "${cid}" 2>/dev/null)" || status=""
            [ "${status}" = "healthy" ] && return 0
            [ "${status}" = "unhealthy" ] && return 1
        fi
        sleep 2
    done
    return 1
}

# What: Wait for a no-healthcheck service to settle.
# Why: Crash-loop signal is Status, never RestartCount.
# From: Issue #1683
_ci_validate_wait_stable() {
    local project="$1" svc="$2" deadline cid status started exitcode
    local prev_started="" stable_since=-1
    local window="${CI_VALIDATE_STABLE_WINDOW:-20}"
    deadline=$(( SECONDS + ${CI_VALIDATE_HEALTH_TIMEOUT:-180} ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        cid="$(docker compose -p "${project}" ps -q "${svc}" 2>/dev/null)"
        if [ -z "${cid}" ]; then
            stable_since=-1
            sleep 2
            continue
        fi
        status="$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null)" || status=""
        # What: exit is terminal, not a crash-loop.
        # Why: restart:no exits 0 by design (AG-VAL-027).
        # From: Issue #1683
        if [ "${status}" = "exited" ]; then
            exitcode="$(docker inspect --format '{{.State.ExitCode}}' "${cid}" 2>/dev/null)" || exitcode=1
            [ "${exitcode}" = "0" ] && return 0
            return 1
        fi
        started="$(docker inspect --format '{{.State.StartedAt}}' "${cid}" 2>/dev/null)" || started=""
        if [ "${status}" != "running" ]; then
            stable_since=-1
        elif [ "${started}" != "${prev_started}" ]; then
            # What: StartedAt changed; it restarted.
            # Why: the window must restart from this start.
            # From: Issue #1683
            stable_since="${SECONDS}"
        elif [ "${stable_since}" -ge 0 ] && [ $(( SECONDS - stable_since )) -ge "${window}" ]; then
            return 0
        fi
        prev_started="${started}"
        sleep 2
    done
    return 1
}

# What: Poll healthcheck and no-healthcheck services.
# Why: No-healthcheck services still need crash-loop proof.
# From: Issue #1683
_ci_validate_wait_healthy() {
    local project="$1" services no_health svc rc=0 i
    services="$(_ci_validate_health_services)" || return 2
    no_health="$(_ci_validate_no_health_services)" || return 2
    local -a pids=() names=() kinds=()
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        _ci_validate_wait_one "${project}" "${svc}" &
        pids+=("$!"); names+=("${svc}"); kinds+=("healthcheck")
    done <<< "${services}"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        _ci_validate_wait_stable "${project}" "${svc}" &
        pids+=("$!"); names+=("${svc}"); kinds+=("stability")
    done <<< "${no_health}"
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            ci_log "[CI-ERROR-VALIDATE-0009]" "service=\"${names[$i]}\" check=\"${kinds[$i]}\" reason=\"not stable/healthy within timeout\""
            rc=1
        fi
    done
    return "${rc}"
}

# What: Prove DNS resolves a CDN domain, both modes.
# Why: Real dig query/response, not ping (AG-VAL-013).
# From: Issue #1683 | PR #1858
_ci_validate_dns() {
    local project="$1" ip_std ip_ssl domain ip
    ip_std="$(_ci_validate_container_ip "${project}" dns-standard)"
    ip_ssl="$(_ci_validate_container_ip "${project}" dns-ssl)"
    domain="$(_ci_validation_dns_domains | head -1)"
    if [ -z "${ip_std}" ] || [ -z "${ip_ssl}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0010]" "reason=\"missing dns container IP or test domain\""
        return 2
    fi
    for ip in "${ip_std}" "${ip_ssl}"; do
        if ! dig +short "@${ip}" "${domain}" | grep -q .; then
            ci_log "[CI-ERROR-VALIDATE-0011]" "resolver=\"${ip}\" domain=\"${domain}\" reason=\"no DNS answer\""
            return 1
        fi
    done
}

# What: Prove the proxy caches: real MISS then HIT.
# Why: Real cache behavior, not a port probe (AG-VAL-014).
# From: Issue #1683 | PR #1858
_ci_validate_proxy() {
    local project="$1" url ip_std host h
    url="$(_ci_validation_proxy_probe_url)"
    ip_std="$(_ci_validate_container_ip "${project}" proxy)"
    host="${url#http://}"; host="${host%%/*}"
    if [ -z "${url}" ] || [ -z "${ip_std}" ] || [ -z "${host}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0012]" "reason=\"missing proxy probe url or proxy container IP\""
        return 2
    fi
    if ! curl -fsS --resolve "${host}:80:${ip_std}" -o /dev/null "${url}"; then
        ci_log "[CI-ERROR-VALIDATE-0013]" "url=\"${url}\" reason=\"proxy MISS request failed\""
        return 1
    fi
    h="$(curl -fsS --resolve "${host}:80:${ip_std}" -D - -o /dev/null "${url}")" || h=""
    if ! printf '%s' "${h}" | grep -qi 'X-Cache-Status:[[:space:]]*HIT'; then
        ci_log "[CI-ERROR-VALIDATE-0014]" "url=\"${url}\" reason=\"second request not a cache HIT\""
        return 1
    fi
}

# What: Validate the candidate on one live prod stack.
# Why: One up, all checks, one teardown (AG-VAL-027).
# From: Issue #1683 | PR #1858
_ci_default_validate() {
    local candidate="$1" reservation subnet holder project rc=0 up_out
    local net_ovr pin_ovr
    if ! reservation="$(_ci_validate_reserve)"; then
        ci_log "[CI-ERROR-VALIDATE-0015]" "reason=\"no free validation /27 after slot retries\""
        return 2
    fi
    subnet="$(_ci_record_field "${reservation}" subnet)"
    holder="$(_ci_record_field "${reservation}" holder)"
    project="$(_ci_validate_project "${subnet}")"
    net_ovr="$(mktemp "${TMPDIR:-/var/tmp}/ci-validate-net.XXXXXX.yml")"
    pin_ovr="$(mktemp "${TMPDIR:-/var/tmp}/ci-validate-pin.XXXXXX.yml")"
    if _ci_validate_net_override "${subnet}" > "${net_ovr}" \
        && _ci_validate_pin_override "${candidate}" > "${pin_ovr}"; then
        if up_out="$(_ci_validate_up "${project}" "${net_ovr}" "${pin_ovr}" 2>&1)"; then
            _ci_validate_wait_healthy "${project}" || rc=$?
            [ "${rc}" -eq 0 ] && { _ci_validate_dns "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_proxy "${project}" || rc=$?; }
        elif _ci_validate_is_collision "${up_out}"; then
            ci_error "[CI-ERROR-VALIDATE-0016]" "reason=\"subnet/port collision after slot reservation\"" "${up_out}"
            rc=1
        else
            ci_error "[CI-ERROR-VALIDATE-0017]" "reason=\"stack up failed\"" "${up_out}"
            rc=1
        fi
    else
        rc=$?
    fi
    _ci_validate_teardown "${holder}" "${project}"
    rm -f "${net_ovr}" "${pin_ovr}"
    return "${rc}"
}

# What: Run stack validation via the wired backend.
# Why: Default runs the real stack; tests inject a stub.
# From: Issue #1683 | PR #1858
_ci_validate_run() {
    local cand="$1" rc=0
    "${CI_VALIDATE_CMD:-_ci_default_validate}" "${cand}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0004]" "reason=\"stack validation failed\""
        return "${rc}"
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

# What: Print the toolchain smoke executables from SOT.
# Why: One smoke list; test build-tools reads it here.
# From: Issue #1683
_ci_build_tools_smoke_tools() {
    local tools
    tools="$(_ci_block_entry_list build_toolchain build-tools smoke_tools)"
    if [ -z "${tools}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0013]" "reason=\"no smoke_tools in SOT; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${tools}"
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

# What: Append one include object from key=value pairs.
# Why: One JSON builder for every matrix, any field set.
# From: Issue #1683
_ci_matrix_append() {
    local arr="$1"; shift
    local obj='{}' kv
    for kv in "$@"; do
        obj="$(printf '%s' "${obj}" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}')" || return 2
    done
    printf '%s' "${arr}" | jq -c --argjson o "${obj}" '. + [$o]'
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
    [ "${amd}" = "true" ] && include="$(_ci_matrix_append "${include}" arch=amd64 runner="$(_ci_platform_runner linux/amd64)" platform=linux/amd64)"
    [ "${arm}" = "true" ] && include="$(_ci_matrix_append "${include}" arch=arm64 runner="$(_ci_platform_runner linux/arm64)" platform=linux/arm64)"
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
        _ci_imagetools_create "${image}:${tag}" "${amd64}" "${arm64}" >/dev/null || return "$?"
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

# What: The build-tools registry tag for a platform.
# Why: sha-<full>-<arch>; AG-REL-015 bans -standalone-.
# From: Issue #1683
_ci_build_tools_tag() {
    local platform="$1"
    local image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE required}"
    printf '%s:sha-%s-%s' "${image}" "${GITHUB_SHA:?GITHUB_SHA required}" "${platform##*/}"
}

# What: Build+push one arch's build-tools image.
# Why: One build+push owner; digest via readback.
# From: Issue #1683
_ci_build_tools_build() {
    local platform="${1:-}" sig="${2:-}" tag a
    if [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0017]" "reason=\"platform arg required\""
        return 2
    fi
    tag="$(_ci_build_tools_tag "${platform}")" || return 2
    local -a args=(docker buildx build --push --provenance=false
        --platform "${platform}" --tag "${tag}"
        --output "type=image,oci-mediatypes=true")
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--label "${a}")
    done < <(_ci_oci_labels build-tools)
    [ -n "${sig}" ] && args+=(--label "org.lancache-ng.build-tools.signature=${sig}")
    [ -n "${CI_BUILD_CACHE_FROM:-}" ] && args+=(--cache-from "${CI_BUILD_CACHE_FROM}")
    [ -n "${CI_BUILD_CACHE_TO:-}" ] && args+=(--cache-to "${CI_BUILD_CACHE_TO}")
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-arg "${a}")
    done < <(_ci_build_tools_build_args --bare "${platform}")
    args+=(tools/build-tools)
    # What: op=buildx only; call signature fix, not a behavior change.
    # Why: exporter/build+push shape is cross-cutting; build-wave owns it.
    # From: Issue #1683
    _ci_retry buildx "${args[@]}" >/dev/null || return "$?"
    _ci_registry_digest "${tag}"
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
        build) _ci_build_tools_build "${1:-}" "${2:-}" ;;
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
    case "${command}" in check) ;; *) ci_require_manifest || return "$?" ;; esac
    "${fn}" "$@"
}

# =========================================================
# SOURCE-HYGIENE CHECKS
# =========================================================

# What: Fail on any listed text file carrying CRLF.
# Why: eol=lf can be bypassed (API write, pre-attr commit).
# From: Issue #1683
_ci_check_line_endings() {
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files)
    fi
    local path
    local -a offenders=()
    for path in "${files[@]}"; do
        case "${path}" in
            *.png|*.jpg|*.jpeg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot|*.crt|*.key|*.pem) continue ;;
        esac
        [ -f "${path}" ] || continue
        grep -aq $'\r' "${path}" 2>/dev/null && offenders+=("${path}")
    done
    if [ "${#offenders[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0002]" "reason=\"CRLF found; repo requires LF\"" "$(printf '%s\n' "${offenders[@]}")"
        return 1
    fi
    printf 'line-endings=clean files=%s\n' "${#files[@]}"
}

# What: True for a path exempt from the header contract.
# Why: One exclusion owner (binaries, vendored, licenses).
# From: Issue #1683
_ci_header_excluded() {
    case "$1" in
        *.md|VERSION|LICENSE|COPYING) return 0 ;;
        .env|.env.example|*/.env|*/.env.example) return 0 ;;
        Cargo.lock|*/Cargo.lock|.gitkeep|*/.gitkeep) return 0 ;;
        services/dhcp/kea-dhcp4.conf|services/dhcp/kea-ctrl-agent.conf|services/dhcp/kea-dhcp-ddns.conf) return 0 ;;
        docs/validation-state.json|*/docs/validation-state.json) return 0 ;;
        services/ui/src/static/chart.umd.min.js|services/ui/src/static/admin.css) return 0 ;;
        services/proxy/public_suffix_list.dat|services/dns/schema.sqlite3.sql) return 0 ;;
        */fuzz/corpus/*|fuzz/corpus/*) return 0 ;;
        *.png|*.jpg|*.jpeg|*.gif|*.ico|*.svg|*.woff|*.woff2|*.ttf|*.eot|*.crt|*.key|*.pem) return 0 ;;
        *) return 1 ;;
    esac
}

# What: Print the native project+SPDX header for a path.
# Why: Header uses the file format's own comment syntax.
# From: Issue #1683
_ci_header_expected() {
    local h='LanCache-NG (https://github.com/wiki-mod/lancache-ng)'
    local s='SPDX-License-Identifier: AGPL-3.0-or-later'
    case "$1" in
        services/ui/src/templates/*.html|*/services/ui/src/templates/*.html) printf '{# %s #}\n{# %s #}\n' "${h}" "${s}" ;;
        *.html) printf '<!-- %s -->\n<!-- %s -->\n' "${h}" "${s}" ;;
        *.rs) printf '//! %s\n//! %s\n' "${h}" "${s}" ;;
        *.lua) printf -- '-- %s\n-- %s\n' "${h}" "${s}" ;;
        *.js) printf '// %s\n// %s\n' "${h}" "${s}" ;;
        *.css) printf '/* %s */\n/* %s */\n' "${h}" "${s}" ;;
        *.sh|*.bats|*.yml|*.yaml|*.toml|*.conf|*.template|*.txt|*.env|*.service|*.timer|*.ps1|*.dockerignore|Dockerfile|*/Dockerfile|.gitattributes|.gitignore|*/.gitignore|.shellspec|*/.shellspec|CODEOWNERS|*/CODEOWNERS|.githooks/*|*/.githooks/*) printf '# %s\n# %s\n' "${h}" "${s}" ;;
        *) return 1 ;;
    esac
}

# What: True if line 1 is a valid marker for the path.
# Why: shebang / Docker directive / Rust //! sit on line 1.
# From: Issue #1683
_ci_header_line1_ok() {
    local path="$1" l1="$2"
    case "${path}" in *.rs) [ "${l1}" = "//!" ]; return "$?" ;; esac
    [ -z "${l1}" ] && return 0
    case "${l1}" in '#!'*) return 0 ;; esac
    case "${path}" in
        Dockerfile|*/Dockerfile)
            [[ "${l1,,}" =~ ^#[[:space:]]*(syntax|escape|check)[[:space:]]*=[[:space:]]*.+$ ]] && return 0 ;;
    esac
    return 1
}

# What: Fail on any file missing the canonical header.
# Why: AGENTS.md header contract, native syntax, line 2/3.
# From: Issue #1683
_ci_check_file_headers() {
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files)
    fi
    local path exp p_line s_line legacy line pc sc scnt lc
    local -a fails=() scan=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        _ci_header_excluded "${path}" && continue
        if ! exp="$(_ci_header_expected "${path}")"; then
            fails+=("${path}: no native header syntax"); continue
        fi
        p_line="$(printf '%s' "${exp}" | sed -n 1p)"
        s_line="$(printf '%s' "${exp}" | sed -n 2p)"
        legacy="${p_line/LanCache-NG/lancache-ng}"
        mapfile -t scan < <(head -n 20 -- "${path}")
        _ci_header_line1_ok "${path}" "${scan[0]-}" || fails+=("${path}: bad line 1 marker")
        [ "${scan[1]-}" = "${p_line}" ] || fails+=("${path}: line 2 must be: ${p_line}")
        [ "${scan[2]-}" = "${s_line}" ] || fails+=("${path}: line 3 must be: ${s_line}")
        pc=0; scnt=0; lc=0
        for line in "${scan[@]}"; do
            [ "${line}" = "${p_line}" ] && pc=$((pc + 1))
            [ "${line}" = "${s_line}" ] && scnt=$((scnt + 1))
            [ "${line}" = "${legacy}" ] && lc=$((lc + 1))
        done
        [ "${pc}" -eq 1 ] || fails+=("${path}: project header count ${pc} not 1")
        [ "${scnt}" -eq 1 ] || fails+=("${path}: SPDX count ${scnt} not 1")
        [ "${lc}" -eq 0 ] || fails+=("${path}: legacy lowercase header present")
    done
    if [ "${#fails[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0003]" "reason=\"invalid file header layout\"" "$(printf '%s\n' "${fails[@]}")"
        return 1
    fi
    sc="${#files[@]}"
    printf 'file-headers=clean files=%s\n' "${sc}"
}

# What: Enforce AG-CODE-012 comment size and block limits.
# Why: Mechanical 1-1-1-60 plus story-telling-run size.
# From: Issue #1683
_ci_check_comment_length() {
    local file heredoc_on yaml_on rc=0
    for file in "$@"; do
        if [ ! -f "${file}" ]; then
            ci_log "[CI-ERROR-CHECK-0004]" "file=\"${file}\" reason=\"not a file\""
            rc=2; continue
        fi
        awk '
            function flush() {
                if (blocklen > 3) { printf "%s:%d: block %d lines (max 3)\n", FILENAME, blockstart, blocklen; viol++ }
                blocklen = 0
            }
            {
                line = $0; sub(/\r$/, "", line)
                if (line ~ /^[[:space:]]*#[[:space:]]*(What|Why|From):/) {
                    if (blocklen == 0) blockstart = FNR
                    blocklen++
                    if (length(line) > 60) { printf "%s:%d: %d chars (max 60): %s\n", FILENAME, FNR, length(line), line; viol++ }
                } else if (blocklen > 0) flush()
            }
            END { if (blocklen > 0) flush(); if (viol > 0) exit 1 }
        ' "${file}" || rc=1
        case "${file}" in
            *.yml|*.yaml) heredoc_on=0; yaml_on=1 ;;
            *) heredoc_on=1; yaml_on=0 ;;
        esac
        awk -v heredoc_on="${heredoc_on}" -v yaml_on="${yaml_on}" '
            BEGIN {
                sq = sprintf("%c", 39)
                qclass = "[" sq "\"]"
                heredoc_open_re = "<<-?[[:space:]]*" qclass "?[A-Za-z_][A-Za-z0-9_]*" qclass "?"
                strip_lead_re = "^<<-?[[:space:]]*" qclass "?"
                strip_trail_re = qclass "?$"
            }
            { lines[FNR] = $0 }
            function flush_run() {
                if (real_len > 3) { printf "%s:%d: story-telling block (%d lines)\n", FILENAME, block_start, real_len; viol++ }
                block_start = 0; real_len = 0
            }
            END {
                n = FNR; header_end = 0
                if (n >= 3 \
                    && lines[2] ~ /^#[[:space:]]*LanCache-NG \(https:\/\/github\.com\/wiki-mod\/lancache-ng\)[[:space:]]*$/ \
                    && lines[3] ~ /^#[[:space:]]*SPDX-License-Identifier: AGPL-3\.0-or-later[[:space:]]*$/) header_end = 3
                in_heredoc = 0; heredoc_delim = ""; heredoc_dash = 0
                in_yaml = 0; yaml_indent = -1; block_start = 0; real_len = 0
                for (i = 1; i <= n; i++) {
                    line = lines[i]; sub(/\r$/, "", line)
                    if (i <= header_end) { flush_run(); continue }
                    if (heredoc_on && in_heredoc) {
                        check_line = line
                        if (heredoc_dash) sub(/^\t+/, "", check_line)
                        if (check_line == heredoc_delim) in_heredoc = 0
                        flush_run(); continue
                    }
                    if (yaml_on && in_yaml) {
                        if (line ~ /^[[:space:]]*$/) { flush_run(); continue }
                        match(line, /[^ ]/)
                        if ((RSTART - 1) > yaml_indent) { flush_run(); continue }
                        in_yaml = 0
                    }
                    if (line ~ /^[[:space:]]*#/) {
                        stripped = line
                        sub(/^[[:space:]]*#[[:space:]]*/, "", stripped); sub(/[[:space:]]+$/, "", stripped)
                        is_divider = (stripped ~ /^[-=~_*]{4,}$/) || (stripped ~ /^(─|━|═|┄|┈|╌|╍)/)
                        if (block_start == 0) block_start = i
                        if (!is_divider) real_len++
                        continue
                    }
                    flush_run()
                    if (heredoc_on) {
                        tmp = line
                        while (match(tmp, heredoc_open_re)) {
                            seg = substr(tmp, RSTART, RLENGTH)
                            heredoc_dash = (seg ~ /^<<-/)
                            d = seg; sub(strip_lead_re, "", d); sub(strip_trail_re, "", d)
                            heredoc_delim = d; in_heredoc = 1
                            tmp = substr(tmp, RSTART + RLENGTH)
                        }
                    }
                    if (yaml_on && !in_heredoc) {
                        if (match(line, /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][+-]?[0-9]?[[:space:]]*$/)) {
                            match(line, /[^ ]/); yaml_indent = RSTART - 1; in_yaml = 1
                        }
                    }
                }
                flush_run(); if (viol > 0) exit 1
            }
        ' "${file}" || rc=1
    done
    [ "${rc}" -eq 0 ] && printf 'comment-length=clean\n'
    return "${rc}"
}

# What: Fail on a short-SHA slice of a sha-named variable.
# Why: bans collision-unsafe truncation (issue #1095 G2).
# From: Issue #1683
_ci_check_deny_short_sha() {
    local pat='\$\{([A-Za-z_][A-Za-z0-9_]*)?([Ss][Hh][Aa]|[Cc][Oo][Mm][Mm][Ii][Tt]|[Cc][Aa][Nn][Dd][Ii][Dd][Aa][Tt][Ee]|[Rr][Ee][Vv][Ii][Ss][Ii][Oo][Nn])[A-Za-z0-9_]*[[:space:]]*(:[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+|:[[:space:]]*0[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+)\}'
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files -- '.github/scripts/*.sh' '.github/workflows/*.yml')
    fi
    local path out gs
    local -a viol=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        case "${path}" in */ci.sh|ci.sh) continue ;; esac
        if ! out="$(grep -EnH "${pat}" "${path}")"; then
            gs=$?
            if [ "${gs}" -gt 1 ]; then
                ci_log "[CI-ERROR-CHECK-0006]" "path=\"${path}\" reason=\"grep failed\""
                return 2
            fi
        fi
        [ -n "${out}" ] && viol+=("${out}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0005]" "reason=\"short-SHA slice banned (issue #1095)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'deny-short-sha=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a banned-language file or interpreter.
# Why: AG-REL-001 Rust+shell; catches heredoc lang too.
# From: Issue #1683
_ci_check_language_policy() {
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files)
    fi
    local path
    local -a viol=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        case "${path}" in
            *.py|*.pyc|*.pyw|*.rb|*.php|*.pl|*.pm) viol+=("${path}: banned-language file"); continue ;;
        esac
        case "${path}" in */ci.sh|ci.sh|*/ci.bats|ci.bats) continue ;; esac
        case "${path}" in
            *.sh|*.bats|*.yml|*.yaml)
                if grep -Eq '(python3?|perl|ruby|node)[[:space:]]+-[eEc]|<<-?[[:space:]]*"?(PY|PYEOF|PYTHON|PERL|RUBY)' "${path}"; then
                    viol+=("${path}: inline foreign-language interpreter")
                fi ;;
        esac
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0007]" "reason=\"banned language (AG-REL-001)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'language-policy=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a mutable image or action reference.
# Why: SHA/digest-pinned only, no :latest or @vN.
# From: Issue #1683
_ci_check_mutable_refs() {
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files -- '.github/workflows/*.yml' '*/Dockerfile' 'Dockerfile')
    fi
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        case "${path}" in
            *.yml|*.yaml)
                out="$(grep -nE 'uses:[^@]*@v[0-9]' "${path}")" && viol+=("${path} action-@vN: ${out}")
                out="$(grep -nE 'BUILD_TOOLS_IMAGE=[^[:space:]]*:latest' "${path}")" && viol+=("${path} img-default-latest: ${out}")
                ;;
            */Dockerfile|Dockerfile)
                out="$(grep -nE '^FROM .+:latest' "${path}" | grep -vE 'sccache-ng|ccache-ng')" && [ -n "${out}" ] && viol+=("${path} FROM-latest: ${out}")
                out="$(grep -nE '^FROM [a-z0-9./:]*[a-z0-9/]$' "${path}")" && viol+=("${path} FROM-untagged: ${out}")
                ;;
        esac
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0008]" "reason=\"mutable image/action reference\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'mutable-refs=clean files=%s\n' "${#files[@]}"
}

# What: Fail if a bare-path script is not committed 100755.
# Why: bare-path exec needs the bit; core.filemode hides it.
# From: Issue #1683
_ci_check_executable_bits() {
    local -a paths=("$@")
    if [ "${#paths[@]}" -eq 0 ]; then
        paths=(.github/scripts/ci.sh)
        while IFS= read -r h; do [ -n "${h}" ] && paths+=("${h}"); done < <(git ls-files -- '.githooks/*')
    fi
    local path mode
    local -a viol=()
    for path in "${paths[@]}"; do
        mode="$(git ls-files -s -- "${path}" | awk '{print $1; exit}')"
        [ -z "${mode}" ] && continue
        [ "${mode}" = "100755" ] || viol+=("${path}: mode ${mode} not 100755")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0009]" "reason=\"bare-path script not committed 100755\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'executable-bits=clean paths=%s\n' "${#paths[@]}"
}

# What: Flag review-chronology and stale line-refs.
# Why: AG-CODE-002/003 comments state current code only.
# From: Issue #1683
_ci_check_review_chronology() {
    local verbs='(caught|found|flagged|spotted|identified|discovered|noticed)'
    local rc="(\\b${verbs}\\b[[:space:]]+(in|during)[[:space:]]+((a|the|this)[[:space:]]+)?(code[[:space:]]+|pr[[:space:]]+|peer[[:space:]]+)?(self-)?review\\b)"
    rc="${rc}|(\\breview\\b[^a-zA-Z.]{0,20}\\b${verbs}\\b)"
    rc="${rc}|(\\b(before|prior to|until)[[:space:]]+this[[:space:]]+(fix|change|commit|patch)\\b)"
    rc="${rc}|(\\breview[[:space:]]+finding\\b)"
    local lr='\(([Ss]ee[[:space:]]+)?\bline\b[[:space:]]*~?[0-9]+'
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files)
    fi
    local path out ln joined fnums num
    local -a viol=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        case "${path}" in */ci.sh|ci.sh|*/ci.bats|ci.bats) continue ;; esac
        out="$(grep -EinIH "${rc}" "${path}")" && viol+=("${out}")
        out="$(grep -EinIH "${lr}" "${path}")" && viol+=("${out}")
        while IFS=$'\t' read -r ln joined; do
            [ -n "${ln}" ] || continue
            shopt -s nocasematch
            [[ "${joined}" =~ ${rc} ]] && viol+=("${path}:${ln}: ${joined}")
            shopt -u nocasematch
        done < <(awk '
            function isc(l) { return l ~ /^[[:space:]]*(#|\/\/|--|\/\*|\*|<!--|\{#)/ }
            function pl(l,  p) { p=l; sub(/^[[:space:]]*(#|\/\/|--|\/\*|\*|<!--|\{#)[[:space:]]*/, "", p); return p }
            { c=isc($0); cur=(c?pl($0):""); if (pc && c) printf "%d\t%s %s\n", NR-1, pp, cur; pc=c; pp=cur }
        ' "${path}")
        grep -qEI 'From:' "${path}" 2>/dev/null || continue
        fnums="$(grep -EI 'From:' "${path}" 2>/dev/null | grep -oEI '#[0-9]+' | tr -d '#' | sort -u || true)"
        [ -z "${fnums}" ] && continue
        while IFS= read -r num; do
            [ -n "${num}" ] || continue
            out="$(awk -v n="${num}" '
                $0 ~ /From:/ { next }
                { line=$0; inq=""; m=0; len=length(line)
                  for (i=1;i<=len;i++) { ch=substr(line,i,1)
                    if (inq=="") { if (ch=="\"") { inq=ch; continue }
                      if (ch=="\x27") { pv=((i>1)?substr(line,i-1,1):""); if (pv !~ /[A-Za-z0-9_]/) { inq=ch; continue } } }
                    else if (ch==inq) { inq=""; continue }
                    if (inq=="" && ch=="#") { rest=substr(line,i+1,length(n))
                      if (rest==n) { af=substr(line,i+1+length(n),1); bf=((i>1)?substr(line,i-1,1):"")
                        if (af !~ /[0-9]/ && bf !~ /[0-9]/) m=1 } } }
                  if (m) print FILENAME ":" FNR ": " line }
            ' "${path}")"
            [ -n "${out}" ] && viol+=("${out}")
        done <<< "${fnums}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0010]" "reason=\"review-chronology / stale line-ref / bare #N\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'review-chronology=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a live pipe into an early-exiting consumer.
# Why: SIGPIPE under pipefail exits 141 (AG-VAL-029).
# From: Issue #1683
_ci_check_pipefail_early_exit() {
    local pat='\|[[:space:]]*(grep[[:space:]]+[^|]*-[a-zA-Z]*q|grep[[:space:]]+[^|]*-[a-zA-Z]*m[0-9]|head([[:space:]]|$)|sed[^|]*([[:space:];{]|[0-9])q)'
    local -a files=()
    if [ "$#" -gt 0 ]; then files=("$@"); else
        mapfile -t files < <(git ls-files -- '.github/scripts/*.sh' '*/Dockerfile' 'Dockerfile' 'services/*.sh')
    fi
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        [ -f "${path}" ] || continue
        case "${path}" in */ci.sh|ci.sh) continue ;; esac
        grep -qE 'pipefail|build-tools|BUILD_TOOLS_IMAGE' "${path}" || continue
        out="$(grep -nE "${pat}" "${path}")" && viol+=("${path}: ${out}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0011]" "reason=\"live pipe into early-exit consumer (SIGPIPE)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'pipefail-early-exit=clean files=%s\n' "${#files[@]}"
}

# What: Check a PR title's Conventional-Commit form.
# Why: types fixed; scopes derive from the SOT service list.
# From: Issue #1683
_ci_check_pr_title() {
    local title="${1:-${PR_TITLE:-}}"
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        printf 'pr-title=skip-dependabot\n'; return 0
    fi
    if [ -z "${title}" ]; then
        ci_log "[CI-ERROR-CHECK-0012]" "reason=\"no PR title given\""; return 2
    fi
    local types="feat fix docs refactor perf test build ci chore style revert security"
    local scopes
    scopes="$(ci_services) nats build-tools setup ci governance docs scripts"
    scopes="${scopes//$'\n'/ }"
    local pat='^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$'
    local -a errs=()
    if [[ "${title}" =~ ${pat} ]]; then
        local ty="${BASH_REMATCH[1]}" sc="${BASH_REMATCH[3]}" subj="${BASH_REMATCH[5]}"
        case " ${types} " in *" ${ty} "*) ;; *) errs+=("type '${ty}' not allowed") ;; esac
        if [ -n "${sc}" ]; then
            case " ${scopes} " in *" ${sc} "*) ;; *) errs+=("scope '${sc}' not allowed") ;; esac
        fi
        [ -n "${subj// /}" ] || errs+=("empty subject")
    else
        errs+=("not a Conventional-Commit title")
    fi
    if [ "${#errs[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0013]" "reason=\"PR title convention\"" "$(printf '%s\n' "${errs[@]}")"
        return 1
    fi
    printf 'pr-title=ok\n'
}

# What: External deploy images must be digest-pinned + SOT.
# Why: A floating external tag breaks reproducibility.
# From: Issue #1683
_ci_check_stable_external_images() {
    local -a dirs=("$@")
    [ "${#dirs[@]}" -gt 0 ] || dirs=(deploy/prod deploy/quickstart)
    local d line img name
    local -a viol=()
    for d in "${dirs[@]}"; do
        [ -d "${d}" ] || continue
        while IFS= read -r line; do
            img="${line#*image:}"; img="${img#"${img%%[![:space:]]*}"}"
            case "${img}" in
                *ghcr.io*|*'${LANCACHE'*|'') continue ;;
            esac
            case "${img}" in
                *@sha256:*) ;;
                *) viol+=("${d}: external not digest-pinned: ${img}"); continue ;;
            esac
            name="${img%%@*}"; name="${name%%:*}"
            grep -qF "${name}" "${CI_MANIFEST}" || viol+=("${d}: external not in SOT: ${img}")
        done < <(grep -rhE '^[[:space:]]+image:[[:space:]]' "${d}" 2>/dev/null)
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0014]" "reason=\"external image not digest-pinned or not in SOT\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'stable-external-images=clean\n'
}

# What: PR body fills every pull_request_template.md section.
# Why: CONTRIBUTING.md requires each heading kept and completed.
# From: Issue #1683
_ci_check_pr_template() {
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        printf 'pr-template=skip-dependabot\n'; return 0
    fi
    local body_arg="${1:-}" body=""
    if [ -n "${body_arg}" ] && [ -f "${body_arg}" ]; then
        body="$(<"${body_arg}")"
    elif [ -n "${body_arg}" ]; then
        body="${body_arg}"
    else
        body="${PR_BODY:-}"
    fi
    body="${body//$'\r'/}"
    local template="${CI_REPO_ROOT}/.github/pull_request_template.md"
    local -a sections=()
    if [ -f "${template}" ]; then
        while IFS= read -r sec; do sections+=("${sec}"); done \
            < <(grep -oE '^## .+' "${template}" | sed 's/^## //')
    fi
    if [ "${#sections[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0015]" "reason=\"no sections found in pull_request_template.md\""
        return 2
    fi
    local -a missing=()
    local sec content stripped trimmed
    for sec in "${sections[@]}"; do
        if ! grep -qF "## ${sec}" <<<"${body}"; then
            missing+=("${sec}: heading not found"); continue
        fi
        content="$(awk -v sec="${sec}" '
            /^## / && $0 ~ ("^## " sec "$") {found=1; next}
            found && /^## / {exit}
            found {print}
        ' <<<"${body}")"
        # Strips <!-- ... --> (may span lines) and ``` fence markers so an
        # untouched template placeholder counts as empty, not "non-empty".
        stripped="$(awk '
            { line=$0 }
            !incm && line ~ /<!--/ && line ~ /-->/ { sub(/<!--.*-->/, "", line) }
            !incm && line ~ /<!--/ && line !~ /-->/ { sub(/<!--.*/, "", line); incm=1 }
            incm && line ~ /-->/ { sub(/.*-->/, "", line); incm=0 }
            incm { next }
            line ~ /^```/ { next }
            { print line }
        ' <<<"${content}")"
        trimmed="$(tr -d '[:space:]' <<<"${stripped}")"
        [ -n "${trimmed}" ] || { missing+=("${sec}: empty (only template placeholder left)"); continue; }
        if [ "${sec}" = "Type of change" ] && ! grep -qE '^- \[[xX]\]' <<<"${content}"; then
            missing+=("Type of change: no checkbox marked (- [x] ...)")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        if [ "${PR_DRAFT:-false}" = "true" ]; then
            ci_log "[CI-ERROR-CHECK-0015]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${missing[@]}")\""
            printf 'pr-template=warn-draft\n'; return 0
        fi
        ci_error "[CI-ERROR-CHECK-0015]" "reason=\"missing/empty required section(s)\"" "$(printf '%s\n' "${missing[@]}")"
        return 1
    fi
    printf 'pr-template=ok\n'
}

# What: Enforce workflow file/byte and run-block byte ceilings.
# Why: GitHub drops runs >~9000 lines; actionlint hangs >~75KB.
# From: Issue #1683
_ci_measure_run_blocks() {
    local file="$1"
    awk '
        function leadspace(s) { match(s, /^[ \t]*/); return RLENGTH }
        function flush_block() {
            if (started) printf "%d\t%d\n", block_start, block_bytes
            in_block = 0; started = 0
        }
        {
            line = $0
            if (in_block) {
                tmp = line; sub(/^[ \t]*/, "", tmp)
                if (length(tmp) == 0) { block_bytes += length(line) + 1; next }
                ind = leadspace(line)
                if (!started) {
                    if (ind > key_indent) {
                        started = 1; content_indent = ind
                        block_bytes += length(line) + 1; next
                    }
                } else if (ind >= content_indent) {
                    block_bytes += length(line) + 1; next
                }
                flush_block()
            }
            if (!in_block && match(line, /^[ ]*(- )?run:[ ]*[|>][+-]?[0-9]?[+-]?[ ]*(#.*)?$/)) {
                match(line, /^[ ]*(- )?run:/); key_indent = RLENGTH - 4
                match(line, /[|>][+-]?[0-9]?[+-]?/)
                digit = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", digit)
                in_block = 1; block_start = NR + 1; block_bytes = 0
                if (digit != "") { started = 1; content_indent = key_indent + digit }
                else { started = 0; content_indent = 0 }
            }
        }
        END { flush_block() }
    ' "${file}"
}

_ci_check_workflow_line_limit() {
    local dir="${1:-${CI_REPO_ROOT}/.github/workflows}"
    local max_lines="${MAX_WORKFLOW_LINES:-8999}"
    local max_bytes="${MAX_WORKFLOW_BYTES:-512000}"
    local max_block="${MAX_RUN_BLOCK_BYTES:-74000}"
    if [ ! -d "${dir}" ]; then
        ci_log "[CI-ERROR-CHECK-0016]" "dir=\"${dir}\" reason=\"not a directory\""
        return 2
    fi
    local file lines bytes block_report block_line block_bytes
    local -a viol=()
    while IFS= read -r -d '' file; do
        lines="$(wc -l < "${file}")"
        bytes="$(wc -c < "${file}")"
        [ "${lines}" -gt "${max_lines}" ] && viol+=("${file}: ${lines} lines > ${max_lines}")
        [ "${bytes}" -gt "${max_bytes}" ] && viol+=("${file}: ${bytes} bytes > ${max_bytes}")
        block_report="$(_ci_measure_run_blocks "${file}")"
        while IFS=$'\t' read -r block_line block_bytes; do
            [ -n "${block_line}" ] || continue
            [ "${block_bytes}" -gt "${max_block}" ] && \
                viol+=("${file}:${block_line}: run-block ${block_bytes} bytes > ${max_block}")
        done <<<"${block_report}"
    done < <(find "${dir}" -maxdepth 1 -name '*.yml' -print0)
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0016]" "reason=\"workflow size ceiling exceeded\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'workflow-line-limit=clean\n'
}

# What: PR must carry label+milestone+project-board (AG-GH-008).
# Why: A 2026-07-13 sweep found the backlog missing all three.
# From: Issue #1683
_ci_check_pr_tracking_metadata() {
    local pr_number="${PR_NUMBER:-}" repo="${REPO:-}"
    local project_number="${PROJECT_NUMBER:-6}" project_owner="${PROJECT_OWNER:-wiki-mod}"
    if [ -z "${pr_number}" ] || [ -z "${repo}" ]; then
        ci_log "[CI-ERROR-CHECK-0017]" "reason=\"PR_NUMBER and REPO are required\""
        return 2
    fi
    local -a errs=() warns=()
    local label_count
    label_count="$(jq -e 'length' <<<"${PR_LABELS_JSON:-[]}" 2>/dev/null)" || label_count=0
    [ "${label_count}" -eq 0 ] && errs+=("No labels set (AG-GH-008).")
    [ -z "${PR_MILESTONE_TITLE:-}" ] && errs+=("No milestone set (AG-GH-008).")
    if [ -z "${GH_TOKEN:-}" ]; then
        if [ "${PR_IS_FORK:-false}" = "true" ]; then
            warns+=("Project-board not checked: fork PRs get no repo secrets.")
        else
            warns+=("Project-board not checked: no read:project token (GH_TOKEN unset).")
        fi
    else
        local repo_name="${repo#*/}" query response_file status response project_item_count
        query="$(jq -n --arg owner "${project_owner}" --arg repo "${repo_name}" --argjson pr "${pr_number}" \
            '{query:"query($owner: String!, $pr: Int!, $repo: String!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { projectItems(first: 10) { nodes { project { number } } } } } }", variables:{owner:$owner, pr:$pr, repo:$repo}}')"
        response_file="$(mktemp)"
        status="$(curl -sS -o "${response_file}" -w '%{http_code}' \
            -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" -d "${query}" \
            "https://api.github.com/graphql")" || status="000"
        response="$(<"${response_file}")"
        rm -f "${response_file}"
        if [ "${status}" = "401" ] || [ "${status}" = "403" ]; then
            errs+=("Project-board lookup rejected (HTTP ${status}): token invalid/insufficient scope.")
        elif [ "${status}" != "200" ]; then
            warns+=("Could not query project-board membership (HTTP ${status}).")
        elif jq -e 'has("errors")' <<<"${response}" >/dev/null 2>&1; then
            errs+=("Project-board lookup failed: GraphQL error response (bad/expired token).")
        else
            project_item_count="$(jq -r --argjson pn "${project_number}" \
                '[.data.repository.pullRequest.projectItems.nodes[]? | select(.project.number == $pn)] | length' \
                <<<"${response}" 2>/dev/null)" || project_item_count=""
            if [ -z "${project_item_count}" ]; then
                warns+=("Could not parse project-board membership response.")
            elif [ "${project_item_count}" -eq 0 ]; then
                errs+=("Not on project board #${project_number} (${project_owner}).")
            fi
        fi
    fi
    local w
    for w in "${warns[@]:-}"; do [ -n "${w}" ] && ci_log "[CI-ERROR-CHECK-0017]" "warn=\"${w}\""; done
    if [ "${#errs[@]}" -gt 0 ]; then
        if [ "${PR_DRAFT:-false}" = "true" ]; then
            ci_log "[CI-ERROR-CHECK-0017]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${errs[@]}")\""
            printf 'pr-tracking-metadata=warn-draft\n'; return 0
        fi
        ci_error "[CI-ERROR-CHECK-0017]" "reason=\"AG-GH-008 metadata incomplete\"" "$(printf '%s\n' "${errs[@]}")"
        return 1
    fi
    printf 'pr-tracking-metadata=ok\n'
}

# What: Resolves one GitHub issue's state (open/closed/unknown).
# Why: Shared by governance-guards for closed-issue TODO checks.
# From: Issue #1683
_ci_governance_issue_state() {
    local issue="$1"
    if [ -n "${CI_GOVERNANCE_ISSUE_STATE:-}" ]; then
        local pair
        IFS=';' read -ra _ci_gov_pairs <<<"${CI_GOVERNANCE_ISSUE_STATE}"
        for pair in "${_ci_gov_pairs[@]}"; do
            [ "${pair%%=*}" = "${issue}" ] && { printf '%s\n' "${pair#*=}"; return 0; }
        done
        printf 'unknown\n'; return 0
    fi
    if [ -z "${GITHUB_REPOSITORY:-}" ]; then
        printf 'unknown\n'; return 0
    fi
    local -a token_hdr=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        token_hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    elif [ -n "${GH_TOKEN:-}" ]; then
        token_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
    fi
    local response
    response="$(curl -fsS -H 'Accept: application/vnd.github+json' "${token_hdr[@]}" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue}")" || { printf 'unknown\n'; return 0; }
    jq -r '.state // "unknown"' <<<"${response}"
}

# What: Flags stale-issue TODOs, partial-scope text, bad uploads.
# Why: Governance guard over changed files + PR title/body.
# From: Issue #1683
_ci_check_governance_guards() {
    local -a changed=("$@")
    local title="${GOVERNANCE_PR_TITLE:-${PR_TITLE:-}}" body="${GOVERNANCE_PR_BODY:-${PR_BODY:-}}"
    local -a viol=()
    local path line marker issue state
    for path in "${changed[@]}"; do
        case "${path}" in *.md|*.mdx|*.rst|*.txt) continue ;; esac
        [ -f "${path}" ] || continue
        while IFS= read -r marker; do
            [ -n "${marker}" ] || continue
            line="${marker%%:*}"; marker="${marker#*:}"
            issue="${marker##*#}"; issue="${issue%)*}"
            [[ "${issue}" =~ ^[0-9]+$ ]] || continue
            state="$(_ci_governance_issue_state "${issue}")"
            [ "${state}" = "closed" ] && viol+=("${path}:${line}: stale TODO/FIXME references closed #${issue}")
        done < <(grep -nEo '(TODO|FIXME)\(#([0-9]+)\)' "${path}" || true)
    done
    local combined="${title}"
    [ -n "${combined}" ] && [ -n "${body}" ] && combined+=$'\n'
    combined+="${body}"
    if [ -n "${combined}" ]; then
        if grep -Eq '(^|[[:space:]])@/tmp/[^[:space:]]+' <<<"${combined}"; then
            viol+=("PR title/body: looks like a literal @/tmp/... upload path, not real body text")
        elif [[ "${combined}" == \"*\" && "${combined}" == *'\\n'* && "${combined}" != *$'\n'* ]]; then
            viol+=("PR title/body: looks like JSON-quoted Markdown, not real body text")
        fi
        local stripped
        stripped="$(sed -E 's/\b(no|not|none|nothing|without)\b([[:space:]]+[[:alnum:]-]+){0,3}[[:space:]]+(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)\b//Ig' <<<"${combined}")"
        if grep -Eiq '(^|[^[:alnum:]])(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)([^[:alnum:]]|$)' <<<"${stripped}"; then
            local open_found=0
            while IFS= read -r issue; do
                [ -n "${issue}" ] || continue
                state="$(_ci_governance_issue_state "${issue}")"
                [ "${state}" = "open" ] && { open_found=1; break; }
            done < <(grep -oE 'Refs[[:space:]]+#[0-9]+' <<<"${combined}" | grep -oE '[0-9]+' || true)
            [ "${open_found}" -eq 1 ] || \
                viol+=("PR title/body: partial-scope language without an open Refs #... remainder issue")
        fi
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0018]" "reason=\"governance guard violation\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'governance-guards=clean\n'
}

# What: Container/service-name literals stay in lockstep repo-wide.
# Why: Socket-proxy allowlist gates every layer's Docker-API call.
# From: Issue #1683 | Issue #454 | Issue #377 | Issue #1486
_ci_check_naming_consistency() {
    local root="${1:-${CI_REPO_ROOT}}"
    local -a compose_files=("${root}/deploy/prod/docker-compose.yml" "${root}/deploy/quickstart/docker-compose.yml")
    local proxy_sh="${root}/scripts/untracked/docker-socket-proxy.sh"
    local docker_client_rs="${root}/services/ui/src/docker_client.rs"
    local watchdog_sh="${root}/services/watchdog/watchdog.sh"
    local ui_config_rs="${root}/services/ui/src/config.rs"
    local -a viol=()
    local cf

    for cf in "${compose_files[@]}"; do
        [ -f "${cf}" ] || continue
        grep -Eq '^name: lancache-ng$' "${cf}" || viol+=("${cf}: missing 'name: lancache-ng'")
    done

    if [ ! -f "${proxy_sh}" ]; then
        ci_error "[CI-ERROR-CHECK-0019]" "reason=\"docker-socket-proxy.sh not found\"" "${proxy_sh}"
        return 2
    fi
    local allowlist_line allowlist_group allowlist_names
    allowlist_line="$(grep -F 'acl lancache_container' "${proxy_sh}" || true)"
    if [ -z "${allowlist_line}" ]; then
        viol+=("${proxy_sh}: missing 'acl lancache_container' allowlist line")
        allowlist_names=""
    else
        allowlist_group="$(grep -oE '\(lancache-[a-z0-9-]+(\|lancache-[a-z0-9-]+)*\)' <<<"${allowlist_line}")"
        allowlist_names="$(head -n1 <<<"${allowlist_group}" | tr -d '()' | tr '|' '\n' | sort -u)"
    fi
    [ -n "${allowlist_names}" ] || viol+=("${proxy_sh}: could not parse lancache-* allowlist names")

    _ci_name_in_allowlist() { grep -qxF "$1" <<<"${allowlist_names}"; }

    for cf in "${compose_files[@]}"; do
        [ -f "${cf}" ] || continue
        local name_suffix=''
        case "${cf}" in *quickstart*) name_suffix='\$\{LANCACHE_CONTAINER_SUFFIX:-\}' ;; esac
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            grep -Eq "^[[:space:]]+container_name: ${name}${name_suffix}\$" "${cf}" || \
                viol+=("${cf}: no container_name: ${name}${name_suffix}")
        done <<<"${allowlist_names}"
    done

    if [ -f "${docker_client_rs}" ]; then
        local dc_names name
        dc_names="$(grep -oE '=> "lancache-[a-z0-9-]+"' "${docker_client_rs}" | grep -oE 'lancache-[a-z0-9-]+' | sort -u)"
        [ -n "${dc_names}" ] || viol+=("${docker_client_rs}: no '=> \"lancache-*\"' resolutions found")
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            _ci_name_in_allowlist "${name}" || viol+=("${docker_client_rs}: resolves '${name}' not in allowlist")
        done <<<"${dc_names}"
    fi

    if [ -f "${watchdog_sh}" ]; then
        local wd_names name
        wd_names="$(grep -oE '\$\{CONTAINER_[A-Z_]+:-lancache-[a-z0-9-]+\}' "${watchdog_sh}" | grep -oE 'lancache-[a-z0-9-]+' | sort -u)"
        [ -n "${wd_names}" ] || viol+=("${watchdog_sh}: no CONTAINER_*:-lancache-* defaults found")
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            _ci_name_in_allowlist "${name}" || viol+=("${watchdog_sh}: defaults '${name}' not in allowlist")
        done <<<"${wd_names}"
    fi

    local watchdog_acl
    watchdog_acl="$(grep -Ei '^[[:space:]]*(acl|http-request)[[:space:]].*lancache-watchdog' "${proxy_sh}" || true)"
    [ -z "${watchdog_acl}" ] || viol+=("${proxy_sh}: lancache-watchdog referenced in acl/http-request (issue #1486)")

    local verb_acls
    verb_acls="$(grep -oE '^[[:space:]]*acl[[:space:]]+[a-z_]+[[:space:]]+path,url_dec.*/\(?(start|stop|restart|wait)(\|(start|stop|restart|wait))*\)?\$' "${proxy_sh}" \
        | grep -oE 'acl [a-z_]+' | awk '{print $2}')"
    [ -n "${verb_acls}" ] || viol+=("${proxy_sh}: no lifecycle-action (start/stop/restart/wait) acl found")
    local verb_acl verb_acl_line
    while IFS= read -r verb_acl; do
        [ -n "${verb_acl}" ] || continue
        verb_acl_line="$(grep -F "acl ${verb_acl} " "${proxy_sh}" || true)"
        grep -qi 'lancache-\(watchdog\|syslog\)' <<<"${verb_acl_line}" && \
            viol+=("${proxy_sh}: '${verb_acl}' grants lifecycle action to watchdog/syslog (issue #1486)")
    done <<<"${verb_acls}"

    if [ -f "${ui_config_rs}" ]; then
        local -A service_defaults=(
            [DNS_STANDARD_SERVICE]=dns-standard [DNS_SSL_SERVICE]=dns-ssl
            [PROXY_SERVICE]=proxy [NATS_SERVICE]=nats
        )
        local var expected actual
        for var in "${!service_defaults[@]}"; do
            expected="${service_defaults[${var}]}"
            actual="$(grep -oE "env_str\(\"${var}\", \"[a-z0-9-]+\"\)|env_or\(\"${var}\", \"[a-z0-9-]+\"" "${ui_config_rs}" \
                | grep -oE '"[a-z0-9-]+"' | tail -n1 | tr -d '"')"
            if [ -z "${actual}" ]; then
                viol+=("${ui_config_rs}: no default found for \$${var}")
            elif [ "${actual}" != "${expected}" ]; then
                viol+=("${ui_config_rs}: \$${var} defaults to '${actual}', expected '${expected}'")
            fi
            for cf in "${compose_files[@]}"; do
                [ -f "${cf}" ] || continue
                grep -Eq "^  ${expected}:\$" "${cf}" || viol+=("${cf}: no '${expected}:' service for \$${var}")
            done
        done
        grep -Fq 'env_or("PROXY_SSL_SERVICE", proxy_service.clone())' "${ui_config_rs}" || \
            viol+=("${ui_config_rs}: \$PROXY_SSL_SERVICE must inherit from proxy_service.clone()")
    fi

    unset -f _ci_name_in_allowlist
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0019]" "reason=\"naming-consistency drift (docs/naming-conventions.md)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'naming-consistency=clean\n'
}

# What: Route a source-hygiene check to its function.
# Why: One owner per guard invariant; ci.bats calls it.
# From: Issue #1683
ci_cmd_check() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        line-endings) _ci_check_line_endings "$@" ;;
        file-headers) _ci_check_file_headers "$@" ;;
        comment-length) _ci_check_comment_length "$@" ;;
        deny-short-sha) _ci_check_deny_short_sha "$@" ;;
        language-policy) _ci_check_language_policy "$@" ;;
        mutable-refs) _ci_check_mutable_refs "$@" ;;
        executable-bits) _ci_check_executable_bits "$@" ;;
        review-chronology) _ci_check_review_chronology "$@" ;;
        pipefail-early-exit) _ci_check_pipefail_early_exit "$@" ;;
        pr-title) _ci_check_pr_title "$@" ;;
        stable-external-images) _ci_check_stable_external_images "$@" ;;
        pr-template) _ci_check_pr_template "$@" ;;
        workflow-line-limit) _ci_check_workflow_line_limit "$@" ;;
        pr-tracking-metadata) _ci_check_pr_tracking_metadata "$@" ;;
        governance-guards) _ci_check_governance_guards "$@" ;;
        naming-consistency) _ci_check_naming_consistency "$@" ;;
        *)
            ci_log "[CI-ERROR-CHECK-0001]" "sub=\"${sub}\" reason=\"unknown check\""
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
