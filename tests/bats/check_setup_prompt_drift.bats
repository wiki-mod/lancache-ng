#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-setup-prompt-drift.sh (#1176): the CI guard that
# fails when setup.sh's interactive install wizard and its expect-driven
# simulation scripts (scripts/tracked/simulations/setup-cli-simulation.sh,
# scripts/tracked/simulations/syslog-forwarding-simulation.sh) drift apart
# on the wizard's hand-duplicated
# prompt text -- the exact failure class that let PR #1082 hang both
# simulation scripts (issue #1175) when a new unconditional prompt was added
# without updating either script's expect_prompt sequence.
#
# Mirrors check_bats_path_filter_coverage.bats's pattern: builds small
# fixture files (a minimal setup.sh with just enough shape to satisfy the
# script's two anchors, plus minimal simulation-script fixtures) and
# exercises the guard's pass/fail branches directly, rather than only
# running it against the real repo (which only proves "passes today," not
# that the guard actually catches a regression). A final test does also run
# it against the real repository tree, matching that file's own last test.
#
# Invoked as `run bash "$script" ...` throughout, not `run "$script" ...`,
# for the same AG-VAL-024 reason check_bats_path_filter_coverage.bats
# documents: this removes any dependency on the committed executable bit,
# which is unverifiable from a Windows/core.filemode=false authoring
# sandbox.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-setup-prompt-drift.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mkdir -p "$fixture_root/scripts/tracked/simulations"
}

# write_setup <wizard_body>
# Writes a minimal setup.sh fixture: the two fixed anchors this script's
# Step 1 greps for (the subcommand dispatch `case "${1:-install}" in` and its
# own matching column-0 `esac`), with <wizard_body> as everything after --
# exactly mirroring the real setup.sh's shape (dispatch case falls through to
# a linear top-level wizard).
write_setup() {
    local wizard_body="$1"
    cat > "$fixture_root/setup.sh" <<EOF
#!/bin/bash
set -euo pipefail
ask() {
    local prompt="\$1" default="\${2:-}"
    printf "%s [%s]: " "\$prompt" "\$default"
    read -r REPLY < /dev/tty
    REPLY="\${REPLY:-\$default}"
}
confirm() {
    local prompt="\$1" default="\${2:-N}"
    ask "\$prompt" "\$default"
    [[ "\${REPLY,,}" = "y" || "\${REPLY,,}" = "yes" ]]
}
case "\${1:-install}" in
    install|"")
        ;;
    help|--help|-h) exit 0 ;;
esac

$wizard_body
EOF
}

# write_sim <path> <expect_prompt_lines>
# Writes a minimal expect-driven simulation-script fixture: a real
# `proc expect_prompt {pattern reply} { ... }` DEFINITION (deliberately
# included in every fixture -- this is the exact line that must NOT be
# misextracted as if it were a call, see the "false extraction" test below)
# plus the given expect_prompt CALL lines.
write_sim() {
    local path="$1" calls="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
expect -f - <<'EXPECT_SCRIPT'
proc expect_prompt {pattern reply} {
    expect {
        -re \$pattern { send "\$reply\r" }
    }
}
$calls
EXPECT_SCRIPT
EOF
}

write_both_sims() {
    local calls="$1"
    write_sim "$fixture_root/scripts/tracked/simulations/setup-cli-simulation.sh" "$calls"
    write_sim "$fixture_root/scripts/tracked/simulations/syslog-forwarding-simulation.sh" "$calls"
}

@test "passes when the only unconditional prompt is covered by both simulation scripts" {
    write_setup 'ask "Server IP (Standard mode)" "192.168.1.10"'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 1 unconditional"* ]]
}

@test "fails when a new unconditional prompt has no matching expect_prompt in either simulation script (#1082/#1175 shape)" {
    # A second, already-covered baseline prompt keeps both sim scripts'
    # pattern sets non-empty -- this test is specifically about the coverage
    # check, not the separate "zero expect_prompt patterns at all" vacuity
    # guard (that guard has its own dedicated test below).
    write_setup '
ask "Server IP (Standard mode)" "192.168.1.10"
ask "Enable Widget Mode? [y/N]" "N"
'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has no expect_prompt pattern matching"* ]]
    [[ "$output" == *"Enable Widget Mode? [y/N]"* ]]
    [[ "$output" == *"#1082/#1175"* ]]
}

@test "fails when only one of the two simulation scripts is missing coverage for an unconditional prompt" {
    write_setup '
ask "Server IP (Standard mode)" "192.168.1.10"
ask "Enable Widget Mode? [y/N]" "N"
'
    write_sim "$fixture_root/scripts/tracked/simulations/setup-cli-simulation.sh" '
expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"
expect_prompt {Enable Widget Mode\? \[y/N\]} ""
'
    write_sim "$fixture_root/scripts/tracked/simulations/syslog-forwarding-simulation.sh" '
expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"
'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"syslog-forwarding-simulation.sh has no expect_prompt pattern matching"* ]]
    [[ "$output" != *"setup-cli-simulation.sh has no expect_prompt pattern matching"* ]]
}

@test "fails when a simulation script's pattern no longer matches any real prompt (stale/renamed)" {
    write_setup 'ask "Enable Widget Mode? [y/N]" "N"'
    write_both_sims 'expect_prompt {Enable Gadget Mode\? \[y/N\]} ""'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match any real prompt currently in"* ]]
    [[ "$output" == *"Enable Gadget Mode"* ]]
}

@test "passes on a coordinated rename in both setup.sh and a simulation script (no false positive)" {
    write_setup 'ask "Enable Gizmo Mode? [y/N]" "N"'
    write_both_sims 'expect_prompt {Enable Gizmo Mode\? \[y/N\]} ""'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not require simulation-script coverage for a prompt reachable only inside an if branch" {
    # Baseline unconditional prompt (covered) keeps sim pattern sets
    # non-empty, isolating this test to whether the IF-conditional prompt
    # specifically is wrongly required.
    write_setup '
ask "Server IP (Standard mode)" "192.168.1.10"
if [[ "${SOME_FLAG:-}" = "y" ]]; then
    ask "Extra conditional prompt" "N"
fi
'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 1 unconditional"* ]]
}

@test "does not require simulation-script coverage for a prompt reachable only inside a case branch" {
    write_setup '
ask "Server IP (Standard mode)" "192.168.1.10"
case "${MODE:-x}" in
    special)
        ask "Special-mode-only prompt" "N"
        ;;
esac
'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "treats a retry-until-valid while loop as unconditional, not conditional (matches setup.sh's real IP/CIDR/path retry style)" {
    write_setup '
ask "Server IP (Standard mode)" "192.168.1.10"
while true; do
    ask "Cache directory" "/opt/lancache-ng/cache"
    CACHE_DIR="$REPLY"
    [[ -n "$CACHE_DIR" ]] && break
done
'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cache directory"* ]]
}

@test "matches a pattern anchored on ask()'s runtime-rendered default value in brackets" {
    # ask() actually prints "PROMPT [DEFAULT]: " at runtime -- a pattern like
    # the real Username[^\n]*\[admin\] one only matches because of that
    # rendering, not because setup.sh's own literal prompt string contains a
    # bracket. Confirms the haystack construction captures the default too.
    write_setup 'ask "Username" "admin"'
    write_both_sims 'expect_prompt {Username[^\n]*\[admin\]} ""'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "does not misextract the proc expect_prompt {pattern reply} definition line itself as a real pattern" {
    # write_sim's fixture always includes this definition line; if the
    # extractor matched it as a call, "pattern reply" would appear as a
    # bogus expect_prompt pattern and this test's real, correctly-covered
    # prompt would still incorrectly report a stale/uncovered finding
    # because of the spurious extra entry polluting the pattern set.
    write_setup 'ask "Server IP (Standard mode)" "192.168.1.10"'
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"'pattern reply'"* ]]
}

@test "fails closed when an ask/confirm call's first argument is a bare variable reference" {
    write_setup 'prompt_var="Dynamic prompt"
ask "$prompt_var" "N"'
    write_both_sims 'expect_prompt {Dynamic prompt} ""'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"looks like a bare variable reference"* ]]
}

@test "fails closed when a simulation script has zero expect_prompt patterns" {
    write_setup 'ask "Server IP (Standard mode)" "192.168.1.10"'
    write_sim "$fixture_root/scripts/tracked/simulations/setup-cli-simulation.sh" 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'
    write_sim "$fixture_root/scripts/tracked/simulations/syslog-forwarding-simulation.sh" '# nothing at all'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found zero expect_prompt patterns"* ]]
}

@test "fails closed when the wizard region has zero ask/confirm prompts at all" {
    write_setup '# no prompts here, just a comment'
    write_both_sims '# nothing either'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"found zero ask/confirm prompts"* ]]
}

@test "fails closed when the dispatch case anchor is missing" {
    cat > "$fixture_root/setup.sh" <<'EOF'
#!/bin/bash
ask "Server IP (Standard mode)" "192.168.1.10"
EOF
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"case \"\${1:-install}\" in"*"anchor"* ]]
}

@test "fails closed when an if/fi block is unbalanced (one-keyword-per-line assumption violated)" {
    write_setup '
if [[ "${SOME_FLAG:-}" = "y" ]]; then
    ask "Extra conditional prompt" "N"
'
    write_both_sims 'expect_prompt {Extra conditional prompt} ""'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unclosed block"* || "$output" == *"no matching open"* ]]
}

@test "fails closed when setup.sh does not exist under the given repo root" {
    rm -f "$fixture_root/setup.sh"
    write_both_sims 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup.sh"*"not found"* ]]
}

@test "the guard also passes when pointed at the real repository tree" {
    real_repo_root="$BATS_TEST_DIRNAME/../.."
    run bash "$script" "$real_repo_root"
    [ "$status" -eq 0 ]
    # Issue #1176 (Angle 1): both real simulation scripts now derive their
    # expect_prompt sequence from setup.sh's `list-prompts` introspection
    # mode (scripts/lib/setup-wizard-introspect.sh) instead of hand-encoding
    # it, so this guard's static coverage/staleness checks have nothing left
    # to run against them -- see is_introspection_driven's own comment.
    [[ "$output" == *"All 2 simulation script(s) are introspection-driven"* ]]
}

@test "is_introspection_driven: a sim script referencing build_expect_prompt_block is skipped from static coverage/staleness checks" {
    write_setup 'ask "Server IP (Standard mode)" "192.168.1.10"'
    # Deliberately gives this fixture NO expect_prompt lines and a pattern
    # that would otherwise be reported stale if statically checked -- if
    # is_introspection_driven's skip did not work, this would fail on either
    # the zero-patterns check or a staleness mismatch.
    write_sim "$fixture_root/scripts/tracked/simulations/setup-cli-simulation.sh" '
build_expect_prompt_block "setup.sh" "/tmp/does-not-matter" "192.168.1.10"
spawn bash setup.sh
'
    write_sim "$fixture_root/scripts/tracked/simulations/syslog-forwarding-simulation.sh" 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"derives its expect_prompt sequence from a real"* ]]
}

@test "is_introspection_driven: fails closed if a sim script references build_expect_prompt_block but no longer spawns setup.sh" {
    write_setup 'ask "Server IP (Standard mode)" "192.168.1.10"'
    write_sim "$fixture_root/scripts/tracked/simulations/setup-cli-simulation.sh" '
build_expect_prompt_block "setup.sh" "/tmp/does-not-matter" "192.168.1.10"
'
    write_sim "$fixture_root/scripts/tracked/simulations/syslog-forwarding-simulation.sh" 'expect_prompt {Server IP \(Standard mode\)} "192.168.1.10"'

    run bash "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer contains 'spawn bash setup.sh'"* ]]
}
