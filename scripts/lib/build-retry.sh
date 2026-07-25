#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Retry wrapper for a full `docker buildx build` invocation, scoped to one
# specific transient failure signature -- NOT a general-purpose "retry any
# nonzero exit" wrapper like scripts/lib/ghcr-retry.sh's ghcr_retry(). That
# distinction matters here: ghcr_retry wraps registry push/pull/imagetools
# calls, where every realistic failure mode (a transient 401, a dropped
# connection) is itself something a retry can plausibly fix. A full image
# build is different -- most of its failure modes (a broken Dockerfile
# instruction, a real compile error in the image's toolchain, a bad
# build-arg) are NOT transient, and blindly retrying one would just delay
# the same deterministic failure two or three more times before finally
# surfacing it. So build_retry() inspects the captured build output and only
# retries when it matches the one known-transient signature; anything else
# fails immediately with the real error intact.
#
# Added for issue #1222: build-tools.yml's "Build local amd64 scan image"
# step (a `docker buildx build` against tools/build-tools on the self-hosted
# amd64 runner pool) failed at least four times on 2026-07-24, across
# different PRs (#1117, #1179, #1206, #1209), with the identical error:
#
#   ERROR: (*service).Write failed: rpc error: code = Unavailable desc = ref
#   layer-sha256:...  locked for <N>ms (since <timestamp>): unavailable
#
# Root cause (per #1222's own investigation): this is host-level contention
# on a shared base-image layer in the containerd content store, surfacing
# when multiple jobs on the same self-hosted runner pool
# ([self-hosted, linux, lancache, lancache-heavy]) build concurrently. It is
# not two jobs sharing one Buildx builder instance (docker/setup-buildx-action
# gives every job its own fresh, uniquely-named docker-container builder) and
# it is not the same race the job's own "Prepare local Buildx cache" step
# already guards with flock (that step protects this project's own shared
# cache directory, a different resource). This class of error is normally
# absorbed by a client-side retry; nothing in the workflow had one.
#
# AG-CI-013 (AGENTS.md) requires exactly this: a documented retry wrapper
# matching this project's established pattern for flaky external CI
# operations, one that "must distinguish retryable transient signatures from
# genuine failures".
#
# Sourced directly by build-tools.yml's own `run:` step (same convention
# ghcr-retry.sh already documents and uses: a plain `source
# "$GITHUB_WORKSPACE/scripts/lib/build-retry.sh"`, not a composite action).
# A composite action wrapping `uses: docker/build-push-action` (the shape
# .github/actions/ghcr-build-push-retry and .github/actions/buildx-setup-retry
# use) was considered and rejected: those two actions can blindly retry any
# failure because every failure they wrap IS the transient case by
# construction, but this wrapper must inspect the actual build log text to
# tell a transient layer-lock apart from a real Dockerfile/compile error --
# and a `uses:` step's own stdout/stderr is written straight to the job log,
# not exposed to a later step as a readable output. A plain shell `run:` step
# invoking `docker buildx build` directly, with its combined output captured
# to a file this wrapper can grep, is what a signature-conditional retry
# actually requires.
#
# Deliberately NOT `set -euo pipefail` at the top level, same reasoning as
# ghcr-retry.sh: this file only defines functions for a caller to invoke
# under the caller's own shell options.

BUILD_RETRY_MAX_ATTEMPTS="${BUILD_RETRY_MAX_ATTEMPTS:-3}"
BUILD_RETRY_BASE_BACKOFF_SECONDS="${BUILD_RETRY_BASE_BACKOFF_SECONDS:-10}"

# The exact signature from issue #1222's four real failures (#1117, #1179,
# #1206, #1209) -- only the digest/duration/timestamp ever varied between
# occurrences. Deliberately narrow (not a bare "locked for" or "Unavailable"
# match): it requires both the specific gRPC service-write error class AND
# the "locked for <N>ms" wording together, so a real Dockerfile/compile
# failure (which never produces this exact combination) cannot be
# misidentified as transient.
BUILD_RETRY_TRANSIENT_PATTERN='\(\*service\)\.Write failed: rpc error: code = Unavailable.*locked for [0-9]+ms'

# build_retry_is_transient_failure <logfile>
#
# Returns success (0) if <logfile> contains the known transient BuildKit
# content-store layer-lock signature, nonzero otherwise. Split out from
# build_retry() itself so it can be unit-tested directly against the real
# historical error text (see tests/bats/build_retry.bats) without having to
# drive a whole fake build through the retry loop.
build_retry_is_transient_failure() {
  local logfile="${1:?build_retry_is_transient_failure: log file is required}"
  grep -Eq "$BUILD_RETRY_TRANSIENT_PATTERN" "$logfile"
}

# build_retry -- <command...>
#
# Runs <command> up to $BUILD_RETRY_MAX_ATTEMPTS times, capturing its
# combined stdout+stderr to a temp file on each attempt (streamed through
# `tee` so the caller's own job log still shows everything in real time --
# nothing is hidden while waiting to decide whether to retry). Returns 0 as
# soon as an attempt succeeds.
#
# On a failed attempt, checks the captured output with
# build_retry_is_transient_failure: if it does NOT match the known transient
# signature, this is treated as a genuine failure (a real Dockerfile syntax
# error, a compile failure, a bad build-arg, ...) and build_retry returns
# immediately with that attempt's exit status -- it is never retried, so a
# real bug is never masked or merely delayed by this wrapper. Only a matching
# transient failure is retried, with exponential backoff
# ($BUILD_RETRY_BASE_BACKOFF_SECONDS * 2^(attempt-1): 10s, then 20s by
# default) between attempts.
build_retry() {
  if [[ "${1:-}" != "--" ]]; then
    echo "::error::build_retry: expected -- before the command to run" >&2
    return 2
  fi
  shift

  local attempt=1
  local status=0
  local logfile
  logfile="$(mktemp)"

  while (( attempt <= BUILD_RETRY_MAX_ATTEMPTS )); do
    : > "$logfile"

    # Deliberately `if "$@" 2>&1 | tee "$logfile"; then status=0; else
    # status="${PIPESTATUS[0]}"; fi`, not a bare pipeline statement followed
    # by reading `${PIPESTATUS[0]}` after the fact: under a caller's
    # `set -e`/`set -o pipefail` (every workflow `run:` step in this repo
    # sets both), a bare failing pipeline aborts the script on the spot,
    # before build_retry ever gets to inspect the log or decide whether to
    # retry -- the exact footgun scripts/lib/ghcr-retry.sh's own ghcr_retry()
    # already documents and avoids for the same reason. Keeping the pipeline
    # in `if` condition position neutralizes both `-e` and `pipefail` for
    # this one statement; `${PIPESTATUS[0]}` (not `$?`, which after a
    # pipeline reports `tee`'s own exit status) is the tested command's real
    # exit code.
    if "$@" 2>&1 | tee "$logfile"; then
      status=0
    else
      status="${PIPESTATUS[0]}"
    fi

    if (( status == 0 )); then
      rm -f "$logfile"
      return 0
    fi

    if ! build_retry_is_transient_failure "$logfile"; then
      echo "::error::Build failed with a non-transient error (exit ${status}); failing fast without retry: $*" >&2
      rm -f "$logfile"
      return "$status"
    fi

    if (( attempt >= BUILD_RETRY_MAX_ATTEMPTS )); then
      echo "::error::Build failed after ${BUILD_RETRY_MAX_ATTEMPTS} attempts, every one matching the transient BuildKit layer-lock signature (exit ${status}): $*" >&2
      rm -f "$logfile"
      return "$status"
    fi

    local backoff=$(( BUILD_RETRY_BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)) ))
    echo "::warning::Build failed with the transient BuildKit content-store layer-lock signature (attempt ${attempt}/${BUILD_RETRY_MAX_ATTEMPTS}, exit ${status}); waiting ${backoff}s before retry: $*" >&2
    sleep "$backoff"
    attempt=$((attempt + 1))
  done

  rm -f "$logfile"
  return "$status"
}
