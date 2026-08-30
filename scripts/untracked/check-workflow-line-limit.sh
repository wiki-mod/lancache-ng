#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Enforces three .github/workflows size ceiling limits.
# Why: GitHub drops runs above limit; actionlint hangs on blocks.
# From: Issue #1535 | PR #1575
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# What: Whole-file line ceiling.
# Why: GitHub drops self-modifying workflows above ~9000 lines.
# From: Issue #1095
MAX_WORKFLOW_LINES="${MAX_WORKFLOW_LINES:-8999}"

# What: Whole-file byte ceiling limit.
# Why: Tracks GitHub dispatch cliff across varying line lengths.
# From: Issue #1095
MAX_WORKFLOW_BYTES="${MAX_WORKFLOW_BYTES:-512000}"

# What: Per-run block byte ceiling limit.
# Why: actionlint's shellcheck hangs on large per-block bytes.
# From: Issue #1535
MAX_RUN_BLOCK_BYTES="${MAX_RUN_BLOCK_BYTES:-74000}"

# What: Extracts run block-scalar byte spans for measurement.
# Why: Shared function avoids re-deriving indentation logic.
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
            # What: Resets started flag in addition to in_block.
            # Why: Leaving started=1 causes flush_block() to be called twice.
            # From: Issue #1535
            in_block = 0
            started = 0
        }
        {
            line = $0
            if (in_block) {
                tmp = line
                sub(/^[ \t]*/, "", tmp)
                if (length(tmp) == 0) {
                    # What: counts the bytes of a blank line without ending the block.
                    # Why: YAML block scalars keep blank lines as content.
                    # From: Issue #1535
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
                # What: Flushes block, re-checks line as possible header.
                # Why: Indentation dropped; block scalar ended here.
                # From: Issue #1535
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
                # What: Uses fixed indent when digit indicator present.
                # Why: Avoids mis-detecting all-blank-first-lines blocks.
                # From: Issue #1535
                if (digit != "") {
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

# What: Collects offending workflow files/blocks across ceilings.
# Why: Single loop applies three checks consistently per file.
# From: Issue #1535 | PR #1575
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
    # What: Captures measure_run_blocks output before consuming it.
    # Why: Process-substitution failures are invisible to set -e.
    # From: Issue #1535
    if ! block_report=$(measure_run_blocks "$file"); then
        echo "check-workflow-line-limit: failed to analyze run: blocks in $file (awk exited non-zero)" >&2
        exit 1
    fi
    while IFS=$'\t' read -r block_line block_bytes; do
        [ -n "$block_line" ] || continue
        if [ "$block_bytes" -gt "$MAX_RUN_BLOCK_BYTES" ]; then
            run_block_offenders+=("$file:$block_line:$block_bytes")
        fi
    done <<< "$block_report"
done < <(find .github/workflows -maxdepth 1 -name '*.yml' -print0)

# What: Reports collected offenders and exits non-zero.
# Why: Single report shows all violations instead of one per push.
# From: Issue #1535 | PR #1575
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
    # What: Prints explanation for exceeded ceiling(s).
    # Why: CI reader needs fix direction; don't just list offenders.
    # From: Issue #1535 | PR #1575
    echo "" >&2
    echo "The line/byte limits exist because GitHub silently stops dispatching" >&2
    echo "pull_request runs for a workflow file that modifies itself past some" >&2
    echo "threshold above ~9000 lines / ~500KB (no error, no skipped conclusion --" >&2
    echo "the run is never created at all). The run: block limit exists because" >&2
    echo "actionlint's embedded shellcheck hangs indefinitely on a single run:" >&2
    echo "block above ~75440-75465 bytes, independent of overall file size. See" >&2
    echo "scripts/untracked/check-workflow-line-limit.sh's own header comment and issues" >&2
    echo "#1095 / #1535 for both reproductions. Split the file/block or trim its" >&2
    echo "comments rather than raising any of these limits." >&2
    exit 1
fi

echo "All .github/workflows/*.yml files are within the ${MAX_WORKFLOW_LINES}-line, ${MAX_WORKFLOW_BYTES}-byte, and ${MAX_RUN_BLOCK_BYTES}-byte-per-run-block hard limits."
