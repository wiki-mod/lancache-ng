#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
# This script parses every workflow and composite-action file for shell
# content in `run:` values, flags commands that execute a repo script by a
# *bare path* (no `bash`/`sh`/`.`/`source` interpreter prefix -- those read the
# file and do not need the executable bit), and asserts each such file's
# *committed* git mode is 100755. Other YAML values such as `paths:` are data,
# not shell, and must never be interpreted as commands merely because their
# scalar text looks like a repository path.
#
# GitHub Actions workflow syntax makes `run` the shell-command field, while
# YAML 1.2 permits that scalar either inline or as a literal/folded block
# (`|`/`>`) with optional chomping and indentation indicators. The scanner
# therefore recognizes plain/single-quoted/double-quoted `run` mapping keys,
# both block-scalar indicator orders, and the shell text indented beneath a
# block scalar. Backslash-continued physical shell lines are joined before
# command-word classification so data words in a multiline construct such as
# `for x in \\ ...; do` are not mistaken for independently executed commands.
#
# The committed mode (`git ls-tree HEAD`) is what matters, not the checkout's
# filesystem mode: CI checks the repo out from git, so the mode stored in the
# tree is exactly what a bare invocation will get, and it is the only mode
# that is meaningful on a core.filemode=false author host.
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
# than adding a YAML library or another committed runtime dependency
# (Rule-Ref: AG-REL-001), and rather than a PCRE grep
# (check-idempotence-test-coverage.sh's own header documents that both PCRE
# grep and a POSIX-awk rewrite misbehaved on this project's actual self-hosted
# runners).
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
# Splits a shell line into command segments at the separators this guard
# needs to recognize (&&, ||, ;, |). This intentionally stays a lightweight
# command-word scanner rather than pretending to be a full Bash parser; the
# workflow's real shell syntax is validated separately by shellcheck/bash.
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

# inspect_shell_line <logical-shell-line> <context>
# Classifies only shell text that came from a GitHub Actions `run:` scalar.
# Keeping this separate from YAML extraction prevents configuration data that
# happens to contain script-looking paths from reaching the command scanner.
inspect_shell_line() {
  local shell_line="$1" context="$2" segment found
  shell_line="${shell_line#"${shell_line%%[![:space:]]*}"}"
  [ -n "$shell_line" ] || return 0
  case "$shell_line" in \#*) return 0 ;; esac

  while IFS= read -r segment; do
    [ -n "$segment" ] || continue
    found="$(command_word_script "$segment")"
    if [ -n "$found" ]; then
      require_executable "$found" "$context"
    fi
  done < <(split_into_segments "$shell_line")
}

# is_block_scalar_header <run-value>
# YAML block scalars use `|` (literal) or `>` (folded), optionally followed
# by one chomping indicator (+/-), one indentation indicator (1-9), in either
# order, plus an optional YAML comment. Recognizing the complete indicator
# shape prevents a legitimate `run: >-`/`run: |2-` form from being mistaken
# for an inline shell command.
is_block_scalar_header() {
  local value="$1"
  [[ "$value" =~ ^[\|\>](\+|-)?[1-9]?[[:space:]]*(#.*)?$ ]] ||
    [[ "$value" =~ ^[\|\>][1-9](\+|-)?[[:space:]]*(#.*)?$ ]]
}

# yaml_run_value <yaml-line>
# Prints "<key-indent><TAB><value>" only when the line defines a `run`
# mapping key. A leading sequence marker (`- run:`) and quoted YAML mapping
# keys are accepted; unrelated YAML values are intentionally ignored.
yaml_run_value() {
  local line="$1" leading body key_indent value
  leading="${line%%[! ]*}"
  body="${line#"$leading"}"
  key_indent=${#leading}
  if [[ "$body" == '- '* ]]; then
    body="${body#- }"
    key_indent=$((key_indent + 2))
  fi

  case "$body" in
    run:*) value="${body#run:}" ;;
    "'run':"*) value="${body#\'run\':}" ;;
    '"run":'*) value="${body#\"run\":}" ;;
    *) return 1 ;;
  esac

  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s\t%s\n' "$key_indent" "$value"
}

# inspect_run_physical_line <line> <context>
# Joins shell physical lines ending in a backslash before classification.
# This mirrors the shell's logical-line behavior for the common workflow
# continuation shape and, critically, keeps a multiline `for ... in` word
# list as one statement whose command word is `for`, not one fake command per
# data item.
pending_shell_line=""
inspect_run_physical_line() {
  local line="$1" context="$2" right_trimmed
  line="${line#"${line%%[![:space:]]*}"}"
  right_trimmed="${line%"${line##*[![:space:]]}"}"

  if [[ -n "$pending_shell_line" ]]; then
    pending_shell_line+=" $right_trimmed"
  else
    pending_shell_line="$right_trimmed"
  fi

  if [[ "$right_trimmed" == *\\ ]]; then
    pending_shell_line="${pending_shell_line%\\}"
    return 0
  fi

  inspect_shell_line "$pending_shell_line" "$context"
  pending_shell_line=""
}

for file in "${scan_files[@]}"; do
  in_run_block=0
  run_key_indent=0
  pending_shell_line=""

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_run_block" -eq 1 ]; then
      # Blank lines are part of a block scalar and do not terminate its YAML
      # indentation scope.
      if [ -z "${line//[[:space:]]/}" ]; then
        continue
      fi

      leading="${line%%[! ]*}"
      line_indent=${#leading}
      if [ "$line_indent" -gt "$run_key_indent" ]; then
        inspect_run_physical_line "$line" "in $file"
        continue
      fi

      # Reaching the key's indentation ends the block. A dangling continued
      # logical line is still inspected rather than silently discarded; the
      # repository's separate shell syntax checks will reject malformed Bash.
      if [ -n "$pending_shell_line" ]; then
        inspect_shell_line "$pending_shell_line" "in $file"
        pending_shell_line=""
      fi
      in_run_block=0
      # The current physical line belongs to YAML again, so intentionally
      # fall through and test whether it begins another `run:` scalar.
    fi

    if run_record="$(yaml_run_value "$line")"; then
      run_key_indent="${run_record%%$'\t'*}"
      run_value="${run_record#*$'\t'}"
      if is_block_scalar_header "$run_value"; then
        in_run_block=1
        pending_shell_line=""
      elif [ -n "$run_value" ]; then
        # Inline `run:` values are shell text. Strip one simple outer quote
        # pair because YAML permits quoted scalars and a quoted scalar still
        # becomes the same command string when Actions invokes the shell.
        if [[ "$run_value" == \'*\' && "$run_value" == *\' ]]; then
          run_value="${run_value:1:${#run_value}-2}"
          run_value="${run_value//\'\'/\'}"
        elif [[ "$run_value" == \"*\" && "$run_value" == *\" ]]; then
          run_value="${run_value:1:${#run_value}-2}"
        fi
        inspect_shell_line "$run_value" "in $file"
      fi
    fi
  done < "$file"

  if [ "$in_run_block" -eq 1 ] && [ -n "$pending_shell_line" ]; then
    inspect_shell_line "$pending_shell_line" "in $file"
  fi
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
