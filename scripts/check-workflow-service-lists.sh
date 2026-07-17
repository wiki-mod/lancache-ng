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
set -euo pipefail

# Optional first argument: path to the workflow file to check. Defaults to
# this repo's build-push.yml (resolved relative to the script), so CI can call
# it with no arguments while the bats suite can point it at a fixture file.
if [[ -n "${1:-}" ]]; then
    workflow="$1"
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/.." && pwd)
    cd "$repo_root"
    workflow=".github/workflows/build-push.yml"
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

# The four full `services=(...)` copies must each equal the canonical set.
mapfile -t services_lines < <(grep -nE '^[[:space:]]+services=\(' "$workflow" || true)
if [[ ${#services_lines[@]} -eq 0 ]]; then
    # Fail closed rather than silently pass: if these arrays were renamed or
    # refactored away, this guard no longer protects anything and must be
    # revisited deliberately, not left green by accident.
    fail "no 'services=(...)' arrays found in $workflow -- were they renamed or refactored? Update this guard deliberately."
fi
for entry in "${services_lines[@]}"; do
    lineno=${entry%%:*}
    content=${entry#*:}
    elements=$(array_elements "$content")
    if [[ "$elements" != "$canonical" ]]; then
        fail "services=(...) at line $lineno diverges from the build-matrix canonical set."
        printf "    expected: %s\n" "$canonical_oneline" >&2
        printf "    found:    %s\n" "$(printf '%s' "$elements" | tr '\n' ' ')" >&2
    fi
done

# full_setup_services=(...) must be a subset of the canonical set (it
# deliberately omits some services). Flag only elements NOT in canonical.
mapfile -t full_setup_lines < <(grep -nE '^[[:space:]]+full_setup_services=\(' "$workflow" || true)
for entry in "${full_setup_lines[@]}"; do
    lineno=${entry%%:*}
    content=${entry#*:}
    while IFS= read -r elem; do
        [[ -z "$elem" ]] && continue
        if ! grep -qxF "$elem" <<<"$canonical"; then
            fail "full_setup_services=(...) at line $lineno contains '$elem', which is not a known build-matrix service."
        fi
    done < <(array_elements "$content")
done

if [[ $violations -gt 0 ]]; then
    printf "%b✗ %d service-list divergence(s) found.%b Keep every services=(...) copy in build-push.yml in sync with the build matrix; see issue #822.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All build-push.yml service lists are consistent with the build matrix (%s).%b\n" "$GREEN" "$canonical_oneline" "$NC"
exit 0
