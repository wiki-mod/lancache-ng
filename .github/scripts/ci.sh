#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Single authoritative CI 2.0 engine.
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

# What: The SOT's repo-relative path (git refs, diffs).
# Why: base SOT reads and SOT-change detection share it.
# From: Issue #1683 | PR #1858
CI_MANIFEST_REL=".github/yaml/build-manifest.yml"

# What: Repository root (.github/scripts/../..).
# Why: Identity hashes git-tracked content from the root.
# From: Issue #1683
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)}"

# What: Path to the single source-of-truth build manifest.
# Why: One machine-readable owner for services and versions.
# From: Issue #1683
CI_MANIFEST="${CI_MANIFEST:-${CI_REPO_ROOT}/${CI_MANIFEST_REL}}"

# What: The one CI temp root; /tmp is forbidden.
# Why: /tmp is tmpfs (RAM); runners hit OOM there.
# From: Issue #1683 | PR #1858
CI_TMPDIR="${CI_TMPDIR:-/var/tmp}"

# What: The OCI digest grammar CI reads and emits.
# Why: one owner for every digest shape check and match.
# From: Issue #1683 | PR #1858
CI_DIGEST_RE='sha256:[0-9a-f]{64}'

# What: The system CA bundle path of an Alpine filesystem.
# Why: runner, build root and built image share this path.
# From: Issue #1683 | PR #1858
CI_SYSTEM_CA_PATH="/etc/ssl/certs/ca-certificates.crt"

# What: The ci.sh subcommand dispatch table.
# Why: One table is membership, dispatch and error text.
# From: Issue #1683
declare -A CI_DISPATCH=(
    [plan]=ci_cmd_plan [plan-matrix]=ci_cmd_plan_matrix [impact]=ci_cmd_impact [codeql-impact]=ci_cmd_codeql_impact [codeql-config]=ci_cmd_codeql_config [codeql-analyze]=ci_cmd_codeql_analyze [identity]=ci_cmd_identity
    [resolve]=ci_cmd_resolve [build]=ci_cmd_build [build-args]=ci_cmd_build_args [rust-build]=ci_cmd_rust_build [apk-setup]=ci_cmd_apk_setup [apk-pin-install]=ci_cmd_apk_pin_install
    [build-tools]=ci_cmd_build_tools [job-settings]=ci_cmd_job_settings [publish]=ci_cmd_publish [verify]=ci_cmd_verify [ship]=ci_cmd_ship [gha-runtime-args]=ci_cmd_gha_runtime_args
    [test]=ci_cmd_test [scan]=ci_cmd_scan [assemble]=ci_cmd_assemble
    [aggregate]=ci_cmd_aggregate [emit-result]=ci_cmd_emit_result [aggregate-stack]=ci_cmd_aggregate_stack [scan-stack]=ci_cmd_scan_stack [changed-files]=ci_cmd_changed_files
    [assemble-stack]=ci_cmd_assemble_stack [test-stack]=ci_cmd_test_stack [nightly-status]=ci_cmd_nightly_status
    [validate]=ci_cmd_validate [result-gate]=ci_cmd_result_gate [promote]=ci_cmd_promote [promote-ref]=ci_cmd_promote_ref [release-validation]=_ci_release_validation_valid [release-ref]=_ci_release_ref
    [release-publish]=ci_cmd_release_publish [release-sbom]=ci_cmd_release_sbom [release-sbom-stack]=ci_cmd_release_sbom_stack [release-vex]=ci_cmd_release_vex [cut-release-tag]=ci_cmd_cut_release_tag [release-notes]=ci_cmd_release_notes [release-changelog]=ci_cmd_release_changelog
    [gc]=ci_cmd_gc [variables]=ci_cmd_variables [socket-proxy-config]=ci_cmd_socket_proxy_config [check]=ci_cmd_check [close-linked-issues]=ci_cmd_close_linked_issues [pr-labels]=ci_cmd_pr_labels [board-add]=ci_cmd_board_add
    [welcome]=ci_cmd_welcome [version]=ci_cmd_version
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
    local okmax="$1"
    shift
    _ci_run -m "${okmax}" -s "[CI-ERROR-CORE-0106]" "reason=\"command failed or wrote stderr\"" "$@"
}

# What: run a command; failure = caller's id, ctx, rc, raw.
# Why: one owner for coded command errors and their raw.
# From: Issue #1683 | PR #1858
_ci_run() {
    local okmax=0 strict="" id ctx err out rc=0
    # What: -m N passes rc up to N; -s fails on any stderr.
    # Why: grep rc 1 is a miss; strict: warnings are errors.
    # From: Issue #1683 | PR #1858
    while :; do
        case "${1:-}" in
            -m) okmax="$2"; shift 2 ;;
            -s) strict=1; shift ;;
            *) break ;;
        esac
    done
    id="$1" ctx="$2"
    shift 2
    err="$(_ci_mktemp "${CI_TMPDIR}/ci-run.XXXXXX")" || return 2
    out="$("$@" 2>"${err}")" || rc=$?
    if [ "${rc}" -gt "${okmax}" ] || { [ -n "${strict}" ] && [ -s "${err}" ]; }; then
        ci_error "${id}" "${ctx} cmd=\"$1\" rc=${rc}" "$(cat "${err}"; [ -z "${out}" ] || printf 'stdout:\n%s\n' "${out}")"
        rm -f "${err}"
        return 2
    fi
    [ ! -s "${err}" ] || cat "${err}" >&2
    rm -f "${err}"
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: mktemp with its args; coded error, dir and raw.
# Why: one temp owner; a failure names the path it tried.
# From: Issue #1683 | PR #1858
_ci_mktemp() {
    local out
    if ! out="$(mktemp "$@" 2>&1)"; then
        ci_error "[CI-ERROR-CORE-0110]" "args=\"$*\" tmpdir=\"${CI_TMPDIR}\" reason=\"temp path not created\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: Enforce and create the /var/tmp CI temp root.
# Why: bare mktemp and tools then use disk, not tmpfs.
# From: Issue #1683 | PR #1858
_ci_tmp_init() {
    local real out base tail="" part
    # What: resolve existing part, append the missing rest
    # Why: busybox has no realpath -m; no .. or link to /tmp
    # From: Issue #1683 | PR #1858
    base="${CI_TMPDIR}"
    [[ "${base}" == /* ]] || base="${PWD}/${base}"
    while [[ ! -e "${base}" ]]; do
        part="${base##*/}" base="${base%/*}"
        base="${base:-/}"
        case "${part}" in
            ''|.) ;;
            ..) ci_log "[CI-ERROR-CORE-0142]" "dir=\"${CI_TMPDIR}\" reason=\"a missing part of the CI temp root is ..\""; return 2 ;;
            *) tail="/${part}${tail}" ;;
        esac
    done
    if ! real="$(realpath "${base}" 2>&1)"; then
        ci_error "[CI-ERROR-CORE-0131]" "dir=\"${CI_TMPDIR}\" reason=\"CI temp root not resolvable\"" "${real}"
        return 2
    fi
    real="${real%/}${tail}"
    real="${real:-/}"
    case "${real}" in
        /var/tmp|/var/tmp/*) ;;
        *) ci_log "[CI-ERROR-CORE-0006]" "reason=\"CI temp root must be under /var/tmp, not tmpfs /tmp\" got=\"${CI_TMPDIR}\" real=\"${real}\""; return 2 ;;
    esac
    if ! out="$(mkdir -p "${real}" 2>&1)"; then
        ci_error "[CI-ERROR-CORE-0111]" "dir=\"${real}\" reason=\"CI temp root not created\"" "${out}"
        return 2
    fi
    CI_TMPDIR="${real}"
    export TMPDIR="${real}"
}

# What: true on a self-hosted runner (RUNNER_ENVIRONMENT).
# Why: LAN proxy and Redis exist on self-hosted only.
# From: Issue #1683 | PR #1858
_ci_runner_self_hosted() {
    [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ]
}

# What: Export the LAN proxy on self-hosted runners only.
# Why: AG-CI-009 proxy; hosted runners have no LAN route.
# From: Issue #1683 | PR #1858
_ci_proxy_init() {
    local http="${PROJECT_SELFHOSTED_PROXY_HTTP:-}"
    if ! _ci_runner_self_hosted || [ -z "${http}" ]; then
        ci_log "[CI-INFO-CORE-0113]" "proxy=off runner=\"${RUNNER_ENVIRONMENT:-unset}\" http_set=$([ -n "${http}" ] && echo yes || echo no)"
        return 0
    fi
    export HTTP_PROXY="${http}" http_proxy="${http}"
    export HTTPS_PROXY="${PROJECT_SELFHOSTED_PROXY_HTTPS:-${http}}"
    export https_proxy="${HTTPS_PROXY}"
    export NO_PROXY="${PROJECT_SELFHOSTED_PROXY_EXCLUSION:-}" no_proxy="${PROJECT_SELFHOSTED_PROXY_EXCLUSION:-}"
    ci_log "[CI-INFO-CORE-0007]" "proxy=on runner=self-hosted no_proxy=\"${NO_PROXY}\""
    if [ -z "${PROJECT_SELFHOSTED_PROXY_CA:-}" ]; then
        ci_log "[CI-INFO-CORE-0114]" "proxy_ca=off reason=\"PROJECT_SELFHOSTED_PROXY_CA empty\""
        return 0
    fi
    local bundle
    bundle="$(_ci_ca_bundle "[CI-ERROR-CORE-0112]" "${CI_SYSTEM_CA_PATH}" "${PROJECT_SELFHOSTED_PROXY_CA}")" || return 2
    export CARGO_HTTP_CAINFO="${bundle}" CURL_CA_BUNDLE="${bundle}"
    ci_log "[CI-INFO-CORE-0115]" "proxy_ca=on bundle=\"${bundle}\""
}

# What: job-local bundle = system CAs + proxy CA, mode 600.
# Why: tools pass the TLS proxy; never baked into an image.
# From: Issue #1683 | PR #1858
_ci_ca_bundle() {
    local id="$1" sys="$2" ca="$3" bundle out
    bundle="$(umask 077 && _ci_mktemp "${CI_TMPDIR}/ci-ca-bundle.XXXXXX")" || return 2
    if ! out="$({ cat "${sys}" && printf '%s\n' "${ca}"; } 2>&1 > "${bundle}")"; then
        ci_error "${id}" "system_bundle=\"${sys}\" bundle=\"${bundle}\" reason=\"proxy CA bundle not built\"" "${out}"
        return 2
    fi
    printf '%s\n' "${bundle}"
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

# What: SOT store: <prefix><kind letter>:<path> -> data.
# Why: a SOT is parsed once per owning shell, not per field.
# From: Issue #1683 | PR #1858
declare -gA _CI_SOT=() _CI_SOT_LOADED=()
_CI_SOT_SEQ=0

# What: jq over yq's SOT JSON: index lines for one eval.
# Why: one YAML parser (yq); readers then only look up.
# From: Issue #1683 | PR #1858
_CI_JQ_SOT_INDEX='
    def nodes($pre): to_entries[] | ($pre + [.key]) as $p
        | {p: $p, v: .value}, (if (.value | type) == "object" then .value | nodes($p) else empty end);
    def scal: if type == "string" then . elif . == null then "" else tojson end;
    def sq: @sh;
    def keep($s): $want == "" or $s == $want or ($s | startswith($want + "/"));
    def put($k; $v): "[" + (($kp + $k) | sq) + "]=" + ($v | sq);
    [nodes([]) | .s = (.p | join("/")) | .par = (.p[:-1] | join("/")) | .last = .p[-1]
        | .kind = (if (.v | type) == "object" then "c" elif (.v | type) == "array" then "l" else "s" end)] as $n
    | ($n[] | select(keep(.s)) | (if .kind == "s" then (.v | scal) else "" end) as $val
        | put("k:" + .s; .kind), put("r:" + .s; $val), put("v:" + .s; $val)),
      (reduce $n[] as $x ({};
            .c[$x.par] += $x.last + "\n"
            | (if $x.kind == "c" then .b[$x.par] += $x.last + "\n" else . end)
            | (if ($x.v | type) == "array" and ($x.v | length) > 0
                then .i[$x.s] = ($x.v | map(scal + "\n") | add) else . end)
            | reduce range(2; [4, ($x.p | length)] | min) as $d (.;
                (($x.p[:$d] | join("/")) + "/" + $x.last) as $a
                | .f[$a] //= $x.s | .a[$a] += $x.s + "\n"))
        | to_entries[] | .key as $t | .value | to_entries[] | select(keep(.key)) | put($t + ":" + .key; .value))'

# What: index a SOT file, or one subtree, under a prefix.
# Why: one yq parse and one eval; raw logged by _ci_run.
# From: Issue #1683 | PR #1858
_ci_sot_index() {
    local json idx
    if ! json="$(_ci_run -s "[CI-ERROR-CORE-0139]" "file=\"$1\" reason=\"yq cannot read the SOT\"" yq -o=json '.' "$1")" \
        || ! idx="$(_ci_run -s "[CI-ERROR-CORE-0141]" "file=\"$1\" reason=\"SOT index not built\"" \
            jq -r --arg want "$2" --arg kp "$3" "${_CI_JQ_SOT_INDEX}" <<< "${json}")"; then
        _CI_SOT_RAW_ERR="raw in the CORE-0139/0141 line above"
        return 2
    fi
    eval "_CI_SOT+=(${idx})"
}

# What: index the SOT into the shared store of this shell.
# Why: owners of CI_MANIFEST load once; readers look up.
# From: Issue #1683 | PR #1858
_ci_sot_load() {
    local file="${1:-${CI_MANIFEST}}" kp
    unset '_CI_SOT_LOADED[$file]'
    _CI_SOT_SEQ=$((_CI_SOT_SEQ + 1))
    kp="${file}"$'\037'"${_CI_SOT_SEQ}"$'\037'
    if ! _ci_sot_index "${file}" "" "${kp}"; then
        ci_error "[CI-ERROR-CORE-0136]" "manifest=\"${file}\" reason=\"SOT unreadable; not indexed\"" "${_CI_SOT_RAW_ERR}"
        return 2
    fi
    _CI_SOT_LOADED["${file}"]="${kp}"
}

# What: prefix of the shared index, else one fresh subtree.
# Why: a miss reads only what it needs, never as shared.
# From: Issue #1683 | PR #1858
_ci_sot_view() {
    local -n _ci_vk="$2"
    _ci_vk="${_CI_SOT_LOADED[${CI_MANIFEST}]:-}"
    [ -z "${_ci_vk}" ] || return 0
    _CI_SOT_SEQ=$((_CI_SOT_SEQ + 1))
    _ci_vk="${CI_MANIFEST}"$'\037'"m${_CI_SOT_SEQ}"$'\037'
    _ci_sot_index "${CI_MANIFEST}" "$1" "${_ci_vk}"
}

# What: List direct child keys under a top-level block.
# Why: One SOT index from yq; no per-block parser.
# From: Issue #1683 | PR #1858
_ci_block_keys() {
    local block="$1" mode="${2:-blocks}" kp t=b
    if ! _ci_sot_view "${block}" kp; then
        ci_error "[CI-ERROR-CORE-0109]" "block=\"${block}\" mode=\"${mode}\" manifest=\"${CI_MANIFEST}\" reason=\"SOT keys unreadable\"" "${_CI_SOT_RAW_ERR}"
        return 2
    fi
    # What: mode "all" also lists scalar keys (key: value).
    # Why: base_images holds values, not nested blocks.
    # From: Issue #1683 | PR #1858
    [ "${mode}" != all ] || t=c
    printf '%s' "${_CI_SOT["${kp}${t}:${block}"]:-}"
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
    ci_services || return 2
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

# =========================================================
# SEMANTIC PARSERS
# =========================================================

# What: Print one field of a block entry.
# Why: One SOT index, no per-block duplicate.
# From: Issue #1683 | PR #1858
_ci_block_entry_field() {
    local block="$1" entry="$2" field="$3" kp p="" ctx
    ctx="block=\"${block}\" entry=\"${entry}\" field=\"${field}\" manifest=\"${CI_MANIFEST}\" reason=\"SOT field unreadable\""
    if ! _ci_sot_view "${block}${entry:+/${entry}}" kp; then
        ci_error "[CI-ERROR-CORE-0107]" "${ctx}" "${_CI_SOT_RAW_ERR}"
        return 2
    fi
    # What: entry="" reads a block-level scalar.
    # Why: base_images has no entry level; one reader.
    # From: Issue #1683 | PR #1858
    if [ -z "${entry}" ]; then
        [ "${_CI_SOT["${kp}k:${block}"]:-}" != c ] || p="${block}/${field}"
    elif [ "${_CI_SOT["${kp}k:${block}/${entry}"]:-}" = c ]; then
        p="${_CI_SOT["${kp}f:${block}/${entry}/${field}"]:-}"
    fi
    [ -n "${p}" ] && [ -n "${_CI_SOT["${kp}k:${p}"]+set}" ] || return 0
    [ -z "${_CI_SOT["${kp}v:${p}"]}" ] || printf '%s\n' "${_CI_SOT["${kp}v:${p}"]}"
}

# What: Print a block->entry->field list, one item per line.
# Why: One list reader; inline [..] and block - items alike.
# From: Issue #1683
_ci_block_entry_list() {
    local block="$1" entry="$2" field="$3" kp node ctx
    ctx="block=\"${block}\" entry=\"${entry}\" field=\"${field}\" manifest=\"${CI_MANIFEST}\" reason=\"SOT list unreadable\""
    # What: entry="" reads a 2-level block->field list.
    # Why: build_matrix has no entry level; one reader.
    # From: Issue #1683 | PR #1858
    node="${block}${entry:+/${entry}}"
    if ! _ci_sot_view "${node}" kp; then
        ci_error "[CI-ERROR-CORE-0108]" "${ctx}" "${_CI_SOT_RAW_ERR}"
        return 2
    fi
    [ "${_CI_SOT["${kp}k:${node}"]:-}" = c ] || return 0
    printf '%s' "${_CI_SOT["${kp}i:${node}/${field}"]:-}"
}

# What: Query a service field (services or build_toolchain).
# Why: build-tools uses same reader, not a services entry.
# From: Issue #1683
ci_service_field() {
    local v
    v="$(_ci_block_entry_field "services" "$1" "$2")" || return 2
    [ -n "${v}" ] && { printf '%s\n' "${v}"; return 0; }
    _ci_block_entry_field "build_toolchain" "$1" "$2"
}

# What: read a required target field; empty is an error.
# Why: no hidden defaults; the SOT must name every field.
# From: Issue #1683
_ci_required_field() {
    local v
    v="$(ci_service_field "$1" "$2")" || return 2
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

# What: a target's SOT list (services or build_toolchain).
# Why: one lookup rule for every target-scoped list.
# From: Issue #1683 | PR #1858
_ci_target_list() {
    local out
    out="$(_ci_block_entry_list services "$1" "$2")" || return 2
    [ -n "${out}" ] || out="$(_ci_block_entry_list build_toolchain "$1" "$2")" || return 2
    [ -z "${out}" ] || printf '%s\n' "${out}"
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
    local service="$1" out global p
    out="$(_ci_target_list "${service}" platforms)" || return 2
    global="$(_ci_build_matrix_platforms)" || return 2
    if [ -n "${out}" ]; then
        # What: override must be a strict matrix subset.
        # Why: a foreign or full override drifts from SOT.
        # From: Issue #1683 | PR #1858
        while IFS= read -r p; do
            grep -qxF -- "${p}" <<< "${global}" && continue
            ci_log "[CI-ERROR-CORE-0126]" "service=\"${service}\" platform=\"${p}\" reason=\"override platform not in build_matrix\""
            return 2
        done <<< "${out}"
        if [ "$(sort <<< "${out}")" = "$(sort <<< "${global}")" ]; then
            ci_log "[CI-ERROR-CORE-0127]" "service=\"${service}\" reason=\"override equals build_matrix; drop the override\""
            return 2
        fi
    else
        out="${global}"
    fi
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
    plats="$(_ci_platforms "${service}")" || return 2
    while IFS= read -r p; do
        [ "${p}" = "${platform}" ] && return 0
    done <<< "${plats}"
    return 1
}

# What: platform SOT field; unset logs caller id + reason.
# Why: a read error is logged once, by the reader.
# From: Issue #1683 | PR #1858
_ci_platform_field() {
    local platform="$1" field="$2" id="$3" ctx="${4:-}" val
    val="$(_ci_block_entry_field platform_arch "${platform##*/}" "${field}")" || return 2
    if [ -z "${val}" ]; then
        ci_log "${id}" "platform=\"${platform}\" field=\"${field}\" ${ctx}"
        return 2
    fi
    printf '%s\n' "${val}"
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
    raw="$(_ci_changed_files "$@" 2>&1)" || { ci_error "[CI-ERROR-CORE-0008]" "changed_files=\"${CHANGED_FILES:-}\" args=$# reason=\"changed-file list unreadable\"" "${raw}"; return 2; }
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
    local context ctx ctx_path ctxs
    context="$(_ci_required_field "${service}" context)" || return 2
    _ci_paths_touch "${context}" "$@" && return 0
    ctxs="$(ci_service_contexts "${service}")" || return 2
    for ctx in ${ctxs}; do
        ctx_path="$(ci_context_path "${ctx}")" || return 2
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

    local service rc targets
    targets="$(ci_build_targets)" || return 2
    for service in ${targets}; do
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
    if [ -z "${base}" ]; then
        ci_log "[CI-INFO-IMPACT-0012]" "path=\"${path}\" reason=\"no base ref for this event; content counts as changed\""
        return 0
    fi
    a="$(_ci_tracked_content_ids "${path}" "${base}")" || return 2
    b="$(_ci_tracked_content_ids "${path}" "${head}")" || return 2
    [ "${a}" != "${b}" ]
}

# What: CodeQL admission: the admitted language matrix.
# Why: §70: no runner without an admitted language.
# From: Issue #1683 | PR #1858
ci_cmd_codeql_impact() {
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
    printf 'codeql-matrix={"include":%s}\n' "${include}"
    ci_log "[CI-INFO-CODEQL-0001]" "phase=codeql-impact langs=$(printf '%s' "${include}" | jq -r 'length') changed=${#changed[@]}"
}

# What: print "key:" and each line as a quoted YAML item.
# Why: **/x would be an alias; pure bash, no jq needed.
# From: Issue #1683 | PR #1858
_ci_yaml_list() {
    local key="$1" prefix="$2" items="$3" v out=""
    while IFS= read -r v; do
        [ -n "${v}" ] || continue
        if [[ "${v}" == *[[:cntrl:]]* ]]; then
            ci_error "[CI-ERROR-CODEQL-0015]" "key=\"${key}\" reason=\"control character in a YAML list value\"" "$(printf '%q' "${v}")"
            return 2
        fi
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
        out+=$'\n'"${prefix}\"${v}\""
    done <<< "${items}"
    printf '%s:%s' "${key}" "${out}"
}

# What: Render the CodeQL config file from the SOT.
# Why: SOT owns scope; the action reads a derived config.
# From: Issue #1683
ci_cmd_codeql_config() {
    local lang repo queries langs paths ignore out all="" q
    repo="$(_ci_repo)" || return 2
    queries="$(_ci_block_entry_list codeql "" queries)" || return 2
    langs="$(_ci_block_keys codeql_languages)" || return 2
    ignore="$(_ci_block_entry_list codeql "" paths_ignore)" || return 2
    while IFS= read -r lang; do
        [ -n "${lang}" ] || continue
        paths="$(_ci_block_entry_list codeql_languages "${lang}" paths)" || return 2
        all+="${paths}"$'\n'
    done <<< "${langs}"
    out="name: ${repo##*/}-codeql"$'\n'
    q="$(_ci_yaml_list queries '  - uses: ' "${queries}")" || return 2
    out+="${q}"$'\n'
    q="$(_ci_yaml_list paths '  - ' "${all}")" || return 2
    out+="${q}"$'\n'
    q="$(_ci_yaml_list paths-ignore '  - ' "${ignore}")" || return 2
    out+="${q}"$'\n'
    printf '%s' "${out}"
}

# What: Download one URL to a file (curl -f).
# Why: one curl call that _ci_retry can classify.
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
    if ! _ci_retry download _ci_http_download "${url}" "${dest}" >/dev/null; then
        ci_log "[CI-ERROR-FETCH-0002]" "url=\"${url}\" reason=\"download failed\""
        _ci_fetch_drop "${dest}"
        return 2
    fi
    if ! raw="$(printf '%s  %s\n' "${sha}" "${dest}" | sha256sum -c - 2>&1)"; then
        ci_error "[CI-ERROR-FETCH-0003]" "url=\"${url}\" reason=\"sha256 differs from the pin; FAIL CLOSED\"" "${raw}"
        _ci_fetch_drop "${dest}"
        return 2
    fi
}

# What: remove an unverified download; a failed rm is coded.
# Why: dest may be trusted, e.g. the apk keys dir.
# From: Issue #1683 | PR #1858
_ci_fetch_drop() {
    local out
    if ! out="$(rm -f -- "$1" 2>&1)"; then
        ci_error "[CI-ERROR-FETCH-0004]" "dest=\"$1\" reason=\"unverified download not removed\"" "${out}"
    fi
}

# What: Fetch the SOT-pinned CodeQL bundle; print binary.
# Why: SOT owns tag+sha256; no action pin in the YAML.
# From: Issue #1683 | PR #1858
_ci_codeql_fetch() {
    local work="$1" repo tag asset url raw sha
    repo="$(_ci_block_entry_field external_versions codeql repository)" || return 2
    tag="$(_ci_block_entry_field external_versions codeql release_tag)" || return 2
    asset="$(_ci_block_entry_field external_versions codeql asset)" || return 2
    sha="$(_ci_block_entry_field external_versions codeql sha256)" || return 2
    if [ -z "${repo}" ] || [ -z "${tag}" ] || [ -z "${asset}" ]; then
        ci_log "[CI-ERROR-CODEQL-0005]" "key=\"external_versions.codeql\" reason=\"repository/release_tag/asset missing; FAIL CLOSED\""
        return 2
    fi
    url="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    url="${url}/${repo}/releases/download/${tag}/${asset}"
    _ci_fetch_verified "${url}" "${sha}" "${work}/${asset}" || return 2
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
    local lang="$1" work="$2" codeql raw java
    local cfg
    # What: CodeQL runs on the JVM of the java on PATH.
    # Why: its bundled JVM needs glibc; build-tools is musl.
    # From: Issue #1683 | PR #1858
    if ! java="$(command -v java)"; then
        ci_error "[CI-ERROR-CODEQL-0017]" "language=\"${lang}\" reason=\"no java on PATH for the CodeQL CLI\"" "PATH=${PATH}"
        return 2
    fi
    if ! raw="$(readlink -f "${java}" 2>&1)" || [ "${raw%/bin/java}" = "${raw}" ]; then
        ci_error "[CI-ERROR-CODEQL-0018]" "language=\"${lang}\" java=\"${java}\" reason=\"java is not <home>/bin/java\"" "${raw}"
        return 2
    fi
    local -x CODEQL_JAVA_HOME="${raw%/bin/java}"
    codeql="$(_ci_codeql_fetch "${work}")" || return 2
    cfg="$(ci_cmd_codeql_config)" || return 2
    if ! raw="$(printf '%s' "${cfg}" 2>&1 > "${work}/config.yml")"; then
        ci_error "[CI-ERROR-CODEQL-0016]" "language=\"${lang}\" file=\"${work}/config.yml\" reason=\"CodeQL config not written\"" "${raw}"
        return 2
    fi
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
    local langs
    langs="$(_ci_block_keys codeql_languages)" || return 2
    if ! grep -qx -- "${lang}" <<< "${langs}"; then
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
    work="$(_ci_mktemp -d "${CI_TMPDIR}/codeql.XXXXXX")" || return 2
    if _ci_codeql_run "${lang}" "${work}"; then rc=0; else rc=$?; fi
    rm -rf "${work}"
    return "${rc}"
}

# What: every path the SOT names as an input, one per line.
# Why: a doc the SOT reads is an input, never a NOOP doc.
# From: Issue #1683 | PR #1858
_ci_sot_named_paths() {
    local names n v
    names="$(_ci_block_keys ci_variables all)" || return 2
    while IFS= read -r n; do
        [ -n "${n}" ] || continue
        v="$(_ci_variable "${n}")" || return 2
        printf '%s\n' "${v}"
    done <<< "${names}"
    v="$(_ci_block_entry_field release "" validation_state)" || return 2
    printf '%s\n' "${v}"
    _ci_block_entry_list release "" governance_paths || return 2
}

# What: rc 0 if every path is a doc no SOT key names.
# Why: docs are NOOP (§63) unless an input (§12.4).
# From: Issue #1683 | PR #1858
_ci_docs_only() {
    [ "$#" -gt 0 ] || return 1
    local f named docs
    named="$(_ci_sot_named_paths)" || return 2
    docs="$(_ci_variable CI_DOCS_DIR)" || return 2
    for f in "$@"; do
        case "${f}" in
            *.md|"${docs}"/*) ;;
            *) return 1 ;;
        esac
        if grep -qxF -- "${f}" <<< "${named}"; then
            ci_log "[CI-INFO-PLAN-0007]" "path=\"${f}\" reason=\"doc is a SOT-named input; not docs-only\""
            return 1
        fi
    done
    return 0
}

# What: Emit a resolve-filtered matrix to GITHUB_OUTPUT.
# Why: Base-CI builds only what identity proves needs work.
# From: Issue #1683
ci_cmd_plan_matrix() {
    local out
    out="$(_ci_env_required GITHUB_OUTPUT)" || return 2
    local -a changed=()
    _ci_collect_changed changed "$@" || return 2
    local docs_only=false drc=0
    _ci_docs_only "${changed[@]}" || drc=$?
    case "${drc}" in 0) docs_only=true ;; 1) ;; *) return 2 ;; esac
    local service platform include='[]' any=false resolved paction runner authed=false test_services=''
    local sot_changed=false f path_cand rc plats
    # What: SOT change makes every target id candidate.
    # Why: pins live in SOT; identity decides BUILD.
    # From: Issue #1683 | PR #1858
    for f in "${changed[@]}"; do [ "${f}" = "${CI_MANIFEST_REL}" ] && sot_changed=true; done
    # What: audit only when the lockfile changed.
    # Why: any other change leaves the audit result as is.
    # From: Issue #1683 | PR #1858
    local rust_audit=false lock
    lock="$(_ci_variable CI_CARGO_LOCK)" || return 2
    for f in "${changed[@]}"; do [ "${f}" = "${lock}" ] && rust_audit=true; done
    # What: build product services and the toolchain.
    # Why: build-tools generic pipeline, separate assembly.
    # From: Issue #1683
    local targets svc_type
    targets="$(ci_build_targets)" || return 2
    for service in ${targets}; do
        path_cand=false rc=0
        _ci_plan_candidate "${service}" "${changed[@]}" || rc=$?
        case "${rc}" in 0) path_cand=true ;; 1) ;; *) return 2 ;; esac
        [ "${path_cand}" = true ] || [ "${sot_changed}" = true ] || continue
        # What: path-changed rust is test candidate (§60).
        # Why: tests run on change, even build reuse (§60).
        # From: Issue #1683
        svc_type="$(ci_service_field "${service}" build_type)" || return 2
        [ "${path_cand}" = true ] && [ "${svc_type}" = rust ] \
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
            runner="$(_ci_platform_field "${platform}" runner "[CI-ERROR-PLAN-0002]" "service=\"${service}\" reason=\"no runner label for platform\"")" || return 2
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
    # What: promote a ref target not yet on the candidate
    # Why: §50 needs no build; §8: no retag when current
    # From: Issue #1683 | PR #1858
    local promote=false validate ptargets t cand
    ptargets="$(_ci_promote_targets_for_ref)" || return 2
    if [ -n "${ptargets}" ]; then
        promote=true
        if [ "${any}" = false ]; then
            if [ "${authed}" = false ]; then
                _ci_require_ghcr_auth || return "$?"
                authed=true
            fi
            if cand="$(_ci_stack_candidate --with-toolchain)"; then
                promote=false
                while IFS= read -r t; do
                    [ -n "${t}" ] || continue
                    _ci_promote_all_current "${t}" "${cand}" || { promote=true; break; }
                done <<< "${ptargets}"
            fi
        fi
    fi
    validate="${any}"
    [ "${promote}" = false ] || validate=true
    {
        printf 'any-build=%s\n' "${any}"
        printf 'promote=%s\n' "${promote}"
        printf 'validate=%s\n' "${validate}"
        printf 'matrix={"include":%s}\n' "${include}"
        printf 'test-services=%s\n' "${test_services# }"
        printf 'rust-validation=%s\n' "${rust_validation}"
        printf 'rust-audit=%s\n' "${rust_audit}"
        printf 'docs-only=%s\n' "${docs_only}"
    } >> "${out}"
}

# =========================================================
# IDENTITY ENGINE
# =========================================================

# What: the v1 normalizer grammar of a path; rc 1 = raw.
# Why: A§12.5 v1 drops comment and blank lines (Test B/C).
# From: Issue #1683 | PR #1858
_ci_norm_grammar() {
    case "${1##*/}" in
        *.rs) printf 'rust\n' ;;
        *.sh|*.bash|*.bats) printf 'shell\n' ;;
        Dockerfile|Dockerfile.*|*.Dockerfile) printf 'dockerfile\n' ;;
        *) return 1 ;;
    esac
}

# What: v1 form of $2 in grammar $1; rc 1 = unsafe, use raw.
# Why: string and heredoc lines stay; any doubt keeps raw.
# From: Issue #1683 | PR #1858
_ci_norm_content() {
    local out rc=0
    out="$(awk -v g="$1" '
        function heredoc(l,   w, pre) {
            while (match(l, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
                pre = (RSTART > 1) ? substr(l, RSTART - 1, 1) : ""
                w = substr(l, RSTART, RLENGTH)
                l = substr(l, RSTART + RLENGTH)
                if (pre == "<") continue
                tab = (w ~ /^<<-/)
                sub(/^<<-?[[:space:]]*/, "", w)
                gsub(/[\047"]/, "", w)
                hd = w
            }
        }
        function lex(l,   i, n, c) {
            n = length(l)
            for (i = 1; i <= n; i++) {
                c = substr(l, i, 1)
                if (q == "s") { if (c == "\047") q = ""; continue }
                if (q != "" && c == "\\") { i++; continue }
                if (q == "a") { if (c == "\047") q = ""; continue }
                if (c == "`") { ticks++; if (q == "d") bad = 1 }
                if (substr(l, i, 2) == "$(") { if (q == "d") { subst++; bad = 1 } i++; continue }
                if (c == ")" && subst) subst--
                if (q == "d") { if (c == "\"") q = ""; continue }
                if (c == "\\") { i++; continue }
                if (c == "\047") { q = (i > 1 && substr(l, i - 1, 1) == "$") ? "a" : "s"; continue }
                if (c == "\"") { q = "d"; continue }
                if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[[:space:];|&()]/)) return
                if (substr(l, i, 2) == "<<") { heredoc(substr(l, i)); i++ }
            }
        }
        { sub(/\r$/, "") }
        hd != "" {
            t = $0
            if (tab) sub(/^\t+/, "", t)
            print
            if (t == hd) hd = ""
            next
        }
        g == "rust" {
            s = $0
            if ($0 ~ /r#*"/ || gsub(/"/, "", s) % 2 == 1) exit 1
            if ($0 !~ /^[[:space:]]*(\/\/|$)/) print
            next
        }
        g == "dockerfile" {
            k = $0
            if (!past && sub(/^#[[:space:]]*/, "", k) && sub(/[[:space:]]*=.*/, "", k) \
                && tolower(k) ~ /^(syntax|escape|check)$/) { print; next }
            past = 1
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            heredoc($0)
            print
            next
        }
        g == "shell" {
            if (FNR == 1 && $0 ~ /^#!/) { print; next }
            if (q == "" && $0 ~ /^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]/) { print; next }
            if (q == "" && $0 ~ /^[[:space:]]*(#|$)/) next
            lex($0)
            if (subst || ticks % 2 || (bad && q != "")) exit 1
            subst = 0; ticks = 0; bad = 0
            print
            next
        }
        { exit 3 }
        END { if (q != "" || hd != "") exit 1 }
    ' <<< "$2" 2>&1)" || rc=$?
    case "${rc}" in
        0) printf '%s\n' "${out}" ;;
        1) return 1 ;;
        *)
            ci_error "[CI-ERROR-IDENTITY-0008]" "grammar=\"$1\" rc=${rc} reason=\"v1 normalizer failed\"" "${out}"
            return 2
            ;;
    esac
}

# What: one git call for the identity; stderr is an error.
# Why: a failed id read must name path, ref and git's text.
# From: Issue #1683 | PR #1858
_ci_identity_git() {
    local path="$1" ref="$2" out
    shift 2
    if ! out="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git "$@")"; then
        ci_log "[CI-ERROR-IDENTITY-0007]" "path=\"${path}\" ref=\"${ref}\" git=\"$1\" repo=\"${CI_REPO_ROOT}\" reason=\"identity input not readable (raw above)\""
        return 2
    fi
    printf '%s' "${out}"
}

# What: Emit path-keyed content ids of tracked files.
# Why: Content, not raw bytes or order, is the input.
# From: Issue #1683
_ci_tracked_content_ids() {
    local root="$1" ref="${2:-}" raw listing line path oid blob norm empty g nrc
    # What: git pathspec selects files in both modes alike.
    # Why: ls-tree ignores globs; diff-tree honours them.
    # From: Issue #1683
    if [ -n "${ref}" ]; then
        empty="$(_ci_identity_git "${root}" "${ref}" hash-object -t tree /dev/null)" || return 2
        raw="$(_ci_identity_git "${root}" "${ref}" diff-tree -r --raw "${empty}" "${ref}" -- "${root}")" || return 2
        listing="$(_ci_capture 0 awk -F'\t' 'NF { split($1, a, " "); print $2 "\t" a[4] }' <<< "${raw}")" || return 2
    else
        raw="$(_ci_identity_git "${root}" "" ls-files -s -- "${root}")" || return 2
        listing="$(_ci_capture 0 awk -F'\t' 'NF { split($1, a, " "); print $2 "\t" a[2] }' <<< "${raw}")" || return 2
    fi
    listing="$(LC_ALL=C _ci_capture 0 sort <<< "${listing}")" || return 2
    [ -n "${listing}" ] || return 0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        path="${line%%$'\t'*}"
        oid="${line#*$'\t'}"
        if g="$(_ci_norm_grammar "${path}")"; then
            blob="$(_ci_identity_git "${path}" "${ref}" cat-file blob "${oid}")" || return 2
            nrc=0
            norm="$(_ci_norm_content "${g}" "${blob}")" || nrc=$?
            case "${nrc}" in
                0)
                    norm="$(_ci_capture 0 sha256sum <<< "${norm}")" || return 2
                    printf '%s\t%s\n' "${path}" "${norm%% *}"
                    continue
                    ;;
                1) ;;
                *) return 2 ;;
            esac
        fi
        printf '%s\t%s\n' "${path}" "${oid}"
    done <<< "${listing}"
}

# What: print the image_base list of a field, then $2.
# Why: every image extends one base; no per-image copies.
# From: Issue #1683 | PR #1858
_ci_image_base_plus() {
    local field="$1" own="$2" base
    base="$(_ci_block_entry_list image_base "" "${field}")" || return 2
    printf '%s\n%s\n' "${base}" "${own}" | awk 'NF && !seen[$0]++'
}

# What: base, a service's own and its type's apk lists.
# Why: image and identity must see one and the same list.
# From: Issue #1683 | PR #1858
_ci_service_packages() {
    local service="$1" own build_type runtime
    own="$(_ci_target_list "${service}" packages)" || return 2
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    runtime="$(_ci_block_entry_list build_runtime "${build_type}" packages)" || return 2
    _ci_image_base_plus packages "${own}"$'\n'"${runtime}"
}

# What: base, own and build-type smoke checks of a service.
# Why: one rule per build type; @CRATE@ = the service crate.
# From: Issue #1683 | PR #1858
_ci_service_smoke() {
    local service="$1" own build_type runtime crate
    own="$(_ci_block_entry_list services "${service}" smoke)" || return 2
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    runtime="$(_ci_block_entry_list build_runtime "${build_type}" smoke)" || return 2
    if [[ "${runtime}" == *@CRATE@* ]]; then
        crate="$(_ci_required_field "${service}" crate)" || return 2
        runtime="${runtime//@CRATE@/${crate}}"
    fi
    _ci_image_base_plus smoke "${own}"$'\n'"${runtime}"
}

# What: Print each SOT build_identity input of a type.
# Why: SOT names the inputs; the build must match the id.
# From: Issue #1683 | PR #1858
_ci_identity_pins() {
    local service="$1" build_type="$2" platform="$3" inputs input pkgs base arch
    inputs="$(_ci_block_entry_list build_identity "${build_type}" inputs)" || return 2
    if [ -z "${inputs}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0004]" "build_type=\"${build_type}\" reason=\"no SOT build_identity inputs; FAIL CLOSED\""
        return 2
    fi
    for input in ${inputs}; do
        printf 'input=%s\n' "${input}"
        case "${input}" in
            source_sha) : ;;
            build_variables) _ci_build_variable_args "${build_type}" || return 2 ;;
            toolchain_digest|toolchain_source_sha) _ci_build_tools_resolve_signature || return 2 ;;
            base_digest)
                if [ "${build_type}" = toolchain ]; then
                    _ci_build_tools_build_args --bare "${platform}" || return 2
                else
                    _ci_service_build_args "${service}" --bare "${platform}" no || return 2
                fi
                ;;
            package_versions)
                pkgs="$(_ci_service_packages "${service}")" || return 2
                pkgs="$(tr '\n' ' ' <<<"${pkgs}")"
                [ -n "${pkgs// /}" ] || continue
                base="$(_ci_alpine_image "[CI-ERROR-IDENTITY-0009]" "service=\"${service}\" key=\"base_images.alpine\" reason=\"no alpine base to resolve package versions; FAIL CLOSED\"")" || return 2
                arch="$(_ci_platform_field "${platform}" apk "[CI-ERROR-IDENTITY-0005]" "service=\"${service}\" reason=\"no apk arch; FAIL CLOSED\"")" || return 2
                local repos keys
                repos="$(_ci_apk_repositories "${service}")" || return 2
                keys="$(_ci_apk_keys "${service}")" || return 2
                _ci_apk_resolve "${base}" "${arch}" "${pkgs% }" "${repos}" "${keys}" || return 2
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
    local build_type context ctx ctx_path ctxs pins part buf
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    context="$(_ci_required_field "${service}" context)" || return 2
    # What: every id input is captured and checked first.
    # Why: a failed part in a hash pipe mints a wrong id.
    # From: Issue #1683 | PR #1858
    pins="$(_ci_identity_pins "${service}" "${build_type}" "${platform}")" || return "$?"
    buf="$(printf 'service=%s\nbuild_type=%s\nplatform=%s' "${service}" "${build_type}" "${platform}")"$'\n'
    part="$(_ci_tracked_content_ids "${context}" "${ref}")" || return 2
    [ -z "${part}" ] || buf+="${part}"$'\n'
    ctxs="$(ci_service_contexts "${service}")" || return 2
    for ctx in ${ctxs}; do
        ctx_path="$(ci_context_path "${ctx}")" || return 2
        [ -n "${ctx_path}" ] || continue
        part="$(_ci_tracked_content_ids "${ctx_path}" "${ref}")" || return 2
        [ -z "${part}" ] || buf+="${part}"$'\n'
    done
    buf+="${pins}"$'\n'
    printf '%s' "${buf}" | sha256sum | cut -d' ' -f1
}

# What: one_fn service platform [args] per (one) platform.
# Why: one fanout and platform check for every command.
# From: Issue #1683
_ci_for_platforms() {
    local service="$1" platform="$2" invalid_id="$3" one_fn="$4" p plats
    shift 4
    if [ -n "${platform}" ]; then
        local vrc=0
        _ci_valid_platform "${service}" "${platform}" || vrc=$?
        case "${vrc}" in
            0) ;;
            1) ci_log "${invalid_id}" "service=\"${service}\" reason=\"platform not in target set\" got=\"${platform}\""; return 2 ;;
            *) return 2 ;;
        esac
        "${one_fn}" "${service}" "${platform}" "$@"
        return "$?"
    fi
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        "${one_fn}" "${service}" "${p}" "$@" || return "$?"
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
    local ref="$1" dest="$2" body out
    body="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git show "${ref}:${CI_MANIFEST_REL}")" || return 2
    if ! out="$(printf '%s\n' "${body}" 2>&1 > "${dest}")"; then
        ci_error "[CI-ERROR-IMPACT-0011]" "ref=\"${ref}\" dest=\"${dest}\" reason=\"base SOT not written\"" "${out}"
        return 2
    fi
    _ci_sot_load "${dest}"
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
    local t="$1" p="$2" hid="$3" base="$4" base_manifest="$5" bid rc=0
    if [ -z "${hid}" ]; then
        ci_log "[CI-INFO-IMPACT-0009]" "service=\"${t}\" platform=\"${p}\" reason=\"no head identity; UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
    bid="$(CI_MANIFEST="${base_manifest}" _ci_identity_for "${t}" "${p}" "${base}")" || rc=$?
    if [ "${rc}" -ne 0 ] || [ -z "${bid}" ]; then
        ci_log "[CI-INFO-IMPACT-0010]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" rc=${rc} reason=\"no base identity (error above if rc>0); UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
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
    base_manifest="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
    _ci_impact_run "${base}" "${head}" "${base_manifest}" || rc=$?
    rm -f "${base_manifest}"
    return "${rc}"
}

# =========================================================
# ARTIFACT RESOLVER
# =========================================================

# What: Combine ledger policy + registry artifact truth.
# Why: §26 three-truths; UNKNOWN on any unreadable truth.
# From: Issue #1683
_ci_resolve_state() {
    local service="$1" identity="$2" platform="$3"
    [ -n "${platform}" ] || { printf 'UNKNOWN\n'; return 0; }
    local lrec lrc=0 grc=0 gdig tag lstate ldig remote
    remote="$(_ci_git_remote)" || { printf 'UNKNOWN\n'; return 0; }
    lrec="$(_ci_ledger_read "${remote}" "${identity}")" || lrc=$?
    [ "${lrc}" -eq 2 ] && { printf 'UNKNOWN\n'; return 0; }
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")" || { printf 'UNKNOWN\n'; return 0; }
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
    state="$(_ci_resolve_state "${service}" "${identity}" "${platform}")"
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

# What: Classify a failure per op into its retry class.
# Why: one classifier decides retry, re-read, build or fail.
# From: Issue #1683 | PR #1858
_ci_classify_failure() {
    local raw="$1" op="${2:-registry}" low
    # What: lowercased match surface for the whole function.
    # Why: Go/curl/gh vary "Connection reset"-style casing.
    # From: Issue #1683
    low="${raw,,}"
    # What: API 404 = miss for github-read, else permanent
    # Why: a read may probe absence; a write 404 never heals
    # From: Issue #1683 | PR #1858
    if [ "${op}" = github-api ] || [ "${op}" = github-read ]; then
        case "${low}" in
            *"http 404"*|*"not found"*|*"no assets match the file pattern"*|*"no assets to download"*)
                if [ "${op}" = github-read ]; then printf 'not_found\n'; else printf 'permanent\n'; fi
                return 0 ;;
            *"gh auth login"*|*"populate the gh_token environment variable"*) printf 'permanent\n'; return 0 ;;
        esac
    fi
    # What: op=accel: only an accelerator outage retries.
    # Why: a real compile error must fail, never degrade.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = "accel" ]; then
        case "${low}" in
            *"failed to distribute"*|*"sccache: error"*|*"ccache: error"*) printf 'transient\n' ;;
            *) printf 'permanent\n' ;;
        esac
        return 0
    fi
    # What: trivy: only a DB download failure is transient.
    # Why: DB fetch is network; other scan errors are fixed.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = "trivy" ]; then
        case "${low}" in
            *"failed to download vulnerability db"*|*"database is not initialized"*|*"unable to initialize"*|*"failed to download artifact"*) printf 'transient\n' ;;
            *) printf 'permanent\n' ;;
        esac
        return 0
    fi
    # What: op=validate-net: pool/address contention only.
    # Why: a slot collision is no image or config failure.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = validate-net ]; then
        case "${low}" in
            *"pool overlaps"*|*"already in use"*) printf 'collision\n' ;;
            *) printf 'permanent\n' ;;
        esac
        return 0
    fi
    # What: op=cas-push: a moved ref is a race to re-read.
    # Why: a lost ref race heals by a re-read, not a retry.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = cas-push ]; then
        case "${low}" in
            *non-fast-forward*|*"failed to push some refs"*|*"cannot lock ref"*|*"stale info"*|*"fetch first"*|*rejected*) printf 'race\n'; return 0 ;;
        esac
    fi
    # What: a genuinely missing registry artifact.
    # Why: only not_found may drive a build; auth may not.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = registry ] || [ "${op}" = registry-read ]; then
        case "${low}" in
            *"manifest unknown"*|*"not found: manifest"*|*"manifest_unknown"*|*"name unknown"*|*"name_unknown"*) printf 'not_found\n'; return 0 ;;
            "error: "*": not found") printf 'not_found\n'; return 0 ;;
        esac
        # What: registry errcodes that never heal on retry
        # Why: OCI DENIED, *_INVALID, UNSUPPORTED are final
        # From: Issue #1683 | PR #1858
        case "${low}" in
            *"denied: "*|*"manifest invalid: "*|*"name invalid: "*|*"unsupported: "*) printf 'permanent\n'; return 0 ;;
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
    # What: a local image that does not exist is permanent.
    # Why: pushing a missing local tag never heals on retry.
    # From: Issue #1683 | PR #1858
    case "${low}" in
        *"an image does not exist locally"*|*"no such image"*) printf 'permanent\n'; return 0 ;;
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
    errf="$(_ci_mktemp "${CI_TMPDIR}/ci-lsremote.XXXXXX")" || return 2
    out="$(git ls-remote --exit-code "${remote}" "${ref}" 2>"${errf}")" || rc=$?
    err="$(<"${errf}")"; rm -f "${errf}"
    [ "${rc}" -eq 0 ] && { printf '%s\n' "${out%%$'\t'*}"; return 0; }
    [ "${rc}" -eq 2 ] && return 1
    ci_error "[CI-WARN-RESOLVE-0008]" "remote=\"${remote}\" ref=\"${ref}\" rc=${rc} reason=\"ref query failed; UNKNOWN\"" "${err}"
    return 2
}

# What: run git as the GitHub Actions bot identity
# Why: runners set no git user; one identity owner
# From: Issue #1683 | PR #1858
_ci_git_as_bot() {
    GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
    GIT_COMMITTER_NAME='github-actions[bot]' GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
        git "$@"
}

# What: Build an empty-tree commit carrying a note.
# Why: A lock head carries a note, not a real tree.
# From: Issue #1683
_ci_cas_note_commit() {
    _ci_capture 0 _ci_git_as_bot commit-tree "${CI_CAS_EMPTY_TREE}" -m "$1"
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
        _ci_cas_push_failed create "${ref}" "${rc}" "${raw}"
        return "$?"
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
    if [ "${age}" -lt "${stale}" ]; then
        ci_log "[CI-INFO-CAS-0006]" "ref=\"${ref}\" holder=\"${prev}\" age=${age}s stale_after=${stale}s reason=\"lock held; waiting\""
        return 1
    fi
    sha="$(_ci_cas_note_commit "${note}")" || return 3
    rc=0; raw="$(git push --force-with-lease="${ref}:${cur}" "${remote}" "${sha}:${ref}" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-INFO-CAS-0001]" "ref=\"${ref}\" note=\"stale lock taken over\" age=\"${age}\" prev=\"${prev}\""
        return 0
    fi
    _ci_cas_push_failed takeover "${ref}" "${rc}" "${raw}"
}

# What: log a failed CAS push; rc 2 race, rc 3 failure.
# Why: race and real failure both need git's raw text.
# From: Issue #1683 | PR #1858
_ci_cas_push_failed() {
    local kind="$1" ref="$2" rc="$3" raw="$4"
    if [ "$(_ci_classify_failure "${raw}" cas-push)" = race ]; then
        ci_error "[CI-INFO-CAS-0005]" "kind=${kind} ref=\"${ref}\" rc=${rc} reason=\"ref moved; re-read\"" "${raw}"
        return 2
    fi
    ci_error "[CI-ERROR-CAS-0004]" "kind=${kind} ref=\"${ref}\" rc=${rc} reason=\"lock push failed\"" "${raw}"
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
    # What: an absent ref is free; an unknown state fails.
    # Why: a failed query must not report a freed lock.
    # From: Issue #1683 | PR #1858
    [ "${rc}" -ne 1 ] || return 0
    [ "${rc}" -eq 0 ] || return 1
    # What: retried here; release has no outer retry loop.
    # Why: op=git uses shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${ref}" >/dev/null || return 1
    held="$(_ci_capture 0 git log -1 --format=%s FETCH_HEAD)" || return 1
    if [ "${held}" != "${note}" ]; then
        ci_log "[CI-INFO-CAS-0007]" "ref=\"${ref}\" holder=\"${held}\" mine=\"${note}\" reason=\"lock reassigned; not released\""
        return 0
    fi
    _ci_capture 0 git push --quiet --force-with-lease="${ref}:${cur}" "${remote}" ":${ref}" || return 1
    return 0
}

# =========================================================
# ACCEPTANCE LEDGER (policy truth; §26)
# =========================================================

# What: the remote every git fetch, push, ls-remote uses.
# Why: one remote name from the SOT; a test overrides it.
# From: Issue #1683
_ci_git_remote() {
    _ci_variable CI_GIT_REMOTE
}

# What: Print the ledger blob text; 1 empty, 2 unknown.
# Why: A failed read is UNKNOWN, never "no records".
# From: Issue #1683
_ci_ledger_blob() {
    local remote="$1" rc=0 ledger_ref file
    ledger_ref="$(_ci_variable CI_LEDGER_REF)" || return 2
    file="$(_ci_variable CI_LEDGER_FILE)" || return 2
    _ci_cas_ref_sha "${remote}" "${ledger_ref}" >/dev/null || rc=$?
    [ "${rc}" -eq 1 ] && return 1
    [ "${rc}" -eq 0 ] || return 2
    # What: this fetch has no retry level.
    # Why: op=git uses shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --quiet --depth=1 "${remote}" "${ledger_ref}" >/dev/null || return 2
    local blob
    if ! blob="$(git cat-file -p "FETCH_HEAD:${file}" 2>&1)"; then
        ci_error "[CI-WARN-RESOLVE-0009]" "ref=\"${ledger_ref}\" file=\"${file}\" reason=\"ledger file unreadable; UNKNOWN\"" "${blob}"
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
    out="$(awk -F'\t' -v id="${identity}" '$1==id {print $4"\t"$5; exit}' <<< "${blob}")"
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
    _ci_capture 0 _ci_git_as_bot commit-tree "${tree}" "${pa[@]}" -m "${msg}"
}

# What: Upsert record lines from stdin in one CAS write.
# Why: §26.1 one atomic ledger write per workflow.
# From: Issue #1683
_ci_ledger_upsert() {
    local remote="$1" new blob rc=0 parent="" ids kept merged blobsha treesha commitsha raw ledger_ref file
    ledger_ref="$(_ci_variable CI_LEDGER_REF)" || return 3
    file="$(_ci_variable CI_LEDGER_FILE)" || return 3
    new="$(cat)"
    new="$(printf '%s\n' "${new}" | awk 'NF>0')"
    [ -n "${new}" ] || return 0
    blob="$(_ci_ledger_blob "${remote}")" || rc=$?
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-LEDGER-0001]" "ref=\"${ledger_ref}\" remote=\"${remote}\" reason=\"ledger read UNKNOWN (raw above); refusing to write\""
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
    # What: an unchanged record set writes no commit.
    # Why: a rerun converges on the same ref (§26.4).
    # From: Issue #1683 | PR #1858
    if [ "${rc}" -eq 0 ] && [ "${merged}" = "${blob}" ]; then
        ci_log "[CI-INFO-LEDGER-0005]" "ref=\"${ledger_ref}\" commit=\"${parent}\" records=$(wc -l <<< "${merged}") reason=\"ledger unchanged; no write\""
        return 0
    fi
    if ! blobsha="$(printf '%s\n' "${merged}" | git hash-object -w --stdin 2>&1)"; then
        ci_error "[CI-ERROR-LEDGER-0002]" "ref=\"${ledger_ref}\" records=$(wc -l <<< "${merged}") reason=\"ledger blob not written\"" "${blobsha}"
        return 3
    fi
    if ! treesha="$(printf '100644 blob %s\t%s\n' "${blobsha}" "${file}" | git mktree 2>&1)"; then
        ci_error "[CI-ERROR-LEDGER-0003]" "ref=\"${ledger_ref}\" blob=\"${blobsha}\" reason=\"ledger tree not written\"" "${treesha}"
        return 3
    fi
    commitsha="$(_ci_ledger_commit "${treesha}" "${parent}" "ledger aggregate")" || return 3
    rc=0
    if [ -n "${parent}" ]; then
        raw="$(git push --force-with-lease="${ledger_ref}:${parent}" "${remote}" "${commitsha}:${ledger_ref}" 2>&1)" || rc=$?
    else
        raw="$(git push "${remote}" "${commitsha}:${ledger_ref}" 2>&1)" || rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-INFO-LEDGER-0004]" "ref=\"${ledger_ref}\" commit=\"${commitsha}\" parent=\"${parent:-none}\" records=$(wc -l <<< "${merged}") reason=\"ledger written\""
        return 0
    fi
    _ci_cas_push_failed ledger "${ledger_ref}" "${rc}" "${raw}"
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
    local f="$1" out
    # What: one jq call; each field a non-empty string.
    # Why: ACCEPTED without a digest accepts nothing.
    # From: Issue #1683 | PR #1858
    if ! out="$(jq -er '[.build_identity, .service, .platform, .state, .digest]
            | if all(type == "string" and length > 0) then @tsv
              else error("missing or empty field in " + (tojson)) end' "${f}" 2>&1)"; then
        ci_error "[CI-ERROR-AGGREGATE-0004]" "file=\"${f}\" reason=\"malformed or incomplete result.json\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
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
        line="$(_ci_result_record "${f}")" || return 2
        records="${records}${line}"$'\n'
    done
    [ -n "${records}" ] || { ci_log "[CI-ERROR-AGGREGATE-0003]" "reason=\"no result.json in dir\" dir=\"${dir}\""; return 2; }
    local rc=0 remote
    remote="$(_ci_git_remote)" || return 2
    printf '%s' "${records}" | _ci_ledger_upsert "${remote}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        printf 'aggregate records=%s\n' "$(printf '%s' "${records}" | grep -c .)"
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
    tag="$(_ci_image_tag "${svc}" "${plat}" "${identity}")" || return 2
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
    if [ -z "${digest}" ] || [ -z "${identity}" ]; then
        ci_log "[CI-ERROR-RESULT-0004]" "service=\"${service}\" platform=\"${platform}\" identity=\"${identity}\" digest=\"${digest}\" reason=\"empty identity or digest; nothing to accept\""
        return 2
    fi
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
    dir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-results.XXXXXX")" || return 2
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

# What: load the history a diff needs, once per checkout.
# Why: workflows check out one commit; ci.sh owns the diff.
# From: Issue #1683 | PR #1858
_ci_diff_history() {
    local shallow have="" remote
    local -a deep=() need=()
    shallow="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git rev-parse --is-shallow-repository)" || return 2
    [ "${shallow}" = true ] && deep=(--unshallow)
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ -n "${BASE_SHA:-}" ]; then
        have="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 1 git rev-parse -q --verify "${BASE_SHA}^{commit}")" || return 2
        [ -n "${have}" ] || need=("${BASE_SHA}")
    fi
    [ "${#deep[@]}" -gt 0 ] || [ "${#need[@]}" -gt 0 ] || return 0
    _ci_env_required GITHUB_REF "[CI-ERROR-CORE-0124]" \
        "shallow=\"${shallow}\" base=\"${BASE_SHA:-}\" reason=\"diff history missing and no GITHUB_REF to fetch\"" > /dev/null || return 2
    remote="$(_ci_git_remote)" || return 2
    (cd -- "${CI_REPO_ROOT}" && _ci_retry git-fetch git fetch -q --no-tags "${deep[@]}" "${remote}" "${GITHUB_REF}" "${need[@]}") \
        > /dev/null || return 2
}

# What: This run's base and head diff refs, or empty.
# Why: one owner; changed-files and codeql share the refs.
# From: Issue #1683
_ci_diff_refs() {
    local mb before
    _ci_diff_history || return 2
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
    local list err
    if [ -n "${base}" ]; then
        list="$(_ci_run "[CI-ERROR-CORE-0117]" "base=\"${base}\" head=\"${head}\" repo=\"${CI_REPO_ROOT}\"" git -C "${CI_REPO_ROOT}" diff --name-only "${base}" "${head}")" || return 2
    else
        ci_log "[CI-INFO-CORE-0118]" "reason=\"no base ref for this event; every tracked file counts as changed\""
        list="$(_ci_run "[CI-ERROR-CORE-0119]" "repo=\"${CI_REPO_ROOT}\"" git -C "${CI_REPO_ROOT}" ls-files)" || return 2
    fi
    if ! err="$( { [ -z "${list}" ] || printf '%s\n' "${list}"; } 2>&1 > "${out}")"; then
        ci_error "[CI-ERROR-CORE-0120]" "file=\"${out}\" reason=\"changed-file list not written\"" "${err}"
        return 2
    fi
    ci_log "[CI-INFO-CORE-0121]" "file=\"${out}\" paths=$(grep -c . <<< "${list}") base=\"${base:-none}\""
    _ci_step_output "[CI-ERROR-CORE-0125]" file "${out}" || return 2
    printf '%s\n' "${out}"
}

# What: translate a path glob to an anchored ERE.
# Why: ** spans dirs and **/ may be empty; * and ? do not.
# From: Issue #1683 | PR #1858
_ci_glob_ere() {
    local g="$1" out="" c i
    for (( i = 0; i < ${#g}; i++ )); do
        c="${g:i:1}"
        if [ "${g:i:3}" = '**/' ]; then
            out+='(.*/)?'; i=$((i + 2))
        elif [ "${g:i:2}" = '**' ]; then
            out+='.*'; i=$((i + 1))
        else
            case "${c}" in
                '*') out+='[^/]*' ;;
                '?') out+='[^/]' ;;
                .|+|^|\$|\(|\)|\[|\]|\{|\}|\||\\) out+="\\${c}" ;;
                *) out+="${c}" ;;
            esac
        fi
    done
    printf '^%s$\n' "${out}"
}

# What: print the PR labels for the changed paths given.
# Why: SOT pr_labels rules plus each target's labels.
# From: Issue #1683 | PR #1858
_ci_pr_labels_for() {
    local label globs g re f t ctx tl keys targets
    local -A hit=()
    local -a res=()
    keys="$(_ci_block_keys pr_labels all)" || return 2
    targets="$(ci_build_targets)" || return 2
    for label in ${keys}; do
        globs="$(_ci_block_entry_list pr_labels "" "${label}")" || return 2
        res=()
        while IFS= read -r g; do
            [ -n "${g}" ] && res+=("$(_ci_glob_ere "${g}")")
        done <<< "${globs}"
        for f in "$@"; do
            for re in "${res[@]}"; do
                [[ "${f}" =~ ${re} ]] && hit["${label}"]=1
            done
        done
    done
    for t in ${targets}; do
        ctx="$(_ci_required_field "${t}" context)" || return 2
        tl="$(_ci_target_list "${t}" labels)" || return 2
        for f in "$@"; do
            [[ "${f}" == "${ctx}"/* ]] || continue
            while IFS= read -r label; do
                [ -n "${label}" ] && hit["${label}"]=1
            done <<< "${tl}"
        done
    done
    [ "${#hit[@]}" -eq 0 ] || printf '%s\n' "${!hit[@]}" | LC_ALL=C sort
}

# What: add the path labels to the current pull request.
# Why: AG-GH-008 labels; SOT owns the path->label rules.
# From: Issue #1683 | PR #1858
ci_cmd_pr_labels() {
    local list labels l repo out stored
    local -a files=() args=() missing=()
    if [ "${GITHUB_EVENT_NAME:-}" != pull_request ] || [ -z "${PR_NUMBER:-}" ]; then
        printf 'pr-labels=NOT-RUN reason="not a pull request"\n'
        return 0
    fi
    if [ "${PR_IS_FORK:-false}" = true ]; then
        printf 'pr-labels=NOT-RUN reason="fork PR: token cannot write labels; label by hand (AG-GH-008)"\n'
        return 0
    fi
    list="${CHANGED_FILES:-}"
    if [ -z "${list}" ] || [ ! -f "${list}" ]; then
        ci_log "[CI-ERROR-PRLABELS-0001]" "file=\"${list}\" reason=\"CHANGED_FILES list missing\""
        return 2
    fi
    mapfile -t files < "${list}"
    labels="$(_ci_pr_labels_for "${files[@]}")" || return 2
    if [ -z "${labels}" ]; then
        printf 'pr-labels=none changed=%s\n' "${#files[@]}"
        return 0
    fi
    while IFS= read -r l; do args+=(-f "labels[]=${l}"); done <<< "${labels}"
    repo="$(_ci_repo)" || return 2
    out="$(_ci_run "[CI-ERROR-PRLABELS-0002]" "pr=\"${PR_NUMBER}\" labels=\"${labels//$'\n'/ }\" reason=\"labels not added\"" \
        gh api -X POST "repos/${repo}/issues/${PR_NUMBER}/labels" "${args[@]}")" || return 2
    # What: each added label is in the label list returned
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    stored="$(_ci_capture 0 jq -r '.[].name' <<< "${out}")" || return 2
    while IFS= read -r l; do
        [[ $'\n'"${stored}"$'\n' == *$'\n'"${l}"$'\n'* ]] || missing+=("${l}")
    done <<< "${labels}"
    if [ "${#missing[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-PRLABELS-0003]" "pr=\"${PR_NUMBER}\" missing=\"${missing[*]}\" reason=\"labels not on the PR after the write\"" "${out}"
        return 2
    fi
    printf 'pr-labels=added labels=%s\n' "${labels//$'\n'/,}"
}

# What: put the new PR or issue on the SOT project board.
# Why: AG-GH-008 board placement; item-add is idempotent.
# From: Issue #1683 | PR #1858
ci_cmd_board_add() {
    local repo number kind item resp ids chk
    case "${GITHUB_EVENT_NAME:-}" in
    pull_request) kind=pull item="${PR_NUMBER:-}" ;;
    issues) kind=issues item="${ISSUE_NUMBER:-}" ;;
    *) kind='' item='' ;;
    esac
    if [ -z "${item}" ]; then
        printf 'board-add=NOT-RUN reason="not a pull request or issue"\n'
        return 0
    fi
    if [ "${PR_IS_FORK:-false}" = true ] || [ -z "${GH_TOKEN:-}" ]; then
        printf 'board-add=NOT-RUN reason="no project token (fork or unset); add by hand (AG-GH-008)"\n'
        return 0
    fi
    repo="$(_ci_repo)" || return 2
    number="$(_ci_block_entry_field pr_policy "" project_number)" || return 2
    if ! [[ "${number}" =~ ^[0-9]+$ ]]; then
        ci_log "[CI-ERROR-BOARD-0001]" "got=\"${number}\" reason=\"no numeric SOT pr_policy.project_number\""
        return 2
    fi
    # What: org board id and item id in one graphql lookup.
    # Why: gh project item-add needs a scope the PAT lacks.
    # From: Issue #1683 | PR #1858
    if ! resp="$(_ci_retry github-api gh api graphql -f o="${repo%%/*}" -f r="${repo#*/}" \
        -F p="${number}" -F n="${item}" -f query='query($o: String!, $r: String!, $p: Int!, $n: Int!) { organization(login: $o) { projectV2(number: $p) { id } } repository(owner: $o, name: $r) { issueOrPullRequest(number: $n) { ... on Issue { id } ... on PullRequest { id } } } }')"; then
        ci_error "[CI-ERROR-BOARD-0002]" "project=\"${number}\" ${kind}=\"${item}\" reason=\"board or item lookup failed\"" "${resp}"
        return 2
    fi
    if ! ids="$(jq -er '[.data.organization.projectV2.id, .data.repository.issueOrPullRequest.id]
        | select(all(type == "string")) | join(" ")' <<<"${resp}" 2>&1)"; then
        ci_error "[CI-ERROR-BOARD-0003]" "project=\"${number}\" ${kind}=\"${item}\" reason=\"no board or item id in the lookup\"" "${resp}"
        return 2
    fi
    resp="$(_ci_run "[CI-ERROR-BOARD-0004]" "project=\"${number}\" ${kind}=\"${item}\" reason=\"item not added to the board\"" \
        gh api graphql -f p="${ids% *}" -f c="${ids#* }" \
        -f query='mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } } }')" || return 2
    # What: the add answer must carry the board item id
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    if ! chk="$(jq -e '.data.addProjectV2ItemById.item.id | type == "string" and . != ""' <<< "${resp}" 2>&1)"; then
        ci_error "[CI-ERROR-BOARD-0005]" "project=\"${number}\" ${kind}=\"${item}\" reason=\"no board item id in the add answer\"" "${resp}"$'\n'"${chk}"
        return 2
    fi
    printf 'board-add=added project=%s %s=%s\n' "${number}" "${kind}" "${item}"
}

# What: assemble product services from build matrix.
# Why: one matrix walk; iteration in ci.sh (AG-CODE-011).
# From: Issue #1683
ci_cmd_assemble_stack() {
    local matrix="${CI_BUILD_MATRIX:-}" svc svcs
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-ASSEMBLE-0006]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    if ! svcs="$(jq -r '[.include[].service] | unique | .[]' <<< "${matrix}" 2>&1)"; then
        ci_error "[CI-ERROR-ASSEMBLE-0011]" "reason=\"CI_BUILD_MATRIX unreadable; no service assembled\"" "${svcs}"$'\n'"matrix: ${matrix}"
        return 2
    fi
    for svc in ${svcs}; do
        ci_cmd_assemble "${svc}" || return "$?"
    done
}

# What: run ci.sh op for each changed rust test service.
# Why: one TEST_SERVICES walk for the test stack.
# From: Issue #1683
_ci_for_test_services() {
    local fn="$1" list="${TEST_SERVICES:-}" svc
    # What: an empty TEST_SERVICES fails instead of passing.
    # Why: a run that tested nothing must not read as green.
    # From: Issue #1683 | PR #1858
    if [ -z "${list// /}" ]; then
        ci_log "[CI-ERROR-TEST-0012]" "fn=\"${fn}\" reason=\"TEST_SERVICES empty; nothing would run\""
        return 2
    fi
    for svc in ${list}; do
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
    local repo srv
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    local run_url="${srv}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}" existing
    local ctx="repo=\"${repo}\" label=\"${label}\" scope=\"${scope}\" outcome=${outcome}"
    existing="$(_ci_run "[CI-ERROR-STATUS-0003]" "${ctx} step=list" gh issue list --repo "${repo}" --label "${label}" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')" || return 2
    if [ "${outcome}" = success ]; then
        [ -n "${existing}" ] || { printf 'nightly-status=noop label=%s\n' "${label}"; return 0; }
        _ci_run "[CI-ERROR-STATUS-0004]" "${ctx} step=comment issue=${existing}" gh issue comment "${existing}" --repo "${repo}" \
            --body "Recovered: ${scope} succeeded in ${run_url}. Closing this standing issue; it re-opens if the check fails again." >/dev/null || return 2
        _ci_run "[CI-ERROR-STATUS-0005]" "${ctx} step=close issue=${existing}" gh issue close "${existing}" --repo "${repo}" >/dev/null || return 2
        printf 'nightly-status=closed issue=%s\n' "${existing}"
        return 0
    fi
    local detail="${scope} failed in ${run_url}"
    [ -n "${failed}" ] && detail="${detail} (failed: ${failed})"
    if [ -n "${existing}" ]; then
        _ci_run "[CI-ERROR-STATUS-0006]" "${ctx} step=comment issue=${existing}" gh issue comment "${existing}" --repo "${repo}" --body "Still failing: ${detail}." >/dev/null || return 2
        printf 'nightly-status=updated issue=%s\n' "${existing}"
    else
        # What: label create-or-update, then the issue.
        # Why: --force makes an existing label no error.
        # From: Issue #1683 | PR #1858
        _ci_run "[CI-ERROR-STATUS-0007]" "${ctx} step=label" gh label create "${label}" --repo "${repo}" --color b60205 --force \
            --description "Recurring self-closing tracking issue: ${scope}" >/dev/null || return 2
        _ci_run "[CI-ERROR-STATUS-0008]" "${ctx} step=create" gh issue create --repo "${repo}" --label "${label}" --title "[${label}] ${scope}" \
            --body "Standing issue, reused across failures and auto-closed on the next success. ${detail}." >/dev/null || return 2
        printf 'nightly-status=opened label=%s\n' "${label}"
    fi
}

# =========================================================
# CACHE CONFIGURATION
# =========================================================

# What: path of one BuildKit secret in a build container.
# Why: one owner for every build-time secret mount path.
# From: Issue #1683 | PR #1858
_ci_secret_file() {
    printf '/run/secrets/%s\n' "$1"
}

# What: sccache mode and cache chain for this runner.
# Why: AG-CI-009: Redis L1 on self-hosted, GHA cache L2.
# From: Issue #1683 | PR #1858
_ci_sccache_policy() {
    local mode chain=""
    mode="$(_ci_variable SCCACHE_REDIS_MODE)" || return 2
    case "${mode}" in
        required|optional|off) ;;
        *)
            ci_log "[CI-ERROR-VARIABLES-0010]" "mode=\"${mode}\" reason=\"SCCACHE_REDIS_MODE must be required|optional|off\""
            return 2
            ;;
    esac
    if [ "${mode}" != off ]; then
        if _ci_runner_self_hosted; then
            if [ -n "${SCCACHE_REDIS_URL:-}" ]; then
                chain=redis
            elif [ "${mode}" = required ]; then
                ci_log "[CI-ERROR-VARIABLES-0012]" "reason=\"SCCACHE_REDIS_URL required when mode=required on a self-hosted runner\""
                return 2
            fi
        fi
        if [ -n "${ACTIONS_RESULTS_URL:-}" ] && [ -n "${ACTIONS_RUNTIME_TOKEN:-}" ]; then
            chain="${chain:+${chain},}gha"
        fi
    fi
    if [ "${mode}" = required ] && [ -z "${chain}" ]; then
        ci_log "[CI-ERROR-CACHE-0007]" "runner=\"${RUNNER_ENVIRONMENT:-unset}\" reason=\"mode required but no cache level: no GHA cache tokens\""
        return 2
    fi
    printf '%s %s\n' "${mode}" "${chain:--}"
}

# What: export the sccache backend vars of one chain.
# Why: one map from redis/gha levels to sccache env.
# From: Issue #1683 | PR #1858
_ci_sccache_backend() {
    local chain="$1" url="$2" mode="$3"
    unset SCCACHE_REDIS SCCACHE_GHA_ENABLED SCCACHE_MULTILEVEL_CHAIN SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY
    [[ ",${chain}," != *,redis,* ]] || export SCCACHE_REDIS="${url}"
    [[ ",${chain}," != *,gha,* ]] || export SCCACHE_GHA_ENABLED=on
    [[ "${chain}" != *,* ]] || export SCCACHE_MULTILEVEL_CHAIN="${chain}"
    [[ "${chain}" != *,* ]] || [ "${mode}" != optional ] || export SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY=ignore
}

# What: export the named keys of a KEY=VALUE secret file
# Why: secrets end without a newline; the last line counts
# From: Issue #1683 | PR #1858
_ci_secret_env() {
    local file="$1" k v
    shift
    [ -s "${file}" ] || return 0
    while IFS='=' read -r k v || [ -n "${k}" ]; do
        case " $* " in *" ${k} "*) export "${k}=${v}" ;; esac
    done < "${file}"
}

# What: sccache as rustc wrapper on the policy chain.
# Why: AG-CI-009 levels; required fails closed (AG-CI-011).
# From: Issue #1683 | PR #1858
_ci_sccache_env() {
    local prefix="$1" wrapper="${2:-sccache}" url="${SCCACHE_REDIS_URL:-}" sf policy mode chain
    # What: a build reads the runner policy; else compute.
    # Why: the chain is decided once, on the runner.
    # From: Issue #1683 | PR #1858
    sf="$(_ci_secret_file sccache_policy)"
    if [ -s "${sf}" ]; then policy="$(<"${sf}")"; else policy="$(_ci_sccache_policy)" || return 2; fi
    read -r mode chain <<< "${policy}"
    [ "${chain}" != - ] || chain=""
    export RUSTC_WRAPPER="${wrapper}" SCCACHE_DIR="${SCCACHE_DIR:-${CI_TMPDIR}/sccache}"
    export SCCACHE_REDIS_KEY_PREFIX="${prefix}"
    sf="$(_ci_secret_file sccache_redis_url)"
    if [ -s "${sf}" ]; then url="$(<"${sf}")"; fi
    _ci_secret_env "$(_ci_secret_file sccache_gha)" ACTIONS_RESULTS_URL ACTIONS_RUNTIME_TOKEN
    _ci_sccache_backend "${chain}" "${url}" "${mode}"
    if [ -n "${chain}" ]; then
        ci_log "[CI-INFO-CACHE-0001]" "prefix=\"${prefix}\" mode=${mode} chain=\"${chain}\" runner=\"${RUNNER_ENVIRONMENT:-unset}\""
    else
        ci_log "[CI-INFO-CACHE-0002]" "prefix=\"${prefix}\" mode=${mode} backend=local dir=\"${SCCACHE_DIR}\""
    fi
    # What: own server socket; start it as the probe.
    # Why: a shared port lets parallel runs collide.
    # From: Issue #1683 | PR #1858
    local probe prc=0 sock_dir step=1 next
    sock_dir="$(_ci_mktemp -d "${CI_TMPDIR}/sccache-srv.XXXXXX")" || return 2
    export SCCACHE_SERVER_UDS="${sock_dir}/s${step}.sock"
    probe="$(sccache --start-server 2>&1)" || prc=$?
    [ "${prc}" -eq 0 ] && return 0
    if [ "${mode}" = required ]; then
        ci_error "[CI-ERROR-CACHE-0008]" "prefix=\"${prefix}\" chain=\"${chain:-local}\" rc=${prc} reason=\"required sccache cache did not start; fail closed\"" "${probe}"
        return 2
    fi
    # What: optional: drop redis, then remote, then local.
    # Why: §42: a cache outage costs speed, never the build.
    # From: Issue #1683 | PR #1858
    while [ -n "${chain}" ]; do
        case "${chain}" in redis,*) next="${chain#redis,}" ;; *) next="" ;; esac
        ci_error "[CI-WARN-CACHE-0003]" "prefix=\"${prefix}\" chain=\"${chain}\" next=\"${next:-local}\" rc=${prc} reason=\"sccache cache level unavailable\"" "${probe}"
        chain="${next}"
        _ci_sccache_backend "${chain}" "${url}" "${mode}"
        step=$(( step + 1 ))
        export SCCACHE_SERVER_UDS="${sock_dir}/s${step}.sock"
        prc=0
        probe="$(sccache --start-server 2>&1)" || prc=$?
        [ "${prc}" -eq 0 ] && return 0
    done
    ci_error "[CI-WARN-CACHE-0004]" "prefix=\"${prefix}\" rc=${prc} reason=\"sccache unavailable; direct rustc\"" "${probe}"
    unset RUSTC_WRAPPER
}

# What: args of the docker:// GHA runtime export step.
# Why: run steps never get the cache token; kill-bounded.
# From: Issue #1683 | PR #1858
ci_cmd_gha_runtime_args() {
    local t args
    t="$(_ci_variable CI_GHA_RUNTIME_EXPORT_TIMEOUT)" || return 2
    case "${t}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-CACHE-0009]" "value=\"${t}\" reason=\"CI_GHA_RUNTIME_EXPORT_TIMEOUT must be whole seconds\""
            return 2
            ;;
    esac
    args="-s KILL ${t} /bin/sh -c \"env | grep -E '^ACTIONS_(RESULTS_URL|RUNTIME_TOKEN)=' >> \$GITHUB_ENV\""
    _ci_step_output "[CI-ERROR-CACHE-0010]" args "${args}" || return 2
    printf '%s\n' "${args}"
}

# What: stop this run's sccache server, drop its socket.
# Why: a started server must not outlive its run.
# From: Issue #1683 | PR #1858
_ci_sccache_stop() {
    local out rc=0
    [ -n "${SCCACHE_SERVER_UDS:-}" ] || return 0
    if [ -n "${RUSTC_WRAPPER:-}" ]; then
        out="$(sccache --stop-server 2>&1)" || rc=$?
        [ "${rc}" -eq 0 ] || ci_error "[CI-WARN-CACHE-0005]" "rc=${rc} reason=\"sccache server stop failed\"" "${out}"
    fi
    _ci_sccache_reap "${SCCACHE_SERVER_UDS%/*}"
    rm -rf -- "${SCCACHE_SERVER_UDS%/*}"
}

# What: kill sccache servers under this run's socket dir.
# Why: a server timed out on Redis keeps on running.
# From: Issue #1683 | PR #1858
_ci_sccache_reap() {
    local dir="$1" p env_s out
    for p in /proc/[0-9]*; do
        [ -r "${p}/environ" ] && [ "$(cat "${p}/comm" 2>&1)" = sccache ] || continue
        env_s="$(tr '\0' '\n' < "${p}/environ")" || continue
        [[ $'\n'"${env_s}" == *$'\n'"SCCACHE_SERVER_UDS=${dir}/"* ]] || continue
        out="$(kill "${p#/proc/}" 2>&1)" || ci_error "[CI-WARN-CACHE-0006]" "pid=${p#/proc/} reason=\"sccache server kill failed\"" "${out}"
    done
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
    # What: log docker in to the image registry, retried
    # Why: auth is ci.sh policy (§7); AG-CI-013 retries it
    # From: Issue #1683 | PR #1858
    local reg out
    reg="$(_ci_registry)" || return "$?"
    if ! out="$(_ci_retry registry _ci_registry_login_once "${reg}" GHCR_USERNAME GHCR_TOKEN)"; then
        ci_error "[CI-ERROR-BUILD-0015]" "registry=\"${reg}\" reason=\"docker login to the image registry failed\"" "${out}"
        return 2
    fi
    _ci_dockerhub_login
}

# What: Docker Hub login once, when credentials are set.
# Why: docker.io pulls hit the anonymous shared-IP limit.
# From: Issue #1095 | PR #1858
_ci_dockerhub_login() {
    [ -z "${_CI_DOCKERHUB_DONE:-}" ] || return 0
    if [ -z "${DOCKERHUB_USERNAME:-}${DOCKERHUB_TOKEN:-}" ]; then
        ci_log "[CI-NOTICE-BUILD-0020]" "reason=\"DOCKERHUB_USERNAME/DOCKERHUB_TOKEN not set; docker.io pulls stay anonymous\""
        _CI_DOCKERHUB_DONE=1
        return 0
    fi
    if [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-BUILD-0021]" "reason=\"only one of DOCKERHUB_USERNAME/DOCKERHUB_TOKEN is set\""
        return 2
    fi
    _ci_retry registry _ci_registry_login_once "" DOCKERHUB_USERNAME DOCKERHUB_TOKEN >/dev/null || return 2
    # What: done only after a login or anonymous on purpose.
    # Why: a failed login must fail again, never pass.
    # From: Issue #1683 | PR #1858
    _CI_DOCKERHUB_DONE=1
}

# What: one login; user and token come by variable name
# Why: retried; a token never reaches argv or a log line
# From: Issue #1683 | PR #1858
_ci_registry_login_once() {
    local registry="$1" user_var="$2" token_var="$3"
    printf '%s' "${!token_var}" | docker login ${registry:+"${registry}"} -u "${!user_var}" --password-stdin
}

# What: compiled-binary CAS lookup; no store, always a miss.
# Why: a miss only costs a compile, never a false reuse.
# From: Issue #1683
_ci_cas_lookup() {
    return 1
}

# What: print a required runner env value; else coded fail.
# Why: one owner; ${VAR:?} ends with no id or context.
# From: Issue #1683 | PR #1858
_ci_env_required() {
    local name="$1" id="${2:-[CI-ERROR-CORE-0128]}" ctx="${3:-}"
    if [ -z "${!name:-}" ]; then
        ci_log "${id}" "${ctx:-name=\"${name}\" reason=\"required environment value missing\"}"
        return 2
    fi
    printf '%s\n' "${!name}"
}

# What: append key=value to the step output, if a step.
# Why: YAML only calls ci.sh; one writer, caller's id.
# From: Issue #1683 | PR #1858
_ci_step_output() {
    local id="$1" key="$2" value="$3" err
    [ -n "${GITHUB_OUTPUT:-}" ] || return 0
    if ! err="$(printf '%s=%s\n' "${key}" "${value}" 2>&1 >> "${GITHUB_OUTPUT}")"; then
        ci_error "${id}" "file=\"${GITHUB_OUTPUT}\" key=\"${key}\" reason=\"step output not written\"" "${err}"
        return 2
    fi
}

# What: SOT runner, job order and minutes per CI job.
# Why: job-settings and its workflow guard read one owner.
# From: Issue #1683 | PR #1858
_ci_job_settings_read() {
    local -n _ci_js_runner="$1" _ci_js_jobs="$2" _ci_js_min="$3"
    local _ci_js_plat _ci_js_keys _ci_js_job _ci_js_m
    _ci_js_plat="$(_ci_build_matrix_platforms)" || return 2
    _ci_js_plat="${_ci_js_plat%%$'\n'*}"
    if [ -z "${_ci_js_plat}" ]; then
        ci_log "[CI-ERROR-JOBS-0001]" "reason=\"no SOT build_matrix platform to take the runner from\""
        return 2
    fi
    _ci_js_runner="$(_ci_platform_field "${_ci_js_plat}" runner "[CI-ERROR-JOBS-0002]" "reason=\"no runner label for the first build_matrix platform\"")" || return 2
    _ci_js_keys="$(_ci_block_keys ci_job_timeouts all)" || return 2
    if [ -z "${_ci_js_keys}" ]; then
        ci_log "[CI-ERROR-JOBS-0003]" "reason=\"no SOT ci_job_timeouts entries\""
        return 2
    fi
    _ci_js_jobs=()
    while IFS= read -r _ci_js_job; do
        _ci_js_m="$(_ci_block_entry_field ci_job_timeouts "" "${_ci_js_job}")" || return 2
        if [[ ! "${_ci_js_m}" =~ ^[1-9][0-9]*$ ]]; then
            ci_error "[CI-ERROR-JOBS-0004]" "job=\"${_ci_js_job}\" reason=\"timeout is not a positive whole number of minutes\"" "value=${_ci_js_m}"
            return 2
        fi
        _ci_js_jobs+=("${_ci_js_job}")
        _ci_js_min["${_ci_js_job}"]="${_ci_js_m}"
    done <<< "${_ci_js_keys}"
}

# What: output runner label and job timeouts from SOT.
# Why: AG-CI-002/006/016: one owner, no YAML copies.
# From: Issue #1683 | PR #1858
ci_cmd_job_settings() {
    local runner json job
    local -a js_jobs=() js_pairs=()
    local -A js_min=()
    _ci_job_settings_read runner js_jobs js_min || return 2
    for job in "${js_jobs[@]}"; do js_pairs+=("${job}" "${js_min[${job}]}"); done
    json="$(_ci_capture 0 jq -cn 'reduce range(0; $ARGS.positional | length; 2) as $i ({}; . + {($ARGS.positional[$i]): ($ARGS.positional[$i + 1] | tonumber)})' --args "${js_pairs[@]}")" || return 2
    _ci_step_output "[CI-ERROR-JOBS-0005]" runner "${runner}" || return 2
    _ci_step_output "[CI-ERROR-JOBS-0006]" timeouts "${json}" || return 2
    printf 'runner=%s\ntimeouts=%s\n' "${runner}" "${json}"
}

# What: Lowercased owner/repo for GHCR image refs.
# Why: GHCR paths are case-sensitive and must be lower.
# From: Issue #1683
_ci_repo() {
    local repo
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    printf '%s' "${repo,,}"
}

# What: The canonical registry host from the SOT.
# Why: refs derive it; a missing value must fail closed.
# From: Issue #1683
_ci_registry() {
    local r
    r="$(_ci_block_entry_field release "" registry)" || return 2
    if [ -z "${r}" ]; then
        ci_log "[CI-ERROR-CORE-0005]" "key=\"release.registry\" reason=\"missing from the SOT\""
        return 2
    fi
    printf '%s' "${r}"
}

# What: Run any command, retrying only a transient failure.
# Why: RETRY OPERATION != REBUILD; classify before retry.
# From: Issue #1683
_ci_retry() {
    local op="$1"; shift
    local n=0 max backoff raw cls
    max="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)" || return 2
    backoff="$(_ci_variable CI_RETRY_BACKOFF_BASE_SECONDS)" || return 2
    while :; do
        n=$((n + 1))
        if raw="$("$@" 2>&1)"; then
            [ "${n}" -eq 1 ] || ci_log "[CI-INFO-BUILD-0017]" "op=${op} cmd=\"$1\" attempt=${n}/${max} reason=\"succeeded after retry\""
            printf '%s\n' "${raw}"
            return 0
        fi
        cls="$(_ci_classify_failure "${raw}" "${op}")"
        if [ "${cls}" != "transient" ] || [ "${n}" -ge "${max}" ]; then
            # What: *-read ops: raw out; rc 1 = absent.
            # Why: a probe miss is a state; the caller logs.
            # From: Issue #1683 | PR #1858
            if [[ "${op}" == *-read ]]; then
                printf '%s\n' "${raw}"
                if [ "${cls}" = not_found ]; then return 1; fi
                return 2
            fi
            ci_error "[CI-ERROR-BUILD-0011]" "op=${op} cmd=\"$1\" cls=${cls} attempt=${n}/${max} reason=\"command failed\"" "${raw}"
            # What: emit raw failure to the caller too.
            # Why: caller may interpret op-specific reason.
            # From: Issue #1683
            printf '%s\n' "${raw}"
            return 2
        fi
        # What: each retried failure is logged with its raw.
        # Why: AG-INT-002: retries show failed attempts.
        # From: Issue #1683 | PR #1858
        ci_error "[CI-WARN-BUILD-0016]" "op=${op} cmd=\"$1\" cls=${cls} attempt=${n}/${max} reason=\"transient failure; retrying\"" "${raw}"
        sleep "$((n * n * backoff))"
    done
}

# What: The per-identity per-arch tag for a build.
# Why: One tag owner; build/publish/verify must agree.
# From: Issue #1683
_ci_image_tag() {
    local name
    name="$(_ci_image_ref "$1")" || return 2
    printf '%s:sha-%s-%s' "${name}" "$3" "${2##*/}"
}

# What: registry/repo, then /target, then @digest if given.
# Why: the one owner of image names; callers add only tags.
# From: Issue #1683 | PR #1858
_ci_image_ref() {
    local reg repo
    if [ "$#" -ge 2 ] && [ -z "$2" ]; then
        ci_log "[CI-ERROR-CORE-0135]" "target=\"$1\" reason=\"empty digest; a tagless name would pull latest\""
        return 2
    fi
    reg="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    printf '%s/%s%s%s' "${reg}" "${repo}" "${1:+/$1}" "${2:+@$2}"
}

# What: The base build-tools image ref, no tag.
# Why: the toolchain image is named like every target.
# From: Issue #1683 | PR #1858
_ci_build_tools_image() {
    local tool
    tool="$(_ci_toolchain_target)" || return 2
    _ci_image_ref "${tool}"
}

# What: OCI image labels from the SOT and env.
# Why: Provenance labels set once, not per Dockerfile.
# From: Issue #1683
_ci_oci_labels() {
    local service="$1" repo source base final created lic
    repo="$(_ci_repo)" || return 2
    lic="$(_ci_release_value license)" || return 2
    source="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    source="${source}/${repo}"
    final="$(_ci_required_field "${service}" final_base)" || return 2
    base="$(_ci_block_entry_field base_images "" "${final}")" || return 2
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'org.opencontainers.image.created=%s\n' "${created}"
    [ -n "${GITHUB_SHA:-}" ] && printf 'org.opencontainers.image.revision=%s\n' "${GITHUB_SHA}"
    [ -n "${GITHUB_SHA:-}" ] && printf 'org.opencontainers.image.version=%s\n' "${GITHUB_SHA}"
    printf 'org.opencontainers.image.source=%s\n' "${source}"
    printf 'org.opencontainers.image.url=%s\n' "${source}"
    printf 'org.opencontainers.image.documentation=%s\n' "${source}"
    printf 'org.opencontainers.image.licenses=%s\n' "${lic}"
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

# What: NAME=value of the set variables of one SOT list.
# Why: build-args and the identity read one resolution.
# From: Issue #1683 | PR #1858
_ci_build_variable_args() {
    local build_type="$1" block="${2:-build_variables}" vnames vname vval vrc
    vnames="$(_ci_block_entry_list "${block}" "" "${build_type}")" || return 2
    while IFS= read -r vname; do
        [ -n "${vname}" ] || continue
        vrc=0
        vval="$(_ci_variable_value "${vname}")" || vrc=$?
        case "${vrc}" in
            0) printf '%s=%s\n' "${vname}" "${vval}" ;;
            1) ;;
            *) return 2 ;;
        esac
    done <<< "${vnames}"
}

# What: Build one service image once and load it locally.
# Why: BUILD != PUBLISH; a push failure must not rebuild.
# From: Issue #1683
_ci_docker_build() {
    local service="$1" identity="$2" platform="$3"
    local context df tag a build_type
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    df="$(_ci_service_path "${service}" Dockerfile "")" || return 2
    context="${df%/Dockerfile}"
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")" || return 2
    # What: the Dockerfile must declare ARG BUILD_IDENTITY.
    # Why: else a stale cached apk layer ships silently.
    # From: Issue #1683 | PR #1858
    if ! grep -qx 'ARG BUILD_IDENTITY' "${df}"; then
        ci_log "[CI-ERROR-BUILD-0013]" "service=\"${service}\" path=\"${df}\" reason=\"no ARG BUILD_IDENTITY; layer cache could ship stale packages\""
        return 2
    fi
    local -a args=()
    # What: rust builds from repo-root, not service dir.
    # Why: bind-mount + workspace COPYs need the tree.
    # From: Issue #1683
    if [ "${build_type}" = rust ]; then
        args+=(--file "${df}")
        context="."
    fi
    # What: every stage bind-mounts ci.sh via one context.
    # Why: one mount form for apk-setup and rust-build.
    # From: Issue #1683 | PR #1858
    args+=(--build-context "ci-scripts=${CI_SCRIPT_DIR}")
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
    # What: a BuildKit check warning fails the build.
    # Why: AG-VAL-001: warnings are errors.
    # From: Issue #1683 | PR #1858
    args+=(--build-arg "BUILDKIT_DOCKERFILE_CHECK=error=true")
    # What: the build type's CI variables as build-args.
    # Why: repo/org variables reach the builder (AG-CI-006).
    # From: Issue #1683 | PR #1858
    local vargs
    vargs="$(_ci_build_variable_args "${build_type}")" || return 2
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-arg "${a}")
    done <<< "${vargs}"
    # What: every ci.sh stage gets the SOT stage variables
    # Why: a stage has no SOT; a missing value fails closed
    # From: Issue #1683 | PR #1858
    local snames sname
    snames="$(_ci_block_entry_list stage_variables "" ci_sh)" || return 2
    vargs="$(_ci_build_variable_args ci_sh stage_variables)" || return 2
    while IFS= read -r sname; do
        [ -n "${sname}" ] || continue
        grep -q "^${sname}=" <<< "${vargs}" || {
            ci_log "[CI-ERROR-BUILD-0022]" "service=\"${service}\" name=\"${sname}\" reason=\"stage variable has no value\""; return 2; }
    done <<< "${snames}"
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-arg "${a}")
    done <<< "${vargs}"
    # What: value-less --build-arg passes proxy from env.
    # Why: predefined args: used by RUN, not in history.
    # From: Issue #1683 | PR #1858
    local produced produced_rc=0
    produced="$(_ci_proxy_names)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r a; do
        [ -n "${a}" ] || continue
        args+=(--build-arg "${a}")
    done <<<"${produced}"
    # What: SOT-owned named build contexts (name=path).
    # Why: Dockerfile COPY --from derives it; SOT owns list.
    # From: Issue #1683
    local produced produced_rc=0
    produced="$(_ci_block_entry_list services "${service}" external_contexts)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r a; do
        [ -n "${a}" ] && args+=(--build-context "${a}")
    done <<<"${produced}"
    # What: write this build's secrets; mount them by id.
    # Why: build-only secrets; cleared after the build.
    # From: Issue #1683 | PR #1858
    local rt line
    if ! rt="$(_ci_set_runtime "${build_type}")"; then
        _ci_clear_runtime >&2 || return 2
        return 2
    fi
    while IFS= read -r line; do
        [ -n "${line}" ] && args+=(--secret "${line#--secret }")
    done <<< "${rt}"
    # What: per-service registry cache-from/to (§35).
    # Why: caller scopes ref per service; a miss is fine.
    # From: Issue #1683
    [ -n "${CI_BUILD_CACHE_FROM:-}" ] && args+=(--cache-from "${CI_BUILD_CACHE_FROM}")
    [ -n "${CI_BUILD_CACHE_TO:-}" ] && args+=(--cache-to "$(_ci_cache_to_spec "${CI_BUILD_CACHE_TO}")")
    # What: retry buildx and capture its output once.
    # Why: ci_error already shows raw; avoid double output.
    # From: Issue #1683
    local buildlog rc=0 crc=0
    buildlog="$(_ci_retry buildx docker buildx build --load --platform "${platform}" --tag "${tag}" "${args[@]}" "${context}")" || rc=$?
    _ci_clear_runtime >&2 || crc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-BUILD-0019]" "service=\"${service}\" platform=\"${platform}\" tag=\"${tag}\" context=\"${context}\" rc=${rc} reason=\"docker buildx build failed (raw above)\""
        return "${rc}"
    fi
    [ "${crc}" -eq 0 ] || return 2
    printf '%s\n' "${buildlog}" >&2
    printf '%s\n' "${tag}"
}

# What: In-image apk setup: repos, update, upgrade, add.
# Why: one owner for http repos + update+upgrade + packages.
# From: Issue #1683
ci_cmd_apk_setup() {
    local root="${CI_APK_ROOT:-}" out kv name bundle=""
    local repos="${root}/etc/apk/repositories" ca
    ca="${root}$(_ci_secret_file project_selfhosted_proxy_ca)"
    if ! out="$(sed -i 's|^https://|http://|' "${repos}" 2>&1)"; then
        ci_error "[CI-ERROR-APKSETUP-0001]" "reason=\"apk repositories not switched to http\"" "${out}"
        return 2
    fi
    # What: proxy CA only for this process, never the image.
    # Why: https fetches pass the TLS proxy; no undo step.
    # From: Issue #1683 | PR #1858
    if [ -s "${ca}" ]; then
        bundle="$(_ci_ca_bundle "[CI-ERROR-APKSETUP-0002]" "${root}${CI_SYSTEM_CA_PATH}" "$(<"${ca}")")" || return 2
        export SSL_CERT_FILE="${bundle}"
    fi
    local -a plain_pkgs=() tagged_pkgs=()
    for kv in "$@"; do
        case "${kv}" in *@*) tagged_pkgs+=("${kv}") ;; *) plain_pkgs+=("${kv}") ;; esac
    done
    _ci_apk_step update || return 2
    _ci_apk_step upgrade || return 2
    [ "${#plain_pkgs[@]}" -eq 0 ] || _ci_apk_step add "${plain_pkgs[@]}" || return 2
    [ -n "${APK_KEYS:-}${APK_TAGGED_REPOS:-}" ] || [ "${#tagged_pkgs[@]}" -gt 0 ] || { [ -z "${bundle}" ] || rm -f "${bundle}"; return 0; }
    # What: tagged repos after the plain set; keys via curl.
    # Why: the fetch owner needs curl, which apk just added.
    # From: Issue #1683 | PR #1858
    for kv in ${APK_KEYS:-}; do
        name="${kv%=*}"; name="${name##*/}"
        _ci_fetch_verified "${kv%=*}" "${kv##*=}" "${root}/etc/apk/keys/${name}" || return 2
    done
    for kv in ${APK_TAGGED_REPOS:-}; do
        kv="@${kv%%=*} ${kv#*=}"
        if ! out="$(printf '%s\n' "${kv}" 2>&1 >> "${repos}")"; then
            ci_error "[CI-ERROR-APKSETUP-0004]" "repo=\"${kv}\" reason=\"tagged repo not added\"" "${out}"
            return 2
        fi
    done
    _ci_apk_step update || return 2
    [ "${#tagged_pkgs[@]}" -eq 0 ] || _ci_apk_step add "${tagged_pkgs[@]}" || return 2
    [ -z "${bundle}" ] || rm -f "${bundle}"
}

# What: fetch, verify and unpack one SOT-pinned apk file.
# Why: a package no current repo has; the SOT owns the pin.
# From: Issue #1683 | PR #1858
ci_cmd_apk_pin_install() {
    local tpl="${1:-}" version="${2:-}" branch="${3:-}" arch="${4:-}" sha="${5:-}" root="${CI_APK_ROOT:-}" url dir out
    if [ -z "${tpl}" ] || [ -z "${version}" ] || [ -z "${branch}" ] || [ -z "${arch}" ]; then
        ci_log "[CI-ERROR-APKSETUP-0006]" "url=\"${tpl}\" version=\"${version}\" branch=\"${branch}\" arch=\"${arch}\" reason=\"url template, version, branch and arch required\""
        return 2
    fi
    url="${tpl//@VERSION@/${version}}"; url="${url//@BRANCH@/${branch}}"; url="${url//@ARCH@/${arch}}"
    dir="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
    _ci_fetch_verified "${url}" "${sha}" "${dir}/pkg.apk" || { rm -rf "${dir}"; return 2; }
    if ! out="$(tar -xzf "${dir}/pkg.apk" -C "${root:-/}" 2>&1)"; then
        ci_error "[CI-ERROR-APKSETUP-0007]" "url=\"${url}\" root=\"${root:-/}\" reason=\"apk not unpacked\"" "${out}"
        rm -rf "${dir}"
        return 2
    fi
    rm -rf "${dir}"
    # What: drop apk metadata files the unpack left in root.
    # Why: they are package-db input, not image content.
    # From: Issue #1683 | PR #1858
    if ! out="$(cd -- "${root:-/}" && rm -f .PKGINFO .SIGN.* .pre-install .post-install .trigger 2>&1)"; then
        ci_error "[CI-ERROR-APKSETUP-0008]" "root=\"${root:-/}\" reason=\"apk metadata not removed\"" "${out}"
        return 2
    fi
    printf 'apk-pin-install=ok url=%s\n' "${url}"
}

# What: one apk step, output shown, coded error with raw.
# Why: every apk call in apk-setup fails the same way.
# From: Issue #1683 | PR #1858
_ci_apk_step() {
    local step="$1" out rc=0
    shift
    out="$(apk "${step}" --no-cache "$@" 2>&1)" || rc=$?
    printf '%s\n' "${out}"
    [ "${rc}" -eq 0 ] && return 0
    ci_error "[CI-ERROR-APKSETUP-0005]" "step=\"apk ${step}\" rc=${rc} reason=\"apk step failed\"" "${out}"
    return 2
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
    out="$(pump --shutdown 2>&1)" && return 0
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

# What: cargo build; drop one accelerator per outage.
# Why: a real build error fails at once, never degrades.
# From: Issue #1683 | PR #1858
_ci_rust_cargo_build() {
    local crate="$1" musl_target="$2" cargo_jobs="$3"
    local cargo_log cargo_status_file cargo_status degraded=0
    local -a layers=()
    # What: active layers from rust-build, dropped in order.
    # Why: rust-build owns ccache_enabled and the disable_*.
    [ "${ccache_enabled:-0}" = "1" ] && layers+=(ccache)
    [ "${_CI_RB_DISTCC}" = "1" ] && layers+=(distcc)
    [ -n "${RUSTC_WRAPPER:-}" ] && layers+=(sccache)
    while :; do
        cargo_log="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
        cargo_status_file="$(_ci_mktemp -p "${CI_TMPDIR}")" || { rm -f "${cargo_log}"; return 2; }
        { set +e; cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" -p "${crate}" 2>&1; echo "$?" >"${cargo_status_file}"; set -e; } | tee "${cargo_log}"
        cargo_status="$(cat "${cargo_status_file}")"; rm -f "${cargo_status_file}"
        if [ "${cargo_status}" = "0" ]; then
            rm -f "${cargo_log}"
            [ "${degraded}" -eq 0 ] || ci_log "[CI-INFO-RUSTBUILD-0009]" "reason=\"cargo build ok after an accelerator fallback\""
            return 0
        fi
        if [ "$(_ci_classify_failure "$(cat "${cargo_log}")" accel)" != transient ]; then
            rm -f "${cargo_log}"
            ci_log "[CI-ERROR-RUSTBUILD-0010]" "rc=${cargo_status} reason=\"cargo build failed without an accelerator outage; no fallback\""
            return "${cargo_status}"
        fi
        rm -f "${cargo_log}"
        degraded=1
        if [ "${#layers[@]}" -eq 0 ]; then
            ci_log "[CI-ERROR-RUSTBUILD-0014]" "rc=${cargo_status} reason=\"accelerator outage output but no accelerator left\""
            return "${cargo_status}"
        fi
        case "${layers[0]}" in
            ccache)
                disable_ccache
                ci_log "[CI-WARN-RUSTBUILD-0011]" "reason=\"accelerator outage; retry without ccache\"" ;;
            distcc)
                disable_distcc || return 2
                ci_log "[CI-WARN-RUSTBUILD-0012]" "reason=\"accelerator outage; retry without distcc\"" ;;
            sccache)
                unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX
                ci_log "[CI-WARN-RUSTBUILD-0013]" "reason=\"accelerator outage; retry without sccache\"" ;;
        esac
        layers=("${layers[@]:1}")
    done
}

# What: Print the distcc wrapper for paths and drivers.
# Why: one generator; ci.bats runs it on fixture paths.
# From: Issue #1533 | PR #1858
_ci_rust_distcc_wrapper() {
    local d
    if [ "$#" -lt 4 ]; then
        ci_error "[CI-ERROR-RUSTBUILD-0045]" "args=$# reason=\"need 3 paths and a driver=path\"" "$(printf '%s\n' "$@")"
        return 2
    fi
    printf '#!/bin/sh\nset -eu\ndistcc_real="%s"\nwrapper_self="%s"\nwrapper_dir="%s"\n' "$1" "$2" "$3"
    shift 3
    printf '%s\n' 'compiler_name="$(basename "$0")"' 'case "$compiler_name" in'
    for d in "$@"; do
        printf '  %s) real_compiler="%s"; local_compiler="%s" ;;\n' "${d%%=*}" "${d%%=*}" "${d#*=}"
    done
    printf '%s\n' \
      '  *)' \
      '    if [ "$#" -ge 1 ] && [ -x "${1:-}" ]; then' \
      '      if ! resolved_arg1="$(readlink -f "$1")"; then' \
      '        echo "[CI-ERROR-RUSTBUILD-0015] arg=$1 reason=\"distcc wrapper: readlink -f failed\"" >&2' \
      '        exit 1' \
      '      fi' \
      '      case "$resolved_arg1" in' \
      '        "$wrapper_self"|"$wrapper_dir"/*)' \
      '          echo "[CI-ERROR-RUSTBUILD-0016] arg=$1 reason=\"distcc wrapper: compiler resolves to the wrapper itself\"" >&2' \
      '          exit 1' \
      '          ;;' \
      '      esac' \
      '      real_compiler="$1"' \
      '      local_compiler="$1"' \
      '      shift' \
      '    else' \
      '      echo "[CI-WARN-RUSTBUILD-0017] argv0=$0 reason=\"distcc wrapper: unknown invocation; default driver\"" >&2'
    printf '      real_compiler="%s"; local_compiler="%s"\n' "${1%%=*}" "${1#*=}"
    printf '%s\n' \
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
      '  echo "[CI-INFO-RUSTBUILD-0018] input=$matched_arg reason=\"generated header; distcc without pump\"" >&2' \
      '  if [ -n "${DISTCC_HOSTS_NO_PUMP:-}" ]; then' \
      '    env -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID DISTCC_HOSTS="$DISTCC_HOSTS_NO_PUMP" "$distcc_real" "$real_compiler" "$@"' \
      '    exit $?' \
      '  fi' \
      '  echo "[CI-INFO-RUSTBUILD-0019] reason=\"no non-pump distcc host; local compiler\"" >&2' \
      '  env -u DISTCC_HOSTS -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID -u DISTCC_FALLBACK "$local_compiler" "$@"' \
      '  exit $?' \
      'fi' \
      'exec "$distcc_real" "$real_compiler" "$@"'
}

# What: print the workspace members of a Cargo manifest.
# Why: one members reader for stubs and version-drift.
# From: Issue #1683 | PR #1858
_ci_cargo_members() {
    awk '/^members *= *\[/ { on = 1; next } on && /^\]/ { exit } on { gsub(/[",[:space:]]/, ""); if ($0 != "") print }' "$1"
}

# What: stub missing bin/lib targets of workspace members.
# Why: cargo loads every member; images copy manifests only.
# From: Issue #1683 | PR #1858
_ci_rust_member_stubs() {
    local members m sec p f targets
    members="$(_ci_cargo_members Cargo.toml)" || return 2
    if [ -z "${members}" ]; then
        ci_log "[CI-ERROR-RUSTBUILD-0042]" "dir=\"${PWD}\" reason=\"no workspace members in Cargo.toml\""
        return 2
    fi
    while IFS= read -r m; do
        if [ ! -f "${m}/Cargo.toml" ]; then
            ci_log "[CI-ERROR-RUSTBUILD-0043]" "member=\"${m}\" reason=\"member manifest missing\""
            return 2
        fi
        targets="$(_ci_capture 0 awk '/^\[\[bin\]\]/ { s = "bin"; next } /^\[lib\]/ { s = "lib"; next } /^\[/ { s = ""; next }
            s != "" && /^path *=/ { v = $0; sub(/^path *= *"/, "", v); sub(/".*$/, "", v); print s "\t" v }' "${m}/Cargo.toml")" || return 2
        # What: a member with no declared target path stops
        # Why: cargo fails on a member with no stub
        # From: Issue #1683 | PR #1905
        if [ -z "${targets}" ]; then
            ci_log "[CI-ERROR-RUSTBUILD-0049]" "member=\"${m}\" reason=\"no [lib] or [[bin]] path declared; a manifest-only stage cannot stub it\""
            return 2
        fi
        while IFS=$'\t' read -r sec p; do
            [ -n "${p}" ] || continue
            f="${m}/${p}"
            [ -e "${f}" ] && continue
            mkdir -p "${f%/*}" || return 2
            if [ "${sec}" = bin ]; then printf 'fn main() {}\n' > "${f}"; else : > "${f}"; fi
            printf '%s\n' "${f}"
        done <<< "${targets}"
    done <<< "${members}"
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
    local acc masq pairs p distcc_bin sccache_bin
    local -a drivers=()
    local -A driver_path=()
    acc="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
    masq="${acc}/masq"
    mkdir -p "${masq}"
    pairs="$(_ci_build_tools_compilers)" || return 2
    # What: resolve the real tools before any masquerade.
    # Why: wrapper and ccache call the real compiler paths.
    # From: Issue #1683 | PR #1858
    while IFS= read -r p; do
        if ! driver_path["${p%%=*}"]="$(command -v "${p#*=}")"; then
            ci_error "[CI-ERROR-RUSTBUILD-0046]" "driver=\"${p#*=}\" reason=\"compiler driver not on PATH\"" "PATH=${PATH}"
            return 2
        fi
        drivers+=("${p#*=}=${driver_path[${p%%=*}]}")
    done <<< "${pairs}"
    distcc_bin="$(command -v distcc)" || { ci_error "[CI-ERROR-RUSTBUILD-0047]" "reason=\"distcc not on PATH\"" "PATH=${PATH}"; return 2; }
    sccache_bin="$(command -v sccache)" || { ci_error "[CI-ERROR-RUSTBUILD-0048]" "reason=\"sccache not on PATH\"" "PATH=${PATH}"; return 2; }
    cp "${distcc_bin}" "${acc}/distcc-real"
    _ci_rust_distcc_wrapper "${acc}/distcc-real" "${acc}/distcc-wrapper" "${masq}" "${drivers[@]}" > "${acc}/distcc-wrapper" || return 2
    chmod +x "${acc}/distcc-wrapper"
    for p in "${drivers[@]}"; do ln -sf "${acc}/distcc-wrapper" "${masq}/${p%%=*}"; done
    ln -sf "${acc}/distcc-wrapper" "${distcc_bin}"
    # What: rustc wrapper: distcc passthrough, else sccache.
    # Why: distcc bypasses sccache masquerade wrapping.
    printf '%s\n' '#!/bin/sh' 'case "${1:-}" in' '  distcc|*/distcc) exec "$@" ;;' "  *) exec \"${sccache_bin}\" \"\$@\" ;;" 'esac' > "${acc}/rustc-wrapper"
    chmod +x "${acc}/rustc-wrapper"
    local ccache_enabled=0 original_path="${PATH}"
    _CI_RB_DISTCC=0
    _CI_RB_CA=0
    trap _ci_rust_build_cleanup EXIT
    # What: trust proxy CA for cargo's crates.io fetch.
    # Why: cleanup trap removes it; never persisted.
    local ca_src
    ca_src="$(_ci_secret_file project_selfhosted_proxy_ca)"
    if [ -s "${ca_src}" ]; then
        cp "${ca_src}" "${_CI_RB_CA_FILE}"
        update-ca-certificates >/dev/null
        _CI_RB_CA=1
    fi
    # What: export each SOT compiler var as its driver name.
    # Why: the masquerade dir on PATH then serves each one.
    # From: Issue #1683 | PR #1858
    export_drivers() {
        local q
        while IFS= read -r q; do export "${q?}"; done <<< "${pairs}"
    }
    configure_sccache() {
        unset CARGO_MAKEFLAGS MAKEFLAGS
        # What: dist config before the server starts.
        # Why: a running server never rereads SCCACHE_CONF.
        # From: Issue #1683 | PR #1858
        local dist
        dist="$(_ci_secret_file sccache_dist_config)"
        if [ -s "${dist}" ]; then export SCCACHE_CONF="${dist}"; fi
        _ci_sccache_env "${key_prefix}" "${acc}/rustc-wrapper" || return 2
        if [ -n "${SCCACHE_CONF:-}" ]; then sccache --dist-status; fi
    }
    disable_distcc() {
        _ci_rust_stop_pump || return 1
        unset DISTCC_POTENTIAL_HOSTS DISTCC_HOSTS DISTCC_HOSTS_NO_PUMP DISTCC_FALLBACK INCLUDE_SERVER_PORT INCLUDE_SERVER_PID "${!driver_path[@]}"
        PATH="${original_path}"; export PATH
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
        local hosts_file
        hosts_file="$(_ci_secret_file distcc_potential_hosts)"
        if [ -s "${hosts_file}" ]; then
            local distcc_probe_dir
            distcc_probe_dir="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
            DISTCC_POTENTIAL_HOSTS="$(cat "${hosts_file}")"; export DISTCC_POTENTIAL_HOSTS
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
                ci_log "[CI-ERROR-RUSTBUILD-0021]" "reason=\"DISTCC_POTENTIAL_HOSTS has no usable host\""; return 1
            fi
            local distcc_pump_hosts="${distcc_hosts_with_pump:-}"
            distcc_hosts_without_pump="${distcc_hosts_without_pump:-${distcc_hosts}}"
            ci_log "[CI-INFO-RUSTBUILD-0022]" "hosts=\"${distcc_hosts}\" reason=\"distcc on\""
            export DISTCC_HOSTS_NO_PUMP="${distcc_hosts_without_pump}"
            export PATH="${masq}:${PATH}" DISTCC_FALLBACK=0
            export_drivers
            _CI_RB_DISTCC=1
            if [ -n "${distcc_pump_hosts}" ]; then
                export DISTCC_POTENTIAL_HOSTS="${distcc_pump_hosts}"
                unset DISTCC_HOSTS
                local distcc_pump_env
                if ! distcc_pump_env="$(pump --startup 2>"${distcc_probe_dir}/distcc-pump.log")"; then
                    ci_error "[CI-WARN-RUSTBUILD-0023]" "reason=\"distcc pump unavailable; local C compiler\"" "$(cat "${distcc_probe_dir}/distcc-pump.log")"
                    disable_distcc; rm -rf "${distcc_probe_dir}"; return 0
                fi
                eval "${distcc_pump_env}"
                local -a distcc_hosts_arr; read -ra distcc_hosts_arr <<<"${DISTCC_HOSTS:-}"
                local distcc_pump_real_hosts="" distcc_host_token
                for distcc_host_token in "${distcc_hosts_arr[@]}"; do case "${distcc_host_token}" in --*) ;; *) distcc_pump_real_hosts=1 ;; esac; done
                if [ -z "${distcc_pump_real_hosts}" ]; then unset DISTCC_HOSTS; fi
                PATH="${masq}:${PATH}"
                export PATH DISTCC_HOSTS_NO_PUMP
                export_drivers
            else
                export DISTCC_HOSTS="${distcc_hosts}"
            fi
            printf '%s\n' 'int main(void) { return 0; }' > "${distcc_probe_dir}/distcc-probe.c"
            if ! cc -c "${distcc_probe_dir}/distcc-probe.c" -o "${distcc_probe_dir}/distcc-probe.o" >"${distcc_probe_dir}/distcc-probe.log" 2>&1; then
                ci_error "[CI-WARN-RUSTBUILD-0024]" "reason=\"distcc probe failed; local C compiler\"" "$(cat "${distcc_probe_dir}/distcc-probe.log")"
                disable_distcc; rm -rf "${distcc_probe_dir}"; return 0
            fi
            extract_remote_toolchain_id "${distcc_probe_dir}/distcc-probe.o"
            rm -rf "${distcc_probe_dir}"
        else
            ci_log "[CI-INFO-RUSTBUILD-0025]" "reason=\"distcc off; no distcc_potential_hosts secret\""
        fi
    }
    disable_ccache() {
        ccache_enabled=0
        unset CCACHE_REMOTE_STORAGE CCACHE_DIR CCACHE_COMPILERCHECK CCACHE_PREFIX CCACHE_EXTRAFILES CCACHE_BASEDIR
        rm -f "${CI_TMPDIR}/ccache-toolchain-id" "${CI_TMPDIR}/ccache-remote-toolchain-id"
        export_drivers
    }
    # What: wrap distcc with ccache (Redis) once distcc up.
    # Why: content-check + remote-id guard stale toolchain.
    configure_ccache() {
        local url_file
        url_file="$(_ci_secret_file ccache_redis_url)"
        if [ "${_CI_RB_DISTCC}" = "1" ] && [ -s "${url_file}" ]; then
            if [ ! -s "${CI_TMPDIR}/ccache-remote-toolchain-id" ]; then
                ci_log "[CI-INFO-RUSTBUILD-0026]" "reason=\"ccache off; no remote distcc toolchain identity\""; return 0
            fi
            local ccache_probe_dir
            ccache_probe_dir="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
            ci_log "[CI-INFO-RUSTBUILD-0027]" "reason=\"ccache on over distcc with redis storage\""
            local ccache_redis_endpoint
            ccache_redis_endpoint="$(cat "${url_file}")"
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
            local k
            for k in "${!driver_path[@]}"; do export "${k}=ccache ${driver_path[${k}]}"; done
            ccache_enabled=1
            printf '%s\n' 'int main(void) { return 0; }' > "${ccache_probe_dir}/ccache-probe.c"
            # What: probe compiles in isolated ccache dir.
            # Why: keep real cache clean; word-split-safe.
            local ccache_probe_cache_dir="${ccache_probe_dir}/probe-cache"
            mkdir -p "${ccache_probe_cache_dir}"
            if ! ( cd "${ccache_probe_dir}" && CCACHE_DIR="${ccache_probe_cache_dir}" ccache "${driver_path[${pairs%%=*}]}" -c ccache-probe.c -o ccache-probe.o ) >"${ccache_probe_dir}/ccache-probe.log" 2>&1; then
                ci_error "[CI-WARN-RUSTBUILD-0028]" "reason=\"ccache probe failed; plain distcc\"" "$(cat "${ccache_probe_dir}/ccache-probe.log")"
                disable_ccache; rm -rf "${ccache_probe_dir}"; return 0
            fi
            local ccache_probe_stats="${ccache_probe_dir}/ccache-probe-stats.log"
            ccache --print-stats > "${ccache_probe_stats}"
            local stat_err stat_ok
            stat_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' "${ccache_probe_stats}")" || return 2
            stat_ok="$(_ci_capture 1 grep -E '^remote_storage_(write|hit)[[:space:]]+[1-9]' "${ccache_probe_stats}")" || return 2
            if [ -n "${stat_err}" ] || [ -z "${stat_ok}" ]; then
                ci_error "[CI-WARN-RUSTBUILD-0029]" "reason=\"ccache redis round trip failed; plain distcc\"" "$(cat "${ccache_probe_stats}")"
                disable_ccache; rm -rf "${ccache_probe_dir}"; return 0
            fi
            rm -rf "${ccache_probe_dir}"
        else
            if [ "${_CI_RB_DISTCC}" != "1" ]; then
                ci_log "[CI-INFO-RUSTBUILD-0030]" "reason=\"ccache off; distcc off\""
            else
                ci_log "[CI-INFO-RUSTBUILD-0031]" "reason=\"ccache off; no ccache_redis_url secret\""
            fi
        fi
    }
    # What: export release LTO/codegen vars, fail closed.
    # Why: no defaults; owner is PROJECT_CARGO_*.
    resolve_cargo_profile_overrides() {
        local lto="${PROJECT_CARGO_LTO:-}" cgu="${PROJECT_CARGO_CODEGENUNIT:-}"
        [ -n "${lto}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0032]" "reason=\"PROJECT_CARGO_LTO missing; it has no default\""; return 1; }
        case "${lto}" in off|thin|fat|true|false) ;; *) ci_log "[CI-ERROR-RUSTBUILD-0033]" "got=\"${lto}\" reason=\"PROJECT_CARGO_LTO not off/thin/fat/true/false\""; return 1;; esac
        [ -n "${cgu}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0034]" "reason=\"PROJECT_CARGO_CODEGENUNIT missing; it has no default\""; return 1; }
        case "${cgu}" in *[!0-9]*) ci_log "[CI-ERROR-RUSTBUILD-0035]" "got=\"${cgu}\" reason=\"PROJECT_CARGO_CODEGENUNIT not a number\""; return 1;; esac
        [ "${cgu}" -gt 0 ] || { ci_log "[CI-ERROR-RUSTBUILD-0036]" "got=\"${cgu}\" reason=\"PROJECT_CARGO_CODEGENUNIT must be above zero\""; return 1; }
        export CARGO_PROFILE_RELEASE_LTO="${lto}" CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${cgu}"
        ci_log "[CI-INFO-RUSTBUILD-0037]" "lto=\"${lto}\" codegen_units=${cgu} reason=\"release profile\""
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
        case "${jobs}" in ''|*[!0-9]*) ci_log "[CI-ERROR-RUSTBUILD-0038]" "got=\"${jobs}\" reason=\"CARGO_BUILD_JOBS not a number\""; return 1;; esac
        [ "${jobs}" -gt 0 ] || { ci_log "[CI-ERROR-RUSTBUILD-0039]" "got=\"${jobs}\" reason=\"CARGO_BUILD_JOBS must be above zero\""; return 1; }
        ci_log "[CI-INFO-RUSTBUILD-0040]" "jobs=${jobs} source=\"${jobs_source}\" reason=\"cargo jobs\""
        printf '%s\n' "${jobs}"
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
    local stubs s
    stubs="$(_ci_rust_member_stubs)" || return 2
    _ci_rust_cargo_build "${crate}" "${musl_target}" "${cargo_jobs}"
    # What: remove exactly the stub files this run created.
    # Why: a stub left behind would ship in the real build.
    # From: Issue #1683 | PR #1858
    while IFS= read -r s; do
        [ -z "${s}" ] || _ci_run "[CI-ERROR-RUSTBUILD-0044]" "file=\"${s}\" reason=\"stub not removed\"" rm -f -- "${s}" \
            > /dev/null || return 2
    done <<< "${stubs}"
    # What: dump ccache stats; mid-build Redis error OK.
    # Why: binary correct; only cache reuse degraded.
    if [ "${ccache_enabled:-0}" = "1" ]; then
        ccache -s
        local ccache_final_stats
        ccache_final_stats="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
        ccache --print-stats > "${ccache_final_stats}"
        local final_err
        final_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' "${ccache_final_stats}")" || return 2
        if [ -n "${final_err}" ]; then
            ci_error "[CI-WARN-RUSTBUILD-0041]" "reason=\"ccache redis error during the build; binary unaffected\"" "$(cat "${ccache_final_stats}")"
        fi
        rm -f "${ccache_final_stats}"
    fi
    # What: copy built binary out only for real build.
    # Why: deps pre-cache pass produces no shippable binary.
    if [ "${mode}" = "build" ]; then
        cp "target/${musl_target}/release/${crate}" "/build/${crate}-out"
    fi
}

# What: Inspect a ref's digest or raw index; 1 = absent.
# Why: one reader; transient retries; callers own the id.
# From: Issue #1683 | PR #1858
_ci_registry_read() {
    local ref="$1" view="$2" id="$3" absent="$4" out cls rc=0
    local -a how=(--raw)
    [ "${view}" = raw ] || how=(--format '{{.Manifest.Digest}}')
    out="$(_ci_retry registry-read docker buildx imagetools inspect "${ref}" "${how[@]}")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        if [ "${view}" = raw ] || [[ "${out}" =~ ^${CI_DIGEST_RE}$ ]]; then
            printf '%s\n' "${out}"
            return 0
        fi
        ci_error "${id}" "ref=\"${ref}\" reason=\"registry read gave no digest\"" "${out}"
        return 2
    fi
    if [ "${rc}" -eq 1 ] && [ "${absent}" = ok ]; then return 1; fi
    cls="$(_ci_classify_failure "${out}" registry-read)"
    ci_error "${id}" "ref=\"${ref}\" cls=${cls} reason=\"registry read failed\"" "${out}"
    return 2
}

# What: Read a pushed tag's immutable registry digest.
# Why: publish/verify readback; an absent tag is an error.
# From: Issue #1683
_ci_registry_digest() {
    _ci_registry_read "$1" digest "[CI-ERROR-RESOLVE-0011]" fail
}

# What: Probe a tag's digest; 1 not-found, 2 unknown.
# Why: only a real miss may build; auth stays UNKNOWN.
# From: Issue #1683
_ci_registry_probe() {
    _ci_registry_read "$1" digest "[CI-WARN-RESOLVE-0007]" ok
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
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")" || return 2
    _ci_retry registry docker push "${tag}" >/dev/null || return "$?"
    _ci_registry_digest "${tag}"
}

# What: one trivy run; a written report ends the retries.
# Why: a finding is deterministic and never retried.
# From: Issue #1683 | PR #1858
_ci_trivy_scan_once() {
    local report="$1" ref="$2"
    shift 2
    : > "${report}"
    "$@" --output "${report}" "${ref}" && return 0
    [ -s "${report}" ]
}

# What: Probe a dir with a real file+subdir write/read.
# Why: A stale/listable mount may still fail real I/O.
# From: Issue #1683
_ci_trivy_dir_writable() {
    local dir="$1" probe subdir
    [ -d "${dir}" ] || return 1
    probe="${dir}/.trivy-cache-dir-write-probe.$$.${RANDOM}"
    subdir="${dir}/.trivy-cache-dir-write-probe-dir.$$.${RANDOM}"
    # What: an && chain, not set -e, carries every failure.
    # Why: callers run this in an if, where set -e is off.
    # From: Issue #1683 | PR #1858
    { printf 'probe' > "${probe}" \
        && [ "$(cat "${probe}")" = "probe" ] \
        && rm -f "${probe}" \
        && mkdir "${subdir}" \
        && printf 'probe' > "${subdir}/probe" \
        && [ "$(cat "${subdir}/probe")" = "probe" ] \
        && rm -rf "${subdir}"; } 2>&1
}

# What: Resolve a persistent Trivy DB cache-dir.
# Why: NFS-shared or real local disk, never tmpfs/tmp.
# From: Issue #1683
_ci_trivy_cache_dir() {
    local shared
    shared="$(_ci_variable CI_TRIVY_SHARED_DIR)" || return 2
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
    local poll waited=0 lock_mtime age mkerr
    poll="$(_ci_variable CI_TRIVY_LOCK_POLL)" || return 2
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
    local lock_timeout stale_after
    lock_timeout="$(_ci_variable CI_TRIVY_LOCK_TIMEOUT)" || return 2
    stale_after="$(_ci_variable CI_TRIVY_LOCK_STALE)" || return 2
    if _ci_trivy_db_fresh "${cache_dir}"; then
        printf 'present=true\n'
        return 0
    fi
    _ci_trivy_db_lock_run "${cache_dir}" "${lock_timeout}" "${stale_after}" -- \
        trivy image --download-db-only --cache-dir "${cache_dir}" || rc=$?
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

# What: trivy image argv for one scan, one item per line
# Why: one owner; a test runs it through the real trivy
# From: Issue #1683 | PR #1858
_ci_trivy_args() {
    local cache_dir="$1" skip_db="$2" scanners ignore
    scanners="$(_ci_variable CI_TRIVY_SCANNERS)" || return 2
    ignore="$(_ci_repo_path CI_TRIVY_IGNORE)" || return 2
    printf '%s\n' trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed \
        --scanners "${scanners}" --cache-dir "${cache_dir}"
    [ "${skip_db}" -ne 1 ] || printf '%s\n' --skip-db-update
    [ ! -f "${ignore}" ] || printf '%s\n' --ignorefile "${ignore}"
    [ -z "${CI_TRIVY_TIMEOUT:-}" ] || printf '%s\n' --timeout "${CI_TRIVY_TIMEOUT}"
}

# What: Scan an image digest; rc 1 finding, 3 DB, 4 run
# Why: a failed run or a DB gap is never read as a finding
# From: Issue #1683 | PR #1858
_ci_trivy_scan() {
    local service="$1" digest="$2" ref report rc=0 out
    local cache_rec cache_dir fresh_rec skip_db=0
    local -a targs
    cache_rec="$(_ci_trivy_cache_dir)" || return 3
    cache_dir="$(_ci_record_field "${cache_rec}" dir)"
    fresh_rec="$(_ci_trivy_db_ensure_fresh "${cache_dir}")" || return 3
    [ "$(_ci_record_field "${fresh_rec}" present)" = "true" ] && skip_db=1
    ref="$(_ci_image_ref "${service}" "${digest}")" || return 2
    out="$(_ci_trivy_args "${cache_dir}" "${skip_db}")" || return 2
    mapfile -t targs <<< "${out}"
    report="$(_ci_mktemp "${CI_TMPDIR}/ci-trivy.XXXXXX")" || return 2
    _ci_retry trivy _ci_trivy_scan_once "${report}" "${ref}" "${targs[@]}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${report}"
        return 4
    fi
    # What: A written report means trivy scanned.
    # Why: A finding is deterministic; no retry.
    # From: Issue #1683
    if [ -s "${report}" ]; then
        cat "${report}" >&2
        rm -f "${report}"
        return 1
    fi
    rm -f "${report}"
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
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-WARN-IMPACT-0007]" "service=\"${service}\" platform=\"${platform}\" cmd=\"${CI_IMPACT_CMD}\" rc=${rc} reason=\"impact command failed; UNKNOWN\"" "${out}"
            printf 'UNKNOWN\n'; return 0
        fi
        case "${out}" in
            BUILD|NOOP|UNKNOWN) printf '%s\n' "${out}" ;;
            *)
                ci_error "[CI-WARN-IMPACT-0008]" "service=\"${service}\" platform=\"${platform}\" cmd=\"${CI_IMPACT_CMD}\" reason=\"impact command gave no BUILD/NOOP/UNKNOWN; UNKNOWN\"" "${out}"
                printf 'UNKNOWN\n'
                ;;
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
    bm="$(_ci_mktemp -p "${CI_TMPDIR}")" || { printf 'UNKNOWN\n'; return 0; }
    if _ci_manifest_at "${base}" "${bm}" && [ -s "${bm}" ]; then
        v="$(_ci_impact_classify "${service}" "${platform}" "${identity}" "${base}" "${bm}")"
    else
        ci_log "[CI-INFO-IMPACT-0006]" "service=\"${service}\" platform=\"${platform}\" base=\"${base}\" reason=\"no SOT at base; UNKNOWN, escalate, BUILD DISACK\""
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
    build_type="$(ci_service_field "${service}" build_type)" || return 2

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
        ci_log "[CI-ERROR-BUILD-0009]" "service=\"${service}\" platform=\"${platform}\" impact=\"${impact}\" state=\"${state}\" identity=\"${identity}\" reason=\"admission needs impact=BUILD, state=MISSING_CONFIRMED and an identity; no BUILD_ACK\""
        return 2
    }
    printf '%s\n' "${ack}"

    # What: reuse a CAS binary before compiling.
    # Why: an identical binary need not rebuild.
    # From: Issue #1683
    if [ "${build_type}" = "rust" ]; then
        local crc=0
        _ci_cas_lookup "${identity}" >/dev/null || crc=$?
        if [ "${crc}" -eq 0 ]; then
            printf 'service=%s platform=%s result=reuse-binary-cas identity=%s\n' "${service}" "${platform}" "${identity}"
            return 0
        fi
        ci_log "[CI-INFO-BUILD-0018]" "service=\"${service}\" platform=\"${platform}\" identity=\"${identity}\" cas_rc=${crc} reason=\"no CAS binary; compiling\""
    fi

    _ci_require_ghcr_auth || return "$?"
    _ci_docker_build "${service}" "${identity}" "${platform}" || return "$?"
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
# Why: push, then the registry digest is what was published.
# From: Issue #1683
_ci_publish_one() {
    local service="$1" platform="$2"
    local identity digest
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    digest="$(_ci_docker_publish "${service}" "${identity}" "${platform}")" || {
        ci_log "[CI-ERROR-PUBLISH-0005]" "service=\"${service}\" platform=\"${platform}\" reason=\"docker publish failed\""
        return 2
    }
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
    # What: bake guard on the local image before publish.
    # Why: a leaked CA or build var must never reach GHCR.
    # From: Issue #1781 | PR #1858
    local tag
    if ! tag="$(_ci_image_tag "${service}" "${platform}" "$(_ci_record_field "${out}" identity)" 2>&1)"; then
        ci_error "[CI-ERROR-SHIP-0003]" "service=\"${service}\" platform=\"${platform}\" reason=\"built image tag not derivable; no bake check, no publish\"" "${tag}"
        return 2
    fi
    _ci_bake_check "${tag}" || return "$?"
    out="$(ci_cmd_publish "${service}" "${platform}")" || return "$?"
    printf '%s\n' "${out}"
    digest="$(_ci_record_field "${out}" published)"
    if [ -z "${digest}" ]; then
        ci_error "[CI-ERROR-SHIP-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"publish reported no digest\"" "${out}"
        return 2
    fi
    ci_cmd_verify "${service}" "${digest}" "${platform}"
}

# What: Read one platform image back; smoke it at digest.
# Why: BUILT != ACCEPTED; a MISMATCH must fail (§7).
# From: Issue #1683
_ci_verify_one() {
    local service="$1" platform="$2" expected="$3" seen identity tag verify_type
    _ci_require_ghcr_auth || return "$?"
    identity="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")" || return 2
    seen="$(_ci_registry_digest "${tag}")" || {
        ci_log "[CI-ERROR-VERIFY-0006]" "service=\"${service}\" tag=\"${tag}\" reason=\"registry readback failed\""
        return 2
    }
    if [ "${seen}" != "${expected}" ]; then
        ci_error "[CI-ERROR-VERIFY-0005]" "service=\"${service}\" reason=\"digest MISMATCH; produced != accepted\" expected=\"${expected}\"" "readback=${seen}"
        return 2
    fi
    # What: smoke-test every built image at its digest.
    # Why: §25 SERVICE_TESTED follows IDENTITY_VERIFIED.
    # From: Issue #1683 | PR #1858
    verify_type="$(ci_service_field "${service}" build_type)" || return 2
    if [ "${verify_type}" = toolchain ]; then
        local CI_TOOLCHAIN_IMAGE
        CI_TOOLCHAIN_IMAGE="$(_ci_image_ref "${service}" "${expected}")" || return 2
        _ci_test_toolchain "${service}" || return "$?"
    else
        local CI_SERVICE_IMAGE
        CI_SERVICE_IMAGE="$(_ci_image_ref "${service}" "${expected}")" || return 2
        _ci_smoke_service "${service}" || return "$?"
    fi
    printf 'service=%s verified=%s\n' "${service}" "${seen}"
}

# What: Verify one target platform against its digest.
# Why: a digest is per platform; input fails before login.
# From: Issue #1683
ci_cmd_verify() {
    local service="${1:-}" expected="${2:-}" platform="${3:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-VERIFY-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${expected}" ] || { ci_log "[CI-ERROR-VERIFY-0002]" "reason=\"expected digest arg required\""; return 2; }
    [ -n "${platform}" ] || { ci_log "[CI-ERROR-VERIFY-0004]" "service=\"${service}\" reason=\"platform arg required; a digest is per platform\""; return 2; }
    _ci_for_platforms "${service}" "${platform}" "[CI-ERROR-VERIFY-0007]" _ci_verify_one "${expected}"
}

# What: rc 0 only if CI_RUST_VALIDATION is exactly "true".
# Why: AG-VAL-008: CI rust validation is off by default.
# From: Issue #1683
_ci_rust_validation_enabled() {
    local v
    v="$(_ci_variable CI_RUST_VALIDATION)" || return 2
    [ "${v}" = true ]
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
    ctx="$(ci_service_field "${service}" crate)" || return 2
    if [ -z "${ctx}" ]; then
        ci_log "[CI-ERROR-TEST-0005]" "service=\"${service}\" reason=\"no crate in SOT\""
        return 2
    fi
    # What: workspace-root cargo on service's own crate.
    # Why: build context is no crate; AG-VAL-008 per crate.
    # From: PR #1858
    local trc=0
    ( _ci_sccache_env "lancache-${service}" || exit 200
        trap _ci_sccache_stop EXIT
        cd "${CI_REPO_ROOT:-.}" \
            && cargo fmt --check -p "${ctx}" \
            && cargo clippy --locked --all-targets -p "${ctx}" -- -D warnings \
            && cargo test --locked -p "${ctx}" ) || trc=$?
    # What: 200 = sccache setup error -> rc 2, not FAIL.
    # Why: §72: infra UNKNOWN never reads as a test FAIL.
    # From: Issue #1683 | PR #1858
    case "${trc}" in
        0) ;;
        200) ci_log "[CI-ERROR-TEST-0009]" "service=\"${service}\" crate=\"${ctx}\" reason=\"sccache setup failed (raw above); not a test result\""; return 2 ;;
        *) ci_log "[CI-ERROR-TEST-0010]" "service=\"${service}\" crate=\"${ctx}\" rc=${trc} reason=\"cargo fmt/clippy/test failed (cargo output above)\""; return 1 ;;
    esac
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Assert smoke tools exist and smoke runs pass.
# Why: SOT owns both lists; present is not runnable.
# From: Issue #1683 | PR #1858
_ci_test_toolchain() {
    local service="$1" image tools runs
    image="${CI_TOOLCHAIN_IMAGE:-}"
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-TEST-0006]" "service=\"${service}\" reason=\"CI_TOOLCHAIN_IMAGE required for the smoke\""
        return 2
    fi
    tools="$(_ci_build_tools_smoke smoke_tools)" || return 2
    runs="$(_ci_build_tools_smoke smoke_runs)" || return 2
    _ci_image_smoke "[CI-ERROR-TEST-0011]" "${service}" "toolchain smoke failed; missing tool or failing run" \
        "${image}" "${tools}" "${runs}" || return "$?"
    printf 'service=%s tested=ok\n' "${service}"
}

# What: Execute-smoke a product image's SOT smoke checks.
# Why: prove apk binaries run, not just exist.
# From: Issue #1613
_ci_smoke_service() {
    local service="$1" checks image
    checks="$(_ci_service_smoke "${service}")" || return 2
    if [ -z "${checks}" ]; then
        printf 'service=%s smoke=SKIP reason=no SOT smoke\n' "${service}"
        return 0
    fi
    image="${CI_SERVICE_IMAGE:-}"
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-TEST-0007]" "service=\"${service}\" reason=\"CI_SERVICE_IMAGE required for the smoke\""
        return 2
    fi
    _ci_image_smoke "[CI-ERROR-TEST-0008]" "${service}" "execute-smoke failed; missing lib?" \
        "${image}" "" "${checks}" || return "$?"
    printf 'service=%s smoke=ok checks=%s\n' "${service}" "$(grep -c . <<< "${checks}")"
}

# What: run SOT smoke in an image: tools found, runs pass.
# Why: one executor for product and toolchain smoke.
# From: Issue #1683 | PR #1858
_ci_image_smoke() {
    local code="$1" service="$2" reason="$3" image="$4" tools="$5" runs="$6" limit grace out t
    local -a tl=()
    limit="$(_ci_variable CI_SMOKE_TIMEOUT)" || return 2
    grace="$(_ci_variable CI_SMOKE_KILL_AFTER)" || return 2
    while IFS= read -r t; do [ -n "${t}" ] && tl+=("${t}"); done <<< "${tools}"
    # What: tools go as args; runs on stdin, one a line.
    # Why: a run holds spaces/pipes; stdin keeps it intact.
    # From: Issue #1683 | PR #1858
    if ! out="$(docker run --rm -i --entrypoint timeout "${image}" --kill-after="${grace}" --signal=TERM "${limit}" \
        bash -c 'for t in "$@"; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done
            while IFS= read -r r; do
                [ -n "${r}" ] || continue
                o="$(bash -o pipefail -c "${r}" 2>&1)" || { printf "failed: %s\n%s\n" "${r}" "${o}"; exit 1; }
            done' _ "${tl[@]}" <<< "${runs}" 2>&1)"; then
        t="${out%%$'\n'*}"
        ci_error "${code}" "service=\"${service}\" check=\"${t#failed: }\" reason=\"${reason}\"" "${out}"
        return 1
    fi
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
    if raw="$(_ci_default_test "${service}" 2>&1)"; then status=0; else status=$?; fi
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

# What: one coded line per _ci_trivy_scan status; rc
# Why: a run, DB or setup failure never reads as a finding
# From: Issue #1683 | PR #1858
_ci_scan_outcome() {
    local service="$1" status="$2" raw="$3"
    case "${status}" in
        0) return 0 ;;
        1) ci_error "[CI-ERROR-SCAN-0005]" "service=\"${service}\" reason=\"scan reported findings\"" "${raw}"; return 2 ;;
        3) ci_error "[CI-ERROR-SCAN-0006]" "service=\"${service}\" reason=\"scan DB unavailable after retries; not a finding, escalate\"" "${raw}"; return 3 ;;
        4) ci_error "[CI-ERROR-SCAN-0021]" "service=\"${service}\" reason=\"trivy run failed without a report; not a finding, escalate\"" "${raw}"; return 3 ;;
        *) ci_error "[CI-ERROR-SCAN-0022]" "service=\"${service}\" rc=${status} reason=\"scan setup failed; not a finding\"" "${raw}"; return 2 ;;
    esac
}

# What: Scan a published digest for vulnerabilities.
# Why: /var/tmp staging (no tmpfs OOM), authed, fail-closed.
# From: Issue #1683
ci_cmd_scan() {
    local service="${1:-}" digest="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-SCAN-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${digest}" ] || { ci_log "[CI-ERROR-SCAN-0002]" "reason=\"digest arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local raw status
    if raw="$(TMPDIR="${CI_TMPDIR}" _ci_trivy_scan "${service}" "${digest}" 2>&1)"; then status=0; else status=$?; fi
    _ci_scan_outcome "${service}" "${status}" "${raw}" || return "$?"
    printf 'service=%s scanned=clean digest=%s tmpdir=%s\n' "${service}" "${digest}" "${CI_TMPDIR}"
}

# =========================================================
# ASSEMBLY
# =========================================================

# What: Look up an ACCEPTED per-platform digest.
# Why: the ledger record is the only digest source
# From: Issue #1683
_ci_accepted_digest() {
    local service="$1" platform="$2"
    local identity rec rc=0 remote
    identity="$(_ci_identity_for "${service}" "${platform}")" || return 2
    remote="$(_ci_git_remote)" || return 2
    rec="$(_ci_ledger_read "${remote}" "${identity}")" || rc=$?
    if [ "${rc}" -eq 1 ]; then
        ci_log "[CI-INFO-ASSEMBLE-0008]" "service=\"${service}\" platform=\"${platform}\" identity=\"${identity}\" reason=\"no ledger record\""
        return 1
    fi
    [ "${rc}" -eq 0 ] || return "${rc}"
    if [ "${rec%%$'\t'*}" != ACCEPTED ]; then
        ci_log "[CI-INFO-ASSEMBLE-0009]" "service=\"${service}\" platform=\"${platform}\" identity=\"${identity}\" record=\"${rec}\" reason=\"ledger record not ACCEPTED\""
        return 1
    fi
    printf '%s' "${rec#*$'\t'}"
}

# What: Inspect an index raw; 1 not-found, 2 unknown.
# Why: One reader; transient must not read as absent.
# From: Issue #1683
_ci_index_raw() {
    _ci_registry_read "$1" raw "[CI-WARN-RESOLVE-0010]" ok
}

# What: canonical sorted "platform=digest ..." values.
# Why: shared format for assemble/reconcile/candidate.
# From: Issue #1683
_ci_normalize_platform_digests() {
    local input="$1"
    printf '%s\n' "${input}" | tr ' ' '\n' | awk 'NF' | LC_ALL=C sort | tr '\n' ' '
}

# What: Look up an existing multi-arch index.
# Why: Idempotency: reuse an identical index.
# From: Issue #1683
_ci_index_lookup() {
    local service="$1"
    local name sha tag idx grc=0 raw plats
    name="$(_ci_image_ref "${service}")" || return 2
    sha="$(_ci_env_required GITHUB_SHA)" || return 2
    tag="${name}:sha-${sha}"
    idx="$(_ci_registry_probe "${tag}")" || grc=$?
    [ "${grc}" -eq 0 ] || return "${grc}"
    raw="$(_ci_index_raw "${tag}")" || return "$?"
    if ! plats="$(jq -r '.manifests[]? | select(.platform.os!="unknown" and .platform.architecture!="unknown") | "\(.platform.os)/\(.platform.architecture)=\(.digest)"' <<< "${raw}" 2>&1)"; then
        ci_error "[CI-ERROR-ASSEMBLE-0010]" "service=\"${service}\" tag=\"${tag}\" reason=\"existing index unparseable; UNKNOWN\"" "${plats}"$'\n'"index: ${raw}"
        return 2
    fi
    plats="$(tr '\n' ' ' <<< "${plats}")"
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
    local service="$1" want="$2" existing ex_digest ex_have lrc=0
    existing="$(_ci_index_lookup "${service}")" || lrc=$?
    case "${lrc}" in
        0) ;;
        1) return 0 ;;
        *)
            ci_log "[CI-ERROR-ASSEMBLE-0007]" "service=\"${service}\" rc=${lrc} reason=\"existing index state UNKNOWN (raw above); not assembling over it\""
            return 2
            ;;
    esac
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
    local name sha target kv
    name="$(_ci_image_ref "${service}")" || return 2
    sha="$(_ci_env_required GITHUB_SHA)" || return 2
    target="${name}:sha-${sha}"
    local -a srcs=()
    for kv; do
        srcs+=("${name}@${kv#*=}")
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
    count="$(printf '%s\n' ${inputs} | awk '/=/ {n++} END {print n+0}')"
    if ! reused="$(_ci_reconcile_index "${service}" "${want}")"; then
        return 2
    fi
    if [ -n "${reused}" ]; then
        printf 'service=%s result=reuse-index assembled=%s platforms=%s\n' "${service}" "${reused}" "${count}"
        return 0
    fi
    _ci_require_ghcr_auth || return "$?"
    if ! index="$(_ci_docker_assemble "${service}" ${inputs})"; then
        ci_log "[CI-ERROR-ASSEMBLE-0005]" "service=\"${service}\" inputs=\"${inputs}\" reason=\"assemble backend failed (raw above)\""
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
    local kp ch p root=release/channels
    if ! _ci_sot_view "${root}" kp; then
        ci_error "[CI-ERROR-CORE-0123]" "field=\"$1\" manifest=\"${CI_MANIFEST}\" reason=\"SOT release.channels unreadable\"" "${_CI_SOT_RAW_ERR}"
        return 2
    fi
    [ "${_CI_SOT["${kp}k:${root}"]:-}" = c ] || return 0
    while IFS= read -r ch; do
        [ -n "${ch}" ] || continue
        while IFS= read -r p; do
            [ -z "${p}" ] || printf '%s %s\n' "${ch}" "${_CI_SOT["${kp}r:${p}"]}"
        done <<< "${_CI_SOT["${kp}a:${root}/${ch}/$1"]:-}"
    done <<< "${_CI_SOT["${kp}b:${root}"]:-}"
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
    local produced produced_rc=0
    produced="$(_ci_mutable_channels)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r c; do
        [ "${c}" = "${channel}" ] && return 0
    done <<<"${produced}"
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
    local service idx
    local produced produced_rc=0
    produced="$(ci_services)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        idx="$(_ci_candidate_index "${service}")" || return "$?"
        printf '%s=%s\n' "${service}" "${idx}"
    done <<<"${produced}"
}

# What: a target's assembled index for its accepted digests.
# Why: one owner for stack and toolchain candidate intake.
# From: Issue #1683 | PR #1858
_ci_candidate_index() {
    local service="$1" inputs want idx
    inputs="$(_ci_collect_accepted_digests "${service}")" || return "$?"
    want="$(_ci_normalize_platform_digests "${inputs}")"
    idx="$(_ci_reconcile_index "${service}" "${want}")" || return "$?"
    if [ -z "${idx}" ]; then
        ci_error "[CI-ERROR-CANDIDATE-0001]" "service=\"${service}\" reason=\"platforms accepted but no assembled multi-arch index; not candidate-ready\"" "accepted=${inputs}"
        return 2
    fi
    printf '%s\n' "${idx}"
}

# What: toolchain promote candidates if fully accepted.
# Why: promote is the one channel mover (AG-REL-009).
# From: Issue #1683 | PR #1858
_ci_toolchain_candidate() {
    local service idx p st all plats tools
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
        idx="$(_ci_candidate_index "${service}")" || return "$?"
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
    local produced produced_rc=0
    produced="$(ci_services)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        if ! digest="$(_ci_published_digest "${service}" "${platform}")"; then
            ci_log "[CI-ERROR-CANDIDATE-0002]" "service=\"${service}\" reason=\"PR image not resolvable; refusing to validate a partial stack\""
            return 2
        fi
        printf '%s=%s\n' "${service}" "${digest}"
    done <<<"${produced}"
}

# What: stack candidate lines, each service=sha256:<hex>.
# Why: one intake check for validate and promote (§48).
# From: Issue #1683 | PR #1858
_ci_stack_candidate() {
    local out line
    out="$(_ci_stack_candidate_source "$@")" || return "$?"
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        [[ "${line}" =~ ^[a-z0-9][a-z0-9._-]*=${CI_DIGEST_RE}$ ]] && continue
        ci_error "[CI-ERROR-CANDIDATE-0006]" "reason=\"candidate line is not service=sha256:<64 hex>; FAIL CLOSED\"" "${out}"
        return 2
    done <<<"${out}"
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: read the accepted stack candidate for this event.
# Why: exact-digest candidate (§48); a PR reads its own.
# From: Issue #1683
_ci_stack_candidate_source() {
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
    local prefix
    prefix="$(_ci_variable CI_PROMOTE_LOCK_REF)" || return 2
    printf '%s/%s' "${prefix}" "$1"
}

# What: Default promote lock: take the channel lock.
# Why: the cross-host CAS mutex, reused for promotion.
# From: Issue #1683
_ci_promote_lock() {
    local remote max backoff stale ref
    remote="$(_ci_git_remote)" || return 2
    max="$(_ci_variable CI_PROMOTE_LOCK_MAX)" || return 2
    backoff="$(_ci_variable CI_PROMOTE_LOCK_BACKOFF)" || return 2
    stale="$(_ci_variable CI_PROMOTE_LOCK_STALE)" || return 2
    ref="$(_ci_promote_lock_ref "$1")" || return 2
    _ci_lock_acquire "${remote}" "${ref}" "promote $1 run=${GITHUB_RUN_ID:-local}" \
        "${max}" "${backoff}" "${stale}"
}

# What: Default promote unlock: free the channel lock.
# Why: the same holder note the acquire path used.
# From: Issue #1683
_ci_promote_unlock() {
    local remote ref
    remote="$(_ci_git_remote)" || return 2
    ref="$(_ci_promote_lock_ref "$1")" || return 2
    _ci_lock_release "${remote}" "${ref}" "promote $1 run=${GITHUB_RUN_ID:-local}"
}

# What: Default channel move: point svc:channel at digest.
# Why: shares the one index writer; moves, never builds.
# From: Issue #1683
_ci_promote_move() {
    local svc="$1" channel="$2" digest="$3" name
    name="$(_ci_image_ref "${svc}")" || return 2
    _ci_imagetools_create "${name}:${channel}" "${name}@${digest}" >/dev/null
}

# What: Default channel readback: the channel's digest.
# Why: one digest reader; empty output means unknown.
# From: Issue #1683
_ci_channel_readback() {
    local svc="$1" channel="$2" name digest
    name="$(_ci_image_ref "${svc}")" || return 2
    digest="$(_ci_registry_digest "${name}:${channel}")" || return 2
    # What: a channel counts only if every child resolves.
    # Why: a present index with lost children is unpullable.
    # From: Issue #1683 | PR #1858
    _ci_index_complete "${name}" "${digest}" || return 2
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
    if ! children="$(jq -er '.manifests[]? | select(.platform.architecture!="unknown") | .digest' <<< "${raw}")"; then
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
    if ! _ci_promote_lock "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0010]" "channel=\"${channel}\" reason=\"could not acquire promotion lock\""
        return 2
    fi
    # What: capture rc so the unlock still runs on failure.
    # Why: a failed move must never leak the promotion lock.
    local rc
    if _ci_promote_move_all "${channel}" "${cand}"; then rc=0; else rc=$?; fi
    _ci_promote_unlock "${channel}" || ci_log "[CI-WARN-PROMOTE-0011]" "channel=\"${channel}\" reason=\"lock release failed\""
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
            refs/tags/*)
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
# Why: one ls-remote reader for every ref tip.
# From: Issue #1683
_ci_ref_tip() {
    local out remote
    remote="$(_ci_git_remote)" || return 2
    out="$(_ci_run "[CI-ERROR-PROMOTE-0016]" "ref=\"$1\" remote=\"${remote}\" reason=\"ref tip lookup failed\"" git ls-remote "${remote}" "$1")" || return 2
    [ -z "${out}" ] || cut -f1 <<< "${out}"
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
    # What: a release tag passes the AG-REL-011 gate first
    # Why: AG-REL-013: no release move on stale validation
    # From: Issue #1683 | PR #1858
    if [[ "${ref}" == refs/tags/* ]] && ! _ci_release_validation_valid; then
        ci_log "[CI-ERROR-RELEASE-0001]" "ref=\"${ref}\" reason=\"candidate validation not valid or unverified; not releasing\""
        return 2
    fi
    # What: moved branch tip means newer run supersedes.
    # Why: determinism (§4); never promote stale blind.
    if [[ "${ref}" == refs/heads/* ]]; then
        if ! tip="$(_ci_ref_tip "${ref}")"; then
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
        ci_cmd_promote "${t}" || return "$?"
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
    local rel gov state target layer sub commit paths rows stale="" out
    rel="$(_ci_block_entry_field release "" validation_state)" || return 2
    gov="$(_ci_block_entry_list release "" governance_paths)" || return 2
    target="$(_ci_env_required GITHUB_SHA)" || return 2
    state="${CI_REPO_ROOT}/${rel}"
    if [ -z "${rel}" ] || [ -z "${gov}" ] || ! jq -e '.subsystem_validation' "${state}" >/dev/null; then
        ci_log "[CI-ERROR-RELEASE-0014]" "state=\"${state}\" reason=\"no readable SOT validation record\""
        return 2
    fi
    gov="${gov//$'\n'/ }"
    local lcommit
    for layer in last_stack_validation last_ci_validation; do
        if ! lcommit="$(jq -r --arg l "${layer}" '.[$l].commit' "${state}" 2>&1)"; then
            ci_error "[CI-ERROR-RELEASE-0022]" "state=\"${state}\" layer=\"${layer}\" reason=\"validation layer commit unreadable\"" "${lcommit}"
            return 2
        fi
        out="$(_ci_release_record_stale "${layer}" "${lcommit}" "${target}" "" "${gov}")" || return 2
        stale+="${out:+${out}$'\n'}"
    done
    if ! rows="$(jq -r '.subsystem_validation | to_entries[] | select(.key | startswith("_") | not)
        | [.key, (.value.commit // "null"), (.value.path_prefixes | join(" "))] | @tsv' "${state}" 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0023]" "state=\"${state}\" reason=\"subsystem validation rows unreadable\"" "${rows}"
        return 2
    fi
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

# What: Markdown of the PRs merged since the last release.
# Why: notes come from PR sections, no manual step.
# From: Issue #894 | PR #1858
_ci_release_changes() {
    local tag="$1" prev repo shallow raw subjects nums
    repo="$(_ci_repo)" || return 2
    prev="$(_ci_last_release_tag "${tag}")" || return 2
    if [ -z "${prev}" ]; then
        printf '_No earlier vX.Y.Z release: no change list for %s._\n' "${tag}"
        return 0
    fi
    # What: fetch both tags with full history for the range.
    # Why: CI checkouts are depth 1; log needs both ends.
    # From: Issue #894 | PR #1858
    shallow="$(_ci_capture 0 git rev-parse --is-shallow-repository)" || return 2
    local -a deepen=()
    local remote
    [ "${shallow}" != true ] || deepen=(--unshallow)
    remote="$(_ci_git_remote)" || return 2
    raw="$(_ci_retry git-fetch git fetch -q --no-tags "${deepen[@]}" "${remote}" \
        "+refs/tags/${prev}:refs/tags/${prev}" "+refs/tags/${tag}:refs/tags/${tag}")" || return 2
    subjects="$(_ci_capture 0 git log --format=%s "${prev}..${tag}")" || return 2
    # What: "Merge pull request #N ..." and "... (#N)".
    # Why: GitHub's merge and squash default subjects.
    # From: Issue #894 | PR #1858
    nums="$(_ci_capture 0 awk '
        match($0, /^Merge pull request #[0-9]+/) { print substr($0, 21, RLENGTH - 20); next }
        match($0, /\(#[0-9]+\)$/) { print substr($0, RSTART + 2, RLENGTH - 3) }
    ' <<< "${subjects}")" || return 2
    nums="$(_ci_capture 0 sort -un <<< "${nums}")" || return 2
    if [ -z "${nums}" ]; then
        printf '_No pull requests merged since %s._\n' "${prev}"
        return 0
    fi
    local n q="" count=0 rows="" part
    while IFS= read -r n; do
        q+=" p${n}: issueOrPullRequest(number: ${n}) { __typename ... on PullRequest { number title url body labels(first: 20) { nodes { name } } } }"
        count=$((count + 1))
        if [ "${count}" -eq 50 ]; then
            part="$(_ci_release_pr_batch "${repo}" "${q}")" || return 2
            rows+="${part}"$'\n'; q=""; count=0
        fi
    done <<< "${nums}"
    if [ -n "${q}" ]; then
        part="$(_ci_release_pr_batch "${repo}" "${q}")" || return 2
        rows+="${part}"$'\n'
    fi
    _ci_release_render "${rows}"
}

# What: Run one aliased PR query; print one JSON per PR.
# Why: 50 PRs per GraphQL call; issues are dropped here.
# From: Issue #894 | PR #1858
_ci_release_pr_batch() {
    local repo="$1" q="$2" raw out
    raw="$(_ci_retry github-api gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" \
        -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {${q} } }")" || return 2
    if ! out="$(jq -c '.data.repository[] | select(. != null and .__typename == "PullRequest")' <<< "${raw}" 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0029]" "reason=\"PR batch unparseable\"" "${out}"
        return 2
    fi
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: Group PR JSON lines by SOT label into Markdown.
# Why: SOT order decides the group; skip label drops a PR.
# From: Issue #894 | PR #1858
_ci_release_render() {
    local rows="$1" labels cat title skip other section pr num url text body
    labels="$(_ci_block_keys release_notes_categories)" || return 2
    skip="$(_ci_block_entry_field release_notes "" skip_label)" || return 2
    other="$(_ci_block_entry_field release_notes "" other_title)" || return 2
    section="$(_ci_block_entry_field release_notes "" pr_section)" || return 2
    if [ -z "${labels}" ] || [ -z "${other}" ] || [ -z "${section}" ]; then
        ci_log "[CI-ERROR-RELEASE-0030]" "reason=\"SOT release_notes or release_notes_categories incomplete\""
        return 2
    fi
    local -a order=()
    local -A group=()
    while IFS= read -r pr; do
        [ -n "${pr}" ] || continue
        num="$(_ci_capture 0 jq -r '.number' <<< "${pr}")" || return 2
        title="$(_ci_capture 0 jq -r '.title' <<< "${pr}")" || return 2
        url="$(_ci_capture 0 jq -r '.url' <<< "${pr}")" || return 2
        text="$(_ci_capture 0 jq -r '[.labels.nodes[].name] | join("\n")' <<< "${pr}")" || return 2
        [ -z "${skip}" ] || ! grep -qxF -- "${skip}" <<< "${text}" || continue
        cat="${other}"
        while IFS= read -r body; do
            if grep -qxF -- "${body}" <<< "${text}"; then
                cat="$(_ci_block_entry_field release_notes_categories "${body}" title)" || return 2
                break
            fi
        done <<< "${labels}"
        body="$(_ci_capture 0 jq -r '.body // ""' <<< "${pr}")" || return 2
        body="$(_ci_pr_section "${body}" "${section}")" || return 2
        if [ "${body}" = "${body%%$'\n'*}" ]; then body=""; else body="${body#*$'\n'}"; fi
        body="$(_ci_md_strip_comments "${body}")" || return 2
        body="$(_ci_capture 0 awk 'NF { seen = 1 } seen { buf = buf $0 "\n"; if (NF) { out = out buf; buf = "" } } END { printf "%s", out }' <<< "${body}")" || return 2
        [ -n "${group[${cat}]+x}" ] || order+=("${cat}")
        group["${cat}"]+="- #${num} ${title} (${url})"$'\n'
        [ -z "${body}" ] || group["${cat}"]+="$(sed 's/^/  /' <<< "${body}")"$'\n'
    done <<< "${rows}"
    if [ "${#order[@]}" -eq 0 ]; then
        printf '_No pull requests with release notes._\n'
        return 0
    fi
    local done_titles=$'\n' t
    while IFS= read -r body; do
        t="$(_ci_block_entry_field release_notes_categories "${body}" title)" || return 2
        [[ "${done_titles}" != *$'\n'"${t}"$'\n'* ]] || continue
        done_titles+="${t}"$'\n'
        [ -z "${group[${t}]+x}" ] || printf '### %s\n\n%s\n' "${t}" "${group[${t}]}"
    done <<< "${labels}"
    [ -z "${group[${other}]+x}" ] || printf '### %s\n\n%s\n' "${other}" "${group[${other}]}"
}

# What: Print the release notes change list for a tag.
# Why: maintainer fallback; same generator as the release.
# From: Issue #894 | PR #1858
ci_cmd_release_notes() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0031]" "reason=\"tag arg required\""; return 2; }
    _ci_release_changes "${tag}"
}

# What: Add a stable tag's change list to CHANGELOG.md.
# Why: release writes CHANGELOG; no PR edits it by hand.
# From: Issue #894 | PR #1858
ci_cmd_release_changelog() {
    local tag="${1:-}" branch="${CI_DEFAULT_BRANCH:-}" changes file head out remote
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0032]" "reason=\"tag arg required\""; return 2; }
    file="$(_ci_variable CI_CHANGELOG)" || return 2
    local kind=""
    if kind="$(_ci_release_tag_kind "${tag}")"; then :; fi
    if [ "${kind}" != false ]; then
        printf 'release-changelog=skip tag=%s reason="not a stable vX.Y.Z tag"\n' "${tag}"
        return 0
    fi
    head="## [${tag#"${tag%%[0-9]*}"}]"
    if [ -z "${branch}" ]; then
        ci_log "[CI-ERROR-RELEASE-0033]" "reason=\"CI_DEFAULT_BRANCH is required\""
        return 2
    fi
    changes="$(_ci_release_changes "${tag}")" || return 2
    remote="$(_ci_git_remote)" || return 2
    out="$(_ci_retry git-fetch git fetch -q --no-tags "${remote}" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}")" || return 2
    out="$(_ci_capture 0 git checkout -q -B ci-release-changelog "${remote}/${branch}")" || return 2
    out="$(_ci_capture 1 grep -nF -- "${head} " "${file}")" || return 2
    if [ -n "${out}" ]; then
        printf 'release-changelog=exists tag=%s line=%s\n' "${tag}" "${out%%:*}"
        return 0
    fi
    # What: new entry goes above the first "## [" release.
    # Why: the pending section stays on top.
    # From: Issue #894 | PR #1858
    if ! out="$(CI_CHANGES="${changes}" awk -v h="${head} - $(date -u +%Y-%m-%d)" '
        !done && /^## \[/ { print h "\n\n" ENVIRON["CI_CHANGES"] "\n"; done = 1 }
        { print }
        END { if (!done) print "\n" h "\n\n" ENVIRON["CI_CHANGES"] }
    ' "${file}" 2>&1 > "${file}.new")" || ! out="$(mv "${file}.new" "${file}" 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0034]" "file=\"${file}\" reason=\"changelog not rewritten\"" "${out}"
        rm -f "${file}.new"
        return 2
    fi
    out="$(_ci_capture 0 _ci_git_as_bot commit -q -m "docs: update ${file} for ${tag}" -- "${file}")" || return 2
    out="$(_ci_retry git-push git push -q "${remote}" "HEAD:refs/heads/${branch}")" || return 2
    printf 'release-changelog=written tag=%s branch=%s\n' "${tag}" "${branch}"
}

# What: Render the marker-delimited image provenance block.
# Why: Records every shipped digest; SOT list, no hardcode.
# From: Issue #1683
_ci_release_notes_block() {
    local tag="$1" base target img dig
    base="$(_ci_image_ref)" || return 2
    _ci_release_marker start || return 2
    printf '## Changes\n\n'
    _ci_release_changes "${tag}" || return 2
    printf '\n## Images\n\n'
    printf 'Images published for %s (commit %s):\n\n' "${tag}" "${GITHUB_SHA:-unknown}"
    local targets
    targets="$(ci_build_targets)" || return 2
    for target in ${targets} stack; do
        img="${base}/${target}:${tag}"
        dig="$(_ci_registry_digest "${img}")" || return "$?"
        printf -- '- %s -> %s\n' "${img}" "${dig}"
    done
    printf '\nProvenance attestations and CycloneDX SBOMs attach per image.\n'
    printf 'OpenVEX from .trivyignore.yaml attaches as vex.openvex.json.\n'
    _ci_release_marker end || return 2
}

# What: fetch one release asset: 0 got, 1 absent, 2 unknown
# Why: a repeat reuses or compares, it never re-uploads
# From: Issue #1683 | PR #1858
_ci_release_asset_get() {
    local tag="$1" name="$2" dir="$3" repo out rc=0
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    out="$(_ci_retry github-read gh release download "${tag}" --repo "${repo}" --pattern "${name}" --dir "${dir}")" || rc=$?
    [ "${rc}" -ne 1 ] || return 1
    if [ "${rc}" -ne 0 ] || [ ! -s "${dir}/${name}" ]; then
        ci_error "[CI-ERROR-RELEASE-0044]" "tag=\"${tag}\" asset=\"${name}\" rc=${rc} reason=\"release asset read failed\"" "${out}"
        return 2
    fi
}

# What: upload an absent asset once, then read it back
# Why: AG-REL-014 never replace; AG-WF-031 read back
# From: Issue #1683 | PR #1858
_ci_release_asset_put() {
    local tag="$1" file="$2" repo dir rc=0
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    [ -s "${file}" ] || { ci_log "[CI-ERROR-RELEASE-0004]" "file=\"${file}\" reason=\"asset file missing or empty\""; return 2; }
    _ci_retry github-api gh release upload "${tag}" "${file}" --repo "${repo}" > /dev/null || return 2
    dir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-asset.XXXXXX")" || return 2
    _ci_release_asset_get "${tag}" "${file##*/}" "${dir}" || rc=$?
    if [ "${rc}" -ne 0 ] || ! cmp -s "${file}" "${dir}/${file##*/}"; then
        ci_error "[CI-ERROR-RELEASE-0045]" "tag=\"${tag}\" asset=\"${file##*/}\" rc=${rc} reason=\"uploaded asset not read back equal\"" "$(ls -la "${dir}" 2>&1)"
        rm -rf "${dir}"
        return 2
    fi
    rm -rf "${dir}"
}

# What: one release read: prerelease line, then the body
# Why: the repeat check and the create read back agree
# From: Issue #1683 | PR #1858
_ci_release_state() {
    local repo="$1" tag="$2" out err rc=0
    err="$(_ci_mktemp "${CI_TMPDIR}/ci-release-view.XXXXXX")" || return 2
    out="$(gh release view "${tag}" --repo "${repo}" --json body,isPrerelease 2>"${err}")" || rc=$?
    # What: only gh's "release not found" means absent.
    # Why: auth/network errors are UNKNOWN, not "absent".
    # From: Issue #1683 | PR #1858
    if [ "${rc}" -ne 0 ]; then
        if [[ "$(<"${err}")" == *"release not found"* ]]; then rm -f "${err}"; return 1; fi
        ci_error "[CI-ERROR-RELEASE-0020]" "tag=\"${tag}\" reason=\"gh release view failed\"" "$(<"${err}")"
        rm -f "${err}"
        return 2
    fi
    rm -f "${err}"
    _ci_capture 0 jq -r '(.isPrerelease | tostring), (.body // "")' <<< "${out}"
}

# What: create a GitHub release once; a repeat only compares
# Why: AG-REL-014: CI never edits a published release
# From: Issue #1683 | PR #1858
ci_cmd_release_publish() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0003]" "reason=\"tag arg required\""; return 2; }
    local repo sha pre want state found body_file err mode=unchanged rc=0
    local -a create=()
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    sha="$(_ci_env_required GITHUB_SHA)" || return 2
    pre="$(_ci_release_prerelease "${tag}")" || return "$?"
    _ci_require_ghcr_auth || return "$?"
    want="$(_ci_release_notes_block "${tag}")" || return "$?"
    state="$(_ci_release_state "${repo}" "${tag}")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    if [ "${rc}" -eq 1 ]; then
        mode=published
        body_file="$(_ci_mktemp "${CI_TMPDIR}/ci-release-notes.XXXXXX")" || return 2
        if ! err="$(printf '%s\n' "${want}" 2>&1 > "${body_file}")"; then
            ci_error "[CI-ERROR-RELEASE-0036]" "tag=\"${tag}\" file=\"${body_file}\" reason=\"notes file not written\"" "${err}"
            rm -f "${body_file}"
            return 2
        fi
        create=(gh release create "${tag}" --repo "${repo}" --title "${tag}" --notes-file "${body_file}" --target "${sha}")
        [ "${pre}" != true ] || create+=(--prerelease)
        rc=0; _ci_retry github-api "${create[@]}" > /dev/null || rc=$?
        rm -f "${body_file}"
        if [ "${rc}" -ne 0 ]; then
            ci_log "[CI-ERROR-RELEASE-0006]" "tag=\"${tag}\" reason=\"gh release create failed (raw above)\""
            return 2
        fi
        # What: read the new release back before it counts.
        # Why: AG-WF-031: every GitHub write is read back
        # From: Issue #1683 | PR #1858
        if ! state="$(_ci_release_state "${repo}" "${tag}")"; then
            ci_log "[CI-ERROR-RELEASE-0037]" "tag=\"${tag}\" reason=\"created release not readable\""
            return 2
        fi
    fi
    found="${state#*$'\n'}"
    [ "${found}" != "${state}" ] || found=""
    if [ "${state%%$'\n'*}" != "${pre}" ]; then
        ci_log "[CI-ERROR-RELEASE-0005]" "tag=\"${tag}\" mode=${mode} reason=\"release prerelease state != tag policy\" expected=\"${pre}\" found=\"${state%%$'\n'*}\""
        return 2
    fi
    if [ "${found//$'\r'/}" != "${want//$'\r'/}" ]; then
        ci_error "[CI-ERROR-RELEASE-0038]" "tag=\"${tag}\" mode=${mode} reason=\"release notes differ from the expected state; CI never edits a release\"" "expected:"$'\n'"${want}"$'\n'"found:"$'\n'"${found}"
        return 2
    fi
    printf 'release=%s tag=%s prerelease=%s\n' "${mode}" "${tag}" "${pre}"
}

# What: Generate and attach a CycloneDX SBOM for one image.
# Why: Per-image provenance asset; reuses the trivy scanner.
# From: Issue #1683
ci_cmd_release_sbom() {
    local service="${1:-}" tag="${2:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RELEASE-0007]" "reason=\"service arg required\""; return 2; }
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0008]" "reason=\"tag arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local name digest dir out rc=0
    name="$(_ci_image_ref "${service}")" || return 2
    digest="$(_ci_registry_digest "${name}:${tag}")" || return "$?"
    dir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-sbom.XXXXXX")" || return 2
    out="${dir}/${service}.cdx.json"
    # What: an attached SBOM for this digest is reused
    # Why: architecture §57: one SBOM per digest, no rescan
    # From: Issue #1683 | PR #1858
    _ci_release_asset_get "${tag}" "${out##*/}" "${dir}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        if grep -qF -- "${digest}" "${out}"; then
            rm -rf "${dir}"
            printf 'release=sbom-reused service=%s tag=%s digest=%s\n' "${service}" "${tag}" "${digest}"
            return 0
        fi
        ci_error "[CI-ERROR-RELEASE-0046]" "service=\"${service}\" tag=\"${tag}\" digest=\"${digest}\" reason=\"attached SBOM is not bound to this digest\"" "digests the attached SBOM names: $(grep -o -E "${CI_DIGEST_RE}" "${out}" 2>&1 | LC_ALL=C sort -u | awk '{ printf "%s ", $0; n++ } END { if (!n) printf "none" }')"
        rm -rf "${dir}"
        return 2
    fi
    [ "${rc}" -eq 1 ] || { rm -rf "${dir}"; return 2; }
    rc=0
    _ci_trivy_sbom "${service}" "${digest}" "${out}" || rc=$?
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
    local tag="${1:-}" svc targets
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0013]" "reason=\"tag arg required\""; return 2; }
    targets="$(ci_build_targets)" || return 2
    for svc in ${targets}; do
        ci_cmd_release_sbom "${svc}" "${tag}" || return "$?"
    done
}

# What: generate and attach OpenVEX to release.
# Why: one VEX per release; reuses SOT vex generator.
# From: Issue #1683
ci_cmd_release_vex() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0010]" "reason=\"tag arg required\""; return 2; }
    local root="${CI_REPO_ROOT:-.}" trivyignore dir adir out rc=0
    trivyignore="$(_ci_repo_path CI_TRIVY_IGNORE "${root}")" || return 2
    [ -s "${trivyignore}" ] || { ci_log "[CI-ERROR-RELEASE-0011]" "path=\"${trivyignore}\" reason=\"trivyignore missing; cannot build release VEX\""; return 2; }
    dir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-vex.XXXXXX")" || return 2
    out="${dir}/vex.openvex.json"
    _ci_generate_vex "${trivyignore}" > "${out}" || rc=$?
    if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
        rm -rf "${dir}"
        ci_log "[CI-ERROR-RELEASE-0012]" "tag=\"${tag}\" rc=${rc} reason=\"OpenVEX generation failed or empty (raw above)\""
        return 2
    fi
    # What: an attached VEX must equal the one derived now
    # Why: AG-REL-014: a published release is never changed
    # From: Issue #1683 | PR #1858
    adir="$(_ci_mktemp -d "${dir}/attached.XXXXXX")" || { rm -rf "${dir}"; return 2; }
    rc=0; _ci_release_asset_get "${tag}" "${out##*/}" "${adir}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        if cmp -s "${out}" "${adir}/${out##*/}"; then
            rm -rf "${dir}"
            printf 'release=vex-unchanged tag=%s\n' "${tag}"
            return 0
        fi
        ci_error "[CI-ERROR-RELEASE-0047]" "tag=\"${tag}\" reason=\"attached VEX differs from the derived one; CI never replaces it\"" "$(diff -u "${adir}/${out##*/}" "${out}" 2>&1)"
        rm -rf "${dir}"
        return 2
    fi
    [ "${rc}" -eq 1 ] || { rm -rf "${dir}"; return 2; }
    _ci_release_asset_put "${tag}" "${out}" || { rm -rf "${dir}"; return 2; }
    rm -rf "${dir}"
    printf 'release=vex tag=%s\n' "${tag}"
}

# What: highest plain vX.Y.Z tag (below $1 if given).
# Why: ls-remote skips deep fetch; empty pre-1.0.
# From: Issue #1683
_ci_last_release_tag() {
    local below="${1:-}" refs tags="" t remote
    remote="$(_ci_git_remote)" || return 2
    refs="$(_ci_capture 0 git ls-remote --tags --refs "${remote}")" || return 2
    # What: keep plain release tags via the one tag grammar.
    # Why: no second tag pattern beside the kind owner.
    # From: Issue #1683 | PR #1858
    while IFS= read -r t; do
        t="${t##*refs/tags/}"
        if [ "$(_ci_release_tag_kind "${t}")" = false ]; then tags="${tags}${t}"$'\n'; fi
    done <<<"${refs}"
    tags="${tags%$'\n'}"
    if [ -z "${tags}" ]; then
        return 0
    fi
    if [ -z "${below}" ]; then
        sort -V <<<"${tags}" | tail -n 1
        return 0
    fi
    # What: an rc tag counts as its base vX.Y.Z here.
    # Why: notes of vX.Y.Z-rc.N start at the release before.
    # From: Issue #1683 | PR #1858
    below="${below%%-*}"
    tags="$(printf '%s\n%s\n' "${tags}" "${below}" | sort -V -u)"
    awk -v b="${below}" '$0 == b { exit } { last = $0 } END { if (last != "") print last }' <<<"${tags}"
}

# What: The next patch tag after a plain vX.Y.Z tag.
# Why: a patch tag bumps Z only, never rc, minor or major
# From: Issue #1683
_ci_next_patch_tag() {
    local tag="$1" kind=""
    if kind="$(_ci_release_tag_kind "${tag}")"; then :; fi
    if [ "${kind}" != false ]; then
        ci_log "[CI-ERROR-RELEASE-0015]" "tag=\"${tag}\" reason=\"not a plain vX.Y.Z tag; no patch bump\""
        return 2
    fi
    printf '%s.%s\n' "${tag%.*}" "$(( 10#${tag##*.} + 1 ))"
}

# What: push the PAT-authored tag, then read it back
# Why: a GITHUB_TOKEN tag push starts no release run
# From: Issue #1683 | PR #1858
_ci_push_release_tag() {
    local tag="$1" sha="$2" pat srv repo url hdr raw got
    pat="$(_ci_env_required PROJECT_AUTOMATION_PAT)" || return 2
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    url="${srv}/${repo}.git"
    hdr="http.${url}.extraheader=AUTHORIZATION: basic $(printf '%s' "x-access-token:${pat}" | base64 -w0)"
    _ci_run "[CI-ERROR-RELEASE-0026]" "tag=\"${tag}\" sha=\"${sha}\" reason=\"annotated tag not created\"" \
        _ci_git_as_bot tag -a "${tag}" "${sha}" -m "Patch release ${tag}" >/dev/null || return 2
    _ci_run "[CI-ERROR-RELEASE-0027]" "tag=\"${tag}\" url=\"${url}\" reason=\"release tag push failed\"" \
        git -c "${hdr}" push "${url}" "refs/tags/${tag}" >/dev/null || return 2
    # What: the remote tag must peel to the cut commit
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    raw="$(_ci_capture 0 git -c "${hdr}" ls-remote --tags "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return 2
    got="$(awk -v r="refs/tags/${tag}" '$2 == r "^{}" { p = $1 } $2 == r { d = $1 } END { print (p != "" ? p : d) }' <<< "${raw}")"
    if [ "${got}" != "${sha}" ]; then
        ci_error "[CI-ERROR-RELEASE-0048]" "tag=\"${tag}\" sha=\"${sha}\" found=\"${got}\" reason=\"pushed tag not read back at the cut commit\"" "${raw}"
        return 2
    fi
    ci_log "[CI-INFO-RELEASE-0028]" "tag=\"${tag}\" sha=\"${sha}\" reason=\"release tag pushed\""
}

# What: cut the next patch tag on an explicit dispatch
# Why: AG-REL-013: a tag cut needs its own authorization
# From: Issue #1683 | PR #1858
ci_cmd_cut_release_tag() {
    local base_tag next_tag tip rel_ref head
    rel_ref="$(_ci_release_ref)" || return 2
    if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]; then
        ci_log "[CI-ERROR-RELEASE-0039]" "event=\"${GITHUB_EVENT_NAME:-}\" reason=\"a release tag is cut only by an explicit workflow_dispatch\""
        return 2
    fi
    if [ "${GITHUB_REF:-}" != "${rel_ref}" ]; then
        ci_log "[CI-ERROR-RELEASE-0040]" "ref=\"${GITHUB_REF:-}\" release_ref=\"${rel_ref}\" reason=\"not the release ref; not cutting\""
        return 2
    fi
    head="$(_ci_env_required GITHUB_SHA)" || return 2
    base_tag="$(_ci_last_release_tag)" || return 2
    if [ -z "${base_tag}" ]; then
        ci_log "[CI-ERROR-RELEASE-0041]" "reason=\"no previous release to bump; the first release tag is cut by hand\""
        return 2
    fi
    next_tag="$(_ci_next_patch_tag "${base_tag}")" || return "$?"
    if ! tip="$(_ci_ref_tip "${rel_ref}")"; then
        ci_log "[CI-ERROR-RELEASE-0016]" "ref=\"${rel_ref}\" reason=\"could not resolve release ref tip; not cutting blind\""
        return 2
    fi
    if [ "${tip}" != "${head}" ]; then
        ci_log "[CI-ERROR-RELEASE-0042]" "ref=\"${rel_ref}\" tip=\"${tip}\" sha=\"${head}\" reason=\"release ref moved during the run; dispatch again\""
        return 2
    fi
    _ci_push_release_tag "${next_tag}" "${head}" || return "$?"
    printf 'cut-tag=pushed tag=%s base=%s\n' "${next_tag}" "${base_tag}"
}

# =========================================================
# GC
# =========================================================

# What: Read the SOT artifact deletion policy value.
# Why: Default is dry-run unless policy allows automation.
# From: Issue #1683
_ci_deletion_policy() {
    _ci_block_entry_field release retention deletion_policy
}

# What: Emit the transitive protected-root digest set.
# Why: Ledger + channels + their index children (§101).
# From: Issue #1683
_ci_gc_roots() {
    local remote base blob rc=0 pairs="" out="" svc channel dig prc line s d raw ledger_ref
    remote="$(_ci_git_remote)" || return 2
    ledger_ref="$(_ci_variable CI_LEDGER_REF)" || return 2
    base="$(_ci_image_ref)" || return 2
    blob="$(_ci_ledger_blob "${remote}")" || rc=$?
    # What: A failed ledger read refuses, never empties.
    # Why: UNKNOWN roots would delete live artifacts.
    # From: Issue #1683
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-GC-0012]" "remote=\"${remote}\" ref=\"${ledger_ref}\" reason=\"ledger read UNKNOWN (raw above); refusing empty roots\""
        return 2
    fi
    # What: Every ledger record is a root, all states.
    # Why: PRODUCED_UNVERIFIED is pending, not garbage.
    # From: Issue #1683
    [ "${rc}" -eq 0 ] && pairs="$(printf '%s\n' "${blob}" | awk -F'\t' 'NF>=5 && $2!="" && $5!="" {print $2"\t"$5}')"
    local targets targets_rc=0
    targets="$(ci_build_targets)" || targets_rc=$?
    _ci_producer_ok "${targets_rc}" 0 || return 2
    # What: every build target's channels are roots.
    # Why: GC candidates include build-tools; skip = orphan.
    # From: Issue #1683 | PR #1858
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        local produced produced_rc=0
        produced="$(_ci_mutable_channels)" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 0 || return 2
        while IFS= read -r channel; do
            [ -n "${channel}" ] || continue
            prc=0
            dig="$(_ci_registry_probe "${base}/${svc}:${channel}")" || prc=$?
            # What: A transient probe refuses the run.
            # Why: A flaky miss must not drop a channel.
            # From: Issue #1683
            [ "${prc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0013]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel probe UNKNOWN; refusing roots\""; return 2; }
            [ "${prc}" -eq 0 ] && pairs="${pairs}"$'\n'"${svc}"$'\t'"${dig}"
        done <<<"${produced}"
    done <<<"${targets}"
    pairs="$(printf '%s\n' "${pairs}" | awk 'NF>0' | LC_ALL=C sort -u)"
    while IFS=$'\t' read -r s d; do
        [ -n "${d}" ] || continue
        out="${out}${d}"$'\n'
        rc=0
        raw="$(_ci_index_raw "${base}/${s}@${d}")" || rc=$?
        # What: A transient child read refuses the run.
        # Why: Dropping children orphan-deletes arches.
        # From: Issue #1683
        [ "${rc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0014]" "service=\"${s}\" digest=\"${d}\" reason=\"index child read UNKNOWN; refusing roots\""; return 2; }
        if [ "${rc}" -eq 0 ]; then
            # What: children parsed+checked first.
            # Why: lost children get deleted as dead.
            # From: Issue #1683 | PR #1858
            local kids
            if ! kids="$(jq -r '.manifests[]? | select(.platform.architecture!="unknown") | .digest' <<< "${raw}" 2>&1)"; then
                ci_error "[CI-ERROR-GC-0026]" "service=\"${s}\" digest=\"${d}\" reason=\"index children unparseable; refusing roots\"" "${kids}"$'\n'"index: ${raw}"
                return 2
            fi
            out="${out}${kids}"$'\n'
        fi
    done <<< "${pairs}"
    printf '%s\n' "${out}" | awk 'NF>0' | LC_ALL=C sort -u
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
_ci_gc_candidates() {
    local prefix owner pkgbase svc vers grc found=0
    prefix="$(_ci_repo)" || { ci_log "[CI-ERROR-GC-0017]" "reason=\"GITHUB_REPOSITORY missing; no package namespace\""; return 2; }
    owner="${prefix%%/*}"
    pkgbase="${prefix#*/}"
    local produced produced_rc=0
    produced="$(ci_build_targets)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
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
    done <<<"${produced}"
    # What: No package found anywhere is a config error.
    # Why: All-404 must refuse, not read as a clean noop.
    # From: Issue #1683
    [ "${found}" -gt 0 ] || { ci_log "[CI-ERROR-GC-0020]" "reason=\"no GHCR package for any target; check image_prefix/owner/token\""; return 2; }
}

# What: Delete one GHCR version by id (destructive).
# Why: The one delete surface; package-scoped by service.
# From: Issue #1683
_ci_gc_delete() {
    local candidate="$1" id svc prefix owner pkgbase path out rc
    id="$(printf '%s' "${candidate}" | awk -F'\t' '{print $2}')"
    svc="$(printf '%s' "${candidate}" | awk -F'\t' '{print $5}')"
    case "${id}" in
        ''|*[!0-9]*)
            ci_log "[CI-ERROR-GC-0019]" "candidate=\"${candidate}\" reason=\"no numeric version id\""
            return 2
            ;;
    esac
    [ -n "${svc}" ] || { ci_log "[CI-ERROR-GC-0021]" "candidate=\"${candidate}\" reason=\"no service for delete path\""; return 2; }
    prefix="$(_ci_repo)" || { ci_log "[CI-ERROR-GC-0024]" "candidate=\"${candidate}\" reason=\"GITHUB_REPOSITORY missing; no package namespace for the delete\""; return 2; }
    owner="${prefix%%/*}"
    pkgbase="${prefix#*/}"
    # What: retry a transient GH-API delete.
    # Why: destructive ops use shared classifier.
    # From: Issue #1683
    path="/orgs/${owner}/packages/container/${pkgbase}%2F${svc}/versions/${id}"
    _ci_retry github-api gh api -X DELETE "${path}" >/dev/null || return 2
    # What: deleted = 404 or a set deleted_at on read back.
    # Why: AG-WF-031; GitHub keeps soft-deleted versions.
    # From: Issue #1683 | PR #1858
    rc=0; out="$(_ci_retry github-read gh api --jq '.deleted_at // ""' "${path}")" || rc=$?
    if [ "${rc}" -eq 1 ] || { [ "${rc}" -eq 0 ] && [ -n "${out}" ]; }; then return 0; fi
    if [ "${rc}" -eq 0 ]; then
        ci_error "[CI-ERROR-GC-0032]" "candidate=\"${candidate}\" reason=\"version still active after the delete\"" "${out}"
    else
        ci_error "[CI-ERROR-GC-0033]" "candidate=\"${candidate}\" reason=\"delete not confirmed; read back failed\"" "${out}"
    fi
    return 2
}

# What: Classify a candidate against the root digest set.
# Why: Membership or recency floor decides; else garbage.
# From: Issue #1683
_ci_gc_reachable() {
    local candidate="$1" digest created window created_epoch now floor
    digest="$(printf '%s' "${candidate}" | awk -F'\t' '{print $1}')"
    created="$(printf '%s' "${candidate}" | awk -F'\t' '{print $3}')"
    # What: Roots must be materialized by the caller.
    # Why: No roots file means we cannot judge; refuse.
    # From: Issue #1683
    if [ -z "${CI_GC_ROOTS_FILE:-}" ] || [ ! -f "${CI_GC_ROOTS_FILE}" ]; then
        ci_log "[CI-ERROR-GC-0027]" "candidate=\"${digest}\" roots_file=\"${CI_GC_ROOTS_FILE:-unset}\" reason=\"no materialized roots file; cannot judge\""
        return 2
    fi
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
    window="$(_ci_block_entry_field release retention unaggregated_grace_minutes)" || return 2
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
            ci_error "[CI-ERROR-GC-0025]" "created=\"${created}\" digest=\"${digest}\" reason=\"date gave no epoch seconds\"" "${created_epoch}"
            return 2
            ;;
    esac
    now="$(date +%s)"
    floor=$(( now - window * 60 ))
    [ "${created_epoch}" -ge "${floor}" ] && { printf 'referenced\n'; return 0; }
    printf 'unreachable\n'
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
    if ! roots="$(_ci_gc_roots)"; then
        ci_log "[CI-ERROR-GC-0028]" "mode=${mode} source=\"_ci_gc_roots\" reason=\"protected roots not derivable (raw above); no gc\""
        return 2
    fi
    if [ -z "${roots}" ]; then
        ci_log "[CI-ERROR-GC-0007]" "reason=\"empty protected-roots set; refusing to treat all as unreachable\""
        return 2
    fi
    # What: Materialize roots once for the default probe.
    # Why: One read; avoids re-deriving roots per candidate.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="$(_ci_mktemp "${CI_TMPDIR}/ci-gc-roots.XXXXXX")" || return 2
    export CI_GC_ROOTS_FILE
    local werr
    if ! werr="$(awk 'NF>0' <<< "${roots}" 2>&1 > "${CI_GC_ROOTS_FILE}")"; then
        ci_error "[CI-ERROR-GC-0029]" "file=\"${CI_GC_ROOTS_FILE}\" reason=\"roots file not written; no gc\"" "${werr}"
        rm -f "${CI_GC_ROOTS_FILE}"
        return 2
    fi
    ci_log "[CI-INFO-GC-0030]" "mode=${mode} roots=$(grep -c . "${CI_GC_ROOTS_FILE}") reason=\"protected roots materialized\""
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
    if ! cands="$(_ci_gc_candidates)"; then
        ci_log "[CI-ERROR-GC-0031]" "mode=${mode} source=\"_ci_gc_candidates\" reason=\"candidate list not derivable (raw above); no gc\""
        return 2
    fi
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
            if ! _ci_gc_delete "${line}"; then
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

# What: SOT proxy probe url only when it is http
# Why: https passthrough gives no HIT proof
# From: Issue #1683 | PR #1858
_ci_validation_proxy_probe_url() {
    local url
    url="$(_ci_block_entry_field validation "" proxy_cache_probe_url)" || return 2
    if [[ "${url}" != http://?* ]]; then
        ci_error "[CI-ERROR-VALIDATE-0115]" "url=\"${url}\" reason=\"proxy probe url is not http\"" "${url}"
        return 2
    fi
    printf '%s\n' "${url}"
}

# What: Emit "service<TAB>image" for each compose service.
# Why: pin and drift checks read one compose render.
# From: Issue #1683 | PR #1858
_ci_validate_compose_images() {
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
    local candidate="$1" prefix images svc image slug digest ref matched=" "
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
                digest="$(awk -F= -v s="${slug}" '$1==s{print $2; exit}' <<< "${candidate}")"
                if [ -z "${digest}" ]; then
                    ci_log "[CI-ERROR-VALIDATE-0007]" "service=\"${svc}\" slug=\"${slug}\" reason=\"first-party compose image without candidate digest; refusing mutable tag\""
                    return 2
                fi
                ref="$(_ci_image_ref "${slug}" "${digest}")" || return 2
                printf '  %s:\n    image: %s\n' "${svc}" "${ref}"
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
    local seed="$1" pool slot plen base h
    pool="$(_ci_variable CI_VALIDATE_SUBNET_POOL)" || return 2
    slot="$(_ci_variable CI_VALIDATE_SLOT_PREFIX)" || return 2
    plen="${pool#*/}"
    if ! [[ "${pool}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ && "${slot}" =~ ^[0-9]{1,2}$ ]] \
        || [ "${slot}" -le "${plen}" ] || [ "${slot}" -gt 32 ]; then
        ci_log "[CI-ERROR-VALIDATE-0114]" "pool=\"${pool}\" slot=\"${slot}\" reason=\"SOT validation pool or slot prefix invalid\""
        return 2
    fi
    base="$(_ci_ipv4_to_int "${pool%/*}")"
    base=$(( base >> (32 - plen) << (32 - plen) ))
    h="$(printf '%s' "${seed}" | sha256sum)"
    printf '%s/%s' "$(_ci_int_to_ipv4 $(( base + (16#${h:0:8} % (1 << (slot - plen))) * (1 << (32 - slot)) )))" "${slot}"
}

# What: Host-lock one /27; print the holder pid.
# Why: Per-slot flock; runs never share a /27.
# From: Issue #1683
_ci_validate_slot_lock() {
    local subnet="$1" root key holder out errf
    root="${CI_TMPDIR}/ci-validate-locks"
    key="$(printf '%s' "${subnet}" | tr './' '__')"
    if ! out="$(mkdir -p "${root}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0072]" "dir=\"${root}\" reason=\"slot lock dir not created\"" "${out}"
        return 2
    fi
    errf="${root}/${key}.err"
    # What: holder stderr goes to a file, not /dev/null.
    # Why: a missing flock must not read as "slot held".
    # From: Issue #1683 | PR #1858
    (
        exec >/dev/null 2>"${errf}"
        exec 9>"${root}/${key}.lock"
        flock -n 9 || exit 1
        exec sleep infinity
    ) &
    holder=$!
    sleep 0.3
    if kill -0 "${holder}" 2>/dev/null; then
        rm -f "${errf}"
        printf '%s\n' "${holder}"
        return 0
    fi
    # What: reap the dead lock holder; its status is unused.
    # Why: this path returns 1; its rc adds nothing.
    # From: Issue #1683 | PR #1858
    wait "${holder}" 2>/dev/null || true
    if [ -s "${errf}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0073]" "subnet=\"${subnet}\" lock=\"${root}/${key}.lock\" reason=\"slot lock holder failed\"" "$(cat "${errf}")"
        rm -f "${errf}"
        return 2
    fi
    rm -f "${errf}"
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

# What: Convert an integer back to a dotted quad.
# Why: the slot's sub-subnets are computed as integers.
# From: Issue #1683 | PR #1858
_ci_int_to_ipv4() {
    printf '%s.%s.%s.%s' "$(( ($1 >> 24) & 255 ))" "$(( ($1 >> 16) & 255 ))" "$(( ($1 >> 8) & 255 ))" "$(( $1 & 255 ))"
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
    nets="$(_ci_run "[CI-ERROR-VALIDATE-0074]" "target=\"${target}\" reason=\"docker network list failed; overlap unknown\"" docker network ls -q)" || return 2
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
    local run_id run_attempt max n seed subnet holder crc lrc overlap
    run_id="${GITHUB_RUN_ID:-$$}"
    run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
    max="$(_ci_variable CI_VALIDATE_MAX_SLOTS)" || return 2
    for (( n=1; n<=max; n++ )); do
        seed="$(_ci_validate_seed "${run_id}" "${run_attempt}" "${n}")"
        subnet="$(_ci_validate_subnet "${seed}")" || return 2
        crc=0
        overlap="$(_ci_validate_subnet_conflicts "${subnet}")" || crc=$?
        if [ "${crc}" -eq 0 ]; then
            ci_log "[CI-INFO-VALIDATE-0075]" "slot=${n}/${max} subnet=\"${subnet}\" overlaps=\"${overlap}\" reason=\"slot overlaps a live network; next\""
            continue
        fi
        if [ "${crc}" -eq 2 ]; then
            ci_log "[CI-ERROR-VALIDATE-0050]" "subnet=\"${subnet}\" reason=\"docker network list failed; cannot prove the slot free\""
            return 2
        fi
        lrc=0
        holder="$(_ci_validate_slot_lock "${subnet}")" || lrc=$?
        case "${lrc}" in
            0) printf 'subnet=%s holder=%s\n' "${subnet}" "${holder}"; return 0 ;;
            1) ci_log "[CI-INFO-VALIDATE-0076]" "slot=${n}/${max} subnet=\"${subnet}\" reason=\"slot lock held by another run; next\"" ;;
            *) return 2 ;;
        esac
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
    local file flags
    file="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local -a pf=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t pf <<< "${flags}"
    _ci_run "[CI-ERROR-VALIDATE-0086]" "file=\"${file}\" profiles=\"${flags//$'\n'/ }\" reason=\"docker compose config failed\"" \
        docker compose -f "${file}" "${pf[@]}" config --format json
}

# What: Compose service names passing one jq filter.
# Why: One owner; startable + health lists share it.
# From: Issue #1683
_ci_validate_service_list() {
    local filter="$1" raw
    if ! raw="$(_ci_validate_config_json)"; then
        ci_log "[CI-ERROR-VALIDATE-0069]" "filter=\"${filter}\" reason=\"compose config read failed\""
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
    local subnet="$1" svc svcs base cfg nets net slot half i=0
    svcs="$(_ci_validate_startable)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    if ! nets="$(jq -r '.networks // {} | keys[] | select(. != "default")' <<< "${cfg}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0067]" "reason=\"compose networks unreadable\"" "${nets}"
        return 2
    fi
    # What: default /28 plus one /29 per other network.
    # Why: an auto /16 pool could swallow the /27 slot.
    # From: Issue #1683 | PR #1858
    base="$(_ci_ipv4_to_int "${subnet%/*}")"
    slot="${subnet#*/}"
    half=$(( 1 << (31 - slot) ))
    printf 'networks:\n  default:\n    ipam:\n      config:\n        - subnet: %s/%s\n' \
        "$(_ci_int_to_ipv4 "${base}")" "$(( slot + 1 ))"
    while IFS= read -r net; do
        [ -n "${net}" ] || continue
        if [ "${i}" -ge 2 ]; then
            ci_log "[CI-ERROR-VALIDATE-0068]" "network=\"${net}\" reason=\"more than 2 extra compose networks; the /${slot} holds 2\""
            return 2
        fi
        printf '  %s:\n    ipam:\n      config:\n        - subnet: %s/%s\n' "${net}" \
            "$(_ci_int_to_ipv4 $(( base + half + half / 2 * i )))" "$(( slot + 2 ))"
        i=$(( i + 1 ))
    done <<< "${nets}"
    printf 'services:\n'
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        printf '  %s:\n    container_name: !reset null\n    ports: !reset []\n' "${svc}"
    done <<< "${svcs}"
    # What: host-mode services join the /27 when run alone.
    # Why: a probe runs one isolated; up never starts them.
    # From: Issue #763 | PR #1858
    svcs="$(_ci_validate_service_list '.value.network_mode == "host"')" || return 2
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        printf '  %s:\n    network_mode: !reset null\n' "${svc}"
    done <<< "${svcs}"
}

# What: container id of a compose service; empty if none.
# Why: docker error is rc 2 with raw, never "no container".
# From: Issue #1683 | PR #1858
_ci_validate_cid() {
    local project="$1" svc="$2" flag="${3:--q}"
    _ci_capture 0 docker compose -p "${project}" ps "${flag}" "${svc}"
}

# What: The /27 IP of a compose service container.
# Why: Checks target the runtime IP, never a fixed one.
# From: Issue #1683
_ci_validate_container_ip() {
    local project="$1" svc="$2" cid
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    [ -n "${cid}" ] || return 1
    _ci_validate_cid_ip "${project}" "${cid}"
}

# What: The /27 IP of a container id or name.
# Why: a compose run container has no service ps entry.
# From: Issue #763 | PR #1858
_ci_validate_cid_ip() {
    local project="$1" cid="$2" net ip
    net="${project}_default"
    ip="$(_ci_capture 0 docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${cid}")" || return 2
    case "${ip}" in
        *.*.*.*) printf '%s' "${ip}" ;;
        *) return 1 ;;
    esac
}

# What: Wait until a network has no containers.
# Why: rm before detach hits 'active endpoints'.
# From: Issue #1683 | PR #1858
_ci_validate_await_detached() {
    local name="$1" deadline count timeout
    timeout="$(_ci_variable CI_VALIDATE_DETACH_TIMEOUT)" || return 2
    deadline=$(( SECONDS + timeout ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if ! count="$(docker network inspect "${name}" --format '{{len .Containers}}' 2>&1)"; then
            _ci_validate_network_gone "${name}" "${count}"
            return "$?"
        fi
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
    if ! name="$(docker network inspect "${net_id}" --format '{{.Name}}' 2>&1)"; then
        _ci_validate_network_gone "${net_id}" "${name}"
        return "$?"
    fi
    # What: wait for detach; a timeout is not fatal here.
    # Why: the rm below fails with raw output if still busy.
    # From: Issue #1683 | PR #1858
    _ci_validate_await_detached "${name}" || true
    out="$(docker network rm "${name}" 2>&1)" && return 0
    ci_error "[CI-ERROR-VALIDATE-0053]" "network=\"${name}\" reason=\"network removal failed\"" "${out}"
    return 2
}

# What: rc 0 if inspect said "not found", else error.
# Why: a gone network is done; other errors are UNKNOWN.
# From: Issue #1683 | PR #1858
_ci_validate_network_gone() {
    local name="$1" raw="$2"
    if [[ "${raw}" == *"not found"* ]]; then
        return 0
    fi
    ci_error "[CI-ERROR-VALIDATE-0064]" "network=\"${name}\" reason=\"network inspect failed\"" "${raw}"
    return 2
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
        if ! base="$(_ci_alpine_image "[CI-ERROR-VALIDATE-0102]" "key=\"base_images.alpine\" reason=\"no alpine base to clear the state root\"")"; then
            rc=2
        elif ! out="$(docker run --rm --network none -v "${LANCACHE_STATE_DIR}:/s" "${base}" \
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
    # What: the socket-proxy allowlist exists before the up
    # Why: the proxy starts on the file ci.sh renders
    # From: Issue #1683 | PR #1858
    raw="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    ci_cmd_socket_proxy_config "${raw}" || return 2
    _ci_validate_compose "${project}" "${net_override}" "${pin_override}" up -d "${svcs[@]}"
}

# What: docker compose on the validate stack with its args.
# Why: up and run share one file, override and profile list.
# From: Issue #763 | PR #1858
_ci_validate_compose() {
    local project="$1" net_override="$2" pin_override="$3" file flags
    shift 3
    file="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local -a pf=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t pf <<< "${flags}"
    docker compose -p "${project}" -f "${file}" \
        -f "${net_override}" -f "${pin_override}" "${pf[@]}" "$@"
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
    local project="$1" svc="$2" deadline cid="" status="none" timeout
    timeout="$(_ci_variable CI_VALIDATE_HEALTH_TIMEOUT)" || return 2
    deadline=$(( SECONDS + timeout ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
        if [ -n "${cid}" ]; then
            status="$(_ci_capture 0 docker inspect --format '{{.State.Health.Status}}' "${cid}")" || return 2
            [ "${status}" = "healthy" ] && return 0
            if [ "${status}" = "unhealthy" ]; then
                ci_log "[CI-INFO-VALIDATE-0077]" "service=\"${svc}\" container=\"${cid}\" health=unhealthy reason=\"healthcheck reported unhealthy\""
                return 1
            fi
        fi
        sleep 2
    done
    ci_log "[CI-INFO-VALIDATE-0078]" "service=\"${svc}\" container=\"${cid:-none}\" last_health=\"${status}\" timeout=${timeout}s reason=\"not healthy before the deadline\""
    return 1
}

# What: Wait for a no-healthcheck service to settle.
# Why: Crash-loop signal is Status, never RestartCount.
# From: Issue #1683
_ci_validate_wait_stable() {
    local project="$1" svc="$2" deadline cid status started exitcode
    local prev_started="" stable_since=-1
    local window timeout
    window="$(_ci_variable CI_VALIDATE_STABLE_WINDOW)" || return 2
    timeout="$(_ci_variable CI_VALIDATE_HEALTH_TIMEOUT)" || return 2
    deadline=$(( SECONDS + timeout ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        cid="$(_ci_validate_cid "${project}" "${svc}" -aq)" || return 2
        if [ -z "${cid}" ]; then
            stable_since=-1
            sleep 2
            continue
        fi
        status="$(_ci_capture 0 docker inspect --format '{{.State.Status}}' "${cid}")" || return 2
        # What: exit is terminal, not a crash-loop.
        # Why: restart:no exits 0 by design (AG-VAL-027).
        # From: Issue #1683
        if [ "${status}" = "exited" ]; then
            exitcode="$(_ci_capture 0 docker inspect --format '{{.State.ExitCode}}' "${cid}")" || return 2
            [ "${exitcode}" = "0" ] && return 0
            ci_log "[CI-INFO-VALIDATE-0079]" "service=\"${svc}\" container=\"${cid}\" exit_code=${exitcode} reason=\"exited non-zero\""
            return 1
        fi
        started="$(_ci_capture 0 docker inspect --format '{{.State.StartedAt}}' "${cid}")" || return 2
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
    ci_log "[CI-INFO-VALIDATE-0080]" "service=\"${svc}\" container=\"${cid:-none}\" last_status=\"${status:-none}\" started=\"${prev_started}\" window=${window}s reason=\"not stable for the window before the deadline\""
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
    local wrc
    for i in "${!pids[@]}"; do
        wrc=0; wait "${pids[$i]}" || wrc=$?
        case "${wrc}" in
            0) ;;
            1)
                ci_error "[CI-ERROR-VALIDATE-0009]" "service=\"${names[$i]}\" check=\"${kinds[$i]}\" reason=\"not stable/healthy (cause above)\"" \
                    "$(_ci_validate_service_evidence "${project}" "${names[$i]}")"
                rc=1
                ;;
            *)
                ci_log "[CI-ERROR-VALIDATE-0081]" "service=\"${names[$i]}\" check=\"${kinds[$i]}\" rc=${wrc} reason=\"health state unknown (docker error above)\""
                [ "${rc}" -eq 1 ] || rc=2
                ;;
        esac
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
    local project="$1" url ip_std host h1 h2 port
    port="$(_ci_service_port http)" || return 2
    url="$(_ci_validation_proxy_probe_url)" || return 2
    ip_std="$(_ci_validate_container_ip "${project}" proxy)"
    host="${url#http://}"; host="${host%%/*}"
    if [ -z "${ip_std}" ] || [ -z "${host}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0012]" "url=\"${url}\" reason=\"missing proxy container IP or probe host\"" "${ip_std}"
        return 2
    fi
    if ! h1="$(curl -fsS --resolve "${host}:${port}:${ip_std}" -D - -o /dev/null "${url}" 2>&1)"; then
        ci_log "[CI-ERROR-VALIDATE-0013]" "url=\"${url}\" reason=\"proxy MISS request failed\""
        printf 'raw:\n%s\n' "${h1}"
        return 1
    fi
    if ! h2="$(curl -fsS --resolve "${host}:${port}:${ip_std}" -D - -o /dev/null "${url}" 2>&1)"; then
        ci_log "[CI-ERROR-VALIDATE-0065]" "url=\"${url}\" reason=\"proxy repeat request failed\""
        printf 'raw:\n%s\n' "${h2}"
        return 1
    fi
    if ! grep -qi 'X-Cache-Status:[[:space:]]*HIT' <<< "${h2}"; then
        ci_log "[CI-ERROR-VALIDATE-0014]" "url=\"${url}\" reason=\"second request not a cache HIT\""
        printf 'first:\n%s\nsecond:\n%s\n' "${h1}" "${h2}"
        return 1
    fi
}

# What: print *.domain stream targets not sent to the SNI
# Why: a root literal sends every subdomain to one origin
# From: Issue #1297 | PR #1858
_ci_stream_map_violations() {
    local port="$1"
    awk -v want="\$ssl_preread_server_name:${port};" '/^[[:space:]]*\*\./ && $2 != want { print }'
}

# What: print depth>=2 dispatch entries off the relay port
# Why: deeper SNI has no wildcard cert; it must passthrough
# From: Issue #1322 | PR #1858
_ci_ssl_dispatch_violations() {
    local port="$1"
    awk -v want=":${port};" 'index($0, "~^.+\\.") > 0 && substr($NF, length($NF) - length(want) + 1) != want { print }'
}

# What: prove proxy routes wildcards by SNI.
# Why: root literal misroutes subdomains.
# From: Issue #1683
_ci_validate_proxy_stream_map() {
    local project="$1" cid map bad file port
    file="$(_ci_proxy_constant STREAM_TARGET_FILE)" || return 2
    port="$(_ci_service_port https)" || return 2
    cid="$(_ci_validate_cid "${project}" proxy)" || return 2
    if [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0022]" "reason=\"no proxy container for stream-map check\""
        return 2
    fi
    if ! map="$(_ci_capture 0 docker exec "${cid}" cat "${file}")"; then
        ci_log "[CI-ERROR-VALIDATE-0019]" "reason=\"could not read proxy stream-target map\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | _ci_stream_map_violations "${port}")"
    if [ -n "${bad}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0020]" "reason=\"stream-target wildcard forwards to a hardcoded root, not the requested SNI (#1297)\"" "${bad}"
        return 1
    fi
}

# What: Prove ssl mode intercepts (MITM) with our LAN CA.
# Why: the proxy https port must show a cert we signed
# From: Issue #1683
_ci_validate_ssl_mitm() {
    local project="$1" ip cid domain ca_subj issuer tmp out cert tls_err ca port
    ca="$(_ci_proxy_constant CA_DIR)" || return 2
    port="$(_ci_service_port https)" || return 2
    ip="$(_ci_validate_container_ip "${project}" proxy)"
    cid="$(_ci_validate_cid "${project}" proxy)" || return 2
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip}" ] || [ -z "${cid}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0023]" "reason=\"no proxy container/IP or test domain for ssl-mitm check\""
        return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-proxy-ca.XXXXXX")" || return 2
    if ! out="$(docker cp "${cid}:${ca}/ca.crt" "${tmp}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0024]" "reason=\"could not read proxy LAN CA for ssl-mitm check\"" "${out}"
        rm -f "${tmp}"
        return 2
    fi
    ca_subj="$(_ci_capture 0 openssl x509 -noout -subject -in "${tmp}")" || { rm -f "${tmp}"; return 2; }
    ca_subj="${ca_subj#subject=}"
    rm -f "${tmp}"
    # What: s_client writes handshake notes to stderr.
    # Why: raw evidence when the issuer read fails.
    # From: Issue #1683 | PR #1858
    tls_err="$(_ci_mktemp "${CI_TMPDIR}/ci-tls-err.XXXXXX")" || { rm -f "${tmp}"; return 2; }
    cert="$(openssl s_client -connect "${ip}:${port}" -servername "${domain}" </dev/null 2>"${tls_err}")"
    issuer=""
    if [ -n "${cert}" ]; then
        issuer="$(openssl x509 -noout -issuer 2>>"${tls_err}" <<<"${cert}")"
        issuer="${issuer#issuer=}"
    fi
    if [ -z "${ca_subj}" ] || [ -z "${issuer}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0025]" "domain=\"${domain}\" reason=\"no TLS issuer or CA subject for ssl-mitm check\"" "$(cat "${tls_err}")"
        rm -f "${tls_err}"
        return 1
    fi
    rm -f "${tls_err}"
    # What: the https cert issuer MUST equal our own LAN CA.
    # Why: proves interception, not passthrough.
    # From: Issue #668
    if [ "${issuer}" != "${ca_subj}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0026]" "issuer=\"${issuer}\" ca=\"${ca_subj}\" reason=\"ssl mode :${port} cert not issued by our LAN CA (not intercepting, #668)\""
        return 1
    fi
}

# What: ssl-mode depth-dispatch routes deeper SNI right.
# Why: depth>=2 SNI takes the passthrough relay, not MITM
# From: Issue #1683
_ci_validate_ssl_dispatch_map() {
    local project="$1" cid map bad file relay
    file="$(_ci_proxy_constant SSL_DISPATCH_MAP_FILE)" || return 2
    relay="$(_ci_proxy_constant SSL_DISPATCH_PASSTHROUGH_RELAY_PORT)" || return 2
    cid="$(_ci_validate_cid "${project}" proxy)" || return 2
    if [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0027]" "reason=\"no proxy container for ssl-dispatch-map check\""
        return 2
    fi
    if ! map="$(_ci_capture 0 docker exec "${cid}" cat "${file}")"; then
        ci_log "[CI-ERROR-VALIDATE-0028]" "reason=\"could not read proxy ssl-dispatch map (SSL_ENABLED=0?)\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | _ci_ssl_dispatch_violations "${relay}")"
    if [ -n "${bad}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0029]" "reason=\"depth>=2 SNI dispatch entry routes to MITM, not passthrough relay :${relay} (#1276/#1322)\"" "${bad}"
        return 1
    fi
}

# What: retry a probe; print its last raw error on fail.
# Why: a timeout must show why the probe never answered.
# From: Issue #1683 | PR #1858
_ci_validate_poll() {
    local attempts="$1" pause="$2" i out
    shift 2
    for (( i = 1; i <= attempts; i++ )); do
        if out="$("$@" 2>&1)"; then
            return 0
        fi
        if [ "${i}" -lt "${attempts}" ]; then
            sleep "${pause}"
        fi
    done
    printf '%s\n' "${out}"
    return 1
}

# What: http://<ip>:<port> of one ui container in the /27
# Why: the image exposes one port; resolved once per probe
# From: Issue #1683 | PR #1858
_ci_validate_ui_base() {
    local project="$1" cid="$2" ip ports p
    local -a tcp=()
    if [ -z "${cid}" ] || ! ip="$(_ci_validate_cid_ip "${project}" "${cid}")"; then
        ci_log "[CI-ERROR-VALIDATE-0103]" "container=\"${cid}\" reason=\"no /27 IP for the ui container\""
        return 2
    fi
    ports="$(_ci_capture 0 docker inspect -f '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${cid}")" || return 2
    while IFS= read -r p; do
        if [[ "${p}" =~ ^([0-9]+)/tcp$ ]]; then
            tcp+=("${BASH_REMATCH[1]}")
        fi
    done <<< "${ports}"
    if [ "${#tcp[@]}" -ne 1 ]; then
        ci_error "[CI-ERROR-VALIDATE-0104]" "container=\"${cid}\" reason=\"need exactly one exposed TCP port\"" "${ports}"
        return 2
    fi
    printf 'http://%s:%s' "${ip}" "${tcp[0]}"
}

# What: open a ui session in <jar>; print its CSRF token
# Why: posts send the token a browser reads from the form
# From: Issue #1683 | PR #1858
_ci_validate_ui_session() {
    local jar="$1" base="$2" attempts pause page csrf last
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0030]" "reason=\"no ui container IP for session check\""
        return 2
    fi
    attempts="$(_ci_variable CI_VALIDATE_UI_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_UI_POLL_PAUSE)" || return 2
    # What: ui has no compose healthcheck; poll /domains.
    # Why: wait_healthy misses ui; prove it answers first.
    # From: Issue #1683
    if ! last="$(_ci_validate_poll "${attempts}" "${pause}" curl -fsS -c "${jar}" -o /dev/null "${base}/domains")"; then
        ci_error "[CI-ERROR-VALIDATE-0031]" "reason=\"ui /domains never answered\"" "${last}"
        return 1
    fi
    page="$(_ci_capture 0 curl -fsS -b "${jar}" -c "${jar}" "${base}/domains")" || return 2
    csrf="$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' <<< "${page}")"
    csrf="${csrf%%$'\n'*}"
    if [ -z "${csrf}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0032]" "url=\"${base}/domains\" reason=\"no csrf_token field on the ui page\"" "${page}"
        return 1
    fi
    printf '%s' "${csrf}"
}

# What: POST one LAN A record through the ui (303 on ok)
# Why: drives the real UI->NATS->PowerDNS write path
# From: Issue #1683 | PR #1858
_ci_validate_ui_add_record() {
    local base="$1" jar="$2" csrf="$3" zone="$4" name="$5" content="$6" ttl
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0033]" "reason=\"no ui container IP for add-record\""
        return 2
    fi
    ttl="$(_ci_variable CI_VALIDATE_PROBE_TTL)" || return 2
    _ci_validate_ui_post "${base}" "${jar}" "/domains/${zone%.}/add" "csrf_token=${csrf}" \
        "name=${name}" record_type=A "content=${content}" "ttl=${ttl}"
}

# What: POST a UI form; rc 0 on 303, 1 other, 2 on error.
# Why: one owner for the CSRF form post and its 303 check.
# From: Issue #1683 | PR #1858
_ci_validate_ui_post() {
    local base="$1" jar="$2" path="$3" field code
    shift 3
    local -a data=()
    for field in "$@"; do
        data+=(--data-urlencode "${field}")
    done
    code="$(_ci_capture 0 curl -sS -b "${jar}" -o /dev/null -w '%{http_code}' \
        "${data[@]}" "${base}${path}")" || {
        ci_log "[CI-ERROR-VALIDATE-0082]" "url=\"${base}${path}\" reason=\"ui form post failed (raw above)\""
        return 2
    }
    if [ "${code}" != "303" ]; then
        ci_log "[CI-ERROR-VALIDATE-0034]" "url=\"${base}${path}\" code=\"${code}\" reason=\"ui form post did not return 303\""
        return 1
    fi
}

# What: the first LAN zone the dns entrypoint creates
# Why: probes write where dns serves; dns owns the zones
# From: Issue #1683 | PR #1858
_ci_validate_lan_zone() {
    local ep zones
    ep="$(_ci_service_path dns entrypoint.sh)" || return 2
    zones="$(_ci_shell_array "${ep}" LAN_ZONES)" || return 2
    if [ -z "${zones}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0106]" "path=\"${ep}\" reason=\"no LAN_ZONES entry in the dns entrypoint\""
        return 2
    fi
    printf '%s\n' "${zones%%$'\n'*}"
}

# What: host <n> of the SOT probe net (RFC 5737 TEST-NET)
# Why: a probe answer must never be a real LAN address
# From: Issue #1683 | PR #1858
_ci_validate_probe_ip() {
    local n="$1" net base
    net="$(_ci_variable CI_VALIDATE_PROBE_NET)" || return 2
    if [[ ! "${net}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/([0-9]+)$ ]] \
        || [ "${n}" -lt 1 ] || [ "${n}" -ge $(( (1 << (32 - BASH_REMATCH[1])) - 1 )) ]; then
        ci_log "[CI-ERROR-VALIDATE-0105]" "net=\"${net}\" host=\"${n}\" reason=\"probe host outside the SOT probe net\""
        return 2
    fi
    base="$(_ci_ipv4_to_int "${net%/*}")"
    _ci_int_to_ipv4 $(( base + n ))
}

# What: probe MAC <n>: the SOT probe MAC, last octet n
# Why: a locally administered MAC never hits a real NIC
# From: Issue #763 | PR #1858
_ci_validate_probe_mac() {
    local n="$1" mac
    mac="$(_ci_variable CI_VALIDATE_PROBE_MAC)" || return 2
    if [[ ! "${mac}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || [ "${n}" -lt 1 ] || [ "${n}" -gt 255 ]; then
        ci_log "[CI-ERROR-VALIDATE-0111]" "mac=\"${mac}\" host=\"${n}\" reason=\"probe MAC outside the SOT probe MAC\""
        return 2
    fi
    printf '%s:%02x' "${mac%:*}" "${n}"
}

# What: Poll dig until <fqdn> resolves to <expected>.
# Why: NATS->PowerDNS (AXFR to ssl) async; prove it.
# From: Issue #1683
_ci_validate_dns_resolves() {
    local project="$1" svc="$2" fqdn="$3" expected="$4" attempts="$5" ip got i
    ip="$(_ci_validate_container_ip "${project}" "${svc}")"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0035]" "svc=\"${svc}\" reason=\"no dns IP for resolve check\""
        return 2
    fi
    local out="" dig_err
    # What: dig stderr kept apart from the compared answer.
    # Why: a warning must not turn a match into a mismatch.
    # From: Issue #1683 | PR #1858
    dig_err="$(_ci_mktemp "${CI_TMPDIR}/ci-dig-err.XXXXXX")" || return 2
    for (( i = 1; i <= attempts; i++ )); do
        got=""
        if out="$(dig +time=2 +tries=1 +short "@${ip}" A "${fqdn}" 2>"${dig_err}")"; then
            got="$(sort -u <<<"${out}")"
        fi
        if [ "${got}" = "${expected}" ]; then
            rm -f "${dig_err}"
            return 0
        fi
        sleep 1
    done
    # What: full answer, zone SOA and the service's logs.
    # Why: +short hides NXDOMAIN vs empty vs SERVFAIL.
    # From: Issue #1683 | PR #1858
    ci_error "[CI-ERROR-VALIDATE-0036]" "svc=\"${svc}\" fqdn=\"${fqdn}\" expected=\"${expected}\" got=\"${got:-}\" reason=\"record did not resolve as expected\"" \
        "${out}$(cat "${dig_err}")
full answer:
$(dig +time=2 +tries=1 "@${ip}" A "${fqdn}" 2>&1)
zone SOA:
$(dig +time=2 +tries=1 +short "@${ip}" SOA "${fqdn#*.}" 2>&1)
service:
$(_ci_validate_service_evidence "${project}" "${svc}")"
    rm -f "${dig_err}"
    return 1
}

# What: UI->NATS->PowerDNS writes reach both dns modes.
# Why: Real end-to-end NATS ingest + AXFR, not mock.
# From: Issue #1683
_ci_validate_ui_nats_dns() {
    local project="$1" jar csrf cid base zone label ip dns_wait axfr_wait rc=0
    cid="$(_ci_validate_cid "${project}" ui)" || return 2
    base="$(_ci_validate_ui_base "${project}" "${cid}")" || return $?
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    ip="$(_ci_validate_probe_ip 1)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    axfr_wait="$(_ci_variable CI_VALIDATE_AXFR_WAIT)" || return 2
    jar="$(_ci_mktemp "${CI_TMPDIR}/ci-ui-jar.XXXXXX")" || return 2
    csrf="$(_ci_validate_ui_session "${jar}" "${base}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${zone}" "${label}" "${ip}" || rc=$?
    rm -f "${jar}"
    [ "${rc}" -eq 0 ] || return "${rc}"
    _ci_validate_dns_resolves "${project}" dns-standard "${label}.${zone}" "${ip}" "${dns_wait}" || return $?
    _ci_validate_dns_resolves "${project}" dns-ssl "${label}.${zone}" "${ip}" "${axfr_wait}" || return $?
}

# What: curl with one header, user or data line from stdin
# Why: a secret on argv shows in every process list
# From: Issue #1683 | PR #1858
_ci_curl_secret() {
    local opt="$1" value="$2"
    shift 2
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s = "%s"\n' "${opt}" "${value}" | curl -K - "$@"
}

# What: one shared secret read inside a running container
# Why: its dir is the shared-secrets mount, not a default
# From: Issue #858 | PR #1858
_ci_validate_shared_secret() {
    local project="$1" cid="$2" name="$3" dir
    dir="$(_ci_capture 0 docker inspect -f "{{range .Mounts}}{{if eq .Name \"${project}_shared-secrets\"}}{{.Destination}}{{end}}{{end}}" "${cid}")" || return 2
    if [ -z "${dir}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0107]" "container=\"${cid}\" reason=\"no shared-secrets volume mount\""
        return 2
    fi
    _ci_capture 0 docker exec "${cid}" cat "${dir}/${name}"
}

# What: http://<dns ip>:<port> of the rollback listener
# Why: the port comes from the ui's DNS_ROLLBACK_URL env
# From: Issue #628 | PR #1858
_ci_validate_rollback_base() {
    local ip="$1" ucid="$2" env url
    env="$(_ci_capture 0 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${ucid}")" || return 2
    url="$(sed -n 's/^DNS_ROLLBACK_URL=//p' <<< "${env}")"
    if [[ ! "${url}" =~ ^https?://[^/:]+:([0-9]+)/?$ ]]; then
        ci_error "[CI-ERROR-VALIDATE-0108]" "container=\"${ucid}\" reason=\"no DNS_ROLLBACK_URL with a port in the ui env\"" "${url}"
        return 2
    fi
    printf 'http://%s:%s' "${ip}" "${BASH_REMATCH[1]}"
}

# What: DNS known-good snapshot/rollback round-trip.
# Why: Real listener HTTP + PATCH + cache flush.
# From: Issue #1683
_ci_validate_dns_rollback() {
    local project="$1" ip cid key jar csrf snap resp code rc=0 compose last
    local zone label old new dns_wait ucid base lbase tries pause su
    ip="$(_ci_validate_container_ip "${project}" dns-standard)"
    cid="$(_ci_validate_cid "${project}" dns-standard)" || return 2
    if [ -z "${ip}" ] || [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0037]" "reason=\"no dns-standard container/IP for rollback check\""
        return 2
    fi
    # What: read PDNS_API_KEY from the shared-secrets mount.
    # Why: entrypoint resolves it at runtime, not env.
    # From: Issue #858
    key="$(_ci_validate_shared_secret "${project}" "${cid}" pdns-api-key)" || return 2
    key="${key//$'\n'/}"
    if [ -z "${key}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0038]" "reason=\"could not read PDNS_API_KEY from shared-secrets\""
        return 2
    fi
    ucid="$(_ci_validate_cid "${project}" ui)" || return 2
    lbase="$(_ci_validate_rollback_base "${ip}" "${ucid}")" || return 2
    tries="$(_ci_variable CI_VALIDATE_LISTENER_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_LISTENER_POLL_PAUSE)" || return 2
    # What: poll until the rollback listener accepts.
    # Why: healthy != bound; nats-subscriber binds late.
    # From: Issue #628
    if ! last="$(_ci_validate_poll "${tries}" "${pause}" _ci_curl_secret header "X-API-Key: ${key}" -fsS -o /dev/null "${lbase}/snapshots")"; then
        ci_error "[CI-ERROR-VALIDATE-0039]" "url=\"${lbase}\" reason=\"rollback listener never accepted a connection\"" "${last}"
        return 1
    fi
    code="$(_ci_capture 0 curl -sS -o /dev/null -w '%{http_code}' "${lbase}/snapshots")" || return 2
    if [ "${code}" != "401" ]; then
        ci_log "[CI-ERROR-VALIDATE-0040]" "code=\"${code}\" reason=\"/snapshots without X-API-Key not 401\""
        return 1
    fi
    code="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}x" -sS -o /dev/null -w '%{http_code}' "${lbase}/snapshots")" || return 2
    if [ "${code}" != "401" ]; then
        ci_log "[CI-ERROR-VALIDATE-0041]" "code=\"${code}\" reason=\"/snapshots with wrong X-API-Key not 401\""
        return 1
    fi
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    old="$(_ci_validate_probe_ip 2)" && new="$(_ci_validate_probe_ip 3)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    base="$(_ci_validate_ui_base "${project}" "${ucid}")" || return $?
    jar="$(_ci_mktemp "${CI_TMPDIR}/ci-rb-jar.XXXXXX")" || return 2
    csrf="$(_ci_validate_ui_session "${jar}" "${base}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${zone}" "${label}" "${old}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" dns-standard "${label}.${zone}" "${old}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    # What: capture the zone's newest snapshot (pre-change).
    # Why: target this test rolls back to after 2nd write.
    # From: Issue #628
    resp="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}" -sS "${lbase}/snapshots")" || { rm -f "${jar}"; return 2; }
    snap="$(_ci_capture 0 jq -r --arg z "${zone}" '.zones[$z][0].id // empty' <<<"${resp}")" || { rm -f "${jar}"; return 2; }
    if [ -z "${snap}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0042]" "zone=\"${zone}\" reason=\"no known-good snapshot after first write\""
        rm -f "${jar}"
        return 1
    fi
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${zone}" "${label}" "${new}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" dns-standard "${label}.${zone}" "${new}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    rm -f "${jar}"
    resp="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}" -sS "${lbase}/snapshots")" || return 2
    last="$(_ci_capture 0 jq -r --arg z "${zone}" '.zones[$z][0].id // empty' <<<"${resp}")" || return 2
    compose="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    su="$(_ci_installer)" || return 2
    # What: setup.sh rollback, wrong host PDNS_API_KEY.
    # Why: the key must be resolved inside the container.
    # From: Issue #836
    resp="$(COMPOSE_PROJECT_NAME="${project}" PDNS_API_KEY=CHANGE_ME_host_side_key_never_used \
        bash "${su}" reset-to-last-known-good-config dns "$(dirname "${compose}")" \
        "${zone}" "${snap}" --yes 2>&1)" || rc=$?
    case "${rc}:${resp}" in
        *"cache-flush publishes failed"*) rc=1 ;;
        0:*"rolled back to known-good snapshot ${snap}"*"${label}.${zone}"*) ;;
        *) rc=1 ;;
    esac
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-VALIDATE-0043]" "reason=\"setup.sh rollback not applied, probe unchanged or flush failed\"" "${resp}"
        return 1
    fi
    # What: post-rollback dig must return the OLD content.
    # Why: proves recursor cache flush reached it.
    # From: Issue #628
    _ci_validate_dns_resolves "${project}" dns-standard "${label}.${zone}" "${old}" "${dns_wait}" || return $?
    tries="$(_ci_variable CI_VALIDATE_SNAPSHOT_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_SNAPSHOT_POLL_PAUSE)" || return 2
    if ! resp="$(_ci_validate_poll "${tries}" "${pause}" _ci_validate_new_snapshot "${lbase}" "${key}" "${last}" "${zone}")"; then
        ci_error "[CI-ERROR-VALIDATE-0087]" "previous=\"${last}\" zone=\"${zone}\" reason=\"no new snapshot after the rollback\"" "${resp}"
        return 1
    fi
}

# What: true if zone $4's newest snapshot id is not $3
# Why: a restore must record the restored state too.
# From: Issue #836
_ci_validate_new_snapshot() {
    _ci_curl_secret header "X-API-Key: $2" -fsS "$1/snapshots" \
        | jq -e --arg p "$3" --arg z "$4" '(.zones[$z][0].id // "") as $i | $i != "" and $i != $p' >/dev/null
}

# What: http-port or user of the Kea control agent config
# Why: the agent config owns where and as whom it answers
# From: Issue #763 | PR #1858
_ci_validate_kea_agent() {
    local field="$1" conf expr out
    conf="$(_ci_service_path dhcp kea-ctrl-agent.conf)" || return 2
    case "${field}" in
        http-port) expr='s/^[[:space:]]*"http-port":[[:space:]]*([0-9]+),?[[:space:]]*$/\1/p' ;;
        user) expr='s/^[[:space:]]*"user":[[:space:]]*"([^"$]+)",?[[:space:]]*$/\1/p' ;;
        *) ci_log "[CI-ERROR-VALIDATE-0109]" "field=\"${field}\" reason=\"unknown Kea agent field\""; return 2 ;;
    esac
    out="$(_ci_file_value "${conf}" "${expr}")" || {
        [ "$?" -eq 2 ] || ci_error "[CI-ERROR-VALIDATE-0110]" "file=\"${conf}\" field=\"${field}\" reason=\"need exactly one literal value\"" "${out}"
        return 2
    }
    printf '%s\n' "${out}"
}

# What: One Kea Control Agent command; prints the reply.
# Why: ready poll, subnet read and rollback check share it.
# From: Issue #763 | PR #1858
_ci_validate_kea_cmd() {
    _ci_curl_secret user "$2:$3" -fsS -H 'Content-Type: application/json' -d "$4" "$1/"
}

# What: True once Kea answers config-get with result 0.
# Why: run -d returns before kea-dhcp4 and the agent bind.
# From: Issue #763 | PR #1858
_ci_validate_kea_ready() {
    _ci_validate_kea_cmd "$1" "$2" "$3" '{"command":"config-get","service":["dhcp4"]}' \
        | jq -e '.[0].result == 0' >/dev/null
}

# What: Kea snapshot ids under <snapshot dir>, oldest first.
# Why: the rollback target is the id a ui write added.
# From: Issue #763 | PR #1858
_ci_validate_kea_snapshots() {
    local found p id
    found="$(_ci_capture 0 find "$1" -mindepth 2 -maxdepth 2 -name dhcp4.json)" || return 2
    while IFS= read -r p; do
        id="${p%/dhcp4.json}"
        id="${id##*/}"
        if [[ "${id}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "${id}"
        fi
    done <<< "${found}" | sort
}

# What: Count live Kea reservations for one MAC.
# Why: the rollback must change Kea's state, not a file.
# From: Issue #763 | PR #1858
_ci_validate_kea_has() {
    local cfg
    cfg="$(_ci_capture 0 _ci_validate_kea_cmd "$1" "$2" "$3" '{"command":"config-get","service":["dhcp4"]}')" || return 2
    _ci_capture 0 jq -r --arg m "$4" \
        '[.[0].arguments.Dhcp4.subnet4[].reservations[]? | select((."hw-address" | ascii_downcase) == ($m | ascii_downcase))] | length' \
        <<< "${cfg}"
}

# What: Add one reservation via the ui, print new snapshot.
# Why: every ui write must record exactly one new snapshot.
# From: Issue #763 | PR #1858
_ci_validate_kea_add() {
    local base="$1" jar="$2" csrf="$3" sid="$4" mac="$5" ip="$6" host="$7" dir="$8"
    local before after new
    before="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    _ci_validate_ui_post "${base}" "${jar}" /dhcp/static/add "csrf_token=${csrf}" \
        "subnet_id=${sid}" "mac=${mac}" "ip=${ip}" "hostname=${host}" || return $?
    after="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    new="$(tail -n 1 <<< "${after}")"
    if [ -z "${new}" ] || grep -qxF -- "${new}" <<< "${before}"; then
        ci_log "[CI-ERROR-VALIDATE-0088]" "mac=\"${mac}\" before=\"${before//$'\n'/ }\" after=\"${after//$'\n'/ }\" reason=\"ui reservation write recorded no new Kea snapshot\""
        return 1
    fi
    printf '%s' "${new}"
}

# What: Two ui writes, setup.sh rollback, live config-get.
# Why: the CLI fallback must revert Kea's running config.
# From: Issue #763 | PR #1858
_ci_validate_kea_round_trip() {
    local project="$1" kip="$2" kport="$3" uname="$4" cfg token dir subnet resp sid ubase
    local jar csrf base snap inst out n_a n_b rc=0 kbase kuser label mac_a mac_b tries pause su snapdir mount snaps compose
    kbase="http://${kip}:${kport}"
    kuser="$(_ci_validate_kea_agent user)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    mac_a="$(_ci_validate_probe_mac 1)" && mac_b="$(_ci_validate_probe_mac 2)" || return 2
    tries="$(_ci_variable CI_VALIDATE_KEA_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_KEA_POLL_PAUSE)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    token="$(_ci_capture 0 jq -r '.services.dhcp.environment.KEA_CTRL_TOKEN // empty' <<< "${cfg}")" || return 2
    snapdir="$(_ci_capture 0 jq -r '.services.dhcp.environment.KEA_CONFIG_SNAPSHOT_DIR // empty' <<< "${cfg}")" || return 2
    # What: the dhcp mount holding KEA_CONFIG_SNAPSHOT_DIR
    # Why: its source is the Kea data dir on the host
    # From: Issue #763 | PR #1858
    mount="$(_ci_capture 0 jq -r --arg s "${snapdir}" '.services.dhcp.volumes[]? | .target as $t
        | select($t != "" and ($s | startswith($t + "/"))) | "\(.source)\t\($s | ltrimstr($t))"' <<< "${cfg}")" || return 2
    subnet="$(_ci_capture 0 jq -r '.services.dhcp.environment.DHCP_SUBNET // empty' <<< "${cfg}")" || return 2
    if [ -z "${token}" ] || [ -z "${snapdir}" ] || [ -z "${mount}" ] || [[ "${mount}" == *$'\n'* ]] || [ -z "${subnet}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0089]" "reason=\"dhcp compose config lacks KEA_CTRL_TOKEN, one mount holding KEA_CONFIG_SNAPSHOT_DIR, or DHCP_SUBNET\"" "${mount}"
        return 2
    fi
    dir="${mount%%$'\t'*}"
    snaps="${dir}${mount#*$'\t'}"
    if ! out="$(_ci_validate_poll "${tries}" "${pause}" _ci_validate_kea_ready "${kbase}" "${kuser}" "${token}")"; then
        ci_error "[CI-ERROR-VALIDATE-0090]" "ip=\"${kip}\" reason=\"Kea control agent never answered config-get\"" "${out}"
        return 1
    fi
    resp="$(_ci_capture 0 _ci_validate_kea_cmd "${kbase}" "${kuser}" "${token}" '{"command":"config-get","service":["dhcp4"]}')" || return 2
    sid="$(_ci_capture 0 jq -r --arg s "${subnet}" '.[0].arguments.Dhcp4.subnet4[]? | select(.subnet == $s) | .id' <<< "${resp}")" || return 2
    if [ -z "${sid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0091]" "subnet=\"${subnet}\" reason=\"no Kea subnet4 entry for DHCP_SUBNET\""
        return 1
    fi
    ubase="$(_ci_validate_ui_base "${project}" "${uname}")" || {
        rc=$?
        ci_log "[CI-ERROR-VALIDATE-0092]" "container=\"${uname}\" reason=\"no /27 IP for the Kea ui run container\""
        return "${rc}"
    }
    jar="$(_ci_mktemp "${CI_TMPDIR}/ci-kea-jar.XXXXXX")" || return 2
    csrf="$(_ci_validate_ui_session "${jar}" "${ubase}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    # What: reservation IPs base+2/+3 of DHCP_SUBNET.
    # Why: Kea rejects a reservation outside its subnet.
    # From: Issue #763 | PR #1858
    base="$(_ci_ipv4_to_int "${subnet%/*}")"
    snap="$(_ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_a}" \
        "$(_ci_int_to_ipv4 $(( base + 2 )))" "${label}-1" "${snaps}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    _ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_b}" \
        "$(_ci_int_to_ipv4 $(( base + 3 )))" "${label}-2" "${snaps}" >/dev/null || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    rm -f "${jar}"
    compose="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    su="$(_ci_installer)" || return 2
    inst="$(dirname "${compose}")"
    if [ -e "${inst}/.env.local" ]; then
        ci_log "[CI-ERROR-VALIDATE-0113]" "path=\"${inst}/.env.local\" reason=\"an .env.local exists; validate never overwrites it\""
        return 2
    fi
    # What: .env.local: deploy .env plus this run's KEA_*
    # Why: setup.sh reads a deploy/prod install's .env.local
    # From: Issue #763 | PR #1858
    if ! out="$(grep -v -E '^(KEA_CTRL_TOKEN|KEA_CTRL_HOST|KEA_DATA_DIR)=' "${inst}/.env" 2>&1)" \
        || ! (umask 077 && printf '%s\nKEA_CTRL_TOKEN=%s\nKEA_CTRL_HOST=%s\nKEA_DATA_DIR=%s\n' \
            "${out}" "${token}" "${kip}" "${dir}" > "${inst}/.env.local"); then
        ci_error "[CI-ERROR-VALIDATE-0093]" "dir=\"${inst}\" reason=\"setup.sh .env.local not written\"" "${out}"
        rm -f "${inst}/.env.local"
        return 2
    fi
    resp="$(bash "${su}" reset-to-last-known-good-config kea "${inst}" "${snap}" --yes 2>&1)" || rc=$?
    rm -f "${inst}/.env.local"
    case "${rc}:${resp}" in
        0:*"Kea rolled back to known-good snapshot ${snap} ("*) ;;
        *)
            ci_error "[CI-ERROR-VALIDATE-0094]" "snapshot=\"${snap}\" rc=\"${rc}\" reason=\"setup.sh kea rollback did not report the requested snapshot\"" "${resp}"
            return 1
            ;;
    esac
    n_a="$(_ci_validate_kea_has "${kbase}" "${kuser}" "${token}" "${mac_a}")" || return 2
    n_b="$(_ci_validate_kea_has "${kbase}" "${kuser}" "${token}" "${mac_b}")" || return 2
    if [ "${n_a}" != 1 ] || [ "${n_b}" != 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0095]" "snapshot=\"${snap}\" a=\"${n_a}\" b=\"${n_b}\" reason=\"live Kea config is not the snapshot state (want a=1 b=0)\""
        return 1
    fi
}

# What: Remove one compose run container of a probe.
# Why: frees its /27 address before the next probe runs.
# From: Issue #763 | PR #1858
_ci_validate_rm_run() {
    _ci_run "[CI-ERROR-VALIDATE-0099]" "container=\"$1\" reason=\"run container not removed\"" \
        docker rm -f "$1" >/dev/null
}

# What: Kea rollback leg on its own run containers.
# Why: dhcp is host-mode, so up never starts a Kea.
# From: Issue #763 | PR #1858
_ci_validate_kea_rollback() {
    local project="$1" net="$2" pin="$3" kname uname kip kport rc=0
    kname="${project}-kea"
    uname="${project}-kea-ui"
    kport="$(_ci_validate_kea_agent http-port)" || return 2
    _ci_run "[CI-ERROR-VALIDATE-0096]" "project=\"${project}\" service=\"dhcp\" reason=\"Kea run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${kname}" dhcp >/dev/null || return $?
    if ! kip="$(_ci_validate_cid_ip "${project}" "${kname}")"; then
        ci_log "[CI-ERROR-VALIDATE-0097]" "container=\"${kname}\" reason=\"no /27 IP for the Kea run container\""
        rc=2
    elif _ci_run "[CI-ERROR-VALIDATE-0098]" "project=\"${project}\" service=\"ui\" reason=\"Kea ui run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${uname}" \
        -e DHCP_MODE=kea -e "DHCP_API_URL=http://${kip}:${kport}" ui >/dev/null; then
        _ci_validate_kea_round_trip "${project}" "${kip}" "${kport}" "${uname}" || rc=$?
        _ci_validate_rm_run "${uname}" || { [ "${rc}" -ne 0 ] || rc=2; }
    else
        rc=2
    fi
    _ci_validate_rm_run "${kname}" || { [ "${rc}" -ne 0 ] || rc=2; }
    return "${rc}"
}

# What: POST /api/secondary/register; print JSON on 200.
# Why: token-gated, no session/CSRF; reused per name.
# From: Issue #583
_ci_register_secondary() {
    local base="$1" token="$2" name="$3" out code
    out="$(_ci_capture 0 _ci_curl_secret data "{\"token\":\"${token}\",\"name\":\"${name}\"}" \
        -sS -w '\n%{http_code}' -H 'Content-Type: application/json' \
        "${base}/api/secondary/register")" || {
        ci_log "[CI-ERROR-VALIDATE-0083]" "url=\"${base}/api/secondary/register\" name=\"${name}\" reason=\"secondary register request failed (raw above)\""
        return 2
    }
    code="${out##*$'\n'}"
    if [ "${code}" != "200" ]; then
        printf 'register %s: http %s\n%s\n' "${name}" "${code}" "${out%$'\n'*}" >&2
        return 1
    fi
    printf '%s' "${out%$'\n'*}"
}

# What: the ui's token file path from its running env
# Why: the ui reads it from env; CI asks it, never copies
# From: Issue #583 | PR #1905
_ci_validate_ui_token_file() {
    local cid="$1" tf
    if ! tf="$(_ci_capture 0 docker exec "${cid}" printenv SECONDARY_REGISTRATION_TOKEN_FILE)" || [ -z "${tf//$'\n'/}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0112]" "container=\"${cid}\" reason=\"no SECONDARY_REGISTRATION_TOKEN_FILE value in the ui env (raw above if any)\""
        return 2
    fi
    printf '%s\n' "${tf//$'\n'/}"
}

# What: Prove each secondary gets unique identity.
# Why: per-secondary NATS auth-callout, not shared token.
# From: Issue #1683
_ci_validate_secondary_identity() {
    local project="$1" base cid token a b au bu ap bp trc=0 tf label
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    cid="$(_ci_validate_cid "${project}" ui)" || return 2
    if [ -z "${cid}" ] || ! base="$(_ci_validate_ui_base "${project}" "${cid}")"; then
        ci_log "[CI-ERROR-VALIDATE-0045]" "reason=\"no ui container/IP for secondary-identity check\""
        return 2
    fi
    tf="$(_ci_validate_ui_token_file "${cid}")" || return 2
    # What: token as the ui resolves it: its file, else env.
    # Why: no file when the ui got a real token via env.
    # From: Issue #583 | PR #1858
    docker exec "${cid}" test -f "${tf}" || trc=$?
    case "${trc}" in
        0) token="$(_ci_capture 0 docker exec "${cid}" cat "${tf}")" || {
               ci_log "[CI-ERROR-VALIDATE-0084]" "container=\"${cid}\" file=\"${tf}\" reason=\"token file unreadable (raw above)\""; return 2; } ;;
        1) token="$(_ci_capture 0 docker exec "${cid}" printenv SECONDARY_REGISTRATION_TOKEN)" || {
               ci_log "[CI-ERROR-VALIDATE-0085]" "container=\"${cid}\" reason=\"no token file and no SECONDARY_REGISTRATION_TOKEN env (raw above)\""; return 2; } ;;
        *)
            ci_log "[CI-ERROR-VALIDATE-0066]" "container=\"${cid}\" file=\"${tf}\" rc=${trc} reason=\"token file check in the ui container failed (docker error above)\""
            return 2
            ;;
    esac
    token="${token//$'\n'/}"
    if [ -z "${token}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0046]" "reason=\"could not read SECONDARY_REGISTRATION_TOKEN from ui\""
        return 2
    fi
    if ! a="$(_ci_register_secondary "${base}" "${token}" "${label}-1")" \
        || ! b="$(_ci_register_secondary "${base}" "${token}" "${label}-2")"; then
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

# What: run every live stack probe in order, stop early.
# Why: probes target the stack; a host proxy must not.
# From: Issue #1683 | PR #1858
_ci_validate_probes() {
    local project="$1" net="$2" pin="$3" rc=0
    local -x NO_PROXY='*' no_proxy='*'
    _ci_validate_dns "${project}" || rc=$?
    [ "${rc}" -eq 0 ] && { _ci_validate_proxy "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_proxy_stream_map "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_ssl_mitm "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_ssl_dispatch_map "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_ui_nats_dns "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_dns_rollback "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_kea_rollback "${project}" "${net}" "${pin}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_secondary_identity "${project}" || rc=$?; }
    return "${rc}"
}

# What: Validate the candidate on one live prod stack.
# Why: One up, all checks, one teardown (AG-VAL-027).
# From: Issue #1683 | PR #1858
_ci_validate_stack() {
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
        ci_error "[CI-ERROR-VALIDATE-0052]" "dir=\"${LANCACHE_STATE_DIR}/cache\" project=\"${project}\" reason=\"per-run state root not creatable\"" "${up_out}"
        _ci_validate_release "${holder}"
        return 2
    fi
    if ! net_ovr="$(_ci_mktemp "${CI_TMPDIR}/ci-validate-net.XXXXXX.yml")" \
        || ! pin_ovr="$(_ci_mktemp "${CI_TMPDIR}/ci-validate-pin.XXXXXX.yml")"; then
        rm -f "${net_ovr:-}"
        _ci_validate_release "${holder}"
        return 2
    fi
    if _ci_validate_net_override "${subnet}" > "${net_ovr}" \
        && _ci_validate_pin_override "${candidate}" > "${pin_ovr}"; then
        if up_out="$(_ci_validate_up "${project}" "${net_ovr}" "${pin_ovr}" 2>&1)"; then
            _ci_validate_wait_healthy "${project}" || rc=$?
            [ "${rc}" -eq 0 ] && { _ci_validate_probes "${project}" "${net_ovr}" "${pin_ovr}" || rc=$?; }
        elif [ "$(_ci_classify_failure "${up_out}" validate-net)" = collision ]; then
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

# What: run the stack validation, print the verdict.
# Why: promote reads STACK_ACCEPTED; a failure keeps rc.
# From: Issue #1683 | PR #1858
_ci_validate_run() {
    local cand="$1" rc=0
    _ci_validate_stack "${cand}" || rc=$?
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
        ci_log "[CI-ERROR-VALIDATE-0001]" "reason=\"no stack candidate (candidate read failed)\""
        return 2
    fi
    if [ -z "${cand}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0002]" "reason=\"empty stack candidate\""
        return 2
    fi
    _ci_require_ghcr_auth || return 2
    _ci_validate_run "${cand}"
}

# What: Required-check gate over the needs results (§62).
# Why: pass/fail classification is ci.sh, not YAML (§5).
# From: Issue #1683 | PR #1858
ci_cmd_result_gate() {
    local needs="${CI_NEEDS:-}" pairs required results="" phase state
    local -A result=()
    if [ -z "${needs}" ]; then
        ci_log "[CI-ERROR-CORE-0101]" "reason=\"CI_NEEDS empty\""
        return 2
    fi
    pairs="$(_ci_run "[CI-ERROR-CORE-0133]" "reason=\"CI_NEEDS is not a needs object\"" \
        jq -r 'to_entries[] | "\(.key) \(.value.result)"' <<< "${needs}")" || return 2
    required="$(_ci_block_entry_list ci_result_gate "" required)" || return 2
    if [ -z "${required}" ]; then
        ci_log "[CI-ERROR-CORE-0134]" "manifest=\"${CI_MANIFEST}\" reason=\"no SOT ci_result_gate.required phase\""
        return 2
    fi
    while read -r phase state; do
        [ -n "${phase}" ] || continue
        result["${phase}"]="${state}"
        results+="${results:+ }${phase}:${state}"
    done <<< "${pairs}"
    # What: every required phase reports and succeeded.
    # Why: a renamed or skipped plan would hide a red run.
    # From: Issue #1683 | PR #1858
    while read -r phase; do
        if [ -z "${result[${phase}]+set}" ]; then
            ci_log "[CI-ERROR-CORE-0132]" "phase=\"${phase}\" results=\"${results}\" reason=\"required phase missing from needs\""
            return 1
        fi
        if [ "${result[${phase}]}" != success ]; then
            ci_log "[CI-ERROR-CORE-0100]" "phase=\"${phase}\" result=\"${result[${phase}]}\" results=\"${results}\" reason=\"required phase did not succeed\""
            return 1
        fi
        unset "result[${phase}]"
    done <<< "${required}"
    # What: any other phase: success or skipped passes.
    # Why: on a NOOP or a PR those phases skip by design.
    # From: Issue #1683 | PR #1858
    while read -r phase state; do
        [ -n "${phase}" ] && [ -n "${result[${phase}]+set}" ] || continue
        case "${state}" in
            success|skipped) ;;
            *)
                ci_log "[CI-ERROR-CORE-0116]" "phase=\"${phase}\" result=\"${state}\" results=\"${results}\" reason=\"phase neither succeeded nor skipped\""
                return 1
                ;;
        esac
    done <<< "${pairs}"
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
    local name="$1" val="" rc=0
    val="${!name:-}"
    if [ -z "${val}" ] && [ -n "${CI_VARIABLES:-}" ]; then
        val="$(jq -er --arg n "${name}" '.[$n] // ""' <<< "${CI_VARIABLES}" 2>&1)" || rc=$?
        if [ "${rc}" -eq 127 ]; then
            ci_error "[CI-ERROR-VARIABLES-0023]" "name=\"${name}\" reason=\"jq not found; CI_VARIABLES cannot be read\"" "${val}"$'\n'"PATH=${PATH}"
            return 2
        fi
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-VARIABLES-0015]" "name=\"${name}\" reason=\"CI_VARIABLES is not a json object\"" "${val}"
            return 2
        fi
    fi
    [ -n "${val}" ] || val="$(_ci_block_entry_field ci_variables "" "${name}")" || return 2
    [ -n "${val}" ] || return 1
    printf '%s\n' "${val}"
}

# What: The build-time secret mount ids (one source).
# Why: set-runtime, mounts and the guard share one list.
# From: Issue #1683
_ci_runtime_secret_ids() {
    printf '%s\n' \
        project_selfhosted_proxy_ca \
        sccache_policy sccache_redis_url ccache_redis_url sccache_gha \
        sccache_dist_config distcc_potential_hosts
}

# What: Forbidden env-key prefixes for the bake guard.
# Why: One source the guard and set-runtime both use.
# From: Issue #1683
_ci_bake_env_patterns() {
    printf '%s\n' \
        HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
        GOPROXY SCCACHE_ CCACHE_ DISTCC_ ACTIONS_
}

# What: env lines + count of the proxy CA in the bundle.
# Why: the bake guard inspects the real built image.
# From: Issue #1781 | PR #1858
_ci_bake_inspect() {
    local image="$1" envs bundle marker line n=0
    envs="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>&1)" || { printf '%s\n' "${envs}"; return 2; }
    while IFS= read -r line; do
        [ -n "${line}" ] && printf 'env %s\n' "${line}"
    done <<< "${envs}"
    marker="$(sed -n '2p' <<< "${PROJECT_SELFHOSTED_PROXY_CA:-}")"
    if [ -n "${marker}" ]; then
        bundle="$(docker run --rm --network none --entrypoint cat "${image}" "${CI_SYSTEM_CA_PATH}" 2>&1)" || { printf '%s\n' "${bundle}"; return 2; }
        n="$(_ci_capture 1 grep -cF -- "${marker}" <<< "${bundle}")" || return 2
    fi
    printf 'extra_ca %s\n' "${n:-0}"
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
    if raw="$(_ci_bake_inspect "${image}" 2>&1)"; then status=0; else status=$?; fi
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
    local path="$1" val="$2" out
    # What: raw = the redirect error only, never the value.
    # Why: a secret must not reach the log, its path must.
    # From: Issue #1683 | PR #1858
    if ! out="$( ( umask 077; printf '%s' "${val}" > "${path}" ) 2>&1 )"; then
        ci_error "[CI-ERROR-VARIABLES-0018]" "path=\"${path}\" bytes=${#val} reason=\"build secret not written\"" "${out}"
        return 2
    fi
}

# What: Assemble the sccache dist config TOML file.
# Why: One place builds it; token stays out of logs.
# From: Issue #1683
_ci_write_dist_config() {
    local path="$1"
    ( umask 077
      {
        printf '[dist]\n'
        printf 'scheduler_url = "%s"\n' "$(_ci_toml_escape "$3")"
        printf 'toolchains = []\n'
        printf 'toolchain_cache_size = %s\n' "$2"
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
    _ci_write_secret "$1/$2" "$3" || return "$?"
    _ci_emit_secret_ref "$1" "$2"
}

# What: build-time secret files + --secret args per kind.
# Why: cache secrets for rust only; the proxy CA for all.
# From: Issue #1683 | PR #1858
_ci_set_runtime() {
    local kind="${1:-rust}" dir policy="" mode=off chain="" sccache_enabled=0
    dir="$(_ci_runtime_secret_dir)"
    if [ "${kind}" = rust ]; then
        policy="$(_ci_sccache_policy)" || return 2
        read -r mode chain <<< "${policy}"
        [ "${mode}" = off ] || sccache_enabled=1
    fi
    # What: dist scheduler, distcc hosts via CI_VARIABLES.
    # Why: repo variables reach ci.sh only as that json.
    # From: Issue #1683 | PR #1858
    local sched="" hosts="" vrc=0
    if [ "${kind}" = rust ]; then
        sched="$(_ci_variable_value SCCACHE_DIST_SCHEDULER_URL)" || vrc=$?
        [ "${vrc}" -le 1 ] || return 2
        vrc=0
        hosts="$(_ci_variable_value DISTCC_POTENTIAL_HOSTS)" || vrc=$?
        [ "${vrc}" -le 1 ] || return 2
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -n "${sched}" ] && [ -z "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0011]" "reason=\"scheduler set without auth token\""
        return 2
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -z "${sched}" ] && [ -n "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0017]" "reason=\"auth token set without scheduler\""
        return 2
    fi
    # What: check every input before any secret is written.
    # Why: a failed check must leave no partial secret dir.
    # From: Issue #1683 | PR #1858
    if [ "${kind}" = rust ] && [ -n "${hosts}" ]; then
        case "${hosts}" in
            *,cpp*) : ;;
            *)
                ci_log "[CI-ERROR-VARIABLES-0013]" "reason=\"DISTCC_POTENTIAL_HOSTS needs a pump host (,cpp)\""
                return 2
                ;;
        esac
    fi
    local out tcs=""
    if [ "${sccache_enabled}" = "1" ] && [ -n "${sched}" ]; then
        tcs="$(_ci_variable CI_SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE)" || return 2
        case "${tcs}" in
            ''|*[!0-9]*)
                ci_log "[CI-ERROR-VARIABLES-0021]" "value=\"${tcs}\" reason=\"CI_SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE must be a byte count\""
                return 2
                ;;
        esac
    fi
    if ! out="$( ( umask 077; mkdir -p "${dir}" ) 2>&1 )"; then
        ci_error "[CI-ERROR-VARIABLES-0019]" "dir=\"${dir}\" reason=\"runtime secret dir not created\"" "${out}"
        return 2
    fi
    [ -z "${policy}" ] || _ci_emit_secret "${dir}" sccache_policy "${policy}" || return "$?"
    if [[ ",${chain}," == *,redis,* ]]; then
        _ci_emit_secret "${dir}" sccache_redis_url "${SCCACHE_REDIS_URL:-}" || return "$?"
        _ci_emit_secret "${dir}" ccache_redis_url "${SCCACHE_REDIS_URL:-}" || return "$?"
    fi
    if [[ ",${chain}," == *,gha,* ]]; then
        _ci_emit_secret "${dir}" sccache_gha "ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL}"$'\n'"ACTIONS_RUNTIME_TOKEN=${ACTIONS_RUNTIME_TOKEN}" || return "$?"
    fi
    if [ "${sccache_enabled}" = "1" ] && [ -n "${sched}" ]; then
        if ! out="$(_ci_write_dist_config "${dir}/sccache_dist_config" "${tcs}" "${sched}" 2>&1)"; then
            ci_error "[CI-ERROR-VARIABLES-0020]" "path=\"${dir}/sccache_dist_config\" reason=\"sccache dist config not written\"" "${out}"
            return 2
        fi
        _ci_emit_secret_ref "${dir}" sccache_dist_config || return "$?"
    fi
    [ "${kind}" != rust ] || [ -z "${hosts}" ] \
        || _ci_emit_secret "${dir}" distcc_potential_hosts "${hosts}" || return "$?"
    if [ -n "${PROJECT_SELFHOSTED_PROXY_CA:-}" ]; then
        _ci_emit_secret "${dir}" project_selfhosted_proxy_ca "${PROJECT_SELFHOSTED_PROXY_CA:-}" || return "$?"
    fi
}

# What: Remove all runtime secret files after the build.
# Why: Secrets must not linger on the runner.
# From: Issue #1683
_ci_clear_runtime() {
    local dir out
    dir="$(_ci_runtime_secret_dir)"
    if ! out="$(rm -rf -- "${dir}" 2>&1)"; then
        ci_error "[CI-ERROR-VARIABLES-0022]" "dir=\"${dir}\" reason=\"runtime secret dir not removed\"" "${out}"
        return 2
    fi
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
    pkgs="$(_ci_apk_keys "${tool}")" || return 2
    [ -z "${pkgs}" ] || out="${out}${prefix}APK_KEYS=${pkgs}"$'\n'
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
    ext="$(_ci_block_entry_field services "${service}" external_image)" || return 2
    if [ -n "${ext}" ]; then
        ext_argname="${ext^^}_IMAGE"
        val="$(_ci_block_entry_field base_images "" "${ext}")" || return 2
        if [ -z "${val}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0007]" "arg=\"${ext_argname}\" service=\"${service}\" key=\"base_images.${ext}\" reason=\"missing central external image; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}${ext_argname}=${val}"$'\n'
    fi
    # What: Rust builders use build-tools image ref
    # Why: SOT owns ref; Dockerfile keeps none
    # From: Issue #1683
    local own_type
    own_type="$(_ci_block_entry_field services "${service}" build_type)" || return 2
    if [ "${own_type}" = rust ]; then
        # What: identity omits the registry-resolved ref.
        # Why: toolchain_digest keys it; no network in id.
        # From: Issue #1683 | PR #1858
        if [ "${with_toolchain}" = yes ]; then
            val="$(_ci_build_tools_resolve_image)" || return 2
            [ -n "${val}" ] || { ci_log "[CI-ERROR-BUILDARGS-0009]" "arg=\"BUILD_TOOLS_IMAGE\" service=\"${service}\" reason=\"empty resolved build-tools image; FAIL CLOSED\""; return 2; }
            out="${out}${prefix}BUILD_TOOLS_IMAGE=${val}"$'\n'
        fi
        # What: emit the SOT workspace crate for rust-build.
        # Why: one crate owner; the Dockerfile names none.
        # From: Issue #1683 | PR #1858
        val="$(_ci_block_entry_field services "${service}" crate)" || return 2
        [ -n "${val}" ] || { ci_log "[CI-ERROR-BUILDARGS-0014]" "arg=\"RUST_CRATE\" service=\"${service}\" reason=\"no crate in SOT; FAIL CLOSED\""; return 2; }
        out="${out}${prefix}RUST_CRATE=${val}"$'\n'
        # What: emit the platform's SOT rust target triple.
        # Why: apk Rust ships only its host std, no rustup.
        # From: Issue #1683 | PR #1858
        if [ -n "${platform}" ]; then
            local triple
            triple="$(_ci_platform_field "${platform}" rust_target "[CI-ERROR-BUILDARGS-0010]" "service=\"${service}\" reason=\"no rust target for platform; FAIL CLOSED\"")" || return 2
            out="${out}${prefix}MUSL_TARGET=${triple}"$'\n'
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
    apk_pkgs="$(_ci_service_packages "${service}")" || return 2
    apk_pkgs="$(tr '\n' ' ' <<<"${apk_pkgs}")"
    apk_pkgs="${apk_pkgs% }"
    if [ -n "${apk_pkgs}" ]; then
        out="${out}${prefix}APK_PACKAGES=${apk_pkgs}"$'\n'
    fi
    # What: the service's tagged repos and repo keys.
    # Why: apk-setup adds them; the Dockerfile owns none.
    # From: Issue #1683 | PR #1858
    local tagged keys
    tagged="$(_ci_apk_repositories "${service}")" || return 2
    keys="$(_ci_apk_keys "${service}")" || return 2
    [ -z "${tagged}" ] || out="${out}${prefix}APK_TAGGED_REPOS=${tagged}"$'\n'
    [ -z "${keys}" ] || out="${out}${prefix}APK_KEYS=${keys}"$'\n'
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
    local out tag
    out="$(_ci_target_list "$1" apk_repositories)" || return 2
    # What: @ALPINE_BRANCH@ becomes vX.Y of the alpine pin.
    # Why: the SOT pin owns the version; repos only follow.
    # From: Issue #1683 | PR #1858
    case "${out}" in
        *@ALPINE_BRANCH@*)
            tag="$(_ci_alpine_image "[CI-ERROR-BUILDARGS-0019]" "target=\"$1\" key=\"base_images.alpine\" reason=\"no alpine pin; no repo branch\"")" || return 2
            tag="${tag%@*}"; tag="${tag##*:}"
            if [[ ! "${tag}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                ci_log "[CI-ERROR-BUILDARGS-0016]" "tag=\"${tag}\" reason=\"alpine pin tag is not major.minor; no repo branch\""
                return 2
            fi
            out="${out//@ALPINE_BRANCH@/v${tag}}"
            ;;
    esac
    printf '%s' "${out//$'\n'/ }"
}

# What: a target's SOT apk_keys (url=sha256), space-joined.
# Why: one key list for apk-setup and the apk resolver.
# From: Issue #1683 | PR #1858
_ci_apk_keys() {
    local out
    out="$(_ci_target_list "$1" apk_keys)" || return 2
    printf '%s' "${out//$'\n'/ }"
}

# What: the toolchain target's apk list; empty fails.
# Why: same list rule as every image; input check needs it.
# From: Issue #1683 | PR #1858
_ci_build_tools_packages() {
    local pkgs tool
    tool="$(_ci_toolchain_target)" || return 2
    pkgs="$(_ci_service_packages "${tool}")" || return 2
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
    items="$(_ci_block_entry_list build_toolchain "${tool}" "${field}")" || return 2
    if [ "${field}" = smoke_runs ]; then
        items="$(_ci_image_base_plus smoke "${items}")" || return 2
    fi
    if [ -z "${items}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0013]" "field=\"${field}\" reason=\"empty SOT smoke list; FAIL CLOSED\""
        return 2
    fi
    # What: smoke_tools also checks every compiler driver.
    # Why: the compiler list is their one owner.
    # From: Issue #1683 | PR #1858
    if [ "${field}" = smoke_tools ]; then
        local pairs p
        pairs="$(_ci_build_tools_compilers)" || return 2
        while IFS= read -r p; do items+=$'\n'"${p#*=}"; done <<< "${pairs}"
    fi
    printf '%s\n' "${items}"
}

# What: Print the compiler VAR=driver pairs, one per line.
# Why: env in the rust builder, else the SOT default.
# From: Issue #1683 | PR #1858
_ci_build_tools_compilers() {
    local items p
    items="$(_ci_variable CI_TOOLCHAIN_COMPILERS)" || return 2
    items="$(tr -s '[:space:]' '\n' <<< "${items}")"
    while IFS= read -r p; do
        if [[ ! "${p}" =~ ^[A-Z][A-Z0-9_]*=[^=/[:space:]]+$ ]]; then
            ci_error "[CI-ERROR-BUILDTOOLS-0025]" "entry=\"${p}\" reason=\"compiler entry is not VAR=driver\"" "${items}"
            return 2
        fi
    done <<< "${items}"
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
        apk="$(_ci_platform_field "${platform}" apk "[CI-ERROR-BUILDTOOLS-0007]" "reason=\"no apk arch mapping; FAIL CLOSED\"")" || return 2
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
    local base="$1" arch="$2" packages="$3" repos="${4:-}" keys="${5:-}" raw n kv kdir b64 kenv=""
    local -a penv=()
    local produced produced_rc=0
    produced="$(_ci_proxy_names)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r n; do [ -n "${n}" ] && penv+=(-e "${n}"); done <<<"${produced}"
    if [ -n "${CI_APK_RESOLVE_CMD:-}" ]; then
        "${CI_APK_RESOLVE_CMD}" "${base}" "${arch}" "${packages}"
        return "$?"
    fi
    # What: SOT repo keys fetched here, passed in as base64.
    # Why: the tagged repo needs its key; one fetch owner.
    # From: Issue #1683 | PR #1858
    if [ -n "${keys}" ]; then
        kdir="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
        for kv in ${keys}; do
            n="${kv%=*}"; n="${n##*/}"
            _ci_fetch_verified "${kv%=*}" "${kv##*=}" "${kdir}/${n}" || { rm -rf "${kdir}"; return 2; }
            if ! b64="$(base64 -w0 "${kdir}/${n}" 2>&1)"; then
                ci_error "[CI-ERROR-BUILDTOOLS-0022]" "key=\"${n}\" reason=\"repo key not encodable for the resolver\"" "${b64}"
                rm -rf "${kdir}"
                return 2
            fi
            kenv="${kenv:+${kenv} }${n}=${b64}"
        done
        rm -rf "${kdir}"
    fi
    # What: per-arch clean root with the build's repos.
    # Why: a foreign arch needs its own db and keys.
    # From: Issue #1683 | PR #1858
    if ! raw="$(_ci_retry apk docker run --rm "${penv[@]}" -e ARCH="${arch}" -e PKGS="${packages}" \
            -e REPOS="${repos}" -e KEYS="${kenv}" "${base}" sh -c '
        set -e
        r=/var/tmp/apk-root; k="/usr/share/apk/keys/${ARCH}"
        mkdir -p "${r}/etc/apk"
        for kv in ${KEYS}; do printf "%s" "${kv#*=}" | base64 -d > "${k}/${kv%%=*}"; done
        sed "s|^https://|http://|" /etc/apk/repositories > "${r}/etc/apk/repositories"
        for kv in ${REPOS}; do echo "@${kv%%=*} ${kv#*=}" >> "${r}/etc/apk/repositories"; done
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" --initdb add
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" update
        apk --root "${r}" --arch "${ARCH}" --keys-dir "${k}" add --simulate ${PKGS}' 2>&1)"; then
        ci_error "[CI-ERROR-BUILDTOOLS-0020]" "arch=\"${arch}\" reason=\"apk resolve failed\"" "${raw}"
        return 2
    fi
    printf '%s\n' "${raw}" | sed -n 's/^.*Installing \([^ ]*\) (\([^)]*\)).*/\1-\2/p' \
        | LC_ALL=C sort | tr '\n' ' '
}

# What: Resolve every arch's apk state, then sign it.
# Why: the whole signature is computed here, not in YAML.
# From: Issue #1683
_ci_build_tools_resolve_signature() {
    local base packages arches arch av versions="" tool repos keys
    base="$(_ci_alpine_image "[CI-ERROR-BUILDTOOLS-0009]" "key=\"base_images.alpine\" reason=\"no alpine base for the build-tools apk resolve; FAIL CLOSED\"")" || return 2
    packages="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    arches="$(_ci_build_tools_arches)" || return 2
    tool="$(_ci_toolchain_target)" || return 2
    repos="$(_ci_apk_repositories "${tool}")" || return 2
    keys="$(_ci_apk_keys "${tool}")" || return 2
    for arch in ${arches}; do
        av="$(_ci_apk_resolve "${base}" "${arch}" "${packages}" "${repos}" "${keys}")" || return 2
        if [ -z "${av//[[:space:]]/}" ]; then
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
    local obj='{}' kv out
    for kv in "$@"; do
        if ! obj="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}' <<< "${obj}" 2>&1)"; then
            ci_error "[CI-ERROR-PLAN-0003]" "entry=\"${kv}\" reason=\"matrix entry not encodable\"" "${obj}"
            return 2
        fi
    done
    if ! out="$(jq -c --argjson o "${obj}" '. + [$o]' <<< "${arr}" 2>&1)"; then
        ci_error "[CI-ERROR-PLAN-0004]" "entry=\"${obj}\" reason=\"matrix not appendable\"" "${out}"$'\n'"matrix: ${arr}"
        return 2
    fi
    printf '%s' "${out}"
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
    [ -n "${channel}" ] || channel="$(_ci_block_entry_field release "" default_channel)" || return 2
    if [ -z "${channel}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0021]" "reason=\"no SOT release.default_channel; FAIL CLOSED\""
        return 2
    fi
    image="$(_ci_build_tools_image)" || return 2
    _ci_require_ghcr_auth || return "$?"
    if ! digest="$(_ci_registry_digest "${image}:${channel}")"; then
        ci_log "[CI-ERROR-BUILDTOOLS-0018]" "channel=\"${channel}\" reason=\"no published build-tools digest; FAIL CLOSED\""
        return 2
    fi
    image="${image}@${digest}"
    _ci_step_output "[CI-ERROR-BUILDTOOLS-0023]" image "${image}" || return 2
    printf '%s\n' "${image}"
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
    local produced produced_rc=0
    produced="$(awk -v n="${name}" '
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
            print "|" rest
        }
    ' "${path}")" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r raw; do
        [ -n "${raw}" ] || continue
        hits+=("${raw#|}")
    done <<<"${produced}"
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
    local deps dep target keys df
    deps="$(_ci_block_keys external_versions)" || return 2
    for dep in ${deps}; do
        target="$(_ci_block_entry_field external_versions "${dep}" consumer)" || return 2
        [ -n "${target}" ] || continue
        keys="$(_ci_block_entry_list external_versions "${dep}" build_args)" || return 2
        if [ -z "${keys}" ]; then
            ci_log "[CI-ERROR-VERSION-0010]" "dep=\"${dep}\" reason=\"consumer without SOT build_args\""
            return 2
        fi
        df="$(_ci_service_path "${target}" Dockerfile "")" || return 2
        printf '%s|%s|%s\n' "${dep}" "${df}" "${keys//$'\n'/ }"
    done
}

# What: One pin's sha256 for an apk arch, fail-closed.
# Why: a missing or garbled checksum must never pass.
# From: Issue #1683 | PR #1858
_ci_pin_sha() {
    local dep="$1" apk="$2" val
    val="$(_ci_block_entry_field external_versions "${dep}" "sha256_${apk}")" || return 2
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
        val="$(_ci_block_entry_field external_versions "${dep}" "${key}")" || return 2
        if [ -z "${val}" ]; then
            ci_log "[CI-ERROR-BUILDARGS-0017]" "key=\"external_versions.${dep}.${key}\" platform=\"${platform}\" reason=\"missing central pin; FAIL CLOSED\""
            return 2
        fi
        out="${out}${prefix}${up}_${key^^}=${val}"$'\n'
    done
    if [ -n "${platform}" ]; then
        apk="$(_ci_platform_field "${platform}" apk "[CI-ERROR-BUILDARGS-0006]" "dep=\"${dep}\" reason=\"no apk arch mapping; FAIL CLOSED\"")" || return 2
        val="$(_ci_pin_sha "${dep}" "${apk}")" || return 2
        out="${out}${prefix}${up}_ARCH=${apk}"$'\n'"${prefix}${up}_SHA256=${val}"$'\n'
    else
        local plats
        plats="$(_ci_build_matrix_platforms)" || return 2
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            apk="$(_ci_platform_field "${p}" apk "[CI-ERROR-BUILDARGS-0018]" "dep=\"${dep}\" reason=\"no apk arch mapping for a build_matrix platform; FAIL CLOSED\"")" || return 2
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
    local target="$1" platform="$2" prefix="$3" want dep df keys consumers
    want="$(_ci_service_path "${target}" Dockerfile "")" || return 2
    consumers="$(_ci_version_consumers)" || return 2
    while IFS='|' read -r dep df keys; do
        [ -n "${dep}" ] && [ "${df}" = "${want}" ] || continue
        _ci_pin_args "${dep}" "${keys}" "${platform}" "${prefix}" || return 2
    done <<< "${consumers}"
}

# What: SOT alpine base ref; empty logs caller id + text.
# Why: one pin for every alpine consumer; each own id.
# From: Issue #1683 | PR #1858
_ci_alpine_image() {
    local id="$1" ctx="$2" val
    val="$(_ci_block_entry_field base_images "" alpine)" || return 2
    if [ -z "${val}" ]; then
        ci_log "${id}" "${ctx}"
        return 2
    fi
    printf '%s\n' "${val}"
}

# What: The SOT alpine base as ALPINE_IMAGE, fail-closed.
# Why: every target's final stage pins this one owner.
# From: Issue #1683 | PR #1858
_ci_alpine_build_arg() {
    local prefix="$1" val
    val="$(_ci_alpine_image "[CI-ERROR-BUILDARGS-0003]" "arg=\"ALPINE_IMAGE\" key=\"base_images.alpine\" reason=\"missing central base image; FAIL CLOSED\"")" || return 2
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


# What: one SOT release scalar; empty is an error.
# Why: one reader for version, license, verify and sync.
# From: Issue #1683 | PR #1858
_ci_release_value() {
    local want
    want="$(_ci_block_entry_field release "" "$1")" || return 2
    if [ -z "${want}" ]; then
        ci_log "[CI-ERROR-VERSION-0020]" "key=\"release.$1\" reason=\"no SOT value\""
        return 2
    fi
    printf '%s\n' "${want}"
}

# What: one string key of a [workspace.package] table.
# Why: verify reads version and license the same way.
# From: Issue #1683 | PR #1858
_ci_cargo_ws_value() {
    awk -v k="$2" '/^\[workspace\.package\]/ { on = 1; next } /^\[/ { on = 0 }
        on && $1 == k { v = $0; sub(/^[^=]*= *"/, "", v); sub(/".*$/, "", v); print v; exit }' "$1"
}

# What: package names of a workspace's own members.
# Why: their Cargo.lock entries carry release.version.
# From: Issue #1683 | PR #1858
_ci_cargo_member_names() {
    local m members
    members="$(_ci_cargo_members "$1")" || return 2
    while IFS= read -r m; do
        [ -n "${m}" ] || continue
        awk '/^\[package\]/ { on = 1; next } /^\[/ { on = 0 }
            on && /^name *=/ { v = $0; sub(/^name *= *"/, "", v); sub(/".*$/, "", v); print v; exit }' "${1%/*}/${m}/Cargo.toml" || return 2
    done <<< "${members}"
}

# What: write release.version into its derived copies.
# Why: copies are synced on demand, idempotent, not by hand.
# From: Issue #1683 | PR #1858
_ci_version_release_sync() {
    local want lic lock cargo vfile names f tmp out wrote=0
    want="$(_ci_release_value version)" || return 2
    lic="$(_ci_release_value license)" || return 2
    lock="$(_ci_repo_path CI_CARGO_LOCK)" || return 2
    cargo="${lock%/*}/Cargo.toml"
    vfile="$(_ci_repo_path CI_VERSION_FILE)" || return 2
    names="$(_ci_cargo_member_names "${cargo}")" || return 2
    for f in "${cargo}" "${lock}" "${vfile}"; do
        tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-vsync.XXXXXX")" || return 2
        case "${f}" in
            "${cargo}") out="$(awk -v v="${want}" -v l="${lic}" '/^\[workspace\.package\]/ { on = 1; print; next } /^\[/ { on = 0 }
                on && $1 == "version" { print "version = \"" v "\""; next }
                on && $1 == "license" { print "license = \"" l "\""; next } { print }' "${f}" 2>&1 > "${tmp}")" ;;
            "${lock}") out="$(awk -v v="${want}" -v names="${names//$'\n'/ }" 'BEGIN { split(names, a, " "); for (i in a) own[a[i]] = 1 }
                /^name = / { x = $0; sub(/^name = "/, "", x); sub(/"$/, "", x); hit = (x in own) }
                hit && /^version = / { print "version = \"" v "\""; hit = 0; next } { print }' "${f}" 2>&1 > "${tmp}")" ;;
            *) out="$(printf '%s\n' "${want}" 2>&1 > "${tmp}")" ;;
        esac || { ci_error "[CI-ERROR-VERSION-0026]" "path=\"${f}\" reason=\"derived copy not rendered\"" "${out}"; rm -f "${tmp}"; return 2; }
        if ! out="$(_ci_copy_if_changed "${tmp}" "${f}")"; then
            ci_error "[CI-ERROR-VERSION-0027]" "path=\"${f}\" reason=\"derived copy not written\"" "${out}"
            rm -f "${tmp}"
            return 2
        fi
        [ "${out}" = unchanged ] || wrote=$((wrote + 1))
        rm -f "${tmp}"
    done
    printf 'sync=release-version version=%s changed=%s\n' "${want}" "${wrote}"
}

# What: Cargo, members and VERSION equal release.version.
# Why: one release version owner; consumers must not drift.
# From: Issue #1683 | PR #1858
_ci_version_release() {
    local want lic got lock cargo vfile members m n k rc=0
    want="$(_ci_release_value version)" || return 2
    lic="$(_ci_release_value license)" || return 2
    lock="$(_ci_repo_path CI_CARGO_LOCK)" || return 2
    cargo="${lock%/*}/Cargo.toml"
    got="$(_ci_cargo_ws_value "${cargo}" version)"
    if [ "${got}" != "${want}" ]; then
        ci_log "[CI-ERROR-VERSION-0021]" "path=\"${cargo}\" got=\"${got}\" want=\"${want}\" reason=\"workspace.package.version is not SOT release.version\""
        rc=1
    fi
    got="$(_ci_cargo_ws_value "${cargo}" license)"
    if [ "${got}" != "${lic}" ]; then
        ci_log "[CI-ERROR-VERSION-0028]" "path=\"${cargo}\" got=\"${got}\" want=\"${lic}\" reason=\"workspace.package.license is not SOT release.license\""
        rc=1
    fi
    members="$(_ci_cargo_members "${cargo}")" || return 2
    while IFS= read -r m; do
        [ -n "${m}" ] || continue
        for k in version edition license; do
            if ! grep -Eq "^${k}\.workspace *= *true$" "${lock%/*}/${m}/Cargo.toml"; then
                ci_log "[CI-ERROR-VERSION-0022]" "member=\"${m}\" key=\"${k}\" reason=\"member owns its ${k}; use ${k}.workspace = true\""
                rc=1
            fi
        done
    done <<< "${members}"
    m="$(_ci_cargo_member_names "${cargo}")" || return 2
    while IFS= read -r n; do
        got="$(awk -v n="${n}" '$0 == "name = \"" n "\"" { on = 1; next }
            on && /^version = / { v = $0; sub(/^version = "/, "", v); sub(/"$/, "", v); print v; exit }' "${lock}")"
        if [ "${got}" != "${want}" ]; then
            ci_log "[CI-ERROR-VERSION-0025]" "path=\"${lock}\" package=\"${n}\" got=\"${got}\" want=\"${want}\" reason=\"lock entry is not SOT release.version\""
            rc=1
        fi
    done <<< "${m}"
    vfile="$(_ci_repo_path CI_VERSION_FILE)" || return 2
    if ! got="$(cat "${vfile}" 2>&1)"; then
        ci_error "[CI-ERROR-VERSION-0023]" "path=\"${vfile}\" reason=\"version file unreadable\"" "${got}"
        return 2
    fi
    if [ "${got}" != "${want}" ]; then
        ci_log "[CI-ERROR-VERSION-0024]" "path=\"${vfile}\" got=\"${got}\" want=\"${want}\" reason=\"version file is not SOT release.version\""
        rc=1
    fi
    [ "${rc}" -eq 0 ] && printf 'release-version=%s consumers=clean\n' "${want}"
    return "${rc}"
}

# What: version verify: default, read-only, fails on drift.
# Why: The one CI gate for SOT-vs-repo version drift.
# From: Issue #1683 | PR #1858
_ci_version_verify() {
    local rc=0 r=0
    _ci_version_walk _ci_version_diff || rc=$?
    _ci_version_release || r=$?
    [ "${r}" -gt "${rc}" ] && rc="${r}"
    return "${rc}"
}

# What: sync: pins checked as verify does; copies written.
# Why: pins are SOT-driven bare ARGs; only copies write.
# From: Issue #1683 | PR #1858
_ci_version_sync() {
    _ci_version_walk _ci_version_diff || return "$?"
    _ci_version_release_sync
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
    # What: index a present SOT once for this command.
    # Why: readers then look fields up instead of rereading.
    # From: Issue #1683 | PR #1858
    [ ! -f "${CI_MANIFEST}" ] || _ci_sot_load || return 2
    "${fn}" "$@"
}

# =========================================================
# SOURCE-HYGIENE CHECKS
# =========================================================

# What: fail a captured loop producer rc above max.
# Why: wait on a < <() pid races bash's reaping (127).
# From: Issue #1683 | PR #1858
_ci_producer_ok() {
    local rc="$1" max="${2:-0}"
    [ "${rc}" -le "${max}" ] && return 0
    ci_log "[CI-ERROR-CORE-0010]" "rc=${rc} reason=\"loop producer failed; refusing a partial result\""
    return 2
}

# What: git ls-files in a root; coded error with site+raw.
# Why: an empty list from a failed ls would scan as clean.
# From: Issue #1683 | PR #1858
_ci_ls_files() {
    local site="$1" root="$2"
    shift 2
    _ci_run "[CI-ERROR-CHECK-0071]" "site=\"${site}\" root=\"${root}\" pathspec=\"$*\" reason=\"git ls-files failed; refusing an empty scan\"" \
        git -C "${root}" ls-files -- "$@"
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
        _ci_scan_raw="$(_ci_ls_files scan-files . "$@")" || return 2
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

# What: Dockerfile pathspecs of every Dockerfile scan.
# Why: one owner for the file set the checks read.
# From: Issue #1683 | PR #1858
CI_DOCKERFILE_SPECS=('Dockerfile' '*/Dockerfile')

# What: out[]: .sh/.bash/.bats files or a sh/bash shebang.
# Why: every shell check reads one set (AG-VAL-032).
# From: Issue #1683 | PR #1858
_ci_shell_sources() {
    local -n _ci_ss_out="$1"
    local -a _ci_ss_all=() _ci_ss_dock=()
    local _ci_ss_f _ci_ss_l1 _ci_ss_re='^#![[:space:]]*/([^[:space:]]*/)?(env[[:space:]]+)?(ba)?sh([[:space:]]|$)'
    _ci_scan_files _ci_ss_all "$2" || return 2
    _ci_ss_out=()
    for _ci_ss_f in "${_ci_ss_all[@]}"; do
        case "${_ci_ss_f##*/}" in
            *.sh|*.bash|*.bats) _ci_ss_out+=("${_ci_ss_f}"); continue ;;
            *.*|Dockerfile) continue ;;
        esac
        _ci_ss_l1="$(_ci_run "[CI-ERROR-CHECK-0164]" "file=\"${_ci_ss_f}\" reason=\"first line unreadable\"" head -n 1 -- "${_ci_ss_f}")" || return 2
        if [[ "${_ci_ss_l1}" =~ ${_ci_ss_re} ]]; then
            _ci_ss_out+=("${_ci_ss_f}")
        fi
    done
    # What: arg dockerfiles adds Dockerfiles (RUN shell).
    # Why: overrides skip pathspecs; the basename decides.
    # From: Issue #1683 | PR #1858
    [ "${3:-}" = dockerfiles ] || return 0
    _ci_scan_files _ci_ss_dock "$2" "${CI_DOCKERFILE_SPECS[@]}" || return 2
    for _ci_ss_f in "${_ci_ss_dock[@]}"; do
        if [ "${_ci_ss_f##*/}" = Dockerfile ]; then
            _ci_ss_out+=("${_ci_ss_f}")
        fi
    done
}

# What: shfmt's JSON syntax tree of one shell source.
# Why: shell checks read the parser's tree, not raw text.
# From: Issue #1683 | PR #1858
_ci_shell_ast() {
    local f="$1" src lang=bash
    case "${f##*/}" in
        Dockerfile)
            src="$(_ci_run "[CI-ERROR-CHECK-0165]" "file=\"${f}\" reason=\"Dockerfile lines unreadable\"" _ci_dockerfile_logical_lines "${f}")" || return 2
            # What: RUN shell text; SHELL pipefail -> set.
            # Why: exec-form RUN is JSON; SHELL sets -o.
            # From: Issue #1683 | PR #1858
            src="$(_ci_run "[CI-ERROR-CHECK-0163]" "file=\"${f}\" reason=\"RUN shell not extracted\"" awk '
                { t = $0; sub(/^[[:space:]]+/, "", t) }
                toupper(substr(t, 1, 6)) == "SHELL " && t ~ /pipefail/ { print "set -o pipefail"; next }
                toupper(substr(t, 1, 4)) != "RUN " { next }
                {
                    t = substr(t, 5)
                    while (match(t, /^[[:space:]]*--[A-Za-z-]+(=[^[:space:]]*)?[[:space:]]+/)) t = substr(t, RLENGTH + 1)
                    sub(/^[[:space:]]+/, "", t)
                    if (substr(t, 1, 1) != "[") print t
                }' <<< "${src}")" || return 2 ;;
        *)
            [[ "${f##*/}" != *.bats ]] || lang=bats
            src="$(_ci_run "[CI-ERROR-CHECK-0166]" "file=\"${f}\" reason=\"source unreadable\"" cat -- "${f}")" || return 2 ;;
    esac
    _ci_run -s "[CI-ERROR-CHECK-0162]" "file=\"${f}\" lang=\"${lang}\" reason=\"shfmt cannot parse the source\"" \
        shfmt -ln "${lang}" --to-json <<< "${src}"
}

# What: jq over a shfmt tree: status-read and pipe findings.
# Why: one pass per file feeds both shell guards.
# From: Issue #1683 | PR #1858
_CI_JQ_SHELL_FINDINGS='
    def reads:
        if type == "array" then .[] | reads
        elif type != "object" then empty
        elif .Type == "ParamExp" and .Param.Value == "?" then .Pos.Line
        elif .Type == "BinaryCmd" then .X | reads
        elif .Type == "IfClause" or .Type == "WhileClause" then (.Cond[0] // empty) | reads
        elif .Type == "Block" or .Type == "Subshell" or .Type == "CmdSubst" or .Type == "ProcSubst" then (.Stmts[0] // empty) | reads
        elif .Type == "FuncDecl" or .Type == "TestDecl" then empty
        else to_entries[] | select(.key | IN("Then", "Else", "Do", "Items") | not) | .value | reads
        end;
    def elseless: if .Else == null then true elif (.Else.Cond | length) == 0 then false else .Else | elseless end;
    def lit: [.Parts[]? | if .Type == "Lit" or .Type == "SglQuoted" then .Value
        elif .Type == "DblQuoted" then ([.Parts[]? | select(.Type == "Lit") | .Value] | join(""))
        else "\u0000" end] | join("");
    def argv: [.Args[]? | lit];
    def early: (.[0] // "") as $c | .[1:] as $a
        | if $c == "head" then true
        elif $c == "grep" then $a[:($a | index("--")) // ($a | length)]
            | any(.[]; test("^-[A-Za-z]*[qml]") or test("^--(quiet|silent|max-count|files-with-matches)"))
        elif $c == "sed" then any($a[]; (startswith("-") | not) and test("(^|[;{}[:space:]0-9$/])[qQ]([0-9[:space:];}]|$)"))
        elif $c == "awk" then any($a[]; (startswith("-") | not) and test("(^|[^A-Za-z_])exit([^A-Za-z_]|$)"))
        else false end;
    (.. | arrays | select(length > 1 and (.[0] | type == "object" and has("Cmd"))) as $l
        | range(0; ($l | length) - 1) as $i
        | select($l[$i].Cmd.Type? == "IfClause" and ($l[$i].Cmd | elseless))
        | $l[$i + 1] | reads | "status\tfi\t\(.)"),
    (.. | objects | select(has("Cond") and has("Then") and (.Cond | length) > 0 and .Cond[-1].Negated == true)
        | (.Then[0] // empty) | reads | "status\tneg\t\(.)"),
    (if any(.. | objects | select(.Type == "CallExpr") | argv; .[0] == "set" and any(.[1:][]; test("pipefail")))
     then .. | objects | select(.Type == "BinaryCmd" and (.Op == 13 or .Op == 14))
        | select(.Y.Cmd.Type? == "CallExpr" and (.Y.Cmd | argv | early))
        | "pipe\t\(.Pos.Line)\t\(.Y.Cmd | argv | join(" "))"
     else empty end)'

# What: path -> shell findings, kept for this ci.sh process.
# Why: check all runs both guards; each file is parsed once.
# From: Issue #1683 | PR #1858
declare -gA _CI_SHELL_FINDINGS=()

# What: tagged shell findings of one source (status, pipe).
# Why: one parse and one tree walk per file and process.
# From: Issue #1683 | PR #1858
_ci_shell_findings() {
    local f="$1" ast out
    if [ -n "${_CI_SHELL_FINDINGS["${f}"]+set}" ]; then
        printf '%s' "${_CI_SHELL_FINDINGS["${f}"]}"
        return 0
    fi
    ast="$(_ci_shell_ast "${f}")" || return 2
    out="$(_ci_run "[CI-ERROR-CHECK-0167]" "file=\"${f}\" reason=\"syntax tree query failed\"" jq -r "${_CI_JQ_SHELL_FINDINGS}" <<< "${ast}")" || return 2
    _CI_SHELL_FINDINGS["${f}"]="${out}"
    printf '%s' "${out}"
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

# What: load the path exemptions from the SOT, once.
# Why: a failed read must fail the check, never pass it.
# From: Issue #1683 | PR #1858
_ci_prose_exempt_load() {
    local list state
    list="$(_ci_block_entry_list file_headers "" exempt)" || return 2
    state="$(_ci_block_entry_field release "" validation_state)" || return 2
    _CI_PROSE_EXEMPT="${list}"$'\n'"${state}"
}

# What: True for a path exempt from prose-comment checks.
# Why: One owner for header + review-chronology exclusions.
# From: Issue #1683
_ci_prose_excluded() {
    case "$1" in
        *.md|VERSION|LICENSE|COPYING) return 0 ;;
        .env|.env.example) return 0 ;;
        Cargo.lock|*/Cargo.lock|.gitkeep|*/.gitkeep) return 0 ;;
        */fuzz/corpus/*|fuzz/corpus/*) return 0 ;;
        *.png|*.jpg|*.jpeg|*.gif|*.ico|*.svg|*.woff|*.woff2|*.ttf|*.eot|*.crt|*.key|*.pem) return 0 ;;
    esac
    local e
    while IFS= read -r e; do
        [ -n "${e}" ] || continue
        [ "$1" = "${e}" ] || [[ "$1" == */"${e}" ]] && return 0
    done <<<"${_CI_PROSE_EXEMPT:-}"
    return 1
}

# What: print the comment grammar of a path, else rc 1.
# Why: header, length and chronology checks share one map.
# From: Issue #1683 | PR #1858
_ci_comment_style() {
    case "$1" in
        services/ui/src/templates/*.html|*/services/ui/src/templates/*.html) printf 'tera\n' ;;
        *.html) printf 'html\n' ;;
        *.rs) printf 'rust\n' ;;
        *.lua) printf 'lua\n' ;;
        *.js) printf 'js\n' ;;
        *.css) printf 'css\n' ;;
        *.yml|*.yaml) printf 'yaml\n' ;;
        *.sh|*.bats|*.toml|*.conf|*.template|*.txt|*.env|*.service|*.timer|*.ps1|*.dockerignore|Dockerfile|*/Dockerfile|.gitattributes|.gitignore|*/.gitignore|CODEOWNERS|*/CODEOWNERS|.githooks/*|*/.githooks/*) printf 'hash\n' ;;
        *) return 1 ;;
    esac
}

# What: Print the native project+SPDX header for a path.
# Why: Header uses the file format's own comment syntax.
# From: Issue #1683
_ci_header_expected() {
    local h='LanCache-NG (https://github.com/wiki-mod/lancache-ng)'
    local s='SPDX-License-Identifier: AGPL-3.0-or-later' style
    style="$(_ci_comment_style "$1")" || return 1
    case "${style}" in
        tera) printf '{# %s #}\n{# %s #}\n' "${h}" "${s}" ;;
        html) printf '<!-- %s -->\n<!-- %s -->\n' "${h}" "${s}" ;;
        rust) printf '//! %s\n//! %s\n' "${h}" "${s}" ;;
        lua) printf -- '-- %s\n-- %s\n' "${h}" "${s}" ;;
        js) printf '// %s\n// %s\n' "${h}" "${s}" ;;
        css) printf '/* %s */\n/* %s */\n' "${h}" "${s}" ;;
        hash|yaml) printf '# %s\n# %s\n' "${h}" "${s}" ;;
    esac
}

# What: True if line 1 is a valid marker for the path.
# Why: shebang / Docker directive / Rust //! sit on line 1.
# From: Issue #1683
_ci_header_line1_ok() {
    local path="$1" l1="$2"
    if [ "$(_ci_comment_style "${path}")" = rust ]; then [ "${l1}" = "//!" ]; return "$?"; fi
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
    _ci_prose_exempt_load || return 2
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
        local produced produced_rc=0
        produced="$(head -n 20 -- "${path}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 0 || return 2
        mapfile -t scan <<<"${produced}"
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

# What: awk lexer: F/C/D/T per line of L[1..n] for a style.
# Why: one comment grammar owner for every comment check.
# From: Issue #1683 | PR #1858
_CI_AWK_COMMENT_LEX='
    BEGIN {
        sq = sprintf("%c", 39)
        mb = (length("é") == 1); lead_re = "^[\300-\367]$"; cont_re = "^[\200-\277]$"
    }
    { L[FNR] = $0; sub(/\r$/, "", L[FNR]) }
    # What: queue the heredoc delimiters a shell line opens.
    # Why: <<< , quoted or (( )) << open no here-document.
    # From: Issue #1683 | PR #1858
    function cl_heredocs(s,  i, n, c, q, dep, rest, w) {
        n = length(s); q = ""; dep = 0
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (q == sq) { if (c == sq) q = ""; continue }
            if (c == "\\") { i++; continue }
            if (q == "\"") { if (c == "\"") q = ""; continue }
            if (c == sq || c == "\"") { q = c; continue }
            if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) break
            if (substr(s, i, 2) == "((") { dep++; i++; continue }
            if (substr(s, i, 2) == "))" && dep > 0) { dep--; i++; continue }
            if (substr(s, i, 3) == "<<<") { i += 2; continue }
            if (substr(s, i, 2) != "<<" || dep > 0) continue
            rest = substr(s, i + 2)
            if (!match(rest, /^-?[[:space:]]*[^[:space:];|&<>()]+/)) continue
            w = substr(rest, 1, RLENGTH); i += 1 + RLENGTH
            hd[++ht] = (w ~ /^-/); sub(/^-?[[:space:]]*/, "", w); gsub(/["\047\\]/, "", w); hq[ht] = w
        }
    }
    # What: hash/yaml lines; heredoc=0 tracks YAML blocks.
    # Why: heredoc/block-scalar bodies are data, not runs.
    # From: Issue #1683 | PR #1858
    function cl_hash(heredoc,  i, line, chk, iny, ind) {
        hh = 1; ht = 0
        for (i = 1; i <= n; i++) {
            line = L[i]
            if (line ~ /^[[:space:]]*#/) { F[i] = 1; T[i] = line; sub(/^[[:space:]]*#[[:space:]]*/, "", T[i]) }
            if (i <= hdr) continue
            if (heredoc && hh <= ht) {
                H[i] = 1; chk = line; if (hd[hh]) sub(/^\t+/, "", chk)
                if (chk == hq[hh]) hh++
                continue
            }
            if (!heredoc && iny) {
                if (line ~ /^[[:space:]]*$/) continue
                match(line, /[^ ]/); if (RSTART - 1 > ind) continue
                iny = 0
            }
            if (line ~ /^[[:space:]]*#/) { C[i] = 1; continue }
            if (heredoc) cl_heredocs(line)
            else if (line ~ /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][+-]?[0-9]?[[:space:]]*$/) {
                match(line, /[^ ]/); ind = RSTART - 1; iny = 1
            }
        }
    }
    # What: end of a Rust quote: char literal or lifetime.
    # Why: a " in a char literal must not open a string.
    # From: Issue #1683 | PR #1858
    function cl_quote(s, p, len,  c, q, k) {
        c = substr(s, p + 1, 1)
        if (c == "\\") {
            q = p + 3
            while (q <= len && substr(s, q, 1) != sq) q++
            return (q <= len) ? q + 1 : p + 1
        }
        if (c != "" && c != sq && substr(s, p + 2, 1) == sq) return p + 3
        if (!mb && c ~ lead_re) {
            k = 2
            while (k <= 4 && substr(s, p + k, 1) ~ cont_re) k++
            if (substr(s, p + k, 1) == sq) return p + k + 1
        }
        return p + 1
    }
    # What: comment text of a line: markers and closer cut.
    # Why: field rules read What/Why/From after the marker.
    # From: Issue #1683 | PR #1858
    function cl_text(s, kind, inblk,  t, op, cl) {
        t = s; sub(/^[[:space:]]+/, "", t)
        if (kind == "line") sub(/^\/\/+!?/, "", t)
        else if (kind == "lua") sub(/^--+/, "", t)
        else {
            if (kind == "c") { op = "^/[*][*!]?"; cl = "[[:space:]]*[*]/[[:space:]]*$" }
            else if (kind == "html") { op = "^<!--"; cl = "[[:space:]]*--!?>[[:space:]]*$" }
            else if (kind == "tera") { op = "^[{]#-?"; cl = "[[:space:]]*-?#[}][[:space:]]*$" }
            else { op = "^--[[]=*[[]"; cl = "[[:space:]]*[]]=*[]][[:space:]]*$" }
            sub(cl, "", t)
            if (!inblk) sub(op, "", t)
            else if (kind == "c") sub(/^[*]+/, "", t)
        }
        sub(/^[[:space:]]+/, "", t)
        return t
    }
    # What: note a comment on this line; first kind wins.
    # Why: T is cut with the delimiters of that kind.
    # From: Issue #1683 | PR #1858
    function cl_mark(k) { lm = 1; if (lk == "") lk = k }
    function cl_rep(c, k,  r) { r = ""; while (k-- > 0) r = r c; return r }
    # What: Lua 5.4 lexer: short and long strings, --.
    # Why: -- inside any string is no comment.
    # From: Issue #1683 | PR #1858
    function cl_lua(  i, s, len, p, c, o, st, q, z, iscm, lcl) {
        st = "code"
        for (i = 1; i <= n; i++) {
            s = L[i]; len = length(s); p = 1; lc = 0; lm = 0; lk = ""; bs = 0
            if (st == "long" && iscm) { lm = 1; lk = "lualong"; IB[i] = 1 }
            else if (st != "code") lc = 1
            while (p <= len) {
                c = substr(s, p, 1)
                if (st == "str") {
                    if (z && c ~ /[[:space:]]/) { p++; continue }
                    z = 0
                    if (c == "\\") { if (substr(s, p + 1, 1) == "z") z = 1; else bs = (p + 1 > len); p += 2 }
                    else { if (c == q) st = "code"; p++ }
                } else if (st == "long") {
                    o = index(substr(s, p), lcl)
                    if (o) { p += o - 1 + length(lcl); st = "code" } else p = len + 1
                } else if (substr(s, p, 2) == "--") {
                    if (match(substr(s, p + 2), /^[[]=*[[]/)) {
                        lcl = "]" cl_rep("=", RLENGTH - 2) "]"; iscm = 1; st = "long"
                        cl_mark("lualong"); p += 2 + RLENGTH
                    } else { cl_mark("lua"); break }
                } else if (c ~ /[[:space:]]/) p++
                else {
                    lc = 1
                    if (c == "\"" || c == sq) { q = c; st = "str"; z = 0; p++ }
                    else if (match(substr(s, p), /^[[]=*[[]/)) {
                        lcl = "]" cl_rep("=", RLENGTH - 2) "]"; iscm = 0; st = "long"; p += RLENGTH
                    } else p++
                }
            }
            if (st == "str" && !z && !bs) st = "code"
            if (lm && !lc) { F[i] = C[i] = 1; K[i] = lk }
        }
    }
    # What: CSS step: strings, url(), /* */ blocks.
    # Why: /* in a string or url() opens no comment.
    # From: Issue #1683 | PR #1858
    function cl_css(s, p, len, c, c2) {
        if (ss == "blk") { cl_mark("c"); if (c2 == "*/") { ss = "code"; return p + 2 } return p + 1 }
        if (ss != "code") lc = 1
        if (ss == "sq" || ss == "dq") {
            if (c == "\\") { bs = (p + 1 > len); return p + 2 }
            if (c == (ss == "sq" ? sq : "\"")) ss = "code"
            return p + 1
        }
        if (ss == "url") { if (c == ")") ss = "code"; return p + 1 }
        if (c2 == "/*") { ss = "blk"; cl_mark("c"); return p + 2 }
        if (c ~ /[[:space:]]/) return p + 1
        lc = 1
        if (c == "\"" || c == sq) { ss = (c == sq) ? "sq" : "dq"; bs = 0; return p + 1 }
        if (tolower(substr(s, p, 4)) == "url(" && substr(s, p - 1, 1) !~ /[-A-Za-z0-9_]/ && substr(s, p + 4) !~ /^[[:space:]]*["\047]/) { ss = "url"; return p + 4 }
        return p + 1
    }
    # What: JS step: strings, templates, regex, comments.
    # Why: a regex or string may hold // or /* text.
    # From: Issue #1683 | PR #1858
    function cl_js(s, p, len, c, c2,  w) {
        if (ss == "blk") { cl_mark("c"); if (c2 == "*/") { ss = "code"; return p + 2 } return p + 1 }
        if (ss == "lc") { cl_mark("line"); return p + 1 }
        if (ss != "code") lc = 1
        if (ss == "sq" || ss == "dq") {
            if (c == "\\") { bs = (p + 1 > len); return p + 2 }
            if (c == (ss == "sq" ? sq : "\"")) ss = "code"
            return p + 1
        }
        if (ss == "tpl") {
            if (c == "\\") return p + 2
            if (c == "`") { ss = "code"; rxok = 0 }
            else if (c2 == "${") { tstk[++tdep] = bdep; ss = "code"; rxok = 1; return p + 2 }
            return p + 1
        }
        if (ss == "rx") {
            if (c == "\\") return p + 2
            if (c == "[") ss = "rxc"
            else if (c == "/") { ss = "code"; rxok = 0; if (match(substr(s, p + 1), /^[A-Za-z0-9_$]+/)) return p + 1 + RLENGTH }
            return p + 1
        }
        if (ss == "rxc") { if (c == "\\") return p + 2; if (c == "]") ss = "rx"; return p + 1 }
        if (c2 == "//") { ss = "lc"; cl_mark("line"); return p + 2 }
        if (c2 == "/*") { ss = "blk"; cl_mark("c"); return p + 2 }
        if (c ~ /[[:space:]]/) return p + 1
        lc = 1
        if (c == "\"" || c == sq) { ss = (c == sq) ? "sq" : "dq"; bs = 0; rxok = 0; return p + 1 }
        if (c == "`") { ss = "tpl"; return p + 1 }
        if (c == "/") { if (rxok) ss = "rx"; else rxok = 1; return p + 1 }
        if (c == "{") { bdep++; rxok = 1; return p + 1 }
        if (c == "}") {
            if (tdep && bdep == tstk[tdep]) { tdep--; ss = "tpl" } else { bdep--; rxok = 1 }
            return p + 1
        }
        if (c == ")" || c == "]") { rxok = 0; return p + 1 }
        if (match(substr(s, p), /^[A-Za-z0-9_$]+/)) {
            w = substr(s, p, RLENGTH)
            rxok = (w ~ /^(return|typeof|case|do|else|in|instanceof|new|delete|void|throw|yield|await|of)$/)
            return p + RLENGTH
        }
        rxok = 1
        return p + 1
    }
    # What: one line of html/tera; state carries over.
    # Why: Tera tags apply first, then html, css, js.
    # From: Issue #1683 | PR #1858
    function cl_webline(s, tera,  len, p, c, c2, o, w) {
        len = length(s); p = 1
        while (p <= len) {
            c = substr(s, p, 1); c2 = substr(s, p, 2)
            if (tera && tm == "cmt") {
                cl_mark("tera"); o = index(substr(s, p), "#}")
                if (o) { p += o + 1; tm = "" } else p = len + 1
            } else if (tera && tm == "expr") {
                lc = 1
                if (tq2 != "") { if (c == tq2) tq2 = ""; p++ }
                else if (c == "\"" || c == sq || c == "`") { tq2 = c; p++ }
                else if (c2 == tclose) { tm = ""; p += 2 }
                else p++
            } else if (tera && tm == "raw" && match(substr(s, p), /^[{]%-?[[:space:]]*endraw[[:space:]]*-?%[}]/)) {
                tm = ""; lc = 1; p += RLENGTH
            } else if (tera && tm == "" && c2 == "{#") { tm = "cmt"; cl_mark("tera"); p += 2 }
            else if (tera && tm == "" && c2 == "{{") { tm = "expr"; tclose = "}}"; tq2 = ""; lc = 1; p += 2 }
            else if (tera && tm == "" && c2 == "{%") {
                lc = 1
                if (match(substr(s, p), /^[{]%-?[[:space:]]*raw[[:space:]]*-?%[}]/)) { tm = "raw"; p += RLENGTH }
                else { tm = "expr"; tclose = "%}"; tq2 = ""; p += 2 }
            } else if (m == "html") {
                if (substr(s, p, 4) == "<!--") { m = "hcmt"; cl_mark("html"); p += 4 }
                else if (match(substr(s, p), /^<\/?[A-Za-z][A-Za-z0-9]*/)) {
                    w = substr(s, p, RLENGTH); tend = (substr(w, 2, 1) == "/"); sub(/^<\/?/, "", w)
                    tname = tolower(w); m = "tag"; tq = ""; lc = 1; p += RLENGTH
                } else { if (c !~ /[[:space:]]/) lc = 1; p++ }
            } else if (m == "hcmt") {
                cl_mark("html"); o = index(substr(s, p), "-->"); w = index(substr(s, p), "--!>")
                if (w && (!o || w < o)) { p += w + 3; m = "html" }
                else if (o) { p += o + 2; m = "html" }
                else p = len + 1
            } else if (m == "tag") {
                lc = 1
                if (tq != "") { if (c == tq) tq = ""; p++ }
                else if (c == "\"" || c == sq) { tq = c; p++ }
                else if (c == ">") {
                    m = (!tend && tname == "script") ? "js" : (!tend && tname == "style") ? "css" : "html"
                    ss = "code"; rxok = 1; bdep = 0; tdep = 0; p++
                } else p++
            } else if (emb && c2 == "</" && tolower(substr(s, p + 2, length(tname))) == tname \
                && substr(s, p + 2 + length(tname), 1) ~ /^([[:space:]]|>|\/)?$/) {
                m = "tag"; tend = 1; tq = ""; ss = "code"; lc = 1; p += 2 + length(tname)
            } else if (m == "css") p = cl_css(s, p, len, c, c2)
            else p = cl_js(s, p, len, c, c2)
        }
        if (ss == "lc" || ss == "rx" || ss == "rxc") ss = "code"
        if ((ss == "sq" || ss == "dq") && !bs) ss = "code"
    }
    # What: html/tera/css/js driver; marks comment lines.
    # Why: script/style content uses its own grammar.
    # From: Issue #1683 | PR #1858
    function cl_web(start, tera,  i) {
        m = start; ss = "code"; tm = ""; tq = ""; emb = (start == "html"); rxok = 1; bdep = 0; tdep = 0
        for (i = 1; i <= n; i++) {
            lc = 0; lm = 0; lk = ""; bs = 0
            if (tera && tm == "cmt") { lm = 1; lk = "tera"; IB[i] = 1 }
            else if (m == "hcmt") { lm = 1; lk = "html"; IB[i] = 1 }
            else if ((m == "js" || m == "css") && ss == "blk") { lm = 1; lk = "c"; IB[i] = 1 }
            else if ((tera && tm == "expr") || m == "tag" || ss ~ /^(sq|dq|tpl|url)$/) lc = 1
            cl_webline(L[i], tera)
            if (lm && !lc) { F[i] = C[i] = 1; K[i] = lk }
        }
    }
    # What: Rust per Reference lexer: strings, raw, blocks.
    # Why: // in a string is no comment; # never is one.
    # From: Issue #1683 | PR #1858
    function cl_rust(  i, s, len, p, c, c2, st, st0, dep, code, cmt, o, rclose) {
        st = "code"
        for (i = 1; i <= n; i++) {
            s = L[i]; len = length(s); p = 1; st0 = st
            code = (st0 == "str" || st0 == "raw"); cmt = (st0 == "blk")
            while (p <= len) {
                c2 = substr(s, p, 2); c = substr(s, p, 1)
                if (st == "blk") {
                    if (c2 == "/*") { dep++; p += 2 }
                    else if (c2 == "*/") { p += 2; if (--dep == 0) st = "code" }
                    else p++
                } else if (st == "str") {
                    if (c == "\\") p += 2
                    else { if (c == "\"") st = "code"; p++ }
                } else if (st == "raw") {
                    o = index(substr(s, p), rclose)
                    if (o) { p += o - 1 + length(rclose); st = "code" } else p = len + 1
                } else if (c2 == "//") { cmt = 1; break }
                else if (c2 == "/*") { cmt = 1; st = "blk"; dep = 1; p += 2 }
                else if (c ~ /[[:space:]]/) p++
                else {
                    code = 1
                    if (c == "\"") { st = "str"; p++ }
                    else if (c ~ /[rbc]/ && substr(s, p - 1, 1) !~ /[A-Za-z0-9_]/ && match(substr(s, p), /^(r|br|cr)#*"/)) {
                        rclose = substr(s, p, RLENGTH); sub(/^[bc]?r/, "", rclose); sub(/"$/, "", rclose)
                        rclose = "\"" rclose; st = "raw"; p += RLENGTH
                    } else if (c == sq) p = cl_quote(s, p, len)
                    else p++
                }
            }
            if (cmt && !code) {
                F[i] = C[i] = 1; IB[i] = (st0 == "blk")
                K[i] = (!IB[i] && s ~ /^[[:space:]]*\/\//) ? "line" : "c"
            }
        }
    }
    # What: run the style lexer; cut header; mark dividers.
    # Why: a style without a lexer must fail, never pass.
    # From: Issue #1683 | PR #1858
    function cl_lex(  i, t) {
        n = FNR; hdr = (n >= 3 && L[2] == h2 && L[3] == h3) ? 3 : 0
        if (style == "hash") cl_hash(1)
        else if (style == "yaml") cl_hash(0)
        else if (style == "rust") cl_rust()
        else if (style == "lua") cl_lua()
        else if (style == "css" || style == "js") cl_web(style, 0)
        else if (style == "html" || style == "tera") cl_web("html", style == "tera")
        else { print "no comment lexer for style " style > "/dev/stderr"; exit 2 }
        for (i = 1; i <= hdr; i++) C[i] = 0
        for (i = 1; i <= n; i++) if (C[i]) {
            if (K[i] != "") T[i] = cl_text(L[i], K[i], IB[i])
            t = T[i]; sub(/[[:space:]]+$/, "", t)
            D[i] = (t ~ /^[-=~_*]{4,}$/) || (t ~ /^(─|━|═|┄|┈|╌|╍)/)
        }
    }
'

# What: Enforce AG-CODE-012 comment size, block, ref rules.
# Why: 1-1-1-60, story-run size, and refs go in From only.
# From: Issue #1683
_ci_check_comment_length() {
    local -a _ci_override=("$@") files=()
    local file style exp arc=0
    local -a bad_files=() no_lexer=()
    _ci_scan_files files _ci_override || return 2
    _ci_prose_exempt_load || return 2
    for file in "${files[@]}"; do
        _ci_prose_excluded "${file}" && continue
        if ! style="$(_ci_comment_style "${file}")"; then
            no_lexer+=("${file}"); continue
        fi
        exp="$(_ci_header_expected "${file}")" || return 2
        awk -v style="${style}" -v h2="${exp%%$'\n'*}" -v h3="${exp#*$'\n'}" "${_CI_AWK_COMMENT_LEX}"'
            function flush1() {
                if (bl > 3) { printf "%s:%d: block %d lines (max 3)\n", FILENAME, bs, bl; viol++ }
                bl = 0
            }
            function flush2() {
                if (rl > 3) { printf "%s:%d: story-telling block (%d lines)\n", FILENAME, rs, rl; viol++ }
                rs = 0; rl = 0
            }
            END {
                cl_lex()
                for (i = 1; i <= n; i++) {
                    if (F[i] && T[i] ~ /^(What|Why|From):/) {
                        if (bl == 0) bs = i
                        bl++
                        if (length(L[i]) > 60) { printf "%s:%d: %d chars (max 60): %s\n", FILENAME, i, length(L[i]), L[i]; viol++ }
                        if (T[i] ~ /^(What|Why):/ && T[i] ~ /#[0-9]/) { printf "%s:%d: issue/PR ref in What/Why (use From:): %s\n", FILENAME, i, L[i]; viol++ }
                        if (T[i] ~ /^From:/ && T[i] !~ /^From: (Issue #[0-9]+|PR #[0-9]+|Issue #[0-9]+ \| PR #[0-9]+)$/) { printf "%s:%d: From: allows one Issue and one PR only: %s\n", FILENAME, i, L[i]; viol++ }
                    } else if (bl > 0) flush1()
                }
                if (bl > 0) flush1()
                for (i = 1; i <= n; i++) if (C[i]) { if (!rs) rs = i; if (!D[i]) rl++ } else flush2()
                flush2()
                if (viol > 0) exit 1
            }
        ' "${file}" || arc=$?
        _ci_comment_length_rc "${file}" || return 2
    done
    # What: a type with no comment grammar fails the check.
    # Why: an unread file must never be reported as clean.
    # From: Issue #1683 | PR #1858
    if [ "${#no_lexer[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0153]" "files=${#no_lexer[@]} reason=\"no comment grammar for this file type\"" "$(printf '%s\n' "${no_lexer[@]}")"
    fi
    if [ "${#bad_files[@]}" -gt 0 ]; then
        ci_log "[CI-ERROR-CHECK-0128]" "files=${#bad_files[@]} scanned=${#files[@]} reason=\"comment contract violations (list above)\""
    fi
    [ "${#no_lexer[@]}" -eq 0 ] && [ "${#bad_files[@]}" -eq 0 ] || return 1
    printf 'comment-length=clean files=%s\n' "${#files[@]}"
}

# What: classify one comment scan rc: 1 = violations.
# Why: a read error (rc 2+) must not count as a finding.
# From: Issue #1683 | PR #1858
_ci_comment_length_rc() {
    local file="$1"
    case "${arc}" in
        0) ;;
        1) case " ${bad_files[*]} " in *" ${file} "*) ;; *) bad_files+=("${file}") ;; esac ;;
        *) ci_log "[CI-ERROR-CHECK-0129]" "file=\"${file}\" rc=${arc} reason=\"comment scan failed (raw above)\""; return 2 ;;
    esac
    arc=0
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
    local -a _ci_override=("$@") files=() shell=()
    local -A is_sh=()
    _ci_scan_files files _ci_override || return 2
    _ci_shell_sources shell _ci_override || return 2
    local path
    for path in "${shell[@]}"; do is_sh["${path}"]=1; done
    local -a viol=()
    for path in "${files[@]}"; do
        # What: vendored minified UI asset, not authored.
        # Why: AG-REL-001 governs authored, not vendored.
        # From: Issue #1683 | PR #1858
        case "${path}" in services/ui/src/static/*.min.js) continue ;; esac
        case "${path}" in
            *.py|*.pyc|*.pyw|*.rb|*.php|*.pl|*.pm|*.js|*.mjs|*.cjs|*.ts) viol+=("${path}: banned-language file"); continue ;;
        esac
        if [ -n "${is_sh[${path}]:-}" ] || [[ "${path}" == *.yml || "${path}" == *.yaml ]]; then
            local inline
            inline="$(_ci_capture 1 grep -E '(python3?|perl|ruby|node)[[:space:]]+-[eEc]|<<-?[[:space:]]*"?(PY|PYEOF|PYTHON|PERL|RUBY)' "${path}")" || return 2
            if [ -n "${inline}" ]; then
                viol+=("${path}: inline foreign-language interpreter")
            fi
        fi
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0007]" "reason=\"banned language (AG-REL-001)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'language-policy=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a mutable image or action reference.
# Why: SHA/digest-pinned only, no :latest, tag or branch.
# From: Issue #1683
_ci_check_mutable_refs() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/workflows/*.yml' '.github/actions/**/action.yml' "${CI_DOCKERFILE_SPECS[@]}" || return 2
    local path out line v
    local -a viol=()
    for path in "${files[@]}"; do
        case "${path}" in
            *.yml|*.yaml)
                # What: external ref needs a 40-hex SHA.
                # Why: tags, branches, short SHAs move.
                # From: Issue #1683 | PR #1858
                out="$(_ci_capture 1 grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]*]' "${path}")" || return 2
                while IFS= read -r line; do
                    [ -n "${line}" ] || continue
                    v="$(sed -E 's/^[0-9]+:[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(&[A-Za-z0-9_-]+[[:space:]]+)?//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"${line}")"
                    v="${v#[\"\']}"; v="${v%[\"\']}"
                    _ci_action_ref_is_external "${v}" || continue
                    [[ "${v##*@}" =~ ^[0-9a-fA-F]{40}$ ]] || viol+=("${path} action-not-full-sha: ${line}")
                done <<<"${out}"
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
                # What: # syntax= needs an @sha256 pin.
                # Why: unpinned is pulled anew each build.
                # From: Issue #1683 | PR #1858
                out="$(_ci_capture 1 grep -niE '^#[[:space:]]*syntax[[:space:]]*=' "${path}")" || return 2
                out="$(_ci_capture 1 grep -vE "@${CI_DIGEST_RE}" <<< "${out}")" || return 2
                if [ -n "${out}" ]; then
                    viol+=("${path} syntax-unpinned: ${out}")
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
    hooks="$(_ci_ls_files executable-bits . '.githooks/*')" || return 2
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
        mode="$(_ci_capture 0 git ls-files -s -- "${path}")" || return 2
        mode="${mode%% *}"
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
    _ci_env_required CHRONOLOGY_DIFF_BASE_REF > /dev/null || return 2
    _ci_env_required GITHUB_SHA > /dev/null || return 2
    local remote
    remote="$(_ci_git_remote)" || return 2
    _ci_retry "git-fetch-chronology-base-ref" git fetch --no-tags --depth=1 "${remote}" \
        "+refs/heads/${CHRONOLOGY_DIFF_BASE_REF}:refs/remotes/${remote}/${CHRONOLOGY_DIFF_BASE_REF}" >/dev/null || return 2
    _ci_retry "git-fetch-chronology-base-sha" git fetch --no-tags --depth=1 "${remote}" \
        "${CHRONOLOGY_DIFF_BASE_SHA}" >/dev/null || return 2
    local out
    out="$(git cat-file -e "${CHRONOLOGY_DIFF_BASE_SHA}^{commit}" 2>&1)" || {
        ci_error "[CI-ERROR-CHECK-0010]" "sha=\"${CHRONOLOGY_DIFF_BASE_SHA}\" reason=\"diff base sha unreachable\"" "${out}"; return 2; }
    out="$(git cat-file -e "${GITHUB_SHA}^{commit}" 2>&1)" || {
        ci_error "[CI-ERROR-CHECK-0076]" "sha=\"${GITHUB_SHA}\" reason=\"GITHUB_SHA unreachable\"" "${out}"; return 2; }
    local diff_file
    diff_file="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
    if ! out="$(git diff -z --name-only --diff-filter=ACMRTUXB \
        "${CHRONOLOGY_DIFF_BASE_SHA}" "${GITHUB_SHA}" 2>&1 > "${diff_file}")"; then
        ci_error "[CI-ERROR-CHECK-0077]" "base=\"${CHRONOLOGY_DIFF_BASE_SHA}\" head=\"${GITHUB_SHA}\" reason=\"git diff itself failed; not treating as a clean pass\"" "${out}"
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
    _ci_prose_exempt_load || return 2
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
        local produced="" produced_rc=0 style exp
        # What: join adjacent comment lines per grammar
        # Why: narration split over two lines must match.
        # From: Issue #1683 | PR #1858
        if style="$(_ci_comment_style "${path}")"; then
            exp="$(_ci_header_expected "${path}")" || return 2
            produced="$(awk -v style="${style}" -v h2="${exp%%$'\n'*}" -v h3="${exp#*$'\n'}" "${_CI_AWK_COMMENT_LEX}"'
                END { cl_lex(); for (i = 2; i <= n; i++) if (F[i - 1] && F[i]) printf "%d\t%s %s\n", i - 1, T[i - 1], T[i] }
            ' "${path}")" || produced_rc=$?
            _ci_producer_ok "${produced_rc}" 0 || return 2
        fi
        while IFS=$'\t' read -r ln joined; do
            [ -n "${ln}" ] || continue
            shopt -s nocasematch
            [[ "${joined}" =~ ${rc} ]] && viol+=("${path}:${ln}: ${joined}")
            shopt -u nocasematch
        done <<<"${produced}"
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
        ci_error "[CI-WARN-CHECK-0078]" "reason=\"bare #N duplicated outside From: (warn-only, PR #1856)\"" "$(printf '%s\n' "${dup_viol[@]}")"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        local warn_only
        warn_only="$(_ci_variable CHRONOLOGY_WARN_ONLY)" || return 2
        if [ "${warn_only}" = "1" ]; then
            ci_error "[CI-WARN-CHECK-0079]" "reason=\"review-chronology / stale line-ref (warn-only)\"" "$(printf '%s\n' "${viol[@]}")"
            printf 'review-chronology=warn files=%s\n' "${#files[@]}"
            return 0
        fi
        ci_error "[CI-ERROR-CHECK-0080]" "reason=\"review-chronology / stale line-ref\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'review-chronology=clean files=%s\n' "${#files[@]}"
}

# What: Fail on a live pipe into an early-exiting consumer.
# Why: SIGPIPE under pipefail exits 141 (AG-VAL-032).
# From: Issue #1683 | PR #1858
_ci_check_pipefail_early_exit() {
    local -a _ci_override=("$@") files=()
    _ci_shell_sources files _ci_override dockerfiles || return 2
    local path produced tag line cmd
    local -a viol=()
    for path in "${files[@]}"; do
        produced="$(_ci_shell_findings "${path}")" || return 2
        while IFS=$'\t' read -r tag line cmd; do
            [ "${tag}" = pipe ] || continue
            if [ "${path##*/}" = Dockerfile ]; then
                viol+=("${path}: RUN text line ${line}: live pipe into '${cmd}' under pipefail")
            else
                viol+=("${path}:${line}: live pipe into '${cmd}' under pipefail")
            fi
        done <<< "${produced}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0011]" "reason=\"live pipe into early-exit consumer (SIGPIPE)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'pipefail-early-exit=clean files=%s\n' "${#files[@]}"
}

# What: Fail a bats [ ] && [ ] check with no || fallback.
# Why: set -e skips a failing first && term; test passes.
# From: Issue #1683 | PR #1858
_ci_check_bats_and_chain() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/scripts/*.bats' || return 2
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        out="$(_ci_capture 0 awk '
            { line = (cont != "" ? cont " " : "") $0; cont = "" }
            /\\$/ { cont = substr(line, 1, length(line) - 1); if (!start) start = NR; next }
            line ~ /^[[:space:]]*\[\[?[[:space:]]/ && line ~ /\]\]?[[:space:]]*&&[[:space:]]*\[/ \
                && line ~ /\]\]?[[:space:]]*$/ && line !~ /\|\|/ {
                print (start ? start : NR) ": " line
            }
            { start = 0 }
        ' "${path}")" || return 2
        [ -z "${out}" ] || viol+=("${path}: ${out}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0145]" "reason=\"bats assertion chained with && and no || fallback\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'bats-and-chain=clean files=%s\n' "${#files[@]}"
}

# What: one ref's v1 form of a file; rc 1 = no NOOP proof.
# Why: one normalizer with build identity (A§12, Test C).
# From: Issue #1683 | PR #1858
_ci_test_gate_norm() {
    local ref="$1" path="$2" g="$3" src out rc=0
    if ! src="$(cd -- "${CI_REPO_ROOT}" && git show "${ref}:${path}" 2>&1)"; then
        ci_error "[CI-INFO-TESTID-0002]" "ref=\"${ref}\" path=\"${path}\" reason=\"not readable at ref; no NOOP proof\"" "${src}"
        return 1
    fi
    out="$(_ci_norm_content "${g}" "${src}")" || rc=$?
    case "${rc}" in
        0) printf '%s\n' "${out}" ;;
        1)
            ci_log "[CI-INFO-TESTID-0003]" "ref=\"${ref}\" path=\"${path}\" reason=\"not safely normalizable; no NOOP proof\""
            return 1
            ;;
        *) return 2 ;;
    esac
}

# What: print run or skip for the ci.bats suite.
# Why: comment-only edits are NOOP (arch doc Test B, C).
# From: Issue #1683 | PR #1858
_ci_test_identity_gate() {
    local refs base head md f g a b arc brc
    if [ "$#" -eq 0 ] || ! refs="$(_ci_diff_refs)"; then
        ci_log "[CI-INFO-TESTID-0001]" "reason=\"no changed files or no diff refs; suite runs\""
        printf 'run\n'
        return 0
    fi
    read -r base head <<< "${refs}"
    if [ -z "${base}" ]; then
        ci_log "[CI-INFO-TESTID-0004]" "reason=\"no base ref; suite runs\""
        printf 'run\n'
        return 0
    fi
    # What: a .md is a test input when a SOT key names it.
    # Why: one owner of SOT-named inputs (§12.4).
    # From: Issue #1683 | PR #1858
    md="$(_ci_sot_named_paths)" || return 2
    for f in "$@"; do
        case "${f}" in
            *.md)
                if grep -qxF -- "${f}" <<< "${md}"; then
                    ci_log "[CI-INFO-TESTID-0005]" "path=\"${f}\" reason=\"doc is a test input; suite runs\""
                    printf 'run\n'
                    return 0
                fi
                continue
                ;;
        esac
        # What: only shell-grammar files can prove a NOOP.
        # Why: one grammar owner; others are test inputs.
        # From: Issue #1683 | PR #1858
        if ! g="$(_ci_norm_grammar "${f}")" || [ "${g}" != shell ]; then
            ci_log "[CI-INFO-TESTID-0006]" "path=\"${f}\" reason=\"no semantic normalizer; suite runs\""
            printf 'run\n'
            return 0
        fi
        arc=0 brc=0
        a="$(_ci_test_gate_norm "${base}" "${f}" "${g}")" || arc=$?
        b="$(_ci_test_gate_norm "${head}" "${f}" "${g}")" || brc=$?
        [ "${arc}" -le 1 ] && [ "${brc}" -le 1 ] || return 2
        if [ "${arc}" -ne 0 ] || [ "${brc}" -ne 0 ]; then
            printf 'run\n'
            return 0
        fi
        if [ "${a}" != "${b}" ]; then
            ci_log "[CI-INFO-TESTID-0007]" "path=\"${f}\" reason=\"semantic change; suite runs\""
            printf 'run\n'
            return 0
        fi
    done
    printf 'skip\n'
}

# What: print "jobs cpus"; jobs = max(16, cpu count).
# Why: one owner for the 16-way floor of parallel checks.
# From: Issue #1683 | PR #1858
_ci_parallel_jobs() {
    local cpus
    cpus="$(_ci_run "[CI-ERROR-CHECK-0127]" "reason=\"cpu count unknown\"" nproc)" || return 2
    printf '%s %s\n' "$(( cpus > 16 ? cpus : 16 ))" "${cpus}"
}

# What: run the ci.bats regression contract in CI.
# Why: tests that never run in CI enforce nothing.
# From: Issue #1683 | PR #1858
_ci_check_ci_bats() {
    local suite="${CI_SCRIPT_DIR}/ci.bats" jobs cpus rc=0 gate
    if [ -n "${BATS_TEST_FILENAME:-}" ]; then
        printf 'ci-bats=NOT-RUN reason="already inside a bats run; no nested suite"\n'
        return 0
    fi
    if [ "${CI_SCAN_SCOPE_FILTER:-0}" = 1 ] && [ "$#" -gt 0 ]; then
        gate="$(_ci_test_identity_gate "$@")" || return 2
        if [ "${gate}" = skip ]; then
            printf 'ci-bats=NOT-RUN reason="no test-input change beyond comments" changed=%s\n' "$#"
            return 0
        fi
    fi
    # What: --jobs = max(16, cores); never below 16.
    # Why: the suite is sized for 16-way parallel runs.
    # From: Issue #1683 | PR #1858
    cpus="$(_ci_parallel_jobs)" || return 2
    read -r jobs cpus <<< "${cpus}"
    ci_log "[CI-INFO-CHECK-0125]" "suite=\"${suite}\" jobs=${jobs} cpus=${cpus} reason=\"running the regression contract\""
    # What: the suite gets PATH, HOME and TMPDIR only.
    # Why: job vars (scope filter, PR_*) would skew tests.
    # From: Issue #1683 | PR #1858
    env -i PATH="${PATH}" HOME="${HOME:-/root}" TMPDIR="${CI_TMPDIR}" \
        bats --print-output-on-failure --jobs "${jobs}" "${suite}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-CHECK-0126]" "suite=\"${suite}\" rc=${rc} reason=\"ci.bats failed (bats output above)\""
        return 1
    fi
    printf 'ci-bats=clean\n'
}

# What: flag exit paths that lose code, context or raw.
# Why: AG-INT-002/AG-VAL-029: the class kept coming back.
# From: Issue #1683 | PR #1858
_ci_check_exit_evidence() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override '.github/scripts/ci.sh' || return 2
    local path out
    local -a viol=()
    for path in "${files[@]}"; do
        if ! out="$(awk '
            function strip(s) { gsub(/\047[^\047]*\047/, "", s); return s }
            /^[a-z_][a-z0-9_]*\(\) [({]/ { fn = $1; sub(/\(\).*/, "", fn) }
            /^[[:space:]]*#/ { next }
            {
                s = strip($0)
                if (fn != "_ci_mktemp" && s ~ /(^|[^_a-z])mktemp([[:space:]]|$)/)
                    print FILENAME ":" NR ": raw-mktemp: " $0
                if (s ~ /for [A-Za-z_][A-Za-z0-9_]* in [^;]*\$\(/)
                    print FILENAME ":" NR ": for-in-substitution: " $0
                if (s ~ /< <\(/)
                    print FILENAME ":" NR ": process-substitution-loop: " $0
                if (s ~ /\[\[? +"\$\((_ci_block_entry_field|_ci_block_entry_list|_ci_block_keys|_ci_channel_field|ci_service_field|ci_services|ci_build_targets|ci_service_contexts|ci_context_path)[ )]/)
                    print FILENAME ":" NR ": reader-in-test: " $0
                if (s ~ /^[[:space:]]*(local +)?[A-Za-z_][A-Za-z0-9_]*="\$\((git|docker|jq|curl|gh|awk|sed|tar|cat|date|base64|sha256sum|openssl|dig|find|ls|wc|tr|cut|sort) [^)]*\)" *\|\| *return/)
                    print FILENAME ":" NR ": uncoded-external-return: " $0
                line = $0
                while (match(line, /\[CI-[A-Z]+-[A-Z0-9]+-[0-9][0-9][0-9][0-9]\]/)) {
                    code = substr(line, RSTART, RLENGTH); sub(/^\[CI-[A-Z]+-/, "", code); sub(/\]$/, "", code)
                    if (code in site) print FILENAME ":" NR ": duplicate-code " code " (first at line " site[code] "): " $0
                    else site[code] = NR
                    line = substr(line, RSTART + RLENGTH)
                }
            }' "${path}" 2>&1)"; then
            ci_error "[CI-ERROR-CHECK-0123]" "file=\"${path}\" reason=\"exit-evidence scan failed\"" "${out}"
            return 2
        fi
        [ -z "${out}" ] || viol+=("${out}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0124]" "files=${#files[@]} reason=\"exit path loses code, context or raw (AG-INT-002)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'exit-evidence=clean files=%s\n' "${#files[@]}"
}

# What: Flag a $? that reads an if's status, not CMD's.
# Why: else-less if and "if !" give 0 (AG-VAL-030).
# From: Issue #1683 | PR #1858
_ci_check_if_without_else_status() {
    local -a _ci_override=("$@") files=()
    local path produced tag kind line loc
    _ci_shell_sources files _ci_override dockerfiles || return 2
    local -a viol=()
    for path in "${files[@]}"; do
        produced="$(_ci_shell_findings "${path}")" || return 2
        while IFS=$'\t' read -r tag kind line; do
            [ "${tag}" = status ] || continue
            loc="${path}:${line}"
            [ "${path##*/}" != Dockerfile ] || loc="${path}: RUN text line ${line}"
            if [ "${kind}" = neg ]; then
                viol+=("${loc}: first \$? under 'if ! CMD' is the negation's 0 -- use 'CMD || rc=\$?'")
            else
                viol+=("${loc}: \$? after an else-less if is the if's 0 -- use 'if CMD; then rc=0; else rc=\$?; fi'")
            fi
        done <<< "${produced}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0065]" "reason=\"\$? reads an if's status, not the command's (AG-VAL-029)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'if-without-else-status=clean files=%s\n' "${#files[@]}"
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
    if [ -z "${cs_line}" ]; then
        ci_log "[CI-ERROR-CHECK-0117]" "file=\"${setup}\" anchor='case \"\${1:-install}\" in' reason=\"setup.sh dispatch anchor not found; wizard rows unknown\""
        return 3
    fi
    esac_line="$(awk -v s="${cs_line}" 'NR>s && /^esac$/{print NR; exit}' "${setup}")"
    if [ -z "${esac_line}" ]; then
        ci_log "[CI-ERROR-CHECK-0118]" "file=\"${setup}\" from_line=${cs_line} reason=\"no esac after the dispatch case; wizard rows unknown\""
        return 3
    fi
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
    local setup
    setup="$(_ci_installer "${repo_root}")" || return 2
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
    local produced produced_rc=0
    produced="$(_ci_setup_wizard_rows "${setup}")" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r r; do [ -n "${r}" ] && rows+=("${r}"); done <<<"${produced}"
    if [ "${#rows[@]}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0082]" "reason=\"zero ask/confirm prompts in setup.sh wizard; vacuous\""
        return 1
    fi
    local produced produced_rc=0
    produced="$(printf '%s\n' "${rows[@]}" | cut -f3 | sort -u)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r r; do [ -n "${r}" ] && all_prompts+=("${r}"); done <<<"${produced}"
    local produced produced_rc=0
    produced="$(printf '%s\n' "${rows[@]}" | awk -F'\t' '$1=="UNCOND"{print $2"\t"$3}' | sort -u)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r r; do [ -n "${r}" ] && uncond+=("${r}"); done <<<"${produced}"
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
        local produced produced_rc=0
        produced="$(
            awk '{ t=$0; sub(/^[ \t]+/,"",t); if(index(t,"expect_prompt {")==1){ x=substr(t,length("expect_prompt {")+1); sub(/}.*/,"",x); if(x!="")print x } }' "${sim}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 0 || return 2
        while IFS= read -r r; do [ -n "${r}" ] && sim_pats+=("${r}"); done <<<"${produced}"
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

# What: 0 when the PR author skips the PR text checks
# Why: one SOT author list for the title and template checks
# From: Issue #1683 | PR #1858
_ci_pr_check_exempt() {
    local authors
    authors="$(_ci_block_entry_list pr_policy "" check_exempt_authors)" || return 2
    [ -n "${PR_AUTHOR:-}" ] && grep -qxF -- "${PR_AUTHOR}" <<< "${authors}"
}

# What: Check a PR title's Conventional-Commit form.
# Why: SOT pr_policy + targets own the type/scope sets.
# From: Issue #1683 | PR #1858
_ci_check_pr_title() {
    local title="${PR_TITLE:-}" ex=0
    _ci_pr_check_exempt || ex=$?
    [ "${ex}" -ne 2 ] || return 2
    if [ "${ex}" -eq 0 ]; then
        printf 'pr-title=skip author="%s"\n' "${PR_AUTHOR}"; return 0
    fi
    if [ -z "${title}" ]; then
        ci_log "[CI-ERROR-CHECK-0012]" "reason=\"no PR title given\""; return 2
    fi
    local types scopes part
    types="$(_ci_block_entry_list pr_policy "" title_types)" || return 2
    if [ -z "${types}" ]; then
        ci_log "[CI-ERROR-CHECK-0085]" "reason=\"no SOT pr_policy.title_types; FAIL CLOSED\""; return 2
    fi
    scopes="$(ci_build_targets)" || return 2
    part="$(_ci_block_keys external_services)" || return 2
    scopes+=$'\n'"${part}"
    part="$(_ci_block_entry_list pr_policy "" title_scopes_extra)" || return 2
    scopes+=$'\n'"${part}"
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
        ci_log "[CI-WARN-CHECK-0013]" "reason=\"draft, non-blocking\" detail=\"$(printf '%s; ' "${errs[@]}")\""
        printf 'pr-title=warn-draft\n'
        return 0
    fi
    # What: PR_TITLE_LINT_MODE picks warn vs block mode.
    # Why: warn is the required default; block is opt-in.
    # From: Issue #1683 | PR #1858
    local lint_mode
    lint_mode="$(_ci_variable PR_TITLE_LINT_MODE)" || return 2
    if [ "${lint_mode}" != "block" ]; then
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
    local keys policy val
    keys="$(_ci_block_keys external_services)" || return 2
    for k in ${keys}; do
        img="$(_ci_block_entry_field external_services "${k}" image)" || return 2
        allowed+="${img} "
        # What: a SOT tag-latest entry may skip the digest.
        # Why: only an explicit SOT policy, never a guess.
        # From: Issue #1683 | PR #1858
        policy="$(_ci_block_entry_field external_services "${k}" policy)" || return 2
        [ "${policy}" = tag-latest ] && tagged+="${img} "
    done
    keys="$(_ci_block_keys base_images all)" || return 2
    for k in ${keys}; do
        val="$(_ci_block_entry_field base_images "" "${k}")" || return 2
        allowed+="${val} "
    done
    for d in "${dirs[@]}"; do
        if [ ! -d "${d}" ]; then
            viol+=("${d}: compose dir missing")
            continue
        fi
        local produced produced_rc=0
        produced="$(grep -rhE '^[[:space:]]+image:[[:space:]]' "${d}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
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
        done <<<"${produced}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0014]" "reason=\"external image not digest-pinned or not in SOT\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'stable-external-images=clean\n'
}

# What: Print the heading count, then the section lines.
# Why: one parser for PR-body sections (template, close).
# From: Issue #1683 | PR #1858
_ci_pr_section() {
    local text="$1" heading="$2" out
    # What: a heading outside code fences ends the section.
    # Why: a fenced or a level-3 heading must not bleed.
    # From: Issue #1496 | PR #1858
    if ! out="$(awk -v h="## ${heading}" '
        { sub(/\r$/, "") }
        /^(   |  | )?(```|~~~)/ { fence = !fence; if (found == 1) print; next }
        !fence && match($0, /^#+([ \t]|$)/) && RLENGTH <= 7 {
            line = $0; sub(/[ \t]+$/, "", line)
            if (line == h) { count++; if (found == 0) { found = 1; next } }
            if (found == 1) found = 2
            next
        }
        found == 1 { print }
        END { printf "%d\n", count }
    ' <<< "${text}" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0143]" "heading=\"${heading}\" reason=\"PR body section parse failed\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out##*$'\n'}"
    [ "${out}" = "${out##*$'\n'}" ] || printf '%s\n' "${out%$'\n'*}"
}

# What: Drop HTML comments from Markdown text.
# Why: template hints are not content (template, notes).
# From: Issue #1683 | PR #1858
_ci_md_strip_comments() {
    local out
    if ! out="$(awk '
        {
            line = $0; keep = ""
            while (1) {
                if (incm) {
                    p = index(line, "-->")
                    if (!p) break
                    line = substr(line, p + 3); incm = 0
                }
                p = index(line, "<!--")
                if (!p) { keep = keep line; break }
                keep = keep substr(line, 1, p - 1); line = substr(line, p + 4); incm = 1
            }
            print keep
        }
    ' <<< "$1" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0144]" "reason=\"HTML comment strip failed\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: PR body must fill every template section.
# Why: CONTRIBUTING.md requires all headings completed.
# From: Issue #1683
_ci_check_pr_template() {
    local body="${PR_BODY:-}" ex=0 checkbox
    _ci_pr_check_exempt || ex=$?
    [ "${ex}" -ne 2 ] || return 2
    if [ "${ex}" -eq 0 ]; then
        printf 'pr-template=skip author="%s"\n' "${PR_AUTHOR}"; return 0
    fi
    checkbox="$(_ci_block_entry_field pr_policy "" checkbox_section)" || return 2
    body="${body//$'\r'/}"
    local template
    template="$(_ci_repo_path CI_PR_TEMPLATE)" || return 2
    local -a sections=()
    if [ -f "${template}" ]; then
        local produced produced_rc=0
        produced="$(grep -oE '^## .+' "${template}" | sed 's/^## //')" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
        while IFS= read -r sec; do
            [ -n "${sec}" ] && sections+=("${sec}")
        done <<<"${produced}"
    fi
    if [ "${#sections[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0015]" "path=\"${template}\" reason=\"no sections found in the PR template\""
        return 2
    fi
    local -a missing=()
    local sec content stripped trimmed count
    for sec in "${sections[@]}"; do
        content="$(_ci_pr_section "${body}" "${sec}")" || return 2
        count="${content%%$'\n'*}"
        if [ "${content}" = "${count}" ]; then content=""; else content="${content#*$'\n'}"; fi
        if [ "${count}" -eq 0 ]; then
            missing+=("${sec}: heading not found"); continue
        fi
        if [ "${count}" -gt 1 ]; then
            missing+=("${sec}: heading appears ${count} times"); continue
        fi
        # What: strip HTML comments and code fence markers
        # Why: detect empty vs placeholder-only sections
        stripped="$(_ci_md_strip_comments "${content}")" || return 2
        stripped="$(_ci_capture 1 grep -v '^```' <<<"${stripped}")" || return 2
        trimmed="$(tr -d '[:space:]' <<<"${stripped}")"
        [ -n "${trimmed}" ] || { missing+=("${sec}: empty (only template placeholder left)"); continue; }
        if [ "${sec}" = "${checkbox}" ] && ! grep -qE '^- \[[xX]\]' <<<"${content}"; then
            missing+=("${checkbox}: no checkbox marked (- [x] ...)")
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

# What: start line and byte size of each run: block
# Why: awk length counts chars; LC_ALL=C makes it bytes
# From: Issue #1683
_ci_measure_run_blocks() {
    local file="$1"
    LC_ALL=C awk '
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

# What: list workflow files, or with "actions" action files
# Why: a guard that read no workflow must fail, not pass
# From: Issue #1683 | PR #1858
_ci_workflow_files() {
    local -n _ci_wf_out="$1"
    local _ci_wf_dir="$2" _ci_wf_kind="${3:-workflows}" _ci_wf_f
    local -a _ci_wf_glob=("${_ci_wf_dir}"/*.yml "${_ci_wf_dir}"/*.yaml)
    _ci_wf_out=()
    # What: composite actions are optional; workflows not.
    # Why: target CI has no actions; a run needs workflows
    # From: Issue #1683 | PR #1858
    if [ "${_ci_wf_kind}" = actions ]; then
        _ci_wf_glob=("${_ci_wf_dir}"/*/action.yml "${_ci_wf_dir}"/*/action.yaml)
    elif [ ! -d "${_ci_wf_dir}" ]; then
        ci_error "[CI-ERROR-CHECK-0016]" "dir=\"${_ci_wf_dir}\" reason=\"not a directory\"" "$(ls -ld -- "${_ci_wf_dir}" 2>&1)"
        return 2
    fi
    for _ci_wf_f in "${_ci_wf_glob[@]}"; do
        [ -f "${_ci_wf_f}" ] && _ci_wf_out+=("${_ci_wf_f}")
    done
    if [ "${_ci_wf_kind}" != actions ] && [ "${#_ci_wf_out[@]}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0053]" "dir=\"${_ci_wf_dir}\" reason=\"no workflow files (*.yml, *.yaml)\"" "$(ls -la -- "${_ci_wf_dir}" 2>&1)"
        return 2
    fi
}

# What: workflow size and run-block size stay under limits.
# Why: GitHub drops runs of oversized workflow files.
# From: Issue #1683
_ci_check_workflow_line_limit() {
    local dir="${1:-}"
    [ -n "${dir}" ] || dir="$(_ci_repo_path CI_WORKFLOW_DIR)" || return 2
    local max_lines max_bytes max_block
    max_lines="$(_ci_variable MAX_WORKFLOW_LINES)" || return 2
    max_bytes="$(_ci_variable MAX_WORKFLOW_BYTES)" || return 2
    max_block="$(_ci_variable MAX_RUN_BLOCK_BYTES)" || return 2
    local file counts lines bytes block_report block_line block_bytes
    local -a viol=() files=()
    _ci_workflow_files files "${dir}" || return 2
    for file in "${files[@]}"; do
        counts="$(_ci_capture 0 wc -lc "${file}")" || return 2
        read -r lines bytes _ <<< "${counts}"
        [ "${lines}" -gt "${max_lines}" ] && viol+=("${file}: ${lines} lines > ${max_lines}")
        [ "${bytes}" -gt "${max_bytes}" ] && viol+=("${file}: ${bytes} bytes > ${max_bytes}")
        block_report="$(_ci_measure_run_blocks "${file}")" || {
            ci_log "[CI-ERROR-CHECK-0122]" "file=\"${file}\" reason=\"run blocks not measurable (raw above)\""; return 2; }
        while IFS=$'\t' read -r block_line block_bytes; do
            [ -n "${block_line}" ] || continue
            [ "${block_bytes}" -gt "${max_block}" ] && \
                viol+=("${file}:${block_line}: run-block ${block_bytes} bytes > ${max_block}")
        done <<<"${block_report}"
    done
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
    project_number="$(_ci_block_entry_field pr_policy "" project_number)" || return 2
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
    for w in "${warns[@]:-}"; do [ -n "${w}" ] && ci_log "[CI-WARN-CHECK-0114]" "pr=\"${pr_number}\" warn=\"${w}\""; done
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

# What: True if a branch is a SOT long-lived branch.
# Why: exact names first, then the SOT POSIX ERE list.
# From: Issue #1683 | PR #1858
_ci_branch_long_lived() {
    local branch="$1" exact="$2" regexes="$3" hit re
    hit="$(_ci_capture 1 grep -xF -- "${branch}" <<< "${exact}")" || return 2
    [ -z "${hit}" ] || return 0
    while IFS= read -r re; do
        [ -n "${re}" ] || continue
        hit="$(_ci_capture 1 grep -E -e "${re}" <<< "${branch}")" || return 2
        [ -z "${hit}" ] || return 0
    done <<< "${regexes}"
    return 1
}

# What: Print each name not referenced in a text file.
# Why: ref grammar bounds a name; no substring false hit.
# From: Issue #1683 | PR #1858
_ci_unreferenced_names() {
    local wanted="$1" file="$2" out
    # What: bound = start/end or a char no ref holds.
    # Why: git-check-ref-format; prose quotes also bound.
    # From: Issue #1683 | PR #1858
    if ! out="$(awk -v names="${wanted}" -v q="'" '
        function bound(c) { return c == "" || c == q || index(" \t\n~^:?*[]\\`\"(),<>;!", c) > 0 }
        BEGIN { n = split(names, want, "\n") }
        { text = text $0 "\n" }
        END {
            for (i = 1; i <= n; i++) {
                w = want[i]; hit = 0; from = 1
                if (w == "") continue
                while (!hit && (p = index(substr(text, from), w)) > 0) {
                    s = from + p - 1; e = s + length(w)
                    a = substr(text, e, 1)
                    if (a == "." || a == "/") a = substr(text, e + 1, 1)
                    if (bound(s > 1 ? substr(text, s - 1, 1) : "") && bound(a)) hit = 1
                    from = s + 1
                }
                if (!hit) print w
            }
        }
    ' "${file}" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0140]" "file=\"${file}\" reason=\"reference match failed\"" "${out}"
        return 2
    fi
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: AG-GH-017 sweep: old work branch, no PR or issue.
# Why: repo-wide by nature (docs §98); a finding is rc 1.
# From: Issue #1683 | PR #1858
_ci_check_orphaned_branches() {
    local repo min_age now exact regexes raw rows rc=0
    repo="$(_ci_repo)" || return 2
    if [ -z "${GH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-CHECK-0130]" "repo=\"${repo}\" reason=\"GH_TOKEN is required\""
        return 2
    fi
    min_age="$(_ci_block_entry_field branch_policy "" orphan_min_age_seconds)" || return 2
    if ! [[ "${min_age}" =~ ^[0-9]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0131]" "value=\"${min_age}\" reason=\"no numeric SOT branch_policy.orphan_min_age_seconds\""
        return 2
    fi
    # What: long-lived = channel refs + branch_policy lists.
    # Why: release.channels owns master; no second literal.
    # From: Issue #1683 | PR #1858
    raw="$(_ci_channel_field ref)" || return 2
    exact="$(awk '$2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2 }' <<< "${raw}")"
    raw="$(_ci_block_entry_list branch_policy "" long_lived)" || return 2
    exact+=$'\n'"${raw}"
    regexes="$(_ci_block_entry_list branch_policy "" long_lived_regex)" || return 2
    if [ -z "${exact//[[:space:]]/}" ]; then
        ci_log "[CI-ERROR-CHECK-0132]" "reason=\"no long-lived branch in the SOT; FAIL CLOSED\""
        return 2
    fi
    # What: one paged query: tip date and PR count per ref.
    # Why: GraphQL budget, not REST; PRs in any state count.
    # From: Issue #1683 | PR #1858
    raw="$(_ci_retry github-api gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" \
        -f query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) { nodes { name target { ... on Commit { committedDate author { name } } } associatedPullRequests { totalCount } } pageInfo { hasNextPage endCursor } } } }')" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-CHECK-0133]" "repo=\"${repo}\" rc=${rc} reason=\"branch listing failed (raw above)\""
        return 2
    fi
    if ! rows="$(jq -r '.data.repository.refs.nodes[] | [.name, .target.committedDate, (.target.committedDate | fromdateiso8601), .associatedPullRequests.totalCount, (.target.author.name // "")] | @tsv' <<< "${raw}" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0135]" "repo=\"${repo}\" reason=\"branch listing unparseable\"" "${rows}"$'\n'"response:"$'\n'"${raw}"
        return 2
    fi
    now="$(date -u +%s)"
    local branch iso epoch prs author live scanned=0 old=0
    local -a noprs=()
    local -A when=() who=()
    while IFS=$'\t' read -r branch iso epoch prs author; do
        [ -n "${branch}" ] || continue
        scanned=$((scanned + 1))
        if ! [[ "${epoch}" =~ ^[0-9]+$ && "${prs}" =~ ^[0-9]+$ ]]; then
            ci_log "[CI-ERROR-CHECK-0134]" "branch=\"${branch}\" epoch=\"${epoch}\" prs=\"${prs}\" reason=\"malformed branch row\""
            return 2
        fi
        [ $((now - epoch)) -ge "${min_age}" ] || continue
        live=0
        _ci_branch_long_lived "${branch}" "${exact}" "${regexes}" || live=$?
        [ "${live}" -ne 2 ] || return 2
        [ "${live}" -ne 0 ] || continue
        old=$((old + 1))
        [ "${prs}" -eq 0 ] || continue
        noprs+=("${branch}"); when["${branch}"]="${iso}"; who["${branch}"]="${author}"
    done <<< "${rows}"
    if [ "${#noprs[@]}" -eq 0 ]; then
        printf 'orphaned-branches=clean scanned=%s checked=%s no_pr=0\n' "${scanned}" "${old}"
        return 0
    fi
    # What: bodies + comments of issues in any state.
    # Why: AG-GH-017 needs an issue link; no PR data here.
    # From: Issue #1683 | PR #1858
    local corpus out="" more="" n
    corpus="$(_ci_mktemp "${CI_TMPDIR}/ci-orphan-corpus.XXXXXX")" || return 2
    raw="$(_ci_retry github-api gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" \
        -f query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { issues(first: 100, after: $endCursor) { nodes { number body comments(first: 100) { nodes { body } pageInfo { hasNextPage } } } pageInfo { hasNextPage endCursor } } } }')" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-CHECK-0136]" "repo=\"${repo}\" rc=${rc} reason=\"issue listing failed (raw above)\""
        rm -f "${corpus}"
        return 2
    fi
    if ! out="$(jq -r '.data.repository.issues.nodes[] | (.body // empty), (.comments.nodes[].body // empty)' <<< "${raw}" 2>&1 > "${corpus}")" \
        || ! more="$(jq -r '.data.repository.issues.nodes[] | select(.comments.pageInfo.hasNextPage) | .number' <<< "${raw}" 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0137]" "repo=\"${repo}\" corpus=\"${corpus}\" reason=\"issue data unparseable or unwritable\"" "${out}"$'\n'"${more}"
        rm -f "${corpus}"
        return 2
    fi
    # What: page the rest of a thread over 100 comments.
    # Why: a cut-off thread could hide the branch reference.
    # From: Issue #1683 | PR #1858
    while IFS= read -r n; do
        [ -n "${n}" ] || continue
        raw="$(_ci_retry github-api gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="${n}" \
            -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { issue(number: $number) { comments(first: 100, after: $endCursor) { nodes { body } pageInfo { hasNextPage endCursor } } } } }')" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            ci_log "[CI-ERROR-CHECK-0138]" "repo=\"${repo}\" issue=${n} rc=${rc} reason=\"issue comment listing failed (raw above)\""
            rm -f "${corpus}"
            return 2
        fi
        if ! out="$(jq -r '.data.repository.issue.comments.nodes[] | .body // empty' <<< "${raw}" 2>&1 >> "${corpus}")"; then
            ci_error "[CI-ERROR-CHECK-0141]" "repo=\"${repo}\" issue=${n} corpus=\"${corpus}\" reason=\"issue comments unparseable or unwritable\"" "${out}"
            rm -f "${corpus}"
            return 2
        fi
    done <<< "${more}"
    out="$(_ci_unreferenced_names "$(printf '%s\n' "${noprs[@]}")" "${corpus}")" || rc=$?
    rm -f "${corpus}"
    [ "${rc}" -eq 0 ] || return 2
    if [ -z "${out}" ]; then
        printf 'orphaned-branches=clean scanned=%s checked=%s no_pr=%s\n' "${scanned}" "${old}" "${#noprs[@]}"
        return 0
    fi
    local -a found=()
    while IFS= read -r branch; do
        found+=("branch=\"${branch}\" last_commit=${when[${branch}]} author=\"${who[${branch}]}\"")
    done <<< "${out}"
    ci_error "[CI-ERROR-CHECK-0139]" "orphaned=${#found[@]} scanned=${scanned} checked=${old} reason=\"AG-GH-017: no PR and no issue reference\"" "$(printf '%s\n' "${found[@]}")"
    return 1
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
    local wf_dir act_dir
    wf_dir="$(_ci_repo_path CI_WORKFLOW_DIR "${repo_root}")" || return 2
    act_dir="$(_ci_repo_path CI_ACTIONS_DIR "${repo_root}")" || return 2
    local -a wf_files=() act_files=() scan_files=()
    local f
    _ci_workflow_files wf_files "${wf_dir}" || return 2
    _ci_workflow_files act_files "${act_dir}" actions || return 2
    scan_files=("${wf_files[@]}" "${act_files[@]}")

    local -a viol=() xv=() infra=() uses_entries=() literal_entries=()
    # What: collect every uses: step, resolve anchors.
    # Why: alias not duplicate; only literals count.
    # From: Issue #1683 | PR #1858
    local sf line raw resolved anchor
    for sf in "${scan_files[@]}"; do
        local -A anchors=()
        local produced produced_rc=0
        produced="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "${sf}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
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
        done <<<"${produced}"
        unset anchors
    done

    local -a uses_values=()
    local produced produced_rc=0
    produced="$(printf '%s\n' "${uses_entries[@]}" | sed $'s/^[^\t]*\t//' | sort -u)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    mapfile -t uses_values <<<"${produced}"
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
            using="$(_ci_action_runs_using < "${resolved_file}")" || {
                ci_log "[CI-ERROR-CHECK-0121]" "file=\"${resolved_file}\" action=\"${v}\" reason=\"action manifest not readable (raw above)\""; return 2; }
            [ -z "${using}" ] && { viol+=("local action '${v}' has no parseable runs.using"); continue; }
            case "${_ci_action_deprecated_runtimes}" in
                *" ${using} "*) viol+=("local action '${v}' declares runs.using: ${using}, a deprecated Node runtime") ;;
            esac
            continue
        fi
        # What: a docker:// step must pin a SOT base image.
        # Why: the workflow literal is no second pin owner.
        # From: Issue #1683 | PR #1858
        if [[ "${v}" == docker://* ]]; then
            local bkeys bk bv bhit=0
            bkeys="$(_ci_block_keys base_images all)" || return 2
            for bk in ${bkeys}; do
                bv="$(_ci_block_entry_field base_images "" "${bk}")" || return 2
                [ "${bv}" != "${v#docker://}" ] || bhit=1
            done
            [ "${bhit}" -eq 1 ] || viol+=("docker step '${v}' (in: $(_ci_ando_reffiles "${v}")) is not a SOT base_images pin")
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

# What: Print "<issue|pr>\t<open|closed>" for a number.
# Why: /issues/N also serves PRs; callers must tell apart.
# From: Issue #1683 | PR #1858
_ci_issue_meta() {
    local issue="$1" repo meta
    repo="$(_ci_repo)" || return 2
    meta="$(_ci_retry github-api gh api "repos/${repo}/issues/${issue}" \
        --jq '[(if has("pull_request") then "pr" else "issue" end), .state] | @tsv')" || return 2
    case "${meta}" in
        issue$'\t'open|issue$'\t'closed|pr$'\t'open|pr$'\t'closed) printf '%s\n' "${meta}" ;;
        *) ci_log "[CI-ERROR-CHECK-0074]" "issue=\"${issue}\" meta=\"${meta}\" reason=\"unexpected issue kind or state\""; return 2 ;;
    esac
}

# What: Print each issue ref a closing keyword names.
# Why: GitHub grammar: keyword[:] #N or owner/repo#N.
# From: Issue #1683 | PR #1858
_ci_closing_refs() {
    local text="$1" out
    # What: skip a match negated by not/never/cannot/n't.
    # Why: negated prose must never close an issue.
    # From: Issue #1496 | PR #1858
    if ! out="$(awk -v q="'" '
        function negated(w,  n, i, k, words, at) {
            n = split("not never cannot n" q "t", words, " ")
            for (k = 1; k <= n; k++) {
                at = 0
                while ((i = index(substr(w, at + 1), words[k])) > 0) {
                    at += i
                    if ((k == n || at == 1 || substr(w, at - 1, 1) !~ /[a-z0-9_]/) && \
                        length(w) - (at + length(words[k]) - 1) <= 20 && \
                        substr(w, at + length(words[k]), 1) !~ /[a-z0-9_]/) return 1
                }
            }
            return 0
        }
        { t = t $0 "\n" }
        END {
            low = tolower(t); pos = 1
            re = "(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[ \t\n]+([a-z0-9_.-]+/[a-z0-9_.-]+)?#[0-9]+"
            while (match(substr(low, pos), re)) {
                s = pos + RSTART - 1; m = substr(low, s, RLENGTH); pos = s + RLENGTH
                if (s > 1 && substr(low, s - 1, 1) ~ /[a-z0-9_]/) continue
                w = substr(low, 1, s - 1); sub(/^.*[.!?\n]/, "", w)
                if (negated(w)) continue
                sub(/^[a-z]+:?[ \t\n]+/, "", m); print m
            }
        }
    ' <<< "${text}" 2>&1)"; then
        ci_error "[CI-ERROR-LINK-0001]" "reason=\"closing keyword parse failed\"" "${out}"
        return 2
    fi
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: post an issue/PR comment; compare what GitHub stored
# Why: AG-WF-031: a GitHub write is read back and verified
# From: Issue #1683 | PR #1858
_ci_issue_comment() {
    local id="$1" repo="$2" n="$3" file="$4" out want
    out="$(_ci_retry github-api gh api -X POST --jq .body "repos/${repo}/issues/${n}/comments" -F body=@"${file}")" || return 2
    want="$(<"${file}")"
    if [ "${out}" != "${want}" ]; then
        ci_error "${id}" "repo=\"${repo}\" number=${n} reason=\"stored comment differs from the sent text\"" "${out}"
        return 2
    fi
}

# What: welcome an author's first issue or first PR
# Why: first contact gets the SOT rules text; bots skip
# From: Issue #1683 | PR #1858
ci_cmd_welcome() {
    local event repo row kind n sender stype oldest raw file err
    event="$(_ci_env_required GITHUB_EVENT_PATH)" || return 2
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    row="$(_ci_capture 0 jq -r '[(if .pull_request then "pr" elif .issue then "issue" else "none" end),
        ((.pull_request.number // .issue.number // "") | tostring), (.sender.login // ""), (.sender.type // "")] | @tsv' "${event}")" || return 2
    IFS=$'\t' read -r kind n sender stype <<< "${row}"
    if [ "${kind}" = none ]; then
        printf 'welcome=skip reason="not an issue or pull request event"\n'
        return 0
    fi
    if [ -z "${sender}" ]; then
        ci_error "[CI-ERROR-WELCOME-0001]" "kind=${kind} number=${n} reason=\"payload has no sender login\"" "${row}"
        return 2
    fi
    if [ "${stype}" = Bot ]; then
        printf 'welcome=skip kind=%s number=%s reason="bot author"\n' "${kind}" "${n}"
        return 0
    fi
    # What: login and number must match GitHub's grammar.
    # Why: both go into a search query and an API path.
    # From: Issue #1683 | PR #1858
    if [[ ! "${sender}" =~ ^[A-Za-z0-9](-?[A-Za-z0-9])*$ ]] || [[ ! "${n}" =~ ^[1-9][0-9]*$ ]]; then
        ci_error "[CI-ERROR-WELCOME-0002]" "kind=${kind} reason=\"sender or number outside the GitHub grammar\"" "${row}"
        return 2
    fi
    oldest="$(_ci_retry github-api gh api -X GET --jq '.items[0].number // empty' search/issues \
        -f q="repo:${repo} author:${sender} is:${kind}" -f sort=created -f order=asc -f per_page=1)" || return 2
    if [ -n "${oldest}" ] && [[ ! "${oldest}" =~ ^[0-9]+$ ]]; then
        ci_error "[CI-ERROR-WELCOME-0003]" "kind=${kind} number=${n} reason=\"search gave no issue number\"" "${oldest}"
        return 2
    fi
    if [ -n "${oldest}" ] && [ "${oldest}" -lt "${n}" ]; then
        printf 'welcome=skip kind=%s number=%s reason="author has an older %s (#%s)"\n' "${kind}" "${n}" "${kind}" "${oldest}"
        return 0
    fi
    raw="$(_ci_block_entry_list pr_policy "" "welcome_${kind}")" || return 2
    if [ -z "${raw}" ]; then
        ci_log "[CI-ERROR-WELCOME-0004]" "kind=${kind} reason=\"no SOT pr_policy.welcome_${kind} text\""
        return 2
    fi
    file="$(_ci_mktemp "${CI_TMPDIR}/ci-welcome.XXXXXX")" || return 2
    if ! err="$(printf '%s\n' "${raw}" 2>&1 > "${file}")"; then
        ci_error "[CI-ERROR-WELCOME-0005]" "file=\"${file}\" reason=\"comment text not written\"" "${err}"
        rm -f "${file}"
        return 2
    fi
    _ci_issue_comment "[CI-ERROR-WELCOME-0006]" "${repo}" "${n}" "${file}" || { rm -f "${file}"; return 2; }
    rm -f "${file}"
    printf 'welcome=posted kind=%s number=%s\n' "${kind}" "${n}"
}

# What: Close issues a merged PR lists under Linked Issues.
# Why: GitHub auto-closes only on default-branch merges.
# From: Issue #1137 | PR #1858
ci_cmd_close_linked_issues() {
    local dry=0 number="" repo raw rows pr body base url merge heading section count refs
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            --pr) number="${2:-}"; shift 2 || { ci_log "[CI-ERROR-LINK-0002]" "reason=\"--pr needs a number\""; return 2; } ;;
            *) ci_log "[CI-ERROR-LINK-0013]" "arg=\"$1\" reason=\"unknown argument\""; return 2 ;;
        esac
    done
    repo="$(_ci_repo)" || return 2
    local fields='number merged baseRefName url body mergeCommit { oid }'
    if [ -n "${number}" ]; then
        # What: a replay of one PR never writes to GitHub.
        # Why: replays inspect the parse; they never close.
        # From: Issue #1137 | PR #1858
        if [ "${dry}" -ne 1 ] || ! [[ "${number}" =~ ^[0-9]+$ ]]; then
            ci_log "[CI-ERROR-LINK-0003]" "pr=\"${number}\" reason=\"--pr needs a numeric PR and --dry-run\""
            return 2
        fi
        raw="$(_ci_retry github-api gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="${number}" \
            -f query="query(\$owner: String!, \$name: String!, \$number: Int!) { repository(owner: \$owner, name: \$name) { pullRequest(number: \$number) { ${fields} } } }")" || return 2
        rows="$(jq -c '[.data.repository.pullRequest]' <<< "${raw}" 2>&1)" || {
            ci_error "[CI-ERROR-LINK-0004]" "pr=\"${number}\" reason=\"PR lookup unparseable\"" "${rows}"; return 2; }
    else
        local branch="${GITHUB_REF#refs/heads/}"
        if [ "${GITHUB_EVENT_NAME:-}" != push ] || [ "${branch}" = "${GITHUB_REF:-}" ]; then
            printf 'close-linked-issues=skip reason="not a branch push" event="%s" ref="%s"\n' "${GITHUB_EVENT_NAME:-}" "${GITHUB_REF:-}"
            return 0
        fi
        _ci_env_required CI_DEFAULT_BRANCH "[CI-ERROR-LINK-0005]" \
            "default=\"\" reason=\"CI_DEFAULT_BRANCH is required\"" > /dev/null || return 2
        _ci_env_required GITHUB_SHA "[CI-ERROR-LINK-0015]" \
            "sha=\"\" reason=\"GITHUB_SHA is required\"" > /dev/null || return 2
        if [ "${branch}" = "${CI_DEFAULT_BRANCH}" ]; then
            printf 'close-linked-issues=skip reason="GitHub closes on the default branch" branch="%s"\n' "${branch}"
            return 0
        fi
        raw="$(_ci_retry github-api gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -f oid="${GITHUB_SHA}" \
            -f query="query(\$owner: String!, \$name: String!, \$oid: GitObjectID!) { repository(owner: \$owner, name: \$name) { object(oid: \$oid) { ... on Commit { associatedPullRequests(first: 10) { nodes { ${fields} } } } } } }")" || return 2
        rows="$(jq -c --arg b "${branch}" --arg s "${GITHUB_SHA}" '[.data.repository.object.associatedPullRequests.nodes[] | select(.merged and .baseRefName == $b and .mergeCommit.oid == $s)]' <<< "${raw}" 2>&1)" || {
            ci_error "[CI-ERROR-LINK-0014]" "sha=\"${GITHUB_SHA}\" reason=\"PR lookup unparseable\"" "${rows}"; return 2; }
    fi
    count="$(_ci_capture 0 jq -r 'length' <<< "${rows}")" || return 2
    if [ "${count}" -eq 0 ]; then
        printf 'close-linked-issues=clean reason="no merged PR for this push" sha="%s"\n' "${GITHUB_SHA:-}"
        return 0
    fi
    if [ "${count}" -gt 1 ]; then
        ci_error "[CI-ERROR-LINK-0006]" "count=${count} reason=\"several merged PRs share this merge commit\"" "${rows}"
        return 2
    fi
    pr="$(_ci_capture 0 jq -r '.[0].number' <<< "${rows}")" || return 2
    body="$(_ci_capture 0 jq -r '.[0].body // ""' <<< "${rows}")" || return 2
    base="$(_ci_capture 0 jq -r '.[0].baseRefName' <<< "${rows}")" || return 2
    url="$(_ci_capture 0 jq -r '.[0].url' <<< "${rows}")" || return 2
    merge="$(_ci_capture 0 jq -r '.[0].mergeCommit.oid // ""' <<< "${rows}")" || return 2
    heading="$(_ci_block_entry_field pr_policy "" linked_section)" || return 2
    section="$(_ci_pr_section "${body}" "${heading}")" || return 2
    count="${section%%$'\n'*}"
    if [ "${section}" = "${count}" ]; then section=""; else section="${section#*$'\n'}"; fi
    if [ "${count}" -eq 0 ]; then
        printf 'close-linked-issues=clean pr=%s reason="no %s section"\n' "${pr}" "${heading}"
        return 0
    fi
    if [ "${count}" -gt 1 ]; then
        ci_log "[CI-ERROR-LINK-0007]" "pr=${pr} count=${count} reason=\"${heading} heading is ambiguous; nothing closed\""
        return 1
    fi
    refs="$(_ci_closing_refs "${section}")" || return 2
    refs="$(_ci_capture 0 sort -u <<< "${refs}")" || return 2
    local ref n meta comment out closed=0 skipped=0 mode="done"
    local -a failed=()
    while IFS= read -r ref; do
        [ -n "${ref}" ] || continue
        n="${ref##*#}"
        if [ "${ref%#*}" != "" ] && [ "${ref%#*}" != "${repo}" ]; then
            ci_log "[CI-NOTICE-LINK-0008]" "pr=${pr} ref=\"${ref}\" reason=\"other repository; not closed here\""
            skipped=$((skipped + 1)); continue
        fi
        meta="$(_ci_issue_meta "${n}")" || { failed+=("#${n}: lookup failed (raw above)"); continue; }
        case "${meta}" in
            pr$'\t'*) ci_log "[CI-NOTICE-LINK-0009]" "pr=${pr} ref=#${n} reason=\"is a pull request\""; skipped=$((skipped + 1)); continue ;;
            *$'\t'closed) ci_log "[CI-NOTICE-LINK-0010]" "pr=${pr} ref=#${n} reason=\"already closed\""; skipped=$((skipped + 1)); continue ;;
        esac
        if [ "${dry}" -eq 1 ]; then
            printf 'close-linked-issues=would-close pr=%s issue=%s\n' "${pr}" "${n}"
            closed=$((closed + 1)); continue
        fi
        comment="$(_ci_mktemp "${CI_TMPDIR}/ci-link-comment.XXXXXX")" || return 2
        if ! out="$(printf '## Closed via merge to `%s`\n\nCI closed this issue (`ci.sh close-linked-issues`) because GitHub closes linked issues only for merges into the default branch. Closed by PR #%s (%s), merge commit `%s`. The PR description follows verbatim.\n\n---\n\n%s\n' \
            "${base}" "${pr}" "${url}" "${merge}" "${body}" 2>&1 > "${comment}")"; then
            failed+=("#${n}: comment file not written: ${out}"); rm -f "${comment}"; continue
        fi
        if ! _ci_issue_comment "[CI-ERROR-LINK-0016]" "${repo}" "${n}" "${comment}"; then
            failed+=("#${n}: comment failed (raw above)"); rm -f "${comment}"; continue
        fi
        rm -f "${comment}"
        if ! out="$(_ci_retry github-api gh api -X PATCH --jq .state "repos/${repo}/issues/${n}" -f state=closed -f state_reason=completed)"; then
            failed+=("#${n}: close failed after the comment (raw above)"); continue
        fi
        if [ "${out}" != closed ]; then
            failed+=("#${n}: state after the close request: ${out:-empty}"); continue
        fi
        ci_log "[CI-INFO-LINK-0011]" "pr=${pr} issue=#${n} reason=\"commented and closed\""
        closed=$((closed + 1))
    done <<< "${refs}"
    if [ "${#failed[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-LINK-0012]" "pr=${pr} closed=${closed} failed=${#failed[@]} reason=\"not every linked issue was processed\"" "$(printf '%s\n' "${failed[@]}")"
        return 2
    fi
    [ "${dry}" -eq 0 ] || mode="dry-run"
    printf 'close-linked-issues=%s pr=%s closed=%s skipped=%s\n' "${mode}" "${pr}" "${closed}" "${skipped}"
}

# What: Flag stale TODOs, scope gaps, upload errors.
# Why: Guard changed files against title/body governance.
# From: Issue #1683
_ci_check_governance_guards() {
    local -a _ci_override=("$@") changed=()
    local title="${PR_TITLE:-}" body="${PR_BODY:-}"
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
            state="$(_ci_issue_meta "${issue}")" || return 2
            [ "${state#*$'\t'}" = "closed" ] && viol+=("${path}:${line}: stale TODO/FIXME references closed #${issue}")
        done <<< "${hits}"
    done
    local combined="${title}"
    [ -n "${combined}" ] && [ -n "${body}" ] && combined+=$'\n'
    combined+="${body}"
    if [ -n "${combined}" ]; then
        if grep -Eq '(^|[[:space:]])@/tmp/[^[:space:]]+' <<<"${combined}"; then
            viol+=("PR title/body: looks like a literal @/tmp/... upload path, not real body text")
        elif [[ "${combined}" == \"*\" && "${combined}" == *'\n'* && "${combined}" != *$'\n'* ]]; then
            viol+=("PR title/body: looks like JSON-quoted Markdown, not real body text")
        fi
        local stripped
        stripped="$(sed -E 's/\b(no|not|none|nothing|without)\b([[:space:]]+[[:alnum:]-]+){0,3}[[:space:]]+(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)\b//Ig' <<<"${combined}")"
        if grep -Eiq '(^|[^[:alnum:]])(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)([^[:alnum:]]|$)' <<<"${stripped}"; then
            local open_found=0 rest="${combined}"
            while [[ "${rest}" =~ Refs[[:space:]]+#([0-9]+) ]]; do
                issue="${BASH_REMATCH[1]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
                state="$(_ci_issue_meta "${issue}")" || return 2
                [ "${state#*$'\t'}" = "open" ] && { open_found=1; break; }
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
# Why: ui and watchdog call Docker by these fixed names
# From: Issue #1683 | PR #1858
_ci_check_naming_consistency() {
    local root="${1:-${CI_REPO_ROOT}}" dep inst
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${root}")" || return 2
    local -a compose_files=("${root}/${dep}")
    [ "${inst}" = "${dep}" ] || compose_files+=("${root}/${inst}")
    local cfg_rs="${root}/services/common/config.rs"
    local -a viol=()
    local -A cnames=() services=() uienv=()
    local cf cfg project name list var val

    # What: compose container names and services, rendered
    # Why: rust must name containers compose creates
    # From: Issue #1683 | PR #1858
    for cf in "${compose_files[@]}"; do
        if [ ! -f "${cf}" ]; then
            viol+=("${cf}: compose file missing")
            continue
        fi
        cfg="$(_ci_compose_json "${cf}")" || return 2
        project="$(_ci_capture 0 jq -r '.name' <<<"${cfg}")" || return 2
        [ "${project}" = lancache-ng ] || viol+=("${cf}: compose project name '${project}' is not lancache-ng")
        cnames[${cf}]="$(_ci_capture 0 jq -r '.services[].container_name // empty' <<<"${cfg}")" || return 2
        services[${cf}]="$(_ci_capture 0 jq -r '.services | keys[]' <<<"${cfg}")" || return 2
        uienv[${cf}]="$(_ci_capture 0 jq -r '.services.ui.environment // {} | to_entries[]
            | select(.key | endswith("_SERVICE")) | "\(.key)=\(.value)"' <<<"${cfg}")" || return 2
    done

    # What: rust CONTAINER_* names are compose containers
    # Why: ui and watchdog call Docker by these fixed names
    # From: Issue #1683 | PR #1905
    if [ ! -f "${cfg_rs}" ]; then
        viol+=("${cfg_rs}: container name owner missing")
    else
        list="$(_ci_capture 1 grep -oE 'const CONTAINER_[A-Z_]+: &str = "lancache-[a-z0-9-]+"' "${cfg_rs}")" || return 2
        list="$(sed -E 's/^.*"(lancache-[a-z0-9-]+)"$/\1/' <<<"${list}" | sort -u)"
        [ -n "${list}" ] || viol+=("${cfg_rs}: no CONTAINER_* names found")
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            for cf in "${!cnames[@]}"; do
                grep -qxF -- "${name}" <<<"${cnames[${cf}]}" || viol+=("${cfg_rs}: '${name}' is no container_name in ${cf}")
            done
        done <<<"${list}"
    fi

    # What: each ui *_SERVICE value is a compose service
    # Why: the ui reaches each service by this name
    # From: Issue #1683 | PR #1905
    for cf in "${!uienv[@]}"; do
        [ -n "${uienv[${cf}]}" ] || { viol+=("${cf}: the ui service sets no *_SERVICE variable"); continue; }
        while IFS='=' read -r var val; do
            grep -qxF -- "${val}" <<<"${services[${cf}]}" || viol+=("${cf}: ui ${var}='${val}' is no service")
        done <<<"${uienv[${cf}]}"
    done

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
        local f dep top
        dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
        top="${dep%/*}"; top="${top%/*}"
        for f in "${CI_REPO_ROOT}/${top}"/*/"${dep##*/}"; do
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
        local produced produced_rc=0
        produced="$(awk '
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
        ' "${file}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 0 || return 2
        while IFS=$'\t' read -r svc hc; do
            [ -n "${svc}" ] || continue
            checked=$((checked + 1))
            [ "${hc}" = "1" ] && continue
            [ -n "${excluded[${svc}]:-}" ] && continue
            viol+=("${file}: service '${svc}' has no healthcheck:")
        done <<<"${produced}"
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

# What: Fail if a proxy CACHE_* default drifts from its doc.
# Why: a hand-copied doc default silently goes stale.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cache_env_doc_drift() {
    local defaults="${1:-}" dep raw
    local arch_doc="${2:-}"
    if [ -z "${arch_doc}" ]; then arch_doc="$(_ci_repo_path CI_ARCH_DOC)" || return 2; fi
    if [ ! -f "${arch_doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0098]" "path=\"${arch_doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    local key value doc_row documented scanned=0 checked=0 rc
    local -a viol=()
    local produced produced_rc=0
    if [ -n "${defaults}" ]; then
        if [ ! -f "${defaults}" ]; then
            ci_log "[CI-ERROR-CHECK-0022]" "path=\"${defaults}\" reason=\"defaults file not found\""
            return 2
        fi
        produced="$(grep -E '^CACHE_[A-Z_]+=' "${defaults}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
    else
        # What: values compose gives proxy, own-dir .env
        # Why: env_file and environment both feed proxy
        # From: Issue #1683 | PR #1858
        dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
        if ! raw="$(_ci_compose_query "${CI_REPO_ROOT}/${dep}" "${CI_REPO_ROOT}/$(dirname "${dep}")/.env" config --format json 2>&1)"; then
            ci_error "[CI-ERROR-CHECK-0110]" "file=\"${dep}\" reason=\"deploy compose not renderable with its .env\"" "${raw}"
            return 2
        fi
        produced="$(_ci_capture 0 jq -r '.services.proxy.environment // {} | to_entries[]
            | select(.key | test("^CACHE_[A-Z_]+$")) | "\(.key)=\(.value)"' <<< "${raw}")" || return 2
    fi
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^CACHE_[A-Z_]+$ ]] || continue
        scanned=$((scanned + 1))
        doc_row="$(_ci_capture 1 grep -E "^\| \`${key}\` \|" "${arch_doc}")" || return 2
        [ -n "${doc_row}" ] || continue
        checked=$((checked + 1))
        documented="$(sed -E "s/^\| \`[A-Z_]+\` \| \`([^\`]*)\` \|.*/\1/" <<<"${doc_row}")"
        if [ "${documented}" != "${value}" ]; then
            viol+=("${key}: default=${value} vs doc=${documented}")
        fi
    done <<<"${produced}"
    if [ "${scanned}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0152]" "defaults=\"${defaults:-deploy compose}\" reason=\"no CACHE_* default found for proxy; vacuous scan\""
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0023]" "reason=\"proxy CACHE_* default/doc drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cache-env-doc-drift=clean scanned=%s checked=%s\n' "${scanned}" "${checked}"
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
    local hit su readme
    su="$(_ci_installer "${repo_root}")" || return 2
    readme="$(_ci_repo_path CI_README "${repo_root}")" || return 2
    hit="$(_ci_capture 1 grep -RIn -- '--build' "${readme}" "${dep}" "${inst}" "${su}")" || return 2
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
    local doc doc_rel
    doc_rel="$(_ci_variable CI_BACKUP_RESTORE_DOC)" || return 2
    doc="${repo_root}/${doc_rel}"
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
            || viol+=("${doc_rel} does not mention ${key}")
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
    tools="$(_ci_block_entry_list validation "" host_tools)" || return 2
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

# What: SOT validation env plus fresh secrets, KEY=VALUE.
# Why: config check and live validate share one owner.
# From: Issue #1683 | PR #1858
_ci_validation_env() {
    local fx kind keys k v n=0 flag
    fx="$(_ci_block_entry_field validation "" compose_validation_env)" || return 2
    if [ -z "${fx}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0054]" "reason=\"no SOT validation.compose_validation_env\""
        return 2
    fi
    tr ' ' '
' <<< "${fx}" | grep -v '^$'
    # What: a fresh value per secret key, setup.sh format.
    # Why: a fixed key in the SOT is a hardcoded credential.
    # From: Issue #1683 | PR #1858
    for kind in hex32 base64_32; do
        case "${kind}" in hex32) flag=-hex ;; base64_32) flag=-base64 ;; esac
        keys="$(_ci_block_entry_list validation compose_validation_secrets "${kind}")" || return 2
        for k in ${keys}; do
            v="$(_ci_run "[CI-ERROR-VALIDATE-0100]" "key=\"${k}\" kind=\"${kind}\" reason=\"secret not generated\"" \
                openssl rand "${flag}" 32)" || return 2
            printf '%s=%s\n' "${k}" "${v//$'\n'/}"
            n=$((n + 1))
        done
    done
    if [ "${n}" -eq 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0101]" "reason=\"no SOT validation.compose_validation_secrets\""
        return 2
    fi
}

# What: repo root joined with a SOT path variable.
# Why: paths are SOT truths; ci.sh holds no path literal.
# From: Issue #1683 | PR #1858
_ci_repo_path() {
    local name="$1" root="${2:-${CI_REPO_ROOT:-.}}" rel
    rel="$(_ci_variable "${name}")" || return 2
    printf '%s/%s\n' "${root}" "${rel}"
}

# What: [root/]SOT context/file; root "" = relative.
# Why: service paths derive from the SOT, not services/x.
# From: Issue #1683 | PR #1858
_ci_service_path() {
    local svc="$1" rel="$2" root="${3-${CI_REPO_ROOT:-.}}" ctx
    ctx="$(_ci_required_field "${svc}" context)" || return 2
    printf '%s%s/%s\n' "${root:+${root}/}" "${ctx}" "${rel}"
}

# What: the installer's absolute path (SOT CI_INSTALLER).
# Why: one owner for the path and its existence check.
# From: Issue #1683 | PR #1858
_ci_installer() {
    local p
    p="$(_ci_repo_path CI_INSTALLER "${1:-}")" || return 2
    if [ ! -f "${p}" ]; then
        ci_log "[CI-ERROR-CORE-0102]" "path=\"${p}\" reason=\"installer not found\""
        return 2
    fi
    printf '%s\n' "${p}"
}

# What: the one sed -n match in a file; rc 1 if not one
# Why: one reader for values a product file owns
# From: Issue #1683 | PR #1858
_ci_file_value() {
    local file="$1" expr="$2" out
    out="$(_ci_capture 0 sed -nE "${expr}" "${file}")" || return 2
    printf '%s\n' "${out}"
    [[ -n "${out}" && "${out}" != *$'\n'* ]]
}

# What: elements of the one NAME=( ... ) array in a file
# Why: product scripts own their lists; CI reads them
# From: Issue #1683 | PR #1858
_ci_shell_array() {
    local file="$1" name="$2"
    _ci_capture 0 awk -v n="${name}" '
        $0 == n "=(" { on = 1; c++; next }
        on && $0 == ")" { on = 0; next }
        on { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }
        END { if (c != 1) exit 3 }' "${file}"
}

# What: literal NAME= value from the proxy entrypoint
# Why: the entrypoint owns proxy paths and relay ports
# From: Issue #1683 | PR #1858
_ci_proxy_constant() {
    local name="$1" ep="${2:-}" raw re='^"?([^"$[:space:]]+)"?$'
    [ -n "${ep}" ] || ep="$(_ci_service_path proxy entrypoint.sh)" || return 2
    raw="$(_ci_file_value "${ep}" "s/^${name}=//p")" || [ "$?" -eq 1 ] || return 2
    if [[ ! "${raw}" =~ ${re} ]]; then
        ci_error "[CI-ERROR-CORE-0129]" "path=\"${ep}\" name=\"${name}\" reason=\"need exactly one literal assignment\"" "${raw}"
        return 2
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# What: TCP port of a service name from the services db
# Why: http/https ports belong to the OS, not to CI
# From: Issue #1683 | PR #1858
_ci_service_port() {
    local name="$1" out port
    out="$(_ci_capture 0 getent services "${name}/tcp")" || return 2
    read -r _ port _ <<< "${out}"
    if [[ ! "${port}" =~ ^([0-9]+)/tcp$ ]]; then
        ci_error "[CI-ERROR-CORE-0130]" "service=\"${name}\" reason=\"no TCP port in the services db\"" "${out}"
        return 2
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# What: compose file setup.sh installs, read from setup.sh.
# Why: the installer owns its compose; CI only derives it.
# From: Issue #1683 | PR #1858
_ci_installer_compose() {
    local root="${1:-${CI_REPO_ROOT}}" su line
    local re='^"\$SCRIPT_DIR/([^"$]+)"$'
    su="$(_ci_installer "${root}")" || return 2
    line="$(_ci_file_value "${su}" 's/^PROD_COMPOSE=//p')" || {
        [ "$?" -eq 1 ] || return 2
        ci_error "[CI-ERROR-CORE-0104]" "path=\"${su}\" reason=\"PROD_COMPOSE missing or assigned twice\"" "${line}"
        return 2
    }
    if [[ ! "${line}" =~ ${re} ]]; then
        ci_error "[CI-ERROR-CORE-0105]" "path=\"${su}\" reason=\"PROD_COMPOSE is not SCRIPT_DIR-relative\"" "${line}"
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

# What: a compose file as JSON, all profiles, opt env file
# Why: a profiled service is checked like any other.
# From: Issue #1683 | PR #1858
_ci_compose_json() {
    local flags
    local -a pf=()
    flags="$(_ci_compose_profile_flags "$1")" || return 2
    [ -z "${flags}" ] || mapfile -t pf <<< "${flags}"
    _ci_compose_query "$1" "${2:-}" "${pf[@]}" config --no-env-resolution --format json
}

# What: copy a rendered file over its target on a change
# Why: derived files are rewritten only when content moves
# From: Issue #1683 | PR #1858
_ci_copy_if_changed() {
    local out
    if cmp -s "$1" "$2"; then
        printf 'unchanged\n'
        return 0
    fi
    if ! out="$(cp "$1" "$2" 2>&1)"; then
        printf '%s\n' "${out}"
        return 2
    fi
    printf 'written\n'
}

# What: SOT operation -> Docker Engine API method, path
# Why: the policy names operations, haproxy matches paths
# From: Issue #1683 | PR #1858
_ci_socket_proxy_api() {
    printf '%s\n' '[["inspect","get","json"],["logs","get","logs"],["restart","post","restart"],["start","post","start"],["stop","post","stop"],["wait","post","wait"]]'
}

# What: haproxy config granting exactly the SOT API calls
# Why: deny by default; names and port come from compose
# From: Issue #1683 | PR #1858
_ci_socket_proxy_render() {
    local cfg="$1" field list fields api policy='{}'
    local -a names=()
    api="$(_ci_socket_proxy_api)"
    fields="$(_ci_capture 0 jq -r '.[][0]' <<<"${api}")" || return 2
    mapfile -t names <<< "${fields}"
    for field in "${names[@]}" endpoints timeouts; do
        list="$(_ci_block_entry_list external_services docker-socket-proxy "${field}")" || return 2
        policy="$(_ci_capture 0 jq -c --arg f "${field}" --arg l "${list}" \
            '.[$f] = ($l | split("\n") | map(select(length > 0)))' <<<"${policy}")" || return 2
    done
    _ci_capture 0 jq -r --argjson p "${policy}" --argjson api "${api}" '
        def fail(m): error("socket-proxy: " + m);
        def re: gsub("\\."; "\\.");
        .services as $s
        | ($s.ui.environment.DOCKER_PROXY_URL // fail("ui has no DOCKER_PROXY_URL")) as $url
        | (($url | capture(":(?<n>[0-9]+)/?$") | .n) // fail("no port in DOCKER_PROXY_URL \($url)")) as $port
        | [($s["docker-socket-proxy"].volumes // [])[]
            | select(.type == "bind" and (.target | endswith(".sock"))) | .target] as $socks
        | (if ($socks | length) == 1 then $socks[0]
            else fail("need one .sock bind, found \($socks | length)") end) as $sock
        | [$api[] | . as [$op, $m, $tail]
            | [($p[$op] // [])[] | . as $svc
                | ($s[$svc].container_name // fail("SOT service \($svc) has no compose container_name")) | re] as $n
            | select($n | length > 0)
            | {acl: $op, m: $m, re: "/containers/(\($n | join("|")))/\($tail)"}]
          + (if ($p.endpoints | length) > 0
              then [{acl: "endpoints", m: "get", re: "/(\($p.endpoints | map(re) | join("|")))"}] else [] end)
          as $rules
        | (if ($rules | length) == 0 then fail("the SOT grants no Docker API call") else . end)
        | (if ($p.timeouts | length) == 0 then fail("the SOT sets no haproxy timeouts") else . end)
        | (["global", "    log stdout format raw daemon info", "", "defaults", "    mode http",
            "    log global", "    option httplog", "    option dontlognull", "    option http-server-close"]
          + [$p.timeouts[] | "    timeout \(.)"]
          + ["", "backend dockerbackend", "    server dockersocket \($sock)", "",
             "frontend dockerfrontend", "    bind [::]:\($port) v4v6", "    acl get method GET",
             "    acl post method POST"]
          + [$rules[] | "    acl \(.acl) path,url_dec -m reg -i ^(/v[0-9.]+)?\(.re)$"]
          + [$rules[] | "    http-request allow if \(.m) \(.acl)"]
          + ["    http-request deny", "    default_backend dockerbackend"])
        | join("\n")' <<<"${cfg}"
}

# What: host path of the config haproxy loads via -f
# Why: compose owns that mount; the writer follows it
# From: Issue #1683 | PR #1858
_ci_socket_proxy_target() {
    _ci_capture 0 jq -r '
        def fail(m): error("socket-proxy: " + m);
        .services["docker-socket-proxy"] as $d
        | ($d.entrypoint // []) as $e
        | [range(0; ($e | length) - 1) as $i | select($e[$i] == "-f") | $e[$i + 1]] as $f
        | (if ($f | length) == 1 then $f[0] else fail("entrypoint needs one haproxy -f path") end) as $path
        | [($d.volumes // [])[] | select(.type == "bind") | . as $v
            | if $v.target == $path then $v.source
              elif ($path | startswith($v.target + "/")) then $v.source + ($path | ltrimstr($v.target))
              else empty end] as $hits
        | if ($hits | length) == 1 then $hits[0] else fail("no single bind mount holds \($path)") end' <<<"$1"
}

# What: write the socket-proxy allowlist to its mount
# Why: setup.sh and validate start the proxy on this file
# From: Issue #1683 | PR #1858
ci_cmd_socket_proxy_config() {
    local file="${1:-}" env_file="${2:-}" cfg body target tmp out st
    if [ -z "${file}" ]; then
        ci_log "[CI-ERROR-SOCKETPROXY-0001]" "reason=\"usage: ci.sh socket-proxy-config <compose-file> [env-file]\""
        return 2
    fi
    cfg="$(_ci_compose_json "${file}" "${env_file}")" || return 2
    body="$(_ci_socket_proxy_render "${cfg}")" || return 2
    target="$(_ci_socket_proxy_target "${cfg}")" || return 2
    if ! out="$(mkdir -p "${target%/*}" 2>&1)"; then
        ci_error "[CI-ERROR-SOCKETPROXY-0002]" "dir=\"${target%/*}\" reason=\"config dir not created\"" "${out}"
        return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-socket-proxy.XXXXXX")" || return 2
    if ! out="$(printf '%s\n' "${body}" 2>&1 > "${tmp}")"; then
        ci_error "[CI-ERROR-SOCKETPROXY-0003]" "path=\"${tmp}\" reason=\"config not rendered\"" "${out}"
        rm -f "${tmp}"
        return 2
    fi
    if ! st="$(_ci_copy_if_changed "${tmp}" "${target}")"; then
        ci_error "[CI-ERROR-SOCKETPROXY-0004]" "path=\"${target}\" reason=\"config not written\"" "${st}"
        rm -f "${tmp}"
        return 2
    fi
    rm -f "${tmp}"
    printf 'socket-proxy-config=%s path=%s\n' "${st}" "${target}"
}

# What: every stack compose renders clean in every profile.
# Why: profiles come from the file; none is skipped.
# From: Issue #1683 | PR #1858
_ci_check_compose_config() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=() pairs=() profiles=()
    local deploy targets envtargets rel mode pair cf ef raw p label render msg count=0
    deploy="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    targets="$(_ci_block_entry_field validation "" compose_targets)" || return 2
    if [ -z "${targets}" ]; then
        ci_error "[CI-ERROR-CHECK-0044]" "reason=\"no compose_targets in SOT\"" "manifest=${CI_MANIFEST}"
        return 1
    fi
    envtargets="$(_ci_block_entry_field validation "" compose_env_file_targets)" || return 2
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
    local cf dep inst ep su
    ep="$(_ci_service_path dns entrypoint.sh "${repo_root}")" || return 2
    su="$(_ci_installer "${repo_root}")" || return 2
    ep="${ep#"${repo_root}/"}" su="${su#"${repo_root}/"}"
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    # What: nats bootstrap stages, chowns, then renames.
    # Why: a restart must keep nats.conf whole and writable.
    # From: Issue #426
    for cf in "${dep}" "${inst}"; do
        grep -Fq 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must stage the shared config in a temp file inside /etc/nats")
        grep -Fq 'chown 10001:10001 "$$tmp_nats_conf"' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must restore shared config ownership to 10001 after writing")
        grep -Fq 'mv "$$tmp_nats_conf" /etc/nats/nats.conf' "${repo_root}/${cf}" \
            || viol+=("${cf}: NATS must atomically replace nats.conf after fixing ownership")
    done
    # What: dns renders its configs via the atomic helper.
    # Why: a torn pdns or recursor config breaks DNS.
    # From: Issue #475
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
    # What: the secondary's files go through atomic writers.
    # Why: a torn compose or .env breaks the secondary.
    # From: Issue #475
    grep -Fq 'write_file_atomically "${secondary_dir}/docker-compose.yml"' "${repo_root}/${su}" \
        || viol+=("${su}: secondary setup must atomically write generated docker-compose.yml")
    grep -Fq 'write_file_atomically "${secondary_dir}/.env"' "${repo_root}/${su}" \
        || viol+=("${su}: secondary setup must atomically write generated .env")
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
    local -a viol=() files=()
    local cf dep inst out
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    files=("${dep}")
    [ "${inst}" = "${dep}" ] || files+=("${inst}")
    for cf in "${files[@]}"; do
        # What: ui/watchdog start once their deps started.
        # Why: a dep health flap must not stop them.
        # From: Issue #763 | PR #1858
        local cfg deps line
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        deps="$(_ci_capture 0 jq -r '.services as $s
            | ("ui", "watchdog") as $n | ($s[$n].depends_on // {}) as $d
            | (if ($d["docker-socket-proxy"].condition // "none") != "service_started"
                then "\($n) must depend on docker-socket-proxy with service_started" else empty end),
              ($d | to_entries[] | select(.value.condition == "service_healthy")
                | "\($n) waits for \(.key) to be healthy; use service_started")' <<<"${cfg}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${cf}: ${line}")
        done <<<"${deps}"
        # What: haproxy runs the SOT policy's config
        # Why: a missing service or mount stops the start
        # From: Issue #1683 | PR #1858
        out="$(_ci_capture 0 jq -r '.services["docker-socket-proxy"].entrypoint[0] // ""' <<<"${cfg}")" || return 2
        [ "${out}" = haproxy ] || viol+=("${cf}: docker-socket-proxy entrypoint is '${out}', not haproxy")
        out="$(_ci_socket_proxy_target "${cfg}" 2>&1)" || viol+=("${cf}: ${out}")
        out="$(_ci_socket_proxy_render "${cfg}" 2>&1)" || viol+=("${cf}: ${out}")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0046]" "reason=\"docker socket proxy allowlist violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'docker-socket-proxy=clean\n'
}

# What: netdata-net holds netdata and the ui, nothing else.
# Why: any other member could reach the netdata API.
# From: Issue #1683 | PR #1858
_ci_check_netdata_isolation() {
    local repo_root="${1:-${CI_REPO_ROOT}}" cf dep inst cfg out line
    local -a viol=()
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    for cf in "${dep}" "${inst}"; do
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        out="$(_ci_capture 0 jq -r '
            [.services | to_entries[] | select((.value.networks // {}) | has("netdata-net")) | .key] as $m
            | (if ($m | sort) != ["netdata", "ui"]
                then "netdata-net members must be netdata and ui (got: \($m | sort | join(",")))" else empty end),
              ((.services.netdata.networks // {}) | keys | select(. != ["netdata-net"])
                | "netdata must join netdata-net only (got: \(join(",")))")' <<<"${cfg}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${cf}: ${line}")
        done <<<"${out}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0146]" "reason=\"netdata network isolation violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'netdata-isolation=clean\n'
}

# What: /healthz ACL order and ignored-header hiding.
# Why: a bare return skips the ACL; ignored headers leak.
# From: Issue #1683 | PR #1858
_ci_check_proxy_nginx_policy() {
    local repo_root="${1:-${CI_REPO_ROOT}}" f out line pp first="" blocks=0 b h a d al r px
    local -a viol=()
    px="$(_ci_service_path proxy "" "${repo_root}")" || return 2
    px="${px%/}"
    for f in "${px}"/conf.d/*.conf; do
        out="$(_ci_capture 0 awk '
            /^[[:space:]]*location = \/healthz \{/ { inb = 1; n++; body = ""; a = 0; d = 0; al = 0; r = 0; next }
            inb && /^[[:space:]]*\}/ {
                printf "%s|%d|%d|%d|%d\n", body, a, d, al, r; inb = 0; next }
            inb { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); gsub(/[[:space:]]+/, " ", line)
                body = body line ";"
                if (line ~ /^allow /) { a++; if (d) d = -1 }
                if (line == "deny all;") { if (d == 0) d = 1 }
                if (line ~ /^alias /) al = 1
                if (line ~ /^return /) r = 1 }' "${f}")" || return 2
        while IFS='|' read -r b line; do
            [ -n "${b}" ] || continue
            blocks=$((blocks + 1))
            IFS='|' read -r a d al r <<<"${line}"
            [ "${a}" -ge 1 ] && [ "${d}" -eq 1 ] || viol+=("${f#"${repo_root}/"}: /healthz needs allow lines followed by deny all")
            [ "${al}" -eq 1 ] && [ "${r}" -eq 0 ] || viol+=("${f#"${repo_root}/"}: /healthz must serve via alias, never return (return skips the ACL)")
            [ -n "${first}" ] || first="${b}"
            [ "${b}" = "${first}" ] || viol+=("${f#"${repo_root}/"}: /healthz differs from the first block")
        done <<<"${out}"
    done
    [ "${blocks}" -gt 0 ] || viol+=("${px#"${repo_root}/"}/conf.d: no /healthz block found")
    pp="${px}/proxy-params.conf"
    out="$(_ci_capture 0 awk '
        $1 == "proxy_ignore_headers" { for (i = 2; i <= NF; i++) { h = $i; sub(/;$/, "", h); ign[h] = 1 } }
        $1 == "proxy_hide_header" { h = $2; sub(/;$/, "", h); hid[h] = 1 }
        END {
            split("Cache-Control Expires Vary Set-Cookie", req, " ")
            for (i in req) if (!(req[i] in ign)) print "proxy_ignore_headers must include " req[i]
            for (h in ign) if (!(h in hid)) print "ignored header " h " must also be hidden from clients"
        }' "${pp}")" || return 2
    while IFS= read -r h; do
        [ -z "${h}" ] || viol+=("${pp#"${repo_root}/"}: ${h}")
    done <<<"${out}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0151]" "reason=\"proxy nginx policy violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-nginx-policy=clean healthz_blocks=%s\n' "${blocks}"
}

# What: proxy CERT_DIR sits on a named volume.
# Why: an anonymous volume loses leaf certs on recreate.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cert_volume() {
    local repo_root="${1:-${CI_REPO_ROOT}}" ep dir dep inst targets cf cfg out line
    local -a viol=()
    local -A seen=()
    ep="$(_ci_service_path proxy entrypoint.sh "${repo_root}")" || return 2
    dir="$(_ci_proxy_constant CERT_DIR "${ep}")" || {
        ci_log "[CI-ERROR-CHECK-0150]" "path=\"${ep}\" reason=\"need exactly one literal CERT_DIR= line\""
        return 2
    }
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    targets="$(_ci_block_entry_field validation "" compose_targets)" || return 2
    for cf in "${dep}" "${inst}" ${targets}; do
        [ -z "${seen[${cf}]:-}" ] || continue
        seen["${cf}"]=1
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        out="$(_ci_capture 0 jq -r --arg d "${dir}" '.services.proxy // empty
            | [.volumes // [] | .[] | select(.target == $d)] as $m
            | if ($m | length) != 1 then "proxy needs exactly one mount at \($d) (got \($m | length))"
              elif $m[0].type != "volume" or ($m[0].source // "") == ""
              then "proxy \($d) must be a named volume (got \($m[0].type) \($m[0].source // "anonymous"))"
              else empty end' <<<"${cfg}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${cf}: ${line}")
        done <<<"${out}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0149]" "reason=\"proxy cert dir not on a named volume\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cert-volume=clean cert_dir=%s files=%s\n' "${dir}" "${#seen[@]}"
}

# What: logs volume chowned to syslog's uid before start.
# Why: syslog runs capability-free and cannot fix it.
# From: Issue #1683 | PR #1858
_ci_check_syslog_logs_volume() {
    local repo_root="${1:-${CI_REPO_ROOT}}" df cf dep inst cfg out line uid gid
    local -a viol=()
    df="$(_ci_service_path syslog Dockerfile "${repo_root}")" || return 2
    uid="$(_ci_capture 1 sed -nE 's/.*adduser .*-u ([0-9]+)( .*|$)/\1/p' "${df}")" || return 2
    gid="$(_ci_capture 1 sed -nE 's/.*addgroup .*-g ([0-9]+)( .*|$)/\1/p' "${df}")" || return 2
    if ! [[ "${uid}" =~ ^[0-9]+$ && "${gid}" =~ ^[0-9]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0148]" "path=\"${df}\" uid=\"${uid//$'\n'/,}\" gid=\"${gid//$'\n'/,}\" reason=\"need exactly one adduser -u and addgroup -g\""
        return 2
    fi
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    for cf in "${dep}" "${inst}"; do
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        out="$(_ci_capture 0 jq -r --arg owner "${uid}:${gid}" '
            (.services["syslog-logs-permissions"] // {}) as $i | (.services.syslog // {}) as $y
            | ([["user", "0:0"], ["entrypoint", ["/bin/chown"]],
                ["command", ["-R", $owner, "/var/log/lancache"]], ["network_mode", "none"],
                ["cap_drop", ["ALL"]], ["cap_add", ["CHOWN"]], ["read_only", true], ["restart", "no"]][]
                | . as [$k, $v] | select($i[$k] != $v)
                | "syslog-logs-permissions \($k) must be \($v | tojson) (got \($i[$k] | tojson))"),
              (if ($y.depends_on["syslog-logs-permissions"].condition // "none") != "service_completed_successfully"
                then "syslog must wait for syslog-logs-permissions to complete" else empty end),
              (if $y.cap_drop != ["ALL"] or ($y | has("cap_add"))
                then "syslog must drop all capabilities and add none" else empty end)' <<<"${cfg}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${cf}: ${line}")
        done <<<"${out}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0147]" "reason=\"syslog logs volume ownership violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'syslog-logs-volume=clean owner=%s:%s\n' "${uid}" "${gid}"
}

# What: Fail unless .env defines every key.
# Why: an unset required key breaks compose interpolation.
# From: Issue #1683 | PR #1858
_ci_check_compose_required_env() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local key inst env compose
    inst="$(_ci_installer_compose "${repo_root}")" || return 2
    env="${repo_root}/$(dirname "${inst}")/.env"
    compose="${repo_root}/${inst}"
    local produced produced_rc=0
    produced="$(
        grep -oE '\$\{[A-Za-z0-9_]+:\?[^}]+\}' "${compose}" \
            | sed -E 's/^\$\{([^:]+):.*/\1/' \
            | sort -u
    )" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        grep -Eq "^${key}=[^[:space:]]+" "${env}" \
            || viol+=("$(dirname "${inst}")/.env must define non-empty ${key} (compose marks it required)")
    done <<<"${produced}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0047]" "reason=\"compose required env not defined\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-required-env=clean\n'
}

# What: dhcp-proxy must receive each template key it uses
# Why: the template owns the keys; a dropped one is lost
# From: Issue #1683 | PR #1858
_ci_check_dhcp_proxy_env() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local -A in_env=() in_tpl=() seen=()
    local dep tpl ep f json env used tkeys key
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    tpl="$(dirname "${dep}")/.env"
    ep=services/dhcp-proxy/entrypoint.sh
    for f in "${dep}" "${tpl}" "${ep}" services/dhcp-proxy/dnsmasq.conf.template; do
        [ -f "${repo_root}/${f}" ] || { ci_error "[CI-ERROR-CHECK-0048]" "path=\"${f}\" reason=\"required dhcp-proxy input missing\"" "missing dhcp-proxy input: ${f}"; return 2; }
    done
    json="$(_ci_compose_json "${repo_root}/${dep}")" || return 2
    env="$(_ci_capture 0 jq -r '.services["dhcp-proxy"].environment // {} | keys[]' <<< "${json}")" || return 2
    tkeys="$(_ci_capture 1 grep -oE '^[A-Z][A-Z0-9_]*=' "${repo_root}/${tpl}")" || return 2
    used="$(_ci_capture 1 grep -oE '\$\{?[A-Z][A-Z0-9_]*' "${repo_root}/${ep}")" || return 2
    while IFS= read -r key; do [ -z "${key}" ] || in_env["${key}"]=1; done <<< "${env}"
    while IFS= read -r key; do [ -z "${key}" ] || in_tpl["${key%=}"]=1; done <<< "${tkeys}"
    while IFS= read -r key; do
        key="${key#\$}"
        key="${key#\{}"
        [ -n "${key}" ] && [ -z "${seen[${key}]:-}" ] && [ -n "${in_tpl[${key}]:-}" ] || continue
        seen["${key}"]=1
        [ -n "${in_env[${key}]:-}" ] \
            || viol+=("${dep}: dhcp-proxy never receives ${key} (read by ${ep}, owned by ${tpl})")
    done <<< "${used}"
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
    local key dep inst su
    su="$(_ci_installer "${repo_root}")" || return 2
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
    grep -Fq 'run_kea_dhcp_activation_preflight "$ENV_LOCAL"' "${su}" \
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
    dhcp_pkgs="$(_ci_service_packages dhcp)" || return 2
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
    local su pause_out
    local -a viol=()
    su="$(_ci_installer "${repo_root}")" || return 2
    awk '/This script must be run as root/{r=1} r&&/assert_prebuilt_image_platform_supported/{g=1} r&&!g&&/(install_docker|systemctl enable --now docker)/{f=1} END{exit f?0:1}' "${su}" \
        && viol+=("prebuilt platform guard must run before Docker install or daemon startup")
    # What: no flow mutates install state before its pause.
    # Why: per function; the cmd_update window went stale.
    # From: Issue #1683 | PR #1858
    if ! pause_out="$(awk '
        /^[A-Za-z_][A-Za-z0-9_]*\(\) [({]/ { fn = $1; sub(/\(\).*/, "", fn); next }
        /^[[:space:]]*#/ { next }
        /pause_lancache_convergence_for_update/ { seen[fn] = 1; paused[fn] = 1; next }
        !paused[fn] && /(sync_repo_to_default_branch|update_repo_and_resume|adopt_config_prod_edits|cmd_backup|git -C|migrate_env_for_update|validate_compose_config|stack_compose[[:space:]].*[[:space:]](pull|up)([[:space:]]|$)|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+(pull|up))/ {
            pend[fn] = pend[fn] NR ": " $0 "\n"
        }
        END {
            for (f in seen) { n++; if (pend[f] != "") { printf "%s mutates before its pause:\n%s", f, pend[f]; bad = 1 } }
            if (n == 0) { print "no update flow calls pause_lancache_convergence_for_update"; bad = 1 }
            exit bad
        }' "${su}")"; then
        viol+=("update must pause the convergence timer before mutating install state"$'\n'"${pause_out}")
    fi
    grep -Fq 'systemctl stop "$CONVERGE_SERVICE_UNIT"' "${su}" \
        || viol+=("update must stop the active convergence service before mutating install state")
    awk '/if ! \( cmd_backup --config "\$install_dir" \); then/{b=1;next} b&&/resume_lancache_convergence_after_update true/{r=1} b&&/die "Pre-update rollback backup failed/{d=1;b=0} END{exit r&&d?0:1}' "${su}" \
        || viol+=("update must restore the convergence timer when the rollback backup fails")
    awk '/^cmd_update_ip\(\) \{/{u=1;g=0;next} /^# .*backup subcommand/{u=0} u&&/assert_prebuilt_image_platform_supported/{g=1} u&&!g&&/(sed -i|docker compose -f|stack_compose[[:space:]])/{f=1} END{exit f?0:1}' "${su}" \
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
    local su
    local -a viol=()
    su="$(_ci_installer "${repo_root}")" || return 2
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
    local su sec prod dep
    su="$(_ci_installer "${repo_root}")" || return 2
    sec="$(_ci_service_path ui src/main.rs "${repo_root}")" || return 2
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    prod="${repo_root}/${dep}"
    local -a viol=()
    local f
    if awk '/^# ── [0-9]+\. Installing systemd watchdog/{i=1;p=0} /^# ── [0-9]+\. Post-start info/{i=0} i&&/(docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?|stack_compose[[:space:]].*)[[:space:]]pull([[:space:]]|$)/{p=1} i&&!p&&/^[[:space:]]*(systemctl[[:space:]]+(enable|start)[[:space:]]+("?\$\{?(STACK_UNIT|CONVERGE_TIMER_UNIT)|lancache\.service|lancache-converge\.timer)|(docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?|stack_compose[[:space:]].*)[[:space:]]up[[:space:]]+-d)/{v=1} END{exit v?0:1}' "${su}"; then
        viol+=("setup.sh must not start/enable lancache services before image pull")
    fi
    for f in \
        'lancache_image_registry=$(resolve_lancache_image_registry "$env_file")' \
        'lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file")' \
        'lancache_image_channel=$(resolve_lancache_image_channel "$env_file")' \
        'lancache_image_tag=$(resolve_lancache_image_tag "$env_file")' \
        'lancache_channel_image_refs()' \
        'if [[ "$first" == "$second" ]]; then' \
        'response_image_tag=$(json_value .image_tag "$response")' \
        'response_image_registry=$(json_value .image_registry "$response")' \
        'response_image_prefix=$(json_value .image_prefix "$response")' \
        'response_image_channel=$(json_value .image_channel "$response")' \
        'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}' \
        'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}' \
        'LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}' \
        'derive_release_archive_image_tag()'; do
        grep -Fq "${f}" "${su}" || viol+=("setup.sh must keep image-resolution: ${f}")
    done
    if [ ! -f "${sec}" ]; then
        viol+=("ui source missing: ${sec}")
    else
        for f in \
            '    image_tag: String,' '    image_registry: String,' \
            '    image_prefix: String,' '    image_channel: String,' \
            'image_tag: state.config.lancache_image_tag.clone()' \
            'image_registry: state.config.lancache_image_registry.clone()' \
            'image_prefix: state.config.lancache_image_prefix.clone()' \
            'image_channel: state.config.lancache_image_channel.clone()'; do
            grep -Fq "${f}" "${sec}" || viol+=("ui main.rs must expose/use ${f}")
        done
    fi
    if [ ! -f "${prod}" ]; then
        viol+=("prod compose missing: ${prod}")
    else
        for f in \
            'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY:-ghcr.io}' \
            'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}' \
            'LANCACHE_IMAGE_CHANNEL=${LANCACHE_IMAGE_CHANNEL:-}' \
            'LANCACHE_IMAGE_TAG=${LANCACHE_IMAGE_TAG:-latest}'; do
            grep -Fq "${f}" "${prod}" || viol+=("prod compose must pass ${f}")
        done
    fi
    local readme reldoc
    readme="$(_ci_repo_path CI_README "${repo_root}")" || return 2
    reldoc="$(_ci_repo_path CI_RELEASE_VERSIONING_DOC "${repo_root}")" || return 2
    grep -Fq 'LANCACHE_IMAGE_CHANNEL=latest' "${readme}" \
        || viol+=("README must document latest as the install default")
    grep -Fq 'fresh installs use `LANCACHE_IMAGE_CHANNEL=nightly` by default pre-1.0' "${reldoc}" \
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
    local trivyignore="$1" fields repo server ts
    fields="$(_ci_trivyignore_fields "${trivyignore}")" || return 2
    repo="$(_ci_repo)" || return 2
    server="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    # What: time: CI_VEX_TIMESTAMP, else HEAD commit time
    # Why: a repeat derives the same VEX (architecture §58)
    # From: Issue #1683 | PR #1858
    ts="${CI_VEX_TIMESTAMP:-}"
    [ -n "${ts}" ] || ts="$(_ci_capture 0 env TZ=UTC git -C "${CI_REPO_ROOT:-.}" log -1 \
        --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd)" || return 2
    _ci_run "[CI-ERROR-RELEASE-0025]" "trivyignore=\"${trivyignore}\" reason=\"OpenVEX assembly failed\"" \
        jq -nR --arg repo "${repo}" --arg server "${server}" --arg ts "${ts}" '
        def stmt($e; $p):
          ($e.statement // "") as $s
          | if ($e.status // "") == "not_affected" then
              (($e.justification // "vulnerable_code_not_present") as $j
               | if ($j | IN("component_not_present", "vulnerable_code_not_present",
                      "vulnerable_code_not_in_execute_path",
                      "vulnerable_code_cannot_be_controlled_by_adversary",
                      "inline_mitigations_already_exist")) | not
                 then error("\($e.id): justification \($j) is not an OpenVEX value") else . end
               | $p + {status: "not_affected", justification: $j,
                   impact_statement: $s})
            elif ($e.status // "") == "" then
              (if $e.justification then error("\($e.id): justification needs status not_affected") else . end
               | $p + {status: "affected",
                   action_statement: $s})
            else error("\($e.id): status \($e.status) is not supported (not_affected or none)") end;
        [inputs | split("\t") | {n: (.[0] | tonumber), k: .[1], v: (.[2:] | join("\t") | gsub("\u001e"; "\n"))}]
        | group_by(.n)
        | map(reduce .[] as $f ({paths: []};
            if $f.k == "path" then .paths += [$f.v] else .[$f.k] = $f.v end))
        | {"@context": "https://openvex.dev/ns/v0.2.0",
           "@id": "\($server)/\($repo)/vex/\($repo | split("/")[1])-\($ts)",
           author: "\($repo | split("/")[1]) release automation (\($server)/\($repo))",
           timestamp: $ts, version: 1,
           statements: map(stmt(.; {vulnerability: {name: .id}, timestamp: $ts,
             products: [{"@id": "pkg:github/\($repo)", subcomponents: (.paths | map({"@id": .}))}]}))}
        ' <<< "${fields}"
}

# What: trivyignore vulnerability fields, one per line.
# Why: strict reader; a shape it does not know fails closed.
# From: Issue #1683 | PR #1858
_ci_trivyignore_fields() {
    local file="$1" out
    if ! out="$(awk '
        function fail(m) { printf "line %d: %s: %s\n", NR, m, $0 > "/dev/stderr"; bad = 1; exit 3 }
        function scalar(v) {
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) { v = substr(v, 2, length(v) - 2); if (v ~ /["\047\\]/) fail("escaped quoted scalar") }
            else if (v ~ /(^| )#/ || v ~ /^[\[{&*!|>%@`]/) fail("unsupported plain scalar")
            return v
        }
        function flush() { if (on) { print n "\tstatement\t" st; on = 0 } }
        { match($0, /^ */); ind = RLENGTH; rest = substr($0, ind + 1) }
        on && rest == "" { if (st != "") nl++; next }
        on && ind == 6 {
            if (st == "") st = rest
            else if (nl) { while (nl-- > 0) st = st "\036"; st = st rest }
            else st = st " " rest
            nl = 0; next
        }
        on && ind > 6 { fail("more-indented folded line") }
        on { flush() }
        rest == "" || rest ~ /^#/ { next }
        ind == 0 && rest == "vulnerabilities:" { sect = "v"; next }
        ind == 0 && rest ~ /^[a-z_]+:[ \t]*$/ { sect = "o"; next }
        ind == 0 { fail("unsupported top-level line") }
        sect == "o" { next }
        sect != "v" { fail("line outside a section") }
        ind == 2 && rest ~ /^- id:/ { v = rest; sub(/^- id:[ \t]*/, "", v); n++; mode = ""; print n "\tid\t" scalar(v); next }
        ind == 4 && n && rest ~ /^[a-z_]+:/ {
            k = rest; sub(/:.*/, "", k); v = rest; sub(/^[a-z_]+:[ \t]*/, "", v); mode = ""
            if (k == "paths" && v == "") { mode = "paths"; next }
            if (k == "statement" && v == ">-") { on = 1; st = ""; nl = 0; next }
            if (k == "statement" || k == "status" || k == "justification") { print n "\t" k "\t" scalar(v); next }
            fail("unsupported entry key")
        }
        ind == 6 && mode == "paths" && rest ~ /^- / { v = rest; sub(/^-[ \t]*/, "", v); print n "\tpath\t" scalar(v); next }
        { fail("unsupported line") }
        END { flush(); if (bad) exit 3 }
    ' "${file}" 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0035]" "file=\"${file}\" reason=\"trivyignore not in the supported shape\"" "${out}"
        return 2
    fi
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: Fail unless the trivyignore yields full OpenVEX.
# Why: a broken entry must fail here, not at release time.
# From: Issue #1683 | PR #1858
_ci_check_vex_drift() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local trivyignore
    trivyignore="$(_ci_repo_path CI_TRIVY_IGNORE "${repo_root}")" || return 2
    local out entry_count statement_count
    [ -f "${trivyignore}" ] || { ci_error "[CI-ERROR-CHECK-0050]" "path=\"${trivyignore}\" reason=\".trivyignore.yaml not found\"" "${trivyignore}"; return 2; }
    if ! out="$(_ci_generate_vex "${trivyignore}")"; then
        ci_log "[CI-ERROR-CHECK-0107]" "path=\"${trivyignore}\" reason=\"OpenVEX generation failed (raw above)\""
        return 1
    fi
    entry_count="$(_ci_capture 1 grep -c '^  - id:' "${trivyignore}")" || return 2
    statement_count="$(_ci_capture 0 jq '.statements | length' <<< "${out}")" || return 2
    if [ "${statement_count}" != "${entry_count}" ]; then
        ci_log "[CI-ERROR-CHECK-0109]" "entries=${entry_count} statements=${statement_count} reason=\"trivyignore entries and VEX statements differ\""
        return 1
    fi
    printf 'vex-drift=clean statements=%s\n' "${statement_count}"
}

# What: Warn (never fail) on editing CHANGELOG.md directly.
# Why: usually unintended; risks a merge-conflict cascade.
# From: Issue #893 | PR #1858
_ci_check_changelog_direct_edit() {
    local -a changed=("$@")
    local path edited=0 file
    file="$(_ci_variable CI_CHANGELOG)" || return 2
    for path in "${changed[@]}"; do
        [ "${path}" = "${file}" ] && { edited=1; break; }
    done
    if [ "${edited}" -eq 0 ]; then
        printf 'changelog-direct-edit=clean\n'
        return 0
    fi
    local label_rc=0 label_err label
    label="$(_ci_block_entry_field release_notes "" changelog_edit_label)" || return 2
    label_err="$(jq -e --arg l "${label}" 'index($l) != null' <<<"${PR_LABELS_JSON:-[]}" 2>&1 >/dev/null)" || label_rc=$?
    case "${label_rc}" in
        0) ci_log "[CI-INFO-CHECK-0115]" "file=\"${file}\" label=\"${label}\" reason=\"changelog edited with the label; expected\"" ;;
        1) ci_log "[CI-INFO-CHECK-0116]" "file=\"${file}\" reason=\"changelog edited directly outside the release flow (issue #893); warn-only\"" ;;
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
    local flags
    local -a profile_flags=()
    flags="$(_ci_compose_profile_flags "${file}")" || return 2
    [ -z "${flags}" ] || mapfile -t profile_flags <<< "${flags}"
    _ci_run "[CI-ERROR-CHECK-0119]" "file=\"${file}\" profiles=\"${flags//$'\n'/ }\" reason=\"docker compose service list failed\"" \
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
    local repo_root="${1:-${CI_REPO_ROOT}}" doc
    doc="$(_ci_repo_path CI_ARCH_DOC "${repo_root}")" || return 2
    if [ ! -f "${doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0035]" "path=\"${doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    local canonical_raw
    canonical_raw="$(_ci_logging_matrix_canonical "${doc}")" || {
        ci_log "[CI-ERROR-CHECK-0120]" "path=\"${doc}\" reason=\"logging matrix not readable (raw above)\""; return 2; }
    local row_summary raw_row_count unique_row_count
    row_summary="$(_ci_capture 1 grep -E '^##ROWS## ' <<<"${canonical_raw}")" || return 2
    raw_row_count="$(awk '{print $2}' <<<"${row_summary}")"
    unique_row_count="$(awk '{print $3}' <<<"${row_summary}")"
    local -a canonical=()
    local n
    local produced produced_rc=0
    produced="$(grep -vE '^##ROWS## ' <<<"${canonical_raw}")" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 1 || return 2
    while IFS= read -r n; do
        [ -n "${n}" ] && canonical+=("${n}")
    done <<<"${produced}"
    if [ "${#canonical[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0036]" "path=\"${doc}\" reason=\"no logging-matrix rows parsed\""
        return 2
    fi
    if [ -n "${raw_row_count}" ] && [ -n "${unique_row_count}" ] && [ "${unique_row_count}" -lt "${raw_row_count}" ]; then
        ci_log "[CI-ERROR-CHECK-0037]" "reason=\"parsed ${unique_row_count} unique of ${raw_row_count} rows; a row was dropped or collapsed\""
        return 2
    fi
    local dep
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 2
    local -a compose_files=("${repo_root}/${dep}")
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
    # What: netdata mounts the real web_log job file.
    # Why: one web_log owner; no inline copy can drift.
    # From: Issue #1683 | PR #1858
    local web_log_conf="${repo_root}/services/syslog/netdata-web_log.conf"
    if [ ! -f "${web_log_conf}" ]; then
        viol+=("${web_log_conf}: not found")
    elif ! grep -q 'jobs:' "${web_log_conf}"; then
        viol+=("${web_log_conf}: no 'jobs:' section found")
    elif ! grep -Fq 'services/syslog/netdata-web_log.conf:/etc/netdata/go.d/web_log.conf' "${repo_root}/${dep}"; then
        viol+=("${dep}: netdata must mount services/syslog/netdata-web_log.conf")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0038]" "reason=\"logging-matrix drift (issue #633)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'logging-matrix=clean rows=%s services=%s\n' "${#canonical[@]}" "${#consumer[@]}"
}

# What: True if final stage COPYs to destination.
# Why: Only runtime stage files exist at run time.
# From: Issue #1683
_ci_dockerfile_copies_to() {
    local dockerfile="$1" want="$2" line lineno=0 last_from=0 dest from_val ctx_path
    local -a words real
    local -A aliases=()
    local produced produced_rc=0
    produced="$(_ci_dockerfile_logical_lines "${dockerfile}")" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        case "${line}" in [Ff][Rr][Oo][Mm]\ *) last_from=${lineno} ;; esac
        if [[ "${line}" =~ [Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$ ]]; then
            aliases["${BASH_REMATCH[1],,}"]=1
        fi
    done <<<"${produced}"
    lineno=0
    local produced produced_rc=0
    produced="$(_ci_dockerfile_logical_lines "${dockerfile}")" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
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
                                ctx_path="$(_ci_block_entry_field named_contexts "${from_val}" path)" || return 2
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
    done <<<"${produced}"
    return 1
}

# What: Sourced lib path must match a COPY destination.
# Why: source-drift breaks silently only at runtime.
# From: Issue #1683
_ci_check_entrypoint_lib_wiring() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=()
    local ep svc svcs ctx dir name dockerfile line lib_path n_ep=0 n_lib=0

    # What: each SOT service context's entrypoint script.
    # Why: the SOT owns services and paths; no glob/literal.
    # From: Issue #1683
    svcs="$(ci_services)" || return 2
    for svc in ${svcs}; do
        dir="$(_ci_service_path "${svc}" "" "${repo_root}")" || return 2
        dir="${dir%/}" ctx="${dir#"${repo_root}/"}"
        dockerfile="${dir}/Dockerfile"
        for name in entrypoint.sh docker-entrypoint.sh; do
            ep="${dir}/${name}"
            [ -f "${ep}" ] || continue
            n_ep=$((n_ep + 1))
            while IFS= read -r line; do
                [[ "${line}" =~ ^[[:space:]]*(\.|source)[[:space:]]+\"?(/[^\"[:space:]]+)\"?[[:space:]]*(\#.*)?$ ]] || continue
                lib_path="${BASH_REMATCH[2]}"
                n_lib=$((n_lib + 1))
                if [ ! -f "${dockerfile}" ]; then
                    viol+=("${ctx}: sources ${lib_path}, no Dockerfile found")
                    continue
                fi
                _ci_dockerfile_copies_to "${dockerfile}" "${lib_path}" ||
                    viol+=("${ctx}/${name} sources ${lib_path}: no matching final-stage COPY in ${dockerfile}")
            done < "${ep}"
        done
    done
    # What: no entrypoint found at all fails closed
    # Why: a guard that checks nothing must not pass
    # From: Issue #1683 | PR #1858
    if [ "${n_ep}" -eq 0 ]; then
        ci_error "[CI-ERROR-CHECK-0168]" "reason=\"no service entrypoint found; nothing was checked\"" "${svcs}"
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0041]" "reason=\"entrypoint sources a lib its Dockerfile never COPYs\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'entrypoint-lib-wiring=clean entrypoints=%s libs=%s\n' "${n_ep}" "${n_lib}"
}

# What: each workflow calling ci.sh passes CI_VARIABLES.
# Why: else ci.sh misses repo/org vars; ids diverge.
# From: Issue #1683 | PR #1858
_ci_check_workflow_ci_variables() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" dir out line callers=0
    local -a viol=() files=()
    dir="$(_ci_repo_path CI_WORKFLOW_DIR "${repo_root}")" || return 2
    _ci_workflow_files files "${dir}" || return 2
    out="$(_ci_capture 0 awk '
        function rep() { if (c) { n++; if (!w) print "unwired " f } }
        FNR == 1 { if (f != "") rep(); f = FILENAME; c = w = 0 }
        index($0, "scripts/ci.sh") { c = 1 }
        $0 == "  CI_VARIABLES: ${{ toJSON(vars) }}" { w = 1 }
        END { if (f != "") rep(); print "callers " n + 0 }' "${files[@]}")" || return 2
    while IFS= read -r line; do
        case "${line}" in
            "callers "*) callers="${line#callers }" ;;
            "unwired "*) line="${line#unwired }"; viol+=("${line#"${repo_root}/"}: calls ci.sh without top-level env CI_VARIABLES") ;;
        esac
    done <<< "${out}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0158]" "scanned=${#files[@]} callers=${callers} flagged=${#viol[@]} reason=\"ci.sh caller without CI_VARIABLES\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'workflow-ci-variables=clean scanned=%s callers=%s\n' "${#files[@]}" "${callers}"
}

# What: needs jobs read job-settings; root literals = SOT
# Why: AG-CI-006/016: one owner; every job has a timeout
# From: Issue #1683 | PR #1858
_ci_check_workflow_job_settings() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" dir out line runner job tmap="" js_count=0
    local -a viol=() files=() js_jobs=()
    local -A js_min=()
    dir="$(_ci_repo_path CI_WORKFLOW_DIR "${repo_root}")" || return 2
    _ci_workflow_files files "${dir}" || return 2
    _ci_job_settings_read runner js_jobs js_min || return 2
    for job in "${js_jobs[@]}"; do tmap+="${job}=${js_min[${job}]} "; done
    out="$(_ci_capture 0 awk -v runner="${runner}" -v tmap="${tmap}" -v q="'" '
        function lit(v) { return v != "" && v !~ /^\$\{\{/ }
        function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub("^[\"" q "]|[\"" q "]$", "", s); return s }
        function bad(m) { print "flag " f ": job " job ": " m }
        function done_job(  k, want, shown) {
            if (job == "" || uses) return
            njob++
            want = (job in T) ? T[job] : ""
            shown = (want == "") ? "none" : want
            if (to == "") bad("no timeout-minutes")
            if (nd) {
                if (lit(ro)) bad("runs-on " ro " (a needs job reads job-settings)")
                if (lit(to)) bad("timeout-minutes " to " (a needs job reads job-settings)")
                else if (to != "" && want == "") bad("no SOT ci_job_timeouts." job)
            } else {
                if (lit(ro) && ro != runner) bad("runs-on " ro " (SOT runner " runner ")")
                if (lit(to) && to != want) bad("timeout-minutes " to " (SOT ci_job_timeouts." job ": " shown ")")
            }
            k = ro
            while (match(k, q "[^" q "]*" q)) {
                if (substr(k, RSTART + 1, RLENGTH - 2) != runner) bad("runs-on fallback " substr(k, RSTART, RLENGTH) " (SOT runner " runner ")")
                k = substr(k, RSTART + RLENGTH)
            }
            if (match(to, /\|\|[[:space:]]*[0-9]+/)) {
                k = substr(to, RSTART + 2, RLENGTH - 2); gsub(/[[:space:]]/, "", k)
                if (k != want) bad("timeout fallback " k " (SOT ci_job_timeouts." job ": " shown ")")
            }
            if (match(to, "\\[" q "[^" q "]*" q "\\]")) {
                k = substr(to, RSTART + 2, RLENGTH - 4)
                if (k != job) bad("timeout-minutes reads key " k)
            }
        }
        function end_file() {
            done_job(); job = ""
            if (f == "") return
            if (!sawj) print "flag " f ": no top-level jobs: block"
            else if (!nfile) print "flag " f ": jobs: block without a parsable job"
        }
        BEGIN { n = split(tmap, kv, " "); for (i = 1; i <= n; i++) { p = index(kv[i], "="); T[substr(kv[i], 1, p - 1)] = substr(kv[i], p + 1) } }
        FNR == 1 { end_file(); f = FILENAME; inj = sawj = nfile = blk = 0 }
        blk && /^      / { s = $0; sub(/^[[:space:]]+/, "", s); ro = ro " " s; next }
        { blk = 0 }
        /^jobs:[[:space:]]*$/ { inj = 1; sawj = 1; next }
        inj && /^[^[:space:]#]/ { done_job(); job = ""; inj = 0 }
        inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { done_job(); job = $1; sub(/:$/, "", job); ro = to = ""; nd = uses = 0; nfile++; next }
        inj && /^    needs:/ { nd = 1 }
        inj && /^    uses:/ { uses = 1 }
        inj && /^    runs-on:/ { ro = val($0); if (ro == "") { ro = "[block]"; blk = 1 } }
        inj && /^    timeout-minutes:/ { to = val($0) }
        END { end_file(); print "jobs " njob + 0 }' "${files[@]}")" || return 2
    while IFS= read -r line; do
        case "${line}" in
            "jobs "*) js_count="${line#jobs }" ;;
            "flag "*) line="${line#flag }"; viol+=("${line#"${repo_root}/"}") ;;
        esac
    done <<< "${out}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0159]" "scanned=${#files[@]} jobs=${js_count} flagged=${#viol[@]} reason=\"job runner or timeout not from the SOT owner\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'workflow-job-settings=clean scanned=%s jobs=%s\n' "${#files[@]}" "${js_count}"
}

# What: a type with build variables lists them as input.
# Why: else a changed build-arg keeps an accepted id.
# From: Issue #1683 | PR #1858
_ci_check_sot_identity_inputs() {
    local types t inputs n=0
    local -a viol=()
    types="$(_ci_block_keys build_variables all)" || return 2
    for t in ${types}; do
        n=$(( n + 1 ))
        inputs="$(_ci_block_entry_list build_identity "${t}" inputs)" || return 2
        [[ " ${inputs//$'\n'/ } " == *" build_variables "* ]] \
            || viol+=("build_identity.${t}.inputs lacks build_variables: ${inputs//$'\n'/ }")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0157]" "types=${n} reason=\"build variables are not an identity input\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'sot-identity-inputs=clean types=%s\n' "${n}"
}

# What: each Dockerfile secret mount id is a central id.
# Why: set-runtime writes only listed ids; one source.
# From: Issue #1683 | PR #1858
_ci_check_dockerfile_secret_ids() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" targets t df allow hits spec p id n=0
    local -a viol=() parts=()
    local -A kv=()
    targets="$(ci_build_targets)" || return 2
    allow="$(_ci_runtime_secret_ids)" || return 2
    for t in ${targets}; do
        df="$(_ci_service_path "${t}" Dockerfile "${repo_root}")" || return 2
        n=$(( n + 1 ))
        if [ ! -f "${df}" ]; then
            viol+=("${t}: no Dockerfile at ${df#"${repo_root}/"}"); continue
        fi
        hits="$(_ci_capture 0 awk '/^[[:space:]]*#/ { next }
            { s = $0; while (match(s, /--mount=[^[:space:]]+/)) { print substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) } }' "${df}")" || return 2
        while IFS= read -r spec; do
            [ -n "${spec}" ] || continue
            kv=()
            IFS=',' read -r -a parts <<< "${spec#--mount=}"
            for p in "${parts[@]}"; do kv["${p%%=*}"]="${p#*=}"; done
            [ "${kv[type]:-bind}" = secret ] || continue
            id="${kv[id]:-${kv[target]:-${kv[dst]:-${kv[destination]:-}}}}"
            [ -n "${kv[id]:-}" ] || id="${id##*/}"
            if [ -z "${id}" ]; then
                viol+=("${t}: ${df#"${repo_root}/"}: '${spec}' has no id or target"); continue
            fi
            grep -qx -- "${id}" <<< "${allow}" || viol+=("${t}: ${df#"${repo_root}/"}: mount id '${id}' is not in the central list")
        done <<< "${hits}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0156]" "targets=${n} reason=\"Dockerfile missing or mount id not central\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'dockerfile-secret-ids=clean targets=%s\n' "${n}"
}

# What: "stage name" per stage that runs <ere> sans ARG
# Why: ARG scope is per stage; else no value reaches it
# From: Issue #1683 | PR #1858
_ci_dockerfile_stage_missing_args() {
    local df="$1" argnames="$2" runs="$3"
    _ci_capture 0 awk -v need="${argnames//$'\n'/ }" -v runs="${runs}" '
        BEGIN { n = split(need, req, " "); st = 0; decl[0] = "|" }
        /^[[:space:]]*#/ { next }
        toupper($1) == "FROM" {
            st++; i = 2; while ($i ~ /^--/) i++
            b = tolower($i); decl[st] = (b in alias) ? decl[alias[b]] : "|"
            if (toupper($(i + 1)) == "AS") alias[tolower($(i + 2))] = st
            next
        }
        toupper($1) == "ARG" { for (i = 2; i <= NF; i++) { a = $i; sub(/=.*/, "", a); decl[st] = decl[st] a "|" }; next }
        $0 ~ runs { for (j = 1; j <= n; j++) if (index(decl[st], "|" req[j] "|") == 0) print st " " req[j] }
    ' "${df}"
}

# What: each ci.sh stage declares every SOT stage variable
# Why: ARG scope is per stage; else ci.sh reads no value
# From: Issue #1683 | PR #1858
_ci_check_dockerfile_stage_variables() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" service df svars targets missing bst bv n=0
    local -a viol=()
    svars="$(_ci_block_entry_list stage_variables "" ci_sh)" || return 2
    [ -n "${svars}" ] || viol+=("SOT stage_variables.ci_sh lists no variable")
    targets="$(ci_build_targets)" || return 2
    for service in ${targets}; do
        df="$(_ci_service_path "${service}" Dockerfile "${repo_root}")" || return 2
        if [ ! -f "${df}" ]; then
            viol+=("${service}: no Dockerfile at ${df#"${repo_root}/"}"); continue
        fi
        n=$(( n + 1 ))
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${svars}" 'ci[.]sh (apk-setup|rust-build)')" || return 2
        while read -r bst bv; do
            [ -n "${bv}" ] || continue
            viol+=("${service}: Dockerfile stage ${bst} runs ci.sh without ARG ${bv} (SOT stage_variables.ci_sh)")
        done <<< "$(sort -u <<< "${missing}")"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0169]" "dockerfiles=${n} reason=\"a ci.sh build stage lacks an SOT stage variable ARG\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'dockerfile-stage-variables=clean dockerfiles=%s\n' "${n}"
}

# What: rust Dockerfiles must use build-tools image.
# Why: one toolchain owner; no self-compile (AG-CI-008).
# From: Issue #1683
_ci_check_dockerfile_build_tools() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" service df rc=0 bvars bv bst missing
    local -a viol=() tuning=()
    local services svc_type
    services="$(ci_services)" || return 2
    bvars="$(_ci_block_entry_list build_variables "" rust)" || return 2
    for service in ${services}; do
        svc_type="$(ci_service_field "${service}" build_type)" || return 2
        [ "${svc_type}" = rust ] || continue
        df="$(_ci_service_path "${service}" Dockerfile "${repo_root}")" || return 2
        if [ ! -f "${df}" ]; then
            viol+=("${service}: no Dockerfile at ${df#"${repo_root}/"}"); continue
        fi
        grep -q 'ARG BUILD_TOOLS_IMAGE' "${df}" \
            || viol+=("${service}: Dockerfile must declare ARG BUILD_TOOLS_IMAGE")
        # What: rust-build stages declare every build var.
        # Why: ARG scope is per stage; else none reaches it.
        # From: Issue #1683 | PR #1858
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${bvars}" 'ci[.]sh rust-build')" || return 2
        missing="$(sort -u <<< "${missing}")"
        while read -r bst bv; do
            [ -n "${bv}" ] || continue
            viol+=("${service}: Dockerfile stage ${bst} runs ci.sh rust-build without ARG ${bv} (SOT build_variables.rust)")
        done <<< "${missing}"
        grep -Eq '^FROM \$\{BUILD_TOOLS_IMAGE(:-scratch)?\}([[:space:]]|$)' "${df}" \
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
    tomls="$(_ci_ls_files cargo-profile-tuning "${repo_root}" '*Cargo.toml')" || return 2
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        local produced produced_rc=0
        produced="$(grep -nE '^[[:space:]]*(lto|codegen-units)[[:space:]]*=' "${repo_root}/${f}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
        while IFS= read -r line; do
            [ -n "${line}" ] && viol+=("${f}:${line}")
        done <<<"${produced}"
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
    dfs="$(_ci_ls_files no-source-compiled-tools "${repo_root}" '*Dockerfile')" || return 2
    while IFS= read -r df; do
        [ -n "${df}" ] || continue
        local produced produced_rc=0
        produced="$(awk '
            match($0, /cargo[ \t]+install[ \t]+/) {
                r = substr($0, RSTART + RLENGTH)
                sub(/[&|;].*/, "", r)
                n = split(r, a, /[ \t]+/)
                for (i = 1; i <= n; i++)
                    if (a[i] != "" && a[i] !~ /^-/) print a[i]
            }
        ' "${repo_root}/${df}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 0 || return 2
        while IFS= read -r tok; do
            [ -n "${tok}" ] && [ -n "${is_pkg[${tok}]:-}" ] \
                && viol+=("${df}: cargo install ${tok}; SOT ships it prebuilt in build-tools")
        done <<<"${produced}"
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
        mapfile -t globs <<< "${raw}"
        raw="$(_ci_block_entry_list codeql_languages "${lang}" paths)" || return 2
        mapfile -t paths <<< "${raw}"
        files="$(_ci_ls_files codeql-coverage "${repo_root}" "${globs[@]}")" || return 2
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

# What: "start end" line of each @test; heredocs skipped.
# Why: a } inside a heredoc must not end the test.
# From: Issue #1683 | PR #1858
_ci_bats_test_ranges() {
    awk -v style=hash -v h2= -v h3= "${_CI_AWK_COMMENT_LEX}"'
        END {
            cl_lex()
            for (i = 1; i <= n; i++) {
                if (H[i]) continue
                if (!s && L[i] ~ /^@test .*[{][[:space:]]*$/) s = i
                else if (s && L[i] == "}") { print s, i; s = 0 }
            }
            if (s) { printf "@test at line %d has no closing }\n", s > "/dev/stderr"; exit 2 }
        }
    ' "$1"
}

# What: shellcheck one @test per run; merge the findings.
# Why: one run links every @test into one dataflow graph.
# From: Issue #1683 | PR #1858
_ci_shellcheck_bats_tests() {
    local f="$1" ranges="$2" dir jobs cpus n k rc brk=0
    local -a outs=()
    dir="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
    jobs="$(_ci_parallel_jobs)" || { rm -rf "${dir}"; return 2; }
    read -r jobs cpus <<< "${jobs}"
    printf '%s\n' "${ranges}" > "${dir}/ranges"
    n="$(wc -l < "${dir}/ranges")"
    awk 'NR == FNR { for (l = $1; l <= $2; l++) t[l] = FNR; next } { print t[FNR] + 0 }' \
        "${dir}/ranges" "${f}" > "${dir}/map" || { rm -rf "${dir}"; return 2; }
    ci_log "[CI-INFO-CHECK-0155]" "file=\"${f}\" tests=${n} jobs=${jobs} cpus=${cpus} reason=\"shellcheck per @test\""
    # What: one job per @test: top level plus that test.
    # Why: other tests stay unparsed; .lines maps back.
    # From: Issue #1683 | PR #1858
    seq 1 "${n}" | xargs -P "${jobs}" -I{} bash -c '
        awk -v k="$1" -v m="$2/$1.lines" "NR == FNR { t[FNR] = \$1; next }
            t[FNR] == 0 || t[FNR] == k { print; print FNR > m }" "$2/map" "$3" > "$2/$1.bats" || exit 255
        shellcheck -f gcc --severity=warning "$2/$1.bats" > "$2/$1.out" 2>&1
        echo "$?" > "$2/$1.rc"
        rm -f "$2/$1.bats"' _ {} "${dir}" "${f}" || brk=1
    for ((k = 1; k <= n; k++)); do
        outs+=("${dir}/${k}.lines" "${dir}/${k}.out")
        rc="$(cat "${dir}/${k}.rc" 2>&1)" || rc="none"
        case "${rc}" in
            0|1) ;;
            *) brk=1; printf 'test lines %s rc=%s:\n%s\n' "$(sed -n "${k}p" "${dir}/ranges")" "${rc}" "$(cat "${dir}/${k}.out" 2>&1)" ;;
        esac
    done
    [ "${brk}" -eq 0 ] || { rm -rf "${dir}"; return 2; }
    # What: own-test findings; top-level ones seen in all.
    # Why: a top-level hit missing in some runs is noise.
    # From: Issue #1683 | PR #1858
    awk -v n="${n}" -v f="${f}" '
        NR == FNR { t[FNR] = $1; next }
        FNR == 1 { k = FILENAME; sub(/^.*\//, "", k); kind = k; sub(/\.(lines|out)$/, "", k); sub(/^[0-9]+\./, "", kind) }
        kind == "lines" { if (FNR == 1) delete m; m[FNR] = $1; next }
        $0 ~ /^[^:]+:[0-9]+:[0-9]+: / {
            split($0, p, ":"); ln = m[p[2]]; line = $0; sub(/^[^:]+:[0-9]+:/, f ":" ln ":", line)
            if (t[ln] == k) print line
            else if (t[ln] == 0 && !seen[k, line]++) top[line]++
        }
        END { for (x in top) if (top[x] == n) print x }
    ' "${dir}/map" "${outs[@]}" > "${dir}/found" || { rm -rf "${dir}"; return 2; }
    sort -t: -k2,2n -k3,3n "${dir}/found"
    rc=0; [ ! -s "${dir}/found" ] || rc=1
    rm -rf "${dir}"
    return "${rc}"
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
    [ "${#changed[@]}" -eq 0 ] || _ci_shell_sources files changed || return 2
    [ "${#files[@]}" -eq 0 ] && { printf 'shellcheck=noop\n'; return 0; }
    # What: one shellcheck process per file.
    # Why: one call on all files needs ~5 GB peak RAM.
    # From: Issue #1683 | PR #1858
    local sc_out="" sc_one sc_rc sc_found=0 sc_broken=0 tests
    for f in "${files[@]}"; do
        sc_rc=0 tests=""
        if [[ "${f}" == *.bats ]] && ! tests="$(_ci_bats_test_ranges "${f}" 2>&1)"; then
            sc_broken=1
            ci_error "[CI-ERROR-CHECK-0154]" "file=\"${f}\" reason=\"@test ranges unreadable\"" "${tests}"
            continue
        fi
        if [ -n "${tests}" ]; then
            sc_one="$(_ci_shellcheck_bats_tests "${f}" "${tests}")" || sc_rc=$?
        else
            sc_one="$(shellcheck --severity=warning "${f}" 2>&1)" || sc_rc=$?
        fi
        # What: rc 1 = findings; any other rc = no result.
        # Why: a killed run (137) must not read as findings.
        # From: Issue #1683 | PR #1858
        case "${sc_rc}" in
            0) ;;
            1) sc_found=1; sc_out="${sc_out}${sc_one}"$'\n' ;;
            *)
                sc_broken=1
                ci_error "[CI-ERROR-CHECK-0113]" "file=\"${f}\" rc=${sc_rc} reason=\"shellcheck did not complete\"" "${sc_one}"
                ;;
        esac
    done
    [ "${sc_broken}" -eq 0 ] || return 2
    if [ "${sc_found}" -ne 0 ]; then
        ci_error "[CI-ERROR-CHECK-0056]" "reason=\"shellcheck found issues\"" "${sc_out}"
        return 1
    fi
    printf 'shellcheck=clean files=%s\n' "${#files[@]}"
}

# What: actionlint workflow files (§98 exception).
# Why: workflow syntax not answerable from diff.
# From: Issue #1683
_ci_check_actionlint() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" out rc=0
    local wf
    local -a wfs=()
    wf="$(_ci_repo_path CI_WORKFLOW_DIR "${repo_root}")" || return 2
    _ci_workflow_files wfs "${wf}" || return 2
    out="$(actionlint "${wfs[@]}" 2>&1)" || rc=$?
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
    local lock="${1:-}" out rc=0
    [ -n "${lock}" ] || lock="$(_ci_variable CI_CARGO_LOCK)" || return 2
    out="$(cargo audit --deny warnings --file "${lock}" 2>&1)" || rc=$?
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
        pipefail-early-exit if-without-else-status \
        bats-and-chain exit-evidence ci-bats review-chronology governance-guards \
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
        prebuilt-prod prod-state-wiring compose-config nats-atomic-write \
        docker-socket-proxy netdata-isolation syslog-logs-volume proxy-cert-volume proxy-nginx-policy \
        compose-required-env dhcp-proxy-env \
        setup-keys-kea setup-update-safety setup-docker-conflict setup-prompt-drift image-channel-resolution \
        vex-drift logging-matrix \
        entrypoint-lib-wiring dockerfile-build-tools dockerfile-stage-variables \
        dockerfile-secret-ids sot-identity-inputs workflow-ci-variables workflow-job-settings cargo-profile-tuning no-source-compiled-tools codeql-coverage version-drift)
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
        dockerfile-stage-variables) _ci_check_dockerfile_stage_variables "$@" ;;
        dockerfile-secret-ids) _ci_check_dockerfile_secret_ids "$@" ;;
        sot-identity-inputs) _ci_check_sot_identity_inputs ;;
        workflow-ci-variables) _ci_check_workflow_ci_variables "$@" ;;
        workflow-job-settings) _ci_check_workflow_job_settings "$@" ;;
        cargo-profile-tuning) _ci_check_cargo_profile_tuning "$@" ;;
        no-source-compiled-tools) _ci_check_no_source_compiled_tools "$@" ;;
        codeql-coverage) _ci_check_codeql_coverage "$@" ;;
        version-drift) _ci_version_verify ;;
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
        bats-and-chain) _ci_check_bats_and_chain "$@" ;;
        if-without-else-status) _ci_check_if_without_else_status "$@" ;;
        exit-evidence) _ci_check_exit_evidence "$@" ;;
        ci-bats) _ci_check_ci_bats "$@" ;;
        setup-prompt-drift) _ci_check_setup_prompt_drift "$@" ;;
        pr-title) _ci_check_pr_title "$@" ;;
        stable-external-images) _ci_check_stable_external_images "$@" ;;
        pr-template) _ci_check_pr_template "$@" ;;
        workflow-line-limit) _ci_check_workflow_line_limit "$@" ;;
        pr-tracking-metadata) _ci_check_pr_tracking_metadata "$@" ;;
        orphaned-branches) _ci_check_orphaned_branches "$@" ;;
        action-node-versions) _ci_check_action_node_versions "$@" ;;
        governance-guards) _ci_check_governance_guards "$@" ;;
        naming-consistency) _ci_check_naming_consistency "$@" ;;
        compose-healthchecks) _ci_check_compose_healthchecks "$@" ;;
        proxy-cache-env-doc-drift) _ci_check_proxy_cache_env_doc_drift "$@" ;;
        changelog-direct-edit) _ci_check_changelog_direct_edit "$@" ;;
        prebuilt-prod) _ci_check_prebuilt_prod "$@" ;;
        prod-state-wiring) _ci_check_prod_state_wiring "$@" ;;
        compose-config) _ci_check_compose_config "$@" ;;
        nats-atomic-write) _ci_check_nats_atomic_write "$@" ;;
        docker-socket-proxy) _ci_check_docker_socket_proxy "$@" ;;
        netdata-isolation) _ci_check_netdata_isolation "$@" ;;
        syslog-logs-volume) _ci_check_syslog_logs_volume "$@" ;;
        proxy-cert-volume) _ci_check_proxy_cert_volume "$@" ;;
        proxy-nginx-policy) _ci_check_proxy_nginx_policy "$@" ;;
        compose-required-env) _ci_check_compose_required_env "$@" ;;
        dhcp-proxy-env) _ci_check_dhcp_proxy_env "$@" ;;
        setup-keys-kea) _ci_check_setup_keys_kea "$@" ;;
        setup-update-safety) _ci_check_setup_update_safety "$@" ;;
        setup-docker-conflict) _ci_check_setup_docker_conflict "$@" ;;
        image-channel-resolution) _ci_check_image_channel_resolution "$@" ;;
        vex-drift) _ci_check_vex_drift "$@" ;;
        logging-matrix) _ci_check_logging_matrix "$@" ;;
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
