#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Checks changed files and PR bodies for stale TODO/FIXME markers, partial
# Fixes/Closes claims, and malformed PR-body uploads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

REPO_ROOT=""
CHANGED_FILES_FILE=""
ISSUE_STATE_FILE=""
PR_TITLE="${GOVERNANCE_PR_TITLE:-${PR_TITLE:-}}"
PR_BODY="${GOVERNANCE_PR_BODY:-${PR_BODY:-}}"

declare -A ISSUE_STATE_CACHE=()

usage() {
  cat <<'EOF'
Usage: check-governance-guards.sh [options]

Options:
  --repo-root FILE           Repository root to inspect. Defaults to the current Git repository root.
  --changed-files-file FILE  Newline-separated list of changed paths, relative to the repository root.
  --issue-state-file FILE    Fixture file with lines like "123=open" or "123=closed".
  -h, --help                 Show this help.

Environment:
  GOVERNANCE_PR_TITLE / PR_TITLE   PR title text to inspect for scaffold and partial-scope claims.
  GOVERNANCE_PR_BODY / PR_BODY     PR body text to inspect for Fixes/Closes and partial-scope claims.
  GITHUB_REPOSITORY                Repository name in owner/name form for live GitHub issue lookups.
  GITHUB_TOKEN / GH_TOKEN          Optional token for live GitHub issue lookups.
  GOVERNANCE_BASE_SHA              Optional base SHA for auto-detecting changed files when no file list is provided.
  GOVERNANCE_HEAD_SHA              Optional head SHA for auto-detecting changed files when no file list is provided.
EOF
}

fail() {
  printf 'governance-guards: %s\n' "$1" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_issue_state_fixtures() {
  local line issue state

  [[ -n "$ISSUE_STATE_FILE" ]] || return 0
  [[ -f "$ISSUE_STATE_FILE" ]] || fail "issue state fixture file not found: $ISSUE_STATE_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" != \#* ]] || continue

    case "$line" in
      *=*)
        issue="${line%%=*}"
        state="${line#*=}"
        ;;
      *)
        fail "invalid issue state fixture line: $line"
        ;;
    esac

    issue="$(trim "$issue")"
    state="$(trim "$state")"
    [[ "$issue" =~ ^[0-9]+$ ]] || fail "invalid issue number in fixture: $issue"
    case "$state" in
      open|closed)
        ISSUE_STATE_CACHE["$issue"]="$state"
        ;;
      *)
        fail "invalid issue state for #$issue: $state"
        ;;
    esac
  done < "$ISSUE_STATE_FILE"
}

query_live_issue_state() {
  local issue="$1" url response state token_headers=()

  [[ -n "${GITHUB_REPOSITORY:-}" ]] || fail "GITHUB_REPOSITORY is required for live issue lookups"
  url="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue}"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    token_headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    token_headers=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi

  if ! response="$(curl -fsS -H 'Accept: application/vnd.github+json' "${token_headers[@]}" "$url")"; then
    fail "could not fetch GitHub issue state for #$issue"
  fi

  state="$(jq -r '.state // empty' <<<"$response")"
  [[ -n "$state" ]] || fail "GitHub API response for #$issue did not include a state"
  printf '%s\n' "$state"
}

issue_state() {
  local issue="$1"

  if [[ -n "${ISSUE_STATE_CACHE[$issue]:-}" ]]; then
    printf '%s\n' "${ISSUE_STATE_CACHE[$issue]}"
    return 0
  fi

  if [[ -n "$ISSUE_STATE_FILE" ]]; then
    fail "missing issue state fixture for #$issue"
  fi

  local state
  state="$(query_live_issue_state "$issue")"
  ISSUE_STATE_CACHE["$issue"]="$state"
  printf '%s\n' "$state"
}

should_scan_file() {
  case "$1" in
    *.md|*.mdx|*.rst|*.txt)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

collect_changed_files() {
  local path

  if [[ -n "$CHANGED_FILES_FILE" ]]; then
    [[ -f "$CHANGED_FILES_FILE" ]] || fail "changed files list not found: $CHANGED_FILES_FILE"
    while IFS= read -r path || [[ -n "$path" ]]; do
      path="$(trim "$path")"
      [[ -n "$path" ]] || continue
      printf '%s\n' "$path"
    done < "$CHANGED_FILES_FILE"
    return 0
  fi

  if [[ -n "${GOVERNANCE_BASE_SHA:-}" && -n "${GOVERNANCE_HEAD_SHA:-}" ]]; then
    git -C "$ROOT_DIR" diff --name-only --diff-filter=ACMRTUXB "$GOVERNANCE_BASE_SHA" "$GOVERNANCE_HEAD_SHA"
    return 0
  fi

  fail "provide --changed-files-file or GOVERNANCE_BASE_SHA/GOVERNANCE_HEAD_SHA"
}

scan_changed_files_for_todos() {
  local path line issue marker state

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    should_scan_file "$path" || continue
    [[ -f "$ROOT_DIR/$path" ]] || continue

    while IFS= read -r marker || [[ -n "$marker" ]]; do
      line="${marker%%:*}"
      marker="${marker#*:}"
      issue="${marker##*#}"
      issue="${issue%)*}"
      [[ "$issue" =~ ^[0-9]+$ ]] || continue

      state="$(issue_state "$issue")"
      if [[ "$state" == "closed" ]]; then
        fail "stale TODO/FIXME marker at ${path}:${line} references closed issue #${issue}"
      fi
    done < <(grep -nEo '(TODO|FIXME)\(#([0-9]+)\)' "$ROOT_DIR/$path" || true)
  done < <(collect_changed_files)
}

extract_issue_numbers() {
  local pattern="$1" text="$2" match issue

  while IFS= read -r match || [[ -n "$match" ]]; do
    issue="${match##*#}"
    issue="${issue%)*}"
    [[ "$issue" =~ ^[0-9]+$ ]] || continue
    printf '%s\n' "$issue"
  done < <(grep -oE "$pattern" <<<"$text" || true)
}

contains_partial_scope_language() {
  local text="$1"
  grep -Eiq '(^|[^[:alnum:]])(scaffold|TODO|deferred|not covered|not implemented|partial|follow-up required)([^[:alnum:]]|$)' <<<"$text"
}

contains_malformed_body_upload() {
  local body="$1"

  if grep -Eq '(^|[[:space:]])@/tmp/[^[:space:]]+' <<<"$body"; then
    return 0
  fi

  if [[ "$body" == \"*\" && "$body" == *'\\n'* && "$body" != *$'\n'* ]]; then
    return 0
  fi

  return 1
}

check_pr_body() {
  local text="$1" open_remainder_found=0 issue state

  if contains_malformed_body_upload "$text"; then
    fail "PR body looks like a literal file path upload or JSON-quoted Markdown instead of the intended body text"
  fi

  if ! contains_partial_scope_language "$text"; then
    return 0
  fi

  while IFS= read -r issue || [[ -n "$issue" ]]; do
    [[ -n "$issue" ]] || continue
    state="$(issue_state "$issue")"
    if [[ "$state" == "open" ]]; then
      open_remainder_found=1
      break
    fi
  done < <(extract_issue_numbers '(Refs[[:space:]]+#([0-9]+))' "$text")

  if [[ "$open_remainder_found" -eq 0 ]]; then
    fail "partial-scope PR text must name an open remainder issue with Refs #... before merge"
  fi
}

main() {
  local path combined_text

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "--repo-root requires a value"
        REPO_ROOT="$1"
        ;;
      --changed-files-file)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "--changed-files-file requires a value"
        CHANGED_FILES_FILE="$1"
        ;;
      --issue-state-file)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "--issue-state-file requires a value"
        ISSUE_STATE_FILE="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
      ;;
    esac
    shift
  done

  if [[ -n "$REPO_ROOT" ]]; then
    ROOT_DIR="$REPO_ROOT"
  fi

  load_issue_state_fixtures
  scan_changed_files_for_todos

  combined_text="${PR_TITLE}"
  if [[ -n "$combined_text" && -n "$PR_BODY" ]]; then
    combined_text+=$'\n'
  fi
  combined_text+="${PR_BODY}"

  if [[ -n "$combined_text" ]]; then
    check_pr_body "$combined_text"
  fi
}

main "$@"
