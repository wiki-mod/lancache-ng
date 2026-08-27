#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: enforces AG-CI-021's three .github/workflows/*.yml size ceilings.
# Why: GitHub silently drops pull_request runs above a whole-file
# byte/line threshold, and actionlint's embedded shellcheck hangs above a
# separate per-run:-block byte threshold; both are bisected, not invented.
# From: Issue #1095 | Issue #1535
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# What: whole-file line ceiling.
# Why: GitHub creates zero pull_request runs for a self-modifying workflow
# file above ~9000 lines; 8999 is the maintainer's own bisected reference.
# From: Issue #1095
MAX_WORKFLOW_LINES="${MAX_WORKFLOW_LINES:-8999}"

# What: whole-file byte ceiling, independent of MAX_WORKFLOW_LINES.
# Why: tracks the same GitHub dispatch cliff for a file whose line lengths
# differ from the bisected reference file's.
# From: Issue #1095
MAX_WORKFLOW_BYTES="${MAX_WORKFLOW_BYTES:-512000}"

# What: per-run:-block byte ceiling, a distinct dimension from the two above.
# Why: actionlint's embedded shellcheck hangs on a single run: block above
# ~75440-75465 bytes, independent of whole-file size.
# From: Issue #1535
MAX_RUN_BLOCK_BYTES="${MAX_RUN_BLOCK_BYTES:-74000}"

# What: extracts each run: block-scalar's byte span as <line>\t<bytes>.
# Why: a shared function avoids re-deriving the indentation walk at each
# call site (AG-CODE-011/AG-CODE-013 reuse point).
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
            # What: also resets started, not just in_block.
            # Why: leaving started=1 after a mid-file flush makes the
            # trailing END block call flush_block() a second time.
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
                # What: flushes the block, then re-checks this same line as
                # a possible new header.
                # Why: indentation dropped to/below the parent level, so
                # the block scalar ended here.
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
                # What: uses a fixed content indent when an explicit digit
                # indicator is present, instead of auto-detecting it.
                # Why: an all-blank-first-lines block would otherwise be
                # mis-detected as empty.
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

# What: collects every offending .github/workflows/*.yml file/block across
# all three ceilings above, one pass per file.
# Why: a single loop keeps the three independent checks (line count, byte
# count, run: block bytes) applied consistently to the same file list.
# From: Issue #1095 | Issue #1535
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
    # What: captures measure_run_blocks output into a variable, checked
    # for a non-zero exit, before consuming it via a here-string.
    # Why: a process-substitution failure is invisible to set -e; feeding
    # the loop directly would silently report zero blocks (AG-INT-002).
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

# What: reports every collected offender, then exits non-zero.
# Why: a single combined report (rather than exiting on the first hit)
# lets one CI run show every violation instead of one per push.
# From: Issue #1095 | Issue #1535
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
    # What: prints one human-readable explanation for whichever ceiling(s)
    # were exceeded above.
    # Why: a CI reader needs the fix direction (split, don't raise the
    # limit), not just a bare offender list.
    # From: Issue #1095 | Issue #1535
    echo "" >&2
    echo "The line/byte limits exist because GitHub silently stops dispatching" >&2
    echo "pull_request runs for a workflow file that modifies itself past some" >&2
    echo "threshold above ~9000 lines / ~500KB (no error, no skipped conclusion --" >&2
    echo "the run is never created at all). The run: block limit exists because" >&2
    echo "actionlint's embedded shellcheck hangs indefinitely on a single run:" >&2
    echo "block above ~75440-75465 bytes, independent of overall file size. See" >&2
    echo "scripts/tracked/check-workflow-line-limit.sh's own header comment and issues" >&2
    echo "#1095 / #1535 for both reproductions. Split the file/block or trim its" >&2
    echo "comments rather than raising any of these limits." >&2
    exit 1
fi

echo "All .github/workflows/*.yml files are within the ${MAX_WORKFLOW_LINES}-line, ${MAX_WORKFLOW_BYTES}-byte, and ${MAX_RUN_BLOCK_BYTES}-byte-per-run-block hard limits."
