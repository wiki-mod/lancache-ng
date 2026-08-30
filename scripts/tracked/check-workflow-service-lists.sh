#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
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
# `full_setup_services=(...)` is deliberately a SUBSET, so it is checked as a
# subset of the canonical set, not for equality -- a naive "all lists
# identical" check would be wrong here. The two `full_setup_services=(...)`
# copies below no longer share one exclusion set as of #1296 (2026-07-30):
# build-push.yml's own copy (the compose-only, product-stack membership list)
# still intentionally omits dhcp/dhcp-proxy/ntp, but scripts/ensure-pr-staging-
# images.sh's copy (the deep-validation staging-image list) now includes all
# three -- see FULL_SETUP_EXACT_EXCLUSIONS below, whose exclusion set for that
# file is now empty (ntp was the last member, added #1296). Do not assume the
# two arrays mirror each other's exclusions; check each file's own comment.
#
# This same #822 recurrence shape was found again, beyond build-push.yml's 4
# internal copies (issue #935's original scope), in 3 more real files that
# duplicate the same service list with no sync mechanism:
#   - scripts/untracked/gc-pr-staging-images.sh: a `services=(...)` copy that must
#     equal the full canonical set (its own comment: "Every service
#     build-push.yml's build/build-arm64 jobs can push a PR staging tag
#     for"). Until #1095 (2026-08-06) this array lived inline in
#     .github/workflows/gc-pr-staging-images.yml's own `run:` block, which is
#     why this guard originally pointed at the workflow file; the reap/
#     orphan-classification logic (array included) moved into this
#     standalone, bats-testable script, and this guard's target moved with
#     it. gc-pr-staging-images.yml itself no longer declares any
#     services=(...) array at all -- it only checks out and runs the script.
#   - .github/workflows/backfill-stack-latest.yml: a `services=(...)` copy
#     that is a deliberate, documented SUBSET excluding build-tools (its own
#     comment: "Product stack latest backfill intentionally excludes
#     build-tools"). Named `services=`, not `full_setup_services=`, but
#     semantically the same subset relationship -- see
#     SUBSET_SERVICES_FILES below.
#   - scripts/untracked/ensure-pr-staging-images.sh: a `full_setup_services=(...)`
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
repo_root=$(cd "$script_dir/../.." && pwd)

# Optional first argument: path to the workflow file the canonical service
# set is derived from (its `- service:` build matrix), plus any further
# arguments naming additional files whose service-list arrays get checked
# against that same canonical set. Defaults (zero args) to this repo's
# build-push.yml plus the additional real files below, so CI can call this
# with no arguments while the bats suite points it at a single self-contained
# fixture file (matrix + arrays together, exactly like the original
# single-file invocation this script started as) with no further arguments.
# Optional --hosted-fallback <path> flag, consumed before the positional
# workflow/extra-file arguments below: build-push-hosted-fallback.yml
# duplicates the same build-matrix service decision a third way -- associative
# bash maps (contexts/build_contexts/descriptions) plus a selected=(...) default set --
# rather than a services=(...)/full_setup_services=(...) array this guard's
# existing check_services_arrays/check_full_setup_arrays functions already
# understand. That representation needs its own comparison logic
# (check_hosted_fallback_matrix below), so it is threaded through as a named
# flag rather than another positional array-bearing file, and is optional
# (empty hosted_fallback = skip) so the single-file bats-fixture invocation
# path stays exactly as before for callers that don't pass it.
hosted_fallback=""
if [[ "${1:-}" == "--hosted-fallback" ]]; then
    [[ -n "${2:-}" ]] || { printf "[SERVICE LISTS] --hosted-fallback requires a path\n" >&2; exit 1; }
    hosted_fallback="$2"
    shift 2
fi

if [[ -n "${1:-}" ]]; then
    workflow="$1"
    shift
    extra_files=("$@")
else
    cd "$repo_root"
    workflow=".github/workflows/build-push.yml"
    hosted_fallback="${hosted_fallback:-.github/workflows/build-push-hosted-fallback.yml}"
    extra_files=(
        "scripts/untracked/gc-pr-staging-images.sh"
        ".github/workflows/backfill-stack-latest.yml"
        "scripts/untracked/ensure-pr-staging-images.sh"
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

# build-push.yml uses one workflow-level runtime list for its shell loops.
# Older/synthetic fixtures may still use services=(...) directly, so the guard
# supports both shapes and fails closed if the runtime list diverges.
workflow_services_requirement="required"
mapfile -t workflow_service_entries < <(grep -nE '^  CI_BUILD_SERVICES:[[:space:]]*' "$workflow" || true)
if [[ ${#workflow_service_entries[@]} -gt 1 ]]; then
    fail "multiple CI_BUILD_SERVICES declarations found in $workflow; expected one maintained runtime list."
elif [[ ${#workflow_service_entries[@]} -eq 1 ]]; then
    entry=${workflow_service_entries[0]}
    content=${entry#*:}
    value=${content#*:}
    value="$(xargs <<<"$value")"
    value=${value#\"}
    value=${value%\"}
    runtime_services=$(printf '%s\n' "$value" | tr ' ' '\n' | sed '/^$/d' | sort -u)
    if [[ "$runtime_services" != "$canonical" ]]; then
        fail "CI_BUILD_SERVICES in $workflow diverges from the build matrix."
        printf "    expected: %s\n" "$canonical_oneline" >&2
        printf "    found:    %s\n" "$(printf '%s' "$runtime_services" | tr '\n' ' ')" >&2
    fi
    workflow_services_requirement="optional"
fi

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
# scripts/untracked/gc-pr-staging-images.sh), which must always equal the full set. Keyed by
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
    # utilities (issue #1556) added alongside the pre-existing build-tools
    # exclusion for the identical reason: this is a shared, non-runtime
    # CI/tooling image (like build-tools), never part of the product stack
    # `latest`-channel backfill loop rebuilds. See that workflow's own
    # inline comment for the full rationale this mirrors.
    ["backfill-stack-latest.yml"]=$'build-tools\nutilities'
)

# Checks every `services=(...)` array in $1. Equal-to-canonical by default;
# equal-to-(canonical-minus-exclusions) for files listed in
# SUBSET_SERVICES_FILES above. $2 ("required" or "optional") controls whether
# finding zero arrays in this file is itself a failure: "required" for files
# where a `services=(...)` array is known to always exist (build-push.yml,
# scripts/untracked/gc-pr-staging-images.sh, backfill-stack-latest.yml) so a rename/refactor
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
# a real service being dropped. Scoped to ensure-pr-staging-images.sh. Before
# #1296 (2026-07-30), its full_setup_services=(...) exclusion set mirrored
# build-push.yml's own full_setup_services=(...) exactly (both represented
# the same full-setup validation scope); since #1296, the two have
# deliberately diverged -- ensure-pr-staging-images.sh's own list is now
# narrower (as of the #1296 completion below, EMPTY -- see the entry's own
# comment), because it must ensure a staging image exists for every service a
# deep-validation simulation actually pulls, which is not the same scope as
# build-push.yml's compose-membership list. Do not "fix" this file's
# exclusion set back to matching build-push.yml's -- that would reintroduce
# #1296. build-push.yml's own copy intentionally keeps the original, looser
# membership-only check below -- it has an established bats test (further up
# this file) exercising an arbitrary smaller subset as a valid case, so
# tightening it to exact-equality is a separate, pre-existing-design decision
# outside the scope of this 3-file extension.
declare -A FULL_SETUP_EXACT_EXCLUSIONS=(
    # #1296 (2026-07-30): dhcp and dhcp-proxy moved OUT of this exclusion set
    # first -- ensure-pr-staging-images.sh started ensuring both, since
    # scripts/untracked/simulations/syslog-forwarding-simulation.sh's Triggers 7/8 (added by #864,
    # after this exclusion set was first written) pull both images directly.
    # ntp (the last remaining member) moved out too once
    # scripts/untracked/simulations/syslog-forwarding-simulation.sh gained a real ntp
    # start+healthcheck consumer (see ensure-pr-staging-images.sh's own
    # full_setup_services=(...) comment) -- completing #1296's original 3-of-3
    # ask. The key is kept PRESENT with an empty value (rather than deleted
    # outright) so this file stays routed through the exact-equality branch
    # below instead of falling back to the looser membership-only check that
    # applies to a file with no entry here at all -- see that branch's own
    # comment for why a key-EXISTENCE test, not a non-empty-VALUE test, is
    # what makes an empty exclusion set actually behave as "equals canonical
    # exactly" rather than silently degrading to the weaker check.
    # utilities (issue #1556): not part of the full-setup/deploy product
    # stack (AG-VAL-027 Scope-Boundaries exception -- it is a shared,
    # non-runtime CI/tooling image other services may COPY --from= later,
    # not a service full-setup-deep-validate itself starts/health-checks),
    # so no deep-validation simulation needs a staging image for it. Mirrors
    # the reasoning that already excludes build-tools from this same file's
    # full_setup_services=(...) array (see that array's own comment).
    ["ensure-pr-staging-images.sh"]="utilities"
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

    # `-v` (key EXISTENCE), not `-n "${...:-}"` (non-empty VALUE): the latter
    # would have been a real, silent bug the moment #1296 emptied out
    # ensure-pr-staging-images.sh's exclusion entry above -- an empty-but-
    # present value makes `-n` false, which would route this file into the
    # looser membership-only branch below instead of the exact-equality
    # branch its own array entry documents it as belonging to. `-v` correctly
    # treats "key present, value empty" as "yes, exact-equality-checked, with
    # zero exclusions" -- exactly what an empty exclusion set is supposed to
    # mean (equals canonical exactly), not "not scoped into this check at
    # all." Requires bash >= 4.3 (`-v` on an array subscript), already implied
    # by this script's associative-array usage throughout.
    if [[ -v FULL_SETUP_EXACT_EXCLUSIONS[$file_basename] ]]; then
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

# The GitHub-hosted build fallback duplicates the same build-matrix service
# decision in associative maps rather than services=(...) arrays. Validate the
# keys and default selection against the canonical build matrix so a new service
# cannot silently disappear only when the fallback path is needed. Deliberately
# checks map KEYS only, not the descriptions map's VALUES: a description-text
# drift between build-push.yml's matrix and this fallback (e.g. a stale/
# mismatched wording, not a missing/extra service) is a real but much lower-
# stakes gap than a service silently failing to build, and value-comparison
# would need to reach into build-push.yml's own multiline matrix parsing this
# script does not otherwise do -- out of scope for this guard's #822 failure
# class (a service silently dropped from a copy), which is about set
# membership, not per-field content equality.
assoc_array_keys() {
    local file="$1" array_name="$2"
    awk -v target="$array_name" '
      BEGIN { in_block=0; found=0 }
      $0 ~ "^[[:space:]]*declare -A[[:space:]]+" target "=\\([[:space:]]*$" { in_block=1; found=1; next }
      in_block && /^[[:space:]]*\)[[:space:]]*$/ { in_block=0; exit }
      in_block {
        line=$0
        if (line ~ /^[[:space:]]*\[[a-z0-9-]+\]=/) {
          sub(/^[[:space:]]*\[/, "", line)
          sub(/\].*$/, "", line)
          print line
        }
      }
      END { if (!found) exit 2 }
    ' "$file" | sort -u
}

check_hosted_fallback_matrix() {
    local file="$1" array_name elements selected_entry selected_elements
    local -a selected_entries
    [[ -f "$file" ]] || { fail "expected hosted fallback workflow not found: $file"; return; }

    for array_name in contexts build_contexts descriptions; do
        if ! elements="$(assoc_array_keys "$file" "$array_name")"; then
            fail "hosted fallback $file is missing declare -A ${array_name}=(...)"
            continue
        fi
        if [[ "$elements" != "$canonical" ]]; then
            fail "hosted fallback ${array_name} keys in $file diverge from the build matrix."
            printf "    expected: %s\n" "$canonical_oneline" >&2
            printf "    found:    %s\n" "$(printf '%s' "$elements" | tr '\n' ' ')" >&2
        fi
    done

    mapfile -t selected_entries < <(grep -nE '^[[:space:]]*selected=\(' "$file" || true)
    if [[ ${#selected_entries[@]} -eq 0 ]]; then
        fail "hosted fallback $file has no selected=(...) default service set"
        return
    fi
    for selected_entry in "${selected_entries[@]}"; do
        selected_elements="$(array_elements "${selected_entry#*:}")"
        if [[ "$selected_elements" != "$canonical" ]]; then
            fail "hosted fallback selected=(...) at $file:${selected_entry%%:*} diverges from the build matrix."
            printf "    expected: %s\n" "$canonical_oneline" >&2
            printf "    found:    %s\n" "$(printf '%s' "$selected_elements" | tr '\n' ' ')" >&2
        fi
    done
}

# What: fails if push-triggered jobs lack push-supersession-check
# Why: referencing needs[] without declaring is a silent no-op
# From: Issue #1095 | PR #1628
check_push_supersession_wiring() {
    local file="$1" job block needs_section
    local -a required_jobs=(build build-arm64 container-scan merge-manifests full-setup-validate)

    # What: skips check unless file defines all five required jobs
    # Why: narrow test fixtures model only build: matrix, not all five
    # From: Issue #1095 | PR #1628
    for job in "${required_jobs[@]}"; do
        grep -qE "^  ${job}:[[:space:]]*\$" "$file" || return 0
    done

    for job in "${required_jobs[@]}"; do
        block="$(awk -v job="  ${job}:" '
            $0 == job { found=1 }
            found && /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ && $0 != job { exit }
            found { print }
        ' "$file")"
        # What: extracts only needs: declaration, not the whole job block
        # Why: bare grep matches check's own reference comments as well
        # From: Issue #1095 | PR #1628
        needs_section="$(awk '
            /^    needs:/ { grab=1; print; next }
            grab && /^      - / { print; next }
            grab { exit }
        ' <<<"$block")"
        if ! grep -q "push-supersession-check" <<<"$needs_section"; then
            fail "job '$job' in $file is missing push-supersession-check from its own needs: list (see merge-manifests' create-trusted-manifests step, PR #1628, for the reference pattern)."
        fi
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
    ["gc-pr-staging-images.sh"]=1
    ["backfill-stack-latest.yml"]=1
)
declare -A REQUIRES_FULL_SETUP_ARRAY=(
    ["ensure-pr-staging-images.sh"]=1
)

# The production workflow uses CI_BUILD_SERVICES; legacy synthetic fixtures may
# still use services=(...). full_setup_services=(...) remains optional here.
check_services_arrays "$workflow" "$workflow_services_requirement"
check_full_setup_arrays "$workflow" "optional"
check_push_supersession_wiring "$workflow"
[[ -z "$hosted_fallback" ]] || check_hosted_fallback_matrix "$hosted_fallback"

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
    printf "%b✗ %d service-list/metadata divergence(s) found.%b Keep runtime service metadata in sync with the build matrix.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All checked service lists and metadata are consistent with the build matrix (%s).%b\n" "$GREEN" "$canonical_oneline" "$NC"
exit 0
