#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Standing guard: when the ten shared full-setup jobs were extracted from
# full-setup-validate.yml/full-setup-deep-validate.yml into the reusable
# full-setup-sims.yml (issue #1014), the GHCR-then-Docker-Hub login step
# PR #1757/#1760 had added to full-setup-deep-validate.yml's
# ensure-pr-staging-images job was never carried into any of the extracted
# jobs -- full-setup-sims.yml pulled deploy/full-setup's and
# deploy/quickstart's third-party docker.io images (nats:2-alpine,
# tecnativa/docker-socket-proxy, netdata/netdata) fully anonymously from the
# day it was created until a later fix restored it. That fix also found
# three MORE jobs outside full-setup-sims.yml with the exact same gap
# (dns-zone-rollback-simulation, dhcp-kea-ui-rollback-simulation in
# full-setup-deep-validate.yml; dhcp-kea-ctrl-agent-mutation-simulation in
# full-setup-validate.yml) -- confirming this is a real, recurring class of
# regression (a job move/extraction silently dropping the login), not a
# one-off. This script is the standing rule that stops a future job move or
# new job from silently reintroducing an anonymous pull, mirroring
# check-validation-subnet-wrapper-coverage.sh's own "trigger marker requires
# a protection marker" shape for the sibling #896/#907 collision class.
#
# --- What counts as "pulls a docker.io image" -----------------------------
# The set of docker.io-backed (third-party, rate-limited) services is derived
# mechanically from each compose file's own `image:` values, not
# hardcoded: a service is docker.io-backed unless its image starts with
# `ghcr.io/`, `mirror.gcr.io/`, or `${LANCACHE_IMAGE_REGISTRY` (this repo's
# own images, always ghcr.io by default). This adapts automatically if a
# currently-docker.io-backed service (nats, docker-socket-proxy, netdata as
# of this writing) is ever migrated to a mirror registry, or a new
# docker.io-backed service is added to either compose file.
#
# --- What counts as "a job pulls one of those services" -------------------
# A job's own YAML body, or a scripts/untracked/simulations/*.sh file it
# names, contains a real (non-comment) `docker compose ... up -d <args>`,
# `... pull --quiet <args>`, or `... run -d --name ... <args>` invocation
# whose argument list includes one of the docker.io-backed service names --
# not just any compose command (e.g. `docker compose config` never pulls
# anything and must not trigger this). A job using the
# reserve-validation-subnet-stack composite action (full-setup-validate) is
# also a trigger unconditionally: that action's own `docker compose ... up
# -d` has no service filter, so it always pulls the whole stack regardless
# of which services this script's static scan would otherwise name.
#
# --- The two jobs this mechanical signal cannot see ------------------------
# setup-cli-simulation.sh and syslog-forwarding-simulation.sh both install a
# REAL stack by driving the actual `setup.sh` CLI end-to-end (fresh install)
# rather than invoking `docker compose` themselves -- which services setup.sh
# chooses to start is its own runtime logic, not a static, grep-able command
# line in either script. Manually verified (see the PR/commit this file was
# introduced under) that both jobs' fresh installs do pull the docker.io-
# backed services. Listed here as an
# explicit, named exception rather than pretended to be covered by the
# generic mechanical signal above (see NAMED_OPAQUE_SCRIPT_TRIGGERS below).
#
# Usage:
#   scripts/tracked/check-registry-login-coverage.sh [repo_root]
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root="${1:-$(cd "$script_dir/../.." && pwd)}"
cd "$repo_root"

WORKFLOW_FILES=(
    ".github/workflows/full-setup-validate.yml"
    ".github/workflows/full-setup-deep-validate.yml"
    ".github/workflows/full-setup-sims.yml"
)
COMPOSE_FILES=(
    "deploy/full-setup/docker-compose.yml"
    "deploy/quickstart/docker-compose.yml"
)
SIMULATIONS_DIR="scripts/untracked/simulations"

LOGIN_ACTION_MARKER='uses: ./.github/actions/ghcr-then-dockerhub-login'
RESERVE_STACK_MARKER='uses: ./.github/actions/reserve-validation-subnet-stack'

# See the header comment's "two jobs this mechanical signal cannot see".
NAMED_OPAQUE_SCRIPT_TRIGGERS=(
    "setup-cli-simulation.sh"
    "syslog-forwarding-simulation.sh"
)

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    NC='\033[0m'
else
    RED=''
    NC=''
fi

failures=0
jobs_examined=0

fail() {
    printf '%b::error:: %s%b\n' "$RED" "$1" "$NC" >&2
    failures=$((failures + 1))
}

# extract_dockerhub_services <compose_file>
# Prints one service name per line for every service in <compose_file> whose
# `image:` is NOT ghcr.io/mirror.gcr.io/${LANCACHE_IMAGE_REGISTRY...}-backed
# (see header comment). Anchored to this repo's own fixed compose-file
# indentation (services: at column 0, service names at 2 spaces, image: at 4
# spaces), matching check-bats-path-filter-coverage.sh's own tradeoff of a
# tightly-coupled-to-current-layout awk scan over pulling in a real YAML
# parser this project has never depended on.
extract_dockerhub_services() {
    local file="$1"
    awk '
        /^services:$/ { in_services = 1; next }
        in_services && /^[a-zA-Z]/ { in_services = 0 }
        in_services && /^  [a-zA-Z0-9_-]+:$/ {
            svc = $0
            sub(/^  /, "", svc)
            sub(/:$/, "", svc)
            next
        }
        in_services && /^    image:/ {
            img = $0
            sub(/^    image:[ \t]*/, "", img)
            gsub(/"/, "", img)
            if (img !~ /^ghcr\.io\// && img !~ /^mirror\.gcr\.io\// && img !~ /^\$\{LANCACHE_IMAGE_REGISTRY/) {
                print svc
            }
        }
    ' "$file"
}

dockerhub_services=()
for compose_file in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "$compose_file" ]]; then
        fail "check-registry-login-coverage: '$compose_file' no longer exists; update COMPOSE_FILES in scripts/tracked/check-registry-login-coverage.sh."
        continue
    fi
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && dockerhub_services+=("$svc")
    done < <(extract_dockerhub_services "$compose_file")
done
# What: skips dedup when the array is genuinely empty.
# Why: printf with zero args still emits one blank line.
# From: Issue #1095
if [[ ${#dockerhub_services[@]} -gt 0 ]]; then
    mapfile -t dockerhub_services < <(printf '%s\n' "${dockerhub_services[@]}" | sort -u)
fi

if [[ ${#dockerhub_services[@]} -eq 0 ]]; then
    fail "check-registry-login-coverage: found zero docker.io-backed services across ${COMPOSE_FILES[*]} -- expected at least nats/docker-socket-proxy/netdata (this guard's own parsing likely broke, or every third-party image has genuinely been migrated off docker.io, in which case this whole guard can be retired)."
fi

# body_pulls_dockerhub_service <body>
# True if <body> contains a real, non-comment `up -d`/`pull --quiet`/`run -d
# --name` compose invocation line whose argument list names at least one
# docker.io-backed service.
body_pulls_dockerhub_service() {
    local body="$1" line stripped svc
    while IFS= read -r line; do
        stripped="${line#"${line%%[! ]*}"}"
        [[ "$stripped" == \#* ]] && continue
        case "$stripped" in
            *'up -d'*|*'pull --quiet'*|*'run -d --name'*)
                for svc in "${dockerhub_services[@]}"; do
                    case " $stripped " in
                        *" $svc "*) return 0 ;;
                    esac
                done
                ;;
        esac
    done <<<"$body"
    return 1
}

# job_triggers_login_requirement <body>
# True if <body> (a job's own YAML text) or any scripts/untracked/simulations
# script it names by filename pulls a docker.io-backed service, or the body
# uses the reserve-validation-subnet-stack composite action, or the body
# names one of NAMED_OPAQUE_SCRIPT_TRIGGERS.
job_triggers_login_requirement() {
    local body="$1" script_name script_path

    if [[ "$body" == *"$RESERVE_STACK_MARKER"* ]]; then
        return 0
    fi
    if body_pulls_dockerhub_service "$body"; then
        return 0
    fi

    while IFS= read -r script_name; do
        [[ -z "$script_name" ]] && continue
        for opaque in "${NAMED_OPAQUE_SCRIPT_TRIGGERS[@]}"; do
            [[ "$script_name" == "$opaque" ]] && return 0
        done
        script_path="$SIMULATIONS_DIR/$script_name"
        if [[ -f "$script_path" ]] && body_pulls_dockerhub_service "$(cat "$script_path")"; then
            return 0
        fi
    done < <(grep -oE "${SIMULATIONS_DIR}/[A-Za-z0-9_-]+\\.sh" <<<"$body" | xargs -r -n1 basename | sort -u)

    return 1
}

# strip_leading_whitespace / indent_width / is_job_name_line / check_job_body
# / check_workflow_file below reuse check-validation-subnet-wrapper-
# coverage.sh's own job-body-extraction shape verbatim (same fixed
# 2-space-indented job-name-key layout, same reasoning for plain
# bash string/glob matching over awk/PCRE) rather than re-deriving an
# equivalent parser -- see that script's header for the full rationale.
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

check_job_body() {
    local file="$1" job_name="$2" body="$3"

    if [[ -z "$job_name" ]]; then
        return 0
    fi
    jobs_examined=$((jobs_examined + 1))
    if ! job_triggers_login_requirement "$body"; then
        return 0
    fi
    if [[ "$body" == *"$LOGIN_ACTION_MARKER"* ]]; then
        return 0
    fi
    fail "check-registry-login-coverage: $file job '$job_name' pulls a docker.io-backed service (nats/docker-socket-proxy/netdata, or uses reserve-validation-subnet-stack) but has no '$LOGIN_ACTION_MARKER' step -- this is the exact #1095 regression class: an anonymous docker.io pull that can exhaust the shared runner egress IP's rate limit. Add a step using ./.github/actions/ghcr-then-dockerhub-login before the pulling step (see e.g. ssl-mitm-cache-simulation in full-setup-sims.yml)."
}

check_workflow_file() {
    local file="$1"
    local in_jobs=0 current_job="" body="" line

    while IFS= read -r line || [[ -n "$line" ]]; do
        # What: strips a trailing CR `read -r` would otherwise keep.
        # Why: a CRLF input would silently defeat every match below.
        # From: Issue #1095
        line="${line%$'\r'}"
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
        fail "check-registry-login-coverage: '$file' no longer exists; update WORKFLOW_FILES in scripts/tracked/check-registry-login-coverage.sh."
        continue
    fi
    check_workflow_file "$file"
done

if [[ "$jobs_examined" -eq 0 ]]; then
    fail "check-registry-login-coverage: examined zero jobs across ${WORKFLOW_FILES[*]} -- expected several (this guard's own parsing likely broke, or all three workflow files changed shape; update this script rather than silently passing)."
fi

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-registry-login-coverage: %d violation(s) found (see scripts/tracked/check-registry-login-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-registry-login-coverage: OK (%d job(s) examined across %d workflow file(s), every docker.io-pulling job has the registry-login step).\n' "$jobs_examined" "${#WORKFLOW_FILES[@]}"
