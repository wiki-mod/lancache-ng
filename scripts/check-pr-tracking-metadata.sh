#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Enforces AGENTS.md's AG-GH-008: a pull request must carry at least one
# label and a milestone, and (when a project-read token is configured)
# must be on the repository's Project board, before it counts as properly
# filed. See AGENTS.md's "Issue And PR Tracking" section for the rule text
# and its Enforcement Notes for why this exists as CI, not just a written
# rule -- a 2026-07-13 backlog sweep found nearly the entire open PR
# backlog missing all three fields despite otherwise-correct content.
#
# For draft PRs: prints warnings but exits 0 (non-blocking), matching
# validate-pr-template.sh's draft handling -- metadata is expected to
# settle before a PR leaves draft, not before the first push.
#
# Usage (CI):
#   PR_LABELS_JSON, PR_MILESTONE_TITLE, PR_DRAFT, PR_NUMBER, REPO set by
#   the workflow from github.event.pull_request.* context (no API call
#   needed for labels/milestone -- they're already in the webhook payload).
#   PROJECT_NUMBER, PROJECT_OWNER identify the project board to check.
#   GH_TOKEN, if set to a token with read:project scope, enables the
#   project-board check via a raw GraphQL call against api.github.com
#   (curl, matching this repo's existing GitHub API convention -- see the
#   release-notes update step in build-push.yml -- rather than depending on
#   the `gh` CLI being present on the runner). The default Actions
#   GITHUB_TOKEN cannot read Projects v2 data (same constraint documented
#   in gc-pr-staging-images.yml for GHCR_PACKAGE_DELETE_PAT), so without
#   a configured token this check is skipped with a warning, not failed.
#
# Runs inside the build-tools container in CI (per AG-VAL-016 -- python3
# and curl below must not be host-local tools), not directly on the runner;
# see the pr-tracking-metadata-check job in build-push.yml.
set -euo pipefail

pr_draft="${PR_DRAFT:-false}"
pr_number="${PR_NUMBER:?PR_NUMBER is required}"
repo="${REPO:?REPO is required (owner/name)}"
project_number="${PROJECT_NUMBER:-6}"
project_owner="${PROJECT_OWNER:-wiki-mod}"

errors=()
warnings=()

# --- Labels ---------------------------------------------------------------
label_count=$(printf '%s' "${PR_LABELS_JSON:-[]}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [ "$label_count" -eq 0 ]; then
    errors+=("No labels set. Add at least one component/type label (see AG-GH-008).")
fi

# --- Milestone --------------------------------------------------------------
if [ -z "${PR_MILESTONE_TITLE:-}" ]; then
    errors+=("No milestone set. Set a milestone (see AG-GH-008).")
fi

# --- Project board ----------------------------------------------------------
# Projects v2 read access needs a token with read:project scope; the default
# GITHUB_TOKEN issued to a workflow run cannot query it. Degrade gracefully
# rather than failing every PR check on an org-level permission gap that has
# nothing to do with the PR itself.
if [ -z "${GH_TOKEN:-}" ]; then
    warnings+=("Project-board membership not checked: no read:project-scoped token configured (GH_TOKEN unset). See AGENTS.md AG-GH-008 enforcement notes.")
else
    repo_name="${repo#*/}"
    query=$(python3 -c '
import json
q = """
query($owner: String!, $pr: Int!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      projectItems(first: 10) {
        nodes { project { number } }
      }
    }
  }
}
"""
print(json.dumps({"query": q, "variables": {"owner": "'"$project_owner"'", "pr": '"$pr_number"', "repo": "'"$repo_name"'"}}))
')
    response_file="$(mktemp)"
    status=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$query" \
        "https://api.github.com/graphql") || status="000"
    if [ "$status" != "200" ]; then
        warnings+=("Could not query project-board membership (HTTP $status) -- not failing the check on an infrastructure issue, but this should be investigated.")
    else
        # Read the response over stdin rather than having Python open
        # $response_file itself: bash's mktemp path and a separately
        # invoked Python interpreter can disagree about path translation
        # (confirmed locally under Git Bash on Windows, where MSYS's
        # /tmp/... isn't the same filesystem view native Python sees) --
        # piping keeps path resolution entirely inside the shell that
        # already wrote the file.
        project_item_count=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    nodes = d['data']['repository']['pullRequest']['projectItems']['nodes']
    print(sum(1 for n in nodes if n['project']['number'] == $project_number))
except Exception:
    print('')
" < "$response_file")
        if [ -z "$project_item_count" ]; then
            warnings+=("Could not parse project-board membership response -- not failing the check on an infrastructure issue, but this should be investigated.")
        elif [ "$project_item_count" -eq 0 ]; then
            errors+=("Not on project board #$project_number ($project_owner). Add it with: gh project item-add $project_number --owner $project_owner --url <pr-url> (see AG-GH-008).")
        fi
    fi
    rm -f "$response_file"
fi

for w in "${warnings[@]:-}"; do
    [ -n "$w" ] && echo "::warning::$w" >&2
done

if [ "${#errors[@]}" -eq 0 ]; then
    echo "PR tracking metadata check passed: labels, milestone$( [ -n "${GH_TOKEN:-}" ] && echo ", and project board" ) are set."
    exit 0
fi

error_message="PR tracking metadata check failed (AG-GH-008):"
for e in "${errors[@]}"; do
    error_message="$error_message"$'\n'"  - $e"
done

if [ "$pr_draft" = "true" ]; then
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "This is a draft PR, so this check is non-blocking. Set these before marking ready for review." >&2
    exit 0
else
    echo "::error::$error_message" >&2
    exit 1
fi
