#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: single authoritative CI 2.0 implementation (ci.sh).
# Why: replaces build-push.yml's per-runner-type duplication.
# From: Issue #1683 | docs/ci-2.0-architecture.md

# ============================================================
# CONSTANTS / EXIT HANDLING
# ============================================================

CI_SH_VERSION="0.1.0"

# What: full-length-only Git SHA / OCI digest regexes.
# Why: §15 forbids abbreviated identifiers anywhere in CI 2.0.
# From: Issue #1683
readonly CI_FULL_GIT_SHA_REGEX='^[0-9a-f]{40}$'
readonly CI_FULL_OCI_DIGEST_REGEX='^sha256:[0-9a-f]{64}$'

# What: collects every failure so the run can summarize them.
# Why: a reader must never scroll back to find what failed.
# From: Issue #1683
declare -ag CI_FAILURES=()

ci_annotate() {
    # What: emits a GitHub ::error::/::warning:: annotation.
    # Why: puts the cause in the job summary, not just the log.
    # From: Issue #1683
    local level="$1"; shift
    printf '::%s::%s\n' "$level" "$*" >&2
}

ci_log() {
    # What: prints a structured, greppable log line to stderr.
    # Why: §79 requires every CI decision to be justified.
    # From: Issue #1683
    printf 'ci.sh: %s\n' "$*" >&2
}

ci_report_failure() {
    # What: reports a failure with expected vs. actual.
    # Why: an exit code alone never says what actually went wrong.
    # From: Issue #1683
    local check="$1" subject="$2" expected="$3" actual="$4" remedy="${5:-}"
    local line="$check failed for '$subject': expected $expected, got $actual"
    [[ -n "$remedy" ]] && line="$line -- fix: $remedy"
    CI_FAILURES+=("$line")
    ci_annotate error "$line"
}

ci_failure_summary() {
    # What: prints every recorded failure, then returns non-zero.
    # Why: the reader sees all causes, not just the first.
    # From: Issue #1683
    (( ${#CI_FAILURES[@]} == 0 )) && return 0
    printf '\n=== ci.sh: %d failure(s) ===\n' "${#CI_FAILURES[@]}" >&2
    local f
    for f in "${CI_FAILURES[@]}"; do
        printf '  - %s\n' "$f" >&2
    done
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && {
        printf '### ci.sh: %d failure(s)\n\n' "${#CI_FAILURES[@]}" >> "$GITHUB_STEP_SUMMARY"
        for f in "${CI_FAILURES[@]}"; do
            printf -- '- %s\n' "$f" >> "$GITHUB_STEP_SUMMARY"
        done
    }
    return 1
}

ci_die() {
    # What: annotates the cause, then exits non-zero.
    # Why: a bare exit 1 leaves the reader with no cause at all.
    # From: Issue #1683
    ci_annotate error "ci.sh: $*"
    printf 'ci.sh: error: %s\n' "$*" >&2
    exit 1
}

ci_run_checked() {
    # What: runs a command, naming it if it exits non-zero.
    # Why: §68 -- never pass a foreign exit code up unexplained.
    # From: Issue #1683
    local label="$1"; shift
    local rc=0
    "$@" || rc=$?
    (( rc == 0 )) && return 0
    ci_annotate error "$label failed (exit $rc): $*"
    printf 'ci.sh: %s failed (exit %d): %s\n' "$label" "$rc" "$*" >&2
    return "$rc"
}

# What: repo root, resolved relative to this file's location.
# Why: needed to source scripts/lib/*.sh from any caller cwd.
# From: Issue #1683
CI_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="$(cd "$CI_SH_DIR/../.." && pwd)"

ci_validate_full_git_sha() {
    # What: dies unless $1 is a full 40-hex-char Git SHA.
    # Why: §15 forbids abbreviated Git SHAs anywhere in CI 2.0.
    # From: Issue #1683
    [[ "${1:-}" =~ $CI_FULL_GIT_SHA_REGEX ]] || ci_die "not a full git SHA: ${1:-<empty>}"
}

ci_validate_full_oci_digest() {
    # What: dies unless $1 is a full sha256: OCI digest.
    # Why: §15 forbids abbreviated OCI digests anywhere in CI 2.0.
    # From: Issue #1683
    [[ "${1:-}" =~ $CI_FULL_OCI_DIGEST_REGEX ]] || ci_die "not a full OCI digest: ${1:-<empty>}"
}

# ============================================================
# SERVICE INVENTORY
# ============================================================
#
# What: the one authoritative service list + metadata (§7/8).
# Why: prevents the many-copies drift class §7 exists to stop.
# From: Issue #1683

readonly -a CI_SERVICES=(
    proxy
    dns
    watchdog
    dhcp
    dhcp-proxy
    ntp
    syslog
    ui
    netdata
    build-tools
    utilities
)

declare -Ag CI_SERVICE_CONTEXT=(
    [proxy]="services/proxy"
    [dns]="services/dns"
    [watchdog]="services/watchdog"
    [dhcp]="services/dhcp"
    [dhcp-proxy]="services/dhcp-proxy"
    [ntp]="services/ntp"
    [syslog]="services/syslog"
    [ui]="services/ui"
    [netdata]="services/netdata"
    [build-tools]="tools/build-tools"
    [utilities]="services/utilities"
)

# What: external build contexts per service, file-exact (§13).
# Why: proxy only COPYs cdn-domains.txt, not dns/.
# From: Issue #1683
declare -Ag CI_SERVICE_EXTERNAL_CONTEXT=(
    [proxy]="dns-domains=services/dns/cdn-domains.txt"
    [dns]=""
    [watchdog]=""
    [dhcp]=""
    [dhcp-proxy]=""
    [ntp]=""
    [syslog]=""
    [ui]=""
    [netdata]=""
    [build-tools]=""
    [utilities]=""
)

declare -Ag CI_SERVICE_PLATFORMS=(
    [proxy]="linux/amd64 linux/arm64"
    [dns]="linux/amd64 linux/arm64"
    [watchdog]="linux/amd64 linux/arm64"
    [dhcp]="linux/amd64 linux/arm64"
    [dhcp-proxy]="linux/amd64 linux/arm64"
    [ntp]="linux/amd64 linux/arm64"
    [syslog]="linux/amd64 linux/arm64"
    [ui]="linux/amd64 linux/arm64"
    [netdata]="linux/amd64 linux/arm64"
    [build-tools]="linux/amd64 linux/arm64"
    [utilities]="linux/amd64 linux/arm64"
)

# What: runner class per service (heavy = self-hosted pool).
# Why: §70 requests heavy runners only after admission.
# From: Issue #1683
declare -Ag CI_SERVICE_RUNNER_CLASS=(
    [proxy]="light"
    [dns]="heavy"
    [watchdog]="heavy"
    [dhcp]="light"
    [dhcp-proxy]="light"
    [ntp]="light"
    [syslog]="light"
    [ui]="heavy"
    [netdata]="light"
    [build-tools]="heavy"
    [utilities]="heavy"
)

# What: compiler class per service (drives cache tier).
# Why: §32-42 pick sccache/ccache/none from this field.
# From: Issue #1683
declare -Ag CI_SERVICE_COMPILER_CLASS=(
    [proxy]="none"
    [dns]="rust"
    [watchdog]="rust"
    [dhcp]="none"
    [dhcp-proxy]="none"
    [ntp]="none"
    [syslog]="none"
    [ui]="rust"
    [netdata]="none"
    [build-tools]="c"
    [utilities]="c"
)

ci_service_list() {
    # What: prints the authoritative service list, one per line.
    # Why: keeps §7's "exactly one list" true for reads too.
    # From: Issue #1683
    printf '%s\n' "${CI_SERVICES[@]}"
}

ci_service_exists() {
    # What: returns success iff $1 is a member of CI_SERVICES.
    # Why: single membership check, not re-implemented per caller.
    # From: Issue #1683
    local candidate="$1" svc
    for svc in "${CI_SERVICES[@]}"; do
        [[ "$svc" == "$candidate" ]] && return 0
    done
    return 1
}

ci_require_service() {
    # What: validates $1 is a known service, dies otherwise.
    # Why: fail closed on a typo instead of an undefined lookup.
    # From: Issue #1683
    local candidate="$1"
    ci_service_exists "$candidate" || ci_die "unknown service: $candidate (expected one of: ${CI_SERVICES[*]})"
}

ci_service_context() {
    # What: prints service $1's build context path.
    # Why: keeps §8's "one definition" true for reads too.
    # From: Issue #1683
    ci_require_service "$1"
    printf '%s\n' "${CI_SERVICE_CONTEXT[$1]}"
}

ci_service_platforms() {
    # What: prints service $1's build platforms, one per line.
    # Why: §43 reads platforms from one place, not per matrix job.
    # From: Issue #1683
    ci_require_service "$1"
    # shellcheck disable=SC2086 # word-split space-separated platforms on purpose
    printf '%s\n' ${CI_SERVICE_PLATFORMS[$1]}
}

ci_service_runner_class() {
    # What: prints service $1's runner class (heavy|light).
    # Why: §71 dynamic matrix needs this to pick a runner pool.
    # From: Issue #1683
    ci_require_service "$1"
    printf '%s\n' "${CI_SERVICE_RUNNER_CLASS[$1]}"
}

ci_service_compiler_class() {
    # What: prints service $1's compiler class (none|rust|c).
    # Why: selects the build's cache-tier configuration.
    # From: Issue #1683
    ci_require_service "$1"
    printf '%s\n' "${CI_SERVICE_COMPILER_CLASS[$1]}"
}

ci_service_external_contexts() {
    # What: prints service $1's external build contexts, if any.
    # Why: §13 needs proxy's real dns dependency, not a guess.
    # From: Issue #1683
    ci_require_service "$1"
    local raw="${CI_SERVICE_EXTERNAL_CONTEXT[$1]}"
    [[ -z "$raw" ]] && return 0
    # shellcheck disable=SC2086 # word-split space-separated pairs on purpose
    printf '%s\n' $raw
}

# ============================================================
# SEMANTIC PARSERS
# ============================================================
#
# What: §12.5's deliberately narrow v1, not full equivalence.
# Why: 4 grammars in bash is a project, not a helper (§12.5).
# From: Issue #1683

ci_path_is_markdown() {
    # What: true iff $1 is a Markdown file (*.md).
    # Why: Markdown is NOOP by default in the impact engine.
    # From: Issue #1683
    [[ "$1" == *.md ]]
}

# What: space-separated .md paths that ARE real build inputs.
# Why: §12.4's exception, env-driven not hardcoded.
# From: Issue #1683
CI_MARKDOWN_BUILD_INPUTS="${CI_MARKDOWN_BUILD_INPUTS:-}"

ci_markdown_is_build_input() {
    # What: true iff $1 is on the markdown build-input allowlist.
    # Why: §12.4's escape hatch for a real build input.
    # From: Issue #1683
    local path="$1" entry
    for entry in $CI_MARKDOWN_BUILD_INPUTS; do
        [[ "$path" == "$entry" ]] && return 0
    done
    return 1
}

ci_normalize_for_hash() {
    # What: strips comment/blank lines and CRLF; keeps the rest.
    # Why: shell/Dockerfile '#' is always a comment.
    # From: Issue #1683
    local path="$1"
    awk '
        { line = $0; sub(/\r$/, "", line) }
        NR == 1 { print line; next }
        { stripped = line; sub(/^[ \t]*/, "", stripped) }
        stripped == "" { next }
        substr(stripped, 1, 1) == "#" { next }
        { print line }
    ' "$path"
}

ci_normalize_yaml_for_hash() {
    # What: YAML '#' stripping that spares block scalars.
    # Why: '#' in a `key: |` body is text, not a comment.
    # From: Issue #1683
    local path="$1"
    awk '
        { raw = $0; sub(/\r$/, "", raw) }
        {
            match(raw, /^[ ]*/)
            indent = RLENGTH
            is_blank = (raw ~ /^[ ]*$/)
        }
        in_literal {
            if (is_blank || indent > literal_indent) { print raw; next }
            in_literal = 0
        }
        !is_blank && raw ~ /:[ ]*[|>][+-]?[0-9]*[ ]*(#.*)?$/ {
            literal_indent = indent
            in_literal = 1
            print raw
            next
        }
        {
            content = raw
            sub(/^[ \t]*/, "", content)
        }
        content == "" { next }
        substr(content, 1, 1) == "#" { next }
        { print raw }
    ' "$path"
}

ci_normalize_dispatch() {
    # What: normalizes stdin by $1's file extension.
    # Why: routes .yml/.yaml through the block-scalar-aware path.
    # From: Issue #1683
    case "$1" in
        *.yml | *.yaml) ci_normalize_yaml_for_hash /dev/stdin ;;
        *) ci_normalize_for_hash /dev/stdin ;;
    esac
}

ci_content_hash() {
    # What: prints the sha256 of $1's normalized content + mode.
    # Why: an exec-bit flip is a real input change too.
    # From: Issue #1683
    local path="$1" mode="${2:-}"
    { printf 'mode=%s\n' "$mode"; ci_normalize_dispatch "$path" < "$path"; } | sha256sum | cut -d' ' -f1
}

# ============================================================
# IMPACT ENGINE
# ============================================================
#
# What: path -> service impact (§11) + dependency graph (§13).
# Why: file path != service boundary; the build graph decides.
# From: Issue #1683

ci_service_touches_path() {
    # What: true iff path $2 is a build input for service $1.
    # Why: checks the service's own + external contexts (§13).
    # From: Issue #1683
    local service="$1" path="$2"
    ci_require_service "$service"
    local ctx="${CI_SERVICE_CONTEXT[$service]}"
    [[ "$path" == "$ctx" || "$path" == "$ctx"/* ]] && return 0
    local pair extpath
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        extpath="${pair#*=}"
        [[ "$path" == "$extpath" || "$path" == "$extpath"/* ]] && return 0
    done < <(ci_service_external_contexts "$service")
    return 1
}

ci_impacted_services() {
    # What: prints services impacted by the given changed paths.
    # Why: markdown is excluded by default, one path per hit.
    # From: Issue #1683
    local svc path
    for svc in "${CI_SERVICES[@]}"; do
        for path in "$@"; do
            if ci_path_is_markdown "$path" && ! ci_markdown_is_build_input "$path"; then
                continue
            fi
            if ci_service_touches_path "$svc" "$path"; then
                printf '%s\n' "$svc"
                break
            fi
        done
    done
}

ci_ref_path_mode() {
    # What: prints path $2's git mode at ref $1.
    # Why: mode lives in the tree, not the blob.
    # From: Issue #1683
    git ls-tree "$1" -- "$2" | awk '{print $1}'
}

ci_semantic_diff_is_noop() {
    # What: true iff $3's mode and content both match.
    # Why: identity must track mode too, not content alone (§16).
    # From: Issue #1683
    local base_ref="$1" head_ref="$2" path="$3"
    local base_mode head_mode base_hash head_hash

    base_mode="$(ci_ref_path_mode "$base_ref" "$path")"
    head_mode="$(ci_ref_path_mode "$head_ref" "$path")"
    [[ -n "$head_mode" && "$base_mode" == "$head_mode" ]] || return 1

    base_hash="$(git show "${base_ref}:${path}" 2>/dev/null | ci_normalize_dispatch "$path" | sha256sum)"
    head_hash="$(git show "${head_ref}:${path}" 2>/dev/null | ci_normalize_dispatch "$path" | sha256sum)"
    [[ "$base_hash" == "$head_hash" ]]
}

# ============================================================
# IDENTITY ENGINE
# ============================================================
#
# What: content-derived identities, one per domain (§14).
# Why: a commit SHA answers "when", never "is this the same".
# From: Issue #1683

# What: toolchain identity, supplied by the caller.
# Why: §16 folds it in; the repo cannot derive it.
# From: Issue #1683
CI_TOOLCHAIN_IDENTITY="${CI_TOOLCHAIN_IDENTITY:-unset}"

# What: resolved base-image digests, newline-separated (§17).
# Why: mutable tags must be pinned before hashing.
# From: Issue #1683
CI_BASE_IMAGE_DIGESTS="${CI_BASE_IMAGE_DIGESTS:-}"

ci_path_identity() {
    # What: prints "<git-mode> <normalized-content-hash>" for $1.
    # Why: mode and content together are the file's real identity.
    # From: Issue #1683
    local path="$1" mode
    mode="$(git ls-files -s -- "$path" | awk '{print $1}')"
    [[ -n "$mode" ]] || ci_die "not a tracked file: $path"
    printf '%s %s\n' "$mode" "$(ci_content_hash "$path" "$mode")"
}

ci_service_input_paths() {
    # What: prints service $1's tracked build-input paths, sorted.
    # Why: a stable order keeps the hash reproducible.
    # From: Issue #1683
    ci_service_input_entries "$1" | cut -f2
}

ci_service_input_entries() {
    # What: prints "<mode>\t<path>" per build input of service $1.
    # Why: one git call for all modes; per-file calls are slow.
    # From: Issue #1683
    local service="$1"
    ci_require_service "$service"
    {
        git ls-files -s -- "${CI_SERVICE_CONTEXT[$service]}"
        local pair
        while IFS= read -r pair; do
            [[ -z "$pair" ]] && continue
            git ls-files -s -- "${pair#*=}"
        done < <(ci_service_external_contexts "$service")
    } | awk -F'\t' '{split($1, m, " "); print m[1] "\t" $2}' | sort -u -t$'\t' -k2,2
}

ci_normalize_many() {
    # What: normalizes every path in entries file $1 in one pass.
    # Why: a subprocess per file made one identity take ~12s.
    # From: Issue #1683
    local entries="$1"
    [[ -s "$entries" ]] || return 0
    cut -f2 "$entries" | tr '\n' '\0' | xargs -0 awk -v entries="$entries" '
        BEGIN {
            FS = "\t"
            while ((getline line < entries) > 0) {
                split(line, parts, "\t")
                mode[parts[2]] = parts[1]
            }
            close(entries)
            FS = "\n"
        }
        FNR == 1 {
            is_yaml = (FILENAME ~ /\.ya?ml$/)
            in_literal = 0
            printf "=== %s %s\n", FILENAME, mode[FILENAME]
            first_line = 1
        }
        {
            raw = $0
            sub(/\r$/, "", raw)
        }
        !is_yaml && first_line { first_line = 0; print raw; next }
        {
            first_line = 0
            match(raw, /^[ ]*/)
            indent = RLENGTH
            is_blank = (raw ~ /^[ ]*$/)
        }
        is_yaml && in_literal {
            if (is_blank || indent > literal_indent) { print raw; next }
            in_literal = 0
        }
        is_yaml && !is_blank && raw ~ /:[ ]*[|>][+-]?[0-9]*[ ]*(#.*)?$/ {
            literal_indent = indent
            in_literal = 1
            print raw
            next
        }
        {
            content = raw
            sub(/^[ \t]*/, "", content)
        }
        content == "" { next }
        substr(content, 1, 1) == "#" { next }
        { print raw }
    '
}

ci_build_identity() {
    # What: prints service $1's build identity for platform $2.
    # Why: §16 -- content, platform, toolchain, pinned bases only.
    # From: Issue #1683
    local service="$1" platform="$2"
    ci_require_service "$service"
    [[ -n "$platform" ]] || ci_die "ci_build_identity: platform is required for $service"
    local entries
    entries="$(mktemp)"
    ci_service_input_entries "$service" > "$entries"
    {
        printf 'service=%s\n' "$service"
        printf 'platform=%s\n' "$platform"
        printf 'toolchain=%s\n' "$CI_TOOLCHAIN_IDENTITY"
        printf 'bases=%s\n' "$CI_BASE_IMAGE_DIGESTS"
        ci_normalize_many "$entries"
    } | sha256sum | cut -d' ' -f1
    rm -f "$entries"
}

ci_test_identity() {
    # What: prints service $1's test identity (§14.3).
    # Why: §29 -- tests re-run on a test change, without a build.
    # From: Issue #1683
    local service="$1" path
    ci_require_service "$service"
    {
        printf 'service=%s\n' "$service"
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            printf '%s %s\n' "$path" "$(ci_path_identity "$path")"
        done < <(git ls-files -- 'tests/' 'scripts/ci/ci.bats')
    } | sha256sum | cut -d' ' -f1
}

ci_validation_identity() {
    # What: prints the validation identity for digest $1 (§14.4).
    # Why: §30 -- a policy change rescans, never rebuilds.
    # From: Issue #1683
    local digest="$1"
    ci_validate_full_oci_digest "$digest"
    {
        printf 'digest=%s\n' "$digest"
        printf 'policy=%s\n' "${CI_VALIDATION_POLICY_ID:-unset}"
    } | sha256sum | cut -d' ' -f1
}

# ============================================================
# ARTIFACT RESOLVER
# ============================================================
#
# What: the six resolver states of §18.
# Why: §2.3 -- UNKNOWN is never MISSING_CONFIRMED.
# From: Issue #1683

readonly CI_STATE_PRESENT_ACCEPTED="PRESENT_ACCEPTED"
readonly CI_STATE_MISSING_CONFIRMED="MISSING_CONFIRMED"
readonly CI_STATE_BUILD_IN_PROGRESS="BUILD_IN_PROGRESS"
readonly CI_STATE_PRODUCED_UNVERIFIED="PRODUCED_UNVERIFIED"
readonly CI_STATE_MISMATCH="MISMATCH"
readonly CI_STATE_UNKNOWN="UNKNOWN"

ci_state_permits_build() {
    # What: true only for MISSING_CONFIRMED.
    # Why: §19 -- only a confirmed absence may build.
    # From: Issue #1683
    [[ "$1" == "$CI_STATE_MISSING_CONFIRMED" ]]
}

# ============================================================
# ACCEPTANCE INDEX
# ============================================================

# ============================================================
# RETRY CLASSIFIER
# ============================================================
#
# What: §67 retry, delegated to this repo's proven wrappers.
# Why: reuse the existing proven retry primitives instead.
# From: Issue #1683

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$CI_REPO_ROOT/scripts/lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/build-retry.sh
source "$CI_REPO_ROOT/scripts/lib/build-retry.sh"

ci_retry_registry_op() {
    # What: retries a registry op via ghcr_retry (env creds).
    # Why: one CI 2.0 name for §67's operation-level retry.
    # From: Issue #1683
    ghcr_retry "$1" "${GHCR_RETRY_USERNAME-}" "${GHCR_RETRY_PASSWORD-}" -- "${@:2}"
}

ci_retry_build_op() {
    # What: retries a build op via build_retry's classifier.
    # Why: one CI 2.0 name for §67's operation-level retry.
    # From: Issue #1683
    build_retry "$@"
}

# ============================================================
# CACHE CONFIGURATION
# ============================================================

# ============================================================
# BUILD ENGINE
# ============================================================

# ============================================================
# VERIFY / TEST / SCAN
# ============================================================

ci_run_bats() {
    # What: runs bats, then re-reports every 'not ok' at the end.
    # Why: a bare exit code buries failures thousands of lines up.
    # From: Issue #1683
    local logfile rc=0
    logfile="$(mktemp)"

    bats --tap "$@" 2>&1 | tee "$logfile"
    rc="${PIPESTATUS[0]}"

    local failed
    failed="$(grep -c '^not ok' "$logfile" || true)"

    if (( failed > 0 )); then
        printf '\n=== bats: %d failing test(s) ===\n' "$failed" >&2
        local line
        while IFS= read -r line; do
            printf '  - %s\n' "$line" >&2
            ci_annotate error "bats: $line"
        done < <(grep '^not ok' "$logfile")
        [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && {
            printf '### bats: %d failing test(s)\n\n' "$failed" >> "$GITHUB_STEP_SUMMARY"
            grep '^not ok' "$logfile" | sed 's/^/- /' >> "$GITHUB_STEP_SUMMARY"
        }
    elif (( rc != 0 )); then
        ci_annotate error "bats exited $rc with no failing test -- suite or harness error"
    fi

    rm -f "$logfile"
    return "$rc"
}

# ============================================================
# ASSEMBLY
# ============================================================

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# NIGHTLY / RELEASE
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# PLANNER
# ============================================================
#
# What: the first stage; decides what work a change requires.
# Why: §10 -- it builds nothing and needs no heavy runner.
# From: Issue #1683

ci_changed_paths() {
    # What: prints paths changed between refs $1 and $2.
    # Why: §10.1 -- the planner's only input is the real diff.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2"
    git diff --no-color --name-only "$base_ref" "$head_ref"
}

ci_semantic_changed_paths() {
    # What: drops paths whose normalized content did not change.
    # Why: §11 -- a comment-only edit must not reach the planner.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2" path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        ci_semantic_diff_is_noop "$base_ref" "$head_ref" "$path" && continue
        printf '%s\n' "$path"
    done < <(ci_changed_paths "$base_ref" "$head_ref")
}

ci_plan_json() {
    # What: prints the planner verdict for refs $1..$2 as JSON.
    # Why: §10.2 -- YAML consumes a machine-readable plan.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2"
    local -a changed=() impacted=()
    mapfile -t changed < <(ci_semantic_changed_paths "$base_ref" "$head_ref")
    (( ${#changed[@]} > 0 )) && mapfile -t impacted < <(ci_impacted_services "${changed[@]}")

    local global_state="NOOP"
    (( ${#impacted[@]} > 0 )) && global_state="WORK_REQUIRED"

    local svc platform first=1
    printf '{"global":{"state":"%s"},"services":{' "$global_state"
    for svc in "${CI_SERVICES[@]}"; do
        (( first )) || printf ','
        first=0
        if printf '%s\n' "${impacted[@]}" | grep -qx "$svc"; then
            printf '"%s":{"state":"ARTIFACT_REQUIRED","build_ack":false}' "$svc"
        else
            printf '"%s":{"state":"NOOP"}' "$svc"
        fi
    done
    printf '},"build_matrix":['
    first=1
    for svc in "${impacted[@]}"; do
        [[ -n "$svc" ]] || continue
        while IFS= read -r platform; do
            (( first )) || printf ','
            first=0
            printf '{"service":"%s","platform":"%s","runner":"%s"}' \
                "$svc" "$platform" "$(ci_service_runner_class "$svc")"
        done < <(ci_service_platforms "$svc")
    done
    printf ']}\n'
}

ci_emit_output() {
    # What: writes name=value to GITHUB_OUTPUT, else stdout.
    # Why: keeps workflow YAML free of output-plumbing shell (§5).
    # From: Issue #1683
    local name="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$name" "$value"
    fi
}

ci_cmd_resolve_refs() {
    # What: resolves the diff base/head for the triggering event.
    # Why: §10.1 -- one place decides what the planner diffs.
    # From: Issue #1683
    local base head="${HEAD_REF:-${HEAD_SHA:-HEAD}}"
    case "${EVENT_NAME:-}" in
        pull_request) base="${PR_BASE_SHA:-}" ;;
        push) base="${PUSH_BEFORE_SHA:-}" ;;
        *) base="" ;;
    esac
    # What: an unusable base falls back to the head itself.
    # Why: fail safe as NOOP, not a whole-tree diff.
    # From: Issue #1683
    if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
        ci_log "no usable diff base for event '${EVENT_NAME:-unknown}'; planning against head"
        base="$head"
    fi
    ci_emit_output base-ref "$base"
    ci_emit_output head-ref "$head"
}

ci_cmd_plan_outputs() {
    # What: runs the planner and exports its verdict as outputs.
    # Why: §10.2 -- the job graph reads its matrix here.
    # From: Issue #1683
    local plan
    plan="$(ci_plan_json "${BASE_REF:?BASE_REF is required}" "${HEAD_REF:?HEAD_REF is required}")"
    printf '%s\n' "$plan"
    local global_state matrix
    global_state="$(printf '%s' "$plan" | sed -n 's/.*"global":{"state":"\([A-Z_]*\)".*/\1/p')"
    matrix="$(printf '%s' "$plan" | sed -n 's/.*"build_matrix":\(\[.*\]\)}$/\1/p')"
    ci_emit_output global-state "${global_state:-UNKNOWN}"
    ci_emit_output build-matrix "${matrix:-[]}"
    ci_log "planner verdict: ${global_state:-UNKNOWN}"
}

ci_cmd_report_result() {
    # What: turns the job results into one pass/fail verdict.
    # Why: §62 -- the required check reports even on a NOOP run.
    # From: Issue #1683
    local plan_result="${PLAN_RESULT:-}" tests_result="${TESTS_RESULT:-}"
    local state="${GLOBAL_STATE:-UNKNOWN}"
    [[ "$plan_result" == "success" ]] \
        || ci_report_failure "plan job" "ci.yml" "success" "$plan_result" "see the plan job log"
    [[ "$tests_result" == "success" || "$tests_result" == "skipped" ]] \
        || ci_report_failure "engine tests" "ci.bats" "success" "$tests_result" "see the failing tests listed in that job"
    ci_failure_summary || ci_die "CI 2.0 result: FAILED (see the failures listed above)"
    ci_log "CI 2.0 result: SUCCESS (planner state: $state)"
}

# ============================================================
# DISPATCH
# ============================================================

ci_usage() {
    cat <<'USAGE'
Usage: ci.sh <command> [args...]

Commands:
  services                     List the one authoritative service list.
  identity <service> <plat>    Print the content-derived build identity.
  plan <base-ref> <head-ref>   Print the planner verdict as JSON.
  test [path...]               Run bats, summarizing every failure.
  version                      Print ci.sh's own version.
USAGE
}

ci_main() {
    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { ci_usage >&2; ci_die "no command given"; }
    shift || true
    case "$cmd" in
        services) ci_service_list ;;
        identity) ci_build_identity "${1:-}" "${2:-}" ;;
        plan) ci_plan_json "${1:?ci.sh plan: base ref required}" "${2:?ci.sh plan: head ref required}" ;;
        resolve-refs) ci_cmd_resolve_refs ;;
        plan-outputs) ci_cmd_plan_outputs ;;
        report-result) ci_cmd_report_result ;;
        test) ci_run_bats "${@:-$CI_SH_DIR/ci.bats}" ;;
        version) printf '%s\n' "$CI_SH_VERSION" ;;
        -h|--help|help) ci_usage ;;
        *) ci_die "unknown command: $cmd (try: ci.sh help)" ;;
    esac
}

# What: only runs ci_main when executed, not when sourced.
# Why: ci.bats sources this file to unit-test functions.
# From: Issue #1683
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # What: strict mode only for real execution, not sourcing.
    # Why: ci.bats's own setup() sources this under its options.
    # From: Issue #1683
    set -euo pipefail
    ci_main "$@"
fi
