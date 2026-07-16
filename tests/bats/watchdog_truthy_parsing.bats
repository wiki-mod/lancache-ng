#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Unit coverage for services/watchdog/watchdog.sh's is_truthy() helper
# (#874): the canonical truthy-parsing contract shared with the Admin UI's
# env_bool() (services/ui/src/config.rs). Before this function existed,
# watchdog.sh's SYSLOG_ENABLED gate only accepted the literal string "true",
# while the Admin UI's env_bool() already accepted 1/true/yes/on
# case-insensitively -- an operator typing "yes" or "1" saw the feature as
# enabled in the Admin UI while watchdog silently never enforced retention.
#
# This file tests is_truthy() directly, in isolation from
# maybe_prune_syslog()'s rate-limiting/filesystem behavior (covered
# separately in watchdog_syslog_prune.bats). The input tables here are
# deliberately the same values services/ui/src/config.rs's
# `syslog_enabled_truthy_parsing_matches_watchdog_contract` test exercises
# against env_bool() -- proving both components agree on the same set of
# inputs is the whole point of #874.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"
}

# Same truthy set env_bool() accepts: 1/true/yes/on, case-insensitive, and
# tolerant of surrounding whitespace (mirroring Rust's `.trim()`).
@test "is_truthy accepts 1/true/yes/on case-insensitively and trims whitespace" {
    for value in "1" "true" "TRUE" "True" "yes" "YES" "Yes" "on" "ON" "On" " true " $'\ton\t'; do
        run is_truthy "$value"
        [ "$status" -eq 0 ] || {
            echo "expected is_truthy [$value] to succeed (truthy)" >&2
            return 1
        }
    done
}

# Same falsy set env_bool() explicitly recognizes, plus anything
# unrecognized (garbage, empty, near-miss values like "1x" or "truex") --
# env_bool() falls back to its caller-supplied default for all of these,
# and watchdog's SYSLOG_ENABLED default is always "false", so the net
# effect is identical: not-truthy.
@test "is_truthy rejects 0/false/no/off and unrecognized/empty values" {
    for value in "0" "false" "FALSE" "no" "NO" "off" "OFF" "" "   " "garbage" "1x" "truex" "yesplease"; do
        run is_truthy "$value"
        [ "$status" -eq 1 ] || {
            echo "expected is_truthy [$value] to fail (not truthy)" >&2
            return 1
        }
    done
}
