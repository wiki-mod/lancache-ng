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
    # What: every test gets the one docker stand-in on PATH
    # Why: no test may reach a daemon or a real registry
    # From: Issue #1683 | PR #1858
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
}

# What: one top-level block of the real SOT, for fixtures.
# Why: fixture SOTs need the policy values ci.sh reads.
# From: Issue #1683 | PR #1858
_sot_block() {
    awk -v b="$1" '$0 ~ ("^" b ":") { on = 1; print; next }
        on && /^[^ #]/ { exit }
        on { print }' "${CI_MANIFEST_SOURCE}"
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

@test "result-gate maps each phase-result set to its verdict" {
    # What: per row: phase results -> rc and verdict line.
    # Why: only success or a NOOP skip may green the gate.
    # From: Issue #1683 | PR #1858
    local case phases rc want
    local -A V=([@O1@]="$(_val name)" [@O2@]="$(_val name)")
    while IFS='|' read -r case phases rc want; do
        if [ "${phases}" = - ]; then
            run env -u CI_PHASE_RESULTS bash "${CI_SH}" result-gate
        else
            CI_PHASE_RESULTS="$(_fill "${phases}")" run bash "${CI_SH}" result-gate
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
all-success|plan:success @O1@:success checks:success|0|-> SUCCESS
noop-skips|plan:success @O1@:skipped @O2@:skipped checks:success|0|-> SUCCESS
plan-failed|plan:failure checks:success|1|[CI-ERROR-CORE-0100] phase="plan" result="failure"
checks-failed|plan:success checks:failure|1|[CI-ERROR-CORE-0100] phase="checks" result="failure"
platform-skipped|platform:skipped plan:success checks:success|1|[CI-ERROR-CORE-0100] phase="platform" result="skipped"
phase-failed|plan:success @O1@:failure checks:success|1|[CI-ERROR-CORE-0116] phase="@O1@" result="failure"
empty|-|2|[CI-ERROR-CORE-0101]
CASES
}

@test "every command fails closed on missing input with its own id" {
    # What: per row: bad or missing input -> rc 2 + its id.
    # Why: input errors stop with our id before a backend.
    # From: Issue #1683 | PR #1858
    local calls case envs args id dk got
    calls="$(_val path)"
    local -a ev av
    local -A V=(
        [@SVC@]="$(ci_services | awk 'NR == 1')" [@TOOL@]="$(_ci_block_keys build_toolchain | awk 'NR == 1')"
        [@CHAN@]="$(_ci_block_entry_field release "" default_channel)"
        [@REC@]="$(_stub 'printf "%s\n" "$*" >> "'"${calls}"'"')"
        [@FULL@]="$(_promote_full_candidate "$(_val digest)")" [@CAND@]="$(_stub 'true')"
        [@NOIDX@]="$(_stub 'exit 1')" [@BAD@]="$(_val name)" [@FOREIGN@]="$(_val platform)"
        [@DIGEST@]="$(_val digest)" [@IMG@]="$(_val name)@$(_val digest)" [@USER@]="$(_val name)" [@TOKEN@]="$(_val name)"
    )
    V[@PLAT@]="$(_ci_platforms "${V[@SVC@]}" | awk 'NR == 1')"
    [ -n "${V[@SVC@]}" ] && [ -n "${V[@TOOL@]}" ] && [ -n "${V[@CHAN@]}" ] && [ -n "${V[@PLAT@]}" ] \
        || { echo "inputs: ${V[*]}"; return 1; }
    while IFS='|' read -r case envs args id dk; do
        ev=() av=()
        envs="$(_fill "${envs}")" args="$(_fill "${args}")"
        [ "${envs}" = - ] || read -r -a ev <<< "${envs}"
        read -r -a av <<< "${args}"
        rm -f "${calls}" "${DS}/docker.log"
        run env -u GHCR_USERNAME -u GHCR_TOKEN "${ev[@]}" bash "${CI_SH}" "${av[@]}"
        _expect "${case}" 2 "[${id}]" || return 1
        [ ! -e "${calls}" ] || { echo "${case}: backend ran: $(cat "${calls}")"; return 1; }
        got=""
        [ "${dk}" != - ] || dk=""
        [ ! -e "${DS}/docker.log" ] || got="$(cat "${DS}/docker.log")"
        [ "${got}" = "${dk}" ] || { echo "${case}: docker calls '${got}' want '${dk}'"; return 1; }
    done <<'CASES'
unknown-command|-|@BAD@|CI-ERROR-CORE-0002|-
identity|-|identity|CI-ERROR-IDENTITY-0001|-
impact|-|impact|CI-ERROR-IMPACT-0001|-
resolve|-|resolve|CI-ERROR-RESOLVE-0001|-
resolve-platform|-|resolve @SVC@ @FOREIGN@|CI-ERROR-RESOLVE-0004|-
build-platform|-|build @SVC@ @FOREIGN@|CI-ERROR-BUILD-0006|-
test|-|test|CI-ERROR-TEST-0001|-
test-toolchain|-|test @TOOL@|CI-ERROR-TEST-0006|-
assemble|-|assemble|CI-ERROR-ASSEMBLE-0001|-
promote|-|promote|CI-ERROR-PROMOTE-0001|-
promote-channel|-|promote @BAD@|CI-ERROR-PROMOTE-0002|-
validate|CI_STACK_CANDIDATE_CMD=@NOIDX@|validate|CI-ERROR-VALIDATE-0001|compose version
validate-empty|CI_STACK_CANDIDATE_CMD=@CAND@|validate|CI-ERROR-VALIDATE-0002|compose version
variables-get|-|variables get|CI-ERROR-VARIABLES-0003|-
variables-verb|-|variables @BAD@|CI-ERROR-VARIABLES-0002|-
bake-image|GHCR_USERNAME=@USER@ GHCR_TOKEN=@TOKEN@|variables bake-check|CI-ERROR-VARIABLES-0008|-
build-args|-|build-args|CI-ERROR-BUILDARGS-0001|-
build-args-target|-|build-args @BAD@|CI-ERROR-BUILDARGS-0002|-
build-args-format|-|build-args @SVC@ --@BAD@|CI-ERROR-BUILDARGS-0005|-
build-tools-verb|-|build-tools @BAD@|CI-ERROR-BUILDTOOLS-0003|-
version-verb|-|version @BAD@|CI-ERROR-VERSION-0014|-
release-tag|CI_RELEASE_GH_CMD=@REC@|release-publish|CI-ERROR-RELEASE-0003|-
scan-auth|CI_SCAN_CMD=@REC@|scan @SVC@ @DIGEST@|CI-ERROR-BUILD-0002|-
publish-auth|-|publish @SVC@|CI-ERROR-BUILD-0002|-
promote-auth|CI_STACK_CANDIDATE_CMD=@FULL@ CI_STACK_VALIDATED=SUCCESS CI_PROMOTE_MOVE_CMD=@REC@|promote @CHAN@|CI-ERROR-BUILD-0002|-
validate-auth|CI_STACK_CANDIDATE_CMD=@FULL@ CI_VALIDATE_CMD=@REC@|validate|CI-ERROR-BUILD-0002|compose version
bake-auth|CI_BAKE_INSPECT_CMD=@REC@|variables bake-check @IMG@|CI-ERROR-BUILD-0002|-
verify|-|verify|CI-ERROR-VERIFY-0001|-
verify-digest|-|verify @SVC@|CI-ERROR-VERIFY-0002|-
verify-platform|-|verify @SVC@ @DIGEST@|CI-ERROR-VERIFY-0004|-
verify-auth|-|verify @SVC@ @DIGEST@ @PLAT@|CI-ERROR-BUILD-0002|-
ship|-|ship|CI-ERROR-SHIP-0001|-
ship-platform|-|ship @SVC@|CI-ERROR-SHIP-0001|-
CASES
}

@test "_ci_capture passes max-ok rc, fails higher rc or stderr" {
    # What: max-ok rc passes; higher rc or stderr fails raw.
    # Why: one owner keeps grep rc 2 from reading as a miss.
    # From: Issue #1683 | PR #1858
    run _ci_capture 0 printf 'a\nb\n'
    [ "${status}" -eq 0 ]; [ "${output}" = $'a\nb' ]
    run _ci_capture 1 grep -x zz <<< "aa"
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
    run _ci_capture 1 grep -x aa <<< "aa"
    [ "${status}" -eq 0 ]; [ "${output}" = aa ]
    run _ci_capture 1 grep x "${BATS_TEST_TMPDIR}/no-such-file"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*'rc="2"'*"no-such-file"* ]]
    run _ci_capture 0 sh -c 'echo out; echo warn >&2'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*'rc="0"'*"warn"* ]]
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

# What: <n> distinct /27 slot addresses from the slot owner
# Why: probe targets live in validation slots, never fixed
# From: Issue #1683 | PR #1858
_slot_ips() {
    local ip
    local -A slots=()
    while [ "${#slots[@]}" -lt "$1" ]; do
        ip="$(_ci_validate_subnet "$(_val name)")" || return 1
        slots["${ip%/*}"]=1
    done
    printf '%s\n' "${!slots[@]}"
}

# What: stand-in answers for one compose service container
# Why: ci.sh finds a container by ps, then reads inspect
# From: Issue #1683 | PR #1858
_container() {
    local svc="$1" cid="$2" ip="$3" ports="${4:-}" env="${5:-}"
    _docker_answer " compose -p * ps -q ${svc} " 0 "${cid}"
    _docker_answer " inspect -f *NetworkSettings* ${cid} " 0 "${ip}"
    [ -z "${ports}" ] || _docker_answer " inspect -f *ExposedPorts* ${cid} " 0 "${ports}"
    [ -z "${env}" ] || _docker_answer " inspect -f *Config.Env* ${cid} " 0 "${env}"
}

# What: script one docker answer: glob, rc, out, err, times
# Why: the one stand-in answers any call; first match wins
# From: Issue #1683 | PR #1858
_docker_answer() {
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" >> "${DS}/answers"
}

# What: curl stand-in: Kea agent, DNS listener, ui pages
# Why: real setup.sh and ci.sh talk to them; no network
# From: Issue #1683 | PR #1858
_curl_stub() {
    _tool_stub "${BIN}" curl <<'STUB'
fmt="" data="" cfg="" out="" fail=0 url="${!#}" user=""
hdr=() form=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -w) fmt="${args[$((i + 1))]}" ;;
        -d) data="${args[$((i + 1))]}" ;;
        -H) hdr+=("${args[$((i + 1))]}") ;;
        -o) out="${args[$((i + 1))]}" ;;
        --data-urlencode) form+=("${args[$((i + 1))]}") ;;
        -K) cfg="$(cat)" ;;
        --*) ;;
        -*f*) fail=1 ;;
    esac
done
while IFS= read -r line; do
    [[ "${line}" =~ ^([a-z]+)\ =\ \"(.*)\"$ ]] || continue
    v="${BASH_REMATCH[2]//\\\"/\"}"
    v="${v//\\\\/\\}"
    case "${BASH_REMATCH[1]}" in header) hdr+=("${v}") ;; data) data="${v}" ;; user) user="${v}" ;; esac
done <<< "${cfg}"
printf '%s\n' "$*" >> "${DS}/curl.argv"
[ -z "${cfg}" ] || printf '%s\n' "${cfg}" >> "${DS}/curl.cfg"
[ ! -e "${DS}/fail-curl" ] || { echo "curl: (7) Failed to connect to ${url}" >&2; exit 7; }
field() { local f; for f in "${form[@]}"; do [ "${f%%=*}" != "$1" ] || printf '%s' "${f#*=}"; done; }
# What: one listener snapshot of a zone's current records
# Why: the listener records a snapshot after every write
# From: Issue #628 | PR #1858
snap() {
    local n=0
    [ -e "${DS}/listener-snapshots" ] && [ -e "${DS}/dns-records" ] && [ ! -e "${DS}/listener-nosnap" ] || return 0
    [ ! -e "${DS}/snap-n" ] || n="$(cat "${DS}/snap-n")"
    n=$(( n + 1 ))
    echo "${n}" > "${DS}/snap-n"
    cp "${DS}/dns-records" "${DS}/snap-${n}"
    jq -c --arg z "$1" --arg i "${n}" '.zones[$z] = ([{id: $i}] + (.zones[$z] // []))' \
        "${DS}/listener-snapshots" > "${DS}/ls.new" && mv "${DS}/ls.new" "${DS}/listener-snapshots"
}
status=200 body=""
rest="${url#*://}" path=""
[ "${rest}" = "${rest#*/}" ] || path="${rest#*/}"
case "${path}" in
    domains)
        [ ! -e "${DS}/ui-page" ] || body="$(cat "${DS}/ui-page")"
        [ ! -e "${DS}/ui-status" ] || status="$(cat "${DS}/ui-status")" ;;
    domains/*/add)
        printf '%s %s\n' "${path}" "${form[*]}" >> "${DS}/ui.posts"
        status=303
        [ ! -e "${DS}/ui-post-status" ] || status="$(cat "${DS}/ui-post-status")"
        if [ "${status}" = 303 ] && [ -e "${DS}/dns-records" ]; then
            z="${path#domains/}" z="${z%/add}." fq="$(field name).${z}"
            { grep -v "^${fq} " "${DS}/dns-records"; printf '%s %s\n' "${fq}" "$(field content)"; } > "${DS}/dr.new"
            mv "${DS}/dr.new" "${DS}/dns-records"
            snap "${z}"
        fi ;;
    dhcp/static/add)
        printf '%s %s\n' "${path}" "${form[*]}" >> "${DS}/ui.posts"
        status=303
        [ ! -e "${DS}/ui-post-status" ] || status="$(cat "${DS}/ui-post-status")"
        if [ "${status}" = 303 ] && [ -e "${DS}/kea-live" ]; then
            jq -c --arg s "$(field subnet_id)" --arg m "$(field mac)" --arg ip "$(field ip)" --arg h "$(field hostname)" \
                '.Dhcp4.subnet4 |= map(if (.id | tostring) == $s then .reservations += [{"hw-address": $m, "ip-address": $ip, hostname: $h}] else . end)' \
                "${DS}/kea-live" > "${DS}/kl.new" && mv "${DS}/kl.new" "${DS}/kea-live"
            if [ ! -e "${DS}/kea-no-snapshot" ]; then
                k=0
                [ ! -e "${DS}/kea-n" ] || k="$(cat "${DS}/kea-n")"
                k=$(( k + 1 ))
                echo "${k}" > "${DS}/kea-n"
                mkdir -p "$(cat "${DS}/kea-snapdir")/${k}" && cp "${DS}/kea-live" "$(cat "${DS}/kea-snapdir")/${k}/dhcp4.json"
            fi
        fi ;;
    api/secondary/register)
        printf '%s\n' "${data}" >> "${DS}/register.posts"
        body="$(jq -c '{nats_user: ("u-" + .name), nats_password: ("p-" + .name)}' <<< "${data}")"
        [ ! -e "${DS}/register-body" ] || body="$(cat "${DS}/register-body")"
        [ ! -e "${DS}/register-status" ] || status="$(cat "${DS}/register-status")" ;;
    "")
        [ -z "${cfg}" ] || printf '%s\n' "${cfg}" > "${DS}/kea.cfg"
        [ ! -e "${DS}/fail-kea" ] || exit 7
        printf '%s\n' "${url}" >> "${DS}/kea.urls"
        [ -z "${user}" ] || printf '%s\n' "${user%%:*}" >> "${DS}/kea.users"
        cmd="$(jq -r .command <<< "${data}")"
        printf '%s\n' "${cmd}" >> "${DS}/kea.commands"
        body='[{"result":0,"text":"ok"}]'
        if [ -e "${DS}/kea-${cmd}" ]; then
            body="$(cat "${DS}/kea-${cmd}")"
        elif [ -e "${DS}/kea-live" ]; then
            case "${cmd}" in
                config-get) body="$(jq -c '[{result: 0, arguments: .}]' "${DS}/kea-live")" ;;
                config-set) [ -e "${DS}/kea-norevert" ] || jq -c .arguments <<< "${data}" > "${DS}/kea-live" ;;
            esac
        fi
        [ ! -e "${DS}/kea-status" ] || status="$(cat "${DS}/kea-status")" ;;
    *)
        body="$(cat "${DS}/listener-${path}")"
        [ ! -e "${DS}/listener-status" ] || status="$(cat "${DS}/listener-status")"
        [ -z "${data}" ] || printf '%s\n' "${data}" >> "${DS}/listener.posts"
        auth="$(printf '%s\n' "${hdr[@]}" | grep -c '^X-API-Key: ')" mode=""
        [ ! -e "${DS}/listener-auth" ] || mode="$(cat "${DS}/listener-auth")"
        case "${mode}" in
            open) ;;
            anykey) [ "${auth}" -gt 0 ] || { status=401 body='{"error":"missing X-API-Key"}'; } ;;
            *) grep -qxF "X-API-Key: $(cat "${DS}/pdns-api-key")" <<< "$(printf '%s\n' "${hdr[@]}")" \
                   || { status=401 body='{"error":"missing or invalid X-API-Key"}'; } ;;
        esac
        if [ "${path}" = rollback ] && [ "${status}" = 200 ] && [ -e "${DS}/dns-records" ]; then
            id="$(jq -r .snapshot_id <<< "${data}")"
            [ ! -e "${DS}/snap-${id}" ] || cp "${DS}/snap-${id}" "${DS}/dns-records"
            [ -e "${DS}/listener-norecord" ] || snap "$(jq -r .zone <<< "${data}")"
        fi ;;
esac
if [ "${fail}" -eq 1 ] && [ "${status}" -ge 400 ]; then
    echo "curl: (22) The requested URL returned error: ${status}" >&2
    exit 22
fi
fmt="${fmt//\\n/$'\n'}"
if [ -n "${out}" ]; then printf '%s' "${body}" > "${out}"; else printf '%s' "${body}"; fi
printf '%s' "${fmt//"%{http_code}"/${status}}"
STUB
}

# What: sleep only advances the shell clock SECONDS
# Why: deadline loops run their SOT timeouts with no wait
# From: Issue #1683 | PR #1858
_virtual_clock() {
    sleep() { SECONDS=$(( SECONDS + ${1%%.*} )); }
}

# What: a PATH dir with every tool but the named ones
# Why: proves the "tool missing" paths with real tools
# From: Issue #1683 | PR #1858
_path_without() {
    local dir="$1" d x n t
    local -A pw_seen=()
    local -a pw_link=()
    shift
    mkdir -p "${dir}"
    for t in "$@"; do pw_seen["${t}"]=1; done
    # What: first PATH hit per name, then one ln for all.
    # Why: one ln per tool cost seconds per calling test.
    # From: Issue #1683 | PR #1858
    while IFS= read -r -d: d; do
        for x in "${d}"/*; do
            n="${x##*/}"
            [ -x "${x}" ] && [ -z "${pw_seen["${n}"]:-}" ] || continue
            pw_seen["${n}"]=1
            pw_link+=("${x}")
        done
    done <<< "${PATH}:"
    [ "${#pw_link[@]}" -eq 0 ] || ln -s "${pw_link[@]}" "${dir}/"
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

# What: fails calls whose arg matches; FAIL_TIMES caps it.
# Why: proves tool errors and retries without an outage.
# From: Issue #1683 | PR #1858
_fail_stub() {
    local bin="$1" tool="$2"
    _tool_stub "${bin}" "${tool}" <<'STUB'
tool="$(basename "$0")"
for arg in "$@"; do
    [ -n "${FAIL_MATCH:-}" ] && [[ "${arg}" == *"${FAIL_MATCH}" ]] || continue
    n=0
    if [ -n "${FAIL_COUNT:-}" ]; then
        n="$(( $(<"${FAIL_COUNT}") + 1 ))"
        printf '%s' "${n}" > "${FAIL_COUNT}"
    fi
    [ -z "${FAIL_TIMES:-}" ] || [ "${n}" -le "${FAIL_TIMES}" ] || break
    echo "${FAIL_TEXT:-${tool}: read error}" >&2
    exit "${FAIL_RC:-2}"
done
PATH="${PATH#*:}"
exec "${tool}" "$@"
STUB
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

# What: per row: registry/repo ref owners on a fixture SOT.
# Why: scan, sbom, assemble, verify must share one ref.
# From: Issue #1683 | PR #1858
@test "image-ref builds the one registry service@digest form" {
    local m nr case envs call rc want
    local -a ev av
    m="$(_val path)" nr="$(_val path)"
    local -A V=(
        [@REG@]="$(_val host).$(_val name)" [@OWN@]="$(_val name)" [@REPO@]="$(_val name)" [@S@]="$(_val name)"
        [@T@]="$(_val name)" [@DIG@]="$(_val digest)" [@OS@]="$(_val name)" [@PA@]="$(_val name)" [@ID@]="$(_val sha)"
    )
    V[@MIX@]="$(tr a-z A-Z <<< "${V[@OWN@]:0:2}")${V[@OWN@]:2}/$(tr a-z A-Z <<< "${V[@REPO@]}")"
    V[@P@]="${V[@OS@]}/${V[@PA@]}" V[@M@]="${m}" V[@NR@]="${nr}"
    _fill "$(printf '%s\n' 'release:' '  registry: @REG@' 'build_toolchain:' '  @T@:' '    build_type: toolchain' \
        'services:' '  @S@:' '    context: @S@' '    build_type: apk')" > "${m}"
    grep -v '^  registry:' "${m}" > "${nr}"
    while IFS='|' read -r case envs call rc want; do
        read -r -a ev <<< "$(_fill "${envs}")"
        read -r -a av <<< "$(_fill "${call}")"
        run env -u GITHUB_REPOSITORY CI_MANIFEST="${m}" "${ev[@]}" bash -c 'source "$1"; shift; "$@"' _ "${CI_SH}" "${av[@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${rc}" -eq 0 ] || [[ "${output}" != *"/${V[@S@]}"* ]] || { echo "${case}: ref printed: ${output}"; return 1; }
    done <<'CASES'
repo-lower|GITHUB_REPOSITORY=@MIX@|_ci_repo|0|=@OWN@/@REPO@
registry|GITHUB_REPOSITORY=@MIX@|_ci_registry|0|=@REG@
image-ref|GITHUB_REPOSITORY=@MIX@|_ci_image_ref @S@ @DIG@|0|=@REG@/@OWN@/@REPO@/@S@@@DIG@
image-tag|GITHUB_REPOSITORY=@MIX@|_ci_image_tag @S@ @P@ @ID@|0|=@REG@/@OWN@/@REPO@/@S@:sha-@ID@-@PA@
toolchain-ref|GITHUB_REPOSITORY=@MIX@|_ci_build_tools_image|0|=@REG@/@OWN@/@REPO@/@T@
no-owner|CI_MANIFEST=@M@|_ci_image_ref @S@ @DIG@|2|[CI-ERROR-CORE-0128] name="GITHUB_REPOSITORY"
no-registry|CI_MANIFEST=@NR@ GITHUB_REPOSITORY=@MIX@|_ci_image_ref @S@ @DIG@|2|[CI-ERROR-CORE-0005] key="release.registry"
CASES
}

# =========================================================
# SEMANTIC IMPACT
# =========================================================

@test "plan selects exactly the targets whose contexts a path touches" {
    # What: own context and named contexts pick candidates.
    # Why: no unrelated target and no prefix-only match.
    # From: Issue #1683
    local m e case sot path rc want row
    m="$(_val path)" e="$(_val path)"
    local -A V=(
        [@A@]="$(_val name)" [@B@]="$(_val name)" [@T@]="$(_val name)" [@D@]="$(_val name)" [@CA@]="$(_val name)"
        [@CB@]="$(_val name)" [@CT@]="$(_val name)" [@X1@]="$(_val name)" [@X2@]="$(_val name)" [@S@]="$(_val name)"
        [@N1@]="$(_val name)" [@N2@]="$(_val name)" [@F@]="$(_val name)"
    )
    _fill "$(printf '%s\n' 'services:' '  @A@:' '    context: @D@/@CA@' '  @B@:' '    context: @D@/@CB@' \
        'build_toolchain:' '  @T@:' '    context: @D@/@CT@' \
        'named_contexts:' '  @X1@:' '    path: @S@/@N1@' '  @X2@:' '    path: @S@/@N2@' \
        'dependency_graph:' '  @A@:' '    contexts: [@X1@, @X2@]' '  @B@:' '    contexts: [@X1@]')" > "${m}"
    _fill "$(printf '%s\n' 'services:' '  @A@:' '    build_type: @F@')" > "${e}"
    while IFS='|' read -r case sot path rc want; do
        [ "${sot}" = m ] && sot="${m}" || sot="${e}"
        CI_MANIFEST="${sot}" run bash "${CI_SH}" plan "$(_fill "${path}")"
        if [ "${rc}" -ne 0 ]; then
            _expect "${case}" "${rc}" "${want}" || return 1
            [[ "${output}" != *"=false"* && "${output}" != *"=true"* ]] || { echo "${case}: guessed: ${output}"; return 1; }
            continue
        fi
        row="$(grep -v 'CI-INFO' <<< "${output}" | paste -sd' ' -)"
        [ "${status}" -eq 0 ] && [ "${row}" = "$(_fill "${want}")" ] || { echo "${case}: rc ${status}: ${row}"; return 1; }
        [[ "${output}" == *"candidates only; identity/CAS decides build"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
own-context|m|@D@/@CA@/@F@|0|@A@=true @B@=false @T@=false
named-one-user|m|@S@/@N2@|0|@A@=true @B@=false @T@=false
named-two-users|m|@S@/@N1@|0|@A@=true @B@=true @T@=false
toolchain|m|@D@/@CT@/@F@|0|@A@=false @B@=false @T@=true
no-prefix-match|m|@D@/@CA@@F@/@F@|0|@A@=false @B@=false @T@=false
no-context|e|@D@/@CA@/@F@|2|[CI-ERROR-CORE-0009]
CASES
}

@test "an unreadable SOT fails every reader caller with raw" {
    # What: each caller row: rc 2 plus the raw reader error.
    # Why: a reader error must never read as an empty value.
    # From: Issue #1683 | PR #1858
    local call row
    local -A V=(
        [@SVC@]="$(_val name)" [@P@]="$(_val platform)" [@PATH@]="$(_val name)/$(_val name)"
        [@VAR@]="$(_val var)" [@DIR@]="${BATS_TEST_TMPDIR}" [@NOSOT@]="$(_val path)" [@ID@]="$(_val name)"
    )
    while IFS= read -r row; do
        [ -n "${row}" ] || continue
        read -r -a call <<< "$(_fill "${row}")"
        CI_MANIFEST="${V[@NOSOT@]}" GITHUB_REPOSITORY="$(_val name)/$(_val name)" \
            CI_COMPOSE_FILE="$(_val name)" run "${call[@]}"
        [ "${status}" -eq 2 ] && [[ "${output}" == *"No such file"* ]] \
            && [[ "${output}" =~ \[CI-ERROR-CORE-010[789]\]\ block= ]] && [[ "${output}" == *"manifest=\"${V[@NOSOT@]}\""* ]] \
            || { echo "${row}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
ci_service_field @SVC@ build_type
_ci_required_field @SVC@ context
_ci_platforms @SVC@
_ci_platform_field @P@ apk @ID@
ci_build_targets
_ci_alpine_build_arg --build-arg
_ci_service_packages @SVC@
_ci_apk_repositories @SVC@
_ci_apk_keys @SVC@
_ci_build_tools_smoke smoke_tools
_ci_variable_value @VAR@
_ci_plan_candidate @SVC@ @PATH@
_ci_identity_for @SVC@ @P@
ci_cmd_codeql_config
_ci_check_stable_external_images @DIR@
_ci_check_dockerfile_build_tools @DIR@
CASES
}

@test "core helpers fail with code, context and raw tool error" {
    # What: real failing input per helper: rc 2, code, raw.
    # Why: a CI log must show where, with what and why.
    # From: Issue #1683 | PR #1858
    local f site
    f="$(_val path)"
    site="$(_val name)"
    : > "${f}"
    run _ci_mktemp -d "${f}/$(_val name).XXXXXX"
    _expect mktemp 2 "[CI-ERROR-CORE-0110] args=\"-d ${f}/;Not a directory" || return 1
    run _ci_ls_files "${site}" "${BATS_TEST_TMPDIR}/$(_val name)" "*.$(_val name)"
    _expect ls-files 2 "[CI-ERROR-CHECK-0071] site=\"${site}\"" || return 1
    [[ "${output}" == *"cannot change to"* || "${output}" == *"No such file"* ]] || { echo "ls-files raw: ${output}"; return 1; }
}

# =========================================================
# SERVICE DEPENDENCIES
# =========================================================

# =========================================================
# BUILD IDENTITIES
# =========================================================

@test "identity is keyed, deterministic, per target and platform" {
    # What: 64-hex per SOT platform; moves on own content.
    # Why: NOOP/reuse needs stable ids that never collide.
    # From: Issue #1683 | PR #1858
    local r a1 a1b b1 a2 b0
    local -A V=(
        [@A@]="$(_val name)" [@B@]="$(_val name)" [@PK@]="$(_val name)" [@CA@]="$(_val name)" [@CB@]="$(_val name)"
        [@TS@]="$(_val name)" [@TP@]="$(_val name)" [@PKG@]="$(_val name)" [@P1@]="$(_val platform)"
        [@P2@]="$(_val platform)" [@X@]="$(_val platform)" [@AA@]="$(_val name)" [@AB@]="$(_val name)"
        [@F@]="$(_val name)" [@IMG@]="$(_val host)/$(_val name)@$(_val digest)"
    )
    V[@K1@]="${V[@P1@]##*/}" V[@K2@]="${V[@P2@]##*/}"
    r="$(_val path)"
    mkdir -p "${r}/${V[@CA@]}" "${r}/${V[@CB@]}"
    _val name > "${r}/${V[@CA@]}/${V[@F@]}"; _val name > "${r}/${V[@CB@]}/${V[@F@]}"
    git -C "${r}" init -q && git -C "${r}" add -A
    _fill "$(printf '%s\n' 'services:' '  @A@:' '    context: @CA@' '    build_type: @TS@' \
        '  @B@:' '    context: @CB@' '    build_type: @TS@' \
        '  @PK@:' '    context: @CB@' '    build_type: @TP@' '    packages: [@PKG@]' \
        'build_identity:' '  @TS@:' '    inputs: [source_sha]' '  @TP@:' '    inputs: [source_sha, package_versions]' \
        'base_images:' '  alpine: @IMG@' 'build_matrix:' '  platforms: [@P1@, @P2@]' \
        'platform_arch:' '  @K1@:' '    apk: @AA@' '  @K2@:' '    apk: @AB@')" > "${r}/m.yml"
    export CI_MANIFEST="${r}/m.yml" CI_REPO_ROOT="${r}"
    _id() { run --separate-stderr bash "${CI_SH}" identity "$@"; [ "${status}" -eq 0 ] || { echo "identity $*: rc ${status} ${stderr}"; return 1; }; }
    _id "${V[@A@]}" "${V[@P1@]}" && a1="${output}"
    [[ "${a1}" =~ ^platform=${V[@P1@]}\ identity=[0-9a-f]{64}$ ]] || { echo "shape: ${a1}"; return 1; }
    _id "${V[@A@]}" "${V[@P1@]}" && [ "${output}" = "${a1}" ] || { echo "not deterministic: ${output}"; return 1; }
    _id "${V[@B@]}" "${V[@P1@]}" && b1="${output}" && [ "${b1#*identity=}" != "${a1#*identity=}" ] || { echo "per target"; return 1; }
    _id "${V[@A@]}" "${V[@P2@]}" && a2="${output}" && [ "${a2#*identity=}" != "${a1#*identity=}" ] || { echo "per platform"; return 1; }
    _id "${V[@PK@]}" "${V[@P1@]}" && [[ "${output}" =~ ^platform=${V[@P1@]}\ identity=[0-9a-f]{64}$ ]] || { echo "pkgs: ${output}"; return 1; }
    _id "${V[@A@]}" && [ "${#lines[@]}" -eq 2 ] && [ "${lines[0]}" = "${a1}" ] && [ "${lines[1]}" = "${a2}" ] \
        || { echo "fan-out: ${output}"; return 1; }
    run bash "${CI_SH}" identity "${V[@A@]}" "${V[@X@]}"
    _expect foreign-platform 2 "[CI-ERROR-IDENTITY-0002] service=\"${V[@A@]}\"" || return 1
    # What: an edit in A's context moves A only, never B.
    # Why: impact is content identity, never a path guess.
    # From: Issue #1683 | PR #1858
    _id "${V[@B@]}" "${V[@P1@]}" && b0="${output}"
    _val name > "${r}/${V[@CA@]}/${V[@F@]}" && git -C "${r}" add -A
    _id "${V[@A@]}" "${V[@P1@]}" && a1b="${output}" && [ "${a1b}" != "${a1}" ] || { echo "A did not move"; return 1; }
    _id "${V[@B@]}" "${V[@P1@]}" && [ "${output}" = "${b0}" ] || { echo "B moved: ${output} vs ${b0}"; return 1; }
    sed -i '/^  platforms: \[/d' "${CI_MANIFEST}"
    run bash "${CI_SH}" identity "${V[@A@]}"
    _expect no-platforms 2 "[CI-ERROR-IDENTITY-0003]" || return 1
    [[ "${output}" != *"identity="* ]] || { echo "identity line leaked: ${output}"; return 1; }
}

# =========================================================
# PLATFORMS
# =========================================================

# What: SOT product services of one build type, in order.
# Why: tests derive examples from the SOT, never by name.
# From: Issue #1683 | PR #1858
_svcs_of_type() {
    local svcs s t
    svcs="$(ci_services)" || return 1
    for s in ${svcs}; do
        t="$(ci_service_field "${s}" build_type)" || return 1
        [ "${t}" != "$1" ] || printf '%s\n' "${s}"
    done
}

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
        [@REF@]="$(_val host)/$(_val name)/$(_val name):$(_val name)" [@CRATE@]="$(_val name)" [@HOST@]="$(_val host)"
        [@GREF@]="refs/$(_val name)" [@PKG@]="$(_val name)" [@FILE@]="$(_val name).c" [@SYM@]="$(_val name)"
        [@MS@]="$(_val int 1 900)ms" [@PID@]="$(_val int 1 9000)" [@URL@]="$(_val url)/$(_val name).json"
        [@TAG@]="$(_val name)" [@TXT@]="$(_val name) $(_val name)"
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
distcc|accel|distcc[@PID@] (dcc_build_somewhere) ERROR: failed to distribute and fallbacks are disabled|transient
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

@test "rust test: off by default; on runs fmt, clippy, test via sccache" {
    # What: per row: SOT + env -> SKIP, ok, or a coded fail.
    # Why: AG-VAL-008: no cargo check; temp error stops.
    # From: Issue #1683 | PR #1858
    local bin log m
    bin="$(_val path)" log="$(_val path)" m="$(_val path)"
    local case envs svc rc want cargo
    local -a ev
    local -A V=(
        [@R@]="$(_val name)" [@NC@]="$(_val name)" [@C@]="$(_val name)"
        [@TMP@]="${BATS_TEST_TMPDIR}/$(_val name)" [@GONE@]="${BATS_TEST_TMPDIR}/$(_val name)"
    )
    mkdir -p "${V[@TMP@]}"
    _tool_stub "${bin}" cargo <<STUB
echo "\$1 wrapper=\${RUSTC_WRAPPER:-none} dir=\${SCCACHE_DIR:-none} args=\$*" >> "${log}"
STUB
    _stub_sccache "${bin}" never
    {
        _fill "$(printf '%s\n' 'services:' '  @R@:' '    build_type: rust' '    crate: @C@' '  @NC@:' '    build_type: rust')"
        printf '\n'
        _sot_block ci_variables
    } > "${m}"
    while IFS='|' read -r case envs svc rc want cargo; do
        ev=(); [ "${envs}" = - ] || read -r -a ev <<< "$(_fill "${envs}")"
        rm -f "${log}"
        run _cache_env_clean env -u CI_RUST_VALIDATION SCCACHE_REDIS_MODE=optional "${ev[@]}" CI_MANIFEST="${m}" \
            CI_REPO_ROOT="${BATS_TEST_TMPDIR}" PATH="${bin}:${PATH}" \
            bash -c 'source "$1"; _ci_test_rust "$2"' _ "${CI_SH}" "$(_fill "${svc}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "${cargo}" = - ]; then
            [ ! -e "${log}" ] || { echo "${case}: cargo ran: $(cat "${log}")"; return 1; }
            continue
        fi
        [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "${cargo}" ] || { echo "${case}: $(cat "${log}")"; return 1; }
        [ "$(grep -c -F -- "wrapper=sccache dir=${V[@TMP@]}/sccache " "${log}")" -eq 3 ] \
            && [ "$(grep -c -F -- "-p ${V[@C@]}" "${log}")" -eq 3 ] || { echo "${case}: $(cat "${log}")"; return 1; }
    done <<'CASES'
off-by-sot|-|@R@|0|tested=SKIP;AG-VAL-008|-
on|CI_RUST_VALIDATION=true CI_TMPDIR=@TMP@|@R@|0|[CI-INFO-CACHE-0002];tested=ok|fmt clippy test
no-crate|CI_RUST_VALIDATION=true CI_TMPDIR=@TMP@|@NC@|2|[CI-ERROR-TEST-0005] service="@NC@"|-
temp-error|CI_RUST_VALIDATION=true CI_TMPDIR=@GONE@|@R@|2|[CI-ERROR-CORE-0110];[CI-ERROR-TEST-0009]|-
CASES
}

# What: export step args: SOT kill timeout, cache pair only.
# Why: only the GHA cache runtime may reach later steps.
# From: Issue #1683 | PR #1858
@test "gha-runtime-args: kill-bounded step exports only the GHA cache runtime pair" {
    local t out envf other args got
    local -a argv
    t="$(_val int 5 120)"; out="$(_val path)"; envf="$(_val path)"; other="ACTIONS_$(_val name)"
    : > "${out}"
    CI_GHA_RUNTIME_EXPORT_TIMEOUT="${t}" GITHUB_OUTPUT="${out}" run ci_cmd_gha_runtime_args
    _expect args 0 "-s KILL ${t} /bin/sh -c " || return 1
    args="${lines[${#lines[@]}-1]}"
    [ "$(<"${out}")" = "args=${args}" ] || { echo "step output: $(<"${out}")"; return 1; }
    mapfile -t argv < <(printf '%s' "${args}" | xargs -n1 printf '%s\n')
    : > "${envf}"
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

# What: per row: build type -> SKIP, smoke at image or fail.
# Why: apk has no source tests; a smoke failure fails test.
# From: Issue #1683 | PR #1858
@test "test dispatches per build type and fails closed" {
    local m case fault svc rc want ran
    m="$(_val path)"
    local -A V=(
        [@APK@]="$(_val name)" [@TOOL@]="$(_val name)" [@ODD@]="$(_val name)" [@BT@]="$(_val name)"
        [@RUN@]="$(_val name)" [@CV@]="$(_val var)" [@IMG@]="$(_val name)@$(_val digest)" [@FAULT@]="$(_val name)"
    )
    _tool_stub "${BIN}" "${V[@RUN@]}" <<< '[ ! -e "${DS}/smoke-fail" ] || { echo "${FAULT}"; exit 1; }'
    {
        _fill "$(printf '%s\n' 'services:' '  @APK@:' '    build_type: apk' '  @ODD@:' '    build_type: @BT@' \
            'build_toolchain:' '  @TOOL@:' '    build_type: toolchain' '    smoke_tools: [@RUN@]' '    smoke_runs: [@RUN@]')"
        printf '\n'
        _sot_block ci_variables
    } > "${m}"
    while IFS='|' read -r case fault svc rc want ran; do
        rm -f "${DS}/smoke-fail" "${DS}/run-images"
        [ "${fault}" = - ] || : > "${DS}/${fault}"
        run env CI_MANIFEST="${m}" CI_TOOLCHAIN_IMAGE="${V[@IMG@]}" FAULT="${V[@FAULT@]}" \
            CI_TOOLCHAIN_COMPILERS="${V[@CV@]}=${V[@RUN@]}" bash "${CI_SH}" test "$(_fill "${svc}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "${ran}" = - ]; then
            [ ! -e "${DS}/run-images" ] || { echo "${case}: smoke ran: $(cat "${DS}/run-images")"; return 1; }
        else
            [ "$(cat "${DS}/run-images")" = "$(_fill "${ran}")" ] || { echo "${case}: ran $(cat "${DS}/run-images")"; return 1; }
        fi
    done <<'CASES'
apk-skip|-|@APK@|0|service=@APK@ tested=SKIP reason=|-
toolchain-ok|-|@TOOL@|0|service=@TOOL@ tested=ok|@IMG@
toolchain-fail|smoke-fail|@TOOL@|2|[CI-ERROR-TEST-0003] service="@TOOL@";[CI-ERROR-TEST-0011] service="@TOOL@";@FAULT@|@IMG@
unknown-type|-|@ODD@|2|[CI-ERROR-TEST-0003];[CI-ERROR-TEST-0004] service="@ODD@" build_type="@BT@"|-
CASES
}

@test "temp root: tmpfs refused, /var/tmp made, failure coded" {
    # What: /tmp refused; subdir made; bad root fails rc 2.
    # Why: bare mktemp in tools must land on disk, not RAM.
    # From: Issue #1683 | PR #1858
    local base f d made
    base="/var/tmp/$(_val name)" f="$(_val path)"
    d="${base}/$(_val name)"
    : > "${f}"
    CI_TMPDIR=/tmp CI_SCAN_CMD="$(_stub 'exit 0')" GHCR_USERNAME="$(_val name)" GHCR_TOKEN="$(_val name)" \
        run bash "${CI_SH}" scan "$(ci_services | awk 'NR == 1')" "$(_val digest)"
    _expect tmpfs-command 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR=/tmp run bash "${CI_SH}" check comment-length
    _expect tmpfs-check 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="${d}" run bash -c 'source "$1"; _ci_tmp_init; echo "t=${TMPDIR}"' _ "${CI_SH}"
    made=no; [ ! -d "${d}" ] || made=yes
    rm -rf "${base}"
    _expect created 0 "t=${d}" || return 1
    [ "${made}" = yes ] || { echo "not created: ${d}"; return 1; }
    CI_TMPDIR="${f}/x" run _ci_tmp_init
    _expect uncreatable 2 "[CI-ERROR-CORE-0111] dir=\"${f}/x\";Not a directory" || return 1
}

@test "proxy init maps each runner and CA case" {
    # What: per row: runner env -> proxy env, names, CA.
    # Why: AG-CI-009: self-hosted proxy only, CA job-local.
    # From: Issue #1683 | PR #1858
    local sys case envs probe rc want
    sys="$(_val path)"
    local -a ev
    local -A P=(
        [names]='echo "names=$(_ci_proxy_names | wc -l)"'
        [env]='echo "h=${https_proxy} n=${NO_PROXY}"; _ci_proxy_names | tr "\n" " "'
        [bundle]='cat "${CARGO_HTTP_CAINFO}"; [ "${CURL_CA_BUNDLE}" = "${CARGO_HTTP_CAINFO}" ] && echo same; stat -c %a "${CARGO_HTTP_CAINFO}"'
        [none]=':'
    )
    local -A V=(
        [@PROXY@]="$(_val url)" [@EXCL@]="$(_val host)" [@SYSCA@]="$(_val name)" [@CA@]="$(_val name)"
        [@SYS@]="${sys}" [@NOFILE@]="${BATS_TEST_TMPDIR}/$(_val name)/$(_val name)"
    )
    printf '%s\n' "${V[@SYSCA@]}" > "${sys}"
    while IFS='|' read -r case envs probe rc want; do
        envs="$(_fill "${envs}")" want="$(_fill "${want}")"
        read -r -a ev <<< "${envs}"
        run env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy \
            "${ev[@]}" CI_TMPDIR="${BATS_TEST_TMPDIR}" \
            bash -c 'source "$1"; _ci_proxy_init || exit; eval "$2"' _ "${CI_SH}" "${P[${probe}]}"
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
hosted-off|RUNNER_ENVIRONMENT=github-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@|names|0|[CI-INFO-CORE-0113] proxy=off runner="github-hosted" http_set=yes;names=0
self-hosted|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_EXCLUSION=@EXCL@|env|0|[CI-INFO-CORE-0007];h=@PROXY@ n=@EXCL@;HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
ca-bundle|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_CA=@CA@ CI_SYSTEM_CA_BUNDLE=@SYS@|bundle|0|@SYSCA@;@CA@;same;600
no-system-bundle|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_CA=@CA@ CI_SYSTEM_CA_BUNDLE=@NOFILE@|none|2|[CI-ERROR-CORE-0112] system_bundle="@NOFILE@";No such file
CASES
}

@test "scan is clean on /var/tmp with auth and a passing backend" {
    # What: authed + /var/tmp + green scan -> clean.
    # Why: The one success path for scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=clean"* ]]
    [[ "${output}" == *"tmpdir=/var/tmp"* ]]
}

@test "scan fails on a finding backend" {
    # What: A backend exit 1 is a genuine finding.
    # Why: HIGH/CRITICAL findings fail the scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub 'exit 1')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0005"* ]]
}

@test "scan escalates a DB-unavailable backend, not a finding" {
    # What: A backend exit 3 is a DB outage, not a finding.
    # Why: An outage must escalate, never reject the image.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub 'exit 3')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0006"* ]]
}

# =========================================================
# CACHE FALLBACK
# =========================================================

# =========================================================
# REGISTRY / PUBLISH / READBACK
# =========================================================

# What: GHCR and Docker Hub login rows over the one owner
# Why: tokens stay off argv and logs; retries stay visible
# From: Issue #1683 | PR #1858
@test "registry logins: GHCR required, Docker Hub optional, retried" {
    local name call ghcr hub fault rc logins want got
    CI_RETRY_MAX_ATTEMPTS="$(_val int 2 6)"
    export CI_RETRY_MAX_ATTEMPTS CI_RETRY_BACKOFF_BASE_SECONDS=0
    local -A V=(
        [@REG@]="$(_val host)" [@GU@]="$(_val name)" [@GT@]="$(_val name)" [@HU@]="$(_val name)"
        [@HT@]="$(_val name)" [@TXT@]="$(_val name) $(_val name)" [@MAX@]="${CI_RETRY_MAX_ATTEMPTS}"
    )
    V[@GSHA@]="$(printf '%s' "${V[@GT@]}" | sha256sum | cut -d' ' -f1)"
    V[@HSHA@]="$(printf '%s' "${V[@HT@]}" | sha256sum | cut -d' ' -f1)"
    # What: the registry is the row's fresh host
    # Why: the expected argv must not come from ci.sh logic
    # From: Issue #1683 | PR #1858
    _ci_registry() { printf '%s\n' "${V[@REG@]}"; }
    # What: two Docker Hub logins in one process
    # Why: the second call must not log in again
    # From: Issue #1095 | PR #1858
    _hub_twice() { _ci_dockerhub_login && _ci_dockerhub_login; }
    while IFS='|' read -r name call ghcr hub fault rc logins want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        unset _CI_DOCKERHUB_DONE GHCR_USERNAME GHCR_TOKEN DOCKERHUB_USERNAME DOCKERHUB_TOKEN
        [ "${ghcr}" = - ] || export GHCR_USERNAME="${V[@GU@]}" GHCR_TOKEN="${V[@GT@]}"
        case "${hub}" in
            half) export DOCKERHUB_USERNAME="${V[@HU@]}" ;;
            full) export DOCKERHUB_USERNAME="${V[@HU@]}" DOCKERHUB_TOKEN="${V[@HT@]}" ;;
        esac
        case "${fault%%:*}" in
            once) _docker_answer ' login *' 1 '' "$(_fill "${fault#*:}")" 1 ;;
            always) _docker_answer ' login *' 1 '' "$(_fill "${fault#*:}")" ;;
        esac
        run "${call}"
        output+=$'\n'"--- docker.log"$'\n'"$(cat "${DS}/docker.log")"
        _expect "${name}" "${rc}" "$(_fill "${want}")" || return 1
        got="$(awk '/^login / { n++ } END { print n + 0 }' "${DS}/docker.log")"
        [ "${got}" -eq "$(_fill "${logins}")" ] || { echo "${name}: ${got} logins: ${output}"; return 1; }
        [[ "${output}" != *"${V[@GT@]}"* && "${output}" != *"${V[@HT@]}"* ]] || { echo "${name}: token shown: ${output}"; return 1; }
    done <<'CASES'
no-ghcr|_ci_require_ghcr_auth|-|full|-|2|0|[CI-ERROR-BUILD-0002]
ghcr-only|_ci_require_ghcr_auth|set|none|-|0|1|[CI-NOTICE-BUILD-0020];--- docker.log;login @REG@ -u @GU@ --password-stdin;stdin-sha256=@GSHA@
ghcr-then-hub|_ci_require_ghcr_auth|set|full|-|0|2|--- docker.log;login @REG@ -u @GU@ --password-stdin;stdin-sha256=@GSHA@;login -u @HU@ --password-stdin;stdin-sha256=@HSHA@
ghcr-denied|_ci_require_ghcr_auth|set|full|always:Error response from daemon: Get "https://@REG@/v2/": denied: denied|2|1|[CI-ERROR-BUILD-0011] op=registry cmd="_ci_registry_login_once" cls=permanent attempt=1/@MAX@;denied: denied;[CI-ERROR-BUILD-0015] registry="@REG@";denied: denied
ghcr-retry|_ci_require_ghcr_auth|set|none|once:connection reset by peer|0|2|[CI-WARN-BUILD-0016] op=registry cmd="_ci_registry_login_once" cls=transient attempt=1/@MAX@;connection reset by peer;[CI-INFO-BUILD-0017] op=registry cmd="_ci_registry_login_once" attempt=2/@MAX@;[CI-NOTICE-BUILD-0020]
ghcr-exhausted|_ci_require_ghcr_auth|set|none|always:connection reset by peer|2|@MAX@|[CI-WARN-BUILD-0016] op=registry cmd="_ci_registry_login_once" cls=transient attempt=1/@MAX@;[CI-ERROR-BUILD-0011] op=registry cmd="_ci_registry_login_once" cls=transient attempt=@MAX@/@MAX@;[CI-ERROR-BUILD-0015] registry="@REG@"
hub-none|_ci_dockerhub_login|-|none|-|0|0|[CI-NOTICE-BUILD-0020]
hub-half|_ci_dockerhub_login|-|half|-|2|0|[CI-ERROR-BUILD-0021]
hub-once|_hub_twice|-|full|-|0|1|--- docker.log;login -u @HU@ --password-stdin;stdin-sha256=@HSHA@
hub-denied|_ci_dockerhub_login|-|full|always:unauthorized: @TXT@|2|1|[CI-ERROR-BUILD-0011] op=registry cmd="_ci_registry_login_once" cls=permanent attempt=1/@MAX@;unauthorized: @TXT@
CASES
}

# What: ship: built, bake fail, no repo, reuse, no digest
# Why: one chain owner; only a built image is pushed
# From: Issue #1683 | PR #1858
@test "ship publishes and verifies only a built image" {
    local name result bake repo digest rc want deny d SHIP_RESULT SHIP_BAKE SHIP_DIGEST
    local -a ds
    local -A V=(
        [@REG@]="$(_val host)" [@REPO@]="$(_val name)/$(_val name)" [@SVC@]="$(_val name)"
        [@PLAT@]="$(_val platform)" [@ID@]="$(_val sha)" [@DIG@]="$(_val digest)"
    )
    V[@ARCH@]="${V[@PLAT@]##*/}"
    # What: stand-ins print what ship hands to each step
    # Why: ship owns order and hand-off, not the steps
    # From: Issue #1683 | PR #1858
    _ci_registry() { printf '%s\n' "${V[@REG@]}"; }
    ci_cmd_build() { echo "service=$1 platform=$2 result=${SHIP_RESULT} identity=${V[@ID@]}"; }
    _ci_bake_check() { echo "BAKE $1"; [ "${SHIP_BAKE}" = ok ] || return 2; }
    ci_cmd_publish() { echo "PUBLISH service=$1 platform=$2 published=${SHIP_DIGEST} identity=${V[@ID@]}"; }
    ci_cmd_verify() { echo "VERIFY $1 $2 $3"; }
    while IFS='|' read -r name result bake repo digest rc want deny; do
        SHIP_RESULT="${result}" SHIP_BAKE="${bake}" SHIP_DIGEST="$(_fill "${digest}")"
        unset GITHUB_REPOSITORY
        [ "${repo}" = - ] || export GITHUB_REPOSITORY="${V[@REPO@]}"
        run ci_cmd_ship "${V[@SVC@]}" "${V[@PLAT@]}"
        _expect "${name}" "${rc}" "$(_fill "${want}")" || return 1
        IFS=';' read -r -a ds <<< "${deny}"
        for d in "${ds[@]}"; do
            [ "${d}" = - ] || [[ "${output}" != *"${d}"* ]] || { echo "${name}: ${d} ran: ${output}"; return 1; }
        done
    done <<'CASES'
built|built|ok|set|@DIG@|0|BAKE @REG@/@REPO@/@SVC@:sha-@ID@-@ARCH@;PUBLISH service=@SVC@ platform=@PLAT@ published=@DIG@;VERIFY @SVC@ @DIG@ @PLAT@|-
bake-fails|built|fail|set|@DIG@|2|BAKE @REG@/@REPO@/@SVC@:sha-@ID@-@ARCH@|PUBLISH;VERIFY
no-repo|built|ok|-|@DIG@|2|[CI-ERROR-SHIP-0003] service="@SVC@" platform="@PLAT@";GITHUB_REPOSITORY|BAKE;PUBLISH
reuse|reuse-accepted|ok|set|@DIG@|0|result=reuse-accepted|BAKE;PUBLISH;VERIFY
no-digest|built|ok|set||2|[CI-ERROR-SHIP-0002] service="@SVC@" platform="@PLAT@"|VERIFY
CASES
}

# =========================================================
# ASSEMBLY
# =========================================================

# What: A valid 64-hex test digest from one char.
# Why: One primitive; assembly/promote/release share it.
# From: Issue #1683
_test_digest() {
    local c="$1" out=""
    while [ "${#out}" -lt 64 ]; do out="${out}${c}"; done
    printf 'sha256:%s' "${out}"
}

# What: ci.sh assemble per platform, index and backend row
# Why: an index only from ACCEPTED digests; never overwrite
# From: Issue #1683 | PR #1858
@test "assemble merges only ACCEPTED digests and never overwrites" {
    local case first index auth create rc want svc img itag raw p i d
    local -a plats digs
    svc="$(_ci_block_keys services | head -n 1)" && mapfile -t plats < <(_ci_platforms "${svc}") || return 1
    _cas_setup
    cd "${CAS_A}" || return 1
    GITHUB_REPOSITORY="$(_val name)/$(_val name)" GITHUB_SHA="$(_val sha)"
    export GITHUB_REPOSITORY GITHUB_SHA
    img="$(_ci_registry)/$(_ci_repo)/${svc}" && itag="${img}:sha-${GITHUB_SHA}" || return 1
    local -A V=([@IDX@]="$(_val digest)" [@N@]="${#plats[@]}" [@ERR@]="$(_val name)")
    while IFS='|' read -r case first index auth create rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        : > "${DS}/docker.log"
        _ledger_fresh
        digs=()
        for (( i = 0; i < ${#plats[@]}; i++ )); do
            digs+=("$(_val digest)")
            p=PRESENT_ACCEPTED
            [ "${i}" -ne 0 ] || p="${first}"
            _artifact "${p}" "${svc}" "${plats[i]}" "${digs[i]}" || return 1
        done
        raw="$(for (( i = 0; i < ${#plats[@]}; i++ )); do
            d="${digs[i]}"
            [ "${index}" != divergent ] || [ "${i}" -ne 0 ] || d="$(_val digest)"
            printf '%s %s\n' "${plats[i]}" "${d}"
        done | jq -Rnc '{manifests: [inputs | split(" ") | {digest: .[1],
            platform: {os: (.[0] | split("/")[0]), architecture: (.[0] | split("/")[1])}}]}')"
        case "${index}" in
            none) _docker_answer " buildx imagetools inspect ${itag} --format *" 1 '' "ERROR: ${itag}: not found" 1
                _docker_answer " buildx imagetools inspect ${itag} --format *" 0 "${V[@IDX@]}" ;;
            same|divergent) _docker_answer " buildx imagetools inspect ${itag} --format *" 0 "${V[@IDX@]}"
                _docker_answer " buildx imagetools inspect ${itag} --raw " 0 "${raw}" ;;
            unknown) _docker_answer " buildx imagetools inspect ${itag} --format *" 1 '' "denied: ${V[@ERR@]}" ;;
        esac
        if [ "${create}" = ok ]; then
            _docker_answer " buildx imagetools create --tag ${itag} *" 0
        else
            _docker_answer " buildx imagetools create --tag ${itag} *" 1 '' "${V[@ERR@]}"
        fi
        if [ "${auth}" = yes ]; then
            GHCR_USERNAME="$(_val name)" GHCR_TOKEN="$(_val name)" run bash "${CI_SH}" assemble "${svc}"
        else
            GHCR_USERNAME="" GHCR_TOKEN="" run bash "${CI_SH}" assemble "${svc}"
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        case "${case}" in
            assembled) grep -qxF -- "buildx imagetools create --tag ${itag}$(for d in "${digs[@]}"; do printf ' %s@%s' "${img}" "${d}"; done)" "${DS}/docker.log" ;;
            backend-fail) grep -q '^buildx imagetools create ' "${DS}/docker.log" ;;
            *) [ "$(grep -c '^buildx imagetools create ' "${DS}/docker.log")" -eq 0 ] ;;
        esac || { echo "${case}: create calls: $(grep 'imagetools create' "${DS}/docker.log")"; return 1; }
    done <<'CASES'
unknown|UNKNOWN|none|yes|ok|2|[CI-ERROR-ASSEMBLE-0002];state="UNKNOWN"
unverified|PRODUCED_UNVERIFIED|none|yes|ok|2|[CI-ERROR-ASSEMBLE-0002];state="PRODUCED_UNVERIFIED"
missing|MISSING_CONFIRMED|none|yes|ok|2|[CI-ERROR-ASSEMBLE-0002];state="MISSING_CONFIRMED"
mismatch|MISMATCH|none|yes|ok|2|[CI-ERROR-ASSEMBLE-0002];state="MISMATCH"
assembled|PRESENT_ACCEPTED|none|yes|ok|0|result=assembled assembled=@IDX@ platforms=@N@
reuse|PRESENT_ACCEPTED|same|yes|ok|0|result=reuse-index assembled=@IDX@ platforms=@N@
divergent|PRESENT_ACCEPTED|divergent|yes|ok|2|[CI-ERROR-ASSEMBLE-0004]
index-unknown|PRESENT_ACCEPTED|unknown|yes|ok|2|[CI-ERROR-ASSEMBLE-0007]
noauth|PRESENT_ACCEPTED|none|no|ok|2|[CI-ERROR-BUILD-0002]
backend-fail|PRESENT_ACCEPTED|none|yes|fail|2|[CI-ERROR-ASSEMBLE-0005]
CASES
}

# =========================================================
# PROMOTION
# =========================================================

# What: A candidate holding every SOT product service.
# Why: Stack-atomic promotion needs every service.
# From: Issue #1683
_promote_full_candidate() {
    local svcs
    svcs="$(ci_services | tr '\n' ' ')"
    _stub "for s in ${svcs}; do echo \"\$s=$1\"; done"
}
_promote_lock() { _stub 'echo "LOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }
_promote_unlock() { _stub 'echo "UNLOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }

# What: per row: target and stack -> moved, kept or an id
# Why: §50-53: atomic move, readback, lock always freed
# From: Issue #1683 | PR #1858
@test "promote moves one target stack-atomically with readback and lock" {
    local case target cand valid rb rc want locks ch got
    local -a ev
    local log="${BATS_TEST_TMPDIR}/lock.log"
    local -A V=([@X@]="$(_val name)" [@V@]="v$(_val semver)" [@D@]="$(_val digest)" [@OD@]="$(_val digest)")
    ch="$(_ci_mutable_channels)"
    V[@CH@]="${ch%%$'\n'*}"
    V[@CH2@]="${ch##*$'\n'}"
    local -A S=(
        [full]="$(_promote_full_candidate "${V[@D@]}")"
        [partial]="$(_stub "echo $(ci_services | head -n 1)=${V[@D@]}")"
        [moved]="$(_stub "if [ -f \"\${BATS_TEST_TMPDIR}/moved.\$1\" ]; then echo ${V[@D@]}; fi")"
        [same]="$(_stub "echo ${V[@D@]}")"
        [other]="$(_stub "echo ${V[@OD@]}")"
    )
    while IFS='|' read -r case target cand valid rb rc want locks; do
        rm -f "${log}" "${BATS_TEST_TMPDIR}"/moved.*
        ev=(CI_STACK_CANDIDATE_CMD="${S[${cand}]}" CI_CHANNEL_READBACK_CMD="${S[${rb}]}"
            CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)"
            CI_PROMOTE_MOVE_CMD="$(_stub 'touch "${BATS_TEST_TMPDIR}/moved.$1"')"
            GHCR_USERNAME="$(_val name)" GHCR_TOKEN="$(_val name)")
        [ "${valid}" = - ] || ev+=(CI_STACK_VALIDATED="${valid}")
        if [ "${target}" = - ]; then
            run env -u CI_STACK_VALIDATED "${ev[@]}" bash "${CI_SH}" promote
        else
            run env -u CI_STACK_VALIDATED "${ev[@]}" bash "${CI_SH}" promote "$(_fill "${target}")"
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        got="$(paste -sd, "${log}" 2> /dev/null)" || got=""
        [ "${got}" = "$(_fill "${locks#-}")" ] || { echo "${case}: lock log '${got}' want '${locks}'"; return 1; }
    done <<'CASES'
no-target|-|full|SUCCESS|moved|2|[CI-ERROR-PROMOTE-0001]|-
sha-target|sha-@X@|full|SUCCESS|moved|2|[CI-ERROR-PROMOTE-0002] channel="sha-@X@"|-
unknown-target|@X@|full|SUCCESS|moved|2|[CI-ERROR-PROMOTE-0002] channel="@X@"|-
incomplete|@CH@|partial|SUCCESS|moved|2|[CI-ERROR-PROMOTE-0004]|-
not-validated|@CH@|full|-|moved|2|[CI-ERROR-PROMOTE-0005]|-
promoted|@CH@|full|SUCCESS|moved|0|channel=@CH@ result=promoted|LOCK @CH@,UNLOCK @CH@
promoted-tag|@V@|full|SUCCESS|moved|0|channel=@V@ result=promoted|LOCK @V@,UNLOCK @V@
promoted-rc|@V@-rc.1|full|SUCCESS|moved|0|channel=@V@-rc.1 result=promoted|LOCK @V@-rc.1,UNLOCK @V@-rc.1
current|@CH2@|full|SUCCESS|same|0|channel=@CH2@ result=already-promoted|-
mismatch|@CH@|full|SUCCESS|other|2|[CI-ERROR-PROMOTE-0009]|LOCK @CH@,UNLOCK @CH@
CASES
}

# What: per row: ref, gate and tip -> promoted targets or id
# Why: one ref owner; a release tag passes AG-REL-011 first
# From: Issue #1683 | PR #1858
@test "promote-ref promotes the ref's targets; a release tag passes the gate" {
    local case ref env rc want calls got
    local -a ev parts
    local m="${BATS_TEST_TMPDIR}/ch.yml" log="${BATS_TEST_TMPDIR}/promote-calls"
    local -A V=(
        [@SHA@]="$(_val sha)" [@OTHER@]="$(_val sha)" [@V@]="v$(_val semver)" [@BR@]="refs/heads/$(_val name)"
        [@OK@]="$(_stub 'exit 0')" [@STALE@]="$(_stub 'exit 1')" [@FAIL@]="$(_stub 'exit 2')"
    )
    printf '%s\n' 'release:' '  channels:' '    ch-b:' '      mutable: true' '    ch-a:' '      mutable: true' \
        '      ref: refs/heads/b-a' '      release_tags: true' '  default_channel: ch-b' > "${m}"
    _sot_block ci_variables >> "${m}"
    V[@TIP@]="$(_stub "echo ${V[@SHA@]}")"
    V[@MOVED@]="$(_stub "echo ${V[@OTHER@]}")"
    while IFS='|' read -r case ref env rc want calls; do
        : > "${log}"
        ev=(CI_MANIFEST="${m}" GITHUB_REF="$(_fill "${ref}")" GITHUB_SHA="${V[@SHA@]}" CI_PROMOTE_REQUESTED_CHANNEL=
            CI_PROMOTE_TIP_CMD="${V[@TIP@]}" CI_RELEASE_VALIDATION_CMD="${V[@OK@]}" PROMOTE_CALLS="${log}"
            CI_PROMOTE_ONE_CMD="$(_stub 'echo "$1" >> "${PROMOTE_CALLS}"')")
        if [ "${env}" != - ]; then
            IFS=';' read -r -a parts <<< "$(_fill "${env}")"
            ev+=("${parts[@]}")
        fi
        run env "${ev[@]}" bash "${CI_SH}" promote-ref
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        got="$(paste -sd, "${log}")"
        [ "${got}" = "$(_fill "${calls#-}")" ] || { echo "${case}: promoted '${got}' want '${calls}'"; return 1; }
    done <<'CASES'
branch|refs/heads/b-a|-|0|-|ch-a
branch-requested|refs/heads/b-a|CI_PROMOTE_REQUESTED_CHANNEL=ch-b|0|-|ch-a,ch-b
branch-requested-same|refs/heads/b-a|CI_PROMOTE_REQUESTED_CHANNEL=ch-a|0|-|ch-a
branch-no-gate|refs/heads/b-a|CI_RELEASE_VALIDATION_CMD=@STALE@|0|-|ch-a
branch-superseded|refs/heads/b-a|CI_PROMOTE_TIP_CMD=@MOVED@|0|promote=superseded ref=refs/heads/b-a tip=@OTHER@ sha=@SHA@|-
branch-tip-unknown|refs/heads/b-a|CI_PROMOTE_TIP_CMD=@FAIL@|2|[CI-ERROR-PROMOTE-0013]|-
branch-no-channel|@BR@|-|0|promote=noop reason=no-targets ref=@BR@|-
tag|refs/tags/@V@|-|0|-|@V@,ch-a
tag-rc|refs/tags/@V@-rc.4|-|0|-|@V@-rc.4
tag-stale|refs/tags/@V@|CI_RELEASE_VALIDATION_CMD=@STALE@|2|[CI-ERROR-RELEASE-0001] ref="refs/tags/@V@"|-
tag-gate-unknown|refs/tags/@V@|CI_RELEASE_VALIDATION_CMD=@FAIL@|2|[CI-ERROR-RELEASE-0001]|-
tag-not-semver|refs/tags/@V@.0|-|2|[CI-ERROR-RELEASE-0002]|-
one-model|refs/heads/b-a|CI_PROMOTE_ONE_CMD=;CI_STACK_CANDIDATE_CMD=@FAIL@|2|[CI-ERROR-PROMOTE-0003] channel="ch-a"|-
CASES
}

@test "toolchain joins the promote candidate only when fully accepted" {
    # What: accepted=row; missing=skip; UNKNOWN=fail.
    # Why: promote moves channel; UNKNOWN != skip.
    # From: Issue #1683 | PR #1858
    _ci_collect_accepted_digests() { echo "os/p1=sha256:a"; }
    _ci_reconcile_index() { echo sha256:idx; }
    _ci_resolve_one() { echo "service=$1 platform=$2 state=PRESENT_ACCEPTED action=noop"; }
    run _ci_toolchain_candidate
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-tools=sha256:idx"* ]]
    _ci_resolve_one() { echo "service=$1 platform=$2 state=MISSING_CONFIRMED action=build"; }
    run _ci_toolchain_candidate
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-INFO-CANDIDATE-0004]"* ]]
    [[ "${output}" != *"build-tools=sha256"* ]]
    _ci_resolve_one() { echo "service=$1 platform=$2 state=UNKNOWN action=escalate"; }
    run _ci_toolchain_candidate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CANDIDATE-0003]"* ]]
}

# What: per row: channel backend call -> digest, move or id
# Why: §53: a channel is read back only as a complete index
# From: Issue #1683 | PR #1858
@test "channel backends: move retargets the tag, readback needs every child" {
    local case cmd index lost rc want moved part bin="${BIN}"
    local -a parts
    local -A V=(
        [@S@]="$(_val name)" [@CH@]="$(_val name)" [@D@]="$(_val digest)" [@K1@]="$(_val digest)" [@K2@]="$(_val digest)"
    )
    V[@REG@]="$(_ci_registry)"
    GITHUB_REPOSITORY="$(_val name)/$(_val name)"
    V[@REPO@]="${GITHUB_REPOSITORY}"
    export GITHUB_REPOSITORY CH_LOG="${BATS_TEST_TMPDIR}/create.log" CH_DIGEST="${V[@D@]}" CH_INDEX CH_LOST
    _tool_stub "${bin}" docker <<'EOF'
case " $* " in
    *" imagetools create "*) echo "$*" >> "${CH_LOG}" ;;
    *"@${CH_LOST:-none}"*) echo "ERROR: ${CH_LOST}: not found" >&2; exit 1 ;;
    *" --raw "*) printf '%s\n' "${CH_INDEX}" ;;
    *) echo "${CH_DIGEST}" ;;
esac
EOF
    while IFS='|' read -r case cmd index lost rc want moved; do
        : > "${CH_LOG}"
        case "${index}" in
            two) CH_INDEX="$(printf '{"manifests":[{"digest":"%s","platform":{"architecture":"a"}},{"digest":"%s","platform":{"architecture":"b"}}]}' "${V[@K1@]}" "${V[@K2@]}")" ;;
            attestation) CH_INDEX="$(printf '{"manifests":[{"digest":"%s","platform":{"architecture":"unknown"}}]}' "${V[@K1@]}")" ;;
            none) CH_INDEX='{"schemaVersion":2}' ;;
        esac
        CH_LOST="$(_fill "${lost#-}")"
        case "${cmd}" in
            readback) PATH="${bin}:${PATH}" run _ci_default_channel_readback "${V[@S@]}" "${V[@CH@]}" ;;
            move) PATH="${bin}:${PATH}" run _ci_default_channel_move "${V[@S@]}" "${V[@CH@]}" "${V[@D@]}" ;;
        esac
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "${rc}" -ne 0 ] && grep -qxF -- "${V[@D@]}" <<< "${output}"; then echo "${case}: digest printed on failure"; return 1; fi
        IFS=';' read -r -a parts <<< "$(_fill "${moved#-}")"
        for part in "${parts[@]}"; do
            grep -qF -- "${part}" "${CH_LOG}" || { echo "${case}: create lacks '${part}': $(cat "${CH_LOG}")"; return 1; }
        done
        [ "${moved}" != - ] || [ ! -s "${CH_LOG}" ] || { echo "${case}: unexpected create"; return 1; }
    done <<'CASES'
readback|readback|two|-|0|=@D@|-
lost-child|readback|two|@K2@|2|[CI-ERROR-PROMOTE-0014];child="@K2@"|-
attestation-only|readback|attestation|-|2|[CI-ERROR-PROMOTE-0015]|-
no-child|readback|none|-|2|[CI-ERROR-PROMOTE-0015]|-
move|move|two|-|0|-|--tag @REG@/@REPO@/@S@:@CH@;@REG@/@REPO@/@S@@@D@
CASES
}

# =========================================================
# RELEASE
# =========================================================

@test "release validation gate checks every AG-REL-011 trigger" {
    # What: path, glob, governance, null, foreign are stale.
    # Why: a release must never trust an invalidated record.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/rel" m="${BATS_TEST_TMPDIR}/rel.yml" c0 c1 case want
    mkdir -p "${r}/a" "${r}/b"
    printf 'x\n' > "${r}/a/x.txt"; printf 'y\n' > "${r}/b/y.txt"; printf 'g\n' > "${r}/G.md"
    git -C "${r}" init -q && git -C "${r}" add -A
    git -C "${r}" -c user.email=t@t -c user.name=t commit -qm base
    c0="$(git -C "${r}" rev-parse HEAD)"
    printf '%s\n' 'release:' '  validation_state: state.json' '  governance_paths: [G.md]' > "${m}"
    _rel_state() {
        jq -n --arg c "$1" --arg s "$2" '{last_stack_validation:{commit:$c}, last_ci_validation:{commit:$c},
            subsystem_validation:{_note:"x", sub:{commit:$s, path_prefixes:["a/*.txt"]}}}' > "${r}/state.json"
    }
    export CI_MANIFEST="${m}" CI_REPO_ROOT="${r}"
    while IFS='|' read -r case want; do
        git -C "${r}" -c advice.detachedHead=false checkout -q "${c0}"
        _rel_state "${c0}" "${c0}"
        case "${case}" in
            fresh) printf 'z\n' > "${r}/b/z.txt" ;;
            glob) printf 'x2\n' > "${r}/a/x.txt" ;;
            gov) printf 'g2\n' > "${r}/G.md" ;;
            never) _rel_state "${c0}" null ;;
            foreign) _rel_state "$(printf '1%.0s' {1..40})" "${c0}" ;;
        esac
        git -C "${r}" add -A
        git -C "${r}" -c user.email=t@t -c user.name=t commit -qm "${case}"
        c1="$(git -C "${r}" rev-parse HEAD)"
        GITHUB_SHA="${c1}" run _ci_release_validation_valid
        if [ "${case}" = fresh ]; then
            [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
            continue
        fi
        [ "${status}" -eq 1 ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"[CI-ERROR-RELEASE-0017]"* && "${output}" == *"${want}"* ]] \
            || { echo "${case}: ${output}"; return 1; }
    done <<'EOF'
fresh|
glob|a/*.txt changed
gov|governance G.md changed
never|sub: never validated
foreign|not reconstructable
EOF
    rm "${r}/state.json"
    GITHUB_SHA="${c1}" run _ci_release_validation_valid
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-RELEASE-0014]"* ]]
}

# What: gh stub logging calls; mocks release and assets
# Why: publish/sbom/vex assert gh calls without a network.
# From: Issue #1683
_release_gh_stub() {
    _tool_stub "${BATS_TEST_TMPDIR}" relgh <<'EOF'
echo "$*" >> "${GH_CALLS}"
if [ "$1 $2" = "release create" ]; then
    [ -z "${STUB_CREATE_FAIL:-}" ] || { echo "${STUB_CREATE_FAIL}" >&2; exit 1; }
    if [ -n "${STUB_STATE:-}" ]; then
        nf="" p=false prev=""
        for a in "$@"; do
            [ "${prev}" != --notes-file ] || nf="${a}"
            [ "${a}" != --prerelease ] || p=true
            prev="${a}"
        done
        b="$(cat "${nf}")"
        [ -z "${STUB_STORE_BODY:-}" ] || b="${STUB_STORE_BODY}"
        jq -nc --arg b "${b}" --argjson p "${p}" '{body: $b, isPrerelease: $p}' > "${STUB_STATE}"
    fi
    exit 0
fi
if [ "$1 $2" = "release upload" ]; then
    [ -z "${STUB_UPLOAD_FAIL:-}" ] || { echo "${STUB_UPLOAD_FAIL}" >&2; exit 1; }
    if [ -n "${STUB_ASSETS:-}" ]; then
        mkdir -p "${STUB_ASSETS}"
        if [ -n "${STUB_UPLOAD_CORRUPT:-}" ]; then echo "${STUB_UPLOAD_CORRUPT}" > "${STUB_ASSETS}/${4##*/}"
        else cp "$4" "${STUB_ASSETS}/"; fi
    fi
    exit 0
fi
if [ "$1 $2" = "release download" ]; then
    [ -z "${STUB_DL_ERR:-}" ] || { echo "${STUB_DL_ERR}" >&2; exit 1; }
    name="" dir="" prev=""
    for a in "$@"; do
        [ "${prev}" != --pattern ] || name="${a}"
        [ "${prev}" != --dir ] || dir="${a}"
        prev="${a}"
    done
    if [ -n "${STUB_ASSETS:-}" ] && [ -f "${STUB_ASSETS}/${name}" ]; then cp "${STUB_ASSETS}/${name}" "${dir}/"; exit 0; fi
    echo "no assets match the file pattern" >&2
    exit 1
fi
if [ "$1 $2" = "release view" ]; then
    if [ -n "${STUB_VIEW_ERR:-}" ]; then
        echo "${STUB_VIEW_ERR}" >&2
        exit 1
    fi
    if [ -n "${STUB_STATE:-}" ] && [ -s "${STUB_STATE}" ]; then
        cat "${STUB_STATE}"
        exit 0
    fi
    echo "release not found" >&2
    exit 1
fi
exit 0
EOF
    printf '%s' "${BATS_TEST_TMPDIR}/relgh"
}

# What: per release part and state: written, kept or an id
# Why: AG-REL-014: a published release part is never changed
# From: Issue #1683 | PR #1858
@test "release parts: one write with read back, a repeat only compares" {
    local gh calls assets st ti case cmd arg input pre env rc want check epoch got
    local -a args
    calls="${BATS_TEST_TMPDIR}/gh-calls"; assets="${BATS_TEST_TMPDIR}/assets"; st="${BATS_TEST_TMPDIR}/rel-state"
    gh="$(_release_gh_stub)"
    local -A V=(
        [@T@]="v$(_val semver)" [@B@]="$(_val name)" [@X@]="$(_val name)" [@S@]="$(_val name)" [@S2@]="$(_val name)"
        [@D@]="$(_val digest)" [@OD@]="$(_val digest)" [@O@]="$(_val name)" [@R@]="$(_val name)" [@SRV@]="https://$(_val host)"
    )
    epoch="$(( 1500000000 + $(_val int 0 99999999) ))"
    V[@CTS@]="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    V[@TS@]="$(date -u -d "@$(( epoch + $(_val int 1 99999) ))" +%Y-%m-%dT%H:%M:%SZ)"
    GITHUB_REPOSITORY="${V[@O@]^}/${V[@R@]^}"; GITHUB_SERVER_URL="${V[@SRV@]}"; GITHUB_SHA="$(_val sha)"
    export GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_SHA
    export GH_CALLS="${calls}" CI_TMPDIR="${BATS_TEST_TMPDIR}" CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RELEASE_GH_CMD="${gh}"
    export CI_REPO_ROOT="${BATS_TEST_TMPDIR}/repo" STUB_STATE="${st}" STUB_ASSETS="${assets}" WANT_BLOCK="${V[@B@]}"
    export SCAN_LOG="${BATS_TEST_TMPDIR}/scans" SBOM_DIGEST="${V[@D@]}" S1="${V[@S@]}" S2="${V[@S2@]}" CI_SBOM_CMD
    unset CI_VEX_TIMESTAMP CI_TRIVY_IGNORE
    _ci_require_ghcr_auth() { return 0; }
    _ci_release_notes_block() { printf '%s\n' "${WANT_BLOCK}"; }
    _ci_registry_digest() { echo "${SBOM_DIGEST}"; }
    ci_build_targets() { printf '%s\n%s\n' "${S1}" "${S2}"; }
    CI_SBOM_CMD="$(_stub 'echo "$1" >> "${SCAN_LOG}"; if [ -n "${SBOM_EMPTY:-}" ]; then : > "$3"; else printf "{\"digest\":\"%s\"}\n" "$2" > "$3"; fi')"
    mkdir -p "${CI_REPO_ROOT}"
    git -C "${CI_REPO_ROOT}" init -q
    GIT_COMMITTER_DATE="@${epoch}" git -C "${CI_REPO_ROOT}" -c user.name=t -c user.email=t@invalid commit -q --allow-empty -m r
    while IFS='|' read -r case cmd arg input pre env rc want check; do
        : > "${calls}"; : > "${SCAN_LOG}"
        if [ "${pre}" != keep ]; then rm -rf "${assets}" "${st}"; mkdir -p "${assets}"; fi
        case "${pre}" in
            rel-other) jq -nc --arg b "${V[@X@]}" '{body: $b, isPrerelease: false}' > "${st}" ;;
            rel-pre) jq -nc --arg b "${V[@B@]}" '{body: $b, isPrerelease: true}' > "${st}" ;;
            sbom-same) printf '{"digest":"%s"}\n' "${V[@D@]}" > "${assets}/${V[@S@]}.cdx.json" ;;
            sbom-other) printf '{"digest":"%s"}\n' "${V[@OD@]}" > "${assets}/${V[@S@]}.cdx.json" ;;
            vex-other) printf '%s\n' "${V[@X@]}" > "${assets}/vex.openvex.json" ;;
        esac
        [ "${env}" = - ] || export "$(_fill "${env}")"
        ti="${CI_REPO_ROOT}/${CI_TRIVY_IGNORE:-.trivyignore.yaml}"
        rm -f "${CI_REPO_ROOT}"/*.yaml "${CI_REPO_ROOT}/.trivyignore.yaml"
        case "${input}" in
            affected) printf 'vulnerabilities:\n  - id: CVE-1\n    paths:\n      - usr/bin/a\n    statement: >-\n      No fix yet.\n' ;;
            notaff) printf 'vulnerabilities:\n  - id: CVE-2\n    statement: >-\n      Code absent.\n    status: not_affected\n' ;;
            expiry) printf 'vulnerabilities:\n  - id: CVE-15\n    statement: >-\n      x\n    expired_at: 2026-12-31\n' ;;
            override) printf 'vulnerabilities:\n  - id: CVE-3\n    statement: >-\n      x\n    status: not_affected\n    justification: vulnerable_code_cannot_be_controlled_by_adversary\n' ;;
            align) printf 'vulnerabilities:\n  - id: CVE-4\n    paths:\n      - usr/bin/first\n    statement: >-\n      a\n    status: not_affected\n  - id: CVE-5\n    paths:\n      - usr/bin/second\n    statement: >-\n      b\n' ;;
            folded) printf '# head\nvulnerabilities:\n  # note\n  - id: CVE-6\n    statement: >-\n      What: one\n      two.\n\n      # kept\n      Why: three\n\n' ;;
            othersec) printf 'misconfigurations:\n  - id: AVD-1\nvulnerabilities:\n  - id: CVE-7\n    statement: >-\n      x\n' ;;
            purls) printf 'vulnerabilities:\n  - id: CVE-8\n    purls:\n      - pkg:x\n' ;;
            indent) printf 'vulnerabilities:\n  - id: CVE-9\n    statement: >-\n      a\n        b\n' ;;
            literal) printf 'vulnerabilities:\n  - id: CVE-10\n    statement: |\n      a\n' ;;
            toplevel) printf 'vulnerabilities: []\n' ;;
            comment) printf 'vulnerabilities:\n  - id: CVE-11 # note\n' ;;
            fixed) printf 'vulnerabilities:\n  - id: CVE-12\n    status: fixed\n' ;;
            badjust) printf 'vulnerabilities:\n  - id: CVE-13\n    status: not_affected\n    justification: because\n' ;;
            orphanjust) printf 'vulnerabilities:\n  - id: CVE-14\n    justification: component_not_present\n' ;;
            -) : ;;
        esac > "${ti}"
        [ "${input}" != - ] || rm -f "${ti}"
        args=()
        [ "${arg}" = - ] || read -r -a args <<< "$(_fill "${arg}")"
        case "${cmd}" in
            publish) run ci_cmd_release_publish "${args[@]}" ;;
            sbom) run ci_cmd_release_sbom "${args[@]}" ;;
            stack) run ci_cmd_release_sbom_stack "${args[@]}" ;;
            vex) run ci_cmd_release_vex "${args[@]}" ;;
            gen) run _ci_generate_vex "${ti}" ;;
        esac
        [ "${env}" = - ] || unset "${env%%=*}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if grep -q -e 'release edit' -e '--clobber' "${calls}"; then echo "${case}: edit or clobber: $(cat "${calls}")"; return 1; fi
        case "${check}" in
            -) ;;
            create:no) if grep -q 'release create' "${calls}"; then echo "${case}: create call"; return 1; fi ;;
            create:yes|create:pre)
                grep -q "release create ${args[0]} " "${calls}" || { echo "${case}: no create"; return 1; }
                got=yes
                if grep -q -- '--prerelease' "${calls}"; then got=pre; fi
                [ "create:${got}" = "${check}" ] || { echo "${case}: create:${got} want ${check}"; return 1; } ;;
            scans:*)
                got="$(paste -sd, "${SCAN_LOG}")"
                [ "${got}" = "$(_fill "${check#scans:}")" ] || { echo "${case}: scans '${got}'"; return 1; } ;;
            out:*)
                got="$(jq -r "$(_fill "${check#out:}")" <<< "${output}")" || { echo "${case}: ${output}"; return 1; }
                [ "${got}" = true ] || { echo "${case}: ${check} -> ${got}: ${output}"; return 1; } ;;
            vex:*)
                got="$(jq -r "$(_fill "${check#vex:}")" "${assets}/vex.openvex.json")" || { echo "${case}: no vex asset"; return 1; }
                [ "${got}" = true ] || { echo "${case}: ${check} -> ${got}"; return 1; } ;;
        esac
    done <<'CASES'
pub-final|publish|@T@|-|-|-|0|=release=published tag=@T@ prerelease=false|create:yes
pub-repeat|publish|@T@|-|keep|-|0|=release=unchanged tag=@T@ prerelease=false|create:no
pub-rc|publish|@T@-rc.1|-|-|-|0|=release=published tag=@T@-rc.1 prerelease=true|create:pre
pub-body-differs|publish|@T@|-|rel-other|-|2|[CI-ERROR-RELEASE-0038] tag="@T@" mode=unchanged;raw:;expected:;@B@;found:;@X@|create:no
pub-pre-differs|publish|@T@|-|rel-pre|-|2|[CI-ERROR-RELEASE-0005] tag="@T@" mode=unchanged|create:no
pub-read-unknown|publish|@T@|-|-|STUB_VIEW_ERR=HTTP 401: Bad credentials|2|[CI-ERROR-RELEASE-0020];Bad credentials|create:no
pub-create-fails|publish|@T@|-|-|STUB_CREATE_FAIL=HTTP 422 Validation Failed|2|[CI-ERROR-BUILD-0011] op=github-api;[CI-ERROR-RELEASE-0006]|create:yes
pub-readback-differs|publish|@T@|-|-|STUB_STORE_BODY=@X@|2|[CI-ERROR-RELEASE-0038] tag="@T@" mode=published;expected:;@B@;found:;@X@|create:yes
pub-not-a-tag|publish|sha-@X@|-|-|-|2|[CI-ERROR-RELEASE-0002]|create:no
sbom-new|sbom|@S@ @T@|-|-|-|0|=release=sbom service=@S@ tag=@T@ digest=@D@|scans:@S@
sbom-repeat|sbom|@S@ @T@|-|keep|-|0|=release=sbom-reused service=@S@ tag=@T@ digest=@D@|scans:
sbom-other-digest|sbom|@S@ @T@|-|sbom-other|-|2|[CI-ERROR-RELEASE-0046] service="@S@" tag="@T@" digest="@D@";raw:;@OD@|scans:
sbom-read-unknown|sbom|@S@ @T@|-|-|STUB_DL_ERR=HTTP 401 Unauthorized|2|[CI-ERROR-RELEASE-0044] tag="@T@" asset="@S@.cdx.json";raw:;HTTP 401|scans:
sbom-upload-fails|sbom|@S@ @T@|-|-|STUB_UPLOAD_FAIL=HTTP 422 Validation Failed|2|[CI-ERROR-BUILD-0011] op=github-api|scans:@S@
sbom-readback-differs|sbom|@S@ @T@|-|-|STUB_UPLOAD_CORRUPT=@X@|2|[CI-ERROR-RELEASE-0045] tag="@T@" asset="@S@.cdx.json"|scans:@S@
sbom-empty|sbom|@S@ @T@|-|-|SBOM_EMPTY=1|2|[CI-ERROR-RELEASE-0004]|scans:@S@
sbom-no-tag|sbom|@S@|-|-|-|2|[CI-ERROR-RELEASE-0008]|scans:
stack-new|stack|@T@|-|-|-|0|release=sbom service=@S@;release=sbom service=@S2@|scans:@S@,@S2@
stack-reuses|stack|@T@|-|sbom-same|-|0|release=sbom-reused service=@S@;release=sbom service=@S2@|scans:@S2@
stack-no-tag|stack|-|-|-|-|2|[CI-ERROR-RELEASE-0013]|scans:
vex-new|vex|@T@|affected|-|-|0|=release=vex tag=@T@|vex:.timestamp == "@CTS@"
vex-repeat|vex|@T@|affected|keep|-|0|=release=vex-unchanged tag=@T@|-
vex-differs|vex|@T@|affected|vex-other|-|2|[CI-ERROR-RELEASE-0047] tag="@T@";raw:;@X@|-
vex-bad-input|vex|@T@|purls|-|-|2|[CI-ERROR-RELEASE-0035];[CI-ERROR-RELEASE-0012]|-
vex-no-input|vex|@T@|-|-|-|2|[CI-ERROR-RELEASE-0011]|-
vex-alt-path|vex|@T@|affected|-|CI_TRIVY_IGNORE=alt.yaml|0|=release=vex tag=@T@|-
vex-read-unknown|vex|@T@|affected|-|STUB_DL_ERR=HTTP 401 Unauthorized|2|[CI-ERROR-RELEASE-0044];raw:;HTTP 401|-
gen-affected|gen|-|affected|-|CI_VEX_TIMESTAMP=@TS@|0|-|out:.statements[0] | .status == "affected" and .action_statement == "No fix yet." and .products[0]["@id"] == "pkg:github/@O@/@R@" and .products[0].subcomponents == [{"@id": "usr/bin/a"}] and .timestamp == "@TS@"
gen-not-affected|gen|-|notaff|-|-|0|-|out:.statements[0] | .status == "not_affected" and .justification == "vulnerable_code_not_present" and .impact_statement == "Code absent." and has("action_statement") == false
gen-override|gen|-|override|-|-|0|-|out:.statements[0] | .justification == "vulnerable_code_cannot_be_controlled_by_adversary" and .impact_statement == "x"
gen-align|gen|-|align|-|-|0|-|out:(.statements | length) == 2 and .statements[0].status == "not_affected" and .statements[0].products[0].subcomponents[0]["@id"] == "usr/bin/first" and .statements[1].vulnerability.name == "CVE-5" and .statements[1].status == "affected" and .statements[1].action_statement == "b"
gen-folded|gen|-|folded|-|-|0|-|out:.statements[0].action_statement == "What: one two.\n# kept Why: three" and ."@context" == "https://openvex.dev/ns/v0.2.0" and ."@id" == "@SRV@/@O@/@R@/vex/@R@-@CTS@" and .author == "@R@ release automation (@SRV@/@O@/@R@)" and .version == 1
gen-other-section|gen|-|othersec|-|-|0|-|out:(.statements | length) == 1 and .statements[0].vulnerability.name == "CVE-7"
gen-expiry|gen|-|expiry|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-purls|gen|-|purls|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-indent|gen|-|indent|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-literal|gen|-|literal|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-top-level|gen|-|toplevel|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-id-comment|gen|-|comment|-|-|2|[CI-ERROR-RELEASE-0035]|-
gen-fixed|gen|-|fixed|-|-|2|[CI-ERROR-RELEASE-0025]|-
gen-bad-justification|gen|-|badjust|-|-|2|[CI-ERROR-RELEASE-0025]|-
gen-orphan-justification|gen|-|orphanjust|-|-|2|[CI-ERROR-RELEASE-0025]|-
gen-no-file|gen|-|-|-|-|2|[CI-ERROR-RELEASE-0035]|-
CASES
}

# What: per row: cut, reader or bump -> result or an id
# Why: AG-REL-013: a tag cut is its own authorized step
# From: Issue #1683 | PR #1858
@test "release tag: a dispatch cuts the next Z from the newest tag" {
    local b="${BATS_TEST_TMPDIR}/cut-build" case cmd arg repo env rc want after k got srvrepo
    local -A V=(
        [@O@]="$(_val name)" [@R@]="$(_val name)" [@X@]="$(_val int 0 50)" [@Y@]="$(_val int 0 50)" [@Z@]="$(_val int 0 50)"
        [@BR@]="refs/heads/$(_val name)" [@OTHER@]="$(_val sha)" [@REL@]="$(_ci_release_ref)" [@FAIL@]="$(_stub 'exit 2')"
        [@NOREL@]="$(_val path)" [@SRV@]="$(_val path)" [@SRV2@]="$(_val path)" [@SRV3@]="$(_val path)"
    )
    V[@X1@]="$(( ${V[@X@]} + 1 ))"
    V[@NEXT@]="v${V[@X@]}.10.1"
    grep -v 'release_tags: true' "${CI_MANIFEST}" > "${V[@NOREL@]}"
    srvrepo="${V[@SRV@]}/${V[@O@]}/${V[@R@]}.git"
    git init -q "${b}"
    git -C "${b}" -c user.name=t -c user.email=t@invalid commit -q --allow-empty -m c1
    V[@C1@]="$(git -C "${b}" rev-parse HEAD)"
    for k in 2.0 9.1 10.0; do git -C "${b}" tag "v${V[@X@]}.${k}"; done
    git -C "${b}" tag "v${V[@X1@]}.0.0-rc.1"
    mkdir -p "${V[@SRV@]}/${V[@O@]}" "${V[@SRV2@]}/${V[@O@]}" "${V[@SRV3@]}/${V[@O@]}"
    git init -q --bare "${srvrepo}"
    git -C "${b}" push -q "${srvrepo}" "HEAD:${V[@REL@]}" --tags
    git init -q --bare "${BATS_TEST_TMPDIR}/empty.git"
    git -C "${b}" push -q "${BATS_TEST_TMPDIR}/empty.git" "HEAD:${V[@REL@]}"
    git clone -q --bare "${srvrepo}" "${V[@SRV2@]}/${V[@O@]}/${V[@R@]}.git"
    git -C "${b}" push -q "${V[@SRV2@]}/${V[@O@]}/${V[@R@]}.git" "${V[@C1@]}:refs/tags/${V[@NEXT@]}"
    git clone -q --bare "${srvrepo}" "${V[@SRV3@]}/${V[@O@]}/${V[@R@]}.git"
    _tool_stub "${V[@SRV3@]}/${V[@O@]}/${V[@R@]}.git/hooks" post-receive <<'EOF'
while read -r _ _ ref; do git update-ref -d "${ref}"; done
EOF
    git clone -q --no-tags "${srvrepo}" "${BATS_TEST_TMPDIR}/w-tags"
    git clone -q --no-tags "${BATS_TEST_TMPDIR}/empty.git" "${BATS_TEST_TMPDIR}/w-empty"
    git init -q "${BATS_TEST_TMPDIR}/w-none"
    local -A D=(
        [GITHUB_EVENT_NAME]=workflow_dispatch [GITHUB_REF]="${V[@REL@]}" [GITHUB_SHA]="${V[@C1@]}"
        [GITHUB_SERVER_URL]="file://${V[@SRV@]}" [GITHUB_REPOSITORY]="${V[@O@]}/${V[@R@]}"
        [PROJECT_AUTOMATION_PAT]="$(_val name)" [CI_MANIFEST]="${CI_MANIFEST}"
    )
    for k in "${!D[@]}"; do export "${k}=${D[${k}]}"; done
    while IFS='|' read -r case cmd arg repo env rc want after; do
        [ "${repo}" = - ] || cd "${BATS_TEST_TMPDIR}/w-${repo}"
        [ "${env}" = - ] || export "$(_fill "${env}")"
        case "${cmd}" in
            cut) run ci_cmd_cut_release_tag ;;
            next) run _ci_next_patch_tag "$(_fill "${arg}")" ;;
            last) run _ci_last_release_tag "$(_fill "${arg}")" ;;
        esac
        if [ "${env}" != - ]; then
            k="${env%%=*}"
            if [ -n "${D[${k}]+set}" ]; then export "${k}=${D[${k}]}"; else unset "${k}"; fi
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        case "${after}" in
            none)
                if git -C "${srvrepo}" rev-parse -q --verify "refs/tags/${V[@NEXT@]}" > /dev/null; then
                    echo "${case}: ${V[@NEXT@]} reached the server"; return 1
                fi ;;
            pushed)
                got="$(git -C "${srvrepo}" rev-parse -q --verify "refs/tags/${V[@NEXT@]}^{commit}")" || { echo "${case}: no tag"; return 1; }
                [ "${got}" = "${V[@C1@]}" ] || { echo "${case}: tag at ${got}"; return 1; } ;;
        esac
        if git -C "${BATS_TEST_TMPDIR}/w-tags" rev-parse -q --verify "refs/tags/${V[@NEXT@]}" > /dev/null; then
            git -C "${BATS_TEST_TMPDIR}/w-tags" tag -d "${V[@NEXT@]}" > /dev/null
        fi
    done <<'CASES'
push-event|cut|-|tags|GITHUB_EVENT_NAME=push|2|[CI-ERROR-RELEASE-0039] event="push"|none
other-ref|cut|-|tags|GITHUB_REF=@BR@|2|[CI-ERROR-RELEASE-0040] ref="@BR@"|none
no-release-ref|cut|-|tags|CI_MANIFEST=@NOREL@|2|[CI-ERROR-RELEASE-0018]|none
no-base|cut|-|empty|-|2|[CI-ERROR-RELEASE-0041]|none
base-unknown|cut|-|none|-|2|[CI-ERROR-CORE-0106]|none
tip-moved|cut|-|tags|GITHUB_SHA=@OTHER@|2|[CI-ERROR-RELEASE-0042];tip="@C1@" sha="@OTHER@"|none
tip-unknown|cut|-|tags|CI_PROMOTE_TIP_CMD=@FAIL@|2|[CI-ERROR-RELEASE-0016]|none
no-pat|cut|-|tags|PROJECT_AUTOMATION_PAT=|2|[CI-ERROR-CORE-0128] name="PROJECT_AUTOMATION_PAT"|none
tag-taken|cut|-|tags|GITHUB_SERVER_URL=file://@SRV2@|2|[CI-ERROR-RELEASE-0027];already exists|none
tag-lost|cut|-|tags|GITHUB_SERVER_URL=file://@SRV3@|2|[CI-ERROR-RELEASE-0048] tag="@NEXT@" sha="@C1@" found=""|none
next-rollover|next|v@X@.@Y@.9|-|-|0|=v@X@.@Y@.10|-
next-rc|next|v@X@.@Y@.@Z@-rc.1|-|-|2|[CI-ERROR-RELEASE-0015]|-
last-below|last|v@X@.10.0|tags|-|0|=v@X@.9.1|-
last-below-rc|last|v@X@.10.0-rc.2|tags|-|0|=v@X@.9.1|-
last-below-first|last|v@X@.2.0|tags|-|0|=|-
pushed|cut|-|tags|-|0|[CI-INFO-RELEASE-0028] tag="@NEXT@" sha="@C1@";cut-tag=pushed tag=@NEXT@ base=v@X@.10.0|pushed
CASES
}

# What: neutral notes SOT, tagged origin and gh PR mock.
# Why: real git range and section parse; no network.
# From: Issue #894 | PR #1858
_rn_setup() {
    local work="${BATS_TEST_TMPDIR}/rn" origin="${BATS_TEST_TMPDIR}/rn-origin.git" s
    printf '%s\n' 'release_notes:' '  pr_section: Changelog' '  skip_label: skip-changelog' '  other_title: Other' \
        'release_notes_categories:' '  bug:' '    title: Fixed' '  ci:' '    title: CI' > "${BATS_TEST_TMPDIR}/rn.yml"
    _sot_block ci_variables >> "${BATS_TEST_TMPDIR}/rn.yml"
    export CI_MANIFEST="${BATS_TEST_TMPDIR}/rn.yml" GITHUB_REPOSITORY=owner/fixture-repo CI_RETRY_BACKOFF_BASE_SECONDS=0
    git init -q --bare --initial-branch=main "${origin}"
    git init -q "${work}"
    for s in "base" "Merge pull request #5 from x/five" "Nine change (#9)" "Merge pull request #8 from x/eight" "Issue ref (#7)" "plain commit"; do
        git -C "${work}" -c user.email=a@b -c user.name=b commit -q --allow-empty -m "${s}"
        [ "${s}" != base ] || git -C "${work}" tag v0.1.0
    done
    git -C "${work}" tag v0.2.0
    git -C "${work}" push -q "${origin}" HEAD:refs/heads/main --tags
    git clone -q "${origin}" "${BATS_TEST_TMPDIR}/rn-clone"
    gh() {
        jq -cn '{data: {repository: {
            p5: {__typename: "PullRequest", number: 5, title: "Five", url: "u5", labels: {nodes: [{name: "bug"}]},
                 body: "## Summary\nx\n## Changelog\nFixed X.\n<!-- hint -->\n\n## Other\nno"},
            p7: {__typename: "Issue"},
            p8: {__typename: "PullRequest", number: 8, title: "Eight", url: "u8", labels: {nodes: [{name: "skip-changelog"}]}, body: ""},
            p9: {__typename: "PullRequest", number: 9, title: "Nine", url: "u9", labels: {nodes: []}, body: "no section"}}}}'
    }
    export -f gh
}

# What: per row: tag -> notes text, changelog entry or an id
# Why: notes and CHANGELOG.md list the PRs since a release
# From: Issue #894 | PR #1858
@test "release notes and the CHANGELOG.md entry come from the PRs since a tag" {
    local work="${BATS_TEST_TMPDIR}/rn" origin="${BATS_TEST_TMPDIR}/rn-origin.git" case cmd arg env rc want after
    _rn_setup
    printf '# Changelog\n\nintro\n\n## Pending\n\np\n\n## [0.1.0] - 2026-07-06\n\nold\n' > "${work}/CHANGELOG.md"
    git -C "${work}" add CHANGELOG.md
    git -C "${work}" -c user.email=a@b -c user.name=b commit -q -m log
    git -C "${work}" tag v1.2.3
    git -C "${work}" push -q "${origin}" HEAD:refs/heads/main --tags
    cd "${BATS_TEST_TMPDIR}/rn-clone"
    export CI_DEFAULT_BRANCH=main
    while IFS='|' read -r case cmd arg env rc want after; do
        [ "${env}" = - ] || export "${env%%=*}=${env#*=}"
        case "${cmd}" in
            changes) run _ci_release_changes "${arg}" ;;
            notes) run bash "${CI_SH}" release-notes "${arg}" ;;
            changelog) run ci_cmd_release_changelog "${arg}" ;;
        esac
        [ "${env}" = - ] || export CI_DEFAULT_BRANCH=main
        _expect "${case}" "${rc}" "$(printf '%b' "${want}")" || return 1
        [ "${after}" != - ] || continue
        output="$(git -C "${origin}" show main:CHANGELOG.md)" status=0
        _expect "${case} file" 0 "$(printf '%b' "${after}")" || return 1
    done <<'CASES'
changes|changes|v0.2.0|-|0|=### Fixed\n\n- #5 Five (u5)\n  Fixed X.\n\n### Other\n\n- #9 Nine (u9)|-
changes-first|changes|v0.1.0|-|0|=_No earlier vX.Y.Z release: no change list for v0.1.0._|-
notes-cmd|notes|v0.2.0|-|0|### Fixed;- #5 Five (u5);### Other;- #9 Nine (u9)|-
log-no-branch|changelog|v1.2.3|CI_DEFAULT_BRANCH=|2|[CI-ERROR-RELEASE-0033]|-
log-rc-skip|changelog|v1.2.3-rc.1|-|0|=release-changelog=skip tag=v1.2.3-rc.1 reason="not a stable vX.Y.Z tag"|-
log-written|changelog|v1.2.3|-|0|release-changelog=written tag=v1.2.3 branch=main|## Pending\n\np\n\n## [1.2.3] - ;\n\n_No pull requests merged since v0.2.0._\n\n## [0.1.0] - 2026-07-06
log-repeat|changelog|v1.2.3|-|0|release-changelog=exists tag=v1.2.3|-
CASES
}

# =========================================================
# GC
# =========================================================

_gc_roots() { _stub 'printf "sha256:aaa\nsha256:bbb\n"'; }

# What: per row: ledger, channel, index state -> roots or id
# Why: §101: every record, channel and child is a root
# From: Issue #1683 | PR #1858
@test "gc roots: ledger records, channels and index children; fail closed" {
    local case env ledger probe index rc want has absent part noreg
    local -a parts
    noreg="$(_val path)"
    grep -v '^  registry:' "${CI_MANIFEST}" > "${noreg}"
    local -A V=([@L@]="$(_val digest)" [@C@]="$(_val digest)" [@K@]="$(_val digest)" [@NOREG@]="${noreg}")
    GITHUB_REPOSITORY="$(_val name)/$(_val name)"
    GC_S="$(_val name)"; GC_CH="$(_val name)"; GC_P="$(_val platform)"; GC_TC="$(_ci_toolchain_target)"
    export GITHUB_REPOSITORY GC_S GC_CH GC_P GC_TC GC_L="${V[@L@]}" GC_C="${V[@C@]}" GC_K="${V[@K@]}"
    ci_services() { printf '%s\n' "${GC_S}"; }
    _ci_mutable_channels() { printf '%s\n' "${GC_CH}"; }
    while IFS='|' read -r case env ledger probe index rc want has absent; do
        case "${ledger}" in
            record) _ci_ledger_blob() { printf 'id1\t%s\t%s\tPRODUCED_UNVERIFIED\t%s\n' "${GC_S}" "${GC_P}" "${GC_L}"; } ;;
            none) _ci_ledger_blob() { return 1; } ;;
            unknown) _ci_ledger_blob() { return 2; } ;;
        esac
        case "${probe}" in
            all) _ci_registry_probe() { printf '%s\n' "${GC_C}"; } ;;
            toolchain) _ci_registry_probe() { case "$1" in *"/${GC_TC}:${GC_CH}") printf '%s\n' "${GC_C}" ;; *) return 1 ;; esac; } ;;
            absent) _ci_registry_probe() { return 1; } ;;
            unknown) _ci_registry_probe() { return 2; } ;;
        esac
        case "${index}" in
            child) _ci_index_raw() { printf '{"manifests":[{"platform":{"architecture":"a"},"digest":"%s"}]}' "${GC_K}"; } ;;
            broken) _ci_index_raw() { printf '{"manifests":[ not json'; } ;;
            absent) _ci_index_raw() { return 1; } ;;
            unknown) _ci_index_raw() { return 2; } ;;
        esac
        if [ "${env}" = - ]; then run _ci_default_gc_roots; else CI_MANIFEST="$(_fill "${env#CI_MANIFEST=}")" run _ci_default_gc_roots; fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        IFS=';' read -r -a parts <<< "$(_fill "${has#-}")"
        for part in "${parts[@]}"; do
            grep -qxF -- "${part}" <<< "${output}" || { echo "${case}: no root ${part}: ${output}"; return 1; }
        done
        IFS=';' read -r -a parts <<< "$(_fill "${absent#-}")"
        for part in "${parts[@]}"; do
            if grep -qxF -- "${part}" <<< "${output}"; then echo "${case}: ${part} must not be a root"; return 1; fi
        done
    done <<'CASES'
union|-|record|all|child|0|-|@L@;@C@;@K@|-
toolchain-channel|-|none|toolchain|child|0|-|@C@;@K@|-
channel-not-promoted|-|record|absent|absent|0|-|@L@|@C@
ledger-unknown|-|unknown|all|child|2|[CI-ERROR-GC-0012]|-|-
index-unparseable|-|none|all|broken|2|[CI-ERROR-GC-0026];digest="@C@";jq: parse error;index: {"manifests":[ not json|-|@C@
channel-probe-unknown|-|none|unknown|child|2|[CI-ERROR-GC-0013]|-|-
child-read-unknown|-|record|absent|unknown|2|[CI-ERROR-GC-0014] service=|-|-
no-registry|CI_MANIFEST=@NOREG@|record|all|child|2|[CI-ERROR-CORE-0005]|-|-
CASES
}

@test "default gc reachable classifies every candidate shape" {
    # What: roots x candidate -> referenced/unreachable/2.
    # Why: only old, unreferenced, dated garbage may go.
    # From: Issue #1683
    local roots cand rc want now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS='|' read -r roots cand rc want; do
        cand="$(printf '%b' "${cand//NOW/${now}}")"
        if [ "${roots}" = - ]; then
            unset CI_GC_ROOTS_FILE
        else
            export CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
            tr ' ' '\n' <<< "${roots}" > "${CI_GC_ROOTS_FILE}"
        fi
        run _ci_default_gc_reachable "${cand}"
        [ "${status}" -eq "${rc}" ] || { echo "${cand}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${cand}: no ${want}: ${output}"; return 1; }
    done <<'CASES'
sha256:aaa sha256:bbb|sha256:aaa\t123\t2020-01-01T00:00:00Z|0|referenced
sha256:root|sha256:fresh\t9\tNOW|0|referenced
sha256:root|sha256:old\t9\t2020-01-01T00:00:00Z|0|unreachable
-|sha256:x\t9\t2020-01-01T00:00:00Z|2|
sha256:root|sha256:notimestamp|2|CI-ERROR-GC-0016
sha256:root|sha256:x\t9\tnot-a-date|2|CI-ERROR-GC-0023
sha256:subj|sha256:att\t9\t2020-01-01T00:00:00Z\tsha256-subj|0|referenced
sha256:other|sha256:att\t9\t2020-01-01T00:00:00Z\tsha256-gone|0|unreachable
CASES
}

@test "default gc reachable refuses when the grace value is missing" {
    # What: A missing grace value fails closed.
    # Why: Empty grace makes the floor now and deletes all.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    local m
    m="$(_val path)"
    grep -v 'unaggregated_grace_minutes:' "${CI_MANIFEST}" > "${m}"
    CI_MANIFEST="${m}" run _ci_default_gc_reachable "$(printf 'sha256:x\t9\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0015"* ]]
}

@test "gc fails closed on an empty protected-roots set" {
    # What: An empty roots set must stop the pass.
    # Why: Empty roots would mark all artifacts unreachable.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub 'true')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0007"* ]]
}

@test "default gc candidates: per-package tuples, 404 skip, fail closed" {
    # What: owner/repo-scoped versions; 404 skips; empty ok.
    # Why: all-404, transient error or no repo must refuse.
    # From: Issue #1683 | PR #1858
    ci_build_targets() { printf 'svc-a\nsvc-b\n'; }
    _ci_gh_versions() {
        [ "$1" = owner ] || return 2
        case "${MODE}:$2" in
            ok:fixture-repo%2Fsvc-a) printf 'sha256:aaa\t111\t2020-01-01T00:00:00Z\tsha-a\n' ;;
            ok:*) return 1 ;;
            empty:*) return 0 ;;
            none:*) return 1 ;;
            *) return 2 ;;
        esac
    }
    export GITHUB_REPOSITORY=Owner/Fixture-Repo
    MODE=ok run _ci_default_gc_candidates
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'sha256:aaa\t111\t2020-01-01T00:00:00Z\tsha-a\tsvc-a')" ]
    MODE=empty run _ci_default_gc_candidates
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
    MODE=none run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]; [[ "${output}" == *"CI-ERROR-GC-0020"* ]]
    MODE=transient run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]
    unset GITHUB_REPOSITORY
    MODE=ok run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]; [[ "${output}" == *"CI-ERROR-GC-0017"* ]]
}

@test "gc pass: every classify and apply outcome from one table" {
    # What: one gc pass per row: rc, output, deletions.
    # Why: keep/delete/UNKNOWN/policy/auth share one path.
    # From: Issue #1683 | PR #1858
    local name cands reach args auth policy rc want deleted log m w
    local -a ge av ws
    while IFS='|' read -r name cands reach args auth policy rc want deleted; do
        log="${BATS_TEST_TMPDIR}/${name}.deleted"
        ge=(-u GHCR_USERNAME -u GHCR_TOKEN CI_GC_ROOTS_CMD="$(_gc_roots)"
            CI_GC_CANDIDATES_CMD="$(_stub "${cands}")"
            CI_GC_DELETE_CMD="$(_stub "echo \"\$1\" >> '${log}'")")
        [ "${reach}" = - ] || ge+=(CI_GC_REACHABLE_CMD="$(_stub "${reach}")")
        [ "${auth}" = no ] || ge+=(GHCR_USERNAME=u GHCR_TOKEN=t)
        if [ "${policy}" != - ]; then
            m="${BATS_TEST_TMPDIR}/${name}.yml"
            printf 'retention:\n  deletion_policy: %s\n' "${policy}" > "${m}"
            ge+=(CI_MANIFEST="${m}")
        fi
        av=(); [ "${args}" = - ] || av=("${args}")
        run env "${ge[@]}" bash "${CI_SH}" gc "${av[@]}"
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
        if [ "${deleted}" = - ]; then
            [ ! -e "${log}" ] || { echo "${name}: deleted $(cat "${log}")"; return 1; }
        else
            [[ "$(cat "${log}")" == *"${deleted}"* ]] || { echo "${name}: delete log: $(cat "${log}")"; return 1; }
        fi
    done <<'CASES'
noop|true|-|-|no|-|0|result=noop candidates=0|-
keep|echo sha-abc|echo referenced|-|no|-|0|candidate=sha-abc action=KEEP|-
dry-run|echo sha-old|echo unreachable|-|no|-|0|candidate=sha-old action=DELETE mode=dry-run|-
unknown|echo sha-x|echo dunno|-|no|-|2|CI-ERROR-GC-0005|-
probe-fail|echo sha-x|exit 3|-|no|-|2|CI-ERROR-GC-0004|-
bad-arg|true|-|--bogus|no|-|2|CI-ERROR-GC-0006|-
apply-no-auth|echo sha-old|echo unreachable|--apply|no|-|2|CI-ERROR-BUILD-0002|-
policy-manual|echo sha-old|echo unreachable|--apply|yes|manual-only|2|CI-ERROR-GC-0008|-
policy-negated|echo sha-old|echo unreachable|--apply|yes|automation-forbidden|2|CI-ERROR-GC-0008|-
apply-unknown|printf "sha-good\nsha-bad\n"|case "$1" in *good*) echo unreachable;; *) echo dunno;; esac|--apply|yes|-|2|CI-ERROR-GC-0005|-
apply-delete|echo sha-old|echo unreachable|--apply|yes|-|0|result=classified keep=0 delete=1 deleted=1 mode=apply|sha-old
apply-toctou|echo sha-old|f="${BATS_TEST_TMPDIR}/seen"; if [ -f "$f" ]; then echo referenced; else : > "$f"; echo unreachable; fi|--apply|yes|-|0|CI-INFO-GC-0011;deleted=0|-
CASES
}

# What: per row: candidate + GitHub answers -> rc and id
# Why: one destructive call; done only when read back gone
# From: Issue #1683 | PR #1858
@test "default gc delete removes one version and confirms it" {
    local case id del read rc want cand
    local -A V=(
        [@O@]="$(_val name)" [@P@]="$(_val name)" [@S@]="$(_val name)" [@ID@]="$(_val int 100 99999)" [@D@]="$(_val digest)"
    )
    export GITHUB_REPOSITORY="${V[@O@]}/${V[@P@]}" CI_RETRY_BACKOFF_BASE_SECONDS=0 GD_LOG="${BATS_TEST_TMPDIR}/gd.log"
    gh() {
        echo "$*" >> "${GD_LOG}"
        case "$*" in
            *"-X DELETE"*) [ "${GD_DEL}" = ok ] || { echo "gh: ${GD_DEL}" >&2; return 1; } ;;
            *) case "${GD_READ}" in
                   404) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
                   soft) echo "$(_val name)" ;;
                   active) echo "" ;;
                   *) echo "gh: ${GD_READ}" >&2; return 1 ;;
               esac ;;
        esac
    }
    export -f gh _val
    while IFS='|' read -r case id del read rc want; do
        : > "${GD_LOG}"
        cand="${V[@D@]}"$'\t'"$(_fill "${id}")"$'\t2020-01-01T00:00:00Z\t\t'"${V[@S@]}"
        GD_DEL="${del}" GD_READ="${read}" run _ci_default_gc_delete "${cand}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${rc}" -ne 0 ] || [ "$(cat "${GD_LOG}")" = "$(_fill $'api -X DELETE /orgs/@O@/packages/container/@P@%2F@S@/versions/@ID@\napi --jq .deleted_at // "" /orgs/@O@/packages/container/@P@%2F@S@/versions/@ID@')" ] \
            || { echo "${case}: calls $(cat "${GD_LOG}")"; return 1; }
    done <<'CASES'
gone|@ID@|ok|404|0|-
soft-deleted|@ID@|ok|soft|0|-
still-active|@ID@|ok|active|2|[CI-ERROR-GC-0032]
read-fails|@ID@|ok|HTTP 401 Unauthorized|2|[CI-ERROR-GC-0033];raw:;HTTP 401
delete-fails|@ID@|HTTP 401 Unauthorized|404|2|[CI-ERROR-BUILD-0011] op=github-api
bad-id|x@ID@|ok|404|2|[CI-ERROR-GC-0019]
CASES
}

# What: GHCR listing retries transient API errors; 404 skips.
# Why: AG-CI-013 per caller: wired to the github-api op.
# From: Issue #1683 | PR #1858
@test "gh versions: a transient API error retries, a 404 skips the package" {
    local own pkg line
    own="$(_val name)"
    pkg="$(_val name)%2F$(_val name)"
    line="$(printf '%s\t%s\t%s\t' "$(_val name)" "$(_val int 0 4294967295)" "$(_val name)")"
    GH_N="$(_val path)"
    GH_LINE="${line}"
    export GH_N GH_LINE
    gh() {
        local n
        n="$(( $(head -n 1 "${GH_N}") + 1 ))"
        { printf '%s\n' "${n}"; tail -n +2 "${GH_N}"; printf '%s\n' "$*"; } > "${GH_N}.next"
        mv "${GH_N}.next" "${GH_N}"
        if [ "${n}" -le "${GH_FAILS}" ]; then printf '%s\n' "${GH_TEXT}" >&2; return 1; fi
        printf '%s\n' "${GH_LINE}"
    }
    printf '0\n' > "${GH_N}"
    GH_FAILS=2 GH_TEXT='HTTP 503 Service Unavailable' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions "${own}" "${pkg}"
    _expect transient-then-ok 0 "${line}" || return 1
    [ "$(head -n 1 "${GH_N}")" -eq 3 ] || { echo "transient: $(cat "${GH_N}")"; return 1; }
    grep -qF -- "/orgs/${own}/packages/container/${pkg}/versions" "${GH_N}" || { echo "api path: $(cat "${GH_N}")"; return 1; }
    printf '0\n' > "${GH_N}"
    GH_FAILS=99 GH_TEXT='gh: Not Found (HTTP 404)' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions "${own}" "${pkg}"
    _expect not-found 1 - || return 1
    [ "$(head -n 1 "${GH_N}")" -eq 1 ] || { echo "404 retried: $(cat "${GH_N}")"; return 1; }
}

@test "gc keeps a candidate the default probe finds in the roots file" {
    # What: Framework makes roots; default probe reads.
    # Why: End-to-end membership KEEP via the roots file.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub 'printf "sha256:aaa\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub 'printf "sha256:aaa\t7\t2020-01-01T00:00:00Z\n"')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
}

@test "gc keeps a fresh non-root candidate via the recency floor" {
    # What: A recent non-root candidate is kept end-to-end.
    # Why: In-flight artifacts survive GC (advisor case).
    # From: Issue #1683
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    CI_GC_ROOTS_CMD="$(_stub 'printf "sha256:root\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub "printf 'sha256:fresh\t7\t${now}\n'")" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
}

# =========================================================
# VALIDATION
# =========================================================

@test "stack candidate admits only service=sha256:<64 hex> lines" {
    # What: candidate intake per line shape, one table.
    # Why: a bad digest must not reach compose or promote.
    # From: Issue #1683 | PR #1858
    local a b name lines want f
    a="$(_test_digest a)"; b="$(_test_digest b)"
    while IFS='|' read -r name lines want; do
        f="${BATS_TEST_TMPDIR}/${name}.cand"
        lines="${lines//@A/${a}}"; lines="${lines//@B/${b}}"
        case "${lines}" in
            FAIL3) CI_STACK_CANDIDATE_CMD="$(_stub 'exit 3')" ;;
            *) printf '%s\n' "${lines//;/$'\n'}" > "${f}"; CI_STACK_CANDIDATE_CMD="$(_stub "cat '${f}'")" ;;
        esac
        export CI_STACK_CANDIDATE_CMD
        run _ci_stack_candidate
        case "${want}" in
            ok) [ "${status}" -eq 0 ] && [ "${output}" = "$(cat "${f}")" ] ;;
            rc3) [ "${status}" -eq 3 ] && [[ "${output}" != *CANDIDATE-0006* ]] ;;
            bad) [ "${status}" -eq 2 ] && [[ "${output}" == *CI-ERROR-CANDIDATE-0006* ]] \
                && [[ "${output}" == *"${lines##*;}"* ]] ;;
        esac || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
one|proxy=@A|ok
two|proxy=@A;dhcp-proxy=@B|ok
empty||ok
source-fails|FAIL3|rc3
short|proxy=sha256:beef|bad
no-prefix|proxy=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|bad
upper-hex|proxy=sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|bad
no-service|=@A|bad
error-text|proxy=@A;dns=An image does not exist locally with the tag: x|bad
CASES
}

# What: the wired default refuses without compose data
# Why: the real backend past a free slot stays fail-closed
# From: Issue #1683 | PR #1858
@test "validate default backend fails closed when compose is unreadable" {
    local err
    err="$(_val name) $(_val name)"
    _docker_answer ' network ls *' 0
    _docker_answer ' container ls *' 0
    _docker_answer ' compose * config *' 1 '' "${err}"
    CI_STACK_CANDIDATE_CMD="$(_stub "echo $(_val name)=$(_val digest)")" \
    GITHUB_REPOSITORY="$(_val name)/$(_val name)" TMPDIR="${BATS_TEST_TMPDIR}" \
    GHCR_USERNAME="$(_val name)" GHCR_TOKEN="$(_val name)" \
        run bash "${CI_SH}" validate
    _expect validate 2 "[CI-ERROR-CORE-0106] rc=\"1\" cmd=\"_ci_compose_run\";${err};[CI-ERROR-VALIDATE-0069] filter=;reason=\"compose config read failed\";[CI-ERROR-VALIDATE-0004]"
}

@test "validate fails with raw evidence when the stack is unhealthy" {
    # What: A failed validation run surfaces its raw output.
    # Why: Raw failure evidence is mandatory (AG-INT-002).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub "echo proxy=$(_test_digest a)")" \
    CI_VALIDATE_CMD="$(_stub 'echo STACK-UNHEALTHY; exit 1')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0004"* ]]
    [[ "${output}" == *"STACK-UNHEALTHY"* ]]
}

@test "validate accepts a healthy stack candidate" {
    # What: A passing run yields STACK_ACCEPTED.
    # Why: The one success path feeding promote (§49/§50).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub "echo proxy=$(_test_digest a)")" \
    CI_VALIDATE_CMD="$(_stub 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=STACK_ACCEPTED"* ]]
}

@test "validation dig target is the first SOT dns test domain" {
    # What: DNS test domain comes from the SOT, not code.
    # Why: One place owns the check inputs (AG-CI-006).
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/v.yml"
    printf 'validation:\n  dns_test_domains: [a.example.test, b.example.test]\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validation_dns_domain
    [ "${status}" -eq 0 ]
    [ "${output}" = "a.example.test" ]
}

@test "validation SOT proxy probe url is a cacheable HTTP target" {
    # What: Only HTTP is cached; the probe URL must be HTTP.
    # Why: No HIT proof exists against passthrough HTTPS.
    # From: Issue #1683 | PR #1858
    run _ci_validation_proxy_probe_url
    [ "${status}" -eq 0 ]
    [[ "${output}" == http://* ]]
}

# What: _ci_proxy_constant and _ci_service_port per input
# Why: one literal line or a services db port, else rc 2
# From: Issue #1683 | PR #1858
@test "proxy constants and service ports come from their owners" {
    local case body rc want p
    local -A V=([@N@]="$(_val name)" [@A@]="$(_val name)" [@B@]="$(_val name)" [@Y@]="$(_val name)")
    while IFS='|' read -r case body rc want; do
        run _ci_proxy_constant "${V[@N@]}" <(printf '%b' "$(_fill "${body}")")
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
quoted|@N@="/@A@/@B@"\n|0|=/@A@/@B@
bare|@Y@=1\n@N@=@A@\n|0|=@A@
absent|@Y@=1\n|2|[CI-ERROR-CORE-0129]
twice|@N@=@A@\n@N@=@B@\n|2|[CI-ERROR-CORE-0129];@A@;@B@
expanded|@N@="$@Y@/@A@"\n|2|[CI-ERROR-CORE-0129]
CASES
    for p in http https; do
        run _ci_service_port "${p}"
        [ "${status}" -eq 0 ] && [[ "$(getent services "${p}/tcp")" =~ [[:space:]]${output}/tcp ]] \
            || { echo "${p}: rc ${status}: ${output}"; return 1; }
    done
    run _ci_service_port "${V[@A@]}"
    _expect unknown 2 '[CI-ERROR-CORE-0106]' || return 1
}

@test "validate pins one SOT service onto both its compose containers" {
    # What: dns pins both dns-standard and dns-ssl.
    # Why: Pin by image, not key (1 service, 2 containers).
    # From: Issue #1683 | PR #1858
    local reg old dig
    reg="$(_ci_registry)"
    old="$(_val host)"
    dig="$(_val digest)"
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub "printf 'dns-standard\t${old}/owner/fixture-repo/dns:latest\ndns-ssl\t${old}/owner/fixture-repo/dns:latest\n'")" \
        run _ci_validate_pin_override "dns=${dig}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dns-standard:"* ]]
    [[ "${output}" == *"dns-ssl:"* ]]
    [ "$(grep -c -x -F "    image: ${reg}/owner/fixture-repo/dns@${dig}" <<<"${output}")" -eq 2 ]
    [[ "${output}" != *"${old}"* ]]
}

@test "validate skips third-party compose images without pinning" {
    # What: nats is third-party; it is never pinned.
    # Why: No first-party digest exists for external images.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub 'printf "nats\tnats:2-alpine@sha256:c11\nproxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
        run _ci_validate_pin_override "proxy=sha256:p"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy@sha256:p"* ]]
    [[ "${output}" != *"nats:"* ]]
}

@test "validate fails closed on a first-party image with no candidate digest" {
    # What: First-party image not in the candidate.
    # Why: Else :latest validates green (silent drift).
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub 'printf "proxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
        run _ci_validate_pin_override "watchdog=sha256:w"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0007"* ]]
}

@test "validate reports (not fails) a candidate with no first-party image" {
    # What: a candidate whose compose image is third-party.
    # Why: drift stays visible as a warning, no hard fail.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub 'printf "svc-x\tupstream.example.test/x@sha256:a13\nproxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
        run _ci_validate_pin_override "proxy=sha256:p
svc-x=sha256:n"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-WARN-VALIDATE-0008"* ]]
    [[ "${output}" == *'unpinned="svc-x"'* ]]
}

@test "validate is_collision matches docker contention signatures" {
    # What: Pool/address contention strings are retryable.
    # Why: Distinct from a real image or config failure.
    # From: Issue #1683 | PR #1858
    run _ci_validate_is_collision "Error: Pool overlaps with other one"
    [ "${status}" -eq 0 ]
    run _ci_validate_is_collision "manifest unknown"
    [ "${status}" -ne 0 ]
}

# What: _ci_validate_host_tools: list, missing tool, compose
# Why: each gap returns 2 with its own error code
# From: Issue #1683 | PR #1858
@test "validate host tools fail closed on a missing tool or list" {
    local h d t tools i err
    local -a dirs
    err="$(_val name)" h="$(_val path)"
    mkdir -p "${h}" || return 1
    # What: host model: PATH entries as links, BIN first
    # Why: command -v finds a tool only through PATH entries
    # From: Issue #1683 | PR #1858
    IFS=: read -r -a dirs <<< "${PATH}"
    for (( i = ${#dirs[@]} - 1; i >= 0; i-- )); do
        d="${dirs[i]}"
        compgen -G "${d}/*" > /dev/null || continue
        ln -sf "${d}"/* "${h}/" || return 1
    done
    _docker_answer ' compose version *' 0
    PATH="${h}" run _ci_validate_host_tools
    _expect present 0 - || return 1
    tools="$(_ci_block_entry_list validation "" host_tools)" || return 1
    [ -n "${tools}" ] || { echo "SOT has no validation.host_tools"; return 1; }
    while IFS= read -r t; do
        mv "${h}/${t}" "${h}/.${t}" || return 1
        PATH="${h}" run _ci_validate_host_tools
        mv "${h}/.${t}" "${h}/${t}" || return 1
        [ "${status}" -eq 2 ] || { echo "${t}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"missing=\"${t}\""* || "${output}" == *"[CI-ERROR-CORE-0108]"*"${t}"* ]] \
            || { echo "${t}: not named: ${output}"; return 1; }
    done <<< "${tools}"
    CI_MANIFEST=<(grep -v '^  host_tools:' "${CI_MANIFEST}") run _ci_validate_host_tools
    _expect no-list 2 '[CI-ERROR-VALIDATE-0056]' || return 1
    rm -f "${DS}/answers" "${DS}"/answer-used-*
    _docker_answer ' compose version *' 1 '' "${err}"
    run _ci_validate_host_tools
    _expect compose-broken 2 "[CI-ERROR-VALIDATE-0063];${err}" || return 1
}

@test "validation env lists the SOT pairs, fails closed when absent" {
    # What: KEY=VALUE lines from the SOT; none -> rc 2.
    # Why: validate and config check share this one owner.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/ve.yml" first
    printf '%s\n' 'validation:' '  compose_validation_env: A_KEY=1 B_KEY=two' '  compose_validation_secrets:' \
        '    hex32: [S_HEX]' '    base64_32: [S_B64]' > "${m}"
    CI_MANIFEST="${m}" run _ci_validation_env
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = A_KEY=1 ]; [ "${lines[1]}" = B_KEY=two ]
    [[ "${lines[2]}" =~ ^S_HEX=[0-9a-f]{64}$ ]]
    base64 -d <<< "${lines[3]#S_B64=}" > "${BATS_TEST_TMPDIR}/s.bin"
    [ "$(wc -c < "${BATS_TEST_TMPDIR}/s.bin")" -eq 32 ]
    # What: secrets are fresh per call, never a fixed value.
    # Why: a fixed render secret is a hardcoded credential.
    # From: Issue #1683 | PR #1858
    first="${lines[2]}"
    CI_MANIFEST="${m}" run _ci_validation_env
    [ "${lines[2]}" != "${first}" ]
    printf 'validation:\n  compose_validation_env: A_KEY=1\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validation_env
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0101"* ]]
    printf 'validation:\n  other: x\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validation_env
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0054"* ]]
}

@test "validation env base64_32 secrets decode to 32 bytes" {
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

@test "validation env lets the ui advertise a NATS url" {
    # What: the validation env sets NATS_ADVERTISE_URL.
    # Why: without it the ui answers 503 to every register.
    # From: Issue #866 | PR #1858
    local env
    env="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_validation_env)"
    echo "${env}" | grep '^NATS_'
    grep -Eq '^NATS_ADVERTISE_URL=[a-z]+://[^[:space:]]+$' <<<"${env}"
}

# What: _ci_compose_profile_flags per compose profile answer
# Why: compose up skips a profiled service without its flag
# From: Issue #1683 | PR #1858
@test "compose profile flags cover every profile and fail closed" {
    local case rc want f
    local -A V=([@P1@]="$(_val name)" [@P2@]="$(_val name)" [@ERR@]="$(_val name)")
    f="$(_val path)"
    while IFS='|' read -r case rc want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${case}" in
            two) _docker_answer ' compose * config --profiles *' 0 "${V[@P1@]}\n${V[@P2@]}" ;;
            none) _docker_answer ' compose * config --profiles *' 0 ;;
            broken) _docker_answer ' compose * config --profiles *' 1 '' "${V[@ERR@]}" ;;
        esac
        run _ci_compose_profile_flags "${f}"
        _expect "${case}" "${rc}" "$(printf '%b' "$(_fill "${want}")")" || return 1
        grep -q -F -- " -f ${f} config --profiles" "${DS}/docker.log" || { echo "${case}: argv $(cat "${DS}/docker.log")"; return 1; }
    done <<'CASES'
two|0|=--profile\n@P1@\n--profile\n@P2@
none|0|=
broken|2|[CI-ERROR-CORE-0106];@ERR@
CASES
}

# What: _ci_validate_up argv, host-mode log, empty start set
# Why: AG-VAL-027: every service starts or is named excluded
# From: Issue #1683 | PR #1858
@test "validate up starts every profile and names host-mode exclusions" {
    local case answer rc want deny d
    local -a ds
    local -A V=(
        [@P@]="$(_val name)" [@H@]="$(_val name)" [@N@]="$(_val name)" [@X@]="$(_val name)" [@PR@]="$(_val name)"
        [@F@]="$(_val path)" [@NET@]="$(_val path)" [@PIN@]="$(_val path)"
    )
    # What: stub records the socket proxy render call
    # Why: up renders the proxy policy before compose up
    # From: Issue #1683 | PR #1858
    ci_cmd_socket_proxy_config() { echo "RENDER $*"; }
    while IFS='|' read -r case answer rc want deny; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        _docker_answer ' compose * config --profiles *' 0 "${V[@PR@]}"
        case "${answer}" in
            mixed) _docker_answer ' compose * config --format json *' 0 \
                "{\"services\":{\"${V[@H@]}\":{\"healthcheck\":{}},\"${V[@N@]}\":{},\"${V[@X@]}\":{\"network_mode\":\"host\"}}}" ;;
            host-only) _docker_answer ' compose * config --format json *' 0 \
                "{\"services\":{\"${V[@X@]}\":{\"network_mode\":\"host\"}}}" ;;
        esac
        CI_COMPOSE_FILE="${V[@F@]}" run _ci_validate_up "${V[@P@]}" "${V[@NET@]}" "${V[@PIN@]}"
        output+=$'\n'"--- docker.log"$'\n'"$(cat "${DS}/docker.log")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        IFS=';' read -r -a ds <<< "$(_fill "${deny}")"
        for d in "${ds[@]}"; do
            [[ "${output}" != *"${d}"* ]] || { echo "${case}: has '${d}': ${output}"; return 1; }
        done
    done <<'CASES'
start|mixed|0|[CI-INFO-VALIDATE-0055] service="@X@";RENDER @F@;--- docker.log;compose -p @P@ -f @F@ -f @NET@ -f @PIN@ --profile @PR@ up -d @H@ @N@|up -d @X@;@N@ @X@
none-startable|host-only|2|[CI-ERROR-VALIDATE-0018]|RENDER;up -d
CASES
}

# What: down, leftover sweep, state root; raw errors
# Why: an aborted up leaves containers; masking hid it
# From: Issue #1683 | PR #1858
@test "validate teardown removes leftovers and never hides a failure" {
    local mode rc want m nofile nobase state
    local -A V=([@C@]="$(_val name)" [@V@]="$(_val name)" [@P@]="$(_val name)" [@ERR@]="$(_val name) $(_val name)")
    nofile="$(_val path)" nobase="$(_val path)"
    grep -v '^  CI_COMPOSE_FILE:' "${CI_MANIFEST}" > "${nofile}"
    grep -v '^  alpine:' "${CI_MANIFEST}" > "${nobase}"
    while IFS='|' read -r mode rc want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        mkdir -p "${DS}/volumes/${V[@V@]}"
        _docker_answer ' container ls *' 0 "${V[@C@]}"
        _docker_answer ' container rm *' 0
        _docker_answer ' network ls *' 0
        [ "${mode}" != fail ] || _docker_answer ' compose * down *' 1 '' "${V[@ERR@]}"
        m="${CI_MANIFEST}"
        [ "${mode}" != nofile ] || m="${nofile}"
        [ "${mode}" != nobase ] || m="${nobase}"
        state="$(_val path)"
        mkdir -p "${state}/cache"
        export LANCACHE_STATE_DIR="${state}"
        CI_MANIFEST="${m}" run _ci_validate_teardown "" "${V[@P@]}"
        _expect "${mode}" "${rc}" "$(_fill "${want}")" || return 1
        grep -qx "container rm -f ${V[@C@]}" "${DS}/docker.log" && [ ! -e "${DS}/volumes/${V[@V@]}" ] \
            || { echo "${mode}: leftovers kept: $(cat "${DS}/docker.log")"; return 1; }
        if [ "${mode}" = nobase ]; then
            [ -d "${state}" ] && ! grep -q '^run ' "${DS}/docker.log" || { echo "nobase cleared: $(cat "${DS}/docker.log")"; return 1; }
        else
            grep -q "^run --rm --network none -v ${state}:/s " "${DS}/docker.log" && [ ! -e "${state}" ] \
                || { echo "${mode}: state root kept: $(cat "${DS}/docker.log")"; return 1; }
        fi
        [ "${mode}" != nofile ] || ! grep -q '^compose' "${DS}/docker.log" || { echo "nofile ran compose"; return 1; }
    done <<'CASES'
ok|0|-
fail|2|[CI-ERROR-VALIDATE-0058] project="@P@";@ERR@
nofile|2|[CI-ERROR-VARIABLES-0001] name="CI_COMPOSE_FILE"
nobase|2|[CI-ERROR-VALIDATE-0102] key="base_images.alpine"
CASES
}

@test "validate default tears the stack down even when up fails" {
    # What: Teardown runs on the failure path.
    # Why: A leaked stack holds the slot, poisons reruns.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}" GITHUB_REPOSITORY=owner/fixture-repo
    _ci_validate_reserve() { echo "subnet=172.16.1.32/27 holder=1234"; }
    _ci_validate_net_override() { echo "networks:"; }
    _ci_validate_pin_override() { echo "services:"; }
    _ci_validate_up() { echo "boom"; return 1; }
    _ci_validate_teardown() { echo "TEARDOWN holder=$1 project=$2"; }
    run _ci_default_validate "proxy=sha256:x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"TEARDOWN holder=1234 project=fixture-repo-validate-172_16_1_32_27"* ]]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0017"* ]]
}

@test "validate default flags a subnet collision distinctly" {
    # What: A pool-overlap up failure is a collision id.
    # Why: Diagnosis points at the slot, not the images.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}" GITHUB_REPOSITORY=owner/fixture-repo
    _ci_validate_reserve() { echo "subnet=172.16.1.32/27 holder=1234"; }
    _ci_validate_net_override() { echo "networks:"; }
    _ci_validate_pin_override() { echo "services:"; }
    _ci_validate_up() { echo "Pool overlaps with other one"; return 1; }
    _ci_validate_teardown() { :; }
    run _ci_default_validate "proxy=sha256:x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0016"* ]]
}

@test "validate slot lock refuses a second holder of one /27" {
    # What: One flock per /27; the second call fails.
    # Why: Two runs must never share a validation subnet.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}"
    local first
    first="$(_ci_validate_slot_lock 172.16.1.32/27)"
    [ -n "${first}" ]
    run _ci_validate_slot_lock 172.16.1.32/27
    [ "${status}" -eq 1 ]
    _ci_validate_release "${first}"
    # What: a failing flock is rc 2 with raw, not "held".
    # Why: else every slot reads busy: wrong "no free /27".
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/fbin"; mkdir -p "${bin}"
    _tool_stub "${bin}" flock <<'STUB'
echo "flock: cannot open lock file: Read-only file system" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_validate_slot_lock 172.16.1.64/27
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-VALIDATE-0073] subnet="172.16.1.64/27"'* ]]
    [[ "${output}" == *"Read-only file system"* ]]
}

# What: wait_healthy fails per service and names its check
# Why: parallel waits still surface each failure with logs
# From: Issue #1683 | PR #1858
@test "validate wait_healthy reports each failing service and its check" {
    local case FAIL_SVC FAIL_RC rc want deny d
    local -a ds
    local -A V=([@P@]="$(_val name)" [@H1@]="$(_val name)" [@H2@]="$(_val name)" [@N1@]="$(_val name)")
    # What: service lists and wait results come from the row
    # Why: the aggregation is under test, not the waits
    # From: Issue #1683 | PR #1858
    _ci_validate_health_services() { printf '%s\n%s\n' "${V[@H1@]}" "${V[@H2@]}"; }
    _ci_validate_no_health_services() { printf '%s\n' "${V[@N1@]}"; }
    _ci_validate_wait_one() { [ "$2" != "${FAIL_SVC}" ] || return "${FAIL_RC}"; }
    _ci_validate_wait_stable() { [ "$2" != "${FAIL_SVC}" ] || return "${FAIL_RC}"; }
    _ci_validate_service_evidence() { echo "evidence-$2"; }
    while IFS='|' read -r case FAIL_SVC FAIL_RC rc want deny; do
        FAIL_SVC="$(_fill "${FAIL_SVC}")"
        run _ci_validate_wait_healthy "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        IFS=';' read -r -a ds <<< "$(_fill "${deny}")"
        for d in "${ds[@]}"; do
            [[ "${output}" != *"${d}"* ]] || { echo "${case}: has '${d}': ${output}"; return 1; }
        done
    done <<'CASES'
all-ok|-|0|0|-|[CI-ERROR
health-fail|@H2@|1|1|[CI-ERROR-VALIDATE-0009] service="@H2@" check="healthcheck";evidence-@H2@|evidence-@H1@;evidence-@N1@
stability-fail|@N1@|1|1|[CI-ERROR-VALIDATE-0009] service="@N1@" check="stability";evidence-@N1@|evidence-@H1@;evidence-@H2@
docker-error|@H1@|2|2|[CI-ERROR-VALIDATE-0081] service="@H1@" check="healthcheck" rc=2|evidence-
CASES
}

# What: service evidence: container, json state, full logs
# Why: the failure reason lives in the container log
# From: Issue #1683 | PR #1858
@test "validate service evidence prints state and full logs" {
    local case rc want
    local -A V=(
        [@P@]="$(_val name)" [@S@]="$(_val name)" [@C@]="$(_val name)" [@L1@]="$(_val name)"
        [@L2@]="$(_val name) $(_val name)" [@X@]="$(_val int 1 125)"
    )
    while IFS='|' read -r case rc want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        if [ "${case}" = present ]; then _docker_answer ' compose -p * ps -aq *' 0 "${V[@C@]}"; else _docker_answer ' compose -p * ps -aq *' 0; fi
        _docker_answer ' inspect --format {{json .State}} *' 0 "{\"Status\":\"exited\",\"ExitCode\":${V[@X@]}}"
        _docker_answer ' compose -p * logs *' 0 "${V[@L1@]}\n${V[@L2@]}"
        run _ci_validate_service_evidence "${V[@P@]}" "${V[@S@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${case}" = present ] || ! grep -q '^inspect ' "${DS}/docker.log" || { echo "${case}: inspected no container"; return 1; }
    done <<'CASES'
present|0|container=@C@;"ExitCode":@X@;@L1@;@L2@
none|0|container=<none>;@L1@;@L2@
CASES
}

# What: health, no-health, startable lists from compose json
# Why: up uses startable; the wait splits on healthcheck
# From: Issue #1683 | PR #1858
@test "validate service lists split compose services per filter" {
    local case fn answer rc want json
    local -A V=([@H@]="$(_val name)" [@N@]="$(_val name)" [@X@]="$(_val name)" [@Y@]="$(_val name)" [@ERR@]="$(_val name)")
    json="{\"services\":{\"${V[@H@]}\":{\"healthcheck\":{}},\"${V[@N@]}\":{},"
    json+="\"${V[@X@]}\":{\"network_mode\":\"host\",\"healthcheck\":{}},\"${V[@Y@]}\":{\"network_mode\":\"host\"}}}"
    while IFS='|' read -r case fn answer rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        _docker_answer ' compose * config --profiles *' 0
        case "${answer}" in
            json) _docker_answer ' compose * config --format json *' 0 "${json}" ;;
            fail) _docker_answer ' compose * config --format json *' 1 '' "${V[@ERR@]}" ;;
            text) _docker_answer ' compose * config --format json *' 0 "${V[@ERR@]}" ;;
        esac
        run "${fn}"
        _expect "${case}" "${rc}" "$(printf '%b' "$(_fill "${want}")")" || return 1
    done <<'CASES'
health|_ci_validate_health_services|json|0|=@H@
no-health|_ci_validate_no_health_services|json|0|=@N@
startable|_ci_validate_startable|json|0|=@H@\n@N@
unreadable|_ci_validate_startable|fail|2|[CI-ERROR-VALIDATE-0086];@ERR@;[CI-ERROR-VALIDATE-0069]
not-json|_ci_validate_startable|text|2|[CI-ERROR-VALIDATE-0057]
CASES
}

# What: wait for health or stability per container answer
# Why: only healthy, settled or a clean one-shot passes
# From: Issue #1683 | PR #1858
@test "validate wait maps health and stability answers per row" {
    local case fn rc want
    local -A V=(
        [@P@]="$(_val name)" [@S@]="$(_val name)" [@C@]="$(_val name)" [@T@]="$(_val name)"
        [@ERR@]="$(_val name)" [@X@]="$(_val int 1 125)"
    )
    _virtual_clock
    while IFS='|' read -r case fn rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${case}" in
            health*|unhealthy) _docker_answer ' compose -p * ps -q *' 0 "${V[@C@]}" ;;
            no-container) _docker_answer ' compose -p * ps -aq *' 0 ;;
            *) _docker_answer ' compose -p * ps -aq *' 0 "${V[@C@]}" ;;
        esac
        case "${case}" in
            healthy) _docker_answer ' inspect --format {{.State.Health.Status}} *' 0 healthy ;;
            unhealthy) _docker_answer ' inspect --format {{.State.Health.Status}} *' 0 unhealthy ;;
            health-error) _docker_answer ' inspect *' 1 '' "${V[@ERR@]}" ;;
            stable-error) _docker_answer ' inspect --format {{.State.Status}} *' 1 '' "${V[@ERR@]}"
                _docker_answer ' inspect --format {{.State.StartedAt}} *' 0 "${V[@T@]}" ;;
            stable) _docker_answer ' inspect --format {{.State.Status}} *' 0 running
                _docker_answer ' inspect --format {{.State.StartedAt}} *' 0 "${V[@T@]}" ;;
            crash-loop) _docker_answer ' inspect --format {{.State.Status}} *' 0 running
                _docker_answer ' inspect --format {{.State.StartedAt}} *' 0 "${V[@T@]}-%CALL%" ;;
            not-running) _docker_answer ' inspect --format {{.State.Status}} *' 0 restarting
                _docker_answer ' inspect --format {{.State.StartedAt}} *' 0 "${V[@T@]}" ;;
            one-shot-ok) _docker_answer ' inspect --format {{.State.Status}} *' 0 exited
                _docker_answer ' inspect --format {{.State.ExitCode}} *' 0 0 ;;
            one-shot-fail) _docker_answer ' inspect --format {{.State.Status}} *' 0 exited
                _docker_answer ' inspect --format {{.State.ExitCode}} *' 0 "${V[@X@]}" ;;
        esac
        run "${fn}" "${V[@P@]}" "${V[@S@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
healthy|_ci_validate_wait_one|0|-
unhealthy|_ci_validate_wait_one|1|[CI-INFO-VALIDATE-0077] service="@S@" container="@C@" health=unhealthy
health-error|_ci_validate_wait_one|2|[CI-ERROR-CORE-0106];@ERR@
stable|_ci_validate_wait_stable|0|-
crash-loop|_ci_validate_wait_stable|1|[CI-INFO-VALIDATE-0080] service="@S@" container="@C@" last_status="running"
not-running|_ci_validate_wait_stable|1|[CI-INFO-VALIDATE-0080] service="@S@" container="@C@" last_status="restarting"
one-shot-ok|_ci_validate_wait_stable|0|-
one-shot-fail|_ci_validate_wait_stable|1|[CI-INFO-VALIDATE-0079] service="@S@" container="@C@" exit_code=@X@
no-container|_ci_validate_wait_stable|1|[CI-INFO-VALIDATE-0080] service="@S@" container="none"
stable-error|_ci_validate_wait_stable|2|[CI-ERROR-CORE-0106];@ERR@
CASES
}

@test "ipv4 to int converts a dotted quad" {
    # What: Dotted quad to a 32-bit integer.
    # Why: Integer masking proves a /27 overlap.
    # From: Issue #1683
    run _ci_ipv4_to_int 172.16.1.32
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 2886730016 ]
}

@test "validate subnet is deterministic and in 172.16/12" {
    # What: Same seed yields the same /27 in 172.16/12.
    # Why: Reproducible slot from the private B block.
    # From: Issue #1683
    local a b o2 host
    a="$(_ci_validate_subnet seed-one)"
    b="$(_ci_validate_subnet seed-one)"
    [ "${a}" = "${b}" ]
    [[ "${a}" == 172.*/27 ]]
    o2="${a#172.}"; o2="${o2%%.*}"
    [ "${o2}" -ge 16 ]
    [ "${o2}" -le 31 ]
    host="${a%/27}"; host="${host##*.}"
    [ "$(( host % 32 ))" -eq 0 ]
}

# What: a slot against live networks: overlap, free, errors
# Why: reserve must skip a collision, never a free slot
# From: Issue #1683 | PR #1858
@test "validate subnet conflicts map each live network answer" {
    local case rc want free
    local -A V=([@N1@]="$(_val name)" [@N2@]="$(_val name)" [@ERR@]="$(_val name)")
    # What: two distinct slots from the slot owner
    # Why: one slot overlaps itself; distinct slots never do
    # From: Issue #1683 | PR #1858
    V[@SLOT@]="$(_ci_validate_subnet "$(_val name)")"
    free="${V[@SLOT@]}"
    while [ "${free}" = "${V[@SLOT@]}" ]; do free="$(_ci_validate_subnet "$(_val name)")"; done
    V[@FREE@]="${free}"
    while IFS='|' read -r case rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${case}" in
            overlap) _docker_answer ' network ls *' 0 "${V[@N1@]}"
                _docker_answer ' network inspect *' 0 "${V[@SLOT@]}" ;;
            free) _docker_answer ' network ls *' 0 "${V[@N1@]}"
                _docker_answer ' network inspect *' 0 "${V[@FREE@]}" ;;
            ls-fails) _docker_answer ' network ls *' 1 '' "${V[@ERR@]}" ;;
            gone-skipped) _docker_answer ' network ls *' 0 "${V[@N1@]}\n${V[@N2@]}"
                _docker_answer " network inspect ${V[@N1@]} *" 1 '' "Error: No such network: ${V[@N1@]}"
                _docker_answer " network inspect ${V[@N2@]} *" 0 "${V[@SLOT@]}" ;;
            inspect-error) _docker_answer ' network ls *' 0 "${V[@N1@]}"
                _docker_answer ' network inspect *' 1 '' "${V[@ERR@]}" ;;
        esac
        run _ci_validate_subnet_conflicts "${V[@SLOT@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
overlap|0|=@SLOT@
free|1|=
ls-fails|2|[CI-ERROR-VALIDATE-0074] target="@SLOT@";@ERR@
gone-skipped|0|=@SLOT@
inspect-error|2|[CI-ERROR-VALIDATE-0051] network="@N1@";@ERR@
CASES
}

@test "validate reserve prints subnet and holder" {
    # What: Reserve yields a free /27 and lock pid.
    # Why: default_validate reads both as fields.
    # From: Issue #1683
    _ci_validate_subnet_conflicts() { return 1; }
    _ci_validate_slot_lock() { echo 4242; }
    run _ci_validate_reserve
    [ "${status}" -eq 0 ]
    [[ "${output}" == subnet=172.*"/27 holder=4242" ]]
    _ci_validate_subnet_conflicts() { return 2; }
    run _ci_validate_reserve
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0050"* ]]
}

# What: _ci_validate_net_override per compose network set
# Why: the /27 splits without overlap; ports, names reset
# From: Issue #1683 | PR #1858
@test "validate net override isolates and resets services" {
    local case nets rc want count slot lo hi sub a b i j
    local -a subs starts ends ns
    local -A V=([@S@]="$(_val name)" [@H@]="$(_val name)")
    # What: three network names in jq's key order
    # Why: the override lists networks by sorted key
    # From: Issue #1683 | PR #1858
    mapfile -t ns < <(printf '%s\n' "$(_val name)" "$(_val name)" "$(_val name)" | LC_ALL=C sort)
    V[@N1@]="${ns[0]}" V[@N2@]="${ns[1]}" V[@N3@]="${ns[2]}"
    slot="$(_ci_validate_subnet "$(_val name)")" || return 1
    lo="$(_ci_ipv4_to_int "${slot%/*}")" hi=$(( $(_ci_ipv4_to_int "${slot%/*}") + (1 << (32 - ${slot#*/})) ))
    while IFS='|' read -r case nets rc want count; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        _docker_answer ' compose * config --profiles *' 0
        _docker_answer ' compose -f * config --format json ' 0 \
            "$(_fill "{\"services\":{\"@S@\":{},\"@H@\":{\"network_mode\":\"host\"}},\"networks\":{${nets}}}")"
        run _ci_validate_net_override "${slot}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${rc}" -eq 0 ] || continue
        # What: /28 then /29s, all in the slot, disjoint
        # Why: range checks, not a copy of the split math
        # From: Issue #1683 | PR #1858
        mapfile -t subs < <(sed -n 's/^ *- subnet: //p' <<< "${output}")
        starts=() ends=()
        [ "${#subs[@]}" -eq "${count}" ] || { echo "${case}: subnets ${subs[*]}"; return 1; }
        for (( i = 0; i < ${#subs[@]}; i++ )); do
            sub="${subs[i]}"
            [ "${sub#*/}" -eq "$([ "${i}" -eq 0 ] && echo 28 || echo 29)" ] || { echo "${case}: prefix ${sub}"; return 1; }
            a="$(_ci_ipv4_to_int "${sub%/*}")" b=$(( $(_ci_ipv4_to_int "${sub%/*}") + (1 << (32 - ${sub#*/})) ))
            (( a >= lo && b <= hi )) || { echo "${case}: ${sub} outside ${slot}"; return 1; }
            for (( j = 0; j < ${#starts[@]}; j++ )); do
                (( b <= starts[j] || a >= ends[j] )) || { echo "${case}: ${sub} overlaps ${subs[j]}"; return 1; }
            done
            starts+=("${a}") ends+=("${b}")
        done
        # What: network_mode reset for host-mode only
        # Why: a probe may run it in the /27; up never does
        # From: Issue #763 | PR #1858
        [[ "${output}" == *$'  '"${V[@H@]}"$':\n    network_mode: !reset null'* ]] \
            && [ "$(grep -c 'network_mode' <<< "${output}")" -eq 1 ] \
            && [[ "${output}" != *$'  '"${V[@H@]}"$':\n    container_name'* ]] \
            || { echo "${case}: host-mode reset: ${output}"; return 1; }
    done <<'CASES'
default-only|"default":{}|0|networks:;default:;services:;@S@:;container_name: !reset null;ports: !reset []|1
two-extra|"default":{},"@N1@":{},"@N2@":{"internal":true}|0|default:;@N1@:;@N2@:;services:|3
three-extra|"@N1@":{},"@N2@":{},"@N3@":{}|2|[CI-ERROR-VALIDATE-0068] network="|0
CASES
}

# What: per row: inspect answer -> rc and output
# Why: only a real IPv4 may become a probe target
# From: Issue #1683 | PR #1858
@test "validate container ip maps each inspect answer" {
    local case rc want
    local -A V=([@P@]="$(_val name)" [@S@]="$(_val name)" [@C@]="$(_val name)" [@ERR@]="$(_val name)")
    # What: the probe IP is a validation slot address
    # Why: probe targets live in slots from the slot owner
    # From: Issue #1683 | PR #1858
    V[@IP@]="$(_slot_ips 1)" || return 1
    while IFS='|' read -r case rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${case}" in
            ipv4) _docker_answer ' compose -p * ps -q *' 0 "${V[@C@]}"
                _docker_answer " inspect -f * ${V[@C@]} " 0 "${V[@IP@]}" ;;
            no-value) _docker_answer ' compose -p * ps -q *' 0 "${V[@C@]}"
                _docker_answer " inspect -f * ${V[@C@]} " 0 '<no value>' ;;
            no-container) _docker_answer ' compose -p * ps -q *' 0 ;;
            daemon) _docker_answer ' compose -p * ps -q *' 1 '' "${V[@ERR@]}" ;;
        esac
        run _ci_validate_container_ip "${V[@P@]}" "${V[@S@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
ipv4|0|=@IP@
no-value|1|-
no-container|1|-
daemon|2|[CI-ERROR-CORE-0106];@ERR@
CASES
}

# What: network teardown: gone, error, removed, rm fails
# Why: a leftover network must not pass as removed
# From: Issue #1683 | PR #1858
@test "validate network inspect: only not-found means gone" {
    local case rc want
    local -A V=([@ID@]="$(_val name)" [@N@]="$(_val name)" [@ERR@]="$(_val name)")
    while IFS='|' read -r case rc want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${case}" in
            gone) _docker_answer ' network inspect *' 1 '' "Error response from daemon: network ${V[@ID@]} not found" ;;
            inspect-error) _docker_answer ' network inspect *' 1 '' "${V[@ERR@]}" ;;
            *) _docker_answer ' network inspect * --format {{.Name}} *' 0 "${V[@N@]}"
                _docker_answer ' network inspect * --format {{len .Containers}} *' 0 0 ;;
        esac
        case "${case}" in
            removed) _docker_answer ' network rm *' 0 ;;
            rm-fails) _docker_answer ' network rm *' 1 '' "${V[@ERR@]}" ;;
        esac
        run _ci_validate_network_teardown "${V[@ID@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        case "${case}" in removed|rm-fails) grep -qx "network rm ${V[@N@]}" "${DS}/docker.log" || { echo "${case}: no rm"; return 1; } ;; esac
    done <<'CASES'
gone|0|-
inspect-error|2|[CI-ERROR-VALIDATE-0064] network="@ID@";@ERR@
removed|0|-
rm-fails|2|[CI-ERROR-VALIDATE-0053] network="@N@";@ERR@
CASES
}

@test "validate poll returns on success and shows the last error" {
    # What: success is rc 0; a timeout prints last error.
    # Why: a probe timeout must say why it never answered.
    # From: Issue #1683 | PR #1858
    _virtual_clock
    run _ci_validate_poll 3 1 true
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_validate_poll 3 1 bash -c 'echo "connection refused" >&2; exit 7'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"connection refused"* ]]
}

@test "validate dns maps each resolver answer pair" {
    # What: per row: std/ssl IPs and answers -> rc, output.
    # Why: split routing needs two distinct answering modes.
    # From: Issue #668 | PR #1858
    local case ipstd ipssl ansstd ansssl rc want
    _ci_validation_dns_domain() { echo a.example.test; }
    _ci_validate_container_ip() { case "$2" in dns-standard) echo "${ipstd}" ;; dns-ssl) echo "${ipssl}" ;; esac; }
    dig() { case "$2" in "@${ipstd}") echo "${ansstd}" ;; "@${ipssl}") echo "${ansssl}" ;; esac; }
    while IFS='|' read -r case ipstd ipssl ansstd ansssl rc want; do
        run _ci_validate_dns proj
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
no-ip|||||2|CI-ERROR-VALIDATE-0010
one-mode|1.1.1.1|2.2.2.2|10.0.0.1||1|CI-ERROR-VALIDATE-0011
same|1.1.1.1|2.2.2.2|10.0.0.9|10.0.0.9|1|CI-ERROR-VALIDATE-0021
split|1.1.1.1|2.2.2.2|10.0.0.1|10.0.0.2|0|-
CASES
}

# What: _ci_validate_proxy MISS, HIT and failures per row
# Why: a HIT through the proxy IP proves the cache path
# From: Issue #1683 | PR #1858
@test "validate proxy maps each request outcome, raw on failure" {
    local case inspect row_mode rc want row_n row_args
    local -A V=([@P@]="$(_val name)" [@C@]="$(_val name)" [@ERR@]="$(_val name)")
    row_n="$(_val path)" row_args="$(_val path)"
    V[@IP@]="$(_slot_ips 1)" && V[@HTTP@]="$(_ci_service_port http)" && V[@URL@]="$(_ci_validation_proxy_probe_url)" \
        || return 1
    # What: curl double: cache answer per call; argv logged
    # Why: no live proxy; the call count picks MISS or HIT
    # From: Issue #1683 | PR #1858
    curl() {
        local n
        n=$(( $(cat "${row_n}") + 1 )); echo "${n}" > "${row_n}"
        printf '%s\n' "$*" >> "${row_args}"
        case "${row_mode}:${n}" in
            miss-fail:1|repeat-fail:2) echo "${V[@ERR@]}" >&2; return 7 ;;
            *:1) echo "X-Cache-Status: MISS" ;;
            no-hit:2) echo "X-Cache-Status: EXPIRED" ;;
            *) echo "X-Cache-Status: HIT" ;;
        esac
    }
    while IFS='|' read -r case inspect row_mode rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        echo 0 > "${row_n}"; : > "${row_args}"
        _container proxy "${V[@C@]}" "$(_fill "${inspect}")"
        run _ci_validate_proxy "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
no-ip|<no value>|hit|2|[CI-ERROR-VALIDATE-0012]
miss-fail|@IP@|miss-fail|1|[CI-ERROR-VALIDATE-0013];@ERR@
repeat-fail|@IP@|repeat-fail|1|[CI-ERROR-VALIDATE-0065];@ERR@
no-hit|@IP@|no-hit|1|[CI-ERROR-VALIDATE-0014];X-Cache-Status: MISS;X-Cache-Status: EXPIRED
hit|@IP@|hit|0|-
CASES
    [ "$(grep -c -F -- ":${V[@HTTP@]}:${V[@IP@]} -D - -o /dev/null ${V[@URL@]}" "${row_args}")" -eq 2 ] \
        || { echo "curl argv:"; cat "${row_args}"; return 1; }
}

@test "validate probes run in order without a proxy, stop early" {
    # What: all probes in order, NO_PROXY=*, stop on fail.
    # Why: a host http_proxy answered the cache probe.
    # From: Issue #1683 | PR #1858
    local log="${BATS_TEST_TMPDIR}/probes" p
    local -a probes=(dns proxy proxy_stream_map ssl_mitm ssl_dispatch_map
        ui_nats_dns dns_rollback kea_rollback secondary_identity)
    for p in "${probes[@]}"; do
        eval "_ci_validate_${p}() {
            echo \"${p} \${NO_PROXY}|\${no_proxy} \$*\" >> '${log}'
            [ '${p}' != \"\${FAIL_PROBE:-}\" ]
        }"
    done
    export NO_PROXY=keep no_proxy=keep
    : > "${log}"
    _ci_validate_probes proj net.yml pin.yml
    [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "${probes[*]}" ] || {
        echo "order:"; cat "${log}"; return 1; }
    [ "$(cut -d' ' -f2 "${log}" | sort -u)" = '*|*' ] || {
        echo "proxy:"; cat "${log}"; return 1; }
    [ "${NO_PROXY}|${no_proxy}" = 'keep|keep' ]
    grep -qx 'kea_rollback \*|\* proj net.yml pin.yml' "${log}"
    export FAIL_PROBE=ssl_mitm; : > "${log}"
    run _ci_validate_probes proj net.yml pin.yml
    [ "${status}" -eq 1 ]
    [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "dns proxy proxy_stream_map ssl_mitm" ] || {
        echo "early:"; cat "${log}"; return 1; }
}

# What: _ci_validate_ssl_mitm per proxy, CA and TLS answer
# Why: only our LAN CA as https issuer proves the MITM
# From: Issue #668 | PR #1858
@test "validate ssl-mitm maps each proxy, CA and handshake case" {
    local case inspect cp row_hs row_issuer rc want row_log
    local -A V=([@P@]="$(_val name)" [@C@]="$(_val name)" [@CA@]="$(_val name)" [@F@]="$(_val name)" [@ERR@]="$(_val name)")
    row_log="$(_val path)"
    V[@IP@]="$(_slot_ips 1)" && V[@CADIR@]="$(_ci_proxy_constant CA_DIR)" && V[@TLS@]="$(_ci_service_port https)" \
        && V[@DOM@]="$(_ci_validation_dns_domain)" || return 1
    # What: openssl double: TLS answer per row; argv logged
    # Why: no live proxy; row_* names avoid callee locals
    # From: Issue #1683 | PR #1858
    openssl() {
        printf '%s\n' "$*" >> "${row_log}"
        case "$*" in
            *s_client*) [ "${row_hs}" = ok ] || { echo "${V[@ERR@]}" >&2; return 1; }; echo "${V[@C@]}" ;;
            *-subject*) echo "subject=${V[@CA@]}" ;;
            *-issuer*) echo "issuer=${row_issuer}" ;;
        esac
    }
    while IFS='|' read -r case inspect cp row_hs row_issuer rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        : > "${row_log}"
        row_issuer="$(_fill "${row_issuer}")"
        _container proxy "${V[@C@]}" "$(_fill "${inspect}")"
        if [ "${cp}" -eq 0 ]; then
            _docker_answer " cp ${V[@C@]}:${V[@CADIR@]}/* *" 0
        else
            _docker_answer " cp ${V[@C@]}:${V[@CADIR@]}/* *" "${cp}" '' "${V[@ERR@]}"
        fi
        run _ci_validate_ssl_mitm "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
no-ip|<no value>|0|ok|@CA@|2|[CI-ERROR-VALIDATE-0023]
no-ca|@IP@|1|ok|@CA@|2|[CI-ERROR-VALIDATE-0024];@ERR@
handshake|@IP@|0|fail|@CA@|1|[CI-ERROR-VALIDATE-0025];@ERR@
foreign|@IP@|0|ok|@F@|1|[CI-ERROR-VALIDATE-0026] issuer="@F@" ca="@CA@"
ours|@IP@|0|ok|@CA@|0|-
CASES
    grep -q -F -- "s_client -connect ${V[@IP@]}:${V[@TLS@]} -servername ${V[@DOM@]}" "${row_log}" \
        || { echo "s_client argv:"; cat "${row_log}"; return 1; }
}

# What: stream and ssl-dispatch map checks per stand-in row
# Why: wildcards follow the SNI; depth>=2 takes the relay
# From: Issue #1322 | PR #1858
@test "validate proxy maps route by SNI and depth per row" {
    local case fn file cid map rc want
    local -A V=([@P@]="$(_val name)" [@C@]="$(_val name)" [@D@]="$(_val name)" [@H@]="$(_val name)" [@ERR@]="$(_val name)")
    V[@SF@]="$(_ci_proxy_constant STREAM_TARGET_FILE)" && V[@DF@]="$(_ci_proxy_constant SSL_DISPATCH_MAP_FILE)" \
        && V[@PASS@]="$(_ci_proxy_constant SSL_DISPATCH_PASSTHROUGH_RELAY_PORT)" \
        && V[@MITM@]="$(_ci_proxy_constant SSL_DISPATCH_MITM_RELAY_PORT)" && V[@TLS@]="$(_ci_service_port https)" \
        || return 1
    while IFS='|' read -r case fn file cid map rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        if [ "${cid}" = yes ]; then
            _docker_answer ' compose -p * ps -q *' 0 "${V[@C@]}"
        else
            _docker_answer ' compose -p * ps -q *' 0
        fi
        file="$(_fill "${file}")"
        case "${map}" in
            -) ;;
            fail) _docker_answer " exec ${V[@C@]} cat ${file} " 1 '' "${V[@ERR@]}" ;;
            *) _docker_answer " exec ${V[@C@]} cat ${file} " 0 "$(_fill "${map}")" ;;
        esac
        run "${fn}" "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
stream-sni|_ci_validate_proxy_stream_map|@SF@|yes|    *.@D@   $ssl_preread_server_name:@TLS@;|0|-
stream-root|_ci_validate_proxy_stream_map|@SF@|yes|    *.@D@   @D@:@TLS@;|1|[CI-ERROR-VALIDATE-0020];*.@D@   @D@:@TLS@
stream-no-proxy|_ci_validate_proxy_stream_map|@SF@|no|-|2|[CI-ERROR-VALIDATE-0022]
stream-unreadable|_ci_validate_proxy_stream_map|@SF@|yes|fail|2|[CI-ERROR-CORE-0106];@ERR@;[CI-ERROR-VALIDATE-0019]
dispatch-split|_ci_validate_ssl_dispatch_map|@DF@|yes|    "~^[^.]+\\.@D@$"   @H@:@MITM@;\n    "~^.+\\.@D@$"   @H@:@PASS@;|0|-
dispatch-mitm|_ci_validate_ssl_dispatch_map|@DF@|yes|    "~^[^.]+\\.@D@$"   @H@:@MITM@;\n    "~^.+\\.@D@$"   @H@:@MITM@;|1|[CI-ERROR-VALIDATE-0029];relay :@PASS@ ;"~^.+\.@D@$"
dispatch-no-proxy|_ci_validate_ssl_dispatch_map|@DF@|no|-|2|[CI-ERROR-VALIDATE-0027]
dispatch-unreadable|_ci_validate_ssl_dispatch_map|@DF@|yes|fail|2|[CI-ERROR-CORE-0106];@ERR@;[CI-ERROR-VALIDATE-0028]
CASES
}

# What: ui base, session and add-record per stand-in row
# Why: the probe reaches the ui only via owner-read values
# From: Issue #1164 | PR #1858
@test "validate ui base, session and add-record per stand-in row" {
    local case rc want base ttl
    local -A V=(
        [@P@]="$(_val name)" [@S@]="$(_val name)" [@C@]="$(_val name)" [@TOK@]="$(_val name)"
        [@N@]="$(_val name)" [@Z@]="$(_val name)." [@PORT@]="$(_val port)" [@Q@]="$(_val port)"
    )
    V[@ZN@]="${V[@Z@]%.}"
    V[@IP@]="$(_slot_ips 1)" && ttl="$(_ci_variable CI_VALIDATE_PROBE_TTL)" || return 1
    _virtual_clock
    _curl_stub
    while IFS='|' read -r case rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-* "${DS}"/ui-* "${DS}/ui.posts" "${DS}/fail-curl"
        base="http://${V[@IP@]}:${V[@PORT@]}"
        printf '<input type="hidden" name="csrf_token" value="%s">\n' "${V[@TOK@]}" > "${DS}/ui-page"
        case "${case}" in
            base) _container "${V[@S@]}" "${V[@C@]}" "${V[@IP@]}" "${V[@PORT@]}/tcp" ;;
            base-noip) _container "${V[@S@]}" "${V[@C@]}" '<no value>' "${V[@PORT@]}/tcp" ;;
            base-ports) _container "${V[@S@]}" "${V[@C@]}" "${V[@IP@]}" "${V[@PORT@]}/tcp\n${V[@Q@]}/tcp" ;;
            session-down) : > "${DS}/fail-curl" ;;
            session-nofield) : > "${DS}/ui-page" ;;
            add-other) echo 500 > "${DS}/ui-post-status" ;;
            *-nobase) base="" ;;
        esac
        case "${case}" in
            base*) run _ci_validate_ui_base "${V[@P@]}" "${V[@C@]}" ;;
            session*) run _ci_validate_ui_session "$(_val path)" "${base}" ;;
            add*) run _ci_validate_ui_add_record "${base}" "$(_val path)" "${V[@TOK@]}" "${V[@Z@]}" "${V[@N@]}" "${V[@IP@]}" ;;
        esac
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${case}" != add ] \
            || grep -qxF "domains/${V[@ZN@]}/add csrf_token=${V[@TOK@]} name=${V[@N@]} record_type=A content=${V[@IP@]} ttl=${ttl}" "${DS}/ui.posts" \
            || { echo "posts:"; cat "${DS}/ui.posts"; return 1; }
    done <<'CASES'
base|0|=http://@IP@:@PORT@
base-noip|2|[CI-ERROR-VALIDATE-0103]
base-ports|2|[CI-ERROR-VALIDATE-0104];@PORT@/tcp;@Q@/tcp
session|0|=@TOK@
session-down|1|[CI-ERROR-VALIDATE-0031];curl: (7)
session-nofield|1|[CI-ERROR-VALIDATE-0032]
session-nobase|2|[CI-ERROR-VALIDATE-0030]
add|0|-
add-other|1|[CI-ERROR-VALIDATE-0034] url="http://@IP@:@PORT@/domains/@ZN@/add" code="500"
add-nobase|2|[CI-ERROR-VALIDATE-0033]
CASES
}

# What: _ci_validate_dns_resolves per dig answer row
# Why: only the expected answer passes; a miss shows why
# From: Issue #1164 | PR #1858
@test "validate dns-resolves maps target and answers" {
    local case ip row_mode rc want budget row_log
    local -A V=(
        [@P@]="$(_val name)" [@S@]="$(_val name)" [@C@]="$(_val name)" [@N@]="$(_val name)"
        [@Z@]="$(_val name)." [@W@]="$(_val name)"
    )
    V[@F@]="${V[@N@]}.${V[@Z@]}"
    V[@IP@]="$(_slot_ips 1)" && V[@A@]="$(_ci_validate_probe_ip 1)" && V[@B@]="$(_ci_validate_probe_ip 2)" \
        && budget="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 1
    _virtual_clock
    row_log="$(_val path)"
    # What: dig double: one answer per row, echoing its argv
    # Why: no live resolver; row_mode picks the answer
    # From: Issue #1164 | PR #1858
    dig() {
        printf '%s\n' "$*" >> "${row_log}"
        case "${row_mode}" in
            never) echo "${V[@B@]} $*" ;;
            warn) echo "${V[@W@]}" >&2; echo "${V[@A@]}" ;;
            *) echo "${V[@A@]}" ;;
        esac
    }
    while IFS='|' read -r case ip row_mode rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        : > "${row_log}"
        _container "${V[@S@]}" "${V[@C@]}" "$(_fill "${ip}")"
        run _ci_validate_dns_resolves "${V[@P@]}" "${V[@S@]}" "${V[@F@]}" "${V[@A@]}" "${budget}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${case}" != never ] || [ "$(grep -cF -- "+short @${V[@IP@]} A ${V[@F@]}" "${row_log}")" -eq "${budget}" ] \
            || { echo "never: $(grep -c . "${row_log}") dig calls for budget ${budget}"; return 1; }
    done <<'CASES'
no-ip|<no value>|match|2|[CI-ERROR-VALIDATE-0035]
never|@IP@|never|1|[CI-ERROR-VALIDATE-0036];full answer:;@@IP@ A @F@;zone SOA:;@@IP@ SOA @Z@;service:
warn|@IP@|warn|0|-
match|@IP@|match|0|-
CASES
}

# What: _ci_validate_ui_nats_dns per ui and dns answer row
# Why: one ui write must reach both dns modes via NATS
# From: Issue #1164 | PR #1858
@test "validate ui-nats-dns writes once and resolves on both dns" {
    local case post row_seen rc want zone label ip row_log dns_wait axfr_wait
    local -a ips
    local -A V=([@P@]="$(_val name)" [@U@]="$(_val name)" [@D1@]="$(_val name)" [@D2@]="$(_val name)" [@TOK@]="$(_val name)" [@PORT@]="$(_val port)")
    mapfile -t ips < <(_slot_ips 3)
    [ "${#ips[@]}" -eq 3 ] && zone="$(_ci_validate_lan_zone)" && label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" \
        && ip="$(_ci_validate_probe_ip 1)" && dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" \
        && axfr_wait="$(_ci_variable CI_VALIDATE_AXFR_WAIT)" || return 1
    V[@IP1@]="${ips[1]}" V[@IP2@]="${ips[2]}"
    row_log="$(_val path)"
    _virtual_clock
    _curl_stub
    # What: dig double: a dns answers from the record model
    # Why: row_seen names the dns IPs the write reached
    # From: Issue #1164 | PR #1858
    dig() {
        printf '%s\n' "$*" >> "${row_log}"
        local a s=""
        for a in "$@"; do case "${a}" in @*) s="${a#@}" ;; esac; done
        [[ " ${row_seen} " == *" ${s} "* ]] || return 0
        awk -v f="${!#}" '$1 == f { print $2 }' "${DS}/dns-records"
    }
    while IFS='|' read -r case post row_seen rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-* "${DS}"/ui-* "${DS}/ui.posts"
        : > "${DS}/dns-records"
        : > "${row_log}"
        row_seen="$(_fill "${row_seen}")"
        printf '<input type="hidden" name="csrf_token" value="%s">\n' "${V[@TOK@]}" > "${DS}/ui-page"
        echo "${post}" > "${DS}/ui-post-status"
        _container ui "${V[@U@]}" "${ips[0]}" "${V[@PORT@]}/tcp"
        _container dns-standard "${V[@D1@]}" "${V[@IP1@]}"
        _container dns-ssl "${V[@D2@]}" "${V[@IP2@]}"
        run _ci_validate_ui_nats_dns "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${case}" != ok ] || [ "$(cat "${DS}/dns-records")" = "${label}.${zone} ${ip}" ] \
            || { echo "records:"; cat "${DS}/dns-records"; return 1; }
        case "${case}" in
            std-miss) [ "$(grep -cF -- "+short @${V[@IP1@]} A ${label}.${zone}" "${row_log}")" -eq "${dns_wait}" ] ;;
            ssl-miss) [ "$(grep -cF -- "+short @${V[@IP2@]} A ${label}.${zone}" "${row_log}")" -eq "${axfr_wait}" ] ;;
        esac || { echo "${case}: dig calls:"; cat "${row_log}"; return 1; }
    done <<'CASES'
ok|303|@IP1@ @IP2@|0|-
add-fails|500|@IP1@ @IP2@|1|[CI-ERROR-VALIDATE-0034]
std-miss|303|@IP2@|1|[CI-ERROR-VALIDATE-0036] svc="dns-standard"
ssl-miss|303|@IP1@|1|[CI-ERROR-VALIDATE-0036] svc="dns-ssl"
CASES
}

# What: _ci_validate_dns_rollback per key, listener, ui row
# Why: real setup.sh rollback must restore the old record
# From: Issue #628 | PR #1858
@test "validate dns-rollback drives the rollback through setup.sh" {
    local case rc want root d dir key zone label old
    local -a ips
    local -A V=(
        [@P@]="$(_val name)" [@CD@]="$(_val name)" [@CU@]="$(_val name)" [@TOK@]="$(_val name)"
        [@PORT@]="$(_val port)" [@LP@]="$(_val port)" [@H@]="$(_val host)"
    )
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="$(_val path)/deploy/prod"
    _prod_install "${d}" || return 1
    export CI_COMPOSE_FILE="${d}/docker-compose.yml"
    mapfile -t ips < <(_slot_ips 2)
    [ "${#ips[@]}" -eq 2 ] && zone="$(_ci_validate_lan_zone)" && label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" \
        && old="$(_ci_validate_probe_ip 2)" || return 1
    _virtual_clock
    _curl_stub
    # What: dig double: dns answers from the record model
    # Why: ui writes and listener rollbacks change the model
    # From: Issue #628 | PR #1858
    dig() { awk -v f="${!#}" '$1 == f { print $2 }' "${DS}/dns-records"; }
    while IFS='|' read -r case rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-* "${DS}"/listener-* "${DS}"/snap-* "${DS}"/ui-* "${DS}/ui.posts" \
            "${DS}/listener.posts" "${DS}/fail-curl"
        key="$(_val name)" dir="$(_val path)"
        printf '%s' "${key}" > "${DS}/pdns-api-key"
        : > "${DS}/dns-records"
        printf '{"zones":{}}' > "${DS}/listener-snapshots"
        jq -nc --arg n "${label}.${zone}" '{applied: true, changed_names: [$n], zone_check_passed: true,
            republished_to_nats: true, flush_ok: true, flush_failed_names: []}' > "${DS}/listener-rollback"
        printf '<input type="hidden" name="csrf_token" value="%s">\n' "${V[@TOK@]}" > "${DS}/ui-page"
        case "${case}" in
            no-dns) _container dns-standard "" "" ;;
            no-mount) _container dns-standard "${V[@CD@]}" "${ips[0]}" ;;
            *) _docker_answer " inspect -f *${V[@P@]}_shared-secrets*Destination* ${V[@CD@]} " 0 "${dir}"
                _container dns-standard "${V[@CD@]}" "${ips[0]}" ;;
        esac
        if [ "${case}" = no-key ]; then
            _docker_answer " exec ${V[@CD@]} cat ${dir}/* " 0
        else
            _docker_answer " exec ${V[@CD@]} cat ${dir}/* " 0 "${key}"
        fi
        if [ "${case}" = no-url ]; then
            _container ui "${V[@CU@]}" "${ips[1]}" "${V[@PORT@]}/tcp" "$(_val var)=$(_val url)"
        else
            _container ui "${V[@CU@]}" "${ips[1]}" "${V[@PORT@]}/tcp" "DNS_ROLLBACK_URL=http://${V[@H@]}:${V[@LP@]}"
        fi
        case "${case}" in
            down) : > "${DS}/fail-curl" ;;
            open|anykey) echo "${case}" > "${DS}/listener-auth" ;;
            nosnap) : > "${DS}/listener-nosnap" ;;
            norecord) : > "${DS}/listener-norecord" ;;
            rejected) jq -c '.applied = false' "${DS}/listener-rollback" > "${DS}/r" && mv "${DS}/r" "${DS}/listener-rollback" ;;
            flush) jq -c '.flush_ok = false | .flush_failed_names = ["f"]' "${DS}/listener-rollback" > "${DS}/r" \
                && mv "${DS}/r" "${DS}/listener-rollback" ;;
        esac
        run _ci_validate_dns_rollback "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${case}" != ok ] || { [ "$(cat "${DS}/dns-records")" = "${label}.${zone} ${old}" ] \
            && jq -e --arg z "${zone}" '.zone == $z and .snapshot_id == "1"' <<< "$(tail -n 1 "${DS}/listener.posts")" > /dev/null; } \
            || { echo "records: $(cat "${DS}/dns-records") posts: $(cat "${DS}/listener.posts")"; return 1; }
    done <<'CASES'
ok|0|-
no-dns|2|[CI-ERROR-VALIDATE-0037]
no-mount|2|[CI-ERROR-VALIDATE-0107]
no-key|2|[CI-ERROR-VALIDATE-0038]
no-url|2|[CI-ERROR-VALIDATE-0108]
down|1|[CI-ERROR-VALIDATE-0039];curl: (7)
open|1|[CI-ERROR-VALIDATE-0040]
anykey|1|[CI-ERROR-VALIDATE-0041]
nosnap|1|[CI-ERROR-VALIDATE-0042]
rejected|1|[CI-ERROR-VALIDATE-0043];did not report applied=true
flush|1|[CI-ERROR-VALIDATE-0043];cache-flush publishes failed
norecord|1|[CI-ERROR-VALIDATE-0087]
CASES
    # What: ci.sh listener calls never carry the key on argv
    # Why: a secret on argv shows in every process list
    # From: Issue #1683 | PR #1858
    grep -qF -- "${ips[0]}:${V[@LP@]}" "${DS}/curl.argv" \
        && ! grep -F -- "${ips[0]}:${V[@LP@]}" "${DS}/curl.argv" | grep -qF -- "${key}" \
        || { echo "no listener call, or the key on argv"; return 1; }
}

# What: _ci_validate_kea_rollback per run, Kea, setup row
# Why: the real setup.sh rollback must revert live Kea
# From: Issue #763 | PR #1858
@test "validate kea-rollback proves the setup.sh rollback on live Kea" {
    local case rc want rms root d kd sub snaps runs rmd mac_a mac_b kport kuser localenv
    local -a ips
    local -A V=(
        [@P@]="$(_val name)" [@TOK@]="$(_val name)" [@PORT@]="$(_val port)" [@KT@]="$(_val name)"
        [@ERR@]="$(_val name)" [@NET@]="$(_val path)" [@PIN@]="$(_val path)" [@SID@]="$(_val int 1 4000)"
    )
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="$(_val path)/deploy/prod" kd="$(_val path)"
    _prod_install "${d}" || return 1
    mapfile -t ips < <(_slot_ips 3)
    [ "${#ips[@]}" -eq 3 ] && sub="$(_ci_validate_subnet "$(_val name)")" \
        && mac_a="$(_ci_validate_probe_mac 1)" && mac_b="$(_ci_validate_probe_mac 2)" \
        && kport="$(jq -er '.["Control-agent"]["http-port"]' "${root}/services/dhcp/kea-ctrl-agent.conf")" \
        && kuser="$(jq -er '.["Control-agent"].authentication.clients[0].user' "${root}/services/dhcp/kea-ctrl-agent.conf")" \
        || return 1
    export CI_COMPOSE_FILE="${d}/docker-compose.yml" KEA_CTRL_TOKEN="${V[@KT@]}" DHCP_SUBNET="${sub}" \
        KEA_DATA_DIR="${kd}" D="${d}" KD="${kd}"
    # What: the snapshot dir as setup.sh itself maps it
    # Why: ci.sh and setup.sh must agree on where ui writes
    # From: Issue #763 | PR #1858
    _setup_sh_run 'kea_snapshot_host_dir "${D}" "${D}/.env" "${KD}"'
    [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "snapshot dir: ${output}"; return 1; }
    snaps="${output}"
    _virtual_clock
    _curl_stub
    while IFS='|' read -r case rc want rms; do
        rm -rf "${DS}/answers" "${DS}"/answer-used-* "${DS}"/kea-* "${DS}"/kea.* "${DS}"/ui-* "${DS}/ui.posts" "${DS}/fail-kea" "${snaps}"
        : > "${DS}/docker.log"
        mkdir -p "${snaps}" && printf '%s' "${snaps}" > "${DS}/kea-snapdir"
        jq -nc --arg s "${sub}" --argjson id "${V[@SID@]}" '{Dhcp4: {subnet4: [{id: $id, subnet: $s, reservations: []}]}}' \
            > "${DS}/kea-live"
        printf '<input type="hidden" name="csrf_token" value="%s">\n' "${V[@TOK@]}" > "${DS}/ui-page"
        _docker_answer " compose -p * run -d --no-deps --name * dhcp " "$([ "${case}" = krun ] && echo 1 || echo 0)"
        _docker_answer " compose -p * run -d --no-deps --name * ui " "$([ "${case}" = urun ] && echo 1 || echo 0)"
        _docker_answer " inspect -f *NetworkSettings* * " 0 "$([ "${case}" = noip ] && echo '<no value>' || echo "${ips[0]}")" '' 1
        _docker_answer " inspect -f *NetworkSettings* * " 0 "${ips[1]}"
        _docker_answer " inspect -f *ExposedPorts* * " 0 "${V[@PORT@]}/tcp"
        if [ "${case}" = rm ]; then
            _docker_answer " rm -f * " 1 '' "${V[@ERR@]}"
        else
            _docker_answer " rm -f * " 0
        fi
        case "${case}" in
            noenv) export KEA_CTRL_TOKEN="" ;;
            noready) : > "${DS}/fail-kea" ;;
            nosubnet) jq -c --arg s "${ips[2]}/27" '.Dhcp4.subnet4[0].subnet = $s' "${DS}/kea-live" > "${DS}/k" && mv "${DS}/k" "${DS}/kea-live" ;;
            nosnap) : > "${DS}/kea-no-snapshot" ;;
            norevert) : > "${DS}/kea-norevert" ;;
            fails) printf '[{"result":1,"text":"%s"}]' "${V[@ERR@]}" > "${DS}/kea-config-test" ;;
            localenv) localenv="$(_val name)"; printf '%s\n' "${localenv}" > "${d}/.env.local" ;;
        esac
        run _ci_validate_kea_rollback "${V[@P@]}" "${V[@NET@]}" "${V[@PIN@]}"
        export KEA_CTRL_TOKEN="${V[@KT@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        # What: .env.local gone after, existing one kept
        # Why: overlay holds a token; operator file wins
        # From: Issue #763 | PR #1858
        if [ "${case}" = localenv ]; then
            [ "$(cat "${d}/.env.local")" = "${localenv}" ] && rm -f "${d}/.env.local"
        else
            [ ! -e "${d}/.env.local" ]
        fi || { echo "${case}: .env.local left or changed"; return 1; }
        [ "${case}" != ok ] || { [ "$(sort -u "${DS}/kea.urls")" = "http://${ips[0]}:${kport}/" ] \
            && [ "$(sort -u "${DS}/kea.users")" = "${kuser}" ]; } \
            || { echo "ok: urls $(sort -u "${DS}/kea.urls") users $(sort -u "${DS}/kea.users")"; return 1; }
        runs="$(sed -n 's/.* run -d --no-deps --name \([^ ]*\) .*/\1/p' "${DS}/docker.log" | tac | paste -sd' ')"
        rmd="$(sed -n 's/^rm -f //p' "${DS}/docker.log" | paste -sd' ')"
        case "${rms}" in
            both) [ "${rmd}" = "${runs}" ] ;;
            kea) [ "${rmd}" = "${runs##* }" ] ;;
            none) [ -z "${rmd}" ] ;;
        esac || { echo "${case}: runs '${runs}' removed '${rmd}'"; return 1; }
        [ "${case}" != ok ] || jq -e --arg a "${mac_a}" --arg b "${mac_b}" \
            '[.Dhcp4.subnet4[].reservations[]."hw-address"] | (index($a) != null) and (index($b) == null)' "${DS}/kea-live" > /dev/null \
            || { echo "live Kea: $(cat "${DS}/kea-live")"; return 1; }
    done <<'CASES'
ok|0|-|both
krun|2|[CI-ERROR-VALIDATE-0096]|none
noip|2|[CI-ERROR-VALIDATE-0097]|kea
urun|2|[CI-ERROR-VALIDATE-0098]|kea
rm|2|[CI-ERROR-VALIDATE-0099];@ERR@|both
noenv|2|[CI-ERROR-VALIDATE-0089]|both
noready|1|[CI-ERROR-VALIDATE-0090]|both
nosubnet|1|[CI-ERROR-VALIDATE-0091]|both
nosnap|1|[CI-ERROR-VALIDATE-0088]|both
fails|1|[CI-ERROR-VALIDATE-0094];@ERR@|both
norevert|1|[CI-ERROR-VALIDATE-0095]|both
localenv|2|[CI-ERROR-VALIDATE-0113]|both
CASES
    # What: no Kea token value ever reaches a curl argv
    # Why: a secret on argv shows in every process list
    # From: Issue #763 | PR #1858
    ! grep -qF -- "${V[@KT@]}" "${DS}/curl.argv" || { echo "token on argv"; return 1; }
}

# What: _ci_validate_secondary_identity token/register rows
# Why: two secondaries must get distinct NATS identities
# From: Issue #583 | PR #1858
@test "validate secondary-identity maps each token and register case" {
    local case ex reg rc want tok tf label
    local -A V=(
        [@P@]="$(_val name)" [@C@]="$(_val name)" [@TF@]="$(_val name)" [@TE@]="$(_val name)"
        [@PORT@]="$(_val port)" [@ERR@]="$(_val name)" [@U@]="$(_val name)"
    )
    V[@IP@]="$(_slot_ips 1)" && tf="$(_ci_validate_ui_token_file)" && label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 1
    V[@L1@]="${label}-1"
    _curl_stub
    while IFS='|' read -r case ex reg rc want tok; do
        rm -f "${DS}/answers" "${DS}"/answer-used-* "${DS}"/register-* "${DS}/register.posts"
        if [ "${ex}" = noui ]; then
            _container ui "" ""
        else
            _container ui "${V[@C@]}" "${V[@IP@]}" "${V[@PORT@]}/tcp"
        fi
        case "${ex}" in
            file|empty) _docker_answer " exec ${V[@C@]} test -f ${tf} " 0 ;;
            env) _docker_answer " exec ${V[@C@]} test -f ${tf} " 1 ;;
            broken) _docker_answer " exec ${V[@C@]} test -f ${tf} " 126 '' "${V[@ERR@]}" ;;
        esac
        case "${ex}" in
            file) _docker_answer " exec ${V[@C@]} cat ${tf} " 0 "${V[@TF@]}" ;;
            empty) _docker_answer " exec ${V[@C@]} cat ${tf} " 0 ;;
        esac
        _docker_answer " exec ${V[@C@]} printenv * " 0 "${V[@TE@]}"
        case "${reg}" in
            500) echo 500 > "${DS}/register-status"; echo "${V[@ERR@]}" > "${DS}/register-body" ;;
            same) jq -nc --arg u "${V[@U@]}" '{nats_user: $u, nats_password: $u}' > "${DS}/register-body" ;;
            nofields) echo '{}' > "${DS}/register-body" ;;
        esac
        run _ci_validate_secondary_identity "${V[@P@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${tok}" = - ] || [ "$(grep -c "\"token\":\"$(_fill "${tok}")\"" "${DS}/register.posts")" -eq 2 ] \
            || { echo "${case}: register posts:"; cat "${DS}/register.posts"; return 1; }
    done <<'CASES'
no-ui|noui|distinct|2|[CI-ERROR-VALIDATE-0045]|-
empty-token|empty|distinct|2|[CI-ERROR-VALIDATE-0046]|-
file-check-broken|broken|distinct|2|@ERR@;[CI-ERROR-VALIDATE-0066];rc=126|-
register-500|file|500|1|register @L1@: http 500;@ERR@;[CI-ERROR-VALIDATE-0047]|-
no-fields|file|nofields|1|[CI-ERROR-VALIDATE-0048]|-
shared-identity|file|same|1|[CI-ERROR-VALIDATE-0049]|@TF@
file-token|file|distinct|0|-|@TF@
env-token|env|distinct|0|-|@TE@
CASES
    # What: the registration token never reaches curl argv
    # Why: a secret on argv shows in every process list
    # From: Issue #583 | PR #1858
    ! grep -qF -- "${V[@TE@]}" "${DS}/curl.argv" || { echo "token on argv"; return 1; }
}

# =========================================================
# VARIABLES
# =========================================================

@test "variables get: env beats CI_VARIABLES json beats SOT" {
    # What: per row: env/json/SOT sources -> value or fail.
    # Why: GitHub vars arrive once as json (AG-CI-006).
    # From: Issue #1683 | PR #1858
    local m case envs name rc want
    m="$(_val path)"
    local -a ev
    local -A V=(
        [@VAR@]="$(_val var)" [@NOVAR@]="$(_val var)" [@SOTV@]="$(_val name)" [@ENVV@]="$(_val name)"
        [@JSONV@]="$(_val name)" [@BAD@]="$(_val name)" [@NOJQ@]="$(_val path)"
    )
    _path_without "${V[@NOJQ@]}" jq
    _fill "$(printf '%s\n' 'ci_variables:' '  @VAR@: @SOTV@')" > "${m}"
    while IFS='|' read -r case envs name rc want; do
        ev=(); [ "${envs}" = - ] || read -r -a ev <<< "$(_fill "${envs}")"
        if [ "${rc}" -eq 0 ]; then
            run --separate-stderr env "${ev[@]}" CI_MANIFEST="${m}" bash "${CI_SH}" variables get "$(_fill "${name}")"
        else
            run env "${ev[@]}" CI_MANIFEST="${m}" bash "${CI_SH}" variables get "$(_fill "${name}")"
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
sot-default|-|@VAR@|0|=@SOTV@
env-over-sot|@VAR@=@ENVV@|@VAR@|0|=@ENVV@
json-over-sot|CI_VARIABLES={"@VAR@":"@JSONV@"}|@VAR@|0|=@JSONV@
env-over-json|@VAR@=@ENVV@ CI_VARIABLES={"@VAR@":"@JSONV@"}|@VAR@|0|=@ENVV@
bad-json|CI_VARIABLES=@BAD@|@VAR@|2|[CI-ERROR-VARIABLES-0015] name="@VAR@"
no-jq|PATH=@NOJQ@ CI_VARIABLES={"@VAR@":"@JSONV@"}|@VAR@|2|[CI-ERROR-VARIABLES-0023] name="@VAR@";command not found;PATH=@NOJQ@
no-value|-|@NOVAR@|2|[CI-ERROR-VARIABLES-0001] name="@NOVAR@"
CASES
}

# What: bake-check per image shape; values never logged.
# Why: build-only vars and the proxy CA stay out of images.
# From: Issue #1683 | PR #1858
@test "bake-check: forbidden env keys and an extra CA fail, values hidden" {
    local case backend envs ca bundle irc rc want bin hook k
    local -A V=(
        [@URL@]="$(_val url)" [@V@]="$(_val name)" [@K@]="$(_val name)" [@M@]="$(_val name)"
        [@B@]="$(_val name)" [@E@]="$(_val name)" [@RAW@]="$(_val name)" [@IMG@]="$(_val host)/$(_val name)@$(_val digest)"
    )
    bin="$(_val path)"
    _tool_stub "${bin}" docker <<'STUB'
case "$1" in
    image) [ "${BK_IRC}" = 0 ] || { echo "${BK_RAW}"; exit 1; }; printf '%b' "${BK_ENV}" ;;
    run) printf '%b' "${BK_BUNDLE}" ;;
esac
STUB
    while IFS='|' read -r case backend envs ca bundle irc rc want; do
        hook=""
        [ "${backend}" = default ] || hook="$(_stub "printf '%b' '${backend}'")"
        [ "${ca}" != - ] || ca=""
        PATH="${bin}:${PATH}" CI_BAKE_INSPECT_CMD="${hook}" PROJECT_SELFHOSTED_PROXY_CA="$(_fill "${ca//;/$'\n'}")" \
            BK_BUNDLE="$(_fill "${bundle}")" BK_IRC="${irc}" BK_RAW="${V[@RAW@]}" BK_ENV="$(_fill "${envs}")" \
            GHCR_USERNAME="$(_val name)" GHCR_TOKEN="$(_val name)" run _ci_bake_check "${V[@IMG@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        for k in @URL@ @V@ @M@ @B@ @E@; do
            [[ "${output}" != *"${V[${k}]}"* ]] || { echo "${case}: value of ${k} logged"; return 1; }
        done
    done <<'CASES'
clean|default|PATH=/usr/bin\nLANG=C\n|-|-|0|0|bake-check result=clean
http-proxy|default|HTTP_PROXY=@URL@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="HTTP_PROXY"
https-proxy-lower|default|https_proxy=@URL@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="https_proxy"
goproxy|default|GOPROXY=@URL@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="GOPROXY"
sccache|default|SCCACHE_@K@=@V@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="SCCACHE_@K@"
ccache|default|CCACHE_@K@=@V@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="CCACHE_@K@"
distcc|default|DISTCC_@K@=@V@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="DISTCC_@K@"
actions|default|ACTIONS_@K@=@V@\n|-|-|0|2|[CI-ERROR-VARIABLES-0006];key="ACTIONS_@K@"
ca-baked|default|PATH=/usr/bin\n|@B@;@M@;@E@|@B@\n@M@\n@E@\n@M@\n|0|2|[CI-ERROR-VARIABLES-0016];extra_ca="2"
ca-not-baked|default|PATH=/usr/bin\n|@B@;@M@;@E@|@B@\n@E@\n|0|0|bake-check result=clean
inspect-fails|default|-|-|-|1|2|[CI-ERROR-VARIABLES-0005];raw:;@RAW@
unknown-line|env PATH=/x\nmystery 1\nextra_ca 0\n|-|-|-|0|2|[CI-ERROR-VARIABLES-0009]
malformed-ca|env PATH=/x\nextra_ca x\n|-|-|-|0|2|[CI-ERROR-VARIABLES-0007]
CASES
}

# What: guard flags a missing file or a non-central id.
# Why: set-runtime provides only the listed mount ids.
# From: Issue #1683 | PR #1858
@test "dockerfile-secret-ids flags a missing file or a foreign id" {
    local df case body rc want root t n=0 sa=""
    root="$(_val path)"
    # What: a copy of every build target's real Dockerfile
    # Why: the check reads files; rows change one copy only
    # From: Issue #1683 | PR #1858
    for t in $(ci_build_targets); do
        df="$(_ci_service_path "${t}" Dockerfile "${root}")"
        mkdir -p "${df%/Dockerfile}"
        cp "$(_ci_service_path "${t}" Dockerfile "")" "${df}"
        n=$(( n + 1 ))
    done
    for t in $(_ci_block_keys services); do
        [ "$(ci_service_field "${t}" build_type)" != apk ] || { sa="${t}"; break; }
    done
    local -A V=([@OK@]="$(_ci_runtime_secret_ids | awk 'NR == 1')" [@BAD@]="$(_val name)"
        [@VAR@]="$(_val var)" [@DIR@]="/$(_val name)" [@IMG@]="$(_val name)" [@SA@]="${sa}" [@N@]="${n}")
    [ -n "${V[@OK@]}" ] && [ -n "${sa}" ] || return 1
    V[@CTX@]="$(ci_service_field "${sa}" context)"
    df="$(_ci_service_path "${sa}" Dockerfile "${root}")"
    while IFS='|' read -r case body rc want; do
        rm -f "${df}"
        [ "${body}" = - ] || printf '%b' "$(_fill "${body}")" > "${df}"
        run ci_cmd_check dockerfile-secret-ids "${root}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
listed|FROM @IMG@\n# RUN --mount=type=secret,id=@BAD@ true\nRUN --mount=type=secret,id=@OK@ --mount=id=@OK@,type=secret \\\n    # --mount=type=secret,id=@BAD@\n    --mount=type=secret,target=@DIR@/@OK@ --mount=type=cache,id=@BAD@ true\n|0|=dockerfile-secret-ids=clean targets=@N@
foreign|FROM @IMG@\nRUN --mount=type=secret,id=@BAD@ true\n|1|[CI-ERROR-CHECK-0156];targets=@N@;@SA@: @CTX@/Dockerfile: mount id '@BAD@'
foreign-dst|FROM @IMG@\nRUN --mount=dst=@DIR@/@BAD@,type=secret true\n|1|[CI-ERROR-CHECK-0156];@SA@: @CTX@/Dockerfile: mount id '@BAD@'
no-id|FROM @IMG@\nRUN --mount=type=secret,env=@VAR@ true\n|1|[CI-ERROR-CHECK-0156];@SA@: @CTX@/Dockerfile: '--mount=type=secret,env=@VAR@' has no id or target
missing|-|1|[CI-ERROR-CHECK-0156];@SA@: no Dockerfile at @CTX@/Dockerfile
CASES
}

# What: each wrapper shape picks its compiler and hosts.
# Why: a wrong dispatch runs the wrong compiler.
# From: Issue #1533 | PR #1858
@test "distcc wrapper dispatches each invocation shape" {
    local d="${BATS_TEST_TMPDIR}/dw" case envs cmd rc want p stub pairs rows
    local -a ev av drivers=()
    local -A V=(
        [@BIN@]="${d}/bin" [@MASQ@]="${d}/masq" [@REAL@]="$(_val name)" [@LCC@]="$(_val name)"
        [@WRAP@]="$(_val name)" [@UNK@]="$(_val name)" [@COPY@]="$(_val name)" [@SRC@]="$(_val name).c"
        [@H1@]="$(_val host)" [@H2@]="$(_val host)" [@PORT@]="$(_val port)" [@N@]="$(_val name)"
        [@N2@]="$(_val name)" [@T@]="$(_val name)" [@VER@]="$(_val int 1 999)"
        [@AWS@]=aws-lc-sys [@AWSU@]=aws_lc_sys
    )
    V[@PUMP@]="DISTCC_HOSTS=${V[@H1@]} INCLUDE_SERVER_PORT=${V[@PORT@]}"
    V[@NOPUMP@]="${V[@PUMP@]} DISTCC_HOSTS_NO_PUMP=${V[@H2@]}"
    V[@ARGS@]="-c ${V[@SRC@]}" V[@ARGV@]="[-c] [${V[@SRC@]}]"
    pairs="$(_ci_build_tools_compilers)" && [ -n "${pairs}" ] || return 1
    V[@D1@]="${pairs%%$'\n'*}"; V[@D1@]="${V[@D1@]#*=}"
    mkdir -p "${V[@BIN@]}" "${V[@MASQ@]}"
    while IFS= read -r p; do drivers+=("${p#*=}=${V[@BIN@]}/${V[@LCC@]}"); done <<< "${pairs}"
    run _ci_rust_distcc_wrapper "${V[@BIN@]}/${V[@REAL@]}" "${V[@BIN@]}/${V[@WRAP@]}" "${V[@MASQ@]}"
    _expect no-driver 2 "[CI-ERROR-RUSTBUILD-0045];raw:;${V[@MASQ@]}" || return 1
    _ci_rust_distcc_wrapper "${V[@BIN@]}/${V[@REAL@]}" "${V[@BIN@]}/${V[@WRAP@]}" "${V[@MASQ@]}" \
        "${drivers[@]}" > "${V[@BIN@]}/${V[@WRAP@]}" || return 1
    stub='#!/bin/sh
printf "%s hosts=%s isp=%s argv:" "${0##*/}" "${DISTCC_HOSTS:-}" "${INCLUDE_SERVER_PORT:-}"
for a in "$@"; do printf " [%s]" "$a"; done; printf "\n"'
    printf '%s\n' "${stub}" > "${V[@BIN@]}/${V[@REAL@]}"
    printf '%s\n' "${stub}" > "${V[@BIN@]}/${V[@LCC@]}"
    chmod +x "${V[@BIN@]}/${V[@WRAP@]}" "${V[@BIN@]}/${V[@REAL@]}" "${V[@BIN@]}/${V[@LCC@]}"
    for p in "${drivers[@]}"; do ln -sf "${V[@BIN@]}/${V[@WRAP@]}" "${V[@MASQ@]}/${p%%=*}"; done
    ln -sf "${V[@BIN@]}/${V[@WRAP@]}" "${V[@BIN@]}/${V[@UNK@]}"
    cp "${V[@BIN@]}/${V[@WRAP@]}" "${V[@MASQ@]}/${V[@COPY@]}"
    rows="$(for p in "${drivers[@]}"; do
        printf 'masq-%s|@PUMP@|@MASQ@/%s @ARGS@|0|=@REAL@ hosts=@H1@ isp=@PORT@ argv: [%s] @ARGV@\n' \
            "${p%%=*}" "${p%%=*}" "${p%%=*}"
    done; cat <<'CASES'
prefix|@PUMP@|@BIN@/@WRAP@ @BIN@/@LCC@ @ARGS@|0|=@REAL@ hosts=@H1@ isp=@PORT@ argv: [@BIN@/@LCC@] @ARGV@
unknown|@PUMP@|@BIN@/@UNK@ @ARGS@|0|[CI-WARN-RUSTBUILD-0017];@REAL@ hosts=@H1@ isp=@PORT@ argv: [@D1@] @ARGV@
loop-link|@PUMP@|@BIN@/@WRAP@ @MASQ@/@D1@ @ARGS@|1|[CI-ERROR-RUSTBUILD-0016]
loop-copy|@PUMP@|@BIN@/@WRAP@ @MASQ@/@COPY@ @ARGS@|1|[CI-ERROR-RUSTBUILD-0016]
loop-self|@PUMP@|@BIN@/@WRAP@ @BIN@/@WRAP@ @ARGS@|1|[CI-ERROR-RUSTBUILD-0016]
aws-out|@NOPUMP@|@MASQ@/@D1@ -I@N@/@AWS@-@VER@/out/@N2@ @ARGS@|0|[CI-INFO-RUSTBUILD-0018] input=@N@/@AWS@-@VER@/out/@N2@;@REAL@ hosts=@H2@ isp= argv: [@D1@] [-I@N@/@AWS@-@VER@/out/@N2@] @ARGV@
aws-generated|@NOPUMP@|@BIN@/@WRAP@ @BIN@/@LCC@ -isystem@N@/@AWSU@/generated @ARGS@|0|[CI-INFO-RUSTBUILD-0018] input=@N@/@AWSU@/generated;@REAL@ hosts=@H2@ isp= argv: [@BIN@/@LCC@] [-isystem@N@/@AWSU@/generated] @ARGV@
aws-build|@NOPUMP@|@MASQ@/@D1@ -I@N@/target/@T@/build/@AWS@-@VER@/@N2@ @ARGS@|0|[CI-INFO-RUSTBUILD-0018];@REAL@ hosts=@H2@ isp= argv: [@D1@]
aws-local-prefix|@PUMP@|@BIN@/@WRAP@ @BIN@/@LCC@ -I@N@/@AWS@-@VER@/out @ARGS@|0|[CI-INFO-RUSTBUILD-0018];[CI-INFO-RUSTBUILD-0019];@LCC@ hosts= isp= argv: [-I@N@/@AWS@-@VER@/out] @ARGV@
aws-local-masq|@PUMP@|@MASQ@/@D1@ -I@N@/@AWS@-@VER@/out @ARGS@|0|[CI-INFO-RUSTBUILD-0018];[CI-INFO-RUSTBUILD-0019];@LCC@ hosts= isp= argv: [-I@N@/@AWS@-@VER@/out] @ARGV@
aws-no-match|@NOPUMP@|@MASQ@/@D1@ -I@N@/@AWS@-@VER@/@N2@ @ARGS@|0|=@REAL@ hosts=@H1@ isp=@PORT@ argv: [@D1@] [-I@N@/@AWS@-@VER@/@N2@] @ARGV@
CASES
)"
    while IFS='|' read -r case envs cmd rc want; do
        read -r -a ev <<< "$(_fill "${envs}")"
        read -r -a av <<< "$(_fill "${cmd}")"
        run env -u DISTCC_HOSTS -u DISTCC_HOSTS_NO_PUMP -u INCLUDE_SERVER_PORT "${ev[@]}" "${av[@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<< "${rows}"
}

# What: set-runtime secrets per config; clear removes them.
# Why: build-only secrets as 0600 mounts; values hidden.
# From: Issue #1683 | PR #1858
@test "set-runtime writes each config's secrets 0600 with values hidden; clear-runtime removes them" {
    local case mode runner url tok sched stoken hosts ca rc want present pol dir id k got
    local -A V=(
        [@U@]="$(_val url)" [@RU@]="$(_val url)" [@T@]="$(_val name)" [@CA@]="$(_val name)"
        [@S@]="$(_val url)" [@ST@]="$(_val name)" [@H1@]="$(_val host)" [@H2@]="$(_val host)" [@BAD@]="$(_val name)"
        [@TCS@]="$(_val int 1 4000000000)"
    )
    _rt_probe() {
        _cache_env_clean
        unset SCCACHE_DIST_SCHEDULER_URL SCCACHE_DIST_AUTH_TOKEN DISTCC_POTENTIAL_HOSTS PROJECT_SELFHOSTED_PROXY_CA CI_VARIABLES
        [ -z "${RT_CIV:-}" ] || export CI_VARIABLES="${RT_CIV}"
        export CI_RUNTIME_SECRET_DIR="$1" SCCACHE_REDIS_MODE="$2"
        export CI_SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE="${RT_TCS:-${V[@TCS@]}}"
        [ "$3" = - ] || export RUNNER_ENVIRONMENT="$3"
        [ "$4" = - ] || export SCCACHE_REDIS_URL="$4"
        [ "$5" = no ] || export ACTIONS_RESULTS_URL="${V[@RU@]}" ACTIONS_RUNTIME_TOKEN="${V[@T@]}"
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
        [ ! -e "${dir}/sccache_redis_url" ] || [ "$(<"${dir}/sccache_redis_url")" = "${V[@U@]}" ] || { echo "${case}: redis url"; return 1; }
        [ ! -e "${dir}/ccache_redis_url" ] || [ "$(<"${dir}/ccache_redis_url")" = "${V[@U@]}" ] || { echo "${case}: ccache url"; return 1; }
        [ ! -e "${dir}/sccache_gha" ] || [ "$(<"${dir}/sccache_gha")" = "ACTIONS_RESULTS_URL=${V[@RU@]}"$'\n'"ACTIONS_RUNTIME_TOKEN=${V[@T@]}" ] \
            || { echo "${case}: gha tokens"; return 1; }
        [ ! -e "${dir}/project_selfhosted_proxy_ca" ] || [ "$(<"${dir}/project_selfhosted_proxy_ca")" = "${V[@CA@]}" ] || { echo "${case}: CA"; return 1; }
        [ ! -e "${dir}/distcc_potential_hosts" ] || [ "$(<"${dir}/distcc_potential_hosts")" = "$(_fill "${hosts}")" ] || { echo "${case}: hosts"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qF "\"${V[@S@]}\"" "${dir}/sccache_dist_config" || { echo "${case}: scheduler"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qF "\"${V[@ST@]}\"" "${dir}/sccache_dist_config" || { echo "${case}: dist token"; return 1; }
        [ ! -e "${dir}/sccache_dist_config" ] || grep -qxF "toolchain_cache_size = ${V[@TCS@]}" "${dir}/sccache_dist_config" \
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
    run _rt_probe "${dir}" optional github-hosted - no "${V[@S@]}" "${V[@ST@]}" - -
    _expect dist-write-fails 2 "[CI-ERROR-VARIABLES-0020];raw:" || return 1
    run _ci_emit_secret_ref "${dir}" "$(_val name)"
    _expect unknown-id 2 "[CI-ERROR-VARIABLES-0014]" || return 1
    dir="$(_val path)"
    RT_TCS="$(_val name)" run _rt_probe "${dir}" optional github-hosted - no "${V[@S@]}" "${V[@ST@]}" - -
    _expect bad-size 2 "[CI-ERROR-VARIABLES-0021]" || return 1
    [ ! -e "${dir}" ] || { echo "bad-size: ${dir} written"; return 1; }
    dir="$(_val path)"
    RT_CIV="$(printf '{"SCCACHE_DIST_SCHEDULER_URL":"%s","DISTCC_POTENTIAL_HOSTS":"%s,cpp"}' "${V[@S@]}" "${V[@H1@]}")" \
        run _rt_probe "${dir}" optional github-hosted - no - "${V[@ST@]}" - -
    _expect ci-variables 0 - || return 1
    grep -qF "\"${V[@S@]}\"" "${dir}/sccache_dist_config" || { echo "ci-variables: scheduler"; return 1; }
    [ "$(<"${dir}/distcc_potential_hosts")" = "${V[@H1@]},cpp" ] || { echo "ci-variables: hosts"; return 1; }
    dir="$(_val path)"
    run _rt_probe "${dir}" optional github-hosted - no - - - -
    CI_RUNTIME_SECRET_DIR="${dir}" run bash "${CI_SH}" variables clear-runtime
    _expect clear 0 "clear-runtime result=cleared" || return 1
    [ ! -e "${dir}" ] || { echo "clear: ${dir} left"; return 1; }
}

# =========================================================
# BUILD-ARGS EMISSION (SOT -> --build-arg)
# =========================================================

@test "build-args map each target, format and platform" {
    # What: row: target, format, platform -> args or id.
    # Why: SOT owns every value; build-args only maps it.
    # From: Issue #1683 | PR #1858
    local case sot target args rc want absent w bti dep verify
    local -a av ws
    local -A V=(
        [@SA@]="$(_val name)" [@SX@]="$(_val name)" [@SM@]="$(_val name)" [@SR@]="$(_val name)" [@SN@]="$(_val name)"
        [@T@]="$(_val name)" [@C@]="$(_val name)" [@CR@]="$(_val name)" [@EXT@]="$(_val name)" [@NOEXT@]="$(_val name)"
        [@IMG@]="$(_val host)/$(_val name)" [@TAG@]="$(_val int 1 9).$(_val int 0 39)"
        [@HEX@]="$(_val digest | cut -d: -f2)" [@XIMG@]="$(_val host)/$(_val name)@$(_val digest)" [@BP@]="$(_val name)"
        [@PA@]="$(_val name)" [@R1@]="$(_val name)" [@R2@]="$(_val name)" [@P1@]="$(_val platform)" [@P2@]="$(_val platform)"
        [@A1@]="$(_val name)" [@A2@]="$(_val name)" [@RT1@]="$(_val name)" [@RT2@]="$(_val name)" [@TR@]="$(_val name)"
        [@H@]="$(_val host)" [@M@]="$(_val name)" [@H2@]="$(_val host)" [@KF@]="$(_val name)" [@KS@]="$(_val name)"
        [@TP@]="$(_val name)" [@BTI@]="$(_val host)/$(_val name)@$(_val digest)"
    )
    V[@K1@]="${V[@P1@]##*/}" V[@K2@]="${V[@P2@]##*/}" V[@EXTU@]="${V[@EXT@]^^}"
    local -A S=([f]="$(_val path)" [g]="$(_val path)" [m]="$(_val path)" [k]="$(_val path)" [s]="${CI_MANIFEST}")
    _fill "$(printf '%s\n' 'image_base:' '  packages: [@BP@, @PA@]' 'base_images:' '  alpine: "@IMG@:@TAG@@sha256:@HEX@"' \
        '  @EXT@: "@XIMG@"' 'platform_arch:' '  @K1@:' '    apk: @A1@' '    rust_target: @RT1@' '  @K2@:' '    apk: @A2@' \
        '    rust_target: @RT2@' 'build_runtime:' '  rust:' '    packages: [@R1@, @R2@]' 'build_identity:' '  rust:' \
        '    inputs: [package_versions]' 'services:' '  @SA@:' '    context: @C@' '    build_type: apk' '    packages: [@PA@]' \
        '    apk_repositories:' '      - @TR@=http://@H@/@ALPINE_BRANCH@/@M@' '    apk_keys:' '      - https://@H2@/@KF@=@KS@' \
        '  @SX@:' '    context: @C@' '    build_type: apk' '    external_image: @EXT@' \
        '  @SM@:' '    context: @C@' '    build_type: apk' '    external_image: @NOEXT@' \
        '  @SR@:' '    context: @C@' '    build_type: rust' '    crate: @CR@' '    packages: [@PA@, @R1@]' \
        '  @SN@:' '    context: @C@' '    build_type: rust' \
        'build_toolchain:' '  @T@:' '    context: @C@' '    build_type: toolchain' '    packages: [@TP@]' \
        '    apk_repositories:' '      - @TR@=http://@H@/@ALPINE_BRANCH@/@M@')" > "${S[f]}"
    grep -v '^  alpine:' "${S[f]}" > "${S[g]}"
    sed "s#^  alpine: .*#  alpine: \"${V[@IMG@]}:$(_val name)@sha256:${V[@HEX@]}\"#" "${S[f]}" > "${S[m]}"
    sed "s#^      - https://${V[@H2@]}/.*#      - \"https://${V[@H2@]}/${V[@KF@]}=${V[@KS@]}#" "${S[f]}" > "${S[k]}"
    # What: pin rows: SOT copy; ARG names from verify.
    # Why: the test must not rebuild the pin naming rule.
    # From: Issue #1683 | PR #1858
    dep="$(_pin_dep)"
    V[@PC@]="$(_pin_consumer)"
    V[@PV@]="$(_ci_block_entry_field external_versions "${dep}" version)"
    V[@SP@]="$(_ci_build_matrix_platforms)"
    V[@SP@]="${V[@SP@]%%$'\n'*}"
    V[@SPA@]="$(_ci_platform_field "${V[@SP@]}" apk "$(_val name)")"
    V[@SPS@]="$(_ci_block_entry_field external_versions "${dep}" "sha256_${V[@SPA@]}")"
    run --separate-stderr bash "${CI_SH}" version verify
    [ "${status}" -eq 0 ] || { echo "version verify rc ${status}: ${output} ${stderr}"; return 1; }
    verify="${output}"
    for w in VERSION ARCH SHA256; do
        V[@${w}@]="$(sed -n "s/^key=${dep}\.consumer\.\([A-Z0-9_]*_${w}\) shape=bare\$/\1/p" <<< "${verify}")"
        V[@${w}@]="${V[@${w}@]%%$'\n'*}"
        [ -n "${V[@${w}@]}" ] || { echo "no ${w} ARG of ${dep} in: ${verify}"; return 1; }
    done
    bti="$(_stub "echo ${V[@BTI@]}")"
    while IFS='|' read -r case sot target args rc want absent; do
        av=(); [ "${args}" = - ] || IFS=';' read -r -a av <<< "$(_fill "${args}")"
        run env CI_MANIFEST="${S[${sot}]}" CI_BUILD_TOOLS_IMAGE_CMD="${bti}" bash "${CI_SH}" build-args "$(_fill "${target}")" "${av[@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${absent}" != - ] || continue
        IFS=';' read -r -a ws <<< "$(_fill "${absent}")"
        for w in "${ws[@]}"; do [[ "${output}" != *"${w}"* ]] || { echo "${case}: has '${w}': ${output}"; return 1; }; done
    done <<'CASES'
apk-flags|f|@SA@|-|0|--build-arg ALPINE_IMAGE=@IMG@:@TAG@@sha256:@HEX@;--build-arg APK_PACKAGES=@BP@ @PA@;--build-arg APK_TAGGED_REPOS=@TR@=http://@H@/v@TAG@/@M@;--build-arg APK_KEYS=https://@H2@/@KF@=@KS@|BUILD_TOOLS_IMAGE;RUST_CRATE;MUSL_TARGET;=@XIMG@
apk-bare|f|@SA@|--bare|0|ALPINE_IMAGE=@IMG@:@TAG@@sha256:@HEX@|--build-arg
external|f|@SX@|--bare|0|ALPINE_IMAGE=;@EXTU@_IMAGE=@XIMG@|-
external-missing|f|@SM@|-|2|[CI-ERROR-BUILDARGS-0007];base_images.@NOEXT@|-
rust|f|@SR@|--bare|0|BUILD_TOOLS_IMAGE=@BTI@;RUST_CRATE=@CR@;APK_PACKAGES=@BP@ @PA@ @R1@ @R2@|MUSL_TARGET
rust-platform-1|f|@SR@|--bare;@P1@|0|MUSL_TARGET=@RT1@|-
rust-platform-2|f|@SR@|--bare;@P2@|0|MUSL_TARGET=@RT2@|-
rust-no-crate|f|@SN@|-|2|[CI-ERROR-BUILDARGS-0014]|RUST_CRATE=
toolchain|f|@T@|-|0|--build-arg ALPINE_IMAGE=@IMG@:@TAG@@sha256:@HEX@;--build-arg APK_PACKAGES=@BP@ @PA@ @TP@;--build-arg APK_TAGGED_REPOS=@TR@=http://@H@/v@TAG@/@M@|BUILD_TOOLS_IMAGE;_VERSION=
no-alpine|g|@SA@|-|2|[CI-ERROR-BUILDARGS-0003]|-
mutable-alpine-tag|m|@SA@|--bare|2|[CI-ERROR-BUILDARGS-0016]|APK_TAGGED_REPOS=
keys-unreadable|k|@SA@|--bare|2|[CI-ERROR-CORE-0108]|APK_KEYS=
pin-no-platform|s|@PC@|-|0|--build-arg @VERSION@=@PV@;_SHA256_|@ARCH@=
pin-platform|s|@PC@|;@SP@|0|--build-arg @ARCH@=@SPA@;--build-arg @SHA256@=@SPS@|@SHA256@_
CASES
    # What: identity sees the image's package list.
    # Why: a package only one of them sees breaks reuse.
    # From: Issue #1683 | PR #1858
    CI_MANIFEST="${S[f]}" CI_APK_RESOLVE_CMD="$(_stub 'echo "pkgs=$3"')" run _ci_identity_pins "${V[@SR@]}" rust "${V[@P1@]}"
    _expect identity-packages 0 "$(_fill 'pkgs=@BP@ @PA@ @R1@ @R2@')" || return 1
    CI_MANIFEST="${S[g]}" run _ci_identity_pins "${V[@SR@]}" rust "${V[@P1@]}"
    _expect identity-no-alpine 2 "$(_fill '[CI-ERROR-IDENTITY-0009] service="@SR@" key="base_images.alpine"')" || return 1
    CI_MANIFEST="${S[g]}" run _ci_apk_repositories "${V[@SA@]}"
    _expect repos-no-alpine 2 "$(_fill '[CI-ERROR-BUILDARGS-0019] target="@SA@" key="base_images.alpine"')" || return 1
}

# What: trap cleans up; a failed step fails, rc is kept.
# Why: cleanup state must survive until the EXIT trap.
# From: Issue #1683 | PR #1858
@test "rust-build EXIT trap stops the pump, drops the CA, keeps rc" {
    local bin log driver ca case main pump cafail rc want
    bin="$(_val path)" log="$(_val path)" driver="$(_val path)" ca="$(_val path)"
    local -A V=([@PB@]="$(_val name)" [@CB@]="$(_val name)" [@RC@]="$(_val int 3 99)")
    mkdir -p "${bin}"
    _tool_stub "${bin}" pump <<'STUB'
printf '%s\n' "${0##*/}${*:+ $*}" >> "${RB_LOG}"
[ -z "${PUMP_FAIL:-}" ] || { echo "${PUMP_FAIL}" >&2; exit 1; }
STUB
    _tool_stub "${bin}" update-ca-certificates <<'STUB'
printf '%s\n' "${0##*/}${*:+ $*}" >> "${RB_LOG}"
[ -z "${CA_FAIL:-}" ] || { echo "${CA_FAIL}" >&2; exit 1; }
STUB
    printf '%s\n' 'source "${CI_SH}"' '_CI_RB_CA_FILE="${CA_FILE}"' 'trap _ci_rust_build_cleanup EXIT' \
        '_CI_RB_DISTCC=1' '_CI_RB_CA=1' 'exit "${MAIN_RC}"' > "${driver}"
    while IFS='|' read -r case main pump cafail rc want; do
        : > "${log}"; : > "${ca}"
        run env PATH="${bin}:${PATH}" RB_LOG="${log}" PUMP_FAIL="$(_fill "${pump}")" \
            CA_FAIL="$(_fill "${cafail}")" CI_SH="${CI_SH}" CA_FILE="${ca}" MAIN_RC="$(_fill "${main}")" \
            bash "${driver}"
        _expect "${case}" "$(_fill "${rc}")" "$(_fill "${want}")" || return 1
        grep -qx 'pump --shutdown' "${log}" || { echo "${case}: pump not stopped"; return 1; }
        grep -qx 'update-ca-certificates' "${log}" || { echo "${case}: trust store not updated"; return 1; }
        [ ! -e "${ca}" ] || { echo "${case}: CA file kept"; return 1; }
    done <<'CASES'
ok|0|||0|-
ca-fail|0||@CB@|1|[CI-ERROR-RUSTBUILD-0008];@CB@
ca-fail-keeps-rc|@RC@||@CB@|@RC@|@CB@
pump-fail|0|@PB@||1|[CI-ERROR-RUSTBUILD-0007];@PB@
CASES
}

# What: wrong rustc host stops; stubs fill only gaps.
# Why: apk Rust has one host std; real sources stay.
# From: Issue #1683 | PR #1858
@test "rust-build fails closed unless MUSL_TARGET is the rustc host" {
    local bin ws m
    bin="$(_val path)" ws="$(_val path)"
    local -A V=(
        [@HA@]="$(_val name)" [@HB@]="$(_val name)" [@SVC@]="$(_val name)" [@CR@]="$(_val name)"
        [@MA@]="$(_val name)" [@MB@]="$(_val name)" [@LIB@]="$(_val name)/$(_val name).rs"
        [@BIN@]="$(_val name)/$(_val name).rs" [@KEEP@]="$(_val name)"
    )
    mkdir -p "${bin}"
    _tool_stub "${bin}" rustc <<'STUB'
printf 'host: %s\n' "${RB_HOST}"
STUB
    PATH="${bin}:${PATH}" RB_HOST="${V[@HA@]}" MUSL_TARGET="${V[@HB@]}" \
        run bash "${CI_SH}" rust-build "${V[@SVC@]}" "${V[@CR@]}"
    _expect host-mismatch 2 "$(_fill '[CI-ERROR-RUSTBUILD-0006] target="@HB@";host: @HA@')" || return 1
    m="$(_val path)"
    CI_MANIFEST="${m}" CI_TOOLCHAIN_COMPILERS="$(_val var)=${V[@CR@]}" PATH="${bin}:${PATH}" \
        RB_HOST="${V[@HA@]}" MUSL_TARGET="${V[@HA@]}" run bash "${CI_SH}" rust-build "${V[@SVC@]}" "${V[@CR@]}"
    _expect driver-missing 2 "$(_fill '[CI-ERROR-RUSTBUILD-0046] driver="@CR@";raw:;PATH=')" || return 1
    mkdir -p "${ws}/${V[@MA@]}/${V[@BIN@]%/*}" "${ws}/${V[@MB@]}"
    printf '[workspace]\nmembers = [\n    "%s",\n    "%s",\n]\n' "${V[@MA@]}" "${V[@MB@]}" > "${ws}/Cargo.toml"
    printf '[lib]\npath = "%s"\n\n[[bin]]\npath = "%s"\n' "${V[@LIB@]}" "${V[@BIN@]}" > "${ws}/${V[@MA@]}/Cargo.toml"
    printf '[[bin]]\npath = "%s"\n' "${V[@BIN@]}" > "${ws}/${V[@MB@]}/Cargo.toml"
    printf '%s\n' "${V[@KEEP@]}" > "${ws}/${V[@MA@]}/${V[@BIN@]}"
    _in_ws() { cd "${ws}" && _ci_rust_member_stubs; }
    run _in_ws
    _expect stubs 0 "$(_fill '=@MA@/@LIB@
@MB@/@BIN@')" || return 1
    [ "$(cat "${ws}/${V[@MA@]}/${V[@BIN@]}")" = "${V[@KEEP@]}" ] || { echo "real source changed"; return 1; }
    [ -e "${ws}/${V[@MA@]}/${V[@LIB@]}" ] && [ ! -s "${ws}/${V[@MA@]}/${V[@LIB@]}" ] || { echo "lib stub not empty"; return 1; }
    [ "$(cat "${ws}/${V[@MB@]}/${V[@BIN@]}")" = 'fn main() {}' ] || { echo "bin stub wrong"; return 1; }
    rm -r "${ws:?}/${V[@MB@]}"
    run _in_ws
    _expect member-missing 2 "$(_fill '[CI-ERROR-RUSTBUILD-0043] member="@MB@"')" || return 1
    printf '[workspace]\n' > "${ws}/Cargo.toml"
    run _in_ws
    _expect no-members 2 '[CI-ERROR-RUSTBUILD-0042]' || return 1
}

# What: cargo stub replays rc|output per call.
# Why: a real error ends at call 1 with its rc kept.
# From: Issue #1683 | PR #1858
@test "rust cargo build degrades only on an accelerator outage" {
    local bin case cc dc wrap steps rc calls want not w
    local -a ws
    bin="$(_val path)" RB_N="$(_val path)" RB_STEPS="$(_val path)" RB_ARGS="$(_val path)"
    export RB_N RB_STEPS RB_ARGS CI_TMPDIR="${BATS_TEST_TMPDIR}"
    local -A V=(
        [@CR@]="$(_val name)" [@TGT@]="$(_val name)" [@J@]="$(_val int 1 64)" [@W@]="$(_val name)"
        [@OK@]="$(_val name)" [@ERR@]="$(_val name)" [@X@]="$(_val name)" [@OFFC@]="$(_val name)"
        [@OFFD@]="$(_val name)" [@RC@]="$(_val int 3 99)"
        [@SCC@]='sccache: error' [@CCE@]='ccache: error' [@DIST@]='failed to distribute'
    )
    mkdir -p "${bin}"
    _tool_stub "${bin}" cargo <<'STUB'
printf '%s\n' "$*" >> "${RB_ARGS}"
n=$(( $(cat "${RB_N}") + 1 )); echo "${n}" > "${RB_N}"
line="$(sed -n "${n}p" "${RB_STEPS}")"
printf '%s\n' "${line#*|}"
exit "${line%%|*}"
STUB
    disable_ccache() { echo "${V[@OFFC@]}"; }
    disable_distcc() { echo "${V[@OFFD@]}"; }
    while IFS='|' read -r case cc dc wrap steps rc calls want not; do
        echo 0 > "${RB_N}"; : > "${RB_ARGS}"
        _fill "${steps}" | tr ';' '\n' | sed 's/~/|/' > "${RB_STEPS}"
        ccache_enabled="${cc}" _CI_RB_DISTCC="${dc}" RUSTC_WRAPPER="$(_fill "${wrap}")" PATH="${bin}:${PATH}" \
            run _ci_rust_cargo_build "${V[@CR@]}" "${V[@TGT@]}" "${V[@J@]}"
        _expect "${case}" "$(_fill "${rc}")" "$(_fill "${want}")" || return 1
        [ "$(cat "${RB_N}")" -eq "${calls}" ] || { echo "${case}: calls $(cat "${RB_N}")"; return 1; }
        [ "$(sed -n 1p "${RB_ARGS}")" = "$(_fill 'build -j @J@ --release --locked --target @TGT@ -p @CR@')" ] \
            || { echo "${case}: argv $(cat "${RB_ARGS}")"; return 1; }
        IFS=',' read -r -a ws <<< "$(_fill "${not}")"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] || [[ "${output}" != *"${w}"* ]] || { echo "${case}: unexpected ${w}: ${output}"; return 1; }
        done
    done <<'CASES'
real-error-all-on|1|1|@W@|@RC@~@ERR@|@RC@|1|@ERR@;[CI-ERROR-RUSTBUILD-0010] rc=@RC@|RUSTBUILD-0011,@OFFC@
ok-first|1|1|@W@|0~@OK@|0|1|=@OK@|-
ccache-outage|1|1|@W@|@RC@~@CCE@ @X@;0~@OK@|0|2|@OFFC@;[CI-WARN-RUSTBUILD-0011];@OK@;[CI-INFO-RUSTBUILD-0009]|@OFFD@
distcc-outage|1|1|@W@|@RC@~@DIST@ @X@;@RC@~@DIST@ @X@;0~@OK@|0|3|@OFFC@;[CI-WARN-RUSTBUILD-0011];@OFFD@;[CI-WARN-RUSTBUILD-0012];@OK@;[CI-INFO-RUSTBUILD-0009]|-
sccache-outage|0|0|@W@|@RC@~@SCC@ @X@;0~@OK@|0|2|[CI-WARN-RUSTBUILD-0013];@OK@;[CI-INFO-RUSTBUILD-0009]|@OFFC@,@OFFD@
outage-then-error|0|0|@W@|@RC@~@SCC@ @X@;@RC@~@ERR@|@RC@|2|[CI-WARN-RUSTBUILD-0013];@ERR@;[CI-ERROR-RUSTBUILD-0010]|-
nothing-left|0|0||@RC@~@SCC@ @X@|@RC@|1|[CI-ERROR-RUSTBUILD-0014] rc=@RC@|-
CASES
}

@test "toolchain packages: image base plus the one toolchain" {
    # What: base first, toolchain own, deduped; else the id.
    # Why: one list rule; no service list leaks into it.
    # From: Issue #1683 | PR #1858
    local case sot rc want base tool
    local -A V=(
        [@T@]="$(_val name)" [@U@]="$(_val name)" [@S@]="$(_val name)"
        [@B@]="$(_val name)" [@TP@]="$(_val name)" [@SP@]="$(_val name)"
    )
    local -A S=([one]="$(_val path)" [two]="$(_val path)" [none]="$(_val path)" [empty]="$(_val path)")
    base="$(printf '%s\n' 'image_base:' '  packages: [@B@]' 'services:' '  @S@:' '    build_type: apk' '    packages: [@SP@]')"
    tool="$(printf '%s\n' 'build_toolchain:' '  @T@:' '    build_type: toolchain' '    packages: [@TP@, @B@]')"
    _fill "${base}"$'\n'"${tool}" > "${S[one]}"
    _fill "${base}"$'\n'"${tool}"$'\n'"$(printf '%s\n' '  @U@:' '    build_type: toolchain' '    packages: [@TP@]')" > "${S[two]}"
    _fill "${base}" > "${S[none]}"
    _fill "$(printf '%s\n' 'build_toolchain:' '  @T@:' '    build_type: toolchain')" > "${S[empty]}"
    CI_MANIFEST="${S[one]}" run _ci_build_tools_packages
    _expect list 0 "=$(printf '%s\n%s' "${V[@B@]}" "${V[@TP@]}")" || return 1
    while IFS='|' read -r case sot rc want; do
        CI_MANIFEST="${S[${sot}]}" run _ci_build_tools_packages
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
two-toolchains|two|2|[CI-ERROR-CORE-0011]
no-toolchain|none|2|[CI-ERROR-CORE-0011]
empty|empty|2|[CI-ERROR-BUILDTOOLS-0006]
CASES
}

@test "build-tools signature: per-arch apk state over SOT args" {
    # What: per-arch apk state + SOT -> signature or its id.
    # Why: only a real toolchain input change moves the id.
    # From: Issue #1683 | PR #1858
    local case sot all last rc check arch arches plats p dep key v base want sig
    local -A sigs=()
    local -A V=([@V1@]="$(_val name)-$(_val semver)-r0" [@V2@]="$(_val name)-$(_val semver)-r0" [@SP@]="   " [@E@]="")
    local -A S=([s]="${CI_MANIFEST}" [p]="$(_val path)" [n]="$(_val path)")
    STUB_DIR="$(_val path)"
    STUB_CALLS="$(_val path)"
    mkdir -p "${STUB_DIR}"
    CI_APK_RESOLVE_CMD="$(_stub 'printf "%s %s\n" "$1" "$2" >> "${STUB_CALLS}"; cat "${STUB_DIR}/$2"')"
    export STUB_DIR STUB_CALLS CI_APK_RESOLVE_CMD
    # What: SOT copies with a moved pin and without alpine.
    # Why: a pin change must move it; no base must stop it.
    # From: Issue #1683 | PR #1858
    dep="$(_pin_dep)"
    plats="$(_ci_build_matrix_platforms)"
    key="sha256_$(_ci_platform_field "${plats%%$'\n'*}" apk "$(_val name)")"
    v="$(_ci_block_entry_field external_versions "${dep}" "${key}")"
    p="$(_val digest)"
    sed "/^    ${key}:/s/${v}/${p#sha256:}/" "${CI_MANIFEST}" > "${S[p]}"
    ! cmp -s "${CI_MANIFEST}" "${S[p]}" || { echo "pin ${dep}.${key} not moved"; return 1; }
    grep -v '^  alpine:' "${CI_MANIFEST}" > "${S[n]}"
    base="$(_ci_block_entry_field base_images "" alpine)"
    want=""
    for p in ${plats}; do want="${want}${base} $(_ci_platform_field "${p}" apk "$(_val name)")"$'\n'; done
    want="$(LC_ALL=C sort -u <<< "${want%$'\n'}")"
    [ "$(wc -l <<< "${want}")" -ge 2 ] || { echo "need two arches: ${want}"; return 1; }
    arches="$(_ci_build_tools_arches)"
    while IFS='|' read -r case sot all last rc check; do
        : > "${STUB_CALLS}"
        for arch in ${arches}; do printf '%s' "$(_fill "${all}")" > "${STUB_DIR}/${arch}"; done
        printf '%s' "$(_fill "${last}")" > "${STUB_DIR}/${arch}"
        CI_MANIFEST="${S[${sot}]}" run _ci_build_tools_resolve_signature
        if [ "${rc}" -ne 0 ]; then
            _expect "${case}" "${rc}" "${check}" || return 1
            [ "${sot}" != n ] || [ ! -s "${STUB_CALLS}" ] || { echo "${case}: resolver ran: $(cat "${STUB_CALLS}")"; return 1; }
            continue
        fi
        _expect "${case}" 0 - || return 1
        sig="${output##*$'\n'}"
        [[ "${sig}" =~ ^[0-9a-f]{64}$ ]] || { echo "${case}: no signature: ${output}"; return 1; }
        [ "$(LC_ALL=C sort "${STUB_CALLS}")" = "${want}" ] || { echo "${case}: resolver calls: $(cat "${STUB_CALLS}")"; return 1; }
        sigs[${case}]="${sig}"
        case "${check}" in
            =*) [ "${sig}" = "${sigs[${check#=}]}" ] || { echo "${case}: differs from ${check#=}"; return 1; } ;;
            !*) [ "${sig}" != "${sigs[${check#!}]}" ] || { echo "${case}: equals ${check#!}"; return 1; } ;;
        esac
    done <<'CASES'
base|s|@V1@|@V1@|0|-
same|s|@V1@|@V1@|0|=base
bump|s|@V2@|@V2@|0|!base
one-arch|s|@V1@|@V2@|0|!base
pin|p|@V1@|@V1@|0|!base
blank|s|@V1@|@SP@|2|[CI-ERROR-BUILDTOOLS-0011]
empty|s|@V1@|@E@|2|[CI-ERROR-BUILDTOOLS-0011]
no-base|n|@V1@|@V1@|2|[CI-ERROR-BUILDTOOLS-0009]
CASES
    for v in "${V[@E@]}" "${V[@SP@]}"; do
        run _ci_build_tools_signature "${v}"
        _expect "state '${v}'" 2 "[CI-ERROR-BUILDTOOLS-0004]" || return 1
    done
}

# What: ref -> channel -> published build-tools digest.
# Why: jobs pin the toolchain by digest (AG-CI-010).
# From: Issue #1683 | PR #1858
@test "build-tools resolve-image: channel per ref, published digest, step output" {
    local case base refname repo out rc want apk
    local -A V=(
        [@OTHER@]="$(_val name)" [@FEAT@]="$(_val name)/$(_val name)" [@OUT@]="$(_val path)"
        [@BADOUT@]="$(_val path)/$(_val name)/$(_val name)" [@REPO@]="$(_val name)/$(_val name)"
    )
    V[@REL@]="$(_ci_release_ref)"
    V[@RELB@]="${V[@REL@]#refs/heads/}"
    V[@CH@]="$(_ci_channels_where ref "${V[@REL@]}")"
    V[@CH@]="${V[@CH@]%%$'\n'*}"
    V[@DFLT@]="$(_ci_block_entry_field release "" default_channel)"
    [ -n "${V[@CH@]}" ] && [ -n "${V[@DFLT@]}" ] || { echo "SOT channel '${V[@CH@]}' default '${V[@DFLT@]}'"; return 1; }
    GHCR_USERNAME="$(_val name)"
    GHCR_TOKEN="$(_val name)"
    export GHCR_USERNAME GHCR_TOKEN
    V[@IMG@]="$(GITHUB_REPOSITORY="${V[@REPO@]}" _ci_build_tools_image)"
    apk="$(_val path)"
    CI_APK_RESOLVE_CMD="$(_stub "touch '${apk}'; exit 1")"
    export CI_APK_RESOLVE_CMD
    _ci_registry_digest() { printf 'sha256:%s\n' "${1##*:}"; }
    while IFS='|' read -r case base refname repo out rc want; do
        [ "${base}" != - ] || base=''
        [ "${refname}" != - ] || refname=''
        [ "${repo}" != - ] || repo=''
        [ "${out}" != - ] || out=''
        [ -z "${out}" ] || [ "${out}" = @BADOUT@ ] || : > "$(_fill "${out}")"
        GITHUB_BASE_REF="$(_fill "${base}")" GITHUB_REF_NAME="$(_fill "${refname}")" GITHUB_REPOSITORY="$(_fill "${repo}")" \
            GITHUB_OUTPUT="$(_fill "${out}")" run _ci_build_tools_resolve_image
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ ! -e "${apk}" ] || { echo "${case}: apk resolver ran"; return 1; }
        [ "${out}" != @OUT@ ] || grep -qxF -- "$(_fill 'image=@IMG@@sha256:@CH@')" "${V[@OUT@]}" \
            || { echo "${case}: step output: $(cat "${V[@OUT@]}")"; return 1; }
    done <<'CASES'
release-ref|@RELB@|-|@REPO@|-|0|@IMG@@sha256:@CH@
other-ref|@OTHER@|-|@REPO@|-|0|@IMG@@sha256:@DFLT@
no-base-ref|-|@FEAT@|@REPO@|-|0|@IMG@@sha256:@DFLT@
step-output|@RELB@|-|@REPO@|@OUT@|0|@IMG@@sha256:@CH@
output-unwritable|@RELB@|-|@REPO@|@BADOUT@|2|[CI-ERROR-BUILDTOOLS-0023] file="@BADOUT@"
repo-unset|@RELB@|-|-|-|2|[CI-ERROR-CORE-0128]
CASES
}

@test "apk resolver: per-arch root with SOT repos, keys and proxy names" {
    # What: arch, packages, repos, keys, proxy names reach apk.
    # Why: a foreign arch resolves only with its own db and keys.
    # From: Issue #1683 | PR #1858
    local bin argv n v p1 p2 v1 v2 key sha b64 bad
    local -a px=(HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)
    local -A V=(
        [@IMG@]="$(_val host)/$(_val name):$(_val semver)" [@ARCH@]="$(_val name)"
        [@REPOS@]="$(_val name)=$(_val url)/$(_val name)" [@KURL@]="$(_val url)/$(_val name).pub"
    )
    bin="$(_val path)"
    p1="a$(_val name)"
    p2="b$(_val name)"
    v1="$(_val semver)-r0"
    v2="$(_val semver)-r1"
    key="$(_val path)"
    DOCKER_LOG="$(_val path)"
    STUB_OUT="$(printf '(1/2) Installing %s (%s)\n(2/2) Installing %s (%s)' "${p2}" "${v2}" "${p1}" "${v1}")"
    CI_APK_RESOLVE_CMD=''
    CI_RETRY_BACKOFF_BASE_SECONDS=0
    export DOCKER_LOG STUB_OUT CI_APK_RESOLVE_CMD CI_RETRY_BACKOFF_BASE_SECONDS
    _tool_stub "${bin}" docker <<'SH'
printf '%s\n' "${*//$'\n'/ }" >> "${DOCKER_LOG}"
if [ -n "${STUB_FAIL:-}" ]; then printf 'ERROR: unable to select packages:\n  %s (no such package)\n' "${STUB_FAIL}"; exit 1; fi
printf '%s\n' "${STUB_OUT}"
SH
    unset "${px[@]}"
    : > "${DOCKER_LOG}"
    PATH="${bin}:${PATH}" run _ci_apk_resolve "${V[@IMG@]}" "${V[@ARCH@]}" "${p1} ${p2}" "${V[@REPOS@]}"
    _expect resolve 0 "=${p1}-${v1} ${p2}-${v2} " || return 1
    argv="$(cat "${DOCKER_LOG}")"
    for v in "-e ARCH=${V[@ARCH@]} " "-e PKGS=${p1} ${p2} " "-e REPOS=${V[@REPOS@]} " " ${V[@IMG@]} sh -c " --initdb --root --keys-dir; do
        [[ "${argv}" == *"${v}"* ]] || { echo "resolve: no '${v}' in: ${argv}"; return 1; }
    done
    for n in "${px[@]}"; do [[ "${argv}" != *"-e ${n} "* ]] || { echo "unset ${n} passed: ${argv}"; return 1; }; done
    # What: each set proxy name passes; its value stays off argv.
    # Why: a proxy URL may carry credentials.
    # From: Issue #1683 | PR #1858
    for n in "${px[@]}"; do v="$(_val url)"; export "${n}=${v}"; done
    : > "${DOCKER_LOG}"
    PATH="${bin}:${PATH}" run _ci_apk_resolve "${V[@IMG@]}" "${V[@ARCH@]}" "${p1}"
    _expect proxy 0 - || return 1
    argv="$(cat "${DOCKER_LOG}")"
    for n in "${px[@]}"; do
        [[ "${argv}" == *"-e ${n} "* && "${argv}" != *"${!n}"* ]] || { echo "proxy ${n}: ${argv}"; return 1; }
    done
    unset "${px[@]}"
    : > "${DOCKER_LOG}"
    STUB_FAIL="${p1}" PATH="${bin}:${PATH}" run _ci_apk_resolve "${V[@IMG@]}" "${V[@ARCH@]}" "${p1}"
    _expect permanent-failure 2 "[CI-ERROR-BUILDTOOLS-0020] arch=\"${V[@ARCH@]}\";unable to select packages;${p1}" || return 1
    [ "$(wc -l < "${DOCKER_LOG}")" -eq 1 ] || { echo "a permanent failure was retried: $(cat "${DOCKER_LOG}")"; return 1; }
    # What: SOT keys reach apk as base64; a bad pin stops first.
    # Why: a tagged repo resolves only with its pinned key.
    # From: Issue #1683 | PR #1858
    _val name > "${key}"
    sha="$(sha256sum "${key}")"
    sha="${sha%% *}"
    b64="$(base64 -w0 "${key}")"
    bad="$(_val digest)"
    CI_HTTP_DOWNLOAD_CMD="$(_stub "cp '${key}' \"\$2\"")"
    export CI_HTTP_DOWNLOAD_CMD
    : > "${DOCKER_LOG}"
    PATH="${bin}:${PATH}" run _ci_apk_resolve "${V[@IMG@]}" "${V[@ARCH@]}" "${p1}" "${V[@REPOS@]}" "${V[@KURL@]}=${sha}"
    _expect key 0 - || return 1
    grep -qF -- "-e KEYS=${V[@KURL@]##*/}=${b64} " "${DOCKER_LOG}" || { echo "key: $(cat "${DOCKER_LOG}")"; return 1; }
    : > "${DOCKER_LOG}"
    PATH="${bin}:${PATH}" run _ci_apk_resolve "${V[@IMG@]}" "${V[@ARCH@]}" "${p1}" "${V[@REPOS@]}" "${V[@KURL@]}=${bad#sha256:}"
    _expect bad-key-pin 2 "[CI-ERROR-FETCH-0003]" || return 1
    [ ! -s "${DOCKER_LOG}" ] || { echo "docker ran on a bad key pin: $(cat "${DOCKER_LOG}")"; return 1; }
}

@test "oci labels: provenance from the SOT and the run env" {
    # What: OCI labels from SOT pins, repo and commit env.
    # Why: provenance is set once, not per Dockerfile.
    # From: Issue #1683 | PR #1858
    local m nobase want got
    local -A V=(
        [@S@]="$(_val name)" [@FB@]="$(_val name)" [@LIC@]="$(_val name)" [@BDIG@]="$(_val digest)"
        [@BIMG@]="$(_val host)/$(_val name):$(_val semver)" [@OWN@]="$(_val name)" [@REPO@]="$(_val name)"
        [@SRV@]="$(_val url)" [@SHA@]="$(_val sha)"
    )
    m="$(_val path)"
    nobase="$(_val path)"
    _fill "$(printf '%s\n' 'release:' '  license: @LIC@' 'base_images:' '  @FB@: "@BIMG@@@BDIG@"' \
        'services:' '  @S@:' '    final_base: @FB@')" > "${m}"
    grep -v "^  ${V[@FB@]}:" "${m}" > "${nobase}"
    want="$(_fill "$(printf 'org.opencontainers.image.%s\n' 'revision=@SHA@' 'version=@SHA@' \
        'source=@SRV@/@OWN@/@REPO@' 'url=@SRV@/@OWN@/@REPO@' 'documentation=@SRV@/@OWN@/@REPO@' 'licenses=@LIC@' \
        'vendor=@OWN@' 'title=@S@' 'description=@REPO@ @S@ image' 'base.name=@BIMG@' 'base.digest=@BDIG@')")"
    CI_MANIFEST="${m}" GITHUB_SHA="${V[@SHA@]}" GITHUB_SERVER_URL="${V[@SRV@]}" GITHUB_REPOSITORY="${V[@OWN@]}/${V[@REPO@]}" \
        run _ci_oci_labels "${V[@S@]}"
    _expect labels 0 - || return 1
    [[ "${output%%$'\n'*}" =~ ^org\.opencontainers\.image\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || { echo "created: ${output}"; return 1; }
    got="${output#*$'\n'}"
    [ "${got}" = "${want}" ] || { echo "labels: ${got}"; echo "want: ${want}"; return 1; }
    CI_MANIFEST="${m}" GITHUB_SHA='' GITHUB_SERVER_URL="${V[@SRV@]}" GITHUB_REPOSITORY="${V[@OWN@]}/${V[@REPO@]}" \
        run _ci_oci_labels "${V[@S@]}"
    _expect no-sha 0 - || return 1
    [[ "${output}" != *"image.revision="* && "${output}" != *"image.version="* ]] || { echo "no-sha: ${output}"; return 1; }
    CI_MANIFEST="${nobase}" GITHUB_SHA="${V[@SHA@]}" GITHUB_SERVER_URL="${V[@SRV@]}" GITHUB_REPOSITORY="${V[@OWN@]}/${V[@REPO@]}" \
        run _ci_oci_labels "${V[@S@]}"
    _expect no-base 2 "$(_fill '[CI-ERROR-BUILD-0014] service="@S@" key="base_images.@FB@"')" || return 1
}

@test "repo-scanning checks fail closed outside a git repo" {
    # What: failed git ls-files gives CHECK-0071, not clean.
    # Why: an empty file list must not pass every check.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}/nogit" c
    mkdir -p "${d}"
    for c in line-endings file-headers language-policy executable-bits; do
        run bash -c "cd '${d}' && GIT_CEILING_DIRECTORIES='${BATS_TEST_TMPDIR}' bash '${CI_SH}' check ${c}"
        [ "${status}" -eq 2 ] || { echo "want rc2: ${c} -> ${status}"; false; }
        [[ "${output}" == *"CI-ERROR-CHECK-0071"* ]]
        [[ "${output}" == *"site="* ]]
        [[ "${output}" == *"not a git repository"* ]]
        [[ "${output}" != *"=clean"* ]]
    done
}

@test "check line-endings passes LF, fails CRLF via ci.sh" {
    # What: ci.sh owns the LF invariant; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf 'a\nb\n' > "${BATS_TEST_TMPDIR}/lf.txt"
    run bash "${CI_SH}" check line-endings "${BATS_TEST_TMPDIR}/lf.txt"
    [ "${status}" -eq 0 ]
    printf 'a\r\nb\r\n' > "${BATS_TEST_TMPDIR}/crlf.txt"
    run bash "${CI_SH}" check line-endings "${BATS_TEST_TMPDIR}/crlf.txt"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0002"* ]]
}

@test "check file-headers passes canonical, fails missing via ci.sh" {
    # What: ci.sh owns the header contract; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n' > "${BATS_TEST_TMPDIR}/good.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/good.sh"
    [ "${status}" -eq 0 ]
    printf '#!/usr/bin/env bash\necho hi\n' > "${BATS_TEST_TMPDIR}/bad.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/bad.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0003"* ]]
    # What: a headerless file is exempt only if SOT-listed.
    # Why: path exemptions are SOT data, not ci.sh literals.
    # From: Issue #1683 | PR #1858
    mkdir -p "${BATS_TEST_TMPDIR}/x/services/dns"
    printf 'CREATE TABLE t (a int);\n' > "${BATS_TEST_TMPDIR}/x/services/dns/schema.sqlite3.sql"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/x/services/dns/schema.sqlite3.sql"
    [ "${status}" -eq 0 ] || { echo "listed: ${output}"; return 1; }
    grep -v 'schema.sqlite3.sql' "${CI_MANIFEST}" > "${BATS_TEST_TMPDIR}/hdr.yml"
    CI_MANIFEST="${BATS_TEST_TMPDIR}/hdr.yml" run bash "${CI_SH}" check file-headers \
        "${BATS_TEST_TMPDIR}/x/services/dns/schema.sqlite3.sql"
    [ "${status}" -ne 0 ] || { echo "unlisted passed: ${output}"; return 1; }
    # What: only the root .env is header-exempt.
    # Why: AG-HDR-007 keeps nested .env files in scope.
    # From: Issue #1683 | PR #1858
    mkdir -p "${BATS_TEST_TMPDIR}/x/deploy/prod"
    printf 'A=1\n' > "${BATS_TEST_TMPDIR}/x/.env"
    printf 'A=1\n' > "${BATS_TEST_TMPDIR}/x/deploy/prod/.env"
    cd "${BATS_TEST_TMPDIR}/x"
    run bash "${CI_SH}" check file-headers .env
    [ "${status}" -eq 0 ] || { echo "root .env: ${output}"; return 1; }
    run bash "${CI_SH}" check file-headers deploy/prod/.env
    [ "${status}" -ne 0 ] || { echo "nested .env passed: ${output}"; return 1; }
    [[ "${output}" == *"CI-ERROR-CHECK-0003"* ]]
}

@test "check file-headers fails an extension with no native syntax" {
    # What: a file type _ci_header_expected has no case for.
    # Why: distinct from a missing header on a known type.
    # From: Issue #1683 | PR #1858
    printf 'whatever\n' > "${BATS_TEST_TMPDIR}/weird.xyz"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/weird.xyz"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no native header syntax"* ]]
}

@test "check file-headers fails a legacy lowercase header mention" {
    # What: canonical header, plus a stray legacy mention.
    # Why: the lc>0 branch had zero test coverage before.
    # From: Issue #1683 | PR #1858
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\n' \
        > "${BATS_TEST_TMPDIR}/legacy.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/legacy.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"legacy lowercase header present"* ]]
}

@test "check file-headers accepts canonical headers across comment syntaxes" {
    # What: Multi-syntax (bash/lua/css/rust) headers.
    # Why: Absorbs per-format header coverage.
    # From: Issue #1683 | PR #1858
    local h='# LanCache-NG (https://github.com/wiki-mod/lancache-ng)'
    local s='# SPDX-License-Identifier: AGPL-3.0-or-later'
    printf '#!/usr/bin/env bash\n%s\n%s\necho hi\n' "${h}" "${s}" > "${BATS_TEST_TMPDIR}/a.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.sh"; [ "${status}" -eq 0 ]
    printf '\n-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n-- SPDX-License-Identifier: AGPL-3.0-or-later\nreturn true\n' > "${BATS_TEST_TMPDIR}/a.lua"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.lua"; [ "${status}" -eq 0 ]
    printf '\n/* LanCache-NG (https://github.com/wiki-mod/lancache-ng) */\n/* SPDX-License-Identifier: AGPL-3.0-or-later */\nbody {}\n' > "${BATS_TEST_TMPDIR}/a.css"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.css"; [ "${status}" -eq 0 ]
    printf '//!\n//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n//! SPDX-License-Identifier: AGPL-3.0-or-later\nfn main() {}\n' > "${BATS_TEST_TMPDIR}/a.rs"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.rs"; [ "${status}" -eq 0 ]
    printf '# hello\n' > "${BATS_TEST_TMPDIR}/a.md"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.md"; [ "${status}" -eq 0 ]
}

@test "check file-headers rejects layout violations" {
    # What: Swapped/duplicate/no-blank/embedded SPDX.
    # Why: Absorbs layout contract rejections.
    # From: Issue #1683 | PR #1858
    printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "${BATS_TEST_TMPDIR}/sw.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/sw.sh"; [ "${status}" -ne 0 ]
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "${BATS_TEST_TMPDIR}/dup.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/dup.sh"; [ "${status}" -ne 0 ]; [[ "${output}" == *"count"* ]]
    printf '# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nkey: value\n' > "${BATS_TEST_TMPDIR}/nb.yml"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/nb.yml"; [ "${status}" -ne 0 ]
    printf '\n// LanCache-NG (https://github.com/wiki-mod/lancache-ng)\nconst license = "SPDX-License-Identifier: AGPL-3.0-or-later";\n' > "${BATS_TEST_TMPDIR}/emb.js"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/emb.js"; [ "${status}" -ne 0 ]
}

@test "check file-headers handles Tera and Docker parser-directive cases" {
    # What: Tera/Docker parser-directive edge cases.
    # Why: Absorbs line-1-marker edge coverage.
    # From: Issue #1683 | PR #1858
    local t="${BATS_TEST_TMPDIR}/services/ui/src/templates"; mkdir -p "${t}"
    printf '%s\n' '' '{# LanCache-NG (https://github.com/wiki-mod/lancache-ng) #}' '{# SPDX-License-Identifier: AGPL-3.0-or-later #}' '{% extends "base.html" %}' > "${t}/ok.html"
    run bash -c "cd '${BATS_TEST_TMPDIR}' && bash '${CI_SH}' check file-headers services/ui/src/templates/ok.html"; [ "${status}" -eq 0 ]
    printf '# syntax=docker/dockerfile:1\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "${BATS_TEST_TMPDIR}/Dockerfile"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/Dockerfile"; [ "${status}" -eq 0 ]
    printf '# syntax=docker/dockerfile:1\n# escape=\140\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "${BATS_TEST_TMPDIR}/Dockerfile"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/Dockerfile"; [ "${status}" -ne 0 ]
}

@test "check comment-length without files scans the whole repo" {
    # What: no file args means every tracked file, not none.
    # Why: an empty scan would report clean on any repo.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${r}"
    printf '# What: %s\n' "$(printf 'x%.0s' {1..80})" > "${r}/a.sh"
    git -C "${r}" init -q && git -C "${r}" add -A
    cd "${r}"
    run bash "${CI_SH}" check comment-length
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"a.sh:1:"* ]]
    [[ "${output}" == *'[CI-ERROR-CHECK-0128] files=1 scanned=1'* ]]
    # What: a failing scan is rc 2 + CHECK-0129, no finding.
    # Why: a read error is no comment violation.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/abin"; mkdir -p "${bin}"
    AWK_REAL="$(type -P awk)"; export AWK_REAL
    # What: the stub fails the comment scan only.
    # Why: the exempt list is read with awk before the scan.
    # From: Issue #1683 | PR #1858
    _tool_stub "${bin}" awk <<'STUB'
case " $* " in *" style="*) echo "awk: fatal: cannot open file for reading" >&2; exit 2 ;; esac
exec "${AWK_REAL:?}" "$@"
STUB
    PATH="${bin}:${PATH}" run bash "${CI_SH}" check comment-length a.sh
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-CHECK-0129] file="a.sh" rc=2'* ]]
    [[ "${output}" == *"cannot open file"* ]]
    [[ "${output}" != *"CHECK-0128"* ]]
}

@test "check comment-length flags oversize, story-run, refs, From form" {
    # What: ci.sh owns AG-CODE-012 limits; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf '# What: ok short line.\n# Why: also fine here.\n' > "${BATS_TEST_TMPDIR}/ok.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/ok.sh"
    [ "${status}" -eq 0 ]
    printf '# What: %s\n' "$(printf 'x%.0s' $(seq 1 80))" > "${BATS_TEST_TMPDIR}/long.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/long.sh"
    [ "${status}" -ne 0 ]
    printf '# one\n# two\n# three\n# four\n' > "${BATS_TEST_TMPDIR}/story.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/story.sh"
    [ "${status}" -ne 0 ]
    printf '# What: does a thing for #1683\n# Why: a real reason\n' > "${BATS_TEST_TMPDIR}/ref.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/ref.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"ref in What/Why"* ]]
    local from
    for from in 'Issue #1' 'PR #2' 'Issue #1 | PR #2'; do
        printf '# What: a\n# Why: b\n# From: %s\n' "${from}" > "${BATS_TEST_TMPDIR}/f.sh"
        run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/f.sh"
        [ "${status}" -eq 0 ]
    done
    for from in 'Issue #1 | Issue #3' 'Issue #1 | PR #2 (note)' 'PR #2 | PR #4'; do
        printf '# What: a\n# Why: b\n# From: %s\n' "${from}" > "${BATS_TEST_TMPDIR}/f.sh"
        run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/f.sh"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"one Issue and one PR only"* ]]
    done
}

@test "check comment-length reads each file type's own grammar" {
    # What: per row: file type, content, rc, output part.
    # Why: a comment counts only under its own grammar.
    # From: Issue #1683 | PR #1858
    local t="${BATS_TEST_TMPDIR}" case ext body rc want h x70 f
    h='//!\n//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n//! SPDX-License-Identifier: AGPL-3.0-or-later\n'
    x70="$(printf 'x%.0s' $(seq 1 70))"
    mkdir -p "${t}/services/ui/src/templates"
    while IFS='|' read -r case ext body rc want; do
        body="${body//HDR/${h}}"; body="${body//X70/${x70}}"; body="${body//PIPE/|}"
        f="${t}/${case}.${ext}"
        [ "${ext}" != tpl ] || f="${t}/services/ui/src/templates/${case}.html"
        printf '%b' "${body}" > "${f}"
        run bash "${CI_SH}" check comment-length "${f}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [ "${want}" = - ] || [[ "${output}" == *"${want}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
rs-header|rs|HDR//! What: a\n//! Why: b\nfn main() {}\n|0|-
rs-header-gap|rs|HDR//!\n//! What: a\n//! Why: b\n//! From: Issue #1\nfn main() {}\n|1|story-telling block (4 lines)
rs-attrs|rs|#[derive(Debug)]\n#[allow(dead_code)]\n#[cfg(test)]\n#[inline]\nfn f() {}\n|0|-
rs-line-run|rs|// a\n// b\n// c\n// d\nfn f() {}\n|1|story-telling block (4 lines)
rs-doc-run|rs|/// a\n/// b\n/// c\n/// d\nfn f() {}\n|1|story-telling block (4 lines)
rs-long|rs|// What: X70\nfn f() {}\n|1|chars (max 60)
rs-raw|rs|const S: &str = r#"\n// What: X70\n// a\n// b\n// c\n"#;\n|0|-
rs-byte-raw|rs|const S: &[u8] = br##"\n// a\n// b\n// c\n// d\n"##;\n|0|-
rs-string|rs|const S: &str = "\n// a\n// b\n// c\n// d\n";\n|0|-
rs-char|rs|const Q: char = '"'; // tail\n// a\n// b\n// c\n// d\n|1|story-telling block (4 lines)
rs-lifetime|rs|fn f<'a>(x: &'a str) -> &'a str { x }\n// a\n// b\n// c\n// d\n|1|story-telling block (4 lines)
rs-raw-ident|rs|let r#type = 1; // x\n// a\n// b\n// c\n// d\n|1|story-telling block (4 lines)
rs-nested|rs|/* a /* b */ c\n d\n e\n f */\nfn f() {}\n|1|story-telling block (4 lines)
rs-block-fields|rs|/* What: a */\n/* Why: b */\nfn f() {}\n|0|-
rs-block-long|rs|/*\n * What: X70\n */\nfn f() {}\n|1|chars (max 60)
lua-header|lua|\n-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n-- SPDX-License-Identifier: AGPL-3.0-or-later\n-- What: a\n-- Why: b\nreturn 1\n|0|-
lua-run|lua|-- a\n-- b\n-- c\n-- d\nreturn 1\n|1|story-telling block (4 lines)
lua-quote|lua|local q = '"' -- tail\n-- a\n-- b\n-- c\n-- d\n|1|story-telling block (4 lines)
lua-long-str|lua|local s = [==[\n-- a\n-- b\n-- c\n-- d\n]==]\n|0|-
lua-long-cmt|lua|--[==[\n a\n b\n c\n]==]\nreturn 1\n|1|story-telling block (5 lines)
lua-long|lua|-- What: X70\nreturn 1\n|1|chars (max 60)
css-fields|css|/* What: a */\n/* Why: b */\nbody {}\n|0|-
css-run|css|/*\n a\n b\n c\n*/\nbody {}\n|1|story-telling block (5 lines)
css-string|css|a { content: "/*"; }\nb {}\nc {}\nd {}\ne {}\n|0|-
css-url|css|a { background: url(x/*y); }\nb {}\nc {}\nd {}\ne {}\n|0|-
js-run|js|// a\n// b\n// c\n// d\nvar x;\n|1|story-telling block (4 lines)
js-string|js|var s = "/*";\nvar a;\nvar b;\nvar c;\nvar d;\n|0|-
js-regex|js|var r = /\/\*/;\nvar a;\nvar b;\nvar c;\nvar d;\n|0|-
js-template|js|var t = `\n// a\n// b\n// c\n// d\n`;\n|0|-
html-run|html|<!--\n a\n b\n c\n-->\n<p>x</p>\n|1|story-telling block (5 lines)
html-attr|html|<a title="<!--">x</a>\n<p>a</p>\n<p>b</p>\n<p>c</p>\n<p>d</p>\n|0|-
html-script|html|<script>\nvar s = "</p>";\n// a\n// b\n// c\n// d\n</script>\n|1|story-telling block (4 lines)
html-style|html|<style>\n/* What: X70 */\n</style>\n|1|chars (max 60)
tera-run|tpl|{#\n a\n b\n c\n#}\n<p>x</p>\n|1|story-telling block (5 lines)
tera-fields|tpl|{# What: a #}\n{# Why: b #}\n<p>x</p>\n|0|-
tera-raw|tpl|{% raw %}\n{# a\n b\n c\n d #}\n{% endraw %}\n|0|-
tera-html|tpl|<p title="{{ x }}">y</p>\n<!-- What: X70 -->\n|1|chars (max 60)
yaml-block|yml|run: PIPE\n  # a\n  # b\n  # c\n  # d\n|0|-
sh-heredoc|sh|cat <<'EOF'\n# a\n# b\n# c\n# d\nEOF\n|0|-
sh-herestring|sh|grep -x a <<< "EOF"\n# a\n# b\n# c\n# d\n|1|story-telling block (4 lines)
sh-quoted|sh|echo "cat <<EOF"\n# a\n# b\n# c\n# d\n|1|story-telling block (4 lines)
sh-shift|sh|x=$(( 1 << y ))\n# a\n# b\n# c\n# d\n|1|story-telling block (4 lines)
sh-bs-delim|sh|cat <<\\EOF\n# a\n# b\n# c\n# d\nEOF\n|0|-
md-heading|md|# a\n# b\n# c\n# d\n|0|-
unknown|xyz|# a\n# b\n# c\n# d\n|1|[CI-ERROR-CHECK-0153] files=1
CASES
}

@test "diff-scoped checks skip a deleted path visibly, check the rest" {
    # What: a listed path not in the tree is skipped, noted.
    # Why: deleted files hold no content; skip is visible.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}"
    printf '# What: ok short line.\n# Why: also fine here.\n' > "${d}/ok.sh"
    printf '# What: %s\n' "$(printf 'x%.0s' $(seq 1 80))" > "${d}/long.sh"
    run bash "${CI_SH}" check comment-length "${d}/ok.sh" "${d}/gone.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-NOTICE-CHECK-0070] skipped=1"* ]]
    run bash "${CI_SH}" check comment-length "${d}/long.sh" "${d}/gone.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"[CI-NOTICE-CHECK-0070] skipped=1"* ]]
}

@test "check deny-short-sha fails every sha-named slice variant" {
    # What: every sha/commit/candidate/revision slice fails.
    # Why: `$` via %s keeps ci.bats itself scan-clean.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/s.sh" slice
    for slice in 'commit:0:7' 'candidate::7' 'revision:0:8' 'SHA::7' \
                 'commit1_sha:0:7' 'base_sha:0:7' 'full_sha:0:length' \
                 'GITHUB_SHA: 0 : 7' 'GITHUB_SHA : : 7' 'COMMIT_SHA::12'; do
        printf 'x="a-%s{%s}"\n' '$' "${slice}" > "${f}"
        run bash "${CI_SH}" check deny-short-sha "${f}"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"CI-ERROR-CHECK-0005"*"s.sh:1"* ]]
    done
}

@test "check-all scope filter keeps only in-scope changed files" {
    # What: .md dropped; .sh fails.
    # Why: changed files are candidates, not check scope.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/scoperepo" bad
    printf -v bad 'x=%s{base_sha:0:7}' '$'
    mkdir -p "${r}/.github/scripts" "${r}/docs"
    git -C "${r}" init -q
    printf '%s\n' "${bad}" > "${r}/docs/a.md"
    printf 'echo ok\n' > "${r}/.github/scripts/s.sh"
    git -C "${r}" add -A
    run bash -c "cd '${r}' && CI_SCAN_SCOPE_FILTER=1 bash '${CI_SH}' check deny-short-sha docs/a.md .github/scripts/s.sh"
    [ "${status}" -eq 0 ]
    printf '%s\n' "${bad}" > "${r}/.github/scripts/s.sh"
    run bash -c "cd '${r}' && CI_SCAN_SCOPE_FILTER=1 bash '${CI_SH}' check deny-short-sha docs/a.md .github/scripts/s.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0005"* ]]
    [[ "${output}" != *"docs/a.md"* ]]
}

@test "check deny-short-sha allows full-SHA refs and git rev-parse --short" {
    # What: Full-SHA and rev-parse --short stay clean.
    # Why: Ban targets bash slices only.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}"
    printf 'full="registry.example.test/${repo}/${svc}:sha-${commit}"\n' > "${d}/full.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/full.sh"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"deny-short-sha=clean"* ]]
    printf 's="$(git rev-parse --short=7 "$c")"\n' > "${d}/revparse.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/revparse.sh"
    [ "${status}" -eq 0 ]
}

@test "check language-policy fails banned ext and inline interpreter" {
    # What: ci.sh owns AG-REL-001; bats calls it.
    # Why: extension ban plus the heredoc foreign-lang gap.
    # From: Issue #1683
    printf 'echo hi\n' > "${BATS_TEST_TMPDIR}/ok.sh"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/ok.sh"
    [ "${status}" -eq 0 ]
    printf 'x = 1\n' > "${BATS_TEST_TMPDIR}/mod.py"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/mod.py"
    [ "${status}" -ne 0 ]
    printf '%s -c "print(1)"\n' python3 > "${BATS_TEST_TMPDIR}/inline.sh"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/inline.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0007"* ]]
}

@test "check language-policy bans JS/TS files but exempts vendored min.js" {
    # What: Absorbs JS/TS extension ban.
    # Why: Authored .js fails; vendored min.js exempt.
    # From: Issue #1683 | PR #1858
    printf 'let x=1\n' > "${BATS_TEST_TMPDIR}/app.js"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/app.js"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0007"* ]]
    printf 'export const x=1\n' > "${BATS_TEST_TMPDIR}/mod.ts"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/mod.ts"
    [ "${status}" -ne 0 ]
    mkdir -p "${BATS_TEST_TMPDIR}/services/ui/src/static"
    printf 'minified\n' > "${BATS_TEST_TMPDIR}/services/ui/src/static/x.min.js"
    run bash -c "cd '${BATS_TEST_TMPDIR}' && bash '${CI_SH}' check language-policy services/ui/src/static/x.min.js"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"language-policy=clean"* ]]
}

@test "check mutable-refs requires a full SHA per external action ref" {
    # What: one uses: shape per row; external needs 40 hex.
    # Why: tags, branches and short SHAs move.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/w.yml" case use want sha
    sha="3d3c42e5aac5ba805825da76410c181273ba90b1"
    while IFS='|' read -r case use want; do
        printf 'jobs:\n  x:\n    steps:\n      %s\n' "${use//@SHA/@${sha}}" > "${f}"
        GITHUB_REPOSITORY=owner/repo run bash "${CI_SH}" check mutable-refs "${f}"
        if [ "${want}" = clean ]; then
            [ "${status}" -eq 0 ] && [[ "${output}" == *"mutable-refs=clean"* ]] || {
                echo "${case}: ${output}"; return 1; }
        else
            [ "${status}" -eq 1 ] && [[ "${output}" == *"CI-ERROR-CHECK-0008"*"action-not-full-sha"* ]] || {
                echo "${case}: ${output}"; return 1; }
        fi
    done <<'ROWS'
full|- uses: foo/bar@SHA|clean
fullcomment|- uses: foo/bar@SHA # v4|clean
quoted|- uses: "foo/bar@SHA"|clean
subpath|- uses: github/codeql-action/init@SHA|clean
local|- uses: ./.github/actions/x|clean
reusable|- uses: ./.github/workflows/r.yml|clean
docker|- uses: docker://alpine@sha256:0123|clean
ownrepo|- uses: owner/repo/.github/workflows/r.yml@current_dev|clean
runtext|- run: echo "uses: foo/bar@v1"|clean
tag|- uses: foo/bar@v4|fail
branch|- uses: foo/bar@main|fail
short|- uses: foo/bar@abc1234|fail
long39|- uses: foo/bar@3d3c42e5aac5ba805825da76410c181273ba90b|fail
anchor|- uses: &co foo/bar@master|fail
quotedtag|- uses: 'foo/bar@v4'|fail
ROWS
    local r="${BATS_TEST_TMPDIR}/mrepo"
    mkdir -p "${r}/.github/actions/x"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: foo/bar@abc1234def\n' > "${r}/.github/actions/x/action.yml"
    ( cd "${r}" && git init -q && git add -A )
    run bash -c "cd '${r}' && bash '${CI_SH}' check mutable-refs"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"action.yml action-not-full-sha"* ]] || { echo "${output}"; return 1; }
}

@test "check mutable-refs fails a floating BUILD_TOOLS_IMAGE default" {
    # What: the img-default-latest yml sub-pattern, unseen.
    # Why: a second violation kind in the same yml branch.
    # From: Issue #1683 | PR #1858
    printf 'env:\n  BUILD_TOOLS_IMAGE=registry.example.test/owner/build-tools:latest\n' \
        > "${BATS_TEST_TMPDIR}/imglatest.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/imglatest.yml"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"img-default-latest"* ]]
    printf "run: grep -F 'ARG BUILD_TOOLS_IMAGE=registry.example.test/x/build-tools:latest' f\n" \
        > "${BATS_TEST_TMPDIR}/greppat.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/greppat.yml"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mutable-refs=clean"* ]]
}

@test "check mutable-refs fails a Dockerfile FROM:latest and untagged FROM" {
    # What: both Dockerfile-side sub-patterns, unseen still.
    # Why: distinct from the yml-side action/@vN case above.
    # From: Issue #1683 | PR #1858
    local d1="${BATS_TEST_TMPDIR}/fromlatest"; mkdir -p "${d1}"
    printf 'FROM alpine:latest\n' > "${d1}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d1}/Dockerfile"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FROM-latest"* ]]
    local d2="${BATS_TEST_TMPDIR}/untagged"; mkdir -p "${d2}"
    printf 'FROM someimage\n' > "${d2}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d2}/Dockerfile"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FROM-untagged"* ]]
}

@test "check mutable-refs maps each # syntax= frontend line" {
    # What: unpinned frontend fails; @sha256 pin passes.
    # Why: a mutable frontend is pulled anew on every build.
    # From: Issue #1683 | PR #1858
    local d name line want n=0
    while IFS='|' read -r name line want; do
        n=$((n + 1)); d="${BATS_TEST_TMPDIR}/syntax${n}"; mkdir -p "${d}"
        printf '%s\nFROM alpine:3.24\n' "${line}" > "${d}/Dockerfile"
        run bash "${CI_SH}" check mutable-refs "${d}/Dockerfile"
        case "${want}" in
            fail) [ "${status}" -eq 1 ] && [[ "${output}" == *"syntax-unpinned"*"${line}"* ]] ;;
            pass) [ "${status}" -eq 0 ] && [[ "${output}" != *"syntax-unpinned"* ]] ;;
        esac || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
major-tag|# syntax=docker/dockerfile:1|fail
spaced|#syntax = docker/dockerfile:1.7|fail
upper|# SYNTAX=docker/dockerfile:1|fail
pinned|# syntax=docker/dockerfile:1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|pass
none|# LanCache-NG header line|pass
CASES
}

@test "check mutable-refs does not flag a real tag as untagged" {
    # What: AG-WF-027: this found a real bug; fixed here.
    # Why: ':' in the untagged charset false-matched 3.24.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}/realtag"; mkdir -p "${d}"
    printf 'FROM alpine:3.24\n' > "${d}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d}/Dockerfile"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"FROM-untagged"* ]]
}

@test "check executable-bits fails a non-755 bare-path script via ci.sh" {
    # What: ci.sh owns the mode check; bats calls it.
    # Why: bare-path scripts must carry the exec bit.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/exr"; mkdir -p "${r}/.githooks"
    git -C "${r}" init -q
    printf '#!/usr/bin/env bash\n' > "${r}/.githooks/pre-commit"
    printf 'FROM scratch\n' > "${r}/Dockerfile"
    git -C "${r}" add .githooks/pre-commit Dockerfile
    run bash -c "cd '${r}' && bash '${CI_SH}' check executable-bits .githooks/pre-commit Dockerfile"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0009"* ]]
    [[ "${output}" != *"Dockerfile: mode"* ]]
    git -C "${r}" update-index --chmod=+x .githooks/pre-commit
    run bash -c "cd '${r}' && bash '${CI_SH}' check executable-bits .githooks/pre-commit Dockerfile"
    [ "${status}" -eq 0 ]
}

@test "check review-chronology fails narration and line-refs, passes prose" {
    # What: narration/line-ref variants fail; prose ok.
    # Why: `r`/`f`/`l` keep ci.bats itself scan-clean.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}" r=review f=fix l=line p
    for p in "found during code ${r} earlier" "fixed it before this ${f} landed" \
             "flagged in ${r} on PR #743" "this is a ${r} finding note" \
             "caught during self-${r} here" "the handler (${l} 42) does it" \
             "revisit this logic (${l} ~890) soon" "the fix is above (see ${l} 42)"; do
        printf '# %s\n' "${p}" > "${d}/bad.sh"
        run bash "${CI_SH}" check review-chronology "${d}/bad.sh"
        [ "${status}" -ne 0 ] || { echo "want fail: ${p}"; false; }
        [[ "${output}" == *"CI-ERROR-CHECK-0080"* ]]
    done
    printf '# noted a %s\n# finding in the code\n' "${r}" > "${d}/bad.sh"
    run bash "${CI_SH}" check review-chronology "${d}/bad.sh"
    [ "${status}" -ne 0 ]
    # What: code lines like --opt or *) are no comments.
    # Why: only the file's own grammar marks a comment.
    # From: Issue #1683 | PR #1858
    printf 'f() {\n    --opt noted a %s\n    *finding) ;;\n}\n' "${r}" > "${d}/code.sh"
    run bash "${CI_SH}" check review-chronology "${d}/code.sh"
    [ "${status}" -eq 0 ] || { echo "code lines joined: ${output}"; false; }
    for p in "a normal current-state comment" "see the manual review section" \
             "runs after this PR merges" "remembered during review to add this" \
             "each line of the config is parsed here"; do
        printf '# %s\n' "${p}" > "${d}/ok.sh"
        run bash "${CI_SH}" check review-chronology "${d}/ok.sh"
        [ "${status}" -eq 0 ] || { echo "want pass: ${p}"; false; }
    done
}

@test "check review-chronology exempts legacy-excluded file types" {
    # What: Legacy-excluded file types (*.md) skip scan.
    # Why: Parity with legacy script's is_excluded().
    # From: Issue #1683
    printf '# %s during code %s earlier.\n' found review > "${BATS_TEST_TMPDIR}/notes.md"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/notes.md"
    [ "${status}" -eq 0 ]
}

@test "check review-chronology CHRONOLOGY_WARN_ONLY downgrades a real violation to exit 0" {
    # What: CHRONOLOGY_WARN_ONLY surfaces but doesn't block.
    # Why: AG-GH-018 transitional warn path.
    # From: Issue #1683
    printf '# %s during code %s earlier.\n' found review > "${BATS_TEST_TMPDIR}/badc.sh"
    run env CHRONOLOGY_WARN_ONLY=1 bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/badc.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"review-chronology=warn"* ]]
    [[ "${output}" == *"CI-WARN-CHECK-0079"* ]]
}

@test "check review-chronology diff-scoped mode scans only the PR's changed files" {
    # What: CHRONOLOGY_DIFF_BASE_SHA scans changed files.
    # Why: Parity: pre-existing violations don't block.
    # From: Issue #1683
    local bare="${BATS_TEST_TMPDIR}/chrono-origin.git" work="${BATS_TEST_TMPDIR}/chrono-work"
    git init --quiet --bare "${bare}"
    git clone --quiet "${bare}" "${work}"
    (
        cd "${work}" || exit 1
        git config user.email chrono-bats@example.invalid
        git config user.name chrono-bats
        printf '# %s during code %s earlier.\n' found review > pre-existing.sh
        git add pre-existing.sh
        git commit --quiet -m base
        git push --quiet origin HEAD:refs/heads/chrono-base
    )
    cd "${work}"
    local base_sha; base_sha="$(git rev-parse HEAD)"
    printf '# a normal current-state comment.\n' > touched.sh
    git add touched.sh
    git commit --quiet -m "touch an unrelated file"
    local head_sha; head_sha="$(git rev-parse HEAD)"
    run env CHRONOLOGY_DIFF_BASE_SHA="${base_sha}" CHRONOLOGY_DIFF_BASE_REF=chrono-base \
        GITHUB_SHA="${head_sha}" bash "${CI_SH}" check review-chronology
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"review-chronology=clean"* ]]
}

@test "check review-chronology diff-scoped mode fails closed when git diff itself fails" {
    # What: git diff failure returns 2, not empty file list.
    # Why: Capture to file preserves exit; mapfile drops it.
    # From: Issue #1683
    local bare="${BATS_TEST_TMPDIR}/chronofail-origin.git" work="${BATS_TEST_TMPDIR}/chronofail-work"
    git init --quiet --bare "${bare}"
    git clone --quiet "${bare}" "${work}"
    (
        cd "${work}" || exit 1
        git config user.email chrono-bats@example.invalid
        git config user.name chrono-bats
        git commit --quiet --allow-empty -m base
        git push --quiet origin HEAD:refs/heads/chrono-base
    )
    cd "${work}"
    local base_sha; base_sha="$(git rev-parse HEAD)"
    git commit --quiet --allow-empty -m "second commit"
    local head_sha; head_sha="$(git rev-parse HEAD)"
    local real_git; real_git="$(command -v git)"
    local stub_bin="${BATS_TEST_TMPDIR}/stubbin"
    mkdir -p "${stub_bin}"
    _tool_stub "${stub_bin}" git <<STUBEOF
if [ "\$1" = "diff" ]; then
    echo "simulated git diff failure" >&2
    exit 128
fi
exec "${real_git}" "\$@"
STUBEOF
    run env PATH="${stub_bin}:${PATH}" CHRONOLOGY_DIFF_BASE_SHA="${base_sha}" \
        CHRONOLOGY_DIFF_BASE_REF=chrono-base GITHUB_SHA="${head_sha}" \
        bash "${CI_SH}" check review-chronology
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"git diff itself failed"* ]]
    [[ "${output}" != *"review-chronology=clean"* ]]
}

@test "check review-chronology dup #N only warns; unlisted files unscanned" {
    # What: dup #N warns; strings/longer numbers pass.
    # Why: a dup ref never blocks; scope is the arg list.
    # From: Issue #1683 | PR #1858
    printf '# From: Issue #887\nlocal x="#887"\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# see also #999 for context\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# unrelated #8871 ticket\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# duplicate ref #887 here\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"CI-WARN-CHECK-0078"* ]]
    [[ "${output}" == *"warn-only, PR #1856"* ]]
    printf '# %s in %s here\n' caught review > "${BATS_TEST_TMPDIR}/dirty.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"
    [[ "${output}" != *"dirty.sh"* ]]
}

@test "check pipefail-early-exit flags grep -q/head, not ||, -eq, sed -n" {
    # What: early-exit consumers fail; lookalikes pass.
    # Why: `||` and a later -eq are no pipe grep option.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/p.sh" g=grep h=head a=awk line
    for line in "x=\"\$(seq 1 9)\"" 'a || grep -q x f' \
                '[ "$(seq 9 | grep -c 3)" -eq 1 ]' 'seq 9 | sed -n "s/3/x/p"' \
                "awk '{print; exit}' <<< \"\$x\"" "seq 9 | awk '{print \$1}'" \
                "a || awk '{exit}' f"; do
        printf 'set -o pipefail\n%s\n' "${line}" > "${f}"
        run bash "${CI_SH}" check pipefail-early-exit "${f}"
        [ "${status}" -eq 0 ]
    done
    for line in "seq 9 | ${g} -q 3" "seq 9 | ${g} -Eiq 3" "seq 9 | ${g} --quiet 3" "seq 9 | ${h} -1" \
                "seq 9 | ${a} '{print; exit}'" "    | ${a} '\$1 == 3 { print; exit 0 }' \\\\"; do
        printf 'set -o pipefail\n%s\n' "${line}" > "${f}"
        run bash "${CI_SH}" check pipefail-early-exit "${f}"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"CI-ERROR-CHECK-0011"* ]]
    done
}

@test "check bats-and-chain flags && assertions without a fallback" {
    # What: [ ] && [ ] fails; || fallback and splits pass.
    # Why: bats ignores a failing first && term mid-test.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/t.bats" line a='&&'
    for line in '    [ 1 -eq 1 ]' "    [ 1 -eq 1 ] ${a} [ 2 -eq 2 ] || { return 1; }" \
                "    [ 1 -eq 1 ] ${a} [ 2 -eq 2 ] \\\\\n        || { return 1; }" \
                "    x=1 ${a} y=2" "    grep -q a f ${a} echo" "    [ -n \"\${x}\" ] ${a} rm -f y" \
                "    [ a = a ] ${a} [ -n b ] ${a} { exit 1; }"; do
        printf '%b\n' "${line}" > "${f}"
        run bash "${CI_SH}" check bats-and-chain "${f}"
        [ "${status}" -eq 0 ] || { echo "pass row: ${line}: ${output}"; return 1; }
    done
    for line in "    [ 1 -eq 1 ] ${a} [ 2 -eq 2 ]" "    [[ x == x ]] ${a} [[ y == y ]]" \
                "    [ 1 -eq 1 ] ${a} [ 2 -eq 2 ] \\\\\n        ${a} [ 3 -eq 3 ]"; do
        printf '%b\n' "${line}" > "${f}"
        run bash "${CI_SH}" check bats-and-chain "${f}"
        [ "${status}" -eq 1 ] || { echo "fail row: ${line}: ${output}"; return 1; }
        [[ "${output}" == *"CI-ERROR-CHECK-0145"*"t.bats: 1: "* ]]
    done
}

@test "check if-without-else-status flags a masked \$? after an else-less if" {
    # What: ci.sh owns the AG-VAL-029 if-status check.
    # Why: else-less if reports 0, masking the real status.
    # From: Issue #1683 | PR #1858
    printf 'if grep -q x f; then STATUS=0; else STATUS=$?; fi\necho ok\n' > "${BATS_TEST_TMPDIR}/okif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/okif.sh"
    [ "${status}" -eq 0 ]
    printf 'if grep -q x f; then\n  :\nfi\nrc=$?\n' > "${BATS_TEST_TMPDIR}/badif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/badif.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0065"* ]]
    printf 'if grep -q x f; then\n  :\nfi\nrc=$? # if-status-safe: not consuming\n' > "${BATS_TEST_TMPDIR}/safeif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/safeif.sh"
    [ "${status}" -eq 0 ]
    printf 'if a; then\n  :\nfi\nb || return "$?"\n' > "${BATS_TEST_TMPDIR}/orif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/orif.sh"
    [ "${status}" -eq 0 ]
    printf 'if a; then\n  :\nfi\nreturn "$?"\n' > "${BATS_TEST_TMPDIR}/retif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/retif.sh"
    [ "${status}" -ne 0 ]
    # What: $? in an `if !` then-branch is always 0.
    # Why: that read made a grep-failure branch dead code.
    # From: Issue #1683 | PR #1858
    printf 'if ! out="$(x)"; then\n  rc=$?\nfi\n' > "${BATS_TEST_TMPDIR}/negif.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/negif.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"negif.sh:2: reads \$? inside 'if ! CMD; then'"* ]]
    printf 'if ! x; then rc=$?; fi\n' > "${BATS_TEST_TMPDIR}/negone.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/negone.sh"
    [ "${status}" -ne 0 ]
    printf 'out="$(x)" || rc=$?\nif ! y; then\n  echo no\nfi\n' > "${BATS_TEST_TMPDIR}/negok.sh"
    run bash "${CI_SH}" check if-without-else-status "${BATS_TEST_TMPDIR}/negok.sh"
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
}

@test "check docker-run-heredoc-stdin flags a heredoc docker run missing -i" {
    # What: ci.sh owns the AG-VAL-029 heredoc-stdin check.
    # Why: unattached stdin reports success.
    # From: Issue #1683 | PR #1858
    printf 'jobs:\n  a:\n    steps:\n      - run: docker run -i img bash -s <<EOF\n' > "${BATS_TEST_TMPDIR}/okhd.yml"
    run bash "${CI_SH}" check docker-run-heredoc-stdin "${BATS_TEST_TMPDIR}/okhd.yml"
    [ "${status}" -eq 0 ]
    printf 'jobs:\n  a:\n    steps:\n      - run: docker run img bash -s <<EOF\n' > "${BATS_TEST_TMPDIR}/badhd.yml"
    run bash "${CI_SH}" check docker-run-heredoc-stdin "${BATS_TEST_TMPDIR}/badhd.yml"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0066"* ]]
    # What: a heredoc with no docker run in view is clean.
    # Why: no match must not end the CLI with a silent rc 1.
    # From: Issue #1683 | PR #1858
    printf 'jobs:\n  a:\n    steps:\n      - run: ssh host bash -s <<EOF\n' > "${BATS_TEST_TMPDIR}/sshhd.yml"
    run bash "${CI_SH}" check docker-run-heredoc-stdin "${BATS_TEST_TMPDIR}/sshhd.yml"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"docker-run-heredoc-stdin=clean"* ]]
}

@test "check setup-prompt-drift flags an uncovered unconditional wizard prompt" {
    # What: ci.sh owns setup.sh/expect-sim drift guard.
    # Why: new unconditional prompt hangs without sim.
    # From: Issue #1176
    local r="${BATS_TEST_TMPDIR}/spd"
    mkdir -p "${r}/scripts/untracked/simulations"
    printf 'case "${1:-install}" in\ninstall|"") ;;\nesac\nask "Username?" "admin"\n' > "${r}/setup.sh"
    printf 'expect_prompt {Username[^\\n]*\\[admin\\]} "x"\n' > "${r}/scripts/untracked/simulations/setup-cli-simulation.sh"
    run bash "${CI_SH}" check setup-prompt-drift "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-prompt-drift=clean sims_checked=1 introspected=0"* ]]
    printf 'ask "NewPrompt?" "y"\n' >> "${r}/setup.sh"
    run bash "${CI_SH}" check setup-prompt-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0084"* ]]
    [[ "${output}" == *"NewPrompt?"* ]]
    # What: an introspection sim counts; it needs the spawn.
    # Why: the clean line names every kind of checked sim.
    # From: Issue #1683 | PR #1858
    local sim="${r}/scripts/untracked/simulations/setup-cli-simulation.sh"
    printf 'build_expect_prompt_block\nspawn bash setup.sh\n' > "${sim}"
    run bash "${CI_SH}" check setup-prompt-drift "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-prompt-drift=clean sims_checked=0 introspected=1"* ]]
    printf 'build_expect_prompt_block\n' > "${sim}"
    run bash "${CI_SH}" check setup-prompt-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0084"* ]]
    [[ "${output}" == *"no 'spawn bash setup.sh'"* ]]
}

@test "check pr-title: SOT types, derived scopes, warn/block/draft modes" {
    # What: grammar + SOT sets; warn default, block, draft.
    # Why: AG-GH-018: one policy owner; warn is the default.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml" t ex
    ex="$(_val name)[bot]"
    printf 'services:\n  svc-a:\n    context: a\nbuild_toolchain:\n  tc-x:\n    context: t\nexternal_services:\n  ext-y:\n    image: i\npr_policy:\n  title_types: [feat, fix, security]\n  title_scopes_extra: [area-z]\n  check_exempt_authors:\n    - %s\n' "${ex}" > "${m}"
    _sot_block ci_variables >> "${m}"
    unset PR_TITLE PR_AUTHOR PR_DRAFT PR_TITLE_LINT_MODE
    for t in "feat(svc-a): x" "fix(tc-x)!: y" "feat(ext-y): x" "feat(area-z): x" \
             "security: z" "feat!: x" $'feat(svc-a): crlf\r'; do
        CI_MANIFEST="${m}" PR_TITLE="${t}" run bash "${CI_SH}" check pr-title
        [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=ok"* ]] || { echo "want ok: ${t}"; false; }
    done
    for t in "feat(bogus): x" "chore(svc-a): x" "not conventional"; do
        CI_MANIFEST="${m}" PR_TITLE="${t}" run bash "${CI_SH}" check pr-title
        [ "${status}" -eq 0 ]; [[ "${output}" == *"CI-ERROR-CHECK-0086"*"pr-title=warn"* ]]
        CI_MANIFEST="${m}" PR_TITLE="${t}" PR_TITLE_LINT_MODE=block run bash "${CI_SH}" check pr-title
        [ "${status}" -eq 1 ]; [[ "${output}" == *"reason=\"PR title convention\""* ]]
        CI_MANIFEST="${m}" PR_TITLE="${t}" PR_TITLE_LINT_MODE=block PR_DRAFT=true run bash "${CI_SH}" check pr-title
        [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=warn-draft"* ]]
    done
    CI_MANIFEST="${m}" PR_TITLE="not conventional" PR_AUTHOR="${ex}" PR_TITLE_LINT_MODE=block run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=skip author=\"${ex}\""* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 2 ]; [[ "${output}" == *"CI-ERROR-CHECK-0012"* ]]
    sed -i '/title_types/d' "${m}"
    CI_MANIFEST="${m}" PR_TITLE="feat: x" run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 2 ]; [[ "${output}" == *"no SOT pr_policy.title_types"* ]]
}

@test "check stable-external-images: literal hosts pinned and in SOT" {
    # What: ci.sh owns the pin gate; bats calls it.
    # Why: floating external tag breaks reproducibility.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/dep" m="${BATS_TEST_TMPDIR}/m.yml" img
    mkdir -p "${r}"
    local pin base
    pin="hub.example.test/ext-y@sha256:$(printf 'b%.0s' {1..64})"
    base="base.example.test/os@sha256:$(printf 'c%.0s' {1..64})"
    printf '%s\n' 'external_services:' '  ext-y:' "    image: \"${pin}\"" \
        '  ext-t:' '    image: "hub.example.test/ext-t:latest"' '    policy: tag-latest' \
        '  ext-u:' '    image: "hub.example.test/ext-u:latest"' \
        'base_images:' "  os: \"${base}\"" > "${m}"
    for img in 'img-a:7' 'registry.example.test/owner/app:latest' 'hub.example.test/ext-y:1' \
               "hub.example.test/other@sha256:$(printf 'a%.0s' {1..64})" "${pin%b}d" \
               'hub.example.test/ext-u:latest' 'hub.example.test/ext-t:2'; do
        printf 'services:\n  x:\n    image: %s\n' "${img}" > "${r}/docker-compose.yml"
        CI_MANIFEST="${m}" run bash "${CI_SH}" check stable-external-images "${r}"
        [ "${status}" -eq 1 ] || { echo "want fail: ${img}"; false; }
        [[ "${output}" == *"CI-ERROR-CHECK-0014"* ]]
    done
    for img in "${pin}" "\"${base}\"" '${LANCACHE_IMAGE_REGISTRY:-r}/p/svc:t' 'hub.example.test/ext-t:latest'; do
        printf 'services:\n  x:\n    image: %s\n' "${img}" > "${r}/docker-compose.yml"
        CI_MANIFEST="${m}" run bash "${CI_SH}" check stable-external-images "${r}"
        [ "${status}" -eq 0 ] || { echo "want pass: ${img}"; false; }
    done
}

# What: per row: PR body -> ok, skip, draft warn or the gaps
# Why: the template's own headings decide what is required
# From: Issue #1683 | PR #1858
@test "check pr-template: every template section filled, one box marked" {
    local root="${BATS_TEST_TMPDIR}/prt" none="${BATS_TEST_TMPDIR}/prt-none" case env body rc want ex
    local -A V=([@A@]="$(_val name)" [@B@]="$(_val name)")
    V[@CB@]="$(_ci_block_entry_field pr_policy "" checkbox_section)"
    ex="$(_ci_block_entry_list pr_policy "" check_exempt_authors)"
    V[@EX@]="${ex%%$'\n'*}"
    V[@NONE@]="${none}"
    [ -n "${V[@CB@]}" ] && [ -n "${V[@EX@]}" ] || { echo "SOT pr_policy inputs missing"; return 1; }
    mkdir -p "${root}/$(dirname "$(_ci_variable CI_PR_TEMPLATE)")" "${none}"
    printf '## %s\n\n## %s\n\n## %s\n' "${V[@A@]}" "${V[@B@]}" "${V[@CB@]}" > "$(_ci_repo_path CI_PR_TEMPLATE "${root}")"
    unset PR_AUTHOR PR_DRAFT
    export CI_REPO_ROOT="${root}"
    while IFS='|' read -r case env body rc want; do
        [ "${env}" = - ] || export "$(_fill "${env}")"
        PR_BODY="$(printf '%b' "$(_fill "${body}")")" run bash "${CI_SH}" check pr-template
        [ "${env}" = - ] || unset "${env%%=*}"
        export CI_REPO_ROOT="${root}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
filled|-|## @A@\nx\n## @B@\n```text\ny\n```\n## @CB@\n- [x] one|0|pr-template=ok
heading-missing|-|## @A@\nx\n## @CB@\n- [x] one|1|[CI-ERROR-CHECK-0089];@B@: heading not found
box-unmarked|-|## @A@\nx\n## @B@\ny\n## @CB@\n- [ ] one|1|[CI-ERROR-CHECK-0089];@CB@: no checkbox marked
placeholder-only|-|## @A@\n<!-- fill\nthis in -->\n## @B@\ny\n## @CB@\n- [x] one|1|[CI-ERROR-CHECK-0089];@A@: empty (only template placeholder left)
fences-only|-|## @A@\nx\n## @B@\n```\n```\n## @CB@\n- [x] one|1|[CI-ERROR-CHECK-0089];@B@: empty (only template placeholder left)
heading-twice|-|## @A@\nx\n## @A@\nz\n## @B@\ny\n## @CB@\n- [x] one|1|[CI-ERROR-CHECK-0089];@A@: heading appears 2 times
draft|PR_DRAFT=true|## @A@\nx|0|[CI-ERROR-CHECK-0088];pr-template=warn-draft
exempt-author|PR_AUTHOR=@EX@|-|0|pr-template=skip author="@EX@"
no-template|CI_REPO_ROOT=@NONE@|## @A@\nx|2|[CI-ERROR-CHECK-0015]
CASES
}

# What: per row: workflow size -> clean or the one limit hit
# Why: GitHub drops runs of oversized workflow files
# From: Issue #1683
@test "check workflow-line-limit flags the line, byte or run-block limit" {
    local d case steps blocks width char rc want absent body i
    d="${BATS_TEST_TMPDIR}/wf"
    while IFS='|' read -r case steps blocks width char rc want absent; do
        rm -rf "${d}" && mkdir -p "${d}"
        body="$(printf '%*s' "${width}" '')"
        body="${body// /${char}}"
        {
            printf 'name: x\non: push\njobs:\n  x:\n    runs-on: r\n    steps:\n'
            for ((i = 0; i < steps; i++)); do printf '      - run: echo %s\n' "${i}"; done
            for ((i = 0; i < blocks; i++)); do printf '      - run: |\n          %s\n' "${body}"; done
        } > "${d}/w.yml"
        MAX_WORKFLOW_LINES=20 MAX_WORKFLOW_BYTES=1500 MAX_RUN_BLOCK_BYTES=400 \
            run bash "${CI_SH}" check workflow-line-limit "${d}"
        _expect "${case}" "${rc}" "${want}" || return 1
        [ "${absent}" = - ] || [[ "${output}" != *"${absent}"* ]] || { echo "${case}: also '${absent}': ${output}"; return 1; }
    done <<'CASES'
ok|3|1|50|e|0|workflow-line-limit=clean|-
lines-over|20|0|0|e|1|[CI-ERROR-CHECK-0090];raw:;w.yml: 26 lines > 20|bytes >
bytes-over|0|5|350|e|1|[CI-ERROR-CHECK-0090];raw:;bytes > 1500|lines >
block-over|0|1|450|e|1|[CI-ERROR-CHECK-0090];raw:;w.yml:8: run-block 461 bytes > 400|lines >
multibyte-block|0|1|200|ä|1|[CI-ERROR-CHECK-0090];raw:;w.yml:8: run-block 411 bytes > 400|bytes > 1500
CASES
}

# What: a workflow calling ci.sh must pass CI_VARIABLES.
# Why: else ci.sh misses repo/org vars; ids diverge.
# From: Issue #1683 | PR #1858
@test "workflow-ci-variables flags a ci.sh caller without CI_VARIABLES" {
    local r
    r="$(_val path)"
    local -A V=(
        [@W@]="$(_val name)" [@A@]="$(_val name)" [@B@]="$(_val name)" [@C@]="$(_val name)"
        [@J@]="$(_val name)" [@S@]="$(_val name)" [@O@]="$(_val var)"
    )
    mkdir -p "${r}/${V[@W@]}"
    _fill "$(printf '%s\n' 'env:' '  CI_VARIABLES: ${{ toJSON(vars) }}' 'jobs:' '  @J@:' '    steps:' \
        '      - run: bash .github/scripts/ci.sh @S@')" > "${r}/${V[@W@]}/${V[@A@]}.yml"
    _fill "$(printf '%s\n' 'env:' '  @O@: @S@' 'jobs:' '  @J@:' '    steps:' \
        '      - run: bash .github/scripts/ci.sh @S@')" > "${r}/${V[@W@]}/${V[@B@]}.yml"
    _fill "$(printf '%s\n' 'jobs:' '  @J@:' '    steps:' '      - run: @S@')" > "${r}/${V[@W@]}/${V[@C@]}.yml"
    CI_WORKFLOW_DIR="${V[@W@]}" run _ci_check_workflow_ci_variables "${r}"
    _expect missing 1 "$(_fill '[CI-ERROR-CHECK-0158] scanned=3 callers=2 flagged=1;raw:;@W@/@B@.yml: calls ci.sh without')" || return 1
    [[ "${output}" != *"${V[@A@]}.yml"* ]] || { echo "wired workflow flagged: ${output}"; return 1; }
    rm "${r}/${V[@W@]}/${V[@B@]}.yml"
    CI_WORKFLOW_DIR="${V[@W@]}" run _ci_check_workflow_ci_variables "${r}"
    _expect wired 0 '=workflow-ci-variables=clean scanned=2 callers=1' || return 1
}

# What: per row: SOT -> runner + timeouts output or an id.
# Why: AG-CI-002/006: workflows take both from one owner.
# From: Issue #1683 | PR #1858
@test "job-settings emits the SOT runner and job timeouts" {
    local go case sot rc want
    go="$(_val path)"
    local -A V=(
        [@OS@]="$(_val name)" [@ARCH@]="$(_val name)" [@RUN@]="$(_val name)" [@J1@]="$(_val name)"
        [@J2@]="$(_val name)" [@M1@]="$(_val int 1 600)" [@M2@]="$(_val int 1 600)" [@BAD@]="$(_val name)"
        [@ARCH2@]="$(_val name)" [@RUN2@]="$(_val name)"
    )
    local -A P=(
        [plat]='build_matrix:\n  platforms: [@OS@/@ARCH@, @OS@/@ARCH2@]\n' [noplat]='build_matrix:\n  platforms: []\n'
        [arch]='platform_arch:\n  @ARCH@:\n    runner: @RUN@\n  @ARCH2@:\n    runner: @RUN2@\n'
        [nolabel]='platform_arch:\n  @ARCH@:\n    apk: @RUN@\n  @ARCH2@:\n    runner: @RUN2@\n'
        [jobs]='ci_job_timeouts:\n  @J1@: @M1@\n  @J2@: @M2@\n' [badjobs]='ci_job_timeouts:\n  @J1@: @BAD@\n'
    )
    local -A S=(
        [ok]="plat arch jobs" [noplat]="noplat arch jobs" [nolabel]="plat nolabel jobs" [nojobs]="plat arch"
        [bad]="plat arch badjobs"
    )
    while IFS='|' read -r case sot rc want; do
        local m p
        m="$(_val path)"
        for p in ${S[${sot}]}; do printf '%b' "$(_fill "${P[${p}]}")"; done > "${m}"
        : > "${go}"
        GITHUB_OUTPUT="${go}" CI_MANIFEST="${m}" run bash "${CI_SH}" job-settings
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "${rc}" -eq 0 ]; then
            [ "$(cat "${go}")" = "$(_fill 'runner=@RUN@')"$'\n'"$(_fill 'timeouts={"@J1@":@M1@,"@J2@":@M2@}')" ] \
                || { echo "${case}: step output $(cat "${go}")"; return 1; }
        else
            [ ! -s "${go}" ] || { echo "${case}: partial step output $(cat "${go}")"; return 1; }
        fi
    done <<'CASES'
ok|ok|0|runner=@RUN@;timeouts={"@J1@":@M1@,"@J2@":@M2@}
no-platform|noplat|2|[CI-ERROR-JOBS-0001]
no-label|nolabel|2|[CI-ERROR-JOBS-0002] platform="@OS@/@ARCH@" field="runner"
no-timeouts|nojobs|2|[CI-ERROR-JOBS-0003]
bad-timeout|bad|2|[CI-ERROR-JOBS-0004] job="@J1@";value=@BAD@
CASES
    printf '%b' "$(_fill "${P[plat]}${P[arch]}${P[jobs]}")" > "${go}.sot"
    GITHUB_OUTPUT="$(_val path)/$(_val name)" CI_MANIFEST="${go}.sot" run bash "${CI_SH}" job-settings
    _expect output-unwritable 2 '[CI-ERROR-JOBS-0005];raw:' || return 1
}

# What: per row: workflow + SOT -> clean or a flagged job
# Why: needs jobs read job-settings; root literals = SOT
# From: Issue #1683 | PR #1858
@test "workflow-job-settings flags a job setting not from the SOT" {
    local r m case ext wf rc want
    r="$(_val path)"
    m="${r}.sot"
    local -A V=(
        [@W@]="$(_val name)" [@F@]="$(_val name)" [@E@]="$(_val name)" [@J@]="$(_val name)" [@K@]="$(_val name)"
        [@L@]="$(_val name)" [@X@]="$(_val name)" [@T@]="$(_val int 1 600)" [@TJ@]="$(_val int 1 600)"
        [@S@]="$(_val name)" [@OS@]="$(_val name)" [@ARCH@]="$(_val name)" [@OR@]='||'
    )
    V[@T1@]="$(( ${V[@T@]} + 1 ))"
    V[@TJ1@]="$(( ${V[@TJ@]} + 1 ))"
    V[@ROOT@]='jobs:\n  @E@:\n    runs-on: @L@\n    timeout-minutes: @T@\n    steps:\n      - run: bash .github/scripts/ci.sh job-settings\n'
    V[@NJ@]='  @J@:\n    needs: @E@\n'
    V[@RO@]='    runs-on: ${{ needs.@E@.outputs.runner }}\n'
    V[@TO@]="    timeout-minutes: \${{ fromJSON(needs.@E@.outputs.timeouts)['@J@'] }}\n"
    V[@STEP@]='    steps:\n      - run: bash .github/scripts/ci.sh @S@\n'
    printf '%b' "$(_fill 'build_matrix:\n  platforms: [@OS@/@ARCH@]\nplatform_arch:\n  @ARCH@:\n    runner: @L@\nci_job_timeouts:\n  @E@: @T@\n  @J@: @TJ@\n')" > "${m}"
    while IFS='|' read -r case ext wf rc want; do
        rm -rf "${r}" && mkdir -p "${r}"
        case "${ext}" in
            file) : > "${r}/${V[@W@]}" ;;
            -) mkdir -p "${r}/${V[@W@]}" ;;
            *) mkdir -p "${r}/${V[@W@]}"
               printf '%b' "$(_fill "$(_fill "${wf}")")" > "${r}/${V[@W@]}/${V[@F@]}.${ext}" ;;
        esac
        CI_MANIFEST="${m}" CI_WORKFLOW_DIR="${V[@W@]}" run _ci_check_workflow_job_settings "${r}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
clean|yml|@ROOT@@NJ@@RO@@TO@@STEP@|0|=workflow-job-settings=clean scanned=1 jobs=2
matrix-runner|yml|@ROOT@@NJ@    runs-on: ${{ matrix.runner }}\n@TO@@STEP@|0|=workflow-job-settings=clean scanned=1 jobs=2
root-without-ci-sh|yml|jobs:\n  @E@:\n    runs-on: "@L@"\n    timeout-minutes: @T@\n    steps:\n      - run: @S@\n|0|=workflow-job-settings=clean scanned=1 jobs=1
uses-job|yml|@ROOT@  @J@:\n    needs: @E@\n    uses: ./@S@.yml\n|0|=workflow-job-settings=clean scanned=1 jobs=1
needs-literal-runner|yml|@ROOT@@NJ@    runs-on: @L@\n@TO@@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: runs-on @L@ (a needs job reads job-settings)
needs-literal-timeout|yml|@ROOT@@NJ@@RO@    timeout-minutes: @TJ@\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: timeout-minutes @TJ@ (a needs job reads job-settings)
needs-block-runner|yml|@ROOT@@NJ@    runs-on:\n      - @L@\n@TO@@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: runs-on [block] - @L@ (a needs job
root-runner-drift|yml|jobs:\n  @E@:\n    runs-on: @X@\n    timeout-minutes: @T@\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=1 flagged=1;raw:;@W@/@F@.yml: job @E@: runs-on @X@ (SOT runner @L@)
root-timeout-drift|yml|jobs:\n  @E@:\n    runs-on: @L@\n    timeout-minutes: @T1@\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=1 flagged=1;raw:;@W@/@F@.yml: job @E@: timeout-minutes @T1@ (SOT ci_job_timeouts.@E@: @T@)
no-timeout|yml|jobs:\n  @E@:\n    runs-on: @L@\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=1 flagged=1;raw:;@W@/@F@.yml: job @E@: no timeout-minutes
runner-fallback-drift|yml|@ROOT@@NJ@    runs-on: ${{ needs.@E@.outputs.runner @OR@ '@X@' }}\n@TO@@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: runs-on fallback '@X@' (SOT runner @L@)
timeout-fallback-drift|yml|@ROOT@@NJ@@RO@    timeout-minutes: ${{ fromJSON(needs.@E@.outputs.timeouts)['@J@'] @OR@ @TJ1@ }}\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: timeout fallback @TJ1@ (SOT ci_job_timeouts.@J@: @TJ@)
wrong-key|yml|@ROOT@@NJ@@RO@    timeout-minutes: ${{ fromJSON(needs.@E@.outputs.timeouts)['@E@'] }}\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @J@: timeout-minutes reads key @E@
needs-no-sot-key|yml|@ROOT@  @K@:\n    needs: @E@\n@RO@    timeout-minutes: ${{ fromJSON(needs.@E@.outputs.timeouts)['@K@'] }}\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=2 flagged=1;raw:;@W@/@F@.yml: job @K@: no SOT ci_job_timeouts.@K@
no-jobs-block|yml|name: @S@\non: push\n|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=0 flagged=1;raw:;@W@/@F@.yml: no top-level jobs: block
unparsable-jobs|yml|jobs:\n    @E@:\n      runs-on: @X@\n|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=0 flagged=1;raw:;@W@/@F@.yml: jobs: block without a parsable job
yaml-extension|yaml|jobs:\n  @E@:\n    runs-on: @X@\n    timeout-minutes: @T@\n@STEP@|1|[CI-ERROR-CHECK-0159] scanned=1 jobs=1 flagged=1;raw:;@W@/@F@.yaml: job @E@: runs-on @X@ (SOT runner @L@)
empty-dir|-|-|2|[CI-ERROR-CHECK-0053];@W@";reason="no workflow files (*.yml, *.yaml)";raw:
not-a-dir|file|-|2|[CI-ERROR-CHECK-0016];@W@";reason="not a directory";raw:;@W@
CASES
}

@test "check pr-tracking-metadata: context, labels, milestone, fork, draft" {
    # What: AG-GH-008 gaps fail; fork/draft warn; SOT board.
    # Why: never report metadata the PR has; wiring != gap.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'pr_policy:\n  project_number: 7\n' > "${m}"
    _sot_block ci_variables >> "${m}"
    export CI_MANIFEST="${m}" PR_NUMBER=12 GITHUB_REPOSITORY=owner/fixture-repo
    PR_NUMBER='' run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 2 ]
    GITHUB_REPOSITORY='' run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -ne 0 ]; [[ "${output}" != *"pr-tracking-metadata=ok"* ]]
    PR_LABELS_JSON='[]' run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 1 ]; [[ "${output}" == *"No labels set"* ]]
    PR_LABELS_JSON='not-json' PR_MILESTONE_TITLE=v1 run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 1 ]; [[ "${output}" == *"not a JSON array"* ]]
    run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 1 ]; [[ "${output}" == *"labels not provided to the check"* ]]
    [[ "${output}" != *"No labels set"* ]]
    PR_LABELS_JSON='["bug"]' PR_MILESTONE_TITLE=v1 run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]; [[ "${output}" == *"no read:project token"* ]]
    PR_LABELS_JSON='["bug"]' PR_MILESTONE_TITLE=v1 PR_IS_FORK=true run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]; [[ "${output}" == *"fork PRs get no repo secrets"* ]]
    PR_DRAFT=true PR_LABELS_JSON='[]' run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-tracking-metadata=warn-draft"* ]]
    printf 'pr_policy:\n  project_number: x\n' > "${m}"
    PR_LABELS_JSON='["bug"]' PR_MILESTONE_TITLE=v1 run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 2 ]; [[ "${output}" == *"no numeric SOT pr_policy.project_number"* ]]
    # What: SOT path labels per path; pr-labels adds them.
    # Why: the labeler rules live on in the SOT and ci.sh.
    # From: Issue #1683 | PR #1858
    local p want got lst="${BATS_TEST_TMPDIR}/changed" gh
    export CI_MANIFEST="${CI_MANIFEST_SOURCE}"
    while IFS='|' read -r p want; do
        got="$(_ci_pr_labels_for "${p}" | paste -sd, -)"
        [ "${got}" = "${want}" ] || { echo "${p}: got ${got} want ${want}"; return 1; }
    done <<'ROWS'
services/dns/nats-subscriber/src/main.rs|dns,pdns,rust
README.md|documentation
deploy/prod/docker-compose.yml|docker,setup
tools/build-tools/Dockerfile|build-tools,docker
.github/scripts/ci.sh|ci
services/ntp/entrypoint.sh|ntp
services/dhcp/entrypoint.sh|dhcp,kea
services/dhcp-proxy/entrypoint.sh|dhcp-proxy,dnsmasq
services/proxy/entrypoint.sh|nginx,proxy
services/ui/src/templates/x.html|admin-ui
services/ui/src/main.rs|admin-ui,rust
services/watchdog/src/main.rs|rust,watchdog
services/syslog/entrypoint.sh|syslog
setup.sh|setup
config/prod/proxy.env|setup
services/ntp/Dockerfile|docker,ntp
.github/workflows/ci.yml|ci,github_actions
docs/release-versioning.md|documentation
CHANGELOG.md|documentation
services/nats/x|
scripts/lib/x.sh|
ROWS
    printf 'README.md\n' > "${lst}"
    gh="$(_val path)/gh"
    _tool_stub "${gh%/*}" gh <<<'printf "%s\n" "$*" >> "'"${BATS_TEST_TMPDIR}"'/gh.log"
case "$*" in
*query=query*) [ -n "${GH_NOPROJ:-}" ] && echo "{\"data\":{\"organization\":{\"projectV2\":null}}}" && exit 0
    echo "{\"data\":{\"organization\":{\"projectV2\":{\"id\":\"PVT_1\"}},\"repository\":{\"issueOrPullRequest\":{\"id\":\"C1\"}}}}" ;;
*query=mutation*) [ -z "${GH_ADDFAIL:-}" ] || { echo "GraphQL: denied" >&2; exit 1; }
    [ -n "${GH_NOITEM:-}" ] && echo "{\"data\":{\"addProjectV2ItemById\":{\"item\":null}}}" && exit 0
    echo "{\"data\":{\"addProjectV2ItemById\":{\"item\":{\"id\":\"PVTI_2\"}}}}" ;;
*/labels*) [ -n "${GH_LABELDROP:-}" ] && echo "[{\"name\":\"other\"}]" && exit 0
    echo "[{\"name\":\"other\"},{\"name\":\"documentation\"}]" ;;
esac'
    GITHUB_EVENT_NAME=push run ci_cmd_pr_labels
    [[ "${output}" == *'pr-labels=NOT-RUN reason="not a pull request"'* ]]
    GITHUB_EVENT_NAME=pull_request PR_IS_FORK=true run ci_cmd_pr_labels
    [[ "${output}" == *'pr-labels=NOT-RUN reason="fork PR'* ]]
    GITHUB_EVENT_NAME=pull_request CHANGED_FILES="${lst}" PATH="${gh%/*}:${PATH}" run ci_cmd_pr_labels
    [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-labels=added labels=documentation"* ]]
    [ "$(cat "${BATS_TEST_TMPDIR}/gh.log")" = 'api -X POST repos/owner/fixture-repo/issues/12/labels -f labels[]=documentation' ]
    GH_LABELDROP=1 GITHUB_EVENT_NAME=pull_request CHANGED_FILES="${lst}" PATH="${gh%/*}:${PATH}" run ci_cmd_pr_labels
    [ "${status}" -eq 2 ]; [[ "${output}" == *'[CI-ERROR-PRLABELS-0003] pr="12" missing="documentation"'*'"other"'* ]]
    GITHUB_EVENT_NAME=pull_request CHANGED_FILES="${BATS_TEST_TMPDIR}/none" run ci_cmd_pr_labels
    [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-PRLABELS-0001]"* ]]
    # What: board-add puts PR/issue on the SOT board number.
    # Why: board placement is CI; the URL is not in YAML.
    # From: Issue #1683 | PR #1858
    : > "${BATS_TEST_TMPDIR}/gh.log"
    GITHUB_EVENT_NAME=push run ci_cmd_board_add
    [[ "${output}" == *'board-add=NOT-RUN reason="not a pull request or issue"'* ]]
    GITHUB_EVENT_NAME=pull_request GH_TOKEN='' run ci_cmd_board_add
    [[ "${output}" == *'board-add=NOT-RUN reason="no project token'* ]]
    GITHUB_EVENT_NAME=pull_request GH_TOKEN=t PATH="${gh%/*}:${PATH}" run ci_cmd_board_add
    [ "${status}" -eq 0 ]; [[ "${output}" == *"board-add=added project=6 pull=12"* ]]
    GITHUB_EVENT_NAME=issues ISSUE_NUMBER=7 GH_TOKEN=t PATH="${gh%/*}:${PATH}" run ci_cmd_board_add
    [ "${status}" -eq 0 ]; [[ "${output}" == *"board-add=added project=6 issues=7"* ]]
    grep -qF -- '-f o=owner -f r=fixture-repo -F p=6 -F n=12 -f query=query' "${BATS_TEST_TMPDIR}/gh.log"
    grep -qF -- '-F p=6 -F n=7 -f query=query' "${BATS_TEST_TMPDIR}/gh.log"
    [ "$(grep -c -- '-f p=PVT_1 -f c=C1 -f query=mutation' "${BATS_TEST_TMPDIR}/gh.log")" -eq 2 ]
    GH_NOPROJ=1 GITHUB_EVENT_NAME=issues ISSUE_NUMBER=7 GH_TOKEN=t PATH="${gh%/*}:${PATH}" run ci_cmd_board_add
    [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-BOARD-0003]"*'"projectV2":null'* ]]
    GH_ADDFAIL=1 GITHUB_EVENT_NAME=issues ISSUE_NUMBER=7 GH_TOKEN=t PATH="${gh%/*}:${PATH}" run ci_cmd_board_add
    [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-BOARD-0004]"*"GraphQL: denied"* ]]
    GH_NOITEM=1 GITHUB_EVENT_NAME=issues ISSUE_NUMBER=7 GH_TOKEN=t PATH="${gh%/*}:${PATH}" run ci_cmd_board_add
    [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-BOARD-0005]"*'"item":null'* ]]
    sed 's/^  project_number: 6$/  project_number: x/' "${CI_MANIFEST_SOURCE}" > "${BATS_TEST_TMPDIR}/pb.yml"
    CI_MANIFEST="${BATS_TEST_TMPDIR}/pb.yml" GITHUB_EVENT_NAME=pull_request GH_TOKEN=t run ci_cmd_board_add
    [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-BOARD-0001]"* ]]
}

@test "check pr-tracking-metadata board lookup: failed, hit, miss" {
    # What: any lookup failure fails; SOT number hit passes.
    # Why: board owner is the repo owner, never a literal.
    # From: Issue #1683 | PR #1858
    local bin="${BIN}" m="${BATS_TEST_TMPDIR}/m.yml" mode
    mkdir -p "${bin}"
    printf 'pr_policy:\n  project_number: 7\n' > "${m}"
    _sot_block ci_variables >> "${m}"
    _tool_stub "${bin}" gh <<'EOF'
case "${MODE}" in
    failed) echo "gh: HTTP 500" >&2; exit 1 ;;
    hit) n=7 ;;
    miss) n=99 ;;
esac
[[ " $* " == *" owner=owner "* ]] || n=0
printf '{"data":{"repository":{"pullRequest":{"projectItems":{"nodes":[{"project":{"number":%s}}]}}}}}' "${n}"
EOF
    for mode in failed hit miss; do
        MODE="${mode}" PATH="${bin}:${PATH}" CI_MANIFEST="${m}" PR_NUMBER=12 \
            GITHUB_REPOSITORY=owner/fixture-repo CI_RETRY_MAX_ATTEMPTS=1 \
            PR_LABELS_JSON='["bug"]' PR_MILESTONE_TITLE=v1 GH_TOKEN=t \
            run bash "${CI_SH}" check pr-tracking-metadata
        case "${mode}" in
            failed) [ "${status}" -eq 1 ]; [[ "${output}" == *"Project-board lookup failed"* ]] ;;
            hit) [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-tracking-metadata=ok"* ]] ;;
            miss) [ "${status}" -eq 1 ]; [[ "${output}" == *"Not on project board #7 (owner)"* ]] ;;
        esac
    done
}

# What: neutral SOT, gh mock and call log for the sweep.
# Why: PRs and issues are fixtures; no SOT mirror.
# From: Issue #1683 | PR #1858
_ob_setup() {
    local m="${BATS_TEST_TMPDIR}/ob.yml"
    printf '%s\n' 'release:' '  channels:' '    stable:' '      ref: refs/heads/trunk' \
        'branch_policy:' '  orphan_min_age_seconds: 3600' '  long_lived: [dev]' \
        '  long_lived_regex:' '    - "^rel-"' > "${m}"
    _sot_block ci_variables >> "${m}"
    export CI_MANIFEST="${m}" GITHUB_REPOSITORY=owner/fixture-repo GH_TOKEN=t
    export CI_RETRY_BACKOFF_BASE_SECONDS=0 OB_CALLS="${BATS_TEST_TMPDIR}/gh.calls"
    export OB_REFS='' OB_ISSUES='' OB_MORE='' OB_FAIL=''
    OB_OLD="2020-01-01T00:00:00Z"
    OB_NEW="$(date -u -d "@$(($(date -u +%s) - 60))" +%Y-%m-%dT%H:%M:%SZ)"
    : > "${OB_CALLS}"
    gh() {
        echo "$*" >> "${OB_CALLS}"
        case "$*" in
            *"${OB_FAIL:-<none>}"*) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
            *"refs(refPrefix"*) printf '%s' "${OB_REFS}" ;;
            *"issue(number"*) printf '%s' "${OB_MORE}" ;;
            *"issues(first"*) printf '%s' "${OB_ISSUES}" ;;
            *) echo "unexpected gh $*" >&2; return 1 ;;
        esac
    }
    export -f gh
}

# What: one refs page from "name|date|prs|author" rows.
# Why: tests state branches, not GraphQL JSON shape.
# From: Issue #1683 | PR #1858
_ob_page() {
    jq -cn --arg rows "$1" '{data: {repository: {refs: {nodes: ($rows | split("\n")
        | map(select(. != "") | split("|") | {name: .[0], target: {committedDate: .[1],
        author: {name: .[3]}}, associatedPullRequests: {totalCount: (.[2] | tonumber)}}))}}}}'
}

# What: one issues page; issue 7 has more than 100 comments.
# Why: drives the per-issue comment paging path.
# From: Issue #1683 | PR #1858
_ob_issues() {
    printf '%s' '{"data":{"repository":{"issues":{"nodes":[
        {"number":1,"body":"see inbody and prefix-long","comments":{"nodes":[{"body":"pushed `incomment`; see dotted."}],"pageInfo":{"hasNextPage":false}}},
        {"number":4,"body":"branch inclosed done","comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}},
        {"number":7,"body":null,"comments":{"nodes":[{"body":"x"}],"pageInfo":{"hasNextPage":true}}}]}}}}'
}

@test "check orphaned-branches: long-lived, age, PR, references" {
    # What: only old non-long-lived refs with no PR/issue.
    # Why: AG-GH-017; a finding is rc 1 with name and date.
    # From: Issue #1683 | PR #1858
    _ob_setup
    OB_REFS="$(_ob_page "trunk|${OB_OLD}|0|a
dev|${OB_OLD}|0|a
rel-1|${OB_OLD}|0|a
young|${OB_NEW}|0|a
haspr|${OB_OLD}|2|a
closedpr|${OB_OLD}|1|a
inbody|${OB_OLD}|0|a")$(_ob_page "incomment|${OB_OLD}|0|a
prefix|${OB_OLD}|0|a
dotted|${OB_OLD}|0|a
lost|${OB_OLD}|0|Ann Author
inclosed|${OB_OLD}|0|a
inlong|${OB_OLD}|0|a")"
    OB_ISSUES="$(_ob_issues)"
    OB_MORE="$(jq -cn '{data: {repository: {issue: {comments: {nodes: [{body: "late inlong"}]}}}}}')"
    export OB_REFS OB_ISSUES OB_MORE
    run bash "${CI_SH}" check orphaned-branches
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0139"*"orphaned=2 scanned=13 checked=9"* ]]
    [[ "${output}" == *'branch="lost" last_commit=2020-01-01T00:00:00Z author="Ann Author"'* ]]
    [[ "${output}" == *'branch="prefix"'* ]]
    local b
    for b in trunk dev rel-1 young haspr closedpr inbody incomment dotted inclosed inlong; do
        [[ "${output}" != *"branch=\"${b}\""* ]]
    done
    grep -qF 'number=7' "${OB_CALLS}"
}

@test "check orphaned-branches: clean run never lists issues" {
    # What: every ref has a PR -> clean, no issue query.
    # Why: success shows what was scanned (5W evidence).
    # From: Issue #1683 | PR #1858
    _ob_setup
    OB_REFS="$(_ob_page "trunk|${OB_OLD}|0|a
haspr|${OB_OLD}|1|a")"
    export OB_REFS
    run _ci_check_orphaned_branches
    [ "${status}" -eq 0 ]
    [ "${output}" = "orphaned-branches=clean scanned=2 checked=1 no_pr=0" ]
    ! grep -qF 'issues(first' "${OB_CALLS}"
}

@test "check orphaned-branches: every failure is coded rc 2" {
    # What: token, SOT, API and parse failures fail closed.
    # Why: a failed lookup never reads as orphan or clean.
    # From: Issue #1683 | PR #1858
    local case setup want
    while IFS='|' read -r case setup want; do
        _ob_setup
        OB_REFS="$(_ob_page "lost|${OB_OLD}|0|a")"; OB_ISSUES="$(_ob_issues)"
        OB_MORE="$(jq -cn '{data: {repository: {issue: {comments: {nodes: []}}}}}')"
        export OB_REFS OB_ISSUES OB_MORE
        eval "${setup}"
        run _ci_check_orphaned_branches
        echo "case=${case} status=${status} output=${output}"
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"${want}"* ]]
        [[ "${output}" != *"orphaned-branches=clean"* ]]; [[ "${output}" != *"CHECK-0139"* ]]
    done <<'CASES'
no-token|GH_TOKEN=''|CI-ERROR-CHECK-0130
bad-age|sed -i 's/3600/1h/' "${CI_MANIFEST}"|CI-ERROR-CHECK-0131
no-long-lived|printf 'branch_policy:\n  orphan_min_age_seconds: 1\n' > "${CI_MANIFEST}"|CI-ERROR-CHECK-0132
refs-fail|OB_FAIL='refs(refPrefix'|CI-ERROR-CHECK-0133
refs-row|OB_REFS='{"data":{"repository":{"refs":{"nodes":[{"name":"x","target":{"committedDate":"2020-01-01T00:00:00Z"},"associatedPullRequests":{}}]}}}}'|CI-ERROR-CHECK-0134
refs-json|OB_REFS='not json'|CI-ERROR-CHECK-0135
issues-fail|OB_FAIL='issues(first'|CI-ERROR-CHECK-0136
issues-json|OB_ISSUES='{'|CI-ERROR-CHECK-0137
more-fail|OB_FAIL='issue(number'|CI-ERROR-CHECK-0138
more-json|OB_MORE='{'|CI-ERROR-CHECK-0141
bad-regex|sed -i 's/"\^rel-"/"(rel"/' "${CI_MANIFEST}"|CI-ERROR-CORE-0106
match-fail|_ci_unreferenced_names() { ci_error "[CI-ERROR-CHECK-0140]" "x" "y"; return 2; }|CI-ERROR-CHECK-0140
CASES
}

@test "unreferenced names: ref-grammar bounds; read error rc 2" {
    # What: a name counts only between ref-grammar bounds.
    # Why: x4 in x4-long is another ref, not a reference.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/corpus"
    printf 'a `x1` b x2.\n(x3)/y x4-long x5_y\n' > "${f}"
    run _ci_unreferenced_names $'x1\nx2\nx3\nx4\nx5' "${f}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'x4\nx5' ]
    run _ci_unreferenced_names x1 "${BATS_TEST_TMPDIR}/missing"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0140"*"missing"*"raw:"* ]]
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

# What: gh mock for close-linked-issues; writes are logged.
# Why: PR lookup, issue meta and writes need no network.
# From: Issue #1137 | PR #1858
_lk_setup() {
    export GITHUB_REPOSITORY=owner/fixture-repo GH_TOKEN=t CI_RETRY_BACKOFF_BASE_SECONDS=0
    export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/dev GITHUB_SHA=abc CI_DEFAULT_BRANCH=main
    export LK_LOG="${BATS_TEST_TMPDIR}/lk.log" LK_FAIL='' LK_BODY
    LK_BODY=$'## Summary\nx\n## Linked Issues\nCloses #1, fixes owner/fixture-repo#2, resolves other/repo#3\nThis does not close #4.\nCloses #5\nCloses #6\n### Notes\ncloses #7\n'
    : > "${LK_LOG}"
    gh() {
        local a="$*" f
        case "${a}" in *"${LK_FAIL:-<none>}"*) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;; esac
        case "${a}" in
            *"object(oid"*) jq -cn --arg b "${LK_BODY}" '{data: {repository: {object: {associatedPullRequests: {nodes: [
                {number: 9, merged: true, baseRefName: "dev", url: "u9", body: $b, mergeCommit: {oid: "abc"}},
                {number: 8, merged: false, baseRefName: "dev", url: "u8", body: "", mergeCommit: null}]}}}}}' ;;
            *"pullRequest(number"*) jq -cn --arg b "${LK_BODY}" '{data: {repository: {pullRequest:
                {number: 9, merged: true, baseRefName: "dev", url: "u9", body: $b, mergeCommit: {oid: "abc"}}}}}' ;;
            *"-X POST"*) f="${a##*body=@}"; { echo "COMMENT ${a}"; cat "${f}"; } >> "${LK_LOG}"
                if [ -n "${LK_ECHO:-}" ]; then echo "${LK_ECHO}"; else cat "${f}"; fi ;;
            *"-X PATCH"*) echo "CLOSE ${a}" >> "${LK_LOG}"; echo "${LK_STATE:-closed}" ;;
            *"issues/5 "*) printf 'pr\topen\n' ;;
            *"issues/6 "*) printf 'issue\tclosed\n' ;;
            *"issues/"*) printf 'issue\topen\n' ;;
            *) echo "unexpected gh ${a}" >&2; return 1 ;;
        esac
    }
    export -f gh
}

# What: per row: push and PR text -> written issues or an id
# Why: mirrors GitHub auto-close off the default branch
# From: Issue #1137 | PR #1858
@test "close-linked-issues closes the open issues a merged PR lists" {
    local case env args rc want seen writes quote got k part
    local -a argv parts
    _lk_setup
    sed 's/^  linked_section: Linked Issues$/  linked_section: Fixes/' "${CI_MANIFEST_SOURCE}" > "${BATS_TEST_TMPDIR}/lk.yml"
    local -A V=([@LKSOT@]="${BATS_TEST_TMPDIR}/lk.yml" [@X@]="$(_val name)")
    local -A D=(
        [GITHUB_EVENT_NAME]=push [GITHUB_REF]=refs/heads/dev [GITHUB_SHA]=abc [CI_DEFAULT_BRANCH]=main
        [LK_FAIL]='' [LK_BODY]="${LK_BODY}" [CI_MANIFEST]="${CI_MANIFEST}"
    )
    while IFS='|' read -r case env args rc want seen writes quote; do
        : > "${LK_LOG}"
        [ "${env}" = - ] || export "$(printf '%b' "$(_fill "${env}")")"
        argv=()
        [ "${args}" = - ] || read -r -a argv <<< "${args}"
        run bash "${CI_SH}" close-linked-issues "${argv[@]}"
        if [ "${env}" != - ]; then
            k="${env%%=*}"
            if [ -n "${D[${k}]+set}" ]; then export "${k}=${D[${k}]}"; else unset "${k}"; fi
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        IFS=';' read -r -a parts <<< "${seen#-}"
        for part in "${parts[@]}"; do
            [[ "${output}" == *"${part}"* ]] || { echo "${case}: no '${part}': ${output}"; return 1; }
        done
        got="$(sed -n 's#^\(COMMENT\|CLOSE\) .*repos/owner/fixture-repo/issues/\([0-9][0-9]*\)[ /].*#\2#p' "${LK_LOG}" | sort -un | paste -sd, -)"
        [ "${got}" = "${writes#-}" ] || { echo "${case}: wrote issues '${got}' want '${writes}'"; return 1; }
        [ "${quote}" != - ] || continue
        IFS=';' read -r -a parts <<< "${quote}"
        for part in "${parts[@]}"; do
            grep -qF -- "${part}" "${LK_LOG}" || { echo "${case}: comment lacks '${part}'"; return 1; }
        done
    done <<'CASES'
closes|-|-|0|close-linked-issues=done pr=9 closed=2 skipped=3|[CI-NOTICE-LINK-0008] pr=9 ref="other/repo#3";[CI-NOTICE-LINK-0009] pr=9 ref=#5;[CI-NOTICE-LINK-0010] pr=9 ref=#6|1,2|Closed by PR #9 (u9), merge commit `abc`;Closes #1, fixes owner/fixture-repo#2
grammar|LK_BODY=## Linked Issues\nCloses #1, FIXES: #2 and resolved Owner/Repo#3.\nThis does not close #4. It doesn't fix #5.\nencloses #6, Refs #7.\nNo. Closes #8\nclose#9|-|0|close-linked-issues=done pr=9 closed=3 skipped=1|[CI-NOTICE-LINK-0008] pr=9 ref="owner/repo#3"|1,2,8|-
pr-event|GITHUB_EVENT_NAME=pull_request|-|0|skip reason="not a branch push"|-|-|-
default-branch|GITHUB_REF=refs/heads/main|-|0|skip reason="GitHub closes on the default branch"|-|-|-
no-default-branch|CI_DEFAULT_BRANCH=|-|2|[CI-ERROR-LINK-0005]|-|-|-
no-sha|GITHUB_SHA=|-|2|[CI-ERROR-LINK-0015]|-|-|-
no-merged-pr|GITHUB_SHA=other|-|0|clean reason="no merged PR for this push"|-|-|-
replay-needs-dry-run|-|--pr 9|2|[CI-ERROR-LINK-0003]|-|-|-
dry-run|-|--dry-run --pr 9|0|close-linked-issues=dry-run pr=9 closed=2 skipped=3|-|-|-
lookup-fails|LK_FAIL=issues/1 |-|2|[CI-ERROR-LINK-0012];closed=1 failed=1;#1: lookup failed|-|2|-
comment-differs|LK_ECHO=@X@|-|2|[CI-ERROR-LINK-0016];stored comment differs;[CI-ERROR-LINK-0012];closed=0 failed=2|-|1,2|-
state-open|LK_STATE=open|-|2|[CI-ERROR-LINK-0012];#1: state after the close request: open|-|1,2|-
ambiguous|LK_BODY=## Linked Issues\nCloses #1\n## Linked Issues\nCloses #2|-|1|[CI-ERROR-LINK-0007]|-|-|-
other-heading|CI_MANIFEST=@LKSOT@|-|0|clean pr=9 reason="no Fixes section"|-|-|-
CASES
}

# What: per row: event + search -> posted, skipped or an id
# Why: one welcome owner; first contact only, bots skip
# From: Issue #1683 | PR #1858
@test "welcome posts the SOT text on a first issue or PR only" {
    local ev m case payload oldest post rc want
    ev="$(_val path)"; m="$(_val path)"
    local -A V=(
        [@U@]="$(_val name)" [@N@]="$(_val int 100 900)" [@O@]="$(_val int 1 99)" [@R@]="$(_val name)/$(_val name)"
        [@I1@]="$(_val name)" [@I2@]="$(_val name)" [@P1@]="$(_val name)"
    )
    { _sot_block ci_variables
      _fill 'pr_policy:\n  welcome_issue:\n    - @I1@\n    - ""\n    - "- @I2@"\n  welcome_pr:\n    - @P1@\n' | sed 's/\\n/\n/g'
    } > "${m}"
    local -A T=([issue]="$(_fill $'@I1@\n\n- @I2@')" [pr]="$(_fill '@P1@')")
    export GITHUB_REPOSITORY="${V[@R@]}" GH_TOKEN=t CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_MANIFEST="${m}"
    export WL_LOG="${BATS_TEST_TMPDIR}/wl.log" WL_POSTED="${BATS_TEST_TMPDIR}/wl.posted"
    gh() {
        local a="$*" f
        case "${a}" in
            *search/issues*) echo "SEARCH ${a}" >> "${WL_LOG}"
                [ -z "${WL_SEARCH_FAIL:-}" ] || { echo "gh: HTTP 422 ${WL_SEARCH_FAIL}" >&2; return 1; }
                [ -z "${WL_OLDEST:-}" ] || printf '%s\n' "${WL_OLDEST}" ;;
            *"-X POST"*) f="${a##*body=@}"; cp "${f}" "${WL_POSTED}"
                if [ -n "${WL_ECHO:-}" ]; then echo "${WL_ECHO}"; else cat "${f}"; fi ;;
            *) echo "unexpected gh ${a}" >&2; return 1 ;;
        esac
    }
    export -f gh
    while IFS='|' read -r case payload oldest post rc want; do
        printf '%s' "$(_fill "${payload}")" > "${ev}"
        rm -f "${WL_POSTED}"; : > "${WL_LOG}"
        WL_OLDEST="$(_fill "${oldest}")" GITHUB_EVENT_PATH="${ev}" run bash "${CI_SH}" welcome
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "${post}" = - ]; then
            [ ! -e "${WL_POSTED}" ] || { echo "${case}: posted $(cat "${WL_POSTED}")"; return 1; }
        else
            [ "$(cat "${WL_POSTED}")" = "${T[${post}]}" ] || { echo "${case}: posted '$(cat "${WL_POSTED}")'"; return 1; }
            grep -qF "$(_fill 'q=repo:@R@ author:@U@ is:')${post}" "${WL_LOG}" || { echo "${case}: query $(cat "${WL_LOG}")"; return 1; }
        fi
    done <<'CASES'
issue-first|{"issue":{"number":@N@},"sender":{"login":"@U@","type":"User"}}||issue|0|welcome=posted kind=issue number=@N@
issue-itself|{"issue":{"number":@N@},"sender":{"login":"@U@","type":"User"}}|@N@|issue|0|welcome=posted kind=issue number=@N@
issue-older|{"issue":{"number":@N@},"sender":{"login":"@U@","type":"User"}}|@O@|-|0|welcome=skip kind=issue number=@N@ reason="author has an older issue (#@O@)"
pr-first|{"pull_request":{"number":@N@},"sender":{"login":"@U@","type":"User"}}||pr|0|welcome=posted kind=pr number=@N@
pr-older|{"pull_request":{"number":@N@},"sender":{"login":"@U@","type":"User"}}|@O@|-|0|welcome=skip kind=pr number=@N@ reason="author has an older pr (#@O@)"
bot|{"pull_request":{"number":@N@},"sender":{"login":"@U@","type":"Bot"}}||-|0|welcome=skip kind=pr number=@N@ reason="bot author"
no-sender|{"issue":{"number":@N@}}||-|2|[CI-ERROR-WELCOME-0001] kind=issue number=@N@
bad-login|{"issue":{"number":@N@},"sender":{"login":"a b","type":"User"}}||-|2|[CI-ERROR-WELCOME-0002];raw:
not-issue|{"ref":"@U@","sender":{"login":"@U@"}}||-|0|welcome=skip reason="not an issue or pull request event"
search-no-number|{"issue":{"number":@N@},"sender":{"login":"@U@","type":"User"}}|x@O@|-|2|[CI-ERROR-WELCOME-0003];raw:;x@O@
CASES
    printf '%s' "$(_fill '{"issue":{"number":@N@},"sender":{"login":"@U@","type":"User"}}')" > "${ev}"
    WL_ECHO="$(_val name)" GITHUB_EVENT_PATH="${ev}" run bash "${CI_SH}" welcome
    _expect stored-differs 2 '[CI-ERROR-WELCOME-0006];stored comment differs;raw:' || return 1
    WL_SEARCH_FAIL="$(_val name)" GITHUB_EVENT_PATH="${ev}" run bash "${CI_SH}" welcome
    _expect search-fails 2 "$(_fill '[CI-ERROR-BUILD-0011] op=github-api')" || return 1
    printf '%s' "$(_fill '{"pull_request":{"number":@N@},"sender":{"login":"@U@","type":"User"}}')" > "${ev}"
    sed '/^  welcome_pr:/,$d' "${m}" > "${m}.notext"
    CI_MANIFEST="${m}.notext" GITHUB_EVENT_PATH="${ev}" run bash "${CI_SH}" welcome
    _expect no-sot-text 2 '[CI-ERROR-WELCOME-0004] kind=pr' || return 1
}

# What: fixture repo + a fake action-manifest resolver.
# Why: one owner for the harness; asserts contract not curl.
# From: Issue #1683 | PR #1858
_anv_setup() {
    local r="$1"
    mkdir -p "${r}/.github/workflows" "${r}/.github/actions"
    _tool_stub "${r}" resolver <<'RS'
case "$4" in
  *deprecated*) printf 'OK\nname: x\nruns:\n  using: node16\n' ;;
  *notfound*)   printf 'NOTFOUND\n' ;;
  *infra*)      printf 'INFRA:403\n' ;;
  *)            printf 'OK\nname: x\nruns:\n  using: node24\n' ;;
esac
RS
}

# What: Run owner against fixture via fake resolver.
# Why: One call site for shared invocation (AG-CODE-011).
# From: Issue #1683 | PR #1858
_anv_run() {
    CI_ACTION_MANIFEST_CMD="$1/resolver" run bash "${CI_SH}" check action-node-versions "$1"
}

@test "action ref is external unless local, docker, or this repo" {
    # What: own repo (any case), ./ and docker:// are local.
    # Why: this repo comes from the run, never a literal.
    # From: Issue #1683 | PR #1858
    local v
    for v in ./a/b@x docker://img@x Owner/Fixture-Repo/.github/a@x owner/fixture-repo/b@y; do
        GITHUB_REPOSITORY=owner/fixture-repo run _ci_action_ref_is_external "${v}"
        [ "${status}" -eq 1 ] || { echo "want local: ${v}"; false; }
    done
    for v in other/tool@0a owner/other-repo/x@1b; do
        GITHUB_REPOSITORY=owner/fixture-repo run _ci_action_ref_is_external "${v}"
        [ "${status}" -eq 0 ] || { echo "want external: ${v}"; false; }
    done
    GITHUB_REPOSITORY=owner/fixture-repo run _ci_action_ref_is_external owner/fixture-repo
    [ "${status}" -eq 1 ]
}

@test "check action-node-versions passes current, fails deprecated runtimes" {
    # What: Current pins pass; dead runtime fails.
    # Why: Node-runtime invariant, no-manifest/skip.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvR"
    _anv_setup "${r}"
    mkdir -p "${r}/.github/actions/loc"
    printf 'name: L\nruns:\n  using: composite\n  steps: []\n' > "${r}/.github/actions/loc/action.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n      - uses: ./.github/actions/loc\n      - uses: ./.github/workflows/re.yml\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"
    [ "${status}" -eq 0 ] || { echo "${output}"; false; }
    [[ "${output}" == *"action-node-versions=clean"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-deprecated\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"node16"* ]]
    printf 'name: L\nruns:\n  using: node12\n  steps: []\n' > "${r}/.github/actions/loc/action.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/loc\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"node12"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/missing\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"no action.yml"* ]]
}

@test "check action-node-versions fails a broken pin and an unresolved one" {
    # What: NOTFOUND is a violation; infra fails closed.
    # Why: an unverified pin must never report clean.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvF"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-notfound\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -eq 1 ]; [[ "${output}" == *"broken pin"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-infra\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -eq 2 ]; [[ "${output}" == *"[CI-ERROR-CHECK-0073]"* ]]
    [[ "${output}" != *"action-node-versions=clean"* ]]
}

@test "action manifest fetch maps gh api results to OK/NOTFOUND/INFRA" {
    # What: dir list then file; 404 dir is NOTFOUND.
    # Why: one gh api owner; other failures are INFRA.
    # From: Issue #1683 | PR #1858
    local bin="${BIN}"; mkdir -p "${bin}"
    _tool_stub "${bin}" gh <<'EOF'
case "$*" in
    *"o/gone/contents"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    *"o/down/contents"*) echo "gh: HTTP 500" >&2; exit 1 ;;
    *"--jq"*) printf 'README.md\naction.yaml\n' ;;
    *"action.yaml?ref=r1") printf 'runs:\n  using: node24\n' ;;
    *) echo "unexpected: $*" >&2; exit 1 ;;
esac
EOF
    PATH="${bin}:${PATH}" CI_RETRY_MAX_ATTEMPTS=1 run _ci_fetch_action_manifest o act sub r1
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'OK\nruns:\n  using: node24')" ]
    PATH="${bin}:${PATH}" CI_RETRY_MAX_ATTEMPTS=1 run _ci_fetch_action_manifest o gone "" r1
    [ "${output##*$'\n'}" = "NOTFOUND" ]
    PATH="${bin}:${PATH}" CI_RETRY_MAX_ATTEMPTS=1 run _ci_fetch_action_manifest o down "" r1
    [ "${output##*$'\n'}" = "INFRA" ]
}

@test "check action-node-versions enforces ref hygiene" {
    # What: Literal repeat/cross-file drift fail; anchor ok.
    # Why: One canonical ref per key; anchors unload.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvH"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n      - uses: o/act@ref-ok\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"repeats third-party ref"* ]]
    rm "${r}/.github/workflows/ci.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n' > "${r}/.github/workflows/a.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-two\n' > "${r}/.github/workflows/b.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"multiple refs"* ]]
    rm "${r}/.github/workflows/b.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: &a o/act@ref-ok\n  c:\n    steps:\n      - uses: *a\n' > "${r}/.github/workflows/a.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
    rm "${r}/.github/workflows/a.yml"
    mkdir -p "${r}/.github/actions/cmp"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/cmp\n' > "${r}/.github/workflows/ci.yml"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: o/act@ref-ok\n    - uses: o/act@ref-ok\n' > "${r}/.github/actions/cmp/action.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "check action-node-versions fails a description expression, allows prose" {
    # What: Expression in description fails; prose ok.
    # Why: Manifest validator evaluates descriptions.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvD"
    _anv_setup "${r}"
    mkdir -p "${r}/.github/actions/x"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/x\n' > "${r}/.github/workflows/ci.yml"
    printf 'name: X\ndescription: >-\n  see %s here\nruns:\n  using: composite\n  steps: []\n' '${{ inputs.y }}' > "${r}/.github/actions/x/action.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"description: field contains"* ]]
    printf 'name: X\ndescription: plain prose\nruns:\n  using: composite\n  steps:\n    - run: echo %s\n      shell: bash\n' '${{ y }}' > "${r}/.github/actions/x/action.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "check action-node-versions aggregates failures, separates extraction" {
    # What: All bad pins; run/alias extraction.
    # Why: One run surfaces every defect.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvA"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/one@ref-deprecated\n      - uses: o/two@ref-deprecated\n      - run: |\n          echo "uses: o/three@ref-deprecated"\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]
    [[ "${output}" == *"o/one@ref-deprecated"* ]]; [[ "${output}" == *"o/two@ref-deprecated"* ]]; [[ "${output}" != *"o/three"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: *undefined\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"unresolved YAML alias"* ]]
}

@test "check all diff-scopes its checks and gates PR checks on PR context" {
    # What: Stub dispatcher; record check-all invokes.
    # Why: Prove scope+gating without 36 checks.
    # From: Issue #1683
    local log="${BATS_TEST_TMPDIR}/checkall.calls"; : > "${log}"
    ci_cmd_check() { printf '%s|%s\n' "$1" "${2:-}" >> "${log}"; return 0; }
    CHANGED_FILES="" PR_NUMBER="" ci_cmd_check_all services/dns/Dockerfile
    grep -qx 'line-endings|services/dns/Dockerfile' "${log}"
    grep -qx 'action-node-versions|' "${log}"
    grep -qx 'ci-bats|services/dns/Dockerfile' "${log}"
    grep -qx 'exit-evidence|services/dns/Dockerfile' "${log}"
    grep -qx 'dockerfile-secret-ids|' "${log}"
    grep -qx 'sot-identity-inputs|' "${log}"
    grep -qx 'workflow-ci-variables|' "${log}"
    grep -qx 'workflow-job-settings|' "${log}"
    ! grep -q '^pr-title|' "${log}"
}

# What: changed file -> skip only for a shell comment.
# Why: arch doc Test B/C/D; unproven changes run it.
# From: Issue #1683 | PR #1858
@test "ci-bats gate: only a shell comment change skips the suite" {
    local r base head case path body want id
    local -A V=(
        [@B@]="$(_val name).bats" [@L@]="$(_val name).sh" [@N@]="$(_val name).md" [@NEW@]="$(_val name).sh"
        [@Y@]="$(_val name).yml" [@RS@]="$(_val name).rs" [@C1@]="$(_val name)" [@C2@]="$(_val name)"
        [@FN@]="$(_val name)" [@E1@]="$(_val name)" [@E2@]="$(_val name)" [@D@]="$(_val name)"
        [@H1@]="$(_val name)" [@H2@]="$(_val name)" [@MAIL@]="$(_val name)@$(_val host)" [@WHO@]="$(_val name)"
        [@U@]="$(_val name).sh"
    )
    V[@README@]="$(_ci_variable CI_README)"
    run _ci_check_ci_bats "${V[@N@]}"
    _expect nested 0 '=ci-bats=NOT-RUN reason="already inside a bats run; no nested suite"' || return 1
    r="$(_val path)"
    git init -q "${r}"
    mkdir -p "$(dirname "${r}/${V[@README@]}")"
    _fill "$(printf '%s\n' '@test "@C1@" {' '  # @C1@' '  true' '}')" > "${r}/${V[@B@]}"
    _fill "$(printf '%s\n' '@FN@() {' '  # @C1@' '  echo @E1@' '}' 'cat <<@D@' '# @H1@' '@D@')" > "${r}/${V[@L@]}"
    _fill "$(printf '%s\n' '// @C1@' 'fn main() {}')" > "${r}/${V[@RS@]}"
    _fill "$(printf '%s\n' 'echo "@E1@' '# @C1@')" > "${r}/${V[@U@]}"
    printf '%s\n' "${V[@C1@]}" > "${r}/${V[@N@]}"
    printf '%s\n' "${V[@C1@]}" > "${r}/${V[@README@]}"
    git -C "${r}" add -A
    git -C "${r}" -c user.email="${V[@MAIL@]}" -c user.name="${V[@WHO@]}" commit -qm base
    base="$(git -C "${r}" rev-parse HEAD)"
    while IFS='|' read -r case path body want id; do
        git -C "${r}" checkout -q "${base}"
        printf '%b' "$(_fill "${body}")" > "${r}/$(_fill "${path}")"
        git -C "${r}" add -A
        git -C "${r}" -c user.email="${V[@MAIL@]}" -c user.name="${V[@WHO@]}" commit -qm "${case}"
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
    CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push BEFORE_SHA='' GITHUB_SHA="${head}" run _ci_test_identity_gate "${V[@B@]}"
    _expect no-base 0 '[CI-INFO-TESTID-0004]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-base: ${output}"; return 1; }
    run _ci_test_identity_gate
    _expect no-files 0 '[CI-INFO-TESTID-0001]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-files: ${output}"; return 1; }
}

@test "check all runs PR-metadata checks when a PR number is present" {
    # What: PR_NUMBER set invokes PR checks.
    # Why: PR checks only on PR (§60).
    # From: Issue #1683
    local cf="${BATS_TEST_TMPDIR}/checkall.cf"; printf 'services/dns/Dockerfile\n' > "${cf}"
    local log="${BATS_TEST_TMPDIR}/checkall.pr"; : > "${log}"
    ci_cmd_check() { printf '%s\n' "$1" >> "${log}"; return 0; }
    CHANGED_FILES="${cf}" PR_NUMBER=42 ci_cmd_check_all
    grep -qx 'pr-title' "${log}"
    grep -qx 'pr-tracking-metadata' "${log}"
}

@test "docs-only holds only for docs no SOT key names" {
    # What: per row: changed paths -> docs-only rc, reason.
    # Why: docs are NOOP (§63) unless the SOT reads them.
    # From: Issue #1683 | PR #1858
    local m case sot paths rc want
    local -a av
    local -A V=(
        [@VAR@]="$(_val var)" [@D@]="$(_val name)" [@NAMED@]="$(_val name)" [@STATE@]="$(_val name)"
        [@GOV@]="$(_val name)" [@X@]="$(_val name)" [@Y@]="$(_val name)" [@C@]="$(_val name)"
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

@test "every git transport fails closed without the SOT remote" {
    # What: per caller: no CI_GIT_REMOTE -> rc 2 + coded id.
    # Why: a missing remote key stops before any git call.
    # From: Issue #1683 | PR #1858
    local m r case pre call
    local -A V=(
        [@N@]="$(_val name)" [@SHA@]="$(_val sha)" [@TAG@]="v$(_val semver)" [@PREV@]="v$(_val semver)"
    )
    m="$(_val path)" r="$(_val path)"
    grep -v '^  CI_GIT_REMOTE:' "${CI_MANIFEST}" > "${m}"
    git init -q "${r}"
    git -C "${r}" -c user.name="$(_val name)" -c user.email="$(_val name)@$(_val host)" commit -q --allow-empty -m "$(_val name)"
    while IFS='|' read -r case pre call; do
        [ "${pre}" != - ] || pre=:
        run env -u CI_GIT_REMOTE CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" GITHUB_REPOSITORY="$(_val name)/$(_val name)" \
            bash -c 'cd "$2" && source "$1" && eval "$3" && eval "$4"' _ "${CI_SH}" "${r}" "$(_fill "${pre}")" "$(_fill "${call}")"
        _expect "${case}" 2 '[CI-ERROR-VARIABLES-0001] name="CI_GIT_REMOTE"' || return 1
    done <<'CASES'
ref-tip|-|_ci_ref_tip refs/heads/@N@
last-release-tag|-|_ci_last_release_tag
diff-history|-|GITHUB_EVENT_NAME=pull_request BASE_SHA=@SHA@ GITHUB_REF=refs/heads/@N@ _ci_diff_history
release-changes|_ci_last_release_tag() { echo @PREV@; }|_ci_release_changes @TAG@
release-changelog|_ci_release_changes() { echo @N@; }|CI_DEFAULT_BRANCH=@N@ ci_cmd_release_changelog @TAG@
chronology-diff|-|CHRONOLOGY_DIFF_BASE_REF=@N@ GITHUB_SHA=@SHA@ _ci_review_chronology_diff_files
CASES
}

@test "check shellcheck noops without shell files and fails on findings" {
    # What: Injected shellcheck; prove noop/fail.
    # Why: Real shellcheck needs toolchain; hook it.
    # From: Issue #1683
    local cf="${BATS_TEST_TMPDIR}/sc.cf" doc="${BATS_TEST_TMPDIR}/note.md"
    : > "${doc}"
    printf '%s\n' "${doc}" > "${cf}"
    CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shellcheck=noop"* ]]
    local sh="${BATS_TEST_TMPDIR}/fixture.sh"; : > "${sh}"
    printf '%s\n' "${sh}" > "${cf}"
    CI_SHELLCHECK_CMD="$(_stub 'exit 1')" CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0056"* ]]
}

@test "check shellcheck runs per file; a killed run is no finding" {
    # What: one call per file; rc>1 is CHECK-0113, rc 2.
    # Why: an OOM kill (137) read as "found issues".
    # From: Issue #1683 | PR #1858
    local cf="${BATS_TEST_TMPDIR}/sc.cf" log="${BATS_TEST_TMPDIR}/sc.log"
    local a="${BATS_TEST_TMPDIR}/a.sh" b="${BATS_TEST_TMPDIR}/b.bats"
    : > "${a}"; : > "${b}"
    printf '%s\n' "${a}" "${b}" > "${cf}"
    CI_SHELLCHECK_CMD="$(_stub "echo \"\$#:\$1\" >> '${log}'")" CHANGED_FILES="${cf}" \
        run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shellcheck=clean files=2"* ]]
    [ "$(cat "${log}")" = "$(printf '1:%s\n1:%s' "${a}" "${b}")" ]
    CI_SHELLCHECK_CMD="$(_stub 'echo raw-oom >&2; exit 137')" CHANGED_FILES="${cf}" \
        run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0113"*"rc=137"* ]]
    [[ "${output}" == *"raw-oom"* ]]
    [[ "${output}" != *"CI-ERROR-CHECK-0056"* ]]
}

@test "check shellcheck lints a .bats file one @test per run" {
    # What: own-test hits, all-run top-level hits, no leaks.
    # Why: one run per @test is how bats runs each test.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}" f cf
    f="${d}/fx.bats" cf="${d}/sc.cf"
    printf '%s\n' '#!/usr/bin/env bats' 'export TOPV="$(printf x)"' 'topu=1' \
        '@test "one" {' '    grep -x a <<< "a" >/dev/null' '    export M1="$(printf x)"' '}' \
        '@test "two" {' "    cat <<'EOF'" '}' '@test "fake" {' 'EOF' '    echo $(printf b) >/dev/null' \
        '    echo "${topu}"' '}' '@test "three" {' '    xs=(a b); echo "${xs[@]}"' '}' \
        '@test "four" {' '    xs="s"; echo "${xs}"' '}' > "${f}"
    printf '%s\n' "${f}" > "${cf}"
    CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 1 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"[CI-INFO-CHECK-0155] file=\"${f}\" tests=4 "* ]] || { echo "${output}"; return 1; }
    [ "$(grep -c "^${f}:2:[0-9]*: .*\[SC2155\]" <<< "${output}")" -eq 1 ] || { echo "${output}"; return 1; }
    grep -q "^${f}:6:[0-9]*: .*\[SC2155\]" <<< "${output}" || { echo "${output}"; return 1; }
    grep -q "^${f}:13:[0-9]*: .*\[SC2046\]" <<< "${output}" || { echo "${output}"; return 1; }
    ! grep -qE '\[SC(2178|2034)\]' <<< "${output}" || { echo "cross-test leak: ${output}"; return 1; }
    # What: an @test without its closing } stops the check.
    # Why: a guessed range could hide a finding.
    # From: Issue #1683 | PR #1858
    printf '%s\n' '#!/usr/bin/env bats' '@test "open" {' '    true' > "${f}"
    CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 2 ] && [[ "${output}" == *"[CI-ERROR-CHECK-0154]"*"no closing }"* ]] || { echo "${output}"; return 1; }
}

@test "check actionlint passes clean and fails on findings" {
    # What: injected actionlint; prove pass/fail.
    # Why: Real actionlint needs toolchain; hook it.
    # From: Issue #1683
    CI_ACTIONLINT_CMD="$(_stub 'exit 0')" run bash "${CI_SH}" check actionlint
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"actionlint=clean"* ]]
    CI_ACTIONLINT_CMD="$(_stub 'exit 1')" run bash "${CI_SH}" check actionlint
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0057"* ]]
}

@test "check cargo-audit passes clean, fails on advisory and on warnings" {
    # What: Injected auditor; prove pass/fail.
    # Why: Real cargo audit needs toolchain; hook it.
    # From: Issue #1683
    CI_CARGO_AUDIT_CMD="$(_stub 'exit 0')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo-audit=clean"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub 'echo "error: vulnerability RUSTSEC-x"; exit 1')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0055"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub 'echo "warning: yanked crate"; exit 0')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0055"* ]]
}

@test "check dockerfile-build-tools flags both image and hardcoded-tuning violations" {
    # What: Rust Dockerfiles use build-tools, no tuning.
    # Why: AG-CI-008/AG-REL-002 (image) + AG-CI-006.
    # From: Issue #1683
    run bash "${CI_SH}" check dockerfile-build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dockerfile-build-tools=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/dfrepo" s ctx n=0 rust
    rust="$(_svcs_of_type rust)"
    while IFS= read -r s; do
        [ -n "${s}" ] || continue
        ctx="$(ci_service_field "$s" context)"
        mkdir -p "${r}/${ctx}"
        case "${n}" in
            0) printf 'FROM alpine\nRUN cargo install sccache\n' > "${r}/${ctx}/Dockerfile" ;;
            1) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nENV CARGO_BUILD_JOBS=4\n' > "${r}/${ctx}/Dockerfile" ;;
            *) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nARG PROJECT_CARGO_LTO=\n' > "${r}/${ctx}/Dockerfile" ;;
        esac
        n=$((n + 1))
    done <<< "${rust}"
    run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0058"* ]]
    [[ "${output}" == *"CI-ERROR-CHECK-0060"* ]]
    local bvars bv first
    bvars="$(_ci_block_entry_list build_variables "" rust)" first="${bvars%%$'\n'*}"
    s="$(awk 'NR == 1' <<< "${rust}")" ctx="$(ci_service_field "${s}" context)"
    { printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\n'; awk 'NR > 1 { print "ARG " $0 }' <<< "${bvars}"
        printf 'RUN bash /usr/local/bin/ci.sh rust-build %s %s\n' "${s}" "$(_val name)"; } > "${r}/${ctx}/Dockerfile"
    run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    [[ "${output}" == *"${s}: Dockerfile stage 1 runs ci.sh rust-build without ARG ${first} (SOT"* ]] \
        || { echo "missing ${first}: ${output}"; return 1; }
    for bv in $(awk 'NR > 1' <<< "${bvars}"); do
        [[ "${output}" != *"${s}: Dockerfile stage 1 runs ci.sh rust-build without ARG ${bv} (SOT"* ]] \
            || { echo "declared ${bv} flagged"; return 1; }
    done
    { printf 'ARG BUILD_TOOLS_IMAGE\n'; awk '{ print "ARG " $0 }' <<< "${bvars}"
        printf 'FROM ${BUILD_TOOLS_IMAGE}\nRUN bash /usr/local/bin/ci.sh rust-build %s %s\n' "${s}" "$(_val name)"; } > "${r}/${ctx}/Dockerfile"
    run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    for bv in ${bvars}; do
        [[ "${output}" == *"${s}: Dockerfile stage 1 runs ci.sh rust-build without ARG ${bv} (SOT"* ]] \
            || { echo "pre-FROM ARG ${bv} not flagged: ${output}"; return 1; }
    done
}

@test "check dockerfile-build-tools flags a mutable BUILD_TOOLS_IMAGE default" {
    # What: rust Dockerfile ARG must carry no default.
    # Why: ci.sh supplies the immutable ref (AG-CI-008).
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/md-manifest.yml" r="${BATS_TEST_TMPDIR}/mdrepo"
    printf 'services:\n  svc-rust:\n    context: c\n    build_type: rust\n' > "${m}"
    mkdir -p "${r}/c"
    printf 'ARG BUILD_TOOLS_IMAGE=x:latest\nFROM ${BUILD_TOOLS_IMAGE}\n' > "${r}/c/Dockerfile"
    CI_MANIFEST="${m}" run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must carry no default"* ]]
}

@test "check dockerfile-build-tools allows only a scratch FROM fallback" {
    # What: FROM forms of BUILD_TOOLS_IMAGE, one table.
    # Why: scratch bakes no image; any other default would.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/sf-manifest.yml" r name from want
    printf 'services:\n  svc-rust:\n    context: c\n    build_type: rust\n' > "${m}"
    while IFS='|' read -r name from want; do
        r="${BATS_TEST_TMPDIR}/sf-${name}"; mkdir -p "${r}/c"
        printf 'ARG BUILD_TOOLS_IMAGE\n%s\n' "${from}" > "${r}/c/Dockerfile"
        CI_MANIFEST="${m}" run bash "${CI_SH}" check dockerfile-build-tools "${r}"
        case "${want}" in
            clean) [ "${status}" -eq 0 ] ;;
            *) [ "${status}" -ne 0 ] && [[ "${output}" == *"${want}"* ]] ;;
        esac || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
plain|FROM ${BUILD_TOOLS_IMAGE} AS b|clean
scratch|FROM ${BUILD_TOOLS_IMAGE:-scratch} AS b|clean
other-default|FROM ${BUILD_TOOLS_IMAGE:-alpine:3.24} AS b|must build FROM
CASES
}

@test "check cargo-profile-tuning flags hardcoded [profile] lto/codegen-units" {
    # What: Cargo.toml cannot set [profile] lto/codegen.
    # Why: From CARGO_PROFILE_RELEASE env (AG-CI-006).
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/cptrepo"
    mkdir -p "${r}/crate-a" "${r}/crate-b"
    printf '[package]\nname = "a"\n\n[profile.release]\n# no tuning here\n' > "${r}/crate-a/Cargo.toml"
    printf '[package]\nname = "b"\n\n[profile.release]\nlto = "thin"\ncodegen-units = 1\n' > "${r}/crate-b/Cargo.toml"
    git -C "${r}" init -q
    git -C "${r}" add -A
    run bash "${CI_SH}" check cargo-profile-tuning "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0059"* ]]
    [[ "${output}" == *"crate-b/Cargo.toml"* ]]
    printf '[package]\nname = "b"\n\n[profile.release]\n' > "${r}/crate-b/Cargo.toml"
    git -C "${r}" add -A
    run bash "${CI_SH}" check cargo-profile-tuning "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo-profile-tuning=clean"* ]]
}

@test "check no-source-compiled-tools flags cargo install of a prebuilt SOT tool" {
    # What: Dockerfile cannot cargo-install SOT tools.
    # Why: INSTALL-DON'T-COMPILE; build-tools owner.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/nsctrepo" pkg
    pkg="$(_ci_build_tools_packages | grep -E '^(sccache|cargo-audit)$')"
    pkg="${pkg%%$'\n'*}"
    [ -n "${pkg}" ]
    mkdir -p "${r}/svc-a" "${r}/svc-b"
    printf 'FROM alpine\nRUN cargo build --release --locked\n' > "${r}/svc-a/Dockerfile"
    printf 'FROM alpine\nRUN cargo install --locked %s\n' "${pkg}" > "${r}/svc-b/Dockerfile"
    git -C "${r}" init -q
    git -C "${r}" add -A
    run bash "${CI_SH}" check no-source-compiled-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0061"* ]]
    [[ "${output}" == *"${pkg}"* ]]
    printf 'FROM alpine\nRUN cargo build --release --locked\n' > "${r}/svc-b/Dockerfile"
    git -C "${r}" add -A
    run bash "${CI_SH}" check no-source-compiled-tools "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no-source-compiled-tools=clean"* ]]
}

@test "stack-candidate reader: full SOT stack, fail-closed on every failure, no stray services" {
    # What: Exact multi-arch digests for SOT (§48).
    # Why: Candidate feeds validate/promote, fail closed.
    # From: Issue #1683
    _ci_collect_accepted_digests() { printf 'os/p1=sha256:a\nos/p2=sha256:b\n'; }
    _ci_reconcile_index() { printf 'sha256:idx-%s\n' "$1"; }
    run _ci_stack_candidate_ledger
    [ "${status}" -eq 0 ]
    # A: exactly one service=digest per SOT product service (count from ci_services)
    local s expected actual
    expected="$(ci_services | grep -c .)"
    actual="$(printf '%s\n' "${output}" | grep -c '=sha256:idx-')"
    [ "${actual}" -eq "${expected}" ]
    for s in $(ci_services); do
        [[ "${output}" == *"${s}=sha256:idx-${s}"* ]]
    done
    # E: no toolchain member (build-tools is not a product-stack service)
    [[ "${output}" != *"build-tools=sha256"* ]]
    # B: a collect failure propagates non-zero (no partial, no skip)
    _ci_collect_accepted_digests() { return 2; }
    _ci_reconcile_index() { printf 'sha256:idx\n'; }
    run _ci_stack_candidate_ledger
    [ "${status}" -ne 0 ]
    # C: a reconcile divergence propagates non-zero
    _ci_collect_accepted_digests() { printf 'os/p1=sha256:a\n'; }
    _ci_reconcile_index() { return 2; }
    run _ci_stack_candidate_ledger
    [ "${status}" -ne 0 ]
    # D: platforms accepted but no assembled index -> CANDIDATE-0001 (distinct state)
    _ci_reconcile_index() { printf '\n'; }
    run _ci_stack_candidate_ledger
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CANDIDATE-0001"* ]]
}

@test "emit-result produces an ACCEPTED record and fails closed on a missing digest" {
    # What: Single aggregator record per service/platform.
    # Why: ACCEPTED state with exact GHCR digest.
    # From: Issue #1683
    _ci_require_ghcr_auth() { return 0; }
    _ci_identity_for() { echo "id-$1"; }
    _ci_image_tag() { echo "reg/$1:$3"; }
    _ci_registry_digest() { echo "sha256:deadbeef"; }
    run ci_cmd_emit_result svc-a os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"service":"svc-a"'* ]]
    [[ "${output}" == *'"state":"ACCEPTED"'* ]]
    [[ "${output}" == *'"digest":"sha256:deadbeef"'* ]]
    _ci_registry_digest() { return 1; }
    run ci_cmd_emit_result svc-a os/p1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-RESULT-0003"* ]]
}

@test "aggregate-stack emits one result per matrix pair then one ledger write" {
    # What: Matrix->emit->aggregate per pair (§26.1).
    # Why: Iteration in ci.sh; workflow thin.
    # From: Issue #1683
    ci_cmd_emit_result() { printf 'emit %s %s\n' "$1" "$2"; }
    local seen="${BATS_TEST_TMPDIR}/agg-dir"
    ci_cmd_aggregate() { ls "$1" | LC_ALL=C sort | tr '\n' ' ' > "${seen}"; }
    export CI_BUILD_MATRIX='{"include":[{"service":"dns","platform":"os/p1"},{"service":"ui","platform":"os/p2"}]}'
    export CI_TMPDIR="${BATS_TEST_TMPDIR}"
    run ci_cmd_aggregate_stack
    [ "${status}" -eq 0 ]
    run cat "${seen}"
    [[ "${output}" == *"dns-os-p1.json"* ]]
    [[ "${output}" == *"ui-os-p2.json"* ]]
    unset CI_BUILD_MATRIX
    run ci_cmd_aggregate_stack
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0005"* ]]
}

@test "scan-stack scans each built matrix pair and fails closed on a missing digest/matrix" {
    # What: SCAN before ACCEPT per pair (§7).
    # Why: Missing digest/matrix fails closed.
    # From: Issue #1683
    _ci_require_ghcr_auth() { return 0; }
    _ci_identity_for() { echo "id-$1"; }
    _ci_image_tag() { echo "reg/$1:$3"; }
    _ci_registry_digest() { echo "sha256:d-$1"; }
    local calls="${BATS_TEST_TMPDIR}/scan-calls"
    : > "${calls}"
    ci_cmd_scan() { printf 'scan %s %s\n' "$1" "$2" >> "${calls}"; }
    export CI_BUILD_MATRIX='{"include":[{"service":"svc-a","platform":"os/p1"},{"service":"svc-b","platform":"os/p2"}]}'
    run ci_cmd_scan_stack
    [ "${status}" -eq 0 ]
    run cat "${calls}"
    [[ "${output}" == *"scan svc-a "* ]]
    [[ "${output}" == *"scan svc-b "* ]]
    : > "${calls}"
    CI_BUILD_MATRIX='not-json' run ci_cmd_scan_stack
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0006"* ]]
    [ ! -s "${calls}" ]
    _ci_registry_digest() { return 1; }
    run ci_cmd_scan_stack
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0017"* ]]
    unset CI_BUILD_MATRIX
    run ci_cmd_scan_stack
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0016"* ]]
}

@test "producer check fails a loop producer rc above max" {
    # What: rc above max is CORE-0010; at or below passes.
    # Why: a failed producer must not look like no results.
    # From: Issue #1683 | PR #1858
    run _ci_producer_ok 3 0
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0010"*"rc=3"* ]]
    run _ci_producer_ok 1 1
    [ "${status}" -eq 0 ]
    run _ci_producer_ok 2 1
    [ "${status}" -eq 2 ]
}

# What: SOT pin consumers -> dep|Dockerfile|keys, or the id.
# Why: the SOT consumer field owns it; no engine-side list.
# From: Issue #1683 | PR #1858
@test "version consumers come from the SOT consumer and build_args" {
    local m nokeys
    local -A V=(
        [@S@]="$(_val name)" [@T@]="$(_val name)" [@CS@]="$(_val name)/$(_val name)" [@CT@]="$(_val name)/$(_val name)"
        [@D1@]="$(_val name)" [@D2@]="$(_val name)" [@D3@]="$(_val name)" [@K1@]="$(_val name)" [@K2@]="$(_val name)"
        [@K3@]="$(_val name)" [@V@]="$(_val semver)"
    )
    m="$(_val path)"
    nokeys="$(_val path)"
    _fill "$(printf '%s\n' 'services:' '  @S@:' '    context: @CS@' 'build_toolchain:' '  @T@:' '    context: @CT@' \
        'external_versions:' '  @D1@:' '    consumer: @S@' '    build_args: [@K1@, @K2@]' \
        '  @D2@:' '    version: @V@' '  @D3@:' '    consumer: @T@' '    build_args: [@K3@]')" > "${m}"
    _fill "$(printf '%s\n' 'services:' '  @S@:' '    context: @CS@' 'external_versions:' '  @D1@:' '    consumer: @S@')" > "${nokeys}"
    CI_MANIFEST="${m}" run _ci_version_consumers
    _expect consumers 0 "=$(_fill '@D1@|@CS@/Dockerfile|@K1@ @K2@')"$'\n'"$(_fill '@D3@|@CT@/Dockerfile|@K3@')" || return 1
    CI_MANIFEST="${nokeys}" run _ci_version_consumers
    _expect no-build-args 2 "$(_fill '[CI-ERROR-VERSION-0010] dep="@D1@"')" || return 1
}

@test "nightly-status opens, updates, and closes the standing tracking issue" {
    # What: Self-closing issue per outcome.
    # Why: Fail=open/update, success=close.
    # From: Issue #1683
    local stub="${BATS_TEST_TMPDIR}/ghstub" calls="${BATS_TEST_TMPDIR}/gh-calls"
    _tool_stub "${BATS_TEST_TMPDIR}" ghstub <<'EOF'
echo "$*" >> "${GH_CALLS}"
[ "$1 $2" = "issue list" ] && printf '%s' "${STUB_EXISTING:-}"
[ "$1 $2" = "label create" ] && [ -n "${STUB_LABEL_FAIL:-}" ] && { echo "HTTP 403" >&2; exit 1; }
exit 0
EOF
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1
    : > "${calls}"; STUB_EXISTING='' CI_NIGHTLY_STATUS_CMD="${stub}" run ci_cmd_nightly_status failure "nightly promote"
    [ "${status}" -eq 0 ]; grep -q 'issue create' "${calls}"
    grep -q '^label create nightly-broken .*--force' "${calls}"
    : > "${calls}"; STUB_LABEL_FAIL=1 STUB_EXISTING='' CI_NIGHTLY_STATUS_CMD="${stub}" run ci_cmd_nightly_status failure "nightly promote"
    [ "${status}" -eq 2 ]
    if grep -q 'issue create' "${calls}"; then return 1; fi
    : > "${calls}"; STUB_EXISTING=42 CI_NIGHTLY_STATUS_CMD="${stub}" run ci_cmd_nightly_status failure "nightly promote"
    [ "${status}" -eq 0 ]; grep -q 'issue comment 42' "${calls}"
    : > "${calls}"; STUB_EXISTING=42 CI_NIGHTLY_STATUS_CMD="${stub}" run ci_cmd_nightly_status success "nightly promote"
    [ "${status}" -eq 0 ]; grep -q 'issue close 42' "${calls}"
    : > "${calls}"; STUB_EXISTING='' CI_NIGHTLY_STATUS_CMD="${stub}" run ci_cmd_nightly_status success "nightly promote"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"noop"* ]]
    run ci_cmd_nightly_status "" scope
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-STATUS-0001"* ]]
}

@test "check governance-guards flags a stale TODO on a closed issue" {
    # What: ci.sh owns the governance scan; bats calls it.
    # Why: TODO on closed issue is stale, must fail loud.
    # From: Issue #1683
    printf '# %s(#42): revisit once fixed\n' TODO > "${BATS_TEST_TMPDIR}/stale.sh"
    CI_GOVERNANCE_ISSUE_STATE='42=closed' \
        run bash "${CI_SH}" check governance-guards "${BATS_TEST_TMPDIR}/stale.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0018"* ]]
    CI_GOVERNANCE_ISSUE_STATE='42=open' \
        run bash "${CI_SH}" check governance-guards "${BATS_TEST_TMPDIR}/stale.sh"
    [ "${status}" -eq 0 ]
}

@test "check governance-guards fails closed when the issue state is unknown" {
    # What: a failed gh api lookup is rc 2, never clean.
    # Why: an unchecked TODO must not pass as current.
    # From: Issue #1683
    local bin="${BIN}"; mkdir -p "${bin}"
    _tool_stub "${bin}" gh <<'STUB'
echo "gh: HTTP 500" >&2; exit 1
STUB
    printf '# %s(#42): revisit once fixed\n' TODO > "${BATS_TEST_TMPDIR}/t.sh"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo CI_RETRY_MAX_ATTEMPTS=1 \
        run bash "${CI_SH}" check governance-guards "${BATS_TEST_TMPDIR}/t.sh"
    [ "${status}" -eq 2 ]
    [[ "${output}" != *"governance-guards=clean"* ]]
}

@test "check governance-guards requires an open Refs issue for partial-scope text" {
    # What: Partial-scope text needs open issue reference.
    # Why: Prevent merging known-incomplete changes.
    # From: Issue #1683
    GOVERNANCE_PR_BODY='This is a partial fix, TODO later.' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -ne 0 ]
    GOVERNANCE_PR_BODY='This is a partial fix. Refs #7' CI_GOVERNANCE_ISSUE_STATE='7=open' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -eq 0 ]
    GOVERNANCE_PR_BODY='No TODO items left, nothing deferred here.' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -eq 0 ]
}

@test "check governance-guards flags a malformed PR-body upload" {
    # What: Literal @/tmp is upload path, not text.
    # Why: Upload mistake must not pass.
    # From: Issue #1683 | PR #1858
    GOVERNANCE_PR_BODY='@/tmp/pr-body-1234.txt' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0018"* ]]
    [[ "${output}" == *"@/tmp"* ]]
}

@test "check naming-consistency requires rust container names in compose" {
    # What: ui and watchdog names must be compose container names
    # Why: a Docker call by a name compose never creates fails
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/repo" cfg name project
    cfg="$(_real_deploy_json)"
    project="$(jq -r '.name' <<< "${cfg}")"
    [ -n "${project}" ] || { echo "no project name in the real compose"; return 1; }
    _stack_fixture "${r}"
    _dsp_compose "${project}" "${r}/dep" > "${r}/dep/c.yml"
    _dsp_compose "${project}" "${r}/inst" > "${r}/inst/c.yml"
    name="$(_ci_compose_json "${r}/dep/c.yml" | jq -r '[.services[].container_name // empty] | first // empty')"
    [ -n "${name}" ] || { echo "no fixture container name"; return 1; }
    mkdir -p "${r}/services/watchdog/src" "${r}/services/ui/src"
    printf 'const DEFAULT_PROXY: &str = "%s";\n' "${name}" > "${r}/services/watchdog/src/config.rs"
    printf '"x" => "%s",\n' "${name}" > "${r}/services/ui/src/docker_client.rs"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 0 ] || { echo "clean: ${output}"; return 1; }
    printf 'const DEFAULT_PROXY: &str = "%s-other";\n' "${name}" > "${r}/services/watchdog/src/config.rs"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"CI-ERROR-CHECK-0096"*"'${name}-other' is no container_name in"* ]] \
        || { echo "watchdog: ${output}"; return 1; }
    printf 'const DEFAULT_PROXY: &str = "%s";\n' "${name}" > "${r}/services/watchdog/src/config.rs"
    printf '"x" => "%s-x",\n' "${name}" > "${r}/services/ui/src/docker_client.rs"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"docker_client.rs: '${name}-x' is no container_name in"* ]] \
        || { echo "ui: ${output}"; return 1; }
    printf '"x" => "%s",\n' "${name}" > "${r}/services/ui/src/docker_client.rs"
    _dsp_compose "${project}-other" "${r}/dep" > "${r}/dep/c.yml"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"compose project name '${project}-other' is not ${project}"* ]] \
        || { echo "project: ${output}"; return 1; }
    # What: no match is a named violation via the CLI.
    # Why: errexit must not end the check without a code.
    # From: Issue #1683 | PR #1858
    _dsp_compose "${project}" "${r}/dep" > "${r}/dep/c.yml"
    printf 'fn main() {}\n' > "${r}/services/watchdog/src/config.rs"
    run bash "${CI_SH}" check naming-consistency "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"CI-ERROR-CHECK-0096"*"no lancache-* container names found"* ]] \
        || { echo "cli: ${output}"; return 1; }
}

@test "check compose-healthchecks passes clean on the real repo" {
    # What: migrated from check-compose-healthchecks.sh.
    # Why: rewritten in ci.sh; real stack composes pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check compose-healthchecks
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"compose-healthchecks=clean"* ]]
}

@test "check compose-healthchecks fails a service with no healthcheck" {
    # What: a real, un-excluded service has no healthcheck.
    # Why: Every service needs healthcheck.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/nohc/docker-compose.yml"
    mkdir -p "$(dirname "${f}")"
    printf 'services:\n  good:\n    image: x\n    healthcheck:\n      test: ["CMD", "true"]\n  bad:\n    image: y\n' \
        > "${f}"
    run bash "${CI_SH}" check compose-healthchecks "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0021"* ]]
    [[ "${output}" == *"service 'bad' has no healthcheck"* ]]
}

@test "check compose-healthchecks honors the documented exclusion list" {
    # What: dhcp-probe is documented as exempt, not a fail.
    # Why: Exclusion contract still applies.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/excl/dep/c.yml"
    mkdir -p "$(dirname "${f}")"
    printf 'services:\n  dhcp-probe:\n    image: x\n' > "${f}"
    run bash "${CI_SH}" check compose-healthchecks "${f}"
    [ "${status}" -eq 0 ]
}

@test "check compose-healthchecks fails closed with no compose files" {
    # What: a vacuous scan (no matched files) must not pass.
    # Why: mirrors the legacy script's anti-vacuous guard.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check compose-healthchecks "${BATS_TEST_TMPDIR}/nope/docker-compose.yml"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0097"* ]]
}

@test "check proxy-cache-env-doc-drift passes clean on the real repo" {
    # What: every documented CACHE_* row is checked, clean
    # Why: a guard that checks no row passes blindly
    # From: Issue #1683 | PR #1858
    local root doc rows
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    doc="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_repo_path CI_ARCH_DOC "${root}")"
    rows="$(grep -cE '^\| `CACHE_[A-Z_]+` \|' "${doc}")"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -eq 0 ] && [ "${rows}" -gt 0 ] && [[ "${output}" == *"proxy-cache-env-doc-drift=clean"*"checked=${rows}"* ]] \
        || { echo "rows ${rows}: ${output}"; return 1; }
}

@test "check proxy-cache-env-doc-drift fails a real default mismatch" {
    # What: a default disagrees with its doc row
    # Why: Copied default can go stale.
    # From: Issue #1683 | PR #1858
    local env="${BATS_TEST_TMPDIR}/proxy.env" doc="${BATS_TEST_TMPDIR}/arch.md"
    printf 'CACHE_MEM_MB=999\n' > "${env}"
    printf "| \`CACHE_MEM_MB\` | \`512\` | some description |\n" > "${doc}"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift "${env}" "${doc}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0023"* ]]
    [[ "${output}" == *"default=999 vs doc=512"* ]]
}

@test "check proxy-cache-env-doc-drift ignores an undocumented CACHE_* var" {
    # What: a CACHE_* var with no matching doc row is fine.
    # Why: not every variable needs a table row.
    # From: Issue #1683 | PR #1858
    local env="${BATS_TEST_TMPDIR}/proxy2.env" doc="${BATS_TEST_TMPDIR}/arch2.md"
    printf 'CACHE_UNDOCUMENTED=1\n' > "${env}"
    printf '# no matching row here\n' > "${doc}"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift "${env}" "${doc}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=1 checked=0"* ]]
}

@test "proxy-cache-env-doc-drift reads what compose gives proxy" {
    # What: env_file and environment, rendered with .env
    # Why: both feed proxy; one file read missed moved keys
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/pce"
    local bin="${BATS_TEST_TMPDIR}/pcebin"
    local name ef want doc
    doc="${r}/$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_variable CI_ARCH_DOC)"
    mkdir -p "${r}/dep" "${doc%/*}"
    printf 'CACHE_X=1\n' > "${r}/dep/p.env"
    printf 'CACHE_Y=3\n' > "${r}/dep/.env"
    printf '| `CACHE_X` | `1` | x |\n| `CACHE_Y` | `4` | y |\n' > "${doc}"
    export CI_REPO_ROOT="${r}" CI_COMPOSE_FILE=dep/c.yml
    while IFS='|' read -r name ef want; do
        printf 'services:\n  proxy:\n    image: x\n%b' "${ef}" > "${r}/dep/c.yml"
        run bash "${CI_SH}" check proxy-cache-env-doc-drift
        [ "${status}" -ne 0 ] && [[ "${output}" == *"${want}"* ]] || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
both|    env_file: [./p.env]\n    environment:\n      - CACHE_Y=${CACHE_Y:?}\n|CACHE_Y: default=3 vs doc=4
none|    environment:\n      - OTHER=1\n|CI-ERROR-CHECK-0152
bad|  bogus: [\n|CI-ERROR-CHECK-0110
CASES
    printf 'CACHE_Y=4\n' > "${r}/dep/.env"
    printf 'services:\n  proxy:\n    image: x\n    env_file: [./p.env]\n    environment:\n      - CACHE_Y=${CACHE_Y:?}\n' > "${r}/dep/c.yml"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -eq 0 ] && [[ "${output}" == *"scanned=2 checked=2"* ]] || { echo "clean: rc ${status}: ${output}"; return 1; }
    _fail_stub "${bin}" grep
    PATH="${bin}:${PATH}" FAIL_MATCH="/docs/architecture-ng.md" \
        run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*"read error"* ]]
}

# What: neutral deploy + installer compose for a fixture.
# Why: checks derive both from owners, never real paths.
# From: Issue #1683 | PR #1858
_stack_fixture() {
    export CI_COMPOSE_FILE=dep/c.yml
    mkdir -p "$1/dep" "$1/inst"
    printf 'PROD_COMPOSE="$SCRIPT_DIR/%s"\n' inst/c.yml >> "$1/setup.sh"
}

@test "installer compose is read from setup.sh, fail-closed" {
    # What: one SCRIPT_DIR form reads; other forms fail.
    # Why: setup.sh owns the installer compose; CI derives.
    # From: Issue #1683 | PR #1858
    local r inst case body rc want
    local -A V=([@A@]="$(_val name)" [@B@]="$(_val name)" [@C@]="$(_val name)" [@X@]="$(_val name)")
    inst="$(_ci_variable CI_INSTALLER)" || return 1
    while IFS='|' read -r case body rc want; do
        r="${BATS_TEST_TMPDIR}/$(_val name)"
        mkdir -p "${r}"
        [ "${body}" = none ] || printf '%b' "$(_fill "${body}")" > "${r}/${inst}"
        run _ci_installer_compose "${r}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
ok|@X@=1\nPROD_COMPOSE="$SCRIPT_DIR/@A@/@B@/@C@"\n|0|=@A@/@B@/@C@
none|none|2|[CI-ERROR-CORE-0102]
absent|@X@=1\n|2|[CI-ERROR-CORE-0104]
twice|PROD_COMPOSE="$SCRIPT_DIR/@A@"\nPROD_COMPOSE="$SCRIPT_DIR/@B@"\n|2|[CI-ERROR-CORE-0104]
form|PROD_COMPOSE=/@A@/@C@\n|2|[CI-ERROR-CORE-0105]
CASES
    # What: the installer path comes from CI_INSTALLER.
    # Why: no installer literal in ci.sh; the SOT decides.
    # From: Issue #1683 | PR #1858
    inst="$(_val name)"
    printf 'PROD_COMPOSE="$SCRIPT_DIR/%s/%s"\n' "${V[@A@]}" "${V[@C@]}" > "${r}/${inst}"
    CI_INSTALLER="${inst}" run _ci_installer_compose "${r}"
    _expect override 0 "=${V[@A@]}/${V[@C@]}" || return 1
}

# What: seed a minimal prebuilt-only stack tree.
# Why: shared by the prebuilt-prod checks below.
# From: Issue #1683 | PR #1858
_prebuilt_fixture() {
    local root="$1"
    mkdir -p "${root}/dep" "${root}/inst"
    printf 'services:\n  proxy:\n    image: registry.example.test/example/proxy:sha-abc\n' > "${root}/dep/c.yml"
    printf 'services:\n  proxy:\n    image: registry.example.test/example/proxy:sha-abc\n' > "${root}/inst/c.yml"
    printf '# LanCache-NG\nRun: docker compose up -d\n' > "${root}/README.md"
    printf '#!/usr/bin/env bash\n' > "${root}/setup.sh"
    _stack_fixture "${root}"
}

@test "check prebuilt-prod passes a prebuilt-only tree" {
    # What: no build: and no --build anywhere user-facing.
    # Why: Prod runs prebuilt images.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-ok"
    _prebuilt_fixture "${r}"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"prebuilt-prod=clean"* ]]
}

@test "check prebuilt-prod fails a build: directive in prod compose" {
    # What: a prod compose that would build locally.
    # Why: prod must consume prebuilt images, not build.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-build"
    _prebuilt_fixture "${r}"
    printf 'services:\n  proxy:\n    build: .\n' > "${r}/dep/c.yml"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0042"*"declares build:"* ]]
}

@test "check prebuilt-prod fails a --build instruction in README" {
    # What: a user-facing doc telling users to build.
    # Why: install paths must not instruct local builds.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-readme"
    _prebuilt_fixture "${r}"
    printf '# LanCache-NG\nRun: docker compose up -d --build\n' > "${r}/README.md"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0042"*"instructs --build"* ]]
}

# What: Seed prod tree from LANCACHE_STATE_DIR.
# Why: shared by the prod-state-wiring checks below.
# From: Issue #1683 | PR #1858
_prod_state_wiring_fixture() {
    local root="$1" k
    _stack_fixture "${root}"
    mkdir -p "${root}/docs"
    : > "${root}/dep/c.yml"
    : > "${root}/dep/.env"
    : > "${root}/docs/backup-restore.md"
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        printf '      - ${%s:-${LANCACHE_STATE_DIR:-/opt/lancache-ng}/x}:/y\n' "${k}" >> "${root}/dep/c.yml"
        printf '%s=\n' "${k}" >> "${root}/dep/.env"
        printf '%s documented\n' "${k}" >> "${root}/docs/backup-restore.md"
    done
}

@test "check prod-state-wiring passes a fully derived, documented tree" {
    # What: All keys from LANCACHE_STATE_DIR.
    # Why: One state root, manual upgrades.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-ok"
    _prod_state_wiring_fixture "${r}"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"prod-state-wiring=clean"* ]]
}

@test "check prod-state-wiring fails a key not derived from LANCACHE_STATE_DIR" {
    # What: Per-service dir hardcoded off root.
    # Why: Breaks state-root contract.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-noderive"
    _prod_state_wiring_fixture "${r}"
    grep -v 'NATS_CONF_DIR' "${r}/dep/c.yml" > "${r}/dep/dc.tmp"
    printf '      - /hard/coded/nats-conf:/etc/nats\n' >> "${r}/dep/dc.tmp"
    mv "${r}/dep/dc.tmp" "${r}/dep/c.yml"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"NATS_CONF_DIR"* ]]
}

@test "check prod-state-wiring fails cleanly when an input file is missing" {
    # What: a missing compose/.env/doc yields a clear error.
    # Why: must not read as an undocumented-key violation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-missing"
    _prod_state_wiring_fixture "${r}"
    rm "${r}/docs/backup-restore.md"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"input missing"* ]]
}

@test "check compose-config renders every compose in every profile" {
    # What: compose files x own profiles, env, raw errors.
    # Why: the file owns its profiles; none may be skipped.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc" bin="${BATS_TEST_TMPDIR}/ccbin"
    local m="${BATS_TEST_TMPDIR}/cc.yml" mf name sot env w1 w2 rc
    export DLOG="${BATS_TEST_TMPDIR}/cc.log"
    mkdir -p "${r}/dep" "${r}/oth" "${bin}"
    : > "${r}/dep/c.yml"; : > "${r}/oth/c.yml"; : > "${r}/oth/.env"
    _tool_stub "${bin}" docker <<'SH'
echo "$* LISTEN_IP=${LISTEN_IP:-}" >> "${DLOG}"
case "$*" in
  *"config --profiles"*)
    [ -n "${PFAIL:-}" ] && { echo "profiles broken" >&2; exit 1; }
    printf 'p1\np2\n' ;;
  *"--profile ${BAD:-none} "*) echo "boom-${BAD}"; exit 1 ;;
  *"config --quiet"*) [ -n "${WARN:-}" ] && echo "level=warning drift"; exit 0 ;;
esac
SH
    printf '%s\n' 'ci_variables:' '  CI_COMPOSE_FILE: dep/c.yml' 'validation:' \
        '  compose_targets: oth/c.yml' '  compose_env_file_targets: oth/c.yml' \
        '  compose_validation_env: LISTEN_IP=fx' '  compose_validation_secrets:' '    hex32: [FX_TOKEN]' > "${m}"
    sed 's#  compose_targets: oth/c.yml#  compose_targets: oth/gone.yml#' "${m}" > "${m}.miss"
    grep -v '^  compose_targets:' "${m}" > "${m}.nosot"
    grep -v '^  CI_COMPOSE_FILE:' "${m}" > "${m}.novar"
    while IFS='|' read -r name sot env w1 w2 rc; do
        : > "${DLOG}"
        mf="${m}"
        [ "${sot}" = base ] || mf="${m}.${sot}"
        local -a ev=()
        [ -z "${env}" ] || ev=("${env}")
        run env "${ev[@]}" CI_MANIFEST="${mf}" PATH="${bin}:${PATH}" \
            bash "${CI_SH}" check compose-config "${r}"
        if [ "${rc}" = 0 ]; then
            [ "${status}" -eq 0 ] || { echo "${name}: ${output}"; return 1; }
        else
            [ "${status}" -ne 0 ] || { echo "${name}: passed"; return 1; }
        fi
        [[ "${output}" == *"${w1}"*"${w2}"* ]] || { echo "${name}: ${output}"; return 1; }
    done <<'CASES'
ok|base||compose-config=clean checks=9||0
bad|base|BAD=p2|oth/c.yml:p2: config invalid|boom-p2|1
warn|base|WARN=1|warnings treated as errors|level=warning drift|1
prof|base|PFAIL=1|profiles unreadable|profiles broken|1
miss|miss||oth/gone.yml: compose target missing||1
nosot|nosot||CI-ERROR-CHECK-0044||1
novar|novar||CI-ERROR-VARIABLES-0001|CI_COMPOSE_FILE|1
CASES
    run bash -c "CI_MANIFEST='${m}' PATH='${bin}:${PATH}' bash '${CI_SH}' check compose-config '${r}' >/dev/null; cat '${DLOG}'"
    [[ "${output}" == *"-f ${r}/dep/c.yml --profile p2 config --quiet LISTEN_IP=fx"* ]]
    [[ "${output}" == *"--env-file ${r}/oth/.env -f ${r}/oth/c.yml --profile p1 config --quiet LISTEN_IP="$'\n'* ]]
}

# What: seed a tree whose shared configs write atomically.
# Why: shared by the nats-atomic-write checks below.
# From: Issue #1683 | PR #1858
_nats_atomic_fixture() {
    local root="$1" cf
    mkdir -p "${root}/dep" "${root}/inst" "${root}/services/dns"
    for cf in dep/c.yml inst/c.yml; do
        cat > "${root}/${cf}" <<'EOF'
        tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"
        chown 10001:10001 "$$tmp_nats_conf"
        mv "$$tmp_nats_conf" /etc/nats/nats.conf
EOF
    done
    cat > "${root}/services/dns/entrypoint.sh" <<'EOF'
render_template_atomic
mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"
EOF
    cat > "${root}/setup.sh" <<'EOF'
write_file_atomically "${secondary_dir}/docker-compose.yml"
write_file_atomically "${secondary_dir}/.env"
EOF
    _stack_fixture "${root}"
}

@test "check nats-atomic-write passes a fully atomic tree" {
    # What: All writers write atomically.
    # Why: shared config must never be torn on write.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/naw-ok"
    _nats_atomic_fixture "${r}"
    run bash "${CI_SH}" check nats-atomic-write "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nats-atomic-write=clean"* ]]
}

@test "check nats-atomic-write fails a non-atomic nats.conf replace" {
    # What: compose overwrites nats.conf without temp+mv.
    # Why: a torn config can start a broken shared stack.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/naw-bad"
    _nats_atomic_fixture "${r}"
    printf 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"\n' > "${r}/dep/c.yml"
    run bash "${CI_SH}" check nats-atomic-write "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"atomically replace nats.conf"* ]]
}

@test "check nats-atomic-write fails a secondary .env written in place" {
    # What: setup writes the secondary .env in place.
    # Why: a torn .env breaks the secondary's start.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/naw-env"
    _nats_atomic_fixture "${r}"
    awk '$0 == "write_file_atomically \"${secondary_dir}/.env\"" { $0 = "cat > \"${secondary_dir}/.env\"" } 1' \
        "${r}/setup.sh" > "${r}/setup.new" && mv "${r}/setup.new" "${r}/setup.sh"
    ! grep -q 'write_file_atomically "${secondary_dir}/.env"' "${r}/setup.sh" || {
        echo "writer line not replaced"; return 1; }
    run bash "${CI_SH}" check nats-atomic-write "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"setup.sh: secondary setup must atomically write generated .env"* ]]
    [[ "${output}" != *"generated docker-compose.yml"* ]]
}

# What: rendered compose JSON of the real deploy file
# Why: fixture services and names derive from that file
# From: Issue #1683 | PR #1858
_real_deploy_json() {
    local dep
    dep="$(unset CI_COMPOSE_FILE; _ci_variable CI_COMPOSE_FILE)" || return 2
    _ci_compose_json "${CI_REPO_ROOT}/${dep}"
}

# What: compose with every real service and the proxy wiring
# Why: socket-proxy names and mounts derive from compose
# From: Issue #1683 | PR #1858
_dsp_compose() {
    local project="$1" dir="$2" real keys svc
    real="$(_real_deploy_json)" || return 1
    keys="$(jq -r '.services | keys[]' <<< "${real}")" || return 1
    printf 'name: %s\nservices:\n' "${project}"
    while IFS= read -r svc; do
        case "${svc}" in ui|watchdog|docker-socket-proxy) continue ;; esac
        printf '  %s:\n    image: x\n    container_name: %s-%s\n' "${svc}" "${project}" "${svc}"
    done <<< "${keys}"
    printf '  ui:\n    image: x\n    container_name: %s-ui\n    environment:\n' "${project}"
    printf '      DOCKER_PROXY_URL: http://docker-socket-proxy:%s # ui-url\n' "$(( BATS_TEST_NUMBER + 40000 ))"
    cat <<'YAML'
    depends_on:
      nats:
        condition: service_started # ui-nats
      docker-socket-proxy:
        condition: service_started # ui-dsp
  watchdog:
    image: x
    depends_on:
      docker-socket-proxy:
        condition: service_started # wd-dsp
  docker-socket-proxy:
    image: x
    entrypoint: ["haproxy", "-f", "/etc/hx/haproxy.cfg"]
    healthcheck:
      test: ["CMD", "true"]
    volumes:
YAML
    printf '      - %s/docker.sock:/run/docker.sock:ro # dsp-sock\n' "${dir}"
    printf '      - %s/cfg:/etc/hx:ro # dsp-cfg\n' "${dir}"
}

# What: seed a docker-socket-proxy tree for the dsp checks
# Why: deploy and installer compose come from one writer
# From: Issue #1683 | PR #1858
_socket_proxy_fixture() {
    local root="$1" cf
    _stack_fixture "${root}"
    for cf in dep inst; do
        _dsp_compose fixture "${root}/${cf}" > "${root}/${cf}/c.yml" || return 1
    done
}

@test "socket-proxy-config renders exactly the SOT grants on compose names" {
    # What: each SOT operation holds its services' names only
    # Why: haproxy grants the SOT policy and nothing else
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-render" f cfg ops op list svc want got names="" c port sock t
    _socket_proxy_fixture "${r}"
    f="${r}/dep/cfg/haproxy.cfg"
    run bash "${CI_SH}" socket-proxy-config "${r}/dep/c.yml"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"socket-proxy-config=written path=${f}"* ]] \
        || { echo "render: ${output}"; return 1; }
    cfg="$(_ci_compose_json "${r}/dep/c.yml")"
    ops="$(_ci_socket_proxy_api | jq -r '.[][0]')"
    while IFS= read -r op; do
        list="$(_ci_block_entry_list external_services docker-socket-proxy "${op}")"
        want=""
        while IFS= read -r svc; do
            [ -n "${svc}" ] || continue
            want+="$(jq -r --arg s "${svc}" '.services[$s].container_name' <<< "${cfg}")"$'\n'
        done <<< "${list}"
        want="$(sed '/^$/d' <<< "${want}" | sort)"
        got="$(sed -nE "s#^ +acl ${op} .*/containers/\\(([^)]*)\\)/.*#\\1#p" "${f}" | tr '|' '\n' | sort)"
        [ "${got}" = "${want}" ] || { echo "${op}: got [${got}] want [${want}]"; return 1; }
        if [ -n "${want}" ]; then
            grep -qE "^ +http-request allow if (get|post) ${op}\$" "${f}" || { echo "${op}: no allow rule"; return 1; }
        fi
        names+="${want}"$'\n'
    done <<< "${ops}"
    want="$(_ci_block_entry_list external_services docker-socket-proxy endpoints | sort)"
    got="$(sed -nE 's#^ +acl endpoints .*/\(([^)]*)\)\$$#\1#p' "${f}" | tr '|' '\n' | sort)"
    [ "${got}" = "${want}" ] || { echo "endpoints: got [${got}] want [${want}]"; return 1; }
    while IFS= read -r t; do
        grep -qxF "    timeout ${t}" "${f}" || { echo "timeout ${t} missing"; return 1; }
    done <<< "$(_ci_block_entry_list external_services docker-socket-proxy timeouts)"
    port="$(jq -r '.services.ui.environment.DOCKER_PROXY_URL' <<< "${cfg}")"
    sock="$(jq -r '.services["docker-socket-proxy"].volumes[] | select(.target | endswith(".sock")) | .target' <<< "${cfg}")"
    grep -qxF "    bind [::]:${port##*:} v4v6" "${f}" && grep -qxF "    server dockersocket ${sock}" "${f}" \
        || { echo "port/sock: $(cat "${f}")"; return 1; }
    [ "$(grep -E '^ +http-request ' "${f}" | tail -n 1)" = "    http-request deny" ] || { echo "last rule: $(cat "${f}")"; return 1; }
    while IFS= read -r c; do
        [ -n "${c}" ] || continue
        if ! grep -qxF -- "${c}" <<< "${names}" && grep -qE "[(|]${c}[|)]" "${f}"; then
            echo "${c} granted without a SOT entry"
            return 1
        fi
    done <<< "$(jq -r '.services[].container_name // empty' <<< "${cfg}")"
    run bash "${CI_SH}" socket-proxy-config "${r}/dep/c.yml"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"socket-proxy-config=unchanged path=${f}"* ]] \
        || { echo "rerun: ${output}"; return 1; }
}

@test "check docker-socket-proxy passes the fixture and the real repo" {
    # What: haproxy wiring and SOT render pass, wrong entry fails
    # Why: the socket proxy must start on the rendered policy
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-ok"
    run bash "${CI_SH}" check docker-socket-proxy
    [ "${status}" -eq 0 ] && [[ "${output}" == *"docker-socket-proxy=clean"* ]] || { echo "repo: ${output}"; return 1; }
    _socket_proxy_fixture "${r}"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"docker-socket-proxy=clean"* ]] || { echo "fixture: ${output}"; return 1; }
    sed -i 's/\["haproxy", /["sh", /' "${r}/dep/c.yml"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"dep/c.yml: docker-socket-proxy entrypoint is 'sh', not haproxy"* ]] \
        || { echo "entry: ${output}"; return 1; }
}

@test "check docker-socket-proxy gates ui/watchdog on started" {
    # What: ui/watchdog deps never wait for healthy.
    # Why: ui/watchdog must run while a dep flaps.
    # From: Issue #763 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-deps" case from to want
    while IFS='|' read -r case from to want; do
        rm -rf "${r}"
        _socket_proxy_fixture "${r}"
        awk -v f="${from}" -v t="${to}" 'f != "" && !d && $0 == f { $0 = t; d = 1 } { print }' \
            "${r}/inst/c.yml" > "${r}/inst/x.yml"
        mv "${r}/inst/x.yml" "${r}/inst/c.yml"
        run bash "${CI_SH}" check docker-socket-proxy "${r}"
        if [ "${want}" = clean ]; then
            [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
        else
            [ "${status}" -eq 1 ] || { echo "${case}: rc ${status} ${output}"; return 1; }
            [[ "${output}" == *"CI-ERROR-CHECK-0046"*"inst/c.yml: ${want}"* ]] || { echo "${case}: ${output}"; return 1; }
        fi
    done <<'CASES'
ok|||clean
uihealthy|        condition: service_started # ui-nats|        condition: service_healthy|ui waits for nats to be healthy; use service_started
uidsphealthy|        condition: service_started # ui-dsp|        condition: service_healthy|ui must depend on docker-socket-proxy with service_started
wdcompleted|        condition: service_started # wd-dsp|        condition: service_completed_successfully|watchdog must depend on docker-socket-proxy with service_started
wdmissing|  watchdog:|  watchdog-x:|watchdog must depend on docker-socket-proxy with service_started
CASES
}

@test "check netdata-isolation allows netdata and ui only" {
    # What: members of netdata-net per compose shape.
    # Why: any other member could reach the netdata API.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/nd" case from to want
    while IFS='|' read -r case from to want; do
        rm -rf "${r}"
        _stack_fixture "${r}"
        cat > "${r}/dep/c.yml" <<'YAML'
services:
  ui:
    image: x
    networks:
      - default
      - netdata-net # ui
  nats:
    image: x
    networks:
      - default # nats
  probe:
    image: x
    profiles: [extra]
    networks:
      - default # probe
  netdata:
    image: x
    networks:
      - netdata-net # netdata
networks:
  netdata-net: {}
  other: {}
YAML
        cp "${r}/dep/c.yml" "${r}/inst/c.yml"
        awk -v f="${from}" -v t="${to}" 'f != "" && !d && $0 == f { $0 = t; d = 1 } { print }' \
            "${r}/inst/c.yml" > "${r}/inst/x.yml"
        mv "${r}/inst/x.yml" "${r}/inst/c.yml"
        run bash "${CI_SH}" check netdata-isolation "${r}"
        if [ "${want}" = clean ]; then
            [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
            [[ "${output}" == *"netdata-isolation=clean"* ]]
        else
            [ "${status}" -eq 1 ] || { echo "${case}: rc ${status} ${output}"; return 1; }
            [[ "${output}" == *"CI-ERROR-CHECK-0146"*"inst/c.yml: ${want}"* ]] || { echo "${case}: ${output}"; return 1; }
            [[ "${output}" != *"dep/c.yml:"* ]] || { echo "${case}: dep flagged: ${output}"; return 1; }
        fi
    done <<'CASES'
ok|||clean
natsjoin|      - default # nats|      - netdata-net|netdata-net members must be netdata and ui (got: nats,netdata,ui)
profiled|      - default # probe|      - netdata-net|netdata-net members must be netdata and ui (got: netdata,probe,ui)
uimissing|      - netdata-net # ui|      - other|netdata-net members must be netdata and ui (got: netdata)
netdatadefault|      - netdata-net # netdata|      - netdata-net\n      - default|netdata must join netdata-net only (got: default,netdata-net)
CASES
}

@test "check syslog-logs-volume per compose and Dockerfile shape" {
    # What: initializer, start order, caps, image owner.
    # Why: syslog runs capability-free and cannot fix it.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/sl" case from to want rc
    while IFS='|' read -r case from to want rc; do
        rm -rf "${r}"
        _stack_fixture "${r}"
        mkdir -p "${r}/services/syslog"
        printf 'RUN addgroup -g 10001 lancache \\\n    && adduser -D -H -u 10001 -G lancache lancache\n' \
            > "${r}/services/syslog/Dockerfile"
        cat > "${r}/dep/c.yml" <<'YAML'
services:
  syslog-logs-permissions:
    image: x
    profiles: [logging]
    user: "0:0"
    entrypoint: ["/bin/chown"]
    command: ["-R", "10001:10001", "/var/log/lancache"]
    network_mode: none
    cap_drop: [ALL]
    cap_add: [CHOWN]
    read_only: true
    restart: "no"
  syslog:
    image: x
    profiles: [logging]
    cap_drop: [ALL]
    depends_on:
      syslog-logs-permissions:
        condition: service_completed_successfully
YAML
        cp "${r}/dep/c.yml" "${r}/inst/c.yml"
        if [ "${case}" = dockerfile ]; then
            sed -i 's/-u 10001/-u 10002/' "${r}/services/syslog/Dockerfile"
        elif [ "${case}" = nouser ]; then
            sed -i 's/adduser.*$/true/' "${r}/services/syslog/Dockerfile"
        fi
        awk -v f="${from}" -v t="${to}" 'f != "" && !d && $0 == f { $0 = t; d = 1 } { print }' \
            "${r}/inst/c.yml" > "${r}/inst/x.yml"
        mv "${r}/inst/x.yml" "${r}/inst/c.yml"
        run bash "${CI_SH}" check syslog-logs-volume "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
ok|||syslog-logs-volume=clean owner=10001:10001|0
user|    user: "0:0"|    user: "0"|inst/c.yml: syslog-logs-permissions user must be "0:0" (got "0")|1
owner|    command: ["-R", "10001:10001", "/var/log/lancache"]|    command: ["-R", "0:0", "/var/log/lancache"]|syslog-logs-permissions command must be ["-R","10001:10001","/var/log/lancache"]|1
network|    network_mode: none|    network_mode: bridge|syslog-logs-permissions network_mode must be "none" (got "bridge")|1
caps|    cap_add: [CHOWN]|    cap_add: [CHOWN, FOWNER]|syslog-logs-permissions cap_add must be ["CHOWN"]|1
rw|    read_only: true|    read_only: false|syslog-logs-permissions read_only must be true (got null)|1
restart|    restart: "no"|    restart: on-failure|syslog-logs-permissions restart must be "no"|1
order|        condition: service_completed_successfully|        condition: service_started|inst/c.yml: syslog must wait for syslog-logs-permissions to complete|1
dropall|    cap_drop: [ALL]|    cap_drop: [NET_RAW]|syslog-logs-permissions cap_drop must be ["ALL"]|1
dockerfile|||dep/c.yml: syslog-logs-permissions command must be ["-R","10002:10001","/var/log/lancache"]|1
nouser|||CI-ERROR-CHECK-0148|2
CASES
    printf '    cap_add: [CHOWN]\n' >> "${r}/dep/c.yml"
    printf 'RUN addgroup -g 10001 g && adduser -u 10001 u\n' > "${r}/services/syslog/Dockerfile"
    run bash "${CI_SH}" check syslog-logs-volume "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"dep/c.yml: syslog must drop all capabilities and add none"* ]]
}

@test "check proxy-cert-volume per compose and entrypoint shape" {
    # What: CERT_DIR mount kind per compose with a proxy.
    # Why: an anonymous volume loses leaf certs on recreate.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/pcv" case file from to want rc
    while IFS='|' read -r case file from to want rc; do
        rm -rf "${r}"
        _stack_fixture "${r}"
        mkdir -p "${r}/services/proxy" "${r}/sec"
        printf 'set -e\nCERT_DIR="/etc/nginx/ssl/certs"\n' > "${r}/services/proxy/entrypoint.sh"
        sed 's#^  compose_targets: .*#  compose_targets: sec/c.yml inst/c.yml#' "${CI_MANIFEST}" > "${r}/sot.yml"
        cat > "${r}/dep/c.yml" <<'YAML'
services:
  proxy:
    image: x
    volumes:
      - proxy-certs:/etc/nginx/ssl/certs # certs
      - ../ca:/etc/nginx/ssl/ca:ro
volumes:
  proxy-certs: {}
YAML
        cp "${r}/dep/c.yml" "${r}/inst/c.yml"
        printf 'services:\n  dns:\n    image: x # dns\n' > "${r}/sec/c.yml"
        awk -v f="${from}" -v t="${to}" 'f != "" && !d && $0 == f { $0 = t; d = 1 } { print }' \
            "${r}/${file}" > "${r}/x.yml"
        mv "${r}/x.yml" "${r}/${file}"
        run env CI_MANIFEST="${r}/sot.yml" bash "${CI_SH}" check proxy-cert-volume "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
ok|inst/c.yml|||proxy-cert-volume=clean cert_dir=/etc/nginx/ssl/certs files=3|0
anon|inst/c.yml|      - proxy-certs:/etc/nginx/ssl/certs # certs|      - /etc/nginx/ssl/certs|inst/c.yml: proxy /etc/nginx/ssl/certs must be a named volume (got volume anonymous)|1
bind|inst/c.yml|      - proxy-certs:/etc/nginx/ssl/certs # certs|      - ../certs:/etc/nginx/ssl/certs|inst/c.yml: proxy /etc/nginx/ssl/certs must be a named volume (got bind|1
moved|dep/c.yml|      - proxy-certs:/etc/nginx/ssl/certs # certs|      - proxy-certs:/data|dep/c.yml: proxy needs exactly one mount at /etc/nginx/ssl/certs (got 0)|1
secproxy|sec/c.yml|  dns:|  proxy:|sec/c.yml: proxy needs exactly one mount at /etc/nginx/ssl/certs (got 0)|1
certdir|services/proxy/entrypoint.sh|CERT_DIR="/etc/nginx/ssl/certs"|CERT_DIR="/srv/certs"|proxy needs exactly one mount at /srv/certs|1
nodir|services/proxy/entrypoint.sh|CERT_DIR="/etc/nginx/ssl/certs"|CERT_DIR="${X}/certs"|CI-ERROR-CHECK-0150|2
CASES
}

@test "check proxy-nginx-policy per healthz and header shape" {
    # What: healthz ACL and alias; hidden ignored headers.
    # Why: return skips the ACL; ignored headers leak.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/png" case file from to want rc f
    while IFS='|' read -r case file from to want rc; do
        rm -rf "${r}"
        mkdir -p "${r}/services/proxy/conf.d"
        for f in http https; do
            printf '%s\n' 'server {' '    location = /healthz {' '        access_log off;' \
                '        allow 127.0.0.1/32;' '        deny  all;' \
                '        alias /etc/nginx/lancache-healthz-body.txt;' '    }' '}' > "${r}/services/proxy/conf.d/${f}.conf"
        done
        printf '%s\n' 'proxy_ignore_headers   Cache-Control Expires Vary Set-Cookie;' \
            'proxy_hide_header      Set-Cookie;' 'proxy_hide_header      Vary;' \
            'proxy_hide_header      Cache-Control;' 'proxy_hide_header      Expires;' > "${r}/services/proxy/proxy-params.conf"
        awk -v f="${from}" -v t="${to}" 'f != "" && !d && $0 == f { $0 = t; d = 1 } { print }' \
            "${r}/${file}" > "${r}/x"
        mv "${r}/x" "${r}/${file}"
        run bash "${CI_SH}" check proxy-nginx-policy "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
ok|services/proxy/proxy-params.conf|||proxy-nginx-policy=clean healthz_blocks=2|0
open|services/proxy/conf.d/https.conf|        deny  all;|        access_log off;|https.conf: /healthz needs allow lines followed by deny all|1
noallow|services/proxy/conf.d/http.conf|        allow 127.0.0.1/32;|        access_log off;|http.conf: /healthz needs allow lines followed by deny all|1
order|services/proxy/conf.d/http.conf|        access_log off;|        deny all;\n        allow 10.0.0.0/8;|http.conf: /healthz needs allow lines followed by deny all|1
return|services/proxy/conf.d/https.conf|        alias /etc/nginx/lancache-healthz-body.txt;|        return 200 ok;|https.conf: /healthz must serve via alias, never return|1
drift|services/proxy/conf.d/https.conf|        allow 127.0.0.1/32;|        allow 0.0.0.0/0;|https.conf: /healthz differs from the first block|1
hidden|services/proxy/proxy-params.conf|proxy_hide_header      Vary;|# Vary shown|ignored header Vary must also be hidden from clients|1
ignore|services/proxy/proxy-params.conf|proxy_ignore_headers   Cache-Control Expires Vary Set-Cookie;|proxy_ignore_headers   Cache-Control Expires Vary;|proxy_ignore_headers must include Set-Cookie|1
none|services/proxy/conf.d/http.conf|    location = /healthz {|    location = /status {|clean healthz_blocks=1|0
CASES
}

@test "socket-proxy-config fails closed on a broken policy or wiring" {
    # What: each broken input stops the render with its reason
    # Why: haproxy must never start on a guessed allowlist
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-fail" case prog want svc="" list s
    list="$(_ci_block_entry_list external_services docker-socket-proxy restart)"
    while IFS= read -r s; do
        case "${s}" in ui|nats|"") ;; *) svc="${s}"; break ;; esac
    done <<< "${list}"
    [ -n "${svc}" ] || { echo "no SOT restart service without dependents: ${list}"; return 1; }
    while IFS='|' read -r case prog want; do
        want="${want//@svc/${svc}}"
        rm -rf "${r}"
        _socket_proxy_fixture "${r}"
        awk -v s="${svc}" "${prog}" "${r}/dep/c.yml" > "${r}/dep/x.yml"
        mv "${r}/dep/x.yml" "${r}/dep/c.yml"
        run bash "${CI_SH}" socket-proxy-config "${r}/dep/c.yml"
        [ "${status}" -eq 2 ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"socket-proxy: ${want}"* ]] || { echo "${case}: ${output}"; return 1; }
        [ ! -e "${r}/dep/cfg/haproxy.cfg" ] || { echo "${case}: a config was written"; return 1; }
        run bash "${CI_SH}" check docker-socket-proxy "${r}"
        [ "${status}" -eq 1 ] || { echo "${case} check: rc ${status} ${output}"; return 1; }
        [[ "${output}" == *"CI-ERROR-CHECK-0046"*"dep/c.yml: "*"socket-proxy: ${want}"* ]] \
            || { echo "${case} check: ${output}"; return 1; }
    done <<'CASES'
nosvc|$0 == "  " s ":" { skip = 1; next } skip && /^    / { next } { skip = 0; print }|SOT service @svc has no compose container_name
nourl|{ sub(/DOCKER_PROXY_URL/, "OTHER_URL") } { print }|ui has no DOCKER_PROXY_URL
twosock|{ print } /# dsp-sock$/ { gsub(/docker\.sock/, "other.sock"); print }|need one .sock bind, found 2
noflag|{ sub(/"-f", /, "") } { print }|entrypoint needs one haproxy -f path
nomount|{ sub(/:\/etc\/hx:ro/, ":/etc/other:ro") } { print }|no single bind mount holds /etc/hx/haproxy.cfg
CASES
}

# What: seed an installer tree with required env keys set.
# Why: shared by the compose-required-env checks below.
# From: Issue #1683 | PR #1858
_required_env_fixture() {
    local root="$1"
    mkdir -p "${root}/inst"
    _stack_fixture "${root}"
    printf 'services:\n  x:\n    environment:\n      A: ${A:?set A}\n      B: ${B:?set B}\n' > "${root}/inst/c.yml"
    printf 'A=1\nB=2\n' > "${root}/inst/.env"
}

@test "check compose-required-env passes when all required keys are set" {
    # What: Required ${VAR:?} keys non-empty.
    # Why: a required-but-unset key breaks compose at start.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-ok"
    _required_env_fixture "${r}"
    run bash "${CI_SH}" check compose-required-env "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"compose-required-env=clean"* ]]
}

@test "check compose-required-env fails when a required key is unset" {
    # What: a required ${VAR:?} key is missing from .env.
    # Why: compose would fail at interpolation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-bad"
    _required_env_fixture "${r}"
    printf 'A=1\n' > "${r}/inst/.env"
    run bash "${CI_SH}" check compose-required-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"define non-empty B"* ]]
}

# What: Seed a dhcp-proxy tree with two template keys.
# Why: shared by the dhcp-proxy-env checks below.
# From: Issue #1683 | PR #1858
_dhcp_proxy_env_fixture() {
    local root="$1" k
    mkdir -p "${root}/services/dhcp-proxy"
    _stack_fixture "${root}"
    printf 'services:\n  dhcp-proxy:\n    image: x\n    environment:\n' > "${root}/dep/c.yml"
    : > "${root}/dep/.env"
    : > "${root}/services/dhcp-proxy/entrypoint.sh"
    for k in "DPE_A_${BATS_TEST_NUMBER}" "DPE_B_${BATS_TEST_NUMBER}"; do
        printf '      - %s=${%s:-}\n' "${k}" "${k}" >> "${root}/dep/c.yml"
        printf '%s=\n' "${k}" >> "${root}/dep/.env"
        printf 'printf "%%s" "${%s}"\n' "${k}" >> "${root}/services/dhcp-proxy/entrypoint.sh"
    done
    printf '%s\n' '_dhcp_proxy_render_optional_directives() { :; }' \
        '_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf' >> "${root}/services/dhcp-proxy/entrypoint.sh"
    : > "${root}/services/dhcp-proxy/dnsmasq.conf.template"
}

@test "check dhcp-proxy-env passes when every used template key arrives" {
    # What: template, compose and entrypoint agree on keys
    # Why: the operator surface of dnsmasq must stay intact.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-ok"
    _dhcp_proxy_env_fixture "${r}"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"dhcp-proxy-env=clean"* ]] || { echo "${output}"; return 1; }
}

@test "check dhcp-proxy-env fails a template key compose drops" {
    # What: a key the entrypoint reads never reaches it.
    # Why: a dropped key loses its operator setting
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-drop" k="DPE_B_${BATS_TEST_NUMBER}"
    _dhcp_proxy_env_fixture "${r}"
    grep -v -- "- ${k}=" "${r}/dep/c.yml" > "${r}/dep/x.yml"
    mv "${r}/dep/x.yml" "${r}/dep/c.yml"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"CI-ERROR-CHECK-0102"*"never receives ${k}"* ]] \
        && [[ "${output}" != *"DPE_A_${BATS_TEST_NUMBER}"* ]] || { echo "${output}"; return 1; }
}

@test "check dhcp-proxy-env ignores keys outside the template" {
    # What: a key with no template entry is not required.
    # Why: the template owns the surface, not the code
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-extra"
    _dhcp_proxy_env_fixture "${r}"
    printf 'printf "%%s" "${DPE_C_%s}"\n' "${BATS_TEST_NUMBER}" >> "${r}/services/dhcp-proxy/entrypoint.sh"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"dhcp-proxy-env=clean"* ]] || { echo "${output}"; return 1; }
}

@test "check dhcp-proxy-env fails cleanly when an input file is missing" {
    # What: Missing compose/env/entrypoint.
    # Why: must not read as a dhcp-proxy contract violation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-miss" f
    for f in dep/.env services/dhcp-proxy/dnsmasq.conf.template; do
        rm -rf "${r}"
        _dhcp_proxy_env_fixture "${r}"
        rm "${r}/${f}"
        run bash "${CI_SH}" check dhcp-proxy-env "${r}"
        [ "${status}" -eq 2 ] && [[ "${output}" == *"input missing"*"${f}"* ]] || { echo "${f}: ${output}"; return 1; }
    done
}

@test "check vex-drift: one statement per entry, else a finding" {
    # What: clean on the real file; shape or count -> rc 1.
    # Why: a broken entry must fail before a release ships.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex" n
    mkdir -p "${r}"
    export GITHUB_REPOSITORY=o/r
    n="$(grep -c '^  - id:' "${BATS_TEST_DIRNAME}/../../.trivyignore.yaml")"
    run bash "${CI_SH}" check vex-drift "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"vex-drift=clean statements=${n}"* ]]
    printf 'vulnerabilities:\n  - id: CVE-1\n    purls: []\n' > "${r}/.trivyignore.yaml"
    run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0035"*"line 3"*"CI-ERROR-CHECK-0107"* ]]
    printf 'misconfigurations:\n  - id: AVD-1\nvulnerabilities:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0109"*"entries=2 statements=1"* ]]
}

# What: Seed setup.sh/dhcp for Kea.
# Why: shared by the setup-keys-kea checks below.
# From: Issue #1683 | PR #1858
_setup_keys_kea_fixture() {
    local root="$1" k
    mkdir -p "${root}/inst" "${root}/dep" "${root}/services/dhcp"
    : > "${root}/inst/.env"
    : > "${root}/dep/.env"
    {
        for k in DDNS_TSIG_KEY KEA_CTRL_TOKEN LANCACHE_IMAGE_TAG NATS_DNS_REPLICA_PASSWORD \
            NATS_DNS_REPLICA_USER NATS_DNS_WRITER_PASSWORD NATS_DNS_WRITER_USER \
            NATS_CALLOUT_PASSWORD NATS_CALLOUT_USER NATS_SYS_PASSWORD NATS_SYS_USER \
            NATS_UI_PASSWORD NATS_UI_USER PDNS_API_KEY SECONDARY_REGISTRATION_TOKEN; do
            printf '# %s\n' "${k}"
        done
        printf 'run_kea_dhcp_activation_preflight() { :; }\n'
        printf 'run_kea_dhcp_activation_preflight "$ENV_LOCAL"\n'
        printf 'nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5\n'
    } > "${root}/setup.sh"
    _stack_fixture "${root}"
    printf 'RUN apk add nmap\n' > "${root}/services/dhcp/Dockerfile"
    printf 'nmap|/usr/bin/nmap|/bin/nmap)\n' > "${root}/services/dhcp/entrypoint.sh"
}

@test "check setup-keys-kea passes a compliant tree" {
    # What: Required keys + Kea + nmap present.
    # Why: first-time setup depends on this whole surface.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-ok"
    _setup_keys_kea_fixture "${r}"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-keys-kea=clean"* ]]
}

@test "check setup-keys-kea fails a missing required key" {
    # What: a required runtime key is absent from setup.sh.
    # Why: setup must generate/migrate every runtime key.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-key"
    _setup_keys_kea_fixture "${r}"
    grep -v 'PDNS_API_KEY' "${r}/setup.sh" > "${r}/setup.sh.tmp"
    mv "${r}/setup.sh.tmp" "${r}/setup.sh"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"PDNS_API_KEY"* ]]
}

@test "check setup-keys-kea reads nmap from the SOT dhcp packages" {
    # What: nmap missing in the SOT dhcp list -> fail.
    # Why: the SOT owns apk lists, not the Dockerfile.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-nmap" m="${BATS_TEST_TMPDIR}/no-nmap.yml"
    _setup_keys_kea_fixture "${r}"
    grep -vx '      - nmap' "${CI_MANIFEST}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"services.dhcp.packages must install nmap"* ]]
}

@test "check setup-keys-kea fails a deprecated NATS token key" {
    # What: an env template reintroduces NATS_TOKEN.
    # Why: Role credentials replace token keys.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-nats"
    _setup_keys_kea_fixture "${r}"
    printf 'NATS_TOKEN=x\n' > "${r}/inst/.env"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"deprecated NATS token"* ]]
}

@test "check setup-update-safety enforces the real setup.sh update flow" {
    # What: setup.sh guards before mutations.
    # Why: AG-OP-010; a missing guard must fail the check.
    # From: Issue #1683
    run bash "${CI_SH}" check setup-update-safety "${BATS_TEST_DIRNAME}/../.."
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-update-safety=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/sus-bad"; mkdir -p "${r}"
    printf 'echo noop\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check setup-update-safety "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0103"*"no update flow calls"* ]]
    # What: a flow mutating before its pause is reported.
    # Why: the guard reads every function, not one window.
    # From: Issue #1683 | PR #1858
    printf 'flow() {\n    git -C x pull\n    pause_lancache_convergence_for_update\n}\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check setup-update-safety "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"flow mutates before its pause:"*"2:     git -C x pull"* ]]
    printf 'flow() {\n    stack_compose "$d" "$e" up -d\n    pause_lancache_convergence_for_update\n}\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check setup-update-safety "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"flow mutates before its pause:"*"2:     stack_compose"* ]]
    printf 'flow() {\n    update_repo_and_resume "$d"\n    pause_lancache_convergence_for_update\n}\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check setup-update-safety "${r}"
    [ "${status}" -ne 0 ] && [[ "${output}" == *"flow mutates before its pause:"*"2:     update_repo_and_resume"* ]] \
        || { echo "sync before pause: ${output}"; return 1; }
}

@test "check setup-docker-conflict enforces the real setup.sh Docker RPM guard" {
    # What: Keeps RPM conflict guard.
    # Why: Legacy docker conflicts; podman ok.
    # From: Issue #1683
    run bash "${CI_SH}" check setup-docker-conflict "${BATS_TEST_DIRNAME}/../.."
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-docker-conflict=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/sdc-bad"; mkdir -p "${r}"
    printf 'echo noop\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check setup-docker-conflict "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0104"* ]]
}

@test "check image-channel-resolution enforces the real channel/tag contract" {
    # What: All share one image resolution.
    # Why: pinned fails closed; channels pin digests.
    # From: Issue #1683
    run bash "${CI_SH}" check image-channel-resolution "${BATS_TEST_DIRNAME}/../.."
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"image-channel-resolution=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/icr-bad"; mkdir -p "${r}"
    printf 'echo noop\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check image-channel-resolution "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0105"* ]]
    local root m="${BATS_TEST_TMPDIR}/icr-mut" inst x n
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run --separate-stderr bash "${CI_SH}" variables get CI_INSTALLER
    [ "${status}" -eq 0 ]
    inst="${output}"
    [[ "${inst}" != */* ]]
    mkdir -p "${m}"
    for x in "${root}"/* "${root}"/.[!.]*; do
        [ "${x##*/}" = "${inst}" ] || ln -s "${x}" "${m}/${x##*/}"
    done
    [ "$(grep -cF 'if [[ "$first" == "$second" ]]; then' "${root}/${inst}")" -eq 1 ]
    n="$(grep -nF 'if [[ "$first" == "$second" ]]; then' "${root}/${inst}" | cut -d: -f1)"
    awk -v n="${n}" 'NR != n' "${root}/${inst}" > "${m}/${inst}"
    run grep -cF 'if [[ "$first" == "$second" ]]; then' "${m}/${inst}"
    [ "${output}" = 0 ]
    [ "$(( $(wc -l < "${root}/${inst}") - $(wc -l < "${m}/${inst}") ))" -eq 1 ]
    run bash "${CI_SH}" check image-channel-resolution "${m}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'setup.sh must keep image-resolution: if [[ "$first" == "$second" ]]; then'* ]]
    # What: the stack start moved above the image pull
    # Why: starting before the pull must fail the check
    # From: Issue #1683 | PR #1858
    local pull start
    pull="$(grep -nE '^stack_compose .* pull' "${root}/${inst}" | cut -d: -f1)"
    start="$(grep -nE '^[[:space:]]+systemctl start "\$STACK_UNIT"' "${root}/${inst}" | cut -d: -f1)"
    [ "$(wc -w <<< "${pull} ${start}")" -eq 2 ] && [ "${start}" -gt "${pull}" ] || { echo "anchors: ${pull} ${start}"; return 1; }
    awk -v p="${pull}" -v s="${start}" 'FNR == NR { if (FNR == s) l = $0; next }
        FNR == p { print l } FNR == s { next } { print }' "${root}/${inst}" "${root}/${inst}" > "${m}/${inst}"
    ! cmp -s "${root}/${inst}" "${m}/${inst}" || { echo "mutant equals the original"; return 1; }
    [ "$(sort "${root}/${inst}" | sha256sum)" = "$(sort "${m}/${inst}" | sha256sum)" ] \
        || { echo "mutant changed lines, not only their order"; return 1; }
    run bash "${CI_SH}" check image-channel-resolution "${m}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"must not start/enable lancache services before image pull"* ]] \
        || { echo "start before pull: ${output}"; return 1; }
}

@test "migrate_env_for_update repairs every empty required key" {
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

@test "migrate_env_for_update stops on a read error even under if" {
    # What: each key read failing stops the migration
    # Why: if/|| turn set -e off; lost reads rewrite config
    # From: Issue #1683 | PR #1858
    local root d keys key fired=0
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    keys="$(declare -f migrate_env_for_update | grep -oE 'get_env_(var|var_nonempty|assignment_value_raw|assignment_value_raw_nonempty) [A-Z][A-Z0-9_]+' | awk '{ print $2 }' | sort -u)"
    [ -n "${keys}" ] || { echo "no key reads found"; return 1; }
    export AWK_REAL STUBS="${BATS_TEST_TMPDIR}/stubs" FAILKEY
    AWK_REAL="$(type -P awk)"
    _tool_stub "${STUBS}" awk <<'STUB'
case " $* " in
    *" key=${FAILKEY:?} "*) : > "${STUBS}/fired"; echo "awk: injected read failure" >&2; exit 2 ;;
esac
exec "${AWK_REAL:?}" "$@"
STUB
    for key in ${keys}; do
        d="${BATS_TEST_TMPDIR}/rf-${key}/deploy/prod"
        _converged_install "${d}" || return 1
        FAILKEY="${key}"
        rm -f "${STUBS}/fired"
        _setup_sh_run 'PATH="${STUBS}:${BIN}:${PATH}"
            if migrate_env_for_update "${CONV}"; then echo migrate-continued; else echo "migrate-stopped $?"; fi'
        [ -e "${STUBS}/fired" ] || continue
        fired=$((fired + 1))
        [[ "${output}" == *"migrate-stopped "[1-9]* && "${output}" != *migrate-continued* ]] \
            || { echo "${key}: read failure did not stop the migration: ${output}"; return 1; }
    done
    [ "${fired}" -gt 0 ] || { echo "no injected read was reached"; return 1; }
    # What: a failed env write also stops the run under ||
    # Why: rewrite_env_key must not leave only a lost status
    # From: Issue #1683 | PR #1858
    d="${BATS_TEST_TMPDIR}/wf/deploy/prod"
    _converged_install "${d}" || return 1
    export WKEY WFILE="${d}/.env"
    WKEY="$(awk -F= '/^[A-Z][A-Z0-9_]*=/ { print $1; exit }' "${WFILE}")" FAILKEY="unused${BATS_TEST_NUMBER}"
    _tool_stub "${STUBS}" mktemp <<< 'echo "mktemp: injected write failure" >&2; exit 1'
    _setup_sh_run 'PATH="${STUBS}:${BIN}:${PATH}"; set_env_key "${WKEY}" "w${BATS_TEST_NUMBER}" "${WFILE}" || echo write-continued'
    [ "${status}" -ne 0 ] && [[ "${output}" == *"injected write failure"* && "${output}" != *write-continued* ]] \
        || { echo "write failure did not stop the run: ${output}"; return 1; }
}

@test "migrate_env_for_update derives CACHE_MAX_SIZE from CACHE_MAX_GB" {
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

@test "get_env_assignment_value_raw_nonempty preserves the raw assignment" {
    # What: Raw (unparsed) value returned.
    # Why: templated/quoted overrides must not be flattened.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/raw.env"
    _load_setup_sh "${repo_root}"
    printf 'FOO=${BAR}/baz\n' > "${ef}"
    run get_env_assignment_value_raw_nonempty FOO "${ef}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '${BAR}/baz' ]
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

@test "set_env_key collapses duplicate assignments to one" {
    # What: Duplicate key assigned once.
    # Why: repair must not rewrite every duplicate line.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/dup.env"
    _load_setup_sh "${repo_root}"
    printf 'FOO=1\nFOO=2\nBAR=3\n' > "${ef}"
    set_env_key FOO 9 "${ef}"
    [ "$(grep -c '^FOO=' "${ef}")" -eq 1 ]
    grep -qx 'FOO=9' "${ef}"
    grep -qx 'BAR=3' "${ef}"
}

# What: builds a fixture doc + deploy web_log mount.
# Why: shared by the logging-matrix tests below.
# From: Issue #1683 | PR #1858
_logging_matrix_fixture() {
    local root="$1" n
    local -a rows
    read -ra rows <<< "${2:-svc-a}"
    mkdir -p "${root}/docs" "${root}/services/syslog" "${root}/inst"
    _stack_fixture "${root}"
    {
        printf '**Logging matrix** (test):\n\n'
        printf '| Service | Logging path | Notes |\n'
        printf '| --- | --- | --- |\n'
        for n in "${rows[@]}"; do
            printf '| %s | Via x | note |\n' "${n}"
        done
    } > "${root}/docs/architecture-ng.md"
    printf 'header\njobs:\n  - name: real\n    path: /x\n' > "${root}/services/syslog/netdata-web_log.conf"
    cat > "${root}/dep/c.yml" <<'EOF'
services:
  netdata:
    volumes:
      - ../services/syslog/netdata-web_log.conf:/etc/netdata/go.d/web_log.conf:ro
EOF
}

@test "check logging-matrix passes clean on the real repo" {
    # What: migrated from check-logging-matrix.sh.
    # Why: rewritten in ci.sh; real docs/compose must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check logging-matrix
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"logging-matrix=clean"* ]]
}

@test "_ci_logging_matrix_canonical is a single deterministic awk pass" {
    # What: the flake this exists to prevent, at scale.
    # Why: stress-tested at 80 rows, 30 repeated runs.
    # From: Issue #1683 | PR #1858
    local doc="${BATS_TEST_TMPDIR}/big.md" i first cur
    {
        printf '**Logging matrix** (test):\n\n'
        printf '| Service | Logging path | Notes |\n'
        printf '| --- | --- | --- |\n'
        for i in $(seq 1 80); do
            printf '| svc-%d (label) | Via x | note %d |\n' "${i}" "${i}"
        done
    } > "${doc}"
    first="$(_ci_logging_matrix_canonical "${doc}")"
    [[ "${first}" == *"##ROWS## 80 80"* ]]
    for i in $(seq 1 30); do
        cur="$(_ci_logging_matrix_canonical "${doc}")"
        [ "${cur}" = "${first}" ]
    done
}

@test "check logging-matrix fails a service with no matrix row" {
    # What: a real Compose service, absent from the matrix.
    # Why: Every service needs matrix row.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-extra"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub 'printf "svc-a\nsvc-b\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0038"* ]]
    [[ "${output}" == *"service 'svc-b' has no logging-matrix row"* ]]
}

@test "check logging-matrix fails a stale row with no real service" {
    # What: a matrix row for a service no longer real.
    # Why: a renamed service must not leave a stale row.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-stale"
    _logging_matrix_fixture "${r}" "svc-a svc-gone"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"row 'svc-gone' is not a real Compose service"* ]]
}

@test "check logging-matrix fails a collapsed/duplicate row" {
    # What: two rows whose names normalize to the same one.
    # Why: Genuine row-parsing defense.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-dup"
    mkdir -p "${r}/docs"
    printf '**Logging matrix** (test):\n\n| Service | Logging path | Notes |\n| --- | --- | --- |\n| svc-a (nginx) | Via x | note |\n| svc-a (alias) | Via x | note |\n' \
        > "${r}/docs/architecture-ng.md"
    run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0037"* ]]
}

@test "check logging-matrix fails closed on a missing architecture doc" {
    # What: a repo root with no docs/architecture-ng.md.
    # Why: a missing input must never silently pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check logging-matrix "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0035"* ]]
}

@test "check logging-matrix fails closed with no matrix marker" {
    # What: a doc with no logging-matrix marker at all.
    # Why: a vacuous parse must never report clean.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-nomarker"
    mkdir -p "${r}/docs"
    printf '# no marker here\n' > "${r}/docs/architecture-ng.md"
    run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0036"* ]]
}

@test "check logging-matrix fails closed when a compose lookup errors" {
    # What: a while/process-sub loop once hid this failure.
    # Why: a real docker-compose error must not vanish.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-cmderr"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub 'exit 3')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0034"* ]]
}

@test "check logging-matrix fails when netdata lacks the web_log mount" {
    # What: deploy compose without the web_log file mount.
    # Why: netdata must read the one real web_log job file.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog"
    _logging_matrix_fixture "${r}" "svc-a"
    printf 'services:\n  netdata:\n    image: x\n' > "${r}/dep/c.yml"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"netdata must mount services/syslog/netdata-web_log.conf"* ]]
}

@test "check logging-matrix passes with the web_log file mounted" {
    # What: deploy compose mounts the real web_log file.
    # Why: the clean case of the same contract.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog-ok"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"logging-matrix=clean"* ]]
}

@test "check trivy-action-direct-usage denies every aquasecurity trivy action" {
    # What: any trivy action use fails; ci.sh scan passes.
    # Why: one scan owner; nesting/quotes must not hide it.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/trivy" use
    mkdir -p "${r}/.github/workflows"
    printf 'jobs:\n  s:\n    steps:\n      - run: bash ci.sh scan x\n' > "${r}/.github/workflows/s.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trivy-action-direct-usage=clean"* ]]
    for use in '      - uses: aquasecurity/trivy-action@0a' \
               '      - uses: "aquasecurity/setup-trivy@0b"' \
               "      -\n        uses: 'aquasecurity/trivy-action@0c'"; do
        printf 'jobs:\n  s:\n    steps:\n%b\n' "${use}" > "${r}/.github/workflows/s.yml"
        run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-CHECK-0039"*"s.yml"* ]]
    done
    printf 'jobs:\n  s:\n    steps:\n      - run: bash ci.sh scan x\n' > "${r}/.github/workflows/s.yml"
    mkdir -p "${r}/.github/actions/a"
    printf 'runs:\n  steps:\n    - uses: aquasecurity/trivy-action@0d\n' > "${r}/.github/actions/a/action.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"a/action.yml"* ]]
}

@test "check entrypoint-lib-wiring: a sourced lib needs a final-stage COPY" {
    # What: entrypoint source vs final-stage COPY, per case.
    # Why: a missing lib only fails at container runtime.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw" case ep src rc df want
    mkdir -p "${r}/dir/a"
    export CI_MANIFEST="${r}/m.yml"
    printf '%s\n' 'services:' '  svc-a:' '    context: dir/a' \
        'named_contexts:' '  ctx-n:' '    path: lib' > "${CI_MANIFEST}"
    while IFS='|' read -r case ep src rc df want; do
        rm -f "${r}/dir/a/entrypoint.sh" "${r}/dir/a/docker-entrypoint.sh"
        if [ "${src}" = yes ]; then
            printf '. /usr/local/lib/lib-x.sh\n' > "${r}/dir/a/${ep}"
        else
            printf 'echo nothing sourced\n' > "${r}/dir/a/${ep}"
        fi
        printf '%b\n' "${df}" > "${r}/dir/a/Dockerfile"
        run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${case}: no ${want}: ${output}"; return 1; }
    done <<'CASES'
copy|entrypoint.sh|yes|0|FROM b\nCOPY lib/lib-x.sh /usr/local/lib/lib-x.sh|=clean entrypoints=1 libs=1
no-copy|entrypoint.sh|yes|1|FROM b\nRUN echo hi|no matching final-stage COPY
docker-ep|docker-entrypoint.sh|yes|1|FROM b\nRUN echo hi|docker-entrypoint.sh sources
drift|entrypoint.sh|yes|1|FROM b\nCOPY lib/lib-x.sh /opt/lib/lib-x.sh|CI-ERROR-CHECK-0041
builder-only|entrypoint.sh|yes|1|FROM b AS bs\nCOPY lib/lib-x.sh /usr/local/lib/lib-x.sh\nFROM b\nRUN echo final|CI-ERROR-CHECK-0041
dir-copy|entrypoint.sh|yes|0|FROM b\nCOPY lib/ /usr/local/lib/|clean
nothing-sourced|entrypoint.sh|no|0|FROM b\nRUN echo hi|=clean entrypoints=1 libs=0
from-stage|entrypoint.sh|yes|0|FROM b AS bs\nRUN echo build\nFROM b\nCOPY --from=bs /build/lib-x.sh /usr/local/lib/lib-x.sh|clean
bad-stage|entrypoint.sh|yes|1|FROM b AS bs\nRUN echo build\nFROM b\nCOPY --from=oldbs /build/lib-x.sh /usr/local/lib/lib-x.sh|CI-ERROR-CHECK-0041
external|entrypoint.sh|yes|0|FROM b\nCOPY --from=registry.example.test/x/y:1 /x/lib-x.sh /usr/local/lib/lib-x.sh|clean
named-ctx|entrypoint.sh|yes|0|FROM b\nCOPY --from=ctx-n lib-x.sh /usr/local/lib/lib-x.sh|clean
CASES
}

@test "check entrypoint-lib-wiring passes clean and meaningfully on the real repo" {
    # What: Domain-validation consolidation live in repo.
    # Why: Guard validates real source lines now.
    # From: Issue #1683
    run bash "${CI_SH}" check entrypoint-lib-wiring
    [ "${status}" -eq 0 ]
    # What: the real repo must check at least one lib.
    # Why: a parser that finds nothing would pass clean.
    # From: Issue #1683 | PR #1858
    [[ "${output}" =~ =clean\ entrypoints=([1-9][0-9]*)\ libs=([1-9][0-9]*) ]]
}

# What: per row: changed files, labels -> clean, note, warn
# Why: CHANGELOG.md is written by the release flow only
# From: Issue #1683 | PR #1858
@test "check changelog-direct-edit warns on a direct edit unless labelled" {
    local case files labels rc want
    local -a argv
    local -A V=([@F@]="$(_ci_variable CI_CHANGELOG)" [@O@]="$(_val name)")
    V[@L@]="$(_ci_block_entry_field release_notes "" changelog_edit_label)"
    [ -n "${V[@L@]}" ] || { echo "no SOT release_notes.changelog_edit_label"; return 1; }
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

@test "diff refs fail on a broken PR merge-base, not empty" {
    # What: failed merge-base is rc 2; absent before = none.
    # Why: empty refs means "all changed"; UNKNOWN != BUILD.
    # From: Issue #1683 | PR #1858
    local repo up sh rt gho fake remote b h br out
    repo="$(_val path)" up="$(_val path)" sh="$(_val path)" rt="$(_val path)" gho="$(_val path)"
    fake="$(_val sha)" remote="$(_ci_git_remote)"
    _g() { git -C "$1" -c user.name="$(_val name)" -c user.email="$(_val name)@$(_val host)" \
        commit -q --allow-empty -m "$(_val name)"; }
    git init -q "${repo}" && _g "${repo}"
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=pull_request BASE_SHA="${fake}" run _ci_diff_refs
    _expect pr-no-history 2 "[CI-ERROR-CORE-0124]" || return 1
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=pull_request GITHUB_REF="refs/heads/$(_val name)" BASE_SHA="${fake}" \
        run _ci_diff_refs
    _expect pr-no-remote 2 "${remote}" || return 1
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=pull_request BASE_SHA="${fake}" run ci_cmd_changed_files
    _expect changed-files-no-history 2 "[CI-ERROR-CORE-0124]" || return 1
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=push BEFORE_SHA="${fake}" GITHUB_SHA=HEAD run _ci_diff_refs
    _expect push-before-absent 0 "=" || return 1
    # What: a shallow checkout gets the diff history once.
    # Why: workflows fetch one commit; ci.sh owns the diff.
    # From: Issue #1683 | PR #1858
    git init -q "${up}" && _g "${up}" && b="$(git -C "${up}" rev-parse HEAD)"
    _g "${up}" && h="$(git -C "${up}" rev-parse HEAD)" && br="$(git -C "${up}" symbolic-ref --short HEAD)"
    git clone -q --depth=1 --origin "${remote}" "file://${up}" "${sh}"
    [ "$(git -C "${sh}" rev-parse --is-shallow-repository)" = true ] || { echo "clone not shallow"; return 1; }
    CI_REPO_ROOT="${sh}" GITHUB_EVENT_NAME=push GITHUB_REF="refs/heads/${br}" BEFORE_SHA="${b}" \
        GITHUB_SHA="${h}" run _ci_diff_refs
    _expect shallow-deepened 0 "=${b} ${h}" || return 1
    [ "$(git -C "${sh}" rev-parse --is-shallow-repository)" = false ] || { echo "still shallow"; return 1; }
    # What: under GitHub the list path is also step output.
    # Why: workflows only call ci.sh; no echo in the YAML.
    # From: Issue #1683 | PR #1858
    mkdir -p "${rt}" && : > "${gho}"
    CI_REPO_ROOT="${sh}" GITHUB_EVENT_NAME=push GITHUB_REF="refs/heads/${br}" BEFORE_SHA="${b}" \
        GITHUB_SHA="${h}" RUNNER_TEMP="${rt}" GITHUB_OUTPUT="${gho}" run --separate-stderr ci_cmd_changed_files
    out="$(sed -n 's/^file=//p' "${gho}")"
    _expect step-output 0 "=${out}" || return 1
    [ "${out#"${rt}"/}" != "${out}" ] && [ -f "${out}" ] || { echo "step output '${out}' not a file in ${rt}"; return 1; }
    CI_REPO_ROOT="${sh}" GITHUB_EVENT_NAME=push GITHUB_REF="refs/heads/${br}" BEFORE_SHA="${b}" \
        GITHUB_SHA="${h}" RUNNER_TEMP="${rt}" GITHUB_OUTPUT="$(_val path)/$(_val name)" run ci_cmd_changed_files
    _expect output-unwritable 2 "[CI-ERROR-CORE-0125]" || return 1
}

# What: docker-build argv, guards and retry per row
# Why: one build owner; tag, cache, vars, retry share it
# From: Issue #1683 | PR #1858
@test "docker-build passes argv, guards and retries per row" {
    local name svc setup env fault rc calls want forbid got w e s ctx base
    local -a ev ws apk=() rust=()
    for s in $(_ci_block_keys services); do
        case "$(ci_service_field "${s}" build_type)" in apk) apk+=("${s}") ;; rust) rust+=("${s}") ;; esac
    done
    [ "${#apk[@]}" -ge 2 ] && [ "${#rust[@]}" -ge 1 ] || { echo "SOT has no two apk and one rust service"; return 1; }
    local -A V=(
        [@SA@]="${apk[0]}" [@SB@]="${apk[1]}" [@RS@]="${rust[0]}" [@ID@]="$(_val sha)"
        [@REG@]="$(_val host)" [@REPO@]="$(_val name)/$(_val name)" [@NOARG@]="$(_val path)"
        [@VE@]="$(_val var)" [@VJ@]="$(_val var)" [@VS@]="$(_val var)" [@VN@]="$(_val var)"
        [@XE@]="$(_val name)" [@XJ@]="$(_val name)" [@XS@]="$(_val name)" [@XL@]="$(_val name)" [@ERR@]="$(_val name)"
    )
    V[@PLAT@]="$(_ci_platforms "${V[@SA@]}" | awk 'NR == 1')"
    V[@ARCH@]="${V[@PLAT@]##*/}" V[@R@]="${V[@REG@]}/${V[@REPO@]}" V[@BT@]="$(_stub 'exit 0')"
    # What: the registry is the row's fresh host
    # Why: the expected tag must not come from ci.sh logic
    # From: Issue #1683 | PR #1858
    _ci_registry() { printf '%s\n' "${V[@REG@]}"; }
    export GITHUB_REPOSITORY="${V[@REPO@]}"
    base="$(_val path)"; cp "${CI_MANIFEST}" "${base}"
    while IFS='|' read -r name svc setup env fault rc calls want forbid; do
        cp "${base}" "${CI_MANIFEST}"
        case "${setup}" in
            vars) sed -i -e "/^build_variables:\$/a\\  apk: [${V[@VE@]}, ${V[@VJ@]}, ${V[@VS@]}, ${V[@VN@]}]" \
                    -e "/^ci_variables:\$/a\\  ${V[@VS@]}: ${V[@XS@]}" "${CI_MANIFEST}" ;;
            noarg) ctx="$(ci_service_field "${V[@SA@]}" context)"
                mkdir -p "${V[@NOARG@]}"
                grep -v -x 'ARG BUILD_IDENTITY' "$(_ci_service_path "${V[@SA@]}" Dockerfile "")" > "${V[@NOARG@]}/Dockerfile"
                sed -i "s|^    context: ${ctx}\$|    context: ${V[@NOARG@]}|" "${CI_MANIFEST}" ;;
        esac
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${fault}" in
            cachemiss) _docker_answer ' buildx build * --cache-from *' 0 '' \
                'importing cache manifest from target\nERROR: failed to configure registry cache import: not found' ;;
            transient) _docker_answer ' buildx build *' 1 '' \
                "(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:${V[@ID@]} locked for $(_val int 1 900)ms (since ${V[@ERR@]}): unavailable" 1 ;;
            compile) _docker_answer ' buildx build *' 1 '' "error: could not compile ${V[@ERR@]}" ;;
            runfail) _docker_answer ' buildx build *' 1 '' \
                "ERROR: process \"/bin/sh -c ${V[@ERR@]}\" did not complete successfully: exit code: 1" ;;
        esac
        unset CI_BUILD_CACHE_FROM CI_BUILD_CACHE_TO
        ev=()
        [ "${env}" = - ] || read -r -a ev <<< "$(_fill "${env}")"
        for e in "${ev[@]}"; do export "${e%%=*}=${e#*=}"; done
        run _ci_docker_build "$(_fill "${svc}")" "${V[@ID@]}" "${V[@PLAT@]}"
        for e in "${ev[@]}"; do unset "${e%%=*}"; done
        output+=$'\n'"--- docker.log"$'\n'"$(cat "${DS}/docker.log")"
        _expect "${name}" "${rc}" "$(_fill "${want}")" || return 1
        got="$(awk '/^buildx build / { n++ } END { print n + 0 }' "${DS}/docker.log")"
        [ "${got}" -eq "${calls}" ] || { echo "${name}: ${got} builds: ${output}"; return 1; }
        [ "${forbid}" = - ] && continue
        IFS=';' read -r -a ws <<< "$(_fill "${forbid}")"
        for w in "${ws[@]}"; do
            [[ "${output}" != *"${w}"* ]] || { echo "${name}: has '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
sot-vars|@SA@|vars|@VE@=@XE@ CI_VARIABLES={"@VJ@":"@XJ@","@VE@":"@XL@"}|-|0|1|--build-arg @VE@=@XE@;--build-arg @VJ@=@XJ@;--build-arg @VS@=@XS@|@VN@;@XL@
bad-vars-json|@SA@|vars|CI_VARIABLES=[|-|2|0|[CI-ERROR-VARIABLES-0015]|-
tag|@SA@|-|-|-|0|1|buildx build --load --platform @PLAT@ --tag @R@/@SA@:sha-@ID@-@ARCH@;org.opencontainers.image.title=@SA@;--build-arg BUILD_IDENTITY=@ID@;--build-arg BUILDKIT_DOCKERFILE_CHECK=error=true|--cache-from;--cache-to
wired-a|@SA@|-|CI_BUILD_CACHE_FROM=type=registry,ref=@R@/@SA@:cache CI_BUILD_CACHE_TO=type=registry,ref=@R@/@SA@:cache,mode=max|-|0|1|--cache-from type=registry,ref=@R@/@SA@:cache;--cache-to type=registry,ref=@R@/@SA@:cache,mode=max,ignore-error=true|@SB@:cache
wired-b|@SB@|-|CI_BUILD_CACHE_FROM=type=registry,ref=@R@/@SB@:cache CI_BUILD_CACHE_TO=type=registry,ref=@R@/@SB@:cache,mode=max|-|0|1|--cache-from type=registry,ref=@R@/@SB@:cache;--cache-to type=registry,ref=@R@/@SB@:cache,mode=max,ignore-error=true|@SA@:cache
ignore-error-kept|@SA@|-|CI_BUILD_CACHE_TO=type=registry,ref=@R@/@SA@:cache,ignore-error=false|-|0|1|--cache-to type=registry,ref=@R@/@SA@:cache,ignore-error=false|ignore-error=false,ignore-error=true;--cache-from
shorthand|@SA@|-|CI_BUILD_CACHE_TO=@R@/@SA@:cache|-|0|1|[CI-WARN-BUILD-0012];--cache-to @R@/@SA@:cache|@SA@:cache,
cache-miss|@SA@|-|CI_BUILD_CACHE_FROM=type=registry,ref=@R@/@SA@:cache|cachemiss|0|1|failed to configure registry cache import|-
no-build-identity|@SA@|noarg|-|-|2|0|[CI-ERROR-BUILD-0013] service="@SA@"|clear-runtime
rust-no-toolchain|@RS@|-|CI_BUILD_TOOLS_IMAGE_CMD=@BT@|-|2|0|[CI-ERROR-BUILDARGS-0009] arg="BUILD_TOOLS_IMAGE" service="@RS@"|clear-runtime
transient-retried|@SA@|-|CI_RETRY_BACKOFF_BASE_SECONDS=0|transient|0|2|[CI-WARN-BUILD-0016] op=buildx cmd="docker" cls=transient attempt=1/;[CI-INFO-BUILD-0017] op=buildx cmd="docker" attempt=2/|-
compile-error|@SA@|-|CI_RETRY_BACKOFF_BASE_SECONDS=0|compile|2|1|[CI-ERROR-BUILD-0011] op=buildx cmd="docker" cls=permanent attempt=1/;could not compile @ERR@;[CI-ERROR-BUILD-0019] service="@SA@"|-
run-failure|@SA@|-|CI_RETRY_BACKOFF_BASE_SECONDS=0|runfail|2|1|[CI-ERROR-BUILD-0011] op=buildx cmd="docker" cls=permanent attempt=1/;did not complete successfully;[CI-ERROR-BUILD-0019] service="@SA@"|-
CASES
}

# What: per row: push + readback -> published or coded fail.
# Why: BUILD != PUBLISH; a failed push never reads/builds.
# From: Issue #1683 | PR #1858
@test "publish pushes, reads the pushed tag back, never rebuilds" {
    local m case plat digest fault msg rc want pushes reads tag
    m="$(_val path)"
    local -A V=(
        [@REG@]="$(_val host).$(_val name)" [@OWN@]="$(_val name)" [@REPO@]="$(_val name)" [@S@]="$(_val name)"
        [@BT@]="$(_val name)" [@CTX@]="$(_val name)" [@DIG@]="$(_val digest)" [@PLAT@]="$(_val platform)"
        [@FOREIGN@]="$(_val platform)" [@USER@]="$(_val name)" [@TOKEN@]="$(_val name)" [@NET@]="$(_val name)"
        [@MAX@]="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)"
    )
    V[@REF@]="${V[@REG@]}/${V[@OWN@]}/${V[@REPO@]}"
    {
        _fill "$(printf '%s\n' 'build_matrix:' '  platforms: [@PLAT@]' 'build_identity:' '  @BT@:' '    inputs: [source_sha]' \
            'services:' '  @S@:' '    context: @CTX@' '    build_type: @BT@' 'release:' '  registry: @REG@')"
        printf '\n'
        _sot_block ci_variables
    } > "${m}"
    while IFS='|' read -r case plat digest fault msg rc want pushes reads; do
        rm -f "${DS}/digest" "${DS}/fail-push"
        : > "${DS}/docker.log"
        [ "${digest}" = - ] || _fill "${digest}" > "${DS}/digest"
        [ "${fault}" = - ] || : > "${DS}/${fault}"
        run env -u DOCKERHUB_USERNAME -u DOCKERHUB_TOKEN CI_MANIFEST="${m}" \
            GITHUB_REPOSITORY="${V[@OWN@]}/${V[@REPO@]}" GHCR_USERNAME="${V[@USER@]}" GHCR_TOKEN="${V[@TOKEN@]}" \
            FAULT="$(_fill "${msg}")" CI_RETRY_BACKOFF_BASE_SECONDS=0 bash "${CI_SH}" publish "${V[@S@]}" "$(_fill "${plat}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        if [ "$(grep -c '^push ' "${DS}/docker.log")" -ne "$(_fill "${pushes}")" ] \
            || [ "$(grep -c 'imagetools inspect' "${DS}/docker.log")" -ne "${reads}" ] \
            || grep -q 'buildx build' "${DS}/docker.log"; then
            echo "${case}: docker calls: $(cat "${DS}/docker.log")"
            return 1
        fi
        [ "${reads}" -eq 0 ] && continue
        tag="$(sed -n 's/^push //p' "${DS}/docker.log")"
        if [[ "${tag}" != "${V[@REF@]}/${V[@S@]}:sha-"* ]] || ! grep -qF -- "imagetools inspect ${tag} " "${DS}/docker.log"; then
            echo "${case}: readback is not the pushed tag: $(cat "${DS}/docker.log")"
            return 1
        fi
    done <<'CASES'
published|@PLAT@|@DIG@|-|-|0|service=@S@ platform=@PLAT@ published=@DIG@ identity=|1|1
push-transient|@PLAT@|@DIG@|fail-push|@NET@|2|[CI-WARN-BUILD-0016] op=registry cmd="docker" cls=transient attempt=1/@MAX@;@NET@;[CI-ERROR-BUILD-0011] op=registry cmd="docker" cls=transient attempt=@MAX@/@MAX@;@NET@;[CI-ERROR-PUBLISH-0005] service="@S@" platform="@PLAT@"|@MAX@|0
push-denied|@PLAT@|@DIG@|fail-push|denied: requested access to the resource is denied|2|[CI-ERROR-BUILD-0011] op=registry cmd="docker" cls=permanent attempt=1/@MAX@;denied: requested access;[CI-ERROR-PUBLISH-0005] service="@S@"|1|0
readback-missing|@PLAT@|-|-|-|2|[CI-ERROR-RESOLVE-0011] ref="@REF@/@S@:sha-;cls=not_found;[CI-ERROR-PUBLISH-0005] service="@S@"|1|1
foreign-platform|@FOREIGN@|@DIG@|-|-|2|[CI-ERROR-PUBLISH-0004] service="@S@";got="@FOREIGN@"|0|0
CASES
}

# =========================================================
# RETRY ENGINE (_ci_retry) + BUILD != PUBLISH INVARIANT
# =========================================================

# What: transient retried and logged; permanent fails once.
# Why: every failed try stays visible; bound from the SOT.
# From: Issue #1683 | PR #1858
@test "retry engine: transient retried with evidence, permanent once, bounded" {
    local stub max bound out sot
    out="$(_val name)"
    sot="$(_val path)"
    STUB_N="$(_val path)"
    export STUB_N
    stub="$(_stub 'n="$(cat "${STUB_N}")"; n=$((n + 1)); printf "%s" "${n}" > "${STUB_N}"; if [ "${n}" -le "${STUB_FAILS}" ]; then printf "%s\n" "${STUB_TEXT}" >&2; exit 1; fi; printf "%s\n" "${STUB_OK}"')"
    max="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)"
    [ "${max}" -ge 3 ] || { echo "SOT retry bound ${max} is below 3"; return 1; }
    bound="$(_val int 2 4)"
    [ "${bound}" -ne "${max}" ] || bound="$(( bound + 1 ))"
    printf '0' > "${STUB_N}"
    STUB_FAILS=2 STUB_TEXT='connection reset by peer' STUB_OK="${out}" CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry "${stub}"
    _expect transient-then-ok 0 "[CI-WARN-BUILD-0016] op=registry cmd=\"${stub}\" cls=transient attempt=1/${max};connection reset by peer;[CI-WARN-BUILD-0016] op=registry cmd=\"${stub}\" cls=transient attempt=2/${max};connection reset by peer;[CI-INFO-BUILD-0017] op=registry cmd=\"${stub}\" attempt=3/${max};${out}" || return 1
    [ "$(cat "${STUB_N}")" -eq 3 ] || { echo "transient-then-ok: $(cat "${STUB_N}") calls"; return 1; }
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='HTTP 401 unauthorized' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry "${stub}"
    _expect permanent 2 "[CI-ERROR-BUILD-0011] op=registry cmd=\"${stub}\" cls=permanent attempt=1/${max};HTTP 401 unauthorized" || return 1
    [ "$(cat "${STUB_N}")" -eq 1 ] || { echo "permanent: $(cat "${STUB_N}") calls"; return 1; }
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='connection refused' CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS="${bound}" run _ci_retry registry "${stub}"
    _expect env-bound 2 "[CI-ERROR-BUILD-0011] op=registry cmd=\"${stub}\" cls=transient attempt=${bound}/${bound};connection refused" || return 1
    [ "$(cat "${STUB_N}")" -eq "${bound}" ] || { echo "env-bound: $(cat "${STUB_N}") calls"; return 1; }
    # What: registry-read gives raw + rc, never BUILD-0011.
    # Why: a probe miss is a state its caller interprets.
    # From: Issue #1683 | PR #1858
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='manifest unknown' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry-read "${stub}"
    _expect read-miss 1 "=manifest unknown" || return 1
    [ "$(cat "${STUB_N}")" -eq 1 ] || { echo "read-miss: $(cat "${STUB_N}") calls"; return 1; }
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='gh: Not Found (HTTP 404)' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry github-read "${stub}"
    _expect github-read-miss 1 "=gh: Not Found (HTTP 404)" || return 1
    [ "$(cat "${STUB_N}")" -eq 1 ] || { echo "github-read-miss: $(cat "${STUB_N}") calls"; return 1; }
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='HTTP 401 unauthorized' CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry-read "${stub}"
    _expect read-permanent 2 "=HTTP 401 unauthorized" || return 1
    [ "$(cat "${STUB_N}")" -eq 1 ] || { echo "read-permanent: $(cat "${STUB_N}") calls"; return 1; }
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='connection refused' CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS="${bound}" \
        run _ci_retry registry-read "${stub}"
    _expect read-exhausted 2 "[CI-WARN-BUILD-0016] op=registry-read cmd=\"${stub}\" cls=transient attempt=1/${bound}" || return 1
    [[ "${output}" != *BUILD-0011* ]] || { echo "read-exhausted: engine error logged: ${output}"; return 1; }
    [ "$(cat "${STUB_N}")" -eq "${bound}" ] || { echo "read-exhausted: $(cat "${STUB_N}") calls"; return 1; }
    # What: without env the attempt count is the SOT value.
    # Why: the bound has one owner; ci.sh holds no literal.
    # From: Issue #1683 | PR #1858
    sed -e "s/^  CI_RETRY_MAX_ATTEMPTS: .*/  CI_RETRY_MAX_ATTEMPTS: ${bound}/" \
        -e 's/^  CI_RETRY_BACKOFF_BASE_SECONDS: .*/  CI_RETRY_BACKOFF_BASE_SECONDS: 0/' "${CI_MANIFEST}" > "${sot}"
    ! cmp -s "${CI_MANIFEST}" "${sot}" || { echo "SOT copy unchanged"; return 1; }
    unset CI_RETRY_MAX_ATTEMPTS CI_RETRY_BACKOFF_BASE_SECONDS
    printf '0' > "${STUB_N}"
    STUB_FAILS=99 STUB_TEXT='connection refused' CI_MANIFEST="${sot}" run _ci_retry registry "${stub}"
    _expect sot-bound 2 "attempt=${bound}/${bound}" || return 1
    [ "$(cat "${STUB_N}")" -eq "${bound}" ] || { echo "sot-bound: $(cat "${STUB_N}") calls"; return 1; }
}

# What: mktemp -d under /var/tmp, tracked for teardown.
# Why: cache-dir tests must pass under any ambient TMPDIR.
# From: Issue #1683 | PR #1858
_trivy_var_tmp_dir() {
    local d
    d="$(mktemp -d "/var/tmp/ci-bats-trivy.XXXXXX")" || return 1
    printf '%s\n' "${d}" >> "${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    printf '%s\n' "${d}"
}

@test "trivy var-tmp-dir manifest survives its own subshell for cleanup" {
    # What: Array append survives subshell for cleanup.
    # Why: Process substitution loses exit status.
    # From: Issue #1683 | PR #1858
    local vt; vt="$(_trivy_var_tmp_dir)"
    [ -d "${vt}" ]
    local manifest="${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    grep -qxF -- "${vt}" "${manifest}"
    _trivy_cleanup_var_tmp_dirs "${manifest}"
    [ ! -d "${vt}" ]
}

# What: PATH-shim trivy for a clean/finding/db outcome.
# Why: One trivy mock; the scan tests share it.
# From: Issue #1683
_trivy_stub() {
    local mode="$1" bin="${BIN}"
    mkdir -p "${bin}"
    {
        printf 'mode=%s\n' "${mode}"
        cat <<'STUB'
out=""
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
case "${mode}" in
    clean) [ -n "$out" ] && : > "$out"; exit 0 ;;
    finding) [ -n "$out" ] && echo "HIGH vuln" > "$out"; exit 1 ;;
    db) echo "failed to download vulnerability DB" >&2; exit 1 ;;
esac
STUB
    } | _tool_stub "${bin}" trivy
    printf '%s' "${bin}"
}

@test "scan default is clean when trivy exits zero" {
    # What: A zero exit is a clean image, no retry.
    # Why: The success path returns clean directly.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub clean)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 0 ]
}

@test "scan default fails on a written report (a finding)" {
    # What: A written report is a deterministic finding.
    # Why: Findings fail once; retrying is wasted work.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub finding)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"HIGH vuln"* ]]
}

@test "scan default escalates a DB miss after retries" {
    # What: No report plus a DB miss retries, then exits 3.
    # Why: A DB outage escalates, never reads as a finding.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub db)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        CI_RETRY_MAX_ATTEMPTS=2 CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_trivy_scan proxy sha256:abc
    _expect db-miss-escalates 3 '[CI-ERROR-BUILD-0011] op=trivy cmd="_ci_trivy_scan_once" cls=transient attempt=2/2' || return 1
}

@test "scan runs trivy with the vuln+secret scanners" {
    # What: The scan covers vulnerabilities and secrets.
    # Why: Secret-scan parity with the retired action.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    export TLOG="${BATS_TEST_TMPDIR}/t.log"; : > "${TLOG}"
    local bin="${BIN}"; mkdir -p "${bin}"
    _tool_stub "${bin}" trivy <<'STUB'
printf "%s\n" "$*" >> "${TLOG}"
out=""
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
[ -n "$out" ] && : > "$out"
exit 0
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 0 ]
    grep -q -- "--scanners vuln,secret" "${TLOG}"
    grep -q -- "--cache-dir ${vt}/trivy-cache" "${TLOG}"
}

@test "trivy dir writable proves a real file+subdir round-trip" {
    # What: A real dir passes the write+read+delete probe.
    # Why: Proves the probe itself, not just its caller.
    # From: Issue #1683
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 0 ]
}

@test "trivy dir writable refuses a missing directory" {
    # What: A nonexistent dir fails the probe.
    # Why: mkdir/write must never silently create the root.
    # From: Issue #1683
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}/does-not-exist"
    [ "${status}" -ne 0 ]
}

@test "trivy cache-dir prefers a writable shared dir" {
    # What: A writable shared-dir wins over the fallback.
    # Why: The shared NFS DB is the intended common cache.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    mkdir -p "${vt}/shared"
    CI_TRIVY_SHARED_DIR="${vt}/shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ]
    [[ "${output}" == "dir=${vt}/shared source=nfs-shared" ]]
}

@test "trivy cache-dir falls back to local disk when shared is absent" {
    # What: A missing shared-dir falls back to local disk.
    # Why: An unmounted NFS share must not block scanning.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    CI_TRIVY_SHARED_DIR="${vt}/no-such-share" \
    CI_TRIVY_FALLBACK_DIR="${vt}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ]
    # What: run merges the INFO notice into output too.
    # Why: a substring match tolerates that extra line.
    # From: Issue #1683
    [[ "${output}" == *"dir=${vt}/fallback source=local-fallback"* ]]
    [ -d "${vt}/fallback" ]
}

@test "trivy cache-dir refuses tmpfs /tmp for shared or fallback" {
    # What: A /tmp shared or fallback dir is rejected.
    # Why: /tmp is tmpfs; a prior outage was OOM there.
    # From: Issue #1683
    CI_TRIVY_SHARED_DIR="/tmp/whatever" CI_TRIVY_FALLBACK_DIR="${BATS_TEST_TMPDIR}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0007"* ]]
    CI_TRIVY_SHARED_DIR="${BATS_TEST_TMPDIR}/no-such-share" CI_TRIVY_FALLBACK_DIR="/tmp/whatever" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0018"* ]]
}

@test "trivy db fresh is false with no db file" {
    # What: A missing trivy.db is stale, never fine.
    # Why: Presence must never be assumed from an empty dir.
    # From: Issue #1683
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/empty"
    [ "${status}" -ne 0 ]
}

@test "trivy db fresh is true before NextUpdate" {
    # What: A future NextUpdate reads as fresh.
    # Why: This is the one true freshness signal.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/db/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/db/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/db/db/metadata.json"
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/db"
    [ "${status}" -eq 0 ]
}

@test "trivy db fresh is false past NextUpdate" {
    # What: A past NextUpdate reads as stale, not present.
    # Why: skip-db-update never re-checks staleness itself.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/db/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/db/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/db/db/metadata.json"
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/db"
    [ "${status}" -ne 0 ]
}

@test "trivy db lock serializes a second concurrent holder" {
    # What: A second locked_run waits for the first to end.
    # Why: Two writers must never race the same DB file.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/lockdb"; mkdir -p "${cache}"
    local order="${BATS_TEST_TMPDIR}/order"; : > "${order}"
    export CI_TRIVY_LOCK_POLL=1
    (
        _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
            'echo first-start >> "'"${order}"'"; sleep 1; echo first-end >> "'"${order}"'"'
    ) &
    local p1=$!
    sleep 0.3
    _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
        'echo second-start >> "'"${order}"'"'
    wait "${p1}"
    [ "$(sed -n 1p "${order}")" = "first-start" ]
    [ "$(sed -n 2p "${order}")" = "first-end" ]
    [ "$(sed -n 3p "${order}")" = "second-start" ]
}

@test "trivy db lock reclaims a stale lock directory" {
    # What: An old lock dir is reclaimed, not waited out.
    # Why: A crashed holder must never wedge later callers.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/staledb"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    touch -d '-1 hour' "${cache}/.trivy-db-update.lock"
    # What: an unreadable lock age stops, keeps the lock.
    # Why: age 0 would reclaim a live holder's lock.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/statbin"
    _fail_stub "${bin}" stat
    PATH="${bin}:${PATH}" FAIL_MATCH=%Y CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_lock_run "${cache}" 10 5 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0020"* ]]
    [ -d "${cache}/.trivy-db-update.lock" ]
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 10 5 -- true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"reclaiming stale trivy DB refresh lock"* ]]
}

@test "trivy db lock fails closed when stale-lock reclaim itself fails" {
    # What: rm -rf not removing the stale lock is SCAN-0015.
    # Why: NFS can leave stale lock; must not spin.
    # From: Issue #1683 | PR #1858
    local cache="${BATS_TEST_TMPDIR}/wedgeddb"; mkdir -p "${cache}"
    local lock="${cache}/.trivy-db-update.lock"
    mkdir -p "${lock}"
    touch -d '-1 hour' "${lock}"
    # What: PATH-shim rm that no-ops only on the lock path.
    # Why: portably simulates a reclaim rm -rf that fails.
    # From: Issue #1683 | PR #1858
    local bin="${BIN}"; mkdir -p "${bin}"
    _tool_stub "${bin}" rm <<STUB
for a; do [ "\$a" = "${lock}" ] && exit 0; done
exec /bin/rm "\$@"
STUB
    PATH="${bin}:${PATH}" CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_lock_run "${cache}" 10 5 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0015"* ]]
}

@test "trivy db lock fails closed when cache-dir cannot be created" {
    # What: A blocked cache-dir mkdir fails, never polls.
    # Why: distinguishes a real error from a held lock.
    # From: Issue #1683
    local blocker="${BATS_TEST_TMPDIR}/blocker"; : > "${blocker}"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${blocker}/cache" 1 5 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0013"* ]]
}

@test "trivy db lock never polls a missing-parent failure forever" {
    # What: A non-lock mkdir failure fails fast, not slow.
    # Why: never spend the full lock-timeout poll budget.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/filelock"; mkdir -p "${cache}"
    # What: a plain file at the lock path is not a lock.
    # Why: mkdir fails there on every platform, portably.
    : > "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0014"* ]]
}

@test "trivy db lock times out on a genuinely held lock" {
    # What: A fresh, still-held lock is never bypassed.
    # Why: Falling through risks two concurrent writers.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/heldlock"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0011"* ]]
}

@test "trivy ensure_fresh skips the download when already fresh" {
    # What: An already-fresh DB skips lock and download.
    # Why: This is the intended common no-op case.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/fresh/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/fresh/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/fresh/db/metadata.json"
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub 'echo SHOULD-NOT-RUN; exit 1')" \
        run _ci_trivy_db_ensure_fresh "${BATS_TEST_TMPDIR}/fresh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=true" ]]
}

@test "trivy ensure_fresh downloads under lock when stale" {
    # What: A stale/missing DB triggers one locked download.
    # Why: The lock is required exactly for the cold path.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/stale"; mkdir -p "${cache}"
    local next; next="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"
    local bin="${BIN}"; mkdir -p "${bin}"
    _tool_stub "${bin}" dl <<EOF
mkdir -p "${cache}/db"
printf 'x' > "${cache}/db/trivy.db"
printf '{"NextUpdate":"%s"}' "${next}" > "${cache}/db/metadata.json"
EOF
    CI_TRIVY_DB_DOWNLOAD_CMD="${bin}/dl" \
    CI_TRIVY_LOCK_TIMEOUT=5 CI_TRIVY_LOCK_STALE=60 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${cache}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=true" ]]
}

@test "trivy ensure_fresh reports present=false after a failed download" {
    # What: A plain download failure stays present=false.
    # Why: Permissive; trivy's own retry can still run.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/stillstale"
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub 'exit 1')" \
    CI_TRIVY_LOCK_TIMEOUT=5 CI_TRIVY_LOCK_STALE=60 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${BATS_TEST_TMPDIR}/stillstale"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=false" ]]
}

@test "trivy ensure_fresh hard-fails on a genuine lock timeout" {
    # What: A held lock fails ensure_fresh, not degrades.
    # Why: A silent downgrade risks a concurrent DB write.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/lockedstale"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_TIMEOUT=1 CI_TRIVY_LOCK_STALE=3600 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${cache}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0012"* ]]
}

# What: bare repo + two host clones for real CAS tests.
# Why: real git CAS proof, no live remote (AG-VAL-030).
# From: Issue #1683 | PR #1858
_cas_setup() {
    local head
    CAS_BARE="$(_val path).git"
    CAS_A="$(_val path)"
    CAS_B="$(_val path)"
    git init --quiet --bare "${CAS_BARE}"
    head="$(git -C "${CAS_BARE}" symbolic-ref HEAD)"
    git clone --quiet "${CAS_BARE}" "${CAS_A}"
    git -C "${CAS_A}" config user.email "$(_val name)@$(_val host)"
    git -C "${CAS_A}" config user.name "$(_val name)"
    git -C "${CAS_A}" commit --quiet --allow-empty -m "$(_val name)"
    git -C "${CAS_A}" push --quiet origin "HEAD:${head}"
    git clone --quiet "${CAS_BARE}" "${CAS_B}"
}

# What: a fresh empty ledger ref on the CAS bare repo
# Why: each row starts from no record; nothing carries over
# From: Issue #1683 | PR #1858
_ledger_fresh() {
    CI_GIT_REMOTE=origin CI_LEDGER_REF="refs/$(_val name)/$(_val name)" CI_LEDGER_FILE="$(_val name)"
    export CI_GIT_REMOTE CI_LEDGER_REF CI_LEDGER_FILE
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

# What: CAS lock life cycle on two real git hosts.
# Why: each lock state change is atomic and owned.
# From: Issue #1683 | PR #1858
@test "cas lock: create, refuse, take over, release, hand off" {
    local ref a b other bad age hi lo held bin cnt ft pfx ch run_id note
    ref="refs/$(_val name)/$(_val name)"
    a="$(_val name)"; b="$(_val name)"; other="$(_val name)"
    bad="$(_val path)"; bin="$(_val path)"; cnt="$(_val path)"; ft="$(_val name)"
    age="$(_val int 60 86459)"; hi=$(( age * 2 )); lo=$(( age / 2 ))
    _cas_setup
    _fail_stub "${bin}" git
    cd "${CAS_A}"
    run _ci_cas_ref_sha origin "${ref}"
    _expect free 1 "=" || return 1
    run _ci_cas_ref_sha "${bad}" "${ref}"
    _expect unknown 2 "[CI-WARN-RESOLVE-0008];raw:;${bad}" || return 1
    run _ci_lock_release "${bad}" "${ref}" "${a}"
    _expect release-unknown 1 "[CI-WARN-RESOLVE-0008]" || return 1
    GIT_COMMITTER_DATE="$(( $(date +%s) - age )) +0000" run _ci_lock_try origin "${ref}" "${a}" "${hi}"
    _expect create 0 - || return 1
    held="$(git ls-remote --exit-code origin "${ref}")" || { echo "create: no ref"; return 1; }
    cd "${CAS_B}"
    run _ci_lock_try origin "${ref}" "${b}" "${hi}"
    _expect refuse 1 "[CI-INFO-CAS-0006];holder=\"${a}\"" || return 1
    run _ci_lock_release origin "${ref}" "${other}"
    _expect foreign-release 0 "[CI-INFO-CAS-0007];holder=\"${a}\"" || return 1
    run _ci_lock_acquire origin "${ref}" "${b}" 2 0 "${hi}"
    _expect exhaust 1 "[CI-ERROR-CAS-0002]" || return 1
    PATH="${bin}:${PATH}" FAIL_MATCH=%ct run _ci_lock_try origin "${ref}" "${b}" "${lo}"
    _expect unreadable-age 3 "[CI-ERROR-CORE-0106]" || return 1
    [ "$(git ls-remote origin "${ref}")" = "${held}" ] || { echo "lock moved before takeover"; return 1; }
    run _ci_lock_try origin "${ref}" "${b}" "${lo}"
    _expect takeover 0 "[CI-INFO-CAS-0001];prev=\"${a}\"" || return 1
    git fetch --quiet origin "${ref}"
    [ "$(git log -1 --format=%s FETCH_HEAD)" = "${b}" ] || { echo "takeover: holder not ${b}"; return 1; }
    held="$(git ls-remote origin "${ref}")"
    printf '0' > "${cnt}"
    PATH="${bin}:${PATH}" FAIL_MATCH=fetch FAIL_COUNT="${cnt}" FAIL_RC=128 \
        FAIL_TEXT="fatal: couldn't find remote ref ${ref}" run _ci_lock_release origin "${ref}" "${b}"
    _expect release-permanent 1 "couldn't find remote ref" || return 1
    [ "$(<"${cnt}")" -eq 1 ] || { echo "release-permanent: $(<"${cnt}") fetch calls"; return 1; }
    PATH="${bin}:${PATH}" FAIL_MATCH=":${ref}" FAIL_RC=1 FAIL_TEXT="${ft}" \
        run _ci_lock_release origin "${ref}" "${b}"
    _expect delete-push-fails 1 "${ft}" || return 1
    [ "$(git ls-remote origin "${ref}")" = "${held}" ] || { echo "failed release moved the lock"; return 1; }
    printf '0' > "${cnt}"
    PATH="${bin}:${PATH}" FAIL_MATCH=fetch FAIL_TIMES=1 FAIL_COUNT="${cnt}" FAIL_RC=1 \
        FAIL_TEXT="unexpected disconnect while reading sideband packet" \
        CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_lock_release origin "${ref}" "${b}"
    _expect retried-release 0 - || return 1
    [ "$(<"${cnt}")" -eq 2 ] || { echo "retried-release: $(<"${cnt}") fetch calls"; return 1; }
    run git ls-remote --exit-code origin "${ref}"
    [ "${status}" -eq 2 ] || { echo "released: ref still present"; return 1; }
    cd "${CAS_A}"
    run _ci_lock_try origin "${ref}" "${a}" "${hi}"
    _expect hand-off 0 - || return 1
    pfx="refs/$(_val name)"; ch="$(_val name)"; run_id="$(_val name)"
    CI_GIT_REMOTE=origin CI_PROMOTE_LOCK_REF="${pfx}" CI_PROMOTE_LOCK_MAX=1 CI_PROMOTE_LOCK_BACKOFF=0 \
        CI_PROMOTE_LOCK_STALE="${hi}" GITHUB_RUN_ID="${run_id}" run _ci_default_promote_lock "${ch}"
    _expect promote-lock 0 - || return 1
    git fetch --quiet origin "${pfx}/${ch}"
    note="$(git log -1 --format=%s FETCH_HEAD)"
    [[ "${note}" == *"${ch}"* && "${note}" == *"${run_id}"* ]] || { echo "promote-lock note: ${note}"; return 1; }
    CI_GIT_REMOTE=origin CI_PROMOTE_LOCK_REF="${pfx}" GITHUB_RUN_ID="${run_id}" \
        run _ci_default_promote_unlock "${ch}"
    _expect promote-unlock 0 - || return 1
    run git ls-remote --exit-code origin "${pfx}/${ch}"
    [ "${status}" -eq 2 ] || { echo "promote-unlock: ref still present"; return 1; }
}

# What: two simultaneous creators; exactly one wins.
# Why: git ref create is compare-against-zero.
# From: Issue #1683 | PR #1858
@test "cas concurrent create has exactly one winner" {
    local ref a b ra rb stale sa sb win
    ref="refs/$(_val name)/$(_val name)"; a="$(_val name)"; b="$(_val name)"
    ra="$(_val path)"; rb="$(_val path)"; stale="$(_val int 60 86459)"
    _cas_setup
    ( set +e; cd "${CAS_A}"; _ci_lock_try origin "${ref}" "${a}" "${stale}"; echo "$?" > "${ra}" ) &
    ( set +e; cd "${CAS_B}"; _ci_lock_try origin "${ref}" "${b}" "${stale}"; echo "$?" > "${rb}" ) &
    wait
    sa="$(<"${ra}")"; sb="$(<"${rb}")"
    case "${sa}:${sb}" in
        0:1|0:2) win="${a}" ;;
        1:0|2:0) win="${b}" ;;
        *) echo "rc a=${sa} b=${sb}: not exactly one winner"; return 1 ;;
    esac
    git -C "${CAS_A}" fetch --quiet origin "${ref}"
    [ "$(git -C "${CAS_A}" log -1 --format=%s FETCH_HEAD)" = "${win}" ] || { echo "holder is not ${win}"; return 1; }
}

# What: acceptance ledger life cycle on one bare repo.
# Why: reuse and GC trust only what the ledger states.
# From: Issue #1683 | PR #1858
@test "ledger: absent, upsert, keep, batch, UNKNOWN, accepted digest" {
    local i1 i2 i3 i4 s1 s2 p1 p2 d1 d2 d3 d4 ref bad file t before
    i1="$(_val sha)"; i2="$(_val sha)"; i3="$(_val sha)"; i4="$(_val sha)"
    s1="$(_val name)"; s2="$(_val name)"; p1="$(_val platform)"; p2="$(_val platform)"
    d1="$(_val digest)"; d2="$(_val digest)"; d3="$(_val digest)"; d4="$(_val digest)"
    ref="refs/$(_val name)/$(_val name)"; bad="refs/$(_val name)/$(_val name)"; file="$(_val name)"; t=$'\t'
    CI_GIT_REMOTE=origin; CI_LEDGER_REF="${ref}"; CI_LEDGER_FILE="${file}"
    export CI_GIT_REMOTE CI_LEDGER_REF CI_LEDGER_FILE
    _ci_identity_for() {
        case "$1|$2" in "${s1}|${p1}") echo "${i1}" ;; "${s2}|${p2}") echo "${i2}" ;; *) echo "${i3}" ;; esac
    }
    _cas_setup
    cd "${CAS_A}"
    run _ci_ledger_read origin "${i1}"
    _expect empty-absent 1 "=" || return 1
    run _ci_ledger_append origin "${i1}" "${s1}" "${p1}" PRODUCED_UNVERIFIED "${d1}"
    _expect append 0 "[CI-INFO-LEDGER-0004]" || return 1
    run _ci_ledger_read origin "${i1}"
    _expect read-unverified 0 "=PRODUCED_UNVERIFIED${t}${d1}" || return 1
    run _ci_accepted_digest "${s1}" "${p1}"
    _expect digest-unverified 1 "[CI-INFO-ASSEMBLE-0009]" || return 1
    run _ci_ledger_append origin "${i1}" "${s1}" "${p1}" ACCEPTED "${d1}"
    _expect upsert 0 "[CI-INFO-LEDGER-0004]" || return 1
    run _ci_ledger_read origin "${i1}"
    _expect read-accepted 0 "=ACCEPTED${t}${d1}" || return 1
    git fetch --quiet origin "${ref}"
    [ "$(git cat-file -p "FETCH_HEAD:${file}" | grep -c "^${i1}${t}")" -eq 1 ] || { echo "upsert: not one ${i1} line"; return 1; }
    run _ci_accepted_digest "${s1}" "${p1}"
    _expect digest-accepted 0 "=${d1}" || return 1
    run _ci_ledger_append origin "${i2}" "${s2}" "${p2}" PRODUCED_UNVERIFIED "${d2}"
    _expect append-other 0 "[CI-INFO-LEDGER-0004]" || return 1
    run _ci_ledger_read origin "${i1}"
    _expect kept 0 "=ACCEPTED${t}${d1}" || return 1
    run _ci_ledger_read origin "${i2}"
    _expect other 0 "=PRODUCED_UNVERIFIED${t}${d2}" || return 1
    run _ci_ledger_read origin "${i3}"
    _expect unlisted-absent 1 "=" || return 1
    run _ci_accepted_digest "$(_val name)" "$(_val platform)"
    _expect digest-no-record 1 "[CI-INFO-ASSEMBLE-0008]" || return 1
    git fetch --quiet origin "${ref}"
    before="$(git rev-list --count FETCH_HEAD)"
    run _ci_ledger_upsert origin <<< "${i3}${t}${s1}${t}${p2}${t}ACCEPTED${t}${d3}"$'\n'"${i4}${t}${s2}${t}${p1}${t}ACCEPTED${t}${d4}"
    _expect batch 0 "[CI-INFO-LEDGER-0004]" || return 1
    git fetch --quiet origin "${ref}"
    [ "$(git rev-list --count FETCH_HEAD)" -eq $(( before + 1 )) ] || { echo "batch: not one commit"; return 1; }
    [ "$(git cat-file -p "FETCH_HEAD:${file}" | grep -c .)" -eq 4 ] || { echo "batch: not 4 records"; return 1; }
    run _ci_ledger_read origin "${i4}"
    _expect batch-read 0 "=ACCEPTED${t}${d4}" || return 1
    git push --quiet origin "HEAD:${bad}"
    CI_LEDGER_REF="${bad}" run _ci_ledger_blob origin
    _expect unknown 2 "[CI-WARN-RESOLVE-0009];file=\"${file}\";raw:" || return 1
    CI_LEDGER_REF="${bad}" run _ci_ledger_read origin "${i1}"
    _expect unknown-read 2 "[CI-WARN-RESOLVE-0009]" || return 1
    CI_LEDGER_REF="${bad}" run _ci_accepted_digest "${s1}" "${p1}"
    _expect unknown-digest 2 "[CI-WARN-RESOLVE-0009]" || return 1
    CI_LEDGER_REF="${bad}" run _ci_ledger_append origin "${i1}" "${s1}" "${p1}" ACCEPTED "${d1}"
    _expect unknown-write 3 "[CI-WARN-RESOLVE-0009];[CI-ERROR-LEDGER-0001]" || return 1
}

# What: one registry reader: digest, raw, miss or unknown
# Why: only a real miss may build; auth stays UNKNOWN
# From: Issue #1683 | PR #1858
@test "registry read maps each answer per wrapper" {
    local case fn answer rc calls want how
    CI_RETRY_MAX_ATTEMPTS="$(_val int 2 6)"
    export CI_RETRY_MAX_ATTEMPTS CI_RETRY_BACKOFF_BASE_SECONDS=0
    local -A V=(
        [@REF@]="$(_val host)/$(_val name)/$(_val name):$(_val name)" [@DIG@]="$(_val digest)" [@NET@]="$(_val name)"
        [@TXT@]="$(_val name)" [@MAX@]="${CI_RETRY_MAX_ATTEMPTS}"
    )
    V[@RAW@]="{\"manifests\":[{\"digest\":\"${V[@DIG@]}\"}]}"
    while IFS='|' read -r case fn answer rc calls want; do
        : > "${DS}/docker.log"
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${answer}" in
            ok:*) _docker_answer ' buildx imagetools inspect *' 0 "$(_fill "${answer#ok:}")" ;;
            miss:*) _docker_answer ' buildx imagetools inspect *' 1 '' "$(_fill "${answer#miss:}")" ;;
            net) _docker_answer ' buildx imagetools inspect *' 1 '' "${V[@NET@]}" ;;
            net-once) _docker_answer ' buildx imagetools inspect *' 1 '' "${V[@NET@]}" 1
                _docker_answer ' buildx imagetools inspect *' 0 "${V[@DIG@]}" ;;
        esac
        run "${fn}" "${V[@REF@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        how='--format {{.Manifest.Digest}}'
        [ "${fn}" != _ci_index_raw ] || how=--raw
        grep -qxF -- "buildx imagetools inspect ${V[@REF@]} ${how}" "${DS}/docker.log" \
            || { echo "${case}: argv $(cat "${DS}/docker.log")"; return 1; }
        [ "$(grep -c '^buildx imagetools inspect ' "${DS}/docker.log")" -eq "$(_fill "${calls}")" ] \
            || { echo "${case}: calls $(cat "${DS}/docker.log")"; return 1; }
    done <<'CASES'
present|_ci_registry_probe|ok:@DIG@|0|1|=@DIG@
manifest-unknown|_ci_registry_probe|miss:@REF@: not found: manifest unknown|1|1|=
buildx-not-found|_ci_registry_probe|miss:ERROR: @REF@: not found|1|1|=
no-digest|_ci_registry_probe|ok:@TXT@|2|1|[CI-WARN-RESOLVE-0007] ref="@REF@" reason="registry read gave no digest";@TXT@
denied|_ci_registry_probe|miss:denied: requested access to the resource is denied|2|1|[CI-WARN-RESOLVE-0007] ref="@REF@" cls=permanent;denied: requested access
transient-then-ok|_ci_registry_probe|net-once|0|2|[CI-WARN-BUILD-0016] op=registry-read;@NET@;[CI-INFO-BUILD-0017];@DIG@
transient-exhausted|_ci_registry_probe|net|2|@MAX@|[CI-WARN-BUILD-0016] op=registry-read;[CI-WARN-RESOLVE-0007] ref="@REF@" cls=transient;@NET@
raw-present|_ci_index_raw|ok:@RAW@|0|1|=@RAW@
raw-absent|_ci_index_raw|miss:not found: manifest unknown|1|1|=
raw-transient|_ci_index_raw|net|2|@MAX@|[CI-WARN-RESOLVE-0010] ref="@REF@" cls=transient;@NET@
digest-present|_ci_registry_digest|ok:@DIG@|0|1|=@DIG@
digest-absent-fails|_ci_registry_digest|miss:not found: manifest unknown|2|1|[CI-ERROR-RESOLVE-0011] ref="@REF@" cls=not_found
CASES
}

# What: index lookup per row; reconcile stops on UNKNOWN
# Why: never assemble over an unchecked existing index
# From: Issue #1683 | PR #1858
@test "index lookup reads the index, drops attestations, stops on unknown" {
    local case answer rc want rrc rwant
    local -A V=(
        [@REG@]="$(_val host)" [@REPO@]="$(_val name)/$(_val name)" [@SVC@]="$(_val name)" [@SHA@]="$(_val sha)"
        [@IDX@]="$(_val digest)" [@DA@]="$(_val digest)" [@DB@]="$(_val digest)" [@DT@]="$(_val digest)"
        [@PA@]="$(_val platform)" [@PB@]="$(_val platform)" [@NET@]="$(_val name)" [@TXT@]="$(_val name)"
    )
    V[@TAG@]="${V[@REG@]}/${V[@REPO@]}/${V[@SVC@]}:sha-${V[@SHA@]}"
    V[@RAW@]="{\"manifests\":[{\"platform\":{\"os\":\"${V[@PA@]%/*}\",\"architecture\":\"${V[@PA@]#*/}\"},\"digest\":\"${V[@DA@]}\"},{\"platform\":{\"os\":\"${V[@PB@]%/*}\",\"architecture\":\"${V[@PB@]#*/}\"},\"digest\":\"${V[@DB@]}\"},{\"platform\":{\"os\":\"unknown\",\"architecture\":\"unknown\"},\"digest\":\"${V[@DT@]}\"}]}"
    _ci_registry() { printf '%s\n' "${V[@REG@]}"; }
    export CI_RETRY_BACKOFF_BASE_SECONDS=0 GITHUB_REPOSITORY="${V[@REPO@]}" GITHUB_SHA="${V[@SHA@]}"
    while IFS='|' read -r case answer rc want rrc rwant; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${answer}" in
            present) _docker_answer ' buildx imagetools inspect * --raw *' 0 "${V[@RAW@]}"
                _docker_answer ' buildx imagetools inspect *' 0 "${V[@IDX@]}" ;;
            broken) _docker_answer ' buildx imagetools inspect * --raw *' 0 "${V[@TXT@]}"
                _docker_answer ' buildx imagetools inspect *' 0 "${V[@IDX@]}" ;;
            absent) _docker_answer ' buildx imagetools inspect *' 1 '' 'not found: manifest unknown' ;;
            net) _docker_answer ' buildx imagetools inspect *' 1 '' "dial tcp ${V[@NET@]}: i/o timeout" ;;
        esac
        run _ci_index_lookup "${V[@SVC@]}"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
        [ "${rrc}" != - ] || continue
        run _ci_reconcile_index "${V[@SVC@]}" "${V[@PA@]}=${V[@DA@]}"
        _expect "${case}-reconcile" "${rrc}" "$(_fill "${rwant}")" || return 1
        [[ "${output}" != *"${V[@IDX@]}"* ]] || { echo "${case}: reconcile reused an unchecked index"; return 1; }
    done <<'CASES'
present|present|0|=@IDX@ @PA@=@DA@ @PB@=@DB@|-|-
broken|broken|2|[CI-ERROR-ASSEMBLE-0010] service="@SVC@" tag="@TAG@"|-|-
absent|absent|1|=|0|=
unreachable|net|2|[CI-WARN-RESOLVE-0007] ref="@TAG@" cls=transient;i/o timeout|2|[CI-ERROR-ASSEMBLE-0007] service="@SVC@" rc=2
CASES
}

@test "assemble-stack walks the matrix; a bad matrix stops with raw" {
    # What: one assemble per service; bad JSON -> 0011.
    # Why: a jq error must not walk zero services silently.
    # From: Issue #1683 | PR #1858
    local calls="${BATS_TEST_TMPDIR}/asm-calls"
    : > "${calls}"
    ci_cmd_assemble() { printf '%s\n' "$1" >> "${calls}"; }
    CI_BUILD_MATRIX='{"include":[{"service":"ui"},{"service":"dns"},{"service":"ui"}]}' run ci_cmd_assemble_stack
    [ "${status}" -eq 0 ]
    [ "$(cat "${calls}")" = "$(printf 'dns\nui')" ]
    : > "${calls}"
    CI_BUILD_MATRIX='{"include":[ broken' run ci_cmd_assemble_stack
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-ASSEMBLE-0011]"* ]]
    [[ "${output}" == *"jq: parse error"* ]]
    [ ! -s "${calls}" ]
}

# What: PR candidate per row: host platform, per-service pin
# Why: no PR ledger; a missing image or host must fail
# From: Issue #1683 | PR #1858
@test "pr candidate pins each service to the daemon platform's digest" {
    local case answer rc want
    local -A V=(
        [@SA@]="$(_val name)" [@SB@]="$(_val name)" [@DA@]="$(_val digest)" [@DB@]="$(_val digest)"
        [@PLAT@]="$(_val platform)" [@REG@]="$(_val host)" [@REPO@]="$(_val name)/$(_val name)"
        [@ID@]="$(_val sha)" [@NET@]="$(_val name)"
    )
    # What: services, identity and registry from the row
    # Why: the PR candidate owns only platform and lookup
    # From: Issue #1683 | PR #1858
    ci_services() { printf '%s\n%s\n' "${V[@SA@]}" "${V[@SB@]}"; }
    _ci_identity_for() { printf '%s\n' "${V[@ID@]}"; }
    _ci_registry() { printf '%s\n' "${V[@REG@]}"; }
    export CI_RETRY_BACKOFF_BASE_SECONDS=0 GITHUB_REPOSITORY="${V[@REPO@]}"
    while IFS='|' read -r case answer rc want; do
        rm -f "${DS}/answers" "${DS}"/answer-used-*
        case "${answer}" in
            ok) _docker_answer ' version *' 0 "${V[@PLAT@]}"
                _docker_answer " buildx imagetools inspect */${V[@SA@]}:sha-${V[@ID@]}-${V[@PLAT@]##*/} *" 0 "${V[@DA@]}"
                _docker_answer " buildx imagetools inspect */${V[@SB@]}:sha-${V[@ID@]}-${V[@PLAT@]##*/} *" 0 "${V[@DB@]}" ;;
            missing) _docker_answer ' version *' 0 "${V[@PLAT@]}"
                _docker_answer ' buildx imagetools inspect *' 1 '' 'not found: manifest unknown' ;;
            reset) _docker_answer ' version *' 0 "${V[@PLAT@]}"
                _docker_answer ' buildx imagetools inspect *' 1 '' "${V[@NET@]}" ;;
            nohost) _docker_answer ' version *' 1 '' "${V[@NET@]}" ;;
        esac
        run _ci_stack_candidate_pr
        _expect "${case}" "${rc}" "$(printf '%b' "$(_fill "${want}")")" || return 1
    done <<'CASES'
ok|ok|0|=@SA@=@DA@\n@SB@=@DB@
missing|missing|2|[CI-ERROR-RESOLVE-0011];cls=not_found;[CI-ERROR-CANDIDATE-0002] service="@SA@"
reset|reset|2|[CI-ERROR-RESOLVE-0011];cls=transient;@NET@;[CI-ERROR-CANDIDATE-0002] service="@SA@"
nohost|nohost|2|[CI-ERROR-CANDIDATE-0005]
CASES
}

# What: result files become one ledger write; reruns converge.
# Why: one aggregator write per run (§26.1, §26.4).
# From: Issue #1683 | PR #1858
@test "aggregate: one write, rerun converges, partial and empty write nothing" {
    local ref file t ok bad empty before recs i1 i2 s1 s2 p1 p2 d1 d2 bs
    ref="refs/$(_val name)/$(_val name)"; file="$(_val name)"; t=$'\t'; bs="$(_val name)"
    i1="$(_val sha)"; i2="$(_val sha)"; s1="$(_val name)"; s2="$(_val name)"
    p1="$(_val platform)"; p2="$(_val platform)"; d1="$(_val digest)"; d2="$(_val digest)"
    ok="$(_val path)"; bad="$(_val path)"; empty="$(_val path)"
    mkdir -p "${ok}" "${bad}" "${empty}"
    CI_GIT_REMOTE=origin; CI_LEDGER_REF="${ref}"; CI_LEDGER_FILE="${file}"
    export CI_GIT_REMOTE CI_LEDGER_REF CI_LEDGER_FILE
    printf '{"service":"%s","platform":"%s","build_identity":"%s","state":"ACCEPTED","digest":"%s"}' \
        "${s1}" "${p1}" "${i1}" "${d1}" > "${ok}/$(_val name).json"
    printf '{"service":"%s","platform":"%s","build_identity":"%s","state":"ACCEPTED","digest":"%s"}' \
        "${s2}" "${p2}" "${i2}" "${d2}" > "${ok}/$(_val name).json"
    cp "${ok}"/*.json "${bad}/"
    printf '{"service":"%s","platform":"%s"}' "${bs}" "$(_val platform)" > "${bad}/$(_val name).json"
    _cas_setup
    cd "${CAS_A}"
    run ci_cmd_aggregate "${empty}"
    _expect empty 2 "[CI-ERROR-AGGREGATE-0003]" || return 1
    run ci_cmd_aggregate "${bad}"
    _expect partial 2 "[CI-ERROR-AGGREGATE-0004];raw:;${bs}" || return 1
    run git ls-remote --exit-code origin "${ref}"
    [ "${status}" -eq 2 ] || { echo "a failed run wrote the ledger"; return 1; }
    run ci_cmd_aggregate "${ok}"
    _expect write 0 "[CI-INFO-LEDGER-0004];aggregate records=2" || return 1
    git fetch --quiet origin "${ref}"
    before="$(git rev-list --count FETCH_HEAD)"
    recs="$(git cat-file -p "FETCH_HEAD:${file}")"
    [ "$(grep -c . <<< "${recs}")" -eq 2 ] || { echo "records: ${recs}"; return 1; }
    grep -qxF "${i1}${t}${s1}${t}${p1}${t}ACCEPTED${t}${d1}" <<< "${recs}" || { echo "no ${i1}: ${recs}"; return 1; }
    grep -qxF "${i2}${t}${s2}${t}${p2}${t}ACCEPTED${t}${d2}" <<< "${recs}" || { echo "no ${i2}: ${recs}"; return 1; }
    run ci_cmd_aggregate "${ok}"
    _expect rerun 0 "[CI-INFO-LEDGER-0005];aggregate records=2" || return 1
    git fetch --quiet origin "${ref}"
    [ "$(git rev-list --count FETCH_HEAD)" -eq "${before}" ] || { echo "rerun added a commit"; return 1; }
    [ "$(git cat-file -p "FETCH_HEAD:${file}")" = "${recs}" ] || { echo "rerun changed the records"; return 1; }
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

@test "release version copies follow the SOT; sync writes once" {
    # What: per row: one drifted copy -> its own id.
    # Why: Cargo, members, lock, VERSION follow the SOT.
    # From: Issue #1683 | PR #1858
    local m lk vf r k case drift rc want before
    m="$(_val path)"
    local -A V=(
        [@W@]="$(_val semver)" [@X@]="$(_val semver)" [@L@]="$(_val name)" [@MEM@]="$(_val name)"
        [@PKG@]="$(_val name)" [@DEP@]="$(_val name)" [@DV@]="$(_val semver)"
    )
    { _fill "$(printf '%s\n' 'release:' '  version: @W@' '  license: @L@')"; printf '\n'; _sot_block ci_variables; } > "${m}"
    lk="$(CI_MANIFEST="${m}" _ci_variable CI_CARGO_LOCK)" && vf="$(CI_MANIFEST="${m}" _ci_variable CI_VERSION_FILE)" || return 1
    _w() { { _fill "$(printf '%s\n' "${@:2}")"; echo; } > "$1"; }
    _rv() {
        r="${BATS_TEST_TMPDIR}/$(_val name)"
        mkdir -p "${r}/${V[@MEM@]}"
        _w "${r}/Cargo.toml" '[workspace]' 'members = [' '    "@MEM@",' ']' '' '[workspace.package]' 'version = "@W@"' 'license = "@L@"'
        _w "${r}/${V[@MEM@]}/Cargo.toml" '[package]' 'name = "@PKG@"' 'version.workspace = true' \
            'edition.workspace = true' 'license.workspace = true'
        _w "${r}/${lk}" '[[package]]' 'name = "@PKG@"' 'version = "@W@"' '' '[[package]]' 'name = "@DEP@"' 'version = "@DV@"'
        _w "${r}/${vf}" '@W@'
    }
    while IFS='|' read -r case drift rc want; do
        _rv
        case "${drift}" in
            none) ;;
            ws-version) sed -i "s/^version = \"${V[@W@]}\"\$/version = \"${V[@X@]}\"/" "${r}/Cargo.toml" ;;
            ws-license) sed -i "s/^license = \"${V[@L@]}\"\$/license = \"${V[@X@]}\"/" "${r}/Cargo.toml" ;;
            member-*) k="${drift#member-}"; sed -i "s/^${k}\.workspace = true\$/${k} = \"${V[@X@]}\"/" "${r}/${V[@MEM@]}/Cargo.toml" ;;
            lock) sed -i "s/^version = \"${V[@W@]}\"\$/version = \"${V[@X@]}\"/" "${r}/${lk}" ;;
            vfile) _w "${r}/${vf}" '@X@' ;;
            vfile-gone) mv "${r}/${vf}" "${r}/${vf}.gone" ;;
        esac
        CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" run _ci_version_release
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
clean|none|0|release-version=@W@ consumers=clean
ws-version|ws-version|1|[CI-ERROR-VERSION-0021];got="@X@" want="@W@"
ws-license|ws-license|1|[CI-ERROR-VERSION-0028];got="@X@" want="@L@"
member-version|member-version|1|[CI-ERROR-VERSION-0022] member="@MEM@" key="version"
member-edition|member-edition|1|[CI-ERROR-VERSION-0022] member="@MEM@" key="edition"
member-license|member-license|1|[CI-ERROR-VERSION-0022] member="@MEM@" key="license"
lock|lock|1|[CI-ERROR-VERSION-0025];package="@PKG@" got="@X@" want="@W@"
version-file|vfile|1|[CI-ERROR-VERSION-0024];got="@X@" want="@W@"
version-file-gone|vfile-gone|2|[CI-ERROR-VERSION-0023];raw:
CASES
    # What: sync writes the 3 copies once; rerun is no-op.
    # Why: copies follow the SOT; other lock rows untouched.
    # From: Issue #1683 | PR #1858
    _rv
    sed -i "s/^version = \"${V[@W@]}\"\$/version = \"${V[@X@]}\"/; s/^license = \"${V[@L@]}\"\$/license = \"${V[@X@]}\"/" \
        "${r}/Cargo.toml"
    sed -i "s/^version = \"${V[@W@]}\"\$/version = \"${V[@X@]}\"/" "${r}/${lk}"
    _w "${r}/${vf}" '@X@'
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" run _ci_version_release_sync
    _expect sync-drifted 0 "=sync=release-version version=${V[@W@]} changed=3" || return 1
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" run _ci_version_release
    _expect sync-then-verify 0 "release-version=${V[@W@]} consumers=clean" || return 1
    grep -qx "version = \"${V[@DV@]}\"" "${r}/${lk}" || { echo "other lock entry changed"; return 1; }
    before="$(cd "${r}" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" run _ci_version_release_sync
    _expect sync-converged 0 "=sync=release-version version=${V[@W@]} changed=0" || return 1
    [ "$(cd "${r}" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" = "${before}" ] || { echo "rerun wrote"; return 1; }
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" CI_VERSION_FILE="$(_val name)/$(_val name)" run _ci_version_release_sync
    _expect sync-unwritable 2 "[CI-ERROR-VERSION-0027];raw:" || return 1
}

@test "version verify fails closed per SOT consumer pin and ARG" {
    # What: per consumer: pin or ARG damage -> its own id.
    # Why: a missing pin or a second owner never passes.
    # From: Issue #1683 | PR #1858
    local dep df keys key val arg root m damage want
    key="$(_ci_build_matrix_platforms)"
    key="sha256_$(_ci_platform_field "${key%%$'\n'*}" apk "$(_val name)")"
    while IFS='|' read -r dep df keys; do
        root="$(_version_fixture_repo)" || return 1
        CI_REPO_ROOT="${root}" run --separate-stderr bash "${CI_SH}" version verify
        arg="$(sed -n "s/^key=${dep}\.consumer\.\([A-Za-z0-9_]*\) shape=bare\$/\1/p" <<< "${output}" | awk 'NR == 1')"
        val="$(_ci_block_entry_field external_versions "${dep}" "${key}")"
        [ -n "${arg}" ] && [ -n "${val}" ] || { echo "${dep}: arg='${arg}' ${key}='${val}': ${output}"; return 1; }
        for damage in pin-missing pin-malformed arg-gone arg-baked; do
            root="$(_version_fixture_repo)" m="${BATS_TEST_TMPDIR}/$(_val name).yml"
            cp "${CI_MANIFEST}" "${m}"
            case "${damage}" in
                pin-missing) grep -v "^    ${key}: ${val}\$" "${CI_MANIFEST}" > "${m}"; want="[CI-ERROR-BUILDARGS-0004];${dep}.${key}" ;;
                pin-malformed) sed "s/^    ${key}: ${val}\$/    ${key}: $(_val name)/" "${CI_MANIFEST}" > "${m}"
                    want="[CI-ERROR-BUILDARGS-0015];${dep}.${key}" ;;
                arg-gone) sed -i "/^ARG ${arg}\$/d" "${root}/${df}"; want="[CI-ERROR-VERSION-0008];name=\"${arg}\"" ;;
                arg-baked) sed -i "s/^ARG ${arg}\$/ARG ${arg}=$(_val name)/" "${root}/${df}"; want="[CI-ERROR-VERSION-0009];name=\"${arg}\"" ;;
            esac
            CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" run bash "${CI_SH}" version verify
            _expect "${dep}/${damage}" 2 "${want}" || return 1
        done
    done <<< "$(_ci_version_consumers)"
}

@test "version, verify and audit give one output and rc" {
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

@test "Dockerfile ARG grammar maps each shape to a state or id" {
    # What: per row: ARG lines -> ABSENT/BARE/FOUND or id.
    # Why: AG-VAL-036: read the real grammar or fail loud.
    # From: Issue #1683 | PR #1858
    local f case lines name rc want
    local -A V=(
        [@A@]="$(_val var)" [@B@]="$(_val var)" [@V@]="$(_val name)" [@W@]="$(_val name)" [@IMG@]="$(_val name)"
    )
    while IFS='|' read -r case lines name rc want; do
        f="${BATS_TEST_TMPDIR}/$(_val name)"
        [ "${lines}" = - ] || { _fill "${lines}"; echo; } | tr ';' '\n' > "${f}"
        run _ci_dockerfile_arg_default "${f}" "$(_fill "${name}")"
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
absent|FROM @IMG@;ARG @A@|@B@|0|=ABSENT
bare|FROM @IMG@;ARG @A@|@A@|0|=BARE
unquoted|FROM @IMG@;ARG @A@=@V@|@A@|0|=FOUND:@V@
double-quoted|FROM @IMG@;ARG @A@="@V@ @W@"|@A@|0|=FOUND:@V@ @W@
single-quoted|FROM @IMG@;ARG @A@='@V@ @W@'|@A@|0|=FOUND:@V@ @W@
lowercase-indented|FROM @IMG@;  arg @A@=@V@|@A@|0|=FOUND:@V@
redeclare-bare|ARG @A@;FROM @IMG@;ARG @A@|@A@|0|=BARE
redeclare-conflict|FROM @IMG@;ARG @A@=@V@;ARG @A@=@W@|@A@|2|[CI-ERROR-VERSION-0002]
continuation|FROM @IMG@;ARG @A@=@V@\|@A@|2|[CI-ERROR-VERSION-0003]
embedded-double|FROM @IMG@;ARG @A@="@V@"@W@"|@A@|2|[CI-ERROR-VERSION-0004]
embedded-single|FROM @IMG@;ARG @A@='@V@'@W@'|@A@|2|[CI-ERROR-VERSION-0015]
unquoted-space|FROM @IMG@;ARG @A@=@V@ @W@|@A@|2|[CI-ERROR-VERSION-0005]
bad-token|FROM @IMG@;ARG @A@ @V@|@A@|2|[CI-ERROR-VERSION-0006]
no-file|-|@A@|2|[CI-ERROR-VERSION-0001]
CASES
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

@test "setup.sh image platform guards map host and manifest" {
    # What: one row per host arch / buildx / manifest case
    # Why: a tag lacking this platform must fail closed
    # From: Issue #1683 | PR #1858
    local root plats p apk unk first second a1 a2 case arch state rc want w
    local -a ws
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    plats="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_platforms dns)"
    first="$(awk 'NR == 1' <<< "${plats}")" second="$(awk 'NR == 2' <<< "${plats}")"
    a1="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_platform_field "${first}" apk "$(_val name)")"
    a2="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_platform_field "${second}" apk "$(_val name)")"
    unk="arch${BATS_TEST_NUMBER}"
    [ -n "${second}" ] && [ -n "${a1}" ] && [ -n "${a2}" ] || { echo "inputs: ${plats} ${a1} ${a2}"; return 1; }
    # What: uname and docker arch map to the SOT platform
    # Why: setup.sh's host map must equal the SOT's arch map
    # From: Issue #1683 | PR #1858
    while IFS= read -r p; do
        apk="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_platform_field "${p}" apk "$(_val name)")"
        [ "$(host_image_platform "${apk}")" = "${p}" ] && [ "$(host_image_platform "${p#*/}")" = "${p}" ] \
            || { echo "host map for ${p}: ${apk}"; return 1; }
    done <<< "${plats}"
    ! host_image_platform "${unk}" || { echo "unknown arch mapped"; return 1; }
    TAG="v$(tr -d '[:space:]' < "${root}/VERSION")"
    export HOST_ARCH UNAME_REAL TAG FAULT="${BATS_TEST_NAME}"
    export REG PRE
    UNAME_REAL="$(type -P uname)"
    REG="$(resolve_lancache_image_registry "${root}/deploy/prod/.env")" PRE="$(resolve_lancache_image_prefix "${root}/deploy/prod/.env")"
    _tool_stub "${BIN}" uname <<'STUB'
[ "${1:-}" != -m ] || { printf '%s\n' "${HOST_ARCH:?}"; exit 0; }
exec "${UNAME_REAL:?}" "$@"
STUB
    # What: host arch and registry answer per row
    # Why: every fail-closed path names its own cause
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case arch state rc want; do
        rm -f "${DS}/single-platform" "${DS}/published" "${DS}/inspect-fail" "${DS}/fail-buildx"
        case "${state}" in
            -) ;;
            fail-buildx|inspect-fail) : > "${DS}/${state}" ;;
            *) printf '%s\n' "${state}" > "${DS}/single-platform" ;;
        esac
        HOST_ARCH="${arch}"
        if [ "${case%%-*}" = prebuilt ]; then
            _setup_sh_run 'PATH="${BIN}:${PATH}"; assert_prebuilt_image_platform_supported'
        else
            _setup_sh_run 'PATH="${BIN}:${PATH}"; assert_resolved_image_tag_platform_supported "${REG}" "${PRE}" "${TAG}"'
        fi
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [ "${want}" != - ] || continue
        IFS=';' read -r -a ws <<< "${want}"
        for w in "${ws[@]}"; do [[ "${output}" == *"${w}"* ]] || { echo "${case}: no '${w}': ${output}"; return 1; }; done
    done <<CASES
prebuilt-first|${a1}|-|0|-
prebuilt-second|${a2}|-|0|-
prebuilt-unknown|${unk}|-|1|'${unk}' has no container image platform
resolved-lacks|${a2}|${first}|1|does not publish a ${second} image;published: ${first}
resolved-single|${a1}|${first}|0|-
resolved-index|${a2}|<no value>/<no value>|0|-
resolved-unknown|${unk}|-|1|'${unk}' has no container image platform
resolved-nobuildx|${a1}|fail-buildx|1|docker buildx is required
resolved-unreachable|${a1}|inspect-fail|1|Failed to inspect ${REG}/${PRE}/dns:${TAG};${FAULT}
CASES
    # What: no docker on PATH fails closed, not silently
    # Why: the guard must never skip without its tool
    # From: Issue #1683 | PR #1858
    HOST_ARCH="${a1}"
    _path_without "${BATS_TEST_TMPDIR}/nodocker" docker
    _setup_sh_run 'PATH="${BATS_TEST_TMPDIR}/nodocker"; assert_resolved_image_tag_platform_supported "${REG}" "${PRE}" "${TAG}"'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"docker is required"* ]] || { echo "no docker: ${output}"; return 1; }
}

@test "migrate_env_for_update is a no-op on an already-converged .env" {
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

@test "runtime_env_file_for_install_dir prefers deploy/prod/.env.local when present" {
    # What: Deploy/prod prefers .env.local override.
    # Why: a git pull must not clobber operator prod values.
    # From: Issue #1683 | PR #1858
    local repo_root dp
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${repo_root}"
    dp="${BATS_TEST_TMPDIR}/deploy/prod"
    mkdir -p "${dp}"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env" ]
    : > "${dp}/.env.local"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env.local" ]
    [ "$(runtime_env_file_for_install_dir "${BATS_TEST_TMPDIR}/legacy")" = "${BATS_TEST_TMPDIR}/legacy/.env" ]
}

@test "setup quickstart install moves into deploy/prod once" {
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

@test "setup compose command runs compose on the stack's files" {
    # What: setup.sh compose equals stack_compose
    # Why: the systemd units start the stack through it
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" over want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    export DP="${t}/co/deploy/prod"
    _prod_install "${DP}"
    over="$(declare -f compose_file_args_for_install_dir | grep -o 'docker-compose\.override\.y[a-z]*ml' | awk 'NR == 1')"
    [ -n "${over}" ] || { echo "no override name in setup.sh"; return 1; }
    printf 'services:\n  %s:\n    image: %s\n' "${over%%.*}" "${LANCACHE_HELPER_IMAGE}" > "${DP}/${over}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; stack_compose "${DP}" "$(runtime_env_file_for_install_dir "${DP}")" config --services'
    [ "${status}" -eq 0 ] && grep -qx "${over%%.*}" <<< "${output}" || { echo "stack_compose: ${output}"; return 1; }
    want="$(sort <<< "${output}")"
    run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" PATH="${BIN}:${PATH}" bash "${root}/setup.sh" compose "${DP}" config --services
    [ "${status}" -eq 0 ] && [ "$(sort <<< "${output}")" = "${want}" ] || { echo "setup.sh compose: ${output}"; return 1; }
    run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" PATH="${BIN}:${PATH}" bash "${root}/setup.sh" compose
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Usage: setup.sh compose"* ]] || { echo "usage: ${output}"; return 1; }
}

@test "setup update pulls the checkout and continues on its setup.sh" {
    # What: update pulls, runs the new setup.sh, rolls back
    # Why: compose, templates, script move as one revision
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" main lo std ssl svc mark c2 c3 f p
    local -a pids=()
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
        timeout 600 busybox nc -lk -s "${p}" -p 80 -e true < /dev/null > /dev/null 2>&1 3>&- &
        pids+=("$!")
    done
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
        || { kill "${pids[@]}"; echo "update: ${output}"; return 1; }
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
        || { kill "${pids[@]}"; echo "rollback to ${c2} from ${c3}: ${output}"; return 1; }
    # What: a detached checkout updates in place, unmoved
    # Why: a pinned revision is the operator's choice
    # From: Issue #1683 | PR #1858
    g -C "${t}/co" checkout -q --detach
    _update
    kill "${pids[@]}"
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] && [[ "${output}" == *"pinned commit"* ]] \
        && [[ "${output}" != *"Continuing the update with"* ]] || { echo "pinned: ${output}"; return 1; }
}

@test "setup kea rollback applies a snapshot via the control agent" {
    # What: test, set, write in order; a fault stops early
    # Why: a half-applied Kea config breaks DHCP for the LAN
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" d kd kd2 old new case want rc v port
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${t}/repo/deploy/prod"
    _prod_install "${d}"
    # What: checkout Kea agent conf with a shifted port
    # Why: setup.sh must dial the conf's port, not a copy
    # From: Issue #1683 | PR #1858
    mkdir -p "${t}/repo/services/dhcp"
    port="$(( $(jq -er '.["Control-agent"]["http-port"]' "${root}/services/dhcp/kea-ctrl-agent.conf") + BATS_TEST_NUMBER + 1 ))"
    jq --argjson p "${port}" '.["Control-agent"]["http-port"] = $p' "${root}/services/dhcp/kea-ctrl-agent.conf" \
        > "${t}/repo/services/dhcp/kea-ctrl-agent.conf"
    export D="${d}" TOKEN FAULT="${BATS_TEST_NAME}"
    TOKEN="$(generate_secret_value KEA_CTRL_TOKEN hex32)"
    set_env_key KEA_CTRL_TOKEN "${TOKEN}" "${d}/.env"
    kd="$(kea_snapshot_host_dir "${d}" "${d}/.env" "$(prod_state_dir_for_key KEA_DATA_DIR "${d}/.env")")"
    old="$(( $(date +%s) - 60 ))000000000" new="$(date +%s)000000000"
    for v in "${old}" "${new}"; do mkdir -p "${kd}/${v}" && jq -nc --arg v "${v}" '{Dhcp4: {"user-context": {id: $v}}}' > "${kd}/${v}/dhcp4.json"; done
    mkdir -p "${kd}/${new}x" "${kd}/$(( new + 1 ))"
    _curl_stub
    # What: only finalized numeric snapshots, oldest first
    # Why: a half-written snapshot must never be applied
    # From: Issue #1683 | PR #1858
    _setup_sh_run 'list_kea_snapshot_ids "'"${kd}"'"'
    [ "${status}" -eq 0 ] && [ "${output}" = "$(printf '%s\n%s' "${old}" "${new}")" ] || { echo "ids: ${output}"; return 1; }
    _setup_sh_run 'list_kea_snapshot_ids "'"${t}/empty"'"; echo "[$?]"'
    [ "${status}" -eq 0 ] && [ "${output}" = "[0]" ] || { echo "empty root: ${output}"; return 1; }
    while IFS='|' read -r case want rc; do
        rm -f "${DS}"/kea.* "${DS}"/kea-* "${DS}/fail-curl" "${DS}/curl.argv"
        export SID=""
        case "${case}" in
            byid) SID="${old}" ;;
            testfail) printf '[{"result":1,"text":"%s"}]' "${FAULT}" > "${DS}/kea-config-test" ;;
            status) printf '503' > "${DS}/kea-status" ;;
            garbage) printf 'x%s' "${BATS_TEST_NUMBER}" > "${DS}/kea-config-test" ;;
            connect) : > "${DS}/fail-curl" ;;
            absent) SID="${new}0" ;;
        esac
        _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_kea_to_last_known_good_config "${D}" "${SID}" 1'
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [ ! -e "${DS}/curl.argv" ] || ! grep -qF -- "${TOKEN}" "${DS}/curl.argv" || { echo "${case}: token in argv"; return 1; }
        case "${case}" in
            byid|newest) [ "$(paste -sd, "${DS}/kea.commands")" = "config-test,config-set,config-write" ] \
                    && grep -qF -- "${TOKEN}" "${DS}/kea.cfg" && [[ "$(sort -u "${DS}/kea.urls")" == *":${port}/" ]] \
                    || { echo "${case}: $(cat "${DS}/kea.commands") $(cat "${DS}/kea.urls")"; return 1; } ;;
            testfail) [ "$(cat "${DS}/kea.commands")" = config-test ] || { echo "config-set after a failed test"; return 1; } ;;
        esac
    done <<CASES
byid|rolled back to known-good snapshot ${old}|0
newest|defaulting to the newest: ${new}|0
testfail|rejected the command (result=1): ${FAULT}|1
status|rejected the request with HTTP 503|1
garbage|Unrecognized response from Kea's Control Agent|1
connect|Failed to connect to Kea's Control Agent|1
absent|Snapshot '${new}0' not found|1
CASES
    # What: no stack, env, token; or a foreign snapshot dir
    # Why: each stops before any request reaches Kea
    # From: Issue #1683 | PR #1858
    cp "${d}/.env" "${t}/env.ok"
    while IFS='|' read -r case want; do
        cp "${t}/env.ok" "${d}/.env"; mkdir -p "${t}/nostack"; export D="${d}"
        case "${case}" in
            nostack) D="${t}/nostack" ;;
            noenv) rm -f "${d}/.env" ;;
            notoken) set_env_key KEA_CTRL_TOKEN "" "${d}/.env" ;;
            outside) set_env_key KEA_CONFIG_SNAPSHOT_DIR "${t}/elsewhere" "${d}/.env" ;;
        esac
        rm -f "${DS}/kea.commands"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_kea_to_last_known_good_config "${D}" "" 1'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${want}"* ]] && [ ! -e "${DS}/kea.commands" ] \
            || { echo "${case}: rc ${status}: ${output}"; return 1; }
    done <<CASES
nostack|No stack found in ${t}/nostack
noenv|No .env found for ${d}
notoken|KEA_CTRL_TOKEN is empty or missing
outside|is not under the Kea data mount
CASES
    # What: a moved snapshot dir inside the mount works
    # Why: UI, dhcp and setup.sh read one configured path
    # From: Issue #1683 | PR #1858
    cp "${t}/env.ok" "${d}/.env"
    v="$(dirname "$(get_env_var KEA_CONFIG_SNAPSHOT_DIR "${d}/.env")")/snaps${BATS_TEST_NUMBER}"
    set_env_key KEA_CONFIG_SNAPSHOT_DIR "${v}" "${d}/.env"
    kd2="$(prod_state_dir_for_key KEA_DATA_DIR "${d}/.env")/snaps${BATS_TEST_NUMBER}"
    mkdir -p "${kd2}/${old}" && cp "${kd}/${old}/dhcp4.json" "${kd2}/${old}/"
    rm -f "${DS}/kea.commands"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_kea_to_last_known_good_config "${D}" "" 1'
    [ "${status}" -eq 0 ] && [[ "${output}" == *"defaulting to the newest: ${old}"* ]] \
        && [ "$(paste -sd, "${DS}/kea.commands")" = "config-test,config-set,config-write" ] \
        || { echo "moved snapshot dir: rc ${status}: ${output}"; return 1; }
    cp "${t}/env.ok" "${d}/.env"
}

@test "setup dns rollback applies a zone snapshot via the listener" {
    # What: zones, snapshots, rollback per listener answer
    # Why: a wrong zone or silent failure keeps bad records
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" d z1 z2 old new case want rc
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${t}/repo/deploy/prod"
    _prod_install "${d}"
    z1="$(grep -oE '"[a-z0-9.-]+\."' "${root}/services/dns/nats-subscriber/src/zone_snapshots.rs" | awk 'NR == 1' | tr -d '"')"
    z2="$(grep -oE '"[a-z0-9.-]+\."' "${root}/services/dns/nats-subscriber/src/zone_snapshots.rs" | awk 'NR == 2' | tr -d '"')"
    [ -n "${z1}" ] && [ -n "${z2}" ] && [ "${z1}" != "${z2}" ] || { echo "zones: ${z1} ${z2}"; return 1; }
    old="$(( $(date +%s) - 60 ))" new="$(date +%s)"
    export D="${d}" Z1="${z1}" FAULT="${BATS_TEST_NAME}"
    generate_secret_value PDNS_API_KEY hex32 > "${DS}/pdns-api-key"
    _curl_stub
    _setup_sh_run 'canonical_dns_zone "${Z1%.}"; canonical_dns_zone "${Z1}"'
    [ "${output}" = "$(printf '%s\n%s' "${z1}" "${z1}")" ] || { echo "canonical: ${output}"; return 1; }
    _listener() {
        jq -nc --arg a "${z1}" --arg b "${z2}" --arg o "${old}" --arg n "${new}" \
            '{zones: {($a): [{id: $n, created_unix: ($n | tonumber)}, {id: $o, created_unix: ($o | tonumber)}], ($b): []}}' \
            > "${DS}/listener-snapshots"
        jq -nc '{applied: true, changed_names: ["a"], zone_check_passed: true, republished_to_nats: true, flush_ok: true, flush_failed_names: []}' \
            > "${DS}/listener-rollback"
        rm -f "${DS}/listener-status" "${DS}/listener.posts" "${DS}/fail-curl"
    }
    while IFS='|' read -r case want rc; do
        _listener
        export ZONE="${z1}" SID=""
        case "${case}" in
            nozone) ZONE="" ;;
            emptyzone) ZONE="${z2}" ;;
            byid) SID="${old}" ;;
            absent) SID="${new}0" ;;
            quote) SID="${old}\"x" ;;
            flush) jq -c '.flush_ok = false | .flush_failed_names = ["f"]' "${DS}/listener-rollback" > "${DS}/r" && mv "${DS}/r" "${DS}/listener-rollback" ;;
            notapplied) jq -c '.applied = false' "${DS}/listener-rollback" > "${DS}/r" && mv "${DS}/r" "${DS}/listener-rollback" ;;
            status) printf '500' > "${DS}/listener-status" ;;
            nokey) mv "${DS}/pdns-api-key" "${DS}/pdns-api-key.off" ;;
            unreachable) : > "${DS}/fail-curl" ;;
        esac
        _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_dns_to_last_known_good_config dns-standard "${D}" "${ZONE}" "${SID}" 1'
        [ ! -e "${DS}/pdns-api-key.off" ] || mv "${DS}/pdns-api-key.off" "${DS}/pdns-api-key"
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        case "${case}" in
            byid|newest) jq -e --arg z "${z1}" --arg i "${SID:-${new}}" '.zone == $z and .snapshot_id == $i' "${DS}/listener.posts" > /dev/null \
                    || { echo "${case}: request $(cat "${DS}/listener.posts")"; return 1; } ;;
            nozone) [[ "${output}" == *"${z1}"* && "${output}" != *"${z2}"* ]] || { echo "zone list: ${output}"; return 1; } ;;
        esac
    done <<CASES
nozone|A zone is required|1
emptyzone|No known-good snapshots found for zone ${z2}|1
byid|rolled back to known-good snapshot ${old}|0
newest|defaulting to the newest: ${new}|0
absent|Snapshot '${new}0' not found for zone ${z1}|1
quote|Snapshot '${old}"x' not found for zone ${z1}|1
flush|cache-flush publishes failed after rollback (f)|0
notapplied|did not report applied=true|1
status|rejected the request with HTTP 500|1
nokey|PDNS_API_KEY could not be resolved inside the dns-standard container|1
unreachable|Failed to reach the rollback listener inside dns-standard|1
CASES
    # What: no stack or no .env stops before any request
    # Why: the command must name what is missing
    # From: Issue #1683 | PR #1858
    mkdir -p "${t}/nostack"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_dns_to_last_known_good_config dns-standard "'"${t}/nostack"'" "${Z1}" "" 1'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"No stack found in ${t}/nostack"* ]] || { echo "nostack: ${output}"; return 1; }
    mv "${d}/.env" "${d}/.env.off"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; reset_dns_to_last_known_good_config dns-standard "${D}" "${Z1}" "" 1'
    mv "${d}/.env.off" "${d}/.env"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"No .env found for ${d}"* ]] || { echo "noenv: ${output}"; return 1; }
}

@test "setup reset command routes each service and refuses bad input" {
    # What: dns and kea reach their flows; others refused
    # Why: a typo must never roll back the wrong service
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export D="${t}/repo/deploy/prod"
    _prod_install "${D}"
    generate_secret_value PDNS_API_KEY hex32 > "${DS}/pdns-api-key"
    printf '{"zones":{}}' > "${DS}/listener-snapshots"
    _curl_stub
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_reset_to_last_known_good_config dns "${D}"'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"A zone is required"* ]] || { echo "dns route: ${output}"; return 1; }
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_reset_to_last_known_good_config "x'"${BATS_TEST_NUMBER}"'" "${D}"'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Unknown service 'x${BATS_TEST_NUMBER}'"* ]] || { echo "unknown: ${output}"; return 1; }
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_reset_to_last_known_good_config'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Usage: ./setup.sh reset-to-last-known-good-config <service>"* ]] || { echo "usage: ${output}"; return 1; }
}

@test "setup health baseline and gate tell a regression from old damage" {
    # What: baseline per container state; gate per baseline
    # Why: only a regression this update caused may block it
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" q host s1 s2 samples day want rc case base svcs lg
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    q="$(printf '%s\n' "${!_REGRESSED_SERVICE_SYSLOG_HOST[@]}" | sort | awk 'NR == 1')"
    host="${_REGRESSED_SERVICE_SYSLOG_HOST[${q}]}"
    s1="$(_prod_compose config --services | sort | grep -vxF -f <(printf '%s\n' "${!_REGRESSED_SERVICE_SYSLOG_HOST[@]}") | awk 'NR == 1')"
    s2="$(_prod_compose config --services | sort | grep -vxF -f <(printf '%s\n' "${!_REGRESSED_SERVICE_SYSLOG_HOST[@]}") | awk 'NR == 2')"
    samples="${_UPDATE_HEALTH_BASELINE_SAMPLES}" day="$(date -u +%Y%m%d)"
    [ -n "${q}" ] && [ -n "${host}" ] && [ -n "${s1}" ] && [ -n "${s2}" ] && [ "${samples}" -ge 2 ] \
        || { echo "inputs: ${q} ${host} ${s1} ${s2} ${samples}"; return 1; }
    export DP="${t}/repo/deploy/prod" GE="${t}/gate.env" S1="${s1}" Q="${q}" FAULT="${BATS_TEST_NAME}" BASE SVCS
    _prod_install "${DP}"
    _tool_stub "${BIN}" sleep <<<'printf "%s\n" "$1" >> "${DS}/sleeps"'
    _state() {
        rm -rf "${DS}"/health-* "${DS}"/status-* "${DS}"/restart-* "${DS}"/exitcode-* "${DS}"/gone-* \
            "${DS}/sleeps" "${DS}/fail-logs" "${t}/syslog"
        : > "${DS}/running"
        printf '%s\n' "IP_STANDARD=" "IP_SSL=" "LOGGING_ENABLED=${1:-1}" "SYSLOG_NG_LOG_DIR=${t}/syslog" > "${GE}"
    }
    _gate() { _setup_sh_run 'PATH="${BIN}:${PATH}"; _UPDATE_ENV_FILE="${GE}" _UPDATE_STACK_DIR="${DP}"; '"$1"; }
    # What: baseline is 1 only if every sample is healthy
    # Why: one lucky sample must not hide a flapping service
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case want; do
        _state
        case "${case}" in
            stable) printf 'healthy\n' > "${DS}/health-${s1}" ;;
            crashloop) printf 'unhealthy\n' > "${DS}/health-${s1}" ;;
            flapping) printf 'healthy\nunhealthy\nhealthy\n' > "${DS}/health-${s1}" ;;
            new) : > "${DS}/gone-${s1}" ;;
            oneshot) printf 'none\n' > "${DS}/health-${s1}"; printf 'exited\n' > "${DS}/status-${s1}"
                printf 'no\n' > "${DS}/restart-${s1}"; printf '0\n' > "${DS}/exitcode-${s1}" ;;
        esac
        _gate 'capture_stack_health_baseline "${S1}"; printf "[%s]\n" "${_UPDATE_HEALTH_BASELINE[${S1}]-absent}"'
        [ "${status}" -eq 0 ] && [ "${lines[-1]}" = "[${want}]" ] || { echo "${case}: ${output}"; return 1; }
    done <<CASES
stable|1
crashloop|0
flapping|0
new|absent
oneshot|1
CASES
    _state; printf 'healthy\n' > "${DS}/health-${s1}"
    _gate 'capture_stack_health_baseline "${S1}"'
    [ "$(wc -l < "${DS}/sleeps")" -eq $(( samples - 1 )) ] || { echo "sleeps: $(cat "${DS}/sleeps")"; return 1; }
    # What: the gate fails on regressions, not old damage
    # Why: an unrelated broken service must not roll back
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case rc want; do
        lg=1; [ "${case}" != quietoff ] || lg=0
        _state "${lg}"
        base="[${s1}]=1" svcs="${s1}"
        case "${case}" in
            oldbroken) base="[${s1}]=0"; printf 'unhealthy\n' > "${DS}/health-${s1}" ;;
            regressed|outside|fresh) printf 'unhealthy\n' > "${DS}/health-${s1}" ;;
            logsfail) printf 'unhealthy\n' > "${DS}/health-${s1}"; : > "${DS}/fail-logs" ;;
            quiet|quietoff|quietnofile) base="[${q}]=1" svcs="${q}"; printf 'unhealthy\n' > "${DS}/health-${q}" ;;
            gone) printf 'unhealthy\n' > "${DS}/health-${s1}"; : > "${DS}/gone-${s1}" ;;
            healthy) printf 'healthy\n' > "${DS}/health-${s1}" ;;
            mix) base="[${s1}]=0 [${s2}]=1" svcs="${s1} ${s2}"
                printf 'unhealthy\n' > "${DS}/health-${s1}"; printf 'unhealthy\n' > "${DS}/health-${s2}" ;;
        esac
        [ "${case}" != fresh ] || base=""
        case "${case}" in
            quiet|quietoff) mkdir -p "${t}/syslog/${host}" && printf 'tail-%s\n' "${host}" > "${t}/syslog/${host}/${day}.log" ;;
        esac
        BASE="${base}" SVCS="${svcs}"
        _gate 'eval "_UPDATE_HEALTH_BASELINE=(${BASE})"; wait_for_stack_health 6 ${SVCS}'
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        case "${case}" in
            quietoff|outside|regressed) [[ "${output}" != *"forwarded log lines"* ]] || { echo "${case}: syslog tail ran"; return 1; } ;;
            mix) [[ "${output}" != *"unhealthy during this update: ${s1}"* ]] || { echo "mix blamed ${s1}"; return 1; } ;;
        esac
    done <<CASES
oldbroken|0|so not blocking it): ${s1}
regressed|1|Last 50 log lines for regressed service '${s1}'
logsfail|1|Could not retrieve logs for '${s1}'
outside|1|regressed from healthy to unhealthy during this update: ${s1}
quiet|1|tail-${host}
quietoff|1|regressed from healthy to unhealthy during this update: ${q}
quietnofile|1|No forwarded syslog-ng log file found for '${q}' yet
gone|1|No container found for regressed service '${s1}'
fresh|1|regressed from healthy to unhealthy during this update: ${s1}
healthy|0|
mix|1|unhealthy during this update: ${s2}
CASES
}

@test "setup update step that dies still reaches the rollback" {
    # What: a die inside an update step runs the rollback
    # Why: an aborted step must never leave a half update
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export DP="${t}/repo/deploy/prod" FAULT="${BATS_TEST_NAME}" AWK_REAL STUBS="${t}/stubs" FAILKEY
    _prod_install "${DP}"
    FAILKEY="$(declare -f verify_stack_functional_health | grep -oE 'get_env_var [A-Z][A-Z0-9_]+' | awk 'NR == 1 { print $2 }')"
    [ -n "${FAILKEY}" ] || { echo "no key read in verify_stack_functional_health"; return 1; }
    AWK_REAL="$(type -P awk)"
    _tool_stub "${STUBS}" awk <<'STUB'
case " $* " in
    *" key=${FAILKEY:?} "*) echo "awk: injected read failure" >&2; exit 2 ;;
esac
exec "${AWK_REAL:?}" "$@"
STUB
    _tool_stub "${BIN}" sleep <<< ':'
    _setup_sh_run 'PATH="${STUBS}:${BIN}:${PATH}"; _UPDATE_ENV_FILE="${DP}/.env" _UPDATE_STACK_DIR="${DP}"
        roll() { echo rollback-ran; }; apply_stack_update_ordered "${DP}" roll || echo apply-failed'
    [[ "${output}" == *"injected read failure"* && "${output}" == *rollback-ran* && "${output}" == *apply-failed* ]] \
        || { echo "rc ${status}: ${output}"; return 1; }
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

@test "setup secondary bind-IP suggestion skips busy IPs and fails loud" {
    # What: free LAN IP first; listing error is rc 2, not 1
    # Why: a swallowed ss or ip error offered a busy address
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" std alt dev pfx case rc want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    std="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")"
    alt="$(get_env_var IP_SSL "${root}/deploy/prod/.env")"
    dev="lan${BATS_TEST_NUMBER}" pfx=$(( BATS_TEST_NUMBER % 8 + 16 ))
    export IPDS="${t}/ipds" IPBIN="${t}/ipbin" STD="${std}"
    mkdir -p "${IPDS}"
    _ip_stub "${IPBIN}"
    _tool_stub "${IPBIN}" fuser <<< 'exit 0'
    _tool_stub "${IPBIN}" lsof <<< 'exit 0'
    _tool_stub "${IPBIN}" ss <<'STUB'
c=0 ok=0
[ ! -e "${IPDS}/ss-calls" ] || read -r c < "${IPDS}/ss-calls"
printf '%s\n' "$((c + 1))" > "${IPDS}/ss-calls"
[ ! -e "${IPDS}/fail-ss" ] || read -r ok < "${IPDS}/fail-ss" || ok=0
[ ! -e "${IPDS}/fail-ss" ] || [ "${c}" -lt "${ok:-0}" ] || { echo "ss: netlink error" >&2; exit 1; }
cat "${IPDS}/ss"
STUB
    while IFS='|' read -r case rc want; do
        rm -f "${IPDS}/fail-ss" "${IPDS}/fail-addr" "${IPDS}/ss-calls"
        : > "${IPDS}/ss"
        printf '%s\n' "${std} ${pfx} ${dev}" "${alt} ${pfx} ${dev}" > "${IPDS}/addrs"
        case "${case}" in
            busy) printf 'udp UNCONN 0 0 %s:53 0.0.0.0:*\n' "${alt}" > "${IPDS}/ss" ;;
            ssfail) : > "${IPDS}/fail-ss" ;;
            ipfail) : > "${IPDS}/fail-addr" ;;
        esac
        _setup_sh_run 'PATH="${IPBIN}:${PATH}"; secondary_suggest_alternate_listen_ip "${STD}"'
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [ "${case}" != busy ] || { [ "${lines[-1]}" != "${alt}" ] && [ "${lines[-1]}" != "${std}" ] && is_valid_ipv4 "${lines[-1]}"; } \
            || { echo "busy: picked ${output}"; return 1; }
    done <<CASES
free|0|${alt}
busy|0|
ssfail|2|Failed to list the port 53 listeners of this host
ipfail|2|Failed to list the IPv4 addresses of this host
CASES
    # What: caller stops on a listing error, asks nothing
    # Why: rc 2 must not become an empty suggestion prompt
    # From: Issue #1683 | PR #1858
    printf 'udp UNCONN 0 0 %s:53 0.0.0.0:*\n' "${std}" > "${IPDS}/ss"
    printf '1\n' > "${IPDS}/fail-ss"
    rm -f "${IPDS}/ss-calls" "${IPDS}/fail-addr"
    printf '%s\n' 'set -euo pipefail' '. "$1"' 'PATH="${IPBIN}:${PATH}"' 'secondary_choose_listen_ip "${STD}"' > "${t}/tty-run.sh"
    run script -qec "bash ${t}/tty-run.sh ${BATS_TEST_TMPDIR}/setup-sh.sh" /dev/null
    [ "${status}" -eq 2 ] && [[ "${output}" != *"Use another Secondary bind IP"* ]] \
        && [[ "${output}" == *"Failed to list the port 53 listeners"* ]] || { echo "tty caller: rc ${status}: ${output}"; return 1; }
}

@test "setup helper image is the SOT's digest-pinned alpine" {
    # What: helper containers run only the SOT-pinned alpine
    # Why: a mutable alpine tag changes under a customer
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" want sot case rc msg
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    want="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field base_images "" alpine)"
    [[ "${want}" == *@sha256:* ]] || { echo "SOT alpine: ${want}"; return 1; }
    export VOL="v${BATS_TEST_NUMBER}" FX="${t}/fx"
    mkdir -p "${DS}/volumes/${VOL}" "${FX}/.github/yaml"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; path_manifest "${VOL}" > /dev/null; printf "[%s]\n" "${LANCACHE_HELPER_IMAGE}"'
    [ "${status}" -eq 0 ] && [ "${lines[-1]}" = "[${want}]" ] && [ "$(sort -u "${DS}/run-images")" = "${want}" ] \
        || { echo "run image: ${output} / $(cat "${DS}/run-images")"; return 1; }
    # What: unpinned, shadowed or missing SOT entries
    # Why: only the base_images pin may reach a docker run
    # From: Issue #1683 | PR #1858
    sot="${root}/.github/yaml/build-manifest.yml"
    while IFS='|' read -r case rc msg; do
        case "${case}" in
            unpinned) sed 's/^\(  alpine: "[^@"]*\)@sha256:[0-9a-f]*"/\1"/' "${sot}" ;;
            shadowed) awk '{ print } /^image_base:$/ { print "  alpine: \"decoy\"" }' "${sot}" ;;
            missing) grep -v '^  alpine: ' "${sot}" ;;
        esac > "${FX}/.github/yaml/build-manifest.yml"
        _setup_sh_run 'SCRIPT_DIR="${FX}"; require_helper_image; printf "[%s]\n" "${LANCACHE_HELPER_IMAGE}"'
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${msg}"* ]] || { echo "${case}: rc ${status}: ${output}"; return 1; }
    done <<CASES
unpinned|1|is not digest-pinned
shadowed|0|[${want}]
missing|1|defines no base_images.alpine
CASES
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

@test "apk-setup maps each case: steps, tagged repos, keys, CA" {
    # What: fixture root + apk stub per row: calls, codes.
    # Why: one owner sets repos, keys, CA and apk steps.
    # From: Issue #1683 | PR #1858
    local name pkgs repos keys ca fail want r bin w keyf
    local -a ws p
    local -A V=(
        [@H1@]="$(_val host)" [@H2@]="$(_val host)" [@H3@]="$(_val host)" [@P1@]="$(_val name)" [@P2@]="$(_val name)"
        [@TAG@]="$(_val name)" [@KF@]="$(_val name)" [@A@]="$(_val name)" [@B@]="$(_val name)"
        [@KEYDATA@]="$(_val name)" [@SYSCA@]="$(_val name)" [@CA@]="$(_val name)" [@BAD@]="$(_val digest | cut -d: -f2)"
    )
    bin="$(_val path)"; mkdir -p "${bin}"
    _tool_stub "${bin}" apk <<'STUB'
echo "APK $* cert=${SSL_CERT_FILE:-none}"
if [ -n "${SSL_CERT_FILE:-}" ] && grep -qF -- "${CA_MARK}" "${SSL_CERT_FILE}"; then echo "CA-IN-BUNDLE"; fi
[ "$1" != "${APK_FAIL:-}" ] || { echo "apk-boom"; exit 3; }
STUB
    keyf="${BATS_TEST_TMPDIR}/$(_val name)"; printf '%s\n' "${V[@KEYDATA@]}" > "${keyf}"
    V[@SHA@]="$(sha256sum "${keyf}" | cut -d' ' -f1)"
    while IFS='|' read -r name pkgs repos keys ca fail want; do
        r="$(_val path)"
        mkdir -p "${r}/etc/apk/keys" "${r}/etc/ssl/certs" "${r}/run/secrets"
        printf 'https://%s/%s\n' "${V[@H1@]}" "${V[@P1@]}" > "${r}/etc/apk/repositories"
        printf '%s\n' "${V[@SYSCA@]}" > "${r}/etc/ssl/certs/ca-certificates.crt"
        [ -z "${ca}" ] || printf '%s\n' "${V[@CA@]}" > "${r}/run/secrets/project_selfhosted_proxy_ca"
        read -r -a p <<< "$(_fill "${pkgs}")"
        PATH="${bin}:${PATH}" CA_MARK="${V[@CA@]}" CI_APK_ROOT="${r}" APK_TAGGED_REPOS="$(_fill "${repos}")" \
        APK_KEYS="$(_fill "${keys}")" APK_FAIL="${fail}" CI_HTTP_DOWNLOAD_CMD="$(_stub "cp '${keyf}' \"\$2\"")" \
            run bash "${CI_SH}" apk-setup "${p[@]}"
        IFS=';' read -r -a ws <<< "$(_fill "${want}")"
        for w in "${ws[@]}"; do
            case "${w}" in
                rc=*) [ "${status}" -eq "${w#rc=}" ] ;;
                file:*) grep -qF -- "${w#file:}" "${r}/etc/apk/repositories" ;;
                key:*) [ "$(cat "${r}/etc/apk/keys/${w#key:}")" = "${V[@KEYDATA@]}" ] ;;
                nokey:*) [ ! -e "${r}/etc/apk/keys/${w#nokey:}" ] ;;
                sysca) [ "$(cat "${r}/etc/ssl/certs/ca-certificates.crt")" = "${V[@SYSCA@]}" ] ;;
                !*) [[ "${output}" != *"${w#!}"* ]] ;;
                *) [[ "${output}" == *"${w}"* ]] ;;
            esac || { echo "${name}: '${w}': rc ${status}: ${output}"; return 1; }
        done
    done <<'CASES'
plain|@A@ @B@|||||rc=0;file:http://@H1@/@P1@;APK update --no-cache;APK upgrade --no-cache;APK add --no-cache @A@ @B@;!CA-IN-BUNDLE
no-pkgs||||||rc=0;APK upgrade --no-cache;!APK add
tagged|@A@ @B@@@TAG@|@TAG@=http://@H2@/@P2@|http://@H3@/@KF@=@SHA@|||rc=0;APK add --no-cache @A@;APK add --no-cache @B@@@TAG@;file:@@TAG@ http://@H2@/@P2@;key:@KF@
key-mismatch|@A@ @B@@@TAG@|@TAG@=http://@H2@/@P2@|http://@H3@/@KF@=@BAD@|||rc=2;CI-ERROR-FETCH-0003;!APK add --no-cache @B@@@TAG@;nokey:@KF@
upgrade-fails|@A@||||upgrade|rc=2;CI-ERROR-APKSETUP-0005;apk-boom;!APK add
proxy-ca|@A@|||y||rc=0;CA-IN-BUNDLE;sysca
CASES
}

# =========================================================
# PRODUCT RUNTIME: KNOWN-GOOD CONFIG SNAPSHOTS
# =========================================================

# What: stable fingerprint of a snapshot store.
# Why: equal prints prove no snapshot was added or changed.
# From: Issue #1683
_kgs_fingerprint() {
    ( cd "$1" && find . -type f | LC_ALL=C sort | xargs -r sha256sum )
}

@test "known-good rollback converges and retention stays bounded" {
    # What: lib every adapter sources, neutral validator.
    # Why: one owner test covers dns, proxy, dhcp-proxy.
    # From: Issue #1683
    local lib conf snap="${BATS_TEST_TMPDIR}/snap" fp1 h1 i
    lib="$(ci_context_path known-good)"
    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "${BATS_TEST_DIRNAME}/../../${lib}"
    conf="${BATS_TEST_TMPDIR}/svc.conf"
    for i in 1 2 3 4 5; do
        printf 'OK v%s\n' "${i}" > "${conf}"
        kgs_snapshot_create "${snap}" 3 svc "${conf}" 2>/dev/null
    done
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 3 ]
    printf 'BROKEN\n' > "${conf}"
    run kgs_snapshot_apply "${snap}" svc "! grep -q BROKEN '${conf}'" "${conf}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${conf}")" = "OK v5" ]
    fp1="$(_kgs_fingerprint "${snap}")"
    h1="$(sha256sum < "${conf}")"
    printf 'BROKEN\n' > "${conf}"
    run kgs_snapshot_apply "${snap}" svc "! grep -q BROKEN '${conf}'" "${conf}"
    [ "${status}" -eq 0 ]
    [ "$(sha256sum < "${conf}")" = "${h1}" ]
    [ "$(_kgs_fingerprint "${snap}")" = "${fp1}" ]
    ! grep -rq BROKEN "${snap}"
}

@test "known-good library edge cases fail closed" {
    # What: missing, staging, keep, reject, partial copy.
    # Why: a bad snapshot must never become the live config.
    # From: Issue #1683 | PR #1858
    local lib snap="${BATS_TEST_TMPDIR}/edge" c="${BATS_TEST_TMPDIR}/a.conf" b="${BATS_TEST_TMPDIR}/b.conf" v i new
    lib="$(ci_context_path known-good)"
    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "${BATS_TEST_DIRNAME}/../../${lib}"
    v="grep -q '^OK' '${c}'"
    run kgs_snapshot_create "${snap}" 3 t "${BATS_TEST_TMPDIR}/none.conf"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"[t][FATAL] candidate file missing"* ]]
    [ -z "$(kgs_list_snapshots "${snap}")" ]
    printf 'OK\n' > "${c}"
    run kgs_snapshot_create "${snap}" 3 t "${c}" "${b}"
    [ "${status}" -ne 0 ]
    [ -z "$(find "${snap}" -mindepth 1 -maxdepth 1)" ] || { echo "partial snapshot left"; ls -a "${snap}"; return 1; }
    run kgs_snapshot_apply "${snap}" t "${v}" "${c}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no known-good snapshots available"* ]]
    for i in 1 2 3 4 5; do printf 'OK %s\n' "${i}" > "${c}"; kgs_snapshot_create "${snap}" 3 t "${c}" 2> /dev/null; done
    [ "$(for i in $(kgs_list_snapshots "${snap}"); do cat "${snap}/${i}/a.conf"; done | paste -sd,)" = "OK 3,OK 4,OK 5" ]
    mkdir -p "${snap}/.staging.x"
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 3 ]
    for i in not-a-number "" 0; do printf 'OK k\n' > "${c}"; kgs_snapshot_create "${snap}" "${i}" t "${c}" 2> /dev/null; done
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 3 ] || { echo "clamp"; kgs_list_snapshots "${snap}"; return 1; }
    new="$(kgs_list_snapshots "${snap}" | tail -n 1)"
    printf 'BROKEN\n' > "${snap}/${new}/a.conf"
    printf 'CANDIDATE\n' > "${c}"
    run kgs_snapshot_apply "${snap}" t "${v}" "${c}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[t][REJECT]"*"[t][SELECT]"* ]]
    [ "$(cat "${c}")" = "OK k" ]
    i="$(kgs_new_snapshot_id)"
    mkdir -p "${snap}/${i}"
    printf 'CANDIDATE\n' > "${c}"
    run kgs_snapshot_apply "${snap}" t "${v}" "${c}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[t][REJECT] rejected known-good snapshot ${i}: incomplete"* ]]
    rm -rf "${snap}"
    printf 'BROKEN\n' > "${c}"
    kgs_snapshot_create "${snap}" 3 t "${c}" 2> /dev/null
    printf 'CANDIDATE\n' > "${c}"
    run kgs_snapshot_apply "${snap}" t "${v}" "${c}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"[t][FATAL]"* ]]
    [ "$(cat "${c}")" = CANDIDATE ]
}

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

@test "retention is_truthy matches the ui env_bool set" {
    # What: retention is_truthy per input, one table.
    # Why: same set as the ui env_bool: 1/true/yes/on.
    # From: Issue #842 | PR #1858
    local raw want v
    _load_retention_functions
    while IFS='|' read -r raw want; do
        v="$(printf '%b' "${raw}")"
        run is_truthy "${v}"
        [ "${status}" -eq "${want}" ] || { echo "is_truthy [${raw}]: rc ${status}, want ${want}"; return 1; }
    done <<'CASES'
1|0
true|0
TRUE|0
True|0
yes|0
YES|0
on|0
ON|0
 true |0
\ton\t|0
0|1
false|1
FALSE|1
no|1
off|1
|1
   |1
garbage|1
1x|1
truex|1
yesplease|1
CASES
}

@test "retention dir validation maps each path" {
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
}

@test "retention purge refuses a cache dir outside its prefix" {
    # What: maybe_purge refuses outside the prefix.
    # Why: no find/rm, stamp untouched, so a fix retries.
    # From: Issue #842 | PR #1858
    export CACHE_DIR="${BATS_TEST_TMPDIR}/outside/cache"
    export CACHE_DIR_ALLOWED_PREFIX="${BATS_TEST_TMPDIR}/expected-cache-root"
    export CACHE_VALID_DAYS=30 PURGE_STAMP="${BATS_TEST_TMPDIR}/purge.stamp"
    _load_retention_functions
    run maybe_purge
    [ "${status}" -eq 0 ]
    [ ! -f "${PURGE_STAMP}" ]
    [[ "${output}" == *"outside the expected"* ]]
}

@test "retention purge maps each cache state; stamp only on success" {
    # What: maybe_purge per cache state, one table.
    # Why: the stamp means purged; never on a failed pass.
    # From: Issue #872 | PR #1858
    local t="${BATS_TEST_TMPDIR}" name state ffail old new stamp msg w
    local -a ws
    export CACHE_DIR_ALLOWED_PREFIX="${t}" CACHE_VALID_DAYS=30
    _load_retention_functions
    while IFS='|' read -r name state ffail old new stamp msg; do
        export CACHE_DIR="${t}/${name}/cache" PURGE_STAMP="${t}/${name}/purge.stamp"
        mkdir -p "${t}/${name}"
        if [ "${state}" != missing ]; then
            mkdir -p "${CACHE_DIR}"
            truncate -s 1M "${CACHE_DIR}/old.bin" "${CACHE_DIR}/new.bin"
            touch -d '-40 days' "${CACHE_DIR}/old.bin"
            touch -d '-1 days' "${CACHE_DIR}/new.bin"
        fi
        [ "${state}" != stamped ] || date +%s > "${PURGE_STAMP}"
        if [ "${ffail}" = yes ]; then
            find() { echo "simulated permission denied" >&2; return 1; }
        fi
        run maybe_purge
        unset -f find
        [ "${status}" -eq 0 ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        case "${old}" in
            gone) [ ! -e "${CACHE_DIR}/old.bin" ] || { echo "${name}: old.bin kept: ${output}"; return 1; } ;;
            kept) [ -e "${CACHE_DIR}/old.bin" ] || { echo "${name}: old.bin gone: ${output}"; return 1; } ;;
        esac
        [ "${new}" != kept ] || [ -e "${CACHE_DIR}/new.bin" ] || { echo "${name}: new.bin gone"; return 1; }
        case "${stamp}" in
            yes) [ -f "${PURGE_STAMP}" ] || { echo "${name}: no stamp: ${output}"; return 1; } ;;
            no) [ ! -f "${PURGE_STAMP}" ] || { echo "${name}: stamp written: ${output}"; return 1; } ;;
        esac
        IFS=';' read -r -a ws <<<"${msg}"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] || [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
purge|present|no|gone|kept|yes|Purged
rate-limited|stamped|no|kept|kept|yes|-
missing-dir|missing|no|-|-|no|does not exist
find-error|present|yes|kept|kept|no|ERROR: find failed while scanning;simulated permission denied
CASES
    # What: a dir that appears later still gets purged.
    # Why: the missing-dir cycle must not use up the day.
    # From: Issue #872 | PR #1858
    export CACHE_DIR="${t}/later/cache" PURGE_STAMP="${t}/later/purge.stamp"
    mkdir -p "${t}/later"
    run maybe_purge
    [ "${status}" -eq 0 ]
    [ ! -f "${PURGE_STAMP}" ]
    mkdir -p "${CACHE_DIR}"
    truncate -s 1M "${CACHE_DIR}/old.bin"
    touch -d '-40 days' "${CACHE_DIR}/old.bin"
    run maybe_purge
    [ "${status}" -eq 0 ]
    [ ! -e "${CACHE_DIR}/old.bin" ] && [ -f "${PURGE_STAMP}" ] || { echo "later: ${output}"; return 1; }
}

@test "retention self-log rotation maps size, knobs and copy failure" {
    # What: self-log rotation per case, one call each.
    # Why: rotate only over budget; never lose the log.
    # From: Issue #1236 | PR #1858
    local t="${BATS_TEST_TMPDIR}" name live mb rot cpfail after nb msg d f b w
    local -a ws
    export FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="${t}"
    _load_retention_functions
    while IFS='|' read -r name live mb rot cpfail after nb msg; do
        d="${t}/${name}"; f="${d}/fluent-bit.log"; mkdir -p "${d}"
        export FLUENT_BIT_SELFLOG_DIR="${d}" FLUENT_BIT_SELFLOG_MAX_MB="${mb}" FLUENT_BIT_SELFLOG_MAX_ROTATIONS="${rot}"
        case "${live}" in
            small) printf 'small\n' > "${f}" ;;
            big) head -c 1100000 /dev/zero | tr '\0' 'x' > "${f}"; printf '\nMARKER-END\n' >> "${f}" ;;
        esac
        [ "${cpfail}" = no ] || cp() { echo "cp: simulated copy failure" >&2; return 1; }
        run maybe_rotate_fluent_bit_selflog
        unset -f cp
        [ "${status}" -eq 0 ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        case "${after}" in
            absent) [ ! -e "${f}" ] ;;
            small) [ "$(cat "${f}")" = small ] ;;
            empty) [ ! -s "${f}" ] && [ -e "${f}" ] ;;
            big) [ "$(stat -c '%s' "${f}")" -gt 1048576 ] ;;
        esac || { echo "${name}: live file not '${after}': ${output}"; return 1; }
        b="$(find "${d}" -maxdepth 1 -type f -name 'fluent-bit.log.*' | sort)"
        [ "$(grep -c . <<<"${b}")" -eq "${nb}" ] || { echo "${name}: backups '${b}', want ${nb}"; return 1; }
        if [ "${nb}" -gt 0 ]; then
            local body
            case "${b}" in
                *.zst) body="$(zstd -dqc "${b}")" ;;
                *) body="$(cat "${b}")" ;;
            esac
            [[ "${body}" == *MARKER-END* ]] || { echo "${name}: backup lost the content"; return 1; }
        fi
        IFS=';' read -r -a ws <<<"${msg}"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] || [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
no-file|none|1|5|no|absent|0|-
under-budget|small|1|5|no|small|0|-
over-budget|big|1|5|no|empty|1|rotating
copy-fails|big|1|5|yes|big|0|ERROR: failed to copy
mb-text|small|not-a-number|5|no|small|0|Invalid FLUENT_BIT_SELFLOG_MAX_MB
mb-zero|small|0|5|no|small|0|below the supported minimum
mb-huge|small|99999999999999|5|no|small|0|clamping to 1048576
mb-octal|small|018|5|no|small|0|-
rot-text|big|1|garbage|no|empty|1|Invalid FLUENT_BIT_SELFLOG_MAX_ROTATIONS
CASES
}

@test "retention self-log rotation keeps the newest backups only" {
    # What: over the cap the oldest backups go first.
    # Why: the backups themselves must not grow unbounded.
    # From: Issue #1236 | PR #1858
    local t="${BATS_TEST_TMPDIR}" d f i before
    export FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="${t}" FLUENT_BIT_SELFLOG_MAX_MB=1
    _load_retention_functions
    d="${t}/cap3"; f="${d}/fluent-bit.log"; mkdir -p "${d}"
    for i in 4 3 2 1; do
        printf 'old-%s\n' "${i}" > "${d}/fluent-bit.log.2026010${i}T000000Z"
        touch -d "-${i} days" "${d}/fluent-bit.log.2026010${i}T000000Z"
    done
    head -c 1100000 /dev/zero | tr '\0' 'x' > "${f}"
    export FLUENT_BIT_SELFLOG_DIR="${d}" FLUENT_BIT_SELFLOG_MAX_ROTATIONS=3
    run maybe_rotate_fluent_bit_selflog
    [ "${status}" -eq 0 ]
    ls -1 "${d}"
    [ ! -e "${d}/fluent-bit.log.20260104T000000Z" ]
    [ ! -e "${d}/fluent-bit.log.20260103T000000Z" ]
    [ -e "${d}/fluent-bit.log.20260102T000000Z" ]
    [ -e "${d}/fluent-bit.log.20260101T000000Z" ]
    [ "$(find "${d}" -maxdepth 1 -name 'fluent-bit.log.*' | grep -c .)" -eq 3 ]
    # What: a second call right after is a no-op.
    # Why: it runs every cycle; it must keep the backups.
    # From: Issue #1236 | PR #1858
    before="$(ls -1 "${d}")"
    run maybe_rotate_fluent_bit_selflog
    [ "${status}" -eq 0 ]
    [ "$(ls -1 "${d}")" = "${before}" ]
    # What: a leading-zero cap with an 8 does not abort.
    # Why: 08 is no octal; the math must stay base 10.
    # From: Issue #1236 | PR #1858
    d="${t}/cap08"; f="${d}/fluent-bit.log"; mkdir -p "${d}"
    for i in 1 2 3 4 5 6 7 8 9; do
        printf 'old\n' > "${d}/fluent-bit.log.2026010${i}T000000Z"
        touch -d "-${i} days" "${d}/fluent-bit.log.2026010${i}T000000Z"
    done
    head -c 1100000 /dev/zero | tr '\0' 'x' > "${f}"
    export FLUENT_BIT_SELFLOG_DIR="${d}" FLUENT_BIT_SELFLOG_MAX_ROTATIONS=08
    run maybe_rotate_fluent_bit_selflog
    [ "${status}" -eq 0 ] || { echo "cap 08: rc ${status}: ${output}"; return 1; }
    [ "$(find "${d}" -maxdepth 1 -name 'fluent-bit.log.*' | grep -c .)" -eq 8 ]
}

@test "retention syslog prune maps gate, age, size and knobs" {
    # What: maybe_prune_syslog per case: files, stamp, log.
    # Why: age first, then oldest-first; never today's file.
    # From: Issue #633 | PR #1858
    local t="${BATS_TEST_TMPDIR}" today name en gb days cd files gone kept stamp msg
    local d spec f mb age want before after got lo hi w
    local -a ws
    today="$(date -u +%Y%m%d).log"
    export SYSLOG_LOG_ROOT_ALLOWED_PREFIX="${t}"
    _load_retention_functions
    while IFS='|' read -r name en gb days cd files gone kept stamp msg; do
        d="${t}/${name}"
        export SYSLOG_ENABLED="${en}" SYSLOG_MAX_GB="${gb}" SYSLOG_RETENTION_DAYS="${days}"
        export SYSLOG_LOG_ROOT="${d}" SYSLOG_PRUNE_STAMP="${t}/${name}.stamp"
        unset SYSLOG_PRUNE_RETRY_COOLDOWN
        [ "${cd}" = - ] || export SYSLOG_PRUNE_RETRY_COOLDOWN="${cd}"
        if [ "${files}" != - ]; then
            mkdir -p "${d}/hostA"
            IFS=',' read -r -a ws <<<"${files}"
            for spec in "${ws[@]}"; do
                IFS=':' read -r f mb age <<<"${spec}"
                [ "${f}" = TODAY ] && f="${today}"
                truncate -s "${mb}M" "${d}/hostA/${f}"
                touch -d "-${age} days" "${d}/hostA/${f}"
            done
        fi
        before="$(date +%s)"
        run maybe_prune_syslog
        after="$(date +%s)"
        [ "${status}" -eq 0 ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        for want in "gone:${gone}" "kept:${kept}"; do
            IFS=',' read -r -a ws <<<"${want#*:}"
            for f in "${ws[@]}"; do
                [ "${f}" = - ] && continue
                [ "${f}" = TODAY ] && f="${today}"
                case "${want%%:*}" in
                    gone) [ ! -e "${d}/hostA/${f}" ] ;;
                    kept) [ -e "${d}/hostA/${f}" ] ;;
                esac || { echo "${name}: ${f} not ${want%%:*}: ${output}"; ls -l "${d}/hostA"; return 1; }
            done
        done
        case "${stamp}" in
            none) [ ! -e "${SYSLOG_PRUNE_STAMP}" ] || { echo "${name}: unexpected stamp"; return 1; } ;;
            *)
                got="$(cat "${SYSLOG_PRUNE_STAMP}")" || { echo "${name}: no stamp: ${output}"; return 1; }
                lo="${before}"; hi="${after}"
                [ "${stamp}" = now ] || { lo=$(( before - 86400 + ${stamp#retry:} )); hi=$(( after - 86400 + ${stamp#retry:} )); }
                [ "${got}" -ge "${lo}" ] && [ "${got}" -le "${hi}" ] || { echo "${name}: stamp ${got} not in ${lo}..${hi}"; return 1; }
                ;;
        esac
        IFS=';' read -r -a ws <<<"${msg}"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] || [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
off-false|false|10|30|-|old.log:1:999|-|old.log|none|-
off-text|1x|10|30|-|old.log:1:999|-|old.log|none|-
on-spaced| on |10|30|-|old.log:1:999|old.log|-|now|age > 30d
age|true|10|30|-|old.log:1:40,new.log:1:1|old.log|new.log|now|removed 1 file(s) older than 30d
under-budget|true|10|30|-|a.log:1:1,b.log:1:1|-|a.log,b.log|now|no size-based pruning needed
age-then-size|true|1|30|-|day1.log:100:45,day2.log:500:20,day3.log:700:1|day1.log,day2.log|day3.log|now|size budget, oldest-first
size-only|true|1|30|-|a.log:400:5,b.log:400:3,c.log:400:1|a.log|b.log,c.log|now|-
bad-knobs|true|x1|not-a-number|-|a.log:1:1|-|a.log|now|Invalid SYSLOG_MAX_GB;Invalid SYSLOG_RETENTION_DAYS
gb-zero|true|0|30|-|a.log:1:1|-|a.log|now|below the supported minimum
gb-ceiling|true|2000000|30|-|a.log:1:1|-|a.log|now|budget=1048576GB
gb-u32-over|true|9999999999|30|-|a.log:1:1|-|a.log|now|budget=1048576GB
gb-octal-010|true|010|30|-|a.log:9216:1|-|a.log|now|-
gb-octal-018|true|018|30|-|a.log:1:1|-|a.log|now|-
no-root|true|10|30|-|-|-|-|none|does not exist yet
today-only|true|1|30|-|TODAY:2000:0|-|TODAY|retry:3600|budget still exceeded
around-today|true|1|30|-|old.log:500:5,TODAY:900:0|old.log|TODAY|now|-
cooldown-120|true|1|30|120|TODAY:2000:0|-|TODAY|retry:120|retry in 120s
cooldown-huge|true|1|30|999999|TODAY:2000:0|-|TODAY|retry:86400|clamping to 86400
CASES
}

@test "retention syslog prune runs at most once a day" {
    # What: a second run inside 24h does nothing.
    # Why: the stamp rate-limits the full tree scan.
    # From: Issue #633 | PR #1858
    local d="${BATS_TEST_TMPDIR}/syslog"
    export SYSLOG_LOG_ROOT_ALLOWED_PREFIX="${BATS_TEST_TMPDIR}" SYSLOG_LOG_ROOT="${d}"
    export SYSLOG_ENABLED=true SYSLOG_MAX_GB=10 SYSLOG_RETENTION_DAYS=30
    export SYSLOG_PRUNE_STAMP="${BATS_TEST_TMPDIR}/syslog.stamp"
    _load_retention_functions
    mkdir -p "${d}/hostA"
    truncate -s 1M "${d}/hostA/old.log" "${d}/hostA/new.log"
    touch -d '-40 days' "${d}/hostA/old.log"
    run maybe_prune_syslog
    [ "${status}" -eq 0 ]
    [ ! -e "${d}/hostA/old.log" ]
    [ -e "${d}/hostA/new.log" ]
    touch -d '-999 days' "${d}/hostA/new.log"
    run maybe_prune_syslog
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -e "${d}/hostA/new.log" ]
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

@test "shared secret is generated once and never rotates on repeat" {
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
}

@test "shared secret fails closed on conflicts and converges" {
    # What: unwritable store, races, formats, 20 writers.
    # Why: services on different secrets lose their link.
    # From: Issue #858 | PR #1858
    local lib root d="${BATS_TEST_TMPDIR}/ss" i v
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    lib="$(ci_context_path shared-secret)"
    # shellcheck source=scripts/lib/shared-secret-bootstrap.sh
    source "${root}/${lib}"
    LANCACHE_SHARED_SECRET_GID="$(id -g)"; export LANCACHE_SHARED_SECRET_GID
    : > "${BATS_TEST_TMPDIR}/file"
    export LANCACHE_SHARED_SECRET_DIR="${BATS_TEST_TMPDIR}/file/secrets"
    run resolve_shared_secret k "real-op" lancache_gen_hex32
    [ "${status}" -eq 0 ]
    [ "${output}" = real-op ]
    run resolve_shared_secret k "real-op" lancache_gen_base64_32 require-persist
    [ "${status}" -ne 0 ]
    run bash -c 'set -euo pipefail; . "$1"
        if ! v="$(resolve_shared_secret k real-op lancache_gen_hex32)"; then v=FAILED; fi
        printf "%s" "${v}"' _ "${root}/${lib}"
    [ "${status}" -eq 0 ]
    [ "${output}" = real-op ]
    export LANCACHE_SHARED_SECRET_DIR="${d}"
    mkdir -p "${d}"
    printf 'old' > "${d}/k"
    mktemp() { return 1; }
    run resolve_shared_secret k "new-op" lancache_gen_hex32
    [ "${status}" -ne 0 ]
    [ "$(cat "${d}/k")" = old ]
    : > "${d}/e"
    run resolve_shared_secret e "new-op" lancache_gen_hex32
    [ "${status}" -ne 0 ]
    mktemp() { printf 'winner' > "${d}/w"; return 1; }
    run resolve_shared_secret w "op" lancache_gen_hex32
    [ "${status}" -ne 0 ]
    [ "$(cat "${d}/w")" = winner ]
    unset -f mktemp
    run resolve_shared_secret h "" lancache_gen_hex32
    [[ "${output}" =~ ^[0-9a-f]{64}$ ]]
    [ "$(cat "${d}/h")" = "${output}" ]
    run resolve_shared_secret b "" lancache_gen_base64_32
    [ "$(printf '%s' "${output}" | base64 -d | wc -c)" -eq 32 ]
    mkdir -p "${BATS_TEST_TMPDIR}/out"
    for i in $(seq 1 20); do
        ( v="$(resolve_shared_secret race "" lancache_gen_hex32)"; printf '%s\n' "${v}" > "${BATS_TEST_TMPDIR}/out/${i}" ) &
    done
    wait
    [ "$(sort -u "${BATS_TEST_TMPDIR}"/out/* | wc -l)" -eq 1 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/out/1")" = "$(cat "${d}/race")" ]
    [ -z "$(find "${d}" -maxdepth 1 -name '.secret.*')" ]
}

@test "prod nats command regenerates nats.conf idempotently" {
    # What: run the real prod nats command via compose.
    # Why: AG-OP-006; no image owns it, compose does.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.." bin="${BIN}"
    local cmd lib sb t first frag u dep
    mkdir -p "${bin}"
    for t in nats-server chown chgrp; do
        _tool_stub "${bin}" "${t}" <<'STUB'
exit 0
STUB
    done
    dep="$(_ci_variable CI_COMPOSE_FILE)"
    cmd="$(docker compose -f "${root}/${dep}" \
        config --format json | jq -er '.services.nats.command[0]')"
    lib="${root}/$(ci_context_path shared-secret)"
    export NATS_DNS_WRITER_USER=w-user NATS_DNS_REPLICA_USER=r-user
    for t in UI DNS_WRITER DNS_REPLICA CALLOUT SYS; do
        export "NATS_${t}_PASSWORD=pw-${t}"
    done
    for sb in a b; do
        sb="${BATS_TEST_TMPDIR}/${sb}"
        mkdir -p "${sb}"
        # What: undo compose $$ escape; sandbox fixed paths.
        # Why: the command hardcodes container-only paths.
        # From: Issue #1683
        sed -e 's/\$\$/$/g' \
            -e "s#/tmp/nats\.conf\.template#${sb}/tpl#g" \
            -e "s#/etc/nats#${sb}/etc#g" \
            -e "s#/var/log/lancache-nats#${sb}/log#g" \
            -e "s#/usr/local/lib/shared-secret-bootstrap\.sh#${lib}#g" \
            <<< "${cmd}" > "${sb}/run.sh"
        LANCACHE_SHARED_SECRET_DIR="${sb}/sec" PATH="${bin}:${PATH}" \
            run sh "${sb}/run.sh"
        [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
        [ ! -s "${sb}/etc/auth_callout.conf" ]
    done
    sb="${BATS_TEST_TMPDIR}/a"
    first="$(sed "s#${sb}#X#g" "${sb}/etc/nats.conf")"
    [ "$(sed "s#${BATS_TEST_TMPDIR}/b#X#g" "${BATS_TEST_TMPDIR}/b/etc/nats.conf")" = "${first}" ]
    frag='auth_callout { issuer: "x" }'
    printf '%s\n' "${frag}" > "${sb}/etc/auth_callout.conf"
    LANCACHE_SHARED_SECRET_DIR="${sb}/sec" PATH="${bin}:${PATH}" run sh "${sb}/run.sh"
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [ "$(sed "s#${sb}#X#g" "${sb}/etc/nats.conf")" = "${first}" ]
    [ "$(cat "${sb}/etc/auth_callout.conf")" = "${frag}" ]
    [ -z "$(find "${sb}/etc" -name '.nats.conf.*')" ]
    for u in w-user r-user; do
        awk -v u="user: \"${u}\"" 'index($0, u) { p = 1; next }
            p && /user:/ { exit } p' "${sb}/etc/nats.conf" > "${sb}/${u}"
        grep -qF '"lancache.dns.record"' "${sb}/${u}"
        grep -qF '"lancache.dns.flush"' "${sb}/${u}"
    done
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

# What: load the dns entrypoint zone functions + validator.
# Why: shared by the RPZ and SOA tests below.
# From: Issue #1072 | PR #1858
_load_dns_zone_functions() {
    local root
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dns/domain-validation.sh
    source "${root}/services/dns/domain-validation.sh"
    # shellcheck source=services/dns/entrypoint.sh
    source "$(_extract_functions "${root}/services/dns/entrypoint.sh" _dns_generate_rpz_zone _dns_soa_maintain_zone)"
}

@test "dns rpz zone maps each domain list shape" {
    # What: per list: ordered A/AAAA names, IPs, warnings.
    # Why: bare is exact, .x is wildcard only, bad is out.
    # From: Issue #1072 | PR #1858
    local d="${BATS_TEST_TMPDIR}/rpz" case list v6 a aaaa warn
    _load_dns_zone_functions
    while IFS='|' read -r case list v6 a aaaa warn; do
        rm -f "${d}.zone"
        printf '%b\n' "${list}" > "${d}.txt"
        run _dns_generate_rpz_zone "${d}.txt" "${d}.zone" 192.0.2.1 "${v6}"
        [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
        [ "$(awk '$3 == "IN" && $4 == "A" { print $1 }' "${d}.zone" | paste -sd,)" = "${a}" ] || {
            echo "${case}: A"; cat "${d}.zone"; return 1; }
        [ "$(awk '$3 == "IN" && $4 == "AAAA" { print $1 }' "${d}.zone" | paste -sd,)" = "${aaaa}" ] || {
            echo "${case}: AAAA"; cat "${d}.zone"; return 1; }
        [ -z "$(awk '$3 == "IN" && (($4 == "A" && $5 != "192.0.2.1") || ($4 == "AAAA" && $5 != "2001:db8::1"))' "${d}.zone")" ]
        [ "$(grep -c WARNING <<< "${output}")" -eq "${warn%%:*}" ] || { echo "${case}: ${output}"; return 1; }
        [ "${warn#*:}" = "${warn}" ] || [[ "${output}" == *"RPZ zone: ${warn#*:}"* ]]
        [ "$(sed -n '1,2p;4p' "${d}.zone" | paste -sd'|')" = '$ORIGIN rpz.|$TTL 60|@ NS localhost.' ]
    done <<'CASES'
bare|steam.com\nepic.com\ngog.com||steam.com,epic.com,gog.com||0
v6|content.steam.com|2001:db8::1|content.steam.com|content.steam.com|0
noise|# c\n\n  valid.com  \n\t# x\t\n\tanother.com\t||valid.com,another.com||0
wildcard|.wildcard.com\nnormal.com||*.wildcard.com,normal.com||0
mixed|exact.com\n.wildcard.com\nsub.exact.com|2001:db8::1|exact.com,*.wildcard.com,sub.exact.com|exact.com,*.wildcard.com,sub.exact.com|0
order|first.com\n.second.com\nthird.com||first.com,*.second.com,third.com||0
tld|good.example.com\ncom\nalso-good.example.com||good.example.com,also-good.example.com||1:com
star|*||||1:*
disabled|!disabled.example.com\n!.disabled-wild.example.com\n.still.example.com\nenabled.example.com||*.still.example.com,enabled.example.com||0
CASES
}

@test "dns rpz serial is 10 digits and never goes backwards" {
    # What: fresh 10-digit serial; old+1 on a clock skew.
    # Why: PowerDNS reloads RPZ only on a higher serial.
    # From: Issue #1072 | PR #1858
    local d="${BATS_TEST_TMPDIR}/rpz" s1 s2
    _load_dns_zone_functions
    printf 'test.com\n' > "${d}.txt"
    _dns_generate_rpz_zone "${d}.txt" "${d}.zone" 192.0.2.1
    s1="$(awk '$1 == "@" && $2 == "SOA" { print $5 }' "${d}.zone")"
    [[ "${s1}" =~ ^[0-9]{10}$ ]] || { echo "serial ${s1}"; return 1; }
    _dns_generate_rpz_zone "${d}.txt" "${d}.zone" 192.0.2.1
    s2="$(awk '$1 == "@" && $2 == "SOA" { print $5 }' "${d}.zone")"
    [ "${s2}" -gt "${s1}" ] || { echo "${s1} -> ${s2}"; return 1; }
    printf '@ SOA localhost. admin.rpz. 9999999999 3600 900 604800 60\n' > "${d}.zone"
    _dns_generate_rpz_zone "${d}.txt" "${d}.zone" 192.0.2.1
    [ "$(awk '$1 == "@" && $2 == "SOA" { print $5 }' "${d}.zone")" = 10000000000 ]
    grep -qx '@ SOA localhost. admin.rpz. 10000000000 3600 900 604800 60' "${d}.zone"
}

@test "dns soa maintainer anchors, bumps and normalises the zone" {
    # What: date anchor, +1, <2^31, refresh/retry, one dot.
    # Why: an RFC1982 decrease stops secondary transfers.
    # From: Issue #1095 | PR #1858
    local log="${BATS_TEST_TMPDIR}/soa" case soa_cur zone want rc path out
    _load_dns_zone_functions
    export PDNS_API_KEY=test-key PDNS_SOA_REFRESH=30 PDNS_SOA_RETRY=10
    # What: the dig mock reads soa_cur, not cur.
    # Why: dynamic scope shows the callee's empty local cur.
    # From: Issue #1095 | PR #1858
    dig() { [ -z "${soa_cur}" ] || printf 'localhost. admin.z. %s 10800 3600 604800 3600\n' "${soa_cur}"; }
    date() { if [ "$1" = +%y%m%d ]; then echo 260906; else command date "$@"; fi; }
    curl() {
        printf '%s\n' "$*" >> "${log}"
        [[ "$*" != *"%{http_code}"* ]] || { [ "${case}" = http500 ] && echo 500 || echo 204; }
    }
    while IFS='|' read -r case soa_cur zone want rc path out; do
        : > "${log}"
        run _dns_soa_maintain_zone "${zone}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [ "${out}" = - ] || [[ "${output}" == *"${out}"* ]] || { echo "${case}: ${output}"; return 1; }
        [ "${want}" = - ] && continue
        grep -q "\"content\":\"localhost. admin.z. ${want} 30 10 604800 3600\"" "${log}" || { echo "${case}"; cat "${log}"; return 1; }
        [ "${want}" -lt 2147483648 ]
        grep -q " ${path} " "${log}" || { echo "${case}: path"; cat "${log}"; return 1; }
        if grep -q '\.\.' "${log}"; then echo "${case}: double dot"; cat "${log}"; return 1; fi
    done <<'CASES'
old|5|lan|260906000|0|http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan.|-
sameday|260906500|lan.|260906501|0|http://127.0.0.1:8081/api/v1/servers/localhost/zones/lan.|-
dotted|5|30.172.in-addr.arpa.|260906000|0|http://127.0.0.1:8081/api/v1/servers/localhost/zones/30.172.in-addr.arpa.|-
nosoa||lan|-|1|-|SOA not readable yet
http500|5|lan|-|1|-|SOA PATCH failed: HTTP 500
CASES
}

@test "proxy domain rows classify each cdn list shape" {
    # What: roots, extra wildcard/exact hosts, skips.
    # Why: a wrong class means a wrong or missing cert.
    # From: Issue #1073 | PR #1858
    local root d="${BATS_TEST_TMPDIR}/rows" case list u w e r s warn k
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dns/domain-validation.sh
    source "${root}/services/dns/domain-validation.sh"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _proxy_is_one_label_past _collect_domain_rows)"
    # What: stub root = last two labels; bad-root.com fails.
    # Why: the real one needs the public suffix list loaded.
    # From: Issue #1073 | PR #1858
    _registrable_domain() {
        [ "$1" != bad-root.com ] || return 1
        printf '%s' "${1#"${1%.*.*}".}"
    }
    declare -ag _UNIQUE_DOMAINS _EXTRA_WILDCARD_BASES _EXTRA_EXACT_HOSTS
    declare -Ag _DOMAIN_IS_ROOT _SEEN_EXTRA_WILDCARD_BASE _SEEN_EXTRA_EXACT_HOST _ROOT_HAS_WILDCARD_ENTRY
    export DOMAINS_FILE="${d}.txt"
    while IFS='|' read -r case list u w e r s warn; do
        printf '%b\n' "${list}" > "${DOMAINS_FILE}"
        _collect_domain_rows 2> "${d}.err" || { echo "${case}: rc $?"; cat "${d}.err"; return 1; }
        k="$(printf '%s\n' "${!_ROOT_HAS_WILDCARD_ENTRY[@]}" | sort | paste -sd,)"
        [ "$(IFS=,; echo "${_UNIQUE_DOMAINS[*]}")|$(IFS=,; echo "${_EXTRA_WILDCARD_BASES[*]}")|$(IFS=,; echo "${_EXTRA_EXACT_HOSTS[*]}")|${k}|${_DOMAIN_ROWS_SKIPPED}" \
            = "${u}|${w}|${e}|${r}|${s}" ] || {
            echo "${case}: got $(IFS=,; echo "${_UNIQUE_DOMAINS[*]}")|$(IFS=,; echo "${_EXTRA_WILDCARD_BASES[*]}")|$(IFS=,; echo "${_EXTRA_EXACT_HOSTS[*]}")|${k}|${_DOMAIN_ROWS_SKIPPED}"
            return 1; }
        if [ "${warn}" = - ]; then
            [ ! -s "${d}.err" ] || { echo "${case}: unexpected stderr"; cat "${d}.err"; return 1; }
        else
            grep -qF "WARNING: ${warn}" "${d}.err" || { echo "${case}: no warning"; cat "${d}.err"; return 1; }
        fi
    done <<'CASES'
disabled|!disabled.com\nenabled.com|enabled.com||||0|-
disabledwild|!.dis.com\n.on.com|on.com|||on.com|0|-
invalid|com\ngood.com|good.com||||1|skipping invalid domain entry: com
noroot|bad-root.com\ngood.com|good.com||||1|could not derive a root domain for: bad-root.com
deepwild|.a.cdn.ea.com|ea.com|a.cdn.ea.com|||0|-
rootwild|.ea.com|ea.com|||ea.com|0|-
deepbare|a.cdn.ea.com|ea.com||a.cdn.ea.com||0|-
manylabels|a.b.c.d.ea.com|ea.com||a.b.c.d.ea.com||0|-
onepast|cdn.ea.com|ea.com||||0|-
bareroot|ea.com|ea.com||||0|-
distinctwild|.x.ea.com\n.y.ea.com|ea.com|x.ea.com,y.ea.com|||0|-
dupwild|.x.ea.com\n.x.ea.com|ea.com|x.ea.com|||0|-
bothways|.a.b.ea.com\na.b.ea.com|ea.com|a.b.ea.com|a.b.ea.com||0|-
dupexact|a.b.ea.com\na.b.ea.com|ea.com||a.b.ea.com||0|-
mixedroots|.ea.com\nsteam.com|ea.com,steam.com|||ea.com|0|-
deeponly|.a.ea.com|ea.com|a.ea.com|||0|-
mixed|!off.com\non1.com\n# c\n\n  on2.com  |on1.com,on2.com||||0|-
CASES
}

@test "dns zone create tolerates only 'exists already' under set -e" {
    # What: each create-zone outcome under set -eu pipefail.
    # Why: a swallowed backend error leaves a zone missing.
    # From: Issue #1683 | PR #1858
    local root s fe case prc msg want out
    s="$(_val path)"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    fe="$(_extract_functions "${root}/services/dns/entrypoint.sh" _dns_ensure_zone_exists)" || return 1
    while IFS='|' read -r case prc msg want out; do
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
            'pdnsutil() { echo "CALL $*"; [ -z "${MSG}" ] || echo "${MSG}" >&2; return "${PRC}"; }' \
            "source '${fe}'" \
            '_dns_ensure_zone_exists lan' 'echo CANARY' > "${s}"
        PRC="${prc}" MSG="${msg}" run bash "${s}"
        [ "${status}" -eq "${want}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${out}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
created|0||0|CANARY
exists|1|Zone 'lan' exists already|0|CANARY
upper|1|EXISTS ALREADY|0|CANARY
reversed|1|Zone 'lan' already exists|1|FATAL: failed to create zone 'lan'
backend|1|Error: Unable to open database connection|1|FATAL: failed to create zone 'lan': CALL --config-dir=/etc/pdns/auth create-zone lan
CASES
    PRC=1 MSG="Error: Unable to open database connection" run bash "${s}"
    [[ "${output}" == *"Unable to open database connection"* ]]
    [[ "${output}" != *CANARY* ]]
}

# What: write a set -euo pipefail script calling dns fns.
# Why: the entrypoint runs them under exactly these options.
# From: Issue #1683 | PR #1858
_dns_tsig_script() {
    local root="$1" s="$2" tsig_call="$3" fs fe
    fs="$(_extract_functions "${root}/scripts/lib/shared-secret-bootstrap.sh" secret_is_placeholder)" || return 1
    fe="$(_extract_functions "${root}/services/dns/entrypoint.sh" configure_ddns_tsig import_ddns_tsig_key \
        _dns_set_zone_metadata dns_xfr_primary_endpoint _dns_configure_primary_zone_replication \
        _dns_ensure_secondary_zone)" || return 1
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        'pdnsutil() {' '    echo "$*" >> "${CALLS}"' \
        '    case "${PMODE}:$*" in' \
        '        fail:*) return 1 ;;' \
        '        exists:*create-secondary*) echo "Zone '"'"'lan'"'"' exists already" >&2; return 1 ;;' \
        '        broken:*create-secondary*) echo "Error: backend down" >&2; return 1 ;;' \
        '    esac' '}' \
        'getent() { echo x >> "${GETENT}"; [ "$(wc -l < "${GETENT}")" -ge "${RESOLVE_AT}" ] || return 2; echo "10.0.0.5 STREAM $2"; }' \
        'sleep() { :; }' \
        "source '${fs}'" \
        "source '${fe}'" \
        'DDNS_TSIG_NAME=lancache-ddns-key DDNS_TSIG_ALGORITHM=hmac-sha256' \
        'DDNS_UPDATE_ZONES=(lan 1.168.192.in-addr.arpa)' \
        "${tsig_call}" 'echo CANARY' > "${s}"
}

@test "dns tsig and zone replication issue the exact pdnsutil calls" {
    # What: per case the ordered pdnsutil calls, rc, output.
    # Why: unset key must revoke; a secondary never writes.
    # From: Issue #1683 | PR #1858
    local root s="${BATS_TEST_TMPDIR}/tsig.sh" case tsig_call key marker notify pmode rc calls out m
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    m="${BATS_TEST_TMPDIR}/allow-unsigned"
    export CALLS="${BATS_TEST_TMPDIR}/calls" GETENT="${BATS_TEST_TMPDIR}/getent" RESOLVE_AT=1
    while IFS='|' read -r case tsig_call key marker notify pmode rc calls out; do
        _dns_tsig_script "${root}" "${s}" "${tsig_call}"
        : > "${CALLS}"; : > "${GETENT}"; rm -f "${m}"
        [ "${marker}" = 0 ] || : > "${m}"
        DDNS_TSIG_KEY="${key}" DDNS_ALLOW_UNSIGNED_MARKER="${m}" DNS_XFR_NOTIFY_TARGETS="${notify}" \
            PMODE="${pmode}" run bash "${s}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${out}"* ]] || { echo "${case}: ${output}"; return 1; }
        [ "$(sed 's#^--config-dir=/etc/pdns/auth ##' "${CALLS}" | paste -sd';')" = "${calls}" ] || {
            echo "${case}: calls"; cat "${CALLS}"; return 1; }
    done <<'CASES'
unset|configure_ddns_tsig||0||ok|0|set-meta lan TSIG-ALLOW-DNSUPDATE;set-meta 1.168.192.in-addr.arpa TSIG-ALLOW-DNSUPDATE;delete-tsig-key lancache-ddns-key|prior authorization has been revoked
unsetfail|configure_ddns_tsig||0||fail|0|set-meta lan TSIG-ALLOW-DNSUPDATE;set-meta 1.168.192.in-addr.arpa TSIG-ALLOW-DNSUPDATE;delete-tsig-key lancache-ddns-key|CANARY
key|configure_ddns_tsig|k-real|0||ok|0|import-tsig-key lancache-ddns-key hmac-sha256 k-real;set-meta lan TSIG-ALLOW-DNSUPDATE lancache-ddns-key;set-meta 1.168.192.in-addr.arpa TSIG-ALLOW-DNSUPDATE lancache-ddns-key|Configured TSIG-authenticated DDNS updates
unsigned|configure_ddns_tsig|k-real|1||ok|0|import-tsig-key lancache-ddns-key hmac-sha256 k-real;set-meta lan TSIG-ALLOW-DNSUPDATE;set-meta 1.168.192.in-addr.arpa TSIG-ALLOW-DNSUPDATE|WARNING: DDNS TSIG enforcement relaxed
placeholder|configure_ddns_tsig|CHANGE_ME|0||ok|1||FATAL: DDNS_TSIG_KEY is still set to a default placeholder
import|import_ddns_tsig_key|k-real|0||ok|0|import-tsig-key lancache-ddns-key hmac-sha256 k-real|CANARY
importempty|import_ddns_tsig_key||0||ok|1||FATAL: DDNS_TSIG_KEY is required
primary|_dns_configure_primary_zone_replication lan|k|0|dns-ssl:5300,192.0.2.53:5300|ok|0|zone set-kind lan primary;set-meta lan SOA-EDIT-DNSUPDATE INCREASE;set-meta lan SOA-EDIT-API INCREASE;set-meta lan NOTIFY-DNSUPDATE 1;tsigkey activate lan lancache-ddns-key primary;set-meta lan ALSO-NOTIFY 10.0.0.5:5300 192.0.2.53:5300|CANARY
primarynone|_dns_configure_primary_zone_replication lan|k|0||ok|0|zone set-kind lan primary;set-meta lan SOA-EDIT-DNSUPDATE INCREASE;set-meta lan SOA-EDIT-API INCREASE;set-meta lan NOTIFY-DNSUPDATE 1;tsigkey activate lan lancache-ddns-key primary|CANARY
secnew|_dns_ensure_secondary_zone lan 192.0.2.10:5300|k|0||ok|0|zone create-secondary lan 192.0.2.10:5300;tsigkey activate lan lancache-ddns-key secondary|CANARY
secexists|_dns_ensure_secondary_zone lan 192.0.2.10:5300|k|0||exists|0|zone create-secondary lan 192.0.2.10:5300;zone set-kind lan secondary;zone change-primary lan 192.0.2.10:5300;tsigkey activate lan lancache-ddns-key secondary|CANARY
secbroken|_dns_ensure_secondary_zone lan 192.0.2.10:5300|k|0||broken|1|zone create-secondary lan 192.0.2.10:5300|FATAL: failed to create secondary zone 'lan': Error: backend down
CASES
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

@test "dns xfr endpoint keeps IPs, resolves names, fails closed" {
    # What: IP passthrough, name after retries, bad form.
    # Why: NOTIFY/AXFR need an IPv4; a bad value must stop.
    # From: Issue #1683 | PR #1775
    local root s="${BATS_TEST_TMPDIR}/xfr.sh" case ep at rc out tries
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export CALLS="${BATS_TEST_TMPDIR}/calls" GETENT="${BATS_TEST_TMPDIR}/getent"
    while IFS='|' read -r case ep at rc out tries; do
        _dns_tsig_script "${root}" "${s}" "dns_xfr_primary_endpoint '${ep}' DNS_XFR_PRIMARY; echo"
        : > "${GETENT}"
        RESOLVE_AT="${at}" PMODE=ok run bash "${s}"
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${out}"* ]] || { echo "${case}: ${output}"; return 1; }
        [ "$(wc -l < "${GETENT}")" -eq "${tries}" ] || { echo "${case}: tries $(wc -l < "${GETENT}")"; return 1; }
    done <<'CASES'
ip|192.0.2.53:5300|1|0|192.0.2.53:5300|0
name|dns-ssl:5300|3|0|10.0.0.5:5300|3
noport|dns-ssl|1|1|FATAL: DNS_XFR_PRIMARY must use host:port form|0
never|dns-ssl:5300|99|1|did not resolve to an IPv4 address after 30s|30
CASES
}

@test "proxy config adapter snapshots, rolls back, migrates ACL" {
    # What: create, skip, roll back, incomplete, migrate.
    # Why: nginx must never start on an invalid config.
    # From: Issue #1683 | PR #1858
    local root bin="${BIN}" l="${BATS_TEST_TMPDIR}/live" snap id mt
    local n p a
    local -a ids=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "${root}/$(ci_context_path known-good)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" \
        _proxy_validate_snapshot_or_rollback _migrate_legacy_proxy_snapshots_for_stream_acl)"
    _tool_stub "${bin}" nginx <<'SH'
if grep -q BROKEN "${NGINX_TEST_CONFIG_FILE}"; then echo "nginx: test failed" >&2; exit 1; fi
SH
    mkdir -p "${l}"
    n="${l}/nginx.conf" p="${l}/proxy-params.conf" a="${l}/00-stream-client-acl.conf"
    snap="${BATS_TEST_TMPDIR}/snap"
    export PATH="${bin}:${PATH}" NGINX_TEST_CONFIG_FILE="${n}" PROXY_CONFIG_SNAPSHOT_DIR="${snap}" \
        KEEP_KNOWN_GOOD_CONFIGS=3 _DOMAIN_ROWS_SKIPPED=0
    printf 'BROKEN\n' > "${n}"
    run _proxy_validate_snapshot_or_rollback "${n}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no known-good nginx config snapshot is available"* ]]
    [ "$(cat "${n}")" = BROKEN ]
    printf 'OK n1\n' > "${n}"; printf 'OK p1\n' > "${p}"
    run _proxy_validate_snapshot_or_rollback "${n}" "${p}"
    [[ "${output}" == *"[known-good-snapshot][proxy][CREATE]"* ]]
    printf 'OK n2\n' > "${n}"
    _DOMAIN_ROWS_SKIPPED=1 run _proxy_validate_snapshot_or_rollback "${n}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rows were skipped; NOT snapshotting"* ]]
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 1 ]
    run _proxy_validate_snapshot_or_rollback "${n}"
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 2 ]
    printf 'BROKEN n3\n' > "${n}"; printf 'BROKEN p3\n' > "${p}"
    run _proxy_validate_snapshot_or_rollback "${n}" "${p}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"incomplete (missing at least one candidate file)"*"[proxy][SELECT]"*"NOT the newly generated config"* ]]
    [ "$(cat "${n}")|$(cat "${p}")" = "OK n1|OK p1" ]
    rm -rf "${snap}"
    printf 'OK n1\n' > "${n}"
    _proxy_validate_snapshot_or_rollback "${n}" 2> /dev/null
    printf 'BROKEN n2\n' > "${n}"
    run _proxy_validate_snapshot_or_rollback "${n}" "${p}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"incomplete"*"no known-good nginx config snapshot is available"* ]]
    rm -rf "${snap}"
    export KEEP_KNOWN_GOOD_CONFIGS=2
    for id in 1 2 3 4; do printf 'OK r%s\n' "${id}" > "${n}"; _proxy_validate_snapshot_or_rollback "${n}" 2> /dev/null; done
    [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 2 ]
    # What: legacy snapshot gets an empty ACL; others stay.
    # Why: never weaken a saved allowlist by guessing it.
    # From: Issue #1683 | PR #1858
    rm -rf "${snap}"
    export KEEP_KNOWN_GOOD_CONFIGS=5
    printf 'legacy n\n' > "${n}"; printf 'legacy p\n' > "${p}"
    kgs_snapshot_create "${snap}" 5 proxy "${n}" "${p}" 2> /dev/null
    printf 'allow 10.0.0.0/8;\n' > "${a}"
    kgs_snapshot_create "${snap}" 5 proxy "${n}" "${p}" "${a}" 2> /dev/null
    printf 'include /etc/nginx/stream.d/access.d/00-stream-client-acl.conf;\n' > "${n}"
    kgs_snapshot_create "${snap}" 5 proxy "${n}" "${p}" "${a}" 2> /dev/null
    mapfile -t ids < <(kgs_list_snapshots "${snap}")
    rm "${snap}/${ids[2]}/00-stream-client-acl.conf"
    mt="$(stat -c %Y "${snap}/${ids[1]}/00-stream-client-acl.conf")"
    run _migrate_legacy_proxy_snapshots_for_stream_acl "${snap}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[MIGRATE]"*"${ids[0]}"* ]]
    [[ "${output}" == *"snapshot ${ids[2]} declares the stream ACL but is missing"* ]]
    [ -f "${snap}/${ids[0]}/00-stream-client-acl.conf" ]
    [ ! -s "${snap}/${ids[0]}/00-stream-client-acl.conf" ]
    [ "$(cat "${snap}/${ids[1]}/00-stream-client-acl.conf")" = 'allow 10.0.0.0/8;' ]
    [ "$(stat -c %Y "${snap}/${ids[1]}/00-stream-client-acl.conf")" = "${mt}" ]
    [ ! -e "${snap}/${ids[2]}/00-stream-client-acl.conf" ]
    printf 'BROKEN\n' > "${a}"
    run kgs_snapshot_apply "${snap}" proxy true "${n}" "${p}" "${a}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"snapshot ${ids[2]}: incomplete"*"[proxy][SELECT]"* ]]
    [ "$(cat "${a}")" = 'allow 10.0.0.0/8;' ]
}

@test "dhcp-proxy config adapter snapshots, rolls back, reports" {
    # What: refuse, create, roll back, keep, failed write.
    # Why: dnsmasq must never start on an invalid config.
    # From: Issue #1683 | PR #1858
    local root bin="${BIN}" c="${BATS_TEST_TMPDIR}/dnsmasq.conf" i
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "${root}/$(ci_context_path known-good)"
    # shellcheck source=services/dhcp-proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp-proxy/entrypoint.sh" _dhcp_proxy_validate_snapshot_or_rollback)"
    _tool_stub "${bin}" dnsmasq <<'SH'
f=""; while [ $# -gt 0 ]; do case "$1" in -C) f="$2"; shift 2 ;; *) shift ;; esac; done
if grep -q BROKEN "${f}"; then echo "dnsmasq: syntax check failed" >&2; exit 1; fi
SH
    export PATH="${bin}:${PATH}" DHCP_PROXY_CONFIG_SNAPSHOT_DIR="${BATS_TEST_TMPDIR}/snap" KEEP_KNOWN_GOOD_CONFIGS=3
    printf 'BROKEN\n' > "${c}"
    run _dhcp_proxy_validate_snapshot_or_rollback "${c}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no known-good dnsmasq config snapshot is available"* ]]
    [ "$(cat "${c}")" = BROKEN ]
    printf 'OK v1\n' > "${c}"
    run _dhcp_proxy_validate_snapshot_or_rollback "${c}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[known-good-snapshot][dhcp-proxy][CREATE]"* ]]
    printf 'BROKEN v2\n' > "${c}"
    run _dhcp_proxy_validate_snapshot_or_rollback "${c}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"generated dnsmasq config failed validation"*"[dhcp-proxy][SELECT]"*"NOT the newly generated config"* ]]
    [ "$(cat "${c}")" = "OK v1" ]
    export KEEP_KNOWN_GOOD_CONFIGS=2
    for i in 1 2 3 4; do printf 'OK r%s\n' "${i}" > "${c}"; _dhcp_proxy_validate_snapshot_or_rollback "${c}" > /dev/null 2>&1; done
    [ "$(kgs_list_snapshots "${DHCP_PROXY_CONFIG_SNAPSHOT_DIR}" | wc -l)" -eq 2 ]
    : > "${BATS_TEST_TMPDIR}/file"
    export DHCP_PROXY_CONFIG_SNAPSHOT_DIR="${BATS_TEST_TMPDIR}/file/snap"
    run _dhcp_proxy_validate_snapshot_or_rollback "${c}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[dhcp-proxy][FATAL]"*"rollback protection is degraded"* ]]
}

@test "dhcp-proxy optional directives render exactly per input" {
    # What: per env set: the full rendered lines + warnings.
    # Why: a bad entry must warn, never reach dnsmasq.conf.
    # From: Issue #1683 | PR #1858
    local root c="${BATS_TEST_TMPDIR}/dnsmasq.conf" case i r n d bf bs co want warn w
    local -a ws
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dhcp-proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp-proxy/entrypoint.sh" _dhcp_proxy_reject_embedded_newline \
        _dhcp_proxy_render_optional_directives _dhcp_proxy_render_custom_options)"
    # What: "." is an empty field, \n a raw newline.
    # Why: keeps every table row at ten visible fields.
    # From: Issue #1683 | PR #1858
    _v() { if [ "$1" = . ]; then printf ''; else printf '%b' "$1"; fi; }
    while IFS='|' read -r case i r n d bf bs co want warn; do
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
basic|eth0|10.0.0.1|ntp1|lan|.|.|.|interface=eth0#dhcp-option-pxe=3,10.0.0.1#dhcp-option-pxe=42,ntp1#dhcp-option-pxe=15,lan|-
boot|.|.|.|.|pxe.efi|10.0.0.5|.|dhcp-boot=pxe.efi,,10.0.0.5|-
bootempty|.|.|.|.|pxe.efi|.|.|dhcp-boot=pxe.efi,,|-
bootsrvonly|.|.|.|.|.|10.0.0.5|.|.|without DHCP_PROXY_BOOT_FILENAME
custom|.|.|.|.|.|.|66:tftp.lan;67:boot.efi|dhcp-option-pxe=66,tftp.lan#dhcp-option-pxe=67,boot.efi|-
badcode|.|.|.|.|.|.|0:x;255:x;ab:x;66:ok|dhcp-option-pxe=66,ok|'0:x': option code 0 is outside^'255:x': option code 255 is outside^'ab:x': option code must be numeric
nocolon|.|.|.|.|.|.|66tftp;67:b; :x|dhcp-option-pxe=67,b|'66tftp' (expected CODE:VALUE)^':x' (expected CODE:VALUE, both non-empty)
code6|.|.|.|.|.|.|6:1.1.1.1|.|option code 6 (DNS servers) always collides
collide|.|10.0.0.1|.|.|.|.|3:10.0.0.9;15:example.com;42:10.0.0.20|dhcp-option-pxe=3,10.0.0.1#dhcp-option-pxe=15,example.com#dhcp-option-pxe=42,10.0.0.20|option code 3 (router) collides with DHCP_PROXY_ROUTER
collideall|.|r|n|d|.|.|3:a;15:b;42:c|dhcp-option-pxe=3,r#dhcp-option-pxe=42,n#dhcp-option-pxe=15,d|code 3 (router) collides^code 15 (domain name) collides^code 42 (NTP servers) collides
nliface|eth\n0|.|.|.|.|.|.|.|DHCP_PROXY_INTERFACE contains an embedded newline
nlfield|.|a\nb|ntp1|c\nd|.|.|.|dhcp-option-pxe=42,ntp1|DHCP_PROXY_ROUTER contains^DHCP_PROXY_DOMAIN contains
nlboot|.|.|.|.|a\nb|10.0.0.5|.|.|DHCP_PROXY_BOOT_FILENAME/DHCP_PROXY_BOOT_SERVER contains
nlcustom|.|.|.|.|.|.|60:PXEClient\ndhcp-option-pxe=99,evil|dhcp-option-pxe=60,PXEClient|-
space|.|.|.|.|.|.|  60:PXE Client  ;93:0|dhcp-option-pxe=60,PXE Client#dhcp-option-pxe=93,0|-
CASES
}

@test "dhcp-proxy pxe directives render exactly per input" {
    # What: per BIOS/UEFI/server set: full lines + warnings.
    # Why: PXE clients need one matching boot pointer.
    # From: Issue #1683 | PR #1858
    local root c="${BATS_TEST_TMPDIR}/dnsmasq.conf" case s b u want warn
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dhcp-proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp-proxy/entrypoint.sh" _dhcp_proxy_reject_embedded_newline \
        _dhcp_proxy_render_pxe_service_directives)"
    while IFS='|' read -r case s b u want warn; do
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
serveronly|10.0.0.5|.|.|.|a boot server alone cannot produce a pxe-service directive
fileonly|.|bios.0|.|.|a boot filename alone cannot produce a pxe-service directive
bios|10.0.0.5|b.0|.|pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",b.0,10.0.0.5#dhcp-match=set:lancache-pxe-bios,option:client-arch,0#dhcp-boot=tag:lancache-pxe-bios,b.0,,10.0.0.5|-
uefi|10.0.0.5|.|u.efi|dhcp-match=set:lancache-pxe-uefi,option:client-arch,7#dhcp-match=set:lancache-pxe-uefi,option:client-arch,11#dhcp-boot=tag:lancache-pxe-uefi,u.efi,,10.0.0.5#pxe-service=IA64_EFI,"lancache-ng PXE proxy active",0|-
both|10.0.0.5|b.0|u.efi|pxe-service=x86PC,"lancache-ng PXE boot (BIOS)",b.0,10.0.0.5#dhcp-match=set:lancache-pxe-bios,option:client-arch,0#dhcp-boot=tag:lancache-pxe-bios,b.0,,10.0.0.5#dhcp-match=set:lancache-pxe-uefi,option:client-arch,7#dhcp-match=set:lancache-pxe-uefi,option:client-arch,11#dhcp-boot=tag:lancache-pxe-uefi,u.efi,,10.0.0.5|-
newline|10.0.0.5\ndhcp-boot=injected,,evil|bios.0|.|.|embedded newline
CASES
}

@test "ui settings sourcing: known keys only, literal values" {
    # What: dhcp-proxy and ntp readers: keys and quotes.
    # Why: a value from the ui file must never be executed.
    # From: Issue #1683 | PR #1858
    local root f="${BATS_TEST_TMPDIR}/ui-settings.env" fn own other
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/dhcp-proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/dhcp-proxy/entrypoint.sh" _dhcp_proxy_source_ui_settings)"
    # shellcheck source=services/ntp/entrypoint.sh
    source "$(_extract_functions "${root}/services/ntp/entrypoint.sh" _ntp_source_ui_settings)"
    for fn in _dhcp_proxy_source_ui_settings:DHCP_MODE:NTP_UPSTREAM_SERVERS _ntp_source_ui_settings:NTP_UPSTREAM_SERVERS:DHCP_MODE; do
        IFS=: read -r fn own other <<< "${fn}"
        unset "${own}" "${other}"
        rm -f "${f}"
        run "${fn}" "${f}"
        [ "${status}" -eq 0 ]
        : > "${f}"
        run "${fn}" "${f}"
        [ "${status}" -eq 0 ]
        printf -v "${own}" '%s' from-env
        printf '# c\n\nnoequals\n%s="dq"\n%s=foreign\n' "${own}" "${other}" > "${f}"
        "${fn}" "${f}"
        [ "${!own}" = dq ] || { echo "${fn}: ${own}=${!own}"; return 1; }
        [ -z "${!other:-}" ] || { echo "${fn}: foreign ${other} set"; return 1; }
        printf "%s='sq'\n" "${own}" > "${f}"
        "${fn}" "${f}"
        [ "${!own}" = sq ]
        printf '%s=93:$(touch %s/canary)\n' "${own}" "${BATS_TEST_TMPDIR}" > "${f}"
        "${fn}" "${f}"
        [ "${!own}" = "93:\$(touch ${BATS_TEST_TMPDIR}/canary)" ]
        [ ! -e "${BATS_TEST_TMPDIR}/canary" ] || { echo "${fn}: value executed"; return 1; }
    done
}

@test "ntp config renders and validates exactly per input" {
    # What: server/pool/allow lines per input; validator.
    # Why: chrony denies all clients without an allow line.
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}/chrony.conf.template" c="${BATS_TEST_TMPDIR}/chrony.conf"
    local case up allow want vrc vmsg e
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/ntp/entrypoint.sh
    source "$(_extract_functions "${root}/services/ntp/entrypoint.sh" is_ip_literal render_ntp_config validate_ntp_config)"
    for e in 192.0.2.1 2606:4700:f1::1 ::1; do
        is_ip_literal "${e}" || { echo "${e} not literal"; return 1; }
    done
    for e in 0.debian.pool.ntp.org time.cloudflare.com 1.2.3; do
        if is_ip_literal "${e}"; then echo "${e} literal"; return 1; fi
    done
    printf 'driftfile /var/lib/chrony/chrony.drift\n' > "${t}"
    while IFS='|' read -r case NTP_UPSTREAM_SERVERS NTP_ALLOWED_CLIENT_CIDRS up allow vrc vmsg; do
        [ "${NTP_UPSTREAM_SERVERS}" != . ] || NTP_UPSTREAM_SERVERS=""
        [ "${NTP_ALLOWED_CLIENT_CIDRS}" != . ] || NTP_ALLOWED_CLIENT_CIDRS=""
        export NTP_UPSTREAM_SERVERS NTP_ALLOWED_CLIENT_CIDRS
        echo stale > "${c}"
        render_ntp_config "${c}" "${t}"
        want="driftfile /var/lib/chrony/chrony.drift##"
        want+="# Upstream servers (NTP_UPSTREAM_SERVERS) -- rendered at container start."
        [ "${up}" = . ] || want+="#${up}"
        want+="### LAN client access (NTP_ALLOWED_CLIENT_CIDRS) -- rendered at container start.#${allow}"
        [ "$(paste -sd'#' "${c}")" = "${want}" ] || { echo "${case}:"; cat "${c}"; return 1; }
        run validate_ntp_config "${c}"
        [ "${status}" -eq "${vrc}" ] || { echo "${case}: validate rc ${status}"; return 1; }
        [[ "${output}" == *"${vmsg}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
pool|0.debian.pool.ntp.org|.|pool 0.debian.pool.ntp.org iburst|allow 0.0.0.0/0#allow ::/0|0|
literal|192.0.2.1 2606:4700:f1::1|.|server 192.0.2.1 iburst#server 2606:4700:f1::1 iburst|allow 0.0.0.0/0#allow ::/0|0|
cidrs|192.0.2.1|192.168.0.0/16 10.0.0.0/8|server 192.0.2.1 iburst|allow 192.168.0.0/16#allow 10.0.0.0/8|0|
noserver|.|10.0.0.0/8|.|allow 10.0.0.0/8|1|no pool/server directive
CASES
    printf 'server 192.0.2.1 iburst\n' > "${c}"
    run validate_ntp_config "${c}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no allow directive"* ]]
}

@test "ntp runtime helpers: pidfile, ownership, clock probe" {
    # What: pidfile, chown, adjtimex probe, start flags.
    # Why: a restart must start chronyd, degraded if needed.
    # From: Issue #1683 | PR #1858
    local root bin="${BIN}" d
    local self case tick write msg
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/ntp/entrypoint.sh
    source "$(_extract_functions "${root}/services/ntp/entrypoint.sh" _cleanup_stale_ntp_pidfile_core \
        cleanup_stale_ntp_pidfile _fix_chrony_dir_ownership_core fix_chrony_dir_ownership clock_control_available)"
    d="${BATS_TEST_TMPDIR}/run"
    mkdir -p "${d}"
    echo 1 > "${d}/chronyd.pid"
    _cleanup_stale_ntp_pidfile_core "${d}/chronyd.pid"
    [ ! -e "${d}/chronyd.pid" ]
    run _cleanup_stale_ntp_pidfile_core "${d}/missing/chronyd.pid"
    [ "${status}" -eq 0 ]
    run type cleanup_stale_ntp_pidfile
    [[ "${output}" == *"_cleanup_stale_ntp_pidfile_core /run/chrony/chronyd.pid"* ]]
    run type fix_chrony_dir_ownership
    [[ "${output}" == *"_fix_chrony_dir_ownership_core chrony:chrony /var/log/chrony /var/lib/chrony"* ]]
    self="$(id -u):$(id -g)"
    mkdir -p "${d}/log" "${d}/lib"
    for case in 1 2; do
        run _fix_chrony_dir_ownership_core "${self}" "${d}/log" "${d}/lib"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ] || { echo "chown pass ${case}: ${output}"; return 1; }
    done
    [ "$(stat -c '%u:%g' "${d}/log" "${d}/lib" | sort -u)" = "${self}" ]
    _tool_stub "${bin}" chown <<'STUB'
echo "chown: changing ownership: Operation not permitted" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _fix_chrony_dir_ownership_core root:root "${d}/log" "${d}/lib"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARNING: could not chown ${d}/log"* ]]
    rm -f "${bin}/chown"
    while IFS='|' read -r case tick write msg; do
        _tool_stub "${bin}" adjtimex <<STUB
case " \$* " in
    *" -t "*) [ "\$*" = "-q -t 10000" ] || exit 9; exit ${write} ;;
    *) printf '%b' '${tick}' ;;
esac
STUB
        PATH="${bin}:/usr/bin:/bin" run clock_control_available
        if [ "${case}" = ok ]; then
            [ "${status}" -eq 0 ] || { echo "${case}: rc ${status} ${output}"; return 1; }
        else
            [ "${status}" -ne 0 ] || { echo "${case}: probe passed"; return 1; }
        fi
        [[ "${output}" == *"${msg}"* ]] || { echo "${case}: ${output}"; return 1; }
    done <<'CASES'
ok|    -t  tick:         10000 us\n|0|
denied|    -t  tick:         10000 us\n|1|
noparse|garbage\n|0|ERROR: 'adjtimex' ran but its read-mode output did not contain a parseable tick value
CASES
    rm -f "${bin}/adjtimex"
    mkdir -p "${d}/nobin"
    run env PATH="${d}/nobin" "${BASH}" -c "$(declare -f clock_control_available); clock_control_available"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"is missing from this image"*"NOT the expected nested/LXC restriction"* ]]
    grep -qx 'user chrony' "${root}/services/ntp/chrony.conf"
    run awk '/^mkdir -p \/run\/chrony$/ { m = NR } /^NTP_CHRONYD_FLAGS=\(-F 2\)$/ { f = NR }
        /^if clock_control_available; then$/ { i = NR } /^else$/ && i && !el { el = NR }
        /^    NTP_CHRONYD_FLAGS\+=\(-x\)$/ { x = NR } /^fi$/ && el && !fi { fi = NR }
        /^exec chronyd -n -f "\$NTP_RUNTIME_CONF" "\$\{NTP_CHRONYD_FLAGS\[@\]\}"$/ { ex = NR }
        END { print (m && m < f && f < i && el < x && x < fi && fi < ex) ? "order-ok" : "m=" m " f=" f " i=" i " x=" x " ex=" ex }' \
        "${root}/services/ntp/entrypoint.sh"
    [ "${output}" = order-ok ]
}

@test "dhcp kea ipv4 and ntp helpers per input" {
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
    local root d="${BATS_TEST_TMPDIR}/kea" ep zones port want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ep="${root}/services/dhcp/entrypoint.sh"
    # shellcheck source=services/dhcp/entrypoint.sh
    source "$(_extract_functions "${ep}" is_ipv4 is_ipv4_csv resolve_ntp_server resolve_ntp_csv build_ntp_option \
        render_kea_config render_kea_dhcp4_config)"
    eval "$(grep -m1 '^ENVSUBST_VARS=' "${ep}")"
    [ -n "${ENVSUBST_VARS}" ]
    export DHCP_SUBNET=10.0.0.0/24 DHCP_RANGE_START=10.0.0.128 DHCP_RANGE_END=10.0.0.254 \
        DHCP_GATEWAY=10.0.0.1 DHCP_DOMAIN=example.com DHCP_LEASE_TIME=86400 DHCP_MAX_LEASE_TIME=172800 \
        DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1" DHCP_DNS_PRIMARY=10.0.0.2 DHCP_DNS_SECONDARY=10.0.0.3 \
        DHCP_DNS_SERVER_IP=127.0.0.1 DHCP_DDNS_PORT=5300 KEA_CTRL_TOKEN=tok-123 KEA_CTRL_HOST=0.0.0.0 \
        DDNS_TSIG_KEY=c2VjcmV0 KEA_LEASE_CMDS_HOOK_PATH=/usr/lib/kea/hooks/libdhcp_lease_cmds.so
    mkdir -p "${d}"
    for DHCP_DDNS_ENABLED in true false; do
        export DHCP_DDNS_ENABLED
        render_kea_dhcp4_config "${root}/services/dhcp/kea-dhcp4.conf" "${d}/dhcp4.json"
        run jq -e --argjson on "${DHCP_DDNS_ENABLED}" '.Dhcp4 as $d | $d.subnet4[0] as $s
            | $s.subnet == "10.0.0.0/24" and $s.pools[0].pool == "10.0.0.128 - 10.0.0.254"
            and $s["valid-lifetime"] == 86400 and $s["max-valid-lifetime"] == 172800
            and ([$s["option-data"][] | select(.name == "ntp-servers") | .data] == ["8.8.8.8,1.1.1.1"])
            and $d["hooks-libraries"] == [{"library": "/usr/lib/kea/hooks/libdhcp_lease_cmds.so"}]
            and $d["dhcp-ddns"]["enable-updates"] == $on and $d["ddns-qualifying-suffix"] == "example.com"' \
            "${d}/dhcp4.json"
        [ "${status}" -eq 0 ] || { echo "dhcp4 ddns=${DHCP_DDNS_ENABLED}: ${output}"; return 1; }
    done
    DHCP_NTP_SERVERS="" render_kea_dhcp4_config "${root}/services/dhcp/kea-dhcp4.conf" "${d}/dhcp4.json"
    jq -e '[.Dhcp4.subnet4[0]["option-data"][] | select(.name == "ntp-servers")] == []' "${d}/dhcp4.json"
    render_kea_config "${root}/services/dhcp/kea-ctrl-agent.conf" "${d}/ctrl.json"
    jq -e '.["Control-agent"] | .["http-host"] == "0.0.0.0" and .authentication.type == "basic"
        and .authentication.clients == [{"user": "admin", "password": "tok-123"}]' "${d}/ctrl.json"
    render_kea_config "${root}/services/dhcp/kea-dhcp-ddns.conf" "${d}/d2.json"
    run grep -n '\${' "${d}/dhcp4.json" "${d}/ctrl.json" "${d}/d2.json"
    [ "${status}" -eq 1 ] || { echo "unrendered: ${output}"; return 1; }
    zones="$(awk '/^PRIVATE_REVERSE_ZONES=\(/,/^\)/' "${root}/services/dns/entrypoint.sh" \
        | grep -oE '[0-9a-z.]+\.in-addr\.arpa\.' | jq -Rsc 'split("\n") | map(select(. != "")) | sort')"
    [ "$(jq length <<< "${zones}")" -gt 0 ]
    run jq -e --argjson zones "${zones}" '.DhcpDdns as $d
        | [$d["tsig-keys"][] | [.name, .algorithm, .secret]] == [["lancache-ddns-key", "HMAC-SHA256", "c2VjcmV0"]]
        and $d.port == 53001 and $d["forward-ddns"]["ddns-domains"][0].name == "example.com."
        and ([$d["reverse-ddns"]["ddns-domains"][].name] | sort) == $zones
        and ([$d["forward-ddns", "reverse-ddns"]["ddns-domains"][] | .["key-name"]] | unique) == ["lancache-ddns-key"]
        and ([$d["forward-ddns", "reverse-ddns"]["ddns-domains"][]["dns-servers"]
            | length == 1 and .[0] == {"ip-address": "127.0.0.1", "port": 5300}] | all)' "${d}/d2.json"
    [ "${status}" -eq 0 ] || { echo "d2: ${output}"; return 1; }
    sed -n '/^: "\${DHCP_DDNS_PORT:=5300}"$/,/^fi$/p' "${ep}" > "${d}/port.sh"
    [ "$(grep -c 'exit 1' "${d}/port.sh")" -eq 2 ]
    while IFS='|' read -r port want; do
        run env DHCP_DDNS_PORT="${port}" bash -c ". '${d}/port.sh' && echo \"ok \${DHCP_DDNS_PORT}\""
        [[ "${output}" == *"${want}"* ]] || { echo "port '${port}': ${output}"; return 1; }
    done <<'CASES'
|ok 5300
1|ok 1
65535|ok 65535
0|must be between 1 and 65535 (got: 0)
65536|must be between 1 and 65535 (got: 65536)
53a|must be a numeric TCP/UDP port (got: 53a)
-1|must be a numeric TCP/UDP port (got: -1)
CASES
}

@test "dhcp kea runtime config migration converges" {
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

@test "watchdog healthcheck judges status file age per interval" {
    # What: max age is 3x interval, at least 60s, decimal.
    # Why: a stalled main loop must turn the container red.
    # From: Issue #1683 | PR #1858
    local hc s="${BATS_TEST_TMPDIR}/status.json" case iv age want now
    hc="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/services/watchdog/healthcheck.sh"
    while IFS='|' read -r case iv age want; do
        now="$(date +%s)"
        printf '{}' > "${s}"
        touch -d "@$((now - age))" "${s}"
        if [ "${iv}" = unset ]; then
            run env -u CHECK_INTERVAL STATUS_FILE="${s}" bash "${hc}"
        else
            run env CHECK_INTERVAL="${iv}" STATUS_FILE="${s}" bash "${hc}"
        fi
        [ "${status}" -eq "${want}" ] || { echo "${case}: rc ${status} ${output}"; return 1; }
    done <<'CASES'
default-fresh|unset|0|0
default-edge|unset|85|0
default-stale|unset|95|1
stale-hour|30|3600|1
octal-8-9|00563179|0|0
decimal-050|050|130|0
decimal-050-stale|050|160|1
floor-60|5|55|0
floor-60-stale|5|65|1
letters|abc|80|0
letters-stale|abc|100|1
future|30|-600|0
CASES
    run env STATUS_FILE="${BATS_TEST_TMPDIR}/missing.json" bash "${hc}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"missing.json does not exist yet"* ]]
}

@test "ui templates gate the log label and re-arm the outage banner" {
    # What: label in syslog mode only; banner per outage.
    # Why: no JS runtime or full dashboard context in tests.
    # From: Issue #849 | PR #1858
    local t
    t="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/services/ui/src/templates"
    run awk '/Recent requests \(proxy\)<\/h2>/ { b = 1 } !b { next }
        /\{% if syslog_enabled %\}/ { inif = 1 } /\{% endif %\}/ { inif = 0 }
        /direct nginx log/ && /href="\/logs"/ { seen = inif ? "inside" : "outside" }
        /\{% if recent_logs %\}/ { exit } END { print seen ? seen : "missing" }' "${t}/dashboard.html"
    [ "${output}" = inside ] || { echo "dashboard label: ${output}"; return 1; }
    run awk '/^let errorShown = false;$/ { e = e " decl" }
        /^async function refresh\(\) \{$/ { f = 1 } !f { next }
        /^    errorShown = false;$/ { e = e " reset" } /^  \} catch \(e\) \{$/ { e = e " catch" }
        /^    if \(!errorShown\) \{$/ { e = e " guard" } /^      errorShown = true;$/ { e = e " set" }
        /^}$/ { exit } END { print e }' "${t}/stats.html"
    [ "${output}" = " decl reset catch guard set" ] || { echo "stats refresh: ${output}"; return 1; }
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
    local root t="${BATS_TEST_TMPDIR}" log="${BATS_TEST_TMPDIR}/csr.log" s1 s2 p case at now san want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _sign_cert _default_cert_needs_regen \
        _bounded_cert_name)"
    export CA_DIR="${t}/ca" CERT_DIR="${t}/certs" SERIAL_FILE="${t}/ca/ca.srl"
    mkdir -p "${CA_DIR}" "${CERT_DIR}"
    openssl req -new -newkey rsa:2048 -nodes -x509 -days 30 -subj "/CN=Test CA" \
        -keyout "${CA_DIR}/ca.key" -out "${CA_DIR}/ca.crt" 2>/dev/null
    printf '%016x\n' "$(date +%s%N)" > "${SERIAL_FILE}"
    mktemp() { local m; m="$(command mktemp "$@")" || return; echo "${m}" >> "${log}"; printf '%s\n' "${m}"; }
    _sign_cert cdn.example.com "${CERT_DIR}/a.key" "${CERT_DIR}/a.crt" \
        "subjectAltName=DNS:cdn.example.com,DNS:*.cdn.example.com" 2>/dev/null
    openssl verify -CAfile "${CA_DIR}/ca.crt" "${CERT_DIR}/a.crt"
    [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "${CERT_DIR}/a.crt")" = "subject=CN=lancache-ng" ]
    [ "$(openssl x509 -noout -ext subjectAltName -in "${CERT_DIR}/a.crt" | tail -n +2 | tr -d ' ')" \
        = "DNS:cdn.example.com,DNS:*.cdn.example.com" ]
    [ $(( ($(date -d "$(openssl x509 -noout -enddate -in "${CERT_DIR}/a.crt" | cut -d= -f2)" +%s) \
        - $(date -d "$(openssl x509 -noout -startdate -in "${CERT_DIR}/a.crt" | cut -d= -f2)" +%s)) / 86400 )) -eq 3650 ]
    s1="$(openssl x509 -noout -serial -in "${CERT_DIR}/a.crt" | cut -d= -f2)"
    _sign_cert "$(printf 'a%.0s' {1..300})" "${CERT_DIR}/b.key" "${CERT_DIR}/b.crt" 2>/dev/null
    [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "${CERT_DIR}/b.crt")" = "subject=CN=lancache-ng" ]
    [ -z "$(openssl x509 -noout -ext subjectAltName -in "${CERT_DIR}/b.crt" 2>/dev/null)" ]
    s2="$(openssl x509 -noout -serial -in "${CERT_DIR}/b.crt" | cut -d= -f2)"
    [ $((16#${s2})) -gt $((16#${s1})) ] || { echo "serial ${s2} not above ${s1}"; return 1; }
    grep -qxE '[0-9A-Fa-f]+' "${SERIAL_FILE}"
    local long w x
    long="$(printf 'a%.0s' {1..60})"
    long="${long}.${long}.${long}.${long}"
    _sign_cert "${long}" "${CERT_DIR}/l.key" "${CERT_DIR}/l.crt" "subjectAltName=DNS:*.${long}" 2>/dev/null
    [ "$(openssl x509 -noout -ext subjectAltName -in "${CERT_DIR}/l.crt" | tail -n +2 | tr -d ' ')" = "DNS:*.${long}" ]
    w="$(_bounded_cert_name "${long}" wildcard)"
    x="$(_bounded_cert_name "${long}" exact)"
    [[ "${w}" =~ ^[0-9a-f]{32}$ && "${x}" =~ ^[0-9a-f]{32}$ && "${w}" != "${x}" ]] || { echo "names ${w} ${x}"; return 1; }
    [ "$(_bounded_cert_name "${long}" wildcard)" = "${w}" ]
    [[ "$(_bounded_cert_name a.example.com exact)" =~ ^[0-9a-f]{32}$ ]]
    mkdir "${CERT_DIR}/kd" "${CERT_DIR}/y.crt"
    run _sign_cert x.example.com "${CERT_DIR}/kd" "${CERT_DIR}/x.crt" "subjectAltName=DNS:x.example.com"
    [ "${status}" -ne 0 ]
    [ ! -e "${CERT_DIR}/x.crt" ]
    run _sign_cert y.example.com "${CERT_DIR}/y.key" "${CERT_DIR}/y.crt" "subjectAltName=DNS:y.example.com"
    [ "${status}" -ne 0 ]
    [ ! -e "${CERT_DIR}/y.key" ] || { echo "orphaned key after a sign failure"; return 1; }
    echo partial > "${CERT_DIR}/z.crt"
    CA_DIR="${t}/missing" run _sign_cert z.example.com "${CERT_DIR}/z.key" "${CERT_DIR}/z.crt"
    [ "${status}" -ne 0 ]
    [ ! -e "${CERT_DIR}/z.crt" ] && [ ! -e "${CERT_DIR}/z.key" ] || { echo "partial output kept"; return 1; }
    [ "$(wc -l < "${log}")" -eq 6 ] || { echo "csr files: $(cat "${log}")"; return 1; }
    while IFS= read -r p; do
        [ ! -e "${p}" ] || { echo "csr left: ${p}"; return 1; }
    done < "${log}"
    while IFS='|' read -r case at now san want; do
        rm -f "${CERT_DIR}/default.crt" "${CERT_DIR}/default.key"
        if [ "${san}" != none ]; then
            IP_SSL="${at}" _sign_cert lancache-default "${CERT_DIR}/default.key" "${CERT_DIR}/default.crt" \
                "${san:+subjectAltName=${san}}" 2>/dev/null
        fi
        [ "${case}" != nokey ] || rm -f "${CERT_DIR}/default.key"
        IP_SSL="${now}" run _default_cert_needs_regen
        [ "${status}" -eq "${want}" ] || { echo "${case}: rc ${status}"; return 1; }
    done <<'CASES'
missing|||none|0
nokey|||DNS:lancache-default|0
nosan||||0
exact|192.168.1.1|192.168.1.1|DNS:lancache-default,IP:192.168.1.1|1
prefix|192.168.1.11|192.168.1.1|DNS:lancache-default,IP:192.168.1.11|0
unrelated|10.0.0.5|192.168.1.1|DNS:lancache-default,IP:10.0.0.5|0
dnsonly|||DNS:lancache-default|1
ipnowempty|10.0.0.5||DNS:lancache-default,IP:10.0.0.5|1
CASES
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

@test "proxy ssl map renders exactly per mode and input" {
    # What: cert map, host allowlist, client geo per input.
    # Why: strict mode and client CIDRs deny by default.
    # From: Issue #1683 | PR #1858
    local root want wb xh
    local -a _UNIQUE_DOMAINS=() _EXTRA_WILDCARD_BASES=() _EXTRA_EXACT_HOSTS=()
    local -A _DOMAIN_IS_ROOT=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _bounded_cert_name _render_ssl_map)"
    _r() { set -euo pipefail; _render_ssl_map | tr -s ' ' | paste -sd'#'; }
    PROXY_SECURITY_MODE=lazy PROXY_ALLOWED_CLIENT_CIDRS="" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = '# Auto-generated by entrypoint — do not edit#map $ssl_server_name $ssl_cert_name {# hostnames;# default default;#}##map $host $cdn_host_allowed {# hostnames;# default 1;#}##geo $lancache_client_allowed {# default 1;#}' ] || {
        echo "lazy empty: ${output}"; return 1; }
    _UNIQUE_DOMAINS=(steamcontent.com cdn.example.com)
    _DOMAIN_IS_ROOT=(["steamcontent.com"]=1 ["cdn.example.com"]=0)
    _EXTRA_WILDCARD_BASES=(a.b.example.org)
    _EXTRA_EXACT_HOSTS=(x.y.example.net)
    wb="$(_bounded_cert_name a.b.example.org wildcard)"
    xh="$(_bounded_cert_name x.y.example.net exact)"
    want="# Auto-generated by entrypoint — do not edit#map \$ssl_server_name \$ssl_cert_name {# hostnames;"
    want+="# *.steamcontent.com steamcontent.com;# steamcontent.com steamcontent.com;"
    want+="# *.cdn.example.com cdn.example.com;# *.a.b.example.org ${wb};# x.y.example.net ${xh};"
    want+="# default default;#}##map \$host \$cdn_host_allowed {# hostnames;"
    PROXY_SECURITY_MODE=lazy PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = "${want}# default 1;#}##geo \$lancache_client_allowed {# default 0;# 192.168.1.0/24 1;# 10.0.0.0/8 1;#}" ] || {
        echo "lazy cidrs: ${output}"; return 1; }
    PROXY_SECURITY_MODE=strict PROXY_ALLOWED_CLIENT_CIDRS="" run _r
    [ "${status}" -eq 0 ]
    [ "${output}" = "${want}# default 0;# *.steamcontent.com 1;# steamcontent.com 1;# *.cdn.example.com 1;# *.a.b.example.org 1;# x.y.example.net 1;#}##geo \$lancache_client_allowed {# default 1;#}" ] || {
        echo "strict: ${output}"; return 1; }
}

@test "proxy stream map and client acl render exactly per input" {
    # What: SNI backend map per mode; stream client ACL.
    # Why: empty SNI and unlisted hosts never reach :443.
    # From: Issue #1683 | PR #1858
    local root fb head
    local -a _UNIQUE_DOMAINS=() _EXTRA_WILDCARD_BASES=() _EXTRA_EXACT_HOSTS=()
    local -A _DOMAIN_IS_ROOT=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=services/proxy/entrypoint.sh
    source "$(_extract_functions "${root}/services/proxy/entrypoint.sh" _render_stream_backend_map _render_stream_client_acl)"
    eval "$(grep -m1 '^STREAM_EMPTY_SNI_BACKEND=' "${root}/services/proxy/entrypoint.sh")"
    fb="${STREAM_EMPTY_SNI_BACKEND}"
    [[ "${fb}" =~ ^127\.0\.0\.1:[0-9]+$ ]]
    _r() { set -euo pipefail; "$@" | tr -s ' ' | paste -sd'#'; }
    head="# Auto-generated by entrypoint — do not edit#map \$ssl_preread_server_name \$stream_backend {# hostnames;# \"\" ${fb};"
    _UNIQUE_DOMAINS=(steamcontent.com cdn.example.com)
    _DOMAIN_IS_ROOT=(["steamcontent.com"]=1 ["cdn.example.com"]=0)
    _EXTRA_WILDCARD_BASES=(a.b.example.org)
    _EXTRA_EXACT_HOSTS=(x.y.example.net)
    PROXY_SECURITY_MODE=lazy run _r _render_stream_backend_map
    [ "${output}" = "${head}# default \$ssl_preread_server_name:443;#}" ] || { echo "lazy: ${output}"; return 1; }
    PROXY_SECURITY_MODE=strict run _r _render_stream_backend_map
    [ "${output}" = "${head}# default ${fb};# *.steamcontent.com \$ssl_preread_server_name:443;# steamcontent.com \$ssl_preread_server_name:443;# *.cdn.example.com \$ssl_preread_server_name:443;# *.a.b.example.org \$ssl_preread_server_name:443;# x.y.example.net x.y.example.net:443;#}" ] || {
        echo "strict: ${output}"; return 1; }
    PROXY_ALLOWED_CLIENT_CIDRS="" run _r _render_stream_client_acl
    [ "${output}" = "# Auto-generated by entrypoint — do not edit" ] || { echo "acl empty: ${output}"; return 1; }
    PROXY_ALLOWED_CLIENT_CIDRS="192.168.1.0/24 10.0.0.0/8" run _r _render_stream_client_acl
    [ "${output}" = "# Auto-generated by entrypoint — do not edit#allow 192.168.1.0/24;#allow 10.0.0.0/8;#deny all;" ] || {
        echo "acl cidrs: ${output}"; return 1; }
}

@test "setup restore: literal path rewrite and stale .env.local" {
    # What: any printable char in a path rewrites exactly
    # Why: a path is text; regex or sed syntax must not leak
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" line moved
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export T="${t}"
    _setup_sh_run 'for code in $(seq 32 126); do
            c="$(printf "\\$(printf "%03o" "$code")")"
            old="${T}/o${c}*[l].d" new="${T}/n${c}&\\1#d"
            printf "A=%s/x\nB=%s%s\n" "$old" "$old" "$old" > "${T}/f"
            replace_literal_in_file "${T}/f" "$old" "$new"
            [ "$(cat "${T}/f")" = "$(printf "A=%s/x\nB=%s%s" "$new" "$new" "$new")" ] || echo "BAD $code"
        done'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "rewrite: ${output}"; return 1; }
    _setup_sh_run 'replace_literal_in_file "${T}/f" "" x; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"empty string"* && "${output}" != *unreached* ]] \
        || { echo "empty: ${output}"; return 1; }
    # What: a stale override moves aside once
    # Why: a stale .env.local overrides the restored .env
    # From: Issue #1683 | PR #1858
    line="$(grep -m1 -E '^[A-Z_]+=' "${root}/deploy/prod/.env")"
    mkdir -p "${t}/arch" "${t}/inst"
    _setup_sh_run 'restore_clear_stale_env_local_if_unarchived "${T}/arch" "${T}/inst"'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] && [ -z "$(ls -A "${t}/inst")" ] || { echo "noop: ${output}"; return 1; }
    printf '%s\n' "${line}" > "${t}/inst/.env.local"
    _setup_sh_run 'restore_clear_stale_env_local_if_unarchived "${T}/arch" "${T}/inst"'
    moved="$(cd "${t}/inst" && ls -A)"
    [ "${status}" -eq 0 ] && [[ "${moved}" =~ ^\.env\.local\.pre-restore-[0-9]{8}T[0-9]{6}Z$ ]] \
        && [ "$(cat "${t}/inst/${moved}")" = "${line}" ] && [[ "${output}" == *"${moved}"* ]] || { echo "moved: ${moved} ${output}"; return 1; }
    _setup_sh_run 'restore_clear_stale_env_local_if_unarchived "${T}/arch" "${T}/inst"'
    [ "${status}" -eq 0 ] && [ "$(cd "${t}/inst" && ls -A)" = "${moved}" ] || { echo "second run changed it"; return 1; }
    printf '%s\n' "${line}" | tee "${t}/arch/.env.local" > "${t}/inst/.env.local"
    _setup_sh_run 'restore_clear_stale_env_local_if_unarchived "${T}/arch" "${T}/inst"'
    [ "${status}" -eq 0 ] && [ "$(cat "${t}/inst/.env.local")" = "${line}" ] && [ "$(cd "${t}/inst" && ls -A | wc -l)" -eq 2 ] \
        || { echo "archived override: $(ls -A "${t}/inst")"; return 1; }
}

@test "setup install dir: update env paths and compose args" {
    # What: env file per layout; compose files per state
    # Why: a wrong file list starts the wrong stack
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" body nats ip case line shell got oracle err f want
    local -a overs
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    export DP="${t}/repo/deploy/prod" EF="${t}/repo/deploy/prod/.env" NB
    _prod_install "${DP}"
    body="$(declare -f compose_file_args_for_install_dir)"
    nats="$(grep -oE 'docker-compose\.nats-[a-z-]+\.yml' <<< "${body}" | awk 'NR == 1')"
    mapfile -t overs < <(grep -oE 'docker-compose\.override\.y[a-z]*ml' <<< "${body}" | awk '!seen[$0]++')
    ip="$(get_env_var IP_STANDARD "${EF}")"
    [ -n "${nats}" ] && [ -f "${root}/deploy/prod/${nats}" ] && [ "${#overs[@]}" -ge 2 ] && [ -n "${ip}" ] \
        || { echo "inputs: ${nats} ${overs[*]} ${ip}"; return 1; }
    cp "${root}/deploy/prod/${nats}" "${DP}/"
    cp "${EF}" "${t}/env.base"
    printf 'services:\n  p:\n    image: %s\n    environment:\n      V: "${NATS_BIND_IP:-}"\n' "${LANCACHE_HELPER_IMAGE}" > "${t}/probe.yml"
    # What: NATS override in iff compose reads a value
    # Why: compose's own .env parsing is the only truth
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case line shell; do
        cp "${t}/env.base" "${EF}"
        [ "${line}" = - ] || printf '%s\n' "${line}" >> "${EF}"
        NB="${shell}"
        _setup_sh_run 'if [ "${NB}" = - ]; then unset NATS_BIND_IP; else export NATS_BIND_IP="${NB}"; fi
            compose_file_args_for_install_dir "${DP}" "${EF}"'
        [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
        got=out; grep -qxF -- "${DP}/${nats}" <<< "${output}" && got=in
        err="$(if [ "${shell}" = - ]; then unset NATS_BIND_IP; else export NATS_BIND_IP="${shell}"; fi
            docker compose --env-file "${EF}" -f "${t}/probe.yml" config --format json 2>&1)" \
            || { echo "${case}: probe: ${err}"; return 1; }
        oracle=out; [ -z "$(jq -r '.services.p.environment.V' <<< "${err}")" ] || oracle=in
        [ "${got}" = "${oracle}" ] || { echo "${case}: setup.sh ${got}, compose ${oracle}: ${err}"; return 1; }
    done <<CASES
unset|-|-
empty|NATS_BIND_IP=|-
quoted|NATS_BIND_IP=""|-
hash|NATS_BIND_IP=  # ${BATS_TEST_NUMBER}|-
set|NATS_BIND_IP=${ip}|-
single|NATS_BIND_IP='${ip}'|-
shell|-|${ip}
CASES
    cp "${t}/env.base" "${EF}"
    printf 'NATS_BIND_IP=%s\n' "${ip}" >> "${EF}"
    rm -f "${DP}/${nats}"
    _setup_sh_run 'compose_file_args_for_install_dir "${DP}" "${EF}"'
    [ "${status}" -eq 0 ] && [ "${output}" = "-f"$'\n'"${DP}/docker-compose.yml" ] || { echo "no override file: ${output}"; return 1; }
    # What: explicit -f list equals compose's own auto-load
    # Why: setup.sh must pass -f and still keep overrides
    # From: Issue #1683 | PR #1858
    for case in "${overs[0]}" "${overs[1]}" both; do
        rm -f "${DP}"/docker-compose.override.*
        for f in "${overs[@]}"; do
            [ "${case}" = both ] || [ "${case}" = "${f}" ] || continue
            printf 'services:\n  %s:\n    image: %s\n' "${f//./-}" "${LANCACHE_HELPER_IMAGE}" > "${DP}/${f}"
        done
        _setup_sh_run 'PATH="${BIN}:${PATH}"; stack_compose "${DP}" "${EF}" config --services'
        [ "${status}" -eq 0 ] || { echo "${case}: ${output}"; return 1; }
        got="$(sort <<< "${output}")"
        want="$(cd "${DP}" && docker compose --env-file "${EF}" config --services)"
        [ "${got}" = "$(sort <<< "${want}")" ] || { echo "${case}: setup.sh ${got} | compose ${want}"; return 1; }
    done
    : > "${DP}/.env.local"
    mkdir -p "${t}/legacy" && : > "${t}/legacy/.env.local"
    [ "$(runtime_env_file_for_install_dir "${DP}")" = "${DP}/.env.local" ] \
        && [ "$(runtime_env_file_for_install_dir "${t}/legacy")" = "${t}/legacy/.env" ] || { echo "env file per layout"; return 1; }
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

@test "setup env value parsing and write safety per shape" {
    # What: setup.sh reads every .env shape as compose does
    # Why: setup must act on the value the stack will use
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" n p ip case line want v code c
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    export E="${t}/.env" RAWV="${t}"$'\t'"&\\1"
    n="${BATS_TEST_NUMBER}" p="${t}/a b" ip="$(get_env_var IP_STANDARD "${root}/deploy/prod/.env")"
    printf 'services:\n  p:\n    image: %s\n    environment:\n      V: "${KEY:-}"\n' "${LANCACHE_HELPER_IMAGE}" > "${t}/probe.yml"
    _compose_value() {
        local json
        json="$(docker compose --env-file "${E}" -f "${t}/probe.yml" config --format json)" || return 1
        jq -r '.services.p.environment.V' <<< "${json}"
    }
    while IFS='|' read -r case line; do
        printf '%b\nOTHER=1\n' "${line}" > "${E}"
        want="$(_compose_value)" || { echo "${case}: compose cannot read ${line}"; return 1; }
        _setup_sh_run 'get_env_var KEY "${E}"'
        [ "${status}" -eq 0 ] && [ "${output}" = "${want}" ] || { echo "${case}: setup.sh '${output}', compose '${want}'"; return 1; }
        _setup_sh_run 'get_env_var_nonempty KEY "${E}"'
        [ "${status}" -eq 0 ] && { [ -z "${want}" ] || [ "${output}" = "${want}" ]; } \
            || { echo "${case}: nonempty '${output}', compose '${want}'"; return 1; }
    done <<CASES
plain|KEY=${n}
dquote|KEY="${p}" # ${n}
squote|KEY='${p} # ${n}' # ${n}
comment|KEY=${n} # ${n}
hashnospace|KEY=${n}#${n}
spaces|KEY=  ${n}\x20\x20
empty|KEY=
missing|NOTKEY=${n}
duplicate|KEY=${n}\nKEY=${ip}
laterempty|KEY=${n}\nKEY=
CASES
    _setup_sh_run 'printf "[%s]" "$(get_env_var KEY "${E}.none")"'
    [ "${status}" -eq 0 ] && [ "${output}" = "[]" ] || { echo "missing file: ${output}"; return 1; }
    # What: an accepted value always round-trips via compose
    # Why: validate_env_value guards each written value
    # From: Issue #1683 | PR #1858
    for code in $(seq 32 126) 10; do
        c="$(printf "\\$(printf '%03o' "${code}")")"
        [ "${code}" -ne 10 ] || c=$'\n'
        export V="a${c}b"
        _setup_sh_run 'validate_env_value KEY "${V}"'
        if [ "${status}" -eq 0 ]; then
            printf 'KEY=%s\n' "${V}" > "${E}"
            [ "$(_compose_value)" = "${V}" ] || { echo "accepted char ${code} does not round-trip"; return 1; }
        else
            [[ "${output}" == *"KEY contains unsafe characters for .env"* ]] || { echo "char ${code}: ${output}"; return 1; }
        fi
    done
    for V in "" "${DEFAULT_INSTALL_DIR}" "${ip}" "${p}"; do
        export V
        _setup_sh_run 'validate_env_value KEY "${V}"'
        [ "${status}" -eq 0 ] || { echo "'${V}' refused: ${output}"; return 1; }
    done
    # What: a failed read or write stops, changes nothing
    # Why: a half-read value must never drive a write
    # From: Issue #1683 | PR #1858
    _fail_stub "${t}/fb" awk
    export FAIL_MATCH="${E}" FB="${t}/fb"
    printf 'A=1\nB=2\nC=3\n' > "${E}"
    cp "${E}" "${E}.before"
    for v in 'remove_env_key C "${E}"' 'set_env_key B 9 "${E}"' 'set_env_assignment B 9 "${E}"'; do
        _setup_sh_run 'PATH="${FB}:${PATH}"; '"${v}"'; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to rewrite "?" in ${E}"* && "${output}" != *unreached* ]] \
            && cmp -s "${E}.before" "${E}" || { echo "${v}: rc ${status} ${output}"; return 1; }
    done
    for v in get_env_var get_env_var_nonempty get_env_assignment_value_raw get_env_assignment_value_raw_nonempty; do
        _setup_sh_run 'PATH="${FB}:${PATH}"; r=$('"${v}"' B "${E}"); echo "unreached ${r}"'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to read B from ${E}"* && "${output}" != *unreached* ]] \
            || { echo "${v}: rc ${status} ${output}"; return 1; }
    done
    mkdir -p "${E}.d"
    _setup_sh_run 'env_key_exists C "${E}.d"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to read ${E}.d while looking up C"* && "${output}" != *unreached* ]] \
        || { echo "dir: ${output}"; return 1; }
    printf 'K=%s\nK=%s\n' "${n}" "${ip}" > "${E}"
    _setup_sh_run 'set_env_assignment K "${RAWV}" "${E}" && remove_env_key OTHER "${E}"'
    [ "${status}" -eq 0 ] && [ "$(cat "${E}")" = "K=${RAWV}" ] || { echo "raw write: $(cat "${E}")"; return 1; }
    _setup_sh_run 'remove_env_key K "${E}"'
    [ "${status}" -eq 0 ] && [ ! -s "${E}" ] || { echo "remove: $(cat "${E}")"; return 1; }
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

@test "setup channel pins come from two equal lock-free reads" {
    # What: lock, double read, retries, raw errors, pins
    # Why: a promote between reads must not mix a stack
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" n a b lock max backoff ino mut rel ch reg pre warn err line
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    warn="$(print_warn '' 2>&1)" err="$(print_error '' 2>&1)"
    mut="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels)"
    rel="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_channel_field release_tags | awk '$2 == "true" { print $1 }')"
    ch="$(grep -vxF -- "${rel}" <<< "${mut}" | awk 'NR == 1')"
    reg="$(resolve_lancache_image_registry "${root}/deploy/prod/.env")"
    pre="$(resolve_lancache_image_prefix "${root}/deploy/prod/.env")"
    line="$(grep -m1 -E '^[A-Z_]+=' "${root}/deploy/prod/.env")"
    a="sha256:$(printf '%064d' 0 | tr 0 a)" b="sha256:$(printf '%064d' 0 | tr 0 b)"
    [ -n "${ch}" ] && [ -n "${reg}" ] && [ -n "${pre}" ] || { echo "inputs: ${ch} ${reg} ${pre}"; return 1; }
    VER="v$(tr -d '[:space:]' < "${root}/VERSION")"
    export CH="${ch}" ENVF="${t}/pins.env" VER
    # What: origin lock refs and backoff sleeps as stubs
    # Why: no remote and no real wait inside the test box
    # From: Issue #1683 | PR #1858
    export GIT_REAL
    GIT_REAL="$(type -P git)"
    _tool_stub "${BIN}" git <<'STUB'
case "$*" in
    *" ls-remote origin "*)
        [ ! -e "${DS}/fail-git" ] || { echo "fatal: ${FAULT:?}" >&2; exit 128; }
        [ ! -e "${DS}/remote-refs" ] || grep -F -- "${!#}" "${DS}/remote-refs" || [ "$?" -eq 1 ] ;;
    *) exec "${GIT_REAL:?}" "$@" ;;
esac
STUB
    _tool_stub "${BIN}" sleep <<<'printf "%s\n" "$1" >> "${DS}/sleeps"'
    _reset() {
        printf '%s' "$1" > "${DS}/digest"
        rm -f "${DS}/inspect-calls" "${DS}/digest-flip" "${DS}/remote-refs" "${DS}/fail-git" "${DS}/fail-buildx"
        : > "${DS}/sleeps"
    }
    _pin() { _setup_sh_run 'PATH="${BIN}:${PATH}"; refs=$(lancache_image_refs_for_tag "" "${CH}") || die "outer pin failed (exit $?)"; printf "%s\n" "${refs}"'; }
    _setup_sh_run 'lancache_image_ref_vars'
    [ "${status}" -eq 0 ] || { echo "ref vars: ${output}"; return 1; }
    n="${#lines[@]}"
    [ "$(cut -d' ' -f1 <<< "${output}" | sort -u | wc -l)" -eq "${n}" ] && [ "$(cut -d' ' -f2 <<< "${output}" | sort -u | wc -l)" -eq "${n}" ] \
        && [ "$(grep -cE '^ *image: .*LANCACHE_IMAGE_TAG' "${root}/deploy/prod/docker-compose.yml")" \
            -eq "$(grep -cE '^ *image: \$\{LANCACHE_IMAGE_REF_[A-Z_]+:-' "${root}/deploy/prod/docker-compose.yml")" ] \
        || { echo "ref vars: one var and slug each, a pin per tagged image: ${output}"; return 1; }
    _setup_sh_run 'lancache_sot_value CI_PROMOTE_LOCK_REF; lancache_sot_value CI_PROMOTE_LOCK_MAX; lancache_sot_value CI_PROMOTE_LOCK_BACKOFF'
    [ "${status}" -eq 0 ] && [ "${#lines[@]}" -eq 3 ] || { echo "sot: ${output}"; return 1; }
    lock="${lines[0]}/${ch}" max="${lines[1]}" backoff="${lines[2]}"
    _reset "${a}"
    _pin
    [ "${status}" -eq 0 ] && [ "$(grep -c "^LANCACHE_IMAGE_REF_[A-Z_]*=${reg}/${pre}/[a-z0-9-]*@${a}$" <<< "${output}")" -eq "${n}" ] \
        && [ "$(cat "${DS}/inspect-calls")" -eq $(( 2 * n )) ] && [ ! -s "${DS}/sleeps" ] || { echo "clean: ${output}"; return 1; }
    export CH="${VER}"
    _pin
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "pinned tag: ${output}"; return 1; }
    export CH="${ch}"
    # What: a promote between the reads forces one retry
    # Why: two equal reads are the only accepted stack
    # From: Issue #1683 | PR #1858
    _reset "${a}"
    printf '%s %s' "$(( n + 1 ))" "${b}" > "${DS}/digest-flip"
    _pin
    [ "${status}" -eq 0 ] && [ "$(grep -c "^LANCACHE_IMAGE_REF_.*@${b}$" <<< "${output}")" -eq "${n}" ] \
        && [ "$(grep -cF "${warn}Channel ${ch}: digests changed between two reads: LANCACHE_IMAGE_REF_" <<< "${output}")" -eq 1 ] \
        && [ "$(grep -F "digests changed" <<< "${output}" | grep -o "@${b}" | wc -l)" -eq "${n}" ] \
        && [[ "${output}" == *"; retry in ${backoff}s (1/${max})."* ]] && [ "$(cat "${DS}/sleeps")" = "${backoff}" ] \
        && [ "$(cat "${DS}/inspect-calls")" -eq $(( 4 * n )) ] || { echo "flip: ${output}"; return 1; }
    _reset "${a}"
    printf '%s\t%s\n' "${b#sha256:}" "${lock}" > "${DS}/remote-refs"
    _pin
    [ "${status}" -eq 1 ] && [ "$(grep -cF "${warn}Channel ${ch}: promote lock ${lock} is held; retry in ${backoff}s" <<< "${output}")" -eq "${max}" ] \
        && [ "$(wc -l < "${DS}/sleeps")" -eq "${max}" ] && [ ! -e "${DS}/inspect-calls" ] \
        && [[ "${output}" == *"${err}Channel ${ch}: promote lock ${lock} is held; no consistent stack after ${max} attempts."* ]] \
        && [[ "${output}" == *"${err}outer pin failed (exit 1)"* ]] || { echo "lock held: ${output}"; return 1; }
    _reset "x${BATS_TEST_NUMBER}"
    _pin
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${err}${reg}/${pre}/"*":${ch} returned an invalid digest: x${BATS_TEST_NUMBER}."* ]] \
        && [[ "${output}" == *"${err}First read of channel ${ch} failed (exit 1)."* ]] || { echo "garbage: ${output}"; return 1; }
    export FAULT="${BATS_TEST_NAME}"
    _reset "${a}"; : > "${DS}/fail-git"
    _pin
    [ "${status}" -eq 1 ] && [[ "${output}" == *"fatal: ${FAULT}"* && "${output}" == *"${err}Failed to read the promote lock ${lock} from origin (exit 128)."* ]] \
        || { echo "ls-remote: ${output}"; return 1; }
    _reset "${a}"; : > "${DS}/fail-buildx"
    _pin
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${err}docker buildx is required to resolve LANCACHE_IMAGE_CHANNEL=${ch} (exit 1: docker buildx: ${FAULT})."* ]] \
        || { echo "buildx: ${output}"; return 1; }
    # What: pins replace old ones; equal ones are no write
    # Why: an unchanged .env must keep its inode and bytes
    # From: Issue #1683 | PR #1858
    printf 'LANCACHE_IMAGE_TAG=%s\nLANCACHE_IMAGE_REF_DNS=%s\n%s\n' "${ch}" "${t}" "${line}" > "${ENVF}"
    _reset "${a}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; refs=$(lancache_image_refs_for_tag "" "${CH}") || die "outer pin failed (exit $?)"
        write_lancache_image_refs "${ENVF}" "${refs}"'
    [ "${status}" -eq 0 ] && [ "$(grep -c '^LANCACHE_IMAGE_REF_' "${ENVF}")" -eq "${n}" ] \
        && [ "$(sed -n 2p "${ENVF}")" = "LANCACHE_IMAGE_REF_DNS=${reg}/${pre}/dns@${a}" ] && [ "$(sed -n 3p "${ENVF}")" = "${line}" ] \
        || { echo "write: $(cat "${ENVF}")"; return 1; }
    cp "${ENVF}" "${t}/pins.before"
    ino="$(stat -c %i "${ENVF}")"
    _reset "${a}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; refs=$(lancache_image_refs_for_tag "" "${CH}") || die "outer pin failed (exit $?)"
        write_lancache_image_refs "${ENVF}" "${refs}"'
    [ "${status}" -eq 0 ] && cmp -s "${t}/pins.before" "${ENVF}" && [ "$(stat -c %i "${ENVF}")" = "${ino}" ] \
        || { echo "rewrite of equal pins: ${output}"; return 1; }
    _setup_sh_run 'p=$(grep "^LANCACHE_IMAGE_REF_" "${ENVF}"); lancache_image_refs_fingerprint "${p}"
        lancache_image_refs_fingerprint "$(sort -r <<< "${p}")"; lancache_image_refs_fingerprint "X=1"
        lancache_image_refs_fingerprint "X=2"; lancache_image_refs_fingerprint ""; echo end'
    [ "${status}" -eq 0 ] && [[ "${lines[0]}" =~ ^refs-[0-9a-f]{12}$ ]] && [ "${lines[0]}" = "${lines[1]}" ] \
        && [ "${lines[2]}" != "${lines[3]}" ] && [ "${lines[4]}" = end ] || { echo "fingerprint: ${output}"; return 1; }
    export BADREF="LANCACHE_IMAGE_REF_DNS=${t}#${BATS_TEST_NUMBER}" NOREF="LANCACHE_IMAGE_REF_X${BATS_TEST_NUMBER}=${t}"
    _setup_sh_run 'write_lancache_image_refs "${ENVF}" "${BADREF}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${err}LANCACHE_IMAGE_REF_DNS contains unsafe characters for .env."* ]] \
        && cmp -s "${t}/pins.before" "${ENVF}" || { echo "unsafe: ${output}"; return 1; }
    _setup_sh_run 'write_lancache_image_refs "${ENVF}" "${NOREF}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${err}${NOREF%%=*} is no first-party image pin of ${PROD_COMPOSE}; ${ENVF} was not changed."* ]] \
        && cmp -s "${t}/pins.before" "${ENVF}" || { echo "unknown pin: ${output}"; return 1; }
    _setup_sh_run 'write_lancache_image_refs "${ENVF}" ""'
    [ "${status}" -eq 0 ] && [ "$(cat "${ENVF}")" = "$(printf 'LANCACHE_IMAGE_TAG=%s\n%s' "${ch}" "${line}")" ] \
        || { echo "clear: $(cat "${ENVF}")"; return 1; }
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
    local root t="${BATS_TEST_TMPDIR}" modes off cprof ip net m p v dhcp="" ntp logp custom tpl vars exported out
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

@test "setup functional health gate and tool install per state" {
    # What: healthz, DNS, port and tool probes per state
    # Why: an update passes only on real traffic checks
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" std hp case compose env world path rc want kv pref fall
    local -a kvs
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export DP="${t}/co/deploy/prod" GE="${t}/gate.env" FAULT="${BATS_TEST_NAME}" CASE_PATH
    _prod_install "${DP}"
    cp "${DP}/docker-compose.yml" "${t}/compose.orig"
    std="$(get_env_var IP_STANDARD "${DP}/.env")"
    hp="$(declare -f _verify_healthz_endpoint | grep -oE '_tcp_port_reachable "\$ip" [0-9]+' | awk '{ print $NF }')"
    [ -n "${std}" ] && [ -n "${hp}" ] || { echo "inputs: ${std} ${hp}"; return 1; }
    _path_without "${t}/nocurl" curl
    _path_without "${t}/nodig" dig
    # What: one stack state per row, then the real gate
    # Why: each probe must fail for its own cause only
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case compose env world path rc want; do
        cp "${t}/compose.orig" "${DP}/docker-compose.yml"
        [ "${compose}" = - ] || sed -i "${compose}" "${DP}/docker-compose.yml"
        rm -f "${DS}"/fail-* "${DS}/no-answer" "${DS}/running"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; stack_compose "${DP}" "${DP}/.env" up -d'
        [ "${status}" -eq 0 ] || { echo "${case}: up: ${output}"; return 1; }
        cp "${DP}/.env" "${GE}"
        IFS=';' read -r -a kvs <<< "${env}"
        for kv in "${kvs[@]}"; do [ "${kv}" = - ] || set_env_key "${kv%%=*}" "${kv#*=}" "${GE}"; done
        case "${world}" in -) ;; down) rm -f "${DS}/running" ;; *) : > "${DS}/${world}" ;; esac
        CASE_PATH="${BIN}:${PATH}"
        [ "${path}" = full ] || CASE_PATH="${t}/${path}"
        _setup_sh_run 'PATH="${CASE_PATH}"; eval "${SETUP_SH_SEAMS}"
            _UPDATE_ENV_FILE="${GE}" _UPDATE_STACK_DIR="${DP}"; verify_stack_functional_health'
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] && { [ -n "${want}" ] || [ -z "${output}" ]; } \
            || { echo "${case}: rc ${status}: ${output}"; return 1; }
    done <<CASES
ok|-|-|-|full|0|
bindall|s/"\${IP_STANDARD}:${hp}:/"${hp}:/|-|-|full|0|
bindv6|s/"\${IP_STANDARD}:${hp}:/"[::]:${hp}:/|-|-|full|0|
otherip|/"\${IP_STANDARD}:${hp}:/d|-|-|full|1|does not include ${std}:${hp}
nobind|/"\${IP_[A-Z]*}:${hp}:/d|-|-|full|1|does not include ${std}:${hp}
noip|-|IP_STANDARD=;IP_SSL=|-|nocurl|0|
nocurl|-|-|-|nocurl|1|requires 'curl', which is not installed
nodig|-|-|-|nodig|1|requires 'dig', which is not installed
healthz|-|-|fail-exec|full|1|inside the proxy container
nodns|-|-|no-answer|full|1|did not resolve
tcp|-|-|fail-tcp|full|1|TCP connect to ${std}:${hp}
nocid|-|-|down|full|1|no running 'proxy' container
sslonly|-|IP_STANDARD=;SSL_ENABLED=1|-|nocurl|1|requires 'curl'
sslok|-|IP_STANDARD=;SSL_ENABLED=1|-|full|0|
ssloff|-|IP_STANDARD=;SSL_ENABLED=0|-|nocurl|0|
CASES
    # What: package choice and install outcome per apt state
    # Why: a failed lookup must stop, never install ""
    # From: Issue #1683 | PR #1858
    pref="$(declare -f package_name_for_tool | grep -oE "printf '%s.n' [a-z0-9.+-]+" | awk 'NR == 1 { print $NF }')"
    fall="$(declare -f package_name_for_tool | grep -oE "printf '%s.n' [a-z0-9.+-]+" | awk 'NR == 2 { print $NF }')"
    [ -n "${pref}" ] && [ -n "${fall}" ] && [ "${pref}" != "${fall}" ] || { echo "packages: ${pref} ${fall}"; return 1; }
    export APT="${t}/apt" CODE="${#pref}" PREF="${pref}"
    _tool_stub "${APT}" apt-cache <<'STUB'
case "$(cat "${0%/*}/mode")" in
    candidate) printf '  Installed: (none)\n  Candidate: %s\n' "$(cat "${0%/*}/version")" ;;
    none) printf '  Installed: (none)\n  Candidate: (none)\n' ;;
    *) exit "$(cat "${0%/*}/mode")" ;;
esac
STUB
    _tool_stub "${APT}" apt-get <<<'exit "$(cat "${0%/*}/$1-rc")"'
    cat "${root}/VERSION" > "${APT}/version"
    _path_without "${t}/noapt" curl dig apt-get apt-cache
    while IFS='|' read -r case mode env path rc want; do
        printf '%s\n' "${mode}" > "${APT}/mode"
        printf '%s\n' "${env%%,*}" > "${APT}/update-rc"; printf '%s\n' "${env#*,}" > "${APT}/install-rc"
        CASE_PATH="${BIN}:${PATH}"
        [ "${path}" = full ] || CASE_PATH="${APT}:${t}/noapt"
        [ "${path}" != noapt ] || CASE_PATH="${t}/noapt"
        _setup_sh_run 'PATH="${CASE_PATH}"; '"${case}"
        [ "${status}" -eq "${rc}" ] && [[ "${output}" == *"${want}"* ]] && { [ -n "${want}" ] || [ -z "${output}" ]; } \
            || { echo "${case}: rc ${status}: ${output}"; return 1; }
    done <<CASES
package_name_for_tool dig|candidate|0,0|apt|0|${pref}
package_name_for_tool dig|none|0,0|apt|0|${fall}
package_name_for_tool dig|${CODE}|0,0|apt|1|apt-cache policy ${pref} failed (exit ${CODE})
package_name_for_tool curl|${CODE}|0,0|apt|0|curl
install_missing_tools curl dig|${CODE}|0,0|full|0|
install_missing_tools curl|${CODE}|0,0|noapt|1|Cannot install missing tools automatically; install: curl
install_missing_tools curl|${CODE}|0,0|apt|1|curl is still missing after installing package(s): curl
install_missing_tools curl|${CODE}|0,${CODE}|apt|1|Failed to install required tool(s): curl
install_missing_tools curl|${CODE}|${CODE},0|apt|1|apt-get update failed (exit ${CODE})
install_missing_tools dig|${CODE}|0,0|apt|1|Cannot resolve the package of dig
CASES
}

@test "setup backup volumes, project name and stack state per docker answer" {
    # What: name, cache volume per mode, state, errors
    # Why: config backups never carry the cache volume
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" name vols cache other mark listing
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    name="$(_prod_compose config --format json | jq -r .name)"
    vols="$(_prod_compose config --volumes)"
    mark="$(print_error '' 2>&1)"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" D="${t}/repo/deploy/prod" ONAME="${name}-${BATS_TEST_NUMBER}" \
        FAULT="${BATS_TEST_NAME}"
    _prod_install "${D}"
    cache="$(compose_cache_volume_name "${D}" "${D}/.env")"
    [ "${cache%%_*}" = "${name}" ] && grep -qx -- "${cache#"${name}_"}" <<< "${vols}" \
        || { echo "cache volume ${cache} is not a prod compose volume"; return 1; }
    other="${name}_$(awk -v c="${cache#"${name}_"}" '$0 != c { print; exit }' <<< "${vols}")"
    mkdir -p "${DS}/volumes/${cache}" "${DS}/volumes/${other}"
    printf '%s\n' "${cache}" > "${DS}/volumes/${cache}/.${cache}"
    printf '%s\n' "${other}" > "${DS}/volumes/${other}/.${other}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"
        echo "name=$(compose_project_name "${D}" "${D}/.env")"
        echo "override=$(COMPOSE_PROJECT_NAME="${ONAME}" compose_project_name "${D}" "${D}/.env")"
        backup_compose_volumes "${D}" "${T}/config" config
        backup_compose_volumes "${D}" "${T}/full" full
        compose_stack_running "${D}" && echo state=running || echo state=stopped
        : > "${DS}/running"
        compose_stack_running "${D}" && echo state=running || echo state=stopped'
    [ "${status}" -eq 0 ] && [[ "${output}" == *"name=${name}"*"override=${ONAME}"*"state=stopped"*"state=running"* ]] \
        || { echo "run: ${output}"; return 1; }
    [ ! -e "${t}/config/${cache}.tar" ] && [ -f "${t}/full/${cache}.tar" ] && [ -f "${t}/config/${other}.tar" ] \
        || { echo "cache volume per mode"; ls -R "${t}/config" "${t}/full"; return 1; }
    listing="$(tar -tf "${t}/config/${other}.tar")"
    grep -qx -- "./.${other}" <<< "${listing}" || { echo "dotfile not archived: ${listing}"; return 1; }
    : > "${DS}/fail-volume"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; compose_volume_names "${D}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${FAULT}"*"${mark}"*"${name}"* && "${output}" != *unreached* ]] \
        || { echo "volume ls failure: ${output}"; return 1; }
}

@test "setup restore guard refuses volumes another install owns" {
    # What: foreign, unlabeled, labeled volumes, no docker
    # Why: one project name shares volumes across installs
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" case owner arch vols rc want mark vol
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mark="$(print_error '' 2>&1)"
    export BIN="${t}/bin" T="${t}" D="${t}/inst" O="${t}/other" P
    P="$(_prod_compose config --format json | jq -r .name)"
    vol="${P}_$(_backup_volume)"
    mkdir -p "${D}" "${O}" "${t}/empty"
    while IFS='|' read -r case owner arch vols rc want; do
        export DS="${t}/ds-${case}" A="${!arch}"
        mkdir -p "${DS}/volumes"
        [ "${owner}" = - ] || printf '%s %s\n' "${case}" "${owner:+${!owner}}" > "${DS}/foreign"
        [ "${vols}" = 0 ] || mkdir -p "${DS}/volumes/${vol}"
        _setup_sh_run 'PATH="${BIN}:${PATH}"; guard_restore_shared_project_volumes "${D}" "${A}" "${P}"; echo "passed=${DS}"'
        if [ "${rc}" -eq 0 ]; then
            [ "${status}" -eq 0 ] && [[ "${output}" == *"passed=${DS}"* ]] || { echo "${case}: ${output}"; return 1; }
        else
            [ "${status}" -eq 1 ] && [[ "${output}" == *"${mark}"*"${!want}"* && "${output}" != *passed=* ]] \
                || { echo "${case}: rc ${status} ${output}"; return 1; }
        fi
    done <<'CASES'
foreign|O|D|0|1|O
own|D|O|0|0|-
nolabel||D|0|1|case
crossdir|-|O|1|1|O
samedir|-|D|1|0|-
CASES
    export DS="${t}/ds-nodocker"
    _setup_sh_run 'PATH="${T}/empty"; guard_restore_shared_project_volumes "${D}" "${O}" "${P}"; echo "passed=${DS}"'
    [ "${status}" -eq 0 ] && [ "${output}" = "passed=${DS}" ] || { echo "no docker: ${output}"; return 1; }
}

@test "setup restore replaces volume content, dotfiles included" {
    # What: restore empties a volume, then unpacks
    # Why: no stale file survives; a bad archive keeps data
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" vol v mark n
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mark="$(print_error '' 2>&1)"
    vol="$(_prod_compose config --format json | jq -r .name)_$(_backup_volume)"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" D="${t}/repo/deploy/prod"
    _prod_install "${D}"
    v="${DS}/volumes/${vol}"
    mkdir -p "${t}/src/${vol}" "${t}/src/.${vol}.d" "${t}/vr" "${t}/bad" "${v}"
    for n in "${vol}" ".${vol}" "${vol}/.${vol}"; do printf '%s\n' "${n}" > "${t}/src/${n}.f"; done
    tar -C "${t}/src" -cpf "${t}/vr/${vol}.tar" .
    for n in "${DS##*/}" ".${DS##*/}" "..${DS##*/}"; do printf '%s\n' "${n}" > "${v}/${n}"; done
    _setup_sh_run 'PATH="${BIN}:${PATH}"; restore_compose_volumes "${D}" "${T}/vr"'
    [ "${status}" -eq 0 ] || { echo "restore: ${output}"; return 1; }
    diff -r "${t}/src" "${v}" || { echo "volume differs from the archive"; return 1; }
    cp "${t}/vr/${vol}.tar" "${t}/bad/${vol}.tar"
    truncate -s 1 "${t}/bad/${vol}.tar"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; restore_compose_volumes "${D}" "${T}/bad"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${mark}"*"${vol}"* && "${output}" != *unreached* ]] \
        || { echo "bad archive: ${output}"; return 1; }
    diff -r "${t}/src" "${v}" || { echo "a bad archive changed the volume"; return 1; }
}

@test "setup backup and restore round-trip per target and host" {
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

@test "setup backup failure restarts the stack and leaves nothing" {
    # What: volume or tar fails: stack back up, no files
    # Why: a failed backup must not stop the cache
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" real vol mark
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mark="$(print_error '' 2>&1)"
    vol="$(_prod_compose config --format json | jq -r .name)_$(_backup_volume)"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" S="${t}/a/deploy/prod" FAULT="${BATS_TEST_NAME}"
    _prod_install "${S}"
    mkdir -p "${DS}/volumes/${vol}" "${t}/tarbin"
    : > "${DS}/running"; : > "${DS}/fail-run"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_backup --config --dest "${T}/bk" "${S}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${mark}"*"${vol}"* && "${output}" != *unreached* ]] \
        && [[ "${output}" != *"unbound variable"* ]] || { echo "run: ${output}"; return 1; }
    [ -e "${DS}/running" ] && [ -z "$(ls -A "${t}/bk")" ] || { echo "after run failure: $(ls -A "${t}/bk")"; return 1; }
    rm -f "${DS}/fail-run"; rm -rf "${DS}/volumes/${vol}"
    real="$(command -v tar)"
    printf '#!/usr/bin/env bash\ncase "$*" in "-C %s "*) echo "${FAULT}" >&2; exit 2 ;; esac\nexec %q "$@"\n' "${t}/bk" "${real}" \
        > "${t}/tarbin/tar"
    chmod +x "${t}/tarbin/tar"
    _setup_sh_run 'PATH="${T}/tarbin:${BIN}:${PATH}"; cmd_backup --config --dest "${T}/bk" "${S}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${FAULT}"*"${mark}"*"${t}/bk/"* && "${output}" != *unreached* ]] \
        || { echo "tar: ${output}"; return 1; }
    [ -e "${DS}/running" ] && [ -z "$(ls -A "${t}/bk")" ] || { echo "after tar failure: $(ls -A "${t}/bk")"; return 1; }
}

@test "setup convergence pause records units and resume restores them" {
    # What: pause stops/disables; resume restores only that.
    # Why: an update must not drop or invent a timer state
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" ta te sa u
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    export BIN="${t}/bin"
    _tool_stub "${BIN}" systemctl <<'STUB'
cmd="$1"; shift
[ "${1:-}" != --quiet ] || shift
[ "${1:-}" != --no-legend ] || shift
s="${SD}/$1"
if [ ! -e "${s}.seen" ]; then
    : > "${s}.seen"
    case "$1" in
        *.timer) [ "${TA}" = 0 ] || : > "${s}.active"; [ "${TE}" = 0 ] || : > "${s}.enabled" ;;
        *.service) [ "${SA}" = 0 ] || : > "${s}.active" ;;
    esac
fi
case "${cmd}" in
    list-unit-files) echo "$1" ;;
    is-active) [ -e "${s}.active" ] ;;
    is-enabled) [ -e "${s}.enabled" ] ;;
    stop) rm -f "${s}.active" ;;
    disable) rm -f "${s}.enabled" ;;
    start) : > "${s}.active" ;;
    enable) : > "${s}.enabled" ;;
    *) echo "unexpected systemctl call: ${cmd} $*" >&2; exit 97 ;;
esac
STUB
    for ta in 0 1; do for te in 0 1; do for sa in 0 1; do
        export SD="${t}/sd-${ta}${te}${sa}" TA="${ta}" TE="${te}" SA="${sa}"
        mkdir -p "${SD}"
        # What: systemd_available, the one replaced probe
        # Why: it tests /run/systemd, absent in containers
        # From: Issue #1683 | PR #1858
        _setup_sh_run 'PATH="${BIN}:${PATH}"; systemd_available() { return 0; }
            pause_lancache_convergence_for_update
            echo "rec=${CONVERGENCE_TIMER_WAS_ACTIVE}${CONVERGENCE_TIMER_WAS_ENABLED}${CONVERGENCE_SERVICE_WAS_ACTIVE}"
            echo "left=$(find "${SD}" -name "*.active" -o -name "*.enabled" | wc -l)"
            resume_lancache_convergence_after_update true'
        [ "${status}" -eq 0 ] && [[ "${output}" == *"rec=${ta}${te}${sa}"*"left=0"* ]] || { echo "${SD}: ${output}"; return 1; }
        [ -n "$(find "${SD}" -name '*.timer.seen')" ] && [ -n "$(find "${SD}" -name '*.service.seen')" ] \
            || { echo "${SD}: no timer and service seen"; return 1; }
        for u in "${SD}"/*.timer.seen; do
            u="${u%.seen}"
            [ "$([ -e "${u}.active" ] && echo 1 || echo 0)$([ -e "${u}.enabled" ] && echo 1 || echo 0)" = "${ta}${te}" ] \
                || { echo "${u}: timer state not restored"; return 1; }
        done
        for u in "${SD}"/*.service.seen; do
            u="${u%.seen}"
            [ "$([ -e "${u}.active" ] && echo 1 || echo 0)" = "${sa}" ] || { echo "${u}: service state not restored"; return 1; }
        done
    done; done; done
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

@test "setup log bundle picks the compressor by availability" {
    # What: zstd, else bzip2, else gzip, by what is on PATH
    # Why: smallest bundle the host can actually write
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" body case avail tool ext real
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    body="$(declare -f write_compressed_tar)"
    # What: the picked suffix has an arm using that tool
    # Why: selector and archiver must agree on every suffix
    # From: Issue #1683 | PR #1858
    while IFS='|' read -r case avail; do
        mkdir -p "${t}/${case}"
        for tool in ${avail//,/ }; do _tool_stub "${t}/${case}" "${tool}" <<<'exit 0'; done
        ext="$(PATH="${t}/${case}" logbundle_select_compressor)"
        tool="$(awk -v e="${ext})" '$1 == e { getline; sub(/^[^(]*\(/, ""); print $1; exit }' <<< "${body}")"
        [ -n "${tool}" ] && { [ -z "${avail}" ] || [ "${tool}" = "${avail%%,*}" ]; } \
            || { echo "${case}: picked .${ext}, archiver packs it with '${tool}'"; return 1; }
        real="$(type -P "${tool}")" || continue
        # What: the tool's own suffix; a readable archive
        # Why: the archive is whole when the writer returns
        # From: Issue #1683 | PR #1858
        mkdir -p "${t}/z-${case}" && printf '%s\n' "${case}" > "${t}/z-${case}/f"
        "${real}" "${t}/z-${case}/f" && [ -e "${t}/z-${case}/f.${ext}" ] \
            || { echo "${case}: ${real} does not write .${ext}: $(ls "${t}/z-${case}")"; return 1; }
        export ZE="${ext}" ZA="${t}/${case}.tar.${ext}" ZP="${t}" ZN="z-${case}"
        _setup_sh_run 'write_compressed_tar "${ZE}" "${ZA}" "${ZP}" "${ZN}"'
        [ "${status}" -eq 0 ] && [ "$("${real}" -dc < "${t}/${case}.tar.${ext}" | tar -tf - | grep -c "f\.${ext}$")" -eq 1 ] \
            || { echo "${case}: archive: ${output}"; return 1; }
    done <<'CASES'
both|zstd,bzip2
bzip2|bzip2
none|
CASES
}

@test "setup log bundle lists snapshot volumes per volume state" {
    # What: missing, failing lookup, volume, no docker
    # Why: the bundle must say why a listing is empty
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" base vol n
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    base="$(_backup_volume)"
    vol="$(_prod_compose config --format json | jq -r .name)_${base}"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" I="${t}/repo/deploy/prod" B="${base}" SUB="${BATS_TEST_NUMBER}" \
        FAULT="${BATS_TEST_NAME}"
    _prod_install "${I}"
    mkdir -p "${DS}/volumes" "${t}/empty"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; logbundle_named_volume_listing "${I}" "${I}/.env" "${B}" "${SUB}" "${T}/1"
        : > "${DS}/fail-volume"
        logbundle_named_volume_listing "${I}" "${I}/.env" "${B}" "${SUB}" "${T}/3"
        PATH="${T}/empty" logbundle_named_volume_listing "${I}" "${I}/.env" "${B}" "${SUB}" "${T}/4"'
    [ "${status}" -eq 0 ] || { echo "run: ${output}"; return 1; }
    rm -f "${DS}/fail-volume"
    mkdir -p "${DS}/volumes/${vol}/${BATS_TEST_NUMBER}"
    : > "${DS}/volumes/${vol}/${BATS_TEST_NUMBER}/${vol}"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; logbundle_named_volume_listing "${I}" "${I}/.env" "${B}" "${SUB}" "${T}/5"'
    [ "${status}" -eq 0 ] || { echo "listing: ${output}"; return 1; }
    for n in 1 3 4 5; do [ -s "${t}/${n}" ] || { echo "listing ${n} is empty"; return 1; }; done
    grep -qF -- "${vol}" "${t}/1" && ! grep -qF -- "${vol}" "${t}/4" && grep -qF -- "${FAULT}" "${t}/3" \
        && grep -qF -- "${vol}" "${t}/5" && ! cmp -s "${t}/1" "${t}/4" || { head -n 3 "${t}/1" "${t}/3" "${t}/4" "${t}/5"; return 1; }
}

@test "setup log bundle archive holds no secret and no leftovers" {
    # What: one redacted archive; on failure: nothing
    # Why: the bundle is attached to a public issue
    # From: Issue #1683 | PR #1858
    local root t="${BATS_TEST_TMPDIR}" key secret archive marker mark
    local -a unpack=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mark="$(print_error '' 2>&1)"
    key="$(logbundle_secret_env_keys | awk 'NR == 1')"
    secret="$(generate_secret_value "${key}" hex32)"
    printf '%s\n' "${secret}" > "${t}/s"
    marker="$(logbundle_redact_stream "${t}/s" <<< "${secret}")"
    export DS="${t}/ds" BIN="${t}/bin" T="${t}" I="${t}/repo/deploy/prod" STUB_SECRET="${secret}" FAULT="${BATS_TEST_NAME}"
    _prod_install "${I}"
    set_env_key "${key}" "${secret}" "${I}/.env"
    mkdir -p "${DS}/volumes" "${t}/x" "${t}/tarbin" "${t}/tmpd"
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_create_logs_for_issue "${I}" --dest "${T}/out"'
    [ "${status}" -eq 0 ] || { echo "bundle: ${output}"; return 1; }
    archive="$(find "${t}/out" -mindepth 1 -maxdepth 1)"
    [ "$(wc -l <<< "${archive}")" -eq 1 ] && [ -f "${archive}" ] || { echo "out: ${archive}"; return 1; }
    case "${archive##*.}" in
        bz2) unpack=(bzip2 -dc) ;; zst) unpack=(zstd -qdc) ;; gz) unpack=(gzip -dc) ;;
        *) echo "unknown archive type: ${archive}"; return 1 ;;
    esac
    # What: decompress with the format's tool, then untar
    # Why: busybox tar's own bz2 path corrupts some streams
    # From: Issue #1683 | PR #1858
    if ! "${unpack[@]}" "${archive}" > "${t}/raw.tar" || ! tar -C "${t}/x" -xf "${t}/raw.tar"; then
        echo "extract failed: $(ls -l "${archive}"), $(wc -c < "${t}/raw.tar") raw bytes"
        tar -tvf "${t}/raw.tar"
        echo "raw list rc $?"
        return 1
    fi
    ! grep -rqF -- "${secret}" "${t}/x" || { echo "secret in bundle: $(grep -rlF -- "${secret}" "${t}/x")"; return 1; }
    grep -rqxF -- "${key}=${marker}" "${t}/x" && [ "$(grep -rlF -- "${marker}" "${t}/x" | wc -l)" -gt 1 ] \
        || { echo "redaction: $(grep -rlF -- "${marker}" "${t}/x")"; return 1; }
    _setup_sh_run 'PATH="${BIN}:${PATH}"; cmd_create_logs_for_issue "${T}/none" --dest "${T}/out2"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${mark}"*"${t}/none"* && "${output}" != *unreached* ]] \
        || { echo "no stack: ${output}"; return 1; }
    printf '#!/usr/bin/env bash\necho "${FAULT}" >&2\nexit 2\n' > "${t}/tarbin/tar"
    chmod +x "${t}/tarbin/tar"
    _setup_sh_run 'PATH="${T}/tarbin:${BIN}:${PATH}" TMPDIR="${T}/tmpd"; cmd_create_logs_for_issue "${I}" --dest "${T}/out3"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"${FAULT}"*"${mark}"*"${t}/out3/"* && "${output}" != *unreached* ]] \
        || { echo "tar failure: ${output}"; return 1; }
    [ -z "$(ls -A "${t}/out3")" ] && [ -z "$(ls -A "${t}/tmpd")" ] || {
        echo "leftovers: $(ls -A "${t}/out3" "${t}/tmpd")"; return 1; }
}

@test "setup debug stays read-only and converge folds UI settings once" {
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

@test "dns config adapters snapshot, roll back and converge" {
    # What: per role: create, rollback, none, keep, repeat.
    # Why: a broken config must never start or be stored.
    # From: Issue #1683 | PR #1858
    local root bin="${BIN}" live="${BATS_TEST_TMPDIR}/live" t
    local role fn conf label keyline n snap fp h
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=scripts/lib/known-good-snapshots.sh
    source "${root}/$(ci_context_path known-good)"
    # shellcheck source=services/dns/entrypoint.sh
    source "$(_extract_functions "${root}/services/dns/entrypoint.sh" \
        _dns_recursor_validate_snapshot_or_rollback _dns_auth_validate_snapshot_or_rollback)"
    for t in pdns_recursor:recursor.conf pdns_server:pdns.conf; do
        _tool_stub "${bin}" "${t%%:*}" <<SH
d=""; for a in "\$@"; do case "\$a" in --config-dir=*) d="\${a#--config-dir=}" ;; esac; done
if grep -q BROKEN "\${d}/${t#*:}"; then echo "${t%%:*}: bad config" >&2; exit 1; fi
SH
    done
    export PATH="${bin}:${PATH}" PDNS_API_KEY=key-now DNS_CONFIG_SNAPSHOT_DIR="${BATS_TEST_TMPDIR}/snap"
    mkdir -p "${live}"
    for role in 'recursor|recursor.conf|dns-recursor|api_key: ' 'auth|pdns.conf|dns-auth|api-key='; do
        IFS='|' read -r n conf label keyline <<< "${role}"
        fn="_dns_${n}_validate_snapshot_or_rollback"
        conf="${live}/${conf}"
        snap="${DNS_CONFIG_SNAPSHOT_DIR}/${n}"
        rm -rf "${DNS_CONFIG_SNAPSHOT_DIR}"
        export KEEP_KNOWN_GOOD_CONFIGS=3 PDNS_API_KEY=key-now
        printf 'BROKEN\n' > "${conf}"
        run "${fn}" "${conf}"
        [ "${status}" -eq 1 ] && [[ "${output}" == *"no known-good ${conf##*/} snapshot is available"* ]] || {
            echo "${n} none: ${status}: ${output}"; return 1; }
        [ "$(cat "${conf}")" = BROKEN ]
        printf '%skey-now\nOK v1\n' "${keyline}" > "${conf}"
        run "${fn}" "${conf}"
        [ "${status}" -eq 0 ] && [[ "${output}" == *"[known-good-snapshot][${label}][CREATE]"* ]] || {
            echo "${n} valid: ${output}"; return 1; }
        [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 1 ]
        printf 'BROKEN v2\n' > "${conf}"
        run "${fn}" "${conf}"
        [ "${status}" -eq 0 ] || { echo "${n} rollback: ${output}"; return 1; }
        [[ "${output}" == *"generated ${conf##*/} failed validation"*"[known-good-snapshot][${label}][SELECT]"*"NOT the newly generated config"* ]]
        [[ "${output}" != *"does not match the current PDNS_API_KEY"* ]]
        [ "$(sed -n 2p "${conf}")" = "OK v1" ]
        h="$(sha256sum < "${conf}")"
        fp="$(_kgs_fingerprint "${snap}")"
        printf 'BROKEN v2\n' > "${conf}"
        run "${fn}" "${conf}"
        [ "${status}" -eq 0 ] && [ "$(sha256sum < "${conf}")" = "${h}" ] && [ "$(_kgs_fingerprint "${snap}")" = "${fp}" ] || {
            echo "${n} repeat is no fixed point"; return 1; }
        if grep -rq BROKEN "${snap}"; then echo "${n}: broken config snapshotted"; return 1; fi
        export PDNS_API_KEY=key-rotated
        run "${fn}" "${conf}"
        [ "${status}" -eq 0 ] && [[ "${output}" != *"does not match the current PDNS_API_KEY"* ]] || {
            echo "${n} valid restored config: ${output}"; return 1; }
        printf 'BROKEN v3\n' > "${conf}"
        run "${fn}" "${conf}"
        [ "${status}" -eq 0 ] && [[ "${output}" == *"does not match the current PDNS_API_KEY"* ]] || {
            echo "${n} stale key: ${output}"; return 1; }
        export KEEP_KNOWN_GOOD_CONFIGS=2
        for t in 1 2 3 4; do printf 'OK r%s\n' "${t}" > "${conf}"; "${fn}" "${conf}" > /dev/null; done
        [ "$(kgs_list_snapshots "${snap}" | wc -l)" -eq 2 ] || { echo "${n}: retention"; return 1; }
    done
    # What: auth rollback re-stamps this run's address.
    # Why: the snapshot holds the prior container address.
    # From: Issue #1683 | PR #1858
    rm -rf "${DNS_CONFIG_SNAPSHOT_DIR}"
    export KEEP_KNOWN_GOOD_CONFIGS=3
    printf 'local-address=127.0.0.1,172.20.0.2\nOK a1\n' > "${live}/pdns.conf"
    PDNS_LOCAL_ADDRESS=172.20.0.2 _dns_auth_validate_snapshot_or_rollback "${live}/pdns.conf" > /dev/null
    printf 'OK r1\n' > "${live}/recursor.conf"
    _dns_recursor_validate_snapshot_or_rollback "${live}/recursor.conf" > /dev/null
    printf 'BROKEN\n' > "${live}/pdns.conf"
    PDNS_LOCAL_ADDRESS=172.20.0.9 run _dns_auth_validate_snapshot_or_rollback "${live}/pdns.conf"
    [ "${status}" -eq 0 ]
    [ "$(cat "${live}/pdns.conf")" = $'local-address=127.0.0.1,172.20.0.9\nOK a1' ]
    [ "$(kgs_list_snapshots "${DNS_CONFIG_SNAPSHOT_DIR}/recursor" | wc -l)" -eq 1 ]
    [ "$(cat "${live}/recursor.conf")" = "OK r1" ]
}
