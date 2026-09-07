#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#

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

#
# What: scripts/ci/ci.sh only, no scripts/ci/ prefix.
# Why: ci.sh may become a real build/publish driver.
# From: Issue #1095
ci_tooling_only_scripts=(
    "scripts/ci/ci.sh"
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


classifier_output="$(CHANGED_FILES="$changed_files" bash "$shared_classifier")"
declare -A shared=()
while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    shared["$key"]="$value"
done <<< "$classifier_output"

shared_keys=(
    proxy dns_image ui watchdog dhcp dhcp_proxy ntp syslog build_tools
    deploy scripts setup_runtime workflow workflow_reuse_scope docs_only
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
