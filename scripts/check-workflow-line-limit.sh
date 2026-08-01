#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

MAX_WORKFLOW_LINES="${MAX_WORKFLOW_LINES:-8999}"

offenders=()
while IFS= read -r -d '' file; do
    lines=$(wc -l < "$file")
    if [ "$lines" -gt "$MAX_WORKFLOW_LINES" ]; then
        offenders+=("$file:$lines")
    fi
done < <(find .github/workflows -maxdepth 1 -name '*.yml' -print0)

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "Workflow file(s) over the ${MAX_WORKFLOW_LINES}-line hard limit:" >&2
    for entry in "${offenders[@]}"; do
        echo "  ${entry%:*} (${entry##*:} lines)" >&2
    done
    echo "" >&2
    echo "This limit exists because GitHub silently stops dispatching pull_request" >&2
    echo "runs for a workflow file that modifies itself past some threshold above" >&2
    echo "~9000 lines (no error, no skipped conclusion -- the run is never created" >&2
    echo "at all). See scripts/check-workflow-line-limit.sh's own header comment" >&2
    echo "and issue #1095 for the reproduction. Split the file or trim its" >&2
    echo "comments rather than raising this limit." >&2
    exit 1
fi

echo "All .github/workflows/*.yml files are within the ${MAX_WORKFLOW_LINES}-line hard limit."
