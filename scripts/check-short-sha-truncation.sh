#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard for issue #1095's G2 gap-map finding: a `short_sha`-style
# variable assignment must read the project's single declared short-SHA
# derivation (scripts/lib/docker-metadata.sh's dmeta_short_sha(), which in
# turn reads DOCKER_METADATA_SHORT_SHA_LENGTH) instead of independently
# hardcoding the truncation length as a literal `::7}`/`:0:7`-style bash
# substring slice. This exact hardcode was found independently, at the
# identical length, in 20 places across five files
# (.github/workflows/build-push.yml x8, .github/workflows/build-tools.yml
# x3, .github/workflows/build-push-hosted-fallback.yml x1,
# scripts/lib/validation-image-tag.sh x1, scripts/lib/staging-ancestor-
# fallback.sh x7) -- every one computing the same value the same way, with
# no single site any of them actually read, so a future change to that
# length would need to be found and edited in sync by hand at every one of
# them, or silently diverge.
#
# Detection matches any `${VAR::N}`/`${VAR:0:N}` bash substring slice with a
# literal numeric length where VAR's own name contains "sha" (case-insensitive
# substring match, e.g. short_sha, base_sha_short, ancestor_sha_short,
# commit1_sha, GITHUB_SHA, full_sha) -- not a broad ban on the substring-slice
# syntax itself (which has many legitimate, unrelated uses this guard must
# not flag), and not limited to an assignment context: a bare interpolation
# like "sha-${ancestor_sha:0:7}" is caught exactly the same as a
# short_sha="${VAR::7}" assignment, since both independently hardcode the
# truncation length instead of calling dmeta_short_sha(). The portion of
# VAR's name before "sha" may itself contain digits (e.g. `commit1_sha`,
# `base2_sha`) as long as VAR still starts with a valid bash identifier
# character (a letter or underscore, never a leading digit) -- matching only
# letters/underscores there would miss any sha-named variable whose prefix
# happens to include a digit. scripts/lib/docker-metadata.sh's OWN internal
# `${full_sha:0:length}` slice (length is a variable, not a literal digit)
# stays exempt by construction -- the regex below only matches a literal
# digit run, never a bare identifier -- since that line IS the single
# declared implementation this guard exists to make everyone else call, not
# a violation of it.
#
# Scoped to .github/workflows/*.yml and scripts/lib/*.sh: the two file
# classes every confirmed instance above was found in. A prose mention of
# "the first 7 characters of a SHA" in documentation is not this pattern
# (no `short_sha=` assignment syntax at all) and is out of scope regardless
# of file location.
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so a bats test can point it at a small fixture tree instead of
# mutating or depending on the real repository, mirroring
# scripts/check-review-chronology-comments.sh's own convention.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
target_root="${1:-$repo_root}"
cd "$target_root"

# This script's own header comment above quotes the banned pattern verbatim
# as documentation of what it detects -- excluded from the scan by
# construction so the guard does not fail on its own documentation, mirroring
# check-review-chronology-comments.sh's identical self-exclusion.
is_self_reference() {
    case "$1" in
        scripts/check-short-sha-truncation.sh) return 0 ;;
        tests/bats/check_short_sha_truncation.bats) return 0 ;;
        *) return 1 ;;
    esac
}

# A `${VAR::N}`/`${VAR:0:N}` slice, in any position (assignment or bare
# interpolation), where VAR's name contains "sha" case-insensitively, with a
# literal numeric length (never a bare identifier -- see the header comment
# for why that keeps scripts/lib/docker-metadata.sh's own implementation
# line, whose length is a variable, from ever matching this pattern). The
# optional prefix group before "sha" requires a valid bash identifier's
# leading character (letter/underscore, never a digit) but allows digits
# anywhere after that, so a name like `commit1_sha` still matches. Bash's
# own substring-expansion grammar evaluates offset and length as arithmetic
# expressions, so it tolerates embedded whitespace around either colon and
# either number (e.g. `${GITHUB_SHA: 0 : 7}` slices identically to
# `${GITHUB_SHA:0:7}`) -- the [[:space:]]* groups below match that shape too,
# so reformatting the slice with stray spaces can no longer bypass the guard.
SHORT_SHA_HARDCODE_PATTERN='\$\{([A-Za-z_][A-Za-z0-9_]*)?[Ss][Hh][Aa][A-Za-z0-9_]*[[:space:]]*(:[[:space:]]*:[[:space:]]*[0-9]+|:[[:space:]]*0[[:space:]]*:[[:space:]]*[0-9]+)\}'


# Captured via command substitution, not a `mapfile -t files < <(...)`
# process substitution: a process substitution's own exit status is
# invisible to the reading command (mapfile here) and to `set -e`/
# `pipefail` alike -- if `git ls-files` (or the find/sed pipeline) fails
# outright (invalid ownership, an unreadable index, a malformed .git
# directory, and so on), `files` would silently end up empty and this
# blocking guard would report a false clean pass instead of failing
# closed. `$(...)` command substitution's own exit status IS checkable via
# a plain assignment's `if !`, which is what makes the explicit failure
# check below possible at all.
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

    # Captured via command substitution (see the rationale above) so grep's
    # real exit status is checkable: status 1 means "no match" (the normal,
    # expected outcome for most scanned files) but status >1 means grep
    # itself failed -- e.g. an unreadable file from corrupted runner
    # permissions -- which must fail this guard closed instead of being
    # silently folded into "no match" the way a bare `|| true` would.
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
    echo "short_sha=\"\$(dmeta_short_sha \"\$FULL_SHA_VAR\")\" instead -- see that file's own" >&2
    echo "header comment, and scripts/check-short-sha-truncation.sh's own header comment" >&2
    echo "for the full list of prior real instances this guard exists to prevent a" >&2
    echo "recurrence of." >&2
    exit 1
fi

echo "No hardcoded short-SHA truncation lengths found -- issue #1095 G2 holds."
