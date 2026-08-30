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
#        workflow-image-defaults|repository-case]; omitted runs every check.
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

    # What: ARG BUILD_TOOLS_IMAGE/UTILITIES_IMAGE defaults to :latest
    # Why: FROM-line check doesn't detect ARG :latest indirection
    # From: Issue #1095 | PR #1687
    local mutable_arg_defaults
    mutable_arg_defaults=$(grep -nE 'ARG (BUILD_TOOLS_IMAGE|UTILITIES_IMAGE).*:latest' services/*/Dockerfile || true)
    if [[ -n "$mutable_arg_defaults" ]]; then
        printf "%b[DOCKERFILE BUILD TOOLS]%b BUILD_TOOLS_IMAGE/UTILITIES_IMAGE ARG defaults use :latest (override-able at build time):\n" "$YELLOW" "$NC"
        printf '%s\n' "$mutable_arg_defaults"
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

# What: flags raw ${{ github.repository }} for GHCR safety
# Why: GHCR lowercase requirement; github.repository not guaranteed
# From: Issue #1504
check_repository_case_expressions() {
    # What: matches ${{ github.repository }} with braces fully escaped.
    # Why: escape braces for POSIX grep compatibility in containers
    # From: Issue #1504
    local pattern='\$\{\{ *github\.repository *\}\}'
    # What: expected baseline count for github.repository expressions
    # Why: must sync with real count in same commit, or guard breaks
    # From: Issue #1504
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

# What: --only flag runs one named check instead of full sweep
# Why: allows single check gating without blocking other checks
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
