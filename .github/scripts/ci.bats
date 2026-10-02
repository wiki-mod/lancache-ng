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
    CI_SH="${BATS_TEST_DIRNAME}/ci.sh"
    CI_MANIFEST_SOURCE="${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
    # What: default apk resolver, rust ids docker-free.
    # Why: rust identity now keys the build-tools signature.
    # From: Issue #1683
    CI_APK_RESOLVE_CMD="$(_stub apkres 'printf "pkg-1.0\n"')"; export CI_APK_RESOLVE_CMD
    # What: GHCR login stub (no-op, docker absent).
    # Why: ci.sh policy uses docker login; tests stub it.
    # From: Issue #1683
    CI_GHCR_LOGIN_CMD="$(_stub ghcrlogin 'exit 0')"; export CI_GHCR_LOGIN_CMD
    # What: neutral server URL every Actions run provides.
    # Why: label provenance needs it; no real host in tests.
    # From: Issue #1683 | PR #1858
    export GITHUB_SERVER_URL=https://git.example.test
    # What: SOT copy with neutral registry and platforms.
    # Why: tests must not mirror the real host or arch set.
    # From: Issue #1683 | PR #1858
    CI_MANIFEST="${BATS_TEST_TMPDIR}/sot.yml"
    sed -e 's|^  registry: .*|  registry: registry.example.test|' \
        -e 's|linux/amd64|os/p1|g; s|linux/arm64|os/p2|g' \
        -e 's|^  amd64:$|  p1:|; s|^  arm64:$|  p2:|' \
        -e 's|x86_64|arch-a|g; s|aarch64|arch-b|g' \
        "${CI_MANIFEST_SOURCE}" > "${CI_MANIFEST}"
    export CI_MANIFEST
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

@test "result-gate accepts an all-success and a NOOP-skipped pipeline" {
    # What: required check greens on success and on skips.
    # Why: non-plan/checks phases skip on NOOP/PR (§62).
    # From: Issue #1683 | PR #1858
    CI_PHASE_RESULTS="plan:success build:success checks:success" run ci_cmd_result_gate
    [ "${status}" -eq 0 ]
    [[ "${output}" == *SUCCESS* ]]
    CI_PHASE_RESULTS="plan:success build:skipped validate:skipped checks:success" run ci_cmd_result_gate
    [ "${status}" -eq 0 ]
}

@test "result-gate fails closed on plan, checks, phase failure, or empty" {
    # What: plan/checks ok; others ok or skip.
    # Why: real phase failure must block promotion.
    # From: Issue #1683 | PR #1858
    CI_PHASE_RESULTS="plan:failure checks:success" run ci_cmd_result_gate
    [ "${status}" -eq 1 ]
    [[ "${output}" == *CI-ERROR-CORE-0100* ]]
    CI_PHASE_RESULTS="plan:success checks:failure" run ci_cmd_result_gate
    [ "${status}" -eq 1 ]
    CI_PHASE_RESULTS="plan:success build:failure checks:success" run ci_cmd_result_gate
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'[CI-ERROR-CORE-0116] phase="build" result="failure"'* ]]
    CI_PHASE_RESULTS="platform:skipped plan:success checks:success" run ci_cmd_result_gate
    [ "${status}" -eq 1 ]
    run ci_cmd_result_gate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *CI-ERROR-CORE-0101* ]]
}

@test "services are the SOT services block; targets add the toolchain" {
    # What: services = services keys; targets = + toolchain.
    # Why: one list owner; the toolchain is never a service.
    # From: Issue #1683 | PR #1858
    local m
    m="${BATS_TEST_TMPDIR}/inv.yml"
    printf 'services:\n  svc-a:\n    context: a\n  svc-b:\n    context: b\nbuild_toolchain:\n  tc-x:\n    context: t\n' > "${m}"
    CI_MANIFEST="${m}" run ci_services
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'svc-a\nsvc-b')" ]
    CI_MANIFEST="${m}" run ci_build_targets
    [ "${output}" = "$(printf 'svc-a\nsvc-b\ntc-x')" ]
}

@test "every rust service in the SOT smoke-runs ldd on its binary" {
    # What: every rust service smoke-runs ldd on a binary.
    # Why: a missing .so must fail verify, not validate.
    # From: Issue #1683 | PR #1858
    local s missing="" rust=0
    for s in $(CI_MANIFEST="${CI_MANIFEST_SOURCE}" ci_services); do
        [ "$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" ci_service_field "${s}" build_type)" = rust ] || continue
        rust=$((rust + 1))
        grep -Eq '^ldd /usr/local/bin/[^ ]+$' \
            <<<"$(CI_MANIFEST="${CI_MANIFEST_SOURCE}" _ci_block_entry_list services "${s}" smoke)" \
            || missing="${missing} ${s}"
    done
    echo "rust=${rust} missing=${missing:-none}"
    [ "${rust}" -gt 0 ]
    [ -z "${missing}" ]
}

@test "unknown subcommand fails closed with a stable id" {
    # What: An unknown command must never succeed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
}

@test "exit-evidence is clean on ci.sh and flags each rule" {
    # What: real ci.sh clean; one fixture per rule fails.
    # Why: the guard owns the class; prove both directions.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check exit-evidence "${CI_SH}"
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"exit-evidence=clean files=1"* ]]
    local fx="${BATS_TEST_TMPDIR}/fx.sh" name body
    while IFS='|' read -r name body; do
        printf 'f() {\n    %s\n}\n' "${body}" > "${fx}"
        run bash "${CI_SH}" check exit-evidence "${fx}"
        [ "${status}" -eq 1 ] && [[ "${output}" == *"[CI-ERROR-CHECK-0124]"* ]] \
            && [[ "${output}" == *": ${name}"* ]] \
            || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
raw-mktemp|t="$(mktemp -d)" || return 2
for-in-substitution|for s in $(ci_services); do :; done
reader-in-test|[ "$(ci_service_field svc build_type)" = rust ] && :
uncoded-external-return|v="$(jq -r .a f.json)" || return 2
duplicate-code|ci_log "[CI-ERROR-X-0001]" "a"; ci_log "[CI-INFO-X-0001]" "b"
CASES
    printf 'f() {\n    t="$(_ci_mktemp -d)" || return 2\n    v="$(jq -r .a f.json 2>&1)" || { ci_error "[CI-ERROR-X-0001]" "c" "${v}"; return 2; }\n}\n' > "${fx}"
    run bash "${CI_SH}" check exit-evidence "${fx}"
    [ "${status}" -eq 0 ] || { echo "valid fixture: ${output}"; return 1; }
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

# What: a tool stub that fails one matching argument.
# Why: proves a tool error is never a clean result.
# From: Issue #1683 | PR #1858
_fail_stub() {
    local bin="$1" tool="$2"
    _tool_stub "${bin}" "${tool}" <<'STUB'
tool="$(basename "$0")"
for arg in "$@"; do
    if [ -n "${FAIL_MATCH:-}" ] && [[ "${arg}" == *"${FAIL_MATCH}" ]]; then
        echo "${tool}: read error" >&2
        exit 2
    fi
done
PATH="${PATH#*:}"
exec "${tool}" "$@"
STUB
}

# What: sccache probe stub: 0 up, 1 down, redis-only.
# Why: the probe must never start a real sccache server.
# From: Issue #1683 | PR #1858
_stub_sccache() {
    local bin="$1" mode="$2"
    case "${mode}" in
        0) _tool_stub "${bin}" sccache <<<'exit 0' ;;
        1) _tool_stub "${bin}" sccache <<<'echo raw-server-down >&2; exit 2' ;;
        redis-only)
            _tool_stub "${bin}" sccache <<<'[ -z "${SCCACHE_REDIS:-}" ] || { echo raw-redis-down >&2; exit 2; }'
            ;;
    esac
}

@test "a grep read error fails every check that reads the file" {
    # What: grep rc 2 on a file a check reads fails it.
    # Why: a read error must never look like a clean file.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/gbin"
    local name check arg fail
    _fail_stub "${bin}" grep
    printf 'echo hi\n' > "${BATS_TEST_TMPDIR}/probe.sh"
    printf 'on: push\n' > "${BATS_TEST_TMPDIR}/probe.yml"
    while IFS='|' read -r name check arg fail; do
        local -a files=()
        if [ -n "${arg}" ]; then
            files=("${BATS_TEST_TMPDIR}/${arg}")
        fi
        run env PATH="${bin}:${PATH}" FAIL_MATCH="${fail}" \
            bash "${CI_SH}" check "${check}" "${files[@]}"
        if [ "${status}" -eq 0 ]; then
            echo "${name}: passed: ${output}"
            return 1
        fi
        if [[ "${output}" != *"CI-ERROR-CORE-0106"*"read error"* ]]; then
            echo "${name}: ${output}"
            return 1
        fi
    done <<'CASES'
crlf|line-endings|probe.sh|/probe.sh
lang|language-policy|probe.sh|/probe.sh
refs|mutable-refs|probe.yml|/probe.yml
chrono|review-chronology|probe.sh|/probe.sh
pipefail|pipefail-early-exit|probe.sh|/probe.sh
prebuilt|prebuilt-prod||/README.md
nats|nats-atomic-write||/services/dns/entrypoint.sh
socket|docker-socket-proxy||/scripts/untracked/docker-socket-proxy.sh
naming|naming-consistency||/scripts/untracked/docker-socket-proxy.sh
naming-dc|naming-consistency||/docker_client.rs
naming-wd|naming-consistency||/watchdog/src/config.rs
naming-ui|naming-consistency||/ui/src/config.rs
dhcp|dhcp-proxy-env||/dnsmasq.conf.template
kea|setup-keys-kea||/setup.sh
rustdf|dockerfile-build-tools||/services/ui/Dockerfile
prompt|setup-prompt-drift||/setup-cli-simulation.sh
prompt-setup|setup-prompt-drift||/setup.sh
prompt-anchor|setup-prompt-drift||-m1
CASES
}

@test "gc refuses when the roots file read fails" {
    # What: a roots read error refuses; no DELETE verdict.
    # Why: "not referenced" from a failed read deletes data.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/gcbin"
    _fail_stub "${bin}" grep
    PATH="${bin}:${PATH}" FAIL_MATCH="-xF" \
    CI_GC_ROOTS_CMD="$(_stub roots 'printf "sha256:aaa\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'printf "sha256:aaa\t7\t2020-01-01T00:00:00Z\n"')" \
        run bash "${CI_SH}" gc
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*"read error"* ]]
    [[ "${output}" != *"action=DELETE"* ]]
}

@test "_ci_repo lowercases a mixed-case GITHUB_REPOSITORY" {
    # What: a mixed-case owner/repo comes out lowercased.
    # Why: GHCR image refs must be lowercase.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY='Owner/Fixture-Repo' run _ci_repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "owner/fixture-repo" ]
}

@test "image-ref builds the one registry service@digest form" {
    # What: Builds <registry>/<repo>/<service>@<digest> ref.
    # Why: scan, sbom, assemble, verify must share the ref.
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo run _ci_image_ref build-tools sha256:beef
    [ "${status}" -eq 0 ]
    [ "${output}" = "registry.example.test/owner/fixture-repo/build-tools@sha256:beef" ]
}

@test "image-ref fails closed and prints no ref without a repo owner" {
    # What: A missing repo owner yields nonzero and no ref.
    # Why: AG-VAL-002: missing required env fails.
    # From: Issue #1683
    unset GITHUB_REPOSITORY
    run _ci_image_ref build-tools sha256:beef
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"//"* ]]
}

# =========================================================
# SEMANTIC IMPACT
# =========================================================

@test "plan selects exactly the targets whose contexts a path touches" {
    # What: own context and named contexts pick candidates.
    # Why: no unrelated target and no prefix-only match.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml" path want row
    printf '%s\n' 'services:' '  svc-a:' '    context: dir/a' \
        '  svc-b:' '    context: dir/b' \
        'build_toolchain:' '  tool-t:' '    context: dir/t' \
        'named_contexts:' '  ctx-1:' '    path: shared/one.sh' \
        '  ctx-2:' '    path: shared/two.txt' \
        'dependency_graph:' '  svc-a:' '    contexts: [ctx-1, ctx-2]' \
        '  svc-b:' '    contexts: [ctx-1]' > "${m}"
    while IFS='|' read -r path want; do
        CI_MANIFEST="${m}" run bash "${CI_SH}" plan "${path}"
        [ "${status}" -eq 0 ]
        row="$(grep -v 'CI-INFO' <<< "${output}" | paste -sd' ' -)"
        [ "${row}" = "${want}" ] || { echo "${path}: ${row}"; return 1; }
        [[ "${output}" == *"candidates only; identity/CAS decides build"* ]]
    done <<'EOF'
dir/a/f|svc-a=true svc-b=false tool-t=false
shared/two.txt|svc-a=true svc-b=false tool-t=false
shared/one.sh|svc-a=true svc-b=true tool-t=false
dir/t/Dockerfile|svc-a=false svc-b=false tool-t=true
dir/ab/f|svc-a=false svc-b=false tool-t=false
EOF
}

@test "plan fails closed on a target without a SOT context" {
    # What: a missing context is CORE-0009, not a default.
    # Why: a guessed path would hide a broken SOT entry.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf '%s\n' 'services:' '  svc-a:' '    build_type: apk' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" plan dir/a/f
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0009]"* ]]
    [[ "${output}" != *"svc-a=false"* ]]
}
@test "codeql-impact admits exactly the languages a path touches" {
    # What: SOT language paths pick the matrix, else empty.
    # Why: no runner for unrelated or SOT-only changes.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml" path want
    printf '%s\n' 'codeql_languages:' '  lang-a:' '    paths: [src-a]' \
        '  lang-b:' '    paths: [wf]' 'base_images:' \
        "  codeql_runtime: registry.example.test/rt@sha256:$(printf '0%.0s' {1..64})" > "${m}"
    while IFS='|' read -r path want; do
        CI_MANIFEST="${m}" run bash "${CI_SH}" codeql-impact "${path}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"codeql-matrix={\"include\":${want}}"* ]] \
            || { echo "${path}: ${output}"; return 1; }
    done <<EOF
src-a/main.rs|[{"language":"lang-a"}]
wf/ci.yml|[{"language":"lang-b"}]
src-ab/x|[]
${CI_MANIFEST_REL}|[]
EOF
}
@test "codeql-coverage fails on tracked source outside SOT paths" {
    # What: files globs must all lie under the lang paths.
    # Why: a new source dir must not escape CodeQL silently.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/repo" m="${BATS_TEST_TMPDIR}/m.yml"
    mkdir -p "${r}/src-a" "${r}/src-b"
    : > "${r}/src-a/x.ext"
    git -C "${r}" init -q && git -C "${r}" add -A
    printf '%s\n' 'codeql_languages:' '  lang-a:' '    files: ["*.ext"]' \
        '    paths: [src-a]' '  lang-b:' '    paths: [src-b]' > "${m}"
    CI_MANIFEST="${m}" run _ci_check_codeql_coverage "${r}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "codeql-coverage=clean" ]
    : > "${r}/src-b/y.ext"
    git -C "${r}" add -A
    CI_MANIFEST="${m}" run _ci_check_codeql_coverage "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[CI-ERROR-CHECK-0072]"* ]]
    [[ "${output}" == *"lang-a: src-b/y.ext"* ]]
    CI_MANIFEST="${m}" run _ci_check_codeql_coverage "${BATS_TEST_TMPDIR}/none"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CHECK-0071]"* ]]
}
@test "codeql-config renders name, queries, paths and ignore from SOT" {
    # What: config is derived from the SOT and the repo.
    # Why: one SOT owner; no project name in the engine.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf '%s\n' 'codeql:' '  queries: [q1]' '  paths_ignore: ["x/**"]' \
        'codeql_languages:' '  lang-a:' '    paths: [src-a]' > "${m}"
    CI_MANIFEST="${m}" GITHUB_REPOSITORY=owner/fixture-repo \
        run --separate-stderr bash "${CI_SH}" codeql-config
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"[CI-INFO-CORE-0113] proxy=off"* ]]
    [ "${output}" = "$(printf '%s\n' 'name: fixture-repo-codeql' 'queries:' \
        '  - uses: "q1"' 'paths:' '  - "src-a"' 'paths-ignore:' '  - "x/**"')" ]
    CI_MANIFEST="${m}" GITHUB_REPOSITORY='' run bash "${CI_SH}" codeql-config
    [ "${status}" -ne 0 ]
    # What: same output with no jq on PATH; quotes escaped.
    # Why: the CodeQL runtime image has no jq (real job).
    # From: Issue #1683 | PR #1858
    local nojq="${BATS_TEST_TMPDIR}/nojq"; mkdir -p "${nojq}"
    _tool_stub "${nojq}" jq <<'STUB'
echo "jq: command not found" >&2; exit 127
STUB
    printf '%s\n' 'codeql:' '  queries: [q1]' '  paths_ignore: ["x/**", "a\"b"]' \
        'codeql_languages:' '  lang-a:' '    paths: [src-a]' > "${m}"
    PATH="${nojq}:${PATH}" CI_MANIFEST="${m}" GITHUB_REPOSITORY=owner/fixture-repo \
        run --separate-stderr bash "${CI_SH}" codeql-config
    [ "${status}" -eq 0 ] || { echo "${output} ${stderr}"; return 1; }
    [[ "${output}" == *'  - "x/**"'* ]] && [[ "${output}" == *'  - "a\"b"'* ]]
}
@test "an unreadable SOT fails every reader caller with raw" {
    # What: each caller row: rc 2 plus the raw reader error.
    # Why: a reader error must never read as an empty value.
    # From: Issue #1683 | PR #1858
    local call row
    while IFS= read -r row; do
        [ -n "${row}" ] || continue
        read -r -a call <<< "${row}"
        CI_MANIFEST="${BATS_TEST_TMPDIR}/missing.yml" GITHUB_REPOSITORY=o/r CI_COMPOSE_FILE=deploy/prod/docker-compose.yml \
            run "${call[@]}"
        [ "${status}" -eq 2 ] && [[ "${output}" == *"No such file"* ]] \
            && [[ "${output}" =~ \[CI-ERROR-CORE-010[789]\]\ block=.*manifest=\".*missing\.yml\" ]] \
            || { echo "${row}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
ci_service_field svc build_type
_ci_required_field svc context
_ci_platforms svc
_ci_platform_field linux/amd64 apk
ci_build_targets
_ci_alpine_build_arg --build-arg
_ci_service_packages svc
_ci_apk_repositories svc
_ci_apk_keys svc
_ci_build_tools_smoke smoke_tools
_ci_variable_value CI_UNSET_PROBE_NAME
_ci_plan_candidate svc a/file
_ci_identity_for svc linux/amd64
ci_cmd_codeql_config
_ci_check_stable_external_images /var/tmp
_ci_check_dockerfile_build_tools /var/tmp
CASES
}

@test "core helpers fail with code, context and raw tool error" {
    # What: real failing input per helper: rc 2, code, raw.
    # Why: a CI log must show where, with what and why.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/afile"
    : > "${f}"
    run _ci_mktemp -d "${f}/sub.XXXXXX"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0110] args=\"-d ${f}/sub.XXXXXX\""* ]]
    [[ "${output}" == *"Not a directory"* ]]
    [[ "${f}" == /var/tmp/* ]] || { echo "BATS_TEST_TMPDIR not under /var/tmp: ${f}"; return 1; }
    CI_TMPDIR="${f}/x" run _ci_tmp_init
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0111] dir=\"${f}/x\""* ]]
    [[ "${output}" == *"Not a directory"* ]]
    run bash -c 'source "$1"; RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=http://p:3128 PROJECT_SELFHOSTED_PROXY_CA=X CI_SYSTEM_CA_BUNDLE=/nonexistent/ca.pem CI_TMPDIR="$2" _ci_proxy_init' _ "${CI_SH}" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-CORE-0112] system_bundle="/nonexistent/ca.pem"'* ]]
    [[ "${output}" == *"No such file"* ]]
    run bash -c 'source "$1"; RUNNER_ENVIRONMENT=github-hosted _ci_proxy_init' _ "${CI_SH}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'[CI-INFO-CORE-0113] proxy=off runner="github-hosted" http_set=no'* ]]
    run _ci_ls_files probe-site "${BATS_TEST_TMPDIR}/nogit-root" '*.sh'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-CHECK-0071] site="probe-site"'* ]]
    [[ "${output}" == *"cannot change to"* || "${output}" == *"No such file"* ]]
}

@test "identity fails, never hashes, when a part fails" {
    # What: a failing content-id part ends with rc 2, no id.
    # Why: a part lost in the hash pipe minted a wrong id.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/id.yml"
    printf 'services:\n  svc:\n    context: c\n    build_type: apk\n' > "${m}"
    _ci_identity_pins() { echo pins; }
    _ci_tracked_content_ids() { echo "git: fatal: bad object" >&2; return 2; }
    CI_MANIFEST="${m}" run _ci_identity_for svc linux/amd64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"git: fatal: bad object"* ]]
    [[ ! "${output}" =~ [0-9a-f]{64} ]]
}

@test "SOT readers unquote YAML scalars; odd quoting fails" {
    # What: list+field rows: plain, "..", '..', bad forms.
    # Why: a kept quote broke the proxy nginx -V smoke.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/q.yml" name line want fn code
    while IFS='|' read -r name line want; do
        printf 'b:\n  e:\n    l:\n      - %s\n    f: %s\n    i: [%s]\n' "${line}" "${line}" "${line}" > "${m}"
        for fn in list field inline; do
            code="[CI-ERROR-CORE-0108]"
            case "${fn}" in
                list) CI_MANIFEST="${m}" run _ci_block_entry_list b e l ;;
                field) code="[CI-ERROR-CORE-0107]"; CI_MANIFEST="${m}" run _ci_block_entry_field b e f ;;
                inline) CI_MANIFEST="${m}" run _ci_block_entry_list b e i ;;
            esac
            case "${want}" in
                ERR) [ "${status}" -eq 2 ] && [[ "${output}" == *"${code}"* ]] \
                    && [[ "${output}" == *"unsupported YAML quoting"* ]] ;;
                *) [ "${status}" -eq 0 ] && [ "${output}" = "${want}" ] ;;
            esac || { echo "${name}/${fn}: rc ${status}: ${output}"; return 1; }
        done
    done <<'CASES'
plain|a/**|a/**
double|"x/**"|x/**
double-esc|"a\"b\\c\/d"|a"b\c/d
single|'it''s'|it's
single-bs|'a\b'|a\b
bad-escape|"a\nb"|ERR
open-double|"abc|ERR
open-single|'abc|ERR
inner-quote|"a"b"|ERR
CASES
    # What: a quoted shell smoke reads back as the command.
    # Why: sh -c must get the command, not a quoted name.
    # From: Issue #1683 | PR #1858
    printf 'services:\n  s:\n    smoke:\n      - "nginx -V 2>&1 | tr -d x"\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_block_entry_list services s smoke
    [ "${status}" -eq 0 ]
    [ "${output}" = 'nginx -V 2>&1 | tr -d x' ]
}
@test "codeql-impact gates on content; only real work needs the image" {
    # What: NOOP needs no image; work needs the SOT one.
    # Why: content gates the matrix; no image fails.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cqrepo" m img
    img="registry.example.test/runtime@sha256:$(printf '0%.0s' {1..64})"
    mkdir -p "${r}/svc"
    git -C "${r}" init -q
    git -C "${r}" config user.email t@t
    git -C "${r}" config user.name t
    printf 'fn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm base
    local base; base="$(git -C "${r}" rev-parse HEAD)"
    printf '// note\nfn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm cmt
    local cmt; cmt="$(git -C "${r}" rev-parse HEAD)"
    m="${r}/manifest.yml"
    printf 'codeql_languages:\n  rust:\n    paths: [svc]\n' > "${m}"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push \
      BEFORE_SHA="${base}" GITHUB_SHA="${cmt}" \
        run bash "${CI_SH}" codeql-impact svc/a.rs
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'codeql-matrix={"include":[]}'* ]]
    printf 'fn main() { let x = 1; }\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm real
    local real; real="$(git -C "${r}" rev-parse HEAD)"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push \
      BEFORE_SHA="${base}" GITHUB_SHA="${real}" \
        run bash "${CI_SH}" codeql-impact svc/a.rs
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CODEQL-0012]"* ]]
    printf 'base_images:\n  codeql_runtime: "%s"\n' "${img}" >> "${m}"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${r}" GITHUB_EVENT_NAME=push \
      BEFORE_SHA="${base}" GITHUB_SHA="${real}" \
        run bash "${CI_SH}" codeql-impact svc/a.rs
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'{"language":"rust"}'* ]]
    [[ "${output}" == *"codeql-image=${img}"* ]]
}

@test "fetch-verified: pinned asset passes; bad pin or 404 fails closed" {
    # What: sha256 must match the pin; 404 never retries.
    # Why: one owner for pinned downloads (AG-CI-006/013).
    # From: Issue #1683 | PR #1858
    local dl good log="${BATS_TEST_TMPDIR}/dl.log"
    dl="$(_stub dl 'echo "$1" >> "'"${log}"'"; case "$1" in *missing*) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;; *) printf payload > "$2" ;; esac')"
    good="$(printf payload | sha256sum | cut -d' ' -f1)"
    CI_HTTP_DOWNLOAD_CMD="${dl}" run _ci_fetch_verified https://x.test/ok "${good}" "${BATS_TEST_TMPDIR}/a"
    [ "${status}" -eq 0 ]
    CI_HTTP_DOWNLOAD_CMD="${dl}" run _ci_fetch_verified https://x.test/ok "$(printf '1%.0s' {1..64})" "${BATS_TEST_TMPDIR}/b"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-FETCH-0003]"* ]]
    CI_HTTP_DOWNLOAD_CMD="${dl}" run _ci_fetch_verified https://x.test/ok not-a-sha "${BATS_TEST_TMPDIR}/c"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-FETCH-0001]"* ]]
    : > "${log}"
    CI_HTTP_DOWNLOAD_CMD="${dl}" CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_fetch_verified https://x.test/missing "${good}" "${BATS_TEST_TMPDIR}/d"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-FETCH-0002]"* ]]
    [ "$(grep -c missing "${log}")" -eq 1 ]
}

@test "codeql-analyze fails closed without a SOT language or context" {
    # What: no arg, unknown language or no upload env fails.
    # Why: never analyze or upload on partial input.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'codeql_languages:\n  lang-a:\n    paths: [src]\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" codeql-analyze
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CODEQL-0002]"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" codeql-analyze lang-b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CODEQL-0003]"* ]]
    CI_MANIFEST="${m}" GITHUB_REPOSITORY='' GITHUB_REF='' GITHUB_SHA='' GITHUB_TOKEN='' \
        run bash "${CI_SH}" codeql-analyze lang-a
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CODEQL-0004]"* ]]
}

@test "codeql-analyze runs create, analyze, upload from the pinned bundle" {
    # What: fetch+verify the bundle, then the 3 steps.
    # Why: no action pin; per-language category; cleanup.
    # From: Issue #1683 | PR #1858
    local b="${BATS_TEST_TMPDIR}/bundle" m="${BATS_TEST_TMPDIR}/m.yml" log="${BATS_TEST_TMPDIR}/cq.log"
    local t="${BATS_TEST_TMPDIR}/tmp" sha dl
    mkdir -p "${b}/codeql" "${t}"
    _tool_stub "${b}/codeql" codeql <<STUB
echo "\$*" >> "${log}"
STUB
    tar -czf "${BATS_TEST_TMPDIR}/bundle.tgz" -C "${b}" codeql
    sha="$(sha256sum "${BATS_TEST_TMPDIR}/bundle.tgz" | cut -d' ' -f1)"
    printf 'codeql:\n  queries: [q1]\ncodeql_languages:\n  lang-a:\n    paths: [src]\nexternal_versions:\n  codeql:\n    repository: owner/tool\n    release_tag: t1\n    asset: bundle.tgz\n    sha256: %s\n' "${sha}" > "${m}"
    dl="$(_stub dl 'cp "'"${BATS_TEST_TMPDIR}"'/bundle.tgz" "$2"')"
    CI_MANIFEST="${m}" CI_HTTP_DOWNLOAD_CMD="${dl}" TMPDIR="${t}" \
      GITHUB_REPOSITORY=owner/fixture GITHUB_REF=refs/heads/x \
      GITHUB_SHA="$(printf 'a%.0s' {1..40})" GITHUB_TOKEN=t \
        run bash "${CI_SH}" codeql-analyze lang-a
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-INFO-CODEQL-0011]"* ]]
    grep -q -- 'database create .*--language=lang-a --build-mode=none' "${log}"
    grep -q -- 'database analyze .*--sarif-category=/language:lang-a' "${log}"
    grep -q -- 'github upload-results --repository=owner/fixture --ref=refs/heads/x' "${log}"
    [ -z "$(ls -A "${t}")" ]
}

@test "platform-field reads apk arch and runner from the SOT, fail-closed" {
    # What: platform->field from platform_arch SOT.
    # Why: one owner; no per-arch duplication.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'platform_arch:\n  p1:\n    apk: TESTARCH\n    runner: TESTRUN\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_platform_apk_arch os/p1
    [ "${status}" -eq 0 ]
    [ "${output}" = "TESTARCH" ]
    CI_MANIFEST="${m}" run _ci_platform_runner os/p1
    [ "${status}" -eq 0 ]
    [ "${output}" = "TESTRUN" ]
    CI_MANIFEST="${m}" run _ci_platform_runner linux/riscv64
    [ "${status}" -ne 0 ]
}

@test "matrix-append builds one include object from key=value pairs" {
    # What: One JSON builder from any key=value field set.
    # Why: Base-CI needs a service field too.
    # From: Issue #1683
    run _ci_matrix_append '[]' service=ui arch=arch-a runner=r1 platform=os/p1
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].service')" = "ui" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].platform')" = "os/p1" ]
}

@test "plan-matrix emits only resolve-build targets, one row per platform" {
    # What: Matrix carries only what resolve says to build.
    # Why: identity filters, not path-sledgehammer.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt" svc ctx want m; : > "${gh}"
    svc="$(ci_services)"
    svc="${svc%%$'\n'*}"
    ctx="$(_ci_block_entry_field services "${svc}" context)"
    want="$(_ci_platforms "${svc}" | sort | paste -sd, -)"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
        run bash "${CI_SH}" plan-matrix "${ctx}/Dockerfile"
    [ "${status}" -eq 0 ]
    grep -q '^any-build=true$' "${gh}"
    m="$(grep '^matrix=' "${gh}" | sed 's/^matrix=//')"
    [ "$(printf '%s' "${m}" | jq -r '[.include[].service]|unique|join(",")')" = "${svc}" ]
    [ "$(printf '%s' "${m}" | jq -r '[.include[].platform]|sort|join(",")')" = "${want}" ]
}

@test "plan-matrix treats a SOT-only change as identity candidates" {
    # What: SOT change -> all targets checked, no tests.
    # Why: pins live in the SOT; identity decides BUILD.
    # From: Issue #1683 | PR #1858
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
    CI_IMPACT_CMD="$(_stub impact '[ "$1" = proxy ] && echo BUILD || echo NOOP')" \
        run bash "${CI_SH}" plan-matrix "${CI_MANIFEST_REL}"
    [ "${status}" -eq 0 ]
    [ "$(sed -n 's/^matrix=//p' "${gh}" | jq -r '[.include[].service]|unique|join(",")')" = proxy ]
    grep -q '^test-services=$' "${gh}"
    : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
    CI_IMPACT_CMD="$(_stub impact 'echo NOOP')" \
        run bash "${CI_SH}" plan-matrix "${CI_MANIFEST_REL}"
    [ "${status}" -eq 0 ]
    grep -q '^any-build=false$' "${gh}"
}

@test "plan-matrix drops a missing target without proven impact" {
    # What: MISSING_CONFIRMED+impact NOOP stays out.
    # Why: MISSING_CONFIRMED alone MUST NOT build.
    # From: Issue #1683 | PR #1858
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
    CI_IMPACT_CMD="$(_stub impact 'echo NOOP')" \
        run bash "${CI_SH}" plan-matrix services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^any-build=false$' "${gh}"
}

@test "plan-matrix emits docs-only=true for a docs-only change" {
    # What: Docs-only change: no container jobs (§63).
    # Why: container jobs gate on docs-only != true.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix fixture-note.md
    [ "${status}" -eq 0 ]
    grep -q '^docs-only=true$' "${gh}"
    grep -q '^any-build=false$' "${gh}"
}

@test "plan-matrix emits test-services for a path-changed rust service" {
    # What: Changed Rust source triggers test run.
    # Why: tests run on source change, reuse or not (§60).
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/watchdog/src/main.rs
    [ "${status}" -eq 0 ]
    grep -q '^test-services=watchdog$' "${gh}"
    grep -q '^rust-validation=false$' "${gh}"
    : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RUST_VALIDATION=true \
        CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/watchdog/src/main.rs
    grep -q '^rust-validation=true$' "${gh}"
}

@test "plan-matrix emits no test-services for a path-changed apk service" {
    # What: APK service has no unit tests.
    # Why: ci.sh test skips APK services.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/ntp/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^test-services=$' "${gh}"
}

@test "plan-matrix omits an accepted target (NOOP), any-build=false" {
    # What: An accepted identity is not rebuilt.
    # Why: NOOP/reuse precedes build; a skip stays out.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo PRESENT_ACCEPTED')" \
        run bash "${CI_SH}" plan-matrix services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^any-build=false$' "${gh}"
    local m; m="$(grep '^matrix=' "${gh}" | sed 's/^matrix=//')"
    [ "$(printf '%s' "${m}" | jq '.include | length')" -eq 0 ]
}

# =========================================================
# SERVICE DEPENDENCIES
# =========================================================

@test "service field and contexts come from the SOT blocks" {
    # What: services then build_toolchain; contexts by edge.
    # Why: one SOT reader; no per-file copy of these values.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf '%s\n' 'services:' '  svc-a:' '    build_type: type-a' '    runner: r1' \
        'build_toolchain:' '  tool-t:' '    build_type: type-t' \
        'dependency_graph:' '  svc-a:' '    contexts: [ctx-1, ctx-2]' > "${m}"
    CI_MANIFEST="${m}" run ci_service_field svc-a build_type
    [ "${output}" = "type-a" ]
    CI_MANIFEST="${m}" run ci_service_field svc-a runner
    [ "${output}" = "r1" ]
    CI_MANIFEST="${m}" run ci_service_field tool-t build_type
    [ "${output}" = "type-t" ]
    CI_MANIFEST="${m}" run ci_service_contexts svc-a
    [ "${output}" = "$(printf '%s\n' ctx-1 ctx-2)" ]
    CI_MANIFEST="${m}" run _ci_required_field svc-a context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0009]"* ]]
}

# =========================================================
# BUILD IDENTITIES
# =========================================================

# What: neutral git repo and SOT for identity tests.
# Why: ids must be tested on the engine, not the inventory.
# From: Issue #1683
_identity_fixture() {
    local r="${BATS_TEST_TMPDIR}/idrepo" h0
    h0="$(printf '0%.0s' {1..64})"
    mkdir -p "${r}/dir/a" "${r}/dir/b"
    printf 'a\n' > "${r}/dir/a/f"; printf 'b\n' > "${r}/dir/b/f"
    git -C "${r}" init -q && git -C "${r}" add -A
    printf '%s\n' 'services:' \
        '  svc-a:' '    context: dir/a' '    build_type: type-s' \
        '  svc-b:' '    context: dir/b' '    build_type: type-s' \
        '  svc-p:' '    context: dir/b' '    build_type: type-p' '    packages: [pkg]' \
        'build_identity:' '  type-s:' '    inputs: [source_sha]' \
        '  type-p:' '    inputs: [source_sha, package_versions]' \
        'base_images:' "  alpine: registry.example.test/base@sha256:${h0}" \
        'build_matrix:' '  platforms: [os/p1, os/p2]' \
        'platform_arch:' '  p1:' '    apk: arch-a' '  p2:' '    apk: arch-b' > "${r}/m.yml"
    export CI_MANIFEST="${r}/m.yml" CI_REPO_ROOT="${r}"
}

@test "identity is keyed, deterministic and per target" {
    # What: same input, same id; other target/arch differs.
    # Why: NOOP/reuse needs stable ids that never collide.
    # From: Issue #1683
    _identity_fixture
    run --separate-stderr bash "${CI_SH}" identity svc-a os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^platform=os/p1\ identity=[0-9a-f]{64}$ ]]
    local a1="${output}"
    run --separate-stderr bash "${CI_SH}" identity svc-a os/p1
    [ "${output}" = "${a1}" ]
    run --separate-stderr bash "${CI_SH}" identity svc-b os/p1
    [ "${status}" -eq 0 ]; [[ "${output}" =~ ^platform=os/p1\ identity=[0-9a-f]{64}$ ]]; [ "${output}" != "${a1}" ]
    run --separate-stderr bash "${CI_SH}" identity svc-a os/p2
    [ "${status}" -eq 0 ]; [[ "${output}" =~ ^platform=os/p2\ identity=[0-9a-f]{64}$ ]]
    [ "${output#*identity=}" != "${a1#*identity=}" ]
    run --separate-stderr bash "${CI_SH}" identity svc-p os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^platform=os/p1\ identity=[0-9a-f]{64}$ ]]
}

@test "identity fails closed with a stable id when no service is given" {
    # What: Missing arg must not crash on set -u.
    # Why: Fail-closed with our own message, not a trace.
    # From: Issue #1683
    run bash "${CI_SH}" identity
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0001"* ]]
}

# =========================================================
# PLATFORMS
# =========================================================

@test "identity fans out per platform and rejects foreign ones" {
    # What: one keyed line per SOT platform; unknown fails.
    # Why: default is all; unknown input never fans out.
    # From: Issue #1683
    _identity_fixture
    run --separate-stderr bash "${CI_SH}" identity svc-a
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "platform=os/p1 identity="* ]]
    [[ "${lines[1]}" == "platform=os/p2 identity="* ]]
    run bash "${CI_SH}" identity svc-a os/p9
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0002"* ]]
    sed -i '/^  platforms: \[/d' "${CI_MANIFEST}"
    run bash "${CI_SH}" identity svc-a
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0003"* ]]
    [[ "${output}" != *"identity="* ]]
}

@test "source identity moves on a tracked content change only" {
    # What: an edit in the context moves its id, not others.
    # Why: impact is content identity, never a path guess.
    # From: Issue #1683
    _identity_fixture
    local a0 b0
    a0="$(bash "${CI_SH}" identity svc-a os/p1)"; b0="$(bash "${CI_SH}" identity svc-b os/p1)"
    printf 'changed\n' > "${CI_REPO_ROOT}/dir/a/f"
    git -C "${CI_REPO_ROOT}" add -A
    [ "$(bash "${CI_SH}" identity svc-a os/p1)" != "${a0}" ]
    [ "$(bash "${CI_SH}" identity svc-b os/p1)" = "${b0}" ]
}

@test "rust identity ignores comment-only and blank edits" {
    # What: A comment-only .rs edit keeps the same id.
    # Why: Comment churn must resolve to NOOP, not build.
    # From: Issue #1683
    local a b
    a="$(printf 'fn main() {}\n' | _ci_rust_content_hash)"
    b="$(printf '// note\nfn main() {}\n\n' | _ci_rust_content_hash)"
    [ -n "${a}" ]
    [ "${a}" = "${b}" ]
}

@test "rust identity keeps a // inside a string literal" {
    # What: Only line-start // is a comment, not in code.
    # Why: A naive strip would fuse distinct sources.
    # From: Issue #1683
    local a b
    a="$(printf 'let u = "//x";\n' | _ci_rust_content_hash)"
    b="$(printf 'let u = "//y";\n' | _ci_rust_content_hash)"
    [ "${a}" != "${b}" ]
}

@test "only compiled sources are identity-normalized" {
    # What: .rs normalizes; copied files stay raw-hashed.
    # Why: A hash in a .conf is payload; strip misreuses.
    # From: Issue #1683
    local p want
    while read -r p want; do
        run _ci_source_is_normalizable "${p}"
        [ "${status}" -eq "${want}" ] || { echo "${p}: ${status}"; return 1; }
    done <<'EOF'
dir/src/a.rs 0
dir/a.conf 1
dir/a.sh 1
dir/Dockerfile 1
EOF
}

@test "rust strip-safety rejects raw and multiline strings" {
    # What: Strip is safe without string-spanning lines.
    # Why: A raw or multiline string can carry a //-line.
    # From: Issue #1683
    run _ci_rust_strip_is_safe <<< $'fn main() {\n    let x = 1;\n}'
    [ "${status}" -eq 0 ]
    run _ci_rust_strip_is_safe <<< 'let j = r#"x"#;'
    [ "${status}" -ne 0 ]
    run _ci_rust_strip_is_safe <<< $'let s = "opens\nand runs on";'
    [ "${status}" -ne 0 ]
}

@test "raw-string // line is protected from wrong reuse" {
    # What: A // inside a raw string must not be stripped.
    # Why: Normalizing it would reuse a wrong image.
    # From: Issue #1683
    local a b
    a=$'let j = r#"\n// alpha\n"#;'
    b=$'let j = r#"\n// beta\n"#;'
    [ "$(printf '%s' "${a}" | _ci_rust_content_hash)" = "$(printf '%s' "${b}" | _ci_rust_content_hash)" ]
    run _ci_rust_strip_is_safe <<< "${a}"
    [ "${status}" -ne 0 ]
    run _ci_rust_strip_is_safe <<< "${b}"
    [ "${status}" -ne 0 ]
}

@test "impact fails closed without a base ref" {
    # What: impact needs an explicit base ref.
    # Why: No base means no comparison; never guess.
    # From: Issue #1683
    run bash "${CI_SH}" impact
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IMPACT-0001"* ]]
}

@test "impact of a ref against itself is all NOOP" {
    # What: Identical refs rebuild nothing (real git SOT).
    # Why: No diff means no build; no rebuild.
    # From: Issue #1683
    CI_MANIFEST="${CI_MANIFEST_SOURCE}" run bash "${CI_SH}" impact HEAD HEAD
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"impact=NOOP"* ]]
    [[ "${output}" != *"impact=BUILD"* ]]
    [[ "${output}" == *"build=0"* ]]
}

@test "content ids read a given ref and stay comment-invariant" {
    # What: A ref reads that commit; comments do not count.
    # Why: impact diffs base vs head by ref, not index.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/refrepo"
    mkdir -p "${r}/svc"
    git -C "${r}" init -q
    git -C "${r}" config user.email t@t
    git -C "${r}" config user.name t
    printf 'fn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm base
    local base; base="$(git -C "${r}" rev-parse HEAD)"
    printf 'fn main() { let x = 1; }\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm head
    local head; head="$(git -C "${r}" rev-parse HEAD)"
    printf '// note\nfn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm cmt
    local cmt; cmt="$(git -C "${r}" rev-parse HEAD)"
    local b h c
    b="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${base}")"
    h="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${head}")"
    c="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${cmt}")"
    [ -n "${b}" ]
    [ "${b}" != "${h}" ]
    [ "${b}" = "${c}" ]
}

@test "impact fails closed to UNKNOWN (escalate) when base has no SOT" {
    # What: A base without the SOT is UNKNOWN, not BUILD.
    # Why: No base truth MUST NOT authorize BUILD; escalate.
    # From: Issue #1683
    run bash "${CI_SH}" impact 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"no SOT at base"* ]]
    [[ "${output}" == *"impact=UNKNOWN"* ]]
    [[ "${output}" != *"impact=BUILD"* ]]
    [[ "${output}" != *"impact=NOOP"* ]]
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

@test "identity pins are ref-relative via CI_MANIFEST" {
    # What: A pin-only change shifts the id at a fixed ref.
    # Why: impact base pins must reflect base, not head.
    # From: Issue #1683
    local m1="${BATS_TEST_TMPDIR}/m1.yml" m2="${BATS_TEST_TMPDIR}/m2.yml"
    cp "${CI_MANIFEST}" "${m1}"
    cp "${m1}" "${m2}"
    sed -i 's/sha256_arch-a: [0-9a-f]\{64\}/sha256_arch-a: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "${m2}"
    local a b tgt
    tgt="$(_pin_consumer)"
    a="$(CI_MANIFEST="${m1}" _ci_identity_for "${tgt}" os/p1 HEAD)"
    b="$(CI_MANIFEST="${m2}" _ci_identity_for "${tgt}" os/p1 HEAD)"
    [ -n "${a}" ]
    [ "${a}" != "${b}" ]
}

@test "registry derives from the SOT and drives refs" {
    # What: A changed release.registry moves the built ref.
    # Why: Proves host is SOT-driven, not hardcoded.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/reg.yml" host tag
    sed 's/^  registry: .*/  registry: example.io/' "${CI_MANIFEST}" > "${m}"
    host="$(CI_MANIFEST="${m}" _ci_registry)"
    [ "${host}" = "example.io" ]
    tag="$(CI_MANIFEST="${m}" GITHUB_REPOSITORY=owner/fixture-repo _ci_image_tag proxy os/p1 abcd)"
    [[ "${tag}" == example.io/* ]]
}

@test "registry fails closed when release.registry is absent" {
    # What: A SOT without registry yields no empty host.
    # Why: An empty host builds a malformed ref, silently.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/noreg.yml"
    grep -v '^  registry:' "${CI_MANIFEST}" > "${m}"
    run bash -c "source '${CI_SH}'; CI_MANIFEST='${m}' _ci_registry 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
}

@test "resolve rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" resolve ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0004"* ]]
}

@test "build rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0006"* ]]
}

@test "build tags its result line with the selected platform" {
    # What: A selected build emits one platform-keyed line.
    # Why: Downstream assembly keys per-platform digests.
    # From: Issue #1683
    local p
    p="$(_ci_platforms ui)"
    p="${p##*$'\n'}"
    STUB_STATE=PRESENT_ACCEPTED
    GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run --separate-stderr bash "${CI_SH}" build ui "${p}"
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${output}" == *"platform=${p}"* ]]
    [[ "${output}" == *"result=reuse-accepted"* ]]
}

@test "per-service platform override is a strict subset of build_matrix" {
    # What: An override must be a proper subset.
    # Why: The global list bounds all; equal = drift.
    # From: Issue #1683
    local global svc ov p
    global="$(_ci_build_matrix_platforms | sort | tr '\n' ' ')"
    for svc in $(ci_build_targets); do
        ov="$(_ci_service_platforms_override "${svc}")"
        [ -n "${ov}" ] || continue
        while IFS= read -r p; do
            [ -z "${p}" ] && continue
            grep -qx -- "${p}" <<< "${global// /$'\n'}"
        done <<< "${ov}"
        [ "$(printf '%s\n' ${ov} | sort | tr '\n' ' ')" != "${global}" ]
    done
}

# =========================================================
# RESOLVER STATES
# =========================================================

# What: A stub probe that returns a fixed state.
# Why: Test the resolver logic without a live GHCR.
# From: Issue #1683
_probe_stub() {
    _stub probe.sh "printf '%s\\n' \"${STUB_STATE}\""
}

@test "resolve maps every probe outcome to exactly one action" {
    # What: each probe outcome -> one state and action.
    # Why: only MISSING_CONFIRMED may build; UNKNOWN never.
    # From: Issue #1683 | PR #1858
    local -a svcs pe
    local name probe state action id
    mapfile -t svcs <<<"$(ci_services)"
    while IFS='|' read -r name probe state action id; do
        pe=(-u CI_RESOLVE_PROBE_CMD)
        case "${probe}" in
            none) ;;
            fail) pe+=(CI_RESOLVE_PROBE_CMD="$(_stub probe 'echo MISSING_CONFIRMED; exit 7')") ;;
            *) pe+=(CI_RESOLVE_PROBE_CMD="$(_stub probe "echo ${probe}")") ;;
        esac
        run env "${pe[@]}" bash "${CI_SH}" resolve "${svcs[0]}"
        [ "${status}" -eq 0 ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"state=${state} action=${action} "* ]] || { echo "${name}: ${output}"; return 1; }
        [ "${action}" = build ] || [[ "${output}" != *"action=build"* ]] || { echo "${name}: build: ${output}"; return 1; }
        [ "${id}" = - ] || [[ "${output}" == *"${id}"* ]] || { echo "${name}: no ${id}: ${output}"; return 1; }
    done <<'CASES'
accepted|PRESENT_ACCEPTED|PRESENT_ACCEPTED|noop|-
missing|MISSING_CONFIRMED|MISSING_CONFIRMED|build|-
mismatch|MISMATCH|MISMATCH|fail|-
unverified|PRODUCED_UNVERIFIED|PRODUCED_UNVERIFIED|verify|-
in-progress|BUILD_IN_PROGRESS|BUILD_IN_PROGRESS|wait|-
unknown|UNKNOWN|UNKNOWN|escalate|CI-INFO-RESOLVE-0003
garbage|BOGUS|UNKNOWN|escalate|CI-ERROR-RESOLVE-0002
probe-fail|fail|UNKNOWN|escalate|CI-INFO-RESOLVE-0005
no-probe|none|UNKNOWN|escalate|CI-INFO-RESOLVE-0003
CASES
}

@test "resolve fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" resolve
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0001"* ]]
}

# =========================================================
# RETRY CLASSIFICATION
# =========================================================

@test "retry classifier: rate-limit / 5xx / network are transient" {
    # What: These recover on retry with backoff.
    # Why: One rule replaces every wrapper's own split.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'toomanyrequests: HTTP 429')" = "transient" ]
    [ "$(_ci_classify_failure 'received HTTP 503 from registry')" = "transient" ]
    [ "$(_ci_classify_failure 'dial tcp: i/o timeout')" = "transient" ]
    [ "$(_ci_classify_failure 'connection refused')" = "transient" ]
    [ "$(_ci_classify_failure 'curl: (22) The requested URL returned error: 503')" = "transient" ]
    [ "$(_ci_classify_failure 'curl: (22) The requested URL returned error: 403')" = "transient" ]
}

@test "retry classifier: auth / malformed / compile are permanent" {
    # What: Retrying these only burns the budget.
    # Why: A fixed outcome must fail fast, not loop.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'HTTP 401 unauthorized')" = "permanent" ]
    [ "$(_ci_classify_failure 'error: could not compile lancache-ui')" = "permanent" ]
    [ "$(_ci_classify_failure 'pull access denied for registry.example.test/x')" = "permanent" ]
    [ "$(_ci_classify_failure 'curl: (22) The requested URL returned error: 404')" = "permanent" ]
    [ "$(_ci_classify_failure 'ERROR: unable to select packages: x (no such package)')" = "permanent" ]
    [ "$(_ci_classify_failure 'ERROR: Not committing changes due to missing repository tags.')" = "permanent" ]
    [ "$(_ci_classify_failure 'An image does not exist locally with the tag: registry.example.test/o/r/svc')" = "permanent" ]
    [ "$(_ci_classify_failure 'Error response from daemon: No such image: registry.example.test/o/r/svc:t')" = "permanent" ]
}

@test "retry classifier: a missing manifest is not_found, auth is not" {
    # What: not_found is separate; auth stays permanent.
    # Why: only not_found may build; auth must never build.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'manifest unknown')" = "not_found" ]
    [ "$(_ci_classify_failure 'registry.example.test/x: not found: manifest')" = "not_found" ]
    [ "$(_ci_classify_failure 'denied: requested access to the resource')" = "permanent" ]
}

@test "retry classifier: an unclassified failure defaults to transient" {
    # What: Unknown error -> retry, not give up.
    # Why: A missed transient is worse than a few retries.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'some novel error text')" = "transient" ]
}

@test "retry classifier: matching is case-insensitive (curl/git casing)" {
    # What: Case-insensitive match for transient errors.
    # Why: Go/curl/git have different error text casing.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'Connection reset by peer')" = "transient" ]
    [ "$(_ci_classify_failure 'HTTP 401 Unauthorized')" = "permanent" ]
}

@test "retry classifier: op=github-api 404 is permanent, never not_found" {
    # What: GitHub API 404 maps to permanent, not not_found.
    # Why: Registry 404 can recover; API 404 never can.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'gh: Not Found (HTTP 404)' github-api)" = "permanent" ]
    [ "$(_ci_classify_failure 'gh: Not Found (HTTP 404)' github-api)" != "not_found" ]
}

@test "retry classifier: op=registry (default) still returns not_found on 404-shaped text" {
    # What: Default op returns not_found for 404 text.
    # Why: Preserves legacy registry-probe behavior.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'registry.example.test/x: not found: manifest')" = "not_found" ]
    [ "$(_ci_classify_failure 'registry.example.test/x: not found: manifest' registry)" = "not_found" ]
}

@test "retry classifier: op=buildx retries the layer-lock and go-panic signatures" {
    # What: layer-lock and panic are transient.
    # Why: buildx layer-lock signature evidence.
    # From: Issue #1222
    [ "$(_ci_classify_failure '(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:abc locked for 900ms (since t): unavailable' buildx)" = "transient" ]
    [ "$(_ci_classify_failure 'panic: methodref has no signature' buildx)" = "transient" ]
}

@test "retry classifier: buildx signatures never leak into a real compile failure" {
    # What: Unrelated buildx ops stay permanent.
    # Why: op-gating prevents matching widening.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'error: could not compile lancache-ui' buildx)" = "permanent" ]
}

@test "retry classifier: a failed buildx RUN is permanent unless network" {
    # What: RUN exit: permanent; I/O cause: transient.
    # Why: a missing build variable must not be retried.
    # From: Issue #1683 | PR #1858
    local run='process "/bin/sh -c x" did not complete successfully: exit code: 1'
    [ "$(_ci_classify_failure "x is required (no default)"$'\n'"${run}" buildx)" = "permanent" ]
    [ "$(_ci_classify_failure "connection reset by peer"$'\n'"${run}" buildx)" = "transient" ]
    [ "$(_ci_classify_failure "x is required"$'\n'"${run}" registry)" = "transient" ]
}

@test "retry classifier: git-fetch transient signatures are covered" {
    # What: DNS/RPC/disconnect transient signatures.
    # Why: Classifier owns the git-fetch transient cases.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'unexpected disconnect while reading sideband packet')" = "transient" ]
    [ "$(_ci_classify_failure 'The remote end hung up unexpectedly')" = "transient" ]
    [ "$(_ci_classify_failure 'Could not resolve host: github.com')" = "transient" ]
    [ "$(_ci_classify_failure 'RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly')" = "transient" ]
    [ "$(_ci_classify_failure 'GnuTLS recv error (-9): A TLS packet with unexpected length was received.')" = "transient" ]
}

@test "retry classifier: a missing git ref is permanent, never retried" {
    # What: Missing git ref maps to permanent.
    # Why: Absent refs cannot be fixed by retrying.
    # From: Issue #1683
    [ "$(_ci_classify_failure "fatal: couldn't find remote ref refs/x")" = "permanent" ]
}

@test "retry classifier: op=accel is transient only on an accelerator outage" {
    # What: real distcc/sccache/ccache outage lines vs bugs.
    # Why: a real compile error must fail, never degrade.
    # From: Issue #1683 | PR #1858
    local name raw want got
    while IFS='|' read -r name raw want; do
        got="$(_ci_classify_failure "${raw}" accel)"
        [ "${got}" = "${want}" ] || { echo "${name}: got ${got}, want ${want}"; return 1; }
    done <<'CASES'
distcc|distcc[13] (dcc_build_somewhere) ERROR: failed to distribute and fallbacks are disabled|transient
sccache|sccache: error: Timed out waiting for server startup. Maybe the remote service is unreachable?|transient
ccache|ccache: error: No such file or directory|transient
c-error|e.c:1:23: error: 'x' undeclared (first use in this function)|permanent
rust-error|error: could not compile `lancache-ui` (bin "lancache-ui") due to 2 previous errors|permanent
fetch|error: failed to download from `https://index.crates.io/config.json`|permanent
CASES
}

@test "reuse order is cheapest-first and ends in compile" {
    # What: noop..accepted..CAS..caches..compile order.
    # Why: NOOP/reuse always precede build (§7).
    # From: Issue #1683
    local order; order="$(ci_reuse_order)"
    [ "${order%% *}" = "noop" ]
    [ "${order##* }" = "compile" ]
}

# =========================================================
# BUILD ADMISSION
# =========================================================

# What: Write an executable stub that prints/exits fixed.
# Why: Inject build/CAS/probe backends without real infra.
# From: Issue #1683
_stub() {
    local name="$1" body="$2"
    _tool_stub "${BATS_TEST_TMPDIR}" "${name}" <<<"${body}"
    printf '%s\n' "${BATS_TEST_TMPDIR}/${name}"
}

@test "build admission: only impact + MISSING_CONFIRMED + auth build" {
    # What: every resolver/impact/CAS/auth combination.
    # Why: one build path; all other states reuse or stop.
    # From: Issue #1683
    local case state impact cas auth rc want probe w
    local -a adm_env
    while IFS='|' read -r case state impact cas auth rc want; do
        STUB_STATE="${state}"
        probe="$(_probe_stub)"
        [ "${case}" != probe-fail ] || probe="$(_stub probe 'echo MISSING_CONFIRMED; exit 7')"
        adm_env=(-u GITHUB_EVENT_NAME -u BEFORE_SHA -u GHCR_USERNAME -u GHCR_TOKEN
            CI_RESOLVE_PROBE_CMD="${probe}"
            CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED')")
        [ "${impact}" = - ] || adm_env+=(CI_IMPACT_CMD="$(_stub impact "echo ${impact}")")
        [ "${cas}" = - ] || adm_env+=(CI_CAS_LOOKUP_CMD="$(_stub cas "exit ${cas}")")
        [ "${auth}" = no ] || adm_env+=(GHCR_USERNAME=u GHCR_TOKEN=t)
        run env "${adm_env[@]}" bash "${CI_SH}" build ui
        [ "${status}" -eq "${rc}" ] || { echo "${case}: rc ${status}: ${output}"; return 1; }
        for w in ${want}; do
            [[ "${output}" == *"${w}"* ]] || { echo "${case}: no ${w}: ${output}"; return 1; }
        done
        [ "${case}" = built ] && continue
        [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]] || { echo "${case}: backend ran"; return 1; }
        [[ "${output}" != *"result=built"* ]] || { echo "${case}: built"; return 1; }
    done <<'CASES'
accepted|PRESENT_ACCEPTED|-|-|yes|0|result=reuse-accepted
unknown|UNKNOWN|-|-|yes|2|result=escalate
cas-hit|MISSING_CONFIRMED|BUILD|0|yes|0|result=reuse-binary-cas
no-auth|MISSING_CONFIRMED|BUILD|1|no|2|CI-ERROR-BUILD-0002
built|MISSING_CONFIRMED|BUILD|1|yes|0|state=BUILD_ACK result=built
mismatch|MISMATCH|BUILD|1|yes|2|result=fail-mismatch CI-ERROR-BUILD-0010
probe-fail|-|BUILD|1|yes|2|result=escalate
no-impact|MISSING_CONFIRMED|NOOP|1|yes|0|result=no-build-no-impact
no-base|MISSING_CONFIRMED|-|1|yes|2|result=escalate
CASES
}

@test "semantic impact compares the head id with the base id" {
    # What: equal=NOOP, diff=BUILD, no base=UNKNOWN.
    # Why: BUILD needs proven impact; compare refs.
    # From: Issue #1683 | PR #1858
    _ci_diff_refs() { printf 'B H\n'; }
    _ci_manifest_at() { printf 'x\n' > "$2"; }
    _ci_identity_for() { [ "$3" = B ] && echo base-id; }
    run _ci_semantic_impact svc-a os/p1 base-id
    [ "${lines[-1]}" = NOOP ]
    run _ci_semantic_impact svc-a os/p1 head-id
    [ "${lines[-1]}" = BUILD ]
    [[ "${output}" == *"[CI-INFO-IMPACT-0004]"* ]]
    _ci_identity_for() { return 2; }
    run _ci_semantic_impact svc-a os/p1 head-id
    [ "${lines[-1]}" = UNKNOWN ]
    _ci_diff_refs() { :; }
    run _ci_semantic_impact svc-a os/p1 head-id
    [ "${lines[-1]}" = UNKNOWN ]
    [[ "${output}" == *"[CI-INFO-IMPACT-0003]"* ]]
}

# =========================================================
# TEST / SCAN
# =========================================================

@test "test fails closed and shows raw output when tests fail" {
    # What: A failed test run is a failed run (AG-VAL-002).
    # Why: Never skip or swallow a real test failure.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'echo boom; exit 1')" run bash "${CI_SH}" test ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0003"* ]]
    [[ "${output}" == *"boom"* ]]
}

@test "test passes when the backend succeeds" {
    # What: Green backend -> tested=ok.
    # Why: The one success path.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'echo "service=ui tested=ok"; exit 0')" run bash "${CI_SH}" test ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "rust test is off by default and never runs cargo check" {
    # What: default SKIP; on runs fmt/clippy/test, no check.
    # Why: AG-VAL-008: no cargo check in CI; the rest gated.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/cargo.log"
    mkdir -p "${bin}"
    _tool_stub "${bin}" cargo <<STUB
echo "\$1" >> "${log}"
STUB
    _stub_sccache "${bin}" 0
    printf '%s\n' 'services:' '  svc-r:' '    build_type: rust' '    crate: crate-r' \
        'ci_variables:' '  CI_RUST_VALIDATION: "false"' > "${BATS_TEST_TMPDIR}/m.yml"
    export CI_MANIFEST="${BATS_TEST_TMPDIR}/m.yml" PATH="${bin}:${PATH}"
    run bash "${CI_SH}" test svc-r
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=SKIP"*"AG-VAL-008"* ]]
    [ ! -e "${log}" ]
    CI_RUST_VALIDATION=true run bash "${CI_SH}" test svc-r
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
    [ "$(paste -sd' ' "${log}")" = "fmt clippy test" ]
}

@test "rust test runs every cargo call through sccache" {
    # What: cargo sees RUSTC_WRAPPER=sccache, local dir.
    # Why: rust without sccache violates AG-CI (no Redis).
    # From: Issue #1683 | PR #1858
    local root="${BATS_TEST_TMPDIR}/root" bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${root}" "${bin}"
    _tool_stub "${bin}" cargo <<'STUB'
echo "cargo $1 wrapper=${RUSTC_WRAPPER:-none} dir=${SCCACHE_DIR:-none} args=$*"
STUB
    _stub_sccache "${bin}" 0
    unset SCCACHE_REDIS_URL
    CI_RUST_VALIDATION=true CI_REPO_ROOT="${root}" PATH="${bin}:${PATH}" run _ci_test_rust dns
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-INFO-CACHE-0002]"* ]]
    [ "$(grep -c 'wrapper=sccache dir=/var/tmp/sccache' <<<"${output}")" -eq 3 ]
    [ "$(grep -c -- "-p $(ci_service_field dns crate)" <<<"${output}")" -eq 3 ]
    CI_TMPDIR="${BATS_TEST_TMPDIR}/missing" SCCACHE_DIR=/var/tmp/sccache CI_RUST_VALIDATION=true \
        CI_REPO_ROOT="${root}" PATH="${bin}:${PATH}" run _ci_test_rust dns
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mktemp"* ]]
    [[ "${output}" != *"cargo fmt"* ]]
}

@test "sccache env selects Redis when a URL is provided" {
    # What: a Redis URL switches the backend to redis.
    # Why: shared cache on self-hosted; local otherwise.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"
    _stub_sccache "${bin}" 0
    SCCACHE_REDIS_URL=redis://cache.invalid:6379 PATH="${bin}:${PATH}" run bash -c \
        'source "$1"; _ci_sccache_env p; echo "r=${SCCACHE_REDIS}"; _ci_sccache_stop' _ "${CI_SH}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-INFO-CACHE-0001]"* ]]
    [[ "${output}" == *"r=redis://cache.invalid:6379"* ]]
}

@test "sccache outage degrades to local cache, then direct rustc" {
    # What: redis down -> local; local down -> direct rustc.
    # Why: §42: cache outage costs speed, never the build.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin" probe='source "$1"; _ci_sccache_env p
        echo "rc=$? w=${RUSTC_WRAPPER:-none} r=${SCCACHE_REDIS:-none}"
        d="${SCCACHE_SERVER_UDS%/*}"; [ -d "${d}" ] && echo "sock-dir=yes"
        _ci_sccache_stop; [ -e "${d}" ] && echo leftover; :'
    _stub_sccache "${bin}" redis-only
    SCCACHE_REDIS_URL=redis://cache.invalid:6379 PATH="${bin}:${PATH}" \
        run bash -c "${probe}" _ "${CI_SH}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-WARN-CACHE-0003"*"raw-redis-down"* ]]
    [[ "${output}" == *"rc=0 w=sccache r=none"* ]]
    [[ "${output}" != *"CI-WARN-CACHE-0004"* ]]
    [[ "${output}" == *"sock-dir=yes"* ]]
    [[ "${output}" != *"leftover"* ]]
    _stub_sccache "${bin}" 1
    SCCACHE_REDIS_URL=redis://cache.invalid:6379 PATH="${bin}:${PATH}" \
        run bash -c "${probe}" _ "${CI_SH}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-WARN-CACHE-0003"* ]]
    [[ "${output}" == *"CI-WARN-CACHE-0004"*"raw-server-down"* ]]
    [[ "${output}" == *"rc=0 w=none r=none"* ]]
    [[ "${output}" != *"leftover"* ]]
}

@test "sccache reap kills only servers under this run's socket dir" {
    # What: no real server; a renamed shell plays one.
    # Why: reap must kill only this run's socket dir.
    # From: Issue #1683 | PR #1858
    local fake="${BATS_TEST_TMPDIR}/fake/sccache" mine other
    mkdir -p "${fake%/*}" "${BATS_TEST_TMPDIR}/mine" "${BATS_TEST_TMPDIR}/other"
    cp "$(command -v bash)" "${fake}"
    SCCACHE_SERVER_UDS="${BATS_TEST_TMPDIR}/mine/s.sock" "${fake}" -c 'while :; do sleep 1; done' 3>&- &
    mine=$!
    SCCACHE_SERVER_UDS="${BATS_TEST_TMPDIR}/other/s.sock" "${fake}" -c 'while :; do sleep 1; done' 3>&- &
    other=$!
    sleep 1
    run _ci_sccache_reap "${BATS_TEST_TMPDIR}/mine"
    sleep 1
    local mine_alive=no other_alive=no
    kill -0 "${mine}" 2>/dev/null && mine_alive=yes
    kill -0 "${other}" 2>/dev/null && other_alive=yes
    kill "${other}"
    echo "status=${status} mine_alive=${mine_alive} other_alive=${other_alive} out=${output}"
    [ "${status}" -eq 0 ]
    [ "${mine_alive}" = no ]
    [ "${other_alive}" = yes ]
}

@test "test reports SKIP for an apk service; smoke is at the digest" {
    # What: apk has no test -> explicit SKIP+reason.
    # Why: legit skip; smoke runs in verify.
    # From: Issue #1613
    CI_SMOKE_CMD="$(_stub sm 'echo SMOKE-CALLED')" \
        run bash "${CI_SH}" test proxy
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=SKIP"* ]]
    [[ "${output}" != *"SMOKE-CALLED"* ]]
}

@test "verify smoke-tests a product image at its digest" {
    # What: matching readback -> SOT smoke at the digest.
    # Why: §25 SERVICE_TESTED; a smoke failure fails verify.
    # From: Issue #1613
    _build_fixture
    CI_READBACK_CMD="$(_stub rb 'echo sha256:dead')" \
    CI_SMOKE_CMD="$(_stub sm 'echo "service=$1 smoke=ok image=${CI_SERVICE_IMAGE}"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify svc-a sha256:dead os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"smoke=ok image="*"svc-a@sha256:dead"* ]]
    CI_READBACK_CMD="$(_stub rb 'echo sha256:dead')" \
    CI_SMOKE_CMD="$(_stub sm 'exit 1')" \
    GHCR_USERNAME=u GHCR_TOKEN=t GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify svc-a sha256:dead os/p1
    [ "${status}" -ne 0 ]
}

@test "verify of a rust service runs its ldd smoke in the image" {
    # What: verify of a rust service reaches the ldd smoke.
    # Why: the SOT ldd item must run, not only exist.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/docker.log"
    _build_fixture
    printf '%s\n' '  svc-r:' '    context: svc' '    build_type: rust' '    final_base: base-x' \
        '    smoke:' '      - ldd /usr/local/bin/svc-r' > "${BATS_TEST_TMPDIR}/svc-r.yml"
    awk -v add="${BATS_TEST_TMPDIR}/svc-r.yml" \
        '/^build_toolchain:/ { while ((getline l < add) > 0) print l } { print }' \
        "${CI_MANIFEST}" > "${CI_MANIFEST}.new" && mv "${CI_MANIFEST}.new" "${CI_MANIFEST}"
    _tool_stub "${bin}" docker <<STUB
echo "docker \$*" >> "${log}"
[ -z "\${LDD_FAIL:-}" ] || { echo "Error loading shared library libx.so" >&2; exit 127; }
STUB
    CI_READBACK_CMD="$(_stub rb 'echo sha256:dead')" PATH="${bin}:${PATH}" \
    GHCR_USERNAME=u GHCR_TOKEN=t GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify svc-r sha256:dead os/p1
    echo "log=$(cat "${log}")"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"service=svc-r smoke=ok checks=1"* ]]
    [[ "$(cat "${log}")" == *"--entrypoint sh "*"svc-r@sha256:dead -c ldd /usr/local/bin/svc-r"* ]]
    LDD_FAIL=1 CI_READBACK_CMD="$(_stub rb 'echo sha256:dead')" PATH="${bin}:${PATH}" \
    GHCR_USERNAME=u GHCR_TOKEN=t GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify svc-r sha256:dead os/p1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0008"*"libx.so"* ]]
}

@test "test build-tools fails closed without a toolchain image" {
    # What: The smoke needs the candidate image ref.
    # Why: No image means nothing to smoke; fail closed.
    # From: Issue #1683
    run bash "${CI_SH}" test build-tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-TEST-0006"* ]]
}

@test "build-tools smoke lists come from the SOT; empty fails closed" {
    # What: smoke_tools/smoke_runs read verbatim from SOT.
    # Why: one smoke owner (AG-VAL-017); blank never passes.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - t1\n    smoke_runs:\n      - t1 --v | x\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_build_tools_smoke smoke_tools
    [ "${output}" = t1 ]
    CI_MANIFEST="${m}" run _ci_build_tools_smoke smoke_runs
    [ "${output}" = "t1 --v | x" ]
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - t1\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_build_tools_smoke smoke_runs
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0013"* ]]
}

@test "toolchain smoke fails on a missing tool or a failing run" {
    # What: the real smoke script runs via a docker shim.
    # Why: tools via args and runs via stdin both gate.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml" tool run
    docker() { shift 4; "$@"; }
    for tool in sh no-such-tool-x; do
        for run in true false; do
            printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - bash\n      - %s\n    smoke_runs:\n      - bash --version\n      - %s\n' \
                "${tool}" "${run}" > "${m}"
            CI_MANIFEST="${m}" CI_TOOLCHAIN_IMAGE=img run _ci_test_toolchain build-tools
            if [ "${tool}" = sh ] && [ "${run}" = true ]; then
                [ "${status}" -eq 0 ]; [[ "${output}" == *"tested=ok"* ]]
            else
                [ "${status}" -eq 1 ]
                [[ "${output}" == *"missing no-such-tool-x"* || "${output}" == *"failed: false"* ]]
            fi
        done
    done
}

@test "test build-tools reports ok via the wired smoke backend" {
    # What: A green smoke yields tested=ok for build-tools.
    # Why: The wired toolchain smoke is the real test.
    # From: Issue #1683
    CI_TOOLCHAIN_TEST_CMD="$(_stub tc 'echo "service=build-tools tested=ok"')" \
        run bash "${CI_SH}" test build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "verify smoke-tests a toolchain image after a matching readback" {
    # What: A toolchain verify runs the SOT tool smoke.
    # Why: §25 requires accelerator tools at digest.
    # From: Issue #1683
    _build_fixture
    CI_READBACK_CMD="$(_stub rb 'echo sha256:dead')" \
    CI_TOOLCHAIN_TEST_CMD="$(_stub tc 'echo "service=$1 tested=ok"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify tool-t sha256:dead os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:dead"* ]]
}

@test "test runs the real cargo pipeline for a rust fixture (no injection)" {
    # What: Default rust path runs real cargo pipeline.
    # Why: AG-VAL-008 must run for real, not via injection.
    # From: Issue #1683
    local root="${BATS_TEST_TMPDIR}/repo-ok"
    mkdir -p "${root}/crate/src"
    cat > "${root}/crate/Cargo.toml" <<'TOML'
[package]
name = "ci-fixture-ok"
version = "0.1.0"
edition = "2021"
TOML
    cat > "${root}/crate/src/main.rs" <<'RS'
fn main() {
    println!("ci fixture ok");
}

#[test]
fn real_cargo_test_runs() {
    // What: Sanity check the real path executes cargo test.
    // Why: Proves _ci_test_rust runs real cargo, not a stub.
    assert_eq!(1 + 1, 2);
}
RS
    printf '[workspace]\nmembers = ["crate"]\nresolver = "2"\n' > "${root}/Cargo.toml"
    ( cd "${root}" && cargo generate-lockfile --offline -q )
    local m="${BATS_TEST_TMPDIR}/manifest-ok.yml"
    printf 'services:\n  fixture-ok:\n    context: crate\n    crate: ci-fixture-ok\n    build_type: rust\n' > "${m}"
    CI_RUST_VALIDATION=true CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" run bash "${CI_SH}" test fixture-ok
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"tested=ok"* ]]
}

@test "test propagates a real cargo clippy failure without injection" {
    # What: Real clippy violations fail, unmocked.
    # Why: AG-INT-002: real failures must never hide.
    # From: Issue #1683
    local root="${BATS_TEST_TMPDIR}/repo-fail"
    mkdir -p "${root}/crate/src"
    cat > "${root}/crate/Cargo.toml" <<'TOML'
[package]
name = "ci-fixture-fail"
version = "0.1.0"
edition = "2021"
TOML
    cat > "${root}/crate/src/main.rs" <<'RS'
fn main() {
    let flag = true;
    if flag == true {
        println!("{flag}");
    }
}
RS
    printf '[workspace]\nmembers = ["crate"]\nresolver = "2"\n' > "${root}/Cargo.toml"
    ( cd "${root}" && cargo generate-lockfile --offline -q )
    local m="${BATS_TEST_TMPDIR}/manifest-fail.yml"
    printf 'services:\n  fixture-fail:\n    context: crate\n    crate: ci-fixture-fail\n    build_type: rust\n' > "${m}"
    CI_RUST_VALIDATION=true CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" run bash "${CI_SH}" test fixture-fail
    [ "${status}" -eq 2 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"CI-ERROR-TEST-0003"* ]]
    [[ "${output}" == *"equality checks against true"* ]] || { echo "${output}"; return 1; }
}

@test "ci.sh rejects a /tmp (tmpfs) temp root for any command" {
    # What: tmpfs /tmp risks OOM; one guard for all.
    # Why: All CI staging is /var/tmp (maintainer rule).
    # From: Issue #1683 | PR #1858
    CI_TMPDIR=/tmp CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0006"* ]]
    CI_TMPDIR=/tmp run bash "${CI_SH}" check comment-length
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0006"* ]]
}

@test "proxy is exported on self-hosted only and passed through" {
    # What: self-hosted+var -> env + passthrough names.
    # Why: AG-CI-009; hosted runners have no LAN route.
    # From: Issue #1683 | PR #1858
    run bash -c 'source "$1"; RUNNER_ENVIRONMENT=github-hosted PROJECT_SELFHOSTED_PROXY_HTTP=http://p:3128 _ci_proxy_init; _ci_proxy_names | wc -l' _ "${CI_SH}"
    [ "${lines[-1]}" -eq 0 ]
    run bash -c 'source "$1"; unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy; RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=http://p:3128 PROJECT_SELFHOSTED_PROXY_EXCLUSION=registry.example.test _ci_proxy_init; echo "h=${https_proxy} n=${NO_PROXY}"; _ci_proxy_names | tr "\n" " "' _ "${CI_SH}"
    [[ "${output}" == *"[CI-INFO-CORE-0007]"* ]]
    [[ "${output}" == *"h=http://p:3128 n=registry.example.test"* ]]
    [[ "${output}" == *"HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"* ]]
}

@test "proxy CA becomes a job-local bundle with the system CAs" {
    # What: bundle = system CAs + proxy CA, for cargo/curl.
    # Why: TLS proxy on self-hosted; system trust stays.
    # From: Issue #1683 | PR #1858
    local sys="${BATS_TEST_TMPDIR}/sys.pem"
    printf 'SYSTEM-CA\n' > "${sys}"
    run bash -c 'source "$1"; RUNNER_ENVIRONMENT=self-hosted PROJECT_SELFHOSTED_PROXY_HTTP=http://p:3128 PROJECT_SELFHOSTED_PROXY_CA=PROXY-CA CI_SYSTEM_CA_BUNDLE="$2" _ci_proxy_init; cat "${CARGO_HTTP_CAINFO}"; [ "${CURL_CA_BUNDLE}" = "${CARGO_HTTP_CAINFO}" ] && echo same; stat -c %a "${CARGO_HTTP_CAINFO}"; rm -f "${CARGO_HTTP_CAINFO}"' _ "${CI_SH}" "${sys}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SYSTEM-CA"*"PROXY-CA"* ]]
    [[ "${output}" == *"same"* ]]
    [[ "${output}" == *"600"* ]]
}

@test "ci.sh creates the /var/tmp temp root and exports TMPDIR" {
    # What: a missing /var/tmp subdir is made (mkdir -p).
    # Why: bare mktemp in tools must land on disk.
    # From: Issue #1683 | PR #1858
    local d="/var/tmp/ci-bats-root.$$/nested"
    CI_TMPDIR="${d}" run bash -c 'source "$1"; _ci_tmp_init; echo "t=${TMPDIR}"' _ "${CI_SH}"
    [ "${status}" -eq 0 ]
    [ -d "${d}" ]
    [[ "${output}" == *"t=${d}"* ]]
    rm -rf "/var/tmp/ci-bats-root.$$"
}

@test "scan is clean on /var/tmp with auth and a passing backend" {
    # What: authed + /var/tmp + green scan -> clean.
    # Why: The one success path for scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=clean"* ]]
    [[ "${output}" == *"tmpdir=/var/tmp"* ]]
}

@test "scan fails closed without GHCR auth" {
    # What: Scan pulls the image -> authenticated.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "scan fails on a finding backend" {
    # What: A backend exit 1 is a genuine finding.
    # Why: HIGH/CRITICAL findings fail the scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 1')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0005"* ]]
}

@test "scan escalates a DB-unavailable backend, not a finding" {
    # What: A backend exit 3 is a DB outage, not a finding.
    # Why: An outage must escalate, never reject the image.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 3')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0006"* ]]
}

# =========================================================
# CACHE FALLBACK
# =========================================================

@test "cache fallback: an unwired CAS lookup always misses, never a false hit" {
    # What: Unwired CAS lookup misses, not false hit.
    # Why: Fallback defaults to miss, not silent hit.
    # From: Issue #1683
    run _ci_cas_lookup "deadbeef"
    [ "${status}" -ne 0 ]
}

@test "cache fallback: a CAS hit skips the build backend entirely" {
    # What: A CAS hit must never invoke the build backend.
    # Why: Reuse means the compile step is truly skipped.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 0')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED; exit 1')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-binary-cas"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
}

@test "cache fallback: a crashing CAS backend still falls back to a real build" {
    # What: Any nonzero CAS exit falls back to build.
    # Why: Broken CAS backend must not block pipeline.
    # From: Issue #1683
    local marker="${BATS_TEST_TMPDIR}/cas-invoked-crash"
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas "touch '${marker}'; echo cas-backend-noise >&2; exit 137")" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=built"* ]]
    # What: Marker proves CAS backend ran.
    # Why: Skipped stub makes fallback claim empty.
    # From: Issue #1683
    [ -f "${marker}" ]
}

@test "cache fallback: an apk (non-rust) service never consults the CAS" {
    # What: build_type=apk must not call CAS.
    # Why: CAS is rust-binary reuse (§7); apk has none.
    # From: Issue #1683
    local marker="${BATS_TEST_TMPDIR}/cas-invoked-apk"
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas "touch '${marker}'; exit 0")" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build proxy
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=built"* ]]
    # What: Absent marker proves CAS never invoked.
    # Why: No-op stub passes with no skip proof.
    # From: Issue #1683
    [ ! -f "${marker}" ]
}

# =========================================================
# REGISTRY / PUBLISH / READBACK
# =========================================================

@test "registry login maps each case; token only via stdin" {
    # What: login per row; token via stdin, never in argv.
    # Why: a secret in argv or a log leaks to every reader.
    # From: Issue #1683 | PR #1858
    local log="${BATS_TEST_TMPDIR}/login" name user tok cmd dmode rc want w hay
    local -a ws
    _ci_registry() { echo registry.example.test; }
    docker() {
        echo "argv: $*" >> "${log}"
        echo "stdin: $(cat)" >> "${log}"
        [ "${dmode}" = ok ] || { echo "Error response from daemon: unauthorized" >&2; return 1; }
    }
    while IFS='|' read -r name user tok cmd dmode rc want; do
        : > "${log}"
        unset CI_GHCR_LOGIN_CMD
        case "${cmd}" in
            ok) CI_GHCR_LOGIN_CMD="$(_stub loginok 'exit 0')" ;;
            fail) CI_GHCR_LOGIN_CMD="$(_stub loginbad 'echo denied by stub; exit 1')" ;;
        esac
        export CI_GHCR_LOGIN_CMD GHCR_USERNAME="${user}" GHCR_TOKEN="${tok}"
        [ "${cmd}" != - ] || unset CI_GHCR_LOGIN_CMD
        run _ci_require_ghcr_auth
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        hay="${output}"$'\n'"$(cat "${log}")"
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] || [[ "${hay}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${hay}"; return 1; }
        done
        [ -z "${tok}" ] || [[ "${output}" != *"${tok}"* ]] || { echo "${name}: token in output"; return 1; }
        [ -z "${tok}" ] || ! grep -q "^argv: .*${tok}" "${log}" || { echo "${name}: token in argv"; cat "${log}"; return 1; }
    done <<'CASES'
no-creds|||-|ok|2|CI-ERROR-BUILD-0002
cmd-ok|u1|s3cr3t-tok|ok|ok|0|-
cmd-fail|u1|s3cr3t-tok|fail|ok|2|CI-ERROR-BUILD-0015;registry="<CI_GHCR_LOGIN_CMD>";denied by stub
docker-ok|u1|s3cr3t-tok|-|ok|0|argv: login registry.example.test -u u1 --password-stdin;stdin: s3cr3t-tok
docker-fail|u1|s3cr3t-tok|-|fail|2|CI-ERROR-BUILD-0015;registry="registry.example.test";unauthorized
CASES
}

@test "publish fails closed without GHCR credentials" {
    # What: Publish is an authenticated GHCR action.
    # Why: Never push anonymously (rate-limit).
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:abc')" run bash "${CI_SH}" publish ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "publish returns the backend digest when authed" {
    # What: A successful push reports its digest.
    # Why: The digest is the ref the next phase verifies.
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:deadbeef')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" publish ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"published=sha256:deadbeef"* ]]
}

@test "ship publishes and verifies only a built image" {
    # What: built=publish+verify; reuse=skip.
    # Why: one chain owner; reuse has no image.
    # From: Issue #1683 | PR #1858
    ci_cmd_build() { echo "service=$1 platform=$2 result=built identity=i"; }
    ci_cmd_publish() { echo "service=$1 platform=$2 published=sha256:pub identity=i"; }
    ci_cmd_verify() { echo "VERIFY $1 $2 $3"; }
    _ci_bake_check() { echo "BAKE $1"; }
    export GITHUB_REPOSITORY=owner/fixture-repo
    run ci_cmd_ship svc-a os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BAKE "*"/svc-a:sha-i-p1"*"published=sha256:pub"*"VERIFY svc-a sha256:pub os/p1"* ]]
    _ci_bake_check() { echo "BAKE-FAIL"; return 2; }
    ci_cmd_publish() { echo PUBLISH-CALLED; }
    run ci_cmd_ship svc-a os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BAKE-FAIL"* ]] && [[ "${output}" != *"PUBLISH-CALLED"* ]]
    unset GITHUB_REPOSITORY
    _ci_bake_check() { echo "BAKE-CALLED"; }
    run ci_cmd_ship svc-a os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SHIP-0003"*"GITHUB_REPOSITORY"* ]]
    [[ "${output}" != *"BAKE-CALLED"* ]] && [[ "${output}" != *"PUBLISH-CALLED"* ]]
    export GITHUB_REPOSITORY=owner/fixture-repo
    ci_cmd_publish() { echo "service=$1 platform=$2 published=sha256:pub identity=i"; }
    _ci_bake_check() { echo "BAKE $1"; }
    ci_cmd_build() { echo "service=$1 platform=$2 result=reuse-accepted identity=i"; }
    ci_cmd_publish() { echo PUBLISH-CALLED; }
    run ci_cmd_ship svc-a os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"PUBLISH-CALLED"* ]]
    ci_cmd_build() { echo "service=$1 platform=$2 result=built identity=i"; }
    ci_cmd_publish() { echo "service=$1 published= identity=i"; }
    run ci_cmd_ship svc-a os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SHIP-0002"* ]]
}

@test "verify passes when the readback digest matches" {
    # What: readback == expected -> verified.
    # Why: Confirms the accepted artifact is the real one.
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:match')" GHCR_USERNAME=u GHCR_TOKEN=t \
    CI_SMOKE_CMD="$(_stub sm 'echo "service=$1 smoke=ok"')" GITHUB_REPOSITORY=owner/fixture-repo \
        run bash "${CI_SH}" verify ui sha256:match
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:match"* ]]
}

@test "verify fails with MISMATCH and shows raw readback (BUILT != ACCEPTED)" {
    # What: readback != expected -> hard fail + raw.
    # Why: A mismatch must never be accepted (§7).
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:other')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" verify ui sha256:expected
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0005"* ]]
    [[ "${output}" == *"MISMATCH"* ]]
    [[ "${output}" == *"readback=sha256:other"* ]]
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
# What: Named digest constants built on _test_digest.
# Why: Idempotency compares assembled vs existing.
# From: Issue #1683
_asm_a() { _test_digest a; }
_asm_b() { _test_digest b; }
_asm_idx() { _test_digest d; }
_asm_digest_stub() {
    _stub dg "echo $(_asm_a)"
}
# What: index stub listing every SOT platform of svc.
# Why: platform set comes from the SOT, never the test.
# From: Issue #1683
_asm_index_stub() {
    local p line
    line="$(_asm_idx)"
    for p in $(_ci_platforms "$1"); do line="${line} ${p}=$(_asm_a)"; done
    [ "${2:-}" = divergent ] && line="${line% *} ${p}=$(_asm_b)"
    _stub idx "echo \"${line}\""
}

@test "assemble refuses a non-ACCEPTED platform and does not rebuild" {
    # What: UNKNOWN blocks assembly, never rebuilds success.
    # Why: A missing platform must not rebuild (docs §45).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0002"* ]]
    [[ "${output}" != *"result=assembled"* ]]
}

@test "assemble refuses PRODUCED_UNVERIFIED (fail-safe stays DISACK)" {
    # What: Unverified is not ACCEPTED, so no assembly.
    # Why: Fail-safe: unaccepted stays a GC candidate.
    # From: Issue #1683
    STUB_STATE=PRODUCED_UNVERIFIED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0002"* ]]
}

@test "assemble creates an index when every platform is ACCEPTED" {
    # What: All ACCEPTED + digests + authed -> one index.
    # Why: The index is the accepted platform set.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_stub noidx 'exit 1')" \
    CI_ASSEMBLE_CMD="$(_stub asm "echo $(_asm_idx)")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=assembled"* ]]
    [[ "${output}" == *"assembled=$(_asm_idx)"* ]]
    [[ "${output}" == *"platforms=$(_ci_platforms ui | grep -c .)"* ]]
}

@test "assemble reuses an identical existing index (idempotent)" {
    # What: A retry reuses the same index.
    # Why: Same end state on retry; no backend.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_asm_index_stub ui)" \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-index"* ]]
    [[ "${output}" == *"assembled=$(_asm_idx)"* ]]
}

@test "assemble refuses to overwrite a divergent existing index" {
    # What: An index with different digests fails closed.
    # Why: Never silently overwrite an accepted artifact.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_asm_index_stub ui divergent)" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0004"* ]]
}

@test "assemble fails closed without GHCR auth before creating" {
    # What: Creating an index is authenticated.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_stub noidx 'exit 1')" \
    CI_ASSEMBLE_CMD="$(_stub asm "echo $(_asm_idx)")" \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "assemble fails when an ACCEPTED platform has no digest" {
    # What: ACCEPTED but no digest is an inconsistency.
    # Why: Fail closed, never assemble a partial index.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0003"* ]]
}

@test "assemble fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" assemble
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0001"* ]]
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
    _stub cand "for s in ${svcs}; do echo \"\$s=$1\"; done"
}
_promote_lock() { _stub lock 'echo "LOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }
_promote_unlock() { _stub unlock 'echo "UNLOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }

@test "promote fails closed when no channel is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" promote
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0001"* ]]
}

@test "promote rejects a channel not in the mutable SOT set" {
    # What: Only known mutable channels may be moved.
    # Why: promote moves refs only; no invented list.
    # From: Issue #1683
    run bash "${CI_SH}" promote bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0002"* ]]
}

@test "promote refuses an incomplete stack (no promote at 8/9)" {
    # What: A missing service blocks the promotion.
    # Why: Promotion is stack-atomic (docs section 50).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

@test "promote blocks when the stack is not validated" {
    # What: Stack validation is a precondition.
    # Why: Fail-closed without validate (docs section 50).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0005"* ]]
}

@test "promote fails closed without GHCR auth" {
    # What: Moving refs is an authenticated action.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "promote moves refs, confirms readback, releases lock" {
    # What: Fresh promote: lock, move, readback, unlock.
    # Why: The one success path (docs section 51/53).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'touch "${BATS_TEST_TMPDIR}/moved.$1"')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "[ -f \"\${BATS_TEST_TMPDIR}/moved.\$1\" ] && echo ${dig} || true")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=promoted"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK nightly"* ]]
}

@test "promote is idempotent: all refs current, no lock taken" {
    # What: A re-run reuses the state, takes no lock.
    # Why: Same end state on retry (docs section 26.4).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${dig}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=already-promoted"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/lock.log" ]
}

@test "promote fails on readback MISMATCH but frees the lock" {
    # What: A mismatch fails closed, never leaks the lock.
    # Why: A held lock blocks all future promotions.
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    local other; other="$(_test_digest b)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${other}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0009"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK nightly"* ]]
}

# =========================================================
# RELEASE
# =========================================================

@test "release fails closed when validation is not fresh" {
    # What: A stale/failed verdict blocks the release.
    # Why: AG-REL-011 requires still-valid validation.
    # From: Issue #1683
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 1')" \
        run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0001"* ]]
}

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

@test "release verifies freshness then promotes latest" {
    # What: Fresh verdict promotes the exact candidate.
    # Why: latest promote is the release success path.
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'touch "${BATS_TEST_TMPDIR}/moved.$1"')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "[ -f \"\${BATS_TEST_TMPDIR}/moved.\$1\" ] && echo ${dig} || true")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"channel=latest"* ]]
    [[ "${output}" == *"result=promoted"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK latest"* ]]
}

@test "release is idempotent when latest is already current" {
    # What: A re-run promotes nothing, takes no lock.
    # Why: Same end state on retry (docs section 26.4).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${dig}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=already-promoted"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/lock.log" ]
}

@test "release runs the promote gates, not a second model" {
    # What: Fresh verdict still needs a complete stack.
    # Why: One acceptance model; promote gates apply.
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

@test "valid-promote-target accepts channels and release tags only" {
    # What: Channels/vX.Y.Z(-rc.N) are valid targets.
    # Why: Promote writes same ref for both.
    # From: Issue #1683
    run _ci_valid_promote_target latest;       [ "${status}" -eq 0 ]
    run _ci_valid_promote_target nightly;      [ "${status}" -eq 0 ]
    run _ci_valid_promote_target v1.2.3;       [ "${status}" -eq 0 ]
    run _ci_valid_promote_target v1.2.3-rc.4;  [ "${status}" -eq 0 ]
    run _ci_valid_promote_target sha-deadbeef; [ "${status}" -ne 0 ]
    run _ci_valid_promote_target bogus;        [ "${status}" -ne 0 ]
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

@test "promote-targets-for-ref maps each ref to its channel set" {
    # What: neutral SOT: ch-a on refs/heads/b-a + tags.
    # Why: the mapping is SOT data, never a test table.
    # From: Issue #1683
    CI_MANIFEST="${BATS_TEST_TMPDIR}/ch.yml"
    printf '%s\n' 'release:' '  channels:' '    ch-b:' '      mutable: true' \
        '    ch-a:' '      mutable: true' '      ref: refs/heads/b-a' \
        '      release_tags: true' '  default_channel: ch-b' > "${CI_MANIFEST}"
    GITHUB_REF=refs/heads/b-a CI_PROMOTE_REQUESTED_CHANNEL='' run _ci_promote_targets_for_ref
    [ "${output}" = ch-a ]
    GITHUB_REF=refs/heads/b-other CI_PROMOTE_REQUESTED_CHANNEL='' run _ci_promote_targets_for_ref
    [ -z "${output}" ]
    GITHUB_REF=refs/tags/v1.2.3 CI_PROMOTE_REQUESTED_CHANNEL='' run _ci_promote_targets_for_ref
    [ "${lines[0]}" = v1.2.3 ]; [ "${lines[1]}" = ch-a ]; [ "${#lines[@]}" -eq 2 ]
    GITHUB_REF=refs/tags/v1.2.3-rc.4 CI_PROMOTE_REQUESTED_CHANNEL='' run _ci_promote_targets_for_ref
    [ "${output}" = v1.2.3-rc.4 ]
    GITHUB_REF=refs/heads/b-a CI_PROMOTE_REQUESTED_CHANNEL=ch-b run _ci_promote_targets_for_ref
    [ "${lines[0]}" = ch-a ]; [ "${lines[1]}" = ch-b ]; [ "${#lines[@]}" -eq 2 ]
    GITHUB_REF=refs/heads/b-a CI_PROMOTE_REQUESTED_CHANNEL=ch-a run _ci_promote_targets_for_ref
    [ "${output}" = ch-a ]
    run _ci_release_ref
    [ "${output}" = refs/heads/b-a ]
    printf '%s\n' 'release:' '  channels:' '    ch-b:' '      mutable: true' > "${CI_MANIFEST}"
    run _ci_release_ref
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0018"* ]]
}

@test "promote-ref promotes every derived target, tip-guarded" {
    # What: Promotes derived targets, skips superseded.
    # Why: Single entry ensures determinism (§4).
    # From: Issue #1683
    local calls="${BATS_TEST_TMPDIR}/promote-calls"
    export PROMOTE_CALLS="${calls}"
    local prom rel ch; prom="$(_stub prom 'echo "PROMOTE $1" >> "${PROMOTE_CALLS}"')"
    rel="$(_ci_release_ref)"
    ch="$(_ci_channels_where release_tags true)"
    : > "${calls}"
    CI_PROMOTE_ONE_CMD="${prom}" GITHUB_REF=refs/tags/v1.2.3 CI_PROMOTE_REQUESTED_CHANNEL='' run ci_cmd_promote_ref
    [ "${status}" -eq 0 ]
    [ "$(cat "${calls}")" = "PROMOTE v1.2.3
PROMOTE ${ch}" ]
    : > "${calls}"
    local tipstub; tipstub="$(_stub tip 'echo othersha')"
    CI_PROMOTE_ONE_CMD="${prom}" GITHUB_REF="${rel}" GITHUB_SHA=mysha CI_PROMOTE_REQUESTED_CHANNEL='' CI_PROMOTE_TIP_CMD="${tipstub}" run ci_cmd_promote_ref
    [ "${status}" -eq 0 ]; [[ "${output}" == *"superseded"* ]]; [ ! -s "${calls}" ]
    : > "${calls}"
    local tipok; tipok="$(_stub tipok 'echo mysha')"
    CI_PROMOTE_ONE_CMD="${prom}" GITHUB_REF="${rel}" GITHUB_SHA=mysha CI_PROMOTE_REQUESTED_CHANNEL='' CI_PROMOTE_TIP_CMD="${tipok}" run ci_cmd_promote_ref
    [ "${status}" -eq 0 ]; [ "$(cat "${calls}")" = "PROMOTE ${ch}" ]
    : > "${calls}"
    CI_PROMOTE_ONE_CMD="${prom}" GITHUB_REF=refs/heads/no-channel-ref CI_PROMOTE_REQUESTED_CHANNEL='' run ci_cmd_promote_ref
    [ "${status}" -eq 0 ]; [[ "${output}" == *"no-targets"* ]]; [ ! -s "${calls}" ]
}

# What: Build a gh stub that logs and mocks release view.
# Why: publish/sbom/vex assert gh calls without a network.
# From: Issue #1683
_release_gh_stub() {
    _tool_stub "${BATS_TEST_TMPDIR}" relgh <<'EOF'
echo "$*" >> "${GH_CALLS}"
if [ "$1 $2" = "release view" ]; then
    if [ -n "${STUB_VIEW_ERR:-}" ]; then
        echo "${STUB_VIEW_ERR}" >&2
        exit 1
    fi
    if [ -n "${STUB_VIEW:-}" ]; then
        printf '%s' "${STUB_VIEW}"
        exit 0
    fi
    echo "release not found" >&2
    exit 1
fi
exit 0
EOF
    printf '%s' "${BATS_TEST_TMPDIR}/relgh"
}

@test "release-prerelease maps tag shape to the prerelease flag" {
    # What: vX.Y.Z is final, -rc.N is prerelease, else fail.
    # Why: Publishes with correct prerelease state.
    # From: Issue #1683
    run _ci_release_prerelease v1.2.3
    [ "${status}" -eq 0 ]; [ "${output}" = false ]
    run _ci_release_prerelease v1.2.3-rc.4
    [ "${status}" -eq 0 ]; [ "${output}" = true ]
    run _ci_release_prerelease sha-deadbeef
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0002"* ]]
}

@test "release-publish creates a new release with prerelease for rc tags" {
    # What: A missing release is created, notes attached.
    # Why: first publish of a tag; rc sets --prerelease.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef CI_TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { echo "sha256:aaa"; }
    ci_build_targets() { echo proxy; }
    : > "${calls}"
    STUB_VIEW='' CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_publish v1.2.3-rc.4
    [ "${status}" -eq 0 ]
    grep -q 'release create v1.2.3-rc.4' "${calls}"
    grep -q -- '--prerelease' "${calls}"
    [[ "${output}" == *"release=published"* ]]
    # What: any other view error stops; nothing created.
    # Why: an auth/network error is UNKNOWN, not "absent".
    # From: Issue #1683 | PR #1858
    : > "${calls}"
    STUB_VIEW_ERR='HTTP 401: Bad credentials' CI_RELEASE_GH_CMD="${gh}" \
        run ci_cmd_release_publish v1.2.3-rc.4
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0020"*"Bad credentials"* ]]
    if grep -q 'release create' "${calls}"; then
        return 1
    fi
}

@test "release-publish replaces the marker block on an existing release" {
    # What: Keep notes prefix/suffix, block replaced.
    # Why: Idempotent; hand-written notes preserved.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef CI_TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { echo "sha256:aaa"; }
    ci_build_targets() { echo svc-a; }
    local start='<!-- r-image-tags:start -->' end='<!-- r-image-tags:end -->'
    : > "${calls}"
    STUB_VIEW="$(jq -nc --arg b "keep-me
${start}
old
${end}
tail" '{body:$b, isPrerelease:false}')" \
        CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_publish v1.2.3
    [ "${status}" -eq 0 ]
    grep -q 'release edit v1.2.3' "${calls}"
    run _ci_release_marker start
    [ "${output}" = "${start}" ]
}

@test "release-publish fails closed on a prerelease-state mismatch" {
    # What: A final tag over a prerelease release must fail.
    # Why: release state is policy, never silently flipped.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r GITHUB_SHA=deadbeef CI_TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { echo "sha256:aaa"; }
    ci_build_targets() { echo proxy; }
    STUB_VIEW='{"body":"x","isPrerelease":true}' \
        CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_publish v1.2.3
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0005"* ]]
}

@test "release-publish requires a tag argument" {
    # What: No tag is a hard fail before any gh call.
    # Why: fail-closed; never publish an unnamed release.
    # From: Issue #1683
    run ci_cmd_release_publish
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0003"* ]]
}

@test "release-asset-put uploads with clobber and rejects an empty file" {
    # What: One asset writer; --clobber replaces prior.
    # Why: SBOM and VEX share it; empty file is a hard fail.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r
    local f="${BATS_TEST_TMPDIR}/proxy.cdx.json"; echo '{}' > "${f}"
    : > "${calls}"
    CI_RELEASE_GH_CMD="${gh}" run _ci_release_asset_put v1.2.3 "${f}"
    [ "${status}" -eq 0 ]
    grep -q -- '--clobber' "${calls}"
    run _ci_release_asset_put v1.2.3 "${BATS_TEST_TMPDIR}/missing"
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0004"* ]]
}

@test "release-sbom generates a cyclonedx asset and uploads it" {
    # What: A per-image SBOM is produced then attached.
    # Why: released provenance asset, one owner uploads it.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r CI_TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { echo "sha256:aaa"; }
    local sbom; sbom="$(_stub sbom 'printf "{}" > "$3"')"
    : > "${calls}"
    CI_SBOM_CMD="${sbom}" CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_sbom proxy v1.2.3
    [ "${status}" -eq 0 ]
    grep -q 'release upload v1.2.3' "${calls}"
    grep -q 'proxy.cdx.json' "${calls}"
    run ci_cmd_release_sbom proxy
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0008"* ]]
}


@test "release-sbom-stack builds an SBOM for every published service" {
    # What: One SBOM per first-party image.
    # Why: No matrix; third-party skipped.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r CI_TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_require_ghcr_auth() { return 0; }
    _ci_registry_digest() { echo "sha256:aaa"; }
    ci_build_targets() { printf 'proxy\ndns\n'; }
    local sbom; sbom="$(_stub sbom 'printf "{}" > "$3"')"
    : > "${calls}"
    CI_SBOM_CMD="${sbom}" CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_sbom_stack v1.2.3
    [ "${status}" -eq 0 ]
    grep -q 'proxy.cdx.json' "${calls}"
    grep -q 'dns.cdx.json' "${calls}"
    run ci_cmd_release_sbom_stack
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0013"* ]]
}

@test "release-vex generates the openvex document and attaches it" {
    # What: One VEX per release, built from the trivyignore.
    # Why: Reuses SOT vex generator; fails on missing.
    # From: Issue #1683
    local gh calls="${BATS_TEST_TMPDIR}/gh-calls"; gh="$(_release_gh_stub)"
    export GH_CALLS="${calls}" GITHUB_REPOSITORY=o/r CI_TMPDIR="${BATS_TEST_TMPDIR}" CI_REPO_ROOT="${BATS_TEST_TMPDIR}"
    printf '  - id: CVE-0\n' > "${BATS_TEST_TMPDIR}/.trivyignore.yaml"
    local vex; vex="$(_stub vex 'printf "{\"statements\":[]}"')"
    : > "${calls}"
    CI_VEX_GENERATE_CMD="${vex}" CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_vex v1.2.3
    [ "${status}" -eq 0 ]
    grep -q 'release upload v1.2.3' "${calls}"
    grep -q 'vex.openvex.json' "${calls}"
    rm -f "${BATS_TEST_TMPDIR}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="${vex}" CI_RELEASE_GH_CMD="${gh}" run ci_cmd_release_vex v1.2.3
    [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0011"* ]]
}

@test "next-patch-tag bumps Z only on a plain vX.Y.Z tag" {
    # What: patch bump only; rc/minor tags are rejected.
    # Why: Bumps patch only; minor and rc rejected.
    # From: Issue #1683
    run _ci_next_patch_tag v0.2.9;      [ "${status}" -eq 0 ]; [ "${output}" = v0.2.10 ]
    run _ci_next_patch_tag v1.0.0;      [ "${status}" -eq 0 ]; [ "${output}" = v1.0.1 ]
    run _ci_next_patch_tag v0.2.0-rc.1; [ "${status}" -ne 0 ]; [[ "${output}" == *"CI-ERROR-RELEASE-0015"* ]]
}

@test "release-stack-changed compares published digests to the base tag" {
    # What: Image diff from base triggers release.
    # Why: Content identity determines release need.
    # From: Issue #1683
    export GITHUB_SHA=mysha
    ci_build_targets() { printf 'proxy\n'; }
    _ci_registry() { echo registry.example.test; }
    _ci_repo() { echo o/r; }
    _ci_registry_digest() { echo sha256:same; }
    _ci_registry_probe() { echo sha256:same; }
    run _ci_release_stack_changed v0.2.0
    [ "${status}" -eq 1 ]
    _ci_registry_probe() { echo sha256:other; }
    run _ci_release_stack_changed v0.2.0
    [ "${status}" -eq 0 ]
}

@test "cut-release-tag pushes the next patch tag only when the stack changed" {
    # What: Gate sequence before PAT tag push.
    # Why: Patch releases on image-affecting pushes.
    # From: Issue #1683
    local calls="${BATS_TEST_TMPDIR}/cut-calls"; export CUT_CALLS="${calls}"
    local push base tipok noexist changed unchanged tipmoved
    push="$(_stub push 'echo "PUSH $1 $2" >> "${CUT_CALLS}"')"
    base="$(_stub base 'echo v0.2.0')"
    tipok="$(_stub tipok 'echo mysha')"
    tipmoved="$(_stub tipmoved 'echo othersha')"
    noexist="$(_stub noexist 'exit 1')"
    changed="$(_stub changed 'exit 0')"
    unchanged="$(_stub unchanged 'exit 1')"
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="$(_stub nobase 'true')" run ci_cmd_cut_release_tag
    [ "${status}" -eq 0 ]; [[ "${output}" == *"no-base-tag"* ]]; [ ! -s "${calls}" ]
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="${unchanged}" run ci_cmd_cut_release_tag
    [ "${status}" -eq 0 ]; [[ "${output}" == *"stack-unchanged"* ]]; [ ! -s "${calls}" ]
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="${changed}" GITHUB_SHA=mysha CI_PROMOTE_TIP_CMD="${tipmoved}" run ci_cmd_cut_release_tag
    [ "${status}" -eq 0 ]; [[ "${output}" == *"superseded"* ]]; [ ! -s "${calls}" ]
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="${changed}" GITHUB_SHA=mysha CI_PROMOTE_TIP_CMD="${tipok}" CI_TAG_EXISTS_CMD="$(_stub exists 'exit 0')" run ci_cmd_cut_release_tag
    [ "${status}" -eq 0 ]; [[ "${output}" == *"exists"* ]]; [ ! -s "${calls}" ]
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="${changed}" GITHUB_SHA=mysha CI_PROMOTE_TIP_CMD="${tipok}" CI_TAG_EXISTS_CMD="${noexist}" CI_TAG_PUSH_CMD="${push}" run ci_cmd_cut_release_tag
    [ "${status}" -eq 0 ]; [[ "${output}" == *"pushed tag=v0.2.1"* ]]
    [ "$(cat "${calls}")" = "PUSH v0.2.1 mysha" ]
    # What: a failed base or tag lookup stops with rc 2.
    # Why: UNKNOWN is never "no release" nor "tag absent".
    # From: Issue #1683 | PR #1858
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="$(_stub basefail 'exit 2')" run ci_cmd_cut_release_tag
    [ "${status}" -eq 2 ]
    [ ! -s "${calls}" ]
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="${changed}" GITHUB_SHA=mysha \
        CI_PROMOTE_TIP_CMD="${tipok}" CI_TAG_EXISTS_CMD="$(_stub unknown 'exit 2')" \
        CI_TAG_PUSH_CMD="${push}" run ci_cmd_cut_release_tag
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-RELEASE-0021] tag="v0.2.1" rc=2'* ]]
    [ ! -s "${calls}" ]
    # What: an unknown stack change is rc 2, never a noop.
    # Why: a registry error never skips a release silently.
    # From: Issue #1683 | PR #1858
    : > "${calls}"
    CI_LAST_RELEASE_TAG_CMD="${base}" CI_STACK_CHANGED_CMD="$(_stub stackunknown 'exit 2')" \
        CI_TAG_PUSH_CMD="${push}" run ci_cmd_cut_release_tag
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-RELEASE-0024] base="v0.2.0" rc=2'* ]]
    [[ "${output}" != *"cut-tag=noop"* ]]
    [ ! -s "${calls}" ]
}

@test "release tag readers keep no tags apart from a failed lookup" {
    # What: no tags is empty; a failed ls-remote is rc 2.
    # Why: UNKNOWN must never read as "no release yet".
    # From: Issue #1683 | PR #1858
    local work="${BATS_TEST_TMPDIR}/rel"
    local origin="${BATS_TEST_TMPDIR}/origin.git"
    local t
    git init -q "${work}"
    git -C "${work}" -c user.email=a@b -c user.name=b commit -q --allow-empty -m x
    cd "${work}"
    run _ci_last_release_tag
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"* ]]
    run _ci_remote_tag_exists v0.1.0
    [ "${status}" -eq 2 ]
    git init -q --bare "${origin}"
    git remote add origin "${origin}"
    run _ci_last_release_tag
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    for t in v0.2.0 v0.10.0 v0.9.1 v1.0.0-rc1; do
        git tag "${t}"
    done
    git push -q origin --tags
    run _ci_last_release_tag
    [ "${status}" -eq 0 ]
    [ "${output}" = "v0.10.0" ]
    run _ci_remote_tag_exists v0.9.1
    [ "${status}" -eq 0 ]
    run _ci_remote_tag_exists v0.9.9
    [ "${status}" -eq 1 ]
}

# =========================================================
# GC
# =========================================================

_gc_roots() { _stub roots 'printf "sha256:aaa\nsha256:bbb\n"'; }

@test "default gc roots unions ledger, channel, and index-child digests" {
    # What: Roots = ledger records + channels + children.
    # Why: The transitive protected set, all states (§101).
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { printf 'id1\tproxy\tos/p1\tPRODUCED_UNVERIFIED\tsha256:led\n'; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { printf 'sha256:chan\n'; }
    _ci_index_raw() { printf '{"manifests":[{"platform":{"architecture":"p1"},"digest":"sha256:child"}]}'; }
    run _ci_default_gc_roots
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:led"* ]]
    [[ "${output}" == *"sha256:chan"* ]]
    [[ "${output}" == *"sha256:child"* ]]
}

@test "default gc roots protect the build-tools channels too" {
    # What: toolchain channels and children are roots.
    # Why: else GC orphans the channel index (unpullable).
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { return 1; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'nightly\n'; }
    _ci_registry_probe() { case "$1" in *build-tools:nightly) echo sha256:btidx ;; *) return 1 ;; esac; }
    _ci_index_raw() { printf '{"manifests":[{"platform":{"architecture":"p2"},"digest":"sha256:btarm"}]}'; }
    run _ci_default_gc_roots
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:btidx"* ]]
    [[ "${output}" == *"sha256:btarm"* ]]
}

@test "channel readback rejects an index with a lost child" {
    # What: index digest resolves, one child 404 -> reject.
    # Why: a channel on an unpullable index breaks all jobs.
    # From: Issue #1683 | PR #1858
    export GITHUB_REPOSITORY=owner/fixture-repo
    _ci_registry_digest() { echo sha256:idx; }
    _ci_index_raw() { printf '{"manifests":[{"platform":{"architecture":"p1"},"digest":"sha256:a"},{"platform":{"architecture":"p2"},"digest":"sha256:b"}]}'; }
    _ci_registry_probe() { echo sha256:ok; }
    run _ci_default_channel_readback build-tools latest
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:idx ]
    _ci_registry_probe() { case "$1" in *@sha256:b) return 1 ;; *) echo sha256:ok ;; esac; }
    run _ci_default_channel_readback build-tools latest
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-PROMOTE-0014]"* ]]
    [[ "${output}" != *"sha256:idx"$'\n'* ]]
}

@test "default gc roots refuses when the ledger read is UNKNOWN" {
    # What: An unreadable ledger refuses; never empty roots.
    # Why: UNKNOWN roots would delete live artifacts (§26).
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0012"* ]]
}

@test "default gc roots refuses an unparseable index; children never lost" {
    # What: bad index JSON -> GC-0026 rc 2; no roots out.
    # Why: lost children would be deleted as unreachable.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { return 1; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { printf 'sha256:chan\n'; }
    _ci_index_raw() { printf '{"manifests":[ not json'; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-GC-0026] service="'*'" digest="sha256:chan"'* ]]
    [[ "${output}" == *"jq: parse error"* ]]
    [[ "${output}" == *"index: {\"manifests\":[ not json"* ]]
    [[ "${output}" != *$'\n'"sha256:chan"* ]]
}

@test "default gc roots refuses on a transient channel probe" {
    # What: A flaky channel probe refuses the whole run.
    # Why: A transient miss must not drop a live channel.
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { return 1; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0013"* ]]
}

@test "default gc roots refuses when release.registry is absent" {
    # What: SOT without registry refused.
    # Why: Empty host drops channels.
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo
    local m="${BATS_TEST_TMPDIR}/noreg.yml"
    grep -v '^  registry:' "${CI_MANIFEST}" > "${m}"
    export CI_MANIFEST="${m}"
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
}

@test "default gc roots refuses on a transient index-child read" {
    # What: A flaky child read refuses the whole run.
    # Why: Missing children would orphan-delete live arches.
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { printf 'id1\tproxy\tos/p1\tACCEPTED\tsha256:led\n'; }
    ci_services() { printf '\n'; }
    _ci_mutable_channels() { printf '\n'; }
    _ci_index_raw() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0014"* ]]
}

@test "default gc roots skips a not-yet-promoted channel without failing" {
    # What: A not-found channel is skipped, not a failure.
    # Why: A service never promoted is legitimately absent.
    # From: Issue #1683
    export GITHUB_REPOSITORY=owner/fixture-repo
    _ci_ledger_blob() { printf 'id1\tproxy\tos/p1\tACCEPTED\tsha256:led\n'; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { return 1; }
    _ci_index_raw() { return 1; }
    run _ci_default_gc_roots
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:led"* ]]
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
    _ci_manifest_scalar() { printf ''; }
    run _ci_default_gc_reachable "$(printf 'sha256:x\t9\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0015"* ]]
}

@test "gc fails closed on an empty protected-roots set" {
    # What: An empty roots set must stop the pass.
    # Why: Empty roots would mark all artifacts unreachable.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub roots 'true')" \
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
            CI_GC_CANDIDATES_CMD="$(_stub "cands-${name}" "${cands}")"
            CI_GC_DELETE_CMD="$(_stub "del-${name}" "echo \"\$1\" >> '${log}'")")
        [ "${reach}" = - ] || ge+=(CI_GC_REACHABLE_CMD="$(_stub "reach-${name}" "${reach}")")
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

@test "default gc delete calls the GHCR delete endpoint by version id" {
    # What: Delete targets /versions/<id> for the service.
    # Why: The one destructive call, package-scoped.
    # From: Issue #1683
    gh() { echo "$@" >> "${BATS_TEST_TMPDIR}/gh.log"; }
    export -f gh
    GITHUB_REPOSITORY=owner/fixture-repo \
        run _ci_default_gc_delete "$(printf 'sha256:old\t222\t2020-01-01T00:00:00Z\t\tsvc-a')"
    [ "${status}" -eq 0 ]
    [[ "$(cat "${BATS_TEST_TMPDIR}/gh.log")" == *"api -X DELETE /orgs/owner/packages/container/fixture-repo%2Fsvc-a/versions/222"* ]]
}

@test "default gc delete refuses a candidate with no numeric id" {
    # What: A non-numeric id is refused, never guessed.
    # Why: A bad id could delete the wrong version.
    # From: Issue #1683
    run _ci_default_gc_delete "$(printf 'sha256:old\tnotanid\t2020\t\tproxy')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0019"* ]]
}

@test "gh_versions retries a transient GH-API failure, then succeeds" {
    # What: Transient GH-API failures retry then succeed.
    # Why: _ci_retry github-api retries a transient GH-API.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    gh() {
        local n; n="$(($(cat "${cnt}") + 1))"; printf '%s' "${n}" > "${cnt}"
        if [ "${n}" -lt 3 ]; then echo "HTTP 503 Service Unavailable" >&2; return 1; fi
        printf 'v1\t111\t2020-01-01T00:00:00Z\t\n'
    }
    export -f gh
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions owner "fixture-repo%2Fsvc-a"
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 3 ]
    [[ "${output}" == *"v1"* ]]
}

@test "gh_versions fails immediately (no retry) on a 404, package skipped" {
    # What: 404 does not consume retry budget.
    # Why: a GH-API 404 is permanent, never retried.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    gh() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "gh: Not Found (HTTP 404)" >&2; return 1
    }
    export -f gh
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions owner "fixture-repo%2Fsvc-b"
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 1 ]
}

@test "gc keeps a candidate the default probe finds in the roots file" {
    # What: Framework makes roots; default probe reads.
    # Why: End-to-end membership KEEP via the roots file.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub roots 'printf "sha256:aaa\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'printf "sha256:aaa\t7\t2020-01-01T00:00:00Z\n"')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
}

@test "gc keeps a fresh non-root candidate via the recency floor" {
    # What: A recent non-root candidate is kept end-to-end.
    # Why: In-flight artifacts survive GC (advisor case).
    # From: Issue #1683
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    CI_GC_ROOTS_CMD="$(_stub roots 'printf "sha256:root\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub cands "printf 'sha256:fresh\t7\t${now}\n'")" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
}

# =========================================================
# VALIDATION
# =========================================================

@test "validate fails closed with no stack candidate" {
    # What: No candidate source means nothing to validate.
    # Why: Fail closed, never validate a phantom stack.
    # From: Issue #1683
    run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0001"* ]]
}

@test "validate fails closed on an empty stack candidate" {
    # What: An empty candidate cannot be validated.
    # Why: Fail closed, never accept an empty stack.
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'true')" \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0002"* ]]
}

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
            FAIL3) CI_STACK_CANDIDATE_CMD="$(_stub "c-${name}" 'exit 3')" ;;
            *) printf '%s\n' "${lines//;/$'\n'}" > "${f}"; CI_STACK_CANDIDATE_CMD="$(_stub "c-${name}" "cat '${f}'")" ;;
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

@test "validate fails closed without GHCR auth" {
    # What: Deploying the stack pulls images; needs auth.
    # Why: Never anonymous against GHCR (rate-limit).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=$(_test_digest a)")" \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "validate default backend fails closed when compose is unreadable" {
    # What: The wired default refuses without compose data.
    # Why: real backend past a free slot, still fail-closed.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
case "$1 $2" in "network ls"|"compose version") exit 0 ;; *) exit 1 ;; esac
STUB
    PATH="${bin}:${PATH}" CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=$(_test_digest a)")" \
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'exit 3')" \
    TMPDIR="${BATS_TEST_TMPDIR}" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'[CI-ERROR-VALIDATE-0069] filter='*'reason="compose config read failed"'* ]]
}

@test "validate fails with raw evidence when the stack is unhealthy" {
    # What: A failed validation run surfaces its raw output.
    # Why: Raw failure evidence is mandatory (AG-INT-002).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=$(_test_digest a)")" \
    CI_VALIDATE_CMD="$(_stub val 'echo STACK-UNHEALTHY; exit 1')" \
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
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=$(_test_digest a)")" \
    CI_VALIDATE_CMD="$(_stub val 'exit 0')" \
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

@test "stream-map check accepts a wildcard that forwards to the requested SNI" {
    # What: *.domain->SNI route is correct.
    # Why: Wildcards route by SNI, not root.
    # From: Issue #1297
    run bash -c "source '${CI_SH}'; printf '%s\n' '    *.example.com   \$ssl_preread_server_name:443;' | _ci_stream_map_violations"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "stream-map check flags a wildcard hardcoded to a root literal (#1297)" {
    # What: *.domain -> <root>:443 is bug.
    # Why: Subdomain must reach own origin.
    # From: Issue #1297
    run bash -c "source '${CI_SH}'; printf '%s\n' '    *.example.com   example.com:443;' | _ci_stream_map_violations"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"*.example.com"* ]]
}

@test "validate pins one SOT service onto both its compose containers" {
    # What: dns pins both dns-standard and dns-ssl.
    # Why: Pin by image, not key (1 service, 2 containers).
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "dns-standard\tcompose.example.test/owner/fixture-repo/dns:latest\ndns-ssl\tcompose.example.test/owner/fixture-repo/dns:latest\n"')" \
        run _ci_validate_pin_override "dns=sha256:aaa"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dns-standard:"* ]]
    [[ "${output}" == *"dns-ssl:"* ]]
    [ "$(grep -c 'image: registry.example.test/owner/fixture-repo/dns@sha256:aaa$' <<<"${output}")" -eq 2 ]
    [[ "${output}" != *"compose.example.test"* ]]
}

@test "validate skips third-party compose images without pinning" {
    # What: nats is third-party; it is never pinned.
    # Why: No first-party digest exists for external images.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "nats\tnats:2-alpine@sha256:c11\nproxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
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
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "proxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
        run _ci_validate_pin_override "watchdog=sha256:w"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0007"* ]]
}

@test "validate reports (not fails) a candidate with no first-party image" {
    # What: a candidate whose compose image is third-party.
    # Why: drift stays visible as a warning, no hard fail.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY=owner/fixture-repo \
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "svc-x\tupstream.example.test/x@sha256:a13\nproxy\tregistry.example.test/owner/fixture-repo/proxy:latest\n"')" \
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

@test "validate host tools fail closed on a missing tool or list" {
    # What: absent SOT list or tool -> VALIDATE-0056, rc 2.
    # Why: the runner host must be proven, never assumed.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/ht.yml"
    docker() { echo "Docker Compose version vX"; }
    printf 'validation:\n  host_tools: [bash, no-such-tool-x]\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validate_host_tools
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0062"*'missing="no-such-tool-x"'* ]]
    printf 'validation:\n  other: x\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validate_host_tools
    [ "${status}" -eq 2 ]
    printf 'validation:\n  host_tools: [bash]\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validate_host_tools
    [ "${status}" -eq 0 ]
}

@test "validation env lists the SOT pairs, fails closed when absent" {
    # What: KEY=VALUE lines from the SOT; none -> rc 2.
    # Why: validate and config check share this one owner.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/ve.yml"
    printf 'validation:\n  compose_validation_env: A_KEY=1 B_KEY=two\n' > "${m}"
    CI_MANIFEST="${m}" run _ci_validation_env
    [ "${status}" -eq 0 ]
    [ "${output}" = $'A_KEY=1\nB_KEY=two' ]
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
        d="$(base64 -d <<<"${v}" 2>&1)" || { echo "${k}='${v}': ${d}"; return 1; }
        [ "${#d}" -eq 32 ] || { echo "${k}='${v}': ${#d} bytes"; return 1; }
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

@test "compose profile flags cover every profile and fail closed" {
    # What: one --profile pair per profile; read error -> 2.
    # Why: a profiled service must never be skipped.
    # From: Issue #1683
    docker() { printf 'logging\nntp\n'; }
    run _ci_compose_profile_flags f.yml
    [ "${status}" -eq 0 ]
    [ "${output}" = $'--profile\nlogging\n--profile\nntp' ]
    docker() { :; }
    run _ci_compose_profile_flags f.yml
    [ "${status}" -eq 0 ]; [ -z "${output}" ]
    docker() { echo "config broken" >&2; return 1; }
    run _ci_compose_profile_flags f.yml
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"config broken"* ]]
}

@test "validate up starts every profile and names host-mode exclusions" {
    # What: profiles reach up; host-mode is logged, not run.
    # Why: AG-VAL-027 coverage with stated exclusions.
    # From: Issue #1683
    _ci_validate_service_list() {
        case "$1" in *'== "host"'*) echo svc-h ;; *) printf 'svc-a\nsvc-p\n' ;; esac
    }
    _ci_compose_profile_flags() { printf -- '--profile\np1\n'; }
    docker() { echo "DOCKER $*"; }
    run _ci_validate_up proj net.yml pin.yml
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'CI-INFO-VALIDATE-0055'*'service="svc-h"'* ]]
    [[ "${output}" == *"--profile p1 up -d svc-a svc-p"* ]]
    [[ "${output}" != *"up -d svc-h"* ]]
}

@test "validate teardown removes leftovers and never hides a failure" {
    # What: down + leftover sweep + state root, raw errors.
    # Why: an aborted up left containers; masking hid it.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/docker.log" mode
    mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'SH'
echo "$*" >> "${DOCKER_LOG}"
case "$*" in
  compose*down*) [ "${DOWN_MODE}" = fail ] && { echo "boom-down" >&2; exit 1; }; exit 0 ;;
  "container ls"*) echo c1 ;;
  "volume ls"*) echo v1 ;;
  "network ls"*) : ;;
  run*) a="$*"; d="${a#*-v }"; d="${d%%:/s *}"; find "${d}" -mindepth 1 -delete ;;
esac
SH
    local nofile="${BATS_TEST_TMPDIR}/no-compose.yml" m
    grep -v '^  CI_COMPOSE_FILE:' "${CI_MANIFEST}" > "${nofile}"
    for mode in ok fail nofile; do
        : > "${log}"
        m="${CI_MANIFEST}"
        [ "${mode}" = nofile ] && m="${nofile}"
        export LANCACHE_STATE_DIR="${BATS_TEST_TMPDIR}/state-${mode}"
        mkdir -p "${LANCACHE_STATE_DIR}/cache"
        CI_MANIFEST="${m}" PATH="${bin}:${PATH}" DOCKER_LOG="${log}" \
            DOWN_MODE="${mode}" run _ci_validate_teardown "" proj
        grep -qx 'container rm -f c1' "${log}"
        grep -qx 'volume rm -f v1' "${log}"
        grep -q "^run --rm --network none -v ${LANCACHE_STATE_DIR}:/s " "${log}"
        [ ! -e "${LANCACHE_STATE_DIR}" ]
        case "${mode}" in
            ok) [ "${status}" -eq 0 ] || { echo "${output}"; return 1; } ;;
            fail)
                [ "${status}" -eq 2 ]
                [[ "${output}" == *"CI-ERROR-VALIDATE-0058"*"boom-down"* ]]
                ;;
            nofile)
                [ "${status}" -eq 2 ]
                [[ "${output}" == *"CI-ERROR-VARIABLES-0001"*"CI_COMPOSE_FILE"* ]]
                if grep -q '^compose' "${log}"; then return 1; fi
                ;;
        esac
    done
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

@test "validate wait_healthy reports every unhealthy service" {
    # What: A failed wait names its service and fails.
    # Why: Parallel waits still surface each failure.
    # From: Issue #1683 | PR #1858
    _ci_validate_health_services() { printf 'proxy\ndns-standard\n'; }
    _ci_validate_no_health_services() { :; }
    _ci_validate_wait_one() { [ "$2" = "dns-standard" ] && return 1; return 0; }
    _ci_validate_service_evidence() { echo "RAW-LOG-$2"; }
    run _ci_validate_wait_healthy "proj"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0009"* ]]
    [[ "${output}" == *'service="dns-standard"'* ]]
    [[ "${output}" == *'check="healthcheck"'* ]]
    [[ "${output}" == *"RAW-LOG-dns-standard"* ]]
    [[ "${output}" != *"RAW-LOG-proxy"* ]]
}

@test "validate service evidence prints state and full logs" {
    # What: container id, json state and logs, unfiltered.
    # Why: the failure reason lives in the container log.
    # From: Issue #1683
    docker() {
        case "$*" in
            *"ps -aq"*) echo cid9 ;;
            inspect*) echo '{"Status":"exited","ExitCode":3}' ;;
            *logs*) printf 'line-1\nfatal: boom\n' ;;
        esac
    }
    run _ci_validate_service_evidence proj ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"container=cid9"*'"ExitCode":3'*"line-1"*"fatal: boom"* ]]
}

@test "validate wait_healthy also covers no-healthcheck services" {
    # What: A no-healthcheck service still fails crash-loop.
    # Why: AG-VAL-027: coverage must not skip it.
    # From: Issue #1683
    _ci_validate_health_services() { :; }
    _ci_validate_no_health_services() { printf 'cachehamster\n'; }
    _ci_validate_wait_stable() { return 1; }
    run _ci_validate_wait_healthy "proj"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0009"* ]]
    [[ "${output}" == *'service="cachehamster"'* ]]
    [[ "${output}" == *'check="stability"'* ]]
}

@test "validate health list excludes no-healthcheck services" {
    # What: no-health list is disjoint from health list.
    # Why: Each service polled by exactly one wait strategy.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{\"healthcheck\":{}},\"dhcp\":{\"network_mode\":\"host\"},\"cachehamster\":{}}}"')" \
        run _ci_validate_no_health_services
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cachehamster"* ]]
    [[ "${output}" != *"proxy"* ]]
    [[ "${output}" != *"dhcp"* ]]
}

@test "validate wait_stable succeeds once StartedAt holds through the window" {
    # What: A stable StartedAt across polls passes.
    # Why: Proves the settle window actually waits.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) [[ "$*" == *" ps -aq "* ]] && echo cid1 ;;
            inspect) echo running ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -eq 0 ]
}

@test "validate wait_stable never settles across restarts (crash-loop)" {
    # What: A StartedAt that keeps changing never settles.
    # Why: This is the crash-loop signal, not a count.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    docker() {
        case "$1" in
            compose) [[ "$*" == *" ps -aq "* ]] && echo cid1 ;;
            inspect)
                if [[ "$3" == *StartedAt* ]]; then
                    printf '%s' "$(( $(cat "${cnt}") + 1 ))" > "${cnt}"
                    cat "${cnt}"
                else
                    echo running
                fi
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=3 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
}

@test "validate wait_stable fails while the container is not running" {
    # What: A non-running status never counts as stable.
    # Why: Restarting/exited must never read as settled.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) [[ "$*" == *" ps -aq "* ]] && echo cid1 ;;
            inspect) echo restarting ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=3 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
}

@test "validate wait_stable passes a one-shot exit-0 service" {
    # What: a restart:no service exits 0 by design.
    # Why: A one-shot exit is success, not a crash-loop.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) [[ "$*" == *" ps -aq "* ]] && echo cid1 ;;
            inspect)
                [[ "$3" == *ExitCode* ]] && echo 0 || echo exited
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -eq 0 ]
}

@test "validate wait_stable fails a one-shot service exiting nonzero" {
    # What: A nonzero exit on a one-shot service is a crash.
    # Why: Success needs ExitCode 0, not just exited.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) [[ "$*" == *" ps -aq "* ]] && echo cid1 ;;
            inspect)
                [[ "$3" == *ExitCode* ]] && echo 1 || echo exited
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
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
    [ "${o2}" -ge 16 ] && [ "${o2}" -le 31 ]
    host="${a%/27}"; host="${host##*.}"
    [ "$(( host % 32 ))" -eq 0 ]
}

@test "validate detects a /27 overlapping a live network" {
    # What: An overlapping live subnet is reported.
    # Why: Reserve must skip a colliding /27.
    # From: Issue #1683
    docker() {
        case "$1 $2" in
            "network ls") echo netid1 ;;
            "network inspect") echo "172.16.1.0/24" ;;
        esac
    }
    run _ci_validate_subnet_conflicts 172.16.1.32/27
    [ "${status}" -eq 0 ]
    [[ "${output}" == "172.16.1.0/24" ]]
}

@test "validate passes a /27 that overlaps nothing live" {
    # What: A /27 overlapping nothing is free.
    # Why: Free slots must not be falsely skipped.
    # From: Issue #1683
    docker() {
        case "$1 $2" in
            "network ls") [ -z "${LS_FAIL:-}" ] || return 1; echo netid1 ;;
            "network inspect") echo "10.0.0.0/24" ;;
        esac
    }
    run _ci_validate_subnet_conflicts 172.16.1.32/27
    [ "${status}" -eq 1 ]
    LS_FAIL=1 run _ci_validate_subnet_conflicts 172.16.1.32/27
    [ "${status}" -eq 2 ]
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

@test "validate startable excludes host-mode services" {
    # What: host-mode services are never started.
    # Why: Host-port bindings cannot be isolated.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{},\"dhcp\":{\"network_mode\":\"host\"},\"dns-standard\":{}}}"')" \
        run _ci_validate_startable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy"* ]]
    [[ "${output}" == *"dns-standard"* ]]
    [[ "${output}" != *"dhcp"* ]]
}

@test "validate health list is started and healthchecked" {
    # What: Health list is started AND healthchecked.
    # Why: Polling an unstarted service hangs out.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{\"healthcheck\":{}},\"dhcp\":{\"network_mode\":\"host\",\"healthcheck\":{}},\"cachehamster\":{}}}"')" \
        run _ci_validate_health_services
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy"* ]]
    [[ "${output}" != *"dhcp"* ]]
    [[ "${output}" != *"cachehamster"* ]]
}

@test "validate net override isolates and resets services" {
    # What: Override splits the /27, resets ports and names.
    # Why: No auto /16 pool, no port or name collisions.
    # From: Issue #1683 | PR #1858
    local name nets want w
    local -a ws
    while IFS='|' read -r name nets want; do
        CI_COMPOSE_CONFIG_CMD="$(_stub "cfg-${name}" "printf '%s' '{\"services\":{\"proxy\":{},\"dhcp\":{\"network_mode\":\"host\"}},\"networks\":{${nets}}}'")" \
            run _ci_validate_net_override 172.16.1.32/27
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            case "${w}" in
                rc=*) [ "${status}" -eq "${w#rc=}" ] ;;
                !*) [[ "${output}" != *"${w#!}"* ]] ;;
                *) [[ "${output}" == *"${w}"* ]] ;;
            esac || { echo "${name}: '${w}': rc ${status}: ${output}"; return 1; }
        done
    done <<'CASES'
default-only|"default":{}|rc=0;default:;subnet: 172.16.1.32/28;proxy:;container_name: !reset null;ports: !reset [];!dhcp:;!/29
two-extra|"default":{},"a":{},"b":{"internal":true}|rc=0;subnet: 172.16.1.32/28;a:;subnet: 172.16.1.48/29;b:;subnet: 172.16.1.56/29
three-extra|"a":{},"b":{},"c":{}|rc=2;CI-ERROR-VALIDATE-0068;network="c"
CASES
}

@test "validate container ip refuses a non-ipv4 result" {
    # What: A non-IPv4 inspect result is refused.
    # Why: Else a check digs a bogus resolver.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo "abc123" ;;
            inspect) echo "<no value>" ;;
        esac
    }
    run _ci_validate_container_ip proj proxy
    [ "${status}" -ne 0 ]
    # What: a docker error is rc 2 with its raw output.
    # Why: "no container" must not hide a daemon error.
    # From: Issue #1683 | PR #1858
    docker() { echo "permission denied on docker.sock" >&2; return 1; }
    run _ci_validate_container_ip proj proxy
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*"permission denied on docker.sock"* ]]
}

@test "validate network inspect: only not-found means gone" {
    # What: not found = done; other inspect errors = rc 2.
    # Why: a leftover network must not pass as removed.
    # From: Issue #1683 | PR #1858
    docker() { echo "Error response from daemon: network n1 not found" >&2; return 1; }
    run _ci_validate_network_teardown n1
    [ "${status}" -eq 0 ]
    docker() { echo "permission denied" >&2; return 1; }
    run _ci_validate_network_teardown n1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0064"*"permission denied"* ]]
}

@test "validate poll returns on success and shows the last error" {
    # What: success is rc 0; a timeout prints last error.
    # Why: a probe timeout must say why it never answered.
    # From: Issue #1683 | PR #1858
    sleep() { :; }
    run _ci_validate_poll 3 1 true
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_validate_poll 3 1 bash -c 'echo "connection refused" >&2; exit 7'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"connection refused"* ]]
}

@test "validate wait_one stops on a docker error with raw output" {
    # What: an inspect error is rc 2 at once, raw shown.
    # Why: polling on errors hid them until the timeout.
    # From: Issue #1683 | PR #1858
    docker() {
        case "$*" in
            *"ps -q"*) echo cid1 ;;
            inspect*) echo "inspect boom" >&2; return 1 ;;
        esac
    }
    CI_VALIDATE_HEALTH_TIMEOUT=30 run _ci_validate_wait_one proj svc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*"inspect boom"* ]]
}

@test "validate container ip returns the container ipv4" {
    # What: A real IPv4 from inspect is returned.
    # Why: Checks target the runtime /27 IP.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo "abc123" ;;
            inspect) echo "172.16.1.35" ;;
        esac
    }
    run _ci_validate_container_ip proj proxy
    [ "${status}" -eq 0 ]
    [ "${output}" = "172.16.1.35" ]
}

@test "validate dns fails when a resolver IP is missing" {
    # What: Missing dns container IP returns rc 2.
    # Why: Cannot dig without a resolver target.
    # From: Issue #1683
    _ci_validate_container_ip() { :; }
    _ci_validation_dns_domain() { echo a.example.test; }
    run _ci_validate_dns proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0010"* ]]
}

@test "validate dns fails when a mode returns no answer" {
    # What: An empty dig answer returns rc 1.
    # Why: A resolver mode must actually answer.
    # From: Issue #668
    _ci_validate_container_ip() { case "$2" in dns-standard) echo 1.1.1.1 ;; dns-ssl) echo 2.2.2.2 ;; esac; }
    _ci_validation_dns_domain() { echo a.example.test; }
    dig() { case "$2" in @1.1.1.1) echo 10.0.0.1 ;; *) : ;; esac; }
    run _ci_validate_dns proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0011"* ]]
}

@test "validate dns fails when standard and ssl share an answer" {
    # What: identical std/ssl answers return rc 1.
    # Why: split routing needs distinct IPs.
    # From: Issue #668
    _ci_validate_container_ip() { case "$2" in dns-standard) echo 1.1.1.1 ;; dns-ssl) echo 2.2.2.2 ;; esac; }
    _ci_validation_dns_domain() { echo a.example.test; }
    dig() { echo 10.0.0.9; }
    run _ci_validate_dns proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0021"* ]]
}

@test "validate dns passes on distinct split-routed answers" {
    # What: distinct std/ssl answers return rc 0.
    # Why: split routing holds.
    # From: Issue #668
    _ci_validate_container_ip() { case "$2" in dns-standard) echo 1.1.1.1 ;; dns-ssl) echo 2.2.2.2 ;; esac; }
    _ci_validation_dns_domain() { echo a.example.test; }
    dig() { case "$2" in @1.1.1.1) echo 10.0.0.1 ;; @2.2.2.2) echo 10.0.0.2 ;; esac; }
    run _ci_validate_dns proj
    [ "${status}" -eq 0 ]
}

@test "validate proxy maps each request outcome, raw on failure" {
    # What: MISS then HIT; each failure shows raw headers.
    # Why: a bare "not a HIT" hides why the cache missed.
    # From: Issue #1683 | PR #1858
    local cnt="${BATS_TEST_TMPDIR}/n" args="${BATS_TEST_TMPDIR}/args"
    local name m ip rc want w
    local -a ws
    _ci_validation_proxy_probe_url() { echo http://a.example.test/f; }
    _ci_validate_container_ip() { echo "${ip}"; }
    curl() {
        local n
        n=$(( $(cat "${cnt}") + 1 )); echo "${n}" > "${cnt}"
        echo "$*" >> "${args}"
        case "${m}:${n}" in
            miss-fail:1|repeat-fail:2) echo "curl: (7) refused" >&2; return 7 ;;
            *:1) echo "X-Cache-Status: MISS" ;;
            no-hit:2) echo "X-Cache-Status: EXPIRED" ;;
            *) echo "X-Cache-Status: HIT" ;;
        esac
    }
    while IFS='|' read -r name m ip rc want; do
        echo 0 > "${cnt}"; : > "${args}"
        run _ci_validate_proxy proj
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        [ "${want}" = - ] && continue
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
no-ip|hit||2|CI-ERROR-VALIDATE-0012
miss-fail|miss-fail|172.16.1.9|1|CI-ERROR-VALIDATE-0013;curl: (7) refused
repeat-fail|repeat-fail|172.16.1.9|1|CI-ERROR-VALIDATE-0065;curl: (7) refused
no-hit|no-hit|172.16.1.9|1|CI-ERROR-VALIDATE-0014;X-Cache-Status: MISS;X-Cache-Status: EXPIRED
hit|hit|172.16.1.9|0|-
CASES
    # What: both requests target the proxy IP, not DNS.
    # Why: a direct origin fetch would never show a HIT.
    # From: Issue #1683 | PR #1858
    [ "$(grep -c -- '--resolve a.example.test:80:172.16.1.9' "${args}")" -eq 2 ] || {
        echo "args:"; cat "${args}"; return 1; }
}

@test "validate probes run in order without a proxy, stop early" {
    # What: all probes in order, NO_PROXY=*, stop on fail.
    # Why: a host http_proxy answered the cache probe.
    # From: Issue #1683 | PR #1858
    local log="${BATS_TEST_TMPDIR}/probes" p fail=""
    local -a probes=(dns proxy proxy_stream_map ssl_mitm ssl_dispatch_map
        ui_nats_dns dns_rollback ui_depends_started secondary_identity)
    for p in "${probes[@]}"; do
        eval "_ci_validate_${p}() {
            echo \"${p} \${NO_PROXY}|\${no_proxy}\" >> '${log}'
            [ '${p}' != \"\${fail}\" ]
        }"
    done
    export NO_PROXY=keep no_proxy=keep
    : > "${log}"
    _ci_validate_probes proj
    [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "${probes[*]}" ] || {
        echo "order:"; cat "${log}"; return 1; }
    [ "$(cut -d' ' -f2 "${log}" | sort -u)" = '*|*' ] || {
        echo "proxy:"; cat "${log}"; return 1; }
    [ "${NO_PROXY}|${no_proxy}" = 'keep|keep' ]
    fail=ssl_mitm; : > "${log}"
    run _ci_validate_probes proj
    [ "${status}" -eq 1 ]
    [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "dns proxy proxy_stream_map ssl_mitm" ] || {
        echo "early:"; cat "${log}"; return 1; }
}

@test "validate ssl-mitm fails when proxy IP is missing" {
    # What: Missing proxy container/IP returns rc 2.
    # Why: Cannot TLS-probe without a target.
    # From: Issue #668
    _ci_validate_container_ip() { :; }
    _ci_validation_dns_domain() { echo a.example.test; }
    docker() { case "$1" in compose) echo cid1 ;; esac; }
    run _ci_validate_ssl_mitm proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0023"* ]]
}

@test "validate ssl-mitm fails when the proxy CA is unreadable" {
    # What: A failed CA copy returns rc 2.
    # Why: Cannot compare issuer without our CA.
    # From: Issue #668
    _ci_validate_container_ip() { echo 172.16.1.9; }
    _ci_validation_dns_domain() { echo a.example.test; }
    docker() { case "$1" in compose) echo cid1 ;; cp) return 1 ;; esac; }
    run _ci_validate_ssl_mitm proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0024"* ]]
}

@test "validate ssl-mitm fails when :443 cert is not our LAN CA" {
    # What: A foreign issuer returns rc 1.
    # Why: Foreign issuer means passthrough, not MITM.
    # From: Issue #668
    _ci_validate_container_ip() { echo 172.16.1.9; }
    _ci_validation_dns_domain() { echo a.example.test; }
    docker() { case "$1" in compose) echo cid1 ;; cp) return 0 ;; esac; }
    openssl() { case "$*" in *s_client*) echo PEM ;; *-subject*) echo "subject=CN=LanCache Root CA" ;; *-issuer*) echo "issuer=CN=DigiCert" ;; esac; }
    run _ci_validate_ssl_mitm proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0026"* ]]
    # What: a failed handshake shows s_client's own error.
    # Why: "no issuer" alone does not say why.
    # From: Issue #1683 | PR #1858
    openssl() {
        case "$*" in
            *s_client*) echo "connect:errno=111" >&2; return 1 ;;
            *-subject*) echo "subject=CN=LanCache Root CA" ;;
        esac
    }
    run _ci_validate_ssl_mitm proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0025"*"connect:errno=111"* ]]
}

@test "validate ssl-mitm passes when :443 cert is our LAN CA" {
    # What: Our CA as issuer returns rc 0.
    # Why: genuine MITM interception.
    # From: Issue #597
    _ci_validate_container_ip() { echo 172.16.1.9; }
    _ci_validation_dns_domain() { echo a.example.test; }
    docker() { case "$1" in compose) echo cid1 ;; cp) return 0 ;; esac; }
    openssl() { case "$*" in *s_client*) echo PEM ;; *-subject*) echo "subject=CN=LanCache Root CA" ;; *-issuer*) echo "issuer=CN=LanCache Root CA" ;; esac; }
    run _ci_validate_ssl_mitm proj
    [ "${status}" -eq 0 ]
}

@test "validate ssl-dispatch fails when no proxy container" {
    # What: Missing proxy container returns rc 2.
    # Why: Cannot read the dispatch map without it.
    # From: Issue #1276
    docker() { case "$1" in compose) : ;; esac; }
    run _ci_validate_ssl_dispatch_map proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0027"* ]]
}

@test "validate ssl-dispatch fails when map is unreadable" {
    # What: An unreadable dispatch map returns rc 2.
    # Why: SSL_ENABLED=0 or missing file, not a defect.
    # From: Issue #1276
    docker() { case "$1" in compose) echo cid1 ;; exec) return 1 ;; esac; }
    run _ci_validate_ssl_dispatch_map proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0028"* ]]
}

@test "validate ssl-dispatch fails when deeper SNI routes to MITM" {
    # What: depth>=2 to :9445 returns rc 1.
    # Why: deeper SNI has no wildcard cert.
    # From: Issue #1322
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            exec) printf '%s\n' '    "~^[^.]+\.example\.net$"   127.0.0.1:9445;' '    "~^.+\.example\.net$"      127.0.0.1:9445;' ;;
        esac
    }
    run _ci_validate_ssl_dispatch_map proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0029"* ]]
}

@test "validate ssl-dispatch passes on correct depth split" {
    # What: deeper=:9446, one-level=:9445 ok.
    # Why: depth dispatch is correct.
    # From: Issue #1276
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            exec) printf '%s\n' '    "~^[^.]+\.example\.net$"   127.0.0.1:9445;' '    "~^.+\.example\.net$"      127.0.0.1:9446;' ;;
        esac
    }
    run _ci_validate_ssl_dispatch_map proj
    [ "${status}" -eq 0 ]
}

@test "validate ui-session fails when no ui IP" {
    # What: Missing ui IP returns rc 2.
    # Why: Cannot open a session without a target.
    # From: Issue #1164
    _ci_validate_container_ip() { :; }
    run _ci_validate_ui_session proj "${BATS_TEST_TMPDIR}/ci-test-jar"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0030"* ]]
    # What: a ui that never answers shows curl's last error.
    # Why: the timeout alone does not say why.
    # From: Issue #1683 | PR #1858
    _ci_validate_container_ip() { echo 172.16.1.9; }
    curl() { echo "curl: (7) Failed to connect" >&2; return 7; }
    sleep() { :; }
    run _ci_validate_ui_session proj "${BATS_TEST_TMPDIR}/ci-test-jar"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0031"*"Failed to connect"* ]]
}

@test "validate ui-session extracts the CSRF token" {
    # What: A session cookie yields its CSRF segment.
    # Why: One owner for cookiejar + CSRF extraction.
    # From: Issue #628
    _ci_validate_container_ip() { echo 172.16.1.9; }
    curl() {
        local jar="" a
        for a in "$@"; do [ "$a" = "-w" ] && { echo 303; return 0; }; done
        while [ $# -gt 0 ]; do case "$1" in -c) jar="$2"; shift 2;; *) shift;; esac; done
        [ -n "$jar" ] && printf 'd\tF\t/\tF\t0\tlancache_ui_session\thdr.body.TOK123\n' > "$jar"
        return 0
    }
    run _ci_validate_ui_session proj "${BATS_TEST_TMPDIR}/ci-test-jar"
    [ "${status}" -eq 0 ]
    [ "${output}" = "TOK123" ]
    rm -f "${BATS_TEST_TMPDIR}/ci-test-jar"
}

@test "validate ui-add-record fails on non-303" {
    # What: A non-303 add returns rc 1.
    # Why: UI must accept the write (303 redirect).
    # From: Issue #1164
    _ci_validate_container_ip() { echo 172.16.1.9; }
    curl() { echo 500; }
    run _ci_validate_ui_add_record proj "${BATS_TEST_TMPDIR}/jar" tok ci-probe 203.0.113.60
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0034"* ]]
}

@test "validate ui-add-record passes on 303" {
    # What: A 303 add returns rc 0.
    # Why: 303 is the UI's success redirect.
    # From: Issue #1164
    _ci_validate_container_ip() { echo 172.16.1.9; }
    curl() { echo 303; }
    run _ci_validate_ui_add_record proj "${BATS_TEST_TMPDIR}/jar" tok ci-probe 203.0.113.60
    [ "${status}" -eq 0 ]
}

@test "validate dns-resolves fails when no dns IP" {
    # What: Missing dns IP returns rc 2.
    # Why: Cannot dig without a resolver.
    # From: Issue #1164
    _ci_validate_container_ip() { :; }
    run _ci_validate_dns_resolves proj dns-standard x.lan. 203.0.113.60 2
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0035"* ]]
}

@test "validate dns-resolves fails when record never matches" {
    # What: A never-matching record returns rc 1.
    # Why: The written record must actually resolve.
    # From: Issue #1164
    _ci_validate_container_ip() { echo 172.16.1.3; }
    dig() { echo "10.9.9.9 $*"; }
    sleep() { :; }
    _ci_validate_service_evidence() { echo "evidence $1 $2"; }
    run _ci_validate_dns_resolves proj dns-standard x.lan. 203.0.113.60 2
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0036"* ]]
    # What: failure ships full dig, zone SOA, service logs.
    # Why: an empty +short answer alone proves no cause.
    # From: Issue #1683 | PR #1858
    [[ "${output}" == *"full answer:"*"@172.16.1.3 A x.lan."* ]]
    [[ "${output}" == *"zone SOA:"*"@172.16.1.3 SOA lan."* ]]
    [[ "${output}" == *"service:"*"evidence proj dns-standard"* ]]
    # What: a dig warning plus the right answer matches.
    # Why: stderr is evidence, never part of the answer.
    # From: Issue #1683 | PR #1858
    dig() { echo ";; Warning: EDNS mismatch" >&2; echo 203.0.113.60; }
    run _ci_validate_dns_resolves proj dns-standard x.lan. 203.0.113.60 2
    [ "${status}" -eq 0 ]
}

@test "validate dns-resolves passes when record matches" {
    # What: A matching answer returns rc 0.
    # Why: Proves the record reached this dns mode.
    # From: Issue #1164
    _ci_validate_container_ip() { echo 172.16.1.3; }
    dig() { echo 203.0.113.60; }
    run _ci_validate_dns_resolves proj dns-standard x.lan. 203.0.113.60 2
    [ "${status}" -eq 0 ]
}

@test "validate ui-nats-dns passes end to end" {
    # What: session+add+resolve(std,ssl) returns rc 0.
    # Why: Proves the UI->NATS->PowerDNS+AXFR path.
    # From: Issue #1164
    _ci_validate_container_ip() { echo 172.16.1.9; }
    curl() {
        local jar="" a
        for a in "$@"; do [ "$a" = "-w" ] && { echo 303; return 0; }; done
        while [ $# -gt 0 ]; do case "$1" in -c) jar="$2"; shift 2;; *) shift;; esac; done
        [ -n "$jar" ] && printf 'd\tF\t/\tF\t0\tlancache_ui_session\th.b.TOK\n' > "$jar"
        return 0
    }
    dig() { echo 203.0.113.60; }
    run _ci_validate_ui_nats_dns proj
    [ "${status}" -eq 0 ]
}

@test "validate dns-rollback fails when no dns container" {
    # What: Missing dns-standard container returns rc 2.
    # Why: No target for the rollback round-trip.
    # From: Issue #628
    _ci_validate_container_ip() { :; }
    docker() { :; }
    run _ci_validate_dns_rollback proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0037"* ]]
}

@test "validate dns-rollback fails when the API key is unreadable" {
    # What: An empty shared-secret key returns rc 2.
    # Why: Cannot authenticate to the listener without it.
    # From: Issue #628
    _ci_validate_container_ip() { echo 172.16.1.3; }
    docker() { case "$1" in compose) echo cid1 ;; exec) : ;; esac; }
    run _ci_validate_dns_rollback proj
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0038"* ]]
}

@test "validate dns-rollback fails when /snapshots is not 401 without a key" {
    # What: non-401 unauth response returns rc 1.
    # Why: listener MUST require authentication.
    # From: Issue #628
    _ci_validate_container_ip() { echo 172.16.1.3; }
    docker() { case "$1" in compose) echo cid1 ;; exec) echo KEY123 ;; esac; }
    curl() { case "$*" in *-w*) echo 200 ;; *) return 0 ;; esac; }
    run _ci_validate_dns_rollback proj
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0040"* ]]
}

@test "validate dns-rollback drives the rollback through setup.sh" {
    # What: setup.sh CLI outcome decides pass or fail.
    # Why: §49 client path; flush or probe miss is a fail.
    # From: Issue #836
    local case want out
    _ci_validate_container_ip() { echo 172.16.1.3; }
    docker() { case "$1" in compose) echo cid1 ;; exec) echo KEY123 ;; esac; }
    _ci_validate_ui_session() { echo TOK; }
    _ci_validate_ui_add_record() { return 0; }
    _ci_validate_dns_resolves() { return 0; }
    curl() {
        case "$*" in
            *-w*) echo 401 ;;
            *-o\ /dev/null*) return 0 ;;
            *) echo '{"zones":{"lan.":[{"id":"snap1"}]}}' ;;
        esac
    }
    export CI_REPO_ROOT="${BATS_TEST_TMPDIR}/repo" CI_COMPOSE_FILE=dep/c.yml
    mkdir -p "${CI_REPO_ROOT}"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s %s\n" "${COMPOSE_PROJECT_NAME}" "$*" > "${CI_REPO_ROOT}/args"' \
        'cat "${CI_REPO_ROOT}/out"; exit "$(cat "${CI_REPO_ROOT}/rc")"' \
        > "${CI_REPO_ROOT}/setup.sh"
    while IFS='|' read -r case want out; do
        printf '%s\n' "${out}" > "${CI_REPO_ROOT}/out"
        case "${case}" in fails) echo 1 ;; *) echo 0 ;; esac > "${CI_REPO_ROOT}/rc"
        run _ci_validate_dns_rollback proj
        [ "${status}" -eq "${want}" ] || { echo "${case}: ${output}"; return 1; }
        [ "${want}" -eq 0 ] || [[ "${output}" == *"CI-ERROR-VALIDATE-0043"* ]]
        [ "$(cat "${CI_REPO_ROOT}/args")" = \
            "proj reset-to-last-known-good-config dns dep lan. snap1 --yes" ]
    done <<'CASES'
ok|0|rolled back to known-good snapshot snap1. Changed rrsets: ["ci-rollback-probe.lan."]
fails|1|rollback listener rejected the request with HTTP 500
flush|1|rolled back to known-good snapshot snap1. ci-rollback-probe.lan. cache-flush publishes failed
other-snap|1|rolled back to known-good snapshot snap0. Changed rrsets: ["ci-rollback-probe.lan."]
no-probe|1|rolled back to known-good snapshot snap1. Changed rrsets: []
CASES
}

@test "validate ui-depends fails on a service_healthy gate" {
    # What: service_healthy condition returns rc 1.
    # Why: UI must start immediately.
    # From: Issue #763
    _ci_validate_config_json() { echo '{"services":{"ui":{"depends_on":{"proxy":{"condition":"service_healthy"}}}}}'; }
    run _ci_validate_ui_depends_started
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0044"* ]]
}

@test "validate ui-depends passes when all deps are service_started" {
    # What: service_started conditions ok.
    # Why: UI starts immediately.
    # From: Issue #763
    _ci_validate_config_json() { echo '{"services":{"ui":{"depends_on":{"proxy":{"condition":"service_started"},"nats":{"condition":"service_started"}}}}}'; }
    run _ci_validate_ui_depends_started
    [ "${status}" -eq 0 ]
}

@test "validate secondary-identity maps each token and register case" {
    # What: token source, register and identity per row.
    # Why: the ui keeps a real env token; no file is made.
    # From: Issue #583 | PR #1858
    local args="${BATS_TEST_TMPDIR}/reg" name row_ip ex cu rc want tok w
    local -a ws
    _ci_validate_container_ip() { echo "${row_ip}"; }
    _ci_validate_cid() { echo cid1; }
    docker() {
        case "$*" in
            "exec cid1 test -f "*)
                case "${ex}" in
                    file|empty) return 0 ;;
                    env) return 1 ;;
                    broken) echo "Error: container cid1 is not running" >&2; return 126 ;;
                esac
                ;;
            "exec cid1 cat "*) [ "${ex}" = empty ] || echo TOKF ;;
            "exec cid1 printenv SECONDARY_REGISTRATION_TOKEN") echo TOKE ;;
            *) echo "unexpected docker call: $*" >&2; return 99 ;;
        esac
    }
    curl() {
        echo "$*" >> "${args}"
        case "${cu}:$*" in
            500:*) printf 'denied\n500' ;;
            same:*) printf '{"nats_user":"same","nats_password":"same"}\n200' ;;
            distinct:*ci-secondary-a*) printf '{"nats_user":"ua","nats_password":"pa"}\n200' ;;
            distinct:*) printf '{"nats_user":"ub","nats_password":"pb"}\n200' ;;
        esac
    }
    while IFS='|' read -r name row_ip ex cu rc want tok; do
        : > "${args}"
        run _ci_validate_secondary_identity proj
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [ "${w}" = - ] && continue
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
        [ "${tok}" = - ] && continue
        [ "$(grep -c "\"token\":\"${tok}\"" "${args}")" -eq 2 ] || {
            echo "${name}: register not sent with ${tok}:"; cat "${args}"; return 1; }
    done <<'CASES'
no-ui||file|distinct|2|CI-ERROR-VALIDATE-0045|-
empty-token|172.16.1.9|empty|distinct|2|CI-ERROR-VALIDATE-0046|-
file-check-broken|172.16.1.9|broken|distinct|2|CI-ERROR-VALIDATE-0066;rc=126;cid1 is not running|-
register-500|172.16.1.9|file|500|1|CI-ERROR-VALIDATE-0047;register ci-secondary-a: http 500;denied|-
shared-identity|172.16.1.9|file|same|1|CI-ERROR-VALIDATE-0049|TOKF
file-token|172.16.1.9|file|distinct|0|-|TOKF
env-token|172.16.1.9|env|distinct|0|-|TOKE
CASES
}

# =========================================================
# VARIABLES
# =========================================================

@test "variables get reads a value from the SOT fallback" {
    # What: With no env override, the SOT default is used.
    # Why: AG-CI-006 fallback, like CARGO_BUILD_JOBS.
    # From: Issue #1683
    run --separate-stderr bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 0 ]
    [ "${output}" = "30" ]
}

@test "variables get lets an env value override the SOT default" {
    # What: A set env value wins over the SOT fallback.
    # Why: AG-CI-006: use the variable when set.
    # From: Issue #1683
    REPOSITORY_CI_LEDGER_RETENTION_DAYS=45 \
        run --separate-stderr bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 0 ]
    [ "${output}" = "45" ]
}

@test "variables get reads CI_VARIABLES json; env still wins" {
    # What: vars json beats SOT; a set env beats the json.
    # Why: GitHub vars arrive once as json (AG-CI-006).
    # From: Issue #1683 | PR #1858
    CI_VARIABLES='{"REPOSITORY_CI_LEDGER_RETENTION_DAYS":"7"}' \
        run --separate-stderr bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [ "${output}" = "7" ]
    REPOSITORY_CI_LEDGER_RETENTION_DAYS=9 CI_VARIABLES='{"REPOSITORY_CI_LEDGER_RETENTION_DAYS":"7"}' \
        run --separate-stderr bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${output}" = "9" ]
    CI_VARIABLES='not json' run bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0015"* ]]
}

@test "variables get fails closed with no env and no SOT default" {
    # What: An unknown variable has no value anywhere.
    # Why: Fail closed, never emit an empty value.
    # From: Issue #1683
    run bash "${CI_SH}" variables get NONEXISTENT_VAR_XYZ
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0001"* ]]
}

@test "variables get fails closed with no variable name" {
    # What: A missing name must fail, not read blank.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" variables get
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0003"* ]]
}

@test "variables rejects an unknown subcommand" {
    # What: Only known subcommands are routed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" variables bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0002"* ]]
}

@test "bake-check fails closed without an image ref" {
    # What: bake-check needs an explicit image ref.
    # Why: No target means no proof; never pass blind.
    # From: Issue #1683
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0008"* ]]
}

@test "bake-check fails closed without GHCR auth" {
    # What: Image inspect must be authenticated.
    # Why: GHCR is never accessed anonymously.
    # From: Issue #1683
    run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "bake-check default backend reads env and counts the proxy CA" {
    # What: docker-stub image per case: rc and codes.
    # Why: the guard must inspect the real built image.
    # From: Issue #1781 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bkbin" name ca bundle irc want w
    local -a ws
    mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
case "$1" in
    image) [ "${BK_IRC}" = 0 ] || { echo "inspect-boom"; exit 1; }; printf 'PATH=/usr/bin\n%s\n' "${BK_ENV}" ;;
    run) printf '%b' "${BK_BUNDLE}" ;;
esac
STUB
    while IFS='|' read -r name ca bundle irc want; do
        PATH="${bin}:${PATH}" PROJECT_SELFHOSTED_PROXY_CA="${ca//;/$'\n'}" BK_BUNDLE="${bundle}" \
        BK_IRC="${irc}" BK_ENV="LANG=C" GHCR_USERNAME=u GHCR_TOKEN=t \
            run bash "${CI_SH}" variables bake-check img@sha256:d
        IFS=',' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
        [[ "${output}" != *"MARKERLINE"* ]] || { echo "${name}: CA bytes leaked"; return 1; }
    done <<'CASES'
no-ca-secret|||0|result=clean
ca-not-baked|BEGIN;MARKERLINE;END|OTHER\nCERT\n|0|result=clean
ca-baked|BEGIN;MARKERLINE;END|x\nMARKERLINE\ny\nMARKERLINE\n|0|CI-ERROR-VARIABLES-0016,extra_ca="2"
inspect-fails|||1|CI-ERROR-VARIABLES-0005,inspect-boom
CASES
}

@test "bake-check passes on a clean image" {
    # What: No forbidden var and no extra CA is clean.
    # Why: A clean image must not be blocked.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "env LANG=C"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=clean"* ]]
}

@test "bake-check fails on a baked proxy and hides the value" {
    # What: A baked HTTP_PROXY fails; log the key only.
    # Why: AG-SEC-007: never emit the secret value.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env HTTP_PROXY=http://10.0.0.9:3128"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0006"* ]]
    [[ "${output}" == *'key="HTTP_PROXY"'* ]]
    [[ "${output}" != *"10.0.0.9"* ]]
}

@test "bake-check fails on a baked accel var by prefix" {
    # What: An SCCACHE_/CCACHE_/DISTCC_ var is forbidden.
    # Why: Accel endpoints are LAN-only, must not bake.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env SCCACHE_REDIS=redis://h:6379"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0006"* ]]
    [[ "${output}" == *'key="SCCACHE_REDIS"'* ]]
}

@test "bake-check fails on a baked CA and shows only a count" {
    # What: An extra CA in the store fails the guard.
    # Why: Log the count, never the certificate bytes.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "extra_ca 1"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0016"* ]]
    [[ "${output}" == *'extra_ca="1"'* ]]
    [[ "${output}" != *"BEGIN CERTIFICATE"* ]]
}

@test "bake-check fails closed on an unknown inspect line" {
    # What: An unrecognized inspect line is not ignored.
    # Why: Silent skip could hide a real leak (fail-closed).
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "mystery 1"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0009"* ]]
}

@test "no Dockerfile mounts the legacy proxy_ca secret id" {
    # What: Every CA mount uses the canonical secret id.
    # Why: A stray proxy_ca = a silently CA-less build.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.."
    run git -C "${root}" grep -nE '(^|[^_])proxy_ca([^a-z_]|$)' -- services tools
    [ "${status}" -ne 0 ]
}

@test "every Dockerfile secret mount id is in the central list" {
    # What: Mounted secret ids come from the one list.
    # Why: No drift; one source drives provisioning.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.." allow ids id
    allow="$(_ci_runtime_secret_ids)"
    ids="$(git -C "${root}" grep -hoE 'mount=type=secret,id=[a-z0-9_]+' -- services tools | sed 's/.*id=//' | sort -u)"
    [ -n "${ids}" ]
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        grep -qx -- "${id}" <<< "${allow}"
    done <<< "${ids}"
}

@test "set-runtime rejects an invalid redis mode" {
    # What: SCCACHE_REDIS_MODE is a closed enum.
    # Why: An unknown mode is an error, not a guess.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=bogus \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0010"* ]]
}

@test "set-runtime errors on scheduler without auth token" {
    # What: dist scheduler and token are both-or-neither.
    # Why: A half config would build misauthenticated.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_URL='redis://h' \
    SCCACHE_DIST_SCHEDULER_URL='https://s' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0011"* ]]
}

@test "set-runtime errors on auth token without scheduler" {
    # What: the symmetric half of the both-or-neither pair.
    # Why: only the scheduler-without-token side had a test.
    # From: Issue #1683 | PR #1858
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt2" \
    SCCACHE_DIST_AUTH_TOKEN='tok' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0017"* ]]
    [[ "${output}" == *"auth token set without scheduler"* ]]
}

@test "set-runtime errors when required redis url is missing" {
    # What: mode=required needs SCCACHE_REDIS_URL.
    # Why: A trusted Rust build must have the cache.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=required \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0012"* ]]
}

@test "set-runtime optional mode skips redis when url is empty" {
    # What: mode=optional tolerates a missing redis url.
    # Why: The cache is an optimization, not required.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=optional \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"sccache_redis_url"* ]]
}

@test "set-runtime off mode emits no acceleration secrets" {
    # What: mode=off disables sccache and its redis.
    # Why: A build without the cache must still work.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=off \
    SCCACHE_REDIS_URL='redis://h' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"sccache_redis_url"* ]]
    [[ "${output}" != *"sccache_dist_config"* ]]
}

@test "set-runtime rejects distcc hosts without a pump host" {
    # What: DISTCC_POTENTIAL_HOSTS needs a ,cpp host.
    # Why: Pump mode needs a cpp-capable host present.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=off \
    DISTCC_POTENTIAL_HOSTS='h1 h2' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0013"* ]]
}

@test "set-runtime writes 0600 files and hides secret values" {
    # What: Each secret is a 0600 file + a --secret arg.
    # Why: AG-SEC-007: values never reach stdout or args.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    CI_RUNTIME_SECRET_DIR="${d}" SCCACHE_REDIS_MODE=required \
    SCCACHE_REDIS_URL='redis://h:6379' PROJECT_SELFHOSTED_PROXY_CA='CADATA' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--secret id=sccache_redis_url,src=${d}/sccache_redis_url"* ]]
    [[ "${output}" == *"--secret id=ccache_redis_url,src=${d}/ccache_redis_url"* ]]
    [[ "${output}" == *"--secret id=project_selfhosted_proxy_ca,src=${d}/project_selfhosted_proxy_ca"* ]]
    [[ "${output}" != *"redis://h:6379"* ]]
    [[ "${output}" != *"CADATA"* ]]
    [ "$(stat -c '%a' "${d}/project_selfhosted_proxy_ca")" = "600" ]
    [ "$(cat "${d}/sccache_redis_url")" = "redis://h:6379" ]
}

@test "set-runtime assembles the sccache dist config toml" {
    # What: The dist config carries scheduler and token.
    # Why: sccache dist needs both to reach the scheduler.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    CI_RUNTIME_SECRET_DIR="${d}" SCCACHE_REDIS_MODE=required \
    SCCACHE_REDIS_URL='redis://h' SCCACHE_DIST_SCHEDULER_URL='https://sched' \
    SCCACHE_DIST_AUTH_TOKEN='tok123' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--secret id=sccache_dist_config,src=${d}/sccache_dist_config"* ]]
    grep -q 'scheduler_url = "https://sched"' "${d}/sccache_dist_config"
    grep -q 'token = "tok123"' "${d}/sccache_dist_config"
    [ "$(stat -c '%a' "${d}/sccache_dist_config")" = "600" ]
}

@test "clear-runtime removes the runtime secret dir" {
    # What: clear-runtime deletes every secret file.
    # Why: Secrets must not linger after the build.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    mkdir -p "${d}"; printf 'x' > "${d}/project_selfhosted_proxy_ca"
    CI_RUNTIME_SECRET_DIR="${d}" run bash "${CI_SH}" variables clear-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=cleared"* ]]
    [ ! -e "${d}/project_selfhosted_proxy_ca" ]
}

# =========================================================
# BUILD-ARGS EMISSION (SOT -> --build-arg)
# =========================================================

@test "build-args emits the SOT base image and apk repos" {
    # What: ALPINE_IMAGE and APK_TAGGED_REPOS equal the SOT.
    # Why: build-tools is a factory, not a version lock.
    # From: Issue #1683
    local alpine repos
    alpine="$(_ci_block_entry_field base_images "" alpine)"
    repos="$(_ci_block_entry_list build_toolchain build-tools apk_repositories | tr '\n' ' ')"
    [ -n "${alpine}" ] && [ -n "${repos}" ]
    run bash "${CI_SH}" build-args build-tools
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"--build-arg ALPINE_IMAGE=${alpine}"* ]]
    [[ "${output}" == *"--build-arg APK_TAGGED_REPOS=${repos% }"* ]]
    [[ "${output}" != *"DOCKER_CLI_VERSION"* ]]
    [[ "${output}" != *"SCCACHE_VERSION"* ]]
}

@test "build-args fails closed on a missing central base image" {
    # What: A missing base pin must never build unpinned.
    # Why: Empty value = FAIL CLOSED, no partial emit.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/no-rust-alpine.yml"
    grep -v '^  alpine:' "${CI_MANIFEST}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args build-tools
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0003"* ]]
}

@test "build-args --bare emits NAME=VALUE without the flag prefix" {
    # What: bare form feeds docker/build-push-action.
    # Why: that action wants NAME=VALUE, not --build-arg.
    # From: Issue #1683
    local alpine
    alpine="$(_ci_block_entry_field base_images "" alpine)"
    run bash "${CI_SH}" build-args build-tools --bare
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"ALPINE_IMAGE=${alpine}"* ]]
    [[ "${output}" != *"--build-arg"* ]]
}

@test "build-args rejects an unknown format (fail closed)" {
    # What: only empty or --bare are valid formats.
    # Why: an unknown flag must not emit a silent default.
    # From: Issue #1683
    run bash "${CI_SH}" build-args build-tools --bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0005"* ]]
}

@test "build-args needs a service argument (fail closed)" {
    # What: No service arg must not emit a silent success.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build-args
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0001"* ]]
}

@test "build-args fails closed for an unrecognized target" {
    # What: a non-SOT target name is BUILDARGS-0002.
    # Why: empty args with rc 0 would build without pins.
    # From: Issue #1683
    run bash "${CI_SH}" build-args not-a-real-service
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-BUILDARGS-0002]"* ]]
}

@test "build-args: base image per service, <KEY>_IMAGE from external_image" {
    # What: alpine for all; external_image x -> X_IMAGE arg.
    # Why: one base-image owner, one naming rule, no list.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'base_images:\n  alpine: "img-a"\n  ext_x: "img-x"\nservices:\n  svc-a:\n    context: a\n    build_type: apk\n  svc-b:\n    context: b\n    build_type: apk\n    external_image: ext_x\n  svc-c:\n    context: c\n    build_type: apk\n    external_image: ext_missing\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-a
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ALPINE_IMAGE=img-a"* ]]
    [[ "${output}" != *"EXT_X_IMAGE"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-b --bare
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ALPINE_IMAGE=img-a"*"EXT_X_IMAGE=img-x"* ]]
    [[ "${output}" != *"--build-arg"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-c
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0007"*"base_images.ext_missing"* ]]
    sed -i '/alpine:/d' "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-a
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0003"* ]]
}

@test "build-args emits BUILD_TOOLS_IMAGE for a rust service, not apk" {
    # What: rust build-args add build-tools ref.
    # Why: no Dockerfile default; ci.sh owns it.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/bt-manifest.yml"
    printf 'base_images:\n  alpine: "a"\nservices:\n  svc-rust:\n    context: c\n    crate: c1\n    build_type: rust\n  svc-apk:\n    context: c\n    build_type: apk\n' > "${m}"
    export CI_BUILD_TOOLS_IMAGE_CMD='echo bt-stub@sha256:test'
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BUILD_TOOLS_IMAGE=bt-stub@sha256:test"* ]]
    [[ "${output}" == *"RUST_CRATE=c1"* ]]
    sed -i '/crate: c1/d' "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0014"* ]]
    printf 'base_images:\n  alpine: "a"\nservices:\n  svc-apk:\n    context: c\n    build_type: apk\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-apk
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"BUILD_TOOLS_IMAGE"* ]]
}

@test "image and identity add the build type's runtime packages" {
    # What: rust gets build_runtime packages once; apk none.
    # Why: a dynamic musl binary needs libgcc_s at runtime.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/rt-manifest.yml"
    printf '%s\n' 'base_images:' '  alpine: "a"' 'services:' \
        '  svc-rust:' '    context: c' '    crate: c1' '    build_type: rust' '    packages: [pkg-a, rt-x]' \
        '  svc-apk:' '    context: c' '    build_type: apk' '    packages: [pkg-a]' \
        'build_identity:' '  rust:' '    inputs: [package_versions]' \
        'build_runtime:' '  rust:' '    packages: [rt-x, rt-y]' > "${m}"
    export CI_BUILD_TOOLS_IMAGE_CMD='echo bt-stub@sha256:test'
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"APK_PACKAGES=pkg-a rt-x rt-y"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-apk
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"APK_PACKAGES=pkg-a"* ]]
    [[ "${output}" != *"rt-"* ]]
    _ci_platform_apk_arch() { echo arch-a; }
    CI_MANIFEST="${m}" CI_APK_RESOLVE_CMD="$(_stub resolve 'echo "pkgs=$3"')" \
        run _ci_identity_pins svc-rust rust os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pkgs=pkg-a rt-x rt-y"* ]]
}

@test "build-args emits MUSL_TARGET per platform for a rust service" {
    # What: rust build-args add the platform's musl target.
    # Why: ci.sh owns arch mapping; no Dockerfile.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/mt-manifest.yml"
    printf 'base_images:\n  alpine: "a"\nplatform_arch:\n  p1:\n    apk: arch-a\n  p2:\n    apk: arch-b\nservices:\n  svc-rust:\n    context: c\n    crate: c1\n    build_type: rust\n' > "${m}"
    export CI_BUILD_TOOLS_IMAGE_CMD='echo bt-stub@sha256:test'
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust --bare os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MUSL_TARGET=arch-a-alpine-linux-musl"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust --bare os/p2
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MUSL_TARGET=arch-b-alpine-linux-musl"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc-rust
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MUSL_TARGET"* ]]
}

@test "rust-build EXIT trap stops the pump, drops the CA, keeps rc" {
    # What: trap cleans up; a failed step fails, rc is kept.
    # Why: cleanup state must survive until the EXIT trap.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/rbbin"
    local driver="${BATS_TEST_TMPDIR}/trap-driver.sh"
    local name main pump ca want code
    export RB_LOG="${BATS_TEST_TMPDIR}/rb.log"
    mkdir -p "${bin}"
    _tool_stub "${bin}" distcc-pump <<'STUB'
echo "pump $*" >> "${RB_LOG}"
if [ -n "${PUMP_FAIL:-}" ]; then
    echo pump-boom >&2
    exit 1
fi
STUB
    _tool_stub "${bin}" update-ca-certificates <<'STUB'
echo "update-ca" >> "${RB_LOG}"
if [ -n "${CA_FAIL:-}" ]; then
    echo ca-boom >&2
    exit 1
fi
STUB
    cat > "${driver}" <<'DRIVER'
source "${CI_SH}"
_CI_RB_CA_FILE="${CA_FILE}"
trap _ci_rust_build_cleanup EXIT
_CI_RB_DISTCC=1
_CI_RB_CA=1
exit "${MAIN_RC}"
DRIVER
    while IFS='|' read -r name main pump ca want code; do
        : > "${RB_LOG}"
        : > "${BATS_TEST_TMPDIR}/ca.crt"
        run env PATH="${bin}:${PATH}" PUMP_FAIL="${pump}" CA_FAIL="${ca}" \
            CI_SH="${CI_SH}" CA_FILE="${BATS_TEST_TMPDIR}/ca.crt" MAIN_RC="${main}" \
            bash "${driver}"
        if [ "${status}" -ne "${want}" ]; then
            echo "${name}: rc ${status}: ${output}"
            return 1
        fi
        if [[ "${output}" != *"${code}"* ]]; then
            echo "${name}: ${output}"
            return 1
        fi
        if ! grep -qx 'pump --shutdown' "${RB_LOG}"; then
            echo "${name}: pump not stopped"
            return 1
        fi
        if ! grep -qx 'update-ca' "${RB_LOG}"; then
            echo "${name}: trust store not updated"
            return 1
        fi
        if [ -e "${BATS_TEST_TMPDIR}/ca.crt" ]; then
            echo "${name}: CA file kept"
            return 1
        fi
    done <<'CASES'
ok|0|||0|
ca-fail|0||1|1|CI-ERROR-RUSTBUILD-0008
ca-fail-keeps-rc|3||1|3|ca-boom
pump-fail|0|1||1|CI-ERROR-RUSTBUILD-0007
CASES
}

@test "rust-build fails closed unless MUSL_TARGET is the rustc host" {
    # What: a target other than the rustc host stops early.
    # Why: apk Rust has only its host std; no rustup exists.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    _tool_stub "${bin}" rustc <<'STUB'
printf "rustc 1.0\nhost: arch-a-alpine-linux-musl\n"
STUB
    PATH="${bin}:${PATH}" MUSL_TARGET=arch-b-alpine-linux-musl run bash "${CI_SH}" rust-build svc c1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RUSTBUILD-0006"*"host: arch-a-alpine-linux-musl"* ]]
}

@test "rust cargo build degrades only on an accelerator outage" {
    # What: cargo stub replays rc|output per call.
    # Why: a real error ends at call 1 with its rc kept.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/cbin" name cc dc wrap steps want calls codes w
    local -a ws
    mkdir -p "${bin}"
    _tool_stub "${bin}" cargo <<'STUB'
n=$(( $(cat "${RB_N}") + 1 )); echo "${n}" > "${RB_N}"
line="$(sed -n "${n}p" "${RB_STEPS}")"
printf '%s\n' "${line#*|}"
exit "${line%%|*}"
STUB
    disable_ccache() { echo "off ccache"; }
    disable_distcc() { echo "off distcc"; }
    export RB_N="${BATS_TEST_TMPDIR}/n" RB_STEPS="${BATS_TEST_TMPDIR}/steps" CI_TMPDIR="${BATS_TEST_TMPDIR}"
    while IFS='|' read -r name cc dc wrap steps want calls codes; do
        echo 0 > "${RB_N}"
        tr ';' '\n' <<<"${steps}" | sed 's/~/|/' > "${RB_STEPS}"
        ccache_enabled="${cc}" _CI_RB_DISTCC="${dc}" RUSTC_WRAPPER="${wrap}" PATH="${bin}:${PATH}" \
            run _ci_rust_cargo_build c1 arch-a-alpine-linux-musl 2
        [ "${status}" -eq "${want}" ] && [ "$(cat "${RB_N}")" -eq "${calls}" ] \
            || { echo "${name}: rc ${status} calls $(cat "${RB_N}"): ${output}"; return 1; }
        IFS=',' read -r -a ws <<<"${codes}"
        for w in "${ws[@]}"; do
            case "${w}" in
                !*) [[ "${output}" != *"${w#!}"* ]] ;;
                *) [[ "${output}" == *"${w}"* ]] ;;
            esac || { echo "${name}: code ${w}: ${output}"; return 1; }
        done
    done <<'CASES'
real-error-all-on|1|1|w|101~error: could not compile `c1`|101|1|RUSTBUILD-0010,!RUSTBUILD-0011,!off ccache,could not compile
ok-first|1|1|w|0~done|0|1|!RUSTBUILD-0009
ccache-outage|1|1|w|1~ccache: error: x;0~done|0|2|RUSTBUILD-0011,off ccache,!off distcc,RUSTBUILD-0009
distcc-outage|1|1|w|116~failed to distribute;116~failed to distribute;0~done|0|3|off ccache,RUSTBUILD-0011,off distcc,RUSTBUILD-0012,RUSTBUILD-0009
sccache-outage|0|0|w|101~sccache: error: Timed out;0~done|0|2|RUSTBUILD-0013,RUSTBUILD-0009
outage-then-error|0|0|w|101~sccache: error: x;101~error: could not compile `c1`|101|2|RUSTBUILD-0013,RUSTBUILD-0010
nothing-left|0|0||101~sccache: error: x|101|1|RUSTBUILD-0014
CASES
}

@test "build-args emit a SOT pin; its digest needs a platform" {
    # What: no platform=version+per-arch shas only.
    # Why: one pin owner; ARCH/SHA256 need platform.
    # From: Issue #1683 | PR #1858
    local dep up ver
    dep="$(_pin_dep)"; up="${dep^^}"; up="${up//-/_}"
    ver="$(_ci_block_entry_field external_versions "${dep}" version)"
    run bash "${CI_SH}" build-args "$(_pin_consumer)"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ${up}_VERSION=${ver}"* ]]
    [[ "${output}" == *"${up}_SHA256_"* ]]
    [[ "${output}" != *"${up}_ARCH"* ]]
}

@test "build-args with a platform emit the per-arch pin digest" {
    # What: a platform selects arch + digest from the SOT.
    # Why: a pinned asset is per-platform.
    # From: Issue #1683
    local dep up arch sha
    dep="$(_pin_dep)"; up="${dep^^}"; up="${up//-/_}"
    arch="$(_ci_platform_apk_arch os/p1)"
    sha="$(_ci_block_entry_field external_versions "${dep}" "sha256_${arch}")"
    run bash "${CI_SH}" build-args "$(_pin_consumer)" "" os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ${up}_ARCH=${arch}"* ]]
    [[ "${output}" == *"--build-arg ${up}_SHA256=${sha}"* ]]
    [[ "${output}" != *"${up}_SHA256_"* ]]
}

@test "toolchain packages read the one SOT toolchain target" {
    # What: service lists ignored; two toolchains fail.
    # Why: the engine names no toolchain; the SOT holds one.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/other.yml"
    printf 'services:\n  svc-a:\n    packages:\n      - WRONG_SVC\n' > "${m}"
    printf 'build_toolchain:\n  tool-t:\n    packages:\n      - right-one\n' >> "${m}"
    CI_MANIFEST="${m}" run --separate-stderr bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 0 ]
    [ "${output}" = "right-one" ]
    printf '  tool-u:\n    packages:\n      - other\n' >> "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0011]"* ]]
}

@test "build-tools packages fails closed on an empty SOT list" {
    # What: no packages in the SOT must not pass.
    # Why: an empty list would blind the input check.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/nopkgs.yml"
    printf 'build_toolchain:\n  build-tools:\n    context: tools/build-tools\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0006"* ]]
}

@test "build-tools signature: same canonical apk state gives same sig" {
    # What: same inputs -> same signature; a bump moves it.
    # Why: weekly check rebuilds only on a real change.
    # From: Issue #1683
    local a b c
    a="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    b="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    c="$(bash "${CI_SH}" build-tools signature "sccache-0.16.0-r0")"
    [ -n "${a}" ]
    [ "${a}" = "${b}" ]
    [ "${a}" != "${c}" ]
}

@test "build-tools signature fails closed on empty apk state" {
    # What: a blank apk version state must not sign.
    # Why: a blank scan must never mint a stable signature.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools signature ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0004"* ]]
    run bash "${CI_SH}" build-tools signature "   "
    [ "${status}" -eq 2 ]
}

@test "build-tools signature moves on a dhclient value change" {
    # What: a dhclient version/checksum bump moves the sig.
    # Why: all emitted build-args must feed the signature.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/dh.yml" base changed
    base="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    local key sha
    key="$(_ci_build_matrix_platforms)"; key="sha256_$(_ci_platform_apk_arch "${key%%$'\n'*}")"
    sha="$(_ci_block_entry_field external_versions dhclient "${key}")"
    sed "s/${key}: ${sha}/${key}: $(printf 'd%.0s' {1..64})/" "${CI_MANIFEST}" > "${m}"
    changed="$(CI_MANIFEST="${m}" bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    [ -n "${base}" ]
    [ -n "${changed}" ]
    [ "${base}" != "${changed}" ]
}

@test "build-tools arches lists every build_matrix apk arch" {
    # What: the signature must cover every supported arch.
    # Why: an arm64-only change must be representable.
    # From: Issue #1683
    local p want=""
    while IFS= read -r p; do
        [ -n "${p}" ] && want="${want}$(_ci_platform_apk_arch "${p}")"$'\n'
    done <<< "$(_ci_build_matrix_platforms)"
    run --separate-stderr bash "${CI_SH}" build-tools arches
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(LC_ALL=C sort -u <<< "${want%$'\n'}")" ]
}

@test "build-tools consumes the channel the promote owner maps" {
    # What: SOT ref -> its channel; else default_channel.
    # Why: one ref->channel owner (promote), no second map.
    # From: Issue #1683 | PR #1858
    local rel ch dflt
    rel="$(_ci_release_ref)"; ch="$(_ci_channels_where ref "${rel}")"
    dflt="$(_ci_block_entry_field release "" default_channel)"
    export GITHUB_REPOSITORY=o/r GHCR_USERNAME=u GHCR_TOKEN=t
    _ci_registry_digest() { echo "sha256:${1##*:}"; }
    GITHUB_BASE_REF="${rel#refs/heads/}" run _ci_build_tools_resolve_image
    [[ "${output}" == *"@sha256:${ch}"* ]]
    GITHUB_BASE_REF=no-channel-ref run _ci_build_tools_resolve_image
    [[ "${output}" == *"@sha256:${dflt}"* ]]
    GITHUB_BASE_REF='' GITHUB_REF_NAME=feature/x run _ci_build_tools_resolve_image
    [[ "${output}" == *"@sha256:${dflt}"* ]]
}

@test "build-tools resolve-image reuses the published channel digest" {
    # What: NOOP -> channel digest, no apk resolve at all.
    # Why: normal runs reuse build-tools (AG-CI-010).
    # From: Issue #1683 | PR #1858
    export GITHUB_REPOSITORY=o/r GHCR_USERNAME=u GHCR_TOKEN=t
    _ci_registry_digest() { echo sha256:chan; }
    CI_APK_RESOLVE_CMD="$(_stub apk 'echo APK_CALLED; exit 9')"
    run _ci_build_tools_resolve_image
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-tools@sha256:chan"* ]]
    [[ "${output}" != *"APK_CALLED"* ]]
}

@test "build-tools signature moves on an arm64-only apk change" {
    # What: an aarch64-only change moves the sig.
    # Why: an arm64-only package bump must not be a NOOP.
    # From: Issue #1683
    local a b
    a="$(bash "${CI_SH}" build-tools signature "arch-a:sccache-0.15.0-r0 arch-b:sccache-0.15.0-r0")"
    b="$(bash "${CI_SH}" build-tools signature "arch-a:sccache-0.15.0-r0 arch-b:sccache-0.16.0-r0")"
    [ -n "${a}" ]
    [ "${a}" != "${b}" ]
}

@test "build-tools resolve-signature uses the injected resolver" {
    # What: the apk resolver is injectable for tests.
    # Why: signature logic is proven without a container.
    # From: Issue #1683
    local mock; mock="$(_stub apk.sh 'echo "sccache-0.15.0-r0 fake-$2-1.0-r0"')"
    run env CI_APK_RESOLVE_CMD="${mock}" bash "${CI_SH}" build-tools resolve-signature
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "apk resolver uses a clean per-arch root with the SOT repos" {
    # What: own root, arch keys, SOT repos; raw on failure.
    # Why: a foreign arch needs its own db, keys and tags.
    # From: Issue #1683 | PR #1858
    local log="${BATS_TEST_TMPDIR}/docker.log" repos="tag-a=http://repo.example.test/a"
    _stub docker 'echo "$*" >> "'"${log}"'"; if [ "${FAIL:-}" = 1 ]; then echo "ERROR: unable to select packages: zz"; exit 1; fi; echo "(1/1) Installing zz (9.9-r0)"' >/dev/null
    CI_APK_RESOLVE_CMD='' PATH="${BATS_TEST_TMPDIR}:${PATH}" run _ci_apk_resolve img/base arch-b zz "${repos}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"zz-9.9-r0"* ]]
    grep -q -- "-e ARCH=arch-b" "${log}"
    grep -qF -- "-e REPOS=${repos}" "${log}"
    grep -q -- "--keys-dir" "${log}"
    grep -q -- "--initdb" "${log}"
    [ "$(grep -c -- "-e HTTP_PROXY" "${log}")" -eq 0 ]
    : > "${log}"
    HTTP_PROXY=http://p:3128 CI_APK_RESOLVE_CMD='' PATH="${BATS_TEST_TMPDIR}:${PATH}" \
        run _ci_apk_resolve img/base arch-b zz
    [ "${status}" -eq 0 ]
    grep -q -- "-e HTTP_PROXY -e ARCH=arch-b" "${log}"
    : > "${log}"
    FAIL=1 CI_APK_RESOLVE_CMD='' CI_RETRY_BACKOFF_BASE_SECONDS=0 PATH="${BATS_TEST_TMPDIR}:${PATH}" \
        run _ci_apk_resolve img/base arch-b zz
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-BUILDTOOLS-0020]"* ]]
    [[ "${output}" == *"unable to select packages"* ]]
    [ "$(grep -c -- "-e ARCH=arch-b" "${log}")" -eq 1 ]
    # What: SOT keys reach apk as base64; a bad pin fails.
    # Why: a tagged repo resolves only with its pinned key.
    # From: Issue #1683 | PR #1858
    local key="${BATS_TEST_TMPDIR}/sig.pub" sha b64
    printf 'KEYDATA\n' > "${key}"; sha="$(sha256sum "${key}")"; sha="${sha%% *}"; b64="$(base64 -w0 "${key}")"
    : > "${log}"
    CI_HTTP_DOWNLOAD_CMD="$(_stub dl "cp '${key}' \"\$2\"")" CI_APK_RESOLVE_CMD='' PATH="${BATS_TEST_TMPDIR}:${PATH}" \
        run _ci_apk_resolve img/base arch-b zz "${repos}" "http://k.example/sig.pub=${sha}"
    [ "${status}" -eq 0 ]
    grep -qF -- "-e KEYS=sig.pub=${b64}" "${log}"
    : > "${log}"
    CI_HTTP_DOWNLOAD_CMD="$(_stub dl "cp '${key}' \"\$2\"")" CI_APK_RESOLVE_CMD='' PATH="${BATS_TEST_TMPDIR}:${PATH}" \
        run _ci_apk_resolve img/base arch-b zz "${repos}" "http://k.example/sig.pub=$(_test_digest a | cut -d: -f2)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-FETCH-0003"* ]]
    [ ! -s "${log}" ]
}

@test "service build-args carry SOT tagged repos and repo keys" {
    # What: branch from the alpine pin tag; keys verbatim.
    # Why: the SOT pin owns the version the repo follows.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/rk.yml" name tag want
    while IFS='|' read -r name tag want; do
        printf 'base_images:\n  alpine: "img:%s@sha256:%s"\nservices:\n  svc:\n    context: c\n    build_type: apk\n    apk_repositories:\n      - x=http://h.example/@ALPINE_BRANCH@/main\n    apk_keys:\n      - https://k.example/s.pub=abc\n' \
            "${tag}" "$(_test_digest a | cut -d: -f2)" > "${m}"
        CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc --bare
        case "${want}" in
            ok) [ "${status}" -eq 0 ] && [[ "${output}" == *"APK_TAGGED_REPOS=x=http://h.example/v${tag}/main"* ]] \
                && [[ "${output}" == *"APK_KEYS=https://k.example/s.pub=abc"* ]] ;;
            *) [ "${status}" -ne 0 ] && [[ "${output}" == *"${want}"* ]] ;;
        esac || { echo "${name}: rc ${status}: ${output}"; return 1; }
    done <<'CASES'
release-tag|3.24|ok
mutable-tag|latest|CI-ERROR-BUILDARGS-0016
CASES
    # What: an unreadable key list fails build-args.
    # Why: a reader error must not pass as "no keys".
    # From: Issue #1683 | PR #1858
    printf 'base_images:\n  alpine: "img:3.24@sha256:%s"\nservices:\n  svc:\n    context: c\n    build_type: apk\n    apk_keys:\n      - "https://k.example/s.pub=abc\n' \
        "$(_test_digest a | cut -d: -f2)" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args svc --bare
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"[CI-ERROR-CORE-0108]"* ]]
    [[ "${output}" != *"APK_KEYS="* ]]
}

@test "build-tools resolve-signature fails closed on a missing central base image" {
    # What: missing base image must fail closed here.
    # Why: errexit must not swallow the fail-closed path.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/no-resolve-alpine.yml"
    grep -v '^  alpine:' "${CI_MANIFEST}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools resolve-signature
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-BUILDARGS-0003] arg="ALPINE_IMAGE" key="base_images.alpine"'* ]]
}

@test "build-tools rejects an unknown subcommand (fail closed)" {
    # What: An unknown sub must not silently succeed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build-tools bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0003"* ]]
}

@test "build-tools image is the base ref from the SOT registry" {
    # What: The base build-tools ref from the SOT.
    # Why: One registry-host owner, no env fallback.
    # From: Issue #1683
    GITHUB_REPOSITORY=owner/fixture-repo run --separate-stderr bash "${CI_SH}" build-tools image
    [ "${status}" -eq 0 ]
    [ "${output}" = "registry.example.test/owner/fixture-repo/build-tools" ]
}

@test "oci labels emit provenance from the SOT and env" {
    # What: revision/source/licenses/base from SOT+env.
    # Why: Provenance labels have one owner (Plan §7).
    # From: Issue #1683
    _build_fixture
    GITHUB_SHA=abc123 GITHUB_SERVER_URL=https://git.example.test GITHUB_REPOSITORY=Owner/Fixture-Repo \
        run _ci_oci_labels tool-t
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"image.revision=abc123"* ]]
    [[ "${output}" == *"image.version=abc123"* ]]
    [[ "${output}" == *"image.source=https://git.example.test/owner/fixture-repo"* ]]
    [[ "${output}" == *"image.licenses=AGPL-3.0-or-later"* ]]
    [[ "${output}" == *"image.title=tool-t"* ]]
    [[ "${output}" == *"image.description=fixture-repo tool-t image"* ]]
    [[ "${output}" == *"image.base.name=registry.example.test/base-x"* ]]
    [[ "${output}" == *"image.base.digest=sha256:$(printf '2%.0s' {1..64})"* ]]
    sed -i 's/^  base-x: .*//' "${CI_MANIFEST}"
    run _ci_oci_labels svc-a
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-BUILD-0014]"* ]]
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
        [[ "${output}" == *"site="* ]] && [[ "${output}" == *"not a git repository"* ]]
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
    _tool_stub "${bin}" awk <<'STUB'
echo "awk: fatal: cannot open file for reading" >&2; exit 2
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

@test "check mutable-refs fails a floating action version via ci.sh" {
    # What: ci.sh owns the pin invariant; bats calls it.
    # Why: no :latest / @vN; SHA/digest-pinned only.
    # From: Issue #1683
    printf 'jobs:\n  x:\n    steps:\n      - uses: foo/bar@abc1234\n' > "${BATS_TEST_TMPDIR}/ok.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/ok.yml"
    [ "${status}" -eq 0 ]
    printf 'jobs:\n  x:\n    steps:\n      - uses: foo/bar@v4\n' > "${BATS_TEST_TMPDIR}/bad.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/bad.yml"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0008"* ]]
}

@test "check mutable-refs default scan includes composite-action action.yml" {
    # What: Default glob covers .github/actions/action."
    # Why: Composite action @vN refs must be guarded.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/mrepo"
    mkdir -p "${r}/.github/actions/x"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: foo/bar@v4\n' > "${r}/.github/actions/x/action.yml"
    ( cd "${r}" && git init -q && git add -A )
    run bash -c "cd '${r}' && bash '${CI_SH}' check mutable-refs"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"action-@vN"* ]]
    printf 'runs:\n  using: composite\n  steps:\n    - uses: foo/bar@abc1234def\n' > "${r}/.github/actions/x/action.yml"
    ( cd "${r}" && git add -A )
    run bash -c "cd '${r}' && bash '${CI_SH}' check mutable-refs"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mutable-refs=clean"* ]]
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
    local f="${BATS_TEST_TMPDIR}/p.sh" g=grep h=head line
    for line in "x=\"\$(seq 1 9)\"" 'a || grep -q x f' \
                '[ "$(seq 9 | grep -c 3)" -eq 1 ]' 'seq 9 | sed -n "s/3/x/p"'; do
        printf 'set -o pipefail\n%s\n' "${line}" > "${f}"
        run bash "${CI_SH}" check pipefail-early-exit "${f}"
        [ "${status}" -eq 0 ]
    done
    for line in "seq 9 | ${g} -q 3" "seq 9 | ${g} -Eiq 3" "seq 9 | ${g} --quiet 3" "seq 9 | ${h} -1"; do
        printf 'set -o pipefail\n%s\n' "${line}" > "${f}"
        run bash "${CI_SH}" check pipefail-early-exit "${f}"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"CI-ERROR-CHECK-0011"* ]]
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
    local m="${BATS_TEST_TMPDIR}/m.yml" t
    printf 'services:\n  svc-a:\n    context: a\nbuild_toolchain:\n  tc-x:\n    context: t\nexternal_services:\n  ext-y:\n    image: i\npr_policy:\n  title_types: [feat, fix, security]\n  title_scopes_extra: [area-z]\n' > "${m}"
    for t in "feat(svc-a): x" "fix(tc-x)!: y" "feat(ext-y): x" "feat(area-z): x" \
             "security: z" "feat!: x" $'feat(svc-a): crlf\r'; do
        CI_MANIFEST="${m}" run bash "${CI_SH}" check pr-title "${t}"
        [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=ok"* ]] || { echo "want ok: ${t}"; false; }
    done
    for t in "feat(bogus): x" "chore(svc-a): x" "not conventional"; do
        CI_MANIFEST="${m}" run bash "${CI_SH}" check pr-title "${t}"
        [ "${status}" -eq 0 ]; [[ "${output}" == *"CI-ERROR-CHECK-0086"*"pr-title=warn"* ]]
        CI_MANIFEST="${m}" PR_TITLE_LINT_MODE=block run bash "${CI_SH}" check pr-title "${t}"
        [ "${status}" -eq 1 ]; [[ "${output}" == *"reason=\"PR title convention\""* ]]
        CI_MANIFEST="${m}" PR_TITLE_LINT_MODE=block PR_DRAFT=true run bash "${CI_SH}" check pr-title "${t}"
        [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=warn-draft"* ]]
    done
    CI_MANIFEST="${m}" PR_AUTHOR='dependabot[bot]' run bash "${CI_SH}" check pr-title "anything"
    [[ "${output}" == *"pr-title=skip-dependabot"* ]]
    CI_MANIFEST="${m}" run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 2 ]; [[ "${output}" == *"CI-ERROR-CHECK-0012"* ]]
    sed -i '/title_types/d' "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" check pr-title "feat: x"
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

@test "check pr-template requires every current template section filled" {
    # What: ci.sh derives required sections from template.
    # Why: Hardcoded list drifts with template changes.
    # From: Issue #1683
    local body='## Summary
Fixes the thing.

## Linked Issues
Refs #1

## What This Actually Changes
Before/after text.

## What This PR Fixes / Adds
The bug.

## What Changed In Code
Touched foo.sh.

## Why This Matters For Users / Operators
Operators see X.

## Scope Boundaries
Does not touch Y.

## Risk / Rollback / Follow-up
Low risk, revert commit.

## Local Scope Evidence
```text
foo.sh
```

## Validation
```bash
bash foo.sh
```

## Type of change
- [x] Bug fix

## Changelog
Fixed foo.'
    printf '%s' "${body}" > "${BATS_TEST_TMPDIR}/full.md"
    run bash "${CI_SH}" check pr-template "${BATS_TEST_TMPDIR}/full.md"
    [ "${status}" -eq 0 ]
}

@test "check pr-template fails an unfilled section and an unchecked type-of-change" {
    # What: Untouched heading or unchecked box must fail.
    # Why: Legacy missed checkbox case in validation.
    # From: Issue #1683
    local body='## Summary
Fixes the thing.

## Type of change
- [ ] Bug fix
- [ ] New feature
'
    printf '%s' "${body}" > "${BATS_TEST_TMPDIR}/bad.md"
    run bash "${CI_SH}" check pr-template "${BATS_TEST_TMPDIR}/bad.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0089"* ]]
    [[ "${output}" == *"Linked Issues: heading not found"* ]]
    [[ "${output}" == *"Type of change: no checkbox marked"* ]]
}

@test "check workflow-line-limit fails a workflow file over the line ceiling" {
    # What: ci.sh owns GitHub dispatch-cliff size limit.
    # Why: GitHub drops runs for oversized workflow files.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/wf"; mkdir -p "${d}"
    printf 'name: ok\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
        > "${d}/ok.yml"
    run bash "${CI_SH}" check workflow-line-limit "${d}"
    [ "${status}" -eq 0 ]
    {
        printf 'name: big\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n'
        local _i
        for _i in $(seq 1 9000); do printf '      - run: echo hi\n'; done
    } > "${d}/big.yml"
    run bash "${CI_SH}" check workflow-line-limit "${d}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0090"* ]]
}

@test "check pr-tracking-metadata: context, labels, milestone, fork, draft" {
    # What: AG-GH-008 gaps fail; fork/draft warn; SOT board.
    # Why: never report metadata the PR has; wiring != gap.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf 'pr_policy:\n  project_number: 7\n' > "${m}"
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
}

@test "check pr-tracking-metadata board lookup: failed, hit, miss" {
    # What: any lookup failure fails; SOT number hit passes.
    # Why: board owner is the repo owner, never a literal.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin" m="${BATS_TEST_TMPDIR}/m.yml" mode
    mkdir -p "${bin}"
    printf 'pr_policy:\n  project_number: 7\n' > "${m}"
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
        '  long_lived_patterns:' '    - "rel-*"' > "${m}"
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
    OB_MORE='{"data":{"repository":{"issue":{"comments":{"nodes":[{"body":"late inlong"}]}}}}}'
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
    # What: no no-PR candidate -> clean, counts, no issue call.
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
    # Why: a failed lookup must never read as orphan or clean.
    # From: Issue #1683 | PR #1858
    local case setup want
    while IFS='|' read -r case setup want; do
        _ob_setup
        OB_REFS="$(_ob_page "lost|${OB_OLD}|0|a")"; OB_ISSUES="$(_ob_issues)"
        OB_MORE='{"data":{"repository":{"issue":{"comments":{"nodes":[]}}}}}'
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
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
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
    ! grep -q '^pr-title|' "${log}"
}

@test "ci-bats check skips docs-only and nested runs with a reason" {
    # What: docs-only and nested bats are NOT-RUN, not PASS.
    # Why: a skip names why; no suite runs inside itself.
    # From: Issue #1683 | PR #1858
    run _ci_check_ci_bats README.md
    [ "${status}" -eq 0 ]
    [ "${output}" = 'ci-bats=NOT-RUN reason="already inside a bats run; no nested suite"' ]
    BATS_TEST_FILENAME="" CI_SCAN_SCOPE_FILTER=1 run _ci_check_ci_bats README.md docs/x.md
    [ "${status}" -eq 0 ]
    [ "${output}" = 'ci-bats=NOT-RUN reason="docs-only change" changed=2' ]
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

@test "docs-only is true only when every changed path is docs" {
    # What: a docs-only change is a NOOP (§63).
    # Why: container jobs must not run on docs-only.
    # From: Issue #1683
    _ci_docs_only fixture-note.md docs/fixture-asset
    run ! _ci_docs_only fixture-note.md fixture-src/code.rs
    run ! _ci_docs_only
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
    CI_SHELLCHECK_CMD="$(_stub sc 'exit 1')" CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
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
    CI_SHELLCHECK_CMD="$(_stub sc "echo \"\$#:\$1\" >> '${log}'")" CHANGED_FILES="${cf}" \
        run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shellcheck=clean files=2"* ]]
    [ "$(cat "${log}")" = "$(printf '1:%s\n1:%s' "${a}" "${b}")" ]
    CI_SHELLCHECK_CMD="$(_stub sc2 'echo raw-oom >&2; exit 137')" CHANGED_FILES="${cf}" \
        run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0113"*"rc=137"* ]]
    [[ "${output}" == *"raw-oom"* ]]
    [[ "${output}" != *"CI-ERROR-CHECK-0056"* ]]
}

@test "check actionlint passes clean and fails on findings" {
    # What: injected actionlint; prove pass/fail.
    # Why: Real actionlint needs toolchain; hook it.
    # From: Issue #1683
    CI_ACTIONLINT_CMD="$(_stub al 'exit 0')" run bash "${CI_SH}" check actionlint
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"actionlint=clean"* ]]
    CI_ACTIONLINT_CMD="$(_stub al2 'exit 1')" run bash "${CI_SH}" check actionlint
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0057"* ]]
}

@test "check cargo-audit passes clean, fails on advisory and on warnings" {
    # What: Injected auditor; prove pass/fail.
    # Why: Real cargo audit needs toolchain; hook it.
    # From: Issue #1683
    CI_CARGO_AUDIT_CMD="$(_stub aud 'exit 0')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo-audit=clean"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub aud2 'echo "error: vulnerability RUSTSEC-x"; exit 1')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0055"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub aud3 'echo "warning: yanked crate"; exit 0')" run bash "${CI_SH}" check cargo-audit
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
    local r="${BATS_TEST_TMPDIR}/dfrepo" s ctx n=0
    while IFS= read -r s; do
        [ "$(ci_service_field "$s" build_type)" = rust ] || continue
        ctx="$(ci_service_field "$s" context)"
        mkdir -p "${r}/${ctx}"
        case "${n}" in
            0) printf 'FROM alpine\nRUN cargo install sccache\n' > "${r}/${ctx}/Dockerfile" ;;
            1) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nENV CARGO_BUILD_JOBS=4\n' > "${r}/${ctx}/Dockerfile" ;;
            *) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nARG PROJECT_CARGO_LTO=\n' > "${r}/${ctx}/Dockerfile" ;;
        esac
        n=$((n + 1))
    done < <(ci_services)
    run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0058"* ]]
    [[ "${output}" == *"CI-ERROR-CHECK-0060"* ]]
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

@test "ci.sh feeds no loop from a process substitution" {
    # What: no '< <(' producer outside comments in ci.sh.
    # Why: wait on its pid races bash's reaping (rc 127).
    # From: Issue #1683 | PR #1858
    run awk '!/^[[:space:]]*#/ && /< <\(/ { print FILENAME ":" FNR ": " $0 }' "${CI_SH}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "version consumers derive from SOT consumer and build_args" {
    # What: dep, Dockerfile and keys come from the SOT.
    # Why: no engine-side consumer list; missing keys fail.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf '%s\n' 'services:' '  svc-a:' '    context: dir/a' \
        'external_versions:' '  dep-a:' '    consumer: svc-a' '    build_args: [version, k2]' \
        '  dep-b:' '    version: x' > "${m}"
    CI_MANIFEST="${m}" run _ci_version_consumers
    [ "${status}" -eq 0 ]
    [ "${output}" = "dep-a|dir/a/Dockerfile|version k2" ]
    printf '%s\n' 'services:' '  svc-a:' '    context: dir/a' \
        'external_versions:' '  dep-a:' '    consumer: svc-a' > "${m}"
    CI_MANIFEST="${m}" run _ci_version_consumers
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-VERSION-0010]"* ]]
}

@test "identity prints no line when the id computation fails" {
    # What: a failed id is rc 2 and no identity= line.
    # Why: an empty identity must never look like a result.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    printf '%s\n' 'services:' '  svc-a:' '    context: dir/a' '    build_type: type-x' \
        'build_matrix:' '  platforms: [os/p1]' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" identity svc-a os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-IDENTITY-0004]"* ]]
    [[ "${output}" != *"identity="* ]]
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
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
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

@test "check naming-consistency requires every allowlist name as a real container_name" {
    # What: ci.sh owns cross-file name-consistency gate.
    # Why: socket-proxy denies unknown container names.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${r}/dep" "${r}/inst" "${r}/scripts/untracked"
    _stack_fixture "${r}"
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-proxy\n' \
        > "${r}/dep/c.yml"
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-proxy${LANCACHE_CONTAINER_SUFFIX:-}\n' \
        > "${r}/inst/c.yml"
    printf 'acl lancache_container path,url_dec -m reg ^/containers/(lancache-proxy)(/|$)\nacl lancache_lifecycle path,url_dec -m reg ^/containers/lancache-proxy/(start|stop|restart|wait)$\n' \
        > "${r}/scripts/untracked/docker-socket-proxy.sh"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 0 ]
    mkdir -p "${r}/services/watchdog/src"
    printf 'const DEFAULT_PROXY: &str = "lancache-other";\n' \
        > "${r}/services/watchdog/src/config.rs"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"names 'lancache-other' not in allowlist"* ]]
    printf 'const DEFAULT_PROXY: &str = "lancache-proxy";\n' \
        > "${r}/services/watchdog/src/config.rs"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 0 ]
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-wrong\n' \
        > "${r}/dep/c.yml"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0096"* ]]
    # What: no match is a named violation via the CLI.
    # Why: errexit must not end the check without a code.
    # From: Issue #1683 | PR #1858
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-proxy\n' \
        > "${r}/dep/c.yml"
    printf 'fn main() {}\n' > "${r}/services/watchdog/src/config.rs"
    run bash "${CI_SH}" check naming-consistency "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0096"* ]]
    [[ "${output}" == *"no const lancache-* container names found"* ]]
    printf 'acl lancache_container path,url_dec -m reg ^/containers/x\n' \
        > "${r}/scripts/untracked/docker-socket-proxy.sh"
    run bash "${CI_SH}" check naming-consistency "${r}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not parse lancache-* allowlist names"* ]]
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
    # What: migrated from check-proxy-cache-env-doc-drift.
    # Why: rewritten in ci.sh; real config/docs must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy-cache-env-doc-drift=clean"* ]]
}

@test "check proxy-cache-env-doc-drift fails a real default mismatch" {
    # What: proxy.env's value disagrees with its doc row.
    # Why: Copied default can go stale.
    # From: Issue #1683 | PR #1858
    local env="${BATS_TEST_TMPDIR}/proxy.env" doc="${BATS_TEST_TMPDIR}/arch.md"
    printf 'CACHE_MEM_MB=999\n' > "${env}"
    printf "| \`CACHE_MEM_MB\` | \`512\` | some description |\n" > "${doc}"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift "${env}" "${doc}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0023"* ]]
    [[ "${output}" == *"proxy.env=999 vs doc=512"* ]]
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

@test "proxy-cache-env-doc-drift reads proxy env_file from the deploy compose" {
    # What: env_file from compose; 0/2 files, bad doc fail.
    # Why: the compose owns the path; ci.sh keeps no copy.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/pce"
    local bin="${BATS_TEST_TMPDIR}/pcebin"
    local name ef want
    mkdir -p "${r}/dep" "${r}/docs"
    printf 'CACHE_X=1\n' > "${r}/dep/p.env"
    printf 'CACHE_X=1\n' > "${r}/dep/q.env"
    printf '| `CACHE_X` | `2` | x |\n' > "${r}/docs/architecture-ng.md"
    export CI_REPO_ROOT="${r}" CI_COMPOSE_FILE=dep/c.yml
    while IFS='|' read -r name ef want; do
        printf 'services:\n  proxy:\n    image: x\n%b' "${ef}" > "${r}/dep/c.yml"
        run bash "${CI_SH}" check proxy-cache-env-doc-drift
        if [ "${status}" -eq 0 ]; then
            echo "${name}: passed"
            return 1
        fi
        if [[ "${output}" != *"${want}"* ]]; then
            echo "${name}: ${output}"
            return 1
        fi
    done <<'CASES'
one|    env_file: [./p.env]\n|CACHE_X: proxy.env=1 vs doc=2
two|    env_file: [./p.env, ./q.env]\n|CI-ERROR-CHECK-0111
none||CI-ERROR-CHECK-0111
bad|  bogus: [\n|CI-ERROR-CHECK-0110
CASES
    printf 'services:\n  proxy:\n    image: x\n    env_file: [./p.env]\n' > "${r}/dep/c.yml"
    _fail_stub "${bin}" grep
    PATH="${bin}:${PATH}" FAIL_MATCH="/docs/architecture-ng.md" \
        run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"*"read error"* ]]
}

@test "check dependabot-docker-base-consistency passes on the real repo" {
    # What: migrated from the legacy dependabot check.
    # Why: rewritten in ci.sh; the real group must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check dependabot-docker-base-consistency
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependabot-docker-base-consistency=clean"* ]]
}

@test "check dependabot-docker-base-consistency maps each fixture" {
    # What: one dependabot fixture per row: rc and codes.
    # Why: every row shares one fixture, only inputs vary.
    # From: Issue #1683 | PR #1858
    local name dirs dfa dfb rc want r w
    local -a ws
    while IFS='|' read -r name dirs dfa dfb rc want; do
        r="${BATS_TEST_TMPDIR}/ddb-${name}"
        mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
        case "${dirs}" in
            a,b) printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n' ;;
            a) printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directory: /services/a\n' ;;
            gone) printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directory: /services/gone\n' ;;
            nodir) printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n' ;;
            actions) printf 'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    directory: /\n' ;;
        esac > "${r}/.github/dependabot.yml"
        [ "${dirs}" = noyml ] && rm -f "${r}/.github/dependabot.yml"
        [ "${dfa}" = - ] || printf '%b' "${dfa}" > "${r}/services/a/Dockerfile"
        [ "${dfb}" = - ] || printf '%b' "${dfb}" > "${r}/services/b/Dockerfile"
        run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
global-arg|a,b|ARG BASE=alpine:3.24\nFROM ${BASE}\n|FROM alpine:3.24\n|0|=clean dockerfiles=2 blocks=1
unbraced-arg|a,b|ARG BASE=alpine:3.24\nFROM $BASE\n|FROM alpine:3.24\n|0|=clean dockerfiles=2 blocks=1
bare-sot-arg|a,b|ARG ALPINE_IMAGE\nFROM ${ALPINE_IMAGE}\n|ARG ALPINE_IMAGE\nFROM ${ALPINE_IMAGE}\n|0|=clean dockerfiles=2 blocks=1
scratch-fallback|a,b|ARG ALPINE_IMAGE\nFROM ${ALPINE_IMAGE:-scratch}\n|ARG ALPINE_IMAGE\nFROM ${ALPINE_IMAGE}\n|0|=clean dockerfiles=2 blocks=1
stage-alias|a,b|FROM alpine:3.24 AS builder\nRUN true\nFROM builder\n|FROM alpine:3.24\n|0|=clean dockerfiles=2 blocks=1
heredoc-from|a,b|FROM alpine:3.24\nRUN <<EOT\nFROM should-be-ignored\nEOT\n|FROM alpine:3.24\n|0|=clean dockerfiles=2 blocks=1
last-from-lower|a,b|FROM golang:1 AS builder\nRUN true\nfrom alpine:3.24\n|FROM alpine:3.24 AS final\n|0|=clean dockerfiles=2 blocks=1
drift|a,b|FROM alpine:3.24\n|FROM alpine:3.20\n|1|CI-ERROR-CHECK-0032;diverges;alpine:3.24;alpine:3.20
no-from|a,b|RUN true\n|FROM alpine:3.24\n|2|CI-ERROR-CHECK-0031
unresolved-arg|a|FROM ${UNKNOWN_ARG}\n|-|2|CI-ERROR-CHECK-0099;${UNKNOWN_ARG}
missing-dockerfile|gone|-|-|2|CI-ERROR-CHECK-0030;/services/gone/Dockerfile
block-without-dir|nodir|-|-|2|CI-ERROR-CHECK-0029
no-docker-block|actions|-|-|2|CI-ERROR-CHECK-0028
no-dependabot-yml|noyml|-|-|2|CI-ERROR-CHECK-0027
CASES
}

# What: neutral deploy + installer compose for a fixture.
# Why: checks derive both from owners, never real paths.
# From: Issue #1683 | PR #1858
_stack_fixture() {
    export CI_COMPOSE_FILE=dep/c.yml
    mkdir -p "$1/dep" "$1/inst"
    printf 'QUICKSTART_COMPOSE="$SCRIPT_DIR/%s"\n' inst/c.yml >> "$1/setup.sh"
}

@test "installer compose is read from setup.sh, fail-closed" {
    # What: one SCRIPT_DIR form reads; other forms fail.
    # Why: setup.sh owns the installer compose; CI derives.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/inst" name body want rc
    mkdir -p "${r}"
    while IFS='|' read -r name body want rc; do
        rm -f "${r}/setup.sh"
        [ "${body}" = none ] || printf '%b' "${body}" > "${r}/setup.sh"
        run _ci_installer_compose "${r}"
        [ "${status}" -eq "${rc}" ] || { echo "${name}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${name}: ${output}"; return 1; }
    done <<'CASES'
ok|x=1\nQUICKSTART_COMPOSE="$SCRIPT_DIR/d/q/c.yml"\n|d/q/c.yml|0
none|none|CI-ERROR-CORE-0102|2
absent|x=1\n|CI-ERROR-CORE-0104|2
twice|QUICKSTART_COMPOSE="$SCRIPT_DIR/a"\nQUICKSTART_COMPOSE="$SCRIPT_DIR/b"\n|CI-ERROR-CORE-0104|2
form|QUICKSTART_COMPOSE=/abs/c.yml\n|CI-ERROR-CORE-0105|2
CASES
}

# What: seed a minimal prebuilt-only prod/quickstart tree.
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
        '  compose_validation_env: LISTEN_IP=fx' > "${m}"
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
    mkdir -p "${root}/dep" "${root}/inst" \
        "${root}/services/dns" "${root}/services/ui/src/routes"
    for cf in dep/c.yml inst/c.yml; do
        cat > "${root}/${cf}" <<'EOF'
        tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"
        chown 10001:10001 "$$tmp_nats_conf"
        mv "$$tmp_nats_conf" /etc/nats/nats.conf
EOF
    done
    cat > "${root}/services/ui/src/routes/secondaries.rs" <<'EOF'
fn write_nats_conf_atomically() {}
fs::rename(&tmp_path, target)
EOF
    cat > "${root}/services/dns/entrypoint.sh" <<'EOF'
render_template_atomic
mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"
EOF
    cat > "${root}/setup.sh" <<'EOF'
write_generated_runtime_file "${secondary_dir}/docker-compose.yml"
write_env_file "${secondary_dir}/.env"
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

# What: seed a deny-by-default docker-socket-proxy tree.
# Why: shared by the docker-socket-proxy checks below.
# From: Issue #1683 | PR #1858
_socket_proxy_fixture() {
    local root="$1" cf
    mkdir -p "${root}/dep" "${root}/inst" "${root}/scripts/untracked"
    _stack_fixture "${root}"
    for cf in dep/c.yml inst/c.yml; do
        printf '      - scripts/untracked/docker-socket-proxy.sh:/usr/local/bin/lancache-docker-socket-proxy.sh:ro\n' > "${root}/${cf}"
    done
    cat > "${root}/scripts/untracked/docker-socket-proxy.sh" <<'EOF'
acl safe_service_restart x
acl safe_dhcp_action x
acl safe_probe_action x
acl safe_netdata_restart x
lancache-netdata/restart
acl lancache_container x
lancache-dns-standard|lancache-dns-ssl
lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart
lancache-dhcp|lancache-dhcp-proxy)/(start|stop)
lancache-dhcp-probe/(start|stop|wait)
http-request deny if docker_container_path !lancache_container
http-request deny
EOF
}

@test "check docker-socket-proxy passes a deny-by-default allowlist" {
    # What: Required rules present, no broad.
    # Why: the socket proxy must stay deny-by-default.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-ok"
    _socket_proxy_fixture "${r}"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"docker-socket-proxy=clean"* ]]
}

@test "check docker-socket-proxy fails when Docker exec is enabled" {
    # What: a compose re-enables the banned EXEC endpoint.
    # Why: exec re-exposes arbitrary command execution.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-exec"
    _socket_proxy_fixture "${r}"
    printf '        EXEC: "1"\n' >> "${r}/dep/c.yml"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"exec is banned"* ]]
}

@test "check docker-socket-proxy fails a forbidden broad container rule" {
    # What: Broad rule re-enters allowlist.
    # Why: generic container APIs must stay denied.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-broad"
    _socket_proxy_fixture "${r}"
    printf '/containers/json\n' >> "${r}/scripts/untracked/docker-socket-proxy.sh"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"forbidden broad rule"* ]]
}

# What: seed a quickstart tree with required env keys set.
# Why: shared by the quickstart-required-env checks below.
# From: Issue #1683 | PR #1858
_qs_required_env_fixture() {
    local root="$1"
    mkdir -p "${root}/inst"
    _stack_fixture "${root}"
    printf 'services:\n  x:\n    environment:\n      A: ${A:?set A}\n      B: ${B:?set B}\n' > "${root}/inst/c.yml"
    printf 'A=1\nB=2\n' > "${root}/inst/.env"
}

@test "check quickstart-required-env passes when all required keys are set" {
    # What: Required ${VAR:?} keys non-empty.
    # Why: a required-but-unset key breaks compose at start.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-ok"
    _qs_required_env_fixture "${r}"
    run bash "${CI_SH}" check quickstart-required-env "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"quickstart-required-env=clean"* ]]
}

@test "check quickstart-required-env fails when a required key is unset" {
    # What: a required ${VAR:?} key is missing from .env.
    # Why: quickstart would fail at compose interpolation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-bad"
    _qs_required_env_fixture "${r}"
    printf 'A=1\n' > "${r}/inst/.env"
    run bash "${CI_SH}" check quickstart-required-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"define non-empty B"* ]]
}

# What: Seed DHCP tree for env/PXE.
# Why: shared by the dhcp-proxy-env checks below.
# From: Issue #1683 | PR #1858
_dhcp_proxy_env_fixture() {
    local root="$1" k
    mkdir -p "${root}/dep" "${root}/inst" \
        "${root}/config/prod" "${root}/services/dhcp-proxy"
    _stack_fixture "${root}"
    cat > "${root}/dep/c.yml" <<'EOF'
services:
  dhcp-proxy:
    image: x
    env_file:
      - ../../config/prod/dhcp-proxy.env
EOF
    : > "${root}/config/prod/dhcp-proxy.env"
    : > "${root}/inst/.env"
    for k in DHCP_PROXY_INTERFACE DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN \
        DHCP_PROXY_BOOT_FILENAME DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS \
        DHCP_PROXY_PXE_BOOT_SERVER DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI; do
        printf '%s=\n' "${k}" >> "${root}/config/prod/dhcp-proxy.env"
        printf '%s=\n' "${k}" >> "${root}/inst/.env"
    done
    cat > "${root}/inst/c.yml" <<'EOF'
        - DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE:-}
        - DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS:-}
        - DHCP_PROXY_PXE_BOOT_SERVER=${DHCP_PROXY_PXE_BOOT_SERVER:-}
        - DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS:-}
        - DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI:-}
EOF
    cat > "${root}/services/dhcp-proxy/entrypoint.sh" <<'EOF'
_dhcp_proxy_render_optional_directives() { :; }
_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf
EOF
    : > "${root}/services/dhcp-proxy/dnsmasq.conf.template"
}

@test "check dhcp-proxy-env passes a compliant env/PXE tree" {
    # What: env_file + all PXE keys present.
    # Why: the dnsmasq relay/proxy surface must stay intact.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-ok"
    _dhcp_proxy_env_fixture "${r}"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dhcp-proxy-env=clean"* ]]
}

@test "check dhcp-proxy-env fails a missing optional key" {
    # What: Optional dnsmasq key absent.
    # Why: the whole optional surface must be declared.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-key"
    _dhcp_proxy_env_fixture "${r}"
    grep -v 'DHCP_PROXY_ROUTER' "${r}/config/prod/dhcp-proxy.env" > "${r}/config/prod/dhcp-proxy.env.tmp"
    mv "${r}/config/prod/dhcp-proxy.env.tmp" "${r}/config/prod/dhcp-proxy.env"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DHCP_PROXY_ROUTER"* ]]
}

@test "check dhcp-proxy-env fails compose environment interpolation" {
    # What: Prod DHCP uses env, not file.
    # Why: env_file contract; loses keys.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-env"
    _dhcp_proxy_env_fixture "${r}"
    cat > "${r}/dep/c.yml" <<'EOF'
services:
  dhcp-proxy:
    image: x
    environment:
      - DHCP_SUBNET_START=${DHCP_SUBNET_START}
EOF
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"dhcp-proxy"* ]]
}

@test "check dhcp-proxy-env fails cleanly when an input file is missing" {
    # What: Missing compose/env/entrypoint.
    # Why: must not read as a dhcp-proxy contract violation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-miss"
    _dhcp_proxy_env_fixture "${r}"
    rm "${r}/services/dhcp-proxy/dnsmasq.conf.template"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"input missing"* ]]
}

@test "check vex-drift passes valid non-empty OpenVEX" {
    # What: generate-vex.sh emits JSON with statements.
    # Why: the generator smoke test's core success path.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-ok"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "{\"statements\":[{\"x\":1}]}"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vex-drift=clean"* ]]
}

@test "check vex-drift fails invalid JSON" {
    # What: generate-vex.sh emits non-JSON output.
    # Why: a broken generator must fail closed.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-bad"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "not json"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid JSON"* ]]
}

@test "check vex-drift fails entries with zero statements" {
    # What: real ignore entries but an empty statement list.
    # Why: Empty output broken, JSON or not.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-empty"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "{\"statements\":[]}"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"0 VEX statements"* ]]
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
        printf 'run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"\n'
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
    # Why: Pinned fails; mutable via stack.
    # From: Issue #1683
    run bash "${CI_SH}" check image-channel-resolution "${BATS_TEST_DIRNAME}/../.."
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"image-channel-resolution=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/icr-bad"; mkdir -p "${r}"
    printf 'echo noop\n' > "${r}/setup.sh"
    run bash "${CI_SH}" check image-channel-resolution "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0105"* ]]
}

@test "migrate_env_for_update repairs every empty required key" {
    # What: SOT repair keys non-empty.
    # Why: Empty breaks stack (AG-OP-007).
    # From: Issue #1683 | PR #1858
    local repo_root keys key d ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    keys="$(grep -E '^  setup_required_repairs:' "${repo_root}/.github/yaml/build-manifest.yml" | sed 's/^[^:]*:[[:space:]]*//')"
    [ -n "${keys}" ]
    _load_setup_update_helpers "${repo_root}"
    for key in ${keys}; do
        [ "${key}" = "LANCACHE_IMAGE_TAG" ] && continue  # tag derives from git/VERSION context, no static default
        d="${BATS_TEST_TMPDIR}/req-${key}"
        mkdir -p "${d}"
        ef="${d}/.env"
        _write_converged_env_fixture "${ef}"
        awk -F= -v k="${key}" '$1==k{print k"=";next}{print}' "${ef}" > "${ef}.t"
        mv "${ef}.t" "${ef}"
        migrate_env_for_update "${d}" >/dev/null 2>&1 || { echo "migrate failed for ${key}"; return 1; }
        grep -Eq "^${key}=..*" "${ef}" || { echo "required key ${key} not repaired"; return 1; }
    done
}

@test "migrate_env_for_update derives CACHE_MAX_SIZE from CACHE_MAX_GB" {
    # What: Empty MAX_SIZE rebuilt from MAX_GB.
    # Why: Reuse operator size, not default.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/cms/.env"
    mkdir -p "${BATS_TEST_TMPDIR}/cms"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${ef}"
    awk -F= '$1=="CACHE_MAX_GB"{print "CACHE_MAX_GB=77";next} $1=="CACHE_MAX_SIZE"{print "CACHE_MAX_SIZE=";next} {print}' "${ef}" > "${ef}.t"
    mv "${ef}.t" "${ef}"
    run migrate_env_for_update "$(dirname "${ef}")"; [ "${status}" -eq 0 ]
    grep -Eq '^CACHE_MAX_SIZE=.*77' "${ef}"
}

@test "get_env_assignment_value_raw_nonempty preserves the raw assignment" {
    # What: Raw (unparsed) value returned.
    # Why: templated/quoted overrides must not be flattened.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/raw.env"
    _load_setup_update_helpers "${repo_root}"
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
    _load_setup_update_helpers "${repo_root}"
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
    _load_setup_update_helpers "${repo_root}"
    printf 'FOO=1\nFOO=2\nBAR=3\n' > "${ef}"
    set_env_key FOO 9 "${ef}"
    [ "$(grep -c '^FOO=' "${ef}")" -eq 1 ]
    grep -qx 'FOO=9' "${ef}"
    grep -qx 'BAR=3' "${ef}"
}

# What: builds a fixture doc + quickstart web_log copy.
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
    cat > "${root}/inst/c.yml" <<'EOF'
services:
  netdata:
    command: |
      cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: real
            path: /x
        CONF
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
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\nsvc-b\n"')" \
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
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
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
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svcfail 'exit 3')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0034"* ]]
}

@test "check logging-matrix fails a drifted quickstart web_log job" {
    # What: quickstart's inline job no longer matches it.
    # Why: Byte-identical promise.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog"
    _logging_matrix_fixture "${r}" "svc-a"
    cat > "${r}/inst/c.yml" <<'EOF'
services:
  netdata:
    command: |
      cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: different
            path: /y
        CONF
EOF
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"quickstart's inline web_log job config has drifted"* ]]
}

@test "check logging-matrix passes a matching quickstart web_log fixture" {
    # What: Inline web_log passes parity.
    # Why: Fixture-level match case.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog-ok"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
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
    rm "${r}/.github/workflows/s.yml"
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

@test "check changelog-direct-edit is clean when CHANGELOG.md is untouched" {
    # What: migrated from check-changelog-direct-edit.sh.
    # Why: rewritten in ci.sh; stays non-blocking always.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check changelog-direct-edit "foo.txt" "bar.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"changelog-direct-edit=clean"* ]]
}

@test "check changelog-direct-edit warns without the release label" {
    # What: a direct CHANGELOG.md edit, no exemption label.
    # Why: Warn-only, never blocks.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check changelog-direct-edit "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-INFO-CHECK-0116"* ]]
    [[ "${output}" == *"warn-only"* ]]
    [[ "${output}" == *"changelog-direct-edit=warn"* ]]
    # What: unreadable labels JSON fails with jq's error.
    # Why: a parse error is not "no release label".
    # From: Issue #1683 | PR #1858
    PR_LABELS_JSON='{broken' run bash "${CI_SH}" check changelog-direct-edit "CHANGELOG.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0112"* ]]
}

@test "diff refs fail on a broken PR merge-base, not empty" {
    # What: failed merge-base is rc 2; absent before = none.
    # Why: empty refs means "all changed"; UNKNOWN != BUILD.
    # From: Issue #1683 | PR #1858
    local repo="${BATS_TEST_TMPDIR}/dr"
    git init -q "${repo}"
    git -C "${repo}" -c user.email=a@b -c user.name=b commit -q --allow-empty -m x
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=pull_request BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
        run _ci_diff_refs
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"* ]]
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=pull_request BASE_SHA=0123456789abcdef0123456789abcdef01234567 \
        run ci_cmd_changed_files
    [ "${status}" -eq 2 ]
    CI_REPO_ROOT="${repo}" GITHUB_EVENT_NAME=push BEFORE_SHA=0123456789abcdef0123456789abcdef01234567 \
        GITHUB_SHA=HEAD run _ci_diff_refs
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "check changelog-direct-edit notices the release label exemption" {
    # What: same edit, but the PR carries the release label.
    # Why: the documented manual release-notes exemption.
    # From: Issue #1683 | PR #1858
    PR_LABELS_JSON='["release"]' \
        run bash "${CI_SH}" check changelog-direct-edit "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"edited with release label; expected"* ]]
}

# What: neutral repo and SOT for image build tests.
# Why: build tests must not depend on a real service.
# From: Issue #1683
_build_fixture() {
    local r="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${r}/svc"
    printf 'FROM x\nARG BUILD_IDENTITY\n' > "${r}/svc/Dockerfile"
    printf '%s\n' 'services:' \
        '  svc-a:' '    context: svc' '    build_type: apk' '    final_base: base-x' \
        '  svc-b:' '    context: svc' '    build_type: apk' '    final_base: base-x' \
        'build_toolchain:' '  tool-t:' '    context: svc' '    build_type: toolchain' \
        '    final_base: base-x' 'base_images:' \
        "  alpine: registry.example.test/base@sha256:$(printf '0%.0s' {1..64})" \
        "  base-x: registry.example.test/base-x@sha256:$(printf '2%.0s' {1..64})" \
        'release:' '  registry: registry.example.test' > "${r}/m.yml"
    cd "${r}" || return 1
    export CI_MANIFEST="${r}/m.yml" GITHUB_REPOSITORY=owner/fixture-repo
}

@test "docker-build passes the build type's SOT variables" {
    # What: env > vars json > SOT; unset is never passed.
    # Why: builders get repo/org vars without a YAML list.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    printf '%s\n' 'ci_variables:' '  V_SOT: from-sot' \
        'build_variables:' '  apk: [V_ENV, V_JSON, V_SOT, V_NONE]' >> "${CI_MANIFEST}"
    _tool_stub "${bin}" docker <<'STUB'
echo "docker $*"
STUB
    PATH="${bin}:${PATH}" V_ENV=from-env \
        CI_VARIABLES='{"V_JSON":"from-json","V_ENV":"json-loses"}' \
        run _ci_docker_build svc-a abc123 os/p1
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [[ "${output}" == *"--build-arg V_ENV=from-env"* ]]
    [[ "${output}" == *"--build-arg V_JSON=from-json"* ]]
    [[ "${output}" == *"--build-arg V_SOT=from-sot"* ]]
    [[ "${output}" != *"V_NONE"* ]]
    PATH="${bin}:${PATH}" CI_VARIABLES='[' run _ci_docker_build svc-a abc123 os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0015"* ]]
}

@test "docker-build passes the tag and cache flags each row expects" {
    # What: one buildx argv check per row: wants, forbids.
    # Why: tag, cache wiring and passthrough share one path.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin" r=registry.example.test/owner/fixture-repo
    local name svc id from to want forbid w
    local -a ws
    mkdir -p "${bin}"
    _build_fixture
    _tool_stub "${bin}" docker <<'STUB'
echo "docker $*"
STUB
    while IFS='|' read -r name svc id from to want forbid; do
        unset CI_BUILD_CACHE_FROM CI_BUILD_CACHE_TO
        [ "${from}" = - ] || export CI_BUILD_CACHE_FROM="${from//@R@/${r}}"
        [ "${to}" = - ] || export CI_BUILD_CACHE_TO="${to//@R@/${r}}"
        PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
            run _ci_docker_build "${svc}" "${id}" os/p1
        [ "${status}" -eq 0 ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a ws <<<"${want//@R@/${r}}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
        [ "${forbid}" = - ] && continue
        IFS=';' read -r -a ws <<<"${forbid//@R@/${r}}"
        for w in "${ws[@]}"; do
            [[ "${output}" != *"${w}"* ]] || { echo "${name}: has '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
tag|svc-a|abc123|-|-|buildx build --load;@R@/svc-a:sha-abc123-p1;--platform os/p1;org.opencontainers.image.title=svc-a;--build-arg BUILD_IDENTITY=abc123;--build-arg BUILDKIT_DOCKERFILE_CHECK=error=true|--cache-from;--cache-to
wired-a|svc-a|abc123|type=registry,ref=@R@/svc-a:cache|type=registry,ref=@R@/svc-a:cache,mode=max|--cache-from type=registry,ref=@R@/svc-a:cache;--cache-to type=registry,ref=@R@/svc-a:cache,mode=max,ignore-error=true|svc-b:cache
wired-b|svc-b|def456|type=registry,ref=@R@/svc-b:cache|type=registry,ref=@R@/svc-b:cache,mode=max|--cache-from type=registry,ref=@R@/svc-b:cache;--cache-to type=registry,ref=@R@/svc-b:cache,mode=max,ignore-error=true|svc-a:cache
ignore-error-kept|svc-a|abc123|-|type=registry,ref=@R@/svc-a:cache,ignore-error=false|--cache-to type=registry,ref=@R@/svc-a:cache,ignore-error=false|ignore-error=false,ignore-error=true;--cache-from
shorthand|svc-a|abc123|-|@R@/svc-a:cache|--cache-to @R@/svc-a:cache;CI-WARN-BUILD-0012|svc-a:cache,
CASES
    unset CI_BUILD_CACHE_FROM CI_BUILD_CACHE_TO
}

@test "docker-build fails closed without ARG BUILD_IDENTITY or build-args" {
    # What: no ARG BUILD_IDENTITY stops before buildx runs.
    # Why: its cache could ship a stale apk layer silently.
    # From: Issue #1683 | PR #1858
    _build_fixture
    printf 'FROM x\nRUN true\n' > svc/Dockerfile
    docker() { echo "docker $*"; }
    run _ci_docker_build svc-a id1 os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0013"* ]]
    [[ "${output}" != *"buildx build"* ]]
    printf 'FROM x\nARG BUILD_IDENTITY\n' > svc/Dockerfile
    sed -i '0,/build_type: apk/s//build_type: rust/' "${CI_MANIFEST}"
    CI_BUILD_TOOLS_IMAGE_CMD='echo bt@sha256:x' run _ci_docker_build svc-a id1 os/p1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-"* ]]
    [[ "${output}" != *"buildx build"* ]]
}

@test "docker-build cache-from miss fails cache import only, build still succeeds" {
    # What: a bad cache-from ref must not fail the build.
    # Why: §35: a cache miss must cost time, not the build.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    _tool_stub "${bin}" docker <<'EOF'
case "$*" in
    *"--cache-from"*)
        echo "importing cache manifest from target" >&2
        echo "ERROR: failed to configure registry cache import: not found" >&2
        exit 0
        ;;
    *) echo "docker $*" ;;
esac
EOF
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
        CI_BUILD_CACHE_FROM="type=registry,ref=registry.example.test/owner/fixture-repo/svc-a:cache" \
        run _ci_docker_build svc-a abc123 os/p1
    [ "${status}" -eq 0 ]
    # What: raw evidence of the miss stays visible.
    # Why: AG-INT-002 forbids hiding it.
    [[ "${output}" == *"failed to configure registry cache import"* ]]
}

@test "docker-publish pushes then reads back the registry digest" {
    # What: publish retries push, then reads the digest.
    # Why: BUILD != PUBLISH; same digest, many retries.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    _tool_stub "${bin}" docker <<'STUB'
case "$*" in *"imagetools inspect"*) echo sha256:deadbeef ;; *) : ;; esac
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
        run _ci_docker_publish svc-a abc123 os/p1
    [ "${status}" -eq 0 ]
    [ "${output}" = "sha256:deadbeef" ]
}

# =========================================================
# RETRY ENGINE (_ci_retry) + BUILD != PUBLISH INVARIANT
# =========================================================

@test "_ci_retry retries a transient failure and returns on success" {
    # What: 2 transient failures then success (3 tries).
    # Why: Engine owns every wrapper's retry loop.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _flaky() {
        local n; n="$(($(cat "${cnt}") + 1))"; printf '%s' "${n}" > "${cnt}"
        if [ "${n}" -lt 3 ]; then echo "connection reset by peer" >&2; return 1; fi
        echo ok
    }
    export -f _flaky
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry _flaky
    [ "${status}" -eq 0 ]
    [ "${lines[-1]}" = "ok" ]
    [ "$(cat "${cnt}")" -eq 3 ]
    # What: each failed try shows with its raw; then INFO.
    # Why: AG-INT-002: a late success is no 1st-try pass.
    # From: Issue #1683 | PR #1858
    [ "$(grep -c '\[CI-WARN-BUILD-0016\] op=registry cmd="_flaky"' <<< "${output}")" -eq 2 ]
    [ "$(grep -c '^connection reset by peer$' <<< "${output}")" -eq 2 ]
    [[ "${output}" == *'[CI-INFO-BUILD-0017] op=registry cmd="_flaky" attempt=3/4'* ]]
}

@test "_ci_retry fails on the first attempt for a permanent classification" {
    # What: 401 failure doesn't consume retry budget.
    # Why: Retrying fixed outcome wastes wall-clock time.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _denied() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "HTTP 401 unauthorized" >&2; return 1
    }
    export -f _denied
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry _denied
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 1 ]
    [[ "${output}" == *'[CI-ERROR-BUILD-0011] op=registry cmd="_denied" cls=permanent attempt=1/4'* ]]
    [[ "${output}" == *"HTTP 401 unauthorized"* ]]
    [[ "${output}" != *"CI-WARN-BUILD-0016"* ]]
}

@test "_ci_retry exhausts after CI_RETRY_MAX_ATTEMPTS on a persistent transient failure" {
    # What: An always-transient failure still stops at max.
    # Why: A retry loop must be bounded, never infinite.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _alwaysflaky() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "connection refused" >&2; return 1
    }
    export -f _alwaysflaky
    CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 run _ci_retry registry _alwaysflaky
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 3 ]
}

@test "publish retry-exhaustion never invokes build (RETRY OPERATION != REBUILD)" {
    # What: Failed retry exhausts retries without rebuild.
    # Why: Retry-fail must never trigger rebuild.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    local buildmarker="${BATS_TEST_TMPDIR}/build-was-called"
    _tool_stub "${bin}" docker <<EOF
case "\$*" in
    *"buildx build"*) printf 'called\n' >> "${buildmarker}"; exit 0 ;;
    *"push "*) echo "connection reset by peer" >&2; exit 1 ;;
    *) : ;;
esac
EOF
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
    CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 \
        run _ci_docker_publish svc-a abc123 os/p1
    [ "${status}" -eq 2 ]
    [ ! -e "${buildmarker}" ]
}

@test "docker-build retries only its own known transient buildx signature" {
    # What: Layer-lock fail then success; build succeeds.
    # Why: Historical buildx transient signature match.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _tool_stub "${bin}" docker <<EOF
case "\$*" in
    *"buildx build"*)
        n="\$(( \$(cat "${cnt}") + 1 ))"; printf '%s' "\$n" > "${cnt}"
        if [ "\$n" -lt 2 ]; then
            echo "(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:abc locked for 900ms (since t): unavailable" >&2
            exit 1
        fi
        exit 0
        ;;
    *) : ;;
esac
EOF
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_docker_build svc-a abc123 os/p1
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 2 ]
}

@test "docker-build fails immediately on a real compile error (no retry)" {
    # What: Compile failure must never be retried.
    # Why: Blind retry would only delay real feedback.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _build_fixture
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _tool_stub "${bin}" docker <<EOF
case "\$*" in
    *"buildx build"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "error: could not compile crate-a" >&2; exit 1 ;;
    *) : ;;
esac
EOF
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_docker_build svc-a abc123 os/p1
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 1 ]
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
    local mode="$1" bin="${BATS_TEST_TMPDIR}/bin"
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

@test "trivy error kind classifies a DB miss versus other errors" {
    # What: DB-download text is retryable; others are not.
    # Why: Only a DB miss should trigger a retry.
    # From: Issue #1683
    run _ci_trivy_error_kind "failed to download vulnerability DB: timeout"
    [ "${output}" = "db-missing" ]
    run _ci_trivy_error_kind "manifest unknown: pull denied"
    [ "${output}" = "pre-report-error" ]
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
        CI_TRIVY_MAX=2 CI_TRIVY_BACKOFF=0 run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 3 ]
}

@test "scan runs trivy with the vuln+secret scanners" {
    # What: The scan covers vulnerabilities and secrets.
    # Why: Secret-scan parity with the retired action.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    export TLOG="${BATS_TEST_TMPDIR}/t.log"; : > "${TLOG}"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
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
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
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
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub dl 'echo SHOULD-NOT-RUN; exit 1')" \
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
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
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
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub dl 'exit 1')" \
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

@test "verify default reads back the registry digest via imagetools" {
    # What: default readback reads the registry digest.
    # Why: expected == registry digest continues (§23).
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo sha256:match
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" verify ui sha256:match os/p1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:match"* ]]
}

@test "assemble default merges digests into one sha index" {
    # What: default assemble writes one multi-arch index.
    # Why: shared writer; digest read back from registry.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local log="${BATS_TEST_TMPDIR}/create.log"
    _tool_stub "${bin}" docker <<STUB
case "\$*" in
    *"imagetools create"*) echo "\$*" >> "${log}" ;;
    *"imagetools inspect"*) echo sha256:idx ;;
esac
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GITHUB_SHA=deadbeef \
        run _ci_docker_assemble svc-a os/p1=sha256:aaa os/p2=sha256:bbb
    [ "${status}" -eq 0 ]
    [ "${output}" = "sha256:idx" ]
    run cat "${log}"
    [[ "${output}" == *"--tag registry.example.test/owner/fixture-repo/svc-a:sha-deadbeef"* ]]
    [[ "${output}" == *"registry.example.test/owner/fixture-repo/svc-a@sha256:aaa"* ]]
    [[ "${output}" == *"registry.example.test/owner/fixture-repo/svc-a@sha256:bbb"* ]]
}

# What: bare repo + two host clones for real CAS tests.
# Why: real git CAS proof, no live remote (AG-VAL-030).
_cas_setup() {
    CAS_BARE="${BATS_TEST_TMPDIR}/bare.git"
    CAS_A="${BATS_TEST_TMPDIR}/host-a"
    CAS_B="${BATS_TEST_TMPDIR}/host-b"
    git init --quiet --bare "${CAS_BARE}"
    git clone --quiet "${CAS_BARE}" "${CAS_A}"
    (
        cd "${CAS_A}" || exit 1
        git config user.email cas-bats@example.invalid
        git config user.name cas-bats
        git commit --quiet --allow-empty -m init
        git push --quiet origin HEAD:refs/heads/master
    )
    git clone --quiet "${CAS_BARE}" "${CAS_B}"
}

@test "cas ref_sha reports an absent ref as free" {
    # What: ls-remote miss maps to absent, not error.
    # Why: a free lock must read as free, code 1.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "cas ref_sha shows raw evidence on a query failure" {
    # What: an unreachable remote is UNKNOWN with raw.
    # Why: UNKNOWN without its cause is not diagnosable.
    # From: Issue #1683 | PR #1858
    _cas_setup
    cd "${CAS_A}"
    run _ci_cas_ref_sha "${BATS_TEST_TMPDIR}/no-such-remote" refs/ci/lock/t
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-WARN-RESOLVE-0008]"* ]]
    [[ "${output}" == *"raw:"* ]]
    [[ "${output}" == *"no-such-remote"* ]]
}

@test "ledger_blob shows raw evidence for a missing file" {
    # What: ref present, ledger file absent -> UNKNOWN.
    # Why: the cat-file cause must stay visible (raw).
    # From: Issue #1683 | PR #1858
    _cas_setup
    cd "${CAS_A}"
    git push --quiet origin "HEAD:${CI_LEDGER_REF}"
    run _ci_ledger_blob origin
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-WARN-RESOLVE-0009]"* ]]
    [[ "${output}" == *"raw:"* ]]
}

@test "cas lock_try creates the ref on a free lock" {
    # What: a free lock is created atomically.
    # Why: create-against-zero is the acquire path.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_lock_try origin refs/ci/lock/t holder-a 600
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "cas lock_try refuses a fresh lock held elsewhere" {
    # What: a held, non-stale lock refuses a second host.
    # Why: mutual exclusion across hosts (code 1).
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_try origin refs/ci/lock/t holder-b 600
    [ "${status}" -eq 1 ]
}

@test "cas release lets another host acquire" {
    # What: release frees the ref for the next host.
    # Why: normal hand-off between two runs.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 0 ]
    cd "${CAS_B}"
    run _ci_lock_try origin refs/ci/lock/t holder-b 600
    [ "${status}" -eq 0 ]
}

@test "cas release never deletes another holder's lock" {
    # What: release checks ownership before deleting.
    # Why: a takeover must not lose the new holder.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_release origin refs/ci/lock/t not-holder
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 0 ]; [ -n "${output}" ]
}

@test "lock_release retries a transient git-fetch failure, then succeeds" {
    # What: Transient fail then success; retry works.
    # Why: Fetch lacked retry until op=git was added.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _tool_stub "${bin}" git <<EOF
case "\$*" in
    *"fetch --quiet"*)
        n="\$(( \$(cat "${cnt}") + 1 ))"; printf '%s' "\$n" > "${cnt}"
        if [ "\$n" -lt 2 ]; then echo "unexpected disconnect while reading sideband packet" >&2; exit 1; fi
        ;;
esac
exec "${realgit}" "\$@"
EOF
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 2 ]
}

@test "lock_release fails fast (no retry) on a not_found-shaped git-fetch error" {
    # What: Missing ref must not consume retry budget.
    # Why: Permanent cascade; retrying won't fix it.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _tool_stub "${bin}" git <<EOF
case "\$*" in
    *"fetch --quiet"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "fatal: couldn't find remote ref refs/ci/lock/t" >&2; exit 1 ;;
esac
exec "${realgit}" "\$@"
EOF
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 1 ]
}

@test "lock_release exhausts after CI_RETRY_MAX_ATTEMPTS on a persistent transient fetch failure" {
    # What: Transient fail respects retry max limit.
    # Why: Bounded retry is a hard requirement.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _tool_stub "${bin}" git <<EOF
case "\$*" in
    *"fetch --quiet"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "connection refused" >&2; exit 1 ;;
esac
exec "${realgit}" "\$@"
EOF
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 3 ]
}

@test "cas lock_try takes over a stale lock" {
    # What: an aged lock is taken over via lease swap.
    # Why: a crashed holder must not block forever.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    sleep 2
    cd "${CAS_B}"
    # What: an unreadable lock age stops the takeover.
    # Why: a failed read must not look like an old lock.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/gitbin"
    _fail_stub "${bin}" git
    PATH="${bin}:${PATH}" FAIL_MATCH=%ct run _ci_lock_try origin refs/ci/lock/t holder-b 1
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"CI-ERROR-CORE-0106"* ]]
    git fetch --quiet origin refs/ci/lock/t
    [ "$(git log -1 --format=%s FETCH_HEAD)" = holder-a ]
    run _ci_lock_try origin refs/ci/lock/t holder-b 1
    [ "${status}" -eq 0 ]
    git fetch --quiet origin refs/ci/lock/t
    [ "$(git log -1 --format=%s FETCH_HEAD)" = holder-b ]
}

@test "cas acquire fails closed after exhausting attempts" {
    # What: an unbeatable lock exhausts retries and fails.
    # Why: proceeding unlocked would race the section.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_acquire origin refs/ci/lock/t holder-b 3 1 600
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CAS-0002"* ]]
}

@test "cas concurrent create has exactly one winner" {
    # What: two simultaneous creators; one wins atomically.
    # Why: git ref create is compare-against-zero.
    # From: Issue #1683
    _cas_setup
    local ra="${BATS_TEST_TMPDIR}/ra" rb="${BATS_TEST_TMPDIR}/rb"
    ( set +e; cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t race-a 600; echo "$?" > "${ra}" ) &
    ( set +e; cd "${CAS_B}"; _ci_lock_try origin refs/ci/lock/t race-b 600; echo "$?" > "${rb}" ) &
    wait || true
    local sa sb; sa="$(cat "${ra}")"; sb="$(cat "${rb}")"
    if [ "${sa}" = 0 ]; then [[ "${sb}" == 1 || "${sb}" == 2 ]]; else [[ "${sa}" == 1 || "${sa}" == 2 ]]; fi
}

@test "ledger read on an empty ledger reports the record absent" {
    # What: no ledger ref yet means a record is absent.
    # Why: empty ledger is absent (1), not UNKNOWN (2).
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_ledger_read origin some-identity
    [ "${status}" -eq 1 ]
}

@test "ledger append then read returns state and digest" {
    # What: a written record round-trips through the ref.
    # Why: proves the write/read format agree.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-1 dns os/p1 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ACCEPTED"* ]]
    [[ "${output}" == *"sha256:aaa"* ]]
}

@test "ledger append upserts an identity to its latest record" {
    # What: a second write replaces the same identity.
    # Why: one current record per identity, no duplicates.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-1 dns os/p1 PRODUCED_UNVERIFIED sha256:aaa
    _ci_ledger_append origin id-1 dns os/p1 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ACCEPTED"* ]]
    git fetch --quiet origin refs/ci/acceptance/ledger
    [ "$(git cat-file -p FETCH_HEAD:records | grep -c '^id-1')" -eq 1 ]
}

@test "ledger keeps distinct identities independently" {
    # What: two identities coexist in one ledger.
    # Why: an append must not drop other records.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-a dns os/p1 ACCEPTED sha256:aaa
    _ci_ledger_append origin id-b dns os/p2 PRODUCED_UNVERIFIED sha256:bbb
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"ACCEPTED"* ]]; [[ "${output}" == *"sha256:aaa"* ]]
    run _ci_ledger_read origin id-b
    [[ "${output}" == *"PRODUCED_UNVERIFIED"* ]]; [[ "${output}" == *"sha256:bbb"* ]]
}

@test "ledger read of an unknown identity is absent in a non-empty ledger" {
    # What: an unlisted identity reads as absent.
    # Why: absent (1) must not be confused with UNKNOWN.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-a dns os/p1 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-missing
    [ "${status}" -eq 1 ]
}

@test "accepted_digest default returns the digest only when ACCEPTED" {
    # What: default reads the ledger via the identity.
    # Why: only an ACCEPTED record yields a digest.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { printf 'ACCEPTED\tsha256:xyz\n'; }
    run _ci_accepted_digest ui os/p1
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:xyz ]
}

@test "accepted_digest default yields nothing for a non-ACCEPTED record" {
    # What: an unverified record is not a reusable digest.
    # Why: fail-safe; only ACCEPTED is reusable.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { printf 'PRODUCED_UNVERIFIED\tsha256:xyz\n'; }
    run _ci_accepted_digest ui os/p1
    [ "${status}" -eq 1 ]
}

@test "accepted_digest default propagates a ledger UNKNOWN read" {
    # What: an unknown ledger read is not a missing digest.
    # Why: UNKNOWN != absent; the caller must not reuse.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { return 2; }
    run _ci_accepted_digest ui os/p1
    [ "${status}" -eq 2 ]
}

@test "registry_probe maps a missing manifest to not-found" {
    # What: a genuine miss returns 1 (may build).
    # Why: not-found is the only build-eligible miss.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "registry.example.test/x: not found: manifest unknown" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_registry_probe registry.example.test/x/y:z
    [ "${status}" -eq 1 ]
}

@test "registry_probe maps the imagetools miss to not-found" {
    # What: buildx "ERROR: <ref>: not found" returns 1.
    # Why: real CI shape; it drove every target UNKNOWN.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "ERROR: registry.example.test/x/y:z: not found" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_registry_probe registry.example.test/x/y:z
    [ "${status}" -eq 1 ]
}

@test "registry_probe maps an auth failure to unknown, not not-found" {
    # What: an auth failure returns 2 (never build).
    # Why: a credential problem is not a missing artifact.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "denied: requested access to the resource" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_registry_probe registry.example.test/x/y:z
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-WARN-RESOLVE-0007]"* ]]
    [[ "${output}" == *"denied: requested access"* ]]
}

@test "registry_probe returns the digest on success" {
    # What: a present tag yields its digest, code 0.
    # Why: the happy path feeds the resolver.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo sha256:ok
STUB
    PATH="${bin}:${PATH}" run _ci_registry_probe registry.example.test/x/y:z
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:ok ]
}

@test "resolve state maps every ledger x registry combination" {
    # What: ledger + registry evidence -> resolver state.
    # Why: only MISSING_CONFIRMED builds; UNKNOWN never.
    # From: Issue #1683
    local led reg want
    _ci_image_tag() { echo tag; }
    while IFS='|' read -r led reg want; do
        case "${led}" in
            fail) _ci_ledger_read() { return 2; } ;;
            none) _ci_ledger_read() { return 1; } ;;
            *) eval "_ci_ledger_read() { printf '%s\tsha256:g\n' '${led}'; }" ;;
        esac
        case "${reg}" in
            fail) _ci_registry_probe() { return 2; } ;;
            none) _ci_registry_probe() { return 1; } ;;
            *) eval "_ci_registry_probe() { echo 'sha256:${reg}'; }" ;;
        esac
        run _ci_resolve_state ui id-x os/p1
        [ "${output##*$'\n'}" = "${want}" ] || { echo "${led}/${reg}: ${output}"; return 1; }
        [ "${led}/${reg}" != ACCEPTED/none ] || [[ "${output}" == *RESOLVE-0006* ]]
    done <<'CASES'
fail|g|UNKNOWN
none|fail|UNKNOWN
none|none|MISSING_CONFIRMED
none|g|PRODUCED_UNVERIFIED
ACCEPTED|g|PRESENT_ACCEPTED
ACCEPTED|other|MISMATCH
ACCEPTED|none|MISMATCH
PRODUCED_UNVERIFIED|g|PRODUCED_UNVERIFIED
CASES
}

@test "resolve state: a missing platform is UNKNOWN" {
    # What: no platform means no registry probe.
    # Why: fail closed rather than guess an artifact.
    # From: Issue #1683
    run _ci_resolve_state ui id-x ""
    [ "${output}" = UNKNOWN ]
}

@test "index_lookup default reads the multi-arch index and drops attestations" {
    # What: default reads the index digest + arch children.
    # Why: reconcile compares against the real registry.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'SH'
case "$*" in
  *--raw*) echo '{"manifests":[{"platform":{"os":"os","architecture":"p1"},"digest":"sha256:a"},{"platform":{"os":"os","architecture":"p2"},"digest":"sha256:b"},{"platform":{"os":"unknown","architecture":"unknown"},"digest":"sha256:att"}]}' ;;
  *) echo sha256:idx ;;
esac
SH
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GITHUB_SHA=deadbeef \
        run _ci_index_lookup ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:idx"* ]]
    [[ "${output}" == *"os/p1=sha256:a"* ]]
    [[ "${output}" == *"os/p2=sha256:b"* ]]
    [[ "${output}" != *"sha256:att"* ]]
}

@test "index_lookup default returns nothing when no index exists" {
    # What: a missing index is not a reusable index.
    # Why: assemble then creates one from accepted digests.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "not found: manifest unknown" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GITHUB_SHA=deadbeef \
        run _ci_index_lookup ui
    [ "${status}" -eq 1 ]
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
    [[ "${output}" == *"[CI-ERROR-ASSEMBLE-0011]"* ]] && [[ "${output}" == *"jq: parse error"* ]]
    [ ! -s "${calls}" ]
}

@test "an unreachable registry stops assembly, never re-assembles" {
    # What: probe UNKNOWN -> lookup rc 2 -> reconcile stops.
    # Why: never assemble over an unchecked index.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "dial tcp: i/o timeout" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GITHUB_SHA=deadbeef \
        run _ci_index_lookup ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-WARN-RESOLVE-0007"* ]] && [[ "${output}" == *"i/o timeout"* ]]
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo GITHUB_SHA=deadbeef \
        run _ci_reconcile_index ui "os/p1=sha256:a"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'[CI-ERROR-ASSEMBLE-0007] service="ui" rc=2'* ]]
    [[ "${output}" != *"sha256:"* ]]
}

@test "index_raw reports unknown, not absent, on a transient failure" {
    # What: a transient inspect failure is rc 2, not rc 1.
    # Why: transient must not read as a missing platform.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "Connection reset by peer" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_index_raw registry.example.test/owner/fixture-repo/ui:sha-deadbeef
    [ "${status}" -eq 2 ]
}

@test "index_raw reports absent only on a genuine not_found" {
    # What: a manifest-unknown miss is rc 1 (absent).
    # Why: real miss drives assembly, not transient.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'STUB'
echo "not found: manifest unknown" >&2
exit 1
STUB
    PATH="${bin}:${PATH}" run _ci_index_raw registry.example.test/owner/fixture-repo/ui:sha-deadbeef
    [ "${status}" -eq 1 ]
}

@test "pr candidate pins each service to the daemon platform's digest" {
    # What: host platform from docker; per-service digest.
    # Why: no PR ledger; a missing image or host fails.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin" mode
    mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'SH'
case "${MODE}:$*" in
  nohost:version*) exit 1 ;;
  *:version*) echo "os/p9" ;;
  ok:*"/svc-a:"*p9*) echo "sha256:aaa" ;;
  ok:*"/svc-b:"*p9*) echo "sha256:bbb" ;;
  missing:*) echo "not found: manifest unknown" >&2; exit 1 ;;
  *) echo "Connection reset by peer" >&2; exit 1 ;;
esac
SH
    ci_services() { printf 'svc-a\nsvc-b\n'; }
    _ci_identity_for() { echo "id-$1"; }
    MODE=ok PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo run _ci_stack_candidate_pr
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'svc-a=sha256:aaa\nsvc-b=sha256:bbb')" ]
    for mode in missing reset nohost; do
        MODE="${mode}" PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo run _ci_stack_candidate_pr
        [ "${status}" -eq 2 ]
    done
    [[ "${output}" == *"CI-ERROR-CANDIDATE-0005"* ]]
}

@test "ledger upsert writes many records in one commit" {
    # What: a batch of records lands in one CAS commit.
    # Why: §26.1 one write per workflow, not per record.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    printf 'id-a\tdns\tos/p1\tACCEPTED\tsha256:a\nid-b\tui\tos/p2\tACCEPTED\tsha256:b\n' \
        | _ci_ledger_upsert origin
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"sha256:a"* ]]
    run _ci_ledger_read origin id-b
    [[ "${output}" == *"sha256:b"* ]]
    git fetch --quiet origin refs/ci/acceptance/ledger
    [ "$(git cat-file -p FETCH_HEAD:records | grep -c .)" -eq 2 ]
    [ "$(git rev-list --count FETCH_HEAD)" -eq 1 ]
}

@test "aggregate writes result.json files as one ledger write" {
    # What: many result.json -> one aggregated ledger write.
    # Why: §26.1 single aggregator, not per-job writes.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"os/p1","build_identity":"id-a","state":"ACCEPTED","digest":"sha256:a"}' > "${rd}/a.json"
    printf '{"service":"ui","platform":"os/p2","build_identity":"id-b","state":"ACCEPTED","digest":"sha256:b"}' > "${rd}/b.json"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=written"* ]]
    [[ "${output}" == *"records=2"* ]]
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"ACCEPTED"* ]]
}

@test "aggregate re-run over the same results converges (idempotent)" {
    # What: re-aggregating the same set is a no-op content.
    # Why: §26.4 idempotency; same inputs -> same blob.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"os/p1","build_identity":"id-a","state":"ACCEPTED","digest":"sha256:a"}' > "${rd}/a.json"
    ci_cmd_aggregate "${rd}"
    git fetch --quiet origin refs/ci/acceptance/ledger
    local first; first="$(git cat-file -p FETCH_HEAD:records)"
    ci_cmd_aggregate "${rd}"
    git fetch --quiet origin refs/ci/acceptance/ledger
    local second; second="$(git cat-file -p FETCH_HEAD:records)"
    [ "${first}" = "${second}" ]
}

@test "aggregate fails closed on a malformed result.json" {
    # What: a partial result.json aborts the aggregation.
    # Why: never record an incomplete acceptance.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"os/p1"}' > "${rd}/bad.json"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0004"* ]]
}

@test "aggregate fails closed when the results dir is empty" {
    # What: no result.json means nothing to write.
    # Why: an empty run must not silently succeed.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0003"* ]]
}

@test "default channel move points the channel tag at the digest" {
    # What: default promote move retargets svc:channel.
    # Why: shares the index writer; moves, not builds.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local log="${BATS_TEST_TMPDIR}/create.log"
    _tool_stub "${bin}" docker <<STUB
case "\$*" in
    *"imagetools create"*) echo "\$*" >> "${log}" ;;
esac
STUB
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
        run _ci_default_channel_move svc-a latest sha256:abc
    [ "${status}" -eq 0 ]
    run cat "${log}"
    [[ "${output}" == *"--tag registry.example.test/owner/fixture-repo/svc-a:latest"* ]]
    [[ "${output}" == *"registry.example.test/owner/fixture-repo/svc-a@sha256:abc"* ]]
}

@test "default channel readback reads the channel digest" {
    # What: default readback returns the channel digest.
    # Why: one digest reader confirms the promotion.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    _tool_stub "${bin}" docker <<'EOF'
case " $* " in
    *" --raw "*) printf '%s\n' "${INDEX_JSON}" ;;
    *) echo sha256:chan ;;
esac
EOF
    INDEX_JSON='{"manifests":[{"digest":"sha256:c1","platform":{"os":"o","architecture":"a"}}]}' \
        PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
        run _ci_default_channel_readback svc-a latest
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:chan ]
    # What: an index without a platform child fails closed.
    # Why: zero children must never read as a usable image.
    INDEX_JSON='{"schemaVersion":2}' PATH="${bin}:${PATH}" GITHUB_REPOSITORY=owner/fixture-repo \
        run _ci_default_channel_readback svc-a latest
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[CI-ERROR-PROMOTE-0015]"* ]]
}

@test "default promote lock acquires the per-channel ref" {
    # What: default promote lock takes refs/ci/promote-lock.
    # Why: reuses the CAS mutex, scoped per channel.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_default_promote_lock latest
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/promote-lock/latest
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

# =========================================================
# VERSION MANAGEMENT
# =========================================================

# What: Copies the two version-pinned Dockerfiles for sync.
# Why: sync tests must never touch the real repo files.
# From: Issue #1683 | PR #1858
_version_fixture_repo() {
    local root="${BATS_TEST_TMPDIR}/vrepo" dep df rest
    while IFS='|' read -r dep df rest; do
        mkdir -p "${root}/$(dirname "${df}")"
        cp "${BATS_TEST_DIRNAME}/../../${df}" "${root}/${df}"
    done <<< "$(_ci_version_consumers)"
    printf '%s' "${root}"
}

@test "version verify (default) passes clean on the real repo" {
    # What: default subcommand is verify, read-only.
    # Why: every SOT pin stays SOT-driven, ARGs bare.
    # From: Issue #1683 | PR #1858
    local dep up
    run bash "${CI_SH}" version
    [ "${status}" -eq 0 ]
    dep="$(_pin_dep)"; up="${dep^^}"; up="${up//-/_}"
    [[ "${output}" == *"key=${dep}.consumer.${up}_SHA256 shape=bare"* ]]
}

@test "version verify explicit subcommand matches the default" {
    # What: 'version verify' behaves like bare 'version'.
    # Why: the default-arg wiring must not silently diverge.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version verify
    [ "${status}" -eq 0 ]
}

@test "version verify fails closed on a missing or malformed SOT pin" {
    # What: sha missing=0004; garbled=0015.
    # Why: a missing/truncated pin must never pass silently.
    # From: Issue #1683 | PR #1858
    local dep df keys key val m
    while IFS='|' read -r dep df keys; do
        key="$(_ci_build_matrix_platforms)"; key="sha256_$(_ci_platform_apk_arch "${key%%$'\n'*}")"
        val="$(_ci_block_entry_field external_versions "${dep}" "${key}")"
        m="${BATS_TEST_TMPDIR}/${dep}-missing.yml"
        grep -v "^    ${key}: ${val}\$" "${CI_MANIFEST}" > "${m}"
        CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"CI-ERROR-BUILDARGS-0004"*"${dep}.${key}"*"missing"* ]]
        m="${BATS_TEST_TMPDIR}/${dep}-badsha.yml"
        sed "s/^    ${key}: ${val}\$/    ${key}: not-a-real-hash/" "${CI_MANIFEST}" > "${m}"
        CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"CI-ERROR-BUILDARGS-0015"*"${dep}.${key}"*"not 64 hex"* ]]
    done <<< "$(_ci_version_consumers)"
}

@test "version verify fails closed on a missing or baked consumer ARG" {
    # What: ARG gone=0008; default=0009.
    # Why: the SOT is the only owner; no second pin, no gap.
    # From: Issue #1683 | PR #1858
    local dep df keys arg root
    while IFS='|' read -r dep df keys; do
        arg="${dep^^}_VERSION"
        root="$(_version_fixture_repo)"
        sed -i "/^ARG ${arg}\$/d" "${root}/${df}"
        CI_REPO_ROOT="${root}" run bash "${CI_SH}" version verify
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"CI-ERROR-VERSION-0008"*"${arg}"* ]]
        root="$(_version_fixture_repo)"
        sed -i "s/^ARG ${arg}\$/ARG ${arg}=baked/" "${root}/${df}"
        CI_REPO_ROOT="${root}" run bash "${CI_SH}" version verify
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"CI-ERROR-VERSION-0009"*"${arg}"* ]]
    done <<< "$(_ci_version_consumers)"
}

@test "version audit is the verify owner under its contract name" {
    # What: audit and verify give the same output and rc.
    # Why: one pin-drift owner; no second walk of the SOT.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version verify
    local want_status="${status}" want="${output}"
    run bash "${CI_SH}" version audit
    [ "${status}" -eq "${want_status}" ]
    [ "${output}" = "${want}" ]
}

@test "version sync is a contract-only no-op for both consumers" {
    # What: every consumer is BARE; sync writes nothing.
    # Why: pins derive live from the SOT.
    # From: Issue #1683 | PR #1858
    local root before after dep
    root="$(_version_fixture_repo)"
    before="$(cd "${root}" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
    CI_REPO_ROOT="${root}" run bash "${CI_SH}" version sync
    [ "${status}" -eq 0 ]
    dep="$(_pin_dep)"
    [[ "${output}" == *"sync=${dep} changed=0 reason=nothing-to-write"* ]]
    after="$(cd "${root}" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
    [ "${before}" = "${after}" ]
}

@test "unknown version subcommand fails closed" {
    # What: an unrecognized 'version' verb must not succeed.
    # Why: fail-closed dispatch, like every other command.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0014"* ]]
}

@test "_ci_dockerfile_arg_default reports ABSENT and BARE" {
    # What: a missing name vs. a defaultless declaration.
    # Why: the two must stay distinct, never conflated.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.shapes"
    printf 'FROM alpine\nARG BARE_ONE\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" NOT_THERE
    [ "${status}" -eq 0 ]
    [ "${output}" = "ABSENT" ]
    run _ci_dockerfile_arg_default "${f}" BARE_ONE
    [ "${status}" -eq 0 ]
    [ "${output}" = "BARE" ]
}

@test "_ci_dockerfile_arg_default reads quoted and bare values" {
    # What: unquoted, double- and single-quoted defaults.
    # Why: AG-VAL-036: the real ARG grammar has all three.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.quotes"
    printf 'FROM alpine\nARG A=1.2.3\nARG B="x y"\nARG C='"'"'q v'"'"'\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" A
    [ "${output}" = "FOUND:1.2.3" ]
    run _ci_dockerfile_arg_default "${f}" B
    [ "${output}" = "FOUND:x y" ]
    run _ci_dockerfile_arg_default "${f}" C
    [ "${output}" = "FOUND:q v" ]
}

@test "_ci_dockerfile_arg_default accepts identical bare re-declares" {
    # What: one bare ARG before and after FROM is BARE.
    # Why: identical bare pre/post-FROM lines are valid.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.redeclare"
    printf 'ARG X\nFROM a\nARG X\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" X
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
    [ "${output}" = "BARE" ]
}

@test "_ci_dockerfile_arg_default refuses conflicting re-declares" {
    # What: two ARG lines, one name, different defaults.
    # Why: AG-VAL-036: refuse to guess, escalate instead.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.conflict"
    printf 'FROM alpine\nARG X=1\nARG X=2\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" X
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0002"* ]]
}

@test "_ci_dockerfile_arg_default refuses unsupported shapes" {
    # What: a line-continuation and an unquoted space value.
    # Why: an unreadable shape must fail loud, never skip.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.unsupported"
    printf 'FROM alpine\nARG A=abc\\\nARG B=has space\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" A
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0003"* ]]
    run _ci_dockerfile_arg_default "${f}" B
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0005"* ]]
}

# =========================================================
# HISTORICAL REGRESSIONS
# =========================================================

# What: Load setup.sh's real update-migration functions.
# Why: Test without sourcing setup.sh.
# From: Issue #1683 | PR #1546
_load_setup_update_helpers() {
    local repo_root="$1"
    local helper_file="${BATS_TEST_TMPDIR}/setup-update-helpers.sh"
    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { :; }'
        printf '%s\n' 'print_step() { :; }'
        printf '%s\n' 'print_warn() { :; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "${repo_root}"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^# Backup\/restore may run on minimal hosts\./ { capture = 0 }
            capture { print }
        ' "${repo_root}/setup.sh"
    } > "${helper_file}"
    # shellcheck source=/dev/null
    source "${helper_file}"
    # What: host arch and registry are stubbed, never real.
    # Why: the platform guard otherwise asks GHCR per test.
    # From: Issue #1683 | PR #1858
    uname() {
        if [ "$1" = -m ]; then printf '%s\n' "${SETUP_FAKE_ARCH:-x86_64}"; else command uname "$@"; fi
    }
    docker() {
        case "$*" in
            "buildx version") [ "${SETUP_FAKE_NO_BUILDX:-0}" = 0 ] ;;
            "buildx imagetools inspect "*)
                [ "${SETUP_FAKE_INSPECT_FAIL:-0}" = 0 ] || { echo "fake registry unreachable" >&2; return 1; }
                if [[ "$*" == *--format* ]]; then
                    printf '%s\n' "${SETUP_FAKE_SINGLE:-linux/amd64}"
                else
                    printf 'Platform:  %s\n' ${SETUP_FAKE_MULTI//,/ }
                fi
                ;;
            *) echo "unexpected docker call: $*" >&2; return 99 ;;
        esac
    }
}

# What: Converged .env, all keys filled.
# Why: A missing key would fail the no-op test's first run.
# From: Issue #1683 | PR #1546
_write_converged_env_fixture() {
    printf '%s\n' \
        'IP_STANDARD=192.0.2.10' 'IP_SSL=192.0.2.11' 'SSL_ENABLED=1' \
        'DNS_XFR_NOTIFY_TARGETS=dns-ssl:5300' 'UI_SESSION_TTL_SECONDS=86400' \
        'LANCACHE_STATE_DIR=/opt/lancache-ng/state' 'CACHE_DIR=/opt/lancache-ng/cache' \
        'CACHE_MAX_SIZE=50g' 'CACHE_MAX_GB=50' 'CACHE_MEM_MB=512' 'CACHE_SLICE_SIZE=8m' \
        'CACHE_VALID_HIT=365d' 'CACHE_VALID_ANY=1m' 'CACHE_INACTIVE=365d' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' 'PROXY_SECURITY_MODE=lazy' \
        'NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4' 'LANCACHE_IMAGE_REGISTRY=ghcr.io' \
        'LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng' 'LANCACHE_IMAGE_CHANNEL=pinned' \
        'LANCACHE_IMAGE_TAG=v0.2.0' 'UI_BIND_IP=192.0.2.10' 'DHCP_ENABLED=0' \
        'DHCP_MODE=disabled' 'DHCP_SUBNET=' 'DHCP_GATEWAY=' 'DHCP_RANGE_START=' \
        'DHCP_RANGE_END=' 'DHCP_SUBNET_START=' 'DHCP_DNS_PRIMARY=192.0.2.10' \
        'DHCP_DNS_SECONDARY=192.0.2.11' 'UPSTREAM_DHCP_IP=' 'DHCP_RELAY_LOCAL_ADDR=' \
        'DHCP_PROXY_INTERFACE=' 'DHCP_PROXY_ROUTER=' 'DHCP_NTP_SERVERS=' \
        'DHCP_PROXY_DOMAIN=' 'DHCP_PROXY_BOOT_FILENAME=' 'DHCP_PROXY_BOOT_SERVER=' \
        'DHCP_PROXY_CUSTOM_OPTIONS=' 'DHCP_PROXY_PXE_BOOT_SERVER=' \
        'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=' 'DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=' \
        'KEA_CTRL_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'DDNS_TSIG_KEY=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
        'PDNS_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        'NETDATA_ALARM_TOKEN=jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj' \
        'NATS_UI_USER=lancache-ui' \
        'NATS_UI_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'NATS_DNS_WRITER_USER=lancache-dns-writer' \
        'NATS_DNS_WRITER_PASSWORD=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
        'NATS_DNS_REPLICA_USER=lancache-dns-replica' \
        'NATS_DNS_REPLICA_PASSWORD=gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg' \
        'NATS_CALLOUT_USER=lancache-nats-callout' \
        'NATS_CALLOUT_PASSWORD=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh' \
        'NATS_SYS_USER=lancache-nats-sys' \
        'NATS_SYS_PASSWORD=iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii' \
        'SECONDARY_REGISTRATION_TOKEN=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        'COMPOSE_PROFILES=ssl,logging' 'UI_AUTH_USER=admin' \
        'UI_AUTH_PASSWORD=RealAdminPassword123' 'ALLOW_INSECURE_UI=false' \
        'AUTO_UPDATE_ENABLED=0' 'NTP_ENABLED=0' 'LOGGING_ENABLED=1' \
        > "$1"
}

# What: An old install .env: split cache keys, strict mode.
# Why: Exercises the migration/converge path on first run.
# From: Issue #1683 | PR #1546
_write_legacy_env_fixture() {
    local env_file="$1" ui_auth_user="${2:-}"
    printf '%s\n' \
        'IP_STANDARD=192.0.2.20' 'IP_SSL=' 'CACHE_DIR_STANDARD=/srv/lancache/cache' \
        'CACHE_DIR_SSL=/srv/lancache/cache' 'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' 'LANCACHE_IMAGE_TAG=v0.2.0' \
        "UI_AUTH_USER=${ui_auth_user}" 'UI_AUTH_PASSWORD=' \
        > "$env_file"
}

@test "setup.sh image platform guards map host and manifest" {
    # What: one row per host arch / buildx / manifest case.
    # Why: a tag lacking this platform must fail closed.
    # From: Issue #665 | PR #1858
    local name fn arch nobx fail single multi rc want w
    local -a ws
    _load_setup_update_helpers "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    while IFS='|' read -r name fn arch nobx fail single multi rc want; do
        export SETUP_FAKE_ARCH="${arch}" SETUP_FAKE_NO_BUILDX="${nobx}" \
            SETUP_FAKE_INSPECT_FAIL="${fail}" SETUP_FAKE_SINGLE="${single}" \
            SETUP_FAKE_MULTI="${multi}"
        case "${fn}" in
            host) run host_image_platform "${arch}" ;;
            prebuilt) run assert_prebuilt_image_platform_supported ;;
            resolved) run assert_resolved_image_tag_platform_supported \
                registry.example.test owner/fixture-repo t1 ;;
        esac
        [ "${status}" -eq "${rc}" ] || { echo "${name}: rc ${status}: ${output}"; return 1; }
        [ "${want}" = - ] && continue
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            [[ "${output}" == *"${w}"* ]] || { echo "${name}: no '${w}': ${output}"; return 1; }
        done
    done <<'CASES'
host-x86_64|host|x86_64|0|0|-|-|0|linux/amd64
host-amd64|host|amd64|0|0|-|-|0|linux/amd64
host-aarch64|host|aarch64|0|0|-|-|0|linux/arm64
host-arm64|host|arm64|0|0|-|-|0|linux/arm64
host-unknown|host|riscv64|0|0|-|-|1|-
prebuilt-x86_64|prebuilt|x86_64|0|0|-|-|0|-
prebuilt-aarch64|prebuilt|aarch64|0|0|-|-|0|-
prebuilt-unknown|prebuilt|riscv64|0|0|-|-|1|linux/amd64 and linux/arm64;'riscv64'
tag-lacks-platform|resolved|aarch64|0|0|linux/amd64|-|1|does not publish a linux/arm64 image;published: linux/amd64
tag-single-match|resolved|x86_64|0|0|linux/amd64|-|0|-
tag-index-fallback|resolved|aarch64|0|0|<no value>/<no value>|linux/amd64,linux/arm64|0|-
tag-unknown-host|resolved|riscv64|0|0|-|-|1|linux/amd64 and linux/arm64
tag-no-buildx|resolved|x86_64|1|0|-|-|1|docker buildx is required
tag-unreachable|resolved|x86_64|0|1|-|-|1|Failed to inspect registry.example.test/owner/fixture-repo/dns:t1;fake registry unreachable
CASES
    # What: no docker on PATH fails closed, not silently.
    # Why: the guard must never skip without its tool.
    # From: Issue #1683 | PR #1858
    unset -f docker
    export SETUP_FAKE_ARCH=x86_64
    PATH="" run assert_resolved_image_tag_platform_supported registry.example.test owner/fixture-repo t1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"docker is required"* ]]
}

@test "migrate_env_for_update is a no-op on an already-converged .env" {
    # What: .env stays byte-identical.
    # Why: Idempotent, no rewrite.
    # From: Issue #1683 | PR #1546
    local repo_root env_file oh h1 h2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    oh="$(sha256sum "${env_file}" | awk '{print $1}')"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    h1="$(sha256sum "${env_file}" | awk '{print $1}')"; [ "${oh}" = "${h1}" ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    h2="$(sha256sum "${env_file}" | awk '{print $1}')"; [ "${h1}" = "${h2}" ]
}

@test "migrate_env_for_update runs cleanly under set -u" {
    # What: A quickstart install must not trip nounset.
    # Why: Unset prodsync guarded.
    # From: Issue #1683 | PR #1546
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    set -u
    _write_converged_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
}

@test "migrate_env_for_update converges a legacy .env and is stable on rerun" {
    # What: Legacy keys migrate once.
    # Why: AG-OP-007 convergence; secrets must not rotate.
    # From: Issue #1683 | PR #1546
    local repo_root env_file a1 a2 s1 s2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run ! grep -q '^CACHE_DIR_STANDARD=' "${env_file}"
    run ! grep -q '^CACHE_DIR_SSL=' "${env_file}"
    grep -qx 'CACHE_DIR=/srv/lancache/cache' "${env_file}"
    grep -qx 'PROXY_SECURITY_MODE=lazy' "${env_file}"
    a1="$(cat "${env_file}")"
    s1="$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "${env_file}" | sort)"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    a2="$(cat "${env_file}")"
    s2="$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "${env_file}" | sort)"
    [ "${a1}" = "${a2}" ]; [ "${s1}" = "${s2}" ]
}

@test "migrate_env_for_update generates a UI password once, never rotates it" {
    # What: UI-password branch runs once.
    # Why: AG-OP-006 stable secrets on repeat execution.
    # From: Issue #1683 | PR #1546
    local repo_root env_file gp p2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}" admin
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    grep -qx 'UI_AUTH_USER=admin' "${env_file}"
    gp="$(grep '^UI_AUTH_PASSWORD=' "${env_file}")"
    [ -n "${gp}" ]; [ "${gp}" != "UI_AUTH_PASSWORD=" ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    p2="$(grep '^UI_AUTH_PASSWORD=' "${env_file}")"; [ "${gp}" = "${p2}" ]
}

@test "migrate_env_for_update leaves no duplicate key assignments" {
    # What: Two runs must not stack duplicate key lines.
    # Why: set_env_key collapses duplicates (AG-OP-006).
    # From: Issue #1683 | PR #1546
    local repo_root env_file dup
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    dup="$(awk -F= '{print $1}' "${env_file}" | sort | uniq -d)"; [ -z "${dup}" ]
}

@test "migrate_env_for_update keeps config/prod values per row" {
    # What: prod layout per row: run, edit, run, compare.
    # Why: AG-OP-009: operator config/prod values survive.
    # From: Issue #1683 | PR #1858
    local repo_root name extra cpe_init env_want edit cpe_want
    local base pd cpe kv
    local -a kvs
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    while IFS='|' read -r name extra cpe_init env_want edit cpe_want; do
        base="${BATS_TEST_TMPDIR}/${name}"
        pd="${base}/deploy/prod"; cpe="${base}/config/prod/dhcp-proxy.env"
        mkdir -p "${pd}" "${base}/config/prod"
        _write_legacy_env_fixture "${pd}/.env"
        [ "${extra}" = - ] || tr ';' '\n' <<<"${extra}" >> "${pd}/.env"
        tr ';' '\n' <<<"${cpe_init}" > "${cpe}"
        run migrate_env_for_update "${pd}"
        [ "${status}" -eq 0 ] || { echo "${name}: run 1 rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a kvs <<<"${env_want}"
        for kv in "${kvs[@]}"; do
            [ "${kv}" = - ] && continue
            grep -qx -- "${kv}" "${pd}/.env" || {
                echo "${name}: .env lacks ${kv}:"; cat "${pd}/.env"; return 1; }
        done
        [ "${edit}" = - ] || set_env_key "${edit%%=*}" "${edit#*=}" "${cpe}"
        run migrate_env_for_update "${pd}"
        [ "${status}" -eq 0 ] || { echo "${name}: run 2 rc ${status}: ${output}"; return 1; }
        IFS=';' read -r -a kvs <<<"${cpe_want}"
        for kv in "${kvs[@]}"; do
            run get_env_var "${kv%%=*}" "${cpe}"
            [ "${output}" = "${kv#*=}" ] || {
                echo "${name}: ${kv%%=*}='${output}' want '${kv#*=}':"; cat "${cpe}"; return 1; }
        done
    done <<'CASES'
repeated|-|DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9;DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0|DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9;DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0|-|DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9;DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0
direct-edit|-|DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1;DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=pxelinux.0|DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1|DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.2|DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.2
incomplete-pair|DHCP_MODE=dnsmasq-proxy;DHCP_SUBNET_START=192.0.2.0;DHCP_DNS_PRIMARY=192.0.2.20;UPSTREAM_DHCP_IP=192.0.2.1|DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9|-|-|DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9
invalid-value|DHCP_MODE=dnsmasq-proxy;DHCP_SUBNET_START=192.0.2.0;DHCP_DNS_PRIMARY=192.0.2.20;UPSTREAM_DHCP_IP=192.0.2.1|DHCP_PROXY_ROUTER=not-an-ip-address|-|-|DHCP_PROXY_ROUTER=not-an-ip-address
CASES
}

@test "migrate_env_for_update preserves all custom per-service state dirs" {
    # What: Custom per-service state dirs survive.
    # Why: AG-OP-009 override preservation.
    # From: Issue #1683 | PR #1858
    local repo_root env_file k
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        printf '%s=/custom/%s\n' "${k}" "${k}" >> "${env_file}"
    done
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        grep -qx "${k}=/custom/${k}" "${env_file}"
    done
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        grep -qx "${k}=/custom/${k}" "${env_file}"
    done
}

@test "migrate_env_for_update drops a per-service state dir equal to the one-root default" {
    # What: Default per-service dir is dropped.
    # Why: One-root contract via LANCACHE_STATE_DIR.
    # From: Issue #1683 | PR #1858
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    printf 'NATS_CONF_DIR=/opt/lancache-ng/state/nats-conf\n' >> "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run ! grep -q '^NATS_CONF_DIR=' "${env_file}"
}

@test "migrate_env_for_update writes LANCACHE_STATE_DIR on a legacy .env" {
    # What: One-root key present after legacy migration.
    # Why: LANCACHE_STATE_DIR single state-root contract.
    # From: Issue #1683 | PR #1858
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run ! grep -q '^LANCACHE_STATE_DIR=' "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    grep -q '^LANCACHE_STATE_DIR=/' "${env_file}"
}

@test "production_state_root_default keeps deploy/prod state out of the checkout" {
    # What: Deploy/prod state defaults off checkout.
    # Why: Runtime state outside git checkout.
    # From: Issue #1683 | PR #1858
    local repo_root root
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    root="$(production_state_root_default /srv/checkout/deploy/prod)"
    [ -n "${root}" ]
    [ "${root}" != "/srv/checkout/deploy/prod" ]
    [ "$(production_state_root_default /var/lib/lancache)" = "/var/lib/lancache" ]
}

@test "runtime_env_file_for_install_dir prefers deploy/prod/.env.local when present" {
    # What: Deploy/prod prefers .env.local override.
    # Why: a git pull must not clobber operator prod values.
    # From: Issue #1683 | PR #1858
    local repo_root dp
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    dp="${BATS_TEST_TMPDIR}/deploy/prod"
    mkdir -p "${dp}"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env" ]
    : > "${dp}/.env.local"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env.local" ]
    [ "$(runtime_env_file_for_install_dir /var/lib/lancache)" = "/var/lib/lancache/.env" ]
}

@test "deploy_prod_repo_input_paths snapshots repo-root runtime inputs for deploy/prod" {
    # What: Backup captures repo-root inputs.
    # Why: Rollback restores prod config.
    # From: Issue #1683 | PR #1858
    local repo_root rr dp
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    rr="${BATS_TEST_TMPDIR}/checkout"
    dp="${rr}/deploy/prod"
    mkdir -p "${dp}" "${rr}/certs" "${rr}/config/prod" "${rr}/services/dns" \
        "${rr}/scripts/untracked" "${rr}/scripts/lib"
    : > "${rr}/services/dns/cdn-domains.txt"
    : > "${rr}/scripts/untracked/docker-socket-proxy.sh"
    : > "${rr}/scripts/lib/shared-secret-bootstrap.sh"
    run deploy_prod_repo_input_paths "${dp}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/certs"* ]]
    [[ "${output}" == *"/config/prod"* ]]
    [[ "${output}" == *"cdn-domains.txt"* ]]
    [[ "${output}" == *"docker-socket-proxy.sh"* ]]
    [[ "${output}" == *"shared-secret-bootstrap.sh"* ]]
    run deploy_prod_repo_input_paths /var/lib/lancache
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "apk-setup maps each case: steps, tagged repos, keys, CA" {
    # What: fixture root + apk stub per row: calls, codes.
    # Why: one owner sets repos, keys, CA and apk steps.
    # From: Issue #1683 | PR #1858
    local name pkgs repos keys ca fail want r bin w key sha
    local -a ws p
    bin="${BATS_TEST_TMPDIR}/apkbin"; mkdir -p "${bin}"
    _tool_stub "${bin}" apk <<'STUB'
echo "APK $* cert=${SSL_CERT_FILE:-none}"
if [ -n "${SSL_CERT_FILE:-}" ] && grep -q PROXYCA "${SSL_CERT_FILE}"; then echo "CA-IN-BUNDLE"; fi
[ "$1" != "${APK_FAIL:-}" ] || { echo "apk-boom"; exit 3; }
STUB
    key="${BATS_TEST_TMPDIR}/key.pub"; printf 'KEYDATA\n' > "${key}"
    sha="$(sha256sum "${key}")"; sha="${sha%% *}"
    while IFS='|' read -r name pkgs repos keys ca fail want; do
        r="${BATS_TEST_TMPDIR}/root-${name}"
        mkdir -p "${r}/etc/apk/keys" "${r}/etc/ssl/certs" "${r}/run/secrets"
        printf 'https://dl.example/main\n' > "${r}/etc/apk/repositories"
        printf 'SYSCA\n' > "${r}/etc/ssl/certs/ca-certificates.crt"
        [ -z "${ca}" ] || printf 'PROXYCA\n' > "${r}/run/secrets/project_selfhosted_proxy_ca"
        keys="${keys//@SHA@/${sha}}"
        read -r -a p <<<"${pkgs}"
        PATH="${bin}:${PATH}" CI_APK_ROOT="${r}" APK_TAGGED_REPOS="${repos}" APK_KEYS="${keys}" APK_FAIL="${fail}" \
        CI_HTTP_DOWNLOAD_CMD="$(_stub "dl-${name}" "cp '${key}' \"\$2\"")" \
            run bash "${CI_SH}" apk-setup "${p[@]}"
        IFS=';' read -r -a ws <<<"${want}"
        for w in "${ws[@]}"; do
            case "${w}" in
                rc=*) [ "${status}" -eq "${w#rc=}" ] ;;
                file:*) grep -qF -- "${w#file:}" "${r}/etc/apk/repositories" ;;
                key) [ "$(cat "${r}/etc/apk/keys/key.pub")" = KEYDATA ] ;;
                nokey) [ ! -e "${r}/etc/apk/keys/key.pub" ] ;;
                sysca) [ "$(cat "${r}/etc/ssl/certs/ca-certificates.crt")" = SYSCA ] ;;
                !*) [[ "${output}" != *"${w#!}"* ]] ;;
                *) [[ "${output}" == *"${w}"* ]] ;;
            esac || { echo "${name}: '${w}': rc ${status}: ${output}"; return 1; }
        done
    done <<'CASES'
plain|a b|||||rc=0;file:http://dl.example/main;APK update --no-cache;APK upgrade --no-cache;APK add --no-cache a b;!CA-IN-BUNDLE
no-pkgs||||||rc=0;APK upgrade --no-cache;!APK add
tagged|curl n@ng|ng=http://ng.example/v3.24/main|http://k.example/key.pub=@SHA@|||rc=0;APK add --no-cache curl;APK add --no-cache n@ng;file:@ng http://ng.example/v3.24/main;key
key-mismatch|curl n@ng|ng=http://ng.example/main|http://k.example/key.pub=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|||rc=2;CI-ERROR-FETCH-0003;!APK add --no-cache n@ng
upgrade-fails|a||||upgrade|rc=2;CI-ERROR-APKSETUP-0005;apk-boom;!APK add
proxy-ca|a|||y||rc=0;CA-IN-BUNDLE;sysca
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
    # shellcheck source=/dev/null
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
    [ "${status}" -eq 0 ] && [ ! -f "${PURGE_STAMP}" ]
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
    [ ! -e "${d}/fluent-bit.log.20260104T000000Z" ] && [ ! -e "${d}/fluent-bit.log.20260103T000000Z" ]
    [ -e "${d}/fluent-bit.log.20260102T000000Z" ] && [ -e "${d}/fluent-bit.log.20260101T000000Z" ]
    [ "$(find "${d}" -maxdepth 1 -name 'fluent-bit.log.*' | grep -c .)" -eq 3 ]
    # What: a second call right after is a no-op.
    # Why: it runs every cycle; it must keep the backups.
    # From: Issue #1236 | PR #1858
    before="$(ls -1 "${d}")"
    run maybe_rotate_fluent_bit_selflog
    [ "${status}" -eq 0 ] && [ "$(ls -1 "${d}")" = "${before}" ]
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
    [ "${status}" -eq 0 ] && [ ! -e "${d}/hostA/old.log" ] && [ -e "${d}/hostA/new.log" ]
    touch -d '-999 days' "${d}/hostA/new.log"
    run maybe_prune_syslog
    [ "${status}" -eq 0 ] && [ -z "${output}" ] && [ -e "${d}/hostA/new.log" ]
}

@test "retention stops promptly with rc 0 on SIGTERM mid-sleep" {
    # What: a real TERM during the interval sleep ends it.
    # Why: PID 1 bash ignored TERM; docker stop had to kill.
    # From: Issue #1683 | PR #1858
    local t="${BATS_TEST_TMPDIR}/ret" pid kid="" c i rc=0
    mkdir -p "${t}/cache/lancache" "${t}/state" "${t}/log/syslog" "${t}/lib/fb"
    CACHE_DIR="${t}/cache/lancache" CACHE_DIR_ALLOWED_PREFIX="${t}/cache" \
        PURGE_STAMP="${t}/state/purge.stamp" SYSLOG_ENABLED=false \
        SYSLOG_PRUNE_STAMP="${t}/state/syslog.stamp" SYSLOG_LOG_ROOT="${t}/log/syslog" \
        SYSLOG_LOG_ROOT_ALLOWED_PREFIX="${t}/log" FLUENT_BIT_SELFLOG_DIR="${t}/lib/fb" \
        FLUENT_BIT_SELFLOG_DIR_ALLOWED_PREFIX="${t}/lib" RETENTION_INTERVAL=60 \
        bash "${BATS_TEST_DIRNAME}/../../services/watchdog/retention.sh" > "${t}/out.log" 2>&1 &
    pid=$!
    for i in $(seq 1 100); do
        for c in $(cat "/proc/${pid}/task/${pid}/children" 2>&1); do
            [ "$(cat "/proc/${c}/comm" 2>&1)" = sleep ] && kid="${c}"
        done
        [ -n "${kid}" ] && break
        sleep 0.1
    done
    [ -n "${kid}" ] || { echo "never reached the sleep:"; cat "${t}/out.log"; kill "${pid}"; return 1; }
    kill -TERM "${pid}"
    for i in $(seq 1 50); do [ -d "/proc/${pid}" ] || break; sleep 0.1; done
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
    local lib v1 v i
    lib="$(ci_context_path shared-secret)"
    # shellcheck source=scripts/lib/shared-secret-bootstrap.sh
    source "${BATS_TEST_DIRNAME}/../../${lib}"
    export LANCACHE_SHARED_SECRET_DIR="${BATS_TEST_TMPDIR}/secrets"
    LANCACHE_SHARED_SECRET_GID="$(id -g)"; export LANCACHE_SHARED_SECRET_GID
    _gen() { printf 'g\n' >> "${BATS_TEST_TMPDIR}/gen.log"; printf 'v-%s' "${RANDOM}"; }
    v1="$(resolve_shared_secret s1 "" _gen)"
    [ -n "${v1}" ]
    for i in 1 2 3; do
        v="$(resolve_shared_secret s1 "" _gen)"
        [ "${v}" = "${v1}" ]
    done
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/gen.log")" -eq 1 ]
    for i in 1 2; do
        v="$(resolve_shared_secret s1 real-value _gen)"
        [ "${v}" = real-value ]
        [ "$(cat "${LANCACHE_SHARED_SECRET_DIR}/s1")" = real-value ]
    done
    [ "$(resolve_shared_secret s1 "" _gen)" = real-value ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/gen.log")" -eq 1 ]
}

@test "prod nats command regenerates nats.conf idempotently" {
    # What: run the real prod nats command via compose.
    # Why: AG-OP-006; no image owns it, compose does.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.." bin="${BATS_TEST_TMPDIR}/bin"
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
