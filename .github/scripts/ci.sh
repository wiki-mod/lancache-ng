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

# What: real path of this script and its directory.
# Why: a runner hook starts ci.sh through a symlink.
# From: Issue #1683 | PR #1858
CI_SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
CI_SCRIPT_DIR="${CI_SCRIPT_PATH%/*}"

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

# What: Dockerfile ARG names ci.sh supplies and reads.
# Why: a rust-build stage has no SOT; one ci.sh owner.
# From: Issue #1683 | PR #1912
CI_ARG_TOOLCHAIN_IMAGE=BUILD_TOOLS_IMAGE
CI_ARG_CRATES=RUST_CRATES
CI_ARG_TARGET=MUSL_TARGET
CI_ARG_PROCESSES=LANCACHE_PROCESSES
CI_ARG_GID=LANCACHE_RUNTIME_GID
CI_ARG_IMAGE_SETUP=IMAGE_SETUP
CI_ARG_DEFAULTS=LANCACHE_RUNTIME_DEFAULTS

# What: The ci.sh subcommand dispatch table.
# Why: One table is membership, dispatch and error text.
# From: Issue #1683
declare -A CI_DISPATCH=(
    [plan]=ci_cmd_plan [plan-matrix]=ci_cmd_plan_matrix [impact]=ci_cmd_impact [codeql-impact]=ci_cmd_codeql_impact [codeql-analyze]=ci_cmd_codeql_analyze [identity]=ci_cmd_identity
    [resolve]=ci_cmd_resolve [build]=ci_cmd_build [rust-build]=ci_cmd_rust_build [apk-setup]=ci_cmd_apk_setup [image-setup]=ci_cmd_image_setup
    [build-tools]=ci_cmd_build_tools [job-settings]=ci_cmd_job_settings [publish]=ci_cmd_publish [verify]=ci_cmd_verify [ship]=ci_cmd_ship [ship-release]=ci_cmd_ship_release [gha-runtime-args]=ci_cmd_gha_runtime_args
    [test]=ci_cmd_test [scan-channel]=ci_cmd_scan_channel [assemble]=ci_cmd_assemble
    [aggregate-stack]=ci_cmd_aggregate_stack [scan-stack]=ci_cmd_scan_stack [changed-files]=ci_cmd_changed_files
    [assemble-stack]=ci_cmd_assemble_stack [test-stack]=ci_cmd_test_stack [nightly-report]=ci_cmd_nightly_report
    [validate]=ci_cmd_validate [result-gate]=ci_cmd_result_gate [promote]=ci_cmd_promote [promote-ref]=ci_cmd_promote_ref [channel-checkout]=ci_cmd_channel_checkout [channel-matrix]=ci_cmd_channel_matrix [channel-check]=ci_cmd_channel_check [channel-report]=ci_cmd_channel_report [release-validation]=_ci_release_validation_valid [release-ref]=_ci_release_ref
    [release-publish]=ci_cmd_release_publish [release-images]=ci_cmd_release_images [release-sbom-stack]=ci_cmd_release_sbom_stack [release-vex]=ci_cmd_release_vex [cut-release-tag]=ci_cmd_cut_release_tag [release-notes]=ci_cmd_release_notes [release-changelog]=ci_cmd_release_changelog [release-variable]=ci_cmd_release_variable
    [gc]=ci_cmd_gc [gc-refs]=ci_cmd_gc_refs [check]=ci_cmd_check [close-linked-issues]=ci_cmd_close_linked_issues [pr-labels]=ci_cmd_pr_labels [board-add]=ci_cmd_board_add
    [welcome]=ci_cmd_welcome [version]=ci_cmd_version [docker-daemon-config]=ci_cmd_docker_daemon_config [runner-host]=ci_cmd_runner_host
    [have-command]=ci_cmd_have_command [pr-green-mark]=ci_cmd_pr_green_mark
)

# What: check name -> "scope function" for ci.sh check.
# Why: one table is membership, run scope and dispatch.
# From: Issue #1683 | PR #1912
declare -gA CI_CHECKS=(
    [line-endings]="diff _ci_check_line_endings" [comments]="diff _ci_check_comments"
    [deny-short-sha]="diff _ci_check_deny_short_sha" [language-policy]="diff _ci_check_language_policy"
    [mutable-refs]="diff _ci_check_mutable_refs" [executable-bits]="diff _ci_check_executable_bits"
    [shell-guards]="diff _ci_check_shell_guards"
    [bats-and-chain]="diff _ci_check_bats_and_chain" [exit-evidence]="diff _ci_check_exit_evidence"
    [ci-bats]="diff _ci_check_ci_bats"
    [governance-guards]="diff _ci_check_governance_guards" [changelog-direct-edit]="diff _ci_check_changelog_direct_edit"
    [action-node-versions]="repo _ci_check_action_node_versions" [action-majors]="job _ci_check_action_majors"
    [naming-consistency]="repo _ci_check_naming_consistency" [workflow-line-limit]="repo _ci_check_workflow_line_limit"
    [stable-external-images]="repo _ci_check_stable_external_images" [compose-healthchecks]="repo _ci_check_compose_healthchecks"
    [proxy-cache-env-doc-drift]="repo _ci_check_proxy_cache_env_doc_drift" [prebuilt-prod]="repo _ci_check_prebuilt_prod"
    [prod-state-wiring]="repo _ci_check_prod_state_wiring" [compose-config]="repo _ci_check_compose_config"
    [netdata-isolation]="repo _ci_check_netdata_isolation" [proxy-cert-volume]="repo _ci_check_proxy_cert_volume"
    [proxy-nginx-policy]="repo _ci_check_proxy_nginx_policy"
    [setup-update-safety]="repo _ci_check_setup_update_safety" [image-channel-resolution]="repo _ci_check_image_channel_resolution"
    [vex-drift]="repo _ci_check_vex_drift" [logging-matrix]="repo _ci_check_logging_matrix"
    [dockerfiles]="repo _ci_check_dockerfiles"
    [sot-identity-inputs]="repo _ci_check_sot_identity_inputs" [workflow-ci-variables]="repo _ci_check_workflow_ci_variables"
    [workflow-job-settings]="repo _ci_check_workflow_job_settings" [cargo-profile-tuning]="repo _ci_check_cargo_profile_tuning"
    [codeql-coverage]="repo _ci_check_codeql_coverage"
    [version-drift]="repo _ci_version_release"
    [pr-title]="pr _ci_check_pr_title" [pr-template]="pr _ci_check_pr_template" [pr-tracking-metadata]="job _ci_check_pr_tracking_metadata"
    [cargo-audit]="job _ci_check_cargo_audit" [shellcheck]="job _ci_check_shellcheck"
    [actionlint]="job _ci_check_actionlint" [orphaned-branches]="job _ci_check_orphaned_branches"
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

# What: run git; its status text on stderr is raw output.
# Why: git writes progress to stderr; only rc fails it.
# From: Issue #1683 | PR #1858
_ci_git_run() {
    _ci_run "[CI-ERROR-CORE-0157]" "reason=\"git command failed\"" git "$@"
}

# What: run a command; failure = caller's id, ctx, rc, raw.
# Why: one owner for coded command errors and their raw.
# From: Issue #1683 | PR #1858
_ci_run() {
    local okmax=0 strict="" ofile="" id ctx err out="" rc=0
    # What: -m N: rc to N ok; -s: stderr fails; -o F: to F
    # Why: grep rc 1 is a miss; big trees skip bash strings
    # From: Issue #1683 | PR #1858
    while :; do
        case "${1:-}" in
            -m) okmax="$2"; shift 2 ;;
            -s) strict=1; shift ;;
            -o) ofile="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    id="$1" ctx="$2"
    shift 2
    err="$(_ci_mktemp "${CI_TMPDIR}/ci-run.XXXXXX")" || return 2
    if [ -n "${ofile}" ]; then
        "$@" > "${ofile}" 2>"${err}" || rc=$?
    else
        out="$("$@" 2>"${err}")" || rc=$?
    fi
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

# What: run "$@" with a fresh work dir last; then remove it.
# Why: one cleanup owner for temp work dirs; rc is kept.
# From: Issue #1683 | PR #1912
_ci_with_workdir() {
    local prefix="$1" dir rc=0
    shift
    dir="$(_ci_mktemp -d "${CI_TMPDIR}/${prefix}.XXXXXX")" || return 2
    "$@" "${dir}" || rc=$?
    rm -rf "${dir}"
    return "${rc}"
}

# What: path of a command on PATH; rc 1 when it is absent.
# Why: one owner for command lookup; callers report absence.
# From: Issue #1683 | PR #1912
_ci_command_path() {
    command -v "$1"
}

# What: true if the command resolves on PATH.
# Why: the path is printed; callers need only the rc.
# From: Issue #1683 | PR #1912
_ci_command_available() {
    local resolved
    resolved="$(_ci_command_path "$1")" || return 1
    [ -n "${resolved}" ]
}

# What: sha256 hex digest of stdin, without the file column.
# Why: one hash owner; callers keep only the digest.
# From: Issue #1683 | PR #1912
_ci_sha256_hex() {
    local out
    out="$(_ci_capture 0 sha256sum)" || return 2
    printf '%s\n' "${out%% *}"
}

# What: true if a whole line of the list equals the needle.
# Why: one membership owner; no grep exit code to misread.
# From: Issue #1683 | PR #1912
_ci_list_has() {
    local needle="$1" line
    while IFS= read -r line; do
        if [ "${line}" = "${needle}" ]; then return 0; fi
    done <<< "$2"
    return 1
}

# What: one line against an ERE: rc 0, 1 none, 2 bad ERE.
# Why: a command rc; $? after [[ ]] is a condition (SC2319).
# From: Issue #1683 | PR #1912
_ci_re_test() { [[ "$1" =~ $2 ]]; }

# What: any line of the text matches the ERE; 2 = bad ERE.
# Why: one text-regex owner; no grep exit code to misread.
# From: Issue #1683 | PR #1912
_ci_text_has() {
    local icase=0 own=0 re line r=1
    if [ "$1" = -i ]; then icase=1; shift; fi
    re="$1"
    if [ "${icase}" -eq 1 ] && ! shopt -q nocasematch; then shopt -s nocasematch; own=1; fi
    while IFS= read -r line; do
        if _ci_re_test "${line}" "${re}"; then r=0; else r=$?; fi
        if [ "${r}" -ne 1 ]; then break; fi
    done <<< "$2"
    if [ "${own}" -eq 1 ]; then shopt -u nocasematch; fi
    if [ "${r}" -eq 2 ]; then ci_log "[CI-ERROR-CORE-0154]" "re=\"${re}\" reason=\"invalid regular expression\""; fi
    return "${r}"
}

# What: number of non-empty lines in the text.
# Why: one counting owner; no grep exit code to misread.
# From: Issue #1683 | PR #1912
_ci_count_lines() {
    local line n=0
    while IFS= read -r line; do
        if [ -n "${line}" ]; then n=$((n + 1)); fi
    done <<< "$1"
    printf '%s\n' "${n}"
}

# What: line 2 of the text; nothing when it has one line.
# Why: one second-line owner; no external line cutter.
# From: Issue #1683 | PR #1912
_ci_second_line() {
    local rest
    case "$1" in
        *$'\n'*) rest="${1#*$'\n'}"; printf '%s\n' "${rest%%$'\n'*}" ;;
    esac
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

# What: git http header value for token $1.
# Why: one owner for the PAT and the job token header.
# From: Issue #1683 | PR #1858
_ci_git_auth_header() {
    printf 'AUTHORIZATION: basic %s' "$(printf '%s' "x-access-token:$1" | base64 -w0)"
}

# What: trust the checkout; CI_GIT_TOKEN as push auth.
# Why: foreign checkout owner; arm64 clone has no token.
# From: Issue #1683 | PR #1858
_ci_git_trust_init() {
    local dir="${GITHUB_WORKSPACE:-}" n="${GIT_CONFIG_COUNT:-0}"
    local token="${CI_GIT_TOKEN:-}" srv key
    if [ -z "${dir}" ]; then
        return 0
    fi
    export "GIT_CONFIG_KEY_${n}=safe.directory" "GIT_CONFIG_VALUE_${n}=${dir}"
    n=$((n + 1))
    if [ -n "${token}" ]; then
        srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
        key="http.${srv}/.extraheader"
        # What: empty value drops checkout's token header
        # Why: else git sends two AUTHORIZATION headers
        # From: Issue #1683 | PR #1858
        export "GIT_CONFIG_KEY_${n}=${key}" "GIT_CONFIG_VALUE_${n}="
        n=$((n + 1))
        export "GIT_CONFIG_KEY_${n}=${key}" "GIT_CONFIG_VALUE_${n}=$(_ci_git_auth_header "${token}")"
        n=$((n + 1))
    fi
    export GIT_CONFIG_COUNT="${n}"
}

# What: Export the LAN proxy on self-hosted runners only.
# Why: AG-CI-009 proxy; hosted runners have no LAN route.
# From: Issue #1683 | PR #1858
_ci_proxy_init() {
    local http="" https="" exclusion=""
    # What: read the proxy values on self-hosted only.
    # Why: CI_VARIABLES is the source; hosted needs no jq.
    # From: Issue #1683 | PR #1912
    if _ci_runner_self_hosted; then
        http="$(_ci_variable_env PROJECT_SELFHOSTED_PROXY_HTTP)" || return 2
    fi
    if [ -z "${http}" ]; then
        ci_log "[CI-INFO-CORE-0113]" "proxy=off runner=\"${RUNNER_ENVIRONMENT:-unset}\" http_set=no"
        return 0
    fi
    https="$(_ci_variable_env PROJECT_SELFHOSTED_PROXY_HTTPS)" || return 2
    exclusion="$(_ci_variable_env PROJECT_SELFHOSTED_PROXY_EXCLUSION)" || return 2
    export HTTP_PROXY="${http}" http_proxy="${http}"
    export HTTPS_PROXY="${https:-${http}}"
    export https_proxy="${HTTPS_PROXY}"
    export NO_PROXY="${exclusion}" no_proxy="${exclusion}"
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

# What: yq rows: bad value first, tag, text; T is a tab.
# Why: yq reads the YAML; a "\t" literal stays 2 chars.
# From: Issue #1683 | PR #1912
_CI_YQ_SOT_ROWS="$(cat <<'PROG'
(.. | select(tag == "!!str") | select(test("[\n\t]")) | "x" + strenv(T) + (path | join("/")) + strenv(T) + "value holds a newline or tab"),
(.. | select(tag == "!!map") | keys | .[] | select(test("[/\n\t]")) | "x" + strenv(T) + . + strenv(T) + "key holds a slash, newline or tab"),
(.. | select(tag == "!!seq") | .[] | select(tag == "!!map" or tag == "!!seq") | "x" + strenv(T) + (path | join("/")) + strenv(T) + "list item is no scalar"),
(.. | select((path | length) > 0) | "t" + strenv(T) + (path | join("/")) + strenv(T) + tag),
(.. | select(tag != "!!map" and tag != "!!seq") | "v" + strenv(T) + (path | join("/")) + strenv(T) + tostring)
PROG
    )"

# What: expand each @{block.key} of $1 into REPLY.
# Why: a value naming another SOT value is not copied.
# From: Issue #1683 | PR #1912
_ci_sot_expand() {
    local rest="$1" out="" t m why
    # What: _ci_sc, _ci_res, _ci_busy: _ci_sot_index locals.
    # Why: bash scope is dynamic; one table per index run.
    # From: Issue #1683 | PR #1912
    while [[ "${rest}" =~ @\{([A-Za-z0-9_.-]+)\} ]]; do
        m="${BASH_REMATCH[0]}" t="${BASH_REMATCH[1]//./\/}" why=""
        out+="${rest%%"${m}"*}"
        rest="${rest#*"${m}"}"
        if [ -z "${_ci_res[${t}]+set}" ]; then
            if [ -z "${_ci_sc[${t}]+set}" ]; then
                why="SOT reference is no string or number"
            elif [ -n "${_ci_busy[${t}]+set}" ]; then
                why="SOT reference cycle"
            fi
            if [ -n "${why}" ]; then
                ci_log "[CI-ERROR-CORE-0150]" "ref=\"${m}\" reason=\"${why}\""
                return 2
            fi
            _ci_busy["${t}"]=1
            _ci_sot_expand "${_ci_sc[${t}]}" || return 2
            _ci_res["${t}"]="${REPLY}"
            unset '_ci_busy[$t]'
        fi
        out+="${_ci_res[${t}]}"
    done
    REPLY="${out}${rest}"
}

# What: index a SOT file, or one subtree, under a prefix.
# Why: one yq parse; bash fills the store, no eval.
# From: Issue #1683 | PR #1912
_ci_sot_index() {
    local file="$1" want="$2" kp="$3" rows f p v par last kind val pre rest d key
    local -a order=()
    local -A tg=() txt=() lists=() acc=() _ci_sc=() _ci_res=() _ci_busy=()
    _CI_SOT_RAW_ERR="raw in the CORE-0139/0150/0153 line above"
    rows="$(_ci_run -s "[CI-ERROR-CORE-0139]" "file=\"${file}\" reason=\"yq cannot read the SOT\"" \
        env T=$'\t' yq -r "${_CI_YQ_SOT_ROWS}" "${file}")" || return 2
    while IFS=$'\t' read -r f p v; do
        case "${f}" in
            t) order+=("${p}"); tg["${p}"]="${v}" ;;
            v) txt["${p}"]="${v}" ;;
            *)
                ci_log "[CI-ERROR-CORE-0153]" "file=\"${file}\" path=\"${p}\" reason=\"SOT row unusable: ${v}\""
                return 2
                ;;
        esac
    done <<< "${rows}"
    # What: null is ""; a string or number is a ref target.
    # Why: same scalar rules as the readers always had.
    # From: Issue #1683 | PR #1912
    for p in "${!txt[@]}"; do
        case "${tg[${p}]}" in
            '!!null') txt["${p}"]="" ;;
            '!!bool') ;;
            *) _ci_sc["${p}"]="${txt[${p}]}" ;;
        esac
    done
    for p in "${order[@]}"; do
        par="${p%/*}"
        [ "${par}" != "${p}" ] || par=""
        # What: a list item joins its list's i: entry.
        # Why: readers take a list one item per line.
        # From: Issue #1683 | PR #1912
        if [ -n "${par}" ] && [ "${tg[${par}]}" = '!!seq' ]; then
            _ci_sot_expand "${txt[${p}]}" || return 2
            lists["${par}"]+="${REPLY}"$'\n'
            continue
        fi
        case "${tg[${p}]}" in
            '!!map') kind=c val="" ;;
            '!!seq') kind=l val="" ;;
            *) kind=s; _ci_sot_expand "${txt[${p}]}" || return 2; val="${REPLY}" ;;
        esac
        last="${p##*/}"
        acc["c:${par}"]+="${last}"$'\n'
        [ "${kind}" != c ] || acc["b:${par}"]+="${last}"$'\n'
        acc["k:${p}"]="${kind}" acc["v:${p}"]="${val}"
        # What: f:, a: map <2 or 3 parts>/<last> to paths.
        # Why: an entry field may sit one block deeper.
        # From: Issue #1683 | PR #1858
        rest="${p}" pre="" d=0
        while [ "${rest}" != "${rest#*/}" ] && [ "${d}" -lt 3 ]; do
            pre+="${pre:+/}${rest%%/*}" rest="${rest#*/}" d=$((d + 1))
            [ "${d}" -ge 2 ] || continue
            key="${pre}/${last}"
            [ -n "${acc["f:${key}"]+set}" ] || acc["f:${key}"]="${p}"
            acc["a:${key}"]+="${p}"$'\n'
        done
    done
    for p in "${!lists[@]}"; do
        acc["i:${p}"]="${lists[${p}]}"
    done
    # What: keep only keys inside the wanted subtree.
    # Why: a view holds what its reader asked for.
    # From: Issue #1683 | PR #1858
    for key in "${!acc[@]}"; do
        p="${key#?:}"
        [ -z "${want}" ] || [ "${p}" = "${want}" ] || [[ "${p}" == "${want}/"* ]] || continue
        _CI_SOT["${kp}${key}"]="${acc[${key}]}"
    done
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

# What: read entry fields: block entry field var ... pairs.
# Why: one owner for the field-by-field SOT read.
# From: Issue #1683 | PR #1912
_ci_block_entry_fields() {
    local block="$1" entry="$2" v
    shift 2
    while [ "$#" -gt 0 ]; do
        v="$(_ci_block_entry_field "${block}" "${entry}" "$1")" || return 2
        printf -v "$2" '%s' "${v}"
        shift 2
    done
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
    local v known
    # What: list; block/blocklist = a top-level value/list.
    # Why: one owner for a missing required SOT field.
    # From: Issue #1683 | PR #1912
    case "${3:-}" in
        "") v="$(ci_service_field "$1" "$2")" || return 2 ;;
        list) v="$(_ci_target_list "$1" "$2")" || return 2 ;;
        block) v="$(_ci_block_entry_field "$1" "" "$2")" || return 2 ;;
        blocklist) v="$(_ci_block_entry_list "$1" "" "$2")" || return 2 ;;
        *) ci_log "[CI-ERROR-CORE-0146]" "target=\"$1\" field=\"$2\" kind=\"$3\" reason=\"kind must be empty, list, block or blocklist\""; return 2 ;;
    esac
    if [ -z "${v}" ]; then
        # What: a target not in the SOT is named as such.
        # Why: an unknown name is no missing field.
        # From: Issue #1683 | PR #1858
        if [ "${3:-}" = "" ] || [ "${3:-}" = list ]; then
            known="$(ci_build_targets)" || return 2
            if [[ $'\n'"${known}"$'\n' != *$'\n'"$1"$'\n'* ]]; then
                ci_log "[CI-ERROR-CORE-0147]" "target=\"$1\" known=\"${known//$'\n'/ }\" reason=\"not an SOT build target\""
                return 2
            fi
        fi
        ci_log "[CI-ERROR-CORE-0009]" \
            "target=\"$1\" field=\"$2\" reason=\"required SOT field missing\""
        return 2
    fi
    printf '%s\n' "${v}"
}

# What: workspace rows: member dir|bin path|crate.
# Why: Cargo.toml owns the members; the SOT copies none.
# From: Issue #1683 | PR #1912
_ci_workspace_rows() {
    local root="${1:-${CI_REPO_ROOT:-.}}" manifest members m row mf
    manifest="$(_ci_repo_path CI_CARGO_MANIFEST "${root}")" || return 2
    members="$(_ci_cargo_members "${manifest}")" || return 2
    # What: a member without [[bin]] is a library.
    # Why: a library counts with its whole dir.
    # From: Issue #1683 | PR #1912
    while IFS= read -r m; do
        [ -n "${m}" ] || continue
        # What: a member without a manifest stays a row.
        # Why: the dir then fails the dead-path gate.
        # From: Issue #1683 | PR #1912
        mf="$(_ci_repo_path CI_CARGO_MANIFEST "${root}/${m}")" || return 2
        if [ ! -f "${mf}" ]; then
            printf '%s||\n' "${m}"
            continue
        fi
        row="$(_ci_capture 0 yq -p toml -oy '(.bin[0].path // "") + "|" + .package.name' "${mf}")" || return 2
        printf '%s|%s\n' "${m}" "${row}"
    done <<< "${members}"
}

# What: the source dir of a bin: its path's directory.
# Why: a bin at the member root makes the member dir it.
# From: Issue #1683 | PR #1912
_ci_workspace_src_dir() {
    case "$2" in
        */*) printf '%s/%s\n' "$1" "${2%/*}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# What: the repo paths a Rust service builds from.
# Why: plan and the context-edge check read one list.
# From: Issue #1683 | PR #1912
ci_service_context_paths() {
    local svc="$1" root="${2:-${CI_REPO_ROOT:-.}}" own crates manifest lock rows dir bin crate type
    type="$(_ci_required_field "${svc}" build_type)" || return 2
    [ "${type}" = rust ] || return 0
    own="$(_ci_required_field "${svc}" context)" || return 2
    crates="$(_ci_required_field "${svc}" crates list)" || return 2
    crates=" ${crates//$'\n'/ } "
    manifest="$(_ci_variable CI_CARGO_MANIFEST)" || return 2
    lock="$(_ci_variable CI_CARGO_LOCK)" || return 2
    rows="$(_ci_workspace_rows "${root}")" || return 2
    printf '%s\n%s\n' "${manifest}" "${lock}"
    while IFS='|' read -r dir bin crate; do
        case "${dir}" in "${own}" | "${own}"/*) continue ;; esac
        if [ -z "${bin}" ]; then
            printf '%s\n' "${dir}"
            continue
        fi
        printf '%s/%s\n' "${dir}" "${manifest}"
        if [[ "${crates}" == *" ${crate} "* ]]; then
            _ci_workspace_src_dir "${dir}" "${bin}"
        fi
    done <<< "${rows}"
}

# What: every workspace source dir CodeQL analyzes.
# Why: a bin's source dir or a library's whole dir.
# From: Issue #1683 | PR #1912
ci_workspace_source_dirs() {
    local rows dir bin crate
    rows="$(_ci_workspace_rows "$1")" || return 2
    while IFS='|' read -r dir bin crate; do
        if [ -z "${bin}" ]; then printf '%s\n' "${dir}"; else _ci_workspace_src_dir "${dir}" "${bin}"; fi
    done <<< "${rows}"
}

# What: a CodeQL language's analyzed paths.
# Why: "@rust_workspace" expands to the member source dirs.
# From: Issue #1683 | PR #1912
_ci_codeql_paths() {
    local raw p
    raw="$(_ci_block_entry_list codeql_languages "$1" paths)" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        if [ "${p}" = "@rust_workspace" ]; then ci_workspace_source_dirs "${CI_REPO_ROOT:-.}" || return 2; else printf '%s\n' "${p}"; fi
    done <<< "${raw}"
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
            _ci_list_has "${p}" "${global}" && continue
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

# What: runner label of a platform; true picks self-hosted.
# Why: GitHub-hosted default; one repo var moves all jobs.
# From: Issue #1683 | PR #1912
_ci_runner_label() {
    local platform="$1" id="$2" ctx="${3:-}" use field=runner
    use="$(_ci_variable PROJECT_SELFHOSTED_RUNNER_USAGE_CI)" || return 2
    [ "${use}" != true ] || field=runner_self_hosted
    _ci_platform_field "${platform}" "${field}" "${id}" "${ctx}"
}

# What: GitHub-hosted label of the first platform.
# Why: jobs that must never run on the fleet use it.
# From: Issue #1683 | PR #1858
_ci_hosted_runner() {
    local id="$1" plat
    plat="$(_ci_build_matrix_platforms)" || return 2
    _ci_platform_field "${plat%%$'\n'*}" runner "${id}" "reason=\"no GitHub-hosted runner for the first build_matrix platform\""
}

# =========================================================
# IMPACT ENGINE
# =========================================================

# What: Read the changed-path list for this run.
# Why: CHANGED_FILES (file) or args; no hidden git walk.
# From: Issue #1683
_ci_changed_files() {
    if [ -n "${CHANGED_FILES:-}" ]; then
        # What: a set list path must be an existing file.
        # Why: AG-VAL-002: a missing list is no empty diff.
        # From: Issue #1683 | PR #1858
        [ -f "${CHANGED_FILES}" ] || { printf 'CHANGED_FILES=%s: no such file\n' "${CHANGED_FILES}"; return 1; }
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

# What: the repo paths one build target is built from
# Why: plan and the release gate read one path list
# From: Issue #1683 | PR #1858
_ci_target_paths() {
    local target="$1" context
    context="$(_ci_required_field "${target}" context)" || return 2
    printf '%s\n' "${context}"
    ci_service_context_paths "${target}"
}

# What: True if a target's contexts touch changed paths.
# Why: One candidate rule for plan and Base-CI matrix.
# From: Issue #1683
_ci_plan_candidate() {
    local service="$1" paths p
    shift
    paths="$(_ci_target_paths "${service}")" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        _ci_paths_touch "${p}" "$@" && return 0
    done <<< "${paths}"
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

# What: rc 0 if reader $1 for $2 differs base..head.
# Why: comment-only edits keep identity (§11.1/§12.5).
# From: Issue #1683 | PR #1858
_ci_content_changed() {
    local reader="$1" subject="$2" base="${3:-}" head="${4:-}" a b refs
    if [ -z "${base}" ]; then
        refs="$(_ci_diff_refs)" || return 2
        read -r base head <<<"${refs}"
    fi
    if [ -z "${base}" ]; then
        ci_log "[CI-INFO-IMPACT-0012]" "reader=\"${reader}\" subject=\"${subject}\" reason=\"no base ref for this event; content counts as changed\""
        return 0
    fi
    # What: the readers take subject, ref and mode "".
    # Why: path ids and the §29 test identity, one rule.
    # From: Issue #1683 | PR #1858
    a="$("${reader}" "${subject}" "${base}" "")" || return 2
    b="$("${reader}" "${subject}" "${head}" "")" || return 2
    [ "${a}" != "${b}" ]
}

# What: CodeQL admission: the admitted language matrix.
# Why: §70: no runner without an admitted language.
# From: Issue #1683 | PR #1858
ci_cmd_codeql_impact() {
    local -a changed=()
    _ci_collect_changed changed "$@" || return 2
    local include='[]' lang p hit langs paths rc n
    langs="$(_ci_block_keys codeql_languages)" || return 2
    while IFS= read -r lang; do
        [ -n "${lang}" ] || continue
        hit=false
        paths="$(_ci_codeql_paths "${lang}")" || return 2
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            _ci_paths_touch "${p}" "${changed[@]}" || continue
            rc=0; _ci_content_changed _ci_tracked_content_ids "${p}" || rc=$?
            case "${rc}" in 0) hit=true; break ;; 1) ;; *) return 2 ;; esac
        done <<< "${paths}"
        [ "${hit}" = true ] && { include="$(_ci_matrix_append "${include}" language="${lang}")" || return 2; }
    done <<< "${langs}"
    printf 'codeql-matrix=%s\n' "$(_ci_matrix_doc "${include}")"
    # What: analyze always on the GitHub-hosted runner.
    # Why: CodeQL needs 4-8 GB RAM; the fleet has less.
    # From: Issue #1683 | PR #1858
    local runner
    runner="$(_ci_hosted_runner "[CI-ERROR-CODEQL-0019]")" || return 2
    printf 'codeql-runner=%s\n' "${runner}"
    n="$(_ci_capture 0 jq -r 'length' <<< "${include}")" || return 2
    ci_log "[CI-INFO-CODEQL-0001]" "phase=codeql-impact langs=${n} changed=${#changed[@]}"
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
        paths="$(_ci_codeql_paths "${lang}")" || return 2
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
    if ! _ci_retry download _ci_http_download "${url}" "${dest}" >&2; then
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

# What: GET a public GitHub API URL, without a token.
# Why: an org IP allow list refuses the job token (403).
# From: Issue #1683 | PR #1858
_ci_github_get() {
    curl --fail-with-body -sSL -H 'Accept: application/vnd.github+json' "$1"
}

# What: print memo $1 of this job; 1 when there is none.
# Why: one RUNNER_TEMP memo owner; GitHub clears it.
# From: Issue #1683 | PR #1858
_ci_job_memo_get() {
    if [ -z "${RUNNER_TEMP:-}" ] || [ ! -s "${RUNNER_TEMP}/$1" ]; then
        return 1
    fi
    printf '%s\n' "$(<"${RUNNER_TEMP}/$1")"
}

# What: keep value $2 as memo $1 of this job.
# Why: outside a GitHub job there is no memo to keep.
# From: Issue #1683 | PR #1858
_ci_job_memo_put() {
    local out
    if [ -z "${RUNNER_TEMP:-}" ]; then
        return 0
    fi
    if ! out="$(printf '%s\n' "$2" 2>&1 > "${RUNNER_TEMP}/$1")"; then
        ci_error "[CI-ERROR-RESOLVE-0012]" "path=\"${RUNNER_TEMP}/$1\" reason=\"value not kept for the job\"" "${out}"
        return 2
    fi
}

# What: latest release of a SOT tool: tag, asset, url, sha.
# Why: no third-party pin; GitHub names tag and sha256.
# From: Issue #1683 | PR #1858
_ci_tool_latest() {
    local key="$1" repo asset api json rel tag ver name digest link sha="" url="" memo
    _ci_block_entry_fields external_versions "${key}" repository repo asset asset || return 2
    if [ -z "${repo}" ] || [ -z "${asset}" ]; then
        ci_log "[CI-ERROR-FETCH-0005]" "key=\"external_versions.${key}\" reason=\"repository/asset missing; FAIL CLOSED\""
        return 2
    fi
    api="$(_ci_variable CI_GITHUB_API_URL)" || return 2
    # What: one anonymous read per job and repository.
    # Why: anonymous reads have a small hourly limit.
    # From: Issue #1683 | PR #1858
    memo="latest-${repo//\//-}.json"
    if ! json="$(_ci_job_memo_get "${memo}")"; then
        if ! json="$(_ci_retry github-read _ci_github_get "${api}/repos/${repo}/releases/latest")"; then
            ci_error "[CI-ERROR-FETCH-0006]" "repo=\"${repo}\" reason=\"latest release not read\"" "${json}"
            return 2
        fi
        _ci_job_memo_put "${memo}" "${json}" || return 2
    fi
    rel="$(_ci_run "[CI-ERROR-FETCH-0008]" "repo=\"${repo}\" reason=\"release JSON not parsed\"" \
        jq -r '.tag_name, (.assets[] | "\(.name)\t\(.digest // "")\t\(.browser_download_url)")' <<< "${json}")" || return 2
    tag="${rel%%$'\n'*}"
    # What: @VERSION@ is the tag after its last v.
    # Why: v0.74.0 and codeql-bundle-v2.27.1 give X.Y.Z.
    # From: Issue #1683 | PR #1858
    ver="${tag##*v}"
    _ci_fill "${asset}" "VERSION=${ver}" || return 2
    asset="${REPLY}"
    while IFS=$'\t' read -r name digest link; do
        [ "${name}" = "${asset}" ] || continue
        sha="${digest#sha256:}"
        url="${link}"
    done <<< "${rel#*$'\n'}"
    if [[ ! "${sha}" =~ ^[0-9a-f]{64}$ ]] || [ -z "${url}" ]; then
        ci_error "[CI-ERROR-FETCH-0007]" "repo=\"${repo}\" tag=\"${tag}\" asset=\"${asset}\" reason=\"asset, sha256 digest or url not in the release\"" "${rel}"
        return 2
    fi
    printf '%s\t%s\t%s\t%s\n' "${tag}" "${asset}" "${url}" "${sha}"
}

# What: Fetch the latest CodeQL bundle; print binary.
# Why: the SOT names the tool; no action in the YAML.
# From: Issue #1683 | PR #1858
_ci_codeql_fetch() {
    local work="$1" rel tag asset url raw sha
    rel="$(_ci_tool_latest codeql)" || return 2
    IFS=$'\t' read -r tag asset url sha <<< "${rel}"
    printf 'codeql bundle: %s\n' "${tag}" >&2
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
    if ! java="$(_ci_command_path java)"; then
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
    _ci_run "[CI-ERROR-CODEQL-0009]" "language=\"${lang}\" reason=\"database create failed\"" \
        "${codeql}" database create "${work}/db" --language="${lang}" --build-mode=none \
        --source-root="${CI_REPO_ROOT:-.}" --codescanning-config="${work}/config.yml" >&2 || return 2
    _ci_run "[CI-ERROR-CODEQL-0010]" "language=\"${lang}\" reason=\"database analyze failed\"" \
        "${codeql}" database analyze "${work}/db" --format=sarif-latest \
        --sarif-category="/language:${lang}" --output="${work}/result.sarif" >&2 || return 2
    if ! _ci_retry github-api "${codeql}" github upload-results --repository="${GITHUB_REPOSITORY}" \
            --ref="${GITHUB_REF}" --commit="${GITHUB_SHA}" --sarif="${work}/result.sarif" >&2; then
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
    if ! _ci_list_has "${lang}" "${langs}"; then
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

# What: path $1: rc 0 doc, 1 no doc, 3 SOT-named doc.
# Why: docs dir $2, SOT paths $3; one doc rule (§63).
# From: Issue #1683 | PR #1858
_ci_doc_path() {
    case "$1" in
        *.md|"$2"/*) ;;
        *) return 1 ;;
    esac
    ! _ci_list_has "$1" "$3" || return 3
}

# What: rc 0 if every path is a doc no SOT key names.
# Why: docs are NOOP (§63) unless an input (§12.4).
# From: Issue #1683 | PR #1858
_ci_docs_only() {
    [ "$#" -gt 0 ] || return 1
    local f named docs rc
    named="$(_ci_sot_named_paths)" || return 2
    docs="$(_ci_variable CI_DOCS_DIR)" || return 2
    for f in "$@"; do
        rc=0; _ci_doc_path "${f}" "${docs}" "${named}" || rc=$?
        [ "${rc}" -ne 1 ] || return 1
        if [ "${rc}" -eq 3 ]; then
            ci_log "[CI-INFO-PLAN-0007]" "path=\"${f}\" reason=\"doc is a SOT-named input; not docs-only\""
            return 1
        fi
    done
    return 0
}

# What: sha256 of the non-doc tree and every pair digest.
# Why: one value names the checked tree and images.
# From: Issue #1683 | PR #1858
_ci_pr_fingerprint() {
    local tree line named docs rc _ci_fp_rows="" _ci_fp_absent=""
    named="$(_ci_sot_named_paths)" || return 2
    docs="$(_ci_variable CI_DOCS_DIR)" || return 2
    tree="$(_ci_capture 0 git -C "${CI_REPO_ROOT}" ls-tree -r HEAD)" || return 2
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        rc=0; _ci_doc_path "${line#*$'\t'}" "${docs}" "${named}" || rc=$?
        [ "${rc}" -eq 0 ] || _ci_fp_rows+="${line}"$'\n'
    done <<< "${tree}"
    _ci_for_all_pairs _ci_pr_fingerprint_pair || return "$?"
    # What: a pair without an image gives no value.
    # Why: only a published digest was checked (§2.3).
    # From: Issue #1683 | PR #1858
    if [ -n "${_ci_fp_absent}" ]; then
        ci_log "[CI-INFO-PLAN-0011]" "absent=\"${_ci_fp_absent% }\" reason=\"pair has no image; no fingerprint\""
        return 1
    fi
    printf '%s' "${_ci_fp_rows}" | _ci_sha256_hex
}

# What: add "pair svc plat id digest" to the fingerprint.
# Why: a new digest of any pair needs the full run.
# From: Issue #1683 | PR #1858
_ci_pr_fingerprint_pair() {
    local id digest rc=0
    id="$(_ci_identity_for "$1" "$2")" || return 2
    digest="$(_ci_published_digest "$1" "$2" ok)" || rc=$?
    case "${rc}" in
        0) _ci_fp_rows+="pair $1 $2 ${id} ${digest}"$'\n' ;;
        1) _ci_fp_absent+="$1/$2 " ;;
        *) return 2 ;;
    esac
}

# What: ref of the last green run mark of one PR.
# Why: one ref per PR keeps one value per PR.
# From: Issue #1683 | PR #1858
_ci_green_ref() {
    local prefix n
    n="$(_ci_env_required PR_NUMBER)" || return 2
    if [[ ! "${n}" =~ ^[1-9][0-9]*$ ]]; then
        ci_log "[CI-ERROR-PLAN-0012]" "pr=\"${n}\" reason=\"PR_NUMBER is no PR number\""
        return 2
    fi
    prefix="$(_ci_variable CI_GREEN_REF)" || return 2
    printf '%s/pr-%s' "${prefix}" "${n}"
}

# What: subject of a green run mark for fingerprint $1.
# Why: plan and result-mark compare one text.
# From: Issue #1683 | PR #1858
_ci_green_note() {
    printf 'green %s' "$1"
}

# What: rc 0 if the last green run had this fingerprint.
# Why: §2.1: an equal tree and digests give no new work.
# From: Issue #1683 | PR #1858
_ci_pr_green_reuse() {
    local fp ref rc=0
    [ "${GITHUB_EVENT_NAME:-}" = pull_request ] || return 1
    fp="$(_ci_pr_fingerprint)" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    ref="$(_ci_green_ref)" || return 2
    rc=0; _ci_mark_has "${ref}" "$(_ci_green_note "${fp}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    ci_log "[CI-INFO-PLAN-0013]" "ref=\"${ref}\" fingerprint=\"${fp}\" reason=\"last green run checked this tree and these digests; build, scan, test and validate NOT-RUN\""
}

# What: rc 0 if each release service has its index.
# Why: a red platform stays out, also on release.
# From: Issue #1683 | PR #1858
_ci_release_plan_gate() {
    local doc="$1" svcs svc idx miss="" rc
    svcs="$(_ci_capture 0 jq -r '.[].service' <<< "${doc}")" || return 2
    svcs="$(LC_ALL=C sort -u <<< "${svcs}")"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        rc=0; idx="$(_ci_candidate_index "${svc}")" || rc=$?
        if [ "${rc}" -eq 0 ]; then
            ci_log "[CI-WARN-RELEASE-0063]" "tag=\"${CI_RELEASE_TAG}\" service=\"${svc}\" index=\"${idx}\" reason=\"a platform is not accepted; the release leaves it out\""
            continue
        fi
        miss="${miss} ${svc}"
    done <<< "${svcs}"
    [ -n "${miss}" ] || return 0
    ci_error "[CI-ERROR-RELEASE-0062]" "tag=\"${CI_RELEASE_TAG}\" services=\"${miss# }\" reason=\"no assembled index for the accepted platforms (raw above); run ci.yml by workflow_dispatch on the release branch, then publish the tag again\"" "$(_ci_matrix_doc "${doc}")"
    return 2
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
    local service platform include='[]' any=false resolved paction pident pimpact runner authed=false test_services=''
    local _ci_plan_ids=""
    local sot_changed=false f path_cand rc plats unknown=""
    # What: SOT change makes every target id candidate.
    # Why: pins live in SOT; identity decides BUILD.
    # From: Issue #1683 | PR #1858
    for f in "${changed[@]}"; do [ "${f}" = "${CI_MANIFEST_REL}" ] && sot_changed=true; done
    # What: audit when a Rust service is a candidate.
    # Why: its generated lock is the audit input.
    # From: Issue #1683 | PR #1858
    local rust_audit=false
    # What: build product services and the toolchain.
    # Why: build-tools generic pipeline, separate assembly.
    # From: Issue #1683
    local targets svc_type
    targets="$(ci_build_targets)" || return 2
    # What: a refresh run compares apk with the index first.
    # Why: §17: a newer package gives the pair a new id.
    # From: Issue #1683 | PR #1858
    rc=0; _ci_refresh_event || rc=$?
    case "${rc}" in
        0)
            _ci_require_ghcr_auth || return "$?"
            authed=true
            _ci_package_refresh_all || return "$?"
            ;;
        1) ;;
        *) return 2 ;;
    esac
    for service in ${targets}; do
        path_cand=false rc=0
        _ci_plan_candidate "${service}" "${changed[@]}" || rc=$?
        case "${rc}" in 0) path_cand=true ;; 1) ;; *) return 2 ;; esac
        # What: log a service with no changed input
        # Why: §79: a skipped service names its reason
        # From: Issue #1683 | PR #1858
        if [ "${path_cand}" = false ] && [ "${sot_changed}" = false ]; then
            ci_log "[CI-INFO-PLAN-0006]" "service=\"${service}\" action=skip reason=\"no input path and no SOT change\""
            continue
        fi
        # What: path-changed rust is test candidate (§60).
        # Why: tests run on change, even build reuse (§60).
        # From: Issue #1683
        svc_type="$(_ci_required_field "${service}" build_type)" || return 2
        # What: tests and audit follow content, not paths.
        # Why: §29 §64: equal content, equal test identity.
        # From: Issue #1683 | PR #1858
        if [ "${svc_type}" = rust ]; then
            rc=0; _ci_content_changed _ci_identity_content "${service}" || rc=$?
            case "${rc}" in
                0)
                    [ "${path_cand}" = false ] || test_services="${test_services} ${service}"
                    rust_audit=true
                    ;;
                1) ;;
                *) return 2 ;;
            esac
        fi
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
            # What: one id per pair, fixed once per run.
            # Why: later jobs read it; none recomputes.
            # From: Issue #1683 | PR #1912
            _ci_plan_record "${service}" "${platform}" || return "$?"
            resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
            paction="$(_ci_record_field "${resolved}" action)" || return 2
            # What: MISMATCH state fails the plan
            # Why: a contradiction must not look green
            # From: Issue #1683 | PR #1912
            if [ "${paction}" = fail ]; then
                ci_error "[CI-ERROR-PLAN-0005]" "service=\"${service}\" platform=\"${platform}\" reason=\"ledger and registry digest disagree; no build, no accept\"" "${resolved}"
                return 2
            fi
            # What: UNKNOWN pairs are kept for escalation.
            # Why: 2.3: UNKNOWN never builds, never silent.
            # From: Issue #1683 | PR #1912
            if [ "${paction}" = escalate ]; then
                unknown+="${service}/${platform} resolve"$'\n'
                continue
            fi
            # What: unverified artifacts join the matrix
            # Why: ship verifies, scan accepts; no rebuild
            # From: Issue #1683 | PR #1912
            [ "${paction}" = build ] || [ "${paction}" = verify ] || [ "${paction}" = wait ] || continue
            # What: matrix holds targets with proven impact.
            # Why: MISSING_CONFIRMED must not build alone.
            # From: Issue #1683 | PR #1858
            pident="$(_ci_record_field "${resolved}" identity)" || return 2
            pimpact=BUILD
            if [ "${paction}" = build ]; then
                pimpact="$(_ci_semantic_impact "${service}" "${platform}" "${pident}")" || return 2
            fi
            [ "${pimpact}" != UNKNOWN ] || unknown+="${service}/${platform} impact"$'\n'
            [ "${pimpact}" = BUILD ] || continue
            runner="$(_ci_runner_label "${platform}" "[CI-ERROR-PLAN-0002]" "service=\"${service}\" reason=\"no runner label for platform\"")" || return 2
            include="$(_ci_matrix_append "${include}" service="${service}" arch="${platform##*/}" runner="${runner}" platform="${platform}")" || return 2
            any=true
        done <<< "${plats}"
    done
    # What: a release builds nothing; the gate decides.
    # Why: §82: release.yml never builds; ci.yml builds it.
    # From: Issue #1683 | PR #1858
    if [ -n "${CI_RELEASE_TAG:-}" ] && [ "${any}" = true ]; then
        _ci_release_plan_gate "${include}" || return "$?"
        any=false include='[]'
    fi
    # What: emit the AG-VAL-008 rust validation decision.
    # Why: no test runner is booked while validation is off.
    # From: Issue #1683
    local rust_validation=true
    rc=0; _ci_rust_validation_enabled || rc=$?
    case "${rc}" in 0) ;; 1) rust_validation=false ;; *) return 2 ;; esac
    local promote=false validate ptargets t cand
    ptargets="$(_ci_promote_targets_for_ref)" || return 2
    # What: the run record covers every target pair.
    # Why: promote check, validate, promote read all pairs.
    # From: Issue #1683 | PR #1912
    if [ "${any}" = true ] || [ -n "${ptargets}" ]; then
        _ci_for_all_pairs _ci_plan_record || return "$?"
    fi
    # What: a PR run reuses its last green run.
    # Why: §2.1 §29 §30: equal tree and digests, no work.
    # From: Issue #1683 | PR #1858
    local reuse=false
    if [ "${any}" = true ] && [ -z "${ptargets}" ]; then
        rc=0; _ci_pr_green_reuse || rc=$?
        case "${rc}" in
            0) reuse=true any=false include='[]' test_services='' rust_audit=false ;;
            1) ;;
            *) return "${rc}" ;;
        esac
    fi
    # What: promote a ref target not yet on the candidate
    # Why: §50 needs no build; §8: no retag when current
    # From: Issue #1683 | PR #1858
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
                    rc=0; _ci_promote_all_current "${t}" "${cand}" || rc=$?
                    [ "${rc}" -le 1 ] || return "${rc}"
                    [ "${rc}" -eq 0 ] || { promote=true; break; }
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
        printf 'matrix=%s\n' "$(_ci_matrix_doc "${include}")"
        printf 'test-services=%s\n' "${test_services# }"
        printf 'rust-validation=%s\n' "${rust_validation}"
        printf 'rust-audit=%s\n' "${rust_audit}"
        printf 'docs-only=%s\n' "${docs_only}"
        printf 'reuse=%s\n' "${reuse}"
    } >> "${out}"
    _ci_record_emit || return 2
    if [ -n "${unknown}" ]; then
        ci_error "[CI-ERROR-PLAN-0008]" "reason=\"UNKNOWN pairs: no build, escalate (2.3)\"" "${unknown}"
        return 3
    fi
}

# =========================================================
# IDENTITY ENGINE
# =========================================================

# What: Rust item records (TSV); refs: code, {name} only.
# Why: one Rust lexer for norm, build id and lib closure.
# From: Issue #1683 | PR #1912
_CI_AWK_RUST_ITEMS="$(cat <<'PROG'
function flush(   h, kind, name, attach, t, refs, seen, w, n, i, a) {
    t = cur; r = code
    sub(/^ +/, "", t); sub(/ +$/, "", t)
    cur = ""; code = ""; hdr = ""; need_semi = 0
    if (t == "") return
    h = t
    attrs = ""
    while (h ~ /^#!?\[/) {
        n = length(h); d = 0
        for (i = 1; i <= n; i++) {
            c = substr(h, i, 1)
            if (c == "[") d++
            else if (c == "]") { d--; if (d == 0) break }
        }
        attrs = attrs substr(h, 1, i)
        h = substr(h, i + 1); sub(/^ +/, "", h)
    }
    if (tests == "drop" && (attrs ~ /cfg\(test\)/ || attrs ~ /#\[test\]/)) return
    head = h; gsub(/pub\([^)]*\)/, "pub", head)
    sub(/[{;=(].*$/, "", head)
    kind = "header"; name = ""; attach = ""
    if (match(head, /(^| )macro_rules! *[A-Za-z_][A-Za-z0-9_]*/)) {
        kind = "item"; name = substr(head, RSTART, RLENGTH); sub(/.*macro_rules! */, "", name)
    } else if (head ~ /(^| )impl( |<|$)/) {
        kind = "impl"
        a = head; sub(/.*(^| )impl/, "", a)
        attach = idents(a)
    } else if (match(head, /(^| )(fn|struct|enum|union|trait|type|mod|static|const) +(mut +)?[A-Za-z_][A-Za-z0-9_]*/)) {
        name = substr(head, RSTART, RLENGTH)
        sub(/^ /, "", name); n = split(name, w, " "); name = w[n]
        kind = (head ~ /(^| )mod / && t ~ /;$/) ? "header" : "item"
    }
    refs = idents(r)
    gsub(/\\/, "\\\\", t); gsub(/\n/, "\\n", t); gsub(/\t/, "\\t", t)
    printf "%s\t%s\t%s\t%s\t%s\n", kind, name, attach, refs, t
}
function idents(s,   out, seen, tok) {
    out = ""
    while (match(s, /[A-Za-z_][A-Za-z0-9_]*/)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (!(tok in seen)) { seen[tok] = 1; out = out (out == "" ? "" : " ") tok }
    }
    return out
}
function emit(c) {
    code = code " "
    if (c == " ") { if (cur != "" && substr(cur, length(cur), 1) != " ") cur = cur " "; return }
    cur = cur c
}
function captures(s,   out) {
    out = " "; gsub(/\{\{/, "", s)
    while (match(s, /\{[A-Za-z_][A-Za-z0-9_]*/)) {
        out = out substr(s, RSTART + 1, RLENGTH - 1) " "
        s = substr(s, RSTART + RLENGTH)
    }
    return out
}
{ src = src $0 "\n" }
END {
    n = length(src); st = "code"; depth = 0; cur = ""; bdepth = 0
    for (i = 1; i <= n; i++) {
        c = substr(src, i, 1)
        if (st == "line") { if (c == "\n") { st = "code"; emit(" ") } continue }
        if (st == "block") {
            if (c == "/" && substr(src, i + 1, 1) == "*") { bdepth++; i++ }
            else if (c == "*" && substr(src, i + 1, 1) == "/") { bdepth--; i++; if (bdepth == 0) { st = "code"; emit(" ") } }
            continue
        }
        if (st == "str") {
            cur = cur c; lit = lit c
            if (c == "\\") { i++; cur = cur substr(src, i, 1); lit = lit substr(src, i, 1); continue }
            if (c == "\"") { st = "code"; code = code captures(lit) }
            continue
        }
        if (st == "raw") {
            cur = cur c; lit = lit c
            if (c == "\"" && substr(src, i + 1, hashes) == rawend) { cur = cur rawend; i += hashes; st = "code"; code = code captures(lit) }
            continue
        }
        if (c == "/" && substr(src, i + 1, 1) == "/") { st = "line"; i++; continue }
        if (c == "/" && substr(src, i + 1, 1) == "*") { st = "block"; bdepth = 1; i++; continue }
        p = (i > 1) ? substr(src, i - 1, 1) : " "
        if ((c == "r" || (c == "b" && substr(src, i + 1, 1) == "r")) && p !~ /[A-Za-z0-9_]/) {
            j = i + (c == "b" ? 2 : 1); hashes = 0
            while (substr(src, j, 1) == "#") { hashes++; j++ }
            if (substr(src, j, 1) == "\"" && (hashes > 0 || c == "r" || c == "b")) {
                rawend = ""; for (k = 0; k < hashes; k++) rawend = rawend "#"
                cur = cur substr(src, i, j - i + 1); i = j; st = "raw"; lit = ""; continue
            }
        }
        if (c == "\"") { cur = cur c; st = "str"; lit = ""; continue }
        if (c == "\047") {
            if (substr(src, i + 1, 1) == "\\") {
                j = i + 2
                while (j <= n && substr(src, j, 1) != "\047") j++
                cur = cur substr(src, i, j - i + 1); i = j; continue
            }
            if (substr(src, i + 2, 1) == "\047") { cur = cur substr(src, i, 3); i += 2; continue }
            cur = cur c; continue
        }
        if (c ~ /[ \t\r\n]/) { emit(" "); continue }
        cur = cur c; code = code c
        if (c == "(" || c == "[") pdepth++
        else if (c == ")" || c == "]") pdepth--
        if (c == "{") depth++
        else if (c == "}") {
            depth--
            if (depth == 0) {
                h0 = cur; gsub(/#!?\[[^]]*\]/, "", h0); sub(/[{].*$/, "", h0)
                if (h0 ~ /(^| )fn( |$)/ || h0 !~ /(^| )(const|static|let|type|use)( |$)/) flush()
            }
        } else if (c == ";" && depth == 0 && pdepth == 0) flush()
    }
    if ((st != "code" && st != "line") || depth != 0) exit 1
    flush()
}
PROG
)"
readonly _CI_AWK_RUST_ITEMS

# What: library items reached from a service's refs.
# Why: an unreached item cannot change its artifact (64.4).
# From: Issue #1683 | PR #1912
_CI_AWK_RUST_CLOSURE="$(cat <<'PROG'
BEGIN { FS = "\t" }
{ kind[NR] = $1; name[NR] = $2; attach[NR] = $3; refs[NR] = $4; text[NR] = $5; if ($2 != "") defined[$2] = 1; n = NR }
END {
    m = split(roots, r, " "); for (i = 1; i <= m; i++) want[r[i]] = 1
    changed = 1
    while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
            if (sel[i]) continue
            take = (kind[i] == "header") || (kind[i] == "item" && (name[i] in want))
            if (kind[i] == "impl") {
                m = split(attach[i], a, " ")
                for (j = 1; j <= m; j++) if ((a[j] in defined) && (a[j] in want)) take = 1
            }
            if (!take) continue
            sel[i] = 1; changed = 1
            m = split(refs[i], a, " "); for (j = 1; j <= m; j++) want[a[j]] = 1
        }
    }
    for (i = 1; i <= n; i++) if (sel[i]) printf "%s\t%s\t%s\n", kind[i], name[i], text[i]
}
PROG
)"
readonly _CI_AWK_RUST_CLOSURE

# What: Cargo.lock packages reached from root crates.
# Why: a lock entry outside the closure is not built.
# From: Issue #1683 | PR #1912
_CI_AWK_LOCK_CLOSURE="$(cat <<'PROG'
function val(l) { sub(/^[^=]*= *"/, "", l); sub(/" *$/, "", l); return l }
/^\[\[package\]\]/ { p++; indeps = 0; next }
indeps { if ($0 ~ /^\]/) { indeps = 0; next } d = $0; gsub(/[ ",]/, "", d); sub(/\(.*$/, "", d); deps[p] = deps[p] " " d; next }
/^name = / { nm[p] = val($0); next }
/^version = / { vr[p] = val($0); next }
/^source = / { sr[p] = val($0); next }
/^checksum = / { ck[p] = val($0); next }
/^dependencies = \[/ { indeps = 1; next }
END {
    for (i = 1; i <= p; i++) { byname[nm[i]] = byname[nm[i]] " " i; key[nm[i] vr[i]] = i }
    m = split(roots, r, " ")
    for (i = 1; i <= m; i++) { k = split(byname[r[i]], a, " "); for (j = 1; j <= k; j++) q[++qn] = a[j] }
    for (h = 1; h <= qn; h++) {
        i = q[h]; if (i in sel) continue; sel[i] = 1
        k = split(deps[i], a, " ")
        for (j = 1; j <= k; j++) {
            d = a[j]
            if (d in byname && split(byname[d], b, " ") == 1) { q[++qn] = b[1]; continue }
            for (x = 1; x <= p; x++) if (nm[x] vr[x] == d || nm[x] == d) q[++qn] = x
        }
    }
    for (i = 1; i <= p; i++) if (i in sel) printf "%s %s %s %s\n", nm[i], vr[i], sr[i], ck[i]
}
PROG
)"
readonly _CI_AWK_LOCK_CLOSURE

# What: awk verdict: rc 0 print, rc 1 raw, else coded stop.
# Why: one owner for the reader and the normalizer verdict.
# From: Issue #1683 | PR #1912
_ci_awk_verdict() {
    local id="$1" ctx="$2" rc="$3" out="$4"
    case "${rc}" in
        0) printf '%s\n' "${out}" ;;
        1) return 1 ;;
        *)
            ci_error "${id}" "${ctx}" "${out}"
            return 2
            ;;
    esac
}

# What: item records of Rust text $1; $2 keep|drop tests.
# Why: rc 1 = unterminated text; the caller keeps raw.
# From: Issue #1683 | PR #1912
_ci_rust_items() {
    local out rc=0
    out="$(awk -v tests="$2" "${_CI_AWK_RUST_ITEMS}" <<< "$1" 2>&1)" || rc=$?
    _ci_awk_verdict "[CI-ERROR-IDENTITY-0010]" "rc=${rc} reason=\"rust item reader failed\"" "${rc}" "${out}"
}

# What: normalized Rust text: kind, name, text per item.
# Why: refs and attach lists derive from the text.
# From: Issue #1683 | PR #1912
_ci_rust_norm() {
    local items
    items="$(_ci_rust_items "$1" "$2")" || return "$?"
    _ci_capture 0 cut -f1,2,5 <<< "${items}"
}

# What: the v1 normalizer grammar of a path; rc 1 = raw.
# Why: A§12.5 v1 drops comment and blank lines (Test B/C).
# From: Issue #1683 | PR #1858
_ci_norm_grammar() {
    case "${1##*/}" in
        *.rs) printf 'rust\n' ;;
        *.sh|*.bash|*.bats) printf 'shell\n' ;;
        Dockerfile|Dockerfile.*|*.Dockerfile) printf 'dockerfile\n' ;;
        *.toml) printf 'toml\n' ;;
        *) return 1 ;;
    esac
}

# What: v1 form of $2 in grammar $1; rc 1 = unsafe, use raw.
# Why: string and heredoc lines stay; any doubt keeps raw.
# From: Issue #1683 | PR #1858
_ci_norm_content() {
    local out rc=0
    if [ "$1" = rust ]; then
        _ci_rust_norm "$2" keep
        return "$?"
    fi
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
        g == "toml" {
            if ($0 ~ /"""|\047\047\047/) exit 1
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            print
            next
        }
        { exit 3 }
        END { if (q != "" || hd != "") exit 1 }
    ' <<< "$2" 2>&1)" || rc=$?
    _ci_awk_verdict "[CI-ERROR-IDENTITY-0008]" "grammar=\"$1\" rc=${rc} reason=\"v1 normalizer failed\"" "${rc}" "${out}"
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

# What: path TAB blob id of tracked files under a root.
# Why: one listing for content ids and the Rust reader.
# From: Issue #1683
_ci_tracked_listing() {
    local root="$1" ref="${2:-}" raw listing empty
    # What: git pathspec selects files in both modes alike.
    # Why: ls-tree ignores globs; diff-tree honours them.
    # From: Issue #1683
    if [ -n "${ref}" ]; then
        empty="$(cd -- "${CI_REPO_ROOT}" && _ci_empty_tree)" || return 2
        raw="$(_ci_identity_git "${root}" "${ref}" diff-tree -r --raw "${empty}" "${ref}" -- "${root}")" || return 2
        listing="$(_ci_capture 0 awk -F'\t' "NF { split(\$1, a, \" \"); print \$2 \"\\t\" a[4] }" <<< "${raw}")" || return 2
    else
        raw="$(_ci_identity_git "${root}" "" ls-files -s -- "${root}")" || return 2
        listing="$(_ci_capture 0 awk -F'\t' "NF { split(\$1, a, \" \"); print \$2 \"\\t\" a[2] }" <<< "${raw}")" || return 2
    fi
    LC_ALL=C _ci_capture 0 sort <<< "${listing}"
}

# What: Emit path-keyed content ids of tracked files.
# Why: Content, not raw bytes or order, is the input.
# From: Issue #1683
_ci_tracked_content_ids() {
    local root="$1" ref="${2:-}" mode="${3:-}" listing line
    listing="$(_ci_tracked_listing "${root}" "${ref}")" || return 2
    [ -n "${listing}" ] || return 0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        _ci_content_id_row "${line}" "${ref}" "${mode}" || return 2
    done <<< "${listing}"
}

# What: path TAB normalized id of one listing row.
# Why: one normalizer for plain paths and Rust libraries.
# From: Issue #1683 | PR #1858
_ci_content_id_row() {
    local line="$1" ref="$2" mode="$3" path oid blob norm g nrc=0
    path="${line%%$'\t'*}"
    oid="${line#*$'\t'}"
    if g="$(_ci_norm_grammar "${path}")"; then
        blob="$(_ci_identity_git "${path}" "${ref}" cat-file blob "${oid}")" || return 2
        # What: a build id drops Rust cfg(test) items.
        # Why: 11.4: a test change builds no container.
        # From: Issue #1683 | PR #1912
        if [ "${g}" = rust ] && [ "${mode}" = build ]; then
            norm="$(_ci_rust_norm "${blob}" drop)" || nrc=$?
        else
            norm="$(_ci_norm_content "${g}" "${blob}")" || nrc=$?
        fi
        case "${nrc}" in
            0)
                norm="$(_ci_sha256_hex <<< "${norm}")" || return 2
                printf '%s\t%s\n' "${path}" "${norm}"
                return 0
                ;;
            1) ;;
            *) return 2 ;;
        esac
    fi
    printf '%s\t%s\n' "${path}" "${oid}"
}

# What: one blob of a listing row at a ref.
# Why: the Rust reader reads files the listing named.
# From: Issue #1683 | PR #1912
_ci_listing_blob() {
    local line="$1" ref="$2"
    _ci_identity_git "${line%%$'\t'*}" "${ref}" cat-file blob "${line#*$'\t'}"
}

# What: generate the workspace lock, once per job.
# Why: no third-party pin; cargo resolves the latest.
# From: Issue #1683 | PR #1858
_ci_cargo_lock() {
    local lock seen out
    lock="$(_ci_repo_path CI_CARGO_LOCK)" || return 2
    if seen="$(_ci_job_memo_get cargo-lock.done)" && [ "${seen}" = "${lock}" ] && [ -s "${lock}" ]; then
        return 0
    fi
    if ! out="$(cd "${CI_REPO_ROOT:-.}" && _ci_retry cargo cargo generate-lockfile)"; then
        ci_error "[CI-ERROR-RESOLVE-0013]" "path=\"${lock}\" reason=\"workspace lock not generated\"" "${out}"
        return 2
    fi
    [ -z "${out}" ] || printf '%s\n' "${out}" >&2
    _ci_job_memo_put cargo-lock.done "${lock}"
}

# What: Rust id lines; $3 text: the reached item texts.
# Why: 64.4: only what the service reaches is input.
# From: Issue #1683 | PR #1912
_ci_rust_content() {
    local service="$1" ref="${2:-}" mode="${3:-id}" crates rows lock dir bin crate src listing line blob items
    local roots="" pkgs lib sel h refs lockf
    crates="$(_ci_required_field "${service}" crates list)" || return 2
    crates=" ${crates//$'\n'/ } "
    lock="$(_ci_variable CI_CARGO_LOCK)" || return 2
    rows="$(_ci_workspace_rows "${CI_REPO_ROOT:-.}")" || return 2
    while IFS='|' read -r dir bin crate; do
        [ -n "${bin}" ] || continue
        [[ "${crates}" == *" ${crate} "* ]] || continue
        src="$(_ci_workspace_src_dir "${dir}" "${bin}")"
        listing="$(_ci_tracked_listing "${src}" "${ref}")" || return 2
        while IFS= read -r line; do
            [[ "${line%%$'\t'*}" == *.rs ]] || continue
            blob="$(_ci_listing_blob "${line}" "${ref}")" || return 2
            items="$(_ci_rust_items "${blob}" drop)" || return 2
            refs="$(_ci_capture 0 cut -f4 <<< "${items}")" || return 2
            roots+=" ${refs//$'\n'/ }"
            [ "${mode}" != text ] || printf '%s\n' "${items}"
        done <<< "${listing}"
    done <<< "${rows}"
    # What: every ref reads this job's generated lock.
    # Why: a resolved input, like a base image digest.
    # From: Issue #1683 | PR #1858
    _ci_cargo_lock || return 2
    lockf="$(_ci_repo_path CI_CARGO_LOCK)" || return 2
    pkgs="$(_ci_run "[CI-ERROR-IDENTITY-0011]" "path=\"${lock}\" reason=\"lock closure not read\"" awk -v roots="${crates}" "${_CI_AWK_LOCK_CLOSURE}" "${lockf}")" || return 2
    if [ "${mode}" != text ]; then
        h="$(_ci_sha256_hex <<< "${pkgs}")" || return 2
        printf '%s\t%s\n' "${lock}" "${h}"
    fi
    while IFS='|' read -r dir bin crate; do
        [ -z "${bin}" ] || continue
        [[ $'\n'"${pkgs}" == *$'\n'"${crate} "* ]] || continue
        listing="$(_ci_tracked_listing "${dir}" "${ref}")" || return 2
        lib=""
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            if [[ "${line%%$'\t'*}" != *.rs ]]; then
                # What: library manifests read normalized.
                # Why: a comment line builds no container.
                # From: Issue #1683 | PR #1858
                [ "${mode}" = text ] || _ci_content_id_row "${line}" "${ref}" "" || return 2
                continue
            fi
            blob="$(_ci_listing_blob "${line}" "${ref}")" || return 2
            items="$(_ci_rust_items "${blob}" drop)" || return 2
            lib+="${items}"$'\n'
        done <<< "${listing}"
        sel="$(_ci_run "[CI-ERROR-IDENTITY-0012]" "dir=\"${dir}\" reason=\"library closure not read\"" awk -v roots="${roots}" "${_CI_AWK_RUST_CLOSURE}" <<< "${lib}")" || return 2
        if [ "${mode}" = text ]; then
            printf '%s\n' "${sel}"
            continue
        fi
        h="$(_ci_sha256_hex <<< "${sel}")" || return 2
        printf '%s\t%s\n' "${dir}" "${h}"
    done <<< "${rows}"
}

# What: print the image_base list of a field, then $2.
# Why: every image extends one base; no per-image copies.
# From: Issue #1683 | PR #1858
_ci_image_base_plus() {
    local field="$1" own="$2" base
    base="$(_ci_block_entry_list image_base "" "${field}")" || return 2
    printf '%s\n%s\n' "${base}" "${own}" | awk 'NF && !seen[$0]++'
}

# What: bootstrap, base, own and build-type apk lists.
# Why: image and identity must see one and the same list.
# From: Issue #1683 | PR #1858
_ci_service_packages() {
    local service="$1" own build_type runtime boot
    boot="$(_ci_required_field image_base bootstrap blocklist)" || return 2
    own="$(_ci_target_list "${service}" packages)" || return 2
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    runtime="$(_ci_block_entry_list build_runtime "${build_type}" packages)" || return 2
    _ci_image_base_plus packages "${boot}"$'\n'"${own}"$'\n'"${runtime}"
}

# What: base, own and build-type smoke checks of a service.
# Why: one rule per build type; @CRATE@ = each image crate.
# From: Issue #1683 | PR #1858
_ci_service_smoke() {
    local service="$1" own build_type runtime crates crate each=""
    own="$(_ci_block_entry_list services "${service}" smoke)" || return 2
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    runtime="$(_ci_block_entry_list build_runtime "${build_type}" smoke)" || return 2
    if [[ "${runtime}" == *@CRATE@* ]]; then
        crates="$(_ci_required_field "${service}" crates list)" || return 2
        while IFS= read -r crate; do
            _ci_fill "${runtime}" "CRATE=${crate}" || return 2
            each="${each}${REPLY}"$'\n'
        done <<< "${crates}"
        runtime="${each}"
    fi
    _ci_image_base_plus smoke "${own}"$'\n'"${runtime}"
}

# What: SOT build_identity inputs of a type; $4 = prefix.
# Why: the id and the provenance toolchain read one list.
# From: Issue #1683 | PR #1858
_ci_identity_pins() {
    local service="$1" build_type="$2" platform="$3" only="${4:-}" inputs input entry
    inputs="$(_ci_block_entry_list build_identity "${build_type}" inputs)" || return 2
    if [ -z "${inputs}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0004]" "build_type=\"${build_type}\" reason=\"no SOT build_identity inputs; FAIL CLOSED\""
        return 2
    fi
    for input in ${inputs}; do
        [[ "${input}" == "${only}"* ]] || continue
        printf 'input=%s\n' "${input}"
        case "${input}" in
            source_sha) : ;;
            build_variables) _ci_build_variable_args "${build_type}" || return 2 ;;
            toolchain_source_sha) _ci_build_tools_signature || return 2 ;;
            toolchain_packages)
                # What: build-tools package versions used.
                # Why: a python3 update rebuilds no service.
                # From: Issue #1683 | PR #1858
                entry="$(_ci_toolchain_entry "${build_type}" "${platform}")" || return 2
                entry="${entry#*$'\t'}"
                tr ' ' '\n' <<< "${entry#* }"
                ;;
            base_digest)
                if [ "${build_type}" = toolchain ]; then
                    _ci_build_tools_build_args --bare || return 2
                else
                    _ci_service_build_args "${service}" --bare "${platform}" no || return 2
                fi
                ;;
            package_refresh)
                # What: last §17 apk refresh value.
                # Why: a newer index package is a new id.
                # From: Issue #1683 | PR #1858
                _ci_package_refresh_value "${service}" "${platform}" || return 2
                ;;
            *)
                ci_log "[CI-ERROR-IDENTITY-0006]" "input=\"${input}\" reason=\"unknown build_identity input; FAIL CLOSED\""
                return 2
                ;;
        esac
    done
}

# What: a target's SOT paths without the Rust-owned ones.
# Why: the id and the default-key scan read one path set.
# From: Issue #1683 | PR #1912
_ci_target_plain_paths() {
    local service="$1" paths p type skip=" "
    paths="$(_ci_target_paths "${service}")" || return 2
    type="$(_ci_required_field "${service}" build_type)" || return 2
    # What: lock, libs, foreign manifests come from Rust.
    # Why: only the reached part of each is an input.
    # From: Issue #1683 | PR #1912
    if [ "${type}" = rust ]; then
        skip="$(_ci_rust_skip_paths "${service}")" || return 2
    fi
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        [[ "${skip}" != *" ${p} "* ]] || continue
        printf '%s\n' "${p}"
    done <<< "${paths}"
}

# What: normalized content ids of a target's SOT paths.
# Why: one reader for build id, impact and test identity.
# From: Issue #1683 | PR #1912
_ci_identity_content() {
    local service="$1" ref="${2:-}" mode="${3-build}" paths p part buf="" type ctx
    paths="$(_ci_target_plain_paths "${service}")" || return 2
    type="$(_ci_required_field "${service}" build_type)" || return 2
    ctx="$(_ci_required_field "${service}" context)" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        part="$(_ci_tracked_content_ids "${p}" "${ref}" "${mode}")" || return 2
        if [ "${p}" = "${ctx}" ] && [ -n "${part}" ]; then
            part="$(_ci_context_build_rows "${service}" "${ref}" "${part}")" || return 2
        fi
        [ -z "${part}" ] || buf+="${part}"$'\n'
    done <<< "${paths}"
    if [ "${type}" = rust ]; then
        part="$(_ci_rust_content "${service}" "${ref}")" || return 2
        buf+="${part}"$'\n'
    fi
    printf '%s' "${buf}"
}

# What: context rows the Dockerfile copies, and itself.
# Why: an uncopied runtime file is no build input.
# From: Issue #1683 | PR #1858
_ci_context_build_rows() {
    local service="$1" ref="$2" rows="$3" df text srcs src line path keep
    df="$(_ci_service_path "${service}" Dockerfile "")" || return 2
    text="$(_ci_identity_git "${df}" "${ref}" show "${ref}:${df}")" || return 2
    srcs="$(_ci_dockerfile_copy_sources "${text}")" || return 2
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        path="${line%%$'\t'*}"
        keep=""
        [ "${path}" != "${df}" ] || keep=1
        while IFS= read -r src; do
            [ -z "${keep}" ] || break
            src="${src%/}"
            [ -n "${src}" ] || continue
            case "${path}" in "${src}" | "${src}"/*) keep=1 ;; esac
        done <<< "${srcs}"
        [ -z "${keep}" ] || printf '%s\n' "${line}"
    done <<< "${rows}"
}

# What: COPY sources of a Dockerfile text, one per line.
# Why: the identity and the Dockerfile check share it.
# From: Issue #1683 | PR #1858
_ci_dockerfile_copy_sources() {
    _ci_capture 0 awk "$(cat <<'PROG'
        /\\$/ { buf = buf substr($0, 1, length($0) - 1) " "; next }
        { line = buf $0; buf = "" }
        toupper(line) !~ /^[[:space:]]*COPY[[:space:]]/ || line ~ /--from=/ { next }
        { k = 0; nw = split(line, w, /[[:space:]]+/)
          for (i = 2; i <= nw; i++) if (w[i] != "" && w[i] !~ /^--/) a[++k] = w[i]
          for (i = 1; i < k; i++) print a[i] }
PROG
        )" <<< "$1"
}

# What: context paths the Rust reader owns, space-framed.
# Why: lock, library dirs, other crates' manifests.
# From: Issue #1683 | PR #1912
_ci_rust_skip_paths() {
    local crates rows manifest dir bin crate lock out
    crates="$(_ci_required_field "$1" crates list)" || return 2
    crates=" ${crates//$'\n'/ } "
    manifest="$(_ci_variable CI_CARGO_MANIFEST)" || return 2
    lock="$(_ci_variable CI_CARGO_LOCK)" || return 2
    out=" ${lock} "
    rows="$(_ci_workspace_rows "${CI_REPO_ROOT:-.}")" || return 2
    while IFS='|' read -r dir bin crate; do
        if [ -z "${bin}" ]; then
            out+="${dir} "
        elif [[ "${crates}" != *" ${crate} "* ]]; then
            out+="${dir}/${manifest} "
        fi
    done <<< "${rows}"
    printf '%s' "${out}"
}

# What: build_type and SOT pins of one target+platform.
# Why: the SOT half of the id; compared alone at base.
# From: Issue #1683 | PR #1912
_ci_identity_sot() {
    local service="$1" platform="$2" build_type pins
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    pins="$(_ci_identity_pins "${service}" "${build_type}" "${platform}")" || return "$?"
    printf 'build_type=%s\n%s\n' "${build_type}" "${pins}"
}

# What: pair id from a run record; rc 1 absent, 2 bad.
# Why: one parser for the plan output and the plan itself.
# From: Issue #1683 | PR #1912
_ci_identity_recorded() {
    local rec=" $1 " key="$2@$3=" id
    [[ "${rec}" == *" ${key}"* ]] || return 1
    id="${rec#*" ${key}"}"
    id="${id%% *}"
    if [[ ! "${id}" =~ ^[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-IDENTITY-0014]" "pair=\"$2@$3\" got=\"${id}\" reason=\"run record holds no 64-hex id\""
        return 2
    fi
    printf '%s\n' "${id}"
}

# What: pair id read only from the planner's run record.
# Why: no consumer can mint a second id in one run (§17).
# From: Issue #1683 | PR #1912
_ci_identity_for() {
    local service="$1" platform="$2" rec rc=0
    if [ -n "${CI_RUN_IDENTITIES+x}" ]; then
        rec="${CI_RUN_IDENTITIES}"
    elif [ -n "${_ci_plan_ids+x}" ]; then
        rec="${_ci_plan_ids}"
    else
        ci_log "[CI-ERROR-IDENTITY-0017]" "service=\"${service}\" platform=\"${platform}\" reason=\"no run record; only plan-matrix or identity --run-record fixes ids; FAIL CLOSED\""
        return 2
    fi
    _ci_identity_recorded "${rec}" "${service}" "${platform}" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        1)
            ci_log "[CI-ERROR-IDENTITY-0015]" "service=\"${service}\" platform=\"${platform}\" reason=\"pair not in the run record; FAIL CLOSED\""
            return 2
            ;;
        *) return 2 ;;
    esac
}

# What: compute a pair id from SOT and tracked inputs.
# Why: only a planner scope may; a given record forbids it.
# From: Issue #1683 | PR #1912
_ci_identity_compute() {
    local service="$1" platform="$2" ref="${3:-}" build_type pins content buf
    if [ -n "${CI_RUN_IDENTITIES+x}" ] || [ -z "${_ci_plan_ids+x}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0018]" "service=\"${service}\" platform=\"${platform}\" reason=\"live id outside a planner scope or beside a given run record; FAIL CLOSED\""
        return 2
    fi
    build_type="$(_ci_required_field "${service}" build_type)" || return 2
    # What: every id input is captured and checked first.
    # Why: a failed part in a hash pipe mints a wrong id.
    # From: Issue #1683 | PR #1858
    pins="$(_ci_identity_pins "${service}" "${build_type}" "${platform}")" || return "$?"
    content="$(_ci_identity_content "${service}" "${ref}")" || return 2
    buf="$(printf 'service=%s\nbuild_type=%s\nplatform=%s' "${service}" "${build_type}" "${platform}")"$'\n'
    [ -z "${content}" ] || buf+="${content}"$'\n'
    buf+="${pins}"$'\n'
    printf '%s' "${buf}" | _ci_sha256_hex
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
    # What: record the pair first unless a record is given.
    # Why: the CLI reads its own record, never a second id.
    # From: Issue #1683 | PR #1912
    [ -n "${CI_RUN_IDENTITIES+x}" ] || _ci_plan_record "$1" "$2" || return "$?"
    id="$(_ci_identity_for "$1" "$2")" || return "$?"
    printf 'platform=%s identity=%s\n' "$2" "${id}"
}

# What: add a pair's id to the run record once.
# Why: one writer; a pair keeps its first id per run.
# From: Issue #1683 | PR #1912
_ci_plan_record() {
    local id rc=0
    id="$(_ci_identity_recorded "${_ci_plan_ids}" "$1" "$2")" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        1) ;;
        *) return 2 ;;
    esac
    id="$(_ci_identity_compute "$1" "$2")" || return "$?"
    _ci_plan_ids+=" $1@$2=${id}"
}

# What: write the run record to the log and step output.
# Why: plan and --run-record emit one format, one writer.
# From: Issue #1683 | PR #1912
_ci_record_emit() {
    _ci_step_output "[CI-ERROR-IDENTITY-0016]" identities "${_ci_plan_ids# }" || return 2
    printf 'identities=%s\n' "${_ci_plan_ids# }"
}

# What: run one_fn service platform for every target pair.
# Why: one pair enumerator for the run record and scans.
# From: Issue #1683 | PR #1912
_ci_for_all_pairs() {
    local one_fn="$1" targets service
    targets="$(ci_build_targets)" || return 2
    for service in ${targets}; do
        _ci_for_platforms "${service}" "" "[CI-ERROR-PAIRS-0001]" "${one_fn}" || return "$?"
    done
}

# What: a target's ids per platform, or the run record.
# Why: the call is a planner scope; its record is local.
# From: Issue #1683 | PR #1912
ci_cmd_identity() {
    local service="${1:-}" platform="${2:-}" _ci_plan_ids=""
    [ -n "${service}" ] || { ci_log "[CI-ERROR-IDENTITY-0001]" "reason=\"service arg required\""; return 2; }
    if [ "${service}" = --run-record ]; then
        _ci_for_all_pairs _ci_plan_record || return "$?"
        _ci_record_emit
        return "$?"
    fi
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

# What: classify one pair base vs head and count it.
# Why: writes the caller's counters (dynamic scope).
# From: Issue #1683 | PR #1912
_ci_impact_pair() {
    local t="$1" p="$2" hid v
    if [ "${base_missing}" -eq 1 ]; then
        # What: no base SOT -> UNKNOWN, escalate.
        # Why: no base truth -> no BUILD.
        # From: Issue #1683
        printf 'target=%s platform=%s impact=UNKNOWN\n' "${t}" "${p}"
        unknown=$((unknown+1))
        return 0
    fi
    hid="$(_ci_identity_compute "${t}" "${p}" "${head}")" || hid=""
    v="$(_ci_impact_classify "${t}" "${p}" "${hid}" "${base}" "${base_manifest}" "${head}")" || return 2
    printf 'target=%s platform=%s impact=%s\n' "${t}" "${p}" "${v}"
    case "${v}" in
        NOOP) noop=$((noop+1)) ;;
        BUILD) build=$((build+1)) ;;
        *) unknown=$((unknown+1)) ;;
    esac
}

# What: Emit NOOP or BUILD per target and platform.
# Why: Equal identity base-vs-head is the no-build rule.
# From: Issue #1683
_ci_impact_run() {
    local base="$1" head="$2" base_manifest="$3"
    local base_missing=0 build=0 noop=0 unknown=0
    if ! _ci_manifest_at "${base}" "${base_manifest}" || [ ! -s "${base_manifest}" ]; then
        base_missing=1
        ci_log "[CI-INFO-IMPACT-0002]" "base=\"${base}\" reason=\"no SOT at base; UNKNOWN, escalate, BUILD DISACK\""
    fi
    _ci_for_all_pairs _ci_impact_pair || return "$?"
    printf 'impact result=classified build=%s noop=%s unknown=%s base=%s\n' "${build}" "${noop}" "${unknown}" "${base}"
    # What: base-missing escalates; UNKNOWN never builds.
    # Why: base-SOT-unavailable stays DISACK, escalates.
    # From: Issue #1683
    if [ "${base_missing}" -eq 1 ] || [ "${unknown}" -gt 0 ]; then return 3; fi
    return 0
}

# What: BUILD only on a proven input change.
# Why: 2.2 BUILD needs proof; 2.3 UNKNOWN != BUILD.
# From: Issue #1683 | PR #1912
_ci_impact_classify() {
    local t="$1" p="$2" hid="$3" base="$4" base_manifest="$5" head="${6:-}" hc bc hs bs bt hi bi
    if [ -z "${hid}" ]; then
        ci_log "[CI-INFO-IMPACT-0009]" "service=\"${t}\" platform=\"${p}\" reason=\"head identity not computed (error above); UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
    # What: head SOT paths, read in the head and base tree.
    # Why: a changed normalized input file proves impact.
    # From: Issue #1683 | PR #1912
    if ! hc="$(_ci_identity_content "${t}" "${head}")" || ! bc="$(_ci_identity_content "${t}" "${base}")"; then
        ci_log "[CI-INFO-IMPACT-0014]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" reason=\"input content unreadable (error above); UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
    if [ "${hc}" != "${bc}" ]; then
        ci_log "[CI-INFO-IMPACT-0015]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" reason=\"normalized build input differs from base; BUILD\""
        printf 'BUILD\n'; return 0
    fi
    # What: a changed identity recipe is proven impact.
    # Why: base pins would name inputs this code dropped.
    # From: Issue #1683 | PR #1858
    if ! bt="$(_ci_required_field "${t}" build_type)" \
        || ! hi="$(_ci_block_entry_list build_identity "${bt}" inputs)" \
        || ! bi="$(CI_MANIFEST="${base_manifest}" _ci_block_entry_list build_identity "${bt}" inputs)"; then
        ci_log "[CI-INFO-IMPACT-0018]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" reason=\"identity inputs unreadable (error above); UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
    if [ "${hi}" != "${bi}" ]; then
        ci_log "[CI-INFO-IMPACT-0017]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" reason=\"identity inputs changed from ${bi//$'\n'/ } to ${hi//$'\n'/ }; BUILD\""
        printf 'BUILD\n'; return 0
    fi
    # What: same inputs: only an SOT pin change is impact.
    # Why: an unreadable base SOT proves nothing; UNKNOWN.
    # From: Issue #1683 | PR #1912
    if ! hs="$(_ci_identity_sot "${t}" "${p}")" || ! bs="$(CI_MANIFEST="${base_manifest}" _ci_identity_sot "${t}" "${p}")"; then
        ci_log "[CI-INFO-IMPACT-0010]" "service=\"${t}\" platform=\"${p}\" base=\"${base}\" reason=\"SOT pins unreadable (error above); UNKNOWN\""
        printf 'UNKNOWN\n'; return 0
    fi
    [ "${hs}" = "${bs}" ] && { printf 'NOOP\n'; return 0; }
    printf 'BUILD\n'
}

# What: Compare base vs head; clean up the temp SOT.
# Why: base is required; fail-closed if base has no SOT.
# From: Issue #1683
ci_cmd_impact() {
    local base="${1:-}" head="${2:-HEAD}" base_manifest rc=0
    # What: this command is a planner scope.
    # Why: head ids at a ref are computed live, never read.
    # From: Issue #1683 | PR #1912
    local _ci_plan_ids=""
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
        # What: MISSING while another run builds is a wait.
        # Why: BUILD_IN_PROGRESS never builds a second time.
        # From: Issue #1683 | PR #1912
        if [ "${grc}" -eq 1 ]; then
            local brc=0
            _ci_build_lock_busy "${identity}" "${service}" "${platform}" || brc=$?
            case "${brc}" in
                0) printf 'BUILD_IN_PROGRESS\n' ;;
                1) printf 'MISSING_CONFIRMED\n' ;;
                *) printf 'UNKNOWN\n' ;;
            esac
            return 0
        fi
        printf 'PRODUCED_UNVERIFIED\n'
        return 0
    fi
    lstate="${lrec%%$'\t'*}"
    ldig="${lrec#*$'\t'}"
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

# What: Map a resolver state to its action; log the reason.
# Why: §79: each pair decision names state, action, reason.
# From: Issue #1683 | PR #1858
_ci_resolve_action() {
    local state="$1" service="$2" platform="$3" action reason
    case "${state}" in
        PRESENT_ACCEPTED) action=noop reason="accepted exact result exists; reuse" ;;
        MISSING_CONFIRMED) action=build reason="no artifact for this identity; impact decides" ;;
        MISMATCH) action=fail reason="ledger and registry digest disagree" ;;
        PRODUCED_UNVERIFIED) action=verify reason="artifact exists, not accepted; verify, no build" ;;
        BUILD_IN_PROGRESS) action=wait reason="another run holds the build lock; no second build" ;;
        *) action=escalate reason="UNKNOWN is never treated as build-needed" ;;
    esac
    ci_log "[CI-INFO-RESOLVE-0005]" "service=\"${service}\" platform=\"${platform}\" state=${state} action=${action} reason=\"${reason}\""
    printf '%s\n' "${action}"
}

# What: one key=value field of a record; absent key fails
# Why: a missing key is UNKNOWN, never a guessed value
# From: Issue #1683 | PR #1858
_ci_record_field() {
    local rec=" $1" key="$2"
    case "${rec}" in
        *" ${key}="*) ;;
        *)
            ci_log "[CI-ERROR-CORE-0143]" "key=\"${key}\" record=\"$1\" reason=\"record has no such field\""
            return 2
            ;;
    esac
    rec="${rec#*" ${key}="}"
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
    action="$(_ci_resolve_action "${state}" "${service}" "${platform}")"
    printf 'service=%s platform=%s state=%s action=%s identity=%s\n' "${service}" "${platform}" "${state}" "${action}" "${identity}"
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
    # What: op=cargo: only a network failure is transient.
    # Why: a missing crate or bad manifest fails again.
    # From: Issue #1683 | PR #1858
    if [ "${op}" = cargo ]; then
        if _ci_failure_is_network "${low}"; then printf 'transient\n'; else printf 'permanent\n'; fi
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
    # What: auth, malformed, compile, no ref: permanent.
    # Why: retrying a fixed outcome wastes budget.
    # From: Issue #1683 | PR #1858
    case "${low}" in
        *"http 401"*|*"unauthorized"*|*"denied: requested access"*) printf 'permanent\n'; return 0 ;;
        *"http 400"*|*"http 422"*|*"invalid reference format"*) printf 'permanent\n'; return 0 ;;
        *"pull access denied"*) printf 'permanent\n'; return 0 ;;
        *"error: could not compile"*|*"dockerfile parse error"*|*"failed to solve"*"parse"*|*"lint violation found"*) printf 'permanent\n'; return 0 ;;
        *"couldn't find remote ref"*|*"not our ref"*|*"fatal: repository"*"not found"*) printf 'permanent\n'; return 0 ;;
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
    # From: Issue #1683 | PR #1858
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
        # What: apk-tools fetch errors that may heal.
        # Why: a bootstrap apk RUN retries via buildx too.
        # From: Issue #1683 | PR #1912
        *"temporary error (try again later)"*|*"network error (check internet"*|*"dns lookup error"*) return 0 ;;
        *"gnutls recv error"*|*"tls connection"*"closed"*) return 0 ;;
    esac
    return 1
}

# =========================================================
# GIT-REF CAS (coordination lock; §20/§52)
# =========================================================

# What: object id of the empty tree in the cwd repo.
# Why: computed, so sha1 and sha256 repos both match.
# From: Issue #1683 | PR #1858
_ci_empty_tree() {
    printf '' | _ci_capture 0 git hash-object -t tree --stdin
}

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
# Why: AG-CI-006: name and e-mail live in SOT git_bot.
# From: Issue #1683 | PR #1858
_ci_git_as_bot() {
    local name email
    name="$(_ci_required_field git_bot name block)" || return 2
    email="$(_ci_required_field git_bot email block)" || return 2
    GIT_AUTHOR_NAME="${name}" GIT_AUTHOR_EMAIL="${email}" \
    GIT_COMMITTER_NAME="${name}" GIT_COMMITTER_EMAIL="${email}" \
        git "$@"
}

# What: Build an empty-tree commit carrying a note.
# Why: A lock head carries a note, not a real tree.
# From: Issue #1683 | PR #1858
_ci_cas_note_commit() {
    local tree
    tree="$(_ci_empty_tree)" || return 2
    _ci_bot_commit "${tree}" "" "$1"
}

# What: bot commit of a tree, optional parent, message.
# Why: one commit-tree owner for notes and the ledger.
# From: Issue #1683 | PR #1912
_ci_bot_commit() {
    local tree="$1" parent="$2" msg="$3"
    local -a pa=()
    [ -n "${parent}" ] && pa=(-p "${parent}")
    _ci_capture 0 _ci_git_as_bot commit-tree "${tree}" "${pa[@]}" -m "${msg}"
}

# What: rc 0 holder run ended, 1 still runs, 2 unknown.
# Why: a lock frees when its holder ends; no age guess.
# From: Issue #1683 | PR #1912
_ci_lock_holder_ended() {
    local note="$1" run attempt out rc=0
    [[ "${note}" =~ run=([0-9]+)\ attempt=([0-9]+) ]] || return 2
    run="${BASH_REMATCH[1]}"; attempt="${BASH_REMATCH[2]}"
    [ -n "${GITHUB_REPOSITORY:-}" ] || return 2
    out="$(_ci_retry github-read gh api --jq '"\(.status) \(.run_attempt)"' \
        "repos/${GITHUB_REPOSITORY}/actions/runs/${run}")" || rc=$?
    # What: a deleted run (HTTP 404) has ended.
    # Why: a run that no longer exists holds nothing.
    # From: Issue #1683 | PR #1858
    [ "${rc}" -ne 1 ] || return 0
    [ "${rc}" -eq 0 ] || return 2
    [[ "${out}" =~ ^([a-z_]+)\ ([0-9]+)$ ]] || return 2
    [ "${BASH_REMATCH[1]}" = completed ] && return 0
    [ "${BASH_REMATCH[2]}" -gt "${attempt}" ] && return 0
    return 1
}

# What: fetch a ref in full; print its head subject.
# Why: lock holders and verified marks live in the subject.
# From: Issue #1683 | PR #1912
_ci_ref_subject() {
    local remote="$1" ref="$2" retry="${3:-0}"
    # What: full fetch of a one-commit ref; retry on ask.
    # Why: shallow breaks the next push; loops retry above.
    # From: Issue #1683 | PR #1912
    if [ "${retry}" = 1 ]; then
        _ci_retry git git fetch "${remote}" "${ref}" >&2 || return 2
    else
        _ci_git_run fetch "${remote}" "${ref}" >&2 || return 2
    fi
    _ci_capture 0 git log -1 --format=%s FETCH_HEAD
}

# What: ref head as sha, tab, subject; 1 absent, 2 unknown.
# Why: one owner for the sha query plus subject fetch.
# From: Issue #1683 | PR #1912
_ci_ref_head() {
    local remote="$1" ref="$2" retry="${3:-0}" sha subject rc=0
    sha="$(_ci_cas_ref_sha "${remote}" "${ref}")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    subject="$(_ci_ref_subject "${remote}" "${ref}" "${retry}")" || return 2
    printf '%s\t%s\n' "${sha}" "${subject}"
}

# What: One non-blocking lock acquisition attempt.
# Why: create, or take over the lock of an ended holder.
# From: Issue #1683 | PR #1912
_ci_lock_try() {
    local remote="$1" ref="$2" note="$3" ask="$4"
    local cur="" sha raw rc=0 prev head
    head="$(_ci_ref_head "${remote}" "${ref}")" || rc=$?
    if [ "${rc}" -eq 1 ]; then
        sha="$(_ci_cas_note_commit "${note}")" || return 3
        rc=0; raw="$(_ci_cas_push "${remote}" "${ref}" "${sha}" "")" || rc=$?
        [ "${rc}" -eq 0 ] && return 0
        _ci_cas_push_failed create "${ref}" "${rc}" "${raw}"
        return "$?"
    fi
    [ "${rc}" -eq 0 ] || return 3
    cur="${head%%$'\t'*}"; prev="${head#*$'\t'}"
    # What: run state only on ask; git-only polls between.
    # Why: AG-CI-020: run state reads stay >= 300 s apart.
    # From: Issue #1683 | PR #1912
    [ "${ask}" -eq 1 ] || return 1
    rc=0; _ci_lock_holder_ended "${prev}" || rc=$?
    if [ "${rc}" -eq 1 ]; then
        ci_log "[CI-INFO-CAS-0006]" "ref=\"${ref}\" holder=\"${prev}\" reason=\"holder run still running; waiting\""
        return 1
    fi
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-CAS-0003]" "ref=\"${ref}\" holder=\"${prev}\" reason=\"holder run state unknown; not taking over\""
        return 3
    fi
    sha="$(_ci_cas_note_commit "${note}")" || return 3
    rc=0; raw="$(_ci_cas_push "${remote}" "${ref}" "${sha}" "${cur}")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-INFO-CAS-0001]" "ref=\"${ref}\" note=\"lock of an ended run taken over\" prev=\"${prev}\""
        return 0
    fi
    _ci_cas_push_failed takeover "${ref}" "${rc}" "${raw}"
}

# What: push sha to ref: create, or lease over $4.
# Why: one owner for lock and mark ref writes.
# From: Issue #1683 | PR #1912
_ci_cas_push() {
    local remote="$1" ref="$2" sha="$3" cur="$4"
    if [ -z "${cur}" ]; then
        git push "${remote}" "${sha}:${ref}" 2>&1
        return
    fi
    git push --force-with-lease="${ref}:${cur}" "${remote}" "${sha}:${ref}" 2>&1
}

# What: delete ref $2 on $1 only while it points at $3.
# Why: one owner for lease deletes of lock and mark refs.
# From: Issue #1683 | PR #1858
_ci_ref_delete() {
    _ci_git_run push --force-with-lease="$2:$3" "$1" ":$2" >&2
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

# What: wait while the holder runs; fail closed on errors.
# Why: unlocked would race; the job timeout bounds the wait.
# From: Issue #1683 | PR #1912
_ci_lock_acquire() {
    local remote="$1" ref="$2" note="$3" backoff="$4"
    local fails=0 max gap asked=0 ask rc=0
    max="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)" || return 2
    gap="$(_ci_variable CI_RUN_STATE_POLL_SECONDS)" || return 2
    while :; do
        ask=0
        if [ $(( $(date +%s) - asked )) -ge "${gap}" ]; then ask=1; asked="$(date +%s)"; fi
        rc=0; _ci_lock_try "${remote}" "${ref}" "${note}" "${ask}" || rc=$?
        case "${rc}" in
            0) return 0 ;;
            1) [ "${ask}" -eq 0 ] || fails=0; sleep "${backoff}" ;;
            2) ;;
            *) fails=$(( fails + 1 ))
               [ "${fails}" -lt "${max}" ] || break
               sleep "${backoff}" ;;
        esac
    done
    ci_error "[CI-ERROR-CAS-0002]" "ref=\"${ref}\" reason=\"lock state unreadable ${fails} times; fail closed\"" "note=${note} last_rc=${rc}"
    return 1
}

# What: Release a lock only if this note still holds it.
# Why: Never delete a lock a takeover reassigned.
# From: Issue #1683
_ci_lock_release() {
    local remote="$1" ref="$2" note="$3" cur="" held rc=0 head
    head="$(_ci_ref_head "${remote}" "${ref}" 1)" || rc=$?
    # What: an absent ref is free; an unknown state fails.
    # Why: a failed query must not report a freed lock.
    # From: Issue #1683 | PR #1858
    [ "${rc}" -ne 1 ] || return 0
    [ "${rc}" -eq 0 ] || return 1
    cur="${head%%$'\t'*}"; held="${head#*$'\t'}"
    if [ "${held}" != "${note}" ]; then
        ci_log "[CI-INFO-CAS-0007]" "ref=\"${ref}\" holder=\"${held}\" mine=\"${note}\" reason=\"lock reassigned; not released\""
        return 0
    fi
    _ci_ref_delete "${remote}" "${ref}" "${cur}" || return 1
    return 0
}

# What: build lock ref of one identity, service, platform.
# Why: one lock key per image being built (§20).
# From: Issue #1683 | PR #1912
_ci_build_lock_ref() {
    local prefix
    prefix="$(_ci_variable CI_BUILD_LOCK_REF)" || return 2
    printf '%s/%s-%s-%s' "${prefix}" "$1" "$2" "${3//\//-}"
}

# What: holder note: lock kind, its keys, run, attempt.
# Why: _ci_lock_holder_ended reads the run and attempt.
# From: Issue #1683 | PR #1912
_ci_lock_note() {
    printf '%s run=%s attempt=%s' "$*" "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-1}"
}

# What: take the build lock; wait while another run builds.
# Why: the waiter then re-resolves and verifies, no rebuild.
# From: Issue #1683 | PR #1912
_ci_build_lock_take() {
    local remote ref backoff identity
    remote="$(_ci_git_remote)" || return 2
    identity="$(_ci_identity_for "$1" "$2")" || return 2
    ref="$(_ci_build_lock_ref "${identity}" "$1" "$2")" || return 2
    backoff="$(_ci_variable CI_LOCK_POLL_SECONDS)" || return 2
    _ci_lock_acquire "${remote}" "${ref}" "$(_ci_lock_note build "$1" "$2")" "${backoff}" || return 2
}

# What: free the build lock of this run.
# Why: a finished pair must not make the next run wait.
# From: Issue #1683 | PR #1912
_ci_build_lock_drop() {
    local remote ref identity
    remote="$(_ci_git_remote)" || return 2
    identity="$(_ci_identity_for "$1" "$2")" || return 2
    ref="$(_ci_build_lock_ref "${identity}" "$1" "$2")" || return 2
    _ci_lock_release "${remote}" "${ref}" "$(_ci_lock_note build "$1" "$2")"
}

# What: head subject of a ref; rc 1 absent, 2 unknown.
# Why: an absent lock or mark is a verdict, not an error.
# From: Issue #1683 | PR #1912
_ci_ref_note() {
    local head
    head="$(_ci_ref_head "$1" "$2")" || return $?
    printf '%s\n' "${head#*$'\t'}"
}

# What: rc 0 if a running other run holds the build lock.
# Why: BUILD_IN_PROGRESS, not MISSING, while it builds.
# From: Issue #1683 | PR #1912
_ci_build_lock_busy() {
    local remote ref rc=0 holder
    remote="$(_ci_git_remote)" || return 2
    ref="$(_ci_build_lock_ref "$1" "$2" "$3")" || return 2
    holder="$(_ci_ref_note "${remote}" "${ref}")" || return $?
    [ "${holder}" != "$(_ci_lock_note build "$2" "$3")" ] || return 1
    rc=0; _ci_lock_holder_ended "${holder}" || rc=$?
    case "${rc}" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# What: ref that holds the last verified digest of a pair.
# Why: one ref per pair keeps the ref count bounded.
# From: Issue #1683 | PR #1912
_ci_verified_ref() {
    local prefix
    prefix="$(_ci_variable CI_VERIFIED_REF)" || return 2
    printf '%s/%s-%s' "${prefix}" "$1" "${2//\//-}"
}

# What: note a verified mark carries for one digest.
# Why: the mark commit subject is the verified digest.
# From: Issue #1683 | PR #1912
_ci_verified_note() {
    printf 'verified %s %s %s' "$1" "$2" "$3"
}

# What: rc 0 if ref $1 holds subject $2, 1 if not.
# Why: one reader for every mark that holds one value.
# From: Issue #1683 | PR #1858
_ci_mark_has() {
    local remote subject
    remote="$(_ci_git_remote)" || return 2
    subject="$(_ci_ref_note "${remote}" "$1")" || return $?
    [ "${subject}" = "$2" ] || return 1
}

# What: set ref $1 to subject $2 (message $3) once.
# Why: one CAS writer for marks; $4 $5 name a failure.
# From: Issue #1683 | PR #1858
_ci_mark_write() {
    local ref="$1" want="$2" remote sha cur rc=0 raw
    remote="$(_ci_git_remote)" || return 2
    _ci_mark_has "${ref}" "${want}" || rc=$?
    [ "${rc}" -ne 0 ] || return 0
    [ "${rc}" -eq 1 ] || return 2
    sha="$(_ci_cas_note_commit "$3")" || return 2
    rc=0; cur="$(_ci_cas_ref_sha "${remote}" "${ref}")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    rc=0; raw="$(_ci_cas_push "${remote}" "${ref}" "${sha}" "${cur}")" || rc=$?
    [ "${rc}" -ne 0 ] || return 0
    # What: a lost push race with an equal mark is success.
    # Why: both runs wrote the same value.
    # From: Issue #1683 | PR #1912
    rc=0; _ci_mark_has "${ref}" "${want}" || rc=$?
    [ "${rc}" -ne 0 ] || return 0
    ci_error "$4" "ref=\"${ref}\" $5" "${raw}"
    return 2
}

# What: rc 0 if a build verified this digest, 1 if not.
# Why: a pushed image is not an accepted image (B20).
# From: Issue #1683 | PR #1912
_ci_verified_has() {
    local ref
    ref="$(_ci_verified_ref "$1" "$2")" || return 2
    _ci_mark_has "${ref}" "$(_ci_verified_note "$1" "$2" "$3")"
}

# What: mark a digest verified after its smoke test.
# Why: ship pushes before it verifies; only this accepts.
# From: Issue #1683 | PR #1912
_ci_verified_mark() {
    local ref note
    ref="$(_ci_verified_ref "$1" "$2")" || return 2
    note="$(_ci_verified_note "$1" "$2" "$3")"
    _ci_mark_write "${ref}" "${note}" "${note}" "[CI-ERROR-SHIP-0007]" \
        "service=\"$1\" platform=\"$2\" digest=\"$3\" reason=\"verified mark not written\""
}

# What: print <name>=NOT-RUN outside a pull request.
# Why: one owner for the PR-only guard (AG-CODE-011).
# From: Issue #1683 | PR #1858
_ci_skip_outside_pr() {
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
        return 1
    fi
    printf '%s=NOT-RUN reason="not a pull request"\n' "$1"
}

# What: mark this run's fingerprint green for its PR.
# Why: a later run of the same PR reuses it (§2.1).
# From: Issue #1683 | PR #1858
ci_cmd_pr_green_mark() {
    local fp ref note rc=0
    if _ci_skip_outside_pr pr-green-mark; then
        return 0
    fi
    if [ "${PR_IS_FORK:-false}" = true ]; then
        printf 'pr-green-mark=NOT-RUN reason="fork PR: the token cannot write refs"\n'
        return 0
    fi
    if [ "${CI_PLAN_ANY_BUILD:-}" != true ]; then
        printf 'pr-green-mark=NOT-RUN reason="plan had no build or verify pair; nothing to carry over" any-build="%s"\n' "${CI_PLAN_ANY_BUILD:-}"
        return 0
    fi
    _ci_require_ghcr_auth || return "$?"
    fp="$(_ci_pr_fingerprint)" || rc=$?
    if [ "${rc}" -eq 1 ]; then
        printf 'pr-green-mark=NOT-RUN reason="a pair has no image; nothing recorded"\n'
        return 0
    fi
    [ "${rc}" -eq 0 ] || return 2
    ref="$(_ci_green_ref)" || return 2
    note="$(_ci_green_note "${fp}")"
    _ci_mark_write "${ref}" "${note}" "${note}"$'\n\n'"$(_ci_lock_note run)" "[CI-ERROR-PLAN-0014]" \
        "fingerprint=\"${fp}\" reason=\"green run mark not written\"" || return 2
    printf 'pr-green-mark=written ref=%s fingerprint=%s\n' "${ref}" "${fp}"
}

# What: verify one digest and mark it on success.
# Why: one owner for the verify-then-mark order (B20).
# From: Issue #1683 | PR #1912
_ci_verify_and_mark() {
    ci_cmd_verify "$1" "$2" "$3" || return "$?"
    _ci_verified_mark "$1" "$3" "$2"
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

# What: the commit this run checked out and builds
# Why: tags, labels, diffs name the tree, not the event
# From: Issue #1683 | PR #1858
_ci_head_commit() {
    _ci_capture 0 git -C "${CI_REPO_ROOT}" rev-parse --verify HEAD
}

# What: Print the ledger blob text; 1 empty, 2 unknown.
# Why: A failed read is UNKNOWN, never "no records".
# From: Issue #1683
_ci_ledger_blob() {
    local remote="$1" rc=0 ledger_ref file
    # What: $2/$3 name another ref and file variable.
    # Why: the refresh records reuse this one reader.
    # From: Issue #1683 | PR #1858
    ledger_ref="$(_ci_variable "${2:-CI_LEDGER_REF}")" || return 2
    file="$(_ci_variable "${3:-CI_LEDGER_FILE}")" || return 2
    _ci_cas_ref_sha "${remote}" "${ledger_ref}" >&2 || rc=$?
    [ "${rc}" -eq 1 ] && return 1
    [ "${rc}" -eq 0 ] || return 2
    # What: this fetch has no retry level.
    # Why: op=git uses shared transient-signature truth.
    # From: Issue #1683
    _ci_retry git git fetch --depth=1 "${remote}" "${ledger_ref}" >&2 || return 2
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

# What: Upsert record lines from stdin in one CAS write.
# Why: §26.1 one atomic ledger write per workflow.
# From: Issue #1683
_ci_ledger_upsert() {
    local remote="$1" new blob rc=0 parent="" ids kept merged blobsha treesha commitsha raw ledger_ref file
    local refvar="${2:-CI_LEDGER_REF}" filevar="${3:-CI_LEDGER_FILE}" mode="${4:-}"
    ledger_ref="$(_ci_variable "${refvar}")" || return 3
    file="$(_ci_variable "${filevar}")" || return 3
    new="$(cat)"
    new="$(_ci_capture 0 awk 'NF>0' <<< "${new}")" || return 3
    [ -n "${new}" ] || return 0
    blob="$(_ci_ledger_blob "${remote}" "${refvar}" "${filevar}")" || rc=$?
    if [ "${rc}" -eq 2 ]; then
        ci_log "[CI-ERROR-LEDGER-0001]" "ref=\"${ledger_ref}\" remote=\"${remote}\" reason=\"ledger read UNKNOWN (raw above); refusing to write\""
        return 3
    fi
    # What: two different records for one identity fail
    # Why: conflicting records fail closed (§26.4)
    # From: Issue #1683 | PR #1912
    local conflict=""
    # What: mode replace: a new line replaces its key.
    # Why: a refresh record is a value, not an acceptance.
    # From: Issue #1683 | PR #1858
    if [ "${mode}" != replace ]; then
        conflict="$(_ci_capture 0 awk -F'\t' "$(cat <<'PROG'
            NF > 0 { if (($1 in seen) && seen[$1] != $0) print $1; seen[$1] = $0 }
PROG
            )" <<< "${blob}"$'\n'"${new}")" || return 3
    fi
    if [ -n "${conflict}" ]; then
        ci_error "[CI-ERROR-LEDGER-0006]" "ref=\"${ledger_ref}\" reason=\"conflicting records for one identity; refusing to write\"" "${conflict}"
        return 3
    fi
    ids="$(_ci_capture 0 cut -f1 <<< "${new}")" || return 3
    if [ "${rc}" -eq 1 ]; then
        kept=""
    else
        parent="$(_ci_capture 0 git rev-parse FETCH_HEAD)" || return 3
        kept="$(_ci_capture 0 awk -F'\t' -v ids="${ids}" "$(cat <<'PROG'
            BEGIN { n = split(ids, a, "\n"); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
            NF > 0 && !($1 in drop)
PROG
            )" <<< "${blob}")" || return 3
    fi
    # What: sort the merged record set deterministically.
    # Why: same inputs -> same blob; §26.4 idempotency.
    # From: Issue #1683 | PR #1858
    merged="$(_ci_capture 0 awk 'NF>0' <<< "${kept}"$'\n'"${new}")" || return 3
    merged="$(_ci_capture 0 env LC_ALL=C sort -u <<< "${merged}")" || return 3
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
    commitsha="$(_ci_bot_commit "${treesha}" "${parent}" "ledger aggregate")" || return 3
    rc=0; raw="$(_ci_cas_push "${remote}" "${ledger_ref}" "${commitsha}" "${parent}")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-INFO-LEDGER-0004]" "ref=\"${ledger_ref}\" commit=\"${commitsha}\" parent=\"${parent:-none}\" records=$(wc -l <<< "${merged}") reason=\"ledger written\""
        return 0
    fi
    _ci_cas_push_failed ledger "${ledger_ref}" "${rc}" "${raw}"
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
    local rc=0 remote tries n=1
    remote="$(_ci_git_remote)" || return 2
    tries="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)" || return 2
    # What: a lost CAS race re-reads the ledger, then writes
    # Why: the other writer's records must be merged in
    # From: Issue #1683 | PR #1912
    while :; do
        rc=0
        printf '%s' "${records}" | _ci_ledger_upsert "${remote}" || rc=$?
        [ "${rc}" -eq 2 ] || break
        [ "${n}" -lt "${tries}" ] || break
        n=$((n + 1))
    done
    if [ "${rc}" -eq 0 ]; then
        printf 'aggregate records=%s\n' "$(_ci_count_lines "${records}")"
        return 0
    fi
    return "${rc}"
}

# What: published per-identity digest for service/platform.
# Why: emit-result and scan-stack resolve (AG-CODE-011).
# From: Issue #1683
_ci_published_digest() {
    local svc="$1" plat="$2" absent="${3:-fail}" identity tag
    identity="$(_ci_identity_for "${svc}" "${plat}")" || return "$?"
    tag="$(_ci_image_tag "${svc}" "${plat}" "${identity}")" || return 2
    if [ "${absent}" = ok ]; then
        _ci_registry_probe "${tag}"
    else
        _ci_registry_digest "${tag}"
    fi
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
    local matrix="${CI_BUILD_MATRIX:-}" svc plat digest pairs rc=0 crc drc vrc failed="" unbuilt="" passed='[]'
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-SCAN-0016]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    pairs="$(_ci_matrix_pairs "${matrix}")" || return 2
    _ci_require_ghcr_auth || return "$?"
    # What: scans every pair, lists failures at the end
    # Why: one finding must not hide the other results
    # From: Issue #1683 | PR #1912
    while read -r svc plat; do
        [ -n "${svc}" ] || continue
        drc=0; digest="$(_ci_published_digest "${svc}" "${plat}" ok)" || drc=$?
        # What: an unbuilt pair is skipped, never passed
        # Why: its build is red; unscanned is never accepted
        # From: Issue #1683 | PR #1858
        if [ "${drc}" -eq 1 ]; then
            ci_log "[CI-WARN-SCAN-0025]" "service=\"${svc}\" platform=\"${plat}\" reason=\"no published image; its build failed, not scanned, not accepted\""
            unbuilt="${unbuilt} ${svc}/${plat}"
            continue
        fi
        if [ "${drc}" -ne 0 ]; then
            ci_log "[CI-ERROR-SCAN-0017]" "service=\"${svc}\" platform=\"${plat}\" reason=\"no published digest to scan\""
            failed="${failed} ${svc}/${plat}"
            rc=2
            continue
        fi
        # What: an unverified digest fails; others go on
        # Why: its readback or smoke test failed (B20)
        # From: Issue #1683 | PR #1912
        vrc=0; _ci_verified_has "${svc}" "${plat}" "${digest}" || vrc=$?
        if [ "${vrc}" -eq 1 ]; then
            ci_log "[CI-ERROR-SCAN-0031]" "service=\"${svc}\" platform=\"${plat}\" digest=\"${digest}\" reason=\"no build verified this digest; not scanned\""
            failed="${failed} ${svc}/${plat}"
            rc=2
            continue
        fi
        if [ "${vrc}" -ne 0 ]; then
            ci_log "[CI-ERROR-SCAN-0032]" "service=\"${svc}\" platform=\"${plat}\" digest=\"${digest}\" reason=\"verified mark unreadable\""
            failed="${failed} ${svc}/${plat}"
            rc=2
            continue
        fi
        crc=0
        ci_cmd_scan "${svc}" "${digest}" "${plat}" || crc=$?
        if [ "${crc}" -ne 0 ]; then
            failed="${failed} ${svc}/${plat}"
            [ "${crc}" -le "${rc}" ] || rc="${crc}"
            continue
        fi
        passed="$(_ci_matrix_append "${passed}" service="${svc}" platform="${plat}")" || return 2
    done <<< "${pairs}"
    # What: the clean pairs go to aggregate as its matrix.
    # Why: a red pair must not block the clean ones
    # From: Issue #1683 | PR #1912
    if [ "${passed}" != '[]' ]; then
        _ci_step_output "[CI-ERROR-SCAN-0026]" passed "$(_ci_matrix_doc "${passed}")" || return 2
    fi
    [ "${rc}" -eq 0 ] || ci_log "[CI-ERROR-SCAN-0024]" "failed=\"${failed# }\" reason=\"scan failed for these pairs; the others were scanned\""
    # What: a full clean run checks for dead ignore ids.
    # Why: an ignore id no scan needs must go.
    # From: Issue #1683 | PR #1912
    if [ "${CI_SCAN_FULL:-}" = 1 ]; then
        if [ "${rc}" -eq 0 ] && [ -z "${unbuilt}" ]; then
            _ci_trivyignore_stale || rc=$?
        else
            ci_log "[CI-WARN-SCAN-0042]" "ignore-stale=NOT-RUN reason=\"a pair failed, so not every image was scanned\""
        fi
    fi
    return "${rc}"
}

# What: issue for ignore-file ids no scan of the run matched
# Why: an issue, no red scan; reruns keep one issue
# From: Issue #1683 | PR #1858
_ci_trivyignore_stale() {
    local ignore fields="" matched="" n kind id stale="" count=0 file="${CI_TMPDIR}/${_CI_TRIVY_MATCHED}" why outcome=success
    ignore="$(_ci_repo_path CI_TRIVY_IGNORE)" || return 2
    [ ! -f "${ignore}" ] || fields="$(_ci_trivyignore_fields "${ignore}")" || return 2
    [ ! -f "${file}" ] || matched="$(< "${file}")"
    while IFS=$'\t' read -r n kind id; do
        [ "${kind}" = id ] || continue
        count=$((count + 1))
        _ci_list_has "${id}" "${matched}" || stale="${stale} ${id}"
    done <<< "${fields}"
    if [ -n "${stale}" ]; then
        outcome=failure
        ci_log "[CI-WARN-SCAN-0041]" "path=\"${ignore}\" stale=\"${stale# }\" reason=\"no scan of this run matched these entries; the issue asks to remove them\""
    else
        printf 'ignore-stale=clean entries=%s\n' "${count}"
    fi
    why="$(_ci_status_readonly_reason)" || return 2
    if [ -n "${why}" ]; then
        printf 'ignore-stale-report=NOT-RUN reason="%s"\n' "${why}"
        return 0
    fi
    _ci_status_issue_kind trivy-ignore-stale "${outcome}" "${stale:+path=${ignore} stale=${stale# }}"
}

# What: load the history a diff needs, plus refs named
# Why: workflows check out one commit; ci.sh owns the diff.
# From: Issue #1683 | PR #1858
_ci_diff_history() {
    local shallow have="" remote head
    local -a deep=() need=("$@")
    shallow="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git rev-parse --is-shallow-repository)" || return 2
    [ "${shallow}" = true ] && deep=(--unshallow)
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ -n "${BASE_SHA:-}" ]; then
        have="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 1 git rev-parse -q --verify "${BASE_SHA}^{commit}")" || return 2
        [ -n "${have}" ] || need+=("${BASE_SHA}")
    fi
    [ "${#deep[@]}" -gt 0 ] || [ "${#need[@]}" -gt 0 ] || return 0
    head="$(_ci_head_commit)" || return 2
    remote="$(_ci_git_remote)" || return 2
    # What: commits and trees only; blobs load on demand.
    # Why: whole history with blobs cost 33 s (Fund 114).
    # From: Issue #1683 | PR #1858
    (cd -- "${CI_REPO_ROOT}" && _ci_retry git-fetch git fetch --no-tags --filter=blob:none "${deep[@]}" "${remote}" "${head}" "${need[@]}") >&2 || return 2
}

# What: This run's base and head diff refs, or empty.
# Why: one owner; changed-files and codeql share the refs.
# From: Issue #1683
_ci_diff_refs() {
    local mb before head
    _ci_diff_history || return 2
    head="$(_ci_head_commit)" || return 2
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
        mb="$(cd -- "${CI_REPO_ROOT}" && _ci_capture 0 git merge-base "${BASE_SHA:-}" "${head}")" || return 2
        printf '%s %s\n' "${mb}" "${head}"
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
        printf '%s %s\n' "${BEFORE_SHA}" "${head}"
    fi
}

# What: write/echo changed-file list path for this event.
# Why: one git-walk owner; plan and checks (AG-CODE-011).
# From: Issue #1683
ci_cmd_changed_files() {
    local out="${RUNNER_TEMP:-${CI_TMPDIR}}/changed-files.txt" base head refs
    refs="$(_ci_diff_refs)" || return 2
    read -r base head <<<"${refs}"
    local list err stat
    if [ -n "${base}" ]; then
        list="$(_ci_run "[CI-ERROR-CORE-0117]" "base=\"${base}\" head=\"${head}\" repo=\"${CI_REPO_ROOT}\"" git -C "${CI_REPO_ROOT}" diff --name-only "${base}" "${head}")" || return 2
        # What: load the changed files' blobs in one fetch.
        # Why: blobless history reads them one by one else.
        # From: Issue #1683 | PR #1858
        stat="$(_ci_run "[CI-ERROR-CORE-0122]" "base=\"${base}\" head=\"${head}\" reason=\"changed blobs not loaded\"" git -C "${CI_REPO_ROOT}" diff --numstat "${base}" "${head}")" || return 2
        ci_log "[CI-INFO-CORE-0124]" "base=\"${base}\" loaded=$(_ci_count_lines "${stat}")"
    else
        ci_log "[CI-INFO-CORE-0118]" "reason=\"no base ref for this event; every tracked file counts as changed\""
        list="$(_ci_run "[CI-ERROR-CORE-0119]" "repo=\"${CI_REPO_ROOT}\"" git -C "${CI_REPO_ROOT}" ls-files)" || return 2
    fi
    if ! err="$( { [ -z "${list}" ] || printf '%s\n' "${list}"; } 2>&1 > "${out}")"; then
        ci_error "[CI-ERROR-CORE-0120]" "file=\"${out}\" reason=\"changed-file list not written\"" "${err}"
        return 2
    fi
    ci_log "[CI-INFO-CORE-0121]" "file=\"${out}\" paths=$(_ci_count_lines "${list}") base=\"${base:-none}\""
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
    local labels l repo out stored
    local -a files=() args=() missing=()
    if _ci_skip_outside_pr pr-labels; then
        return 0
    fi
    if [ "${PR_IS_FORK:-false}" = true ]; then
        printf 'pr-labels=NOT-RUN reason="fork PR: token cannot write labels; label by hand (AG-GH-008)"\n'
        return 0
    fi
    if [ -z "${CHANGED_FILES:-}" ]; then
        ci_log "[CI-ERROR-PRLABELS-0001]" "reason=\"CHANGED_FILES list missing\""
        return 2
    fi
    _ci_collect_changed files || return 2
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
        -F p="${number}" -F n="${item}" -f query="query(\$o: String!, \$r: String!, \$p: Int!, \$n: Int!) { organization(login: \$o) { projectV2(number: \$p) { id } } repository(owner: \$o, name: \$r) { issueOrPullRequest(number: \$n) { ... on Issue { id } ... on PullRequest { id } } } }")"; then
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
        -f query="mutation(\$p: ID!, \$c: ID!) { addProjectV2ItemById(input: {projectId: \$p, contentId: \$c}) { item { id } } }")" || return 2
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
    local matrix="${CI_BUILD_MATRIX:-}" svc svcs rc=0 arc failed=""
    [ -n "${matrix}" ] || { ci_log "[CI-ERROR-ASSEMBLE-0006]" "reason=\"CI_BUILD_MATRIX required\""; return 2; }
    if ! svcs="$(jq -r '[.include[].service] | unique | .[]' <<< "${matrix}" 2>&1)"; then
        ci_error "[CI-ERROR-ASSEMBLE-0011]" "reason=\"CI_BUILD_MATRIX unreadable; no service assembled\"" "${svcs}"$'\n'"matrix: ${matrix}"
        return 2
    fi
    # What: assembles all services, lists failures last
    # Why: a service lacking a platform blocks no other one
    # From: Issue #1683 | PR #1912
    for svc in ${svcs}; do
        arc=0; ci_cmd_assemble "${svc}" || arc=$?
        if [ "${arc}" -ne 0 ]; then
            failed="${failed} ${svc}"
            [ "${arc}" -le "${rc}" ] || rc="${arc}"
        fi
    done
    [ "${rc}" -eq 0 ] || ci_log "[CI-ERROR-ASSEMBLE-0012]" "failed=\"${failed# }\" reason=\"assemble failed for these services; the others were assembled\""
    return "${rc}"
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

# What: label and scope of one SOT status kind.
# Why: the SOT owns both; service and arch are filled in.
# From: Issue #1683 | PR #1912
_ci_status_text() {
    local kind="$1" svc="${2:-}" arch="${3:-}" label scope
    label="$(_ci_block_entry_field status_reports "${kind}" label)" || return 2
    scope="$(_ci_block_entry_field status_reports "${kind}" scope)" || return 2
    if [ -z "${label}" ] || [ -z "${scope}" ]; then
        ci_log "[CI-ERROR-STATUS-0010]" "kind=\"${kind}\" reason=\"no SOT status_reports label and scope\""
        return 2
    fi
    _ci_fill "${scope}" "SERVICE=${svc}"$'\n'"ARCH=${arch}" || return 2
    printf '%s\n%s\n' "${label}${svc:+-${svc}}${arch:+-${arch}}" "${REPLY}"
}

# What: the issue body of one failing case.
# Why: run, commit and raw evidence sit in the issue.
# From: Issue #1683 | PR #1912
_ci_status_body() {
    local scope="$1" run_url="$2" sha="$3" evidence="$4" cap
    local event
    event="$(_ci_env_required GITHUB_EVENT_NAME)" || return 2
    printf '%s\n\nRun: %s\nCommit: %s\nEvent: %s\n' "${scope}" "${run_url}" "${sha}" "${event}"
    [ -z "${evidence}" ] && return 0
    cap="$(_ci_variable CI_STATUS_EVIDENCE_BYTES)" || return 2
    printf "\\nEvidence (first %s of %s bytes; the run log holds all):\\n\`\`\`text\\n%s\\n\`\`\`\\n" \
        "${cap}" "${#evidence}" "${evidence:0:${cap}}"
}

# What: set one standing issue: red files, green closes.
# Why: one open issue per label; the label names the case.
# From: Issue #1683 | PR #1912
_ci_status_apply() {
    local outcome="$1" label="$2" scope="$3" evidence="${4:-}" repo srv sha run_url open ctx body color
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    sha="$(_ci_env_required GITHUB_SHA)" || return 2
    run_url="${srv}/${repo}/actions/runs/$(_ci_env_required GITHUB_RUN_ID)" || return 2
    ctx="repo=\"${repo}\" label=\"${label}\" outcome=${outcome}"
    open="$(_ci_run "[CI-ERROR-STATUS-0003]" "${ctx} step=list" gh issue list --repo "${repo}" --label "${label}" --state open \
        --json number --jq 'map(.number) | min // empty')" || return 2
    if [ "${outcome}" = success ]; then
        [ -n "${open}" ] || { printf 'status=noop label=%s\n' "${label}"; return 0; }
        _ci_run "[CI-ERROR-STATUS-0004]" "${ctx} step=comment issue=${open}" gh issue comment "${open}" --repo "${repo}" \
            --body "Green again in ${run_url} at ${sha}. Closing; a new issue opens with this label if the case turns red." >&2 || return 2
        _ci_run "[CI-ERROR-STATUS-0005]" "${ctx} step=close issue=${open}" gh issue close "${open}" --repo "${repo}" >&2 || return 2
        printf 'status=closed label=%s issue=%s\n' "${label}" "${open}"
        return 0
    fi
    body="$(_ci_status_body "${scope}" "${run_url}" "${sha}" "${evidence}")" || return 2
    if [ -n "${open}" ]; then
        _ci_run "[CI-ERROR-STATUS-0006]" "${ctx} step=comment issue=${open}" gh issue comment "${open}" --repo "${repo}" \
            --body "Still red.${body:+$'\n\n'}${body}" >&2 || return 2
        printf 'status=updated label=%s issue=%s\n' "${label}" "${open}"
        return 0
    fi
    color="$(_ci_variable CI_STATUS_LABEL_COLOR)" || return 2
    _ci_run "[CI-ERROR-STATUS-0007]" "${ctx} step=label" gh label create "${label}" --repo "${repo}" --color "${color}" --force \
        --description "${scope:0:100}" >&2 || return 2
    _ci_run "[CI-ERROR-STATUS-0008]" "${ctx} step=create" gh issue create --repo "${repo}" --label "${label}" \
        --title "[${label}] ${scope}" --body "${body}" >&2 || return 2
    printf 'status=opened label=%s\n' "${label}"
}

# What: file or close one case of a service and arch.
# Why: scan and nightly share this one reporter.
# From: Issue #1683 | PR #1912
_ci_status_case() {
    local kind="$1" outcome="$2" svc="$3" arch="$4" evidence="${5:-}" text label scope
    text="$(_ci_status_text "${kind}" "${svc}" "${arch}")" || return 2
    label="${text%%$'\n'*}" scope="${text#*$'\n'}"
    _ci_status_apply "${outcome}" "${label}" "${scope}" "${evidence}"
}

# What: job and result of a needs object, one line per job.
# Why: one parser for the result gate and nightly report.
# From: Issue #1683 | PR #1912
_ci_needs_pairs() {
    _ci_run "[CI-ERROR-CORE-0133]" "reason=\"CI_NEEDS is not a needs object\"" \
        jq -r 'to_entries[] | "\(.key) \(.value.result)"' <<< "$1"
}

# What: success, skipped or failed for one needs result.
# Why: one class rule; cancelled, null and the rest fail.
# From: Issue #1683 | PR #1912
_ci_needs_class() {
    case "$1" in
        success|skipped) printf '%s\n' "$1" ;;
        *) printf 'failed\n' ;;
    esac
}

# What: report the nightly kinds from the needs results.
# Why: runs in its own always-job; a red job still reports.
# From: Issue #1683 | PR #1912
ci_cmd_nightly_report() {
    local needs="${CI_NEEDS:-}" kind kinds jobs job red="" rc=0 verdict states seen pairs
    local -A got=()
    if [ -z "${needs}" ]; then
        ci_log "[CI-ERROR-STATUS-0001]" "reason=\"CI_NEEDS required\""
        return 2
    fi
    pairs="$(_ci_needs_pairs "${needs}")" || return 2
    while read -r job seen; do
        [ -n "${job}" ] || continue
        got["${job}"]="${seen}"
        if [ "$(_ci_needs_class "${seen}")" != success ]; then
            red+="${red:+$'\n'}${job}=${seen}"
        fi
    done <<< "${pairs}"
    kinds="$(_ci_block_keys status_reports)" || return 2
    while IFS= read -r kind; do
        [ -n "${kind}" ] || continue
        jobs="$(_ci_block_entry_list status_reports "${kind}" jobs)" || return 2
        [ -n "${jobs}" ] || continue
        verdict=success states=""
        while IFS= read -r job; do
            if [ -z "${got[${job}]+set}" ]; then
                ci_log "[CI-ERROR-STATUS-0011]" "kind=\"${kind}\" job=\"${job}\" reason=\"job missing in needs\""
                return 2
            fi
            seen="${got[${job}]}"
            states+="${states:+ }${job}=${seen}"
            case "$(_ci_needs_class "${seen}")" in
                success) ;;
                skipped) [ "${verdict}" = failure ] || verdict=unknown ;;
                *) verdict=failure ;;
            esac
        done <<< "${jobs}"
        # What: a skipped job proves neither green nor red.
        # Why: AG-INT-002: NOT-RUN with reason, no verdict.
        # From: Issue #1683 | PR #1912
        if [ "${verdict}" = unknown ]; then
            printf 'status=NOT-RUN kind=%s reason="a judged job was skipped" jobs="%s"\n' "${kind}" "${states}"
            continue
        fi
        _ci_status_issue_kind "${kind}" "${verdict}" "${states}${red:+ | not green: ${red//$'\n'/ }}" || rc=2
    done <<< "${kinds}"
    return "${rc}"
}

# What: file or close a kind that has no service.
# Why: nightly kinds are one issue per run source.
# From: Issue #1683 | PR #1912
_ci_status_issue_kind() {
    local kind="$1" outcome="$2" evidence="$3" text
    text="$(_ci_status_text "${kind}")" || return 2
    _ci_status_apply "${outcome}" "${text%%$'\n'*}" "${text#*$'\n'}" "${evidence}"
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

# What: sccache mode of this run; _ci_sccache_env sets it.
# Why: a mid-build outage must honour required (AG-CI-011).
# From: Issue #1683 | PR #1912
_CI_SCCACHE_MODE=""

# What: debug log file of the current sccache server.
# Why: start and report run in different subshells.
# From: Issue #1683 | PR #1912
_ci_sccache_log() {
    printf '%s\n' "${SCCACHE_SERVER_UDS%.sock}.log"
}

# What: start the sccache server with a debug log file.
# Why: sccache logs cache errors at debug level only.
# From: Issue #1683 | PR #1912
_ci_sccache_start() {
    local log
    log="$(_ci_sccache_log)"
    SCCACHE_LOG=sccache=debug SCCACHE_ERROR_LOG="${log}" sccache --start-server 2>&1
}

# What: the chain without its first level, redis first.
# Why: one owner of the level-drop step (AG-CODE-011).
# From: Issue #1683 | PR #1858
_ci_sccache_chain_next() {
    case "$1" in redis,*) printf '%s' "${1#redis,}" ;; *) printf '' ;; esac
}

# What: sccache as rustc wrapper on the policy chain.
# Why: AG-CI-009 levels; required fails closed (AG-CI-011).
# From: Issue #1683 | PR #1912
_ci_sccache_env() {
    local service="$1" wrapper="${2:-sccache}" url="${SCCACHE_REDIS_URL:-}" sf policy mode chain prefix next
    prefix="$(_ci_variable CI_CACHE_PREFIX)" || return 2
    prefix="${prefix}-${service}"
    # What: the runner policy file if mounted, else compute.
    # Why: a builder gets the file; rust-build requires it.
    # From: Issue #1683 | PR #1912
    sf="$(_ci_secret_file sccache_policy)"
    if [ -s "${sf}" ]; then policy="$(<"${sf}")"; else policy="$(_ci_sccache_policy)" || return 2; fi
    read -r mode chain <<< "${policy}"
    [ "${chain}" != - ] || chain=""
    _CI_SCCACHE_MODE="${mode}"
    export RUSTC_WRAPPER="${wrapper}" SCCACHE_DIR="${SCCACHE_DIR:-${CI_TMPDIR}/sccache}"
    export SCCACHE_REDIS_KEY_PREFIX="${prefix}"
    sf="$(_ci_secret_file sccache_redis_url)"
    if [ -s "${sf}" ]; then url="$(<"${sf}")"; fi
    # What: a redis level needs a redis url; required fails.
    # Why: policy sets redis only with a url; AG-INT-002.
    # From: Issue #1683 | PR #1858
    if [[ ",${chain}," == *,redis,* ]] && [ -z "${url}" ]; then
        if [ "${mode}" = required ]; then
            ci_log "[CI-ERROR-CACHE-0020]" "chain=\"${chain}\" file=\"${sf}\" reason=\"policy names redis but no redis url is set\""
            return 2
        fi
        # What: optional drops the redis level.
        # Why: AG-CI-011: optional mode keeps correctness.
        # From: Issue #1683 | PR #1858
        next="$(_ci_sccache_chain_next "${chain}")"
        ci_log "[CI-WARN-CACHE-0021]" "chain=\"${chain}\" next=\"${next:-local}\" file=\"${sf}\" reason=\"policy names redis but no redis url is set; level dropped\""
        chain="${next}"
    fi
    _ci_secret_env "$(_ci_secret_file sccache_gha)" ACTIONS_RESULTS_URL ACTIONS_RUNTIME_TOKEN ACTIONS_CACHE_SERVICE_V2
    _ci_sccache_backend "${chain}" "${url}" "${mode}"
    if [ -n "${chain}" ]; then
        ci_log "[CI-INFO-CACHE-0001]" "prefix=\"${prefix}\" mode=${mode} chain=\"${chain}\" runner=\"${RUNNER_ENVIRONMENT:-unset}\""
    else
        ci_log "[CI-INFO-CACHE-0002]" "prefix=\"${prefix}\" mode=${mode} backend=local dir=\"${SCCACHE_DIR}\""
    fi
    # What: own server socket; start it as the probe.
    # Why: a shared port lets parallel runs collide.
    # From: Issue #1683 | PR #1858
    local probe prc=0 sock_dir step=1
    sock_dir="$(_ci_mktemp -d "${CI_TMPDIR}/sccache-srv.XXXXXX")" || return 2
    export SCCACHE_SERVER_UDS="${sock_dir}/s${step}.sock"
    probe="$(_ci_sccache_start)" || prc=$?
    [ "${prc}" -eq 0 ] && return 0
    if [ "${mode}" = required ]; then
        ci_error "[CI-ERROR-CACHE-0008]" "prefix=\"${prefix}\" chain=\"${chain:-local}\" rc=${prc} reason=\"required sccache cache did not start; fail closed\"" "${probe}"
        unset RUSTC_WRAPPER
        _ci_sccache_stop
        unset SCCACHE_SERVER_UDS
        return 2
    fi
    # What: optional: drop redis, then remote, then local.
    # Why: AG-CI-011: optional mode keeps correctness.
    # From: Issue #1683 | PR #1858
    while [ -n "${chain}" ]; do
        next="$(_ci_sccache_chain_next "${chain}")"
        ci_error "[CI-WARN-CACHE-0003]" "prefix=\"${prefix}\" chain=\"${chain}\" next=\"${next:-local}\" rc=${prc} reason=\"sccache cache level unavailable\"" "${probe}"
        _ci_sccache_reap "${sock_dir}"
        chain="${next}"
        _ci_sccache_backend "${chain}" "${url}" "${mode}"
        step=$(( step + 1 ))
        export SCCACHE_SERVER_UDS="${sock_dir}/s${step}.sock"
        prc=0
        probe="$(_ci_sccache_start)" || prc=$?
        [ "${prc}" -eq 0 ] && return 0
    done
    ci_error "[CI-WARN-CACHE-0004]" "prefix=\"${prefix}\" rc=${prc} reason=\"sccache unavailable; direct rustc\"" "${probe}"
    unset RUSTC_WRAPPER
    _ci_sccache_stop || return 2
    unset SCCACHE_SERVER_UDS
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

# What: kill timeout (s) of a docker run/exec CI command.
# Why: AG-CI-016: one SOT value, checked before use.
# From: Issue #1683 | PR #1858
_ci_container_limit() {
    local t
    t="$(_ci_variable CI_CONTAINER_CMD_TIMEOUT)" || return 2
    if [[ ! "${t}" =~ ^[1-9][0-9]*$ ]]; then
        ci_log "[CI-ERROR-JOBS-0008]" "value=\"${t}\" reason=\"CI_CONTAINER_CMD_TIMEOUT must be positive whole seconds\""
        return 2
    fi
    printf '%s\n' "${t}"
}

# What: docker exec with the command under timeout -s KILL.
# Why: AG-CI-016: a hung exec ends; rc 137 to the caller.
# From: Issue #1683 | PR #1858
_ci_bounded_exec() {
    local cid="$1" t
    shift
    t="$(_ci_container_limit)" || return 2
    docker exec "${cid}" timeout -s KILL "${t}" "$@"
}

# What: offline docker run, command under timeout -s KILL.
# Why: --init: timeout as PID 1 ignores its own KILL.
# From: Issue #1683 | PR #1858
_ci_bounded_run() {
    local vol="$1" image="$2" t
    local -a mount=()
    shift 2
    t="$(_ci_container_limit)" || return 2
    [ -z "${vol}" ] || mount=(-v "${vol}")
    docker run --rm --init --network none "${mount[@]}" --entrypoint timeout "${image}" -s KILL "${t}" "$@"
}

# What: stop this run's sccache server, drop its socket.
# Why: a started server must not outlive its run.
# From: Issue #1683 | PR #1858
_ci_sccache_stop() {
    local out rc=0 frc=0
    [ -n "${SCCACHE_SERVER_UDS:-}" ] || return 0
    if [ -n "${RUSTC_WRAPPER:-}" ]; then
        out="$(sccache --stop-server 2>&1)" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-CACHE-0005]" "rc=${rc} reason=\"sccache server stop failed\"" "${out}"
            frc=2
        fi
    fi
    _ci_sccache_reap "${SCCACHE_SERVER_UDS%/*}" || frc=2
    rm -rf -- "${SCCACHE_SERVER_UDS%/*}"
    return "${frc}"
}

# What: test whether a /proc entry is dead or exiting.
# Why: environ fails once the address space is gone.
# From: Issue #1683 | PR #1912
_ci_proc_dead() {
    local stat_s state mem_s
    if ! stat_s="$( { cat "$1/stat"; } 2>&1)"; then
        REPLY="${stat_s}"
        [ -e "$1" ] || return 0
        return 2
    fi
    state="${stat_s##*) }"
    [ "${state%% *}" != Z ] || return 0
    if ! mem_s="$( { cat "$1/statm"; } 2>&1)"; then
        REPLY="${mem_s}"
        [ -e "$1" ] || return 0
        return 2
    fi
    [ "${mem_s%% *}" = 0 ]
}

# What: kill sccache servers under this run's socket dir.
# Why: a server timed out on Redis keeps on running.
# From: Issue #1683 | PR #1858
_ci_sccache_reap() {
    local dir="$1" p env_s pst out rc=0
    for p in /proc/[0-9]*; do
        [ -r "${p}/environ" ] || continue
        [ "$(cat "${p}/comm" 2>&1)" = sccache ] || continue
        # What: a dead or exiting server is skipped.
        # Why: environ fails until the parent collects it.
        # From: Issue #1683 | PR #1912
        pst=0
        _ci_proc_dead "${p}" || pst=$?
        if [ "${pst}" -eq 2 ]; then
            ci_error "[CI-ERROR-CACHE-0019]" "pid=${p#/proc/} reason=\"sccache server stat unreadable\"" "${REPLY}"
            rc=2
            continue
        fi
        [ "${pst}" -ne 0 ] || continue
        # What: test again after a failed environ read.
        # Why: a stopped server turns zombie after the test.
        # From: Issue #1683 | PR #1912
        if ! env_s="$( { tr '\0' '\n' < "${p}/environ"; } 2>&1)"; then
            pst=0
            _ci_proc_dead "${p}" || pst=$?
            [ "${pst}" -eq 0 ] || { ci_error "[CI-ERROR-CACHE-0011]" "pid=${p#/proc/} reason=\"sccache server environ unreadable\"" "${env_s}"; rc=2; }
            continue
        fi
        [[ $'\n'"${env_s}" == *$'\n'"SCCACHE_SERVER_UDS=${dir}/"* ]] || continue
        out="$(kill "${p#/proc/}" 2>&1)" || [ ! -e "${p}" ] || { ci_error "[CI-ERROR-CACHE-0006]" "pid=${p#/proc/} reason=\"sccache server kill failed\"" "${out}"; rc=2; }
    done
    return "${rc}"
}

# =========================================================
# BUILD ENGINE
# =========================================================

# What: Fail unless GHCR credentials are present.
# Why: Every GHCR action authenticates, never anonymous.
# From: Issue #1683
_ci_require_ghcr_auth() {
    if [ -z "${GITHUB_ACTOR:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-BUILD-0002]" "reason=\"GHCR credentials required; anonymous is rate-limited\""
        return 2
    fi
    # What: log docker in to the image registry, retried
    # Why: auth is ci.sh policy (§7); AG-CI-013 retries it
    # From: Issue #1683 | PR #1858
    local reg out
    reg="$(_ci_registry)" || return "$?"
    if ! out="$(_ci_retry registry _ci_registry_login_once "${reg}" GITHUB_ACTOR GHCR_TOKEN)"; then
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
    _ci_retry registry _ci_registry_login_once "" DOCKERHUB_USERNAME DOCKERHUB_TOKEN >&2 || return 2
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
    local id="$1" key="$2" value="$3" var="${4:-GITHUB_OUTPUT}" file err
    file="${!var:-}"
    [ -n "${file}" ] || return 0
    if ! err="$(printf '%s=%s\n' "${key}" "${value}" 2>&1 >> "${file}")"; then
        ci_error "${id}" "file=\"${file}\" key=\"${key}\" reason=\"step output not written\"" "${err}"
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
    _ci_js_runner="$(_ci_runner_label "${_ci_js_plat}" "[CI-ERROR-JOBS-0002]" "reason=\"no runner label for the first build_matrix platform\"")" || return 2
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
    local runner json job vdir
    local -a js_jobs=() js_pairs=()
    local -A js_min=()
    _ci_job_settings_read runner js_jobs js_min || return 2
    for job in "${js_jobs[@]}"; do js_pairs+=("${job}" "${js_min[${job}]}"); done
    json="$(_ci_capture 0 jq -cn "reduce range(0; \$ARGS.positional | length; 2) as \$i ({}; . + {(\$ARGS.positional[\$i]): (\$ARGS.positional[\$i + 1] | tonumber)})" --args "${js_pairs[@]}")" || return 2
    _ci_step_output "[CI-ERROR-JOBS-0005]" runner "${runner}" || return 2
    _ci_step_output "[CI-ERROR-JOBS-0006]" timeouts "${json}" || return 2
    # What: the validate shared dir, for the job's volume.
    # Why: the workflow reads no SOT; this is the owner.
    # From: Issue #1683 | PR #1912
    vdir="$(_ci_variable CI_VALIDATE_SHARED_DIR)" || return 2
    _ci_step_output "[CI-ERROR-JOBS-0007]" validate-dir "${vdir}" || return 2
    printf 'runner=%s\ntimeouts=%s\nvalidate-dir=%s\n' "${runner}" "${json}" "${vdir}"
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
            [ -z "${raw}" ] || printf '%s\n' "${raw}"
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
    local name prefix
    name="$(_ci_image_ref "$1")" || return 2
    # What: the identity tag prefix comes from the SOT.
    # Why: AG-REL-015 keeps sha- for the commit SHA only.
    # From: Issue #1683 | PR #1912
    _ci_block_entry_fields release "" tag_identity_prefix prefix || return 2
    if [ -z "${prefix}" ]; then
        ci_log "[CI-ERROR-CORE-0141]" "reason=\"no SOT release.tag_identity_prefix; FAIL CLOSED\""
        return 2
    fi
    printf '%s:%s%s-%s' "${name}" "${prefix}" "$3" "${2##*/}"
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

# What: OCI labels from the SOT, the env and the checkout
# Why: Provenance labels set once, not per Dockerfile.
# From: Issue #1683
_ci_oci_labels() {
    local service="$1" repo source base final created lic head desc
    repo="$(_ci_repo)" || return 2
    lic="$(_ci_release_value license)" || return 2
    source="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    source="${source}/${repo}"
    final="$(_ci_required_field "${service}" final_base)" || return 2
    base="$(_ci_base_image "${final}" "[CI-ERROR-BUILD-0014]" "service=\"${service}\" key=\"base_images.${final}\" reason=\"no final base in SOT\"")" || return 2
    head="$(_ci_head_commit)" || return 2
    desc="$(_ci_required_field "${service}" description)" || return 2
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'org.opencontainers.image.created=%s\n' "${created}"
    printf 'org.opencontainers.image.revision=%s\n' "${head}"
    printf 'org.opencontainers.image.version=%s\n' "${head}"
    printf 'org.opencontainers.image.source=%s\n' "${source}"
    printf 'org.opencontainers.image.url=%s\n' "${source}"
    printf 'org.opencontainers.image.documentation=%s\n' "${source}"
    printf 'org.opencontainers.image.licenses=%s\n' "${lic}"
    printf 'org.opencontainers.image.vendor=%s\n' "${repo%%/*}"
    printf 'org.opencontainers.image.title=%s\n' "${service}"
    printf 'org.opencontainers.image.description=%s\n' "${desc}"
    printf 'org.opencontainers.image.base.name=%s\n' "${base%@*}"
    printf 'org.opencontainers.image.base.digest=%s\n' "${base#*@}"
}

# What: registry layer cache ref of a target and arch.
# Why: §35: one cache per service and arch; GC reads it.
# From: Issue #1683 | PR #1912
_ci_build_cache_ref() {
    local name tag
    name="$(_ci_image_ref "$1")" || return 2
    tag="$(_ci_variable CI_BUILD_CACHE_TAG)" || return 2
    printf '%s:%s-%s' "${name}" "${tag}" "${2##*/}"
}

# What: start a docker-container BuildKit for one build.
# Why: the docker driver cannot export a cache (§35).
# From: Issue #1683 | PR #1912
_ci_buildx_start() {
    local name="$1" img names n v conf
    local -a opts=()
    img="$(_ci_base_image buildkit "[CI-ERROR-BUILD-0024]" "key=\"base_images.buildkit\" reason=\"no BuildKit image in SOT\"")" || return 2
    opts+=(--driver-opt "image=${img}")
    # What: the job proxy reaches the BuildKit daemon.
    # Why: AG-CI-009; the daemon pulls and caches itself.
    # From: Issue #1683 | PR #1912
    names="$(_ci_proxy_names)" || return 2
    while IFS= read -r n; do
        [ -n "${n}" ] || continue
        v="${!n//\"/\"\"}"
        opts+=(--driver-opt "\"env.${n}=${v}\"")
    done <<< "${names}"
    if [ -n "${HTTP_PROXY:-}" ] && [ -n "${PROJECT_SELFHOSTED_PROXY_CA:-}" ]; then
        conf="$(_ci_buildkitd_config)" || return 2
        opts+=(--buildkitd-config "${conf}")
    fi
    _ci_retry buildx docker buildx create --name "${name}" --driver docker-container \
        "${opts[@]}" --bootstrap >&2
}

# What: the host's persistent builder; create if absent.
# Why: §34: one buildkitd per self-hosted host, kept.
# From: Issue #1683 | PR #1912
_ci_buildx_host() {
    local name="$1" rc=0 out
    out="$(docker buildx inspect "${name}" 2>&1)" && return 0
    _ci_buildx_start "${name}" || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    # What: a parallel job may have created it first.
    # Why: the second create fails; the builder exists.
    # From: Issue #1683 | PR #1912
    out="$(docker buildx inspect "${name}" 2>&1)" && return 0
    ci_error "[CI-ERROR-BUILD-0027]" "builder=\"${name}\" rc=${rc} reason=\"persistent BuildKit builder neither found nor created\"" "${out}"
    return 2
}

# What: buildkitd config trusting the job CA bundle.
# Why: the daemon talks TLS through the self-hosted proxy.
# From: Issue #1683 | PR #1912
_ci_buildkitd_config() {
    local bundle="${CURL_CA_BUNDLE:-}" reg keys k img hosts host conf body=""
    if [ ! -s "${bundle}" ]; then
        ci_log "[CI-ERROR-BUILD-0026]" "bundle=\"${bundle}\" reason=\"proxy CA set but no job CA bundle\""
        return 2
    fi
    reg="$(_ci_registry)" || return 2
    hosts="${reg%%/*}"
    keys="$(_ci_block_keys base_images all)" || return 2
    while IFS= read -r k; do
        [ -n "${k}" ] || continue
        img="$(_ci_block_entry_field base_images "" "${k}")" || return 2
        hosts+=$'\n'"${img%%/*}"
    done <<< "${keys}"
    hosts="$(_ci_capture 0 sort -u <<< "${hosts}")" || return 2
    while IFS= read -r host; do
        [ -n "${host}" ] || continue
        body+="[registry.\"${host}\"]"$'\n'"  ca = [\"${bundle}\"]"$'\n'
    done <<< "${hosts}"
    conf="$(_ci_mktemp "${CI_TMPDIR}/buildkitd.XXXXXX")" || return 2
    _ci_write_secret "${conf}" "${body}" || return 2
    printf '%s\n' "${conf}"
}

# What: remove a builder and its state after the build.
# Why: AG-CI-016: no container or volume outlives a job.
# From: Issue #1683 | PR #1912
_ci_buildx_stop() {
    _ci_run "[CI-ERROR-BUILD-0025]" "builder=\"$1\" reason=\"BuildKit builder not removed\"" docker buildx rm "$1" >&2
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
    local arc=0
    _ci_file_match "[CI-ERROR-BUILD-0023]" "service=\"${service}\"" "${df}" '^ARG BUILD_IDENTITY$' || arc=$?
    case "${arc}" in
        0) ;;
        1)
            ci_log "[CI-ERROR-BUILD-0013]" "service=\"${service}\" path=\"${df}\" reason=\"no ARG BUILD_IDENTITY; layer cache could ship stale packages\""
            return 2
            ;;
        *) return 2 ;;
    esac
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
        _ci_text_has "^${sname}=" "${vargs}" || {
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
    produced_rc=0
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
    # What: registry layer cache, always read (§35).
    # Why: one writer: only non-PR runs export layers.
    # From: Issue #1683 | PR #1912
    local cref builder
    cref="$(_ci_build_cache_ref "${service}" "${platform}")" || { _ci_clear_runtime >&2; return 2; }
    args+=(--cache-from "type=registry,ref=${cref}")
    case "${GITHUB_EVENT_NAME:-}" in
        ''|pull_request) ;;
        *) args+=(--cache-to "type=registry,ref=${cref},mode=max,ignore-error=true") ;;
    esac
    # What: self-hosted: the host builder; hosted: own one.
    # Why: §34 keeps host state; a hosted VM ends anyway.
    # From: Issue #1683 | PR #1912
    local own=1
    builder="$(_ci_variable CI_BUILDX_BUILDER)" || { _ci_clear_runtime >&2; return 2; }
    if _ci_runner_self_hosted; then
        own=0
        _ci_buildx_host "${builder}" || { _ci_clear_runtime >&2; return 2; }
    else
        builder+="-$$"
        _ci_buildx_start "${builder}" || { _ci_clear_runtime >&2; return 2; }
    fi
    # What: retry buildx and capture its output once.
    # Why: ci_error already shows raw; avoid double output.
    # From: Issue #1683
    local buildlog rc=0 crc=0 brc=0
    buildlog="$(_ci_retry buildx docker buildx build --builder "${builder}" --load --platform "${platform}" --tag "${tag}" "${args[@]}" "${context}")" || rc=$?
    [ "${own}" -eq 0 ] || _ci_buildx_stop "${builder}" || brc=$?
    _ci_clear_runtime >&2 || crc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-BUILD-0019]" "service=\"${service}\" platform=\"${platform}\" tag=\"${tag}\" context=\"${context}\" rc=${rc} reason=\"docker buildx build failed (raw above)\""
        return "${rc}"
    fi
    [ "${crc}" -eq 0 ] || return 2
    [ "${brc}" -eq 0 ] || return 2
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
    # What: @ALPINE_BRANCH@ is vX.Y of this image's alpine.
    # Why: the base is latest; the image knows its branch.
    # From: Issue #1683 | PR #1858
    local tagged="${APK_TAGGED_REPOS:-}" rel
    case "${tagged}" in
        *@ALPINE_BRANCH@*)
            if ! rel="$(cat "${root}/etc/alpine-release" 2>&1)"; then
                ci_error "[CI-ERROR-APKSETUP-0006]" "path=\"${root}/etc/alpine-release\" reason=\"no alpine release; no repo branch\"" "${rel}"
                return 2
            fi
            if [[ ! "${rel}" =~ ^([0-9]+\.[0-9]+)\. ]]; then
                ci_log "[CI-ERROR-APKSETUP-0007]" "release=\"${rel}\" reason=\"alpine release is not X.Y.Z; no repo branch\""
                return 2
            fi
            _ci_fill "${tagged}" "ALPINE_BRANCH=v${BASH_REMATCH[1]}" || return 2
            tagged="${REPLY}"
            ;;
    esac
    for kv in ${tagged}; do
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

# What: In-image accounts and directories from IMAGE_SETUP.
# Why: the Dockerfile runs this one command, no RUN logic.
# From: Issue #1683 | PR #1912
ci_cmd_image_setup() {
    local tok kind a b c out rc
    for tok in ${IMAGE_SETUP:-}; do
        kind="${tok%%=*}"
        IFS=: read -r a b c <<< "${tok#*=}"
        rc=0
        case "${kind}" in
            group) out="$(addgroup -g "${b}" "${a}" 2>&1)" || rc=$? ;;
            member) out="$(addgroup "${a}" "${b}" 2>&1)" || rc=$? ;;
            user) out="$(adduser -D -H -u "${b}" -G "${c}" -s /sbin/nologin "${a}" 2>&1)" || rc=$? ;;
            dir)
                out="$(mkdir -p "${a}" 2>&1)" || rc=$?
                if [ "${rc}" -eq 0 ] && [ -n "${b}" ]; then out="$(chown -R "${b}:${b}" "${a}" 2>&1)" || rc=$?; fi
                ;;
            *) out="unknown setup kind"; rc=2 ;;
        esac
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-IMGSETUP-0001]" "token=\"${tok}\" rc=${rc} reason=\"image setup step failed\"" "${out}"
            return 2
        fi
    done
    printf 'image-setup=ok steps=%s\n' "$(wc -w <<< "${IMAGE_SETUP:-}")"
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

# What: rust-build state; globals, not locals.
# Why: the EXIT trap and the _ci_rb_* steps share it.
# From: Issue #1683 | PR #1912
_CI_RB_DISTCC=0
_CI_RB_CCACHE=0
_CI_RB_CA=0
_CI_RB_CA_FILE=/usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt
_CI_RB_ACC=""
_CI_RB_REMOTE_ID=""
_CI_RB_PAIRS=""
declare -gA _CI_RB_DRIVER_PATH=()

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

# What: EXIT trap: stop pump and sccache, drop CA, acc.
# Why: no proxy CA, server or temp dir outlives the step.
# From: Issue #1683 | PR #1912
_ci_rust_build_cleanup() {
    local status=$?
    local out
    local failed=0
    if ! _ci_rust_stop_pump; then
        failed=1
    fi
    if ! _ci_sccache_stop; then
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
    if [ -n "${_CI_RB_ACC}" ]; then
        if ! out="$(rm -rf -- "${_CI_RB_ACC}" 2>&1)"; then
            ci_error "[CI-ERROR-RUSTBUILD-0051]" "dir=\"${_CI_RB_ACC}\" reason=\"rust-build temp dir not removed\"" "${out}"
            failed=1
        fi
        _CI_RB_ACC=""
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

# What: one overall counter of sccache --show-stats.
# Why: exact label; "(Rust)" and rate rows never match.
# From: Issue #1683 | PR #1912
_ci_sccache_count() {
    awk -v l="$1" 'index($0, l " ") == 1 { r = substr($0, length(l) + 1); gsub(/^ +| +$/, "", r); if (r ~ /^[0-9]+$/) print r }' <<< "$2"
}

# What: log sccache use; check requests and cache errors.
# Why: AG-CI-011, AG-CI-007: a dead level must not pass.
# From: Issue #1683 | PR #1912
_ci_sccache_report() {
    local stats req hits miss errs="" label n
    stats="$(_ci_run "[CI-ERROR-CACHE-0012]" "reason=\"sccache stats not readable\"" sccache --show-stats)" || return 2
    req="$(_ci_sccache_count "Compile requests" "${stats}")"
    hits="$(_ci_sccache_count "Cache hits" "${stats}")"
    miss="$(_ci_sccache_count "Cache misses" "${stats}")"
    # What: the full stats follow the counts as raw.
    # Why: hits=0 needs the error and non-cacheable rows.
    # From: Issue #1683 | PR #1912
    ci_error "[CI-INFO-CACHE-0013]" "mode=${_CI_SCCACHE_MODE} requests=${req:-none} hits=${hits:-none} misses=${miss:-none}" "${stats}"
    if [[ ! "${req}" =~ ^[1-9][0-9]*$ ]]; then
        if [ "${_CI_SCCACHE_MODE}" = required ]; then
            ci_error "[CI-ERROR-CACHE-0014]" "reason=\"required sccache saw no compile request; unused\"" "${stats}"
            return 2
        fi
        ci_error "[CI-WARN-CACHE-0015]" "mode=${_CI_SCCACHE_MODE} reason=\"sccache saw no compile request\"" "${stats}"
        return 0
    fi
    # What: read, lookup errors and timeouts.
    # Why: sccache turns each into a miss and compiles.
    # From: Issue #1683 | PR #1912
    for label in "Cache errors" "Cache read errors" "Cache timeouts"; do
        n="$(_ci_sccache_count "${label}" "${stats}")"
        [ "${n}" = 0 ] || errs+=" ${label// /_}=${n:-none}"
    done
    # What: write errors by their cause in the server log.
    # Why: 409 exists and 429 skipped keep the level alive.
    # From: Issue #1683 | PR #1912
    local log wr wlog wex=0 wrl=0 chk cause
    local ok='Error executing cache write: (AlreadyExists \(permanent\)|RateLimited \(temporary\))'
    log="$(_ci_sccache_log)"
    wr="$(_ci_sccache_count "Cache write errors" "${stats}")"
    if [ "${wr}" != 0 ]; then
        wlog="$(_ci_capture 1 grep -c 'Error executing cache write:' "${log}")" || return 2
        wex="$(_ci_capture 1 grep -c 'Error executing cache write: AlreadyExists (permanent)' "${log}")" || return 2
        wrl="$(_ci_capture 1 grep -c 'Error executing cache write: RateLimited (temporary)' "${log}")" || return 2
        [ "${wr}" = "${wlog}" ] && [ "${wlog}" = "$(( wex + wrl ))" ] \
            || errs+=" Cache_write_errors=${wr:-none} exists=${wex} rate_limited=${wrl}"
        chk="$(_ci_capture 1 grep -o 'storage check result: [A-Za-z]*' "${log}")" || return 2
        case "${chk}" in *ReadOnly*) errs+=" storage=ReadOnly" ;; esac
    fi
    if [ -z "${errs}" ]; then
        [ "${wr}" = 0 ] || ci_log "[CI-INFO-CACHE-0018]" "write_exists=${wex} write_rate_limited=${wrl} reason=\"writes skipped; entries exist or retry later\""
        return 0
    fi
    # What: the error lines of the sccache server log.
    # Why: AG-INT-002: the cause next to the counters.
    # From: Issue #1683 | PR #1912
    cause="$(_ci_capture 1 grep -E 'storage check result|storage write check failed|cache storage (read check|failed to read)|Error executing cache write|Cache read error|Cache timed out|compile result: cache error' "${log}")" || return 2
    cause="$(_ci_capture 1 grep -vE "${ok}" <<< "${cause}")" || return 2
    if [ "${_CI_SCCACHE_MODE}" = required ]; then
        ci_error "[CI-ERROR-CACHE-0016]" "errors=\"${errs# }\" log=\"${log}\" reason=\"required sccache cache level failed\"" "${cause}"
        return 2
    fi
    ci_error "[CI-WARN-CACHE-0017]" "mode=${_CI_SCCACHE_MODE} errors=\"${errs# }\" log=\"${log}\" reason=\"sccache cache level failed\"" "${cause}"
}

# What: cargo build; only optional sccache may be dropped.
# Why: a real build error fails at once, never degrades.
# From: Issue #1683 | PR #1912
_ci_rust_cargo_build() {
    local crates="$1" musl_target="$2" cargo_jobs="$3" crate
    local cargo_log cargo_status degraded=0
    local -a layers=() picks=() pst=() cl=()
    read -ra cl <<< "${crates}"
    for crate in "${cl[@]}"; do picks+=(-p "${crate}"); done
    # What: active layers of rust-build, dropped in order.
    # Why: ccache wraps distcc; sccache is the rustc layer.
    # From: Issue #1683 | PR #1912
    [ "${_CI_RB_CCACHE}" = 1 ] && layers+=(ccache)
    [ "${_CI_RB_DISTCC}" = 1 ] && layers+=(distcc)
    [ -n "${RUSTC_WRAPPER:-}" ] && layers+=(sccache)
    while :; do
        cargo_log="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
        # What: PIPESTATUS splits cargo's rc from tee's rc.
        # Why: the classifier needs the whole cargo log.
        # From: Issue #1683 | PR #1912
        pst=(0 0)
        cargo build -j "${cargo_jobs}" --release --locked --target "${musl_target}" "${picks[@]}" 2>&1 \
            | tee "${cargo_log}" || pst=("${PIPESTATUS[@]}")
        if [ "${pst[1]}" -ne 0 ]; then
            rm -f "${cargo_log}"
            ci_log "[CI-ERROR-RUSTBUILD-0052]" "rc=${pst[1]} cargo_rc=${pst[0]} reason=\"cargo log not written by tee\""
            return 2
        fi
        cargo_status="${pst[0]}"
        if [ "${cargo_status}" -eq 0 ]; then
            rm -f "${cargo_log}"
            [ "${degraded}" -eq 0 ] || ci_log "[CI-INFO-RUSTBUILD-0009]" "reason=\"cargo build ok after an accelerator fallback\""
            [ -z "${RUSTC_WRAPPER:-}" ] || _ci_sccache_report || return 2
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
        # What: a required sccache never drops mid-build.
        # Why: AG-CI-011: required mode fails closed.
        # From: Issue #1683 | PR #1912
        if [ "${layers[0]}" = sccache ] && [ "${_CI_SCCACHE_MODE}" = required ]; then
            ci_log "[CI-ERROR-RUSTBUILD-0053]" "rc=${cargo_status} reason=\"sccache outage under SCCACHE_REDIS_MODE=required; fail closed\""
            return 2
        fi
        case "${layers[0]}" in
            ccache|distcc)
                ci_log "[CI-ERROR-RUSTBUILD-0011]" "rc=${cargo_status} layer=${layers[0]} reason=\"configured accelerator outage; no fallback (AG-CI-007)\""
                return 2 ;;
            sccache)
                unset RUSTC_WRAPPER SCCACHE_REDIS SCCACHE_CONF SCCACHE_REDIS_KEY_PREFIX
                ci_log "[CI-WARN-RUSTBUILD-0013]" "reason=\"accelerator outage; retry without sccache\"" ;;
        esac
        layers=("${layers[@]:1}")
    done
}

# What: Print the distcc wrapper for paths and drivers.
# Why: one generator for the wrapper rust-build installs.
# From: Issue #1533 | PR #1912
_ci_rust_distcc_wrapper() {
    local d
    if [ "$#" -lt 4 ]; then
        ci_error "[CI-ERROR-RUSTBUILD-0045]" "args=$# reason=\"need 3 paths and a driver=path\"" "$(printf '%s\n' "$@")"
        return 2
    fi
    printf '#!/bin/sh\nset -eu\ndistcc_real="%s"\nwrapper_self="%s"\nwrapper_dir="%s"\n' "$1" "$2" "$3"
    shift 3
    cat <<'SH'
compiler_name="$(basename "$0")"
case "$compiler_name" in
SH
    for d in "$@"; do
        printf '  %s) real_compiler="%s"; local_compiler="%s" ;;\n' "${d%%=*}" "${d%%=*}" "${d#*=}"
    done
    cat <<'SH'
  *)
    if [ "$#" -ge 1 ] && [ -x "${1:-}" ]; then
      if ! resolved_arg1="$(readlink -f "$1")"; then
        echo "[CI-ERROR-RUSTBUILD-0015] arg=$1 reason=\"distcc wrapper: readlink -f failed\"" >&2
        exit 1
      fi
      case "$resolved_arg1" in
        "$wrapper_self"|"$wrapper_dir"/*)
          echo "[CI-ERROR-RUSTBUILD-0016] arg=$1 reason=\"distcc wrapper: compiler resolves to the wrapper itself\"" >&2
          exit 1
          ;;
      esac
      real_compiler="$1"
      local_compiler="$1"
      shift
    else
      echo "[CI-ERROR-RUSTBUILD-0017] argv0=$0 reason=\"distcc wrapper: unknown invocation\"" >&2
      exit 1
    fi
    ;;
esac
SH
    # What: the wrapper drops its own dir from PATH.
    # Why: distcc's local cc -E must not find the wrapper.
    # From: Issue #1683 | PR #1912
    cat <<'SH'
trimmed_path=""
set -f
old_ifs="$IFS"; IFS=:
for path_dir in $PATH; do
  [ "$path_dir" = "$wrapper_dir" ] || trimmed_path="${trimmed_path:+$trimmed_path:}$path_dir"
done
IFS="$old_ifs"
set +f
PATH="$trimmed_path"; export PATH
SH
    cat <<'SH'
normalize_argument() {
  arg="$1"
  case "$arg" in
    -I*|-isystem*)
      case "$arg" in
        -I*) echo "${arg#-I}" ;;
        -isystem*) echo "${arg#-isystem}" ;;
      esac
      return
      ;;
  esac
  printf "%s\n" "$arg"
}
matches_aws_lc_generated_path() {
  arg="$1"
  case "$arg" in
    *aws-lc-sys*|*aws_lc_sys*)
      case "$arg" in
        *generated*|*out*|*target*/*/build/*) return 0;;
      esac
      ;;
  esac
  return 1
}
for arg in "$@"; do
  normalized_arg="$(normalize_argument "$arg")"
  if matches_aws_lc_generated_path "$normalized_arg"; then
    matched_arg="$normalized_arg"
    break
  fi
done
if [ -n "${matched_arg:-}" ]; then
  echo "[CI-INFO-RUSTBUILD-0018] input=$matched_arg reason=\"generated header; distcc without pump\"" >&2
  if [ -n "${DISTCC_HOSTS_NO_PUMP:-}" ]; then
    env -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID DISTCC_HOSTS="$DISTCC_HOSTS_NO_PUMP" "$distcc_real" "$real_compiler" "$@"
    exit $?
  fi
  echo "[CI-INFO-RUSTBUILD-0019] reason=\"no non-pump distcc host; local compiler\"" >&2
  env -u DISTCC_HOSTS -u INCLUDE_SERVER_PORT -u INCLUDE_SERVER_PID -u DISTCC_FALLBACK "$local_compiler" "$@"
  exit $?
fi
exec "$distcc_real" "$real_compiler" "$@"
SH
}

# What: print the workspace members of a Cargo manifest.
# Why: one reader for rows, stubs and version-drift.
# From: Issue #1683 | PR #1858
_ci_cargo_members() {
    _ci_capture 0 yq -p toml -oy '.workspace.members[]' "$1"
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
        targets="$(_ci_capture 0 awk "$(cat <<'PROG'
/^\[\[bin\]\]/ { s = "bin"; next } /^\[lib\]/ { s = "lib"; next } /^\[/ { s = ""; next }
            s != "" && /^path *=/ { v = $0; sub(/^path *= *"/, "", v); sub(/".*$/, "", v); print s "\t" v }
PROG
            )" "${m}/Cargo.toml")" || return 2
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

# What: export each SOT compiler var as its driver name.
# Why: the masquerade dir on PATH then serves each one.
# From: Issue #1683 | PR #1858
_ci_rb_export_drivers() {
    local q
    while IFS= read -r q; do export "${q?}"; done <<< "${_CI_RB_PAIRS}"
}

# What: sccache on the runner's policy and dist config.
# Why: a running server never rereads SCCACHE_CONF.
# From: Issue #1683 | PR #1912
_ci_rb_sccache() {
    local service="$1" dist
    unset CARGO_MAKEFLAGS MAKEFLAGS
    # What: a builder stops without the runner's policy.
    # Why: the runner decides the chain once per run.
    # From: Issue #1683 | PR #1912
    if [ ! -s "$(_ci_secret_file sccache_policy)" ]; then
        ci_log "[CI-ERROR-RUSTBUILD-0050]" "service=\"${service}\" reason=\"sccache_policy secret missing; the runner decides the chain\""
        return 2
    fi
    dist="$(_ci_secret_file sccache_dist_config)"
    if [ -s "${dist}" ]; then export SCCACHE_CONF="${dist}"; fi
    _ci_sccache_env "${service}" "${_CI_RB_ACC}/rustc-wrapper" || return 2
    if [ -n "${SCCACHE_CONF:-}" ]; then
        _ci_run "[CI-ERROR-RUSTBUILD-0054]" "reason=\"sccache dist status failed\"" sccache --dist-status || return 2
    fi
}

# What: write the farm compiler identity of a probe .o.
# Why: ccache content-check misses a remote toolchain bump.
# From: Issue #1683 | PR #1912
_ci_rb_remote_toolchain_id() {
    local section
    rm -f "${_CI_RB_REMOTE_ID}"
    if _ci_command_available readelf; then
        if section="$(_ci_capture 0 readelf -p .comment "$1")"; then
            sed -n 's/^ *\[[^]]*\] *//p' <<<"${section}" > "${_CI_RB_REMOTE_ID}"
        fi
    fi
}

# What: split pump/non-pump hosts, set up distcc.
# Why: aws-lc-sys generated headers must bypass pump.
# From: Issue #1533 | PR #1912
_ci_rb_distcc() {
    local hosts_file masq="${_CI_RB_ACC}/masq"
    hosts_file="$(_ci_secret_file distcc_potential_hosts)"
    if [ -s "${hosts_file}" ]; then
        local distcc_probe_dir
        distcc_probe_dir="$(_ci_mktemp -d -p "${_CI_RB_ACC}")" || return 2
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
            ci_log "[CI-ERROR-RUSTBUILD-0021]" "reason=\"DISTCC_POTENTIAL_HOSTS has no usable host\""; return 1
        fi
        local distcc_pump_hosts="${distcc_hosts_with_pump:-}"
        distcc_hosts_without_pump="${distcc_hosts_without_pump:-${distcc_hosts}}"
        ci_log "[CI-INFO-RUSTBUILD-0022]" "hosts=\"${distcc_hosts}\" reason=\"distcc on\""
        export DISTCC_HOSTS_NO_PUMP="${distcc_hosts_without_pump}"
        export PATH="${masq}:${PATH}" DISTCC_FALLBACK=0
        _ci_rb_export_drivers
        _CI_RB_DISTCC=1
        if [ -n "${distcc_pump_hosts}" ]; then
            export DISTCC_POTENTIAL_HOSTS="${distcc_pump_hosts}"
            unset DISTCC_HOSTS
            local distcc_pump_env
            if ! distcc_pump_env="$(pump --startup 2>"${distcc_probe_dir}/distcc-pump.log")"; then
                ci_error "[CI-ERROR-RUSTBUILD-0023]" "reason=\"distcc pump unavailable; no fallback (AG-CI-007)\"" "$(cat "${distcc_probe_dir}/distcc-pump.log")"
                return 2
            fi
            eval "${distcc_pump_env}"
            local -a distcc_hosts_arr; read -ra distcc_hosts_arr <<<"${DISTCC_HOSTS:-}"
            local distcc_pump_real_hosts="" distcc_host_token
            for distcc_host_token in "${distcc_hosts_arr[@]}"; do case "${distcc_host_token}" in --*) ;; *) distcc_pump_real_hosts=1 ;; esac; done
            if [ -z "${distcc_pump_real_hosts}" ]; then unset DISTCC_HOSTS; fi
            PATH="${masq}:${PATH}"
            export PATH DISTCC_HOSTS_NO_PUMP
            _ci_rb_export_drivers
        else
            export DISTCC_HOSTS="${distcc_hosts}"
        fi
        _ci_rb_write "${distcc_probe_dir}/distcc-probe.c" printf '%s\n' 'int main(void) { return 0; }' || return 2
        if ! cc -c "${distcc_probe_dir}/distcc-probe.c" -o "${distcc_probe_dir}/distcc-probe.o" >"${distcc_probe_dir}/distcc-probe.log" 2>&1; then
            ci_error "[CI-ERROR-RUSTBUILD-0024]" "reason=\"distcc probe failed; no fallback (AG-CI-007)\"" "$(cat "${distcc_probe_dir}/distcc-probe.log")"
            return 2
        fi
        _ci_rb_remote_toolchain_id "${distcc_probe_dir}/distcc-probe.o"
    else
        ci_log "[CI-INFO-RUSTBUILD-0025]" "reason=\"distcc off; no distcc_potential_hosts secret\""
    fi
}

# What: wrap distcc with ccache (Redis) once distcc is up.
# Why: content-check + remote id guard a stale toolchain.
# From: Issue #1683 | PR #1912
_ci_rb_ccache() {
    local url_file local_id="${_CI_RB_ACC}/ccache-toolchain-id"
    url_file="$(_ci_secret_file ccache_redis_url)"
    if [ "${_CI_RB_DISTCC}" = "1" ] && [ -s "${url_file}" ]; then
        if [ ! -s "${_CI_RB_REMOTE_ID}" ]; then
            ci_log "[CI-INFO-RUSTBUILD-0026]" "reason=\"ccache off; no remote distcc toolchain identity\""; return 0
        fi
        local ccache_probe_dir
        ccache_probe_dir="$(_ci_mktemp -d -p "${_CI_RB_ACC}")" || return 2
        ci_log "[CI-INFO-RUSTBUILD-0027]" "reason=\"ccache on over distcc with redis storage\""
        local ccache_redis_endpoint
        ccache_redis_endpoint="$(cat "${url_file}")"
        case "${ccache_redis_endpoint}" in
            redis://*|redis+unix:*) ;;
            *) ccache_redis_endpoint="redis://${ccache_redis_endpoint}" ;;
        esac
        export CCACHE_REMOTE_STORAGE="${ccache_redis_endpoint}"
        export CCACHE_DIR="${_CI_RB_ACC}/ccache"
        export CCACHE_PREFIX=distcc
        export CCACHE_COMPILERCHECK=content
        local tc_id="${!CI_ARG_TOOLCHAIN_IMAGE:-}"
        if [ -z "${tc_id}" ]; then
            ci_log "[CI-ERROR-RUSTBUILD-0067]" "name=\"${CI_ARG_TOOLCHAIN_IMAGE}\" reason=\"empty toolchain identity; the ccache key would miss a toolchain bump\""
            return 2
        fi
        _ci_rb_write "${local_id}" printf '%s' "${tc_id}" || return 2
        export CCACHE_EXTRAFILES="${local_id}:${_CI_RB_REMOTE_ID}"
        export CCACHE_BASEDIR="${ccache_probe_dir}"
        local k
        for k in "${!_CI_RB_DRIVER_PATH[@]}"; do export "${k}=ccache ${_CI_RB_DRIVER_PATH[${k}]}"; done
        _CI_RB_CCACHE=1
        _ci_rb_write "${ccache_probe_dir}/ccache-probe.c" printf '%s\n' 'int main(void) { return 0; }' || return 2
        # What: the probe compiles and counts in its dir.
        # Why: keep real cache clean; its stats live there.
        # From: Issue #1683 | PR #1912
        local ccache_probe_cache_dir="${ccache_probe_dir}/probe-cache"
        _ci_run "[CI-ERROR-RUSTBUILD-0065]" "dir=\"${ccache_probe_cache_dir}\" reason=\"ccache probe dir not created\"" mkdir -p "${ccache_probe_cache_dir}" || return 2
        if ! ( cd "${ccache_probe_dir}" && CCACHE_DIR="${ccache_probe_cache_dir}" ccache "${_CI_RB_DRIVER_PATH[${_CI_RB_PAIRS%%=*}]}" -c ccache-probe.c -o ccache-probe.o ) >"${ccache_probe_dir}/ccache-probe.log" 2>&1; then
            ci_error "[CI-ERROR-RUSTBUILD-0028]" "reason=\"ccache probe failed; no fallback (AG-CI-007)\"" "$(cat "${ccache_probe_dir}/ccache-probe.log")"
            return 2
        fi
        local stats stat_err stat_ok
        stats="$(CCACHE_DIR="${ccache_probe_cache_dir}" _ci_run "[CI-ERROR-RUSTBUILD-0057]" "reason=\"ccache probe stats not readable\"" ccache --print-stats)" || return 2
        stat_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' <<< "${stats}")" || return 2
        stat_ok="$(_ci_capture 1 grep -E '^remote_storage_(write|hit)[[:space:]]+[1-9]' <<< "${stats}")" || return 2
        if [ -n "${stat_err}" ] || [ -z "${stat_ok}" ]; then
            ci_error "[CI-ERROR-RUSTBUILD-0029]" "reason=\"ccache redis round trip failed; no fallback (AG-CI-007)\"" "${stats}"
            return 2
        fi
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
# From: Issue #1683 | PR #1858
_ci_rb_cargo_profile() {
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
# From: Issue #1683 | PR #1858
_ci_rb_cargo_jobs() {
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

# What: write one rust-build helper file from a command.
# Why: a lost write must fail with the file, not silently.
# From: Issue #1683 | PR #1912
_ci_rb_write() {
    local file="$1"
    shift
    "$@" > "${file}" && return 0
    ci_log "[CI-ERROR-RUSTBUILD-0055]" "file=\"${file}\" cmd=\"$1\" reason=\"rust-build helper file not written\""
    return 2
}

# What: In-image rust builder; sccache, opt-in distcc.
# Why: one owner for every rust builder stage.
# From: Issue #1683 | PR #1912
ci_cmd_rust_build() {
    local service="${1:-}" crates="${2:-}" mode="${3:-build}" crate
    local -a cl=()
    [ -n "${service}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${crates}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0002]" "reason=\"crates arg required\""; return 2; }
    # What: the crates arg is a space-separated list.
    # Why: read -a splits words without glob expansion.
    # From: Issue #1683 | PR #1912
    read -ra cl <<< "${crates}"
    # What: mode build (real+cp) or deps (pre-cache, no cp).
    # Why: services with stub-src dep-cache stage call deps.
    # From: Issue #1683 | PR #1858
    case "${mode}" in build|deps) ;; *) ci_log "[CI-ERROR-RUSTBUILD-0005]" "mode=\"${mode}\" reason=\"mode must be build or deps\""; return 2 ;; esac
    local musl_target="${!CI_ARG_TARGET:-}"
    [ -n "${musl_target}" ] || { ci_log "[CI-ERROR-RUSTBUILD-0003]" "arg=\"${CI_ARG_TARGET}\" reason=\"build arg env required\""; return 2; }
    # What: the target must be the build-tools rustc host.
    # Why: apk Rust has no rustup; host std is the only one.
    # From: Issue #1683 | PR #1858
    local rustc_info
    rustc_info="$(rustc -vV)" || { ci_log "[CI-ERROR-RUSTBUILD-0004]" "reason=\"rustc -vV failed in build-tools\""; return 2; }
    _ci_list_has "host: ${musl_target}" "${rustc_info}" || { ci_error "[CI-ERROR-RUSTBUILD-0006]" "target=\"${musl_target}\" arg=\"${CI_ARG_TARGET}\" reason=\"target is not the build-tools rustc host\"" "${rustc_info}"; return 2; }
    local masq p distcc_bin sccache_bin
    local -a drivers=()
    _CI_RB_DISTCC=0 _CI_RB_CCACHE=0 _CI_RB_CA=0
    _CI_RB_DRIVER_PATH=()
    trap _ci_rust_build_cleanup EXIT
    _CI_RB_ACC="$(_ci_mktemp -d -p "${CI_TMPDIR}")" || return 2
    masq="${_CI_RB_ACC}/masq" _CI_RB_REMOTE_ID="${_CI_RB_ACC}/ccache-remote-toolchain-id"
    _ci_run "[CI-ERROR-RUSTBUILD-0056]" "dir=\"${masq}\" reason=\"masquerade dir not created\"" mkdir -p "${masq}" || return 2
    _CI_RB_PAIRS="$(_ci_build_tools_compilers)" || return 2
    # What: resolve the real tools before any masquerade.
    # Why: wrapper and ccache call the real compiler paths.
    # From: Issue #1683 | PR #1858
    while IFS= read -r p; do
        if ! _CI_RB_DRIVER_PATH["${p%%=*}"]="$(_ci_command_path "${p#*=}")"; then
            ci_error "[CI-ERROR-RUSTBUILD-0046]" "driver=\"${p#*=}\" reason=\"compiler driver not on PATH\"" "PATH=${PATH}"
            return 2
        fi
        drivers+=("${p#*=}=${_CI_RB_DRIVER_PATH[${p%%=*}]}")
    done <<< "${_CI_RB_PAIRS}"
    distcc_bin="$(_ci_command_path distcc)" || { ci_error "[CI-ERROR-RUSTBUILD-0047]" "reason=\"distcc not on PATH\"" "PATH=${PATH}"; return 2; }
    sccache_bin="$(_ci_command_path sccache)" || { ci_error "[CI-ERROR-RUSTBUILD-0048]" "reason=\"sccache not on PATH\"" "PATH=${PATH}"; return 2; }
    # What: masq links each driver and distcc to the wrapper
    # Why: masq is on PATH only while distcc is on.
    # From: Issue #1533 | PR #1912
    _ci_rb_write "${_CI_RB_ACC}/distcc-wrapper" _ci_rust_distcc_wrapper "${distcc_bin}" "${_CI_RB_ACC}/distcc-wrapper" "${masq}" "${drivers[@]}" || return 2
    _ci_run "[CI-ERROR-RUSTBUILD-0061]" "reason=\"distcc wrapper not made executable\"" chmod +x "${_CI_RB_ACC}/distcc-wrapper" || return 2
    for p in "${drivers[@]%%=*}" distcc; do
        _ci_run "[CI-ERROR-RUSTBUILD-0062]" "link=\"${masq}/${p}\" reason=\"masquerade link not created\"" ln -sf "${_CI_RB_ACC}/distcc-wrapper" "${masq}/${p}" || return 2
    done
    # What: rustc wrapper: distcc passthrough, else sccache.
    # Why: a distcc call must never pass through sccache.
    # From: Issue #1683 | PR #1912
    _ci_rb_write "${_CI_RB_ACC}/rustc-wrapper" printf '%s\n' '#!/bin/sh' "case \"\${1:-}\" in" '  distcc|*/distcc) exec "$@" ;;' "  *) exec \"${sccache_bin}\" \"\$@\" ;;" 'esac' || return 2
    _ci_run "[CI-ERROR-RUSTBUILD-0063]" "reason=\"rustc wrapper not made executable\"" chmod +x "${_CI_RB_ACC}/rustc-wrapper" || return 2
    # What: trust proxy CA for cargo's crates.io fetch.
    # Why: cleanup trap removes it; never persisted.
    # From: Issue #1683 | PR #1912
    local ca_src
    ca_src="$(_ci_secret_file project_selfhosted_proxy_ca)"
    if [ -s "${ca_src}" ]; then
        _ci_run "[CI-ERROR-RUSTBUILD-0064]" "reason=\"proxy CA not copied to the trust dir\"" cp "${ca_src}" "${_CI_RB_CA_FILE}" || return 2
        _CI_RB_CA=1
        _ci_run "[CI-ERROR-RUSTBUILD-0058]" "reason=\"proxy CA not added to the trust store\"" update-ca-certificates || return 2
    fi
    # What: an accelerator that fails stops the build.
    # Why: AG-CI-007: a cache level has no silent fallback.
    # From: Issue #1683 | PR #1858
    _ci_rb_sccache "${service}" || return 2
    _ci_rb_distcc || return 2
    _ci_rb_ccache || return 2
    # What: cargo home from the SOT, the cache mount root.
    # Why: §39: registry and git caches live in the mounts.
    # From: Issue #1683 | PR #1912
    CARGO_HOME="$(_ci_variable CI_CARGO_HOME)" || return 2
    export CARGO_HOME
    _ci_rb_cargo_profile || return 2
    local cargo_jobs
    cargo_jobs="$(_ci_rb_cargo_jobs)" || return 2
    # What: drop each crate's stale artifact first.
    # Why: dep pre-cache stub rlib outdates COPYed src.
    # From: Issue #1683 | PR #1858
    if [ "${mode}" = "build" ]; then
        for crate in "${cl[@]}"; do
            _ci_run "[CI-ERROR-RUSTBUILD-0059]" "crate=\"${crate}\" reason=\"cargo clean failed\"" \
                cargo clean -p "${crate}" --release --target "${musl_target}" || return 2
        done
    fi
    local stubs s brc=0
    stubs="$(_ci_rust_member_stubs)" || return 2
    _ci_rust_cargo_build "${crates}" "${musl_target}" "${cargo_jobs}" || brc=$?
    # What: remove exactly the stub files this run created.
    # Why: a stub left behind would ship in the real build.
    # From: Issue #1683 | PR #1858
    while IFS= read -r s; do
        [ -z "${s}" ] || _ci_run "[CI-ERROR-RUSTBUILD-0044]" "file=\"${s}\" reason=\"stub not removed\"" rm -f -- "${s}" || return 2
    done <<< "${stubs}"
    [ "${brc}" -eq 0 ] || return 2
    # What: show ccache stats; a Redis error fails.
    # Why: AG-CI-007: a dead cache level must not pass.
    # From: Issue #1683 | PR #1912
    if [ "${_CI_RB_CCACHE}" = 1 ]; then
        local stats final_err
        stats="$(_ci_run "[CI-ERROR-RUSTBUILD-0066]" "reason=\"ccache build stats not readable\"" ccache --print-stats)" || return 2
        printf '%s\n' "${stats}"
        final_err="$(_ci_capture 1 grep -E '^remote_storage_error[[:space:]]+[1-9]' <<< "${stats}")" || return 2
        if [ -n "${final_err}" ]; then
            ci_error "[CI-ERROR-RUSTBUILD-0041]" "reason=\"ccache redis error during the build\"" "${stats}"
            return 2
        fi
    fi
    # What: copy each binary to <crate>-out in the WORKDIR.
    # Why: the final stage COPYs it; deps builds ship none.
    # From: Issue #1683 | PR #1912
    if [ "${mode}" = "build" ]; then
        for crate in "${cl[@]}"; do
            _ci_run "[CI-ERROR-RUSTBUILD-0060]" "crate=\"${crate}\" reason=\"built binary not copied out\"" \
                cp "target/${musl_target}/release/${crate}" "${PWD}/${crate}-out" || return 2
        done
    fi
}

# What: a ref's digest, revision or raw index; 1 = absent
# Why: one reader; transient retries; callers own the id.
# From: Issue #1683 | PR #1858
_ci_registry_read() {
    local ref="$1" view="$2" id="$3" absent="$4" out cls rc=0
    local -a how=(--raw)
    case "${view}" in
        digest) how=(--format '{{.Manifest.Digest}}') ;;
        revision) how=(--format '{{index .Image.Config.Labels "org.opencontainers.image.revision"}}') ;;
    esac
    out="$(_ci_retry registry-read docker buildx imagetools inspect "${ref}" "${how[@]}")" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        if [ "${view}" = raw ]; then
            printf '%s\n' "${out}"
            return 0
        fi
        # What: the revision label names the build commit.
        # Why: §28: an index stays under its build commit.
        # From: Issue #1683 | PR #1858
        if [ "${view}" = revision ]; then
            if [[ "${out}" =~ ^[0-9a-f]{40}$ ]]; then
                printf '%s\n' "${out}"
                return 0
            fi
            ci_error "${id}" "ref=\"${ref}\" reason=\"image has no full 40-hex revision label\"" "${out}"
            return 2
        fi
        # What: the value is the one digest line read.
        # Why: buildx warns on stderr for cache manifests.
        # From: Issue #1683 | PR #1858
        local dig
        dig="$(_ci_capture 1 grep -xE -- "${CI_DIGEST_RE}" <<< "${out}")" || return 2
        if [[ "${dig}" =~ ^${CI_DIGEST_RE}$ ]]; then
            [ "${dig}" = "${out}" ] || printf '%s\n' "${out}" >&2
            printf '%s\n' "${dig}"
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

# What: Push a tag; the push digest must match the registry.
# Why: a mismatch is no accepted image (convergence L5).
# From: Issue #1683 | PR #1912
_ci_docker_publish() {
    local service="$1" identity="$2" platform="$3" tag out pushed seen line
    tag="$(_ci_image_tag "${service}" "${platform}" "${identity}")" || return 2
    out="$(_ci_retry registry docker push "${tag}")" || return "$?"
    pushed=""
    while IFS= read -r line; do
        if [[ "${line}" =~ :\ digest:\ (sha256:[0-9a-f]{64})\ size:\  ]]; then pushed="${BASH_REMATCH[1]}"; fi
    done <<< "${out}"
    seen="$(_ci_registry_digest "${tag}")" || return "$?"
    if [ -z "${pushed}" ] || [ "${pushed}" != "${seen}" ]; then
        ci_error "[CI-ERROR-PUBLISH-0006]" "service=\"${service}\" platform=\"${platform}\" pushed=\"${pushed:-none}\" registry=\"${seen}\" reason=\"push digest and registry digest differ\"" "${out}"
        return 2
    fi
    printf '%s\n' "${seen}"
}

# What: platform_arch key of the machine this runs on.
# Why: an external binary must fit the host, not the image.
# From: Issue #1683
_ci_host_arch() {
    local machine key keys apk
    machine="$(_ci_capture 0 uname -m)" || return 2
    keys="$(_ci_block_keys platform_arch)" || return 2
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        apk="$(_ci_block_entry_field platform_arch "${key}" apk)" || return 2
        if [ "${apk}" = "${machine}" ]; then
            printf '%s\n' "${key}"
            return 0
        fi
    done <<< "${keys}"
    ci_log "[CI-ERROR-SCAN-0036]" "machine=\"${machine}\" reason=\"no platform_arch apk value matches this host\""
    return 2
}

# What: Fetch the latest trivy once per tag; print path.
# Why: AG-VAL-017: trivy is external; the SOT names it.
# From: Issue #1683
_ci_trivy_bin() {
    local dir bin err arch rel tag asset sha url
    arch="$(_ci_host_arch)" || return 2
    rel="$(_ci_tool_latest "trivy-${arch}")" || return 2
    IFS=$'\t' read -r tag asset url sha <<< "${rel}"
    # What: the kept binary is the one of the latest tag.
    # Why: a kept older trivy must not stand in for latest.
    # From: Issue #1683 | PR #1858
    dir="${CI_TMPDIR}/trivy-${tag}"
    bin="${dir}/trivy"
    if [ -x "${bin}" ]; then
        printf '%s\n' "${bin}"
        return 0
    fi
    if ! err="$(mkdir -p "${dir}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0038]" "dir=\"${dir}\" reason=\"trivy dir not created\"" "${err}"
        return 2
    fi
    _ci_fetch_verified "${url}" "${sha}" "${dir}/${asset}" || return 2
    if ! err="$(tar --no-same-owner -xzf "${dir}/${asset}" -C "${dir}" trivy 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0039]" "asset=\"${asset}\" reason=\"trivy extract failed\"" "${err}"
        return 2
    fi
    if [ ! -x "${bin}" ]; then
        ci_log "[CI-ERROR-SCAN-0040]" "asset=\"${asset}\" reason=\"archive has no executable trivy\""
        return 2
    fi
    printf '%s\n' "${bin}"
}

# What: the trivy exit code that means findings.
# Why: trivy's own errors exit 1; a finding must differ.
# From: Issue #1683 | PR #1912
_CI_TRIVY_FINDING_RC=5

# What: one trivy run; exit 0 clean, findings keep a report.
# Why: a clean summary is no finding; an error no verdict.
# From: Issue #1683 | PR #1912
_ci_trivy_scan_once() {
    local report="$1" ref="$2" rc=0
    shift 2
    : > "${report}"
    "$@" --output "${report}" "${ref}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        : > "${report}"
        return 0
    fi
    [ "${rc}" -eq "${_CI_TRIVY_FINDING_RC}" ] && [ -s "${report}" ]
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

# What: the Trivy DB dir inside the job container.
# Why: nothing writes on the runner; never tmpfs /tmp.
# From: Issue #1683 | PR #1858
_ci_trivy_cache_dir() {
    local dir="${CI_TMPDIR}/trivy-cache" probe_out mkerr
    case "${dir}" in
        /tmp|/tmp/*) ci_log "[CI-ERROR-SCAN-0018]" "reason=\"trivy cache-dir must not be tmpfs /tmp\" got=\"${dir}\""; return 2 ;;
    esac
    if ! mkerr="$(mkdir -p "${dir}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0009]" "dir=\"${dir}\" reason=\"could not create the trivy cache-dir\"" "${mkerr}"
        return 2
    fi
    if ! probe_out="$(_ci_trivy_dir_writable "${dir}")"; then
        ci_error "[CI-ERROR-SCAN-0019]" "dir=\"${dir}\" reason=\"trivy cache-dir failed write probe\"" "${probe_out}"
        return 2
    fi
    printf '%s\n' "${dir}"
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

# What: flock around a Trivy DB cache-dir write.
# Why: the kernel frees a dead holder's lock; no age rule.
# From: Issue #1683 | PR #1912
_ci_trivy_db_lock_run() {
    local cache_dir="$1"; shift
    [ "${1:-}" = "--" ] && shift
    local lock_file="${cache_dir}/.trivy-db-update.flock" fd err rc=0
    # What: cache-dir must exist before the lock file.
    # Why: a missing parent must not misread as "locked".
    # From: Issue #1683
    if ! err="$(mkdir -p "${cache_dir}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0013]" "dir=\"${cache_dir}\" reason=\"could not create cache-dir for lock\"" "${err}"
        return 2
    fi
    if ! err="$(touch -- "${lock_file}" 2>&1)"; then
        ci_error "[CI-ERROR-SCAN-0014]" "lock=\"${lock_file}\" reason=\"lock file not created\"" "${err}"
        return 2
    fi
    exec {fd}>>"${lock_file}"
    # What: blocks until the holder releases or exits.
    # Why: the wait follows the holder, never a clock.
    # From: Issue #1683 | PR #1912
    if ! err="$(flock "${fd}" 2>&1)"; then
        exec {fd}>&-
        ci_error "[CI-ERROR-SCAN-0011]" "lock=\"${lock_file}\" reason=\"flock on the trivy DB lock failed\"" "${err}"
        return 2
    fi
    "$@" || rc=$?
    exec {fd}>&-
    return "${rc}"
}

# What: trivy's own DB refresh, retried when transient.
# Why: the shared retry owner; rc 6 names a DB outage.
# From: Issue #1683
_ci_trivy_db_download() {
    local rc=0 bin
    bin="$(_ci_trivy_bin)" || return 2
    _ci_retry trivy "${bin}" image --download-db-only --cache-dir "$1" || rc=$?
    [ "${rc}" -eq 0 ] || return 6
}

# What: Refresh cache-dir's Trivy DB right before the gate.
# Why: AG-VAL-026: trivy's own check runs on every scan.
# From: Issue #1683
_ci_trivy_db_ensure_fresh() {
    local cache_dir="$1" rc=0
    _ci_trivy_db_lock_run "${cache_dir}" -- _ci_trivy_db_download "${cache_dir}" || rc=$?
    case "${rc}" in
        0) ;;
        6) ci_log "[CI-ERROR-SCAN-0034]" "dir=\"${cache_dir}\" reason=\"trivy DB refresh failed; no scan without a fresh DB\""; return 6 ;;
        *) ci_log "[CI-ERROR-SCAN-0012]" "reason=\"locked DB refresh failed; refusing an unlocked concurrent write\""; return 2 ;;
    esac
    if ! _ci_trivy_db_fresh "${cache_dir}"; then
        ci_log "[CI-ERROR-SCAN-0035]" "dir=\"${cache_dir}\" reason=\"trivy DB is not fresh after its refresh\""
        return 6
    fi
}

# What: print the DB identity: version, update time, sha256.
# Why: AG-VAL-026: a gate result names the exact DB it used.
# From: Issue #1683
_ci_trivy_db_record() {
    local cache_dir="$1" meta ver upd sum
    meta="${cache_dir}/db/metadata.json"
    ver="$(_ci_capture 0 jq -r '.Version // empty' "${meta}")" || return 2
    upd="$(_ci_capture 0 jq -r '.UpdatedAt // empty' "${meta}")" || return 2
    sum="$(_ci_sha256_hex < "${cache_dir}/db/trivy.db")" || return 2
    if [ -z "${ver}" ] || [ -z "${upd}" ] || [ -z "${sum}" ]; then
        ci_error "[CI-ERROR-SCAN-0033]" "dir=\"${cache_dir}\" reason=\"trivy DB identity incomplete\"" ""
        return 2
    fi
    printf 'trivy-db version=%s updated_at=%s sha256=%s\n' "${ver}" "${upd}" "${sum}"
}

# What: trivy image argv for one scan, one item per line
# Why: one owner; a test runs it through the real trivy
# From: Issue #1683 | PR #1858
_ci_trivy_args() {
    local cache_dir="$1" scanners severity scan_timeout ignore bin
    bin="$(_ci_trivy_bin)" || return 2
    scanners="$(_ci_variable CI_TRIVY_SCANNERS)" || return 2
    severity="$(_ci_variable CI_TRIVY_SEVERITY)" || return 2
    scan_timeout="$(_ci_variable CI_TRIVY_TIMEOUT)" || return 2
    ignore="$(_ci_repo_path CI_TRIVY_IGNORE)" || return 2
    printf '%s\n' "${bin}" image --severity "${severity}" --exit-code "${_CI_TRIVY_FINDING_RC}" \
        --scanners "${scanners}" --timeout "${scan_timeout}" --cache-dir "${cache_dir}" --skip-db-update
    [ ! -f "${ignore}" ] || printf '%s\n' --ignorefile "${ignore}"
}

# What: file name of the ignore ids a full run matched
# Why: writer and reader share one name
# From: Issue #1683 | PR #1912
_CI_TRIVY_MATCHED=trivy-ignore-matched.txt

# What: append the ids the ignore file hid in one image
# Why: an id never hidden is stale; trivy lists the hidden
# From: Issue #1683 | PR #1912
_ci_trivy_suppressed_ids() {
    local ref="$1" json ids rc=0
    shift
    json="$(_ci_mktemp "${CI_TMPDIR}/ci-trivy-sup.XXXXXX")" || return 2
    "$@" --exit-code 0 --show-suppressed --format json --output "${json}" "${ref}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${json}"
        return "${rc}"
    fi
    ids="$(_ci_capture 0 jq -r '[.Results[]? | .ExperimentalModifiedFindings[]?
        | select(.Status == "ignored") | .Finding.VulnerabilityID] | unique[]' "${json}")" || return 2
    rm -f "${json}"
    [ -z "${ids}" ] || printf '%s\n' "${ids}" >> "${CI_TMPDIR}/${_CI_TRIVY_MATCHED}"
}

# What: Scan a digest; rc 1 finding, 2 setup, 4 run, 6 DB
# Why: a failed run or setup is never read as a finding
# From: Issue #1683 | PR #1858
_ci_trivy_scan() {
    local service="$1" digest="$2" ref report rc=0 out
    local cache_dir fresh_rc=0
    local -a targs
    cache_dir="$(_ci_trivy_cache_dir)" || return 2
    out="$(_ci_trivy_args "${cache_dir}")" || return 2
    _ci_trivy_db_ensure_fresh "${cache_dir}" || fresh_rc=$?
    [ "${fresh_rc}" -eq 0 ] || return "${fresh_rc}"
    _ci_trivy_db_record "${cache_dir}" || return 2
    ref="$(_ci_image_ref "${service}" "${digest}")" || return 2
    mapfile -t targs <<< "${out}"
    report="$(_ci_mktemp "${CI_TMPDIR}/ci-trivy.XXXXXX")" || return 2
    _ci_retry trivy _ci_trivy_scan_once "${report}" "${ref}" "${targs[@]}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${report}"
        # What: a failed run, no fresh DB: a DB outage.
        # Why: the status kind names the cause, not a guess.
        # From: Issue #1683 | PR #1912
        _ci_trivy_db_fresh "${cache_dir}" || return 6
        return 4
    fi
    # What: a full run also records which ignores matched.
    # Why: the stale-entry gate reads them after all pairs.
    # From: Issue #1683 | PR #1912
    if [ "${CI_SCAN_FULL:-}" = 1 ]; then
        _ci_retry trivy _ci_trivy_suppressed_ids "${ref}" "${targs[@]}" || { rm -f "${report}"; return 4; }
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

# What: rc 0 when this run is a controlled refresh (§17).
# Why: one owner; the SOT names the events, not ci.sh.
# From: Issue #1683 | PR #1912
_ci_refresh_event() {
    local events event="${GITHUB_EVENT_NAME:-}"
    [ -n "${event}" ] || return 1
    # What: a release run never refreshes packages.
    # Why: §82: release.yml never builds; ids stay fixed.
    # From: Issue #1683 | PR #1858
    [ -z "${CI_RELEASE_TAG:-}" ] || return 1
    events="$(_ci_required_field build_admission refresh_events blocklist)" || return 2
    _ci_list_has "${event}" "${events}" || return 1
}

# What: a pair's refresh value, or none; 2 unknown.
# Why: §17: the last refresh run's result, never re-read.
# From: Issue #1683 | PR #1858
_ci_package_refresh_value() {
    local key="$1@$2" remote blob rc=0 k v
    remote="$(_ci_git_remote)" || return 2
    blob="$(_ci_ledger_blob "${remote}" CI_REFRESH_REF CI_REFRESH_FILE)" || rc=$?
    case "${rc}" in
        0)
            while IFS=$'\t' read -r k v; do
                if [ "${k}" = "${key}" ]; then printf '%s\n' "${v}"; return 0; fi
            done <<< "${blob}"
            ;;
        1) ;;
        *) return 2 ;;
    esac
    printf 'none\n'
}

# What: record each pair whose accepted image is behind.
# Why: §17: one write; the new value changes the pair id.
# From: Issue #1683 | PR #1858
_ci_package_refresh_all() {
    local _ci_plan_ids="" _ci_refresh_new="" remote rc=0
    _ci_for_all_pairs _ci_package_refresh_pair || return "$?"
    [ -n "${_ci_refresh_new}" ] || return 0
    remote="$(_ci_git_remote)" || return 2
    printf '%s' "${_ci_refresh_new}" | _ci_ledger_upsert "${remote}" CI_REFRESH_REF CI_REFRESH_FILE replace || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-REFRESH-0004]" "rc=${rc} reason=\"refresh records not written (raw above); no build on a stale id\""
        return 2
    fi
}

# What: check one pair's accepted image against the index.
# Why: writes the caller's record list (dynamic scope).
# From: Issue #1683 | PR #1858
_ci_package_refresh_pair() {
    local service="$1" platform="$2" id remote lrec rc=0 ref outdated value type entry
    # What: keep the pair's toolchain packages as a record.
    # Why: a later plan reads it; no build-tools pull there.
    # From: Issue #1683 | PR #1858
    type="$(_ci_required_field "${service}" build_type)" || return 2
    value="$(_ci_block_entry_list build_identity "${type}" toolchain_packages)" || return 2
    if [ -n "${value}" ]; then
        entry="$(_ci_toolchain_entry "${type}" "${platform}")" || return 2
        [[ $'\n'"${_ci_refresh_new}" == *$'\n'"${entry}"$'\n'* ]] || _ci_refresh_new+="${entry}"$'\n'
    fi
    _ci_plan_record "${service}" "${platform}" || return "$?"
    id="$(_ci_identity_for "${service}" "${platform}")" || return "$?"
    remote="$(_ci_git_remote)" || return 2
    lrec="$(_ci_ledger_read "${remote}" "${id}")" || rc=$?
    # What: no record: the plan builds the pair anyway.
    # Why: only an accepted image can be behind the index.
    # From: Issue #1683 | PR #1858
    [ "${rc}" -ne 1 ] || return 0
    [ "${rc}" -eq 0 ] || return 2
    [ "${lrec%%$'\t'*}" = ACCEPTED ] || return 0
    ref="$(_ci_image_ref "${service}" "${lrec#*$'\t'}")" || return 2
    outdated="$(_ci_with_workdir ci-apk _ci_apk_outdated "${ref}" "${platform}")" || return 2
    if [ -z "${outdated}" ]; then
        ci_log "[CI-INFO-REFRESH-0005]" "service=\"${service}\" platform=\"${platform}\" image=\"${ref}\" reason=\"apk packages match the index; reuse\""
        return 0
    fi
    value="$(printf '%s\n' "${outdated}" | _ci_sha256_hex)" || return 2
    ci_error "[CI-INFO-REFRESH-0001]" "service=\"${service}\" platform=\"${platform}\" image=\"${ref}\" value=\"${value}\" reason=\"the index has newer apk packages; new id, rebuild\"" "${outdated}"
    _ci_refresh_new+="${service}@${platform}"$'\t'"${value}"$'\n'
}

# What: copy files $4.. of image $1 ($2) into dir $3.
# Why: create and cp read the image; it never runs here.
# From: Issue #1683 | PR #1858
_ci_image_files() {
    local ref="$1" platform="$2" work="$3" cid f out kids kid rc=0
    shift 3
    # What: an index digest is read as its platform child.
    # Why: one daemon keeps one platform per index digest.
    # From: Issue #1683 | PR #1858
    kids="$(_ci_index_children "${ref}")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    while IFS= read -r kid; do
        [ "${kid%%=*}" != "${platform}" ] || ref="${ref%@*}@${kid#*=}"
    done <<< "${kids}"
    rc=0
    _ci_retry registry docker pull --platform "${platform}" "${ref}" >&2 || return 2
    cid="$(_ci_capture 0 docker create --platform "${platform}" --entrypoint /bin/true "${ref}")" || return 2
    for f in "$@"; do
        if ! out="$(docker cp "${cid}:${f}" "${work}/${f##*/}" 2>&1)"; then
            ci_error "[CI-ERROR-REFRESH-0002]" "image=\"${ref}\" file=\"${f}\" reason=\"file not read from the image\"" "${out}"
            rc=2
            break
        fi
    done
    _ci_capture 0 docker rm "${cid}" >&2 || rc=2
    return "${rc}"
}

# What: "key<TAB>digest name=version ..." of a toolchain.
# Why: memo, refresh record and id read one value (§17).
# From: Issue #1683 | PR #1858
_ci_toolchain_entry() {
    local build_type="$1" platform="$2" roots tref key memo val="" remote blob rc=0 k v
    roots="$(_ci_block_entry_list build_identity "${build_type}" toolchain_packages)" || return 2
    if [ -z "${roots}" ]; then
        ci_log "[CI-ERROR-IDENTITY-0019]" "build_type=\"${build_type}\" reason=\"no SOT toolchain_packages; FAIL CLOSED\""
        return 2
    fi
    tref="$(_ci_build_tools_run_image)" || return 2
    key="toolchain@${platform}@${roots//$'\n'/,}"
    memo="$(_ci_sha256_hex <<< "${key}@${tref##*@}")" || return 2
    memo="toolchain-${memo}"
    if val="$(_ci_job_memo_get "${memo}")"; then
        printf '%s\t%s\n' "${key}" "${val}"
        return 0
    fi
    # What: the record counts only for this run's image.
    # Why: one record per platform; a new image replaces it.
    # From: Issue #1683 | PR #1858
    remote="$(_ci_git_remote)" || return 2
    blob="$(_ci_ledger_blob "${remote}" CI_REFRESH_REF CI_REFRESH_FILE)" || rc=$?
    case "${rc}" in
        0)
            while IFS=$'\t' read -r k v; do
                [ "${k}" != "${key}" ] || [ "${v%% *}" != "${tref##*@}" ] || val="${v}"
            done <<< "${blob}"
            ;;
        1) ;;
        *) return 2 ;;
    esac
    if [ -z "${val}" ]; then
        val="$(_ci_with_workdir ci-toolchain _ci_toolchain_closure "${tref}" "${platform}" "${roots}")" || return 2
        val="${tref##*@} ${val//$'\n'/ }"
        ci_log "[CI-INFO-IDENTITY-0021]" "key=\"${key}\" value=\"${val}\" reason=\"read from the image; no record for it\""
    fi
    _ci_job_memo_put "${memo}" "${val}" || return 2
    printf '%s\t%s\n' "${key}" "${val}"
}

# What: P: name and V: version of an apk db record.
# Why: one reader; each program defines pv(name, version).
# From: Issue #1683 | PR #1858
_CI_AWK_APK_PV="$(cat <<'PROG'
/^P:/ { p = substr($0, 3); next }
/^V:/ { pv(p, substr($0, 3)); next }
PROG
)"
readonly _CI_AWK_APK_PV

# What: apk packages reached from roots in an installed db.
# Why: a D: entry names a package, a p: provide or a file.
# From: Issue #1683 | PR #1858
_CI_AWK_APK_CLOSURE="${_CI_AWK_APK_PV}"$'\n'"$(cat <<'PROG'
function pv(n, v) { pkg[n] = 1; ver[n] = v }
function bare(t) { sub(/[<>=~].*$/, "", t); return t }
/^D:/ { dep[p] = substr($0, 3); next }
/^p:/ { k = split(substr($0, 3), a, " "); for (i = 1; i <= k; i++) own[bare(a[i])] = p; next }
/^F:/ { dir = substr($0, 3); next }
/^R:/ { own["/" dir "/" substr($0, 3)] = p; next }
END {
    qn = split(roots, q, " ")
    for (h = 1; h <= qn; h++) {
        t = q[h]
        if (t in pkg) i = t
        else if (t in own) i = own[t]
        else { print "unresolved: " t; bad = 1; continue }
        if (i in sel) continue
        sel[i] = 1
        k = split(dep[i], a, " ")
        for (j = 1; j <= k; j++) if (a[j] !~ /^!/) q[++qn] = bare(a[j])
    }
    if (bad) exit 2
    for (i in sel) print i "=" ver[i]
}
PROG
)"
readonly _CI_AWK_APK_CLOSURE

# What: sorted name=version of roots $3 in image $1 ($2).
# Why: the closure holds the libs and tools the roots run.
# From: Issue #1683 | PR #1858
_ci_toolchain_closure() {
    local ref="$1" platform="$2" roots="$3" work="$4" out
    _ci_image_files "${ref}" "${platform}" "${work}" /lib/apk/db/installed || return 2
    out="$(_ci_run "[CI-ERROR-IDENTITY-0020]" "image=\"${ref}\" platform=\"${platform}\" reason=\"toolchain package closure not read\"" \
        awk -v roots="${roots//$'\n'/ }" "${_CI_AWK_APK_CLOSURE}" "${work}/installed")" || return 2
    printf '%s\n' "${out}" | LC_ALL=C sort
}

# What: installed apk packages the index has newer.
# Why: the image files come from the one image reader.
# From: Issue #1683 | PR #1858
_ci_apk_outdated() {
    local ref="$1" platform="$2" work="$3" out arch line n=0
    _ci_image_files "${ref}" "${platform}" "${work}" /lib/apk/db/installed /etc/apk/repositories /etc/apk/arch || return 2
    arch="$(<"${work}/arch")"
    # What: one APKINDEX per repository line of the image.
    # Why: a tagged line is "@tag url"; the url is last.
    # From: Issue #1683 | PR #1858
    while IFS= read -r line; do
        case "${line}" in ''|'#'*) continue ;; esac
        n=$((n + 1))
        _ci_retry download _ci_http_download "${line##* }/${arch}/APKINDEX.tar.gz" "${work}/index-${n}.tar.gz" >&2 || return 2
        if ! out="$(tar -xzf "${work}/index-${n}.tar.gz" -O APKINDEX 2>&1 >> "${work}/index")"; then
            ci_error "[CI-ERROR-REFRESH-0003]" "image=\"${ref}\" repo=\"${line}\" reason=\"APKINDEX not unpacked\"" "${out}"
            return 2
        fi
    done < "${work}/repositories"
    _ci_apk_newer "${work}/installed" "${work}/index"
}

# What: "name installed newer" for each package behind.
# Why: apk version -t owns the order; no own compare.
# From: Issue #1683 | PR #1858
_ci_apk_newer() {
    local pairs name have cand order
    # What: P: then V: per record, in both file formats.
    # Why: the one P:/V: reader for the db and the index.
    # From: Issue #1683 | PR #1858
    pairs="$(_ci_capture 0 awk 'function pv(n, v) {
        if (file == 1) have[n] = v
        else if ((n in have) && v != have[n]) print n "\t" have[n] "\t" v }
        FNR == 1 { file++ }
        '"${_CI_AWK_APK_PV}" "$1" "$2")" || return 2
    while IFS=$'\t' read -r name have cand; do
        [ -n "${name}" ] || continue
        order="$(_ci_capture 0 apk version -t "${have}" "${cand}")" || return 2
        [ "${order}" != "<" ] || printf '%s %s %s\n' "${name}" "${have}" "${cand}"
    done <<< "${pairs}" | LC_ALL=C sort -u
}

# What: Read the semantic build-impact verdict, fail-closed.
# Why: BUILD needs proven impact; unset/failed -> UNKNOWN.
# From: Issue #1683
_ci_semantic_impact() {
    local service="$1" platform="$2" identity="$3"
    local base head bm refs v=UNKNOWN
    # What: a failed lookup stops; its owner logs the code.
    # Why: AG-INT-002: an error is no UNKNOWN verdict.
    # From: Issue #1683 | PR #1858
    refs="$(_ci_diff_refs)" || return 2
    read -r base head <<<"${refs}"
    if [ -z "${base}" ]; then
        # What: a refresh run has no base; missing is BUILD.
        # Why: §17 names it a refresh point; state decides.
        # From: Issue #1683 | PR #1912
        local frc=0
        _ci_refresh_event || frc=$?
        case "${frc}" in
            0)
                ci_log "[CI-INFO-IMPACT-0016]" "service=\"${service}\" platform=\"${platform}\" event=\"${GITHUB_EVENT_NAME:-}\" reason=\"controlled refresh run; the missing artifact is the proof; BUILD\""
                printf 'BUILD\n'
                return 0
                ;;
            1) ;;
            *) return 2 ;;
        esac
        ci_log "[CI-INFO-IMPACT-0003]" "service=\"${service}\" platform=\"${platform}\" reason=\"no base ref for this event; UNKNOWN\""
        printf 'UNKNOWN\n'
        return 0
    fi
    bm="$(_ci_mktemp -p "${CI_TMPDIR}")" || return 2
    if _ci_manifest_at "${base}" "${bm}" && [ -s "${bm}" ]; then
        v="$(_ci_impact_classify "${service}" "${platform}" "${identity}" "${base}" "${bm}")" || { rm -f "${bm}"; return 2; }
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
# Why: NOOP/reuse precede compile; UNKNOWN never builds.
# From: Issue #1683
_ci_build_one() {
    local service="$1" platform="$2"
    local resolved action identity state impact ack
    # What: log in before the resolver reads GHCR.
    # Why: an anonymous probe is 403 -> UNKNOWN, no build.
    # From: Issue #1683 | PR #1858
    _ci_require_ghcr_auth || return "$?"
    resolved="$(_ci_resolve_one "${service}" "${platform}")" || return "$?"
    action="$(_ci_record_field "${resolved}" action)" || return 2
    identity="$(_ci_record_field "${resolved}" identity)" || return 2
    state="$(_ci_record_field "${resolved}" state)" || return 2

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
    impact="$(_ci_semantic_impact "${service}" "${platform}" "${identity}")" || return 2
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

# What: free the build lock on a cancel, then stop.
# Why: a cancelled run must not make the next one wait.
# From: Issue #1683 | PR #1912
_ci_ship_abort() {
    _ci_build_lock_drop "$1" "$2" || ci_log "[CI-ERROR-SHIP-0006]" "service=\"$1\" platform=\"$2\" reason=\"build lock not released on cancel\""
    exit "$3"
}

# What: ship one pair under the build lock of its identity.
# Why: one build per identity (§20); waiter re-resolves.
# From: Issue #1683 | PR #1912
ci_cmd_ship() {
    local service="${1:-}" platform="${2:-}" rc=0 lrc=0
    if [ -z "${service}" ] || [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-SHIP-0001]" "reason=\"service and platform args required\""
        return 2
    fi
    _ci_build_lock_take "${service}" "${platform}" || return "$?"
    # What: exit 128 + signal number per signal.
    # Why: a TERM cancel must not read as INT.
    # From: Issue #1683 | PR #1858
    trap '_ci_ship_abort "${service}" "${platform}" 130' INT
    trap '_ci_ship_abort "${service}" "${platform}" 143' TERM
    _ci_ship_chain "${service}" "${platform}" || rc=$?
    trap - INT TERM
    _ci_build_lock_drop "${service}" "${platform}" || lrc=$?
    if [ "${lrc}" -ne 0 ]; then
        ci_log "[CI-ERROR-SHIP-0005]" "service=\"${service}\" platform=\"${platform}\" rc=${lrc} reason=\"build lock not released\""
        [ "${rc}" -ne 0 ] || rc=2
    fi
    return "${rc}"
}

# What: frees this run's build lock of one pair.
# Why: a cancel stops the docker exec step; no trap runs
# From: Issue #1683 | PR #1912
ci_cmd_ship_release() {
    local service="${1:-}" platform="${2:-}"
    if [ -z "${service}" ] || [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-SHIP-0008]" "reason=\"service and platform args required\""
        return 2
    fi
    _ci_build_lock_drop "${service}" "${platform}"
}

# What: build, then publish+verify only what was built.
# Why: one owner for the chain; a reuse has nothing to push.
# From: Issue #1683 | PR #1858
_ci_ship_chain() {
    local service="${1:-}" platform="${2:-}" out digest result
    out="$(ci_cmd_build "${service}" "${platform}")" || return "$?"
    printf '%s\n' "${out}"
    result="$(_ci_record_field "${out}" result)" || return 2
    # What: smoke-tests an unverified artifact
    # Why: PRODUCED_UNVERIFIED needs verify, no rebuild
    # From: Issue #1683 | PR #1912
    if [ "${result}" = verify ]; then
        _ci_require_ghcr_auth || return "$?"
        digest="$(_ci_published_digest "${service}" "${platform}")" || {
            ci_log "[CI-ERROR-SHIP-0004]" "service=\"${service}\" platform=\"${platform}\" reason=\"no registry digest to verify\""
            return 2
        }
        _ci_verify_and_mark "${service}" "${digest}" "${platform}"
        return
    fi
    [ "${result}" = built ] || return 0
    # What: bake guard on the local image before publish.
    # Why: a leaked CA or build var must never reach GHCR.
    # From: Issue #1781 | PR #1858
    local tag ident
    ident="$(_ci_record_field "${out}" identity)" || return 2
    if ! tag="$(_ci_image_tag "${service}" "${platform}" "${ident}" 2>&1)"; then
        ci_error "[CI-ERROR-SHIP-0003]" "service=\"${service}\" platform=\"${platform}\" reason=\"built image tag not derivable; no bake check, no publish\"" "${tag}"
        return 2
    fi
    _ci_bake_check "${tag}" || return "$?"
    out="$(ci_cmd_publish "${service}" "${platform}")" || return "$?"
    printf '%s\n' "${out}"
    digest="$(_ci_record_field "${out}" published)" || return 2
    if [ -z "${digest}" ]; then
        ci_error "[CI-ERROR-SHIP-0002]" "service=\"${service}\" platform=\"${platform}\" reason=\"publish reported no digest\"" "${out}"
        return 2
    fi
    _ci_verify_and_mark "${service}" "${digest}" "${platform}"
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
    verify_type="$(_ci_required_field "${service}" build_type)" || return 2
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
    local service="$1" ctx rc=0 bt
    _ci_rust_validation_enabled || rc=$?
    case "${rc}" in
        0) ;;
        1) printf 'service=%s tested=SKIP reason="CI_RUST_VALIDATION is not true (AG-VAL-008)"\n' "${service}"; return 0 ;;
        *) return 2 ;;
    esac
    ctx="$(_ci_required_field "${service}" crates list)" || return 2
    bt="$(_ci_variable RUST_BACKTRACE)" || return 2
    # What: workspace-root cargo on the service's crates.
    # Why: build context is no crate; AG-VAL-008 per crate.
    # From: Issue #1683 | PR #1858
    local trc=0 c setup_rc=200 defaults rows kv
    local -a picks=() crate_list=()
    [ -z "${ctx}" ] || mapfile -t crate_list <<< "${ctx}"
    for c in "${crate_list[@]}"; do picks+=(-p "${c}"); done
    ctx="${ctx//$'\n'/ }"
    # What: tests get the env the service container gets.
    # Why: no test invents a value (AG-CODE-010).
    # From: Issue #1683 | PR #1858
    defaults="$(_ci_service_defaults_arg "${service}")" || return 2
    rows="$(_ci_service_compose_env "${service}")" || return 2
    _ci_cargo_lock || return 2
    ( _ci_sccache_env "${service}" || exit "${setup_rc}"
        trap _ci_sccache_stop EXIT
        while IFS= read -r kv; do
            [ -z "${kv}" ] || export "${kv?}"
        done <<< "${rows}"
        export "${CI_ARG_DEFAULTS}=${defaults}"
        cd "${CI_REPO_ROOT:-.}" \
            && cargo fmt --check "${picks[@]}" \
            && cargo clippy --locked --all-targets "${picks[@]}" -- -D warnings \
            && RUST_BACKTRACE="${bt}" cargo test --locked "${picks[@]}" ) || trc=$?
    # What: setup_rc: sccache setup error, rc 2, not FAIL.
    # Why: §72: infra UNKNOWN never reads as a test FAIL.
    # From: Issue #1683 | PR #1912
    case "${trc}" in
        0) ;;
        "${setup_rc}") ci_log "[CI-ERROR-TEST-0009]" "service=\"${service}\" crate=\"${ctx}\" reason=\"sccache setup failed (raw above); not a test result\""; return 2 ;;
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
    printf 'service=%s smoke=ok checks=%s\n' "${service}" "$(_ci_count_lines "${checks}")"
}

# What: run SOT smoke in an image: tools found, runs pass.
# Why: one executor for product and toolchain smoke.
# From: Issue #1683 | PR #1858
_ci_image_smoke() {
    local code="$1" service="$2" reason="$3" image="$4" tools="$5" runs="$6" limit grace out t lookup
    local -a tl=()
    # What: the lookup owner as text for the container.
    # Why: the image has no ci.sh; one owner, one loop.
    # From: Issue #1683 | PR #1912
    lookup="$(declare -f _ci_command_path _ci_command_available)"
    limit="$(_ci_variable CI_SMOKE_TIMEOUT)" || return 2
    grace="$(_ci_variable CI_SMOKE_KILL_AFTER)" || return 2
    while IFS= read -r t; do [ -n "${t}" ] && tl+=("${t}"); done <<< "${tools}"
    # What: tools go as args; runs on stdin, one a line.
    # Why: a run holds spaces/pipes; stdin keeps it intact.
    # From: Issue #1683 | PR #1858
    if ! out="$(docker run --rm -i --init --entrypoint timeout "${image}" -k "${grace}" -s TERM "${limit}" \
        bash -c "${lookup}"$'\n''for t in "$@"; do _ci_command_available "$t" || { echo "missing $t"; exit 1; }; done
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
    local service="$1" digest="$2" out="$3" ref cache_dir rc=0 bin
    ref="$(_ci_image_ref "${service}" "${digest}")" || return 2
    bin="$(_ci_trivy_bin)" || return 2
    cache_dir="$(_ci_trivy_cache_dir)" || return 2
    # What: the DB is written only by the locked refresh.
    # Why: the cache-dir is shared; this run only reads it.
    # From: Issue #1683 | PR #1858
    _ci_trivy_db_ensure_fresh "${cache_dir}" || return 2
    _ci_retry trivy "${bin}" image --format cyclonedx --cache-dir "${cache_dir}" \
        --skip-db-update --output "${out}" "${ref}" >&2 || rc=$?
    { [ "${rc}" -eq 0 ] && [ -s "${out}" ]; } && return 0
    return 1
}

# What: one coded line per _ci_trivy_scan status; rc
# Why: a run or setup failure never reads as a finding
# From: Issue #1683 | PR #1858
_ci_scan_outcome() {
    local service="$1" status="$2" raw="$3"
    case "${status}" in
        0) return 0 ;;
        1) ci_error "[CI-ERROR-SCAN-0005]" "service=\"${service}\" reason=\"scan reported findings\"" "${raw}"; return 2 ;;
        2) ci_error "[CI-ERROR-SCAN-0022]" "service=\"${service}\" reason=\"scan setup failed; not a finding\"" "${raw}"; return 2 ;;
        4) ci_error "[CI-ERROR-SCAN-0021]" "service=\"${service}\" reason=\"trivy run failed without a report; not a finding, escalate\"" "${raw}"; return 3 ;;
        6) ci_error "[CI-ERROR-SCAN-0028]" "service=\"${service}\" reason=\"trivy DB refresh failed or DB stale; not a finding, escalate\"" "${raw}"; return 3 ;;
        *) ci_error "[CI-ERROR-SCAN-0023]" "service=\"${service}\" rc=${status} reason=\"unexpected scan status; not a finding, escalate\"" "${raw}"; return 3 ;;
    esac
}

# What: why this run's token cannot write issues, or empty.
# Why: a fork or bot PR gets NOT-RUN, never a failed write.
# From: Issue #1683 | PR #1912
_ci_status_readonly_reason() {
    local actors
    [ "${GITHUB_EVENT_NAME:-}" = pull_request ] || return 0
    [ "${PR_IS_FORK:-false}" != true ] || { printf 'fork PR: the token cannot write issues\n'; return 0; }
    actors="$(_ci_variable CI_READONLY_TOKEN_ACTORS)" || return 2
    case " ${actors} " in
        *" ${GITHUB_ACTOR:-} "*) printf 'bot PR: the token cannot write issues\n' ;;
    esac
}

# What: file or close the Trivy cases one scan decided.
# Why: finding, DB outage and scan error are own issues.
# From: Issue #1683 | PR #1912
_ci_scan_report() {
    local svc="$1" plat="$2" status="$3" raw="$4" why plan kind outcome evidence rc=0
    why="$(_ci_status_readonly_reason)" || return 2
    if [ -n "${why}" ]; then
        printf 'scan-report=NOT-RUN service=%s platform=%s reason="%s"\n' "${svc}" "${plat}" "${why}"
        return 0
    fi
    # What: each status settles only the cases it proves.
    # Why: an error proves no finding, an outage none.
    # From: Issue #1683 | PR #1912
    case "${status}" in
        0) plan=$'trivy-finding success\ntrivy-scan-error success\ntrivy-db-unavailable success' ;;
        1) plan=$'trivy-finding failure\ntrivy-scan-error success\ntrivy-db-unavailable success' ;;
        4) plan=$'trivy-scan-error failure\ntrivy-db-unavailable success' ;;
        6) plan='trivy-db-unavailable failure' ;;
        *) plan='trivy-scan-error failure' ;;
    esac
    while read -r kind outcome; do
        evidence=""
        [ "${outcome}" != failure ] || evidence="${raw}"
        _ci_status_case "${kind}" "${outcome}" "${svc}" "${plat#*/}" "${evidence}" || rc=2
    done <<< "${plan}"
    return "${rc}"
}

# What: Scan a published digest for vulnerabilities.
# Why: /var/tmp staging (no tmpfs OOM), authed, fail-closed.
# From: Issue #1683
ci_cmd_scan() {
    local service="${1:-}" digest="${2:-}" platform="${3:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-SCAN-0001]" "reason=\"service arg required\""; return 2; }
    [ -n "${digest}" ] || { ci_log "[CI-ERROR-SCAN-0002]" "reason=\"digest arg required\""; return 2; }
    [ -n "${platform}" ] || { ci_log "[CI-ERROR-SCAN-0029]" "reason=\"platform arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    local raw status orc=0 rrc=0 line dbrec=""
    if raw="$(TMPDIR="${CI_TMPDIR}" _ci_trivy_scan "${service}" "${digest}" 2>&1)"; then status=0; else status=$?; fi
    # What: the DB identity line _ci_trivy_scan printed.
    # Why: AG-VAL-026: it goes into the scan result.
    # From: Issue #1683
    while IFS= read -r line; do
        case "${line}" in
            "trivy-db "*) dbrec="${line#trivy-db }" ;;
        esac
    done <<< "${raw}"
    _ci_scan_outcome "${service}" "${status}" "${raw}" || orc=$?
    # What: the report follows the verdict, no more.
    # Why: a failed write must not hide a finding.
    # From: Issue #1683 | PR #1912
    _ci_scan_report "${service}" "${platform}" "${status}" "${raw}" || rrc=$?
    [ "${orc}" -eq 0 ] || return "${orc}"
    [ "${rrc}" -eq 0 ] || return "${rrc}"
    printf 'service=%s scanned=clean digest=%s tmpdir=%s trivy_db="%s"\n' "${service}" "${digest}" "${CI_TMPDIR}" "${dbrec}"
}

# What: scan every channel image, not only the built ones.
# Why: a new CVE hits an unchanged image; §31 refreshes it.
# From: Issue #1683 | PR #1912
ci_cmd_scan_channel() {
    local include='[]'
    _ci_for_all_pairs _ci_scan_channel_pair || return "$?"
    CI_SCAN_FULL=1 CI_BUILD_MATRIX="$(_ci_matrix_doc "${include}")" ci_cmd_scan_stack
}

# What: add one pair to the scan-channel matrix.
# Why: the per-pair unit _ci_for_all_pairs calls.
# From: Issue #1683 | PR #1912
_ci_scan_channel_pair() {
    include="$(_ci_matrix_append "${include}" service="$1" platform="$2")" || return 2
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

# What: index of the accepted digests, found by content
# Why: §28: an unchanged service keeps its build commit
# From: Issue #1683 | PR #1858
_ci_index_lookup() {
    local service="$1" want="$2"
    local name head kv rev revs tag idx grc plats have found=""
    name="$(_ci_image_ref "${service}")" || return 2
    head="$(_ci_head_commit)" || return 2
    revs="${head}"
    local -a want_list
    read -ra want_list <<< "${want}"
    for kv in "${want_list[@]}"; do
        rev="$(_ci_registry_read "${name}@${kv#*=}" revision "[CI-ERROR-ASSEMBLE-0016]" fail)" || return 2
        _ci_list_has "${rev}" "${revs}" || revs="${revs}"$'\n'"${rev}"
    done
    while IFS= read -r rev; do
        tag="${name}:sha-${rev}"
        grc=0; idx="$(_ci_registry_probe "${tag}")" || grc=$?
        [ "${grc}" -ne 1 ] || continue
        [ "${grc}" -eq 0 ] || return "${grc}"
        plats="$(_ci_index_children "${tag}")" || return "$?"
        plats="$(tr '\n' ' ' <<< "${plats}")"
        have="$(_ci_normalize_platform_digests "${plats}")"
        if [ "${have}" = "${want}" ]; then
            printf '%s %s\n' "${idx}" "${plats% }"
            return 0
        fi
        # What: a head index that differs goes to reconcile.
        # Why: reconcile completes or refuses it (§45).
        # From: Issue #1683 | PR #1858
        [ "${rev}" != "${head}" ] || found="${idx} ${plats% }"
    done <<< "${revs}"
    [ -n "${found}" ] || return 1
    printf '%s\n' "${found}"
}

# What: platform=digest lines of the index at ref $1.
# Why: one child reader for assemble and promote.
# From: Issue #1683 | PR #1858
_ci_index_children() {
    local raw plats
    raw="$(_ci_index_raw "$1")" || return "$?"
    if ! plats="$(jq -r '.manifests[]? | select(.platform.os!="unknown" and .platform.architecture!="unknown") | "\(.platform.os)/\(.platform.architecture)=\(.digest)"' <<< "${raw}" 2>&1)"; then
        ci_error "[CI-ERROR-ASSEMBLE-0010]" "ref=\"$1\" reason=\"existing index unparseable; UNKNOWN\"" "${plats}"$'\n'"index: ${raw}"
        return 2
    fi
    [ -z "${plats}" ] || printf '%s\n' "${plats}"
}

# What: Collect a target's accepted per-platform digests.
# Why: a red platform leaves the others assembled.
# From: Issue #1683 | PR #1858
_ci_collect_accepted_digests() {
    local service="$1" plats p line state digest n=0
    plats="$(_ci_platforms "${service}")" || return "$?"
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        line="$(_ci_resolve_one "${service}" "${p}")" || return "$?"
        state="$(_ci_record_field "${line}" state)" || return 2
        case "${state}" in
            PRESENT_ACCEPTED) ;;
            # What: a platform not accepted stays out.
            # Why: its channels keep the old image.
            # From: Issue #1683 | PR #1858
            MISSING_CONFIRMED|PRODUCED_UNVERIFIED)
                ci_log "[CI-WARN-ASSEMBLE-0013]" "service=\"${service}\" platform=\"${p}\" state=\"${state}\" reason=\"platform not accepted; left out of the index\""
                continue
                ;;
            *)
                ci_error "[CI-ERROR-ASSEMBLE-0002]" "service=\"${service}\" platform=\"${p}\" reason=\"platform state not decidable; not assembling, not rebuilding\" state=\"${state}\"" "resolve: ${line}"
                return 2
                ;;
        esac
        if ! digest="$(_ci_accepted_digest "${service}" "${p}")"; then
            ci_log "[CI-ERROR-ASSEMBLE-0003]" "service=\"${service}\" platform=\"${p}\" reason=\"no accepted digest for an ACCEPTED platform\""
            return 2
        fi
        printf '%s=%s\n' "${p}" "${digest}"
        n=$((n + 1))
    done <<< "${plats}"
    if [ "${n}" -eq 0 ]; then
        ci_log "[CI-ERROR-ASSEMBLE-0014]" "service=\"${service}\" reason=\"no platform accepted; nothing to assemble\""
        return 2
    fi
}

# What: Reuse an identical index or reject a divergent one.
# Why: Idempotent retry; never overwrite an index.
# From: Issue #1683
_ci_reconcile_index() {
    local service="$1" want="$2" existing ex_digest ex_have lrc=0 kv sub=1 wl
    existing="$(_ci_index_lookup "${service}" "${want}")" || lrc=$?
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
    # What: an index may gain a platform, never change one.
    # Why: a rebuilt red platform completes the sha index.
    # From: Issue #1683 | PR #1858
    wl="$(tr ' ' '\n' <<< "${want}")"
    local -a have_list
    read -ra have_list <<< "${ex_have}"
    for kv in "${have_list[@]}"; do
        _ci_list_has "${kv}" "${wl}" || sub=0
    done
    if [ "${sub}" -eq 1 ]; then
        ci_log "[CI-INFO-ASSEMBLE-0015]" "service=\"${service}\" existing=\"${ex_digest}\" reason=\"index lacks a platform accepted now; completing it\""
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
    sha="$(_ci_head_commit)" || return 2
    target="${name}:sha-${sha}"
    local -a srcs=()
    for kv; do
        srcs+=("${name}@${kv#*=}")
    done
    _ci_imagetools_create "${target}" "${srcs[@]}" >&2 || return "$?"
    _ci_registry_digest "${target}"
}

# What: Assemble accepted per-platform digests.
# Why: accepted platforms only; a gap opens an issue.
# From: Issue #1683 | PR #1858
ci_cmd_assemble() {
    local service="${1:-}"
    [ -n "${service}" ] || { ci_log "[CI-ERROR-ASSEMBLE-0001]" "reason=\"service arg required\""; return 2; }
    local inputs want count reused index
    inputs="$(_ci_collect_accepted_digests "${service}")" || return "$?"
    want="$(_ci_normalize_platform_digests "${inputs}")"
    local -a input_list=()
    [ -z "${inputs}" ] || mapfile -t input_list <<< "${inputs}"
    count="$(printf '%s\n' "${input_list[@]}" | awk '/=/ {n++} END {print n+0}')"
    if ! reused="$(_ci_reconcile_index "${service}" "${want}")"; then
        return 2
    fi
    if [ -n "${reused}" ]; then
        printf 'service=%s result=reuse-index assembled=%s platforms=%s\n' "${service}" "${reused}" "${count}"
        _ci_assemble_report "${service}" "${inputs}"
        return "$?"
    fi
    _ci_require_ghcr_auth || return "$?"
    if ! index="$(_ci_docker_assemble "${service}" "${input_list[@]}")"; then
        ci_log "[CI-ERROR-ASSEMBLE-0005]" "service=\"${service}\" inputs=\"${inputs}\" reason=\"assemble backend failed (raw above)\""
        return 2
    fi
    printf 'service=%s result=assembled assembled=%s platforms=%s\n' "${service}" "${index}" "${count}"
    _ci_assemble_report "${service}" "${inputs}"
}

# What: file or close the platform-mismatch case per arch.
# Why: a platform left out opens an issue.
# From: Issue #1683 | PR #1858
_ci_assemble_report() {
    local svc="$1" inputs="$2" why plats p outcome rc=0
    why="$(_ci_status_readonly_reason)" || return 2
    if [ -n "${why}" ]; then
        printf 'assemble-report=NOT-RUN service=%s reason="%s"\n' "${svc}" "${why}"
        return 0
    fi
    plats="$(_ci_platforms "${svc}")" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        outcome=success
        _ci_text_has "^${p}=" "${inputs}" || outcome=failure
        _ci_status_case platform-mismatch "${outcome}" "${svc}" "${p#*/}" "accepted: ${inputs}" || rc=2
    done <<< "${plats}"
    return "${rc}"
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
            [ -z "${p}" ] || printf '%s %s\n' "${ch}" "${_CI_SOT["${kp}v:${p}"]}"
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

# What: check out a channel source_ref or a pinned commit
# Why: a schedule run starts on the default branch
# From: Issue #1683 | PR #1858
ci_cmd_channel_checkout() {
    local channel="${1:-}" pin="${2:-}" rows ref remote want sha boot
    if [ -z "${channel}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0017]" "reason=\"channel arg required\""
        return 2
    fi
    rows="$(_ci_channel_field source_ref)" || return 2
    ref="$(awk -v c="${channel}" '$1 == c { print $2 }' <<< "${rows}")"
    if [ -z "${ref}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0018]" "channel=\"${channel}\" reason=\"SOT release.channels has no source_ref for this channel\""
        return 2
    fi
    # What: the branch name the bootstrap checked out.
    # Why: YAML read it before ci.sh; it must match the SOT.
    # From: Issue #1683 | PR #1858
    if [ -n "${CI_BOOTSTRAP_REF_VARIABLE:-}" ]; then
        boot="$(_ci_variable_env "${CI_BOOTSTRAP_REF_VARIABLE}")" || return 2
        if [ -z "${boot}" ]; then
            ci_log "[CI-ERROR-PROMOTE-0036]" "name=\"${CI_BOOTSTRAP_REF_VARIABLE}\" want=\"${ref}\" reason=\"repo variable not set\""
            return 2
        fi
        if [ "${boot}" != "${ref#refs/heads/}" ]; then
            ci_log "[CI-ERROR-PROMOTE-0037]" "name=\"${CI_BOOTSTRAP_REF_VARIABLE}\" got=\"${boot}\" want=\"${ref}\" reason=\"repo variable differs from the SOT source_ref\""
            return 2
        fi
    fi
    # What: a later job checks out the first job's commit
    # Why: all jobs of one run validate and promote one tree
    # From: Issue #1683 | PR #1858
    want="${ref}"
    if [ -n "${pin}" ]; then
        if [[ ! "${pin}" =~ ^[0-9a-f]{40}$ ]]; then
            ci_log "[CI-ERROR-PROMOTE-0020]" "channel=\"${channel}\" commit=\"${pin}\" reason=\"pinned commit is not a full 40-hex SHA\""
            return 2
        fi
        want="${pin}"
    fi
    remote="$(_ci_git_remote)" || return 2
    (cd -- "${CI_REPO_ROOT}" && _ci_retry git-fetch git fetch --no-tags --depth=1 "${remote}" "${want}") >&2 || return 2
    _ci_run "[CI-ERROR-PROMOTE-0019]" "channel=\"${channel}\" ref=\"${want}\" reason=\"checkout of the fetched source failed\"" \
        git -C "${CI_REPO_ROOT}" checkout FETCH_HEAD || return 2
    sha="$(_ci_head_commit)" || return 2
    _ci_step_output "[CI-ERROR-PROMOTE-0021]" commit "${sha}" || return 2
    # What: later steps of this job see the checked-out ref.
    # Why: a master-started run must use current_dev tools.
    # From: Issue #1683 | PR #1858
    _ci_step_output "[CI-ERROR-PROMOTE-0038]" CI_SOURCE_REF "${ref#refs/heads/}" GITHUB_ENV || return 2
    printf 'channel=%s source_ref=%s commit=%s\n' "${channel}" "${ref}" "${sha}"
}

# What: channels and GitHub-hosted runner for channel-check
# Why: the SOT owns both; CHECK_CHANNEL narrows a dispatch.
# From: Issue #1683 | PR #1858
ci_cmd_channel_matrix() {
    local want="${CHECK_CHANNEL:-}" list runner json vrc=0
    local -a chans=()
    if [ -n "${want}" ]; then
        _ci_valid_channel "${want}" || vrc=$?
        if [ "${vrc}" -ne 0 ]; then
            [ "${vrc}" -eq 2 ] || ci_log "[CI-ERROR-PROMOTE-0025]" "channel=\"${want}\" reason=\"not a mutable SOT channel\""
            return 2
        fi
        list="${want}"
    else
        list="$(_ci_mutable_channels)" || return 2
    fi
    [ -z "${list}" ] || mapfile -t chans <<< "${list}"
    if [ "${#chans[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-PROMOTE-0026]" "reason=\"no mutable SOT channel to check\""
        return 2
    fi
    json="$(_ci_capture 0 jq -cn "\$ARGS.positional" --args "${chans[@]}")" || return 2
    runner="$(_ci_hosted_runner "[CI-ERROR-PROMOTE-0027]")" || return 2
    _ci_step_output "[CI-ERROR-PROMOTE-0028]" channels "${json}" || return 2
    _ci_step_output "[CI-ERROR-PROMOTE-0029]" runner "${runner}" || return 2
    printf 'channels=%s runner=%s\n' "${json}" "${runner}"
}

# What: pull a channel by its tag and start the stack.
# Why: a lost channel image must fail before a user pulls.
# From: Issue #1683 | PR #1858
ci_cmd_channel_check() {
    local channel="${1:-}" svcs svc digest cand="" absent="" vrc=0
    if [ -z "${channel}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0030]" "reason=\"channel arg required\""
        return 2
    fi
    _ci_valid_channel "${channel}" || vrc=$?
    if [ "${vrc}" -ne 0 ]; then
        [ "${vrc}" -eq 2 ] || ci_log "[CI-ERROR-PROMOTE-0031]" "channel=\"${channel}\" reason=\"not a mutable SOT channel\""
        return 2
    fi
    _ci_validate_host_tools || return 2
    _ci_require_ghcr_auth || return 2
    svcs="$(ci_services)" || return 2
    # What: read each service tag, then start the stack.
    # Why: a missing tag names all; no partial stack.
    # From: Issue #1683 | PR #1858
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        if digest="$(_ci_channel_readback "${svc}" "${channel}")"; then
            cand+="${cand:+$'\n'}${svc}=${digest}"
        else
            absent+="${absent:+ }${svc}"
        fi
    done <<< "${svcs}"
    if [ -n "${absent}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0032]" "channel=\"${channel}\" missing=\"${absent}\" reason=\"channel tag absent or incomplete (raw above); stack not started\""
        return 1
    fi
    printf 'channel-check channel=%s candidate="%s"\n' "${channel}" "${cand//$'\n'/ }"
    _ci_validate_run "${cand}"
}

# What: file or close the issue of one checked channel.
# Why: each channel has its own issue: -<channel> label.
# From: Issue #1683 | PR #1858
ci_cmd_channel_report() {
    local channel="${1:-}" outcome="${2:-}" text verdict=failure vrc=0
    if [ -z "${channel}" ] || [ -z "${outcome}" ]; then
        ci_log "[CI-ERROR-STATUS-0012]" "channel=\"${channel}\" outcome=\"${outcome}\" reason=\"channel and step outcome args required\""
        return 2
    fi
    _ci_valid_channel "${channel}" || vrc=$?
    if [ "${vrc}" -ne 0 ]; then
        [ "${vrc}" -eq 2 ] || ci_log "[CI-ERROR-STATUS-0013]" "channel=\"${channel}\" reason=\"not a mutable SOT channel\""
        return 2
    fi
    [ "${outcome}" != success ] || verdict=success
    text="$(_ci_status_text channel-check "${channel}")" || return 2
    _ci_status_apply "${verdict}" "${text%%$'\n'*}" "${text#*$'\n'}: ${channel}" "channel=${channel} step outcome=${outcome}"
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
    _ci_release_tag_kind "${target}" >&2
}

# What: accepted multi-arch candidate: service=index-digest.
# Why: promote/validate use digests, no moving tags (§48).
# From: Issue #1683
_ci_stack_candidate_ledger() {
    _ci_stack_candidate_rows _ci_candidate_index
}

# What: service=<lookup "$@" service> per stack service.
# Why: one loop for the ledger and the PR candidate.
# From: Issue #1683 | PR #1912
_ci_stack_candidate_rows() {
    local service val
    local produced produced_rc=0
    produced="$(ci_services)" || produced_rc=$?
    _ci_producer_ok "${produced_rc}" 0 || return 2
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        val="$("$@" "${service}")" || return "$?"
        printf '%s=%s\n' "${service}" "${val}"
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

# What: toolchain candidates of the accepted platforms.
# Why: promote is the one channel mover (AG-REL-009).
# From: Issue #1683 | PR #1858
_ci_toolchain_candidate() {
    local service idx p st busy acc plats tools
    tools="$(_ci_block_keys build_toolchain)" || return 2
    while IFS= read -r service; do
        [ -n "${service}" ] || continue
        busy=0 acc=0
        plats="$(_ci_platforms "${service}")" || return "$?"
        while IFS= read -r p; do
            [ -n "${p}" ] || continue
            st="$(_ci_resolve_one "${service}" "${p}")" || return "$?"
            st="$(_ci_record_field "${st}" state)" || return 2
            case "${st}" in
                PRESENT_ACCEPTED) acc=$((acc + 1)) ;;
                MISSING_CONFIRMED|PRODUCED_UNVERIFIED) ;;
                UNKNOWN|MISMATCH)
                    ci_log "[CI-ERROR-CANDIDATE-0003]" "service=\"${service}\" platform=\"${p}\" state=\"${st}\" reason=\"toolchain state not decidable; no promotion\""
                    return 2
                    ;;
                *) busy=1 ;;
            esac
        done <<< "${plats}"
        if [ "${busy}" -eq 1 ] || [ "${acc}" -eq 0 ]; then
            ci_log "[CI-INFO-CANDIDATE-0004]" "service=\"${service}\" reason=\"toolchain still building or accepted nowhere; channel unchanged\""
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
    local platform
    if ! platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')" || [ -z "${platform}" ]; then
        ci_log "[CI-ERROR-CANDIDATE-0005]" "reason=\"docker daemon platform unknown; cannot pick PR images\""
        return 2
    fi
    _ci_stack_candidate_rows _ci_pr_candidate_digest "${platform}"
}

# What: PR image digest of service $2 on platform $1.
# Why: a missing image refuses a partial stack.
# From: Issue #1683 | PR #1858
_ci_pr_candidate_digest() {
    if ! _ci_published_digest "$2" "$1"; then
        ci_log "[CI-ERROR-CANDIDATE-0002]" "service=\"$2\" reason=\"PR image not resolvable; refusing to validate a partial stack\""
        return 2
    fi
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

# What: 0 if the stack services equal the validated stack.
# Why: promote moves only what validate checked (§48-§51).
# From: Issue #1683 | PR #1858
_ci_stack_validated() {
    local cand="$1" svcs line prod=""
    svcs="$(ci_services)" || return 2
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        _ci_list_has "${line%%=*}" "${svcs}" || continue
        prod="${prod:+${prod} }${line}"
    done <<< "${cand}"
    [ -n "${CI_STACK_VALIDATED:-}" ] && [ "${prod}" = "${CI_STACK_VALIDATED}" ]
}

# What: The per-channel promotion lock ref.
# Why: serialize movers of one channel (§52).
# From: Issue #1683
_ci_promote_lock_ref() {
    local prefix
    prefix="$(_ci_required_field release promote_lock_ref block)" || return 2
    printf '%s/%s' "${prefix}" "$1"
}

# What: Default promote lock: take the channel lock.
# Why: the cross-host CAS mutex, reused for promotion.
# From: Issue #1683
_ci_promote_lock() {
    local remote backoff ref
    remote="$(_ci_git_remote)" || return 2
    backoff="$(_ci_variable CI_LOCK_POLL_SECONDS)" || return 2
    ref="$(_ci_promote_lock_ref "$1")" || return 2
    _ci_lock_acquire "${remote}" "${ref}" "$(_ci_lock_note promote "$1")" "${backoff}"
}

# What: Default promote unlock: free the channel lock.
# Why: the same holder note the acquire path used.
# From: Issue #1683
_ci_promote_unlock() {
    local remote ref
    remote="$(_ci_git_remote)" || return 2
    ref="$(_ci_promote_lock_ref "$1")" || return 2
    _ci_lock_release "${remote}" "${ref}" "$(_ci_lock_note promote "$1")"
}

# What: point svc:channel at digest plus kept children $4.
# Why: shares the one index writer; moves, never builds.
# From: Issue #1683 | PR #1858
_ci_promote_move() {
    local svc="$1" channel="$2" digest="$3" kept="${4:-}" name kv
    name="$(_ci_image_ref "${svc}")" || return 2
    local -a srcs=("${name}@${digest}") kept_list
    read -ra kept_list <<< "${kept}"
    for kv in "${kept_list[@]}"; do
        srcs+=("${name}@${kv#*=}")
    done
    _ci_imagetools_create "${name}:${channel}" "${srcs[@]}" >&2
}

# What: channel children of the platforms digest $3 lacks.
# Why: a platform red in this run keeps its image.
# From: Issue #1683 | PR #1858
_ci_promote_kept() {
    local svc="$1" channel="$2" digest="$3" name have old plats p line rc=0 kept=""
    name="$(_ci_image_ref "${svc}")" || return 2
    have="$(_ci_index_children "${name}@${digest}")" || return 2
    old="$(_ci_index_children "${name}:${channel}")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    plats="$(_ci_platforms "${svc}")" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        if _ci_text_has "^${p}=" "${have}"; then continue; fi
        line="$(awk -F= -v p="${p}" '$1 == p { print; exit }' <<< "${old}")"
        if [ -z "${line}" ]; then
            ci_log "[CI-WARN-PROMOTE-0033]" "service=\"${svc}\" channel=\"${channel}\" platform=\"${p}\" reason=\"candidate and channel both lack this platform\""
            continue
        fi
        ci_log "[CI-INFO-PROMOTE-0034]" "service=\"${svc}\" channel=\"${channel}\" platform=\"${p}\" kept=\"${line#*=}\" reason=\"platform not in the candidate; channel keeps its image\""
        kept="${kept} ${line}"
    done <<< "${plats}"
    printf '%s\n' "${kept# }"
}

# What: 0 if the channel holds digest children plus kept.
# Why: a merged channel index has a digest of its own.
# From: Issue #1683 | PR #1858
_ci_channel_matches() {
    local svc="$1" channel="$2" digest="$3" kept="$4" name want seen
    name="$(_ci_image_ref "${svc}")" || return 2
    want="$(_ci_index_children "${name}@${digest}")" || return 2
    seen="$(_ci_index_children "${name}:${channel}")" || return "$?"
    want="$(_ci_normalize_platform_digests "${want} ${kept}")"
    seen="$(_ci_normalize_platform_digests "${seen}")"
    [ "${want}" = "${seen}" ]
}

# What: Channel readback; -p digest only, 1 absent.
# Why: one digest reader; -p lets a new channel read absent.
# From: Issue #1683
_ci_channel_readback() {
    local probe=0 svc channel name digest
    if [ "${1:-}" = -p ]; then probe=1; shift; fi
    svc="$1"; channel="$2"
    name="$(_ci_image_ref "${svc}")" || return 2
    if [ "${probe}" -eq 1 ]; then
        _ci_registry_probe "${name}:${channel}"
        return "$?"
    fi
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
    local base="$1" digest="$2" child prc children rc=0
    children="$(_ci_index_children "${base}@${digest}")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    # What: an absent or childless index is incomplete.
    # Why: zero children must not read as all resolvable.
    # From: Issue #1683
    if [ -z "${children}" ]; then
        ci_log "[CI-ERROR-PROMOTE-0015]" "image=\"${base}@${digest}\" reason=\"index has no readable platform child\""
        return 2
    fi
    while IFS= read -r child; do
        child="${child#*=}"
        prc=0
        _ci_registry_probe "${base}@${child}" >&2 || prc=$?
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
    local channel="$1" cand="$2" line svc digest seen prev moved="" prc kept mrc plan=""
    # What: read every service's state before any move.
    # Why: a read error then stops with nothing moved (§50).
    # From: Issue #1683 | PR #1858
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; digest="${line#*=}"
        if ! kept="$(_ci_promote_kept "${svc}" "${channel}" "${digest}")"; then
            ci_log "[CI-ERROR-PROMOTE-0035]" "service=\"${svc}\" channel=\"${channel}\" reason=\"kept platforms unreadable; blocking, nothing moved\""
            return 2
        fi
        # What: read the earlier digest; absent = first.
        # Why: an unreadable state cannot be rolled back.
        # From: Issue #1683 | PR #1912
        prc=0
        prev="$(_ci_channel_readback -p "${svc}" "${channel}")" || prc=$?
        if [ "${prc}" -gt 1 ]; then
            ci_log "[CI-ERROR-PROMOTE-0024]" "service=\"${svc}\" channel=\"${channel}\" rc=${prc} reason=\"earlier digest unreadable; blocking, nothing moved\""
            return 2
        fi
        plan+="${svc}|${digest}|${prev}|${kept}"$'\n'
    done <<< "${cand}"
    while IFS='|' read -r svc digest prev kept; do
        [ -n "${svc}" ] || continue
        if ! _ci_promote_move "${svc}" "${channel}" "${digest}" "${kept}"; then
            ci_log "[CI-ERROR-PROMOTE-0007]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel ref move failed\""
            _ci_promote_rollback "${channel}" "${moved}"
            return 2
        fi
        moved="${moved}${svc}=${prev}"$'\n'
        if ! seen="$(_ci_channel_readback "${svc}" "${channel}")"; then
            ci_log "[CI-ERROR-PROMOTE-0008]" "service=\"${svc}\" channel=\"${channel}\" reason=\"readback failed; blocking\""
            _ci_promote_rollback "${channel}" "${moved}"
            return 2
        fi
        mrc=0; _ci_channel_matches "${svc}" "${channel}" "${digest}" "${kept}" || mrc=$?
        if [ "${mrc}" -ne 0 ]; then
            ci_error "[CI-ERROR-PROMOTE-0009]" "service=\"${svc}\" channel=\"${channel}\" rc=${mrc} reason=\"readback MISMATCH; rolling the moved services back\" expected=\"${digest} ${kept}\"" "readback=${seen}"
            _ci_promote_rollback "${channel}" "${moved}"
            return 2
        fi
    done <<< "${plan}"
}

# What: re-read the stack under the lock, then move it.
# Why: a stack accepted meanwhile was never validated.
# From: Issue #1683 | PR #1858
_ci_promote_locked() {
    local channel="$1" cand="$2" now
    if ! now="$(_ci_stack_candidate --with-toolchain)"; then
        ci_log "[CI-ERROR-PROMOTE-0041]" "channel=\"${channel}\" reason=\"stack unreadable under the lock; blocking\""
        return 2
    fi
    if [ "${now}" != "${cand}" ]; then
        ci_error "[CI-ERROR-PROMOTE-0042]" "channel=\"${channel}\" reason=\"stack changed after validate; blocking\"" \
            "validated=${cand}"$'\n'"now=${now}"
        return 2
    fi
    _ci_promote_move_all "${channel}" "${cand}"
}

# What: Put moved services back on their earlier digests.
# Why: a failed move must not leave a mixed channel (§50)
# From: Issue #1683 | PR #1912
_ci_promote_rollback() {
    local channel="$1" moved="$2" line svc prev
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; prev="${line#*=}"
        if [ -z "${prev}" ]; then
            ci_log "[CI-ERROR-PROMOTE-0022]" "service=\"${svc}\" channel=\"${channel}\" reason=\"channel had no image before; ref stays, channel incomplete until a promote rerun\""
            continue
        fi
        if ! _ci_promote_move "${svc}" "${channel}" "${prev}"; then
            ci_log "[CI-ERROR-PROMOTE-0023]" "service=\"${svc}\" channel=\"${channel}\" earlier=\"${prev}\" reason=\"rollback move failed; channel is mixed until a promote rerun\""
        fi
    done <<< "${moved}"
}

# What: True if the candidate holds every product service.
# Why: Promotion is stack-atomic; 8/9 does not promote.
# From: Issue #1683
_ci_promote_stack_complete() {
    local channel="$1" cand="$2" svcs svc
    svcs="$(ci_services)" || return "$?"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        if ! _ci_text_has "^${svc}=" "${cand}"; then
            ci_log "[CI-ERROR-PROMOTE-0004]" "channel=\"${channel}\" service=\"${svc}\" reason=\"incomplete stack; no promotion (docs section 50)\""
            return 2
        fi
    done <<< "${svcs}"
}

# What: True if every ref already points at its digest.
# Why: A re-run needs no lock or move; rc 2 unknown.
# From: Issue #1683
_ci_promote_all_current() {
    local channel="$1" cand="$2" line svc digest seen name rc kept
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        svc="${line%%=*}"; digest="${line#*=}"
        rc=0
        seen="$(_ci_channel_readback -p "${svc}" "${channel}")" || rc=$?
        [ "${rc}" -le 1 ] || return 2
        [ "${rc}" -eq 0 ] || return 1
        kept="$(_ci_promote_kept "${svc}" "${channel}" "${digest}")" || return 2
        rc=0; _ci_channel_matches "${svc}" "${channel}" "${digest}" "${kept}" || rc=$?
        [ "${rc}" -eq 0 ] || return "${rc}"
        name="$(_ci_image_ref "${svc}")" || return 2
        _ci_index_complete "${name}" "${seen}" || return 2
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
    local cand arc=0 vrc=0
    if ! cand="$(_ci_stack_candidate --with-toolchain)"; then
        ci_log "[CI-ERROR-PROMOTE-0003]" "channel=\"${channel}\" reason=\"no accepted stack candidate\""
        return 2
    fi
    _ci_promote_stack_complete "${channel}" "${cand}" || return "$?"
    _ci_stack_validated "${cand}" || vrc=$?
    if [ "${vrc}" -ne 0 ]; then
        [ "${vrc}" -eq 1 ] || return 2
        ci_error "[CI-ERROR-PROMOTE-0005]" "channel=\"${channel}\" reason=\"stack not the validated one; promotion blocked\"" \
            "validated=${CI_STACK_VALIDATED:-}"$'\n'"candidate=${cand}"
        return 2
    fi
    _ci_require_ghcr_auth || return "$?"
    _ci_promote_all_current "${channel}" "${cand}" || arc=$?
    if [ "${arc}" -eq 0 ]; then
        printf 'channel=%s result=already-promoted services=%s\n' "${channel}" "$(_ci_count_lines "${cand}")"
        return 0
    fi
    [ "${arc}" -eq 1 ] || return "${arc}"
    if ! _ci_promote_lock "${channel}"; then
        ci_log "[CI-ERROR-PROMOTE-0010]" "channel=\"${channel}\" reason=\"could not acquire promotion lock\""
        return 2
    fi
    # What: capture rc so the unlock still runs on failure.
    # Why: a failed move must never leak the promotion lock.
    # From: Issue #1683 | PR #1858
    local rc
    if _ci_promote_locked "${channel}" "${cand}"; then rc=0; else rc=$?; fi
    _ci_promote_unlock "${channel}" || {
        ci_error "[CI-ERROR-PROMOTE-0011]" "channel=\"${channel}\" reason=\"lock release failed\"" "${channel}"
        [ "${rc}" -ne 0 ] || rc=2
    }
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf 'channel=%s result=promoted services=%s\n' "${channel}" "$(_ci_count_lines "${cand}")"
}

# What: the ref promotion reads: release tag, else event.
# Why: a release dispatch runs on a branch ref (§56.1).
# From: Issue #1683 | PR #1858
_ci_promote_ref() {
    if [ -n "${CI_RELEASE_TAG:-}" ]; then
        printf 'refs/tags/%s\n' "${CI_RELEASE_TAG}"
        return 0
    fi
    printf '%s\n' "${GITHUB_REF:-}"
}

# What: list promote targets for current git ref.
# Why: ref-driven policy; no channel logic in YAML.
# From: Issue #1683
_ci_promote_targets_for_ref() {
    local ref requested="${CI_PROMOTE_REQUESTED_CHANNEL:-}" tag prerelease
    ref="$(_ci_promote_ref)" || return 2
    {
        case "${ref}" in
            refs/heads/*) _ci_channels_where ref "${ref}" || return 2 ;;
            refs/tags/*)
                tag="${ref#refs/tags/}"
                prerelease="$(_ci_release_prerelease "${tag}")" || return "$?"
                printf '%s\n' "${tag}"
                if [ "${prerelease}" = false ]; then _ci_channels_where release_tags true || return 2; fi
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
    local out remote line
    remote="$(_ci_git_remote)" || return 2
    out="$(_ci_run "[CI-ERROR-PROMOTE-0016]" "ref=\"$1\" remote=\"${remote}\" reason=\"ref tip lookup failed\"" git ls-remote "${remote}" "$1")" || return 2
    [ -z "${out}" ] || while IFS= read -r line; do printf '%s\n' "${line%%$'\t'*}"; done <<< "${out}"
}

# What: Promote every target the current ref maps to.
# Why: one ref entry, supersede-safe, single policy owner.
# From: Issue #1683
ci_cmd_promote_ref() {
    local ref tip targets t head
    ref="$(_ci_promote_ref)" || return 2
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
    # From: Issue #1683 | PR #1858
    if [[ "${ref}" == refs/heads/* ]]; then
        if ! tip="$(_ci_ref_tip "${ref}")"; then
            ci_log "[CI-ERROR-PROMOTE-0013]" "ref=\"${ref}\" reason=\"could not resolve ref tip; refusing blind promote\""
            return 2
        fi
        head="$(_ci_head_commit)" || return 2
        if [ -n "${tip}" ] && [ "${tip}" != "${head}" ]; then
            printf 'promote=superseded ref=%s tip=%s sha=%s\n' "${ref}" "${tip}" "${head}"
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
            ci_error "[CI-ERROR-RELEASE-0019]" "commit=\"${commit}\" target=\"${target}\" reason=\"ancestry check failed\"" "${anc_err}"
            return 2
            ;;
    esac
    for p in "${gov[@]}"; do
        rc=0; _ci_content_changed _ci_tracked_content_ids "${p}" "${commit}" "${target}" || rc=$?
        case "${rc}" in
            0) printf '%s: governance %s changed since %s\n' "${name}" "${p}" "${commit}"; return 0 ;;
            1) ;;
            *) return 2 ;;
        esac
    done
    for p in "${paths[@]}"; do
        rc=0; _ci_content_changed _ci_tracked_content_ids "${p}" "${commit}" "${target}" || rc=$?
        case "${rc}" in
            0) printf '%s: %s changed since %s\n' "${name}" "${p}" "${commit}"; return 0 ;;
            1) ;;
            *) return 2 ;;
        esac
    done
}

# What: the scope paths of one validation record
# Why: a layer owns a pr_labels class, a target its paths
# From: Issue #1683 | PR #1858
_ci_release_scope() {
    local kind="$1" name="$2" class
    if [ "${kind}" = target ]; then
        _ci_target_paths "${name}"
        return "$?"
    fi
    class="$(_ci_block_entry_field release validation_layers "${name}")" || return 2
    if [ -z "${class}" ]; then
        ci_log "[CI-ERROR-RELEASE-0049]" "layer=\"${name}\" reason=\"SOT release.validation_layers names no pr_labels class\""
        return 2
    fi
    _ci_block_entry_list pr_labels "" "${class}"
}

# What: scope paths that match no tracked file
# Why: a gone path would read as unchanged forever
# From: Issue #1683 | PR #1858
_ci_release_dead_paths() {
    local p hit
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        hit="$(_ci_capture 0 git -C "${CI_REPO_ROOT}" ls-files -- "${p}")" || return 2
        [ -n "${hit}" ] || printf '%s\n' "${p}"
    done <<< "$1"
}

# What: AG-REL-011 verdict over the SOT validation record.
# Why: a stale or invalidated record must never ship.
# From: Issue #1683 | PR #1858
_ci_release_validation_valid() {
    local rel gov state target stale="" out dead="" rows layers targets name commit scope kind
    local -A rec=()
    rel="$(_ci_block_entry_field release "" validation_state)" || return 2
    gov="$(_ci_block_entry_list release "" governance_paths)" || return 2
    target="$(_ci_head_commit)" || return 2
    state="${CI_REPO_ROOT}/${rel}"
    if [ -z "${rel}" ] || [ -z "${gov}" ] || ! jq -e '(.subsystem_validation // false) != false' "${state}" >&2; then
        ci_log "[CI-ERROR-RELEASE-0014]" "state=\"${state}\" reason=\"no readable SOT validation record\""
        return 2
    fi
    # What: load the full history before any record check
    # Why: a depth-1 checkout lacks every record commit
    # From: Issue #1683 | PR #1858
    _ci_diff_history || return 2
    layers="$(_ci_block_keys release/validation_layers all)" || return 2
    if [ -z "${layers}" ]; then
        ci_log "[CI-ERROR-RELEASE-0052]" "reason=\"SOT release.validation_layers lists no layer\""
        return 2
    fi
    targets="$(ci_build_targets)" || return 2
    if ! rows="$(jq -r '(.subsystem_validation | to_entries[] | ["target", .key, (.value.commit // "null")]),
        (to_entries[] | select(.key | test("^last_.+_validation$"))
            | ["layer", (.key | sub("^last_"; "") | sub("_validation$"; "")), (.value.commit // "null")])
        | @tsv' "${state}" 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0023]" "state=\"${state}\" reason=\"validation records unreadable\"" "${rows}"
        return 2
    fi
    while IFS=$'\t' read -r kind name commit; do
        [ -n "${kind}" ] && rec["${kind}/${name}"]="${commit}"
    done <<< "${rows}"
    # What: a record whose key the SOT no longer knows
    # Why: a removed target or layer must not stay silent
    # From: Issue #1683 | PR #1858
    for name in "${!rec[@]}"; do
        kind="${name%%/*}"
        local known="${layers}"
        [ "${kind}" = layer ] || known="${targets}"
        [[ $'\n'"${known}"$'\n' == *$'\n'"${name#*/}"$'\n'* ]] && continue
        stale+="${name#*/}: no SOT ${kind} of that name"$'\n'
    done
    out="$(_ci_release_dead_paths "${gov}")" || return 2
    dead+="${out:+${out}$'\n'}"
    gov="${gov//$'\n'/ }"
    for kind in layer target; do
        local names="${layers}"
        [ "${kind}" = layer ] || names="${targets}"
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            scope="$(_ci_release_scope "${kind}" "${name}")" || return 2
            if [ -z "${scope}" ]; then
                ci_log "[CI-ERROR-RELEASE-0050]" "${kind}=\"${name}\" reason=\"empty validation scope\""
                return 2
            fi
            out="$(_ci_release_dead_paths "${scope}")" || return 2
            dead+="${out:+${out}$'\n'}"
            out="$(_ci_release_record_stale "${name}" "${rec["${kind}/${name}"]:-null}" "${target}" "${scope//$'\n'/ }" "${gov}")" || return 2
            stale+="${out:+${out}$'\n'}"
        done <<< "${names}"
    done
    if [ -n "${dead}" ]; then
        ci_error "[CI-ERROR-RELEASE-0051]" "target=\"${target}\" reason=\"validation scope path matches no tracked file\"" "${dead}"
        return 2
    fi
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
# Why: SOT release.tag_prerelease/tag_final own the grammar
# From: Issue #1683 | PR #1912
_ci_release_tag_kind() {
    local tag="$1" pre final
    _ci_block_entry_fields release "" tag_prerelease pre tag_final final || return 2
    if [ -z "${pre}" ] || [ -z "${final}" ]; then
        ci_log "[CI-ERROR-RELEASE-0055]" "reason=\"no SOT release.tag_final or tag_prerelease; FAIL CLOSED\""
        return 2
    fi
    if [[ "${tag}" =~ ${pre} ]]; then
        printf 'true\n'
        return 0
    fi
    if [[ "${tag}" =~ ${final} ]]; then
        printf 'false\n'
        return 0
    fi
    return 1
}

# What: rc 0 plain vX.Y.Z, 1 other tag, 2 SOT error.
# Why: an SOT error must never read as "not stable".
# From: Issue #1683 | PR #1858
_ci_release_tag_final() {
    local kind rc=0
    kind="$(_ci_release_tag_kind "$1")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    [ "${kind}" = false ]
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
    local tag="$1" prev repo subjects nums
    repo="$(_ci_repo)" || return 2
    prev="$(_ci_last_release_tag "${tag}")" || return 2
    if [ -z "${prev}" ]; then
        printf '_No earlier vX.Y.Z release: no change list for %s._\n' "${tag}"
        return 0
    fi
    # What: fetch both tags with full history for the range.
    # Why: CI checkouts are depth 1; log needs both ends.
    # From: Issue #894 | PR #1858
    _ci_diff_history "+refs/tags/${prev}:refs/tags/${prev}" "+refs/tags/${tag}:refs/tags/${tag}" || return 2
    subjects="$(_ci_capture 0 git -C "${CI_REPO_ROOT}" log --format=%s "${prev}..${tag}")" || return 2
    # What: "Merge pull request #N ..." and "... (#N)".
    # Why: GitHub's merge and squash default subjects.
    # From: Issue #894 | PR #1858
    nums="$(_ci_capture 0 awk "$(cat <<'PROG'
        match($0, /^Merge pull request #[0-9]+/) { print substr($0, 21, RLENGTH - 20); next }
        match($0, /\(#[0-9]+\)$/) { print substr($0, RSTART + 2, RLENGTH - 3) }
PROG
    )" <<< "${subjects}")" || return 2
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
    _ci_block_entry_fields release_notes "" skip_label skip other_title other pr_section section || return 2
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
        [ -z "${skip}" ] || ! _ci_list_has "${skip}" "${text}" || continue
        cat="${other}"
        while IFS= read -r body; do
            if _ci_list_has "${body}" "${text}"; then
                cat="$(_ci_block_entry_field release_notes_categories "${body}" title)" || return 2
                break
            fi
        done <<< "${labels}"
        body="$(_ci_capture 0 jq -r '.body // ""' <<< "${pr}")" || return 2
        body="$(_ci_pr_section "${body}" "${section}")" || return 2
        if [ "${body}" = "${body%%$'\n'*}" ]; then body=""; else body="${body#*$'\n'}"; fi
        body="$(_ci_md_strip_comments "${body}")" || return 2
        body="$(_ci_capture 0 awk "NF { seen = 1 } seen { buf = buf \$0 \"\\n\"; if (NF) { out = out buf; buf = \"\" } } END { printf \"%s\", out }" <<< "${body}")" || return 2
        [ -n "${group[${cat}]+x}" ] || order+=("${cat}")
        group["${cat}"]+="- #${num} ${title} (${url})"$'\n'
        [ -z "${body}" ] || group["${cat}"]+="  ${body//$'\n'/$'\n'  }"$'\n'
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
    local tag="${1:-}" branch="${CI_DEFAULT_BRANCH:-}" changes file head out remote url sha tip
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0032]" "reason=\"tag arg required\""; return 2; }
    file="$(_ci_variable CI_CHANGELOG)" || return 2
    _ci_release_tag_final "${tag}" || {
        [ "$?" -eq 1 ] || return 2
        printf 'release-changelog=skip tag=%s reason="not a stable vX.Y.Z tag"\n' "${tag}"
        return 0
    }
    head="## [${tag#"${tag%%[0-9]*}"}]"
    if [ -z "${branch}" ]; then
        ci_log "[CI-ERROR-RELEASE-0033]" "reason=\"CI_DEFAULT_BRANCH is required\""
        return 2
    fi
    changes="$(_ci_release_changes "${tag}")" || return 2
    remote="$(_ci_git_remote)" || return 2
    _ci_retry git-fetch git fetch --no-tags "${remote}" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" >&2 || return 2
    _ci_git_run checkout -B ci-release-changelog "${remote}/${branch}" >&2 || return 2
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
    _ci_capture 0 _ci_git_as_bot commit -m "docs: update ${file} for ${tag}" -- "${file}" >&2 || return 2
    url="$(_ci_pat_url)" || return 2
    sha="$(_ci_capture 0 git rev-parse HEAD)" || return 2
    _ci_retry git-push _ci_pat_git push "${url}" "HEAD:refs/heads/${branch}" >&2 || return 2
    # What: the branch tip must be the CHANGELOG commit
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    tip="$(_ci_ref_tip "refs/heads/${branch}")" || return 2
    if [ "${tip}" != "${sha}" ]; then
        ci_log "[CI-ERROR-RELEASE-0057]" "branch=\"${branch}\" sha=\"${sha}\" found=\"${tip}\" reason=\"pushed CHANGELOG commit not read back\""
        return 2
    fi
    printf 'release-changelog=written tag=%s branch=%s\n' "${tag}" "${branch}"
}

# What: repo variable PROJECT_RELEASE_VERSION; 1 = absent.
# Why: only gh's HTTP 404 means absent; else UNKNOWN.
# From: Issue #1683 | PR #1858
_ci_release_variable_get() {
    local path="$1" pat="$2" out rc=0
    out="$(GH_TOKEN="${pat}" _ci_retry github-read gh api -X GET --jq .value "${path}")" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        if [ "${rc}" -eq 1 ] && [[ "${out}" == *"HTTP 404"* ]]; then return 1; fi
        ci_error "[CI-ERROR-RELEASE-0058]" "path=\"${path}\" reason=\"repo variable not readable\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: set PROJECT_RELEASE_VERSION to a stable tag.
# Why: AG-SEC-004: the version is a repo variable.
# From: Issue #1683 | PR #1858
ci_cmd_release_variable() {
    local tag="${1:-}" repo pat name=PROJECT_RELEASE_VERSION want path got rc=0
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0059]" "reason=\"tag arg required\""; return 2; }
    _ci_release_tag_final "${tag}" || {
        [ "$?" -eq 1 ] || return 2
        printf 'release-variable=skip tag=%s reason="not a stable vX.Y.Z tag"\n' "${tag}"
        return 0
    }
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    pat="$(_ci_env_required PROJECT_AUTOMATION_PAT)" || return 2
    want="${tag#v}"
    path="repos/${repo}/actions/variables/${name}"
    got="$(_ci_release_variable_get "${path}" "${pat}")" || rc=$?
    case "${rc}" in
        0)
            [ "${got}" != "${want}" ] || { printf 'release-variable=unchanged name=%s value=%s\n' "${name}" "${want}"; return 0; }
            GH_TOKEN="${pat}" _ci_retry github-api gh api -X PATCH "${path}" -f name="${name}" -f value="${want}" >&2 || return 2
            ;;
        1) GH_TOKEN="${pat}" _ci_retry github-api gh api -X POST "repos/${repo}/actions/variables" -f name="${name}" -f value="${want}" >&2 || return 2 ;;
        *) return 2 ;;
    esac
    # What: read the variable back before it counts.
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    got="$(_ci_release_variable_get "${path}" "${pat}")" || return 2
    if [ "${got}" != "${want}" ]; then
        ci_log "[CI-ERROR-RELEASE-0060]" "name=\"${name}\" want=\"${want}\" found=\"${got}\" reason=\"repo variable not read back\""
        return 2
    fi
    printf 'release-variable=written name=%s value=%s\n' "${name}" "${want}"
}

# What: the released images with their digests, as a matrix.
# Why: the workflow attests each digest; no list in YAML.
# From: Issue #1683 | PR #1912
ci_cmd_release_images() {
    local tag="${1:-}" base name names img dig n include="[]" ptype repo ppath pred
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0053]" "reason=\"tag arg required\""; return 2; }
    _ci_require_ghcr_auth || return "$?"
    base="$(_ci_image_ref)" || return 2
    names="$(ci_build_targets)" || return 2
    # What: predicate type = repo URL + SOT path.
    # Why: §59 provenance has its own type; no YAML literal.
    # From: Issue #1683 | PR #1858
    ptype="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    repo="$(_ci_repo)" || return 2
    ppath="$(_ci_release_value provenance_predicate)" || return 2
    ptype="${ptype}/${repo}/${ppath}"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        img="${base}/${name}"
        dig="$(_ci_registry_digest "${img}:${tag}")" || return "$?"
        pred="$(_ci_release_provenance "${name}" "${img}" "${dig}" "${tag}")" || return "$?"
        include="$(_ci_matrix_append "${include}" registry="${img%%/*}" name="${img}" digest="${dig}" predicate_type="${ptype}" predicate="${pred}")" || return 2
    done <<< "${names}"
    _ci_step_output "[CI-ERROR-RELEASE-0054]" matrix "$(_ci_matrix_doc "${include}")" || return 2
    n="$(_ci_capture 0 jq -r 'length' <<< "${include}")" || return 2
    printf 'release-images=%s tag=%s\n' "${n}" "${tag}"
}

# What: §59 provenance JSON of one released index digest.
# Why: build and toolchain id per platform, no mutable tag.
# From: Issue #1683 | PR #1858
_ci_release_provenance() {
    local service="$1" img="$2" dig="$3" tag="$4" source repo head type kids plat child id acc rev pins tid out plats="[]" rc
    source="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    repo="$(_ci_repo)" || return 2
    source="${source}/${repo}"
    head="$(_ci_head_commit)" || return 2
    type="$(_ci_required_field "${service}" build_type)" || return 2
    kids="$(_ci_index_children "${img}@${dig}")" || return 2
    if [ -z "${kids}" ]; then
        ci_log "[CI-ERROR-RELEASE-0067]" "image=\"${img}\" digest=\"${dig}\" reason=\"released index names no platform; no provenance\""
        return 2
    fi
    while IFS= read -r plat; do
        [ -n "${plat}" ] || continue
        child="${plat#*=}"; plat="${plat%%=*}"
        id="$(_ci_identity_for "${service}" "${plat}")" || return 2
        # What: child must be this run's accepted digest.
        # Why: else the id belongs to another image.
        # From: Issue #1683 | PR #1858
        rc=0; acc="$(_ci_accepted_digest "${service}" "${plat}")" || rc=$?
        [ "${rc}" -le 1 ] || return 2
        if [ "${rc}" -ne 0 ] || [ "${acc}" != "${child}" ]; then
            ci_log "[CI-ERROR-RELEASE-0064]" "image=\"${img}\" platform=\"${plat}\" released=\"${child}\" accepted=\"${acc}\" identity=\"${id}\" reason=\"released child is not the accepted digest of this run's id; no provenance\""
            return 2
        fi
        rev="$(_ci_registry_read "${img}@${child}" revision "[CI-ERROR-RELEASE-0065]" fail)" || return 2
        pins="$(_ci_identity_pins "${service}" "${type}" "${plat}" toolchain_)" || return 2
        tid="$(printf '%s\n' "${pins}" | _ci_sha256_hex)" || return 2
        if ! out="$(jq -c --arg p "${plat}" --arg c "${child}" --arg r "${rev}" --arg i "${id}" --arg t "${tid}" --arg tc "${pins}" \
            '. + [{platform: $p, digest: $c, source_commit: $r, build_identity: $i, toolchain_identity: $t, toolchain_inputs: ($tc | split("\n") | map(select(. != "")))}]' <<< "${plats}" 2>&1)"; then
            ci_error "[CI-ERROR-RELEASE-0066]" "image=\"${img}\" platform=\"${plat}\" reason=\"provenance entry not encodable\"" "${out}"
            return 2
        fi
        plats="${out}"
    done <<< "${kids}"
    if ! out="$(jq -c -n --arg d "${dig}" --arg s "${source}" --arg h "${head}" --arg t "${tag}" --arg b "${type}" --argjson p "${plats}" \
        '{digest: $d, source: $s, release_commit: $h, release_tag: $t, build_type: $b, platforms: $p}' 2>&1)"; then
        ci_error "[CI-ERROR-RELEASE-0068]" "image=\"${img}\" reason=\"provenance not encodable\"" "${out}"
        return 2
    fi
    printf '%s\n' "${out}"
}

# What: one image's digest from the release-images matrix.
# Why: §82: the tag resolves once; notes and SBOM reuse it.
# From: Issue #1683 | PR #1858
_ci_release_digest() {
    local img="$1" matrix dig
    matrix="$(_ci_env_required CI_RELEASE_IMAGES)" || return 2
    dig="$(_ci_capture 0 jq -r --arg n "${img}" ".include[] | select(.name == \$n) | .digest" <<< "${matrix}")" || return 2
    if [[ ! "${dig}" =~ ^${CI_DIGEST_RE}$ ]]; then
        ci_error "[CI-ERROR-RELEASE-0061]" "image=\"${img}\" reason=\"not exactly one digest in CI_RELEASE_IMAGES\"" "${matrix}"
        return 2
    fi
    printf '%s\n' "${dig}"
}

# What: Render the marker-delimited image provenance block.
# Why: Records every shipped digest; SOT list, no hardcode.
# From: Issue #1683
_ci_release_notes_block() {
    local tag="$1" base target dig head
    base="$(_ci_image_ref)" || return 2
    head="$(_ci_head_commit)" || return 2
    _ci_release_marker start || return 2
    printf '## Changes\n\n'
    _ci_release_changes "${tag}" || return 2
    printf '\n## Images\n\n'
    printf 'Images published for %s (commit %s):\n\n' "${tag}" "${head}"
    local targets
    local -a target_list=()
    targets="$(ci_build_targets)" || return 2
    [ -z "${targets}" ] || mapfile -t target_list <<< "${targets}"
    for target in "${target_list[@]}"; do
        dig="$(_ci_release_digest "${base}/${target}")" || return "$?"
        printf -- '- %s:%s -> %s\n' "${base}/${target}" "${tag}" "${dig}"
    done
    printf '\nProvenance attestations and CycloneDX SBOMs attach per image.\n'
    local ignore vex
    ignore="$(_ci_variable CI_TRIVY_IGNORE)" || return 2
    vex="$(_ci_variable CI_RELEASE_VEX_ASSET)" || return 2
    printf 'OpenVEX from %s attaches as %s.\n' "${ignore}" "${vex}"
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
    _ci_retry github-api gh release upload "${tag}" "${file}" --repo "${repo}" >&2 || return 2
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
    local repo="$1" tag="$2" out rc=0
    out="$(_ci_retry github-read gh release view "${tag}" --repo "${repo}" --json body,isPrerelease)" || rc=$?
    # What: only gh's "release not found" means absent.
    # Why: auth/network errors are UNKNOWN, not "absent".
    # From: Issue #1683 | PR #1858
    if [ "${rc}" -ne 0 ]; then
        if [ "${rc}" -eq 1 ] && [[ "${out}" == *"release not found"* ]]; then return 1; fi
        ci_error "[CI-ERROR-RELEASE-0020]" "tag=\"${tag}\" reason=\"gh release view failed\"" "${out}"
        return 2
    fi
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
    sha="$(_ci_head_commit)" || return 2
    pre="$(_ci_release_prerelease "${tag}")" || return "$?"
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
        rc=0; _ci_retry github-api "${create[@]}" >&2 || rc=$?
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
    local name digest
    name="$(_ci_image_ref "${service}")" || return 2
    digest="$(_ci_release_digest "${name}")" || return "$?"
    _ci_with_workdir ci-sbom _ci_release_sbom_in "${service}" "${tag}" "${digest}"
}

# What: SBOM of release $1 into $2: 0 has $3, 1 none, 3 not
# Why: one reader for this and the previous release.
# From: Issue #1683 | PR #1858
_ci_release_sbom_get() {
    local tag="$1" out="$2" digest="$3" rc=0
    _ci_release_asset_get "${tag}" "${out##*/}" "${out%/*}" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    _ci_file_match "[CI-ERROR-RELEASE-0056]" "tag=\"${tag}\"" "${out}" "${digest}" -F || rc=$?
    [ "${rc}" -ne 1 ] || return 3
    return "${rc}"
}

# What: reuse or make and attach one SBOM, work dir in $4.
# Why: one owner removes the work dir, not this body.
# From: Issue #1683 | PR #1858
_ci_release_sbom_in() {
    local service="$1" tag="$2" digest="$3" dir="$4" out prev rc=0
    out="${dir}/${service}.cdx.json"
    # What: an attached SBOM for this digest is reused
    # Why: architecture §57: one SBOM per digest, no rescan
    # From: Issue #1683 | PR #1858
    _ci_release_sbom_get "${tag}" "${out}" "${digest}" || rc=$?
    case "${rc}" in
        0)
            printf 'release=sbom-reused service=%s tag=%s digest=%s\n' "${service}" "${tag}" "${digest}"
            return 0
            ;;
        1) ;;
        3)
            ci_error "[CI-ERROR-RELEASE-0046]" "service=\"${service}\" tag=\"${tag}\" digest=\"${digest}\" reason=\"attached SBOM is not bound to this digest\"" "digests the attached SBOM names: $(grep -o -E "${CI_DIGEST_RE}" "${out}" 2>&1 | LC_ALL=C sort -u | awk '{ printf "%s ", $0; n++ } END { if (!n) printf "none" }')"
            return 2
            ;;
        *) return 2 ;;
    esac
    # What: the previous release's SBOM of this digest.
    # Why: §57: an SBOM belongs to a digest, not a release.
    # From: Issue #1683 | PR #1858
    prev="$(_ci_last_release_tag "${tag}")" || return 2
    if [ -n "${prev}" ]; then
        rc=0; _ci_release_sbom_get "${prev}" "${out}" "${digest}" || rc=$?
        case "${rc}" in
            0)
                _ci_release_asset_put "${tag}" "${out}" || return 2
                printf 'release=sbom-reused service=%s tag=%s digest=%s from=%s\n' "${service}" "${tag}" "${digest}" "${prev}"
                return 0
                ;;
            1 | 3) rm -f "${out}" ;;
            *) return 2 ;;
        esac
    fi
    rc=0
    _ci_trivy_sbom "${service}" "${digest}" "${out}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-RELEASE-0009]" "service=\"${service}\" reason=\"SBOM generation failed\""
        return 2
    fi
    _ci_release_asset_put "${tag}" "${out}" || return 2
    printf 'release=sbom service=%s tag=%s digest=%s\n' "${service}" "${tag}" "${digest}"
}

# What: generate and attach SBOM for each image.
# Why: one SBOM walk; SOT-driven, skips third-party.
# From: Issue #1683
ci_cmd_release_sbom_stack() {
    local tag="${1:-}" svc targets
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0013]" "reason=\"tag arg required\""; return 2; }
    targets="$(ci_build_targets)" || return 2
    local -a target_list=()
    [ -z "${targets}" ] || mapfile -t target_list <<< "${targets}"
    for svc in "${target_list[@]}"; do
        ci_cmd_release_sbom "${svc}" "${tag}" || return "$?"
    done
}

# What: generate and attach OpenVEX to release.
# Why: one VEX per release; reuses SOT vex generator.
# From: Issue #1683
ci_cmd_release_vex() {
    local tag="${1:-}"
    [ -n "${tag}" ] || { ci_log "[CI-ERROR-RELEASE-0010]" "reason=\"tag arg required\""; return 2; }
    local root="${CI_REPO_ROOT:-.}" trivyignore
    trivyignore="$(_ci_repo_path CI_TRIVY_IGNORE "${root}")" || return 2
    [ -s "${trivyignore}" ] || { ci_log "[CI-ERROR-RELEASE-0011]" "path=\"${trivyignore}\" reason=\"trivyignore missing; cannot build release VEX\""; return 2; }
    _ci_with_workdir ci-vex _ci_release_vex_in "${tag}" "${trivyignore}"
}

# What: derive, compare and attach the VEX, work dir in $3.
# Why: one owner removes the work dir, not this body.
# From: Issue #1683 | PR #1858
_ci_release_vex_in() {
    local tag="$1" trivyignore="$2" dir="$3" adir out vex rc=0
    vex="$(_ci_variable CI_RELEASE_VEX_ASSET)" || return 2
    out="${dir}/${vex}"
    _ci_generate_vex "${trivyignore}" > "${out}" || rc=$?
    if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
        ci_log "[CI-ERROR-RELEASE-0012]" "tag=\"${tag}\" rc=${rc} reason=\"OpenVEX generation failed or empty (raw above)\""
        return 2
    fi
    # What: an attached VEX must equal the one derived now
    # Why: AG-REL-014: a published release is never changed
    # From: Issue #1683 | PR #1858
    adir="$(_ci_mktemp -d "${dir}/attached.XXXXXX")" || return 2
    rc=0; _ci_release_asset_get "${tag}" "${out##*/}" "${adir}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        if cmp -s "${out}" "${adir}/${out##*/}"; then
            printf 'release=vex-unchanged tag=%s\n' "${tag}"
            return 0
        fi
        ci_error "[CI-ERROR-RELEASE-0047]" "tag=\"${tag}\" reason=\"attached VEX differs from the derived one; CI never replaces it\"" "$(diff -u "${adir}/${out##*/}" "${out}" 2>&1)"
        return 2
    fi
    [ "${rc}" -eq 1 ] || return 2
    _ci_release_asset_put "${tag}" "${out}" || return 2
    printf 'release=vex tag=%s\n' "${tag}"
}

# What: every plain vX.Y.Z tag, in version order.
# Why: one tag reader for release notes and GC roots.
# From: Issue #1683 | PR #1858
_ci_release_tags() {
    local refs tags="" t remote
    remote="$(_ci_git_remote)" || return 2
    refs="$(_ci_capture 0 git ls-remote --tags --refs "${remote}")" || return 2
    # What: loads the SOT once before the per-tag subshells
    # Why: each subshell then reuses the parsed manifest
    # From: Issue #1683 | PR #1912
    _ci_block_entry_field release "" tag_final >&2 || return 2
    # What: keep plain release tags via the one tag grammar.
    # Why: no second tag pattern beside the kind owner.
    # From: Issue #1683 | PR #1858
    while IFS= read -r t; do
        t="${t##*refs/tags/}"
        if _ci_release_tag_final "${t}"; then
            tags="${tags}${t}"$'\n'
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
    done <<<"${refs}"
    tags="${tags%$'\n'}"
    [ -n "${tags}" ] || return 0
    _ci_capture 0 sort -V <<<"${tags}"
}

# What: highest plain vX.Y.Z tag (below $1 if given).
# Why: ls-remote skips deep fetch; empty pre-1.0.
# From: Issue #1683
_ci_last_release_tag() {
    local below="${1:-}" tags
    tags="$(_ci_release_tags)" || return 2
    if [ -z "${tags}" ]; then
        return 0
    fi
    if [ -z "${below}" ]; then
        printf '%s\n' "${tags##*$'\n'}"
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
    local tag="$1"
    _ci_release_tag_final "${tag}" || {
        [ "$?" -eq 1 ] || return 2
        ci_log "[CI-ERROR-RELEASE-0015]" "tag=\"${tag}\" reason=\"not a plain vX.Y.Z tag; no patch bump\""
        return 2
    }
    printf '%s.%s\n' "${tag%.*}" "$(( 10#${tag##*.} + 1 ))"
}

# What: the repo URL every PAT git call talks to
# Why: one URL for the PAT header and the push target
# From: Issue #1683 | PR #1858
_ci_pat_url() {
    local srv repo
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    printf '%s/%s.git\n' "${srv}" "${repo}"
}

# What: git with PROJECT_AUTOMATION_PAT as the only auth
# Why: rulesets refuse GITHUB_TOKEN branch pushes
# From: Issue #1683 | PR #1858
_ci_pat_git() {
    local pat srv
    pat="$(_ci_env_required PROJECT_AUTOMATION_PAT)" || return 2
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    # What: empty value drops the checkout's token header
    # Why: else git sends two AUTHORIZATION headers
    # From: Issue #1683 | PR #1858
    git -c "http.${srv}/.extraheader=" \
        -c "http.${srv}/.extraheader=$(_ci_git_auth_header "${pat}")" "$@"
}

# What: push the PAT-authored tag, then read it back
# Why: a GITHUB_TOKEN tag push starts no release run
# From: Issue #1683 | PR #1858
_ci_push_release_tag() {
    local tag="$1" sha="$2" url raw got
    url="$(_ci_pat_url)" || return 2
    _ci_run "[CI-ERROR-RELEASE-0026]" "tag=\"${tag}\" sha=\"${sha}\" reason=\"annotated tag not created\"" \
        _ci_git_as_bot tag -a "${tag}" "${sha}" -m "Patch release ${tag}" || return 2
    _ci_run "[CI-ERROR-RELEASE-0027]" "tag=\"${tag}\" url=\"${url}\" reason=\"release tag push failed\"" \
        _ci_pat_git push "${url}" "refs/tags/${tag}" || return 2
    # What: the remote tag must peel to the cut commit
    # Why: AG-WF-031: every GitHub write is read back
    # From: Issue #1683 | PR #1858
    raw="$(_ci_capture 0 _ci_pat_git ls-remote --tags "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return 2
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
    head="$(_ci_head_commit)" || return 2
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

# What: release tags GC keeps: newest lines + migrations.
# Why: lines are counted as they exist, 19.9 or 18.88.
# From: Issue #1683 | PR #1858
_ci_gc_release_tags() {
    local n tags t line prev="" lines="" keep mig
    n="$(_ci_block_entry_field release retention keep_release_lines)" || return 2
    case "${n}" in
        ''|*[!0-9]*|0*)
            ci_log "[CI-ERROR-GC-0042]" "value=\"${n}\" reason=\"keep_release_lines not a positive integer\""
            return 2
            ;;
    esac
    tags="$(_ci_release_tags)" || return 2
    # What: vX.Y lines in version order, newest last.
    # Why: sorted tags group each line; one pass dedups.
    # From: Issue #1683 | PR #1858
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        line="${t%.*}"
        [ "${line}" = "${prev}" ] || lines="${lines}${line}"$'\n'
        prev="${line}"
    done <<<"${tags}"
    keep="$(awk -v n="${n}" 'NF { l[++c] = $0 } END { for (i = c - n + 1; i <= c; i++) if (i > 0) print l[i] }' <<<"${lines}")"
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        case $'\n'"${keep}"$'\n' in
            *$'\n'"${t%.*}"$'\n'*) printf '%s\n' "${t}" ;;
        esac
    done <<<"${tags}"
    mig="$(_ci_block_entry_list release retention migration_releases)" || return 2
    # What: a migration entry must be a plain vX.Y.Z tag.
    # Why: a typo would silently protect nothing.
    # From: Issue #1683 | PR #1858
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        _ci_release_tag_final "${t}" || {
            [ "$?" -eq 1 ] || return 2
            ci_log "[CI-ERROR-GC-0043]" "tag=\"${t}\" reason=\"migration_releases entry is not a plain vX.Y.Z tag\""
            return 2
        }
        printf '%s\n' "${t}"
    done <<<"${mig}"
}

# What: Emit the transitive protected-root digest set.
# Why: Ledger + channels + their index children (§75).
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
    local targets targets_rc=0 reltags
    targets="$(ci_build_targets)" || targets_rc=$?
    _ci_producer_ok "${targets_rc}" 0 || return 2
    reltags="$(_ci_gc_release_tags)" || return 2
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
            [ "${prc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0013]" "service=\"${svc}\" tag=\"${channel}\" reason=\"channel or release tag probe UNKNOWN; refusing roots\""; return 2; }
            [ "${prc}" -eq 0 ] && pairs="${pairs}"$'\n'"${svc}"$'\t'"${dig}"
        # What: kept release tags share the channel probe.
        # Why: one probe owner for every protected tag.
        # From: Issue #1683 | PR #1858
        done <<<"${produced}"$'\n'"${reltags}"
        # What: each layer cache tag of a target is a root.
        # Why: §35 cache is live; §77 owns its GC.
        # From: Issue #1683 | PR #1912
        local plats plat cref
        plats="$(_ci_platforms "${svc}")" || return 2
        while IFS= read -r plat; do
            [ -n "${plat}" ] || continue
            cref="$(_ci_build_cache_ref "${svc}" "${plat}")" || return 2
            prc=0
            dig="$(_ci_registry_probe "${cref}")" || prc=$?
            [ "${prc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0035]" "ref=\"${cref}\" reason=\"cache probe UNKNOWN; refusing roots\""; return 2; }
            [ "${prc}" -eq 0 ] && pairs="${pairs}"$'\n'"${svc}"$'\t'"${dig}"
        done <<<"${plats}"
    done <<<"${targets}"
    pairs="$(printf '%s\n' "${pairs}" | awk 'NF>0' | LC_ALL=C sort -u)"
    while IFS=$'\t' read -r s d; do
        [ -n "${d}" ] || continue
        out="${out}${d}"$'\n'
        rc=0
        local kids kid
        kids="$(_ci_index_children "${base}/${s}@${d}")" || rc=$?
        # What: a failed child read refuses the run.
        # Why: Dropping children orphan-deletes arches.
        # From: Issue #1683
        [ "${rc}" -eq 2 ] && { ci_log "[CI-ERROR-GC-0014]" "service=\"${s}\" digest=\"${d}\" reason=\"index child read UNKNOWN; refusing roots\""; return 2; }
        [ "${rc}" -eq 0 ] || continue
        while IFS= read -r kid; do
            out="${out}${kid#*=}"$'\n'
        done <<< "${kids}"
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
        _ci_text_has -i 'HTTP 404|Not Found' "${out}" && return 1
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
        # Why: a target never published has no package yet.
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
    # What: a DELETE answered with 404 reached the goal.
    # Why: the version vanished between listing and delete.
    # From: Issue #1683 | PR #1912
    rc=0; out="$(_ci_retry github-api gh api -X DELETE "${path}")" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        case "${out,,}" in
            *"http 404"*)
                ci_log "[CI-INFO-GC-0034]" "candidate=\"${candidate}\" reason=\"version already gone; goal reached\""
                return 0 ;;
        esac
        return 2
    fi
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

# What: the two words a reachability probe may answer.
# Why: probe and classifier share one spelling.
# From: Issue #1683 | PR #1912
readonly _CI_GC_REFERENCED=referenced _CI_GC_UNREACHABLE=unreachable

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
    # What: An attestation is live iff its subject is.
    # Why: sha256-<subj> referrers guard live provenance.
    # From: Issue #1683
    local tags tag subj root_hit
    local -a probes=("${digest}")
    tags="$(printf '%s' "${candidate}" | awk -F'\t' '{print $4}')"
    if [ -n "${tags}" ]; then
        while IFS= read -r tag; do
            case "${tag}" in
                sha256-*)
                    subj="sha256:${tag#sha256-}"; probes+=("${subj%%.*}")
                    ;;
            esac
        done <<< "${tags//,/$'\n'}"
    fi
    for subj in "${probes[@]}"; do
        root_hit="$(_ci_capture 1 grep -xF -- "${subj}" "${CI_GC_ROOTS_FILE}")" || return 2
        [ -z "${root_hit}" ] || { printf '%s\n' "${_CI_GC_REFERENCED}"; return 0; }
    done
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
    [ "${created_epoch}" -ge "${floor}" ] && { printf '%s\n' "${_CI_GC_REFERENCED}"; return 0; }
    printf '%s\n' "${_CI_GC_UNREACHABLE}"
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
        "${_CI_GC_REFERENCED}") printf 'KEEP\n' ;;
        "${_CI_GC_UNREACHABLE}") printf 'DELETE\n' ;;
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
    ci_log "[CI-INFO-GC-0030]" "mode=${mode} roots=$(_ci_count_lines "${roots}") reason=\"protected roots materialized\""
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

# What: delete ref $2 at $3 on $1; it must be gone after.
# Why: AG-WF-031: check, never assume; one GC deleter.
# From: Issue #1683 | PR #1858
_ci_gc_ref_reap() {
    local remote="$1" ref="$2" sha="$3" out rc=0
    if ! _ci_ref_delete "${remote}" "${ref}" "${sha}"; then
        ci_log "[CI-ERROR-GC-0039]" "ref=\"${ref}\" reason=\"ref delete failed (raw above)\""
        return 2
    fi
    out="$(_ci_cas_ref_sha "${remote}" "${ref}")" || rc=$?
    case "${rc}" in
        1) return 0 ;;
        0)
            ci_log "[CI-ERROR-GC-0040]" "ref=\"${ref}\" sha=\"${out}\" reason=\"ref still present after the delete\""
            return 2
            ;;
        *) return 2 ;;
    esac
}

# What: delete green refs of closed PRs, ended locks.
# Why: nothing else deletes them; dry-run only lists.
# From: Issue #1683 | PR #1858
ci_cmd_gc_refs() {
    local mode="dry-run" arg remote prefix repo refs sha ref n state holder rc keep=0 del=0 deleted=0
    local build_lock promote_lock
    for arg in "$@"; do
        case "${arg}" in
            --apply) mode="apply" ;;
            *)
                ci_log "[CI-ERROR-GC-0036]" "arg=\"${arg}\" reason=\"unknown gc-refs argument\""
                return 2
                ;;
        esac
    done
    remote="$(_ci_git_remote)" || return 2
    prefix="$(_ci_variable CI_GREEN_REF)" || return 2
    repo="$(_ci_env_required GITHUB_REPOSITORY)" || return 2
    refs="$(_ci_capture 0 git ls-remote --refs "${remote}" "${prefix}/*")" || return 2
    while IFS=$'\t' read -r sha ref; do
        [ -n "${ref}" ] || continue
        n="${ref#"${prefix}/pr-"}"
        if [[ ! "${n}" =~ ^[1-9][0-9]*$ ]]; then
            ci_log "[CI-ERROR-GC-0037]" "ref=\"${ref}\" reason=\"not of the form ${prefix}/pr-<number>\""
            return 2
        fi
        if ! state="$(_ci_retry github-read gh api --jq .state "repos/${repo}/pulls/${n}")"; then
            ci_error "[CI-ERROR-GC-0038]" "ref=\"${ref}\" pr=${n} reason=\"PR state not readable\"" "${state}"
            return 2
        fi
        case "${state}" in
            open)
                keep=$((keep + 1))
                printf 'gc-refs ref=%s pr=%s state=open action=KEEP\n' "${ref}" "${n}"
                ;;
            closed)
                del=$((del + 1))
                printf 'gc-refs ref=%s pr=%s state=closed action=DELETE mode=%s\n' "${ref}" "${n}" "${mode}"
                [ "${mode}" = apply ] || continue
                _ci_gc_ref_reap "${remote}" "${ref}" "${sha}" || return 2
                deleted=$((deleted + 1))
                ;;
            *)
                ci_log "[CI-ERROR-GC-0041]" "ref=\"${ref}\" pr=${n} state=\"${state}\" reason=\"unknown PR state; neither kept nor deleted\""
                return 2
                ;;
        esac
    done <<< "${refs}"
    # What: build and promote locks whose holder run ended.
    # Why: a lost runner never frees its own lock.
    # From: Issue #1683 | PR #1858
    build_lock="$(_ci_variable CI_BUILD_LOCK_REF)" || return 2
    promote_lock="$(_ci_required_field release promote_lock_ref block)" || return 2
    for prefix in "${build_lock}" "${promote_lock}"; do
        refs="$(_ci_capture 0 git ls-remote --refs "${remote}" "${prefix}/*")" || return 2
        while IFS=$'\t' read -r sha ref; do
            [ -n "${ref}" ] || continue
            holder="$(_ci_ref_subject "${remote}" "${ref}" 1)" || return 2
            rc=0; _ci_lock_holder_ended "${holder}" || rc=$?
            case "${rc}" in
                0)
                    del=$((del + 1))
                    printf 'gc-refs ref=%s holder="%s" state=ended action=DELETE mode=%s\n' "${ref}" "${holder}" "${mode}"
                    [ "${mode}" = apply ] || continue
                    _ci_gc_ref_reap "${remote}" "${ref}" "${sha}" || return 2
                    deleted=$((deleted + 1))
                    ;;
                1)
                    keep=$((keep + 1))
                    printf 'gc-refs ref=%s holder="%s" state=running action=KEEP\n' "${ref}" "${holder}"
                    ;;
                *)
                    ci_log "[CI-ERROR-GC-0044]" "ref=\"${ref}\" holder=\"${holder}\" reason=\"holder run state unknown; neither kept nor deleted\""
                    return 2
                    ;;
            esac
        done <<< "${refs}"
    done
    printf 'gc-refs result=classified keep=%s delete=%s deleted=%s mode=%s\n' "${keep}" "${del}" "${deleted}" "${mode}"
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

# What: compose service of a validation role (dns, proxy).
# Why: AG-CI-006: a service name has one owner, the SOT.
# From: Issue #1683 | PR #1858
_ci_validation_service() {
    local svc keys
    svc="$(_ci_block_entry_field validation "" "${1}_service")" || return 2
    keys="$(_ci_block_keys services)" || return 2
    if ! _ci_list_has "${svc}" "${keys}"; then
        ci_error "[CI-ERROR-VALIDATE-0137]" "role=\"${1}\" service=\"${svc}\" reason=\"validation role names no SOT product service\"" "${keys}"
        return 2
    fi
    printf '%s\n' "${svc}"
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

# What: Fail on candidates without a first-party image.
# Why: AG-VAL-001: an unvalidated digest is no pass.
# From: Issue #1683 | PR #1858
_ci_validate_report_unpinned() {
    local candidate="$1" matched="$2" slug _digest rc=0
    while IFS='=' read -r slug _digest; do
        [ -n "${slug}" ] || continue
        case "${matched}" in
            *" ${slug} "*) : ;;
            *)
                ci_log "[CI-ERROR-VALIDATE-0008]" "unpinned=\"${slug}\" reason=\"candidate service has no first-party image in compose\""
                rc=2
                ;;
        esac
    done <<< "${candidate}"
    return "${rc}"
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
        [ -n "${svc}" ] || continue
        [ -n "${image}" ] || continue
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

# What: Derive a collision-free slot in the SOT pool.
# Why: CI_VALIDATE_SUBNET_POOL sets the slot count.
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
    base="$(_ci_ipv4_to_int "${pool%/*}")" || return 2
    base=$(( base >> (32 - plen) << (32 - plen) ))
    h="$(printf '%s' "${seed}" | _ci_sha256_hex)" || return 2
    printf '%s/%s' "$(_ci_int_to_ipv4 $(( base + (16#${h:0:8} % (1 << (slot - plen))) * (1 << (32 - slot)) )))" "${slot}"
}

# What: the host dir this job container shares, checked.
# Why: the daemon binds host paths; unmounted is wrong.
# From: Issue #1683 | PR #1912
_ci_validate_shared_dir() {
    local dir
    dir="$(_ci_variable CI_VALIDATE_SHARED_DIR)" || return 2
    local mrc=0
    _ci_file_match "[CI-ERROR-VALIDATE-0130]" "dir=\"${dir}\"" /proc/self/mountinfo " ${dir} " -F || mrc=$?
    case "${mrc}" in
        0) ;;
        1)
            ci_log "[CI-ERROR-VALIDATE-0118]" "dir=\"${dir}\" reason=\"not a mount of this container; the job must mount it at the same path\""
            return 2
            ;;
        *) return 2 ;;
    esac
    printf '%s' "${dir}"
}

# What: copy the compose dir and repo bind sources to a dir.
# Why: relative binds must name host paths it has.
# From: Issue #1683 | PR #1912
_ci_validate_stage() {
    local dest="$1" file cfg srcs rel out
    file="$(_ci_compose_file)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    if ! srcs="$(jq -r --arg root "${CI_REPO_ROOT}/" \
        '.services[].volumes[]? | select(.type == "bind") | .source | select(startswith($root)) | ltrimstr($root)' <<< "${cfg}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0119]" "file=\"${file}\" reason=\"compose bind sources unreadable\"" "${srcs}"
        return 2
    fi
    srcs="$(printf '%s\n%s\n' "$(dirname "${file}")" "${srcs}" | sort -u)"
    while IFS= read -r rel; do
        [ -n "${rel}" ] || continue
        if [ -d "${CI_REPO_ROOT}/${rel}" ]; then
            out="$(mkdir -p "${dest}/${rel}" && cp -a "${CI_REPO_ROOT}/${rel}/." "${dest}/${rel}/" 2>&1)" || {
                ci_error "[CI-ERROR-VALIDATE-0121]" "path=\"${rel}\" reason=\"bind source dir not copied\"" "${out}"
                return 2
            }
        elif [ -e "${CI_REPO_ROOT}/${rel}" ]; then
            out="$(mkdir -p "${dest}/$(dirname "${rel}")" && cp -a "${CI_REPO_ROOT}/${rel}" "${dest}/${rel}" 2>&1)" || {
                ci_error "[CI-ERROR-VALIDATE-0123]" "path=\"${rel}\" reason=\"bind source file not copied\"" "${out}"
                return 2
            }
        else
            out="$(mkdir -p "${dest}/${rel}" 2>&1)" || {
                ci_error "[CI-ERROR-VALIDATE-0124]" "path=\"${rel}\" reason=\"missing bind source dir not created\"" "${out}"
                return 2
            }
        fi
    done <<< "${srcs}"
}

# What: join this job container to the stack's network.
# Why: the checks dial container IPs of the /27 bridge.
# From: Issue #1683 | PR #1912
_ci_validate_attach() {
    local project="$1" out
    out="$(docker network connect "${project}_default" "$(hostname)" 2>&1)" || {
        ci_error "[CI-ERROR-VALIDATE-0120]" "network=\"${project}_default\" reason=\"job container not joined to the stack network\"" "${out}"
        return 2
    }
}

# What: leave the stack's network; gone or left is fine.
# Why: compose down cannot remove a network in use.
# From: Issue #1683 | PR #1912
_ci_validate_detach() {
    local project="$1" out
    out="$(docker network disconnect -f "${project}_default" "$(hostname)" 2>&1)" && return 0
    case "${out}" in
        *"not found"*|*"is not connected"*) return 0 ;;
    esac
    ci_error "[CI-ERROR-VALIDATE-0122]" "network=\"${project}_default\" reason=\"job container not removed from the stack network\"" "${out}"
    return 2
}

# What: Host-lock one /27; print the holder pid.
# Why: Per-slot flock; runs never share a /27.
# From: Issue #1683
_ci_validate_slot_lock() {
    local subnet="$1" root key holder out errf hmsg hfail ack="" rfd wfd hrc=0
    root="$(_ci_validate_shared_dir)" || return 2
    root="${root}/locks"
    key="$(printf '%s' "${subnet}" | tr './' '__')"
    if ! out="$(mkdir -p "${root}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0072]" "dir=\"${root}\" reason=\"slot lock dir not created\"" "${out}"
        return 2
    fi
    errf="${root}/${key}.err"
    # What: holder says "held" after flock; stderr to file
    # Why: read waits for it or its exit; no guessed pause
    # From: Issue #1683 | PR #1912
    coproc HOLDER {
        exec 2>"${errf}"
        exec 9>"${root}/${key}.lock"
        flock -n 9 || exit 1
        printf 'held\n'
        exec sleep infinity
    }
    holder="${HOLDER_PID}" rfd="${HOLDER[0]}" wfd="${HOLDER[1]}"
    exec {wfd}>&-
    if ! read -r -u "${rfd}" ack; then
        ack=""
    fi
    exec {rfd}<&-
    if [ "${ack}" = held ]; then
        rm -f "${errf}"
        printf '%s\n' "${holder}"
        return 0
    fi
    # What: reap the dead lock holder; keep its exit status.
    # Why: the status and its stderr join the error raw.
    # From: Issue #1683 | PR #1858
    wait "${holder}" || hrc=$?
    hfail=0
    [ ! -s "${errf}" ] || hfail=1
    hmsg="$(cat "${errf}")"
    rm -f "${errf}"
    if [ "${hfail}" -eq 1 ]; then
        ci_error "[CI-ERROR-VALIDATE-0073]" "subnet=\"${subnet}\" lock=\"${root}/${key}.lock\" holder_rc=${hrc} reason=\"slot lock holder failed\"" "${hmsg}"
        return 2
    fi
    return 1
}

# What: Release a held validate slot lock.
# Why: Frees the mutex; safe if already gone.
# From: Issue #1683
_ci_validate_release() {
    local holder="${1:-}" out
    [ -n "${holder}" ] || return 0
    # What: stop the holder; a gone holder is not an error.
    # Why: only a holder still alive after a failed kill is.
    # From: Issue #1683 | PR #1858
    if ! out="$(kill "${holder}" 2>&1)" && [ -e "/proc/${holder}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0128]" "pid=${holder} reason=\"slot lock holder not stopped\"" "${out}"
        return 2
    fi
}

# What: Convert an IPv4 address to an integer.
# Why: Integer masking proves a /27 overlap.
# From: Issue #1683
_ci_ipv4_to_int() {
    local a b c d o
    IFS=. read -r a b c d <<< "$1"
    # What: four octets 0-255, else a coded stop.
    # Why: bad input would give a wrong base address.
    # From: Issue #1683 | PR #1858
    for o in "${a}" "${b}" "${c}" "${d}"; do
        if ! [[ "${o}" =~ ^[0-9]{1,3}$ ]] || [ "$(( 10#${o} ))" -gt 255 ]; then
            ci_log "[CI-ERROR-VALIDATE-0140]" "ip=\"$1\" reason=\"not an IPv4 dotted quad\""
            return 2
        fi
    done
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
    tip="$(_ci_ipv4_to_int "${target%/*}")" || return 2
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
                    sip="$(_ci_ipv4_to_int "${sub%/*}")" || return 2
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
    local file
    local -a pf=()
    file="$(_ci_compose_file)" || return 2
    _ci_compose_profile_flags "${file}" pf || return 2
    _ci_run "[CI-ERROR-VALIDATE-0086]" "file=\"${file}\" profiles=\"${pf[*]}\" reason=\"docker compose config failed\"" \
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
    local subnet="$1" svc svcs base cfg nets net slot half quarter i=0
    svcs="$(_ci_validate_startable)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    if ! nets="$(jq -r '.networks // {} | keys[] | select(. != "default")' <<< "${cfg}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0067]" "reason=\"compose networks unreadable\"" "${nets}"
        return 2
    fi
    # What: default /28 plus one /29 per other network.
    # Why: an auto /16 pool could swallow the /27 slot.
    # From: Issue #1683 | PR #1858
    base="$(_ci_ipv4_to_int "${subnet%/*}")" || return 2
    slot="${subnet#*/}"
    half=$(( 1 << (31 - slot) ))
    quarter=$(( half / 2 ))
    printf 'networks:\n  default:\n    ipam:\n      config:\n        - subnet: %s/%s\n' \
        "$(_ci_int_to_ipv4 "${base}")" "$(( slot + 1 ))"
    while IFS= read -r net; do
        [ -n "${net}" ] || continue
        if [ "${i}" -ge 2 ]; then
            ci_log "[CI-ERROR-VALIDATE-0068]" "network=\"${net}\" reason=\"more than 2 extra compose networks; the /${slot} holds 2\""
            return 2
        fi
        printf '  %s:\n    ipam:\n      config:\n        - subnet: %s/%s\n' "${net}" \
            "$(_ci_int_to_ipv4 $(( base + half + quarter * i )))" "$(( slot + 2 ))"
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
    # What: an empty service name stops here.
    # Why: compose ps with "" lists every container.
    # From: Issue #1683 | PR #1858
    if [ -z "${svc}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0138]" "project=\"${project}\" reason=\"empty compose service name\""
        return 2
    fi
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

# What: Remove one validation network safely.
# Why: Containers go first; a stale net poisons reruns.
# From: Issue #1683 | PR #1858
_ci_validate_network_teardown() {
    local net_id="$1" name out
    if ! name="$(docker network inspect "${net_id}" --format '{{.Name}}' 2>&1)"; then
        _ci_validate_network_gone "${net_id}" "${name}"
        return "$?"
    fi
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
    _ci_validate_detach "${project}" || rc=2
    # What: no compose file: skip down, sweep leftovers.
    # Why: the label sweep frees the slot without the file.
    # From: Issue #1683 | PR #1858
    if compose="$(_ci_compose_file)"; then
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
        if ! base="$(_ci_base_image alpine "[CI-ERROR-VALIDATE-0102]" "key=\"base_images.alpine\" reason=\"no alpine base to clear the state root\"")"; then
            rc=2
        elif ! out="$(_ci_bounded_run "${LANCACHE_STATE_DIR}:/s" "${base}" \
                find /s -mindepth 1 -delete 2>&1 && rmdir "${LANCACHE_STATE_DIR}" 2>&1)"; then
            ci_error "[CI-ERROR-VALIDATE-0061]" "reason=\"per-run state root not removed\"" "${out}"
            rc=2
        fi
    fi
    _ci_validate_release "${holder}" || rc=2
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
    _ci_validate_compose "${project}" "${net_override}" "${pin_override}" up -d "${svcs[@]}"
}

# What: docker compose on the validate stack with its args.
# Why: up and run share one file, override and profile list.
# From: Issue #763 | PR #1858
_ci_validate_compose() {
    local project="$1" net_override="$2" pin_override="$3" file
    local -a pf=()
    shift 3
    file="$(_ci_compose_file)" || return 2
    _ci_compose_profile_flags "${file}" pf || return 2
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

# What: Wait for one container's health verdict or death.
# Why: Docker events end the wait; no guessed deadline.
# From: Issue #1683 | PR #1912
_ci_validate_wait_one() {
    local project="$1" svc="$2" cid
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    if [ -z "${cid}" ]; then
        ci_log "[CI-INFO-VALIDATE-0078]" "service=\"${svc}\" reason=\"no running container after up\""
        return 1
    fi
    _ci_validate_wait_cid "${svc}" "${cid}"
}

# What: Health verdict of one container id or name.
# Why: run containers are not in wait_healthy's list.
# From: Issue #1683 | PR #1912
_ci_validate_wait_cid() (
    local svc="$1" cid="$2" created action pid raw=""
    created="$(_ci_capture 0 docker inspect --format '{{.Created}}' "${cid}")" || return 2
    # What: replay from creation, then follow live.
    # Why: a verdict before the subscribe is not lost.
    # From: Issue #1683 | PR #1912
    coproc EVENTS { exec docker events --since "${created}" --filter "container=${cid}" \
        --filter event=health_status --filter event=die --format '{{.Action}}' 2>&1; }
    pid="${EVENTS_PID}"
    while IFS= read -r action <&"${EVENTS[0]}"; do
        case "${action}" in
            "health_status: healthy")
                kill "${pid}"
                return 0
                ;;
            "health_status: unhealthy" | die)
                kill "${pid}"
                ci_log "[CI-INFO-VALIDATE-0077]" "service=\"${svc}\" container=\"${cid}\" event=\"${action}\" reason=\"unhealthy or exited before healthy\""
                return 1
                ;;
            *) raw+="${action}"$'\n' ;;
        esac
    done
    ci_error "[CI-ERROR-VALIDATE-0079]" "service=\"${svc}\" container=\"${cid}\" reason=\"docker events ended without a verdict\"" "${raw}"
    return 2
)

# What: Wait for every started service's health verdict.
# Why: A service without healthcheck has no crash proof.
# From: Issue #1683 | PR #1912
_ci_validate_wait_healthy() {
    local project="$1" services no_health svc rc=0 i
    services="$(_ci_validate_health_services)" || return 2
    no_health="$(_ci_validate_no_health_services)" || return 2
    if [ -n "${no_health}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0080]" "reason=\"started service(s) without healthcheck (AG-VAL-027)\"" "${no_health}"
        return 1
    fi
    local -a pids=() names=()
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        _ci_validate_wait_one "${project}" "${svc}" &
        pids+=("$!"); names+=("${svc}")
    done <<< "${services}"
    local wrc
    for i in "${!pids[@]}"; do
        wrc=0; wait "${pids[$i]}" || wrc=$?
        case "${wrc}" in
            0) ;;
            1)
                ci_error "[CI-ERROR-VALIDATE-0009]" "service=\"${names[$i]}\" reason=\"not healthy (cause above)\"" \
                    "$(_ci_validate_service_evidence "${project}" "${names[$i]}")"
                rc=1
                ;;
            *)
                ci_log "[CI-ERROR-VALIDATE-0081]" "service=\"${names[$i]}\" rc=${wrc} reason=\"health state unknown (docker error above)\""
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
    if [ -z "${svc}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0139]" "project=\"${project}\" reason=\"empty compose service name\""
        return 2
    fi
    cid="$(docker compose -p "${project}" ps -aq "${svc}" 2>&1)"
    printf 'container=%s\n' "${cid:-<none>}"
    [ -n "${cid}" ] && docker inspect --format '{{json .State}}' "${cid}" 2>&1
    docker compose -p "${project}" logs --no-color "${svc}" 2>&1
}

# What: dns container port of one side, from compose.
# Why: one dns container; each side is its own port.
# From: Issue #1683 | PR #1912
_ci_validate_dns_port() {
    local side="$1" cfg dport port
    cfg="$(_ci_validate_config_json)" || return 2
    dport="$(_ci_runtime_default DNS_PORT)" || return 2
    port="$(_ci_capture 0 jq -r --arg v "${side}" --arg p "${dport}" "$(cat <<'PROG'
        .services.dns as $s | ($s.environment[$v] // "") as $ip
        | [$s.ports[]? | select($ip != "" and .host_ip == $ip
            and .published == $p and .protocol == "udp") | .target]
        | unique[]
PROG
        )" <<<"${cfg}")" || return 2
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        ci_error "[CI-ERROR-VALIDATE-0116]" "side=\"${side}\" reason=\"not one dns udp port for this side\"" "${port}"
        return 2
    fi
    printf '%s\n' "${port}"
}

# What: Prove DNS resolves a CDN domain and split-routes.
# Why: Real dig on both sides; the answers MUST differ.
# From: Issue #1683 | PR #1912
_ci_validate_dns() {
    local project="$1" ip domain side port out a_http=""
    ip="$(_ci_validate_container_ip "${project}" "$(_ci_validation_service dns)")"
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0010]" "reason=\"missing dns container IP or test domain\""
        return 2
    fi
    for side in IP_HTTP IP_HTTPS; do
        port="$(_ci_validate_dns_port "${side}")" || return 2
        out="$(_ci_run -s "[CI-ERROR-VALIDATE-0117]" "domain=\"${domain}\" side=\"${side}\" reason=\"dig failed\"" \
            _ci_validate_dig +short -p "${port}" "@${ip}" A "${domain}")" || return 2
        out="$(sort -u <<<"${out}")"
        if [ -z "${out}" ]; then
            ci_log "[CI-ERROR-VALIDATE-0011]" "domain=\"${domain}\" side=\"${side}\" reason=\"no DNS answer from a resolver side\""
            return 1
        fi
        # What: http and https sides resolve distinct IPs.
        # Why: each side answers with its own proxy IP.
        # From: Issue #668
        if [ "${side}" = IP_HTTP ]; then
            a_http="${out}"
        elif [ "${out}" = "${a_http}" ]; then
            ci_log "[CI-ERROR-VALIDATE-0021]" "domain=\"${domain}\" reason=\"http and https DNS returned the same answer (split routing lost)\""
            return 1
        fi
    done
}

# What: Prove the proxy caches: real MISS then HIT.
# Why: Real cache behavior, not a port probe (AG-VAL-014).
# From: Issue #1683 | PR #1858
_ci_validate_proxy() {
    local project="$1" url ip_std host h1 h2 port
    port="$(_ci_runtime_default PROXY_HTTP_PORT)" || return 2
    url="$(_ci_validation_proxy_probe_url)" || return 2
    ip_std="$(_ci_validate_container_ip "${project}" "$(_ci_validation_service proxy)")"
    host="${url#http://}"; host="${host%%/*}"
    if [ -z "${ip_std}" ] || [ -z "${host}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0012]" "url=\"${url}\" reason=\"missing proxy container IP or probe host\"" "${ip_std}"
        return 2
    fi
    if ! h1="$(curl -fsS --resolve "${host}:${port}:${ip_std}" -D - "${url}" 2>&1)"; then
        ci_log "[CI-ERROR-VALIDATE-0013]" "url=\"${url}\" reason=\"proxy MISS request failed\""
        printf 'raw:\n%s\n' "${h1}"
        return 1
    fi
    if ! h2="$(curl -fsS --resolve "${host}:${port}:${ip_std}" -D - "${url}" 2>&1)"; then
        ci_log "[CI-ERROR-VALIDATE-0065]" "url=\"${url}\" reason=\"proxy repeat request failed\""
        printf 'raw:\n%s\n' "${h2}"
        return 1
    fi
    if ! _ci_text_has -i 'X-Cache-Status:[[:space:]]*HIT' "${h2}"; then
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
_ci_https_dispatch_violations() {
    local port="$1"
    awk -v want=":${port};" 'index($0, "~^.+\\.") > 0 && substr($NF, length($NF) - length(want) + 1) != want { print }'
}

# What: prove proxy routes wildcards by SNI.
# Why: root literal misroutes subdomains.
# From: Issue #1683
_ci_validate_proxy_stream_map() {
    local file port
    file="$(_ci_proxy_constant NGINX_STREAM_TARGETS)" || return 2
    port="$(_ci_runtime_default NGINX_ORIGIN_HTTPS_PORT)" || return 2
    _ci_validate_proxy_map "$1" "${file}" _ci_stream_map_violations "${port}" \
        "[CI-ERROR-VALIDATE-0022]" "no proxy container for stream-map check" \
        "[CI-ERROR-VALIDATE-0019]" "could not read proxy stream-target map" \
        "[CI-ERROR-VALIDATE-0020]" "stream-target wildcard forwards to a hardcoded root, not the requested SNI"
}

# What: read a proxy map; a filter prints its bad rows.
# Why: both SNI map checks share one read and verdict.
# From: Issue #1683 | PR #1912
_ci_validate_proxy_map() {
    local project="$1" file="$2" filter="$3" arg="$4" cid map bad
    cid="$(_ci_validate_cid "${project}" "$(_ci_validation_service proxy)")" || return 2
    if [ -z "${cid}" ]; then
        ci_log "$5" "reason=\"$6\""
        return 2
    fi
    if ! map="$(_ci_capture 0 _ci_bounded_exec "${cid}" cat "${file}")"; then
        ci_log "$7" "reason=\"$8\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | "${filter}" "${arg}")"
    if [ -n "${bad}" ]; then
        ci_error "$9" "reason=\"${10}\"" "${bad}"
        return 1
    fi
}

# What: Prove https mode intercepts (MITM) with our LAN CA.
# Why: the proxy https port must show a cert we signed
# From: Issue #1683
_ci_validate_https_mitm() {
    local project="$1" ip cid domain ca_subj issuer tmp out cert tls_err ca ca_file port
    ca="$(_ci_nginx_subdir NGINX_SUBDIR_CA)" || return 2
    ca_file="$(_ci_runtime_default CA_CERT_FILE)" || return 2
    port="$(_ci_runtime_default PROXY_HTTPS_PORT)" || return 2
    ip="$(_ci_validate_container_ip "${project}" "$(_ci_validation_service proxy)")"
    cid="$(_ci_validate_cid "${project}" "$(_ci_validation_service proxy)")" || return 2
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip}" ] || [ -z "${cid}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0023]" "reason=\"no proxy container/IP or test domain for https-mitm check\""
        return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-proxy-ca.XXXXXX")" || return 2
    if ! out="$(docker cp "${cid}:${ca}/${ca_file}" "${tmp}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0024]" "reason=\"could not read proxy LAN CA for https-mitm check\"" "${out}"
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
    cert="$(printf '' | openssl s_client -connect "${ip}:${port}" -servername "${domain}" 2>"${tls_err}")"
    issuer=""
    if [ -n "${cert}" ]; then
        issuer="$(openssl x509 -noout -issuer 2>>"${tls_err}" <<<"${cert}")"
        issuer="${issuer#issuer=}"
    fi
    if [ -z "${ca_subj}" ] || [ -z "${issuer}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0025]" "domain=\"${domain}\" reason=\"no TLS issuer or CA subject for https-mitm check\"" "$(cat "${tls_err}")"
        rm -f "${tls_err}"
        return 1
    fi
    rm -f "${tls_err}"
    # What: the https cert issuer MUST equal our own LAN CA.
    # Why: proves interception, not passthrough.
    # From: Issue #668
    if [ "${issuer}" != "${ca_subj}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0026]" "issuer=\"${issuer}\" ca=\"${ca_subj}\" reason=\"https mode :${port} cert not issued by our LAN CA (not intercepting)\""
        return 1
    fi
}

# What: https-mode depth-dispatch routes deeper SNI right.
# Why: depth>=2 SNI takes the passthrough relay, not MITM
# From: Issue #1683
_ci_validate_https_dispatch_map() {
    local file relay
    file="$(_ci_proxy_constant NGINX_HTTPS_DISPATCH)" || return 2
    relay="$(_ci_runtime_default NGINX_PASSTHROUGH_RELAY_PORT)" || return 2
    _ci_validate_proxy_map "$1" "${file}" _ci_https_dispatch_violations "${relay}" \
        "[CI-ERROR-VALIDATE-0027]" "no proxy container for https-dispatch-map check" \
        "[CI-ERROR-VALIDATE-0028]" "could not read proxy https-dispatch map (HTTPS_ENABLED=0?)" \
        "[CI-ERROR-VALIDATE-0029]" "depth>=2 SNI dispatch entry routes to MITM, not passthrough relay :${relay}"
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
    ports="$(_ci_capture 0 docker inspect -f "{{range \$p, \$v := .Config.ExposedPorts}}{{println \$p}}{{end}}" "${cid}")" || return 2
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
    local jar="$1" base="$2" page csrf last url
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0030]" "reason=\"no ui container IP for session check\""
        return 2
    fi
    url="${base}$(_ci_runtime_default UI_PAGE_DOMAINS)" || return 2
    # What: one try; wait_healthy already saw ui healthy.
    # Why: its healthcheck asks the same server; no poll.
    # From: Issue #1683 | PR #1912
    if ! last="$(curl -fsS -c "${jar}" "${url}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0031]" "url=\"${url}\" reason=\"ui page did not answer\"" "${last}"
        return 1
    fi
    page="$(_ci_capture 0 curl -fsS -b "${jar}" -c "${jar}" "${url}")" || return 2
    csrf="$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' <<< "${page}")"
    csrf="${csrf%%$'\n'*}"
    if [ -z "${csrf}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0032]" "url=\"${url}\" reason=\"no csrf_token field on the ui page\"" "${page}"
        return 1
    fi
    printf '%s' "${csrf}"
}

# What: new cookie jar plus ui session: sets $1 and $2.
# Why: one owner; three probes opened a session this way.
# From: Issue #1683 | PR #1912
_ci_validate_ui_login() {
    local -n _ci_ul_jar="$1" _ci_ul_csrf="$2"
    local _ci_ul_rc=0
    _ci_ul_jar="$(_ci_mktemp "${CI_TMPDIR}/ci-ui-jar.XXXXXX")" || return 2
    _ci_ul_csrf="$(_ci_validate_ui_session "${_ci_ul_jar}" "$3")" || _ci_ul_rc=$?
    [ "${_ci_ul_rc}" -eq 0 ] || rm -f "${_ci_ul_jar}"
    return "${_ci_ul_rc}"
}

# What: setup.sh args on a one-run .env.local; @INST@=dir.
# Why: ci.sh runs setup.sh commands; it loads none of it.
# From: Issue #1683 | PR #1858
_ci_setup_run() {   # out rc errfile ("" = merge) env args
    local -n _ci_su_out="$1" _ci_su_rc="$2"
    local _ci_su_err="$3" _ci_su_env="$4" _ci_su_c _ci_su_bin _ci_su_inst _ci_su_a
    local -a _ci_su_args=()
    shift 4
    _ci_su_rc=0
    _ci_su_c="$(_ci_compose_file)" || return 2
    case "${_ci_su_c}" in /*) ;; *) _ci_su_c="${CI_REPO_ROOT}/${_ci_su_c}" ;; esac
    _ci_su_bin="$(_ci_installer)" || return 2
    _ci_su_inst="$(dirname "${_ci_su_c}")"
    for _ci_su_a in "$@"; do
        [ "${_ci_su_a}" != @INST@ ] || _ci_su_a="${_ci_su_inst}"
        _ci_su_args+=("${_ci_su_a}")
    done
    _ci_validate_env_local "${_ci_su_inst}" "${_ci_su_env}" || return 2
    if [ -n "${_ci_su_err}" ]; then
        _ci_su_out="$(bash "${_ci_su_bin}" "${_ci_su_args[@]}" 2>"${_ci_su_err}")" || _ci_su_rc=$?
    else
        _ci_su_out="$(bash "${_ci_su_bin}" "${_ci_su_args[@]}" 2>&1)" || _ci_su_rc=$?
    fi
    rm -f "${_ci_su_inst}/.env.local"
}

# What: setup.sh rollback around a one-run .env.local.
# Why: one owner for the dns and Kea rollback legs.
# From: Issue #1683 | PR #1912
_ci_validate_setup_rollback() {
    local -n _ci_sr_out="$1" _ci_sr_rc="$2"
    local _ci_sr_env="$3" _ci_sr_svc="$4"
    shift 4
    _ci_sr_rc=0
    # What: the run's state root leads the one-run env file
    # Why: setup.sh reads the state root only from that file
    # From: Issue #1683 | PR #1912
    if [ -z "${LANCACHE_STATE_DIR:-}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0132]" "svc=\"${_ci_sr_svc}\" reason=\"no per-run LANCACHE_STATE_DIR to hand setup.sh\""
        return 2
    fi
    _ci_sr_env="LANCACHE_STATE_DIR=${LANCACHE_STATE_DIR}${_ci_sr_env:+$'\n'${_ci_sr_env}}"
    _ci_setup_run _ci_sr_out _ci_sr_rc "" "${_ci_sr_env}" \
        reset-to-last-known-good-config "${_ci_sr_svc}" @INST@ "$@" --yes
}

# What: POST one LAN A record through the ui (303 on ok)
# Why: drives the real UI->NATS->PowerDNS write path
# From: Issue #1683 | PR #1858
_ci_validate_ui_add_record() {
    local base="$1" jar="$2" csrf="$3" name="$4" content="$5" ttl route
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0033]" "reason=\"no ui container IP for add-record\""
        return 2
    fi
    ttl="$(_ci_variable CI_VALIDATE_PROBE_TTL)" || return 2
    # What: the LAN add route of the ui, from the SOT
    # Why: the zone name is not part of the route path
    # From: Issue #1683 | PR #1912
    route="$(_ci_runtime_default UI_ROUTE_LAN_ADD)" || return 2
    _ci_validate_ui_post "${base}" "${jar}" "${route}" "csrf_token=${csrf}" \
        "name=${name}" record_type=A "content=${content}" "ttl=${ttl}"
}

# What: POST a UI form; rc 0 on 303, 1 other, 2 on error.
# Why: one owner for the CSRF form post and its 303 check.
# From: Issue #1683 | PR #1858
_ci_validate_ui_post() {
    local base="$1" jar="$2" path="$3" field code body raw
    shift 3
    local -a data=()
    for field in "$@"; do
        data+=(--data-urlencode "${field}")
    done
    body="$(_ci_mktemp "${CI_TMPDIR}/ci-ui-body.XXXXXX")" || return 2
    code="$(_ci_capture 0 curl -sS -b "${jar}" -o "${body}" -w '%{http_code}' \
        "${data[@]}" "${base}${path}")" || {
        rm -f "${body}"
        ci_log "[CI-ERROR-VALIDATE-0082]" "url=\"${base}${path}\" reason=\"ui form post failed (raw above)\""
        return 2
    }
    if [ "${code}" != "303" ]; then
        raw="$(_ci_capture 0 cat "${body}")" || { rm -f "${body}"; return 2; }
        ci_error "[CI-ERROR-VALIDATE-0034]" "url=\"${base}${path}\" code=\"${code}\" reason=\"ui form post did not return 303; response body in raw\"" "${raw}"
        rm -f "${body}"
        return 1
    fi
    rm -f "${body}"
}

# What: the LAN zone (dotted) the dns side serves.
# Why: DHCP_DOMAIN of the stack env, else its SOT default.
# From: Issue #1683 | PR #1912
_ci_validate_lan_zone() {
    local env zone
    env="$(_ci_validation_env)" || return 2
    zone="$(_ci_capture 0 awk "index(\$0, \"DHCP_DOMAIN=\") == 1 { print substr(\$0, 13); exit }" <<< "${env}")" || return 2
    if [ -z "${zone}" ]; then
        zone="$(_ci_runtime_default DHCP_DOMAIN)" || return 2
    fi
    if [ -z "${zone}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0106]" "reason=\"no DHCP_DOMAIN in the stack env or the SOT runtime.defaults\""
        return 2
    fi
    printf '%s.\n' "${zone%.}"
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
    base="$(_ci_ipv4_to_int "${net%/*}")" || return 2
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

# What: dig with the SOT timeout and tries.
# Why: AG-CI-006: one owner for every dig timing value.
# From: Issue #1683 | PR #1858
_ci_validate_dig() {
    local wait tries
    wait="$(_ci_variable CI_VALIDATE_DIG_TIMEOUT)" || return 2
    tries="$(_ci_variable CI_VALIDATE_DIG_TRIES)" || return 2
    dig "+time=${wait}" "+tries=${tries}" "$@"
}

# What: Poll one dns side until <fqdn> is <expected>.
# Why: the NATS->PowerDNS write is async; prove it.
# From: Issue #1683 | PR #1912
_ci_validate_dns_resolves() {
    local project="$1" side="$2" fqdn="$3" expected="$4" attempts="$5" ip port
    ip="$(_ci_validate_container_ip "${project}" "$(_ci_validation_service dns)")"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0035]" "side=\"${side}\" reason=\"no dns IP for resolve check\""
        return 2
    fi
    port="$(_ci_validate_dns_port "${side}")" || return 2
    local out pause
    pause="$(_ci_variable CI_VALIDATE_POLL_PAUSE)" || return 2
    # What: the one poll owner repeats one dig compare.
    # Why: AG-CODE-011: no second poll loop in this file.
    # From: Issue #1683 | PR #1858
    out="$(_ci_validate_poll "${attempts}" "${pause}" _ci_validate_dns_match "${port}" "${ip}" "${fqdn}" "${expected}")" && return 0
    # What: full answer, zone SOA and the service's logs.
    # Why: +short hides NXDOMAIN vs empty vs SERVFAIL.
    # From: Issue #1683 | PR #1858
    ci_error "[CI-ERROR-VALIDATE-0036]" "side=\"${side}\" fqdn=\"${fqdn}\" expected=\"${expected}\" reason=\"record did not resolve as expected\"" \
        "last try:
${out}
full answer:
$(_ci_validate_dig -p "${port}" "@${ip}" A "${fqdn}" 2>&1)
zone SOA:
$(_ci_validate_dig +short -p "${port}" "@${ip}" SOA "${fqdn#*.}" 2>&1)
service:
$(_ci_validate_service_evidence "${project}" "$(_ci_validation_service dns)")"
    return 1
}

# What: one dig +short A answer against the expected set.
# Why: dig stderr stays out of the compared answer.
# From: Issue #1683 | PR #1858
_ci_validate_dns_match() {
    local port="$1" ip="$2" fqdn="$3" expected="$4" out got=""
    if out="$(_ci_validate_dig +short -p "${port}" "@${ip}" A "${fqdn}")"; then
        got="$(sort -u <<<"${out}")"
    fi
    [ "${got}" != "${expected}" ] || return 0
    printf 'got=%s\n' "${got}"
    return 1
}

# What: UI->NATS->PowerDNS writes reach both dns sides.
# Why: Real end-to-end NATS ingest, not a mock.
# From: Issue #1683 | PR #1912
_ci_validate_ui_nats_dns() {
    local project="$1" jar csrf cid base zone label ip dns_wait side rc=0
    cid="$(_ci_validate_cid "${project}" "$(_ci_validation_service ui)")" || return 2
    base="$(_ci_validate_ui_base "${project}" "${cid}")" || return $?
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    ip="$(_ci_validate_probe_ip 1)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    _ci_validate_ui_login jar csrf "${base}" || return $?
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${ip}" || rc=$?
    rm -f "${jar}"
    [ "${rc}" -eq 0 ] || return "${rc}"
    for side in IP_HTTP IP_HTTPS; do
        _ci_validate_dns_resolves "${project}" "${side}" "${label}.${zone}" "${ip}" "${dns_wait}" || return $?
    done
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
    _ci_capture 0 _ci_bounded_exec "${cid}" cat "${dir}/${name}"
}

# What: the SOT runtime.defaults rows, @KEY@ resolved.
# Why: ci.sh resolves them; setup.sh is the customer file.
# From: Issue #1683 | PR #1912
_ci_runtime_defaults() {
    local rows
    rows="$(_ci_required_field runtime defaults blocklist)" || return 2
    _ci_fill "${rows}" "${rows}" || { ci_log "[CI-ERROR-VALIDATE-0127]" "reason=\"runtime.defaults not resolved (error above)\""; return 2; }
    printf '%s\n' "${REPLY}"
}

# What: one key's value in a KEY=value row list.
# Why: a bash read; no sed fork per key in env loops.
# From: Issue #1683 | PR #1912
_ci_default_in() {
    local row val="" why="not in"
    while IFS= read -r row; do
        [[ "${row}" != "$2="* ]] || { val="${row#*=}"; why="empty in"; break; }
    done <<< "$1"
    # What: a missing key and an empty value read apart.
    # Why: an empty value must not send to add the key.
    # From: Issue #1683 | PR #1858
    if [ -z "${val}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0125]" "key=\"$2\" reason=\"${why} the SOT runtime.defaults\""
        return 2
    fi
    printf '%s' "${val}"
}

# What: one value of the SOT runtime.defaults list.
# Why: ports and timings have one owner; checks read it.
# From: Issue #1683 | PR #1912
_ci_runtime_default() {
    local list
    list="$(_ci_runtime_defaults)" || return 2
    _ci_default_in "${list}" "$1"
}

# What: REPLY = $1, each @KEY@ set from KEY=value rows $2.
# Why: the one @KEY@ replacer; a value may name another key.
# From: Issue #1683 | PR #1912
_ci_fill() {
    local text="$1" depth="${3:-0}" key pre out=""
    # What: the row table is built once, at the first level.
    # Why: a chained value reads it; no rescan per token.
    # From: Issue #1683 | PR #1912
    if [ "${depth}" -eq 0 ]; then
        local -A _ci_fv=()
        local row
        while IFS= read -r row; do
            [[ "${row}" == *=* ]] || continue
            [ -n "${_ci_fv[${row%%=*}]+x}" ] || _ci_fv["${row%%=*}"]="${row#*=}"
        done <<< "$2"
    fi
    if [ "${depth}" -gt 16 ]; then
        ci_log "[CI-ERROR-CORE-0156]" "text=\"$1\" reason=\"an @KEY@ value refers to itself\""
        return 2
    fi
    while [[ "${text}" =~ @([A-Z][A-Z0-9_]*)@ ]]; do
        key="${BASH_REMATCH[1]}"
        if [ -z "${_ci_fv[${key}]+x}" ]; then
            ci_log "[CI-ERROR-CORE-0155]" "key=\"${key}\" text=\"${text}\" reason=\"@KEY@ names no row\""
            return 2
        fi
        pre="${text%%"@${key}@"*}"
        text="${text#*"@${key}@"}"
        _ci_fill "${_ci_fv[${key}]}" "" $((depth + 1)) || return 2
        out+="${pre}${REPLY}"
    done
    REPLY="${out}${text}"
}

# What: http://<dns ip>:<port> of the rollback listener
# Why: the port is the SOT runtime default, not a ui env
# From: Issue #628 | PR #1858
_ci_validate_rollback_base() {
    local ip="$1" port
    port="$(_ci_runtime_default DNS_ROLLBACK_PORT)" || return 2
    printf 'http://%s:%s' "${ip}" "${port}"
}

# What: writes a deploy/prod install's .env.local, mode 600.
# Why: setup.sh reads it; validate never overwrites one.
# From: Issue #763 | PR #1912
_ci_validate_env_local() {
    local inst="$1" content="$2"
    if [ -e "${inst}/.env.local" ]; then
        ci_log "[CI-ERROR-VALIDATE-0113]" "path=\"${inst}/.env.local\" reason=\"an .env.local exists; validate never overwrites it\""
        return 2
    fi
    if ! (umask 077 && printf '%s' "${content:+${content}$'\n'}" > "${inst}/.env.local"); then
        ci_log "[CI-ERROR-VALIDATE-0093]" "dir=\"${inst}\" reason=\"setup.sh .env.local not written\""
        rm -f "${inst}/.env.local"
        return 2
    fi
}

# What: DNS known-good snapshot/rollback round-trip.
# Why: Real listener HTTP + PATCH + cache flush.
# From: Issue #1683
_ci_validate_dns_rollback() {
    local project="$1" ip cid key jar csrf snap resp code rc=0 last
    local zone label old new dns_wait ucid base lbase tries pause decoy
    ip="$(_ci_validate_container_ip "${project}" "$(_ci_validation_service dns)")"
    cid="$(_ci_validate_cid "${project}" "$(_ci_validation_service dns)")" || return 2
    if [ -z "${ip}" ] || [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0037]" "reason=\"no dns container/IP for rollback check\""
        return 2
    fi
    # What: read PDNS_API_KEY from the shared-secrets mount.
    # Why: watchdog resolves it at runtime, not env.
    # From: Issue #858
    key="$(_ci_validate_shared_secret "${project}" "${cid}" pdns-api-key)" || return 2
    key="${key//$'\n'/}"
    if [ -z "${key}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0038]" "reason=\"could not read PDNS_API_KEY from shared-secrets\""
        return 2
    fi
    ucid="$(_ci_validate_cid "${project}" "$(_ci_validation_service ui)")" || return 2
    lbase="$(_ci_validate_rollback_base "${ip}")" || return 2
    # What: one try; dns healthy means the listener accepts.
    # Why: the healthcheck connects to it; no poll.
    # From: Issue #1683 | PR #1912
    if ! last="$(_ci_curl_secret header "X-API-Key: ${key}" -fsS "${lbase}/snapshots" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0039]" "url=\"${lbase}\" reason=\"rollback listener did not accept\"" "${last}"
        return 1
    fi
    resp="$(_ci_capture 0 curl -sS -w '\n%{http_code}' "${lbase}/snapshots")" || return 2
    code="${resp##*$'\n'}"
    if [ "${code}" != "401" ]; then
        ci_error "[CI-ERROR-VALIDATE-0040]" "code=\"${code}\" reason=\"/snapshots without X-API-Key not 401\"" "${resp}"
        return 1
    fi
    resp="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}x" -sS -w '\n%{http_code}' "${lbase}/snapshots")" || return 2
    code="${resp##*$'\n'}"
    if [ "${code}" != "401" ]; then
        ci_error "[CI-ERROR-VALIDATE-0041]" "code=\"${code}\" reason=\"/snapshots with wrong X-API-Key not 401\"" "${resp}"
        return 1
    fi
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    old="$(_ci_validate_probe_ip 2)" && new="$(_ci_validate_probe_ip 3)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    base="$(_ci_validate_ui_base "${project}" "${ucid}")" || return $?
    _ci_validate_ui_login jar csrf "${base}" || return $?
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${old}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${old}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    # What: capture the zone's newest snapshot (pre-change).
    # Why: target this test rolls back to after 2nd write.
    # From: Issue #628
    resp="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}" -sS "${lbase}/snapshots")" || { rm -f "${jar}"; return 2; }
    snap="$(_ci_capture 0 jq -r --arg z "${zone}" ".zones[\$z][0].id // empty" <<<"${resp}")" || { rm -f "${jar}"; return 2; }
    if [ -z "${snap}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0042]" "zone=\"${zone}\" reason=\"no known-good snapshot after first write\""
        rm -f "${jar}"
        return 1
    fi
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${new}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${new}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    rm -f "${jar}"
    resp="$(_ci_capture 0 _ci_curl_secret header "X-API-Key: ${key}" -sS "${lbase}/snapshots")" || return 2
    last="$(_ci_capture 0 jq -r --arg z "${zone}" ".zones[\$z][0].id // empty" <<<"${resp}")" || return 2
    # What: setup.sh rollback, wrong host PDNS_API_KEY.
    # Why: the key must be resolved inside the container.
    # From: Issue #836
    decoy="$(_ci_variable CI_VALIDATE_DECOY_API_KEY)" || return 2
    COMPOSE_PROJECT_NAME="${project}" PDNS_API_KEY="${decoy}" \
        _ci_validate_setup_rollback resp rc "" "$(_ci_validation_service dns)" "${zone}" "${snap}" || return 2
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
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${old}" "${dns_wait}" || return $?
    tries="$(_ci_variable CI_VALIDATE_SNAPSHOT_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_POLL_PAUSE)" || return 2
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
        | jq -e --arg p "$3" --arg z "$4" '(.zones[$z][0].id // "") as $i | $i != "" and $i != $p'
}

# What: http-port or user of the Kea control agent
# Why: the SOT runtime.defaults owns both; dhcp renders them
# From: Issue #763 | PR #1912
_ci_validate_kea_agent() {
    local field="$1"
    case "${field}" in
        http-port) _ci_runtime_default KEA_CTRL_PORT ;;
        user) _ci_runtime_default KEA_CTRL_USER ;;
        *) ci_log "[CI-ERROR-VALIDATE-0109]" "field=\"${field}\" reason=\"unknown Kea agent field\""; return 2 ;;
    esac
}

# What: One Kea Control Agent command; prints the reply.
# Why: the product API as the ui sends it; no setup.sh load
# From: Issue #763 | PR #1858
_ci_validate_kea_cmd() {
    _ci_run "[CI-ERROR-VALIDATE-0133]" "url=\"$1\" reason=\"Kea Control Agent command failed\"" \
        _ci_curl_secret user "$2:$3" --fail-with-body -sS -X POST -H 'Content-Type: application/json' -d "$4" "$1/"
}

# What: fail unless a Kea reply carries result 0
# Why: Kea answers per service; result 0 means success
# From: Issue #1683 | PR #1858
_ci_kea_reply_check() {
    local code
    if ! code="$(jq -r 'if type == "array" then .[0] else . end | .result' <<< "$3" 2>&1)" || [ "${code}" != 0 ]; then
        ci_error "$1" "$2 result=\"${code}\"" "$3"
        return 1
    fi
}

# What: Kea snapshot ids under <snapshot dir>, oldest first.
# Why: the rollback target is the id a ui write added.
# From: Issue #763 | PR #1858
_ci_validate_kea_snapshots() {
    local found p id file
    file="$(_ci_runtime_default KEA_CONFIG_SNAPSHOT_FILE)" || return 2
    if ! [[ "${file}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0197]" "key=\"KEA_CONFIG_SNAPSHOT_FILE\" value=\"${file}\" reason=\"SOT snapshot file name is no plain file name\""
        return 2
    fi
    found="$(_ci_capture 0 find "$1" -mindepth 2 -maxdepth 2 -name "${file}")" || return 2
    while IFS= read -r p; do
        id="${p%/"${file}"}"
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
    _ci_kea_reply_check "[CI-ERROR-VALIDATE-0131]" "mac=\"$4\" reason=\"Kea config-get did not return result 0\"" "${cfg}" || return 2
    _ci_capture 0 jq -r --arg m "$4" \
        "[.[0].arguments.Dhcp4.subnet4[].reservations[]? | select((.\"hw-address\" | ascii_downcase) == (\$m | ascii_downcase))] | length" \
        <<< "${cfg}"
}

# What: Add one reservation via the ui, print new snapshot.
# Why: every ui write must record exactly one new snapshot.
# From: Issue #763 | PR #1858
_ci_validate_kea_add() {
    local base="$1" jar="$2" csrf="$3" sid="$4" mac="$5" ip="$6" host="$7" dir="$8"
    local before after new route
    before="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    # What: the reservation add route, from the SOT
    # Why: the ui path has one owner, build-manifest.yml
    # From: Issue #1683 | PR #1912
    route="$(_ci_runtime_default UI_ROUTE_STATIC_ADD)" || return 2
    _ci_validate_ui_post "${base}" "${jar}" "${route}" "csrf_token=${csrf}" \
        "subnet_id=${sid}" "mac=${mac}" "ip=${ip}" "hostname=${host}" || return $?
    after="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    new="${after##*$'\n'}"
    if [ -z "${new}" ] || _ci_list_has "${new}" "${before}"; then
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
    local jar csrf base snap snap_b n_a n_b rc=0 kbase kuser label mac_a mac_b snapdir mount snaps
    kbase="http://${kip}:${kport}"
    kuser="$(_ci_validate_kea_agent user)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    mac_a="$(_ci_validate_probe_mac 1)" && mac_b="$(_ci_validate_probe_mac 2)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    token="$(_ci_capture 0 jq -r '.services.dhcp.environment.KEA_CTRL_TOKEN // empty' <<< "${cfg}")" || return 2
    snapdir="$(_ci_runtime_default KEA_CONFIG_SNAPSHOT_DIR)" || return 2
    # What: the dhcp mount holding KEA_CONFIG_SNAPSHOT_DIR
    # Why: its source is the Kea data dir on the host
    # From: Issue #763 | PR #1858
    mount="$(_ci_capture 0 jq -r --arg s "${snapdir}" "$(cat <<'PROG'
.services.dhcp.volumes[]? | .target as $t
        | select($t != "" and ($s | startswith($t + "/"))) | "\(.source)\t\($s | ltrimstr($t))"
PROG
        )" <<< "${cfg}")" || return 2
    subnet="$(_ci_capture 0 jq -r '.services.dhcp.environment.DHCP_SUBNET // empty' <<< "${cfg}")" || return 2
    if [ -z "${token}" ] || [ -z "${snapdir}" ] || [ -z "${mount}" ] || [[ "${mount}" == *$'\n'* ]] || [ -z "${subnet}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0089]" "reason=\"dhcp compose config lacks KEA_CTRL_TOKEN, one mount holding KEA_CONFIG_SNAPSHOT_DIR, or DHCP_SUBNET\"" "${mount}"
        return 2
    fi
    dir="${mount%%$'\t'*}"
    snaps="${dir}${mount#*$'\t'}"
    # What: one config-get; healthy dhcp means it accepts.
    # Why: the healthcheck connects to it; no poll.
    # From: Issue #1683 | PR #1912
    resp="$(_ci_capture 0 _ci_validate_kea_cmd "${kbase}" "${kuser}" "${token}" '{"command":"config-get","service":["dhcp4"]}')" || return 2
    _ci_kea_reply_check "[CI-ERROR-VALIDATE-0090]" "ip=\"${kip}\" reason=\"Kea control agent config-get did not return result 0\"" "${resp}" || return 1
    sid="$(_ci_capture 0 jq -r --arg s "${subnet}" ".[0].arguments.Dhcp4.subnet4[]? | select(.subnet == \$s) | .id" <<< "${resp}")" || return 2
    if [ -z "${sid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0091]" "subnet=\"${subnet}\" reason=\"no Kea subnet4 entry for DHCP_SUBNET\""
        return 1
    fi
    ubase="$(_ci_validate_ui_base "${project}" "${uname}")" || {
        rc=$?
        ci_log "[CI-ERROR-VALIDATE-0092]" "container=\"${uname}\" reason=\"no /27 IP for the Kea ui run container\""
        return "${rc}"
    }
    _ci_validate_ui_login jar csrf "${ubase}" || return $?
    # What: reservation IPs base+2/+3 of DHCP_SUBNET.
    # Why: Kea rejects a reservation outside its subnet.
    # From: Issue #763 | PR #1858
    base="$(_ci_ipv4_to_int "${subnet%/*}")" || { rm -f "${jar}"; return 2; }
    snap="$(_ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_a}" \
        "$(_ci_int_to_ipv4 $(( base + 2 )))" "${label}-1" "${snaps}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    snap_b="$(_ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_b}" \
        "$(_ci_int_to_ipv4 $(( base + 3 )))" "${label}-2" "${snaps}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    rm -f "${jar}"
    # What: .env.local holds this run's KEA_* values
    # Why: setup.sh reads a deploy/prod install's .env.local
    # From: Issue #763 | PR #1912
    _ci_validate_setup_rollback resp rc "$(printf 'KEA_CTRL_TOKEN=%s\nKEA_CTRL_HOST=%s\nKEA_DATA_DIR=%s\n' \
        "${token}" "${kip}" "${dir}")" kea "${snap}" || return 2
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
        ci_log "[CI-ERROR-VALIDATE-0095]" "snapshot=\"${snap}\" second=\"${snap_b}\" a=\"${n_a}\" b=\"${n_b}\" reason=\"live Kea config is not the snapshot state (want a=1 b=0)\""
        return 1
    fi
}

# What: Remove one compose run container of a probe.
# Why: frees its /27 address before the next probe runs.
# From: Issue #763 | PR #1858
_ci_validate_rm_run() {
    _ci_run "[CI-ERROR-VALIDATE-0099]" "container=\"$1\" reason=\"run container not removed\"" \
        docker rm -f "$1"
}

# What: Kea rollback leg on its own run containers.
# Why: dhcp is host-mode, so up never starts a Kea.
# From: Issue #763 | PR #1858
_ci_validate_kea_rollback() {
    local project="$1" net="$2" pin="$3" kname uname kip kport tail_lines rc=0
    kname="${project}-kea"
    uname="${project}-kea-ui"
    kport="$(_ci_validate_kea_agent http-port)" || return 2
    tail_lines="$(_ci_variable CI_VALIDATE_RUN_LOG_TAIL)" || return 2
    _ci_run "[CI-ERROR-VALIDATE-0096]" "project=\"${project}\" service=\"dhcp\" reason=\"Kea run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${kname}" \
            -e DHCP_MODE=kea "$(_ci_validation_service dhcp)" || return $?
    # What: both run containers must be healthy first.
    # Why: healthy means the Kea agent and ui accept.
    # From: Issue #1683 | PR #1912
    if ! _ci_validate_wait_cid "$(_ci_validation_service dhcp)" "${kname}"; then
        ci_error "[CI-ERROR-VALIDATE-0129]" "service=\"dhcp\" container=\"${kname}\" reason=\"Kea run container not healthy (cause above)\"" \
            "$(docker logs --tail "${tail_lines}" "${kname}" 2>&1)"
        rc=1
    elif ! kip="$(_ci_validate_cid_ip "${project}" "${kname}")"; then
        ci_log "[CI-ERROR-VALIDATE-0097]" "container=\"${kname}\" reason=\"no /27 IP for the Kea run container\""
        rc=2
    elif _ci_run "[CI-ERROR-VALIDATE-0098]" "project=\"${project}\" service=\"ui\" reason=\"Kea ui run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${uname}" \
        -e DHCP_MODE=kea -e "DHCP_API_HOST=${kip}" "$(_ci_validation_service ui)"; then
        _ci_validate_wait_cid "$(_ci_validation_service ui)" "${uname}" || rc=$?
        [ "${rc}" -ne 0 ] || _ci_validate_kea_round_trip "${project}" "${kip}" "${kport}" "${uname}" || rc=$?
        # What: a failed round trip ships both run logs.
        # Why: the ui answer alone does not name the cause.
        # From: Issue #1683 | PR #1912
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-VALIDATE-0126]" "ui=\"${uname}\" kea=\"${kname}\" rc=${rc} reason=\"Kea round trip failed; run logs in raw\"" \
                "$(docker logs --tail "${tail_lines}" "${uname}" 2>&1; docker logs --tail "${tail_lines}" "${kname}" 2>&1)"
        fi
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
    local base="$1" token="$2" name="$3" out code url body
    # What: the register route from the SOT defaults
    # Why: the ui path has one owner, build-manifest.yml
    # From: Issue #1683 | PR #1912
    url="${base}$(_ci_runtime_default UI_ROUTE_SECONDARY_REGISTER)" || return 2
    # What: jq encodes the body; the token comes via env.
    # Why: a quote breaks pasted JSON; argv shows secrets.
    # From: Issue #1683 | PR #1858
    body="$(CI_REGISTER_TOKEN="${token}" _ci_capture 0 jq -cn --arg name "${name}" "{token: env.CI_REGISTER_TOKEN, name: \$name}")" || return 2
    out="$(_ci_capture 0 _ci_curl_secret data "${body}" \
        -sS -w '\n%{http_code}' -H 'Content-Type: application/json' \
        "${url}")" || {
        ci_log "[CI-ERROR-VALIDATE-0083]" "url=\"${url}\" name=\"${name}\" reason=\"secondary register request failed (raw above)\""
        return 2
    }
    code="${out##*$'\n'}"
    if [ "${code}" != "200" ]; then
        printf 'register %s: http %s\n%s\n' "${name}" "${code}" "${out%$'\n'*}" >&2
        return 1
    fi
    printf '%s' "${out%$'\n'*}"
}

# What: the ui's token file path, a SOT runtime default
# Why: the ui reads it from the SOT list, not a process env
# From: Issue #583 | PR #1905
_ci_validate_ui_token_file() {
    _ci_runtime_default SECONDARY_REGISTRATION_TOKEN_FILE
}

# What: Prove each secondary gets unique identity.
# Why: per-secondary NATS auth-callout, not shared token.
# From: Issue #1683
_ci_validate_secondary_identity() {
    local project="$1" base cid token a b au bu ap bp trc=0 tf label
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    cid="$(_ci_validate_cid "${project}" "$(_ci_validation_service ui)")" || return 2
    if [ -z "${cid}" ] || ! base="$(_ci_validate_ui_base "${project}" "${cid}")"; then
        ci_log "[CI-ERROR-VALIDATE-0045]" "reason=\"no ui container/IP for secondary-identity check\""
        return 2
    fi
    tf="$(_ci_validate_ui_token_file)" || return 2
    # What: token as the ui resolves it: its file, else env.
    # Why: no file when the ui got a real token via env.
    # From: Issue #583 | PR #1858
    _ci_bounded_exec "${cid}" test -f "${tf}" || trc=$?
    case "${trc}" in
        0) token="$(_ci_capture 0 _ci_bounded_exec "${cid}" cat "${tf}")" || {
               ci_log "[CI-ERROR-VALIDATE-0084]" "container=\"${cid}\" file=\"${tf}\" reason=\"token file unreadable (raw above)\""; return 2; } ;;
        1) token="$(_ci_capture 0 _ci_bounded_exec "${cid}" printenv SECONDARY_REGISTRATION_TOKEN)" || {
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
        ci_log "[CI-ERROR-VALIDATE-0049]" "reason=\"two secondaries got the same NATS identity (per-secondary identity lost)\""
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
    [ "${rc}" -eq 0 ] && { _ci_validate_https_mitm "${project}" || rc=$?; }
    [ "${rc}" -eq 0 ] && { _ci_validate_https_dispatch_map "${project}" || rc=$?; }
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
    local net_ovr pin_ovr shared compose_copy state
    reservation="$(_ci_validate_reserve)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        [ "${rc}" -eq 2 ] || ci_log "[CI-ERROR-VALIDATE-0015]" "reason=\"no free validation /27 after slot retries\""
        return 2
    fi
    holder="$(_ci_record_field "${reservation}" holder)" || return 2
    subnet="$(_ci_record_field "${reservation}" subnet)" || { _ci_validate_release "${holder}"; return 2; }
    project="$(_ci_validate_project "${subnet}")" || { _ci_validate_release "${holder}"; return 2; }
    # What: per-run state root; no host path is used.
    # Why: isolate runs; never touch a host's real state.
    # From: Issue #1683
    shared="$(_ci_validate_shared_dir)" || { _ci_validate_release "${holder}"; return 2; }
    # What: the SOT fixture env for every compose call.
    # Why: no .env exists; compose reads the process env.
    # From: Issue #1683 | PR #1912
    local -a venv=()
    local vfx
    state="${shared}/state/${project}"
    vfx="$(_ci_validation_env "${state}")" || { _ci_validate_release "${holder}"; return 2; }
    mapfile -t venv <<< "${vfx}"
    export "${venv[@]}"
    # What: the per-run root is the env state root.
    # Why: derived dirs must follow it, not the SOT root.
    # From: Issue #1683 | PR #1912
    export LANCACHE_STATE_DIR="${state}"
    if ! up_out="$(mkdir -p "${LANCACHE_STATE_DIR}/cache" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0052]" "dir=\"${LANCACHE_STATE_DIR}/cache\" project=\"${project}\" reason=\"per-run state root not creatable\"" "${up_out}"
        _ci_validate_release "${holder}"
        return 2
    fi
    # What: compose runs on a copy in the shared dir.
    # Why: relative binds then name paths the daemon has.
    # From: Issue #1683 | PR #1912
    compose_copy="$(_ci_compose_path "${LANCACHE_STATE_DIR}/repo")" || { _ci_validate_teardown "${holder}" "${project}"; return 2; }
    if ! _ci_validate_stage "${LANCACHE_STATE_DIR}/repo"; then
        _ci_validate_teardown "${holder}" "${project}"
        return 2
    fi
    export CI_COMPOSE_COPY="${compose_copy}"
    if ! net_ovr="$(_ci_mktemp "${CI_TMPDIR}/ci-validate-net.XXXXXX.yml")" \
        || ! pin_ovr="$(_ci_mktemp "${CI_TMPDIR}/ci-validate-pin.XXXXXX.yml")"; then
        rm -f "${net_ovr:-}"
        _ci_validate_teardown "${holder}" "${project}"
        return 2
    fi
    if _ci_validate_net_override "${subnet}" > "${net_ovr}" \
        && _ci_validate_pin_override "${candidate}" > "${pin_ovr}"; then
        if up_out="$(_ci_validate_up "${project}" "${net_ovr}" "${pin_ovr}" 2>&1)"; then
            _ci_validate_attach "${project}" || rc=$?
            [ "${rc}" -ne 0 ] || _ci_validate_wait_healthy "${project}" || rc=$?
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
# Why: a failure keeps its rc; no stack goes to promote.
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
    local cand shared
    _ci_validate_host_tools || return 2
    shared="$(_ci_validate_shared_dir)" || return 2
    printf 'validate shared_dir=%s\n' "${shared}"
    if ! cand="$(_ci_stack_candidate)"; then
        ci_log "[CI-ERROR-VALIDATE-0001]" "reason=\"no stack candidate (candidate read failed)\""
        return 2
    fi
    if [ -z "${cand}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0002]" "reason=\"empty stack candidate\""
        return 2
    fi
    _ci_require_ghcr_auth || return 2
    _ci_validate_run "${cand}" || return "$?"
    # What: hand the validated stack to the promote job.
    # Why: promote moves only this exact stack (§48, §51).
    # From: Issue #1683 | PR #1858
    _ci_step_output "[CI-ERROR-VALIDATE-0136]" stack "${cand//$'\n'/ }"
}

# What: Required-check gate over the needs results (§62).
# Why: pass/fail classification is ci.sh, not YAML (§5).
# From: Issue #1683 | PR #1858
ci_cmd_result_gate() {
    local needs="${CI_NEEDS:-}" pairs required results="" phase state not_run="" facts
    local -A result=()
    if [ -z "${needs}" ]; then
        ci_log "[CI-ERROR-CORE-0101]" "reason=\"CI_NEEDS empty\""
        return 2
    fi
    pairs="$(_ci_needs_pairs "${needs}")" || return 2
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
        [ -n "${phase}" ] || continue
        [ -n "${result[${phase}]+set}" ] || continue
        case "$(_ci_needs_class "${state}")" in
            success) ;;
            skipped) not_run+="${not_run:+ }${phase}" ;;
            *)
                ci_log "[CI-ERROR-CORE-0116]" "phase=\"${phase}\" result=\"${state}\" results=\"${results}\" reason=\"phase neither succeeded nor skipped\""
                return 1
                ;;
        esac
    done <<< "${pairs}"
    # What: a skipped phase is NOT-RUN, not a pass.
    # Why: AG-INT-002: name what did not run, and why.
    # From: Issue #1683 | PR #1912
    if [ -n "${not_run}" ]; then
        facts="$(_ci_run "[CI-ERROR-CORE-0151]" "reason=\"plan outputs unreadable\"" \
            jq -c '.plan.outputs // {}' <<< "${needs}")" || return 2
        ci_log "[CI-INFO-CORE-0152]" "not-run=\"${not_run}\" event=\"${GITHUB_EVENT_NAME:-}\" plan=${facts} reason=\"skipped by the job condition; no phase failed\""
        printf 'CI 2.0 result gate: %s -> SUCCESS (NOT-RUN: %s)\n' "${results}" "${not_run}"
        return 0
    fi
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

# What: env, then CI_VARIABLES json; empty when neither.
# Why: GitHub vars arrive once as json; no per-name YAML.
# From: Issue #1683 | PR #1912
_ci_variable_env() {
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
    printf '%s\n' "${val}"
}

# What: env, then CI_VARIABLES json, then the SOT default.
# Why: one value rule; the SOT is the last fallback.
# From: Issue #1683 | PR #1858
_ci_variable_value() {
    local name="$1" val=""
    val="$(_ci_variable_env "${name}")" || return 2
    [ -n "${val}" ] || val="$(_ci_block_entry_field ci_variables "" "${name}")" || return 2
    [ -n "${val}" ] || return 1
    printf '%s\n' "${val}"
}

# What: The build-time secret mount ids (one reader).
# Why: AG-CI-006: the list lives in SOT build_secrets.
# From: Issue #1683 | PR #1858
_ci_runtime_secret_ids() {
    _ci_required_field build_secrets mount_ids blocklist
}

# What: Forbidden env-key prefixes for the bake guard.
# Why: AG-CI-006: the list lives in SOT build_secrets.
# From: Issue #1683 | PR #1858
_ci_bake_env_patterns() {
    _ci_required_field build_secrets bake_env_prefixes blocklist
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
    marker="$(_ci_second_line "${PROJECT_SELFHOSTED_PROXY_CA:-}")"
    if [ -n "${marker}" ]; then
        bundle="$(_ci_bounded_run "" "${image}" cat "${CI_SYSTEM_CA_PATH}" 2>&1)" || { printf '%s\n' "${bundle}"; return 2; }
        n="$(_ci_capture 1 grep -cF -- "${marker}" <<< "${bundle}")" || return 2
    fi
    printf 'extra_ca %s\n' "${n:-0}"
}

# What: Fail if a build-only secret/var is baked in.
# Why: A baked CA/proxy/accel var leaks and breaks runtime.
# From: Issue #1683
_ci_bake_check() {
    local image="$1" raw status line kind rest key patt patts bad=0
    if [ -z "${image}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0008]" "reason=\"no image ref given\""
        return 2
    fi
    _ci_require_ghcr_auth || return 2
    patts="$(_ci_bake_env_patterns)" || return 2
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
                done <<< "${patts}"
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
# From: Issue #1683 | PR #1858
_ci_runtime_secret_dir() {
    local name
    if [ -n "${CI_RUNTIME_SECRET_DIR:-}" ]; then
        printf '%s\n' "${CI_RUNTIME_SECRET_DIR}"
        return 0
    fi
    name="$(_ci_required_field build_secrets runtime_dir_name block)" || return 2
    printf '%s\n' "${RUNNER_TEMP:-${CI_TMPDIR}}/${name}"
}

# What: Escape a value for a double-quoted TOML string.
# Why: Scheduler URL and token go into the dist config.
# From: Issue #1683
_ci_toml_escape() {
    local v="$1"
    # What: a control character (tab aside) stops the write.
    # Why: TOML basic strings forbid them; config breaks.
    # From: Issue #1683 | PR #1858
    if [[ "${v//$'\t'/}" == *[[:cntrl:]]* ]]; then
        ci_log "[CI-ERROR-VARIABLES-0025]" "bytes=${#v} reason=\"control character in a TOML value\""
        return 2
    fi
    v="${v//\\/\\\\}"
    printf '%s' "${v//\"/\\\"}"
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
    local path="$1" url tok
    url="$(_ci_toml_escape "$3")" || return 2
    tok="$(_ci_toml_escape "${SCCACHE_DIST_AUTH_TOKEN:-}")" || return 2
    ( umask 077
      {
        printf '[dist]\n'
        printf 'scheduler_url = "%s"\n' "${url}"
        printf 'toolchains = []\n'
        printf 'toolchain_cache_size = %s\n' "$2"
        printf '\n[dist.auth]\n'
        printf 'type = "token"\n'
        printf 'token = "%s"\n' "${tok}"
      } > "${path}" )
}

# What: Emit a --secret ref for an already-written file.
# Why: One place formats the mount; id stays validated.
# From: Issue #1683
_ci_emit_secret_ref() {
    local dir="$1" id="$2" ids
    ids="$(_ci_runtime_secret_ids)" || return 2
    if ! _ci_list_has "${id}" "${ids}"; then
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
    dir="$(_ci_runtime_secret_dir)" || return 2
    if [ "${kind}" = rust ]; then
        policy="$(_ci_sccache_policy)" || return 2
        read -r mode chain <<< "${policy}"
        [ "${mode}" = off ] || sccache_enabled=1
    fi
    # What: dist scheduler, distcc hosts via CI_VARIABLES.
    # Why: repo variables reach ci.sh only as that json.
    # From: Issue #1683 | PR #1858
    local sched="" hosts="" vrc=0
    # What: dist farm is read on self-hosted runners only.
    # Why: its scheduler and distcc hosts are LAN-only.
    # From: Issue #1683 | PR #1912
    if [ "${kind}" = rust ] && _ci_runner_self_hosted; then
        sched="$(_ci_variable_value SCCACHE_DIST_SCHEDULER_URL)" || vrc=$?
        [ "${vrc}" -le 1 ] || return 2
        vrc=0
        hosts="$(_ci_variable_value DISTCC_POTENTIAL_HOSTS)" || vrc=$?
        [ "${vrc}" -le 1 ] || return 2
    elif [ "${kind}" = rust ]; then
        ci_log "[CI-INFO-VARIABLES-0024]" "dist=off distcc=off runner=\"${RUNNER_ENVIRONMENT:-unset}\" reason=\"LAN-only farm needs a self-hosted runner\""
    fi
    if _ci_runner_self_hosted && [ "${sccache_enabled}" = "1" ] && [ -n "${sched}" ] && [ -z "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0011]" "reason=\"scheduler set without auth token\""
        return 2
    fi
    if _ci_runner_self_hosted && [ "${sccache_enabled}" = "1" ] && [ -z "${sched}" ] && [ -n "${SCCACHE_DIST_AUTH_TOKEN:-}" ]; then
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
        # What: both runner values via the one env reader.
        # Why: a bare read stops under set -u with no code.
        # From: Issue #1683 | PR #1858
        local gha url tok
        url="$(_ci_env_required ACTIONS_RESULTS_URL)" || return 2
        tok="$(_ci_env_required ACTIONS_RUNTIME_TOKEN)" || return 2
        gha="ACTIONS_RESULTS_URL=${url}"$'\n'"ACTIONS_RUNTIME_TOKEN=${tok}"
        # What: v2 cache flag on github.com and *.ghe.com.
        # Why: container steps never get it; v1 answers 404.
        # From: Issue #1683 | PR #1912
        local host
        host="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
        host="${host#*://}"
        host="${host%%[/:]*}"
        case "${host,,}" in
            github.com | *.ghe.com) gha+=$'\n'"ACTIONS_CACHE_SERVICE_V2=true" ;;
        esac
        _ci_emit_secret "${dir}" sccache_gha "${gha}" || return "$?"
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
    dir="$(_ci_runtime_secret_dir)" || return 2
    if ! out="$(rm -rf -- "${dir}" 2>&1)"; then
        ci_error "[CI-ERROR-VARIABLES-0022]" "dir=\"${dir}\" reason=\"runtime secret dir not removed\"" "${out}"
        return 2
    fi
    printf 'clear-runtime result=cleared dir=%s\n' "${dir}"
}

# What: the SOT bootstrap apk list as one build-arg.
# Why: each Dockerfile adds it before ci.sh can run.
# From: Issue #1683 | PR #1912
_ci_apk_bootstrap_arg() {
    local boot
    boot="$(_ci_required_field image_base bootstrap blocklist)" || return 2
    boot="$(tr '\n' ' ' <<< "${boot}")"
    printf '%sAPK_BOOTSTRAP=%s\n' "$1" "${boot% }"
}

# What: Emit build-tools base + apk build-args.
# Why: SOT owns them; the Dockerfile pins nothing itself.
# From: Issue #1683
_ci_build_tools_build_args() {
    local fmt="${1:-}" prefix="--build-arg " out="" pkgs tool
    [ "${fmt}" = "--bare" ] && prefix=""
    tool="$(_ci_toolchain_target)" || return 2
    out="$(_ci_alpine_build_arg "${prefix}")"$'\n' || return 2
    # What: append the SOT apk list as a build-arg.
    # Why: Dockerfile consumes it; it never owns the list.
    # From: Issue #1683
    pkgs="$(_ci_build_tools_packages | tr '\n' ' ')" || return 2
    pkgs="${pkgs% }"
    out="${out}${prefix}APK_PACKAGES=${pkgs}"$'\n'
    pkgs="$(_ci_apk_bootstrap_arg "${prefix}")" || return 2
    out="${out}${pkgs}"$'\n'
    # What: add SOT tagged repos as build-arg
    # Why: Dockerfile adds them; never owns URL
    # From: Issue #1683 | PR #1858
    pkgs="$(_ci_apk_repositories "${tool}")" || return 2
    out="${out}${prefix}APK_TAGGED_REPOS=${pkgs}"$'\n'
    pkgs="$(_ci_apk_keys "${tool}")" || return 2
    [ -z "${pkgs}" ] || out="${out}${prefix}APK_KEYS=${pkgs}"$'\n'
    printf '%s' "${out}"
}

# What: a service's setup tokens with SOT values filled in.
# Why: @KEY@ is a runtime default; @GID@ the runtime gid.
# From: Issue #1683 | PR #1912
_ci_service_setup() {
    local tokens rows gid
    tokens="$(_ci_target_list "$1" setup)" || return 2
    tokens="${tokens//$'\n'/ }"
    rows="$(_ci_runtime_defaults)" || return 2
    gid="$(_ci_required_field runtime gid block)" || return 2
    _ci_fill "${tokens}" "${rows}"$'\n'"GID=${gid}" || return 2
    printf '%s' "${REPLY}"
}

# What: runtime.defaults rows a service image reads.
# Why: 64.4: a default rebuilds only images that read it.
# From: Issue #1683 | PR #1912
_ci_service_default_rows() {
    local service="$1" rows type text="" paths p part field tracked
    local -a specs=() files=()
    rows="$(_ci_runtime_defaults)" || return 2
    type="$(_ci_required_field "${service}" build_type)" || return 2
    if [ "${type}" = rust ]; then
        text="$(_ci_rust_content "${service}" "" text)" || return 2
    fi
    # What: non-Rust files and SOT lists of the image.
    # Why: templates and processes name keys too.
    # From: Issue #1683 | PR #1912
    paths="$(_ci_target_plain_paths "${service}")" || return 2
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        specs+=("${p}")
    done <<< "${paths}"
    # What: tracked image files without Rust sources.
    # Why: _ci_rust_content already reads the Rust text.
    # From: Issue #1683 | PR #1912
    tracked="$(_ci_capture 0 git -C "${CI_REPO_ROOT}" ls-files --cached -- "${specs[@]}")" || return 2
    while IFS= read -r p; do
        case "${p}" in '' | *.rs) continue ;; esac
        files+=("${p}")
    done <<< "${tracked}"
    if [ "${#files[@]}" -gt 0 ]; then
        part="$(_ci_run -m 1 "[CI-ERROR-BUILDARGS-0022]" "service=\"${service}\" reason=\"tracked files not read\"" \
            git -C "${CI_REPO_ROOT}" grep --cached -I -h -o -E '[A-Z][A-Z0-9_]*' -- "${files[@]}")" || return 2
        text+=$'\n'"${part}"
    fi
    for field in processes setup default_args; do
        part="$(_ci_target_list "${service}" "${field}")" || return 2
        text+=$'\n'"${part}"
    done
    _ci_run "[CI-ERROR-BUILDARGS-0021]" "service=\"${service}\" reason=\"read default keys not found\"" \
        awk "$(cat <<'PROG'
sep { s = $0; while (match(s, /[A-Z][A-Z0-9_]*/)) { t[substr(s, RSTART, RLENGTH)] = 1; s = substr(s, RSTART + RLENGTH) }; next }
            $0 == "\001" { sep = 1; next }
            { r[++n] = $0 }
            END { for (i = 1; i <= n; i++) if (substr(r[i], 1, index(r[i], "=") - 1) in t) print r[i] }
PROG
            )" \
        <<< "${rows}"$'\n\001\n'"${text}"
}

# What: one image's SOT defaults as one pipe-joined list.
# Why: the build arg and the test env carry one value.
# From: Issue #1683 | PR #1858
_ci_service_defaults_arg() {
    local rows
    rows="$(_ci_service_default_rows "$1")" || return 2
    printf '%s' "${rows//$'\n'/|}"
}

# What: KEY=value rows compose gives one service.
# Why: rendered with the SOT fixture env; one owner.
# From: Issue #1683 | PR #1858
_ci_service_compose_env() {
    local dep raw
    dep="$(_ci_compose_path)" || return 2
    if ! raw="$(_ci_compose_query "${dep}" "" config --format json 2>&1)"; then
        ci_error "[CI-ERROR-CHECK-0110]" "file=\"${dep#"${CI_REPO_ROOT}/"}\" reason=\"deploy compose not renderable with the SOT fixture env\"" "${raw}"
        return 2
    fi
    _ci_capture 0 jq -r --arg s "$1" "$(cat <<'PROG'
(.services[$s] // error("no compose service \($s)")).environment // {}
        | to_entries[] | "\(.key)=\(.value // "")"
PROG
        )" <<< "${raw}"
}

# What: Emit SOT build-args for one product service.
# Why: single base-image owner; Dockerfiles pin none.
# From: Issue #1683
_ci_service_build_args() {
    local service="$1" fmt="${2:-}" platform="${3:-}" with_toolchain="${4:-yes}"
    local prefix="--build-arg " out="" val
    # What: with_toolchain is yes or no; else a coded stop.
    # Why: a wrong caller value must not drop the image arg.
    # From: Issue #1683 | PR #1912
    case "${with_toolchain}" in
        yes|no) ;;
        *) ci_log "[CI-ERROR-BUILDARGS-0020]" "service=\"${service}\" with_toolchain=\"${with_toolchain}\" reason=\"must be yes or no\""; return 2 ;;
    esac
    [ "${fmt}" = "--bare" ] && prefix=""
    out="$(_ci_alpine_build_arg "${prefix}")"$'\n' || return 2
    # What: Rust builders use build-tools image ref
    # Why: SOT owns ref; Dockerfile keeps none
    # From: Issue #1683
    local own_type
    own_type="$(_ci_required_field "${service}" build_type)" || return 2
    if [ "${own_type}" = rust ]; then
        # What: identity omits the ref and its digest.
        # Why: toolchain_packages keys the packages it runs.
        # From: Issue #1683 | PR #1858
        if [ "${with_toolchain}" = yes ]; then
            val="$(_ci_build_tools_run_image)" || return 2
            [ -n "${val}" ] || { ci_log "[CI-ERROR-BUILDARGS-0009]" "arg=\"${CI_ARG_TOOLCHAIN_IMAGE}\" service=\"${service}\" reason=\"empty resolved build-tools image; FAIL CLOSED\""; return 2; }
            out="${out}${prefix}${CI_ARG_TOOLCHAIN_IMAGE}=${val}"$'\n'
        fi
        # What: emit SOT workspace crates for rust-build.
        # Why: one crate owner; the Dockerfile names none.
        # From: Issue #1683 | PR #1858
        val="$(_ci_required_field "${service}" crates list)" || return 2
        out="${out}${prefix}${CI_ARG_CRATES}=${val//$'\n'/ }"$'\n'
        # What: emit the platform's SOT rust target triple.
        # Why: apk Rust ships only its host std, no rustup.
        # From: Issue #1683 | PR #1858
        if [ -n "${platform}" ]; then
            local triple
            triple="$(_ci_platform_field "${platform}" rust_target "[CI-ERROR-BUILDARGS-0010]" "service=\"${service}\" reason=\"no rust target for platform; FAIL CLOSED\"")" || return 2
            out="${out}${prefix}${CI_ARG_TARGET}=${triple}"$'\n'
        fi
    fi
    # What: the SOT process list of a supervised image.
    # Why: the Dockerfile bakes it into the image env.
    # From: Issue #1683
    val="$(_ci_target_list "${service}" processes)" || return 2
    [ -z "${val}" ] || out="${out}${prefix}${CI_ARG_PROCESSES}=${val//$'\n'/ }"$'\n'
    # What: the SOT runtime gid the images share.
    # Why: the Dockerfiles bake it; compose names none.
    # From: Issue #1683 | PR #1912
    val="$(_ci_required_field runtime gid block)" || return 2
    out="${out}${prefix}${CI_ARG_GID}=${val}"$'\n'
    # What: the SOT defaults this image reads.
    # Why: the Dockerfiles bake them; compose names none.
    # From: Issue #1683 | PR #1912
    val="$(_ci_service_defaults_arg "${service}")" || return 2
    out="${out}${prefix}${CI_ARG_DEFAULTS}=${val}"$'\n'
    # What: SOT defaults this Dockerfile takes as args.
    # Why: the image builds with the value; it names none.
    # From: Issue #1683 | PR #1912
    local key keys
    keys="$(_ci_target_list "${service}" default_args)" || return 2
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        val="$(_ci_runtime_default "${key}")" || return 2
        out="${out}${prefix}${key}=${val}"$'\n'
    done <<<"${keys}"
    # What: the SOT accounts and directories of this image.
    # Why: ci.sh image-setup creates them, not the file.
    # From: Issue #1683 | PR #1912
    val="$(_ci_service_setup "${service}")" || return 2
    [ -z "${val}" ] || out="${out}${prefix}${CI_ARG_IMAGE_SETUP}=${val}"$'\n'
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
    apk_pkgs="$(_ci_apk_bootstrap_arg "${prefix}")" || return 2
    out="${out}${apk_pkgs}"$'\n'
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
    if _ci_list_has "${service}" "${svc_list}"; then
        _ci_service_build_args "${service}" "${fmt}" "${platform}"
    elif _ci_list_has "${service}" "${tools}"; then
        _ci_build_tools_build_args "${fmt}"
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
    out="$(_ci_target_list "$1" apk_repositories)" || return 2
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

# What: build-tools signature from declared inputs only.
# Why: §17, AG-CI-010: no live apk read in a routine id.
# From: Issue #1683 | PR #1912
_ci_build_tools_signature() {
    local args ids tool ctx
    # What: every emitted build-arg feeds the signature.
    # Why: a base or apk change must move the sig.
    # From: Issue #1683
    args="$(_ci_build_tools_build_args --bare)" || return 2
    tool="$(_ci_toolchain_target)" || return 2
    ctx="$(_ci_required_field "${tool}" context)" || return 2
    ids="$(_ci_tracked_content_ids "${ctx}")" || return 2
    if [ -z "${ids}" ]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0005]" "reason=\"no tracked build-tools source; FAIL CLOSED\""
        return 2
    fi
    printf 'args<<\n%s\nids<<\n%s\n' "${args}" "${ids}" | _ci_sha256_hex
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

# What: wrap a matrix array as a workflow matrix document.
# Why: one format for every matrix output.
# From: Issue #1683 | PR #1912
_ci_matrix_doc() {
    printf '{"include":%s}' "$1"
}

# What: resolve published build-tools to immutable ref.
# Why: jobs pin toolchain by digest; no cascade.
# From: Issue #1683
_ci_build_tools_resolve_image() {
    local ref channel image digest
    # What: a channel-checkout ref wins over the event ref.
    # Why: nightly starts on master but runs current_dev.
    # From: Issue #1683 | PR #1858
    ref="${CI_SOURCE_REF:-${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}}"
    # What: a release tag run reads the release branch.
    # Why: its ids must match the run that accepted them.
    # From: Issue #1683 | PR #1858
    if [ -n "${CI_RELEASE_TAG:-}" ]; then
        ref="$(_ci_release_ref)" || return 2
        ref="${ref#refs/heads/}"
    fi
    # What: consume the channel a push to this branch moves.
    # Why: one ref->channel owner (promote); else nightly.
    # From: Issue #1683 | PR #1858
    channel="$(GITHUB_REF="refs/heads/${ref}" CI_RELEASE_TAG='' CI_PROMOTE_REQUESTED_CHANNEL='' _ci_promote_targets_for_ref)" || return 2
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

# What: the build-tools ref the platform job resolved.
# Why: one resolver per run; ids and builds read it.
# From: Issue #1683 | PR #1912
_ci_build_tools_run_image() {
    local ref="${CI_BUILD_TOOLS_IMAGE:-}" image
    image="$(_ci_build_tools_image)" || return 2
    if [[ "${ref}" != "${image}@sha256:"* ]] || [[ ! "${ref##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-BUILDTOOLS-0026]" "got=\"${ref}\" want=\"${image}@sha256:<64 hex>\" reason=\"CI_BUILD_TOOLS_IMAGE unset or no digest ref; FAIL CLOSED\""
        return 2
    fi
    printf '%s\n' "${ref}"
}

# What: build-tools lifecycle helpers for the workflow.
# Why: all gate logic lives here; YAML only orchestrates.
# From: Issue #1683
ci_cmd_build_tools() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        packages) _ci_build_tools_packages ;;
        signature) _ci_build_tools_signature ;;
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

# What: SOT base image $1 as ref@digest of this run.
# Why: no third-party pin; the run resolves latest.
# From: Issue #1683 | PR #1858
_ci_base_image() {
    local key="$1" id="$2" ctx="$3" val digest memo
    # What: one job resolves a base once, in RUNNER_TEMP.
    # Why: build arg, labels and id name the same digest.
    # From: Issue #1683 | PR #1858
    if memo="$(_ci_job_memo_get "base-image-${key}.ref")"; then
        printf '%s\n' "${memo}"
        return 0
    fi
    val="$(_ci_block_entry_field base_images "" "${key}")" || return 2
    if [ -z "${val}" ]; then
        ci_log "${id}" "${ctx}"
        return 2
    fi
    digest="$(_ci_registry_digest "${val}")" || return 2
    _ci_job_memo_put "base-image-${key}.ref" "${val}@${digest}" || return 2
    printf '%s@%s\n' "${val}" "${digest}"
}

# What: The SOT alpine base as ALPINE_IMAGE, fail-closed.
# Why: every target's final stage uses this one owner.
# From: Issue #1683 | PR #1858
_ci_alpine_build_arg() {
    local prefix="$1" val
    val="$(_ci_base_image alpine "[CI-ERROR-BUILDARGS-0003]" "arg=\"ALPINE_IMAGE\" key=\"base_images.alpine\" reason=\"missing central base image; FAIL CLOSED\"")" || return 2
    printf '%sALPINE_IMAGE=%s\n' "${prefix}" "${val}"
}


# What: one SOT release scalar; empty is an error.
# Why: one reader for channel, license and edition.
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
    _ci_capture 0 env K="$2" yq -p toml -oy '.workspace.package[strenv(K)]' "$1"
}

# What: set 3 vars: license, edition, toml.
# Why: sync and verify read the same SOT values once.
# From: Issue #1683 | PR #1912
_ci_version_inputs() {
    local -n _vi_lic="$1" _vi_ed="$2" _vi_cargo="$3"
    _vi_lic="$(_ci_release_value license)" || return 2
    _vi_ed="$(_ci_release_value rust_edition)" || return 2
    _vi_cargo="$(_ci_repo_path CI_CARGO_MANIFEST)" || return 2
}

# What: write SOT license and edition into Cargo.toml.
# Why: copies are synced on demand, idempotent, not by hand.
# From: Issue #1683 | PR #1858
_ci_version_release_sync() {
    local lic ed cargo f tmp out wrote=0
    _ci_version_inputs lic ed cargo || return 2
    f="${cargo}"
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-vsync.XXXXXX")" || return 2
    out="$(awk -v l="${lic}" -v e="${ed}" '/^\[workspace\.package\]/ { on = 1; print; next } /^\[/ { on = 0 }
        on && $1 == "license" { print "license = \"" l "\""; next }
        on && $1 == "edition" { print "edition = \"" e "\""; next } { print }' "${f}" 2>&1 > "${tmp}")" \
        || { ci_error "[CI-ERROR-VERSION-0026]" "path=\"${f}\" reason=\"derived copy not rendered\"" "${out}"; rm -f "${tmp}"; return 2; }
    if ! out="$(_ci_copy_if_changed "${tmp}" "${f}")"; then
        ci_error "[CI-ERROR-VERSION-0027]" "path=\"${f}\" reason=\"derived copy not written\"" "${out}"
        rm -f "${tmp}"
        return 2
    fi
    [ "${out}" = unchanged ] || wrote=1
    rm -f "${tmp}"
    printf 'sync=cargo-workspace changed=%s\n' "${wrote}"
}

# What: Cargo has no version; license, edition from SOT.
# Why: AG-SEC-004: PROJECT_RELEASE_VERSION owns it.
# From: Issue #1683 | PR #1858
_ci_version_release() {
    local lic ed got cargo members m mf k rc=0
    _ci_version_inputs lic ed cargo || return 2
    got="$(_ci_cargo_ws_value "${cargo}" version)" || return 2
    if [ "${got}" != null ]; then
        ci_log "[CI-ERROR-VERSION-0021]" "path=\"${cargo}\" got=\"${got}\" reason=\"workspace.package.version must be absent; the repo variable PROJECT_RELEASE_VERSION owns it\""
        rc=1
    fi
    got="$(_ci_cargo_ws_value "${cargo}" license)" || return 2
    if [ "${got}" != "${lic}" ]; then
        ci_log "[CI-ERROR-VERSION-0028]" "path=\"${cargo}\" got=\"${got}\" want=\"${lic}\" reason=\"workspace.package.license is not SOT release.license\""
        rc=1
    fi
    got="$(_ci_cargo_ws_value "${cargo}" edition)" || return 2
    if [ "${got}" != "${ed}" ]; then
        ci_log "[CI-ERROR-VERSION-0031]" "path=\"${cargo}\" got=\"${got}\" want=\"${ed}\" reason=\"workspace.package.edition is not SOT release.rust_edition\""
        rc=1
    fi
    members="$(_ci_cargo_members "${cargo}")" || return 2
    while IFS= read -r m; do
        [ -n "${m}" ] || continue
        mf="$(_ci_repo_path CI_CARGO_MANIFEST "${CI_REPO_ROOT:-.}/${m}")" || return 2
        local vrc=0
        _ci_file_match "[CI-ERROR-VERSION-0033]" "member=\"${m}\" key=\"version\"" "${mf}" "^version([.]workspace)? *=" || vrc=$?
        case "${vrc}" in
            0)
                ci_log "[CI-ERROR-VERSION-0032]" "member=\"${m}\" key=\"version\" reason=\"member sets a version; PROJECT_RELEASE_VERSION owns it\""
                rc=1
                ;;
            1) ;;
            *) return 2 ;;
        esac
        for k in edition license; do
            local mrc=0
            _ci_file_match "[CI-ERROR-VERSION-0029]" "member=\"${m}\" key=\"${k}\"" "${mf}" "^${k}\.workspace *= *true$" || mrc=$?
            case "${mrc}" in
                0) ;;
                1)
                    ci_log "[CI-ERROR-VERSION-0022]" "member=\"${m}\" key=\"${k}\" reason=\"member owns its ${k}; use ${k}.workspace = true\""
                    rc=1
                    ;;
                *) return 2 ;;
            esac
        done
    done <<< "${members}"
    [ "${rc}" -eq 0 ] && printf 'cargo-workspace=clean version=absent\n'
    return "${rc}"
}

# What: version sync writes the SOT version into copies.
# Why: the read-only gate is check version-drift alone.
# From: Issue #1683 | PR #1912
ci_cmd_version() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        sync) _ci_version_release_sync ;;
        *)
            ci_log "[CI-ERROR-VERSION-0014]" "sub=\"${sub}\" reason=\"unknown version subcommand\" known=\"sync\""
            return 2
            ;;
    esac
}

# =========================================================
# RUNNER HOST: DOCKER DAEMON CONFIG
# =========================================================

# What: daemon.json keys that bound build cache and logs.
# Why: AG-CI-016 requires bounded build caches on runners.
# From: Issue #1255 | PR #1349
_ci_daemon_additions() {
    local reserved size files driver
    reserved="$(_ci_variable CI_BUILDER_GC_RESERVED_SPACE)" || return 2
    size="$(_ci_variable CI_DAEMON_LOG_MAX_SIZE)" || return 2
    files="$(_ci_variable CI_DAEMON_LOG_MAX_FILE)" || return 2
    driver="$(_ci_variable CI_DAEMON_LOG_DRIVER)" || return 2
    _ci_capture 0 jq -n --arg reserved "${reserved}" --arg size "${size}" --arg files "${files}" --arg driver "${driver}" "$(cat <<'PROG'
{
        "builder": { "gc": { "enabled": true, "defaultReservedSpace": $reserved } },
        "log-driver": $driver,
        "log-opts": { "max-size": $size, "max-file": $files }
    }
PROG
    )"
}

# What: deep-merge the additions into one daemon.json.
# Why: jq * keeps unrelated keys; bad JSON fails closed.
# From: Issue #1255 | PR #1349
_ci_daemon_merge() {
    local file="$1" existing="{}" additions jerr
    if [ -f "${file}" ]; then
        existing="$(_ci_capture 0 cat "${file}")" || return 2
        if ! jerr="$(jq empty <<<"${existing}" 2>&1)"; then
            ci_error "[CI-ERROR-DAEMON-0001]" "path=\"${file}\" reason=\"not valid JSON; fix or remove it first\"" "${jerr}"
            return 1
        fi
        [ -n "${existing//[[:space:]]/}" ] || existing="{}"
    fi
    additions="$(_ci_daemon_additions)" || return 2
    _ci_capture 0 jq -n --argjson old "${existing}" --argjson add "${additions}" "\$old * \$add"
}

# What: dockerd --validate on one config file.
# Why: a clean merge does not prove the key names are valid.
# From: Issue #1255 | PR #1349
_ci_daemon_validate() {
    local file="$1" out
    if ! _ci_command_available dockerd; then
        ci_error "[CI-ERROR-DAEMON-0002]" "reason=\"dockerd not on PATH; config not validated\"" "${file}"
        return 2
    fi
    if ! out="$(dockerd --validate --config-file "${file}" 2>&1)"; then
        ci_error "[CI-ERROR-DAEMON-0003]" "path=\"${file}\" reason=\"dockerd --validate rejected the config\"" "${out}"
        return 1
    fi
    printf 'dockerd --validate: configuration OK\n'
}

# What: print current, merged and diff; write nothing.
# Why: the operator reviews before stage or apply.
# From: Issue #1255 | PR #1349
_ci_daemon_check() {
    local file="$1" merged tmp
    printf -- '--- Current %s ---\n' "${file}"
    if [ -f "${file}" ]; then cat "${file}"; else printf '(none: docker runs on defaults)\n'; fi
    merged="$(_ci_daemon_merge "${file}")" || return "$?"
    printf -- '\n--- Computed merged result ---\n%s\n\n--- Diff (current vs merged) ---\n' "${merged}"
    if [ -f "${file}" ]; then
        _ci_capture 1 diff <(jq -S . "${file}") <(jq -S . <<<"${merged}") || return 2
    else
        _ci_capture 1 diff <(printf '{}\n') <(jq -S . <<<"${merged}") || return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-daemon.XXXXXX")" || return 2
    printf '%s\n' "${merged}" > "${tmp}"
    _ci_daemon_validate "${tmp}" || { rm -f "${tmp}"; return 1; }
    rm -f "${tmp}"
    printf -- '\n--- No files written (check mode) ---\n'
}

# What: write the merged config next to the live file.
# Why: manual review before apply; the live file stays.
# From: Issue #1255 | PR #1349
_ci_daemon_stage() {
    local file="$1" merged suf
    suf="$(_ci_variable CI_DAEMON_STAGED_SUFFIX)" || return 2
    merged="$(_ci_daemon_merge "${file}")" || return "$?"
    printf '%s\n' "${merged}" > "${file}${suf}" || return 2
    printf 'Staged merged config at: %s\n' "${file}${suf}"
}

# What: back up the live file; install the merged config.
# Why: validated and atomic; dockerd is not restarted here.
# From: Issue #1255 | PR #1349
_ci_daemon_apply() {
    local file="$1" merged tmp backup bsuf
    bsuf="$(_ci_variable CI_DAEMON_BACKUP_SUFFIX)" || return 2
    merged="$(_ci_daemon_merge "${file}")" || return "$?"
    tmp="$(_ci_mktemp "${file}.XXXXXX")" || return 2
    printf '%s\n' "${merged}" > "${tmp}" || { rm -f "${tmp}"; return 2; }
    _ci_daemon_validate "${tmp}" || { rm -f "${tmp}"; return 1; }
    if [ -f "${file}" ]; then
        backup="$(_ci_mktemp "${file}${bsuf}XXXXXX")" || { rm -f "${tmp}"; return 2; }
        cp "${file}" "${backup}" || { rm -f "${tmp}"; return 2; }
        printf 'Backed up existing config to: %s\n' "${backup}"
    fi
    mv "${tmp}" "${file}" || { rm -f "${tmp}"; return 2; }
    printf 'Applied merged config to: %s\ndockerd is not restarted; run the restart mode in a quiet window.\n' "${file}"
}

# What: restart dockerd after an explicit confirmation.
# Why: it stops every container, in-flight CI jobs included.
# From: Issue #1255 | PR #1349
_ci_daemon_restart() {
    local file="$1" driver want clog
    clog="$(_ci_rh_val cleanup_log)" || return 2
    want="$(_ci_variable CI_DAEMON_LOG_DRIVER)" || return 2
    if [ "${CONFIRM_DOCKERD_RESTART:-}" != "yes" ]; then
        ci_log "[CI-ERROR-DAEMON-0004]" "reason=\"restart stops every container; set CONFIRM_DOCKERD_RESTART=yes\""
        return 1
    fi
    _ci_capture 0 _ci_rh_root systemctl restart docker || return 2
    # What: one probe; restart returns once dockerd is up
    # Why: docker.service is Type=notify; no guessed wait
    # From: Issue #1683 | PR #1912
    if ! driver="$(docker info --format '{{.LoggingDriver}}' 2>&1)"; then
        ci_error "[CI-ERROR-DAEMON-0005]" "reason=\"dockerd not responsive after restart\"" "${driver}"
        return 1
    fi
    printf 'LoggingDriver (docker info): %s\n' "${driver}"
    if [ "${driver}" != "${want}" ]; then
        ci_error "[CI-ERROR-DAEMON-0006]" "driver=\"${driver}\" want=\"${want}\" reason=\"LoggingDriver is not the SOT driver; check the host\"" "${driver}"
        return 1
    fi
    printf 'builder section of %s (docker info does not report it):\n' "${file}"
    _ci_capture 0 jq '.builder // "(no builder key)"' "${file}" || return 2
    printf 'Next: confirm the runner takes jobs again, watch the\nbuild cache bound over the next days in %s, then\nmove on to the next host (one host at a time).\n' "${clog}"
}

# What: daemon-config mode on the runner host's daemon.json.
# Why: one entry for check, stage, apply and restart.
# From: Issue #1255 | PR #1349
ci_cmd_docker_daemon_config() {
    local mode="${1:-check}" file="${2:-}"
    [ -n "${file}" ] || file="$(_ci_variable CI_DAEMON_JSON)" || return 2
    case "${mode}" in
        check) _ci_daemon_check "${file}" ;;
        stage) _ci_daemon_stage "${file}" ;;
        apply) _ci_daemon_apply "${file}" ;;
        restart) _ci_daemon_restart "${file}" ;;
        *)
            ci_log "[CI-ERROR-DAEMON-0007]" "mode=\"${mode}\" reason=\"unknown mode\" known=\"check stage apply restart\""
            return 2
            ;;
    esac
}

# =========================================================
# RUNNER HOST: CLEANUP AND UNITS (AG-CI-016)
# =========================================================

# What: run a command as root; sudo -n unless root already.
# Why: runner hosts run ci.sh as the runner user.
# From: Issue #1622 | PR #1624
_ci_rh_root() {
    if [ "${EUID}" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# What: test(1) as root: 0 yes, 1 no, 2 sudo/test failed.
# Why: sudo -n also ends with 1; stderr tells it from "no".
# From: Issue #1683 | PR #1858
_ci_rh_test() {
    local err rc=0
    err="$(_ci_rh_root test "$@" 2>&1)" || rc=$?
    [ "${rc}" -ne 0 ] || return 0
    if [ "${rc}" -eq 1 ] && [ -z "${err}" ]; then
        return 1
    fi
    ci_error "[CI-ERROR-RUNNER-0135]" "test=\"$*\" rc=${rc} reason=\"root test failed, not a plain no\"" "${err}"
    return 2
}

# What: write stdin to a file as root; -a appends.
# Why: one owner for root file writes; no echoed copy.
# From: Issue #1683 | PR #1912
_ci_rh_put() {
    local redirect='>'
    if [ "${1:-}" = "-a" ]; then
        redirect='>>'
        shift
    fi
    _ci_run "[CI-ERROR-RUNNER-0129]" "file=\"$1\" reason=\"file not written\"" _ci_rh_root bash -c "cat ${redirect} \"\$1\"" _ "$1"
}

# What: epoch seconds of a docker timestamp; rc 1 if none.
# Why: the age checks key on .Created, never on StartedAt.
# From: Issue #1095 | PR #1426
_ci_rh_epoch() {
    local stamp="${1% UTC}" out
    out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0001]" "stamp=\"${stamp}\" reason=\"timestamp not parsed\"" date -d "${stamp}" +%s)" || return 2
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}"
}

# What: rc 0 if stamp $1 is before epoch $2; 1 if not.
# Why: rc 2 (unparsed stamp) stays apart from rc 1 (young).
# From: Issue #1095 | PR #1426
_ci_rh_older_than() {
    local epoch rc=0
    epoch="$(_ci_rh_epoch "$1")" || rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    [ "${epoch}" -lt "$2" ]
}

# What: remove running containers of one kind past an age.
# Why: .Created survives a daemon restart; StartedAt resets.
# From: Issue #1095 | PR #1426
_ci_rh_reap_containers() {
    local label="$1" field="$2" pattern="$3" hours="$4"
    local before ids rows id image name project created value rrc rc=0
    local -a idl
    # What: an unknown match field stops with a code.
    # Why: a bare return 2 named no field and no reason.
    # From: Issue #1683 | PR #1858
    case "${field}" in
        image | name | project) ;;
        *)
            ci_log "[CI-ERROR-RUNNER-0134]" "label=\"${label}\" field=\"${field}\" known=\"image name project\" reason=\"unknown field\""
            return 2
            ;;
    esac
    before=$(( $(date +%s) - hours * 3600 ))
    printf -- '--- reap orphaned %s containers older than %sh ---\n' "${label}" "${hours}"
    ids="$(_ci_capture 0 docker ps -q)" || return 2
    [ -n "${ids}" ] || return 0
    mapfile -t idl <<< "${ids}"
    rows="$(_ci_capture 0 docker inspect --format '{{.Id}}|{{.Config.Image}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Created}}' "${idl[@]}")" || return 2
    while IFS='|' read -r id image name project created; do
        case "${field}" in
            image) value="${image}" ;;
            name) value="${name#/}" ;;
            *) value="${project}" ;;
        esac
        [[ "${value}" == *"${pattern}"* ]] || continue
        rrc=0
        _ci_rh_older_than "${created}" "${before}" || rrc=$?
        [ "${rrc}" -le 1 ] || rc=2
        [ "${rrc}" -eq 0 ] || continue
        printf 'reaping hung %s container %s (%s=%s, created %s)\n' "${label}" "${id}" "${field}" "${value}" "${created}"
        _ci_run "[CI-ERROR-RUNNER-0002]" "container=\"${id}\" reason=\"container not removed\"" docker rm -f "${id}" || rc=2
    done <<< "${rows}"
    return "${rc}"
}

# What: remove empty networks of a name past an age.
# Why: an empty network may be mid-bringup, so age decides.
# From: Issue #1095 | PR #1426
_ci_rh_reap_networks() {
    local match="$1" secs="$2" before names name row count created rrc rc=0
    before=$(( $(date +%s) - secs ))
    printf -- '--- reap empty networks named %s older than %ss ---\n' "${match}" "${secs}"
    names="$(_ci_capture 0 docker network ls --filter "name=${match}" --format '{{.Name}}')" || return 2
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        row="$(_ci_capture 0 docker network inspect "${name}" --format '{{len .Containers}}|{{.Created}}')" || { rc=2; continue; }
        count="${row%%|*}" created="${row#*|}"
        [ "${count}" = 0 ] || continue
        rrc=0
        _ci_rh_older_than "${created}" "${before}" || rrc=$?
        [ "${rrc}" -le 1 ] || rc=2
        [ "${rrc}" -eq 0 ] || continue
        printf 'reaping empty network %s (created %s)\n' "${name}" "${created}"
        _ci_run "[CI-ERROR-RUNNER-0003]" "network=\"${name}\" reason=\"network not removed\"" docker network rm "${name}" || rc=2
    done <<< "${names}"
    return "${rc}"
}

# What: remove volumes that no container references.
# Why: AG-CI-016: unreferenced volumes fill the runner disk.
# From: Issue #1255 | PR #1349
_ci_rh_prune_volumes() {
    local vols vol users rc=0
    printf -- '--- remove unreferenced volumes ---\n'
    vols="$(_ci_capture 0 docker volume ls -q)" || return 2
    while IFS= read -r vol; do
        [ -n "${vol}" ] || continue
        users="$(_ci_capture 0 docker ps -a --filter "volume=${vol}" -q)" || { rc=2; continue; }
        [ -z "${users}" ] || continue
        _ci_run "[CI-ERROR-RUNNER-0004]" "volume=\"${vol}\" reason=\"volume not removed\"" docker volume rm "${vol}" || rc=2
    done <<< "${vols}"
    return "${rc}"
}

# What: remove CI 1.x Trivy cache dirs past an age.
# Why: they persist once their branch stops scanning.
# From: Issue #1255 | PR #1334
_ci_rh_reap_trivy() {
    local root days dirs dir rc=0
    root="$(_ci_rh_val trivy_leftover_root)" || return 2
    days="$(_ci_rh_val trivy_leftover_days)" || return 2
    printf -- '--- reap Trivy cache dirs under %s older than %sd ---\n' "${root}" "${days}"
    [ -d "${root}" ] || { printf '(no %s on this host, skipping)\n' "${root}"; return 0; }
    # What: -mmin, not -mtime; -mtime floors to whole days.
    # Why: the age threshold must be exact.
    # From: Issue #1255 | PR #1334
    dirs="$(_ci_capture 0 find "${root}" -mindepth 1 -maxdepth 1 -type d -mmin "+$(( days * 1440 ))")" || return 2
    while IFS= read -r dir; do
        [ -n "${dir}" ] || continue
        printf 'reaping stale Trivy cache dir %s\n' "${dir}"
        _ci_run "[CI-ERROR-RUNNER-0111]" "dir=\"${dir}\" reason=\"cache dir not removed\"" _ci_rh_root rm -rf -- "${dir}" || rc=2
    done <<< "${dirs}"
    return "${rc}"
}

# What: the cleanup run: reap, prune, measure before/after.
# Why: AG-CI-016: measure, clean, re-measure, verify.
# From: Issue #1255 | PR #1349
_ci_rh_cleanup_run() {
    local prefix before after rc=0 kb disk
    local bt_hours val_hours bx_hours bt_match bx_match legacy
    bt_hours="$(_ci_rh_val reap_build_tools_hours)" || return 2
    bt_match="$(_ci_rh_val build_tools_match)" || return 2
    val_hours="$(_ci_rh_val reap_validation_hours)" || return 2
    bx_hours="$(_ci_rh_val reap_buildx_hours)" || return 2
    bx_match="$(_ci_rh_val buildx_match)" || return 2
    disk="$(_ci_rh_val disk_path)" || return 2
    prefix="$(_ci_validate_project "")" || return 2
    legacy="$(_ci_rh_val legacy_validation_prefix)" || return 2
    printf '=== %s runner-host cleanup start ===\n--- disk usage before cleanup ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    before="$(_ci_capture 0 df -P "${disk}")" || return 2
    printf '%s\n' "${before}"
    before="$(awk 'NR == 2 { print $3 }' <<<"${before}")"
    _ci_rh_reap_containers build-tools image "${bt_match}" "${bt_hours}" || rc=2
    _ci_rh_reap_containers validation project "${prefix}" "${val_hours}" || rc=2
    _ci_rh_reap_networks "${prefix}" "$(( val_hours * 3600 ))" || rc=2
    _ci_rh_reap_containers legacy-validation project "${legacy}" "${val_hours}" || rc=2
    _ci_rh_reap_networks "${legacy}" "$(( val_hours * 3600 ))" || rc=2
    _ci_rh_reap_containers buildx-builder name "${bx_match}" "${bx_hours}" || rc=2
    _ci_rh_reap_trivy || rc=2
    printf -- '--- prune stopped containers, build cache, images ---\n'
    _ci_run "[CI-ERROR-RUNNER-0005]" "reason=\"container prune failed\"" docker container prune -f || rc=2
    _ci_run "[CI-ERROR-RUNNER-0006]" "reason=\"builder prune failed\"" docker builder prune -af || rc=2
    _ci_run "[CI-ERROR-RUNNER-0007]" "reason=\"image prune failed\"" docker image prune -af || rc=2
    _ci_rh_prune_volumes || rc=2
    after="$(_ci_capture 0 df -P "${disk}")" || return 2
    printf -- '--- disk usage after cleanup ---\n%s\n' "${after}"
    after="$(awk 'NR == 2 { print $3 }' <<<"${after}")"
    kb=$(( before - after ))
    printf 'reclaimed: %s KiB (%s MiB) on %s\n=== %s runner-host cleanup done rc=%s ===\n' "${kb}" "$(( kb / 1024 ))" "${disk}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${rc}"
    return "${rc}"
}

# What: cleanup mode: rotate the log, run into the log.
# Why: a timer run has no terminal; the log is its record.
# From: Issue #1255 | PR #1349
_ci_rh_cleanup() {
    local log max size rc=0 tmp
    log="$(_ci_rh_val cleanup_log)" || return 2
    max="$(_ci_rh_val cleanup_log_max_bytes)" || return 2
    if [ -f "${log}" ]; then
        size="$(_ci_capture 0 stat -c%s "${log}")" || return 2
        if [ "${size}" -gt "${max}" ]; then
            tmp="$(_ci_mktemp "${log}.XXXXXX")" || return 2
            _ci_capture 0 tail -c "${max}" "${log}" > "${tmp}" || { rm -f "${tmp}"; return 2; }
            mv "${tmp}" "${log}" || { rm -f "${tmp}"; return 2; }
        fi
    fi
    _ci_rh_cleanup_run >> "${log}" 2>&1 || rc=$?
    [ "${rc}" -eq 0 ] || ci_log "[CI-ERROR-RUNNER-0008]" "log=\"${log}\" rc=${rc} reason=\"cleanup run reported failures; see the log\""
    return "${rc}"
}

# What: a runner_host unit text; fill the @KEY@ rows in $2.
# Why: service and timer text share one fill and print.
# From: Issue #1683 | PR #1912
_ci_rh_unit_text() {
    local field="$1" text
    text="$(_ci_block_entry_list runner_host "" "${field}")" || return 2
    _ci_fill "${text}" "$2" || return 2
    printf '%s\n' "${REPLY}"
}

# What: the systemd service unit text of the cleanup run.
# Why: units are generated from ci.sh, never copied by hand.
# From: Issue #1255 | PR #1349
_ci_rh_service_text() {
    local repo
    repo="$(_ci_repo)" || return 2
    _ci_rh_unit_text service_unit "REPO=${repo}"$'\n'"SCRIPT_DIR=${CI_SCRIPT_DIR}"
}

# What: the systemd timer unit text of the cleanup run.
# Why: schedule values come from the SOT variables.
# From: Issue #1255 | PR #1349
_ci_rh_timer_text() {
    local calendar delay
    calendar="$(_ci_rh_val timer_calendar)" || return 2
    delay="$(_ci_rh_val timer_delay)" || return 2
    _ci_rh_unit_text timer_unit "CALENDAR=${calendar}"$'\n'"DELAY=${delay}"
}

# What: install the cleanup service and timer, enable it.
# Why: all runner hosts run the same versioned cleanup.
# From: Issue #1255 | PR #1349
_ci_rh_units() {
    local dir name text
    dir="$(_ci_rh_val unit_dir)" || return 2
    name="$(_ci_rh_val unit_name)" || return 2
    text="$(_ci_rh_service_text)" || return 2
    printf '%s\n' "${text}" | _ci_rh_put "${dir}/${name}.service" || return 2
    text="$(_ci_rh_timer_text)" || return 2
    printf '%s\n' "${text}" | _ci_rh_put "${dir}/${name}.timer" || return 2
    _ci_run "[CI-ERROR-RUNNER-0009]" "reason=\"systemctl daemon-reload failed\"" _ci_rh_root systemctl daemon-reload || return 2
    _ci_run "[CI-ERROR-RUNNER-0010]" "timer=\"${name}.timer\" reason=\"timer not enabled\"" _ci_rh_root systemctl enable --now "${name}.timer" || return 2
    printf 'Installed and enabled %s.timer in %s\n' "${name}" "${dir}"
}

# =========================================================
# RUNNER HOST: IDENTITY, CLONE CLEAN, HOST PREP, RUNNER SETUP
# =========================================================

# What: one runner_host SOT value; an empty one is an error.
# Why: no value lives in code; the SOT owns every one.
# From: Issue #1622 | PR #1624
_ci_rh_val() {
    _ci_required_field runner_host "$1" block
}

# What: primary group of the runner account, else its name.
# Why: a configured account may not share its group name.
# From: Issue #1622 | PR #1624
_ci_rh_group() {
    local out
    out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0012]" "user=\"$1\" reason=\"group lookup failed\"" id -gn "$1")" || return 2
    printf '%s' "${out:-$1}"
}

# What: last digit run of the hostname, or nothing.
# Why: a clone keeps the old hostname; the IP octet differs.
# From: Issue #1622 | PR #1624
_ci_rh_host_token() {
    local host
    host="$(_ci_capture 0 hostname)" || return 2
    [[ "${host}" =~ ([0-9]+)[^0-9]*$ ]] || return 0
    printf '%s' "${BASH_REMATCH[1]}"
}

# What: IPv4 routing to ROUTE_PROBE_TARGET, or none.
# Why: no route is normal on an isolated host.
# From: Issue #1622 | PR #1858
_ci_rh_ipv4() {
    local out probe
    probe="$(_ci_runtime_default ROUTE_PROBE_TARGET)" || return 2
    probe="${probe%:*}"
    out="$(_ci_run -m 2 "[CI-ERROR-RUNNER-0013]" "reason=\"route lookup failed\"" ip -4 route get "${probe}")" || return 2
    [[ "${out}" =~ src\ ([0-9.]+) ]] || return 0
    printf '%s' "${BASH_REMATCH[1]}"
}

# What: the last octet of the primary IPv4, or nothing.
# Why: a clone copies the hostname but not the live IP.
# From: Issue #1622 | PR #1624
_ci_rh_ip_token() {
    local ip
    ip="$(_ci_rh_ipv4)" || return 2
    [ -z "${ip}" ] || printf '%s' "${ip##*.}"
}

# What: the fleet host number of a runner name, or nothing.
# Why: a loose match could pick the instance suffix.
# From: Issue #1622 | PR #1624
_ci_rh_fleet_number() {
    local pats pat
    pats="$(_ci_block_entry_list runner_host "" fleet_name_patterns)" || return 2
    while IFS= read -r pat; do
        [ -n "${pat}" ] || continue
        if [[ "$1" =~ ${pat} ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<< "${pats}"
    return 0
}

# What: rc 0 if a runner dir holds credential files.
# Why: the file names have one owner, the SOT.
# From: Issue #1683 | PR #1912
_ci_rh_has_credentials() {
    local dir="$1" f list
    list="$(_ci_block_entry_list runner_host "" runner_credential_files)" || return 2
    while IFS= read -r f; do
        [ -z "${f}" ] || [ ! -f "${dir}/${f}" ] || return 0
    done <<< "${list}"
    return 1
}

# What: agentName of a runner dir's runner file, or empty.
# Why: foreign_dir and the report read it the same way.
# From: Issue #1683 | PR #1912
_ci_rh_agent_name() {
    local dir="$1" rf field
    rf="$(_ci_rh_val runner_file)" || return 2
    field="$(_ci_rh_val runner_agent_field)" || return 2
    _ci_run -m 5 "[CI-ERROR-RUNNER-0016]" "file=\"${dir}/${rf}\" reason=\"jq failed\"" jq -r --arg k "${field}" ".[\$k] // empty" "${dir}/${rf}"
}

# What: rc 0 foreign, 1 own or unregistered, 2 ambiguous.
# Why: rc 2 must never be reported as own or removed.
# From: Issue #1622 | PR #1624
_ci_rh_foreign_dir() {
    local dir="$1" agent found htok itok mine rf crc=0
    rf="$(_ci_rh_val runner_file)" || return 2
    if [ ! -f "${dir}/${rf}" ]; then
        # What: credentials but no runner file mean foreign.
        # Why: fail closed; no private key material is left.
        # From: Issue #1622 | PR #1624
        _ci_rh_has_credentials "${dir}" || crc=$?
        [ "${crc}" -le 1 ] || return 2
        if [ "${crc}" -eq 0 ]; then
            ci_log "[CI-NOTICE-RUNNER-0014]" "dir=\"${dir}\" file=\"${rf}\" reason=\"credentials but no runner file; treated as foreign\""
            return 0
        fi
        return 1
    fi
    if ! _ci_command_available jq; then
        ci_log "[CI-NOTICE-RUNNER-0015]" "dir=\"${dir}\" reason=\"jq missing; identity unprovable, treated as foreign\""
        return 0
    fi
    agent="$(_ci_rh_agent_name "${dir}")" || return 2
    found=""
    [ -z "${agent}" ] || found="$(_ci_rh_fleet_number "${agent}")" || return 2
    if [ -z "${found}" ]; then
        ci_log "[CI-NOTICE-RUNNER-0017]" "dir=\"${dir}\" agent=\"${agent}\" reason=\"no known fleet name; treated as foreign\""
        return 0
    fi
    htok="$(_ci_rh_host_token)" || return 2
    itok="$(_ci_rh_ip_token)" || return 2
    if [ -z "${htok}" ] && [ -z "${itok}" ]; then
        ci_log "[CI-NOTICE-RUNNER-0018]" "dir=\"${dir}\" reason=\"own identity unknown; treated as foreign\""
        return 0
    fi
    if [ -n "${htok}" ] && [ -n "${itok}" ] && [ "${htok}" != "${itok}" ]; then
        if [ "${found}" = "${htok}" ] || [ "${found}" = "${itok}" ]; then
            ci_log "[CI-NOTICE-RUNNER-0019]" "dir=\"${dir}\" host=\"${htok}\" ip=\"${itok}\" reason=\"own identity ambiguous; not classified\""
            return 2
        fi
        return 0
    fi
    mine="${itok:-${htok}}"
    [ "${found}" != "${mine}" ]
}

# What: runner instance dirs below the opt root, sorted.
# Why: each runner dir may be a clone leftover.
# From: Issue #1622 | PR #1624
_ci_rh_runner_dirs() {
    local root out glob
    root="$(_ci_rh_val opt_root)" || return 2
    glob="$(_ci_rh_val runner_dir_glob)" || return 2
    out="$(_ci_capture 0 find "${root}" -maxdepth 1 -type d -name "${glob}")" || return 2
    [ -z "${out}" ] || sort <<< "${out}"
}

# What: stray archives at or above the size threshold.
# Why: leftovers of 6.7 and 14.3 GB were confirmed.
# From: Issue #1622 | PR #1624
_ci_rh_stray_archives() {
    local root min out globs g names=()
    root="$(_ci_rh_val opt_root)" || return 2
    min="$(_ci_rh_val stray_archive_min_bytes)" || return 2
    globs="$(_ci_block_entry_list runner_host "" stray_archive_globs)" || return 2
    while IFS= read -r g; do
        [ -z "${g}" ] || names+=("${names[@]:+-o}" -name "${g}")
    done <<< "${globs}"
    out="$(_ci_capture 0 find "${root}" -maxdepth 1 -type f '(' "${names[@]}" ')' -size "+${min}c")" || return 2
    [ -z "${out}" ] || sort <<< "${out}"
}

# What: file match: rc 0 hit, 1 no hit, 2 unreadable.
# Why: a tolerant wrapper rates "no hit" as a hit (grep 1).
# From: Issue #1683 | PR #1912
_ci_file_match() {
    local id="$1" ctx="$2" file="$3" pat="$4" flags="${5:--E}" out
    out="$(_ci_run -m 1 "${id}" "${ctx} file=\"${file}\"" grep "${flags}" -- "${pat}" "${file}")" || return 2
    [ -n "${out}" ]
}

# What: runner units that run from one dir.
# Why: a disk clone copies the source's enabled unit.
# From: Issue #1622 | PR #1624
_ci_rh_runner_units() {
    local dir="$1" udir unit glob rc
    udir="$(_ci_rh_val unit_dir)" || return 2
    glob="$(_ci_rh_val runner_unit_glob)" || return 2
    [ -d "${udir}" ] || return 0
    for unit in "${udir}"/${glob}; do
        [ -e "${unit}" ] || continue
        rc=0
        _ci_file_match "[CI-ERROR-RUNNER-0020]" "dir=\"${dir}\" reason=\"unit unreadable\"" \
            "${unit}" "^(WorkingDirectory|ExecStart)=${dir}(/|\$)" || rc=$?
        case "${rc}" in
            0) printf '%s\n' "${unit##*/}" ;;
            1) ;;
            *) return 2 ;;
        esac
    done
}

# What: stop and disable a unit; fail while it is active.
# Why: a live process must not outlive its directory.
# From: Issue #1622 | PR #1624
_ci_rh_stop_unit() {
    printf '  stopping and disabling inherited runner service %s\n' "$1"
    _ci_run "[CI-ERROR-RUNNER-0021]" "unit=\"$1\" reason=\"stop failed\"" _ci_rh_root systemctl stop "$1" || return 2
    _ci_run "[CI-ERROR-RUNNER-0022]" "unit=\"$1\" reason=\"disable failed\"" _ci_rh_root systemctl disable "$1" || return 2
    if systemctl is-active --quiet "$1"; then
        ci_log "[CI-ERROR-RUNNER-0023]" "unit=\"$1\" reason=\"still active; its directory stays\""
        return 2
    fi
}

# What: agentName of a runner dir, "?" if unreadable.
# Why: the report names the identity a leftover belongs to.
# From: Issue #1622 | PR #1624
_ci_rh_agent() {
    local out="" rf
    rf="$(_ci_rh_val runner_file)" || return 2
    [ ! -f "$1/${rf}" ] || ! _ci_command_available jq || out="$(_ci_rh_agent_name "$1")" || return 2
    printf '%s' "${out:-?}"
}

# What: each stray archive with its size; rc 1 if none.
# Why: check and clean list the archives one way.
# From: Issue #1622 | PR #1624
_ci_rh_archive_report() {
    local prefix="$1" archives archive size rc=1
    archives="$(_ci_rh_stray_archives)" || return 2
    while IFS= read -r archive; do
        [ -n "${archive}" ] || continue
        rc=0
        size="$(_ci_capture 0 du -h "${archive}")" || return 2
        printf '%s%s (%s)\n' "${prefix}" "${archive}" "${size%%$'\t'*}"
    done <<< "${archives}"
    return "${rc}"
}

# What: read-only report of clone leftovers and host setup.
# Why: review first; clean acts only on what check shows.
# From: Issue #1622 | PR #1624
_ci_rh_check() {
    local root user hooks utim dir dirs st agent svc units found=0 f groups rf sfile dgroup crc hpre hpost arc=0
    _ci_rh_need_sudo || return 2
    root="$(_ci_rh_val opt_root)" || return 2
    user="$(_ci_rh_val user)" || return 2
    hooks="$(_ci_rh_val hooks_dir)" || return 2
    utim="$(_ci_rh_val unit_name)" || return 2
    rf="$(_ci_rh_val runner_file)" || return 2
    sfile="$(_ci_rh_sudoers_file "${user}")" || return 2
    dgroup="$(_ci_rh_val docker_group)" || return 2
    hpre="$(_ci_rh_val hook_pre_name)" || return 2
    hpost="$(_ci_rh_val hook_post_name)" || return 2
    printf 'Host: %s   own_host_token=%s\n\n--- Runner instance directories under %s ---\n' "$(_ci_capture 0 hostname)" "$(_ci_rh_host_token)" "${root}"
    dirs="$(_ci_rh_runner_dirs)" || return 2
    while IFS= read -r dir; do
        [ -n "${dir}" ] || continue
        found=1
        st=0
        _ci_rh_foreign_dir "${dir}" || st=$?
        agent="$(_ci_rh_agent "${dir}")" || return 2
        if [ "${st}" -eq 0 ]; then
            printf '  FOREIGN CLONE ARTIFACT: %s (belongs to: %s)\n' "${dir}" "${agent}"
            crc=0
            _ci_rh_has_credentials "${dir}" || crc=$?
            [ "${crc}" -le 1 ] || return 2
            if [ "${crc}" -eq 0 ]; then
                printf '    -> carries credential material (private key for that identity)\n'
            fi
            units="$(_ci_rh_runner_units "${dir}")" || return 2
            while IFS= read -r svc; do
                [ -z "${svc}" ] || printf '    -> inherited unit %s is stopped and disabled by clean first\n' "${svc}"
            done <<< "${units}"
        elif [ "${st}" -eq 2 ]; then
            printf '  UNRESOLVED IDENTITY: %s (agentName: %s); hostname and IP disagree, clean skips it\n' "${dir}" "${agent}"
        elif [ -f "${dir}/${rf}" ]; then
            printf '  own/registered: %s (agentName: %s)\n' "${dir}" "${agent}"
        else
            printf '  unregistered (no %s yet): %s\n' "${rf}" "${dir}"
        fi
    done <<< "${dirs}"
    [ "${found}" -eq 1 ] || printf '  (none found)\n'
    printf '\n--- Stray large archives under %s ---\n' "${root}"
    _ci_rh_archive_report '  ' || arc=$?
    case "${arc}" in
        0) ;;
        1) printf '  (none found)\n' ;;
        *) return 2 ;;
    esac
    printf '\n--- Sudoers and docker group for %s ---\n' "${user}"
    if _ci_rh_test -f "${sfile}"; then
        printf '  %s: present\n' "${sfile}"
    elif [ "$?" -eq 1 ]; then
        printf '  %s: MISSING\n' "${sfile}"
    else
        return 2
    fi
    groups=" $(_ci_run -m 1 "[CI-ERROR-RUNNER-0025]" "user=\"${user}\" reason=\"groups lookup failed\"" id -nG "${user}") "
    if [[ "${groups}" == *" ${dgroup} "* ]]; then
        printf '  %s in %s group: yes\n' "${user}" "${dgroup}"
    else
        printf '  %s in %s group: MISSING\n' "${user}" "${dgroup}"
    fi
    printf '\n--- Job hooks in %s ---\n' "${hooks}"
    for f in "${hpre}" "${hpost}"; do
        if [ "$(readlink -f -- "${hooks}/${f}")" = "${CI_SCRIPT_PATH}" ]; then printf '  %s/%s: linked to %s\n' "${hooks}" "${f}" "${CI_SCRIPT_PATH}"
        elif [ -e "${hooks}/${f}" ]; then printf '  %s/%s: NOT LINKED to %s, hooks replaces it\n' "${hooks}" "${f}" "${CI_SCRIPT_PATH}"
        else printf '  %s/%s: MISSING\n' "${hooks}" "${f}"; fi
    done
    printf '\n--- %s timer ---\n' "${utim}"
    local tstate
    if tstate="$(systemctl is-enabled "${utim}.timer" 2>&1)"; then
        printf '  %s.timer: %s/%s\n' "${utim}" "${tstate}" "$(systemctl is-active "${utim}.timer")"
    else
        printf '  %s.timer: not installed (systemctl: %s)\n' "${utim}" "${tstate}"
    fi
    printf '\n--- Disk usage (%s) ---\n' "${root}"
    _ci_capture 0 df -h "${root}" || return 2
    printf '\nNo files were changed (check mode).\n'
}

# What: refuse a destructive mode without its CONFIRM value.
# Why: read the report before anything is removed.
# From: Issue #1622 | PR #1624
_ci_rh_confirmed() {
    [ "${!1:-}" = yes ] && return 0
    ci_log "[CI-ERROR-RUNNER-0026]" "var=\"$1\" reason=\"refusing without $1=yes; run the matching check mode first\""
    return 2
}

# What: stop units and remove foreign runner dirs.
# Why: only identity-proven leftovers go; archives stay.
# From: Issue #1622 | PR #1624
_ci_rh_clean() {
    local dir dirs st svc units all removed=0 arc=0
    _ci_rh_confirmed CONFIRM_CLEAN || return 2
    dirs="$(_ci_rh_runner_dirs)" || return 2
    while IFS= read -r dir; do
        [ -n "${dir}" ] || continue
        # What: identity is re-checked right before removal.
        # Why: a dir can change between check and clean.
        # From: Issue #1622 | PR #1624
        st=0
        _ci_rh_foreign_dir "${dir}" || st=$?
        if [ "${st}" -eq 2 ]; then
            printf 'SKIPPING %s: identity unresolved; fix the hostname first\n' "${dir}"
        elif [ "${st}" -eq 0 ]; then
            all=1
            units="$(_ci_rh_runner_units "${dir}")" || return 2
            while IFS= read -r svc; do
                [ -z "${svc}" ] || _ci_rh_stop_unit "${svc}" || all=0
            done <<< "${units}"
            if [ "${all}" -eq 0 ]; then
                printf 'SKIPPING %s: an inherited runner service is not confirmed stopped\n' "${dir}"
                continue
            fi
            printf 'Removing foreign clone artifact: %s\n' "${dir}"
            _ci_run "[CI-ERROR-RUNNER-0027]" "dir=\"${dir}\" reason=\"directory not removed\"" _ci_rh_root rm -rf -- "${dir}" || return 2
            removed=1
        fi
    done <<< "${dirs}"
    _ci_rh_archive_report 'NOT removed (size and extension cannot prove origin): ' || arc=$?
    case "${arc}" in
        0) printf 'Review the paths, then: ci.sh runner-host clean-archive <exact-path>...\n' ;;
        1) ;;
        *) return 2 ;;
    esac
    if [ "${removed}" -eq 0 ]; then printf 'Nothing removed by clean.\n'; else printf 'Clean complete. Re-run check to confirm.\n'; fi
}

# What: remove named stray archives the finder still lists.
# Why: size and extension cannot prove clone origin.
# From: Issue #1622 | PR #1624
_ci_rh_clean_archive() {
    local cands path removed=0
    if [ "$#" -eq 0 ]; then
        ci_log "[CI-ERROR-RUNNER-0028]" "reason=\"clean-archive needs exact paths; see check or clean\""
        return 2
    fi
    cands="$(_ci_rh_stray_archives)" || return 2
    for path in "$@"; do
        if _ci_list_has "${path}" "${cands}"; then
            printf 'Removing confirmed stray archive: %s\n' "${path}"
            _ci_run "[CI-ERROR-RUNNER-0029]" "path=\"${path}\" reason=\"archive not removed\"" _ci_rh_root rm -f -- "${path}" || return 2
            removed=1
        else
            printf 'SKIPPING %s: not a current stray archive (wrong path, gone, or below the threshold)\n' "${path}"
        fi
    done
    if [ "${removed}" -eq 1 ]; then printf 'clean-archive complete.\n'; else printf 'Nothing removed.\n'; fi
}

# What: fail unless sudo works without a prompt.
# Why: a denied read must not look like no artifacts.
# From: Issue #1622 | PR #1624
_ci_rh_need_sudo() {
    [ "${EUID}" -eq 0 ] && return 0
    _ci_run "[CI-ERROR-RUNNER-0030]" "reason=\"non-interactive sudo is required for protected paths\"" sudo -n true || return 2
}

# What: per-account paths of one file kind (root, runner).
# Why: one list per file kind; check and clean share it.
# From: Issue #1622 | PR #1624
_ci_rh_user_paths() {
    local user root rhome home
    user="$(_ci_rh_val user)" || return 2
    root="$(_ci_rh_val opt_root)" || return 2
    rhome="$(_ci_rh_val root_home)" || return 2
    home="$(_ci_rh_val home_root)" || return 2
    printf '%s\n' "${rhome}/$1" "${home}/${user}/$1" "${root}/${user}/$1"
}

# What: history and known_hosts files of root and runner.
# Why: check reports and clean truncates the same list.
# From: Issue #1622 | PR #1624
_ci_rh_state_files() {
    local hist known less
    hist="$(_ci_rh_val history_file)" || return 2
    known="$(_ci_rh_val known_hosts_file)" || return 2
    less="$(_ci_rh_val lesshst_file)" || return 2
    _ci_rh_user_paths "${hist}" || return 2
    printf '%s\n' "${less}"
    _ci_rh_user_paths "${known}"
}

# What: rc 0 if an authorized_keys line names another host.
# Why: removal could lock out access, so it is report-only.
# From: Issue #1622 | PR #1624
_ci_rh_foreign_key_line() {
    local mine found
    mine="$(_ci_rh_host_token)" || return 2
    [ -n "${mine}" ] || return 1
    found="$(_ci_rh_fleet_number "$1")" || return 2
    [ -n "${found}" ] && [ "${found}" != "${mine}" ]
}

# What: list the stale journal dirs, one path per line.
# Why: an empty machine-id would select every journal dir.
# From: Issue #1622 | PR #1624
_ci_rh_stale_journals() {
    local mid out mfile jdir
    mfile="$(_ci_rh_val machine_id_file)" || return 2
    jdir="$(_ci_rh_val journal_dir)" || return 2
    mid="$(_ci_capture 0 cat "${mfile}")" || return 2
    if [ -z "${mid}" ]; then
        ci_log "[CI-ERROR-RUNNER-0031]" "file=\"${mfile}\" reason=\"machine-id unreadable; journal sweep skipped\""
        return 0
    fi
    out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0032]" "reason=\"journal search failed\"" _ci_rh_root find "${jdir}" -mindepth 1 -maxdepth 1 -type d ! -name "${mid}")" || return 2
    [ -z "${out}" ] || printf '%s\n' "${out}"
}

# What: list /home dirs with no passwd entry, tagged.
# Why: a mount or backup is data, not clone residue.
# From: Issue #1622 | PR #1624
_ci_rh_orphan_homes() {
    local out hd home
    home="$(_ci_rh_val home_root)" || return 2
    out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0033]" "dir=\"${home}\" reason=\"home search failed\"" _ci_rh_root find "${home}" -mindepth 1 -maxdepth 1 -type d)" || return 2
    while IFS= read -r hd; do
        [ -n "${hd}" ] || continue
        getent passwd "${hd##*/}" >&2 && continue
        if mountpoint -q "${hd}"; then printf 'MOUNTPOINT %s\n' "${hd}"; else printf 'ORPHANED %s\n' "${hd}"; fi
    done <<< "${out}"
}

# What: report the hostname against the primary IPv4.
# Why: only the maintainer's inventory knows the right name.
# From: Issue #1622 | PR #1624
_ci_rh_hostname_report() {
    local ip tok
    ip="$(_ci_rh_ipv4)" || return 2
    tok="$(_ci_rh_host_token)" || return 2
    if [ -z "${ip}" ] || [ -z "${tok}" ]; then
        printf '  (no primary IPv4 or no numeric hostname token; check skipped)\n'
    elif [ "${ip##*.}" != "${tok}" ]; then
        printf '  MISMATCH: hostname %s (token %s) vs primary IPv4 %s; confirm the name, then: ci.sh runner-host set-hostname <name>\n' "$(_ci_capture 0 hostname)" "${tok}" "${ip}"
    else
        printf '  OK: hostname token %s matches primary IPv4 %s\n' "${tok}" "${ip}"
    fi
}

# What: check /etc/hosts resolves the hostname; fix appends.
# Why: without it sudo fails: unable to resolve host.
# From: Issue #1622 | PR #1624
_ci_rh_hosts_self() {
    local mode="$1" host active hosts self
    host="$(_ci_capture 0 hostname)" || return 2
    hosts="$(_ci_rh_val hosts_file)" || return 2
    self="$(_ci_rh_val hosts_self_ip)" || return 2
    active="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0034]" "file=\"${hosts}\" reason=\"hosts file unreadable\"" _ci_rh_root grep -vE '^[[:space:]]*#' "${hosts}")" || return 2
    if _ci_text_has "(^|[^[:alnum:]_])${host}([^[:alnum:]_]|\$)" "${active}"; then
        printf '  OK: %s resolves hostname %s\n' "${hosts}" "${host}"
        return 0
    fi
    printf '  STALE: %s has no line resolving hostname %s\n' "${hosts}" "${host}"
    [ "${mode}" = fix ] || return 0
    # What: append a self-address line, no address edit.
    # Why: editing an address line would drop its aliases.
    # From: Issue #1622 | PR #1624
    printf '%s\t%s\n' "${self}" "${host}" | _ci_rh_put -a "${hosts}" || return 2
    printf '    fixed: appended a %s entry\n' "${self}"
}

# What: read-only survey of what a disk clone copied.
# Why: full-reset-clean acts only on what this lists.
# From: Issue #1622 | PR #1624
_ci_rh_full_reset_check() {
    local f ck found mine out line hd mid list fleet_ere mfile sshd privg pubg aklist logs rhome
    _ci_rh_need_sudo || return 2
    mfile="$(_ci_rh_val machine_id_file)" || return 2
    sshd="$(_ci_rh_val ssh_dir)" || return 2
    privg="$(_ci_rh_val ssh_private_key_glob)" || return 2
    pubg="$(_ci_rh_val ssh_public_key_glob)" || return 2
    aklist="$(_ci_rh_val authorized_keys_file)" || return 2
    rhome="$(_ci_rh_val root_home)" || return 2
    mine="$(_ci_rh_host_token)" || return 2
    printf 'Host: %s   own_host_token=%s\n\n--- Shell history and known_hosts (size only) ---\n' "$(_ci_capture 0 hostname)" "${mine:-<none>}"
    list="$(_ci_rh_state_files)" || return 2
    while IFS= read -r f; do
        if _ci_rh_test -s "${f}"; then printf '  %s: truncated by full-reset-clean\n' "${f}"; elif [ "$?" -ne 1 ]; then return 2; fi
    done <<< "${list}"
    printf '\n--- Private SSH client keys (report only; rotate by hand) ---\n'
    found=0
    list="$(_ci_rh_user_paths "${sshd}")" || return 2
    while IFS= read -r f; do
        _ci_rh_test -d "${f}" || { [ "$?" -eq 1 ] || return 2; continue; }
        out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0035]" "dir=\"${f}\" reason=\"key search failed\"" _ci_rh_root find "${f}" -maxdepth 1 -type f -name "${privg}" ! -name "${pubg}")" || return 2
        while IFS= read -r ck; do
            [ -z "${ck}" ] || { found=1; printf '  %s: authenticates as the SOURCE host\n' "${ck}"; }
        done <<< "${out}"
    done <<< "${list}"
    [ "${found}" -eq 1 ] || printf '  (none found)\n'
    printf '\n--- authorized_keys naming a DIFFERENT fleet host (report only) ---\n'
    found=0
    list="$(_ci_rh_user_paths "${aklist}")" || return 2
    while IFS= read -r f; do
        _ci_rh_test -f "${f}" || { [ "$?" -eq 1 ] || return 2; continue; }
        out="$(_ci_capture 0 _ci_rh_root cat "${f}")" || return 2
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            if _ci_rh_foreign_key_line "${line}"; then found=1; printf '  FOREIGN (%s): %s\n' "${f}" "${line}"; fi
        done <<< "${out}"
    done <<< "${list}"
    [ "${found}" -eq 1 ] || printf '  (none found)\n'
    mid="$(_ci_capture 0 cat "${mfile}")" || return 2
    printf '\n--- Stale journal machine-id dirs (current: %s) ---\n' "${mid:-UNKNOWN}"
    out="$(_ci_rh_stale_journals)" || return 2
    if [ -n "${out}" ]; then printf '  STALE: %s\n' "${out//$'\n'/$'\n'  STALE: }"; else printf '  (none found)\n'; fi
    printf '\n--- Orphaned home directories (report only) ---\n'
    out="$(_ci_rh_orphan_homes)" || return 2
    if [ -n "${out}" ]; then printf '  %s\n' "${out//$'\n'/$'\n'  }"; else printf '  (none found)\n'; fi
    printf '\n--- Template scripts under %s ---\n' "${rhome}"
    found=0
    list="$(_ci_block_entry_list runner_host "" template_scripts)" || return 2
    while IFS= read -r f; do
        if _ci_rh_test -f "${rhome}/${f}"; then found=1; printf '  %s/%s: removed by full-reset-clean\n' "${rhome}" "${f}"; elif [ "$?" -ne 1 ]; then return 2; fi
    done <<< "${list}"
    [ "${found}" -eq 1 ] || printf '  (none found)\n'
    printf '\n--- apt/dpkg history naming other fleet hosts (report only) ---\n'
    fleet_ere="$(_ci_rh_ere fleet_name_patterns)" || return 2
    logs="$(_ci_block_entry_list runner_host "" apt_log_globs | tr '\n' ' ')" || return 2
    out="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0036]" "reason=\"apt history search failed\"" _ci_rh_root bash -c "zgrep -hEo '${fleet_ere}' ${logs}")" || return 2
    found=0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        hd="$(_ci_rh_fleet_number "${line}")" || return 2
        if [ -n "${hd}" ] && [ "${hd}" != "${mine}" ]; then found=1; printf '  %s\n' "${line}"; fi
    done <<< "${out}"
    [ "${found}" -eq 1 ] || printf '  (none found)\n'
    printf '\n--- Hostname against primary IPv4 and the hosts file ---\n'
    _ci_rh_hostname_report || return 2
    _ci_rh_hosts_self check || return 2
    printf '\n--- Always regenerated by full-reset-clean ---\n  SSH host keys, hostid (%s), machine-id (%s)\n\nNo files were changed (full-reset-check mode).\n' "$(_ci_capture 0 hostid)" "${mid:-?}"
}

# What: new /etc/hostid and a fresh random machine-id.
# Why: clones share both ids and cannot detect it.
# From: Issue #1622 | PR #1624
_ci_rh_dedupe_identity() {
    local old new mfile hfile zgen dbus jd
    mfile="$(_ci_rh_val machine_id_file)" || return 2
    hfile="$(_ci_rh_val hostid_file)" || return 2
    zgen="$(_ci_rh_val zgenhostid_bin)" || return 2
    dbus="$(_ci_rh_val dbus_machine_id_file)" || return 2
    jd="$(_ci_rh_val journald_unit)" || return 2
    _ci_command_available "${zgen}" || { ci_log "[CI-ERROR-RUNNER-0037]" "bin=\"${zgen}\" reason=\"hostid generator missing\""; return 2; }
    old="$(_ci_capture 0 cat "${mfile}")" || return 2
    _ci_run "[CI-ERROR-RUNNER-0038]" "file=\"${hfile}\" reason=\"hostid not removed\"" _ci_rh_root rm -f "${hfile}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0039]" "bin=\"${zgen}\" reason=\"hostid not generated\"" _ci_rh_root "${zgen}" -f || return 2
    _ci_run "[CI-ERROR-RUNNER-0040]" "file=\"${hfile}\" reason=\"hostid is missing or empty\"" _ci_rh_root test -s "${hfile}" || return 2
    new="$(_ci_capture 0 od -An -N16 -tx1 /dev/urandom)" || return 2
    new="${new//[$' \n']/}"
    printf '%s\n' "${new}" | _ci_rh_put "${mfile}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0041]" "file=\"${dbus}\" reason=\"dbus machine-id not relinked\"" _ci_rh_root ln -sf "${mfile}" "${dbus}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0042]" "unit=\"${jd}\" reason=\"journald not restarted\"" _ci_rh_root systemctl restart "${jd}" || return 2
    printf '  hostid: %s\n  machine-id: %s -> %s\n' "$(_ci_capture 0 hostid)" "${old}" "${new}"
}

# What: new SSH host keys, then restart sshd.
# Why: a disk clone copies the source's server identity.
# From: Issue #1622 | PR #1624
_ci_rh_ssh_host_keys() {
    local pub glob units u fp ok=0
    glob="$(_ci_rh_val ssh_host_key_glob)" || return 2
    units="$(_ci_block_entry_list runner_host "" ssh_units)" || return 2
    _ci_run "[CI-ERROR-RUNNER-0043]" "glob=\"${glob}\" reason=\"old host keys not removed\"" _ci_rh_root bash -c "rm -f ${glob}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0044]" "reason=\"ssh-keygen -A failed; sshd may refuse to start\"" _ci_rh_root ssh-keygen -A || return 2
    while IFS= read -r u; do
        [ -z "${u}" ] || [ "${ok}" -eq 1 ] || ! _ci_rh_root systemctl restart "${u}" || ok=1
    done <<< "${units}"
    if [ "${ok}" -eq 0 ]; then
        ci_log "[CI-ERROR-RUNNER-0045]" "units=\"${units//$'\n'/ }\" reason=\"sshd not restarted (all units tried); it serves the OLD keys until restarted\""
        return 2
    fi
    printf '  new host key fingerprints:\n'
    for pub in ${glob}.pub; do
        [ -e "${pub}" ] || continue
        fp="$(_ci_run "[CI-ERROR-RUNNER-0046]" "key=\"${pub}\" reason=\"fingerprint not read\"" _ci_rh_root ssh-keygen -lf "${pub}")" || return 2
        printf '    %s\n' "${fp//$'\n'/$'\n'    }"
    done
}

# What: act on what full-reset-check marked removable.
# Why: lockout and audit-trail items stay report-only.
# From: Issue #1622 | PR #1624
_ci_rh_full_reset_clean() {
    local f out jd list rhome
    rhome="$(_ci_rh_val root_home)" || return 2
    _ci_rh_confirmed CONFIRM_FULL_RESET || return 2
    _ci_rh_need_sudo || return 2
    list="$(_ci_rh_state_files)" || return 2
    while IFS= read -r f; do
        if _ci_rh_test -f "${f}"; then
            _ci_run "[CI-ERROR-RUNNER-0047]" "file=\"${f}\" reason=\"not truncated\"" _ci_rh_root truncate -s0 "${f}" || return 2
            printf 'Truncated %s\n' "${f}"
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
    done <<< "${list}"
    printf 'NOTE: an open login shell keeps its own history; run history -c there or reconnect.\n--- hostid and machine-id ---\n'
    _ci_rh_dedupe_identity || return 2
    printf '\n--- SSH host keys ---\n'
    _ci_rh_ssh_host_keys || return 2
    out="$(_ci_rh_stale_journals)" || return 2
    while IFS= read -r jd; do
        [ -n "${jd}" ] || continue
        printf 'Removing stale journal dir: %s\n' "${jd}"
        _ci_run "[CI-ERROR-RUNNER-0048]" "dir=\"${jd}\" reason=\"journal dir not removed\"" _ci_rh_root rm -rf -- "${jd}" || return 2
    done <<< "${out}"
    list="$(_ci_block_entry_list runner_host "" template_scripts)" || return 2
    while IFS= read -r f; do
        if _ci_rh_test -f "${rhome}/${f}"; then
            printf 'Removing template-authoring script: %s/%s\n' "${rhome}" "${f}"
            _ci_run "[CI-ERROR-RUNNER-0049]" "file=\"${rhome}/${f}\" reason=\"script not removed\"" _ci_rh_root rm -f -- "${rhome}/${f}" || return 2
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
    done <<< "${list}"
    printf -- '--- hosts file self-reference ---\n'
    _ci_rh_hosts_self fix || return 2
    printf '\nfull-reset-clean complete. Report only, not touched: orphaned home dirs, authorized_keys, private ssh keys, apt/dpkg history.\n'
}

# What: set the hostname and its self-address hosts line.
# Why: the new name is maintainer input, never derived.
# From: Issue #1622 | PR #1624
_ci_rh_set_hostname() {
    local new="${1:-}" old hosts self self_re
    hosts="$(_ci_rh_val hosts_file)" || return 2
    self="$(_ci_rh_val hosts_self_ip)" || return 2
    self_re="${self//./\\.}"
    if [ -z "${new}" ]; then
        ci_log "[CI-ERROR-RUNNER-0050]" "reason=\"set-hostname needs the new hostname\""
        return 2
    fi
    old="$(_ci_capture 0 hostname)" || return 2
    # What: a retry repairs /etc/hosts, skips hostnamectl.
    # Why: it must finish a half-applied rename.
    # From: Issue #1622 | PR #1624
    if [ "${new}" != "${old}" ]; then
        printf "Renaming host: '%s' -> '%s'\n" "${old}" "${new}"
        _ci_run "[CI-ERROR-RUNNER-0051]" "name=\"${new}\" reason=\"hostnamectl failed\"" _ci_rh_root hostnamectl set-hostname "${new}" || return 2
    fi
    local h1=0 h2=0
    _ci_file_match "[CI-ERROR-RUNNER-0124]" "host=\"${new}\"" "${hosts}" "${self_re}" || h1=$?
    [ "${h1}" -le 1 ] || return 2
    if [ "${h1}" -eq 1 ]; then
        _ci_file_match "[CI-ERROR-RUNNER-0127]" "host=\"${new}\"" "${hosts}" "^[0-9.]+[[:space:]].*\\b${old}\\b" || h2=$?
        [ "${h2}" -le 1 ] || return 2
    fi
    if [ "${h1}" -eq 0 ]; then
        _ci_run "[CI-ERROR-RUNNER-0052]" "file=\"${hosts}\" reason=\"self-address line not updated\"" _ci_rh_root sed -i "s/^${self_re}[[:space:]].*/${self}\\t${new}/" "${hosts}" || return 2
    elif [ "${h2}" -eq 0 ]; then
        _ci_run "[CI-ERROR-RUNNER-0053]" "file=\"${hosts}\" reason=\"stale self line not replaced\"" _ci_rh_root sed -i "s/^[0-9.]\\+[[:space:]].*\\b${old}\\b.*/${self}\\t${new}/" "${hosts}" || return 2
    else
        printf '%s\t%s\n' "${self}" "${new}" | _ci_rh_put -a "${hosts}" || return 2
    fi
    printf 'Done. Hostname: %s (nothing was rebooted or restarted)\n' "$(_ci_capture 0 hostname)"
}

# What: one runner_host list as a single ERE alternation.
# Why: name families have one owner, the SOT; no regex copy.
# From: Issue #1683 | PR #1912
_ci_rh_ere() {
    local list
    list="$(_ci_block_entry_list runner_host "" "$1")" || return 2
    tr '\n' '|' <<< "${list}" | sed 's/|$//'
}

# What: the kernel/firmware name parts as one ERE.
# Why: purge-pve must never touch the boot packages.
# From: Issue #1622 | PR #1624
_ci_rh_pve_keep_ere() {
    _ci_rh_ere pve_keep
}

# What: print lines of $3 matching ERE $1, else the text $2.
# Why: a failed grep is an error, never read as "none".
# From: Issue #1683 | PR #1912
_ci_rh_grep_or() {
    local hits
    hits="$(_ci_capture 1 grep -iE "$1" <<< "$3")" || return 2
    if [ -n "${hits}" ]; then printf '%s\n' "${hits}"; else printf '%s\n' "$2"; fi
}

# What: read-only inventory of the nested Proxmox stack.
# Why: review it before purge-pve removes a live stack.
# From: Issue #1622 | PR #1624
_ci_rh_purge_pve_check() {
    local keep pkgs pkg_raw sim families units fstab pdir procs crons d open hits rss dpkg_out unit_out
    _ci_rh_need_sudo || return 2
    pdir="$(_ci_rh_val pve_config_dir)" || return 2
    procs="$(_ci_rh_ere pve_process_families)" || return 2
    crons="$(_ci_block_entry_list runner_host "" pve_cron_dirs)" || return 2
    fstab="$(_ci_rh_val fstab_file)" || return 2
    keep="$(_ci_rh_pve_keep_ere)" || return 2
    families="$(_ci_rh_ere pve_package_families)" || return 2
    units="$(_ci_rh_ere pve_unit_families)" || return 2
    # What: the list is captured and checked, then split.
    # Why: a lost read code purges with an empty name list.
    # From: Issue #1683 | PR #1912
    pkg_raw="$(_ci_required_field runner_host pve_packages blocklist)" || return 2
    mapfile -t pkgs <<< "${pkg_raw}"
    printf -- '--- Installed packages of the PVE stack ---\n'
    dpkg_out="$(_ci_capture 0 dpkg -l)" || return 2
    _ci_rh_grep_or "^ii.*(${families})" '  (none found; already clean)' "${dpkg_out}" || return 2
    printf '\n--- Kept regardless (kernel, firmware) ---\n'
    _ci_rh_grep_or "^ii.*(${keep})" '  (none installed)' "${dpkg_out}" || return 2
    printf '\n--- Active units of the PVE stack ---\n'
    unit_out="$(_ci_capture 0 systemctl list-units --all --type=service,timer --no-pager)" || return 2
    unit_out="$(_ci_capture 1 grep -iE "${units}" <<< "${unit_out}")" || return 2
    _ci_rh_grep_or active '  (none active)' "${unit_out}" || return 2
    printf '\n--- Mounts, fstab, open files and cron of the PVE stack ---\n'
    unit_out="$(_ci_capture 0 mount)" || return 2
    _ci_rh_grep_or "${units}" '  not currently mounted' "${unit_out}" || return 2
    local frc=0
    _ci_file_match "[CI-ERROR-RUNNER-0125]" "file=\"${fstab}\"" "${fstab}" "${units}" -iE || frc=$?
    case "${frc}" in
        0) printf '  FOUND: %s references the stack\n' "${fstab}" ;;
        1) ;;
        *) return 2 ;;
    esac
    if ! _ci_command_available lsof; then
        ci_error "[CI-ERROR-RUNNER-0119]" "dir=\"${pdir}\" reason=\"lsof not on PATH; open-file check not run\"" "${pdir}"
        return 2
    elif _ci_rh_test -d "${pdir}"; then
        open="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0120]" "dir=\"${pdir}\" reason=\"lsof failed\"" _ci_rh_root lsof +D "${pdir}")" || return 2
        [ -z "${open}" ] || printf '  FOUND: open files under %s:\n%s\n' "${pdir}" "${open}"
    elif [ "$?" -ne 1 ]; then
        return 2
    fi
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        _ci_rh_test -d "${d}" || { [ "$?" -eq 1 ] || return 2; continue; }
        hits="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0121]" "dir=\"${d}\" reason=\"cron scan failed\"" _ci_rh_root grep -rliE "${units}" "${d}")" || return 2
        [ -z "${hits}" ] || printf '  FOUND: cron entries reference the stack:\n%s\n' "${hits}"
    done <<< "${crons}"
    printf '\n--- RSS of the PVE stack processes ---\n'
    rss="$(_ci_capture 0 ps -eo rss=,comm=)" || return 2
    awk -v re="${procs}" 'tolower($2) ~ re { kb += $1 } END { printf "  %d MiB\n", kb / 1024 }' <<< "${rss}"
    printf '\n--- Simulated purge (no kernel or firmware must appear) ---\n'
    sim="$(_ci_run -m 100 "[CI-ERROR-RUNNER-0054]" "reason=\"simulated purge failed\"" _ci_rh_root apt-get purge --simulate "${pkgs[@]}")" || return 2
    printf '%s\n' "${sim}"
    printf '\nNo files were changed (purge-pve-check mode).\n'
}

# What: stop and purge the nested Proxmox VE stack.
# Why: a leftover stack from the template holds RAM and CPU.
# From: Issue #1622 | PR #1624
_ci_rh_purge_pve() {
    local keep pkgs pkg_raw svcs svc_raw sim rem procs bad families proc_families override dpkg_out ps_out
    _ci_rh_confirmed CONFIRM_PURGE_PVE || return 2
    keep="$(_ci_rh_pve_keep_ere)" || return 2
    families="$(_ci_rh_ere pve_package_families)" || return 2
    proc_families="$(_ci_rh_ere pve_process_families)" || return 2
    override="$(_ci_rh_val pve_apt_override)" || return 2
    # What: both lists are captured, checked, then split.
    # Why: a lost read code purges and stops empty names.
    # From: Issue #1683 | PR #1912
    pkg_raw="$(_ci_required_field runner_host pve_packages blocklist)" || return 2
    svc_raw="$(_ci_required_field runner_host pve_services blocklist)" || return 2
    mapfile -t pkgs <<< "${pkg_raw}"
    mapfile -t svcs <<< "${svc_raw}"
    # What: re-simulate; refuse when a boot package is hit.
    # Why: the package set can drift as host images change.
    # From: Issue #1622 | PR #1624
    sim="$(_ci_run -m 100 "[CI-ERROR-RUNNER-0055]" "reason=\"simulated purge failed\"" _ci_rh_root apt-get purge --simulate "${pkgs[@]}")" || return 2
    if _ci_text_has -i "${keep}" "${sim}"; then
        ci_log "[CI-ERROR-RUNNER-0056]" "reason=\"the simulated purge touches a kernel or firmware package; refusing\""
        return 2
    fi
    printf 'Stopping pve/proxmox/corosync services...\n'
    _ci_run -m 5 "[CI-ERROR-RUNNER-0057]" "reason=\"services not stopped\"" _ci_rh_root systemctl stop "${svcs[@]}" || return 2
    # What: set the pve-apt-hook override; always remove it.
    # Why: apt refuses to remove proxmox-ve otherwise.
    # From: Issue #1622 | PR #1624
    _ci_rh_root touch "${override}" || return 2
    _ci_rh_pve_purge_run "${keep}" "${pkgs[@]}" || { _ci_rh_root rm -f "${override}"; return 2; }
    _ci_rh_root rm -f "${override}" || return 2
    dpkg_out="$(_ci_run "[CI-ERROR-RUNNER-0112]" "reason=\"package list not read\"" dpkg -l)" || return 2
    ps_out="$(_ci_run "[CI-ERROR-RUNNER-0113]" "reason=\"process list not read\"" ps -eo pid,args)" || return 2
    rem="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0114]" "reason=\"remaining packages not scanned\"" grep -iE "^ii.*(${families})" <<< "${dpkg_out}")" || return 2
    bad="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0115]" "reason=\"boot packages not filtered\"" grep -viE "${keep}" <<< "${rem}")" || return 2
    procs="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0116]" "reason=\"remaining processes not scanned\"" grep -E "${proc_families}" <<< "${ps_out}")" || return 2
    procs="$(awk -v self="$$" '$1 != self && $0 !~ /grep|awk/' <<< "${procs}")"
    printf -- '--- Verification ---\nRemaining packages (kernel/firmware only expected):\n%s\nRemaining processes (none expected):\n%s\n' "${rem:-  (none)}" "${procs:-  (none)}"
    if [ -n "${bad}" ] || [ -n "${procs}" ]; then
        ci_log "[CI-ERROR-RUNNER-0058]" "reason=\"purge-pve did not remove the whole stack\""
        return 2
    fi
    printf 'purge-pve complete. Next: check docker, network and the runner, then a real reboot test.\n'
}

# What: purge the packages, then a guarded autoremove.
# Why: autoremove may hit PVE dependencies only.
# From: Issue #1622 | PR #1624
_ci_rh_pve_purge_run() {
    local keep="$1" sim bad removable aenv
    shift
    aenv="$(_ci_rh_val apt_env)" || return 2
    removable="$(_ci_rh_ere pve_autoremove_families)" || return 2
    _ci_run "[CI-ERROR-RUNNER-0059]" "reason=\"apt-get purge failed\"" _ci_rh_root env "${aenv}" apt-get purge -y "$@" || return 2
    sim="$(_ci_run "[CI-ERROR-RUNNER-0060]" "reason=\"simulated autoremove failed\"" _ci_rh_root env "${aenv}" apt-get autoremove --simulate)" || return 2
    bad="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0117]" "reason=\"autoremove list not read\"" grep -E '^Remv ' <<< "${sim}")" || return 2
    bad="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0118]" "reason=\"autoremove list not filtered\"" grep -viE "${removable}" <<< "${bad}")" || return 2
    if [ -n "${bad}" ] || _ci_text_has -i "${keep}" "${sim}"; then
        ci_log "[CI-ERROR-RUNNER-0061]" "reason=\"autoremove would remove packages outside the PVE set or a boot package; run it by hand if intended\""
        printf '%s\n' "${sim}" >&2
        return 2
    fi
    _ci_run "[CI-ERROR-RUNNER-0062]" "reason=\"apt-get autoremove failed\"" _ci_rh_root env "${aenv}" apt-get autoremove -y
}

# What: the job workspace back to the runner account.
# Why: a container leaves root files checkout cannot delete.
# From: Issue #1622 | PR #1858
_ci_rh_workspace_owner() {
    local ws
    ws="$(_ci_env_required GITHUB_WORKSPACE)" || return 2
    if [ ! -d "${ws}" ]; then
        printf 'workspace owner=NOT-RUN reason="no workspace dir yet" dir="%s"\n' "${ws}"
        return 0
    fi
    _ci_run "[CI-ERROR-RUNNER-0132]" "dir=\"${ws}\" reason=\"workspace owner not reset\"" _ci_rh_root chown -R "$(id -u):$(id -g)" "${ws}" || return 2
    printf 'workspace owner reset: %s\n' "${ws}"
}

# What: job end: empty aged validate nets, then the owner.
# Why: a cancelled job skips its own teardown step.
# From: Issue #1622 | PR #1858
_ci_rh_job_completed() {
    local secs prefix legacy rc=0
    secs="$(_ci_rh_val hook_network_min_age)" || return 2
    prefix="$(_ci_validate_project "")" || return 2
    legacy="$(_ci_rh_val legacy_validation_prefix)" || return 2
    _ci_rh_reap_networks "${prefix}" "${secs}" || rc=2
    _ci_rh_reap_networks "${legacy}" "${secs}" || rc=2
    _ci_rh_workspace_owner || rc=2
    return "${rc}"
}

# What: run the job hook whose link name is $1.
# Why: the runner calls each hook by its SOT file name.
# From: Issue #1622 | PR #1858
_ci_rh_hook() {
    local name="${1:-}" pre post
    pre="$(_ci_rh_val hook_pre_name)" || return 2
    post="$(_ci_rh_val hook_post_name)" || return 2
    if [ "${name}" = "${pre}" ]; then
        _ci_rh_workspace_owner
    elif [ "${name}" = "${post}" ]; then
        _ci_rh_job_completed
    else
        ci_log "[CI-ERROR-RUNNER-0133]" "name=\"${name}\" known=\"${pre} ${post}\" reason=\"not a SOT hook name\""
        return 2
    fi
}

# What: both job hooks as symlinks to this ci.sh.
# Why: the runner env wires them to job start and finish.
# From: Issue #1622 | PR #1858
_ci_rh_hooks() {
    local dir user group pre post link
    dir="$(_ci_rh_val hooks_dir)" || return 2
    user="$(_ci_rh_val user)" || return 2
    group="$(_ci_rh_group "${user}")" || return 2
    pre="${dir}/$(_ci_rh_val hook_pre_name)" || return 2
    post="${dir}/$(_ci_rh_val hook_post_name)" || return 2
    _ci_run "[CI-ERROR-RUNNER-0063]" "dir=\"${dir}\" reason=\"hooks dir not created\"" _ci_rh_root mkdir -p "${dir}" || return 2
    for link in "${pre}" "${post}"; do
        _ci_run "[CI-ERROR-RUNNER-0065]" "link=\"${link}\" reason=\"hook link not created\"" _ci_rh_root ln -sfn "${CI_SCRIPT_PATH}" "${link}" || return 2
    done
    _ci_run "[CI-ERROR-RUNNER-0064]" "dir=\"${dir}\" reason=\"hooks not owned by the runner account\"" _ci_rh_root chown -h "${user}:${group}" "${pre}" "${post}" || return 2
    printf 'Linked %s and %s to %s\n' "${pre}" "${post}" "${CI_SCRIPT_PATH}"
}

# What: the sudoers file path of the runner account.
# Why: check and access name the same file; SOT owns parts.
# From: Issue #1683 | PR #1912
_ci_rh_sudoers_file() {
    local dir suffix
    dir="$(_ci_rh_val sudoers_dir)" || return 2
    suffix="$(_ci_rh_val sudoers_suffix)" || return 2
    printf '%s/%s%s' "${dir}" "$1" "${suffix}"
}

# What: the sudoers rule and docker group of the runner.
# Why: the hooks need the exact NOPASSWD grant and docker.
# From: Issue #1622 | PR #1624
_ci_rh_access() {
    local user="$1" file rule groups cur mode dgroup
    _ci_rh_need_sudo || return 2
    file="$(_ci_rh_sudoers_file "${user}")" || return 2
    rule="$(_ci_rh_val sudoers_rule)" || return 2
    _ci_fill "${rule}" "USER=${user}" || return 2
    rule="${REPLY}"
    mode="$(_ci_rh_val sudoers_mode)" || return 2
    dgroup="$(_ci_rh_val docker_group)" || return 2
    if _ci_rh_test -f "${file}"; then
        cur="$(_ci_capture 0 _ci_rh_root cat "${file}")" || return 2
        if [ "${cur}" != "${rule}" ] || ! _ci_rh_root visudo -cf "${file}" >&2; then
            ci_log "[CI-ERROR-RUNNER-0066]" "file=\"${file}\" reason=\"exists without exactly the expected rule or fails visudo; fix it by hand\""
            return 2
        fi
        printf '%s already holds the expected rule.\n' "${file}"
    elif [ "$?" -ne 1 ]; then
        return 2
    else
        printf '%s\n' "${rule}" | _ci_rh_put "${file}" || return 2
        _ci_run "[CI-ERROR-RUNNER-0067]" "file=\"${file}\" reason=\"mode not set\"" _ci_rh_root chmod "${mode}" "${file}" || return 2
        if ! _ci_rh_root visudo -cf "${file}"; then
            _ci_rh_root rm -f "${file}"
            ci_log "[CI-ERROR-RUNNER-0068]" "file=\"${file}\" reason=\"visudo rejected the rule; removed\""
            return 2
        fi
        printf 'Installed %s\n' "${file}"
    fi
    groups=" $(_ci_run -m 1 "[CI-ERROR-RUNNER-0069]" "user=\"${user}\" reason=\"groups lookup failed\"" id -nG "${user}") "
    if [[ "${groups}" == *" ${dgroup} "* ]]; then
        printf '%s is already in the %s group.\n' "${user}" "${dgroup}"
    else
        _ci_run "[CI-ERROR-RUNNER-0070]" "user=\"${user}\" reason=\"group not granted\"" _ci_rh_root usermod -aG "${dgroup}" "${user}" || return 2
        printf 'Added %s to the %s group (next login).\n' "${user}" "${dgroup}"
    fi
}

# What: write the suite's backports files, then upgrade.
# Why: the pin must use a=stable-backports, not a name.
# From: Issue #1622 | PR #1624
_ci_rh_backports() {
    local suite code list pref want_list want_pref osrel pin aenv
    suite="$(_ci_rh_val debian_suite)" || return 2
    aenv="$(_ci_rh_val apt_env)" || return 2
    osrel="$(_ci_rh_val os_release_file)" || return 2
    code="$(_ci_capture 0 bash -c ". \"\$1\"; printf %s \"\${VERSION_CODENAME:-}\"" _ "${osrel}")" || return 2
    if [ "${code}" != "${suite}" ]; then
        ci_log "[CI-ERROR-RUNNER-0071]" "codename=\"${code:-unknown}\" want=\"${suite}\" reason=\"backports only for the configured suite\""
        return 2
    fi
    list="$(_ci_rh_val backports_list)" || return 2
    pref="$(_ci_rh_val backports_pref)" || return 2
    want_list="$(_ci_rh_val backports_repo)" || return 2
    _ci_fill "${want_list}" "SUITE=${suite}" || return 2
    want_list="${REPLY}"
    pin="$(_ci_block_entry_list runner_host "" backports_pin)" || return 2
    want_pref="${pin}"
    if [ "$(_ci_run -m 1 "[CI-ERROR-RUNNER-0072]" "file=\"${list}\" reason=\"unreadable\"" _ci_rh_root cat "${list}")" != "${want_list}" ]; then
        printf '%s\n' "${want_list}" | _ci_rh_put "${list}" || return 2
    fi
    if [ "$(_ci_run -m 1 "[CI-ERROR-RUNNER-0073]" "file=\"${pref}\" reason=\"unreadable\"" _ci_rh_root cat "${pref}")" != "${want_pref}" ]; then
        printf '%s\n' "${want_pref}" | _ci_rh_put "${pref}" || return 2
    fi
    printf 'Validated %s and %s.\n' "${list}" "${pref}"
    _ci_run "[CI-ERROR-RUNNER-0074]" "reason=\"apt-get update failed\"" _ci_rh_root apt-get update || return 2
    _ci_run "[CI-ERROR-RUNNER-0075]" "reason=\"apt-get dist-upgrade failed\"" _ci_rh_root env "${aenv}" apt-get dist-upgrade -y || return 2
    _ci_run "[CI-ERROR-RUNNER-0076]" "reason=\"apt-get full-upgrade failed\"" _ci_rh_root env "${aenv}" apt-get full-upgrade -y
}

# What: purge the apt change-list package when installed.
# Why: its prompts or mail hang unattended upgrades.
# From: Issue #1622 | PR #1624
_ci_rh_purge_listchanges() {
    local st pkg aenv
    pkg="$(_ci_rh_val apt_listchanges_pkg)" || return 2
    aenv="$(_ci_rh_val apt_env)" || return 2
    st="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0077]" "pkg=\"${pkg}\" reason=\"dpkg query failed\"" dpkg -l "${pkg}")"
    if _ci_text_has '^ii' "${st}"; then
        _ci_run "[CI-ERROR-RUNNER-0078]" "pkg=\"${pkg}\" reason=\"package not purged\"" _ci_rh_root env "${aenv}" apt-get purge -y "${pkg}" || return 2
        printf 'Purged %s.\n' "${pkg}"
    else
        printf '%s not installed.\n' "${pkg}"
    fi
}

# What: idempotent host setup for a cloned runner host.
# Why: every runner host gets the same access, hooks, timer.
# From: Issue #1622 | PR #1624
_ci_rh_host_prep() {
    local user root group rmode heavy
    user="$(_ci_rh_val user)" || return 2
    root="$(_ci_rh_val opt_root)" || return 2
    rmode="$(_ci_rh_val opt_root_mode)" || return 2
    heavy="$(_ci_rh_val heavy_host_pattern)" || return 2
    if ! getent passwd "${user}" >&2; then
        ci_log "[CI-ERROR-RUNNER-0079]" "user=\"${user}\" reason=\"runner account does not exist\""
        return 2
    fi
    _ci_rh_access "${user}" || return 2
    group="$(_ci_rh_group "${user}")" || return 2
    # What: converge the opt root to the runner, setgid.
    # Why: base state for /opt; new files inherit the group.
    # From: Issue #1622 | PR #1624
    _ci_run "[CI-ERROR-RUNNER-0080]" "root=\"${root}\" reason=\"owner not converged\"" _ci_rh_root chown -R "${user}:${group}" "${root}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0081]" "root=\"${root}\" reason=\"mode not set\"" _ci_rh_root chmod "${rmode}" "${root}" || return 2
    printf 'Converged %s to %s:%s with mode %s.\n' "${root}" "${user}" "${group}" "${rmode}"
    _ci_rh_hooks || return 2
    _ci_rh_purge_listchanges || return 2
    _ci_rh_backports || return 2
    _ci_rh_units || return 2
    printf '\nhost-prep complete. It does not touch %s (use docker-daemon-config; add a "proxies" block by hand if this host needs the LAN proxy), does not run config.sh and starts no runner.\n' "$(_ci_variable CI_DAEMON_JSON)"
    if [[ "$(_ci_capture 0 hostname)" == *${heavy}* ]]; then
        printf 'Heavy-tier host: run sccache-check; stage only the sccache binaries, then sccache-fetch <dir>.\n'
    fi
}

# What: the runner .env hook wiring, two lines.
# Why: one text for runner-fetch and runner-hook-env.
# From: Issue #1622 | PR #1624
_ci_rh_hook_env_lines() {
    local dir hs hc pre post
    dir="$(_ci_rh_val hooks_dir)" || return 2
    hs="$(_ci_rh_val hook_env_started)" || return 2
    hc="$(_ci_rh_val hook_env_completed)" || return 2
    pre="$(_ci_rh_val hook_pre_name)" || return 2
    post="$(_ci_rh_val hook_post_name)" || return 2
    printf '%s=%s/%s\n%s=%s/%s\n' "${hs}" "${dir}" "${pre}" "${hc}" "${dir}" "${post}"
}

# What: download, verify and extract a runner release.
# Why: a new host needs a runner that was checked first.
# From: Issue #1622 | PR #1624
_ci_rh_runner_fetch() {
    local inst="${1:-}" root user group rel ver tar url dir digest tmp envf lang
    if [ -z "${inst}" ]; then
        ci_log "[CI-ERROR-RUNNER-0084]" "reason=\"runner-fetch needs an instance dir\""
        return 2
    fi
    root="$(_ci_rh_val opt_root)" || return 2
    user="$(_ci_rh_val user)" || return 2
    group="$(_ci_rh_group "${user}")" || return 2
    rel="$(_ci_tool_latest runner)" || return 2
    IFS=$'\t' read -r ver tar url digest <<< "${rel}"
    envf="$(_ci_rh_val runner_env_file)" || return 2
    lang="$(_ci_rh_val runner_env_lang)" || return 2
    # What: accept only a new or empty dir under the root.
    # Why: a typo such as /opt must not reach chown -R.
    # From: Issue #1622 | PR #1624
    dir="$(_ci_capture 0 readlink -m -- "${inst}")" || return 2
    case "${dir}" in
        "${root}"/*) ;;
        *) ci_log "[CI-ERROR-RUNNER-0085]" "dir=\"${dir}\" root=\"${root}\" reason=\"only a new dir directly under the opt root\""; return 2 ;;
    esac
    if [ -e "${dir}" ] && { [ ! -d "${dir}" ] || [ -n "$(_ci_capture 0 find "${dir}" -mindepth 1 -maxdepth 1)" ]; }; then
        ci_log "[CI-ERROR-RUNNER-0086]" "dir=\"${dir}\" reason=\"exists and is not empty; no extract over a runner\""
        return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/${tar}.XXXXXX")" || return 2
    printf 'Downloading %s (latest %s) ...\n' "${url}" "${ver}"
    _ci_fetch_verified "${url}" "${digest}" "${tmp}" || return 2
    printf 'Checksum verified: %s\n' "${digest}"
    _ci_run "[CI-ERROR-RUNNER-0089]" "dir=\"${dir}\" reason=\"dir not created\"" _ci_rh_root mkdir -p "${dir}" || { rm -f "${tmp}"; return 2; }
    _ci_run "[CI-ERROR-RUNNER-0090]" "dir=\"${dir}\" reason=\"extract failed\"" _ci_rh_root tar xzf "${tmp}" -C "${dir}" || { rm -f "${tmp}"; return 2; }
    rm -f "${tmp}"
    _ci_run "[CI-ERROR-RUNNER-0091]" "dir=\"${dir}\" reason=\"owner not set\"" _ci_rh_root chown -R "${user}:${group}" "${dir}" || return 2
    # What: write the lang line and both hook lines.
    # Why: env.sh (run by config.sh) truncates it again.
    # From: Issue #1622 | PR #1624
    { printf '%s\n' "${lang}"; _ci_rh_hook_env_lines; } | _ci_rh_put "${dir}/${envf}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0092]" "dir=\"${dir}\" file=\"${envf}\" reason=\"env file owner not set\"" _ci_rh_root chown "${user}:${group}" "${dir}/${envf}" || return 2
    printf 'Extracted actions-runner %s into %s and wrote its hook wiring. NOT registered.\n' "${ver}" "${dir}"
    printf "Next: config.sh by hand (token via stdin, --name \$(hostname) exactly), then runner-hook-env %s,\\nthen svc.sh install, then runner-restart-policy; start the service only after the go-ahead.\\n" "${dir}"
}

# What: rewrite the .env hook lines only when they differ.
# Why: config.sh truncates .env, so this runs after it.
# From: Issue #1622 | PR #1624
_ci_rh_runner_hook_env() {
    local dir="${1:-}" want cur envf hs hc
    envf="$(_ci_rh_val runner_env_file)" || return 2
    hs="$(_ci_rh_val hook_env_started)" || return 2
    hc="$(_ci_rh_val hook_env_completed)" || return 2
    if [ ! -d "${dir}" ] || [ ! -f "${dir}/${envf}" ]; then
        ci_log "[CI-ERROR-RUNNER-0093]" "dir=\"${dir}\" file=\"${envf}\" reason=\"needs an instance dir whose env file exists; run it after config.sh\""
        return 2
    fi
    want="$(_ci_rh_hook_env_lines)" || return 2
    cur="$(_ci_run -m 1 "[CI-ERROR-RUNNER-0094]" "dir=\"${dir}\" file=\"${envf}\" reason=\"env file not read\"" grep -E "^(${hs}|${hc})=" "${dir}/${envf}")" || return 2
    if [ "${cur}" = "${want}" ]; then
        printf '%s/%s already has the correct hook wiring.\n' "${dir}" "${envf}"
        return 0
    fi
    # What: delete stale hook lines first, then append.
    # Why: a stale copy must not coexist with the new pair.
    # From: Issue #1622 | PR #1624
    _ci_run "[CI-ERROR-RUNNER-0095]" "dir=\"${dir}\" reason=\"stale hook lines not removed\"" _ci_rh_root sed -i "/^${hs}=/d; /^${hc}=/d" "${dir}/${envf}" || return 2
    printf '%s\n' "${want}" | _ci_rh_put -a "${dir}/${envf}" || return 2
    printf 'Wrote the hook wiring to %s/%s.\n' "${dir}" "${envf}"
}

# What: restart drop-in on every runner unit.
# Why: the installer unit never restarts a crashed runner.
# From: Issue #1738
_ci_rh_restart_policy() {
    local udir sec unit name dropin seen=0 wrote=0 glob policy dname restart_val restart_usec
    udir="$(_ci_rh_val unit_dir)" || return 2
    sec="$(_ci_rh_val restart_sec)" || return 2
    glob="$(_ci_rh_val runner_unit_glob)" || return 2
    policy="$(_ci_rh_val restart_policy)" || return 2
    dname="$(_ci_rh_val restart_dropin)" || return 2
    for unit in "${udir}"/${glob}; do
        [ -e "${unit}" ] || continue
        seen=1
        name="${unit##*/}"
        dropin="${udir}/${name}.d/${dname}"
        # What: a read error is not "drop-in not set".
        # Why: AG-INT-002: an unreadable file is reported.
        # From: Issue #1683 | PR #1912
        local drc=1
        if [ -f "${dropin}" ]; then
            drc=0
            _ci_file_match "[CI-ERROR-RUNNER-0126]" "unit=\"${name}\"" "${dropin}" "^Restart=${policy}$" || drc=$?
            if [ "${drc}" -eq 0 ]; then
                _ci_file_match "[CI-ERROR-RUNNER-0128]" "unit=\"${name}\"" "${dropin}" "^RestartSec=${sec}$" || drc=$?
            fi
        fi
        case "${drc}" in
            0)
                printf '  %s: drop-in already set\n' "${name}"
                continue
                ;;
            1) ;;
            *) return 2 ;;
        esac
        printf '  %s: writing %s\n' "${name}" "${dropin}"
        _ci_run "[CI-ERROR-RUNNER-0096]" "unit=\"${name}\" reason=\"drop-in dir not created\"" _ci_rh_root mkdir -p "${dropin%/*}" || return 2
        printf '[Service]\nRestart=%s\nRestartSec=%s\n' "${policy}" "${sec}" | _ci_rh_put "${dropin}" || return 2
        wrote=1
    done
    if [ "${seen}" -eq 0 ]; then
        printf 'No %s units here; run this after svc.sh install.\n' "${glob}"
        return 0
    fi
    if [ "${wrote}" -eq 1 ]; then
        _ci_run "[CI-ERROR-RUNNER-0097]" "reason=\"systemctl daemon-reload failed\"" _ci_rh_root systemctl daemon-reload || return 2
    fi
    printf '\n--- Verification ---\n'
    for unit in "${udir}"/${glob}; do
        [ -e "${unit}" ] || continue
        restart_val="$(_ci_run "[CI-ERROR-RUNNER-0131]" "unit=\"${unit##*/}\" reason=\"Restart not read\"" systemctl show "${unit##*/}" -p Restart --value)" || return 2
        restart_usec="$(_ci_run "[CI-ERROR-RUNNER-0130]" "unit=\"${unit##*/}\" reason=\"RestartUSec not read\"" systemctl show "${unit##*/}" -p RestartUSec --value)" || return 2
        printf '  %s: Restart=%s, RestartUSec=%s\n' "${unit##*/}" "${restart_val}" "${restart_usec}"
    done
}

# What: check the sccache client tooling; change nothing.
# Why: Rust CI on heavy hosts fails without the client.
# From: Issue #1622 | PR #1624
_ci_rh_sccache_check() {
    local user root lack=0 f stale dist list bin_dir main_bin stales sum st
    _ci_rh_need_sudo || return 2
    user="$(_ci_rh_val user)" || return 2
    root="$(_ci_rh_val opt_root)" || return 2
    dist="$(_ci_rh_val sccache_dist_dir)" || return 2
    printf -- '--- sccache client binaries ---\n'
    bin_dir="$(_ci_rh_val sccache_bin_dir)" || return 2
    list="$(_ci_block_entry_list runner_host "" sccache_bins)" || return 2
    while IFS= read -r f; do
        f="${bin_dir}/${f}"
        if [ -x "${f}" ]; then
            sum="$(_ci_capture 0 sha256sum "${f}")" || return 2
            printf '  %s: present (sha256 %s)\n' "${f}" "${sum%% *}"
        else
            printf '  %s: MISSING\n' "${f}"
            lack=1
        fi
    done <<< "${list}"
    printf '\n--- Runtime config: supplied per job through SCCACHE_CONF; no token on the host ---\n'
    stales="$(_ci_block_entry_list runner_host "" sccache_stale_files)" || return 2
    while IFS= read -r stale; do
        stale="${root}/${user}/${stale}"
        _ci_rh_test -f "${stale}" || { [ "$?" -eq 1 ] || return 2; continue; }
        st="$(_ci_run "[CI-ERROR-RUNNER-0122]" "file=\"${stale}\" reason=\"stat failed\"" _ci_rh_root stat -c '%a %U:%G' "${stale}")" || return 2
        printf '  STALE: %s still present (%s); sccache-fetch removes it\n' "${stale}" "${st}"
    done <<< "${stales}"
    if _ci_rh_test -d "${dist}"; then printf '  %s: present\n' "${dist}"; elif [ "$?" -eq 1 ]; then printf '  %s: MISSING\n' "${dist}"; lack=1; else return 2; fi
    printf '\n--- Live check as %s ---\n' "${user}"
    main_bin="${bin_dir}/${list%%$'\n'*}"
    if [ -x "${main_bin}" ]; then
        _ci_run "[CI-ERROR-RUNNER-0098]" "user=\"${user}\" reason=\"sccache --version failed\"" _ci_rh_root sudo -u "${user}" env HOME="${root}/${user}" "${main_bin}" --version || lack=1
    else
        printf '  (skipped; sccache binary lack)\n'
    fi
    if [ "${lack}" -eq 1 ]; then
        ci_log "[CI-ERROR-RUNNER-0099]" "reason=\"sccache prerequisites lack; no files were written\""
        return 2
    fi
    printf 'No files were written (sccache-check mode).\n'
}

# What: install staged sccache binaries, drop old creds.
# Why: builds run on a heavy host; secrets are per job.
# From: Issue #1622 | PR #1626
_ci_rh_sccache_fetch() {
    local src="${1:-}" user root group dist f bin_dir list main_name dist_name old dmode sfiles sdirs sf bmode staged stmpl
    _ci_rh_need_sudo || return 2
    dmode="$(_ci_rh_val sccache_dist_mode)" || return 2
    bmode="$(_ci_rh_val sccache_bin_mode)" || return 2
    stmpl="$(_ci_rh_val sccache_staged_name)" || return 2
    sfiles="$(_ci_block_entry_list runner_host "" sccache_stale_files)" || return 2
    sdirs="$(_ci_block_entry_list runner_host "" sccache_stale_dirs)" || return 2
    user="$(_ci_rh_val user)" || return 2
    bin_dir="$(_ci_rh_val sccache_bin_dir)" || return 2
    list="$(_ci_block_entry_list runner_host "" sccache_bins)" || return 2
    main_name="${list%%$'\n'*}" dist_name="$(_ci_second_line "${list}")"
    root="$(_ci_rh_val opt_root)" || return 2
    dist="$(_ci_rh_val sccache_dist_dir)" || return 2
    group="$(_ci_rh_group "${user}")" || return 2
    for f in ${list}; do
        if [ ! -f "${src}/${f}" ]; then
            ci_log "[CI-ERROR-RUNNER-0100]" "file=\"${src}/${f}\" reason=\"not staged; scp it from a working heavy host\""
            return 2
        fi
    done
    # What: run the staged binaries before any install.
    # Why: a bad or foreign file must not replace tools.
    # From: Issue #1622 | PR #1626
    _ci_run "[CI-ERROR-RUNNER-0101]" "file=\"${src}/${main_name}\" reason=\"staged binary does not run\"" _ci_rh_root sudo -u "${user}" env HOME="${root}/${user}" "${src}/${main_name}" --version || return 2
    _ci_run "[CI-ERROR-RUNNER-0102]" "file=\"${src}/${dist_name}\" reason=\"staged binary does not run\"" "${src}/${dist_name}" --help || return 2
    for f in ${list}; do
        _ci_fill "${stmpl}" "FILE=${f}" || return 2
        staged="${bin_dir}/${REPLY}"
        _ci_run "[CI-ERROR-RUNNER-0103]" "file=\"${f}\" reason=\"not installed\"" _ci_rh_root install -o root -g "${group}" -m "${bmode}" "${src}/${f}" "${staged}" || { _ci_rh_root rm -f "${staged}"; return 2; }
        _ci_run "[CI-ERROR-RUNNER-0104]" "file=\"${f}\" reason=\"not moved in place\"" _ci_rh_root mv -f "${staged}" "${bin_dir}/${f}" || { _ci_rh_root rm -f "${staged}"; return 2; }
    done
    _ci_run "[CI-ERROR-RUNNER-0105]" "dir=\"${dist}\" reason=\"dist dir not created\"" _ci_rh_root mkdir -p "${dist}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0106]" "dir=\"${dist}\" reason=\"dist dir owner not set\"" _ci_rh_root chown "${user}:${group}" "${dist%/*}" "${dist}" || return 2
    _ci_run "[CI-ERROR-RUNNER-0107]" "dir=\"${dist}\" reason=\"dist dir mode not set\"" _ci_rh_root chmod "${dmode}" "${dist%/*}" "${dist}" || return 2
    # What: remove credentials the old host-copy flow left.
    # Why: leftover world-readable copies have no reader.
    # From: Issue #1622 | PR #1624
    while IFS= read -r sf; do
        [ -z "${sf}" ] || _ci_run "[CI-ERROR-RUNNER-0108]" "file=\"${root}/${user}/${sf}\" reason=\"old credential copy not removed\"" _ci_rh_root rm -f "${root}/${user}/${sf}" || return 2
    done <<< "${sfiles}"
    while IFS= read -r sf; do
        [ -n "${sf}" ] || continue
        old="${root}/${user}/${sf}"
        _ci_rh_test -d "${old}" || { [ "$?" -eq 1 ] || return 2; continue; }
        _ci_run "[CI-ERROR-RUNNER-0109]" "dir=\"${old}\" reason=\"old credential dir not removed\"" _ci_rh_root rmdir --ignore-fail-on-non-empty "${old}" || return 2
    done <<< "${sdirs}"
    printf 'Installed the sccache client tooling. Verifying:\n'
    _ci_run "[CI-ERROR-RUNNER-0123]" "file=\"${bin_dir}/${main_name}\" reason=\"installed binary does not run\"" _ci_rh_root sudo -u "${user}" env HOME="${root}/${user}" "${bin_dir}/${main_name}" --version || return 2
    printf 'Run sccache-check to confirm the full picture.\n'
}

# What: runner-host mode on a runner host.
# Why: one entry replaces the legacy runner-host scripts.
# From: Issue #1622 | PR #1624
ci_cmd_runner_host() {
    local mode="${1:-check}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${mode}" in
        cleanup) _ci_rh_cleanup ;;
        units) _ci_rh_units ;;
        hooks) _ci_rh_hooks ;;
        hook) _ci_rh_hook "$@" ;;
        check) _ci_rh_check ;;
        clean) _ci_rh_clean ;;
        clean-archive) _ci_rh_clean_archive "$@" ;;
        host-prep) _ci_rh_host_prep ;;
        runner-fetch) _ci_rh_runner_fetch "$@" ;;
        runner-hook-env) _ci_rh_runner_hook_env "$@" ;;
        runner-restart-policy) _ci_rh_restart_policy ;;
        full-reset-check) _ci_rh_full_reset_check ;;
        full-reset-clean) _ci_rh_full_reset_clean ;;
        set-hostname) _ci_rh_set_hostname "$@" ;;
        purge-pve-check) _ci_rh_purge_pve_check ;;
        purge-pve) _ci_rh_purge_pve ;;
        sccache-check) _ci_rh_sccache_check ;;
        sccache-fetch) _ci_rh_sccache_fetch "$@" ;;
        *)
            ci_log "[CI-ERROR-RUNNER-0110]" "mode=\"${mode}\" reason=\"unknown mode\" known=\"cleanup units hooks hook check clean clean-archive host-prep runner-fetch runner-hook-env runner-restart-policy full-reset-check full-reset-clean set-hostname purge-pve-check purge-pve sccache-check sccache-fetch\""
            return 2
            ;;
    esac
}

# =========================================================
# DISPATCH
# =========================================================

# What: have-command NAME; rc 0 found, 1 absent, 2 bad call.
# Why: hooks ask this one owner for command lookup.
# From: Issue #1683 | PR #1912
ci_cmd_have_command() {
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        ci_log "[CI-ERROR-CORE-0012]" "args=$# reason=\"have-command needs exactly one command name\""
        return 2
    fi
    _ci_command_available "$1"
}

# What: print one entry of a named table; none if unset.
# Why: an empty key aborts bash with rc 1, not a stop.
# From: Issue #1683 | PR #1858
_ci_table_entry() {
    local -n _ci_tab="$1"
    [ -z "$2" ] || printf '%s' "${_ci_tab[$2]:-}"
}

# What: Route a subcommand to its engine function.
# Why: One table is membership and dispatch; no second list.
# From: Issue #1683
ci_main() {
    local command="${1:-}" fn
    if [ "$#" -gt 0 ]; then shift; fi
    fn="$(_ci_table_entry CI_DISPATCH "${command}")" || return 2
    if [ -z "${fn}" ]; then
        ci_log "[CI-ERROR-CORE-0002]" "command=\"${command}\" reason=\"unknown subcommand\" known=\"${!CI_DISPATCH[*]}\""
        return 2
    fi
    # What: run the lookup before temp, proxy, manifest.
    # Why: a git hook has no manifest, temp root or network.
    # From: Issue #1683 | PR #1912
    case "${command}" in have-command) "${fn}" "$@"; return "$?" ;; esac
    _ci_tmp_init || return "$?"
    _ci_proxy_init || return "$?"
    _ci_git_trust_init || return "$?"
    # What: skip manifest for build-only commands
    # Why: bind-mounted stage has no SOT present
    # From: Issue #1683
    case "${command}" in check|rust-build|apk-setup|image-setup) ;; *) ci_require_manifest || return "$?" ;; esac
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
    local _ci_ss_f _ci_ss_l1 _ci_ss_rc _ci_ss_re='^#![[:space:]]*/([^[:space:]]*/)?(env[[:space:]]+)?(ba)?sh([[:space:]]|$)'
    _ci_scan_files _ci_ss_all "$2" || return 2
    _ci_ss_out=()
    for _ci_ss_f in "${_ci_ss_all[@]}"; do
        case "${_ci_ss_f##*/}" in
            *.sh|*.bash|*.bats) _ci_ss_out+=("${_ci_ss_f}"); continue ;;
            *.*|Dockerfile) continue ;;
        esac
        # What: read the first line; rc 1 is EOF only.
        # Why: an empty file is a valid input.
        # From: Issue #1683 | PR #1912
        _ci_ss_l1=""
        _ci_ss_rc=0
        if [ -r "${_ci_ss_f}" ]; then
            IFS= read -r _ci_ss_l1 < "${_ci_ss_f}" || _ci_ss_rc=$?
        else
            _ci_ss_rc=2
        fi
        if [ "${_ci_ss_rc}" -gt 1 ]; then
            ci_log "[CI-ERROR-CHECK-0164]" "file=\"${_ci_ss_f}\" rc=${_ci_ss_rc} reason=\"first line unreadable\""
            return 2
        fi
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

# What: shfmt's JSON syntax tree of one source into $2.
# Why: shell checks read the parser's tree, not raw text.
# From: Issue #1683 | PR #1858
_ci_shell_ast() {
    local f="$1" ast="$2" src lang=bash
    case "${f##*/}" in
        Dockerfile)
            src="$(_ci_run "[CI-ERROR-CHECK-0165]" "file=\"${f}\" reason=\"Dockerfile lines unreadable\"" _ci_dockerfile_logical_lines "${f}")" || return 2
            # What: RUN shell text; SHELL pipefail -> set.
            # Why: exec-form RUN is JSON; SHELL sets -o.
            # From: Issue #1683 | PR #1858
            src="$(_ci_run "[CI-ERROR-CHECK-0163]" "file=\"${f}\" reason=\"RUN shell not extracted\"" awk "$(cat <<'PROG'
                { t = $0; sub(/^[[:space:]]+/, "", t) }
                toupper(substr(t, 1, 6)) == "SHELL " && t ~ /pipefail/ { print "set -o pipefail"; next }
                toupper(substr(t, 1, 4)) != "RUN " { next }
                {
                    t = substr(t, 5)
                    while (match(t, /^[[:space:]]*--[A-Za-z-]+(=[^[:space:]]*)?[[:space:]]+/)) t = substr(t, RLENGTH + 1)
                    sub(/^[[:space:]]+/, "", t)
                    if (substr(t, 1, 1) != "[") print t
                }
PROG
                )" <<< "${src}")" || return 2 ;;
        *)
            [[ "${f##*/}" != *.bats ]] || lang=bats
            src="$(_ci_run "[CI-ERROR-CHECK-0166]" "file=\"${f}\" reason=\"source unreadable\"" cat -- "${f}")" || return 2 ;;
    esac
    _ci_run -s -o "${ast}" "[CI-ERROR-CHECK-0162]" "file=\"${f}\" lang=\"${lang}\" reason=\"shfmt cannot parse the source\"" \
        shfmt -ln "${lang}" --to-json <<< "${src}"
}

# What: jq over a shfmt tree: status-read and pipe findings.
# Why: one walk per file feeds both shell guards.
# From: Issue #1683 | PR #1858
_CI_JQ_SHELL_FINDINGS="$(cat <<'PROG'
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
    ($pipes[0] | [.. | objects | select(.Type == "BinaryCmd") | .Op]) as $ops
    | if ($ops | length) != 2 then error("pipe probe Op codes: \($ops)") else . end
    | [.. | if type == "array" then
            select(length > 1 and (.[0] | type == "object" and has("Cmd"))) as $l
            | range(0; ($l | length) - 1) as $i
            | select($l[$i].Cmd.Type? == "IfClause" and ($l[$i].Cmd | elseless))
            | $l[$i + 1] | reads | "status\tfi\t\(.)"
        elif type != "object" then empty
        elif has("Cond") and has("Then") and (.Cond | length) > 0 and .Cond[-1].Negated == true then
            (.Then[0] // empty) | reads | "status\tneg\t\(.)"
        elif .Type == "CallExpr" then
            argv | select(.[0] == "set" and any(.[1:][]; test("pipefail"))) | "pipefail"
        elif .Type == "BinaryCmd" and (.Op | IN($ops[])) then
            select(.Y.Cmd.Type? == "CallExpr" and (.Y.Cmd | argv | early))
            | "pipe\t\(.Pos.Line)\t\(.Y.Cmd | argv | join(" "))"
        else empty end] as $r
    | any($r[]; . == "pipefail") as $pf
    | $r[] | select(. != "pipefail" and ($pf or (startswith("pipe\t") | not)))
PROG
    )"

# What: tagged shell findings of one source (status, pipe).
# Why: one parse, one walk; $2 tree file, $3 pipe probe.
# From: Issue #1683 | PR #1858
_ci_shell_findings() {
    local f="$1" ast="$2" probe="$3"
    _ci_shell_ast "${f}" "${ast}" || return 2
    _ci_run "[CI-ERROR-CHECK-0167]" "file=\"${f}\" reason=\"syntax tree query failed\"" \
        jq -r --slurpfile pipes "${probe}" "${_CI_JQ_SHELL_FINDINGS}" "${ast}"
}

# What: Fail on any listed text file carrying CRLF.
# Why: eol=lf can be bypassed (API write, pre-attr commit).
# From: Issue #1683
_ci_check_line_endings() {
    local -a _ci_override=("$@") files=()
    _ci_scan_files files _ci_override || return 2
    local eol row
    local -a offenders=()
    # What: git's eol view; w/crlf or w/mixed is CRLF.
    # Why: git tells text from binary; no extension list.
    # From: Issue #1683 | PR #1912
    [ "${#files[@]}" -eq 0 ] || eol="$(_ci_capture 0 git ls-files --eol -- "${files[@]}")" || return 2
    while IFS= read -r row; do
        case "${row}" in *" w/crlf "*|*" w/mixed "*) offenders+=("${row#*$'\t'}") ;; esac
    done <<< "${eol:-}"
    if [ "${#offenders[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0002]" "reason=\"CRLF found; repo requires LF\"" "$(printf '%s\n' "${offenders[@]}")"
        return 1
    fi
    printf 'line-endings=clean files=%s\n' "${#files[@]}"
}

# What: the SOT exemption globs as EREs, loaded once.
# Why: _ci_glob_ere owns glob syntax; a read error fails.
# From: Issue #1683 | PR #1912
_ci_prose_exempt_load() {
    local list state g
    list="$(_ci_block_entry_list file_headers "" exempt)" || return 2
    state="$(_ci_block_entry_field release "" validation_state)" || return 2
    _CI_PROSE_EXEMPT=()
    while IFS= read -r g; do
        [ -z "${g}" ] || _CI_PROSE_EXEMPT+=("$(_ci_glob_ere "**/${g}")")
    done <<<"${list}"$'\n'"${state}"
}

# What: true for a path a SOT exemption glob matches.
# Why: one owner for vendored, binary and prose skips.
# From: Issue #1683 | PR #1912
_ci_prose_excluded() {
    local re
    for re in "${_CI_PROSE_EXEMPT[@]}"; do
        [[ "$1" =~ ${re} ]] && return 0
    done
    return 1
}

# What: per-file header, size and chronology rules.
# Why: one awk run reads each file once, before the lexer.
# From: Issue #1683 | PR #1912
_CI_AWK_COMMENTS='
    BEGIN {
        v = "(caught|found|flagged|spotted|identified|discovered|noticed)"
        b0 = "(^|[^a-z0-9_])"; b1 = "([^a-z0-9_]|$)"
        rc = b0 v "[[:space:]]+(in|during)[[:space:]]+((a|the|this)[[:space:]]+)?"
        rc = rc "(code[[:space:]]+|pr[[:space:]]+|peer[[:space:]]+)?(self-)?review" b1
        rc = rc "|" b0 "review[^a-z0-9_.]([^a-z.]{0,18}[^a-z0-9_.])?" v b1
        rc = rc "|" b0 "(before|prior to|until)[[:space:]]+this[[:space:]]+(fix|change|commit|patch)" b1
        rc = rc "|" b0 "review[[:space:]]+finding" b1
        lr = "[(](see[[:space:]]+)?line([[:space:]]+~?|~)[0-9]+"
    }
    # What: the comment grammar of a path; "" if none.
    # Why: a type without a grammar must fail, never pass.
    # From: Issue #1683 | PR #1858
    function cm_style(p,  b) {
        b = p; sub(/.*\//, "", b)
        if (p ~ /(^|\/)services\/ui\/src\/templates\/[^\/]*\.html$/) return "tera"
        if (b ~ /\.html$/) return "html"
        if (b ~ /\.rs$/) return "rust"
        if (b ~ /\.lua$/) return "lua"
        if (b ~ /\.js$/) return "js"
        if (b ~ /\.css$/) return "css"
        if (b ~ /\.ya?ml$/) return "yaml"
        if (b ~ /\.(sh|bats|toml|conf|txt|dockerignore)$/) return "hash"
        if (b ~ /^(Dockerfile|\.gitattributes|\.gitignore|CODEOWNERS)$/) return "hash"
        return ""
    }
    # What: a header line in the native comment syntax.
    # Why: the SOT holds the text; the style the markers.
    # From: Issue #1683 | PR #1912
    function cm_hdr(t) {
        if (style == "tera") return "{# " t " #}"
        if (style == "html") return "<!-- " t " -->"
        if (style == "rust") return "//! " t
        if (style == "lua") return "-- " t
        if (style == "js") return "// " t
        if (style == "css") return "/* " t " */"
        return "# " t
    }
    # What: true if a #N outside quotes is a From: number.
    # Why: a ref belongs in From: only (AG-CODE-012).
    # From: Issue #1683 | PR #1856
    function cm_dup(s,  len, i, ch, pv, d) {
        len = length(s)
        for (i = 1; i <= len; i++) {
            ch = substr(s, i, 1)
            if (ch != "#") continue
            pv = (i > 1) ? substr(s, i - 1, 1) : ""
            if (pv ~ /[A-Za-z0-9_$&{#]/) continue
            d = substr(s, i + 1)
            if (match(d, /^[0-9]+/) && RLENGTH < 6 && substr(d, RLENGTH + 1, 1) !~ /[A-Za-z0-9_]/) return 1
        }
        return 0
    }
    # What: one finding row: kind, tab, text.
    # Why: bash sorts the rows into one report per rule.
    # From: Issue #1683 | PR #1912
    function cm_out(k, t) { printf "%s\t%s\n", k, t }
    # What: YAML text blocks led by What: are strict.
    # Why: AG-CODE-012 holds for text fields too.
    # From: Issue #1683 | PR #1912
    function cm_stmt(  i, b, t, cw, cy, cf, st, pb) {
        b = 0; pb = 0
        for (i = 1; i <= n + 1; i++) {
            if (i <= n && S[i] && S[i] == b) { st = 1 } else st = 0
            if (!st && b) {
                if (cw != 1 || cy != 1 || cf > 1) cm_out("C", cur ":" ss ": text block needs one What:, one Why:, at most one From:")
                b = 0
            }
            if (i > n || !S[i]) continue
            if (!st) { b = S[i]; ss = i; cw = cy = cf = 0; pb = 0 }
            t = ST[i]
            if (t == "") { if (!pb) pb = i; continue }
            if (pb) { cm_out("C", cur ":" pb ": blank line inside a text block (stacked blocks)"); pb = 0 }
            if (length(L[i]) > 60) cm_out("C", cur ":" i ": " length(L[i]) " chars (max 60): " L[i])
            if (t ~ /^What:/) cw++
            else if (t ~ /^Why:/) cy++
            else if (t ~ /^From:/) {
                cf++
                if (t !~ /^From: (Issue #[0-9]+|PR #[0-9]+|Issue #[0-9]+ \| PR #[0-9]+)$/) cm_out("C", cur ":" i ": From: allows one Issue and one PR only: " L[i])
            } else cm_out("C", cur ":" i ": text block line is not What:, Why: or From: (no continuation): " L[i])
            if (t ~ /^(What|Why):/ && t ~ /#[0-9]/) cm_out("C", cur ":" i ": issue/PR ref in What/Why (use From:): " L[i])
        }
    }
    # What: all rules for the file held in L[1..n].
    # Why: the lexer runs once; every rule reads its arrays.
    # From: Issue #1683 | PR #1912
    function cm_file(  i, b, ok, leg, pc, sc, lc, bl, bs, rl, rs, t, k) {
        cl_lex()
        b = cur; sub(/.*\//, "", b)
        if (style == "rust") ok = (L[1] == "//!")
        else ok = (L[1] == "" || L[1] ~ /^#!/)
        if (b == "Dockerfile" && tolower(L[1]) ~ /^#[[:space:]]*(syntax|escape|check)[[:space:]]*=[[:space:]]*.+$/) ok = 1
        if (!ok) cm_out("H", cur ": bad line 1 marker")
        if (L[2] != h2) cm_out("H", cur ": line 2 must be: " h2)
        if (L[3] != h3) cm_out("H", cur ": line 3 must be: " h3)
        leg = cm_hdr(tolower(hp)); pc = sc = lc = 0
        for (i = 1; i <= n && i <= 20; i++) { pc += (L[i] == h2); sc += (L[i] == h3); lc += (L[i] == leg) }
        if (pc != 1) cm_out("H", cur ": project header count " pc " not 1")
        if (sc != 1) cm_out("H", cur ": SPDX count " sc " not 1")
        if (lc != 0) cm_out("H", cur ": legacy lowercase header present")
        bl = rl = rs = 0
        for (i = 1; i <= n + 1; i++) {
            if (i <= n && F[i] && T[i] ~ /^(What|Why|From):/) {
                if (bl == 0) bs = i
                bl++
                if (length(L[i]) > 60) cm_out("C", cur ":" i ": " length(L[i]) " chars (max 60): " L[i])
                if (T[i] ~ /^(What|Why):/ && T[i] ~ /#[0-9]/) cm_out("C", cur ":" i ": issue/PR ref in What/Why (use From:): " L[i])
                if (T[i] ~ /^From:/ && T[i] !~ /^From: (Issue #[0-9]+|PR #[0-9]+|Issue #[0-9]+ \| PR #[0-9]+)$/) cm_out("C", cur ":" i ": From: allows one Issue and one PR only: " L[i])
                continue
            }
            if (bl > 3) cm_out("C", cur ":" bs ": block " bl " lines (max 3)")
            bl = 0
        }
        for (i = 1; i <= n + 1; i++) {
            if (i <= n && C[i]) { if (!rs) rs = i; if (!D[i]) rl++; continue }
            if (rl > 3) cm_out("C", cur ":" rs ": story-telling block (" rl " lines)")
            rs = rl = 0
        }
        cm_stmt()
        for (i = 1; i <= n; i++) {
            t = tolower(L[i])
            if (t ~ rc || t ~ lr) cm_out("R", cur ":" i ":" L[i])
            if (i > 1 && F[i - 1] && F[i] && tolower(T[i - 1] " " T[i]) ~ rc) cm_out("R", cur ":" i - 1 ": " T[i - 1] " " T[i])
            if (L[i] !~ /From:/ && cm_dup(L[i])) cm_out("W", cur ":" i ": " L[i])
        }
    }
    # What: a new file ends the last one and resets state.
    # Why: arrays of one file must not leak into the next.
    # From: Issue #1683 | PR #1912
    FNR == 1 {
        if (cur != "") cm_file()
        delete L; delete F; delete C; delete D; delete T; delete H; delete K; delete IB; delete S; delete ST
        cur = FILENAME; style = cm_style(cur)
        if (style == "") { cm_out("G", cur); cur = ""; nextfile }
        h2 = cm_hdr(hp); h3 = cm_hdr(hs)
    }
    END { if (cur != "") cm_file() }
'

# What: AG-HDR header, AG-CODE-012 size and chronology.
# Why: one owner reads each file once (AG-CODE-011).
# From: Issue #1683 | PR #1912
_ci_check_comments() {
    local -a _ci_override=("$@") files=() todo=() hdr=() size=() chron=() dup=() nogr=() bad=()
    local path out line project spdx arc=0 rc=0
    _ci_scan_files files _ci_override || return 2
    _ci_prose_exempt_load || return 2
    _ci_block_entry_fields file_headers "" project project spdx spdx || return 2
    for path in "${files[@]}"; do
        _ci_prose_excluded "${path}" && continue
        if [ -s "${path}" ]; then todo+=("${path}"); else hdr+=("${path}: empty file has no header"); fi
    done
    # What: counts characters, not bytes, per line
    # Why: AG-CODE-012 sets a character limit
    # From: Issue #1683 | PR #1858
    if [ "${#todo[@]}" -gt 0 ]; then
        out="$(LC_ALL=C.UTF-8 awk -v hp="${project}" -v hs="${spdx}" "${_CI_AWK_COMMENTS}${_CI_AWK_COMMENT_LEX}" "${todo[@]}" 2>&1)" || arc=$?
    fi
    while IFS= read -r line; do
        case "${line%%$'\t'*}" in
            H) hdr+=("${line#*$'\t'}") ;;
            C) size+=("${line#*$'\t'}") ;;
            R) chron+=("${line#*$'\t'}") ;;
            W) dup+=("${line#*$'\t'}") ;;
            G) nogr+=("${line#*$'\t'}") ;;
            *) [ -z "${line}" ] || bad+=("${line}") ;;
        esac
    done <<<"${out:-}"
    # What: an awk error or stray output stops the check
    # Why: AG-VAL-001: an awk warning is an error
    # From: Issue #1683 | PR #1858
    if [ "${arc}" -ne 0 ] || [ "${#bad[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0129]" "rc=${arc} reason=\"comment scan failed\"" "${out}"
        return 2
    fi
    if [ "${#nogr[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0153]" "files=${#nogr[@]} reason=\"no comment grammar for this file type\"" "$(printf '%s\n' "${nogr[@]}")"
        rc=1
    fi
    if [ "${#hdr[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0003]" "reason=\"invalid file header layout\"" "$(printf '%s\n' "${hdr[@]}")"
        rc=1
    fi
    if [ "${#size[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0128]" "scanned=${#todo[@]} reason=\"comment contract violations\"" "$(printf '%s\n' "${size[@]}")"
        rc=1
    fi
    # What: a bare #N outside From: fails the check.
    # Why: AG-VAL-001: a warning is no success.
    # From: Issue #1683 | PR #1912
    if [ "${#dup[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0078]" "reason=\"bare #N duplicated outside From:\"" "$(printf '%s\n' "${dup[@]}")"
        rc=1
    fi
    if [ "${#chron[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0080]" "reason=\"review-chronology / stale line-ref\"" "$(printf '%s\n' "${chron[@]}")"
        rc=1
    fi
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf 'comments=clean files=%s\n' "${#todo[@]}"
}

# What: awk lexer: F/C/D/T per line of L[1..n] for a style.
# Why: one comment grammar owner for every comment check.
# From: Issue #1683 | PR #1858
_CI_AWK_COMMENT_LEX="$(cat <<'PROG'
    BEGIN {
        sq = sprintf("%c", 39)
        mb = (length("é") == 1); lead_re = "^[\300-\367]$"; cont_re = "^[\200-\277]$"
    }
    { L[FNR] = $0; sub(/\r$/, "", L[FNR]); n = FNR }
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
    function cl_hash(heredoc,  i, line, chk, iny, ind, t, sf, sb) {
        hh = 1; ht = 0; sn = 0
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
                if (line ~ /^[[:space:]]*$/) { if (sb) { S[i] = sb; ST[i] = "" } continue }
                match(line, /[^ ]/)
                if (RSTART - 1 > ind) {
                    t = substr(line, RSTART)
                    if (sf) { sf = 0; if (t ~ /^What:/) sb = ++sn }
                    if (sb) { S[i] = sb; ST[i] = t }
                    continue
                }
                iny = 0
            }
            if (line ~ /^[[:space:]]*#/) { C[i] = 1; continue }
            if (heredoc) cl_heredocs(line)
            else if (line ~ /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][+-]?[0-9]?[[:space:]]*$/) {
                match(line, /[^ ]/); ind = RSTART - 1; iny = 1; sf = 1; sb = 0
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
        hdr = (n >= 3 && L[2] == h2 && L[3] == h3) ? 3 : 0
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
PROG
)"

# What: fail on code that shortens a commit SHA.
# Why: AG-REL-015 SHA tags carry all 40 hex digits.
# From: Issue #1683 | PR #1912
_ci_check_deny_short_sha() {
    local kw='([Ss][Hh][Aa]|[Cc][Oo][Mm][Mm][Ii][Tt]|[Cc][Aa][Nn][Dd][Ii][Dd][Aa][Tt][Ee]|[Rr][Ee][Vv][Ii][Ss][Ii][Oo][Nn])'
    # What: bash substring, git short forms, Rust slices.
    # Why: a name part like shared or shape is no SHA.
    # From: Issue #1683 | PR #1912
    local sh_pat="\\\$\\{([A-Za-z0-9]*_)*${kw}[0-9]*(_[A-Za-z0-9_]*)?(\\[[^]]*\\])?:[^-=?+]"
    local git_pat='git[[:space:]][^|;&]*(rev-parse[^|;&]*--short|--abbrev|--(format|pretty)=[^[:space:]]*%h)'
    local rs_pat="(^|[^A-Za-z0-9_])([A-Za-z0-9]*_)*${kw}[0-9]*(_[A-Za-z0-9_]*)?(\\.as_str\\(\\)|\\.as_bytes\\(\\))?(\\[|\\.get\\()[[:space:]]*[A-Za-z0-9_]*[[:space:]]*\\.\\."
    local -a _ci_override=("$@") files=() yml_rs=() viol=() rs=() other=()
    local -A seen=()
    local path out
    # What: shell set plus workflow and Rust files.
    # Why: one shell-file owner; run blocks, Rust slice.
    # From: Issue #1683 | PR #1912
    _ci_shell_sources files _ci_override dockerfiles || return 2
    _ci_scan_files yml_rs _ci_override '.github/workflows/*.yml' '*.rs' || return 2
    for path in "${files[@]}" "${yml_rs[@]}"; do
        [ -z "${seen[${path}]:-}" ] || continue
        seen[${path}]=1
        case "${path}" in *.rs) rs+=("${path}") ;; *) other+=("${path}") ;; esac
    done
    # What: one grep per kind over all its files.
    # Why: a grep per file cost a temp file and a fork each.
    # From: Issue #1683 | PR #1912
    if [ "${#other[@]}" -gt 0 ]; then
        out="$(_ci_capture 1 grep -EnH -e "${sh_pat}" -e "${git_pat}" -- "${other[@]}")" || return 2
        [ -z "${out}" ] || viol+=("${out}")
    fi
    if [ "${#rs[@]}" -gt 0 ]; then
        out="$(_ci_capture 1 grep -EnH -e "${rs_pat}" -- "${rs[@]}")" || return 2
        [ -z "${out}" ] || viol+=("${out}")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0005]" "reason=\"short commit SHA (AG-REL-015)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'deny-short-sha=clean files=%s\n' "${#seen[@]}"
}

# What: Fail on a banned-language file or interpreter.
# Why: AG-REL-001 Rust+shell; catches heredoc lang too.
# From: Issue #1683
_ci_check_language_policy() {
    local -a _ci_override=("$@") files=() shell=()
    local -A is_sh=()
    _ci_scan_files files _ci_override || return 2
    _ci_shell_sources shell _ci_override || return 2
    local path inline
    for path in "${shell[@]}"; do is_sh["${path}"]=1; done
    local -a viol=() scan=()
    _ci_prose_exempt_load || return 2
    for path in "${files[@]}"; do
        # What: vendored files (SOT file_headers.exempt).
        # Why: AG-REL-001 governs authored, not vendored.
        # From: Issue #1683 | PR #1912
        ! _ci_prose_excluded "${path}" || continue
        case "${path}" in
            *.py|*.pyc|*.pyw|*.rb|*.php|*.pl|*.pm|*.js|*.mjs|*.cjs|*.ts) viol+=("${path}: banned-language file"); continue ;;
        esac
        if [ -n "${is_sh[${path}]:-}" ] || [[ "${path}" == *.yml || "${path}" == *.yaml ]]; then
            scan+=("${path}")
        fi
    done
    # What: one grep -l over every shell and YAML file.
    # Why: a grep per file cost a temp file and a fork each.
    # From: Issue #1683 | PR #1912
    if [ "${#scan[@]}" -gt 0 ]; then
        inline="$(_ci_capture 1 grep -lE '(python3?|perl|ruby|node)[[:space:]]+-[eEc]|<<-?[[:space:]]*"?(PY|PYEOF|PYTHON|PERL|RUBY)' -- "${scan[@]}")" || return 2
        while IFS= read -r path; do
            [ -z "${path}" ] || viol+=("${path}: inline foreign-language interpreter")
        done <<< "${inline}"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0007]" "reason=\"banned language (AG-REL-001)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'language-policy=clean files=%s\n' "${#files[@]}"
}

# What: Fail on an image ref the SOT does not own.
# Why: base_images and ci.sh own images (actions: 0095).
# From: Issue #1683 | PR #1858
_ci_check_mutable_refs() {
    local -a _ci_override=("$@") files=() yml=() dock=() viol=()
    _ci_scan_files files _ci_override '.github/workflows/*.yml' "${CI_DOCKERFILE_SPECS[@]}" || return 2
    local path out row
    for path in "${files[@]}"; do
        case "${path}" in
            *.yml|*.yaml) yml+=("${path}") ;;
            */Dockerfile|Dockerfile) dock+=("${path}") ;;
        esac
    done
    # What: one grep per pattern over all files of a kind.
    # Why: a grep or sed per file or line cost a fork each.
    # From: Issue #1683 | PR #1912
    if [ "${#yml[@]}" -gt 0 ]; then
        # What: grep pattern in ARG not ref.
        # Why: PROMOTE_TAGS greps ARG :latest.
        # From: Issue #1683 | PR #1858
        out="$(_ci_capture 1 grep -nHE "${CI_ARG_TOOLCHAIN_IMAGE}=[^[:space:]]*:latest" -- "${yml[@]}")" || return 2
        while IFS= read -r row; do
            [[ -z "${row}" || "${row}" == *"ARG ${CI_ARG_TOOLCHAIN_IMAGE}="* ]] || viol+=("${row%%:*} img-default-latest: ${row#*:}")
        done <<< "${out}"
    fi
    if [ "${#dock[@]}" -gt 0 ]; then
        # What: FROM is an ARG, a stage alias or scratch.
        # Why: base_images owns each image; no pin here.
        # From: Issue #1683 | PR #1858
        out="$(_ci_capture 0 awk "$(cat <<'PROG'
            FNR == 1 { delete alias }
            tolower($0) ~ /^#[[:space:]]*syntax[[:space:]]*=/ { print FILENAME ":" FNR " syntax-image: " $0; next }
            toupper($1) == "FROM" {
                i = 2; while ($i ~ /^--/) i++
                img = tolower($i)
                if (img !~ /^\$\{/ && img != "scratch" && !(img in alias)) print FILENAME ":" FNR " FROM-literal: " $0
                if (toupper($(i + 1)) == "AS") alias[tolower($(i + 2))] = 1
            }
PROG
        )" "${dock[@]}")" || return 2
        while IFS= read -r row; do [ -z "${row}" ] || viol+=("${row}"); done <<< "${out}"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0008]" "reason=\"image reference outside the SOT\"" "$(printf '%s\n' "${viol[@]}")"
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

# What: Fail on a $? that reads an if, or a SIGPIPE pipe.
# Why: AG-VAL-029/030/032; one shfmt tree per file.
# From: Issue #1683 | PR #1912
_ci_check_shell_guards() {
    local -a _ci_override=("$@") files=() status=() pipe=()
    local path produced tag a b loc ast probe
    _ci_shell_sources files _ci_override dockerfiles || return 2
    ast="$(_ci_mktemp "${CI_TMPDIR}/ci-ast.XXXXXX")" || return 2
    probe="$(_ci_mktemp "${CI_TMPDIR}/ci-pipe.XXXXXX")" || { rm -f "${ast}"; return 2; }
    # What: this shfmt parses | and |& for their Op codes
    # Why: Op numbers move between shfmt versions
    # From: Issue #1683 | PR #1912
    printf 'a | b\na |& b\n' > "${ast}"
    _ci_shell_ast "${ast}" "${probe}" || { rm -f "${ast}" "${probe}"; return 2; }
    for path in "${files[@]}"; do
        produced="$(_ci_shell_findings "${path}" "${ast}" "${probe}")" || { rm -f "${ast}" "${probe}"; return 2; }
        while IFS=$'\t' read -r tag a b; do
            loc="${path}:"
            [ "${path##*/}" != Dockerfile ] || loc="${path}: RUN text line "
            case "${tag}" in
                pipe) pipe+=("${loc}${a}: live pipe into '${b}' under pipefail") ;;
                status)
                    if [ "${a}" = neg ]; then
                        status+=("${loc}${b}: first \$? under 'if ! CMD' is the negation's 0 -- use 'CMD || rc=\$?'")
                    else
                        status+=("${loc}${b}: \$? after an else-less if is the if's 0 -- use 'if CMD; then rc=0; else rc=\$?; fi'")
                    fi ;;
            esac
        done <<< "${produced}"
    done
    rm -f "${ast}" "${probe}"
    [ "${#pipe[@]}" -eq 0 ] || ci_error "[CI-ERROR-CHECK-0011]" "reason=\"live pipe into early-exit consumer (SIGPIPE)\"" "$(printf '%s\n' "${pipe[@]}")"
    [ "${#status[@]}" -eq 0 ] || ci_error "[CI-ERROR-CHECK-0065]" "reason=\"\$? reads an if's status, not the command's (AG-VAL-029)\"" "$(printf '%s\n' "${status[@]}")"
    [ "$(( ${#pipe[@]} + ${#status[@]} ))" -eq 0 ] || return 1
    printf 'shell-guards=clean files=%s\n' "${#files[@]}"
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
        out="$(_ci_capture 0 awk "$(cat <<'PROG'
            { line = (cont != "" ? cont " " : "") $0; cont = "" }
            /\\$/ { cont = substr(line, 1, length(line) - 1); if (!start) start = NR; next }
            line ~ /^[[:space:]]*\[\[?[[:space:]]/ && line ~ /\]\]?[[:space:]]*&&[[:space:]]*\[/ \
                && line ~ /\]\]?[[:space:]]*$/ && line !~ /\|\|/ {
                print (start ? start : NR) ": " line
            }
            { start = 0 }
PROG
        )" "${path}")" || return 2
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
                if _ci_list_has "${f}" "${md}"; then
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
    local suite="${CI_SCRIPT_DIR}/ci.bats" jobs cpus rc=0 gate tests
    if [ -n "${BATS_TEST_FILENAME:-}" ]; then
        printf 'ci-bats=NOT-RUN reason="already inside a bats run; no nested suite"\n'
        return 0
    fi
    # What: no @test, no bats start; tests need a PR ACK
    # Why: an empty suite passes and only costs a start
    # From: Issue #1683 | PR #1912
    tests="$(_ci_capture 1 grep -c '^@test ' "${suite}")" || return 2
    if [ "${tests}" -eq 0 ]; then
        printf 'ci-bats=NOT-RUN reason="suite holds no test"\n'
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
                if (s ~ /\[\[? +"\$\((_ci_block_entry_field|_ci_block_entry_list|_ci_block_keys|_ci_channel_field|ci_service_field|ci_services|ci_build_targets|ci_service_context_paths)[ )]/)
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

# What: 0 when the PR author skips the PR text checks
# Why: one SOT author list for the title and template checks
# From: Issue #1683 | PR #1858
_ci_pr_check_exempt() {
    local authors
    authors="$(_ci_block_entry_list pr_policy "" check_exempt_authors)" || return 2
    [ -n "${PR_AUTHOR:-}" ] && _ci_list_has "${PR_AUTHOR}" "${authors}"
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

# What: an external deploy image must be a SOT base image.
# Why: one owner per external image; no copy elsewhere.
# From: Issue #1683
_ci_check_stable_external_images() {
    local -a dirs=("$@")
    local d line img k allowed=" " dep
    if [ "${#dirs[@]}" -eq 0 ]; then
        dep="$(_ci_compose_path)" || return 2
        dirs=("${dep%/*}")
    fi
    local -a viol=()
    # What: the exact SOT base image values.
    # Why: compose must match them; other values are drift.
    # From: Issue #1683 | PR #1858
    local keys val
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
            # Why: any literal host (ghcr too) is SOT.
            # From: Issue #1683 | PR #1858
            case "${img}" in
                *"\${LANCACHE"*|'') continue ;;
            esac
            img="${img%\"}"; img="${img#\"}"
            case "${allowed}" in
                *" ${img} "*) ;;
                *) viol+=("${d}: external image is not a SOT base image: ${img}") ;;
            esac
        done <<<"${produced}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0014]" "reason=\"external image not in SOT\"" "$(printf '%s\n' "${viol[@]}")"
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
    local body="${PR_BODY:-}" ex=0 checkbox sec
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
    local content stripped trimmed count
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
        # From: Issue #1683 | PR #1858
        stripped="$(_ci_md_strip_comments "${content}")" || return 2
        stripped="$(_ci_capture 1 grep -v '^```' <<<"${stripped}")" || return 2
        trimmed="$(tr -d '[:space:]' <<<"${stripped}")"
        [ -n "${trimmed}" ] || { missing+=("${sec}: empty (only template placeholder left)"); continue; }
        if [ "${sec}" = "${checkbox}" ] && ! _ci_text_has '^- \[[xX]\]' "${content}"; then
            missing+=("${checkbox}: no checkbox marked (- [x] ...)")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0089]" "template=\"${template#"${CI_REPO_ROOT:-.}/"}\" reason=\"the PR body must use the PR template, own layouts are refused; missing/empty required section(s)\"" "$(printf '%s\n' "${missing[@]}")"
        return 1
    fi
    printf 'pr-template=ok\n'
}

# What: file, start line, byte size of each run: block
# Why: awk length counts chars; LC_ALL=C makes it bytes
# From: Issue #1683
_ci_measure_run_blocks() {
    LC_ALL=C awk '
        function leadspace(s) { match(s, /^[ \t]*/); return RLENGTH }
        function flush_block() {
            if (started) printf "%s\t%d\t%d\n", fname, block_start, block_bytes
            in_block = 0; started = 0
        }
        FNR == 1 { flush_block(); fname = FILENAME }
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
                in_block = 1; block_start = FNR + 1; block_bytes = 0
                if (digit != "") { started = 1; content_indent = key_indent + digit }
                else { started = 0; content_indent = 0 }
            }
        }
        END { flush_block() }
    ' "$@"
}

# What: list the workflow files of a directory.
# Why: a guard that read no workflow must fail, not pass
# From: Issue #1683 | PR #1858
_ci_workflow_files() {
    local -n _ci_wf_out="$1"
    local _ci_wf_dir="$2" _ci_wf_f
    _ci_wf_out=()
    if [ ! -d "${_ci_wf_dir}" ]; then
        ci_error "[CI-ERROR-CHECK-0016]" "dir=\"${_ci_wf_dir}\" reason=\"not a directory\"" "$(ls -ld -- "${_ci_wf_dir}" 2>&1)"
        return 2
    fi
    for _ci_wf_f in "${_ci_wf_dir}"/*.yml "${_ci_wf_dir}"/*.yaml; do
        [ -f "${_ci_wf_f}" ] && _ci_wf_out+=("${_ci_wf_f}")
    done
    if [ "${#_ci_wf_out[@]}" -eq 0 ]; then
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
    counts="$(_ci_capture 0 wc -lc "${files[@]}")" || return 2
    # What: skip the wc total row; file rows carry the dir
    # Why: a workflow path is never the bare word total
    # From: Issue #1683 | PR #1912
    while read -r lines bytes file; do
        [ "${file}" != total ] || continue
        [ "${lines}" -gt "${max_lines}" ] && viol+=("${file}: ${lines} lines > ${max_lines}")
        [ "${bytes}" -gt "${max_bytes}" ] && viol+=("${file}: ${bytes} bytes > ${max_bytes}")
    done <<< "${counts}"
    block_report="$(_ci_measure_run_blocks "${files[@]}")" || {
        ci_log "[CI-ERROR-CHECK-0122]" "dir=\"${dir}\" reason=\"run blocks not measurable (raw above)\""; return 2; }
    while IFS=$'\t' read -r file block_line block_bytes; do
        [ -n "${block_line}" ] || continue
        [ "${block_bytes}" -gt "${max_block}" ] && \
            viol+=("${file}:${block_line}: run-block ${block_bytes} bytes > ${max_block}")
    done <<<"${block_report}"
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
    # What: no pull request means no PR metadata to check
    # Why: its own PAT step runs on every checks event
    # From: Issue #1683 | PR #1858
    if _ci_skip_outside_pr pr-tracking-metadata; then
        return 0
    fi
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
        if ! label_count="$(jq -e 'if type == "array" then length else error("not an array") end' <<<"${PR_LABELS_JSON}" 2>&1)"; then
            errs+=("PR labels input is not a JSON array: ${label_count}")
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
            -f repo="${repo#*/}" -F pr="${pr_number}" -f query="query(\$owner: String!, \$pr: Int!, \$repo: String!) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$pr) { projectItems(first: 10) { nodes { project { number } } } } } }")" || rc=$?
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
    local repo min_age now exact regexes raw src rows rc=0
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
    # Why: release.channels owns master and current_dev.
    # From: Issue #1683 | PR #1858
    raw="$(_ci_channel_field ref)" || return 2
    src="$(_ci_channel_field source_ref)" || return 2
    exact="$(awk '$2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2 }' <<< "${raw}"$'\n'"${src}")"
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
        -f query="query(\$owner: String!, \$name: String!, \$endCursor: String) { repository(owner: \$owner, name: \$name) { refs(refPrefix: \"refs/heads/\", first: 100, after: \$endCursor) { nodes { name target { ... on Commit { committedDate author { name } } } associatedPullRequests { totalCount } } pageInfo { hasNextPage endCursor } } } }")" || rc=$?
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
        -f query="query(\$owner: String!, \$name: String!, \$endCursor: String) { repository(owner: \$owner, name: \$name) { issues(first: 100, after: \$endCursor) { nodes { number body comments(first: 100) { nodes { body } pageInfo { hasNextPage } } } pageInfo { hasNextPage endCursor } } } }")" || rc=$?
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
            -f query="query(\$owner: String!, \$name: String!, \$number: Int!, \$endCursor: String) { repository(owner: \$owner, name: \$name) { issue(number: \$number) { comments(first: 100, after: \$endCursor) { nodes { body } pageInfo { hasNextPage endCursor } } } } }")" || rc=$?
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

# What: print top-level runs.using from an action manifest.
# Why: one parser for each fetched action.yml body.
# From: Issue #1683 | PR #1858
_ci_action_runs_using() {
    awk '
        /^runs:/ { in_runs = 1; next }
        in_runs && /^[^[:space:]]/ { exit }
        in_runs && /^[[:space:]]*using:/ { print; exit }
    ' | sed -E "s/.*using:[[:space:]]*//; s/[\"']//g; s/[[:space:]]*#.*\$//; s/[[:space:]]+\$//"
}

# What: GET one raw-content URL; body on 200.
# Why: public SHA reads need no token and no REST budget.
# From: Issue #1860 | PR #1872
_ci_raw_get() {
    local url="$1" out code conn max
    conn="$(_ci_variable CI_RAW_GET_CONNECT_TIMEOUT)" || return 2
    max="$(_ci_variable CI_RAW_GET_MAX_TIME)" || return 2
    if ! out="$(curl -sS --connect-timeout "${conn}" --max-time "${max}" --location -w '\n%{http_code}' "${url}")"; then
        printf 'raw GET %s failed: curl error (http 000)\n' "${url}" >&2
        return 1
    fi
    code="${out##*$'\n'}"
    if [ "${code}" != 200 ]; then
        printf 'raw GET %s failed: http %s\n%s\n' "${url}" "${code}" "${out%$'\n'*}" >&2
        return 1
    fi
    printf '%s\n' "${out%$'\n'*}"
}

# What: resolve external action manifest for pin.
# Why: raw tag reads, one _ci_retry owner; HTTP code kept.
# From: Issue #1860 | PR #1872
_ci_fetch_action_manifest() {
    local owner="$1" repo="$2" subpath="$3" ref="$4" file out rc code raw
    raw="$(_ci_runtime_default RAW_CONTENT_URL)" || return 2
    for file in action.yml action.yaml; do
        rc=0
        out="$(_ci_retry github-read _ci_raw_get "${raw}/${owner}/${repo}/${ref}/${subpath:+${subpath}/}${file}")" || rc=$?
        case "${rc}" in
            0) printf 'OK\n%s\n' "${out}"; return 0 ;;
            1) continue ;;
        esac
        code=000
        if [[ "${out,,}" =~ http\ ([0-9]{3}) ]]; then code="${BASH_REMATCH[1]}"; fi
        printf 'INFRA:%s\n%s\n' "${code}" "${out}"
        return 0
    done
    printf 'NOTFOUND\n'
}

# What: true if a uses: ref names this repo's own action.
# Why: owner/repo comes from the run, never hardcoded.
# From: Issue #1860 | PR #1872
_ci_action_ref_is_own() {
    [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
    case "${1,,}" in "${GITHUB_REPOSITORY,,}"/*) return 0 ;; esac
    return 1
}

# What: true if a uses: ref is an external pinned action.
# Why: local, docker, own and unpinned refs skip the fetch.
# From: Issue #1683 | PR #1858
_ci_action_ref_is_external() {
    local v="$1"
    case "${v}" in
        *@*) ;; *) return 1 ;;
    esac
    case "${v}" in
        ./*|\$/*|docker://*) return 1 ;;
    esac
    ! _ci_action_ref_is_own "${v}"
}

# What: SOT github_actions entry of an action, or empty.
# Why: one lookup for the pin check and its dead-pin pass.
# From: Issue #1683 | PR #1912
_ci_action_sot_entry() {
    local e u entries
    entries="$(_ci_block_keys github_actions)" || return 2
    for e in ${entries}; do
        u="$(_ci_block_entry_field github_actions "${e}" uses)" || return 2
        [ "${u}" != "$1" ] || { printf '%s\n' "${e}"; return 0; }
    done
}

# What: enforce Node runtime + ref hygiene on pins.
# Why: single owner of action-pin policy.
# From: Issue #1683 | PR #1858
_ci_check_action_node_versions() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}"
    local wf_dir
    wf_dir="$(_ci_repo_path CI_WORKFLOW_DIR "${repo_root}")" || return 2
    local -a scan_files=()
    local f
    _ci_workflow_files scan_files "${wf_dir}" || return 2

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
            raw="${line#*uses:}"; raw="${raw%%#*}"
            raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"
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

    # What: check each pin's runs.using for dead runtime.
    # Why: external manifests come via raw tag reads.
    # From: Issue #1683 | PR #1858
    local v using owner repo subpath ref res marker meta
    local entry used_entries=" " node_min
    node_min="$(_ci_variable CI_ACTION_NODE_MIN)" || return 2
    if [[ ! "${node_min}" =~ ^[0-9]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0142]" "got=\"${node_min}\" key=\"CI_ACTION_NODE_MIN\" reason=\"not a whole number\""
        return 2
    fi
    for v in "${uses_values[@]}"; do
        [ -n "${v}" ] || continue
        # What: a local uses: ./ path fails; workflows pass.
        # Why: CI 2.0 has no composite actions (Phase 15).
        # From: Issue #1683 | PR #1858
        if [[ "${v}" == ./* ]]; then
            case "${v}" in *.yml|*.yaml) continue ;; esac
            viol+=("local action '${v}' (in: $(_ci_ando_reffiles "${v}")); CI 2.0 has no composite actions")
            continue
        fi
        # What: a docker:// step must name a SOT base image.
        # Why: the workflow literal is no second owner.
        # From: Issue #1683 | PR #1858
        if [[ "${v}" == docker://* ]]; then
            local bkeys bk bv bhit=0
            bkeys="$(_ci_block_keys base_images all)" || return 2
            for bk in ${bkeys}; do
                bv="$(_ci_block_entry_field base_images "" "${bk}")" || return 2
                [ "${bv}" != "${v#docker://}" ] || bhit=1
            done
            [ "${bhit}" -eq 1 ] || viol+=("docker step '${v}' (in: $(_ci_ando_reffiles "${v}")) is not a SOT base_images value")
            continue
        fi
        # What: own repo needs a ref; others unsupported.
        # Why: a mutable ref has no verifiable manifest.
        # From: Issue #1860 | PR #1872
        if _ci_action_ref_is_own "${v}"; then
            case "${v}" in *@*) ;; *) viol+=("same-repository action '${v}' must include an explicit ref") ;; esac
            continue
        fi
        if ! _ci_action_ref_is_external "${v}"; then
            viol+=("unsupported action reference '${v}' (in: $(_ci_ando_reffiles "${v}"))")
            continue
        fi
        ref="${v##*@}"; key="${v%@*}"
        # What: an external ref must be a major tag vN.
        # Why: no third-party pin; the tag moves forward.
        # From: Issue #1683 | PR #1858
        if [[ ! "${ref}" =~ ^v[0-9]+$ ]]; then
            viol+=("external action '${v}' (in: $(_ci_ando_reffiles "${v}")) must use a major tag vN")
            continue
        fi
        # What: an external action must have a SOT entry.
        # Why: GitHub reads uses: only, so it owns the tag.
        # From: Issue #1683 | PR #1858
        entry="$(_ci_action_sot_entry "${key}")" || return 2
        if [ -z "${entry}" ]; then
            viol+=("external action '${key}' (in: $(_ci_ando_reffiles "${v}")) has no SOT github_actions entry")
            continue
        fi
        used_entries+="${entry} "
        owner="${key%%/*}"; repo="${key#*/}"; subpath=""
        [[ "${repo}" != */* ]] || { subpath="${repo#*/}"; repo="${repo%%/*}"; }
        res="$(_ci_fetch_action_manifest "${owner}" "${repo}" "${subpath}" "${ref}")" || return 2
        marker="${res%%$'\n'*}"
        case "${marker}" in
            OK)
                meta="${res#*$'\n'}"
                using="$(_ci_action_runs_using <<<"${meta}")"
                if [ -z "${using}" ]; then
                    viol+=("'${v}' has no parseable runs.using")
                elif [[ "${using}" =~ ^node([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -lt "${node_min}" ]; then
                    viol+=("'${v}' (in: $(_ci_ando_reffiles "${v}")) declares runs.using: ${using}, below node${node_min}")
                fi ;;
            NOTFOUND)
                viol+=("no action.yml/action.yaml for '${v}' at ref '${ref}' (in: $(_ci_ando_reffiles "${v}")); broken pin") ;;
            *)
                infra+=("${v} (${marker})"$'\n'"${res#*$'\n'}") ;;
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

    # What: every SOT action pin must be used.
    # Why: a dead pin is an owner nobody checks.
    # From: Issue #1683 | PR #1912
    local entries
    entries="$(_ci_block_keys github_actions)" || return 2
    for entry in ${entries}; do
        case "${used_entries}" in
            *" ${entry} "*) ;;
            *) viol+=("SOT github_actions.${entry} is used by no workflow") ;;
        esac
    done

    # What: extraction faults reported apart from pin.
    # Why: parse gap not deprecated-runtime fail.
    # From: Issue #1683 | PR #1858
    if [ "${#xv[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0054]" "reason=\"uses: extraction failure (unresolved alias / unparseable step)\"" "$(printf '%s\n' "${xv[@]}")"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0095]" "reason=\"deprecated runtime / ref drift / local action\"" "$(printf '%s\n' "${viol[@]}")"
    fi
    if [ "${#xv[@]}" -gt 0 ] || [ "${#viol[@]}" -gt 0 ]; then
        return 1
    fi
    printf 'action-node-versions=clean pins=%s\n' "${#uses_values[@]}"
}

# What: warn when an action has a newer major tag.
# Why: nightly hint only; a gone tag fails node-versions.
# From: Issue #1683 | PR #1858
_ci_check_action_majors() {
    local wf_dir srv entries e u cur repo refs t max warn=0 rc
    local -a files=()
    wf_dir="$(_ci_repo_path CI_WORKFLOW_DIR)" || return 2
    _ci_workflow_files files "${wf_dir}" || return 2
    srv="$(_ci_env_required GITHUB_SERVER_URL)" || return 2
    entries="$(_ci_block_keys github_actions)" || return 2
    for e in ${entries}; do
        u="$(_ci_block_entry_field github_actions "${e}" uses)" || return 2
        # What: the vN ref of this action in the workflows.
        # Why: action-node-versions keeps it one ref.
        # From: Issue #1683 | PR #1858
        rc=0
        cur="$(grep -h -o -E "uses:[[:space:]]*${u}@v[0-9]+" "${files[@]}")" || rc=$?
        _ci_producer_ok "${rc}" 1 || return 2
        cur="${cur%%$'\n'*}"; cur="${cur##*@v}"
        [ -n "${cur}" ] || continue
        repo="${u#*/}"; repo="${repo%%/*}"
        rc=0
        refs="$(_ci_retry github-read git ls-remote --tags --refs "${srv}/${u%%/*}/${repo}")" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-CHECK-0199]" "action=\"${u}\" reason=\"tag list not readable\"" "${refs}"
            return 2
        fi
        max=0
        while IFS= read -r t; do
            t="${t##*refs/tags/}"
            [[ "${t}" =~ ^v([0-9]+)(\.[0-9]+)*$ ]] || continue
            [ "${BASH_REMATCH[1]}" -le "${max}" ] || max="${BASH_REMATCH[1]}"
        done <<< "${refs}"
        if [ "${max}" -gt "${cur}" ]; then
            ci_log "[CI-WARN-CHECK-0198]" "action=\"${u}\" used=\"v${cur}\" newest=\"v${max}\" reason=\"newer major tag exists\""
            warn=$((warn + 1))
        fi
    done
    printf 'action-majors=clean newer=%s\n' "${warn}"
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
            "default=\"\" reason=\"CI_DEFAULT_BRANCH is required\"" >&2 || return 2
        _ci_env_required GITHUB_SHA "[CI-ERROR-LINK-0015]" \
            "sha=\"\" reason=\"GITHUB_SHA is required\"" >&2 || return 2
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
        if ! out="$(printf "## Closed via merge to \`%s\`\\n\\nCI closed this issue (\`ci.sh close-linked-issues\`) because GitHub closes linked issues only for merges into the default branch. Closed by PR #%s (%s), merge commit \`%s\`. The PR description follows verbatim.\\n\\n---\\n\\n%s\\n" \
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
    local -a viol=() scan=()
    local -A st=()
    local path line marker issue hits=""
    if [ "$#" -gt 0 ]; then
        _ci_scan_files changed _ci_override || return 2
    fi
    for path in "${changed[@]}"; do
        case "${path}" in *.md|*.mdx|*.rst|*.txt) continue ;; esac
        scan+=("${path}")
    done
    # What: grep rc 1 means no marker; rc 2 is an error.
    # Why: a read error must not pass as a clean file.
    # From: Issue #1683
    if [ "${#scan[@]}" -gt 0 ]; then
        hits="$(_ci_capture 1 grep -nEoH '(TODO|FIXME)\(#([0-9]+)\)' "${scan[@]}")" || return 2
    fi
    # What: st[N] holds each issue state, one API call.
    # Why: a number named twice must not cost a second call.
    # From: Issue #1683 | PR #1912
    while IFS= read -r marker; do
        [ -n "${marker}" ] || continue
        issue="${marker##*#}"; issue="${issue%)*}"
        marker="${marker%:*}"; line="${marker##*:}"; path="${marker%:*}"
        [[ "${issue}" =~ ^[0-9]+$ ]] || continue
        [ -n "${st[${issue}]:-}" ] || st["${issue}"]="$(_ci_issue_meta "${issue}")" || return 2
        [ "${st[${issue}]#*$'\t'}" = "closed" ] && viol+=("${path}:${line}: stale TODO/FIXME references closed #${issue}")
    done <<< "${hits}"
    local combined="${title}"
    [ -n "${combined}" ] && [ -n "${body}" ] && combined+=$'\n'
    combined+="${body}"
    if [ -n "${combined}" ]; then
        if _ci_text_has '(^|[[:space:]])@/tmp/[^[:space:]]+' "${combined}"; then
            viol+=("PR title/body: looks like a literal @/tmp/... upload path, not real body text")
        elif [[ "${combined}" == \"*\" && "${combined}" == *'\n'* && "${combined}" != *$'\n'* ]]; then
            viol+=("PR title/body: looks like JSON-quoted Markdown, not real body text")
        fi
        local stripped
        stripped="$(sed -E 's/\b(no|not|none|nothing|without)\b([[:space:]]+[[:alnum:]-]+){0,3}[[:space:]]+(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)\b//Ig' <<<"${combined}")"
        if _ci_text_has -i '(^|[^[:alnum:]])(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)([^[:alnum:]]|$)' "${stripped}"; then
            local open_found=0 rest="${combined}"
            while [[ "${rest}" =~ Refs[[:space:]]+#([0-9]+) ]]; do
                issue="${BASH_REMATCH[1]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
                [ -n "${st[${issue}]:-}" ] || st["${issue}"]="$(_ci_issue_meta "${issue}")" || return 2
                [ "${st[${issue}]#*$'\t'}" = "open" ] && { open_found=1; break; }
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

# What: add each text line to array $1 as "<$2>: <line>".
# Why: checks list findings per file the same way.
# From: Issue #1683 | PR #1912
_ci_viol_lines() {
    local -n _vl_viol="$1"
    local _vl_line
    while IFS= read -r _vl_line; do
        [ -z "${_vl_line}" ] || _vl_viol+=("$2: ${_vl_line}")
    done <<< "$3"
}

# What: container names share one prefix + service name.
# Why: operators find a container by its service name.
# From: Issue #1683 | PR #1858
_ci_check_naming_consistency() {
    local root="${1:-${CI_REPO_ROOT}}" dep
    dep="$(_ci_compose_path "${root}")" || return 2
    local -a compose_files=("${dep}")
    local -a viol=()
    local cf cfg line

    for cf in "${compose_files[@]}"; do
        if [ ! -f "${cf}" ]; then
            viol+=("${cf}: compose file missing")
            continue
        fi
        cfg="$(_ci_compose_json "${cf}")" || return 2
        # What: prefix is the project name in any case.
        # Why: compose name: owns the name; one spelling.
        # From: Issue #1683 | PR #1912
        line="$(_ci_capture 0 jq -r "$(cat <<'PROG'
.name as $p
            | [.services | to_entries[] | {s: .key, c: (.value.container_name // "")}] as $all
            | ($all | map(select(.c == "")) | map("service \(.s) has no container_name")[]),
              ($all | map(select(.c != "" and (.s as $s | .c | endswith("-" + $s) | not)))
                | map("container_name \(.c) does not end in -\(.s)")[]),
              ($all | map(select(.c != "") | .c[0:(.c | length) - (.s | length) - 1]) | unique
                | (select(length > 1) | "container prefixes differ: \(join(", "))"),
                  (.[] | select(ascii_downcase != ($p | ascii_downcase))
                    | "container prefix \(.) is not the project name \($p)"))
PROG
                    )" <<<"${cfg}")" || return 2
        _ci_viol_lines viol "${cf}" "${line}"
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
        dep="$(_ci_compose_path)" || return 2
        top="${dep%/*}"; top="${top%/*}"
        for f in "${top}"/*/"${dep##*/}"; do
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
        if [ ! -f "${file}" ]; then
            viol+=("${file}: compose file missing")
            continue
        fi
        # What: judge the rendered compose, not its text.
        # Why: anchors and merge keys give healthchecks too.
        # From: Issue #1683 | PR #1912
        local cfg produced
        cfg="$(_ci_compose_json "${file}")" || return 2
        produced="$(_ci_capture 0 jq -r '.services | to_entries[]
            | "\(.key)\t\(if .value.healthcheck then 1 else 0 end)"' <<<"${cfg}")" || return 2
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
        ci_error "[CI-ERROR-CHECK-0021]" "reason=\"service missing a healthcheck\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-healthchecks=clean checked=%s\n' "${checked}"
}

# What: Fail if a proxy CACHE_* default drifts from its doc.
# Why: a hand-copied doc default silently goes stale.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cache_env_doc_drift() {
    local defaults="${1:-}"
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
        # What: values compose gives proxy, SOT fixture env
        # Why: an empty one falls back to runtime.defaults
        # From: Issue #1683 | PR #1912
        produced="$(_ci_service_compose_env proxy)" || return 2
    fi
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^CACHE_[A-Z_]+$ ]] || continue
        scanned=$((scanned + 1))
        doc_row="$(_ci_capture 1 grep -E "^\| \`${key}\` \|" "${arch_doc}")" || return 2
        [ -n "${doc_row}" ] || continue
        checked=$((checked + 1))
        if [ -z "${value}" ] && [ -z "${defaults}" ]; then value="$(_ci_runtime_default "${key}")" || return 2; fi
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
    local repo_root="${1:-${CI_REPO_ROOT}}" dep
    local -a viol=()
    dep="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${dep%/*}"
    local hit
    hit="$(_ci_capture 1 grep -RInE '^[[:space:]]+build:' "${dep}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("a stack compose declares build:; prod must run prebuilt images only" "${hit}")
    fi
    local hit su readme
    su="$(_ci_installer "${repo_root}")" || return 2
    readme="$(_ci_repo_path CI_README "${repo_root}")" || return 2
    hit="$(_ci_capture 1 grep -RIn -- '--build' "${readme}" "${dep}" "${su}")" || return 2
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
    local repo_root="${1:-${CI_REPO_ROOT}}" dep compose
    compose="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${compose#"${repo_root}/"}"
    local doc doc_rel
    doc_rel="$(_ci_variable CI_BACKUP_RESTORE_DOC)" || return 2
    doc="${repo_root}/${doc_rel}"
    local -a viol=()
    local key f keys
    for f in "${compose}" "${doc}"; do
        [ -f "${f}" ] || { ci_log "[CI-ERROR-CHECK-0043]" "path=\"${f}\" reason=\"required prod-state-wiring input missing\""; return 2; }
    done
    keys="$(_ci_state_keys)" || return 2
    if [ -z "${keys}" ]; then
        ci_log "[CI-ERROR-CHECK-0174]" "reason=\"SOT runtime.state_dir_keys names no state key\""
        return 2
    fi
    # What: a key counts only as a whole word, not a prefix.
    # Why: PDNS_DIR_OLD must not satisfy PDNS_DIR.
    # From: Issue #1683 | PR #1912
    while IFS= read -r key; do
        _ci_file_match "[CI-ERROR-CHECK-0181]" "key=\"${key}\" reason=\"doc not searched\"" "${doc}" "${key}" -Fw \
            || { [ "$?" -eq 1 ] || return 2; viol+=("${doc_rel} does not mention ${key}"); }
    done <<<"${keys}"
    # What: compose mounts exactly the SOT state_dir_keys.
    # Why: the SOT list owns the keys; compose only mounts.
    # From: Issue #1683 | PR #1912
    local mounted="" want row key off=""
    row="$(_ci_run "[CI-ERROR-CHECK-0192]" "file=\"${compose}\" reason=\"state mounts not read\"" \
        yq --yaml-fix-merge-anchor-to-spec=true -r '(.services[].volumes[]?, .volumes[]?.driver_opts.device?) | select(tag == "!!str") | select(test("^\$\{[A-Z0-9_]+:[?-]"))' "${compose}")" || return 2
    # What: ":?" after the key is a mount, ":-" a default.
    # Why: a mount default in compose is a second owner.
    # From: Issue #1683 | PR #1912
    while IFS= read -r want; do
        [ -n "${want}" ] || continue
        key="${want#\$\{}"
        key="${key%%:*}"
        case "${want:$(( ${#key} + 2 )):2}" in
            ':?') mounted+="${key}"$'\n' ;;
            *) off+=$'\n'"${want}" ;;
        esac
    done <<< "${row}"
    mounted="$(sort -u <<< "${mounted%$'\n'}")"
    want="$(sort -u <<< "${keys}")"
    [ "${mounted}" = "${want}" ] \
        || viol+=("${dep} state mounts differ from SOT runtime.state_dir_keys: compose=[${mounted//$'\n'/ }] sot=[${want//$'\n'/ }]")
    [ -z "${off}" ] || viol+=("${dep} has a mount default in compose:${off}")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0100]" "reason=\"prod state wiring differs from the SOT or undocumented\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'prod-state-wiring=clean\n'
}

# What: Fail unless every SOT host tool is present.
# Why: validate runs in build-tools; verified (AG-CI-001).
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
        [ -n "${t}" ] && ! _ci_command_available "${t}" && missing+=("${t}")
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

# What: the state keys of SOT runtime.state_dir_keys.
# Why: the SOT owns the list; ci.sh loads no setup.sh.
# From: Issue #1683 | PR #1858
_ci_state_keys() {
    local rows key sub
    rows="$(_ci_required_field runtime state_dir_keys blocklist)" || return 2
    while read -r key sub; do
        [ -z "${key}" ] || printf '%s\n' "${key}"
    done <<< "${rows}"
}

# What: SOT_ and state-dir rows setup.sh compose sets.
# Why: setup.sh owns them; ci.sh runs it, $1 = .env.local.
# From: Issue #1683 | PR #1858
_ci_sot_compose_env() {
    local out rc err keys line k miss=""
    keys="$(_ci_state_keys)" || return 2
    err="$(_ci_mktemp "${CI_TMPDIR}/ci-setup-err.XXXXXX")" || return 2
    _ci_setup_run out rc "${err}" "$1" compose @INST@ config --environment || { rm -f "${err}"; return 2; }
    # What: stderr only as raw; stdout holds all env values.
    # Why: a warning fails; secrets must not reach the log.
    # From: Issue #1683 | PR #1858
    if [ "${rc}" -ne 0 ] || [ -s "${err}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0134]" "rc=${rc} reason=\"setup.sh compose config --environment failed or wrote stderr\"" "$(<"${err}")"
        rm -f "${err}"
        return 2
    fi
    rm -f "${err}"
    local -A seen=()
    while IFS= read -r line; do
        k="${line%%=*}"
        case "${k}" in
            SOT_*) printf '%s\n' "${line}" ;;
            *) [[ $'\n'"${keys}"$'\n' != *$'\n'"${k}"$'\n'* ]] || { printf '%s\n' "${line}"; seen["${k}"]=1; } ;;
        esac
    done <<< "${out}"
    while IFS= read -r k; do
        [ -n "${seen[${k}]:-}" ] || miss+=" ${k}"
    done <<< "${keys}"
    if [ -n "${miss}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0135]" "keys=\"${miss# }\" reason=\"setup.sh compose set no such state dir\""
        return 2
    fi
}

# What: image coordinates of the compose images, KEY=VALUE.
# Why: compose has no image default; SOT and repo own them.
# From: Issue #1683 | PR #1912
_ci_validation_images() {
    local reg repo tag svc names
    reg="$(_ci_registry)" || return 2
    repo="$(_ci_repo)" || return 2
    # What: the tag is the install channel setup.sh offers.
    # Why: no version in the SOT; PROJECT_RELEASE_VERSION
    # From: Issue #1683 | PR #1858
    tag="$(_ci_release_value install_channel)" || return 2
    names="$(ci_services)" || return 2
    printf 'LANCACHE_IMAGE_REGISTRY=%s\nLANCACHE_IMAGE_PREFIX=%s\nLANCACHE_IMAGE_TAG=%s\n' "${reg}" "${repo}" "${tag}"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        printf 'LANCACHE_IMAGE_REF_%s=%s/%s/%s:%s\n' "${svc^^}" "${reg}" "${repo}" "${svc}" "${tag}"
    done <<<"${names}"
}

# What: SOT validation env plus fresh secrets, KEY=VALUE.
# Why: one owner for check and validate; $1 = state root.
# From: Issue #1683 | PR #1858
_ci_validation_env() {
    local fx kind owner secrets k v n=0 rows state body=""
    local -a pairs=()
    fx="$(_ci_block_entry_list validation "" compose_validation_env)" || return 2
    if [ -z "${fx}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0054]" "reason=\"no SOT validation.compose_validation_env\""
        return 2
    fi
    # What: a bare KEY is a default; rows fill @KEY@.
    # Why: the SOT runtime.defaults owns each default value.
    # From: Issue #1683 | PR #1912
    rows="$(_ci_runtime_defaults)" || return 2
    while IFS= read -r k; do
        [ -n "${k}" ] || continue
        case "${k}" in
            *=*) _ci_fill "${k}" "${rows}" || return 2; v="${REPLY}" ;;
            *) v="$(_ci_default_in "${rows}" "${k}")" || return 2; v="${k}=${v}" ;;
        esac
        body+="${v}"$'\n'
    done <<< "${fx}"
    state="${1:-}"
    [ -n "${state}" ] || state="$(_ci_default_in "${rows}" LANCACHE_STATE_DIR)" || return 2
    v="$(_ci_validation_images)" || return 2
    body+="${v}"$'\n'
    # What: a fresh value per secret key, setup.sh format.
    # Why: a fixed key in the SOT is a hardcoded credential.
    # From: Issue #1683 | PR #1858
    secrets="$(_ci_required_field runtime managed_secrets blocklist)" || return 2
    while read -r k kind owner; do
        case "${owner}" in stack|secondary) ;; *) continue ;; esac
        pairs+=("${k}" "${kind}")
        n=$((n + 1))
    done <<< "${secrets}"
    # What: one setup.sh load makes every secret.
    # Why: a load per key cost 10 loads per env.
    # From: Issue #1683 | PR #1912
    if [ "${n}" -eq 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0101]" "reason=\"no SOT runtime.managed_secrets stack or secondary row\""
        return 2
    fi
    v="$(_ci_run "[CI-ERROR-VALIDATE-0100]" "keys=${n} reason=\"secret not generated\"" \
        bash -c "$(cat <<'PROG'
source "$1" || exit 2; shift
            while [ "$#" -gt 1 ]; do
                v="$(generate_secret_value "$1" "$2")" || exit 2
                printf "%s=%s\n" "$1" "${v}"
                shift 2
            done
PROG
            )" _ "${CI_REPO_ROOT}/setup.sh" "${pairs[@]}")" || return 2
    body+="${v}"
    # What: setup.sh compose adds the SOT_ and state rows.
    # Why: per-run state overrides its SOT default.
    # From: Issue #1683 | PR #1951
    v="$(_ci_sot_compose_env "${body}"$'\n'"LANCACHE_STATE_DIR=${state}")" || return 2
    printf '%s\n%s\n' "${body}" "${v}"
}

# What: repo root joined with a SOT path variable.
# Why: paths are SOT truths; ci.sh holds no path literal.
# From: Issue #1683 | PR #1858
_ci_repo_path() {
    local name="$1" root="${2:-${CI_REPO_ROOT:-.}}" rel
    rel="$(_ci_variable "${name}")" || return 2
    printf '%s/%s\n' "${root}" "${rel}"
}

# What: prod compose file: the run copy, else SOT runtime.
# Why: runtime.compose_file is the one owner with setup.sh
# From: Issue #1683 | PR #1858
_ci_compose_file() {
    if [ -n "${CI_COMPOSE_COPY:-}" ]; then
        printf '%s\n' "${CI_COMPOSE_COPY}"
        return 0
    fi
    _ci_required_field runtime compose_file block
}

# What: repo root joined with the prod compose file.
# Why: one join rule for every compose reader.
# From: Issue #1683 | PR #1858
_ci_compose_path() {
    local root="${1:-${CI_REPO_ROOT:-.}}" rel
    rel="$(_ci_compose_file)" || return 2
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

# What: a proxy path or port the supervisor renders
# Why: main.rs owns them; the SOT owns NGINX_DIR
# From: Issue #1683 | PR #1912
_ci_proxy_constant() {
    local name="$1" root="${2-${CI_REPO_ROOT:-.}}" src raw re='^("([^"$]+)"|([0-9]+))$'
    src="$(_ci_service_path services src/main.rs "${root}")" || return 2
    # What: Rust const item; other value forms fail closed.
    # Why: visibility and spacing are valid Rust grammar.
    # From: Issue #1683 | PR #1912
    raw="$(_ci_file_value "${src}" "s/^[[:space:]]*(pub(\\([a-z]+\\))?[[:space:]]+)?const[[:space:]]+${name}[[:space:]]*:[[:space:]]*(&('static[[:space:]]+)?str|u16)[[:space:]]*=[[:space:]]*(\"[^\"\\\\]+\"|[0-9]+)[[:space:]]*;([[:space:]]*\\/\\/.*)?\$/\\5/p")" \
        || [ "$?" -eq 1 ] || return 2
    if [[ ! "${raw}" =~ ${re} ]]; then
        ci_error "[CI-ERROR-CORE-0129]" "path=\"${src}\" name=\"${name}\" reason=\"need exactly one literal const\"" "${raw}"
        return 2
    fi
    if [ -n "${BASH_REMATCH[3]}" ]; then
        printf '%s\n' "${BASH_REMATCH[3]}"
        return 0
    fi
    _ci_nginx_path "${BASH_REMATCH[2]}"
}

# What: a relative path joined under the SOT NGINX_DIR.
# Why: one join owner for proxy files and subdirs.
# From: Issue #1683 | PR #1912
_ci_nginx_path() {
    local dir
    dir="$(_ci_runtime_default NGINX_DIR)" || return 2
    printf '%s/%s\n' "${dir%/}" "$1"
}

# What: NGINX_DIR joined with the SOT subdir key $1.
# Why: certs and CA dirs are SOT keys under NGINX_DIR.
# From: Issue #1683 | PR #1912
_ci_nginx_subdir() {
    local sub
    sub="$(_ci_runtime_default "$1")" || return 2
    _ci_nginx_path "${sub}"
}

# What: docker compose with the env the file renders under.
# Why: .env if given, else SOT fixture; one env owner.
# From: Issue #1683 | PR #1858
_ci_compose_run() {
    local env_file="$1" fx kv vars names i
    shift
    local -a fixture=() args=("$@") files=() unsetv=() pre=()
    if [ -n "${env_file}" ]; then
        # What: compose variables lose their shell values
        # Why: a shell value would win over the env file
        # From: Issue #1683 | PR #1858
        for (( i = 0; i < ${#args[@]}; i++ )); do
            case "${args[i]}" in
                -f|--file) files+=(-f "${args[i + 1]}"); i=$(( i + 1 )) ;;
                --profile|-p|--project-name|--project-directory|--env-file) i=$(( i + 1 )) ;;
                -*) ;;
                *) break ;;
            esac
        done
        vars="$(_ci_run "[CI-ERROR-CORE-0144]" "env_file=\"${env_file}\" reason=\"compose variable list failed\"" \
            docker compose --env-file "${env_file}" "${files[@]}" config --variables --format json)" || return 2
        names="$(_ci_run "[CI-ERROR-CORE-0145]" "env_file=\"${env_file}\" reason=\"compose variable names unreadable\"" \
            jq -r 'keys[]' <<< "${vars}")" || return 2
        [ -z "${names}" ] || mapfile -t unsetv <<< "${names}"
        fx="$(_ci_capture 0 cat "${env_file}")" || return 2
        fx="$(_ci_sot_compose_env "${fx}")" || return 2
        pre=(--env-file "${env_file}")
    else
        fx="$(_ci_validation_env)" || return 2
    fi
    mapfile -t fixture <<< "${fx}"
    # What: export each KEY=VALUE fixture pair.
    # Why: ${kv?} is ShellCheck's pair form (SC2163).
    # From: Issue #1683 | PR #1858
    (
        [ "${#unsetv[@]}" -eq 0 ] || unset "${unsetv[@]}"
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
    if _ci_text_has -i '(^|[[:space:]])(warn|warning|level=warning)' "${out}"; then
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
    local -a pf=()
    _ci_compose_profile_flags "$1" pf || return 2
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

# What: out[]: the stack compose file, then compose_targets
# Why: one reader for the checks that walk every stack file
# From: Issue #1683 | PR #1912
_ci_stack_compose_files() {
    local -n _ci_scf_out="$1"
    local _ci_scf_dep _ci_scf_targets
    _ci_scf_out=()
    _ci_scf_dep="$(_ci_compose_file)" || return 2
    _ci_scf_targets="$(_ci_block_entry_field validation "" compose_targets)" || return 2
    if [ -z "${_ci_scf_targets}" ]; then
        ci_error "[CI-ERROR-CHECK-0044]" "reason=\"no compose_targets in SOT\"" "manifest=${CI_MANIFEST}"
        return 1
    fi
    # What: the SOT field is a space-separated path list.
    # Why: read -a splits words without glob expansion.
    # From: Issue #1683 | PR #1912
    read -ra _ci_scf_out <<< "${_ci_scf_targets}"
    _ci_scf_out=("${_ci_scf_dep}" "${_ci_scf_out[@]}")
}

# What: every stack compose renders clean in every profile.
# Why: profiles come from the file; none is skipped.
# From: Issue #1683 | PR #1858
_ci_check_compose_config() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=() profiles=() files=()
    local rel cf raw p label render msg count=0
    _ci_stack_compose_files files || return $?
    for rel in "${files[@]}"; do
        cf="${repo_root}/${rel}"
        label="${rel}"
        if [ ! -f "${cf}" ]; then
            viol+=("${label}: compose target missing")
            continue
        fi
        if ! raw="$(_ci_compose_profiles "${cf}" "" 2>&1)"; then
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
            if ! msg="$(_ci_compose_config_ok "${cf}" "${p}" "")"; then
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

# What: no service publishes the netdata API port.
# Why: only stack peers may reach it; the ui proxies it.
# From: Issue #1683 | PR #1858
_ci_check_netdata_isolation() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dep cfg out line nd_url
    local -a viol=()
    dep="$(_ci_compose_path "${repo_root}")" || return 2
    nd_url="$(_ci_runtime_default NETDATA_URL)" || return 2
    cfg="$(_ci_compose_json "${dep}")" || return 2
    dep="${dep#"${repo_root}/"}"
    out="$(_ci_capture 0 jq -r --arg url "${nd_url}" "$(cat <<'PROG'
        if ($url | test(":[0-9]+$") | not)
            then "ui NETDATA_URL has no port (got: \($url))"
          else ($url | sub(".*:"; "") | tonumber) as $port
            | .services | to_entries[]
            | select(any(.value.ports[]?; .target == $port))
            | "\(.key) publishes the netdata port \($port)"
          end
PROG
          )" <<<"${cfg}")" || return 2
    while IFS= read -r line; do
        [ -z "${line}" ] || viol+=("${dep}: ${line}")
    done <<<"${out}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0146]" "reason=\"netdata API is published\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'netdata-isolation=clean\n'
}

# What: health ACL order and ignored-header hiding.
# Why: a bare return skips the ACL; ignored headers leak.
# From: Issue #1683 | PR #1858
_ci_check_proxy_nginx_policy() {
    local repo_root="${1:-${CI_REPO_ROOT}}" f out line pp blocks=0 b h a d al r px hk hu hp="" hq pn lb fb hv sv sp bn
    local -a viol=() bnt
    px="$(_ci_service_path proxy "" "${repo_root}")" || return 2
    px="${px%/}"
    # What: the health and status paths of the SOT.
    # Why: the templates name the keys; values must be sane.
    # From: Issue #1683 | PR #1912
    hv="$(_ci_runtime_default PROXY_HEALTH_PATH)" || return 2
    sv="$(_ci_runtime_default PROXY_STATUS_PATH)" || return 2
    if ! [[ "${sv}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0196]" "key=\"PROXY_STATUS_PATH\" value=\"${sv}\" reason=\"SOT status path is no plain absolute path\""
        return 2
    fi
    for hk in PROXY_HEALTH_URL PROXY_HEALTH_HTTPS_URL; do
        hu="$(_ci_runtime_default "${hk}")" || return 2
        hq="${hu#*://}"
        hq="/${hq#*/}"
        if [[ "${hu}" != *://*/* ]] || ! [[ "${hq}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            ci_log "[CI-ERROR-CHECK-0194]" "key=\"${hk}\" value=\"${hu}\" reason=\"SOT health URL names no plain absolute path\""
            return 2
        fi
        if [ "${hq}" != "${hv}" ]; then
            ci_log "[CI-ERROR-CHECK-0195]" "key=\"${hk}\" path=\"${hq}\" other=\"${hv}\" reason=\"the SOT health URL path differs from PROXY_HEALTH_PATH\""
            return 2
        fi
    done
    hp="\${PROXY_HEALTH_PATH}"
    sp="\${PROXY_STATUS_PATH}"
    # What: the allow targets a location may carry.
    # Why: the SOT owns the ranges; templates name the key.
    # From: Issue #1683 | PR #1912
    pn="$(_ci_runtime_default PRIVATE_NETS)" || return 2
    bn="$(_ci_runtime_default DOCKER_BRIDGE_NET)" || return 2
    read -ra bnt <<<"${bn}"
    for h in "${bnt[@]}"; do
        [[ " ${pn} " == *" ${h} "* ]] \
            || viol+=("DOCKER_BRIDGE_NET holds ${h}, which is no PRIVATE_NETS member")
    done
    lb="\${LOOPBACK_BIND_IP}/32 \${DOCKER_BRIDGE_NET}"
    pp="${px}/proxy-params.conf"
    # What: one /healthz block, in proxy-params.conf only.
    # Why: both servers include it; a copy is a 2nd owner.
    # From: Issue #1683 | PR #1858
    for f in "${px}"/conf.d/*.conf "${pp}"; do
        out="$(_ci_capture 0 awk -v "P=${hp}" "$(cat <<'PROG'
            $1 == "location" && $2 == "=" && $3 == P && $4 == "{" { inb = 1; n++; body = ""; a = 0; d = 0; al = 0; r = 0; next }
            inb && /^[[:space:]]*\}/ {
                printf "%s|%d|%d|%d|%d\n", body, a, d, al, r; inb = 0; next }
            inb { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); gsub(/[[:space:]]+/, " ", line)
                body = body line ";"
                if (line ~ /^allow /) { a++; if (d) d = -1 }
                if (line == "deny all;") { if (d == 0) d = 1 }
                if (line ~ /^alias /) al = 1
                if (line ~ /^return /) r = 1 }
PROG
                )" "${f}")" || return 2
        fb=0
        while IFS='|' read -r b line; do
            [ -n "${b}" ] || continue
            blocks=$((blocks + 1))
            fb=$((fb + 1))
            IFS='|' read -r a d al r <<<"${line}"
            [ "${a}" -ge 1 ] && [ "${d}" -eq 1 ] || viol+=("${f#"${repo_root}/"}: ${hp} needs allow lines followed by deny all")
            [ "${al}" -eq 1 ] && [ "${r}" -eq 0 ] || viol+=("${f#"${repo_root}/"}: ${hp} must serve via alias, never return (return skips the ACL)")
        done <<<"${out}"
        if [ "${f}" = "${pp}" ]; then
            [ "${fb}" -eq 1 ] || viol+=("${f#"${repo_root}/"}: needs exactly one ${hp} block, found ${fb}")
        else
            [ "${fb}" -eq 0 ] || viol+=("${f#"${repo_root}/"}: ${hp} block belongs in proxy-params.conf only")
        fi
        # What: the allow lines of every location.
        # Why: a location with allow lines is an ACL.
        # From: Issue #1683 | PR #1912
        out="$(_ci_capture 0 awk "$(cat <<'PROG'
            $1 == "location" { loc = $0; sub(/^[[:space:]]+/, "", loc); sub(/[[:space:]]*\{[[:space:]]*$/, "", loc); gsub(/[[:space:]]+/, " ", loc)
                inb = 1; depth = 0; a = 0; d = 0; s = 0 }
            inb { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); gsub(/[[:space:]]+/, " ", line)
                if (line ~ /^allow /) { t = line; sub(/^allow /, "", t); sub(/;$/, "", t); print loc "|T|" t; a++; if (d) d = -1 }
                if (line == "deny all;" && d == 0) d = 1
                if (line == "stub_status;") s = 1
                o = $0; c = $0
                depth += gsub(/\{/, "", o) - gsub(/\}/, "", c)
                if (depth <= 0) { if (a > 0 && d != 1) print loc "|D|"; if (s) print loc "|S|"; inb = 0 } }
PROG
            )" "${f}")" || return 2
        while IFS='|' read -r line b h; do
            [ -n "${line}" ] || continue
            if [ "${b}" = "T" ]; then
                [[ " ${lb} " == *" ${h} "* ]] \
                    || viol+=("${f#"${repo_root}/"}: ${line} allows ${h}, neither the loopback bind nor \${DOCKER_BRIDGE_NET} (a literal is a second owner)")
            elif [ "${b}" = "S" ]; then
                [ "${line}" = "location = ${sp}" ] \
                    || viol+=("${f#"${repo_root}/"}: ${line} serves stub_status but is not location = ${sp}")
            elif [ "${line}" != "location = ${hp}" ]; then
                viol+=("${f#"${repo_root}/"}: ${line} needs allow lines followed by deny all")
            fi
        done <<<"${out}"
    done
    out="$(_ci_capture 0 awk "$(cat <<'PROG'
        $1 == "proxy_ignore_headers" { for (i = 2; i <= NF; i++) { h = $i; sub(/;$/, "", h); ign[h] = 1 } }
        $1 == "proxy_hide_header" { h = $2; sub(/;$/, "", h); hid[h] = 1 }
        END {
            split("Cache-Control Expires Vary Set-Cookie", req, " ")
            for (i in req) if (!(req[i] in ign)) print "proxy_ignore_headers must include " req[i]
            for (h in ign) if (!(h in hid)) print "ignored header " h " must also be hidden from clients"
        }
PROG
        )" "${pp}")" || return 2
    while IFS= read -r h; do
        [ -z "${h}" ] || viol+=("${pp#"${repo_root}/"}: ${h}")
    done <<<"${out}"
    # What: the https.conf template includes the listen file
    # Why: a literal listen would be a second port owner.
    # From: Issue #1683 | PR #1912
    _ci_file_match "[CI-ERROR-CHECK-0182]" "reason=\"https include not searched\"" "${px}/conf.d/https.conf" "    include     \${NGINX_DIR}/\${NGINX_HTTPS_LISTEN_FILE};" -Fx \
        || { [ "$?" -eq 1 ] || return 2; viol+=("${px#"${repo_root}/"}/conf.d/https.conf: no include of the SOT keys NGINX_DIR and NGINX_HTTPS_LISTEN_FILE"); }
    if _ci_file_match "[CI-ERROR-CHECK-0183]" "reason=\"https listen not searched\"" "${px}/conf.d/https.conf" '^[[:space:]]*listen[[:space:]]'; then
        viol+=("${px#"${repo_root}/"}/conf.d/https.conf: literal listen; the watchdog renders it")
    elif [ "$?" -ne 1 ]; then
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0151]" "reason=\"proxy nginx policy violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-nginx-policy=clean healthz_blocks=%s\n' "${blocks}"
}

# What: proxy cert, CA and cache dirs sit on the SOT mounts.
# Why: the SOT owns them; Compose and nginx.conf use them.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cert_volume() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dir ca cache cf cfg out px
    local -a viol=() files=()
    local -A seen=()
    dir="$(_ci_nginx_subdir NGINX_SUBDIR_CERTS)" || return 2
    ca="$(_ci_nginx_subdir NGINX_SUBDIR_CA)" || return 2
    cache="$(_ci_runtime_default NGINX_CACHE_DIR)" || return 2
    px="$(_ci_service_path proxy "" "${repo_root}")" || return 2
    _ci_file_match "[CI-ERROR-CHECK-0184]" "reason=\"proxy_cache_path not searched\"" "${px%/}/nginx.conf" '^[[:space:]]*proxy_cache_path[[:space:]]+\$\{NGINX_CACHE_DIR\}[[:space:]]*$' \
        || { [ "$?" -eq 1 ] || return 2; viol+=("${px#"${repo_root}/"}nginx.conf: proxy_cache_path is not the SOT key NGINX_CACHE_DIR"); }
    _ci_stack_compose_files files || return $?
    for cf in "${files[@]}"; do
        [ -z "${seen[${cf}]:-}" ] || continue
        seen["${cf}"]=1
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        out="$(_ci_capture 0 jq -r --arg d "${dir}" --arg c "${ca}" --arg k "${cache}" "$(cat <<'PROG'
.services.proxy // empty
            | def mount($t; $kind): [.volumes // [] | .[] | select(.target == $t)] as $m
                | if ($m | length) != 1 then "proxy needs exactly one mount at \($t) (got \($m | length))"
                  elif $m[0].type != $kind or ($m[0].source // "") == ""
                  then "proxy \($t) must be a \($kind) mount (got \($m[0].type) \($m[0].source // "anonymous"))"
                  else empty end;
              mount($d; "volume"), mount($c; "bind"), mount($k; "volume")
PROG
              )" <<<"${cfg}")" || return 2
        _ci_viol_lines viol "${cf}" "${out}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0149]" "reason=\"proxy dirs differ from the SOT mounts\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cert-volume=clean cert_dir=%s ca_dir=%s cache_dir=%s files=%s\n' "${dir}" "${ca}" "${cache}" "${#seen[@]}"
}

# What: the bootstrap repo address equals the SOT value.
# Why: setup.sh runs before the clone; the one text check.
# From: Issue #1683 | PR #1858
_ci_check_setup_update_safety() {
    local repo_root="${1:-${CI_REPO_ROOT}}" su
    local -a viol=()
    su="$(_ci_installer "${repo_root}")" || return 2
    local repo_url
    repo_url="$(_ci_runtime_default LANCACHE_REPO_URL)" || return 2
    _ci_file_match "[CI-ERROR-CHECK-0193]" "reason=\"repo address not searched\"" "${su}" "LANCACHE_REPO_URL=\"${repo_url}\"" -Fx \
        || { [ "$?" -eq 1 ] || return 2; viol+=("setup.sh LANCACHE_REPO_URL differs from SOT runtime.defaults LANCACHE_REPO_URL (${repo_url})"); }
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0103]" "reason=\"setup.sh update safety or bootstrap contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-update-safety=clean\n'
}

# What: compose JSON on the fixture env, own IMAGE vars
# Why: only then do the images show which var they take
# From: Issue #1683 | PR #1912
_ci_compose_image_render() {
    local file="$1" out="$2" env body line kept=""
    shift 2
    env="$(_ci_mktemp "${CI_TMPDIR}/ci-image-env.XXXXXX")" || return 2
    body="$(_ci_validation_env)" || { rm -f "${env}"; return 2; }
    while IFS= read -r line; do
        case "${line}" in LANCACHE_IMAGE_*) ;; *) kept+="${line}"$'\n' ;; esac
    done <<< "${body}"
    body="${kept%$'\n'}"
    if ! printf '%s\n' "${body}" "$@" > "${env}"; then
        ci_log "[CI-ERROR-CHECK-0172]" "file=\"${env}\" reason=\"render env file not writable\""
        rm -f "${env}"
        return 2
    fi
    if ! _ci_compose_json "${file}" "${env}" > "${out}"; then
        rm -f "${env}"
        return 2
    fi
    rm -f "${env}"
}

# What: Fail unless channel/tag resolves from config.
# Why: one resolution across setup.sh/UI/compose.
# From: Issue #1683
_ci_check_image_channel_resolution() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local sec prod dep
    sec="$(_ci_service_path ui src/main.rs "${repo_root}")" || return 2
    prod="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${prod#"${repo_root}/"}"
    local -a viol=()
    local f
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
            _ci_file_match "[CI-ERROR-CHECK-0187]" "line=\"${f}\" reason=\"ui source not searched\"" "${sec}" "${f}" -F \
                || { [ "$?" -eq 1 ] || return 2; viol+=("ui main.rs must expose/use ${f}"); }
        done
    fi
    if [ ! -f "${prod}" ]; then
        viol+=("prod compose missing: ${prod}")
    else
        # What: each compose image has one ref var
        # Why: AG-CI-006: the SOT owns the image coordinates
        # From: Issue #1683 | PR #1912
        local tdir rep line sreg spre stag schan prog svc names refs hits
        hits="$(_ci_run -m 1 "[CI-ERROR-CHECK-0178]" "file=\"${prod}\" reason=\"image defaults not scanned\"" grep -nE 'LANCACHE_IMAGE_(REF_[A-Z_]+|REGISTRY|PREFIX|TAG):-[^}]' "${prod}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("compose gives an image coordinate a default: ${line}")
        done <<< "${hits}"
        names="$(ci_services)" || return 2
        sreg="r${SRANDOM}.test" spre="p${SRANDOM}/q${SRANDOM}" stag="t${SRANDOM}" schan="c${SRANDOM}"
        refs=()
        while IFS= read -r svc; do
            [ -z "${svc}" ] || refs+=("LANCACHE_IMAGE_REF_${svc^^}=${sreg}/${spre}/${svc}:${stag}")
        done <<< "${names}"
        prog="$(cat <<'PROG'
($s[0].services) as $S | ($sreg + "/" + $spre + "/") as $sp
            | [$names | split("\n")[] | select(. != "")] as $N
            | [$S | to_entries[] | select((.value.environment // {}) | type == "object" and has("LANCACHE_IMAGE_REGISTRY"))] as $ev
            | (if ($ev | length) == 0 then "no compose service receives LANCACHE_IMAGE_REGISTRY" else empty end),
              ($N[] | . as $k | ($S[$k].image // "") as $im
                | if $im == ($sp + $k + ":" + $stag) then empty
                  else "service \($k): image \($im) does not take LANCACHE_IMAGE_REF_\($k | ascii_upcase)" end),
              ($ev[] | .key as $k | $S[$k].environment as $se
                | (["LANCACHE_IMAGE_REGISTRY", $sreg], ["LANCACHE_IMAGE_PREFIX", $spre],
                   ["LANCACHE_IMAGE_CHANNEL", $schan], ["LANCACHE_IMAGE_TAG", $stag]) as [$n, $sv]
                | if ($se[$n] // null) == $sv then empty else "service \($k): \($n) is \($se[$n] // "unset") for env file value \($sv)" end)
PROG
                )"
        tdir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-chanres.XXXXXX")" || return 2
        if ! _ci_compose_image_render "${prod}" "${tdir}/s.json" "LANCACHE_IMAGE_REGISTRY=${sreg}" \
                "LANCACHE_IMAGE_PREFIX=${spre}" "LANCACHE_IMAGE_TAG=${stag}" "LANCACHE_IMAGE_CHANNEL=${schan}" "${refs[@]}"; then
            rm -rf "${tdir}"
            return 2
        fi
        rep="$(_ci_run "[CI-ERROR-CHECK-0171]" "file=\"${dep}\" reason=\"image coordinate comparison failed\"" \
            jq -rn --slurpfile s "${tdir}/s.json" --arg names "${names}" \
            --arg sreg "${sreg}" --arg spre "${spre}" --arg stag "${stag}" --arg schan "${schan}" \
            "${prog}")" || { rm -rf "${tdir}"; return 2; }
        rm -rf "${tdir}"
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${line}")
        done <<< "${rep}"
    fi
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
    # What: an empty ignore list gives zero statements.
    # Why: no exception is valid; <<< adds one empty line.
    # From: Issue #1683 | PR #1858
    _ci_run "[CI-ERROR-RELEASE-0025]" "trivyignore=\"${trivyignore}\" reason=\"OpenVEX assembly failed\"" \
        jq -nR --arg repo "${repo}" --arg server "${server}" --arg ts "${ts}" "$(cat <<'PROG'
        def stmt($e; $p):
          ($e.statement // "") as $s
          | if ($e.id // "") == "" then error("entry \($e.n): id is empty")
            elif $s == "" then error("\($e.id): statement is empty") else . end
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
        [inputs | select(. != "") | split("\t") | {n: (.[0] | tonumber), k: .[1], v: (.[2:] | join("\t") | gsub("\u001e"; "\n"))}]
        | group_by(.n)
        | map(reduce .[] as $f ({paths: []};
            if $f.k == "path" then .paths += [$f.v] else .[$f.k] = $f.v end) + {n: .[0].n})
        | ([group_by(.id)[] | select(length > 1) | .[0].id]) as $dup
        | if $dup != [] then error("duplicate id: \($dup | join(", "))") else . end
        | {"@context": "https://openvex.dev/ns/v0.2.0",
           "@id": "\($server)/\($repo)/vex/\($repo | split("/")[1])-\($ts)",
           author: "\($repo | split("/")[1]) release automation (\($server)/\($repo))",
           timestamp: $ts, version: 1,
           statements: map(stmt(.; {vulnerability: {name: .id}, timestamp: $ts,
             products: [{"@id": "pkg:github/\($repo)", subcomponents: (.paths | map({"@id": .}))}]}))}
PROG
        )" <<< "${fields}"
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

# What: Fail on editing CHANGELOG.md without the label.
# Why: AG-VAL-001: a warning is no success; conflict risk.
# From: Issue #893 | PR #1858
_ci_check_changelog_direct_edit() {
    local -a changed=("$@")
    local path edited=0 file
    # What: the label rule needs a pull request.
    # Why: by hand all files count as changed, no labels.
    # From: Issue #1683 | PR #1858
    if _ci_skip_outside_pr changelog-direct-edit; then
        return 0
    fi
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
    label_err="$(jq -e --arg l "${label}" 'index($l) != null' <<<"${PR_LABELS_JSON:-[]}" 2>&1)" || label_rc=$?
    case "${label_rc}" in
        0) ci_log "[CI-INFO-CHECK-0115]" "file=\"${file}\" label=\"${label}\" reason=\"changelog edited with the label; expected\"" ;;
        1)
            ci_error "[CI-ERROR-CHECK-0116]" "file=\"${file}\" label=\"${label}\" reason=\"changelog edited directly outside the release flow\"" "${file}"
            return 1
            ;;
        *)
            ci_error "[CI-ERROR-CHECK-0112]" "reason=\"PR_LABELS_JSON unreadable\"" "${label_err}"
            return 2
            ;;
    esac
    printf 'changelog-direct-edit=labelled\n'
}

# What: print each logging-matrix row's service, dupes kept.
# Why: the check finds missing, extra and double rows.
# From: Issue #1683 | PR #1912
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
            split(line, parts, "|")
            name = parts[1]
            sub(/[[:space:]]+$/, "", name)
            if (match(name, /`[a-z0-9-]+`/)) name = substr(name, RSTART + 1, RLENGTH - 2)
            print "row=" name
            next
        }
        seen_marker && rows_seen && !/^\|/ { exit }
    ' "${doc}"
}

# What: Print one real Compose service name per line.
# Why: a profiled service needs `config --profiles` first.
# From: Issue #1683 | PR #1858
_ci_compose_service_names() {
    local file="$1"
    local -a profile_flags=()
    _ci_compose_profile_flags "${file}" profile_flags || return 2
    _ci_compose_query "${file}" "" "${profile_flags[@]}" config --services
}

# What: out[]: --profile pairs for every compose profile.
# Why: one owner; a profiled service must not be skipped.
# From: Issue #1683 | PR #1912
_ci_compose_profile_flags() {
    local -n _ci_pf_out="$2"
    local _ci_pf_all _ci_pf_p
    _ci_pf_out=()
    _ci_pf_all="$(_ci_compose_profiles "$1")" || return 2
    while IFS= read -r _ci_pf_p; do
        [ -n "${_ci_pf_p}" ] && _ci_pf_out+=(--profile "${_ci_pf_p}")
    done <<< "${_ci_pf_all}"
    return 0
}

# What: each Compose service has exactly one matrix row.
# Why: a new, renamed or doubled service must not hide.
# From: Issue #1683 | PR #1912
_ci_check_logging_matrix() {
    local repo_root="${1:-${CI_REPO_ROOT}}" doc rows cf raw_services n
    local -a canonical=() services=() viol=()
    local -A in_doc=() in_compose=()
    doc="$(_ci_repo_path CI_ARCH_DOC "${repo_root}")" || return 2
    if [ ! -f "${doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0035]" "path=\"${doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    rows="$(_ci_logging_matrix_canonical "${doc}")" || {
        ci_log "[CI-ERROR-CHECK-0120]" "path=\"${doc}\" reason=\"logging matrix not readable (raw above)\""; return 2; }
    if [ -z "${rows}" ]; then
        ci_log "[CI-ERROR-CHECK-0036]" "path=\"${doc}\" reason=\"no logging-matrix rows parsed\""
        return 2
    fi
    mapfile -t canonical <<< "${rows}"
    # What: drops the row= prefix of each parsed name.
    # Why: $(...) would eat a last row with an empty name.
    # From: Issue #1683 | PR #1912
    canonical=("${canonical[@]#row=}")
    # What: only the primary stack compose is matched.
    # Why: the secondary dns logs locally (driver: local).
    # From: Issue #1683 | PR #1912
    cf="$(_ci_compose_path "${repo_root}")" || return 2
    raw_services="$(_ci_compose_service_names "${cf}")" || {
        ci_log "[CI-ERROR-CHECK-0034]" "path=\"${cf}\" reason=\"compose service lookup failed (raw above)\""; return 2; }
    mapfile -t services <<< "${raw_services}"
    for n in "${canonical[@]}"; do
        [ -n "${n}" ] || { viol+=("${doc}: a row has no service name"); continue; }
        [ -z "${in_doc[${n}]:-}" ] || viol+=("${doc}: row '${n}' appears more than once")
        in_doc[${n}]=1
    done
    for n in "${services[@]}"; do
        [ -n "${n}" ] || continue
        in_compose[${n}]=1
        [ -n "${in_doc[${n}]:-}" ] || viol+=("${cf}: service '${n}' has no logging-matrix row")
    done
    for n in "${canonical[@]}"; do
        [ -z "${n}" ] || [ -n "${in_compose[${n}]:-}" ] || viol+=("${doc}: row '${n}' is not a real Compose service")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0038]" "reason=\"logging-matrix drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'logging-matrix=clean rows=%s services=%s\n' "${#canonical[@]}" "${#in_compose[@]}"
}

# What: fill array $2 with the workflow files under root $1.
# Why: both workflow scans list the files the same way.
# From: Issue #1683 | PR #1912
_ci_workflow_scan_files() {
    local dir
    dir="$(_ci_repo_path CI_WORKFLOW_DIR "$1")" || return 2
    _ci_workflow_files "$2" "${dir}"
}

# What: read awk rows: "$2 N" count, "flag ..." findings.
# Why: both workflow scans parse the same row format.
# From: Issue #1683 | PR #1912
_ci_workflow_scan_report() {
    local root="$1" key="$2" out="$3" line
    local -n _ws_viol="$4" _ws_count="$5"
    while IFS= read -r line; do
        case "${line}" in
            "${key} "*) _ws_count="${line#"${key} "}" ;;
            "flag "*) line="${line#flag }"; _ws_viol+=("${line#"${root}/"}") ;;
        esac
    done <<< "${out}"
}

# What: each workflow calling ci.sh passes CI_VARIABLES.
# Why: else ci.sh misses repo/org vars; ids diverge.
# From: Issue #1683 | PR #1858
_ci_check_workflow_ci_variables() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" out callers=0
    local -a viol=() files=()
    _ci_workflow_scan_files "${repo_root}" files || return 2
    out="$(_ci_capture 0 awk "$(cat <<'PROG'
        function rep() { if (c) { n++; if (!w) print "flag " f ": calls ci.sh without top-level env CI_VARIABLES" } }
        FNR == 1 { if (f != "") rep(); f = FILENAME; c = w = 0 }
        index($0, "scripts/ci.sh") { c = 1 }
        $0 == "  CI_VARIABLES: ${{ toJSON(vars) }}" { w = 1 }
        END { if (f != "") rep(); print "callers " n + 0 }
PROG
        )" "${files[@]}")" || return 2
    _ci_workflow_scan_report "${repo_root}" callers "${out}" viol callers
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0158]" "scanned=${#files[@]} callers=${callers} flagged=${#viol[@]} reason=\"ci.sh caller without CI_VARIABLES\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'workflow-ci-variables=clean scanned=%s callers=%s\n' "${#files[@]}" "${callers}"
}

# What: SOT-owned jobs read job-settings, others a literal
# Why: AG-CI-006/016: one owner; every job has a timeout
# From: Issue #1683 | PR #1858
_ci_check_workflow_job_settings() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" out runner job tmap="" js_count=0
    local -a viol=() files=() js_jobs=()
    local -A js_min=()
    _ci_workflow_scan_files "${repo_root}" files || return 2
    _ci_job_settings_read runner js_jobs js_min || return 2
    for job in "${js_jobs[@]}"; do tmap+="${job}=${js_min[${job}]} "; done
    out="$(_ci_capture 0 awk -v runner="${runner}" -v tmap="${tmap}" -v q="'" "$(cat <<'PROG'
        function lit(v) { return v != "" && v !~ /^\$\{\{/ }
        function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub("^[\"" q "]|[\"" q "]$", "", s); return s }
        function bad(m) { print "flag " f ": job " job ": " m }
        function done_job(  k, want, shown) {
            if (job == "" || uses) return
            njob++
            want = (job in T) ? T[job] : ""
            if (to == "") bad("no timeout-minutes")
            else if (want != "" && lit(to)) bad("timeout-minutes " to " (SOT ci_job_timeouts." job " owns it)")
            else if (want == "" && !lit(to)) bad("timeout-minutes reads job-settings, SOT ci_job_timeouts has no " job)
            if (nd) {
                if (lit(ro)) bad("runs-on " ro " (a needs job reads job-settings)")
            } else if (lit(ro) && ro != runner) bad("runs-on " ro " (SOT runner " runner ")")
            k = ro
            while (match(k, q "[^" q "]*" q)) {
                if (substr(k, RSTART + 1, RLENGTH - 2) != runner) bad("runs-on fallback " substr(k, RSTART, RLENGTH) " (SOT runner " runner ")")
                k = substr(k, RSTART + RLENGTH)
            }
            if (match(to, /\|\|[[:space:]]*[0-9]+/)) bad("timeout fallback " substr(to, RSTART, RLENGTH) " (a literal is a second owner)")
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
        END { end_file(); print "jobs " njob + 0 }
PROG
        )" "${files[@]}")" || return 2
    _ci_workflow_scan_report "${repo_root}" jobs "${out}" viol js_count
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

# What: every build target's Dockerfile, one pass each.
# Why: one owner for the rules a Dockerfile must meet.
# From: Issue #1683 | PR #1912
_ci_check_dockerfiles() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" targets t df rel type svars bvars allow raw tok missing bst bv
    local hits spec p id c ctxs srcs src ok n=0 rc=0
    local -a tl=() cl=() roots=() parts=() e_bt=() e_tune=() e_stage=() e_secret=() e_ctx=() e_src=()
    local -A kv=() is_pkg=()
    svars="$(_ci_block_entry_list stage_variables "" ci_sh)" || return 2
    [ -n "${svars}" ] || e_stage+=("SOT stage_variables.ci_sh lists no variable")
    bvars="$(_ci_block_entry_list build_variables "" rust)" || return 2
    allow="$(_ci_runtime_secret_ids)" || return 2
    raw="$(_ci_build_tools_packages)" || return 2
    while IFS= read -r tok; do [ -z "${tok}" ] || is_pkg["${tok}"]=1; done <<< "${raw}"
    targets="$(ci_build_targets)" || return 2
    [ -z "${targets}" ] || mapfile -t tl <<< "${targets}"
    for t in "${tl[@]}"; do
        df="$(_ci_service_path "${t}" Dockerfile "${repo_root}")" || return 2
        rel="${df#"${repo_root}/"}"
        if [ ! -f "${df}" ]; then
            e_secret+=("${t}: no Dockerfile at ${rel}"); continue
        fi
        n=$(( n + 1 ))
        type="$(_ci_required_field "${t}" build_type)" || return 2
        # What: ci.sh stages declare each SOT stage var.
        # Why: ARG scope is per stage; else no value.
        # From: Issue #1683 | PR #1858
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${svars}" 'ci[.]sh (apk-setup|rust-build)')" || return 2
        missing="$(_ci_capture 0 sort -u <<< "${missing}")" || return 2
        while read -r bst bv; do
            [ -z "${bv}" ] || e_stage+=("${t}: Dockerfile stage ${bst} runs ci.sh without ARG ${bv} (SOT stage_variables.ci_sh)")
        done <<< "${missing}"
        # What: each secret mount id is a central id.
        # Why: set-runtime writes only listed ids.
        # From: Issue #1683 | PR #1858
        hits="$(_ci_capture 0 awk "$(cat <<'PROG'
/^[[:space:]]*#/ { next }
            { s = $0; while (match(s, /--mount=[^[:space:]]+/)) { print substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) } }
PROG
            )" "${df}")" || return 2
        while IFS= read -r spec; do
            [ -n "${spec}" ] || continue
            kv=()
            IFS=',' read -r -a parts <<< "${spec#--mount=}"
            for p in "${parts[@]}"; do kv["${p%%=*}"]="${p#*=}"; done
            [ "${kv[type]:-bind}" = secret ] || continue
            id="${kv[id]:-${kv[target]:-${kv[dst]:-${kv[destination]:-}}}}"
            [ -n "${kv[id]:-}" ] || id="${id##*/}"
            if [ -z "${id}" ]; then
                e_secret+=("${t}: ${rel}: '${spec}' has no id or target"); continue
            fi
            _ci_list_has "${id}" "${allow}" || e_secret+=("${t}: ${rel}: mount id '${id}' is not in the central list")
        done <<< "${hits}"
        # What: COPY sources: the context or an edge.
        # Why: else the image identity goes stale.
        # From: Issue #1683 | PR #1912
        c="$(_ci_required_field "${t}" context)" || return 2
        roots=("${c}")
        ctxs="$(ci_service_context_paths "${t}" "${repo_root}")" || return 2
        cl=()
        [ -z "${ctxs}" ] || mapfile -t cl <<< "${ctxs}"
        roots+=("${cl[@]}")
        srcs="$(_ci_dockerfile_copy_sources "$(< "${df}")")" || return 2
        while IFS= read -r src; do
            [ -n "${src}" ] || continue
            ok=""
            for p in "${roots[@]}"; do
                case "${src%/}" in "${p}" | "${p}"/*) ok=1; break ;; esac
            done
            [ -n "${ok}" ] || e_ctx+=("${t}: ${rel} copies ${src}, outside its context and SOT edges")
        done <<< "${srcs}"
        # What: cargo install tokens; rust: none at all.
        # Why: build-tools owns the toolchain (AG-REL-002).
        # From: Issue #1683 | PR #1912
        raw="$(_ci_capture 0 awk "$(cat <<'PROG'
            match($0, /cargo[ \t]+install[ \t]+/) {
                r = substr($0, RSTART + RLENGTH); sub(/[&|;].*/, "", r)
                k = split(r, a, /[ \t]+/)
                for (i = 1; i <= k; i++) if (a[i] != "" && a[i] !~ /^-/) print a[i]
            }
PROG
            )" "${df}")" || return 2
        if [ "${type}" != rust ]; then
            while IFS= read -r tok; do
                [ -z "${tok}" ] || [ -z "${is_pkg[${tok}]:-}" ] || e_src+=("${rel}: cargo install ${tok}; SOT ships it prebuilt in build-tools")
            done <<< "${raw}"
            continue
        fi
        [ -z "${raw}" ] || e_bt+=("${t}: Dockerfile compiles a tool with cargo install; consume the build-tools image")
        # What: rust stages: build vars, build-tools image.
        # Why: one toolchain owner (AG-CI-008).
        # From: Issue #1683
        _ci_file_match "[CI-ERROR-CHECK-0188]" "target=\"${t}\" reason=\"toolchain ARG not searched\"" "${df}" "ARG ${CI_ARG_TOOLCHAIN_IMAGE}" -F \
            || { [ "$?" -eq 1 ] || return 2; e_bt+=("${t}: Dockerfile must declare ARG ${CI_ARG_TOOLCHAIN_IMAGE}"); }
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${bvars}" 'ci[.]sh rust-build')" || return 2
        missing="$(_ci_capture 0 sort -u <<< "${missing}")" || return 2
        while read -r bst bv; do
            [ -z "${bv}" ] || e_bt+=("${t}: Dockerfile stage ${bst} runs ci.sh rust-build without ARG ${bv} (SOT build_variables.rust)")
        done <<< "${missing}"
        _ci_file_match "[CI-ERROR-CHECK-0189]" "target=\"${t}\" reason=\"FROM line not searched\"" "${df}" "^FROM \\$\\{${CI_ARG_TOOLCHAIN_IMAGE}(:-scratch)?\\}([[:space:]]|$)" \
            || { [ "$?" -eq 1 ] || return 2; e_bt+=("${t}: Dockerfile must build FROM \${${CI_ARG_TOOLCHAIN_IMAGE}}"); }
        # What: forbid a mutable default on the ARG.
        # Why: ci.sh supplies the immutable ref (AG-CI-008).
        # From: Issue #1683
        if _ci_file_match "[CI-ERROR-CHECK-0190]" "target=\"${t}\" reason=\"ARG default not searched\"" "${df}" "^ARG ${CI_ARG_TOOLCHAIN_IMAGE}="; then
            e_bt+=("${t}: ARG ${CI_ARG_TOOLCHAIN_IMAGE} must carry no default; ci.sh supplies it")
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
        # What: reject Cargo tuning hardcode; empty ARG ok.
        # Why: jobs/lto/codegen from CI vars (AG-CI-006).
        # From: Issue #1683
        if _ci_file_match "[CI-ERROR-CHECK-0191]" "target=\"${t}\" reason=\"Cargo tuning not searched\"" "${df}" '^[[:space:]]*(ARG[[:space:]]+SCCACHE_DIST_SCHEDULER_URL|ENV[[:space:]]+CARGO_BUILD_JOBS=|ARG[[:space:]]+PROJECT_CARGO_LTO=.+|ARG[[:space:]]+PROJECT_CARGO_CODEGENUNIT=.+|ENV[[:space:]]+PROJECT_CARGO_LTO=|ENV[[:space:]]+PROJECT_CARGO_CODEGENUNIT=)'; then
            e_tune+=("${t}: Dockerfile hardcodes a Cargo tuning value; source jobs/lto/codegen from CI vars")
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
    done
    [ "${#e_stage[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0169]" "targets=${n} reason=\"a ci.sh build stage lacks an SOT stage variable ARG\"" "$(printf '%s\n' "${e_stage[@]}")"; rc=1; }
    [ "${#e_secret[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0156]" "targets=${n} reason=\"Dockerfile missing or mount id not central\"" "$(printf '%s\n' "${e_secret[@]}")"; rc=1; }
    [ "${#e_ctx[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0175]" "targets=${n} reason=\"a COPY source is outside the context paths\"" "$(printf '%s\n' "${e_ctx[@]}")"; rc=1; }
    [ "${#e_src[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0061]" "targets=${n} reason=\"Dockerfile source-compiles a prebuilt SOT tool; consume the build-tools image\"" "$(printf '%s\n' "${e_src[@]}")"; rc=1; }
    [ "${#e_bt[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0058]" "targets=${n} reason=\"rust Dockerfile does not consume the build-tools image (AG-CI-008/AG-REL-002)\"" "$(printf '%s\n' "${e_bt[@]}")"; rc=1; }
    [ "${#e_tune[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0060]" "targets=${n} reason=\"rust Dockerfile hardcodes a Cargo tuning value (AG-CI-006)\"" "$(printf '%s\n' "${e_tune[@]}")"; rc=1; }
    [ "${rc}" -ne 0 ] || printf 'dockerfiles=clean targets=%s\n' "${n}"
    return "${rc}"
}

# What: "stage name" per stage that runs <ere> sans ARG
# Why: ARG scope is per stage; else no value reaches it
# From: Issue #1683 | PR #1858
_ci_dockerfile_stage_missing_args() {
    local df="$1" argnames="$2" runs="$3"
    _ci_capture 0 awk -v need="${argnames//$'\n'/ }" -v runs="${runs}" "$(cat <<'PROG'
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
PROG
    )" "${df}"
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
        raw="$(_ci_codeql_paths "${lang}")" || return 2
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

# What: shellcheck changed shell files, all severities.
# Why: one owner; SOT build-tools image.
# From: Issue #1683
_ci_check_shellcheck() {
    local -a changed=() files=() supp=()
    _ci_collect_changed changed "$@" || return 2
    # What: a set SHELLCHECK_OPTS stops the check.
    # Why: its -e or -S would hide findings (AG-VAL-007).
    # From: Issue #1683 | PR #1912
    if [ -n "${SHELLCHECK_OPTS:-}" ]; then
        ci_error "[CI-ERROR-CHECK-0180]" "reason=\"SHELLCHECK_OPTS is set; it can exclude findings\"" "SHELLCHECK_OPTS=${SHELLCHECK_OPTS}"
        return 2
    fi
    # What: a changed shellcheck rc file is a finding.
    # Why: its disable= hides findings in every local run.
    # From: Issue #1683 | PR #1912
    local f hits re='#[[:space:]]*shellcheck[[:space:]].*(disable=|source=/dev/null|extended-analysis=(false|0))'
    for f in "${changed[@]}"; do
        case "${f##*/}" in .shellcheckrc|shellcheckrc) supp+=("${f}: shellcheck rc file") ;; esac
    done
    # What: shell files of the list; no list = all of them.
    # Why: an empty list means all files, as in check all.
    # From: Issue #1683 | PR #1858
    _ci_shell_sources files changed || return 2
    # What: in-file disable, null source, no dataflow.
    # Why: each one hides findings; AG-VAL-007 forbids it.
    # From: Issue #1683 | PR #1912
    for f in "${files[@]}"; do
        hits="$(_ci_capture 1 grep -n -E -- "${re}" "${f}")" || return 2
        [ -z "${hits}" ] || supp+=("${f}:${hits//$'\n'/$'\n'${f}:}")
    done
    if [ "${#supp[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0179]" "reason=\"shellcheck suppression found\"" "$(printf '%s\n' "${supp[@]}")"
        return 1
    fi
    [ "${#files[@]}" -eq 0 ] && { printf 'shellcheck=NOT-RUN reason="no shell file in the changed list"\n'; return 0; }
    # What: one shellcheck process per file.
    # Why: one call on all files needs ~5 GB peak RAM.
    # From: Issue #1683 | PR #1858
    local sc_out="" sc_one sc_rc sc_found=0 sc_broken=0
    for f in "${files[@]}"; do
        sc_rc=0
        sc_one="$(shellcheck --norc "${f}" 2>&1)" || sc_rc=$?
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
    if [ -z "${lock}" ]; then
        _ci_cargo_lock || return 2
        lock="$(_ci_repo_path CI_CARGO_LOCK)" || return 2
    fi
    out="$(cargo audit --deny warnings --file "${lock}" 2>&1)" || rc=$?
    # What: advisories/warnings fail (belt+braces).
    # Why: --deny warnings catches; never pass.
    # From: Issue #1683
    if [ "${rc}" -ne 0 ] || _ci_text_has -i '(^|[[:space:]])warning:' "${out}"; then
        ci_error "[CI-ERROR-CHECK-0055]" "reason=\"cargo audit found advisories or warnings\"" "${out}"
        return 1
    fi
    printf 'cargo-audit=clean\n'
}

# What: run CI_CHECKS by scope, keep the worst exit (§98).
# Why: a stop (2) must not read as a finding (1) (§68).
# From: Issue #1683 | PR #1912
ci_cmd_check_all() {
    local -a changed=() names=() skipped=() failed=() stopped=()
    _ci_collect_changed changed "$@" || return 2
    local raw sub r rc=0 scope why state invoked=0 diff_seen="all files"
    raw="$(printf '%s\n' "${!CI_CHECKS[@]}" | LC_ALL=C sort)" || return 2
    mapfile -t names <<< "${raw}"
    [ "${#changed[@]}" -eq 0 ] || diff_seen="${#changed[@]} changed paths"
    for sub in "${names[@]}"; do
        r=0 why=""
        scope="${CI_CHECKS[${sub}]%% *}"
        # What: diff sees changed files; pr needs a real PR.
        # Why: no PR context on push; job has its own step.
        # From: Issue #1683 | PR #1912
        case "${scope}" in
            diff) CI_SCAN_SCOPE_FILTER=1 ci_cmd_check "${sub}" "${changed[@]}" || r=$? ;;
            repo) ci_cmd_check "${sub}" || r=$? ;;
            pr)
                if [ -n "${PR_NUMBER:-}" ]; then
                    ci_cmd_check "${sub}" || r=$?
                else
                    why="PR_NUMBER unset, so this run has no pull request; it runs when PR_NUMBER is set"
                fi
                ;;
            job) why="job scope: the workflow step of its own job runs it; run it by name, check all does not" ;;
            *) ci_log "[CI-ERROR-CHECK-0173]" "sub=\"${sub}\" entry=\"${CI_CHECKS[${sub}]}\" reason=\"scope must be diff, repo, pr or job\""; r=2 ;;
        esac
        # What: a check check all did not run says NOT-RUN.
        # Why: AG-INT-002: a skip is stated with its reason.
        # From: Issue #1683 | PR #1912
        if [ -n "${why}" ]; then
            printf '%s=NOT-RUN scope=%s reason="%s"\n' "${sub}" "${scope}" "${why}"
            skipped+=("${sub}")
        else
            invoked=$((invoked + 1))
        fi
        # What: name each check with a finding or a stop.
        # Why: the last line says which checks are red.
        # From: Issue #1683 | PR #1858
        case "${r}" in
            0) ;;
            1) failed+=("${sub}") ;;
            *) stopped+=("${sub}") ;;
        esac
        [ "${r}" -le "${rc}" ] || rc="${r}"
    done
    case "${rc}" in
        0) state=clean ;;
        1) state=findings ;;
        *) state=stopped ;;
    esac
    printf 'check-all=%s rc=%s invoked=%s not-run=%s diff-scope="%s" finding-checks="%s" stopped-checks="%s" not-run-checks="%s"\n' "${state}" "${rc}" "${invoked}" "${#skipped[@]}" "${diff_seen}" "${failed[*]:-}" "${stopped[*]:-}" "${skipped[*]:-}"
    return "${rc}"
}

# What: run one CI_CHECKS entry by name; all runs every one.
# Why: an unknown name is a coded stop, never a pass.
# From: Issue #1683 | PR #1912
ci_cmd_check() {
    local sub="${1:-}" entry
    if [ "$#" -gt 0 ]; then shift; fi
    if [ "${sub}" = all ]; then
        ci_cmd_check_all "$@"
        return
    fi
    entry="$(_ci_table_entry CI_CHECKS "${sub}")" || return 2
    if [ -z "${entry}" ]; then
        ci_log "[CI-ERROR-CHECK-0001]" "sub=\"${sub}\" reason=\"unknown check\" known=\"all ${!CI_CHECKS[*]}\""
        return 2
    fi
    "${entry#* }" "$@"
}

# What: Run the dispatcher only on direct execution.
# Why: Lets ci.bats source the functions to test them.
# From: Issue #1683
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # What: started via symlink = runner hook by link name.
    # Why: the runner passes a hook path, never arguments.
    # From: Issue #1683 | PR #1858
    if [ -L "${0}" ]; then
        ci_main runner-host hook "${0##*/}"
    else
        ci_main "$@"
    fi
fi
