#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: ensure docker.io login and build-context coverage.
# Why: prevent silent anonymous pulls on job moves.
# From: Issue #1014
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

# What: setup-cli/syslog sims pull via setup.sh CLI.
# Why: not docker-compose invocations; verified by hand.
# From: Issue #1014
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
# What: image lacks ghcr.io/mirror.gcr.io prefix = pull.
# Why: derived from compose, not a hardcoded service list.
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

# What: matches a real compose line naming the service.
# Why: a comment merely mentioning the name must not count.
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

# What: true if the job pulls docker.io via any trigger.
# Why: covers reserve-stack and named-opaque-script cases.
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
        # What: strips the trailing CR read -r would keep.
        # Why: CRLF would silently defeat matches below.
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

# What: build invocations need required --build-context.
# Why: missing context = buildx pulls a bare image name.
# From: Issue #1095
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

# CI matrix declaring each service's named build contexts.
BCC_BUILD_PUSH_YML=".github/workflows/build-push.yml"

# What: prints each build_contexts name in the CI matrix.
# Why: read names value-independently, not just paths.
# From: Issue #1095 (PR #1836 review: #2)
bcc_ci_declared_contexts() {
    awk '
        /build_contexts:[[:space:]]*\|[[:space:]]*$/ { in_block = 1; next }
        /build_contexts:[[:space:]]*[^|[:space:]]/ {
            line = $0; sub(/.*build_contexts:[[:space:]]*/, "", line)
            if (line ~ /=/) { split(line, a, "="); gsub(/[[:space:]]/, "", a[1]); print a[1] }
            in_block = 0; next
        }
        in_block {
            if ($0 ~ /^[[:space:]]+[a-z][a-z0-9_-]*=/) {
                line = $0; sub(/^[[:space:]]+/, "", line); split(line, a, "="); print a[1]
            } else if ($0 ~ /^[[:space:]]*[a-zA-Z_-]+:/ || $0 !~ /[^[:space:]]/) { in_block = 0 }
        }
    ' "$BCC_BUILD_PUSH_YML" | sort -u
}

# What: allowlist covers every build-push.yml context.
# Why: a new named context would else pass unverified.
# From: Issue #1095 (PR #1836 review: #2)
bcc_assert_allowlist_covers_ci_contexts() {
    local name
    [[ -f "$BCC_BUILD_PUSH_YML" ]] || return 0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        bcc_is_known_named_context "$name" || fail "check-registry-login-coverage (build-context): $BCC_BUILD_PUSH_YML declares build context '$name' absent from BCC_KNOWN_NAMED_CONTEXTS -- add '$name' there so simulations are verified to supply it."
    done < <(bcc_ci_declared_contexts)
}

# bcc_all_named_contexts_for_dockerfile <dockerfile>
# Prints every external named build context (known or not), one per line.
bcc_all_named_contexts_for_dockerfile() {
    local dockerfile="$1"
    # What: join \-continued lines before matching COPY --from.
    # Why: COPY and --from= can sit on separate physical lines.
    # From: Issue #1095 (PR #1836 review: #3)
    bcc_join_continued_lines "$dockerfile" | awk '
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
    ' | sort -u
}

# bcc_required_contexts_for_dockerfile <dockerfile>
# Prints one required (known) named-build-context name per line.
bcc_required_contexts_for_dockerfile() {
    local dockerfile="$1" name
    bcc_all_named_contexts_for_dockerfile "$dockerfile" | { while IFS= read -r name; do
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

# What: prints the docker build positional PATH argument.
# Why: last bare token skips flags and name=VALUE opts.
# From: Issue #1095 (PR #1836 review: #5/#6)
bcc_positional_context() {
    local invocation
    invocation=$(bcc_strip_inline_comment "$1")
    awk 'BEGIN { dq = sprintf("%c", 34); sq = sprintf("%c", 39) }
    {
        inq = 0; qc = ""; tok = ""; last = ""; n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (inq) { tok = tok c; if (c == qc) inq = 0; continue }
            if (c == dq || c == sq) { inq = 1; qc = c; continue }
            if (c == " " || c == "\t") {
                if (tok != "") { if (tok !~ /^-/ && tok !~ /=/ && tok !~ /[<>]/) last = tok; tok = "" }
                continue
            }
            tok = tok c
        }
        if (tok != "") { if (tok !~ /^-/ && tok !~ /=/ && tok !~ /[<>]/) last = tok }
        print last
    }' <<<"$invocation"
}

# What: resolves the Dockerfile path from -f or context.
# Why: a path prefix like $repo_root/ must still resolve.
# From: Issue #1095
bcc_target_dockerfile_for_invocation() {
    local invocation="$1" explicit_arg="" resolved="" ctx=""
    # What: no sed/grep/tail match is not an error here.
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
    # What: derive the Dockerfile from the positional context only.
    # Why: a services/* value in --build-context is not the target.
    # From: Issue #1095 (PR #1836 review: #5/#6)
    ctx=$(bcc_positional_context "$invocation")
    resolved=$(grep -oE 'services/[A-Za-z0-9_-]+/?$' <<<"$ctx") || true
    if [[ -n "$resolved" ]]; then
        printf '%s/Dockerfile\n' "${resolved%/}"
    fi
    return 0
}

# bcc_strip_inline_comment <line>
# Drops a trailing `#`-comment (a `#` starting a word outside quotes),
# so a commented-out option is not read as an active argument.
bcc_strip_inline_comment() {
    awk 'BEGIN { dq = sprintf("%c", 34); sq = sprintf("%c", 39) }
    {
        inq = 0; qc = ""; out = ""
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (inq) { out = out c; if (c == qc) inq = 0; continue }
            if (c == dq || c == sq) { inq = 1; qc = c; out = out c; continue }
            if (c == "#") {
                p = (i > 1) ? substr($0, i - 1, 1) : " "
                if (p == " " || p == "\t") break
            }
            out = out c
        }
        print out
    }' <<<"$1"
}

# What: prints each --build-context name supplied.
# Why: space/= forms, single/double quotes, no comments.
# From: Issue #1095 (PR #1836 review: #4/#6)
bcc_supplied_build_contexts() {
    local invocation="$1"
    invocation=$(bcc_strip_inline_comment "$invocation")
    grep -oE -- '--build-context(=|[[:space:]]+)["'\'']?[A-Za-z0-9_.-]+=' <<<"$invocation" \
        | sed -E 's/--build-context(=|[[:space:]]+)["'\'']?//; s/=$//' || true
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

# What: split a line on top-level && || ; separators.
# Why: each build on a line must be checked, not only last.
# From: Issue #1095 (PR #1836 review: #9)
bcc_split_commands() {
    awk 'BEGIN { dq = sprintf("%c", 34); sq = sprintf("%c", 39) }
    {
        inq = 0; qc = ""; seg = ""; n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (inq) { seg = seg c; if (c == qc) inq = 0; continue }
            if (c == dq || c == sq) { inq = 1; qc = c; seg = seg c; continue }
            two = substr($0, i, 2)
            if (two == "&&" || two == "||") { print seg; seg = ""; i++; continue }
            if (c == ";") { print seg; seg = ""; continue }
            seg = seg c
        }
        print seg
    }' <<<"$1"
}

# What: drops leading env-assignments and control keywords.
# Why: env-prefix or if-keyword else hides the build.
# From: Issue #1095 (PR #1836 review: #1)
bcc_strip_command_prefix() {
    BCC_STRIPPED="${1#"${1%%[![:space:]]*}"}"
    while [[ "$BCC_STRIPPED" =~ ^(if|then|else|elif|while|until|do|!)[[:space:]]+ ]]; do
        BCC_STRIPPED="${BCC_STRIPPED#"${BASH_REMATCH[0]}"}"
    done
    while [[ "$BCC_STRIPPED" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
        BCC_STRIPPED="${BCC_STRIPPED#"${BASH_REMATCH[0]}"}"
    done
}

shopt -s nullglob
bcc_docker_build_re='^docker[[:space:]]+(buildx[[:space:]]+)?build([[:space:]]|$)'
for file in "$SIMULATIONS_DIR"/*.sh; do
    while IFS= read -r logical_line; do
        stripped="${logical_line#"${logical_line%%[! ]*}"}"
        [[ "$stripped" == \#* ]] && continue
        # What: only split lines that hold a docker build.
        # Why: splitting every line else costs minutes.
        # From: Issue #1095 (PR #1836 review: #9)
        [[ "$stripped" =~ docker[[:space:]]+(buildx[[:space:]]+)?build([[:space:]]|$) ]] || continue
        while IFS= read -r segment; do
            bcc_strip_command_prefix "$segment"
            if [[ "$BCC_STRIPPED" =~ $bcc_docker_build_re ]]; then
                bcc_check_invocation "$file" "$segment"
            fi
        done < <(bcc_split_commands "$logical_line")
    done < <(bcc_join_continued_lines "$file")
done
shopt -u nullglob

bcc_assert_allowlist_covers_ci_contexts

# What: fixture trees legitimately examine zero invocations.
# Why: zero fixtures isn't a broken-parse signal here.
# ============================================================================

if [[ "$failures" -gt 0 ]]; then
    printf '::error::check-registry-login-coverage: %d violation(s) found (see scripts/tracked/check-registry-login-coverage.sh).\n' "$failures" >&2
    exit 1
fi

printf 'check-registry-login-coverage: OK (%d job(s) examined across %d workflow file(s), every docker.io-pulling job has the registry-login step; %d docker build invocation(s) examined, every required named build context is supplied).\n' "$jobs_examined" "${#WORKFLOW_FILES[@]}" "$build_context_invocations_examined"
