#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: fails if tracked files slice SHA-named variables via bash
# Why: short-SHA banned; slice creates collision-unsafe truncation
# From: Issue #1095
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# What: excludes this script and its own bats fixture from the scan.
# Why: script header quotes the banned pattern verbatim
# From: Issue #1095
is_self_reference() {
    case "$1" in
        scripts/untracked/check-deny-short-sha.sh) return 0 ;;
        tests/bats/check_deny_short_sha.bats) return 0 ;;
        *) return 1 ;;
    esac
}

# What: detects substring slices ${VAR::N} on SHA-holding variables
# Why: bans slices on sha/commit/candidate/revision-named variables
# From: Issue #1095 | PR #1611
SHORT_SHA_SLICE_PATTERN='\$\{([A-Za-z_][A-Za-z0-9_]*)?([Ss][Hh][Aa]|[Cc][Oo][Mm][Mm][Ii][Tt]|[Cc][Aa][Nn][Dd][Ii][Dd][Aa][Tt][Ee]|[Rr][Ee][Vv][Ii][Ss][Ii][Oo][Nn])[A-Za-z0-9_]*[[:space:]]*(:[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+|:[[:space:]]*0[[:space:]]*:[[:space:]]*[A-Za-z0-9_]+)\}'


# What: enumerates via command substitution not process substitution
# Why: process substitution fails silently with mapfile and set -e
# From: Issue #1095
if [ -e "$target_root/.git" ]; then
    if ! files_raw="$(git ls-files -- '.github/workflows/*.yml' 'scripts/lib/*.sh')"; then
        echo "::error::check-deny-short-sha: \`git ls-files\` itself failed -- is $target_root a real git work tree? Not treating this as a clean pass." >&2
        exit 1
    fi
else
    if ! files_raw="$(find . \( -path './.github/workflows/*.yml' -o -path './scripts/lib/*.sh' \) -type f -print | sed 's#^\./##')"; then
        echo "::error::check-deny-short-sha: file enumeration (find/sed) failed. Not treating this as a clean pass." >&2
        exit 1
    fi
fi
files=()
if [ -n "$files_raw" ]; then
    mapfile -t files <<< "$files_raw"
fi

violations=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_self_reference "$path" && continue

    # What: captures grep output and checks exit status explicitly
    # Why: status 1 means no match; status >1 means grep error occurred
    # From: Issue #1095
    grep_status=0
    grep_output="$(grep -EnH "$SHORT_SHA_SLICE_PATTERN" "$path")" || grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
        echo "::error::check-deny-short-sha: \`grep\` failed reading '$path' (exit $grep_status). Not treating this as a clean pass." >&2
        exit 1
    fi
    if [ -n "$grep_output" ]; then
        while IFS= read -r match; do
            [ -n "$match" ] || continue
            violations+=("$match")
        done <<< "$grep_output"
    fi
done

if [ "${#violations[@]}" -gt 0 ]; then
    echo "Short-SHA slice found (issue #1095 G2 violation -- short SHAs are banned outright):" >&2
    printf '  %s\n' "${violations[@]}" >&2
    echo "" >&2
    echo "A \${VAR::N}/\${VAR:0:N} slice on a sha-named variable re-introduces the" >&2
    echo "collision-unsafe local truncation this project removed. Use the full" >&2
    echo "commit SHA directly; if a legacy 7-char GHCR tag genuinely needs probing" >&2
    echo "during the transition window, resolve it via 'git rev-parse --short=7'" >&2
    echo "against a real object (scripts/lib/staging-ancestor-fallback.sh's own" >&2
    echo "saf_resolve_sha_image_ref is the reference example), never a bash slice." >&2
    exit 1
fi

echo "No short-SHA slices found -- issue #1095 G2 (deny-short-sha) holds."
