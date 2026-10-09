#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Single authoritative CI 2.0 regression suite.
# Why: One place proves every CI invariant and regression.
# From: Issue #1683

# What: declare the bats feature level the suite uses.
# Why: run -N / --separate-stderr need 1.5.0 (BW02).
# From: Issue #1683
bats_require_minimum_version 1.5.0

# What: Source ci.sh functions without running dispatch.
# Why: Test engine functions directly against the real SOT.
# From: Issue #1683
setup() {
    # What: socket setup.sh tests get; it never exists
    # Why: a missing stub must fail, not reach a daemon
    # From: Issue #1683 | PR #1858
    SETUP_SH_DOCKER_HOST="unix://${BATS_TEST_TMPDIR}/$(_val name)"
    CI_SH="${BATS_TEST_DIRNAME}/ci.sh"
    unset CI_MANIFEST
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
    CI_MANIFEST_SOURCE="${CI_MANIFEST}"
    # What: index the real SOT once in the test shell.
    # Why: sourced readers look up, as under ci_main.
    # From: Issue #1683 | PR #1858
    _ci_sot_load || return 1
}

# What: docker stand-in, apk stub, server URL, SOT copy.
# Why: callers need a daemon, registry or apk they lack.
# From: Issue #1683 | PR #1858
_stand_ins() {
    BIN="$(_val path)" DS="$(_val path)"; export BIN DS
    mkdir -p "${DS}/volumes" && _docker_stub "${BIN}" || return 1
    PATH="${BIN}:${PATH}"
    # What: default apk resolver, rust ids docker-free.
    # Why: rust identity now keys the build-tools signature.
    # From: Issue #1683
    CI_APK_RESOLVE_CMD="$(_stub "printf '%s\n' '$(_val name)'")"; export CI_APK_RESOLVE_CMD
    # What: server URL every Actions run provides, fresh.
    # Why: label provenance needs it; no real host in tests.
    # From: Issue #1683 | PR #1858
    GITHUB_SERVER_URL="$(_val url)"; export GITHUB_SERVER_URL
    # What: SOT copy; fresh registry, platforms, runners.
    # Why: tests read them back; no real or fixed value.
    # From: Issue #1683 | PR #1858
    local -a ed=(-e "s|^  registry: .*|  registry: $(_val host)|")
    local plats p k f v
    plats="$(_ci_build_matrix_platforms)" || return 1
    for p in ${plats}; do
        v="$(_val platform)"
        ed+=(-e "s|${p//./\\.}|${v}|g" -e "s|^  ${p##*/}:\$|  ${v##*/}:|")
    done
    for k in $(_ci_block_keys platform_arch); do
        for f in rust_target apk runner; do
            v="$(_ci_block_entry_field platform_arch "${k}" "${f}")" || return 1
            [ -z "${v}" ] || ed+=(-e "s|${v//./\\.}|$(_val name)|g")
        done
    done
    CI_MANIFEST="${BATS_TEST_TMPDIR}/sot.yml"
    sed "${ed[@]}" "${CI_MANIFEST_SOURCE}" > "${CI_MANIFEST}" || return 1
    export CI_MANIFEST
    _ci_sot_load || return 1
}

# What: drop runner cache inputs, then run the args.
# Why: one list keeps tests off the real runner caches.
# From: Issue #1683 | PR #1858
_cache_env_clean() {
    unset RUNNER_ENVIRONMENT SCCACHE_REDIS_URL SCCACHE_DIR ACTIONS_RESULTS_URL ACTIONS_RUNTIME_TOKEN
    [ "$#" -eq 0 ] || "$@"
}

# What: Write an executable stub that prints/exits fixed.
# Why: Inject build/CAS/probe backends without real infra.
# From: Issue #1683
_stub() {
    local path
    path="$(_val path)"
    _tool_stub "${path%/*}" "${path##*/}" <<<"$1"
    printf '%s\n' "${path}"
}

# What: loads every setup.sh function, never runs setup.sh
# Why: tests drive the product code with its real die
# From: Issue #1683 | PR #1858
_load_setup_sh() {
    local repo_root="$1"
    local helper_file="${BATS_TEST_TMPDIR}/setup-sh.sh"
    # What: setup.sh up to its dispatcher; nothing executes
    # Why: declare -gA keeps top-level maps global in here
    # From: Issue #1683 | PR #1858
    {
        printf 'SCRIPT_DIR=%q\n' "${repo_root}"
        awk 'NR == 1 || /^set -euo pipefail$/ || /^SCRIPT_DIR=/ { next }
            /^case "\$\{1:-install\}" in$/ { exit }
            { sub(/^declare -A /, "declare -gA "); print }' "${repo_root}/setup.sh"
    } > "${helper_file}"
    grep -q '^cmd_backup() ($' "${helper_file}" || { echo "setup.sh cut is incomplete"; return 1; }
    export DOCKER_HOST="${SETUP_SH_DOCKER_HOST}"
    # shellcheck source=setup.sh
    source "${helper_file}"
    # What: setup.sh's own seam for the raw TCP probe
    # Why: no LAN address is reachable inside the test box
    # From: Issue #1683 | PR #1858
    export SETUP_SH_SEAMS='_tcp_port_reachable() { [ ! -e "${DS}/fail-tcp" ]; }'
}

# What: runs a snippet on loaded setup.sh fns, setup.sh opts
# Why: failure paths are proven under set -euo pipefail
# From: Issue #1683 | PR #1858
_setup_sh_run() {
    local root msg="${BATS_TEST_TMPDIR}/setup-msg.sh" full="${BATS_TEST_TMPDIR}/setup-sh.sh"
    if [ -f "${full}" ]; then
        run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" bash -c 'set -euo pipefail; . "$1"; eval "$2"' _ "${full}" "$1"
        return 0
    fi
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    grep -E '^(print_step|print_ok|print_warn|print_error|die) *\(\) *\{.*\}$' "${root}/setup.sh" > "${msg}"
    [ "$(wc -l < "${msg}")" -eq 5 ]
    run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" bash -c 'set -euo pipefail; YELLOW="" RED="" RESET="" BOLD="" CYAN="" GREEN=""
        . "$1"; . "$2"; eval "$3"' _ "${msg}" "${BATS_TEST_TMPDIR}/fns-setup.sh" "$1"
}

# What: check rc and the ;-list of output parts in order.
# Why: one row check for every table-driven test.
# From: Issue #1683 | PR #1858
_expect() {
    local case="$1" rc="$2" want="$3" rest="${output}" w
    [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status} want ${rc}: ${output}"; return 1; }
    case "${want}" in
        -) return 0 ;;
        =*) [ "${output}" = "${want#=}" ] || { echo "${case}: '${output}' want '${want#=}'"; return 1; }; return 0 ;;
    esac
    # What: split on ; by expansion; parts keep newlines
    # Why: read stops at a newline and drops the later parts
    # From: Issue #1683 | PR #1858
    while :; do
        w="${want%%;*}"
        [[ "${rest}" == *"${w}"* ]] || { echo "${case}: no '${w}' (in order): ${output}"; return 1; }
        rest="${rest#*"${w}"}"
        [ "${want}" != "${w}" ] || return 0
        want="${want#*;}"
    done
}

# What: print one fresh value of a kind per call.
# Why: no fixed host, port, token or name in a test.
# From: Issue #1683 | PR #1858
_val() {
    case "$1" in
        name) printf 'v%s' "${SRANDOM}" ;;
        path) printf '%s/v%s' "${BATS_TEST_TMPDIR}" "${SRANDOM}" ;;
        var) printf 'CI_V%s' "${SRANDOM}" ;;
        host) printf 'h%s' "${SRANDOM}" ;;
        port) printf '%s' "$(( SRANDOM % 64511 + 1024 ))" ;;
        int) printf '%s' "$(( SRANDOM % ($3 - $2 + 1) + $2 ))" ;;
        url) printf 'http://h%s:%s' "${SRANDOM}" "$(( SRANDOM % 64511 + 1024 ))" ;;
        platform) printf 'o%s/p%s' "${SRANDOM}" "${SRANDOM}" ;;
        sha) printf '%08x%08x%08x%08x%08x' "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" ;;
        semver) printf '%s.%s.%s' "$(( SRANDOM % 90 + 1 ))" "$(( SRANDOM % 100 ))" "$(( SRANDOM % 100 ))" ;;
        digest) printf 'sha256:%08x%08x%08x%08x%08x%08x%08x%08x' "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" \
            "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" ;;
        ipv4) printf '%s.%s.%s.%s' "$(( SRANDOM % 256 ))" "$(( SRANDOM % 256 ))" "$(( SRANDOM % 256 ))" \
            "$(( SRANDOM % 256 ))" ;;
        ipv6) printf '%x:%x:%x::%x' "$(( SRANDOM % 65536 ))" "$(( SRANDOM % 65536 ))" "$(( SRANDOM % 65536 ))" \
            "$(( SRANDOM % 65536 ))" ;;
        cidr) printf '%s/%s' "$(_val ipv4)" "$(( SRANDOM % 33 ))" ;;
        *) echo "_val: unknown kind \"$1\"" >&2; return 2 ;;
    esac
}

# What: replace each @KEY@ in a row from the caller's V map.
# Why: one fill for every table built on _val values.
# From: Issue #1683 | PR #1858
_fill() {
    local s="$1" k
    for k in "${!V[@]}"; do s="${s//"${k}"/"${V[${k}]}"}"; done
    printf '%s' "${s}"
}

# What: Removes dirs listed in a manifest file.
# Why: Function lets a test prove the cleanup.
# From: Issue #1683 | PR #1858
_trivy_cleanup_var_tmp_dirs() {
    local manifest="$1" d
    if [ -f "${manifest}" ]; then
        while IFS= read -r d; do
            if [ -n "${d}" ]; then
                rm -rf -- "${d}"
            fi
        done < "${manifest}"
    fi
}

# What: Removes /var/tmp scratch dirs this test made.
# Why: a "$(...)"-run helper can't set a var seen here.
# From: Issue #1683 | PR #1858
teardown() {
    _trivy_cleanup_var_tmp_dirs "${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    # What: on failure print the last run's raw values.
    # Why: a failed test must never hide its raw values.
    # From: Issue #1683 | PR #1858
    [ -n "${BATS_TEST_COMPLETED:-}" ] ||
        printf 'last-run status=%s\nlast-run output=%s\n' "${status:-unset}" "${output-}"
}

# =========================================================
# CORE INVARIANTS
# =========================================================

# What: real ci.yml needs per row -> gate rc and verdict.
# Why: §62: only success or a NOOP skip may green the gate.
# From: Issue #1683 | PR #1858
@test "result-gate maps each phase-result set to its verdict" {
    local needs req p all="" noop="" other=""
    needs="$(awk '/^  result:$/ { r = 1; next } r && /^  [^ ]/ { exit }
        r && /^    needs: \[/ { sub(/^    needs: \[/, ""); sub(/\].*$/, ""); gsub(/,/, " "); print; exit }' \
        "${BATS_TEST_DIRNAME}/../workflows/ci.yml")"
    req="$(_ci_block_entry_list ci_result_gate "" required)" || { echo "required: ${req}"; return 1; }
    req=" ${req//$'\n'/ } "
    [ -n "${needs// }" ] && [ -n "${req// }" ] || { echo "needs '${needs}' or required '${req}' empty"; return 1; }
    for p in ${req}; do
        [[ " ${needs} " == *" ${p} "* ]] || { echo "required ${p} is not in the result needs: ${needs}"; return 1; }
    done
    for p in ${needs}; do
        all+=" ${p}:success"
        if [[ "${req}" == *" ${p} "* ]]; then noop+=" ${p}:success"; else noop+=" ${p}:skipped" other="${other:-${p}}"; fi
    done
    [ -n "${other}" ] || { echo "no optional phase in the result needs: ${needs}"; return 1; }
    _json() {
        local e out=""
        for e in $1; do out+="${out:+,}\"${e%%:*}\":{\"result\":\"${e#*:}\",\"outputs\":{}}"; done
        printf '{%s}' "${out}"
    }
    _row() {
        CI_NEEDS="$(_json "$4")" run ci_cmd_result_gate
        _expect "$1" "$2" "$3"
    }
    CI_NEEDS="$(_json "${all}")" run bash "${CI_SH}" result-gate
    _expect all-success-cli 0 "-> SUCCESS" || return 1
    _row noop 0 "-> SUCCESS" "${noop}" || return 1
    for p in ${req}; do
        _row "${p}-skipped" 1 "[CI-ERROR-CORE-0100] phase=\"${p}\" result=\"skipped\"" "${all/ ${p}:success/ ${p}:skipped}" || return 1
        _row "${p}-missing" 1 "[CI-ERROR-CORE-0132] phase=\"${p}\"" "${all/ ${p}:success/}" || return 1
    done
    _row "${other}-failed" 1 "[CI-ERROR-CORE-0116] phase=\"${other}\" result=\"failure\"" "${noop/ ${other}:skipped/ ${other}:failure}" || return 1
    CI_NEEDS="" run ci_cmd_result_gate
    _expect empty 2 "[CI-ERROR-CORE-0101]" || return 1
    CI_NEEDS="{" run ci_cmd_result_gate
    _expect not-json 2 '[CI-ERROR-CORE-0133];cmd="jq" rc=' || return 1
    CI_NEEDS="[\"$(_val name)\"]" run ci_cmd_result_gate
    _expect not-object 2 '[CI-ERROR-CORE-0133];cmd="jq" rc=' || return 1
}

# What: per row: bad or missing input -> rc 2 and its id.
# Why: input errors stop with our id before any backend.
# From: Issue #1683 | PR #1858
@test "every command fails closed on missing input with its own id" {
    local case envs args id wrap want
    local -a ev av
    local -A V=(
        ["@SVC@"]="$(ci_services | awk 'NR == 1')" ["@TOOL@"]="$(_ci_block_keys build_toolchain | awk 'NR == 1')"
        ["@BAD@"]="$(_val name)" ["@FOREIGN@"]="$(_val platform)" ["@DIGEST@"]="$(_val digest)"
        ["@USER@"]="$(_val name)" ["@TOKEN@"]="$(_val name)" ["@MISSING@"]="$(_val path)"
    )
    V["@PLAT@"]="$(_ci_platforms "${V["@SVC@"]}" | awk 'NR == 1')"
    [ -n "${V["@SVC@"]}" ] && [ -n "${V["@TOOL@"]}" ] && [ -n "${V["@PLAT@"]}" ] || { echo "inputs: ${V[*]}"; return 1; }
    while IFS='|' read -r case envs args id wrap; do
        ev=() av=()
        envs="$(_fill "${envs}")" args="$(_fill "${args}")"
        [ "${envs}" = - ] || read -r -a ev <<< "${envs}"
        read -r -a av <<< "${args}"
        run env -u GHCR_USERNAME -u GHCR_TOKEN "${ev[@]}" bash "${CI_SH}" "${av[@]}"
        want="[${id}]"; [ "${wrap}" = - ] || want="[${wrap}];${want}"
        _expect "${case}" 2 "${want}" || return 1
        # What: only INFO, wrapper and raw: before the id
        # Why: any other line is a backend that ran first.
        # From: Issue #1683 | PR #1858
        [ -z "$(awk -v i="[${id}]" -v w="[${wrap}]" 'index($0, i) { exit }
            !/^\[CI-INFO-/ && index($0, w) != 1 && $0 != "raw:"' <<< "${output}")" ] \
            || { echo "${case}: output before the guard: ${output}"; return 1; }
    done <<'CASES'
unknown-command|-|@BAD@|CI-ERROR-CORE-0002|-
identity|-|identity|CI-ERROR-IDENTITY-0001|-
impact|-|impact|CI-ERROR-IMPACT-0001|-
resolve|-|resolve|CI-ERROR-RESOLVE-0001|-
resolve-platform|-|resolve @SVC@ @FOREIGN@|CI-ERROR-RESOLVE-0004|-
build-platform|-|build @SVC@ @FOREIGN@|CI-ERROR-BUILD-0006|-
test|-|test|CI-ERROR-TEST-0001|-
test-toolchain|-|test @TOOL@|CI-ERROR-TEST-0006|CI-ERROR-TEST-0003
test-stack|-|test-stack|CI-ERROR-TEST-0012|-
assemble|-|assemble|CI-ERROR-ASSEMBLE-0001|-
promote|-|promote|CI-ERROR-PROMOTE-0001|-
promote-channel|-|promote @BAD@|CI-ERROR-PROMOTE-0002|-
promote-sha|-|promote sha-@BAD@|CI-ERROR-PROMOTE-0002|-
variables-get|-|variables get|CI-ERROR-VARIABLES-0003|-
variables-verb|-|variables @BAD@|CI-ERROR-VARIABLES-0002|-
bake-image|GHCR_USERNAME=@USER@ GHCR_TOKEN=@TOKEN@|variables bake-check|CI-ERROR-VARIABLES-0008|-
build-args|-|build-args|CI-ERROR-BUILDARGS-0001|-
build-args-target|-|build-args @BAD@|CI-ERROR-BUILDARGS-0002|-
build-args-format|-|build-args @SVC@ --@BAD@|CI-ERROR-BUILDARGS-0005|-
build-tools-verb|-|build-tools @BAD@|CI-ERROR-BUILDTOOLS-0003|-
version-verb|-|version @BAD@|CI-ERROR-VERSION-0014|-
publish-auth|-|publish @SVC@|CI-ERROR-BUILD-0002|-
verify|-|verify|CI-ERROR-VERIFY-0001|-
verify-digest|-|verify @SVC@|CI-ERROR-VERIFY-0002|-
verify-platform|-|verify @SVC@ @DIGEST@|CI-ERROR-VERIFY-0004|-
verify-auth|-|verify @SVC@ @DIGEST@ @PLAT@|CI-ERROR-BUILD-0002|-
ship|-|ship|CI-ERROR-SHIP-0001|-
ship-platform|-|ship @SVC@|CI-ERROR-SHIP-0001|-
pr-title-missing|PR_TITLE= PR_AUTHOR=|check pr-title|CI-ERROR-CHECK-0012|-
logging-matrix-root|-|check logging-matrix @MISSING@|CI-ERROR-CHECK-0035|-
CASES
}

# What: wrappers: rc rules, then id, context and raw error.
# Why: §68: no wrapper hides a failure or its raw text.
# From: Issue #1683 | PR #1858
@test "command wrappers fail with their id, context and raw tool error" {
    local nofile id ctx site
    nofile="$(_val path)" id="[CI-ERROR-$(_val name)]" ctx="$(_val name)=1" site="$(_val name)"
    run _ci_capture 0 printf 'a\nb\n'
    _expect capture-ok 0 $'=a\nb' || return 1
    run _ci_capture 1 grep -x zz <<< "aa"
    _expect capture-miss 0 "=" || return 1
    run _ci_capture 1 grep -x aa <<< "aa"
    _expect capture-hit 0 "=aa" || return 1
    run _ci_capture 1 grep x "${nofile}"
    _expect capture-rc 2 "[CI-ERROR-CORE-0106];cmd=\"grep\" rc=2;No such file" || return 1
    run _ci_capture 0 sh -c 'echo out; echo warn >&2'
    _expect capture-stderr 2 "[CI-ERROR-CORE-0106];cmd=\"sh\" rc=0;warn;stdout:;out" || return 1
    run _ci_run "${id}" "${ctx}" sh -c 'echo out; echo warn >&2'
    _expect run-warn 0 "warn;out" || return 1
    run _ci_run "${id}" "${ctx}" grep x "${nofile}"
    _expect run-fail 2 "${id} ${ctx} cmd=\"grep\" rc=2;No such file" || return 1
    run _ci_mktemp -d "${nofile}/$(_val name).XXXXXX"
    _expect mktemp 2 "[CI-ERROR-CORE-0110] args=\"-d ${nofile}/;No such file" || return 1
    run _ci_ls_files "${site}" "${nofile}" "*.$(_val name)"
    _expect ls-files 2 "[CI-ERROR-CHECK-0071] site=\"${site}\" root=\"${nofile}\";cmd=\"git\" rc=" || return 1
    [[ "${output}" == *"cannot change to"* || "${output}" == *"No such file"* ]] || { echo "ls-files raw: ${output}"; return 1; }
    run _ci_producer_ok 1 1
    _expect producer-at-max 0 - || return 1
    run _ci_producer_ok 3 0
    _expect producer-above 2 "[CI-ERROR-CORE-0010];rc=3" || return 1
    run _ci_producer_ok 2 1
    _expect producer-above-max 2 "[CI-ERROR-CORE-0010];rc=2" || return 1
}

# What: write <bin>/<tool>; the body comes on stdin.
# Why: one writer for every PATH-injected tool stub.
# From: Issue #1683 | PR #1858
_tool_stub() {
    local bin="$1" tool="$2"
    mkdir -p "${bin}"
    {
        printf '#!/usr/bin/env bash\n'
        cat
    } > "${bin}/${tool}"
    chmod +x "${bin}/${tool}"
}

# What: docker CLI stand-in; state and faults under $DS.
# Why: one stub; setup.sh and ci.sh run their real paths.
# From: Issue #1683 | PR #1858
_docker_stub() {
    _tool_stub "$1" docker <<'STUB'
: "${DS:?the docker stub needs DS, its state dir}"
printf '%s\n' "$*" >> "${DS}/docker.log"
[ "$1" != login ] || printf 'stdin-sha256=%s\n' "$(sha256sum | cut -d' ' -f1)" >> "${DS}/docker.log"
if [ -s "${DS}/answers" ]; then
    n=0
    while IFS=$'\x1f' read -r glob rc out err times; do
        n=$(( n + 1 ))
        [[ " $* " == ${glob} ]] || continue
        used=0
        [ ! -e "${DS}/answer-used-${n}" ] || used="$(cat "${DS}/answer-used-${n}")"
        [ -z "${times}" ] || [ "${used}" -lt "${times}" ] || continue
        used=$(( used + 1 ))
        echo "${used}" > "${DS}/answer-used-${n}"
        out="${out//%CALL%/${used}}"
        [ -z "${out}" ] || printf '%b\n' "${out}"
        [ -z "${err}" ] || printf '%b\n' "${err}" >&2
        exit "${rc}"
    done < "${DS}/answers"
fi
[ ! -e "${DS}/fail-$1" ] || { echo "docker $1: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1; }
here="$(dirname "$(readlink -f "$0")")" || exit 1
case "$1" in
    --version) echo 'docker CLI (test stub)' ;;
    info) echo 'Server Version: test stub' ;;
    compose)
        all=("$@")
        shift
        while :; do case "${1:-}" in --env-file|-f|-p|--profile) shift 2 ;; *) break ;; esac; done
        case "$1" in
            config) [ ! -e "${DS}/fail-config" ] || { echo "compose config: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1; }
                [ ! -e "${DS}/fail-config-after-up" ] || [ ! -e "${DS}/running" ] \
                    || { echo "compose config: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1; }
                exec "$(cat "${here}/docker-real")" "${all[@]}" ;;
            ps) case "${2:-}" in
                    --all) ;;
                    -a) [ ! -e "${DS}/running" ] || [ -e "${DS}/gone-${!#}" ] || echo "${DS##*/}-${!#}" ;;
                    -q) [ ! -e "${DS}/running" ] || echo "${DS##*/}" ;;
                    *) echo "${DS##*/} ${STUB_SECRET:-}" ;;
                esac ;;
            stop|down) rm -f "${DS}/running" ;;
            up) [ ! -e "${DS}/fail-apply" ] || case " $* " in
                    *" --remove-orphans "*) echo "compose up: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1 ;;
                esac
                printf '%s\n' "${all[@]:0:${#all[@]}-$#}" > "${DS}/running" ;;
            pull) ;;
            exec) shift; [ "$1" != -T ] || shift; shift
                [ ! -e "${DS}/pdns-api-key" ] || PDNS_API_KEY="$(cat "${DS}/pdns-api-key")" exec "$@"
                exec "$@" ;;
            images) echo '[]' ;;
            logs) echo "${!#} ${STUB_SECRET:-}" ;;
            version) echo 'docker compose (test stub)' ;;
            *) echo "unexpected docker compose call: $*" >&2; exit 97 ;;
        esac ;;
    volume)
        case "$2" in
            ls) ls -1 "${DS}/volumes" ;;
            create) mkdir -p "${DS}/volumes/$3" ;;
            rm) shift 2; for v in "$@"; do [ "${v}" = -f ] || rm -rf "${DS:?}/volumes/${v}"; done ;;
            *) echo "unexpected docker volume call: $*" >&2; exit 97 ;;
        esac ;;
    login) ;;
    push) ;;
    run)
        shift
        maps=("/tmp=$(mktemp -d "${DS}/run.XXXXXX")") ep=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --rm|-i) shift ;;
                --network) shift 2 ;;
                --entrypoint) ep=("$2"); shift 2 ;;
                -v) src="${2%%:*}" dst="${2#*:}"; dst="${dst%%:*}"
                    case "${src}" in /*) ;; *) src="${DS}/volumes/${src}"; mkdir -p "${src}" ;; esac
                    maps+=("${dst}=${src}"); shift 2 ;;
                *) break ;;
            esac
        done
        printf '%s\n' "$1" >> "${DS}/run-images"
        shift
        args=()
        for a in "$@"; do
            for m in "${maps[@]}"; do a="${a//"${m%%=*}"/"${m#*=}"}"; done
            args+=("${a}")
        done
        exec "${ep[@]}" "${args[@]}" ;;
    ps) [ ! -e "${DS}/foreign" ] || cut -d' ' -f1 "${DS}/foreign" ;;
    inspect) svc="${!#}"; svc="${svc#"${DS##*/}"-}"
        case "$3" in
            *State.Health*)
                if [ -e "${DS}/health-${svc}" ]; then
                    h="$(head -n 1 "${DS}/health-${svc}")"
                    [ "$(wc -l < "${DS}/health-${svc}")" -le 1 ] || sed -i 1d "${DS}/health-${svc}"
                    [ "${h}" = none ] || echo "${h}"
                elif [ -e "${DS}/running" ]; then echo healthy; fi ;;
            *State.Status*)
                if [ -e "${DS}/status-${svc}" ]; then cat "${DS}/status-${svc}"
                elif [ -e "${DS}/running" ]; then echo running; else echo exited; fi ;;
            *RestartPolicy*) if [ -e "${DS}/restart-${svc}" ]; then cat "${DS}/restart-${svc}"; else echo unless-stopped; fi ;;
            *ExitCode*) if [ -e "${DS}/exitcode-${svc}" ]; then cat "${DS}/exitcode-${svc}"; else echo 0; fi ;;
            *) [ ! -e "${DS}/foreign" ] || awk -v id="${!#}" '$1 == id { print $2 }' "${DS}/foreign" ;;
        esac ;;
    logs) echo "${!#} log ${STUB_SECRET:-}" ;;
    port) svc="$2"; svc="${svc#"${DS##*/}"-}"
        mapfile -t up < "${DS}/running"
        json="$("$(cat "${here}/docker-real")" "${up[@]}" config --format json)" || exit 1
        out="$(jq -r --arg s "${svc}" --arg t "${3%/*}" '.services[$s].ports[]? | select((.target | tostring) == $t)
            | if (.host_ip // "") == "" then "0.0.0.0:\(.published)", "[::]:\(.published)"
              elif (.host_ip | test(":")) then "[\(.host_ip)]:\(.published)"
              else "\(.host_ip):\(.published)" end' <<< "${json}")" || exit 1
        [ -n "${out}" ] || { echo "Error: No public port '$3' published for $2" >&2; exit 1; }
        printf '%s\n' "${out}" ;;
    exec) [ -e "${DS}/running" ] ;;
    buildx)
        case "$2" in
            version) echo 'docker buildx (test stub)' ;;
            build) ;;
            imagetools)
                [ ! -e "${DS}/inspect-fail" ] || { echo "ERROR: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1; }
                case "$*" in
                    *"{{.Manifest.Digest}}"*)
                        [ -e "${DS}/digest" ] || { echo "ERROR: $4: not found" >&2; exit 1; }
                        n=1; [ ! -e "${DS}/inspect-calls" ] || n=$(( $(cat "${DS}/inspect-calls") + 1 ))
                        echo "${n}" > "${DS}/inspect-calls"
                        [ ! -e "${DS}/digest-flip" ] || [ "${n}" != "$(cut -d' ' -f1 "${DS}/digest-flip")" ] \
                            || cut -d' ' -f2 "${DS}/digest-flip" > "${DS}/digest"
                        cat "${DS}/digest" ;;
                    *--format*) [ ! -e "${DS}/single-platform" ] || cat "${DS}/single-platform" ;;
                    *) pf="${here}/docker-platforms"; [ ! -e "${DS}/published" ] || pf="${DS}/published"
                        echo 'Manifests:'; awk '{ print "  Platform:    " $0 }' "${pf}" ;;
                esac ;;
            *) echo "unexpected docker buildx call: $*" >&2; exit 97 ;;
        esac ;;
    *) echo "unexpected docker call: $*" >&2; exit 97 ;;
esac
STUB
    # What: the stub publishes the real SOT platforms
    # Why: setup.sh checks the real host, not test arches
    # From: Issue #1683 | PR #1858
    CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_platforms dns > "$1/docker-platforms" \
        || { echo "SOT platforms unreadable"; return 1; }
    type -P docker > "$1/docker-real" && [ "$(cat "$1/docker-real")" != "$1/docker" ] \
        || { echo "no real docker binary for compose config"; return 1; }
    # What: the cache DNS answers CDN names with its own IP
    # Why: the update health gate resolves one CDN name
    # From: Issue #1683 | PR #1858
    _tool_stub "$1" dig <<'STUB'
[ ! -e "${DS}/no-answer" ] || exit 0
for a in "$@"; do case "${a}" in @*) server="${a#@}" ;; esac; done
echo "${server:?the dig stub needs @server}"
STUB
}

# What: script one docker answer: glob, rc, out, err, times
# Why: the one stand-in answers any call; first match wins
# From: Issue #1683 | PR #1858
_docker_answer() {
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" >> "${DS}/answers"
}

# What: docker compose on the real deploy/prod files
# Why: tests take names, volumes, profiles from their owner
# From: Issue #1683 | PR #1858
_prod_compose() {
    local root
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    docker compose --env-file "${root}/deploy/prod/.env" -f "${root}/deploy/prod/docker-compose.yml" "$@"
}

# What: a prod volume config backups carry, sorted first
# Why: compose lists volumes in no fixed order
# From: Issue #1683 | PR #1858
_backup_volume() {
    local root project cache
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    project="$(_prod_compose config --format json | jq -r .name)" || return 1
    cache="$(compose_cache_volume_name "${root}/deploy/prod" "${root}/deploy/prod/.env")" || return 1
    _prod_compose config --volumes | sort | grep -vxF -- "${cache#"${project}_"}" | awk 'NR == 1'
}

# What: a deploy/prod install from the real prod files
# Why: setup.sh tests run on owner inputs, not hand copies
# From: Issue #1683 | PR #1858
_prod_install() {
    local root dir="$1"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    mkdir -p "${dir}" "${dir}/../../config" "${dir}/../../.github/yaml" "${dir}/../../.github/scripts" \
        "${dir}/../../services/dhcp" || return 1
    cp "${root}/deploy/prod/docker-compose.yml" "${root}/deploy/prod/.env" "${dir}/" || return 1
    cp "${root}/services/dhcp/kea-ctrl-agent.conf" "${dir}/../../services/dhcp/" || return 1
    cp -r "${root}/config/prod" "${dir}/../../config/" || return 1
    cp "${root}/.github/yaml/build-manifest.yml" "${dir}/../../.github/yaml/" || return 1
    cp "${root}/.github/scripts/ci.sh" "${dir}/../../.github/scripts/" || return 1
    set_env_key LANCACHE_STATE_DIR "${dir}/state" "${dir}/.env"
    set_env_key LANCACHE_IMAGE_TAG "v$(cat "${root}/VERSION")" "${dir}/.env"
}

# What: tracked tree copy for a setup.sh run of its own
# Why: setup.sh writes into its checkout; root stays clean
# From: Issue #1683 | PR #1858
_checkout_copy() {
    local root="$1" dir="$2" list="${BATS_TEST_TMPDIR}/tracked-files" tree="${BATS_TEST_TMPDIR}/tree.tar"
    git -C "${root}" -c core.quotePath=false ls-files > "${list}" || return 1
    tar -C "${root}" -T "${list}" -cf "${tree}" || return 1
    mkdir -p "${dir}" && tar -C "${dir}" -xf "${tree}"
}

# What: sccache stub failing per level; logs the env seen.
# Why: no real server; the cache chain env is observable.
# From: Issue #1683 | PR #1858
_stub_sccache() {
    local bin="$1" fail="$2" raw="${3:-}" log="${4:-/dev/null}"
    _tool_stub "${bin}" sccache <<STUB
printf 'r=%s g=%s c=%s w=%s\n' "\${SCCACHE_REDIS:-}" "\${SCCACHE_GHA_ENABLED:-}" \
    "\${SCCACHE_MULTILEVEL_CHAIN:-}" "\${SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY:-}" >> '${log}'
case '${fail}' in
    always) echo '${raw}' >&2; exit 2 ;;
    redis) [ -z "\${SCCACHE_REDIS:-}" ] || { echo '${raw}' >&2; exit 2; } ;;
    gha) [ -z "\${SCCACHE_GHA_ENABLED:-}" ] || { echo '${raw}' >&2; exit 2; } ;;
esac
exit 0
STUB
}

# What: real SOT targets: the name prod pulls, ref and tag.
# Why: §15: CI must publish exactly what deploy/prod pulls.
# From: Issue #1683 | PR #1858
@test "image-ref builds the one registry service@digest form" {
    local root reg pfx name svc tool plats keys p s dig id
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    reg="$(awk -F= '$1 == "LANCACHE_IMAGE_REGISTRY" { print $2; exit }' "${root}/deploy/prod/.env")"
    pfx="$(awk -F= '$1 == "LANCACHE_IMAGE_PREFIX" { print $2; exit }' "${root}/deploy/prod/.env")"
    [ -n "${reg}" ] && [ -n "${pfx}" ] || { echo "deploy/prod/.env: registry '${reg}' prefix '${pfx}'"; return 1; }
    svc="$(_ci_block_keys services all)" || { echo "services: ${svc}"; return 1; }
    svc="${svc%%$'\n'*}"
    tool="$(_ci_block_keys build_toolchain all)" || { echo "build_toolchain: ${tool}"; return 1; }
    tool="${tool%%$'\n'*}"
    plats="$(_ci_block_entry_list build_matrix "" platforms)" || { echo "platforms: ${plats}"; return 1; }
    keys="$(_ci_block_keys platform_arch all)" || { echo "platform_arch: ${keys}"; return 1; }
    keys=" ${keys//$'\n'/ } "
    name="${reg}/${pfx,,}" dig="$(_val digest)" id="$(_val sha)"
    export GITHUB_REPOSITORY="${pfx^^}"
    run _ci_image_ref
    _expect prefix 0 "=${name}" || return 1
    run _ci_image_ref "${svc}"
    _expect name 0 "=${name}/${svc}" || return 1
    run _ci_image_ref "${svc}" "${dig}"
    _expect ref 0 "=${name}/${svc}@${dig}" || return 1
    run _ci_build_tools_image
    _expect toolchain 0 "=${name}/${tool}" || return 1
    while IFS= read -r p; do
        run _ci_image_tag "${svc}" "${p}" "${id}"
        _expect "tag ${p}" 0 "${name}/${svc}:sha-${id}-" || return 1
        s="${output#"${name}/${svc}:sha-${id}-"}"
        [[ "${p}" == *"/${s}" && "${keys}" == *" ${s} "* ]] || { echo "tag ${p}: arch '${s}' not the platform arch: ${output}"; return 1; }
    done <<< "${plats}"
    run _ci_image_ref "${svc}" ""
    _expect empty-digest 2 "[CI-ERROR-CORE-0135] target=\"${svc}\"" || return 1
    _norepo() { unset GITHUB_REPOSITORY; _ci_image_ref "$@"; }
    run _norepo "${svc}" "${dig}"
    _expect no-owner 2 '[CI-ERROR-CORE-0128] name="GITHUB_REPOSITORY"' || return 1
}

# =========================================================
# SEMANTIC IMPACT
# =========================================================

# What: architecture §85 paths -> exactly their candidates.
# Why: §11/§13: no unrelated target, no prefix-only match.
# From: Issue #1683 | PR #1858
@test "plan selects exactly the targets whose contexts a path touches" {
    local root targets tool tctx tfile p case path want row l
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    targets="$(ci_build_targets)" || { echo "targets: ${targets}"; return 1; }
    tool="$(_ci_block_keys build_toolchain all)" || { echo "build_toolchain: ${tool}"; return 1; }
    tool="${tool%%$'\n'*}"
    tctx="$(_ci_block_entry_field build_toolchain "${tool}" context)" || { echo "toolchain context: ${tctx}"; return 1; }
    tfile="$(git -C "${root}" ls-files -- "${tctx}")" || { echo "ls-files ${tctx}: ${tfile}"; return 1; }
    tfile="${tfile%%$'\n'*}"
    [ -n "${tfile}" ] || { echo "no tracked file under ${tctx}"; return 1; }
    p="services/dns$(_val name)/$(_val name)"
    _want() {
        local t out=""
        for t in ${targets}; do
            if [[ " $1 " == *" ${t} "* ]]; then out+="${t}=true "; else out+="${t}=false "; fi
        done
        printf '%s' "${out% }"
    }
    while IFS='|' read -r case path want; do
        if [ "${case}" = readme ]; then run bash "${CI_SH}" plan "${path}"; else run ci_cmd_plan "${path}"; fi
        [ "${status}" -eq 0 ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        row=""
        while IFS= read -r l; do
            case "${l}" in *=true | *=false) row+="${l} " ;; esac
        done <<< "${output}"
        [ "${row% }" = "$(_want "${want}")" ] || { echo "${case}: got '${row% }' want '$(_want "${want}")'"; return 1; }
        [[ "${output}" == *"candidates only; identity/CAS decides build"* ]] || { echo "${case}: no candidate note: ${output}"; return 1; }
    done <<CASES
readme|README.md|
dns-input|services/dns/entrypoint.sh|dns
dns-domains|services/dns/cdn-domains.txt|dns proxy
prefix-only|${p}|
toolchain|${tfile}|${tool}
CASES
}

# What: missing SOT: each reader rc 2, own id, raw error.
# Why: a reader error must never read as an empty value.
# From: Issue #1683 | PR #1858
@test "an unreadable SOT fails every reader caller with raw" {
    local nosot blk name
    nosot="$(_val path)" name="$(_val name)"
    blk="$(awk '/^[A-Za-z0-9_.-]+:[[:space:]]*$/ { sub(/:.*/, ""); print; exit }' "${CI_MANIFEST_SOURCE}")"
    [ -n "${blk}" ] || { echo "no block in ${CI_MANIFEST_SOURCE}"; return 1; }
    CI_MANIFEST="${nosot}" run _ci_block_keys "${blk}"
    _expect keys 2 "[CI-ERROR-CORE-0139] file=\"${nosot}\";no such file or directory;[CI-ERROR-CORE-0109] block=\"${blk}\";manifest=\"${nosot}\"" || return 1
    CI_MANIFEST="${nosot}" run _ci_block_entry_field "${blk}" "" "${name}"
    _expect field 2 "[CI-ERROR-CORE-0139] file=\"${nosot}\";no such file or directory;[CI-ERROR-CORE-0107] block=\"${blk}\";manifest=\"${nosot}\"" || return 1
    CI_MANIFEST="${nosot}" run _ci_block_entry_list "${blk}" "" "${name}"
    _expect list 2 "[CI-ERROR-CORE-0139] file=\"${nosot}\";no such file or directory;[CI-ERROR-CORE-0108] block=\"${blk}\";manifest=\"${nosot}\"" || return 1
    CI_MANIFEST="${nosot}" run _ci_channel_field "${name}"
    _expect channel 2 "[CI-ERROR-CORE-0139] file=\"${nosot}\";no such file or directory;[CI-ERROR-CORE-0123] field=\"${name}\";manifest=\"${nosot}\"" || return 1
    run _ci_sot_load "${nosot}"
    _expect load 2 "[CI-ERROR-CORE-0139] file=\"${nosot}\";no such file or directory;[CI-ERROR-CORE-0136] manifest=\"${nosot}\"" || return 1
    CI_MANIFEST="${nosot}" run bash "${CI_SH}" plan "${name}"
    _expect cli 2 "[CI-ERROR-CORE-0003] manifest=\"${nosot}\"" || return 1
    run _ci_block_keys "${blk}" all
    [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "loaded real SOT no longer answers: rc ${status}: ${output}"; return 1; }
}

# =========================================================
# SERVICE DEPENDENCIES
# =========================================================

# =========================================================
# BUILD IDENTITIES
# =========================================================

@test "identity is keyed, deterministic, per target and platform" {
    _stand_ins || return 1
    # What: 64-hex per SOT platform; moves on own content.
    # Why: NOOP/reuse needs stable ids that never collide.
    # From: Issue #1683 | PR #1858
    local r a1 a1b b1 a2 b0
    local -A V=(
        ["@A@"]="$(_val name)" ["@B@"]="$(_val name)" ["@PK@"]="$(_val name)" ["@CA@"]="$(_val name)" ["@CB@"]="$(_val name)"
        ["@TS@"]="$(_val name)" ["@TP@"]="$(_val name)" ["@PKG@"]="$(_val name)" ["@P1@"]="$(_val platform)"
        ["@P2@"]="$(_val platform)" ["@X@"]="$(_val platform)" ["@AA@"]="$(_val name)" ["@AB@"]="$(_val name)"
        ["@F@"]="$(_val name)" ["@IMG@"]="$(_val host)/$(_val name)@$(_val digest)"
    )
    V["@K1@"]="${V["@P1@"]##*/}" V["@K2@"]="${V["@P2@"]##*/}"
    r="$(_val path)"
    mkdir -p "${r}/${V["@CA@"]}" "${r}/${V["@CB@"]}"
    _val name > "${r}/${V["@CA@"]}/${V["@F@"]}"; _val name > "${r}/${V["@CB@"]}/${V["@F@"]}"
    git -C "${r}" init -q && git -C "${r}" add -A
    _fill "$(printf '%s\n' 'services:' '  @A@:' '    context: @CA@' '    build_type: @TS@' \
        '  @B@:' '    context: @CB@' '    build_type: @TS@' \
        '  @PK@:' '    context: @CB@' '    build_type: @TP@' '    packages: ["@PKG@"]' \
        'build_identity:' '  @TS@:' '    inputs: [source_sha]' '  @TP@:' '    inputs: [source_sha, package_versions]' \
        'base_images:' '  alpine: @IMG@' 'build_matrix:' '  platforms: [@P1@, @P2@]' \
        'platform_arch:' '  @K1@:' '    apk: @AA@' '  @K2@:' '    apk: @AB@')" > "${r}/m.yml"
    export CI_MANIFEST="${r}/m.yml" CI_REPO_ROOT="${r}"
    _id() { run --separate-stderr bash "${CI_SH}" identity "$@"; [ "${status}" -eq 0 ] || { echo "identity $*: rc ${status} ${stderr}"; return 1; }; }
    _id "${V["@A@"]}" "${V["@P1@"]}" && a1="${output}"
    [[ "${a1}" =~ ^platform=${V["@P1@"]}\ identity=[0-9a-f]{64}$ ]] || { echo "shape: ${a1}"; return 1; }
    _id "${V["@A@"]}" "${V["@P1@"]}" && [ "${output}" = "${a1}" ] || { echo "not deterministic: ${output}"; return 1; }
    _id "${V["@B@"]}" "${V["@P1@"]}" && b1="${output}" && [ "${b1#*identity=}" != "${a1#*identity=}" ] || { echo "per target"; return 1; }
    _id "${V["@A@"]}" "${V["@P2@"]}" && a2="${output}" && [ "${a2#*identity=}" != "${a1#*identity=}" ] || { echo "per platform"; return 1; }
    _id "${V["@PK@"]}" "${V["@P1@"]}" && [[ "${output}" =~ ^platform=${V["@P1@"]}\ identity=[0-9a-f]{64}$ ]] || { echo "pkgs: ${output}"; return 1; }
    _id "${V["@A@"]}" && [ "${#lines[@]}" -eq 2 ] && [ "${lines[0]}" = "${a1}" ] && [ "${lines[1]}" = "${a2}" ] \
        || { echo "fan-out: ${output}"; return 1; }
    run bash "${CI_SH}" identity "${V["@A@"]}" "${V["@X@"]}"
    _expect foreign-platform 2 "[CI-ERROR-IDENTITY-0002] service=\"${V["@A@"]}\"" || return 1
    # What: an edit in A's context moves A only, never B.
    # Why: impact is content identity, never a path guess.
    # From: Issue #1683 | PR #1858
    _id "${V["@B@"]}" "${V["@P1@"]}" && b0="${output}"
    _val name > "${r}/${V["@CA@"]}/${V["@F@"]}" && git -C "${r}" add -A
    _id "${V["@A@"]}" "${V["@P1@"]}" && a1b="${output}" && [ "${a1b}" != "${a1}" ] || { echo "A did not move"; return 1; }
    _id "${V["@B@"]}" "${V["@P1@"]}" && [ "${output}" = "${b0}" ] || { echo "B moved: ${output} vs ${b0}"; return 1; }
    sed -i '/^  platforms: \[/d' "${CI_MANIFEST}"
    run bash "${CI_SH}" identity "${V["@A@"]}"
    _expect no-platforms 2 "[CI-ERROR-IDENTITY-0003]" || return 1
    [[ "${output}" != *"identity="* ]] || { echo "identity line leaked: ${output}"; return 1; }
}

# =========================================================
# PLATFORMS
# =========================================================

# What: The first SOT external pin with a consumer.
# Why: pin tests derive their example, never name one.
# From: Issue #1683
_pin_dep() {
    local d
    for d in $(_ci_block_keys external_versions); do
        [ -n "$(_ci_block_entry_field external_versions "${d}" consumer)" ] && { echo "${d}"; return 0; }
    done
    return 1
}

# What: The build target that consumes that pin.
# Why: shared by the build-args and identity pin tests.
# From: Issue #1683
_pin_consumer() {
    _ci_block_entry_field external_versions "$(_pin_dep)" consumer
}

# =========================================================
# RESOLVER STATES
# =========================================================

# =========================================================
# RETRY CLASSIFICATION
# =========================================================

# What: per row: op and raw failure text -> class.
# Why: one classifier decides retry, fail fast or build.
# From: Issue #1683 | PR #1858
@test "retry classifier maps each failure text per op" {
    local name op text want got
    local -A V=(
        ["@REF@"]="$(_val host)/$(_val name)/$(_val name):$(_val name)" ["@CRATE@"]="$(_val name)" ["@HOST@"]="$(_val host)"
        ["@GREF@"]="refs/$(_val name)" ["@PKG@"]="$(_val name)" ["@FILE@"]="$(_val name).c" ["@SYM@"]="$(_val name)"
        ["@MS@"]="$(_val int 1 900)ms" ["@PID@"]="$(_val int 1 9000)" ["@URL@"]="$(_val url)/$(_val name).json"
        ["@TAG@"]="$(_val name)" ["@TXT@"]="$(_val name) $(_val name)"
    )
    while IFS='|' read -r name op text want; do
        got="$(_ci_classify_failure "$(printf '%b' "$(_fill "${text}")")" ${op:+"${op}"})"
        [ "${got}" = "${want}" ] || { echo "${name}: got ${got}, want ${want}"; return 1; }
    done <<'CASES'
rate-429||toomanyrequests: HTTP 429|transient
http-503||received HTTP 503 from @HOST@|transient
io-timeout||dial tcp: i/o timeout|transient
refused||connection refused|transient
curl-503||curl: (22) The requested URL returned error: 503|transient
curl-403||curl: (22) The requested URL returned error: 403|transient
auth-401||HTTP 401 unauthorized|permanent
compile||error: could not compile @CRATE@|permanent
pull-denied||pull access denied for @REF@|permanent
curl-404||curl: (22) The requested URL returned error: 404|permanent
apk-missing||ERROR: unable to select packages: @PKG@ (no such package)|permanent
apk-tags||ERROR: Not committing changes due to missing repository tags.|permanent
no-local-image||An image does not exist locally with the tag: @REF@|permanent
no-such-image||Error response from daemon: No such image: @REF@|permanent
manifest-unknown||manifest unknown|not_found
not-found-default||@REF@: not found: manifest|not_found
not-found-registry|registry|@REF@: not found: manifest|not_found
not-found-read|registry-read|@REF@: not found: manifest|not_found
denied-read|registry-read|denied: requested access to the resource|permanent
denied||denied: requested access to the resource|permanent
login-denied|registry|Error response from daemon: Get "https://@HOST@/v2/": denied: denied|permanent
read-denied|registry-read|@REF@: denied: @TXT@|permanent
manifest-invalid|registry|manifest invalid: manifest invalid|permanent
name-invalid|registry|name invalid: invalid repository name|permanent
unsupported|registry|unsupported: the operation is unsupported|permanent
name-unknown|registry-read|name unknown: repository name not known to registry|not_found
rate-registry|registry|toomanyrequests: too many requests|transient
novel||@TXT@|transient
reset-caps||Connection reset by peer|transient
auth-caps||HTTP 401 Unauthorized|permanent
gh-404|github-api|gh: Not Found (HTTP 404)|permanent
gh-404-read|github-read|gh: Not Found (HTTP 404)|not_found
gh-noasset-read|github-read|no assets match the file pattern|not_found
gh-noasset-api|github-api|no assets to download|permanent
gh-auth-read|github-read|To get started with GitHub CLI, please run:  gh auth login|permanent
gh-no-login|github-api|To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.|permanent
layer-lock|buildx|(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:@TAG@ locked for @MS@ (since @TAG@): unavailable\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
go-panic|buildx|panic: methodref has no signature\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
buildx-compile|buildx|error: could not compile @CRATE@|permanent
run-missing-var|buildx|@SYM@ is required (no default)\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|permanent
run-network|buildx|connection reset by peer\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
run-registry|registry|@SYM@ is required\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
git-sideband||unexpected disconnect while reading sideband packet|transient
git-hung-up||The remote end hung up unexpectedly|transient
git-no-host||Could not resolve host: @HOST@|transient
git-rpc||RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly|transient
git-gnutls||GnuTLS recv error (-9): A TLS packet with unexpected length was received.|transient
git-no-ref||fatal: couldn't find remote ref @GREF@|permanent
distcc|accel|distcc["@PID@"] (dcc_build_somewhere) ERROR: failed to distribute and fallbacks are disabled|transient
sccache|accel|sccache: error: Timed out waiting for server startup. Maybe the remote service is unreachable?|transient
ccache|accel|ccache: error: No such file or directory|transient
c-error|accel|@FILE@:1:23: error: '@SYM@' undeclared (first use in this function)|permanent
rust-error|accel|error: could not compile `@CRATE@` (bin "@CRATE@") due to 2 previous errors|permanent
fetch|accel|error: failed to download from `@URL@`|permanent
trivy-db|trivy|FATAL failed to download vulnerability DB: @TXT@|transient
trivy-init|trivy|database is not initialized|transient
trivy-other|trivy|@REF@: manifest unknown|permanent
CASES
}

# =========================================================
# BUILD ADMISSION
# =========================================================

# =========================================================
# TEST / SCAN
# =========================================================

# What: test-stack per real SOT target: SKIP or coded stop.
# Why: AG-VAL-008 off by default; §72 cache error no FAIL.
# From: Issue #1683 | PR #1858
@test "test-stack: rust off by default, apk skips, cache errors coded" {
    local s bt rust="" apk=""
    for s in $(_ci_block_keys services); do
        bt="$(_ci_block_entry_field services "${s}" build_type)" || { echo "build_type ${s}: ${bt}"; return 1; }
        [ "${bt}" != rust ] || rust="${rust:-${s}}"
        [ "${bt}" != apk ] || apk="${apk:-${s}}"
    done
    [ -n "${rust}" ] && [ -n "${apk}" ] || { echo "no rust '${rust}' or apk '${apk}' service in the SOT"; return 1; }
    _ts() { run _cache_env_clean env "$@" bash "${CI_SH}" test-stack; }
    _ts -u CI_RUST_VALIDATION TEST_SERVICES="${rust}"
    _expect rust-default 0 "service=${rust} tested=SKIP;AG-VAL-008" || return 1
    _ts CI_RUST_VALIDATION=false TEST_SERVICES="${rust}"
    _expect rust-false 0 "service=${rust} tested=SKIP;AG-VAL-008" || return 1
    _ts CI_RUST_VALIDATION=true SCCACHE_REDIS_MODE=required RUNNER_ENVIRONMENT=self-hosted TEST_SERVICES="${rust}"
    _expect self-hosted-no-redis 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-VARIABLES-0012];[CI-ERROR-TEST-0009] service=\"${rust}\"" || return 1
    [[ "${output}" != *"tested="* ]] || { echo "self-hosted-no-redis read as a result: ${output}"; return 1; }
    _ts CI_RUST_VALIDATION=true SCCACHE_REDIS_MODE=required RUNNER_ENVIRONMENT=github-hosted TEST_SERVICES="${rust}"
    _expect hosted-no-cache 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-CACHE-0007];[CI-ERROR-TEST-0009] service=\"${rust}\"" || return 1
    [[ "${output}" != *"tested="* ]] || { echo "hosted-no-cache read as a result: ${output}"; return 1; }
    _ts TEST_SERVICES="${apk}"
    _expect apk-skip 0 "service=${apk} tested=SKIP reason=\"no source tests" || return 1
}

# What: export step args: SOT kill timeout, cache pair only.
# Why: only the GHA cache runtime may reach later steps.
# From: Issue #1683 | PR #1858
@test "gha-runtime-args: kill-bounded step exports only the GHA cache runtime pair" {
    local t out envf other args got split
    local -a argv
    t="$(_val int 5 120)"; out="$(_val path)"; envf="$(_val path)"; other="ACTIONS_$(_val name)"
    CI_GHA_RUNTIME_EXPORT_TIMEOUT="${t}" GITHUB_OUTPUT="${out}" run ci_cmd_gha_runtime_args
    _expect args 0 "-s KILL ${t} /bin/sh -c " || return 1
    args="${lines[${#lines[@]}-1]}"
    [ "$(<"${out}")" = "args=${args}" ] || { echo "step output: $(<"${out}")"; return 1; }
    split="$(printf '%s' "${args}" | xargs -n1 printf '%s\n')" || { echo "args not splittable: ${args}"; return 1; }
    mapfile -t argv <<< "${split}"
    local ru tok
    ru="$(_val url)"; tok="$(_val name)"
    run env -i PATH="${PATH}" GITHUB_ENV="${envf}" ACTIONS_RESULTS_URL="${ru}" ACTIONS_RUNTIME_TOKEN="${tok}" \
        "${other}=$(_val name)" timeout "${argv[@]}"
    _expect export 0 - || return 1
    got="$(sort "${envf}" | paste -sd' ')"
    [ "${got}" = "ACTIONS_RESULTS_URL=${ru} ACTIONS_RUNTIME_TOKEN=${tok}" ] || { echo "exported: ${got}"; return 1; }
    CI_GHA_RUNTIME_EXPORT_TIMEOUT="$(_val name)" run ci_cmd_gha_runtime_args
    _expect bad-timeout 2 "[CI-ERROR-CACHE-0009]" || return 1
    CI_GHA_RUNTIME_EXPORT_TIMEOUT="${t}" GITHUB_OUTPUT="$(_val path)/$(_val name)/$(_val name)" run ci_cmd_gha_runtime_args
    _expect output-unwritable 2 "[CI-ERROR-CACHE-0010];raw:" || return 1
}

# What: temp root off tmpfs, made; uncreatable dirs coded.
# Why: bare mktemp in tools must land on disk, not RAM.
# From: Issue #1683 | PR #1858
@test "temp dirs: tmpfs refused, made on disk, else coded" {
    local base d long made
    base="/var/tmp/$(_val name)" d="${base}/$(_val name)" long="/var/tmp/$(printf '%0300d' 0)"
    CI_TMPDIR=/tmp run bash "${CI_SH}" check comment-length
    _expect tmpfs 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="/var/tmp/../../tmp/$(_val name)" run bash "${CI_SH}" check comment-length
    _expect dotdot 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="${d}" run bash -c 'source "$1"; _ci_tmp_init; echo "t=${TMPDIR}"' _ "${CI_SH}"
    made=no; [ ! -d "${d}" ] || made=yes
    rm -rf "${base}"
    _expect created 0 "t=${d}" || return 1
    [ "${made}" = yes ] || { echo "not created: ${d}"; return 1; }
    CI_TMPDIR="${long}" run _ci_tmp_init
    _expect uncreatable 2 "[CI-ERROR-CORE-0111] dir=\"${long}\"" || return 1
}

# What: per row: runner env -> proxy env, names, CA bundle.
# Why: AG-CI-009: self-hosted proxy only, CA job-local.
# From: Issue #1683 | PR #1858
@test "proxy init maps each runner and CA case" {
    local case envs probe rc want
    local -a ev
    local -A P=(
        [names]='echo "names=$(_ci_proxy_names | wc -l)"'
        [env]='echo "h=${https_proxy} n=${NO_PROXY}"; _ci_proxy_names | tr "\n" " "'
        [bundle]='[ "$(grep -c "BEGIN CERTIFICATE" "${CARGO_HTTP_CAINFO}")" -gt 0 ] && echo system-certs; tail -n 1 "${CARGO_HTTP_CAINFO}"; [ "${CURL_CA_BUNDLE}" = "${CARGO_HTTP_CAINFO}" ] && echo same; stat -c %a "${CARGO_HTTP_CAINFO}"'
    )
    local -A V=(["@PROXY@"]="$(_val url)" ["@EXCL@"]="$(_val host)" ["@CA@"]="$(_val name)")
    while IFS='|' read -r case envs probe rc want; do
        envs="$(_fill "${envs}")" want="$(_fill "${want}")"
        read -r -a ev <<< "${envs}"
        run env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy \
            "${ev[@]}" CI_TMPDIR="${BATS_TEST_TMPDIR}" \
            bash -c 'source "$1"; _ci_proxy_init || exit; eval "$2"' _ "${CI_SH}" "${P[${probe}]}"
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
hosted-off|RUNNER_ENVIRONMENT=github-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@|names|0|[CI-INFO-CORE-0113] proxy=off runner="github-hosted" http_set=yes;names=0
self-hosted|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_EXCLUSION=@EXCL@|env|0|[CI-INFO-CORE-0007];h=@PROXY@ n=@EXCL@;HTTP_PROXY HTTPS_PROXY
ca-bundle|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_CA=@CA@|bundle|0|[CI-INFO-CORE-0115];system-certs;@CA@;same;600
CASES
}

# =========================================================
# CACHE FALLBACK
# =========================================================

# =========================================================
# REGISTRY / PUBLISH / READBACK
# =========================================================

# What: login rows without a registry; token stays on stdin.
# Why: GHCR required, Docker Hub paired; no token on argv.
# From: Issue #1683 | PR #1858
@test "registry logins: GHCR required, Docker Hub paired, token on stdin" {
    local logins l
    _twice() { local a=0 b=0; _ci_dockerhub_login || a=$?; _ci_dockerhub_login || b=$?; echo "rc=${a},${b}"; }
    unset _CI_DOCKERHUB_DONE GHCR_USERNAME GHCR_TOKEN DOCKERHUB_USERNAME DOCKERHUB_TOKEN
    run _ci_require_ghcr_auth
    _expect no-ghcr 2 "[CI-ERROR-BUILD-0002]" || return 1
    run _ci_dockerhub_login
    _expect hub-none 0 "[CI-NOTICE-BUILD-0020]" || return 1
    DOCKERHUB_USERNAME="$(_val name)" run _ci_dockerhub_login
    _expect hub-half 2 "[CI-ERROR-BUILD-0021]" || return 1
    DOCKERHUB_TOKEN="$(_val name)" run _twice
    _expect hub-half-twice 0 "[CI-ERROR-BUILD-0021];[CI-ERROR-BUILD-0021];rc=2,2" || return 1
    logins="$(grep -n -E '(^[[:space:]]*|[|;&][[:space:]]*)docker login( |$)' "${CI_SH}")" || { echo "no docker login in ${CI_SH}"; return 1; }
    while IFS= read -r l; do
        [[ "${l}" == *'printf '*'| docker login '*'--password-stdin'* && "${l}" != *' -p '* && "${l}" != *'--password '* ]] \
            || { echo "token not on stdin: ${l}"; return 1; }
    done <<< "${logins}"
}

# =========================================================
# ASSEMBLY
# =========================================================

# =========================================================
# PROMOTION
# =========================================================

# =========================================================
# RELEASE
# =========================================================

# What: next patch tag per tag string; an rc tag refused.
# Why: AG-REL-013: only Z moves without a maintainer step.
# From: Issue #1683 | PR #1858
@test "release tag: next patch from a tag string, an rc tag refused" {
    local case arg rc want
    local -A V=(["@X@"]="$(_val int 0 50)" ["@Y@"]="$(_val int 0 50)" ["@Z@"]="$(_val int 0 50)")
    while IFS='|' read -r case arg rc want; do
        run _ci_next_patch_tag "$(_fill "${arg}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
next-rollover|v@X@.@Y@.9|0|=v@X@.@Y@.10
next-rc|v@X@.@Y@.@Z@-rc.1|2|[CI-ERROR-RELEASE-0015]
CASES
}

# =========================================================
# GC
# =========================================================

# =========================================================
# VALIDATION
# =========================================================

# What: per image pin, third-party kept, a gap fails closed
# Why: §48: validate runs the candidate, not a mutable tag.
# From: Issue #1683 | PR #1858
@test "validate pin override: per image, third-party kept, gap fails" {
    local root cfg cand="" s dig out ext img k miss extra shared
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export GITHUB_REPOSITORY
    GITHUB_REPOSITORY="$(awk -F= '$1 == "LANCACHE_IMAGE_PREFIX" { print $2; exit }' "${root}/deploy/prod/.env")"
    dig="$(_val digest)"
    while IFS= read -r s; do cand+="${s}=${dig}"$'\n'; done < <(ci_services)
    [ -n "${GITHUB_REPOSITORY}" ] && [ -n "${cand}" ] || { echo "inputs: ${GITHUB_REPOSITORY} | ${cand}"; return 1; }
    run _ci_validate_pin_override "${cand}"
    _expect pin 0 "services:" || return 1
    out="${output}"
    [ -n "$(grep '^    image: ' <<< "${out}")" ] || { echo "nothing pinned: ${out}"; return 1; }
    [ -z "$(grep '^    image: ' <<< "${out}" | grep -v "@${dig}\$")" ] || { echo "pin without the digest: ${out}"; return 1; }
    cfg="$(docker compose -f "${root}/$(_ci_variable CI_COMPOSE_FILE)" config --format json)"
    shared="$(jq -r '[.services | to_entries[] | {k: .key, i: .value.image}] | group_by(.i)
        | map(select(length > 1)) | (.[0] // []) | .[].k' <<< "${cfg}")"
    [ -n "${shared}" ] || { echo "no image shared by two compose services"; return 1; }
    while IFS= read -r k; do
        grep -qx "  ${k}:" <<< "${out}" || { echo "shared image not pinned on ${k}: ${out}"; return 1; }
    done <<< "${shared}"
    while IFS= read -r ext; do
        img="$(_ci_block_entry_field external_services "${ext}" image)"
        while IFS= read -r k; do
            [ -z "${k}" ] || ! grep -qx "  ${k}:" <<< "${out}" || { echo "third-party ${k} pinned: ${out}"; return 1; }
        done < <(jq -r --arg i "${img}" '.services | to_entries[] | select(.value.image == $i) | .key' <<< "${cfg}")
    done < <(_ci_block_keys external_services)
    miss="$(grep -m1 '^    image: ' <<< "${out}")" && miss="${miss%@*}" && miss="${miss##*/}"
    run _ci_validate_pin_override "$(grep -v "^${miss}=" <<< "${cand}")"
    _expect gap 2 "[CI-ERROR-VALIDATE-0007]" || return 1
    extra="$(_val name)"
    run _ci_validate_pin_override "${cand}${extra}=${dig}"
    _expect unpinned 0 "[CI-WARN-VALIDATE-0008] unpinned=\"${extra}\"" || return 1
}

@test "validation env: base64_32 secrets decode, no fixed secret, NATS url set" {
    # What: setup.sh base64_32 keys decode in the SOT env.
    # Why: PowerDNS rejects a non-base64 TSIG key: no AXFR.
    # From: Issue #1683 | PR #1858
    local root keys env k v d LC_ALL=C
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    keys="$(sed -nE 's/^[[:space:]]*ensure_secret_env_key ([A-Z_]+) "\$env_file" base64_32$/\1/p' "${root}/setup.sh")"
    echo "base64_32 keys: ${keys:-<none>}"
    [ -n "${keys}" ]
    env="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_validation_env)"
    for k in ${keys}; do
        v="$(sed -n "s/^${k}=//p" <<<"${env}")"
        [ -n "${v}" ] || { echo "${k}: missing from validation env"; return 1; }
        # What: count decoded bytes in a file, not a var.
        # Why: bash drops NUL; a random key may hold one.
        # From: Issue #1683 | PR #1858
        d="$(base64 -d <<<"${v}" 2>&1 > "${BATS_TEST_TMPDIR}/key.bin")" || { echo "${k}='${v}': ${d}"; return 1; }
        d="$(wc -c < "${BATS_TEST_TMPDIR}/key.bin")"
        [ "${d}" -eq 32 ] || { echo "${k}='${v}': ${d} bytes"; return 1; }
    done
    # What: the ui must advertise a NATS url to register
    # Why: without it every register answers 503
    # From: Issue #866 | PR #1858
    grep -Eq '^NATS_ADVERTISE_URL=[a-z]+://[^[:space:]]+$' <<<"${env}" \
        || { echo "no NATS_ADVERTISE_URL: $(grep '^NATS_' <<<"${env}")"; return 1; }
    # What: no setup.sh secret has a fixed value in the SOT.
    # Why: render secrets are generated; a literal leaks.
    # From: Issue #1683 | PR #1858
    keys="$(sed -nE 's/^[[:space:]]*ensure_secret_env_key ([A-Z_]+) "\$env_file" [a-z0-9_]+$/\1/p' "${root}/setup.sh")"
    [ -n "${keys}" ]
    for k in ${keys}; do
        ! grep -Eq "^  compose_validation_env:.*[[:space:]]${k}=" "${CI_MANIFEST_SOURCE}" \
            || { echo "${k}: fixed value in the SOT"; return 1; }
    done
}

# What: one flock per slot; a second holder is refused
# Why: two runs on one host must never share a slot
# From: Issue #1683 | PR #1858
@test "validate slot lock refuses a second holder of one slot" {
    local first s
    export TMPDIR="${BATS_TEST_TMPDIR}"
    s="$(_ci_validate_subnet "$(_val name)")" || { echo "slot: ${s}"; return 1; }
    first="$(_ci_validate_slot_lock "${s}")" || { echo "first holder failed"; return 1; }
    run _ci_validate_slot_lock "${s}"
    _ci_validate_release "${first}"
    _expect second-holder 1 - || return 1
}

# What: one seed gives one slot inside the SOT pool
# Why: the slot is reproducible and never leaves the pool
# From: Issue #1683 | PR #1858
@test "validate subnet is deterministic and inside the SOT pool" {
    local a b seed n max rid pool slot plen o1 o2 o3 o4 pnet anet
    max="$(_ci_variable CI_VALIDATE_MAX_SLOTS)" || { echo "max: ${max}"; return 1; }
    pool="$(_ci_variable CI_VALIDATE_SUBNET_POOL)" || { echo "pool: ${pool}"; return 1; }
    slot="$(_ci_variable CI_VALIDATE_SLOT_PREFIX)" || { echo "slot: ${slot}"; return 1; }
    plen="${pool#*/}"
    IFS=. read -r o1 o2 o3 o4 <<< "${pool%/*}"
    pnet=$(( ((o1 << 24) + (o2 << 16) + (o3 << 8) + o4) >> (32 - plen) ))
    rid="$(_val int 1 999999999)"
    for (( n = 1; n <= max; n++ )); do
        seed="$(_ci_validate_seed "${rid}" 1 "${n}")"
        a="$(_ci_validate_subnet "${seed}")" && b="$(_ci_validate_subnet "${seed}")" || { echo "seed ${seed}: ${a}"; return 1; }
        [ "${a}" = "${b}" ] && [ "${a#*/}" = "${slot}" ] || { echo "seed ${seed}: ${a} then ${b}"; return 1; }
        IFS=. read -r o1 o2 o3 o4 <<< "${a%/*}"
        anet=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
        [ $(( anet >> (32 - plen) )) -eq "${pnet}" ] && [ $(( anet % (1 << (32 - slot)) )) -eq 0 ] \
            || { echo "seed ${seed}: ${a} outside ${pool} or not /${slot} aligned"; return 1; }
    done
}

# What: the real compose config -> one slot split, resets
# Why: no overlap in the slot; no host port or name binds
# From: Issue #1683 | PR #1858
@test "validate net override isolates and resets services" {
    local slot cfg nx plain host out sub a b i j o1 o2 o3 o4 lo hi svc s
    local -a subs starts=() ends=()
    slot="$(_ci_validate_subnet "$(_val name)")" && cfg="$(_ci_validate_config_json)" || { echo "inputs: ${slot}"; return 1; }
    s="${slot#*/}"
    nx="$(jq '[.networks // {} | keys[] | select(. != "default")] | length' <<< "${cfg}")" \
        && plain="$(jq -r '.services | to_entries[] | select(.value.network_mode != "host") | .key' <<< "${cfg}")" \
        && host="$(jq -r '.services | to_entries[] | select(.value.network_mode == "host") | .key' <<< "${cfg}")" \
        || { echo "compose config not readable"; return 1; }
    [ "${nx}" -le 2 ] && [ -n "${plain}" ] || { echo "real compose: ${nx} extra networks, services: ${plain}"; return 1; }
    run _ci_validate_net_override "${slot}"
    _expect override 0 "networks:;default:;services:" || return 1
    out="${output}"
    mapfile -t subs <<< "$(sed -n 's/^ *- subnet: //p' <<< "${out}")"
    [ "${#subs[@]}" -eq $(( nx + 1 )) ] || { echo "subnets ${subs[*]} for ${nx} extra networks"; return 1; }
    IFS=. read -r o1 o2 o3 o4 <<< "${slot%/*}"
    lo=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 )) hi=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 + (1 << (32 - s)) ))
    for (( i = 0; i < ${#subs[@]}; i++ )); do
        sub="${subs[i]}"
        [ "${sub#*/}" -eq $(( s + (i == 0 ? 1 : 2) )) ] || { echo "prefix ${sub} at ${i}"; return 1; }
        IFS=. read -r o1 o2 o3 o4 <<< "${sub%/*}"
        a=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 )) b=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 + (1 << (32 - ${sub#*/})) ))
        (( a >= lo && b <= hi )) || { echo "${sub} outside ${slot}"; return 1; }
        for (( j = 0; j < ${#starts[@]}; j++ )); do
            (( b <= starts[j] || a >= ends[j] )) || { echo "${sub} overlaps ${subs[j]}"; return 1; }
        done
        starts+=("${a}") ends+=("${b}")
    done
    while IFS= read -r svc; do
        [[ "${out}" == *$'\n  '"${svc}"$':\n    container_name: !reset null\n    ports: !reset []'* ]] \
            || { echo "${svc}: name and ports not reset"; return 1; }
    done <<< "${plain}"
    while IFS= read -r svc; do
        [ -n "${svc}" ] || continue
        [[ "${out}" == *$'\n  '"${svc}"$':\n    network_mode: !reset null'* && "${out}" != *$'\n  '"${svc}"$':\n    container_name'* ]] \
            || { echo "${svc}: host mode not reset alone"; return 1; }
    done <<< "${host}"
}

# What: success is rc 0; a timeout prints the last error
# Why: a probe timeout must say why it never answered
# From: Issue #1683 | PR #1858
@test "validate poll returns on success and shows the last error" {
    local w
    w="$(_val name)"
    run _ci_validate_poll "$(_val int 2 4)" 0 true
    _expect success 0 "=" || return 1
    run _ci_validate_poll "$(_val int 2 4)" 0 bash -c 'echo "$1" >&2; exit 7' _ "${w}"
    _expect timeout 1 "${w}" || return 1
}

# =========================================================
# VARIABLES
# =========================================================

# What: per row: env, CI_VARIABLES and SOT -> value or id
# Why: AG-CI-006: GitHub vars arrive once as one JSON
# From: Issue #1683 | PR #1858
@test "variables get: env beats CI_VARIABLES json beats SOT" {
    local case envs name rc want keys k
    local -a ev
    local -A V=(["@NOVAR@"]="$(_val var)" ["@ENVV@"]="$(_val name)" ["@JSONV@"]="$(_val name)" ["@BAD@"]="$(_val name)")
    keys="$(_ci_block_keys ci_variables all)" || { echo "no SOT ci_variables: ${keys}"; return 1; }
    while IFS= read -r k; do
        V["@SOTV@"]="$(_ci_block_entry_field ci_variables "" "${k}")" || { echo "${k}: unreadable"; return 1; }
        [ -z "${V["@SOTV@"]}" ] || { V["@VAR@"]="${k}"; break; }
    done <<< "${keys}"
    [ -n "${V["@VAR@"]:-}" ] || { echo "no SOT ci_variables key with a value"; return 1; }
    while IFS='|' read -r case envs name rc want; do
        ev=(); [ "${envs}" = - ] || read -r -a ev <<< "$(_fill "${envs}")"
        if [ "${rc}" -eq 0 ]; then
            run --separate-stderr env -u CI_VARIABLES -u "${V["@VAR@"]}" "${ev[@]}" bash "${CI_SH}" variables get "$(_fill "${name}")"
        else
            run env -u CI_VARIABLES -u "${V["@VAR@"]}" "${ev[@]}" bash "${CI_SH}" variables get "$(_fill "${name}")"
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
sot-default|-|@VAR@|0|=@SOTV@
env-over-sot|@VAR@=@ENVV@|@VAR@|0|=@ENVV@
json-over-sot|CI_VARIABLES={"@VAR@":"@JSONV@"}|@VAR@|0|=@JSONV@
env-over-json|@VAR@=@ENVV@ CI_VARIABLES={"@VAR@":"@JSONV@"}|@VAR@|0|=@ENVV@
bad-json|CI_VARIABLES=@BAD@|@VAR@|2|[CI-ERROR-VARIABLES-0015] name="@VAR@"
no-value|-|@NOVAR@|2|[CI-ERROR-VARIABLES-0001] name="@NOVAR@"
CASES
}

# What: set-runtime secrets per config; clear removes them.
# Why: build-only secrets as 0600 mounts; values hidden.
# From: Issue #1683 | PR #1858
@test "set-runtime writes each config's secrets 0600 with values hidden; clear-runtime removes them" {
    local case mode runner url tok sched stoken hosts ca rc want present pol dir id k got
    local -A V=(
        ["@U@"]="$(_val url)" ["@RU@"]="$(_val url)" ["@T@"]="$(_val name)" ["@CA@"]="$(_val name)"
        ["@S@"]="$(_val url)" ["@ST@"]="$(_val name)" ["@H1@"]="$(_val host)" ["@H2@"]="$(_val host)" ["@BAD@"]="$(_val name)"
        ["@TCS@"]="$(_val int 1 4000000000)"
    )
    _rt_probe() {
        _cache_env_clean
        unset SCCACHE_DIST_SCHEDULER_URL SCCACHE_DIST_AUTH_TOKEN DISTCC_POTENTIAL_HOSTS PROJECT_SELFHOSTED_PROXY_CA CI_VARIABLES
        [ -z "${RT_CIV:-}" ] || export CI_VARIABLES="${RT_CIV}"
        export CI_RUNTIME_SECRET_DIR="$1" SCCACHE_REDIS_MODE="$2"
        export CI_SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE="${RT_TCS:-${V["@TCS@"]}}"
        [ "$3" = - ] || export RUNNER_ENVIRONMENT="$3"
        [ "$4" = - ] || export SCCACHE_REDIS_URL="$4"
        [ "$5" = no ] || export ACTIONS_RESULTS_URL="${V["@RU@"]}" ACTIONS_RUNTIME_TOKEN="${V["@T@"]}"
        [ "$6" = - ] || export SCCACHE_DIST_SCHEDULER_URL="$6"
        [ "$7" = - ] || export SCCACHE_DIST_AUTH_TOKEN="$7"
        [ "$8" = - ] || export DISTCC_POTENTIAL_HOSTS="$8"
        [ "$9" = - ] || export PROJECT_SELFHOSTED_PROXY_CA="$9"
        _ci_set_runtime
    }
    while IFS='|' read -r case mode runner url tok sched stoken hosts ca rc want present pol; do
        dir="$(_val path)"
        run _rt_probe "${dir}" "$(_fill "${mode}")" "${runner}" "$(_fill "${url}")" "${tok}" "$(_fill "${sched}")" \
            "$(_fill "${stoken}")" "$(_fill "${hosts}")" "$(_fill "${ca}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        for k in "${!V[@]}"; do
            [ "${k}" = @BAD@ ] || [ "${k}" = @TCS@ ] || [[ "${output}" != *"${V[${k}]}"* ]] || { echo "${case}: value of ${k} on stdout"; return 1; }
        done
        got=""
        [ ! -d "${dir}" ] || got="$(ls -A "${dir}" | sort | paste -sd' ')"
        [ "${got}" = "${present#-}" ] || { echo "${case}: files '${got}' want '${present}'"; return 1; }
        for id in ${got}; do
            [ "$(stat -c '%a' "${dir}/${id}")" = 600 ] || { echo "${case}: ${id} not 0600"; return 1; }
            [[ "${output}" == *"--secret id=${id},src=${dir}/${id}"* ]] || { echo "${case}: no --secret for ${id}"; return 1; }
        done
        [ -z "${got}" ] || [ "$(<"${dir}/sccache_policy")" = "$(_fill "${pol}")" ] || { echo "${case}: policy"; return 1; }
        [ ! -e "${dir}/sccache_redis_url" ] || [ "$(<"${dir}/sccache_redis_url")" = "${V["@U@"]}" ] || { echo "${case}: redis url"; return 1; }
        [ ! -e "${dir}/ccache_redis_url" ] || [ "$(<"${dir}/ccache_redis_url")" = "${V["@U@"]}" ] || { echo "${case}: ccache url"; return 1; }
        [ ! -e "${dir}/sccache_gha" ] || [ "$(<"${dir}/sccache_gha")" = "ACTIONS_RESULTS_URL=${V["@RU@"]}"$'\n'"ACTIONS_RUNTIME_TOKEN=${V["@T@"]}" ] \
            || { echo "${case}: gha tokens"; return 1; }
        [ ! -e "${dir}/project_selfhosted_proxy_ca" ] || [ "$(<"${dir}/project_selfhosted_proxy_ca")" = "${V["@CA@"]}" ] || { echo "${case}: CA"; return 1; }
        [ ! -e "${dir}/distcc_potential_hosts" ] || [ "$(<"${dir}/distcc_potential_hosts")" = "$(_fill "${hosts}")" ] || { echo "${case}: hosts"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qF "\"${V["@S@"]}\"" "${dir}/sccache_dist_config" || { echo "${case}: scheduler"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qF "\"${V["@ST@"]}\"" "${dir}/sccache_dist_config" || { echo "${case}: dist token"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qxF "toolchain_cache_size = ${V["@TCS@"]}" "${dir}/sccache_dist_config" \
            || { echo "${case}: toolchain cache size"; return 1; }
    done <<'CASES'
bad-mode|@BAD@|github-hosted|-|yes|-|-|-|-|2|[CI-ERROR-VARIABLES-0010]|-|-
sched-no-token|optional|github-hosted|-|no|@S@|-|-|-|2|[CI-ERROR-VARIABLES-0011]|-|-
token-no-sched|optional|github-hosted|-|no|-|@ST@|-|-|2|[CI-ERROR-VARIABLES-0017]|-|-
self-required-no-url|required|self-hosted|-|yes|-|-|-|-|2|[CI-ERROR-VARIABLES-0012]|-|-
hosted-required-no-tokens|required|github-hosted|@U@|no|-|-|-|-|2|[CI-ERROR-CACHE-0007]|-|-
no-pump-host|off|github-hosted|-|no|-|-|@H1@ @H2@|-|2|[CI-ERROR-VARIABLES-0013]|-|-
self-full|required|self-hosted|@U@|yes|@S@|@ST@|@H1@,cpp @H2@|@CA@|0|-|ccache_redis_url distcc_potential_hosts project_selfhosted_proxy_ca sccache_dist_config sccache_gha sccache_policy sccache_redis_url|required redis,gha
hosted-gha|required|github-hosted|@U@|yes|-|-|-|-|0|-|sccache_gha sccache_policy|required gha
optional-local|optional|github-hosted|-|no|-|-|-|-|0|-|sccache_policy|optional -
off|off|self-hosted|@U@|yes|@S@|@ST@|-|@CA@|0|-|project_selfhosted_proxy_ca sccache_policy|off -
CASES
    dir="$(_val path)"
    : > "${dir}"
    run _rt_probe "${dir}/$(_val name)" optional github-hosted - no - - - -
    _expect mkdir-fails 2 "[CI-ERROR-VARIABLES-0019];raw:" || return 1
    dir="$(_val path)"
    mkdir -p "${dir}/sccache_dist_config"
    run _rt_probe "${dir}" optional github-hosted - no "${V["@S@"]}" "${V["@ST@"]}" - -
    _expect dist-write-fails 2 "[CI-ERROR-VARIABLES-0020];raw:" || return 1
    run _ci_emit_secret_ref "${dir}" "$(_val name)"
    _expect unknown-id 2 "[CI-ERROR-VARIABLES-0014]" || return 1
    dir="$(_val path)"
    RT_TCS="$(_val name)" run _rt_probe "${dir}" optional github-hosted - no "${V["@S@"]}" "${V["@ST@"]}" - -
    _expect bad-size 2 "[CI-ERROR-VARIABLES-0021]" || return 1
    [ ! -e "${dir}" ] || { echo "bad-size: ${dir} written"; return 1; }
    dir="$(_val path)"
    RT_CIV="$(printf '{"SCCACHE_DIST_SCHEDULER_URL":"%s","DISTCC_POTENTIAL_HOSTS":"%s,cpp"}' "${V["@S@"]}" "${V["@H1@"]}")" \
        run _rt_probe "${dir}" optional github-hosted - no - "${V["@ST@"]}" - -
    _expect ci-variables 0 - || return 1
    grep -qF "\"${V["@S@"]}\"" "${dir}/sccache_dist_config" || { echo "ci-variables: scheduler"; return 1; }
    [ "$(<"${dir}/distcc_potential_hosts")" = "${V["@H1@"]},cpp" ] || { echo "ci-variables: hosts"; return 1; }
    dir="$(_val path)"
    run _rt_probe "${dir}" optional github-hosted - no - - - -
    CI_RUNTIME_SECRET_DIR="${dir}" run bash "${CI_SH}" variables clear-runtime
    _expect clear 0 "clear-runtime result=cleared" || return 1
    [ ! -e "${dir}" ] || { echo "clear: ${dir} left"; return 1; }
}

# =========================================================
# BUILD-ARGS EMISSION (SOT -> --build-arg)
# =========================================================

# What: real SOT targets: digest-pinned alpine, filled args.
# Why: SOT owns every value; build-args only maps it.
# From: Issue #1683 | PR #1858
@test "build-args: real SOT targets give pinned, filled arguments" {
    local s apk="" tool pc sp verify w case target fmt plat pre want absent
    local -A N=()
    for s in $(ci_services); do
        [ "$(ci_service_field "${s}" build_type)" != apk ] || { apk="${s}"; break; }
    done
    tool="$(_ci_block_keys build_toolchain | awk 'NR == 1')"
    pc="$(_pin_consumer)" sp="$(_ci_build_matrix_platforms | awk 'NR == 1')"
    [ -n "${apk}" ] && [ -n "${tool}" ] && [ -n "${pc}" ] && [ -n "${sp}" ] || { echo "inputs: ${apk} ${tool} ${pc} ${sp}"; return 1; }
    run --separate-stderr bash "${CI_SH}" version verify
    [ "${status}" -eq 0 ] || { echo "version verify rc ${status}: ${output} ${stderr}"; return 1; }
    verify="${output}"
    for w in VERSION ARCH SHA256; do
        N[${w}]="$(sed -n "s/^key=$(_pin_dep)\.consumer\.\([A-Z0-9_]*_${w}\) shape=bare\$/\1/p" <<< "${verify}" | awk 'NR == 1')"
        [ -n "${N[${w}]}" ] || { echo "no ${w} ARG in: ${verify}"; return 1; }
    done
    while IFS='|' read -r case target fmt plat want absent; do
        target="${target/@APK@/${apk}}" target="${target/@TOOL@/${tool}}" target="${target/@PC@/${pc}}"
        plat="${plat/@SP@/${sp}}"
        want="${want/@ARCH@/${N[ARCH]}}" want="${want/@SHA@/${N[SHA256]}}" want="${want/@VER@/${N[VERSION]}}"
        absent="${absent/@ARCH@/${N[ARCH]}}"
        pre="--build-arg "; [ "${fmt}" != --bare ] || pre=""
        run --separate-stderr bash "${CI_SH}" build-args "${target}" "${fmt}" "${plat}"
        [ "${status}" -eq 0 ] || { echo "${case}: rc ${status}: ${output} ${stderr}"; return 1; }
        [ -z "$(grep -vE "^${pre}[A-Z][A-Z0-9_]*=.+\$" <<< "${output}")" ] || { echo "${case}: malformed line: ${output}"; return 1; }
        grep -qE "^${pre}ALPINE_IMAGE=[^ ]+@sha256:[0-9a-f]{64}\$" <<< "${output}" || { echo "${case}: alpine not pinned: ${output}"; return 1; }
        [[ "${output}" != *@ALPINE_BRANCH@* ]] || { echo "${case}: branch placeholder left: ${output}"; return 1; }
        for w in ${want}; do grep -qE "^${pre}${w}" <<< "${output}" || { echo "${case}: no ${w}: ${output}"; return 1; }; done
        [ "${absent}" = - ] && continue
        for w in ${absent}; do ! grep -q "^${pre}${w}=" <<< "${output}" || { echo "${case}: has ${w}: ${output}"; return 1; }; done
    done <<'CASES'
apk-flags|@APK@|||APK_PACKAGES=.+|BUILD_TOOLS_IMAGE
apk-bare|@APK@|--bare||APK_PACKAGES=.+|BUILD_TOOLS_IMAGE
toolchain|@TOOL@|||APK_PACKAGES=.+|BUILD_TOOLS_IMAGE
pin-no-platform|@PC@|||@VER@=.+|@ARCH@
pin-platform|@PC@||@SP@|@ARCH@=.+ @SHA@=[0-9a-f]{64}$|-
CASES
}

# What: OCI labels of a real service from SOT and run env
# Why: build provenance is set once per image by ci.sh
# From: Issue #1683 | PR #1858
@test "oci labels: provenance from the SOT and the run env" {
    local want got fb base
    local -A V=(["@OWN@"]="$(_val name)" ["@REPO@"]="$(_val name)" ["@SRV@"]="$(_val url)" ["@SHA@"]="$(_val sha)")
    V["@S@"]="$(ci_services | awk 'NR == 1')"
    fb="$(_ci_required_field "${V["@S@"]}" final_base)" && base="$(_ci_block_entry_field base_images "" "${fb}")" \
        && V["@LIC@"]="$(_ci_release_value license)" || { echo "SOT inputs: ${V[*]} ${fb} ${base}"; return 1; }
    [ -n "${V["@S@"]}" ] && [ -n "${base}" ] && [ -n "${V["@LIC@"]}" ] || { echo "SOT inputs: ${V[*]} ${base}"; return 1; }
    V["@BIMG@"]="${base%@*}" V["@BDIG@"]="${base#*@}"
    want="$(_fill "$(printf 'org.opencontainers.image.%s\n' 'revision=@SHA@' 'version=@SHA@' \
        'source=@SRV@/@OWN@/@REPO@' 'url=@SRV@/@OWN@/@REPO@' 'documentation=@SRV@/@OWN@/@REPO@' 'licenses=@LIC@' \
        'vendor=@OWN@' 'title=@S@' 'description=@REPO@ @S@ image' 'base.name=@BIMG@' 'base.digest=@BDIG@')")"
    GITHUB_SHA="${V["@SHA@"]}" GITHUB_SERVER_URL="${V["@SRV@"]}" GITHUB_REPOSITORY="${V["@OWN@"]}/${V["@REPO@"]}" \
        run _ci_oci_labels "${V["@S@"]}"
    _expect labels 0 - || return 1
    [[ "${output%%$'\n'*}" =~ ^org\.opencontainers\.image\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || { echo "created: ${output}"; return 1; }
    got="${output#*$'\n'}"
    [ "${got}" = "${want}" ] || { echo "labels: ${got}"; echo "want: ${want}"; return 1; }
    GITHUB_SHA='' GITHUB_SERVER_URL="${V["@SRV@"]}" GITHUB_REPOSITORY="${V["@OWN@"]}/${V["@REPO@"]}" \
        run _ci_oci_labels "${V["@S@"]}"
    _expect no-sha 0 - || return 1
    [[ "${output}" != *"image.revision="* && "${output}" != *"image.version="* ]] || { echo "no-sha: ${output}"; return 1; }
}

# What: no repo fails coded and a gone path is noted
# Why: an empty scan must never pass a check as clean
# From: Issue #1683 | PR #1858
@test "scan file set: no repo fails closed, a gone path is skipped" {
    local a g
    local -a ov=()
    a="${CI_SH}" g="${BATS_TEST_TMPDIR}/$(_val name)"
    cd "${BATS_TEST_TMPDIR}" || return 1
    export GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR%/*}"
    run _ci_scan_files out ov
    _expect no-repo 2 "[CI-ERROR-CHECK-0071] site=\"scan-files\";not a git repository" || return 1
    ov=("${a}" "${g}")
    run eval '_ci_scan_files out ov && printf "out=%s\n" "${out[@]}"'
    _expect gone 0 "[CI-NOTICE-CHECK-0070] skipped=1;out=${a}" || return 1
    [[ "${output}" != *"out=${g}"* ]] || { echo "gone: in ${ov[*]}: ${output}"; return 1; }
    ov=("${a}")
    run eval '_ci_scan_files out ov && printf "out=%s\n" "${out[@]}"'
    _expect present 0 "out=${a}" || return 1
    [[ "${output}" != *CHECK-0070* ]] || { echo "present: in ${ov[*]}: ${output}"; return 1; }
}

# What: per row: title and env -> verdict and ids
# Why: AG-GH-018 owns format SOT sets and the modes
# From: Issue #1683 | PR #1858
@test "check pr-title: SOT types and scopes, warn default, block and draft" {
    local case title envs rc want
    local -a ev
    local -A V=(["@BT@"]="$(_val name | tr '0-9' 'a-j')" ["@BS@"]="$(_val name)" ["@W@"]="$(_val name)")
    V["@T@"]="$(_ci_block_entry_list pr_policy "" title_types | awk 'NR == 1')"
    V["@S@"]="$(ci_build_targets | awk 'NR == 1')"
    V["@E@"]="$(_ci_block_keys external_services | awk 'NR == 1')"
    V["@X@"]="$(_ci_block_entry_list pr_policy "" title_scopes_extra | awk 'NR == 1')"
    V["@A@"]="$(_ci_block_entry_list pr_policy "" check_exempt_authors | awk 'NR == 1')"
    [ -n "${V["@T@"]}" ] && [ -n "${V["@S@"]}" ] && [ -n "${V["@E@"]}" ] && [ -n "${V["@X@"]}" ] && [ -n "${V["@A@"]}" ] \
        || { echo "SOT inputs: ${V[*]}"; return 1; }
    while IFS='|' read -r case title envs rc want; do
        ev=()
        [ "${envs}" = - ] || read -r -a ev <<< "$(_fill "${envs}")"
        run env -u PR_TITLE_LINT_MODE -u PR_DRAFT -u PR_AUTHOR -u CI_VARIABLES "PR_TITLE=$(_fill "${title}")" "${ev[@]}" \
            bash "${CI_SH}" check pr-title
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
target|@T@(@S@): @W@|-|0|pr-title=ok
target-breaking|@T@(@S@)!: @W@|-|0|pr-title=ok
external|@T@(@E@): @W@|-|0|pr-title=ok
extra|@T@(@X@): @W@|-|0|pr-title=ok
no-scope|@T@: @W@|-|0|pr-title=ok
no-scope-breaking|@T@!: @W@|-|0|pr-title=ok
type-warn-default|@BT@(@S@): @W@|-|0|[CI-ERROR-CHECK-0086];type '@BT@' not allowed;pr-title=warn
type-block|@BT@(@S@): @W@|PR_TITLE_LINT_MODE=block|1|[CI-ERROR-CHECK-0087] reason="PR title convention";type '@BT@' not allowed
type-draft|@BT@(@S@): @W@|PR_TITLE_LINT_MODE=block PR_DRAFT=true|0|[CI-WARN-CHECK-0013];type '@BT@' not allowed;pr-title=warn-draft
scope-block|@T@(@BS@): @W@|PR_TITLE_LINT_MODE=block|1|[CI-ERROR-CHECK-0087];scope '@BS@' not allowed
grammar-block|@W@|PR_TITLE_LINT_MODE=block|1|[CI-ERROR-CHECK-0087];not a Conventional-Commit title
empty-subject|@T@(@S@):  |PR_TITLE_LINT_MODE=block|1|[CI-ERROR-CHECK-0087];empty subject
exempt|@W@|PR_TITLE_LINT_MODE=block PR_AUTHOR=@A@|0|pr-title=skip author="@A@"
CASES
}

# What: per row: PR body on the real template -> verdict
# Why: AG-GH-010: every real template section is filled
# From: Issue #1683 | PR #1858
@test "check pr-template: every real template section filled, one box marked" {
    local case envs rc want h heads body full="" nl=$'\n' fence='```'
    local -a ev
    local -A V=(["@W@"]="$(_val name)")
    V["@CB@"]="$(_ci_block_entry_field pr_policy "" checkbox_section)"
    V["@EX@"]="$(_ci_block_entry_list pr_policy "" check_exempt_authors | awk 'NR == 1')"
    heads="$(grep '^## ' "$(_ci_repo_path CI_PR_TEMPLATE)" | sed 's/^## //')" || { echo "no template headings"; return 1; }
    V["@H1@"]="$(grep -vxF -- "${V["@CB@"]}" <<< "${heads}" | awk 'NR == 1')"
    grep -qxF -- "${V["@CB@"]}" <<< "${heads}" && [ -n "${V["@H1@"]}" ] && [ -n "${V["@EX@"]}" ] \
        || { echo "inputs: ${V[*]} | ${heads}"; return 1; }
    while IFS= read -r h; do
        if [ "${h}" = "${V["@CB@"]}" ]; then full+="## ${h}${nl}- [x] ${V["@W@"]}${nl}"; else full+="## ${h}${nl}${V["@W@"]}${nl}"; fi
    done <<< "${heads}"
    local sec1="## ${V["@H1@"]}${nl}${V["@W@"]}${nl}"
    while IFS='|' read -r case envs rc want; do
        case "${case}" in
            filled) body="${full}" ;;
            heading-missing|draft) body="${full/"${sec1}"/}" ;;
            heading-twice) body="${full}${sec1}" ;;
            placeholder-only) body="${full/"${sec1}"/"## ${V["@H1@"]}${nl}<!-- ${V["@W@"]} -->${nl}"}" ;;
            fences-only) body="${full/"${sec1}"/"## ${V["@H1@"]}${nl}${fence}${nl}${fence}${nl}"}" ;;
            box-unmarked) body="${full/"- [x] ${V["@W@"]}"/"- [ ] ${V["@W@"]}"}" ;;
            *) body="" ;;
        esac
        ev=()
        [ "${envs}" = - ] || read -r -a ev <<< "$(_fill "${envs}")"
        run env -u PR_DRAFT -u PR_AUTHOR -u CI_VARIABLES "PR_BODY=${body}" "${ev[@]}" bash "${CI_SH}" check pr-template
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
filled|-|0|pr-template=ok
heading-missing|-|1|[CI-ERROR-CHECK-0089];@H1@: heading not found
heading-twice|-|1|[CI-ERROR-CHECK-0089];@H1@: heading appears 2 times
placeholder-only|-|1|[CI-ERROR-CHECK-0089];@H1@: empty (only template placeholder left)
fences-only|-|1|[CI-ERROR-CHECK-0089];@H1@: empty (only template placeholder left)
box-unmarked|-|1|[CI-ERROR-CHECK-0089];@CB@: no checkbox marked
draft|PR_DRAFT=true|0|[CI-ERROR-CHECK-0088];pr-template=warn-draft
exempt|PR_AUTHOR=@EX@|0|pr-template=skip author="@EX@"
CASES
}

# What: per row: PR markdown -> stripped text or the section
# Why: notes, template and close checks parse PR text alike
# From: Issue #1496 | PR #1858
@test "pr markdown: comments strip, a section ends at any real heading" {
    local case fn text heading want
    while IFS='|' read -r case fn text heading want; do
        case "${fn}" in
            strip) run _ci_md_strip_comments "$(printf '%b' "${text}")" ;;
            section) run _ci_pr_section "$(printf '%b' "${text}")" "${heading}" ;;
        esac
        _expect "${case}" 0 "=$(printf '%b' "${want}")" || return 1
    done <<'CASES'
strip-inline-and-block|strip|a <!-- x --> b\nkeep <!-- start\nhidden\nend --> tail|-|a  b\nkeep \n\n tail
section-exact|section|## Summary\nx\n## Linked Issues  \r\nCloses #1\n```bash\n# not a heading\n```\n### Notes\ncloses #2\n## Linked Issuesx\n|Linked Issues|1\nCloses #1\n```bash\n# not a heading\n```
section-twice|section|## Linked Issues\na\n## Linked Issues\nb|Linked Issues|2\na
section-level-3|section|### Linked Issues\na|Linked Issues|0
CASES
}

# What: per row: uses ref -> external (pin) or local
# Why: AG-CI-001 pins every external action by full SHA
# From: Issue #1683 | PR #1858
@test "action ref is external unless local, docker, or this repo" {
    local case ref rc
    local -A V=(["@O@"]="$(_val name)" ["@R@"]="$(_val name)" ["@X@"]="$(_val name)" ["@P@"]="$(_val name)" ["@SHA@"]="$(_val sha)")
    V["@UO@"]="${V["@O@"]^^}" V["@UR@"]="${V["@R@"]^^}"
    while IFS='|' read -r case ref rc; do
        GITHUB_REPOSITORY="${V["@O@"]}/${V["@R@"]}" run _ci_action_ref_is_external "$(_fill "${ref}")"
        _expect "${case}" "${rc}" - || return 1
    done <<'CASES'
relative|./@P@/@X@@@SHA@|1
docker|docker://@P@@@SHA@|1
own-subpath|@O@/@R@/@P@@@SHA@|1
own-other-case|@UO@/@UR@/@P@@@SHA@|1
no-ref|@X@/@P@|1
other-owner|@X@/@P@@@SHA@|0
same-owner-other-repo|@O@/@X@/@P@@@SHA@|0
own-name-prefix-repo|@O@/@R@@X@/@P@@@SHA@|0
CASES
}

# What: changed file -> skip only for a shell comment.
# Why: arch doc Test B/C/D; unproven changes run it.
# From: Issue #1683 | PR #1858
@test "ci-bats gate: only a shell comment change skips the suite" {
    local r base head case path body want id
    local -A V=(
        ["@B@"]="$(_val name).bats" ["@L@"]="$(_val name).sh" ["@N@"]="$(_val name).md" ["@NEW@"]="$(_val name).sh"
        ["@Y@"]="$(_val name).yml" ["@RS@"]="$(_val name).rs" ["@C1@"]="$(_val name)" ["@C2@"]="$(_val name)"
        ["@FN@"]="$(_val name)" ["@E1@"]="$(_val name)" ["@E2@"]="$(_val name)" ["@D@"]="$(_val name)"
        ["@H1@"]="$(_val name)" ["@H2@"]="$(_val name)" ["@MAIL@"]="$(_val name)@$(_val host)" ["@WHO@"]="$(_val name)"
        ["@U@"]="$(_val name).sh"
    )
    V["@README@"]="$(_ci_variable CI_README)"
    run _ci_check_ci_bats "${V["@N@"]}"
    _expect nested 0 '=ci-bats=NOT-RUN reason="already inside a bats run; no nested suite"' || return 1
    r="$(_val path)"
    git init -q "${r}"
    mkdir -p "$(dirname "${r}/${V["@README@"]}")"
    _fill "$(printf '%s\n' '@test "@C1@" {' '  # @C1@' '  true' '}')" > "${r}/${V["@B@"]}"
    _fill "$(printf '%s\n' '@FN@() {' '  # @C1@' '  echo @E1@' '}' 'cat <<@D@' '# @H1@' '@D@')" > "${r}/${V["@L@"]}"
    _fill "$(printf '%s\n' '// @C1@' 'fn main() {}')" > "${r}/${V["@RS@"]}"
    _fill "$(printf '%s\n' 'echo "@E1@' '# @C1@')" > "${r}/${V["@U@"]}"
    printf '%s\n' "${V["@C1@"]}" > "${r}/${V["@N@"]}"
    printf '%s\n' "${V["@C1@"]}" > "${r}/${V["@README@"]}"
    git -C "${r}" add -A
    git -C "${r}" -c user.email="${V["@MAIL@"]}" -c user.name="${V["@WHO@"]}" commit -qm base
    base="$(git -C "${r}" rev-parse HEAD)"
    while IFS='|' read -r case path body want id; do
        git -C "${r}" checkout -q "${base}"
        printf '%b' "$(_fill "${body}")" > "${r}/$(_fill "${path}")"
        git -C "${r}" add -A
        git -C "${r}" -c user.email="${V["@MAIL@"]}" -c user.name="${V["@WHO@"]}" commit -qm "${case}"
        head="$(git -C "${r}" rev-parse HEAD)"
        CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push BEFORE_SHA="${base}" GITHUB_SHA="${head}" \
            run _ci_test_identity_gate "$(_fill "${path}")"
        _expect "${case}" 0 "${id}" || return 1
        [ "${lines[${#lines[@]}-1]}" = "${want}" ] || { echo "${case} want ${want}: ${output}"; return 1; }
    done <<'CASES'
bats-comment|@B@|@test "@C1@" {\n  # @C2@\n  true\n}\n|skip|-
sh-comment|@L@|@FN@() {\n  # @C2@\n\n  echo @E1@\n}\ncat <<@D@\n# @H1@\n@D@\n|skip|-
sh-code|@L@|@FN@() {\n  # @C1@\n  echo @E2@\n}\ncat <<@D@\n# @H1@\n@D@\n|run|[CI-INFO-TESTID-0007]
heredoc-body|@L@|@FN@() {\n  # @C1@\n  echo @E1@\n}\ncat <<@D@\n# @H2@\n@D@\n|run|[CI-INFO-TESTID-0007]
unsafe-both|@U@|echo "@E1@\n# @C2@\n|run|[CI-INFO-TESTID-0003]
plain-doc|@N@|@C2@\n|skip|-
sot-named-doc|@README@|@C2@\n|run|[CI-INFO-TESTID-0005]
new-file|@NEW@|echo @E1@\n|run|[CI-INFO-TESTID-0002]
other-file|@Y@|@C1@: @E1@\n|run|[CI-INFO-TESTID-0006]
rust-comment|@RS@|// @C2@\nfn main() {}\n|run|[CI-INFO-TESTID-0006]
CASES
    CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push BEFORE_SHA='' GITHUB_SHA="${head}" run _ci_test_identity_gate "${V["@B@"]}"
    _expect no-base 0 '[CI-INFO-TESTID-0004]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-base: ${output}"; return 1; }
    run _ci_test_identity_gate
    _expect no-files 0 '[CI-INFO-TESTID-0001]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-files: ${output}"; return 1; }
}

@test "docs-only holds only for docs no SOT key names" {
    # What: per row: changed paths -> docs-only rc, reason.
    # Why: docs are NOOP (§63) unless the SOT reads them.
    # From: Issue #1683 | PR #1858
    local m case sot paths rc want
    local -a av
    local -A V=(
        ["@VAR@"]="$(_val var)" ["@D@"]="$(_val name)" ["@NAMED@"]="$(_val name)" ["@STATE@"]="$(_val name)"
        ["@GOV@"]="$(_val name)" ["@X@"]="$(_val name)" ["@Y@"]="$(_val name)" ["@C@"]="$(_val name)"
    )
    m="$(_val path)"
    _fill "$(printf '%s\n' 'ci_variables:' '  @VAR@: @D@/@NAMED@.md' '  CI_DOCS_DIR: @D@' 'release:' \
        '  validation_state: @D@/@STATE@' '  governance_paths: [@GOV@.md]')" > "${m}"
    while IFS='|' read -r case sot paths rc want; do
        av=(); [ "${paths}" = - ] || read -r -a av <<< "$(_fill "${paths}")"
        [ "${sot}" = m ] && sot="${m}" || sot="$(_val path)"
        CI_MANIFEST="${sot}" run _ci_docs_only "${av[@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
markdown|m|@X@.md|0|-
docs-dir|m|@D@/@Y@ @X@.md|0|-
mixed|m|@X@.md @C@/@Y@|1|-
no-paths|m|-|1|-
dir-prefix-only|m|@D@@Y@/@X@|1|-
sot-named-doc|m|@X@.md @D@/@NAMED@.md|1|[CI-INFO-PLAN-0007] path="@D@/@NAMED@.md"
validation-state|m|@D@/@STATE@|1|[CI-INFO-PLAN-0007] path="@D@/@STATE@"
governance|m|@GOV@.md|1|[CI-INFO-PLAN-0007] path="@GOV@.md"
no-sot|x|@X@.md|2|[CI-ERROR-CORE-010
CASES
    # What: plan-matrix stops rc 2 when docs-only fails.
    # Why: an unread SOT must never pass as "not docs-only".
    # From: Issue #1683 | PR #1858
    local gho
    gho="$(_val path)" m="$(_val path)"
    : > "${gho}"
    grep -v '^  CI_DOCS_DIR:' "${CI_MANIFEST}" > "${m}"
    GITHUB_OUTPUT="${gho}" CI_MANIFEST="${m}" run bash "${CI_SH}" plan-matrix "$(_val name).md"
    _expect plan-matrix-undecided 2 '[CI-ERROR-VARIABLES-0001] name="CI_DOCS_DIR"' || return 1
    [ ! -s "${gho}" ] || { echo "plan-matrix wrote output: $(cat "${gho}")"; return 1; }
}

# What: per row: PR body -> clean or the governance gap
# Why: AG-GH-010 and 011: real body text and open Refs
# From: Issue #1683 | PR #1858
@test "check governance-guards: partial scope needs an open Refs issue, a body must be real text" {
    local case body rc want
    local -A V=(["@W@"]="$(_val name)")
    while IFS='|' read -r case body rc want; do
        run env -u PR_TITLE -u CI_VARIABLES "PR_BODY=$(printf '%b' "$(_fill "${body}")")" bash "${CI_SH}" check governance-guards
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
plain|@W@|0|governance-guards=clean
negated|No TODO items left and nothing deferred here @W@|0|governance-guards=clean
partial-no-refs|This is a partial fix @W@|1|[CI-ERROR-CHECK-0018];partial-scope language without an open Refs
upload-path|@/tmp/@W@.txt|1|[CI-ERROR-CHECK-0018];literal @/tmp/... upload path
json-quoted|"## @W@\\n@W@"|1|[CI-ERROR-CHECK-0018];JSON-quoted Markdown
json-double|"## @W@\\\\n@W@"|1|[CI-ERROR-CHECK-0018];JSON-quoted Markdown
CASES
}

@test "migrate_env_for_update repairs every empty required key" {
    _stand_ins || return 1
    # What: every SOT repair key is refilled when emptied
    # Why: empty required keys break the stack (AG-OP-007)
    # From: Issue #1683 | PR #1858
    local root keys key d
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    keys="$(grep -E '^  setup_required_repairs:' "${root}/.github/yaml/build-manifest.yml" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[],')"
    [ -n "${keys}" ] || { echo "no repair keys in the SOT"; return 1; }
    _load_setup_sh "${root}"
    for key in ${keys}; do
        d="${BATS_TEST_TMPDIR}/req-${key}/deploy/prod"
        _converged_install "${d}" || return 1
        set_env_key "${key}" "" "${d}/.env"
        cp "${d}/.env" "${d}/.env.before"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
        # What: a pin without a tag is refused, not guessed
        # Why: only the operator picks an immutable tag
        # From: Issue #1683 | PR #1858
        if [ "${key}" = LANCACHE_IMAGE_TAG ] && [ "${status}" -ne 0 ]; then
            [ "${status}" -eq 1 ] && [[ "${output}" == *"requires LANCACHE_IMAGE_TAG"* ]] && cmp -s "${d}/.env.before" "${d}/.env" \
                || { echo "pinned without tag: ${output}"; return 1; }
            continue
        fi
        [ "${status}" -eq 0 ] && [ -n "$(get_env_var "${key}" "${d}/.env")" ] \
            || { echo "${key} not repaired: ${output}"; echo "before:"; cat "${d}/.env.before"; return 1; }
    done
}

@test "migrate_env_for_update derives CACHE_MAX_SIZE from CACHE_MAX_GB" {
    _stand_ins || return 1
    # What: empty CACHE_MAX_SIZE comes from CACHE_MAX_GB
    # Why: reuse the operator's size, not the default
    # From: Issue #1683 | PR #1858
    local root d gb
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${BATS_TEST_TMPDIR}/cms/deploy/prod"
    _converged_install "${d}" || return 1
    gb="$(( $(get_env_var CACHE_MAX_GB "${d}/.env") * 3 ))"
    set_env_key CACHE_MAX_GB "${gb}" "${d}/.env"
    set_env_key CACHE_MAX_SIZE "" "${d}/.env"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [[ "$(get_env_var CACHE_MAX_SIZE "${d}/.env")" == "${gb}"[!0-9]* ]] \
        || { echo "size: $(get_env_var CACHE_MAX_SIZE "${d}/.env") ${output}"; return 1; }
}

@test "validate_ui_session_ttl_seconds rejects invalid and accepts valid" {
    # What: TTL positive int within max.
    # Why: a bad TTL would be written or reused unchecked.
    # From: Issue #1683 | PR #1858
    local repo_root
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${repo_root}"
    run validate_ui_session_ttl_seconds abc src
    [[ "${output}" == *"unsigned integer"* ]]
    run validate_ui_session_ttl_seconds 0 src
    [[ "${output}" == *"greater than zero"* ]]
    run validate_ui_session_ttl_seconds 86400 src
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# What: per row: changed files, labels -> clean, note, warn
# Why: CHANGELOG.md is written by the release flow only
# From: Issue #893 | PR #1858
@test "check changelog-direct-edit warns on a direct edit unless labelled" {
    local case files labels rc want
    local -a argv
    local -A V=(["@F@"]="$(_ci_variable CI_CHANGELOG)" ["@O@"]="$(_val name)")
    V["@L@"]="$(_ci_block_entry_field release_notes "" changelog_edit_label)"
    [ -n "${V["@L@"]}" ] || { echo "no SOT release_notes.changelog_edit_label"; return 1; }
    while IFS='|' read -r case files labels rc want; do
        read -r -a argv <<< "$(_fill "${files}")"
        PR_LABELS_JSON="$(_fill "${labels}")" run bash "${CI_SH}" check changelog-direct-edit "${argv[@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
untouched|@O@.txt @O@.md|[]|0|changelog-direct-edit=clean
direct-edit|@O@.txt @F@|["@O@"]|0|[CI-INFO-CHECK-0116];warn-only;changelog-direct-edit=warn
labelled|@F@|["@O@","@L@"]|0|[CI-INFO-CHECK-0115];label="@L@";changelog-direct-edit=warn
labels-unreadable|@F@|{broken|2|[CI-ERROR-CHECK-0112]
CASES
}

# =========================================================
# RETRY ENGINE (_ci_retry) + BUILD != PUBLISH INVARIANT
# =========================================================

# What: mktemp -d under /var/tmp, tracked for teardown.
# Why: cache-dir tests must pass under any ambient TMPDIR.
# From: Issue #1683 | PR #1858
_trivy_var_tmp_dir() {
    local d
    d="$(mktemp -d "/var/tmp/ci-bats-trivy.XXXXXX")" || return 1
    printf '%s\n' "${d}" >> "${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    printf '%s\n' "${d}"
}

@test "trivy cache dir: writable probe, shared first, disk fallback, never tmpfs" {
    # What: probe, shared dir first, disk fallback, no tmpfs
    # Why: §41.1 one shared DB on disk and never on tmpfs
    # From: Issue #1683
    local vt
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 0 ] || { echo "writable: rc ${status}: ${output}"; return 1; }
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}/does-not-exist"
    [ "${status}" -ne 0 ] || { echo "missing dir passed: ${output}"; return 1; }
    vt="$(_trivy_var_tmp_dir)"
    mkdir -p "${vt}/shared"
    CI_TRIVY_SHARED_DIR="${vt}/shared" CI_TRIVY_FALLBACK_DIR="${vt}/fallback" run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ] && [[ "${output}" == "dir=${vt}/shared source=nfs-shared" ]] || { echo "shared: ${output}"; return 1; }
    vt="$(_trivy_var_tmp_dir)"
    CI_TRIVY_SHARED_DIR="${vt}/no-such-share" CI_TRIVY_FALLBACK_DIR="${vt}/fallback" run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ] && [[ "${output}" == *"dir=${vt}/fallback source=local-fallback"* ]] && [ -d "${vt}/fallback" ] \
        || { echo "fallback: ${output}"; return 1; }
    CI_TRIVY_SHARED_DIR="/tmp/whatever" CI_TRIVY_FALLBACK_DIR="${BATS_TEST_TMPDIR}/fallback" run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ] && [[ "${output}" == *"CI-ERROR-SCAN-0007"* ]] || { echo "tmpfs shared: ${output}"; return 1; }
    CI_TRIVY_SHARED_DIR="${BATS_TEST_TMPDIR}/no-such-share" CI_TRIVY_FALLBACK_DIR="/tmp/whatever" run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ] && [[ "${output}" == *"CI-ERROR-SCAN-0018"* ]] || { echo "tmpfs fallback: ${output}"; return 1; }
}

@test "trivy db lock: one writer, a held lock times out, ensure_fresh hard-fails" {
    # What: lock order, held lock timeout, lock dir error
    # Why: two writers must never race the same DB file
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/lockdb" order="${BATS_TEST_TMPDIR}/order" p1
    mkdir -p "${cache}"; : > "${order}"
    export CI_TRIVY_LOCK_POLL=1
    (
        _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
            'echo first-start >> "'"${order}"'"; sleep 1; echo first-end >> "'"${order}"'"'
    ) &
    p1=$!
    sleep 0.3
    _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
        'echo second-start >> "'"${order}"'"'
    wait "${p1}"
    [ "$(paste -sd' ' "${order}")" = "first-start first-end second-start" ] || { echo "order: $(cat "${order}")"; return 1; }
    cache="${BATS_TEST_TMPDIR}/heldlock"; mkdir -p "${cache}/.trivy-db-update.lock"
    run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    _expect held-lock 2 "[CI-ERROR-SCAN-0011]" || return 1
    cache="${BATS_TEST_TMPDIR}/lockedstale"; mkdir -p "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_TIMEOUT=1 CI_TRIVY_LOCK_STALE=3600 run _ci_trivy_db_ensure_fresh "${cache}"
    _expect ensure-fresh 2 "[CI-ERROR-SCAN-0012]" || return 1
    run _ci_trivy_db_lock_run "/dev/null/$(_val name)" 1 5 -- true
    _expect lock-dir 2 "[CI-ERROR-SCAN-0013]" || return 1
}

# What: one artifact state: ledger record + registry answer
# Why: the real resolver reads both; no state is injected
# From: Issue #1683 | PR #1858
_artifact() {
    local state="$1" svc="$2" plat="$3" dig="$4" id tag
    id="$(_ci_identity_for "${svc}" "${plat}")" && tag="$(_ci_image_tag "${svc}" "${plat}" "${id}")" || return 1
    case "${state}" in
        PRESENT_ACCEPTED|MISMATCH) _ci_ledger_append origin "${id}" "${svc}" "${plat}" ACCEPTED "${dig}" > /dev/null || return 1 ;;
    esac
    case "${state}" in
        PRESENT_ACCEPTED|PRODUCED_UNVERIFIED) _docker_answer " buildx imagetools inspect ${tag} --format *" 0 "${dig}" ;;
        MISMATCH) _docker_answer " buildx imagetools inspect ${tag} --format *" 0 "$(_val digest)" ;;
        MISSING_CONFIRMED) _docker_answer " buildx imagetools inspect ${tag} --format *" 1 '' "ERROR: ${tag}: not found" ;;
        UNKNOWN) _docker_answer " buildx imagetools inspect ${tag} --format *" 1 '' "denied: $(_val name)" ;;
        *) echo "_artifact: unknown state ${state}" >&2; return 1 ;;
    esac
}

# =========================================================
# VERSION MANAGEMENT
# =========================================================

# What: Copies pin consumers and release-version copies.
# Why: sync tests must never touch the real repo files.
# From: Issue #1683 | PR #1858
_version_fixture_repo() {
    local root="${CI_REPO_ROOT}" dir lock vf ws f consumers members
    dir="$(_val path)"
    lock="$(_ci_repo_path CI_CARGO_LOCK "${root}")" && vf="$(_ci_repo_path CI_VERSION_FILE "${root}")" || return 1
    ws="${lock%/*}/Cargo.toml"
    consumers="$(_ci_version_consumers | cut -d'|' -f2)" && members="$(_ci_cargo_members "${ws}")" || return 1
    for f in ${consumers} "${ws#"${root}/"}" "${lock#"${root}/"}" "${vf#"${root}/"}" $(sed 's#$#/Cargo.toml#' <<< "${members}"); do
        mkdir -p "${dir}/$(dirname "${f}")" && cp "${root}/${f}" "${dir}/${f}" || return 1
    done
    printf '%s' "${dir}"
}

@test "version, verify and audit give one output and rc" {
    _stand_ins || return 1
    # What: per state: the 3 names agree on output and rc.
    # Why: one pin-drift owner; no second walk of the SOT.
    # From: Issue #1683 | PR #1858
    local root vf state sub want_status want
    for state in clean drifted; do
        root="$(_version_fixture_repo)" || return 1
        if [ "${state}" = drifted ]; then
            vf="$(_ci_repo_path CI_VERSION_FILE "${root}")" && printf '%s\n' "$(_val semver)" > "${vf}"
        fi
        CI_REPO_ROOT="${root}" run bash "${CI_SH}" version
        want_status="${status}" want="${output}"
        case "${state}" in
            clean) [ "${want_status}" -eq 0 ] ;;
            drifted) [ "${want_status}" -eq 1 ] && [[ "${want}" == *"[CI-ERROR-VERSION-0024]"* ]] ;;
        esac || { echo "${state}: rc ${want_status}: ${want}"; return 1; }
        for sub in verify audit; do
            CI_REPO_ROOT="${root}" run bash "${CI_SH}" version "${sub}"
            [ "${status}" -eq "${want_status}" ] && [ "${output}" = "${want}" ] \
                || { echo "${state}/${sub}: rc ${status}: ${output}"; return 1; }
        done
    done
}

# =========================================================
# HISTORICAL REGRESSIONS
# =========================================================

# What: a prod install whose .env setup.sh converged
# Why: tests start from setup.sh's own output, not a copy
# From: Issue #1683 | PR #1858
_converged_install() {
    _prod_install "$1" || return 1
    export CONV="$1"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] || { echo "converge $1: ${output}"; return 1; }
}

# What: an old-shape .env from the template's own values
# Why: split cache keys, strict proxy, no state root
# From: Issue #1683 | PR #1858
_legacy_env() {
    local file="$1" user="${2:-}" root tpl
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    tpl="${root}/deploy/prod/.env"
    printf '%s\n' "IP_STANDARD=$(get_env_var IP_STANDARD "${tpl}")" "IP_SSL=$(get_env_var IP_SSL "${tpl}")" \
        "CACHE_DIR_STANDARD=${file%/*}/cache" "CACHE_DIR_SSL=${file%/*}/cache" 'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' "LANCACHE_IMAGE_TAG=v$(tr -d '[:space:]' < "${root}/VERSION")" \
        "UI_AUTH_USER=${user}" 'UI_AUTH_PASSWORD=' > "${file}"
}

@test "migrate_env_for_update is a no-op on an already-converged .env" {
    _stand_ins || return 1
    # What: a converged .env stays byte-identical
    # Why: idempotent update, no rewrite (AG-OP-006)
    # From: Issue #1683 | PR #1858
    local root d h
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${BATS_TEST_TMPDIR}/noop/deploy/prod"
    _converged_install "${d}" || return 1
    h="$(sha256sum < "${d}/.env")"
    for _ in 1 2; do
        _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] && [ "$(sha256sum < "${d}/.env")" = "${h}" ] || { echo "rewrite: ${output}"; return 1; }
    done
}

@test "migrate_env_for_update converges a legacy .env and is stable on rerun" {
    _stand_ins || return 1
    # What: legacy keys migrate once; state root is written
    # Why: AG-OP-007 convergence; secrets must not rotate
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}/legacy" before
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mkdir -p "${t}" && _legacy_env "${t}/.env"
    export CONV="${t}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && ! env_key_exists CACHE_DIR_STANDARD "${t}/.env" && ! env_key_exists CACHE_DIR_SSL "${t}/.env" \
        && [ "$(get_env_var CACHE_DIR "${t}/.env")" = "${t}/cache" ] && [ "$(get_env_var PROXY_SECURITY_MODE "${t}/.env")" = lazy ] \
        && [[ "$(get_env_var LANCACHE_STATE_DIR "${t}/.env")" == /* ]] || { echo "legacy: ${output}"; cat "${t}/.env"; return 1; }
    before="$(cat "${t}/.env")"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ "$(cat "${t}/.env")" = "${before}" ] || { echo "second run changed .env"; return 1; }
}

@test "migrate_env_for_update generates a UI password once, never rotates it" {
    _stand_ins || return 1
    # What: a UI user without password gets one, once
    # Why: AG-OP-006 stable secrets on repeat execution
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}/ui" pw
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mkdir -p "${t}" && _legacy_env "${t}/.env" "u${BATS_TEST_NUMBER}"
    export CONV="${t}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    pw="$(get_env_var UI_AUTH_PASSWORD "${t}/.env")"
    [ "${status}" -eq 0 ] && [ "$(get_env_var UI_AUTH_USER "${t}/.env")" = "u${BATS_TEST_NUMBER}" ] && [ -n "${pw}" ] \
        || { echo "password: ${output}"; return 1; }
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ "$(get_env_var UI_AUTH_PASSWORD "${t}/.env")" = "${pw}" ] || { echo "password rotated"; return 1; }
}

@test "migrate_env_for_update leaves no duplicate key assignments" {
    _stand_ins || return 1
    # What: two runs must not stack duplicate key lines
    # Why: set_env_key collapses duplicates (AG-OP-006)
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}/dup"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mkdir -p "${t}" && _legacy_env "${t}/.env"
    export CONV="${t}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}" && migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ -z "$(awk -F= '/^[A-Za-z_]/ { print $1 }' "${t}/.env" | sort | uniq -d)" ] \
        || { echo "duplicates: ${output}"; return 1; }
}

@test "migrate_env_for_update keeps config/prod values per row" {
    _stand_ins || return 1
    # What: hand edits move to .env; bad ones change nothing
    # Why: AG-OP-009 edits survive; the checkout stays clean
    # From: Issue #1683 | PR #1858
    local root ip srv srv2 net bios mode name extra init envw edit want kv msg base pd cpe
    local -a kvs
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    ip="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")" net="${ip%.*}"
    srv="${net}.$(( (${ip##*.} + 1) % 255 ))" srv2="${net}.$(( (${ip##*.} + 2) % 255 ))" bios="b${BATS_TEST_NUMBER}.0"
    mode="$(declare -f migrate_env_for_update)"
    mode="$(awk '/^ *[a-z-]+\)$/ { a = $1 } /neither DHCP_PROXY_PXE_BOOT_FILENAME_BIOS/ && !m { sub(/\)$/, "", a); m = a } END { print m }' <<< "${mode}")"
    [ -n "${ip}" ] && is_valid_dhcp_mode "${mode}" || { echo "inputs: ${ip} ${mode}"; return 1; }
    _cp_install() {
        base="${BATS_TEST_TMPDIR}/${1}" pd="${BATS_TEST_TMPDIR}/${1}/deploy/prod" cpe="${BATS_TEST_TMPDIR}/${1}/config/prod/dhcp-proxy.env"
        _prod_install "${pd}" || return 1
        git -C "${base}" init -q && git -C "${base}" add config
        git -C "${base}" -c user.email=t@t -c user.name=t commit -qm template
        _legacy_env "${pd}/.env"
        export CONV="${pd}"
    }
    # What: a template edit moves to .env and stays
    # Why: a later edit wins; the template stays at HEAD
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r name init envw edit want; do
        _cp_install "${name}" || return 1
        IFS=';' read -r -a kvs <<< "${init}"
        for kv in "${kvs[@]}"; do set_env_key "${kv%%=*}" "${kv#*=}" "${cpe}"; done
        _setup_sh_run 'PATH="${BIN}:${PATH}"; adopt_config_prod_edits "${CONV%/deploy/prod}" >/dev/null && migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "${name}: run 1: ${output}"; return 1; }
        IFS=';' read -r -a kvs <<< "${envw}"
        for kv in "${kvs[@]}"; do grep -qx -- "${kv}" "${pd}/.env" || { echo "${name}: .env lacks ${kv}"; return 1; }; done
        [ "${edit}" = - ] || set_env_key "${edit%%=*}" "${edit#*=}" "${cpe}"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; adopt_config_prod_edits "${CONV%/deploy/prod}" >/dev/null && migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] && git -C "${base}" diff --quiet HEAD -- config || { echo "${name}: run 2: ${output}"; return 1; }
        IFS=';' read -r -a kvs <<< "${want}"
        for kv in "${kvs[@]}"; do
            grep -qx -- "${kv}" "${pd}/.env" && ! grep -q "^${kv%%=*}=" "${cpe%.env}.local.env" \
                || { echo "${name}: ${kv} not moved"; return 1; }
        done
    done <<CASES
repeated|DHCP_PROXY_PXE_BOOT_SERVER=${srv};DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${bios}|DHCP_PROXY_PXE_BOOT_SERVER=${srv};DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${bios}|-|DHCP_PROXY_PXE_BOOT_SERVER=${srv};DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${bios}
direct-edit|DHCP_PROXY_PXE_BOOT_SERVER=${srv};DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${bios}|DHCP_PROXY_PXE_BOOT_SERVER=${srv}|DHCP_PROXY_PXE_BOOT_SERVER=${srv2}|DHCP_PROXY_PXE_BOOT_SERVER=${srv2}
CASES
    # What: an invalid edit restores .env and keeps the edit
    # Why: a failed update must never leave half a migration
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r name extra kv msg; do
        _cp_install "${name}" || return 1
        tr ';' '\n' <<< "${extra}" >> "${pd}/.env"
        set_env_key "${kv%%=*}" "${kv#*=}" "${cpe}"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; adopt_config_prod_edits "${CONV%/deploy/prod}" >/dev/null'
        cp "${pd}/.env" "${base}/env.before"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${msg}"* && "${output}" == *"Restored ${pd}/.env to its state before the update"* ]] \
            && [[ "${output}" != *unreached* ]] && cmp -s "${base}/env.before" "${pd}/.env" && grep -qx -- "${kv}" "${cpe%.env}.local.env" \
            || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<CASES
incomplete-pair|DHCP_MODE=${mode};DHCP_SUBNET_START=${net}.0;DHCP_DNS_PRIMARY=${ip};UPSTREAM_DHCP_IP=${srv}|DHCP_PROXY_PXE_BOOT_SERVER=${srv}|neither DHCP_PROXY_PXE_BOOT_FILENAME_BIOS nor DHCP_PROXY_PXE_BOOT_FILENAME_UEFI is
invalid-value|DHCP_MODE=${mode};DHCP_SUBNET_START=${net}.0;DHCP_DNS_PRIMARY=${ip};UPSTREAM_DHCP_IP=${srv}|DHCP_PROXY_ROUTER=x${BATS_TEST_NUMBER}|must be a valid IPv4 address or empty.
CASES
}

@test "migrate_env_for_update preserves all custom per-service state dirs" {
    _stand_ins || return 1
    # What: an operator's own per-service state dir survives
    # Why: AG-OP-009 override preservation
    # From: Issue #1683 | PR #1858
    local root d keys k
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${BATS_TEST_TMPDIR}/custom/deploy/prod"
    _converged_install "${d}" || return 1
    keys="$(prod_state_keys | grep -vx CACHE_DIR)"
    while IFS= read -r k; do set_env_key "${k}" "${BATS_TEST_TMPDIR}/own/${k}" "${d}/.env"; done <<< "${keys}"
    for _ in 1 2; do
        _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "migrate: ${output}"; return 1; }
        while IFS= read -r k; do
            [ "$(get_env_var "${k}" "${d}/.env")" = "${BATS_TEST_TMPDIR}/own/${k}" ] || { echo "${k} lost"; return 1; }
        done <<< "${keys}"
    done
}

@test "migrate_env_for_update drops a per-service state dir equal to the one-root default" {
    _stand_ins || return 1
    # What: a per-service dir equal to default is dropped
    # Why: one-root contract via LANCACHE_STATE_DIR
    # From: Issue #1683 | PR #1858
    local root d k
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${BATS_TEST_TMPDIR}/dflt/deploy/prod"
    _converged_install "${d}" || return 1
    while IFS= read -r k; do
        set_env_key "${k}" "$(get_env_var LANCACHE_STATE_DIR "${d}/.env")/$(prod_state_subdir "${k}")" "${d}/.env"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] && ! env_key_exists "${k}" "${d}/.env" || { echo "${k} kept: ${output}"; return 1; }
    done <<< "$(prod_state_keys | grep -vx CACHE_DIR)"
}

@test "migrate_env_for_update refuses an empty IP_SSL before any write" {
    _stand_ins || return 1
    # What: empty IP_SSL stops the update; .env untouched
    # Why: prod binds dns-ssl to IP_SSL (AG-SETUP-001)
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}/nossl"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mkdir -p "${t}" && _legacy_env "${t}/.env"
    set_env_key IP_SSL "" "${t}/.env"
    cp "${t}/.env" "${t}/.env.before"
    export CONV="${t}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${CONV}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"IP_SSL is missing or empty in ${t}/.env"* && "${output}" != *unreached* ]] \
        && cmp -s "${t}/.env.before" "${t}/.env" || { echo "empty IP_SSL: ${output}"; return 1; }
}

@test "production_state_root_default keeps deploy/prod state out of the checkout" {
    # What: Deploy/prod state defaults off checkout.
    # Why: Runtime state outside git checkout.
    # From: Issue #1683 | PR #1858
    local repo_root root co="${BATS_TEST_TMPDIR}/co" dp binds
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${repo_root}"
    dp="${co}/deploy/prod"
    _prod_install "${dp}"
    remove_env_key LANCACHE_STATE_DIR "${dp}/.env"
    root="$(production_state_root_default "${dp}")"
    [[ "${root}" == /* && "${root}/" != "${co}/"* ]] || { echo "root: ${root}"; return 1; }
    # What: compose itself resolves state under that root
    # Why: setup.sh and compose must share one default
    # From: Issue #1683 | PR #1858
    binds="$(docker compose --env-file "${dp}/.env" -f "${dp}/docker-compose.yml" config --format json)"
    binds="$(jq -r '.services[].volumes[]? | select(.type == "bind") | .source' <<< "${binds}")"
    grep -q "^${root}/" <<< "${binds}" || { echo "no state bind under ${root}: ${binds}"; return 1; }
    [ "$(production_state_root_default "${BATS_TEST_TMPDIR}/legacy")" = "${BATS_TEST_TMPDIR}/legacy" ]
}

@test "setup quickstart install moves into deploy/prod once" {
    _stand_ins || return 1
    # What: state, settings and CA move to deploy/prod
    # Why: AG-OP-007: a quickstart user loses nothing
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" project svc keys key want vol dir absent copies f el
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    export ROOT="${root}" CO="${t}/co" QS="${t}/qs" BK="${t}/bk"
    _prod_install "${CO}/deploy/prod"
    project="$(_prod_compose config --format json | jq -r .name)"
    svc="$(_prod_compose config --services | awk 'NR == 1')"
    # What: quickstart input from setup.sh's own lists
    # Why: volume, path and bundle sets have one owner
    # From: Issue #1683 | PR #1858
    keys="$(declare -f migrate_quickstart_install | sed -n 's/^ *local path_keys="\([^"]*\)".*/\1/p')"
    copies="$(declare -f migrate_quickstart_install | grep -o '"\$old_dir/scripts/[^"]*"' | sed 's|^"\$old_dir/||; s|"$||')"
    [ -n "${keys}" ] && [ -n "${copies}" ] || { echo "migration lists: ${keys} | ${copies}"; return 1; }
    mkdir -p "${QS}/certs"
    cp "${root}/deploy/prod/.env" "${QS}/.env"
    remove_env_key LANCACHE_STATE_DIR "${QS}/.env"
    for key in ${keys}; do set_env_key "${key}" "./${key,,}" "${QS}/.env"; done
    want="$(get_env_var CACHE_MAX_SIZE "${QS}/.env")"
    set_env_key CACHE_MAX_SIZE "$(( ${want%%[!0-9]*} * 2 ))${want##*[0-9]}" "${QS}/.env"
    cp "${QS}/.env" "${t}/qs.env"
    while IFS= read -r f; do
        mkdir -p "$(dirname "${QS}/${f}")" && printf '%s\n' "${f}" > "${QS}/${f}"
    done <<< "${copies}"
    printf '%s\n' "${QS}" > "${QS}/certs/ca.crt"; printf '%s\n' "${t}" > "${QS}/certs/ca.key"
    {
        printf 'name: %s\nservices:\n  %s:\n    image: %s\n    volumes:\n' "${project}" "${svc}" "${LANCACHE_HELPER_IMAGE}"
        quickstart_volume_keys | awk '{ printf "      - %s:/%s\n", $1, $1 }'
        printf 'volumes:\n'
        quickstart_volume_keys | awk '{ printf "  %s: {}\n", $1 }'
    } > "${QS}/docker-compose.yml"
    absent="$(quickstart_volume_keys | awk 'END { print $1 }')"
    while read -r vol key; do
        [ "${vol}" != "${absent}" ] || continue
        mkdir -p "${DS}/volumes/${project}_${vol}"
        printf '%s\n' "${vol}" > "${DS}/volumes/${project}_${vol}/${vol}"
        printf '%s\n' "${key}" > "${DS}/volumes/${project}_${vol}/.${key}"
    done <<< "$(quickstart_volume_keys)"
    : > "${DS}/running"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; eval "${SETUP_SH_SEAMS}"; SCRIPT_DIR="${CO}" BACKUP_ROOT="${BK}"
        PROD_COMPOSE="${CO}/${PROD_COMPOSE#"${ROOT}/"}"
        is_quickstart_install "${QS}" && migrate_quickstart_install "${QS}"'
    [ "${status}" -eq 0 ] || { echo "migrate: ${output}"; return 1; }
    el="$(runtime_env_file_for_install_dir "${CO}/deploy/prod")"
    [ "${el}" != "${CO}/deploy/prod/.env" ] && [ "$(stat -c %a "${el}")" = 600 ] || { echo "env: ${el}"; return 1; }
    [ "$(get_env_var LANCACHE_STATE_DIR "${el}")" = "${QS}" ] || { echo "state root"; return 1; }
    while IFS= read -r key; do
        want="$(get_env_assignment_value_raw "${key}" "${t}/qs.env")"
        [[ " ${keys} " != *" ${key} "* ]] || want="$(realpath -m "${QS}/${want}")"
        [ "$(get_env_assignment_value_raw "${key}" "${el}")" = "${want}" ] || { echo "value of ${key}"; return 1; }
    done <<< "$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "${t}/qs.env")"
    while read -r vol dir; do
        if [ "${vol}" = "${absent}" ]; then
            [ ! -e "${dir}" ] || { echo "absent ${vol} made ${dir}"; return 1; }
        else
            diff -r "${DS}/volumes/${project}_${vol}" "${dir}" || { echo "copy of ${vol}"; return 1; }
        fi
    done <<< "$(quickstart_volume_dirs "${el}")"
    cmp "${QS}/certs/ca.crt" "${CO}/certs/ca.crt" && cmp "${QS}/certs/ca.key" "${CO}/certs/ca.key" || { echo "ca"; return 1; }
    while IFS= read -r f; do [ ! -e "${QS}/${f}" ] || { echo "kept ${f}"; return 1; }; done <<< "${copies}"
    [ ! -e "${QS}/docker-compose.yml" ] && [ ! -e "${QS}/.env" ] || { echo "quickstart files"; return 1; }
    grep -q '^completed|' "${QS}/.quickstart-migration" || { echo "record"; return 1; }
    [ "$(find "${BK}" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] || { echo "backups: $(ls -A "${BK}")"; return 1; }
    # What: quickstart stops for good before prod starts
    # Why: two stacks must never share the IPs at once
    # From: Issue #1683 | PR #1858
    awk -v q="compose --env-file ${QS}/.env " -v p="compose --env-file ${el} " '
        index($0, q) == 1 && / stop$/ { st = NR }
        index($0, q) == 1 && / up -d$/ { su = NR }
        index($0, p) == 1 && / up -d / && !pu { pu = NR }
        END { exit !(st > su && pu > st) }' "${DS}/docker.log" || { cat "${DS}/docker.log"; return 1; }
    ! is_quickstart_install "${QS}" || { echo "still quickstart"; return 1; }
    [ "$(resolve_stack_dir "${CO}")" = "${CO}/deploy/prod" ] && [ "$(resolve_stack_dir "${QS}")" = "${QS}" ] \
        || { echo "stack dirs"; return 1; }
    # What: the prod stack reads every migrated value
    # Why: a copied but unread key is silent value loss
    # From: Issue #1683 | PR #1858
    local cfg prof
    local -a profiles=()
    prof="$(docker compose --env-file "${el}" -f "${CO}/deploy/prod/docker-compose.yml" config --profiles)"
    while IFS= read -r f; do [ -z "${f}" ] || profiles+=(--profile "${f}"); done <<< "${prof}"
    cfg="$(docker compose --env-file "${el}" -f "${CO}/deploy/prod/docker-compose.yml" "${profiles[@]}" config --format json)"
    want="$(get_env_var CACHE_MAX_SIZE "${t}/qs.env")"
    jq -e --arg v "${want}" '[.services[].environment.CACHE_MAX_SIZE?] | index($v) != null' <<< "${cfg}" >/dev/null \
        || { echo "CACHE_MAX_SIZE ${want} not in the prod stack"; return 1; }
    for key in ${keys}; do
        want="$(get_env_var "${key}" "${el}")"
        grep -qF "\"${want}\"" <<< "${cfg}" || { echo "${key}=${want} not in the prod stack"; return 1; }
    done
}

@test "setup update pulls the checkout and continues on its setup.sh" {
    _stand_ins || return 1
    # What: update pulls, runs the new setup.sh, rolls back
    # Why: compose, templates, script move as one revision
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" main lo std ssl svc mark c2 c3 f p
    local -a pids=() ips=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    main="$(declare -f git_default_branch_name | sed -n 's/.*default_branch:-\([A-Za-z0-9_-]*\)}.*/\1/p')"
    lo="127.$(( BATS_TEST_NUMBER % 250 + 1 ))" svc="probe${BATS_TEST_NUMBER}" mark="rev${BATS_TEST_NUMBER}"
    std="${lo}.0.1" ssl="${lo}.0.2"
    g() { git -c user.email=t@example.test -c user.name=t -c init.defaultBranch="${main}" "$@"; }
    # What: an origin holding the real checkout files
    # Why: the update must run exactly what a clone carries
    # From: Issue #1683 | PR #1858
    g init -q --bare "${t}/origin.git"
    mkdir -p "${t}/src"
    for f in setup.sh VERSION .gitignore deploy/prod/docker-compose.yml deploy/prod/.env \
        deploy/prod/docker-compose.nats-secondary.yml .github/yaml/build-manifest.yml .github/scripts/ci.sh \
        $(cd "${root}" && git ls-files config/prod); do
        mkdir -p "$(dirname "${t}/src/${f}")" && cp "${root}/${f}" "${t}/src/${f}"
    done
    chmod +x "${t}/src/setup.sh"
    g -C "${t}/src" init -q && g -C "${t}/src" add -A && g -C "${t}/src" commit -q -m c1
    g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}"
    g clone -q "${t}/origin.git" "${t}/co"
    cp "${t}/co/deploy/prod/.env" "${t}/co/deploy/prod/.env.local"
    set_env_key LANCACHE_STATE_DIR "${t}/state" "${t}/co/deploy/prod/.env.local"
    set_env_key IP_STANDARD "${std}" "${t}/co/deploy/prod/.env.local"
    set_env_key IP_SSL "${ssl}" "${t}/co/deploy/prod/.env.local"
    set_env_key LANCACHE_IMAGE_TAG "v$(tr -d '[:space:]' < "${root}/VERSION")" "${t}/co/deploy/prod/.env.local"
    [ -z "$(g -C "${t}/co" status --porcelain)" ] || { echo "fixture checkout is dirty"; return 1; }
    # What: revision 2 adds a service and marks setup.sh
    # Why: both must reach the run after the pull
    # From: Issue #1683 | PR #1858
    printf '  %s:\n    image: %s\n' "${svc}" "${LANCACHE_HELPER_IMAGE}" > "${t}/svc.yml"
    awk -v add="${t}/svc.yml" '{ print } /^services:$/ { while ((getline l < add) > 0) print l }' \
        "${t}/src/deploy/prod/docker-compose.yml" > "${t}/c.yml" && mv "${t}/c.yml" "${t}/src/deploy/prod/docker-compose.yml"
    sed -i "s/print_ok \"Stack updated\"/print_ok \"Stack updated at ${mark}\"/" "${t}/src/setup.sh"
    grep -qF "Stack updated at ${mark}" "${t}/src/setup.sh" || { echo "marker not placed"; return 1; }
    g -C "${t}/src" commit -q -am c2 && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}"
    c2="$(g -C "${t}/src" rev-parse HEAD)"
    for p in "${std}" "${ssl}"; do
        timeout 600 busybox nc -lk -s "${p}" -p 80 -e true < /dev/null > "${t}/nc-${p}.log" 2>&1 3>&- &
        pids+=("$!")
        ips+=("${p}")
    done
    # What: stop listeners; a gone one fails, raw log shown
    # Why: else the port 80 probe may hit another socket
    # From: Issue #1683 | PR #1858
    _stop() {
        local i err rc=0
        for i in "${!pids[@]}"; do
            err="$(kill "${pids[i]}" 2>&1)" && continue
            echo "listener ${ips[i]}:80 gone before cleanup: ${err}; nc: $(cat "${t}/nc-${ips[i]}.log")"
            rc=1
        done
        return "${rc}"
    }
    export FAULT="${BATS_TEST_NAME}" CO="${t}/co"
    _update() {
        run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" PATH="${BIN}:${PATH}" LANCACHE_BACKUP_ROOT="${t}/bk" \
            bash "${CO}/setup.sh" update "${CO}/deploy/prod"
    }
    _update
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] \
        && [[ "${output}" == *"Stack updated at ${mark}"* ]] \
        && [ "$(grep -c "Continuing the update with" <<< "${output}")" -eq 1 ] \
        && grep -qE "^compose .* up -d --remove-orphans .*\b${svc}\b" "${DS}/docker.log" \
        || { _stop; echo "update: ${output}"; return 1; }
    # What: a failed apply returns checkout and config
    # Why: no mix of old config and new compose may stay
    # From: Issue #1683 | PR #1858
    sed -i "s/Stack updated at ${mark}/Stack updated at ${mark}x/" "${t}/src/setup.sh"
    g -C "${t}/src" commit -q -am c3 && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}"
    c3="$(g -C "${t}/src" rev-parse HEAD)"
    cp "${t}/co/deploy/prod/.env.local" "${t}/env.before"
    : > "${DS}/fail-apply"
    _update
    rm -f "${DS}/fail-apply"
    [ "${status}" -eq 1 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] \
        && [[ "${output}" == *"Returned ${t}/co to ${c2}"* && "${output}" == *"rolled back"* ]] \
        && cmp -s "${t}/env.before" "${t}/co/deploy/prod/.env.local" \
        || { _stop; echo "rollback to ${c2} from ${c3}: ${output}"; return 1; }
    # What: a detached checkout updates in place, unmoved
    # Why: a pinned revision is the operator's choice
    # From: Issue #1683 | PR #1858
    g -C "${t}/co" checkout -q --detach
    _update
    _stop || return 1
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] && [[ "${output}" == *"pinned commit"* ]] \
        && [[ "${output}" != *"Continuing the update with"* ]] || { echo "pinned: ${output}"; return 1; }
}

# What: iproute2 stand-in for host addresses and routes
# Why: the wizard reads them; tests own no host network
# From: Issue #1683 | PR #1858
_ip_stub() {
    _tool_stub "$1" ip <<'STUB'
printf '%s\n' "$*" >> "${IPDS}/ip.log"
case "$*" in
    "-4 addr show")
        [ ! -e "${IPDS}/fail-addr" ] || { echo "ip: cannot list addresses" >&2; exit 1; }
        n=1
        while read -r a p d; do
            n=$((n + 1))
            printf '%s: %s: <BROADCAST,UP,LOWER_UP> mtu 1500 state UP\n' "${n}" "${d}"
            printf '    inet %s/%s scope global %s\n' "${a}" "${p}" "${d}"
        done < "${IPDS}/addrs" ;;
    "-4 route get "*)
        [ -e "${IPDS}/src" ] || { echo "RTNETLINK answers: Network is unreachable" >&2; exit 2; }
        read -r a d < "${IPDS}/src"
        printf '%s dev %s src %s uid 0\n    cache\n' "$4" "${d}" "${a}" ;;
esac
STUB
}

@test "setup list-prompts walks the real wizard without side effects" {
    # What: prompts, defaults, branches of the real wizard
    # Why: CI prompt checks must see what operators see
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" tpl std dev pfx ssl k base pats preset modes m dhcp ddir add v d p q try
    local -a ans=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    # What: a checkout copy whose template DHCP values shift
    # Why: a default equal to an old literal proves no owner
    # From: Issue #1683 | PR #1858
    _checkout_copy "${root}" "${t}/repo" || { echo "checkout copy failed"; return 1; }
    tpl="${t}/repo/deploy/prod/.env"
    for v in DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END; do
        d="$(get_env_var "${v}" "${tpl}")"
        printf '%s\n' "${d}" "${d%/*}" >> "${t}/unshifted"
        set_env_key "${v}" "$(awk -F. -v OFS=. '{ $3 = ($3 + 1) % 256; print }' <<< "${d}")" "${tpl}"
        [ "$(get_env_var "${v}" "${tpl}")" != "${d}" ] || { echo "${v} not shifted"; return 1; }
    done
    std="$(get_env_var IP_STANDARD "${tpl}")"
    dev="lan${BATS_TEST_NUMBER}" pfx=$(( BATS_TEST_NUMBER % 8 + 16 ))
    export IPDS="${t}/ipds" SETUP="${t}/repo/setup.sh" ANS="${t}/answers" PRESET=""
    mkdir -p "${IPDS}"
    _ip_stub "${t}/ipbin"
    _host() {
        rm -f "${IPDS}/fail-addr"
        printf '%s\n' "127.0.0.1 8 lo" "$@" > "${IPDS}/addrs"
        printf '%s %s\n' "${std}" "${dev}" > "${IPDS}/src"
    }
    _lp() {
        run timeout -k 5 120 env -u LANCACHE_IMAGE_CHANNEL DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" \
            PATH="${t}/ipbin:${PATH}" IPDS="${IPDS}" ${PRESET:+LANCACHE_IMAGE_CHANNEL="${PRESET}"} \
            bash "${SETUP}" list-prompts "$@"
    }
    _prompts() { grep -P '^PROMPT\t' <<< "${output}" | cut -f2; }
    _default() { grep -P '^PROMPT\t' <<< "${output}" | awk -F'\t' -v n="$1" 'NR == n { print $3 }'; }
    _write_ans() {
        local i last=-1
        for i in "${!ans[@]}"; do last="${i}"; done
        : > "${ANS}"
        for ((i = 0; i <= last; i++)); do printf '%s\n' "${ans[${i}]-}" >> "${ANS}"; done
    }
    _host "${std} ${pfx} ${dev}"
    _lp
    [ "${status}" -eq 0 ] || { echo "defaults: ${output}"; return 1; }
    base="$(_prompts)"
    # What: each prompt matches an ask/confirm in setup.sh
    # Why: the list comes from the wizard, never made up
    # From: Issue #1683 | PR #1858
    pats="${t}/prompt-patterns"
    grep -oE '\b(ask|confirm) "[^"]*"' "${root}/setup.sh" | sed -E 's/^(ask|confirm) "//; s/"$//' \
        | sed -E 's/\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*/@@V@@/g; s/[][\\.^$*+?(){}|]/\\&/g; s/@@V@@/.*/g; s/.*/^&$/' \
        | grep -vxF '^.*$' > "${pats}"
    while IFS= read -r q; do
        grep -qE -f "${pats}" <<< "${q}" || { echo "prompt not from setup.sh: ${q}"; return 1; }
    done <<< "${base}"
    # What: default is the detected IP; offer uses its link
    # Why: AG-SEC-007; no guessed address, device or mask
    # From: Issue #1683 | PR #1858
    k="$(awk -F'\t' -v ip="${std}" '$1 == "PROMPT" { n++; if ($3 == ip) { print n; exit } }' <<< "${output}")"
    ssl="$(_default $(( k + 1 )))"
    [ -n "${k}" ] && [ -n "${ssl}" ] && [ "${ssl}" != "${std}" ] \
        && [[ "${output}" == *"${std}/${pfx} dev ${dev}"* && "${output}" != *"127.0.0.1/8"* ]] \
        && [[ "${base}" == *"${ssl}/${pfx} dev ${dev}"* ]] || { echo "detection: ${output}"; return 1; }
    add="$(grep -nF -- "${ssl}/${pfx} dev ${dev}" <<< "${base}" | cut -d: -f1)"
    # What: no address: no default, and a fail, not a loop
    # Why: AG-OP-008; the operator must enter the address
    # From: Issue #1683 | PR #1858
    : > "${IPDS}/fail-addr"; rm -f "${IPDS}/src"
    _lp
    [ "${status}" -ne 0 ] && [ "${status}" -ne 124 ] && [ -z "$(_default "${k}")" ] \
        && [[ "${output}" == *"rejected its answer"* ]] || { echo "no detection: rc ${status}: ${output}"; return 1; }
    printf '%s' "${std}" > "${ANS}"
    _lp "${ANS}"
    [ "${status}" -eq 0 ] || { echo "unterminated last answer lost: ${output}"; return 1; }
    # What: assigned IP_SSL: no offer; foreign IP: none
    # Why: the add offer exists only for a known device
    # From: Issue #1683 | PR #1858
    _host "${std} ${pfx} ${dev}" "${ssl} ${pfx} ${dev}"
    _lp
    [ "${status}" -eq 0 ] && [[ "$(_prompts)" != *"${ssl}/"* && "${output}" == *"${ssl} already assigned"* ]] \
        || { echo "assigned: ${output}"; return 1; }
    _host "${std} ${pfx} ${dev}"
    v="$(get_env_var IP_SSL "${tpl}")"
    ans=(); ans[$(( k - 1 ))]="${v}"; _write_ans
    _lp "${ANS}"
    [ "${status}" -eq 0 ] && [[ "$(_prompts)" != *" dev "* && "${output}" == *"interface that carries ${v}"* ]] \
        || { echo "foreign: ${output}"; return 1; }
    # What: y to the add offer never runs ip addr add
    # Why: list-prompts must not change host networking
    # From: Issue #1683 | PR #1858
    ans=(); ans[$(( add - 1 ))]=y; _write_ans
    : > "${IPDS}/ip.log"
    _lp "${ANS}"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"would be added"* ]] && ! grep -q '^addr add' "${IPDS}/ip.log" \
        || { echo "ip addr add ran: $(cat "${IPDS}/ip.log")"; return 1; }
    preset="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release "" default_channel)"
    PRESET="${preset}" _lp
    [ "${status}" -eq 0 ] && [ "$(_prompts | wc -l)" -eq $(( $(wc -l <<< "${base}") - 1 )) ] \
        || { echo "channel preset: ${output}"; return 1; }
    export PRESET="${preset}"
    _lp; base="$(_prompts)"
    modes="$(awk '/pub fn as_str/ { f = 1 } f && /^    }$/ { exit } f' "${root}/services/ui/src/config.rs" | sed -n 's/.*Self::[A-Za-z]* => "\([a-z-]*\)",/\1/p')"
    dhcp="$(awk -v m="$(paste -sd'|' <<< "${modes}")" 'BEGIN { n = split(m, a, "|") } { ok = 1; for (i = 1; i <= n; i++) if (index($0, a[i]) == 0) ok = 0; if (ok) { print NR - 1; exit } }' <<< "${base}")"
    ddir="$(awk -F'\t' -v d="$(production_state_root_default "${t}/repo/deploy/prod")" '$1 == "PROMPT" { n++; if ($3 == d) { print n - 1; exit } }' <<< "${output}")"
    [ -n "${dhcp}" ] && [ -n "${ddir}" ] || { echo "prompts not found: dhcp=${dhcp} ddir=${ddir}"; return 1; }
    # What: an answered path is never created by the walk
    # Why: list-prompts must not touch the host at all
    # From: Issue #1683 | PR #1858
    ans=(); ans[ddir]="${t}/would-be-state"; _write_ans
    _lp "${ANS}"
    [ "${status}" -eq 0 ] && [ ! -e "${t}/would-be-state" ] || { echo "data dir created: ${output}"; return 1; }
    # What: each DHCP mode walks its own branch to the end
    # Why: a branch the walk skips is a prompt CI never sees
    # From: Issue #1683 | PR #1858
    m="$(_default $(( dhcp + 1 )))"
    printf '%s\n' "${base}" > "${t}/base-prompts"
    : > "${t}/extra-defaults"
    while IFS= read -r v; do
        ans=(); ans[dhcp]="${v}"
        for ((try = 0; try < 8; try++)); do
            _write_ans; _lp "${ANS}"
            [ "${status}" -ne 0 ] || break
            p="$(_prompts | wc -l)"
            [ "$(_prompts | awk -v n=$((p - 1)) 'NR == n')" != "$(_prompts | awk -v n="${p}" 'NR == n')" ] || p=$((p - 1))
            if [ "$(_default "${p}")" = N ]; then ans[p-1]=y; else ans[p-1]="${std}"; fi
        done
        d="$(awk -F'\t' 'NR == FNR { b[$0] = 1; next } $1 == "PROMPT" && !($2 in b) { print $3 }' "${t}/base-prompts" - <<< "${output}")"
        p="$(awk -F'\t' 'NR == FNR { b[$0] = 1; next } $1 == "PROMPT" && !($2 in b)' "${t}/base-prompts" - <<< "${output}" | wc -l)"
        if [ "${v}" = "${m}" ]; then [ "${p}" -eq 0 ]; else [ "${p}" -gt 0 ]; fi && [ "${status}" -eq 0 ] \
            || { echo "mode ${v}: rc ${status}, ${p} own prompts: ${output}"; return 1; }
        printf '%s\n' "${d}" >> "${t}/extra-defaults"
    done <<< "${modes}"
    for v in DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END; do
        d="$(get_env_var "${v}" "${tpl}")"
        grep -qxF -- "${d}" "${t}/extra-defaults" || { echo "${v} default not from the template"; return 1; }
    done
    d="$(get_env_var DHCP_SUBNET "${tpl}")"
    grep -qxF -- "${d%/*}" "${t}/extra-defaults" || { echo "subnet start default not from the template"; return 1; }
    v=0; grep -qxF -f "${t}/unshifted" "${t}/extra-defaults" || v=$?
    [ "${v}" -eq 1 ] || { echo "a default ignores the template (grep rc ${v})"; return 1; }
    # What: same input, same walk; help; missing file fails
    # Why: AG-OP-006 repeat-run stable; fail closed on input
    # From: Issue #1683 | PR #1858
    ans=(); ans[dhcp]="$(awk 'NR == 2' <<< "${modes}")"; _write_ans
    _lp "${ANS}"; base="${output}"
    _lp "${ANS}"
    [ "${status}" -eq 0 ] && [ "${output}" = "${base}" ] || { echo "walk not stable"; return 1; }
    _lp --help
    [ "${status}" -eq 0 ] && [[ "${output}" == *list-prompts* ]] || { echo "help: ${output}"; return 1; }
    _lp "${t}/missing"
    [ "${status}" -ne 0 ] || { echo "missing answers file accepted"; return 1; }
}

@test "setup fresh install writes a config the prod compose takes" {
    _stand_ins || return 1
    # What: the real wizard installs a checkout copy
    # Why: no other test runs the .env.local write
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" repo env tpl cfg port std dev pfx keys k v n ddir np i calls after
    # What: refuses to run on a host with a live systemd
    # Why: install would write units outside the test dir
    # From: Issue #1683 | PR #1858
    [ ! -d /run/systemd/system ] || { echo "systemd host: a real install would write /etc units"; return 1; }
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    repo="${t}/repo" env="${t}/repo/deploy/prod/.env.local" tpl="${t}/repo/deploy/prod/.env"
    _checkout_copy "${root}" "${repo}" || { echo "checkout copy failed"; return 1; }
    # What: the copy shifts ui port and size/age defaults
    # Why: a literal port or value copy would miss the shift
    # From: Issue #1683 | PR #1858
    cfg="$(docker compose --env-file "${tpl}" -f "${repo}/deploy/prod/docker-compose.yml" config --format json)"
    port="$(jq -r '.services.ui.ports[0].published' <<< "${cfg}")"
    sed -i "s/}:${port}:/}:$((port + 1)):/" "${repo}/deploy/prod/docker-compose.yml"
    [ "$(grep -c "}:$((port + 1)):" "${repo}/deploy/prod/docker-compose.yml")" -eq 1 ] || { echo "port ${port} not shifted"; return 1; }
    keys="$(declare -f set_template_owned_env_defaults)"
    keys="$(grep -oE '\b[A-Z][A-Z0-9_]{2,}\b' <<< "${keys}" | sort -u)"
    n=0
    for k in ${keys}; do
        v="$(get_env_var "${k}" "${tpl}")"
        [[ "${v}" =~ ^([0-9]+)([a-z])$ ]] || continue
        set_env_key "${k}" "$((BASH_REMATCH[1] + 1))${BASH_REMATCH[2]}" "${tpl}"
        n=$((n + 1))
    done
    [ "${n}" -gt 0 ] || { echo "no template default shifted: ${keys}"; return 1; }
    std="$(get_env_var IP_STANDARD "${tpl}")" dev="lan${BATS_TEST_NUMBER}" pfx=$(( BATS_TEST_NUMBER % 8 + 16 ))
    export IPDS="${t}/ipds" REPO="${repo}" ENVL="${env}" ID_REAL
    ID_REAL="$(type -P id)"
    mkdir -p "${IPDS}" && _ip_stub "${BIN}"
    printf '%s\n' "127.0.0.1 8 lo" "${std} ${pfx} ${dev}" > "${IPDS}/addrs"
    printf '%s %s\n' "${std}" "${dev}" > "${IPDS}/src"
    # What: id -u reports root; the rest is the real host
    # Why: setup.sh requires root; the test box may not be
    # From: Issue #1683 | PR #1858
    _tool_stub "${BIN}" id <<<'[ "$*" != -u ] || { echo 0; exit 0; }; exec "${ID_REAL:?}" "$@"'
    printf 'sha256:%s' "$(printf '%064d' 0 | tr 0 a)" > "${DS}/digest"
    LANCACHE_IMAGE_TAG="v$(tr -d '[:space:]' < "${root}/VERSION")"
    export LANCACHE_IMAGE_CHANNEL=pinned LANCACHE_IMAGE_TAG
    # What: one answer per wizard prompt, all defaults
    # Why: only the state dir moves under the test dir
    # From: Issue #1683 | PR #1858
    run timeout -k 5 120 bash "${repo}/setup.sh" list-prompts
    [ "${status}" -eq 0 ] || { echo "prompts: ${output}"; return 1; }
    ddir="$(awk -F'\t' -v d="$(production_state_root_default "${repo}/deploy/prod")" '$1 == "PROMPT" { n++; if ($3 == d) { print n; exit } }' <<< "${output}")"
    np="$(grep -cP '^PROMPT\t' <<< "${output}")"
    [ -n "${ddir}" ] && [ "${np}" -gt 0 ] || { echo "no state dir prompt: ${output}"; return 1; }
    for ((i = 1; i <= np; i++)); do
        if [ "${i}" -eq "${ddir}" ]; then printf '%s\n' "${t}/state"; else printf '\n'; fi
    done > "${t}/answers"
    # What: no command prints the help and writes nothing
    # Why: only the explicit install command installs
    # From: Issue #1683 | PR #1858
    calls=0
    [ ! -e "${DS}/docker.log" ] || calls="$(wc -l < "${DS}/docker.log")"
    run timeout -k 5 60 bash "${repo}/setup.sh"
    after=0
    [ ! -e "${DS}/docker.log" ] || after="$(wc -l < "${DS}/docker.log")"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Usage:"* ]] && [ ! -e "${env}" ] && [ "${after}" -eq "${calls}" ] \
        || { echo "no command: rc ${status} docker calls ${calls}->${after}: ${output}"; return 1; }
    run timeout -k 5 300 script -qec "bash ${repo}/setup.sh install" /dev/null < "${t}/answers"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Stack started"* ]] || { echo "install: rc ${status}: ${output}"; return 1; }
    [[ "${output}" == *"http://${std}:$((port + 1))"* ]] || { echo "ui url: ${output}"; return 1; }
    [ "$(awk -v e="compose --env-file ${env} " 'index($0, e) == 1 && ($NF == "pull" || / up -d$/) { n++ } END { print n + 0 }' "${DS}/docker.log")" -eq 2 ] \
        || { echo "pull/up: $(cat "${DS}/docker.log")"; return 1; }
    # What: prod compose renders with the written config
    # Why: compose fails closed on a missing required key
    # From: Issue #1683 | PR #1858
    _setup_sh_run 'stack_compose "${REPO}/deploy/prod" "${ENVL}" config --quiet'
    [ "${status}" -eq 0 ] || { echo "compose config: ${output}"; return 1; }
    for k in ${keys}; do
        [ "$(get_env_var "${k}" "${env}")" = "$(get_env_var "${k}" "${tpl}")" ] || { echo "${k}: $(cat "${env}")"; return 1; }
    done
    [ "$(get_env_var IP_STANDARD "${env}")" = "${std}" ] && [ "$(get_env_var LOGGING_ENABLED "${env}")" = 1 ] \
        && [[ ",$(get_env_var COMPOSE_PROFILES "${env}")," == *,logging,* ]] || { echo "values: $(cat "${env}")"; return 1; }
    # What: a failed URL render warns; the install ends 0
    # Why: a print after the start must never abort setup
    # From: Issue #1683 | PR #1858
    _checkout_copy "${root}" "${t}/repo2" || { echo "second copy failed"; return 1; }
    rm -f "${DS}/running"
    : > "${DS}/fail-config-after-up"
    FAULT="render refused" run timeout -k 5 300 script -qec "bash ${t}/repo2/setup.sh install" /dev/null < "${t}/answers"
    rm -f "${DS}/fail-config-after-up"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Stack started"* && "${output}" == *"Cannot derive the Admin-UI URL"* ]] \
        && [[ "${output}" == *"render refused"* ]] || { echo "url failure: rc ${status}: ${output}"; return 1; }
}

@test "deploy_prod_repo_input_paths snapshots repo-root runtime inputs for deploy/prod" {
    # What: lists each repo input compose mounts or reads
    # Why: rollback restores the config that existed before
    # From: Issue #1683 | PR #1858
    local root dp paths json inputs i p ok
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    dp="${root}/deploy/prod"
    paths="$(deploy_prod_repo_input_paths "${dp}")"
    json="$(NATS_BIND_IP="$(get_env_var IP_STANDARD "${dp}/.env")" docker compose --env-file "${dp}/.env" \
        -f "${dp}/docker-compose.yml" -f "${dp}/docker-compose.nats-secondary.yml" config --format json)"
    inputs="$(jq -r --arg r "${root}/" '[.services[] | ((.volumes // [])[] | select(.type == "bind") | .source),
        ((.env_file // [])[] | if type == "object" then .path else . end)] | unique[] | select(startswith($r))' <<< "${json}")"
    [ -n "${inputs}" ] && [ -n "${paths}" ] || { echo "inputs: ${inputs} | paths: ${paths}"; return 1; }
    while IFS= read -r i; do
        [ -e "${i}" ] || continue
        ok=0
        while IFS= read -r p; do [ "${i}" != "${p}" ] && [[ "${i}" != "${p}/"* ]] || ok=1; done <<< "${paths}"
        [ "${ok}" -eq 1 ] || { echo "compose input ${i} not in the backup list"; return 1; }
    done <<< "${inputs}"
    while IFS= read -r p; do [[ "${p}" == "${root}/"* && -e "${p}" ]] || { echo "listed ${p} is no repo path"; return 1; }; done <<< "${paths}"
    mkdir -p "${BATS_TEST_TMPDIR}/legacy"
    [ -z "$(deploy_prod_repo_input_paths "${BATS_TEST_TMPDIR}/legacy")" ] || { echo "non-prod install listed inputs"; return 1; }
}

# =========================================================
# PRODUCT RUNTIME: KNOWN-GOOD CONFIG SNAPSHOTS
# =========================================================

# =========================================================
# PRODUCT RUNTIME: RETENTION
# =========================================================

# What: source retention.sh's functions, not its loop.
# Why: tests call the real code without the daemon.
# From: Issue #842 | PR #1858
_load_retention_functions() {
    local f="${BATS_TEST_TMPDIR}/retention-functions.sh"
    awk '/^log\(\) \{/ { c = 1 } /^log "Retention daemon started\./ { c = 0 } c { print }' \
        "${BATS_TEST_DIRNAME}/../../services/watchdog/retention.sh" > "${f}"
    # shellcheck source=services/watchdog/retention.sh
    source "${f}"
}

@test "retention dir validation maps each path and purge refuses outside its prefix" {
    # What: validate_retention_dir per input, one table.
    # Why: a bad CACHE_DIR must never reach find or rm.
    # From: Issue #842 | PR #1858
    local t="${BATS_TEST_TMPDIR}" name val rc want
    _load_retention_functions
    mkdir -p "${t}/cache/lancache/sub"
    while IFS='|' read -r name val rc want; do
        run validate_retention_dir CACHE_DIR "${val//@T@/${t}}" "${t}/cache"
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want//@T@/${t}}"* ]] || { echo "${name}: no '${want}': ${output}"; return 1; }
    done <<'CASES'
real-subdir|@T@/cache/lancache|0|@T@/cache/lancache
not-yet-created|@T@/cache/not-created-yet|0|@T@/cache/not-created-yet
traversal-inside|@T@/cache/lancache/sub/../../lancache|0|@T@/cache/lancache
empty||1|is empty
relative|relative/path|1|is not an absolute path
root|/|1|outside the expected
system-dir|/etc|1|outside the expected
traversal-outside|@T@/cache/lancache/../../../etc|1|outside the expected
prefix-itself|@T@/cache|1|itself, not a subdirectory
CASES
    # What: maybe_purge refuses a dir outside its prefix
    # Why: no find or rm and no stamp so a fix retries
    # From: Issue #842 | PR #1858
    export CACHE_DIR="${t}/outside/cache" CACHE_DIR_ALLOWED_PREFIX="${t}/expected-cache-root"
    export CACHE_VALID_DAYS=30 PURGE_STAMP="${t}/purge.stamp"
    _load_retention_functions
    run maybe_purge
    [ "${status}" -eq 0 ] && [ ! -f "${PURGE_STAMP}" ] && [[ "${output}" == *"outside the expected"* ]] \
        || { echo "purge outside: rc ${status}: ${output}"; return 1; }
}

@test "retention stops promptly with rc 0 on SIGTERM mid-sleep" {
    # What: a real TERM during the interval sleep ends it.
    # Why: PID 1 bash ignored TERM; docker stop had to kill.
    # From: Issue #1683 | PR #1858
    local t="${BATS_TEST_TMPDIR}/ret" pid kid="" c rc=0
    mkdir -p "${t}/cache/lancache" "${t}/state" "${t}/log/syslog" "${t}/lib/fb"
    CACHE_DIR="${t}/cache/lancache" CACHE_DIR_ALLOWED_PREFIX="${t}/cache" \
        PURGE_STAMP="${t}/state/purge.stamp" SYSLOG_ENABLED=false \
        SYSLOG_PRUNE_STAMP="${t}/state/syslog.stamp" SYSLOG_LOG_ROOT="${t}/log/syslog" \
        SYSLOG_LOG_ROOT_ALLOWED_PREFIX="${t}/log" FLUENT_BIT_SELFLOG_DIR="${t}/lib/fb" \
        FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="${t}/lib" RETENTION_INTERVAL=60 \
        bash "${BATS_TEST_DIRNAME}/../../services/watchdog/retention.sh" > "${t}/out.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
        for c in $(cat "/proc/${pid}/task/${pid}/children" 2>&1); do
            [ "$(cat "/proc/${c}/comm" 2>&1)" = sleep ] && kid="${c}"
        done
        [ -n "${kid}" ] && break
        sleep 0.1
    done
    [ -n "${kid}" ] || { echo "never reached the sleep:"; cat "${t}/out.log"; kill "${pid}"; return 1; }
    kill -TERM "${pid}"
    for _ in $(seq 1 50); do [ -d "/proc/${pid}" ] || break; sleep 0.1; done
    [ ! -d "/proc/${pid}" ] || { echo "still running 5 s after TERM:"; cat "${t}/out.log"; kill -9 "${pid}"; return 1; }
    wait "${pid}" || rc=$?
    echo "rc=${rc}"; cat "${t}/out.log"
    [ "${rc}" -eq 0 ]
    grep -q 'retention stopping' "${t}/out.log"
    c="$(awk '{print $3}' "/proc/${kid}/stat" 2>&1)" || c=gone
    case "${c}" in Z|gone) ;; *) echo "interval sleep still alive: ${c}"; return 1 ;; esac
}

# =========================================================
# PRODUCT RUNTIME: SHARED SECRETS
# =========================================================

@test "shared secret: generated once, never rotated, fails closed, parallel writers converge" {
    # What: lib nats, dns, dhcp and ui resolve secrets with.
    # Why: AG-OP-006; reruns must not rotate stable secrets.
    # From: Issue #1683
    local lib v1 v
    lib="$(ci_context_path shared-secret)"
    # shellcheck source=scripts/lib/shared-secret-bootstrap.sh
    source "${BATS_TEST_DIRNAME}/../../${lib}"
    export LANCACHE_SHARED_SECRET_DIR="${BATS_TEST_TMPDIR}/secrets"
    LANCACHE_SHARED_SECRET_GID="$(id -g)"; export LANCACHE_SHARED_SECRET_GID
    _gen() { printf 'g\n' >> "${BATS_TEST_TMPDIR}/gen.log"; printf '%s' "$(_val name)"; }
    v1="$(resolve_shared_secret s1 "" _gen)"
    [ -n "${v1}" ]
    for _ in 1 2 3; do
        v="$(resolve_shared_secret s1 "" _gen)"
        [ "${v}" = "${v1}" ]
    done
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/gen.log")" -eq 1 ]
    for _ in 1 2; do
        v="$(resolve_shared_secret s1 real-value _gen)"
        [ "${v}" = real-value ]
        [ "$(cat "${LANCACHE_SHARED_SECRET_DIR}/s1")" = real-value ]
    done
    [ "$(resolve_shared_secret s1 "" _gen)" = real-value ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/gen.log")" -eq 1 ]
    # What: unwritable store formats and parallel writers
    # Why: services on different secrets lose their link
    # From: Issue #858 | PR #1858
    local i d="${BATS_TEST_TMPDIR}/ss"
    : > "${BATS_TEST_TMPDIR}/file"
    LANCACHE_SHARED_SECRET_DIR="${BATS_TEST_TMPDIR}/file/secrets"
    run resolve_shared_secret k "real-op" lancache_gen_hex32
    [ "${status}" -eq 0 ] && [ "${output}" = real-op ] || { echo "unwritable: rc ${status}: ${output}"; return 1; }
    run resolve_shared_secret k "real-op" lancache_gen_base64_32 require-persist
    [ "${status}" -ne 0 ] || { echo "require-persist passed: ${output}"; return 1; }
    run bash -c 'set -euo pipefail; . "$1"
        if ! v="$(resolve_shared_secret k real-op lancache_gen_hex32)"; then v=FAILED; fi
        printf "%s" "${v}"' _ "${BATS_TEST_DIRNAME}/../../${lib}"
    [ "${status}" -eq 0 ] && [ "${output}" = real-op ] || { echo "set -e: rc ${status}: ${output}"; return 1; }
    LANCACHE_SHARED_SECRET_DIR="${d}"
    mkdir -p "${d}"
    run resolve_shared_secret h "" lancache_gen_hex32
    [[ "${output}" =~ ^[0-9a-f]{64}$ ]] && [ "$(cat "${d}/h")" = "${output}" ] || { echo "hex32: ${output}"; return 1; }
    run resolve_shared_secret b "" lancache_gen_base64_32
    [ "$(printf '%s' "${output}" | base64 -d | wc -c)" -eq 32 ] || { echo "base64_32: ${output}"; return 1; }
    mkdir -p "${BATS_TEST_TMPDIR}/out"
    for i in $(seq 1 20); do
        ( v="$(resolve_shared_secret race "" lancache_gen_hex32)"; printf '%s\n' "${v}" > "${BATS_TEST_TMPDIR}/out/${i}" ) &
    done
    wait
    [ "$(sort -u "${BATS_TEST_TMPDIR}"/out/* | wc -l)" -eq 1 ] || { echo "writers disagree"; return 1; }
    [ "$(cat "${BATS_TEST_TMPDIR}/out/1")" = "$(cat "${d}/race")" ] || { echo "race file differs"; return 1; }
    [ -z "$(find "${d}" -maxdepth 1 -name '.secret.*')" ] || { echo "temp files left in ${d}"; return 1; }
}

@test "domain validator matches the parity fixture and the cdn list" {
    # What: validator vs shared fixture; cdn list is valid.
    # Why: a rejected entry silently leaves DNS spoofing.
    # From: Issue #822 | PR #1858
    local root line want dom got total=0 bad=0
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dns/domain-validation.sh
    source "${root}/services/dns/domain-validation.sh"
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        want="${line%% *}"
        dom="${line#* }"
        total=$((total + 1))
        if _is_valid_domain "${dom}"; then got=valid; else got=invalid; fi
        [ "${got}" = "${want}" ] || { echo "fixture: '${dom}' want ${want} got ${got}"; bad=$((bad + 1)); }
    done < "${root}/tests/fixtures/domain-validation-cases.txt"
    [ "${total}" -gt 0 ]
    while IFS= read -r line || [ -n "${line}" ]; do
        dom="$(_normalize_domain "${line}")"
        [[ -z "${dom}" || "${dom}" == \#* ]] && continue
        _is_valid_domain "${dom}" || { echo "cdn-domains.txt: '${line}' rejected"; bad=$((bad + 1)); }
    done < "${root}/services/dns/cdn-domains.txt"
    [ "${bad}" -eq 0 ]
    local a63 a64 l253 l254
    a63="$(printf 'a%.0s' {1..63})"
    a64="${a63}a"
    l253="${a63}.${a63}.${a63}.$(printf 'a%.0s' {1..57}).com"
    l254="${a63}.${a63}.${a63}.$(printf 'a%.0s' {1..58}).com"
    [ "${#l253}" -eq 253 ] && [ "${#l254}" -eq 254 ] || { echo "length setup"; return 1; }
    while IFS='|' read -r want dom; do
        dom="${dom//A63/${a63}}"; dom="${dom//A64/${a64}}"
        dom="${dom//L253/${l253}}"; dom="${dom//L254/${l254}}"; dom="${dom//_/ }"
        if _is_valid_domain "${dom}"; then got=valid; else got=invalid; fi
        [ "${got}" = "${want}" ] || { echo "bash-only: '${dom:0:40}' want ${want} got ${got}"; return 1; }
    done <<'CASES'
valid|a.example.com
valid|my-cache.example123.com
valid|__Example.COM__
valid|A63.example.com
valid|L253
invalid|A64.example.com
invalid|L254
invalid|
invalid|___
CASES
    [ "$(_normalize_domain '  .Example.COM ')" = example.com ]
}

# What: print a file with named functions of a script.
# Why: the caller sources it under its real source name.
# From: Issue #1683 | PR #1858
_extract_functions() {
    local file="$1" out fn
    shift
    out="$(_val path)"
    : > "${out}"
    for fn in "$@"; do
        awk -v fn="${fn}" '!c && match($0, "^ *" fn "\\(\\) [({]$") {
                c = 1; ind = substr($0, 1, index($0, fn) - 1)
                end = (substr($0, length($0)) == "{") ? "}" : ")"
            }
            c { print } c && $0 == ind end { exit }' "${file}" >> "${out}"
        grep -qE "^ *${fn}\(\) [({]$" "${out}" || { echo "function ${fn} not found in ${file}" >&2; return 1; }
    done
    printf '%s\n' "${out}"
}

@test "placeholder detection agrees across lib, setup.sh, healthcheck" {
    # What: each detector vs its shared fixture column.
    # Why: one path trusting what another rejects breaks.
    # From: Issue #967 | PR #1858
    local root fx value shared setup _r got snip ref auth f n=0
    local -a composes=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    fx="${root}/tests/fixtures/placeholder-detection-cases.txt"
    # shellcheck source=scripts/lib/shared-secret-bootstrap.sh
    source "$(_extract_functions "${root}/scripts/lib/shared-secret-bootstrap.sh" secret_is_placeholder)"
    # shellcheck source=setup.sh
    source "$(_extract_functions "${root}/setup.sh" secret_value_is_placeholder)"
    mapfile -t composes < <(grep -l 'kea-ctrl-token 2>/dev/null' "${root}"/deploy/*/docker-compose.yml)
    [ "${#composes[@]}" -ge 1 ]
    # What: the dhcp healthcheck token block, $$ unescaped.
    # Why: compose runs it in sh; it must match the lib.
    # From: Issue #967 | PR #1858
    for f in "${composes[@]}"; do
        snip="$(awk '/token="\$\$\{KEA_CTRL_TOKEN/ { c = 1 } c { sub(/^[[:space:]]+/, ""); gsub(/\$\$/, "$"); print }
            /lancache-dhcp-prod-secret/ { c = 0 }' "${f}")"
        [ -n "${snip}" ] || { echo "${f}: no token block"; return 1; }
        [ -z "${ref:-}" ] || [ "${snip}" = "${ref}" ] || { echo "${f}: block differs"; return 1; }
        ref="${snip}"
        snip="$(awk '/kea-ctrl-token 2>\/dev\/null/ { c = 1 } c { sub(/^[[:space:]]+/, ""); print } /jq -e/ { c = 0 }' "${f}")"
        [ -n "${snip}" ] || { echo "${f}: no auth block"; return 1; }
        [ -z "${auth:-}" ] || [ "${snip}" = "${auth}" ] || { echo "${f}: auth block differs"; return 1; }
        auth="${snip}"
    done
    while read -r value shared setup _r; do
        case "${value}" in ''|\#*) continue ;; esac
        n=$((n + 1))
        if secret_is_placeholder "${value}"; then got=placeholder; else got=real; fi
        [ "${got}" = "${shared}" ] || { echo "lib: ${value} got ${got} want ${shared}"; return 1; }
        if secret_value_is_placeholder "${value}"; then got=placeholder; else got=real; fi
        [ "${got}" = "${setup}" ] || { echo "setup.sh: ${value} got ${got} want ${setup}"; return 1; }
        got="$(KEA_CTRL_TOKEN="${value}" sh -c "${ref}"$'\nprintf "%s" "${token:-}"')"
        [ "${got:+real}" = "${shared/placeholder/}" ] || { echo "healthcheck: ${value} kept '${got}', lib ${shared}"; return 1; }
    done < "${fx}"
    [ "${n}" -gt 0 ]
    secret_value_is_placeholder ""
    for value in lancache-dhcp-secret lancache-dhcp-dev-secret lancache-dhcp-prod-secret; do
        [ -z "$(KEA_CTRL_TOKEN="${value}" sh -c "${ref}"$'\nprintf "%s" "${token:-}"')" ] || { echo "${value} kept"; return 1; }
    done
    [ "$(KEA_CTRL_TOKEN=lancache-dev-kea-control-token-change-me sh -c "${ref}"$'\nprintf "%s" "${token:-}"')" = lancache-dev-kea-control-token-change-me ]
}

@test "dhcp-proxy optional and pxe directives render exactly per input" {
    # What: per env set: the full rendered lines + warnings.
    # Why: a bad entry must warn, never reach dnsmasq.conf.
    # From: Issue #1683 | PR #1858
    local root c row case i r n d bf bs co s b u want warn w
    local -a ws
    local -A V=(
        ["@IF@"]="$(_val name)" ["@R@"]="$(_val host)" ["@N@"]="$(_val host)" ["@D@"]="$(_val name)"
        ["@BF@"]="$(_val name)" ["@BS@"]="$(_val host)" ["@V1@"]="$(_val name)" ["@V2@"]="$(_val name)"
        ["@V3@"]="$(_val name)" ["@V4@"]="$(_val name)"
    )
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" c="$(_val path)"
    # shellcheck source=services/dhcp-proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp-proxy/entrypoint.sh" _dhcp_proxy_reject_embedded_newline \
        _dhcp_proxy_render_optional_directives _dhcp_proxy_render_custom_options \
        _dhcp_proxy_render_pxe_service_directives)"
    # What: "." is an empty field, \n a raw newline.
    # Why: keeps every table row at ten visible fields.
    # From: Issue #1683 | PR #1858
    _v() { if [ "$1" = . ]; then printf ''; else printf '%b' "$1"; fi; }
    while IFS= read -r row; do
        IFS='|' read -r case i r n d bf bs co want warn <<< "$(_fill "${row}")"
        DHCP_PROXY_INTERFACE="$(_v "${i}")"; DHCP_PROXY_ROUTER="$(_v "${r}")"
        DHCP_NTP_SERVERS="$(_v "${n}")"; DHCP_PROXY_DOMAIN="$(_v "${d}")"
        DHCP_PROXY_BOOT_FILENAME="$(_v "${bf}")"; DHCP_PROXY_BOOT_SERVER="$(_v "${bs}")"
        DHCP_PROXY_CUSTOM_OPTIONS="$(_v "${co}")"
        export DHCP_PROXY_INTERFACE DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN \
            DHCP_PROXY_BOOT_FILENAME DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS
        [ "${want}" != . ] || want=""
        : > "${c}"
        run _dhcp_proxy_render_optional_directives "${c}"
        [ "${status}" -eq 0 ] || { echo "${case}: rc ${status}"; return 1; }
        [ "$(paste -sd'#' "${c}")" = "${want}" ] || { echo "${case}:"; cat "${c}"; return 1; }
        if [ "${warn}" = - ]; then
            [ -z "${output}" ] || { echo "${case}: unexpected ${output}"; return 1; }
            continue
        fi
        IFS='^' read -r -a ws <<< "${warn}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${case}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
none|.|.|.|.|.|.|.|.|-
basic|@IF@|@R@|@N@|@D@|.|.|.|interface=@IF@#dhcp-option-pxe=3,@R@#dhcp-option-pxe=42,@N@#dhcp-option-pxe=15,@D@|-
boot|.|.|.|.|@BF@|@BS@|.|dhcp-boot=@BF@,,@BS@|-
bootempty|.|.|.|.|@BF@|.|.|dhcp-boot=@BF@,,|-
bootsrvonly|.|.|.|.|.|@BS@|.|.|without DHCP_PROXY_BOOT_FILENAME
custom|.|.|.|.|.|.|66:@V1@;67:@V2@|dhcp-option-pxe=66,@V1@#dhcp-option-pxe=67,@V2@|-
badcode|.|.|.|.|.|.|0:@V1@;255:@V1@;ab:@V1@;66:@V2@|dhcp-option-pxe=66,@V2@|'0:@V1@': option code 0 is outside^'255:@V1@': option code 255 is outside^'ab:@V1@': option code must be numeric
nocolon|.|.|.|.|.|.|66@V1@;67:@V2@; :@V3@|dhcp-option-pxe=67,@V2@|'66@V1@' (expected CODE:VALUE)^':@V3@' (expected CODE:VALUE, both non-empty)
code6|.|.|.|.|.|.|6:@V1@|.|option code 6 (DNS servers) always collides
collide|.|@R@|.|.|.|.|3:@V1@;15:@V2@;42:@V3@|dhcp-option-pxe=3,@R@#dhcp-option-pxe=15,@V2@#dhcp-option-pxe=42,@V3@|option code 3 (router) collides with DHCP_PROXY_ROUTER
collideall|.|@R@|@N@|@D@|.|.|3:@V1@;15:@V2@;42:@V3@|dhcp-option-pxe=3,@R@#dhcp-option-pxe=42,@N@#dhcp-option-pxe=15,@D@|code 3 (router) collides^code 15 (domain name) collides^code 42 (NTP servers) collides
nliface|@V1@\n@V2@|.|.|.|.|.|.|.|DHCP_PROXY_INTERFACE contains an embedded newline
nlfield|.|@V1@\n@V2@|@N@|@V3@\n@V4@|.|.|.|dhcp-option-pxe=42,@N@|DHCP_PROXY_ROUTER contains^DHCP_PROXY_DOMAIN contains
nlboot|.|.|.|.|@V1@\n@V2@|@BS@|.|.|DHCP_PROXY_BOOT_FILENAME/DHCP_PROXY_BOOT_SERVER contains
nlcustom|.|.|.|.|.|.|60:@V1@\ndhcp-option-pxe=99,@V2@|dhcp-option-pxe=60,@V1@|-
space|.|.|.|.|.|.|  60:@V1@ @V2@  ;93:0|dhcp-option-pxe=60,@V1@ @V2@#dhcp-option-pxe=93,0|-
CASES
    # What: per BIOS/UEFI/server set: full lines + warnings.
    # Why: PXE clients need one matching boot pointer.
    # From: Issue #1683 | PR #1858
    while IFS= read -r row; do
        IFS='|' read -r case s b u want warn <<< "$(_fill "${row}")"
        [ "${s}" != . ] || s=""
        [ "${b}" != . ] || b=""
        [ "${u}" != . ] || u=""
        [ "${want}" != . ] || want=""
        DHCP_PROXY_PXE_BOOT_SERVER="$(printf '%b' "${s}")"
        DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="${b}"
        DHCP_PROXY_PXE_BOOT_FILENAME_UEFI="${u}"
        export DHCP_PROXY_PXE_BOOT_SERVER DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI
        : > "${c}"
        run _dhcp_proxy_render_pxe_service_directives "${c}"
        [ "${status}" -eq 0 ] || { echo "${case}: rc ${status}"; return 1; }
        [ "$(paste -sd'#' "${c}")" = "${want}" ] || { echo "${case}:"; cat "${c}"; return 1; }
        if [ "${warn}" = - ]; then
            [ -z "${output}" ] || { echo "${case}: unexpected ${output}"; return 1; }
        else
            [[ "${output}" == *"${warn}"* ]] || { echo "${case}: ${output}"; return 1; }
        fi
    done <<'CASES'
none|.|.|.|.|-
serveronly|@BS@|.|.|.|a boot server alone cannot produce a pxe-service directive
fileonly|.|@V1@|.|.|a boot filename alone cannot produce a pxe-service directive
bios|@BS@|@V1@|.|pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",@V1@,@BS@#dhcp-match=set:lancache-pxe-bios,option:client-arch,0#dhcp-boot=tag:lancache-pxe-bios,@V1@,,@BS@|-
uefi|@BS@|.|@V2@|dhcp-match=set:lancache-pxe-uefi,option:client-arch,7#dhcp-match=set:lancache-pxe-uefi,option:client-arch,11#dhcp-boot=tag:lancache-pxe-uefi,@V2@,,@BS@#pxe-service=IA64_EFI,"lancache-ng PXE proxy active",0|-
both|@BS@|@V1@|@V2@|pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",@V1@,@BS@#dhcp-match=set:lancache-pxe-bios,option:client-arch,0#dhcp-boot=tag:lancache-pxe-bios,@V1@,,@BS@#dhcp-match=set:lancache-pxe-uefi,option:client-arch,7#dhcp-match=set:lancache-pxe-uefi,option:client-arch,11#dhcp-boot=tag:lancache-pxe-uefi,@V2@,,@BS@|-
newline|@BS@\ndhcp-boot=injected,,@V3@|@V1@|.|.|embedded newline
CASES
}

@test "ntp config renders and validates exactly per input" {
    # What: server/pool/allow lines per input; validator.
    # Why: chrony denies all clients without an allow line.
    # From: Issue #1683 | PR #1858
    local root t c row case up allow want vrc vmsg
    local -A V=(
        ["@H1@"]="$(_val host)" ["@H2@"]="$(_val host)" ["@I4A@"]="$(_val ipv4)" ["@I4B@"]="$(_val ipv4)"
        ["@I6@"]="$(_val ipv6)" ["@C1@"]="$(_val cidr)" ["@C2@"]="$(_val cidr)"
        ["@D@"]="$(_val int 0 9).$(_val host).$(_val host)"
        ["@T@"]="$(_val int 0 255).$(_val int 0 255).$(_val int 0 255)"
    )
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    t="${root}/services/ntp/chrony.conf" c="$(_val path)"
    # shellcheck source=services/ntp/entrypoint.sh
    source "$(_extract_functions "${root}/services/ntp/entrypoint.sh" is_ip_literal render_ntp_config validate_ntp_config)"
    while IFS= read -r row; do
        IFS='|' read -r case NTP_UPSTREAM_SERVERS NTP_ALLOWED_CLIENT_CIDRS up allow vrc vmsg <<< "$(_fill "${row}")"
        [ "${NTP_UPSTREAM_SERVERS}" != . ] || NTP_UPSTREAM_SERVERS=""
        [ "${NTP_ALLOWED_CLIENT_CIDRS}" != . ] || NTP_ALLOWED_CLIENT_CIDRS=""
        export NTP_UPSTREAM_SERVERS NTP_ALLOWED_CLIENT_CIDRS
        render_ntp_config "${c}" "${t}"
        want="$(paste -sd'#' "${t}")##"
        want+="# Upstream servers (NTP_UPSTREAM_SERVERS) -- rendered at container start."
        [ "${up}" = . ] || want+="#${up}"
        want+="### LAN client access (NTP_ALLOWED_CLIENT_CIDRS) -- rendered at container start."
        [ "${allow}" = . ] || want+="#${allow}"
        [ "$(paste -sd'#' "${c}")" = "${want}" ] || { echo "${case}:"; cat "${c}"; return 1; }
        run validate_ntp_config "${c}"
        [ "${status}" -eq "${vrc}" ] || { echo "${case}: validate rc ${status}"; return 1; }
        [[ "${output}" == *"${vmsg}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
pool|@H1@ @D@ @T@|.|pool @H1@ iburst#pool @D@ iburst#pool @T@ iburst|allow 0.0.0.0/0#allow ::/0|0|
literal|@I4A@ @I6@|.|server @I4A@ iburst#server @I6@ iburst|allow 0.0.0.0/0#allow ::/0|0|
cidrs|@I4B@ @H2@|@C1@ @C2@|server @I4B@ iburst#pool @H2@ iburst|allow @C1@#allow @C2@|0|
noserver|.|@C1@|.|allow @C1@|1|no pool/server directive
blankcidrs|@H2@| |pool @H2@ iburst|.|1|no allow directive
CASES
}

@test "dhcp kea ipv4 and ntp helpers per input" {
    _stand_ins || return 1
    # What: ipv4 checks, ntp name lookup, kea ntp option.
    # Why: kea needs ipv4 ntp data; a bad value must stop.
    # From: Issue #1683 | PR #1858
    local root bin="${BIN}" e
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dhcp/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp/entrypoint.sh" is_ipv4 is_ipv4_csv resolve_ntp_server \
        resolve_ntp_csv build_ntp_option)"
    for e in 192.168.1.1 8.8.8.8 0.0.0.0 255.255.255.255 010.1.1.1; do
        is_ipv4 "${e}" || { echo "${e} rejected"; return 1; }
    done
    for e in 256.1.1.1 1.1.1 1.1.1.1.1 1..1.1 not-an-ip "" " 1.1.1.1" 1.1.1.-1; do
        if is_ipv4 "${e}"; then echo "'${e}' accepted"; return 1; fi
    done
    for e in 192.168.1.1 8.8.8.8,1.1.1.1 1.1.1.1,,8.8.8.8; do
        is_ipv4_csv "${e}" || { echo "csv ${e} rejected"; return 1; }
    done
    for e in "" "," 1.1.1.1,not-an-ip 256.256.256.256; do
        if is_ipv4_csv "${e}"; then echo "csv '${e}' accepted"; return 1; fi
    done
    _tool_stub "${bin}" getent <<'STUB'
case "$1 $2" in
    "ahostsv4 ntp.lan") printf '10.0.0.9 STREAM ntp.lan\n10.0.0.9 DGRAM\n' ;;
    "hosts old.lan") printf '10.0.0.8 old.lan\n' ;;
    "hosts v6.lan") printf 'fd00::1 v6.lan\n' ;;
    *) exit 2 ;;
esac
STUB
    export PATH="${bin}:${PATH}"
    [ "$(resolve_ntp_server 8.8.8.8)" = 8.8.8.8 ]
    [ "$(resolve_ntp_server ntp.lan)" = 10.0.0.9 ]
    [ "$(resolve_ntp_server old.lan)" = 10.0.0.8 ]
    for e in "" 256.256.256.256 v6.lan nowhere.lan; do
        run resolve_ntp_server "${e}"
        [ "${status}" -eq 1 ] || { echo "'${e}' resolved to ${output}"; return 1; }
    done
    [[ "${output}" == *"cannot be resolved: nowhere.lan"* ]]
    [ "$(resolve_ntp_csv '8.8.8.8 ntp.lan,old.lan')" = 8.8.8.8,10.0.0.9,10.0.0.8 ]
    [ -z "$(resolve_ntp_csv '')" ]
    run resolve_ntp_csv '8.8.8.8 nowhere.lan'
    [ "${status}" -eq 1 ]
    [ "$(DHCP_NTP_SERVERS="8.8.8.8 ntp.lan" build_ntp_option)" = "$(printf ',\n          {\n            "name": "ntp-servers",\n            "data": "8.8.8.8,10.0.0.9"\n          }')" ]
    [ -z "$(DHCP_NTP_SERVERS="" build_ntp_option)" ]
    DHCP_NTP_SERVERS="nowhere.lan" run build_ntp_option
    [ "${status}" -eq 1 ]
}

@test "dhcp kea templates render complete valid json" {
    # What: dhcp4, ctrl-agent, d2 from the real var list.
    # Why: a missed var or bad port stops kea from starting.
    # From: Issue #1683 | PR #1858
    local root ep dns zones key alg n1 n2 row port rc want j4 jc jd ps
    local -A V=(["@P@"]="$(_val port)")
    j4="$(_val path)" jc="$(_val path)" jd="$(_val path)" ps="$(_val path)"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ep="${root}/services/dhcp/entrypoint.sh"
    dns="${root}/services/dns/entrypoint.sh"
    # shellcheck source=services/dhcp/entrypoint.sh
    source "$(_extract_functions "${ep}" is_ipv4 is_ipv4_csv resolve_ntp_server resolve_ntp_csv build_ntp_option \
        render_kea_config render_kea_dhcp4_config)"
    eval "$(grep -m1 '^ENVSUBST_VARS=' "${ep}")"
    [ -n "${ENVSUBST_VARS}" ]
    n1="$(_val ipv4)" n2="$(_val ipv4)"
    DHCP_SUBNET="$(_val cidr)" DHCP_RANGE_START="$(_val ipv4)" DHCP_RANGE_END="$(_val ipv4)"
    DHCP_GATEWAY="$(_val ipv4)" DHCP_DOMAIN="$(_val host)" DHCP_LEASE_TIME="$(_val int 60 99999)"
    DHCP_MAX_LEASE_TIME="$(_val int 60 99999)" DHCP_NTP_SERVERS="${n1} ${n2}" DHCP_DNS_PRIMARY="$(_val ipv4)"
    DHCP_DNS_SECONDARY="$(_val ipv4)" DHCP_DNS_SERVER_IP="$(_val ipv4)" DHCP_DDNS_PORT="$(_val port)"
    KEA_CTRL_TOKEN="$(_val name)" KEA_CTRL_HOST="$(_val ipv4)" DDNS_TSIG_KEY="$(_val name | base64)"
    KEA_LEASE_CMDS_HOOK_PATH="$(_val path)"
    export DHCP_SUBNET DHCP_RANGE_START DHCP_RANGE_END DHCP_GATEWAY DHCP_DOMAIN DHCP_LEASE_TIME \
        DHCP_MAX_LEASE_TIME DHCP_NTP_SERVERS DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY DHCP_DNS_SERVER_IP \
        DHCP_DDNS_PORT KEA_CTRL_TOKEN KEA_CTRL_HOST DDNS_TSIG_KEY KEA_LEASE_CMDS_HOOK_PATH
    mkdir -p "${d}"
    for DHCP_DDNS_ENABLED in true false; do
        export DHCP_DDNS_ENABLED
        render_kea_dhcp4_config "${root}/services/dhcp/kea-dhcp4.conf" "${j4}"
        run jq -e --argjson on "${DHCP_DDNS_ENABLED}" --arg sub "${DHCP_SUBNET}" \
            --arg pool "${DHCP_RANGE_START} - ${DHCP_RANGE_END}" --argjson lt "${DHCP_LEASE_TIME}" \
            --argjson mlt "${DHCP_MAX_LEASE_TIME}" --arg ntp "${n1},${n2}" --arg hook "${KEA_LEASE_CMDS_HOOK_PATH}" \
            --arg dom "${DHCP_DOMAIN}" '.Dhcp4 as $d | $d.subnet4[0] as $s
            | $s.subnet == $sub and $s.pools[0].pool == $pool
            and $s["valid-lifetime"] == $lt and $s["max-valid-lifetime"] == $mlt
            and ([$s["option-data"][] | select(.name == "ntp-servers") | .data] == [$ntp])
            and $d["hooks-libraries"] == [{"library": $hook}]
            and $d["dhcp-ddns"]["enable-updates"] == $on and $d["ddns-qualifying-suffix"] == $dom' \
            "${j4}"
        [ "${status}" -eq 0 ] || { echo "dhcp4 ddns=${DHCP_DDNS_ENABLED}: ${output}"; return 1; }
    done
    DHCP_NTP_SERVERS="" render_kea_dhcp4_config "${root}/services/dhcp/kea-dhcp4.conf" "${j4}"
    jq -e '[.Dhcp4.subnet4[0]["option-data"][] | select(.name == "ntp-servers")] == []' "${j4}"
    render_kea_config "${root}/services/dhcp/kea-ctrl-agent.conf" "${jc}"
    jq -e --arg host "${KEA_CTRL_HOST}" --arg tok "${KEA_CTRL_TOKEN}" '.["Control-agent"]
        | .["http-host"] == $host and .authentication.type == "basic"
        and [.authentication.clients[].password] == [$tok]' "${jc}"
    render_kea_config "${root}/services/dhcp/kea-dhcp-ddns.conf" "${d}/d2.json"
    run grep -n '\${' "${j4}" "${jc}" "${d}/d2.json"
    [ "${status}" -eq 1 ] || { echo "unrendered: ${output}"; return 1; }
    zones="$(awk '/^PRIVATE_REVERSE_ZONES=\(/,/^\)/' "${dns}" \
        | grep -oE '[0-9a-z.]+\.in-addr\.arpa\.' | jq -Rsc 'split("\n") | map(select(. != "")) | sort')"
    [ "$(jq length <<< "${zones}")" -gt 0 ]
    key="$(sed -n 's/^DDNS_TSIG_NAME="\${DDNS_TSIG_NAME:-\([^}]*\)}"$/\1/p' "${dns}")"
    alg="$(sed -n 's/^DDNS_TSIG_ALGORITHM="\${DDNS_TSIG_ALGORITHM:-\([^}]*\)}"$/\1/p' "${dns}")"
    [ -n "${key}" ] || { echo "no DDNS_TSIG_NAME default in ${dns}"; return 1; }
    [ -n "${alg}" ] || { echo "no DDNS_TSIG_ALGORITHM default in ${dns}"; return 1; }
    run jq -e --slurpfile d4 "${j4}" --argjson zones "${zones}" --arg key "${key}" --arg alg "${alg}" \
        --arg tsig "${DDNS_TSIG_KEY}" --arg dom "${DHCP_DOMAIN}." --arg ip "${DHCP_DNS_SERVER_IP}" \
        --argjson port "${DHCP_DDNS_PORT}" '.DhcpDdns as $d | $d4[0].Dhcp4["dhcp-ddns"] as $s
        | [$d["tsig-keys"][] | [.name, (.algorithm | ascii_downcase), .secret]] == [[$key, ($alg | ascii_downcase), $tsig]]
        and $d.port == $s["server-port"] and $d["ip-address"] == $s["server-ip"]
        and $d["forward-ddns"]["ddns-domains"][0].name == $dom
        and ([$d["reverse-ddns"]["ddns-domains"][].name] | sort) == $zones
        and ([$d["forward-ddns", "reverse-ddns"]["ddns-domains"][] | .["key-name"]] | unique) == [$key]
        and ([$d["forward-ddns", "reverse-ddns"]["ddns-domains"][]["dns-servers"]
            | length == 1 and .[0] == {"ip-address": $ip, "port": $port}] | all)' "${d}/d2.json"
    [ "${status}" -eq 0 ] || { echo "d2: ${output}"; return 1; }
    sed -n '/^: "\${DHCP_DDNS_PORT:=/,/^fi$/p' "${ep}" > "${d}/port.sh"
    [ -s "${d}/port.sh" ]
    while IFS= read -r row; do
        IFS='|' read -r port rc want <<< "$(_fill "${row}")"
        run env DHCP_DDNS_PORT="${port}" bash -c ". '${d}/port.sh' && echo \"ok \${DHCP_DDNS_PORT}\""
        [ "${status}" -eq "${rc}" ] || { echo "port '${port}': rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "port '${port}': ${output}"; return 1; }
    done <<'CASES'
|0|ok
@P@|0|ok @P@
1|0|ok 1
65535|0|ok 65535
0|1|must be between 1 and 65535 (got: 0)
65536|1|must be between 1 and 65535 (got: 65536)
@P@a|1|must be a numeric TCP/UDP port (got: @P@a)
-@P@|1|must be a numeric TCP/UDP port (got: -@P@)
CASES
}

@test "dhcp kea runtime config migration converges" {
    _stand_ins || return 1
    # What: stale hook, old lease keys, ntp names migrated.
    # Why: an old volume must load and converge on restart.
    # From: Issue #1683 | PR #1858
    local root r="${BATS_TEST_TMPDIR}/kea-dhcp4.conf" bin="${BIN}"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dhcp/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp/entrypoint.sh" is_ipv4 is_ipv4_csv resolve_ntp_server \
        resolve_ntp_csv build_ntp_migration_map migrate_dhcp4_config)"
    _tool_stub "${bin}" getent <<'STUB'
[ "$1 $2" = "ahostsv4 ntp.lan" ] || exit 2
printf '10.0.0.9 STREAM ntp.lan\n'
STUB
    export PATH="${bin}:${PATH}" DHCP_DOMAIN=lan DHCP_LEASE_TIME=86400 DHCP_MAX_LEASE_TIME=172800 \
        DHCP_DDNS_ENABLED=false KEA_LEASE_CMDS_HOOK_PATH=/usr/lib/kea/hooks/libdhcp_lease_cmds.so
    cat > "${r}" <<'JSON'
{"Dhcp4": {"control-socket": {"socket-type": "unix", "socket-name": "/old/kea4.sock"},
  "hooks-libraries": [{"library": "/usr/lib/x86_64-linux-gnu/kea/hooks/libdhcp_lease_cmds.so"},
    {"library": "/usr/lib/kea/hooks/libother.so"}],
  "subnet4": [{"id": 1, "subnet": "10.0.0.0/24", "default-lease-time": 600, "max-lease-time": 1200,
    "option-data": [{"name": "ntp-servers", "data": "ntp.lan"},
      {"name": "ntp-servers", "data": "0a000009", "csv-format": false}]}],
  "loggers": []}}
JSON
    run migrate_dhcp4_config "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Updated ${r}"* ]]
    run jq -e '.Dhcp4 as $d | $d.subnet4[0] as $s
        | $d["control-socket"]["socket-name"] == "/run/kea/kea4.sock"
        and $d["hooks-libraries"] == [{"library": "/usr/lib/kea/hooks/libother.so"},
            {"library": "/usr/lib/kea/hooks/libdhcp_lease_cmds.so"}]
        and $s["valid-lifetime"] == 600 and $s["max-valid-lifetime"] == 1200
        and ($s | has("default-lease-time") or has("max-lease-time") | not)
        and [$s["option-data"][].data] == ["10.0.0.9", "0a000009"]
        and $d["dhcp-ddns"]["enable-updates"] == false and $d["ddns-qualifying-suffix"] == "lan"
        and [$d.loggers[] | select(.name == "kea-dhcp4.dhcp4") | .severity] == ["ERROR"]' "${r}"
    [ "${status}" -eq 0 ] || { cat "${r}"; return 1; }
    cp "${r}" "${r}.first"
    run migrate_dhcp4_config "${r}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ] || { echo "second run changed: ${output}"; return 1; }
    cmp "${r}" "${r}.first"
    jq '.Dhcp4.subnet4[0]["option-data"][0].data = "nowhere.lan"' "${r}.first" > "${r}"
    run migrate_dhcp4_config "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"failed to resolve legacy NTP server values"* ]]
}

@test "proxy CA, cert dir and CA rotation behave per state" {
    # What: CA key mode and subject, cert dir, leaf purge.
    # Why: a rotated CA must never keep serving old leafs.
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" gen fp1 fp2 h1
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _ensure_ca_cert _harden_cert_dir \
        _purge_stale_leaf_certs_on_ca_change)"
    export CA_DIR="${t}/ca" CERT_DIR="${t}/certs"
    run _ensure_ca_cert
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [ "$(stat -c '%a' "${CA_DIR}/ca.key")" = 600 ]
    mkdir -p "${t}/gen"
    cp "${root}/certs/generate-ca.sh" "${t}/gen/"
    bash "${t}/gen/generate-ca.sh" > /dev/null 2>&1
    gen="$(openssl x509 -noout -subject -in "${t}/gen/ca.crt")"
    [ "$(openssl x509 -noout -subject -in "${CA_DIR}/ca.crt")" = "${gen}" ] || {
        echo "proxy CA $(openssl x509 -noout -subject -in "${CA_DIR}/ca.crt") vs generate-ca.sh ${gen}"; return 1; }
    [[ "${gen}" == *"LanCache-NG"* ]]
    h1="$(sha256sum < "${CA_DIR}/ca.key")"
    _ensure_ca_cert
    [ "$(sha256sum < "${CA_DIR}/ca.key")" = "${h1}" ]
    rm -rf "${CA_DIR}"
    run bash -c "$(declare -f _ensure_ca_cert)
        openssl() { local p='' a k='' c=''; for a in \"\$@\"; do
            case \"\${p}\" in -keyout) k=\"\${a}\" ;; -out) c=\"\${a}\" ;; esac; p=\"\${a}\"; done
            echo key > \"\${k}\"; echo crt > \"\${c}\"; chmod 644 \"\${k}\"; }
        _ensure_ca_cert >/dev/null; stat -c %a '${CA_DIR}/ca.key'"
    [ "${output}" = 600 ] || { echo "insecure key kept: ${output}"; return 1; }
    rm -rf "${CA_DIR}"
    _ensure_ca_cert > /dev/null
    for h1 in 1 2; do
        _harden_cert_dir "$(id -g)"
        [ "$(stat -c '%a %g' "${CERT_DIR}")" = "2750 $(id -g)" ] || { echo "pass ${h1}: $(stat -c '%a %g' "${CERT_DIR}")"; return 1; }
        echo leaf > "${CERT_DIR}/kept-${h1}.crt"
    done
    [ -f "${CERT_DIR}/kept-1.crt" ]
    printf 'x' | tee "${CERT_DIR}/a.crt" "${CERT_DIR}/a.key" "${CERT_DIR}/.marker" "${CERT_DIR}/notes.txt" > /dev/null
    _purge_stale_leaf_certs_on_ca_change
    [ "$(cd "${CERT_DIR}" && ls -A | sort | paste -sd' ')" = ".ca-fingerprint .marker notes.txt" ] || {
        echo "first run: $(ls -A "${CERT_DIR}")"; return 1; }
    fp1="$(cat "${CERT_DIR}/.ca-fingerprint")"
    [[ "${fp1}" == *"Fingerprint="* ]]
    echo leaf > "${CERT_DIR}/b.crt"
    echo key > "${CERT_DIR}/b.key"
    _purge_stale_leaf_certs_on_ca_change
    [ -f "${CERT_DIR}/b.crt" ] && [ -f "${CERT_DIR}/b.key" ] || { echo "same CA purged leafs"; return 1; }
    rm -f "${CA_DIR}/ca.crt" "${CA_DIR}/ca.key"
    _ensure_ca_cert > /dev/null
    _purge_stale_leaf_certs_on_ca_change
    [ ! -e "${CERT_DIR}/b.crt" ] && [ ! -e "${CERT_DIR}/b.key" ] || { echo "rotated CA kept leafs"; return 1; }
    fp2="$(cat "${CERT_DIR}/.ca-fingerprint")"
    [ "${fp1}" != "${fp2}" ]
    [ -f "${CERT_DIR}/.marker" ]
}

@test "proxy leaf signing and default cert regen per input" {
    # What: _sign_cert output and cleanup; regen decision.
    # Why: a bad leaf or a stale default cert breaks TLS.
    # From: Issue #1683 | PR #1858
    local root ep s1 s2 p case at now san want row long w x base o d a dn hx hy hz srl miss
    local k1 c1 k2 c2 k3 c3 kd c4 k5 c5 k6 c6
    local -a pre post
    d="$(_val host).$(_val host)" a="$(_val host).$(_val host)" dn="$(_val host)"
    hx="$(_val host).$(_val host)" hy="$(_val host).$(_val host)" hz="$(_val host).$(_val host)"
    base="$(_val int 0 255).$(_val int 0 255).$(_val int 0 255)" o="$(_val int 1 25)"
    local -A V=(["@DN@"]="${dn}" ["@PA@"]="${base}.${o}" ["@PB@"]="${base}.${o}1" ["@PC@"]="$(_val ipv4)")
    srl="$(_val path)" miss="$(_val path)"
    k1="$(_val path)" c1="$(_val path)" k2="$(_val path)" c2="$(_val path)" k3="$(_val path)" c3="$(_val path)"
    kd="$(_val path)" c4="$(_val path)" k5="$(_val path)" c5="$(_val path)" k6="$(_val path)" c6="$(_val path)"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ep="${root}/services/proxy/entrypoint.sh"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${ep}" _ensure_ca_cert _sign_cert _default_cert_needs_regen _bounded_cert_name)"
    CA_DIR="$(_val path)" CERT_DIR="$(_val path)"
    export CA_DIR CERT_DIR
    mkdir -p "${CERT_DIR}"
    run _ensure_ca_cert
    [ "${status}" -eq 0 ] || { echo "ca: ${output}"; return 1; }
    sed -n '/^    SERIAL_FILE="\$CA_DIR\/ca\.srl"$/,/^    fi$/p' "${ep}" > "${srl}"
    [ -s "${srl}" ]
    # shellcheck source=services/proxy/entrypoint.sh
    source "${srl}"
    shopt -s nullglob
    pre=(/var/tmp/lancache-cert.*)
    _sign_cert "${d}" "${k1}" "${c1}" "subjectAltName=DNS:${d},DNS:*.${d}"
    openssl verify -CAfile "${CA_DIR}/ca.crt" "${c1}"
    [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "${c1}")" = "subject=CN=lancache-ng" ]
    [ "$(openssl x509 -noout -ext subjectAltName -in "${c1}" | tail -n +2 | tr -d ' ')" = "DNS:${d},DNS:*.${d}" ]
    s1="$(openssl x509 -noout -serial -in "${c1}" | cut -d= -f2)"
    _sign_cert "$(printf 'a%.0s' {1..300})" "${k2}" "${c2}"
    [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "${c2}")" = "subject=CN=lancache-ng" ]
    [ -z "$(openssl x509 -noout -ext subjectAltName -in "${c2}" 2>/dev/null)" ]
    s2="$(openssl x509 -noout -serial -in "${c2}" | cut -d= -f2)"
    [ $((16#${s2})) -gt $((16#${s1})) ] || { echo "serial ${s2} not above ${s1}"; return 1; }
    grep -qxE '[0-9A-Fa-f]+' "${SERIAL_FILE}"
    long="$(printf 'a%.0s' {1..60})"
    long="${long}.${long}.${long}.${long}"
    _sign_cert "${long}" "${k3}" "${c3}" "subjectAltName=DNS:*.${long}"
    [ "$(openssl x509 -noout -ext subjectAltName -in "${c3}" | tail -n +2 | tr -d ' ')" = "DNS:*.${long}" ]
    w="$(_bounded_cert_name "${long}" wildcard)"
    x="$(_bounded_cert_name "${long}" exact)"
    [[ "${w}" =~ ^[0-9a-f]{32}$ && "${x}" =~ ^[0-9a-f]{32}$ && "${w}" != "${x}" ]] || { echo "names ${w} ${x}"; return 1; }
    [ "$(_bounded_cert_name "${long}" wildcard)" = "${w}" ]
    [[ "$(_bounded_cert_name "${a}" exact)" =~ ^[0-9a-f]{32}$ ]]
    mkdir "${kd}" "${c5}"
    run _sign_cert "${hx}" "${kd}" "${c4}" "subjectAltName=DNS:${hx}"
    [ "${status}" -ne 0 ]
    [ ! -e "${c4}" ]
    run _sign_cert "${hy}" "${k5}" "${c5}" "subjectAltName=DNS:${hy}"
    [ "${status}" -ne 0 ]
    [ ! -e "${k5}" ] || { echo "orphaned key after a sign failure"; return 1; }
    echo partial > "${c6}"
    CA_DIR="${miss}" run _sign_cert "${hz}" "${k6}" "${c6}"
    [ "${status}" -ne 0 ]
    [ ! -e "${c6}" ] && [ ! -e "${k6}" ] || { echo "partial output kept"; return 1; }
    while IFS= read -r row; do
        IFS='|' read -r case at now san want <<< "$(_fill "${row}")"
        rm -f "${CERT_DIR}/default.crt" "${CERT_DIR}/default.key"
        if [ "${san}" != none ]; then
            IP_SSL="${at}" _sign_cert "${dn}" "${CERT_DIR}/default.key" "${CERT_DIR}/default.crt" \
                "${san:+subjectAltName=${san}}"
        fi
        [ "${case}" != nokey ] || rm -f "${CERT_DIR}/default.key"
        IP_SSL="${now}" run _default_cert_needs_regen
        [ "${status}" -eq "${want}" ] || { echo "${case}: rc ${status}"; return 1; }
    done <<'CASES'
missing|||none|0
nokey|||DNS:@DN@|0
nosan||||0
exact|@PA@|@PA@|DNS:@DN@,IP:@PA@|1
prefix|@PB@|@PA@|DNS:@DN@,IP:@PB@|0
unrelated|@PC@|@PA@|DNS:@DN@,IP:@PC@|0
dnsonly|||DNS:@DN@|1
ipnowempty|@PC@||DNS:@DN@,IP:@PC@|1
CASES
    post=(/var/tmp/lancache-cert.*)
    p="$(comm -13 <(printf '%s\n' "${pre[@]}" | sort) <(printf '%s\n' "${post[@]}" | sort))"
    [ -z "${p}" ] || { echo "csr left: ${p}"; return 1; }
    run awk '/^_bounded_cert_name\(\) \{$/ && !d { d = NR }
        /^if \[ "\$\{SSL_ENABLED\}" = "1" \]; then$/ && !s { s = NR }
        END { print (d && s && d < s) ? "before" : "d=" d " s=" s }' "${root}/services/proxy/entrypoint.sh"
    [ "${output}" = before ]
}

@test "proxy registrable domain per public suffix rule" {
    # What: normal, compound, wildcard and exception rules.
    # Why: a wrong root shares one cert across owners.
    # From: Issue #1683 | PR #1858
    local root case dom want
    local -A _PSL_RULES=() _PSL_WILDCARDS=() _PSL_EXCEPTIONS=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _load_public_suffix_list _suffix_from_end \
        _registrable_domain)"
    PUBLIC_SUFFIX_LIST_FILE="${root}/services/proxy/public_suffix_list.dat" _load_public_suffix_list
    [ "${#_PSL_RULES[@]}" -gt 1000 ] && [ "${#_PSL_EXCEPTIONS[@]}" -gt 0 ] || { echo "psl not loaded"; return 1; }
    while IFS='|' read -r case dom want; do
        run _registrable_domain "${dom}"
        if [ "${want}" = - ]; then
            [ "${status}" -ne 0 ] || { echo "${case}: got ${output}"; return 1; }
        else
            [ "${status}" -eq 0 ] && [ "${output}" = "${want}" ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        fi
    done <<'CASES'
plain|cdn.steamcontent.com|steamcontent.com
plainroot|steamcontent.com|steamcontent.com
compound|cdn.example.co.uk|example.co.uk
compoundroot|example.co.uk|example.co.uk
compoundbare|co.uk|-
tld|com|-
exception|city.kawasaki.jp|city.kawasaki.jp
exceptionsub|cdn.city.kawasaki.jp|city.kawasaki.jp
wildcardbare|example.kawasaki.jp|-
wildcardmin|sub.example.kawasaki.jp|sub.example.kawasaki.jp
wildcarddeep|cdn.sub.example.kawasaki.jp|sub.example.kawasaki.jp
private|cdn.user.github.io|github.io
unlisted|cdn.example.zzzq|example.zzzq
CASES
}

@test "proxy ssl map, stream map and client acl render exactly per mode and input" {
    # What: cert map, host allowlist, client geo per input.
    # Why: strict mode and client CIDRs deny by default.
    # From: Issue #1683 | PR #1858
    local root want wb xh fb head r n bd xd c1 c2 sni='$ssl_preread_server_name'
    local -a _UNIQUE_DOMAINS=() _EXTRA_WILDCARD_BASES=() _EXTRA_EXACT_HOSTS=()
    local -A _DOMAIN_IS_ROOT=()
    r="$(_val host).$(_val host)" n="$(_val host).$(_val host).$(_val host)"
    bd="$(_val host).$(_val host).$(_val host)" xd="$(_val host).$(_val host).$(_val host)"
    c1="$(_val cidr)" c2="$(_val cidr)"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _bounded_cert_name _render_ssl_map)"
    _r() { set -euo pipefail; _render_ssl_map | tr -s ' ' | paste -sd'#'; }
    PROXY_SECURITY_MODE=lazy PROXY_ALLOWED_CLIENT_CIDRS="" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = '# Auto-generated by entrypoint — do not edit#map $ssl_server_name $ssl_cert_name {# hostnames;# default default;#}##map $host $cdn_host_allowed {# hostnames;# default 1;#}##geo $lancache_client_allowed {# default 1;#}' ] || {
        echo "lazy empty: ${output}"; return 1; }
    _UNIQUE_DOMAINS=("${r}" "${n}")
    _DOMAIN_IS_ROOT=(["${r}"]=1 ["${n}"]=0)
    _EXTRA_WILDCARD_BASES=("${bd}")
    _EXTRA_EXACT_HOSTS=("${xd}")
    wb="$(_bounded_cert_name "${bd}" wildcard)"
    xh="$(_bounded_cert_name "${xd}" exact)"
    want="# Auto-generated by entrypoint — do not edit#map \$ssl_server_name \$ssl_cert_name {# hostnames;"
    want+="# *.${r} ${r};# ${r} ${r};# *.${n} ${n};# *.${bd} ${wb};# ${xd} ${xh};"
    want+="# default default;#}##map \$host \$cdn_host_allowed {# hostnames;"
    PROXY_SECURITY_MODE=lazy PROXY_ALLOWED_CLIENT_CIDRS="${c1} ${c2}" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = "${want}# default 1;#}##geo \$lancache_client_allowed {# default 0;# ${c1} 1;# ${c2} 1;#}" ] || {
        echo "lazy cidrs: ${output}"; return 1; }
    PROXY_SECURITY_MODE=strict PROXY_ALLOWED_CLIENT_CIDRS="" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = "${want}# default 0;# *.${r} 1;# ${r} 1;# *.${n} 1;# *.${bd} 1;# ${xd} 1;#}##geo \$lancache_client_allowed {# default 1;#}" ] || {
        echo "strict: ${output}"; return 1; }
    # What: SNI backend map per mode; stream client ACL.
    # Why: empty SNI and unlisted hosts never reach :443.
    # From: Issue #1683 | PR #1858
    _r() { set -euo pipefail; "$@" | tr -s ' ' | paste -sd'#'; }
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _render_stream_backend_map _render_stream_client_acl)"
    eval "$(grep -m1 '^STREAM_EMPTY_SNI_BACKEND=' "${root}/services/proxy/entrypoint.sh")"
    fb="${STREAM_EMPTY_SNI_BACKEND}"
    [[ "${fb}" =~ ^127\.0\.0\.1:[0-9]+$ ]]
    head="# Auto-generated by entrypoint — do not edit#map ${sni} \$stream_backend {# hostnames;# \"\" ${fb};"
    PROXY_SECURITY_MODE=lazy run _r _render_stream_backend_map
    [ "${output}" = "${head}# default ${sni}:443;#}" ] || { echo "lazy: ${output}"; return 1; }
    PROXY_SECURITY_MODE=strict run _r _render_stream_backend_map
    [ "${output}" = "${head}# default ${fb};# *.${r} ${sni}:443;# ${r} ${sni}:443;# *.${n} ${sni}:443;# *.${bd} ${sni}:443;# ${xd} ${xd}:443;#}" ] || {
        echo "strict: ${output}"; return 1; }
    PROXY_ALLOWED_CLIENT_CIDRS="" run _r _render_stream_client_acl
    [ "${output}" = "# Auto-generated by entrypoint — do not edit" ] || { echo "acl empty: ${output}"; return 1; }
    PROXY_ALLOWED_CLIENT_CIDRS="${c1} ${c2}" run _r _render_stream_client_acl
    [ "${output}" = "# Auto-generated by entrypoint — do not edit#allow ${c1};#allow ${c2};#deny all;" ] || {
        echo "acl cidrs: ${output}"; return 1; }
}

@test "setup bootstrap ref pins the checkout per ref kind" {
    # What: tag, branch, commit, unknown ref, dirty tree
    # Why: an operator ref must pin exactly that revision
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" main tagsha brsha mainsha ref want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    TAG="v$(cat "${root}/VERSION")"
    export T="${t}" TAG BR="b${BATS_TEST_NUMBER}" REF
    main="$(declare -f git_default_branch_name | sed -n 's/.*default_branch:-\([A-Za-z0-9_-]*\)}.*/\1/p')"
    [ -n "${main}" ] || { echo "no fallback branch in git_default_branch_name"; return 1; }
    g() { git -c user.email=t@example.test -c user.name=t -c init.defaultBranch="${main}" "$@"; }
    g init -q --bare "${t}/origin.git"
    g init -q "${t}/src"
    g -C "${t}/src" commit -q --allow-empty -m c1
    g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}"
    g -C "${t}/src" tag "${TAG}"
    g -C "${t}/src" push -q "${t}/origin.git" "${TAG}"
    g -C "${t}/src" commit -q --allow-empty -m c2
    g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}"
    mainsha="$(g -C "${t}/src" rev-parse HEAD)"
    tagsha="$(g -C "${t}/src" rev-parse "${TAG}^{commit}")"
    g -C "${t}/src" checkout -q -b "${BR}"
    g -C "${t}/src" commit -q --allow-empty -m d1
    g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${BR}"
    brsha="$(g -C "${t}/src" rev-parse HEAD)"
    g clone -q "${t}/origin.git" "${t}/co"
    _setup_sh_run 'unset LANCACHE_SETUP_GIT_REF; resolve_setup_bootstrap_ref'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "unset ref: ${output}"; return 1; }
    _setup_sh_run 'LANCACHE_SETUP_GIT_REF="${TAG}" resolve_setup_bootstrap_ref'
    [ "${status}" -eq 0 ] && [ "${output}" = "${TAG}" ] || { echo "set ref: ${output}"; return 1; }
    # What: each ref kind lands on exactly its commit
    # Why: tag, branch and commit pins must not drift
    # From: Issue #1683 | PR #1858
    while read -r ref want; do
        REF="${ref}"
        _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"'
        [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${want}" ] || { echo "${ref}: ${output}"; return 1; }
    done <<CASES
${TAG} ${tagsha}
${BR} ${brsha}
${tagsha} ${tagsha}
CASES
    REF="missing-${BR}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to fetch ref '${REF}'"* && "${output}" != *unreached* ]] \
        || { echo "missing ref: ${output}"; return 1; }
    _setup_sh_run 'sync_repo_to_default_branch "${T}/co"'
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "default: ${output}"; return 1; }
    g -C "${t}/co" remote set-head origin --delete
    REF="${BR}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}" && sync_repo_to_default_branch "${T}/co"'
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "no origin/HEAD: ${output}"; return 1; }
    g init -q "${t}/noorigin"
    _setup_sh_run 'git_default_branch_name "${T}/noorigin"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to read the remote origin of ${t}/noorigin"* && "${output}" != *unreached* ]] \
        || { echo "noorigin: ${output}"; return 1; }
    g init -q --bare "${t}/nohead.git"
    g init -q "${t}/unknown"
    g -C "${t}/unknown" remote add origin "${t}/nohead.git"
    _setup_sh_run 'git_default_branch_name "${T}/unknown"'
    [ "${status}" -eq 0 ] && [ "${output}" = "${main}" ] || { echo "unknown head: ${output}"; return 1; }
    printf '%s\n' "${BR}" > "${t}/co/${BR}.txt"
    REF="${TAG}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"has local changes"* && "${output}" != *unreached* ]] \
        && [ -f "${t}/co/${BR}.txt" ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "dirty: ${output}"; return 1; }
}

@test "setup env migration and release image tag per input" {
    # What: migrated keys, proxy mode, tag from git/VERSION
    # Why: an update keeps operator values and pins a tag
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" ip v raw case lines want rc tags tag
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    ip="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")"
    v="$(tr -d '[:space:]' < "${root}/VERSION")"
    raw="\"${t}/a b\" # ${BATS_TEST_NUMBER}"
    [ -n "${ip}" ] && [ -n "${v}" ] || { echo "inputs: ${ip} ${v}"; return 1; }
    export E="${t}/.env" IP="${ip}"
    # What: UI_BIND_IP follows IP_STANDARD only when unset
    # Why: an operator's own value or syntax must survive
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case lines want; do
        printf '%b' "${lines}" > "${E}"
        _setup_sh_run 'append_env_migrated_assignment_if_missing UI_BIND_IP IP_STANDARD "${IP}" "${E}"'
        [ "${status}" -eq 0 ] && [ "$(paste -sd'#' "${E}")" = "${want}" ] || { echo "${case}: $(paste -sd'#' "${E}")"; return 1; }
    done <<CASES
emptytarget|IP_STANDARD=${ip}\nUI_BIND_IP=\n|IP_STANDARD=${ip}#UI_BIND_IP=
copysyntax|IP_STANDARD=${raw}\n|IP_STANDARD=${raw}#UI_BIND_IP=${raw}
keep|IP_STANDARD=${ip}\nUI_BIND_IP=${t}\n|IP_STANDARD=${ip}#UI_BIND_IP=${t}
fallback|IP_STANDARD=\n|IP_STANDARD=#UI_BIND_IP=${ip}
CASES
    printf '%s\n' "IP_STANDARD=" > "${E}"
    _setup_sh_run 'append_env_migrated_assignment_if_missing UI_BIND_IP IP_STANDARD "" "${E}"'
    [ "${status}" -eq 0 ] && [ "$(cat "${E}")" = "IP_STANDARD=" ] || { echo "nothing: $(cat "${E}")"; return 1; }
    # What: strict without CIDRs becomes lazy
    # Why: strict with no allow-list blocks every client
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case lines want; do
        printf '%b' "${lines}" > "${E}"
        _setup_sh_run 'migrate_proxy_security_mode_for_update "${E}"'
        [ "${status}" -eq 0 ] && [ "$(paste -sd'#' "${E}")" = "${want}" ] || { echo "${case}: $(paste -sd'#' "${E}")"; return 1; }
    done <<CASES
strictopen|PROXY_SECURITY_MODE=strict\nPROXY_ALLOWED_CLIENT_CIDRS=\n|PROXY_SECURITY_MODE=lazy#PROXY_ALLOWED_CLIENT_CIDRS=
strictcidr|PROXY_SECURITY_MODE=strict\nPROXY_ALLOWED_CLIENT_CIDRS=${ip%.*}.0/24\n|PROXY_SECURITY_MODE=strict#PROXY_ALLOWED_CLIENT_CIDRS=${ip%.*}.0/24
lazy|PROXY_SECURITY_MODE=lazy\n|PROXY_SECURITY_MODE=lazy
CASES
    # What: VERSION shapes map to a release tag or a refusal
    # Why: a bad VERSION must never become an image tag
    # From: Issue #1683 | PR #1858
    export SD="${t}/archive"
    mkdir -p "${SD}"
    while IFS='|' read -r case want rc; do
        printf '%s\n' "${case}" > "${SD}/VERSION"
        [ "${case}" != - ] || : > "${SD}/VERSION"
        _setup_sh_run 'unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG; SCRIPT_DIR="${SD}"; derive_release_archive_image_tag'
        [ "${status}" -eq "${rc}" ] && [ "${output}" = "${want}" ] || { echo "VERSION ${case}: rc ${status} ${output}"; return 1; }
    done <<CASES
${v#v}|v${v#v}|0
v${v#v}-rc.1|v${v#v}-rc.1|0
${v%.*}|Invalid release image tag derived from VERSION: v${v%.*}|2
-|VERSION is empty; cannot derive a release image tag.|2
CASES
    printf '%s\n' "${v}" > "${SD}/VERSION"
    _setup_sh_run 'unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG; SCRIPT_DIR="${SD}"
        printf "%s|%s|%s|%s\n" "$(resolve_lancache_image_channel "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL=pinned resolve_lancache_image_tag "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL=nightly resolve_lancache_image_tag "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL=stable resolve_lancache_image_tag "${SD}/missing.env")"'
    [ "${status}" -eq 0 ] && [ "${output}" = "pinned|v${v#v}|nightly|latest" ] || { echo "channels: ${output}"; return 1; }
    # What: a release tag at HEAD wins; real git
    # Why: a checkout must deploy exactly its tagged images
    # From: Issue #1683 | PR #1858
    g() { git -c user.email=t@example.test -c user.name=t "$@"; }
    export GD="${t}/real dir"
    g init -q "${GD}" && g -C "${GD}" commit -q --allow-empty -m c1
    printf '%s\n' "${v}" > "${GD}/VERSION"
    ln -s "${GD}" "${t}/link"
    while IFS='|' read -r case tags want rc; do
        g -C "${GD}" tag -l | while IFS= read -r tag; do g -C "${GD}" tag -d "${tag}" > /dev/null; done
        for tag in ${tags}; do g -C "${GD}" tag "${tag}"; done
        export SDIR="${GD}"
        [ "${case}" != symlink ] || SDIR="${t}/link"
        _setup_sh_run 'SCRIPT_DIR="${SDIR}"; derive_release_archive_image_tag'
        [ "${status}" -eq "${rc}" ] && [ "$(grep -v '^Note: ' <<< "${output}")" = "${want}" ] \
            || { echo "${case}: rc ${status} ${output}"; return 1; }
    done <<CASES
tagged|v${v#v}|v${v#v}|0
untagged|||1
symlink|v${v#v}|v${v#v}|0
badtag|release-${BATS_TEST_NUMBER}|Invalid release tag from git checkout: release-${BATS_TEST_NUMBER}|2
multi|v${v#v} v${v#v}-rc.1|Several release tags point at HEAD: v${v#v} v${v#v}-rc.1|2
CASES
    g -C "${GD}" tag -l | while IFS= read -r tag; do g -C "${GD}" tag -d "${tag}" > /dev/null; done
    g -C "${GD}" tag "v${v#v}"
    chown -R "$(( $(id -u) + 1 ))" "${GD}" || { echo "chown needs root for the dubious-ownership case"; return 1; }
    export SDIR="${GD}"
    _setup_sh_run 'SCRIPT_DIR="${SDIR}"; derive_release_archive_image_tag'
    [ "${status}" -eq 0 ] && [ "$(tail -n 1 <<< "${output}")" = "v${v#v}" ] && [[ "${output}" == "Note: ${GD} has different file ownership"* ]] \
        || { echo "dubious: rc ${status} ${output}"; return 1; }
}

@test "setup image channel validation, resolution and pointer" {
    # What: SOT channels valid; retired names give a hint
    # Why: setup.sh and the SOT must name the same channels
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" mut rel arms accepted retired alias pin="" first second v sha case line want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mut="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels)"
    rel="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_channel_field release_tags | awk '$2 == "true" { print $1 }')"
    arms="$(declare -f validate_lancache_image_channel | sed -n 's/^ *\([a-z| ]*\))$/\1/p' | tr -d ' ')"
    accepted="$(awk 'NR == 1' <<< "${arms}" | tr '|' '\n')"
    retired="$(awk 'NR > 1' <<< "${arms}" | tr '|' '\n')"
    v="$(tr -d '[:space:]' < "${root}/VERSION")"
    sha="sha-$(sha256sum "${root}/VERSION" | cut -c1-40)"
    [ "$(wc -l <<< "${mut}")" -ge 2 ] && [ "$(wc -w <<< "${rel}")" -eq 1 ] && [ -n "${retired}" ] \
        || { echo "inputs: ${mut} | ${rel} | ${arms}"; return 1; }
    first="$(awk 'NR == 1' <<< "${mut}")" second="$(awk 'NR == 2' <<< "${mut}")"
    export C SD="${t}/plain" E="${t}/.env" SHELLC SHELLT
    mkdir -p "${SD}"
    # What: each SOT channel is valid, points to itself
    # Why: an alias points at the SOT release-tag channel
    # From: Issue #1683 | PR #1858
    while IFS= read -r C; do
        grep -qxF -- "${C}" <<< "${accepted}" || { echo "SOT channel ${C} not accepted by setup.sh"; return 1; }
        _setup_sh_run 'validate_lancache_image_channel "${C}" && lancache_stack_pointer_channel_for "${C}"'
        [ "${status}" -eq 0 ] && [ "${output}" = "${C}" ] || { echo "channel ${C}: ${output}"; return 1; }
    done <<< "${mut}"
    while IFS= read -r alias; do
        grep -qxF -- "${alias}" <<< "${mut}" && continue
        C="${alias}"
        _setup_sh_run 'validate_lancache_image_channel "${C}" && lancache_stack_pointer_channel_for "${C}"'
        [ "${output}" != "${alias}" ] || pin="${alias}"
        [ "${status}" -eq 0 ] && { [ "${output}" = "${rel}" ] || [ "${output}" = "${alias}" ]; } \
            || { echo "alias ${alias}: ${output}"; return 1; }
    done <<< "${accepted}"
    while IFS= read -r C; do
        _setup_sh_run 'validate_lancache_image_channel "${C}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* ]] && grep -qF -f <(sed 's/^/LANCACHE_IMAGE_CHANNEL=/' <<< "${mut}") <<< "${output}" \
            || { echo "retired ${C}: ${output}"; return 1; }
    done <<< "${retired}"
    for C in "x${BATS_TEST_NUMBER}" ""; do
        _setup_sh_run 'validate_lancache_image_channel "${C}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"must be"* && "${output}" != *unreached* ]] || { echo "unknown '${C}': ${output}"; return 1; }
    done
    [ -n "${pin}" ] || { echo "no self-pointing alias in setup.sh"; return 1; }
    # What: shell beats .env; a tag implies its channel
    # Why: one resolution order for every caller
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case SHELLC SHELLT line want; do
        printf '%b' "${line}" > "${E}"
        _setup_sh_run 'SCRIPT_DIR="${SD}"; unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG
            [ -z "${SHELLC}" ] || export LANCACHE_IMAGE_CHANNEL="${SHELLC}"
            [ -z "${SHELLT}" ] || export LANCACHE_IMAGE_TAG="${SHELLT}"
            resolve_lancache_image_channel "${E}"'
        [ "${status}" -eq 0 ] && [ "${output}" = "${want}" ] || { echo "${case}: ${output}"; return 1; }
    done <<CASES
none||||${rel}
shellchan|${first}||LANCACHE_IMAGE_CHANNEL=${second}\n|${first}
shelltag||${second}||${second}
envchan|||LANCACHE_IMAGE_CHANNEL=${second}\n|${second}
envtagsha|||LANCACHE_IMAGE_TAG=${sha}\n|${pin}
envtagv|||LANCACHE_IMAGE_TAG=v${v#v}\n|${pin}
envtagchannel|||LANCACHE_IMAGE_TAG=${first}\n|${first}
CASES
    C="$(awk 'NR == 1' <<< "${retired}")"
    _setup_sh_run 'SCRIPT_DIR="${SD}"; LANCACHE_IMAGE_CHANNEL="${C}" resolve_lancache_image_channel "${E}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* ]] || { echo "retired in shell: ${output}"; return 1; }
}

@test "setup ui override validators per value" {
    # What: setup accepts exactly what the UI can write
    # Why: a UI value must never be dropped or misread
    # From: Issue #1683 | PR #1858
    local root ui chans modes other gb v
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    ui="${root}/services/ui/src"
    chans="$(awk '/^fn is_valid_ui_channel/ { f = 1 } f && /matches!/ { print; exit }' "${ui}/routes/setup.rs" | grep -oE '"[a-z]+"' | tr -d '"')"
    modes="$(awk '/pub fn as_str/ { f = 1 } f && /^    }$/ { exit } f' "${ui}/config.rs" | sed -n 's/.*Self::[A-Za-z]* => "\([a-z-]*\)",/\1/p')"
    other="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels | grep -vxF -f <(printf '%s\n' "${chans}"))"
    other+=$'\n'"$(declare -f validate_lancache_image_channel | sed -n 's/^ *\([a-z| ]*\))$/\1/p' | tr -d ' ' | tr '|' '\n' | grep -vxF -f <(printf '%s\n' "${chans}"))"
    gb="$(cache_size_gb_from_env "$(get_env_var CACHE_MAX_SIZE "${root}/deploy/prod/.env")")"
    [ "$(wc -l <<< "${chans}")" -ge 2 ] && [ "$(wc -l <<< "${modes}")" -ge 2 ] && [ -n "${other}" ] && [ -n "${gb}" ] \
        || { echo "inputs: ${chans} | ${modes} | ${other} | ${gb}"; return 1; }
    # What: one row per value: validator|value|ok or bad
    # Why: every UI value, its near misses and shell junk
    # From: Issue #1683 | PR #1858
    local ch="lancache_ui_channel_override_is_valid" dm="is_valid_dhcp_mode" gbf="lancache_ui_cache_max_gb_override_is_valid"
    {
        while IFS= read -r v; do
            printf '%s|%s|ok\n%s|%s|bad\n%s|%s; rm|bad\n' "${ch}" "${v}" "${ch}" "${v^^}" "${ch}" "${v}"
        done <<< "${chans}"
        while IFS= read -r v; do [ -z "${v}" ] || printf '%s|%s|bad\n' "${ch}" "${v}"; done <<< "${other}"
        while IFS= read -r v; do
            printf '%s|%s|ok\n%s|%s|bad\n%s|%s; rm|bad\n' "${dm}" "${v}" "${dm}" "${v^^}" "${dm}" "${v}"
        done <<< "${modes}"
        printf '%s||bad\n' "${ch}" "${dm}"
        printf "${gbf}|%s|ok\n" 1 "${gb}" "00${gb}" "$(( gb * 40 ))"
        printf "${gbf}|%s|bad\n" 0 000 "-${gb}" "${gb}.5" "" " ${gb} " "${gb}+1" "${gb}; rm"
    } > "${BATS_TEST_TMPDIR}/rows"
    export ROWS="${BATS_TEST_TMPDIR}/rows"
    _setup_sh_run 'while IFS="|" read -r fn v want; do
            got=bad; ! "${fn}" "$v" || got=ok
            [ "$got" = "$want" ] || echo "${fn} [${v}] want ${want}"
        done < "${ROWS}"'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "${output}"; return 1; }
}

@test "setup auto-update gate decides exactly per input" {
    # What: enabled flag, pinned channel, moved tag, text
    # Why: auto-update never touches a pinned or idle stack
    # From: Issue #1683 | PR #1858
    local root mut first second pin new old
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mut="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels)"
    first="$(awk 'NR == 1' <<< "${mut}")" second="$(awk 'NR == 2' <<< "${mut}")"
    pin="$(declare -f validate_lancache_image_channel | sed -n 's/^ *\([a-z| ]*\))$/\1/p' | awk 'NR == 1' | tr -d ' ' | tr '|' '\n' \
        | while IFS= read -r c; do [ "$(lancache_stack_pointer_channel_for "${c}")" != "${c}" ] || grep -qxF -- "${c}" <<< "${mut}" \
            || printf '%s\n' "${c}"; done)"
    new="sha-$(sha256sum <<< "new${BATS_TEST_NUMBER}" | cut -c1-40)"
    old="sha-$(sha256sum <<< "old${BATS_TEST_NUMBER}" | cut -c1-40)"
    [ -n "${first}" ] && [ -n "${second}" ] && [ "$(wc -l <<< "${pin}")" -eq 1 ] && [ -n "${pin}" ] \
        || { echo "inputs: ${mut} | ${pin}"; return 1; }
    # What: one decision per row, under setup.sh options
    # Why: the gate output is the auto-update log line
    # From: Issue #1683 | PR #1858
    cat > "${BATS_TEST_TMPDIR}/rows" <<CASES
off|0|${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
empty||${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
word|x${BATS_TEST_NUMBER}|${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
offpinned|0|${pin}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
pinned|1|${pin}|${new}|${old}|1|skip: LANCACHE_IMAGE_CHANNEL=${pin} tracks one fixed tag, not a moving channel; nothing to detect
idle|1|${first}|${old}|${old}|1|skip: channel ${first} is already at ${old}
moved|1|${first}|${new}|${old}|0|proceed: channel ${first} moved ${old} -> ${new}
second|1|${second}|${new}|${old}|0|proceed: channel ${second} moved ${old} -> ${new}
firstdeploy|1|${second}|${new}||0|proceed: channel ${second} moved  -> ${new}
CASES
    export ROWS="${BATS_TEST_TMPDIR}/rows"
    _setup_sh_run 'while IFS="|" read -r case en ch cur dep rc want; do
            out="$(lancache_auto_update_should_proceed "$en" "$ch" "$cur" "$dep")" && got=0 || got=$?
            [ "$got" = "$rc" ] && [ "$out" = "$want" ] || echo "${case}: rc ${got} ${out}"
        done < "${ROWS}"'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "${output}"; return 1; }
}

@test "setup moves config/prod overrides into the runtime env once" {
    # What: moved keys go from <svc>.local.env to .env.local
    # Why: compose maps them from there; the value must stay
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" rows trows prows svc key target v cp ip bad rest
    local -a plain=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export D="${t}/repo/deploy/prod" E="${t}/repo/deploy/prod/.env.local" Q="${t}/a/qs"
    _prod_install "${D}"
    cp="${t}/repo/config/prod"
    rows="$(config_prod_moved_keys)"
    trows="$(awk 'NF == 3' <<< "${rows}")"
    prows="$(awk 'NF == 2 && !seen[$1]++' <<< "${rows}" | awk 'NR <= 2')"
    [ "$(wc -l <<< "${trows}")" -ge 2 ] && [ "$(wc -l <<< "${prows}")" -eq 2 ] || { echo "rows: ${rows}"; return 1; }
    cp "${D}/.env" "${E}"
    rest="X${BATS_TEST_NUMBER}=${BATS_TEST_NUMBER}"
    while read -r svc key target; do
        v="$(get_env_assignment_value_raw "${target}" "${E}")"
        [ -n "${v}" ] || { echo "template sets no ${target}"; return 1; }
        printf '%s=%s\n' "${key}" "${v}" >> "${cp}/${svc}.local.env"
    done <<< "${trows}"
    while read -r svc key; do
        plain+=("${key}=\"${t}/${key} x\"")
        printf '%s\n' "${plain[-1]}" "${rest}" >> "${cp}/${svc}.local.env"
    done <<< "${prows}"
    # What: a differing target is refused before writes
    # Why: two addresses for one role would split the stack
    # From: Issue #1683 | PR #1858
    read -r svc key target <<< "$(awk 'END { print }' <<< "${trows}")"
    ip="$(get_env_var "${target}" "${E}")"
    bad="${ip%.*}.$(( (${ip##*.} + 1) % 255 ))"
    cp "${cp}/${svc}.local.env" "${t}/good.local.env"
    set_env_key "${key}" "${bad}" "${cp}/${svc}.local.env"
    cp -a "${t}/repo" "${t}/before"
    _setup_sh_run 'adopt_moved_config_prod_keys "${D}" "${E}" copy; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${key}=${bad} in ${cp}/${svc}.local.env differs from ${target}=${ip}"* ]] \
        && [[ "${output}" != *unreached* ]] && diff -r "${t}/before" "${t}/repo" || { echo "mismatch: ${output}"; return 1; }
    cp "${t}/good.local.env" "${cp}/${svc}.local.env"
    rm -rf "${t}/before" && cp -a "${t}/repo" "${t}/before"
    _setup_sh_run 'adopt_moved_config_prod_keys "${D}" "${E}" copy'
    [ "${status}" -eq 0 ] && [[ "${output}" != *Moved* ]] && diff -r "${t}/before/config" "${t}/repo/config" \
        || { echo "copy: ${output}"; return 1; }
    for v in "${plain[@]}"; do
        [ "$(get_env_assignment_value_raw "${v%%=*}" "${E}")" = "${v#*=}" ] || { echo "not copied raw: ${v}"; return 1; }
    done
    _setup_sh_run 'adopt_moved_config_prod_keys "${D}" "${E}" drop'
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Moved ${key} from ${svc}.local.env into ${E##*/} as ${target}"* ]] \
        || { echo "drop: ${output}"; return 1; }
    while read -r svc key target; do
        ! env_key_exists "${key}" "${cp}/${svc}.local.env" || { echo "${key} kept in ${svc}.local.env"; return 1; }
    done <<< "${rows}"
    while read -r svc key; do
        [ "$(cat "${cp}/${svc}.local.env")" = "${rest}" ] || { echo "${svc}.local.env lost other lines"; return 1; }
        [ ! -e "${t}/before/config/prod/${svc}.env" ] || cmp -s "${t}/before/config/prod/${svc}.env" "${cp}/${svc}.env" \
            || { echo "tracked ${svc}.env changed"; return 1; }
    done <<< "${prows}"
    rm -rf "${t}/before" && cp -a "${t}/repo" "${t}/before"
    _setup_sh_run 'adopt_moved_config_prod_keys "${D}" "${E}" copy && adopt_moved_config_prod_keys "${D}" "${E}" drop'
    [ "${status}" -eq 0 ] && [[ "${output}" != *Moved* ]] && diff -r "${t}/before" "${t}/repo" || { echo "second run: ${output}"; return 1; }
    mkdir -p "${Q}" "${t}/config/prod"
    read -r svc key <<< "$(awk 'NR == 1' <<< "${prows}")"
    printf '%s\n' "${plain[0]}" > "${t}/config/prod/${svc}.local.env"
    _setup_sh_run 'adopt_moved_config_prod_keys "${Q}" "${E}" copy && adopt_moved_config_prod_keys "${Q}" "${E}" drop'
    [ "${status}" -eq 0 ] && [ "$(cat "${t}/config/prod/${svc}.local.env")" = "${plain[0]}" ] && diff -r "${t}/before" "${t}/repo" \
        || { echo "non-prod moved: ${output}"; return 1; }
}

@test "setup pxe wizard answers and boot filename per input" {
    # What: server plus a filename; filename char rules
    # Why: a half answer or bad name breaks dnsmasq.conf
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" ip bios uefi max code c
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    ip="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")"
    bios="b${BATS_TEST_NUMBER}.0" uefi="images/u${BATS_TEST_NUMBER}.efi"
    max="$(declare -f is_valid_dhcp_proxy_boot_filename | grep -oE -- '-le [0-9]+' | awk '{ print $2 }')"
    [ -n "${ip}" ] && [ -n "${max}" ] || { echo "inputs: ${ip} ${max}"; return 1; }
    # What: a boot pointer needs the server and a filename
    # Why: dnsmasq renders nothing useful from half of it
    # From: Issue #1683 | PR #1858
    cat > "${t}/answers" <<CASES
${ip}|${bios}||ok
${ip}||${uefi}|ok
${ip}|${bios}|${uefi}|ok
${ip}|||bad
|${bios}||bad
|||bad
CASES
    export ROWS="${t}/answers" E="${t}/.env" MAX="${max}"
    _setup_sh_run 'while IFS="|" read -r s b u want; do
            got=bad; ! pxe_boot_pointer_answers_are_complete "$s" "$b" "$u" || got=ok
            [ "$got" = "$want" ] || echo "answers [$s] [$b] [$u] want $want"
        done < "${ROWS}"'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "${output}"; return 1; }
    # What: an accepted name is .env-safe, one dnsmasq field
    # Why: it goes into .env and into dhcp-boot=
    # From: Issue #1683 | PR #1858
    printf 'services:\n  p:\n    image: %s\n    environment:\n      V: "${KEY:-}"\n' "${LANCACHE_HELPER_IMAGE}" > "${t}/probe.yml"
    for code in $(seq 32 126) 10; do
        c="$(printf "\\$(printf '%03o' "${code}")")"
        [ "${code}" -ne 10 ] || c=$'\n'
        export V="a${c}b"
        _setup_sh_run 'is_valid_dhcp_proxy_boot_filename "${V}" && validate_env_value KEY "${V}" && echo accepted'
        case "${c}" in [A-Za-z0-9._/-]) [ "${output}" = accepted ] || { echo "plain char ${code} refused"; return 1; } ;; esac
        [ "${output}" = accepted ] || continue
        [[ "${V}" != *[[:space:],]* ]] || { echo "char ${code} accepted but splits a dnsmasq field"; return 1; }
        printf 'KEY=%s\n' "${V}" > "${E}"
        [ "$(jq -r '.services.p.environment.V' <<< "$(docker compose --env-file "${E}" -f "${t}/probe.yml" config --format json)")" = "${V}" ] \
            || { echo "char ${code} accepted but changes in .env"; return 1; }
    done
    export V255 V256
    V255="$(printf 'a%.0s' $(seq 1 "${max}"))" V256="${V255}a"
    _setup_sh_run 'is_valid_dhcp_proxy_boot_filename "${V255}" && echo long-ok; is_valid_dhcp_proxy_boot_filename "${V256}" || echo too-long
        is_valid_dhcp_proxy_boot_filename "" || echo empty'
    [ "${status}" -eq 0 ] && [ "${output}" = "$(printf 'long-ok\ntoo-long\nempty')" ] || { echo "length: ${output}"; return 1; }
}

@test "setup dhcp mode, compose profiles and dnsmasq templates" {
    # What: modes, subnet start, profiles, template vars
    # Why: one dhcp profile per mode; templates fully render
    # From: Issue #1683 | PR #1858
    local root modes off cprof ip net m p v dhcp="" ntp logp custom tpl vars exported out
    local -a assigns=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    modes="$(awk '/pub fn as_str/ { f = 1 } f && /^    }$/ { exit } f' "${root}/services/ui/src/config.rs" \
        | sed -n 's/.*Self::[A-Za-z]* => "\([a-z-]*\)",/\1/p')"
    off="$(awk 'NR == 1' <<< "${modes}")"
    cprof="$(_prod_compose config --profiles)"
    ip="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")" net="${ip%.*}.0"
    [ "$(wc -l <<< "${modes}")" -ge 3 ] && [ -n "${cprof}" ] && [ -n "${ip}" ] || { echo "inputs: ${modes} | ${cprof}"; return 1; }
    while IFS= read -r m; do
        is_valid_dhcp_mode "${m}" && ! is_valid_dhcp_mode "${m^^}" && ! is_valid_dhcp_mode "${m}x" || { echo "mode ${m}"; return 1; }
    done <<< "${modes}"
    ! is_valid_dhcp_mode "" || { echo "empty mode accepted"; return 1; }
    is_dnsmasq_subnet_start "${net}" || { echo "subnet ${net} refused"; return 1; }
    for v in "${ip%.*}.$(( ${ip##*.} | 1 ))" "x${BATS_TEST_NUMBER}" "256.${net#*.}"; do
        ! is_dnsmasq_subnet_start "${v}" || { echo "subnet ${v} accepted"; return 1; }
    done
    # What: each mode gives one compose profile, never two
    # Why: one dhcp server per stack; profiles are compose's
    # From: Issue #1683 | PR #1858
    [ -z "$(compose_profiles_for_runtime "" "${off}" 0 0)" ] || { echo "${off} enables a profile"; return 1; }
    while IFS= read -r m; do
        [ "${m}" != "${off}" ] || continue
        p="$(compose_profiles_for_runtime "" "${m}" 0 0)"
        [ "$(tr ',' '\n' <<< "${p}" | wc -l)" -eq 1 ] && grep -qxF -- "${p}" <<< "${cprof}" || { echo "mode ${m}: ${p}"; return 1; }
        dhcp+="${dhcp:+,}${p}"
    done <<< "${modes}"
    while IFS= read -r m; do
        p="$(compose_profiles_for_runtime "${dhcp}" "${m}" 0 0)"
        [ "${p}" = "$(compose_profiles_for_runtime "" "${m}" 0 0)" ] || { echo "switch to ${m}: ${p}"; return 1; }
    done <<< "${modes}"
    ntp="$(compose_profiles_for_runtime "" "${off}" 1 0)" logp="$(compose_profiles_for_runtime "" "${off}" 0 1)"
    grep -qxF -- "${ntp}" <<< "${cprof}" && grep -qxF -- "${logp}" <<< "${cprof}" && [ "${ntp}" != "${logp}" ] \
        && [ "$(compose_profiles_for_runtime "" "${off}" 0)" = "${logp}" ] \
        && [ -z "$(compose_profiles_for_runtime "${ntp},${logp},ssl" "${off}" 0 0)" ] || { echo "ntp/logging: ${ntp} ${logp}"; return 1; }
    custom="$(grep -vxF -e "${ntp}" -e "${logp}" -f <(tr ',' '\n' <<< "${dhcp}") <<< "${cprof}" | awk 'NR == 1')"
    out="$(compose_profiles_for_runtime " x${BATS_TEST_NUMBER} , ${custom} ,x${BATS_TEST_NUMBER}" "${off}" 1 1)"
    [ "${out}" = "x${BATS_TEST_NUMBER},${custom},${ntp},${logp}" ] || { echo "custom: ${out}"; return 1; }
    # What: every template variable is set by the entrypoint
    # Why: an unset one renders an empty dnsmasq field
    # From: Issue #1683 | PR #1858
    exported="$(grep -E '^export ' "${root}/services/dhcp-proxy/entrypoint.sh" | tr ' ' '\n' | grep -E '^[A-Z_]+$')"
    for tpl in "${root}"/services/dhcp-proxy/*.conf.template; do
        vars="$(grep -oE '\$\{[A-Z_]+\}' "${tpl}" | tr -d '${}' | sort -u)"
        [ -n "${vars}" ] || continue
        [ -z "$(grep -vxF -f <(printf '%s\n' "${exported}") <<< "${vars}")" ] || { echo "${tpl##*/}: unset vars"; return 1; }
        mapfile -t assigns < <(sed 's/.*/&=m-&/' <<< "${vars}")
        out="$(env "${assigns[@]}" envsubst < "${tpl}")"
        [[ "${out}" != *'${'* ]] || { echo "${tpl##*/}: placeholder left"; return 1; }
        while IFS= read -r v; do grep -qF -- "m-${v}" <<< "${out}" || { echo "${tpl##*/}: ${v} not rendered"; return 1; }; done <<< "${vars}"
    done
}

@test "setup secondary registration end to end per primary answer" {
    _stand_ins || return 1
    # What: cmd_secondary against a stub primary per answer
    # Why: token never in argv; failures stop before writes
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" rs std lip ui name xfr fields reg pre tag token body f v case want dir
    local env gen canon over required first rest
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    rs="${root}/services/ui/src/routes/secondaries.rs"
    std="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")"
    lip="$(get_env_var IP_SSL "${root}/deploy/prod/.env")"
    ui="$(_prod_compose config --format json | jq -r '.services.ui.ports[0].published')"
    name="$(_prod_compose config --format json | jq -r .name)"
    xfr="$(grep -oE 'format!\("\{\}:[0-9]+", state\.config\.standard_ip\)' "${rs}" | grep -oE ':[0-9]+')"
    fields="$(awk '/pub struct RegisterResponse/,/^}/' "${rs}" | sed -n 's/^ *pub \([a-z_]*\): String,$/\1/p')"
    reg="$(resolve_lancache_image_registry "${root}/deploy/prod/.env")"
    pre="$(resolve_lancache_image_prefix "${root}/deploy/prod/.env")"
    tag="v$(cat "${root}/VERSION")"
    token="$(generate_secret_value SECONDARY_REGISTRATION_TOKEN hex32)"
    token="${token}\"${token}\\"
    over="$(declare -f compose_file_args_for_install_dir | grep -oE 'docker-compose\.[a-z-]+\.yml' | grep -v override | awk 'NR == 1')"
    required="$(declare -f cmd_secondary | sed -n 's/.*missing_fields+=("\([a-z_]*\)").*/\1/p')"
    [ -n "${std}" ] && [ -n "${lip}" ] && [ -n "${ui}" ] && [ -n "${xfr}" ] && [ -n "${fields}" ] && [ -n "${over}" ] \
        && [ -n "${required}" ] || { echo "inputs: ${std} ${lip} ${ui} ${xfr} ${over}"; return 1; }
    # What: the primary's answer, one value per struct field
    # Why: values are unique so each one is traced to .env
    # From: Issue #1683 | PR #1858
    body='{}'
    while IFS= read -r f; do
        case "${f}" in
            proxy_ip) v="${std}" ;;
            dns_xfr_primary) v="${std}${xfr}" ;;
            image_registry) v="${reg}" ;;
            image_prefix) v="${pre}" ;;
            image_channel) v="" ;;
            image_tag) v="${tag}" ;;
            *) v="$(generate_secret_value "${f^^}" hex32)" ;;
        esac
        body="$(jq -c --arg k "${f}" --arg v "${v}" '.[$k] = $v' <<< "${body}")"
    done <<< "${fields}"
    first="$(awk 'NR == 1' <<< "${required}")"
    rest="$(awk 'NR > 1' <<< "${required}" | paste -sd' ')"
    export PRIMARY="http://${std}:${ui}" TOKEN="${token}" NAME="${name}" STD="${std}" LIP="${lip}"
    export JQ_REAL
    JQ_REAL="$(type -P jq)"
    _tool_stub "${BIN}" ss <<<'[ ! -e "${DS}/listeners" ] || cat "${DS}/listeners"'
    _tool_stub "${BIN}" jq <<<'printf "%s\n" "$*" >> "${DS}/jq.argv"; exec "${JQ_REAL:?}" "$@"'
    _tool_stub "${BIN}" curl <<'STUB'
printf '%s\n' "$*" >> "${DS}/curl.argv"
case "${!#}" in
    */deploy/secondary/docker-compose.yml) [ ! -e "${DS}/fail-raw" ] || exit 22; cat "${DS}/raw.compose"; exit 0 ;;
esac
cat > "${DS}/curl.body"
[ ! -e "${DS}/fail-curl" ] || exit 7
fmt=""
while [ "$#" -gt 0 ]; do [ "$1" != -w ] || fmt="$2"; shift; done
fmt="${fmt//\\n/$'\n'}"
cat "${DS}/reply.body"
printf '%s' "${fmt//"%{http_code}"/$(cat "${DS}/reply.status")}"
STUB
    _sec() {
        export SD="$1"
        shift
        mkdir -p "${SD}" && printf '%s\0' "$@" > "${DS}/args"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; [ -z "${SEC_SCRIPT_DIR:-}" ] || SCRIPT_DIR="${SEC_SCRIPT_DIR}"
            mapfile -d "" -t a < "${DS}/args"; cd "${SD}" && cmd_secondary "${a[@]}"'
    }
    # What: each failing answer stops before any file exists
    # Why: a half-written secondary must never start
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case want; do
        rm -f "${DS}/fail-curl" "${DS}/listeners" "${DS}/jq.argv" "${DS}/curl.argv"
        printf '200' > "${DS}/reply.status"; printf '%s' "${body}" > "${DS}/reply.body"
        case "${case}" in
            connect) : > "${DS}/fail-curl" ;;
            http503) printf '503' > "${DS}/reply.status"; printf '{}' > "${DS}/reply.body" ;;
            http401) printf '401' > "${DS}/reply.status"; printf '{}' > "${DS}/reply.body" ;;
            status) printf 'x' > "${DS}/reply.status" ;;
            json) printf '{' > "${DS}/reply.body" ;;
            fields) jq -c --arg k "${first}" '{($k): .[$k]}' <<< "${body}" > "${DS}/reply.body" ;;
            port) printf 'udp UNCONN 0 0 %s:53 0.0.0.0:*\n' "${lip}" > "${DS}/listeners" ;;
        esac
        rm -f "${DS}/jq.argv"
        _sec "${t}/${case}" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}"
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${want}"* ]] && [ ! -e "${t}/${case}/${name}" ] \
            && ! grep -qF -- "$(jq -r .nats_password <<< "${body}")" <<< "${output}" \
            || { echo "${case}: rc ${status}: ${output}"; return 1; }
        touch "${DS}/jq.argv" "${DS}/curl.argv"
        ! grep -qF -- "${token}" "${DS}/jq.argv" "${DS}/curl.argv" || { echo "${case}: token in argv"; return 1; }
    done <<CASES
connect|Failed to connect to primary server at ${PRIMARY}
http503|HTTP 503
http401|rejected the registration request with HTTP 401
status|Unrecognized response from primary server at ${PRIMARY}
json|Unrecognized response from primary server at ${PRIMARY}
fields|missing field(s): ${rest}
port|No usable secondary bind IP on port 53
CASES
    _sec "${t}/args" --name "${NAME}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Required argument(s) missing: --primary --token --proxy-ip"* ]] \
        || { echo "missing args: ${output}"; return 1; }
    rm -f "${DS}/listeners" "${DS}/curl.argv"
    printf '200' > "${DS}/reply.status"; printf '%s' "${body}" > "${DS}/reply.body"
    rm -f "${DS}/jq.argv"
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}"
    [ "${status}" -eq 0 ] || { echo "register: ${output}"; return 1; }
    ! grep -qF -- "${token}" "${DS}/jq.argv" "${DS}/curl.argv" || { echo "token in argv"; return 1; }
    jq -e --arg tok "${token}" --arg n "${name}" --arg a "${lip}" '. == {token: $tok, name: $n, address: $a}' "${DS}/curl.body" \
        || { echo "request: $(cat "${DS}/curl.body")"; return 1; }
    dir="${t}/ok/${name}" env="${t}/ok/${name}/.env"
    # What: every answer value lands in .env, IPs as passed
    # Why: the secondary runs on what the primary handed out
    # From: Issue #1683 | PR #1858
    while IFS= read -r f; do
        case "${f}" in proxy_ip|image_*) continue ;; esac
        v="$(jq -r --arg k "${f}" '.[$k]' <<< "${body}")"
        awk -v v="${v}" 'substr($0, index($0, "=") + 1) == v { f = 1 } END { exit !f }' "${env}" \
            || { echo "${f} not in .env"; return 1; }
    done <<< "${fields}"
    [ "$(get_env_var PROXY_IP "${env}")" = "${std}" ] && [ "$(get_env_var LISTEN_IP "${env}")" = "${lip}" ] \
        || { echo "ips: $(cat "${env}")"; return 1; }
    want="compose --env-file ${env} $(compose_file_args_for_install_dir "${dir}" "${env}" | paste -sd' ') up -d"
    grep -qxF -- "${want}" "${DS}/docker.log" || { echo "start: $(cat "${DS}/docker.log")"; return 1; }
    # What: the written compose equals deploy/secondary
    # Why: deploy/secondary is the one owner of this file
    # From: Issue #1683 | PR #1858
    gen="$(docker compose -p "${name}" --env-file "${env}" -f "${dir}/docker-compose.yml" config --format json)"
    canon="$(docker compose -p "${name}" --env-file "${env}" -f "${root}/deploy/secondary/docker-compose.yml" config --format json)"
    [ "$(jq -S . <<< "${gen}")" = "$(jq -S . <<< "${canon}")" ] \
        && jq -e --arg img "${reg}/${pre}/" --arg tag ":${tag}" '[.services[].image] | all(startswith($img) and endswith($tag))' <<< "${gen}" \
        || { echo "compose drift or image: ${gen}"; return 1; }
    cp "${env}" "${t}/env.first"; cp "${dir}/docker-compose.yml" "${t}/compose.first"
    rm -f "${DS}/curl.argv"
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"already exists; rerun with --rotate"* ]] && [ ! -e "${DS}/curl.argv" ] \
        || { echo "existing: ${output}"; return 1; }
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}" --rotate
    [ "${status}" -eq 0 ] && cmp "${t}/env.first" "${env}" && cmp "${t}/compose.first" "${dir}/docker-compose.yml" \
        || { echo "rotate: ${output}"; return 1; }
    # What: without a checkout the owner file is downloaded
    # Why: a curl|bash secondary uses the same single owner
    # From: Issue #1683 | PR #1858
    cp "${root}/deploy/secondary/docker-compose.yml" "${DS}/raw.compose"
    export SEC_SCRIPT_DIR="${t}/nocheckout"
    mkdir -p "${SEC_SCRIPT_DIR}"
    rm -f "${DS}/curl.argv"
    _sec "${t}/raw" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}"
    [ "${status}" -eq 0 ] && cmp "${root}/deploy/secondary/docker-compose.yml" "${t}/raw/${NAME}/docker-compose.yml" \
        && grep -q '/HEAD/deploy/secondary/docker-compose\.yml$' "${DS}/curl.argv" || { echo "download: ${output}"; return 1; }
    : > "${DS}/fail-raw"
    rm -f "${DS}/curl.argv"
    _sec "${t}/rawfail" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --proxy-ip "${STD}" --listen-ip "${LIP}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to download the secondary compose file"* ]] \
        && [ "$(wc -l < "${DS}/curl.argv")" -eq 1 ] && [ ! -e "${t}/rawfail/${NAME}" ] \
        || { echo "download failure: ${output}"; return 1; }
    unset SEC_SCRIPT_DIR
}

@test "setup backup and restore round-trip per target and host" {
    _stand_ins || return 1
    # What: rollback in place twice; restore on a new host
    # Why: a restore must reproduce files, paths and volumes
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" archive round vol v keys excl key e
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    vol="$(_prod_compose config --format json | jq -r .name)_$(_backup_volume)"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" S="${t}/a/deploy/prod" D="${t}/b/deploy/prod"
    v="${DS}/volumes/${vol}"
    _prod_install "${S}"
    mkdir -p "${S}/certs" "${v}"
    printf '%s\n' "${S}" > "${S}/certs/${vol}"
    printf '%s\n' "${vol}" > "${v}/${vol}"; printf '%s\n' "${DS}" > "${v}/.${vol}"
    # What: one file in every state dir the compose mounts
    # Why: backups carry each but the excluded cache/logs
    # From: Issue #1683 | PR #1858
    keys="$(prod_state_keys)"
    excl="$(awk '/^backup_manifest\(\) \{/ { f = 1 } f && /^}/ { exit } f' "${root}/setup.sh" \
        | sed -n 's/.*case "\$key" in \([A-Z_|]*\)).*/\1/p' | tr '|' '\n')"
    [ -n "${keys}" ] && [ -n "${excl}" ] || { echo "state keys: ${keys} | ${excl}"; return 1; }
    while IFS= read -r key; do
        mkdir -p "${S}/state/$(prod_state_subdir "${key}")"
        printf '%s\n' "${key}" > "${S}/state/$(prod_state_subdir "${key}")/${key}"
    done <<< "${keys}"
    _state_matches() {
        local dest="$1" key sub
        while IFS= read -r key; do
            sub="$(prod_state_subdir "${key}")"
            if grep -qx -- "${key}" <<< "${excl}"; then
                ! cmp -s "${t}/S.first/state/${sub}/${key}" "${dest}/state/${sub}/${key}" \
                    || { echo "${key} came from a config backup"; return 1; }
            else
                diff -r "${t}/S.first/state/${sub}" "${dest}/state/${sub}" || { echo "${key} not restored"; return 1; }
            fi
        done <<< "${keys}"
    }
    : > "${DS}/running"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; migrate_env_for_update "${S}" 1 && cmd_backup --config --dest "${T}/bk" "${S}"'
    [ "${status}" -eq 0 ] && [ -e "${DS}/running" ] || { echo "converge and backup: ${output}"; return 1; }
    archive="$(find "${t}/bk" -mindepth 1 -maxdepth 1)"
    [ "$(wc -l <<< "${archive}")" -eq 1 ] && [ -f "${archive}" ] || { echo "backup root: ${archive}"; return 1; }
    export AR="${archive}"
    cp -a "${S}" "${t}/S.first"; cp -a "${v}" "${t}/v.first"
    printf '%s\n' "${t}" > "${v}/${vol}"; printf '%s\n' "${t}" > "${S}/certs/${vol}"
    while IFS= read -r key; do printf '%s\n' "${t}" > "${S}/state/$(prod_state_subdir "${key}")/${key}"; done <<< "${keys}"
    for round in first second; do
        _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_restore "${AR}" "${S}"'
        [ "${status}" -eq 0 ] && [ -e "${DS}/running" ] || { echo "restore ${round}: ${output}"; return 1; }
        for e in "${t}/S.first"/* "${t}/S.first"/.[!.]*; do
            [ ! -e "${e}" ] || [ "${e##*/}" = state ] || diff -r "${e}" "${S}/${e##*/}" || { echo "restore ${round}: ${e##*/}"; return 1; }
        done
        _state_matches "${S}" && diff -r "${t}/v.first" "${v}" || { echo "restore ${round} state"; return 1; }
    done
    rm -rf "${DS}/volumes" && mkdir "${DS}/volumes"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_restore "${AR}" "${D}"'
    [ "${status}" -eq 0 ] || { echo "fresh host: ${output}"; return 1; }
    [ "$(get_env_var LANCACHE_STATE_DIR "${D}/.env")" = "${D}/state" ] && ! grep -qF -- "${S}" "${D}/.env" \
        && _state_matches "${D}" && diff -r "${t}/v.first" "${v}" || { echo "fresh host state"; return 1; }
}

@test "setup log bundle finds every managed secret and redacts it" {
    # What: secret keys, values, mid-line, .env redaction
    # Why: a missed secret in a bundle is a credential leak
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" keys list plain k long short custom ph marker
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    keys="$(grep -oE '(ensure_secret_env_key|generate_secret_value) [A-Z_]+' "${root}/setup.sh" | awk '{ print $2 }' | sort -u)"
    list="$(logbundle_secret_env_keys)"
    [ -n "${keys}" ] && [ -n "${list}" ] || { echo "no managed secrets found"; return 1; }
    while IFS= read -r k; do
        grep -qx -- "${k}" <<< "${list}" || logbundle_key_looks_like_secret "${k}" || { echo "unredacted ${k}"; return 1; }
    done <<< "${keys}"
    plain="$(awk -F= '/^[A-Z_][A-Z0-9_]*=/ { print $1 }' "${root}/deploy/prod/.env" | grep -vxF -f <(printf '%s\n' "${keys}"))"
    while IFS= read -r k; do
        ! logbundle_key_looks_like_secret "${k}" || { echo "plain prod key ${k} flagged as secret"; return 1; }
    done <<< "${plain}"
    k="$(awk 'NR == 1' <<< "${list}")"
    long="$(generate_secret_value "${k}" hex32)"; short="$(generate_secret_value "${k}" alnum20)"
    custom="BATS${BATS_TEST_NUMBER}_${k##*_}"; ph="CHANGE_ME_${k}"
    ! grep -qx -- "${custom}" <<< "${list}" && logbundle_key_looks_like_secret "${custom}" && secret_value_is_placeholder "${ph}" \
        || { echo "probe inputs invalid: ${custom} ${ph}"; return 1; }
    { printf '%s=%s\n' "${k}" "${short}" "${custom}" "${long}" "$(awk 'NR == 2' <<< "${list}")" "${ph}"
      awk -F= -v k="$(awk 'NR == 1' <<< "${plain}")" '$1 == k' "${root}/deploy/prod/.env"; } > "${t}/src.env"
    logbundle_collect_secret_values "${t}/src.env" > "${t}/secrets"
    [ "$(paste -sd, "${t}/secrets")" = "${long},${short}" ] || { echo "values: $(paste -sd, "${t}/secrets")"; return 1; }
    marker="$(logbundle_redact_stream "${t}/secrets" <<< "${long}")"
    [ -n "${marker}" ] && [ "${marker}" != "${long}" ] || { echo "no redaction marker"; return 1; }
    [ "$(logbundle_redact_stream "${t}/secrets" <<< "${t}:${short}@${k}")" = "${t}:${marker}@${k}" ] \
        && [ "$(: > "${t}/none"; logbundle_redact_stream "${t}/none" <<< "${t}:${short}")" = "${t}:${short}" ] \
        || { echo "stream redaction"; return 1; }
    logbundle_redact_env_file "${t}/src.env" "${t}/dst.env"
    ! grep -qF -e "${long}" -e "${short}" "${t}/dst.env" && grep -qxF -- "${k}=${marker}" "${t}/dst.env" \
        && grep -qxF -- "$(tail -n 1 "${t}/src.env")" "${t}/dst.env" || { echo "env: $(paste -sd'#' "${t}/dst.env")"; return 1; }
}

@test "setup debug stays read-only and converge folds UI settings once" {
    _stand_ins || return 1
    # What: debug only reads; converge folds once, stable
    # Why: support commands must not change an install
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" body vsuffix sfile vols channel mode size gb unit profiles kv p known
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    _tool_stub "${t}/bin" curl <<<'exit 7'
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" I="${t}/repo/deploy/prod"
    _prod_install "${I}"
    mkdir -p "${DS}/volumes" "$(get_env_var LANCACHE_STATE_DIR "${I}/.env")"
    cp "${I}/.env" "${t}/env.before"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_debug "${I}"; cmd_debug "${I}"'
    [ "${status}" -eq 0 ] && cmp "${t}/env.before" "${I}/.env" || { echo "debug: ${output}"; return 1; }
    ! grep -Eq '^compose .* (up|pull|down|stop|rm|restart|create|start|kill)( |$)' "${DS}/docker.log" \
        && grep -Eq '^compose .* ps( |$)' "${DS}/docker.log" || { echo "debug calls: $(paste -sd'#' "${DS}/docker.log")"; return 1; }
    body="$(declare -f lancache_read_ui_settings_override)"
    vsuffix="$(sed -n 's/.*volume="\${project}_\([^"]*\)".*/\1/p' <<< "${body}")"
    sfile="$(grep -oE '/volume/[A-Za-z0-9._-]+' <<< "${body}" | awk 'NR == 1 { sub(/^\/volume\//, ""); print }')"
    vols="$(_prod_compose config --volumes)"
    grep -qx -- "${vsuffix}" <<< "${vols}" && [ -n "${sfile}" ] || { echo "ui volume ${vsuffix}/${sfile}"; return 1; }
    channel="$(_ci_block_entry_field release "" default_channel)"
    lancache_ui_channel_override_is_valid "${channel}" || { echo "SOT channel ${channel} not UI-valid"; return 1; }
    mode=""
    while IFS= read -r p; do
        is_valid_dhcp_mode "${p#dhcp-}" && [ "${p#dhcp-}" != "${p}" ] && { mode="${p#dhcp-}"; break; }
    done < <(_prod_compose config --profiles)
    size="$(get_env_var CACHE_MAX_SIZE "${root}/deploy/prod/.env")"; unit="${size//[0-9]/}"; gb=$(( ${size%"${unit}"} * 2 ))
    [ -n "${mode}" ] && lancache_ui_cache_max_gb_override_is_valid "${gb}" || { echo "no UI inputs: ${mode} ${gb}"; return 1; }
    vsuffix="$(_prod_compose config --format json | jq -r .name)_${vsuffix}"
    mkdir -p "${DS}/volumes/${vsuffix}"
    printf '%s\n' "LANCACHE_IMAGE_CHANNEL=${channel}" AUTO_UPDATE_ENABLED=1 "DHCP_MODE=${mode}" LOGGING_ENABLED=1 "CACHE_MAX_GB=${gb}" \
        > "${DS}/volumes/${vsuffix}/${sfile}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_converge_reconcile "${I}"; cp "${I}/.env" "${T}/env.first"; cmd_converge_reconcile "${I}"'
    [ "${status}" -eq 0 ] && cmp "${t}/env.first" "${I}/.env" || { echo "converge: ${output}"; return 1; }
    while IFS= read -r kv; do
        grep -qxF -- "${kv}" "${I}/.env" || { echo "missing ${kv}: $(paste -sd'#' "${I}/.env")"; return 1; }
    done < "${DS}/volumes/${vsuffix}/${sfile}"
    [ "$(get_env_var CACHE_MAX_SIZE "${I}/.env")" = "${gb}${unit}" ] || { echo "cache size not derived from ${gb}"; return 1; }
    profiles="$(compose_profiles_for_runtime "" "${mode}" "$(get_env_var NTP_ENABLED "${I}/.env")" 1)"
    [ "$(get_env_var COMPOSE_PROFILES "${I}/.env")" = "${profiles}" ] || { echo "profiles: $(get_env_var COMPOSE_PROFILES "${I}/.env")"; return 1; }
    known="$(_prod_compose config --profiles)"
    while IFS= read -r p; do
        grep -qx -- "${p}" <<< "${known}" || { echo "profile ${p} unknown to prod"; return 1; }
    done < <(tr ',' '\n' <<< "${profiles}" | awk 'NF')
}

