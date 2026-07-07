#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI image pinning helper: scans .github/workflows and Dockerfiles for mutable
# image references (floating tags like :latest, @v4-style action references
# without SHA pins, untagged base images) and reports them. Intended as a
# transparency tool to make mixed mutable+immutable states visible; can be
# used as a CI gate to enforce pinning (exit 1 if violations found) or as an
# informational report (exit 0, violations reported to stdout/stderr).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
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

echo "Checking GitHub Actions references..."
check_action_refs || true

echo "Checking Dockerfile base images..."
check_dockerfile_base_images || true

echo "Checking workflow image defaults..."
check_workflow_image_defaults || true

report

# Exit with 1 if violations found (failures), 0 if only warnings or all clean.
if [[ $violations -gt 0 ]]; then
    exit 1
fi

exit 0
