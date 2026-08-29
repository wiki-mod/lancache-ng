#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Retry wrapper for a *local* `docker buildx build` invocation, specifically
# for the transient BuildKit/containerd content-store race confirmed live at
# least 4 times on 2026-07-24 across PRs #1117, #1179, #1206, #1209, always
# the identical signature, always inside the actual `docker buildx build`
# step (never docker/setup-buildx-action's own bootstrap -- that class of
# failure is a different signature and already covered separately by
# .github/actions/buildx-setup-retry, see issue #930):
#
#   ERROR: (*service).Write failed: rpc error: code = Unavailable desc = ref
#   layer-sha256:<digest> locked for <N>ms (since <timestamp>): unavailable
#
# docker/setup-buildx-action creates a fresh, isolated docker-container
# builder per job (confirmed: cleanup logs show a unique builder-<uuid> name
# every run), so this is not two jobs racing on one shared builder instance
# -- it is contention on a shared base-image layer at the host Docker
# daemon/containerd content-store level, surfacing whenever multiple jobs on
# the same self-hosted runner host build concurrently. This class of error is
# normally absorbed by a client-side retry; build-tools.yml's local scan
# builds had none.
#
# Second confirmed transient signature (2026-07-29, a current_dev
# Build & Push run's `coverage (Rust)` job):
#
#   panic: methodref has no signature
#
# A genuine Go compiler/toolchain-internal panic, surfaced inside
# tools/build-tools/Dockerfile's go-tools-builder stage (renamed from
# actionlint-builder in PR #1743 once actionlint moved off this
# stage) while building docker-buildx/docker-cli/docker-compose from
# source. That stage
# deliberately uses `FROM golang:latest` (and the image's final stage
# `FROM rust:latest`) rather than a pinned digest -- an intentional,
# documented exception to this project's general image-pinning policy (see
# docs/ci-image-pinning-policy.md and this Dockerfile's own top-of-file
# comment), so that CI/developer validation always sees current Go/Rust
# tooling without needing manual pin-bump PRs. That freshness has a real
# cost: an unpinned upstream toolchain can occasionally hit an internal
# compiler bug tied to a specific, transient version snapshot -- confirmed
# non-reproducible: a from-scratch `--no-cache` rebuild of the identical,
# unmodified Dockerfile on a self-hosted runner immediately afterward
# succeeded cleanly with no panic. Reverting to a pinned digest would trade
# away the "always current" property this Dockerfile explicitly chose
# (maintainer decision, 2026-07-29); retrying here preserves that choice
# while absorbing this specific, rare toolchain-version-drift failure mode
# instead of blocking CI on it.
#
# Unlike scripts/lib/ghcr-retry.sh's ghcr_retry (which blindly retries any
# nonzero exit -- appropriate there, because every failure mode a registry
# push/pull/inspect call can hit is itself transient or auth-shaped), a full
# `docker buildx build` can also fail for entirely real reasons: a Dockerfile
# syntax error, a genuine compile or test failure inside the build. Blindly
# retrying those would not just waste up to
# DOCKER_BUILDX_RETRY_MAX_ATTEMPTS x the full build time on every real
# failure, it would delay real feedback to the PR author for no benefit. So
# docker_buildx_retry below inspects the wrapped command's own combined
# stdout+stderr for the exact transient signature before deciding to retry --
# a real build failure whose output does not contain that signature fails
# immediately on its first attempt, exactly like an unwrapped invocation
# would.
#
# Pure functions, no top-level executable code -- sourced the same way
# ghcr-retry.sh is, directly from a workflow `run:` step via
# "$GITHUB_WORKSPACE/scripts/lib/docker-buildx-retry.sh".
#
# Deliberately NOT `set -euo pipefail` at the top level, for the identical
# reason ghcr-retry.sh gives: this file only defines functions for a caller
# to invoke under the caller's own shell options.

DOCKER_BUILDX_RETRY_MAX_ATTEMPTS="${DOCKER_BUILDX_RETRY_MAX_ATTEMPTS:-4}"
DOCKER_BUILDX_RETRY_BACKOFF_SECONDS="${DOCKER_BUILDX_RETRY_BACKOFF_SECONDS:-30}"

# The historical failures' error text, loosened only where the real payload
# varies run to run (the layer digest, the lock duration in ms, the lock
# timestamp). Anchored on the stable, load-bearing tokens
# ("code = Unavailable", "locked for", ": unavailable") rather than the
# literal digest/duration/timestamp, which is what makes this match every
# observed occurrence while still not matching an unrelated error that
# happens to mention "unavailable" on its own. Extended regex, matched
# line-by-line (buildx emits this as a single line) -- no multiline mode
# needed.
#
# Second alternative: the exact, literal "panic: methodref has no signature"
# text of the golang:latest-toolchain-internal-panic signature documented
# above. Deliberately the full literal string (no varying payload to loosen
# around, unlike the layer-lock signature) -- narrow and specific on purpose,
# so this alternation only ever matches this one confirmed Go-internal panic
# message, never a broader "panic:" from a real, code-caused failure
# elsewhere in the build.
DOCKER_BUILDX_RETRY_TRANSIENT_PATTERN='\(\*service\)\.Write failed: rpc error: code = Unavailable desc = ref [^ ]+ locked for [0-9]+ms \(since [^)]*\): unavailable|panic: methodref has no signature'

# docker_buildx_retry -- <command...>
#
# Runs <command> up to $DOCKER_BUILDX_RETRY_MAX_ATTEMPTS times.
#
# Every attempt's combined stdout+stderr streams live to the caller's own
# stdout via `tee` -- identical to what an unwrapped invocation would print,
# nothing hidden or delayed -- and is also captured to a temp file so a
# failed attempt's output can be inspected for the transient signature above.
#
# - Exit 0: returns 0 immediately.
# - Nonzero exit and the captured output matches the transient signature and
#   attempts remain: waits $DOCKER_BUILDX_RETRY_BACKOFF_SECONDS, retries.
# - Nonzero exit and the captured output does NOT match the transient
#   signature: returns that exit status immediately, no retry -- this is
#   what keeps a real Dockerfile/compile failure from being masked or merely
#   delayed by a retry that could never fix it.
# - Nonzero exit that does match, but this was the last attempt: returns that
#   exit status.
docker_buildx_retry() {
  if [[ "${1:-}" != "--" ]]; then
    echo "::error::docker_buildx_retry: expected -- before the command to run" >&2
    return 2
  fi
  shift

  local log_file
  log_file="$(mktemp)"
  # Local to this function invocation (not the whole sourcing shell), so a
  # caller invoking docker_buildx_retry more than once in the same script
  # never leaks a previous call's temp file path or leaves it behind on this
  # call's own early return.
  # shellcheck disable=SC2064 # intentional immediate expansion of $log_file
  trap "rm -f '$log_file'" RETURN

  local attempt=1
  local status=0
  while (( attempt <= DOCKER_BUILDX_RETRY_MAX_ATTEMPTS )); do
    : > "$log_file"
    # A caller's `set -e` must never abort mid-retry-loop on a failing
    # attempt (same reasoning ghcr_retry documents for its own bare
    # command), so errexit is suspended for exactly this one pipeline and
    # restored right after. Relying on the caller having `pipefail` set (as
    # an earlier version of this comment assumed "every workflow run: step
    # in this repo sets this") is not a safe basis for this function's own
    # correctness: this file is sourced into whatever shell state the
    # caller happens to have, and if pipefail is ever NOT active there (a
    # bats test harness sourcing this file directly, for one -- see the
    # identical bug found and fixed in scripts/lib/build-retry.sh),
    # `if cmd1 | cmd2; then` branches on cmd2's exit status (`tee`, which
    # essentially always succeeds), so the status=0/else-PIPESTATUS split
    # above would take the true-branch and silently record status=0 even
    # when "$@" itself failed. PIPESTATUS[0] is populated correctly for the
    # just-executed pipeline regardless of pipefail, so long as it is read
    # as the statement immediately following the pipe -- not even a no-op
    # command may run in between, since executing any command starts a new
    # pipeline and overwrites PIPESTATUS first.
    local errexit_was_set=0
    case "$-" in *e*) errexit_was_set=1 ;; esac
    set +e
    "$@" 2>&1 | tee "$log_file"
    status="${PIPESTATUS[0]}"
    (( errexit_was_set )) && set -e

    if (( status == 0 )); then
      return 0
    fi

    if ! grep -qE "$DOCKER_BUILDX_RETRY_TRANSIENT_PATTERN" "$log_file"; then
      echo "::error::docker_buildx_retry: command failed (exit ${status}) without the known transient layer-lock signature; not retrying (real failure): $*" >&2
      return "$status"
    fi

    if (( attempt >= DOCKER_BUILDX_RETRY_MAX_ATTEMPTS )); then
      echo "::error::docker_buildx_retry: command still failing with the transient layer-lock signature after ${DOCKER_BUILDX_RETRY_MAX_ATTEMPTS} attempts (exit ${status}): $*" >&2
      return "$status"
    fi

    echo "::warning::docker_buildx_retry: transient layer-lock error detected (attempt ${attempt}/${DOCKER_BUILDX_RETRY_MAX_ATTEMPTS}, exit ${status}); waiting ${DOCKER_BUILDX_RETRY_BACKOFF_SECONDS}s before retry: $*" >&2
    sleep "$DOCKER_BUILDX_RETRY_BACKOFF_SECONDS"
    attempt=$((attempt + 1))
  done
  return "$status"
}
