#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Validates a pull request TITLE against this repo's Conventional-Commit
# taxonomy, enforced from AGENTS.md's AG-GH-018. This repo merges (not
# squashes) pull requests, so the PR title -- not any individual commit
# message -- is the unit release-please would read to compute the next
# vX.Y.Z bump; see issue #850 for the real-history audit this taxonomy was
# derived from and #819 for the release-automation this is a prerequisite
# for.
#
# Expected shape: type(scope)!: subject
#   - type    required, one of $allowed_types below (lowercase, exact match)
#   - (scope) optional, one of $allowed_scopes below (lowercase)
#   - !       optional, marks a breaking change (see AG-GH-018 bump policy)
#   - subject required, non-empty after the mandatory ": " separator
#
# `security` is intentionally NOT in $allowed_types -- see AG-GH-018 and the
# #850 comment thread for why, and for the pending maintainer decision this
# still needs before it's considered final. Until decided, security-related
# changes should use `fix(security): ...` / `feat(security): ...` instead of
# a bespoke `security:` type.
#
# For draft PRs: prints warnings but exits 0 (non-blocking), matching
# validate-pr-template.sh's and check-pr-tracking-metadata.sh's draft
# handling -- title convention is expected to settle before a PR leaves
# draft, not before the first push.
#
# Grace-period switch: PR_TITLE_LINT_MODE controls whether a non-draft PR
# with a non-conforming title fails the job ("block", the default per the
# maintainer's "enforcing" ask) or only warns ("warn", for a temporary
# rollout grace period). This is the one line to flip:
#   PR_TITLE_LINT_MODE="${PR_TITLE_LINT_MODE:-block}"
#
# Usage:
#   check-pr-title-convention.sh <title-file>
#
# Environment variables (for CI):
#   PR_TITLE            - PR title content (used if no file argument)
#   PR_DRAFT             - "true" or "false" (if not set, defaults to non-draft enforcement)
#   PR_AUTHOR             - github.event.pull_request.user.login; a literal
#                           "dependabot[bot]" short-circuits this check entirely
#                           (see the exemption below for why)
#   PR_TITLE_LINT_MODE    - "block" (default) or "warn"; see grace-period note above
#
# Runs inside the build-tools container in CI (per AG-VAL-016), not directly
# on the runner host -- see the pr-title-convention-check job in
# build-push.yml. The regex/array logic below only needs bash itself, but
# routing it through the pinned container keeps this check on the same bash
# version as every other project verification step rather than depending on
# whatever bash happens to be preinstalled on a given runner.
set -euo pipefail

# Dependabot writes its own fixed dependency-bump titles (e.g. "Bump foo from
# 1.0 to 1.1") and has no way to conform to this repo's Conventional-Commit
# taxonomy on its own -- exempting it here (matching validate-pr-template.sh
# and check-pr-tracking-metadata.sh's identical exemption) rather than
# skipping the whole CI job, so the required-status-check gate sees an
# explicit pass, not an ambiguous skip.
if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
    echo "PR title convention check skipped: PR authored by dependabot[bot], which cannot conform to this repo's Conventional-Commit title taxonomy."
    exit 0
fi

# Grace-period switch -- see the header comment above. Flip the default
# below from "block" to "warn" for a temporary non-blocking rollout period.
pr_title_lint_mode="${PR_TITLE_LINT_MODE:-block}"

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

# `gh pr view --json title` (and GitHub's API generally) can return a
# trailing CRLF; strip both a trailing \r and any trailing whitespace so a
# clean title isn't rejected purely on invisible trailing bytes (same class
# of issue validate-pr-template.sh hit with CRLF-terminated section bodies).
title="${title%$'\r'}"
title="$(printf '%s' "$title" | sed 's/[[:space:]]*$//')"

# Allowed types: the standard Conventional Commits set actually in use
# across this repo's real history (per the #850 audit), plus `revert`
# (not yet seen in history but a standard type worth allowing up front).
# `security` is deliberately excluded -- see the header comment.
allowed_types=(feat fix docs refactor perf test build ci chore style revert)

# Allowed scopes: optional, lowercase, drawn from docs/naming-conventions.md's
# real service names plus the non-service project areas the #850 audit found
# already in use (ci, governance, docs, scripts, tests, build-tools).
allowed_scopes=(proxy dns dhcp dhcp-proxy ui nats watchdog netdata setup ci governance docs scripts tests build-tools)

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

# type(scope)!: subject -- scope and the breaking-change `!` are both
# optional. Capture groups (BASH_REMATCH indices): 1=type, 2=(scope) with
# parens, 3=scope alone, 4=!, 5=subject. `: ` (colon-space) is mandatory,
# matching Conventional Commits' own separator convention.
conventional_commit_pattern='^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$'

if [[ "$title" =~ $conventional_commit_pattern ]]; then
    commit_type="${BASH_REMATCH[1]}"
    commit_scope="${BASH_REMATCH[3]}"
    commit_subject="${BASH_REMATCH[5]}"

    # Trim the subject and reject a subject that is only whitespace -- the
    # regex's `.+` already requires at least one character, but that
    # character could be a stray trailing space with nothing meaningful
    # before it (e.g. "fix:    ").
    trimmed_subject="$(printf '%s' "$commit_subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if ! array_contains "$commit_type" "${allowed_types[@]}"; then
        if [ "$commit_type" = "security" ]; then
            errors+=("Type 'security' is not a standard Conventional-Commit type and is not currently allowed (pending maintainer decision, see #850). Use 'fix(security): ...' or 'feat(security): ...' instead.")
        else
            lowercase_type="$(printf '%s' "$commit_type" | tr '[:upper:]' '[:lower:]')"
            if array_contains "$lowercase_type" "${allowed_types[@]}"; then
                errors+=("Type '$commit_type' must be lowercase ('$lowercase_type').")
            else
                errors+=("Type '$commit_type' is not one of the allowed types: ${allowed_types[*]}.")
            fi
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
    # Draft PR: warn but don't fail, so a PR can be opened before its final
    # title is settled.
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "This is a draft PR, so the title convention check is non-blocking. Fix the title before marking ready for review." >&2
    exit 0
elif [ "$pr_title_lint_mode" = "warn" ]; then
    # Grace-period mode: report the same failure but do not block the PR.
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "PR_TITLE_LINT_MODE=warn: this check is running in non-blocking grace-period mode." >&2
    exit 0
else
    echo "::error::$error_message" >&2
    exit 1
fi
