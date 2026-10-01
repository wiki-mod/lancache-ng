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

# What: The SOT's repo-relative path (git refs, diffs).
# Why: base SOT reads and SOT-change detection share it.
# From: Issue #1683 | PR #1858
CI_MANIFEST_REL=".github/yaml/build-manifest.yml"

# What: Repository root (.github/scripts/../..).
# Why: Identity hashes git-tracked content from the root.
# From: Issue #1683
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)}"

# What: The one CI temp root; /tmp is forbidden.
# Why: /tmp is tmpfs (RAM); runners hit OOM there.
# From: Issue #1683 | PR #1858
CI_TMPDIR="${CI_TMPDIR:-/var/tmp}"

# What: The ci.sh subcommand dispatch table.
# Why: One table is membership, dispatch and error text.
# From: Issue #1683
declare -A CI_DISPATCH=(
    [plan]=ci_cmd_plan [plan-matrix]=ci_cmd_plan_matrix [impact]=ci_cmd_impact [codeql-impact]=ci_cmd_codeql_impact [codeql-config]=ci_cmd_codeql_config [codeql-analyze]=ci_cmd_codeql_analyze [identity]=ci_cmd_identity
    [resolve]=ci_cmd_resolve [build]=ci_cmd_build [build-args]=ci_cmd_build_args [rust-build]=ci_cmd_rust_build [apk-setup]=ci_cmd_apk_setup
    [build-tools]=ci_cmd_build_tools [publish]=ci_cmd_publish [verify]=ci_cmd_verify [ship]=ci_cmd_ship
    [test]=ci_cmd_test [scan]=ci_cmd_scan [assemble]=ci_cmd_assemble
    [aggregate]=ci_cmd_aggregate [emit-result]=ci_cmd_emit_result [aggregate-stack]=ci_cmd_aggregate_stack [scan-stack]=ci_cmd_scan_stack [changed-files]=ci_cmd_changed_files
    [assemble-stack]=ci_cmd_assemble_stack [test-stack]=ci_cmd_test_stack [nightly-status]=ci_cmd_nightly_status
    [validate]=ci_cmd_validate [result-gate]=ci_cmd_result_gate [promote]=ci_cmd_promote [promote-ref]=ci_cmd_promote_ref [release]=ci_cmd_release [release-validation]=_ci_release_validation_valid
    [release-publish]=ci_cmd_release_publish [release-sbom]=ci_cmd_release_sbom [release-sbom-stack]=ci_cmd_release_sbom_stack [release-vex]=ci_cmd_release_vex [cut-release-tag]=ci_cmd_cut_release_tag
    [gc]=ci_cmd_gc [variables]=ci_cmd_variables [check]=ci_cmd_check
    [version]=ci_cmd_version
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
    local message_id="$1" context="$2" raw="${3:-}"
    ci_log "${message_id}" "${context}"
    printf 'raw:\n%s\n' "${raw}" >&2
}

# What: stdout of a command; rc over max-ok or stderr fail.
# Why: grep rc 2 is not a miss; warnings are errors.
# From: Issue #1683 | PR #1858
_ci_capture() {
    local okmax="$1" out err rc=0
    shift
    err="$(mktemp)" || return 2
    out="$("$@" 2>"${err}")" || rc=$?
    if [ "${rc}" -gt "${okmax}" ] || [ -s "${err}" ]; then
        ci_error "[CI-ERROR-CORE-0106]" "rc=\"${rc}\" cmd=\"$1\" reason=\"command failed or wrote stderr\"" "$(cat "${err}")"
        rm -f "${err}"
        return 2
    fi
    rm -f "${err}"
    [ -z "${out}" ] || printf '%s\n' "${out}"
}


# What: Enforce and create the /var/tmp CI temp root.
# Why: bare mktemp and tools then use disk, not tmpfs.
# From: Issue #1683 | PR #1858
_ci_tmp_init() {
    case "${CI_TMPDIR}" in
        /var/tmp|/var/tmp/*) ;;
        *) ci_log "[CI-ERROR-CORE-0006]" "reason=\"CI temp root must be under /var/tmp, not tmpfs /tmp\" got=\"${CI_TMPDIR}\""; return 2 ;;
    esac
    mkdir -p "${CI_TMPDIR}" || return 2
    export TMPDIR="${CI_TMPDIR}"
}

# What: Export the LAN proxy on self-hosted runners only.
# Why: AG-CI-009 proxy; hosted runners have no LAN route.
# From: Issue #1683 | PR #1858
_ci_proxy_init() {
    local http="${PROJECT_SELFHOSTED_PROXY_HTTP:-}"
    [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ] && [ -n "${http}" ] || return 0
    export HTTP_PROXY="${http}" http_proxy="${http}"
    export HTTPS_PROXY="${PROJECT_SELFHOSTED_PROXY_HTTPS:-${http}}"
    export https_proxy="${HTTPS_PROXY}"
    export NO_PROXY="${PROJECT_SELFHOSTED_PROXY_EXCLUSION:-}" no_proxy="${PROJECT_SELFHOSTED_PROXY_EXCLUSION:-}"
    ci_log "[CI-INFO-CORE-0007]" "proxy=on runner=self-hosted no_proxy=\"${NO_PROXY}\""
    [ -n "${PROJECT_SELFHOSTED_PROXY_CA:-}" ] || return 0
    # What: job-local bundle = system CAs + proxy CA.
    # Why: cargo/curl via the TLS proxy; never in an image.
    # From: Issue #1683 | PR #1858
    local bundle
    bundle="$(umask 077 && mktemp "${CI_TMPDIR}/ci-ca-bundle.XXXXXX")" || return 2
    { cat "${CI_SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"; printf '%s\n' "${PROJECT_SELFHOSTED_PROXY_CA}"; } > "${bundle}" || return 2
    export CARGO_HTTP_CAINFO="${bundle}" CURL_CA_BUNDLE="${bundle}"
}

# What: Proxy env names passed through to docker.
# Why: predefined build-args stay out of image history.
# From: Issue #1683 | PR #1858
_ci_proxy_names() {
    local n
    for n in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
        [ -n "${!n:-}" ] && printf '%s\n' "${n}"
    done
    return 0
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
    local block="$1" mode="${2:-blocks}"
    # What: mode "all" also lists scalar keys (key: value).
    # Why: base_images holds values, not nested blocks.
    # From: Issue #1683 | PR #1858
    awk -v block="$block" -v all="$([ "${mode}" = all ] && echo 1)" '
        $0 ~ ("^" block ":[[:space:]]*$") { inb = 1; next }
        inb && /^[^[:space:]]/ { inb = 0 }
        inb && (/^  [A-Za-z0-9_.-]+:[[:space:]]*$/ || (all && /^  [A-Za-z0-9_.-]+:/)) {
            key = $1; sub(/:.*$/, "", key); print key
        }
    ' "${CI_MANIFEST}"
}

# What: Print the product-stack service names.
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

# What: Print the one SOT build_toolchain target name.
# Why: the engine never hardcodes the toolchain target.
# From: Issue #1683
_ci_toolchain_target() {
    local keys
    keys="$(_ci_block_keys build_toolchain)" || return 2
    if [ -z "${keys}" ] || [ "$(wc -l <<< "${keys}")" -ne 1 ]; then
        ci_log "[CI-ERROR-CORE-0011]" "reason=\"SOT build_toolchain must hold exactly one target\""
        return 2
    fi
    printf '%s\n' "${keys}"
}

# What: Build targets that publish a first-party image.
# Why: every SOT service and the toolchain ship an image.
# From: Issue #1683
_ci_published_services() {
    ci_services || return 2
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
    # What: entry="" reads a block-level scalar; quotes cut.
    # Why: base_images has no entry level; one reader.
    # From: Issue #1683 | PR #1858
    awk -v block="$block" -v entry="$entry" -v field="$field" '
        $0 ~ ("^" block ":[[:space:]]*$") { inb = 1; inentry = (entry == ""); next }
        inb && /^[^[:space:]]/ { inb = 0 }
        inb && entry != "" && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            cur = $1; sub(/:$/, "", cur); inentry = (cur == entry)
        }
        inb && inentry && ((entry == "" && index($0, "  " field ":") == 1) || (entry != "" && $1 == (field ":"))) {
            val = $0; sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, "", val)
            if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
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

# What: Query a service field (services or build_toolchain).
# Why: build-tools uses same reader, not a services entry.
# From: Issue #1683
ci_service_field() {
    local v
    v="$(_ci_block_entry_field "services" "$1" "$2")"
    [ -n "${v}" ] && { printf '%s\n' "${v}"; return 0; }
    _ci_block_entry_field "build_toolchain" "$1" "$2"
}

# What: read a required target field; empty is an error.
# Why: no hidden defaults; the SOT must name every field.
# From: Issue #1683
_ci_required_field() {
    local v
    v="$(ci_service_field "$1" "$2")"
    if [ -z "${v}" ]; then
        ci_log "[CI-ERROR-CORE-0009]" \
            "target=\"$1\" field=\"$2\" reason=\"required SOT field missing\""
        return 2
    fi
    printf '%s\n' "${v}"
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
    local service="$1" platform="$2" p plats
    plats="$(_ci_platforms "${service}")" || return 1
    while IFS= read -r p; do
        [ "${p}" = "${platform}" ] && return 0
    done <<< "${plats}"
    return 1
}

# What: Read a platform's SOT arch attribute, fail-closed.
# Why: one owner of platform facts; no per-fact case dup.
# From: Issue #1683
_ci_platform_field() {
    local arch="${1##*/}" field="$2" val
    val="$(_ci_block_entry_field platform_arch "${arch}" "${field}")"
    [ -n "${val}" ] || return 2
    printf '%s\n' "${val}"
}

# What: Map a platform to its apk arch, fail-closed.
# Why: One owner of the platform->apk-arch fact.
# From: Issue #1683
_ci_platform_apk_arch() {
    _ci_platform_field "$1" apk
}

# What: Map a platform to its GitHub-hosted runner label.
# Why: One owner; gate and Base-CI must not both hardcode.
# From: Issue #1683
_ci_platform_runner() {
    _ci_platform_field "$1" runner
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
    local line raw
    raw="$(_ci_changed_files "$@")" || { ci_log "[CI-ERROR-CORE-0008]" "reason=\"changed-file list unreadable\""; return 2; }
    while IFS= read -r line; do
        [ -n "${line}" ] && _arr+=("${line}")
    done <<< "${raw}"
    return 0
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
    context="$(_ci_required_field "${service}" context)" || return 2
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
    _ci_collect_changed changed "$@" || return 2

    local service rc
    for service in $(ci_build_targets); do
        rc=0
        _ci_plan_candidate "${service}" "${changed[@]}" || rc=$?
        case "${rc}" in
            0) printf '%s=true\n' "${service}" ;;
            1) printf '%s=false\n' "${service}" ;;
            *) return 2 ;;
        esac
    done
    ci_log "[CI-INFO-PLAN-0001]" "phase=plan changed=${#changed[@]} note=\"candidates only; identity/CAS decides build\""
}

# What: rc 0 if content under path changed base..head.
# Why: comment-only edits keep identity (§11.1/§12.5).
# From: Issue #1683
_ci_path_content_changed() {
    local path="$1" base="${2:-}" head="${3:-}" a b refs
    if [ -z "${base}" ]; then
        refs="$(_ci_diff_refs)" || return 2
        read -r base head <<<"${refs}"
    fi
    [ -n "${base}" ] || return 0
    a="$(_ci_tracked_content_ids "${path}" "${base}")" || return 2
    b="$(_ci_tracked_content_ids "${path}" "${head}")" || return 2
    [ "${a}" != "${b}" ]
}

# What: CodeQL admission: language matrix + job image.
# Why: §70 no empty runner; image pin lives in the SOT.
# From: Issue #1683 | PR #1858
ci_cmd_codeql_impact() {
    local img
    local -a changed=()
    _ci_collect_changed changed "$@" || return 2
    local include='[]' lang p hit langs paths rc
    langs="$(_ci_block_keys codeql_languages)" || return 2
    while IFS= read -r lang; do
        [ -n "${lang}" ] || continue
        hit=false
        paths="$(_ci_block_entry_list codeql_languages "${lang}" paths)" || return 2
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            _ci_paths_touch "${p}" "${changed[@]}" || continue
            rc=0; _ci_path_content_changed "${p}" || rc=$?
            case "${rc}" in 0) hit=true; break ;; 1) ;; *) return 2 ;; esac
        done <<< "${paths}"
        [ "${hit}" = true ] && { include="$(_ci_matrix_append "${include}" language="${lang}")" || return 2; }
    done <<< "${langs}"
    # What: an admitted language needs the SOT job image.
    # Why: DEFAULT=NOOP; an empty matrix never needs it.
    # From: Issue #1683 | PR #1858
    img="$(_ci_block_entry_field base_images "" codeql_runtime)"
    if [ "${include}" != '[]' ] && [ -z "${img}" ]; then
        ci_log "[CI-ERROR-CODEQL-0012]" "key=\"base_images.codeql_runtime\" reason=\"missing CodeQL job image; FAIL CLOSED\""
        return 2
    fi
    printf 'codeql-matrix={"include":%s}\n' "${include}"
    printf 'codeql-image=%s\n' "${img}"
    ci_log "[CI-INFO-CODEQL-0001]" "phase=codeql-impact langs=$(printf '%s' "${include}" | jq -r 'length') changed=${#changed[@]}"
}

# What: Render the CodeQL config file from the SOT.
# Why: SOT owns scope; the action reads a derived config.
# From: Issue #1683
ci_cmd_codeql_config() {
    local item lang p repo queries langs paths ignore out
    repo="$(_ci_repo)" || return 2
    queries="$(_ci_block_entry_list codeql "" queries)" || return 2
    langs="$(_ci_block_keys codeql_languages)" || return 2
    ignore="$(_ci_block_entry_list codeql "" paths_ignore)" || return 2
    out="name: ${repo##*/}-codeql"$'\n''queries:'$'\n'
    while IFS= read -r item; do
        [ -n "${item}" ] && out+="  - uses: ${item}"$'\n'
    done <<< "${queries}"
    out+='paths:'$'\n'
    while IFS= read -r lang; do
        [ -n "${lang}" ] || continue
        paths="$(_ci_block_entry_list codeql_languages "${lang}" paths)" || return 2
        while IFS= read -r p; do
            [ -n "${p}" ] && out+="  - ${p}"$'\n'
        done <<< "${paths}"
    done <<< "${langs}"
    out+='paths-ignore:'$'\n'
    while IFS= read -r item; do
        [ -n "${item}" ] && out+="  - ${item}"$'\n'
    done <<< "${ignore}"
    printf '%s' "${out}"
}

# What: Download one URL to a file (curl -f).
# Why: injectable seam; _ci_retry classifies the error.
# From: Issue #1683 | PR #1858
_ci_http_download() {
    curl -fsSL -o "$2" "$1"
}

# What: Download a URL and verify it against a sha256.
# Why: one owner for pinned-asset fetches (AG-CI-006).
# From: Issue #1683 | PR #1858
_ci_fetch_verified() {
    local url="$1" sha="$2" dest="$3" raw
    if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-FETCH-0001]" "url=\"${url}\" reason=\"pinned sha256 missing or malformed; FAIL CLOSED\""
        return 2
    fi
    if ! _ci_retry download "${CI_HTTP_DOWNLOAD_CMD:-_ci_http_download}" "${url}" "${dest}" >/dev/null; then
        ci_log "[CI-ERROR-FETCH-0002]" "url=\"${url}\" reason=\"download failed\""
        return 2
    fi
    if ! raw="$(printf '%s  %s\n' "${sha}" "${dest}" | sha256sum -c - 2>&1)"; then
        ci_error "[CI-ERROR-FETCH-0003]" "url=\"${url}\" reason=\"sha256 differs from the pin; FAIL CLOSED\"" "${raw}"
        return 2
    fi
}

# What: Fetch the SOT-pinned CodeQL bundle; print binary.
# Why: SOT owns tag+sha256; no action pin in the YAML.
# From: Issue #1683 | PR #1858
_ci_codeql_fetch() {
    local work="$1" repo tag asset url raw
    repo="$(_ci_block_entry_field external_versions codeql repository)"
    tag="$(_ci_block_entry_field external_versions codeql release_tag)"
    asset="$(_ci_block_entry_field external_versions codeql asset)"
    if [ -z "${repo}" ] || [ -z "${tag}" ] || [ -z "${asset}" ]; then
        ci_log "[CI-ERROR-CODEQL-0005]" "key=\"external_versions.codeql\" reason=\"repository/release_tag/asset missing; FAIL CLOSED\""
        return 2
    fi
    url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/releases/download/${tag}/${asset}"
    _ci_fetch_verified "${url}" "$(_ci_block_entry_field external_versions codeql sha256)" "${work}/${asset}" || return 2
    if ! raw="$(tar --no-same-owner -xzf "${work}/${asset}" -C "${work}" 2>&1)"; then
        ci_error "[CI-ERROR-CODEQL-0007]" "asset=\"${asset}\" reason=\"bundle extract failed\"" "${raw}"
        return 2
    fi
    if [ ! -x "${work}/codeql/codeql" ]; then
        ci_log "[CI-ERROR-CODEQL-0008]" "asset=\"${asset}\" reason=\"bundle has no codeql/codeql binary\""
        return 2
    fi
    printf '%s\n' "${work}/codeql/codeql"
}

# What: Create, analyze and upload one language's SARIF.
# Why: category per language, like the removed action.
# From: Issue #1683 | PR #1858
_ci_codeql_run() {
    local lang="$1" work="$2" codeql raw
    codeql="$(_ci_codeql_fetch "${work}")" || return 2
    ci_cmd_codeql_config > "${work}/config.yml" || return 2
    if ! raw="$("${codeql}" database create "${work}/db" --language="${lang}" --build-mode=none \
            --source-root="${CI_REPO_ROOT:-.}" --codescanning-config="${work}/config.yml" 2>&1)"; then
        ci_error "[CI-ERROR-CODEQL-0009]" "language=\"${lang}\" reason=\"database create failed\"" "${raw}"
        return 2
    fi
    if ! raw="$("${codeql}" database analyze "${work}/db" --format=sarif-latest \
            --sarif-category="/language:${lang}" --output="${work}/result.sarif" 2>&1)"; then
        ci_error "[CI-ERROR-CODEQL-0010]" "language=\"${lang}\" reason=\"database analyze failed\"" "${raw}"
        return 2
    fi
    if ! _ci_retry github-api "${codeql}" github upload-results --repository="${GITHUB_REPOSITORY}" \
            --ref="${GITHUB_REF}" --commit="${GITHUB_SHA}" --sarif="${work}/result.sarif" >/dev/null; then
        ci_log "[CI-ERROR-CODEQL-0014]" "language=\"${lang}\" reason=\"SARIF upload failed\""
        return 2
    fi
    ci_log "[CI-INFO-CODEQL-0011]" "phase=codeql-analyze language=${lang} result=uploaded"
}

# What: Run CodeQL for one SOT language in a work dir.
# Why: fail closed on context; always clean the work dir.
# From: Issue #1683 | PR #1858
ci_cmd_codeql_analyze() {
    local lang="${1:-}" v work rc
    local -a missing=()
    if [ -z "${lang}" ]; then
        ci_log "[CI-ERROR-CODEQL-0002]" "reason=\"language arg required\""
        return 2
    fi
    if ! grep -qx -- "${lang}" <<< "$(_ci_block_keys codeql_languages)"; then
        ci_log "[CI-ERROR-CODEQL-0003]" "language=\"${lang}\" reason=\"not a SOT codeql_languages entry\""
        return 2
    fi
    for v in GITHUB_REPOSITORY GITHUB_REF GITHUB_SHA GITHUB_TOKEN; do
        [ -n "${!v:-}" ] || missing+=("${v}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        ci_log "[CI-ERROR-CODEQL-0004]" "missing=\"${missing[*]}\" reason=\"upload context incomplete; FAIL CLOSED\""
        return 2
    fi
    work="$(mktemp -d "${CI_TMPDIR}/codeql.XXXXXX")" || return 2
    if _ci_codeql_run "${lang}" "${work}"; then rc=0; else rc=$?; fi
    rm -rf "${work}"
    return "${rc}"
}

# What: True when every changed path is documentation.
# Why: docs-only is NOOP; no container jobs run (§63).
# From: Issue #1683
_ci_docs_only() {
    [ "$#" -gt 0 ] || return 1
    local f
    for f in "$@"; do
        case "${f}" in
            *.md|docs/*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# What: Emit a resolve-filtered matrix to GITHUB_OUTPUT.
# Why: Base-CI builds only what identity proves needs work.
# From: Issue #1683
ci_cmd_plan_matrix() {
    local out="${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    local -a changed=()
    _ci_collect_changed changed "$@" || return 2
    local docs_only=false
    _ci_docs_only "${changed[@]}" && docs_only=true
    local service platform include='[]' any=false resolved paction runner authed=false test_services=''
    local sot_changed=false f path_cand rc plats
    # What: SOT change makes every target id candidate.
    # Why: pins live in SOT; identity decides BUILD.
    # From: Issue #1683 | PR #1858
    for f in "${changed[@]}"; do [ "${f}" = "${CI_MANIFEST_REL}" ] && sot_changed=true; done
    # What: build product services and the toolchain.
    # Why: build-tools generic pipeline, separate assembly.
    # From: Issue #1683
    for service in $(ci_services) $(_ci_block_keys build_toolchain); do
        path_cand=false rc=0
        _ci_plan_candidate "${service}" "${changed[@]}" || rc=$?
        case "${rc}" in 0) path_cand=true ;; 1) ;; *) return 2 ;; esac
        [ "${path_cand}" = true ] || [ "${sot_changed}" = true ] || continue
        # What: path-changed rust is test candidate (§60).
        # Why: tests run on change, even build reuse (§60).
        # From: Issue #1683
        [ "${path_cand}" = true ] && [ "$(ci_service_field "${service}" build_type)" = rust ] \
            && test_services="${test_services} ${service}"
        # What: auth once, only when a candidate exists.
        # Why: docs-only NOOP: registry zero touches (§63).
        # From: Issue #1683
        if [ "${authed}" = false ]; then
            _ci_require_ghcr_auth || return "$?"
            authed=true
        fi
        plats="$(_ci_platforms "${service}")" || return "$?"
        while IFS= read -r platform; do
            [ -n "${platform}" ] || continue
            resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
            paction="$(_ci_record_field "${resolved}" action)"
            [ "${paction}" = "build" ] || continue
            # What: matrix holds targets with proven impact.
            # Why: MISSING_CONFIRMED must not build alone.
            # From: Issue #1683 | PR #1858
            [ "$(_ci_semantic_impact "${service}" "${platform}" "$(_ci_record_field "${resolved}" identity)")" = BUILD ] || continue
            if ! runner="$(_ci_platform_runner "${platform}")"; then
                ci_log "[CI-ERROR-PLAN-0002]" "platform=\"${platform}\" reason=\"no runner label for platform\""
                return 2
            fi
            include="$(_ci_matrix_append "${include}" service="${service}" arch="${platform##*/}" runner="${runner}" platform="${platform}")" || return 2
            any=true
        done <<< "${plats}"
    done
    # What: emit the AG-VAL-008 rust validation decision.
    # Why: no test runner is booked while validation is off.
    # From: Issue #1683
    local rust_validation=true
    rc=0; _ci_rust_validation_enabled || rc=$?
    case "${rc}" in 0) ;; 1) rust_validation=false ;; *) return 2 ;; esac
    {
        printf 'any-build=%s\n' "${any}"
        printf 'matrix={"include":%s}\n' "${include}"
        printf 'test-services=%s\n' "${test_services# }"
        printf 'rust-validation=%s\n' "${rust_validation}"
        printf 'docs-only=%s\n' "${docs_only}"
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
    local root="$1" ref="${2:-}" raw listing line path oid blob norm empty
    # What: git pathspec selects files in both modes alike.
    # Why: ls-tree ignores globs; diff-tree honours them.
    # From: Issue #1683
    if [ -n "${ref}" ]; then
        empty="$( cd -- "${CI_REPO_ROOT}" && git hash-object -t tree /dev/null )" || return 2
        raw="$( cd -- "${CI_REPO_ROOT}" && git diff-tree -r --raw "${empty}" "${ref}" -- "${root}" )" || return 2
        listing="$(awk -F'\t' 'NF { split($1, a, " "); print $2 "\t" a[4] }' <<< "${raw}")"
    else
        raw="$( cd -- "${CI_REPO_ROOT}" && git ls-files -s -- "${root}" )" || return 2
        listing="$(awk -F'\t' 'NF { split($1, a, " "); print $2 "\t" a[2] }' <<< "${raw}")"
    fi
    listing="$(LC_ALL=C sort <<< "${listing}")"
    [ -n "${listing}" ] || return 0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        path="${line%%$'\t'*}"
        oid="${line#*$'\t'}"
        if _ci_source_is_normalizable "${path}"; then
            blob="$( cd -- "${CI_REPO_ROOT}" && git cat-file blob "${oid}" )" || return 2
            if printf '%s' "${blob}" | _ci_rust_strip_is_safe; then
                norm="$(printf '%s' "${blob}" | _ci_rust_content_hash)"
                printf '%s\t%s\n' "${path}" "${norm}"
                continue
            fi
        fi
        printf '%s\t%s\n' "${path}" "${oid}"
    done <<< "${listing}"
}

# What: Print each SOT build_identity input of a type.
# Why: SOT names the inputs; the build must match the id.
# From: Issue #1683 | PR #1858
_ci_identity_pins() {
    local service="$1" build_type="$2" platform="$3" inputs input pkgs base arch
    inputs="$(_ci_block_entry_list build_identity "${build_type}" inputs)"
    if [ -z "${inputs}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0004]" "build_type=\"${build_type}\" reason=\"no SOT build_identity inputs; FAIL CLOSED\""
        return 2
    fi
    for input in ${inputs}; do
        printf 'input=%s\n' "${input}"
        case "${input}" in
            source_sha) : ;;
            toolchain_digest|toolchain_source_sha) _ci_build_tools_resolve_signature || return 2 ;;
            base_digest)
                if [ "${build_type}" = toolchain ]; then
                    _ci_build_tools_build_args --bare "${platform}" || return 2
                else
                    _ci_service_build_args "${service}" --bare "${platform}" no || return 2
                fi
                ;;
            package_versions)
                pkgs="$(_ci_block_entry_list services "${service}" packages | tr '\n' ' ')"
                [ -n "${pkgs// /}" ] || continue
                base="$(_ci_block_entry_field base_images "" alpine)"
                arch="$(_ci_platform_apk_arch "${platform}")" || {
                    ci_log "[CI-ERROR-IDENTITY-0005]" "platform=\"${platform}\" reason=\"no apk arch; FAIL CLOSED\""; return 2; }
                _ci_apk_resolve "${base}" "${arch}" "${pkgs% }" "$(_ci_apk_repositories "${service}")" || return 2
                printf '\n'
                ;;
            *)
                ci_log "[CI-ERROR-IDENTITY-0006]" "input=\"${input}\" reason=\"unknown build_identity input; FAIL CLOSED\""
                return 2
                ;;
        esac
    done
}

# What: Print the bare id of one target+platform.
# Why: Platform mixed in so arches never collide.
# From: Issue #1683
_ci_identity_for() {
    local service="$1" platform="$2" ref="${3:-}"
    local build_type context ctx ctx_path pins
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    context="$(_ci_required_field "${service}" context)" || return 2
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
    local id
    id="$(_ci_identity_for "$1" "$2")" || return "$?"
    printf 'platform=%s identity=%s\n' "$2" "${id}"
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
    local ref="$1" dest="$2" body
    body="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git show "${ref}:${CI_MANIFEST_REL}")" || return 2
    printf '%s\n' "${body}" > "${dest}"
}

# What: Emit NOOP or BUILD per target and platform.
# Why: Equal identity base-vs-head is the no-build rule.
# From: Issue #1683
_ci_impact_run() {
    local base="$1" head="$2" base_manifest="$3"
    local base_missing=0 t p plats hid v build=0 noop=0 unknown=0 targets
    targets="$(ci_build_targets)" || return 2
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
            hid="$(_ci_identity_for "${t}" "${p}" "${head}")" || hid=""
            v="$(_ci_impact_classify "${t}" "${p}" "${hid}" "${base}" "${base_manifest}")"
            printf 'target=%s platform=%s impact=%s\n' "${t}" "${p}" "${v}"
            case "${v}" in
                NOOP) noop=$((noop+1)) ;;
                BUILD) build=$((build+1)) ;;
                *) unknown=$((unknown+1)) ;;
            esac
        done <<< "${plats}"
    done <<< "${targets}"
    printf 'impact result=classified build=%s noop=%s unknown=%s base=%s\n' "${build}" "${noop}" "${unknown}" "${base}"
    # What: base-missing escalates; UNKNOWN never builds.
    # Why: base-SOT-unavailable stays DISACK, escalates.
    # From: Issue #1683
    if [ "${base_missing}" -eq 1 ] || [ "${unknown}" -gt 0 ]; then return 3; fi
    return 0
}

# What: NOOP/BUILD for a head id vs its base id.
# Why: a failed or empty identity is UNKNOWN, never BUILD.
# From: Issue #1683 | PR #1858
_ci_impact_classify() {
    local t="$1" p="$2" hid="$3" base="$4" base_manifest="$5" bid
    [ -n "${hid}" ] || { printf 'UNKNOWN\n'; return 0; }
    bid="$(CI_MANIFEST="${base_manifest}" _ci_identity_for "${t}" "${p}" "${base}")" || bid=""
    [ -n "${bid}" ] || { printf 'UNKNOWN\n'; return 0; }
    [ "${hid}" = "${bid}" ] && { printf 'NOOP\n'; return 0; }
    printf 'BUILD\n'
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
    base_manifest="$(mktemp -p "${CI_TMPDIR}")"
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
# Why: not_found enables build; other types stay final.
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
            "error: "*": not found") printf 'not_found\n'; return 0 ;;
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
    # Why: Never a real compile failure (scoped wrappers).
    # From: Issue #1683
    if [ "${op}" = "buildx" ]; then
        case "${low}" in
            *"code = unavailable"*"locked for"*) printf 'transient\n'; return 0 ;;
            *"panic: methodref has no signature"*) printf 'transient\n'; return 0 ;;
        esac
        # What: failed RUN step: permanent unless network.
        # Why: same inputs fail again; only I/O may heal.
        # From: Issue #1683 | PR #1858
        case "${low}" in
            *"did not complete successfully"*)
                if _ci_failure_is_network "${low}"; then printf 'transient\n'; else printf 'permanent\n'; fi
                return 0 ;;
        esac
    fi
    # What: apk package or repo-tag resolution errors.
    # Why: a missing package or tag never heals on retry.
    # From: Issue #1683 | PR #1858
    case "${low}" in
        *"unable to select packages"*|*"not committing changes"*) printf 'permanent\n'; return 0 ;;
    esac
    # What: curl -f HTTP 4xx, except 403/429, is permanent.
    # Why: a wrong tag/asset never heals on a retry.
    # From: Issue #1683 | PR #1858
    case "${low}" in
        *"returned error: 403"*|*"returned error: 429"*) ;;
        *"returned error: 4"[0-9][0-9]*) printf 'permanent\n'; return 0 ;;
    esac
    # What: an unclassified failure is transient.
    # Why: a missed transient is worse than a retry.
    printf 'transient\n'
}

# What: true for rate-limit, 5xx and network signatures.
# Why: one list for the default and the buildx RUN path.
# From: Issue #1683 | PR #1858
_ci_failure_is_network() {
    case "$1" in
        *"http 403"*|*"http 429"*|*"toomanyrequests"*|*"rate limit"*) return 0 ;;
        *"http 5"[0-9][0-9]*|*"i/o timeout"*|*"connection refused"*|*"tls handshake timeout"*) return 0 ;;
        *"eof"*|*"connection reset by peer"*|*"temporary failure"*) return 0 ;;
        *"unexpected disconnect"*|*"remote end hung up"*|*"connection timed out"*) return 0 ;;
        *"could not resolve host"*|*"could not connect to server"*) return 0 ;;
        *"rpc failed; curl 92"*|*"rpc failed; curl 5"*) return 0 ;;
        *"gnutls recv error"*|*"tls connection"*"closed"*) return 0 ;;
    esac
    return 1
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
    local remote="$1" ref="$2" out err errf rc=0
    errf="$(mktemp "${CI_TMPDIR}/ci-lsremote.XXXXXX")" || return 2
    out="$(git ls-remote --exit-code "${remote}" "${ref}" 2>"${errf}")" || rc=$?
    err="$(<"${errf}")"; rm -f "${errf}"
    [ "${rc}" -eq 0 ] && { printf '%s\n' "${out%%$'\t'*}"; return 0; }
    [ "${rc}" -eq 2 ] && return 1
    ci_error "[CI-WARN-RESOLVE-0008]" "remote=\"${remote}\" ref=\"${ref}\" rc=${rc} reason=\"ref query failed; UNKNOWN\"" "${err}"
    return 2
}

# What: Run git under the synthetic CAS identity.
# Why: Runners have no git user; one identity owner.
# From: Issue #1683
_ci_cas_git() {
    GIT_AUTHOR_NAME=ci-cas GIT_AUTHOR_EMAIL=ci-cas@ci.invalid \
    GIT_COMMITTER_NAME=ci-cas GIT_COMMITTER_EMAIL=ci-cas@ci.invalid \
        git "$@"
}

# What: Build an empty-tree commit carrying a note.
# Why: A lock head carries a note, not a real tree.
# From: Issue #1683
_ci_cas_note_commit() {
    _ci_capture 0 _ci_cas_git commit-tree "${CI_CAS_EMPTY_TREE}" -m "$1"
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
    # Why: _ci_lock_acquire already wraps retry logic.
    # From: Issue #1683
    _ci_capture 0 git fetch --quiet --depth=1 "${remote}" "${ref}" || return 3
    # What: unreadable lock age stops; never a takeover.
    # Why: age 0 would take over a live holder's lock.
    # From: Issue #1683 | PR #1858
    committed="$(_ci_capture 0 git log -1 --format=%ct FETCH_HEAD)" || return 3
    if [ -z "${committed}" ]; then
        ci_log "[CI-ERROR-CAS-0003]" "ref=\"${ref}\" reason=\"lock commit has no timestamp; not taking over\""
        return 3
    fi
    prev="$(_ci_capture 0 git log -1 --format=%s FETCH_HEAD)" || return 3
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
    # What: this fetch has no retry level (acquire differs).
    # Why: op=git uses shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${ref}" >/dev/null || return 1
    held="$(_ci_capture 0 git log -1 --format=%s FETCH_HEAD)" || return 1
    [ "${held}" = "${note}" ] || return 0
    _ci_capture 0 git push --quiet --force-with-lease="${ref}:${cur}" "${remote}" ":${ref}" || return 1
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
    _ci_cas_ref_sha "${remote}" "${CI_LEDGER_REF}" >/dev/null || rc=$?
    [ "${rc}" -eq 1 ] && return 1
    [ "${rc}" -eq 0 ] || return 2
    # What: this fetch has no retry level.
    # Why: op=git uses shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${CI_LEDGER_REF}" >/dev/null || return 2
    local blob
    if ! blob="$(git cat-file -p "FETCH_HEAD:${CI_LEDGER_FILE}" 2>&1)"; then
        ci_error "[CI-WARN-RESOLVE-0009]" "ref=\"${CI_LEDGER_REF}\" file=\"${CI_LEDGER_FILE}\" reason=\"ledger file unreadable; UNKNOWN\"" "${blob}"
        return 2
    fi
    printf '%s\n' "${blob}"
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
    _ci_capture 0 _ci_cas_git commit-tree "${tree}" "${pa[@]}" -m "${msg}"
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
        parent="$(_ci_capture 0 git rev-parse FETCH_HEAD)" || return 3
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

# What: published per-identity digest for service/platform.
# Why: emit-result and scan-stack resolve (AG-CODE-011).
# From: Issue #1683
_ci_published_digest() {
    local svc="$1" plat="$2" identity tag
    identity="$(_ci_identity_for "${svc}" "${plat}")" || return "$?"
    tag="$(_ci_image_tag "${svc}" "${plat}" "${identity}")"
    _ci_registry_digest "${tag}"
}

# What: Emit service/platform acceptance result (§26.1).
# Why: single aggregator reads; digest from GHCR verified.
# From: Issue #1683
ci_cmd_emit_result() {
    local service="${1:-}" platform="${2:-}" identity digest
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RESULT-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${platform}" ] || { ci_log "[CI-ERROR-RESULT-0002]" "reason=\"platform arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    digest="$(_ci_published_digest "${service}" "${platform}")" || {
        ci_log "[CI-ERROR-RESULT-0003]" "service=\"${service}\" platform=\"${platform}\" reason=\"no published digest to accept\""
        return 2
    }
    jq -cn --arg s "${service}" --arg p "${platform}" --arg i "${identity}" --arg d "${digest}" \
        '{service:$s, platform:$p, build_identity:$i, digest:$d, state:"ACCEPTED"}'
}

# What: emit "service platform" per built matrix pair.
# Why: matrix walk shared by aggregate-stack/scan-stack.
# From: Issue #1683
_ci_matrix_pairs() {
    if ! jq -r '.include[] | "\(.service) \(.platform)"' <<< "$1"; then
        ci_log "[CI-ERROR-AGGREGATE-0006]" "reason=\"build matrix is not valid include JSON\""
        return 2
    fi
}

# What: aggregate built matrix into ledger in one write.
# Why: emit each pair then one CAS commit (§26.1); thin.
# From: Issue #1683
ci_cmd_aggregate_stack() {
    local matrix="${CI_BUILD_MATRIX:-}" dir svc plat pairs
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-AGGREGATE-0005]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    pairs="$(_ci_matrix_pairs "${matrix}")" || return 2
    dir="$(mktemp -d "${CI_TMPDIR}/ci-results.XXXXXX")" || return 2
    while read -r svc plat; do
        [ -n "${svc}" ] || continue
        ci_cmd_emit_result "${svc}" "${plat}" > "${dir}/${svc}-${plat//\//-}.json" || return "$?"
    done <<< "${pairs}"
    ci_cmd_aggregate "${dir}"
}

# What: scan each built pair by published digest (§7).
# Why: SCAN before ACCEPT; thin YAML, iteration in ci.sh.
# From: Issue #1683
ci_cmd_scan_stack() {
    local matrix="${CI_BUILD_MATRIX:-}" svc plat digest pairs
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-SCAN-0016]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    pairs="$(_ci_matrix_pairs "${matrix}")" || return 2
    _ci_require_ghcr_auth || return "$?"
    while read -r svc plat; do
        [ -n "${svc}" ] || continue
        digest="$(_ci_published_digest "${svc}" "${plat}")" || {
            ci_log "[CI-ERROR-SCAN-0017]" "service=\"${svc}\" platform=\"${plat}\" reason=\"no published digest to scan\""
            return 2
        }
        ci_cmd_scan "${svc}" "${digest}" || return "$?"
    done <<< "${pairs}"
}

# What: This run's base and head diff refs, or empty.
# Why: one owner; changed-files and codeql share the refs.
# From: Issue #1683
_ci_diff_refs() {
    local mb before
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
        mb="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git merge-base "${BASE_SHA:-}" FETCH_HEAD)" || return 2
        printf '%s %s\n' "${mb}" FETCH_HEAD
        return 0
    fi
    if [ -z "${BEFORE_SHA:-}" ] || [ "${BEFORE_SHA}" = 0000000000000000000000000000000000000000 ]; then
        return 0
    fi
    # What: rc 1 = before-commit absent (force push).
    # Why: absent is "no base"; any other failure is rc 2.
    # From: Issue #1683 | PR #1858
    before="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 1 git rev-parse -q --verify "${BEFORE_SHA}^{commit}")" || return 2
    if [ -n "${before}" ]; then
        printf '%s %s\n' "${BEFORE_SHA}" "${GITHUB_SHA}"
    fi
}

# What: write/echo changed-file list path for this event.
# Why: one git-walk owner; plan/lint/checks (AG-CODE-011).
# From: Issue #1683
ci_cmd_changed_files() {
    local out="${RUNNER_TEMP:-${CI_TMPDIR}}/changed-files.txt" base head refs
    refs="$(_ci_diff_refs)" || return 2
    read -r base head <<<"${refs}"
    if [ -n "${base}" ]; then
        ( cd -- "${CI_REPO_ROOT}" && git diff --name-only "${base}" "${head}" ) > "${out}" || return 2
    else
        ( cd -- "${CI_REPO_ROOT}" && git ls-files ) > "${out}" || return 2
    fi
    printf '%s\n' "${out}"
}

# What: assemble product services from build matrix.
# Why: one matrix walk; iteration in ci.sh (AG-CODE-011).
# From: Issue #1683
ci_cmd_assemble_stack() {
    local matrix="${CI_BUILD_MATRIX:-}" svc
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-ASSEMBLE-0006]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    for svc in $(printf '%s' "${matrix}" | jq -r '[.include[].service] | unique | .[]'); do
        ci_cmd_assemble "${svc}" || return "$?"
    done
}

# What: run ci.sh op for each changed rust test service.
# Why: one TEST_SERVICES walk for the test stack.
# From: Issue #1683
_ci_for_test_services() {
    local fn="$1" svc
    for svc in ${TEST_SERVICES:-}; do
        "${fn}" "${svc}" || return "$?"
    done
}
ci_cmd_test_stack() { _ci_for_test_services ci_cmd_test; }

# What: file/update/close standing tracking issue for run.
# Why: nightly reliability; self-closing, no action.
# From: Issue #1683
ci_cmd_nightly_status() {
    local outcome="${1:-}" scope="${2:-}" label="${3:-nightly-broken}" failed="${CI_FAILED_JOBS:-}"
    [ -n "${outcome}" ] || { ci_log "[CI-ERROR-STATUS-0001]" "reason=\"outcome arg required (success|failure)\""; return 2; }
    [ -n "${scope}" ] || { ci_log "[CI-ERROR-STATUS-0002]" "reason=\"scope arg required\""; return 2; }
    local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" gh="${CI_NIGHTLY_STATUS_CMD:-gh}"
    local run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}" existing
    existing="$("${gh}" issue list --repo "${repo}" --label "${label}" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')" || return 2
    if [ "${outcome}" = success ]; then
        [ -n "${existing}" ] || { printf 'nightly-status=noop label=%s\n' "${label}"; return 0; }
        "${gh}" issue comment "${existing}" --repo "${repo}" \
            --body "Recovered: ${scope} succeeded in ${run_url}. Closing this standing issue; it re-opens if the check fails again." || return 2
        "${gh}" issue close "${existing}" --repo "${repo}" || return 2
        printf 'nightly-status=closed issue=%s\n' "${existing}"
        return 0
    fi
    local detail="${scope} failed in ${run_url}"
    [ -n "${failed}" ] && detail="${detail} (failed: ${failed})"
    if [ -n "${existing}" ]; then
        "${gh}" issue comment "${existing}" --repo "${repo}" --body "Still failing: ${detail}." || return 2
        printf 'nightly-status=updated issue=%s\n' "${existing}"
    else
        # What: label create-or-update, then the issue.
        # Why: --force makes an existing label no error.
        # From: Issue #1683 | PR #1858
        "${gh}" label create "${label}" --repo "${repo}" --color b60205 --force \
            --description "Recurring self-closing tracking issue: ${scope}" || return 2
        "${gh}" issue create --repo "${repo}" --label "${label}" --title "[${label}] ${scope}" \
            --body "Standing issue, reused across failures and auto-closed on the next success. ${detail}." >/dev/null || return 2
        printf 'nightly-status=opened label=%s\n' "${label}"
    fi
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

# What: Export sccache as rustc wrapper; Redis if given.
# Why: every cargo run uses sccache; local disk fallback.
# From: Issue #1683 | PR #1858
_ci_sccache_env() {
    local prefix="$1" wrapper="${2:-sccache}" url="${SCCACHE_REDIS_URL:-}"
    export RUSTC_WRAPPER="${wrapper}" SCCACHE_DIR="${SCCACHE_DIR:-${CI_TMPDIR}/sccache}"
    export SCCACHE_REDIS_KEY_PREFIX="${prefix}"
    if [ -s /run/secrets/sccache_redis_url ]; then url="$(</run/secrets/sccache_redis_url)"; fi
    if [ -n "${url}" ]; then
        export SCCACHE_REDIS="${url}"
        ci_log "[CI-INFO-CACHE-0001]" "prefix=\"${prefix}\" backend=redis"
    else
        ci_log "[CI-INFO-CACHE-0002]" "prefix=\"${prefix}\" backend=local dir=\"${SCCACHE_DIR}\""
    fi
}

# =========================================================
# BUILD ENGINE
# =========================================================

# What: Fail unless GHCR credentials are present.
# Why: Every GHCR action authenticates, never anonymous.
# From: Issue #1683
_ci_require_ghcr_auth() {
    [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] || {
        ci_log "[CI-ERROR-BUILD-0002]" "reason=\"GHCR credentials required; anonymous is rate-limited\""
        return 2
    }
    # What: Log docker in for auth; injectable.
    # Why: auth is ci.sh policy (§7); no workflow action.
    # From: Issue #1683
    local reg out rc=0
    if [ -n "${CI_GHCR_LOGIN_CMD:-}" ]; then
        out="$("${CI_GHCR_LOGIN_CMD}" 2>&1)" || rc=$?
    else
        reg="$(_ci_registry)" || return "$?"
        out="$(printf '%s' "${GHCR_TOKEN}" | docker login "${reg}" -u "${GHCR_USERNAME}" --password-stdin 2>&1)" || rc=$?
    fi
    [ "${rc}" -eq 0 ] && return 0
    ci_error "[CI-ERROR-BUILD-0015]" "reason=\"docker login to GHCR failed\"" "${out}"
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

# What: The canonical registry host from the SOT.
# Why: refs derive it; a missing value must fail closed.
# From: Issue #1683
_ci_registry() {
    local r
    r="$(_ci_manifest_scalar '^  registry:[[:space:]]')"
    printf '%s' "${r:?[CI-ERROR-CORE-0005] release.registry missing from the SOT}"
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
            # What: emit raw failure to the caller too.
            # Why: caller may interpret op-specific reason.
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
    local registry repo
    registry="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    printf '%s/%s/%s:sha-%s-%s' "${registry}" "${repo}" "$1" "$3" "${2##*/}"
}

# What: The registry ref for a service at a digest.
# Why: One owner of the image@digest form used by many.
# From: Issue #1683
_ci_image_ref() {
    local reg repo
    reg="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    printf '%s/%s/%s@%s' "${reg}" "${repo}" "$1" "$2"
}

# What: The base build-tools image ref, no tag.
# Why: One owner for the registry host, from the SOT.
# From: Issue #1683
_ci_build_tools_image() {
    local reg repo tool
    reg="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    tool="$(_ci_toolchain_target)" || return 2
    printf '%s/%s/%s' "${reg}" "${repo}" "${tool}"
}

# What: OCI image labels from the SOT and env.
# Why: Provenance labels set once, not per Dockerfile.
# From: Issue #1683
_ci_oci_labels() {
    local service="$1" repo source base final created
    repo="$(_ci_repo)" || return 2
    source="${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}/${repo}"
    final="$(_ci_required_field "${service}" final_base)" || return 2
    base="$(_ci_block_entry_field base_images "" "${final}")"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'org.opencontainers.image.created=%s\n' "${created}"
    [ -n "${GITHUB_SHA:-}" ] && printf 'org.opencontainers.image.revision=%s\n' "${GITHUB_SHA}"
    [ -n "${GITHUB_SHA:-}" ] && printf 'org.opencontainers.image.version=%s\n' "${GITHUB_SHA}"
    printf 'org.opencontainers.image.source=%s\n' "${source}"
    printf 'org.opencontainers.image.url=%s\n' "${source}"
    printf 'org.opencontainers.image.documentation=%s\n' "${source}"
    printf 'org.opencontainers.image.licenses=%s\n' 'AGPL-3.0-or-later'
    printf 'org.opencontainers.image.vendor=%s\n' "${repo%%/*}"
    printf 'org.opencontainers.image.title=%s\n' "${service}"
    printf 'org.opencontainers.image.description=%s\n' "${repo##*/} ${service} image"
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-BUILD-0014]" "service=\"${service}\" key=\"base_images.${final}\" reason=\"final base not pinned in SOT\""
        return 2
    fi
    printf 'org.opencontainers.image.base.name=%s\n' "${base%@*}"
    printf 'org.opencontainers.image.base.digest=%s\n' "${base#*@}"
}

# What: adds ignore-error to a cache-to spec (§35).
# Why: never corrupt a bare shorthand ref; warn instead.
# From: Issue #1683
_ci_cache_to_spec() {
    local val="$1"
    case "${val}" in
        *ignore-error=*) printf '%s\n' "${val}" ;;
        type=*) printf '%s,ignore-error=true\n' "${val}" ;;
        *)
            ci_log "[CI-WARN-BUILD-0012]" "value=\"${val}\" reason=\"shorthand cache-to has no ignore-error; use type=registry,ref=...\""
            printf '%s\n' "${val}"
            ;;
    esac
}

# What: Build one service image once and load it locally.
# Why: BUILD != PUBLISH; a push failure must not rebuild.
# From: Issue #1683
_ci_docker_build() {
    local service="$1" identity="$2" platform="$3"
    local context tag a build_type
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    context="$(_ci_required_field "${service}" context)" || return 2
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")"
    # What: the Dockerfile must declare ARG BUILD_IDENTITY.
    # Why: else a stale cached apk layer ships silently.
    # From: Issue #1683 | PR #1858
    if ! grep -qx 'ARG BUILD_IDENTITY' "${context}/Dockerfile"; then
        ci_log "[CI-ERROR-BUILD-0013]" "service=\"${service}\" path=\"${context}/Dockerfile\" reason=\"no ARG BUILD_IDENTITY; layer cache could ship stale packages\""
        return 2
    fi
    local -a args=()
    # What: rust builds from repo-root, not service dir.
    # Why: bind-mount + workspace COPYs need the tree.
    # From: Issue #1683
    if [ "${build_type}" = rust ]; then
        args+=(--file "${context}/Dockerfile")
        context="."
    fi
    # What: apk stages bind-mount ci.sh via context.
    # Why: apk-setup runs in bare final; ci.sh absent.
    # From: Issue #1683
    if [ "${build_type}" = apk ]; then
        args+=(--build-context "ci-scripts=${CI_SCRIPT_DIR}")
    fi
    # What: capture labels + build-args before reading them.
    # Why: < <(...) drops a failure; never build without.
    # From: Issue #1683 | PR #1858
    local labels bargs
    labels="$(_ci_oci_labels "${service}")" || return 2
    bargs="$(ci_cmd_build_args "${service}" --bare "${platform}")" || return 2
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--label "${a}")
    done <<< "${labels}"
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-arg "${a}")
    done <<< "${bargs}"
    # What: the build identity keys every layer's cache.
    # Why: ARG change reruns RUN; apk repos never do.
    # From: Issue #1683 | PR #1858
    args+=(--build-arg "BUILD_IDENTITY=${identity}")
    # What: the build type's CI variables as build-args.
    # Why: repo/org variables reach the builder (AG-CI-006).
    # From: Issue #1683 | PR #1858
    local vnames vname vval vrc
    vnames="$(_ci_block_entry_list build_variables "" "${build_type}")"
    while IFS= read -r vname; do
        [ -n "${vname}" ] || continue
        vrc=0
        vval="$(_ci_variable_value "${vname}")" || vrc=$?
        case "${vrc}" in
            0) args+=(--build-arg "${vname}=${vval}") ;;
            1) ;;
            *) return 2 ;;
        esac
    done <<< "${vnames}"
    # What: value-less --build-arg passes proxy from env.
    # Why: predefined args: used by RUN, not in history.
    # From: Issue #1683 | PR #1858
    while IFS= read -r a; do
        args+=(--build-arg "${a}")
    done < <(_ci_proxy_names)
    _ci_procsub_ok "$!" 0 || return 2
    # What: SOT-owned named build contexts (name=path).
    # Why: Dockerfile COPY --from derives it; SOT owns list.
    # From: Issue #1683
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-context "${a}")
    done < <(_ci_block_entry_list services "${service}" external_contexts)
    _ci_procsub_ok "$!" 0 || return 2
    # What: mount build-time secrets at runtime.
    # Why: leak-safe --secret; cleanup removes after.
    # From: Issue #1683
    local secret_dir sf
    secret_dir="$(_ci_runtime_secret_dir)"
    if [ -d "${secret_dir}" ]; then
        for sf in "${secret_dir}"/*; do
            [ -f "${sf}" ] && args+=(--secret "id=$(basename "${sf}"),src=${sf}")
        done
    fi
    # What: per-service registry cache-from/to (§35).
    # Why: caller scopes ref per service; a miss is fine.
    # From: Issue #1683
    [ -n "${CI_BUILD_CACHE_FROM:-}" ] && args+=(--cache-from "${CI_BUILD_CACHE_FROM}")
    [ -n "${CI_BUILD_CACHE_TO:-}" ] && args+=(--cache-to "$(_ci_cache_to_spec "${CI_BUILD_CACHE_TO}")")
    # What: retry buildx and capture its output once.
    # Why: ci_error already shows raw; avoid double output.
    # From: Issue #1683
    local buildlog rc=0
    buildlog="$(_ci_retry buildx docker buildx build --load --platform "${platform}" --tag "${tag}" "${args[@]}" "${context}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf '%s\n' "${buildlog}" >&2
    printf '%s\n' "${tag}"
}

# What: In-image apk setup: repos, update, upgrade, add.
# Why: one owner for http repos + update+upgrade + packages.
# From: Issue #1683
ci_cmd_apk_setup() {
    sed -i 's|^https://|http://|' /etc/apk/repositories
    apk update --no-cache
    apk upgrade --no-cache
    if [ "$#" -gt 0 ]; then
        apk add --no-cache "$@"
    fi
}

# What: rust-build cleanup state; globals, not locals.
# Why: an EXIT trap runs after locals are gone.
# From: Issue #1683 | PR #1858
_CI_RB_DISTCC=0
_CI_RB_CA=0
_CI_RB_CA_FILE=/usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt

# What: stop the distcc pump if rust-build started it.
# Why: a failed stop leaves a pump; raw output shown.
# From: Issue #1683 | PR #1858
_ci_rust_stop_pump() {
    local out
    [ "${_CI_RB_DISTCC}" = 1 ] || return 0
    _CI_RB_DISTCC=0
    out="$(distcc-pump --shutdown 2>&1)" && return 0
    ci_error "[CI-ERROR-RUSTBUILD-0007]" "reason=\"distcc-pump shutdown failed\"" "${out}"
    return 1
}

# What: EXIT trap: stop pump, drop proxy CA, keep status.
# Why: the proxy CA must not outlive the build step.
# From: Issue #1683 | PR #1858
_ci_rust_build_cleanup() {
    local status=$?
    local out
    local failed=0
    if ! _ci_rust_stop_pump; then
        failed=1
    fi
    if [ "${_CI_RB_CA}" = 1 ]; then
        _CI_RB_CA=0
        rm -f "${_CI_RB_CA_FILE}"
        if ! out="$(update-ca-certificates 2>&1)"; then
            ci_error "[CI-ERROR-RUSTBUILD-0008]" "reason=\"proxy CA not removed from the trust store\"" "${out}"
            failed=1
        fi
    fi
    if [ "${failed}" -eq 0 ]; then
        return 0
    fi
    # What: failed cleanup fails the step; keeps its rc.
    # Why: a build error code must not be replaced by 1.
    # From: Issue #1683 | PR #1858
    if [ "${status}" -ne 0 ]; then
        exit "${status}"
    fi
    exit 1
}

# What: In-image rust builder; sccache, opt-in distcc.
# Why: one owner for dns/ui/watchdog builders (was 3x).
# From: Issue #1683
ci_cmd_rust_build() {
    local service="${1:-}" crate="${2:-}" mode="${3:-build}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${crate}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0002]" "reason=\"crate arg required\""; return 2; }
    # What: mode build (real+cp) or deps (pre-cache, no cp).
    # Why: services with stub-src dep-cache stage call deps.
    case "${mode}" in build|deps) ;; *) ci_log "[CI-ERROR-RUSTBUILD-0005]" "mode=\"${mode}\" reason=\"mode must be build or deps\""; return 2 ;; esac
    local musl_target="${MUSL_TARGET:-}"
    [ -n "${musl_target}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0003]" "reason=\"MUSL_TARGET env required\""; return 2; }
    # What: MUSL_TARGET must be the build-tools rustc host.
    # Why: apk Rust has no rustup; host std is the only one.
    # From: Issue #1683 | PR #1858
    local rustc_info
    rustc_info="$(rustc -vV)" || { ci_log "[CI-ERROR-RUSTBUILD-0004]" "reason=\"rustc -vV failed in build-tools\""; return 2; }
    grep -qx "host: ${musl_target}" <<<"${rustc_info}" || { ci_error "[CI-ERROR-RUSTBUILD-0006]" "target=\"${musl_target}\" reason=\"MUSL_TARGET is not the build-tools rustc host\"" "${rustc_info}"; return 2; }
    local key_prefix="lancache-${service}" ccache_dir="${CI_TMPDIR}/ccache-${service}"
    # What: distcc bypasses pump for aws-lc headers.
    # Why: pump can't see generated headers; would fail.
    # From: Issue #1533
    mkdir -p /usr/local/lib/distcc
    local distcc_bin
    distcc_bin="$(command -v distcc)"
    cp "${distcc_bin}" /usr/local/bin/distcc-real
    printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'distcc_real="/usr/local/bin/distcc-real"' \
      'wrapper_self="/usr/local/bin/lancache-distcc-wrapper"' \
      'wrapper_dir="/usr/local/lib/distcc"' \
      'compiler_name="$(basename "$0")"' \
      'case "$compiler_name" in' \
      '  cc|gcc|c++|g++)' \
      '    real_compiler="$compiler_name"' \
      '    local_compiler="/usr/bin/$real_compiler"' \
      '    ;;' \
      '  *)' \
      '    if [ "$#" -ge 1 ] && [ -x "${1:-}" ]; then' \
      '      if ! resolved_arg1="$(readlink -f "$1")"; then' \
      '        echo "[ERROR] lancache-distcc-wrapper: readlink -f $1 failed." >&2' \
      '        exit 1' \
      '      fi' \
      '      case "$resolved_arg1" in' \
      '        "$wrapper_self"|"$wrapper_dir"/*)' \
      '          echo "[ERROR] lancache-distcc-wrapper: refusing to dispatch $1 back to itself (real-compiler resolution must happen before the distcc masquerade PATH is active)." >&2' \
      '          exit 1' \
      '          ;;' \
      '      esac' \
      '      real_compiler="$1"' \
      '      local_compiler="$1"' \
      '      shift' \
      '    else' \
      '      echo "[INFO] lancache-distcc-wrapper: unrecognized invocation (argv0=$0); defaulting to cc." >&2' \
      '      real_compiler="cc"' \
      '      local_compiler="/usr/bin/cc"' \
      '    fi' \
      '    ;;' \
      'esac' \
      'normalize_argument() {' \
      '  arg="$1"' \
      '  case "$arg" in' \
      '    -I*|-isystem*)' \
      '      case "$arg" in' \
      '        -I*) echo "${arg#-I}" ;;' \
      '        -isystem*) echo "${arg#-isystem}" ;;' \
      '      esac' \
      '      return' \
      '      ;;' \
      '  esac' \
      '  printf "%s\n" "$arg"' \
      '}' \
      'matches_aws_lc_generated_path() {' \
      '  arg="$1"' \
      '  case "$arg" in' \
      '    *aws-lc-sys*|*aws_lc_sys*)' \
      '      case "$arg" in' \
      '        *generated*|*out*|*target*/*/build/*) return 0;;' \
      '      esac' \
      '      ;;' \
      '  esac' \
      '  return 1' \
      '}' \
      'for arg in "$@"; do' \
      '  normalized_arg="$(normalize_argument "$arg")"' \
      '  if matches_aws_lc_generated_path "$normalized_arg"; then' \
      '    matched_arg="$normalized_arg"' \
      '    break' \
      '  fi' \
      'done' \
      'if [ -n "${matched_arg:-}" ]; then' \
      '  echo "[INFO] bypassing distcc-pump for generated-header input: $matched_arg" >&2' \
      '  if [ -n "${DISTCC_HOSTS_NO_PUMP:-}" ]; then' \
      '    env -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID DISTCC_HOSTS="$DISTCC_HOSTS_NO_PUMP" "$distcc_real" "$real_compiler" "$@"' \
      '    exit $?' \
      '  fi' \
      '  echo "[INFO] no non-pump hosts configured; compiling through local compiler path." >&2' \
      '  env -u DISTCC_HOSTS -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID -u DISTCC_FALLBACK "$local_compiler" "$@"' \
      '  exit $?' \
      'fi' \
      'exec "$distcc_real" "$real_compiler" "$@"' \
      > /usr/local/bin/lancache-distcc-wrapper
    chmod +x /usr/local/bin/lancache-distcc-wrapper
    local wrapper
    for wrapper in cc gcc c++ g++; do ln -sf /usr/local/bin/lancache-distcc-wrapper "/usr/local/lib/distcc/${wrapper}"; done
    ln -sf /usr/local/bin/lancache-distcc-wrapper "${distcc_bin}"
    # What: rustc wrapper: distcc passthrough, else sccache.
    # Why: distcc bypasses sccache masquerade wrapping.
    printf '%s\n' '#!/bin/sh' 'case "${1:-}" in' '  distcc|*/distcc) exec "$@" ;;' '  *) exec /usr/local/bin/sccache "$@" ;;' 'esac' > /usr/local/bin/lancache-rustc-wrapper
    chmod +x /usr/local/bin/lancache-rustc-wrapper
    local ccache_enabled=0 original_path="${PATH}"
    _CI_RB_DISTCC=0
    _CI_RB_CA=0
    trap _ci_rust_build_cleanup EXIT
    # What: trust proxy CA for cargo's crates.io fetch.
    # Why: cleanup trap removes it; never persisted.
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then
        cp /run/secrets/project_selfhosted_proxy_ca "${_CI_RB_CA_FILE}"
        update-ca-certificates >/dev/null
        _CI_RB_CA=1
    fi
    local real_cc real_gcc real_cxx real_gxx
    real_cc="$(PATH="${original_path}" command -v cc)"
    real_gcc="$(PATH="${original_path}" command -v gcc)"
    real_cxx="$(PATH="${original_path}" command -v c++)"
    real_gxx="$(PATH="${original_path}" command -v g++)"
    configure_sccache() {
        unset CARGO_MAKEFLAGS MAKEFLAGS
        _ci_sccache_env "${key_prefix}" /usr/local/bin/lancache-rustc-wrapper
        if [ -s /run/secrets/sccache_dist_config ]; then export SCCACHE_CONF=/run/secrets/sccache_dist_config; sccache --dist-status; fi
    }
    disable_distcc() {
        _ci_rust_stop_pump || return 1
        unset DISTCC_POTENTIAL_HOSTS DISTCC_HOSTS DISTCC_HOSTS_NO_PUMP DISTCC_FALLBACK CC GCC CXX GXX INCLUDE_SERVER_PORT INCLUDE_SERVER_PID
        PATH="${original_path}"; export PATH
    }
    resolve_distcc_wrapper_dir() {
        local candidate
        for candidate in /usr/local/lib/distcc /usr/lib/distcc; do
            if [ -x "${candidate}/cc" ] && [ -x "${candidate}/gcc" ] && [ -x "${candidate}/c++" ] && [ -x "${candidate}/g++" ]; then
                printf '%s\n' "${candidate}"; return 0
            fi
        done
        echo "distcc wrapper directory not found" >&2; return 1
    }
    # What: read farm host's real compiler identity.
    # Why: ccache content-check misses remote bump.
    extract_remote_toolchain_id() {
        rm -f "${CI_TMPDIR}/ccache-remote-toolchain-id"
        if command -v readelf >/dev/null 2>&1; then
            local readelf_comment_section
            if readelf_comment_section="$(_ci_capture 0 readelf -p .comment "$1")"; then
                sed -n 's/^ *\[[^]]*\] *//p' <<<"${readelf_comment_section}" > "${CI_TMPDIR}/ccache-remote-toolchain-id"
            fi
        fi
    }
    # What: split pump/non-pump hosts, set up distcc.
    # Why: aws-lc-sys generated headers must bypass pump.
    # From: Issue #1533
    configure_distcc() {
        if [ -s /run/secrets/distcc_potential_hosts ]; then
            local distcc_probe_dir
            distcc_probe_dir="$(mktemp -d -p "${CI_TMPDIR}")"
            DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"; export DISTCC_POTENTIAL_HOSTS
            local -a distcc_host_specs; read -ra distcc_host_specs <<<"${DISTCC_POTENTIAL_HOSTS}"
            local distcc_hosts="" distcc_hosts_with_pump="" distcc_hosts_without_pump="" distcc_host_spec distcc_host_base
            for distcc_host_spec in "${distcc_host_specs[@]}"; do
                distcc_host_base="${distcc_host_spec%%,*}"
                if [ -n "${distcc_host_base}" ]; then distcc_hosts="${distcc_hosts:+${distcc_hosts} }${distcc_host_base}"; fi
                case "${distcc_host_spec}" in
                    *,cpp*) distcc_hosts_with_pump="${distcc_hosts_with_pump:+${distcc_hosts_with_pump} }${distcc_host_base}" ;;
                    *) distcc_hosts_without_pump="${distcc_hosts_without_pump:+${distcc_hosts_without_pump} }${distcc_host_spec}" ;;
                esac
            done
            if [ -z "${distcc_hosts}" ]; then
                rm -rf "${distcc_probe_dir}"
                echo "DISTCC_POTENTIAL_HOSTS does not contain usable distcc hosts" >&2; return 1
            fi
            local distcc_pump_hosts="${distcc_hosts_with_pump:-}"
            distcc_hosts_without_pump="${distcc_hosts_without_pump:-${distcc_hosts}}"
            echo "[INFO] trying distcc path." >&2
            local distcc_wrapper_dir
            distcc_wrapper_dir="$(resolve_distcc_wrapper_dir)"
            export DISTCC_HOSTS_NO_PUMP="${distcc_hosts_without_pump}"
            export PATH="${distcc_wrapper_dir}:${PATH}" CC=cc GCC=gcc CXX=c++ GXX=g++ DISTCC_FALLBACK=0
            _CI_RB_DISTCC=1
            if [ -n "${distcc_pump_hosts}" ]; then
                export DISTCC_POTENTIAL_HOSTS="${distcc_pump_hosts}"
                unset DISTCC_HOSTS
                local distcc_pump_env
                if ! distcc_pump_env="$(distcc-pump --startup 2>"${distcc_probe_dir}/distcc-pump.log")"; then
                    disable_distcc; rm -rf "${distcc_probe_dir}"
                    echo "[INFO] distcc pump unavailable; continuing with normal local C compiler." >&2; return 0
                fi
                eval "${distcc_pump_env}"
                local -a distcc_hosts_arr; read -ra distcc_hosts_arr <<<"${DISTCC_HOSTS:-}"
                local distcc_pump_real_hosts="" distcc_host_token
                for distcc_host_token in "${distcc_hosts_arr[@]}"; do case "${distcc_host_token}" in --*) ;; *) distcc_pump_real_hosts=1 ;; esac; done
                if [ -z "${distcc_pump_real_hosts}" ]; then unset DISTCC_HOSTS; fi
                PATH="${distcc_wrapper_dir}:${PATH}"
                export PATH DISTCC_HOSTS_NO_PUMP CC=cc GCC=gcc CXX=c++ GXX=g++
            else
                export DISTCC_HOSTS="${distcc_hosts}"
            fi
            printf '%s\n' 'int main(void) { return 0; }' > "${distcc_probe_dir}/distcc-probe.c"
            if ! cc -c "${distcc_probe_dir}/distcc-probe.c" -o "${distcc_probe_dir}/distcc-probe.o" >"${distcc_probe_dir}/distcc-probe.log" 2>&1; then
                disable_distcc; rm -rf "${distcc_probe_dir}"
                echo "[INFO] distcc probe unavailable; continuing with normal local C compiler." >&2; return 0
            fi
            extract_remote_toolchain_id "${distcc_probe_dir}/distcc-probe.o"
            rm -rf "${distcc_probe_dir}"
        else
            echo "[INFO] distcc disabled (no distcc_potential_hosts secret present)." >&2
        fi
    }
    disable_ccache() {
        ccache_enabled=0
        unset CCACHE_REMOTE_STORAGE CCACHE_DIR CCACHE_COMPILERCHECK CCACHE_PREFIX CCACHE_EXTRAFILES CCACHE_BASEDIR
        rm -f "${CI_TMPDIR}/ccache-toolchain-id" "${CI_TMPDIR}/ccache-remote-toolchain-id"
        export CC=cc GCC=gcc CXX=c++ GXX=g++
    }
    # What: wrap distcc with ccache (Redis) once distcc up.
    # Why: content-check + remote-id guard stale toolchain.
    configure_ccache() {
        if [ "${_CI_RB_DISTCC}" = "1" ] && [ -s /run/secrets/ccache_redis_url ]; then
            if [ ! -s "${CI_TMPDIR}/ccache-remote-toolchain-id" ]; then
                echo "[INFO] no verified remote distcc toolchain identity; continuing with plain distcc (no cache layer)." >&2; return 0
            fi
            local ccache_probe_dir
            ccache_probe_dir="$(mktemp -d -p "${CI_TMPDIR}")"
            echo "[INFO] wrapping distcc with ccache (Redis remote storage)." >&2
            local ccache_redis_endpoint
            ccache_redis_endpoint="$(cat /run/secrets/ccache_redis_url)"
            case "${ccache_redis_endpoint}" in
                redis://*|redis+unix:*) ;;
                *) ccache_redis_endpoint="redis://${ccache_redis_endpoint}" ;;
            esac
            export CCACHE_REMOTE_STORAGE="${ccache_redis_endpoint}"
            export CCACHE_DIR="${ccache_dir}"
            export CCACHE_PREFIX=distcc
            export CCACHE_COMPILERCHECK=content
            printf '%s' "${BUILD_TOOLS_IMAGE:-}" > "${CI_TMPDIR}/ccache-toolchain-id"
            export CCACHE_EXTRAFILES="${CI_TMPDIR}/ccache-toolchain-id:${CI_TMPDIR}/ccache-remote-toolchain-id"
            export CCACHE_BASEDIR="${ccache_probe_dir}"
            export CC="ccache ${real_cc}" GCC="ccache ${real_gcc}" CXX="ccache ${real_cxx}" GXX="ccache ${real_gxx}"
            ccache_enabled=1
            printf '%s\n' 'int main(void) { return 0; }' > "${ccache_probe_dir}/ccache-probe.c"
            # What: probe compiles in isolated ccache dir.
            # Why: keep real cache clean; word-split-safe.
            local ccache_probe_cache_dir="${ccache_probe_dir}/probe-cache"
            mkdir -p "${ccache_probe_cache_dir}"
            if ! ( cd "${ccache_probe_dir}" && CCACHE_DIR="${ccache_probe_cache_dir}" ccache "${real_cc}" -c ccache-probe.c -o ccache-probe.o ) >"${ccache_probe_dir}/ccache-probe.log" 2>&1; then
                cat "${ccache_probe_dir}/ccache-probe.log" >&2
                disable_ccache; rm -rf "${ccache_probe_dir}"
                echo "[INFO] ccache probe unavailable; continuing with plain distcc (no cache layer)." >&2; return 0
            fi
            local ccache_probe_stats="${ccache_probe_dir}/ccache-probe-stats.log"
            ccache --print-stats > "${ccache_probe_stats}"
            local stat_err stat_ok
            stat_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' "${ccache_probe_stats}")" || return 2
            stat_ok="$(_ci_capture 1 grep -E '^remote_storage_(write|hit)[[:space:]]+[1-9]' "${ccache_probe_stats}")" || return 2
            if [ -n "${stat_err}" ] || [ -z "${stat_ok}" ]; then
                cat "${ccache_probe_stats}" >&2
                disable_ccache; rm -rf "${ccache_probe_dir}"
                echo "[INFO] ccache probe Redis round trip failed; continuing with plain distcc (no cache layer)." >&2; return 0
            fi
            rm -rf "${ccache_probe_dir}"
        else
            if [ "${_CI_RB_DISTCC}" != "1" ]; then
                echo "[INFO] ccache disabled (distcc is not enabled, nothing to wrap)." >&2
            else
                echo "[INFO] ccache disabled (no ccache_redis_url secret present)." >&2
            fi
        fi
    }
    # What: export release LTO/codegen vars, fail closed.
    # Why: no defaults; owner is PROJECT_CARGO_*.
    resolve_cargo_profile_overrides() {
        local lto="${PROJECT_CARGO_LTO:-}" cgu="${PROJECT_CARGO_CODEGENUNIT:-}"
        [ -n "${lto}" ] || { echo "PROJECT_CARGO_LTO is required (no default; Issue #1095)" >&2; return 1; }
        case "${lto}" in off|thin|fat|true|false) ;; *) echo "PROJECT_CARGO_LTO must be off|thin|fat|true|false (got '${lto}')" >&2; return 1;; esac
        [ -n "${cgu}" ] || { echo "PROJECT_CARGO_CODEGENUNIT is required (no default; Issue #1095)" >&2; return 1; }
        case "${cgu}" in ''|*[!0-9]*) echo "PROJECT_CARGO_CODEGENUNIT must be a positive integer (got '${cgu}')" >&2; return 1;; esac
        [ "${cgu}" -gt 0 ] || { echo "PROJECT_CARGO_CODEGENUNIT must be greater than zero" >&2; return 1; }
        export CARGO_PROFILE_RELEASE_LTO="${lto}" CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${cgu}"
        echo "[INFO] using CARGO_PROFILE_RELEASE_LTO=${lto} CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${cgu}." >&2
    }
    # What: CARGO_BUILD_JOBS or nproc-2 floored at 4.
    # Why: build parallelism owner (AG-CI-006).
    resolve_cargo_jobs() {
        local jobs="${CARGO_BUILD_JOBS:-}" jobs_source cores
        if [ -z "${jobs}" ]; then
            cores="$(_ci_capture 0 nproc)" || return 1
            jobs=$((cores - 2)); [ "${jobs}" -lt 4 ] && jobs=4
            jobs_source="auto-detected from ${cores} core(s)"
        else
            jobs_source="explicit CARGO_BUILD_JOBS"
        fi
        case "${jobs}" in ''|*[!0-9]*) echo "CARGO_BUILD_JOBS must be a positive integer" >&2; return 1;; esac
        [ "${jobs}" -gt 0 ] || { echo "CARGO_BUILD_JOBS must be greater than zero" >&2; return 1; }
        echo "[INFO] using ${jobs} job(s) (${jobs_source})." >&2
        printf '%s\n' "${jobs}"
    }
    # What: build, fall back ccache->distcc->local on fail.
    # Why: accel outage: must not fail correct build.
    run_cargo_build() {
        local cargo_log cargo_status_file cargo_status
        cargo_log="$(mktemp -p "${CI_TMPDIR}")"; cargo_status_file="$(mktemp -p "${CI_TMPDIR}")"
        { set +e; cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" -p "${crate}" 2>&1; echo "$?" >"${cargo_status_file}"; set -e; } | tee "${cargo_log}"
        cargo_status="$(cat "${cargo_status_file}")"; rm -f "${cargo_status_file}"
        if [ "${cargo_status}" = "0" ]; then rm -f "${cargo_log}"; return 0; fi
        if [ "${ccache_enabled:-0}" = "1" ]; then
            disable_ccache
            echo "[INFO] ccache build path unavailable; retrying with plain distcc." >&2
            local ccache_retry_status_file
            ccache_retry_status_file="$(mktemp -p "${CI_TMPDIR}")"
            { set +e; cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" -p "${crate}" 2>&1; echo "$?" >"${ccache_retry_status_file}"; set -e; } | tee -a "${cargo_log}"
            cargo_status="$(cat "${ccache_retry_status_file}")"; rm -f "${ccache_retry_status_file}"
            if [ "${cargo_status}" = "0" ]; then echo "[INFO] plain distcc fallback (ccache disabled) completed." >&2; rm -f "${cargo_log}"; return 0; fi
            echo "[INFO] plain distcc fallback also failed; falling through to local-compiler retry." >&2
        fi
        if [ "${_CI_RB_DISTCC}" = "1" ]; then
            disable_distcc
            unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX
            echo "[INFO] distcc build path unavailable; retrying with normal local C compiler." >&2
            if cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" -p "${crate}"; then
                echo "[INFO] normal local C compiler fallback completed." >&2; rm -f "${cargo_log}"; return 0
            fi
            rm -f "${cargo_log}"; return 1
        fi
        local sccache_hit
        sccache_hit="$(_ci_capture 1 grep -Eia 'sccache: error|Fixed token mismatch|Timed out waiting for server startup|SCCACHE_' "${cargo_log}")" || return 2
        if [ -n "${sccache_hit}" ]; then
            unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX
            echo "[INFO] sccache build path unavailable; retrying with sccache disabled." >&2
            rm -f "${cargo_log}"
            if cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" -p "${crate}"; then
                echo "[INFO] sccache-disabled fallback completed." >&2; return 0
            fi
            return 1
        fi
        echo "[ERROR] cargo build failed for reasons unrelated to sccache or distcc; not retrying." >&2
        rm -f "${cargo_log}"; return "${cargo_status}"
    }
    configure_sccache
    configure_distcc
    configure_ccache
    resolve_cargo_profile_overrides
    local cargo_jobs
    cargo_jobs="$(resolve_cargo_jobs)"
    # What: drop crate's stale artifact before real build.
    # Why: dep pre-cache stub rlib outdates COPYed src.
    if [ "${mode}" = "build" ]; then
        cargo clean -p "${crate}" --release --target "${musl_target}"
    fi
    run_cargo_build
    # What: dump ccache stats; mid-build Redis error OK.
    # Why: binary correct; only cache reuse degraded.
    if [ "${ccache_enabled:-0}" = "1" ]; then
        ccache -s
        local ccache_final_stats
        ccache_final_stats="$(mktemp -p "${CI_TMPDIR}")"
        ccache --print-stats > "${ccache_final_stats}"
        local final_err
        final_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' "${ccache_final_stats}")" || return 2
        if [ -n "${final_err}" ]; then
            echo "[INFO] ccache recorded a Redis remote-storage error during the build; binary unaffected, later builds may miss cache reuse." >&2
            cat "${ccache_final_stats}" >&2
        fi
        rm -f "${ccache_final_stats}"
    fi
    # What: copy built binary out only for real build.
    # Why: deps pre-cache pass produces no shippable binary.
    if [ "${mode}" = "build" ]; then
        cp "target/${musl_target}/release/${crate}" "/build/${crate}-out"
    fi
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
    ci_error "[CI-WARN-RESOLVE-0007]" "tag=\"${tag}\" rc=${rc} reason=\"registry probe failed; UNKNOWN\"" "${raw}"
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
    ) 2>&1
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
    local fallback="${CI_TRIVY_FALLBACK_DIR:-${CI_TMPDIR}/trivy-cache-fallback}"
    case "${shared}" in
        /tmp|/tmp/*) ci_log "[CI-ERROR-SCAN-0007]" "reason=\"shared trivy cache-dir must not be tmpfs /tmp\" got=\"${shared}\""; return 2 ;;
    esac
    case "${fallback}" in
        /tmp|/tmp/*) ci_log "[CI-ERROR-SCAN-0018]" "reason=\"fallback trivy cache-dir must not be tmpfs /tmp\" got=\"${fallback}\""; return 2 ;;
    esac
    local probe_out mkerr
    if probe_out="$(_ci_trivy_dir_writable "${shared}")"; then
        printf 'dir=%s source=nfs-shared\n' "${shared}"
        return 0
    fi
    ci_error "[CI-INFO-SCAN-0008]" "shared=\"${shared}\" reason=\"not mounted/writable; falling back to local disk\"" "${probe_out}"
    if ! mkerr="$(mkdir -p "${fallback}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0009]" "dir=\"${fallback}\" reason=\"could not create local fallback trivy cache-dir\"" "${mkerr}"
        return 2
    fi
    if ! probe_out="$(_ci_trivy_dir_writable "${fallback}")"; then
        ci_error "[CI-ERROR-SCAN-0019]" "dir=\"${fallback}\" reason=\"fallback trivy cache-dir failed write probe\"" "${probe_out}"
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
    next_update="$(_ci_capture 0 jq -r '.NextUpdate // empty' "${meta}")" || return 1
    [ -n "${next_update}" ] || return 1
    next_epoch="$(_ci_capture 0 date -d "${next_update}" +%s)" || return 1
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
    local poll="${CI_TRIVY_LOCK_POLL:-5}" waited=0 lock_mtime age mkerr
    # What: cache-dir must exist before the lock mkdir.
    # Why: a missing parent must not misread as "locked".
    # From: Issue #1683
    if ! mkerr="$(mkdir -p "${cache_dir}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0013]" "dir=\"${cache_dir}\" reason=\"could not create cache-dir for lock\"" "${mkerr}"
        return 2
    fi
    while :; do
        mkerr="$(mkdir "${lock_dir}" 2>&1)" && break
        if [ -d "${lock_dir}" ]; then
            # What: no lock age: retry if gone, else stop.
            # Why: age 0 would reclaim a live holder's lock.
            # From: Issue #1683 | PR #1858
            if ! lock_mtime="$(stat -c %Y "${lock_dir}" 2>&1)"; then
                if [ ! -d "${lock_dir}" ]; then
                    continue
                fi
                ci_error "[CI-ERROR-SCAN-0020]" "lock=\"${lock_dir}\" reason=\"cannot read lock age; not reclaiming\"" "${lock_mtime}"
                return 2
            fi
            age=$(( $(date +%s) - lock_mtime ))
            if [ "${age}" -gt "${stale_after}" ]; then
                ci_log "[CI-WARN-SCAN-0010]" "lock=\"${lock_dir}\" age=${age} stale_after=${stale_after} reason=\"reclaiming stale trivy DB refresh lock\""
                rm -rf -- "${lock_dir}"
                # What: a failed reclaim must not spin.
                # Why: e.g. NFS can leave it behind.
                # From: Issue #1683
                if [ -d "${lock_dir}" ]; then
                    ci_log "[CI-ERROR-SCAN-0015]" "lock=\"${lock_dir}\" reason=\"stale lock reclaim did not remove it\""
                    return 2
                fi
                continue
            fi
            if [ "${waited}" -ge "${lock_timeout}" ]; then
                ci_log "[CI-ERROR-SCAN-0011]" "lock=\"${lock_dir}\" timeout=${lock_timeout} reason=\"timed out waiting for trivy DB refresh lock\""
                return 2
            fi
            sleep "${poll}"
            waited=$(( waited + poll ))
            continue
        fi
        # What: mkdir failed but no lock dir exists.
        # Why: never poll blind; fail closed with evidence.
        # From: Issue #1683
        ci_error "[CI-ERROR-SCAN-0014]" "lock=\"${lock_dir}\" reason=\"lock mkdir failed; not a held lock\"" "${mkerr}"
        return 2
    done
    # What: releases the lock on any return from this call.
    # Why: an unreleased lock wedges every later caller.
    trap 'rm -rf -- "${lock_dir:-}"' RETURN
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
        ci_log "[CI-ERROR-SCAN-0012]" "reason=\"locked DB refresh failed; refusing an unlocked concurrent write\""
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
    ref="$(_ci_image_ref "${service}" "${digest}")"
    report="$(mktemp "${CI_TMPDIR}/ci-trivy.XXXXXX")"
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
    local base head bm refs v=UNKNOWN
    if ! refs="$(_ci_diff_refs)"; then
        ci_log "[CI-INFO-IMPACT-0005]" "service=\"${service}\" platform=\"${platform}\" reason=\"diff refs lookup failed; UNKNOWN\""
        printf 'UNKNOWN\n'
        return 0
    fi
    read -r base head <<<"${refs}"
    if [ -z "${base}" ]; then
        ci_log "[CI-INFO-IMPACT-0003]" "service=\"${service}\" platform=\"${platform}\" reason=\"no base ref for this event; UNKNOWN\""
        printf 'UNKNOWN\n'
        return 0
    fi
    bm="$(mktemp -p "${CI_TMPDIR}")" || { printf 'UNKNOWN\n'; return 0; }
    if _ci_manifest_at "${base}" "${bm}" && [ -s "${bm}" ]; then
        v="$(_ci_impact_classify "${service}" "${platform}" "${identity}" "${base}" "${bm}")"
    else
        ci_log "[CI-INFO-IMPACT-0002]" "base=\"${base}\" reason=\"no SOT at base; UNKNOWN, escalate, BUILD DISACK\""
    fi
    rm -f "${bm}"
    ci_log "[CI-INFO-IMPACT-0004]" "service=\"${service}\" platform=\"${platform}\" base=\"${base}\" head=\"${head}\" impact=${v}"
    printf '%s\n' "${v}"
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
    # What: log in before the resolver reads GHCR.
    # Why: an anonymous probe is 403 -> UNKNOWN, no build.
    # From: Issue #1683 | PR #1858
    _ci_require_ghcr_auth || return "$?"
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
    if [ "${build_type}" = "rust" ] && _ci_cas_lookup "${identity}" >/dev/null; then
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
            ci_log "[CI-ERROR-PUBLISH-0005]" "service=\"${service}\" platform=\"${platform}\" reason=\"docker publish failed\""
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

# What: build, then publish+verify only what was built.
# Why: one owner for the chain; a reuse has nothing to push.
# From: Issue #1683 | PR #1858
ci_cmd_ship() {
    local service="${1:-}" platform="${2:-}" out digest
    if [ -z "${service}" ] || [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-SHIP-0001]" "reason=\"service and platform args required\""
        return 2
    fi
    out="$(ci_cmd_build "${service}" "${platform}")" || return "$?"
    printf '%s\n' "${out}"
    case "${out}" in *" result=built "*) ;; *) return 0 ;; esac
    out="$(ci_cmd_publish "${service}" "${platform}")" || return "$?"
    printf '%s\n' "${out}"
    digest="$(_ci_record_field "${out}" published)"
    if [ -z "${digest}" ]; then
        ci_error "[CI-ERROR-SHIP-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"publish reported no digest\"" "${out}"
        return 2
    fi
    ci_cmd_verify "${service}" "${digest}" "${platform}"
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
    # What: smoke-test every built image at its digest.
    # Why: §25 SERVICE_TESTED follows IDENTITY_VERIFIED.
    # From: Issue #1683 | PR #1858
    if [ "$(ci_service_field "${service}" build_type)" = toolchain ]; then
        local CI_TOOLCHAIN_IMAGE
        CI_TOOLCHAIN_IMAGE="$(_ci_image_ref "${service}" "${expected}")"
        _ci_test_toolchain "${service}" || return "$?"
    else
        local -x CI_SERVICE_IMAGE
        CI_SERVICE_IMAGE="$(_ci_image_ref "${service}" "${expected}")"
        _ci_smoke_service "${service}" || return "$?"
    fi
    printf 'service=%s verified=%s\n' "${service}" "${seen}"
}

# What: rc 0 only if CI_RUST_VALIDATION is exactly "true".
# Why: AG-VAL-008: CI rust validation is off by default.
# From: Issue #1683
_ci_rust_validation_enabled() {
    local v
    v="$(_ci_variable CI_RUST_VALIDATION)" || return 2
    [ "${v//\"/}" = true ]
}

# What: Run AG-VAL-008 cargo fmt/clippy/test for a service.
# Why: CI never runs cargo check; the variable gates rest.
# From: Issue #1683 | PR #1858
_ci_test_rust() {
    local service="$1" ctx rc=0
    _ci_rust_validation_enabled || rc=$?
    case "${rc}" in
        0) ;;
        1) printf 'service=%s tested=SKIP reason="CI_RUST_VALIDATION is not true (AG-VAL-008)"\n' "${service}"; return 0 ;;
        *) return 2 ;;
    esac
    if [ -n "${CI_RUST_TEST_CMD:-}" ]; then
        "${CI_RUST_TEST_CMD}" "${service}"
        return "$?"
    fi
    ctx="$(ci_service_field "${service}" crate)"
    if [ -z "${ctx}" ]; then
        ci_log "[CI-ERROR-TEST-0005]" "service=\"${service}\" reason=\"no crate in SOT\""
        return 2
    fi
    # What: workspace-root cargo on service's own crate.
    # Why: build context is no crate; AG-VAL-008 per crate.
    # From: PR #1858
    ( _ci_sccache_env "lancache-${service}" \
        && cd "${CI_REPO_ROOT:-.}" \
        && cargo fmt --check -p "${ctx}" \
        && cargo clippy --locked --all-targets -p "${ctx}" -- -D warnings \
        && cargo test --locked -p "${ctx}" ) || return 1
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Assert smoke tools exist and smoke runs pass.
# Why: SOT owns both lists; present is not runnable.
# From: Issue #1683 | PR #1858
_ci_test_toolchain() {
    local service="$1" image tools runs t
    if [ -n "${CI_TOOLCHAIN_TEST_CMD:-}" ]; then
        "${CI_TOOLCHAIN_TEST_CMD}" "${service}"
        return "$?"
    fi
    image="${CI_TOOLCHAIN_IMAGE:-}"
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-TEST-0006]" "service=\"${service}\" reason=\"CI_TOOLCHAIN_IMAGE required for the smoke\""
        return 2
    fi
    tools="$(_ci_build_tools_smoke smoke_tools)" || return 2
    runs="$(_ci_build_tools_smoke smoke_runs)" || return 2
    local -a tl=()
    while IFS= read -r t; do
        [ -n "${t}" ] && tl+=("${t}")
    done <<< "${tools}"
    # What: tools go as args; runs on stdin, one a line.
    # Why: a run holds spaces/pipes; stdin keeps it intact.
    # From: Issue #1683 | PR #1858
    docker run --rm -i "${image}" timeout --kill-after=30s --signal=TERM 14m \
        sh -c 'for t in "$@"; do command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }; done
               while IFS= read -r r; do sh -c "$r" >/dev/null || { echo "failed: $r" >&2; exit 1; }; done' \
        _ "${tl[@]}" <<< "${runs}" \
        || return 1
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Execute-smoke a product image's SOT smoke checks.
# Why: prove apk binaries run, not just exist.
# From: Issue #1613
_ci_smoke_service() {
    local service="$1" checks image c
    if [ -n "${CI_SMOKE_CMD:-}" ]; then
        "${CI_SMOKE_CMD}" "${service}"
        return "$?"
    fi
    checks="$(_ci_block_entry_list services "${service}" smoke)"
    if [ -z "${checks}" ]; then
        printf 'service=%s smoke=SKIP reason=no SOT smoke\n' "${service}"
        return 0
    fi
    image="${CI_SERVICE_IMAGE:-}"
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-TEST-0007]" "service=\"${service}\" reason=\"CI_SERVICE_IMAGE required for the smoke\""
        return 2
    fi
    local -a cl=()
    while IFS= read -r c; do [ -n "${c}" ] && cl+=("${c}"); done <<< "${checks}"
    local out
    for c in "${cl[@]}"; do
        if ! out="$(timeout --kill-after=30s --signal=TERM 5m docker run --rm --entrypoint sh "${image}" -c "${c}" 2>&1)"; then
            ci_error "[CI-ERROR-TEST-0008]" "service=\"${service}\" check=\"${c}\" reason=\"execute-smoke failed; missing lib?\"" "${out}"
            return 1
        fi
    done
    printf 'service=%s smoke=ok checks=%s\n' "${service}" "${#cl[@]}"
}

# What: Dispatch a service's source test by its build type.
# Why: image smoke runs at the built digest (verify, §25).
# From: Issue #1683 | PR #1858
_ci_default_test() {
    local service="$1" build_type
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    case "${build_type}" in
        rust) _ci_test_rust "${service}" ;;
        apk) printf 'service=%s tested=SKIP reason="no source tests; smoke runs at the built digest"\n' "${service}" ;;
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

# What: Write a CycloneDX SBOM for an image digest.
# Why: SBOM generate != vuln gate; shares the trivy cache.
# From: Issue #1683
_ci_trivy_sbom() {
    local service="$1" digest="$2" out="$3" ref cache_rec cache_dir raw rc=0
    ref="$(_ci_image_ref "${service}" "${digest}")" || return 2
    cache_rec="$(_ci_trivy_cache_dir)" || return 2
    cache_dir="$(_ci_record_field "${cache_rec}" dir)"
    raw="$(trivy image --format cyclonedx --cache-dir "${cache_dir}" --output "${out}" "${ref}" 2>&1)" || rc=$?
    { [ "${rc}" -eq 0 ] && [ -s "${out}" ]; } && return 0
    printf '%s\n' "${raw}" >&2
    return 1
}

# What: Scan a published digest for vulnerabilities.
# Why: /var/tmp staging (no tmpfs OOM), authed, fail-closed.
# From: Issue #1683
ci_cmd_scan() {
    local service="${1:-}" digest="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-SCAN-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${digest}" ] || { ci_log "[CI-ERROR-SCAN-0002]" "reason=\"digest arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local scan_cmd="${CI_SCAN_CMD:-_ci_trivy_scan}"
    local raw status
    if raw="$(TMPDIR="${CI_TMPDIR}" "${scan_cmd}" "${service}" "${digest}" 2>&1)"; then status=0; else status=$?; fi
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
    printf 'service=%s scanned=clean digest=%s tmpdir=%s\n' "${service}" "${digest}" "${CI_TMPDIR}"
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
        ci_error "[CI-WARN-RESOLVE-0010]" "ref=\"${ref}\" rc=${rc} reason=\"index read failed; UNKNOWN\"" "${raw}"
        return 2
    fi
    printf '%s' "${raw}"
}

# What: canonical sorted "platform=digest ..." values.
# Why: shared format for assemble/reconcile/candidate.
# From: Issue #1683
_ci_normalize_platform_digests() {
    local input="$1"
    printf '%s\n' "${input}" | tr ' ' '\n' | awk 'NF' | LC_ALL=C sort | tr '\n' ' '
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
    local repo registry sha tag idx grc=0 raw plats
    repo="$(_ci_repo)" || return 2
    registry="$(_ci_registry)" || return 2
    sha="${GITHUB_SHA:?GITHUB_SHA required}"
    tag="${registry}/${repo}/${service}:sha-${sha}"
    idx="$(_ci_registry_probe "${tag}")" || grc=$?
    [ "${grc}" -eq 0 ] || return 1
    raw="$(_ci_index_raw "${tag}")" || return 1
    plats="$(jq -r '.manifests[]? | select(.platform.os!="unknown" and .platform.architecture!="unknown") | "\(.platform.os)/\(.platform.architecture)=\(.digest)"' <<< "${raw}" | tr '\n' ' ')"
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
    ex_have="$(_ci_normalize_platform_digests "${existing#* }")"
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
    local repo registry sha target kv
    repo="$(_ci_repo)" || return 2
    registry="$(_ci_registry)" || return 2
    sha="${GITHUB_SHA:?GITHUB_SHA required}"
    target="${registry}/${repo}/${service}:sha-${sha}"
    local -a srcs=()
    for kv; do
        srcs+=("$(_ci_image_ref "${service}" "${kv#*=}")")
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
    want="$(_ci_normalize_platform_digests "${inputs}")"
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

# What: Print "<channel> <value>" for one channel field.
# Why: One release.channels reader; callers filter it.
# From: Issue #1683
_ci_channel_field() {
    awk -v f="$1" '
        /^release:[[:space:]]*$/ { inr = 1; next }
        inr && /^[A-Za-z]/ { inr = 0; inc = 0 }
        inr && /^  channels:[[:space:]]*$/ { inc = 1; next }
        inr && inc && /^  [A-Za-z]/ { inc = 0 }
        inc && /^    [A-Za-z0-9_.-]+:[[:space:]]*$/ { ch = $1; sub(/:$/, "", ch); next }
        inc && ch != "" && $1 == (f ":") {
            v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            print ch, v
        }
    ' "${CI_MANIFEST}"
}

# What: Channels whose field equals a value, one per line.
# Why: shared by mutable, ref and release-tag lookups.
# From: Issue #1683
_ci_channels_where() {
    local rows
    rows="$(_ci_channel_field "$1")" || return 2
    awk -v v="$2" '$2 == v { print $1 }' <<< "${rows}"
}

# What: Print the SOT's mutable release channels.
# Why: One channel list; promote never invents a second.
# From: Issue #1683
_ci_mutable_channels() {
    _ci_channels_where mutable true
}

# What: The branch ref whose pushes cut release tags.
# Why: the release-tag channel's ref; SOT is the owner.
# From: Issue #1683
_ci_release_ref() {
    local ch rows ref
    ch="$(_ci_channels_where release_tags true)" || return 2
    rows="$(_ci_channel_field ref)" || return 2
    ref="$(awk -v c="${ch%%$'\n'*}" '$1 == c { print $2 }' <<< "${rows}")"
    if [ -z "${ref}" ]; then
        ci_log "[CI-ERROR-RELEASE-0018]" "reason=\"SOT release.channels has no release_tags channel with a ref\""
        return 2
    fi
    printf '%s\n' "${ref}"
}

# What: True if a channel is a known mutable channel.
# Why: promote moves mutable refs only (docs section 51).
# From: Issue #1683
_ci_valid_channel() {
    local channel="$1" c
    while IFS= read -r c; do
        [ "${c}" = "${channel}" ] && return 0
    done < <(_ci_mutable_channels)
    _ci_procsub_ok "$!" 0 || return 2
    return 1
}

# What: true if target is mutable channel or v-tag.
# Why: promote uses same ref for channels/releases.
# From: Issue #1683
_ci_valid_promote_target() {
    local target="$1"
    _ci_valid_channel "${target}" && return 0
    _ci_release_tag_kind "${target}" >/dev/null
}

# What: accepted multi-arch candidate: service=index-digest.
# Why: promote/validate use digests, no moving tags (§48).
# From: Issue #1683
_ci_stack_candidate_ledger() {
    local service inputs want idx
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        inputs="$(_ci_collect_accepted_digests "${service}")" || return "$?"
        want="$(_ci_normalize_platform_digests "${inputs}")"
        idx="$(_ci_reconcile_index "${service}" "${want}")" || return "$?"
        if [ -z "${idx}" ]; then
            ci_log "[CI-ERROR-CANDIDATE-0001]" "service=\"${service}\" reason=\"platforms accepted but no assembled multi-arch index; stack not candidate-ready\""
            return 2
        fi
        printf '%s=%s\n' "${service}" "${idx}"
    done < <(ci_services)
    _ci_procsub_ok "$!" 0 || return 2
}

# What: toolchain promote candidates if fully accepted.
# Why: promote is the one channel mover (AG-REL-009).
# From: Issue #1683 | PR #1858
_ci_toolchain_candidate() {
    local service inputs want idx p st all plats tools
    tools="$(_ci_block_keys build_toolchain)" || return 2
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        all=1
        plats="$(_ci_platforms "${service}")" || return "$?"
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            st="$(_ci_resolve_one "${service}" "${p}")" || return "$?"
            st="$(_ci_record_field "${st}" state)"
            case "${st}" in
                PRESENT_ACCEPTED) ;;
                UNKNOWN|MISMATCH)
                    ci_log "[CI-ERROR-CANDIDATE-0003]" "service=\"${service}\" platform=\"${p}\" state=\"${st}\" reason=\"toolchain state not decidable; no promotion\""
                    return 2
                    ;;
                *) all=0 ;;
            esac
        done <<< "${plats}"
        if [ "${all}" -eq 0 ]; then
            ci_log "[CI-INFO-CANDIDATE-0004]" "service=\"${service}\" reason=\"toolchain not accepted on every platform; channel unchanged\""
            continue
        fi
        inputs="$(_ci_collect_accepted_digests "${service}")" || return "$?"
        want="$(_ci_normalize_platform_digests "${inputs}")"
        idx="$(_ci_reconcile_index "${service}" "${want}")" || return "$?"
        if [ -z "${idx}" ]; then
            ci_log "[CI-ERROR-CANDIDATE-0001]" "service=\"${service}\" reason=\"platforms accepted but no assembled multi-arch index; stack not candidate-ready\""
            return 2
        fi
        printf '%s=%s\n' "${service}" "${idx}"
    done <<< "${tools}"
}

# What: PR stack candidate: per-service digest for host.
# Why: no PR ledger; the stack runs on this daemon's arch.
# From: Issue #1683 | PR #1858
_ci_stack_candidate_pr() {
    local service digest platform
    if ! platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" || [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-CANDIDATE-0005]" "reason=\"docker daemon platform unknown; cannot pick PR images\""
        return 2
    fi
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        if ! digest="$(_ci_published_digest "${service}" "${platform}")"; then
            ci_log "[CI-ERROR-CANDIDATE-0002]" "service=\"${service}\" reason=\"PR image not resolvable; refusing to validate a partial stack\""
            return 2
        fi
        printf '%s=%s\n' "${service}" "${digest}"
    done < <(ci_services)
    _ci_procsub_ok "$!" 0 || return 2
}

# What: read accepted stack candidate (injectable).
# Why: exact-digest candidate (§48); tests/prod differ.
# From: Issue #1683
_ci_stack_candidate() {
    if [ -n "${CI_STACK_CANDIDATE_CMD:-}" ]; then
        "${CI_STACK_CANDIDATE_CMD}" "$@"
        return "$?"
    fi
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
        _ci_stack_candidate_pr
        return "$?"
    fi
    _ci_stack_candidate_ledger || return "$?"
    # What: promote also carries the accepted toolchain.
    # Why: validate pins compose services only.
    # From: Issue #1683 | PR #1858
    [ "${1:-}" = --with-toolchain ] || return 0
    _ci_toolchain_candidate
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
    local svc="$1" channel="$2" digest="$3" repo registry
    repo="$(_ci_repo)" || return 2
    registry="$(_ci_registry)" || return 2
    _ci_imagetools_create "${registry}/${repo}/${svc}:${channel}" "${registry}/${repo}/${svc}@${digest}" >/dev/null
}

# What: Default channel readback: the channel's digest.
# Why: one digest reader; empty output means unknown.
# From: Issue #1683
_ci_default_channel_readback() {
    local svc="$1" channel="$2" repo registry digest
    repo="$(_ci_repo)" || return 2
    registry="$(_ci_registry)" || return 2
    digest="$(_ci_registry_digest "${registry}/${repo}/${svc}:${channel}")" || return 2
    # What: a channel counts only if every child resolves.
    # Why: a present index with lost children is unpullable.
    # From: Issue #1683 | PR #1858
    _ci_index_complete "${registry}/${repo}/${svc}" "${digest}" || return 2
    printf '%s\n' "${digest}"
}

# What: True if every platform child of an index resolves.
# Why: an index digest alone does not prove a usable image.
# From: Issue #1683 | PR #1858
_ci_index_complete() {
    local base="$1" digest="$2" raw rc=0 child prc children
    raw="$(_ci_index_raw "${base}@${digest}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    # What: an index with no platform child is incomplete.
    # Why: zero children must not read as all resolvable.
    # From: Issue #1683
    if ! children="$(jq -er '[.manifests[]? | select(.platform.architecture!="unknown") | .digest] | if length == 0 then error("no platform child") else .[] end' <<< "${raw}")"; then
        ci_log "[CI-ERROR-PROMOTE-0015]" "image=\"${base}@${digest}\" reason=\"index has no readable platform child\""
        return 2
    fi
    while IFS= read -r child; do
        [ -n "${child}" ] || continue
        prc=0
        _ci_registry_probe "${base}@${child}" >/dev/null || prc=$?
        if [ "${prc}" -ne 0 ]; then
            ci_log "[CI-ERROR-PROMOTE-0014]" "image=\"${base}@${digest}\" child=\"${child}\" rc=${prc} reason=\"index child not resolvable; image unusable\""
            return 2
        fi
    done <<< "${children}"
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
    if ! _ci_valid_promote_target "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0002]" "channel=\"${channel}\" reason=\"not a mutable channel or a vX.Y.Z release tag\""
        return 2
    fi
    local cand
    if ! cand="$(_ci_stack_candidate --with-toolchain)"; then
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

# What: list promote targets for current git ref.
# Why: ref-driven policy; no channel logic in YAML.
# From: Issue #1683
_ci_promote_targets_for_ref() {
    local ref="${GITHUB_REF:-}" requested="${CI_PROMOTE_REQUESTED_CHANNEL:-}" tag pre
    {
        case "${ref}" in
            refs/heads/*) _ci_channels_where ref "${ref}" || return 2 ;;
            refs/tags/v*)
                tag="${ref#refs/tags/}"
                pre="$(_ci_release_prerelease "${tag}")" || return "$?"
                printf '%s\n' "${tag}"
                if [ "${pre}" = false ]; then _ci_channels_where release_tags true || return 2; fi
                ;;
        esac
        if [ -n "${requested}" ] && [ "${requested}" != none ]; then
            printf '%s\n' "${requested}"
        fi
    } | awk 'NF && !seen[$0]++'
}

# What: Resolve a git ref's current remote tip SHA.
# Why: one ls-remote reader; injectable for tests.
# From: Issue #1683
_ci_ref_tip() {
    git ls-remote origin "$1" | cut -f1
}

# What: Promote every target the current ref maps to.
# Why: one ref entry, supersede-safe, single policy owner.
# From: Issue #1683
ci_cmd_promote_ref() {
    local ref="${GITHUB_REF:-}" tip targets t
    targets="$(_ci_promote_targets_for_ref)" || return "$?"
    if [ -z "${targets}" ]; then
        printf 'promote=noop reason=no-targets ref=%s\n' "${ref}"
        return 0
    fi
    # What: moved branch tip means newer run supersedes.
    # Why: determinism (§4); never promote stale blind.
    if [[ "${ref}" == refs/heads/* ]]; then
        if ! tip="$("${CI_PROMOTE_TIP_CMD:-_ci_ref_tip}" "${ref}")"; then
            ci_log "[CI-ERROR-PROMOTE-0013]" "ref=\"${ref}\" reason=\"could not resolve ref tip; refusing blind promote\""
            return 2
        fi
        if [ -n "${tip}" ] && [ "${tip}" != "${GITHUB_SHA:-}" ]; then
            printf 'promote=superseded ref=%s tip=%s sha=%s\n' "${ref}" "${tip}" "${GITHUB_SHA:-}"
            return 0
        fi
    fi
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        "${CI_PROMOTE_ONE_CMD:-ci_cmd_promote}" "${t}" || return "$?"
    done <<< "${targets}"
}

# =========================================================
# NIGHTLY / RELEASE
# =========================================================

# What: Print why one validation record is stale, if it is.
# Why: AG-REL-011 triggers are checked directly, per record.
# From: Issue #1683
_ci_release_record_stale() {
    local name="$1" commit="$2" target="$3" rc=0 p
    local -a gov=() paths=()
    read -ra paths <<< "$4"
    read -ra gov <<< "$5"
    if [ -z "${commit}" ] || [ "${commit}" = null ]; then
        printf '%s: never validated\n' "${name}"; return 0
    fi
    local anc_err
    anc_err="$(git -C "${CI_REPO_ROOT}" merge-base --is-ancestor "${commit}" "${target}" 2>&1)" || rc=$?
    case "${rc}" in
        0) ;;
        1) printf '%s: %s is not an ancestor of %s\n' "${name}" "${commit}" "${target}"; return 0 ;;
        *)
            ci_error "[CI-WARN-RELEASE-0019]" "commit=\"${commit}\" target=\"${target}\" reason=\"ancestry check failed\"" "${anc_err}"
            printf '%s: diff from %s not reconstructable\n' "${name}" "${commit}"
            return 0
            ;;
    esac
    for p in "${gov[@]}"; do
        rc=0; _ci_path_content_changed "${p}" "${commit}" "${target}" || rc=$?
        case "${rc}" in
            0) printf '%s: governance %s changed since %s\n' "${name}" "${p}" "${commit}"; return 0 ;;
            1) ;;
            *) return 2 ;;
        esac
    done
    for p in "${paths[@]}"; do
        rc=0; _ci_path_content_changed "${p}" "${commit}" "${target}" || rc=$?
        case "${rc}" in
            0) printf '%s: %s changed since %s\n' "${name}" "${p}" "${commit}"; return 0 ;;
            1) ;;
            *) return 2 ;;
        esac
    done
}

# What: AG-REL-011 verdict over the SOT validation record.
# Why: a stale or invalidated record must never ship.
# From: Issue #1683
_ci_release_validation_valid() {
    if [ -n "${CI_RELEASE_VALIDATION_CMD:-}" ]; then
        "${CI_RELEASE_VALIDATION_CMD}"
        return "$?"
    fi
    local rel gov state target layer sub commit paths rows stale="" out
    rel="$(_ci_block_entry_field release "" validation_state)"
    gov="$(_ci_block_entry_list release "" governance_paths)"
    target="${GITHUB_SHA:?GITHUB_SHA required}"
    state="${CI_REPO_ROOT}/${rel}"
    if [ -z "${rel}" ] || [ -z "${gov}" ] || ! jq -e '.subsystem_validation' "${state}" >/dev/null; then
        ci_log "[CI-ERROR-RELEASE-0014]" "state=\"${state}\" reason=\"no readable SOT validation record\""
        return 2
    fi
    gov="${gov//$'\n'/ }"
    for layer in last_stack_validation last_ci_validation; do
        out="$(_ci_release_record_stale "${layer}" "$(jq -r --arg l "${layer}" '.[$l].commit' "${state}")" \
            "${target}" "" "${gov}")" || return 2
        stale+="${out:+${out}$'\n'}"
    done
    rows="$(jq -r '.subsystem_validation | to_entries[] | select(.key | startswith("_") | not)
        | [.key, (.value.commit // "null"), (.value.path_prefixes | join(" "))] | @tsv' "${state}")" || return 2
    while IFS=$'\t' read -r sub commit paths; do
        [ -n "${sub}" ] || continue
        out="$(_ci_release_record_stale "${sub}" "${commit}" "${target}" "${paths}" "${gov}")" || return 2
        stale+="${out:+${out}$'\n'}"
    done <<< "${rows}"
    if [ -n "${stale}" ]; then
        ci_error "[CI-ERROR-RELEASE-0017]" "reason=\"validation record stale (AG-REL-011)\"" "${stale}"
        return 1
    fi
    printf 'release-validation=fresh target=%s\n' "${target}"
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

# What: Map a release tag to its prerelease flag.
# Why: -rc.N ships as prerelease; vX.Y.Z is final.
# From: Issue #1683
_ci_release_prerelease() {
    local tag="$1"
    if _ci_release_tag_kind "${tag}"; then
        return 0
    fi
    ci_log "[CI-ERROR-RELEASE-0002]" "tag=\"${tag}\" reason=\"unsupported tag; use vX.Y.Z or vX.Y.Z-rc.N\""
    return 2
}

# What: true/false prerelease for a v-tag, else rc 1.
# Why: one tag grammar; predicates need no error log.
# From: Issue #1683 | PR #1858
_ci_release_tag_kind() {
    local tag="$1"
    if [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
        printf 'true\n'
        return 0
    fi
    if [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'false\n'
        return 0
    fi
    return 1
}

# What: Print the release-notes start or end marker.
# Why: one marker owner for writer and replacer; no name.
# From: Issue #1683
_ci_release_marker() {
    local repo
    repo="$(_ci_repo)" || return 2
    printf '<!-- %s-image-tags:%s -->\n' "${repo##*/}" "$1"
}

# What: Render the marker-delimited image provenance block.
# Why: Records every shipped digest; SOT list, no hardcode.
# From: Issue #1683
_ci_release_notes_block() {
    local tag="$1" registry repo target img dig
    registry="$(_ci_registry)" || return "$?"
    repo="$(_ci_repo)" || return 2
    _ci_release_marker start || return 2
    printf 'Images published for %s (commit %s):\n\n' "${tag}" "${GITHUB_SHA:-unknown}"
    for target in $(_ci_published_services) stack; do
        img="${registry}/${repo}/${target}:${tag}"
        dig="$(_ci_registry_digest "${img}")" || return "$?"
        printf -- '- %s -> %s\n' "${img}" "${dig}"
    done
    printf '\nProvenance attestations and CycloneDX SBOMs attach per image.\n'
    printf 'OpenVEX from .trivyignore.yaml attaches as vex.openvex.json.\n'
    _ci_release_marker end || return 2
}

# What: upload asset to release, replacing any prior.
# Why: one asset writer; SBOM/VEX; --clobber.
# From: Issue #1683
_ci_release_asset_put() {
    local tag="$1" file="$2" gh="${CI_RELEASE_GH_CMD:-gh}" repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    [ -s "${file}" ] || { ci_log "[CI-ERROR-RELEASE-0004]" "file=\"${file}\" reason=\"asset file missing or empty\""; return 2; }
    _ci_retry github-api "${gh}" release upload "${tag}" "${file}" --clobber --repo "${repo}" >/dev/null
}

# What: create/update GitHub release with notes.
# Why: idempotent marker replace; prerelease-checked.
# From: Issue #1683
ci_cmd_release_publish() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0003]" "reason=\"tag arg required\""; return 2; }
    local gh="${CI_RELEASE_GH_CMD:-gh}" repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local sha="${GITHUB_SHA:?GITHUB_SHA required}" pre block start end body_file merged view rc=0
    local view_rc=0 view_err
    pre="$(_ci_release_prerelease "${tag}")" || return "$?"
    _ci_require_ghcr_auth || return "$?"
    block="$(_ci_release_notes_block "${tag}")" || return "$?"
    start="$(_ci_release_marker start)" || return 2
    end="$(_ci_release_marker end)" || return 2
    body_file="$(mktemp "${CI_TMPDIR}/ci-release-notes.XXXXXX")"
    view_err="$(mktemp "${CI_TMPDIR}/ci-release-view.XXXXXX")"
    view="$("${gh}" release view "${tag}" --repo "${repo}" --json body,isPrerelease 2>"${view_err}")" || view_rc=$?
    # What: only gh's "release not found" means create.
    # Why: auth/network errors are UNKNOWN, not "absent".
    # From: Issue #1683 | PR #1858
    if [ "${view_rc}" -ne 0 ] && [[ "$(cat "${view_err}")" != *"release not found"* ]]; then
        ci_error "[CI-ERROR-RELEASE-0020]" "tag=\"${tag}\" reason=\"gh release view failed\"" "$(cat "${view_err}")"
        rm -f "${body_file}" "${view_err}"
        return 2
    fi
    rm -f "${view_err}"
    if [ "${view_rc}" -eq 0 ]; then
        local existing_body existing_pre
        existing_body="$(printf '%s' "${view}" | jq -r '.body // ""')"
        existing_pre="$(printf '%s' "${view}" | jq -r '.isPrerelease')"
        if [ "${existing_pre}" != "${pre}" ]; then
            rm -f "${body_file}"
            ci_log "[CI-ERROR-RELEASE-0005]" "tag=\"${tag}\" reason=\"existing prerelease state != tag policy\" expected=\"${pre}\" found=\"${existing_pre}\""
            return 2
        fi
        if [[ "${existing_body}" == *"${start}"* && "${existing_body}" == *"${end}"* ]]; then
            merged="${existing_body%%"${start}"*}${block}${existing_body#*"${end}"}"
        elif [ -n "${existing_body}" ]; then
            merged="${existing_body}"$'\n\n'"${block}"
        else
            merged="${block}"
        fi
        printf '%s\n' "${merged}" > "${body_file}"
        _ci_retry github-api "${gh}" release edit "${tag}" --repo "${repo}" \
            --notes-file "${body_file}" --target "${sha}" >/dev/null || rc=$?
    else
        printf '%s\n' "${block}" > "${body_file}"
        local -a create=("${gh}" release create "${tag}" --repo "${repo}"
            --title "${tag}" --notes-file "${body_file}" --target "${sha}")
        [ "${pre}" = true ] && create+=(--prerelease)
        _ci_retry github-api "${create[@]}" >/dev/null || rc=$?
    fi
    rm -f "${body_file}"
    [ "${rc}" -eq 0 ] || { ci_log "[CI-ERROR-RELEASE-0006]" "tag=\"${tag}\" reason=\"gh release create/edit failed\""; return 2; }
    printf 'release=published tag=%s prerelease=%s\n' "${tag}" "${pre}"
}

# What: Generate and attach a CycloneDX SBOM for one image.
# Why: Per-image provenance asset; reuses the trivy scanner.
# From: Issue #1683
ci_cmd_release_sbom() {
    local service="${1:-}" tag="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RELEASE-0007]" "reason=\"service arg required\""; return 2; }
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0008]" "reason=\"tag arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local registry repo digest dir out rc=0
    registry="$(_ci_registry)" || return "$?"
    repo="$(_ci_repo)" || return 2
    digest="$(_ci_registry_digest "${registry}/${repo}/${service}:${tag}")" || return "$?"
    dir="$(mktemp -d "${CI_TMPDIR}/ci-sbom.XXXXXX")"
    out="${dir}/${service}.cdx.json"
    "${CI_SBOM_CMD:-_ci_trivy_sbom}" "${service}" "${digest}" "${out}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -rf "${dir}"
        ci_log "[CI-ERROR-RELEASE-0009]" "service=\"${service}\" reason=\"SBOM generation failed\""
        return 2
    fi
    _ci_release_asset_put "${tag}" "${out}" || { rm -rf "${dir}"; return 2; }
    rm -rf "${dir}"
    printf 'release=sbom service=%s tag=%s digest=%s\n' "${service}" "${tag}" "${digest}"
}

# What: generate and attach SBOM for each image.
# Why: one SBOM walk; SOT-driven, skips third-party.
# From: Issue #1683
ci_cmd_release_sbom_stack() {
    local tag="${1:-}" svc
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0013]" "reason=\"tag arg required\""; return 2; }
    for svc in $(_ci_published_services); do
        ci_cmd_release_sbom "${svc}" "${tag}" || return "$?"
    done
}

# What: generate and attach OpenVEX to release.
# Why: one VEX per release; reuses SOT vex generator.
# From: Issue #1683
ci_cmd_release_vex() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0010]" "reason=\"tag arg required\""; return 2; }
    local root="${CI_REPO_ROOT:-.}" trivyignore dir out rc=0
    trivyignore="${root}/.trivyignore.yaml"
    [ -s "${trivyignore}" ] || { ci_log "[CI-ERROR-RELEASE-0011]" "path=\"${trivyignore}\" reason=\"trivyignore missing; cannot build release VEX\""; return 2; }
    dir="$(mktemp -d "${CI_TMPDIR}/ci-vex.XXXXXX")"
    out="${dir}/vex.openvex.json"
    _ci_generate_vex "${trivyignore}" "${root}" > "${out}" || rc=$?
    if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
        rm -rf "${dir}"
        ci_log "[CI-ERROR-RELEASE-0012]" "tag=\"${tag}\" reason=\"generate-vex produced no output\""
        return 2
    fi
    _ci_release_asset_put "${tag}" "${out}" || { rm -rf "${dir}"; return 2; }
    rm -rf "${dir}"
    printf 'release=vex tag=%s\n' "${tag}"
}

# What: highest plain vX.Y.Z release tag, or empty.
# Why: ls-remote skips deep fetch; empty pre-1.0.
# From: Issue #1683
_ci_last_release_tag() {
    local refs tags
    refs="$(_ci_capture 0 git ls-remote --tags --refs origin 'refs/tags/v[0-9]*.[0-9]*.[0-9]*')" || return 2
    tags="$(_ci_capture 1 grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' <<<"${refs}")" || return 2
    if [ -z "${tags}" ]; then
        return 0
    fi
    sed 's#^refs/tags/##' <<<"${tags}" | sort -V | tail -n 1
}

# What: The next patch tag after a plain vX.Y.Z tag.
# Why: automated patch releases bump Z only, never rc/minor.
# From: Issue #1683
_ci_next_patch_tag() {
    local tag="$1"
    if [[ ! "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        ci_log "[CI-ERROR-RELEASE-0015]" "tag=\"${tag}\" reason=\"not a plain vX.Y.Z tag; not auto-bumped\""
        return 2
    fi
    printf 'v%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$(( 10#${BASH_REMATCH[3]} + 1 ))"
}

# What: true if published image differs from base.
# Why: content-identity trigger, not path heuristic.
# From: Issue #1683
_ci_release_stack_changed() {
    local base_tag="$1" registry repo sha svc cur rel
    registry="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    sha="${GITHUB_SHA:?GITHUB_SHA required}"
    for svc in $(_ci_published_services); do
        cur="$(_ci_registry_digest "${registry}/${repo}/${svc}:sha-${sha}")" || return 2
        rel="$(_ci_registry_probe "${registry}/${repo}/${svc}:${base_tag}")" || rel=""
        [ "${cur}" = "${rel}" ] || return 0
    done
    return 1
}

# What: push PAT-authored annotated tag to origin.
# Why: GITHUB_TOKEN no re-trigger CI (anti-recursion).
# From: Issue #1683
_ci_push_release_tag() {
    local tag="$1" sha="$2" pat="${PROJECT_AUTOMATION_PAT:?PROJECT_AUTOMATION_PAT required to push a release tag}"
    local url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?}.git"
    git tag -a "${tag}" "${sha}" -m "Automated patch release ${tag}"
    git -c "http.${url}.extraheader=AUTHORIZATION: basic $(printf '%s' "x-access-token:${pat}" | base64 -w0)" \
        push "${url}" "refs/tags/${tag}"
}

# What: 0 tag on origin, 1 absent, 2 lookup failed.
# Why: a failed lookup is UNKNOWN, never "absent".
# From: Issue #1683 | PR #1858
_ci_remote_tag_exists() {
    local hit
    hit="$(_ci_capture 0 git ls-remote --tags origin "refs/tags/$1")" || return 2
    [ -n "${hit}" ]
}

# What: cut next patch tag when master changed stack.
# Why: automated releases on image-affecting pushes.
# From: Issue #1683
ci_cmd_cut_release_tag() {
    local base_tag next_tag tip rel_ref
    base_tag="$("${CI_LAST_RELEASE_TAG_CMD:-_ci_last_release_tag}")" || return 2
    if [ -z "${base_tag}" ]; then
        printf 'cut-tag=noop reason=no-base-tag\n'
        return 0
    fi
    if ! "${CI_STACK_CHANGED_CMD:-_ci_release_stack_changed}" "${base_tag}"; then
        printf 'cut-tag=noop reason=stack-unchanged base=%s\n' "${base_tag}"
        return 0
    fi
    next_tag="$(_ci_next_patch_tag "${base_tag}")" || return "$?"
    rel_ref="$(_ci_release_ref)" || return 2
    if ! tip="$("${CI_PROMOTE_TIP_CMD:-_ci_ref_tip}" "${rel_ref}")"; then
        ci_log "[CI-ERROR-RELEASE-0016]" "ref=\"${rel_ref}\" reason=\"could not resolve release ref tip; not cutting blind\""
        return 2
    fi
    if [ -n "${tip}" ] && [ "${tip}" != "${GITHUB_SHA:-}" ]; then
        printf 'cut-tag=superseded tip=%s sha=%s\n' "${tip}" "${GITHUB_SHA:-}"
        return 0
    fi
    local exists_rc=0
    "${CI_TAG_EXISTS_CMD:-_ci_remote_tag_exists}" "${next_tag}" || exists_rc=$?
    if [ "${exists_rc}" -eq 0 ]; then
        printf 'cut-tag=noop reason=exists tag=%s\n' "${next_tag}"
        return 0
    fi
    if [ "${exists_rc}" -ne 1 ]; then
        return 2
    fi
    "${CI_TAG_PUSH_CMD:-_ci_push_release_tag}" "${next_tag}" "${GITHUB_SHA:?}" || return "$?"
    printf 'cut-tag=pushed tag=%s\n' "${next_tag}"
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
    local remote repo registry blob rc=0 pairs="" out="" svc channel dig prc line s d raw
    remote="$(_ci_ledger_remote)"
    repo="$(_ci_repo)" || return 2
    registry="$(_ci_registry)" || return 2
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
            dig="$(_ci_registry_probe "${registry}/${repo}/${svc}:${channel}")" || prc=$?
            # What: A transient probe refuses the run.
            # Why: A flaky miss must not drop a channel.
            # From: Issue #1683
            [ "${prc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0013]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel probe UNKNOWN; refusing roots\""; return 2; }
            [ "${prc}" -eq 0 ] && pairs="${pairs}"$'\n'"${svc}"$'\t'"${dig}"
        done < <(_ci_mutable_channels)
        _ci_procsub_ok "$!" 0 || return 2
    # What: every build target's channels are roots.
    # Why: GC candidates include build-tools; skip = orphan.
    # From: Issue #1683 | PR #1858
    done < <(ci_build_targets)
    _ci_procsub_ok "$!" 0 || return 2
    pairs="$(printf '%s\n' "${pairs}" | awk 'NF>0' | LC_ALL=C sort -u)"
    while IFS=$'\t' read -r s d; do
        [ -n "${d}" ] || continue
        out="${out}${d}"$'\n'
        rc=0
        raw="$(_ci_index_raw "${registry}/${repo}/${s}@${d}")" || rc=$?
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
    # What: retry transient GH-API reads; 404 permanent.
    # Why: op=github-api treats 404 as permanent failure.
    # From: Issue #1683
    out="$(_ci_retry github-api gh api --paginate "/orgs/${owner}/packages/container/${pkg}/versions?per_page=100" --jq '.[] | [.name, .id, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv')" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        grep -qiE 'HTTP 404|Not Found' <<< "${out}" && return 1
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
    prefix="$(_ci_repo)" || { ci_log "[CI-ERROR-GC-0017]" "reason=\"GITHUB_REPOSITORY missing; no package namespace\""; return 2; }
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
    _ci_procsub_ok "$!" 0 || return 2
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
    [ -n "${svc}" ] || { ci_log "[CI-ERROR-GC-0021]" "candidate=\"${candidate}\" reason=\"no service for delete path\""; return 2; }
    prefix="$(_ci_repo)" || { ci_log "[CI-ERROR-GC-0017]" "reason=\"GITHUB_REPOSITORY missing; no package namespace\""; return 2; }
    owner="${prefix%%/*}"
    pkgbase="${prefix#*/}"
    # What: retry a transient GH-API delete.
    # Why: destructive ops use shared classifier.
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
    local root_hit
    root_hit="$(_ci_capture 1 grep -xF -- "${digest}" "${CI_GC_ROOTS_FILE}")" || return 2
    if [ -n "${root_hit}" ]; then
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
                    root_hit="$(_ci_capture 1 grep -xF -- "${subj}" "${CI_GC_ROOTS_FILE}")" || return 2
                    if [ -n "${root_hit}" ]; then
                        printf 'referenced\n'
                        return 0
                    fi
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
    [ "${window}" -gt 0 ] || { ci_log "[CI-ERROR-GC-0022]" "value=\"${window}\" reason=\"grace must be greater than zero\""; return 2; }
    # What: A candidate needs created_at for the floor.
    # Why: No timestamp is UNKNOWN, never a delete.
    # From: Issue #1683
    [ -n "${created}" ] || { ci_log "[CI-ERROR-GC-0016]" "digest=\"${digest}\" reason=\"missing created_at; cannot apply recency floor\""; return 2; }
    if ! created_epoch="$(date -d "${created}" +%s 2>&1)"; then
        ci_error "[CI-ERROR-GC-0023]" "created=\"${created}\" reason=\"created_at unparseable\"" "${created_epoch}"
        return 2
    fi
    case "${created_epoch}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-GC-0023]" "created=\"${created}\" reason=\"created_at unparseable\""
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
    CI_GC_ROOTS_FILE="$(mktemp "${CI_TMPDIR}/ci-gc-roots.XXXXXX")" || return 2
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

# What: Print the first SOT DNS test domain.
# Why: dig target lives in SOT; no pipe into head.
# From: Issue #1683 | PR #1858
_ci_validation_dns_domain() {
    local all
    all="$(_ci_block_entry_list validation "" dns_test_domains)" || return
    printf '%s\n' "${all%%$'\n'*}"
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
    local raw
    raw="$(_ci_validate_config_json)" || return 2
    jq -r '.services | to_entries[] | [.key, .value.image] | @tsv' <<< "${raw}"
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
            *) ci_log "[CI-WARN-VALIDATE-0008]" "unpinned=\"${slug}\" reason=\"candidate service has no first-party image in compose\"" ;;
        esac
    done <<< "${candidate}"
}

# What: Print a compose override pinning first-party images.
# Why: Validate candidate digests, never a mutable :latest.
# From: Issue #1683 | PR #1858
_ci_validate_pin_override() {
    local candidate="$1" prefix images svc image slug digest reg matched=" "
    if ! prefix="$(_ci_repo)"; then
        ci_log "[CI-ERROR-VALIDATE-0005]" "reason=\"GITHUB_REPOSITORY missing; no image namespace\""
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
    root="${CI_TMPDIR}/ci-validate-locks"
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
    # What: reap the dead lock holder; its status is unused.
    # Why: this path returns 1; its rc adds nothing.
    # From: Issue #1683 | PR #1858
    wait "${holder}" 2>/dev/null || true
    return 1
}

# What: Release a held validate slot lock.
# Why: Frees the mutex; safe if already gone.
# From: Issue #1683
_ci_validate_release() {
    local holder="${1:-}"
    [ -n "${holder}" ] || return 0
    # What: stop and reap the holder; it may be gone.
    # Why: best effort; a gone holder is not an error.
    # From: Issue #1683 | PR #1858
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
    local target="$1" tip tm net sub sip sm m nets
    tip="$(_ci_ipv4_to_int "${target%/*}")"
    tm="${target#*/}"
    # What: rc 2 when the network list is unknown.
    # Why: a failed docker call must not read as "free".
    # From: Issue #1683 | PR #1858
    nets="$(docker network ls -q)" || return 2
    local subs
    while IFS= read -r net; do
        [ -n "${net}" ] || continue
        # What: a net gone since ls is skipped; others fail.
        # Why: an inspect error must not pass as a free net.
        # From: Issue #1683
        if ! subs="$(docker network inspect "${net}" --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>&1)"; then
            case "${subs,,}" in *"no such network"*|*"not found"*) continue ;; esac
            ci_error "[CI-ERROR-VALIDATE-0051]" "network=\"${net}\" reason=\"network inspect failed\"" "${subs}"
            return 2
        fi
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
        done <<< "${subs}"
    done <<< "${nets}"
    return 1
}

# What: Reserve a free /27; print subnet + holder.
# Why: Retry a fresh slot on a locked candidate.
# From: Issue #1683
_ci_validate_reserve() {
    local run_id run_attempt max n seed subnet holder crc
    run_id="${GITHUB_RUN_ID:-$$}"
    run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
    max="${CI_VALIDATE_MAX_SLOTS:-10}"
    for (( n=1; n<=max; n++ )); do
        seed="$(_ci_validate_seed "${run_id}" "${run_attempt}" "${n}")"
        subnet="$(_ci_validate_subnet "${seed}")"
        crc=0
        _ci_validate_subnet_conflicts "${subnet}" >/dev/null || crc=$?
        [ "${crc}" -eq 0 ] && continue
        if [ "${crc}" -eq 2 ]; then
            ci_log "[CI-ERROR-VALIDATE-0050]" "subnet=\"${subnet}\" reason=\"docker network list failed; cannot prove the slot free\""
            return 2
        fi
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
    local repo
    repo="$(_ci_repo)" || return 2
    printf '%s-validate-%s' "${repo##*/}" "$(printf '%s' "${1}" | tr './' '__')"
}

# What: The resolved compose config as JSON.
# Why: One source; every service list derives from it.
# From: Issue #1683
_ci_validate_config_json() {
    if [ -n "${CI_COMPOSE_CONFIG_CMD:-}" ]; then
        "${CI_COMPOSE_CONFIG_CMD}"
        return "$?"
    fi
    local file flags
    file="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local -a pf=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t pf <<< "${flags}"
    docker compose -f "${file}" "${pf[@]}" config --format json
}

# What: Compose service names passing one jq filter.
# Why: One owner; startable + health lists share it.
# From: Issue #1683
_ci_validate_service_list() {
    local filter="$1" raw
    if ! raw="$(_ci_validate_config_json)"; then
        ci_log "[CI-ERROR-VALIDATE-0006]" "reason=\"compose config read failed\""
        return 2
    fi
    if ! jq -r ".services|to_entries[]|select(${filter})|.key" <<< "${raw}"; then
        ci_log "[CI-ERROR-VALIDATE-0057]" "reason=\"compose config is not service JSON\""
        return 2
    fi
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
    local subnet="$1" svc svcs
    svcs="$(_ci_validate_startable)" || return 2
    printf 'networks:\n  default:\n    ipam:\n      config:\n        - subnet: %s\n' "${subnet}"
    printf 'services:\n'
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        printf '  %s:\n    container_name: !reset null\n    ports: !reset []\n' "${svc}"
    done <<< "${svcs}"
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
    local net_id="$1" name out
    name="$(docker network inspect "${net_id}" --format '{{.Name}}' 2>/dev/null)" || return 0
    # What: wait for detach; a timeout is not fatal here.
    # Why: the rm below fails with raw output if still busy.
    # From: Issue #1683 | PR #1858
    _ci_validate_await_detached "${name}" || true
    out="$(docker network rm "${name}" 2>&1)" && return 0
    ci_error "[CI-ERROR-VALIDATE-0053]" "network=\"${name}\" reason=\"network removal failed\"" "${out}"
    return 2
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
    local holder="$1" project="$2" net_id out rc=0 kind ids compose
    local label="label=com.docker.compose.project=${project}"
    # What: no compose file: skip down, sweep leftovers.
    # Why: the label sweep frees the slot without the file.
    # From: Issue #1683 | PR #1858
    if compose="$(_ci_variable CI_COMPOSE_FILE)"; then
        out="$(docker compose -p "${project}" \
            -f "${compose}" \
            down -v --remove-orphans 2>&1)" || {
            ci_error "[CI-ERROR-VALIDATE-0058]" "project=\"${project}\" reason=\"compose down failed\"" "${out}"
            rc=2
        }
    else
        rc=2
    fi
    # What: remove what an aborted up still left behind.
    # Why: Created containers pin volumes; next slot breaks.
    # From: Issue #1683
    local -a found=()
    for kind in container volume network; do
        if [ "${kind}" = container ]; then
            ids="$(docker container ls -aq --filter "${label}" 2>&1)"
        else
            ids="$(docker "${kind}" ls -q --filter "${label}" 2>&1)"
        fi || {
            ci_error "[CI-ERROR-VALIDATE-0059]" "kind=\"${kind}\" reason=\"cannot list leftovers\"" "${ids}"
            rc=2
            continue
        }
        [ -n "${ids}" ] || continue
        mapfile -t found <<< "${ids}"
        if [ "${kind}" = network ]; then
            for net_id in "${found[@]}"; do
                _ci_validate_network_teardown "${net_id}" || rc=2
            done
            continue
        fi
        out="$(docker "${kind}" rm -f "${found[@]}" 2>&1)" || {
            ci_error "[CI-ERROR-VALIDATE-0060]" "kind=\"${kind}\" reason=\"leftover removal failed\"" "${out}"
            rc=2
        }
    done
    if [ -n "${LANCACHE_STATE_DIR:-}" ] && [ -d "${LANCACHE_STATE_DIR}" ]; then
        # What: clear root-owned state via a container.
        # Why: services write as root; runner user cannot.
        # From: Issue #1683
        local base
        base="$(_ci_block_entry_field base_images "" alpine)"
        if ! out="$(docker run --rm --network none -v "${LANCACHE_STATE_DIR}:/s" "${base}" \
                find /s -mindepth 1 -delete 2>&1 && rmdir "${LANCACHE_STATE_DIR}" 2>&1)"; then
            ci_error "[CI-ERROR-VALIDATE-0061]" "reason=\"per-run state root not removed\"" "${out}"
            rc=2
        fi
    fi
    _ci_validate_release "${holder}"
    return "${rc}"
}

# What: Bring the isolated prod stack up detached.
# Why: net override /27-isolates; pin override pins.
# From: Issue #1683 | PR #1858
_ci_validate_up() {
    local project="$1" net_override="$2" pin_override="$3" svc raw
    local -a svcs=()
    raw="$(_ci_validate_startable)" || return 2
    while IFS= read -r svc; do
        [ -n "${svc}" ] && svcs+=("${svc}")
    done <<< "${raw}"
    if [ "${#svcs[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0018]" "reason=\"no startable services from compose config\""
        return 2
    fi
    # What: name each host-mode service left out of the up.
    # Why: AG-VAL-027 needs a stated exclusion, not silence.
    # From: Issue #1683
    raw="$(_ci_validate_service_list '.value.network_mode == "host"')" || return 2
    while IFS= read -r svc; do
        [ -n "${svc}" ] && ci_log "[CI-INFO-VALIDATE-0055]" "service=\"${svc}\" reason=\"host network mode cannot be isolated in a /27; excluded\""
    done <<< "${raw}"
    local file flags
    file="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local -a pf=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t pf <<< "${flags}"
    docker compose -p "${project}" -f "${file}" \
        -f "${net_override}" -f "${pin_override}" "${pf[@]}" up -d "${svcs[@]}"
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
        cid="$(docker compose -p "${project}" ps -aq "${svc}" 2>/dev/null)"
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
            ci_error "[CI-ERROR-VALIDATE-0009]" "service=\"${names[$i]}\" check=\"${kinds[$i]}\" reason=\"not stable/healthy within timeout\"" \
                "$(_ci_validate_service_evidence "${project}" "${names[$i]}")"
            rc=1
        fi
    done
    return "${rc}"
}

# What: Raw state and full logs of one compose service.
# Why: a health failure must ship its evidence (AG-INT-002).
# From: Issue #1683
_ci_validate_service_evidence() {
    local project="$1" svc="$2" cid
    cid="$(docker compose -p "${project}" ps -aq "${svc}" 2>&1)"
    printf 'container=%s\n' "${cid:-<none>}"
    [ -n "${cid}" ] && docker inspect --format '{{json .State}}' "${cid}" 2>&1
    docker compose -p "${project}" logs --no-color "${svc}" 2>&1
}

# What: Prove DNS resolves a CDN domain and split-routes.
# Why: Real dig; standard/ssl MUST differ, not ping.
# From: Issue #1683 | PR #1858
_ci_validate_dns() {
    local project="$1" ip_std ip_ssl domain a_std a_ssl
    ip_std="$(_ci_validate_container_ip "${project}" dns-standard)"
    ip_ssl="$(_ci_validate_container_ip "${project}" dns-ssl)"
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip_std}" ] || [ -z "${ip_ssl}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0010]" "reason=\"missing dns container IP or test domain\""
        return 2
    fi
    a_std="$(dig +short "@${ip_std}" A "${domain}" | sort -u)"
    a_ssl="$(dig +short "@${ip_ssl}" A "${domain}" | sort -u)"
    if [ -z "${a_std}" ] || [ -z "${a_ssl}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0011]" "domain=\"${domain}\" reason=\"no DNS answer from a resolver mode\""
        return 1
    fi
    # What: standard and ssl modes resolve distinct IPs.
    # Why: split routing proof (.10 vs .11).
    # From: Issue #668
    if [ "${a_std}" = "${a_ssl}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0021]" "domain=\"${domain}\" reason=\"standard and ssl DNS returned the same answer (#668 split routing lost)\""
        return 1
    fi
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
    if ! grep -qi 'X-Cache-Status:[[:space:]]*HIT' <<< "${h}"; then
        ci_log "[CI-ERROR-VALIDATE-0014]" "url=\"${url}\" reason=\"second request not a cache HIT\""
        return 1
    fi
}

# What: print stream-target wildcard hardcode lines.
# Why: *.domain must forward to SNI, not literal.
# From: Issue #1683
_ci_stream_map_violations() {
    awk '/^[[:space:]]*\*\./ && $2 != "$ssl_preread_server_name:443;" { print }'
}

# What: print depth>=2 dispatch entries not routed to :9446.
# Why: deeper SNI has no wildcard cert; must passthrough.
# From: Issue #1683
_ci_ssl_dispatch_violations() {
    awk 'index($0, "~^.+\\.") > 0 && $NF != "127.0.0.1:9446;" { print }'
}

# What: prove proxy routes wildcards by SNI.
# Why: root literal misroutes subdomains.
# From: Issue #1683
_ci_validate_proxy_stream_map() {
    local project="$1" cid map bad
    cid="$(docker compose -p "${project}" ps -q proxy 2>/dev/null)"
    if [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0022]" "reason=\"no proxy container for stream-map check\""
        return 2
    fi
    if ! map="$(docker exec "${cid}" cat /etc/nginx/stream.d/00-stream-targets.conf 2>/dev/null)"; then
        ci_log "[CI-ERROR-VALIDATE-0019]" "reason=\"could not read proxy stream-target map\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | _ci_stream_map_violations)"
    if [ -n "${bad}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0020]" "reason=\"stream-target wildcard forwards to a hardcoded root, not the requested SNI (#1297)\"" "${bad}"
        return 1
    fi
}

# What: Prove ssl mode intercepts (MITM) with our LAN CA.
# Why: proxy :443 must present a cert we signed.
# From: Issue #1683
_ci_validate_ssl_mitm() {
    local project="$1" ip cid domain ca_subj issuer tmp
    ip="$(_ci_validate_container_ip "${project}" proxy)"
    cid="$(docker compose -p "${project}" ps -q proxy 2>/dev/null)"
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip}" ] || [ -z "${cid}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0023]" "reason=\"no proxy container/IP or test domain for ssl-mitm check\""
        return 2
    fi
    tmp="$(mktemp "${CI_TMPDIR}/ci-proxy-ca.XXXXXX")"
    if ! docker cp "${cid}:/etc/nginx/ssl/ca/ca.crt" "${tmp}" 2>/dev/null; then
        ci_log "[CI-ERROR-VALIDATE-0024]" "reason=\"could not read proxy LAN CA for ssl-mitm check\""
        rm -f "${tmp}"
        return 2
    fi
    ca_subj="$(openssl x509 -noout -subject -in "${tmp}" 2>/dev/null | sed 's/^subject=//')"
    issuer="$(openssl s_client -connect "${ip}:443" -servername "${domain}" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    rm -f "${tmp}"
    if [ -z "${ca_subj}" ] || [ -z "${issuer}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0025]" "domain=\"${domain}\" reason=\"no TLS issuer or CA subject for ssl-mitm check\""
        return 1
    fi
    # What: the :443 cert issuer MUST equal our own LAN CA.
    # Why: proves interception, not passthrough.
    # From: Issue #668
    if [ "${issuer}" != "${ca_subj}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0026]" "issuer=\"${issuer}\" ca=\"${ca_subj}\" reason=\"ssl mode :443 cert not issued by our LAN CA (not intercepting, #668)\""
        return 1
    fi
}

# What: ssl-mode depth-dispatch routes deeper SNI right.
# Why: depth>=2 SNI passthrough (:9446), not MITM.
# From: Issue #1683
_ci_validate_ssl_dispatch_map() {
    local project="$1" cid map bad
    cid="$(docker compose -p "${project}" ps -q proxy 2>/dev/null)"
    if [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0027]" "reason=\"no proxy container for ssl-dispatch-map check\""
        return 2
    fi
    if ! map="$(docker exec "${cid}" cat /etc/nginx/stream.d/01-ssl-dispatch.conf 2>/dev/null)"; then
        ci_log "[CI-ERROR-VALIDATE-0028]" "reason=\"could not read proxy ssl-dispatch map (SSL_ENABLED=0?)\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | _ci_ssl_dispatch_violations)"
    if [ -n "${bad}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0029]" "reason=\"depth>=2 SNI dispatch entry routes to MITM, not passthrough relay :9446 (#1276/#1322)\"" "${bad}"
        return 1
    fi
}

# What: Open a UI session into <jar>, print its CSRF token.
# Why: One owner for the cookiejar + CSRF extraction.
# From: Issue #1683
_ci_validate_ui_session() {
    local project="$1" jar="$2" ip cookie csrf attempt
    ip="$(_ci_validate_container_ip "${project}" ui)"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0030]" "reason=\"no ui container IP for session check\""
        return 2
    fi
    # What: ui has no compose healthcheck; poll /domains.
    # Why: wait_healthy misses ui; prove it answers first.
    # From: Issue #1683
    for attempt in $(seq 1 30); do
        curl -fsS -c "${jar}" -o /dev/null "http://${ip}:8080/domains" 2>/dev/null && break
        if [ "${attempt}" -eq 30 ]; then
            ci_log "[CI-ERROR-VALIDATE-0031]" "reason=\"ui /domains never answered\""
            return 1
        fi
        sleep 2
    done
    cookie="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "${jar}" 2>/dev/null)"
    csrf="$(printf '%s' "${cookie}" | cut -d. -f3)"
    if [ -z "${csrf}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0032]" "reason=\"no CSRF token in ui session cookie\""
        return 1
    fi
    printf '%s' "${csrf}"
}

# What: POST a LAN A record through the UI (303 on ok).
# Why: Drives the real UI->NATS->PowerDNS write path.
# From: Issue #1683
_ci_validate_ui_add_record() {
    local project="$1" jar="$2" csrf="$3" name="$4" content="$5" ip code
    ip="$(_ci_validate_container_ip "${project}" ui)"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0033]" "reason=\"no ui container IP for add-record\""
        return 2
    fi
    code="$(curl -sS -b "${jar}" -o /dev/null -w '%{http_code}' \
        --data-urlencode "csrf_token=${csrf}" \
        --data-urlencode "name=${name}" \
        --data-urlencode "record_type=A" \
        --data-urlencode "content=${content}" \
        --data-urlencode "ttl=60" \
        "http://${ip}:8080/domains/lan/add" 2>/dev/null)"
    if [ "${code}" != "303" ]; then
        ci_log "[CI-ERROR-VALIDATE-0034]" "code=\"${code}\" reason=\"ui /domains/lan/add did not return 303\""
        return 1
    fi
}

# What: Poll dig until <fqdn> resolves to <expected>.
# Why: NATS->PowerDNS (AXFR to ssl) async; prove it.
# From: Issue #1683
_ci_validate_dns_resolves() {
    local project="$1" svc="$2" fqdn="$3" expected="$4" attempts="${5:-15}" ip got i
    ip="$(_ci_validate_container_ip "${project}" "${svc}")"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0035]" "svc=\"${svc}\" reason=\"no dns IP for resolve check\""
        return 2
    fi
    for i in $(seq 1 "${attempts}"); do
        got="$(dig +time=2 +tries=1 +short "@${ip}" A "${fqdn}" | sort -u)"
        [ "${got}" = "${expected}" ] && return 0
        sleep 1
    done
    ci_log "[CI-ERROR-VALIDATE-0036]" "svc=\"${svc}\" fqdn=\"${fqdn}\" expected=\"${expected}\" got=\"${got:-}\" reason=\"record did not resolve as expected\""
    return 1
}

# What: UI->NATS->PowerDNS writes reach both dns modes.
# Why: Real end-to-end NATS ingest + AXFR, not mock.
# From: Issue #1683
_ci_validate_ui_nats_dns() {
    local project="$1" jar csrf rc=0
    jar="$(mktemp "${CI_TMPDIR}/ci-ui-jar.XXXXXX")"
    csrf="$(_ci_validate_ui_session "${project}" "${jar}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    _ci_validate_ui_add_record "${project}" "${jar}" "${csrf}" ci-uinats-probe 203.0.113.60 || rc=$?
    rm -f "${jar}"
    [ "${rc}" -eq 0 ] || return "${rc}"
    _ci_validate_dns_resolves "${project}" dns-standard ci-uinats-probe.lan. 203.0.113.60 15 || return $?
    _ci_validate_dns_resolves "${project}" dns-ssl ci-uinats-probe.lan. 203.0.113.60 60 || return $?
}

# What: DNS known-good snapshot/rollback round-trip.
# Why: Real listener HTTP + PATCH + cache flush.
# From: Issue #1683
_ci_validate_dns_rollback() {
    local project="$1" ip cid key jar csrf snap resp code i rc=0 compose
    ip="$(_ci_validate_container_ip "${project}" dns-standard)"
    cid="$(docker compose -p "${project}" ps -q dns-standard 2>/dev/null)"
    if [ -z "${ip}" ] || [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0037]" "reason=\"no dns-standard container/IP for rollback check\""
        return 2
    fi
    # What: read PDNS_API_KEY from shared-secrets file.
    # Why: entrypoint resolves it at runtime, not env.
    # From: Issue #858
    key="$(docker exec "${cid}" cat /var/lib/lancache-secrets/pdns-api-key 2>/dev/null | tr -d '\n')"
    if [ -z "${key}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0038]" "reason=\"could not read PDNS_API_KEY from shared-secrets\""
        return 2
    fi
    # What: poll until the rollback listener :8083 accepts.
    # Why: healthy != bound; nats-subscriber binds late.
    # From: Issue #628
    for i in $(seq 1 30); do
        curl -fsS -o /dev/null -H "X-API-Key: ${key}" "http://${ip}:8083/snapshots" 2>/dev/null && break
        if [ "${i}" -eq 30 ]; then
            ci_log "[CI-ERROR-VALIDATE-0039]" "reason=\"rollback listener :8083 never accepted a connection\""
            return 1
        fi
        sleep 1
    done
    code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${ip}:8083/snapshots" 2>/dev/null)"
    if [ "${code}" != "401" ]; then
        ci_log "[CI-ERROR-VALIDATE-0040]" "code=\"${code}\" reason=\"/snapshots without X-API-Key not 401\""
        return 1
    fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-API-Key: wrong' "http://${ip}:8083/snapshots" 2>/dev/null)"
    if [ "${code}" != "401" ]; then
        ci_log "[CI-ERROR-VALIDATE-0041]" "code=\"${code}\" reason=\"/snapshots with wrong X-API-Key not 401\""
        return 1
    fi
    jar="$(mktemp "${CI_TMPDIR}/ci-rb-jar.XXXXXX")"
    csrf="$(_ci_validate_ui_session "${project}" "${jar}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    _ci_validate_ui_add_record "${project}" "${jar}" "${csrf}" ci-rollback-probe 203.0.113.70 || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" dns-standard ci-rollback-probe.lan. 203.0.113.70 15 || { rm -f "${jar}"; return 1; }
    # What: capture newest lan. snapshot (pre-change state).
    # Why: target this test rolls back to after 2nd write.
    # From: Issue #628
    snap="$(curl -sS -H "X-API-Key: ${key}" "http://${ip}:8083/snapshots" 2>/dev/null | jq -r '.zones["lan."][0].id // empty')"
    if [ -z "${snap}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0042]" "reason=\"no lan. known-good snapshot after first write\""
        rm -f "${jar}"
        return 1
    fi
    _ci_validate_ui_add_record "${project}" "${jar}" "${csrf}" ci-rollback-probe 203.0.113.71 || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" dns-standard ci-rollback-probe.lan. 203.0.113.71 15 || { rm -f "${jar}"; return 1; }
    rm -f "${jar}"
    compose="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    # What: roll back through the operator CLI, setup.sh.
    # Why: §49 client path; API key resolved in container.
    # From: Issue #836
    resp="$(COMPOSE_PROJECT_NAME="${project}" bash "${CI_REPO_ROOT}/setup.sh" \
        reset-to-last-known-good-config dns "$(dirname "${compose}")" \
        lan. "${snap}" --yes 2>&1)" || rc=$?
    case "${rc}:${resp}" in
        *"cache-flush publishes failed"*) rc=1 ;;
        0:*"rolled back to known-good snapshot ${snap}"*"ci-rollback-probe.lan."*) ;;
        *) rc=1 ;;
    esac
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-VALIDATE-0043]" "reason=\"setup.sh rollback not applied, probe unchanged or flush failed\"" "${resp}"
        return 1
    fi
    # What: post-rollback dig must return the OLD content.
    # Why: proves recursor cache flush reached it.
    # From: Issue #628
    _ci_validate_dns_resolves "${project}" dns-standard ci-rollback-probe.lan. 203.0.113.70 15 || return $?
}

# What: Prove ui.depends_on never gates on service_healthy.
# Why: UI must start even while a dependency crash-loops.
# From: Issue #1683
_ci_validate_ui_depends_started() {
    local bad
    bad="$(_ci_validate_config_json | jq -r '.services.ui.depends_on // {} | to_entries[] | select(.value.condition == "service_healthy") | .key' 2>/dev/null)"
    if [ -n "${bad}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0044]" "deps=\"${bad}\" reason=\"ui depends_on gates on service_healthy; UI must start independently of dependency health (#763)\""
        return 1
    fi
}

# What: POST /api/secondary/register; print JSON on 200.
# Why: token-gated, no session/CSRF; reused per name.
# From: Issue #583
_ci_register_secondary() {
    local ip="$1" token="$2" name="$3" out code
    out="$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' \
        -d "{\"token\":\"${token}\",\"name\":\"${name}\"}" \
        "http://${ip}:8080/api/secondary/register" 2>/dev/null)"
    code="${out##*$'\n'}"
    [ "${code}" = "200" ] || return 1
    printf '%s' "${out%$'\n'*}"
}

# What: Prove each secondary gets unique identity.
# Why: per-secondary NATS auth-callout, not shared token.
# From: Issue #1683
_ci_validate_secondary_identity() {
    local project="$1" ip cid token a b au bu ap bp
    ip="$(_ci_validate_container_ip "${project}" ui)"
    cid="$(docker compose -p "${project}" ps -q ui 2>/dev/null)"
    if [ -z "${ip}" ] || [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0045]" "reason=\"no ui container/IP for secondary-identity check\""
        return 2
    fi
    # What: read SECONDARY_REGISTRATION_TOKEN from ui file.
    # Why: ui resolves at runtime; not env, not hardcoded.
    # From: Issue #583
    token="$(docker exec "${cid}" cat /data/lancache-secondary-registration.token 2>/dev/null | tr -d '\n')"
    if [ -z "${token}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0046]" "reason=\"could not read SECONDARY_REGISTRATION_TOKEN from ui\""
        return 2
    fi
    if ! a="$(_ci_register_secondary "${ip}" "${token}" ci-secondary-a)" \
        || ! b="$(_ci_register_secondary "${ip}" "${token}" ci-secondary-b)"; then
        ci_log "[CI-ERROR-VALIDATE-0047]" "reason=\"a secondary register did not return 200\""
        return 1
    fi
    au="$(printf '%s' "${a}" | jq -r '.nats_user // empty')"
    bu="$(printf '%s' "${b}" | jq -r '.nats_user // empty')"
    ap="$(printf '%s' "${a}" | jq -r '.nats_password // empty')"
    bp="$(printf '%s' "${b}" | jq -r '.nats_password // empty')"
    if [ -z "${au}" ] || [ -z "${bu}" ] || [ -z "${ap}" ] || [ -z "${bp}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0048]" "reason=\"register response missing nats_user/nats_password\""
        return 1
    fi
    if [ "${au}" = "${bu}" ] || [ "${ap}" = "${bp}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0049]" "reason=\"two secondaries got the same NATS identity (#583 per-secondary identity lost)\""
        return 1
    fi
}

# What: Validate the candidate on one live prod stack.
# Why: One up, all checks, one teardown (AG-VAL-027).
# From: Issue #1683 | PR #1858
_ci_default_validate() {
    local candidate="$1" reservation subnet holder project rc=0 up_out
    local net_ovr pin_ovr
    reservation="$(_ci_validate_reserve)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        [ "${rc}" -eq 2 ] || ci_log "[CI-ERROR-VALIDATE-0015]" "reason=\"no free validation /27 after slot retries\""
        return 2
    fi
    subnet="$(_ci_record_field "${reservation}" subnet)"
    holder="$(_ci_record_field "${reservation}" holder)"
    project="$(_ci_validate_project "${subnet}")" || { _ci_validate_release "${holder}"; return 2; }
    # What: per-run state root; prod .env names the host's.
    # Why: isolate runs; never touch a host's real state.
    # From: Issue #1683
    export LANCACHE_STATE_DIR="${CI_REPO_ROOT}/.ci-validate-state/${project}"
    # What: configured values over the .env template blanks.
    # Why: the template leaves required keys empty.
    # From: Issue #1683
    local -a venv=()
    local vfx
    vfx="$(_ci_validation_env)" || { _ci_validate_release "${holder}"; return 2; }
    mapfile -t venv <<< "${vfx}"
    export "${venv[@]}"
    if ! up_out="$(mkdir -p "${LANCACHE_STATE_DIR}/cache" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0052]" "reason=\"per-run state root not creatable\"" "${up_out}"
        _ci_validate_release "${holder}"
        return 2
    fi
    net_ovr="$(mktemp "${CI_TMPDIR}/ci-validate-net.XXXXXX.yml")"
    pin_ovr="$(mktemp "${CI_TMPDIR}/ci-validate-pin.XXXXXX.yml")"
    if _ci_validate_net_override "${subnet}" > "${net_ovr}" \
        && _ci_validate_pin_override "${candidate}" > "${pin_ovr}"; then
        if up_out="$(_ci_validate_up "${project}" "${net_ovr}" "${pin_ovr}" 2>&1)"; then
            _ci_validate_wait_healthy "${project}" || rc=$?
            [ "${rc}" -eq 0 ] && { _ci_validate_dns "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_proxy "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_proxy_stream_map "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_ssl_mitm "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_ssl_dispatch_map "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_ui_nats_dns "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_dns_rollback "${project}" || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_ui_depends_started || rc=$?; }
            [ "${rc}" -eq 0 ] && { _ci_validate_secondary_identity "${project}" || rc=$?; }
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
    _ci_validate_teardown "${holder}" "${project}" || { [ "${rc}" -ne 0 ] || rc=2; }
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
    _ci_validate_host_tools || return 2
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

# What: Required-check gate over phase results (§62).
# Why: pass/fail classification is ci.sh, not YAML (§5).
# From: Issue #1683 | PR #1858
ci_cmd_result_gate() {
    local results="${CI_PHASE_RESULTS:-}" entry phase state
    local -a entries
    if [ -z "${results}" ]; then
        ci_log "[CI-ERROR-CORE-0101]" "reason=\"CI_PHASE_RESULTS empty\""
        return 2
    fi
    read -ra entries <<< "${results}"
    for entry in "${entries[@]}"; do
        phase="${entry%%:*}"
        state="${entry#*:}"
        case "${phase}" in
            # What: always-run phases: succeed, never skip.
            # Why: skipped plan/checks would hide a red run.
            platform|plan|checks)
                if [ "${state}" != success ]; then
                    ci_log "[CI-ERROR-CORE-0100]" "phase=\"${phase}\" result=\"${state}\""
                    return 1
                fi
                ;;
            # every other phase skips on a NOOP or PR: skipped is success.
            *)
                case "${state}" in
                    success|skipped) ;;
                    *)
                        ci_log "[CI-ERROR-CORE-0100]" "phase=\"${phase}\" result=\"${state}\""
                        return 1
                        ;;
                esac
                ;;
        esac
    done
    printf 'CI 2.0 result gate: %s -> SUCCESS\n' "${results}"
}

# =========================================================
# VARIABLES
# =========================================================

# What: Read a CI variable: env override or SOT default.
# Why: One rule, no hardcode (AG-CI-006, CARGO_BUILD_JOBS).
# From: Issue #1683
_ci_variable() {
    local name="$1" rc=0
    if [ -z "${name}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0003]" "reason=\"no variable name given\""
        return 2
    fi
    _ci_variable_value "${name}" || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    [ "${rc}" -eq 1 ] && ci_log "[CI-ERROR-VARIABLES-0001]" "name=\"${name}\" reason=\"no env value, no CI_VARIABLES entry and no SOT fallback\""
    return 2
}

# What: env, then CI_VARIABLES json, then the SOT default.
# Why: GitHub vars arrive once as json; no per-name YAML.
# From: Issue #1683 | PR #1858
_ci_variable_value() {
    local name="$1" val=""
    val="${!name:-}"
    if [ -z "${val}" ] && [ -n "${CI_VARIABLES:-}" ]; then
        if ! val="$(jq -er --arg n "${name}" '.[$n] // ""' <<< "${CI_VARIABLES}" 2>&1)"; then
            ci_error "[CI-ERROR-VARIABLES-0015]" "name=\"${name}\" reason=\"CI_VARIABLES is not a json object\"" "${val}"
            return 2
        fi
    fi
    [ -n "${val}" ] || val="$(_ci_block_entry_field ci_variables "" "${name}")"
    [ -n "${val}" ] || return 1
    printf '%s\n' "${val}"
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
                        ci_log "[CI-ERROR-VARIABLES-0016]" "image=\"${image}\" extra_ca=\"${rest}\" reason=\"proxy CA baked into cert store\""
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
    printf '%s\n' "${CI_RUNTIME_SECRET_DIR:-${RUNNER_TEMP:-${CI_TMPDIR}}/ci-runtime-secrets}"
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
        ci_log "[CI-ERROR-VARIABLES-0017]" "reason=\"auth token set without scheduler\""
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
    local fmt="${1:-}" platform="${2:-}" prefix="--build-arg " out="" pkgs pins tool
    [ "${fmt}" = "--bare" ] && prefix=""
    tool="$(_ci_toolchain_target)" || return 2
    out="$(_ci_alpine_build_arg "${prefix}")"$'\n' || return 2
    pins="$(_ci_target_pin_args "${tool}" "${platform}" "${prefix}")" || return 2
    [ -z "${pins}" ] || out="${out}${pins}"$'\n'
    # What: append the SOT apk list as a build-arg.
    # Why: Dockerfile consumes it; it never owns the list.
    # From: Issue #1683
    pkgs="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    pkgs="${pkgs% }"
    out="${out}${prefix}APK_PACKAGES=${pkgs}"$'\n'
    # What: add SOT tagged repos as build-arg
    # Why: Dockerfile adds them; never owns URL
    # From: Issue #1683 | PR #1858
    pkgs="$(_ci_apk_repositories "${tool}")" || return 2
    out="${out}${prefix}APK_TAGGED_REPOS=${pkgs}"$'\n'
    printf '%s' "${out}"
}

# What: Emit SOT build-args for one product service.
# Why: single base-image owner; Dockerfiles pin none.
# From: Issue #1683
_ci_service_build_args() {
    local service="$1" fmt="${2:-}" platform="${3:-}" with_toolchain="${4:-yes}"
    local prefix="--build-arg " out="" val ext ext_argname
    [ "${fmt}" = "--bare" ] && prefix=""
    out="$(_ci_alpine_build_arg "${prefix}")"$'\n' || return 2
    # What: external_image field adds one more build-arg.
    # Why: the SOT maps the image; the Dockerfile pins none.
    # From: Issue #1683
    ext="$(_ci_block_entry_field services "${service}" external_image)"
    if [ -n "${ext}" ]; then
        ext_argname="${ext^^}_IMAGE"
        val="$(_ci_block_entry_field base_images "" "${ext}")"
        if [ -z "${val}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0007]" "arg=\"${ext_argname}\" service=\"${service}\" key=\"base_images.${ext}\" reason=\"missing central external image; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}${ext_argname}=${val}"$'\n'
    fi
    # What: Rust builders use build-tools image ref
    # Why: SOT owns ref; Dockerfile keeps none
    # From: Issue #1683
    if [ "$(_ci_block_entry_field services "${service}" build_type)" = rust ]; then
        # What: identity omits the registry-resolved ref.
        # Why: toolchain_digest keys it; no network in id.
        # From: Issue #1683 | PR #1858
        if [ "${with_toolchain}" = yes ]; then
            val="$(${CI_BUILD_TOOLS_IMAGE_CMD:-_ci_build_tools_resolve_image})" || return 2
            [ -n "${val}" ] || { ci_log "[CI-ERROR-BUILDARGS-0009]" "arg=\"BUILD_TOOLS_IMAGE\" service=\"${service}\" reason=\"empty resolved build-tools image; FAIL CLOSED\""; return 2; }
            out="${out}${prefix}BUILD_TOOLS_IMAGE=${val}"$'\n'
        fi
        # What: emit the SOT workspace crate for rust-build.
        # Why: one crate owner; the Dockerfile names none.
        # From: Issue #1683 | PR #1858
        val="$(_ci_block_entry_field services "${service}" crate)"
        [ -n "${val}" ] || { ci_log "[CI-ERROR-BUILDARGS-0014]" "arg=\"RUST_CRATE\" service=\"${service}\" reason=\"no crate in SOT; FAIL CLOSED\""; return 2; }
        out="${out}${prefix}RUST_CRATE=${val}"$'\n'
        # What: emit the platform's Alpine musl host triple.
        # Why: apk Rust ships only its host std, no rustup.
        # From: Issue #1683
        if [ -n "${platform}" ]; then
            local arch
            arch="$(_ci_platform_apk_arch "${platform}")" || { ci_log "[CI-ERROR-BUILDARGS-0010]" "platform=\"${platform}\" service=\"${service}\" reason=\"no apk-arch mapping for platform; FAIL CLOSED\""; return 2; }
            out="${out}${prefix}MUSL_TARGET=${arch}-alpine-linux-musl"$'\n'
        fi
    fi
    # What: SOT-pinned external inputs of this Dockerfile.
    # Why: one pin->ARG owner shared with version verify.
    # From: Issue #1683 | PR #1858
    local pins
    pins="$(_ci_target_pin_args "${service}" "${platform}" "${prefix}")" || return 2
    [ -z "${pins}" ] || out="${out}${pins}"$'\n'
    # What: add service's apk packages from SOT
    # Why: SOT owns list; Dockerfile derives it
    # From: Issue #1683
    local apk_pkgs
    apk_pkgs="$(_ci_block_entry_list services "${service}" packages | tr '\n' ' ')"
    apk_pkgs="${apk_pkgs% }"
    if [ -n "${apk_pkgs}" ]; then
        out="${out}${prefix}APK_PACKAGES=${apk_pkgs}"$'\n'
    fi
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
    local tools svc_list
    svc_list="$(ci_services)" || return 2
    tools="$(_ci_block_keys build_toolchain)" || return 2
    if grep -qxF -- "${service}" <<< "${svc_list}"; then
        _ci_service_build_args "${service}" "${fmt}" "${platform}"
    elif grep -qxF -- "${service}" <<< "${tools}"; then
        _ci_build_tools_build_args "${fmt}" "${platform}"
    else
        ci_log "[CI-ERROR-BUILDARGS-0002]" "service=\"${service}\" reason=\"not a SOT build target\""
        return 2
    fi
}

# What: a target's SOT apk_repositories, space-joined.
# Why: each target resolves with its own repos only.
# From: Issue #1683
_ci_apk_repositories() {
    local out
    out="$(_ci_block_entry_list services "$1" apk_repositories)"
    [ -n "${out}" ] || out="$(_ci_block_entry_list build_toolchain "$1" apk_repositories)"
    printf '%s' "${out//$'\n'/ }"
}

# What: Print the build-tools apk package list.
# Why: One SOT source feeds the input check.
# From: Issue #1683
_ci_build_tools_packages() {
    local pkgs tool
    tool="$(_ci_toolchain_target)" || return 2
    # What: read the exact SOT apk list via the one reader.
    # Why: SOT is the owner; no parse-back, no new parser.
    # From: Issue #1683
    pkgs="$(_ci_block_entry_list build_toolchain "${tool}" packages | LC_ALL=C sort -u)"
    # What: fail closed if the SOT list is empty.
    # Why: an empty list would blind the input check.
    # From: Issue #1683
    if [ -z "${pkgs}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0006]" "reason=\"no packages in SOT build_toolchain.${tool}.packages; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${pkgs}"
}

# What: Print a toolchain smoke list (smoke_tools|_runs).
# Why: SOT is the one smoke owner (AG-VAL-017).
# From: Issue #1683 | PR #1858
_ci_build_tools_smoke() {
    local field="$1" items tool
    tool="$(_ci_toolchain_target)" || return 2
    items="$(_ci_block_entry_list build_toolchain "${tool}" "${field}")"
    if [ -z "${items}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0013]" "field=\"${field}\" reason=\"empty SOT smoke list; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${items}"
}

# What: Print the build-tools input signature.
# Why: Weekly check rebuilds only on a changed input.
# From: Issue #1683
_ci_build_tools_signature() {
    local versions="$1" args ids trimmed tool ctx
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
    tool="$(_ci_toolchain_target)" || return 2
    ctx="$(_ci_required_field "${tool}" context)" || return 2
    ids="$(_ci_tracked_content_ids "${ctx}")" || return 2
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
    local platform out="" apk plats
    plats="$(_ci_build_matrix_platforms)" || return 2
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
    done <<< "${plats}"
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
    local base="$1" arch="$2" packages="$3" repos="${4:-}" raw n
    local -a penv=()
    while IFS= read -r n; do penv+=(-e "${n}"); done < <(_ci_proxy_names)
    _ci_procsub_ok "$!" 0 || return 2
    if [ -n "${CI_APK_RESOLVE_CMD:-}" ]; then
        "${CI_APK_RESOLVE_CMD}" "${base}" "${arch}" "${packages}"
        return "$?"
    fi
    # What: per-arch clean root with the build's repos.
    # Why: a foreign arch needs its own db and keys.
    # From: Issue #1683 | PR #1858
    if ! raw="$(_ci_retry apk docker run --rm "${penv[@]}" -e ARCH="${arch}" -e PKGS="${packages}" \
            -e REPOS="${repos}" "${base}" sh -c '
        set -e
        r=/var/tmp/apk-root; k="/usr/share/apk/keys/${ARCH}"
        mkdir -p "${r}/etc/apk"
        sed "s|^https://|http://|" /etc/apk/repositories > "${r}/etc/apk/repositories"
        for kv in ${REPOS}; do echo "@${kv%%=*} ${kv#*=}" >> "${r}/etc/apk/repositories"; done
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" --initdb add
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" update
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" add --simulate ${PKGS}')"; then
        ci_log "[CI-ERROR-BUILDTOOLS-0020]" "arch=\"${arch}\" reason=\"apk resolve failed\""
        return 2
    fi
    printf '%s\n' "${raw}" | sed -n 's/^.*Installing \([^ ]*\) (\([^)]*\)).*/\1-\2/p' \
        | LC_ALL=C sort | tr '\n' ' '
}

# What: Resolve every arch's apk state, then sign it.
# Why: the whole signature is computed here, not in YAML.
# From: Issue #1683
_ci_build_tools_resolve_signature() {
    local base packages arches arch av versions="" tool repos
    base="$(_ci_build_tools_build_args --bare | sed -n 's/^ALPINE_IMAGE=//p')" || {
        ci_log "[CI-ERROR-BUILDTOOLS-0009]" "reason=\"no ALPINE_IMAGE from SOT; FAIL CLOSED\""
        return 2
    }
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0009]" "reason=\"no ALPINE_IMAGE from SOT; FAIL CLOSED\""
        return 2
    fi
    packages="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    arches="$(_ci_build_tools_arches)" || return 2
    tool="$(_ci_toolchain_target)" || return 2
    repos="$(_ci_apk_repositories "${tool}")" || return 2
    for arch in ${arches}; do
        av="$(_ci_apk_resolve "${base}" "${arch}" "${packages}" "${repos}")" || return 2
        if [ -z "${av}" ]; then
            ci_log "[CI-ERROR-BUILDTOOLS-0011]" "arch=\"${arch}\" reason=\"no apk versions; FAIL CLOSED\""
            return 2
        fi
        versions="${versions}${arch}:${av} "
    done
    _ci_build_tools_signature "${versions}"
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

# What: resolve published build-tools to immutable ref.
# Why: jobs pin toolchain by digest; no cascade.
# From: Issue #1683
_ci_build_tools_resolve_image() {
    local ref channel image digest
    ref="${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}"
    # What: consume the channel a push to this branch moves.
    # Why: one ref->channel owner (promote); else nightly.
    # From: Issue #1683 | PR #1858
    channel="$(GITHUB_REF="refs/heads/${ref}" CI_PROMOTE_REQUESTED_CHANNEL='' _ci_promote_targets_for_ref)" || return 2
    channel="${channel%%$'\n'*}"
    [ -n "${channel}" ] || channel="$(_ci_block_entry_field release "" default_channel)"
    if [ -z "${channel}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0021]" "reason=\"no SOT release.default_channel; FAIL CLOSED\""
        return 2
    fi
    image="$(_ci_build_tools_image)"
    _ci_require_ghcr_auth || return "$?"
    if ! digest="$(_ci_registry_digest "${image}:${channel}")"; then
        ci_log "[CI-ERROR-BUILDTOOLS-0018]" "channel=\"${channel}\" reason=\"no published build-tools digest; FAIL CLOSED\""
        return 2
    fi
    printf '%s@%s\n' "${image}" "${digest}"
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
        image) _ci_build_tools_image ;;
        resolve-image) _ci_build_tools_resolve_image "${1:-}" ;;
        *)
            ci_log "[CI-ERROR-BUILDTOOLS-0003]" "sub=\"${sub}\" reason=\"unknown build-tools subcommand\""
            return 2
            ;;
    esac
}

# =========================================================
# VERSION MANAGEMENT
# =========================================================

# What: Parse one ARG NAME[=VALUE] Dockerfile declaration.
# Why: AG-VAL-036: grammar reader, not ad-hoc regex guess.
# From: Issue #1683 | PR #1858
_ci_dockerfile_arg_default() {
    local path="$1" name="$2"
    if [ ! -f "${path}" ]; then
        ci_log "[CI-ERROR-VERSION-0001]" "path=\"${path}\" reason=\"file not found\""
        return 2
    fi
    local -a hits=()
    local raw
    while IFS= read -r raw; do
        hits+=("${raw}")
    done < <(awk -v n="${name}" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line !~ /^[Aa][Rr][Gg][[:space:]]+/) next
            sub(/^[Aa][Rr][Gg][[:space:]]+/, "", line)
            if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*/)) next
            decl = substr(line, RSTART, RLENGTH)
            if (decl != n) next
            rest = substr(line, RLENGTH + 1)
            sub(/^[[:space:]]+/, "", rest)
            sub(/[[:space:]]+$/, "", rest)
            print rest
        }
    ' "${path}")
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#hits[@]}" -eq 0 ]; then
        printf 'ABSENT\n'
        return 0
    fi
    if [ "${#hits[@]}" -gt 1 ]; then
        # What: Allow ARG re-declares only when identical.
        # Why: Bare-after-valued would silently guess wrong.
        # From: Issue #1683 | PR #1858
        local h uniq="" mixed=0
        for h in "${hits[@]}"; do
            if [ -z "${uniq}" ]; then
                uniq="${h}"
            elif [ "${h}" != "${uniq}" ]; then
                mixed=1
            fi
        done
        if [ "${mixed}" -eq 1 ]; then
            ci_log "[CI-ERROR-VERSION-0002]" "path=\"${path}\" name=\"${name}\" reason=\"conflicting ARG re-declarations; ambiguous default\""
            return 2
        fi
    fi
    local rest="${hits[0]}"
    if [ -z "${rest}" ]; then
        printf 'BARE\n'
        return 0
    fi
    case "${rest}" in
        =*)
            local val="${rest#=}"
            case "${val}" in
                *\\)
                    ci_log "[CI-ERROR-VERSION-0003]" "path=\"${path}\" name=\"${name}\" reason=\"line continuation unsupported\""
                    return 2
                    ;;
            esac
            case "${val}" in
                \"*\")
                    val="${val#\"}"; val="${val%\"}"
                    case "${val}" in
                        *\"*)
                            ci_log "[CI-ERROR-VERSION-0004]" "path=\"${path}\" name=\"${name}\" reason=\"embedded double-quote unsupported\""
                            return 2
                            ;;
                    esac
                    ;;
                \'*\')
                    val="${val#\'}"; val="${val%\'}"
                    case "${val}" in
                        *\'*)
                            ci_log "[CI-ERROR-VERSION-0015]" "path=\"${path}\" name=\"${name}\" reason=\"embedded single-quote unsupported\""
                            return 2
                            ;;
                    esac
                    ;;
                *)
                    case "${val}" in
                        *[\ \"\']*)
                            ci_log "[CI-ERROR-VERSION-0005]" "path=\"${path}\" name=\"${name}\" reason=\"unquoted value has space/quote\""
                            return 2
                            ;;
                    esac
                    ;;
            esac
            printf 'FOUND:%s\n' "${val}"
            ;;
        *)
            ci_log "[CI-ERROR-VERSION-0006]" "path=\"${path}\" name=\"${name}\" reason=\"unexpected token after ARG name\""
            return 2
            ;;
    esac
}

# What: SOT pin consumers: dep|dockerfile|build_args keys.
# Why: SOT consumer field owns it; no engine-side list.
# From: Issue #1683 | PR #1858
_ci_version_consumers() {
    local deps dep target keys ctx
    deps="$(_ci_block_keys external_versions)" || return 2
    for dep in ${deps}; do
        target="$(_ci_block_entry_field external_versions "${dep}" consumer)"
        [ -n "${target}" ] || continue
        keys="$(_ci_block_entry_list external_versions "${dep}" build_args)"
        if [ -z "${keys}" ]; then
            ci_log "[CI-ERROR-VERSION-0010]" "dep=\"${dep}\" reason=\"consumer without SOT build_args\""
            return 2
        fi
        ctx="$(_ci_required_field "${target}" context)" || return 2
        printf '%s|%s/Dockerfile|%s\n' "${dep}" "${ctx}" "${keys//$'\n'/ }"
    done
}

# What: One pin's sha256 for an apk arch, fail-closed.
# Why: a missing or garbled checksum must never pass.
# From: Issue #1683 | PR #1858
_ci_pin_sha() {
    local dep="$1" apk="$2" val
    val="$(_ci_block_entry_field external_versions "${dep}" "sha256_${apk}")"
    if [ -z "${val}" ]; then
        ci_log "[CI-ERROR-BUILDARGS-0004]" "key=\"external_versions.${dep}.sha256_${apk}\" reason=\"missing central pin; FAIL CLOSED\""
        return 2
    fi
    if [[ ! "${val}" =~ ^[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-BUILDARGS-0015]" "key=\"external_versions.${dep}.sha256_${apk}\" reason=\"not 64 hex chars; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${val}"
}

# What: emit pin args for dep, arch, and sha256
# Why: one pin->ARG convention for every arch
# From: Issue #1683 | PR #1858
_ci_pin_args() {
    local dep="$1" keys="$2" platform="$3" prefix="$4" up key val apk p out=""
    up="${dep^^}"; up="${up//-/_}"
    for key in ${keys}; do
        val="$(_ci_block_entry_field external_versions "${dep}" "${key}")"
        if [ -z "${val}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0004]" "key=\"external_versions.${dep}.${key}\" reason=\"missing central pin; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}${up}_${key^^}=${val}"$'\n'
    done
    if [ -n "${platform}" ]; then
        apk="$(_ci_platform_apk_arch "${platform}")" || {
            ci_log "[CI-ERROR-BUILDARGS-0006]" "platform=\"${platform}\" reason=\"no apk arch mapping; FAIL CLOSED\""
            return 2
        }
        val="$(_ci_pin_sha "${dep}" "${apk}")" || return 2
        out="${out}${prefix}${up}_ARCH=${apk}"$'\n'"${prefix}${up}_SHA256=${val}"$'\n'
    else
        local plats
        plats="$(_ci_build_matrix_platforms)" || return 2
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            apk="$(_ci_platform_apk_arch "${p}")" || return 2
            val="$(_ci_pin_sha "${dep}" "${apk}")" || return 2
            out="${out}${prefix}${up}_SHA256_${apk^^}=${val}"$'\n'
        done <<< "${plats}"
    fi
    printf '%s' "${out}"
}

# What: pin build-args for target's Dockerfile
# Why: build-args derive from verify check list
# From: Issue #1683 | PR #1858
_ci_target_pin_args() {
    local target="$1" platform="$2" prefix="$3" ctx dep df keys consumers
    ctx="$(_ci_required_field "${target}" context)" || return 2
    consumers="$(_ci_version_consumers)" || return 2
    while IFS='|' read -r dep df keys; do
        [ -n "${dep}" ] && [ "${df}" = "${ctx}/Dockerfile" ] || continue
        _ci_pin_args "${dep}" "${keys}" "${platform}" "${prefix}" || return 2
    done <<< "${consumers}"
}

# What: The SOT alpine base as ALPINE_IMAGE, fail-closed.
# Why: every target's final stage pins this one owner.
# From: Issue #1683 | PR #1858
_ci_alpine_build_arg() {
    local prefix="$1" val
    val="$(_ci_block_entry_field base_images "" alpine)"
    if [ -z "${val}" ]; then
        ci_log "[CI-ERROR-BUILDARGS-0003]" "arg=\"ALPINE_IMAGE\" key=\"base_images.alpine\" reason=\"missing central base image; FAIL CLOSED\""
        return 2
    fi
    printf '%sALPINE_IMAGE=%s\n' "${prefix}" "${val}"
}

# What: check consumer's SOT pins vs Dockerfile
# Why: SOT owns pin; baked ARG default is 2nd owner
# From: Issue #1683 | PR #1858
_ci_version_diff() {
    local dep="$1" dockerfile="${CI_REPO_ROOT}/$2" keys="$3" p args name want out="" plats
    plats="$(_ci_build_matrix_platforms)" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        args="$(_ci_pin_args "${dep}" "${keys}" "${p}" "")" || return 2
        out="${out}${args}"$'\n'
    done <<< "${plats}"
    local line
    local -A argseen=()
    out="$(LC_ALL=C sort -u <<< "${out}")"
    while IFS= read -r line; do
        [ -n "${line}" ] && printf 'key=%s.sot %s\n' "${dep}" "${line}"
    done <<< "${out}"
    while IFS= read -r line; do
        name="${line%%=*}"
        { [ -n "${name}" ] && [ -z "${argseen[${name}]:-}" ]; } || continue
        argseen["${name}"]=1
        want="$(_ci_dockerfile_arg_default "${dockerfile}" "${name}")" || return 2
        case "${want}" in
            ABSENT)
                ci_log "[CI-ERROR-VERSION-0008]" "path=\"${dockerfile}\" name=\"${name}\" reason=\"expected ARG declaration missing\""
                return 2
                ;;
            BARE) printf 'key=%s.consumer.%s shape=bare\n' "${dep}" "${name}" ;;
            FOUND:*)
                ci_log "[CI-ERROR-VERSION-0009]" "path=\"${dockerfile}\" name=\"${name}\" reason=\"unexpected baked default; must stay SOT-driven\""
                return 2
                ;;
        esac
    done <<< "${out}"
}

# What: Run _ci_version_diff for every SOT-pinned consumer.
# Why: verify/audit/sync differ only in how they report.
# From: Issue #1683 | PR #1858
_ci_version_walk() {
    local fn="$1" dep df keys rc=0 r consumers
    consumers="$(_ci_version_consumers)" || return 2
    while IFS='|' read -r dep df keys; do
        [ -n "${dep}" ] || continue
        r=0
        "${fn}" "${dep}" "${df}" "${keys}" || r=$?
        [ "${r}" -eq 0 ] || [ "${rc}" -ne 0 ] || rc="${r}"
    done <<< "${consumers}"
    return "${rc}"
}


# What: version verify: default, read-only, fails on drift.
# Why: The one CI gate for SOT-vs-repo version drift.
# From: Issue #1683 | PR #1858
_ci_version_verify() {
    _ci_version_walk _ci_version_diff
}

# What: sync consumer's bare ARGs, nothing to update
# Why: SOT-driven consumers have no literal to write
# From: Issue #1683 | PR #1858
_ci_version_sync_one() {
    _ci_version_diff "$@" || return "$?"
    printf 'sync=%s changed=0 reason=nothing-to-write\n' "$1"
}

# What: sync all version consumer contracts
# Why: idempotent; nothing to write if all bare
# From: Issue #1683 | PR #1858
_ci_version_sync() {
    _ci_version_walk _ci_version_sync_one
}

# What: version verify/audit/sync for SOT external_versions.
# Why: pin consumers must not silently drift from the SOT.
# From: Issue #1683 | PR #1858
ci_cmd_version() {
    local sub="${1:-verify}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        verify|audit) _ci_version_verify ;;
        sync)   _ci_version_sync ;;
        *)
            ci_log "[CI-ERROR-VERSION-0014]" "sub=\"${sub}\" reason=\"unknown version subcommand\""
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
    _ci_tmp_init || return "$?"
    _ci_proxy_init || return "$?"
    # What: skip manifest for build-only commands
    # Why: bind-mounted stage has no SOT present
    # From: Issue #1683
    case "${command}" in check|rust-build|apk-setup) ;; *) ci_require_manifest || return "$?" ;; esac
    "${fn}" "$@"
}

# =========================================================
# SOURCE-HYGIENE CHECKS
# =========================================================

# What: fail if the last < <(producer) exited above max.
# Why: a failed producer must not read as an empty result.
# From: Issue #1683
_ci_procsub_ok() {
    local pid="$1" max="${2:-0}" rc=0
    wait "${pid}" || rc=$?
    [ "${rc}" -le "${max}" ] && return 0
    ci_log "[CI-ERROR-CORE-0010]" "rc=${rc} reason=\"loop producer failed; refusing a partial result\""
    return 2
}

# What: out[]=override if non-empty, else git ls-files spec.
# Why: 7 checks repeated this override-or-scan boilerplate.
# From: Issue #1683
_ci_scan_files() {
    local -n _ci_scan_out="$1" _ci_scan_override="$2"
    shift 2
    local -a _ci_scan_in=()
    local _ci_scan_p _ci_scan_gone=0 _ci_scan_raw
    # What: git ls-files only when needed; failure is fatal.
    # Why: an empty list would report every check as clean.
    # From: Issue #1683 | PR #1858
    if [ "${#_ci_scan_override[@]}" -eq 0 ] || { [ "${CI_SCAN_SCOPE_FILTER:-0}" = 1 ] && [ "$#" -gt 0 ]; }; then
        if ! _ci_scan_raw="$(git ls-files -- "$@")"; then
            ci_log "[CI-ERROR-CHECK-0071]" "reason=\"git ls-files failed; refusing an empty scan\""
            return 2
        fi
    fi
    if [ "${#_ci_scan_override[@]}" -gt 0 ]; then
        _ci_scan_in=("${_ci_scan_override[@]}")
        # What: narrow changed files to check scope
        # Why: .md/.bats changes don't affect checks
        # From: Issue #1683 | PR #1858
        if [ "${CI_SCAN_SCOPE_FILTER:-0}" = 1 ] && [ "$#" -gt 0 ]; then
            local -A _ci_scan_scope=()
            while IFS= read -r _ci_scan_p; do
                [ -n "${_ci_scan_p}" ] && _ci_scan_scope["${_ci_scan_p}"]=1
            done <<< "${_ci_scan_raw}"
            local -a _ci_scan_kept=()
            for _ci_scan_p in "${_ci_scan_in[@]}"; do
                if [ ! -f "${_ci_scan_p}" ] || [ -n "${_ci_scan_scope[${_ci_scan_p}]:-}" ]; then
                    _ci_scan_kept+=("${_ci_scan_p}")
                fi
            done
            _ci_scan_in=("${_ci_scan_kept[@]}")
        fi
    elif [ -n "${_ci_scan_raw}" ]; then
        mapfile -t _ci_scan_in <<< "${_ci_scan_raw}"
    fi
    # What: keep files in tree, skip deleted ones
    # Why: deleted paths have no content to check
    # From: Issue #1683 | PR #1858
    _ci_scan_out=()
    for _ci_scan_p in "${_ci_scan_in[@]}"; do
        if [ -f "${_ci_scan_p}" ]; then
            _ci_scan_out+=("${_ci_scan_p}")
        else
            _ci_scan_gone=$((_ci_scan_gone + 1))
        fi
    done
    if [ "${_ci_scan_gone}" -gt 0 ]; then
        ci_log "[CI-NOTICE-CHECK-0070]" "skipped=${_ci_scan_gone} reason=\"path not in the tree (deleted)\""
    fi
}

# What: Fail on any listed text file carrying CRLF.
# Why: eol=lf can be bypassed (API write, pre-attr commit).
# From: Issue #1683
_ci_check_line_endings() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override || return 2
    local path
    local -a offenders=()
    for path in "${files[@]}"; do
        case "${path}" in
            *.png|*.jpg|*.jpeg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot|*.crt|*.key|*.pem) continue ;;
        esac
        local crlf
        crlf="$(_ci_capture 1 grep -a -m1 -n $'\r' "${path}")" || return 2
        if [ -n "${crlf}" ]; then
            offenders+=("${path}")
        fi
    done
    if [ "${#offenders[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0002]" "reason=\"CRLF found; repo requires LF\"" "$(printf '%s\n' "${offenders[@]}")"
        return 1
    fi
    printf 'line-endings=clean files=%s\n' "${#files[@]}"
}

# What: True for a path exempt from prose-comment checks.
# Why: One owner for header + review-chronology exclusions.
# From: Issue #1683
_ci_prose_excluded() {
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
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override || return 2
    local path exp p_line s_line legacy line pc sc scnt lc
    local -a fails=() scan=()
    for path in "${files[@]}"; do
        _ci_prose_excluded "${path}" && continue
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

# What: Enforce AG-CODE-012 comment size, block, ref rules.
# Why: 1-1-1-60, story-run size, and refs go in From only.
# From: Issue #1683
_ci_check_comment_length() {
    local -a _ci_override=("$@") files=()
    local file heredoc_on yaml_on rc=0
    _ci_scan_files files _ci_override || return 2
    for file in "${files[@]}"; do
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
                    if (line ~ /^[[:space:]]*#[[:space:]]*(What|Why):/ && line ~ /#[0-9]/) { printf "%s:%d: issue/PR ref in What/Why (use From:): %s\n", FILENAME, FNR, line; viol++ }
                    if (line ~ /^[[:space:]]*#[[:space:]]*From:/ && line !~ /From: (Issue #[0-9]+|PR #[0-9]+|Issue #[0-9]+ \| PR #[0-9]+)$/) { printf "%s:%d: From: allows one Issue and one PR only: %s\n", FILENAME, FNR, line; viol++ }
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

# What: fail on short-SHA slice of sha-named variable.
# Why: bans collision-unsafe truncation.
# From: Issue #1683
_ci_check_deny_short_sha() {
    local pat='\$\{([A-Za-z_][A-Za-z0-9_]*)?([Ss][Hh][Aa]|[Cc][Oo][Mm][Mm][Ii][Tt]|[Cc][Aa][Nn][Dd][Ii][Dd][Aa][Tt][Ee]|[Rr][Ee][Vv][Ii][Ss][Ii][Oo][Nn])[A-Za-z0-9_]*[[:space:]]*(:[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+|:[[:space:]]*0[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+)\}'
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/scripts/*.sh' '.github/scripts/*.bats' '.github/workflows/*.yml' 'scripts/lib/*.sh' || return 2
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        out="$(_ci_capture 1 grep -EnH "${pat}" "${path}")" || return 2
        if [ -n "${out}" ]; then
            viol+=("${out}")
        fi
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
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override || return 2
    local path
    local -a viol=()
    for path in "${files[@]}"; do
        # What: vendored minified UI asset, not authored.
        # Why: AG-REL-001 governs authored, not vendored.
        # From: Issue #1683 | PR #1858
        case "${path}" in services/ui/src/static/*.min.js) continue ;; esac
        case "${path}" in
            *.py|*.pyc|*.pyw|*.rb|*.php|*.pl|*.pm|*.js|*.mjs|*.cjs|*.ts) viol+=("${path}: banned-language file"); continue ;;
        esac
        case "${path}" in
            *.sh|*.bats|*.yml|*.yaml)
                local inline
                inline="$(_ci_capture 1 grep -E '(python3?|perl|ruby|node)[[:space:]]+-[eEc]|<<-?[[:space:]]*"?(PY|PYEOF|PYTHON|PERL|RUBY)' "${path}")" || return 2
                if [ -n "${inline}" ]; then
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
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/workflows/*.yml' '.github/actions/**/action.yml' '*/Dockerfile' 'Dockerfile' || return 2
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        case "${path}" in
            *.yml|*.yaml)
                out="$(_ci_capture 1 grep -nE 'uses:[^@]*@v[0-9]' "${path}")" || return 2
                if [ -n "${out}" ]; then
                    viol+=("${path} action-@vN: ${out}")
                fi
                # What: grep pattern in ARG not ref.
                # Why: PROMOTE_TAGS greps ARG :latest.
                # From: Issue #1683 | PR #1858
                out="$(_ci_capture 1 grep -nE 'BUILD_TOOLS_IMAGE=[^[:space:]]*:latest' "${path}")" || return 2
                out="$(_ci_capture 1 grep -vF 'ARG BUILD_TOOLS_IMAGE=' <<< "${out}")" || return 2
                if [ -n "${out}" ]; then
                    viol+=("${path} img-default-latest: ${out}")
                fi
                ;;
            */Dockerfile|Dockerfile)
                out="$(_ci_capture 1 grep -nE '^FROM .+:latest' "${path}")" || return 2
                out="$(_ci_capture 1 grep -vE 'sccache-ng|ccache-ng' <<< "${out}")" || return 2
                if [ -n "${out}" ]; then
                    viol+=("${path} FROM-latest: ${out}")
                fi
                out="$(_ci_capture 1 grep -nE '^FROM [a-z0-9./]+$' "${path}")" || return 2
                if [ -n "${out}" ]; then
                    viol+=("${path} FROM-untagged: ${out}")
                fi
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
    local -a owned=(.github/scripts/ci.sh) paths=()
    local h path mode
    local hooks
    hooks="$(git ls-files -- '.githooks/*')" || { ci_log "[CI-ERROR-CHECK-0071]" "reason=\"git ls-files failed; refusing an empty scan\""; return 2; }
    while IFS= read -r h; do [ -n "${h}" ] && owned+=("${h}"); done <<< "${hooks}"
    # What: a changed-file list only narrows the owned set.
    # Why: Dockerfile/Cargo.toml are no bare-path scripts.
    # From: Issue #1683 | PR #1858
    if [ "$#" -eq 0 ]; then
        paths=("${owned[@]}")
    else
        for path in "$@"; do
            for h in "${owned[@]}"; do [ "${path}" = "${h}" ] && paths+=("${path}"); done
        done
    fi
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

# What: Sets caller's files array from a diff-scoped fetch.
# Why: captures to a file; process subst. drops exit status.
# From: Issue #1683 | PR #1686
_ci_review_chronology_diff_files() {
    : "${CHRONOLOGY_DIFF_BASE_REF:?CHRONOLOGY_DIFF_BASE_REF is required}"
    : "${GITHUB_SHA:?GITHUB_SHA is required}"
    _ci_retry "git-fetch-chronology-base-ref" git fetch --no-tags --depth=1 origin \
        "+refs/heads/${CHRONOLOGY_DIFF_BASE_REF}:refs/remotes/origin/${CHRONOLOGY_DIFF_BASE_REF}" >/dev/null || return 2
    _ci_retry "git-fetch-chronology-base-sha" git fetch --no-tags --depth=1 origin \
        "${CHRONOLOGY_DIFF_BASE_SHA}" >/dev/null || return 2
    git cat-file -e "${CHRONOLOGY_DIFF_BASE_SHA}^{commit}" || {
        ci_log "[CI-ERROR-CHECK-0010]" "reason=\"diff base sha unreachable\""; return 2; }
    git cat-file -e "${GITHUB_SHA}^{commit}" || {
        ci_log "[CI-ERROR-CHECK-0076]" "reason=\"GITHUB_SHA unreachable\""; return 2; }
    local diff_file
    diff_file="$(mktemp -p "${CI_TMPDIR}")"
    if ! git diff -z --name-only --diff-filter=ACMRTUXB \
        "${CHRONOLOGY_DIFF_BASE_SHA}" "${GITHUB_SHA}" > "${diff_file}"; then
        ci_log "[CI-ERROR-CHECK-0077]" "reason=\"git diff itself failed; not treating as a clean pass\""
        rm -f "${diff_file}"
        return 2
    fi
    mapfile -d '' files < "${diff_file}"
    rm -f "${diff_file}"
}

# What: flags review-chronology, stale line-refs, dup #N.
# Why: comments must state current code only (AG-CODE-012).
# From: Issue #1683
_ci_check_review_chronology() {
    local verbs='(caught|found|flagged|spotted|identified|discovered|noticed)'
    local rc="(\\b${verbs}\\b[[:space:]]+(in|during)[[:space:]]+((a|the|this)[[:space:]]+)?(code[[:space:]]+|pr[[:space:]]+|peer[[:space:]]+)?(self-)?review\\b)"
    rc="${rc}|(\\breview\\b[^a-zA-Z.]{0,20}\\b${verbs}\\b)"
    rc="${rc}|(\\b(before|prior to|until)[[:space:]]+this[[:space:]]+(fix|change|commit|patch)\\b)"
    rc="${rc}|(\\breview[[:space:]]+finding\\b)"
    local lr='\(([Ss]ee[[:space:]]+)?\bline\b[[:space:]]*~?[0-9]+'
    local -a _ci_override=("$@") files=()
    if [ -n "${CHRONOLOGY_DIFF_BASE_SHA:-}" ]; then
        _ci_review_chronology_diff_files || return 2
    else
        _ci_scan_files files _ci_override || return 2
    fi
    local path out ln joined fnums num from_lines
    local -a viol=() dup_viol=()
    for path in "${files[@]}"; do
        _ci_prose_excluded "${path}" && continue
        out="$(_ci_capture 1 grep -EinIH "${rc}" "${path}")" || return 2
        if [ -n "${out}" ]; then
            viol+=("${out}")
        fi
        out="$(_ci_capture 1 grep -EinIH "${lr}" "${path}")" || return 2
        if [ -n "${out}" ]; then
            viol+=("${out}")
        fi
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
        _ci_procsub_ok "$!" 0 || return 2
        from_lines="$(_ci_capture 1 grep -EI 'From:' "${path}")" || return 2
        [ -n "${from_lines}" ] || continue
        fnums="$(_ci_capture 1 grep -oEI '#[0-9]+' <<< "${from_lines}")" || return 2
        fnums="$(tr -d '#' <<< "${fnums}" | sort -u)"
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
            [ -n "${out}" ] && dup_viol+=("${out}")
        done <<< "${fnums}"
    done
    # What: dup #N outside From: is warn-only in every mode.
    # Why: a genuine duplicate must warn, never block.
    # From: Issue #1683
    if [ "${#dup_viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0078]" "reason=\"bare #N duplicated outside From: (warn-only, PR #1856)\"" "$(printf '%s\n' "${dup_viol[@]}")"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        if [ "${CHRONOLOGY_WARN_ONLY:-0}" = "1" ]; then
            ci_error "[CI-ERROR-CHECK-0079]" "reason=\"review-chronology / stale line-ref (warn-only)\"" "$(printf '%s\n' "${viol[@]}")"
            printf 'review-chronology=warn files=%s\n' "${#files[@]}"
            return 0
        fi
        ci_error "[CI-ERROR-CHECK-0080]" "reason=\"review-chronology / stale line-ref\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'review-chronology=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a live pipe into an early-exiting consumer.
# Why: SIGPIPE under pipefail exits 141 (AG-VAL-029).
# From: Issue #1683
_ci_check_pipefail_early_exit() {
    # What: one pipe (not ||) into grep -q/-m/head/sed q.
    # Why: only grep's own option words count, not -eq.
    # From: Issue #1683 | PR #1858
    local pat='(^|[^|])\|[[:space:]]*(grep([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(-[a-zA-Z]*(q|m[[:space:]]*[0-9])|--(quiet|silent|max-count))|head([[:space:]]|$)|sed[^|]*([[:space:];{]|[0-9])q)'
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/scripts/*.sh' '.github/scripts/*.bats' '*/Dockerfile' 'Dockerfile' 'services/*.sh' || return 2
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        out="$(_ci_capture 1 grep -E 'pipefail|build-tools|BUILD_TOOLS_IMAGE' "${path}")" || return 2
        [ -n "${out}" ] || continue
        out="$(_ci_capture 1 grep -nE "${pat}" "${path}")" || return 2
        if [ -n "${out}" ]; then
            viol+=("${path}: ${out}")
        fi
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0011]" "reason=\"live pipe into early-exit consumer (SIGPIPE)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'pipefail-early-exit=clean files=%s\n' "${#files[@]}"
}

# What: Flag a $? read first after an else-less if.
# Why: that $? is the if's own 0 (AG-VAL-030).
# From: Issue #1683 | PR #1858
_ci_check_if_without_else_status() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/scripts/*.sh' '.github/scripts/*.bats' '*/Dockerfile' 'Dockerfile' 'services/*.sh' || return 2
    local path fi_line status_line
    local -a viol=()
    for path in "${files[@]}"; do
        while IFS=: read -r kind fi_line status_line; do
            [ -n "${fi_line}" ] || continue
            if [ "${kind}" = neg ]; then
                viol+=("${path}:${status_line}: reads \$? inside 'if ! CMD; then' (line ${fi_line}); that \$? is the negation's 0, not CMD's status -- use 'CMD || rc=\$?' or _ci_capture, or mark '# if-status-safe: <reason>'")
                continue
            fi
            viol+=("${path}:${status_line}: reads \$? after an else-less if (fi at line ${fi_line}); POSIX reports the if's own status 0, not the command's -- use 'if CMD; then STATUS=0; else STATUS=\$?; fi' or mark '# if-status-safe: <reason>'")
        done < <(awk '
            { lines[NR] = $0 }
            END {
              depth = 0; nc = 0
              for (i = 1; i <= NR; i++) {
                stripped = lines[i]; sub(/#.*/, "", stripped)
                n = split(stripped, toks, /[ \t;]+/)
                for (k = 1; k <= n; k++) {
                  t = toks[k]
                  if (t == "if") { depth++; has_else[depth] = 0 }
                  else if (t == "elif" || t == "else") { if (depth > 0) has_else[depth] = 1 }
                  else if (t == "fi") { if (depth > 0) { if (has_else[depth] == 0) { nc++; fic[nc] = i } depth-- } }
                }
              }
              for (c = 1; c <= nc; c++) {
                fi_i = fic[c]; checked = 0
                for (j = fi_i + 1; j <= NR && checked < 6; j++) {
                  nxt = lines[j]
                  if (nxt ~ /^[ \t]*$/) continue
                  ns = nxt; sub(/^[ \t]*/, "", ns)
                  if (ns ~ /^#/) { checked++; continue }
                  checked++
                  pre = substr(nxt, 1, index(nxt, "$?") - 1)
                  if (nxt ~ /\$\?/ && pre !~ /(\||&|;)/ && nxt !~ /#[ \t]*if-status-safe:/) printf "fi:%d:%d\n", fi_i, j
                  break
                }
              }
              for (i = 1; i <= NR; i++) {
                s0 = lines[i]; sub(/#.*/, "", s0)
                if (s0 !~ /(^|[;&|[:space:]])if[[:space:]]+![[:space:]]/) continue
                if (s0 ~ /then[[:space:]]*$/) {
                  for (j = i + 1; j <= NR && j <= i + 6; j++) {
                    nxt = lines[j]
                    if (nxt ~ /^[ \t]*$/ || nxt ~ /^[ \t]*#/) continue
                    if (nxt ~ /\$\?/ && nxt !~ /#[ \t]*if-status-safe:/) printf "neg:%d:%d\n", i, j
                    break
                  }
                } else if (s0 ~ /then/) {
                  rest = s0; sub(/.*then/, "", rest)
                  if (rest ~ /\$\?/ && lines[i] !~ /#[ \t]*if-status-safe:/) printf "neg:%d:%d\n", i, i
                }
              }
            }
          ' "${path}")
        _ci_procsub_ok "$!" 0 || return 2
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0065]" "reason=\"\$? read after else-less if masks status (AG-VAL-029)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'if-without-else-status=clean files=%s\n' "${#files[@]}"
}

# What: flag heredoc-fed docker run missing -i
# Why: unattached stdin runs nothing (AG-VAL-029)
# From: Issue #1683 | PR #1858
_ci_check_docker_run_heredoc_stdin() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/**/*.yml' '.github/actions/**/*.yaml' || return 2
    local path lineno matched trimmed start window last_off invocation
    local -a viol=()
    for path in "${files[@]}"; do
        while IFS=: read -r lineno _rest; do
            [ -n "${lineno}" ] || continue
            matched="$(sed -n "${lineno}p" "${path}")"
            trimmed="${matched#"${matched%%[![:space:]]*}"}"
            case "${trimmed}" in '#'*) continue ;; esac
            start=$(( lineno > 20 ? lineno - 20 : 1 ))
            window="$(sed -n "${start},${lineno}p" "${path}")"
            last_off="$(printf '%s\n' "${window}" | grep -n 'docker run' | tail -1 | cut -d: -f1)"
            [ -n "${last_off}" ] || continue
            invocation="$(printf '%s\n' "${window}" | tail -n +"${last_off}")"
            grep -qE '(^|[[:space:]])-i([[:space:]]|$)' <<<"${invocation}" && continue
            viol+=("${path}:${lineno}: heredoc-fed 'docker run' (bash -s / sh -s) missing -i; container stdin never attaches so the heredoc runs nothing while the step reports success")
        done < <(grep -noE '(bash|sh)[[:space:]]+-s[[:space:]]*<<' "${path}")
        _ci_procsub_ok "$!" 1 || return 2
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0066]" "reason=\"heredoc docker run missing -i; stdin unattached (AG-VAL-029)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'docker-run-heredoc-stdin=clean files=%s\n' "${#files[@]}"
}

# What: setup.sh wizard prompts vs expect-sim staleness.
# Why: unanswered prompt hangs sim to timeout.
# From: Issue #1176 | PR #1858
_ci_setup_wizard_rows() {
    # What: emit ask/confirm prompts from setup wizard
    # Why: parse wizard rows for prompt/expect drift checks
    local setup="$1" cs_line esac_line wiz_start
    cs_line="$(_ci_capture 1 grep -n -m1 '^case "${1:-install}" in$' "${setup}")" || return 2
    cs_line="${cs_line%%:*}"
    [ -n "${cs_line}" ] || return 3
    esac_line="$(awk -v s="${cs_line}" 'NR>s && /^esac$/{print NR; exit}' "${setup}")"
    [ -n "${esac_line}" ] || return 3
    wiz_start=$((esac_line + 1))
    tail -n "+${wiz_start}" "${setup}" | awk '
        {
            t=$0; sub(/^[ \t]+/,"",t)
            if(t==""){ next }
            prompt=""; rest=""
            if(index(t,"ask \"")>0){ rest=substr(t,index(t,"ask \"")+5) }
            else if(index(t,"confirm \"")>0){ rest=substr(t,index(t,"confirm \"")+9) }
            if(rest!=""){ prompt=rest; sub(/".*/,"",prompt) }
            if(prompt!="" && substr(prompt,1,1)!="$"){
                ap=rest; sub(/^[^"]*"/,"",ap)                 # drop prompt + its closing quote
                if(index(ap,"\"")>0){
                    def=ap; sub(/^[^"]*"/,"",def); sub(/".*/,"",def)   # second quoted arg
                    flag="UNCOND"
                    for(i=1;i<=depth;i++){ if(stack[i]=="if"||stack[i]=="case"){ flag="COND"; break } }
                    printf "%s\t%s\t%s [%s]: \n", flag, prompt, prompt, def
                }
            }
            kw=t; sub(/[ \t].*/,"",kw)
            if(kw=="if"){ stack[++depth]="if" }
            else if(kw=="fi"){ if(depth>0)depth-- }
            else if(kw=="while"||kw=="until"||kw=="for"||kw=="select"){ stack[++depth]="loop" }
            else if(kw=="done"){ if(depth>0)depth-- }
            else if(kw=="case"){ stack[++depth]="case" }
            else if(kw=="esac"){ if(depth>0)depth-- }
        }
    '
}
_ci_check_setup_prompt_drift() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}"
    local setup="${repo_root}/setup.sh"
    if [ ! -f "${setup}" ]; then
        ci_log "[CI-ERROR-CHECK-0067]" "path=\"${setup}\" reason=\"setup.sh not found\""
        return 2
    fi
    local anchor_count
    anchor_count="$(_ci_capture 1 grep -c '^case "${1:-install}" in$' "${setup}")" || return 2
    if [ "${anchor_count}" -ne 1 ]; then
        ci_error "[CI-ERROR-CHECK-0081]" "reason=\"setup.sh dispatch case anchor not unique\""
        return 1
    fi
    local -a sims=(
        "${repo_root}/scripts/untracked/simulations/setup-cli-simulation.sh"
    )
    local -a rows=() all_prompts=() uncond=() viol=()
    local r
    while IFS= read -r r; do [ -n "${r}" ] && rows+=("${r}"); done < <(_ci_setup_wizard_rows "${setup}")
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#rows[@]}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0082]" "reason=\"zero ask/confirm prompts in setup.sh wizard; vacuous\""
        return 1
    fi
    while IFS= read -r r; do [ -n "${r}" ] && all_prompts+=("${r}"); done < <(printf '%s\n' "${rows[@]}" | cut -f3 | sort -u)
    _ci_procsub_ok "$!" 0 || return 2
    while IFS= read -r r; do [ -n "${r}" ] && uncond+=("${r}"); done < <(printf '%s\n' "${rows[@]}" | awk -F'\t' '$1=="UNCOND"{print $2"\t"$3}' | sort -u)
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#uncond[@]}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0083]" "reason=\"zero unconditional prompts in setup.sh wizard; vacuous\""
        return 1
    fi
    local sim pair prompt haystack tcl gpat covered matched checked=0 introspected=0
    local -a sim_pats=() gpats=()
    for sim in "${sims[@]}"; do
        [ -f "${sim}" ] || { viol+=("expected simulation script not found: ${sim}"); continue; }
        # What: introspection-driven sims use list-prompts
        # Why: no hand-encoded patterns needed here
        local introspect
        introspect="$(_ci_capture 1 grep -F 'build_expect_prompt_block' "${sim}")" || return 2
        if [ -n "${introspect}" ]; then
            grep -qF 'spawn bash setup.sh' "${sim}" || viol+=("${sim}: introspection-driven but no 'spawn bash setup.sh'")
            introspected=$((introspected + 1))
            continue
        fi
        checked=$((checked + 1))
        sim_pats=(); gpats=()
        while IFS= read -r r; do [ -n "${r}" ] && sim_pats+=("${r}"); done < <(
            awk '{ t=$0; sub(/^[ \t]+/,"",t); if(index(t,"expect_prompt {")==1){ x=substr(t,length("expect_prompt {")+1); sub(/}.*/,"",x); if(x!="")print x } }' "${sim}")
        _ci_procsub_ok "$!" 0 || return 2
        if [ "${#sim_pats[@]}" -eq 0 ]; then
            viol+=("${sim}: zero expect_prompt patterns; vacuous or no longer drives the wizard")
            continue
        fi
        for tcl in "${sim_pats[@]}"; do gpats+=("$(printf '%s' "${tcl}" | sed 's/\[\^\\n\]/./g')"); done
        # What: check if sim covers unconditional prompts
        # Why: hang-to-timeout on unanswered prompt
        for pair in "${uncond[@]}"; do
            prompt="${pair%%$'\t'*}"; haystack="${pair#*$'\t'}"; covered=0
            for gpat in "${gpats[@]}"; do grep -Eq -- "${gpat}" <<<"${haystack}" && { covered=1; break; }; done
            [ "${covered}" -eq 0 ] && viol+=("${sim}: no expect_prompt matches setup.sh unconditional prompt '${prompt}' (#1082/#1175: would hang to timeout)")
        done
        # What: detect stale pattern-matches
        # Why: patterns must match current prompts
        for tcl in "${gpats[@]}"; do
            matched=0
            for haystack in "${all_prompts[@]}"; do grep -Eq -- "${tcl}" <<<"${haystack}" && { matched=1; break; }; done
            [ "${matched}" -eq 0 ] && viol+=("${sim}: expect_prompt pattern '${tcl}' matches no current setup.sh prompt (stale)")
        done
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0084]" "reason=\"setup.sh/simulation prompt drift (#1176)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-prompt-drift=clean sims_checked=%s introspected=%s uncond=%s\n' \
        "${checked}" "${introspected}" "${#uncond[@]}"
}

# What: Check a PR title's Conventional-Commit form.
# Why: SOT pr_policy + targets own the type/scope sets.
# From: Issue #1683 | PR #1858
_ci_check_pr_title() {
    local title="${1:-${PR_TITLE:-}}"
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        printf 'pr-title=skip-dependabot\n'; return 0
    fi
    if [ -z "${title}" ]; then
        ci_log "[CI-ERROR-CHECK-0012]" "reason=\"no PR title given\""; return 2
    fi
    local types scopes
    types="$(_ci_block_entry_list pr_policy "" title_types)"
    if [ -z "${types}" ]; then
        ci_log "[CI-ERROR-CHECK-0085]" "reason=\"no SOT pr_policy.title_types; FAIL CLOSED\""; return 2
    fi
    scopes="$(ci_build_targets; _ci_block_keys external_services; _ci_block_entry_list pr_policy "" title_scopes_extra)"
    types="${types//$'\n'/ }"
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
    if [ "${#errs[@]}" -eq 0 ]; then
        printf 'pr-title=ok\n'
        return 0
    fi
    # What: AG-GH-018: draft PRs get only a soft warning.
    # Why: draft titles are expected to settle before ready.
    # From: Issue #1683 | PR #1858
    if [ "${PR_DRAFT:-false}" = "true" ]; then
        ci_log "[CI-ERROR-CHECK-0013]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${errs[@]}")\""
        printf 'pr-title=warn-draft\n'
        return 0
    fi
    # What: PR_TITLE_LINT_MODE picks warn vs block mode.
    # Why: warn is the required default; block is opt-in.
    # From: Issue #1683 | PR #1858
    if [ "${PR_TITLE_LINT_MODE:-warn}" != "block" ]; then
        ci_log "[CI-ERROR-CHECK-0086]" "reason=\"warn-mode, non-blocking; must fix before merge\" detail=\"$(printf '%s; ' "${errs[@]}")\""
        printf 'pr-title=warn\n'
        return 0
    fi
    ci_error "[CI-ERROR-CHECK-0087]" "reason=\"PR title convention\"" "$(printf '%s\n' "${errs[@]}")"
    return 1
}

# What: External deploy images must be digest-pinned + SOT.
# Why: A floating external tag breaks reproducibility.
# From: Issue #1683
_ci_check_stable_external_images() {
    local -a dirs=("$@")
    local d line img k allowed=" " tagged=" " dep inst
    if [ "${#dirs[@]}" -eq 0 ]; then
        dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
        inst="$(_ci_installer_compose)" || return 2
        dirs=("${CI_REPO_ROOT}/$(dirname "${dep}")" "${CI_REPO_ROOT}/$(dirname "${inst}")")
    fi
    local -a viol=()
    # What: the exact SOT pins (external services + bases).
    # Why: compose must match them; other values are drift.
    # From: Issue #1683 | PR #1858
    for k in $(_ci_block_keys external_services); do
        img="$(_ci_block_entry_field external_services "${k}" image)"
        allowed+="${img} "
        # What: a SOT tag-latest entry may skip the digest.
        # Why: only an explicit SOT policy, never a guess.
        # From: Issue #1683 | PR #1858
        [ "$(_ci_block_entry_field external_services "${k}" policy)" = tag-latest ] && tagged+="${img} "
    done
    for k in $(_ci_block_keys base_images all); do
        allowed+="$(_ci_block_entry_field base_images "" "${k}") "
    done
    for d in "${dirs[@]}"; do
        if [ ! -d "${d}" ]; then
            viol+=("${d}: compose dir missing")
            continue
        fi
        while IFS= read -r line; do
            img="${line#*image:}"; img="${img#"${img%%[![:space:]]*}"}"
            # What: only ${LANCACHE_*} own images skip.
            # Why: any literal host (ghcr too) is pinned.
            # From: Issue #1683 | PR #1858
            case "${img}" in
                *'${LANCACHE'*|'') continue ;;
            esac
            img="${img%\"}"; img="${img#\"}"
            case "${tagged}" in
                *" ${img} "*) continue ;;
            esac
            case "${img}" in
                *@sha256:*) ;;
                *) viol+=("${d}: external not digest-pinned: ${img}"); continue ;;
            esac
            case "${allowed}" in
                *" ${img} "*) ;;
                *) viol+=("${d}: external pin is not a SOT pin: ${img}") ;;
            esac
        done < <(grep -rhE '^[[:space:]]+image:[[:space:]]' "${d}")
        _ci_procsub_ok "$!" 1 || return 2
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0014]" "reason=\"external image not digest-pinned or not in SOT\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'stable-external-images=clean\n'
}

# What: PR body must fill every template section.
# Why: CONTRIBUTING.md requires all headings completed.
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
        # What: strip HTML comments and code fence markers
        # Why: detect empty vs placeholder-only sections
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
            ci_log "[CI-ERROR-CHECK-0088]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${missing[@]}")\""
            printf 'pr-template=warn-draft\n'; return 0
        fi
        ci_error "[CI-ERROR-CHECK-0089]" "reason=\"missing/empty required section(s)\"" "$(printf '%s\n' "${missing[@]}")"
        return 1
    fi
    printf 'pr-template=ok\n'
}

# What: Enforce workflow file/byte and run-block limits.
# Why: GitHub drops >~9000 lines; actionlint >~75KB.
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
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0090]" "reason=\"workflow size ceiling exceeded\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'workflow-line-limit=clean\n'
}

# What: PR must carry label, milestone, project (AG-GH-008).
# Why: CI is the mechanical owner of that metadata rule.
# From: Issue #1683
_ci_check_pr_tracking_metadata() {
    local pr_number="${PR_NUMBER:-}" repo project_number project_owner
    if [ -z "${pr_number}" ]; then
        ci_log "[CI-ERROR-CHECK-0017]" "reason=\"PR_NUMBER is required\""
        return 2
    fi
    repo="$(_ci_repo)" || return 2
    # What: SOT board number; owner is the repo owner.
    # Why: one CI policy owner (AG-GH-008), no literal.
    # From: Issue #1683 | PR #1858
    project_number="$(_ci_block_entry_field pr_policy "" project_number)"
    project_owner="${repo%%/*}"
    if ! [[ "${project_number}" =~ ^[0-9]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0091]" "reason=\"no numeric SOT pr_policy.project_number\""
        return 2
    fi
    local -a errs=() warns=()
    local label_count
    # What: unset input is wiring, empty is PR gap
    # Why: avoid false PR metadata failures
    # From: Issue #1683 | PR #1858
    if [ -z "${PR_LABELS_JSON+x}" ]; then
        errs+=("PR labels not provided to the check (workflow wiring).")
    else
        if ! label_count="$(jq -e 'length' <<<"${PR_LABELS_JSON}")"; then
            errs+=("PR labels input is not a JSON array.")
        elif [ "${label_count}" -eq 0 ]; then
            errs+=("No labels set (AG-GH-008).")
        fi
    fi
    if [ -z "${PR_MILESTONE_TITLE+x}" ]; then
        errs+=("PR milestone not provided to the check (workflow wiring).")
    elif [ -z "${PR_MILESTONE_TITLE}" ]; then
        errs+=("No milestone set (AG-GH-008).")
    fi
    if [ -z "${GH_TOKEN:-}" ]; then
        if [ "${PR_IS_FORK:-false}" = "true" ]; then
            warns+=("Project-board not checked: fork PRs get no repo secrets.")
        else
            warns+=("Project-board not checked: no read:project token (GH_TOKEN unset).")
        fi
    else
        # What: board lookup: gh api graphql via _ci_retry.
        # Why: a set token that fails must fail (AG-GH-008).
        # From: Issue #1683 | PR #1858
        local response rc=0 project_item_count
        response="$(_ci_retry github-api gh api graphql -f owner="${project_owner}" \
            -f repo="${repo#*/}" -F pr="${pr_number}" -f query='query($owner: String!, $pr: Int!, $repo: String!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { projectItems(first: 10) { nodes { project { number } } } } } }')" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            errs+=("Project-board lookup failed: ${response##*$'\n'}")
        elif ! project_item_count="$(jq -er --argjson pn "${project_number}" \
            '[.data.repository.pullRequest.projectItems.nodes[] | select(.project.number == $pn)] | length' \
            <<<"${response}")"; then
            errs+=("Could not parse project-board membership response.")
        elif [ "${project_item_count}" -eq 0 ]; then
            errs+=("Not on project board #${project_number} (${project_owner}).")
        fi
    fi
    local w
    for w in "${warns[@]:-}"; do [ -n "${w}" ] && ci_log "[CI-ERROR-CHECK-0017]" "warn=\"${w}\""; done
    if [ "${#errs[@]}" -gt 0 ]; then
        if [ "${PR_DRAFT:-false}" = "true" ]; then
            ci_log "[CI-ERROR-CHECK-0092]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${errs[@]}")\""
            printf 'pr-tracking-metadata=warn-draft\n'; return 0
        fi
        ci_error "[CI-ERROR-CHECK-0093]" "reason=\"AG-GH-008 metadata incomplete\"" "$(printf '%s\n' "${errs[@]}")"
        return 1
    fi
    printf 'pr-tracking-metadata=ok\n'
}

# What: Node runtimes GitHub Actions has retired.
# Why: a pin on an EoL runtime breaks once GitHub drops it.
# From: Issue #1683 | PR #1858
_ci_action_deprecated_runtimes=" node6 node10 node12 node16 node20 "

# What: print top-level runs.using from an action manifest.
# Why: one parser for local + API-fetched action.yml bodies.
# From: Issue #1683 | PR #1858
_ci_action_runs_using() {
    awk '
        /^runs:/ { in_runs = 1; next }
        in_runs && /^[^[:space:]]/ { exit }
        in_runs && /^[[:space:]]*using:/ { print; exit }
    ' | sed -E "s/.*using:[[:space:]]*//; s/[\"']//g; s/[[:space:]]*#.*\$//; s/[[:space:]]+\$//"
}

# What: resolve external action manifest for pin.
# Why: one gh api + _ci_retry owner; no own HTTP client.
# From: Issue #1683 | PR #1858
_ci_fetch_action_manifest() {
    local owner="$1" repo="$2" subpath="$3" ref="$4"
    # What: caller resolver overrides API path.
    # Why: tests assert OK/NOTFOUND/INFRA, not the API.
    # From: Issue #1683 | PR #1858
    if [ -n "${CI_ACTION_MANIFEST_CMD:-}" ]; then
        "${CI_ACTION_MANIFEST_CMD}" "${owner}" "${repo}" "${subpath}" "${ref}"
        return
    fi
    local dir="repos/${owner}/${repo}/contents${subpath:+/${subpath}}" names out file rc=0
    # What: list the dir once, then fetch the manifest name.
    # Why: a 404 on the dir is a broken pin, not infra.
    # From: Issue #1683 | PR #1858
    names="$(_ci_retry github-api gh api "${dir}?ref=${ref}" --jq '.[].name')" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        case "${names,,}" in *"http 404"*) printf 'NOTFOUND\n' ;; *) printf 'INFRA\n' ;; esac
        return 0
    fi
    for file in action.yml action.yaml; do
        grep -qx -- "${file}" <<< "${names}" || continue
        out="$(_ci_retry github-api gh api -H 'Accept: application/vnd.github.raw+json' \
            "${dir}/${file}?ref=${ref}")" || { printf 'INFRA\n'; return 0; }
        printf 'OK\n%s\n' "${out}"; return 0
    done
    printf 'NOTFOUND\n'
}

# What: true if a uses: ref is an external pinned action.
# Why: local, docker, and same-repo refs skip the API path.
# From: Issue #1683 | PR #1858
_ci_action_ref_is_external() {
    local v="$1"
    case "${v}" in
        *@*) ;; *) return 1 ;;
    esac
    case "${v}" in
        ./*|\$/*|docker://*) return 1 ;;
    esac
    # What: this repo's own actions are no third-party pins.
    # Why: owner/repo comes from the run, never hardcoded.
    # From: Issue #1683 | PR #1858
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        case "${v,,}" in "${GITHUB_REPOSITORY,,}"/*) return 1 ;; esac
    fi
    return 0
}

# What: enforce Node runtime + ref hygiene on pins.
# Why: single owner of action-pin policy.
# From: Issue #1683 | PR #1858
_ci_check_action_node_versions() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}"
    local wf_dir="${repo_root}/.github/workflows" act_dir="${repo_root}/.github/actions"
    local -a wf_files=() act_files=() scan_files=()
    local f
    for f in "${wf_dir}"/*.yml "${wf_dir}"/*.yaml; do [ -f "${f}" ] && wf_files+=("${f}"); done
    for f in "${act_dir}"/*/action.yml "${act_dir}"/*/action.yaml; do [ -f "${f}" ] && act_files+=("${f}"); done
    if [ "${#wf_files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0053]" "reason=\"no workflow files under ${wf_dir}\""; return 2
    fi
    scan_files=("${wf_files[@]}" "${act_files[@]}")

    local -a viol=() xv=() infra=() uses_entries=() literal_entries=()
    # What: collect every uses: step, resolve anchors.
    # Why: alias not duplicate; only literals count.
    # From: Issue #1683 | PR #1858
    local sf line raw resolved anchor
    for sf in "${scan_files[@]}"; do
        local -A anchors=()
        while IFS= read -r line; do
            raw="$(sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' <<<"${line}")"
            resolved="${raw}"
            if [[ "${raw}" =~ ^\&([A-Za-z0-9_-]+)[[:space:]]+(.+)$ ]]; then
                anchor="${BASH_REMATCH[1]}"; resolved="${BASH_REMATCH[2]}"
                anchors["${anchor}"]="${resolved}"
                literal_entries+=("${sf}"$'\t'"${resolved}")
            elif [[ "${raw}" =~ ^\*([A-Za-z0-9_-]+)$ ]]; then
                anchor="${BASH_REMATCH[1]}"
                if [ -z "${anchors[${anchor}]+x}" ]; then
                    xv+=("${sf}: unresolved YAML alias '*${anchor}' in a uses: step")
                    continue
                fi
                resolved="${anchors[${anchor}]}"
            else
                literal_entries+=("${sf}"$'\t'"${resolved}")
            fi
            uses_entries+=("${sf}"$'\t'"${resolved}")
        done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "${sf}")
        _ci_procsub_ok "$!" 1 || return 2
        unset anchors
    done

    local -a uses_values=()
    mapfile -t uses_values < <(printf '%s\n' "${uses_entries[@]}" | sed $'s/^[^\t]*\t//' | sort -u)
    # What: no uses: AND no fail is vacuous.
    # Why: unresolved alias is extraction fault.
    # From: Issue #1683 | PR #1858
    if { [ "${#uses_values[@]}" -eq 0 ] || { [ "${#uses_values[@]}" -eq 1 ] && [ -z "${uses_values[0]}" ]; }; } && [ "${#xv[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0094]" "reason=\"no uses: steps extracted; scan vacuous\""; return 2
    fi

    # What: names the files a resolved ref appears in.
    # Why: violation messages point at the real call sites.
    # From: Issue #1683 | PR #1858
    _ci_ando_reffiles() {
        local needle="$1" e file val; local -a m=()
        for e in "${uses_entries[@]}"; do
            file="${e%%$'\t'*}"; val="${e#*$'\t'}"
            [ "${val}" = "${needle}" ] || continue
            case " ${m[*]} " in *" ${file} "*) ;; *) m+=("${file}") ;; esac
        done
        [ "${#m[@]}" -eq 0 ] && { printf '<none>'; return; }
        printf '%s' "${m[*]}"
    }

    # What: per-file literal ref counts + per-key ref drift.
    # Why: a repeated literal or split ref both fail closed.
    # From: Issue #1683 | PR #1858
    local -A file_ref_count=() key_refs=()
    local e file val key ref
    for e in "${literal_entries[@]}"; do
        file="${e%%$'\t'*}"; val="${e#*$'\t'}"
        _ci_action_ref_is_external "${val}" || continue
        case "${file}" in
            "${wf_dir}"/*)
                key="${file}"$'\t'"${val}"
                file_ref_count["${key}"]=$(( ${file_ref_count["${key}"]:-0} + 1 )) ;;
        esac
        key="${val%@*}"; ref="${val##*@}"
        case " ${key_refs[${key}]:-} " in
            *" ${ref} "*) ;;
            *) key_refs["${key}"]="${key_refs[${key}]:-} ${ref}" ;;
        esac
    done
    for key in "${!file_ref_count[@]}"; do
        [ "${file_ref_count[${key}]}" -le 1 ] && continue
        viol+=("${key%%$'\t'*}: repeats third-party ref '${key#*$'\t'}' ${file_ref_count[${key}]}x; collapse via a YAML anchor")
    done
    for key in "${!key_refs[@]}"; do
        local -a refs=()
        read -ra refs <<< "${key_refs[${key}]}"
        [ "${#refs[@]}" -le 1 ] && continue
        viol+=("third-party action '${key}' is pinned to multiple refs across .github/**: ${key_refs[${key}]# }; keep one canonical ref")
    done

    # What: fail expression in composite description.
    # Why: manifest validator evaluates description.
    # From: Issue #1683 | PR #1858
    local af hits hl
    for af in "${act_files[@]}"; do
        hits="$(awk '
            in_block {
                if ($0 ~ /^[[:space:]]*$/) { next }
                match($0, /^[[:space:]]*/)
                if (RLENGTH > bi) { if (index($0,"${{")>0 || index($0,"}}")>0) print NR; next }
                in_block = 0
            }
            /^[[:space:]]*description[[:space:]]*:/ {
                match($0, /^[[:space:]]*/); bi = RLENGTH
                rest = $0; sub(/^[[:space:]]*description[[:space:]]*:[[:space:]]*/, "", rest)
                if (rest ~ /^[>|]/) { in_block = 1; next }
                if (index(rest,"${{")>0 || index(rest,"}}")>0) print NR
            }' "${af}")"
        [ -z "${hits}" ] && continue
        while IFS= read -r hl; do
            [ -n "${hl}" ] && viol+=("${af} line ${hl}: description: field contains \${{ }} expression syntax; the manifest validator evaluates it and the action fails to load")
        done <<< "${hits}"
    done

    # What: check each pin's runs.using for dead runtime.
    # Why: local reads disk; external via API.
    # From: Issue #1683 | PR #1858
    local v using local_dir cand resolved_file owner repo subpath ref res marker meta
    for v in "${uses_values[@]}"; do
        [ -n "${v}" ] || continue
        if [[ "${v}" == ./* ]]; then
            case "${v}" in *.yml|*.yaml) continue ;; esac
            local_dir="${repo_root}/${v#./}"
            resolved_file=""
            for cand in "${local_dir}/action.yml" "${local_dir}/action.yaml"; do
                [ -f "${cand}" ] && { resolved_file="${cand}"; break; }
            done
            if [ -z "${resolved_file}" ]; then
                viol+=("local action '${v}' (in: $(_ci_ando_reffiles "${v}")) has no action.yml/action.yaml"); continue
            fi
            using="$(_ci_action_runs_using < "${resolved_file}")"
            [ -z "${using}" ] && { viol+=("local action '${v}' has no parseable runs.using"); continue; }
            case "${_ci_action_deprecated_runtimes}" in
                *" ${using} "*) viol+=("local action '${v}' declares runs.using: ${using}, a deprecated Node runtime") ;;
            esac
            continue
        fi
        _ci_action_ref_is_external "${v}" || continue
        ref="${v##*@}"; key="${v%@*}"
        owner="$(cut -d/ -f1 <<<"${key}")"; repo="$(cut -d/ -f2 <<<"${key}")"; subpath="$(cut -d/ -f3- <<<"${key}")"
        res="$(_ci_fetch_action_manifest "${owner}" "${repo}" "${subpath}" "${ref}")" || return 2
        marker="${res%%$'\n'*}"
        case "${marker}" in
            OK)
                meta="${res#*$'\n'}"
                using="$(_ci_action_runs_using <<<"${meta}")"
                if [ -z "${using}" ]; then
                    viol+=("'${v}' has no parseable runs.using")
                elif case "${_ci_action_deprecated_runtimes}" in *" ${using} "*) true ;; *) false ;; esac; then
                    viol+=("'${v}' (in: $(_ci_ando_reffiles "${v}")) declares runs.using: ${using}, a deprecated Node runtime")
                fi ;;
            NOTFOUND)
                viol+=("no action.yml/action.yaml for '${v}' at ref '${ref}' (in: $(_ci_ando_reffiles "${v}")); broken pin") ;;
            *)
                infra+=("${v}") ;;
        esac
    done
    unset -f _ci_ando_reffiles
    # What: an unresolved pin fails closed, never clean.
    # Why: an unverified runtime must not pass the gate.
    # From: Issue #1683 | PR #1858
    if [ "${#infra[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0073]" "reason=\"action manifest unresolved after retries; FAIL CLOSED\"" "$(printf '%s\n' "${infra[@]}")"
        return 2
    fi

    # What: extraction faults reported apart from pin.
    # Why: parse gap not deprecated-runtime fail.
    # From: Issue #1683 | PR #1858
    if [ "${#xv[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0054]" "reason=\"uses: extraction failure (unresolved alias / unparseable step)\"" "$(printf '%s\n' "${xv[@]}")"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0095]" "reason=\"deprecated runtime / ref drift / description expression (issue #799/#1095)\"" "$(printf '%s\n' "${viol[@]}")"
    fi
    if [ "${#xv[@]}" -gt 0 ] || [ "${#viol[@]}" -gt 0 ]; then
        return 1
    fi
    printf 'action-node-versions=clean pins=%s\n' "${#uses_values[@]}"
}

# What: Resolve GitHub issue state; failure returns 2.
# Why: an unknown state must not hide a stale TODO.
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
    local state repo
    repo="$(_ci_repo)" || return 2
    state="$(_ci_retry github-api gh api "repos/${repo}/issues/${issue}" --jq '.state')" || return 2
    case "${state}" in
        open|closed) printf '%s\n' "${state}" ;;
        *) ci_log "[CI-ERROR-CHECK-0074]" "issue=\"${issue}\" state=\"${state}\" reason=\"unexpected issue state\""; return 2 ;;
    esac
}

# What: Flag stale TODOs, scope gaps, upload errors.
# Why: Guard changed files against title/body governance.
# From: Issue #1683
_ci_check_governance_guards() {
    local -a _ci_override=("$@") changed=()
    local title="${GOVERNANCE_PR_TITLE:-${PR_TITLE:-}}" body="${GOVERNANCE_PR_BODY:-${PR_BODY:-}}"
    local -a viol=()
    local path line marker issue state hits grc
    if [ "$#" -gt 0 ]; then
        _ci_scan_files changed _ci_override || return 2
    fi
    for path in "${changed[@]}"; do
        case "${path}" in *.md|*.mdx|*.rst|*.txt) continue ;; esac
        # What: grep rc 1 means no marker; rc 2 is an error.
        # Why: a read error must not pass as a clean file.
        # From: Issue #1683
        hits="$(_ci_capture 1 grep -nEo '(TODO|FIXME)\(#([0-9]+)\)' "${path}")" || return 2
        while IFS= read -r marker; do
            [ -n "${marker}" ] || continue
            line="${marker%%:*}"; marker="${marker#*:}"
            issue="${marker##*#}"; issue="${issue%)*}"
            [[ "${issue}" =~ ^[0-9]+$ ]] || continue
            state="$(_ci_governance_issue_state "${issue}")" || return 2
            [ "${state}" = "closed" ] && viol+=("${path}:${line}: stale TODO/FIXME references closed #${issue}")
        done <<< "${hits}"
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
            local open_found=0 rest="${combined}"
            while [[ "${rest}" =~ Refs[[:space:]]+#([0-9]+) ]]; do
                issue="${BASH_REMATCH[1]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
                state="$(_ci_governance_issue_state "${issue}")" || return 2
                [ "${state}" = "open" ] && { open_found=1; break; }
            done
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

# What: Container names stay in lockstep repo-wide.
# Why: Socket-proxy allowlist gates Docker-API access.
# From: Issue #1683
_ci_check_naming_consistency() {
    local root="${1:-${CI_REPO_ROOT}}" dep inst
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${root}")" || return 2
    local -a compose_files=("${root}/${dep}" "${root}/${inst}")
    local proxy_sh="${root}/scripts/untracked/docker-socket-proxy.sh"
    local docker_client_rs="${root}/services/ui/src/docker_client.rs"
    local watchdog_rs="${root}/services/watchdog/src/config.rs"
    local ui_config_rs="${root}/services/ui/src/config.rs"
    local -a viol=()
    local cf

    for cf in "${compose_files[@]}"; do
        if [ ! -f "${cf}" ]; then
            viol+=("${cf}: compose file missing")
            continue
        fi
        grep -Eq '^name: lancache-ng$' "${cf}" || viol+=("${cf}: missing 'name: lancache-ng'")
    done

    if [ ! -f "${proxy_sh}" ]; then
        ci_error "[CI-ERROR-CHECK-0019]" "reason=\"docker-socket-proxy.sh not found\"" "${proxy_sh}"
        return 2
    fi
    local allowlist_line allowlist_group allowlist_names
    allowlist_line="$(_ci_capture 1 grep -F 'acl lancache_container' "${proxy_sh}")" || return 2
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
        # What: installer compose names carry the suffix.
        # Why: owner-derived; a path substring hid it.
        # From: Issue #1683 | PR #1858
        if [ "${cf}" = "${root}/${inst}" ]; then
            name_suffix='\$\{LANCACHE_CONTAINER_SUFFIX:-\}'
        fi
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            grep -Eq "^[[:space:]]+container_name: ${name}${name_suffix}\$" "${cf}" || \
                viol+=("${cf}: no container_name: ${name}${name_suffix}")
        done <<<"${allowlist_names}"
    done

    if [ -f "${docker_client_rs}" ]; then
        local dc_names name
        dc_names="$(_ci_capture 1 grep -oE '=> "lancache-[a-z0-9-]+"' "${docker_client_rs}")" || return 2
        dc_names="$(sed -E 's/^=> "(.*)"$/\1/' <<<"${dc_names}" | sort -u)"
        if [ -z "${dc_names}" ]; then
            viol+=("${docker_client_rs}: no '=> \"lancache-*\"' resolutions found")
        fi
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            _ci_name_in_allowlist "${name}" || viol+=("${docker_client_rs}: resolves '${name}' not in allowlist")
        done <<<"${dc_names}"
    fi

    if [ -f "${watchdog_rs}" ]; then
        local wd_names name
        wd_names="$(_ci_capture 1 grep -oE 'const [A-Z_]+: &str = "lancache-[a-z0-9-]+"' "${watchdog_rs}")" || return 2
        wd_names="$(sed -E 's/^.*"(lancache-[a-z0-9-]+)"$/\1/' <<<"${wd_names}" | sort -u)"
        if [ -z "${wd_names}" ]; then
            viol+=("${watchdog_rs}: no const lancache-* container names found")
        fi
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            _ci_name_in_allowlist "${name}" || viol+=("${watchdog_rs}: names '${name}' not in allowlist")
        done <<<"${wd_names}"
    fi

    local watchdog_acl
    watchdog_acl="$(_ci_capture 1 grep -Ei '^[[:space:]]*(acl|http-request)[[:space:]].*lancache-watchdog' "${proxy_sh}")" || return 2
    if [ -n "${watchdog_acl}" ]; then
        viol+=("${proxy_sh}: lancache-watchdog referenced in acl/http-request (issue #1486)")
    fi

    local verb_acls
    verb_acls="$(_ci_capture 1 grep -E '^[[:space:]]*acl[[:space:]]+[a-z_]+[[:space:]]+path,url_dec.*/\(?(start|stop|restart|wait)(\|(start|stop|restart|wait))*\)?\$' "${proxy_sh}")" || return 2
    verb_acls="$(awk '{print $2}' <<<"${verb_acls}")"
    if [ -z "${verb_acls}" ]; then
        viol+=("${proxy_sh}: no lifecycle-action (start/stop/restart/wait) acl found")
    fi
    local verb_acl verb_acl_line
    while IFS= read -r verb_acl; do
        [ -n "${verb_acl}" ] || continue
        verb_acl_line="$(_ci_capture 1 grep -F "acl ${verb_acl} " "${proxy_sh}")" || return 2
        if grep -qi 'lancache-\(watchdog\|syslog\)' <<<"${verb_acl_line}"; then
            viol+=("${proxy_sh}: '${verb_acl}' grants lifecycle action to watchdog/syslog (issue #1486)")
        fi
    done <<<"${verb_acls}"

    if [ -f "${ui_config_rs}" ]; then
        local -A service_defaults=(
            [DNS_STANDARD_SERVICE]=dns-standard [DNS_SSL_SERVICE]=dns-ssl
            [PROXY_SERVICE]=proxy [NATS_SERVICE]=nats
        )
        local var expected actual
        for var in "${!service_defaults[@]}"; do
            expected="${service_defaults[${var}]}"
            actual="$(_ci_capture 1 grep -oE "env_str\(\"${var}\", \"[a-z0-9-]+\"\)|env_or\(\"${var}\", \"[a-z0-9-]+\"" "${ui_config_rs}")" || return 2
            actual="$(sed -E 's/^.*, "([a-z0-9-]+)"\)?$/\1/' <<<"${actual}" | tail -n 1)"
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
        ci_error "[CI-ERROR-CHECK-0096]" "reason=\"naming-consistency drift (docs/naming-conventions.md)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'naming-consistency=clean\n'
}

# What: fail on compose service with no healthcheck.
# Why: every service needs a real healthcheck.
# From: Issue #1683 | PR #1858
_ci_check_compose_healthchecks() {
    local -a files=("$@")
    if [ "${#files[@]}" -eq 0 ]; then
        local f dep
        dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
        for f in "${CI_REPO_ROOT}/$(dirname "$(dirname "${dep}")")"/*/"$(basename "${dep}")"; do
            [ -f "${f}" ] && files+=("${f}")
        done
    fi
    if [ "${#files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0020]" "reason=\"no stack compose files found\""
        return 2
    fi
    # What: exemptions are per service, never per file path.
    # Why: the SOT owns the list; a path key duplicated it.
    # From: Issue #1683 | PR #1858
    local -A excluded=()
    local file svc hc checked=0 ex raw
    raw="$(_ci_block_entry_list validation "" healthcheck_exempt)" || return 2
    while IFS= read -r ex; do
        [ -n "${ex}" ] && excluded["${ex}"]=1
    done <<< "${raw}"
    local -a viol=()
    for file in "${files[@]}"; do
        [ -f "${file}" ] || continue
        while IFS=$'\t' read -r svc hc; do
            [ -n "${svc}" ] || continue
            checked=$((checked + 1))
            [ "${hc}" = "1" ] && continue
            [ -n "${excluded[${svc}]:-}" ] && continue
            viol+=("${file}: service '${svc}' has no healthcheck:")
        done < <(awk '
            /^services:[[:space:]]*$/ { insvc = 1; next }
            insvc && /^[A-Za-z]/ {
                if (name != "") print name "\t" hc
                insvc = 0; name = ""; next
            }
            insvc && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
                if (name != "") print name "\t" hc
                name = $1; sub(/:$/, "", name); hc = 0; next
            }
            insvc && name != "" && /^    healthcheck:[[:space:]]*$/ { hc = 1 }
            END { if (name != "") print name "\t" hc }
        ' "${file}")
        _ci_procsub_ok "$!" 0 || return 2
    done
    if [ "${checked}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0097]" "reason=\"no services found across deploy compose files\""
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0021]" "reason=\"service missing a healthcheck (issue #1169)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-healthchecks=clean checked=%s\n' "${checked}"
}

# What: Fail if a CACHE_* value drifts from its doc row.
# Why: a hand-copied doc default silently goes stale.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cache_env_doc_drift() {
    local proxy_env="${1:-}" dep raw
    local arch_doc="${2:-${CI_REPO_ROOT}/docs/architecture-ng.md}"
    if [ -z "${proxy_env}" ]; then
        # What: the env_file the deploy compose gives proxy.
        # Why: the compose owns the path; no ci.sh literal.
        # From: Issue #1683 | PR #1858
        dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
        if ! raw="$(_ci_compose_env_files "${CI_REPO_ROOT}/${dep}" proxy 2>&1)"; then
            ci_error "[CI-ERROR-CHECK-0110]" "reason=\"deploy compose unreadable for proxy env_file\"" "${raw}"
            return 2
        fi
        if [ -z "${raw}" ] || [ "$(wc -l <<< "${raw}")" -ne 1 ]; then
            ci_error "[CI-ERROR-CHECK-0111]" "reason=\"deploy compose proxy needs exactly one env_file\"" "${raw}"
            return 2
        fi
        proxy_env="${raw}"
    fi
    if [ ! -f "${proxy_env}" ]; then
        ci_log "[CI-ERROR-CHECK-0022]" "path=\"${proxy_env}\" reason=\"proxy.env not found\""
        return 2
    fi
    if [ ! -f "${arch_doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0098]" "path=\"${arch_doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    local key value doc_row documented scanned=0 checked=0 rc
    local -a viol=()
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^CACHE_[A-Z_]+$ ]] || continue
        scanned=$((scanned + 1))
        doc_row="$(_ci_capture 1 grep -E "^\| \`${key}\` \|" "${arch_doc}")" || return 2
        [ -n "${doc_row}" ] || continue
        checked=$((checked + 1))
        documented="$(sed -E "s/^\| \`[A-Z_]+\` \| \`([^\`]*)\` \|.*/\1/" <<<"${doc_row}")"
        if [ "${documented}" != "${value}" ]; then
            viol+=("${key}: proxy.env=${value} vs doc=${documented}")
        fi
    done < <(grep -E '^CACHE_[A-Z_]+=' "${proxy_env}")
    _ci_procsub_ok "$!" 1 || return 2
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0023]" "reason=\"proxy.env/doc CACHE_* default drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cache-env-doc-drift=clean scanned=%s checked=%s\n' "${scanned}" "${checked}"
}

# What: Emit "block\tdir" or "block\t@BLOCK@" per group.
# Why: dependabot.yml's own scalar/list forms, no yq dep.
# From: Issue #1683 | PR #1858
_ci_dependabot_docker_entries() {
    local file="$1"
    awk '
        function scalar(line,    value) {
            value = line
            sub(/^[^:]*:[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*$/, "", value)
            gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", value)
            return value
        }
        /^  - package-ecosystem:/ {
            ecosystem = tolower(scalar($0))
            in_docker = (ecosystem == "docker")
            if (in_docker) { block++; print block "\t@BLOCK@" }
            next
        }
        in_docker && /^    directory:/ {
            path = scalar($0)
            if (path ~ /^\//) print block "\t" path
            next
        }
        in_docker && /^    directories:[[:space:]]*\[/ {
            paths = $0
            sub(/^    directories:[[:space:]]*\[/, "", paths)
            sub(/\][[:space:]]*(#.*)?$/, "", paths)
            count = split(paths, entries, /,[[:space:]]*/)
            for (i = 1; i <= count; i++) {
                path = entries[i]
                gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", path)
                if (path ~ /^\//) print block "\t" path
            }
            next
        }
        in_docker && /^      - / {
            path = $0
            sub(/^      - /, "", path)
            sub(/[[:space:]]*#.*$/, "", path)
            gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", path)
            if (path ~ /^\//) print block "\t" path
        }
    ' "${file}"
}

# What: Print Dockerfile logical lines (joined).
# Why: AG-VAL-036: heredoc/escape= change what a line is.
# From: Issue #1683 | PR #1858
_ci_dockerfile_logical_lines() {
    awk '
        function emit_logical(    candidate, owner, marker) {
            print logical
            candidate = logical
            sub(/^[[:space:]]*/, "", candidate)
            owner = candidate
            sub(/[[:space:]].*$/, "", owner)
            if ((tolower(owner) == "run" || tolower(owner) == "copy") &&
                match(candidate, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
                marker = substr(candidate, RSTART, RLENGTH)
                sub(/^<<-?[[:space:]]*/, "", marker)
                gsub(/["'"'"']/, "", marker)
                heredoc = marker
            }
            logical = ""
        }
        heredoc != "" {
            candidate = $0
            sub(/^[[:space:]]*/, "", candidate)
            if (candidate == heredoc) heredoc = ""
            next
        }
        {
            physical = $0
            candidate = physical
            sub(/^[[:space:]]*/, "", candidate)
            if (!content_seen && candidate ~ /^#[[:space:]]*escape[[:space:]]*=/) {
                directive = candidate
                sub(/^#[[:space:]]*escape[[:space:]]*=[[:space:]]*/, "", directive)
                sub(/[[:space:]]*$/, "", directive)
                if (directive == "`" || directive == "\\") escape = directive
                print physical
                next
            }
            if (logical == "" && candidate ~ /^#/) { logical = physical; emit_logical(); next }
            if (candidate != "") content_seen = 1
            if (escape == "") escape = "\\"
            escaped = (escape == "\\" ? physical ~ /\\[[:space:]]*$/ : physical ~ /`[[:space:]]*$/)
            if (escaped) {
                if (escape == "\\") sub(/\\[[:space:]]*$/, "", physical)
                else sub(/`[[:space:]]*$/, "", physical)
                logical = logical physical " "
                next
            }
            logical = logical physical
            emit_logical()
        }
        END { if (logical != "") emit_logical() }
    ' "$1"
}

# What: Resolve <KEY>_IMAGE to SOT base_images.<key>.
# Why: same rule external_image uses; no per-image list.
# From: Issue #1683 | PR #1858
_ci_sot_base_image_arg() {
    local name="$1" val key
    case "${name}" in *_IMAGE) ;; *) return 1 ;; esac
    key="${name%_IMAGE}"
    val="$(_ci_block_entry_field base_images "" "${key,,}")"
    [ -n "${val}" ] || return 1
    printf '%s' "${val}"
}

# What: Print a Dockerfile's final resolved FROM image.
# Why: global ARG defaults + stage aliases change it.
# From: Issue #1683 | PR #1858
_ci_dockerfile_final_image() {
    local dockerfile="$1" line instruction remainder image alias name value token
    local seen_from=0 final_image=""
    local -A global_args=() stage_images=()
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        instruction="${line%%[[:space:]]*}"
        remainder="${line#"${instruction}"}"
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"
        if [ "${seen_from}" -eq 0 ] && [[ "${instruction,,}" == "arg" ]]; then
            name="${remainder%%=*}"
            if [[ "${remainder}" == *=* ]]; then
                value="${remainder#*=}"
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                global_args["${name}"]="${value}"
            fi
            continue
        fi
        [[ "${instruction,,}" == "from" ]] || continue
        seen_from=1
        remainder="${remainder#--platform=* }"
        image="${remainder%%[[:space:]]*}"
        while [[ "${image}" =~ (\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)) ]]; do
            token="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
            if [[ ! -v "global_args[${name}]" ]]; then
                local sot_val
                if sot_val="$(_ci_sot_base_image_arg "${name}")"; then
                    global_args["${name}"]="${sot_val}"
                else
                    # What: leave non-base-image ARGs opaque
                    # Why: builder-stage ARGs are not bases
                    # From: Issue #1683
                    break
                fi
            fi
            image="${image/"${token}"/${global_args[${name}]}}"
        done
        if [[ -v "stage_images[${image,,}]" ]]; then
            image="${stage_images[${image,,}]}"
        fi
        alias=""
        if [[ "${remainder}" =~ [[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            alias="${BASH_REMATCH[1],,}"
            stage_images["${alias}"]="${image}"
        fi
        final_image="${image}"
    done < <(_ci_dockerfile_logical_lines "${dockerfile}")
    _ci_procsub_ok "$!" 0 || return 2
    if [ -z "${final_image}" ]; then
        ci_log "[CI-ERROR-CHECK-0031]" "path=\"${dockerfile}\" reason=\"no FROM instruction found\""
        return 2
    fi
    # What: resolve only final base image
    # Why: builder-stage ARGs (BUILD_TOOLS_IMAGE) opaque
    # From: Issue #1683
    if [[ "${final_image}" == *'$'* ]]; then
        ci_log "[CI-ERROR-CHECK-0099]" "path=\"${dockerfile}\" reason=\"unresolved ARG in final FROM: ${final_image}\""
        return 2
    fi
    printf '%s\n' "${final_image}"
}

# What: Fail if one docker group's Dockerfiles diverge.
# Why: the grouped-PR premise needs one shared base image.
# From: Issue #1683 | PR #1858
_ci_check_dependabot_docker_base_consistency() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local dependabot_file="${repo_root}/.github/dependabot.yml"
    if [ ! -f "${dependabot_file}" ]; then
        ci_log "[CI-ERROR-CHECK-0027]" "path=\"${dependabot_file}\" reason=\"dependabot.yml not found\""
        return 2
    fi
    local -a entries=()
    local line
    while IFS= read -r line; do
        [ -n "${line}" ] && entries+=("${line}")
    done < <(_ci_dependabot_docker_entries "${dependabot_file}")
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#entries[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0028]" "path=\"${dependabot_file}\" reason=\"no docker-ecosystem directories found\""
        return 2
    fi
    local -A base_image_of=()
    # What: dirs_seen = declared; blocks_seen = resolved.
    # Why: a declared but missing dir is a 2nd failure kind.
    # From: Issue #1683 | PR #1858
    local -a declared_blocks=() dirs_seen=() blocks_seen=() missing=()
    local entry block dir dockerfile image
    for entry in "${entries[@]}"; do
        block="${entry%%$'\t'*}"
        dir="${entry#*$'\t'}"
        if [ "${dir}" = "@BLOCK@" ]; then
            declared_blocks+=("${block}")
            continue
        fi
        dirs_seen+=("${block}")
        dockerfile="${repo_root}${dir}/Dockerfile"
        if [ ! -f "${dockerfile}" ]; then
            missing+=("${dockerfile}")
            continue
        fi
        image="$(_ci_dockerfile_final_image "${dockerfile}")" || return 2
        base_image_of["${block}"$'\t'"${dockerfile}"]="${image}"
        blocks_seen+=("${block}")
    done
    local b
    for b in "${declared_blocks[@]}"; do
        case " ${dirs_seen[*]:-} " in
            *" ${b} "*) ;;
            *)
                ci_log "[CI-ERROR-CHECK-0029]" "reason=\"docker-ecosystem block #${b} has no parseable directory entries\""
                return 2
                ;;
        esac
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0030]" "reason=\"no Dockerfile for a dependabot.yml docker directory\"" "$(printf '%s\n' "${missing[@]}")"
        return 2
    fi
    local -a distinct_blocks=()
    while IFS= read -r b; do [ -n "${b}" ] && distinct_blocks+=("${b}"); done \
        < <(printf '%s\n' "${blocks_seen[@]}" | sort -un)
    local -a viol=()
    local key key_block key_dockerfile
    for b in "${distinct_blocks[@]}"; do
        local -a block_images=()
        for key in "${!base_image_of[@]}"; do
            key_block="${key%%$'\t'*}"
            [ "${key_block}" = "${b}" ] || continue
            block_images+=("${base_image_of[${key}]}")
        done
        local distinct_count
        distinct_count="$(printf '%s\n' "${block_images[@]}" | sort -u | grep -c .)"
        if [ "${distinct_count}" -gt 1 ]; then
            viol+=("block #${b} diverges:")
            for key in "${!base_image_of[@]}"; do
                key_block="${key%%$'\t'*}"
                [ "${key_block}" = "${b}" ] || continue
                key_dockerfile="${key#*$'\t'}"
                viol+=("  ${key_dockerfile}: ${base_image_of[${key}]}")
            done
        fi
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0032]" "reason=\"dependabot docker group base-image drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'dependabot-docker-base-consistency=clean dockerfiles=%s blocks=%s\n' \
        "${#base_image_of[@]}" "${#distinct_blocks[@]}"
}

# What: Fail unless prod install paths stay prebuilt-only.
# Why: docs/release-versioning: prod runs prebuilt images.
# From: Issue #1683 | PR #1858
_ci_check_prebuilt_prod() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dep inst
    local -a viol=()
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    dep="${repo_root}/$(dirname "${dep}")"
    inst="${repo_root}/$(dirname "${inst}")"
    local hit
    hit="$(_ci_capture 1 grep -RInE '^[[:space:]]+build:' "${dep}" "${inst}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("a stack compose declares build:; prod must run prebuilt images only" "${hit}")
    fi
    local hit
    hit="$(_ci_capture 1 grep -RIn -- '--build' "${repo_root}/README.md" "${dep}" "${inst}" "${repo_root}/setup.sh")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("a user-facing install path instructs --build; prod must run from prebuilt images, not a local build" "${hit}")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0042]" "reason=\"production install path is not prebuilt-only\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'prebuilt-prod=clean\n'
}

# What: Check prod state derives from LANCACHE_STATE_DIR.
# Why: AG-SETUP-001: LANCACHE_STATE_DIR is state root.
# From: Issue #1683 | PR #1858
_ci_check_prod_state_wiring() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dep
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local compose="${repo_root}/${dep}"
    local env_file
    env_file="${repo_root}/$(dirname "${dep}")/.env"
    local doc="${repo_root}/docs/backup-restore.md"
    local -a viol=()
    local key f
    for f in "${compose}" "${env_file}" "${doc}"; do
        [ -f "${f}" ] || { ci_error "[CI-ERROR-CHECK-0043]" "path=\"${f}\" reason=\"required prod-state-wiring input missing\"" "missing prod-state-wiring input: ${f}"; return 2; }
    done
    for key in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        grep -Fq "\${${key}:-\${LANCACHE_STATE_DIR" "${compose}" \
            || viol+=("${dep} does not derive ${key} from LANCACHE_STATE_DIR")
        grep -Fq "${key}" "${env_file}" \
            || viol+=("$(dirname "${dep}")/.env does not document ${key} for manual upgrades")
        grep -Fq "${key}" "${doc}" \
            || viol+=("docs/backup-restore.md does not mention ${key}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0100]" "reason=\"prod state wiring not LANCACHE_STATE_DIR-derived or undocumented\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'prod-state-wiring=clean\n'
}

# What: Fail unless every SOT host tool is present.
# Why: validate runs on the runner host (AG-CI-001).
# From: Issue #1683
_ci_validate_host_tools() {
    local tools t out
    local -a missing=()
    tools="$(_ci_block_entry_list validation "" host_tools)"
    if [ -z "${tools}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0056]" "reason=\"no SOT validation.host_tools\""
        return 2
    fi
    while IFS= read -r t; do
        [ -n "${t}" ] && ! command -v "${t}" >/dev/null 2>&1 && missing+=("${t}")
    done <<< "${tools}"
    if [ "${#missing[@]}" -gt 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0062]" "missing=\"${missing[*]}\" reason=\"host tool missing\""
        return 2
    fi
    if ! out="$(docker compose version 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0063]" "reason=\"docker compose plugin unusable\"" "${out}"
        return 2
    fi
}

# What: SOT validation env, one KEY=VALUE per line.
# Why: config check and live validate share one owner.
# From: Issue #1683
_ci_validation_env() {
    local fx
    fx="$(_ci_manifest_scalar '^  compose_validation_env:[[:space:]]')" || return 2
    if [ -z "${fx}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0054]" "reason=\"no SOT validation.compose_validation_env\""
        return 2
    fi
    tr ' ' '
' <<< "${fx}" | grep -v '^$'
}

# What: compose file setup.sh installs, read from setup.sh.
# Why: the installer owns its compose; CI only derives it.
# From: Issue #1683 | PR #1858
_ci_installer_compose() {
    local root="${1:-${CI_REPO_ROOT}}" su line
    local re='^QUICKSTART_COMPOSE="\$SCRIPT_DIR/([^"$]+)"$'
    su="${root}/setup.sh"
    if [ ! -f "${su}" ]; then
        ci_log "[CI-ERROR-CORE-0102]" "path=\"${su}\" reason=\"installer setup.sh not found\""
        return 2
    fi
    line="$(_ci_capture 1 grep -E '^QUICKSTART_COMPOSE=' "${su}")" || return 2
    if [ -z "${line}" ] || [ "$(wc -l <<< "${line}")" -ne 1 ]; then
        ci_error "[CI-ERROR-CORE-0104]" "path=\"${su}\" reason=\"QUICKSTART_COMPOSE missing or assigned twice\"" "${line}"
        return 2
    fi
    if [[ ! "${line}" =~ ${re} ]]; then
        ci_error "[CI-ERROR-CORE-0105]" "path=\"${su}\" reason=\"QUICKSTART_COMPOSE is not SCRIPT_DIR-relative\"" "${line}"
        return 2
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# What: docker compose with the env the file renders under.
# Why: .env if given, else SOT fixture; one env owner.
# From: Issue #1683 | PR #1858
_ci_compose_run() {
    local env_file="$1" fx kv
    shift
    local -a pre=() fixture=()
    if [ -n "${env_file}" ]; then
        pre=(--env-file "${env_file}")
    else
        fx="$(_ci_validation_env)" || return 2
        mapfile -t fixture <<< "${fx}"
    fi
    # What: export each KEY=VALUE fixture pair.
    # Why: ${kv?} is ShellCheck's pair form (SC2163).
    # From: Issue #1683 | PR #1858
    (
        for kv in "${fixture[@]}"; do
            export "${kv?}"
        done
        docker compose "${pre[@]}" "$@"
    )
}

# What: True if compose file/profile warning-free.
# Why: docker compose warnings hide real drift; fail closed.
# From: Issue #1683 | PR #1858
_ci_compose_config_ok() {
    local file="$1" profile="${2:-}" env_file="${3:-}" out
    local -a args=(-f "${file}")
    if [ -n "${profile}" ]; then
        args+=(--profile "${profile}")
    fi
    if ! out="$(_ci_compose_run "${env_file}" "${args[@]}" config --quiet 2>&1)"; then
        printf '%s\n' "${out}"
        return 1
    fi
    if grep -Eqi '(^|[[:space:]])(warn|warning|level=warning)' <<<"${out}"; then
        printf 'warnings treated as errors:\n%s\n' "${out}"
        return 1
    fi
    return 0
}

# What: stdout of one compose query; stderr output fails.
# Why: a warning is an error (AG-VAL-001); raw is kept.
# From: Issue #1683 | PR #1858
_ci_compose_query() {
    local file="$1" env_file="$2"
    shift 2
    _ci_capture 0 _ci_compose_run "${env_file}" -f "${file}" "$@"
}

# What: profile names a compose file declares.
# Why: the file owns its profiles; no hand-kept SOT list.
# From: Issue #1683 | PR #1858
_ci_compose_profiles() {
    _ci_compose_query "$1" "${2:-}" config --profiles
}

# What: env_file paths one compose service declares.
# Why: the compose owns them; docker compose parses it.
# From: Issue #1683 | PR #1858
_ci_compose_env_files() {
    local raw
    raw="$(_ci_compose_query "$1" "" config --no-env-resolution --format json)" || return 2
    jq -r --arg s "$2" \
        '.services[$s].env_file // [] | .[] | if type == "object" then .path else . end' <<< "${raw}"
}

# What: every stack compose renders clean in every profile.
# Why: profiles come from the file; none is skipped.
# From: Issue #1683 | PR #1858
_ci_check_compose_config() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=() pairs=() profiles=()
    local deploy targets envtargets rel mode pair cf ef raw p label render msg count=0
    deploy="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    targets="$(_ci_manifest_scalar '^  compose_targets:[[:space:]]')"
    if [ -z "${targets}" ]; then
        ci_error "[CI-ERROR-CHECK-0044]" "reason=\"no compose_targets in SOT\"" "manifest=${CI_MANIFEST}"
        return 1
    fi
    envtargets="$(_ci_manifest_scalar '^  compose_env_file_targets:[[:space:]]')"
    for rel in "${deploy}" ${targets}; do pairs+=("${rel}|"); done
    for rel in ${envtargets}; do pairs+=("${rel}|env"); done
    for pair in "${pairs[@]}"; do
        rel="${pair%|*}"
        mode="${pair#*|}"
        cf="${repo_root}/${rel}"
        label="${rel}"
        ef=""
        if [ -n "${mode}" ]; then
            label="(env-file) ${rel}"
            ef="$(dirname "${cf}")/.env"
        fi
        if [ ! -f "${cf}" ]; then
            viol+=("${label}: compose target missing")
            continue
        fi
        if ! raw="$(_ci_compose_profiles "${cf}" "${ef}" 2>&1)"; then
            viol+=("${label}: profiles unreadable"$'\n'"${raw}")
            continue
        fi
        profiles=("")
        [ -z "${raw}" ] || mapfile -t -O 1 profiles <<< "${raw}"
        for p in "${profiles[@]}"; do
            count=$((count + 1))
            render="${label}"
            if [ -n "${p}" ]; then
                render="${label}:${p}"
            fi
            if ! msg="$(_ci_compose_config_ok "${cf}" "${p}" "${ef}")"; then
                viol+=("${render}: config invalid" "${msg}")
            fi
        done
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0101]" "reason=\"compose config invalid\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-config=clean checks=%s\n' "${count}"
}

# What: Fail unless NATS/DNS configs are written atomically.
# Why: a torn shared-config write can start a broken stack.
# From: Issue #1683 | PR #1858
_ci_check_nats_atomic_write() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local cf dep inst ep='services/dns/entrypoint.sh' rs='services/ui/src/routes/secondaries.rs' su='setup.sh'
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    for cf in "${dep}" "${inst}"; do
        grep -Fq 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must stage the shared config in a temp file inside /etc/nats")
        grep -Fq 'chown 10001:10001 "$$tmp_nats_conf"' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must restore shared config ownership to 10001 after writing")
        grep -Fq 'mv "$$tmp_nats_conf" /etc/nats/nats.conf' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must atomically replace nats.conf after fixing ownership")
    done
    grep -Fq 'fn write_nats_conf_atomically(' "${repo_root}/${rs}" \
        || viol+=("${rs}: Admin UI must keep an atomic nats.conf write helper")
    grep -Fq 'fs::rename(&tmp_path, target)' "${repo_root}/${rs}" \
        || viol+=("${rs}: Admin UI nats.conf writes must use temp-file plus rename")
    grep -Fq 'render_template_atomic' "${repo_root}/${ep}" \
        || viol+=("${ep}: DNS entrypoint must render generated configs atomically")
    grep -Fq 'mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"' "${repo_root}/${ep}" \
        || viol+=("${ep}: DNS entrypoint must stage temp files in the target directory")
    local hit
    hit="$(_ci_capture 1 grep -F -e '> /tmp/recursor.conf' -e '> /tmp/pdns.conf' "${repo_root}/${ep}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("${ep}: DNS entrypoint must not render PDNS configs through /tmp")
    fi
    local hit
    hit="$(_ci_capture 1 grep -F "sed -i 's/^  loglevel: 3\$/  loglevel: 6/' /etc/pdns/recursor.conf" "${repo_root}/${ep}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("${ep}: query logging must apply to the staged recursor.conf before replacement")
    fi
    grep -Fq 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml"' "${repo_root}/${su}" \
        || viol+=("${su}: secondary setup must atomically write generated docker-compose.yml")
    grep -Fq 'write_env_file "${secondary_dir}/.env"' "${repo_root}/${su}" \
        || viol+=("${su}: secondary setup must use the safe env writer for generated .env")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0045]" "reason=\"shared config write is not atomic\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'nats-atomic-write=clean\n'
}

# What: Fail unless socket proxy stays deny-by-default.
# Why: a broad allowlist re-exposes generic container APIs.
# From: Issue #1683 | PR #1858
_ci_check_docker_socket_proxy() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local cf pat dep inst sp='scripts/untracked/docker-socket-proxy.sh'
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    for cf in "${dep}" "${inst}"; do
        local hit
        hit="$(_ci_capture 1 grep -F 'EXEC: "1"' "${repo_root}/${cf}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${cf}: Docker exec is banned from the Admin UI/watchdog proxy")
        fi
        local hit
        hit="$(_ci_capture 1 grep -E '^[[:space:]]*(CONTAINERS|POST): "1"' "${repo_root}/${cf}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${cf}: broad CONTAINERS=1/POST=1 exposes generic Docker APIs; use the allowlist")
        fi
        grep -Fq 'scripts/untracked/docker-socket-proxy.sh:/usr/local/bin/lancache-docker-socket-proxy.sh:ro' "${repo_root}/${cf}" \
            || viol+=("${cf}: must mount the one real scripts/untracked/docker-socket-proxy.sh")
        local hit
        hit="$(_ci_capture 1 grep -E '^x-docker-socket-proxy-command:' "${repo_root}/${cf}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${cf}: the dead x-docker-socket-proxy-command anchor must not be reintroduced")
        fi
    done
    local -a must=(
        'acl safe_service_restart'
        'acl safe_dhcp_action'
        'acl safe_probe_action'
        'acl safe_netdata_restart'
        'lancache-netdata/restart'
        'acl lancache_container'
        'lancache-dns-standard|lancache-dns-ssl'
        'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart'
        'lancache-dhcp|lancache-dhcp-proxy)/(start|stop)'
        'lancache-dhcp-probe/(start|stop|wait)'
        'http-request deny if docker_container_path !lancache_container'
        'http-request deny'
    )
    for pat in "${must[@]}"; do
        grep -Fq "${pat}" "${repo_root}/${sp}" || viol+=("${sp}: missing required allowlist rule: ${pat}")
    done
    local -a forbid=(
        'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats)/(start|stop|restart|wait)'
        '/containers/create'
        '/containers/json'
        '[A-Za-z0-9_.-]+/(start|stop|restart|attach)'
    )
    for pat in "${forbid[@]}"; do
        local hit
        hit="$(_ci_capture 1 grep -F -- "${pat}" "${repo_root}/${sp}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${sp}: forbidden broad rule present: ${pat}")
        fi
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0046]" "reason=\"docker socket proxy allowlist violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'docker-socket-proxy=clean\n'
}

# What: Fail unless .env defines every key.
# Why: unset key breaks quickstart compose.
# From: Issue #1683 | PR #1858
_ci_check_quickstart_required_env() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local key inst env compose
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    env="${repo_root}/$(dirname "${inst}")/.env"
    compose="${repo_root}/${inst}"
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        grep -Eq "^${key}=[^[:space:]]+" "${env}" \
            || viol+=("$(dirname "${inst}")/.env must define non-empty ${key} (compose marks it required)")
    done < <(
        grep -oE '\$\{[A-Za-z0-9_]+:\?[^}]+\}' "${compose}" \
            | sed -E 's/^\$\{([^:]+):.*/\1/' \
            | sort -u
    )
    _ci_procsub_ok "$!" 0 || return 2
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0047]" "reason=\"quickstart required env not defined\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'quickstart-required-env=clean\n'
}

# What: True if dhcp-proxy service uses env_file only.
# Why: env_file prod contract; reinterpolation loses keys.
# From: Issue #1683 | PR #1858
_ci_dhcp_proxy_env_file_ok() {
    local compose_file="$1" expected="$2"
    awk -v compose_file="${compose_file}" -v expected_env_file="${expected}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function content_indent(value, prefix) {
            match(value, /^[[:space:]]*/)
            prefix = substr(value, 1, RLENGTH)
            return length(prefix)
        }
        function strip_inline_comment(value) {
            sub(/[[:space:]]+#.*/, "", value)
            return value
        }
        /^  dhcp-proxy:/ { in_service=1; saw_service=1; in_env_file_block=0; next }
        in_service && /^  [[:alnum:]_-]+:/ { in_service=0; in_env_file_block=0 }
        in_service {
            line=strip_inline_comment($0)
            stripped=trim(line)
            if (in_env_file_block && stripped != "" && content_indent(line) <= env_file_indent) { in_env_file_block=0 }
            if (in_env_file_block && stripped ~ /^-/ && index(stripped, expected_env_file) > 0) { saw_env_file=1 }
            if (line ~ /^[[:space:]]*env_file:[[:space:]]*$/) {
                in_env_file_block=1; env_file_indent=content_indent(line)
            } else if (line ~ /^[[:space:]]*env_file:[[:space:]]*/ && index(line, expected_env_file) > 0) {
                saw_env_file=1
            }
            if (line ~ /^[[:space:]]*environment:[[:space:]]*/) { saw_environment=1 }
            if (stripped ~ /^-[[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP)=\$\{/ || stripped ~ /[{,][[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP):[[:space:]]*"\$\{/) { saw_interpolated_dhcp_key=1 }
        }
        END {
            if (!saw_service) { printf "%s: dhcp-proxy service is missing\n", compose_file; exit 1 }
            if (!saw_env_file) { printf "%s: dhcp-proxy must keep env_file %s\n", compose_file, expected_env_file; exit 1 }
            if (saw_environment || saw_interpolated_dhcp_key) { printf "%s: dhcp-proxy must not reintroduce Compose environment interpolation; env_file is the contract\n", compose_file; exit 1 }
        }
    ' "${compose_file}"
}

# What: Fail unless dhcp-proxy env/PXE surface intact.
# Why: env_file contract + optional/PXE keys not drop.
# From: Issue #1683 | PR #1858
_ci_check_dhcp_proxy_env() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local ef key out f dep inst qc
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    qc="${repo_root}/${inst}"
    local -a opt=(DHCP_PROXY_INTERFACE DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN DHCP_PROXY_BOOT_FILENAME DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS)
    local -a pxe=(DHCP_PROXY_PXE_BOOT_SERVER DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI)
    for f in "${dep}" config/prod/dhcp-proxy.env "$(dirname "${inst}")/.env" \
        "${inst}" services/dhcp-proxy/entrypoint.sh services/dhcp-proxy/dnsmasq.conf.template; do
        [ -f "${repo_root}/${f}" ] || { ci_error "[CI-ERROR-CHECK-0048]" "path=\"${f}\" reason=\"required dhcp-proxy input missing\"" "missing dhcp-proxy input: ${f}"; return 2; }
    done
    out="$(_ci_dhcp_proxy_env_file_ok "${repo_root}/${dep}" '../../config/prod/dhcp-proxy.env')" || viol+=("${out}")
    for ef in config/prod/dhcp-proxy.env "$(dirname "${inst}")/.env"; do
        for key in "${opt[@]}" "${pxe[@]}"; do
            grep -Eq "^${key}=" "${repo_root}/${ef}" || viol+=("${ef}: must define ${key} (empty default)")
        done
    done
    grep -Fq 'DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE:-}' "${qc}" \
        || viol+=("quickstart compose must pass through DHCP_PROXY_INTERFACE")
    grep -Fq 'DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS:-}' "${qc}" \
        || viol+=("quickstart compose must pass through DHCP_PROXY_CUSTOM_OPTIONS")
    for key in "${pxe[@]}"; do
        grep -Fq "${key}=\${${key}:-}" "${qc}" \
            || viol+=("quickstart compose must pass through ${key}")
    done
    grep -Fq '_dhcp_proxy_render_optional_directives()' "${repo_root}/services/dhcp-proxy/entrypoint.sh" \
        || viol+=("dhcp-proxy entrypoint must render optional dnsmasq directives (#450)")
    grep -Fq '_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf' "${repo_root}/services/dhcp-proxy/entrypoint.sh" \
        || viol+=("dhcp-proxy entrypoint must render optional directives before validating dnsmasq.conf")
    local hit
    hit="$(_ci_capture 1 grep -F 'dhcp-proxy=${UPSTREAM_DHCP_IP}' "${repo_root}/services/dhcp-proxy/dnsmasq.conf.template")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("dnsmasq.conf.template must not reintroduce the RFC 5107 dhcp-proxy flag")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0102]" "reason=\"dhcp-proxy env/PXE contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'dhcp-proxy-env=clean\n'
}

# What: Fail unless setup.sh keys + Kea preflight intact.
# Why: missing runtime keys/preflight breaks setup.
# From: Issue #1683 | PR #1858
_ci_check_setup_keys_kea() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local key dep inst su="${repo_root}/setup.sh"
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    local hit
    hit="$(_ci_capture 1 grep -RInE '^(NATS_LOCAL_TOKEN|NATS_TOKEN)=' "${repo_root}/$(dirname "${inst}")/.env" "${repo_root}/$(dirname "${dep}")/.env")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("env templates must not use deprecated NATS token keys; use role credentials" "${hit}")
    fi
    local -a req=(DDNS_TSIG_KEY KEA_CTRL_TOKEN LANCACHE_IMAGE_TAG NATS_DNS_REPLICA_PASSWORD NATS_DNS_REPLICA_USER NATS_DNS_WRITER_PASSWORD NATS_DNS_WRITER_USER NATS_CALLOUT_PASSWORD NATS_CALLOUT_USER NATS_SYS_PASSWORD NATS_SYS_USER NATS_UI_PASSWORD NATS_UI_USER PDNS_API_KEY SECONDARY_REGISTRATION_TOKEN)
    for key in "${req[@]}"; do
        grep -Fq "${key}" "${su}" || viol+=("setup.sh must generate or migrate required runtime key ${key}")
    done
    grep -Fq 'run_kea_dhcp_activation_preflight()' "${su}" \
        || viol+=("setup.sh must define a DHCP discovery preflight before Kea activation")
    grep -Fq 'run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"' "${su}" \
        || viol+=("setup.sh must call the Kea discovery preflight before starting the stack")
    grep -Fq 'nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5' "${su}" \
        || viol+=("setup.sh must probe DHCP discovery with the Kea image before activation")
    local hit
    hit="$(_ci_capture 1 grep -F 'nmap --script broadcast-dhcp-discover -e any' "${su}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("setup.sh must not pass -e any to nmap; invalid interface fails the preflight")
    fi
    # What: nmap in SOT dhcp packages
    # Why: SOT owns apk lists; Dockerfile consumes
    # From: Issue #1683 | PR #1858
    local dhcp_pkgs
    dhcp_pkgs="$(_ci_block_entry_list services dhcp packages)"
    grep -qx 'nmap' <<< "${dhcp_pkgs}" \
        || viol+=("SOT services.dhcp.packages must install nmap for the Kea discovery preflight")
    grep -Fq 'nmap|/usr/bin/nmap|/bin/nmap)' "${repo_root}/services/dhcp/entrypoint.sh" \
        || viol+=("services/dhcp/entrypoint.sh must pass through the nmap preflight command")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0049]" "reason=\"setup.sh required keys / Kea preflight contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-keys-kea=clean\n'
}

# What: Fail unless update pauses/guards before mutation.
# Why: AG-OP-010 validation-before-mutation; prebuilt first.
# From: Issue #1683
_ci_check_setup_update_safety() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local su="${repo_root}/setup.sh" pause_out
    local -a viol=()
    [ -f "${su}" ] || { ci_error "[CI-ERROR-CHECK-0062]" "path=\"${su}\" reason=\"setup.sh not found\""; return 2; }
    awk '/This script must be run as root/{r=1} r&&/assert_prebuilt_image_platform_supported/{g=1} r&&!g&&/(install_docker|systemctl enable --now docker)/{f=1} END{exit f?0:1}' "${su}" \
        && viol+=("prebuilt platform guard must run before Docker install or daemon startup")
    # What: no flow mutates install state before its pause.
    # Why: per function; the cmd_update window went stale.
    # From: Issue #1683 | PR #1858
    if ! pause_out="$(awk '
        /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ { fn = $1; sub(/\(\).*/, "", fn); next }
        /^[[:space:]]*#/ { next }
        /pause_lancache_convergence_for_update/ { seen[fn] = 1; paused[fn] = 1; next }
        !paused[fn] && /(sync_repo_to_default_branch|install_quickstart_compose_assets|cmd_backup|git -C|migrate_env_for_update|validate_compose_config|dc_update[[:space:]]+(pull|up)|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+(pull|up))/ {
            pend[fn] = pend[fn] NR ": " $0 "\n"
        }
        END {
            for (f in seen) { n++; if (pend[f] != "") { printf "%s mutates before its pause:\n%s", f, pend[f]; bad = 1 } }
            if (n == 0) { print "no update flow calls pause_lancache_convergence_for_update"; bad = 1 }
            exit bad
        }' "${su}")"; then
        viol+=("update must pause the convergence timer before mutating install state"$'\n'"${pause_out}")
    fi
    grep -Fq 'systemctl stop lancache-converge.service' "${su}" \
        || viol+=("update must stop the active convergence service before mutating install state")
    awk '/if ! \( cmd_backup --config "\$install_dir" \); then/{b=1;next} b&&/resume_lancache_convergence_after_update true/{r=1} b&&/die "Pre-update rollback backup failed/{d=1;b=0} END{exit r&&d?0:1}' "${su}" \
        || viol+=("update must restore the convergence timer when the rollback backup fails")
    awk '/^cmd_update_ip\(\) \{/{u=1;g=0;next} /^# .*backup subcommand/{u=0} u&&/assert_prebuilt_image_platform_supported/{g=1} u&&!g&&/(sed -i|docker compose -f)/{f=1} END{exit f?0:1}' "${su}" \
        && viol+=("update-ip must check prebuilt platform support before mutating config")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0103]" "reason=\"setup.sh update-migration safety contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-update-safety=clean\n'
}

# What: Fail unless Fedora/RHEL Docker RPM guarded.
# Why: legacy docker RPMs conflict; podman/runc ok.
# From: Issue #1683
_ci_check_setup_docker_conflict() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local su="${repo_root}/setup.sh"
    local -a viol=()
    [ -f "${su}" ] || { ci_error "[CI-ERROR-CHECK-0063]" "path=\"${su}\" reason=\"setup.sh not found\""; return 2; }
    grep -Fq 'rpm_legacy_docker_package_list()' "${su}" \
        || viol+=("setup.sh must keep a shared legacy Docker RPM conflict list")
    { grep -Fq 'docker-selinux' "${su}" && grep -Fq 'docker-engine-selinux' "${su}"; } \
        || viol+=("Fedora/RHEL Docker RPM conflict guard must include legacy Docker selinux packages")
    grep -Fq 'docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin)' "${su}" \
        || viol+=("compose-plugin-only RPM install must still run the Docker/Podman conflict guard")
    if awk '/\[\[ "\$os_id" = fedora \]\]/{f=1;next} /^    else$/{f=0} f&&/ (podman|runc)([[:space:]]|$)/{v=1} END{exit v?0:1}' "${su}"; then
        viol+=("Fedora Docker conflict guard must not block stock podman or runc")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0104]" "reason=\"setup.sh Docker RPM conflict contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-docker-conflict=clean\n'
}

# What: Fail unless channel/tag resolves from config.
# Why: one resolution across setup.sh/UI/compose.
# From: Issue #1683
_ci_check_image_channel_resolution() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local su="${repo_root}/setup.sh"
    local sec="${repo_root}/services/ui/src/routes/secondaries.rs"
    local prod dep
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    prod="${repo_root}/${dep}"
    local -a viol=()
    local f
    [ -f "${su}" ] || { ci_error "[CI-ERROR-CHECK-0064]" "path=\"${su}\" reason=\"setup.sh not found\""; return 2; }
    if awk '/^# .*Installing systemd watchdog/{i=1;p=0} /^# .*Post-start info/{i=0} i&&/docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+pull/{p=1} i&&!p&&/^[[:space:]]*(systemctl[[:space:]]+(enable|start)[[:space:]]+(lancache\.service|lancache-converge\.timer)|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+up[[:space:]]+-d)/{v=1} END{exit v?0:1}' "${su}"; then
        viol+=("setup.sh must not start/enable lancache services before image pull")
    fi
    for f in \
        'lancache_image_registry=$(resolve_lancache_image_registry "$env_file")' \
        'lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file")' \
        'lancache_image_channel=$(resolve_lancache_image_channel "$env_file")' \
        'lancache_image_tag=$(resolve_lancache_image_tag "$env_file")' \
        'LANCACHE_IMAGE_CHANNEL=pinned requires LANCACHE_IMAGE_TAG to be set to an immutable sha-* or vX.Y.Z tag.' \
        'resolve_lancache_stack_channel_tag()' \
        'docker cp "${container_id}:/stack.env" -' \
        'response_image_tag=$(echo "$response"' \
        'response_image_registry=$(echo "$response"' \
        'response_image_prefix=$(echo "$response"' \
        'response_image_channel=$(echo "$response"' \
        'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}' \
        'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}' \
        'LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}' \
        'derive_release_archive_image_tag()' \
        'channel="${channel:-latest}"'; do
        grep -Fq "${f}" "${su}" || viol+=("setup.sh must keep image-resolution: ${f}")
    done
    if [ -f "${sec}" ]; then
        for f in \
            'pub image_tag: String' 'pub image_registry: String' \
            'pub image_prefix: String' 'pub image_channel: String' \
            'image_tag: state.config.lancache_image_tag.clone()' \
            'image_registry: state.config.lancache_image_registry.clone()' \
            'image_prefix: state.config.lancache_image_prefix.clone()' \
            'image_channel: state.config.lancache_image_channel.clone()'; do
            grep -Fq "${f}" "${sec}" || viol+=("secondaries.rs must expose/use ${f}")
        done
    fi
    if [ -f "${prod}" ]; then
        for f in \
            'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY:-ghcr.io}' \
            'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}' \
            'LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL:-}' \
            'LANCACHE_IMAGE_TAG=${LANCACHE_IMAGE_TAG:-latest}'; do
            grep -Fq "${f}" "${prod}" || viol+=("prod compose must pass ${f}")
        done
    fi
    grep -Fq 'LANCACHE_IMAGE_CHANNEL=latest' "${repo_root}/README.md" \
        || viol+=("README must document latest as the install default")
    grep -Fq 'fresh installs use `LANCACHE_IMAGE_CHANNEL=nightly` by default pre-1.0' "${repo_root}/docs/release-versioning.md" \
        || viol+=("release docs must document nightly as the pre-1.0 default")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0105]" "reason=\"image channel/tag resolution contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'image-channel-resolution=clean\n'
}

# What: Emit the OpenVEX document for a trivyignore file.
# Why: One VEX generator for drift-check and release attach.
# From: Issue #1683
_ci_generate_vex() {
    local trivyignore="$1" repo_root="${2:-${CI_REPO_ROOT:-.}}"
    local gen="${repo_root}/scripts/untracked/generate-vex.sh"
    if [ -n "${CI_VEX_GENERATE_CMD:-}" ]; then
        "${CI_VEX_GENERATE_CMD}" "${trivyignore}"
        return "$?"
    fi
    [ -f "${gen}" ] || return 2
    bash "${gen}" "${trivyignore}"
}

# What: Fail unless generate-vex.sh emits valid OpenVEX.
# Why: catch VEX generator bugs before post-merge discovery.
# From: Issue #1683 | PR #1858
_ci_check_vex_drift() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local trivyignore="${repo_root}/.trivyignore.yaml"
    local out entry_count statement_count rc=0
    [ -f "${trivyignore}" ] || { ci_error "[CI-ERROR-CHECK-0050]" "path=\"${trivyignore}\" reason=\".trivyignore.yaml not found\"" "${trivyignore}"; return 2; }
    out="$(_ci_generate_vex "${trivyignore}" "${repo_root}")" || rc=$?
    if [ "${rc}" -eq 2 ]; then
        ci_error "[CI-ERROR-CHECK-0106]" "reason=\"generate-vex.sh not found\"" "${trivyignore}"; return 2
    elif [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-CHECK-0107]" "reason=\"generate-vex.sh failed\"" "${trivyignore}"; return 1
    fi
    local jq_err
    if ! jq_err="$(jq empty <<<"${out}" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0108]" "reason=\"generate-vex.sh produced invalid JSON\"" "${jq_err}"
        return 1
    fi
    entry_count="$(_ci_capture 1 grep -c '^  - id:' "${trivyignore}")" || return 2
    statement_count="$(jq '.statements | length' <<<"${out}")"
    if [ "${entry_count:-0}" -gt 0 ] && [ "${statement_count}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0109]" "reason=\"${entry_count} trivyignore entries but 0 VEX statements\"" "${trivyignore}"
        return 1
    fi
    printf 'vex-drift=clean statements=%s\n' "${statement_count}"
}

# What: Warn (never fail) on editing CHANGELOG.md directly.
# Why: usually unintended; risks a merge-conflict cascade.
# From: Issue #1683 | PR #1858
_ci_check_changelog_direct_edit() {
    local -a changed=("$@")
    local path edited=0
    for path in "${changed[@]}"; do
        [ "${path}" = "CHANGELOG.md" ] && { edited=1; break; }
    done
    if [ "${edited}" -eq 0 ]; then
        printf 'changelog-direct-edit=clean\n'
        return 0
    fi
    local label_rc=0 label_err
    label_err="$(jq -e 'index("release") != null' <<<"${PR_LABELS_JSON:-[]}" 2>&1 >/dev/null)" || label_rc=$?
    case "${label_rc}" in
        0) ci_log "[CI-INFO-CHECK-0001]" "reason=\"CHANGELOG.md edited with release label; expected\"" ;;
        1) ci_log "[CI-INFO-CHECK-0002]" "reason=\"CHANGELOG.md edited directly outside the release flow (issue #893); warn-only\"" ;;
        *)
            ci_error "[CI-ERROR-CHECK-0112]" "reason=\"PR_LABELS_JSON unreadable\"" "${label_err}"
            return 2
            ;;
    esac
    printf 'changelog-direct-edit=warn\n'
}

# What: One awk pass over the logging-matrix table's rows.
# Why: a per-row shell loop once fork-raced a real row away.
# From: Issue #1683 | PR #1858
_ci_logging_matrix_canonical() {
    local doc="$1"
    awk '
        /\*\*Logging matrix\*\*/ { seen_marker = 1; next }
        seen_marker && /^\|/ {
            rows_seen = 1
            if ($0 ~ /^\|[[:space:]]*Service[[:space:]]*\|/) next
            if ($0 ~ /^\|[[:space:]]*-+[[:space:]]*\|/) next
            line = $0
            sub(/^\|[[:space:]]*/, "", line)
            n = split(line, parts, "|")
            cell = (n >= 1) ? parts[1] : ""
            sub(/[[:space:]]+$/, "", cell)
            name = cell
            if (match(cell, /`[a-z0-9-]+`/)) {
                name = substr(cell, RSTART + 1, RLENGTH - 2)
            } else {
                sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", name)
            }
            data_rows++
            if (!(name in seen)) { seen[name] = 1; print name }
            next
        }
        seen_marker && rows_seen && !/^\|/ { exit }
        END {
            unique_count = 0
            for (k in seen) unique_count++
            print "##ROWS## " data_rows " " unique_count
        }
    ' "${doc}"
}

# What: Print one real Compose service name per line.
# Why: a profiled service needs `config --profiles` first.
# From: Issue #1683 | PR #1858
_ci_compose_service_names() {
    local file="$1"
    if [ -n "${CI_LOGGING_MATRIX_SERVICES_CMD:-}" ]; then
        "${CI_LOGGING_MATRIX_SERVICES_CMD}" "${file}"
        return "$?"
    fi
    local flags
    local -a profile_flags=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t profile_flags <<< "${flags}"
    docker compose -f "${file}" "${profile_flags[@]}" config --services
}

# What: --profile flag pairs for every compose profile.
# Why: one owner; a profiled service must not be skipped.
# From: Issue #1683
_ci_compose_profile_flags() {
    local profiles p
    profiles="$(_ci_compose_profiles "$1")" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] && printf -- '--profile\n%s\n' "${p}"
    done <<< "${profiles}"
    return 0
}

# What: Fail if logging-matrix row/service pair drifts.
# Why: every service needs a declared row.
# From: Issue #1683 | PR #1858
_ci_check_logging_matrix() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local doc="${repo_root}/docs/architecture-ng.md"
    if [ ! -f "${doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0035]" "path=\"${doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    local canonical_raw
    canonical_raw="$(_ci_logging_matrix_canonical "${doc}")"
    local row_summary raw_row_count unique_row_count
    row_summary="$(_ci_capture 1 grep -E '^##ROWS## ' <<<"${canonical_raw}")" || return 2
    raw_row_count="$(awk '{print $2}' <<<"${row_summary}")"
    unique_row_count="$(awk '{print $3}' <<<"${row_summary}")"
    local -a canonical=()
    local n
    while IFS= read -r n; do
        [ -n "${n}" ] && canonical+=("${n}")
    done < <(grep -vE '^##ROWS## ' <<<"${canonical_raw}")
    _ci_procsub_ok "$!" 1 || return 2
    if [ "${#canonical[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0036]" "path=\"${doc}\" reason=\"no logging-matrix rows parsed\""
        return 2
    fi
    if [ -n "${raw_row_count}" ] && [ -n "${unique_row_count}" ] && [ "${unique_row_count}" -lt "${raw_row_count}" ]; then
        ci_log "[CI-ERROR-CHECK-0037]" "reason=\"parsed ${unique_row_count} unique of ${raw_row_count} rows; a row was dropped or collapsed\""
        return 2
    fi
    local dep inst
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    local -a compose_files=("${repo_root}/${dep}" "${repo_root}/${inst}")
    local -a consumer=() viol=()
    local cf svc
    for cf in "${compose_files[@]}"; do
        # What: capture the exit before splitting lines.
        # Why: a while/process-sub loop can hide it.
        local raw_services
        if raw_services="$(_ci_compose_service_names "${cf}")"; then
            :
        else
            ci_log "[CI-ERROR-CHECK-0034]" "path=\"${cf}\" reason=\"compose service lookup failed\""
            return 2
        fi
        local -a file_services=()
        while IFS= read -r svc; do
            [ -n "${svc}" ] && file_services+=("${svc}")
        done <<<"${raw_services}"
        for svc in "${file_services[@]}"; do
            case " ${canonical[*]} " in
                *" ${svc} "*) ;;
                *) viol+=("${cf}: service '${svc}' has no logging-matrix row") ;;
            esac
            consumer+=("${svc}")
        done
    done
    for n in "${canonical[@]}"; do
        case " ${consumer[*]:-} " in
            *" ${n} "*) ;;
            *) viol+=("${doc}: row '${n}' is not a real Compose service") ;;
        esac
    done
    # What: quickstart's inline web_log job vs. real file.
    # Why: no services/ dir there to bind-mount it from.
    # From: Issue #1683 | PR #1858
    local web_log_conf="${repo_root}/services/syslog/netdata-web_log.conf"
    local quickstart_compose="${repo_root}/${inst}"
    if [ ! -f "${web_log_conf}" ]; then
        viol+=("${web_log_conf}: not found")
    elif [ ! -f "${quickstart_compose}" ]; then
        viol+=("${quickstart_compose}: not found")
    else
        local real_jobs quick_jobs
        real_jobs="$(awk '/^jobs:/{flag=1} flag{print}' "${web_log_conf}")"
        quick_jobs="$(awk '
            /cat > \/etc\/netdata\/go\.d\/web_log\.conf <<.CONF./ { capture = 1; next }
            capture && /^        CONF$/ { capture = 0 }
            capture { print }
        ' "${quickstart_compose}" | sed 's/^        //')"
        if [ -z "${real_jobs}" ]; then
            viol+=("${web_log_conf}: no 'jobs:' section found")
        elif [ -z "${quick_jobs}" ]; then
            viol+=("${quickstart_compose}: no web_log.conf heredoc found")
        elif [ "${real_jobs}" != "${quick_jobs}" ]; then
            viol+=("quickstart's inline web_log job config has drifted from ${web_log_conf}")
        fi
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0038]" "reason=\"logging-matrix drift (issue #633)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'logging-matrix=clean rows=%s services=%s\n' "${#canonical[@]}" "${#consumer[@]}"
}

# What: Deny any aquasecurity trivy action in workflows.
# Why: ci.sh scan owns trivy + its retry (AG-CI-013/023).
# From: Issue #1683 | PR #1858
_ci_check_trivy_action_direct_usage() {
    local repo_root="${1:-${CI_REPO_ROOT}}" out d
    local -a dirs=()
    for d in .github/workflows .github/actions; do
        [ -d "${repo_root}/${d}" ] && dirs+=("${d}")
    done
    [ "${#dirs[@]}" -gt 0 ] || { printf 'trivy-action-direct-usage=clean dirs=0\n'; return 0; }
    out="$(cd "${repo_root}" && _ci_capture 1 grep -nRE --include='*.yml' --include='*.yaml' \
        '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?aquasecurity/(setup-)?trivy(-action)?@' \
        "${dirs[@]}")" || return 2
    if [ -n "${out}" ]; then
        ci_error "[CI-ERROR-CHECK-0039]" "reason=\"aquasecurity trivy action; scan via ci.sh\"" "${out}"
        return 1
    fi
    printf 'trivy-action-direct-usage=clean\n'
}

# What: True if final stage COPYs to destination.
# Why: Only runtime stage files exist at run time.
# From: Issue #1683
_ci_dockerfile_copies_to() {
    local dockerfile="$1" want="$2" line lineno=0 last_from=0 dest from_val ctx_path
    local -a words real
    local -A aliases=()
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        case "${line}" in [Ff][Rr][Oo][Mm]\ *) last_from=${lineno} ;; esac
        if [[ "${line}" =~ [Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$ ]]; then
            aliases["${BASH_REMATCH[1],,}"]=1
        fi
    done < <(_ci_dockerfile_logical_lines "${dockerfile}")
    _ci_procsub_ok "$!" 0 || return 2
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        [ "${lineno}" -ge "${last_from}" ] || continue
        case "${line}" in [Cc][Oo][Pp][Yy]\ *) : ;; *) continue ;; esac
        read -ra words <<< "${line}"
        real=(); from_val=""
        local w
        for w in "${words[@]:1}"; do
            case "${w}" in
                --from=*) from_val="${w#--from=}"; continue ;;
                --*) continue ;;
            esac
            real+=("${w}")
        done
        if [ -n "${from_val}" ]; then
            case "${from_val}" in
                *[!0-9]*)
                    case "${from_val,,}" in
                        */*|*:*|*.*) : ;;
                        *)
                            if [ -z "${aliases[${from_val,,}]:-}" ]; then
                                ctx_path="$(_ci_block_entry_field named_contexts "${from_val}" path)"
                                [ -n "${ctx_path}" ] || continue
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
        [ "${#real[@]}" -ge 2 ] || continue
        dest="${real[$(( ${#real[@]} - 1 ))]}"
        [ "${dest}" = "${want}" ] && return 0
        case "${dest}" in */) [ "${dest}${want##*/}" = "${want}" ] && return 0 ;; esac
    done < <(_ci_dockerfile_logical_lines "${dockerfile}")
    _ci_procsub_ok "$!" 0 || return 2
    return 1
}

# What: Sourced lib path must match a COPY destination.
# Why: source-drift breaks silently only at runtime.
# From: Issue #1683
_ci_check_entrypoint_lib_wiring() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local ep svc svcs ctx name dockerfile line lib_path

    # What: each SOT service context's entrypoint script.
    # Why: the SOT owns services and paths; no glob/literal.
    # From: Issue #1683
    svcs="$(ci_services)" || return 2
    for svc in ${svcs}; do
        ctx="$(_ci_required_field "${svc}" context)" || return 2
        dockerfile="${repo_root}/${ctx}/Dockerfile"
        for name in entrypoint.sh docker-entrypoint.sh; do
            ep="${repo_root}/${ctx}/${name}"
            [ -f "${ep}" ] || continue
            while IFS= read -r line; do
                [[ "${line}" =~ ^[[:space:]]*(\.|source)[[:space:]]+\"?(/[^\"[:space:]]+)\"?[[:space:]]*(\#.*)?$ ]] || continue
                lib_path="${BASH_REMATCH[2]}"
                if [ ! -f "${dockerfile}" ]; then
                    viol+=("${ctx}: sources ${lib_path}, no Dockerfile found")
                    continue
                fi
                _ci_dockerfile_copies_to "${dockerfile}" "${lib_path}" ||
                    viol+=("${ctx}/${name} sources ${lib_path}: no matching final-stage COPY in ${dockerfile}")
            done < "${ep}"
        done
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0041]" "reason=\"entrypoint sources a lib its Dockerfile never COPYs\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'entrypoint-lib-wiring=clean\n'
}

# What: rust Dockerfiles must use build-tools image.
# Why: one toolchain owner; no self-compile (AG-CI-008).
# From: Issue #1683
_ci_check_dockerfile_build_tools() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" service ctx df rc=0
    local -a viol=() tuning=()
    for service in $(ci_services); do
        [ "$(ci_service_field "${service}" build_type)" = rust ] || continue
        ctx="$(ci_service_field "${service}" context)"
        df="${repo_root}/${ctx}/Dockerfile"
        if [ ! -f "${df}" ]; then
            viol+=("${service}: no Dockerfile at ${ctx}"); continue
        fi
        grep -q 'ARG BUILD_TOOLS_IMAGE' "${df}" \
            || viol+=("${service}: Dockerfile must declare ARG BUILD_TOOLS_IMAGE")
        grep -Fq 'FROM ${BUILD_TOOLS_IMAGE}' "${df}" \
            || viol+=("${service}: Dockerfile must build FROM \${BUILD_TOOLS_IMAGE}")
        # What: forbid a mutable default on the ARG.
        # Why: ci.sh supplies the immutable ref (AG-CI-008).
        # From: Issue #1683
        local hit
        hit="$(_ci_capture 1 grep -E '^ARG BUILD_TOOLS_IMAGE=' "${df}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${service}: ARG BUILD_TOOLS_IMAGE must carry no default; ci.sh supplies it")
        fi
        local hit
        hit="$(_ci_capture 1 grep -F 'cargo install' "${df}")" || return 2
        if [ -n "${hit}" ]; then
            viol+=("${service}: Dockerfile compiles a tool with cargo install; consume the build-tools image")
        fi
        # What: reject Cargo tuning hardcode; empty ARG ok.
        # Why: jobs/lto/codegen from CI vars (AG-CI-006).
        # From: Issue #1683
        local hit
        hit="$(_ci_capture 1 grep -E '^[[:space:]]*(ARG[[:space:]]+SCCACHE_DIST_SCHEDULER_URL|ENV[[:space:]]+CARGO_BUILD_JOBS=|ARG[[:space:]]+PROJECT_CARGO_LTO=.+|ARG[[:space:]]+PROJECT_CARGO_CODEGENUNIT=.+|ENV[[:space:]]+PROJECT_CARGO_LTO=|ENV[[:space:]]+PROJECT_CARGO_CODEGENUNIT=)' "${df}")" || return 2
        if [ -n "${hit}" ]; then
            tuning+=("${service}: Dockerfile hardcodes a Cargo tuning value; source jobs/lto/codegen from CI vars")
        fi
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0058]" "reason=\"rust Dockerfile does not consume the build-tools image (AG-CI-008/AG-REL-002)\"" "$(printf '%s\n' "${viol[@]}")"
        rc=1
    fi
    if [ "${#tuning[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0060]" "reason=\"rust Dockerfile hardcodes a Cargo tuning value (AG-CI-006)\"" "$(printf '%s\n' "${tuning[@]}")"
        rc=1
    fi
    [ "${rc}" -eq 0 ] && printf 'dockerfile-build-tools=clean\n'
    return "${rc}"
}

# What: no workspace Cargo.toml set [profile].
# Why: sourced from CARGO env vars (AG-CI-006).
# From: Issue #1683
_ci_check_cargo_profile_tuning() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" f line tomls
    local -a viol=()
    tomls="$(git -C "${repo_root}" ls-files '*Cargo.toml')" || { ci_log "[CI-ERROR-CHECK-0071]" "reason=\"git ls-files failed; refusing an empty scan\""; return 2; }
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        while IFS= read -r line; do
            [ -n "${line}" ] && viol+=("${f}:${line}")
        done < <(grep -nE '^[[:space:]]*(lto|codegen-units)[[:space:]]*=' "${repo_root}/${f}")
        _ci_procsub_ok "$!" 1 || return 2
    done <<< "${tomls}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0059]" "reason=\"Cargo.toml hardcodes [profile] lto/codegen-units; source them from CARGO_PROFILE_RELEASE env (AG-CI-006)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'cargo-profile-tuning=clean\n'
}

# What: no Dockerfile cargo-install prebuilt.
# Why: build-tools one toolchain owner (AG-REL-002).
# From: Issue #1683
_ci_check_no_source_compiled_tools() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" df tok raw dfs
    local -a viol=() pkgs=()
    local -A is_pkg=()
    raw="$(_ci_build_tools_packages)" || return 2
    mapfile -t pkgs <<< "${raw}"
    for tok in "${pkgs[@]}"; do [ -n "${tok}" ] && is_pkg["${tok}"]=1; done
    dfs="$(git -C "${repo_root}" ls-files '*Dockerfile')" || { ci_log "[CI-ERROR-CHECK-0071]" "reason=\"git ls-files failed; refusing an empty scan\""; return 2; }
    while IFS= read -r df; do
        [ -n "${df}" ] || continue
        while IFS= read -r tok; do
            [ -n "${tok}" ] && [ -n "${is_pkg[${tok}]:-}" ] \
                && viol+=("${df}: cargo install ${tok}; SOT ships it prebuilt in build-tools")
        done < <(awk '
            match($0, /cargo[ \t]+install[ \t]+/) {
                r = substr($0, RSTART + RLENGTH)
                sub(/[&|;].*/, "", r)
                n = split(r, a, /[ \t]+/)
                for (i = 1; i <= n; i++)
                    if (a[i] != "" && a[i] !~ /^-/) print a[i]
            }
        ' "${repo_root}/${df}")
        _ci_procsub_ok "$!" 0 || return 2
    done <<< "${dfs}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0061]" "reason=\"Dockerfile source-compiles a prebuilt SOT tool; consume the build-tools image\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'no-source-compiled-tools=clean\n'
}

# What: every tracked language file is in its CodeQL scope.
# Why: an unlisted source dir would skip analysis silently.
# From: Issue #1683
_ci_check_codeql_coverage() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" lang langs raw files f p ok
    local -a viol=() globs=() paths=()
    langs="$(_ci_block_keys codeql_languages)" || return 2
    for lang in ${langs}; do
        raw="$(_ci_block_entry_list codeql_languages "${lang}" files)" || return 2
        [ -n "${raw}" ] || continue
        mapfile -t globs <<< "${raw//\"/}"
        raw="$(_ci_block_entry_list codeql_languages "${lang}" paths)" || return 2
        mapfile -t paths <<< "${raw//\"/}"
        files="$(git -C "${repo_root}" ls-files -- "${globs[@]}")" || { ci_log "[CI-ERROR-CHECK-0071]" "reason=\"git ls-files failed; refusing an empty scan\""; return 2; }
        while IFS= read -r f; do
            [ -n "${f}" ] || continue
            ok=false
            for p in "${paths[@]}"; do
                case "${f}" in "${p}"/*) ok=true; break ;; esac
            done
            [ "${ok}" = true ] || viol+=("${lang}: ${f}")
        done <<< "${files}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0072]" "reason=\"tracked source outside SOT codeql_languages paths\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'codeql-coverage=clean\n'
}

# What: shellcheck changed shell scripts (§98).
# Why: one owner; SOT build-tools image.
# From: Issue #1683
_ci_check_shellcheck() {
    local -a changed=() files=()
    _ci_collect_changed changed "$@" || return 2
    # What: keep only real shell files; mixed.
    # Why: shellcheck reads shell; yaml etc not input.
    # From: Issue #1683
    local f
    for f in "${changed[@]}"; do
        case "${f}" in *.sh|*.bats) [ -f "${f}" ] && files+=("${f}") ;; esac
    done
    [ "${#files[@]}" -eq 0 ] && { printf 'shellcheck=noop\n'; return 0; }
    local out rc=0
    if [ -n "${CI_SHELLCHECK_CMD:-}" ]; then
        out="$("${CI_SHELLCHECK_CMD}" "${files[@]}" 2>&1)" || rc=$?
    else
        out="$(shellcheck --severity=warning "${files[@]}" 2>&1)" || rc=$?
    fi
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-CHECK-0056]" "reason=\"shellcheck found issues\"" "${out}"
        return 1
    fi
    printf 'shellcheck=clean files=%s\n' "${#files[@]}"
}

# What: actionlint workflow files (§98 exception).
# Why: workflow syntax not answerable from diff.
# From: Issue #1683
_ci_check_actionlint() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" out rc=0
    if [ -n "${CI_ACTIONLINT_CMD:-}" ]; then
        out="$("${CI_ACTIONLINT_CMD}" "${repo_root}" 2>&1)" || rc=$?
    else
        out="$(actionlint "${repo_root}/.github/workflows/"*.yml 2>&1)" || rc=$?
    fi
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-CHECK-0057]" "reason=\"actionlint found issues\"" "${out}"
        return 1
    fi
    printf 'actionlint=clean\n'
}

# What: Fail on a vulnerable or yanked Rust dependency.
# Why: cargo-audit policy owner; the workflow only runs it.
# From: Issue #1683
_ci_check_cargo_audit() {
    local lock="${1:-Cargo.lock}" out rc=0
    if [ -n "${CI_CARGO_AUDIT_CMD:-}" ]; then
        out="$("${CI_CARGO_AUDIT_CMD}" "${lock}" 2>&1)" || rc=$?
    else
        out="$(cargo audit --deny warnings --file "${lock}" 2>&1)" || rc=$?
    fi
    # What: advisories/warnings fail (belt+braces).
    # Why: --deny warnings catches; never pass.
    # From: Issue #1683
    if [ "${rc}" -ne 0 ] || grep -Eiq '(^|[[:space:]])warning:' <<< "${out}"; then
        ci_error "[CI-ERROR-CHECK-0055]" "reason=\"cargo audit found advisories or warnings\"" "${out}"
        return 1
    fi
    printf 'cargo-audit=clean\n'
}

# What: Run all checks, aggregate failures (§98).
# Why: one owner; per-check scope fixed.
# From: Issue #1683
ci_cmd_check_all() {
    local -a changed=()
    _ci_collect_changed changed "$@" || return 2
    local sub rc=0
    # What: diff-scoped checks see changed files.
    # Why: PR check doesn't re-scan whole repo.
    # From: Issue #1683
    local -a diff_scoped=(line-endings comment-length \
        deny-short-sha language-policy mutable-refs executable-bits \
        pipefail-early-exit if-without-else-status docker-run-heredoc-stdin \
        review-chronology governance-guards \
        changelog-direct-edit)
    for sub in "${diff_scoped[@]}"; do
        CI_SCAN_SCOPE_FILTER=1 ci_cmd_check "${sub}" "${changed[@]}" || rc=1
    done
    # What: repo-wide invariants diff can't answer.
    # Why: cross-file/state consistency every run.
    # From: Issue #1683
    local -a repo_wide=(file-headers action-node-versions naming-consistency \
        workflow-line-limit stable-external-images compose-healthchecks \
        proxy-cache-env-doc-drift \
        dependabot-docker-base-consistency \
        prebuilt-prod prod-state-wiring compose-config nats-atomic-write \
        docker-socket-proxy quickstart-required-env dhcp-proxy-env \
        setup-keys-kea setup-update-safety setup-docker-conflict setup-prompt-drift image-channel-resolution \
        vex-drift logging-matrix \
        trivy-action-direct-usage entrypoint-lib-wiring dockerfile-build-tools \
        cargo-profile-tuning no-source-compiled-tools codeql-coverage)
    for sub in "${repo_wide[@]}"; do
        ci_cmd_check "${sub}" || rc=1
    done
    # What: PR-metadata checks on real PR.
    # Why: no PR context on push.
    # From: Issue #1683
    if [ -n "${PR_NUMBER:-}" ]; then
        for sub in pr-title pr-template pr-tracking-metadata; do
            ci_cmd_check "${sub}" || rc=1
        done
    fi
    [ "${rc}" -eq 0 ] && printf 'check-all=clean\n'
    return "${rc}"
}

ci_cmd_check() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        all) ci_cmd_check_all "$@" ;;
        cargo-audit) _ci_check_cargo_audit "$@" ;;
        dockerfile-build-tools) _ci_check_dockerfile_build_tools "$@" ;;
        cargo-profile-tuning) _ci_check_cargo_profile_tuning "$@" ;;
        no-source-compiled-tools) _ci_check_no_source_compiled_tools "$@" ;;
        codeql-coverage) _ci_check_codeql_coverage "$@" ;;
        shellcheck) _ci_check_shellcheck "$@" ;;
        actionlint) _ci_check_actionlint "$@" ;;
        line-endings) _ci_check_line_endings "$@" ;;
        file-headers) _ci_check_file_headers "$@" ;;
        comment-length) _ci_check_comment_length "$@" ;;
        deny-short-sha) _ci_check_deny_short_sha "$@" ;;
        language-policy) _ci_check_language_policy "$@" ;;
        mutable-refs) _ci_check_mutable_refs "$@" ;;
        executable-bits) _ci_check_executable_bits "$@" ;;
        review-chronology) _ci_check_review_chronology "$@" ;;
        pipefail-early-exit) _ci_check_pipefail_early_exit "$@" ;;
        if-without-else-status) _ci_check_if_without_else_status "$@" ;;
        docker-run-heredoc-stdin) _ci_check_docker_run_heredoc_stdin "$@" ;;
        setup-prompt-drift) _ci_check_setup_prompt_drift "$@" ;;
        pr-title) _ci_check_pr_title "$@" ;;
        stable-external-images) _ci_check_stable_external_images "$@" ;;
        pr-template) _ci_check_pr_template "$@" ;;
        workflow-line-limit) _ci_check_workflow_line_limit "$@" ;;
        pr-tracking-metadata) _ci_check_pr_tracking_metadata "$@" ;;
        action-node-versions) _ci_check_action_node_versions "$@" ;;
        governance-guards) _ci_check_governance_guards "$@" ;;
        naming-consistency) _ci_check_naming_consistency "$@" ;;
        compose-healthchecks) _ci_check_compose_healthchecks "$@" ;;
        proxy-cache-env-doc-drift) _ci_check_proxy_cache_env_doc_drift "$@" ;;
        changelog-direct-edit) _ci_check_changelog_direct_edit "$@" ;;
        dependabot-docker-base-consistency) _ci_check_dependabot_docker_base_consistency "$@" ;;
        prebuilt-prod) _ci_check_prebuilt_prod "$@" ;;
        prod-state-wiring) _ci_check_prod_state_wiring "$@" ;;
        compose-config) _ci_check_compose_config "$@" ;;
        nats-atomic-write) _ci_check_nats_atomic_write "$@" ;;
        docker-socket-proxy) _ci_check_docker_socket_proxy "$@" ;;
        quickstart-required-env) _ci_check_quickstart_required_env "$@" ;;
        dhcp-proxy-env) _ci_check_dhcp_proxy_env "$@" ;;
        setup-keys-kea) _ci_check_setup_keys_kea "$@" ;;
        setup-update-safety) _ci_check_setup_update_safety "$@" ;;
        setup-docker-conflict) _ci_check_setup_docker_conflict "$@" ;;
        image-channel-resolution) _ci_check_image_channel_resolution "$@" ;;
        vex-drift) _ci_check_vex_drift "$@" ;;
        logging-matrix) _ci_check_logging_matrix "$@" ;;
        trivy-action-direct-usage) _ci_check_trivy_action_direct_usage "$@" ;;
        entrypoint-lib-wiring) _ci_check_entrypoint_lib_wiring "$@" ;;
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
