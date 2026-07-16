#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for services/watchdog/watchdog.sh's disk_info() (#872): two
# compounding bugs made it emit syntactically invalid JSON into status.json,
# corrupting the whole file for every reader (the Admin UI dashboard).
#
# 1. `df` was called without `-P`. On a filesystem behind a long device name
#    (common for overlay/mapper devices), non-POSIX `df` output wraps the
#    device name onto its own line, so `awk 'NR==2'` reads the wrapped
#    device-name line instead of the real usage-percentage data row and `$5`
#    comes back empty.
# 2. The final `printf` interpolated raw `"$pct"` instead of `"${pct:-0}"`,
#    so an empty `$pct` (from bug 1, or any other `df` failure) produced
#    `{"pct": , "status": "..."}` -- invalid JSON, not just a wrong value.
#
# This file proves both are fixed: the real `df -P` invocation is exercised
# via a temp directory, and the specific "df produced no usable output"
# failure mode is simulated directly by stubbing `df` to fail, isolating the
# printf-fallback fix (bug 2) from whatever `df -P` itself does on the CI
# host's real filesystem.

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    helper_file="$BATS_TEST_TMPDIR/watchdog-helpers-extracted.sh"

    export SSL_ENABLED=0
    export CACHE_DIR="$BATS_TEST_TMPDIR"

    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
    load_watchdog_functions "$repo_root" "$helper_file"
}

@test "disk_info emits valid JSON with a real percentage for an existing directory" {
    run disk_info "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
    run jq -e '.pct | type == "number"' <<< "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "disk_info emits valid JSON (pct 0) for a directory that does not exist" {
    run disk_info "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
    run jq -e '.pct == 0 and .status == "unknown"' <<< "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# Isolates the printf fallback fix (${pct:-0}, not $pct) from `df -P`
# itself: stubbing `df` to produce no output reproduces the exact "$pct
# comes back empty" condition bug 1 caused via the device-name wrap (awk
# reading the wrong line and $5 coming back empty), without depending on the
# CI host having a long-device-name filesystem to reproduce that wrap
# naturally.
@test "disk_info falls back to a JSON-valid pct=0 when df produces no output" {
    df() { return 1; }
    # No `set -o pipefail` in this sourced context (that's the top-level
    # script's setting, outside the extraction range) -- df's stubbed
    # failure alone would not be enough to make the pipeline's own exit
    # status non-zero, since awk still runs and exits 0 on empty input. What
    # actually matters here is that `pct` ends up empty either way, which is
    # exactly what the original device-name-wrap bug produced.
    run disk_info "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    # A second `run` below would overwrite $output, so the original
    # disk_info JSON is saved first -- the final assertion needs the exact
    # raw text, not just jq's parsed verdict on it.
    local json="$output"
    # Before the fix, this was the literal invalid `{"pct": , "status": ...}`
    # -- assert both that jq parses it AND that pct is the numeral 0, not an
    # empty/missing field.
    echo "$json" | jq empty
    run jq -e '.pct == 0' <<< "$json"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
    [[ "$json" != *'"pct": ,'* ]]
}

# Directly proves the `-P` flag is present in the real df invocation (not
# just that some fallback path happens to produce valid output) -- greps the
# actual sourced function body extracted from watchdog.sh.
@test "disk_info's df invocation uses -P (POSIX output format)" {
    run declare -f disk_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"df -P "* ]]
}
