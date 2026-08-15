#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Hard line-count ceiling for .github/workflows/*.yml (issue #1095's
# build-push.yml trigger investigation, 2026-08-01). Empirically confirmed via
# a live bisection on a throwaway branch/PR (test/old-buildpush-trigger-check,
# PR #1381): a self-modifying pull_request event against build-push.yml
# dispatches a real Build & Push run at 8191/8193/8998/8999 lines, but never
# dispatches ANY run object at all (not even a skipped conclusion -- same
# signature as a paths-ignore match) at 9216 lines. Three real, independent
# PRs (#1356, #1378, #1379), all sitting at ~9098-9110 lines after modifying
# this same file, never got a single Build & Push run across many retries
# each, while the file's own known-good historical version (PR #1344,
# 2026-07-31) and every throwaway test under ~9000 lines triggered normally.
#
# The exact cutoff between 8999 and 9216 was not pinned down further (this is
# a defensive guardrail, not a root-cause fix -- GitHub Support has been
# notified separately). MAX_WORKFLOW_LINES is set to 8999, the maintainer's
# own tested reference point (an earlier revision of this script defaulted
# to 8500, an AI-chosen safety margin the maintainer had not been consulted
# on and did not want -- corrected here per direct maintainer instruction).
#
# MAX_WORKFLOW_BYTES adds a second, independent dimension at the maintainer's
# request: measured byte sizes from the same bisection were ~504-505KB at
# 8998/8999 lines (dispatches fine) vs. ~512KB at the real 9104-line failing
# size and ~518KB at 9216 lines (both dead) -- so byte size tracks the same
# boundary as line count here, but is checked separately in case a future
# file has unusually short or long lines where the two diverge.
# MAX_WORKFLOW_BYTES defaults to 512000 (500 KiB, the maintainer's own stated
# reference point: "493kb ging, 500kb nicht ... sollten wir auch unter 500kb
# bleiben").
#
# MAX_RUN_BLOCK_BYTES adds a third, independent dimension (issue #1535,
# 2026-08-13): a single oversized `run:` block can hang actionlint's embedded
# shellcheck even while the whole file sits comfortably under the two limits
# above -- confirmed live via real bisection: build-push.yml's single largest
# `run:` block (1016 lines) passed at 74695 bytes but hung indefinitely
# (requiring a hard kill) once padded past a threshold pinned down to a
# 25-byte window between 75440 bytes (confirmed clean, 8/8 real runs) and
# 75465 bytes (confirmed hanging, 8/8 real runs) -- see AG-CI-021 and this
# script's own bats coverage for the full reproduction. This is a distinct
# failure mode from GitHub's whole-file dispatch cliff above: different
# mechanism (a hard limit inside actionlint's bundled shellcheck integration,
# not GitHub's own run-dispatch logic), different unit (per-block, not
# per-file), and it can trigger while the file is nowhere near 8999 lines or
# 512000 bytes. MAX_RUN_BLOCK_BYTES defaults to 74000, leaving ~1440 bytes of
# headroom below the confirmed-clean 75440-byte point -- not a generously
# invented safety margin, the same live-tested-boundary convention the two
# limits above already use. PR #1572 fixed the one real offending block by
# splitting it into 9 smaller steps; this check exists so the next PR that
# grows a `run:` block back past the cliff gets a red check instead of a
# silently hung `shellcheck` job discoverable only via a killed CI run.
#
# Measurement unit: raw YAML bytes of the block's content lines exactly as
# they appear in the file, including each line's leading block-scalar
# indentation -- the same unit issue #1535's own bisection used, confirmed
# there to track the real cliff even though actionlint itself later dedents
# the block by roughly 10 bytes/line before handing it to shellcheck (an
# already-documented, deliberately conservative approximation, not an
# oversight). A `run:` block is located by finding a `run:` mapping key whose
# value starts with a YAML block-scalar indicator (`|` or `>`, with any
# combination of the optional chomping (`-`/`+`) and explicit
# indentation-indicator (`1`-`9`) modifiers YAML's block-scalar-header
# grammar allows, in either order -- e.g. `run: |`, `run: >-`, `run: |2+`),
# then walking forward until a non-blank line's indentation drops back to or
# below the `run:` key's own column, mirroring the walk issue #1535's own
# analysis performed by hand. Plain (non-block-scalar) `run:` values, e.g.
# `run: echo hi`, are a single short line by construction in this repository
# and are not measured here -- the confirmed failure mode is specific to the
# large heredoc-style block scalars this repository's workflows actually use
# for multi-line shell. Scope is `.github/workflows/*.yml` only, matching
# MAX_WORKFLOW_LINES/MAX_WORKFLOW_BYTES above and AG-CI-021's own wording;
# composite actions under `.github/actions/**` are a known, deliberately
# unaddressed gap here (not fixed in this pass -- see issue #1535 for the
# scope note), since the only real offending block found and fixed so far
# (PR #1572) was a workflow file, not a composite action.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

MAX_WORKFLOW_LINES="${MAX_WORKFLOW_LINES:-8999}"
MAX_WORKFLOW_BYTES="${MAX_WORKFLOW_BYTES:-512000}"
MAX_RUN_BLOCK_BYTES="${MAX_RUN_BLOCK_BYTES:-74000}"

# What: extracts every `run:` block-scalar's content-line byte span from one
# YAML file, one `<start-line>\t<raw-bytes>` pair per block on stdout.
# Why: a single `awk` pass is far cheaper than re-parsing the file once per
# candidate block, and keeping the state machine in one function (rather than
# duplicating it inline at each call site) is the AG-CODE-011/AG-CODE-013
# reuse point for a check that must run once per workflow file.
# From: Issue #1535
measure_run_blocks() {
    local file="$1"
    awk '
        function leadspace(s) {
            match(s, /^[ \t]*/)
            return RLENGTH
        }
        function flush_block() {
            if (started) {
                printf "%d\t%d\n", block_start, block_bytes
            }
            # Reset started (not just in_block): without this, a block
            # flushed mid-file leaves started=1 as global awk state, and the
            # unconditional flush_block() in END re-prints that same already
            # -flushed block a second time whenever no later run: header
            # resets it first -- a real, confirmed double-report bug, not a
            # hypothetical one.
            in_block = 0
            started = 0
        }
        {
            line = $0
            if (in_block) {
                tmp = line
                sub(/^[ \t]*/, "", tmp)
                if (length(tmp) == 0) {
                    # A blank line never terminates a block scalar (YAML
                    # spec) and its own bytes (just the newline) still count
                    # toward the raw-byte measurement.
                    block_bytes += length(line) + 1
                    next
                }
                ind = leadspace(line)
                if (!started) {
                    if (ind > key_indent) {
                        started = 1
                        content_indent = ind
                        block_bytes += length(line) + 1
                        next
                    }
                } else if (ind >= content_indent) {
                    block_bytes += length(line) + 1
                    next
                }
                # Indentation dropped back to (or below) the parent level:
                # the block scalar ends here. Flush it, then fall through so
                # this same line is still checked as a possible new header.
                flush_block()
            }
            if (!in_block && match(line, /^[ ]*(- )?run:[ ]*[|>][+-]?[0-9]?[+-]?[ ]*(#.*)?$/)) {
                match(line, /^[ ]*(- )?run:/)
                key_indent = RLENGTH - 4
                match(line, /[|>][+-]?[0-9]?[+-]?/)
                indicator = substr(line, RSTART, RLENGTH)
                digit = indicator
                gsub(/[^0-9]/, "", digit)
                in_block = 1
                block_start = NR + 1
                block_bytes = 0
                if (digit != "") {
                    # Explicit indentation indicator: content indent is fixed
                    # relative to the key, not auto-detected from the first
                    # line -- required so an all-blank-first-lines block is
                    # still measured correctly instead of mis-detecting the
                    # block as empty.
                    started = 1
                    content_indent = key_indent + digit
                } else {
                    started = 0
                    content_indent = 0
                }
            }
        }
        END { flush_block() }
    ' "$file"
}

line_offenders=()
byte_offenders=()
run_block_offenders=()
while IFS= read -r -d '' file; do
    lines=$(wc -l < "$file")
    bytes=$(wc -c < "$file")
    if [ "$lines" -gt "$MAX_WORKFLOW_LINES" ]; then
        line_offenders+=("$file:$lines")
    fi
    if [ "$bytes" -gt "$MAX_WORKFLOW_BYTES" ]; then
        byte_offenders+=("$file:$bytes")
    fi
    while IFS=$'\t' read -r block_line block_bytes; do
        [ -n "$block_line" ] || continue
        if [ "$block_bytes" -gt "$MAX_RUN_BLOCK_BYTES" ]; then
            run_block_offenders+=("$file:$block_line:$block_bytes")
        fi
    done < <(measure_run_blocks "$file")
done < <(find .github/workflows -maxdepth 1 -name '*.yml' -print0)

if [ "${#line_offenders[@]}" -gt 0 ] || [ "${#byte_offenders[@]}" -gt 0 ] || [ "${#run_block_offenders[@]}" -gt 0 ]; then
    if [ "${#line_offenders[@]}" -gt 0 ]; then
        echo "Workflow file(s) over the ${MAX_WORKFLOW_LINES}-line hard limit:" >&2
        for entry in "${line_offenders[@]}"; do
            echo "  ${entry%:*} (${entry##*:} lines)" >&2
        done
    fi
    if [ "${#byte_offenders[@]}" -gt 0 ]; then
        echo "Workflow file(s) over the ${MAX_WORKFLOW_BYTES}-byte hard limit:" >&2
        for entry in "${byte_offenders[@]}"; do
            echo "  ${entry%:*} (${entry##*:} bytes)" >&2
        done
    fi
    if [ "${#run_block_offenders[@]}" -gt 0 ]; then
        echo "run: block(s) over the ${MAX_RUN_BLOCK_BYTES}-byte hard limit:" >&2
        for entry in "${run_block_offenders[@]}"; do
            f="${entry%%:*}"
            rest="${entry#*:}"
            block_line="${rest%%:*}"
            block_bytes="${rest#*:}"
            echo "  ${f} (block starting at line ${block_line}, ${block_bytes} bytes)" >&2
        done
    fi
    echo "" >&2
    echo "The line/byte limits exist because GitHub silently stops dispatching" >&2
    echo "pull_request runs for a workflow file that modifies itself past some" >&2
    echo "threshold above ~9000 lines / ~500KB (no error, no skipped conclusion --" >&2
    echo "the run is never created at all). The run: block limit exists because" >&2
    echo "actionlint's embedded shellcheck hangs indefinitely on a single run:" >&2
    echo "block above ~75440-75465 bytes, independent of overall file size. See" >&2
    echo "scripts/check-workflow-line-limit.sh's own header comment and issues" >&2
    echo "#1095 / #1535 for both reproductions. Split the file/block or trim its" >&2
    echo "comments rather than raising any of these limits." >&2
    exit 1
fi

echo "All .github/workflows/*.yml files are within the ${MAX_WORKFLOW_LINES}-line, ${MAX_WORKFLOW_BYTES}-byte, and ${MAX_RUN_BLOCK_BYTES}-byte-per-run-block hard limits."
