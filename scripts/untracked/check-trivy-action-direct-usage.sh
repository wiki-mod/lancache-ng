#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: AG-VAL-029: only call trivy-action via wrapper action
# Why: Bypasses retry/auth fixes; separate pin drifts without sync
# From: Issue #1535 | PR #1542

# What: Check all trivy-scan-retry calls set both dockerhub-* keys
# Why: Missing either key silently falls back to fewer DB sources
# From: Issue #1535 | PR #1543

# Accepts an optional repo_root argument so a bats test can point it at a
# throwaway fixture tree instead of the real repository.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    repo_root=$(cd "$1" && pwd)
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/../.." && pwd)
fi
cd "$repo_root"

# The one legitimate call site: the centralized pin-owner wrapper itself.
allowed_file=".github/actions/aquasecurity-trivy-action-centralized-version/action.yml"

check_direct_usage() {
    local violations=0
    while IFS=: read -r file _rest; do
        [ -n "$file" ] || continue
        if [ "$file" = "$allowed_file" ]; then
            continue
        fi
        echo "::error::check-trivy-action-direct-usage: $file calls aquasecurity/trivy-action directly -- use ./.github/actions/aquasecurity-trivy-action-centralized-version instead (issue #1535, AG-CI-013)" >&2
        violations=$((violations + 1))
    done < <(grep -rn --include='*.yml' --include='*.yaml' -E "uses: *[\"']?aquasecurity/trivy-action@" .github/workflows .github/actions 2>/dev/null || true)
    return "$violations"
}

# What: State machine validates trivy-scan-retry with: blocks
# Why: Single regex cannot handle indentation, order, gaps
# From: Issue #1535 | PR #1543
check_dockerhub_wiring() {
    local violations=0
    local file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        local out rc
        # What: Disable errexit in awk substitution for violation counting
        # Why: Unprotected non-zero exit would abort at first error file
        # From: Issue #1535 | PR #1543
        set +e
        # SQ carries a real single-quote character into the awk program via
        # -v: the program text itself is bash-single-quoted, so a literal
        # `'` cannot appear inside it directly.
        out=$(awk -v SQ="'" '
            function indent(line,    t) { t = line; sub(/[^ ].*$/, "", t); return length(t) }
            function trimmed(line,    t) { t = line; gsub(/^[ \t]+/, "", t); return t }
            # What: Calculate key column accounting for optional YAML list dash
            # Why: Whitespace-only comparison conflates dash/sibling key shapes
            # From: Issue #1535 | PR #1543
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
            function is_uses_line(t) { return t ~ USES_RE }
            function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
            function unquote(s) { gsub("^[\"" SQ "]|[\"" SQ "]$", "", s); return s }
            function value_of(t,    v) {
                v = t
                sub(/^[^:]*:/, "", v)
                sub(/[ \t]+#.*$/, "", v)
                return unquote(trim(v))
            }
            # What: Validate secret value: accept expected or forwarded inputs
            # Why: Wrapper passes caller value one level down, does not recurse
            # From: Issue #1535 | PR #1543
            function bad_value_reason(v, expected_secret) {
                if (v == "") return "empty value"
                if (v ~ /inputs\./) return ""
                if (v ~ ("secrets\\." expected_secret "([^A-Za-z0-9_]|$)")) return ""
                if (v ~ /secrets\./) return "references the wrong secret (expected secrets." expected_secret ")"
                return "does not reference secrets." expected_secret " or a forwarded inputs.* value"
            }
            function evaluate_block() {
                if (!(hasuser && haspass)) {
                    missing = (!hasuser && !haspass) ? "dockerhub-username and dockerhub-password" : (!hasuser ? "dockerhub-username" : "dockerhub-password")
                    report("with: block is missing " missing)
                    return
                }
                if (userbad != "" || passbad != "") {
                    reasons = (userbad != "" ? "dockerhub-username " userbad : "") (userbad != "" && passbad != "" ? "; " : "") (passbad != "" ? "dockerhub-password " passbad : "")
                    report("with: block has invalid values: " reasons)
                }
            }
            BEGIN {
                # What: Match uses: with optional quotes around wrapper path
                # Why: Unquoted-only regex silently skips valid quoted path calls
                # From: Issue #1535 | PR #1543
                USES_RE = "^-?[ \t]*uses:[ \t]*[\"" SQ "]?\\./\\.github/actions/trivy-scan-retry[\"" SQ "]?[ \t]*(#.*)?$"
            }
            FNR == 1 { state = 0; useline = 0; usesindent = 0 }
            {
                t = trimmed($0)
                if (state == 0) {
                    if (is_uses_line(t)) start_uses($0)
                    next
                }
                if (state == 1) {
                    if (t == "" || t ~ /^#/) next
                    if (t ~ /^with:[ \t]*(#.*)?$/ && keycol($0, "with:") == usesindent) {
                        state = 2
                        withindent = indent($0)
                        hasuser = 0; haspass = 0; userbad = ""; passbad = ""
                        next
                    }
                    report("has no with: block (missing dockerhub-username/dockerhub-password wiring)")
                    state = 0
                    if (is_uses_line(t)) start_uses($0)
                    next
                }
                if (state == 2) {
                    if (t == "" || t ~ /^#/) next
                    if (indent($0) <= withindent) {
                        evaluate_block()
                        state = 0
                        if (is_uses_line(t)) start_uses($0)
                        next
                    }
                    if (t ~ /^dockerhub-username:/) { hasuser = 1; userbad = bad_value_reason(value_of(t), "DOCKERHUB_USERNAME") }
                    if (t ~ /^dockerhub-password:/) { haspass = 1; passbad = bad_value_reason(value_of(t), "DOCKERHUB_TOKEN") }
                    next
                }
            }
            END {
                if (state == 2) {
                    evaluate_block()
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
                echo "::error::check-trivy-action-direct-usage: $line -- both dockerhub-username and dockerhub-password must be set to a real secrets./inputs.* reference (issue #1535 follow-up)" >&2
            done
        fi
        violations=$((violations + rc))
    done < <(grep -rlE --include='*.yml' --include='*.yaml' "uses: *[\"']?\./\.github/actions/trivy-scan-retry" .github/workflows .github/actions 2>/dev/null || true)
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

echo "check-trivy-action-direct-usage: no direct aquasecurity/trivy-action call sites outside $allowed_file, and every trivy-scan-retry call site sets dockerhub-username/dockerhub-password"
