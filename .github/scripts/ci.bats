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
    local rows row r n answers
    local -A sot=()
    [ ! -d /run/systemd/system ] || { echo "systemd host: a real install would write /etc units"; return 1; }
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_sh "${root}" || return 1
    repo="${t}/repo" env="${t}/repo/deploy/prod/.env.local" tpl="$(_template_env)"
    _checkout_copy "${root}" "${repo}" || { echo "checkout copy failed"; return 1; }
    cfg="$(docker compose --env-file "${tpl}" -f "${repo}/deploy/prod/docker-compose.yml" config --format json)" \
        && port="$(jq -r '.services.ui.ports[0].published' <<< "${cfg}")" && [[ "${port}" =~ ^[0-9]+$ ]] \
        || { echo "prod compose config: ${cfg}"; return 1; }
    # What: SOT defaults via yq; @KEY@ resolved here
    # Why: no expectation from the resolver in setup.sh
    # From: Issue #1683 | PR #1912
    rows="$(yq -r '.runtime.defaults[]' "${CI_MANIFEST_SOURCE}")" && [ -n "${rows}" ] \
        || { echo "no SOT runtime.defaults rows: ${rows}"; return 1; }
    while IFS= read -r row; do sot["${row%%=*}"]="${row#*=}"; done <<< "${rows}"
    keys="${!sot[*]}"
    # What: setup.sh holds no SOT default or ui port
    # Why: one owner each; a copy passes the checks below
    # From: Issue #1683 | PR #1912
    if grep -qw -- "${port}" "${repo}/setup.sh"; then echo "ui port ${port} is a literal in setup.sh"; return 1; fi
    for k in ${keys}; do
        v="${sot[${k}]}" n=0
        while [[ "${v}" =~ @([A-Za-z0-9_]+)@ ]] && [ "$((n += 1))" -le 16 ]; do
            r="${BASH_REMATCH[1]}"
            [ -n "${sot[${r}]+x}" ] || { echo "${k} names @${r}@, no SOT row"; return 1; }
            v="${v//@${r}@/${sot[${r}]}}"
        done
        [[ ! "${v}" =~ @[A-Za-z0-9_]+@ ]] || { echo "${k} stays unresolved: ${v}"; return 1; }
        [ -n "${v}" ] || continue
        # What: any case; a lowercase copy is a copy too
        # Why: allow_insecure_ui=false hid the SOT default
        # From: Issue #1683 | PR #1912
        if grep -qiF -e "${k}=${v}" -e "${k}:-${v}" "${repo}/setup.sh"; then
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
    # What: the wizard answers land; no other SOT key does
    # Why: answers stay; SOT defaults are not copied
    # From: Issue #1683 | PR #1912
    answers=" CACHE_MAX_SIZE CACHE_MEM_MB DHCP_SUBNET DHCP_GATEWAY DHCP_RANGE_START DHCP_RANGE_END ALLOW_INSECURE_UI NTP_ENABLED HTTPS_ENABLED AUTO_UPDATE_ENABLED DHCP_MODE KEA_DATA_DIR LANCACHE_STATE_DIR CACHE_DIR "
    for k in ${keys}; do
        case "${answers}" in
            *" ${k} "*) env_key_exists "${k}" "${env}" || { echo "answer ${k} missing in .env.local: $(cat "${env}")"; return 1; } ;;
            *) [ -z "$(get_env_var "${k}" "${env}")" ] || { echo "${k} was copied into .env.local: $(cat "${env}")"; return 1; } ;;
        esac
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

# What: a PATH holding only bash, env, cat and awk
# Why: a real package manager on the host is never reached
# From: Issue #1683 | PR #1858
_pm_path() {
    local dir tool
    dir="$(_val path)"
    mkdir -p "${dir}" || return 1
    for tool in bash env cat awk; do
        ln -s "$(type -P "${tool}")" "${dir}/${tool}" || return 1
    done
    printf '%s\n' "${dir}"
}

# What: runs a setup.sh snippet; answers come on fd 9
# Why: the real ask path reads list-prompts answers there
# From: Issue #1683 | PR #1858
_pm_run() {
    _setup_sh_run "WIZARD_INTROSPECT_MODE=1; WIZARD_INTROSPECT_ANSWERS_FD=9; exec 9<\"\${ANS:?}\"; PATH='$1'; $2"
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
    _prod_install "${S}" && mkdir -p "${v}" \
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
    cp -a "${S}" "${t}/S.first" && cp -a "${v}" "${t}/v.first" && printf '%s\n' "${t}" > "${v}/${vol}" || return 1
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

# What: Kea preflight probes; asks when a server answers
# Why: a second DHCP server needs the operator's yes
# From: Issue #1683 | PR #1912
@test "setup kea preflight asks before a second dhcp server" {
    local root p env mode id want found none
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
    _kea_try kea n "${id}" 1 || return 1
    [ "${status}" -eq 1 ] && [[ "${output}" == *"could not be executed inside the dhcp image."*"Cancelled DHCP activation."* ]] \
        || { echo "probe failed, no: rc ${status} ${output}"; return 1; }
}

