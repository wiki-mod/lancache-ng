#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
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

# strip_leading_whitespace / indent_width / is_job_name_line / check_job_body / check_workflow_file
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

# --- Build-context coverage (see header's "Second, unrelated coverage") ---
build_context_invocations_examined=0

# bcc_is_known_named_context <name>
# From: Issue #1095
BCC_KNOWN_NAMED_CONTEXTS=(
    "shared-scripts"
    "dns-domains"
)

bcc_is_known_named_context() {
    local name="$1" known
    for known in "${BCC_KNOWN_NAMED_CONTEXTS[@]}"; do
        [[ "$name" == "$known" ]] && return 0
    done
    return 1
}

# bcc_required_contexts_for_dockerfile <dockerfile>
# Prints one required named-build-context name per line.
bcc_required_contexts_for_dockerfile() {
    local dockerfile="$1"
    awk '
        BEGIN { IGNORECASE = 1 }
        /^[ \t]*#/ { next }
        /^FROM[ \t]/ {
            for (i = 1; i <= NF; i++) {
                if (toupper($i) == "AS" && (i + 1) <= NF) { stages[$(i + 1)] = 1 }
            }
        }
        /^[ \t]*COPY[ \t]/ && /--from=/ {
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
    ' "$dockerfile" | sort -u | { while IFS= read -r name; do
        bcc_is_known_named_context "$name" && printf '%s\n' "$name"
    done; }
}

# bcc_join_continued_lines <file>
# Prints <file> with every `\`-continued line joined onto one logical line,
# so a multi-line docker build invocation is scanned whole.
bcc_join_continued_lines() {
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

# bcc_target_dockerfile_for_invocation <invocation-line>
# Prints the services/*/Dockerfile path this invocation targets, or nothing
# if none can be resolved.
#
# What: resolves -f/--file's argument regardless of path prefix.
# Why: `./services/x/Dockerfile`, `"$repo_root/services/x/Dockerfile"` too.
# From: Issue #1095
bcc_target_dockerfile_for_invocation() {
    local invocation="$1" explicit_arg="" resolved="" ctx=""
    # What: `|| true` per sed|grep|tail; no match isn't error.
    # Why: pipefail would else abort caller under set -e.
    explicit_arg=$(sed -nE 's/.*(^|[[:space:]])(-f|--file)[[:space:]]+("[^"]*"|[^[:space:]]+).*/\3/p' <<<"$invocation" | tail -1) || true
    if [[ -n "$explicit_arg" ]]; then
        explicit_arg="${explicit_arg%\"}"
        explicit_arg="${explicit_arg#\"}"
        resolved=$(grep -oE 'services/[A-Za-z0-9_-]+/Dockerfile$' <<<"$explicit_arg") || true
        if [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
        # An explicit -f/--file pointing outside services/*/Dockerfile
        # (e.g. a synthetic fixture) is out of this check's scope.
        return 0
    fi
    ctx=$(grep -oE 'services/[A-Za-z0-9_-]+' <<<"$invocation" | tail -1) || true
    if [[ -n "$ctx" ]]; then
        printf '%s/Dockerfile\n' "$ctx"
    fi
    return 0
}

# bcc_supplied_build_contexts <invocation-line>
# Prints one --build-context name (the part before its "=") per line.
#
# What: accepts both `--build-context name=val` and `=name=val` forms.
# Why: docker's long-option `=` separator is valid alongside a space.
# From: Issue #1095
bcc_supplied_build_contexts() {
    local invocation="$1"
    grep -oE -- '--build-context(=|[[:space:]]+)"?[A-Za-z0-9_.-]+=' <<<"$invocation" \
        | sed -E 's/--build-context(=|[[:space:]]+)"?//; s/=$//' || true
}

bcc_check_invocation() {
    local file="$1" invocation="$2" dockerfile required supplied name missing=()

    dockerfile=$(bcc_target_dockerfile_for_invocation "$invocation")
    [[ -z "$dockerfile" || ! -f "$dockerfile" ]] && return 0
    build_context_invocations_examined=$((build_context_invocations_examined + 1))

    mapfile -t required < <(bcc_required_contexts_for_dockerfile "$dockerfile")
    [[ ${#required[@]} -eq 0 ]] && return 0

    mapfile -t supplied < <(bcc_supplied_build_contexts "$invocation")
    for name in "${required[@]}"; do
        local found=0 s
        for s in "${supplied[@]}"; do
            [[ "$s" == "$name" ]] && { found=1; break; }
        done
        [[ "$found" -eq 0 ]] && missing+=("$name")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "check-registry-login-coverage (build-context): $file builds $dockerfile without --build-context for: ${missing[*]} -- buildx resolves the bare name as a registry image and fails at build time with 'pull access denied'. Add --build-context <name>=<path> for each. Invocation: $invocation"
    fi
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

# What: requires docker build in command position, not any substring.
# Why: rejects data/prose (e.g. echo "docker build ...") as non-invocation.
# From: Issue #1095
shopt -s nullglob
for file in "$SIMULATIONS_DIR"/*.sh; do
    while IFS= read -r logical_line; do
        stripped="${logical_line#"${logical_line%%[! ]*}"}"
        [[ "$stripped" == \#* ]] && continue
        case "$stripped" in
            'docker build '*|'docker buildx build '*|*'&& docker build '*|*'&& docker buildx build '*|*'; docker build '*|*'; docker buildx build '*|*'|| docker build '*|*'|| docker buildx build '*)
                bcc_check_invocation "$file" "$logical_line"
                ;;
        esac
    done < <(bcc_join_continued_lines "$file")
done
shopt -u nullglob

# What: no "examined zero" self-diagnostic for this half.
# Why: synthetic per-test fixtures legitimately have zero
# docker build invocations; unlike jobs_examined, zero here is
# not a parsing-broke signal in this shared, multi-purpose script.
if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-registry-login-coverage: %d violation(s) found (see scripts/tracked/check-registry-login-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-registry-login-coverage: OK (%d job(s) examined across %d workflow file(s), every docker.io-pulling job has the registry-login step; %d docker build invocation(s) examined, every required named build context is supplied).\n' "$jobs_examined" "${#WORKFLOW_FILES[@]}" "$build_context_invocations_examined"
