#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Resolves one exact Git remote ref with bounded retries for transient failures.

set -euo pipefail

remote="${1:?usage: resolve-remote-ref-with-retry.sh REMOTE REF}"
ref="${2:?usage: resolve-remote-ref-with-retry.sh REMOTE REF}"
max_attempts="${REMOTE_REF_MAX_ATTEMPTS:-4}"
backoff_seconds="${REMOTE_REF_BACKOFF_SECONDS:-30}"

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    # --exit-code distinguishes a missing ref from a successful empty query;
    # both are retryable because a transient remote failure can present either way.
    if output="$(git ls-remote --exit-code "$remote" "$ref")" && [[ -n "$output" ]]; then
        printf '%s\n' "${output%%$'\t'*}"
        exit 0
    fi

    if ((attempt == max_attempts)); then
        printf '::warning::Remote ref lookup failed after %d attempts: %s %s\n' \
            "$max_attempts" "$remote" "$ref" >&2
        exit 1
    fi

    printf '::warning::Remote ref lookup failed (attempt %d/%d); retrying in %ss: %s %s\n' \
        "$attempt" "$max_attempts" "$backoff_seconds" "$remote" "$ref" >&2
    sleep "$backoff_seconds"
done
