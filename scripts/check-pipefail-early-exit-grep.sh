#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# scripts/**, tools/**, and services/**, plus setup.sh (the production
# installer). `services/**` was added later: this file's own header had
# claimed "repo-wide" coverage while its glob list actually omitted every
# service entrypoint, which is exactly where a real, previously-undetected
# instance of this failure class was later found and fixed (a `set -e`
# script silently dying on an unguarded `printf ... | grep -qi` after a
# multi-line capture). This was originally scoped to only
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
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

  # Scope to files that use pipefail at all -- an early-exiting consumer
  # piped from a still-writing producer is harmless without it (the
  # pipeline's exit status would just reflect the last command's own,
  # SIGPIPE or not, and nothing downstream treats that as a failure).
  if ! grep -qF 'pipefail' "$file"; then
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
    fail "$file:$line_num: pipes a live command into an early-exiting consumer (grep -q/-m, head, or sed -n) in a file that uses pipefail -- this can fail with an unrelated-looking SIGPIPE (exit 141) if the producer is still writing when the consumer exits. Capture the producer's output into a variable first, then apply the consumer to the variable (e.g. via a here-string), or mark the line reviewed-safe with a trailing '# pipefail-safe: <reason>' comment if the producer is provably single-line/already-finished. Line: $trimmed"
  done < <(grep -nE "$pattern" "$file" || true)
done

if [ "$failures" -gt 0 ]; then
  printf '::error::check-pipefail-early-exit-grep: %d finding(s). See AGENTS.md AG-VAL-029/AG-VAL-032 for the full failure-class writeup.\n' "$failures" >&2
  exit 1
fi

printf 'check-pipefail-early-exit-grep: OK (no early-exiting consumer piped from a live producer found across %d scanned scripts/Dockerfiles).\n' "${#scan_files[@]}"
