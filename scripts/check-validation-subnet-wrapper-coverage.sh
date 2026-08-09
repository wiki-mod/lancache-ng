#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Validates that jobs consuming a derived validation subnet cannot start a
# Docker Compose stack without the host-local flock/retry reservation layer.
# The guard also recognizes the newer reusable-suite shape where one shared
# job owns the reservation for the complete full-setup stack lifetime and no
# job consumes the old raw compute-validation-network outputs anymore.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

WORKFLOW_FILES=(
    ".github/workflows/full-setup-validate.yml"
    ".github/workflows/full-setup-deep-validate.yml"
    ".github/workflows/full-setup-sims.yml"
)

RAW_OUTPUT_MARKERS=(
    'needs.compute-validation-network.outputs.'
    "needs['compute-validation-network'].outputs."
    'needs["compute-validation-network"].outputs.'
)
WRAPPER_INVOCATION_MARKER='bash scripts/lib/run-in-validation-subnet.sh'
INLINE_RESERVATION_MARKER='validation_subnet_reserve_slot "'
COMPOSITE_RESERVATION_MARKER='uses: ./.github/actions/reserve-validation-subnet-stack'
SHARED_STACK_WORKFLOW='.github/workflows/full-setup-sims.yml'
SHARED_STACK_JOB='shared-full-setup-stack'

failures=0
jobs_examined_with_raw_output=0
shared_stack_job_seen=0
shared_stack_reservation_seen=0

fail() {
    printf '::error::%s\n' "$1" >&2
    failures=$((failures + 1))
}

strip_leading_whitespace() {
    local line="$1" leading_ws
    leading_ws="${line%%[^[:space:]]*}"
    printf '%s' "${line#"$leading_ws"}"
}

indent_width() {
    local line="$1" stripped
    stripped=$(strip_leading_whitespace "$line")
    echo $(( ${#line} - ${#stripped} ))
}

is_job_name_line() {
    local line="$1"
    case "$line" in
        '  '[A-Za-z0-9_-]*':')
            case "$line" in
                '  '*' '*) return 1 ;;
            esac
            [[ "$(indent_width "$line")" -eq 2 ]]
            return $?
            ;;
        *) return 1 ;;
    esac
}

body_has_raw_output_reference() {
    local body="$1" marker
    for marker in "${RAW_OUTPUT_MARKERS[@]}"; do
        if [[ "$body" == *"$marker"* ]]; then
            return 0
        fi
    done
    return 1
}

check_job_body() {
    local file="$1" job_name="$2" body="$3"

    if [[ -z "$job_name" ]]; then
        return 0
    fi

    # The consolidated reusable suite no longer needs a caller-computed raw
    # subnet. Instead, one job starts the stack through the reservation action
    # and holds the resulting lock until its final teardown step. Recognize
    # that as a first-class safe architecture, and fail if the named owner job
    # ever loses the reservation action.
    if [[ "$file" == "$SHARED_STACK_WORKFLOW" && "$job_name" == "$SHARED_STACK_JOB" ]]; then
        shared_stack_job_seen=1
        if [[ "$body" == *"$COMPOSITE_RESERVATION_MARKER"* ]]; then
            shared_stack_reservation_seen=1
        else
            fail "check-validation-subnet-wrapper-coverage: $file job '$job_name' is the shared validation-stack owner but does not contain the '$COMPOSITE_RESERVATION_MARKER' reservation step."
        fi
    fi

    if ! body_has_raw_output_reference "$body"; then
        return 0
    fi

    jobs_examined_with_raw_output=$((jobs_examined_with_raw_output + 1))
    if [[ "$body" == *"$WRAPPER_INVOCATION_MARKER"* ]]; then
        return 0
    fi
    if [[ "$body" == *"$INLINE_RESERVATION_MARKER"* ]]; then
        return 0
    fi
    if [[ "$body" == *"$COMPOSITE_RESERVATION_MARKER"* ]]; then
        return 0
    fi

    fail "check-validation-subnet-wrapper-coverage: $file job '$job_name' references compute-validation-network's raw outputs directly but has none of: a '$WRAPPER_INVOCATION_MARKER' invocation, an inline '$INLINE_RESERVATION_MARKER' reservation call, or a '$COMPOSITE_RESERVATION_MARKER' composite-action step."
}

check_workflow_file() {
    local file="$1"
    local in_jobs=0 current_job="" body="" line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_jobs" -eq 0 ]]; then
            if [[ "$line" == "jobs:" ]]; then
                in_jobs=1
            fi
            continue
        fi

        if [[ "$line" != '  '* && "$line" != '' && "$(indent_width "$line")" -eq 0 ]]; then
            in_jobs=0
            check_job_body "$file" "$current_job" "$body"
            current_job=""
            body=""
            continue
        fi

        if is_job_name_line "$line"; then
            check_job_body "$file" "$current_job" "$body"
            current_job="${line#'  '}"
            current_job="${current_job%:}"
            body=""
            continue
        fi

        if [[ -n "$current_job" ]]; then
            body+="$line"$'\n'
        fi
    done < "$file"

    check_job_body "$file" "$current_job" "$body"
}

for file in "${WORKFLOW_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        fail "check-validation-subnet-wrapper-coverage: '$file' no longer exists; update WORKFLOW_FILES in scripts/check-validation-subnet-wrapper-coverage.sh."
        continue
    fi
    check_workflow_file "$file"
done

# A zero raw-consumer count is now valid only when the reusable workflow has
# genuinely migrated to the single reservation-owning shared-stack job. If
# neither architecture is detected, the parser or workflow shape changed in a
# way this guard no longer understands, which must fail closed.
if [[ "$jobs_examined_with_raw_output" -eq 0 && "$shared_stack_reservation_seen" -ne 1 ]]; then
    fail "check-validation-subnet-wrapper-coverage: found zero jobs referencing compute-validation-network's raw outputs and no protected shared validation-stack owner; this guard's parsing likely broke or the workflow architecture changed without updating the guard."
fi
if [[ "$shared_stack_job_seen" -eq 1 && "$shared_stack_reservation_seen" -ne 1 ]]; then
    fail "check-validation-subnet-wrapper-coverage: shared validation-stack owner was found without its required reservation protection."
fi

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-validation-subnet-wrapper-coverage: %d violation(s) found (see scripts/check-validation-subnet-wrapper-coverage.sh).\n' "$failures" >&2
    exit 1
fi

if [[ "$jobs_examined_with_raw_output" -eq 0 ]]; then
    printf 'check-validation-subnet-wrapper-coverage: OK (shared validation-stack owner holds the composite reservation; no raw compute-validation-network consumers remain).\n'
else
    printf 'check-validation-subnet-wrapper-coverage: OK (%d job(s) referencing compute-validation-network raw output, all protected by the wrapper, inline reservation, or composite reservation).\n' "$jobs_examined_with_raw_output"
fi
