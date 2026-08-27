#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI guard for issue #1176: setup.sh's interactive install wizard and the
# expect-driven simulation scripts that drive it (scripts/setup-cli-
# simulation.sh, scripts/tracked/simulations/syslog-forwarding-simulation.sh) hand-duplicate the
# same fact -- the exact prompt text each `ask`/`confirm` call in setup.sh's
# wizard prints -- with nothing that ever checked the two stay in sync. This
# is the same failure class as #1112/#1171 (a shared literal moved without
# updating every hand-duplicated copy), applied to the specific incident that
# actually happened: PR #1082 added a new, unconditional "Enable
# LanCache-NG-NTP? [y/N]" prompt to the wizard, but neither simulation
# script's hand-encoded `expect_prompt` sequence was updated to answer it, so
# both hung until timeout (issue #1175) -- silently, until CI happened to run
# those specific jobs against an unrelated PR days later.
#
# --- What this DOES catch --------------------------------------------------
# Two checks, both mechanical and both run against setup.sh's real current
# source text (never a hand-maintained duplicate list, which could itself
# drift):
#   1. Coverage: every prompt setup.sh's install wizard asks UNCONDITIONALLY
#      (i.e. not nested inside any `if`/`case` branch -- see the
#      classification note below) must have a matching `expect_prompt`
#      pattern in EVERY simulation script that drives the wizard. This is
#      exactly the #1082/#1175 shape: a new unconditional prompt appears and
#      a sim script's hand-encoded sequence does not grow to match it, which
#      hangs that sim at the new prompt (expect never sends an answer for it,
#      and setup.sh's `ask()` blocks on `/dev/tty` forever).
#   2. Staleness: every `expect_prompt` pattern in a simulation script must
#      still match at least one real prompt text currently in setup.sh's
#      wizard (conditional or unconditional). A pattern matching nothing
#      real means the prompt it was written for was renamed or removed in
#      setup.sh without updating the simulation script -- the same drift
#      class, just discovered from the other direction.
#
# --- Historical blind spot, now closed for introspection-driven scripts ----
# A *new* prompt inserted along a *conditional* branch that a simulation
# script's own answers actually walk (e.g. a new prompt added inside the SSL
# block, which scripts/tracked/simulations/syslog-forwarding-simulation.sh's SSL_ENABLED=y path
# exercises) used to be invisible to check 1 above, because this script never
# executed setup.sh or interpreted which conditional branches a given sim's
# fixed answer sequence actually takes -- it only classified whether a
# prompt is reachable unconditionally from the top of the wizard.
#
# Issue #1176's Angle 1 (`setup.sh list-prompts`, a real introspection mode
# that walks the wizard's actual branch logic for a supplied answer
# sequence -- see setup.sh's own `wizard_introspect_record_prompt` comment)
# closes this from the OTHER direction: scripts/tracked/simulations/setup-cli-simulation.sh and
# scripts/tracked/simulations/syslog-forwarding-simulation.sh no longer hand-encode their
# expect_prompt sequences at all -- they call
# scripts/lib/setup-wizard-introspect.sh's build_expect_prompt_block, which
# runs `setup.sh list-prompts` with the exact same replies the script is
# about to send interactively and builds the expect patterns from that real,
# current output. There is nothing left in either file for THIS script's
# static text-matching (steps 3-5 below) to compare against, and that is
# correct, not a gap: a script with no hand-encoded copy cannot drift from
# one. Per AG-VAL-015, this script is not deleted or weakened just because
# introspection makes its coverage/staleness checks moot for these two files
# -- it still runs a real check on any file that still hand-encodes
# expect_prompt patterns (see is_introspection_driven's own comment for the
# detection rule and its sanity-check fallback), so it remains a live second
# net for any simulation script that has not adopted introspection yet, or
# adopts it incorrectly.
#
# --- How prompts are classified: unconditional vs. conditional -------------
# setup.sh's install wizard is NOT a function -- it is top-level script code
# that runs when the `install|""` case in setup.sh's subcommand dispatch
# falls through (see the fixed anchors this script greps for below). This
# script walks that region line by line, maintaining a stack of open control
# blocks:
#   - A line whose first token (after stripping leading whitespace) is `if`
#     pushes an "if" tag; `elif`/`else` are no-ops (same tag, still open);
#     `fi` pops.
#   - `case` pushes a "case" tag; `esac` pops.
#   - `while`/`until`/`for`/`select` push a "loop" tag; `done` pops.
# A prompt is "unconditional" if, at the point it is reached, the stack
# contains no "if" or "case" tag -- only "loop" tags (or is empty). This
# deliberately treats setup.sh's `while true; do ask ...; done`
# retry-until-valid-input loops (used throughout for IP/CIDR/path
# validation) as NOT conditional: every one of them always asks at least
# once and only repeats on invalid input, it never skips the prompt
# entirely, unlike an `if`/`case` branch that can be skipped outright based
# on an earlier answer. Confirmed by manual trace against setup.sh as of
# this script's introduction: exactly 11 prompts were unconditional (Server
# IP, Enable SSL mode?, Directory, Cache directory, Cache size, Cache RAM
# buffer, Enable scheduled automatic updates?, DHCP mode, Enable
# LanCache-NG-NTP?, Protect Admin-UI with password?, Start now?); issue
# #1343 added a 12th, "Enable central logging?" (between the NTP and
# Admin-UI-password prompts), and both current simulation scripts answer all
# 12 via their introspection-driven expect_prompt sequences (see
# scripts/lib/setup-wizard-introspect.sh) -- see this script's own bats
# coverage (tests/bats/check_setup_prompt_drift.bats) for fixtures that
# exercise the classifier directly rather than relying on this trace alone.
#
# This line-classification approach is deliberately NOT a generic bash
# parser: it assumes one control-flow keyword per physical line (confirmed
# true for setup.sh's entire wizard region: no one-line `if ...; then ...;
# fi` compaction, no function definitions, no brace-group blocks appear in
# that region as of this script's introduction) and fails closed (see
# parse_wizard_prompts's own comment) rather than silently misclassifying if
# that ever stops holding.
#
# --- Scope boundary: package-install confirms are NOT covered --------------
# `confirm "Install this package now? [y/N]"` (and similar) calls live
# inside helper functions (e.g. ensure_stack_requirements_installed) defined
# EARLIER in setup.sh and merely invoked from the wizard region -- they are
# not textually present in the wizard region this script scans. They also
# depend on real host package state (Docker/git already present or not),
# not a fixed prompt sequence a scripted CI transcript walks deterministically
# -- on every runner this project's CI actually uses, those packages are
# already present, so these confirms never fire in practice. Out of scope by
# design, not a silent gap.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

setup_script="setup.sh"
sim_scripts=(
    "scripts/tracked/simulations/setup-cli-simulation.sh"
    "scripts/tracked/simulations/syslog-forwarding-simulation.sh"
)

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

violations=0
fail() {
    printf "%b[SETUP PROMPT DRIFT]%b %s\n" "$RED" "$NC" "$1" >&2
    violations=$((violations + 1))
}

[[ -f "$setup_script" ]] \
    || { printf "%b[SETUP PROMPT DRIFT]%b expected %s not found under %s.\n" "$RED" "$NC" "$setup_script" "$repo_root" >&2; exit 1; }
for sim in "${sim_scripts[@]}"; do
    [[ -f "$sim" ]] \
        || { printf "%b[SETUP PROMPT DRIFT]%b expected simulation script not found: %s\n" "$RED" "$NC" "$sim" >&2; exit 1; }
done

# --- Step 1: locate the install wizard region -------------------------------
# Anchored on the subcommand dispatch `case "${1:-install}" in` (unique,
# column-0) and its own matching `esac` (also unique, column-0) -- everything
# after that `esac` to EOF is the linear top-level install wizard (see header
# comment). Both anchors are verified unique/present so a future refactor
# that renames or restructures the dispatch fails this script loudly instead
# of silently scanning the wrong region (or none at all).
mapfile -t case_start_matches < <(grep -n '^case "${1:-install}" in$' "$setup_script")
if [[ ${#case_start_matches[@]} -ne 1 ]]; then
    fail "expected exactly one 'case \"\${1:-install}\" in' anchor line in $setup_script, found ${#case_start_matches[@]} -- update this script's anchor if the dispatch was refactored."
    exit 1
fi
case_start_line="${case_start_matches[0]%%:*}"

mapfile -t esac_matches < <(awk -v start="$case_start_line" 'NR > start && /^esac$/ {print NR}' "$setup_script")
if [[ ${#esac_matches[@]} -eq 0 ]]; then
    fail "could not find the column-0 'esac' closing the subcommand dispatch case in $setup_script after line $case_start_line -- update this script's anchor if the dispatch was refactored."
    exit 1
fi
esac_line="${esac_matches[0]}"
wizard_start=$((esac_line + 1))
total_lines=$(wc -l < "$setup_script")

if (( wizard_start >= total_lines )); then
    fail "the install wizard region (after line $esac_line in $setup_script) is empty or missing -- refusing to run a vacuous check."
    exit 1
fi

# --- Step 2: walk the wizard region, extracting every ask/confirm prompt ---
# Output format: one line per prompt occurrence, "FLAG\tPROMPT\tHAYSTACK\tLINE",
# where FLAG is UNCOND or COND, PROMPT is the literal first argument (used for
# human-readable fail messages), and HAYSTACK is what ask() actually prints at
# runtime for this call. See the header comment for the classification rule
# and its "one keyword per physical line" assumption.
#
# HAYSTACK must include ask()'s own rendering, not just the bare prompt: ask()
# (defined near the top of setup.sh) always prints "$prompt [$default]: " --
# several real expect_prompt patterns anchor on that trailing bracket+default
# (e.g. "Username[^\n]*\[admin\]" asserts the Username prompt's default is
# literally "admin"; "Directory[^\n]*\[" only matches because ask() appends "
# [" after every prompt, not because setup.sh's own prompt literal contains a
# bracket). Matching against the bare PROMPT alone would make every such
# pattern falsely appear stale.
parse_wizard_prompts() {
    local -a stack=()
    local lineno=0 line trimmed leading flag prompt rest after_prompt default_part default haystack

    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Strip leading whitespace the same way check-idempotence-test-
        # coverage.sh does (plain parameter expansion, no sed/awk regex
        # dependency -- this project has hit real awk/grep -P portability
        # gaps on its self-hosted runners before, see that script's own
        # comment).
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" ]] && continue

        # Classify and extract a prompt BEFORE this line's own control-flow
        # keyword (if any) is pushed onto the stack: a line like
        # `if confirm "...?" "N"; then` uses the CURRENT (pre-push) stack to
        # classify its embedded confirm call, since that call evaluates the
        # if's own condition and therefore runs whether or not the if's body
        # is entered -- its conditionality comes from whatever encloses this
        # line already, not from the if this line itself opens.
        case "$trimmed" in
            *'ask "'*)
                rest="${trimmed#*ask \"}"
                prompt="${rest%%\"*}"
                ;;
            *'confirm "'*)
                rest="${trimmed#*confirm \"}"
                prompt="${rest%%\"*}"
                ;;
            *)
                prompt=""
                ;;
        esac
        if [[ -n "$prompt" ]]; then
            case "$prompt" in
                '$'*)
                    fail "$setup_script:$lineno: an ask/confirm call's first argument looks like a bare variable reference ('$prompt'), not a literal prompt string -- this script only understands literal prompts; update parse_wizard_prompts if setup.sh legitimately needs a variable prompt here."
                    ;;
                *)
                    # Every ask()/confirm() call in the wizard region passes a
                    # second, quoted (possibly empty) default argument --
                    # confirmed by inspection of every call site as of this
                    # script's introduction. Fail closed rather than silently
                    # matching against an incomplete haystack if that shape
                    # ever stops holding.
                    after_prompt="${rest#*\"}"
                    if [[ "$after_prompt" == "$rest" || "$after_prompt" != *'"'* ]]; then
                        fail "$setup_script:$lineno: could not find a second quoted (default) argument after prompt '$prompt' -- every ask()/confirm() call in the wizard is expected to pass one; update parse_wizard_prompts if this call's shape genuinely changed."
                    else
                        default_part="${after_prompt#*\"}"
                        default="${default_part%%\"*}"
                        haystack="$prompt [$default]: "

                        flag="UNCOND"
                        for tag in "${stack[@]}"; do
                            if [[ "$tag" = "if" || "$tag" = "case" ]]; then
                                flag="COND"
                                break
                            fi
                        done
                        printf '%s\t%s\t%s\t%s\n' "$flag" "$prompt" "$haystack" "$lineno"
                    fi
                    ;;
            esac
        fi

        # Now update the stack based on this line's own leading keyword.
        leading="${trimmed%% *}"
        [[ "$leading" = "$trimmed" ]] || true # leading already set correctly either way
        case "$leading" in
            if) stack+=("if") ;;
            elif|else) ;;
            fi)
                if [[ ${#stack[@]} -eq 0 || "${stack[-1]}" != "if" ]]; then
                    fail "$setup_script:$lineno: found 'fi' with no matching open 'if' on the tracked block stack -- the one-keyword-per-line assumption behind this script's classifier no longer holds; see this script's header comment."
                else
                    unset 'stack[-1]'
                fi
                ;;
            while|until|for|select) stack+=("loop") ;;
            done)
                if [[ ${#stack[@]} -eq 0 || "${stack[-1]}" != "loop" ]]; then
                    fail "$setup_script:$lineno: found 'done' with no matching open loop on the tracked block stack -- the one-keyword-per-line assumption behind this script's classifier no longer holds; see this script's header comment."
                else
                    unset 'stack[-1]'
                fi
                ;;
            case) stack+=("case") ;;
            "esac")
                if [[ ${#stack[@]} -eq 0 || "${stack[-1]}" != "case" ]]; then
                    fail "$setup_script:$lineno: found 'esac' with no matching open 'case' on the tracked block stack -- the one-keyword-per-line assumption behind this script's classifier no longer holds; see this script's header comment."
                else
                    unset 'stack[-1]'
                fi
                ;;
            *) ;;
        esac
    done < <(tail -n "+$wizard_start" "$setup_script")

    if [[ ${#stack[@]} -ne 0 ]]; then
        fail "the wizard region in $setup_script ended with ${#stack[@]} unclosed block(s) still open on the tracked stack -- the one-keyword-per-line assumption behind this script's classifier no longer holds; see this script's header comment."
    fi
}

mapfile -t prompt_rows < <(parse_wizard_prompts)
if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d parse error(s) while scanning %s's install wizard.%b\n" "$RED" "$violations" "$setup_script" "$NC" >&2
    exit 1
fi
if [[ ${#prompt_rows[@]} -eq 0 ]]; then
    fail "found zero ask/confirm prompts in $setup_script's install wizard region (lines $wizard_start-$total_lines) -- refusing to run a vacuous check; check the extraction pattern in this script."
    exit 1
fi

# All real prompt haystacks (conditional + unconditional), deduped, for the
# staleness check. Field 3 (HAYSTACK), not field 2 (bare PROMPT) -- see
# parse_wizard_prompts's comment on why matching must include ask()'s own
# " [default]: " rendering.
mapfile -t all_prompts < <(printf '%s\n' "${prompt_rows[@]}" | cut -f3 | sort -u)
# Unconditional-only "PROMPT\tHAYSTACK" pairs, deduped, for the coverage
# check: PROMPT for human-readable fail messages, HAYSTACK for matching. If
# the same literal text appears both as an unconditional occurrence somewhere
# and a conditional occurrence elsewhere, it is still required (a scripted
# run can reach it via the unconditional path), so this filters on "at least
# one UNCOND occurrence" rather than "every occurrence is UNCOND".
mapfile -t unconditional_prompts < <(printf '%s\n' "${prompt_rows[@]}" | awk -F'\t' '$1 == "UNCOND" {print $2 "\t" $3}' | sort -u)

if [[ ${#unconditional_prompts[@]} -eq 0 ]]; then
    fail "found zero unconditional prompts in $setup_script's install wizard -- refusing to run a vacuous coverage check; check the classifier in this script (parse_wizard_prompts)."
    exit 1
fi

# --- Step 3: extract each simulation script's expect_prompt patterns -------
# expect_prompt {PATTERN} REPLY -- PATTERN is a Tcl `-re` (advanced regular
# expression) pattern, extracted between the first '{' and the following
# '}' (none of the patterns in either current simulation script contain an
# embedded literal '}', confirmed by inspection; a pattern that did would
# need a smarter extractor than this one).
#
# Matched only when the TRIMMED line starts with "expect_prompt {" (not a
# bare substring match): both simulation scripts also define
# `proc expect_prompt {pattern reply} { ... }` itself, whose own signature
# line contains the substring "expect_prompt {" too but is not a call --
# a substring match would misextract its literal parameter list ("pattern
# reply") as if it were a real expected prompt pattern.
extract_expect_patterns() {
    local file="$1" line trimmed rest pattern
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            'expect_prompt {'*)
                rest="${line#*expect_prompt \{}"
                pattern="${rest%%\}*}"
                [[ -n "$pattern" ]] && printf '%s\n' "$pattern"
                ;;
        esac
    done < "$file"
}

# to_grep_pattern <tcl-pattern>
# Tcl ARE and POSIX ERE (grep -E) agree on \(, \), \?, \[, \] as literal
# escapes, so those pass through untouched. `[^\n]` is the one place they
# provably diverge for this project's own toolchain: POSIX bracket
# expressions do not give backslash any special meaning inside `[...]`, so
# `[^\n]` is "not backslash and not the letter n" under strict POSIX/GNU
# grep -E, not "not newline" -- and several real prompt texts contain the
# letter n in the very substring this wildcard is meant to skip over (e.g.
# "Directory[^\n]*\[" needs to skip through anything, and does contain "n"
# characters in real installer output). Since every haystack here is always
# a single line (no real newlines), `.` (any char) is behaviorally
# equivalent to the *intended* meaning of `[^\n]` and sidesteps the
# divergence entirely.
to_grep_pattern() {
    printf '%s' "$1" | sed 's/\[\^\\n\]/./g'
}

# is_introspection_driven <file>
# Issue #1176 (Angle 1): true when <file> derives its expect_prompt sequence
# from scripts/lib/setup-wizard-introspect.sh's build_expect_prompt_block
# (a real `setup.sh list-prompts` run) instead of hand-encoding it -- the
# reference to that function name is the one signal this script trusts,
# mirroring how parse_wizard_prompts above trusts only setup.sh's own
# `ask "..."` / `confirm "..."` call sites rather than a broader heuristic.
# A file that matches still needs SOME sanity check that it has not simply
# stopped driving the wizard altogether (the exact regression the zero-
# patterns fail-closed check below exists to catch for hand-encoded files);
# `spawn bash setup.sh` is that check here -- it is the literal `expect`
# command that starts the real wizard, unrelated to how the prompt sequence
# feeding it was built.
is_introspection_driven() {
    local file="$1"
    grep -qF 'build_expect_prompt_block' "$file" || return 1
    if ! grep -qF 'spawn bash setup.sh' "$file"; then
        fail "$file references build_expect_prompt_block (introspection-driven) but no longer contains 'spawn bash setup.sh' -- it may have stopped driving the real install wizard entirely; update this script's sanity check if that invocation genuinely changed shape."
    fi
    return 0
}

# --- Step 4/5: coverage + staleness, per simulation script -----------------
statically_checked_sims=0
for sim in "${sim_scripts[@]}"; do
    if is_introspection_driven "$sim"; then
        # violations may have just been incremented by is_introspection_driven's
        # own sanity check (missing "spawn bash setup.sh") -- only print the
        # reassuring green line when that check actually passed, so a real
        # failure isn't immediately followed by a confusing "all good" line.
        if [[ $violations -eq 0 ]]; then
            printf "%b✓ %s derives its expect_prompt sequence from a real 'setup.sh list-prompts' run (scripts/lib/setup-wizard-introspect.sh) -- nothing hand-encoded to check for drift here; see this script's header.%b\n" "$GREEN" "$sim" "$NC"
        fi
        continue
    fi
    statically_checked_sims=$((statically_checked_sims + 1))

    mapfile -t sim_patterns < <(extract_expect_patterns "$sim")
    if [[ ${#sim_patterns[@]} -eq 0 ]]; then
        fail "found zero expect_prompt patterns in $sim -- refusing to run a vacuous check; check extract_expect_patterns in this script or whether $sim still drives setup.sh's wizard at all."
        continue
    fi

    # Precompute each pattern's grep-E form once (rather than inside the
    # nested loops below) -- avoids re-spawning `sed` once per (prompt,
    # pattern) combination, which is otherwise O(prompts x patterns).
    grep_patterns=()
    for tcl_pattern in "${sim_patterns[@]}"; do
        grep_patterns+=("$(to_grep_pattern "$tcl_pattern")")
    done

    # Step 4: coverage -- every unconditional prompt must be answerable by
    # this sim script (the #1082/#1175 shape).
    for pair in "${unconditional_prompts[@]}"; do
        prompt="${pair%%$'\t'*}"
        haystack="${pair#*$'\t'}"
        covered=0
        for grep_pattern in "${grep_patterns[@]}"; do
            # Here-string, not a live pipe into grep -q -- issue #1377.
            if grep -Eq -- "$grep_pattern" <<<"$haystack"; then
                covered=1
                break
            fi
        done
        if [[ "$covered" -eq 0 ]]; then
            fail "$sim has no expect_prompt pattern matching setup.sh's unconditional wizard prompt '$prompt' -- this is the exact #1082/#1175 shape: a new or changed unconditional prompt with no matching answer in this simulation script's expect sequence would hang it until timeout."
        fi
    done

    # Step 5: staleness -- every pattern this sim script hand-encodes must
    # still match some real prompt currently in setup.sh's wizard.
    for i in "${!sim_patterns[@]}"; do
        tcl_pattern="${sim_patterns[$i]}"
        grep_pattern="${grep_patterns[$i]}"
        matched=0
        for haystack in "${all_prompts[@]}"; do
            # Here-string, not a live pipe into grep -q -- issue #1377.
            if grep -Eq -- "$grep_pattern" <<<"$haystack"; then
                matched=1
                break
            fi
        done
        if [[ "$matched" -eq 0 ]]; then
            fail "$sim's expect_prompt pattern '$tcl_pattern' does not match any real prompt currently in $setup_script's install wizard -- likely stale (the prompt it was written for was renamed or removed in setup.sh without updating this simulation script)."
        fi
    done
done

if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d setup.sh/simulation-script prompt drift finding(s) found.%b See issue #1176.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

if [[ "$statically_checked_sims" -eq 0 ]]; then
    printf "%b✓ All %d simulation script(s) are introspection-driven (issue #1176) -- no hand-encoded expect_prompt sequence left to check for drift.%b\n" "$GREEN" "${#sim_scripts[@]}" "$NC"
else
    printf "%b✓ All %d unconditional setup.sh wizard prompts are covered by every statically-checked simulation script (%d of %d), and every one of their expect_prompt patterns still matches a real prompt.%b\n" "$GREEN" "${#unconditional_prompts[@]}" "$statically_checked_sims" "${#sim_scripts[@]}" "$NC"
fi
exit 0
