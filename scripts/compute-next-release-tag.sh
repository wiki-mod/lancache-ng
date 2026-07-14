#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Pure version-arithmetic helper for the automated patch-release step in
# build-push.yml's `promote` job (#819). Deliberately has no git/network
# dependency so tests/bats/compute_next_release_tag.bats can exercise every
# boundary (leading zeros, multi-digit components, malformed input) without a
# real repository.
#
# Only the patch (Z) component is ever computed automatically. Minor (X) and
# major (Y) bumps stay a deliberate, manual maintainer tag push -- #819's
# design is explicit that automatic bumping past a feature/breaking milestone
# is not something a diff classifier can decide.
#
# Input: the current release tag, e.g. v0.2.3 (from
# `git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0`).
# Output: the next patch tag, e.g. v0.2.4, on stdout.
set -euo pipefail

current_tag="${1:-}"
: "${current_tag:?usage: compute-next-release-tag.sh <current-tag, e.g. v0.2.3>}"

if [[ ! "$current_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf 'compute-next-release-tag.sh: %s is not a plain vX.Y.Z tag (release candidates and other refs are not auto-bumped)\n' "$current_tag" >&2
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

# 10#$patch forces base-10 arithmetic so a component with a leading zero
# (e.g. the "07" in v0.2.07) is never misread as an invalid octal literal by
# bash's arithmetic expansion.
next_patch=$((10#$patch + 1))

printf 'v%s.%s.%s\n' "$major" "$minor" "$next_patch"
