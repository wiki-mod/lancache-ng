#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Standing guard for issue #896: #820 ported the flock+retry collision-safe
# reservation (issue #703) into every full-setup-validate.yml/full-setup-
# deep-validate.yml job that starts its own compose stack against
# `compute-validation-network`'s per-run derived subnet -- but it only ported
# the jobs that existed at the time. #896 found (and #907 fixed) two jobs
# added later that never got wired through the wrapper and, as a real,
# reproduced failure, collided with a concurrent run's identical subnet
# ("Pool overlaps with other one on this address space"). #907 fixed the two
# known instances; this script is the standing rule that stops a THIRD job
# from silently repeating the same gap, since #820's fix only covered a fixed
# job list, not a rule enforced going forward.
#
# WHAT COUNTS AS "CONSUMES THE RAW OUTPUT": a job references
# `needs.compute-validation-network.outputs.<subnet|gateway|*_ip|
# project_name|ui_port>` directly (in practice, always a job-level `env:`
# entry in this repo, confirmed by reading every job in both files) -- this
# is the exact per-run-but-otherwise-unlocked candidate #820/#896 diagnosed:
# safe from OTHER runs on OTHER hosts, but not from a second, genuinely
# concurrent run on the SAME self-hosted host deriving the identical slot.
#
# WHAT COUNTS AS "PROTECTED": the same job's body must ALSO contain one of
# two things this repo's existing jobs actually use:
#   1. An actual invocation of the wrapper, `bash scripts/lib/
#      run-in-validation-subnet.sh` -- not just a comment mentioning the
#      filename. Several jobs' own header comments mention
#      "run-in-validation-subnet.sh" in prose (explaining why OTHER jobs are
#      wrapped) without invoking it themselves; matching on the bare
#      filename would treat that prose as protection and never fire. The
#      full literal command form (as every real wrapped job in this repo
#      spells it) is required instead.
#   2. Inline reservation equivalent: an actual call to
#      `validation_subnet_reserve_slot "` (opening quote for its first
#      arg -- distinguishes a real call from a comment merely naming the
#      function). This is what full-setup-validate's own job in both files
#      uses: it holds the lock across several SEPARATE steps (up, health
#      check, client simulation, teardown), so it can't use the
#      single-invocation wrapper and instead sources reserve-validation-
#      subnet.sh directly and re-derives its own reservation loop.
#
# A job that references the raw output but has NEITHER protection is exactly
# the #896/#907 bug class: it will build its compose stack directly from the
# unlocked, un-retried candidate subnet, so two concurrent runs deriving the
# same slot on the same host WILL collide.
#
# Deliberately implemented in plain bash (read/case/parameter-expansion), not
# awk or a YAML library: check-idempotence-test-coverage.sh's own header
# documents that both a PCRE grep and a POSIX-awk rewrite silently
# misbehaved on this project's actual self-hosted runners, while plain bash
# string/glob matching (already required by this script's own bash shebang)
# does not depend on any such external engine.
#
# Usage:
#   scripts/check-validation-subnet-wrapper-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

WORKFLOW_FILES=(
    ".github/workflows/full-setup-validate.yml"
    ".github/workflows/full-setup-deep-validate.yml"
)

RAW_OUTPUT_MARKER='needs.compute-validation-network.outputs.'
WRAPPER_INVOCATION_MARKER='bash scripts/lib/run-in-validation-subnet.sh'
INLINE_RESERVATION_MARKER='validation_subnet_reserve_slot "'

failures=0
jobs_examined_with_raw_output=0

fail() {
    printf '::error::%s\n' "$1" >&2
    failures=$((failures + 1))
}

# strip_leading_whitespace <line>
# Same parameter-expansion idiom check-idempotence-test-coverage.sh already
# uses, kept identical here rather than reinvented, so both guards share one
# well-reviewed way of measuring a line's own indentation without sed/grep.
strip_leading_whitespace() {
    local line="$1" leading_ws
    leading_ws="${line%%[^[:space:]]*}"
    printf '%s' "${line#"$leading_ws"}"
}

# indent_width <line>
# Prints the number of leading space characters on <line>. Used to find
# top-level job-name keys, which in both workflow files are always indented
# by exactly two spaces directly under the top-level `jobs:` key (one level
# deeper than `jobs:` itself, one level shallower than any of a job's own
# `name:`/`needs:`/`env:`/`steps:` keys).
indent_width() {
    local line="$1" stripped
    stripped=$(strip_leading_whitespace "$line")
    echo $(( ${#line} - ${#stripped} ))
}

# is_job_name_line <line>
# True if <line> is a bare "  some-job-name:" line: exactly two leading
# spaces, a YAML-key-shaped identifier, then a colon and nothing else. This
# deliberately excludes any line with trailing content after the colon (a
# real job name is never followed by an inline value) and any line indented
# by any other amount, so a job's own 4-space-indented `env:`/`steps:` keys,
# and `on:`'s 2-space-indented `pull_request:`/`workflow_dispatch:` keys
# (guarded separately by only scanning after the `jobs:` line -- see below),
# can never be mistaken for a job name.
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

# check_workflow_file <file>
# Splits <file> into per-job bodies (everything strictly under the top-level
# `jobs:` key) and checks each one that references the raw
# compute-validation-network output for one of the two protection markers.
check_workflow_file() {
    local file="$1"
    local in_jobs=0 current_job="" body="" line

    # flush_current_job: run the actual check for whatever job body has been
    # accumulated so far, then reset for the next one. Called both when a new
    # job-name line is seen and once more after the read loop for the last
    # job in the file.
    flush_current_job() {
        if [[ -z "$current_job" ]]; then
            return 0
        fi
        if [[ "$body" != *"$RAW_OUTPUT_MARKER"* ]]; then
            return 0
        fi
        jobs_examined_with_raw_output=$((jobs_examined_with_raw_output + 1))
        if [[ "$body" == *"$WRAPPER_INVOCATION_MARKER"* ]]; then
            return 0
        fi
        if [[ "$body" == *"$INLINE_RESERVATION_MARKER"* ]]; then
            return 0
        fi
        fail "check-validation-subnet-wrapper-coverage: $file job '$current_job' references $RAW_OUTPUT_MARKER* directly but has neither a '$WRAPPER_INVOCATION_MARKER' invocation nor an inline '$INLINE_RESERVATION_MARKER' reservation call -- this is the exact #820/#896/#907 collision class: two concurrent runs deriving the same subnet will race 'docker compose up' with no lock and no retry. Wrap this job's stack-starting invocation in scripts/lib/run-in-validation-subnet.sh (see e.g. ssl-mitm-cache-simulation in either workflow file), or add an equivalent inline reservation loop if the job must hold the lock across multiple separate steps (see full-setup-validate's own job in either file)."
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_jobs" -eq 0 ]]; then
            if [[ "$line" == "jobs:" ]]; then
                in_jobs=1
            fi
            continue
        fi

        # A new zero-indent top-level key after jobs: (none exists in either
        # file today, but a future workflow key added after `jobs:` must not
        # silently get swallowed into the last job's body) ends the jobs
        # section.
        if [[ "$line" != '  '* && "$line" != '' && "$(indent_width "$line")" -eq 0 ]]; then
            in_jobs=0
            flush_current_job
            current_job=""
            body=""
            continue
        fi

        if is_job_name_line "$line"; then
            flush_current_job
            current_job="${line#'  '}"
            current_job="${current_job%:}"
            body=""
            continue
        fi

        if [[ -n "$current_job" ]]; then
            body+="$line"$'\n'
        fi
    done < "$file"

    flush_current_job
}

for file in "${WORKFLOW_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        fail "check-validation-subnet-wrapper-coverage: '$file' no longer exists; update WORKFLOW_FILES in scripts/check-validation-subnet-wrapper-coverage.sh."
        continue
    fi
    check_workflow_file "$file"
done

# A parsing bug that silently walks past every job (e.g. a future rename of
# `jobs:` itself, or of compute-validation-network) must not be
# indistinguishable from "no violations found" -- both workflow files have
# had several protected jobs since #820/#907, so finding zero is itself a
# guard failure, matching check-idempotence-test-coverage.sh's own
# "verified to actually exist ... instead of the check silently checking
# nothing" principle.
if [[ "$jobs_examined_with_raw_output" -eq 0 ]]; then
    fail "check-validation-subnet-wrapper-coverage: found zero jobs referencing $RAW_OUTPUT_MARKER* across ${WORKFLOW_FILES[*]} -- expected several (this guard's own parsing likely broke, or both workflow files changed shape; update this script rather than silently passing)."
fi

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-validation-subnet-wrapper-coverage: %d violation(s) found (see scripts/check-validation-subnet-wrapper-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-validation-subnet-wrapper-coverage: OK (%d job(s) referencing compute-validation-network raw output, all protected by the wrapper or an inline reservation).\n' "$jobs_examined_with_raw_output"
