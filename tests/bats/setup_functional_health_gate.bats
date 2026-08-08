#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression coverage for verify_stack_functional_health()'s fail-closed
# behavior: a functional probe whose required tool (curl, dig) is missing
# must report the check as FAILED, not silently skip that half of the check
# and return success -- a skipped check and a passed check must never
# produce the same "healthy" verdict. Also proves the probes still correctly
# fail when the tool IS present but the thing it probes is actually broken
# (unreachable /healthz, non-resolving DNS), so the fail-closed change did
# not accidentally make either probe impossible to fail for its original
# real-break case. Coverage for install_missing_tools/package_name_for_tool
# (the mechanism that keeps curl/dig actually installed on a real run, so
# the fail-closed branch above stays the rare exception) closes out the
# same failure class.
#
# Also covers the healthz probe's own split into a TCP-reachability step, an
# external nginx-identity step, and a container-loopback content step (see
# _verify_healthz_endpoint, _tcp_port_reachable, and
# _external_healthz_response_is_nginx in setup.sh): each must independently
# fail closed (unreachable port; a listener that answers but isn't this
# project's proxy, e.g. a broken compose update remapping port 80 onto a
# different service; a healthy port with no proxy container to exec into),
# and the content probe never depends on the externally published address's
# own source-IP ACL, since it only ever runs against the container's own
# loopback.
#
# PATH is fully replaced per test with a minimal sandbox containing only the
# one external command this function chain actually shells out to (awk, via
# get_env_var) plus whatever curl/dig/apt-get stub a given test wants to
# simulate -- so "curl missing" means curl is genuinely absent from PATH,
# not merely masked by a shell function (command -v also matches functions,
# which would defeat the point of these tests).

bats_require_minimum_version 1.5.0

setup() {
    orig_path="$PATH"

    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-functional-health-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-functional-health-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-functional-health-helpers.sh"
    load_setup_functional_health_helpers "$repo_root" "$helper_file"

    sandbox="$BATS_TEST_TMPDIR/path-sandbox"
    mkdir -p "$sandbox"
    ln -s "$(command -v awk)" "$sandbox/awk"

    env_file="$BATS_TEST_TMPDIR/lancache.env"

    # Default fakes for the split TCP-reachability / container-loopback
    # probe _verify_healthz_endpoint now performs in addition to curl/dig:
    # "port reachable, proxy container present, its loopback /healthz call
    # succeeds" -- so every existing test that only cares about the curl/dig
    # fail-closed behavior doesn't have to know these exist at all. Only the
    # tests that specifically target the new split (TCP unreachable, no
    # container running) override them.
    #
    # _tcp_port_reachable is a real function this project's setup.sh defines
    # (see setup.sh); overriding it here instead of exercising a real network
    # connection keeps this test hermetic against a made-up test IP like
    # "10.0.0.10", the same reason dc_update/docker are overridden as fake
    # functions rather than real binaries in
    # tests/bats/setup_update_health_baseline.bats.
    _tcp_port_reachable() { return 0; }
    # Same reasoning as _tcp_port_reachable above: a real function this
    # project's setup.sh defines (see _external_healthz_response_is_nginx),
    # overridden here so every existing test that doesn't specifically
    # target the nginx-identity step doesn't have to know it exists.
    _external_healthz_response_is_nginx() { return 0; }
    service_container_id() { printf '%s' "fake-proxy-container-id"; }
    # Delegates "docker exec <id> <cmd...>" to the real command on PATH
    # (curl, in this file's case) so the existing curl-success/failure stubs
    # below drive the container-loopback probe's outcome too, exactly like
    # they drove the old single external curl call.
    docker() {
        if [[ "$1" = "exec" ]]; then
            shift 2
            "$@"
            return $?
        fi
        return 0
    }
}

# Tests below replace PATH with the sandbox for the `run` call and never
# restore it -- left unrestored, bats' own post-test tmpdir cleanup (which
# shells out to `rm`) fails with "command not found" since the sandbox has
# no `rm`. Restoring here keeps that cleanup on the real PATH regardless of
# what a test pointed PATH at.
teardown() {
    PATH="$orig_path"
}

write_env() {
    cat > "$env_file" <<EOF
IP_STANDARD=$1
IP_SSL=$2
SSL_ENABLED=$3
EOF
    _UPDATE_ENV_FILE="$env_file"
}

stub_tool() {
    local name="$1" exit_code="$2" stdout="${3:-}"
    # #!/bin/bash, not #!/usr/bin/env bash: PATH is fully replaced by the
    # caller (see the file header), so an env-indirected shebang would have
    # `env` itself search that same restricted PATH for `bash` and fail with
    # "No such file or directory" the moment this stub is actually executed
    # (not just `command -v`-checked) -- turning every real/broken probe
    # scenario into an indistinguishable exec failure.
    cat > "$sandbox/$name" <<EOF
#!/bin/bash
printf '%s' '$stdout'
exit $exit_code
EOF
    chmod +x "$sandbox/$name"
}

@test "fails closed when curl is missing instead of silently skipping the HTTP probe" {
    write_env "10.0.0.10" "" "0"
    stub_tool dig 0 "1.2.3.4"
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"curl"* ]]
}

@test "fails closed when dig is missing instead of silently skipping the DNS probe" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 0 ""
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"dig"* ]]
}

@test "still fails when curl is present but the HTTP endpoint is actually broken" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 22 ""
    stub_tool dig 0 "1.2.3.4"
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"healthz"* ]]
}

@test "still fails when dig is present but DNS does not resolve" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 0 ""
    stub_tool dig 0 ""
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"DNS did not resolve"* ]]
}

@test "passes when both tools are present and both probes succeed" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 0 ""
    stub_tool dig 0 "1.2.3.4"
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 0 ]
}

@test "fails when the published port's TCP connect fails, independent of the container's own health" {
    write_env "10.0.0.10" "" "0"
    stub_tool dig 0 "1.2.3.4"
    _tcp_port_reachable() { return 1; }
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"TCP connect"* ]]
}

@test "fails when the published port answers but not as this project's nginx proxy" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 0 ""
    stub_tool dig 0 "1.2.3.4"
    _external_healthz_response_is_nginx() { return 1; }
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not answer as this project's nginx proxy"* ]]
}

@test "_external_healthz_response_is_nginx accepts a 403 from the healthz ACL as long as the Server header is nginx" {
    stub_tool curl 0 "HTTP/1.1 403 Forbidden
Server: nginx/1.27.0
Content-Type: text/html"
    PATH="$sandbox"
    hash -r
    # setup()'s own blanket `_external_healthz_response_is_nginx() { return
    # 0; }` fake (installed so every OTHER test doesn't have to know this
    # function exists) shadows the real one sourced from setup.sh in this
    # same shell. Re-sourcing the whole helper file would fail on its
    # `readonly` globals the second time; redefine just this one function by
    # re-extracting it from the real setup.sh instead.
    eval "$(awk '/^_external_healthz_response_is_nginx\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$repo_root/setup.sh")"
    run _external_healthz_response_is_nginx "10.0.0.10"
    [ "$status" -eq 0 ]
}

@test "_external_healthz_response_is_nginx rejects a response from a non-nginx service" {
    stub_tool curl 0 "HTTP/1.1 200 OK
Server: SomeOtherService/1.0
Content-Type: application/json"
    PATH="$sandbox"
    hash -r
    eval "$(awk '/^_external_healthz_response_is_nginx\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$repo_root/setup.sh")"
    run _external_healthz_response_is_nginx "10.0.0.10"
    [ "$status" -eq 1 ]
}

@test "_external_healthz_response_is_nginx fails when curl itself cannot connect" {
    stub_tool curl 7 ""
    PATH="$sandbox"
    hash -r
    eval "$(awk '/^_external_healthz_response_is_nginx\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$repo_root/setup.sh")"
    run _external_healthz_response_is_nginx "10.0.0.10"
    [ "$status" -eq 1 ]
}

@test "fails when no proxy container is running to probe healthz through" {
    write_env "10.0.0.10" "" "0"
    stub_tool curl 0 ""
    stub_tool dig 0 "1.2.3.4"
    service_container_id() { printf ''; }
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"no running 'proxy' container"* ]]
}

@test "does not require curl or dig when no IP is configured" {
    write_env "" "" "0"
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 0 ]
}

@test "fails closed on the SSL endpoint's curl probe when SSL_ENABLED=1 even without IP_STANDARD" {
    write_env "" "10.0.0.11" "1"
    PATH="$sandbox"
    hash -r
    run verify_stack_functional_health
    [ "$status" -eq 1 ]
    [[ "$output" == *"curl"* ]]
}

@test "package_name_for_tool maps dig to a real Debian package name" {
    run package_name_for_tool dig
    [ "$status" -eq 0 ]
    [[ "$output" == "bind9-dnsutils" || "$output" == "dnsutils" ]]
}

@test "package_name_for_tool returns the tool name unchanged when package and binary names match" {
    run package_name_for_tool tar
    [ "$status" -eq 0 ]
    [ "$output" = "tar" ]
}

@test "install_missing_tools returns success without invoking apt-get when all tools are already present" {
    stub_tool curl 0 ""
    stub_tool dig 0 "1.2.3.4"
    PATH="$sandbox"
    hash -r
    run install_missing_tools curl dig
    [ "$status" -eq 0 ]
}

@test "install_missing_tools fails closed when no apt-get is available to install a missing tool" {
    PATH="$sandbox"
    hash -r
    run install_missing_tools curl
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot install missing tools automatically"* ]]
}

@test "install_missing_tools fails closed if the tool is still missing after apt-get claims success" {
    # Simulates a broken/incomplete package: apt-get exits 0 but never
    # actually produces a curl binary on PATH.
    stub_tool apt-get 0 ""
    PATH="$sandbox"
    hash -r
    run install_missing_tools curl
    [ "$status" -eq 1 ]
    [[ "$output" == *"still missing"* ]]
}
