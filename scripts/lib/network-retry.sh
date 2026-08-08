#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared retry wrapper for external read-only network operations that are
# expected to be deterministic once the remote endpoint is reachable, such as
# downloading one checksum-pinned release asset. This exists so callers do not
# grow their own ad-hoc retry policies and so the retry contract is
# reviewable/testable in one place.
#
# Unlike build-retry.sh, this wrapper is not suitable for a compilation/build
# command, where most failures are deterministic code defects. It is also not
# a GHCR wrapper: registry reads/writes must continue to use ghcr-retry.sh so
# they get the established fresh-login behavior between attempts.
#
# A wrapped command must classify conclusively non-retryable failures by
# returning NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE. Curl callers should use
# the classifier functions below for transport and HTTP results. The wrapper
# retries every other nonzero result because it is intentionally scoped only
# to read-only external network operations.
#
# Pure functions only. Do not enable shell options here because this file is
# sourced into callers that own their own strict-mode policy.

NETWORK_RETRY_MAX_ATTEMPTS="${NETWORK_RETRY_MAX_ATTEMPTS:-4}"
NETWORK_RETRY_BACKOFF_SECONDS="${NETWORK_RETRY_BACKOFF_SECONDS:-30}"
NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE="${NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE:-99}"

# network_retry_curl_exit_is_transient <curl-exit-code>
# Curl's transport-layer exit codes are stable API. These cases describe
# DNS/connect/TLS-session/timeout/partial-transfer/HTTP2 transport failures
# that can succeed unchanged on a later attempt. Local I/O, malformed URL,
# certificate trust, redirect-loop and option errors are deliberately absent
# and therefore permanent.
network_retry_curl_exit_is_transient() {
    case "${1:-}" in
        5|6|7|16|18|28|35|52|55|56|92) return 0 ;;
        *) return 1 ;;
    esac
}

# network_retry_http_status_is_transient <http-status>
# Retry request-timeout, too-early, rate-limit and server-side failures. Other
# 4xx responses represent a deterministic request/auth/path problem and must
# fail immediately instead of being hidden behind the retry budget.
network_retry_http_status_is_transient() {
    local status="${1:-}"
    [[ "$status" =~ ^[0-9]{3}$ ]] || return 1
    case "$status" in
        408|425|429|5??) return 0 ;;
        *) return 1 ;;
    esac
}

# network_retry -- <command> [args...]
network_retry() {
    if [[ "${1:-}" != "--" ]]; then
        echo "::error::network_retry: expected -- before the command to run" >&2
        return 2
    fi
    shift
    if (( $# == 0 )); then
        echo "::error::network_retry: command is required" >&2
        return 2
    fi

    local attempt=1
    local status=0
    while (( attempt <= NETWORK_RETRY_MAX_ATTEMPTS )); do
        if "$@"; then
            status=0
        else
            status=$?
        fi

        if (( status == 0 )); then
            return 0
        fi
        if (( status == NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE )); then
            echo "::error::External network operation failed permanently (exit ${status}): $*" >&2
            return "$status"
        fi
        if (( attempt >= NETWORK_RETRY_MAX_ATTEMPTS )); then
            echo "::error::External network operation failed after ${NETWORK_RETRY_MAX_ATTEMPTS} attempts (exit ${status}): $*" >&2
            return "$status"
        fi

        echo "::warning::External network operation failed (attempt ${attempt}/${NETWORK_RETRY_MAX_ATTEMPTS}, exit ${status}); waiting ${NETWORK_RETRY_BACKOFF_SECONDS}s before retry: $*" >&2
        sleep "$NETWORK_RETRY_BACKOFF_SECONDS"
        attempt=$((attempt + 1))
    done

    return "$status"
}
