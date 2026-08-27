#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing coverage guard for scripts/tracked/check-pipefail-early-exit-grep.sh's own
# test suite: verifies tests/bats/check_pipefail_early_exit_grep.bats
# actually exercises every top-level path prefix that guard's own scan_files
# discovery covers, not just some of them. Mirrors this project's existing
# standing-coverage-check pattern (scripts/untracked/check-idempotence-test-coverage.sh,
# scripts/untracked/check-bats-path-filter-coverage.sh, scripts/untracked/check-build-tools-smoke-
# coverage.sh): a small, targeted structural check, not full code-coverage
# instrumentation.
#
# WHY THIS EXISTS: check-pipefail-early-exit-grep.sh's own header once
# claimed repo-wide coverage while its actual scan_files glob list omitted
# services/** entirely -- a real, previously-undetected instance of the
# exact failure class this guard exists to catch survived in
# services/dns/entrypoint.sh as a result. The glob list has
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
    repo_root=$(cd "$script_dir/../.." && pwd)
fi
cd "$repo_root"

guard_script="scripts/tracked/check-pipefail-early-exit-grep.sh"
guard_bats="tests/bats/check_pipefail_early_exit_grep.bats"

for f in "$guard_script" "$guard_bats"; do
    if [ ! -f "$f" ]; then
        printf '::error::check-pipefail-scope-coverage: %s not found\n' "$f" >&2
        exit 1
    fi
done

# Independently pinned -- deliberately NOT derived from the guard's own
# current source. Deriving "required" from the exact same file this check
# is supposed to police is a tautology: narrowing the guard's own scope
# would narrow this check's expectation right along with it, so a
# recurrence of that class of regression (scan_files silently
# missing a whole path class) would keep passing this check indefinitely
# instead of ever failing it. This is the project's own documented minimum
# scope for AG-VAL-032 enforcement (see AGENTS.md's enforcement-matrix row
# for that rule) and must be updated by hand, deliberately, whenever that
# documented scope changes -- never automatically re-derived from the guard.
REQUIRED_PREFIXES=(scripts/ tools/ setup.sh services/)
REQUIRED_PATTERNS=(
    'scripts/*.sh' 'scripts/**/*.sh'
    'tools/*.sh' 'tools/**/*.sh' 'tools/*/Dockerfile*'
    'services/*.sh' 'services/**/*.sh' 'services/*/Dockerfile*'
    'setup.sh'
)

# Extract the quoted pathspec literals from the guard's own `git ls-files --
# ...` discovery block, then reduce each to its top-level prefix: a leading
# directory name, or the literal filename for a bare file like setup.sh.
mapfile -t raw_patterns < <(grep -oE "'[a-zA-Z0-9_.*/-]+'" "$guard_script" | tr -d "'" | grep -E '^(scripts|tools|services)/|^setup\.sh$')

if [ "${#raw_patterns[@]}" -eq 0 ]; then
    printf '::error::check-pipefail-scope-coverage: found no scan_files pathspecs in %s -- did its git ls-files block change shape?\n' "$guard_script" >&2
    exit 1
fi

# Prefix coverage alone cannot distinguish service shell scripts from
# service Dockerfiles. Preserve every policy-required pathspec verbatim so
# retaining one services/** class cannot conceal removal of the other.
missing_patterns=()
for required_pattern in "${REQUIRED_PATTERNS[@]}"; do
    found=0
    for actual_pattern in "${raw_patterns[@]}"; do
        if [ "$actual_pattern" = "$required_pattern" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        missing_patterns+=("$required_pattern")
    fi
done
if [ "${#missing_patterns[@]}" -gt 0 ]; then
    printf '::error::check-pipefail-scope-coverage: %s no longer scans these required pathspec classes:\n' "$guard_script" >&2
    printf '  %s\n' "${missing_patterns[@]}" >&2
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

# The guard's own scope must not have narrowed below REQUIRED_PREFIXES --
# checked independently of, and before, the bats-fixture-coverage check
# below (a fixture cannot cover a prefix the guard does not even scan).
missing_required=()
for required in "${REQUIRED_PREFIXES[@]}"; do
    if [ -z "${prefixes[$required]-}" ]; then
        missing_required+=("$required")
    fi
done

if [ "${#missing_required[@]}" -gt 0 ]; then
    printf '::error::check-pipefail-scope-coverage: %s no longer scans these required prefixes:\n' "$guard_script" >&2
    printf '  %s\n' "${missing_required[@]}" >&2
    echo "This is a real narrowing of AG-VAL-032 enforcement (the exact failure class this check exists to catch), not a bats-fixture gap -- widen scan_files in $guard_script itself before this can pass." >&2
    exit 1
fi

# Full comment lines are excluded the same way the guard itself excludes
# them when scanning for violations, so a prefix only mentioned in prose
# (e.g. this guard's own header comment) does not count as a real fixture.
# `grep -v` exits 1 (not just "empty output") when EVERY line matched the
# excluded pattern -- a comments-only or empty bats file -- and a plain
# top-level `var=$(cmd)` assignment's failure aborts this script outright
# under `set -e`, before any of this check's own diagnostics ever run.
# Status 1 here is a legitimate "nothing left after excluding comments"
# result, not a real failure; only a status >1 (grep itself erroring, e.g.
# an unreadable file) should propagate as a hard error.
grep_status=0
non_comment_bats="$(grep -v '^[[:space:]]*#' "$guard_bats")" || grep_status=$?
if [ "$grep_status" -gt 1 ]; then
    printf '::error::check-pipefail-scope-coverage: could not read %s (grep exit %s)\n' "$guard_bats" "$grep_status" >&2
    exit 1
fi

missing=()
for prefix in "${!prefixes[@]}"; do
    if ! grep -qF "$prefix" <<<"$non_comment_bats"; then
        missing+=("$prefix")
    fi
done

# A services shell fixture does not exercise the separate service-Dockerfile
# discovery path. Require both forms explicitly in addition to the general
# prefix check above.
if ! grep -qF 'services/example-service/Dockerfile' <<<"$non_comment_bats"; then
    missing+=("services/*/Dockerfile*")
fi

if [ "${#missing[@]}" -gt 0 ]; then
    printf '::error::check-pipefail-scope-coverage: %s has no fixture exercising these scan_files prefixes from %s:\n' "$guard_bats" "$guard_script" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "Add a write_script/write_dockerfile fixture under each missing prefix (see the existing scripts/**, tools/**, setup.sh, services/** cases) so a future narrowing of scan_files fails this suite instead of passing silently." >&2
    exit 1
fi

printf 'check-pipefail-scope-coverage: OK (every scan_files prefix in %s has an exercising fixture in %s).\n' "$guard_script" "$guard_bats"
