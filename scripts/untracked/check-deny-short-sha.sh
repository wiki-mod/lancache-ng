#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: fails if any tracked .github/workflows/*.yml or scripts/lib/*.sh
#   file hardcodes a short-SHA truncation length via a literal
#   ${VAR::N}/${VAR:0:N} bash slice on a sha-named variable (assignment or
#   bare interpolation, e.g. short_sha=/base_sha_short=/"sha-${x:0:7}").
# Why: a hardcoded slice bypasses the single declared derivation
#   (scripts/lib/docker-metadata.sh's dmeta_short_sha()), letting copies
#   silently diverge from DOCKER_METADATA_SHORT_SHA_LENGTH and each other.
# From: Issue #1095 (G2) | PR #1503
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# What: excludes this script and its own bats fixture from the scan.
# Why: the header above quotes the banned pattern verbatim as documentation.
# From: Issue #1095 (G2) | PR #1503
is_self_reference() {
    case "$1" in
        scripts/untracked/check-short-sha-truncation.sh) return 0 ;;
        tests/bats/check_short_sha_truncation.bats) return 0 ;;
        *) return 1 ;;
    esac
}

# What: matches a ${VAR::N}/${VAR:0:N} slice (any position) where VAR's name
#   contains "sha" case-insensitively, with a literal numeric length, and
#   optional bash-tolerated whitespace around either colon/number.
# Why: a literal length is what identifies a hardcode; scripts/lib/
#   docker-metadata.sh's own slice uses a variable length and never matches.
# From: Issue #1095 (G2) | PR #1503
SHORT_SHA_HARDCODE_PATTERN='\$\{([A-Za-z_][A-Za-z0-9_]*)?[Ss][Hh][Aa][A-Za-z0-9_]*[[:space:]]*(:[[:space:]]*:[[:space:]]*[0-9]+|:[[:space:]]*0[[:space:]]*:[[:space:]]*[0-9]+)\}'


# What: enumerates target files via command substitution, not a
#   `mapfile -t files < <(...)` process substitution.
# Why: a process substitution's own exit status is invisible to mapfile and
#   to set -e/pipefail, so a real enumeration failure would silently scan
#   zero files and report a false clean pass.
# From: Issue #1095 (G2) | PR #1503
if [ -e "$target_root/.git" ]; then
    if ! files_raw="$(git ls-files -- '.github/workflows/*.yml' 'scripts/lib/*.sh')"; then
        echo "::error::check-short-sha-truncation: \`git ls-files\` itself failed -- is $target_root a real git work tree? Not treating this as a clean pass." >&2
        exit 1
    fi
else
    if ! files_raw="$(find . \( -path './.github/workflows/*.yml' -o -path './scripts/lib/*.sh' \) -type f -print | sed 's#^\./##')"; then
        echo "::error::check-short-sha-truncation: file enumeration (find/sed) failed. Not treating this as a clean pass." >&2
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

    # What: captures grep's output via command substitution and checks its
    #   real exit status explicitly.
    # Why: status 1 means "no match" (expected), but status >1 means grep
    #   itself failed (e.g. an unreadable file), which must fail this guard
    #   closed instead of a bare `|| true` folding it into "no match".
    # From: Issue #1095 (G2) | PR #1503
    grep_status=0
    grep_output="$(grep -EnH "$SHORT_SHA_HARDCODE_PATTERN" "$path")" || grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
        echo "::error::check-short-sha-truncation: \`grep\` failed reading '$path' (exit $grep_status). Not treating this as a clean pass." >&2
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
    echo "Hardcoded short-SHA truncation length found (issue #1095 G2 violation):" >&2
    printf '  %s\n' "${violations[@]}" >&2
    echo "" >&2
    echo "A \${VAR::N}/\${VAR:0:N} slice on a sha-named variable with a literal" >&2
    echo "numeric length independently hardcodes the truncation length instead of reading" >&2
    echo "the single declared derivation. Source scripts/lib/docker-metadata.sh and use" >&2
    echo "short_sha=\"\$(dmeta_short_sha \"\$FULL_SHA_VAR\")\" instead." >&2
    exit 1
fi

echo "No hardcoded short-SHA truncation lengths found -- issue #1095 G2 holds."
