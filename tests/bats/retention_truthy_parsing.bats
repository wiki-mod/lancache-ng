#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Unit coverage for services/watchdog/retention.sh's own is_truthy() copy
# (#842, 2026-08-01): deliberately duplicated from watchdog.sh's identical
# function rather than shared via a sourced library file (see retention.sh's
# own header for why -- a shared helper would reintroduce exactly the
# process-coupling the #842 extraction was meant to remove). Since the two
# copies can drift out of sync by hand-edit mistake with nothing to catch
# it, this file mirrors watchdog_truthy_parsing.bats's exact input tables
# against retention.sh's copy instead of watchdog.sh's -- if the two ever
# disagree on a single input, one of these two files' assertions fails while
# the other still passes, making the drift immediately visible instead of
# silent.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/retention-helpers-extracted.sh"

    # shellcheck source=tests/bats/helpers/retention-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/retention-helpers.sh"
    load_retention_functions "$repo_root" "$helper_file"
}

# Same truthy set env_bool() accepts: 1/true/yes/on, case-insensitive, and
# tolerant of surrounding whitespace (mirroring Rust's `.trim()`). Identical
# input table to watchdog_truthy_parsing.bats's matching test, run here
# against retention.sh's independently-maintained copy.
@test "retention.sh's is_truthy accepts 1/true/yes/on case-insensitively and trims whitespace" {
    for value in "1" "true" "TRUE" "True" "yes" "YES" "Yes" "on" "ON" "On" " true " $'\ton\t'; do
        run is_truthy "$value"
        [ "$status" -eq 0 ] || {
            echo "expected is_truthy [$value] to succeed (truthy)" >&2
            return 1
        }
    done
}

# Same falsy set env_bool() explicitly recognizes, plus anything
# unrecognized (garbage, empty, near-miss values like "1x" or "truex").
@test "retention.sh's is_truthy rejects 0/false/no/off and unrecognized/empty values" {
    for value in "0" "false" "FALSE" "no" "NO" "off" "OFF" "" "   " "garbage" "1x" "truex" "yesplease"; do
        run is_truthy "$value"
        [ "$status" -eq 1 ] || {
            echo "expected is_truthy [$value] to fail (not truthy)" >&2
            return 1
        }
    done
}
