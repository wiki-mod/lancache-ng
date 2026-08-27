#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Issue #1176 (Angle 1): shared helper sourced by scripts/setup-cli-
# simulation.sh and scripts/tracked/simulations/syslog-forwarding-simulation.sh so both derive
# the expect-driven prompt-matching sequence they drive setup.sh's install
# wizard through from a REAL `setup.sh list-prompts` run, instead of hand-
# encoding the prompt text as a second, independently maintained copy.
#
# Why this is the fix, not just another check: PR #1256's
# scripts/untracked/check-setup-prompt-drift.sh (issue #1176, Angle 2) already catches
# a new UNCONDITIONAL prompt with no matching hand-encoded expect_prompt
# pattern -- but by its own documented design, it cannot catch a new prompt
# added along a CONDITIONAL branch that a simulation script's own answers
# actually walk (e.g. a new prompt inside the SSL or Kea blocks), because it
# only classifies reachability structurally, never executes setup.sh. Here,
# the simulation scripts feed setup.sh's own `list-prompts` introspection
# mode (setup.sh's ask()/confirm() calls, unmodified) the exact same reply
# sequence they are about to send interactively, and build their expect
# patterns from what that real run reports -- so a new prompt on any branch
# the script's own answers reach is picked up automatically, with nothing
# left to hand-duplicate or drift. check-setup-prompt-drift.sh remains in
# place as a second, independent static net (AG-VAL-015: an exception this
# strong should not replace a cheaper existing check).
set -euo pipefail

# escape_tcl_re <text>
# Escapes every Tcl ARE / POSIX ERE metacharacter in <text> so it can be
# embedded literally inside a Tcl `-re` pattern. Backslash must be escaped
# FIRST -- escaping any of the other metacharacters first would then
# double-escape the backslashes those substitutions themselves introduce.
escape_tcl_re() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[][(){}.^$|*+?]/\\&/g'
}

# tcl_brace_quote <text>
# Wraps <text> in Tcl's {...} literal-string form, which suppresses ALL
# substitution ($ and [ included) -- safer than double-quoting for reply
# values this script does not otherwise validate as brace-free. None of this
# project's real wizard replies (IPs, paths, y/n, DHCP-mode names, free-text
# DHCP/NTP fields) legitimately contain a literal Tcl brace; fail closed
# instead of silently emitting a malformed expect script if one ever did.
tcl_brace_quote() {
    local text="$1"
    if [[ "$text" == *'{'* || "$text" == *'}'* ]]; then
        echo "::error::tcl_brace_quote: reply value contains a literal Tcl brace, cannot safely quote: $text" >&2
        exit 1
    fi
    printf '{%s}' "$text"
}

# wizard_prompt_patterns <setup_sh_path> <answers_file>
# Runs `setup.sh list-prompts <answers_file>` and prints one Tcl -re pattern
# per real "PROMPT" line it reports, in order, on stdout (one pattern per
# line, NOT wrapped in the outer {} an `expect_prompt {pattern} reply` call
# needs -- callers add that). Each pattern reproduces ask()'s own literal
# rendering, so it validates both the prompt text AND the exact default
# value the wizard offers at that step -- strictly stronger than a pattern
# that only matches the prompt text.
#
# `[^\n]*` (not a plain literal space) between the escaped prompt and the
# opening bracket, mirroring the hand-written patterns this replaces (e.g.
# "Directory[^\n]*\[", "Username[^\n]*\[admin\]"): ask()'s real printf format
# is `"  ${BOLD}%s${RESET} [%s]: "` -- the ANSI RESET escape sequence lands
# BETWEEN "$prompt" and the literal " [", so a pattern assuming the two are
# directly adjacent never matches against real terminal output (confirmed by
# a real `expect` timeout during end-to-end validation on lancache-240: the
# introspection-derived pattern for "Server IP (Standard mode)" was correct
# text but missing this gap, and hung waiting for a prompt that had, in
# fact, already been printed).
#
# <setup_sh_path> is invoked via `bash`, not executed directly, so this
# works whether or not the caller's checkout preserved the executable bit
# (see AG-VAL-024's Windows/core.filemode=false caveat -- this project's own
# CI/authoring hosts cannot always verify or rely on that bit being set).
wizard_prompt_patterns() {
    local setup_sh="$1" answers_file="$2" tag prompt default

    while IFS=$'\t' read -r tag prompt default; do
        [[ "$tag" = "PROMPT" ]] || continue
        printf '%s[^\\n]*\\[%s\\]\n' "$(escape_tcl_re "$prompt")" "$(escape_tcl_re "$default")"
    done < <(bash "$setup_sh" list-prompts "$answers_file")
}

# build_expect_prompt_block <setup_sh_path> <answers_file> <reply...>
# Writes <answers_file> from the given ordered <reply...> values (one per
# line -- an empty reply argument writes a blank line, which setup.sh's own
# introspection mode already treats as "accept the default", mirroring a
# real blank Enter keypress), then prints one
# `expect_prompt {<pattern>} <braced-reply>` line per real prompt setup.sh's
# wizard reports for that exact answer sequence, in order -- ready to be
# substituted straight into an expect heredoc.
#
# Fails closed if the number of prompts setup.sh's wizard actually asks for
# this answer sequence does not match the number of replies supplied: a
# mismatch means either this call site's reply list is stale (the wizard
# gained or lost a prompt on the branch these replies walk) or genuinely
# ran out of replies mid-sequence -- either way, silently zipping mismatched
# arrays would build an expect script that waits on the wrong prompt at some
# later step instead of failing at the one point the mismatch is fully known.
build_expect_prompt_block() {
    local setup_sh="$1" answers_file="$2"
    shift 2
    local -a replies=("$@")
    printf '%s\n' "${replies[@]}" > "$answers_file"

    local -a patterns=()
    while IFS= read -r pattern; do
        patterns+=("$pattern")
    done < <(wizard_prompt_patterns "$setup_sh" "$answers_file")

    if [[ "${#patterns[@]}" -ne "${#replies[@]}" ]]; then
        echo "::error::build_expect_prompt_block: setup.sh list-prompts reported ${#patterns[@]} prompt(s) for this answer sequence, but ${#replies[@]} repl(y/ies) were supplied -- the reply list at this call site is out of sync with the wizard's real current prompt sequence for this branch." >&2
        exit 1
    fi

    local i
    for i in "${!patterns[@]}"; do
        printf 'expect_prompt {%s} %s\n' "${patterns[$i]}" "$(tcl_brace_quote "${replies[$i]}")"
    done
}
