#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for issue #1176 (Angle 1): setup.sh's `list-prompts` introspection
# subcommand and scripts/lib/setup-wizard-introspect.sh, the shared helper
# scripts/setup-cli-simulation.sh and scripts/syslog-forwarding-simulation.sh
# now use to derive their expect_prompt sequences instead of hand-encoding
# them. See setup.sh's own `wizard_introspect_record_prompt` comment and
# scripts/check-setup-prompt-drift.sh's header for the specific blind spot
# (a new prompt on a conditional branch a sim script's answers actually
# reach) this closes.
#
# Invoked as `run bash "$setup_sh" ...`, not `run "$setup_sh" ...` (AG-VAL-024):
# removes any dependency on the committed executable bit, unverifiable from a
# Windows/core.filemode=false authoring sandbox.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    setup_sh="$repo_root/setup.sh"
    lib="$repo_root/scripts/lib/setup-wizard-introspect.sh"
}

# write_answers <file> <line...>
# One answer per line, in prompt order; an empty argument writes a blank
# line (accept that prompt's own default), mirroring a real Enter keypress.
write_answers() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

# ─── list-prompts: defaults path ───

@test "list-prompts with no answers file reports the all-defaults prompt sequence" {
    run bash "$setup_sh" list-prompts
    [ "$status" -eq 0 ]
    # 13 prompts on the never-set-LANCACHE_IMAGE_CHANNEL path: the 12 always
    # asked plus "Release channel [nightly/stable]" (skipped only when
    # LANCACHE_IMAGE_CHANNEL is already set, see setup.sh's own comment on
    # that prompt).
    prompt_count="$(printf '%s\n' "$output" | grep -c '^PROMPT	')"
    [ "$prompt_count" -eq 13 ]
    printf '%s\n' "$output" | grep -qF $'PROMPT\tEnable SSL mode? [y/N]\tN'
    printf '%s\n' "$output" | grep -qF $'PROMPT\tDHCP mode (disabled, kea, dnsmasq-proxy, dnsmasq-relay)\tdisabled'
    printf '%s\n' "$output" | grep -qF $'PROMPT\tStart now? [Y/n]\tY'
}

@test "list-prompts respects a pre-set LANCACHE_IMAGE_CHANNEL and skips the Release channel prompt" {
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts
    [ "$status" -eq 0 ]
    prompt_count="$(printf '%s\n' "$output" | grep -c '^PROMPT	')"
    [ "$prompt_count" -eq 12 ]
    ! printf '%s\n' "$output" | grep -qF 'Release channel'
}

@test "list-prompts never creates the install directory or any other real file" {
    fake_install_dir="$BATS_TEST_TMPDIR/would-be-install"
    write_answers "$BATS_TEST_TMPDIR/answers.txt" "" "" "$fake_install_dir"
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    [ ! -e "$fake_install_dir" ]
}

@test "list-prompts never invokes the real 'ip' binary, even when 'Add now?' is answered y" {
    # Stubs ip on PATH to record every invocation instead of touching real
    # host network state -- introspection mode must skip this call
    # entirely (setup.sh's own WIZARD_INTROSPECT_MODE guard around `ip addr
    # add`), so this file must stay empty regardless of what the answers
    # file says for "Add now?".
    stub_bin="$BATS_TEST_TMPDIR/stub-bin"
    mkdir -p "$stub_bin"
    ip_calls="$BATS_TEST_TMPDIR/ip-calls.log"
    : > "$ip_calls"
    cat > "$stub_bin/ip" <<EOF
#!/bin/bash
echo "\$@" >> "$ip_calls"
EOF
    chmod +x "$stub_bin/ip"

    write_answers "$BATS_TEST_TMPDIR/answers.txt" \
        "127.0.0.2" "y" "127.0.0.3" "y"
    PATH="$stub_bin:$PATH" LANCACHE_IMAGE_CHANNEL=nightly \
        run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    [ ! -s "$ip_calls" ]
}

# ─── list-prompts: branch-following (the actual #1176 blind spot) ───

@test "list-prompts walks the DHCP kea branch and reports its 5 extra prompts" {
    write_answers "$BATS_TEST_TMPDIR/answers.txt" \
        "" "" "" "" "" "" "" "kea"
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qF 'Kea data directory'
    printf '%s\n' "$output" | grep -qF 'DHCP subnet (CIDR)'
    printf '%s\n' "$output" | grep -qF 'Gateway'
    printf '%s\n' "$output" | grep -qF 'IP pool start'
    printf '%s\n' "$output" | grep -qF 'IP pool end'
    # disabled-path-only prompts must NOT appear once kea is chosen.
    ! printf '%s\n' "$output" | grep -qF 'DHCP subnet start for dnsmasq-proxy'
}

@test "list-prompts walks the SSL-enabled branch and reports the SSL follow-up prompts" {
    write_answers "$BATS_TEST_TMPDIR/answers.txt" "" "y"
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qF 'SSL mode IP (second LAN IP)'
    printf '%s\n' "$output" | grep -qF 'Add now?'
}

@test "list-prompts does NOT report the SSL follow-up prompts when SSL mode is left disabled" {
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -qF 'SSL mode IP (second LAN IP)'
    ! printf '%s\n' "$output" | grep -qF 'Add now?'
}

@test "list-prompts is repeat-run stable for identical answers (AG-OP-006/007 convergence)" {
    write_answers "$BATS_TEST_TMPDIR/answers.txt" "" "" "" "" "" "" "" "kea"
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    first_output="$output"
    LANCACHE_IMAGE_CHANNEL=nightly run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/answers.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "$first_output" ]
}

@test "list-prompts --help documents the subcommand and exits 0" {
    run bash "$setup_sh" list-prompts --help
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qF 'list-prompts'
}

@test "list-prompts fails closed on a nonexistent answers file" {
    run bash "$setup_sh" list-prompts "$BATS_TEST_TMPDIR/does-not-exist.txt"
    [ "$status" -ne 0 ]
}

# ─── scripts/lib/setup-wizard-introspect.sh ───

@test "escape_tcl_re escapes every ARE metacharacter, backslash first" {
    # shellcheck source=scripts/lib/setup-wizard-introspect.sh
    source "$lib"
    run escape_tcl_re 'Enable SSL mode? [y/N]'
    [ "$status" -eq 0 ]
    [ "$output" = 'Enable SSL mode\? \[y/N\]' ]

    run escape_tcl_re 'DHCP mode (disabled, kea, dnsmasq-proxy, dnsmasq-relay)'
    [ "$output" = 'DHCP mode \(disabled, kea, dnsmasq-proxy, dnsmasq-relay\)' ]

    # A literal backslash must become \\, not collide with the metacharacter
    # substitutions applied afterward.
    run escape_tcl_re 'a\b'
    [ "$output" = 'a\\b' ]
}

@test "tcl_brace_quote wraps plain text in braces and rejects embedded braces" {
    # shellcheck source=scripts/lib/setup-wizard-introspect.sh
    source "$lib"
    run tcl_brace_quote "127.0.0.2"
    [ "$status" -eq 0 ]
    [ "$output" = "{127.0.0.2}" ]

    run tcl_brace_quote "has {brace"
    [ "$status" -ne 0 ]
}

@test "build_expect_prompt_block fails closed on a reply-count mismatch instead of silently misaligning" {
    # shellcheck source=scripts/lib/setup-wizard-introspect.sh
    source "$lib"
    # The default (LANCACHE_IMAGE_CHANNEL unset) path asks 13 prompts; supply
    # only 3 replies so the mismatch is unambiguous either way this fixture
    # is read.
    run build_expect_prompt_block "$setup_sh" "$BATS_TEST_TMPDIR/answers.txt" "a" "b" "c"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -qF 'out of sync'
}

@test "build_expect_prompt_block produces one expect_prompt line per real prompt, in order, for the fresh-install reply sequence" {
    # shellcheck source=scripts/lib/setup-wizard-introspect.sh
    source "$lib"
    install_dir="$BATS_TEST_TMPDIR/install"
    run env LANCACHE_IMAGE_CHANNEL=nightly bash -c "
        source '$lib'
        build_expect_prompt_block '$setup_sh' '$BATS_TEST_TMPDIR/answers.txt' \
            '127.0.0.2' '' '$install_dir' '' '' '' '' '' '' '' '' ''
    "
    [ "$status" -eq 0 ]
    line_count="$(printf '%s\n' "$output" | grep -c '^expect_prompt ')"
    [ "$line_count" -eq 12 ]
    printf '%s\n' "$output" | grep -qF 'expect_prompt {Server IP \(Standard mode\)'
    printf '%s\n' "$output" | grep -qF 'expect_prompt {Start now\?'
    # The install-dir reply must be Tcl-brace-quoted verbatim, not escaped as
    # if it were part of a -re pattern.
    printf '%s\n' "$output" | grep -qF "{$install_dir}"
}
