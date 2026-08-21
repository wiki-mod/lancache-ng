#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard (AG-VAL-029) for a confirmed real CI failure: a shell
# pipeline that pipes a live-running producer command into an early-exiting
# consumer (`grep -q`, `grep -m<N>`, `head`, `sed -n '<N>p'`) under
# `set -o pipefail` can fail with an unrelated-looking exit code (typically
# 141, SIGPIPE) whenever the consumer decides it has what it needs and closes
# its end of the pipe while the producer is still writing -- the producer
# receives SIGPIPE, and `pipefail` reports that as the pipeline's exit status
# even though the consumer itself matched/succeeded. The confirmed instance
# this guard exists for: `tools/build-tools/Dockerfile`'s musl/host
# verification RUN step, real CI job 91393831566 (run 30709307913, PR #1374,
# issue #815) failed with exit 141 on
# `rustup target list --installed | grep -qx ...` /
# `rustc -vV | grep -qE ...` -- fixed in the same PR by capturing each
# producer's output into a variable first. A near-identical shape (`git log |
# tail | head -n 50`) was independently found and fixed the same session in
# PR #1371's find_built_ancestor(). A proposed AGENTS.md rule for the
# general failure class was posted on PR #1374 for maintainer review per
# AG-WF-025 (originally drafted as AG-VAL-030, since claimed by an unrelated
# rule; landed as AG-VAL-032 via issue #1377, which also widened this
# script's own scope repo-wide) -- this script is the separate,
# already-required AG-VAL-029 standing check for the confirmed incident,
# independent of that governance rule.
#
# SCOPE: repo-wide, per issue #1377 -- every tracked shell script under
# scripts/**, tools/**, and services/**, every tools/*/Dockerfile* and
# services/*/Dockerfile*, plus setup.sh (the production installer).
# Dockerfiles are in scope for exactly the same reason shell scripts are: a
# multi-stage service builder Dockerfile commonly runs under `set -o
# pipefail` (`tools/build-tools/Dockerfile`'s confirmed real incident, see
# above) and can pipe a producer into an early-exiting consumer inside a
# single `RUN` instruction just as easily as a standalone script can.
# `services/**` matters just as much as `scripts/**`/`tools/**`: a service
# entrypoint commonly runs under its own `set -e`/`pipefail` and can pipe a
# captured multi-line value (e.g. via `printf`) into an early-exiting
# consumer such as `grep -qi`, the exact SIGPIPE-under-pipefail hazard this
# guard exists to catch. This was originally scoped to only
# `tools/build-tools/Dockerfile` (the exact
# file the confirmed incident occurred in) because a first wide scan found
# 41 preexisting instances of the same raw pattern across the codebase with
# none individually reviewed yet, and fixing or reviewing all of them in
# that PR (#1374) would have been a disproportionate scope expansion for an
# unrelated musl-toolchain/network-verification change. Issue #1377 tracked
# that gap explicitly and did the actual per-location triage: a fresh scan
# at #1377's own audit time found 56 locations (the codebase had drifted
# since the original 41 were listed -- some were already fixed by
# unrelated changes, `setup.sh` had grown new instances), each reviewed
# individually. Every genuine SIGPIPE risk (a live pipe from a producer
# that could still be writing when an early-exiting consumer decides it has
# enough -- proven empirically on a real runner, not just reasoned about:
# even `seq 1 200000 | head -1` reproducibly exits 141 under `pipefail`) was
# fixed by capturing the producer's output into a variable first and
# feeding the consumer via a here-string, eliminating the live pipe
# entirely. The remaining handful are marked `# pipefail-safe: <reason>`
# because they are backed by a hard tool contract for single-line or
# self-limiting output (`docker inspect --format` on one field of one
# container, `docker ps -q --filter name=^X$`, `find ... -print -quit`, and
# one Docker HEALTHCHECK `CMD-SHELL` line that runs under the container's
# own `/bin/sh -c` on every tick, a different execution context that never
# inherits the calling script's own `pipefail`) -- not because the output
# happens to be small or the producer happens to be fast, both of which the
# same empirical proof showed are not reliable safety signals on their own.
#
# WHAT THIS DOES NOT DO: this is a deliberately cheap, grep-based heuristic
# (matching this project's existing check-build-tools-smoke-coverage.sh
# style, not a real shell parser). It cannot tell whether pipefail is active
# at the specific matched line (only that the word "pipefail" appears
# somewhere in the file), and it cannot tell whether a matched pipe is
# actually safe. A reviewed-safe line can be marked with a trailing
# `# pipefail-safe: <reason>` comment to suppress a false positive.
#
# SECOND, INDEPENDENT CHECK (added 2026-08-13, issue #1449, AG-VAL-029
# maintainer decision: extend this existing guard rather than add a new
# script or new workflow wiring): a different but related POSIX shell
# gotcha -- an `if CMD; then BLOCK; fi` with NO `else` clause, where the very
# next line of code reads `$?` expecting CMD's real exit status. POSIX/bash
# define a condition-only `if` that takes no branch (false condition, no
# matching `else`) as exiting the WHOLE if construct with status 0,
# unconditionally -- not the tested command's own exit code. Confirmed live:
# `f() { return 22; }; if f; then :; fi; status=$?; echo "$status"` prints
# `0`, not `22`.
#
# Confirmed real instance this pattern was added to catch:
# scripts/untracked/check-netdata-curl-pin.sh's fetch_bundled_packages_version() read
# `local status=$?` immediately after `if curl -fsSL "${url}"; then return 0;
# fi` with no else -- every curl failure, including a genuine HTTP 404
# (exit 22), silently read status=0, so the confirmed-absence fast-fail
# branch could never fire. Fixed in the same pass this second check was
# added (see check_if_without_else_status() below).
#
# Deliberately NOT gated on the file mentioning "pipefail" (unlike the check
# above): this bug is not pipefail-specific -- it manifests under plain
# `set -e`, or even with no strict mode at all, whenever a caller reads $?
# expecting a real value. Runs against the same repo-wide scan_files this
# script already discovers, for every file, unconditionally.
#
# WHAT THIS SECOND CHECK DOES NOT DO: a deliberately cheap, token-based
# heuristic (splitting each line on whitespace/`;` and watching for bare
# `if`/`elif`/`else`/`fi` tokens with a per-nesting-depth "did this if see an
# else" flag), not a real shell parser -- it can in principle be fooled by an
# `if`/`fi`-shaped string inside unusual quoting or a heredoc body. It only
# flags a `$?` read on the SINGLE line immediately following a qualifying
# `fi` (skipping only blank/comment lines in between): any other command
# between the `fi` and the `$?` read would itself become the value `$?`
# captures, which is a different, unrelated correctness question outside
# this check's scope. A reviewed-safe line can be marked with a trailing
# `# if-status-safe: <reason>` comment to suppress a false positive,
# mirroring this file's `# pipefail-safe:` convention above.
#
# SCOPE NOTE (recorded per AG-VAL-029/AG-VAL-028, not silently omitted): the
# original repo-wide audit for this bug class (issue #1449) additionally
# covered tests/bats/**, .github/workflows/*.yml, and
# .github/actions/**/action.yml (all came back clean at audit time) -- this
# standing check does not cover those, since it deliberately reuses this
# script's own existing scan_files (scripts/**, tools/**, services/**,
# setup.sh, plus their Dockerfiles) per the maintainer's "extend this
# script, no new workflow wiring" decision. That is a real, deliberate
# scope gap versus the one-off audit, not an oversight. This file's name
# (check-pipefail-early-exit-grep.sh) now undersells its actual scope for
# the same "no new wiring" reason: renaming it would require updating
# .github/actions/shellcheck-and-standing-guards/action.yml's own reference,
# which is itself a (trivial but real) workflow-wiring change the
# maintainer's decision did not ask for.
#
# THIRD, INDEPENDENT CHECK (added 2026-08-21, Issue #1095 F-23, maintainer
# decision: fold this new pattern into this existing guard rather than add a
# new script -- same "extend this script, no new file" call already made
# once for the second check above): a `docker run` invocation that feeds its
# command to the container via a `bash -s <<'X'` / `sh -s <<'X'` stdin
# heredoc but omits `-i` never attaches the container's stdin at all, so the
# containerized shell reads immediate EOF and exits 0 having run none of the
# heredoc's commands -- a green step, not a visible failure.
#
# CONFIRMED REAL INSTANCE (not just reasoned about): build-push.yml's
# `release` job ("Create or update GitHub release for built images" and
# "Attach OpenVEX document to the release" steps) and `release-sbom` job
# (SBOM-asset-upload step) all had this shape. Checked against the real
# v0.3.0 release (published 2026-08-03, run 30788959407, both steps reported
# `success`): the release body is exactly release-drafter's own generated
# changelog with none of the "Resolved build-tools base image digests" /
# "Provenance and SBOM status" text the release-notes step's heredoc was
# supposed to append, and the release carries zero assets -- no
# vex.openvex.json, no <service>.cdx.json. Fixed in Issue #1095 (F-23)'s PR
# by adding `-i` to all three invocations.
#
# SCOPE: unlike the first two checks above, this one deliberately does NOT
# reuse their scan_files -- its actual domain (workflow/composite-action
# YAML) is exactly the class of file the SCOPE NOTE above documents those two
# checks as not covering. Discovers its own file list via `git ls-files`
# (matching this file's own established preference over `find`, so a new
# workflow or action file is automatically covered without a hand-maintained
# list): .github/workflows/**/*.yml(.yaml) and .github/actions/**/*.yml(.yaml)
# -- both extensions genuinely occur in this tree
# (.github/workflows/update-changelog.yaml, .github/actionlint.yaml). A
# `docker run` command is matched heuristically: this repo's own established
# convention (confirmed by inspecting every current instance before writing
# this check, per AG-VAL-036) is always `docker run --rm [-i] \` immediately
# followed by zero or more `-e`/`-v` flag lines, then the image reference,
# then the command to run -- when that command ends in `bash -s <<'MARKER'`
# or `sh -s <<'MARKER'`, `-i` is required somewhere in the flags. This
# intentionally does not try to parse arbitrary `docker run`
# argument-ordering/syntax in general -- it targets the one call-site shape
# this repo actually uses, the same scoping principle the first check above
# already documents for its own heuristic.
#
# WHAT THIS THIRD CHECK DOES NOT DO: it looks back only up to 20 lines from a
# matched heredoc marker for the nearest preceding `docker run` line, and
# anchors on the LAST such line in that window (not the first), since two
# docker-run invocations can legitimately fall inside the same 20-line window
# (this repo's real "Attach OpenVEX document to the release" step has exactly
# that shape: a plain generate call, then the heredoc-fed upload call ~10
# lines later) -- anchoring on the first match would silently pass a genuine
# violation whenever an earlier, unrelated invocation in the window happens
# to carry -i. A comment line (including this file's own explanatory prose
# above, which quotes the exact pattern verbatim) is skipped, not treated as
# a real invocation -- confirmed empirically: without this check, an earlier
# version of this logic flagged its own explanatory comment in
# vex-regenerate.yml as a missing-`-i` violation, a real false positive found
# by actually running it (AG-VAL-030).
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

# Repo-wide, per issue #1377 -- see this file's own header comment above.
# Discovered via `git ls-files` (not `find`) so this only ever scans
# tracked, committed scripts, and so a new script added under scripts/ or
# tools/ is automatically covered without needing this list hand-maintained
# -- the exact kind of drift that let the original narrow scope (a single
# hardcoded path) go unnoticed for as long as it did.
#
# Captured via a plain assignment first (not `mapfile -t scan_files < <(git
# ls-files ...)` directly), specifically so `git ls-files`'s own exit status
# is checked explicitly: a process substitution's failure does not
# propagate through `mapfile`, so a broken discovery (no git work tree
# here, or `git` itself missing) would otherwise silently leave scan_files
# empty, the scan loop below would iterate zero times, and the script would
# report a false "OK" with exit 0 -- a check that can never fail is not a
# check, per AG-VAL-002/AG-VAL-015. This is deliberately distinct from a
# valid git work tree that genuinely has zero tracked files matching these
# patterns (e.g. a bats fixture repo with only an untracked scratch file):
# that is a legitimate empty scan, not a discovery failure, and must still
# report OK.
if ! tracked_scan_files="$(git ls-files -- \
  'scripts/*.sh' 'scripts/**/*.sh' \
  'tools/*.sh' 'tools/**/*.sh' \
  'tools/*/Dockerfile*' \
  'services/*.sh' 'services/**/*.sh' \
  'services/*/Dockerfile*' \
  'setup.sh')"; then
  printf '::error::check-pipefail-early-exit-grep: `git ls-files` itself failed -- is %s a real git work tree? Not treating this as a clean pass.\n' "$repo_root" >&2
  exit 1
fi

scan_files=()
if [ -n "$tracked_scan_files" ]; then
  mapfile -t scan_files < <(sort <<<"$tracked_scan_files")
fi

# Early-exiting-consumer patterns, matched immediately after a live pipe
# (`|`, not `||`): grep with -q or -m<N> (any short-option cluster containing
# one of those, e.g. `-qx`, `-qE`, `-m1`), a bare `head` invocation, or
# `sed -n` (commonly paired with a `Np`/`$p` address to print one line and
# stop). Deliberately does NOT flag `grep -F ... "$file" >/dev/null` reading
# an actual file argument (no live producer process on the other end of a
# pipe to receive SIGPIPE) -- only a `|`-preceded invocation is in scope.
pattern='\|[[:space:]]*(grep[[:space:]]+[^|]*-[a-zA-Z]*q|grep[[:space:]]+[^|]*-[a-zA-Z]*m[0-9]|head([[:space:]]|$)|sed[[:space:]]+-n[[:space:]])'

failures=0
fail() {
  printf '::error::%s\n' "$1" >&2
  failures=$((failures + 1))
}

for file in "${scan_files[@]}"; do
  [ -f "$file" ] || continue

  # Scope to files that use pipefail directly or inherit the build-tools
  # image's Bash/pipefail SHELL. Service builders commonly select that image
  # through BUILD_TOOLS_IMAGE, so requiring the literal word "pipefail" in
  # each child Dockerfile would miss the effective shell used by every RUN.
  # A direct build-tools image reference is included for fixtures and for
  # Dockerfiles that do not need the repository's overridable ARG pattern.
  inherits_build_tools_pipefail=false
  case "$file" in
    services/*/Dockerfile*)
      # `FROM` accepts optional `--flag`/`--flag=value` tokens (e.g.
      # `--platform=$BUILDPLATFORM`) before the image reference -- without
      # skipping over those, a multi-platform builder's own `FROM --platform=
      # ... ${BUILD_TOOLS_IMAGE} AS builder` line would never match, silently
      # exempting that stage from this guard despite genuinely inheriting
      # build-tools' pipefail SHELL. Matched case-insensitively (`-i`):
      # Dockerfile instruction names are themselves case-insensitive (Docker
      # accepts `from`/`From`/`FROM` identically), so a case-sensitive-only
      # match would miss a valid, differently-cased FROM line. Leading
      # `[[:space:]]*` allows optional indentation before the instruction,
      # which the Dockerfile format reference documents as ignored.
      if grep -Eqi '^[[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([^[:space:]]*build-tools([:@][^[:space:]]+)?|\$\{?BUILD_TOOLS_IMAGE\}?)($|[[:space:]])' "$file"; then
        inherits_build_tools_pipefail=true
      fi
      ;;
  esac

  # An early-exiting consumer piped from a still-writing producer is harmless
  # without pipefail: the pipeline status only reflects the consumer.
  if ! grep -qF 'pipefail' "$file" && [ "$inherits_build_tools_pipefail" != true ]; then
    continue
  fi

  while IFS=: read -r line_num line_content; do
    [ -n "$line_num" ] || continue

    # Skip full comment lines (leading whitespace then '#'): this guard's
    # own documentation (this file, and tools/build-tools/Dockerfile's real
    # incident writeup) legitimately quotes the dangerous pattern as literal
    # text (e.g. "`producer | grep -q...`") when describing the bug it
    # fixed -- that prose is not executable code and must not self-trigger
    # this check. A trailing inline comment on an actual code line (`foo |
    # grep -q bar # comment`) is still caught, since the code portion before
    # '#' is what the pattern actually matches.
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;;
    esac

    case "$line_content" in
      *'# pipefail-safe:'*) continue ;;
    esac
    fail "$file:$line_num: pipes a live command into an early-exiting consumer (grep -q/-m, head, or sed -n) in a file that uses or inherits pipefail -- this can fail with an unrelated-looking SIGPIPE (exit 141) if the producer is still writing when the consumer exits. Capture the producer's output into a variable first, then apply the consumer to the variable (e.g. via a here-string), or mark the line reviewed-safe with a trailing '# pipefail-safe: <reason>' comment if the producer is provably single-line/already-finished. Line: $trimmed"
  done < <(grep -nE "$pattern" "$file" || true)
done

# check_if_without_else_status <file>
# Emits one "<fi-line>:<status-line>:<status-line-content>" record per
# qualifying candidate: a `fi` that closes an if-block with no matching
# `else`/`elif` at its own nesting depth, whose immediate next non-blank,
# non-comment line contains a literal `$?`. See this file's own header
# comment above ("SECOND, INDEPENDENT CHECK") for the full rationale, the
# confirmed real incident this exists to catch, and this heuristic's
# documented limits.
#
# Implemented as a single awk pass (not per-line grep, unlike the pipefail
# check above): this pattern is inherently a two-line adjacency question
# (what immediately follows a specific `fi`), plus a same-file nesting-depth
# question (did THIS if have an else), neither of which a single-line regex
# can answer on its own. The whole file is read into an array first (the
# `{ lines[NR] = $0 }` pattern-action pair) so the END block can freely look
# both backward (nesting depth as of a given `fi`) and forward (the next
# real line after it) without needing bash to re-read the file a second
# time.
check_if_without_else_status() {
  local file="$1"
  awk '
    { lines[NR] = $0 }
    END {
      depth = 0
      nc = 0
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        stripped = line
        sub(/#.*/, "", stripped)
        n = split(stripped, toks, /[ \t;]+/)
        for (k = 1; k <= n; k++) {
          t = toks[k]
          if (t == "if") {
            depth++
            has_else[depth] = 0
          } else if (t == "elif" || t == "else") {
            if (depth > 0) has_else[depth] = 1
          } else if (t == "fi") {
            if (depth > 0) {
              if (has_else[depth] == 0) {
                nc++
                fi_candidates[nc] = i
              }
              depth--
            }
          }
        }
      }
      for (c = 1; c <= nc; c++) {
        fi_i = fi_candidates[c]
        checked = 0
        for (j = fi_i + 1; j <= NR && checked < 6; j++) {
          nxt = lines[j]
          if (nxt ~ /^[ \t]*$/) continue
          ns = nxt
          sub(/^[ \t]*/, "", ns)
          if (ns ~ /^#/) { checked++; continue }
          checked++
          if (nxt ~ /\$\?/ && nxt !~ /#[ \t]*if-status-safe:/) {
            printf "%d:%d:%s\n", fi_i, j, nxt
          }
          break
        }
      }
    }
  ' "$file"
}

for file in "${scan_files[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r fi_line status_line status_content; do
    [ -n "$fi_line" ] || continue
    fail "$file:$status_line: reads \$? on the line immediately after an if-block (whose \`fi\` is at $file:$fi_line) that has no else clause -- per POSIX, an if-construct that takes no branch (false condition, no matching else) reports the WHOLE if statement's own exit status (0), not the tested command's real exit code, so this \$? read can never observe a real failure from that command. Use an explicit 'if CMD; then STATUS=0; else STATUS=\$?; fi' (this project's own established pattern, see scripts/lib/ghcr-retry.sh's ghcr_retry()/scripts/lib/git-fetch-retry.sh's git_fetch_retry()), or an equivalent 'CMD && { ...; return/exit 0; }' whose fallthrough \$? is CMD's own real status, instead -- or mark the line reviewed-safe with a trailing '# if-status-safe: <reason>' comment if this \$? read is provably not consuming the if's masked status. Line: $status_content"
  done < <(check_if_without_else_status "$file")
done

# check_docker_run_stdin_heredoc_missing_i <file>
# Emits one "<lineno>:<invocation>" record per heredoc-fed docker-run
# invocation missing -i. See this file's own header comment above ("THIRD,
# INDEPENDENT CHECK") for the full rationale, the confirmed real incident
# this exists to catch, and this heuristic's documented limits.
check_docker_run_stdin_heredoc_missing_i() {
  local file="$1"
  while IFS=: read -r lineno _rest; do
    [ -n "$lineno" ] || continue

    # A comment line is prose (e.g. this file's own header, or another
    # step's explanatory comment quoting the pattern verbatim), not a real
    # invocation -- skip it, confirmed empirically necessary above.
    local matched_line trimmed_line
    matched_line="$(sed -n "${lineno}p" "$file")"
    trimmed_line="$(printf '%s' "$matched_line" | sed 's/^[[:space:]]*//')"
    case "$trimmed_line" in
      '#'*) continue ;;
    esac

    local start window last_offset invocation
    start=$(( lineno > 20 ? lineno - 20 : 1 ))
    window="$(sed -n "${start},${lineno}p" "$file")"
    last_offset="$(printf '%s\n' "$window" | grep -n "docker run" | tail -1 | cut -d: -f1 || true)"
    if [ -z "$last_offset" ]; then
      # No "docker run" found in the lookback window at all -- not this
      # check's concern (e.g. a heredoc feeding something other than a
      # docker container, or one further away than the window covers).
      continue
    fi
    invocation="$(printf '%s\n' "$window" | tail -n +"$last_offset")"

    if ! grep -qE '(^|[[:space:]])-i([[:space:]]|$)' <<<"$invocation"; then
      printf '%d:%s\n' "$lineno" "docker run invocation feeding a stdin heredoc (bash -s / sh -s) is missing -i -- container stdin is never attached, so the heredoc silently executes nothing while the step still reports success"
    fi
  done < <(grep -noE '(bash|sh)[[:space:]]+-s[[:space:]]*<<' "$file" 2>/dev/null || true)
}

# What: file discovery specific to the third check, independent of
#   scan_files above -- see this file's own header ("THIRD, INDEPENDENT
#   CHECK" / SCOPE) for why this domain is deliberately separate.
# Why: `git ls-files` (not `find`) so a new workflow/action file is
#   automatically covered without a hand-maintained list, and so this only
#   ever scans tracked, committed files -- mirroring scan_files's own
#   rationale above, and its own fail-closed discovery-failure check.
# From: Issue #1095 (F-23)
if ! yaml_scan_files_raw="$(git ls-files -- \
  '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  '.github/actions/**/*.yml' '.github/actions/**/*.yaml')"; then
  printf '::error::check-pipefail-early-exit-grep (docker-run-stdin-heredoc check): `git ls-files` itself failed -- is %s a real git work tree? Not treating this as a clean pass.\n' "$repo_root" >&2
  exit 1
fi

yaml_scan_files=()
if [ -n "$yaml_scan_files_raw" ]; then
  mapfile -t yaml_scan_files < <(sort <<<"$yaml_scan_files_raw")
fi

for file in "${yaml_scan_files[@]}"; do
  [ -f "$file" ] || continue

  while IFS=: read -r lineno finding; do
    [ -n "$lineno" ] || continue
    fail "$file:$lineno: $finding. See scripts/untracked/check-pipefail-early-exit-grep.sh's own header (THIRD, INDEPENDENT CHECK) for the confirmed real incident this guards against."
  done < <(check_docker_run_stdin_heredoc_missing_i "$file")
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-pipefail-early-exit-grep: %d finding(s) across all three checks (early-exiting-consumer-into-pipefail, if-without-else-then-$?, and docker-run-stdin-heredoc-missing--i). See AGENTS.md AG-VAL-029/AG-VAL-032 for the early-exit/if-without-else writeup, issue #1449 for the if-without-else-then-$? class specifically, and issue #1095 (F-23) for the docker-run-stdin-heredoc class.\n' "$failures" >&2
  exit 1
fi

# The literal "$?" text below is prose inside a printf message describing
# this file's own second check, not a real $? expansion reading the
# preceding `if`'s status -- self-flagged by check_if_without_else_status()
# above without this marker, confirmed a false positive by inspection.
printf 'check-pipefail-early-exit-grep: OK (no early-exiting consumer piped from a live producer, no if-without-else block immediately followed by a masked $? read, across %d scanned scripts/Dockerfiles; no docker-run-stdin-heredoc missing -i, across %d scanned workflow/action YAML files).\n' "${#scan_files[@]}" "${#yaml_scan_files[@]}" # if-status-safe: literal "$?" is prose in the message text, not a real status read of the preceding if
