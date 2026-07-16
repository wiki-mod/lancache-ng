#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Assists the manual "Releasing Changes to CHANGELOG.md" step in CONTRIBUTING.md:
# collects the accumulated `## Changelog` PR-body sections from every PR merged
# into a branch since the last `vX.Y.Z` tag (or an explicit start point) and
# prints them so a maintainer can hand-organize the text into CHANGELOG.md's
# `Added`/`Changed`/`Fixed`/`Deprecated`/`Removed`/`Security` subheadings.
#
# This is a maintainer-invoked, read-only collection aid, not a release-cutting
# tool -- it does not write to CHANGELOG.md, tag anything, or call any GitHub
# write API. That matches issue #819's fully-manual version-bump model: this
# script exists to make step 1 of the release checklist (collecting entries)
# less tedious, not to automate the decision of when/what to release.
#
# Why not GitHub's native `--generate-notes` or release-drafter instead: both
# summarize merged PRs by title/label, not by body content. This project's
# CHANGELOG.md entries are long-form, multi-paragraph explanations (see any
# existing entry), so a title-based generator would be a real style
# regression. Pulling each PR's own `## Changelog` section is the only way to
# keep that style without hand-transcribing from scratch at release time.
#
# Requires the GitHub CLI (`gh`), authenticated with at least read access to
# this repository.
#
# Usage:
#   scripts/collect-changelog-entries.sh [--base <branch>] [--since <ref-or-date>]
#
#   --base <branch>       Branch to collect merged PRs against (default: v0.2.0).
#   --since <ref-or-date> Git ref (tag/commit) or ISO date (YYYY-MM-DD) to collect
#                         from. Defaults to the most recent vX.Y.Z tag reachable
#                         from --base, or the branch's root commit if no tag exists
#                         yet.
#
# Output (stdout): one block per PR with a Changelog section, in merge order:
#   ### PR #<number>: <title>
#   <url>
#
#   <changelog section text, verbatim>
#
# PRs with no `## Changelog` heading, or only placeholder/empty content, are
# skipped and reported on stderr so the maintainer knows what to check by hand.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

base_branch="v0.2.0"
since_ref=""

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            base_branch="$2"
            shift 2
            ;;
        --since)
            since_ref="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "::error::Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "::error::GitHub CLI (gh) is required but not found on PATH." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq is required but not found on PATH." >&2
    exit 1
fi

# Resolve the collection start point: an explicit --since wins; otherwise fall
# back to the latest vX.Y.Z tag reachable from base_branch, or (if no release
# has been tagged yet) the branch's root commit so the very first release
# still collects every PR merged so far.
since_date=""
if [ -n "$since_ref" ]; then
    if [[ "$since_ref" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        since_date="$since_ref"
    else
        since_date="$(git log -1 --format=%aI "$since_ref" | cut -c1-10)"
    fi
else
    last_tag="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 "origin/$base_branch" 2>/dev/null || true)"
    if [ -n "$last_tag" ]; then
        since_date="$(git log -1 --format=%aI "$last_tag" | cut -c1-10)"
        echo "::notice::Collecting PRs merged since the last tag $last_tag ($since_date)." >&2
    else
        since_date="$(git log --format=%aI "origin/$base_branch" | tail -1 | cut -c1-10)"
        echo "::notice::No prior vX.Y.Z tag found; collecting every PR merged into $base_branch since its root commit ($since_date)." >&2
    fi
fi

# Extract the content of a named "## <section>" heading from a PR body, up to
# the next "## " heading or end of body. Mirrors validate-pr-template.sh's
# section_exists_with_content() extraction so both scripts agree on what
# counts as "the Changelog section".
extract_section() {
    local section="$1"
    local body="$2"

    awk -v sec="$section" '
        /^## / && $0 ~ ("^## " sec "$") {found=1; next}
        found && /^## / {exit}
        found {print}
    ' <<<"$body"
}

pr_numbers="$(gh pr list \
    --repo wiki-mod/lancache-ng \
    --base "$base_branch" \
    --state merged \
    --search "merged:>=${since_date}" \
    --json number \
    --jq '.[].number' \
    --limit 500 | sort -n)"

if [ -z "$pr_numbers" ]; then
    echo "::notice::No merged PRs found against $base_branch since $since_date." >&2
    exit 0
fi

skipped=0
collected=0
while IFS= read -r pr_number; do
    [ -z "$pr_number" ] && continue

    pr_json="$(gh pr view "$pr_number" --repo wiki-mod/lancache-ng --json title,url,body)"
    pr_title="$(printf '%s' "$pr_json" | jq -r '.title')"
    pr_url="$(printf '%s' "$pr_json" | jq -r '.url')"
    pr_body="$(printf '%s' "$pr_json" | jq -r '.body')"

    changelog_text="$(extract_section "Changelog" "$pr_body")"
    trimmed="$(printf '%s' "$changelog_text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if [ -z "$trimmed" ]; then
        echo "::warning::PR #$pr_number ($pr_title) has no non-empty ## Changelog section -- check it by hand." >&2
        skipped=$((skipped + 1))
        continue
    fi

    printf '### PR #%s: %s\n%s\n\n%s\n\n' "$pr_number" "$pr_title" "$pr_url" "$trimmed"
    collected=$((collected + 1))
done <<<"$pr_numbers"

echo "::notice::Collected $collected PR changelog section(s), skipped $skipped PR(s) with no usable section." >&2
