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
#        workflow-image-defaults|repository-case|action-pin-baseline|
#        build-tools-default-sites]; omitted runs every check.
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

shopt -s nullglob
github_workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
github_action_files=(.github/actions/*/action.yml .github/actions/*/action.yaml)
shopt -u nullglob
github_scan_files=("${github_workflow_files[@]}" "${github_action_files[@]}")

# Check GitHub Actions for @v<number> style (non-SHA) references.
# These should be pinned to @<sha> with a comment showing the version.
check_action_refs() {
    local pattern='uses:.*@v[0-9]'
    local matches
    matches=$(grep -rn "$pattern" "${github_scan_files[@]}" || true)
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
    matches=$(grep -n "$pattern" "${github_workflow_files[@]}" || true)
    if [[ -n "$matches" ]]; then
        printf "%b[WORKFLOW DEFAULTS]%b BUILD_TOOLS_IMAGE environment defaults use :latest:\n" "$YELLOW" "$NC"
        printf '%s\n' "$matches"
        warnings=$((warnings + 1))
        return 0  # Warning, not violation
    fi
    return 0
}

count_external_action_ref() {
    local ref="$1"
    local count
    count=$(
        grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "${github_scan_files[@]}" \
            | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' \
            | grep -Fvx './' \
            | grep -Fx "$ref" \
            | wc -l
    )
    printf '%s\n' "${count//[[:space:]]/}"
}

files_for_external_action_ref() {
    local ref="$1"
    local file
    for file in "${github_scan_files[@]}"; do
        if grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "$file" \
            | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' \
            | grep -Fxq "$ref"; then
            printf '%s\n' "$file"
        fi
    done
}

# What: inventories every external pinned Action ref in `.github/**` against a checked-in baseline.
# Why: the first no-generator pass accepts a small explicit remainder, but new direct third-party
#   pins or silent count growth must fail closed instead of reintroducing scattered maintenance.
# From: Issue #1095
check_action_pin_baseline() {
    local mismatch=0
    local ref actual expected actual_joined expected_joined
    local -A expected_counts=(
        [actions/add-to-project@5afcf98fcd03f1c2f92c3c83f58ae24323cc57fd]=1
        [actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6]=4
        [actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9]=3
        [actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9]=3
        [actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1]=79
        [actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c]=1
        [actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3]=2
        [actions/labeler@bf12e9b00b37c5c0ca2b87b79b2daf7891dbda13]=1
        [actions/setup-node@820762786026740c76f36085b0efc47a31fe5020]=1
        [actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a]=2
        [aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25]=4
        [docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a]=5
        [docker/login-action@dbcb813823bdd20940b903addbd779551569679f]=28
        [docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302]=5
        [docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c]=16
        [dtolnay/rust-toolchain@4cda84d5c5c54efe2404f9d843567869ab1699d4]=7
        [github/codeql-action/analyze@ff2f1c621b7f889edc0d3c761ac2e6a3f8cdb0dd]=1
        [github/codeql-action/init@ff2f1c621b7f889edc0d3c761ac2e6a3f8cdb0dd]=1
        [release-drafter/release-drafter@34d80673e067bdc0c24568d3af899c216adcfaa9]=1
        [stefanzweifel/changelog-updater-action@a938690fad7edf25368f37e43a1ed1b34303eb36]=1
        [stefanzweifel/git-auto-commit-action@4a55954c782fc1ea30b9056cd3e7a2b40ca8887d]=1
    )
    local -A expected_files=(
        [actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9]=$'.github/actions/ghcr-attest-with-cache/action.yml\n.github/actions/trivy-scan-with-cache/action.yml\n.github/workflows/gc-sha-retention-audit.yml'
        [actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9]=$'.github/actions/ghcr-attest-with-cache/action.yml\n.github/actions/trivy-scan-with-cache/action.yml\n.github/workflows/gc-sha-retention-audit.yml'
        [aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25]=$'.github/actions/trivy-scan-retry/action.yml'
        [docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a]=$'.github/actions/ghcr-build-push-retry/action.yml\n.github/workflows/build-tools.yml'
        [docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c]=$'.github/actions/buildx-setup-retry/action.yml\n.github/workflows/backfill-stack-latest.yml\n.github/workflows/build-push.yml\n.github/workflows/build-tools-smoke.yml\n.github/workflows/build-tools.yml\n.github/workflows/full-setup-deep-validate.yml'
    )

    mapfile -t actual_refs < <(
        grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "${github_scan_files[@]}" \
            | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' \
            | grep -vE '^(\./|wiki-mod/lancache-ng/\.github/)' \
            | sort -u
    )

    for ref in "${actual_refs[@]}"; do
        if [[ -z "${expected_counts[$ref]+x}" ]]; then
            printf "%b[ACTION PIN BASELINE]%b unexpected external action pin: %s\n" "$RED" "$NC" "$ref"
            mismatch=1
        fi
    done

    for ref in "${!expected_counts[@]}"; do
        expected="${expected_counts[$ref]}"
        actual="$(count_external_action_ref "$ref")"
        if [[ "$actual" != "$expected" ]]; then
            printf "%b[ACTION PIN BASELINE]%b %s: expected %s occurrence(s), found %s.\n" "$RED" "$NC" "$ref" "$expected" "$actual"
            mismatch=1
        fi

        if [[ -n "${expected_files[$ref]:-}" ]]; then
            actual_joined="$(files_for_external_action_ref "$ref" | sort)"
            expected_joined="$(printf '%s\n' "${expected_files[$ref]}" | sort)"
            if [[ "$actual_joined" != "$expected_joined" ]]; then
                printf "%b[ACTION PIN BASELINE]%b %s: allowed file inventory drifted.\n" "$RED" "$NC" "$ref"
                printf '  Expected files:\n%s\n' "$(printf '%s\n' "$expected_joined" | sed 's/^/    /')"
                printf '  Actual files:\n%s\n' "$(printf '%s\n' "$actual_joined" | sed 's/^/    /')"
                mismatch=1
            fi
        fi
    done

    if [[ "$mismatch" -eq 1 ]]; then
        violations=$((violations + 1))
        return 1
    fi
    return 0
}

# What: constrains the remaining literal `build-tools:latest` fallback defaults to their approved sites.
# Why: the two shell-script helper fallbacks now derive their default through shared channel logic, so
#   any future new literal default should be deliberate, visible, and baseline-reviewed.
# From: Issue #1095
check_build_tools_default_sites() {
    local mismatch=0
    local -A expected_counts=(
        ['^ARG BUILD_TOOLS_IMAGE=ghcr\.io/wiki-mod/lancache-ng/build-tools:latest$']=2
        ['^[[:space:]]*default: ghcr\.io/wiki-mod/lancache-ng/build-tools:latest$']=1
        ['^RUST_IMAGE="\$\{RUST_IMAGE:-ghcr\.io/wiki-mod/lancache-ng/build-tools:latest\}"$']=0
        ['^client_tools_image="\$\{FULL_SETUP_CLIENT_TOOLS_IMAGE:-ghcr\.io/wiki-mod/lancache-ng/build-tools:latest\}"$']=0
    )
    local pattern actual expected

    for pattern in "${!expected_counts[@]}"; do
        expected="${expected_counts[$pattern]}"
        actual="$(grep -RchE "$pattern" .github/actions services scripts/untracked 2>/dev/null | awk '{sum += $1} END { print sum + 0 }')"
        if [[ "$actual" != "$expected" ]]; then
            printf "%b[BUILD-TOOLS DEFAULT SITES]%b /%s/: expected %s occurrence(s), found %s.\n" "$RED" "$NC" "$pattern" "$expected" "$actual"
            mismatch=1
        fi
    done

    if [[ "$mismatch" -eq 1 ]]; then
        violations=$((violations + 1))
        return 1
    fi
    return 0
}

# What: flags raw github.repository expressions against a counted baseline.
# Why: GHCR requires a lowercase owner/repo; github.repository is not
#   guaranteed lowercase.
# From: Issue #1504
check_repository_case_expressions() {
    # What: matches ${{ github.repository }} with braces fully escaped.
    # Why: GNU grep tolerates a bare, syntactically-invalid ERE interval as
    #   a literal brace, but a strict POSIX grep is not required to, and
    #   this script's container is not guaranteed to run GNU grep.
    # From: Issue #1504
    local pattern='\$\{\{ *github\.repository *\}\}'
    # What: file -> expected TOTAL raw github.repository count (live baseline).
    # Why: must be updated in the same commit that changes the real count,
    #   or this guard silently stops meaning anything.
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

# What: --only NAME runs exactly one named check instead of the full sweep.
# Why: lets a caller wire a single check into CI without also gating on
#   the other checks' own, independent state.
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
        printf 'Usage: check-mutable-refs.sh [--only action-refs|dockerfile-base-images|workflow-image-defaults|repository-case|action-pin-baseline|build-tools-default-sites]\n' >&2
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
run_check action-pin-baseline "Checking external action pin baseline (issue #1095)..." check_action_pin_baseline
run_check build-tools-default-sites "Checking remaining build-tools:latest fallback sites..." check_build_tools_default_sites

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
