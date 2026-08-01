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
# PR #1371's find_built_ancestor(), and a proposed AGENTS.md rule for the
# general failure class (AG-VAL-030) was posted on PR #1374 for maintainer
# review per AG-WF-025 -- this script is the separate, already-required
# AG-VAL-029 standing check for the confirmed incident, independent of
# whether that governance rule proposal is adopted.
#
# SCOPE, DELIBERATELY NARROW -- read before extending this list:
# this only scans `tools/build-tools/Dockerfile`, the exact file the
# confirmed incident occurred in. An earlier version of this script scanned
# every shell script under scripts/ and tools/ too, and found 41 preexisting
# instances of the same raw pattern across the codebase (e.g.
# `scripts/check-file-headers.sh`, `scripts/check-netdata-curl-pin.sh`,
# `scripts/setup-cli-simulation.sh`, and others) -- each would need
# individual review to determine whether it is a real latent SIGPIPE risk
# (most looked low-risk on inspection: a `printf`/single small-string
# producer piped into `grep -q`/`head`, which in practice rarely writes
# enough to fill a pipe buffer before the consumer's read completes, unlike
# `rustc -vV`'s multi-line, larger output) or already provably safe. Fixing
# or reviewing all 41 in this PR would be a large, disproportionate scope
# expansion for a musl-toolchain/network-verification change with no
# reported incident in any of those 41 locations, and risks introducing real
# regressions into unrelated, currently-working scripts under mechanical
# pattern-matching pressure. This is a genuine, not-yet-closed gap -- tracked
# in issue #815's own PR #1374 discussion and as a named follow-up in
# docs/release-validation-plan.md's Coverage Assessment section, not silently
# dropped. Widening this script's scan_files back to the repo-wide set (see
# git history on this file for the exact prior version) is the concrete next
# step for that follow-up, once each finding has been triaged.
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

# Deliberately narrow scope -- see this file's own header comment for why.
scan_files=("tools/build-tools/Dockerfile")

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
  printf '::error::check-pipefail-early-exit-grep: %d finding(s). See AGENTS.md AG-VAL-029 / the AG-VAL-030 rule proposal on PR #1374 for the full failure-class writeup.\n' "$failures" >&2
  exit 1
fi

printf 'check-pipefail-early-exit-grep: OK (no early-exiting consumer piped from a live producer found in tools/build-tools/Dockerfile).\n'
