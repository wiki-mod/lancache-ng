#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: AG-VAL-029 standing check -- aquasecurity/trivy-action must only be
# invoked from the centralized pin-owner wrapper action.
# Why: a direct call site bypasses trivy-scan-retry's own retry/auth fix,
# and a second pin outside the one owner drifts.
# From: PR #1542, Issue #1535 | Issue #1095

# What: check_dockerhub_wiring() is a second check -- every real
# trivy-scan-retry call site must set both dockerhub-* keys.
# Why: a caller that forgets either key silently falls back to only the
# first two DB-source tiers, unnoticed.
# From: PR #1543, Issue #1535

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

# What: Forward-scanning state machine that confirms each trivy-scan-retry
# call site's with: block sets both dockerhub keys with valid values.
# Why: a single regex can't cover indentation depth, key order, interleaved
# comments, and a missing with: block all at once (AG-VAL-036).
# From: PR #1543, Issue #1535
check_dockerhub_wiring() {
    local violations=0
    local file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        local out rc
        # What: Toggles errexit off around the awk substitution below, whose
        # own `exit bad + 0` returns the per-file violation count.
        # Why: an unprotected non-zero exit under set -e would abort on the
        # first offending file instead of collecting every violation.
        # From: PR #1543, Issue #1535
        set +e
        # SQ carries a real single-quote character into the awk program via
        # -v: the program text itself is bash-single-quoted, so a literal
        # `'` cannot appear inside it directly.
        out=$(awk -v SQ="'" '
            function indent(line,    t) { t = line; sub(/[^ ].*$/, "", t); return length(t) }
            function trimmed(line,    t) { t = line; gsub(/^[ \t]+/, "", t); return t }
            # What: Column where `key` (e.g. "uses:") starts, regardless of
            # a preceding YAML list dash.
            # Why: raw leading-whitespace comparison conflates `- uses:` and
            # sibling-key `uses:` shapes, since the dash eats 2 columns.
            # From: PR #1543, Issue #1535
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
            # What: Accepts the expected secret or a forwarded inputs.*
            # pass-through; rejects an empty or a wrong-secret value.
            # Why: a wrapper action (trivy-scan-with-cache) relays a
            # caller-owned value one level down -- not chased any deeper.
            # From: PR #1543, Issue #1535
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
                # What: Matches uses: with an optional single or double
                # quote around the wrapper path.
                # Why: an unquoted-only pattern silently skips a valid
                # `uses: "./path"` call site (AG-VAL-036).
                # From: PR #1543, Issue #1535
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
