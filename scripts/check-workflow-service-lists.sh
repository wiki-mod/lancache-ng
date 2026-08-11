#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI guard for service-set and build-metadata drift.
# The normal build matrix is canonical. Runtime service loops, Hosted Fallback,
# GC/backfill helpers, and Full-Setup subsets must stay consistent with it.
# Deliberate subsets are checked against explicit exclusion sets so dropping a
# real service cannot pass merely because the shorter list is still a subset.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# Optional first argument: path to the workflow file the canonical service
# set is derived from (its `- service:` build matrix), plus any further
# arguments naming additional files whose service-list arrays get checked
# against that same canonical set. Defaults (zero args) to this repo's
# build-push.yml plus the additional real files below, so CI can call this
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
        ".github/workflows/build-push-hosted-fallback.yml"
        "scripts/gc-pr-staging-images.sh"
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
# scripts/gc-pr-staging-images.sh), which must always equal the full set. Keyed by
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
# scripts/gc-pr-staging-images.sh, backfill-stack-latest.yml) so a rename/refactor
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


# Extract one field from the anchored normal-build matrix. The matrix values in
# this workflow are scalar strings; description anchors are stripped before
# comparison because the alias name is YAML structure, not metadata content.
extract_matrix_metadata() {
    local field="$1"
    awk -v field="$field" '
        /^[[:space:]]+include: &normal-build-services[[:space:]]*$/ { inside=1; next }
        inside && /^    steps:[[:space:]]*$/ { exit }
        inside && /^[[:space:]]+- service:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+- service:[[:space:]]*/, "", line)
            service=line
            next
        }
        inside && service != "" {
            prefix="^[[:space:]]+" field ":[[:space:]]*"
            if ($0 ~ prefix) {
                line=$0
                sub(prefix, "", line)
                sub(/^&[^[:space:]]+[[:space:]]+/, "", line)
                if (line ~ /^".*"$/) {
                    sub(/^"/, "", line)
                    sub(/"$/, "", line)
                }
                print service "\t" line
            }
        }
    ' "$workflow" | sort
}

# Extract service-keyed values from one associative array in Hosted Fallback.
extract_fallback_metadata() {
    local file="$1" array_name="$2"
    awk -v array_name="$array_name" '
        $0 ~ "^[[:space:]]*declare -A " array_name "=\\($" { inside=1; next }
        inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
        inside && /^[[:space:]]*\[[a-z0-9-]+\]=/ {
            line=$0
            sub(/^[[:space:]]*\[/, "", line)
            split_at=index(line, "]=")
            service=substr(line, 1, split_at - 1)
            value=substr(line, split_at + 2)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            print service "\t" value
        }
    ' "$file" | sort
}

check_hosted_fallback_metadata() {
    local file="$1" field array_name expected found
    local -a pairs=(
        "context:contexts"
        "build_contexts:build_contexts"
        "description:descriptions"
    )

    for pair in "${pairs[@]}"; do
        field=${pair%%:*}
        array_name=${pair#*:}
        expected="$(extract_matrix_metadata "$field")"
        found="$(extract_fallback_metadata "$file" "$array_name")"
        if [[ -z "$expected" ]]; then
            fail "could not extract '$field' metadata from the anchored build matrix in $workflow."
            continue
        fi
        if [[ "$found" != "$expected" ]]; then
            fail "$array_name metadata in $file diverges from build-push.yml's normal-build matrix."
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
    # scripts/syslog-forwarding-simulation.sh's Triggers 7/8 (added by #864,
    # after this exclusion set was first written) pull both images directly.
    # ntp (the last remaining member) moved out too once
    # scripts/syslog-forwarding-simulation.sh gained a real ntp
    # start+healthcheck consumer (see ensure-pr-staging-images.sh's own
    # full_setup_services=(...) comment) -- completing #1296's original 3-of-3
    # ask. The key is kept PRESENT with an empty value (rather than deleted
    # outright) so this file stays routed through the exact-equality branch
    # below instead of falling back to the looser membership-only check that
    # applies to a file with no entry here at all -- see that branch's own
    # comment for why a key-EXISTENCE test, not a non-empty-VALUE test, is
    # what makes an empty exclusion set actually behave as "equals canonical
    # exactly" rather than silently degrading to the weaker check.
    ["ensure-pr-staging-images.sh"]=""
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

# Per-extra-file expectation of which array kind each file must declare at
# least one of (basename-keyed, same reasoning as SUBSET_SERVICES_FILES
# above). This is what lets check_services_arrays/check_full_setup_arrays
# fail closed per file instead of either over-requiring (e.g. demanding
# ensure-pr-staging-images.sh have a services=(...) array it never had) or
# under-requiring (silently accepting the array vanishing from a file that
# should always have it).
declare -A REQUIRES_SERVICES_ARRAY=(
    ["build-push-hosted-fallback.yml"]=1
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

    if [[ "$file_basename" == "build-push-hosted-fallback.yml" ]]; then
        check_hosted_fallback_metadata "$file"
    fi
done

if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d service-list/metadata divergence(s) found.%b Keep runtime service metadata in sync with the build matrix.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All checked service lists and metadata are consistent with the build matrix (%s).%b\n" "$GREEN" "$canonical_oneline" "$NC"
exit 0
