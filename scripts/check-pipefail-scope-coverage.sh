#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Standing coverage guard for scripts/check-pipefail-early-exit-grep.sh's own
# test suite: verifies tests/bats/check_pipefail_early_exit_grep.bats
# actually exercises every top-level path prefix that guard's own scan_files
# discovery covers, not just some of them. Mirrors this project's existing
# standing-coverage-check pattern (scripts/check-idempotence-test-coverage.sh,
# scripts/check-bats-path-filter-coverage.sh, scripts/check-build-tools-smoke-
# coverage.sh): a small, targeted structural check, not full code-coverage
# instrumentation.
#
# WHY THIS EXISTS: check-pipefail-early-exit-grep.sh's own header once
# claimed repo-wide coverage while its actual scan_files glob list omitted
# services/** entirely -- a real, previously-undetected instance of the
# exact failure class this guard exists to catch survived in
# services/dns/entrypoint.sh as a result (issue #1505). The glob list has
# since been corrected, but nothing stopped a *future* edit from narrowing
# it again with the test suite staying green throughout, since a test suite
# proves only what it actually exercises. This closes that gap generically:
# it derives the expected prefixes from the guard's own current source
# rather than hardcoding them, so it keeps working (or starts failing
# loudly) if that scope list changes again.
#
# WHAT THIS DOES NOT DO: like the guard it checks, this is a deliberately
# cheap, grep-based heuristic, not a real shell/bats parser. "Covered" means
# the prefix substring appears somewhere on a non-comment line of the bats
# file -- it does not verify the fixture actually contains a pipefail
# violation, only that some fixture targets that path prefix at all. A
# maintainer adding a fixture there is expected to make it a real violation
# case, the same trust this project already extends to every other
# structural coverage check listed above.
#
# Usage: check-pipefail-scope-coverage.sh [directory]
# Defaults to this script's own repo root; an explicit directory (a
# throwaway fixture repo) is used by this script's own bats coverage.
set -euo pipefail

# Optional directory argument, mirroring check-pipefail-early-exit-grep.sh's
# own convention: defaults to this script's real repo root for normal CI/
# developer use, but accepts a throwaway fixture directory so bats can
# exercise this script's own extraction/matching logic in isolation without
# ever touching this repository's real check-pipefail-early-exit-grep.sh or
# its bats file.
if [ "$#" -gt 0 ]; then
    repo_root=$(cd "$1" && pwd)
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/.." && pwd)
fi
cd "$repo_root"

guard_script="scripts/check-pipefail-early-exit-grep.sh"
guard_bats="tests/bats/check_pipefail_early_exit_grep.bats"

for f in "$guard_script" "$guard_bats"; do
    if [ ! -f "$f" ]; then
        printf '::error::check-pipefail-scope-coverage: %s not found\n' "$f" >&2
        exit 1
    fi
done

# Extract the quoted pathspec literals from the guard's own `git ls-files --
# ...` discovery block, then reduce each to its top-level prefix: a leading
# directory name, or the literal filename for a bare file like setup.sh.
mapfile -t raw_patterns < <(grep -oE "'[a-zA-Z0-9_.*/-]+'" "$guard_script" | tr -d "'" | grep -E '^(scripts|tools|services)/|^setup\.sh$')

if [ "${#raw_patterns[@]}" -eq 0 ]; then
    printf '::error::check-pipefail-scope-coverage: found no scan_files pathspecs in %s -- did its git ls-files block change shape?\n' "$guard_script" >&2
    exit 1
fi

declare -A prefixes=()
for pattern in "${raw_patterns[@]}"; do
    if [[ "$pattern" == */* ]]; then
        prefixes["${pattern%%/*}/"]=1
    else
        prefixes["$pattern"]=1
    fi
done

# Full comment lines are excluded the same way the guard itself excludes
# them when scanning for violations, so a prefix only mentioned in prose
# (e.g. this guard's own header comment) does not count as a real fixture.
non_comment_bats="$(grep -v '^[[:space:]]*#' "$guard_bats")"

missing=()
for prefix in "${!prefixes[@]}"; do
    if ! grep -qF "$prefix" <<<"$non_comment_bats"; then
        missing+=("$prefix")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    printf '::error::check-pipefail-scope-coverage: %s has no fixture exercising these scan_files prefixes from %s:\n' "$guard_bats" "$guard_script" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Add a write_script/write_dockerfile fixture under each missing prefix (see the existing scripts/**, tools/**, setup.sh, services/** cases) so a future narrowing of scan_files fails this suite instead of passing silently." >&2
    exit 1
fi

printf 'check-pipefail-scope-coverage: OK (every scan_files prefix in %s has an exercising fixture in %s).\n' "$guard_script" "$guard_bats"
