#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for services/watchdog/healthcheck.sh, the Docker HEALTHCHECK for
# the watchdog container. Unlike watchdog.sh (sourced via
# helpers/watchdog-helpers.sh to test individual functions in isolation),
# healthcheck.sh is a small standalone script with no reusable functions, so
# these tests run it directly as a subprocess (`run bash healthcheck.sh`)
# against a real STATUS_FILE fixture, exactly the way Docker's own
# HEALTHCHECK invokes it.
#
# The CHECK_INTERVAL octal-misparse regression (found live 2026-07-31, PR
# #1347's CI) is the primary thing this file guards: scripts/
# syslog-forwarding-simulation.sh deliberately sets CHECK_INTERVAL to a
# random-looking marker (the last 8 digits of a nanosecond timestamp) to
# prove the startup banner log line reaches the Admin UI. Roughly 1 run in
# 13, that marker has a leading zero AND contains an 8 or 9 -- Bash's
# `$(( CHECK_INTERVAL * 3 ))` then evaluates the leading-zero string as
# octal, which is not just wrong but syntactically invalid for those
# digits, raising "value too great for base" and aborting the whole script
# under `set -euo pipefail`. Docker reports any nonzero healthcheck exit as
# "unhealthy", so this surfaced as an intermittent, hard-to-reproduce
# "watchdog did not become healthy" CI failure with a perfectly healthy
# watchdog daemon underneath it.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    healthcheck="$repo_root/services/watchdog/healthcheck.sh"
    status_file="$BATS_TEST_TMPDIR/status.json"
    printf '{}' > "$status_file"
}

@test "healthcheck reports healthy for a fresh status file under the default CHECK_INTERVAL" {
    STATUS_FILE="$status_file" run bash "$healthcheck"
    [ "$status" -eq 0 ]
}

@test "healthcheck reports unhealthy for a stale status file" {
    touch -d '-1 hour' "$status_file"
    STATUS_FILE="$status_file" CHECK_INTERVAL=30 run bash "$healthcheck"
    [ "$status" -eq 1 ]
}

# The exact regression: a leading-zero CHECK_INTERVAL whose remaining digits
# include an 8 or 9 (invalid octal) must not abort the script -- it must be
# read as decimal, same as any other digit-only value.
@test "healthcheck does not abort on a leading-zero CHECK_INTERVAL containing an 8 or 9" {
    STATUS_FILE="$status_file" CHECK_INTERVAL=00563179 run bash "$healthcheck"
    [ "$status" -eq 0 ] || {
        echo "expected CHECK_INTERVAL=00563179 not to abort the healthcheck; status=$status output=$output" >&2
        return 1
    }
}

# A leading-zero value using only valid-octal digits (0-7) would not crash
# even with the bug present, but WOULD silently compute the wrong max_age
# (010 read as octal 8, not decimal 10) -- a status file aged between the
# two (91s: over the buggy 8*3=24s-floored-at-60s window's neighbor, under a
# correct 10*3=30s-floored-at-60s window) distinguishes them. Both windows
# floor to 60s minimum here, so use a larger interval where the floor no
# longer masks the difference: CHECK_INTERVAL=050 must mean 50s (max_age
# 150s), not octal 40 (max_age 120s) -- a 130s-old status file is stale
# under the octal misread's 120s window but fresh under the correct 150s one.
@test "healthcheck treats a leading-zero CHECK_INTERVAL as decimal, not octal" {
    touch -d '-130 seconds' "$status_file"
    STATUS_FILE="$status_file" CHECK_INTERVAL=050 run bash "$healthcheck"
    [ "$status" -eq 0 ] || {
        echo "expected CHECK_INTERVAL=050 (decimal 50, max_age 150s) to treat a 130s-old status file as fresh; status=$status output=$output" >&2
        return 1
    }
}

@test "healthcheck reports unhealthy when the status file does not exist" {
    STATUS_FILE="$BATS_TEST_TMPDIR/missing.json" run bash "$healthcheck"
    [ "$status" -eq 1 ]
}
