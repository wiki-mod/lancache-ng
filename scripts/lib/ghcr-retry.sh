#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Shared retry + fresh-re-login wrapper for GHCR registry operations (docker
# login/pull/push, `docker buildx imagetools create|inspect`, etc.).
#
# Extracted from .github/workflows/build-push.yml's build/build-arm64 jobs
# ("Wait before retrying the push" / "Re-authenticate to GHCR before retry" /
# "Retry Build and push", added by #541) so every registry call site in the
# project shares one retry policy instead of re-implementing it ad hoc. #541
# only ever covered those two jobs; issue #822 ("Pattern D") found every other
# registry-writing (and several registry-reading) call site in the project
# still had a single bare attempt with no retry, including the exact step
# that failed three times live on 2026-07-14 and the "merge multi-platform
# manifests" job that failed live on 2026-07-13 with a real
# "401 Unauthorized: unauthenticated" log.
#
# Pure functions, no top-level executable code: sourced directly both by
# plain scripts (scripts/ensure-pr-staging-images.sh,
# scripts/require-image-platforms.sh) and by workflow `run:` steps (which
# source it via "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh", the same
# convention scripts/lib/reserve-validation-subnet.sh already uses). Kept out
# of a composite action for the shell case specifically because embedding an
# arbitrary caller's multi-line shell (heredocs, associative arrays, `trap`)
# as a composite-action string input is fragile; sourcing this file directly
# in the caller's own `run:` block keeps the caller's real environment,
# quoting, and control flow intact. `docker/build-push-action` and
# `actions/attest` are `uses:` steps (not shell), so those get their own
# composite-action retry wrappers instead
# (.github/actions/ghcr-build-push-retry, .github/actions/ghcr-attest-retry) --
# see those files for why a `uses:` step can't just call into this one.
#
# Deliberately NOT `set -euo pipefail` at the top level: this file only
# defines functions for a caller to invoke under the caller's own shell
# options, and forcing strict mode here would do nothing (functions inherit
# the invoking shell's options) while looking misleading to a reader.

# Retry/backoff policy shared by every call site. Extends #541's pattern (one
# retry, 30s backoff -> 2 total attempts) to at least 3 retries (4 total
# attempts) per the #822 fix -- overridable via env (e.g. for
# tests/bats/*_ghcr_retry.bats) but the defaults must stay in sync by hand
# with .github/actions/ghcr-build-push-retry and .github/actions/ghcr-attest-retry's
# own `max-attempts`/`backoff-seconds` input defaults, since GitHub Actions
# composite-action YAML cannot source a Bash variable from this file.
GHCR_RETRY_MAX_ATTEMPTS="${GHCR_RETRY_MAX_ATTEMPTS:-4}"
GHCR_RETRY_BACKOFF_SECONDS="${GHCR_RETRY_BACKOFF_SECONDS:-30}"

# ghcr_relogin <registry> <username> <password>
#
# Fresh re-authentication via `docker login --password-stdin`, not a nested
# `docker/login-action` step: this file runs identically from a raw script
# and from a workflow `run:` step, and login-action is a JS action that only
# exists as a workflow step -- it cannot be sourced or called from arbitrary
# Bash. `--password-stdin` keeps the token out of the process command line
# (invisible to a concurrent `ps` on the same runner).
ghcr_relogin() {
  local registry="${1:?ghcr_relogin: registry is required}"
  local username="${2:?ghcr_relogin: username is required}"
  local password="${3:?ghcr_relogin: password is required}"

  # `docker login` prints "Login Succeeded" to STDOUT (only the
  # credential-store warning goes to stderr). ghcr_retry is routinely called
  # from a caller's `$(...)` command substitution to capture a digest/output
  # (e.g. `digest="$(ghcr_retry ... -- docker buildx imagetools inspect ...)"`),
  # and a retry that fires *during* that same substitution would otherwise
  # splice "Login Succeeded" into the captured value -- corrupting exactly the
  # transient-401 retry case this file exists to survive. Redirect to stderr
  # so relogin output never lands in a caller's stdout capture.
  printf '%s' "$password" | docker login "$registry" --username "$username" --password-stdin >&2
}

# ghcr_retry <registry> <username> <password> -- <command> [args...]
#
# Runs <command> up to $GHCR_RETRY_MAX_ATTEMPTS times. On every failed
# attempt except the last, sleeps $GHCR_RETRY_BACKOFF_SECONDS, then -- if
# both <username> and <password> are non-empty -- calls ghcr_relogin before
# retrying. Returns the final attempt's exit status.
#
# <registry> is always required, but <username>/<password> may each be an
# empty string: a caller with no credentials in scope (e.g.
# scripts/require-image-platforms.sh run ad hoc outside CI) still gets
# backoff+retry, just without a fresh login between attempts -- strictly
# better than the single bare attempt every call site had before #822, even
# without credentials to relogin with.
#
# Re-logs-in before every retry (not just once) when credentials are given:
# #822 could not distinguish between "the registry itself was transiently
# unavailable" and "the earlier login session's push token had already gone
# stale" as the root cause, and a fresh login costs nothing extra if the real
# cause was the former.
#
# <command>'s own stdout/stderr pass through untouched on every attempt
# (including failed ones) -- callers that capture output via `$(...)` rely on
# a failed `docker buildx imagetools inspect`/`create` writing nothing to
# stdout on failure (true for every call site this wraps today; a future
# caller capturing output from a command that violates this must not use
# ghcr_retry as-is).
ghcr_retry() {
  local registry="${1:?ghcr_retry: registry is required}"
  local username="${2-}"
  local password="${3-}"
  shift 3
  if [[ "${1:-}" != "--" ]]; then
    echo "::error::ghcr_retry: expected -- before the command to run" >&2
    return 2
  fi
  shift

  local attempt=1
  local status=0
  while (( attempt <= GHCR_RETRY_MAX_ATTEMPTS )); do
    # Deliberately `if "$@"; then status=0; else status=$?; fi`, not the more
    # obvious `if "$@"; then return 0; fi` followed by `status=$?`: when an
    # `if` with no `else` takes the false branch, bash defines the compound
    # statement's OWN exit status as 0 -- a bare `status=$?` read right after
    # such an `if` always sees 0, never the tested command's real failure
    # code, so ghcr_retry would silently report success after every attempt
    # was exhausted (caught live: a forced-failure smoke test returned 0
    # even though the wrapped command failed every single attempt). Keeping
    # "$@" in if-condition position (not a bare statement) also keeps this
    # safe under a caller's `set -e` -- a command tested by if/while/until
    # does not trigger -e even when it fails.
    if "$@"; then
      status=0
    else
      status=$?
    fi
    if (( status == 0 )); then
      return 0
    fi
    if (( attempt >= GHCR_RETRY_MAX_ATTEMPTS )); then
      echo "::error::GHCR operation failed after ${GHCR_RETRY_MAX_ATTEMPTS} attempts (exit ${status}): $*" >&2
      return "$status"
    fi
    echo "::warning::GHCR operation failed (attempt ${attempt}/${GHCR_RETRY_MAX_ATTEMPTS}, exit ${status}); waiting ${GHCR_RETRY_BACKOFF_SECONDS}s before retry: $*" >&2
    sleep "$GHCR_RETRY_BACKOFF_SECONDS"
    if [[ -n "$username" && -n "$password" ]]; then
      if ! ghcr_relogin "$registry" "$username" "$password"; then
        echo "::warning::Re-authentication before retry failed; the retried command may fail again for the same auth reason." >&2
      fi
    else
      echo "::warning::No credentials passed to ghcr_retry; retrying without a fresh login." >&2
    fi
    attempt=$((attempt + 1))
  done
  return "$status"
}
