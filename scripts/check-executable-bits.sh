#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Standing guard for issue #1019 (#822 Pattern B): a repo script committed
# with git mode 100644 but invoked as a *bare path* (e.g. `scripts/foo.sh`,
# not `bash scripts/foo.sh`) fails at runtime with `Permission denied` /
# exit 126. This defect is invisible from a Windows / core.filemode=false
# authoring host (Rule-Ref: AG-VAL-024) -- `chmod +x` is a no-op there and no
# local check reveals the committed mode -- so it has recurred at least four
# times (#617 ui-nats-dns-integration-simulation.sh, #711 nats-secondary-
# auth-callout-simulation.sh, PR #804's own check-action-node-versions.sh /
# .githooks/pre-push incident) and, until this guard, had no systemic
# protection: only a single hardcoded `test -x services/watchdog/watchdog.sh`
# existed in build-push.yml.
#
# This script parses every workflow and composite-action file for script
# invocations, flags the ones that execute a repo script by a *bare path*
# (no `bash`/`sh`/`.`/`source` interpreter prefix -- those read the file and
# do not need the executable bit), and asserts each such file's *committed*
# git mode is 100755. The committed mode (`git ls-tree HEAD`) is what matters,
# not the checkout's filesystem mode: CI checks the repo out from git, so the
# mode stored in the tree is exactly what a bare invocation will get, and it
# is the only mode that is meaningful on a core.filemode=false author host.
#
# It additionally requires every tracked file under `.githooks/` to be
# executable, because git runs a hook by bare path unconditionally (a
# non-executable hook is silently skipped or errors) -- this is the
# `.githooks/pre-push` half of PR #804's own incident, which a workflow-only
# scan would miss. PR #804's other half -- a bats suite invoking its
# script-under-test bare via `run "$script"` -- is already self-guarding:
# those suites run in CI via `bats tests/bats`, where a non-executable
# script-under-test fails with exit 126, so the regression surfaces there
# rather than needing to be re-derived here.
#
# Modeled on scripts/check-action-node-versions.sh (issue #801/#804), the
# `scripts/check-*.sh` + CI-job template #822's own Pattern H names for
# converting a recurring whack-a-mole into an impossible-to-reintroduce class.
#
# Deliberately implemented in plain bash string/glob/`case` matching rather
# than a YAML parser (this project depends on neither a YAML library nor a
# non-shell runtime for its guards -- Rule-Ref: AG-REL-001) and rather than a
# PCRE grep (check-idempotence-test-coverage.sh's own header documents that
# both PCRE grep and a POSIX-awk rewrite misbehaved on this project's actual
# self-hosted runners).
#
# Known, deliberate scope limits (a safety net for the common shape, not a
# proof of universal coverage -- Rule-Ref: AG-VAL-024 still governs how new
# scripts should be *written*, via explicit-interpreter invocation):
#   - Only repo-root-relative paths under scripts/, services/, tests/, or
#     .githooks/ are recognized. A `../`-relative invocation (from a step's
#     `working-directory:`) or a `$VAR`-interpolated script path is not
#     resolved. This matches how the sibling workflow-parsing guards scope
#     themselves.
#   - A path passed as a data *argument* to another command (`cat
#     scripts/x.sh`, `grep ... scripts/x.sh`) is correctly NOT flagged,
#     because only the command *word* of each simple command is examined.
#
# Accepts an optional repo_root argument (defaults to this script's own repo)
# so tests/bats/check_executable_bits.bats can point it at a fixture git tree
# instead of depending on the real repository.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

# The committed mode is read from git, so this must be a git work tree.
# `cd "$repo_root"` above already put us inside it, so a bare `git` call
# (no `-C`) resolves against it.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf '::error::check-executable-bits: %s is not a git work tree; cannot read committed file modes.\n' "$repo_root" >&2
  exit 1
fi

workflow_dir=.github/workflows
actions_dir=.github/actions
shopt -s nullglob
scan_files=(
  "$workflow_dir"/*.yml "$workflow_dir"/*.yaml
  "$actions_dir"/*/action.yml "$actions_dir"/*/action.yaml
)
shopt -u nullglob

if [ "${#scan_files[@]}" -eq 0 ]; then
  printf '::error::check-executable-bits: no workflow or composite-action files found under %s or %s.\n' "$workflow_dir" "$actions_dir" >&2
  exit 1
fi

failures=0

fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf '::warning::%s\n' "$1" >&2
}

# A repo script path (optionally with a leading ./), anchored to the four
# top-level directories this repo keeps executable scripts under. `.bats` is
# included because a bats suite executed by bare path (rather than `bats
# <file>`) would need the bit too.
script_path_re='^(scripts|services|tests|\.githooks)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|bats)$'

# committed_mode <path>
# Prints the git tree mode (e.g. 100644 or 100755) recorded for a tracked
# path at HEAD, or nothing if the path is not tracked. Reads the committed
# tree, not the index or the filesystem, so the result is independent of the
# checkout's core.filemode setting and reflects exactly what a bare
# invocation in CI will execute.
committed_mode() {
  git ls-tree HEAD -- "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

# require_executable <path> <context>
# Fails the check if <path> is tracked but not committed as mode 100755.
require_executable() {
  local path="$1" context="$2" mode
  mode="$(committed_mode "$path")"
  if [ -z "$mode" ]; then
    # A bare invocation of an untracked path is a different bug (missing
    # file), not a lost-exec-bit one; warn rather than fail so this guard
    # stays scoped to the mode class and does not false-fail on a
    # legitimately generated or intentionally .gitignored target.
    warn "check-executable-bits: '$path' is invoked as a bare path ($context) but is not tracked at HEAD -- cannot verify its committed mode."
    return
  fi
  if [ "$mode" != "100755" ]; then
    fail "'$path' is invoked as a bare path ($context) but its committed git mode is $mode, not 100755. A bare-path invocation execs the file directly, so a non-executable mode fails at runtime with 'Permission denied' (exit 126). Fix with: git update-index --chmod=+x '$path' (see issue #1019 / #822 Pattern B / Rule-Ref: AG-VAL-024)."
  fi
}

# command_word_script <shell-segment>
# Given one shell command segment (already split off at a command
# separator), prints the repo script path it *executes* by bare path, or
# nothing. It strips a leading exec-wrapper (`exec`/`command`/`sudo`) and a
# leading `./`, then returns the first token only if that token is itself a
# repo script path -- i.e. the file is the command being run, not an argument
# to some other command, and not the target of an interpreter/reader
# (`bash`/`sh`/`.`/`source`/`bats`/`shellspec`/`python3`), which would make
# the executable bit irrelevant.
command_word_script() {
  local seg="$1" first candidate
  # Trim leading whitespace and any leading grouping/keyword tokens that can
  # legitimately precede a command word within a single segment.
  while :; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    case "$seg" in
      '('*) seg="${seg#(}"; continue ;;
      '{'*) seg="${seg#\{}"; continue ;;
      'then '*) seg="${seg#then}"; continue ;;
      'do '*) seg="${seg#do}"; continue ;;
      'else '*) seg="${seg#else}"; continue ;;
      'exec '*) seg="${seg#exec}"; continue ;;
      'command '*) seg="${seg#command}"; continue ;;
      'sudo '*) seg="${seg#sudo}"; continue ;;
    esac
    break
  done
  first="${seg%%[[:space:]]*}"
  [ -n "$first" ] || return 0
  case "$first" in
    bash|sh|dash|zsh|ksh|.|source|bats|shellspec|python|python3) return 0 ;;
  esac
  candidate="${first#./}"
  if [[ "$candidate" =~ $script_path_re ]]; then
    printf '%s' "$candidate"
  fi
}

# split_into_segments <line>
# Splits a shell line into command segments at command separators
# (&& || ; |) using pure bash parameter expansion, emitting one segment per
# line. Kept subprocess-free (no per-line `sed`) so scanning every line of a
# multi-thousand-line workflow file stays fast on every host, including
# Windows Git Bash where each subprocess spawn is expensive. `||` and `&&`
# are collapsed before the single `|` so a `||` is not mis-split as two
# empty pipes.
split_into_segments() {
  local s="$1" nl=$'\n'
  s="${s//&&/$nl}"
  s="${s//||/$nl}"
  s="${s//;/$nl}"
  s="${s//|/$nl}"
  # Trailing newline is required: without it `while IFS= read -r segment`
  # silently drops the final (and, for a separator-free line, only) segment,
  # since `read` returns non-zero at EOF-without-newline before the loop body
  # runs. The empty trailing segment this produces is filtered by the loop's
  # own `[ -n "$segment" ]` guard.
  printf '%s\n' "$s"
}

for file in "${scan_files[@]}"; do
  # Pre-filter to only the handful of lines that even mention a candidate
  # script directory, so the per-segment parsing below never runs on the
  # thousands of unrelated lines in a large workflow file. `|| true` keeps a
  # file with zero candidate lines from tripping `set -e` on grep's exit 1.
  while IFS= read -r line; do
    # Left-trim; skip whole-line shell comments -- this is how a workflow
    # comment that merely *mentions* a script path (e.g. full-setup-
    # validate.yml's prose reference to full-setup-client-simulation.sh) is
    # prevented from being read as an invocation.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in \#*) continue ;; esac

    # Drop a leading YAML list marker and a leading `run:` key so an inline
    # `run: scripts/foo.sh` is analyzed as shell; block-scalar `run: |`
    # bodies arrive here already as bare indented shell lines and need no
    # such stripping.
    trimmed="${trimmed#- }"
    case "$trimmed" in
      run:*)
        trimmed="${trimmed#run:}"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        ;;
    esac
    [ -n "$trimmed" ] || continue

    while IFS= read -r segment; do
      [ -n "$segment" ] || continue
      found="$(command_word_script "$segment")"
      if [ -n "$found" ]; then
        require_executable "$found" "in $file"
      fi
    done < <(split_into_segments "$trimmed")
  done < <(grep -E '(scripts|services|tests|\.githooks)/' "$file" || true)
done

# .githooks/*: git execs a hook by bare path unconditionally, so every
# tracked file there must be executable regardless of whether any workflow
# references it.
while IFS=$'\t' read -r meta path; do
  [ -n "${path:-}" ] || continue
  mode="${meta%% *}"
  if [ "$mode" != "100755" ]; then
    fail "'$path' is a git hook (.githooks/) but its committed git mode is $mode, not 100755. Git runs a hook by bare path, so a non-executable hook is silently skipped or errors. Fix with: git update-index --chmod=+x '$path' (see issue #1019 / #822 Pattern B)."
  fi
done < <(git ls-tree -r HEAD -- .githooks 2>/dev/null)

if [ "$failures" -gt 0 ]; then
  printf '::error::check-executable-bits: %d file(s) invoked by bare path (or git hooks) are not committed as executable (see issue #1019 / #822 Pattern B).\n' "$failures" >&2
  exit 1
fi

printf 'check-executable-bits: OK (every bare-path script invocation and every .githooks/ file is committed as mode 100755).\n'
