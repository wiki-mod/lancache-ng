#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Validates that a pull request body contains all required sections from
# .github/pull_request_template.md. Enforces the policy stated in CONTRIBUTING.md:
# "Fill in every section rather than deleting the ones that feel redundant for a
# small change — a short 'N/A, this is a one-line typo fix' is fine, but the
# section headings themselves should stay."
#
# For draft PRs: prints warnings but exits 0 (non-blocking).
# For non-draft PRs: exits 1 if any required section is missing or empty.
#
# Usage:
#   validate-pr-template.sh <pr-body-file>
#
# Environment variables (for CI):
#   PR_BODY         - PR body content (used if no file argument)
#   PR_DRAFT        - "true" or "false" (if not set, defaults to non-draft enforcement)
#   PR_AUTHOR       - github.event.pull_request.user.login; a literal
#                     "dependabot[bot]" short-circuits this check entirely
#                     (see the exemption below for why)
set -euo pipefail

# Dependabot only ever writes its own fixed dependency-bump description, and
# has no way to fill in this repo's custom .github/pull_request_template.md
# sections -- this check could never pass on one of its PRs regardless of
# content. Exiting 0 here (an explicit pass) rather than skipping the whole
# CI job keeps this a real reported success for the branch-protection
# required-status-check gate, instead of relying on a skipped job being
# treated as passing.
if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
    echo "PR template validation skipped: PR authored by dependabot[bot], which cannot fill in this repo's custom template body."
    exit 0
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

pr_body_file="${1:-}"
pr_body=""

# Read PR body from file or environment.
if [ -n "$pr_body_file" ] && [ -f "$pr_body_file" ]; then
    pr_body="$(<"$pr_body_file")"
elif [ -n "${PR_BODY:-}" ]; then
    pr_body="$PR_BODY"
else
    echo "::error::No PR body provided. Pass a file path as argument or set PR_BODY environment variable." >&2
    exit 1
fi

# `gh pr view --json body` (and GitHub's API generally) returns issue/PR
# body text with CRLF line endings. Left in place, the trailing `\r` stays
# part of awk's `$0` for every line, so section_exists_with_content()'s
# end-anchored pattern (`$0 ~ ("^## " sec "$")`) never matches any section
# heading on an awk build that doesn't itself normalize CRLF (e.g. `mawk`,
# the default `/usr/bin/awk` on both this project's Debian self-hosted
# runners and GitHub-hosted Ubuntu runners) -- confirmed live on PR #881:
# a correctly fetched, fully-filled 9833-byte body was reported as missing
# all 10 required sections. Stripping `\r` here fixes it at the source
# instead of depending on a specific awk implementation's behavior.
pr_body="${pr_body//$'\r'/}"

# Determine if PR is a draft (default to false/non-draft for CI if not specified).
pr_draft="${PR_DRAFT:-false}"

# Extract required sections from the PR template.
# These are the exact section headings (starting with ##) that CONTRIBUTING.md requires to be present.
# Derived from .github/pull_request_template.md sections.
declare -a required_sections=(
    "Summary"
    "What This Actually Changes"
    "What This PR Fixes / Adds"
    "What Changed In Code"
    "Why This Matters For Users / Operators"
    "Scope Boundaries"
    "Local Scope Evidence"
    "Validation"
    "Type of change"
    "Changelog"
)

# Template placeholders that indicate empty/unfilled sections.
# These are example text from .github/pull_request_template.md that should be replaced.
declare -a placeholder_texts=(
    "Bulleted markdown checklist"
    "Exact commands run locally"
)

# Check if a section exists and has content (not just placeholder text).
section_exists_with_content() {
    local section="$1"
    local body="$2"

    # Look for the section heading "## <Section>".
    # Here-string, not `echo "$body" | grep`: with `set -o pipefail`, a large
    # $body plus awk's `exit` below closing its stdin early can make the
    # `echo` on the left side of a pipe receive SIGPIPE before it finishes
    # writing, failing the whole pipeline non-deterministically depending on
    # body size and where the target section falls -- confirmed this exact
    # failure live in CI (PR #627) as a false "missing section" report. A
    # here-string has no such race: the shell writes it out before awk/grep
    # ever start reading.
    if ! grep -qF "## $section" <<<"$body"; then
        return 1
    fi

    # Extract content after the section heading until the next ## heading using awk.
    # This avoids sed delimiter issues with sections containing "/" characters.
    local section_content
    section_content=$(awk -v sec="$section" '
        /^## / && $0 ~ ("^## " sec "$") {found=1; next}
        found && /^## / {exit}
        found {print}
    ' <<<"$body")

    # Remove leading/trailing whitespace and check if empty.
    local trimmed
    trimmed=$(printf '%s' "$section_content" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [ -z "$trimmed" ]; then
        return 1
    fi

    # A section that still contains the template's own placeholder text
    # (e.g. "Exact commands run locally") wasn't actually filled in, even
    # though it isn't empty.
    for placeholder in "${placeholder_texts[@]}"; do
        if [[ "$trimmed" == *"$placeholder"* ]]; then
            return 1
        fi
    done

    return 0
}

# Validate all required sections.
missing_sections=()
for section in "${required_sections[@]}"; do
    if ! section_exists_with_content "$section" "$pr_body"; then
        missing_sections+=("$section")
    fi
done

# Report results.
if [ "${#missing_sections[@]}" -eq 0 ]; then
    echo "PR template validation passed: all required sections present and filled."
    exit 0
fi

# Format error message.
error_message="$(cat <<EOF
PR template validation failed: missing or empty required sections.

The following sections from .github/pull_request_template.md are missing or empty:
EOF
)"
for section in "${missing_sections[@]}"; do
    error_message="$error_message"$'\n'"  - ## $section"
done
error_message="$error_message"$'\n\n'"See CONTRIBUTING.md: fill in every section (even 'N/A, ...' is fine)."

# Behavior for draft vs. non-draft PRs.
if [ "$pr_draft" = "true" ]; then
    # Draft PR: warn but don't fail.
    echo "::warning::$error_message" >&2
    echo ""
    echo "This is a draft PR, so the template check is non-blocking." >&2
    echo "Before marking ready for review, please fill in the missing sections." >&2
    exit 0
else
    # Non-draft PR: fail.
    echo "::error::$error_message" >&2
    exit 1
fi
