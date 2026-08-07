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
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

MAX_WORKFLOW_LINES="${MAX_WORKFLOW_LINES:-8999}"
MAX_WORKFLOW_BYTES="${MAX_WORKFLOW_BYTES:-512000}"

line_offenders=()
byte_offenders=()
while IFS= read -r -d '' file; do
    lines=$(wc -l < "$file")
    bytes=$(wc -c < "$file")
    if [ "$lines" -gt "$MAX_WORKFLOW_LINES" ]; then
        line_offenders+=("$file:$lines")
    fi
    if [ "$bytes" -gt "$MAX_WORKFLOW_BYTES" ]; then
        byte_offenders+=("$file:$bytes")
    fi
done < <(find .github/workflows -maxdepth 1 -name '*.yml' -print0)

if [ "${#line_offenders[@]}" -gt 0 ] || [ "${#byte_offenders[@]}" -gt 0 ]; then
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
    echo "" >&2
    echo "This limit exists because GitHub silently stops dispatching pull_request" >&2
    echo "runs for a workflow file that modifies itself past some threshold above" >&2
    echo "~9000 lines / ~500KB (no error, no skipped conclusion -- the run is never" >&2
    echo "created at all). See scripts/check-workflow-line-limit.sh's own header" >&2
    echo "comment and issue #1095 for the reproduction. Split the file or trim its" >&2
    echo "comments rather than raising either limit." >&2
    exit 1
fi

echo "All .github/workflows/*.yml files are within the ${MAX_WORKFLOW_LINES}-line and ${MAX_WORKFLOW_BYTES}-byte hard limits."
