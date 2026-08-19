#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI image pinning helper: scans .github/workflows and Dockerfiles for mutable
# image references (floating tags like :latest, @v4-style action references
# without SHA pins, untagged base images, and raw un-lowercased
# github.repository expressions in GHCR paths) and reports them. Intended as
# a transparency tool to make mixed mutable+immutable states visible; can be
# used as a CI gate to enforce pinning (exit 1 if violations found) or as an
# informational report (exit 0, violations reported to stdout/stderr).
# Usage: check-mutable-refs.sh [--only action-refs|dockerfile-base-images|
#        workflow-image-defaults|repository-case] -- omitted runs every
#        check; shellcheck-and-standing-guards/action.yml currently wires up
#        only --only repository-case in CI (the other three checks have
#        never been gated on in CI and their current pass/fail state is
#        unverified -- see this file's own From: pointer below for the
#        tracking issue and the scoping reason).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"

# Colors for terminal output (disabled if stdout is not a TTY)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    NC='\033[0m'  # No Color
else
    RED=''
    YELLOW=''
    GREEN=''
    NC=''
fi

violations=0
warnings=0

# Check GitHub Actions for @v<number> style (non-SHA) references.
# These should be pinned to @<sha> with a comment showing the version.
check_action_refs() {
    local pattern='uses:.*@v[0-9]'
    local matches
    matches=$(grep -rn "$pattern" .github/workflows/*.yml || true)
    if [[ -n "$matches" ]]; then
        printf "%b[ACTION REFS]%b Floating action version tags (should be pinned to @sha):\n" "$RED" "$NC"
        printf '%s\n' "$matches"
        violations=$((violations + 1))
        return 1
    fi
    return 0
}

# Check Dockerfiles for untagged or mutable image references in FROM lines.
# Exception: ARG defaults for BUILD_TOOLS_IMAGE that reference :latest are noted
# as warnings rather than violations, since they are overridden at build time.
check_dockerfile_base_images() {
    local violations_found=0

    # Check for mutable :latest tags in FROM lines (excluding ARG lines).
    # This catches both 'FROM image:latest' and 'FROM image' (untagged = latest).
    local latest_pattern='FROM .*:latest'
    local untagged_pattern='^FROM [a-z0-9./:]*[a-z0-9/]$'  # No tag at all

    # Find any FROM ... :latest except those explicitly documented in comments
    local matches
    matches=$(grep -nE "$latest_pattern" services/*/Dockerfile || true)
    if [[ -n "$matches" ]]; then
        printf "%b[DOCKERFILE BASE IMAGES]%b :latest tags in FROM statements:\n" "$RED" "$NC"
        printf '%s\n' "$matches"
        violations_found=1
    fi

    # Find FROM lines with no tag at all (implicitly :latest).
    local untagged_matches
    untagged_matches=$(grep -nE "$untagged_pattern" services/*/Dockerfile || true)
    if [[ -n "$untagged_matches" ]]; then
        printf "%b[DOCKERFILE BASE IMAGES]%b untagged FROM statements (implicitly :latest):\n" "$RED" "$NC"
        printf '%s\n' "$untagged_matches"
        violations_found=1
    fi

    # Warn about BUILD_TOOLS_IMAGE defaults using :latest (override-able, not a hard violation)
    local build_tools_defaults
    build_tools_defaults=$(grep -n 'ARG BUILD_TOOLS_IMAGE.*:latest' services/*/Dockerfile || true)
    if [[ -n "$build_tools_defaults" ]]; then
        printf "%b[DOCKERFILE BUILD TOOLS]%b BUILD_TOOLS_IMAGE ARG defaults use :latest (override-able at build time):\n" "$YELLOW" "$NC"
        printf '%s\n' "$build_tools_defaults"
        warnings=$((warnings + 1))
    fi

    if [[ $violations_found -eq 1 ]]; then
        violations=$((violations + 1))
        return 1
    fi
    return 0
}

# Check workflow environment variable defaults for mutable image references.
# Look for lines setting BUILD_TOOLS_IMAGE or similar to :latest tags.
check_workflow_image_defaults() {
    local pattern='BUILD_TOOLS_IMAGE=.*:latest'
    local matches
    matches=$(grep -n "$pattern" .github/workflows/*.yml || true)
    if [[ -n "$matches" ]]; then
        printf "%b[WORKFLOW DEFAULTS]%b BUILD_TOOLS_IMAGE environment defaults use :latest:\n" "$YELLOW" "$NC"
        printf '%s\n' "$matches"
        warnings=$((warnings + 1))
        return 0  # Warning, not violation
    fi
    return 0
}

# Check for raw (non-lowercased) github.repository expressions. GHCR requires
# a lowercase owner/repo; github.repository mirrors the real GitHub-declared
# casing and is not guaranteed lowercase (issue #1095, finding G1 -- this
# broke during a real repo rename). Bash-reachable sites (an env: value
# consumed inside that step's own run: block) must resolve this via the
# shared dmeta_ghcr_repo() helper (scripts/lib/docker-metadata.sh) instead,
# exactly like build-push.yml's own ~15 existing "What: reads the single
# declared, lowercased GHCR owner/repo" call sites (issue #1095 G1 / PR
# #1503).
#
# Each file's expected count below is a MIX of three known categories, not
# one uniform kind of site -- naming them here so a future reader classifies
# a NEW site correctly instead of assuming every raw match is the same kind:
#   - pure-YAML `with:` step inputs (images:/image-ref:/subject-name:,
#     consumed by third-party actions such as docker/metadata-action).
#     GitHub Actions' own ${{ }} expression syntax has no lowercase()
#     function, so these can't call the bash helper at all; fixing them
#     needs a precomputed job/step output instead -- documented as
#     follow-up rather than implemented here, given the line-count
#     ceiling build-push.yml is already close to (AG-CI-021).
#     build-push.yml: 27 | build-tools.yml: 0 | build-push-hosted-fallback.yml: 4
#   - env: values in a GHCR image-path context that have NOT yet been
#     confirmed bash-reachable-and-fixable the way build-push.yml:2847 (PR
#     #1523's regression) was -- classification is open, not yet fixed
#     here on purpose.
#     build-push.yml: 0 | build-tools.yml: 1 | build-push-hosted-fallback.yml: 1
#   - non-GHCR uses (e.g. `REPO: ${{ github.repository }}` feeding `gh pr
#     view --repo`) where GitHub's own API/CLI is case-insensitive on repo
#     path, so casing is out of this check's concern and these are expected
#     to stay exactly as-is.
#     build-push.yml: 2 | build-tools.yml: 0 | build-push-hosted-fallback.yml: 0
#
# This check holds each file's TOTAL raw count as a known, counted baseline,
# not an approved-forever exception list: it fails the moment the real count
# drifts from the expected number below in EITHER direction, so a newly-
# added raw site (regression) and a newly-fixed site (stale baseline) both
# surface instead of going silent.
check_repository_case_expressions() {
    # Braces are explicitly escaped (\{ \}) rather than left bare: GNU grep
    # treats a syntactically-invalid ERE interval as a literal brace, but a
    # strict POSIX grep is not required to, and this pattern's real
    # container (the build-tools image, not this dev host) is not
    # guaranteed to be GNU grep -- an unescaped bare '{{'/'}}' silently
    # under-matching would make this guard report a false "regression fixed"
    # instead of catching a real one.
    local pattern='\$\{\{ *github\.repository *\}\}'
    # file -> expected TOTAL raw-expression count (all three categories
    # above combined), established 2026-08-19 after fixing build-push.yml's
    # own line-2847 PR-#1523 regression. Update the number
    # here in the SAME commit that changes the real count, with a one-line
    # reason in that commit message (fixed N sites | classified N env: sites
    # as bash-reachable and fixed them | added a legitimate new non-GHCR
    # site).
    local -A expected_counts=(
        [.github/workflows/build-push.yml]=29
        [.github/workflows/build-tools.yml]=1
        [.github/workflows/build-push-hosted-fallback.yml]=5
    )
    local file expected actual mismatch=0

    for file in "${!expected_counts[@]}"; do
        expected="${expected_counts[$file]}"
        actual=$(grep -cE "$pattern" "$file" || true)
        if [[ "$actual" -ne "$expected" ]]; then
            printf "%b[REPOSITORY CASE]%b %s: expected %d raw github.repository expression(s), found %d.\n" "$RED" "$NC" "$file" "$expected" "$actual"
            if [[ "$actual" -gt "$expected" ]]; then
                printf '  A new raw ${{ github.repository }} expression was added. If it is bash-reachable, use dmeta_ghcr_repo() instead (see scripts/lib/docker-metadata.sh), per issue #1095 (G1). If it is a genuine new pure-YAML or non-GHCR site, raise the expected count above with a reason.\n'
            else
                printf '  Fewer raw expressions than expected -- likely a site was fixed. Lower the expected count above to match, so this baseline stays accurate.\n'
            fi
            mismatch=1
        fi
    done

    if [[ "$mismatch" -eq 1 ]]; then
        violations=$((violations + 1))
        return 1
    fi
    return 0
}

# Summary report.
report() {
    echo
    printf '%b=== CI Image Pinning Check ===%b\n' "$GREEN" "$NC"

    if [[ $violations -eq 0 && $warnings -eq 0 ]]; then
        printf '%bAll checked references are pinned or documented as mutable.%b\n' "$GREEN" "$NC"
        return 0
    fi

    if [[ $violations -gt 0 ]]; then
        printf '%b✗ Found %d violation(s): mutable references that should be pinned.%b\n' "$RED" "$violations" "$NC"
    fi

    if [[ $warnings -gt 0 ]]; then
        printf '%b⚠ Found %d warning(s): mutable references with documented exceptions.%b\n' "$YELLOW" "$warnings" "$NC"
    fi

    if [[ $violations -gt 0 ]]; then
        printf '\nSee docs/ci-image-pinning-policy.md for remediation steps.\n'
        return 1
    fi

    return 0
}

# What: --only NAME runs exactly one named check instead of the full sweep;
# omitted (the default) runs everything below, unchanged from this script's
# original behavior.
# Why: shellcheck-and-standing-guards/action.yml (the composite action that
# actually runs guard scripts in CI, AG-VAL-016) can only wire up the one
# check this project has verified clean (repository-case) without also
# gating CI on the other three checks' current, never-yet-evaluated state --
# see the tracking issue's own PR body for that scoping decision.
# From: Issue #1504
only_check=""
case "${1:-}" in
    --only)
        only_check="${2:?--only requires a check name}"
        ;;
    --only=*)
        only_check="${1#--only=}"
        ;;
    "") ;;
    *)
        printf 'check-mutable-refs: unknown argument: %s\n' "$1" >&2
        printf 'Usage: check-mutable-refs.sh [--only action-refs|dockerfile-base-images|workflow-image-defaults|repository-case]\n' >&2
        exit 2
        ;;
esac

run_check() {
    local name="$1" label="$2"
    shift 2
    [[ -z "$only_check" || "$only_check" == "$name" ]] || return 0
    echo "$label"
    "$@" || true
}

run_check action-refs "Checking GitHub Actions references..." check_action_refs
run_check dockerfile-base-images "Checking Dockerfile base images..." check_dockerfile_base_images
run_check workflow-image-defaults "Checking workflow image defaults..." check_workflow_image_defaults
run_check repository-case "Checking github.repository case-safety (issue #1504/#1095 G1)..." check_repository_case_expressions

if [[ -n "$only_check" && "$violations" -eq 0 && "$warnings" -eq 0 ]]; then
    printf 'check-mutable-refs --only %s: OK\n' "$only_check"
    exit 0
fi

report

# Exit with 1 if violations found (failures), 0 if only warnings or all clean.
if [[ $violations -gt 0 ]]; then
    exit 1
fi

exit 0
