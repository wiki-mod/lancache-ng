#!/usr/bin/env bats
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
# PATH is fully replaced per test with a minimal sandbox containing only the
# one external command this function chain actually shells out to (awk, via
# get_env_var) plus whatever curl/dig/apt-get stub a given test wants to
# simulate -- so "curl missing" means curl is genuinely absent from PATH,
# not merely masked by a shell function (command -v also matches functions,
# which would defeat the point of these tests).

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/setup-functional-health-helpers.sh"

    # shellcheck source=tests/bats/helpers/setup-functional-health-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/setup-functional-health-helpers.sh"
    load_setup_functional_health_helpers "$repo_root" "$helper_file"

    sandbox="$BATS_TEST_TMPDIR/path-sandbox"
    mkdir -p "$sandbox"
    ln -s "$(command -v awk)" "$sandbox/awk"

    env_file="$BATS_TEST_TMPDIR/lancache.env"
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
    cat > "$sandbox/$name" <<EOF
#!/usr/bin/env bash
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
