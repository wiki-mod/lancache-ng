#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Automated companion to AGENTS.md's AG-GH-017 (issue #990): a branch must be
# traceable in writing (a PR, or an issue comment/body naming it) at or near
# creation. The manual rule alone did not prevent recurrence -- 19
# bughunt-*/docs/inventory-* branches were pushed 2026-07-15 with genuine
# analysis work for issues #843/#849 and sat undiscovered for three days,
# invisible to anyone reading those issues, until someone happened to run
# `git branch -r` and cross-reference by hand. This script is the automated
# guard: it finds every remote branch older than 1 hour that has neither an
# associated pull request (open, closed, or merged) nor a written reference
# in any open issue, and reports it -- advisory only, never blocking (see the
# scheduled workflow this runs in, which posts findings as `::warning::`/
# `::notice::` annotations rather than failing a job; there is no PR here for
# a failure to gate).
#
# --- Design decisions and deviations from the issue's literal wording ------
#
# 1. Issue comments AND issue bodies are both searched, not comments alone.
#    A branch named directly in an issue's body (not just a follow-up
#    comment) is still "traceable in writing" per AG-GH-017's actual intent,
#    and searching both only *reduces* false "orphaned" reports -- the safe
#    direction for an advisory guard whose credibility depends on not crying
#    wolf on branches that genuinely are tracked.
#
# 2. Issue-reference matching uses REST enumeration (list open issues, list
#    each one's comments, grep the raw text), not the Search API the issue
#    text suggested as one option. The Search API has two properties that
#    make it actively worse for this job, not just a stricter rate limit:
#    indexing lag (a comment posted minutes ago may not be searchable yet)
#    and its tokenizer splitting on `/` and `-` (so a quoted search for
#    e.g. "feat/990-orphaned-branch-guard" can miss an exact raw-text
#    reference). Both failure modes return a clean 200 with too few results,
#    not an error -- so they would silently produce the corrosive failure
#    mode for a guard like this: a false "orphaned" flag on a branch that
#    IS tracked, which is exactly what would train people to ignore this
#    guard. REST enumeration (paginated, exact substring match against raw
#    text) is immune to both, costs one list call plus one comments call per
#    open issue (bounded, cheap at this repo's scale), and uses the 5000/hr
#    REST budget instead of the Search API's much stricter 30/min.
#
# 3. Branch exclusion uses an exact-name list (master, badges) plus a glob
#    pattern (v[0-9]*) for release branches, rather than hardcoding exactly
#    v0.1.0 and v0.2.0 -- matching gc-pr-staging-images.yml's own
#    `branches: [master, "v[0-9]*"]` convention and not silently missing a
#    future v0.3.0. `badges` is excluded because build-push.yml's
#    coverage-badge-publish job pushes directly to it as a legitimate,
#    intentionally-shared branch, not because it is genuinely untracked.
#
# --- Failure-mode policy ----------------------------------------------------
#
# A GitHub API call that cannot be resolved (network error, rate limit, an
# auth rejection on a *supplied* token) must never be treated as "so this
# branch has no PR / no issue reference" -- that would manufacture exactly
# the false-positive orphan flags this guard exists to avoid. Every lookup
# below distinguishes a confirmed answer from an ambiguous one (the same
# split gc-pr-staging-images.yml's pr_lookup_state uses) and an ambiguous
# branch is skipped with a warning, never reported as orphaned.
#
# --- Usage -------------------------------------------------------------------
#
# Accepts an optional repo_root argument (defaults to this script's own repo)
# so tests/bats/check_orphaned_branches.bats can point it at a fixture git
# tree instead of depending on the real repository -- same shape as
# check-action-node-versions.sh and check-executable-bits.sh.
#
# Required env: REPO (owner/name), GH_TOKEN or GITHUB_TOKEN (a token with
# default repo-scoped read access is sufficient -- issues:read and
# pull-requests:read, no project/PAT scope needed, unlike the project-board
# check in check-pr-tracking-metadata.sh).
#
# Optional env:
#   BRANCH_MIN_AGE_SECONDS   Age threshold in seconds (default 3600 / 1 hour,
#                            per the issue's explicit maintainer requirement).
#   REMOTE_NAME              Git remote to scan branches under (default origin).
#   REF_PREFIX               Ref namespace to enumerate (default
#                            refs/remotes/<REMOTE_NAME>); overridden by tests
#                            to refs/heads so they can use a plain local
#                            fixture repo with no real remote configured.
#   EXTRA_EXCLUDED_BRANCH_NAMES / EXTRA_EXCLUDED_BRANCH_PATTERNS
#                            Space-separated additions to the exact-name and
#                            glob-pattern exclusion lists, layered on top of
#                            (never replacing) the defaults above.
#   SLEEP_BETWEEN_CALLS     Seconds to sleep between per-branch PR-lookup API
#                            calls (default 0.2; set to 0 in tests). Mirrors
#                            this project's general "pace bulk GitHub API
#                            calls" convention rather than firing dozens of
#                            requests back to back.
#
# Runs inside the build-tools container in CI (per AG-VAL-016 -- jq and curl
# below must not be treated as guaranteed host-local tools), not directly on
# the runner. This project's established convention for hitting the GitHub
# API from a guard script is curl + GH_TOKEN, not the `gh` CLI (see
# check-pr-tracking-metadata.sh's header) -- the `gh` binary is not installed
# in the build-tools image this script runs inside in CI.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf '::error::check-orphaned-branches: %s is not a git work tree; cannot enumerate branches.\n' "$repo_root" >&2
  exit 1
fi

repo="${REPO:?REPO is required (owner/name)}"
owner="${repo%%/*}"
gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$gh_token" ]; then
  printf '::error::check-orphaned-branches: GH_TOKEN or GITHUB_TOKEN is required (a default repo-scoped token is sufficient; see this script'"'"'s header).\n' >&2
  exit 1
fi

min_age_seconds="${BRANCH_MIN_AGE_SECONDS:-3600}"
remote_name="${REMOTE_NAME:-origin}"
ref_prefix="${REF_PREFIX:-refs/remotes/${remote_name}}"
sleep_between_calls="${SLEEP_BETWEEN_CALLS:-0.2}"

# Exact-name and glob-pattern exclusions. Layering EXTRA_* on top of (never
# replacing) these defaults keeps master/badges/release-branches protected
# even if a caller only meant to widen the list, not narrow it.
excluded_names=(master badges)
excluded_patterns=('v[0-9]*')
if [ -n "${EXTRA_EXCLUDED_BRANCH_NAMES:-}" ]; then
  read -ra extra_names <<<"$EXTRA_EXCLUDED_BRANCH_NAMES"
  excluded_names+=("${extra_names[@]}")
fi
if [ -n "${EXTRA_EXCLUDED_BRANCH_PATTERNS:-}" ]; then
  read -ra extra_patterns <<<"$EXTRA_EXCLUDED_BRANCH_PATTERNS"
  excluded_patterns+=("${extra_patterns[@]}")
fi

is_excluded_branch() {
  local candidate="$1" name pattern
  for name in "${excluded_names[@]}"; do
    [ "$candidate" = "$name" ] && return 0
  done
  for pattern in "${excluded_patterns[@]}"; do
    # Deliberate unquoted glob match against $pattern (e.g. v[0-9]*), not a
    # literal string compare -- quoting it would defeat the whole point.
    # shellcheck disable=SC2053
    [[ "$candidate" == $pattern ]] && return 0
  done
  return 1
}

warnings=0
warn() {
  printf '::warning::%s\n' "$1" >&2
  warnings=$((warnings + 1))
}

# --- Step 1: enumerate remote branches and apply the age + exclusion gate --
#
# refs/remotes/<remote>/HEAD is a symbolic ref (points at whatever branch the
# remote's default is), not a real branch -- for-each-ref lists it alongside
# genuine branches under the same prefix, so it must be explicitly skipped or
# it would be evaluated (and potentially reported) as a phantom branch.
#
# The skip check is done against the FULL refname (%(refname), checked for a
# literal "/HEAD" suffix), never against %(refname:short) -- confirmed live
# against a real clone (git version shipped in this project's build-tools
# image) that refs/remotes/origin/HEAD's refname:short renders as the bare
# string "origin" (the remote name alone, no "/HEAD" suffix at all), not
# "origin/HEAD" as might be assumed. A short-name-based check (comparing the
# post-strip branch name to the literal string "HEAD") silently fails to
# catch that shape and lets a phantom branch literally named after the
# remote (e.g. "origin") through to the age/exclusion gate and beyond -- this
# was caught by an actual live run against the real repository's remote
# branches, not by this suite's own fixture test, which used a real remote
# clone but happened to mask the bug (the untested phantom name hit an
# unrelated unmocked-API fallback path instead of exercising this check).
now_epoch="$(date -u +%s)"
total_scanned=0        # every real branch under ref_prefix, before any filter
candidates=()          # branch names surviving the age + exclusion gate
declare -A commit_iso=()
declare -A commit_author=()

while IFS='|' read -r full_ref short_ref epoch iso author; do
  [ -n "$full_ref" ] || continue
  case "$full_ref" in
    */HEAD) continue ;;
  esac
  [ -n "$epoch" ] || continue
  branch="${short_ref#"${remote_name}"/}"
  total_scanned=$((total_scanned + 1))

  age=$((now_epoch - epoch))
  if [ "$age" -lt "$min_age_seconds" ]; then
    continue
  fi
  if is_excluded_branch "$branch"; then
    continue
  fi

  candidates+=("$branch")
  commit_iso["$branch"]="$iso"
  commit_author["$branch"]="$author"
done < <(git for-each-ref "$ref_prefix" --format='%(refname)|%(refname:short)|%(committerdate:unix)|%(committerdate:iso-strict)|%(authorname)')

if [ "${#candidates[@]}" -eq 0 ]; then
  printf 'check-orphaned-branches: OK (no remote branch older than %ss survives the exclusion list, out of %d scanned; nothing to check further).\n' "$min_age_seconds" "$total_scanned"
  exit 0
fi

# --- Step 2: drop any candidate with an open, closed, or merged PR ---------
#
# branch_has_pr prints HAS_PR, NO_PR, or LOOKUP_FAILED -- deliberately three
# states, not a boolean: an API call that could not be resolved (network
# error, rate limit, an auth rejection) must never collapse into "so it has
# no PR," which would manufacture a false orphan report for a branch this
# guard simply failed to check. Only a confirmed NO_PR (every page returned
# zero results) proceeds to the issue-reference check below.
branch_has_pr() {
  local branch="$1" page=1 max_pages=10 status count
  local response_file
  response_file="$(mktemp)"
  while [ "$page" -le "$max_pages" ]; do
    status=$(curl -sS -o "$response_file" -w '%{http_code}' \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/vnd.github+json" \
      -G \
      --data-urlencode "head=${owner}:${branch}" \
      --data-urlencode "state=all" \
      --data-urlencode "per_page=100" \
      --data-urlencode "page=${page}" \
      "https://api.github.com/repos/${repo}/pulls" 2>/dev/null) || status="000"
    if [ "$status" != "200" ]; then
      rm -f "$response_file"
      printf 'LOOKUP_FAILED:%s\n' "$status"
      return 0
    fi
    if ! count=$(jq 'length' <"$response_file" 2>/dev/null); then
      rm -f "$response_file"
      printf 'LOOKUP_FAILED:unparseable\n'
      return 0
    fi
    if [ "$count" -gt 0 ]; then
      rm -f "$response_file"
      printf 'HAS_PR\n'
      return 0
    fi
    if [ "$count" -lt 100 ]; then
      break
    fi
    page=$((page + 1))
  done
  rm -f "$response_file"
  printf 'NO_PR\n'
}

no_pr_candidates=()
for branch in "${candidates[@]}"; do
  result="$(branch_has_pr "$branch")"
  case "$result" in
    HAS_PR) ;;
    NO_PR) no_pr_candidates+=("$branch") ;;
    LOOKUP_FAILED:*)
      warn "check-orphaned-branches: could not determine whether branch '$branch' has a pull request (HTTP/parse: ${result#LOOKUP_FAILED:}) -- skipping it rather than risk a false orphan report."
      ;;
  esac
  sleep "$sleep_between_calls" 2>/dev/null || true
done

if [ "${#no_pr_candidates[@]}" -eq 0 ]; then
  printf 'check-orphaned-branches: OK (every branch old enough to check has an associated pull request).\n'
  exit 0
fi

# --- Step 3: build a text corpus of every open issue's body + comments -----
#
# Fetched once, up front, rather than per candidate branch: an O(issues) pass
# followed by a local substring search per branch is far cheaper than an
# O(candidates * issues) cross-product of API calls, and produces exactly
# the same result since the corpus doesn't depend on which branch is being
# checked.
corpus_file="$(mktemp)"
trap 'rm -f "$corpus_file"' EXIT

# issues_fetch_ok tracks whether the open-issues LISTING itself (not an
# individual issue's comments -- see the per-issue loop below) succeeded in
# full. A failure here means the corpus this script is about to build is
# incomplete in a way no per-branch check can detect or compensate for --
# every no_pr_candidates branch would risk a false "orphaned" verdict simply
# because this run couldn't see the issue that actually references it. That
# is a strictly worse outcome than reporting nothing this run, so a listing
# failure suppresses Step 4's orphan reporting entirely (still exits 0; the
# warning already emitted below is the signal something needs attention).
issues_fetch_ok=1

fetch_open_issue_numbers() {
  local page=1 max_pages=20 status body_file count
  body_file="$(mktemp)"
  while [ "$page" -le "$max_pages" ]; do
    status=$(curl -sS -o "$body_file" -w '%{http_code}' \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/vnd.github+json" \
      -G \
      --data-urlencode "state=open" \
      --data-urlencode "per_page=100" \
      --data-urlencode "page=${page}" \
      "https://api.github.com/repos/${repo}/issues" 2>/dev/null) || status="000"
    if [ "$status" != "200" ]; then
      rm -f "$body_file"
      warn "check-orphaned-branches: could not list open issues (page $page, HTTP $status) -- suppressing orphan reporting for this run rather than risk false positives from an incomplete issue corpus."
      issues_fetch_ok=0
      return 0
    fi
    # The /issues endpoint returns pull requests too; entries carrying a
    # `pull_request` key are PRs, not issues, and must be excluded here --
    # their existence was already checked directly in Step 2, and searching
    # PR bodies/comments for a branch name is not what AG-GH-017 asks for.
    if ! jq -c 'map(select(has("pull_request") | not)) | .[] | {number, body}' <"$body_file" >>"$corpus_file.issues" 2>/dev/null; then
      warn "check-orphaned-branches: could not parse the open-issues response (page $page) via jq -- suppressing orphan reporting for this run rather than risk false positives from an incomplete issue corpus."
      issues_fetch_ok=0
      rm -f "$body_file"
      return 0
    fi
    if ! count=$(jq 'length' <"$body_file" 2>/dev/null); then
      rm -f "$body_file"
      return 0
    fi
    rm -f "$body_file"
    if [ "$count" -lt 100 ]; then
      break
    fi
    page=$((page + 1))
  done
}

: >"$corpus_file.issues"
fetch_open_issue_numbers

if [ "$issues_fetch_ok" -eq 0 ]; then
  printf 'check-orphaned-branches: incomplete run -- open-issues listing failed, so orphan reporting was suppressed for %d branch(es) that had no PR (see the warning above).\n' "${#no_pr_candidates[@]}"
  exit 0
fi

if [ -s "$corpus_file.issues" ]; then
  while IFS= read -r issue_entry; do
    [ -n "$issue_entry" ] || continue
    issue_number="$(printf '%s' "$issue_entry" | jq -r '.number')"
    issue_body="$(printf '%s' "$issue_entry" | jq -r '.body // empty')"
    printf '%s\n' "$issue_body" >>"$corpus_file"

    page=1
    max_pages=20
    while [ "$page" -le "$max_pages" ]; do
      comments_file="$(mktemp)"
      status=$(curl -sS -o "$comments_file" -w '%{http_code}' \
        -H "Authorization: Bearer ${gh_token}" \
        -H "Accept: application/vnd.github+json" \
        -G \
        --data-urlencode "per_page=100" \
        --data-urlencode "page=${page}" \
        "https://api.github.com/repos/${repo}/issues/${issue_number}/comments" 2>/dev/null) || status="000"
      if [ "$status" != "200" ]; then
        warn "check-orphaned-branches: could not list comments for issue #$issue_number (page $page, HTTP $status) -- issue-reference matching may be incomplete for this run."
        rm -f "$comments_file"
        break
      fi
      jq -r '.[].body // empty' <"$comments_file" >>"$corpus_file" 2>/dev/null || true
      comment_count="$(jq 'length' <"$comments_file" 2>/dev/null || echo 0)"
      rm -f "$comments_file"
      if [ "$comment_count" -lt 100 ]; then
        break
      fi
      page=$((page + 1))
    done
  done <"$corpus_file.issues"
fi
rm -f "$corpus_file.issues"

# --- Step 4: report any branch not found anywhere in the corpus -----------
orphaned=()
for branch in "${no_pr_candidates[@]}"; do
  if grep -qF -- "$branch" "$corpus_file"; then
    continue
  fi
  orphaned+=("$branch")
done

if [ "${#orphaned[@]}" -eq 0 ]; then
  printf 'check-orphaned-branches: OK (%d branch(es) had no PR but every one is referenced in an open issue'"'"'s body or comments).\n' "${#no_pr_candidates[@]}"
  exit 0
fi

for branch in "${orphaned[@]}"; do
  warn "Orphaned branch detected: '${branch}' (last commit ${commit_iso[$branch]:-unknown} by ${commit_author[$branch]:-unknown}) -- no open/closed/merged pull request and no open-issue body/comment reference found. Per AG-GH-017 (#990), this branch must either get a pull request or a comment on a linked issue naming it and its purpose, or be flagged for deletion by the maintainer."
done

printf '::notice::check-orphaned-branches: %d orphaned branch(es) found out of %d candidate(s) checked (%d total remote branch(es) scanned). This is advisory only and does not fail this run.\n' \
  "${#orphaned[@]}" "${#candidates[@]}" "$total_scanned"
exit 0
