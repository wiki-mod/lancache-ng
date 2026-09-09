#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard: PR #1856 (Refs #1095) found 7 `docker build` invocations in
# scripts/untracked/simulations/*.sh that never passed the required
# `--build-context shared-scripts=<path>`, even though their target
# Dockerfile uses `COPY --from=shared-scripts`. Docker then resolves
# `shared-scripts` as a (non-existent) `docker.io/library/shared-scripts`
# image and fails with "pull access denied" -- a real, reproduced CI failure
# class (job 102440430735: `full-setup simulations / DHCP Kea lease-flow
# simulation`), not a hypothetical one. This mirrors
# check-registry-login-coverage.sh's own "a job/script move can silently
# drop a required flag again" shape for the sibling #1095 regression class.
#
# --- What requires the shared-scripts context ------------------------------
# Mechanically derived, not hardcoded: any `services/*/Dockerfile` or
# `tools/*/Dockerfile` containing a real (non-comment) `COPY --from=shared-
# scripts` line. This adapts automatically if a service starts or stops
# needing scripts/lib's shared entrypoint helpers.
#
# --- What counts as "a script builds one of those images" ------------------
# Any real (non-comment) `docker build` invocation anywhere in a tracked
# `*.sh` file (deliberately NOT `*.bats`: those contain fixture strings that
# quote fake YAML/shell snippets to test OTHER guards' own parsing --
# tests/bats/check_registry_login_coverage.bats:132 is exactly such a
# fixture, not a real invocation, and scanning `*.bats` produced that false
# positive during this guard's own development) whose logical command line
# (continued across `\` line-continuations) either:
#   - passes `-f <dir>/Dockerfile` for a flagged <dir>, or
#   - names a flagged <dir> as a bare context argument (e.g. `services/dhcp`
#     at the end of the command),
# and does not also contain `--build-context` with a `shared-scripts=` value
# in that same logical command.
#
# --- Known limitation --------------------------------------------------------
# This is a text scan, not a shell parser: it cannot see a context built
# entirely from runtime-computed values with no literal directory name
# anywhere in the command (none currently exist -- verified by this script's
# own zero-invocations-examined self-check below).
#
# Usage:
#   scripts/tracked/check-shared-scripts-build-context-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/../.." && pwd)}"
cd "$repo_root"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    NC='\033[0m'
else
    RED=''
    NC=''
fi

failures=0
invocations_examined=0

fail() {
    printf '%b::error:: %s%b\n' "$RED" "$1" "$NC" >&2
    failures=$((failures + 1))
}

# --- Derive the set of directories whose Dockerfile needs shared-scripts ---
flagged_dirs=()
while IFS= read -r dockerfile; do
    if grep -Eq '^[[:space:]]*COPY[[:space:]]+--from=shared-scripts' "$dockerfile"; then
        flagged_dirs+=("$(dirname "$dockerfile")")
    fi
done < <(find services tools -maxdepth 2 -name Dockerfile 2>/dev/null | sort)

if [[ ${#flagged_dirs[@]} -eq 0 ]]; then
    fail "check-shared-scripts-build-context-coverage: found zero Dockerfiles using 'COPY --from=shared-scripts' under services/*/Dockerfile or tools/*/Dockerfile -- expected at least dhcp/dhcp-proxy/dns/proxy/ui/watchdog (this guard's own parsing likely broke, or the shared-scripts pattern has genuinely been retired, in which case this whole guard can be removed)."
fi

# logical_command_references_dir <blob> <dir>
# True if <blob> either passes `-f <dir>/Dockerfile` or names <dir> as a
# bare (unquoted or single/double-quoted) whitespace-delimited token.
logical_command_references_dir() {
    local blob="$1" dir="$2"
    case "$blob" in
        *"-f $dir/Dockerfile"*|*"-f \"$dir/Dockerfile\""*) return 0 ;;
    esac
    case " $blob " in
        *" $dir "*|*" \"$dir\" "*|*" '$dir' "*) return 0 ;;
    esac
    return 1
}

# logical_command_has_shared_scripts_context <blob>
logical_command_has_shared_scripts_context() {
    local blob="$1"
    case "$blob" in
        *'--build-context'*'shared-scripts='*) return 0 ;;
    esac
    return 1
}

check_file() {
    local file="$1" line stripped blob=""
    local in_command=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_command" -eq 1 ]]; then
            blob+=" $line"
            if [[ "$line" != *'\' ]]; then
                in_command=0
                invocations_examined=$((invocations_examined + 1))
                for dir in "${flagged_dirs[@]}"; do
                    if logical_command_references_dir "$blob" "$dir" \
                        && ! logical_command_has_shared_scripts_context "$blob"; then
                        fail "check-shared-scripts-build-context-coverage: $file builds '$dir' (Dockerfile uses COPY --from=shared-scripts) without passing --build-context shared-scripts=<path>. Command: ${blob# }"
                    fi
                done
                blob=""
            fi
            continue
        fi
        stripped="${line#"${line%%[! ]*}"}"
        [[ "$stripped" == \#* ]] && continue
        if [[ "$stripped" == *'docker build'* || "$stripped" == *'docker_buildx_retry'*'docker build'* ]]; then
            blob="$line"
            if [[ "$line" == *'\' ]]; then
                in_command=1
            else
                invocations_examined=$((invocations_examined + 1))
                for dir in "${flagged_dirs[@]}"; do
                    if logical_command_references_dir "$blob" "$dir" \
                        && ! logical_command_has_shared_scripts_context "$blob"; then
                        fail "check-shared-scripts-build-context-coverage: $file builds '$dir' (Dockerfile uses COPY --from=shared-scripts) without passing --build-context shared-scripts=<path>. Command: ${blob# }"
                    fi
                done
                blob=""
            fi
        fi
    done < "$file"
}

while IFS= read -r -d '' file; do
    check_file "$file"
done < <(find . -name '*.sh' -not -path './.git/*' -not -path '*/target/*' -print0 | sort -z)

if [[ "$invocations_examined" -eq 0 ]]; then
    fail "check-shared-scripts-build-context-coverage: examined zero 'docker build' invocations repo-wide -- expected several (this guard's own parsing likely broke, e.g. a renamed pattern), or every relevant build has moved to a form (e.g. pure docker-compose build:) this text scan cannot see, in which case this guard needs a redesign rather than silently passing."
fi

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-shared-scripts-build-context-coverage: %d violation(s) found (see scripts/tracked/check-shared-scripts-build-context-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-shared-scripts-build-context-coverage: OK (%d docker build invocation(s) examined, %d flagged Dockerfile(s): %s).\n' \
    "$invocations_examined" "${#flagged_dirs[@]}" "${flagged_dirs[*]}"
