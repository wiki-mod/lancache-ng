#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Retry wrapper for a `git fetch` invocation, following this project's
# established AG-CI-013 pattern (scripts/lib/ghcr-retry.sh for registry
# operations, scripts/lib/build-retry.sh for a full local image build) for a
# new class of flaky CI operation: fetching a base branch/exact base SHA over
# the network from a workflow's own `run:` step, which had no retry wrapper
# at all before this file existed. A `git fetch` against GitHub's own
# infrastructure can fail transiently the same way any other network call to
# it can (a dropped connection, a transient 5xx, a DNS hiccup on the runner
# host) -- but unlike ghcr_retry's registry pulls/pushes, a `git fetch`
# failure can also be a genuine, permanent condition (an unknown ref, a
# force-pushed-away SHA no longer reachable, a real auth/permission problem)
# that must never be blindly retried, matching AG-CI-013's explicit
# requirement to "distinguish retryable transient signatures from genuine
# failures."
#
# Deliberately NOT `set -euo pipefail` at the top level: this file only
# defines a function for a caller to invoke under the caller's own shell
# options, mirroring scripts/lib/ghcr-retry.sh's identical note.

GIT_FETCH_RETRY_MAX_ATTEMPTS="${GIT_FETCH_RETRY_MAX_ATTEMPTS:-4}"
GIT_FETCH_RETRY_BACKOFF_SECONDS="${GIT_FETCH_RETRY_BACKOFF_SECONDS:-10}"

# Known-transient signatures a `git fetch` over HTTPS can emit for a dropped
# connection, a transient server-side error, or a runner-host DNS hiccup --
# never for a genuinely missing/renamed ref or an auth failure, which must
# still fail on the very first attempt with the real error intact.
_git_fetch_retry_is_transient() {
    local output="$1"
    case "$output" in
        *'early EOF'* | \
        *'unexpected disconnect'* | \
        *'The remote end hung up unexpectedly'* | \
        *'Connection reset by peer'* | \
        *'Connection timed out'* | \
        *'Failed to connect '*'Could not connect to server'* | \
        *'Could not resolve host'* | \
        *'Temporary failure in name resolution'* | \
        *'The requested URL returned error: 429'* | \
        *'The requested URL returned error: 5'[0-9][0-9]* | \
        *'RPC failed; HTTP 429 '* | \
        *'RPC failed; HTTP 5'[0-9][0-9]' '* | \
        *'RPC failed; curl 92 HTTP/2 stream '*'was not closed cleanly'* | \
        *'RPC failed; curl 5'* | \
        *'GnuTLS recv error'* | \
        *'TLS connection'*'closed'*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# git_fetch_retry <git fetch argument>...
# Runs `git fetch "$@"`, retrying up to GIT_FETCH_RETRY_MAX_ATTEMPTS times
# (with a fixed GIT_FETCH_RETRY_BACKOFF_SECONDS backoff between attempts)
# only when the captured output matches a known-transient signature above.
# Any other failure -- including the first attempt's own -- propagates
# immediately, preserving the real error text on stderr for the caller.
git_fetch_retry() {
    local attempt=1 output status
    while :; do
        # `status=$?` must live in an explicit `else`, not merely after the
        # closing `fi` of a then-only `if` -- the same bug class
        # scripts/lib/ghcr-retry.sh's own ghcr_retry() already documents and
        # guards against: per POSIX, an `if...then...fi` with no `else`
        # clause and a false condition reports the WHOLE if-construct's own
        # exit status (0, "success") on the next `$?` read, not the failing
        # condition's real exit status. Reading `$?` immediately after `fi`
        # in that shape silently captures 0 every time, making every failure
        # look like a success one line later -- reproduced directly here
        # (`if false; then :; fi; echo $?` prints 0) before this file's
        # first version shipped with exactly that bug.
        if output="$(git fetch "$@" 2>&1)"; then
            [ -n "$output" ] && printf '%s\n' "$output"
            return 0
        else
            status=$?
        fi
        printf '%s\n' "$output" >&2
        if [ "$attempt" -ge "$GIT_FETCH_RETRY_MAX_ATTEMPTS" ] || ! _git_fetch_retry_is_transient "$output"; then
            return "$status"
        fi
        echo "git_fetch_retry: transient failure on attempt $attempt/$GIT_FETCH_RETRY_MAX_ATTEMPTS, retrying in ${GIT_FETCH_RETRY_BACKOFF_SECONDS}s..." >&2
        sleep "$GIT_FETCH_RETRY_BACKOFF_SECONDS"
        attempt=$((attempt + 1))
    done
}
