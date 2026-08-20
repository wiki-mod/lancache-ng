#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard (AG-VAL-029) for a confirmed real bug: a `docker run`
# invocation that feeds its command to the container via a `bash -s <<'X'` /
# `sh -s <<'X'` stdin heredoc, but omits `-i`, silently executes nothing.
# Without `-i`, `docker run` never attaches the container's stdin at all, so
# the containerized shell reads immediate EOF and exits 0 having run none of
# the heredoc's commands -- a green step, not a visible failure.
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
# vex.openvex.json, no <service>.cdx.json. Fixed in Issue #1095 (F-22)'s PR
# by adding `-i` to all three invocations.
#
# Every stdin-heredoc `docker run` already in this repo's `validate-compose`
# job (the VALIDATE_* steps) already carries `-i` -- this guard exists so a
# future new heredoc-fed docker run invocation is not added without it,
# rather than relying on someone noticing a silently-empty release asset
# months later, the way this specific bug went unnoticed since PR #1194.
#
# SCOPE: workflow YAML under .github/workflows/**/*.yml(.yaml) and composite
# actions under .github/actions/**/*.yml(.yaml) -- both extensions genuinely
# occur in this tree (.github/workflows/update-changelog.yaml,
# .github/actionlint.yaml), so both must be matched -- the two places this repo defines
# `docker run` invocations. A `docker run` command is matched heuristically:
# this repo's own established convention (confirmed by inspecting every
# current instance before writing this guard, per AG-VAL-036) is always
# `docker run --rm [-i] \` immediately followed by zero or more `-e`/`-v`
# flag lines, then the image reference, then the command to run -- when that
# command ends in `bash -s <<'MARKER'` or `sh -s <<'MARKER'`, `-i` is
# required somewhere in the flags. This intentionally does not try to parse
# arbitrary `docker run` argument ordering/syntax in general -- it targets
# the one call-site shape this repo actually uses, the same "match the real
# established convention, not the whole possible grammar" scoping
# check-pipefail-early-exit-grep.sh's own header documents for its own
# heuristic.
set -euo pipefail

exit_code=0

while IFS= read -r -d '' file; do
  # Locate every heredoc-fed shell invocation line.
  while IFS=: read -r lineno _rest; do
    [ -n "$lineno" ] || continue

    # A comment line (this script's own header/step comments explaining this
    # exact pattern being the confirmed real example: `sed`'s trim strips
    # leading whitespace so an indented `# ... bash -s <<'MARKER' ...` line
    # inside a YAML `run:` block still matches) is prose, not a real
    # invocation -- skip it. Confirmed empirically: without this check, this
    # guard flagged its own explanatory comment in vex-regenerate.yml as a
    # missing-`-i` violation, a real false positive found by actually
    # running this script (AG-VAL-030).
    matched_line="$(sed -n "${lineno}p" "$file")"
    trimmed_line="$(printf '%s' "$matched_line" | sed 's/^[[:space:]]*//')"
    case "$trimmed_line" in
      '#'*) continue ;;
    esac

    # Look back up to 20 lines for the start of this invocation's `docker
    # run` command -- generous enough to cover this repo's longest real
    # flag lists (the VEX/SBOM upload steps use 4-5 -e/-v lines) without
    # accidentally reaching into an unrelated, earlier docker run block.
    start=$(( lineno > 20 ? lineno - 20 : 1 ))
    window="$(sed -n "${start},${lineno}p" "$file")"

    # Only the block from the NEAREST preceding "docker run" onward is the
    # actual invocation this heredoc belongs to -- anchoring on the first
    # match in the window (e.g. a plain `sed -n '/docker run/,$p'`) is wrong
    # whenever two docker run invocations fall inside the same 20-line
    # window (this repo's real "Attach OpenVEX document to the release"
    # step has exactly that shape: a plain generate call, then the
    # heredoc-fed upload call ~10 lines later) -- that would silently pass a
    # genuine violation whenever an earlier, unrelated invocation in the
    # window happens to carry -i. grep -n's own within-window line numbers
    # plus `tail -1` find the LAST match's offset without needing `tac`
    # (not guaranteed present on every base this project's build-tools image
    # might use, AG-KD-009); `tail -n +<offset>` then slices from there.
    # `|| true` is required, not cosmetic: under `set -o pipefail`, `grep -n`
    # finding no match in a window with no preceding "docker run" (a real,
    # expected case, handled explicitly by the -z check below) exits 1, and
    # that failure would otherwise propagate through the pipeline into this
    # assignment -- which `set -e` treats as a fatal error on the assignment
    # itself, aborting the whole script with no message at all. Confirmed
    # empirically (a first version of this script without `|| true` did
    # exactly that, exit 1, zero output, real bug in the guard itself before
    # this fix -- exactly the class AGENTS.md's AG-VAL-029 Known Gaps notes
    # already document for this project).
    last_offset="$(printf '%s\n' "$window" | grep -n "docker run" | tail -1 | cut -d: -f1 || true)"
    if [ -z "$last_offset" ]; then
      # No "docker run" found in the lookback window at all -- not this
      # guard's concern (e.g. a heredoc feeding something other than a
      # docker container, or one further away than the window covers).
      continue
    fi
    invocation="$(printf '%s\n' "$window" | tail -n +"$last_offset")"

    if ! grep -qE '(^|[[:space:]])-i([[:space:]]|$)' <<<"$invocation"; then
      echo "::error file=${file},line=${lineno}::docker run invocation feeding a stdin heredoc (bash -s / sh -s) is missing -i -- container stdin is never attached, so the heredoc silently executes nothing while the step still reports success. See scripts/untracked/check-docker-run-stdin-heredoc.sh's header for the confirmed real incident this guards against." >&2
      exit_code=1
    fi
  done < <(grep -noE '(bash|sh)[[:space:]]+-s[[:space:]]*<<' "$file" 2>/dev/null || true)
done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)

if [ "$exit_code" -eq 0 ]; then
  echo "No docker run invocations feeding a stdin heredoc without -i found."
fi

exit "$exit_code"
