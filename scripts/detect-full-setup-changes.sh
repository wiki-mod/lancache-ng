#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Plans whether the full-setup deep validation needs to run for a PR diff.
# Shared service/build path classification comes from classify-image-impact.sh;
# only the full-setup-specific should_run policy remains here so the staging
# guard and the build pipeline cannot drift on which service a path affects.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shared_classifier="$script_dir/classify-image-impact.sh"
: "${shared_classifier:?shared classifier path is required}"
[[ -f "$shared_classifier" ]] || {
    echo "Shared classifier '$shared_classifier' does not exist." >&2
    exit 1
}

changed_files=""
cleanup() {
    # CHANGED_FILES-driven callers create no temporary file. The explicit
    # branch prevents a false guard result from becoming the EXIT-trap status
    # under errexit.
    if [[ -n "${_vit_tmp:-}" ]]; then
        rm -f "$_vit_tmp"
    fi
}
trap cleanup EXIT

if [[ -n "${CHANGED_FILES:-}" ]]; then
    changed_files="$CHANGED_FILES"
else
    : "${BASE_SHA:?pull request base SHA is required when CHANGED_FILES is unset}"
    : "${GITHUB_SHA:?GitHub checkout SHA is required when CHANGED_FILES is unset}"
    # Use the real merge-base so changes that reached the base branch after
    # this branch forked are not misattributed to the PR under validation.
    merge_base="$(git merge-base "$BASE_SHA" "$GITHUB_SHA")"
    _vit_tmp="$(mktemp)"
    git diff --name-only "$merge_base" "$GITHUB_SHA" > "$_vit_tmp"
    changed_files="$_vit_tmp"
fi

[[ -f "$changed_files" ]] || {
    echo "Changed-file input '$changed_files' does not exist." >&2
    exit 1
}

# should_run is intentionally broader than the shared service/build verdicts,
# so it still needs the raw path list for full-setup-only policy decisions.
touches_prefix() {
    local prefix="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$prefix"* ]] && return 0
    done < "$changed_files"
    return 1
}

touches_exact() {
    local expected="$1" path
    while IFS= read -r path; do
        [[ "$path" == "$expected" ]] && return 0
    done < "$changed_files"
    return 1
}

# These scripts are CI/governance tooling with no runtime-stack dependency.
# Keeping the exception exact and fail-closed avoids paying for the deep stack
# suite for known tooling-only edits while every unknown/new script still runs
# the suite. scripts/tracked/ is the designated prefix for scripts that have
# already received the same dependency review before being moved there.
ci_tooling_only_scripts=(
    "scripts/check-action-node-versions.sh"
    "scripts/check-bats-path-filter-coverage.sh"
    "scripts/check-build-tools-smoke-coverage.sh"
    "scripts/check-changelog-direct-edit.sh"
    "scripts/check-compose-healthchecks.sh"
    "scripts/check-executable-bits.sh"
    "scripts/check-file-headers.sh"
    "scripts/check-governance-guards.sh"
    "scripts/check-idempotence-test-coverage.sh"
    "scripts/check-language-policy.sh"
    "scripts/check-line-endings.sh"
    "scripts/check-logging-matrix.sh"
    "scripts/check-mutable-refs.sh"
    "scripts/check-naming-consistency.sh"
    "scripts/check-orphaned-branches.sh"
    "scripts/check-pr-title-convention.sh"
    "scripts/check-pr-tracking-metadata.sh"
    "scripts/check-setup-prompt-drift.sh"
    "scripts/check-stable-external-images.sh"
    "scripts/check-validation-subnet-wrapper-coverage.sh"
    "scripts/check-vex-drift.sh"
    "scripts/check-workflow-service-lists.sh"
    "scripts/test-governance-guards.sh"
    "scripts/validate-pr-template.sh"
)

touches_scripts_beyond_ci_tooling_allowlist() {
    local path allowed known
    while IFS= read -r path; do
        [[ "$path" == "scripts/"* ]] || continue
        allowed=false
        if [[ "$path" == "scripts/tracked/"* ]]; then
            allowed=true
        else
            for known in "${ci_tooling_only_scripts[@]}"; do
                if [[ "$path" == "$known" ]]; then
                    allowed=true
                    break
                fi
            done
        fi
        [[ "$allowed" == "false" ]] && return 0
    done < "$changed_files"
    return 1
}

# The shared classifier is the single source for every verdict that must agree
# with build-push. It writes diagnostics to stderr and machine-readable values
# to stdout, so command substitution retains only the key=value contract.
classifier_output="$(CHANGED_FILES="$changed_files" bash "$shared_classifier")"
declare -A shared=()
while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    shared["$key"]="$value"
done <<< "$classifier_output"

shared_keys=(
    proxy dns_image ui watchdog dhcp dhcp_proxy ntp syslog build_tools
    deploy scripts setup_runtime workflow docs_only
)
for key in "${shared_keys[@]}"; do
    case "${shared[$key]:-}" in
        true | false) ;;
        *)
            echo "Shared classifier did not emit a valid '$key' verdict." >&2
            exit 1
            ;;
    esac
done

# Empty and docs-only diffs are both cheap no-op cases, but they are distinct:
# the shared classifier intentionally reports docs_only=false for an empty diff.
any_changed=false
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    any_changed=true
    break
done < "$changed_files"

full_setup_should_run() {
    if [[ "${shared[docs_only]}" == "true" || "$any_changed" == "false" ]]; then
        return 1
    fi

    # The deep suite is broader than service rebuild admission. Workflow files
    # can change the validation itself, deploy files change stack assembly, and
    # runtime-facing scripts can change behavior without changing an image path.
    # The scripts allowlist above is the one deliberate narrowing of this broad
    # fail-closed policy.
    if touches_prefix "services/" \
        || touches_prefix "deploy/" \
        || touches_scripts_beyond_ci_tooling_allowlist \
        || touches_prefix "tools/build-tools/" \
        || touches_prefix ".github/workflows/" \
        || touches_prefix ".github/actions/" \
        || touches_exact "setup.sh" \
        || [[ "${shared[workflow]}" == "true" ]]; then
        return 0
    fi
    return 1
}

emit() {
    local key
    # Preserve the detector's existing public output contract and order while
    # sourcing every shared value from one classifier implementation.
    for key in "${shared_keys[@]}"; do
        printf '%s=%s\n' "$key" "${shared[$key]}"
    done

    if full_setup_should_run; then
        printf 'should_run=true\n'
    else
        printf 'should_run=false\n'
    fi
}

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    emit >> "$GITHUB_OUTPUT"
else
    emit
fi
