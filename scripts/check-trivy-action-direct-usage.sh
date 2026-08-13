#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# AG-VAL-029 standing check for issue #1535: aquasecurity/trivy-action must
# only ever be invoked from inside .github/actions/trivy-scan-retry/action.yml
# (the AG-CI-013 retry + GHCR-first-DB-mirror + authenticated-pull wrapper),
# never directly from a workflow or a different composite action. A direct
# call site bypasses that wrapper's retry/auth/mirror-ordering fix entirely
# and silently reintroduces the exact zero-retry gap that caused two real CI
# failures (PR #1503, PR #1500) before this wrapper existed. A point fix
# alone would not have prevented the *next* direct call site from making the
# same mistake, so this exists as a repeatable guard rather than only a
# one-time cleanup (AG-VAL-029).
#
# Widened scope (issue #1535 follow-up, 2026-08-13): once trivy-scan-retry
# grew a third, directly-authenticated Docker Hub DB-source tier, a caller
# of the wrapper that forgets to wire dockerhub-username/dockerhub-password
# silently falls back to only the first two tiers -- exactly the same
# "the fix exists, but the next call site doesn't use it" failure shape as
# the direct-usage check above, just one level deeper (inside the wrapper's
# own contract instead of around it). check_dockerhub_wiring() below is a
# second, independent check for that: it walks every real
# `uses: ./.github/actions/trivy-scan-retry` call site in both
# .github/workflows and .github/actions -- a real call site can sit one
# level removed from a workflow file (.github/actions/trivy-scan-with-cache
# wraps trivy-scan-retry and is itself called from build-push.yml, a shape
# a workflows-only search silently missed until a repo-wide grep caught it
# during this same task) -- and flags any whose `with:` block is missing
# either key. Kept in this
# same file (not split into a second script) because both checks exist to
# answer the same underlying question -- "is every real call site actually
# using the wrapper's full, current contract" -- for the one wrapper this
# repository has (AG-CODE-011: searched scripts/ for an existing YAML
# with:-block indentation scanner before writing check_dockerhub_wiring()'s
# own awk state machine below; found none to reuse).
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so a bats test can point it at a throwaway fixture tree instead of
# mutating or depending on the real repository.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    repo_root=$(cd "$1" && pwd)
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/.." && pwd)
fi
cd "$repo_root"

# The one legitimate call site: the wrapper action's own four attempt steps.
allowed_file=".github/actions/trivy-scan-retry/action.yml"

check_direct_usage() {
    local violations=0
    while IFS=: read -r file _rest; do
        [ -n "$file" ] || continue
        if [ "$file" = "$allowed_file" ]; then
            continue
        fi
        echo "::error::check-trivy-action-direct-usage: $file calls aquasecurity/trivy-action directly -- use ./.github/actions/trivy-scan-retry instead (issue #1535, AG-CI-013)" >&2
        violations=$((violations + 1))
    done < <(grep -rn --include='*.yml' --include='*.yaml' 'uses: *aquasecurity/trivy-action@' .github/workflows .github/actions 2>/dev/null || true)
    return "$violations"
}

# Walks every `uses: ./.github/actions/trivy-scan-retry` step in a workflow
# file and confirms its `with:` block sets both dockerhub-username and
# dockerhub-password. A small forward-scanning state machine, not a single
# grep, because a call site's real shape varies on every axis a naive regex
# would miss (AG-VAL-036): indentation depth (computed relative to each
# call site's own `uses:` line, never a hardcoded column), key order inside
# `with:` (both keys are searched for independently, order-agnostic),
# interleaved comment lines (skipped explicitly), a call site with no
# `with:` block at all (flagged as its own case, not silently treated as
# "0 keys found"), and a call site missing only one of the two keys
# (flagged distinctly from missing both). Real call sites in this repo
# format `uses:`/`with:` as sibling keys of a `- name: ...` step (not
# `- uses: ...`), so the scanner does not require a leading `-`.
check_dockerhub_wiring() {
    local violations=0
    local file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        local out rc
        # awk's own `exit bad + 0` (below) intentionally returns the
        # per-file violation count as this command substitution's exit
        # status. Under this script's `set -e`, an unprotected non-zero
        # exit here would abort the whole script on the *first* offending
        # file instead of collecting every violation across all files --
        # explicitly toggling errexit off/on around just this one
        # substitution (rather than trusting -e's exemption rules for
        # commands inside a function/loop body, which do not reliably
        # cover this case) makes the intended behavior the actual,
        # executed behavior rather than an assumption (AG-VAL-030).
        set +e
        out=$(awk '
            function indent(line,    t) { t = line; sub(/[^ ].*$/, "", t); return length(t) }
            function trimmed(line,    t) { t = line; gsub(/^[ \t]+/, "", t); return t }
            # Column where `key` (e.g. "uses:", "with:") actually starts in
            # the raw line, whether or not it is preceded by a YAML list
            # dash. Needed because this repos own real call sites mix two
            # step-item shapes: `- name: ...` (a step-start marker) with
            # `uses:`/`with:` as later SIBLING keys at indent+2, versus a
            # test/edge-case shape like `- uses: ...` where the dash and
            # `uses:` share one line and `with:` is a CHILD at indent+2 of
            # the dash itself. Comparing raw leading-whitespace counts
            # conflates these two cases (the dash eats 2 columns that
            # belong to the key, not the line); comparing the column the
            # key text itself starts at does not, since a sibling `with:`
            # and a same-step `uses:` key always start at the same column
            # either way.
            function keycol(line, key,    i) { i = index(line, key); return (i == 0) ? -1 : i - 1 }
            function report(reason) {
                print FILENAME ":" useline ": trivy-scan-retry call site " reason
                bad++
            }
            function start_uses(line) {
                state = 1
                useline = FNR
                usesindent = keycol(line, "uses:")
            }
            FNR == 1 { state = 0; useline = 0; usesindent = 0 }
            {
                t = trimmed($0)
                if (state == 0) {
                    if (t ~ /^-?[ \t]*uses:[ \t]*\.\/\.github\/actions\/trivy-scan-retry[ \t]*(#.*)?$/) {
                        start_uses($0)
                    }
                    next
                }
                if (state == 1) {
                    if (t == "" || t ~ /^#/) next
                    if (t ~ /^with:[ \t]*(#.*)?$/ && keycol($0, "with:") == usesindent) {
                        state = 2
                        withindent = indent($0)
                        hasuser = 0; haspass = 0
                        next
                    }
                    report("has no with: block (missing dockerhub-username/dockerhub-password wiring)")
                    state = 0
                    if (t ~ /^-?[ \t]*uses:[ \t]*\.\/\.github\/actions\/trivy-scan-retry[ \t]*(#.*)?$/) start_uses($0)
                    next
                }
                if (state == 2) {
                    if (t == "" || t ~ /^#/) next
                    if (indent($0) <= withindent) {
                        if (!(hasuser && haspass)) {
                            missing = (!hasuser && !haspass) ? "dockerhub-username and dockerhub-password" : (!hasuser ? "dockerhub-username" : "dockerhub-password")
                            report("with: block is missing " missing)
                        }
                        state = 0
                        if (t ~ /^-?[ \t]*uses:[ \t]*\.\/\.github\/actions\/trivy-scan-retry[ \t]*(#.*)?$/) start_uses($0)
                        next
                    }
                    if (t ~ /^dockerhub-username:/) hasuser = 1
                    if (t ~ /^dockerhub-password:/) haspass = 1
                    next
                }
            }
            END {
                if (state == 2 && !(hasuser && haspass)) {
                    missing = (!hasuser && !haspass) ? "dockerhub-username and dockerhub-password" : (!hasuser ? "dockerhub-username" : "dockerhub-password")
                    report("with: block is missing " missing)
                } else if (state == 1) {
                    report("has no with: block (missing dockerhub-username/dockerhub-password wiring)")
                }
                exit bad + 0
            }
        ' "$file")
        rc=$?
        set -e
        if [ -n "$out" ]; then
            echo "$out" | while IFS= read -r line; do
                echo "::error::check-trivy-action-direct-usage: $line -- both dockerhub-username and dockerhub-password must be set (issue #1535 follow-up)" >&2
            done
        fi
        violations=$((violations + rc))
    done < <(grep -rl --include='*.yml' --include='*.yaml' 'uses: *\./\.github/actions/trivy-scan-retry' .github/workflows .github/actions 2>/dev/null || true)
    return "$violations"
}

direct_violations=0
check_direct_usage || direct_violations=$?

wiring_violations=0
check_dockerhub_wiring || wiring_violations=$?

total=$((direct_violations + wiring_violations))
if [ "$total" -gt 0 ]; then
    echo "::error::check-trivy-action-direct-usage: found $direct_violations direct aquasecurity/trivy-action call site(s) and $wiring_violations trivy-scan-retry call site(s) missing dockerhub wiring" >&2
    exit 1
fi

echo "check-trivy-action-direct-usage: no direct aquasecurity/trivy-action call sites outside .github/actions/trivy-scan-retry/action.yml, and every trivy-scan-retry call site sets dockerhub-username/dockerhub-password"
