#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs the diff-scoped half of the file-headers/file-headers-hosted jobs'
# SPDX check (AG-HDR-008): fetches the PR's base branch and exact base SHA,
# computes the PR's own changed-file list against HEAD, and runs
# scripts/untracked/check-file-headers.sh against exactly that list. Factored out of
# build-push.yml's own inline `run:` block (previously duplicated verbatim
# across the self-hosted and GitHub-hosted-fallback jobs) so both mirrors
# call one real, bats-testable script instead of two copies of the same
# multi-line shell drifting apart, and so this logic runs inside the pinned
# build-tools image rather than depending on runner-local git/Bash/grep --
# a self-hosted runner with missing or stale host tooling could otherwise
# fail this check or silently disagree with the project's own toolchain.
#
# Required environment: SPDX_BASE_SHA (the PR's exact base commit),
# SPDX_BASE_REF (the PR's base branch name), GITHUB_SHA (the commit under
# test, GitHub Actions' own standard env var). Exits 0 with no output when
# the diff is empty (nothing for check-file-headers.sh to check); exits 1
# with check-file-headers.sh's own diagnostics when a changed file is
# missing a required header/SPDX line; exits 1 with its own diagnostic for
# any git-level failure (a real fetch failure after retries are exhausted,
# an unreachable commit, or the diff producer itself failing).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

# NUL-delimited (`-z`) and written straight to a file, never through a
# `mapfile -t x < <(git diff ...)` process substitution or a `$(...)`
# command substitution: a process substitution's own exit status is
# invisible to the reading command and to `set -e`/pipefail alike (the same
# class of bug already fixed in scripts/untracked/check-file-headers.sh's own
# git-ls-files call), so a real diff failure -- a corrupted object, an
# unreachable commit despite the cat-file
# checks above racing a concurrent gc -- would otherwise silently report an
# empty changed-file set as a clean pass instead of failing closed. `$(...)`
# command substitution has the same exit-status problem AND additionally
# strips embedded NUL bytes outright (confirmed: bash's own command
# substitution emits "ignored null byte in input" and discards them),
# which would corrupt the NUL-delimited format `-z` exists to produce in the
# first place -- a plain redirect into a real file avoids both problems at
# once, since it is neither a substitution nor a pipe.
diff_file="$(mktemp)"
trap 'rm -f "$diff_file"' EXIT
if ! git diff -z --name-only --diff-filter=ACMRTUXB "$SPDX_BASE_SHA" "$GITHUB_SHA" > "$diff_file"; then
    echo "::error::check-pr-diff-file-headers: \`git diff\` itself failed between $SPDX_BASE_SHA and $GITHUB_SHA. Not treating this as a clean (empty) pass." >&2
    exit 1
fi

changed_files=()
if [ -s "$diff_file" ]; then
    mapfile -d '' changed_files < "$diff_file"
fi

if [ "${#changed_files[@]}" -gt 0 ]; then
    bash "$script_dir/check-file-headers.sh" "${changed_files[@]}"
fi
