#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: standing guard requiring every bare-path-invoked script (and every
# .githooks/ file) to be committed as git mode 100755, not 100644.
# Why: invisible from a Windows/core.filemode=false host -- `chmod +x` is a
# no-op there and no local check reveals the committed mode (AG-VAL-024).
# From: Issue #1019 | Issue #1095 | PR #1501.
set -euo pipefail

# What: accepts an optional repo_root argument, defaulting to this script's
# own repo.
# Why: lets tests/bats/check_executable_bits.bats point this at a fixture
# git tree instead of the real repository.
# From: Issue #1019 | Issue #1095 | PR #1501.
repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

# What: requires a git work tree at repo_root.
# Why: the committed mode is read from git, and `cd "$repo_root"` above
# already put us inside it, so a bare `git` call (no `-C`) resolves against it.
# From: Issue #1019 | Issue #1095 | PR #1501.
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

# What: matches a repo script path anchored to the four top-level dirs this
# repo keeps executable scripts under, plus `.bats`.
# Why: repo-root-relative only -- a `../`-relative or `$VAR`-interpolated
# path is not resolved; `.bats` covers a bare-path bats suite too.
# From: Issue #1019 | Issue #1095 | PR #1501.
script_path_re='^(scripts|services|tests|\.githooks)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|bats)$'

# What: committed_mode() prints the git tree mode for a tracked path at HEAD.
# Why: reads the committed tree, not the filesystem, independent of the
# checkout's core.filemode.
# From: Issue #1019 | Issue #1095 | PR #1501.
committed_mode() {
  git ls-tree HEAD -- "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

# What: require_executable() fails the check if <path> is tracked but not
# committed as mode 100755.
# Why: a bare-path invocation execs the file directly, so a non-executable
# mode fails at runtime.
# From: Issue #1019 | Issue #1095 | PR #1501.
require_executable() {
  local path="$1" context="$2" mode
  mode="$(committed_mode "$path")"
  if [ -z "$mode" ]; then
    # What: warns instead of failing when the path is not tracked at HEAD.
    # Why: an untracked bare invocation is a different bug (missing file),
    # not a lost-exec-bit one, and this keeps the guard scoped to the mode
    # class rather than false-failing on a generated or gitignored target.
    # From: Issue #1019 | Issue #1095 | PR #1501.
    warn "check-executable-bits: '$path' is invoked as a bare path ($context) but is not tracked at HEAD -- cannot verify its committed mode."
    return
  fi
  if [ "$mode" != "100755" ]; then
    fail "'$path' is invoked as a bare path ($context) but its committed git mode is $mode, not 100755. A bare-path invocation execs the file directly, so a non-executable mode fails at runtime with 'Permission denied' (exit 126). Fix with: git update-index --chmod=+x '$path' (see issue #1019 / #822 Pattern B / Rule-Ref: AG-VAL-024)."
  fi
}

# What: command_word_script() prints the repo script path a segment
# executes by bare path.
# Why: only the first token counts as the command, not a data argument or
# an interpreter/reader (`bash`/`source`/etc).
# From: Issue #1019 | Issue #1095 | PR #1501.
command_word_script() {
  local seg="$1" first candidate
  # Trims leading whitespace and grouping/keyword tokens that can legitimately
  # precede a command word within a single segment.
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

# What: splits a shell line into segments at &&, ||, ;, | (plain bash
# string matching, not a YAML library or PCRE grep).
# Why: a YAML library is a dependency this project avoids (AG-REL-001);
# PCRE grep is known to misbehave on this project's self-hosted runners.
# From: Issue #1019 | Issue #1095 | PR #1501.
split_into_segments() {
  local s="$1" nl=$'\n'
  s="${s//&&/$nl}"
  s="${s//||/$nl}"
  s="${s//;/$nl}"
  s="${s//|/$nl}"
  # What: appends a trailing newline before printing.
  # Why: without it, `while IFS= read -r segment` silently drops the final
  # segment, since `read` returns non-zero at EOF-without-newline before the
  # loop body runs.
  # From: Issue #1019 | Issue #1095 | PR #1501.
  printf '%s\n' "$s"
}

# What: classifies shell text from a `run:` scalar, skipping segments when
# no script_path_re prefix appears in the line at all.
# Why: keeps classification separate from YAML extraction; the prefix
# pre-check avoids an expensive per-segment subshell fork on every line.
# From: Issue #1019 | Issue #1095 | PR #1501.
inspect_shell_line() {
  local shell_line="$1" context="$2" segment found
  shell_line="${shell_line#"${shell_line%%[![:space:]]*}"}"
  [ -n "$shell_line" ] || return 0
  case "$shell_line" in \#*) return 0 ;; esac
  case "$shell_line" in
    *scripts/*|*services/*|*tests/*|*.githooks/*) ;;
    *) return 0 ;;
  esac

  while IFS= read -r segment; do
    [ -n "$segment" ] || continue
    found="$(command_word_script "$segment")"
    if [ -n "$found" ]; then
      require_executable "$found" "$context"
    fi
  done < <(split_into_segments "$shell_line")
}

# What: is_block_scalar_header() recognizes the `|`/`>` block-scalar
# indicator shape (chomping +/-, indentation 1-9, either order).
# Why: prevents `run: >-`/`run: |2-` from being mistaken for inline shell;
# an explicit indentation-indicator column is untested but unused today.
# From: Issue #1019 | Issue #1095 | PR #1501.
is_block_scalar_header() {
  local value="$1"
  [[ "$value" =~ ^[\|\>](\+|-)?[1-9]?[[:space:]]*(#.*)?$ ]] ||
    [[ "$value" =~ ^[\|\>][1-9](\+|-)?[[:space:]]*(#.*)?$ ]]
}

# What: yaml_run_value() prints "<key-indent><TAB><value>" only when the
# line defines a `run` mapping key, else fails.
# Why: unrelated YAML values must never be mistaken for shell content.
# From: Issue #1019 | Issue #1095 | PR #1501.
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

# What: inspect_run_physical_line() joins shell physical lines ending in a
# backslash before classification.
# Why: mirrors the shell's own logical-line behavior, so a multiline
# `for ... in` word list stays one statement, not one fake command per item.
# From: Issue #1019 | Issue #1095 | PR #1501.
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
      # What: treats a blank line as still inside the block scalar.
      # Why: a blank line does not terminate a YAML block scalar's
      # indentation scope.
      # From: Issue #1019 | Issue #1095 | PR #1501.
      if [ -z "${line//[[:space:]]/}" ]; then
        continue
      fi

      leading="${line%%[! ]*}"
      line_indent=${#leading}
      if [ "$line_indent" -gt "$run_key_indent" ]; then
        inspect_run_physical_line "$line" "in $file"
        continue
      fi

      # What: inspects a dangling continued logical line before clearing it,
      # then falls through to test whether the current line starts another `run:`.
      # Why: separate shell syntax checks reject malformed Bash, so a
      # dangling line is inspected here rather than silently discarded.
      # From: Issue #1019 | Issue #1095 | PR #1501.
      if [ -n "$pending_shell_line" ]; then
        inspect_shell_line "$pending_shell_line" "in $file"
        pending_shell_line=""
      fi
      in_run_block=0
    fi

    # What: skips the yaml_run_value subshell for a line with no `run:` substring.
    # Why: yaml_run_value() can never match such a line; this avoids forking
    # a subshell on every line of a large workflow file.
    # From: Issue #1095 | PR #1501.
    case "$line" in
      *run:*) ;;
      *) continue ;;
    esac

    if run_record="$(yaml_run_value "$line")"; then
      run_key_indent="${run_record%%$'\t'*}"
      run_value="${run_record#*$'\t'}"
      if is_block_scalar_header "$run_value"; then
        in_run_block=1
        pending_shell_line=""
      elif [ -n "$run_value" ]; then
        # What: strips one outer quote pair from an inline `run:` value.
        # Why: YAML permits a quoted scalar, which becomes the identical
        # command string once Actions invokes the shell.
        # From: Issue #1019 | Issue #1095 | PR #1501.
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

# What: requires every tracked .githooks/ file to be executable, regardless
# of whether any workflow references it.
# Why: git execs a hook by bare path unconditionally; a bats
# script-under-test is already self-guarded via `bats tests/bats` instead.
# From: Issue #1019 | Issue #1095 | PR #1501.
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
