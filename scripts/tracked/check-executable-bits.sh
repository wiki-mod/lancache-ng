#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: guard bare-path scripts/hooks committed as mode 100755
# Why: Windows-invisible without check; core.filemode=false
# From: Issue #1019
set -euo pipefail

# What: accept optional repo_root, default to script's repo
# Why: allow tests to point at fixture git tree
# From: Issue #1019
repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

# What: require git work tree at repo_root
# Why: read committed tree via git, independent of core.filemode
# From: Issue #1019
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

# What: match repo script paths in four dirs + .bats
# Why: repo-root-relative only; ${VAR} not resolved
# From: Issue #1019
script_path_re='^(scripts|services|tests|\.githooks)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|bats)$'

# What: committed_mode prints git tree mode for tracked path
# Why: read git tree not filesystem; independent of filemode
# From: Issue #1019
committed_mode() {
  git ls-tree HEAD -- "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

# What: fail if tracked path not committed as mode 100755
# Why: bare-path invocation execs directly; mode fail=126
# From: Issue #1019
require_executable() {
  local path="$1" context="$2" mode
  mode="$(committed_mode "$path")"
  if [ -z "$mode" ]; then
    # What: warn if path invoked bare but not tracked at HEAD
    # Why: untracked invocation is missing-file bug not mode bug
    # From: Issue #1019
    warn "check-executable-bits: '$path' is invoked as a bare path ($context) but is not tracked at HEAD -- cannot verify its committed mode."
    return
  fi
  if [ "$mode" != "100755" ]; then
    fail "'$path' is invoked as a bare path ($context) but its committed git mode is $mode, not 100755. A bare-path invocation execs the file directly, so a non-executable mode fails at runtime with 'Permission denied' (exit 126). Fix with: git update-index --chmod=+x '$path' (see issue #1019 / #822 Pattern B / Rule-Ref: AG-VAL-024)."
  fi
}

# What: print repo script path a segment execs by bare path
# Why: only first token; not args or interpreter (bash/sh)
# From: Issue #1019
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

# What: split shell line into segments at &&, ||, ;, |
# Why: avoid YAML lib dependency (AG-REL-001); PCRE issues
# From: Issue #1019
split_into_segments() {
  local s="$1" nl=$'\n'
  s="${s//&&/$nl}"
  s="${s//||/$nl}"
  s="${s//;/$nl}"
  s="${s//|/$nl}"
  # What: append trailing newline before printing
  # Why: without it read returns non-zero, silently drops final
  # From: Issue #1019
  printf '%s\n' "$s"
}

# What: classify shell text from run: scalar, skip if no prefix
# Why: separate classification from YAML; avoid per-line fork
# From: Issue #1019
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

# What: recognize |/> block-scalar (chomping +/-, indent 1-9)
# Why: prevent run: >- being mistaken for inline shell
# From: Issue #1019
is_block_scalar_header() {
  local value="$1"
  [[ "$value" =~ ^[\|\>](\+|-)?[1-9]?[[:space:]]*(#.*)?$ ]] ||
    [[ "$value" =~ ^[\|\>][1-9](\+|-)?[[:space:]]*(#.*)?$ ]]
}

# What: print key-indent<TAB>value only for run: mapping key
# Why: prevent unrelated YAML values mistaken for shell
# From: Issue #1019
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

# What: join shell physical lines ending in backslash
# Why: mirror shell logical-line behavior; keep for loops one
# From: Issue #1019
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
      # What: treat blank line as still inside block scalar
      # Why: blank does not terminate YAML block scalar scope
      # From: Issue #1019
      if [ -z "${line//[[:space:]]/}" ]; then
        continue
      fi

      leading="${line%%[! ]*}"
      line_indent=${#leading}
      if [ "$line_indent" -gt "$run_key_indent" ]; then
        inspect_run_physical_line "$line" "in $file"
        continue
      fi

      # What: inspect dangling logical line before clearing
      # Why: separate checks reject malformed bash; avoid silent drop
      # From: Issue #1019
      if [ -n "$pending_shell_line" ]; then
        inspect_shell_line "$pending_shell_line" "in $file"
        pending_shell_line=""
      fi
      in_run_block=0
    fi

    # What: skip yaml_run_value subshell if no run: substring
    # Why: yaml_run_value never matches; avoid fork per large line
    # From: Issue #1095 | PR #1501
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
        # What: strip one outer quote pair from inline run: value
        # Why: YAML quoted scalar becomes same command string in Actions
        # From: Issue #1019
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

# What: require all tracked .githooks/ files executable
# Why: git execs hook by bare path; non-exec silently skipped
# From: Issue #1019
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
