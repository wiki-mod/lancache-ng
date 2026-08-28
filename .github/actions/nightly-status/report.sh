#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: file, update, or close standing issue by LABEL.
# Why: reuses same issue across failures, closes on success.
# From: Issue #1095

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${REPO:?REPO required}"
: "${OUTCOME:?OUTCOME required (success|failure)}"
: "${SCOPE:?SCOPE required, e.g. 'nightly channel promote'}"
: "${RUN_URL:?RUN_URL required}"
LABEL="${LABEL:-nightly-broken}"
DRY_RUN="${DRY_RUN:-false}"
FAILED_JOBS="${FAILED_JOBS:-}"
PROJECT_PAT="${PROJECT_PAT:-}"
# What: KANBAN board URL for add-to-project webhook.
# Why: manual sync required; update both if board changes.
# From: Issue #1095
PROJECT_OWNER="${PROJECT_OWNER:-wiki-mod}"
PROJECT_NUMBER="${PROJECT_NUMBER:-6}"

# What: add standing issue to project board.
# Why: GH_TOKEN suppresses issues:opened webhook.
# From: Issue #1095
add_to_project_board() {
  local issue_url="$1"
  if [ -z "${PROJECT_PAT}" ]; then
    echo "::warning::PROJECT_PAT not configured; ${issue_url} was not added to the project board."
    return 0
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY_RUN would run: GH_TOKEN=*** gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url ${issue_url}"
    return 0
  fi
  GH_TOKEN="${PROJECT_PAT}" gh project item-add "${PROJECT_NUMBER}" \
    --owner "${PROJECT_OWNER}" --url "${issue_url}" >/dev/null
}

# What: echo command instead of running it when DRY_RUN=true.
# Why: exercise branch logic locally without side effects.
# From: Issue #1095
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    printf 'DRY_RUN would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# What: assign "Bug" issue type to argument if needed.
# Why: every failure path ensures correct type.
# From: Issue #1095
ensure_bug_type() {
  local issue_number="$1" owner name issue_query_result issue_node_id current_type bug_type_id
  owner="${REPO%%/*}"
  name="${REPO##*/}"
  # shellcheck disable=SC2016
  issue_query_result="$(gh api graphql -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) { id issueType { name } }
      }
    }' -F owner="${owner}" -F name="${name}" -F number="${issue_number}" \
    --jq '.data.repository.issue | .id + " " + (.issueType.name // "-")')"
  read -r issue_node_id current_type <<<"${issue_query_result}"
  if [ "${current_type}" != "-" ]; then
    return 0
  fi
  # shellcheck disable=SC2016
  bug_type_id="$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        issueTypes(first: 20) { nodes { id name } }
      }
    }' -F owner="${owner}" -F name="${name}" \
    --jq '.data.repository.issueTypes.nodes[] | select(.name == "Bug") | .id')"
  if [ -z "${bug_type_id}" ]; then
    echo "::error::No 'Bug' issue type configured for ${REPO}; cannot type issue #${issue_number}."
    return 1
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY_RUN would run: assign Bug type to issue #${issue_number}"
    return 0
  fi
  # shellcheck disable=SC2016
  gh api graphql -f query='
    mutation($issueId: ID!, $typeId: ID!) {
      updateIssue(input: {id: $issueId, issueTypeId: $typeId}) {
        issue { id }
      }
    }' -F issueId="${issue_node_id}" -F typeId="${bug_type_id}" >/dev/null
}

# What: find oldest open standing issue for this label.
# Why: --jq avoids SIGPIPE-prone pipe chains.
# From: Issue #1095
existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
  --json number --jq 'sort_by(.number) | .[0].number // empty')"

if [ "${OUTCOME}" = "success" ]; then
  if [ -n "${existing}" ]; then
    ensure_bug_type "${existing}"
    add_to_project_board "https://github.com/${REPO}/issues/${existing}"
    echo "success: closing standing ${LABEL} issue #${existing}"
    run gh issue comment "${existing}" --repo "${REPO}" \
      --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if this check fails again."
    run gh issue close "${existing}" --repo "${REPO}"
  else
    echo "success and no open ${LABEL} issue: nothing to do"
  fi
  exit 0
fi

# What: ensure label exists before reusing or opening issue.
# Why: truncated to 100 chars; GitHub's hard limit.
# From: Issue #1095
label_description="Recurring, self-closing tracking issue: ${SCOPE}"
run gh label create "${LABEL}" --repo "${REPO}" --color b60205 \
  --description "${label_description:0:100}" 2>/dev/null || true

detail="${SCOPE} failed in ${RUN_URL}"
if [ -n "${FAILED_JOBS}" ]; then
  detail="${detail} (failed: ${FAILED_JOBS})"
fi
if [ -n "${existing}" ]; then
  echo "failure: commenting on standing ${LABEL} issue #${existing}"
  run gh issue comment "${existing}" --repo "${REPO}" \
    --body "Still failing: ${detail}."
  ensure_bug_type "${existing}"
  add_to_project_board "https://github.com/${REPO}/issues/${existing}"
else
  echo "failure: opening a new standing ${LABEL} issue"
  new_issue_url="$(run gh issue create --repo "${REPO}" --label "${LABEL}" \
    --title "[${LABEL}] ${SCOPE}" \
    --body "This standing issue is reused across consecutive failures of this check and closed automatically on the next success.

${detail}.")"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "${new_issue_url}"
    echo "DRY_RUN would run: assign Bug type to the newly created issue"
    if [ -z "${PROJECT_PAT}" ]; then
      echo "::warning::PROJECT_PAT not configured; the newly created issue would not be added to the project board."
    else
      echo "DRY_RUN would run: GH_TOKEN=*** gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url <newly created issue URL>"
    fi
  fi
  if [ "${DRY_RUN}" != "true" ]; then
    ensure_bug_type "${new_issue_url##*/}"
    add_to_project_board "${new_issue_url}"
  fi
fi
