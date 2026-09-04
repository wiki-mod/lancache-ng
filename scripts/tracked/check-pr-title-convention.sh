#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#

set -euo pipefail


if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
    echo "PR title convention check skipped: PR authored by dependabot[bot], which cannot conform to this repo's Conventional-Commit title taxonomy."
    exit 0
fi


pr_title_lint_mode="${PR_TITLE_LINT_MODE:-warn}"

pr_draft="${PR_DRAFT:-false}"

title_file="${1:-}"
title=""

# Read the PR title from a file or environment variable.
if [ -n "$title_file" ] && [ -f "$title_file" ]; then
    title="$(<"$title_file")"
elif [ -n "${PR_TITLE:-}" ]; then
    title="$PR_TITLE"
else
    echo "::error::No PR title provided. Pass a file path as argument or set PR_TITLE environment variable." >&2
    exit 1
fi


title="${title%$'\r'}"
title="$(printf '%s' "$title" | sed 's/[[:space:]]*$//')"


allowed_types=(feat fix docs refactor perf test build ci chore style revert security)


allowed_scopes=(proxy dns dhcp dhcp-proxy ntp ui nats watchdog netdata syslog cachehamster setup ci governance docs scripts tests build-tools)

array_contains() {
    local needle="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if [ "$candidate" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

errors=()

conventional_commit_pattern='^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$'

if [[ "$title" =~ $conventional_commit_pattern ]]; then
    commit_type="${BASH_REMATCH[1]}"
    commit_scope="${BASH_REMATCH[3]}"
    commit_subject="${BASH_REMATCH[5]}"
    trimmed_subject="$(printf '%s' "$commit_subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if ! array_contains "$commit_type" "${allowed_types[@]}"; then
        lowercase_type="$(printf '%s' "$commit_type" | tr '[:upper:]' '[:lower:]')"
        if array_contains "$lowercase_type" "${allowed_types[@]}"; then
            errors+=("Type '$commit_type' must be lowercase ('$lowercase_type').")
        else
            errors+=("Type '$commit_type' is not one of the allowed types: ${allowed_types[*]}.")
        fi
    fi
    if [ -n "$commit_scope" ] && ! array_contains "$commit_scope" "${allowed_scopes[@]}"; then
        errors+=("Scope '($commit_scope)' is not one of the documented areas: ${allowed_scopes[*]} (see docs/naming-conventions.md).")
    fi
    if [ -z "$trimmed_subject" ]; then
        errors+=("Subject is empty or whitespace-only after 'type(scope)!: '.")
    fi
else
    errors+=("Title does not start with a Conventional-Commit prefix ('type(scope)!: subject', e.g. 'feat(dhcp): add IPv6 lease support' or 'fix: correct cache key'). Allowed types: ${allowed_types[*]}.")
fi
if [ "${#errors[@]}" -eq 0 ]; then
    echo "PR title convention check passed: '$title'"
    exit 0
fi
error_message="PR title convention check failed (AG-GH-018) for title: '$title'"
for e in "${errors[@]}"; do
    error_message="$error_message"$'\n'"  - $e"
done
if [ "$pr_draft" = "true" ]; then
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "This is a draft PR, so the title convention check is non-blocking. Fix the title before marking ready for review." >&2
    exit 0
elif [ "$pr_title_lint_mode" = "warn" ]; then
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "PR_TITLE_LINT_MODE=warn: this is a transitional grace period, not a permanent downgrade. The title above is still a rule violation (AG-GH-018) and must be fixed before this PR merges -- it simply does not hard-block CI while the grace period is active." >&2
    exit 0
else
    echo "::error::$error_message" >&2
    exit 1
fi
