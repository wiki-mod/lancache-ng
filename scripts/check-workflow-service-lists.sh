#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI guard against a specific #822 recurrence shape: the service list that
# drives multi-platform manifest merge, channel promotion, and release is
# hardcoded as several independent `services=(...)` bash arrays inside
# separate embedded `run:` blocks of .github/workflows/build-push.yml, with
# no mechanism keeping them in sync. If a new service is added to the
# build/build-arm64 matrix but one of those copies is missed, that service is
# SILENTLY dropped from merge/promotion/release -- the loop just never
# iterates over it, with no error. This script fails CI the moment any copy
# diverges from the canonical set of built services.
#
# The canonical set is DERIVED from the build matrix (`- service:` entries),
# not hardcoded here: that is the one place a service must be added to be
# built at all, so deriving from it means adding a service automatically
# updates the canonical set and forces every `services=(...)` copy to follow
# or fail this check. A hardcoded canonical set would go stale in exactly the
# same silent way it is meant to prevent.
#
# `full_setup_services=(...)` is deliberately a SUBSET (it intentionally omits
# dhcp/dhcp-proxy), so it is checked as a subset of the canonical set, not for
# equality -- a naive "all lists identical" check would be wrong here.
#
# This same #822 recurrence shape was found again, beyond build-push.yml's 4
# internal copies (issue #935's original scope), in 3 more real files that
# duplicate the same service list with no sync mechanism:
#   - .github/workflows/gc-pr-staging-images.yml: a `services=(...)` copy
#     that must equal the full canonical set (its own comment: "Every
#     service build-push.yml's build/build-arm64 jobs can push a PR staging
#     tag for").
#   - .github/workflows/backfill-stack-latest.yml: a `services=(...)` copy
#     that is a deliberate, documented SUBSET excluding build-tools (its own
#     comment: "Product stack latest backfill intentionally excludes
#     build-tools"). Named `services=`, not `full_setup_services=`, but
#     semantically the same subset relationship -- see
#     SUBSET_SERVICES_FILES below.
#   - scripts/ensure-pr-staging-images.sh: a `full_setup_services=(...)`
#     copy -- see FULL_SETUP_EXACT_EXCLUSIONS below.
# All three are checked against the SAME canonical set derived from
# build-push.yml's build matrix below, since none of them has a build matrix
# of their own -- build-push.yml is the one place a service is actually built.
#
# For these two new subset-checked arrays specifically, "subset" means EXACT
# equality to canonical-minus-a-known-exclusion-set, not just "no phantom
# members": a membership-only check would silently accept a real service
# being DROPPED from the array (a shorter list is still a valid subset by
# that weaker definition), which is exactly the #822 failure mode this whole
# guard exists to catch. build-push.yml's own pre-existing
# `full_setup_services=(...)` check (used by the original 8 bats fixtures)
# intentionally keeps its original, looser membership-only semantics --
# tightening that one too is a separate, pre-existing-design decision outside
# this 3-file extension's scope.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# Optional first argument: path to the workflow file the canonical service
# set is derived from (its `- service:` build matrix), plus any further
# arguments naming additional files whose service-list arrays get checked
# against that same canonical set. Defaults (zero args) to this repo's
# build-push.yml plus the 3 additional real files above, so CI can call this
# with no arguments while the bats suite points it at a single self-contained
# fixture file (matrix + arrays together, exactly like the original
# single-file invocation this script started as) with no further arguments.
if [[ -n "${1:-}" ]]; then
    workflow="$1"
    shift
    extra_files=("$@")
else
    cd "$repo_root"
    workflow=".github/workflows/build-push.yml"
    extra_files=(
        ".github/workflows/gc-pr-staging-images.yml"
        ".github/workflows/backfill-stack-latest.yml"
        "scripts/ensure-pr-staging-images.sh"
    )
fi

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

fail() {
    printf "%b[SERVICE LISTS]%b %s\n" "$RED" "$NC" "$1" >&2
    violations=$((violations + 1))
}

violations=0

if [[ ! -f "$workflow" ]]; then
    printf "%b[SERVICE LISTS]%b expected workflow not found: %s\n" "$RED" "$NC" "$workflow" >&2
    exit 1
fi

# Canonical set: every distinct service the build matrix declares. Fail closed
# if extraction yields nothing -- an empty canonical set would make every
# comparison below vacuously pass, defeating the guard.
#
# The `|| true` is required, not decorative: `grep -oP` exits 1 (its normal,
# documented "no lines matched" status, not an error) when the matrix can't
# be parsed at all -- exactly the case this guard must fail closed on. Under
# `set -euo pipefail`, an unguarded `canonical=$(grep ... | sort -u)` would
# let that non-zero pipeline status kill the script right here via errexit,
# silently (no message, no diagnostic) before the `-z "$canonical"` check
# below ever runs -- defeating the very fail-closed path this comment block
# describes. `sort -u` never fails on empty input, so the only realistic
# non-zero pipeline outcome here is the intentional zero-match case, which is
# exactly what the next `if` is meant to catch and report.
canonical=$(grep -oP '^\s+- service:\s*\K[a-z0-9-]+' "$workflow" | sort -u || true)
if [[ -z "$canonical" ]]; then
    printf "%b[SERVICE LISTS]%b could not extract any '- service:' matrix entries from %s; refusing to run a vacuous check.\n" "$RED" "$NC" "$workflow" >&2
    exit 1
fi
canonical_oneline=$(printf '%s' "$canonical" | tr '\n' ' ')

# Normalize a `name=(a b c)` bash array line to a sorted, newline-separated
# element list so set comparison is order-independent.
array_elements() {
    sed -E 's/^[^(]*\(//; s/\).*$//' <<<"$1" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

# Set-difference helper: canonical minus a given exclusion list (both must be
# newline-separated; canonical is already sorted+unique, and this sorts+dedupes
# $1 too, since `comm` requires sorted input on both sides).
canonical_minus() {
    comm -23 <(printf '%s\n' "$canonical") <(printf '%s\n' "$1" | sort -u)
}

# Files where a `services=(...)` array is a deliberate, documented SUBSET of
# the canonical set rather than the full build matrix -- unlike every
# `services=(...)` copy inside build-push.yml itself (and inside
# gc-pr-staging-images.yml), which must always equal the full set. Keyed by
# basename so this stays readable regardless of a file's full path. The value
# is the EXACT, documented exclusion set (newline-separated), not just a
# boolean flag: checking only "no phantom members" would accept a real
# service silently being DROPPED from the array too, which is exactly the
# #822 failure mode this whole guard exists to catch -- a subset check must
# still assert equality against the one specific expected subset, not "any
# subset at all." Each entry here must be backed by that file's own inline
# comment explaining the intentional exclusion (see backfill-stack-latest.yml's
# "Product stack latest backfill intentionally excludes build-tools" comment).
declare -A SUBSET_SERVICES_FILES=(
    ["backfill-stack-latest.yml"]="build-tools"
)

# Checks every `services=(...)` array in $1. Equal-to-canonical by default;
# equal-to-(canonical-minus-exclusions) for files listed in
# SUBSET_SERVICES_FILES above. $2 ("required" or "optional") controls whether
# finding zero arrays in this file is itself a failure: "required" for files
# where a `services=(...)` array is known to always exist (build-push.yml,
# gc-pr-staging-images.yml, backfill-stack-latest.yml) so a rename/refactor
# that silently removes it is caught; "optional" for files that legitimately
# never declare one (e.g. ensure-pr-staging-images.sh only has
# full_setup_services=(...), checked separately below).
check_services_arrays() {
    local file="$1" requirement="$2" file_basename lineno content elements entry
    local -a entries
    local expected expected_oneline
    file_basename=$(basename "$file")
    if [[ -n "${SUBSET_SERVICES_FILES[$file_basename]:-}" ]]; then
        expected=$(canonical_minus "${SUBSET_SERVICES_FILES[$file_basename]}")
    else
        expected="$canonical"
    fi
    expected_oneline=$(printf '%s' "$expected" | tr '\n' ' ')

    # `[[:space:]]*` (zero or more), not `+`: build-push.yml's copies are
    # indented (embedded in a YAML `run:` block), but a plain shell script
    # like ensure-pr-staging-images.sh declares this at column 0 with no
    # leading whitespace at all. Requiring `+` would silently never match
    # those column-0 files, defeating the guard for them specifically.
    mapfile -t entries < <(grep -nE '^[[:space:]]*services=\(' "$file" || true)
    if [[ ${#entries[@]} -eq 0 ]]; then
        if [[ "$requirement" == "required" ]]; then
            # Fail closed rather than silently pass: if this array was
            # renamed or refactored away, this guard no longer protects that
            # file and must be revisited deliberately, not left green by
            # accident.
            fail "no 'services=(...)' array found in $file -- was it renamed or refactored? Update this guard deliberately."
        fi
        return
    fi

    for entry in "${entries[@]}"; do
        lineno=${entry%%:*}
        content=${entry#*:}
        elements=$(array_elements "$content")
        if [[ "$elements" != "$expected" ]]; then
            fail "services=(...) at $file:$lineno diverges from the expected set."
            printf "    expected: %s\n" "$expected_oneline" >&2
            printf "    found:    %s\n" "$(printf '%s' "$elements" | tr '\n' ' ')" >&2
        fi
    done
}

# Files where full_setup_services=(...) must equal canonical minus a KNOWN,
# EXACT exclusion set (not just "no phantom members") -- same reasoning as
# SUBSET_SERVICES_FILES above: membership-only checking would silently accept
# a real service being dropped. Scoped to ensure-pr-staging-images.sh, since
# its full_setup_services=(...) is meant to mirror build-push.yml's own
# full_setup_services=(...) exactly (both represent the same full-setup
# validation scope). build-push.yml's own copy intentionally keeps the
# original, looser membership-only check below -- it has an established bats
# test (further up this file) exercising an arbitrary smaller subset as a
# valid case, so tightening it to exact-equality is a separate, pre-existing-
# design decision outside the scope of this 3-file extension.
declare -A FULL_SETUP_EXACT_EXCLUSIONS=(
    ["ensure-pr-staging-images.sh"]="dhcp
dhcp-proxy"
)

# Checks every `full_setup_services=(...)` array in $1. For files listed in
# FULL_SETUP_EXACT_EXCLUSIONS, must equal canonical minus that exact
# exclusion set. Otherwise (build-push.yml's own copy), the original,
# looser "subset of canonical" check: flags only elements NOT in canonical,
# accepting any smaller subset. $2 ("required" or "optional") mirrors
# check_services_arrays's requirement parameter, for the same reason: a file
# known to always declare one (build-push.yml, ensure-pr-staging-images.sh)
# must fail closed if that array vanishes.
check_full_setup_arrays() {
    local file="$1" requirement="$2" file_basename lineno content entry elements
    local -a entries
    local expected expected_oneline
    file_basename=$(basename "$file")
    # Same `[[:space:]]*` reasoning as check_services_arrays above:
    # ensure-pr-staging-images.sh declares full_setup_services=(...) at
    # column 0, not indented inside a YAML `run:` block.
    mapfile -t entries < <(grep -nE '^[[:space:]]*full_setup_services=\(' "$file" || true)
    if [[ ${#entries[@]} -eq 0 && "$requirement" == "required" ]]; then
        fail "no 'full_setup_services=(...)' array found in $file -- was it renamed or refactored? Update this guard deliberately."
        return
    fi

    if [[ -n "${FULL_SETUP_EXACT_EXCLUSIONS[$file_basename]:-}" ]]; then
        expected=$(canonical_minus "${FULL_SETUP_EXACT_EXCLUSIONS[$file_basename]}")
        expected_oneline=$(printf '%s' "$expected" | tr '\n' ' ')
        for entry in "${entries[@]}"; do
            lineno=${entry%%:*}
            content=${entry#*:}
            elements=$(array_elements "$content")
            if [[ "$elements" != "$expected" ]]; then
                fail "full_setup_services=(...) at $file:$lineno diverges from the expected set."
                printf "    expected: %s\n" "$expected_oneline" >&2
                printf "    found:    %s\n" "$(printf '%s' "$elements" | tr '\n' ' ')" >&2
            fi
        done
        return
    fi

    for entry in "${entries[@]}"; do
        lineno=${entry%%:*}
        content=${entry#*:}
        while IFS= read -r elem; do
            [[ -z "$elem" ]] && continue
            if ! grep -qxF "$elem" <<<"$canonical"; then
                fail "full_setup_services=(...) at $file:$lineno contains '$elem', which is not a known build-matrix service."
            fi
        done < <(array_elements "$content")
    done
}

# Per-extra-file expectation of which array kind each file must declare at
# least one of (basename-keyed, same reasoning as SUBSET_SERVICES_FILES
# above). This is what lets check_services_arrays/check_full_setup_arrays
# fail closed per file instead of either over-requiring (e.g. demanding
# ensure-pr-staging-images.sh have a services=(...) array it never had) or
# under-requiring (silently accepting the array vanishing from a file that
# should always have it).
declare -A REQUIRES_SERVICES_ARRAY=(
    ["gc-pr-staging-images.yml"]=1
    ["backfill-stack-latest.yml"]=1
)
declare -A REQUIRES_FULL_SETUP_ARRAY=(
    ["ensure-pr-staging-images.sh"]=1
)

# The matrix-source file itself always requires at least one services=(...)
# copy (this is build-push.yml's own long-standing invariant, preserved
# exactly for the single-file bats-fixture invocation too). It is not itself
# required to declare full_setup_services=(...) -- a bats fixture testing
# only the services=(...) equality case has no reason to include one.
check_services_arrays "$workflow" "required"
check_full_setup_arrays "$workflow" "optional"

for file in "${extra_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        fail "expected file not found: $file -- was it renamed, moved, or removed? Update this guard deliberately."
        continue
    fi
    file_basename=$(basename "$file")

    services_requirement="optional"
    [[ -n "${REQUIRES_SERVICES_ARRAY[$file_basename]:-}" ]] && services_requirement="required"
    check_services_arrays "$file" "$services_requirement"

    full_setup_requirement="optional"
    [[ -n "${REQUIRES_FULL_SETUP_ARRAY[$file_basename]:-}" ]] && full_setup_requirement="required"
    check_full_setup_arrays "$file" "$full_setup_requirement"
done

if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d service-list divergence(s) found.%b Keep every services=(...)/full_setup_services=(...) copy in sync with the build matrix; see issue #822.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All checked service lists are consistent with the build matrix (%s).%b\n" "$GREEN" "$canonical_oneline" "$NC"
exit 0
