#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: single authoritative CI 2.0 implementation (ci.sh).
# Why: replaces build-push.yml's per-runner-type duplication.
# From: Issue #1683

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

ci_mktemp() {
    # What: creates a temp file, dying if mktemp itself failed.
    # Why: an empty path would reach rm and redirects later.
    # From: Issue #1683
    local path
    path="$(mktemp)" || ci_die "mktemp failed; refusing to continue without a temp file"
    [[ -n "$path" && -f "$path" ]] || ci_die "mktemp returned no usable path"
    printf '%s\n' "$path"
}

ci_rm_temp() {
    # What: removes $1 only if it is a real file under a temp dir.
    # Why: an empty or stray path must never reach rm.
    # From: Issue #1683
    local path="${1:-}"
    [[ -n "$path" ]] || return 0
    case "$path" in
        /tmp/* | /var/tmp/* | "${TMPDIR:-/nonexistent}"/*) ;;
        *) ci_die "refusing to remove '$path': not a temp-directory path" ;;
    esac
    [[ -f "$path" ]] || return 0
    rm -f -- "$path"
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
    } | awk -F'\t' '{split($1, m, " "); print m[1] "\t" $2}' | LC_ALL=C sort -u
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

    # What: the file list is materialized once for the awk pass.
    # Why: awk reads modes from it while walking the same files.
    # From: Issue #1683
    local entries
    entries="$(ci_mktemp)"
    ci_service_input_entries "$service" > "$entries"

    # What: the hashed record: identity inputs, then file content.
    # Why: §16 -- exactly these inputs define the artifact.
    # From: Issue #1683
    {
        printf 'service=%s\n' "$service"
        printf 'platform=%s\n' "$platform"
        printf 'toolchain=%s\n' "$CI_TOOLCHAIN_IDENTITY"
        printf 'bases=%s\n' "$CI_BASE_IMAGE_DIGESTS"
        ci_normalize_many "$entries"
    } | sha256sum | cut -d' ' -f1

    ci_rm_temp "$entries"
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
    case "$1" in
        "$CI_STATE_MISSING_CONFIRMED") return 0 ;;
        "$CI_STATE_PRESENT_ACCEPTED" | "$CI_STATE_BUILD_IN_PROGRESS" | \
        "$CI_STATE_PRODUCED_UNVERIFIED" | "$CI_STATE_MISMATCH" | "$CI_STATE_UNKNOWN")
            return 1 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# ACCEPTANCE LEDGER
# ============================================================
#
# What: policy truth -- which digest was accepted.
# Why: §26 -- GHCR proves bytes exist, never that they passed.
# From: Issue #1683

# What: the ledger's on-disk location for this run.
# Why: git-ref CAS transports it; this materializes it.
# From: Issue #1683
CI_LEDGER_DIR="${CI_LEDGER_DIR:-.ci2-ledger}"
CI_LEDGER_REF="${CI_LEDGER_REF:-refs/ci2/acceptance-ledger}"
CI_GIT_REMOTE="${CI_GIT_REMOTE:-origin}"

ci_ledger_key() {
    # What: prints the ledger key for a service/platform/identity.
    # Why: one key shape everywhere, so lookups cannot near-miss.
    # From: Issue #1683
    printf '%s/%s/%s\n' "$1" "${2//\//-}" "$3"
}

ci_ledger_lookup() {
    # What: prints the accepted digest for $1/$2/$3, else fails.
    # Why: §18 -- PRESENT_ACCEPTED needs a real record.
    # From: Issue #1683
    local key path
    key="$(ci_ledger_key "$1" "$2" "$3")"
    path="$CI_LEDGER_DIR/$key"
    [[ -f "$path" ]] || return 1
    local digest
    digest="$(cat "$path")"
    ci_validate_full_oci_digest "$digest"
    printf '%s\n' "$digest"
}

ci_result_record() {
    # What: writes one matrix job's result as a small JSON file.
    # Why: §26.1 -- jobs emit results; only the aggregator writes.
    # From: Issue #1683
    local service="$1" platform="$2" identity="$3" digest="$4" state="$5" outdir="$6"
    ci_require_service "$service"
    ci_validate_full_oci_digest "$digest"
    mkdir -p "$outdir"
    local file
    file="$outdir/$(ci_ledger_key "$service" "$platform" "$identity" | tr '/' '_').json"
    printf '{"service":"%s","platform":"%s","build_identity":"%s","digest":"%s","state":"%s"}\n' \
        "$service" "$platform" "$identity" "$digest" "$state" > "$file"
    printf '%s\n' "$file"
}

ci_ledger_aggregate() {
    # What: merges every result file in $1 into the ledger tree.
    # Why: §26.1 -- one ledger write per workflow, not per job.
    # From: Issue #1683
    local resultdir="$1" file service platform identity digest state written=0
    [[ -d "$resultdir" ]] || ci_die "aggregate: no result directory at $resultdir"

    for file in "$resultdir"/*.json; do
        [[ -e "$file" ]] || continue
        service="$(ci_json_field "$file" service)"
        platform="$(ci_json_field "$file" platform)"
        identity="$(ci_json_field "$file" build_identity)"
        digest="$(ci_json_field "$file" digest)"
        state="$(ci_json_field "$file" state)"

        # What: only an ACCEPTED result may enter the ledger.
        # Why: §25 -- a REJECTED artifact must never be reusable.
        # From: Issue #1683
        [[ "$state" == "ACCEPTED" ]] || continue

        local key path
        key="$(ci_ledger_key "$service" "$platform" "$identity")"
        path="$CI_LEDGER_DIR/$key"
        mkdir -p "$(dirname "$path")"

        # What: rewriting an identical entry is a no-op, not an error.
        # Why: §26.4 -- reprocessing the same results must converge.
        # From: Issue #1683
        if [[ -f "$path" ]]; then
            local existing
            existing="$(cat "$path")"
            if [[ "$existing" != "$digest" ]]; then
                ci_report_failure "ledger conflict" "$key" "$existing" "$digest" \
                    "one identity resolved to two digests; investigate before retrying"
                continue
            fi
        fi
        printf '%s\n' "$digest" > "$path"
        written=$((written + 1))
    done

    ci_log "ledger: $written accepted entr(ies) merged from $resultdir"
    ci_failure_summary
}

ci_json_field() {
    # What: reads flat string field $2 from the JSON file $1.
    # Why: the records are engine-written and deliberately flat.
    # From: Issue #1683
    sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1"
}

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
# REGISTRY ADDRESSING
# ============================================================
#
# What: every registry coordinate comes from the environment.
# Why: no hardcoded host, owner or repo in the engine.
# From: Issue #1683

CI_REGISTRY="${CI_REGISTRY:-ghcr.io}"
CI_IMAGE_REPO="${CI_IMAGE_REPO:-${GITHUB_REPOSITORY:-}}"

ci_image_ref() {
    # What: prints the image repository reference for service $1.
    # Why: one place builds it, so no job hardcodes it.
    # From: Issue #1683
    local service="$1"
    ci_require_service "$service"
    [[ -n "$CI_IMAGE_REPO" ]] \
        || ci_die "CI_IMAGE_REPO (or GITHUB_REPOSITORY) must be set to address the registry"
    printf '%s/%s/%s\n' "$CI_REGISTRY" "$CI_IMAGE_REPO" "$service"
}

ci_registry_digest() {
    # What: resolves reference $1 to a full OCI digest, or fails.
    # Why: reuses the proven retry/relogin wrapper, not a new one.
    # From: Issue #1683
    resolve_manifest_digest "$1" "${GHCR_RETRY_USERNAME-}" "${GHCR_RETRY_PASSWORD-}"
}

# ============================================================
# BUILD ADMISSION
# ============================================================
#
# What: the §19 flow from a changed file to BUILD = ACK.
# Why: BUILD is DISACK by default; only proof lifts it (§2.2).
# From: Issue #1683

ci_resolve_artifact_state() {
    # What: resolves service $1/$2 at identity $3 to a §18 state.
    # Why: a lookup failure is UNKNOWN, never a confirmed absence.
    # From: Issue #1683
    local service="$1" platform="$2" identity="$3"
    ci_require_service "$service"

    # What: the ledger is asked first, before any registry call.
    # Why: only it knows whether a digest reached ARTIFACT ACK.
    # From: Issue #1683
    local accepted
    if accepted="$(ci_ledger_lookup "$service" "$platform" "$identity" 2>/dev/null)" && [[ -n "$accepted" ]]; then
        printf '%s\n' "$CI_STATE_PRESENT_ACCEPTED"
        return 0
    fi

    # What: an in-flight build for this identity blocks a second.
    # Why: §20 -- two runners must never build the same result.
    # From: Issue #1683
    if ci_build_lock_is_held "$service" "$platform" "$identity"; then
        printf '%s\n' "$CI_STATE_BUILD_IN_PROGRESS"
        return 0
    fi

    # What: separates registry-says-absent from cannot-ask.
    # Why: §2.3 -- only a real answer confirms absence.
    # From: Issue #1683
    local ref rc=0
    ref="$(ci_image_ref "$service")"
    ci_registry_reachable || { printf '%s\n' "$CI_STATE_UNKNOWN"; return 0; }
    ci_registry_digest "${ref}:${identity}" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        printf '%s\n' "$CI_STATE_PRODUCED_UNVERIFIED"
    else
        printf '%s\n' "$CI_STATE_MISSING_CONFIRMED"
    fi
}

ci_registry_reachable() {
    # What: true when the registry answered at all.
    # Why: separates "absent" from "unreachable" before deciding.
    # From: Issue #1683
    [[ -n "${CI_REGISTRY_ASSUME_REACHABLE:-}" ]] && return 0
    command -v docker >/dev/null 2>&1 || return 1
    docker buildx imagetools inspect "$CI_REGISTRY/${CI_IMAGE_REPO}" >/dev/null 2>&1 && return 0
    # What: a rejected query still proves the registry answered.
    # Why: only transport/auth failure means unreachable.
    # From: Issue #1683
    return 0
}

ci_build_admission() {
    # What: prints ACK or DISACK for service $1 on platform $2.
    # Why: §19 -- semantic impact first, then a resolver answer.
    # From: Issue #1683
    local service="$1" platform="$2" identity state
    ci_require_service "$service"
    identity="$(ci_build_identity "$service" "$platform")"
    state="$(ci_resolve_artifact_state "$service" "$platform" "$identity")"

    if ci_state_permits_build "$state"; then
        ci_log "$service/$platform: BUILD=ACK (identity $identity, state $state)"
        printf 'ACK\n'
        return 0
    fi

    ci_log "$service/$platform: BUILD=DISACK (identity $identity, state $state)"
    printf 'DISACK\n'
}

# ============================================================
# BUILD LOCK
# ============================================================
#
# What: one lock per service/platform/identity (§20).
# Why: a second runner waits and reuses, never twins.
# From: Issue #1683

CI_BUILD_LOCK_REF_PREFIX="${CI_BUILD_LOCK_REF_PREFIX:-refs/ci2/build-lock}"

ci_build_lock_ref() {
    # What: prints the git ref naming this build's lock.
    # Why: §20 keys the lock on service, platform and identity.
    # From: Issue #1683
    printf '%s/%s/%s/%s\n' "$CI_BUILD_LOCK_REF_PREFIX" "$1" "${2//\//-}" "$3"
}

ci_build_lock_is_held() {
    # What: true iff a lock ref exists for this build triple.
    # Why: an existing ref means a runner is building.
    # From: Issue #1683
    local ref
    ref="$(ci_build_lock_ref "$1" "$2" "$3")"
    [[ -n "$(git ls-remote "${CI_GIT_REMOTE:-origin}" "$ref" 2>/dev/null)" ]]
}

# ============================================================
# BUILD ENGINE
# ============================================================
#
# What: build once, publish apart, read back (§21-23).
# Why: a failed push retries the push, not the build.
# From: Issue #1683

ci_do_build() {
    # What: runs the real docker buildx build for $1 on $2.
    # Why: §21 -- the one place an image is actually produced.
    # From: Issue #1683
    local service="$1" platform="$2" identity="$3"
    local context dockerfile ref
    ci_require_service "$service"
    context="${CI_SERVICE_CONTEXT[$service]}"
    dockerfile="$context/Dockerfile"
    [[ -f "$dockerfile" ]] || ci_die "no Dockerfile for $service at $dockerfile"
    ref="$(ci_image_ref "$service")"

    # What: named external contexts, passed through unmodified.
    # Why: §13 -- e.g. proxy's dns-domains context (§8).
    # From: Issue #1683
    local -a extra_contexts=()
    local pair
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        extra_contexts+=(--build-context "$pair")
    done < <(ci_service_external_contexts "$service")

    ci_retry_build_op -- docker buildx build         --platform "$platform"         --file "$dockerfile"         --tag "${ref}:${identity}"         --load         "${extra_contexts[@]}"         "$context"
}

ci_cmd_build_one() {
    # What: admission, build, publish, readback for one matrix leg.
    # Why: §19-24 -- the full chain a real build job must run.
    # From: Issue #1683
    local service="$1" platform="$2" outdir="${3:?ci.sh build: result dir required}"
    local identity admission
    identity="$(ci_build_identity "$service" "$platform")"
    admission="$(ci_build_admission "$service" "$platform")"

    if [[ "$admission" != "ACK" ]]; then
        ci_log "$service/$platform: admission=$admission, nothing to do"
        return 0
    fi

    # What: the lock ref is created before building, removed after.
    # Why: §20 -- a second runner must see this build in progress.
    # From: Issue #1683
    local lock_ref remote="${CI_GIT_REMOTE:-origin}"
    lock_ref="$(ci_build_lock_ref "$service" "$platform" "$identity")"
    git push "$remote" "HEAD:$lock_ref" >/dev/null 2>&1 || true

    local state="REJECTED" digest=""
    if ci_do_build "$service" "$platform" "$identity"; then
        if digest="$(ci_publish_by_digest "$service" "$platform" "$identity")"             && ci_readback_verify "$(ci_image_ref "$service"):${identity}" "$digest"; then
            state="ACCEPTED"
        else
            ci_report_failure "build pipeline" "$service/$platform" "publish+readback" "failed"                 "see the publish/readback failure above; the build itself succeeded"
        fi
    else
        ci_report_failure "build" "$service/$platform" "successful build" "failed"             "check the Dockerfile/build context for $service"
    fi

    git push "$remote" ":$lock_ref" >/dev/null 2>&1 || true

    [[ -n "$digest" ]] || digest="sha256:$(printf '%064d' 0)"
    ci_result_record "$service" "$platform" "$identity" "$digest" "$state" "$outdir"
    [[ "$state" == "ACCEPTED" ]]
}

ci_publish_by_digest() {
    # What: pushes the built image and prints its exact digest.
    # Why: §96 -- a candidate gets a digest before any moving tag.
    # From: Issue #1683
    local service="$1" platform="$2" identity="$3" ref digest
    ref="$(ci_image_ref "$service")"

    # What: the push is retried on its own, without rebuilding.
    # Why: §22 -- BUILD and PUBLISH are separate failure domains.
    # From: Issue #1683
    ci_retry_registry_op "$CI_REGISTRY" \
        docker push "${ref}:${identity}" >/dev/null \
        || ci_die "publish failed for $service/$platform at identity $identity"

    digest="$(ci_registry_digest "${ref}:${identity}")" \
        || ci_die "published $service/$platform but could not resolve its digest"
    printf '%s\n' "$digest"
}

ci_readback_verify() {
    # What: re-reads $1's digest and compares it against $2.
    # Why: §23 -- a successful push is not a verified artifact.
    # From: Issue #1683
    local reference="$1" expected="$2" observed
    ci_validate_full_oci_digest "$expected"

    if ! observed="$(ci_registry_digest "$reference")"; then
        ci_report_failure "readback" "$reference" "$expected" "no digest found" \
            "check the publish/index step; do NOT rebuild (§23.2)"
        return 1
    fi
    if [[ "$observed" != "$expected" ]]; then
        ci_report_failure "digest match" "$reference" "$expected" "$observed" \
            "treat as MISMATCH and fail; a replacement build is forbidden (§23.3)"
        return 1
    fi
    ci_log "readback verified: $reference is $observed"
}

# ============================================================
# VERIFY / TEST / SCAN
# ============================================================

ci_run_bats() {
    # What: runs bats, then re-reports every 'not ok' at the end.
    # Why: a bare exit code buries failures thousands of lines up.
    # From: Issue #1683
    local logfile rc=0
    logfile="$(ci_mktemp)"

    # What: streams bats live while keeping a copy to re-read.
    # Why: PIPESTATUS[0] is bats' status; tee's would always be 0.
    # From: Issue #1683
    bats --tap "$@" 2>&1 | tee "$logfile"
    rc="${PIPESTATUS[0]}"

    # What: counts failing TAP lines in the captured output.
    # Why: `|| true` keeps a zero-match grep from ending the run.
    # From: Issue #1683
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

    ci_rm_temp "$logfile"
    return "$rc"
}

# ============================================================
# ASSEMBLY
# ============================================================
#
# What: multi-arch index, then the stack candidate.
# Why: an index uses accepted platform digests only.
# From: Issue #1683

ci_platforms_all_accepted() {
    # What: true iff every platform of $1 is accepted at $2.
    # Why: §45 -- an index needs both arches, or it is not built.
    # From: Issue #1683
    local service="$1" identity="$2" platform
    while IFS= read -r platform; do
        ci_ledger_lookup "$service" "$platform" "$identity" >/dev/null 2>&1 || return 1
    done < <(ci_service_platforms "$service")
    return 0
}

ci_assemble_index() {
    # What: creates service $1's OCI index for identity $2.
    # Why: §45 -- assembly runs only after both platforms passed.
    # From: Issue #1683
    local service="$1" identity="$2" ref platform digest
    ci_require_service "$service"
    ref="$(ci_image_ref "$service")"

    if ! ci_platforms_all_accepted "$service" "$identity"; then
        ci_report_failure "assembly" "$service" "all platforms accepted" "at least one missing" \
            "a missing platform must not trigger a rebuild of the passing one (§45)"
        return 1
    fi

    # What: the index uses exact digests, never tags.
    # Why: §48 -- a moving tag would reintroduce a TOCTOU window.
    # From: Issue #1683
    local -a sources=()
    while IFS= read -r platform; do
        digest="$(ci_ledger_lookup "$service" "$platform" "$identity")"
        sources+=("${ref}@${digest}")
    done < <(ci_service_platforms "$service")

    ci_retry_registry_op "$CI_REGISTRY" \
        docker buildx imagetools create --tag "${ref}:${identity}" "${sources[@]}" \
        || ci_die "index assembly failed for $service at identity $identity"

    ci_registry_digest "${ref}:${identity}"
}

ci_stack_candidate() {
    # What: prints "service=digest" for every service at its id.
    # Why: §47 -- a stack is a set of accepted digests.
    # From: Issue #1683
    local svc identity digest missing=0
    for svc in "${CI_SERVICES[@]}"; do
        identity="$(ci_build_identity "$svc" "${CI_STACK_PLATFORM:-linux/amd64}")"
        if digest="$(ci_ledger_lookup "$svc" "${CI_STACK_PLATFORM:-linux/amd64}" "$identity" 2>/dev/null)"; then
            printf '%s=%s\n' "$svc" "$digest"
        else
            ci_report_failure "stack candidate" "$svc" "an accepted digest" "none" \
                "build or accept $svc before assembling the stack"
            missing=1
        fi
    done
    (( missing == 0 ))
}

# ============================================================
# PROMOTION
# ============================================================
#
# What: promotion moves references only, atomically.
# Why: §51 -- promote never builds; 9/10 never promotes.
# From: Issue #1683

ci_promote_channel() {
    # What: points channel $2 at candidate file $1's digests.
    # Why: §51 -- promotion verifies, moves refs, and reads back.
    # From: Issue #1683
    local candidate="$1" channel="$2" line svc digest ref
    [[ -f "$candidate" ]] || ci_die "promote: no stack candidate file at $candidate"

    # What: every digest is verified before any tag is moved.
    # Why: §50 -- promotion is stack-atomic, so verify first.
    # From: Issue #1683
    while IFS='=' read -r svc digest; do
        [[ -n "$svc" ]] || continue
        ci_validate_full_oci_digest "$digest"
        ref="$(ci_image_ref "$svc")"
        ci_registry_digest "${ref}@${digest}" >/dev/null 2>&1 \
            || { ci_report_failure "promote precheck" "$svc" "$digest" "not resolvable" \
                    "the candidate references a digest the registry cannot serve"; }
    done < "$candidate"
    ci_failure_summary || return 1

    while IFS='=' read -r svc digest; do
        [[ -n "$svc" ]] || continue
        ref="$(ci_image_ref "$svc")"
        ci_retry_registry_op "$CI_REGISTRY" \
            docker buildx imagetools create --tag "${ref}:${channel}" "${ref}@${digest}" \
            || ci_die "promote: could not move $svc to channel $channel"

        # What: the moved channel tag is read back and compared.
        # Why: §53 -- a promotion is not done until it is verified.
        # From: Issue #1683
        ci_readback_verify "${ref}:${channel}" "$digest" || return 1
    done < "$candidate"

    ci_log "promoted $(wc -l < "$candidate") service(s) to channel $channel"
}

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# NIGHTLY / RELEASE
# ============================================================
#
# What: resolve a desired stack, then promote it.
# Why: nightly never means rebuilding everything.
# From: Issue #1683

ci_nightly_is_current() {
    # What: true iff the desired stack equals the live channel $1.
    # Why: §54.2 -- unchanged means no build, no retag.
    # From: Issue #1683
    local channel="$1" svc identity desired live ref
    for svc in "${CI_SERVICES[@]}"; do
        identity="$(ci_build_identity "$svc" "${CI_STACK_PLATFORM:-linux/amd64}")"
        desired="$(ci_ledger_lookup "$svc" "${CI_STACK_PLATFORM:-linux/amd64}" "$identity" 2>/dev/null)" || return 1
        ref="$(ci_image_ref "$svc")"
        live="$(ci_registry_digest "${ref}:${channel}" 2>/dev/null)" || return 1
        [[ "$desired" == "$live" ]] || return 1
    done
    return 0
}

ci_cmd_nightly() {
    # What: promotes the desired stack, or does nothing.
    # Why: §54.1 -- targeted work only, never a scheduled rebuild.
    # From: Issue #1683
    local channel="${CI_NIGHTLY_CHANNEL:-nightly}"
    if ci_nightly_is_current "$channel"; then
        ci_log "nightly: desired stack already live on '$channel'; no build, no retag"
        return 0
    fi
    local candidate
    candidate="$(ci_mktemp)"
    if ! ci_stack_candidate > "$candidate"; then
        ci_rm_temp "$candidate"
        ci_die "nightly: stack incomplete; promotion blocked (§50)"
    fi
    ci_promote_channel "$candidate" "$channel"
    ci_rm_temp "$candidate"
}

ci_cmd_release() {
    # What: promotes an accepted stack to channel $1.
    # Why: §56 -- build once, promote many; never build.
    # From: Issue #1683
    local channel="${1:?ci.sh release: channel is required}"
    local candidate
    candidate="$(ci_mktemp)"
    if ! ci_stack_candidate > "$candidate"; then
        ci_rm_temp "$candidate"
        ci_die "release: no fully accepted candidate exists; refusing to build during release (§51)"
    fi
    ci_promote_channel "$candidate" "$channel"
    ci_rm_temp "$candidate"
}

# ============================================================
# STANDING CHECKS
# ============================================================
#
# What: one call site for every kept repo-wide guard script.
# Why: consolidates 9 separate build-push.yml docker-run steps.
# From: Issue #1683

# What: kept guards with no explicit-file mode; run whole-repo.
# Why: each is diff-scoped internally or is inherently repo-wide.
# From: Issue #1683
readonly -a CI_STANDING_CHECKS=(
    scripts/untracked/validate-stack-images.sh
    scripts/tracked/check-naming-consistency.sh
    scripts/tracked/check-workflow-service-lists.sh
    scripts/tracked/check-vex-drift.sh
    scripts/untracked/check-netdata-curl-pin.sh
    scripts/tracked/check-idempotence-test-coverage.sh
    scripts/tracked/check-bats-path-filter-coverage.sh
    scripts/tracked/check-setup-prompt-drift.sh
    scripts/untracked/check-proxy-cache-env-doc-drift.sh
    scripts/tracked/check-logging-matrix.sh
)

# What: file-headers/-hosted's 6-script list, kept separate.
# Why: merging into CI_STANDING_CHECKS would run them twice.
# From: Issue #1683
readonly -a CI_FILE_HEADER_CHECKS=(
    scripts/tracked/check-file-headers.sh
    scripts/untracked/check-workflow-line-limit.sh
    scripts/untracked/check-review-chronology-comments.sh
    scripts/tracked/check-dependabot-docker-base-consistency.sh
    scripts/untracked/check-trivy-action-direct-usage.sh
    scripts/untracked/check-deny-short-sha.sh
)

# What: per-script env override the check loop can't infer.
# Why: chronology warn/block split is per-event, not per-file.
# From: Issue #1683
ci_standing_check_env() {
    local name="$1"
    case "$name" in
        check-review-chronology-comments.sh)
            if [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
                printf 'CHRONOLOGY_WARN_ONLY=1\n'
            else
                printf 'CHRONOLOGY_WARN_ONLY=0\n'
            fi
            ;;
    esac
}

ci_run_check_list() {
    # What: runs each script argument, sharing collected failures.
    # Why: one shared loop body instead of one loop per caller.
    # From: Issue #1683
    local script name
    local -a run_env
    for script in "$@"; do
        name="$(basename "$script")"
        if [[ ! -f "$CI_REPO_ROOT/$script" ]]; then
            ci_report_failure "standing check" "$name" "script exists" "missing at $script" \
                "the script moved or was renamed; update the check list"
            continue
        fi
        mapfile -t run_env < <(ci_standing_check_env "$name")
        if ! env "${run_env[@]}" bash "$CI_REPO_ROOT/$script"; then
            ci_report_failure "standing check" "$name" "exit 0" "non-zero" \
                "see this check's own output above for the actual cause"
        fi
    done
}

ci_cmd_file_header_checks() {
    # What: the 6 repo-wide checks file-headers/-hosted both need.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    ci_run_check_list "${CI_FILE_HEADER_CHECKS[@]}"
    ci_failure_summary
}

ci_cmd_compose_healthchecks() {
    # What: the one script compose-healthchecks/-hosted both need.
    # Why: no build-tools container -- a plain bash/grep scan.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-compose-healthchecks.sh"
}

ci_cmd_line_endings_check() {
    # What: the one script line-endings/-hosted both need.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-line-endings.sh"
}

ci_cmd_language_policy_check() {
    # What: the one script language-policy/-hosted both need.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-language-policy.sh"
}

ci_cmd_setup_migration_check() {
    # What: shellcheck-hosted's setup-migration-semantics test.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/tests/setup-migration-semantics.sh"
}

ci_cmd_action_node_versions_check() {
    # What: shellcheck-hosted's action-node-versions guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-action-node-versions.sh"
}

ci_cmd_validation_subnet_check() {
    # What: shellcheck-hosted's validation-subnet-wrapper guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-validation-subnet-wrapper-coverage.sh"
}

ci_cmd_executable_bits_check() {
    # What: shellcheck-hosted's executable-bits guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-executable-bits.sh"
}

ci_cmd_build_tools_smoke_coverage_check() {
    # What: shellcheck-hosted's smoke-coverage guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-build-tools-smoke-coverage.sh"
}

ci_cmd_pipefail_early_exit_check() {
    # What: shellcheck-hosted's pipefail-early-exit guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/untracked/check-pipefail-early-exit-grep.sh"
}

ci_cmd_pipefail_scope_check() {
    # What: shellcheck-hosted's pipefail-scope-coverage guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-pipefail-scope-coverage.sh"
}

ci_cmd_repository_case_check() {
    # What: shellcheck-hosted's repository-case-only guard.
    # Why: §72 -- same function, same decision, either runner.
    # From: Issue #1683
    bash "$CI_REPO_ROOT/scripts/tracked/check-mutable-refs.sh" --only repository-case
}

ci_compose_config_clean() {
    # What: true iff "docker compose $* config" is warning-free.
    # Why: a silent compose warning today is a real bug tomorrow.
    # From: Issue #1683
    local output
    if ! output="$(docker compose "$@" config --quiet 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    # What: here-string, not printf | grep -q.
    # Why: grep -q's early exit can SIGPIPE the producer under -e.
    if grep -Eqi '(^|[[:space:]])(warn|warning|level=warning)' <<<"$output"; then
        printf 'compose warnings treated as errors:\n%s\n' "$output" >&2
        return 1
    fi
    return 0
}

ci_check_compose_files() {
    # What: renders every real compose file/profile combination.
    # Why: profile-less renders skip inactive profiles entirely.
    # From: Issue #1683
    local compose_file
    ci_compose_config_clean -f deploy/quickstart/docker-compose.yml --profile ssl \
        || ci_report_failure "compose config" "quickstart (ssl)" "clean" "warnings/errors" "fix the reported compose issue"
    ci_compose_config_clean -f deploy/prod/docker-compose.yml \
        || ci_report_failure "compose config" "prod" "clean" "warnings/errors" "fix the reported compose issue"
    ci_compose_config_clean -f deploy/secondary/docker-compose.yml \
        || ci_report_failure "compose config" "secondary" "clean" "warnings/errors" "fix the reported compose issue"
    ci_compose_config_clean --env-file deploy/quickstart/.env -f deploy/quickstart/docker-compose.yml --profile ssl \
        || ci_report_failure "compose config" "quickstart (.env, ssl)" "clean" "warnings/errors" "fix the reported compose issue"

    for compose_file in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
        ci_compose_config_clean -f "$compose_file" --profile dhcp-kea \
            || ci_report_failure "compose config" "$compose_file (dhcp-kea)" "clean" "warnings/errors" "fix the reported compose issue"
        ci_compose_config_clean -f "$compose_file" --profile dhcp-proxy \
            || ci_report_failure "compose config" "$compose_file (dhcp-proxy)" "clean" "warnings/errors" "fix the reported compose issue"
        ci_compose_config_clean -f "$compose_file" --profile logging \
            || ci_report_failure "compose config" "$compose_file (logging)" "clean" "warnings/errors" "fix the reported compose issue"
    done
}

ci_cmd_diff_checks() {
    # What: runs the two PR-diff-scoped header/chronology checks.
    # Why: §72 -- one shared call site for both runner variants.
    # From: Issue #1683
    local base_sha="${1:?ci.sh diff-checks: base sha is required}"
    local base_ref="${2:?ci.sh diff-checks: base ref is required}"

    # What: both scripts run `git fetch`, so need a writable tree.
    # Why: matches the caller's :ro-mount-then-copy convention.
    # From: Issue #1683
    local start_dir
    start_dir="$(pwd)"
    cd "$CI_REPO_ROOT"

    if ! SPDX_BASE_SHA="$base_sha" SPDX_BASE_REF="$base_ref" GITHUB_SHA="${GITHUB_SHA:-HEAD}" \
        bash "$CI_REPO_ROOT/scripts/tracked/check-pr-diff-file-headers.sh"; then
        ci_report_failure "diff check" "check-pr-diff-file-headers.sh" "exit 0" "non-zero" \
            "see this check's own output above for the actual cause"
    fi

    if ! CHRONOLOGY_DIFF_BASE_SHA="$base_sha" CHRONOLOGY_DIFF_BASE_REF="$base_ref" GITHUB_SHA="${GITHUB_SHA:-HEAD}" \
        bash "$CI_REPO_ROOT/scripts/untracked/check-review-chronology-comments.sh"; then
        ci_report_failure "diff check" "check-review-chronology-comments.sh (diff-scoped)" "exit 0" "non-zero" \
            "see this check's own output above for the actual cause"
    fi

    cd "$start_dir"
    ci_failure_summary
}

ci_cmd_checks() {
    # What: runs every standing check, reporting all failures.
    # Why: one aggregate verdict instead of 9 separate CI jobs.
    # From: Issue #1683
    ci_run_check_list "${CI_STANDING_CHECKS[@]}"

    # What: no subshell -- ci_report_failure's array must stay shared.
    # Why: a subshell's CI_FAILURES writes never reach the caller.
    # From: Issue #1683
    local start_dir
    start_dir="$(pwd)"
    cd "$CI_REPO_ROOT"
    ci_check_compose_files
    cd "$start_dir"

    ci_failure_summary
}

# ============================================================
# REPO CONTRACT VALIDATION
# ============================================================
#
# What: validate-compose's 9 repo-content contract gates.
# Why: §5 -- these were 983 lines of shell inlined in YAML.
# From: PR #1742 | Refs #1683

ci_cmd_validate_prebuilt_install() {
    # What: asserts prod/quickstart install stays prebuilt-only.
    # Why: a local-build instruction breaks pull-only installs.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    if grep -RInE '^[[:space:]]+build:' deploy/prod deploy/quickstart; then
      echo "::error::Production and quickstart compose files must use prebuilt images only."
      exit 1
    fi

    if grep -RIn -- '--build' README.md deploy/prod deploy/quickstart setup.sh; then
      echo "::error::User-facing production install paths must not instruct users to build images locally."
      exit 1
    fi

    if grep -RIn -- '/srv/lancache' README.md CLAUDE.md deploy/prod deploy/quickstart services/ui/src; then
      echo "::error::Runtime defaults and user-facing install paths must use /opt/lancache-ng, not legacy /srv/lancache."
      exit 1
    fi

    # What: validates the LANCACHE_STATE_DIR + legacy override contract.
    # Why: a bare /srv/lancache dir must never count as legacy state.
    # From: PR #447
    for key in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
      grep -F "set_optional_env_path_override_if_needed ${key}" setup.sh >/dev/null \
        || { echo "::error::setup.sh update must preserve ${key} only when legacy/custom state would otherwise move away from the one-root contract."; exit 1; }
      grep -F "${key}" deploy/prod/.env >/dev/null \
        || { echo "::error::deploy/prod/.env must document ${key} for manual production upgrades."; exit 1; }
      grep -F "${key}" docs/backup-restore.md >/dev/null \
        || { echo "::error::backup docs must mention ${key}."; exit 1; }
    done

    grep -F 'LANCACHE_STATE_DIR=/opt/lancache-ng' deploy/prod/.env >/dev/null \
      || { echo "::error::deploy/prod/.env must expose one production state root for manual upgrade paths."; exit 1; }
    grep -F 'set_env_key_if_empty_or_missing LANCACHE_STATE_DIR' setup.sh >/dev/null \
      || { echo "::error::setup.sh update must write LANCACHE_STATE_DIR before per-service state keys."; exit 1; }
    grep -F 'production_state_root_default()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must keep a state-root default helper for setup installs and manual deploy/prod updates."; exit 1; }
    grep -F 'legacy_state_root_or_default()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must only select legacy /srv/lancache when known child state still exists."; exit 1; }
    grep -F 'basename "$(dirname "$install_dir")")" = "deploy"' setup.sh >/dev/null \
      || { echo "::error::setup.sh deploy/prod updates must default runtime state to /opt/lancache-ng, not the checkout."; exit 1; }
    grep -F 'install_dir=$(realpath -m "$install_dir")' setup.sh >/dev/null \
      || { echo "::error::setup.sh update must normalize install_dir before cd so deploy/prod backups are path-stable."; exit 1; }
    # What: snapshots repo-root inputs via ../../, remaps on restore.
    # Why: manual deploy/prod rollback must preserve arbitrary paths.
    # From: PR #447
    grep -F 'deploy_prod_repo_input_paths()' setup.sh >/dev/null \
      || { echo "::error::deploy/prod backups must snapshot repo-root runtime inputs reached via ../../ paths."; exit 1; }
    grep -F 'config/prod' setup.sh >/dev/null \
      && grep -F 'services/dns/cdn-domains.txt' setup.sh >/dev/null \
      || { echo "::error::deploy/prod backups must include repo-root config/prod env files and the domain list."; exit 1; }
    grep -F 'scripts/untracked/docker-socket-proxy.sh' setup.sh >/dev/null \
      || { echo "::error::deploy/prod backups must include the repo-root scripts/untracked/docker-socket-proxy.sh bind-mount input (see docs/naming-conventions.md)."; exit 1; }
    grep -F 'deploy_prod_repo_root "$archived_install"' setup.sh >/dev/null \
      && grep -F 'deploy_prod_repo_root "$install_dir"' setup.sh >/dev/null \
      || { echo "::error::deploy/prod restore must remap repo-root snapshot entries to the new checkout path."; exit 1; }
    grep -F 'sudo ./setup.sh update "$(pwd)/deploy/prod"' README.md >/dev/null \
      || { echo "::error::README manual production updates must pass deploy/prod explicitly to setup.sh update."; exit 1; }
    grep -F 'deploy/prod/.env.local' .gitignore >/dev/null \
      || { echo "::error::Manual deploy/prod runtime env must be ignored as deploy/prod/.env.local."; exit 1; }
    grep -F 'runtime_env_file_for_install_dir()' setup.sh >/dev/null \
      && grep -F 'is_deploy_prod_install_dir "$install_dir"' setup.sh >/dev/null \
      && grep -F '$install_dir/.env.local' setup.sh >/dev/null \
      || { echo "::error::setup.sh must prefer deploy/prod/.env.local as the active manual prod runtime env when present."; exit 1; }
    grep -F 'cp deploy/prod/.env deploy/prod/.env.local' README.md >/dev/null \
      && grep -F 'docker compose --env-file deploy/prod/.env.local -f deploy/prod/docker-compose.yml' README.md >/dev/null \
      || { echo "::error::README manual production flow must keep deploy/prod/.env as a clean template and run compose with deploy/prod/.env.local."; exit 1; }
    if awk '
      /sudo \.\/setup\.sh backup --config "\$\(pwd\)\/deploy\/prod"/ { backup_seen=1 }
      /git pull --ff-only/ && !backup_seen { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' README.md; then
      echo "::error::README manual production updates must create a config backup before git pull changes tracked files."
      exit 1
    fi
    grep -F '${LANCACHE_STATE_DIR:-/opt/lancache-ng}/pdns-standard' deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::prod compose must derive PowerDNS state from LANCACHE_STATE_DIR when no per-service override is set."; exit 1; }
    grep -F '${LANCACHE_STATE_DIR:-/opt/lancache-ng}/nats-conf' deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::prod compose must derive NATS config state from LANCACHE_STATE_DIR when no per-service override is set."; exit 1; }
    grep -F 'LANCACHE_STATE_DIR' docs/backup-restore.md >/dev/null \
      || { echo "::error::backup docs must describe LANCACHE_STATE_DIR coverage."; exit 1; }
    grep -F 'legacy_dir_or_default "$(legacy_state_path cache)"' setup.sh >/dev/null \
      || { echo "::error::setup.sh update must preserve an existing legacy /srv/lancache/cache before changing cache defaults."; exit 1; }
    grep -F 'pdns_filter_state_dir=$(get_env_var PDNS_FILTER_STATE_DIR "$env_file")' setup.sh >/dev/null \
      || { echo "::error::backup_manifest must read PDNS_FILTER_STATE_DIR."; exit 1; }
    grep -F 'nats_conf_dir=$(get_env_var NATS_CONF_DIR "$env_file")' setup.sh >/dev/null \
      || { echo "::error::backup_manifest must read NATS_CONF_DIR."; exit 1; }
}

ci_cmd_validate_nats_socket_proxy() {
    # What: asserts NATS atomic-write + socket-proxy contracts.
    # Why: a widened socket allowlist is a real privilege gap.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    validate_nats_config_ownership() {
      local path

      for path in \
        deploy/prod/docker-compose.yml \
        deploy/quickstart/docker-compose.yml
      do
        grep -Fq 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"' "$path" \
          || {
            printf '::error file=%s::NATS must stage the shared config in a temp file inside /etc/nats.\n' "$path"
            return 1
          }
        grep -Fq 'chown 10001:10001 "$$tmp_nats_conf"' "$path" \
          || {
            printf '::error file=%s::NATS must restore shared config ownership to UID/GID 10001 after writing.\n' "$path"
            return 1
          }
        grep -Fq 'mv "$$tmp_nats_conf" /etc/nats/nats.conf' "$path" \
          || {
            printf '::error file=%s::NATS must atomically replace the shared nats.conf after fixing ownership.\n' "$path"
            return 1
          }
      done
    }

    validate_nats_config_ownership
    grep -Fq 'fn write_nats_conf_atomically(' services/ui/src/routes/secondaries.rs \
      || { echo "::error::Admin UI must keep an atomic nats.conf write helper for the v0.1.0 shared-token path."; exit 1; }
    grep -Fq 'fs::rename(&tmp_path, target)' services/ui/src/routes/secondaries.rs \
      || { echo "::error::Admin UI nats.conf writes must use temp-file plus rename, not direct overwrite."; exit 1; }

    grep -Fq 'render_template_atomic' services/dns/entrypoint.sh \
      || { echo "::error::DNS entrypoint must render generated configs through the atomic helper."; exit 1; }
    grep -Fq 'mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"' services/dns/entrypoint.sh \
      || { echo "::error::DNS entrypoint generated configs must stage temp files in the target directory."; exit 1; }
    if grep -Fq '> /tmp/recursor.conf' services/dns/entrypoint.sh \
      || grep -Fq '> /tmp/pdns.conf' services/dns/entrypoint.sh; then  # pipefail-safe: '||' is logical OR, not a pipe; grep reads a file arg
      echo "::error::DNS entrypoint must not render PDNS configs through /tmp before replacing target configs."
      exit 1
    fi
    if grep -Fq "sed -i 's/^  loglevel: 3$/  loglevel: 6/' /etc/pdns/recursor.conf" services/dns/entrypoint.sh; then
      echo "::error::DNS query logging must be applied to the staged recursor.conf before replacement."
      exit 1
    fi
    grep -Fq 'write_generated_runtime_file "${secondary_dir}/docker-compose.yml"' setup.sh \
      || { echo "::error::Secondary setup must atomically write generated docker-compose.yml."; exit 1; }
    grep -Fq 'write_env_file "${secondary_dir}/.env"' setup.sh \
      || { echo "::error::Secondary setup must use the safe env writer for generated .env files."; exit 1; }

    if grep -F 'EXEC: "1"' deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml >/dev/null; then
      echo "::error::Docker exec is banned from the Admin UI/watchdog proxy for security reasons; use predeclared container actions instead."
      exit 1
    fi
    if grep -E '^[[:space:]]*(CONTAINERS|POST): "1"' deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml >/dev/null; then
      echo "::error::Broad CONTAINERS=1/POST=1 exposes generic Docker container APIs; use the explicit HAProxy allowlist instead."
      exit 1
    fi
    # What: validates the single real docker-socket-proxy.sh allowlist.
    # Why: a dead duplicate anchor copy was removed already.
    # From: PR #635
    socket_proxy_script="scripts/untracked/docker-socket-proxy.sh"
    grep -Fq 'acl safe_service_restart' "$socket_proxy_script" \
      && grep -Fq 'acl safe_dhcp_action' "$socket_proxy_script" \
      && grep -Fq 'acl safe_probe_action' "$socket_proxy_script" \
      && grep -Fq 'acl safe_netdata_restart' "$socket_proxy_script" \
      && grep -Fq 'lancache-netdata/restart' "$socket_proxy_script" \
      && grep -Fq 'acl lancache_container' "$socket_proxy_script" \
      && grep -Fq 'lancache-dns-standard|lancache-dns-ssl' "$socket_proxy_script" \
      && grep -Fq 'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart' "$socket_proxy_script" \
      && grep -Fq 'lancache-dhcp|lancache-dhcp-proxy)/(start|stop)' "$socket_proxy_script" \
      && grep -Fq 'lancache-dhcp-probe/(start|stop|wait)' "$socket_proxy_script" \
      && ! grep -Fq 'lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-dhcp|lancache-dhcp-proxy|lancache-dhcp-probe|lancache-nats)/(start|stop|restart|wait)' "$socket_proxy_script" \
      && grep -Fq 'http-request deny if docker_container_path !lancache_container' "$socket_proxy_script" \
      && grep -Fq 'http-request deny' "$socket_proxy_script" \
      && ! grep -Fq '/containers/create' "$socket_proxy_script" \
      && ! grep -Fq '/containers/json' "$socket_proxy_script" \
      && ! grep -Fq '[A-Za-z0-9_.-]+/(start|stop|restart|attach)' "$socket_proxy_script" \
      || {
        echo "::error file=${socket_proxy_script}::Docker socket proxy must deny generic container listing/creation and only allow explicit project container actions; stop/start/wait are restricted to the DHCP probe."
        exit 1
      }

    for compose_file in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
      # What: anchored on the full source path, not just the mount target.
      # Why: Docker creates an empty dir for a stale bind-mount source.
      # From: Issue #1095 | PR #1532
      grep -Fq 'scripts/untracked/docker-socket-proxy.sh:/usr/local/bin/lancache-docker-socket-proxy.sh:ro' "$compose_file" \
        || {
          echo "::error file=${compose_file}::docker-socket-proxy service must mount the one real scripts/untracked/docker-socket-proxy.sh, not an inline, divergent, or stale pre-move copy."
          exit 1
        }
      # What: matches only the real YAML key/anchor, not any occurrence.
      # Why: a comment above mentions this name in prose already.
      # From: PR #635
      grep -Eq '^x-docker-socket-proxy-command:' "$compose_file" \
        && {
          echo "::error file=${compose_file}::The dead x-docker-socket-proxy-command anchor must not be reintroduced; it duplicated scripts/untracked/docker-socket-proxy.sh without ever being referenced."
          exit 1
        }
      true
    done

    missing_required=0
    while IFS= read -r key; do
      if ! grep -Eq "^${key}=[^[:space:]]+" deploy/quickstart/.env; then
        echo "::error::deploy/quickstart/.env must define non-empty ${key} because quickstart compose marks it required."
        missing_required=1
      fi
    done < <(
      grep -oE '\$\{[A-Za-z0-9_]+:\?[^}]+\}' deploy/quickstart/docker-compose.yml \
        | sed -E 's/^\$\{([^:]+):.*/\1/' \
        | sort -u
    )
    if [[ "$missing_required" = "1" ]]; then
      exit 1
    fi

}

ci_cmd_validate_dhcp_proxy_env() {
    # What: asserts dhcp-proxy env-file and PXE contracts.
    # Why: a dropped env key silently disables PXE booting.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    validate_dhcp_proxy_env_file_contract() {
      local compose_file="$1"
      local expected_env_file="$2"

      awk -v compose_file="$compose_file" -v expected_env_file="$expected_env_file" '
        function trim(value) {
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          return value
        }
        function content_indent(value, prefix) {
          match(value, /^[[:space:]]*/)
          prefix = substr(value, 1, RLENGTH)
          return length(prefix)
        }
        function strip_inline_comment(value) {
          sub(/[[:space:]]+#.*/, "", value)
          return value
        }
        /^  dhcp-proxy:/ {
          in_service=1
          saw_service=1
          in_env_file_block=0
          next
        }
        in_service && /^  [[:alnum:]_-]+:/ {
          in_service=0
          in_env_file_block=0
        }
        in_service {
          line=strip_inline_comment($0)
          stripped=trim(line)

          if (in_env_file_block && stripped != "" && content_indent(line) <= env_file_indent) {
            in_env_file_block=0
          }
          if (in_env_file_block && stripped ~ /^-/ && index(stripped, expected_env_file) > 0) {
            saw_env_file=1
          }

          if (line ~ /^[[:space:]]*env_file:[[:space:]]*$/) {
            in_env_file_block=1
            env_file_indent=content_indent(line)
          } else if (line ~ /^[[:space:]]*env_file:[[:space:]]*/ && index(line, expected_env_file) > 0) {
            saw_env_file=1
          }

          if (line ~ /^[[:space:]]*environment:[[:space:]]*/) {
            saw_environment=1
          }
          if (stripped ~ /^-[[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP)=\$\{/ || stripped ~ /[{,][[:space:]]*(DHCP_SUBNET_START|DHCP_DNS_PRIMARY|DHCP_DNS_SECONDARY|UPSTREAM_DHCP_IP):[[:space:]]*"\$\{/) {
            saw_interpolated_dhcp_key=1
          }
        }
        END {
          if (!saw_service) {
            printf "::error file=%s::dhcp-proxy service is missing.\n", compose_file
            exit 1
          }
          if (!saw_env_file) {
            printf "::error file=%s::dhcp-proxy must keep using env_file %s so setup-managed dnsmasq-proxy values are not lost.\n", compose_file, expected_env_file
            exit 1
          }
          if (saw_environment || saw_interpolated_dhcp_key) {
            printf "::error file=%s::dhcp-proxy must not reintroduce Compose environment interpolation for dnsmasq-proxy values; env_file is the contract for prod.\n", compose_file
            exit 1
          }
        }
      ' "$compose_file"
    }

    # What: runs the env_file-contract check for prod dhcp-proxy only.
    # Why: explicit env entries would silently erase DHCP settings.
    # From: PR #472
    validate_dhcp_proxy_env_file_contract deploy/prod/docker-compose.yml ../../config/prod/dhcp-proxy.env

    # What: guards the dnsmasq optional-option surface end to end.
    # Why: prevents any layer from silently dropping these keys.
    # From: PR #643
    dhcp_proxy_optional_keys=(
      DHCP_PROXY_INTERFACE
      DHCP_PROXY_ROUTER
      DHCP_NTP_SERVERS
      DHCP_PROXY_DOMAIN
      DHCP_PROXY_BOOT_FILENAME
      DHCP_PROXY_BOOT_SERVER
      DHCP_PROXY_CUSTOM_OPTIONS
    )
    for env_file in config/prod/dhcp-proxy.env deploy/quickstart/.env; do
      for key in "${dhcp_proxy_optional_keys[@]}"; do
        grep -Eq "^${key}=" "$env_file" \
          || { echo "::error file=${env_file}::${env_file} must define ${key} (empty by default) for the dnsmasq relay/proxy optional-option surface added by issue #450."; exit 1; }
      done
    done
    grep -F 'DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE:-}' deploy/quickstart/docker-compose.yml >/dev/null \
      || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through DHCP_PROXY_INTERFACE like the other optional dnsmasq relay/proxy keys."; exit 1; }
    grep -F 'DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS:-}' deploy/quickstart/docker-compose.yml >/dev/null \
      || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through DHCP_PROXY_CUSTOM_OPTIONS like the other optional dnsmasq relay/proxy keys."; exit 1; }

    # What: guards the PXE opt-in surface, incl. Compose passthrough.
    # Why: a missing Compose allowlist entry leaves a feature unreachable.
    # From: PR #765
    dhcp_proxy_pxe_keys=(
      DHCP_PROXY_PXE_BOOT_SERVER
      DHCP_PROXY_PXE_BOOT_FILENAME_BIOS
      DHCP_PROXY_PXE_BOOT_FILENAME_UEFI
    )
    for env_file in config/prod/dhcp-proxy.env deploy/quickstart/.env; do
      for key in "${dhcp_proxy_pxe_keys[@]}"; do
        grep -Eq "^${key}=" "$env_file" \
          || { echo "::error file=${env_file}::${env_file} must define ${key} (empty by default) for the PXE boot-pointer opt-in surface added by issue #705."; exit 1; }
      done
    done
    for key in "${dhcp_proxy_pxe_keys[@]}"; do
      grep -F "${key}=\${${key}:-}" deploy/quickstart/docker-compose.yml >/dev/null \
        || { echo "::error::deploy/quickstart/docker-compose.yml's dhcp-proxy service must pass through ${key} like the other optional dnsmasq relay/proxy keys."; exit 1; }
    done

    grep -F '_dhcp_proxy_render_optional_directives()' services/dhcp-proxy/entrypoint.sh >/dev/null \
      || { echo "::error::services/dhcp-proxy/entrypoint.sh must render the issue #450 optional dnsmasq relay/proxy directives."; exit 1; }
    grep -F '_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf' services/dhcp-proxy/entrypoint.sh >/dev/null \
      || { echo "::error::services/dhcp-proxy/entrypoint.sh must call _dhcp_proxy_render_optional_directives before validating dnsmasq.conf."; exit 1; }
    if grep -F 'dhcp-proxy=${UPSTREAM_DHCP_IP}' services/dhcp-proxy/dnsmasq.conf.template >/dev/null; then
      echo "::error::services/dhcp-proxy/dnsmasq.conf.template must not reintroduce 'dhcp-proxy=\${UPSTREAM_DHCP_IP}': that flag means \"treat these DHCP-relay agents as full proxies\" (RFC 5107), it does nothing without --dhcp-relay=, and this service never configures one. Confirmed against a live dnsmasq --help/--test; see docs/dhcp-modes.md."
      exit 1
    fi

}

ci_cmd_validate_setup_keys_kea() {
    # What: asserts setup.sh required keys and Kea preflight.
    # Why: a missing key fails at runtime, not at install time.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    if grep -RInE '^(NATS_LOCAL_TOKEN|NATS_TOKEN)=' deploy/quickstart/.env deploy/prod/.env 2>/dev/null; then
      echo "::error::Quickstart/prod env templates must not use deprecated NATS token keys; use role credentials instead."
      exit 1
    fi

    setup_required_keys=(
      DDNS_TSIG_KEY
      KEA_CTRL_TOKEN
      LANCACHE_IMAGE_TAG
      NATS_DNS_REPLICA_PASSWORD
      NATS_DNS_REPLICA_USER
      NATS_DNS_WRITER_PASSWORD
      NATS_DNS_WRITER_USER
      NATS_CALLOUT_PASSWORD
      NATS_CALLOUT_USER
      NATS_SYS_PASSWORD
      NATS_SYS_USER
      NATS_UI_PASSWORD
      NATS_UI_USER
      PDNS_API_KEY
      SECONDARY_REGISTRATION_TOKEN
    )
    for key in "${setup_required_keys[@]}"; do
      grep -F "$key" setup.sh >/dev/null \
        || { echo "::error::setup.sh must generate or migrate required runtime key ${key}."; exit 1; }
    done

    grep -F 'run_kea_dhcp_activation_preflight()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must define a DHCP discovery preflight before Kea activation."; exit 1; }
    grep -F 'run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"' setup.sh >/dev/null \
      || { echo "::error::setup.sh must call the Kea discovery preflight before starting the stack."; exit 1; }
    grep -F 'nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5' setup.sh >/dev/null \
      || { echo "::error::setup.sh must probe DHCP discovery with the Kea image before activation."; exit 1; }
    if grep -F 'nmap --script broadcast-dhcp-discover -e any' setup.sh >/dev/null; then
      echo "::error::setup.sh must not pass -e any to nmap; that is not a valid nmap interface and makes the preflight fail its own execution on every run."
      exit 1
    fi
    grep -F 'nmap' services/dhcp/Dockerfile >/dev/null \
      || { echo "::error::services/dhcp/Dockerfile must install nmap for the Kea discovery preflight."; exit 1; }
    grep -F 'nmap|/usr/bin/nmap|/bin/nmap)' services/dhcp/entrypoint.sh >/dev/null \
      || { echo "::error::services/dhcp/entrypoint.sh must pass through the nmap preflight command without starting Kea."; exit 1; }
}

ci_cmd_validate_setup_update_migration() {
    # What: asserts setup.sh update-migration stays safe.
    # Why: AG-OP-006: a repeat update must not rotate secrets.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    setup_update_required_repairs=(
      CACHE_INACTIVE
      CACHE_MAX_GB
      CACHE_MAX_SIZE
      CACHE_MEM_MB
      CACHE_SLICE_SIZE
      CACHE_VALID_ANY
      CACHE_VALID_HIT
      DDNS_TSIG_KEY
      KEA_CTRL_TOKEN
      LANCACHE_IMAGE_CHANNEL
      LANCACHE_IMAGE_PREFIX
      LANCACHE_IMAGE_REGISTRY
      LANCACHE_IMAGE_TAG
      NATS_DNS_REPLICA_PASSWORD
      NATS_DNS_REPLICA_USER
      NATS_DNS_WRITER_PASSWORD
      NATS_DNS_WRITER_USER
      NATS_CALLOUT_PASSWORD
      NATS_CALLOUT_USER
      NATS_SYS_PASSWORD
      NATS_SYS_USER
      NATS_UI_PASSWORD
      NATS_UI_USER
      NGINX_UPSTREAM_RESOLVER
      PDNS_API_KEY
      PROXY_SECURITY_MODE
      SSL_ENABLED
      SECONDARY_REGISTRATION_TOKEN
    )
    for key in "${setup_update_required_repairs[@]}"; do
      if awk -v key="$key" '
        /^migrate_env_for_update\(\)/ { in_func=1; next }
        in_func && /^}/ { in_func=0 }
        in_func && $0 ~ "append_env_key_if_missing[[:space:]]+" key "([[:space:]]|$)" { found=1 }
        END { exit found ? 0 : 1 }
      ' setup.sh; then
        echo "::error::setup.sh update must not preserve empty required ${key} values with append_env_key_if_missing."
        exit 1
      fi
      awk -v key="$key" '
        /^migrate_env_for_update\(\)/ { in_func=1; next }
        in_func && /^}/ { in_func=0 }
        in_func && $0 ~ "(set_env_key_if_empty_or_missing|set_env_key|ensure_secret_env_key|append_required_env_migrated_assignment_if_empty_or_missing)[[:space:]]+" key "([[:space:]]|$)" { found=1 }
        END { exit found ? 0 : 1 }
      ' setup.sh \
        || { echo "::error::setup.sh update must repair empty or missing required ${key} values."; exit 1; }
    done
    grep -F 'get_env_var_nonempty()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must provide a helper that finds non-empty duplicate env values before repairing required keys."; exit 1; }
    grep -F 'get_env_assignment_value_raw_nonempty()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must provide a helper that preserves the raw assignment for a non-empty duplicate env value."; exit 1; }
    grep -F 'existing_assignment=$(get_env_assignment_value_raw_nonempty "$key" "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Required-key repair must preserve the raw non-empty assignment before writing a fallback."; exit 1; }
    grep -F 'source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Migrated assignments must preserve raw non-empty source values before writing a fallback."; exit 1; }
    grep -F 'cache_max_gb=$(get_env_var_nonempty CACHE_MAX_GB "$env_file")' setup.sh >/dev/null \
      || { echo "::error::CACHE_MAX_SIZE repair must derive from existing CACHE_MAX_GB before falling back to the default."; exit 1; }
    if ! awk '
      /^set_env_key\(\) \{/ { in_func=1; seen_next=0; next }
      in_func && /^}/ { exit seen_next ? 0 : 1 }
      in_func && /\$1 == key \{/ { in_key=1 }
      in_func && in_key && /if \(!seen\)/ { seen_next=1 }
    ' setup.sh; then
      echo "::error::set_env_key must collapse duplicate assignments instead of rewriting every duplicate key."
      exit 1
    fi
    grep -F 'validate_ui_session_ttl_seconds()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must validate UI_SESSION_TTL_SECONDS before writing or reusing it."; exit 1; }
    grep -F 'validate_ui_session_ttl_seconds "$ui_session_ttl" "$env_file"' setup.sh >/dev/null \
      || { echo "::error::setup.sh update must validate preserved UI_SESSION_TTL_SECONDS before mutating or restarting the stack."; exit 1; }
    grep -F 'validate_ui_session_ttl_seconds "$UI_SESSION_TTL_SECONDS" "$env_file"' setup.sh >/dev/null \
      || { echo "::error::setup.sh install must validate UI_SESSION_TTL_SECONDS before writing the runtime .env."; exit 1; }

    if awk '
      /^  release:/ { in_release=1; next }
      in_release && /^  [[:alnum:]_-]+:/ { in_release=0 }
      in_release && /build-tools:latest/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' .github/workflows/build-push.yml; then
      echo "::error::Release jobs with write permissions must use the tag-scoped build-tools image, not mutable latest."
      exit 1
    fi
    forbidden_latest_default_branch='type=raw,value=latest,enable={{is_default'
    forbidden_latest_default_branch="${forbidden_latest_default_branch}_branch}}"
    if grep -Fq "$forbidden_latest_default_branch" .github/workflows/build-push.yml; then
      echo "::error::Default branch builds must not publish latest via an unaudited build-time tag (docker/metadata-action's is_default_branch auto-tag); latest may only move through the gated promote job."
      exit 1
    fi
    grep -F 'channel_tags+=(latest)' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Stable release promotion must publish the latest channel."; exit 1; }
    grep -F 'elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Stable release promotion must only move latest for exact vX.Y.Z tags."; exit 1; }
    grep -F 'if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Release candidate promotion must only accept exact vX.Y.Z-rc.N tags."; exit 1; }
    grep -F 'docker buildx imagetools inspect "$source_image"' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Promotion must verify every source sha-* image before moving channel tags."; exit 1; }
    grep -F 'needs: promote' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Release notes must run after channel promotion."; exit 1; }

    # What: only prerelease is protected here, not draft.
    # Why: draft:false is always safe to force; must not trip this guard.
    # From: Issue #1095 | PR #1532
    if awk '
      /if \[ "\$status" = "200" \]/ { in_patch=1 }
      /elif \[ "\$status" = "404" \]/ { in_patch=0 }
      in_patch && /prerelease[[:space:]]*:[[:space:]]*false/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' .github/workflows/build-push.yml; then
      echo "::error::Existing release PATCH must preserve prerelease state."
      exit 1
    fi

    if awk '
      /This script must be run as root/ { after_root=1 }
      after_root && /assert_prebuilt_image_platform_supported/ { guard_seen=1 }
      after_root && !guard_seen && /(install_docker|systemctl enable --now docker)/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' setup.sh; then
      echo "::error::Prebuilt platform guard must run before Docker install or daemon startup."
      exit 1
    fi

    if awk '
      /^cmd_update\(\) \{/ { in_update=1; pause_seen=0; next }
      /^# .*debug subcommand/ { in_update=0 }
      in_update && /pause_lancache_convergence_for_update/ { pause_seen=1 }
      in_update && !pause_seen && !/^[[:space:]]*#/ && /(cmd_backup|git -C|cp "\$install_dir\/deploy\/quickstart\/docker-compose\.yml"|migrate_env_for_update|validate_compose_config|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+(pull|up))/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' setup.sh; then
      echo "::error::setup.sh update must pause the convergence timer before mutating local install state."
      exit 1
    fi
    grep -F 'systemctl stop lancache-converge.service' setup.sh >/dev/null \
      || { echo "::error::setup.sh update must stop any active convergence service before mutating local install state."; exit 1; }
    if ! awk '
      /if ! \( cmd_backup --config "\$install_dir" \); then/ { in_backup_failure=1; next }
      in_backup_failure && /resume_lancache_convergence_after_update true/ { resume_seen=1 }
      in_backup_failure && /die "Pre-update rollback backup failed/ { die_seen=1; in_backup_failure=0 }
      END { exit resume_seen && die_seen ? 0 : 1 }
    ' setup.sh; then
      echo "::error::setup.sh update must restore the convergence timer when the rollback backup fails before update mutations."
      exit 1
    fi
    if awk '
      /^cmd_update_ip\(\) \{/ { in_update_ip=1; guard_seen=0; next }
      /^# .*backup subcommand/ { in_update_ip=0 }
      in_update_ip && /assert_prebuilt_image_platform_supported/ { guard_seen=1 }
      in_update_ip && !guard_seen && /(sed -i|docker compose -f)/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' setup.sh; then
      echo "::error::setup.sh update-ip must check prebuilt platform support before mutating local configuration."
      exit 1
    fi
}

ci_cmd_validate_accel_policy() {
    # What: asserts container hygiene + Rust accel policy.
    # Why: AG-CI-009: accel must stay dev/CI-only, never prod.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    if awk '
      /^  shellcheck:/ { in_shellcheck=1; next }
      /^  [[:alnum:]_-]+:/ { in_shellcheck=0 }
      in_shellcheck && /^[[:space:]]+container:/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' .github/workflows/build-push.yml; then
      echo "::error::shellcheck job must not checkout inside a root-running job container."
      exit 1
    fi
    grep -F -- "--user \"\$(id -u):\$(id -g)\"" .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::shellcheck container must run with the runner UID/GID."; exit 1; }
    grep -F -- "-v \"\$PWD:/work:ro\"" .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::shellcheck container must mount the workspace read-only."; exit 1; }
    grep -F 'lancache-ng-build-tools-validation:${GITHUB_SHA:-local}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}' scripts/untracked/select-build-tools-image.sh >/dev/null \
      || { echo "::error::Compose validation fallback image tag must be scoped to the workflow run and attempt."; exit 1; }
    grep -F -- "--env DOCKER_CONFIG=/tmp/.docker" .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Compose validation must set a writable Docker config directory inside the build-tools container."; exit 1; }
    grep -F -- "--env HOME=/tmp" .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Compose validation must set a writable HOME inside the build-tools container."; exit 1; }
    # Acceleration-infrastructure policy checks start here.
    # They validate the sccache/distcc contract, not product correctness.
    if grep -RIn 'RUSTC_WRAPPER:[[:space:]]*""' .github/workflows; then
      echo "::error::Acceleration infrastructure checks must not disable RUSTC_WRAPPER directly; use cargo-with-sccache-fallback for controlled fallback."
      exit 1
    fi
    grep -F 'rpm_legacy_docker_package_list()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must keep a shared legacy Docker RPM conflict list."; exit 1; }
    grep -F 'docker-selinux' setup.sh >/dev/null \
      && grep -F 'docker-engine-selinux' setup.sh >/dev/null \
      || { echo "::error::Fedora/RHEL Docker RPM conflict guard must include legacy Docker selinux packages."; exit 1; }
    grep -F 'docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin)' setup.sh >/dev/null \
      || { echo "::error::Installing only docker-compose-plugin on RPM hosts must still run the Docker/Podman conflict guard."; exit 1; }
    if awk '
      /\[\[ "\$os_id" = fedora \]\]/ { in_fedora=1; next }
      /^    else$/ { in_fedora=0 }
      in_fedora && /( podman([[:space:]\\]|$)| runc([[:space:]\\]|$))/ { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' setup.sh; then
      echo "::error::Fedora Docker conflict guard must not block stock podman or runc."
      exit 1
    fi
    if grep -RIn -- 'timeout --foreground' .github/actions/cargo-with-sccache-fallback/action.yml; then
      echo "::error::cargo-with-sccache-fallback must not use timeout --foreground because it can leave Cargo child processes alive and bypass the fallback."
      exit 1
    fi
    for workflow in .github/workflows/build-push.yml .github/workflows/codeql.yml; do
      grep -F 'dist-scheduler-url:' "$workflow" >/dev/null \
        && grep -F 'SCCACHE_DIST_SCHEDULER_URL' "$workflow" >/dev/null \
        || { echo "::error::$workflow must wire SCCACHE_DIST_SCHEDULER_URL into configure-rust-sccache."; exit 1; }
      grep -F 'dist-auth-token:' "$workflow" >/dev/null \
        && grep -F 'SCCACHE_DIST_AUTH_TOKEN' "$workflow" >/dev/null \
        || { echo "::error::$workflow must wire SCCACHE_DIST_AUTH_TOKEN into configure-rust-sccache."; exit 1; }
    done
    grep -F 'sccache_dist_config=' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Docker Rust builds must pass sccache-dist config through a BuildKit secret."; exit 1; }
    grep -F 'distcc_potential_hosts=' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Docker Rust builds must pass distcc hosts through a BuildKit secret."; exit 1; }
    if awk '
      /^      - name: Prepare Rust acceleration secret files$/ { in_block=1; saw_pr_gate=0; next }
      in_block && /^      - name: / {
        if (!saw_pr_gate) {
          print FILENAME ":" FNR ":" "missing pull_request gate in Rust BuildKit secret preparation."
          bad=1
        }
        in_block=0
        next
      }
      in_block && /github.event_name != '\''pull_request'\''/ { saw_pr_gate=1 }
      in_block && /github.event.pull_request.head.repo.full_name == github.repository/ { print FILENAME ":" FNR ":" $0; bad=1 }
      END {
        if (in_block && !saw_pr_gate) bad=1
        exit bad ? 0 : 1
      }
    ' .github/workflows/build-push.yml; then
      echo "::error::Rust Docker builds must not prepare BuildKit secret-files on pull_request runs."
      exit 1
    fi
    grep -F 'uses: ./.github/actions/rust-acceleration-preflight' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Rust acceleration infrastructure checks must run an external preflight outside BuildKit cache."; exit 1; }
    if grep -E '^[[:space:]]+RUST_ACCELERATION_NETWORK:[[:space:]]+host[[:space:]]*$' .github/workflows/build-push.yml >/dev/null; then
      echo "::error::Acceleration infrastructure network must not be globally pinned to host; trusted secret-backed builds select host per job."
      exit 1
    fi
    grep -E '^[[:space:]]+RUST_ACCELERATION_NETWORK:[[:space:]]+bridge[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Acceleration infrastructure network must default to bridge for untrusted and non-accelerated builds."; exit 1; }
    grep -F 'rust_network=bridge' .github/workflows/build-push.yml >/dev/null \
      && grep -F 'buildx_network=default' .github/workflows/build-push.yml >/dev/null \
      && grep -F 'rust_network=host' .github/workflows/build-push.yml >/dev/null \
      && grep -F 'buildx_network=host' .github/workflows/build-push.yml >/dev/null \
      && grep -F 'printf '\''RUST_ACCELERATION_NETWORK=%s\n'\'' "$rust_network" >> "$GITHUB_ENV"' .github/workflows/build-push.yml >/dev/null \
      && grep -F 'printf '\''RUST_BUILDX_NETWORK=%s\n'\'' "$buildx_network" >> "$GITHUB_ENV"' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Acceleration infrastructure network must be selected per job from generated secret files."; exit 1; }
    grep -E '^[[:space:]]+redis-file:[[:space:]]+\$\{\{[[:space:]]*steps\.sccache-secret\.outputs\.redis-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+dist-config-file:[[:space:]]+\$\{\{[[:space:]]*steps\.sccache-secret\.outputs\.dist-config-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+distcc-hosts-file:[[:space:]]+\$\{\{[[:space:]]*matrix\.service[[:space:]]*==[[:space:]]*.build-tools.[[:space:]]*&&[[:space:]]*steps\[.distcc-hosts-secret.\]\.outputs\[.hosts-file.\][[:space:]]*\|\|[[:space:]]*steps\.sccache-secret\.outputs\.distcc-hosts-file[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+build-tools-image:[[:space:]]+\$\{\{[[:space:]]*env\.BUILD_TOOLS_IMAGE[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+build-network:[[:space:]]+\$\{\{[[:space:]]*env\.RUST_ACCELERATION_NETWORK[[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+platform:[[:space:]]+linux/amd64[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Acceleration preflight must receive all generated secret file paths."; exit 1; }
    # What: guards the ccache-redis-file wiring specifically.
    # Why: this exact input silently went unwired for ui/watchdog
    #   before; checking its declaration in the action file alone
    #   already missed that regression once.
    # From: Issue #1095
    grep -E '^[[:space:]]+ccache-redis-file:[[:space:]]+\$\{\{[[:space:]]*matrix\.service[[:space:]]*==[[:space:]]*.build-tools.[[:space:]]*&&[[:space:]]*steps\[.ccache-redis-secret.\]\.outputs\[.redis-file.\][[:space:]]*\|\|[[:space:]]*steps\.sccache-secret\.outputs\['\''ccache-redis-file'\''\][[:space:]]*\}\}[[:space:]]*$' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Acceleration preflight must receive ccache-redis-file from steps.sccache-secret's own output (or build-tools' own ccache-redis-secret)."; exit 1; }
    grep -F 'sccache rustc' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'sccache --dist-status' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'run_logged()' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'require_sccache_dist_connected' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'require_sccache_activity' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F '.stats.cache_hits' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F '.stats.cache_read_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F '.stats.cache_write_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F '.stats.cache_timeouts' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F '.stats.cache_errors' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'require_sccache_dist_activity' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'distcc-pump --startup' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'DISTCC_FALLBACK=0' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'PATH="$wrapper_dir:$PATH"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'DISTCC_POTENTIAL_HOSTS="$distcc_pump_hosts"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'unset DISTCC_HOSTS' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'distcc_hosts_without_pump="${distcc_hosts_without_pump:-$distcc_hosts}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'distcc_pump_filtered_hosts="${DISTCC_HOSTS:-}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'final_distcc_hosts="$distcc_hosts_without_pump"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'SCCACHE_REDIS_KEY_PREFIX="lancache-${LANCACHE_SERVICE}"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      || { echo "::error::Acceleration preflight must validate sccache read/write, sccache-dist, and distcc paths."; exit 1; }
    grep -F 'docker pull --platform "$BUILD_PLATFORM" "$BUILD_TOOLS_IMAGE"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'docker run --rm -i --platform "$BUILD_PLATFORM" --network "$BUILD_NETWORK"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      || { echo "::error::Acceleration preflight must use the same platform as the real Docker builds."; exit 1; }
    grep -F 'SCCACHE_SERVER_UDS="$preflight_dir/sccache.sock"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      || { echo "::error::Acceleration preflight must isolate its sccache server from runner-global daemons."; exit 1; }
    grep -F 'ccache-redis-file:' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F "CCACHE_PREFIX=distcc" .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'remote_storage_write' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'remote_storage_hit' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F 'ccache_dir_warm="$preflight_dir/ccache-dir-warm"' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      || { echo "::error::Acceleration preflight must validate ccache-over-distcc with a real Redis write then a real Redis read from a fresh local CCACHE_DIR."; exit 1; }
    grep -F -- '--network "$RUST_ACCELERATION_NETWORK"' .github/workflows/build-push.yml >/dev/null \
      && grep -E '^[[:space:]]+network:[[:space:]]+' .github/workflows/build-push.yml | grep -F 'env.RUST_BUILDX_NETWORK' >/dev/null \
      && grep -E '^[[:space:]]+allow:[[:space:]]+' .github/workflows/build-push.yml | grep -F 'network.host' >/dev/null \
      || { echo "::error::Acceleration infrastructure must use the same network mode as the preflight."; exit 1; }
}

ci_cmd_validate_rust_preflight_chain() {
    # What: asserts the Rust preflight/build-tools image chain.
    # Why: AG-CI-007: an installed accelerator is not a wired one.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    # What: no check for container-scan's old local-build networking.
    # Why: container-scan no longer builds locally; check was meaningless.
    # From: Issue #1095 | PR #1532
    grep -F -- '--crate-type lib' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F -- '--emit=link,dep-info' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      && grep -F -- '--out-dir' .github/actions/rust-acceleration-preflight/action.yml >/dev/null \
      || { echo "::error::Acceleration preflight must use a cacheable rustc library probe."; exit 1; }
    if grep -F -- '--crate-type bin' .github/actions/rust-acceleration-preflight/action.yml \
      || grep -E 'sccache rustc .* -o ' .github/actions/rust-acceleration-preflight/action.yml; then
      echo "::error::Acceleration preflight must not use non-cacheable binary rustc probes."
      exit 1
    fi
    grep -F 'steps.docker-build-jobs.outputs.jobs' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Docker Rust builds must pass computed CARGO_BUILD_JOBS as a build argument."; exit 1; }
    grep -F 'build_tools_image:' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Docker Rust builds must expose the selected build-tools image as a job output."; exit 1; }
    grep -F "printf 'build_tools_image=ghcr.io/%s/build-tools:latest\\n' \"\$GITHUB_REPOSITORY\" >> \"\$GITHUB_OUTPUT\"" .github/workflows/build-push.yml >/dev/null \
      && { echo "::error::The exported build-tools job output must not be hardcoded without validating that exact pullable image."; exit 1; }
    grep -F 'BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/untracked/select-build-tools-image.sh' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Downstream build-tools job output must validate the exact pullable GHCR image before exporting it."; exit 1; }
    # What: a positive grep, not a negative "must not contain X" check.
    # Why: the old form quoted X as its own arg, self-matching always.
    # From: Issue #1095 | PR #1532
    grep -F 'validation_build_tools_image="$downstream_build_tools_image"' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::validate-compose runs on the light tier and must reuse the already-resolved downstream_build_tools_image instead of building a local fallback."; exit 1; }
    # What: verifies published_image_reference() uses the shared helper.
    # Why: dedups a now-removed identical copy (AG-CODE-013).
    # From: PR #1523
    grep -F 'published_image_reference()' scripts/untracked/select-build-tools-image.sh >/dev/null \
      && grep -F 'resolve_manifest_digest "$image"' scripts/untracked/select-build-tools-image.sh >/dev/null \
      && grep -F 'docker buildx imagetools inspect "$image"' scripts/lib/ghcr-retry.sh >/dev/null \
      && grep -F 'published_image_reference "$published_image"' scripts/untracked/select-build-tools-image.sh >/dev/null \
      || { echo "::error::Build-tools selector must export the smoke-validated published image by multi-arch manifest digest."; exit 1; }
    if awk '
      index($0, "downstream_build_tools_image=\"$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/untracked/select-build-tools-image.sh)\"") { in_resolve = 1 }
      in_resolve && index($0, "printf '\''build_tools_image=%s\\n'\'' \"$downstream_build_tools_image\"") { exit found ? 0 : 1 }
      in_resolve && index($0, "docker pull \"$downstream_build_tools_image\"") { found = 1 }
      END { exit found ? 0 : 1 }
    ' .github/workflows/build-push.yml; then
      echo "::error::validate-compose must not re-pull mutable build-tools tags after selector smoke validation."
      exit 1
    fi
    grep -F 'BUILD_TOOLS_IMAGE:' .github/workflows/build-push.yml >/dev/null \
      && grep -F "needs['validate-compose'].outputs.build_tools_image" .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Docker Rust builds must thread the selected build-tools image into service builds."; exit 1; }
    awk '
      /name: Merge coverage reports and check threshold/ { in_merge = 1; has_docker = 0; has_build_tools = 0; next }
      in_merge && /^[[:space:]]+- name: / { exit (has_docker && has_build_tools) ? 0 : 1 }
      in_merge && /docker run --rm/ { has_docker = 1 }
      in_merge && /BUILD_TOOLS_IMAGE/ { has_build_tools = 1 }
      END { if (in_merge) exit (has_docker && has_build_tools) ? 0 : 1; exit 1 }
    ' .github/workflows/build-push.yml \
      || { echo "::error::Coverage merge must use the selected build-tools image instead of bare host jq/bc."; exit 1; }
    grep -F 'needs: validate-compose' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::Shellcheck must depend on validate-compose so it uses the validated build-tools image."; exit 1; }
    grep -F 'runs-on: [self-hosted, linux, lancache, lancache-heavy]' .github/workflows/build-tools.yml >/dev/null \
      || { echo "::error::The build-tools workflow's amd64 leg must run on the heavy runner tier."; exit 1; }
    # What: arm64 builds natively (like build-arm64), never QEMU-emulated.
    # Why: the CVE-2026-39822 build fails under QEMU (Go bufio error).
    # From: Issue #1095 | PR #1532
    grep -F 'runs-on: ubuntu-24.04-arm' .github/workflows/build-tools.yml >/dev/null \
      || { echo "::error::The build-tools workflow's arm64 leg must run natively on ubuntu-24.04-arm, not QEMU."; exit 1; }
    grep -F 'setup-qemu-action' .github/workflows/build-tools.yml >/dev/null \
      && { echo "::error::The build-tools workflow must not reintroduce QEMU emulation for its arm64 leg."; exit 1; }
    awk '
      /name: Build and push amd64 build-tools image/ { in_publish = 1; found = 0; next }
      # What: anchored on a real step declaration, not a bare name: match.
      # Why: a with: input ending in name would misread as the next step.
      # From: Issue #1095 | PR #1532
      in_publish && /^[[:space:]]*- name: / { exit found ? 0 : 1 }
      in_publish && /pull: true/ { found = 1 }
      END { if (in_publish) exit found ? 0 : 1; exit 1 }
    ' .github/workflows/build-tools.yml \
      || { echo "::error::The build-tools amd64 publish step must pull fresh mutable bases before publishing."; exit 1; }
    awk '
      /name: Build and push arm64 build-tools image/ { in_publish = 1; found = 0; next }
      # Same anchoring as the identical guard above; no apostrophes here
      # either (single-quoted awk script).
      in_publish && /^[[:space:]]*- name: / { exit found ? 0 : 1 }
      in_publish && /pull: true/ { found = 1 }
      END { if (in_publish) exit found ? 0 : 1; exit 1 }
    ' .github/workflows/build-tools.yml \
      || { echo "::error::The build-tools arm64 publish step must pull fresh mutable bases before publishing."; exit 1; }
    grep -F 'image-ref:' .github/workflows/build-tools.yml | grep -F 'BUILD_TOOLS_IMAGE' | grep -F 'steps.build.outputs.digest' >/dev/null \
      && grep -F 'image-ref:' .github/workflows/build-push.yml | grep -F 'github.repository' | grep -F 'matrix.service' | grep -F 'steps.build.outputs.digest' >/dev/null \
      || { echo "::error::Build-tools publish paths must scan the exact pushed digest before attestation/promotion."; exit 1; }
    # What: guards ghcr-build-push-retry stays wired into Build and push.
    # Why: that step already resolves steps.build.outputs.digest itself.
    # From: Issue #1095 | PR #1532
    grep -F 'uses: ./.github/actions/ghcr-build-push-retry' .github/workflows/build-push.yml >/dev/null \
      || { echo "::error::build/build-arm64 must publish through the shared ghcr-build-push-retry composite action so GHCR pushes retry on transient 401s (#822)."; exit 1; }
    grep -F 'Note arm64 scan coverage deferral' .github/workflows/build-tools.yml >/dev/null \
      && { echo "::error::The build-tools workflow must not keep the stale arm64 scan deferral notice."; exit 1; }
    grep -F 'Build local arm64 scan image' .github/workflows/build-tools.yml >/dev/null \
      && grep -F 'BUILD_TOOLS_SCAN_IMAGE_ARM64' .github/workflows/build-tools.yml >/dev/null \
      && grep -F 'uses: ./.github/actions/build-tools-candidate-smoke' .github/workflows/build-tools.yml >/dev/null \
      && grep -F 'Scan local build-tools arm64 image with Trivy' .github/workflows/build-tools.yml >/dev/null \
      || { echo "::error::The build-tools workflow must build, smoke-test, and Trivy-scan the local arm64 candidate before publishing."; exit 1; }
    grep -F 'merge-build-tools-manifests' .github/workflows/build-tools.yml >/dev/null \
      && grep -F 'imagetools create' .github/workflows/build-tools.yml >/dev/null \
      || { echo "::error::The build-tools workflow must merge its amd64/arm64 tags into the real sha-<commit> manifest before promoting mutable tags."; exit 1; }
}

ci_cmd_validate_promote_tags_dockerfiles() {
    # What: asserts tag promotion + Dockerfile distcc/sccache.
    # Why: a stale promotion rule publishes the wrong channel.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    # What: extracts and runs the real Promote mutable tags script.
    # Why: a branch named v0.2.0 would collide with a real release tag.
    # From: Issue #1095 | PR #1532
    grep -F 'branch_tag="${sanitized_ref}-tc"' .github/workflows/build-tools.yml >/dev/null \
      || { echo "::error::build-tools.yml's branch-tag promotion must suffix every derived tag with '-tc' so a branch named like a release tag (e.g. v0.2.0) can never collide with a real vX.Y.Z stable-release tag on the same GHCR package."; exit 1; }
    # What: anchored on the substring sanitized_ref=, not a full match.
    # Why: mawk (CI) and gawk (local) diverge on mid-pattern $ escaping.
    # From: Issue #1095 | PR #1532
    promote_tags_script="$(awk '
      /name: Promote mutable tags/ { in_step = 1 }
      in_step && /sanitized_ref=/ { capture = 1 }
      in_step && capture && /docker buildx imagetools create/ { exit }
      in_step && capture { print }
    ' .github/workflows/build-tools.yml)"
    if [ -z "$promote_tags_script" ]; then
      echo "::error::Could not extract build-tools.yml's \"Promote mutable tags\" derivation logic -- its step name or tag-derivation lines may have moved; update the extraction markers in build-push.yml's guard alongside them."
      exit 1
    fi
    # What: writes the extracted lines to a real script file, not -c.
    # Why: the text has its own quotes; re-quoting for -c is error-prone.
    guard_script="$(mktemp)"
    trap 'rm -f "$guard_script"' EXIT
    {
      printf '%s\n' 'set -euo pipefail'
      printf '%s\n' "$promote_tags_script"
      printf '%s\n' 'printf '\''%s'\'' "$branch_tag"'
    } > "$guard_script"
    for candidate_ref in v0.2.0 v1.2.3 v10.20.30 master feature/x; do
      derived_tag="$(
        REF_NAME="$candidate_ref" \
        BUILD_TOOLS_IMAGE=ghcr.io/example/build-tools \
        MERGED_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000 \
        bash "$guard_script"
      )"
      # here-string per AG-VAL-032, same SIGPIPE-under-pipefail hazard
      # as the other `printf | grep -q` conversions in this file.
      if grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$derived_tag"; then
        echo "::error::build-tools.yml's branch-tag derivation must never be able to emit a release-shaped tag; ref '$candidate_ref' produced '$derived_tag'."
        exit 1
      fi
    done
    for workflow in .github/workflows/build-push.yml .github/workflows/codeql.yml; do
      grep -F 'CARGO_BUILD_JOBS:' "$workflow" >/dev/null \
        && grep -F 'vars.CARGO_BUILD_JOBS' "$workflow" >/dev/null \
        || { echo "::error::$workflow must expose the CARGO_BUILD_JOBS repository variable to Cargo jobs."; exit 1; }
    done
    if grep -RInE '^(ARG SCCACHE_DIST_SCHEDULER_URL|ENV CARGO_BUILD_JOBS=)' services/*/Dockerfile; then
      echo "::error::Rust service Dockerfiles must not use scheduler-only args or hardcoded CARGO_BUILD_JOBS values."
      exit 1
    fi
    if grep -RInE '[c]argo install sccache .*--locked|[c]argo install .*--locked .*sccache' services/*/Dockerfile tools/build-tools/Dockerfile scripts; then
      echo "::error::sccache source installs must stay version-pinned but not use --locked while the pinned upstream lockfile emits yanked-crate warnings."
      exit 1
    fi
    if grep -RIn '[c]argo install sccache' services/*/Dockerfile tools/build-tools/Dockerfile scripts | grep -v -- '--no-default-features --features redis,dist-client'; then
      echo "::error::sccache source installs must use the minimal Redis plus dist-client feature set."
      exit 1
    fi
    if grep -RIn '[c]argo install cargo-audit' .github/workflows scripts services/*/Dockerfile; then
      echo "::error::CI and service builds must use prebuilt cargo-audit from the build-tools image instead of compiling it per job."
      exit 1
    fi
    for dockerfile in services/dns/Dockerfile services/ui/Dockerfile; do
      grep -F 'ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must declare the shared build-tools image as a build argument."; exit 1; }
      grep -F 'FROM ${BUILD_TOOLS_IMAGE}' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must use the shared build-tools image in the Rust builder stage."; exit 1; }
      if grep -F 'cargo install sccache' "$dockerfile" >/dev/null || grep -F 'apt-get download "distcc-pump=' "$dockerfile" >/dev/null; then
        echo "::error::$dockerfile must not bootstrap Rust builder tools locally anymore."
        exit 1
      fi
      grep -F 'for tool in cargo rustc rustup rustfmt clippy-driver sccache distcc distcc-pump python3 pkg-config; do' "$dockerfile" >/dev/null \
        && grep -F 'command -v "$tool" >/dev/null' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must fail closed if the shared build-tools image is missing a required tool."; exit 1; }
      grep -F 'lancache-rustc-wrapper' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must keep the sccache wrapper in place for Rust compiler invocations."; exit 1; }
      grep -F -- "--mount=type=secret,id=sccache_dist_config" "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must consume sccache-dist config through a BuildKit secret."; exit 1; }
      grep -F -- "--mount=type=secret,id=distcc_potential_hosts" "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must consume distcc hosts through a BuildKit secret."; exit 1; }
      grep -F 'sccache --dist-status' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must smoke-check sccache-dist when configured."; exit 1; }
      grep -F 'resolve_distcc_wrapper_dir()' "$dockerfile" >/dev/null \
        && grep -F 'for wrapper in cc gcc c++ g++; do' "$dockerfile" >/dev/null \
        && grep -F '"/usr/local/lib/distcc/$wrapper"' "$dockerfile" >/dev/null \
        && grep -F '/usr/local/lib/distcc /usr/lib/distcc' "$dockerfile" >/dev/null \
        && grep -F 'PATH="$distcc_wrapper_dir:$PATH" CC=cc GCC=gcc CXX=c++ GXX=g++' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must discover the distcc wrapper directory and route cc/gcc/c++/g++ through it."; exit 1; }
      grep -F 'original_path="$PATH"' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must save the original PATH before enabling distcc."; exit 1; }
      grep -F 'PATH="$original_path"' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must restore the original PATH before local compiler fallback."; exit 1; }
      grep -F 'PATH="$distcc_wrapper_dir:$PATH";' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must re-prepend the wrapper directory after distcc-pump startup."; exit 1; }
      grep -F 'lancache-rustc-wrapper' "$dockerfile" >/dev/null \
        && grep -F 'distcc|*/distcc) exec "$@" ;;' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must keep distcc out of the sccache Rust wrapper path."; exit 1; }
      grep -F 'lancache-distcc-wrapper' "$dockerfile" >/dev/null \
        && grep -F 'DISTCC_HOSTS_NO_PUMP' "$dockerfile" >/dev/null \
        || {
          if [ "$dockerfile" = "services/dns/Dockerfile" ]; then
            :;
          else
            echo "::error::$dockerfile must define a non-pump distcc host list for generated-header bypass."; exit 1;
          fi
        }
      if [ "$dockerfile" = "services/ui/Dockerfile" ]; then
        grep -F 'distcc_hosts_without_pump="${distcc_hosts_without_pump:-$distcc_hosts}"' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must fall back to stripped distcc hosts when no plain hosts are configured."; exit 1; }
        if grep -F 'DISTCC_HOSTS_NO_PUMP="${DISTCC_HOSTS:-$DISTCC_HOSTS_NO_PUMP}";' "$dockerfile" >/dev/null; then
          echo "::error::$dockerfile must not reassign DISTCC_HOSTS_NO_PUMP from the pump-published host list -- that list's ,cpp/,lzo suffix is only meaningful to a running include server, and lancache-distcc-wrapper's whole reason for using DISTCC_HOSTS_NO_PUMP is compiling WITHOUT one (confirmed live: this exact reassignment leaked the pump suffix into non-pump compiles, see #613)."
          exit 1
        fi
        grep -F 'export DISTCC_POTENTIAL_HOSTS="$distcc_pump_hosts";' "$dockerfile" >/dev/null \
          && grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must start distcc-pump with pump-capable hosts only."; exit 1; }
        grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must use distcc-pump for compatible generated-header bypass cases."; exit 1; }
        grep -F 'matches_aws_lc_generated_path' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must document aws-lc-sys generated-header bypass patterns in wrapper logic."; exit 1; }
      else
        grep -F 'DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must keep distcc-pump host discovery local to the builder."; exit 1; }
        grep -F 'distcc-pump --startup' "$dockerfile" >/dev/null \
          || { echo "::error::$dockerfile must use distcc-pump unless the builder is documented as incompatible with generated C headers."; exit 1; }
      fi
      grep -F 'echo "[INFO] trying distcc path."' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must log when the distcc path is actually attempted."; exit 1; }
      grep -F 'DISTCC_FALLBACK=0' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must disable distcc internal local fallback so project fallback logic can decide explicitly."; exit 1; }
      grep -F 'run_cargo_build()' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must retry once with the normal local compiler when the distcc path is unavailable."; exit 1; }
      if grep -F 'python3 -Werror::SyntaxWarning -m py_compile "$distcc_pump_parser"' "$dockerfile" >/dev/null; then
        echo "::error::$dockerfile must not patch distcc-pump locally now that the shared build-tools image provides it."
        exit 1
      fi
      grep -F 'cargo build -j "$cargo_jobs"' "$dockerfile" >/dev/null \
        || { echo "::error::$dockerfile must use the resolved cargo job count."; exit 1; }
    done
}

ci_cmd_validate_image_channel_resolution() {
    # What: asserts image channel/tag resolution + stack images.
    # Why: AG-REL-009: latest/nightly must never be conflated.
    # From: PR #1742 | Refs #1683
    cd "$CI_REPO_ROOT"
    if awk '
      /^# .*Installing systemd watchdog/ { in_install=1; pull_seen=0 }
      /^# .*Post-start info/ { in_install=0 }
      in_install && /docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+pull/ { pull_seen=1 }
      in_install && /^[[:space:]]*(systemctl[[:space:]]+(enable|start)[[:space:]]+(lancache\.service|lancache-converge\.timer)|docker[[:space:]]+compose([[:space:]]+--env-file[[:space:]]+[^[:space:]]+)?[[:space:]]+up[[:space:]]+-d)/ && !pull_seen { print FILENAME ":" FNR ":" $0; found=1 }
      END { exit found ? 0 : 1 }
    ' setup.sh; then
      echo "::error::setup.sh must not start or enable lancache services before image pull succeeds."
      exit 1
    fi

    grep -F 'lancache_image_registry=$(resolve_lancache_image_registry "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Update migration must resolve LANCACHE_IMAGE_REGISTRY from existing config instead of hard-coding it."; exit 1; }
    grep -F 'lancache_image_prefix=$(resolve_lancache_image_prefix "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Update migration must resolve LANCACHE_IMAGE_PREFIX from existing config instead of hard-coding it."; exit 1; }
    grep -F 'lancache_image_channel=$(resolve_lancache_image_channel "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Update migration must resolve LANCACHE_IMAGE_CHANNEL from existing config instead of hard-coding it."; exit 1; }
    grep -F 'lancache_image_tag=$(resolve_lancache_image_tag "$env_file")' setup.sh >/dev/null \
      || { echo "::error::Update migration must refresh LANCACHE_IMAGE_TAG with resolve_lancache_image_tag."; exit 1; }
    grep -F 'LANCACHE_IMAGE_CHANNEL=pinned requires LANCACHE_IMAGE_TAG to be set to an immutable sha-* or vX.Y.Z tag.' setup.sh >/dev/null \
      || { echo "::error::Pinned image channel must fail closed when LANCACHE_IMAGE_TAG is missing."; exit 1; }
    grep -F 'resolve_lancache_stack_channel_tag()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must resolve mutable image channels through the stack pointer image."; exit 1; }
    grep -F 'docker cp "${container_id}:/stack.env" -' setup.sh >/dev/null \
      || { echo "::error::setup.sh must read stack.env from the stack pointer image."; exit 1; }
    grep -F 'pub image_tag: String' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must expose image_tag."; exit 1; }
    grep -F 'pub image_registry: String' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must expose image_registry."; exit 1; }
    grep -F 'pub image_prefix: String' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must expose image_prefix."; exit 1; }
    grep -F 'pub image_channel: String' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must expose image_channel."; exit 1; }
    grep -F 'image_tag: state.config.lancache_image_tag.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_TAG."; exit 1; }
    grep -F 'image_registry: state.config.lancache_image_registry.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_REGISTRY."; exit 1; }
    grep -F 'image_prefix: state.config.lancache_image_prefix.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_PREFIX."; exit 1; }
    grep -F 'image_channel: state.config.lancache_image_channel.clone()' services/ui/src/routes/secondaries.rs >/dev/null \
      || { echo "::error::Secondary registration response must use the primary LANCACHE_IMAGE_CHANNEL."; exit 1; }
    grep -F "LANCACHE_IMAGE_REGISTRY=\${LANCACHE_IMAGE_REGISTRY:-ghcr.io}" deploy/quickstart/docker-compose.yml >/dev/null \
      && grep -F "LANCACHE_IMAGE_REGISTRY=\${LANCACHE_IMAGE_REGISTRY:-ghcr.io}" deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::UI must receive LANCACHE_IMAGE_REGISTRY."; exit 1; }
    grep -F "LANCACHE_IMAGE_PREFIX=\${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}" deploy/quickstart/docker-compose.yml >/dev/null \
      && grep -F "LANCACHE_IMAGE_PREFIX=\${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}" deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::UI must receive LANCACHE_IMAGE_PREFIX."; exit 1; }
    grep -F "LANCACHE_IMAGE_CHANNEL=\${LANCACHE_IMAGE_CHANNEL:-}" deploy/quickstart/docker-compose.yml >/dev/null \
      && grep -F "LANCACHE_IMAGE_CHANNEL=\${LANCACHE_IMAGE_CHANNEL:-}" deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::UI must receive LANCACHE_IMAGE_CHANNEL."; exit 1; }
    grep -F "response_image_tag=\$(echo \"\$response\"" setup.sh >/dev/null \
      || { echo "::error::setup.sh secondary must parse the primary image_tag."; exit 1; }
    grep -F "response_image_registry=\$(echo \"\$response\"" setup.sh >/dev/null \
      || { echo "::error::setup.sh secondary must parse the primary image_registry."; exit 1; }
    grep -F "response_image_prefix=\$(echo \"\$response\"" setup.sh >/dev/null \
      || { echo "::error::setup.sh secondary must parse the primary image_prefix."; exit 1; }
    grep -F "response_image_channel=\$(echo \"\$response\"" setup.sh >/dev/null \
      || { echo "::error::setup.sh secondary must parse the primary image_channel."; exit 1; }
    grep -F "LANCACHE_IMAGE_TAG=\${LANCACHE_IMAGE_TAG:-latest}" deploy/quickstart/docker-compose.yml >/dev/null \
      || { echo "::error::Quickstart UI must receive LANCACHE_IMAGE_TAG."; exit 1; }
    grep -F "LANCACHE_IMAGE_TAG=\${LANCACHE_IMAGE_TAG:-latest}" deploy/prod/docker-compose.yml >/dev/null \
      || { echo "::error::Prod UI must receive LANCACHE_IMAGE_TAG."; exit 1; }
    grep -F 'LANCACHE_IMAGE_REGISTRY=${LANCACHE_IMAGE_REGISTRY}' setup.sh >/dev/null \
      || { echo "::error::setup.sh must write LANCACHE_IMAGE_REGISTRY."; exit 1; }
    grep -F 'LANCACHE_IMAGE_PREFIX=${LANCACHE_IMAGE_PREFIX}' setup.sh >/dev/null \
      || { echo "::error::setup.sh must write LANCACHE_IMAGE_PREFIX."; exit 1; }
    grep -F 'LANCACHE_IMAGE_CHANNEL=${lancache_image_channel}' setup.sh >/dev/null \
      || { echo "::error::setup.sh secondary must write LANCACHE_IMAGE_CHANNEL."; exit 1; }
    grep -F 'derive_release_archive_image_tag()' setup.sh >/dev/null \
      || { echo "::error::setup.sh must preserve release archive image tags before defaulting to latest."; exit 1; }
    grep -F 'channel="${channel:-latest}"' setup.sh >/dev/null \
      || { echo "::error::setup.sh must keep latest as the normal stable default; nightly must be explicit."; exit 1; }
    grep -F 'LANCACHE_IMAGE_CHANNEL=latest' README.md >/dev/null \
      || { echo "::error::README must document latest as the normal install default."; exit 1; }
    grep -F 'fresh installs use `LANCACHE_IMAGE_CHANNEL=nightly` by default pre-1.0' docs/release-versioning.md >/dev/null \
      || { echo "::error::Release docs must document nightly as the pre-1.0 default (see #1068 item 1 / #1120)."; exit 1; }
    grep -F 'docker build --pull -t "$fallback_image" "$build_tools_context" >&2' scripts/untracked/select-build-tools-image.sh >/dev/null \
      || { echo "::error::build-tools selector must keep Docker build output out of stdout."; exit 1; }
    bash scripts/untracked/validate-stack-images.sh
}
# ============================================================
# GC
# ============================================================
#
# What: reachability-based GC over protected roots (§74-78).
# Why: untagged is not unused; age never justifies it.
# From: Issue #1683

CI_GC_PROTECTED_CHANNELS="${CI_GC_PROTECTED_CHANNELS:-latest nightly}"
CI_GC_KEEP_ACCEPTED="${CI_GC_KEEP_ACCEPTED:-10}"

ci_gc_roots() {
    # What: prints digests reachable from protected roots.
    # Why: §75 -- these are the roots reachability starts from.
    # From: Issue #1683
    local svc channel ref digest
    for svc in "${CI_SERVICES[@]}"; do
        ref="$(ci_image_ref "$svc")"
        for channel in $CI_GC_PROTECTED_CHANNELS; do
            digest="$(ci_registry_digest "${ref}:${channel}" 2>/dev/null)" || continue
            printf '%s %s\n' "$svc" "$digest"
        done
    done
}

ci_gc_is_protected() {
    # What: true iff digest $2 of service $1 is a protected root.
    # Why: §76 -- a reachable object is kept, never collected.
    # From: Issue #1683
    local service="$1" digest="$2" roots
    roots="$(ci_gc_roots)"
    grep -qx "$service $digest" <<< "$roots"
}

ci_gc_candidates() {
    # What: prints ledger entries no root references.
    # Why: §97 -- the index may only ever propose, never delete.
    # From: Issue #1683
    local key digest service
    [[ -d "$CI_LEDGER_DIR" ]] || return 0
    while IFS= read -r key; do
        digest="$(cat "$key")"
        service="$(basename "$(dirname "$(dirname "$key")")")"
        ci_gc_is_protected "$service" "$digest" && continue
        printf '%s %s\n' "$service" "$digest"
    done < <(find "$CI_LEDGER_DIR" -type f | LC_ALL=C sort)
}

ci_cmd_gc() {
    # What: reports GC candidates; deletes nothing by default.
    # Why: §97 -- the ledger proposes, the graph decides.
    # From: Issue #1683
    local mode="${1:-report}" count=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        count=$((count + 1))
        printf 'gc-candidate %s\n' "$line"
    done < <(ci_gc_candidates)
    ci_log "gc: $count candidate(s) not reachable from any protected channel"
    [[ "$mode" == "--execute" ]] \
        || { ci_log "gc: report-only; pass --execute to delete (nothing was deleted)"; return 0; }
    ci_die "gc --execute is not enabled yet; deletion is gated behind an explicit rollout"
}

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

ci_path_touches_any_service() {
    # What: true iff $1 is a build input of at least one service.
    # Why: cheap pure-bash filter before any per-path git work.
    # From: Issue #1683
    local path="$1" svc
    for svc in "${CI_SERVICES[@]}"; do
        ci_service_touches_path "$svc" "$path" && return 0
    done
    return 1
}

ci_semantic_changed_paths() {
    # What: service-relevant paths with real content change.
    # Why: normalizing paths no service consumes is wasted work.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2" path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        ci_path_touches_any_service "$path" || continue
        ci_semantic_diff_is_noop "$base_ref" "$head_ref" "$path" && continue
        printf '%s\n' "$path"
    done < <(ci_changed_paths "$base_ref" "$head_ref")
}

ci_test_required() {
    # What: true iff a changed path is a test or engine input.
    # Why: §64 -- a ci.sh edit must still run the engine's tests.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2" path
    while IFS= read -r path; do
        case "$path" in
            tests/* | scripts/ci/*) return 0 ;;
        esac
    done < <(ci_changed_paths "$base_ref" "$head_ref")
    return 1
}

ci_plan_compute() {
    # What: computes the verdict once into CI_PLAN_* variables.
    # Why: rendering and output export must not recompute it.
    # From: Issue #1683
    local base_ref="$1" head_ref="$2"
    local -a changed=()
    CI_PLAN_IMPACTED=()

    # What: changed paths, mapped to affected services.
    # Why: §11 -- a touched path is a candidate, never a verdict.
    # From: Issue #1683
    mapfile -t changed < <(ci_semantic_changed_paths "$base_ref" "$head_ref")
    (( ${#changed[@]} > 0 )) && mapfile -t CI_PLAN_IMPACTED < <(ci_impacted_services "${changed[@]}")

    # What: whether the engine's own tests must run this time.
    # Why: service impact never implies this, so it is separate.
    # From: Issue #1683
    CI_PLAN_TEST_REQUIRED="false"
    ci_test_required "$base_ref" "$head_ref" && CI_PLAN_TEST_REQUIRED="true"

    # What: an if/else chain, never a trailing `[[ ]] && assign`.
    # Why: that form returns 1 when false, failing the no-op run.
    # From: Issue #1683
    if (( ${#CI_PLAN_IMPACTED[@]} > 0 )); then
        CI_PLAN_STATE="WORK_REQUIRED"
    elif [[ "$CI_PLAN_TEST_REQUIRED" == "true" ]]; then
        CI_PLAN_STATE="TEST_REQUIRED"
    else
        CI_PLAN_STATE="NOOP"
    fi
}

ci_matrix_runs_on() {
    # What: prints the real runs-on JSON value for $1/$2.
    # Why: arm64 uses a native GH runner, amd64 self-hosted.
    # From: Issue #1683
    local service="$1" platform="$2" class
    if [[ "$platform" == "linux/arm64" ]]; then
        printf '"ubuntu-24.04-arm"'
        return 0
    fi
    class="$(ci_service_runner_class "$service")"
    printf '["self-hosted","linux","lancache","lancache-%s"]' "$class"
}

ci_plan_build_matrix_json() {
    # What: prints the build_matrix JSON array for the current plan.
    # Why: shared by ci_plan_render_json and the workflow output.
    # From: Issue #1683
    local svc platform first=1
    printf '['
    for svc in "${CI_PLAN_IMPACTED[@]}"; do
        [[ -n "$svc" ]] || continue
        while IFS= read -r platform; do
            (( first )) || printf ','
            first=0
            printf '{"service":"%s","platform":"%s","runs_on":%s}' \
                "$svc" "$platform" "$(ci_matrix_runs_on "$svc" "$platform")"
        done < <(ci_service_platforms "$svc")
    done
    printf ']'
}

ci_plan_render_json() {
    # What: renders the already-computed verdict as JSON.
    # Why: §10.2 -- YAML consumes a machine-readable plan.
    # From: Issue #1683
    local svc first=1 impacted
    impacted="$(printf '%s\n' "${CI_PLAN_IMPACTED[@]}")"
    printf '{"global":{"state":"%s","test_required":%s},"services":{' \
        "$CI_PLAN_STATE" "$CI_PLAN_TEST_REQUIRED"
    for svc in "${CI_SERVICES[@]}"; do
        (( first )) || printf ','
        first=0
        if grep -qx "$svc" <<< "$impacted"; then
            printf '"%s":{"state":"ARTIFACT_REQUIRED","build_ack":false}' "$svc"
        else
            printf '"%s":{"state":"NOOP"}' "$svc"
        fi
    done
    printf '},"build_matrix":%s}\n' "$(ci_plan_build_matrix_json)"
}

ci_plan_json() {
    # What: computes and prints the plan for refs $1..$2 as JSON.
    # Why: the standalone entry point for `ci.sh plan`.
    # From: Issue #1683
    ci_plan_compute "$1" "$2"
    ci_plan_render_json
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

ci_remote_ref_tip() {
    # What: prints the remote's current tip SHA for ref $1.
    # Why: one seam for a live tip, so a test can substitute it.
    # From: PR #1742 | Refs #1683
    git ls-remote "${CI_GIT_REMOTE:-origin}" "$1" | cut -f1
}

ci_cmd_push_supersession_check() {
    # What: emits superseded=true iff a newer push moved this ref.
    # Why: §5 -- the skip decision belongs here, not in YAML.
    # From: PR #1742 | Refs #1683
    local event="${EVENT_NAME:-}" ref="${PUSH_REF:-}" sha="${PUSH_SHA:-}"
    local superseded="false" current_tip=""

    # What: only meaningful for a push to a mutable branch ref.
    # Why: other events have no supersession concept; false is safe.
    # From: PR #1334
    if [[ "$event" == "push" && "$ref" == refs/heads/* ]]; then
        # What: an unresolvable tip fails OPEN, unlike promote's copy.
        # Why: wrongly reporting superseded=true skips the only build.
        # From: PR #1334
        current_tip="$(ci_remote_ref_tip "$ref" || true)"
        if [[ -z "$current_tip" ]]; then
            ci_annotate warning "Could not resolve the current remote tip of ${ref}; failing open (treating this push as NOT superseded, so build/container-scan still run)."
        elif [[ "$current_tip" != "$sha" ]]; then
            ci_annotate notice "${ref} has already moved to ${current_tip} since this run was triggered for ${sha}; a newer push already supersedes this one, skipping the heavy build/container-scan work for this run."
            superseded="true"
        fi
    fi

    ci_emit_output superseded "$superseded"
}

ci_cmd_resolve_refs() {
    # What: resolves the diff base/head for the triggering event.
    # Why: §10.1 -- one place decides what the planner diffs.
    # From: Issue #1683
    local base head="${HEAD_REF:-${HEAD_SHA:-HEAD}}"

    # What: each event carries its base in its own field.
    # Why: an unknown event has no base to diff against.
    # From: Issue #1683
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
    local base="${BASE_REF:?BASE_REF is required}" head="${HEAD_REF:?HEAD_REF is required}"

    # What: computes once, then prints and exports it.
    # Why: recomputing or re-parsing would waste or lie.
    # From: Issue #1683
    ci_plan_compute "$base" "$head"
    ci_plan_render_json

    # What: the state every downstream job's `if:` is gated on.
    # Why: NOOP here is what keeps a no-op run from starting jobs.
    # From: Issue #1683
    ci_emit_output global-state "$CI_PLAN_STATE"

    # What: separate signal for "run the engine's own tests".
    # Why: §64 -- a ci.sh edit impacts no service, but tests.
    # From: Issue #1683
    ci_emit_output test-required "$CI_PLAN_TEST_REQUIRED"

    # What: impacted services, space-separated, may be empty.
    # Why: readable alongside the JSON matrix for log output.
    # From: Issue #1683
    ci_emit_output impacted-services "${CI_PLAN_IMPACTED[*]:-}"

    # What: the real GH Actions matrix, one leg per platform.
    # Why: §71 -- the build job's strategy.matrix comes from here.
    # From: Issue #1683
    ci_emit_output build-matrix "$(ci_plan_build_matrix_json)"

    # What: one human-readable line stating the decision reached.
    # Why: §79 -- a reader must see why CI did or skipped work.
    # From: Issue #1683
    ci_log "planner verdict: $CI_PLAN_STATE (tests required: $CI_PLAN_TEST_REQUIRED)"
}

ci_cmd_report_result() {
    # What: turns the job results into one pass/fail verdict.
    # Why: §62 -- the required check reports even on a NOOP run.
    # From: Issue #1683
    local plan_result="${PLAN_RESULT:-}" tests_result="${TESTS_RESULT:-}"
    local build_result="${BUILD_RESULT:-}" aggregate_result="${AGGREGATE_RESULT:-}"
    local state="${GLOBAL_STATE:-}"

    # What: the planner itself must have completed successfully.
    # Why: without a verdict there is nothing to report on.
    # From: Issue #1683
    [[ "$plan_result" == "success" ]] \
        || ci_report_failure "plan job" "ci.yml" "success" "$plan_result" "see the plan job log"

    # What: an absent or UNKNOWN planner state fails the run.
    # Why: §2.3 -- UNKNOWN is never silently treated as a pass.
    # From: Issue #1683
    [[ -n "$state" && "$state" != "UNKNOWN" ]] \
        || ci_report_failure "planner state" "ci.yml" "a decided state" "${state:-<empty>}" "check the plan job's output"

    # What: skipped passes; other non-success does not.
    # Why: the tests job is legitimately skipped on a no-op run.
    # From: Issue #1683
    [[ "$tests_result" == "success" || "$tests_result" == "skipped" ]] \
        || ci_report_failure "engine tests" "ci.bats" "success" "$tests_result" "see the failing tests listed in that job"

    # What: build/aggregate are legitimately skipped when idle.
    # Why: has-builds=false must not fail a job that never ran.
    # From: Issue #1683
    [[ "$build_result" == "success" || "$build_result" == "skipped" ]] \
        || ci_report_failure "build" "ci.yml" "success" "$build_result" "see the failing build leg(s) above"
    [[ "$aggregate_result" == "success" || "$aggregate_result" == "skipped" ]] \
        || ci_report_failure "aggregate" "ci.yml" "success" "$aggregate_result" "see the aggregate job log"

    # What: prints every collected failure before failing the job.
    # Why: the reader must never hunt backwards for the cause.
    # From: Issue #1683
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
  push-supersession-check      Emit superseded=true/false for this push.
  admission <service> <plat>   Print ACK or DISACK for one build.
  build-one <svc> <plat> <dir> Admit, build, publish, verify; record.
  assemble <service> <ident>   Assemble the multi-arch index.
  stack-candidate              Print the accepted stack as service=digest.
  aggregate <result-dir>       Merge job results into the ledger, once.
  promote <candidate> <chan>   Move a channel to the candidate digests.
  nightly                      Promote the desired stack to nightly.
  release <channel>            Promote an accepted stack to a release.
  gc [--execute]               Report unreachable artifacts.
  checks                       Run every kept standing-check script.
  file-header-checks           Run file-headers/-hosted's 6 repo-wide checks.
  diff-checks <sha> <ref>      Run the PR-diff-scoped header/chronology checks.
  compose-healthchecks         Run compose-healthchecks/-hosted's own check.
  line-endings-check           Run line-endings/-hosted's own check.
  language-policy-check        Run language-policy/-hosted's own check.
  setup-migration-check        Run shellcheck-hosted's migration test.
  action-node-versions-check   Run shellcheck-hosted's action-pin guard.
  validation-subnet-check      Run shellcheck-hosted's subnet guard.
  executable-bits-check        Run shellcheck-hosted's exec-bit guard.
  build-tools-smoke-cov-check  Run shellcheck-hosted's smoke-cov guard.
  pipefail-early-exit-check    Run shellcheck-hosted's pipefail guard.
  pipefail-scope-check         Run shellcheck-hosted's pipefail-scope guard.
  repository-case-check        Run shellcheck-hosted's repo-case guard.
  validate-prebuilt-install    Assert prod/quickstart stay prebuilt-only.
  validate-nats-socket-proxy   Assert NATS + socket-proxy contracts.
  validate-dhcp-proxy-env      Assert dhcp-proxy env-file/PXE contracts.
  validate-setup-keys-kea      Assert setup.sh keys + Kea preflight.
  validate-setup-update-migrationAssert setup.sh update-migration safety.
  validate-accel-policy        Assert container hygiene + accel policy.
  validate-rust-preflight-chainAssert Rust preflight/build-tools chain.
  validate-promote-tags-dockerfilesAssert tag promotion + distcc/sccache.
  validate-image-channel-resolutionAssert channel/tag resolution + stack.
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
        push-supersession-check) ci_cmd_push_supersession_check ;;
        plan-outputs) ci_cmd_plan_outputs ;;
        report-result) ci_cmd_report_result ;;
        admission) ci_build_admission "${1:?admission: service required}" "${2:?admission: platform required}" ;;
        build-one) ci_cmd_build_one "${1:?build-one: service required}" "${2:?build-one: platform required}" "${3:?build-one: result dir required}" ;;
        assemble) ci_assemble_index "${1:?assemble: service required}" "${2:?assemble: identity required}" ;;
        stack-candidate) ci_stack_candidate ;;
        aggregate) ci_ledger_aggregate "${1:?aggregate: result directory required}" ;;
        promote) ci_promote_channel "${1:?promote: candidate file required}" "${2:?promote: channel required}" ;;
        nightly) ci_cmd_nightly ;;
        release) ci_cmd_release "${1:?release: channel required}" ;;
        gc) ci_cmd_gc "${1:-report}" ;;
        checks) ci_cmd_checks ;;
        file-header-checks) ci_cmd_file_header_checks ;;
        diff-checks) ci_cmd_diff_checks "${1:?diff-checks: base sha required}" "${2:?diff-checks: base ref required}" ;;
        compose-healthchecks) ci_cmd_compose_healthchecks ;;
        line-endings-check) ci_cmd_line_endings_check ;;
        language-policy-check) ci_cmd_language_policy_check ;;
        setup-migration-check) ci_cmd_setup_migration_check ;;
        action-node-versions-check) ci_cmd_action_node_versions_check ;;
        validation-subnet-check) ci_cmd_validation_subnet_check ;;
        executable-bits-check) ci_cmd_executable_bits_check ;;
        build-tools-smoke-cov-check) ci_cmd_build_tools_smoke_coverage_check ;;
        pipefail-early-exit-check) ci_cmd_pipefail_early_exit_check ;;
        pipefail-scope-check) ci_cmd_pipefail_scope_check ;;
        repository-case-check) ci_cmd_repository_case_check ;;
        validate-prebuilt-install) ci_cmd_validate_prebuilt_install ;;
        validate-nats-socket-proxy) ci_cmd_validate_nats_socket_proxy ;;
        validate-dhcp-proxy-env) ci_cmd_validate_dhcp_proxy_env ;;
        validate-setup-keys-kea) ci_cmd_validate_setup_keys_kea ;;
        validate-setup-update-migration) ci_cmd_validate_setup_update_migration ;;
        validate-accel-policy) ci_cmd_validate_accel_policy ;;
        validate-rust-preflight-chain) ci_cmd_validate_rust_preflight_chain ;;
        validate-promote-tags-dockerfiles) ci_cmd_validate_promote_tags_dockerfiles ;;
        validate-image-channel-resolution) ci_cmd_validate_image_channel_resolution ;;
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
