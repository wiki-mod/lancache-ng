#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs the diff-scoped, blocking half of the file-headers/file-headers-hosted
# jobs' review-chronology check (AG-CODE-002/003/012): fetches the PR's base
# branch and exact base SHA, computes the PR's own changed-file list against
# HEAD, and runs scripts/untracked/check-review-chronology-comments.sh
# against exactly that list. Mirrors check-pr-diff-file-headers.sh's own
# fetch/diff/mapfile mechanism verbatim (see that script's header for why
# process substitution and $(...) are both wrong for the diff step), so this
# check has the same failure semantics as the SPDX one it sits alongside: a
# pre-existing repo-wide violation elsewhere no longer blocks an unrelated
# PR (see the sibling repo-wide invocation's CHRONOLOGY_WARN_ONLY=1 mode),
# but a violation this PR's own diff introduces or touches still fails
# closed here.
#
# Required environment: SPDX_BASE_SHA (the PR's exact base commit),
# SPDX_BASE_REF (the PR's base branch name), GITHUB_SHA (the commit under
# test, GitHub Actions' own standard env var) -- reused verbatim from the
# SPDX step's own env, not duplicated under a new name. Exits 0 with no
# output when the diff is empty; exits 1 with
# check-review-chronology-comments.sh's own diagnostics when a changed file
# violates AG-CODE-002/003/012; exits 1 with its own diagnostic for any
# git-level failure.
# From: Issue #1095
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
# shellcheck source=scripts/lib/git-fetch-retry.sh
source "$script_dir/../lib/git-fetch-retry.sh"

: "${SPDX_BASE_SHA:?SPDX_BASE_SHA is required}"
: "${SPDX_BASE_REF:?SPDX_BASE_REF is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

git_fetch_retry --no-tags --depth=1 origin \
    "+refs/heads/${SPDX_BASE_REF}:refs/remotes/origin/${SPDX_BASE_REF}"
git_fetch_retry --no-tags --depth=1 origin "$SPDX_BASE_SHA"
git cat-file -e "${SPDX_BASE_SHA}^{commit}"
git cat-file -e "${GITHUB_SHA}^{commit}"

# What: NUL-delimited diff written to a real file, never a substitution.
# Why: same reasoning as check-pr-diff-file-headers.sh's identical step --
#   a process/command substitution's exit status is invisible to set -e,
#   and $(...) additionally strips embedded NULs, corrupting the -z format.
# From: Issue #1095
diff_file="$(mktemp)"
trap 'rm -f "$diff_file"' EXIT
if ! git diff -z --name-only --diff-filter=ACMRTUXB "$SPDX_BASE_SHA" "$GITHUB_SHA" > "$diff_file"; then
    echo "::error::check-pr-diff-review-chronology: \`git diff\` itself failed between $SPDX_BASE_SHA and $GITHUB_SHA. Not treating this as a clean (empty) pass." >&2
    exit 1
fi

changed_files=()
if [ -s "$diff_file" ]; then
    mapfile -d '' changed_files < "$diff_file"
fi

if [ "${#changed_files[@]}" -gt 0 ]; then
    bash "$script_dir/check-review-chronology-comments.sh" "$repo_root" "${changed_files[@]}"
fi
