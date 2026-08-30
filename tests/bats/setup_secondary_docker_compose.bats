#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Regression tests for setup.sh's cmd_secondary(): gen
#   secondary docker-compose.yml, and the register_secondary JSON request
#   body sent to the primary.
# Why: guards a docker-compose.yml healthcheck block that re
#   twice, and a printf-built JSON body against unescaped '"'/'\'
#   corrupting its structure.
# From: Issues #652, #946, #955 | PRs #976, #982, #1561

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # What: Mocks curl for register_secondary tests; logs st
    #   received, and can simulate failure via MOCK_CURL_FAIL.
    # Why: the real call sends JSON body via `-d @-` (stdin)
    #   argv, so the mock must read stdin to assert on bytes sent.
    # From: Issue #955 | PR #982
    mock_bin="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_bin"

    export MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl-body.log"
    : > "$MOCK_CURL_LOG"

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
default_body='{"nats_url":"nats://primary.example:4222","nats_user":"sec-1","nats_password":"secret","consumer_name":"sec-1","pdns_api_key":"pdns-secret","ddns_tsig_key":"transfer-secret","dns_xfr_primary":"192.168.1.10:5300"}'
[[ -n "$out" ]] && printf '%s' "${MOCK_CURL_BODY:-$default_body}" > "$out"
printf '%s' "${MOCK_CURL_STATUS:-200}"
MOCK
    chmod +x "$mock_bin/curl"

    export PATH="$mock_bin:$PATH"
}

# What: Extracts the heredoc body cmd_secondary() writes to
#   ${secondary_dir}/docker-compose.yml -- from write_generated_runtime_file
#   (exclusive) through the closing bare "EOF" (exclusive).
# Why: shared by both tests below so extraction logic can't
#   diverge between them, as it briefly did before this helper existed.
# From: PR #981
extract_cmd_secondary_heredoc() {
    local heredoc_start
    heredoc_start=$(grep -n 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml" <<EOF' \
        "$repo_root/setup.sh" | cut -d: -f1)
    [[ -n "$heredoc_start" ]] || return 1

    awk -v start="$heredoc_start" '
        NR <= start { next }
        /^EOF$/ { exit }
        found || /^services:/ { found = 1; print }
    ' "$repo_root/setup.sh"
}

# What: Extracts "Registering secondary" fragment (escaping,
#   JSON-body printf, curl call/die guard) verbatim from setup.sh, bounded
#   by its print_step banner and the closing `fi`.
# Why: capturing by content marker instead of a hand copy me
#   to the real code is exercised here, not a stale duplicate.
# From: Issue #1558 | PR #1561
extract_register_secondary_fragment() {
    awk '
        /print_step "Registering secondary"/ { capture = 1 }
        capture { print }
        capture && /^    fi$/ { exit }
    ' "$repo_root/setup.sh"
}

# What: Runs extracted fragment in a fresh bash -c child wit
#   $token/$name/$listen_ip/$primary set and print_step/die stubbed.
# Why: a real child process (not sourcing into test shell) r
#   the fragment's `local`/EXIT-trap behavior as it runs in cmd_secondary().
# From: Issue #1558 | PR #1561
run_register_secondary_fragment() {
    local test_token="$1" test_name="$2" test_listen_ip="$3"
    local status_out="$4" response_out="$5"
    local fragment
    fragment="$(extract_register_secondary_fragment)"
    [[ -n "$fragment" ]] || return 91

    # What: Wraps fragment in a real function (via eval) rat
    #   loose top-level statements.
    # Why: bash's `local` errors outside a function; OUT_STA
    #   OUT_RESPONSE stay non-local so they survive after the fragment's
    #   own local-scoped vars go out of scope.
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

run_cmd_secondary_full() {
    local run_dir="$1"
    shift
    local helper_file="$BATS_TEST_TMPDIR/setup-secondary-full-helper.sh"
    {
        printf '%s\n' 'print_ok() { printf "OK: %s\n" "$*"; }'
        printf '%s\n' 'print_step() { printf "STEP: %s\n" "$*"; }'
        printf '%s\n' 'print_warn() { printf "WARN: %s\n" "$*" >&2; }'
        printf '%s\n' 'print_error() { printf "ERR: %s\n" "$*" >&2; }'
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 9; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "$repo_root"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^# ── Dispatch subcommands/ { capture = 0 }
            capture { print }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
    assert_prebuilt_image_platform_supported() { :; }
    assert_resolved_image_tag_platform_supported() { :; }
    resolve_lancache_image_tag() { printf "%s\n" "${LANCACHE_IMAGE_TAG:-latest}"; }
    cd "$run_dir" || return 1
    cmd_secondary "$@"
}

@test "cmd_secondary heredoc in setup.sh contains healthcheck block" {
    # What: Asserts generated secondary docker-compose.yml h
    #   includes a healthcheck block, in the right position.
    # Why: this block is critical for PowerDNS health detect
    #   production and had silently regressed out of the heredoc before.
    # From: Issue #652

    local extracted_heredoc
    extracted_heredoc=$(extract_cmd_secondary_heredoc) \
        || skip "Could not find cmd_secondary heredoc start"

    # Verify the essential healthcheck fields are present in order
    echo "$extracted_heredoc" | grep -q "healthcheck:" \
        || fail "healthcheck: block missing"

    # What: Asserts heredoc emits real dig query/response pr
    #   (AG-VAL-018) and explicitly rejects the old bare `rec_control
    #   ping` probe (liveness only, AG-VAL-019).
    # Why: asserting both presence & absence makes a partial
    #   (e.g. merging an older heredoc back in) fail loudly.
    # From: Issue #946 | PR #976
    echo "$extracted_heredoc" | grep -qF 'test: ["CMD-SHELL", "dig @127.0.0.1 content1.steampowered.com A +short +time=2 +tries=1 | grep -q ."]' \
        || fail "healthcheck test command missing or incorrect (expected dig-based query/response probe)"

    if echo "$extracted_heredoc" | grep -qF 'test: ["CMD", "rec_control", "ping"]'; then
        fail "healthcheck test command regressed to the old rec_control-ping-only probe (#946)"
    fi

    echo "$extracted_heredoc" | grep -q "interval: 30s" \
        || fail "healthcheck interval missing"

    echo "$extracted_heredoc" | grep -q "timeout: 5s" \
        || fail "healthcheck timeout missing"

    echo "$extracted_heredoc" | grep -q "retries: 3" \
        || fail "healthcheck retries missing"

    echo "$extracted_heredoc" | grep -q "start_period: 20s" \
        || fail "healthcheck start_period missing"

    echo "$extracted_heredoc" | grep -q "DNS_REPLICATION_ROLE=secondary" \
        || fail "secondary heredoc no longer runs PowerDNS in native secondary mode"

    echo "$extracted_heredoc" | grep -q "NATS_RECORD_WRITES=0" \
        || fail "secondary heredoc no longer disables local NATS record writes"

    echo "$extracted_heredoc" | grep -q "DNS_XFR_PRIMARY=" \
        || fail "secondary heredoc no longer receives the primary AXFR endpoint"

    # Verify the healthcheck block comes after the ports block and before restart
    # by checking line ordering in the extracted heredoc
    local ports_line healthcheck_line restart_line

    ports_line=$(echo "$extracted_heredoc" | grep -n "ports:" | head -1 | cut -d: -f1)
    healthcheck_line=$(echo "$extracted_heredoc" | grep -n "healthcheck:" | head -1 | cut -d: -f1)
    restart_line=$(echo "$extracted_heredoc" | grep -n "restart: always" | head -1 | cut -d: -f1)

    [[ -n "$ports_line" && -n "$healthcheck_line" && -n "$restart_line" ]] \
        || fail "Could not determine line order of ports/healthcheck/restart blocks"

    [[ "$ports_line" -lt "$healthcheck_line" ]] \
        || fail "healthcheck block must come after ports block"

    [[ "$healthcheck_line" -lt "$restart_line" ]] \
        || fail "healthcheck block must come before restart block"
}

@test "cmd_secondary gives an actionable message for the issue #866 HTTP 503 refusal" {
    # What: Asserts cmd_secondary's HTTP 503 branch gives an
    #   NATS-specific message instead of the generic 4xx "verify
    #   token/name/logs" message.
    # Why: register_secondary refuses (503) when primary has
    #   NATS_BIND_IP nor NATS_ADVERTISE_URL configured -- a primary-side
    #   config gap the operator can't fix via their own CLI arguments.
    # From: Issue #866 | PR #881
    grep -q 'http_status" = "503"' "$repo_root/setup.sh" \
        || fail "cmd_secondary no longer special-cases HTTP 503"

    grep -q 'NATS_BIND_IP.*NATS_ADVERTISE_URL' "$repo_root/setup.sh" \
        || fail "the 503 die message no longer names NATS_BIND_IP/NATS_ADVERTISE_URL as the fix"

    # Also asserts the 503 message names nats-secondary.yml specifically:
    #   restarting only `ui` does not republish NATS on the advertised
    #   address, so a message that stops at "restart ui" would leave the
    #   same silent never-syncs failure one step later.
    grep -q 'nats-secondary\.yml' "$repo_root/setup.sh" \
        || fail "the 503 die message no longer tells the operator to recreate the nats service with the nats-secondary.yml override"
}

@test "cmd_secondary's 503 recreate example includes --env-file .env.local for the .env.local case" {
    # What: Asserts 503 message's recreate example includes
    #   --env-file .env.local.
    # Why: Compose only auto-loads default .env, never .env.
    #   recreate command missing this flag leaves
    #   docker-compose.nats-secondary.yml's NATS_BIND_IP guard unset, so
    #   NATS never gets recreated with the override applied.
    # From: PR #881
    grep -q -- '--env-file \.env\.local' "$repo_root/setup.sh" \
        || fail "the 503 die message's recreate example no longer shows --env-file .env.local for the .env.local case"
}

@test "cmd_secondary's registration POST sends the token via stdin, not argv" {
    # What: Asserts registration POST reads its JSON body fr
    #   (`-d @-`), never as a literal `-d "..."` argument.
    # Why: an argv-passed token stays visible in this proces
    #   the whole request (readable via `ps`/`/proc/<pid>/cmdline`) --
    #   same exposure class kea_ctrl_post's Basic-Auth fix closed.
    # From: Issue #955 | PR #982
    grep -q 'curl -sS -o "\$response_file" -w "%{http_code}" -X POST \\' "$repo_root/setup.sh" \
        || fail "cmd_secondary's registration curl invocation not found where expected"

    grep -q -- '-d @-' "$repo_root/setup.sh" \
        || fail "registration POST no longer reads its body from stdin (-d @-) -- token may have regressed back into argv"

    if grep -qF '-d "{\"token\":\"${token}\"' "$repo_root/setup.sh"; then
        fail "registration token has regressed back into curl's argv via a literal -d \"...\" argument"
    fi
}

@test "cmd_secondary collects all missing required arguments and reports them together" {
    # What: Asserts cmd_secondary reports all missing requir
    #   (--primary, --token, --name, --proxy-ip) together, not just the
    #   first one found.
    # Why: matches pattern already used for collecting missi
    #   from the primary server's response; avoids forcing the operator
    #   to re-run the command once per missing argument.
    # From: PR #984

    # Verify the argument validation uses the missing_args array pattern
    grep -q 'missing_args=()' "$repo_root/setup.sh" \
        || fail "cmd_secondary no longer uses missing_args array pattern"

    # Verify all four required arguments are checked and added to the array
    grep -q 'missing_args+=(.*--primary' "$repo_root/setup.sh" \
        || fail "cmd_secondary does not collect missing --primary"

    grep -q 'missing_args+=(.*--token' "$repo_root/setup.sh" \
        || fail "cmd_secondary does not collect missing --token"

    grep -q 'missing_args+=(.*--name' "$repo_root/setup.sh" \
        || fail "cmd_secondary does not collect missing --name"

    grep -q 'missing_args+=(.*--proxy-ip' "$repo_root/setup.sh" \
        || fail "cmd_secondary does not collect missing --proxy-ip"

    # Verify that the error is reported with all missing arguments at once
    # (using ${missing_args[*]} pattern similar to missing_fields)
    grep -q 'die.*missing_args\[' "$repo_root/setup.sh" \
        || fail "cmd_secondary does not report all missing arguments together"
}

# What: proves current escaping in setup.sh keeps JSON body
#   for a token containing a double-quote and backslash.
# Why: the historical bug was an unescaped '"' corrupting JS
#   structure; if escaping regresses, `jq empty` below fails the same way
#   it does against the raw pre-fix body in the next test.
# From: Issue #1558 | PR #1561
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

# What: reproduces pre-fix corrupted JSON body directly, byp
#   the fix.
# Why: proves previous test's `jq empty` failure is a meanin
#   assertion, not one that would fail regardless of escaping.
# From: Issue #1558 | PR #1561
@test "an unescaped JSON body (pre-fix shape) genuinely fails to parse for the same malicious token" {
    unescaped_body=$(printf '{"token":"%s","name":"%s","address":"%s"}' 'mal"icious\token' 'sec1' '192.168.1.50')
    run bash -c 'jq empty <<< "$1"' _ "$unescaped_body"
    [ "$status" -ne 0 ]
}

# What: asserts a backslash-only value (no quote) also survi
#   escaping.
# Why: the sed idiom escapes backslash & quote independently
#   matters -- escaping the quote first would double-escape a backslash
#   introduced by that step.
# From: Issue #1558 | PR #1561
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

# What: asserts ordinary values with no special characters r
#   unchanged.
# Why: confirms escaping fix does not alter behavior for com
#   case.
# From: Issue #1558 | PR #1561
@test "register_secondary JSON body is unchanged for ordinary values with no special characters" {
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'abcdef0123456789' 'my-secondary-1' '192.168.1.77' "$status_out" "$response_out"
    [ "$status" -eq 0 ]

    [ "$(cat "$MOCK_CURL_LOG")" = '{"token":"abcdef0123456789","name":"my-secondary-1","address":"192.168.1.77"}' ]
    [ "$(cat "$status_out")" = "200" ]
}

# What: asserts a curl transport failure still fails closed
#   fragment's own die guard.
# Why: unrelated to escaping fix itself -- confirms extracti
#   didn't accidentally drop that error path.
# From: Issue #1558 | PR #1561
@test "register_secondary fragment fails closed via die when curl cannot connect" {
    export MOCK_CURL_FAIL=1
    status_out="$BATS_TEST_TMPDIR/status.txt"
    response_out="$BATS_TEST_TMPDIR/response.txt"
    run run_register_secondary_fragment 'tok' 'sec1' '192.168.1.50' "$status_out" "$response_out"
    [ "$status" -eq 9 ]
    [[ "$output" == *"DIE: Failed to connect to primary server"* ]]
}

@test "cmd_secondary refuses an existing secondary directory before contacting the primary" {
    run_dir="$BATS_TEST_TMPDIR/full-secondary-existing"
    mkdir -p "$run_dir/sec-a"
    cat > "$run_dir/sec-a/.env" <<'EOF'
PDNS_API_KEY=old
EOF
    cat > "$run_dir/sec-a/docker-compose.yml" <<'EOF'
services: {}
EOF
    : > "$MOCK_CURL_LOG"

    cat > "$mock_bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" = "compose" && "$2" = "version" ]]; then exit 0; fi
if [[ "$1" = "compose" ]]; then exit 0; fi
MOCK
    chmod +x "$mock_bin/docker"

    run run_cmd_secondary_full "$run_dir" \
        --primary http://primary.example:8080 \
        --token tok \
        --name sec-a \
        --proxy-ip 192.168.1.10 \
        --listen-ip 192.168.1.50
    [ "$status" -eq 9 ]
    [[ "$output" == *"already exists"* ]]
    [ ! -s "$MOCK_CURL_LOG" ]
}

@test "cmd_secondary full command path writes converged local files and a second --rotate run keeps them stable" {
    run_dir="$BATS_TEST_TMPDIR/full-secondary-rotate"
    mkdir -p "$run_dir"
    docker_log="$BATS_TEST_TMPDIR/cmd-secondary-docker.log"
    export docker_log
    : > "$MOCK_CURL_LOG"

    cat > "$mock_bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" = "compose" && "$2" = "version" ]]; then exit 0; fi
if [[ "$1" = "compose" ]]; then
  printf '%s\n' "$*" >> "${docker_log:?}"
  exit 0
fi
exit 0
MOCK
    chmod +x "$mock_bin/docker"

    export LANCACHE_IMAGE_TAG="sha-test-secondary"
    export MOCK_CURL_BODY='{"nats_url":"nats://primary.example:4222","nats_user":"sec-a","nats_password":"secret","consumer_name":"sec-a","pdns_api_key":"pdns-secret","ddns_tsig_key":"transfer-secret","dns_xfr_primary":"192.168.1.10:5300"}'

    run run_cmd_secondary_full "$run_dir" \
        --primary http://primary.example:8080 \
        --token tok \
        --name sec-a \
        --proxy-ip 192.168.1.10 \
        --listen-ip 192.168.1.50
    [ "$status" -eq 0 ]

    first_env="$(cat "$run_dir/sec-a/.env")"
    first_compose="$(cat "$run_dir/sec-a/docker-compose.yml")"
    [[ "$first_env" == *"PROXY_IP=192.168.1.10"* ]]
    [[ "$first_env" == *"LISTEN_IP=192.168.1.50"* ]]
    [[ "$first_env" == *"LANCACHE_IMAGE_TAG=sha-test-secondary"* ]]
    [[ "$first_compose" == *"dns-secondary:"* ]]

    run run_cmd_secondary_full "$run_dir" \
        --primary http://primary.example:8080 \
        --token tok \
        --name sec-a \
        --proxy-ip 192.168.1.10 \
        --listen-ip 192.168.1.50 \
        --rotate
    [ "$status" -eq 0 ]

    second_env="$(cat "$run_dir/sec-a/.env")"
    second_compose="$(cat "$run_dir/sec-a/docker-compose.yml")"
    [ "$second_env" = "$first_env" ]
    [ "$second_compose" = "$first_compose" ]
}
