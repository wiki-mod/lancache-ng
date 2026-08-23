#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: exercises services/ui/Dockerfile's distcc wrapper masquerade and CCACHE_PREFIX=distcc dispatch shapes.
# Why: a distcc-wrapping compiler call must reach the real compiler
#   exactly once under both shapes; CCACHE_PREFIX=distcc's $1-as-path
#   convention is the same contract AG-CI-022 requires for services/dns.
# From: Issue #1533 | PR #1612

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    dockerfile="$repo_root/services/ui/Dockerfile"
    fixture_root="$(mktemp -d)"
    bin_dir="$fixture_root/usr_local_bin"
    masq_dir="$fixture_root/usr_local_lib_distcc"
    sys_dir="$fixture_root/usr_bin"
    mkdir -p "$bin_dir" "$masq_dir" "$sys_dir"

    extract_wrapper_script
    install_stubs
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
