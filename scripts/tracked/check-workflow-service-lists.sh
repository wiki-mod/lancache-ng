#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)


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


array_elements() {
    sed -E 's/^[^(]*\(//; s/\).*$//' <<<"$1" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

canonical_minus() {
    comm -23 <(printf '%s\n' "$canonical") <(printf '%s\n' "$1" | sort -u)
}


declare -A SUBSET_SERVICES_FILES=(

    ["backfill-stack-latest.yml"]="build-tools"
)


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


    mapfile -t entries < <(grep -nE '^[[:space:]]*services=\(' "$file" || true)
    if [[ ${#entries[@]} -eq 0 ]]; then
        if [[ "$requirement" == "required" ]]; then

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



declare -A FULL_SETUP_EXACT_EXCLUSIONS=(

    ["ensure-pr-staging-images.sh"]=$'cachehamster'
)


check_full_setup_arrays() {
    local file="$1" requirement="$2" file_basename lineno content entry elements
    local -a entries
    local expected expected_oneline
    file_basename=$(basename "$file")

    mapfile -t entries < <(grep -nE '^[[:space:]]*full_setup_services=\(' "$file" || true)
    if [[ ${#entries[@]} -eq 0 && "$requirement" == "required" ]]; then
        fail "no 'full_setup_services=(...)' array found in $file -- was it renamed or refactored? Update this guard deliberately."
        return
    fi

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


# should always have it).
declare -A REQUIRES_SERVICES_ARRAY=(
    ["gc-pr-staging-images.sh"]=1
    ["backfill-stack-latest.yml"]=1
)
declare -A REQUIRES_FULL_SETUP_ARRAY=(
    ["ensure-pr-staging-images.sh"]=1
)


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
