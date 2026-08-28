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

ci_die() {
    # What: prints an error to stderr and exits non-zero.
    # Why: one exit point keeps error formatting consistent.
    # From: Issue #1683
    printf 'ci.sh: error: %s\n' "$*" >&2
    exit 1
}

ci_log() {
    # What: prints a structured, greppable log line to stderr.
    # Why: §79 requires every CI decision to be justified.
    # From: Issue #1683
    printf 'ci.sh: %s\n' "$*" >&2
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

# What: external build contexts per service, if any (§13).
# Why: §13's dependency graph avoids re-parsing Dockerfiles.
# From: Issue #1683
declare -Ag CI_SERVICE_EXTERNAL_CONTEXT=(
    [proxy]="dns=services/dns"
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

# ============================================================
# IMPACT ENGINE
# ============================================================

# ============================================================
# IDENTITY ENGINE
# ============================================================

# ============================================================
# ARTIFACT RESOLVER
# ============================================================

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
# DISPATCH
# ============================================================

ci_usage() {
    cat <<'USAGE'
Usage: ci.sh <command> [args...]

Commands:
  services                 List the one authoritative service list.
  version                  Print ci.sh's own version.
USAGE
}

ci_main() {
    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { ci_usage >&2; exit 1; }
    shift || true
    case "$cmd" in
        services) ci_service_list ;;
        version) printf '%s\n' "$CI_SH_VERSION" ;;
        -h|--help|help) ci_usage ;;
        *) ci_die "unknown command: $cmd" ;;
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
