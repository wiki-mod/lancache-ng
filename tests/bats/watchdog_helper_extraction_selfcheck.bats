#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for #849 bug-hunt finding watchdog.md#12: tests/bats/helpers/
# watchdog-helpers.sh's load_watchdog_functions() extracts watchdog.sh's
# functions via two literal-text awk anchors (the DOCKER_PROXY_URL= default
# assignment that starts capture, and the "Watchdog started." log line that
# ends it). A drifted anchor can silently produce an empty or truncated
# extraction file that a plain `source` accepts with no error -- without a
# loud, immediate check, the only symptom would surface much later as a
# confusing "command not found" deep inside some unrelated @test that calls
# a now-undefined function, not as a clear "the test harness failed to
# extract functions" message at setup() time. This file proves the helper
# fails loudly and immediately instead, using synthetic fake watchdog.sh
# stand-ins that
# reproduce exactly the two ways the real anchors could drift (start anchor
# no longer matches at all; end anchor matches too early, truncating the
# range before it reaches a real function definition), and separately
# confirms the real watchdog.sh still extracts cleanly today.
#
# load_watchdog_functions is called directly here (not via bats' `run`),
# matching how every other watchdog_*.bats file's own setup() calls it --
# `run` forks a subshell, so a function `source`d inside a `run` invocation
# would not persist into the calling test's shell, which would defeat the
# point of testing what this helper actually leaves behind.

bats_require_minimum_version 1.5.0

setup() {
    real_repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=tests/bats/helpers/watchdog-helpers.sh
    source "$BATS_TEST_DIRNAME/helpers/watchdog-helpers.sh"
}

@test "load_watchdog_functions fails loudly when the start anchor no longer matches" {
    fake_root="$BATS_TEST_TMPDIR/fake-repo-no-start-anchor"
    mkdir -p "$fake_root/services/watchdog"
    # A cosmetically-reworded default assignment (the exact drift class the
    # finding describes, e.g. a variable rename) no longer matches the awk
    # anchor's literal "^DOCKER_PROXY_URL=" text -- capture never turns on,
    # so the extraction would previously have silently produced an empty
    # file that `source` accepted without complaint.
    cat > "$fake_root/services/watchdog/watchdog.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
DOCKER_PROXY_URL_RENAMED="${DOCKER_PROXY_URL_RENAMED:-http://docker-socket-proxy:2375}"
disk_info() { printf '{"pct": 0, "status": "unknown"}'; }
log "Watchdog started."
EOF

    error_output=$(load_watchdog_functions "$fake_root" "$BATS_TEST_TMPDIR/drift.sh" 2>&1)
    status="$?"
    [ "$status" -ne 0 ]
    [[ "$error_output" == *"is empty"* ]]
}

@test "load_watchdog_functions fails loudly when the extracted range is truncated before any function body" {
    fake_root="$BATS_TEST_TMPDIR/fake-repo-truncated"
    mkdir -p "$fake_root/services/watchdog"
    # Start anchor matches, but the end anchor ("Watchdog started.") appears
    # immediately after it -- before disk_info is ever defined -- producing a
    # non-empty but functionally useless extraction (the empty-file check
    # alone would not catch this).
    cat > "$fake_root/services/watchdog/watchdog.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
DOCKER_PROXY_URL="${DOCKER_PROXY_URL:-http://docker-socket-proxy:2375}"
log "Watchdog started."
disk_info() { printf '{"pct": 0, "status": "unknown"}'; }
EOF

    error_output=$(load_watchdog_functions "$fake_root" "$BATS_TEST_TMPDIR/truncated.sh" 2>&1)
    status="$?"
    [ "$status" -ne 0 ]
    [[ "$error_output" == *"did not define disk_info"* ]]
}

@test "load_watchdog_functions still succeeds against the real, current watchdog.sh" {
    load_watchdog_functions "$real_repo_root" "$BATS_TEST_TMPDIR/real.sh"
    declare -F disk_info >/dev/null
    declare -F check_and_maybe_restart >/dev/null
}
