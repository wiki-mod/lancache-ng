#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regression coverage for scan_log()/scan_distcc_compile_log(), the
# preflight-log scanners defined inline inside
# .github/actions/rust-acceleration-preflight/action.yml's `bash -s
# <<'PREFLIGHT'` heredoc (issue #1095). Because these functions live inside
# a YAML block-scalar `run: |` string rather than a standalone script, this
# extracts the exact function bodies out of the action file at test time
# (between the `<<'PREFLIGHT'` and closing `PREFLIGHT` markers) and sources
# them, so a future edit to the real functions is exercised by these tests
# without needing to keep a second, hand-copied definition in sync.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    action_file="$repo_root/.github/actions/rust-acceleration-preflight/action.yml"
    extracted="$BATS_TEST_TMPDIR/extracted-functions.sh"

    # What: pulls only scan_log() and scan_distcc_compile_log() out of the
    #   action's heredoc body, not the whole preflight script (which does
    #   real docker/distcc/sccache work this test must not attempt).
    # Why: keeps this test coupled to the two pure, side-effect-free
    #   functions the regression is actually about; brace-depth tracking
    #   (not a bare closing-brace match) is required since both function
    #   bodies contain their own nested if/then blocks.
    awk '
        /^ *scan_log\(\) \{$/ { capture=1 }
        capture {
            print
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") {
                    depth--
                    if (depth == 0 && started) { exit }
                }
            }
            if (/scan_distcc_compile_log\(\) \{/) started=1
        }
    ' "$action_file" > "$extracted"

    [ -s "$extracted" ] || {
        echo "Extraction produced no output -- action.yml's function shape may have changed." >&2
        return 1
    }

    # shellcheck source=/dev/null
    source "$extracted"

    log_file="$BATS_TEST_TMPDIR/probe.log"
}

@test "extraction actually pulled both functions (canary against a renamed/reshaped source)" {
    declare -F scan_log >/dev/null
    declare -F scan_distcc_compile_log >/dev/null
}

@test "single benign connect-refused line is tolerated with 2+ hosts" {
    printf 'distcc[123] ERROR: nonblocking connect to 192.168.1.229:3632 failed: Connection refused\n' > "$log_file"
    run scan_distcc_compile_log "$log_file" 2
    [ "$status" -eq 0 ]
}

@test "the exact three-line hung-host timeout sequence is tolerated with 2+ hosts (confirmed live, issue #1095)" {
    {
        printf 'distcc[294] (dcc_select_for_read) ERROR: IO timeout\n'
        printf 'distcc[294] (dcc_r_token_int) ERROR: read failed while waiting for token "DONE"\n'
        printf 'distcc[294] (dcc_r_result_header) ERROR: server provided no answer. Is the server configured to allow access from your IP address? Is the server performing authentication and your client isn'\''t? Does the server have the compiler installed? Is the server configured to access the compiler?\n'
    } > "$log_file"
    run scan_distcc_compile_log "$log_file" 3
    [ "$status" -eq 0 ]
}

@test "an unrelated real error still fails closed even with 2+ hosts" {
    printf 'error: linker `cc` not found\n' > "$log_file"
    run scan_distcc_compile_log "$log_file" 2
    [ "$status" -eq 1 ]
}

@test "the no-answer line rejects a suffix carrying a real diagnostic instead of matching it via a wildcard" {
    printf 'distcc[294] (dcc_r_result_header) ERROR: server provided no answer. Is the server configured to allow access from your IP address? Is the server performing authentication and your client isn'\''t? Does the server have the compiler installed? Is the server configured to access the compiler? PANIC: compiler response was corrupt\n' > "$log_file"
    run scan_distcc_compile_log "$log_file" 2
    [ "$status" -eq 1 ]
}

@test "the hung-host sequence is NOT tolerated at host_count<=1 (falls back to strict scan_log)" {
    printf 'distcc[294] (dcc_select_for_read) ERROR: IO timeout\n' > "$log_file"
    run scan_distcc_compile_log "$log_file" 1
    [ "$status" -eq 1 ]
}

@test "a clean log with no suspicious lines passes regardless of host count" {
    printf 'nothing interesting here\n' > "$log_file"
    run scan_distcc_compile_log "$log_file" 3
    [ "$status" -eq 0 ]
}
