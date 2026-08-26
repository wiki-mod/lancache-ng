#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises services/ui/Dockerfile's distcc wrapper masquerade and
#   CCACHE_PREFIX=distcc dispatch shapes, plus rust-acceleration-preflight's
#   scan_log()/scan_distcc_compile_log() log-classification functions.
# Why: both are distcc-adjacent bash extracted verbatim from their real
#   source (Dockerfile heredoc / action.yml heredoc) so a future edit is
#   exercised here without a second, hand-copied definition to keep in sync.
# From: Issue #1533 | PR #1612 | Issue #1095

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    dockerfile="$repo_root/services/ui/Dockerfile"
    action_file="$repo_root/.github/actions/rust-acceleration-preflight/action.yml"
    fixture_root="$(mktemp -d)"
    bin_dir="$fixture_root/usr_local_bin"
    masq_dir="$fixture_root/usr_local_lib_distcc"
    sys_dir="$fixture_root/usr_bin"
    mkdir -p "$bin_dir" "$masq_dir" "$sys_dir"

    extract_wrapper_script
    install_stubs
    extract_preflight_scan_functions
}

# What: pulls scan_log()/scan_distcc_compile_log() out of
#   rust-acceleration-preflight/action.yml's heredoc and sources them.
# Why: brace-depth tracking is required, not a bare closing-brace match,
#   since both functions nest their own if/then blocks.
# From: Issue #1095
extract_preflight_scan_functions() {
    local extracted="$BATS_TEST_TMPDIR/extracted-preflight-functions.sh"
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
    [ -s "$extracted" ] || fail "preflight scan-function extraction produced no output -- action.yml's function shape may have changed"
    # shellcheck source=/dev/null
    source "$extracted"
    preflight_log_file="$BATS_TEST_TMPDIR/probe.log"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

# What: extracts the lancache-distcc-wrapper script verbatim into an isolated fixture directory.
# Why: a hand-duplicated copy would silently drift from the real generated
#   script; extracting the real content is the only way this test proves
#   what the Dockerfile actually ships (AG-CODE-011).
# From: Issue #1533 | PR #1612
extract_wrapper_script() {
    local end_line start_line
    end_line="$(grep -nF '> /usr/local/bin/lancache-distcc-wrapper; \' "$dockerfile" | head -1 | cut -d: -f1)"
    [ -n "$end_line" ] || fail "could not locate the lancache-distcc-wrapper printf redirect in services/ui/Dockerfile"
    start_line="$(sed -n "1,${end_line}p" "$dockerfile" | grep -nF "printf '%s\n' \\" | tail -1 | cut -d: -f1)"
    [ -n "$start_line" ] || fail "could not locate the lancache-distcc-wrapper printf statement in services/ui/Dockerfile"

    sed -n "$((start_line + 1)),$((end_line - 1))p" "$dockerfile" \
        | sed -e "s/^[[:space:]]*'//" -e 's/'"'"'[[:space:]]*[\]$//' \
        | sed -e "s#/usr/local/bin/distcc-real#$bin_dir/distcc-real#g" \
              -e "s#/usr/local/bin/lancache-distcc-wrapper#$bin_dir/lancache-distcc-wrapper#g" \
              -e "s#/usr/local/lib/distcc#$masq_dir#g" \
        > "$bin_dir/lancache-distcc-wrapper"

    grep -qF 'matches_aws_lc_generated_path' "$bin_dir/lancache-distcc-wrapper" \
        || fail "extraction picked up the wrong printf block (missing matches_aws_lc_generated_path)"
    chmod +x "$bin_dir/lancache-distcc-wrapper"
}

install_stubs() {
    # A stub distcc-real that records its own argv so tests can assert on
    # exactly what the wrapper dispatched to it, matching what a real
    # distcc/ccache probe compile would receive.
    cat > "$bin_dir/distcc-real" <<'EOF'
#!/bin/sh
printf 'DISTCC_REAL_ARGV:'
for a in "$@"; do printf ' [%s]' "$a"; done
printf '\n'
EOF
    chmod +x "$bin_dir/distcc-real"

    for w in cc gcc c++ g++; do
        ln -sf "$bin_dir/lancache-distcc-wrapper" "$masq_dir/$w"
    done
    ln -sf "$bin_dir/lancache-distcc-wrapper" "$bin_dir/distcc"

    # A stub real system compiler, standing in for ccache's own resolved
    # $CC path (e.g. /usr/bin/cc) under CCACHE_PREFIX dispatch.
    printf '#!/bin/sh\necho REALCOMPILER "$@"\n' > "$sys_dir/cc"
    chmod +x "$sys_dir/cc"
}

@test "masquerade dispatch: cc-named symlink passes real compiler name through, unmodified args" {
    run "$masq_dir/cc" -c foo.c -o foo.o
    [ "$status" -eq 0 ]
    [ "$output" = "DISTCC_REAL_ARGV: [cc] [-c] [foo.c] [-o] [foo.o]" ]
}

@test "CCACHE_PREFIX dispatch: real compiler path from \$1 is passed through once, not duplicated" {
    # Regression test for the reported corruption: before the fix, $0=="distcc"
    # fell through to a hardcoded "cc" default and re-passed $1 as a stray
    # positional argument (e.g. "cc /usr/bin/cc -O2 ... file.c").
    run "$bin_dir/distcc" "$sys_dir/cc" -c foo.c -o foo.o
    [ "$status" -eq 0 ]
    [ "$output" = "DISTCC_REAL_ARGV: [$sys_dir/cc] [-c] [foo.c] [-o] [foo.o]" ]
    [[ "$output" != *"[cc] [$sys_dir/cc]"* ]] || fail "compiler path was duplicated -- the exact reported corruption"
}

@test "unrecognized invocation with no usable \$1 falls back to the pre-existing cc default" {
    run "$bin_dir/distcc" -c foo.c -o foo.o
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISTCC_REAL_ARGV: [cc] [-c] [foo.c] [-o] [foo.o]"* ]]
}

@test "aws-lc-sys generated-header bypass still fires under masquerade dispatch" {
    DISTCC_HOSTS_NO_PUMP="host1,host2" run "$masq_dir/cc" -I/build/target/x/aws-lc-sys-0.1/generated -c foo.c -o foo.o
    [ "$status" -eq 0 ]
    [[ "$output" == *"bypassing distcc-pump for generated-header input"* ]]
    [[ "$output" == *"DISTCC_REAL_ARGV: [cc]"* ]]
}

@test "aws-lc-sys generated-header bypass still fires under CCACHE_PREFIX dispatch" {
    DISTCC_HOSTS_NO_PUMP="host1,host2" run "$bin_dir/distcc" "$sys_dir/cc" -I/build/target/x/aws-lc-sys-0.1/generated -c foo.c -o foo.o
    [ "$status" -eq 0 ]
    [[ "$output" == *"bypassing distcc-pump for generated-header input"* ]]
    [[ "$output" == *"DISTCC_REAL_ARGV: [$sys_dir/cc]"* ]]
}

@test "refuses to dispatch when \$1 resolves back into the wrapper's own masquerade directory" {
    # Defends against a misconfigured CC resolving through the distcc
    # masquerade PATH instead of the pre-mutation original PATH -- would
    # otherwise recurse the wrapper into itself.
    run "$bin_dir/distcc" "$masq_dir/cc" -c foo.c -o foo.o
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to dispatch"* ]]
}

@test "preflight scan extraction actually pulled both functions (canary against a renamed/reshaped source)" {
    declare -F scan_log >/dev/null
    declare -F scan_distcc_compile_log >/dev/null
}

@test "preflight: single benign connect-refused line is tolerated with 2+ hosts" {
    printf 'distcc[123] ERROR: nonblocking connect to 192.168.1.229:3632 failed: Connection refused\n' > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 2
    [ "$status" -eq 0 ]
}

@test "preflight: the exact three-line hung-host timeout sequence is tolerated with 2+ hosts (confirmed live, issue #1095)" {
    {
        printf 'distcc[294] (dcc_select_for_read) ERROR: IO timeout\n'
        printf 'distcc[294] (dcc_r_token_int) ERROR: read failed while waiting for token "DONE"\n'
        printf 'distcc[294] (dcc_r_result_header) ERROR: server provided no answer. Is the server configured to allow access from your IP address? Is the server performing authentication and your client isn'\''t? Does the server have the compiler installed? Is the server configured to access the compiler?\n'
    } > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 3
    [ "$status" -eq 0 ]
}

@test "preflight: an unrelated real error still fails closed even with 2+ hosts" {
    printf 'error: linker `cc` not found\n' > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 2
    [ "$status" -eq 1 ]
}

@test "preflight: the no-answer line rejects a suffix carrying a real diagnostic instead of matching it via a wildcard" {
    printf 'distcc[294] (dcc_r_result_header) ERROR: server provided no answer. Is the server configured to allow access from your IP address? Is the server performing authentication and your client isn'\''t? Does the server have the compiler installed? Is the server configured to access the compiler? PANIC: compiler response was corrupt\n' > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 2
    [ "$status" -eq 1 ]
}

@test "preflight: the hung-host sequence is NOT tolerated at host_count<=1 (falls back to strict scan_log)" {
    printf 'distcc[294] (dcc_select_for_read) ERROR: IO timeout\n' > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 1
    [ "$status" -eq 1 ]
}

@test "preflight: a clean log with no suspicious lines passes regardless of host count" {
    printf 'nothing interesting here\n' > "$preflight_log_file"
    run scan_distcc_compile_log "$preflight_log_file" 3
    [ "$status" -eq 0 ]
}
