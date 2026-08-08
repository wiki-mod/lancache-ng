#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared retry wrapper for external read-only network operations that are
# expected to be deterministic once the remote endpoint is reachable, such as
# downloading one checksum-pinned release asset. This exists so callers do not
# grow their own ad-hoc `curl --retry` policies and so the retry contract is
# reviewable/testable in one place.
#
# Unlike build-retry.sh, this wrapper is not suitable for a compilation/build
# command, where most failures are deterministic code defects. It is also not
# a GHCR wrapper: registry reads/writes must continue to use ghcr-retry.sh so
# they get the established fresh-login behavior between attempts.
#
# A wrapped command can return NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE to
# stop immediately. Callers should use that for a conclusively non-retryable
# condition they classify themselves. Other failures are retried because the
# wrapper is intentionally scoped only to read-only external network commands.
#
# Pure functions only. Do not enable shell options here because this file is
# sourced into callers that own their own strict-mode policy.

NETWORK_RETRY_MAX_ATTEMPTS="${NETWORK_RETRY_MAX_ATTEMPTS:-4}"
NETWORK_RETRY_BACKOFF_SECONDS="${NETWORK_RETRY_BACKOFF_SECONDS:-30}"
NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE="${NETWORK_RETRY_PERMANENT_FAILURE_EXIT_CODE:-99}"

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
