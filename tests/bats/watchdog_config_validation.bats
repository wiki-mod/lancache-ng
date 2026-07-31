#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for the remaining services/watchdog/watchdog.sh startup-config
# fixes bundled in #872 that don't fit watchdog_disk_info.bats,
# watchdog_purge.bats, or watchdog_curl_timeout.bats:
#
#   - CHECK_INTERVAL gets the same digit-only guard the other numeric knobs
#     already had, plus a floor of 1 (a literal 0 would busy-loop).
#   - is_truthy()/SSL_ENABLED: watchdog.sh used to require the exact literal
#     "1" for SSL_ENABLED, diverging from the Admin UI's env_bool(), which
#     also accepts true/yes/on case-insensitively -- SSL_ENABLED=true showed
#     SSL mode enabled in the UI while watchdog silently left dns-ssl
#     unmonitored.
#   - resolve_cache_dir()'s fail-closed diagnostic used to go through log()
#     (stdout), which the `CACHE_DIR="$(resolve_cache_dir)"` command
#     substitution silently captured and discarded -- it must reach stderr.
#   - CONTAINER_PROXY/CONTAINER_DNS_STANDARD/CONTAINER_DNS_SSL: renaming a
#     monitored container is not wired through scripts/docker-socket-proxy.sh's
#     hardcoded HAProxy allowlist (nor the Admin UI's docker_client.rs, which
#     hardcodes the same three names again) -- watchdog now fails loudly at
#     startup on a mismatch instead of silently degrading every health check
#     for that container to "unreachable".
#
# The CONTAINER_* checks call `exit 1` at the top level (not inside a
# function), so they cannot be exercised by sourcing the extracted helper
# range in-process the way every other test in this suite does -- doing so
# would tear down the whole bats worker on a failing case. Those tests
# instead `run` the real watchdog.sh file as its own subprocess (bats' `run`
# already forks/captures), bounded by `timeout` as a safety net.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"
    export STATUS_FILE="$status_file"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"
}

# --- CHECK_INTERVAL -----------------------------------------------------

@test "CHECK_INTERVAL falls back to 30 for non-digit or empty values" {
    for value in "abc" "" "12.5" "-5"; do
        # export, not a `VAR=x cmd` prefix: load_watchdog_functions is a shell
        # function that sources into the CURRENT shell, but bash's prefix-
        # assignment scoping still only lasts for that one call and reverts
        # afterward even though the sourced code reassigns the same name --
        # verified empirically (bash restores/unsets the prefix-assigned
        # variable once the function returns, regardless of what the
        # function body itself assigns). `export` makes the value a real,
        # persistent shell variable so the assertion below observes what the
        # sourced validation logic actually produced.
        export CHECK_INTERVAL="$value"
        load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-$RANDOM.sh"
        [ "$CHECK_INTERVAL" -eq 30 ]
    done
}

@test "CHECK_INTERVAL=0 is floored to 1 instead of busy-looping" {
    export CHECK_INTERVAL=0
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-zero.sh"
    [ "$CHECK_INTERVAL" -eq 1 ]
}

@test "a valid CHECK_INTERVAL passes through unchanged" {
    export CHECK_INTERVAL=45
    load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-valid.sh"
    [ "$CHECK_INTERVAL" -eq 45 ]
}

# --- is_truthy() / SSL_ENABLED ------------------------------------------

@test "is_truthy accepts 1/true/yes/on case-insensitively and trims whitespace" {
    for value in "1" "true" "TRUE" "True" "yes" "YES" "on" "ON" " true " $'\ton\t'; do
        run is_truthy "$value"
        [ "$status" -eq 0 ] || {
            echo "expected is_truthy [$value] to succeed (truthy)" >&2
            return 1
        }
    done
}

@test "is_truthy rejects 0/false/no/off and unrecognized/empty values" {
    for value in "0" "false" "FALSE" "no" "off" "" "   " "garbage" "1x" "truex"; do
        run is_truthy "$value"
        [ "$status" -eq 1 ] || {
            echo "expected is_truthy [$value] to fail (not truthy)" >&2
            return 1
        }
    done
}

# End-to-end: before this fix, only the exact literal "1" enabled SSL
# monitoring. Reload the helper with each Admin-UI-truthy spelling and
# confirm the normalized SSL_ENABLED/C_DNS_SSL actually flow through to
# write_status()'s DNS-SSL block, not just that is_truthy() itself returns
# true in isolation.
@test "SSL_ENABLED accepts every Admin-UI-truthy spelling and monitors dns-ssl" {
    # Also covers the unset/empty case implicitly: `${SSL_ENABLED:-1}`
    # treats an explicitly-empty value the same as unset and falls back to
    # "1", exactly like the Admin UI's env_bool("SSL_ENABLED", true) falls
    # back to its own `true` default when trim().to_ascii_lowercase()
    # matches neither the truthy nor falsy set. "" is deliberately included
    # here (not in the falsy test below) for that reason.
    for value in "1" "true" "TRUE" "yes" "on" " true " ""; do
        # export, not a `VAR=x cmd` prefix -- see the CHECK_INTERVAL test
        # above for why the prefix form doesn't work for a sourcing function.
        export SSL_ENABLED="$value"
        load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-ssl-$RANDOM.sh"
        [ "$SSL_ENABLED" = "1" ]
        [ "$C_DNS_SSL" = "lancache-dns-ssl" ]

        # shellcheck disable=SC2034 # read by write_status() (sourced from
        # services/watchdog/watchdog.sh via load_watchdog_functions above) --
        # this is a cross-file dynamic-scope read static analysis cannot see.
        F_DNS_SSL=0
        # shellcheck disable=SC2034 # see F_DNS_SSL comment above
        H_DNS_SSL="healthy"
        write_status
        run jq -e '.services["lancache-dns-ssl"]' "$status_file"
        [ "$status" -eq 0 ] || {
            echo "expected SSL_ENABLED=[$value] to produce a dns-ssl status block" >&2
            return 1
        }
    done
}

@test "SSL_ENABLED treats every Admin-UI-falsy spelling as disabled (dns-ssl unmonitored)" {
    # "" is deliberately NOT in this list -- see the truthy test above for
    # why an explicitly-empty value defaults to enabled instead.
    for value in "0" "false" "off" "garbage"; do
        export SSL_ENABLED="$value"
        load_watchdog_functions "$repo_root" "$BATS_TEST_TMPDIR/reload-nossl-$RANDOM.sh"
        [ "$SSL_ENABLED" = "0" ]
        [ -z "$C_DNS_SSL" ]
    done
}

# --- resolve_cache_dir() stderr -----------------------------------------

@test "resolve_cache_dir's fail-closed error reaches stderr, not stdout" {
    unset CACHE_DIR
    export CACHE_DIR_STANDARD=/mnt/standard
    export CACHE_DIR_SSL=/mnt/ssl

    run --separate-stderr resolve_cache_dir

    [ "$status" -ne 0 ]
    # shellcheck disable=SC2154 # $stderr is populated by Bats itself via
    # `run --separate-stderr` (Bats >= 1.5.0, required above); the Bats
    # dialect support recognizes $status/$output/$lines but not this newer
    # variable, so it misreports it as never assigned. Verified this is a
    # real, working assertion (not a silent no-op): temporarily mangling
    # resolve_cache_dir()'s error message made this exact line fail as
    # expected, then the mangling was reverted.
    [[ "$stderr" == *"CACHE_DIR_STANDARD and CACHE_DIR_SSL point to different paths"* ]]
    # The bug this fixes: the same message used to go through log() to
    # stdout, which "$(resolve_cache_dir)"'s command substitution silently
    # swallows. Stdout must now carry nothing from the error path.
    [ -z "$output" ]
}

# --- CONTAINER_* fail-loud (real subprocess, not sourced in-process) ----
#
# Every subprocess test below pins STATUS_FILE into $BATS_TEST_TMPDIR: the
# two "reaches main loop" tests actually run write_status(), whose
# `mkdir -p "$(dirname "$STATUS_FILE")"` would otherwise target the real
# default /var/run/watchdog -- writable inside the real watchdog container
# image, but not guaranteed writable inside whatever CI test-runner
# container executes this bats suite. CACHE_DIR is deliberately pointed at
# a path that does NOT exist (rather than $BATS_TEST_TMPDIR itself): the
# main loop also calls maybe_purge(), and if CACHE_DIR existed,
# maybe_purge() would proceed past its missing-dir early-return and attempt
# to write PURGE_STAMP, which is a hardcoded /var/run/watchdog path with no
# env override -- the same permission risk STATUS_FILE avoids. A
# nonexistent CACHE_DIR keeps maybe_purge() a same no-op it already is by
# default (real deployments' CACHE_DIR won't exist inside this test image
# either) without depending on that being true by coincidence.

@test "watchdog.sh exits non-zero and logs a fatal when CONTAINER_PROXY does not match the socket-proxy allowlist" {
    run timeout 5 env CONTAINER_PROXY=my-renamed-proxy DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTAINER_PROXY=my-renamed-proxy is not supported"* ]]
}

@test "watchdog.sh exits non-zero when CONTAINER_DNS_STANDARD does not match the socket-proxy allowlist" {
    run timeout 5 env CONTAINER_DNS_STANDARD=my-renamed-dns DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTAINER_DNS_STANDARD=my-renamed-dns is not supported"* ]]
}

@test "watchdog.sh exits non-zero when CONTAINER_DNS_SSL does not match the socket-proxy allowlist and SSL is enabled" {
    run timeout 5 env CONTAINER_DNS_SSL=my-renamed-ssl SSL_ENABLED=1 DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTAINER_DNS_SSL=my-renamed-ssl is not supported"* ]]
}

# CONTAINER_NATS (#842): unlike CONTAINER_DNS_SSL, nats is never
# profile/flag-gated, so a mismatch is always fatal, the same as
# CONTAINER_PROXY/CONTAINER_DNS_STANDARD above.
@test "watchdog.sh exits non-zero when CONTAINER_NATS does not match the socket-proxy allowlist" {
    run timeout 5 env CONTAINER_NATS=my-renamed-nats DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CONTAINER_NATS=my-renamed-nats is not supported"* ]]
}

# A mismatched CONTAINER_DNS_SSL must NOT be fatal when SSL is disabled --
# dns-ssl is not monitored at all in that mode, so its name is irrelevant.
@test "watchdog.sh does not fail on a CONTAINER_DNS_SSL mismatch when SSL_ENABLED=0" {
    run timeout 2 env CONTAINER_DNS_SSL=my-renamed-ssl SSL_ENABLED=0 DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    # timeout's own 124 means the process was still running (i.e. it made it
    # into the main loop instead of failing validation) -- the success case
    # here is "did not exit on its own", not a specific exit code.
    [ "$status" -eq 124 ]
}

# Complements the fail-loud tests above: with every CONTAINER_* var left at
# its default, startup must succeed and reach the main loop rather than
# exiting -- proves the new validation doesn't false-positive on the
# unmodified, already-correct default configuration every existing
# deployment (dev/prod/quickstart/full-setup env files) actually ships.
@test "watchdog.sh reaches the main loop and does not exit when CONTAINER_* are left at their defaults" {
    run timeout 2 env DOCKER_PROXY_URL="http://127.0.0.1:1" \
        STATUS_FILE="$BATS_TEST_TMPDIR/sub-status.json" CACHE_DIR="$BATS_TEST_TMPDIR/sub-nonexistent-cache" \
        bash "$repo_root/services/watchdog/watchdog.sh"
    [ "$status" -eq 124 ]
}
