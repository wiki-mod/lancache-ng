#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression coverage for issue #1558: cmd_secondary()'s "Registering
# secondary" step builds its JSON registration body via printf, so a literal
# '"' or '\' in $token/$name/$listen_ip previously corrupted the body's JSON
# structure before it ever reached curl -- the same bug class fixed earlier
# for kea_ctrl_post's Basic-Auth credential (issue #1304, PR #1550), which
# this file's extraction/mocking technique mirrors
# (tests/bats/setup_reset_last_known_good_config.bats's kea_ctrl_post
# coverage).
#
# setup.sh is a top-level script, not a sourceable library, so the real
# "Registering secondary" fragment (escaping + printf + curl call) is
# extracted verbatim from setup.sh by line-content markers (not duplicated
# by hand) and executed for real against a mock curl placed ahead of the
# real one on PATH -- the JSON body curl actually receives on stdin (`-d @-`)
# is logged and asserted to be valid, correctly round-tripping JSON, not
# merely eyeballed.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    mock_bin="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_bin"

    export MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl-body.log"
    : > "$MOCK_CURL_LOG"

    # Mock curl: the real invocation sends the JSON body via `-d @-` (stdin),
    # deliberately not a literal `-d "..."` argv value -- see the fragment's
    # own comment on that exposure class (#955/#956). This mock reads that
    # same stdin body and logs it verbatim (not re-serialized), so the test
    # asserts on the exact bytes curl would have transmitted. MOCK_CURL_FAIL
    # simulates a transport failure (curl exiting non-zero, as it does when
    # it cannot connect).
    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_CURL_FAIL:-0}" == "1" ]]; then exit 7; fi
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "-o" ]] && out="${args[$((i + 1))]}"
done
body="$(cat)"
printf '%s' "$body" > "${MOCK_CURL_LOG:?}"
[[ -n "$out" ]] && printf '%s' "${MOCK_CURL_BODY:-{\"secondary_id\":\"sec-1\"}}" > "$out"
printf '%s' "${MOCK_CURL_STATUS:-200}"
MOCK
    chmod +x "$mock_bin/curl"

    export PATH="$mock_bin:$PATH"
}

# Extracts the real "Registering secondary" fragment (mktemp/trap setup,
# the per-field escaping, the JSON-body printf, and the curl call/die guard)
# verbatim from setup.sh, bounded by the print_step banner that starts it
# and the closing `fi` of its `if ! http_status=...; then die ...; fi` --
# the same "capture real lines by content marker, not line number" technique
# extract_cmd_secondary_heredoc() (this directory's sibling
# setup_secondary_docker_compose.bats) and extract_auth_call()
# (dhcp_healthcheck_placeholder_parity.bats, PR #1550) already use, so a
# future edit to the real code is exercised here automatically instead of
# silently drifting from a hand-copied duplicate.
extract_register_secondary_fragment() {
    awk '
        /print_step "Registering secondary"/ { capture = 1 }
        capture { print }
        capture && /^    fi$/ { exit }
    ' "$repo_root/setup.sh"
}

# Runs the extracted fragment in a fresh bash -c child (so its `local`
# declarations and EXIT trap behave exactly as they do inside the real
# cmd_secondary function body) with $token/$name/$listen_ip/$primary set to
# the given values, and print_step/die stubbed the same minimal way the
# kea_ctrl_post extraction stubs its own cross-cutting dependencies. Writes
# the fragment's own $http_status and $response to the given output files so
# the caller can assert on them after the child exits.
run_register_secondary_fragment() {
    local test_token="$1" test_name="$2" test_listen_ip="$3"
    local status_out="$4" response_out="$5"
    local fragment
    fragment="$(extract_register_secondary_fragment)"
    [[ -n "$fragment" ]] || return 91

    # The fragment is wrapped in a real function (via eval), not run as
    # loose top-level statements, so its `local` declarations behave exactly
    # as they do inside the real cmd_secondary() body -- bash's `local`
    # errors ("can only be used in a function") outside one. OUT_STATUS/
    # OUT_RESPONSE are plain (non-local) variables the wrapped function can
    # still see after the fragment's own `local`-scoped $http_status/
    # $response go out of scope when it returns.
    bash -c '
        print_step() { :; }
        die() { printf "DIE: %s\n" "$*" >&2; exit 9; }
        token="$1"; name="$2"; listen_ip="$3"
        primary="http://primary.example:8080"
        OUT_STATUS="$5"; OUT_RESPONSE="$6"
        eval "run_fragment() { $4
printf %s \"\$http_status\" > \"\$OUT_STATUS\"
printf %s \"\$response\" > \"\$OUT_RESPONSE\"
}"
        run_fragment
    ' _ "$test_token" "$test_name" "$test_listen_ip" "$fragment" "$status_out" "$response_out"
}

# The historical bug: an unescaped '"' in $token broke the JSON body's
# structure. This proves the fragment as it exists in setup.sh right now no
# longer does that -- if the escaping in setup.sh ever regressed, `jq empty`
# below would fail the same way it does against the raw pre-fix body in the
# next test.
@test "register_secondary JSON body stays valid JSON when the token contains a double-quote and backslash" {
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'mal"icious\token' 'sec1' '192.168.1.50' "$status_out" "$response_out"
    [ "$status" -eq 0 ]

    [ -s "$MOCK_CURL_LOG" ]
    jq empty < "$MOCK_CURL_LOG"

    run jq -e '.token == "mal\"icious\\token" and .name == "sec1" and .address == "192.168.1.50"' < "$MOCK_CURL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# Regression guard: reproduces the pre-fix corruption directly (bypassing
# the fix) to prove the JSON-parse failure above is a real, meaningful
# assertion and not a test that would pass regardless of escaping.
@test "an unescaped JSON body (pre-fix shape) genuinely fails to parse for the same malicious token" {
    unescaped_body=$(printf '{"token":"%s","name":"%s","address":"%s"}' 'mal"icious\token' 'sec1' '192.168.1.50')
    run bash -c 'jq empty <<< "$1"' _ "$unescaped_body"
    [ "$status" -ne 0 ]
}

# Values containing only a backslash (no quote) must also survive -- the sed
# idiom escapes backslash and double-quote independently, and escaping order
# matters (backslash first): escaping the quote first would double-escape a
# backslash introduced by that step.
@test "register_secondary JSON body stays valid JSON when name/address-role values contain a backslash" {
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'tok' 'name\with\backslash' '10.0.0.1' "$status_out" "$response_out"
    [ "$status" -eq 0 ]

    jq empty < "$MOCK_CURL_LOG"
    run jq -e '.name == "name\\with\\backslash"' < "$MOCK_CURL_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# Normal-case regression check: ordinary values with no special characters
# must round-trip unchanged, so the fix does not alter behavior for the
# common case.
@test "register_secondary JSON body is unchanged for ordinary values with no special characters" {
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'abcdef0123456789' 'my-secondary-1' '192.168.1.77' "$status_out" "$response_out"
    [ "$status" -eq 0 ]

    [ "$(cat "$MOCK_CURL_LOG")" = '{"token":"abcdef0123456789","name":"my-secondary-1","address":"192.168.1.77"}' ]
    [ "$(cat "$status_out")" = "200" ]
}

# A curl transport failure must still fail closed via the fragment's own die
# guard, unrelated to the escaping fix -- confirms the extraction didn't
# accidentally drop that error path.
@test "register_secondary fragment fails closed via die when curl cannot connect" {
    export MOCK_CURL_FAIL=1
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'tok' 'sec1' '192.168.1.50' "$status_out" "$response_out"
    [ "$status" -eq 9 ]
    [[ "$output" == *"DIE: Failed to connect to primary server"* ]]
}
