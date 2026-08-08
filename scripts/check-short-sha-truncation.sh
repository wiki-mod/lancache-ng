#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# GITHUB_SHA, full_sha) -- not a broad ban on the substring-slice syntax
# itself (which has many legitimate, unrelated uses this guard must not
# flag), and not limited to an assignment context: a bare interpolation like
# "sha-${ancestor_sha:0:7}" is caught exactly the same as a
# short_sha="${VAR::7}" assignment, since both independently hardcode the
# truncation length instead of calling dmeta_short_sha(). Widened from an
# earlier, narrower version of this guard that matched only a variable
# literally named `short_sha` in assignment position -- that version passed
# this project's own real tree cleanly (0 violations) while remaining
# structurally unable to catch the exact `base_sha_short`/`ancestor_sha_short`
# assignment shapes and bare-interpolation shapes this same effort had just
# migrated in scripts/lib/staging-ancestor-fallback.sh, which is the same
# "declared value not actually read at every site" risk AG-CI-022 exists to
# close -- a guard for that class should not itself have a shape-based blind
# spot. scripts/lib/docker-metadata.sh's OWN internal `${full_sha:0:length}`
# slice (length is a variable, not a literal digit) stays exempt by
# construction -- the regex below only matches a literal digit run, never a
# bare identifier -- since that line IS the single declared implementation
# this guard exists to make everyone else call, not a violation of it. A
# repo-wide grep confirmed zero non-comment `*sha*::N`/`*sha*:0:N` matches
# remain anywhere in this guard's current file scope before this widening
# shipped, so it starts from a real, verified-clean baseline rather than an
# assumed one.
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
# line, whose length is a variable, from ever matching this pattern).
SHORT_SHA_HARDCODE_PATTERN='\$\{[A-Za-z_]*[Ss][Hh][Aa][A-Za-z0-9_]*(::[0-9]+|:0:[0-9]+)\}'

if [ -e "$target_root/.git" ]; then
    mapfile -t files < <(git ls-files -- '.github/workflows/*.yml' 'scripts/lib/*.sh')
else
    mapfile -t files < <(find . \( -path './.github/workflows/*.yml' -o -path './scripts/lib/*.sh' \) -type f -print | sed 's#^\./##')
fi

violations=()
for path in "${files[@]}"; do
    [ -f "$path" ] || continue
    is_self_reference "$path" && continue

    while IFS= read -r match; do
        [ -n "$match" ] || continue
        violations+=("$match")
    done < <(grep -EnH "$SHORT_SHA_HARDCODE_PATTERN" "$path" || true)
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
