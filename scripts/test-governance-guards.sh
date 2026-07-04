#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Runs fixture-style checks for scripts/check-governance-guards.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="${ROOT_DIR}/scripts/check-governance-guards.sh"

fail() {
  printf 'test-governance-guards: %s\n' "$1" >&2
  exit 1
}

expect_success() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    fail "$name: expected success"
  fi
}

expect_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name: expected failure"
  fi
}

make_fixture() {
  local repo_dir="$1" fixture_path
  shift
  mkdir -p "$repo_dir"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture path requires a value"
        mkdir -p "$repo_dir/$(dirname "$1")"
        fixture_path="$repo_dir/$1"
        ;;
      --content)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture content requires a value"
        printf '%s\n' "$1" > "$fixture_path"
        ;;
      --changed)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture changed file requires a value"
        printf '%s\n' "$1" >> "$repo_dir/changed-files.txt"
        ;;
      --state)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture state requires a value"
        printf '%s\n' "$1" >> "$repo_dir/issue-state.txt"
        ;;
      --title)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture title requires a value"
        printf '%s' "$1" > "$repo_dir/pr-title.txt"
        ;;
      --body)
        shift
        [[ $# -gt 0 && "$1" != --* ]] || fail "fixture body requires a value"
        printf '%s' "$1" > "$repo_dir/pr-body.txt"
        ;;
      *)
        fail "unknown fixture option: $1"
        ;;
    esac
    shift
  done
}

run_checker() {
  local repo_dir="$1"
  shift
  env \
    GOVERNANCE_PR_TITLE="$(cat "$repo_dir/pr-title.txt" 2>/dev/null || true)" \
    GOVERNANCE_PR_BODY="$(cat "$repo_dir/pr-body.txt" 2>/dev/null || true)" \
    bash "$CHECKER" \
    --repo-root "$repo_dir" \
    --changed-files-file "$repo_dir/changed-files.txt" \
    --issue-state-file "$repo_dir/issue-state.txt" \
    "$@"
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/repo"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"

closed_marker="# TO""DO(#999001): stale marker"
make_fixture "$repo" \
  --path "setup.sh" --content "$closed_marker" \
  --changed "setup.sh" \
  --state "999001=closed"
expect_failure "closed TODO marker" run_checker "$repo"

repo="$tmp_root/repo-open"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"
open_marker="# TO""DO(#999002): tracked follow-up"
make_fixture "$repo" \
  --path "setup.sh" --content "$open_marker" \
  --changed "setup.sh" \
  --state "999002=open"
expect_success "open TODO marker" run_checker "$repo"

repo="$tmp_root/repo-partial-fail"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"
make_fixture "$repo" \
  --title "scaffold: partial fix" \
  --body $'Refs #439\nFixes #123\nThis is a partial scaffold.'
expect_failure "partial fix without open remainder" run_checker "$repo"

repo="$tmp_root/repo-partial-pass"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"
make_fixture "$repo" \
  --title "scaffold: partial fix" \
  --body $'Refs #440\nFixes #123\nThis is a partial scaffold.' \
  --state "440=open"
expect_success "partial fix with open remainder" run_checker "$repo"

repo="$tmp_root/repo-json"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"
make_fixture "$repo" \
  --body '"Refs #440\\nFixes #123\\npartial scope"' \
  --state "440=open"
expect_failure "json quoted body" run_checker "$repo"

repo="$tmp_root/repo-at-path"
mkdir -p "$repo"
: > "$repo/changed-files.txt"
: > "$repo/issue-state.txt"
: > "$repo/pr-title.txt"
: > "$repo/pr-body.txt"
make_fixture "$repo" \
  --body '@/tmp/PR_BODY.txt'
expect_failure "literal tmp upload body" run_checker "$repo"

printf 'governance guard fixtures passed\n'
