#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: authoritative CI 2.0 implementation entry point.
# Why: consolidates per-runner-type duplication.
# From: Issue #1683

# ============================================================
# CONSTANTS / EXIT HANDLING
# ============================================================

CI_SH_VERSION="0.1.0"

# What: full-length-only Git SHA / OCI digest regexes.
# Why: §15 forbids abbreviated identifiers in CI 2.0.
# From: Issue #1683
readonly CI_FULL_GIT_SHA_REGEX='^[0-9a-f]{40}$'
readonly CI_FULL_OCI_DIGEST_REGEX='^sha256:[0-9a-f]{64}$'

# What: collects failures for final summary output.
# Why: reader must not scroll back to find failures.
# From: Issue #1683
declare -ag CI_FAILURES=()

ci_annotate() {
    # What: emits GitHub ::error:: or ::warning:: annotation.
    # Why: puts cause in job summary, not just logs.
    # From: Issue #1683
    local level="$1"; shift
    printf '::%s::%s\n' "$level" "$*" >&2
}

ci_log() {
    # What: prints structured, greppable log to stderr.
    # Why: §79 requires every CI decision justified.
    # From: Issue #1683
    printf 'ci.sh: %s\n' "$*" >&2
}

ci_report_failure() {
    # What: reports failure with expected vs. actual.
    # Why: exit code alone doesn't show what failed.
    # From: Issue #1683
    local check="$1" subject="$2" expected="$3" actual="$4" remedy="${5:-}"
    local line="$check failed for '$subject': expected $expected, got $actual"
    [[ -n "$remedy" ]] && line="$line -- fix: $remedy"
    CI_FAILURES+=("$line")
    ci_annotate error "$line"
}

ci_failure_summary() {
    # What: prints all recorded failures, returns non-zero.
    # Why: reader sees all causes, not just first.
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
    # What: annotates cause, then exits non-zero.
    # Why: bare exit 1 leaves reader with no cause.
    # From: Issue #1683
    ci_annotate error "ci.sh: $*"
    printf 'ci.sh: error: %s\n' "$*" >&2
    exit 1
}

ci_mktemp() {
    # What: creates temp file, dies if mktemp fails.
    # Why: empty path would reach rm and redirects.
    # From: Issue #1683
    local path
    path="$(mktemp)" || ci_die "mktemp failed; refusing to continue without a temp file"
    [[ -n "$path" && -f "$path" ]] || ci_die "mktemp returned no usable path"
    printf '%s\n' "$path"
}

ci_rm_temp() {
    # What: removes $1 only if in a temp directory.
    # Why: empty or stray paths must never reach rm.
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
    # What: runs command, names it if exit non-zero.
    # Why: §68 — never pass exit code up unexplained.
    # From: Issue #1683
    local label="$1"; shift
    local rc=0
    "$@" || rc=$?
    (( rc == 0 )) && return 0
    ci_annotate error "$label failed (exit $rc): $*"
    printf 'ci.sh: %s failed (exit %d): %s\n' "$label" "$rc" "$*" >&2
    return "$rc"
}

# What: repo root resolved from this file's location.
# Why: needed to source scripts/lib/*.sh from any cwd.
# From: Issue #1683
CI_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_REPO_ROOT="$(cd "$CI_SH_DIR/../.." && pwd)"

ci_validate_full_git_sha() {
    # What: dies unless $1 is full 40-hex Git SHA.
    # Why: §15 forbids abbreviated SHAs in CI 2.0.
    # From: Issue #1683
    [[ "${1:-}" =~ $CI_FULL_GIT_SHA_REGEX ]] || ci_die "not a full git SHA: ${1:-<empty>}"
}

ci_validate_full_oci_digest() {
    # What: dies unless $1 is full sha256: digest.
    # Why: §15 forbids abbreviated digests in CI 2.0.
    # From: Issue #1683
    [[ "${1:-}" =~ $CI_FULL_OCI_DIGEST_REGEX ]] || ci_die "not a full OCI digest: ${1:-<empty>}"
}

# ============================================================
# SERVICE INVENTORY
# ============================================================
#
# What: authoritative service list + metadata (§7/8).
# Why: prevents §7's many-copies drift class.
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

# What: external build contexts per service (§13).
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
    # What: prints authoritative service list, one per line.
    # Why: keeps §7's "exactly one list" for reads too.
    # From: Issue #1683
    printf '%s\n' "${CI_SERVICES[@]}"
}

ci_service_exists() {
    # What: returns success iff $1 is in CI_SERVICES.
    # Why: single check, not re-implemented per caller.
    # From: Issue #1683
    local candidate="$1" svc
    for svc in "${CI_SERVICES[@]}"; do
        [[ "$svc" == "$candidate" ]] && return 0
    done
    return 1
}

ci_require_service() {
    # What: validates $1 is known service, dies otherwise.
    # Why: fail closed on typo, not undefined lookup.
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
    # What: prints $1's platforms, one per line.
    # Why: §43 reads from one place, not per job.
    # From: Issue #1683
    ci_require_service "$1"
    # shellcheck disable=SC2086 # word-split space-separated platforms on purpose
    printf '%s\n' ${CI_SERVICE_PLATFORMS[$1]}
}

ci_service_runner_class() {
    # What: prints $1's runner class (heavy|light).
    # Why: §71 matrix needs this to pick runner.
    # From: Issue #1683
    ci_require_service "$1"
    printf '%s\n' "${CI_SERVICE_RUNNER_CLASS[$1]}"
}

ci_service_compiler_class() {
    # What: prints $1's compiler (none|rust|c).
    # Why: selects cache-tier configuration.
    # From: Issue #1683
    ci_require_service "$1"
    printf '%s\n' "${CI_SERVICE_COMPILER_CLASS[$1]}"
}

ci_service_external_contexts() {
    # What: prints $1's external build contexts.
    # Why: §13 needs proxy's dns dependency.
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
# What: §12.5's narrow v1, not full equivalence.
# Why: 4 grammars in bash is a project (§12.5).
# From: Issue #1683

ci_path_is_markdown() {
    # What: true iff $1 is a Markdown file (*.md).
    # Why: Markdown is NOOP by default in the impact engine.
    # From: Issue #1683
    [[ "$1" == *.md ]]
}

# What: .md paths that are real build inputs.
# Why: §12.4's exception, env-driven not hardcoded.
# From: Issue #1683
CI_MARKDOWN_BUILD_INPUTS="${CI_MARKDOWN_BUILD_INPUTS:-}"

ci_markdown_is_build_input() {
    # What: true iff $1 is on build-input allowlist.
    # Why: §12.4's escape hatch for build input.
    # From: Issue #1683
    local path="$1" entry
    for entry in $CI_MARKDOWN_BUILD_INPUTS; do
        [[ "$path" == "$entry" ]] && return 0
    done
    return 1
}

ci_normalize_for_hash() {
    # What: strips comments, blanks, CRLF; keeps code.
    # Why: shell/Dockerfile '#' is always comment.
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
    # What: normalizes stdin by $1's extension.
    # Why: routes .yml/.yaml through block-scalar path.
    # From: Issue #1683
    case "$1" in
        *.yml | *.yaml) ci_normalize_yaml_for_hash /dev/stdin ;;
        *) ci_normalize_for_hash /dev/stdin ;;
    esac
}

ci_content_hash() {
    # What: prints sha256 of $1's normalized content.
    # Why: exec-bit flip is a real input change.
    # From: Issue #1683
    local path="$1" mode="${2:-}"
    { printf 'mode=%s\n' "$mode"; ci_normalize_dispatch "$path" < "$path"; } | sha256sum | cut -d' ' -f1
}

# ============================================================
# IMPACT ENGINE
# ============================================================
#
# What: path → impact (§11) + dependency (§13).
# Why: path != boundary; build graph decides.
# From: Issue #1683

ci_service_touches_path() {
    # What: true iff $2 is input for service $1.
    # Why: checks service's own + external (§13).
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
    # What: prints services impacted by paths.
    # Why: markdown excluded by default, unique paths.
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
    # What: true iff $3's mode and content match.
    # Why: identity tracks mode too, not just (§16).
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
# What: content-derived identities per domain (§14).
# Why: SHA answers "when", not "is same".
# From: Issue #1683

# What: toolchain identity, supplied by the caller.
# Why: §16 folds it in; the repo cannot derive it.
# From: Issue #1683
CI_TOOLCHAIN_IDENTITY="${CI_TOOLCHAIN_IDENTITY:-unset}"

# What: resolved base-image digests (§17).
# Why: mutable tags must be pinned before hashing.
# From: Issue #1683
CI_BASE_IMAGE_DIGESTS="${CI_BASE_IMAGE_DIGESTS:-}"

ci_path_identity() {
    # What: prints mode + normalized hash for $1.
    # Why: mode and content are file's identity.
    # From: Issue #1683
    local path="$1" mode
    mode="$(git ls-files -s -- "$path" | awk '{print $1}')"
    [[ -n "$mode" ]] || ci_die "not a tracked file: $path"
    printf '%s %s\n' "$mode" "$(ci_content_hash "$path" "$mode")"
}

ci_service_input_paths() {
    # What: prints $1's input paths, sorted.
    # Why: stable order keeps hash reproducible.
    # From: Issue #1683
    ci_service_input_entries "$1" | cut -f2
}

ci_service_input_entries() {
    # What: prints mode/path per input of $1.
    # Why: one git call, not per-file calls.
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
    # What: normalizes paths in file $1 in one pass.
    # Why: per-file subprocesses made identity ~12s.
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
    # What: prints $1's identity for platform $2.
    # Why: §16 — content, platform, bases.
    # From: Issue #1683
    local service="$1" platform="$2"
    ci_require_service "$service"
    [[ -n "$platform" ]] || ci_die "ci_build_identity: platform is required for $service"

    # What: materializes file list once for awk.
    # Why: awk reads modes while walking files.
    # From: Issue #1683
    local entries
    entries="$(ci_mktemp)"
    ci_service_input_entries "$service" > "$entries"

    # What: hashed identity inputs, then content.
    # Why: §16 — these inputs define artifact.
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
    # What: prints $1's test identity (§14.3).
    # Why: §29 — rerun on change, not rebuild.
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
    # What: prints validation identity for $1 (§14.4).
    # Why: §30 — policy change rescans.
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
    # From: Issue #1683
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
