#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard for the shared-scripts build-context regression: 9
# `docker build`/`docker buildx build` invocations across 7
# scripts/untracked/simulations/*.sh files built services/{proxy,dhcp,
# dhcp-proxy,dns}/Dockerfile directly, independent of
# .github/workflows/build-push.yml's own `build_contexts:` matrix wiring,
# without the `--build-context shared-scripts=scripts/lib` flag those
# Dockerfiles' `COPY --from=shared-scripts verify-version-banner.sh` (Issue
# #1781 | PR #1783) requires. A missing named build context does not fail
# at review time, `bash -n`, or shellcheck time: buildx instead treats the
# bare name as a registry image reference and fails at BUILD time deep
# inside a CI job with "pull access denied ... repository does not exist",
# no earlier static signal. This guard is the standing rule that catches a
# *new* invocation, or a Dockerfile gaining a new named context, missing
# the same wiring, mirroring check-registry-login-coverage.sh's own
# "compose call must carry required companion flag" shape for a different
# class of build-time wiring drift.
#
# --- What counts as "a required named build context" ----------------------
# For a services/*/Dockerfile: every `COPY --from=<name>` value that is
# NEITHER a numeric build-stage index NOR a name already declared by an
# earlier `FROM ... AS <name>` line in the same file, NOR a real external
# image reference (containing "/" or ":", e.g. `--from=docker/dockerfile:1`)
# is a required named build context that must be supplied via
# `--build-context <name>=<path>` on any `docker build`/`docker buildx
# build` invocation targeting that Dockerfile.
#
# --- Which docker build invocations are checked ----------------------------
# Every `docker build`/`docker buildx build` invocation in
# scripts/untracked/simulations/*.sh, joined across `\`-continued lines
# first so a multi-line invocation is seen whole. Its target Dockerfile is
# the `-f`/`--file` argument if given, else the last bare `services/<svc>`
# token (this repo's simulation scripts never build any other bare context
# path without `-f`) with `/Dockerfile` appended. An invocation that cannot
# be resolved to a services/*/Dockerfile is skipped.
#
# Usage:
#   scripts/tracked/check-simulation-build-context-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/../.." && pwd)}"
cd "$repo_root"

SIMULATIONS_DIR="scripts/untracked/simulations"

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

# required_contexts_for_dockerfile <dockerfile>
# Prints one required named-build-context name per line (see header
# comment's "required named build context" definition).
required_contexts_for_dockerfile() {
    local dockerfile="$1"
    awk '
        BEGIN { IGNORECASE = 1 }
        /^FROM[ \t]/ {
            for (i = 1; i <= NF; i++) {
                if (toupper($i) == "AS" && (i + 1) <= NF) { stages[$(i + 1)] = 1 }
            }
        }
        /--from=/ {
            line = $0
            n = split(line, parts, "--from=")
            for (i = 2; i <= n; i++) {
                rest = parts[i]
                sub(/[ \t].*/, "", rest)
                name = rest
                if (name ~ /^[0-9]+$/) continue
                if (name in stages) continue
                if (name ~ /\//) continue
                if (name ~ /:/) continue
                if (name == "") continue
                print name
            }
        }
    ' "$dockerfile" | sort -u
}

# join_continued_lines <file>
# Prints <file> with every `\`-continued line joined onto one logical line,
# so a multi-line docker build invocation is scanned whole.
join_continued_lines() {
    local file="$1" line logical=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *\\ ]]; then
            logical+="${line%\\} "
            continue
        fi
        printf '%s\n' "${logical}${line}"
        logical=""
    done < "$file"
}

# target_dockerfile_for_invocation <invocation-line>
# Prints the services/*/Dockerfile path this invocation targets, or nothing
# if none can be resolved (see header comment).
target_dockerfile_for_invocation() {
    local invocation="$1" explicit="" ctx=""
    # What: `|| true` on each grep|tail; a no-match is not an error.
    # Why: pipefail would otherwise abort the caller under set -e.
    # From: Issue #1095
    explicit=$(grep -oE '(^|[[:space:]])(-f|--file)[[:space:]]+"?services/[A-Za-z0-9_-]+/Dockerfile"?' <<<"$invocation" | tail -1) || true
    if [[ -n "$explicit" ]]; then
        explicit="${explicit#*services/}"
        explicit="${explicit%\"}"
        printf 'services/%s\n' "$explicit"
        return 0
    fi
    if [[ "$invocation" == *"-f "* || "$invocation" == *"--file "* ]]; then
        # An explicit -f/--file pointing outside services/*/Dockerfile
        # (e.g. a synthetic fixture) is out of this guard's scope.
        return 0
    fi
    ctx=$(grep -oE 'services/[A-Za-z0-9_-]+' <<<"$invocation" | tail -1) || true
    if [[ -n "$ctx" ]]; then
        printf '%s/Dockerfile\n' "$ctx"
    fi
    return 0
}

# supplied_build_contexts <invocation-line>
# Prints one --build-context name (the part before its "=") per line.
supplied_build_contexts() {
    local invocation="$1"
    grep -oE -- '--build-context[[:space:]]+"?[A-Za-z0-9_.-]+=' <<<"$invocation" \
        | sed -E 's/--build-context[[:space:]]+"?//; s/=$//' || true
}

check_invocation() {
    local file="$1" invocation="$2" dockerfile required supplied name missing=()

    dockerfile=$(target_dockerfile_for_invocation "$invocation")
    [[ -z "$dockerfile" || ! -f "$dockerfile" ]] && return 0
    invocations_examined=$((invocations_examined + 1))

    mapfile -t required < <(required_contexts_for_dockerfile "$dockerfile")
    [[ ${#required[@]} -eq 0 ]] && return 0

    mapfile -t supplied < <(supplied_build_contexts "$invocation")
    for name in "${required[@]}"; do
        local found=0 s
        for s in "${supplied[@]}"; do
            [[ "$s" == "$name" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && missing+=("$name")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "check-simulation-build-context-coverage: $file builds $dockerfile without --build-context for: ${missing[*]} -- this is the exact shared-scripts regression class: buildx resolves the bare name as a registry image and fails at build time with 'pull access denied'. Add --build-context <name>=<path> for each. Invocation: $invocation"
    fi
}

shopt -s nullglob
for file in "$SIMULATIONS_DIR"/*.sh; do
    while IFS= read -r logical_line; do
        case "$logical_line" in
            *'docker build '*|*'docker buildx build '*)
                # Skip a comment line naming docker build in prose.
                stripped="${logical_line#"${logical_line%%[! ]*}"}"
                [[ "$stripped" == \#* ]] && continue
                check_invocation "$file" "$logical_line"
                ;;
        esac
    done < <(join_continued_lines "$file")
done
shopt -u nullglob

if [[ "$invocations_examined" -eq 0 ]]; then
    fail "check-simulation-build-context-coverage: examined zero docker build invocations targeting services/*/Dockerfile under $SIMULATIONS_DIR -- expected several (this guard's own parsing likely broke, or every simulation script stopped building images directly; update this script rather than silently passing)."
fi

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-simulation-build-context-coverage: %d violation(s) found (see scripts/tracked/check-simulation-build-context-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-simulation-build-context-coverage: OK (%d docker build invocation(s) examined, every required named build context is supplied).\n' "$invocations_examined"
