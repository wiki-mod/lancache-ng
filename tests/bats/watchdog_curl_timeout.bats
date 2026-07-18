#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #872's curl-timeout fix: get_health() and restart_container()
# used to call `curl -sf ...` against docker-socket-proxy with no
# `--max-time`, so a hung/unresponsive proxy could stall the entire
# single-threaded main loop indefinitely -- no further health checks, no
# restarts, and (before the freshness healthcheck fix, also #872) no
# status.json refresh, with no way for Docker or an operator to notice.
#
# Unlike watchdog_idempotence.bats, this file does NOT redefine
# get_health()/restart_container() as pure stubs -- that would hide exactly
# the bug being tested. Instead it stubs `curl` itself (the actual I/O
# boundary) to record its invocation, so the real function bodies run
# unmodified and the assertion is against the real argument list curl
# receives.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"

    curl_calls_file="$BATS_TEST_TMPDIR/curl-calls.txt"
    : > "$curl_calls_file"
    # Records the full argument list curl was invoked with (one call per
    # line) and prints a minimal Docker inspect JSON body so get_health()'s
    # jq parse still succeeds -- this is a boundary stub for curl itself,
    # not for get_health()/restart_container(), so their real logic
    # (including which curl flags they pass) is what's under test.
    curl() {
        printf '%s\n' "$*" >> "$curl_calls_file"
        echo '{"State":{"Health":{"Status":"healthy"}}}'
    }
}

@test "get_health invokes curl with --max-time" {
    get_health "lancache-proxy" >/dev/null
    run cat "$curl_calls_file"
    [[ "$output" == *"--max-time"* ]]
}

@test "restart_container invokes curl with --max-time" {
    restart_container "lancache-proxy" >/dev/null
    run cat "$curl_calls_file"
    [[ "$output" == *"--max-time"* ]]
}

@test "CURL_MAX_TIME overrides the default and is passed through verbatim" {
    export CURL_MAX_TIME=3
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-curl-max-time.sh"
    curl() {
        printf '%s\n' "$*" >> "$curl_calls_file"
        echo '{"State":{"Health":{"Status":"healthy"}}}'
    }

    get_health "lancache-proxy" >/dev/null
    run cat "$curl_calls_file"
    [[ "$output" == *"--max-time 3 "* ]]
}

@test "get_health still returns unreachable when curl itself fails, even with --max-time set" {
    curl() {
        printf '%s\n' "$*" >> "$curl_calls_file"
        return 1
    }

    result=$(get_health "lancache-proxy")
    [ "$result" = "unreachable" ]
    run cat "$curl_calls_file"
    [[ "$output" == *"--max-time"* ]]
}
