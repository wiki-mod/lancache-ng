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
    # What: a repository name when the suite runs env -i.
    # Why: image refs need one; a test may unset it.
    # From: Issue #1683 | PR #1912
    export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(_val name)/$(_val name)}"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
    CI_MANIFEST_SOURCE="${CI_MANIFEST}"
    # What: index the real SOT once in the test shell.
    # Why: sourced readers look up, as under ci_main.
    # From: Issue #1683 | PR #1858
    _ci_sot_load || return 1
    # What: the SOT_ compose values every test shares.
    # Why: compose takes mount and port targets from them.
    # From: Issue #1683 | PR #1912
    local fx kv
    fx="$(_ci_sot_compose_env)" || return 1
    while IFS= read -r kv; do
        export "${kv?}"
    done <<<"${fx}"
}

# What: docker and dig stand-ins first on PATH, state in DS
# Why: setup.sh flows drive containers the test box lacks
# From: Issue #1683 | PR #1858
_stand_ins() {
    BIN="$(_val path)" DS="$(_val path)"; export BIN DS
    mkdir -p "${DS}/volumes" && _docker_stub "${BIN}" || return 1
    PATH="${BIN}:${PATH}"
}

# What: the SOT release version as its image tag, vX.Y.Z
# Why: fixtures and the test registry name one tag
# From: Issue #1683 | PR #1858
_release_tag() {
    local v
    v="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_release_value version)" || return 1
    printf 'v%s\n' "${v}"
}

# What: a TLS registry on the test daemon with dns:<tag>
# Why: setup.sh image lookups reach a real registry
# From: Issue #1683 | PR #1858
_registry() {
    local d="${BATS_TEST_TMPDIR}/registry" img alp tag id port gw c host="" san="" i ref failed=""
    local -a reg_hosts=() ec=(-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes)
    img="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field base_images "" registry)" \
        && alp="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field base_images "" alpine)" \
        && tag="$(_release_tag)" || return 1
    [ -n "${img}" ] && [ -n "${alp}" ] || { echo "SOT base_images.registry or .alpine is empty"; return 1; }
    case "${DOCKER_HOST:-}" in tcp://*) c="${DOCKER_HOST#tcp://}"; reg_hosts+=("${c%:*}") ;; esac
    gw="$(awk 'NR > 1 && $2 == "00000000" { print $3; exit }' /proc/net/route)" || return 1
    [ -z "${gw}" ] || reg_hosts+=("$(printf '%d.%d.%d.%d' "0x${gw:6:2}" "0x${gw:4:2}" "0x${gw:2:2}" "0x${gw:0:2}")")
    reg_hosts+=(127.0.0.1)
    for c in "${reg_hosts[@]}"; do
        case "${c}" in *[!0-9.]*) san+=",DNS:${c}" ;; *) san+=",IP:${c}" ;; esac
    done
    mkdir -p "${d}/certs" && printf 'subjectAltName=%s\n' "${san#,}" > "${d}/san" || return 1
    openssl req -x509 "${ec[@]}" -days 1 -subj /CN=ci-bats-ca -keyout "${d}/ca.key" -out "${d}/ca.crt" \
        > "${d}/openssl.log" 2>&1 \
        && openssl req "${ec[@]}" -subj /CN=ci-bats-registry -keyout "${d}/certs/r.key" -out "${d}/r.csr" \
        >> "${d}/openssl.log" 2>&1 \
        && openssl x509 -req -in "${d}/r.csr" -CA "${d}/ca.crt" -CAkey "${d}/ca.key" -CAcreateserial -days 1 \
        -extfile "${d}/san" -out "${d}/certs/r.crt" >> "${d}/openssl.log" 2>&1 || { cat "${d}/openssl.log"; return 1; }
    cat "${CI_SYSTEM_CA_PATH}" "${d}/ca.crt" > "${d}/bundle.crt" || return 1
    id="$(docker create -p 5000 -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/r.crt -e REGISTRY_HTTP_TLS_KEY=/certs/r.key "${img}")" \
        || return 1
    printf '%s %s %s\n' "$(type -P docker)" "${DOCKER_HOST:--}" "${id}" >> "${BATS_TEST_TMPDIR}/containers" || return 1
    docker cp "${d}/certs" "${id}:/certs" && docker start "${id}" > "${d}/start.log" && port="$(docker port "${id}" 5000/tcp)" \
        || return 1
    port="${port%%$'\n'*}" port="${port##*:}"
    for i in $(seq 1 20); do
        for c in "${reg_hosts[@]}"; do
            if curl -sf --max-time 1 --cacert "${d}/ca.crt" -o "${d}/v2.out" "https://${c}:${port}/v2/" \
                > "${d}/curl-${i}.log" 2>&1; then
                host="${c}"
                break 2
            fi
        done
        sleep 1
    done
    [ -n "${host}" ] || { echo "registry ${id} answers on none of ${reg_hosts[*]} port ${port}"; cat "${d}/curl-${i}.log"
        docker logs "${id}"; return 1; }
    LANCACHE_IMAGE_PREFIX="$(_val name)"
    export SSL_CERT_FILE="${d}/bundle.crt" LANCACHE_IMAGE_REGISTRY="${host}:${port}" LANCACHE_IMAGE_PREFIX
    ref="localhost:${port}/${LANCACHE_IMAGE_PREFIX}/dns:${tag}"
    docker pull -q "${alp}" > "${d}/push.log" 2>&1 && docker tag "${alp}" "${ref}" || { cat "${d}/push.log"; return 1; }
    docker push -q "${ref}" >> "${d}/push.log" 2>&1 || failed+=" push"
    docker rmi "${ref}" >> "${d}/push.log" 2>&1 || failed+=" rmi"
    [ -z "${failed}" ] || { echo "registry image ${ref}:${failed} failed"; cat "${d}/push.log"; return 1; }
}

# What: TCP listeners on port 80 of each given address
# Why: setup.sh's health gate makes a real TCP connect
# From: Issue #1683 | PR #1858
_listen80() {
    local p
    for p in "$@"; do
        timeout 600 busybox nc -lk -s "${p}" -p 80 -e true 0<&- > "${BATS_TEST_TMPDIR}/nc-${p}.log" 2>&1 3>&- &
        printf '%s %s\n' "$!" "${p}" >> "${BATS_TEST_TMPDIR}/listeners" || return 1
    done
}

# What: drop the runner cache inputs from this shell.
# Why: one list keeps tests off the real runner caches.
# From: Issue #1683 | PR #1858
_cache_env_clean() {
    unset RUNNER_ENVIRONMENT SCCACHE_REDIS_URL SCCACHE_DIR ACTIONS_RESULTS_URL ACTIONS_RUNTIME_TOKEN
}

# What: sources setup.sh; its guard stops before the run
# Why: tests drive the product code with its real die
# From: Issue #1683 | PR #1858
_load_setup_sh() {
    local -
    SETUP_SH="$1/setup.sh"
    export SETUP_SH DOCKER_HOST="${SETUP_SH_DOCKER_HOST}"
    # shellcheck source=setup.sh
    source "${SETUP_SH}" "$(_val name)"
}

# What: runs a snippet on loaded setup.sh fns, setup.sh opts
# Why: failure paths are proven under set -euo pipefail
# From: Issue #1683 | PR #1858
_setup_sh_run() {
    [ -n "${SETUP_SH:-}" ] || { echo "_setup_sh_run needs _load_setup_sh first"; return 1; }
    run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" bash -c 'set -euo pipefail; . "$1" "$3"; eval "$2"' _ "${SETUP_SH}" "$1" \
        "$(_val name)"
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

# What: the DHCP mode names of the Rust owner, in its order
# Why: setup.sh must offer exactly the modes the ui accepts
# From: Issue #1683 | PR #1858
_rust_dhcp_modes() {
    local src="$1/services/common/config.rs" out
    [ -r "${src}" ] || { echo "_rust_dhcp_modes: ${src} not readable" >&2; return 1; }
    out="$(awk '/^impl DhcpMode/ { d = 1 } d && /pub fn as_str/ { f = 1 } f && /^    }$/ { exit } f' "${src}" \
        | sed -n 's/.*Self::[A-Za-z]* => "\([a-z-]*\)",/\1/p')"
    [ -n "${out}" ] || { echo "_rust_dhcp_modes: no DhcpMode::as_str names in ${src}" >&2; return 1; }
    printf '%s\n' "${out}"
}

# What: replace each @KEY@ in a row from the caller's V map.
# Why: one fill for every table built on _val values.
# From: Issue #1683 | PR #1858
_fill() {
    local s="$1" k
    for k in "${!V[@]}"; do s="${s//"${k}"/"${V[${k}]}"}"; done
    printf '%s' "${s}"
}

# What: stop listeners, remove containers; raw on failure
# Why: nothing outlives its test; raw values stay shown
# From: Issue #1683 | PR #1858
teardown() {
    local rc=0 f="${BATS_TEST_TMPDIR}/containers" l="${BATS_TEST_TMPDIR}/listeners" bin h id pid ip err
    if [ -s "${l}" ]; then
        while read -r pid ip; do
            err="$(kill "${pid}" 2>&1)" && continue
            echo "listener ${ip}:80 gone before teardown: ${err}; nc: $(cat "${BATS_TEST_TMPDIR}/nc-${ip}.log")"
            rc=1
        done < "${l}"
    fi
    if [ -s "${f}" ]; then
        while read -r bin h id; do
            if [ "${h}" = - ]; then env -u DOCKER_HOST "${bin}" rm -f "${id}"; else DOCKER_HOST="${h}" "${bin}" rm -f "${id}"; fi \
                > "${f}.rm.log" 2>&1 || { rc=$?; cat "${f}.rm.log"; }
        done < "${f}"
    fi
    [ -n "${BATS_TEST_COMPLETED:-}" ] ||
        printf 'last-run status=%s\nlast-run output=%s\n' "${status:-unset}" "${output-}"
    return "${rc}"
}

# =========================================================
# CORE INVARIANTS
# =========================================================

# What: per row: needs results -> gate rc and verdict
# Why: §62: only success or an optional skip greens it
# From: Issue #1683 | PR #1858
@test "result-gate maps each phase-result set to its verdict" {
    local req p all="" noop="" other
    req="$(_ci_block_entry_list ci_result_gate "" required)" || { echo "required: ${req}"; return 1; }
    [ -n "${req// }" ] || { echo "no SOT ci_result_gate.required phase"; return 1; }
    other="$(_val name)"
    for p in ${req}; do all+=" ${p}:success" noop+=" ${p}:success"; done
    for p in "${other}" "$(_val name)"; do all+=" ${p}:success" noop+=" ${p}:skipped"; done
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
    _row noop 0 "[CI-INFO-CORE-0152] not-run=\"${other};-> SUCCESS (NOT-RUN: ${other}" "${noop}" || return 1
    _row all-ran 0 "-> SUCCESS" "${all}" || return 1
    [[ "${output}" != *"NOT-RUN"* ]] || { echo "all-ran: a pass is called NOT-RUN: ${output}"; return 1; }
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
@test "each command's input guard stops first with its own id" {
    local case envs args id wrap want svc tool plat
    local -a ev av
    svc="$(ci_services)" && tool="$(_ci_block_keys build_toolchain)" || { echo "SOT readers failed"; return 1; }
    svc="${svc%%$'\n'*}" tool="${tool%%$'\n'*}"
    plat="$(_ci_platforms "${svc}")" || { echo "${svc}: no platforms"; return 1; }
    plat="${plat%%$'\n'*}"
    [ -n "${svc}" ] && [ -n "${tool}" ] && [ -n "${plat}" ] || { echo "inputs: ${svc}|${tool}|${plat}"; return 1; }
    local -A V=(
        ["@SVC@"]="${svc}" ["@TOOL@"]="${tool}" ["@PLAT@"]="${plat}"
        ["@BAD@"]="$(_val name)" ["@FOREIGN@"]="$(_val platform)" ["@DIGEST@"]="$(_val digest)"
        ["@USER@"]="$(_val name)" ["@TOKEN@"]="$(_val name)" ["@MISSING@"]="$(_val path)"
    )
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
codeql-analyze|-|codeql-analyze|CI-ERROR-CODEQL-0002|-
codeql-language|-|codeql-analyze @BAD@|CI-ERROR-CODEQL-0003|-
build|-|build|CI-ERROR-BUILD-0001|-
rust-build|-|rust-build|CI-ERROR-RUSTBUILD-0001|-
rust-build-crate|-|rust-build @SVC@|CI-ERROR-RUSTBUILD-0002|-
rust-build-mode|-|rust-build @SVC@ @BAD@ @BAD@|CI-ERROR-RUSTBUILD-0005|-
rust-build-target|-|rust-build @SVC@ @BAD@|CI-ERROR-RUSTBUILD-0003|-
apk-pin-install|-|apk-pin-install|CI-ERROR-APKSETUP-0006|-
publish|-|publish|CI-ERROR-PUBLISH-0001|-
scan|-|scan|CI-ERROR-SCAN-0001|-
scan-digest|-|scan @SVC@|CI-ERROR-SCAN-0002|-
scan-platform|-|scan @SVC@ @DIGEST@|CI-ERROR-SCAN-0029|-
aggregate|-|aggregate|CI-ERROR-AGGREGATE-0001|-
aggregate-dir|-|aggregate @MISSING@|CI-ERROR-AGGREGATE-0002|-
emit-result|-|emit-result|CI-ERROR-RESULT-0001|-
emit-result-platform|-|emit-result @SVC@|CI-ERROR-RESULT-0002|-
assemble-stack|CI_BUILD_MATRIX=|assemble-stack|CI-ERROR-ASSEMBLE-0006|-
aggregate-stack|CI_BUILD_MATRIX=|aggregate-stack|CI-ERROR-AGGREGATE-0005|-
scan-stack|CI_BUILD_MATRIX=|scan-stack|CI-ERROR-SCAN-0016|-
nightly-report|-|nightly-report|CI-ERROR-STATUS-0001|-
release-publish|-|release-publish|CI-ERROR-RELEASE-0003|-
release-sbom|-|release-sbom|CI-ERROR-RELEASE-0007|-
release-sbom-tag|-|release-sbom @SVC@|CI-ERROR-RELEASE-0008|-
release-sbom-stack|-|release-sbom-stack|CI-ERROR-RELEASE-0013|-
release-vex|-|release-vex|CI-ERROR-RELEASE-0010|-
release-notes|-|release-notes|CI-ERROR-RELEASE-0031|-
release-changelog|-|release-changelog|CI-ERROR-RELEASE-0032|-
close-linked-pr|-|close-linked-issues --pr|CI-ERROR-LINK-0002|-
close-linked-arg|-|close-linked-issues @BAD@|CI-ERROR-LINK-0013|-
gc-arg|-|gc --@BAD@|CI-ERROR-GC-0006|-
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
    CI_TMPDIR="${nofile}" run _ci_run "${id}" "${ctx}" true
    _expect run-no-temp 2 "[CI-ERROR-CORE-0110]" || return 1
    [[ "${output}" != *"${id}"* ]] || { echo "run-no-temp: the command ran: ${output}"; return 1; }
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
here="$(dirname "$(readlink -f "$0")")" || exit 1
case "$1" in
    --version) echo 'docker CLI (test stub)' ;;
    info) echo 'Server Version: test stub' ;;
    compose)
        all=("$@")
        shift
        while :; do case "${1:-}" in --env-file|-f|-p|--profile) shift 2 ;; *) break ;; esac; done
        case "$1" in
            config) [ ! -e "${DS}/fail-config-after-up" ] || [ ! -e "${DS}/running" ] \
                    || { echo "compose config: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1; }
                exec "$(cat "${here}/docker-real")" "${all[@]}" ;;
            ps) case "${2:-}" in
                    --all) ;;
                    -a) [ ! -e "${DS}/running" ] || echo "${DS##*/}-${!#}" ;;
                    -q) [ ! -e "${DS}/running" ] || echo "${DS##*/}" ;;
                    *) echo "${DS##*/}" ;;
                esac ;;
            stop) rm -f "${DS}/running" ;;
            up) [ ! -e "${DS}/fail-apply" ] || case " $* " in
                    *" --remove-orphans "*) echo "compose up: ${FAULT:?a failure injection needs FAULT}" >&2; exit 1 ;;
                esac
                printf '%s\n' "${all[@]:0:${#all[@]}-$#}" > "${DS}/running" ;;
            pull) ;;
            run) [ "${!#}" = hash-password ] || { echo "unexpected docker compose call: $*" >&2; exit 97; }
                sha256sum | cut -c1-43 ;;
            images) echo '[]' ;;
            logs) echo "${!#}" ;;
            version) echo 'docker compose (test stub)' ;;
            *) echo "unexpected docker compose call: $*" >&2; exit 97 ;;
        esac ;;
    volume)
        case "$2" in
            ls) ls -1 "${DS}/volumes" ;;
            create) mkdir -p "${DS}/volumes/$3" ;;
            *) echo "unexpected docker volume call: $*" >&2; exit 97 ;;
        esac ;;
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
    ps) ;;
    inspect)
        case "$3" in
            *State.Health*) [ ! -e "${DS}/running" ] || echo healthy ;;
            *) echo "unexpected docker inspect call: $*" >&2; exit 97 ;;
        esac ;;
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
    buildx) exec "$(cat "${here}/docker-real")" "$@" ;;
    *) echo "unexpected docker call: $*" >&2; exit 97 ;;
esac
STUB
    type -P docker > "$1/docker-real" && [ "$(cat "$1/docker-real")" != "$1/docker" ] \
        || { echo "no real docker binary for compose config and buildx"; return 1; }
    # What: the cache DNS answers CDN names with its own IP
    # Why: the update health gate resolves one CDN name
    # From: Issue #1683 | PR #1858
    _tool_stub "$1" dig <<'STUB'
for a in "$@"; do case "${a}" in @*) server="${a#@}" ;; esac; done
echo "${server:?the dig stub needs @server}"
STUB
}

# What: an operator env file made from the SOT fixture
# Why: no .env is tracked; setup() exports the SOT_ values
# From: Issue #1683 | PR #1912
_template_env() {
    local out="${BATS_TEST_TMPDIR}/operator.env" fx
    if [ ! -s "${out}" ]; then
        fx="$(_ci_validation_env)" || return 1
        grep -v '^SOT_' <<< "${fx}" > "${out}" || return 1
    fi
    printf '%s\n' "${out}"
}

# What: exports the SOT fixture env, like the validate stack
# Why: no .env exists; compose reads the process environment
# From: Issue #1683 | PR #1912
_export_validation_env() {
    local -a kv=()
    mapfile -t kv <<< "$(_ci_validation_env)" && export "${kv[@]}"
}

# What: docker compose on the real deploy/prod files
# Why: tests take names, volumes, profiles from their owner
# From: Issue #1683 | PR #1858
_prod_compose() {
    local root
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    docker compose --env-file "$(_template_env)" -f "${root}/deploy/prod/docker-compose.yml" "$@"
}

# What: a prod volume config backups carry, sorted first
# Why: compose lists volumes in no fixed order
# From: Issue #1683 | PR #1858
_backup_volume() {
    local root project cache
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    project="$(_prod_compose config --format json | jq -r .name)" || return 1
    cache="$(compose_cache_volume_name "${root}/deploy/prod" "$(_template_env)")" || return 1
    _prod_compose config --volumes | sort | grep -vxF -- "${cache#"${project}_"}" | awk 'NR == 1'
}

# What: a deploy/prod install from the real prod files
# Why: setup.sh tests run on owner inputs, not hand copies
# From: Issue #1683 | PR #1858
_prod_install() {
    local root dir="$1"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    mkdir -p "${dir}" "${dir}/../../.github/yaml" "${dir}/../../.github/scripts" || return 1
    cp "${root}/deploy/prod/docker-compose.yml" "${dir}/" && cp "$(_template_env)" "${dir}/.env" || return 1
    cp "${root}/.github/yaml/build-manifest.yml" "${dir}/../../.github/yaml/" || return 1
    cp "${root}/.github/scripts/ci.sh" "${dir}/../../.github/scripts/" || return 1
    set_env_key LANCACHE_STATE_DIR "${dir}/state" "${dir}/.env"
    set_env_key LANCACHE_IMAGE_TAG "$(_release_tag)" "${dir}/.env"
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

# What: SOT registry and run repo -> name, ref and tags
# Why: §15: one name owner; prod pulls that registry too
# From: Issue #1683 | PR #1858
@test "image-ref builds the one registry service@digest form" {
    local root reg own repo name svc tool plats keys p s dig id
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    reg="$(_ci_block_entry_field release "" registry)" || { echo "registry: ${reg}"; return 1; }
    [ -n "${reg}" ] || { echo "no SOT release.registry"; return 1; }
    svc="$(_ci_block_keys services all)" || { echo "services: ${svc}"; return 1; }
    svc="${svc%%$'\n'*}"
    tool="$(_ci_block_keys build_toolchain all)" || { echo "build_toolchain: ${tool}"; return 1; }
    tool="${tool%%$'\n'*}"
    plats="$(_ci_block_entry_list build_matrix "" platforms)" || { echo "platforms: ${plats}"; return 1; }
    keys="$(_ci_block_keys platform_arch all)" || { echo "platform_arch: ${keys}"; return 1; }
    keys=" ${keys//$'\n'/ } "
    own="$(_val name)" repo="$(_val name)"
    name="${reg}/${own}/${repo}" dig="$(_val digest)" id="$(_val sha)"
    export GITHUB_REPOSITORY="${own^^}/${repo^}"
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
dns-input|services/dns/Dockerfile|dns
dns-domains|services/dns/cdn-domains.txt|dns
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
    run _ci_manifest_at "$(_val name)" "${nosot}"
    _expect at-ref 2 '[CI-ERROR-CORE-0106];cmd="git"' || return 1
    [ ! -e "${nosot}" ] || { echo "at-ref wrote ${nosot}"; return 1; }
    CI_MANIFEST="${nosot}" run bash "${CI_SH}" plan "${name}"
    _expect cli 2 "[CI-ERROR-CORE-0003] manifest=\"${nosot}\"" || return 1
    run _ci_block_keys "${blk}" all
    [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "loaded real SOT no longer answers: rc ${status}: ${output}"; return 1; }
}

# What: absent base field is BUILD, other base failures not
# Why: a missing field is fact; UNKNOWN stays never BUILD
# From: Issue #1683 | PR #1912
@test "impact classifies a target new at base as BUILD and any other base failure as UNKNOWN" {
    local miss other
    miss='_ci_required_field no-such-target build_type'
    other='ci_log "[CI-ERROR-CORE-0106]" "reason=\"command failed or wrote stderr\""'
    eval "_ci_identity_for() { ${miss}; return 2; }"
    run _ci_impact_classify x linux/amd64 head base "${CI_MANIFEST_SOURCE}"
    _expect field-absent 0 "[CI-ERROR-CORE-0009];[CI-INFO-IMPACT-0013];BUILD" || return 1
    [[ "${output}" != *"UNKNOWN"* ]] || { echo "absent field: ${output}"; return 1; }
    eval "_ci_identity_for() { ${other}; return 2; }"
    run _ci_impact_classify x linux/amd64 head base "${CI_MANIFEST_SOURCE}"
    _expect other-failure 0 "[CI-ERROR-CORE-0106];[CI-INFO-IMPACT-0010];UNKNOWN" || return 1
    [[ "${output}" != *"[CI-INFO-IMPACT-0013]"* ]] || { echo "other failure took the absent path: ${output}"; return 1; }
    eval "_ci_identity_for() { ${miss}; ${other}; return 2; }"
    run _ci_impact_classify x linux/amd64 head base "${CI_MANIFEST_SOURCE}"
    _expect mixed 0 "[CI-INFO-IMPACT-0010];UNKNOWN" || return 1
    _ci_identity_for() { printf 'head\n'; }
    run _ci_impact_classify x linux/amd64 head base "${CI_MANIFEST_SOURCE}"
    _expect same 0 "=NOOP" || return 1
    _ci_identity_for() { printf 'other\n'; }
    run _ci_impact_classify x linux/amd64 head base "${CI_MANIFEST_SOURCE}"
    _expect changed 0 "=BUILD" || return 1
}

# =========================================================
# SERVICE DEPENDENCIES
# =========================================================

# =========================================================
# BUILD IDENTITIES
# =========================================================

# What: real SOT ids per target and platform; edits move
# Why: NOOP needs stable ids; an edit moves only its owner
# From: Issue #1683 | PR #1858
@test "identity is keyed, deterministic, per target and platform" {
    local root svcs plats p1 p2 s a="" b="" ctx f idx a1 a2 b1 sot rc stderr=""
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    svcs="$(ci_services)" && plats="$(_ci_build_matrix_platforms)" || { echo "SOT readers failed"; return 1; }
    p1="${plats%%$'\n'*}" p2="${plats#*$'\n'}" p2="${p2%%$'\n'*}"
    [ -n "${p1}" ] && [ "${p2}" != "${p1}" ] || { echo "the SOT build matrix needs two platforms: ${plats}"; return 1; }
    a="${svcs%%[[:space:]]*}"
    ctx="$(_ci_required_field "${a}" context)" && f="$(git -C "${root}" ls-files -- "${ctx}")" \
        || { echo "${a}: no context files"; return 1; }
    f="${f%%$'\n'*}"
    for s in ${svcs}; do
        [ "${s}" != "${a}" ] || continue
        rc=0; _ci_plan_candidate "${s}" "${f}" || rc=$?
        case "${rc}" in
            0) ;;
            1) b="${s}"; break ;;
            *) echo "${s}: plan candidate rc ${rc}"; return 1 ;;
        esac
    done
    [ -n "${a}" ] && [ -n "${f}" ] && [ -n "${b}" ] || { echo "inputs: a=${a} f=${f} b=${b}"; return 1; }
    _id() { run --separate-stderr bash "${CI_SH}" identity "$@"; [ "${status}" -eq 0 ] || { echo "identity $*: rc ${status} ${stderr}"; return 1; }; }
    _id "${a}" "${p1}" || return 1
    a1="${output}"
    [[ "${a1}" =~ ^platform=${p1}\ identity=[0-9a-f]{64}$ ]] || { echo "shape: ${a1}"; return 1; }
    _id "${a}" "${p1}" && [ "${output}" = "${a1}" ] || { echo "not deterministic: ${output}"; return 1; }
    _id "${b}" "${p1}" && b1="${output}" && [ "${b1#*identity=}" != "${a1#*identity=}" ] || { echo "per target"; return 1; }
    _id "${a}" "${p2}" && a2="${output}" && [ "${a2#*identity=}" != "${a1#*identity=}" ] || { echo "per platform"; return 1; }
    _id "${a}" && [ "${#lines[@]}" -eq "$(grep -c . <<< "${plats}")" ] && [ "${lines[0]}" = "${a1}" ] && [ "${lines[1]}" = "${a2}" ] \
        || { echo "fan-out: ${output}"; return 1; }
    run bash "${CI_SH}" identity "${a}" "$(_val platform)"
    _expect foreign-platform 2 "[CI-ERROR-IDENTITY-0002] service=\"${a}\"" || return 1
    idx="$(_val path)"
    cp "$(git -C "${root}" rev-parse --path-format=absolute --git-path index)" "${idx}" \
        && GIT_INDEX_FILE="${idx}" git -C "${root}" update-index --force-remove -- "${f}" || { echo "index copy failed"; return 1; }
    GIT_INDEX_FILE="${idx}" _id "${a}" "${p1}" && [ "${output}" != "${a1}" ] || { echo "${a} did not move without ${f}"; return 1; }
    GIT_INDEX_FILE="${idx}" _id "${b}" "${p1}" && [ "${output}" = "${b1}" ] || { echo "${b} moved: ${output} vs ${b1}"; return 1; }
    sot="$(_val path)"
    sed '/^build_matrix:/,/^[a-z]/ { /^  platforms: \[/d }' "${CI_MANIFEST_SOURCE}" > "${sot}" \
        && ! cmp -s "${sot}" "${CI_MANIFEST_SOURCE}" || { echo "no build_matrix platforms line removed"; return 1; }
    CI_MANIFEST="${sot}" run bash "${CI_SH}" identity "${a}"
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
lint-buildx|buildx|ERROR: failed to build: failed to solve: lint violation found for rules: @SYM@|permanent
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
trivy-javadb|trivy|FATAL failed to download artifact from @REF@: @TXT@|transient
cas-nff|cas-push|! [rejected] HEAD -> @GREF@ (non-fast-forward)|race
cas-lock|cas-push|error: cannot lock ref '@GREF@': is at @TAG@ but expected @TAG@|race
net-overlap|validate-net|Error response from daemon: Pool overlaps with other one on this address space|collision
net-in-use|validate-net|Error response from daemon: failed to allocate gateway: Address already in use|collision
net-other|validate-net|@TXT@|permanent
oci-manifest-code|registry-read|{"errors":[{"code":"MANIFEST_UNKNOWN","message":"@TXT@"}]}|not_found
oci-name-code|registry-read|{"errors":[{"code":"NAME_UNKNOWN","message":"@TXT@"}]}|not_found
ref-not-found|registry-read|Error: @REF@: not found|not_found
gh-422|github-api|gh: Validation Failed (HTTP 422)|permanent
gh-400|github-api|gh: Problems parsing JSON (HTTP 400)|permanent
bad-ref||docker: invalid reference format.|permanent
df-parse|buildx|Dockerfile parse error line 3: unknown instruction: @SYM@|permanent
solve-parse|buildx|ERROR: failed to solve: failed to parse platform @SYM@|permanent
git-repo-gone||fatal: repository '@URL@/' not found|permanent
curl-429||curl: (22) The requested URL returned error: 429|transient
run-rate|buildx|toomanyrequests: rate limit exceeded\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
run-timeout|buildx|dial tcp: lookup @HOST@: i/o timeout\nprocess "/bin/sh -c @SYM@" did not complete successfully: exit code: 1|transient
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
@test "test-stack: rust off by default, cache errors coded" {
    local s bt rust="" sot bad
    for s in $(_ci_block_keys services); do
        bt="$(_ci_block_entry_field services "${s}" build_type)" || { echo "build_type ${s}: ${bt}"; return 1; }
        [ "${bt}" != rust ] || rust="${rust:-${s}}"
    done
    [ -n "${rust}" ] || { echo "no rust service in the SOT"; return 1; }
    _ts() { _cache_env_clean; run env "$@" bash "${CI_SH}" test-stack; }
    _ts -u CI_RUST_VALIDATION TEST_SERVICES="${rust}"
    _expect rust-default 0 "service=${rust} tested=SKIP;AG-VAL-008" || return 1
    _ts CI_RUST_VALIDATION=false TEST_SERVICES="${rust}"
    _expect rust-false 0 "service=${rust} tested=SKIP;AG-VAL-008" || return 1
    _ts CI_RUST_VALIDATION="$(_val name)" TEST_SERVICES="${rust}"
    _expect rust-not-true 0 "service=${rust} tested=SKIP;AG-VAL-008" || return 1
    _ts CI_RUST_VALIDATION=true SCCACHE_REDIS_MODE=required RUNNER_ENVIRONMENT=self-hosted TEST_SERVICES="${rust}"
    _expect self-hosted-no-redis 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-VARIABLES-0012];[CI-ERROR-TEST-0009] service=\"${rust}\"" || return 1
    [[ "${output}" != *"tested="* ]] || { echo "self-hosted-no-redis read as a result: ${output}"; return 1; }
    _ts CI_RUST_VALIDATION=true SCCACHE_REDIS_MODE=required RUNNER_ENVIRONMENT=github-hosted TEST_SERVICES="${rust}"
    _expect hosted-no-cache 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-CACHE-0007];[CI-ERROR-TEST-0009] service=\"${rust}\"" || return 1
    [[ "${output}" != *"tested="* ]] || { echo "hosted-no-cache read as a result: ${output}"; return 1; }
    sot="${BATS_TEST_TMPDIR}/sot-edit.yml" bad="$(_val name)"
    sed "/^  ${rust}:\$/,/^  [a-z0-9-]*:\$/ { /^    crates:/d }" "${CI_MANIFEST_SOURCE}" > "${sot}" \
        && ! cmp -s "${sot}" "${CI_MANIFEST_SOURCE}" || { echo "no crate line of ${rust} removed"; return 1; }
    _ts CI_MANIFEST="${sot}" CI_RUST_VALIDATION=true TEST_SERVICES="${rust}"
    _expect no-crate 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-CORE-0009] target=\"${rust}\" field=\"crates\"" || return 1
    sed "/^  ${rust}:\$/,/^  [a-z0-9-]*:\$/ s/^    build_type: rust\$/    build_type: ${bad}/" "${CI_MANIFEST_SOURCE}" > "${sot}" \
        && ! cmp -s "${sot}" "${CI_MANIFEST_SOURCE}" || { echo "no build_type of ${rust} changed"; return 1; }
    _ts CI_MANIFEST="${sot}" TEST_SERVICES="${rust}"
    _expect unknown-type 2 "[CI-ERROR-TEST-0003] service=\"${rust}\";[CI-ERROR-TEST-0004] service=\"${rust}\" build_type=\"${bad}\"" || return 1
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

# What: temp root off tmpfs, made; uncreatable dirs coded
# Why: bare mktemp in tools must land on disk, not RAM
# From: Issue #1683 | PR #1858
@test "temp dirs: tmpfs refused, made on disk, else coded" {
    local d long lnk rel bb bbd
    d="${BATS_TEST_TMPDIR}/$(_val name)/$(_val name)" long="${BATS_TEST_TMPDIR}/$(printf '%0300d' 0)"
    lnk="${BATS_TEST_TMPDIR}/$(_val name)" rel="$(_val name)/$(_val name)" bb="${BATS_TEST_TMPDIR}/$(_val name)"
    bbd="${BATS_TEST_TMPDIR}/$(_val name)/$(_val name)"
    ln -s /tmp "${lnk}" || return 1
    CI_TMPDIR="${lnk}/$(_val name)" run _ci_tmp_init
    _expect symlink 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="${BATS_TEST_TMPDIR}/$(_val name)$(printf '/..%.0s' {1..40})/tmp/$(_val name)" run _ci_tmp_init
    _expect escape 2 "[CI-ERROR-CORE-0142]" || return 1
    CI_TMPDIR="${rel}" run eval 'cd "${BATS_TEST_TMPDIR}" && _ci_tmp_init && echo "t=${TMPDIR}"'
    _expect relative 0 "t=$(cd "${BATS_TEST_TMPDIR}" && pwd -P)/${rel}" || return 1
    mkdir -p "${bb}" && ln -s "$(command -v busybox)" "${bb}/realpath" || { echo "busybox: no busybox"; return 1; }
    CI_TMPDIR="${bbd}" PATH="${bb}:${PATH}" run eval '_ci_tmp_init && echo "t=${TMPDIR}"'
    _expect busybox 0 "t=${bbd}" || return 1
    [[ "$(realpath -m -- "${BATS_TEST_TMPDIR}")" == /var/tmp/* ]] || { echo "bats temp dir not under /var/tmp: ${BATS_TEST_TMPDIR}"; return 1; }
    CI_TMPDIR=/tmp run _ci_tmp_init
    _expect tmpfs 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="/var/tmp/../../tmp/$(_val name)" run _ci_tmp_init
    _expect dotdot 2 "[CI-ERROR-CORE-0006]" || return 1
    CI_TMPDIR="${d}" run eval '_ci_tmp_init && echo "t=${TMPDIR}"'
    _expect created 0 "t=${d}" || return 1
    [ -d "${d}" ] || { echo "not created: ${d}"; return 1; }
    CI_TMPDIR="${long}" run _ci_tmp_init
    _expect uncreatable 2 "[CI-ERROR-CORE-0111] dir=\"${long}\"" || return 1
}

# What: each ci.sh stage declares every SOT stage variable
# Why: a stage has no SOT; a missing ARG starves ci.sh
# From: Issue #1683 | PR #1858
@test "dockerfile stage variables: every ci.sh stage declares them" {
    local root t="${BATS_TEST_TMPDIR}/repo" out svc df var
    local -a tg
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run _ci_check_dockerfile_stage_variables "${root}"
    _expect real 0 "dockerfile-stage-variables=clean" || return 1
    out="$(ci_build_targets)" || return 1
    mapfile -t tg <<< "${out}"
    var="$(_ci_block_entry_list stage_variables "" ci_sh | awk 'NR == 1')"
    [ "${#tg[@]}" -gt 0 ] && [ -n "${var}" ] || { echo "inputs: ${#tg[@]} targets, var '${var}'"; return 1; }
    svc="${tg[$(( SRANDOM % ${#tg[@]} ))]}"
    _checkout_copy "${root}" "${t}" || return 1
    df="$(_ci_service_path "${svc}" Dockerfile "${t}")" || return 1
    grep -v -x "ARG ${var}" "${df}" > "${df}.new" && mv "${df}.new" "${df}" || return 1
    run _ci_check_dockerfile_stage_variables "${t}"
    _expect dropped 1 "[CI-ERROR-CHECK-0169];${svc}: Dockerfile stage;without ARG ${var}" || return 1
}

# What: a COPY source outside context and edges fails
# Why: an uncovered source keeps a stale image identity
# From: Issue #1683 | PR #1912
@test "dockerfile context edges: every COPY source feeds the identity" {
    local root t="${BATS_TEST_TMPDIR}/repo" out svc df src
    local -a tg
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run _ci_check_dockerfile_context_edges "${root}"
    _expect real 0 "dockerfile-context-edges=clean" || return 1
    out="$(ci_build_targets)" || return 1
    mapfile -t tg <<< "${out}"
    [ "${#tg[@]}" -gt 0 ] || { echo "inputs: no build targets"; return 1; }
    svc="${tg[$(( SRANDOM % ${#tg[@]} ))]}" src="$(_val name)/$(_val name)"
    _checkout_copy "${root}" "${t}" || return 1
    df="$(_ci_service_path "${svc}" Dockerfile "${t}")" || return 1
    printf 'COPY --chown=0:0 %s \\\n    /x\n' "${src}" >> "${df}" || return 1
    run _ci_check_dockerfile_context_edges "${t}"
    _expect uncovered 1 "[CI-ERROR-CHECK-0175];${svc}: ;copies ${src}, outside" || return 1
}

# What: container prefix is the compose name in any case
# Why: AG-INT-002: a changed guard needs a pass and a fail
# From: Issue #1683 | PR #1912
@test "naming consistency: container prefix is the compose project name" {
    local root t="${BATS_TEST_TMPDIR}/repo" dep cfg p new case target sedexpr want
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run _ci_check_naming_consistency "${root}"
    _expect real 0 "naming-consistency=clean" || return 1
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 1
    cfg="$(_ci_compose_json "${root}/${dep}")" || return 1
    p="$(jq -r '.services | to_entries[0] | .value.container_name[0:-(.key | length) - 1]' <<< "${cfg}")" || return 1
    new="$(_val name)"
    [ -n "${p}" ] || { echo "inputs: no container prefix in ${dep}"; return 1; }
    while IFS='|' read -r case target sedexpr want; do
        rm -rf "${t}" && _checkout_copy "${root}" "${t}" || return 1
        [ "${target}" = sot ] && target="${CI_MANIFEST_REL}" || target="${dep}"
        sed -i -E "${sedexpr}" "${t}/${target}" || return 1
        CI_MANIFEST="${t}/${CI_MANIFEST_REL}" run _ci_check_naming_consistency "${t}"
        if [ "${case}" = case-only ]; then
            _expect "${case}" 0 "naming-consistency=clean" || return 1
        else
            _expect "${case}" 1 "[CI-ERROR-CHECK-0096];${want}" || return 1
        fi
    done <<ROWS
case-only|sot|s/(CONTAINER_NAME_PREFIX)=${p}\$/\\1=${p^^}/|-
all-renamed|sot|s/(CONTAINER_NAME_PREFIX)=${p}\$/\\1=${new}/|container prefix ${new} is not the project name
one-renamed|sot|0,/(CONTAINER_NAME_[A-Z]+)=@CONTAINER_NAME_PREFIX@-/s//\\1=${new}-/|container prefixes differ
no-project|compose|/^name:/d|is not the project name
ROWS
}

# What: a state key counts only as a whole word
# Why: AG-INT-002: a key_OLD line must not satisfy the key
# From: Issue #1683 | PR #1912
@test "prod state wiring: a renamed state key is missing, not matched" {
    local root t="${BATS_TEST_TMPDIR}/repo" doc keys key
    local -a all
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run _ci_check_prod_state_wiring "${root}"
    _expect real 0 "prod-state-wiring=clean" || return 1
    doc="$(_ci_variable CI_BACKUP_RESTORE_DOC)" || return 1
    keys="$(bash -c 'set -euo pipefail; . "$1"; prod_state_keys' _ "${root}/setup.sh")" || return 1
    mapfile -t all <<< "${keys}"
    [ "${#all[@]}" -gt 0 ] && [ -n "${all[0]}" ] || { echo "inputs: no state key"; return 1; }
    key="${all[$(( SRANDOM % ${#all[@]} ))]}"
    rm -rf "${t}" && _checkout_copy "${root}" "${t}" || return 1
    sed -i -E "s/(^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$)/\\1${key}_OLD\\2/g" "${t}/${doc}" || return 1
    run _ci_check_prod_state_wiring "${t}"
    _expect doc 1 "[CI-ERROR-CHECK-0100];${doc} does not mention ${key}" || return 1
}

# What: each state key defaults under LANCACHE_STATE_DIR
# Why: AG-SETUP-001: a literal host dir would leave the root
# From: Issue #1683 | PR #1912
@test "prod state wiring: a state key off the state root fails" {
    local root t="${BATS_TEST_TMPDIR}/repo" dep keys key
    local -a all
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    dep="$(_ci_variable CI_COMPOSE_FILE)" || return 1
    keys="$(bash -c 'set -euo pipefail; . "$1"; prod_state_keys' _ "${root}/setup.sh")" || return 1
    mapfile -t all <<< "${keys}"
    [ "${#all[@]}" -gt 0 ] && [ -n "${all[0]}" ] || { echo "inputs: no state key"; return 1; }
    key="${all[$(( SRANDOM % ${#all[@]} ))]}"
    rm -rf "${t}" && _checkout_copy "${root}" "${t}" || return 1
    sed -i -E "s/\\$\\{${key}:-\\$\\{LANCACHE_STATE_DIR:\\?[^}]*\\}/\${${key}:-\/srv\/literal/" "${t}/${dep}" || return 1
    run _ci_check_prod_state_wiring "${t}"
    _expect off-root 1 "[CI-ERROR-CHECK-0100];${dep} has a mount default off LANCACHE_STATE_DIR;\${${key}:-/srv/literal" || return 1
}

# What: the fixture carries the SOT state root, a host path.
# Why: validate exports its per-run root after it.
# From: Issue #1683 | PR #1912
@test "validate exports its per-run state root after the fixture env" {
    local fx fixture_line root_line
    fx="$(_ci_validation_env)" || return 1
    grep -qx 'LANCACHE_STATE_DIR=.*' <<< "${fx}" || { echo "fixture lost the state root: ${fx}"; return 1; }
    fixture_line="$(grep -n -m 1 -F -e 'export "${venv[@]}"' "${CI_SH}")"; fixture_line="${fixture_line%%:*}"
    root_line="$(grep -n -m 1 -F -e 'export LANCACHE_STATE_DIR="${shared}/state/${project}"' "${CI_SH}")"; root_line="${root_line%%:*}"
    [ -n "${fixture_line}" ] && [ -n "${root_line}" ] && [ "${root_line}" -gt "${fixture_line}" ] \
        || { echo "root export line ${root_line:-none} is not after fixture export line ${fixture_line:-none}"; return 1; }
}

# What: the validate .env.local helper writes, 600, or fails
# Why: dns and kea rollback share it; no .env exists
# From: Issue #836 | PR #1912
@test "validate env-local helper: mode 600, content kept, existing or unwritable refused" {
    local d="${BATS_TEST_TMPDIR}/inst" f
    f="${d}/.env.local"
    mkdir -p "${d}" && _ci_validate_env_local "${d}" "" || return 1
    [ -f "${f}" ] && [ ! -s "${f}" ] && [ "$(stat -c %a "${f}")" = 600 ] || { echo "empty file: $(stat -c '%a %s' "${f}")"; return 1; }
    run _ci_validate_env_local "${d}" "A=1"
    _expect existing 2 "[CI-ERROR-VALIDATE-0113]" || return 1
    [ ! -s "${f}" ] || { echo "an existing file was overwritten"; return 1; }
    rm -f "${f}" && _ci_validate_env_local "${d}" "KEA_CTRL_TOKEN=x" || return 1
    [ "$(cat "${f}")" = "KEA_CTRL_TOKEN=x" ] && [ "$(stat -c %a "${f}")" = 600 ] || { echo "content: $(cat "${f}")"; return 1; }
    run _ci_validate_env_local "${d}/missing" ""
    _expect unwritable 2 "[CI-ERROR-VALIDATE-0093]" || return 1
}

# What: proxy constant reads Rust const forms or fails
# Why: AG-VAL-036: visibility and spacing are valid Rust
# From: Issue #1683 | PR #1912
@test "proxy constant: Rust const forms read, other values fail closed" {
    local root t="${BATS_TEST_TMPDIR}/repo" src want case line rc exp
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run _ci_proxy_constant NGINX_STREAM_TARGETS "${root}"
    [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "real: rc ${status}: ${output}"; return 1; }
    want="${output}"
    while IFS='|' read -r case line rc exp; do
        rm -rf "${t}" && _checkout_copy "${root}" "${t}" || return 1
        src="$(_ci_service_path services src/main.rs "${t}")" || return 1
        awk -v l="${line}" '/^const NGINX_STREAM_TARGETS:/ { print l; next } { print }' "${src}" > "${src}.new" \
            && mv "${src}.new" "${src}" || return 1
        run _ci_proxy_constant NGINX_STREAM_TARGETS "${t}"
        [ "${exp}" != @WANT@ ] || exp="=${want}"
        _expect "${case}" "${rc}" "${exp}" || return 1
    done <<ROWS
visibility|    pub(crate) const NGINX_STREAM_TARGETS : &'static str = "stream.d/00-stream-targets.conf"; // targets|0|@WANT@
macro|const NGINX_STREAM_TARGETS: &str = concat!("stream.d", "/00-stream-targets.conf");|2|[CI-ERROR-CORE-0129]
ROWS
}

# What: https.conf holds no literal listen of its own
# Why: the watchdog renders the ports from the SOT
# From: Issue #1683 | PR #1912
@test "check proxy-nginx-policy: https.conf listens come from the generated file" {
    local root t="${BATS_TEST_TMPDIR}/repo"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    run bash "${CI_SH}" check proxy-nginx-policy
    _expect real 0 "proxy-nginx-policy=clean" || return 1
    _checkout_copy "${root}" "${t}" || return 1
    sed -i -E "s/^([[:space:]]*)include[[:space:]]+[^;]*NGINX_HTTPS_LISTEN_FILE[^;]*;/\\1listen $(_val ipv4):$(_val port) ssl;/" "${t}/services/proxy/conf.d/https.conf" || return 1
    run bash "${CI_SH}" check proxy-nginx-policy "${t}"
    _expect moved 1 "[CI-ERROR-CHECK-0151];no include of;literal listen" || return 1
}

# What: the Kea ui run gets the bare host; the ui adds more
# Why: scheme and port came twice: http://ip:8000:8000
# From: Issue #1683 | PR #1912
@test "kea rollback: the ui run gets DHCP_API_HOST bare" {
    local ip port log="${BATS_TEST_TMPDIR}/runs.log"
    ip="$(_val ipv4)" port="$(_val port)"
    _ci_validate_kea_agent() { printf '%s\n' "${port}"; }
    _ci_validate_cid_ip() { printf '%s\n' "${ip}"; }
    _ci_run() { shift 2; printf '%s\n' "$*" >> "${log}"; }
    _ci_validate_kea_round_trip() { return 0; }
    _ci_validate_rm_run() { return 0; }
    run _ci_validate_kea_rollback "$(_val name)" "$(_val name)" "$(_val name)"
    _expect real 0 "-" || return 1
    grep -qF -- "DHCP_API_HOST=${ip} " "${log}" || { echo "ui run: $(cat "${log}")"; return 1; }
    ! grep -qF -- "DHCP_API_HOST=${ip}:" "${log}" || { echo "port in the host: $(cat "${log}")"; return 1; }
}

# What: image-setup builds the SOT accounts and directories
# Why: the Dockerfiles run no inline RUN logic (AG-CI-023)
# From: Issue #1683 | PR #1912
@test "image-setup: IMAGE_SETUP steps run in order, a bad step stops coded" {
    local t="${BATS_TEST_TMPDIR}" bin d grp usr uid c
    bin="${t}/bin" d="${t}/$(_val name)" grp="$(_val name)" usr="$(_val name)" uid="$(_val int 2000 60000)"
    mkdir -p "${bin}" || return 1
    for c in addgroup adduser; do
        printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "${c}" "${t}" > "${bin}/${c}" && chmod +x "${bin}/${c}" || return 1
    done
    PATH="${bin}:${PATH}" IMAGE_SETUP="group=${grp}:${uid} member=${usr}:${grp} user=${grp}:${uid}:${grp} dir=${d}/a dir=${d}/b:root" \
        run bash "${CI_SH}" image-setup
    _expect steps 0 "image-setup=ok steps=5" || return 1
    [ -d "${d}/a" ] && [ -d "${d}/b" ] || { echo "dirs not made"; return 1; }
    [ "$(cat "${t}/calls")" = "$(printf 'addgroup -g %s %s\naddgroup %s %s\nadduser -D -H -u %s -G %s -s /sbin/nologin %s' "${uid}" "${grp}" "${usr}" "${grp}" "${uid}" "${grp}" "${grp}")" ] \
        || { echo "calls: $(cat "${t}/calls")"; return 1; }
    IMAGE_SETUP="dir=${d}/c ${grp}=x" run bash "${CI_SH}" image-setup
    _expect bad-kind 2 "[CI-ERROR-IMGSETUP-0001];token=\"${grp}=x\"" || return 1
}

# What: a service's setup tokens carry SOT values only
# Why: the build-arg must not leave an unresolved @KEY@
# From: Issue #1683 | PR #1912
@test "service setup tokens: @KEY@ resolves from the SOT" {
    local svc tokens want
    for svc in $(ci_services); do
        tokens="$(_ci_service_setup "${svc}")" || { echo "${svc}: rc $?"; return 1; }
        [[ "${tokens}" != *@* ]] || { echo "${svc}: unresolved: ${tokens}"; return 1; }
    done
    want="dir=$(_ci_runtime_default NGINX_DIR)/ssl/ca"
    [[ "$(_ci_service_setup proxy)" == "${want} "* ]] || { echo "proxy: $(_ci_service_setup proxy)"; return 1; }
    want="group=$(_ci_runtime_default LOG_READER_GROUP):$(_ci_required_field runtime gid block)"
    [[ "$(_ci_service_setup ui)" == "${want} "* ]] || { echo "ui: $(_ci_service_setup ui)"; return 1; }
}

# What: stubs let cargo load every member; undeclared stops
# Why: rust builder stages copy only the members' manifests
# From: Issue #1683 | PR #1905
@test "rust member stubs: every member loads, an undeclared one stops" {
    local root d m out pick
    local -a ms
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" d="$(_val path)"
    out="$(cd "${root}" && _ci_cargo_members Cargo.toml)" || return 1
    mapfile -t ms <<< "${out}"
    [ -n "${ms[0]}" ] || { echo "no workspace members"; return 1; }
    mkdir -p "${d}" && cp "${root}/Cargo.toml" "${d}/" || return 1
    for m in "${ms[@]}"; do mkdir -p "${d}/${m}" && cp "${root}/${m}/Cargo.toml" "${d}/${m}/" || return 1; done
    run bash -c 'cd "$1" && source "$2" && _ci_rust_member_stubs > stubs.txt && cargo metadata --no-deps --offline --format-version 1 > meta.json' _ "${d}" "${CI_SH}"
    [ "${status}" -eq 0 ] && [ "$(jq '.workspace_members | length' "${d}/meta.json")" -eq "${#ms[@]}" ] \
        || { echo "load: rc ${status}: ${output}"; return 1; }
    pick="${ms[$(( SRANDOM % ${#ms[@]} ))]}"
    awk '/^\[\[bin\]\]|^\[lib\]/ { s = 1; next } /^\[/ { s = 0 } !s' "${d}/${pick}/Cargo.toml" > "${d}/manifest.new" \
        && mv "${d}/manifest.new" "${d}/${pick}/Cargo.toml" || return 1
    run bash -c 'cd "$1" && source "$2" && _ci_rust_member_stubs' _ "${d}" "${CI_SH}"
    _expect undeclared 2 "[CI-ERROR-RUSTBUILD-0049] member=\"${pick}\"" || return 1
}

# What: the distcc wrapper runs distcc without its own dir
# Why: distcc's local cc -E found the wrapper and recursed
# From: Issue #1683 | PR #1912
@test "rust distcc wrapper: distcc runs without the masq dir on PATH" {
    local d masq log drv
    local -a out
    d="$(_val path)" drv="$(_val name)"
    masq="${d}/masq" log="${d}/argv"
    mkdir -p "${masq}" || return 1
    printf '#!/bin/sh\nprintf "%%s\\n" "$PATH" "$*" > "%s"\n' "${log}" > "${d}/distcc" && chmod +x "${d}/distcc" || return 1
    _ci_rust_distcc_wrapper "${d}/distcc" "${d}/wrapper" "${masq}" "${drv}=/bin/true" > "${d}/wrapper" \
        && chmod +x "${d}/wrapper" && ln -s "${d}/wrapper" "${masq}/${drv}" || return 1
    run env PATH="${masq}:${PATH}" "${drv}" -c x.c
    [ "${status}" -eq 0 ] || { echo "wrapper: rc ${status}: ${output}"; return 1; }
    mapfile -t out < "${log}"
    [[ ":${out[0]}:" != *":${masq}:"* ]] || { echo "masq dir still on PATH: ${out[0]}"; return 1; }
    [ "${out[1]}" = "${drv} -c x.c" ] || { echo "argv: ${out[1]}"; return 1; }
}

# What: the cargo cascade per outcome, under ci.sh options
# Why: AG-VAL-030: PIPESTATUS and fail-closed need a run
# From: Issue #1683 | PR #1912
@test "rust cargo cascade: rc, fallback and required sccache per row" {
    local d case mode plan tee_rc rc want calls n
    d="$(_val path)"
    mkdir -p "${d}/bin" || return 1
    printf '%s\n' '#!/bin/sh' 'n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT"' \
        'step=$(printf "%s" "$PLAN" | cut -d, -f"$n")' 'printf "%s\n" "${step#*:}"; exit "${step%%:*}"' > "${d}/bin/cargo" \
        && chmod +x "${d}/bin/cargo" || return 1
    while IFS='|' read -r case mode plan tee_rc rc want calls; do
        rm -f "${d}/cnt" "${d}/bin/tee"
        if [ "${tee_rc}" != 0 ]; then
            printf '#!/bin/sh\ncat > /dev/null\nexit %s\n' "${tee_rc}" > "${d}/bin/tee" && chmod +x "${d}/bin/tee" || return 1
        fi
        run env PATH="${d}/bin:${PATH}" CNT="${d}/cnt" PLAN="${plan}" bash -c \
            'source "$1"; CI_TMPDIR="$2" _CI_SCCACHE_MODE="$3" RUSTC_WRAPPER=sccache; _ci_rust_cargo_build c t 1; echo "wrapper=${RUSTC_WRAPPER:-unset}"' \
            _ "${CI_SH}" "${d}" "${mode}"
        _expect "${case}" "${rc}" "${want}" || return 1
        n="$(cat "${d}/cnt")"
        [ "${n}" = "${calls}" ] || { echo "${case}: cargo ran ${n} times, want ${calls}"; return 1; }
    done <<ROWS
ok|required|0:built|0|0|built;wrapper=sccache|1
real-error|optional|101:error[E0308]: mismatched types|0|101|[CI-ERROR-RUSTBUILD-0010] rc=101|1
required|required|1:sccache: error: server gone,0:built|0|2|[CI-ERROR-RUSTBUILD-0053] rc=1|1
optional|optional|1:sccache: error: server gone,0:built|0|0|[CI-WARN-RUSTBUILD-0013];built;[CI-INFO-RUSTBUILD-0009];wrapper=unset|2
tee-lost|optional|0:built|3|2|[CI-ERROR-RUSTBUILD-0052] rc=3 cargo_rc=0|1
ROWS
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
    local -A V=(["@PROXY@"]="$(_val url)" ["@PROXYS@"]="$(_val url)" ["@EXCL@"]="$(_val host)" ["@CA@"]="$(_val name)")
    while IFS='|' read -r case envs probe rc want; do
        envs="$(_fill "${envs}")" want="$(_fill "${want}")"
        read -r -a ev <<< "${envs}"
        run env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy \
            "${ev[@]}" CI_TMPDIR="${BATS_TEST_TMPDIR}" \
            bash -c 'source "$1"; _ci_proxy_init || exit; eval "$2"' _ "${CI_SH}" "${P[${probe}]}"
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
hosted-off|RUNNER_ENVIRONMENT=github-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@|names|0|[CI-INFO-CORE-0113] proxy=off runner="github-hosted" http_set=yes;names=0
self-hosted|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_EXCLUSION=@EXCL@|env|0|[CI-INFO-CORE-0007];[CI-INFO-CORE-0114];h=@PROXY@ n=@EXCL@;HTTP_PROXY HTTPS_PROXY
self-hosted-no-http|RUNNER_ENVIRONMENT=self-hosted|names|0|[CI-INFO-CORE-0113] proxy=off runner="self-hosted" http_set=no;names=0
https-own|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_HTTPS=@PROXYS@|env|0|[CI-INFO-CORE-0007];h=@PROXYS@ n=;HTTP_PROXY HTTPS_PROXY
ca-bundle|RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=@PROXY@ PROJECT_SELFHOSTED_PROXY_CA=@CA@|bundle|0|[CI-INFO-CORE-0115];system-certs;@CA@;same;600
CASES
}

# =========================================================
# CACHE FALLBACK
# =========================================================

# =========================================================
# REGISTRY / PUBLISH / READBACK
# =========================================================

# What: GHCR login required; Docker Hub only as a pair
# Why: anonymous pulls hit limits; a half pair is a bug
# From: Issue #1683 | PR #1858
@test "registry logins: GHCR required, Docker Hub only as a pair" {
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
next-unsupported|v@X@.@Y@|2|[CI-ERROR-RELEASE-0015] tag="v@X@.@Y@"
CASES
}

# =========================================================
# GC
# =========================================================

# =========================================================
# VALIDATION
# =========================================================

# What: each first-party service pinned; a gap fails
# Why: §48: validate runs the candidate, not a mutable tag
# From: Issue #1683 | PR #1858
@test "validate pin override: every first-party service pinned, gap fails" {
    local root cfg svcs cand="" s dig out k ks miss extra first
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _export_validation_env || return 1
    cfg="$(docker compose -f "${root}/$(_ci_variable CI_COMPOSE_FILE)" config --format json)" && svcs="$(ci_services)" \
        || { echo "inputs: compose config or services"; return 1; }
    first="$(jq -r --arg s "$(awk 'NR == 1' <<< "${svcs}")" '.services[$s].image // empty' <<< "${cfg}")"
    first="${first#*/}" first="${first%/*}"
    [ -n "${first}" ] || { echo "no compose image for the first SOT service"; return 1; }
    export GITHUB_REPOSITORY="${first}"
    dig="$(_val digest)"
    while IFS= read -r s; do cand+="${s}=${dig}"$'\n'; done <<< "${svcs}"
    run _ci_validate_pin_override "${cand}"
    _expect pin 0 "services:" || return 1
    out="${output}"
    [ -n "$(grep '^    image: ' <<< "${out}")" ] || { echo "nothing pinned: ${out}"; return 1; }
    [ -z "$(grep '^    image: ' <<< "${out}" | grep -v "@${dig}\$")" ] || { echo "pin without the digest: ${out}"; return 1; }
    ks="$(jq -r --arg p "/${first}/" '.services | to_entries[] | select((.value.image // "") | contains($p)) | .key' <<< "${cfg}")"
    [ -n "${ks}" ] || { echo "no first-party compose service"; return 1; }
    while IFS= read -r k; do
        grep -qx "  ${k}:" <<< "${out}" || { echo "first-party ${k} not pinned: ${out}"; return 1; }
    done <<< "${ks}"
    miss="$(grep -m1 '^    image: ' <<< "${out}")" && miss="${miss%@*}" && miss="${miss##*/}"
    run _ci_validate_pin_override "$(grep -v "^${miss}=" <<< "${cand}")"
    _expect gap 2 "[CI-ERROR-VALIDATE-0007]" || return 1
    extra="$(_val name)"
    run _ci_validate_pin_override "${cand}${extra}=${dig}"
    _expect unpinned 0 "[CI-WARN-VALIDATE-0008] unpinned=\"${extra}\"" || return 1
}

# What: per SOT kind a fresh secret; setup.sh lists none
# Why: PowerDNS rejects a non-base64 TSIG key: no AXFR
# From: Issue #1683 | PR #1858
@test "validation env: secrets generated per SOT kind, setup.sh lists none, NATS url set" {
    local root env fx kind kinds k v n LC_ALL=C
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env="$(_ci_validation_env)" && fx="$(_ci_block_entry_list validation "" compose_validation_env)" \
        || { echo "validation env: ${env}"; return 1; }
    for kind in hex32 base64_32 secondary_hex32; do
        kinds="$(_ci_required_field runtime "secrets_${kind}" block)" || { echo "${kind}: ${kinds}"; return 1; }
        [ -n "${kinds}" ] || { echo "no SOT ${kind} secret"; return 1; }
        for k in ${kinds}; do
            ! grep -q "^${k}\\(=\\|\$\\)" <<< "${fx}" || { echo "${k}: fixed value in the SOT validation env"; return 1; }
            v="$(sed -n "s/^${k}=//p" <<< "${env}")"
            case "${kind}" in
                hex32|secondary_hex32) [[ "${v}" =~ ^[0-9a-f]{64}$ ]] || { echo "${k}: ${#v} chars, not 64 hex"; return 1; } ;;
                base64_32)
                    n="$(set -o pipefail; base64 -d <<< "${v}" | wc -c)" && [ "${n}" -eq 32 ] \
                        || { echo "${k}: ${#v} chars decode to ${n:-an error}"; return 1; }
                    ;;
            esac
        done
    done
    ! grep -Eq '(ensure_secret_env_key|get_or_generate_secret) [A-Z][A-Z_0-9]+ ' "${root}/setup.sh" \
        || { echo "setup.sh names a secret key: $(grep -En '(ensure_secret_env_key|get_or_generate_secret) [A-Z][A-Z_0-9]+ ' "${root}/setup.sh")"; return 1; }
    grep -Eq '^NATS_ADVERTISE_URL=[a-z]+://[^[:space:]]+$' <<< "${env}" \
        || { echo "no NATS_ADVERTISE_URL: $(grep '^NATS_' <<< "${env}")"; return 1; }
}

# What: one flock per slot; a second holder is refused
# Why: two runs on one host must never share a slot
# From: Issue #1683 | PR #1858
@test "validate slot lock refuses a second holder of one slot" {
    local first s
    export TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_validate_shared_dir() { printf '%s' "${BATS_TEST_TMPDIR}"; }
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
    _export_validation_env || return 1
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

# What: each dns side maps to exactly one compose udp port
# Why: one dns container serves both sides on two ports
# From: Issue #1683 | PR #1912
@test "validate dns port: real compose splits the sides, drift fails coded" {
    local http https a b pa pb row env ports side rc want
    _export_validation_env || return 1
    run _ci_validate_dns_port IP_HTTP
    _expect real-http 0 - || return 1
    http="${output}"
    run _ci_validate_dns_port IP_HTTPS
    _expect real-https 0 - || return 1
    https="${output}"
    [[ "${http}" =~ ^[0-9]+$ && "${https}" =~ ^[0-9]+$ && "${http}" != "${https}" ]] \
        || { echo "real sides: '${http}' '${https}'"; return 1; }
    a="192.0.2.$(_val int 1 99)" b="192.0.2.$(_val int 100 199)"
    pa="$(_val port)" pb="$(_val port)"
    _ci_validate_config_json() { printf '%s\n' "${CFG}"; }
    while IFS='#' read -r row env ports side rc want; do
        env="${env//@A@/${a}}" ports="${ports//@A@/${a}}" ports="${ports//@B@/${b}}"
        ports="${ports//@PA@/${pa}}" ports="${ports//@PB@/${pb}}" want="${want//@PA@/${pa}}"
        CFG="$(jq -nc --argjson e "${env}" --argjson p "${ports}" '{services: {dns: {environment: $e, ports: $p}}}')" \
            || { echo "${row}: fixture"; return 1; }
        run _ci_validate_dns_port "${side}"
        _expect "${row}" "${rc}" "${want}" || return 1
    done <<'CASES'
match#{"IP_HTTP":"@A@"}#[{"host_ip":"@A@","published":"53","protocol":"udp","target":@PA@},{"host_ip":"@B@","published":"53","protocol":"udp","target":@PB@}]#IP_HTTP#0#=@PA@
tcp-only#{"IP_HTTP":"@A@"}#[{"host_ip":"@A@","published":"53","protocol":"tcp","target":@PA@}]#IP_HTTP#2#[CI-ERROR-VALIDATE-0116];side="IP_HTTP"
other-ip#{"IP_HTTP":"@A@"}#[{"host_ip":"@B@","published":"53","protocol":"udp","target":@PB@}]#IP_HTTP#2#[CI-ERROR-VALIDATE-0116]
other-published#{"IP_HTTP":"@A@"}#[{"host_ip":"@A@","published":"5300","protocol":"udp","target":@PA@}]#IP_HTTP#2#[CI-ERROR-VALIDATE-0116]
two-targets#{"IP_HTTP":"@A@"}#[{"host_ip":"@A@","published":"53","protocol":"udp","target":@PA@},{"host_ip":"@A@","published":"53","protocol":"udp","target":@PB@}]#IP_HTTP#2#[CI-ERROR-VALIDATE-0116]
no-env#{}#[{"host_ip":"","published":"53","protocol":"udp","target":@PA@}]#IP_HTTPS#2#[CI-ERROR-VALIDATE-0116];side="IP_HTTPS"
CASES
}

# What: dig hits each side's port; rc and answers coded
# Why: a dig failure was dropped; a same answer is no split
# From: Issue #1683 | PR #1912
@test "validate dns: both sides queried on their port, failures coded" {
    local row a1 a2 r1 e1 rc want
    IP="198.51.100.$(_val int 1 254)"
    _ci_validate_container_ip() { [ "$2" = dns ] && printf '%s' "${IP}"; }
    _ci_validate_dns_port() { case "$1" in IP_HTTP) echo 11 ;; IP_HTTPS) echo 12 ;; *) return 2 ;; esac; }
    # What: dig stub answering by -p; @IP is required
    # Why: proves the side port and the dns IP reach dig
    # From: Issue #1683 | PR #1912
    dig() {
        local a p="" prev="" at=""
        for a in "$@"; do
            [ "${prev}" = -p ] && p="${a}"
            [ "${a}" = "@${IP}" ] && at=1
            prev="${a}"
        done
        [ -n "${at}" ] || { echo "dig without @${IP}: $*" >&2; return 64; }
        case "${p}" in
            11) [ -z "${E1}" ] || echo "${E1}" >&2; [ -z "${A1}" ] || printf '%s\n' "${A1}"; return "${R1}" ;;
            12) [ -z "${A2}" ] || printf '%s\n' "${A2}"; return 0 ;;
            *) echo "dig without a side port: $*" >&2; return 64 ;;
        esac
    }
    while IFS='#' read -r row a1 a2 r1 e1 rc want; do
        A1="${a1}" A2="${a2}" R1="${r1}" E1="${e1}"
        run _ci_validate_dns x
        _expect "${row}" "${rc}" "${want}" || return 1
    done <<'CASES'
split#192.0.2.1#192.0.2.2#0##0#=
same#192.0.2.1#192.0.2.1#0##1#[CI-ERROR-VALIDATE-0021]
empty-https#192.0.2.1##0##1#[CI-ERROR-VALIDATE-0011];side="IP_HTTPS"
dig-fail#192.0.2.1#192.0.2.2#9##2#[CI-ERROR-VALIDATE-0117];side="IP_HTTP";rc=9
dig-warn#192.0.2.1#192.0.2.2#0#;; warning#2#[CI-ERROR-VALIDATE-0117];warning
CASES
    IP=""
    run _ci_validate_dns x
    _expect no-ip 2 "[CI-ERROR-VALIDATE-0010]" || return 1
}

# What: the resolve poll asks the given side's port
# Why: the https side is its own recursor, not the http one
# From: Issue #1683 | PR #1912
@test "validate dns resolves: polls the side's port, a miss fails coded" {
    IP="198.51.100.$(_val int 1 254)"
    _ci_validate_container_ip() { [ "$2" = dns ] && printf '%s' "${IP}"; }
    _ci_validate_dns_port() { case "$1" in IP_HTTPS) echo 12 ;; *) echo 11 ;; esac; }
    _ci_validate_service_evidence() { printf 'evidence %s\n' "$2"; }
    dig() { [[ " $* " == *" -p 12 @${IP} "* ]] && printf '192.0.2.7\n'; return 0; }
    run _ci_validate_dns_resolves x IP_HTTPS probe.lan 192.0.2.7 1
    _expect https-hit 0 "=" || return 1
    run _ci_validate_dns_resolves x IP_HTTP probe.lan 192.0.2.7 1
    _expect http-miss 1 "[CI-ERROR-VALIDATE-0036];side=\"IP_HTTP\";evidence dns" || return 1
}

# What: setup.sh rolls DNS back in the real dns service
# Why: one dns service serves both sides.
# From: Issue #1683 | PR #1912
@test "setup.sh dns rollback targets the compose dns service" {
    local root cfg url
    _export_validation_env || return 1
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    cfg="$(_ci_validate_config_json)" \
        && url="$(_ci_runtime_default DNS_URL)" || { echo "compose: ${cfg}"; return 1; }
    url="${url#*://}"
    [ "${url%%:*}" = dns ] && jq -e '.services.dns' <<<"${cfg}" >/dev/null \
        || { echo "ui rollback host '${url%%:*}' is not the compose dns service"; return 1; }
    _load_setup_sh "${root}"
    _setup_sh_run 'resolve_stack_dir() { printf "%s\n" "$1"; }
        reset_dns_to_last_known_good_config() { echo "target=$1 zone=$3 snap=$4 yes=$5"; }
        cmd_reset_to_last_known_good_config pdns /x lan. s1 --yes
        cmd_reset_to_last_known_good_config dns /x lan.'
    _expect dispatch 0 "target=dns zone=lan. snap=s1 yes=1;target=dns zone=lan. snap= yes=0" || return 1
    _setup_sh_run 'cmd_reset_to_last_known_good_config dns-http /x lan.'
    _expect old-name 1 "Unknown service 'dns-http'" || return 1
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

# What: a runtime default is read from the SOT list
# Why: checks must not keep their own copy of a port
# From: Issue #1683 | PR #1912
@test "runtime default reads one key of the SOT list" {
    local list key val miss
    list="$(_ci_runtime_defaults)" || { echo "no runtime.defaults: ${list}"; return 1; }
    key="${list%%$'\n'*}"
    run _ci_runtime_default "${key%%=*}"
    _expect listed 0 "=${key#*=}" || return 1
    miss="$(_val name)"
    run _ci_runtime_default "${miss}"
    _expect unlisted 2 "VALIDATE-0125" || return 1
    run _ci_validate_rollback_base 192.0.2.1
    val="$(sed -n 's/^DNS_ROLLBACK_PORT=//p' <<< "${list}")"
    _expect rollback-base 0 "=http://192.0.2.1:${val}" || return 1
}

# What: @KEY@ in a default names another entry
# Why: a path or port is written once; users name it
# From: Issue #1683 | PR #1912
@test "runtime defaults: @KEY@ resolves, unknown and cyclic references fail" {
    local root a b c d rows
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    a="$(_val name)" b="$(_val name)" c="$(_val name)" d="$(_val name)"
    rows="${a}=/${d}"$'\n'"${b}=@${a}@/sub"$'\n'"${c}=@${b}@:1"
    run bash -c 'source "$1" && runtime_defaults_expand' _ "${root}/setup.sh" <<< "${rows}"
    _expect chain 0 "=${a}=/${d}"$'\n'"${b}=/${d}/sub"$'\n'"${c}=/${d}/sub:1" || return 1
    run bash -c 'source "$1" && runtime_defaults_expand' _ "${root}/setup.sh" <<< "${b}=@${a}@"
    _expect unknown 1 "names @${a}@, which is no entry" || return 1
    run bash -c 'source "$1" && runtime_defaults_expand' _ "${root}/setup.sh" <<< "${a}=@${b}@"$'\n'"${b}=@${a}@"
    _expect cycle 1 "refers to itself" || return 1
    rows="$(_ci_runtime_defaults)" || { echo "no expanded defaults: ${rows}"; return 1; }
    [[ "${rows}" != *"@"*"@"* ]] || { echo "unresolved @KEY@ left: $(grep -F '@' <<< "${rows}")"; return 1; }
}

# What: @{block.key} in the SOT is that scalar
# Why: a value naming another SOT value is not copied
# From: Issue #1683 | PR #1912
@test "SOT references: @{block.key} resolves, unknown and cyclic ones fail" {
    local m="${BATS_TEST_TMPDIR}/ref.yml" a b v
    a="$(_val name)" b="$(_val name)" v="$(_val name)"
    printf '%s:\n  k: %s\n%s:\n  k: "@{%s.k}/x"\n' "${a}" "${v}" "${b}" "${a}" > "${m}"
    CI_MANIFEST="${m}" run _ci_block_entry_field "${b}" "" k
    _expect resolved 0 "=${v}/x" || return 1
    printf '%s:\n  k: "@{%s.nope}"\n' "${a}" "${a}" > "${m}.2"
    CI_MANIFEST="${m}.2" run _ci_block_entry_field "${a}" "" k
    _expect unknown 2 "CORE-0150" || return 1
    printf '%s:\n  k: "@{%s.j}"\n  j: "@{%s.k}"\n' "${a}" "${a}" "${a}" > "${m}.3"
    CI_MANIFEST="${m}.3" run _ci_block_entry_field "${a}" "" k
    _expect cycle 2 "SOT reference cycle" || return 1
}

# What: workspace members come from Cargo.toml
# Why: no SOT list repeats them; bins and libs differ
# From: Issue #1683 | PR #1912
@test "workspace: members, bin source dirs and libraries are read from Cargo.toml" {
    local root="${BATS_TEST_TMPDIR}/ws" bin lib sub
    bin="$(_val name)" lib="$(_val name)" sub="$(_val name)"
    mkdir -p "${root}/${bin}/${sub}" "${root}/${lib}"
    printf '[workspace]\nmembers = ["%s", "%s"]\n' "${bin}" "${lib}" > "${root}/Cargo.toml"
    printf '[package]\nname = "%s"\n[[bin]]\nname = "x"\npath = "%s/main.rs"\n' "${bin}" "${sub}" > "${root}/${bin}/Cargo.toml"
    printf '[package]\nname = "%s"\n[lib]\npath = "shared.rs"\n' "${lib}" > "${root}/${lib}/Cargo.toml"
    run _ci_workspace_rows "${root}"
    _expect rows 0 "=${bin}|${sub}/main.rs|${bin}"$'\n'"${lib}||${lib}" || return 1
    run ci_workspace_lib_dirs "${root}"
    _expect libs 0 "=${lib}" || return 1
    run ci_workspace_source_dirs "${root}"
    _expect sources 0 "=${bin}/${sub}"$'\n'"${lib}" || return 1
    run _ci_workspace_src_dir "${bin}" main.rs
    _expect root-bin 0 "=${bin}" || return 1
}

# What: every moved config/prod key reaches a container
# Why: a key .env.local holds but compose drops is lost
# From: Issue #1683 | PR #1912
@test "moved config/prod keys have a compose environment entry" {
    local root rows compose svc key target
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    compose="${root}/$(_ci_variable CI_COMPOSE_FILE)" || return 1
    rows="$(bash -c 'source "$1" && config_prod_moved_keys' _ "${root}/setup.sh")" \
        && [ -n "${rows}" ] || { echo "no moved keys: ${rows}"; return 1; }
    while read -r svc key target; do
        key="${target:-${key}}"
        # What: a renamed legacy key is migrated, not passed
        # Why: setup.sh moves it to its new name's entry
        grep -qE "^[[:space:]]+- ${key}=\\$\\{${key}[:}]" "${compose}" \
            || grep -qE "append_env_migrated_assignment_if_missing [A-Z_]+ ${key} " "${root}/setup.sh" \
            || { echo "${svc} ${key}: no environment entry in ${compose}"; return 1; }
    done <<< "${rows}"
}

# What: the shared dir must be a mount of this container
# Why: an unmounted dir would give the daemon a wrong path
# From: Issue #1683 | PR #1912
@test "validate shared dir is refused unless it is a mount" {
    local d
    d="${BATS_TEST_TMPDIR}/$(_val name)"
    mkdir -p "${d}"
    CI_VALIDATE_SHARED_DIR="${d}" run _ci_validate_shared_dir
    _expect plain-dir 2 "VALIDATE-0118" || return 1
    CI_VALIDATE_SHARED_DIR=/proc run _ci_validate_shared_dir
    _expect mount 0 "=/proc" || return 1
}

# What: stage copies the compose dir and repo bind sources
# Why: relative binds must name paths the daemon also has
# From: Issue #1683 | PR #1912
@test "validate stage copies the compose dir and repo bind sources" {
    local r d c f
    r="${BATS_TEST_TMPDIR}/repo" d="${BATS_TEST_TMPDIR}/stage" c="$(_val name)" f="$(_val name)"
    mkdir -p "${r}/deploy/x" "${r}/${c}" "${r}/lone"
    printf 'A\n' > "${r}/deploy/x/compose.yml"
    printf 'B\n' > "${r}/${c}/${f}"
    printf 'C\n' > "${r}/lone/file.txt"
    export CI_REPO_ROOT="${r}" CI_COMPOSE_FILE=deploy/x/compose.yml
    _ci_validate_config_json() {
        jq -cn --arg a "${r}/${c}" --arg b "${r}/lone/file.txt" '{services: {s: {volumes: [
            {type: "bind", source: $a}, {type: "bind", source: $b},
            {type: "bind", source: "/var/run/docker.sock"}, {type: "bind", source: ($a + "/gone")}]}}}'
    }
    run _ci_validate_stage "${d}"
    _expect stage 0 - || return 1
    [ "$(cat "${d}/deploy/x/compose.yml")" = A ] || { echo "compose file not staged"; return 1; }
    [ "$(cat "${d}/${c}/${f}")" = B ] || { echo "bind dir not staged"; return 1; }
    [ "$(cat "${d}/lone/file.txt")" = C ] || { echo "bind file not staged"; return 1; }
    [ -d "${d}/${c}/gone" ] || { echo "missing bind source not made"; return 1; }
    [ ! -e "${d}/var" ] || { echo "a path outside the repo was staged"; return 1; }
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
        _ci_set_runtime ${RT_KIND:+"${RT_KIND}"}
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
    run _rt_probe "/proc/$(_val name)/$(_val name)" optional github-hosted - no - - - -
    _expect mkdir-fails 2 "[CI-ERROR-VARIABLES-0019];raw:" || return 1
    run _rt_probe /proc/self optional github-hosted - no - - - -
    _expect write-fails 2 "[CI-ERROR-VARIABLES-0018];raw:" || return 1
    [[ "${output}" != *"--secret"* ]] || { echo "write-fails: a mount for an unwritten secret: ${output}"; return 1; }
    dir="$(_val path)"
    RT_KIND=toolchain run _rt_probe "${dir}" required self-hosted "${V["@U@"]}" yes "${V["@S@"]}" "${V["@ST@"]}" \
        "${V["@H1@"]},cpp" "${V["@CA@"]}"
    _expect toolchain-kind 0 "--secret id=project_selfhosted_proxy_ca,src=${dir}/project_selfhosted_proxy_ca" || return 1
    [ "$(ls -A "${dir}")" = project_selfhosted_proxy_ca ] || { echo "toolchain-kind: cache secrets written: $(ls -A "${dir}")"; return 1; }
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

# What: a KEY=VALUE secret reaches the stage key by key
# Why: the writer ends without a newline; no key may drop
# From: Issue #1683 | PR #1858
@test "build secret KEY=VALUE file exports every asked key in the stage" {
    local f ru tok other
    f="$(_val path)" ru="$(_val url)" tok="$(_val sha)=$(_val name)" other="$(_val var)"
    _ci_write_secret "${f}" "ACTIONS_RESULTS_URL=${ru}"$'\n\n'"${other}=$(_val name)"$'\n'"ACTIONS_RUNTIME_TOKEN=${tok}" || return 1
    [ "$(tail -c 1 "${f}" | od -An -c | tr -d ' ')" != '\n' ] || { echo "writer ends with a newline"; return 1; }
    CI_SH="${CI_SH}" F="${f}" O="${other}" run env -u ACTIONS_RESULTS_URL -u ACTIONS_RUNTIME_TOKEN -u "${other}" bash -c \
        'source "${CI_SH}" && _ci_secret_env "${F}" ACTIONS_RESULTS_URL ACTIONS_RUNTIME_TOKEN \
            && printf "u=%s t=%s o=%s\n" "${ACTIONS_RESULTS_URL-unset}" "${ACTIONS_RUNTIME_TOKEN-unset}" "${!O-unset}"'
    _expect roundtrip 0 "=u=${ru} t=${tok} o=unset" || return 1
    CI_SH="${CI_SH}" F="$(_val path)" run bash -c 'source "${CI_SH}" && _ci_secret_env "${F}" ACTIONS_RESULTS_URL && echo none'
    _expect absent 0 "=none" || return 1
}

# =========================================================
# BUILD-ARGS EMISSION (SOT -> --build-arg)
# =========================================================

# What: real SOT targets: digest-pinned alpine, filled args.
# Why: SOT owns every value; build-args only maps it.
# From: Issue #1683 | PR #1858
@test "build-args: real SOT targets give pinned, filled arguments" {
    local tool pc sp verify w case target fmt plat pre want absent s stderr=""
    local -A N=()
    tool="$(_ci_block_keys build_toolchain)" && pc="$(_pin_consumer)" && sp="$(_ci_build_matrix_platforms)" \
        || { echo "SOT readers failed"; return 1; }
    tool="${tool%%$'\n'*}" sp="${sp%%$'\n'*}"
    [ -n "${tool}" ] && [ -n "${pc}" ] && [ -n "${sp}" ] || { echo "inputs: ${tool} ${pc} ${sp}"; return 1; }
    run --separate-stderr bash "${CI_SH}" check version-drift
    [ "${status}" -eq 0 ] || { echo "version-drift rc ${status}: ${output} ${stderr}"; return 1; }
    verify="${output}"
    for w in VERSION ARCH SHA256; do
        N[${w}]="$(sed -n "s/^key=$(_pin_dep)\.consumer\.\([A-Z0-9_]*_${w}\) shape=bare\$/\1/p" <<< "${verify}" | awk 'NR == 1')"
        [ -n "${N[${w}]}" ] || { echo "no ${w} ARG in: ${verify}"; return 1; }
    done
    while IFS='|' read -r case target fmt plat want absent; do
        target="${target/@TOOL@/${tool}}" target="${target/@PC@/${pc}}"
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
toolchain|@TOOL@|||APK_PACKAGES=.+|BUILD_TOOLS_IMAGE
toolchain-bare|@TOOL@|--bare||APK_PACKAGES=.+|BUILD_TOOLS_IMAGE
pin-no-platform|@PC@|||@VER@=.+|@ARCH@
pin-platform|@PC@||@SP@|@ARCH@=.+ @SHA@=[0-9a-f]{64}$|-
CASES
    s="$(ci_services | awk 'NR == 1')"
    run _ci_service_build_args "${s}" --bare "${sp}" no
    _expect no-toolchain 0 "RUST_CRATES=" || return 1
    _expect runtime-gid 0 "LANCACHE_RUNTIME_GID=$(_ci_required_field runtime gid block)" || return 1
    [[ "${output}" != *BUILD_TOOLS_IMAGE=* ]] || { echo "no-toolchain: image arg emitted: ${output}"; return 1; }
    run _ci_service_build_args "${s}" --bare "${sp}" "$(_val name)"
    _expect bad-toolchain-flag 2 "[CI-ERROR-BUILDARGS-0020] service=\"${s}\"" || return 1
}

# What: OCI labels from the SOT, the env and the checkout
# Why: build provenance is set once per image by ci.sh
# From: Issue #1683 | PR #1858
@test "oci labels: provenance from the SOT, the env and the checkout" {
    local want got fb base r u
    local -A V=(["@OWN@"]="$(_val name)" ["@REPO@"]="$(_val name)" ["@SRV@"]="$(_val url)")
    r="$(_val path)" u="$(_val path)"
    git init -q "${r}" && git init -q "${u}" || return 1
    git -C "${r}" -c user.email="$(_val name)@$(_val host)" -c user.name="$(_val name)" commit -q --allow-empty -m "$(_val name)" \
        && V["@SHA@"]="$(git -C "${r}" rev-parse HEAD)" || return 1
    V["@S@"]="$(ci_services | awk 'NR == 1')"
    fb="$(_ci_required_field "${V["@S@"]}" final_base)" && base="$(_ci_block_entry_field base_images "" "${fb}")" \
        && V["@LIC@"]="$(_ci_release_value license)" || { echo "SOT inputs: ${V[*]} ${fb} ${base}"; return 1; }
    [ -n "${V["@S@"]}" ] && [ -n "${base}" ] && [ -n "${V["@LIC@"]}" ] || { echo "SOT inputs: ${V[*]} ${base}"; return 1; }
    V["@BIMG@"]="${base%@*}" V["@BDIG@"]="${base#*@}"
    want="$(_fill "$(printf 'org.opencontainers.image.%s\n' 'revision=@SHA@' 'version=@SHA@' \
        'source=@SRV@/@OWN@/@REPO@' 'url=@SRV@/@OWN@/@REPO@' 'documentation=@SRV@/@OWN@/@REPO@' 'licenses=@LIC@' \
        'vendor=@OWN@' 'title=@S@' 'description=@REPO@ @S@ image' 'base.name=@BIMG@' 'base.digest=@BDIG@')")"
    CI_REPO_ROOT="${r}" GITHUB_SHA="$(_val sha)" GITHUB_SERVER_URL="${V["@SRV@"]}" \
        GITHUB_REPOSITORY="${V["@OWN@"]}/${V["@REPO@"]}" run _ci_oci_labels "${V["@S@"]}"
    _expect labels 0 - || return 1
    [[ "${output%%$'\n'*}" =~ ^org\.opencontainers\.image\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || { echo "created: ${output}"; return 1; }
    got="${output#*$'\n'}"
    [ "${got}" = "${want}" ] || { echo "labels: ${got}"; echo "want: ${want}"; return 1; }
    CI_REPO_ROOT="${u}" GITHUB_SERVER_URL="${V["@SRV@"]}" GITHUB_REPOSITORY="${V["@OWN@"]}/${V["@REPO@"]}" \
        run _ci_oci_labels "${V["@S@"]}"
    _expect no-commit 2 '[CI-ERROR-CORE-0106]' || return 1
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
    V["@X@"]="$(_ci_block_entry_list pr_policy "" title_scopes_extra | awk 'NR == 1')"
    V["@A@"]="$(_ci_block_entry_list pr_policy "" check_exempt_authors | awk 'NR == 1')"
    [ -n "${V["@T@"]}" ] && [ -n "${V["@S@"]}" ] && [ -n "${V["@X@"]}" ] && [ -n "${V["@A@"]}" ] \
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

# What: compose image: own ref or SOT base pin, else coded
# Why: a floating or foreign external image is unreviewed
# From: Issue #1683 | PR #1912
@test "check stable-external-images: own refs and SOT pins pass, others fail" {
    local d pin case img rc want
    run bash "${CI_SH}" check stable-external-images
    _expect real 0 "stable-external-images=clean" || return 1
    pin="$(_ci_block_keys base_images all | awk 'NR == 1')" && pin="$(_ci_block_entry_field base_images "" "${pin}")" \
        && [[ "${pin}" == *@sha256:* ]] || { echo "no SOT base pin: ${pin}"; return 1; }
    d="$(_val path)" && mkdir -p "${d}" || { echo "no compose dir"; return 1; }
    while IFS='|' read -r case img rc want; do
        img="${img/@PIN@/${pin}}" img="${img/@BARE@/${pin%@*}}" img="${img/@DIG@/$(_val digest)}"
        want="${want/@BARE@/${pin%@*}}"
        printf 'services:\n  a:\n    image: %s\n' "${img}" > "${d}/docker-compose.yml"
        run bash "${CI_SH}" check stable-external-images "${d}"
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
own|${LANCACHE_IMAGE_REF_A:?LANCACHE_IMAGE_REF_A is required}|0|stable-external-images=clean
sot-pin|@PIN@|0|stable-external-images=clean
quoted-pin|"@PIN@"|0|stable-external-images=clean
tag-only|@BARE@|1|[CI-ERROR-CHECK-0014];external not digest-pinned: @BARE@
foreign-digest|@BARE@@@DIG@|1|[CI-ERROR-CHECK-0014];external pin is not a SOT pin
CASES
    run bash "${CI_SH}" check stable-external-images "${d}/$(_val name)"
    _expect no-dir 1 "[CI-ERROR-CHECK-0014];compose dir missing" || return 1
}

# What: every check has a function; check all keeps worst rc
# Why: a stop (2) read as a finding (1) or a skip hides it
# From: Issue #1683 | PR #1912
@test "check: one table dispatches, check all keeps the worst exit" {
    local k fn row tab pr rc want stubs
    for k in "${!CI_CHECKS[@]}"; do
        fn="${CI_CHECKS[${k}]#* }"
        declare -F "${fn}" > /dev/null || { echo "${k}: no function ${fn}"; return 1; }
    done
    run bash "${CI_SH}" check "$(_val name)"
    _expect unknown 2 "[CI-ERROR-CHECK-0001]" || return 1
    stubs='_t_arg() { echo "arg:$*"; }; _t_find() { return 1; }; _t_stop() { return 2; }; _t_job() { echo job-ran; }'
    while IFS='|' read -r row tab pr rc want; do
        CI_SH="${CI_SH}" STUBS="${stubs}" TAB="${tab}" PR_NUMBER="${pr}" run env -u CHANGED_FILES bash -c \
            'source "${CI_SH}"; eval "${STUBS}"; eval "CI_CHECKS=(${TAB})"; ci_cmd_check_all x.sh'
        _expect "${row}" "${rc}" "${want}" || return 1
        [[ "${output}" != *job-ran* ]] || { echo "${row}: job scope ran in check all"; return 1; }
    done <<'CASES'
clean|[a]="diff _t_arg" [c]="job _t_job"||0|arg:x.sh;check-all=clean
finding|[a]="diff _t_arg" [b]="repo _t_find"||1|arg:x.sh
stop-wins|[b]="repo _t_find" [e]="repo _t_stop"||2|-
stop-kept|[a]="repo _t_stop" [b]="repo _t_find"||2|-
pr-off|[d]="pr _t_find"||0|check-all=clean
pr-on|[d]="pr _t_find"|7|1|-
bad-scope|[f]="bogus _t_job"||2|[CI-ERROR-CHECK-0173]
CASES
    CI_SH="${CI_SH}" STUBS="${stubs}" run bash -c \
        'source "${CI_SH}"; eval "${STUBS}"; CI_CHECKS=([c]="job _t_job"); ci_cmd_check c'
    _expect job-by-name 0 job-ran
}

# What: matrix vs compose: missing, extra, double row coded
# Why: a service must not log unseen after a rename or fold
# From: Issue #1683 | PR #1912
@test "check logging-matrix: real repo clean, row drift fails coded" {
    local real doc dep s g fx row edit rc want
    real="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    doc="$(_ci_variable CI_ARCH_DOC)" && dep="$(_ci_variable CI_COMPOSE_FILE)" \
        && s="$(_ci_compose_service_names "${real}/${dep}")" || { echo "inputs unreadable"; return 1; }
    s="${s%%$'\n'*}" g="$(_val name)"
    [ -n "${s}" ] || { echo "no compose service"; return 1; }
    run bash "${CI_SH}" check logging-matrix "${real}"
    _expect real 0 "logging-matrix=clean" || return 1
    while IFS='#' read -r row edit rc want; do
        fx="$(_val path)"
        mkdir -p "${fx}/${doc%/*}" "${fx}/${dep%/*}" && cp "${real}/${doc}" "${fx}/${doc}" \
            && cp -r "${real}/${dep%/*}/." "${fx}/${dep%/*}/" || { echo "${row}: fixture not copied"; return 1; }
        edit="${edit//@S@/${s}}" want="${want//@S@/${s}}"
        edit="${edit//@G@/${g}}" want="${want//@G@/${g}}"
        if [ "${edit}" = rm ]; then
            rm -- "${fx}/${dep}"
        else
            sed -i "${edit}" "${fx}/${doc}"
            ! cmp -s "${real}/${doc}" "${fx}/${doc}" || { echo "${row}: edit changed nothing"; return 1; }
        fi
        run bash "${CI_SH}" check logging-matrix "${fx}"
        _expect "${row}" "${rc}" "${want}" || return 1
    done <<'CASES'
drop#/^| `@S@` |/d#1#[CI-ERROR-CHECK-0038];service '@S@' has no logging-matrix row
double#/^| `@S@` |/p#1#[CI-ERROR-CHECK-0038];row '@S@' appears more than once
extra#/^| `@S@` |/{p;s/`@S@`/`@G@`/}#1#[CI-ERROR-CHECK-0038];row '@G@' is not a real Compose service
noname#/^| `@S@` |/{p;s/`@S@`//}#1#[CI-ERROR-CHECK-0038];a row has no service name
no-compose#rm#2#[CI-ERROR-CHECK-0034]
CASES
}

# What: each short-SHA form fails coded; look-alikes pass
# Why: AG-REL-015 tags need all 40 hex digits of the SHA
# From: Issue #1683 | PR #1912
@test "check deny-short-sha: substring, git and Rust forms fail, look-alikes pass" {
    local d row file line rc want
    run bash "${CI_SH}" check deny-short-sha
    _expect real 0 "deny-short-sha=clean" || return 1
    while IFS='|' read -r row file line rc; do
        d="$(_val path)"
        mkdir -p "${d}"
        line="${line//@D@/\$}" line="${line//@K@/sha}" line="${line//@S@/--short}"
        line="${line//@A@/--abbrev}" line="${line//@P@/%}"
        printf '%s\n' "${line}" > "${d}/${file}"
        want="deny-short-sha=clean files=1"
        [ "${rc}" -eq 0 ] || want="[CI-ERROR-CHECK-0005];${d}/${file}:1:"
        run bash "${CI_SH}" check deny-short-sha "${d}/${file}"
        _expect "${row}" "${rc}" "${want}" || return 1
    done <<'CASES'
sh-slice|a.sh|x=@D@{GIT_@K@:0:7}|1
sh-empty-offset|a.sh|x=@D@{@K@::7}|1
sh-neg-offset|a.sh|x=@D@{@K@: -7}|1
sh-neg-length|a.sh|x=@D@{@K@:0:-33}|1
sh-var-length|a.sh|x=@D@{commit_id:0:@D@n}|1
sh-paren-offset|a.sh|x=@D@{revision:(0):7}|1
sh-array|a.sh|x=@D@{@K@[0]:0:7}|1
sh-default|a.sh|x=@D@{@K@:-none}|0
sh-assign|a.sh|x=@D@{@K@:=none}|0
sh-error|a.sh|x=@D@{@K@:?unset}|0
sh-alt|a.sh|x=@D@{@K@:+set}|0
sh-shared|a.sh|x=@D@{shared_dir:0:3}|0
git-short|a.sh|v=@D@(git rev-parse @S@ HEAD)|1
git-abbrev|a.sh|git log -1 @A@-commit|1
git-format|a.sh|git log -1 --format=@P@h|1
git-full|a.sh|git log -1 --format=@P@H|0
git-branch|a.sh|git symbolic-ref @S@ HEAD|0
dockerfile|Dockerfile|RUN t=@D@{@K@:0:7}|1
workflow|w.yml|run: t=@D@{@K@:0:7}|1
rust-slice|a.rs|let s = &head_@K@[..7];|1
rust-get|a.rs|let s = commit.get(0..12);|1
rust-shape|a.rs|let s = &shape[..2];|0
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
strip-two-inline|strip|a<!--x-->b<!--y-->c|-|abc
section-tilde-fence|section|## Linked Issues\n~~~\n# not a heading\n~~~\nz|Linked Issues|1\n~~~\n# not a heading\n~~~\nz
section-seven-hashes|section|## Linked Issues\n####### text\n## Next|Linked Issues|1\n####### text
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

# What: raw GET -> body on 200, rc 1 with the http code else
# Why: the retry layer classifies by the "http NNN" text
# From: Issue #1860 | PR #1872
@test "raw get returns the body on 200 and the http code otherwise" {
    local body code
    body="$(_val name)"
    curl() { printf '%s\n%s' "${BODY}" "${CODE}"; }
    BODY="${body}" CODE=200 run _ci_raw_get "$(_val url)"
    _expect ok 0 "=${body}" || return 1
    for code in 404 503; do
        body="$(_val name)"
        BODY="${body}" CODE="${code}" run _ci_raw_get "$(_val url)"
        _expect "http-${code}" 1 "http ${code};${body}" || return 1
    done
    curl() { printf '%s\n200' "$*"; }
    run _ci_raw_get "$(_val url)"
    _expect timeouts-from-sot 0 "--connect-timeout $(_ci_variable CI_RAW_GET_CONNECT_TIMEOUT) --max-time $(_ci_variable CI_RAW_GET_MAX_TIME) " || return 1
    curl() { return 6; }
    run _ci_raw_get "$(_val url)"
    _expect curl-error 1 "http 000" || return 1
}

# What: manifest fetch -> OK body, NOTFOUND, or INFRA:<code>
# Why: a missing manifest is a broken pin; rest fails closed
# From: Issue #1860 | PR #1872
@test "action manifest fetch separates ok, not found and infra" {
    local own repo ref body
    own="$(_val name)" repo="$(_val name)" ref="$(_val sha)" body="runs:
  using: $(_val name)"
    export CI_RETRY_MAX_ATTEMPTS=1 CI_RETRY_BACKOFF_BASE_SECONDS=0
    _ci_raw_get() { case "$1" in *action.yml) printf 'http 404\n' >&2; return 1 ;; esac; printf '%s\n' "${BODY}"; }
    BODY="${body}" run _ci_fetch_action_manifest "${own}" "${repo}" "" "${ref}"
    _expect ok-after-yml-404 0 "OK;${body}" || return 1
    _ci_raw_get() { printf 'raw GET x failed: http 404\n' >&2; return 1; }
    run _ci_fetch_action_manifest "${own}" "${repo}" "" "${ref}"
    _expect not-found 0 "=NOTFOUND" || return 1
    _ci_raw_get() { printf 'raw GET x failed: http 503\n%s\n' "${body}" >&2; return 1; }
    run _ci_fetch_action_manifest "${own}" "${repo}" "" "${ref}"
    _expect infra 0 "INFRA:503;http 503;${body}" || return 1
}

# What: pin policy -> runtime, 40-hex SHA, own repo, infra
# Why: one check owns the pin rules for hook and CI
# From: Issue #1860 | PR #1872
@test "action node versions check enforces runtime and ref hygiene" {
    local own repo ext sha root case uses manifest rc want
    own="$(_val name)" repo="$(_val name)" ext="$(_val name)/$(_val name)" sha="$(_val sha)"
    root="$(_val path)"
    mkdir -p "${root}/.github/workflows"
    export GITHUB_REPOSITORY="${own}/${repo}"
    while IFS='|' read -r case uses manifest rc want; do
        uses="${uses//@EXT@/${ext}}" uses="${uses//@SHA@/${sha}}" uses="${uses//@OWN@/${own}/${repo}}"
        printf 'jobs:\n  j:\n    steps:\n      - uses: %s\n' "${uses}" > "${root}/.github/workflows/w.yml"
        _ci_fetch_action_manifest() { printf '%s\n' "${MANIFEST//\\n/$'\n'}"; }
        MANIFEST="${manifest}" run _ci_check_action_node_versions "${root}"
        _expect "${case}" "${rc}" "${want}" || return 1
    done <<'CASES'
node24|@EXT@@@SHA@|OK\nruns:\n  using: node24|0|action-node-versions=clean
node20|@EXT@@@SHA@|OK\nruns:\n  using: node20|1|declares runs.using: node20
no-using|@EXT@@@SHA@|OK\nname: x|1|has no parseable runs.using
not-found|@EXT@@@SHA@|NOTFOUND|1|broken pin
infra|@EXT@@@SHA@|INFRA:503|2|FAIL CLOSED
tag-ref|@EXT@@v4|OK\nruns:\n  using: node24|1|must use a full 40-hex commit SHA
own-no-ref|@OWN@/x|OK\nruns:\n  using: node24|1|must include an explicit ref
CASES
}

# What: hook -> runs the ci.sh check on workflow changes
# Why: the check lives in ci.sh; the hook gates the push
# From: Issue #801 | PR #1912
@test "pre-push hook runs ci.sh check action-node-versions on workflow changes" {
    local repo hook before after zero
    repo="$(_val path)" hook="${BATS_TEST_DIRNAME}/../../.githooks/pre-push"
    zero="0000000000000000000000000000000000000000"
    mkdir -p "${repo}/.github/scripts" "${repo}/.github/workflows"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\nexit "$(cat "%s/rc")"\n' "${repo}" "${repo}" > "${repo}/.github/scripts/ci.sh"
    printf '0' > "${repo}/rc"
    git -C "${repo}" init -q
    git -C "${repo}" remote add origin "https://github.com/$(_val name)/$(_val name).git"
    git -C "${repo}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m a
    before="$(git -C "${repo}" rev-parse HEAD)"
    printf 'x\n' > "${repo}/other.txt"
    git -C "${repo}" add other.txt
    git -C "${repo}" -c user.name=t -c user.email=t@t commit -q -m b
    after="$(git -C "${repo}" rev-parse HEAD)"
    cd "${repo}"
    run bash "${hook}" origin "$(git remote get-url origin)" <<< "refs/heads/m ${after} refs/heads/m ${before}"
    _expect no-workflow 0 - || return 1
    [ ! -e "${repo}/calls" ] || { echo "check ran without a workflow change"; return 1; }
    before="${after}"
    printf 'on: push\n' > "${repo}/.github/workflows/w.yml"
    git -C "${repo}" add .github/workflows/w.yml
    git -C "${repo}" -c user.name=t -c user.email=t@t commit -q -m c
    after="$(git -C "${repo}" rev-parse HEAD)"
    run bash "${hook}" origin "$(git remote get-url origin)" <<< "refs/heads/m ${after} refs/heads/m ${before}"
    _expect workflow-clean 0 - || return 1
    [ "$(cat "${repo}/calls")" = "check action-node-versions" ] || { echo "calls: $(cat "${repo}/calls")"; return 1; }
    printf '1' > "${repo}/rc"
    run bash "${hook}" origin "$(git remote get-url origin)" <<< "refs/heads/m ${after} refs/heads/m ${zero}"
    _expect workflow-violation 1 "push blocked" || return 1
    printf '0' > "${repo}/rc"
    rm -f "${repo}/calls"
    run bash "${hook}" origin "$(git remote get-url origin)" <<< "refs/heads/m ${after} refs/heads/m $(_val sha)"
    _expect git-diff-failure 0 "git diff failed (" || return 1
    [ "$(cat "${repo}/calls")" = "check action-node-versions" ] || { echo "calls: $(cat "${repo}/calls")"; return 1; }
}

# What: changed file -> skip only for a shell comment.
# Why: arch doc Test B/C/D; unproven changes run it.
# From: Issue #1683 | PR #1858
@test "ci-bats gate: only a shell comment change skips the suite" {
    local r base case path body want id
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
        CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push BEFORE_SHA="${base}" \
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
    CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push BEFORE_SHA='' run _ci_test_identity_gate "${V["@B@"]}"
    _expect no-base 0 '[CI-INFO-TESTID-0004]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-base: ${output}"; return 1; }
    run _ci_test_identity_gate
    _expect no-files 0 '[CI-INFO-TESTID-0001]' || return 1
    [ "${lines[${#lines[@]}-1]}" = run ] || { echo "no-files: ${output}"; return 1; }
}

# What: per row: changed paths -> docs-only rc and reason
# Why: §12.4 §63: docs are NOOP unless a SOT-named input
# From: Issue #1683 | PR #1858
@test "docs-only holds only for docs no SOT key names" {
    local case sot paths rc want keys k v gho
    local -a av
    local -A V=(["@X@"]="$(_val name)" ["@Y@"]="$(_val name)" ["@C@"]="$(_val name)")
    V["@D@"]="$(_ci_variable CI_DOCS_DIR)" && V["@STATE@"]="$(_ci_block_entry_field release "" validation_state)" \
        && V["@GOV@"]="$(_ci_block_entry_list release "" governance_paths | awk 'NR == 1')" \
        && keys="$(_ci_block_keys ci_variables all)" || { echo "SOT inputs: ${V[*]}"; return 1; }
    while IFS= read -r k; do
        v="$(_ci_variable "${k}")" || { echo "${k}: unreadable"; return 1; }
        [[ "${v}" != *.md ]] || { V["@NAMED@"]="${v}"; break; }
    done <<< "${keys}"
    [ -n "${V["@D@"]}" ] && [ -n "${V["@STATE@"]}" ] && [ -n "${V["@GOV@"]}" ] && [ -n "${V["@NAMED@"]:-}" ] \
        || { echo "SOT inputs: ${V[*]}"; return 1; }
    while IFS='|' read -r case sot paths rc want; do
        av=(); [ "${paths}" = - ] || read -r -a av <<< "$(_fill "${paths}")"
        if [ "${sot}" = missing ]; then
            CI_MANIFEST="$(_val path)" run _ci_docs_only "${av[@]}"
        else
            run _ci_docs_only "${av[@]}"
        fi
        _expect "${case}" "${rc}" "$(_fill "${want}")" || return 1
    done <<'CASES'
markdown|-|@X@.md|0|-
docs-dir|-|@D@/@Y@ @X@.md|0|-
mixed|-|@X@.md @C@/@Y@|1|-
no-paths|-|-|1|-
dir-prefix-only|-|@D@@Y@/@X@|1|-
sot-named-doc|-|@X@.md @NAMED@|1|[CI-INFO-PLAN-0007] path="@NAMED@"
validation-state|-|@STATE@|1|[CI-INFO-PLAN-0007] path="@STATE@"
governance|-|@GOV@|1|[CI-INFO-PLAN-0007] path="@GOV@"
no-sot|missing|@X@.md|2|[CI-ERROR-CORE-0109] block="ci_variables"
CASES
    gho="$(_val path)"
    GITHUB_OUTPUT="${gho}" CI_MANIFEST="$(_val path)" run bash "${CI_SH}" plan-matrix "${V["@X@"]}.md"
    _expect plan-matrix-undecided 2 '[CI-ERROR-' || return 1
    [ ! -e "${gho}" ] || { echo "plan-matrix wrote output: $(cat "${gho}")"; return 1; }
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

# What: each SOT repair key is refilled when emptied
# Why: AG-OP-007: an incomplete install must converge
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update repairs every empty required key" {
    _registry || return 1
    local keys key d
    keys="$(_ci_block_entry_field validation "" setup_required_repairs)" && [ -n "${keys}" ] \
        || { echo "no SOT validation.setup_required_repairs: ${keys}"; return 1; }
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    for key in ${keys}; do
        d="${BATS_TEST_TMPDIR}/req-${key}/deploy/prod"
        _converged_install "${d}" || return 1
        set_env_key "${key}" "" "${d}/.env"
        cp "${d}/.env" "${d}/.env.before"
        _setup_sh_run 'migrate_env_for_update "${CONV}"'
        # What: a pin without a tag is refused, not guessed
        # Why: only the operator picks an immutable tag
        # From: Issue #1683 | PR #1858
        if [ "${key}" = LANCACHE_IMAGE_TAG ]; then
            _expect "${key}" 1 "requires LANCACHE_IMAGE_TAG" || return 1
            cmp -s "${d}/.env.before" "${d}/.env" || { echo "${key}: refused but the .env changed"; return 1; }
            continue
        fi
        [ "${status}" -eq 0 ] && [ -n "$(get_env_var "${key}" "${d}/.env")" ] \
            || { echo "${key} not repaired: ${output}"; echo "before:"; cat "${d}/.env.before"; return 1; }
    done
}

# What: an empty cache size or GB key derives from its pair
# Why: keep the operator's size, not the template default
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update derives CACHE_MAX_SIZE from CACHE_MAX_GB" {
    _registry || return 1
    local d n m def
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    _cache_row() {
        d="${BATS_TEST_TMPDIR}/cms-$1/deploy/prod"
        _converged_install "${d}" || return 1
        set_env_key CACHE_MAX_GB "$2" "${d}/.env"
        set_env_key CACHE_MAX_SIZE "$3" "${d}/.env"
        _setup_sh_run 'migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "$1: rc ${status}: ${output}"; return 1; }
    }
    n="$(_val int 2 999)" m="$(_val int 2 999)"
    def="$(prod_env_default CACHE_MAX_SIZE)" || { echo "no CACHE_MAX_SIZE default: ${def}"; return 1; }
    _cache_row gb-to-size "${n}" "" || return 1
    [ "$(get_env_var CACHE_MAX_SIZE "${d}/.env")" = "${n}g" ] || { echo "gb-to-size: $(get_env_var CACHE_MAX_SIZE "${d}/.env")"; return 1; }
    _cache_row size-to-gb "" "${m}g" || return 1
    [ "$(get_env_var CACHE_MAX_GB "${d}/.env")" = "${m}" ] || { echo "size-to-gb: $(get_env_var CACHE_MAX_GB "${d}/.env")"; return 1; }
    _cache_row bad-gb "$(_val name)" "" || return 1
    [ "$(get_env_var CACHE_MAX_SIZE "${d}/.env")" = "${def}" ] || { echo "bad-gb: $(get_env_var CACHE_MAX_SIZE "${d}/.env") want ${def}"; return 1; }
}

# What: TTL is a positive whole number up to the SOT max
# Why: a bad TTL would be written or reused unchecked
# From: Issue #1683 | PR #1858
@test "validate_ui_session_ttl_seconds rejects invalid and accepts valid" {
    local max
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    max="$(_ci_runtime_default UI_SESSION_TTL_MAX_SECONDS)" || return 1
    [[ "${max}" =~ ^[1-9][0-9]*$ ]] || { echo "no UI_SESSION_TTL_MAX_SECONDS in the SOT: '${max}'"; return 1; }
    run validate_ui_session_ttl_seconds "$(_val name)" src
    _expect not-a-number 1 "unsigned integer" || return 1
    run validate_ui_session_ttl_seconds 0 src
    _expect zero 1 "greater than zero" || return 1
    run validate_ui_session_ttl_seconds 000 src
    _expect zeros 1 "greater than zero" || return 1
    run validate_ui_session_ttl_seconds "$((max + 1))" src
    _expect over-max 1 "must be at most ${max} seconds" || return 1
    run validate_ui_session_ttl_seconds "${max}" src
    _expect at-max 0 "=" || return 1
    run validate_ui_session_ttl_seconds 010 src
    _expect leading-zero 0 "=" || return 1
    run validate_ui_session_ttl_seconds "$(_val int 1 "${max}")" src
    _expect valid 0 "=" || return 1
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

# What: probe; shared first; disk fallback; never /tmp
# Why: §41.1 one shared DB on disk, never on tmpfs
# From: Issue #1683 | PR #1858
@test "trivy cache dir: writable probe, shared first, disk fallback, never tmpfs" {
    local fb
    [[ "${BATS_TEST_TMPDIR}" != /tmp && "${BATS_TEST_TMPDIR}" != /tmp/* ]] \
        || { echo "BATS_TEST_TMPDIR ${BATS_TEST_TMPDIR} is under /tmp; run the suite via ci.sh check ci-bats"; return 1; }
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}"
    _expect writable 0 - || return 1
    run _ci_trivy_dir_writable "$(_val path)"
    [ "${status}" -ne 0 ] || { echo "missing dir passed: ${output}"; return 1; }
    CI_TRIVY_SHARED_DIR="${BATS_TEST_TMPDIR}" CI_TRIVY_FALLBACK_DIR="$(_val path)" run _ci_trivy_cache_dir
    _expect shared 0 "=dir=${BATS_TEST_TMPDIR} source=nfs-shared" || return 1
    fb="$(_val path)"
    CI_TRIVY_SHARED_DIR="$(_val path)" CI_TRIVY_FALLBACK_DIR="${fb}" run _ci_trivy_cache_dir
    _expect fallback 0 "[CI-INFO-SCAN-0008];dir=${fb} source=local-fallback" || return 1
    [ -d "${fb}" ] || { echo "fallback dir not made: ${fb}"; return 1; }
    CI_TRIVY_SHARED_DIR="/tmp/$(_val name)" CI_TRIVY_FALLBACK_DIR="$(_val path)" run _ci_trivy_cache_dir
    _expect tmp-shared 2 "[CI-ERROR-SCAN-0007]" || return 1
    CI_TRIVY_SHARED_DIR="$(_val path)" CI_TRIVY_FALLBACK_DIR="/tmp/$(_val name)" run _ci_trivy_cache_dir
    _expect tmp-fallback 2 "[CI-ERROR-SCAN-0018]" || return 1
    CI_TRIVY_SHARED_DIR="$(_val path)" CI_TRIVY_FALLBACK_DIR="/proc/$(_val name)/$(_val name)" run _ci_trivy_cache_dir
    _expect fallback-uncreatable 2 "[CI-ERROR-SCAN-0009];raw:" || return 1
    CI_TRIVY_SHARED_DIR="$(_val path)" CI_TRIVY_FALLBACK_DIR=/proc/self run _ci_trivy_cache_dir
    _expect fallback-unwritable 2 "[CI-ERROR-SCAN-0019];raw:" || return 1
}

# What: one writer; held lock times out; stale reclaimed
# Why: two writers must never race the same DB file
# From: Issue #1683 | PR #1858
@test "trivy db lock: one writer, a held lock times out, ensure_fresh hard-fails" {
    local cache order p1
    export CI_TRIVY_LOCK_POLL=1
    _wait_line() {
        local n=0
        until [ -e "$1" ] && grep -qx -- "$2" "$1"; do
            n=$((n + 1))
            [ "${n}" -le 100 ] || { echo "never saw '$2' in $1"; return 1; }
            sleep 0.1
        done
    }
    cache="$(_val path)" order="$(_val path)"
    ( _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c 'echo first-start >> "$1"; sleep 1; echo first-end >> "$1"' _ "${order}" ) &
    p1=$!
    _wait_line "${order}" first-start || return 1
    _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c 'echo second-start >> "$1"' _ "${order}"
    wait "${p1}"
    [ "$(paste -sd' ' "${order}")" = "first-start first-end second-start" ] || { echo "order: $(cat "${order}")"; return 1; }
    cache="$(_val path)" order="$(_val path)"
    ( _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c 'echo held >> "$1"; sleep 6' _ "${order}" ) &
    p1=$!
    _wait_line "${order}" held || return 1
    run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    _expect held-lock 2 "[CI-ERROR-SCAN-0011]" || return 1
    CI_TRIVY_LOCK_TIMEOUT=1 CI_TRIVY_LOCK_STALE=3600 run _ci_trivy_db_ensure_fresh "${cache}"
    _expect ensure-fresh 2 "[CI-ERROR-SCAN-0011];[CI-ERROR-SCAN-0012]" || return 1
    run _ci_trivy_db_lock_run "${cache}" 1 1 -- echo reclaimed
    _expect stale 0 "[CI-WARN-SCAN-0010];reclaimed" || return 1
    wait "${p1}"
    cache="$(_val path)"
    : > "${cache}" || return 1
    run _ci_trivy_db_lock_run "${cache}/$(_val name)" 1 5 -- true
    _expect lock-dir 2 "[CI-ERROR-SCAN-0013]" || return 1
}

# What: the scan argv passes the pinned trivy's flag parser
# Why: a stub took --trivyignores; the real trivy refused it
# From: Issue #1683 | PR #1858
@test "trivy scan argv: the pinned trivy accepts every flag" {
    local root out skip
    local -a a
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    for skip in 0 1; do
        out="$(CI_REPO_ROOT="${root}" CI_TRIVY_TIMEOUT="$(_val int 1 9)m" _ci_trivy_args "$(_val path)" "${skip}")" || return 1
        mapfile -t a <<< "${out}"
        [ "${a[0]} ${a[1]}" = "trivy image" ] || { echo "argv: ${a[*]}"; return 1; }
        run "${a[@]}" --help
        [ "${status}" -eq 0 ] && [[ "${output}" != *"unknown flag"* ]] \
            || { echo "skip ${skip}: ${a[*]}: rc ${status}: $(grep -m 1 -i -E 'error|unknown' <<< "${output}")"; return 1; }
    done
    [[ " ${a[*]} " == *" --ignorefile ${root}/"* && " ${a[*]} " == *" --skip-db-update "* ]] \
        || { echo "argv lacks the ignore file or skip-db-update: ${a[*]}"; return 1; }
}

# What: trivy's exit code tells clean, finding and error
# Why: a clean summary is no finding; an error no verdict
# From: Issue #1683 | PR #1912
@test "trivy scan once: the exit code decides, not the report text" {
    local rep
    rep="${BATS_TEST_TMPDIR}/$(_val name)"
    _stub_trivy() { printf '%s\n' "$(_val name)" > "$2"; return "${_stub_rc}"; }
    _stub_rc=0
    run _ci_trivy_scan_once "${rep}" "$(_val name)" _stub_trivy
    [ "${status}" -eq 0 ] && [ ! -s "${rep}" ] || { echo "clean: rc ${status}, report kept"; return 1; }
    _stub_rc="${_CI_TRIVY_FINDING_RC}"
    run _ci_trivy_scan_once "${rep}" "$(_val name)" _stub_trivy
    [ "${status}" -eq 0 ] && [ -s "${rep}" ] || { echo "finding: rc ${status}, report lost"; return 1; }
    _stub_rc=1
    run _ci_trivy_scan_once "${rep}" "$(_val name)" _stub_trivy
    [ "${status}" -ne 0 ] || { echo "error with a partial report read as a verdict"; return 1; }
}

# What: each scan status gets its own code and exit code
# Why: a run or setup failure never reads as a finding
# From: Issue #1683 | PR #1858
@test "scan outcome: every trivy scan status has its own code" {
    local svc raw st rc want odd
    svc="$(_val name)" raw="$(_val name)" odd="$(_val int 5 99)"
    while IFS='|' read -r st rc want; do
        run _ci_scan_outcome "${svc}" "${st}" "${raw}"
        _expect "status-${st}" "${rc}" "${want}" || return 1
    done <<ROWS
0|0|=
1|2|[CI-ERROR-SCAN-0005] service="${svc}" reason="scan reported findings";${raw}
3|3|[CI-ERROR-SCAN-0023] service="${svc}" rc=3 reason="unexpected scan status;${raw}
4|3|[CI-ERROR-SCAN-0021] service="${svc}" reason="trivy run failed without a report;${raw}
2|2|[CI-ERROR-SCAN-0022] service="${svc}" reason="scan setup failed;${raw}
${odd}|3|[CI-ERROR-SCAN-0023] service="${svc}" rc=${odd};${raw}
ROWS
}

# =========================================================
# VERSION MANAGEMENT
# =========================================================

# What: copy of every file the version owner reads
# Why: drift rows edit a copy, never the real repo
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

# What: real repo clean; one drift per row fails coded
# Why: SOT owns versions; a copy or baked pin must not drift
# From: Issue #1683 | PR #1912
@test "check version-drift: real repo clean, each drift fails with its code" {
    local real want out dep df keys arg lock vf ws mem pkg sv row f e want_rc code fx
    real="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    want="$(_ci_release_value version)" || return 1
    CI_REPO_ROOT="${real}" run bash "${CI_SH}" check version-drift
    _expect clean 0 "release-version=${want} consumers=clean" || return 1
    out="${output}"
    dep="$(_ci_version_consumers)" || { echo "consumers unreadable: ${dep}"; return 1; }
    IFS='|' read -r dep df keys <<< "${dep%%$'\n'*}"
    arg="$(sed -n "s/^key=${dep}\.consumer\.\([A-Z0-9_]*\) shape=bare\$/\1/p" <<< "${out}")"
    arg="${arg%%$'\n'*}"
    lock="$(_ci_variable CI_CARGO_LOCK)" && vf="$(_ci_variable CI_VERSION_FILE)" && ws="$(dirname "${lock}")/Cargo.toml" \
        && mem="$(_ci_cargo_members "${real}/${ws}")" && pkg="$(_ci_cargo_member_names "${real}/${ws}")" \
        || { echo "cargo inputs unreadable"; return 1; }
    mem="${mem%%$'\n'*}" pkg="${pkg%%$'\n'*}"
    [ -n "${df}" ] && [ -n "${keys}" ] && [ -n "${arg}" ] && [ -n "${mem}" ] && [ -n "${pkg}" ] \
        || { echo "inputs: ${dep}|${df}|${keys}|${arg}|${mem}|${pkg}"; return 1; }
    sv="$(_val semver)"
    for row in version-file ws-version ws-license lock-entry member-owns arg-baked arg-missing; do
        want_rc=1
        case "${row}" in
            version-file) f="${vf}" e="s/.*/${sv}/" code=0024 ;;
            ws-version) f="${ws}" e="/^\[workspace\.package\]/,/^\[/ s/^version = .*/version = \"${sv}\"/" code=0021 ;;
            ws-license) f="${ws}" e="/^\[workspace\.package\]/,/^\[/ s/^license = .*/license = \"$(_val name)\"/" code=0028 ;;
            lock-entry) f="${lock}" e="/^name = \"${pkg}\"\$/,/^version = / s/^version = .*/version = \"${sv}\"/" code=0025 ;;
            member-owns) f="${ws%/*}/${mem}/Cargo.toml" e="s/^version\.workspace = true\$/version = \"${sv}\"/" code=0022 ;;
            arg-baked) f="${df}" e="s/^([[:space:]]*ARG[[:space:]]+${arg})[[:space:]]*\$/\1=$(_val name)/" want_rc=2 code=0009 ;;
            arg-missing) f="${df}" e="/^[[:space:]]*ARG[[:space:]]+${arg}[[:space:]]*\$/d" want_rc=2 code=0008 ;;
        esac
        fx="$(_version_fixture_repo)" && sed -i -E "${e}" "${fx}/${f}" || { echo "${row}: copy not edited"; return 1; }
        ! cmp -s "${real}/${f}" "${fx}/${f}" || { echo "${row}: edit changed nothing in ${f}"; return 1; }
        CI_MANIFEST="${CI_MANIFEST_SOURCE}" CI_REPO_ROOT="${fx}" run bash "${CI_SH}" check version-drift
        _expect "${row}" "${want_rc}" "[CI-ERROR-VERSION-${code}]" || return 1
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
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] || { echo "converge $1: ${output}"; return 1; }
}

# What: an old-shape .env from the template's own values
# Why: split cache keys, strict proxy, no state root
# From: Issue #1683 | PR #1858
_legacy_env() {
    local file="$1" user="${2:-}" root tpl
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    tpl="$(_template_env)"
    printf '%s\n' "IP_STANDARD=$(get_env_var IP_HTTP "${tpl}")" "IP_SSL=$(get_env_var IP_HTTPS "${tpl}")" \
        "CACHE_DIR_STANDARD=${file%/*}/cache" "CACHE_DIR_SSL=${file%/*}/cache" 'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' "LANCACHE_IMAGE_TAG=$(_release_tag)" \
        "UI_AUTH_USER=${user}" 'UI_AUTH_PASSWORD=' > "${file}"
}

# What: a converged .env stays byte-identical
# Why: idempotent update, no rewrite (AG-OP-006)
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update is a no-op on an already-converged .env" {
    _registry || return 1
    local root d h
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="${BATS_TEST_TMPDIR}/noop/deploy/prod"
    _converged_install "${d}" || return 1
    h="$(sha256sum < "${d}/.env")"
    for _ in 1 2; do
        _setup_sh_run 'migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] && [ "$(sha256sum < "${d}/.env")" = "${h}" ] || { echo "rewrite: ${output}"; return 1; }
    done
}

# What: legacy keys migrate once; reruns change nothing
# Why: AG-OP-007 convergence; AG-OP-006 no second write
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update converges a legacy .env and is stable on rerun" {
    _registry || return 1
    local t before http https
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    _legacy_row() {
        t="${BATS_TEST_TMPDIR}/legacy-$1"
        mkdir -p "${t}" && _legacy_env "${t}/.env" || return 1
        export CONV="${t}"
    }
    _legacy_row strict-allowlist || return 1
    set_env_key PROXY_ALLOWED_CLIENT_CIDRS "$(_val cidr)" "${t}/.env"
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ "$(get_env_var PROXY_SECURITY_MODE "${t}/.env")" = strict ] \
        || { echo "strict-allowlist: $(get_env_var PROXY_SECURITY_MODE "${t}/.env") ${output}"; return 1; }
    _legacy_row split-cache || return 1
    set_env_key CACHE_DIR_SSL "$(_val path)" "${t}/.env"
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    _expect split-cache 1 "CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths" || return 1
    _legacy_row base || return 1
    http="$(get_env_var IP_STANDARD "${t}/.env")" https="$(get_env_var IP_SSL "${t}/.env")"
    set_env_key NATS_DNS_REPLICA_USER "$(_val name)" "${t}/.env" && set_env_key NATS_DNS_REPLICA_PASSWORD "$(_val name)" "${t}/.env"
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && ! env_key_exists CACHE_DIR_STANDARD "${t}/.env" && ! env_key_exists CACHE_DIR_SSL "${t}/.env" \
        && [ "$(get_env_var CACHE_DIR "${t}/.env")" = "${t}/cache" ] && [ "$(get_env_var PROXY_SECURITY_MODE "${t}/.env")" = lazy ] \
        && [[ "$(get_env_var LANCACHE_STATE_DIR "${t}/.env")" == /* ]] && [ -n "${http}" ] && [ "$(get_env_var IP_HTTP "${t}/.env")" = "${http}" ] \
        && [ "$(get_env_var IP_HTTPS "${t}/.env")" = "${https}" ] && ! env_key_exists IP_STANDARD "${t}/.env" && ! env_key_exists IP_SSL "${t}/.env" \
        && ! env_key_exists NATS_DNS_REPLICA_USER "${t}/.env" && ! env_key_exists NATS_DNS_REPLICA_PASSWORD "${t}/.env" \
        || { echo "legacy: ${output}"; cat "${t}/.env"; return 1; }
    _legacy_row logging-off || return 1
    set_env_key LOGGING_ENABLED 0 "${t}/.env"
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && ! env_key_exists LOGGING_ENABLED "${t}/.env" && ! env_key_exists LOGGING_PROXY_ENABLED "${t}/.env" \
        || { echo "logging: ${output}"; cat "${t}/.env"; return 1; }
    before="$(cat "${t}/.env")"
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ "$(cat "${t}/.env")" = "${before}" ] || { echo "second run changed .env"; return 1; }
}

# What: a DHCP NTP entry is an IPv4 or a DNS name
# Why: the prod .env lists host names; digits stay IPv4
# From: Issue #1683 | PR #1912
@test "setup.sh accepts DHCP NTP host names and rejects look-alikes" {
    local root row entry rc
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    while IFS='|' read -r row entry rc; do
        _setup_sh_run "is_valid_dhcp_ntp_server '${entry}'"
        [ "${status}" -eq "${rc}" ] || { echo "${row}: rc ${status} want ${rc}: ${output}"; return 1; }
    done <<'CASES'
ipv4|192.0.2.7|0
pool-name|debian.pool.ntp.org|0
short-name|ntp|0
bad-octet|256.1.1.1|1
three-octets|1.2.3|1
underscore|a_b.example|1
empty-label|a..b|1
semicolon|a;b|1
CASES
}

# What: a UI user without a usable password gets one, once
# Why: AG-OP-006: stable secrets never rotate on reruns
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update generates a UI password once, never rotates it" {
    _registry || return 1
    local t user pw real
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    _ui_row() {
        t="${BATS_TEST_TMPDIR}/ui-$1"
        mkdir -p "${t}" && _legacy_env "${t}/.env" "$2" || return 1
        export CONV="${t}"
        [ -z "${3:-}" ] || set_env_key UI_AUTH_PASSWORD "$3" "${t}/.env"
        _setup_sh_run 'migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "$1: rc ${status}: ${output}"; return 1; }
    }
    user="$(_val name)" real="$(_val name)"
    _ui_row gen "${user}" || return 1
    pw="$(get_env_var UI_AUTH_PASSWORD "${t}/.env")"
    [[ "${pw}" =~ ^[A-Za-z0-9]{20}$ ]] && [ "$(get_env_var UI_AUTH_USER "${t}/.env")" = "${user}" ] \
        || { echo "gen: user '$(get_env_var UI_AUTH_USER "${t}/.env")', password of ${#pw} chars"; return 1; }
    _setup_sh_run 'migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ "$(get_env_var UI_AUTH_PASSWORD "${t}/.env")" = "${pw}" ] || { echo "gen: password rotated"; return 1; }
    _ui_row no-user "" || return 1
    [ -z "$(get_env_var UI_AUTH_PASSWORD "${t}/.env")" ] || { echo "no-user: a password was made"; return 1; }
    _ui_row placeholder "${user}" "CHANGE_ME_$(_val name)" || return 1
    pw="$(get_env_var UI_AUTH_PASSWORD "${t}/.env")"
    [[ "${pw}" =~ ^[A-Za-z0-9]{20}$ ]] || { echo "placeholder: not replaced (${#pw} chars)"; return 1; }
    _ui_row kept "${user}" "${real}" || return 1
    [ "$(get_env_var UI_AUTH_PASSWORD "${t}/.env")" = "${real}" ] || { echo "kept: the operator password changed"; return 1; }
}

# What: a plaintext Admin UI password becomes its hash
# Why: no plaintext password stays on disk (AG-SEC-003)
# From: Issue #1683 | PR #1912
@test "ensure_ui_password_hash stores the hash and removes the plaintext" {
    _stand_ins || return 1
    local root d pw
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    d="${BATS_TEST_TMPDIR}/hash/deploy/prod"
    _prod_install "${d}" || return 1
    pw="$(_val name)"
    set_env_key UI_AUTH_PASSWORD "${pw}" "${d}/.env" || return 1
    export HD="${d}"
    _setup_sh_run 'ensure_ui_password_hash "${HD}" "${HD}/.env"'
    [ "${status}" -eq 0 ] || { echo "rc ${status}: ${output}"; return 1; }
    [ "$(get_env_var UI_AUTH_PASSWORD_HASH "${d}/.env")" = "$(printf '%s' "${pw}" | sha256sum | cut -c1-43)" ] \
        && ! env_key_exists UI_AUTH_PASSWORD "${d}/.env" && ! grep -qF -- "${pw}" "${d}/.env" "${DS}/docker.log" \
        || { echo "hash not stored or plaintext left: $(paste -sd'#' "${d}/.env")"; return 1; }
}

# What: reruns add no duplicate; a written key collapses
# Why: AG-OP-006: one canonical assignment per key
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update leaves no duplicate key assignments" {
    _registry || return 1
    local t="${BATS_TEST_TMPDIR}/dup"
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    mkdir -p "${t}" && _legacy_env "${t}/.env" || return 1
    printf 'PROXY_SECURITY_MODE=strict\n' >> "${t}/.env"
    [ "$(grep -c '^PROXY_SECURITY_MODE=' "${t}/.env")" -eq 2 ] || { echo "no duplicate in the input"; return 1; }
    export CONV="${t}"
    _setup_sh_run 'migrate_env_for_update "${CONV}" && migrate_env_for_update "${CONV}"'
    [ "${status}" -eq 0 ] && [ -z "$(awk -F= '/^[A-Za-z_]/ { print $1 }' "${t}/.env" | sort | uniq -d)" ] \
        || { echo "duplicates: $(awk -F= '/^[A-Za-z_]/ { print $1 }' "${t}/.env" | sort | uniq -d) ${output}"; return 1; }
    [ "$(grep '^PROXY_SECURITY_MODE=' "${t}/.env")" = PROXY_SECURITY_MODE=lazy ] \
        || { echo "collapse: $(grep '^PROXY_SECURITY_MODE=' "${t}/.env")"; return 1; }
}

# What: hand edits move to .env; bad ones change nothing
# Why: AG-OP-009 edits survive; the checkout stays clean
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update keeps config/prod values per row" {
    _registry || return 1
    local root ip srv srv2 net bios bad mode=dnsmasq-proxy name extra init envw edit want kv msg base pd cpe
    local -a kvs
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    ip="$(get_env_var IP_HTTP "$(_template_env)")" net="${ip%.*}"
    srv="${net}.$(( (${ip##*.} + 1) % 255 ))" srv2="${net}.$(( (${ip##*.} + 2) % 255 ))"
    bios="$(_val name).0" bad="$(_val host)"
    [ -n "${ip}" ] && is_valid_dhcp_mode "${mode}" || { echo "inputs: ip '${ip}', mode ${mode}"; return 1; }
    _cp_install() {
        base="${BATS_TEST_TMPDIR}/${1}" pd="${BATS_TEST_TMPDIR}/${1}/deploy/prod" cpe="${BATS_TEST_TMPDIR}/${1}/config/prod/dhcp-proxy.env"
        _prod_install "${pd}" || return 1
        # What: old tracked config/prod template, one key
        # Why: old checkouts carry it; update moves edits
        mkdir -p "${cpe%/*}" && printf 'DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=\n' > "${cpe}" || return 1
        [ "${2:-}" = nogit ] || { git -C "${base}" init -q && git -C "${base}" add config \
            && git -C "${base}" -c user.email=t@t -c user.name=t commit -qm template; } || return 1
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
        _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}" && migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "${name}: run 1: ${output}"; return 1; }
        IFS=';' read -r -a kvs <<< "${envw}"
        for kv in "${kvs[@]}"; do grep -qx -- "${kv}" "${pd}/.env" || { echo "${name}: .env lacks ${kv}"; return 1; }; done
        [ "${edit}" = - ] || set_env_key "${edit%%=*}" "${edit#*=}" "${cpe}"
        _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}" && migrate_env_for_update "${CONV}"'
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
        _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}"'
        cp "${pd}/.env" "${base}/env.before"
        _setup_sh_run 'migrate_env_for_update "${CONV}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${msg}"* && "${output}" == *"Restored ${pd}/.env to its state before the update"* ]] \
            && [[ "${output}" != *unreached* ]] && cmp -s "${base}/env.before" "${pd}/.env" && grep -qx -- "${kv}" "${cpe%.env}.local.env" \
            || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<CASES
incomplete-pair|DHCP_MODE=${mode};DHCP_SUBNET_START=${net}.0;DHCP_DNS_PRIMARY=${ip};UPSTREAM_DHCP_IP=${srv}|DHCP_PROXY_PXE_BOOT_SERVER=${srv}|neither DHCP_PROXY_PXE_BOOT_FILENAME_BIOS nor DHCP_PROXY_PXE_BOOT_FILENAME_UEFI is
invalid-value|DHCP_MODE=${mode};DHCP_SUBNET_START=${net}.0;DHCP_DNS_PRIMARY=${ip};UPSTREAM_DHCP_IP=${srv}|DHCP_PROXY_ROUTER=${bad}|must be a valid IPv4 address or empty.
CASES
    _cp_install only-changed || return 1
    [ "$(awk -F= '/^[A-Za-z_]/ { n++ } END { print n + 0 }' "${cpe}")" -ge 1 ] || { echo "only-changed: template has no key"; return 1; }
    set_env_key DHCP_PROXY_PXE_BOOT_SERVER "${srv}" "${cpe}"
    _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}"'
    [ "${status}" -eq 0 ] && git -C "${base}" diff --quiet HEAD -- config \
        && [ "$(awk -F= '/^[A-Za-z_]/ { print $1 }' "${cpe%.env}.local.env")" = DHCP_PROXY_PXE_BOOT_SERVER ] \
        || { echo "only-changed: rc ${status}: $(awk -F= '/^[A-Za-z_]/ { print $1 }' "${cpe%.env}.local.env" | tr '\n' ' ')"; return 1; }
    _cp_install deleted || return 1
    rm "${cpe}"
    _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}"'
    [ "${status}" -eq 0 ] && git -C "${base}" diff --quiet HEAD -- config && [ ! -e "${cpe%.env}.local.env" ] \
        || { echo "deleted: rc ${status}: ${output}"; return 1; }
    _cp_install no-git nogit || return 1
    set_env_key DHCP_PROXY_PXE_BOOT_SERVER "${srv}" "${cpe}"
    _setup_sh_run 'adopt_config_prod_edits "${CONV%/deploy/prod}"'
    [ "${status}" -eq 0 ] && [ "$(get_env_var DHCP_PROXY_PXE_BOOT_SERVER "${cpe}")" = "${srv}" ] && [ ! -e "${cpe%.env}.local.env" ] \
        || { echo "no-git: rc ${status}: ${output}"; return 1; }
}

# What: own state dirs stay; defaults drop; broken ones heal
# Why: AG-OP-009 keeps overrides; AG-OP-007 converges once
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update preserves all custom per-service state dirs" {
    _registry || return 1
    local d keys k first tv
    local -A own
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    _state_row() { d="${BATS_TEST_TMPDIR}/$1/deploy/prod"; _converged_install "${d}"; }
    _state_run() {
        _setup_sh_run 'migrate_env_for_update "${CONV}"'
        [ "${status}" -eq 0 ] || { echo "$1: rc ${status}: ${output}"; return 1; }
    }
    _state_row own || return 1
    keys="$(prod_state_keys | grep -vx CACHE_DIR)" first="${keys%%$'\n'*}"
    [ -n "${first}" ] || { echo "no state keys"; return 1; }
    while IFS= read -r k; do own["${k}"]="$(_val path)"; set_env_key "${k}" "${own[${k}]}" "${d}/.env"; done <<< "${keys}"
    for _ in 1 2; do
        _state_run own || return 1
        while IFS= read -r k; do
            [ "$(get_env_var "${k}" "${d}/.env")" = "${own[${k}]}" ] || { echo "own: ${k} lost"; return 1; }
        done <<< "${keys}"
    done
    _state_row templated || return 1
    tv="\${LANCACHE_STATE_DIR}/$(_val name)"
    set_env_assignment "${first}" "${tv}" "${d}/.env"
    _state_run templated || return 1
    [ "$(get_env_assignment_value_raw "${first}" "${d}/.env")" = "${tv}" ] \
        || { echo "templated: ${first}=$(get_env_assignment_value_raw "${first}" "${d}/.env")"; return 1; }
    _state_row default || return 1
    while IFS= read -r k; do
        set_env_key "${k}" "$(get_env_var LANCACHE_STATE_DIR "${d}/.env")/$(prod_state_subdir "${k}")" "${d}/.env"
    done <<< "${keys}"
    _state_run default || return 1
    while IFS= read -r k; do
        ! env_key_exists "${k}" "${d}/.env" || { echo "default: ${k} kept"; return 1; }
    done <<< "${keys}"
    _state_row broken || return 1
    set_env_key "${first}" "$(_val int 1 99)" "${d}/.env"
    _state_run broken || return 1
    ! env_key_exists "${first}" "${d}/.env" || { echo "broken: ${first}=$(get_env_var "${first}" "${d}/.env")"; return 1; }
    cp "${d}/.env" "${d}/env.run1"
    _state_run broken-rerun || return 1
    cmp -s "${d}/env.run1" "${d}/.env" || { echo "broken: run 2 changed .env"; return 1; }
}

# What: a bad IP_HTTPS stops the update; .env untouched
# Why: dns-https needs it (AG-SETUP-001, AG-OP-010)
# From: Issue #1683 | PR #1858
@test "migrate_env_for_update refuses an unusable IP_HTTPS before any write" {
    local t name val msg bad
    _load_setup_sh "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" || return 1
    bad="$(_val host)"
    while IFS='|' read -r name val msg; do
        t="${BATS_TEST_TMPDIR}/${name}"
        mkdir -p "${t}" && _legacy_env "${t}/.env" || return 1
        [ "${val}" != @HTTP_IP@ ] || val="$(get_env_var IP_STANDARD "${t}/.env")"
        set_env_key IP_SSL "${val}" "${t}/.env"
        cp "${t}/.env" "${t}/.env.before"
        export CONV="${t}"
        _setup_sh_run 'migrate_env_for_update "${CONV}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${msg}"* && "${output}" != *unreached* ]] \
            && cmp -s "${t}/.env.before" "${t}/.env" || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<ROWS
empty||IP_HTTPS is missing or empty in ${BATS_TEST_TMPDIR}/empty/.env
equal|@HTTP_IP@|IP_HTTP and IP_HTTPS must be different.
invalid|${bad}|IP_HTTPS is not a valid IPv4 address: ${bad}
ROWS
}

# What: deploy/prod state root is the SOT default
# Why: state stays off the checkout; compose and setup agree
# From: Issue #1683 | PR #1912
@test "production_state_root_default keeps deploy/prod state out of the checkout" {
    local co="${BATS_TEST_TMPDIR}/co" dp root binds other name expr msg want sot="${BATS_TEST_TMPDIR}/sot"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    dp="${co}/deploy/prod"
    _prod_install "${dp}" || return 1
    want="$(_ci_runtime_default LANCACHE_STATE_DIR)" || return 1
    run production_state_root_default "${dp}"
    _expect prod 0 "=${want}" || return 1
    [[ "${want}" == /* && "${want}/" != "${co}/"* ]] || { echo "prod: root ${want} is inside the checkout"; return 1; }
    binds="$(_prod_compose config --format json)" || { echo "prod: compose config failed"; return 1; }
    binds="$(jq -r '.services[].volumes[]? | select(.type == "bind") | .source' <<< "${binds}")"
    grep -q "^${want}/" <<< "${binds}" || { echo "prod: no state bind under ${want}: ${binds}"; return 1; }
    other="$(_val path)"
    run production_state_root_default "${other}"
    _expect other 0 "=${other}" || return 1
    mkdir -p "${sot}/.github/yaml" || return 1
    while IFS='@' read -r name expr msg; do
        sed "${expr}" "${root}/.github/yaml/build-manifest.yml" > "${sot}/.github/yaml/build-manifest.yml" || return 1
        SCRIPT_DIR="${sot}" run production_state_root_default "${dp}"
        _expect "${name}" 1 "${msg}" || return 1
    done <<ROWS
relative@s|^    - LANCACHE_STATE_DIR=.*|    - LANCACHE_STATE_DIR=$(_val name)|@no absolute path
none@/^    - LANCACHE_STATE_DIR=/d@holds no default for LANCACHE_STATE_DIR
ROWS
}

# What: state, settings and CA move to deploy/prod once
# Why: AG-OP-007: a quickstart user loses nothing
# From: Issue #1683 | PR #1858
@test "setup quickstart install moves into deploy/prod once" {
    _registry || return 1
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" cfg project svc keys key want vol dir absent copies f el lo prof old
    local -a profiles=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    require_helper_image || return 1
    export ROOT="${root}" CO="${t}/co" QS="${t}/qs" BK="${t}/bk"
    _prod_install "${CO}/deploy/prod" || return 1
    cfg="$(_prod_compose config --format json)" && project="$(jq -r .name <<< "${cfg}")" \
        && svc="$(jq -r '.services | keys[0]' <<< "${cfg}")" || { echo "prod compose: ${cfg}"; return 1; }
    keys="$(quickstart_path_keys)" && keys="${keys//$'\n'/ }" && copies="$(quickstart_bundle_copies)" \
        && [ -n "${keys}" ] && [ -n "${copies}" ] || { echo "migration lists: ${keys} | ${copies}"; return 1; }
    lo="127.$(_val int 1 254).$(_val int 1 254)"
    mkdir -p "${QS}/certs" && cp "$(_template_env)" "${QS}/.env" && remove_env_key LANCACHE_STATE_DIR "${QS}/.env" \
        && set_env_key IP_HTTP "${lo}.1" "${QS}/.env" && set_env_key IP_HTTPS "${lo}.2" "${QS}/.env" || return 1
    for key in ${keys}; do set_env_key "${key}" "./${key,,}" "${QS}/.env" || return 1; done
    old="$(get_env_var LANCACHE_IMAGE_REGISTRY "${QS}/.env")/$(get_env_var LANCACHE_IMAGE_PREFIX "${QS}/.env")/" \
        && sed -i "s#^\(LANCACHE_IMAGE_REF_[A-Z_]*=\)${old}#\1${LANCACHE_IMAGE_REGISTRY}/${LANCACHE_IMAGE_PREFIX}/#" "${QS}/.env" \
        && set_env_key LANCACHE_IMAGE_REGISTRY "${LANCACHE_IMAGE_REGISTRY}" "${QS}/.env" \
        && set_env_key LANCACHE_IMAGE_PREFIX "${LANCACHE_IMAGE_PREFIX}" "${QS}/.env" || return 1
    want="$(get_env_var CACHE_MAX_SIZE "${QS}/.env")" \
        && set_env_key CACHE_MAX_SIZE "$(( ${want%%[!0-9]*} * 2 ))${want##*[0-9]}" "${QS}/.env" \
        && cp "${QS}/.env" "${t}/qs.env" || return 1
    while IFS= read -r f; do
        mkdir -p "$(dirname "${QS}/${f}")" && printf '%s\n' "${f}" > "${QS}/${f}" || return 1
    done <<< "${copies}"
    printf '%s\n' "${QS}" > "${QS}/certs/ca.crt" && printf '%s\n' "${t}" > "${QS}/certs/ca.key" || return 1
    {
        printf 'name: %s\nservices:\n  %s:\n    image: %s\n    volumes:\n' "${project}" "${svc}" "${LANCACHE_HELPER_IMAGE}"
        quickstart_volume_keys | awk '{ printf "      - %s:/%s\n", $1, $1 }'
        printf 'volumes:\n'
        quickstart_volume_keys | awk '{ printf "  %s: {}\n", $1 }'
    } > "${QS}/docker-compose.yml" || return 1
    absent="$(quickstart_volume_keys | awk 'END { print $1 }')"
    while read -r vol key; do
        [ "${vol}" != "${absent}" ] || continue
        mkdir -p "${DS}/volumes/${project}_${vol}" && printf '%s\n' "${vol}" > "${DS}/volumes/${project}_${vol}/${vol}" \
            && printf '%s\n' "${key}" > "${DS}/volumes/${project}_${vol}/.${key}" || return 1
    done <<< "$(quickstart_volume_keys)"
    : > "${DS}/running" && _listen80 "${lo}.1" "${lo}.2" || return 1
    _setup_sh_run 'SCRIPT_DIR="${CO}" BACKUP_ROOT="${BK}" PROD_COMPOSE="${CO}/${PROD_COMPOSE#"${ROOT}/"}"
        is_quickstart_install "${QS}" && migrate_quickstart_install "${QS}"'
    [ "${status}" -eq 0 ] || { echo "migrate: ${output}"; return 1; }
    el="$(runtime_env_file_for_install_dir "${CO}/deploy/prod")" || return 1
    [ "${el}" != "${CO}/deploy/prod/.env" ] && [ "$(stat -c %a "${el}")" = 600 ] || { echo "env: ${el}"; return 1; }
    [ "$(get_env_var LANCACHE_STATE_DIR "${el}")" = "${QS}" ] || { echo "state root"; return 1; }
    while IFS= read -r key; do
        want="$(get_env_assignment_value_raw "${key}" "${t}/qs.env")" || return 1
        [[ " ${keys} " != *" ${key} "* ]] || want="$(realpath -m "${QS}/${want}")"
        [ "$(get_env_assignment_value_raw "${key}" "${el}")" = "${want}" ] \
            || { echo "value of ${key}: want ${want} got $(get_env_assignment_value_raw "${key}" "${el}")"; return 1; }
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
    awk -v q="compose --env-file ${QS}/.env " -v p="compose --env-file ${el} " '
        index($0, q) == 1 && / stop$/ { st = NR }
        index($0, q) == 1 && / up -d$/ { su = NR }
        index($0, p) == 1 && / up -d / && !pu { pu = NR }
        END { exit !(st > su && pu > st) }' "${DS}/docker.log" || { cat "${DS}/docker.log"; return 1; }
    ! is_quickstart_install "${QS}" || { echo "still quickstart"; return 1; }
    [ "$(resolve_stack_dir "${CO}")" = "${CO}/deploy/prod" ] && [ "$(resolve_stack_dir "${QS}")" = "${QS}" ] \
        || { echo "stack dirs"; return 1; }
    prof="$(docker compose --env-file "${el}" -f "${CO}/deploy/prod/docker-compose.yml" config --profiles)" || return 1
    while IFS= read -r f; do [ -z "${f}" ] || profiles+=(--profile "${f}"); done <<< "${prof}"
    cfg="$(docker compose --env-file "${el}" -f "${CO}/deploy/prod/docker-compose.yml" "${profiles[@]}" config --format json)" \
        || { echo "prod config: ${cfg}"; return 1; }
    want="$(get_env_var CACHE_MAX_SIZE "${t}/qs.env")" || return 1
    jq -e --arg v "${want}" '[.services[].environment.CACHE_MAX_SIZE?] | index($v) != null' <<< "${cfg}" > "${t}/jq.out" \
        || { echo "CACHE_MAX_SIZE ${want} not in the prod stack"; return 1; }
    for key in ${keys}; do
        want="$(get_env_var "${key}" "${el}")" || return 1
        grep -qF "\"${want}\"" <<< "${cfg}" || { echo "${key}=${want} not in the prod stack"; return 1; }
    done
}

# What: update pulls, reruns the new setup.sh, rolls back
# Why: compose, templates, script move as one revision
# From: Issue #1683 | PR #1858
@test "setup update pulls the checkout and continues on its setup.sh" {
    _registry || return 1
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" main lo http https svc mark em line out c2 c3
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    require_helper_image || return 1
    main="$(_val name)" svc="$(_val name)" mark="$(_val name)" em="$(_val name)@$(_val host)"
    lo="127.$(_val int 1 254).$(_val int 1 254)"
    http="${lo}.1" https="${lo}.2"
    g() { git -c user.email="${em}" -c user.name="${main}" -c init.defaultBranch="${main}" "$@"; }
    g init -q --bare "${t}/origin.git" && _checkout_copy "${root}" "${t}/src" && g -C "${t}/src" init -q \
        && g -C "${t}/src" add -A && g -C "${t}/src" commit -q -m c1 \
        && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}" && g clone -q "${t}/origin.git" "${t}/co" \
        && cp "$(_template_env)" "${t}/co/deploy/prod/.env.local" || { echo "origin setup failed"; return 1; }
    set_env_key LANCACHE_STATE_DIR "${t}/state" "${t}/co/deploy/prod/.env.local" \
        && set_env_key IP_HTTP "${http}" "${t}/co/deploy/prod/.env.local" \
        && set_env_key IP_HTTPS "${https}" "${t}/co/deploy/prod/.env.local" \
        && set_env_key LANCACHE_IMAGE_TAG "$(_release_tag)" "${t}/co/deploy/prod/.env.local" || return 1
    out="$(g -C "${t}/co" status --porcelain)" && [ -z "${out}" ] || { echo "fixture checkout is dirty: ${out}"; return 1; }
    line="printf '%s\n' ${mark} >&2"
    printf '  %s:\n    image: %s\n' "${svc}" "${LANCACHE_HELPER_IMAGE}" > "${t}/svc.yml" \
        && awk -v add="${t}/svc.yml" '{ print } /^services:$/ { while ((getline l < add) > 0) print l }' \
        "${t}/src/deploy/prod/docker-compose.yml" > "${t}/c.yml" && mv "${t}/c.yml" "${t}/src/deploy/prod/docker-compose.yml" \
        && grep -qx "  ${svc}:" "${t}/src/deploy/prod/docker-compose.yml" \
        && L="${line}" awk 'NR == 2 { print ENVIRON["L"] } { print }' "${t}/src/setup.sh" > "${t}/s.sh" \
        && cat "${t}/s.sh" > "${t}/src/setup.sh" && g -C "${t}/src" commit -q -am c2 \
        && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}" && c2="$(g -C "${t}/src" rev-parse HEAD)" \
        || { echo "revision 2 not published"; return 1; }
    _listen80 "${http}" "${https}" || return 1
    FAULT="$(_val name)" CO="${t}/co"
    export FAULT CO
    _update() {
        run env DOCKER_HOST="${SETUP_SH_DOCKER_HOST}" LANCACHE_BACKUP_ROOT="${t}/bk" bash "${CO}/setup.sh" update "${CO}/deploy/prod"
    }
    _update
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] \
        && [ "$(grep -cxF -- "${mark}" <<< "${output}")" -eq 1 ] \
        && [ "$(grep -c "Continuing the update with" <<< "${output}")" -eq 1 ] \
        && grep -qE "^compose .* up -d --remove-orphans .*\b${svc}\b" "${DS}/docker.log" \
        || { echo "update: ${output}"; return 1; }
    g -C "${t}/src" commit -q --allow-empty -m c3 && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}" \
        && c3="$(g -C "${t}/src" rev-parse HEAD)" && cp "${t}/co/deploy/prod/.env.local" "${t}/env.before" \
        && : > "${DS}/fail-apply" || { echo "revision 3 not published"; return 1; }
    _update
    rm -f "${DS}/fail-apply" || return 1
    [ "${status}" -eq 1 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${c2}" ] \
        && [[ "${output}" == *"Returned ${t}/co to ${c2}"* && "${output}" == *"rolled back"* ]] \
        && cmp -s "${t}/env.before" "${t}/co/deploy/prod/.env.local" \
        || { echo "rollback to ${c2} from ${c3}: ${output}"; return 1; }
    g -C "${t}/co" checkout -q --detach || return 1
    _update
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

# What: list-prompts walks the real wizard, no side effects
# Why: the release validation plan derives prompts from it
# From: Issue #1683 | PR #1858
@test "setup list-prompts walks the real wizard without side effects" {
    local root t="${BATS_TEST_TMPDIR}" tpl http other dev pfx lo https k base preset modes m dhcp ddir add v d p try
    local -a ans=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    # What: the walk runs on a checkout copy
    # Why: a side effect must not reach the real checkout
    # From: Issue #1683 | PR #1858
    _checkout_copy "${root}" "${t}/repo" || { echo "checkout copy failed"; return 1; }
    tpl="$(_template_env)"
    http="10.$(_val int 0 127).$(_val int 0 255).$(_val int 1 254)" dev="$(_val name)" pfx="$(_val int 16 30)"
    other="10.$(_val int 128 255).$(_val int 0 255).$(_val int 1 254)"
    lo="127.$(_val int 0 255).$(_val int 0 255).$(_val int 1 254)"
    [ "${http}" != "$(get_env_var IP_HTTP "${tpl}")" ] || { echo "host address equals the template's"; return 1; }
    export IPDS="${t}/ipds" SETUP="${t}/repo/setup.sh" ANS="${t}/answers" PRESET=""
    mkdir -p "${IPDS}"
    _ip_stub "${t}/ipbin"
    _host() {
        rm -f "${IPDS}/fail-addr"
        printf '%s\n' "${lo} 8 lo" "$@" > "${IPDS}/addrs"
        printf '%s %s\n' "${http}" "${dev}" > "${IPDS}/src"
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
    _host "${http} ${pfx} ${dev}"
    _lp
    [ "${status}" -eq 0 ] || { echo "defaults: ${output}"; return 1; }
    base="$(_prompts)"
    # What: default is the detected IP; offer uses its link
    # Why: AG-SEC-007; no guessed address, device or mask
    # From: Issue #1683 | PR #1858
    k="$(awk -F'\t' -v ip="${http}" '$1 == "PROMPT" { n++; if ($3 == ip) { print n; exit } }' <<< "${output}")"
    https="$(_default $(( k + 1 )))"
    [ -n "${k}" ] && [ -n "${https}" ] && [ "${https}" != "${http}" ] \
        && [[ "${output}" == *"${http}/${pfx} dev ${dev}"* && "${output}" != *"${lo}/8"* ]] \
        && [[ "${base}" == *"${https}/${pfx} dev ${dev}"* ]] || { echo "detection: ${output}"; return 1; }
    add="$(grep -nF -- "${https}/${pfx} dev ${dev}" <<< "${base}" | cut -d: -f1)"
    # What: no address: no default, and a fail, not a loop
    # Why: AG-OP-008; the operator must enter the address
    # From: Issue #1683 | PR #1858
    : > "${IPDS}/fail-addr"; rm -f "${IPDS}/src"
    _lp
    [ "${status}" -ne 0 ] && [ "${status}" -ne 124 ] && [ -z "$(_default "${k}")" ] \
        && [[ "${output}" == *"rejected its answer"* ]] || { echo "no detection: rc ${status}: ${output}"; return 1; }
    printf '%s' "${http}" > "${ANS}"
    _lp "${ANS}"
    [ "${status}" -eq 0 ] || { echo "unterminated last answer lost: ${output}"; return 1; }
    # What: assigned IP_HTTPS: no offer; foreign IP: none
    # Why: the add offer exists only for a known device
    # From: Issue #1683 | PR #1858
    _host "${http} ${pfx} ${dev}" "${https} ${pfx} ${dev}"
    _lp
    [ "${status}" -eq 0 ] && [[ "$(_prompts)" != *"${https}/"* && "${output}" == *"${https} already assigned"* ]] \
        || { echo "assigned: ${output}"; return 1; }
    _host "${http} ${pfx} ${dev}"
    ans=(); ans[$(( k - 1 ))]="${other}"; _write_ans
    _lp "${ANS}"
    [ "${status}" -eq 0 ] && [[ "$(_prompts)" != *" dev "* && "${output}" == *"interface that carries ${other}"* ]] \
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
    modes="$(_rust_dhcp_modes "${root}")" || return 1
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
            if [ "$(_default "${p}")" = N ]; then ans[p-1]=y; else ans[p-1]="${http}"; fi
        done
        d="$(awk -F'\t' 'NR == FNR { b[$0] = 1; next } $1 == "PROMPT" && !($2 in b) { print $3 }' "${t}/base-prompts" - <<< "${output}")"
        p="$(awk -F'\t' 'NR == FNR { b[$0] = 1; next } $1 == "PROMPT" && !($2 in b)' "${t}/base-prompts" - <<< "${output}" | wc -l)"
        if [ "${v}" = "${m}" ]; then [ "${p}" -eq 0 ]; else [ "${p}" -gt 0 ]; fi && [ "${status}" -eq 0 ] \
            || { echo "mode ${v}: rc ${status}, ${p} own prompts: ${output}"; return 1; }
        printf '%s\n' "${d}" >> "${t}/extra-defaults"
    done <<< "${modes}"
    for v in DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END; do
        d="$(_ci_runtime_default "${v}")" || return 1
        grep -qxF -- "${d}" "${t}/extra-defaults" || { echo "${v} default not from the template"; return 1; }
    done
    d="$(_ci_runtime_default DHCP_SUBNET)" || return 1
    grep -qxF -- "${d%/*}" "${t}/extra-defaults" || { echo "subnet start default not from the template"; return 1; }
    # What: no template DHCP default is literal in setup.sh
    # Why: one owner of the defaults; a copy passes above
    # From: Issue #1683 | PR #1858
    for v in DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END; do
        d="$(_ci_runtime_default "${v}")" || return 1
        for p in "${d}" "${d%/*}"; do
            if grep -qwF -- "${p}" "${SETUP}"; then echo "${v} default ${p} is a literal in setup.sh"; return 1; fi
        done
    done
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

# What: the real wizard installs a checkout copy
# Why: values come from the template and the host only
# From: Issue #1683 | PR #1858
@test "setup fresh install writes a config the prod compose takes" {
    _registry || return 1
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" repo env tpl cfg port http other dev pfx keys k v ddir np i calls after fault
    [ ! -d /run/systemd/system ] || { echo "systemd host: a real install would write /etc units"; return 1; }
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    repo="${t}/repo" env="${t}/repo/deploy/prod/.env.local" tpl="$(_template_env)"
    _checkout_copy "${root}" "${repo}" || { echo "checkout copy failed"; return 1; }
    cfg="$(docker compose --env-file "${tpl}" -f "${repo}/deploy/prod/docker-compose.yml" config --format json)" \
        && port="$(jq -r '.services.ui.ports[0].published' <<< "${cfg}")" && [[ "${port}" =~ ^[0-9]+$ ]] \
        || { echo "prod compose config: ${cfg}"; return 1; }
    keys="$(_ci_runtime_defaults | sed -n 's/=.*//p')" && [ -n "${keys}" ] \
        || { echo "no SOT runtime.defaults keys: ${keys}"; return 1; }
    # What: setup.sh holds no SOT default or ui port
    # Why: one owner each; a copy passes the checks below
    # From: Issue #1683 | PR #1912
    if grep -qw -- "${port}" "${repo}/setup.sh"; then echo "ui port ${port} is a literal in setup.sh"; return 1; fi
    for k in ${keys}; do
        v="$(_ci_runtime_default "${k}")" || return 1
        [ -n "${v}" ] || continue
        # What: a wizard y is the on-value, not a default
        # Why: the prompt default N is the operator's pick.
        # From: Issue #1683 | PR #1912
        [ "${k}" != HTTPS_ENABLED ] || { grep -qF -e "${k}:-${v}" "${repo}/setup.sh" && { echo "${k} default ${v} is a literal in setup.sh"; return 1; }; continue; }
        if grep -qF -e "${k}=${v}" -e "${k}:-${v}" "${repo}/setup.sh"; then
            echo "${k} default ${v} is a literal in setup.sh"
            return 1
        fi
    done
    http="10.$(_val int 0 127).$(_val int 0 255).$(_val int 1 254)" dev="$(_val name)" pfx="$(_val int 16 30)"
    other="10.$(_val int 128 255).$(_val int 0 255).$(_val int 1 254)"
    [ "${http}" != "$(get_env_var IP_HTTP "${tpl}")" ] || { echo "host address equals the template's"; return 1; }
    ID_REAL="$(type -P id)" || return 1
    export IPDS="${t}/ipds" REPO="${repo}" ENVL="${env}" ID_REAL
    mkdir -p "${IPDS}" && _ip_stub "${BIN}" \
        && printf '%s\n' "127.$(_val int 0 255).$(_val int 0 255).$(_val int 1 254) 8 lo" "${other} ${pfx} ${dev}" \
        "${http} ${pfx} ${dev}" > "${IPDS}/addrs" && printf '%s %s\n' "${http}" "${dev}" > "${IPDS}/src" || return 1
    _tool_stub "${BIN}" id <<<'[ "$*" != -u ] || { echo 0; exit 0; }; exec "${ID_REAL:?}" "$@"' || return 1
    LANCACHE_IMAGE_TAG="$(_release_tag)" || return 1
    export LANCACHE_IMAGE_CHANNEL=pinned LANCACHE_IMAGE_TAG
    run timeout -k 5 120 bash "${repo}/setup.sh" list-prompts
    [ "${status}" -eq 0 ] || { echo "prompts: ${output}"; return 1; }
    ddir="$(awk -F'\t' -v d="$(production_state_root_default "${repo}/deploy/prod")" \
        '$1 == "PROMPT" { n++; if ($3 == d) { print n; exit } }' <<< "${output}")"
    np="$(grep -cP '^PROMPT\t' <<< "${output}")"
    [ -n "${ddir}" ] && [ "${np}" -gt 0 ] || { echo "no state dir prompt: ${output}"; return 1; }
    for ((i = 1; i <= np; i++)); do
        if [ "${i}" -eq "${ddir}" ]; then printf '%s\n' "${t}/state"; else printf '\n'; fi
    done > "${t}/answers" || return 1
    calls=0
    [ ! -e "${DS}/docker.log" ] || calls="$(wc -l < "${DS}/docker.log")"
    run timeout -k 5 60 bash "${repo}/setup.sh"
    after=0
    [ ! -e "${DS}/docker.log" ] || after="$(wc -l < "${DS}/docker.log")"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Usage:"* ]] && [ ! -e "${env}" ] && [ "${after}" -eq "${calls}" ] \
        || { echo "no command: rc ${status} docker calls ${calls}->${after}: ${output}"; return 1; }
    run timeout -k 5 300 script -qec "bash ${repo}/setup.sh install" "${t}/typescript" < "${t}/answers"
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Stack started"* ]] || { echo "install: rc ${status}: ${output}"; return 1; }
    [[ "${output}" == *"http://${http}:${port}"* ]] || { echo "ui url: ${output}"; return 1; }
    [ "$(awk -v e="compose --env-file ${env} " 'index($0, e) == 1 && ($NF == "pull" || / up -d$/) { n++ } END { print n + 0 }' \
        "${DS}/docker.log")" -eq 2 ] || { echo "pull/up: $(cat "${DS}/docker.log")"; return 1; }
    _setup_sh_run 'stack_compose "${REPO}/deploy/prod" "${ENVL}" config --quiet'
    [ "${status}" -eq 0 ] || { echo "compose config: ${output}"; return 1; }
    # What: no SOT default lands in .env.local
    # Why: wizard answers stay; SOT defaults are not copied
    # From: Issue #1683 | PR #1912
    for k in ${keys}; do
        exempt=" CACHE_MAX_SIZE CACHE_MEM_MB DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END ALLOW_INSECURE_UI NTP_ENABLED HTTPS_ENABLED DHCP_MODE KEA_DATA_DIR LANCACHE_STATE_DIR CACHE_DIR "
        case "${exempt}" in *" ${k} "*) continue ;; esac
        [ -z "$(get_env_var "${k}" "${env}")" ] || { echo "${k} was copied into .env.local: $(cat "${env}")"; return 1; }
    done
    [ "$(get_env_var IP_HTTP "${env}")" = "${http}" ] && ! env_key_exists UI_AUTH_PASSWORD "${env}" \
        && [ -n "$(get_env_var UI_AUTH_PASSWORD_HASH "${env}")" ] \
        && ! env_key_exists COMPOSE_PROFILES "${env}" || { echo "values: $(cat "${env}")"; return 1; }
    _checkout_copy "${root}" "${t}/repo2" && rm -f "${DS}/running" && : > "${DS}/fail-config-after-up" \
        || { echo "second copy failed"; return 1; }
    fault="$(_val name)"
    FAULT="${fault}" run timeout -k 5 300 script -qec "bash ${t}/repo2/setup.sh install" "${t}/typescript2" < "${t}/answers"
    rm -f "${DS}/fail-config-after-up" || return 1
    [ "${status}" -eq 0 ] && [[ "${output}" == *"Stack started"* && "${output}" == *"Cannot derive the Admin-UI URL"* ]] \
        && [[ "${output}" == *"${fault}"* ]] || { echo "url failure: rc ${status}: ${output}"; return 1; }
}

# What: every repo input compose mounts or reads is listed
# Why: update rollback restores exactly those (AG-OP-010)
# From: Issue #1683 | PR #1858
@test "deploy_prod_repo_input_paths snapshots repo-root runtime inputs for deploy/prod" {
    local root dp paths json inputs i p ok other
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    dp="${root}/deploy/prod"
    paths="$(deploy_prod_repo_input_paths "${dp}")" || { echo "owner rc $?"; return 1; }
    json="$(NATS_BIND_IP="$(get_env_var IP_HTTP "$(_template_env)")" _prod_compose config --format json)" \
        || { echo "compose config failed"; return 1; }
    inputs="$(jq -r --arg r "${root}/" '[.services[] | ((.volumes // [])[] | select(.type == "bind") | .source),
        ((.env_file // [])[] | if type == "object" then .path else . end)] | unique[] | select(startswith($r))' <<< "${json}")"
    [ -n "${inputs}" ] && [ -n "${paths}" ] || { echo "inputs: ${inputs} | paths: ${paths}"; return 1; }
    while IFS= read -r i; do
        [ -e "${i}" ] || { echo "compose input ${i} is missing in the checkout"; return 1; }
        ok=0
        while IFS= read -r p; do [ "${i}" != "${p}" ] && [[ "${i}" != "${p}/"* ]] || ok=1; done <<< "${paths}"
        [ "${ok}" -eq 1 ] || { echo "compose input ${i} not in the backup list"; return 1; }
    done <<< "${inputs}"
    while IFS= read -r p; do [[ "${p}" == "${root}/"* && -e "${p}" ]] || { echo "listed ${p} is no repo path"; return 1; }; done <<< "${paths}"
    _checkout_copy "${root}" "${BATS_TEST_TMPDIR}/repo" || return 1
    other="${BATS_TEST_TMPDIR}/repo/deploy/$(_val name)"
    mkdir -p "${other}" && cp "${dp}"/docker-compose*.y*ml "${other}/" || return 1
    run deploy_prod_repo_input_paths "${other}"
    _expect non-prod 0 "=" || return 1
}

# =========================================================
# PRODUCT RUNTIME: SHARED SECRETS
# =========================================================

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

# What: setup.sh detector vs its shared fixture column.
# Why: setup must refuse what the Rust services refuse.
# From: Issue #967 | PR #1912
@test "setup.sh placeholder detection matches the shared fixture" {
    local root fx value _shared setup _r got n=0
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    fx="${root}/tests/fixtures/placeholder-detection-cases.txt"
    # shellcheck source=setup.sh
    source "$(_extract_functions "${root}/setup.sh" secret_value_is_placeholder)"
    while read -r value _shared setup _r; do
        case "${value}" in ''|\#*) continue ;; esac
        n=$((n + 1))
        if secret_value_is_placeholder "${value}"; then got=placeholder; else got=real; fi
        [ "${got}" = "${setup}" ] || { echo "setup.sh: ${value} got ${got} want ${setup}"; return 1; }
    done < "${fx}"
    [ "${n}" -gt 0 ]
    secret_value_is_placeholder ""
}

# What: each ref kind pins its commit; the fallback is SOT's
# Why: an operator ref must pin exactly that revision
# From: Issue #1683 | PR #1858
@test "setup bootstrap ref pins the checkout per ref kind" {
    local root t="${BATS_TEST_TMPDIR}" main tagsha brsha mainsha ref want err cur nb sot
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    TAG="v$(_val semver)" BR="$(_val name)" main="$(_val name)" nb="$(_val name)"
    export T="${t}" TAG BR REF
    g() { git -c user.email=t@example.test -c user.name=t -c init.defaultBranch="${main}" "$@"; }
    g init -q --bare "${t}/origin.git" && g init -q "${t}/src" && g -C "${t}/src" commit -q --allow-empty -m c1 \
        && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}" && g -C "${t}/src" tag "${TAG}" \
        && g -C "${t}/src" push -q "${t}/origin.git" "${TAG}" && g -C "${t}/src" commit -q --allow-empty -m c2 \
        && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${main}" || { echo "origin setup failed"; return 1; }
    mainsha="$(g -C "${t}/src" rev-parse HEAD)" && tagsha="$(g -C "${t}/src" rev-parse "${TAG}^{commit}")" || return 1
    g -C "${t}/src" checkout -q -b "${BR}" && g -C "${t}/src" commit -q --allow-empty -m d1 \
        && g -C "${t}/src" push -q "${t}/origin.git" "HEAD:refs/heads/${BR}" || { echo "branch setup failed"; return 1; }
    brsha="$(g -C "${t}/src" rev-parse HEAD)" && g clone -q "${t}/origin.git" "${t}/co" || return 1
    _setup_sh_run 'unset LANCACHE_SETUP_GIT_REF; resolve_setup_bootstrap_ref'
    [ "${status}" -eq 0 ] && [ -z "${output}" ] || { echo "unset ref: ${output}"; return 1; }
    _setup_sh_run 'LANCACHE_SETUP_GIT_REF="${TAG}" resolve_setup_bootstrap_ref'
    [ "${status}" -eq 0 ] && [ "${output}" = "${TAG}" ] || { echo "set ref: ${output}"; return 1; }
    while read -r ref want; do
        REF="${ref}"
        _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"'
        [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${want}" ] || { echo "${ref}: ${output}"; return 1; }
    done <<CASES
${TAG} ${tagsha}
${BR} ${brsha}
${tagsha} ${tagsha}
CASES
    _setup_sh_run 'print_error ""'
    [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "print_error: ${output}"; return 1; }
    err="${output}"
    aborted_on() {
        local e
        e="$(awk -v p="${err}" 'index($0, p) == 1' <<< "${output}")"
        [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* && "$(wc -l <<< "${e}")" -eq 1 && "${e}" == *"$1"* ]] \
            || return 1
    }
    REF="missing-${BR}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"; echo unreached'
    aborted_on "Failed to fetch ref '${REF}'" || { echo "missing ref: ${output}"; return 1; }
    _setup_sh_run 'sync_repo_to_default_branch "${T}/co"'
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "default: ${output}"; return 1; }
    g -C "${t}/co" remote set-head origin --delete || return 1
    REF="${BR}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}" && sync_repo_to_default_branch "${T}/co"'
    [ "${status}" -eq 0 ] && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "no origin/HEAD: ${output}"; return 1; }
    g init -q "${t}/noorigin" || return 1
    _setup_sh_run 'git_default_branch_name "${T}/noorigin"; echo unreached'
    aborted_on "Failed to read the remote origin of ${t}/noorigin" || { echo "noorigin: ${output}"; return 1; }
    g init -q --bare "${t}/nohead.git" && g init -q "${t}/unknown" \
        && g -C "${t}/unknown" remote add origin "${t}/nohead.git" || { echo "nohead setup failed"; return 1; }
    _setup_sh_run 'git_default_branch_name "${T}/unknown"; echo unreached'
    aborted_on "Failed to read the release branch from the SOT of ${t}/unknown" || { echo "no SOT: ${output}"; return 1; }
    cur="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_release_ref)" || return 1
    sot="${t}/unknown/${CI_MANIFEST_REL}"
    mkdir -p "${t}/unknown/${CI_SCRIPT_DIR#"${CI_REPO_ROOT}/"}" "${sot%/*}" \
        && cp "${CI_SH}" "${t}/unknown/${CI_SCRIPT_DIR#"${CI_REPO_ROOT}/"}/" || return 1
    export CI_MANIFEST="${CI_MANIFEST_SOURCE}" CI_REPO_ROOT ERR="${t}/stderr"
    sot_ref() {
        sed "s|^\( *ref: \)${cur//./\\.}\$|\1$1|" "${CI_MANIFEST_SOURCE}" > "${sot}" \
            && [ "$(CI_MANIFEST="${sot}" _ci_release_ref)" = "$1" ] || { echo "SOT ref ${cur} not set to $1"; return 1; }
    }
    sot_ref "refs/heads/${nb}" || return 1
    _setup_sh_run 'git_default_branch_name "${T}/unknown" 2> "${ERR}"; echo unreached'
    [ "${status}" -eq 0 ] && [ "${output}" = "${nb}"$'\n'unreached ] && ! grep -qF -- "${err}" "${ERR}" \
        || { echo "SOT branch: ${output} | $(cat "${ERR}")"; return 1; }
    sot_ref "refs/tags/${nb}" || return 1
    _setup_sh_run 'git_default_branch_name "${T}/unknown"; echo unreached'
    aborted_on "The SOT of ${t}/unknown names no release branch ref: 'refs/tags/${nb}'" || { echo "SOT tag: ${output}"; return 1; }
    printf '%s\n' "${BR}" > "${t}/co/${BR}.txt" || return 1
    REF="${TAG}"
    _setup_sh_run 'sync_repo_to_ref "${T}/co" "${REF}"; echo unreached'
    aborted_on "has local changes" && [ -f "${t}/co/${BR}.txt" ] \
        && [ "$(g -C "${t}/co" rev-parse HEAD)" = "${mainsha}" ] || { echo "dirty: ${output}"; return 1; }
}

# What: UI_BIND_IP follows IP_HTTP; one tag on stdout
# Why: an update keeps operator values and pins one tag
# From: Issue #1683 | PR #1858
@test "setup env migration and release image tag per input" {
    local root t="${BATS_TEST_TMPDIR}" ip v raw case lines want err rc tags tag bad sot PIN REL CH ALIAS
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    ip="$(get_env_var IP_HTTP "$(_template_env)")"
    v="$(tr -d '[:space:]' < "${root}/VERSION")"
    raw="\"$(_val path) $(_val name)\" # $(_val name)" bad="$(_val name)"
    [ -n "${ip}" ] && [ -n "${v}" ] || { echo "inputs: ${ip} ${v}"; return 1; }
    export E="${t}/.env" IP="${ip}" ERR="${t}/stderr"
    while IFS='|' read -r case lines want; do
        printf '%b' "${lines}" > "${E}"
        _setup_sh_run 'append_env_migrated_assignment_if_missing UI_BIND_IP IP_HTTP "${IP}" "${E}"'
        [ "${status}" -eq 0 ] && [ "$(paste -sd'#' "${E}")" = "${want}" ] || { echo "${case}: $(paste -sd'#' "${E}")"; return 1; }
    done <<CASES
emptytarget|IP_HTTP=${ip}\nUI_BIND_IP=\n|IP_HTTP=${ip}#UI_BIND_IP=
copysyntax|IP_HTTP=${raw}\n|IP_HTTP=${raw}#UI_BIND_IP=${raw}
keep|IP_HTTP=${ip}\nUI_BIND_IP=${t}\n|IP_HTTP=${ip}#UI_BIND_IP=${t}
fallback|IP_HTTP=\n|IP_HTTP=#UI_BIND_IP=${ip}
CASES
    printf '%s\n' "IP_HTTP=" > "${E}"
    _setup_sh_run 'append_env_migrated_assignment_if_missing UI_BIND_IP IP_HTTP "" "${E}"'
    [ "${status}" -eq 0 ] && [ "$(cat "${E}")" = "IP_HTTP=" ] || { echo "nothing: $(cat "${E}")"; return 1; }
    export SD="${t}/archive"
    sot="${CI_MANIFEST_SOURCE#"${root}"/}"
    [ "${sot}" != "${CI_MANIFEST_SOURCE}" ] && mkdir -p "${SD}/${sot%/*}" && cp "${CI_MANIFEST_SOURCE}" "${SD}/${sot}" \
        || { echo "SOT ${CI_MANIFEST_SOURCE} not copied below ${SD}"; return 1; }
    while IFS='|' read -r case want err rc; do
        printf '%s\n' "${case}" > "${SD}/VERSION"
        [ "${case}" != - ] || : > "${SD}/VERSION"
        _setup_sh_run 'unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG; SCRIPT_DIR="${SD}"; derive_release_archive_image_tag 2> "${ERR}"'
        [ "${status}" -eq "${rc}" ] && [ "${output}" = "${want}" ] && [ "$(cat "${ERR}")" = "${err}" ] \
            || { echo "VERSION ${case}: rc ${status}, stdout '${output}', stderr '$(cat "${ERR}")'"; return 1; }
    done <<CASES
${v#v}|v${v#v}||0
v${v#v}-rc.1|v${v#v}-rc.1||0
${v%.*}||Invalid release image tag derived from VERSION: v${v%.*}|2
-||VERSION is empty; cannot derive a release image tag.|2
CASES
    printf '%s\n' "${v}" > "${SD}/VERSION"
    PIN="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release "" pinned_channel)"
    REL="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_channels_where release_tags true)"
    CH="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_keys release/channels)"
    CH="$(awk -v r="${REL}" '$0 != r { print; exit }' <<< "${CH}")"
    ALIAS="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_list release/channels "${REL}" aliases)"
    ALIAS="${ALIAS%%$'\n'*}"
    [ -n "${PIN}" ] && [ -n "${REL}" ] && [ -n "${CH}" ] && [ -n "${ALIAS}" ] || { echo "SOT: ${PIN}|${REL}|${CH}|${ALIAS}"; return 1; }
    export PIN CH ALIAS
    _setup_sh_run 'unset LANCACHE_IMAGE_CHANNEL LANCACHE_IMAGE_TAG; SCRIPT_DIR="${SD}"
        printf "%s|%s|%s|%s\n" "$(resolve_lancache_image_channel "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL="${PIN}" resolve_lancache_image_tag "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL="${CH}" resolve_lancache_image_tag "${SD}/missing.env")" \
            "$(LANCACHE_IMAGE_CHANNEL="${ALIAS}" resolve_lancache_image_tag "${SD}/missing.env")"'
    [ "${status}" -eq 0 ] && [ "${output}" = "${PIN}|v${v#v}|${CH}|${REL}" ] || { echo "channels: ${output}"; return 1; }
    g() { git -c user.email=t@example.test -c user.name=t "$@"; }
    _tags_reset() {
        g -C "${GD}" tag -l > "${t}/tags" || return 1
        while IFS= read -r tag; do g -C "${GD}" tag -d "${tag}" >> "${t}/tags-deleted" || return 1; done < "${t}/tags"
    }
    export GD="${t}/real dir"
    g init -q "${GD}" && g -C "${GD}" commit -q --allow-empty -m c1 || return 1
    printf '%s\n' "${v}" > "${GD}/VERSION"
    ln -s "${GD}" "${t}/link" || return 1
    while IFS='|' read -r case tags want err rc; do
        _tags_reset || return 1
        for tag in ${tags}; do g -C "${GD}" tag "${tag}" || return 1; done
        export SDIR="${GD}"
        [ "${case}" != symlink ] || SDIR="${t}/link"
        _setup_sh_run 'SCRIPT_DIR="${SDIR}"; derive_release_archive_image_tag 2> "${ERR}"'
        [ "${status}" -eq "${rc}" ] && [ "${output}" = "${want}" ] && [ "$(cat "${ERR}")" = "${err}" ] \
            || { echo "${case}: rc ${status}, stdout '${output}', stderr '$(cat "${ERR}")'"; return 1; }
    done <<CASES
tagged|v${v#v}|v${v#v}||0
untagged||||1
symlink|v${v#v}|v${v#v}||0
badtag|${bad}||Invalid release tag from git checkout: ${bad}|2
multi|v${v#v} v${v#v}-rc.1||Several release tags point at HEAD: v${v#v} v${v#v}-rc.1|2
CASES
    _tags_reset && g -C "${GD}" tag "v${v#v}" || return 1
    chown -R "$(( $(id -u) + 1 ))" "${GD}" || { echo "chown needs root for the dubious-ownership case"; return 1; }
    export SDIR="${GD}"
    _setup_sh_run 'SCRIPT_DIR="${SDIR}"; derive_release_archive_image_tag 2> "${ERR}"'
    [ "${status}" -eq 0 ] && [ "${output}" = "v${v#v}" ] && [[ "$(cat "${ERR}")" == "Note: ${GD} has different file ownership"* ]] \
        || { echo "dubious: rc ${status}, stdout '${output}', stderr '$(cat "${ERR}")'"; return 1; }
}

# What: SOT channels, aliases, pinned; retired names fail
# Why: AG-REL-010: setup.sh derives every channel name
# From: Issue #1683 | PR #1858
@test "setup image channel validation, resolution and pointer" {
    local root t="${BATS_TEST_TMPDIR}" mut rel pin aliases="" retired="" accepted kind want ch name reason
    local first second v sha case line sot
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mut="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_keys release/channels)"
    rel="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_channels_where release_tags true)"
    pin="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release "" pinned_channel)"
    while IFS= read -r ch; do
        while IFS= read -r name; do
            [ -z "${name}" ] || aliases+="${name} ${ch}"$'\n'
        done <<< "$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_list release/channels "${ch}" aliases)"
    done <<< "${mut}"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        reason="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release retired_channels "${name}")"
        retired+="${name} ${reason}"$'\n'
    done <<< "$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_keys release/retired_channels all)"
    aliases="${aliases%$'\n'}" retired="${retired%$'\n'}"
    [ "$(wc -l <<< "${mut}")" -ge 2 ] && [ "$(wc -w <<< "${rel}")" -eq 1 ] && [ -n "${aliases}" ] \
        && [ -n "${pin}" ] && [ -n "${retired}" ] || { echo "SOT: ${mut} | ${rel} | ${aliases} | ${pin} | ${retired}"; return 1; }
    accepted="$(printf '%s\n%s\n%s\n' "${mut}" "$(cut -d' ' -f1 <<< "${aliases}")" "${pin}")"
    v="$(tr -d '[:space:]' < "${root}/VERSION")"
    sha="sha-$(sha256sum "${root}/VERSION" | cut -c1-40)"
    first="$(awk 'NR == 1' <<< "${mut}")" second="$(awk 'NR == 2' <<< "${mut}")"
    export C SD="${t}/plain" E="${t}/.env" SHELLC SHELLT
    mkdir -p "${SD}"
    sot="${CI_MANIFEST_SOURCE#"${root}"/}"
    [ "${sot}" != "${CI_MANIFEST_SOURCE}" ] && mkdir -p "${SD}/${sot%/*}" && cp "${CI_MANIFEST_SOURCE}" "${SD}/${sot}" \
        || { echo "SOT ${CI_MANIFEST_SOURCE} not copied below ${SD}"; return 1; }
    # What: setup.sh reads the release block as ci.sh does
    # Why: two readers of one SOT must never disagree
    # From: Issue #1683 | PR #1858
    for kind in channel release alias pinned retired; do
        case "${kind}" in
            channel) want="${mut}" ;;
            release) want="${rel}" ;;
            alias) want="${aliases}" ;;
            pinned) want="${pin}" ;;
            retired) want="${retired}" ;;
        esac
        _setup_sh_run "lancache_release_rows ${kind}"
        [ "${status}" -eq 0 ] && [ "$(sort <<< "${output}")" = "$(sort <<< "${want}")" ] \
            || { echo "${kind}: setup.sh '${output}', ci.sh '${want}'"; return 1; }
    done
    # What: channels point to themselves, aliases to theirs
    # Why: an alias has no stack tag of its own
    # From: Issue #1683 | PR #1858
    while IFS= read -r C; do
        _setup_sh_run 'validate_lancache_image_channel "${C}" && lancache_stack_pointer_channel_for "${C}"'
        [ "${status}" -eq 0 ] && [ "${output}" = "${C}" ] || { echo "channel ${C}: ${output}"; return 1; }
    done <<< "${mut}"
    while read -r C ch; do
        _setup_sh_run 'validate_lancache_image_channel "${C}" && lancache_stack_pointer_channel_for "${C}"'
        [ "${status}" -eq 0 ] && [ "${output}" = "${ch}" ] || { echo "alias ${C}: ${output}"; return 1; }
    done <<< "${aliases}"
    C="${pin}"
    _setup_sh_run 'validate_lancache_image_channel "${C}"'
    [ "${status}" -eq 0 ] || { echo "pinned ${C}: ${output}"; return 1; }
    # What: retired and unknown names fail with the choices
    # Why: release-versioning: a clear error, no fallback
    # From: Issue #1683 | PR #1858
    while read -r C reason; do
        _setup_sh_run 'validate_lancache_image_channel "${C}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* && "${output}" == *"${reason}"* ]] \
            || { echo "retired ${C}: ${output}"; return 1; }
        while IFS= read -r name; do
            [[ "${output}" == *"${name}"* ]] || { echo "retired ${C} does not name ${name}: ${output}"; return 1; }
        done <<< "${accepted}"
    done <<< "${retired}"
    for C in "$(_val name)" ""; do
        _setup_sh_run 'validate_lancache_image_channel "${C}"; echo unreached'
        [ "${status}" -eq 1 ] && [[ "${output}" == *"must be one of"* && "${output}" != *unreached* ]] \
            || { echo "unknown '${C}': ${output}"; return 1; }
        while IFS= read -r name; do
            [[ "${output}" == *"${name}"* ]] || { echo "unknown '${C}' does not name ${name}: ${output}"; return 1; }
        done <<< "${accepted}"
    done
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
    # What: the pinned mode without any tag stops
    # Why: pinned names one fixed tag; none must not pass
    # From: Issue #1683 | PR #1858
    : > "${E}"
    C="${pin}"
    _setup_sh_run 'SCRIPT_DIR="${SD}"; unset LANCACHE_IMAGE_TAG
        LANCACHE_IMAGE_CHANNEL="${C}" resolve_lancache_image_tag "${E}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* && "${output}" == *"LANCACHE_IMAGE_CHANNEL=${pin} requires LANCACHE_IMAGE_TAG"* ]] \
        || { echo "pinned without a tag: ${output}"; return 1; }
    C="$(awk 'NR == 1 { print $1 }' <<< "${retired}")"
    _setup_sh_run 'SCRIPT_DIR="${SD}"; LANCACHE_IMAGE_CHANNEL="${C}" resolve_lancache_image_channel "${E}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" != *unreached* ]] || { echo "retired in shell: ${output}"; return 1; }
}

# What: setup accepts exactly what the UI can write
# Why: a UI value must never be dropped or misread
# From: Issue #1683 | PR #1858
@test "setup ui override validators per value" {
    local root ui chans modes other gb v acc c
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    ui="${root}/services/ui/src"
    chans="$(awk '/^fn is_valid_ui_channel/ { f = 1 } f && /matches!/ { print; exit }' "${ui}/main.rs" | grep -oE '"[a-z]+"' | tr -d '"')"
    modes="$(_rust_dhcp_modes "${root}")" || return 1
    other="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels | grep -vxF -f <(printf '%s\n' "${chans}"))"
    acc="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release "" pinned_channel)"
    while IFS= read -r c; do
        acc+=$'\n'"${c}"$'\n'"$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_list release/channels "${c}" aliases)"
    done <<< "$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_keys release/channels)"
    other+=$'\n'"$(grep -v '^$' <<< "${acc}" | grep -vxF -f <(printf '%s\n' "${chans}"))"
    gb="$(cache_size_gb_from_env "$(get_env_var CACHE_MAX_SIZE "$(_template_env)")")"
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

# What: enabled flag, pinned channel, moved tag, text
# Why: auto-update never touches a pinned or idle stack
# From: Issue #1683 | PR #1858
@test "setup auto-update gate decides exactly per input" {
    local root mut first second pin new old word
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    mut="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_mutable_channels)"
    first="$(awk 'NR == 1' <<< "${mut}")" second="$(awk 'NR == 2' <<< "${mut}")"
    pin="$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_field release "" pinned_channel)"
    new="sha-$(_val sha)" old="sha-$(_val sha)" word="$(_val name)"
    [ -n "${first}" ] && [ -n "${second}" ] && [ "$(wc -l <<< "${pin}")" -eq 1 ] && [ -n "${pin}" ] \
        && [ "${new}" != "${old}" ] || { echo "inputs: ${mut} | ${pin} | ${new} | ${old}"; return 1; }
    # What: one decision per row, under setup.sh options
    # Why: the gate output is the auto-update log line
    # From: Issue #1683 | PR #1858
    cat > "${BATS_TEST_TMPDIR}/rows" <<CASES
off|0|${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
empty||${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
word|${word}|${first}|${new}|${old}|1|skip: AUTO_UPDATE_ENABLED is not 1
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

# What: moved keys go from <svc>.local.env to .env.local
# Why: compose maps them from there; the value must stay
# From: Issue #1683 | PR #1858
@test "setup moves config/prod overrides into the runtime env once" {
    local root t="${BATS_TEST_TMPDIR}" rows trows prows svc key target v cp ip bad rest
    local -a plain=()
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    export D="${t}/repo/deploy/prod" E="${t}/repo/deploy/prod/.env.local" Q="${t}/a/qs"
    _prod_install "${D}" || return 1
    cp="${t}/repo/config/prod"
    mkdir -p "${cp}" || return 1
    rows="$(config_prod_moved_keys)" || { echo "config_prod_moved_keys rc $?"; return 1; }
    trows="$(awk 'NF == 3' <<< "${rows}")"
    prows="$(awk 'NF == 2 && !seen[$1]++' <<< "${rows}" | awk 'NR <= 2')"
    [ "$(wc -l <<< "${trows}")" -ge 2 ] && [ "$(wc -l <<< "${prows}")" -eq 2 ] || { echo "rows: ${rows}"; return 1; }
    cp "${D}/.env" "${E}" || return 1
    rest="$(_val var)=$(_val name)"
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

# What: server plus a filename; filename char rules
# Why: a half answer or bad name breaks dnsmasq.conf
# From: Issue #1683 | PR #1858
@test "setup pxe wizard answers and boot filename per input" {
    local root t="${BATS_TEST_TMPDIR}" ip bios uefi max code c
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    require_helper_image
    ip="$(get_env_var IP_HTTP "$(_template_env)")"
    bios="$(_val name)" uefi="$(_val name)/$(_val name)"
    # What: the longest name one DHCP option can carry
    # Why: RFC 2132: an option length is a single octet
    # From: Issue #1683 | PR #1858
    max=$(( (1 << 8) - 1 ))
    [ -n "${ip}" ] || { echo "template sets no IP_HTTP"; return 1; }
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

# What: rpm repo, conflicts and install set per distro
# Why: Docker CE needs its repo; legacy Docker blocks it
# From: PR #429
@test "setup rpm docker repo, conflicts and install set per distro" {
    local root p
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    export RPMDB RBIN DNFLOG OTHER OSID
    RPMDB="$(_val path)" RBIN="$(_val path)" DNFLOG="$(_val path)"
    OTHER="$(_val name)" OSID="$(_val name)"
    printf '%s\n' docker docker-selinux docker-engine-selinux podman runc podman-docker "${OTHER}" > "${RPMDB}"
    _tool_stub "${RBIN}" rpm <<< 'cat "${RPMDB:?}"'
    _tool_stub "${RBIN}" dnf <<< 'exit 1'
    # What: Fedora drops only Docker-family packages
    # Why: stock podman and runc must stay installable
    # From: PR #429
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; rpm_conflicting_docker_packages_for fedora'
    [ "${status}" -eq 0 ] || { echo "fedora: ${output}"; return 1; }
    for p in docker docker-selinux docker-engine-selinux podman-docker; do
        grep -qxF -- "${p}" <<< "${output}" || { echo "fedora misses ${p}: ${output}"; return 1; }
    done
    for p in podman runc "${OTHER}"; do
        if grep -qxF -- "${p}" <<< "${output}"; then echo "fedora blocks ${p}: ${output}"; return 1; fi
    done
    # What: every other ID also blocks podman and runc
    # Why: they conflict with Docker CE on the RHEL family
    # From: PR #429
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; rpm_conflicting_docker_packages_for "${OSID}"'
    [ "${status}" -eq 0 ] || { echo "${OSID}: ${output}"; return 1; }
    for p in docker docker-selinux docker-engine-selinux podman runc; do
        grep -qxF -- "${p}" <<< "${output}" || { echo "${OSID} misses ${p}: ${output}"; return 1; }
    done
    if grep -qxF -- "${OTHER}" <<< "${output}"; then echo "${OSID} blocks ${OTHER}"; return 1; fi
    # What: an engine set stops on a conflict before dnf
    # Why: a compose-plugin-only install must not skip it
    # From: PR #429
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; install_docker_rpm dnf docker-compose-plugin; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" == *"conflict with these installed packages"* && "${output}" != *unreached* ]] \
        || { echo "compose plugin only: ${output}"; return 1; }
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; install_docker_rpm dnf "${OTHER}"; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" != *"conflict with these installed packages"* && "${output}" != *unreached* ]] \
        || { echo "non-engine set ran the guard: ${output}"; return 1; }
    : > "${RPMDB}"
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; install_docker_rpm dnf docker-compose-plugin; echo unreached'
    [ "${status}" -eq 1 ] && [[ "${output}" != *"conflict with these installed packages"* ]] \
        || { echo "no conflict reported as one: ${output}"; return 1; }
    # What: https root; Fedora, RHEL own dirs, else CentOS
    # Why: Docker publishes one .repo file per distro family
    # From: PR #259
    local id dir url base="" urls=""
    for id in fedora rhel "${OSID}"; do
        _setup_sh_run "docker_rpm_repo_url ${id}"
        dir="${id}"; [ "${id}" != "${OSID}" ] || dir=centos
        url="${output}"
        [ "${status}" -eq 0 ] && [[ "${url}" == */"${dir}"/docker-ce.repo ]] \
            || { echo "${id}: ${status} ${url} want .../${dir}/docker-ce.repo"; return 1; }
        [ -n "${base}" ] || base="${url%/"${dir}"/docker-ce.repo}"
        [ "${url}" = "${base}/${dir}/docker-ce.repo" ] || { echo "${id}: ${url} not under ${base}"; return 1; }
        urls+="${url}"$'\n'
    done
    [[ "${base}" == https://?* ]] || { echo "repo root not https: ${base}"; return 1; }
    # What: default set: engine, CLI, containerd, plugins
    # Why: verify and the buildx check need all five
    # From: PR #259
    _tool_stub "${RBIN}" dnf <<< 'printf "%s\n" "$*" >> "${DNFLOG:?}"'
    _tool_stub "${RBIN}" docker <<< '[ "$*" = "compose version" ]'
    _setup_sh_run 'PATH="${RBIN}:${PATH}"; install_docker_rpm dnf'
    [ "${status}" -eq 0 ] || { echo "default install: ${output}"; return 1; }
    url="$(sed -n 's/^config-manager --add-repo //p' "${DNFLOG}")"
    [ -n "${url}" ] && grep -qxF -- "${url}" <<< "${urls}" || { echo "repo ${url} not one of: ${urls}"; return 1; }
    [ "$(sed -n '$p' "${DNFLOG}")" = "install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" ] \
        || { echo "default set: $(cat "${DNFLOG}")"; return 1; }
}

# What: PATH of manager stand-ins plus bash, env, cat, awk
# Why: a real package manager on the host is never reached
# From: Issue #1683 | PR #1858
_pm_path() {
    local dir tool rec='printf "%s %s\n" "${0##*/}" "$*" >> "${CALLS:?}"'
    dir="$(_val path)"
    mkdir -p "${dir}" || return 1
    for tool in bash env cat awk; do
        ln -s "$(type -P "${tool}")" "${dir}/${tool}" || return 1
    done
    for tool in "$@"; do
        _tool_stub "${dir}" "${tool}" <<< "${rec}" || return 1
    done
    _tool_stub "${dir}" apt-cache <<< 'case " ${AVAIL:-} " in *" $2 "*) echo "  Candidate: 2.${SRANDOM}" ;; *) echo "  Candidate: (none)" ;; esac' \
        || return 1
    _tool_stub "${dir}" rpm <<< 'cat "${RPMDB:?}"' || return 1
    _tool_stub "${dir}" docker <<< '[ "$*" = "compose version" ]' || return 1
    printf '%s\n' "${dir}"
}

# What: runs a setup.sh snippet; answers come on fd 9
# Why: the real ask path reads list-prompts answers there
# From: Issue #1683 | PR #1858
_pm_run() {
    _setup_sh_run "WIZARD_INTROSPECT_MODE=1; WIZARD_INTROSPECT_ANSWERS_FD=9; exec 9<\"\${ANS:?}\"; PATH='$1'; $2"
}

# What: Docker installs per manager, answer and install set
# Why: one detection order; nothing installs without a yes
# From: Issue #1683 | PR #1858
@test "setup docker install per package manager and answer" {
    local root p calls tool ce rpmset repo="--add-repo <repo>"
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    export CALLS ANS RPMDB AVAIL=""
    CALLS="$(_val path)" ANS="$(_val path)" RPMDB="$(_val path)" tool="$(_val name)"
    : > "${RPMDB}"
    ce="docker-ce docker-ce-cli containerd.io"
    rpmset="${ce} docker-buildx-plugin docker-compose-plugin"
    # What: runs a snippet on stand-ins with one answer
    # Why: each row needs a fresh PATH, answer and call log
    _pm_try() {
        p="$(_pm_path "${@:3}")" || return 1
        printf '%s\n' "$1" > "${ANS}" && : > "${CALLS}" || return 1
        _pm_run "${p}" "$2"
        calls="$(sed -E 's|--add-repo [^ ]+|--add-repo <repo>|' "${CALLS}")"
    }
    # What: checks rc and recorded calls of the last run
    # Why: every row names its exact installs or none
    _pm_calls() {
        local label="$1" rc="$2" want=""
        shift 2
        [ "$#" -eq 0 ] || want="$(printf '%s\n' "$@")"
        [ "${status}" -eq "${rc}" ] && [ "${calls}" = "${want}" ] \
            || { echo "${label}: rc ${status} want ${rc}; calls [${calls}] want [${want}]; ${output}"; return 1; }
    }
    AVAIL="docker-compose-plugin docker-buildx-plugin"
    _pm_try y install_docker apt-get || return 1
    _pm_calls apt-ce 0 "apt-get update -y" \
        "apt-get install -y --no-install-recommends ${ce} docker-compose-plugin docker-buildx-plugin" || return 1
    [[ "${output}" == *"Required packages: docker.io, an available Compose v2 package (docker-compose-plugin, docker-compose-v2, or docker-compose), and Buildx (docker-buildx-plugin or docker-buildx) when this apt index has one"* ]] \
        || { echo "apt prompt: ${output}"; return 1; }
    AVAIL="docker-compose-v2 docker-buildx"
    _pm_try y install_docker apt-get || return 1
    _pm_calls apt-distro 0 "apt-get update -y" "apt-get install -y --no-install-recommends docker.io docker-compose-v2 docker-buildx" \
        || return 1
    _pm_try n install_docker apt-get || return 1
    _pm_calls apt-no 1 || return 1
    [[ "${output}" == *"Aborted. Please install Docker and a Docker Compose v2 package manually, then rerun setup.sh."* ]] \
        || { echo "apt abort: ${output}"; return 1; }
    _pm_try y install_docker dnf || return 1
    _pm_calls dnf 0 "dnf install -y dnf-plugins-core" "dnf config-manager ${repo}" "dnf install -y ${rpmset}" || return 1
    [[ "${output}" == *"Required packages: ${rpmset}"*"Docker's RPM repository will be configured before installation."* ]] \
        || { echo "dnf prompt: ${output}"; return 1; }
    _pm_try y install_docker yum yum-config-manager || return 1
    _pm_calls yum 0 "yum install -y yum-utils" "yum-config-manager ${repo}" "yum install -y ${rpmset}" || return 1
    _pm_try y install_docker dnf yum yum-config-manager || return 1
    _pm_calls dnf-first 0 "dnf install -y dnf-plugins-core" "dnf config-manager ${repo}" "dnf install -y ${rpmset}" || return 1
    _pm_try n install_docker dnf || return 1
    _pm_calls dnf-no 1 || return 1
    [[ "${output}" == *"Aborted. Please install Docker from Docker's RPM repository manually, then rerun setup.sh: ${rpmset}"* ]] \
        || { echo "dnf abort: ${output}"; return 1; }
    _pm_try y install_docker pacman || return 1
    _pm_calls pacman 0 "pacman -Syu --noconfirm docker docker-compose docker-buildx" || return 1
    _pm_try y install_docker || return 1
    _pm_calls none 1 || return 1
    [[ "${output}" == *"No supported package manager found. Please install Docker and the Docker Compose plugin manually, then rerun setup.sh."* ]] \
        || { echo "no manager: ${output}"; return 1; }
    # What: Compose-only installs one package per manager
    # Why: Docker is present; only Compose v2 is missing
    AVAIL="docker-compose"
    _pm_try y install_docker_compose apt-get || return 1
    _pm_calls compose-apt 0 "apt-get update -y" "apt-get install -y --no-install-recommends docker-compose" || return 1
    [[ "${output}" == *"Required package: an available Compose v2 package (docker-compose-plugin, docker-compose-v2, or docker-compose)"* ]] \
        || { echo "compose apt prompt: ${output}"; return 1; }
    _pm_try y install_docker_compose dnf || return 1
    _pm_calls compose-dnf 0 "dnf install -y dnf-plugins-core" "dnf config-manager ${repo}" "dnf install -y docker-compose-plugin" \
        || return 1
    _pm_try n install_docker_compose yum yum-config-manager || return 1
    _pm_calls compose-yum-no 1 || return 1
    [[ "${output}" == *"Aborted. Please install Docker Compose from Docker's RPM repository manually, then rerun setup.sh: docker-compose-plugin"* ]] \
        || { echo "compose yum abort: ${output}"; return 1; }
    _pm_try y install_docker_compose pacman || return 1
    _pm_calls compose-pacman 0 "pacman -Syu --noconfirm docker-compose" || return 1
    # What: missing tools install only through apt
    # Why: the tool-to-package map knows apt names only
    _pm_try y "install_missing_tools ${tool}" dnf || return 1
    _pm_calls tools-dnf 1 || return 1
    [[ "${output}" == *"Cannot install missing tools automatically; install: ${tool}"* ]] \
        || { echo "tools on dnf: ${output}"; return 1; }
}

# What: modes, subnet start; retired profiles dropped
# Why: five fixed services; operator profiles must stay
# From: Issue #1683 | PR #1912
@test "setup dhcp modes, subnet start and retired compose profiles" {
    local root modes ip net m v x out
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    modes="$(_rust_dhcp_modes "${root}")" || return 1
    ip="$(get_env_var IP_HTTP "$(_template_env)")" net="${ip%.*}.0"
    [ "$(wc -l <<< "${modes}")" -ge 3 ] && [ -n "${ip}" ] || { echo "inputs: ${modes} | ${ip}"; return 1; }
    while IFS= read -r m; do
        is_valid_dhcp_mode "${m}" && ! is_valid_dhcp_mode "${m^^}" && ! is_valid_dhcp_mode "${m}x" || { echo "mode ${m}"; return 1; }
    done <<< "${modes}"
    ! is_valid_dhcp_mode "" || { echo "empty mode accepted"; return 1; }
    is_dnsmasq_subnet_start "${net}" || { echo "subnet ${net} refused"; return 1; }
    for v in "${ip%.*}.$(( ${ip##*.} | 1 ))" "x${BATS_TEST_NUMBER}" "256.${net#*.}"; do
        ! is_dnsmasq_subnet_start "${v}" || { echo "subnet ${v} accepted"; return 1; }
    done
    [ -z "$(_prod_compose config --profiles)" ] || { echo "prod compose has profiles again"; return 1; }
    x="x${BATS_TEST_NUMBER}"
    out="$(compose_profiles_for_runtime "ssl, dhcp-kea ,dhcp-proxy,ntp,logging")"
    [ -z "${out}" ] || { echo "retired profiles kept: ${out}"; return 1; }
    out="$(compose_profiles_for_runtime " ${x} ,logging, ${x}z ,${x},dhcp-kea")"
    [ "${out}" = "${x},${x}z" ] || { echo "operator profiles: ${out}"; return 1; }
    [ -z "$(compose_profiles_for_runtime "")" ] || { echo "empty input gave a value"; return 1; }
}

# What: atomic write replaces whole, keeps old on failure
# Why: secondary compose and .env must never be torn
# From: Issue #1683 | PR #1912
@test "setup write_file_atomically: replaces whole or keeps the old file" {
    local root d f old new
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    d="$(_val path)" old="$(_val sha)" new="$(_val sha)"
    f="${d}/$(_val name)"
    mkdir -p "${d}" && printf '%s\n' "${old}" > "${f}" && chmod 0640 "${f}" || return 1
    _setup_sh_run "write_file_atomically '${f}' <<< '${new}'"
    _expect replaced 0 - || return 1
    [ "$(cat "${f}")" = "${new}" ] && [ "$(stat -c %a "${f}")" = 640 ] \
        || { echo "replaced: '$(cat "${f}")' mode $(stat -c %a "${f}")"; return 1; }
    _setup_sh_run "write_file_atomically '${f}' < '${d}'"
    [ "${status}" -ne 0 ] || { echo "unreadable stdin: rc 0: ${output}"; return 1; }
    [ "$(cat "${f}")" = "${new}" ] || { echo "torn: '$(cat "${f}")'"; return 1; }
    _setup_sh_run "write_file_atomically '${d}/fresh' <<< '${old}'"
    _expect fresh 0 - || return 1
    [ "$(stat -c %a "${d}/fresh")" = 600 ] || { echo "fresh mode $(stat -c %a "${d}/fresh")"; return 1; }
    [ -z "$(find "${d}" -name '.*.tmp.*')" ] || { echo "temp left: $(find "${d}" -name '.*.tmp.*')"; return 1; }
}

# What: cmd_secondary against a stub primary per answer
# Why: token never in argv; failures stop before writes
# From: Issue #1683 | PR #1858
@test "setup secondary registration end to end per primary answer" {
    _registry || return 1
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" rs http lip ui name xfr fields reg pre tag token body f v case want dir
    local env gen canon required first rest
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}"
    rs="${root}/services/ui/src/main.rs"
    http="$(get_env_var IP_HTTP "$(_template_env)")"
    lip="$(get_env_var IP_HTTPS "$(_template_env)")"
    ui="$(_prod_compose config --format json | jq -r '.services.ui.ports[0].published')"
    name="$(_prod_compose config --format json | jq -r .name)"
    xfr=""
    ! grep -qF 'dns_xfr_primary: format!("{}:{}", state.config.http_ip, state.config.pdns_auth_port)' "${rs}" \
        || xfr=":$(_ci_runtime_default PDNS_AUTH_PORT)"
    fields="$(awk '/^struct RegisterResponse/,/^}/' "${rs}" | sed -n 's/^ *\([a-z_]*\): String,$/\1/p')"
    reg="$(resolve_lancache_image_registry "$(_template_env)")"
    pre="$(resolve_lancache_image_prefix "$(_template_env)")"
    tag="v$(cat "${root}/VERSION")"
    token="$(generate_secret_value SECONDARY_REGISTRATION_TOKEN hex32)"
    token="${token}\"${token}\\"
    required="$(declare -f cmd_secondary | sed -n 's/.*missing_fields+=("\([a-z_]*\)").*/\1/p')"
    [ -n "${http}" ] && [ -n "${lip}" ] && [ -n "${ui}" ] && [ -n "${xfr}" ] && [ -n "${fields}" ] \
        && [ -n "${required}" ] || { echo "inputs: ${http} ${lip} ${ui} ${xfr}"; return 1; }
    # What: the primary's answer, one value per struct field
    # Why: values are unique so each one is traced to .env
    # From: Issue #1683 | PR #1858
    body='{}'
    while IFS= read -r f; do
        case "${f}" in
            ip_http) v="${http}" ;;
            dns_xfr_primary) v="${http}${xfr}" ;;
            image_registry) v="${reg}" ;;
            image_prefix) v="${pre}" ;;
            image_channel) v="" ;;
            image_tag) v="${tag}" ;;
            *) v="$(_val sha)" ;;
        esac
        body="$(jq -c --arg k "${f}" --arg v "${v}" '.[$k] = $v' <<< "${body}")"
    done <<< "${fields}"
    first="$(awk 'NR == 1' <<< "${required}")"
    rest="$(awk 'NR > 1' <<< "${required}" | paste -sd' ')"
    export PRIMARY="http://${http}:${ui}" TOKEN="${token}" NAME="${name}" HTTP_IP="${http}" LIP="${lip}"
    export JQ_REAL
    JQ_REAL="$(type -P jq)"
    _tool_stub "${BIN}" ss <<<'[ ! -e "${DS}/listeners" ] || cat "${DS}/listeners"'
    _tool_stub "${BIN}" jq <<<'printf "%s\n" "$*" >> "${DS}/jq.argv"; exec "${JQ_REAL:?}" "$@"'
    _tool_stub "${BIN}" curl <<'STUB'
printf '%s\n' "$*" >> "${DS}/curl.argv"
u="${!#}"
while IFS= read -r f; do
    case "${u}" in
        */"${f#"${DS}/raw/"}") [ ! -e "${DS}/fail-raw" ] || [ "${f#"${DS}/raw/"}" != "$(cat "${DS}/fail-raw")" ] || exit 22; cat "${f}"; exit 0 ;;
    esac
done < <(find "${DS}/raw" -type f)
cat > "${DS}/curl.body"
[ ! -e "${DS}/fail-curl" ] || exit 7
fmt=""
while [ "$#" -gt 0 ]; do [ "$1" != -w ] || fmt="$2"; shift; done
fmt="${fmt//\\n/$'\n'}"
cat "${DS}/reply.body"
printf '%s' "${fmt//"%{http_code}"/$(cat "${DS}/reply.status")}"
STUB
    mkdir -p "${DS}/raw" || return 1
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
        _sec "${t}/${case}" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}"
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
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Required argument(s) missing: --primary --token --ip-http"* ]] \
        || { echo "missing args: ${output}"; return 1; }
    rm -f "${DS}/listeners" "${DS}/curl.argv"
    printf '200' > "${DS}/reply.status"; printf '%s' "${body}" > "${DS}/reply.body"
    rm -f "${DS}/jq.argv"
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}"
    [ "${status}" -eq 0 ] || { echo "register: ${output}"; return 1; }
    ! grep -qF -- "${token}" "${DS}/jq.argv" "${DS}/curl.argv" || { echo "token in argv"; return 1; }
    jq -e --arg tok "${token}" --arg n "${name}" --arg a "${lip}" '. == {token: $tok, name: $n, address: $a}' "${DS}/curl.body" \
        || { echo "request: $(cat "${DS}/curl.body")"; return 1; }
    dir="${t}/ok/${name}" env="${t}/ok/${name}/.env"
    # What: every answer value lands in .env, IPs as passed
    # Why: the secondary runs on what the primary handed out
    # From: Issue #1683 | PR #1858
    while IFS= read -r f; do
        case "${f}" in ip_http|image_*) continue ;; esac
        v="$(jq -r --arg k "${f}" '.[$k]' <<< "${body}")"
        awk -v v="${v}" 'substr($0, index($0, "=") + 1) == v { f = 1 } END { exit !f }' "${env}" \
            || { echo "${f} not in .env"; return 1; }
    done <<< "${fields}"
    [ "$(get_env_var IP_HTTP "${env}")" = "${http}" ] && [ "$(get_env_var LISTEN_IP "${env}")" = "${lip}" ] \
        || { echo "ips: $(cat "${env}")"; return 1; }
    want="compose --env-file ${env} $(compose_file_args_for_install_dir "${dir}" | paste -sd' ') up -d"
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
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"already exists; rerun with --rotate"* ]] && [ ! -e "${DS}/curl.argv" ] \
        || { echo "existing: ${output}"; return 1; }
    _sec "${t}/ok" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}" --rotate
    [ "${status}" -eq 0 ] && cmp "${t}/env.first" "${env}" && cmp "${t}/compose.first" "${dir}/docker-compose.yml" \
        || { echo "rotate: ${output}"; return 1; }
    # What: https side needs both flags and its own bind IP
    # Why: one dns container, a second bind, never half-set
    # From: Issue #1683 | PR #1912
    [ -z "$(get_env_var IP_HTTPS "${env}")" ] && [ -z "$(get_env_var DNS_HTTPS_HOST_PORT "${env}")" ] \
        && [ "$(get_env_var LISTEN_IP_HTTPS "${env}")" = "$(_ci_runtime_default LOOPBACK_BIND_IP)" ] \
        || { echo "https keys set without flags: $(cat "${env}")"; return 1; }
    while IFS='|' read -r case want args; do
        # shellcheck disable=SC2086
        _sec "${t}/${case}" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}" ${args}
        [ "${status}" -eq 1 ] && [[ "${output}" == *"${want}"* ]] && [ ! -e "${t}/${case}/${name}" ] \
            || { echo "${case}: rc ${status}: ${output}"; return 1; }
    done <<CASES
https-one|must be given together|--ip-https 192.0.2.2
https-bad|--ip-https must be a valid IPv4 address|--ip-https x --listen-ip-https 192.0.2.6
https-same|must differ from the http bind IP|--ip-https 192.0.2.2 --listen-ip-https ${LIP}
CASES
    _sec "${t}/https" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}" --ip-https 192.0.2.2 --listen-ip-https 192.0.2.6
    [ "${status}" -eq 0 ] || { echo "https register: ${output}"; return 1; }
    env="${t}/https/${name}/.env"
    [ "$(get_env_var IP_HTTPS "${env}")" = "192.0.2.2" ] && [ "$(get_env_var LISTEN_IP_HTTPS "${env}")" = "192.0.2.6" ] \
        && [ "$(get_env_var DNS_HTTPS_HOST_PORT "${env}")" = "$(_ci_runtime_default DNS_PORT)" ] \
        || { echo "https keys: $(cat "${env}")"; return 1; }
    docker compose -p "${name}" --env-file "${env}" -f "${root}/deploy/secondary/docker-compose.yml" config --format json \
        | jq -e '.services.dns | .environment.IP_HTTPS == "192.0.2.2" and ([.ports[] | select(.target == 1053 and .host_ip == "192.0.2.6" and .published == "53")] | length == 2)' >/dev/null \
        || { echo "https compose ports"; return 1; }
    env="${t}/ok/${name}/.env"
    # What: without a checkout the owner file is downloaded
    # Why: a curl|bash secondary uses the same single owner
    # From: Issue #1683 | PR #1858
    for f in deploy/secondary/docker-compose.yml "${CI_MANIFEST_SOURCE#"${root}"/}"; do
        mkdir -p "${DS}/raw/${f%/*}" && cp "${root}/${f}" "${DS}/raw/${f}" || { echo "raw copy ${f} failed"; return 1; }
    done
    export SEC_SCRIPT_DIR="${t}/nocheckout"
    mkdir -p "${SEC_SCRIPT_DIR}"
    rm -f "${DS}/curl.argv"
    _sec "${t}/raw" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}"
    [ "${status}" -eq 0 ] && cmp "${root}/deploy/secondary/docker-compose.yml" "${t}/raw/${NAME}/docker-compose.yml" \
        && grep -q '/HEAD/deploy/secondary/docker-compose\.yml$' "${DS}/curl.argv" || { echo "download: ${output}"; return 1; }
    # What: the failing download is the compose file only
    # Why: the SOT answers first; the compose file fails.
    # From: Issue #1683 | PR #1912
    printf '%s' deploy/secondary/docker-compose.yml > "${DS}/fail-raw"
    rm -f "${DS}/curl.argv"
    _sec "${t}/rawfail" --primary "${PRIMARY}" --token "${TOKEN}" --name "${NAME}" --ip-http "${HTTP_IP}" --listen-ip "${LIP}"
    [ "${status}" -eq 1 ] && [[ "${output}" == *"Failed to download deploy/secondary/docker-compose.yml"* ]] \
        && [[ "$(tail -n 1 "${DS}/curl.argv")" == *"/HEAD/deploy/secondary/docker-compose.yml" ]] && [ ! -e "${t}/rawfail/${NAME}" ] \
        || { echo "download failure: ${output}"; return 1; }
    unset SEC_SCRIPT_DIR
}

# What: rollback in place twice; restore on a new host
# Why: a restore must reproduce files, paths and volumes
# From: Issue #1683 | PR #1858
@test "setup backup and restore round-trip per target and host" {
    _registry || return 1
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" archive round cfg name bv vol v keys excl key sub e manifest
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    cfg="$(_prod_compose config --format json)" && name="$(jq -r .name <<< "${cfg}")" && bv="$(_backup_volume)" \
        || { echo "compose name or backup volume: ${cfg}"; return 1; }
    vol="${name}_${bv}"
    export T="${t}" S="${t}/a/deploy/prod" D="${t}/b/deploy/prod"
    v="${DS}/volumes/${vol}"
    _prod_install "${S}" && mkdir -p "${S}/certs" "${v}" && printf '%s\n' "${S}" > "${S}/certs/${vol}" \
        && printf '%s\n' "${vol}" > "${v}/${vol}" && printf '%s\n' "${DS}" > "${v}/.${vol}" || return 1
    keys="$(prod_state_keys)" && [ -n "${keys}" ] || { echo "no state keys"; return 1; }
    while IFS= read -r key; do
        sub="$(prod_state_subdir "${key}")" && mkdir -p "${S}/state/${sub}" \
            && printf '%s\n' "${key}" > "${S}/state/${sub}/${key}" || return 1
    done <<< "${keys}"
    manifest="$(backup_manifest "${S}" config)" || { echo "manifest: ${manifest}"; return 1; }
    excl=""
    while IFS= read -r key; do
        sub="$(prod_state_subdir "${key}")" || return 1
        grep -qxF -- "${S}/state/${sub}" <<< "${manifest}" || excl+="${key}"$'\n'
    done <<< "${keys}"
    [ -n "${excl}" ] && [ "$(grep -c . <<< "${excl}")" -lt "$(grep -c . <<< "${keys}")" ] \
        || { echo "a config backup must keep some state dirs and drop others: ${manifest}"; return 1; }
    _state_matches() {
        local dest="$1" key sub
        while IFS= read -r key; do
            sub="$(prod_state_subdir "${key}")" || return 1
            if grep -qx -- "${key}" <<< "${excl}"; then
                ! cmp -s "${t}/S.first/state/${sub}/${key}" "${dest}/state/${sub}/${key}" \
                    || { echo "${key} came from a config backup"; return 1; }
            else
                diff -r "${t}/S.first/state/${sub}" "${dest}/state/${sub}" || { echo "${key} not restored"; return 1; }
            fi
        done <<< "${keys}"
    }
    : > "${DS}/running" || return 1
    _setup_sh_run 'migrate_env_for_update "${S}" 1 && cmd_backup --config --dest "${T}/bk" "${S}"'
    [ "${status}" -eq 0 ] && [ -e "${DS}/running" ] || { echo "converge and backup: ${output}"; return 1; }
    archive="$(find "${t}/bk" -mindepth 1 -maxdepth 1)" || return 1
    [ "$(wc -l <<< "${archive}")" -eq 1 ] && [ -f "${archive}" ] || { echo "backup root: ${archive}"; return 1; }
    export AR="${archive}"
    cp -a "${S}" "${t}/S.first" && cp -a "${v}" "${t}/v.first" && printf '%s\n' "${t}" > "${v}/${vol}" \
        && printf '%s\n' "${t}" > "${S}/certs/${vol}" || return 1
    while IFS= read -r key; do
        printf '%s\n' "${t}" > "${S}/state/$(prod_state_subdir "${key}")/${key}" || return 1
    done <<< "${keys}"
    for round in first second; do
        _setup_sh_run 'cmd_restore "${AR}" "${S}"'
        [ "${status}" -eq 0 ] && [ -e "${DS}/running" ] || { echo "restore ${round}: ${output}"; return 1; }
        for e in "${t}/S.first"/* "${t}/S.first"/.[!.]*; do
            [ ! -e "${e}" ] || [ "${e##*/}" = state ] || diff -r "${e}" "${S}/${e##*/}" || { echo "restore ${round}: ${e##*/}"; return 1; }
        done
        _state_matches "${S}" && diff -r "${t}/v.first" "${v}" || { echo "restore ${round} state"; return 1; }
    done
    rm -rf "${DS}/volumes" && mkdir "${DS}/volumes" || return 1
    _setup_sh_run 'cmd_restore "${AR}" "${D}"'
    [ "${status}" -eq 0 ] || { echo "fresh host: ${output}"; return 1; }
    [ "$(get_env_var LANCACHE_STATE_DIR "${D}/.env")" = "${D}/state" ] && ! grep -qF -- "${S}" "${D}/.env" \
        && _state_matches "${D}" && diff -r "${t}/v.first" "${v}" || { echo "fresh host state"; return 1; }
}

# What: only listed secrets are made; each is redacted
# Why: a secret missed by the bundle is a credential leak
# From: Issue #762 | PR #1858
@test "setup log bundle finds every managed secret and redacts it" {
    local root t="${BATS_TEST_TMPDIR}" list plain k kind long short custom ph marker sec
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    list="$(managed_secret_env_keys)" || return 1
    [ -n "${list}" ] || { echo "no managed secrets"; return 1; }
    while IFS= read -r k; do
        for kind in hex32 base64_32 alnum20; do
            run generate_secret_value "${k}" "${kind}"
            [ "${status}" -eq 0 ] && [ -n "${output}" ] || { echo "listed ${k} ${kind}: rc ${status}"; return 1; }
        done
    done <<< "${list}"
    custom="$(_val var)_TOKEN"
    run generate_secret_value "${custom}" hex32
    _expect unlisted 1 "Secret ${custom} is not in managed_secret_env_keys" || return 1
    sec="$(_ci_required_field runtime secrets_hex32 block) $(_ci_required_field runtime secrets_base64_32 block) $(_ci_required_field runtime secrets_secondary_hex32 block)" || return 1
    sec="$(tr -s '[:space:]' '\n' <<< "${sec}")"
    plain="$(awk -F= '/^[A-Z_][A-Z0-9_]*=/ { print $1 }' "$(_template_env)" | grep -vxF -f <(printf '%s\n' "${list}" "${sec}"))"
    while IFS= read -r k; do
        ! logbundle_key_looks_like_secret "${k}" || [ -z "$(get_env_var "${k}" "$(_template_env)")" ] \
            || { echo "plain prod key ${k} with a shipped value flagged as secret"; return 1; }
    done <<< "${plain}"
    custom="$(_val var)"
    logbundle_key_looks_like_secret "${custom}_SECRET" && ! logbundle_key_looks_like_secret "${custom}_SECRET_MODE" \
        || { echo "secret name net: ${custom}_SECRET or ${custom}_SECRET_MODE"; return 1; }
    k="$(awk 'NR == 1' <<< "${list}")"
    long="$(generate_secret_value "${k}" hex32)" && short="$(generate_secret_value "${k}" alnum20)" || return 1
    custom="$(_val var)_${k##*_}"; ph="CHANGE_ME_${k}"
    ! grep -qx -- "${custom}" <<< "${list}" && logbundle_key_looks_like_secret "${custom}" && secret_value_is_placeholder "${ph}" \
        || { echo "probe inputs invalid: ${custom} ${ph}"; return 1; }
    { printf '%s=%s\n' "${k}" "${short}" "${custom}" "${long}" "$(awk 'NR == 2' <<< "${list}")" "${ph}"
      awk -F= -v k="$(awk 'NR == 1' <<< "${plain}")" '$1 == k' "$(_template_env)"; } > "${t}/src.env"
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

# What: debug only reads; converge folds UI settings once
# Why: support commands must not change an install
# From: Issue #1683 | PR #1858
@test "setup debug stays read-only and converge folds UI settings once" {
    _stand_ins || return 1
    local root t="${BATS_TEST_TMPDIR}" cfg project v reads vsuffix sfile channel mode size gb unit kv p
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    _tool_stub "${BIN}" curl <<<'exit 7' || return 1
    export T="${t}" I="${t}/repo/deploy/prod"
    _prod_install "${I}" && mkdir -p "$(get_env_var LANCACHE_STATE_DIR "${I}/.env")" && cp "${I}/.env" "${t}/env.before" \
        || return 1
    _setup_sh_run 'cmd_debug "${I}" && cmd_debug "${I}"'
    [ "${status}" -eq 0 ] && cmp "${t}/env.before" "${I}/.env" || { echo "debug: ${output}"; return 1; }
    ! grep -Eq '^compose .* (up|pull|down|stop|rm|restart|create|start|kill)( |$)' "${DS}/docker.log" \
        && grep -Eq '^compose .* ps( |$)' "${DS}/docker.log" || { echo "debug calls: $(paste -sd'#' "${DS}/docker.log")"; return 1; }
    cfg="$(_prod_compose config --format json)" && project="$(jq -r .name <<< "${cfg}")" \
        && v="$(jq -r '.volumes | keys[]' <<< "${cfg}")" && [ -n "${v}" ] || { echo "prod volumes: ${cfg}"; return 1; }
    while IFS= read -r p; do mkdir -p "${DS}/volumes/${project}_${p}" || return 1; done <<< "${v}"
    : > "${DS}/docker.log" || return 1
    _setup_sh_run 'cmd_converge_reconcile "${I}"'
    reads="$(grep -E '^run .* -v [^ ]+:/volume:ro ' "${DS}/docker.log")"
    [ "${status}" -eq 0 ] && [ -n "${reads}" ] || { echo "settings read: ${output} $(paste -sd'#' "${DS}/docker.log")"; return 1; }
    vsuffix="$(sed -n 's/.* -v \([^ :]*\):\/volume:ro .*/\1/p' <<< "${reads}" | sort -u)"
    sfile="$(grep -oE 'cat /volume/[A-Za-z0-9._-]+' <<< "${reads}" | sed 's/^cat \/volume\///' | sort -u)"
    [ "$(wc -l <<< "${vsuffix}")" -eq 1 ] && [ "$(wc -l <<< "${sfile}")" -eq 1 ] && [ -n "${sfile}" ] \
        && grep -qx -- "${vsuffix#"${project}_"}" <<< "${v}" || { echo "ui settings at ${vsuffix}/${sfile}: ${reads}"; return 1; }
    channel="$(_ci_block_entry_field release "" default_channel)" || return 1
    lancache_ui_channel_override_is_valid "${channel}" || { echo "SOT channel ${channel} not UI-valid"; return 1; }
    mode="$(_rust_dhcp_modes "${root}" | awk 'NR == 2')" || return 1
    size="$(get_env_var CACHE_MAX_SIZE "$(_template_env)")" && unit="${size//[0-9]/}" || return 1
    gb=$(( ${size%"${unit}"} * 2 ))
    [ -n "${mode}" ] && lancache_ui_cache_max_gb_override_is_valid "${gb}" || { echo "no UI inputs: ${mode} ${gb}"; return 1; }
    printf '%s\n' "LANCACHE_IMAGE_CHANNEL=${channel}" AUTO_UPDATE_ENABLED=1 "DHCP_MODE=${mode}" \
        "CACHE_MAX_GB=${gb}" > "${DS}/volumes/${vsuffix}/${sfile}" || return 1
    _setup_sh_run 'cmd_converge_reconcile "${I}" && cp "${I}/.env" "${T}/env.first" && cmd_converge_reconcile "${I}"'
    [ "${status}" -eq 0 ] && cmp "${t}/env.first" "${I}/.env" || { echo "converge: ${output}"; return 1; }
    while IFS= read -r kv; do
        grep -qxF -- "${kv}" "${I}/.env" || { echo "missing ${kv}: $(paste -sd'#' "${I}/.env")"; return 1; }
    done < "${DS}/volumes/${vsuffix}/${sfile}"
    [ "$(get_env_var CACHE_MAX_SIZE "${I}/.env")" = "${gb}${unit}" ] || { echo "cache size not derived from ${gb}"; return 1; }
    ! env_key_exists COMPOSE_PROFILES "${I}/.env" || { echo "converge wrote COMPOSE_PROFILES"; return 1; }
}


# What: each flow checks the host arch before a change
# Why: no change on a host the stack cannot run on
# From: Issue #1683 | PR #1858
@test "setup flows refuse an unsupported arch before any change" {
    local root p dir flow tool
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    export CALLS ANS ARCH LANCACHE_BACKUP_ROOT
    CALLS="$(_val path)" ANS="$(_val path)" LANCACHE_BACKUP_ROOT="$(_val path)" dir="$(_val path)"
    : > "${ANS}"
    mkdir -p "${dir}" && : > "${dir}/docker-compose.yml" && : > "${dir}/.env" || return 1
    p="$(_pm_path systemctl)" || return 1
    _tool_stub "${p}" docker <<< 'printf "docker %s\n" "$*" >> "${CALLS:?}"' || return 1
    _tool_stub "${p}" uname <<< 'printf "%s\n" "${ARCH:?}"' || return 1
    _tool_stub "${p}" id <<< 'echo 0' || return 1
    for tool in realpath basename dirname; do
        ln -s "$(type -P "${tool}")" "${p}/${tool}" || return 1
    done
    for flow in ensure_stack_requirements_installed "perform_stack_update_flow ${dir}" "cmd_update_ip ${dir}"; do
        ARCH="$(_val name)"
        : > "${CALLS}"
        _pm_run "${p}" "${flow}"
        [ "${status}" -eq 1 ] && [[ "${output}" == *"This host's architecture '${ARCH}' has no container image platform"* ]] \
            && [ ! -s "${CALLS}" ] || { echo "${flow} ${ARCH}: rc ${status} calls [$(cat "${CALLS}")] ${output}"; return 1; }
    done
    # What: a supported arch passes on to the next step
    # Why: proves the refusal comes from the arch check
    ARCH=x86_64
    for flow in ensure_stack_requirements_installed "perform_stack_update_flow ${root}/deploy/prod" "cmd_update_ip ${dir}"; do
        : > "${CALLS}"
        _pm_run "${p}" "${flow}"
        [[ "${output}" != *"has no container image platform"* ]] || { echo "${flow} refused ${ARCH}: ${output}"; return 1; }
    done
}

# What: Kea preflight probes; asks when a server answers
# Why: a second DHCP server needs the operator's yes
# From: Issue #1683 | PR #1912
@test "setup kea preflight asks before a second dhcp server" {
    local root p env mode id want found none row
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    export CALLS ANS DOUT DRC
    CALLS="$(_val path)" ANS="$(_val path)" env="$(_val path)" mode="$(_val name)" id="$(_val name)"
    p="$(_pm_path)" || return 1
    _tool_stub "${p}" docker <<< 'printf "docker %s\n" "$*" >> "${CALLS:?}"; printf "%s\n" "${DOUT:-}"; exit "${DRC:-0}"' || return 1
    ln -s "$(type -P sed)" "${p}/sed" && ln -s "$(type -P jq)" "${p}/jq" || return 1
    want="docker compose --env-file ${env} -f ${root}/deploy/prod/docker-compose.yml run --rm --no-deps dhcp probe"
    found="{\"status\":\"conflict_found\",\"conflict\":{\"status\":\"found\",\"output\":\"${id}\",\"details\":[]}}"
    none='{"status":"client_failed","conflict":{"status":"not_found"},"client":{"status":"failed","output":"x"}}'
    # What: runs one row: mode, docker reply, answer
    # Why: each row checks rc, text and the docker call
    _kea_try() {
        DOUT="$3" DRC="$4"
        printf '%s\n' "$2" > "${ANS}" && : > "${CALLS}" || return 1
        _pm_run "${p}" "DHCP_MODE=$1; run_kea_dhcp_activation_preflight ${env}"
    }
    _kea_try "${mode}" y "" 0 || return 1
    [ "${status}" -eq 0 ] && [ ! -s "${CALLS}" ] || { echo "non-kea mode probed: $(cat "${CALLS}") ${output}"; return 1; }
    _kea_try kea n "${found}" 0 || return 1
    [ "${status}" -eq 1 ] && [ "$(cat "${CALLS}")" = "${want}" ] \
        && [[ "${output}" == *"An existing DHCP server answered before Kea activation: ${id}"*"Cancelled DHCP activation."* ]] \
        || { echo "server, no: rc ${status} calls [$(cat "${CALLS}")] ${output}"; return 1; }
    _kea_try kea y "${found}" 0 || return 1
    [ "${status}" -eq 0 ] && [[ "${output}" == *"answered before Kea activation: ${id}"* ]] \
        || { echo "server, yes: rc ${status} ${output}"; return 1; }
    _kea_try kea n "${none}" 0 || return 1
    [ "${status}" -eq 0 ] && [[ "${output}" == *"No DHCP server answer was detected before Kea activation."* ]] \
        && [[ "${output}" != *PROMPT* ]] || { echo "no server: rc ${status} ${output}"; return 1; }
    for row in "${id}|1" "${id}|0" '{"status":"unavailable"}|0'; do
        _kea_try kea n "${row%|*}" "${row##*|}" || return 1
        [ "${status}" -eq 1 ] && [[ "${output}" == *"could not be executed inside the dhcp image."*"Cancelled DHCP activation."* ]] \
            || { echo "probe not run (${row}), no: rc ${status} ${output}"; return 1; }
    done
}

# What: a missing record key fails each reader closed
# Why: a guessed field hid UNKNOWN or skipped a step
# From: Issue #1683 | PR #1858
@test "record field: a missing key fails every reader closed" {
    local k pre v w svc plat rec mark rel pid
    k="$(_val name)" pre="$(_val name)" v="$(_val name)" w="$(_val name)" svc="$(_val name)"
    plat="$(_val platform)" mark="$(_val path)" rel="$(_val path)" pid="$(_val int 2 99999)"
    run _ci_record_field "${pre}${k}=${w} ${k}=${v} ${pre}=${w}" "${k}"
    _expect own-key 0 "=${v}" || return 1
    run _ci_record_field "${k}=${v} ${pre}=${w}" "${k}"
    _expect first-key 0 "=${v}" || return 1
    run _ci_record_field "${k}= ${pre}=${w}" "${k}"
    _expect empty-value 0 "=" || return 1
    run _ci_record_field "${pre}${k}=${w}" "${k}"
    _expect absent 2 "[CI-ERROR-CORE-0143] key=\"${k}\" record=\"${pre}${k}=${w}\"" || return 1
    # What: stand-in for the step after the field read
    # Why: it runs only if a caller ignored the failure
    _next() { printf '[CI-NEXT] %s\n' "${FUNCNAME[1]}" >&2; return 2; }
    # What: one row: rc 2, the key, then no later step
    # Why: a later coded line means the caller went on
    _closed() {
        local case="$1" key="$2" after; shift 2
        run "$@"
        _expect "${case}" 2 "[CI-ERROR-CORE-0143] key=\"${key}\"" || return 1
        after="$(sed -n '/\[CI-ERROR-CORE-0143\]/,$p' <<< "${output}" | tail -n +2)"
        [[ "${after}" != *"[CI-"* ]] || { echo "${case}: went on after the read: ${output}"; return 1; }
    }
    export GITHUB_OUTPUT="${mark}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_platforms() { printf '%s\n' "${plat}"; }
    _ci_resolve_one() { printf 'service=%s platform=%s %s\n' "$1" "$2" "${rec}"; }
    _ci_semantic_impact() { _next; }
    rec="state=${w} identity=${w}"
    _closed plan-action action ci_cmd_plan_matrix "${CI_MANIFEST_REL}" || return 1
    rec="action=build state=${w}"
    _closed plan-identity identity ci_cmd_plan_matrix "${CI_MANIFEST_REL}" || return 1
    rec="action=build identity=${w}"
    _ci_semantic_impact() { return 3; }
    run ci_cmd_plan_matrix "${CI_MANIFEST_REL}"
    _expect plan-impact 2 - || return 1
    [ ! -s "${mark}" ] || { echo "plan-impact wrote a matrix: $(cat "${mark}")"; return 1; }
    _ci_trivy_cache_dir() { printf 'source=%s\n' "${w}"; }
    _ci_trivy_db_ensure_fresh() { _next; }
    _closed scan-dir dir _ci_trivy_scan "${svc}" "${w}" || return 1
    _ci_trivy_cache_dir() { printf 'dir=%s\n' "${mark}"; }
    run _ci_trivy_scan "${svc}" "${w}"
    _expect scan-db-setup 2 "[CI-NEXT] _ci_trivy_db_ensure_fresh" || return 1
    _ci_trivy_db_ensure_fresh() { printf 'fresh=%s\n' "${w}"; }
    _ci_image_ref() { _next; }
    _closed scan-present present _ci_trivy_scan "${svc}" "${w}" || return 1
    _ci_trivy_cache_dir() { _next; }
    run _ci_trivy_scan "${svc}" "${w}"
    _expect scan-cache-setup 2 "[CI-NEXT] _ci_trivy_cache_dir" || return 1
    _ci_image_ref() { printf '%s\n' "${w}"; }
    _ci_trivy_cache_dir() { printf 'source=%s\n' "${w}"; }
    trivy() { _next; }
    _closed sbom-dir dir _ci_trivy_sbom "${svc}" "${w}" "${mark}" || return 1
    rec="action=${w} identity=${w}"
    _ci_accepted_digest() { _next; }
    _closed assemble-state state _ci_collect_accepted_digests "${svc}" || return 1
    _ci_block_keys() { printf '%s\n' "${svc}"; }
    _ci_candidate_index() { _next; }
    _closed toolchain-state state _ci_toolchain_candidate || return 1
    ci_service_field() { _next; }
    rec="state=${w} identity=${w}"
    _closed build-action action _ci_build_one "${svc}" "${plat}" || return 1
    rec="action=build state=${w}"
    _closed build-identity identity _ci_build_one "${svc}" "${plat}" || return 1
    rec="action=build identity=${w}"
    _closed build-state state _ci_build_one "${svc}" "${plat}" || return 1
    rec="action=build identity=${w} state=${w}"
    ci_service_field() { printf '%s\n' "${w}"; }
    _ci_semantic_impact() { return 3; }
    run _ci_build_one "${svc}" "${plat}"
    _expect build-impact 2 "=" || return 1
    _ci_image_tag() { _next; }
    ci_cmd_build() { printf 'service=%s platform=%s identity=%s\n' "$1" "$2" "${w}"; }
    _closed ship-result result ci_cmd_ship "${svc}" "${plat}" || return 1
    ci_cmd_build() { printf 'service=%s platform=%s result=built\n' "$1" "$2"; }
    _closed ship-identity identity ci_cmd_ship "${svc}" "${plat}" || return 1
    ci_cmd_build() { printf 'service=%s platform=%s result=built identity=%s\n' "$1" "$2" "${w}"; }
    _ci_image_tag() { printf '%s\n' "${w}"; }
    _ci_bake_check() { return 0; }
    ci_cmd_publish() { printf 'service=%s identity=%s\n' "$1" "${w}"; }
    ci_cmd_verify() { _next; }
    _closed ship-published published ci_cmd_ship "${svc}" "${plat}" || return 1
    _ci_validate_release() { printf '%s\n' "$1" > "${rel}"; }
    _ci_validate_project() { _next; }
    _ci_validate_reserve() { printf 'holder=%s\n' "${pid}"; }
    _closed validate-subnet subnet _ci_validate_stack "${w}" || return 1
    [ "$(cat "${rel}")" = "${pid}" ] || { echo "validate-subnet: slot not released"; return 1; }
    rm -f "${rel}"
    _ci_validate_reserve() { printf 'subnet=%s\n' "${w}"; }
    _closed validate-holder holder _ci_validate_stack "${w}" || return 1
    [ ! -e "${rel}" ] || { echo "validate-holder: released without a holder"; return 1; }
}

# What: plan keeps verify pairs; a MISMATCH fails the plan
# Why: a produced artifact needs acceptance, not a rebuild
# From: Issue #1683 | PR #1912
@test "plan and ship: unverified pairs verify without a build, a mismatch fails" {
    local mark plat w d calls
    mark="$(_val path)" plat="$(_val platform)" w="$(_val name)" d="$(_val digest)" calls="$(_val path)"
    export GITHUB_OUTPUT="${mark}"
    : > "${mark}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_platforms() { printf '%s\n' "${plat}"; }
    _ci_platform_field() { printf '%s\n' "${w}"; }
    _ci_promote_targets_for_ref() { return 0; }
    _ci_semantic_impact() { echo "impact asked for a non-build action" >&2; return 2; }
    _ci_resolve_one() { printf 'service=%s platform=%s state=PRODUCED_UNVERIFIED action=verify identity=%s\n' "$1" "$2" "${w}"; }
    run ci_cmd_plan_matrix "${CI_MANIFEST_REL}"
    _expect plan-verify 0 - || return 1
    [ "$(grep -c '^any-build=true$' "${mark}")" -eq 1 ] && grep -q "\"identity\":\"${w}\"" "${mark}" \
        || { echo "verify pairs missing from the plan: $(cat "${mark}")"; return 1; }
    : > "${mark}"
    _ci_resolve_one() { printf 'service=%s platform=%s state=MISMATCH action=fail identity=%s\n' "$1" "$2" "${w}"; }
    run ci_cmd_plan_matrix "${CI_MANIFEST_REL}"
    _expect plan-mismatch 2 "[CI-ERROR-PLAN-0005];state=MISMATCH" || return 1
    [ ! -s "${mark}" ] || { echo "plan-mismatch wrote a matrix: $(cat "${mark}")"; return 1; }
    ci_cmd_build() { printf 'service=%s platform=%s result=verify identity=%s\n' "$1" "$2" "${w}"; }
    ci_cmd_publish() { echo "publish ran for a verify pair" >&2; return 2; }
    ci_cmd_verify() { printf '%s %s %s\n' "$1" "$2" "$3" > "${calls}"; }
    _ci_published_digest() { printf '%s\n' "${d}"; }
    run ci_cmd_ship "${w}" "${plat}"
    _expect ship-verify 0 - || return 1
    [ "$(cat "${calls}")" = "${w} ${d} ${plat}" ] || { echo "verify call: $(cat "${calls}")"; return 1; }
    _ci_published_digest() { return 2; }
    run ci_cmd_ship "${w}" "${plat}"
    _expect ship-no-digest 2 "[CI-ERROR-SHIP-0004]" || return 1
}

# What: a failed promotion move restores the moved services
# Why: the channel must never keep a mixed stack (§50)
# From: Issue #1683 | PR #1912
@test "promote move: a failed move or readback rolls the moved services back" {
    local st a b c pa pb pc na nb nc cand bad
    st="$(_val path)" a="$(_val name)" b="$(_val name)" c="$(_val name)"
    pa="$(_val digest)" pb="$(_val digest)" pc="$(_val digest)"
    na="$(_val digest)" nb="$(_val digest)" nc="$(_val digest)" bad="$(_val digest)"
    cand="${a}=${na}"$'\n'"${b}=${nb}"$'\n'"${c}=${nc}"
    mkdir -p "${st}" || return 1
    _reset() { printf '%s\n' "${pa}" > "${st}/${a}"; printf '%s\n' "${pb}" > "${st}/${b}"; printf '%s\n' "${pc}" > "${st}/${c}"; }
    _ci_channel_readback() { cat "${st}/$1"; }
    _ci_promote_move() {
        [ "$1" != "${FAIL_MOVE:-}" ] || return 1
        if [ "$3" = "${BAD_DIGEST:-}" ]; then printf '%s\n' "${bad}" > "${st}/$1"; else printf '%s\n' "$3" > "${st}/$1"; fi
    }
    _reset
    run _ci_promote_move_all stable "${cand}"
    _expect all-moved 0 - || return 1
    [ "$(cat "${st}/${a}")" = "${na}" ] && [ "$(cat "${st}/${c}")" = "${nc}" ] || { echo "not moved"; return 1; }
    _reset
    FAIL_MOVE="${c}" run _ci_promote_move_all stable "${cand}"
    _expect move-failed 2 "[CI-ERROR-PROMOTE-0007]" || return 1
    [ "$(cat "${st}/${a}")" = "${pa}" ] && [ "$(cat "${st}/${b}")" = "${pb}" ] && [ "$(cat "${st}/${c}")" = "${pc}" ] \
        || { echo "move failure left a mixed channel"; return 1; }
    _reset
    BAD_DIGEST="${nb}" run _ci_promote_move_all stable "${cand}"
    _expect readback-mismatch 2 "[CI-ERROR-PROMOTE-0009];rolling the moved services back" || return 1
    [ "$(cat "${st}/${a}")" = "${pa}" ] && [ "$(cat "${st}/${b}")" = "${pb}" ] && [ "$(cat "${st}/${c}")" = "${pc}" ] \
        || { echo "mismatch left a mixed channel"; return 1; }
}

# What: scan-stack scans every pair and lists the failures
# Why: one finding must not hide the other pairs' results
# From: Issue #1683 | PR #1912
@test "scan stack: a failing pair does not stop the others, the code is kept" {
    local a b c calls d
    a="$(_val name)" b="$(_val name)" c="$(_val name)" calls="$(_val path)" d="$(_val digest)"
    _ci_require_ghcr_auth() { return 0; }
    _ci_published_digest() { [ "$1" != "${c}" ] || return 2; printf '%s\n' "${d}"; }
    ci_cmd_scan() { echo "$1" >> "${calls}"; [ "$1" != "${a}" ] || return 1; }
    : > "${calls}"
    CI_BUILD_MATRIX="{\"include\":[{\"service\":\"${a}\",\"platform\":\"p/x\"},{\"service\":\"${b}\",\"platform\":\"p/x\"},{\"service\":\"${c}\",\"platform\":\"p/x\"}]}" \
        run ci_cmd_scan_stack
    _expect scan-failures 2 "[CI-ERROR-SCAN-0017];[CI-ERROR-SCAN-0024];failed=\"${a}/p/x ${c}/p/x\"" || return 1
    [ "$(tr '\n' ' ' < "${calls}")" = "${a} ${b} " ] || { echo "scanned: $(tr '\n' ' ' < "${calls}")"; return 1; }
    ci_cmd_scan() { echo "$1" >> "${calls}"; [ "$1" != "${a}" ] || return 1; }
    _ci_published_digest() { printf '%s\n' "${d}"; }
    : > "${calls}"
    CI_BUILD_MATRIX="{\"include\":[{\"service\":\"${a}\",\"platform\":\"p/x\"},{\"service\":\"${b}\",\"platform\":\"p/x\"}]}" \
        run ci_cmd_scan_stack
    _expect scan-finding 1 "[CI-ERROR-SCAN-0024]" || return 1
    [ "$(wc -l < "${calls}")" -eq 2 ] || { echo "finding stopped the scan: $(cat "${calls}")"; return 1; }
}

# What: scan passes clean pairs on; an image-less pair skips
# Why: Q7: a red service must not keep the others unaccepted
# From: Issue #1683 | PR #1912
@test "scan stack: clean pairs are the output, a pair without image is skipped" {
    local a b c d out
    a="$(_val name)" b="$(_val name)" c="$(_val name)" d="$(_val digest)" out="$(_val path)"
    : > "${out}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_published_digest() { [ "$1" != "${c}" ] || return 1; printf '%s\n' "${d}"; }
    ci_cmd_scan() { [ "$1" != "${a}" ] || return 1; }
    GITHUB_OUTPUT="${out}" CI_BUILD_MATRIX="{\"include\":[{\"service\":\"${a}\",\"platform\":\"p/x\"},{\"service\":\"${b}\",\"platform\":\"p/x\"},{\"service\":\"${c}\",\"platform\":\"p/x\"}]}" \
        run ci_cmd_scan_stack
    _expect scan-partial 1 "[CI-WARN-SCAN-0025];[CI-ERROR-SCAN-0024];failed=\"${a}/p/x\"" || return 1
    [ "$(cat "${out}")" = "passed={\"include\":[{\"service\":\"${b}\",\"platform\":\"p/x\"}]}" ] \
        || { echo "passed output: $(cat "${out}")"; return 1; }
}

# What: a status issue per case: red files, green closes
# Why: one label per case; no case closes another's issue
# From: Issue #1683 | PR #1912
@test "status report: one issue per case, red files, green closes" {
    local calls listed="" kind lab labels="" svc arch scope
    local -x GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_SHA GITHUB_RUN_ID GITHUB_EVENT_NAME CI_MANIFEST_ENV
    GITHUB_REPOSITORY="$(_val name)/$(_val name)" GITHUB_SERVER_URL="https://$(_val host)" GITHUB_SHA="$(_val digest)"
    GITHUB_RUN_ID="$(_val int 1 99999)" GITHUB_EVENT_NAME="$(_val name)" svc="$(_val name)" arch="$(_val name)"
    calls="$(_val path)" listed=""
    gh() {
        printf '%s\n' "$*" >> "${calls}"
        case "$*" in
            "issue list"*) printf '%s' "${listed}" ;;
        esac
    }
    for kind in trivy-finding trivy-db-unavailable trivy-scan-error; do
        lab="$(_ci_block_entry_field status_reports "${kind}" label)-${svc}-${arch}"
        [[ " ${labels} " != *" ${lab} "* ]] || { echo "${kind}: label ${lab} is shared"; return 1; }
        labels+=" ${lab}"
        scope="$(_ci_block_entry_field status_reports "${kind}" scope)"
        scope="${scope//@SERVICE@/${svc}}" scope="${scope//@ARCH@/${arch}}"
        { : > "${calls}"; listed=""; }
        run _ci_status_case "${kind}" failure "${svc}" "${arch}" "raw-$(_val name)"
        _expect "${kind}-open-new" 0 "status=opened label=${lab}" || return 1
        grep -qF -- "label create ${lab} " "${calls}" && grep -qF -- "issue create --repo ${GITHUB_REPOSITORY} --label ${lab} --title [${lab}] ${scope}" "${calls}" \
            || { echo "${kind}: no label and issue create: $(cat "${calls}")"; return 1; }
        { : > "${calls}"; listed="$(_val int 1 999)"; }
        run _ci_status_case "${kind}" failure "${svc}" "${arch}"
        _expect "${kind}-open-again" 0 "status=updated label=${lab} issue=${listed}" || return 1
        ! grep -q "issue create\|issue close" "${calls}" || { echo "${kind}: a second issue or a close: $(cat "${calls}")"; return 1; }
        : > "${calls}"
        run _ci_status_case "${kind}" success "${svc}" "${arch}"
        _expect "${kind}-green-closes" 0 "status=closed label=${lab} issue=${listed}" || return 1
        grep -q "^issue comment ${listed} " "${calls}" && grep -q "^issue close ${listed} " "${calls}" || { echo "${kind}: no comment and close: $(cat "${calls}")"; return 1; }
        { : > "${calls}"; listed=""; }
        run _ci_status_case "${kind}" success "${svc}" "${arch}"
        _expect "${kind}-green-none" 0 "status=noop label=${lab}" || return 1
        [ "$(wc -l < "${calls}")" -eq 1 ] || { echo "${kind}: a green with no issue wrote: $(cat "${calls}")"; return 1; }
    done
    for kind in nightly-cargo-audit nightly-promote; do
        lab="$(_ci_block_entry_field status_reports "${kind}" label)"
        [[ " ${labels} " != *" ${lab} "* ]] || { echo "${kind}: label ${lab} is shared"; return 1; }
        labels+=" ${lab}"
    done
    gh() { echo "gh: boom" >&2; return 1; }
    run _ci_status_case trivy-finding failure "${svc}" "${arch}"
    _expect gh-fails 2 "[CI-ERROR-STATUS-0003];gh: boom" || return 1
}

# What: each scan status settles only the cases it proves
# Why: an error says nothing of findings, an outage none
# From: Issue #1683 | PR #1912
@test "scan report: each status settles only the cases it proves" {
    local calls svc plat row st want got raw
    local -x PR_IS_FORK=false GITHUB_EVENT_NAME=push GITHUB_ACTOR
    svc="$(_val name)" plat="p/$(_val name)" calls="$(_val path)" raw="$(_val name)" GITHUB_ACTOR="$(_val name)"
    _ci_status_case() { printf '%s %s %s %s [%s]\n' "$1" "$2" "$3" "$4" "$5" >> "${calls}"; }
    while IFS='|' read -r st want; do
        : > "${calls}"
        run _ci_scan_report "${svc}" "${plat}" "${st}" "${raw}"
        [ "${status}" -eq 0 ] || { echo "status ${st}: rc ${status}: ${output}"; return 1; }
        got="$(sed "s|${svc} ${plat#*/}||; s|  *| |g" "${calls}" | paste -sd'|')"
        [ "${got}" = "${want}" ] || { echo "status ${st}: got '${got}' want '${want}'"; return 1; }
    done <<ROWS
0|trivy-finding success []|trivy-scan-error success []|trivy-db-unavailable success []
1|trivy-finding failure [${raw}]|trivy-scan-error success []|trivy-db-unavailable success []
4|trivy-scan-error failure [${raw}]|trivy-db-unavailable success []
6|trivy-db-unavailable failure [${raw}]
2|trivy-scan-error failure [${raw}]
$(_val int 7 99)|trivy-scan-error failure [${raw}]
ROWS
    : > "${calls}"
    GITHUB_EVENT_NAME=pull_request PR_IS_FORK=true run _ci_scan_report "${svc}" "${plat}" 1 "${raw}"
    _expect fork-not-run 0 "scan-report=NOT-RUN service=${svc};fork PR" || return 1
    [ ! -s "${calls}" ] || { echo "a fork PR wrote: $(cat "${calls}")"; return 1; }
    GITHUB_EVENT_NAME=pull_request GITHUB_ACTOR="$(_ci_variable CI_READONLY_TOKEN_ACTORS)" run _ci_scan_report "${svc}" "${plat}" 1 "${raw}"
    _expect bot-not-run 0 "scan-report=NOT-RUN service=${svc};bot PR" || return 1
    [ ! -s "${calls}" ] || { echo "a bot PR wrote: $(cat "${calls}")"; return 1; }
    GITHUB_EVENT_NAME=pull_request run _ci_scan_report "${svc}" "${plat}" 0 ""
    [ "${status}" -eq 0 ] && [ "$(wc -l < "${calls}")" -eq 3 ] || { echo "a same-repo PR did not report: ${output}"; return 1; }
}

# What: a failed run without a fresh DB is the DB cause
# Why: DB outage and scan error are separate issues
# From: Issue #1683 | PR #1912
@test "scan: a failed trivy run reports the DB cause only without a fresh DB" {
    local svc dir
    svc="$(_val name)" dir="$(_val path)"
    _ci_trivy_cache_dir() { printf 'dir=%s\n' "${dir}"; }
    _ci_trivy_db_ensure_fresh() { printf 'present=false\n'; }
    _ci_image_ref() { printf '%s\n' "$1"; }
    _ci_trivy_args() { printf '%s\n' trivy; }
    _ci_retry() { return 1; }
    _ci_trivy_db_fresh() { return 1; }
    run _ci_trivy_scan "${svc}" "$(_val digest)"
    [ "${status}" -eq 6 ] || { echo "no fresh DB: rc ${status}: ${output}"; return 1; }
    _ci_trivy_db_fresh() { return 0; }
    run _ci_trivy_scan "${svc}" "$(_val digest)"
    [ "${status}" -eq 4 ] || { echo "fresh DB: rc ${status}: ${output}"; return 1; }
    run _ci_scan_outcome "${svc}" 6 "$(_val name)"
    _expect db-outcome 3 "[CI-ERROR-SCAN-0028] service=\"${svc}\"" || return 1
}

# What: the scheduled scan covers every target and platform
# Why: an unchanged image is never built, so never scanned
# From: Issue #1683 | PR #1912
@test "scan channel: every target and platform is a matrix pair" {
    local out t p want=0 got
    out="$(_val path)"
    ci_cmd_scan_stack() { printf '%s' "${CI_BUILD_MATRIX}" > "${out}"; }
    run ci_cmd_scan_channel
    [ "${status}" -eq 0 ] || { echo "scan-channel: rc ${status}: ${output}"; return 1; }
    for t in $(ci_build_targets); do
        [ "$(jq -r --arg t "${t}" '[.include[] | select(.service == $t)] | length' "${out}")" -ge 1 ] || { echo "${t} is not scanned: $(cat "${out}")"; return 1; }
    done
    while read -r p; do
        jq -e --arg p "${p}" '[.include[] | select(.platform == $p)] | length > 0' "${out}" >/dev/null || { echo "platform ${p} is not scanned"; return 1; }
    done <<< "$(_ci_block_entry_list build_matrix "" platforms)"
    got="$(jq -r '.include | length' "${out}")"
    [ "${got}" -gt 0 ] || { echo "empty matrix"; return 1; }
}

# What: each nightly kind reads its jobs; skipped is NOT-RUN
# Why: a red job still reports; kinds stay apart
# From: Issue #1683 | PR #1912
@test "nightly report: each kind reads its jobs, a skipped job is NOT-RUN" {
    local calls kind jobs j needs all="" lab_a lab_p
    calls="$(_val path)"
    _ci_status_apply() { printf '%s|%s|%s\n' "$2" "$1" "$4" >> "${calls}"; }
    lab_a="$(_ci_block_entry_field status_reports nightly-cargo-audit label)"
    lab_p="$(_ci_block_entry_field status_reports nightly-promote label)"
    [ "${lab_a}" != "${lab_p}" ] || { echo "both kinds share the label ${lab_a}"; return 1; }
    jobs="$(_ci_block_entry_list status_reports nightly-cargo-audit jobs; echo; _ci_block_entry_list status_reports nightly-promote jobs)"
    _needs() {
        local out="" e
        for e in "$@"; do out+="${out:+,}\"${e%%=*}\":{\"result\":\"${e#*=}\",\"outputs\":{}}"; done
        printf '{%s}' "${out}"
    }
    for j in ${jobs}; do all+=" ${j}=success"; done
    : > "${calls}"
    CI_NEEDS="$(_needs ${all})" run ci_cmd_nightly_report
    _expect all-green 0 - || return 1
    [ "$(cut -d'|' -f1,2 "${calls}")" = "$(printf '%s|success\n%s|success\n' "${lab_a}" "${lab_p}")" ] || { echo "all green: $(cat "${calls}")"; return 1; }
    kind="$(_ci_block_entry_list status_reports nightly-cargo-audit jobs | head -n 1)"
    : > "${calls}"
    CI_NEEDS="$(_needs ${all/ ${kind}=success/ ${kind}=failure})" run ci_cmd_nightly_report
    _expect audit-red 0 - || return 1
    grep -q "^${lab_a}|failure|" "${calls}" && grep -q "^${lab_p}|success|" "${calls}" || { echo "audit red: $(cat "${calls}")"; return 1; }
    grep -q "${kind}=failure" "${calls}" || { echo "evidence misses the red job: $(cat "${calls}")"; return 1; }
    kind="$(_ci_block_entry_list status_reports nightly-promote jobs | head -n 1)"
    : > "${calls}"
    CI_NEEDS="$(_needs ${all/ ${kind}=success/ ${kind}=failure})" run ci_cmd_nightly_report
    grep -q "^${lab_p}|failure|" "${calls}" && grep -q "^${lab_a}|success|" "${calls}" || { echo "promote red: $(cat "${calls}")"; return 1; }
    : > "${calls}"
    CI_NEEDS="$(_needs ${all/ ${kind}=success/ ${kind}=skipped})" run ci_cmd_nightly_report
    _expect skipped 0 "status=NOT-RUN kind=nightly-promote" || return 1
    ! grep -q "^${lab_p}|" "${calls}" || { echo "a skipped job gave a verdict: $(cat "${calls}")"; return 1; }
    : > "${calls}"
    CI_NEEDS="$(_needs ${all/ ${kind}=success/ ${kind}=skipped} $(_val name)=failure)" run ci_cmd_nightly_report
    CI_NEEDS="$(_needs ${all/ ${kind}=success/})" run ci_cmd_nightly_report
    _expect job-missing 2 "[CI-ERROR-STATUS-0011] kind=\"nightly-promote\" job=\"${kind}\"" || return 1
}

# What: release images lists every target digest and stack
# Why: the provenance matrix is the only attested set
# From: Issue #1683 | PR #1912
@test "release images: one matrix entry per target and the stack" {
    local out t d n
    out="$(_val path)" d="$(_val digest)"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { printf '%s\n' "${d}"; }
    GITHUB_OUTPUT="${out}" run ci_cmd_release_images "v$(_val int 1 9).$(_val int 1 9).$(_val int 1 9)"
    [ "${status}" -eq 0 ] || { echo "release-images: rc ${status}: ${output}"; return 1; }
    n="$(sed -n 's/^matrix=//p' "${out}")"
    for t in $(ci_build_targets) stack; do
        jq -e --arg t "${t}" --arg d "${d}" '[.include[] | . as $e | select(($e.name | endswith("/" + $t)) and $e.digest == $d and ($e.name | startswith($e.registry + "/")))] | length == 1' <<< "${n}" >/dev/null \
            || { echo "${t}: not one entry with the digest: ${n}"; return 1; }
    done
    [ "$(jq '.include | length' <<< "${n}")" -eq $(( $(ci_build_targets | wc -l) + 1 )) ] || { echo "entry count: ${n}"; return 1; }
    run ci_cmd_release_images
    _expect release-images-tag 2 "[CI-ERROR-RELEASE-0053]" || return 1
}

# What: assemble goes on after a service that fails
# Why: one service without both platforms blocks no other
# From: Issue #1683 | PR #1912
@test "assemble stack: a failing service does not stop the others" {
    local a b calls
    a="$(_val name)" b="$(_val name)" calls="$(_val path)"
    : > "${calls}"
    ci_cmd_assemble() { echo "$1" >> "${calls}"; [ "$1" != "${a}" ] || return 2; }
    CI_BUILD_MATRIX="{\"include\":[{\"service\":\"${a}\",\"platform\":\"p/x\"},{\"service\":\"${b}\",\"platform\":\"p/x\"}]}" \
        run ci_cmd_assemble_stack
    _expect assemble-partial 2 "[CI-ERROR-ASSEMBLE-0012];failed=\"${a}\"" || return 1
    [ "$(wc -l < "${calls}")" -eq 2 ] || { echo "assembled: $(cat "${calls}")"; return 1; }
}

# What: push digest must equal the registry digest
# Why: a mismatch must never reach the ledger as accepted
# From: Issue #1683 | PR #1912
@test "publish: the push digest must equal the registry digest" {
    local svc d1 d2 ref
    svc="$(_val name)" d1="$(_val digest)" d2="$(_val digest)" ref="$(_val name)"
    _ci_image_tag() { printf '%s\n' "${ref}"; }
    _ci_retry() { printf 'latest: digest: %s size: 401\n' "${PUSHED}"; }
    _ci_registry_digest() { printf '%s\n' "${SEEN}"; }
    PUSHED="${d1}" SEEN="${d1}" run _ci_docker_publish "${svc}" x p/x
    _expect same 0 "${d1}" || return 1
    PUSHED="${d1}" SEEN="${d2}" run _ci_docker_publish "${svc}" x p/x
    _expect differ 2 "[CI-ERROR-PUBLISH-0006]" || return 1
    _ci_retry() { printf 'no digest line\n'; }
    PUSHED="" SEEN="${d1}" run _ci_docker_publish "${svc}" x p/x
    _expect no-digest 2 "[CI-ERROR-PUBLISH-0006];pushed=\"none\"" || return 1
}

# What: GC delete counts a vanished version as deleted
# Why: the goal is "version gone"; a 404 reached it
# From: Issue #1683 | PR #1912
@test "gc delete: a 404 on the delete is the goal reached, other errors fail" {
    local cand
    cand="$(printf 'n\t123\tt\ttags\tsvc')"
    _ci_repo() { printf 'org/repo\n'; }
    _ci_retry() {
        if [ "$1" = github-api ]; then printf '%s\n' "${DELOUT}"; return "${DELRC}"; fi
        printf '2026-01-01T00:00:00Z\n'
    }
    DELRC=0 DELOUT="" run _ci_gc_delete "${cand}"
    _expect deleted 0 "" || return 1
    DELRC=2 DELOUT="gh: Not Found (HTTP 404)" run _ci_gc_delete "${cand}"
    _expect gone 0 "[CI-INFO-GC-0034]" || return 1
    DELRC=2 DELOUT="gh: Forbidden (HTTP 403)" run _ci_gc_delete "${cand}"
    [ "${status}" -eq 2 ] || { echo "403 rc=${status}"; return 1; }
}

# What: every ledger/registry pair maps to one state+action
# Why: only MISSING builds; MISMATCH fails; UNKNOWN stops
# From: Issue #1683 | PR #1912
@test "resolver: each ledger and registry pair gives one state and action" {
    local d1 d2 row lrc lstate prc want act got
    d1="$(_val digest)" d2="$(_val digest)"
    _ci_git_remote() { printf 'origin\n'; }
    _ci_image_tag() { printf 'x\n'; }
    _ci_ledger_read() { [ "${LRC}" -ne 0 ] && return "${LRC}"; printf '%s\t%s\n' "${LSTATE}" "${LDIG}"; }
    _ci_registry_probe() { [ "${PRC}" -ne 0 ] && return "${PRC}"; printf '%s\n' "${PDIG}"; }
    # columns: ledger rc, ledger state, ledger digest, probe rc, probe digest, state, action
    for row in \
        "1 - - 1 - MISSING_CONFIRMED build" \
        "1 - - 0 ${d1} PRODUCED_UNVERIFIED verify" \
        "0 ACCEPTED ${d1} 0 ${d1} PRESENT_ACCEPTED noop" \
        "0 ACCEPTED ${d1} 0 ${d2} MISMATCH fail" \
        "0 ACCEPTED ${d1} 1 - MISMATCH fail" \
        "0 PRODUCED ${d1} 0 ${d1} PRODUCED_UNVERIFIED verify" \
        "2 - - 1 - UNKNOWN escalate" \
        "1 - - 2 - UNKNOWN escalate"; do
        read -r lrc lstate LDIG prc PDIG want act <<< "${row}"
        LRC="${lrc}" LSTATE="${lstate}" PRC="${prc}"
        got="$(_ci_resolve_state s i p/x)"
        [ "${got}" = "${want}" ] || { echo "row [${row}] state ${got}"; return 1; }
        got="$(_ci_resolve_action "${got}")"
        [ "${got}" = "${act}" ] || { echo "row [${row}] action ${got}"; return 1; }
    done
}

# What: the lock is held, waited on, taken over, released
# Why: a fresh lock is never taken or freed by others
# From: Issue #1683 | PR #1912
@test "lock: a fresh lock is held, a stale one taken over, only the holder frees it" {
    local o w ref
    o="$(_val path)" w="$(_val path)" ref="refs/ci/t/$(_val name)"
    git init -q --bare "${o}" && git init -q "${w}" && git -C "${w}" remote add origin "${o}" || return 1
    cd "${w}" || return 1
    export GIT_CONFIG_GLOBAL=/dev/null
    sleep() { :; }
    run _ci_lock_acquire origin "${ref}" "holder-a" 1 0 900
    _expect first-acquire 0 - || return 1
    run _ci_lock_acquire origin "${ref}" "holder-b" 2 0 900
    _expect held-fresh 1 "[CI-ERROR-CAS-0002]" || return 1
    run _ci_lock_release origin "${ref}" "holder-b"
    _expect foreign-release 0 "[CI-INFO-CAS-0007]" || return 1
    [ -n "$(git ls-remote origin "${ref}")" ] || { echo "foreign release freed the lock"; return 1; }
    run _ci_lock_acquire origin "${ref}" "holder-b" 1 0 0
    _expect stale-takeover 0 "[CI-INFO-CAS-0001]" || return 1
    run _ci_lock_release origin "${ref}" "holder-b"
    _expect own-release 0 - || return 1
    [ -z "$(git ls-remote origin "${ref}")" ] || { echo "own release left the lock"; return 1; }
    run _ci_lock_release origin "${ref}" "holder-b"
    _expect absent-release 0 - || return 1
}

# What: verify compares the registry digest to the expected
# Why: produced != accepted must fail before any smoke test
# From: Issue #1683 | PR #1912
@test "verify: a readback mismatch and a failed readback both fail" {
    local d1 d2
    d1="$(_val digest)" d2="$(_val digest)"
    _ci_require_ghcr_auth() { return 0; }
    _ci_identity_for() { printf 'id\n'; }
    _ci_image_tag() { printf 'x\n'; }
    _ci_registry_digest() { printf '%s\n' "${d2}"; }
    run _ci_verify_one svc p/x "${d1}"
    _expect mismatch 2 "[CI-ERROR-VERIFY-0005]" || return 1
    _ci_registry_digest() { return 2; }
    run _ci_verify_one svc p/x "${d1}"
    _expect readback 2 "[CI-ERROR-VERIFY-0006]" || return 1
}

# What: version sync twice in a row changes nothing
# Why: Q2: the second run must report changed=0
# From: Issue #1683 | PR #1912
@test "version sync: the second run changes nothing" {
    local dir
    dir="$(_val path)"
    mkdir -p "${dir}" || return 1
    printf '[workspace.package]\nversion = "0.0.1"\nlicense = "X"\n\n[dependencies]\nversion = "9"\n' > "${dir}/Cargo.toml"
    printf '[[package]]\nname = "own"\nversion = "0.0.1"\n\n[[package]]\nname = "dep"\nversion = "1.2.3"\n' > "${dir}/Cargo.lock"
    printf '0.0.1\n' > "${dir}/VERSION"
    _ci_release_value() { case "$1" in version) printf '2.0.0\n' ;; *) printf 'AGPL\n' ;; esac; }
    _ci_repo_path() { case "$1" in CI_CARGO_LOCK) printf '%s/Cargo.lock\n' "${dir}" ;; *) printf '%s/VERSION\n' "${dir}" ;; esac; }
    _ci_cargo_member_names() { printf 'own\n'; }
    run _ci_version_release_sync
    _expect first-run 0 "changed=3" || return 1
    cp -r "${dir}" "${dir}.after" || return 1
    run _ci_version_release_sync
    _expect second-run 0 "changed=0" || return 1
    diff -r "${dir}" "${dir}.after" || return 1
    grep -q '^version = "1.2.3"$' "${dir}/Cargo.lock" || { echo "dependency version touched"; return 1; }
}

# What: GC run: dry-run deletes nothing, apply is repeatable
# Why: a rerun finds nothing; the policy gates delete
# From: Issue #1683 | PR #1912
@test "gc run: dry-run keeps all, apply deletes, a rerun is a noop, policy gates" {
    local calls
    calls="$(_val path)"
    : > "${calls}"
    _ci_gc_candidates() { printf '%s' "${CANDS}"; }
    _ci_gc_classify() { printf 'DELETE\n'; }
    _ci_deletion_policy() { printf '%s\n' "${POLICY}"; }
    _ci_require_ghcr_auth() { return 0; }
    _ci_gc_delete() { echo "$1" >> "${calls}"; return "${DELRC}"; }
    POLICY=manual-or-approved-automation-only DELRC=0 CANDS=$'a\t1\nb\t2\n'
    run _ci_gc_run dry-run
    _expect dry-run 0 "delete=2 deleted=0 mode=dry-run" || return 1
    [ ! -s "${calls}" ] || { echo "dry-run deleted: $(cat "${calls}")"; return 1; }
    run _ci_gc_run apply
    _expect apply 0 "delete=2 deleted=2 mode=apply" || return 1
    CANDS=""
    run _ci_gc_run apply
    _expect rerun 0 "result=noop candidates=0" || return 1
    CANDS=$'a\t1\n'
    POLICY="not-manual-or-approved-automation-only"
    run _ci_gc_run apply
    _expect policy 2 "[CI-ERROR-GC-0008]" || return 1
    POLICY=manual-or-approved-automation-only DELRC=2
    run _ci_gc_run apply
    _expect delete-fail 2 "[CI-ERROR-GC-0009]" || return 1
}

# What: SBOM per digest is reused; a foreign SBOM fails
# Why: a rerun makes no new SBOM; an unbound one fails
# From: Issue #1683 | PR #1912
@test "release sbom: a bound SBOM is reused, an unbound one fails, none is generated" {
    local d1 d2
    d1="$(_val digest)" d2="$(_val digest)"
    _ci_require_ghcr_auth() { return 0; }
    _ci_image_ref() { printf 'img\n'; }
    _ci_registry_digest() { printf '%s\n' "${d1}"; }
    _ci_release_asset_get() { printf '{"digest":"%s"}\n' "${ATT}" > "$3/$2"; }
    _ci_trivy_sbom() { echo "generated" >&2; return 2; }
    ATT="${d1}" run ci_cmd_release_sbom svc v1
    _expect reused 0 "release=sbom-reused" || return 1
    ATT="${d2}" run ci_cmd_release_sbom svc v1
    _expect unbound 2 "[CI-ERROR-RELEASE-0046]" || return 1
    [[ "${output}" != *generated* ]] || { echo "an SBOM was generated"; return 1; }
}

# What: promotion is current only if every channel matches
# Why: a rerun after a full move must have nothing to do
# From: Issue #1683 | PR #1912
@test "promote: all-current is true only if every service matches" {
    local d1 d2
    d1="$(_val digest)" d2="$(_val digest)"
    _ci_channel_readback() { case "$1" in a) printf '%s\n' "${d1}" ;; *) printf '%s\n' "${OTHER}" ;; esac; }
    OTHER="${d1}" run _ci_promote_all_current ch $'a='"${d1}"$'\nb='"${d1}"
    _expect all-current 0 - || return 1
    OTHER="${d2}" run _ci_promote_all_current ch $'a='"${d1}"$'\nb='"${d1}"
    _expect one-differs 1 - || return 1
}

# What: a ui form post that is not a 303 shows the body
# Why: a bare 500 does not name the cause of the failure
# From: Issue #1683 | PR #1912
@test "validate ui post: a non-303 answer logs the response body" {
    local body
    body="$(_val name)"
    curl() { printf '%s' "${BODY}" > "$5"; printf '%s' "${CODE}"; }
    BODY="${body}" CODE=500 run _ci_validate_ui_post http://x /tmp/jar /p a=b
    _expect not-303 1 "[CI-ERROR-VALIDATE-0034];code=\"500\";${body}" || return 1
    BODY="" CODE=303 run _ci_validate_ui_post http://x /tmp/jar /p a=b
    _expect is-303 0 - || return 1
}

# What: ledger keeps one record per identity; races re-read
# Why: a conflict fails closed; a lost race must merge
# From: Issue #1683 | PR #1912
@test "ledger: same record is idempotent, a conflict fails, a lost race is retried" {
    local o w id svc plat d1 d2 dir calls tries
    o="$(_val path)" w="$(_val path)" id="$(_val sha)" svc="$(_val name)" plat="$(_val platform)"
    d1="$(_val digest)" d2="$(_val digest)" dir="$(_val path)" calls="$(_val path)"
    git init -q --bare "${o}" && git init -q "${w}" && git -C "${w}" remote add origin "${o}" || return 1
    cd "${w}" || return 1
    _put() { printf '%s\t%s\t%s\tACCEPTED\t%s\n' "${id}" "${svc}" "${plat}" "$1" | _ci_ledger_upsert origin; }
    run _put "${d1}"
    _expect first-write 0 "[CI-INFO-LEDGER-0004]" || return 1
    run _put "${d1}"
    _expect same-record 0 "[CI-INFO-LEDGER-0005]" || return 1
    run _put "${d2}"
    _expect conflict 3 "[CI-ERROR-LEDGER-0006]" || return 1
    run _ci_ledger_read origin "${id}"
    _expect kept-first 0 "=ACCEPTED"$'\t'"${d1}" || return 1
    mkdir -p "${dir}" && jq -cn --arg s "${svc}" --arg p "${plat}" --arg i "${id}" --arg d "${d1}" \
        '{service:$s, platform:$p, build_identity:$i, digest:$d, state:"ACCEPTED"}' > "${dir}/r.json" || return 1
    tries="$(_ci_variable CI_RETRY_MAX_ATTEMPTS)" || return 1
    : > "${calls}"
    _ci_ledger_upsert() { cat > /dev/null; echo x >> "${calls}"; [ "$(wc -l < "${calls}")" -ge 2 ] || return 2; }
    run ci_cmd_aggregate "${dir}"
    _expect race-retried 0 "aggregate records=1" || return 1
    [ "$(wc -l < "${calls}")" -eq 2 ] || { echo "race: $(wc -l < "${calls}") writes, want 2"; return 1; }
    : > "${calls}"
    _ci_ledger_upsert() { cat > /dev/null; echo x >> "${calls}"; return 2; }
    run ci_cmd_aggregate "${dir}"
    _expect race-lost 2 - || return 1
    [ "$(wc -l < "${calls}")" -eq "${tries}" ] || { echo "race: $(wc -l < "${calls}") writes, want ${tries}"; return 1; }
}

# What: a channel run checks out its SOT source or a pin
# Why: a schedule run starts on the default branch tip
# From: Issue #1683 | PR #1858
@test "channel checkout: SOT source ref, pinned commit, coded misuse" {
    local o s w rows ch ref other src next
    local -a commit
    local -x CI_GIT_REMOTE GITHUB_OUTPUT
    o="$(_val path)" s="$(_val path)" w="$(_val path)" other="$(_val name)"
    CI_GIT_REMOTE="$(_val name)" GITHUB_OUTPUT="$(_val path)"
    rows="$(_ci_channel_field source_ref)" || { echo "SOT source_ref rows: ${rows}"; return 1; }
    ch="$(awk 'NR == 1 { print $1 }' <<< "${rows}")" ref="$(awk 'NR == 1 { print $2 }' <<< "${rows}")"
    [ -n "${ch}" ] && [[ "${ref}" == refs/heads/?* ]] || { echo "SOT source_ref rows: ${rows}"; return 1; }
    commit=(git -C "${s}" -c user.email="$(_val name)@$(_val host)" -c user.name="$(_val name)" commit -q --allow-empty -m)
    git init -q --bare "${o}" && git -C "${o}" config uploadpack.allowReachableSHA1InWant true && git init -q "${s}" || return 1
    "${commit[@]}" "${other}" && git -C "${s}" push -q "${o}" "HEAD:refs/heads/${other}" || return 1
    "${commit[@]}" "${ch}" && git -C "${s}" push -q "${o}" "HEAD:${ref}" && src="$(git -C "${s}" rev-parse HEAD)" || return 1
    git init -q "${w}" && git -C "${w}" remote add "${CI_GIT_REMOTE}" "${o}" || return 1
    git -C "${w}" fetch -q --depth=1 "${CI_GIT_REMOTE}" "refs/heads/${other}" && git -C "${w}" checkout -q FETCH_HEAD || return 1
    CI_MANIFEST="${CI_MANIFEST_SOURCE}" CI_REPO_ROOT="${w}" run bash "${CI_SH}" channel-checkout
    _expect no-channel 2 '[CI-ERROR-PROMOTE-0017]' || return 1
    CI_REPO_ROOT="${w}" run ci_cmd_channel_checkout "$(_val name)"
    _expect no-source-ref 2 '[CI-ERROR-PROMOTE-0018]' || return 1
    CI_REPO_ROOT="${w}" run ci_cmd_channel_checkout "${ch}" "$(_val name)"
    _expect bad-pin 2 '[CI-ERROR-PROMOTE-0020]' || return 1
    : > "${GITHUB_OUTPUT}"
    CI_REPO_ROOT="${w}" run ci_cmd_channel_checkout "${ch}"
    _expect source-ref 0 "channel=${ch} source_ref=${ref} commit=${src}" || return 1
    [ "$(git -C "${w}" rev-parse HEAD)" = "${src}" ] && [ "$(< "${GITHUB_OUTPUT}")" = "commit=${src}" ] \
        || { echo "source-ref: HEAD $(git -C "${w}" rev-parse HEAD) output $(< "${GITHUB_OUTPUT}") want ${src}"; return 1; }
    "${commit[@]}" "${other}" && git -C "${s}" push -q "${o}" "HEAD:${ref}" && next="$(git -C "${s}" rev-parse HEAD)" || return 1
    git -C "${w}" fetch -q --depth=1 "${CI_GIT_REMOTE}" "refs/heads/${other}" && git -C "${w}" checkout -q FETCH_HEAD || return 1
    CI_REPO_ROOT="${w}" run ci_cmd_channel_checkout "${ch}" "${src}"
    _expect pinned 0 "commit=${src}" || return 1
    [ "$(git -C "${w}" rev-parse HEAD)" = "${src}" ] && [ "${next}" != "${src}" ] \
        || { echo "pinned: HEAD $(git -C "${w}" rev-parse HEAD) want ${src}, ref tip ${next}"; return 1; }
}

# What: channel and source_ref branches are never orphans
# Why: release.channels owns master and current_dev
# From: Issue #1683 | PR #1858
@test "orphaned branches: channel ref and source_ref branches are long-lived" {
    local refs srcs row old iso b
    local -a live=()
    local -x GH_TOKEN GITHUB_REPOSITORY
    GH_TOKEN="$(_val name)" GITHUB_REPOSITORY="$(_val name)/$(_val name)" old="$(_val host)"
    iso="$(date -u -d "@$(_val int 1 999999999)" +%Y-%m-%dT%H:%M:%SZ)" || return 1
    refs="$(_ci_channel_field ref)" && srcs="$(_ci_channel_field source_ref)" || { echo "SOT: ${refs} ${srcs}"; return 1; }
    [[ "${srcs}" == *" refs/heads/"?* ]] || { echo "SOT has no branch source_ref: ${srcs}"; return 1; }
    while read -r _ row; do
        if [[ "${row}" == refs/heads/?* ]]; then live+=("${row#refs/heads/}"); fi
    done <<< "${refs}"$'\n'"${srcs}"
    gh() {
        case "$*" in
            *'refs(refPrefix'*) jq -n --arg t "${iso}" --arg a "${old}" '{data: {repository: {refs: {nodes: [$ARGS.positional[]
                | {name: ., target: {committedDate: $t, author: {name: $a}}, associatedPullRequests: {totalCount: 0}}],
                pageInfo: {hasNextPage: false}}}}}' --args "${old}" "${live[@]}" ;;
            *'issues(first'*) jq -n '{data: {repository: {issues: {nodes: [], pageInfo: {hasNextPage: false}}}}}' ;;
            *) echo "gh stub: unexpected call: $*" >&2; return 1 ;;
        esac
    }
    run _ci_check_orphaned_branches
    _expect orphans 1 "[CI-ERROR-CHECK-0139];orphaned=1;branch=\"${old}\"" || return 1
    for b in "${live[@]}"; do
        [[ "${output}" != *"branch=\"${b}\""* ]] || { echo "long-lived ${b} reported: ${output}"; return 1; }
    done
}

# What: release gate staleness per SOT target and layer
# Why: AG-REL-011: a changed target or ci.sh must not ship
# From: Issue #1683 | PR #1858
@test "release gate: SOT scope per target and layer, dead path, unknown and missing record" {
    local root r w st layers targets svc ctx f doc x y extra
    local -a commit
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" r="$(_val path)" w="$(_val path)" extra="$(_val name)"
    st="$(_ci_block_entry_field release "" validation_state)" && layers="$(_ci_block_keys release/validation_layers all)" \
        && targets="$(ci_build_targets)" || { echo "SOT: ${st} ${layers} ${targets}"; return 1; }
    svc="$(ci_services | awk 'NR == 1')" && ctx="$(_ci_required_field "${svc}" context)" || { echo "SOT ${svc}: ${ctx}"; return 1; }
    _checkout_copy "${root}" "${r}" && git -C "${r}" init -q && git -C "${r}" add -A || return 1
    commit=(git -C "${r}" -c user.email="$(_val name)@$(_val host)" -c user.name="$(_val name)" commit -q -a -m)
    "${commit[@]}" X && x="$(git -C "${r}" rev-parse HEAD)" || return 1
    jq -n --arg x "${x}" --arg l "${layers}" --arg t "${targets}" '
        reduce ($l | split("\n")[] | select(length > 0)) as $n ({}; .["last_\($n)_validation"] = {commit: $x})
        | .subsystem_validation = reduce ($t | split("\n")[] | select(length > 0)) as $n ({}; .[$n] = {commit: $x})' \
        > "${r}/${st}" && git -C "${r}" add -A && "${commit[@]}" records && y="$(git -C "${r}" rev-parse HEAD)" || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect fresh 0 "release-validation=fresh target=${y}" || return 1
    git clone -q --depth 1 "file://${r}" "${w}" || return 1
    CI_REPO_ROOT="${w}" run _ci_release_validation_valid
    _expect depth-1 0 "release-validation=fresh target=${y}" || return 1
    doc="$(git -C "${r}" ls-files -- 'docs/*.md' | awk 'NR == 1')" && f="$(git -C "${r}" ls-files -- "${ctx}" | awk 'NR == 1')" \
        && [ -n "${doc}" ] && [ -n "${f}" ] || { echo "fixture files: ${doc} ${f}"; return 1; }
    printf '%s\n' "$(_val name)" >> "${r}/${doc}" && "${commit[@]}" doc || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect docs-only 0 "release-validation=fresh" || return 1
    git -C "${r}" reset -q --hard "${y}" && printf '%s\n' "$(_val name)" >> "${r}/${f}" && "${commit[@]}" target || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect target 1 "[CI-ERROR-RELEASE-0017];${svc}: ${ctx} changed since ${x}" || return 1
    git -C "${r}" reset -q --hard "${y}" && printf 'true\n' >> "${r}/.github/scripts/ci.sh" && "${commit[@]}" ci || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect ci-layer 1 "[CI-ERROR-RELEASE-0017];.github/scripts/" || return 1
    git -C "${r}" reset -q --hard "${y}" && git -C "${r}" rm -q -r -- "${ctx}" && "${commit[@]}" gone || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect dead-scope 2 "[CI-ERROR-RELEASE-0051];${ctx}" || return 1
    git -C "${r}" reset -q --hard "${y}" || return 1
    jq --arg e "${extra}" --arg s "${svc}" '.subsystem_validation[$e] = .subsystem_validation[$s] | del(.subsystem_validation[$s])' \
        "${r}/${st}" > "${r}/${st}.new" && mv "${r}/${st}.new" "${r}/${st}" && "${commit[@]}" keys || return 1
    CI_REPO_ROOT="${r}" run _ci_release_validation_valid
    _expect keys 1 "[CI-ERROR-RELEASE-0017]" || return 1
    [[ "${output}" == *"${extra}: no SOT target of that name"* && "${output}" == *"${svc}: never validated"* ]] \
        || { echo "keys: ${output}"; return 1; }
}

# What: daemon additions follow the SOT, or an env override.
# Why: AG-CI-016: hosts deviate by variable, not by a fork.
# From: Issue #1255 | PR #1349
@test "docker-daemon-config: additions come from the SOT variables or their override" {
    local reserved size files
    run _ci_daemon_additions
    [ "${status}" -eq 0 ] || { echo "rc ${status}: ${output}"; return 1; }
    [ "$(jq -r '.builder.gc.enabled' <<<"${output}")" = true ] || { echo "gc: ${output}"; return 1; }
    [ "$(jq -r '."log-driver"' <<<"${output}")" = json-file ] || { echo "driver: ${output}"; return 1; }
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"${output}")" = "$(_ci_variable CI_BUILDER_GC_RESERVED_SPACE)" ] || return 1
    [ "$(jq -r '."log-opts"."max-size"' <<<"${output}")" = "$(_ci_variable CI_DAEMON_LOG_MAX_SIZE)" ] || return 1
    [ "$(jq -r '."log-opts"."max-file"' <<<"${output}")" = "$(_ci_variable CI_DAEMON_LOG_MAX_FILE)" ] || return 1
    reserved="$(_val name)" size="$(_val name)" files="$(_val int 1 99)"
    CI_BUILDER_GC_RESERVED_SPACE="${reserved}" CI_DAEMON_LOG_MAX_SIZE="${size}" CI_DAEMON_LOG_MAX_FILE="${files}" run _ci_daemon_additions
    [ "${status}" -eq 0 ] || { echo "override rc ${status}: ${output}"; return 1; }
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"${output}")" = "${reserved}" ] || { echo "reserved: ${output}"; return 1; }
    [ "$(jq -r '."log-opts"."max-size"' <<<"${output}")" = "${size}" ] || { echo "size: ${output}"; return 1; }
    [ "$(jq -r '."log-opts"."max-file"' <<<"${output}")" = "${files}" ] || { echo "files: ${output}"; return 1; }
}

# What: merge keeps host keys, a missing file, bad JSON.
# Why: host settings must survive; bad input stops.
# From: Issue #1255 | PR #1349
@test "docker-daemon-config: merge keeps host keys, handles a missing file, stops on bad JSON" {
    local f key val sub
    f="$(_val path)" key="$(_val name)" val="$(_val name)" sub="$(_val name)"
    jq -n --arg k "${key}" --arg v "${val}" --arg s "${sub}" '{($k): $v, builder: {cache: {($s): true}}}' > "${f}"
    run _ci_daemon_merge "${f}"
    [ "${status}" -eq 0 ] || { echo "rc ${status}: ${output}"; return 1; }
    [ "$(jq -r --arg k "${key}" '.[$k]' <<<"${output}")" = "${val}" ] || { echo "host key lost: ${output}"; return 1; }
    [ "$(jq -r --arg s "${sub}" '.builder.cache[$s]' <<<"${output}")" = true ] || { echo "builder replaced: ${output}"; return 1; }
    [ "$(jq -r '.builder.gc.defaultReservedSpace' <<<"${output}")" = "$(_ci_variable CI_BUILDER_GC_RESERVED_SPACE)" ] || { echo "gc missing: ${output}"; return 1; }
    run _ci_daemon_merge "$(_val path)"
    [ "${status}" -eq 0 ] || { echo "missing rc ${status}: ${output}"; return 1; }
    [ "$(jq -S . <<<"${output}")" = "$(_ci_daemon_additions | jq -S .)" ] || { echo "missing file: ${output}"; return 1; }
    printf '{ %s' "$(_val name)" > "${f}"
    run _ci_daemon_merge "${f}"
    _expect bad-json 1 "[CI-ERROR-DAEMON-0001];${f};parse error" || return 1
}

# What: restart waits the SOT time, then shows docker's raw text.
# Why: V-N3: a dead dockerd must not end in a bare message.
# From: Issue #1255 | PR #1912
@test "docker-daemon-config: a dockerd that never answers fails with its raw text" {
    local msg wait
    msg="$(_val name)" wait="$(_val int 2 4)"
    systemctl() { return 0; }
    sleep() { return 0; }
    docker() { printf '%s\n' "${msg}" >&2; return 1; }
    CONFIRM_DOCKERD_RESTART=yes CI_DAEMON_RESTART_WAIT="${wait}" run _ci_daemon_restart "$(_val path)"
    _expect never-answers 1 "[CI-ERROR-DAEMON-0005];wait=${wait};${msg}" || return 1
}

# What: apply backs up and installs; restart needs consent.
# Why: dockerd restarts stop every running CI job.
# From: Issue #1255 | PR #1349
@test "docker-daemon-config: apply backs up and installs, restart refuses without consent" {
    local f key=max-concurrent-downloads val
    f="$(_val path)" val="$(_val int 1 99)"
    jq -n --arg k "${key}" --argjson v "${val}" '{($k): $v}' > "${f}"
    run ci_cmd_docker_daemon_config apply "${f}"
    [ "${status}" -eq 0 ] || { echo "apply rc ${status}: ${output}"; return 1; }
    [ "$(jq -r --arg k "${key}" '.[$k]' "${f}")" = "${val}" ] || { echo "host key lost"; return 1; }
    [ "$(jq -r '."log-driver"' "${f}")" = json-file ] || { echo "no additions in ${f}"; return 1; }
    [ "$(jq -r --arg k "${key}" '.[$k]' "${f}".bak.*)" = "${val}" ] || { echo "no backup of the old file"; return 1; }
    run ci_cmd_docker_daemon_config stage "${f}"
    [ "${status}" -eq 0 ] && [ -s "${f}.staged" ] || { echo "stage rc ${status}: ${output}"; return 1; }
    CONFIRM_DOCKERD_RESTART="" run ci_cmd_docker_daemon_config restart "${f}"
    _expect restart-guard 1 "[CI-ERROR-DAEMON-0004]" || return 1
    run ci_cmd_docker_daemon_config "$(_val name)" "${f}"
    _expect unknown-mode 2 "[CI-ERROR-DAEMON-0007]" || return 1
}

# What: runner-host fixtures: SOT values on a temp tree.
# Why: the modes act on /opt and systemd; tests use temps.
# From: Issue #1622 | PR #1624
_rh_fixture() {
    RH_ROOT="$(_val path)" RH_UNITS="$(_val path)" RH_HOOKS="$(_val path)" RH_MIN="$(_val int 1 9)"
    RH_HTOK="$(_val int 100 499)" RH_ITOK="${RH_HTOK}"
    mkdir -p "${RH_ROOT}" "${RH_UNITS}" "${RH_HOOKS}"
    _ci_rh_root() { "$@"; }
    _ci_rh_host_token() { printf '%s' "${RH_HTOK}"; }
    _ci_rh_ip_token() { printf '%s' "${RH_ITOK}"; }
    _ci_rh_val() {
        case "$1" in
            opt_root) printf '%s' "${RH_ROOT}" ;;
            unit_dir) printf '%s' "${RH_UNITS}" ;;
            hooks_dir) printf '%s' "${RH_HOOKS}" ;;
            stray_archive_min_bytes) printf '%s' "${RH_MIN}" ;;
            *) _ci_block_entry_field runner_host "" "$1" ;;
        esac
    }
}

# What: a runner dir whose .runner names an agent.
# Why: identity checks read agentName only.
# From: Issue #1622 | PR #1624
_rh_runner_dir() {
    mkdir -p "$1"
    jq -n --arg a "$2" '{agentName: $a}' > "$1/.runner"
}

# What: fleet numbers and foreign key lines follow the SOT.
# Why: a loose match could take the instance suffix.
# From: Issue #1622 | PR #1624
@test "runner-host: fleet numbers come from the SOT patterns, key lines compare to the host" {
    local n m
    _rh_fixture
    n="$(_val int 500 999)"
    [ "$(_ci_rh_fleet_number "gh-lancache-heavy-$(_val name)-${n}")" = "${n}" ] || return 1
    [ "$(_ci_rh_fleet_number "a-lancache-runner-${n}")" = "${n}" ] || return 1
    [ -z "$(_ci_rh_fleet_number "$(_val name)")" ] || return 1
    RH_HTOK="${n}" run _ci_rh_foreign_key_line "ssh-ed25519 AAAA a-lancache-runner-${n}"
    [ "${status}" -eq 1 ] || { echo "own key line rc ${status}"; return 1; }
    m=$(( n + 1 ))
    RH_HTOK="${m}" run _ci_rh_foreign_key_line "ssh-ed25519 AAAA a-lancache-runner-${n}"
    [ "${status}" -eq 0 ] || { echo "foreign key line rc ${status}"; return 1; }
}

# What: runner dirs sort into own, foreign, ambiguous.
# Why: rc 2 must never be reported as own or removed.
# From: Issue #1622 | PR #1624
@test "runner-host: a runner dir is own, foreign, ambiguous or unregistered" {
    local own foreign other
    _rh_fixture
    own="a-lancache-runner-${RH_HTOK}" foreign="a-lancache-runner-$(( RH_HTOK + 1 ))"
    mkdir -p "${RH_ROOT}/none" "${RH_ROOT}/creds"
    : > "${RH_ROOT}/creds/.credentials"
    _rh_runner_dir "${RH_ROOT}/own" "${own}"
    _rh_runner_dir "${RH_ROOT}/foreign" "${foreign}"
    _rh_runner_dir "${RH_ROOT}/unnamed" "$(_val name)"
    run _ci_rh_foreign_dir "${RH_ROOT}/none"
    [ "${status}" -eq 1 ] || { echo "unregistered rc ${status}"; return 1; }
    run _ci_rh_foreign_dir "${RH_ROOT}/creds"
    [ "${status}" -eq 0 ] || { echo "credentials-only rc ${status}"; return 1; }
    run _ci_rh_foreign_dir "${RH_ROOT}/own"
    [ "${status}" -eq 1 ] || { echo "own rc ${status}: ${output}"; return 1; }
    run _ci_rh_foreign_dir "${RH_ROOT}/foreign"
    [ "${status}" -eq 0 ] || { echo "foreign rc ${status}: ${output}"; return 1; }
    run _ci_rh_foreign_dir "${RH_ROOT}/unnamed"
    [ "${status}" -eq 0 ] || { echo "unknown name rc ${status}: ${output}"; return 1; }
    RH_ITOK="$(( RH_HTOK + 7 ))"
    run _ci_rh_foreign_dir "${RH_ROOT}/own"
    [ "${status}" -eq 2 ] || { echo "ambiguous rc ${status}: ${output}"; return 1; }
    other="a-lancache-runner-$(( RH_HTOK + 9 ))"
    _rh_runner_dir "${RH_ROOT}/third" "${other}"
    run _ci_rh_foreign_dir "${RH_ROOT}/third"
    [ "${status}" -eq 0 ] || { echo "third host rc ${status}: ${output}"; return 1; }
}

# What: clean removes foreign dirs only, with consent.
# Why: archives and own runners must survive a clean.
# From: Issue #1622 | PR #1624
@test "runner-host: clean needs consent and removes only foreign dirs, archives need clean-archive" {
    local arc other
    _rh_fixture
    _rh_runner_dir "${RH_ROOT}/actions-runner-own" "a-lancache-runner-${RH_HTOK}"
    _rh_runner_dir "${RH_ROOT}/actions-runner-foreign" "a-lancache-runner-$(( RH_HTOK + 1 ))"
    arc="${RH_ROOT}/$(_val name).tar.gz" other="${RH_ROOT}/$(_val name).tar.gz"
    truncate -s "$(( RH_MIN + 10 ))" "${arc}"
    : > "${other}"
    CONFIRM_CLEAN="" run _ci_rh_clean
    _expect no-consent 2 "[CI-ERROR-RUNNER-0026];CONFIRM_CLEAN" || return 1
    [ -d "${RH_ROOT}/actions-runner-foreign" ] || { echo "removed without consent"; return 1; }
    CONFIRM_CLEAN=yes run _ci_rh_clean
    _expect clean 0 "Removing foreign clone artifact: ${RH_ROOT}/actions-runner-foreign;NOT removed" || return 1
    [ ! -d "${RH_ROOT}/actions-runner-foreign" ] && [ -d "${RH_ROOT}/actions-runner-own" ] && [ -f "${arc}" ] || { echo "wrong set removed"; return 1; }
    run _ci_rh_clean_archive "${other}" "${arc}"
    _expect clean-archive 0 "SKIPPING ${other};Removing confirmed stray archive: ${arc}" || return 1
    [ ! -e "${arc}" ] && [ -e "${other}" ] || { echo "archive set wrong"; return 1; }
    run _ci_rh_clean_archive
    _expect no-paths 2 "[CI-ERROR-RUNNER-0028]" || return 1
}

# What: the hook wiring is rewritten once, then left alone.
# Why: config.sh truncates .env; a rerun must not duplicate.
# From: Issue #1622 | PR #1624
@test "runner-host: runner-hook-env rewrites stale wiring and then stays idempotent" {
    local inst
    _rh_fixture
    inst="${RH_ROOT}/$(_val name)"
    mkdir -p "${inst}"
    run _ci_rh_runner_hook_env "${inst}"
    _expect no-env 2 "[CI-ERROR-RUNNER-0093]" || return 1
    printf 'LANG=C\nACTIONS_RUNNER_HOOK_JOB_STARTED=%s\nOTHER=%s\n' "$(_val path)" "$(_val name)" > "${inst}/.env"
    run _ci_rh_runner_hook_env "${inst}"
    [ "${status}" -eq 0 ] || { echo "rewrite rc ${status}: ${output}"; return 1; }
    [ "$(grep -c '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "${inst}/.env")" -eq 1 ] || { echo "started lines duplicated"; return 1; }
    grep -qx "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RH_HOOKS}/post-job-cleanup.sh" "${inst}/.env" || { echo "completed line missing"; return 1; }
    grep -q '^OTHER=' "${inst}/.env" || { echo "foreign .env line lost"; return 1; }
    run _ci_rh_runner_hook_env "${inst}"
    _expect again 0 "already has the correct hook wiring" || return 1
}

# What: the restart policy lands once per runner unit.
# Why: the installer unit never restarts a crashed runner.
# From: Issue #1738
@test "runner-host: runner-restart-policy writes a drop-in per unit and skips a set one" {
    local unit
    _rh_fixture
    systemctl() { printf '%s\n' "$*" >> "${RH_UNITS}/systemctl.log"; [ "$1" != show ] || printf 'x'; }
    run _ci_rh_restart_policy
    _expect no-units 0 "No actions.runner" || return 1
    unit="actions.runner.$(_val name).service"
    : > "${RH_UNITS}/${unit}"
    run _ci_rh_restart_policy
    [ "${status}" -eq 0 ] || { echo "rc ${status}: ${output}"; return 1; }
    grep -qx 'Restart=on-failure' "${RH_UNITS}/${unit}.d/override.conf" || { echo "no Restart line"; return 1; }
    grep -qx "RestartSec=$(_ci_rh_val restart_sec)" "${RH_UNITS}/${unit}.d/override.conf" || { echo "no RestartSec line"; return 1; }
    grep -qx 'daemon-reload' "${RH_UNITS}/systemctl.log" || { echo "no daemon-reload"; return 1; }
    : > "${RH_UNITS}/systemctl.log"
    run _ci_rh_restart_policy
    _expect again 0 "drop-in already set" || return 1
    ! grep -qx 'daemon-reload' "${RH_UNITS}/systemctl.log" || { echo "reloaded without a change"; return 1; }
}

# What: hook texts name the validate prefix and grace age.
# Why: the post hook reaps this repo's validation networks.
# From: Issue #1095 | PR #1426
@test "runner-host: job hooks parse and carry the validate prefix and grace seconds from the SOT" {
    local pre post
    _rh_fixture
    pre="$(_ci_rh_hook_pre_text)" post="$(_ci_rh_hook_post_text)"
    bash -n <<< "${pre}" || return 1
    bash -n <<< "${post}" || return 1
    [[ "${post}" == *"name=$(_ci_validate_project "") "* ]] || { echo "no validate prefix in the post hook"; return 1; }
    [[ "${post}" == *"MIN_AGE=$(_ci_rh_val hook_network_min_age)"$'\n'* ]] || { echo "no grace age in the post hook"; return 1; }
    [[ "${post}" != *"@"* ]] || { echo "unfilled placeholder in the post hook"; return 1; }
    [[ "${pre}" == *'GITHUB_WORKSPACE'* ]] || return 1
}

# What: the post hook names a failed inspect and goes on.
# Why: V-N2: no swallowed error; the raw text is in the log.
# From: Issue #1622 | PR #1912
@test "runner-host: the post hook keeps the raw text of a failed network inspect" {
    local bin net msg
    _rh_fixture
    bin="$(_val path)" net="$(_val name)" msg="$(_val name)"
    mkdir -p "${bin}"
    printf '#!/bin/bash\ncase "$2" in\n  ls) echo "%s" ;;\n  inspect) echo "%s" >&2; exit 1 ;;\nesac\n' "${net}" "${msg}" > "${bin}/docker"
    chmod +x "${bin}/docker"
    _ci_rh_hook_post_text > "${bin}/post.sh"
    PATH="${bin}:${PATH}" run bash "${bin}/post.sh"
    _expect inspect-fails 0 "leaving ${net} alone, not inspected: ${msg}" || return 1
}

# What: cleanup units follow the SOT schedule and path.
# Why: units are generated, never copied by hand.
# From: Issue #1255 | PR #1349
@test "runner-host: service and timer text come from the SOT and this script's path" {
    local svc tim
    svc="$(_ci_rh_service_text)" tim="$(_ci_rh_timer_text)"
    [[ "${svc}" == *"ExecStart=/usr/bin/env bash ${CI_SCRIPT_DIR}/ci.sh runner-host cleanup"* ]] || { echo "${svc}"; return 1; }
    [[ "${svc}" == *"Environment=GITHUB_REPOSITORY=${GITHUB_REPOSITORY}"* ]] || { echo "${svc}"; return 1; }
    [[ "${tim}" == *"OnCalendar=$(_ci_rh_val timer_calendar)"$'\n'* ]] || { echo "${tim}"; return 1; }
    [[ "${tim}" == *"RandomizedDelaySec=$(_ci_rh_val timer_delay)"$'\n'* ]] || { echo "${tim}"; return 1; }
}

# What: reaping keys on .Created and the match field.
# Why: .Created survives a daemon restart; StartedAt resets.
# From: Issue #1095 | PR #1426
@test "runner-host: reaping removes old matching containers and old empty networks only" {
    local old new pat hours
    _rh_fixture
    RH_LOG="$(_val path)"
    old="$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%S.123456789Z)" new="$(date -u -d '-1 minutes' +%Y-%m-%dT%H:%M:%S.123456789Z)"
    pat="$(_val name)" hours="$(_val int 2 5)"
    docker() {
        case "$1 ${2:-}" in
            "ps -q") printf 'c1\nc2\nc3\n' ;;
            "inspect --format") printf 'c1|img|/n1|%s-a|%s\nc2|img|/n2|%s-b|%s\nc3|img|/n3|other|%s\n' "${pat}" "${old}" "${pat}" "${new}" "${old}" ;;
            "network ls") printf '%s-1\n%s-2\n%s-3\n' "${pat}" "${pat}" "${pat}" ;;
            "network inspect")
                case "$3" in
                    "${pat}-1") printf '0|%s\n' "${old}" ;;
                    "${pat}-2") printf '0|%s\n' "${new}" ;;
                    *) printf '2|%s\n' "${old}" ;;
                esac ;;
            "rm -f") printf 'rm %s\n' "$3" >> "${RH_LOG}" ;;
            "network rm") printf 'netrm %s\n' "$3" >> "${RH_LOG}" ;;
            *) echo "docker stub: $*" >&2; return 1 ;;
        esac
    }
    run _ci_rh_reap_containers validation project "${pat}" "${hours}"
    [ "${status}" -eq 0 ] || { echo "containers rc ${status}: ${output}"; return 1; }
    run _ci_rh_reap_networks "${pat}" "${hours}"
    [ "${status}" -eq 0 ] || { echo "networks rc ${status}: ${output}"; return 1; }
    [ "$(cat "${RH_LOG}")" = "$(printf 'rm c1\nnetrm %s-1' "${pat}")" ] || { echo "reaped: $(cat "${RH_LOG}")"; return 1; }
}

# What: the cleanup log is trimmed to its cap, appended.
# Why: a timer run has no terminal; the log stays bounded.
# From: Issue #1255 | PR #1349
@test "runner-host: cleanup trims an oversized log and appends the run" {
    local rhlog
    _rh_fixture
    rhlog="$(_val path)"
    _ci_rh_val() { case "$1" in cleanup_log) printf '%s' "${rhlog}" ;; cleanup_log_max_bytes) printf '10' ;; *) return 1 ;; esac; }
    _ci_rh_cleanup_run() { printf 'ran\n'; }
    printf '0123456789abcdefghij' > "${rhlog}"
    run _ci_rh_cleanup
    [ "${status}" -eq 0 ] || { echo "rc ${status}: ${output}"; return 1; }
    [ "$(cat "${rhlog}")" = "$(printf 'abcdefghij\nran')" ] || { echo "log: $(cat "${rhlog}")"; return 1; }
}

# What: purge-pve stops before it removes foreign packages.
# Why: autoremove may hit PVE dependencies only.
# From: Issue #1622 | PR #1624
@test "runner-host: the purge guard refuses an autoremove outside the PVE set or on a boot package" {
    local keep
    _rh_fixture
    keep="$(_ci_rh_pve_keep_ere)"
    [[ "${keep}" == *proxmox-kernel* && "${keep}" == *pve-firmware* ]] || { echo "keep: ${keep}"; return 1; }
    env() { shift; "$@"; }
    apt-get() { case "$*" in *--simulate*) printf 'Remv %s [1]\n' "${RH_REMV}" ;; *) printf 'apt-get %s\n' "$*" ;; esac; }
    RH_REMV="libpve-$(_val name)" run _ci_rh_pve_purge_run "${keep}" pve-manager
    _expect pve-only 0 "apt-get autoremove -y" || return 1
    RH_REMV="$(_val name)" run _ci_rh_pve_purge_run "${keep}" pve-manager
    _expect other-package 2 "[CI-ERROR-RUNNER-0061]" || return 1
    RH_REMV="proxmox-kernel-$(_val name)" run _ci_rh_pve_purge_run "${keep}" pve-manager
    _expect boot-package 2 "[CI-ERROR-RUNNER-0061]" || return 1
}

# What: guards stop before any host change.
# Why: destructive modes need consent, input, a safe path.
# From: Issue #1622 | PR #1624
@test "runner-host: unknown mode, missing consent and unsafe runner-fetch targets stop first" {
    local inst
    _rh_fixture
    run ci_cmd_runner_host "$(_val name)"
    _expect unknown-mode 2 "[CI-ERROR-RUNNER-0110]" || return 1
    CONFIRM_PURGE_PVE="" run ci_cmd_runner_host purge-pve
    _expect purge-consent 2 "[CI-ERROR-RUNNER-0026];CONFIRM_PURGE_PVE" || return 1
    CONFIRM_FULL_RESET="" run ci_cmd_runner_host full-reset-clean
    _expect reset-consent 2 "[CI-ERROR-RUNNER-0026];CONFIRM_FULL_RESET" || return 1
    run ci_cmd_runner_host set-hostname
    _expect no-hostname 2 "[CI-ERROR-RUNNER-0050]" || return 1
    run ci_cmd_runner_host runner-fetch
    _expect no-dir 2 "[CI-ERROR-RUNNER-0084]" || return 1
    run ci_cmd_runner_host runner-fetch "$(_val path)"
    _expect outside-root 2 "[CI-ERROR-RUNNER-0085]" || return 1
    inst="${RH_ROOT}/$(_val name)"
    mkdir -p "${inst}" && : > "${inst}/$(_val name)"
    run ci_cmd_runner_host runner-fetch "${inst}"
    _expect not-empty 2 "[CI-ERROR-RUNNER-0086]" || return 1
    run ci_cmd_runner_host sccache-fetch "$(_val path)"
    _expect not-staged 2 "[CI-ERROR-RUNNER-0100]" || return 1
}

# What: the Trivy leftover reap uses an exact minute age.
# Why: -mtime floors to days and would keep a 1.9 day dir.
# From: Issue #1255 | PR #1334
@test "runner-host: the Trivy leftover reap removes only dirs older than the SOT age" {
    local trroot old new trdays
    _rh_fixture
    trroot="$(_val path)" trdays="$(_val int 1 3)"
    _ci_rh_val() { case "$1" in trivy_leftover_root) printf '%s' "${trroot}" ;; trivy_leftover_days) printf '%s' "${trdays}" ;; *) return 1 ;; esac; }
    run _ci_rh_reap_trivy
    _expect no-root 0 "skipping" || return 1
    old="${trroot}/$(_val name)" new="${trroot}/$(_val name)"
    mkdir -p "${old}" "${new}"
    touch -d "$(( trdays * 24 + 1 )) hours ago" "${old}"
    touch -d "$(( trdays * 24 - 1 )) hours ago" "${new}"
    run _ci_rh_reap_trivy
    _expect reap 0 "reaping stale Trivy cache dir ${old}" || return 1
    [ ! -e "${old}" ] && [ -d "${new}" ] || { echo "wrong dirs removed"; return 1; }
}
