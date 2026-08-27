#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI helper that picks which build-tools image a job should use: prefers the
# published ghcr.io build-tools image (smoke-tested for the required Rust/CI
# tooling), and falls back to building a branch-local image only for trusted
# refs (pushes, or same-repo pull requests) — untrusted forked pull requests
# never trigger a fallback build. Prints the chosen image reference on stdout.
#
# IMPORTANT: This script resolves the mutable channel tag it selects (`:latest`
# or `:nightly`, see scripts/lib/build-tools-channel.sh's
# resolve_build_tools_channel) to its immutable digest-qualified reference
# before returning. Do not call this script expecting a mutable tag in the
# output; the returned reference is always pinned to a digest or a
# branch-local validation image.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/../lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/build-tools-channel.sh
source "$script_dir/../lib/build-tools-channel.sh"
# shellcheck source=scripts/lib/docker-buildx-retry.sh
source "$script_dir/../lib/docker-buildx-retry.sh"

repository="${GITHUB_REPOSITORY:-wiki-mod/lancache-ng}"

# Resolves to the mutable channel tag build-push.yml's own promote job would
# have just written for this exact ref (see scripts/lib/build-tools-channel.sh's
# resolve_build_tools_channel, updated by #1153 to match #1142/#825's
# master->latest / current_dev->nightly model), rather than hardcoding one
# channel for every ref -- `master` only moves `latest` on a stable vX.Y.Z
# release, so a PR targeting `master` needs a different, actively-maintained
# channel (`nightly`, fed by every `current_dev` push) to avoid the exact
# staleness issue #775 hit historically.
# GITHUB_BASE_REF (set only for pull_request events, to the PR's target
# branch) takes priority over GITHUB_REF_NAME so a PR opened from a feature
# branch still resolves against what it will actually merge into, not the
# feature branch's own name.
channel_ref="${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}"
build_tools_channel="$(resolve_build_tools_channel "$channel_ref")"
published_image="ghcr.io/${repository}/build-tools:${build_tools_channel}"
build_tools_context="${BUILD_TOOLS_CONTEXT:-tools/build-tools}"
fallback_image="${FALLBACK_IMAGE:-lancache-ng-build-tools-validation:${GITHUB_SHA:-local}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
event_name="${GITHUB_EVENT_NAME:-${EVENT_NAME:-}}"
head_repository="${GITHUB_EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME:-${HEAD_REPOSITORY:-}}"
base_repository="${GITHUB_REPOSITORY:-${BASE_REPOSITORY:-}}"
require_published="${BUILD_TOOLS_REQUIRE_PUBLISHED:-false}"
pull_log="$(mktemp)"

cleanup() {
  rm -f "$pull_log"
}
trap cleanup EXIT

fail() {
  printf 'select-build-tools-image: %s\n' "$1" >&2
  exit 1
}

# smoke_test_image verifies the provided image contains all required CI tools (cargo,
# rustc, distcc, docker, etc.) before it is trusted. The published channel tag (:latest or
# :nightly) is mutable and could become stale, broken, or missing tools between publication
# and use, so explicit verification is preferable to assuming the tag is current and valid.
smoke_test_image() {
  local image="$1"

  # EXTRA_REQUIRED_TOOLS lets a specific caller (e.g. the coverage job, which
  # needs cargo-tarpaulin) widen this check without forcing every other
  # consumer of this script (cargo-audit jobs, the plain compose-validation
  # path) to also require a tool they never use.
  docker run --rm -e "EXTRA_REQUIRED_TOOLS=${EXTRA_REQUIRED_TOOLS:-}" "$image" \
    timeout --kill-after=30 --signal=KILL 300 bash -lc '
    set -euo pipefail

    required_tools=(
      bash
      cargo
      rustc
      rustup
      rustfmt
      clippy-driver
      sccache
      ccache
      cargo-audit
      shellcheck
      actionlint
      bats
      shellspec
      distcc
      distcc-pump
      docker
      jq
      dig
      ip
      openssl
      rsync
      envsubst
      dhclient
      expect
      tcpdump
    )

    if [[ -n "${EXTRA_REQUIRED_TOOLS:-}" ]]; then
      read -ra extra_tools <<<"$EXTRA_REQUIRED_TOOLS"
      required_tools+=("${extra_tools[@]}")
    fi

    for tool in "${required_tools[@]}"; do
      command -v "$tool" >/dev/null
    done

    docker --version >/dev/null
    docker compose version >/dev/null
    # docker buildx is verified here now (issue #791). It was deliberately
    # deferred while #789 first added buildx to tools/build-tools/Dockerfile,
    # because this strict path (BUILD_TOOLS_REQUIRE_PUBLISHED callers have no
    # local-build fallback -- see the strict-mode branch below) trusts the
    # already-published :latest/:nightly image, which could not contain buildx
    # until after #789 merged and republished it. That has since happened, so
    # gating on it now no longer creates the chicken-and-egg failure #791
    # documents. The setup.sh assert_resolved_image_tag_platform_supported
    # check hard-requires buildx (issue #787), so a published image silently
    # missing it must fail this smoke test rather than surface deeper.
    # (No apostrophes in these comments: this whole block is a single-quoted
    # bash -lc argument, so a stray quote would terminate it -- see #833.)
    docker buildx version >/dev/null
    shellcheck --version >/dev/null
    actionlint --version >/dev/null
    # bats and shellspec are the two test-runner tools real consumer suites
    # depend on (tests/bats/*.bats via `bats tests/bats`; tests/shellspec via
    # shellspec). #790: the smoke test asserted neither, even though both are
    # installed and build-time-verified in tools/build-tools/Dockerfile --
    # exactly the derive-not-from-real-requirements drift #822 Pattern G
    # names. scripts/untracked/check-build-tools-smoke-coverage.sh now guards against
    # this list drifting from the Dockerfile verification list again.
    bats --version >/dev/null
    shellspec --version >/dev/null
    cargo-audit --version >/dev/null
    sccache --version >/dev/null
    distcc --version >/dev/null
    distcc-pump --help >/dev/null
    expect -v >/dev/null
  '
}

published_image_reference() {
  local image="$1" digest=""

  if digest="$(resolve_manifest_digest "$image")"; then
    printf '%s@%s\n' "${image%:*}" "$digest"
  else
    fail "could not resolve multi-platform manifest digest for $image"
  fi
}

# A forked pull request (head_repository != base_repository) is NOT allowed to trigger a
# fallback build, because untrusted PR code would get to build and run an arbitrary
# Dockerfile as part of this project's trusted CI infrastructure — a real supply-chain risk.
# Same-repo PRs and pushes are trusted because they went through this project's own
# contributor approval and branch-protection rules.
#
# Comparison is case-INSENSITIVE (issue #842 PR #1360, 2026-08-01, same bug
# class as scripts/lib/validation-image-tag.sh's vit_pr_staging_available() --
# see that file's identical comment for the full incident): GitHub repository
# names are case-insensitive for identity, but the two context values feeding
# this comparison are not guaranteed to agree on casing at every point in
# time, confirmed live during this repository's rename to `LanCache-NG`. A
# bare `=` here would misclassify a genuine same-repo PR as a fork PR, which
# for THIS specific check fails closed in the safe direction (no fallback
# build, not an unwanted one) -- but it's still the wrong answer for a
# trusted same-repo PR, and lowercasing both sides is strictly more correct,
# never less secure: it cannot make an actual fork PR compare equal, since
# two distinct repositories can never differ only in casing.
#
# Extracted into its own function purely for testability: this whole script
# has real side effects from its very first sourced line (docker pulls,
# GHCR logins, buildx calls), so it cannot be exercised end-to-end by a fast
# bats test the way scripts/lib/validation-image-tag.sh's pure helpers can.
# This one decision -- the security-relevant trust boundary this comment
# block documents -- is worth being able to test in isolation regardless;
# tests/bats/select_build_tools_image.bats sources just this function
# (same awk-extraction technique tests/bats/helpers/retention-helpers.sh
# already uses for services/watchdog/retention.sh) without executing the
# rest of this script's network/Docker calls.
select_build_tools_trusted_fallback_allowed() {
  local event_name="$1" head_repository="$2" base_repository="$3"
  if [[ "$event_name" = "pull_request" ]]; then
    [[ -n "$head_repository" && "${head_repository,,}" = "${base_repository,,}" ]]
  else
    return 0
  fi
}

trusted_fallback_allowed=false
if select_build_tools_trusted_fallback_allowed "$event_name" "$head_repository" "$base_repository"; then
  trusted_fallback_allowed=true
fi

# Strict mode (require_published=true): some callers opt in to use only the published
# image or fail outright — no silent fallback to a branch-local build. This is the right
# trade-off for jobs where an unvalidated fallback image would be worse than a hard failure.
if [[ "$require_published" = "true" ]]; then
  # #822: strict mode has no fallback below (a failed pull here hard-fails
  # the whole caller job), so this pull is the highest-value retry candidate
  # in this script. GHCR_RETRY_USERNAME/PASSWORD are optional -- most of this
  # script's many callers don't set them, and ghcr_retry still backs off and
  # retries without them, just without a fresh relogin between attempts.
  if ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$published_image" >"$pull_log" 2>&1 && smoke_test_image "$published_image"; then
    published_image_reference "$published_image"
    exit 0
  fi
  cat "$pull_log" >&2
  fail "published build-tools image is required for downstream jobs but was not pullable or did not satisfy smoke checks"
fi

# Three-tier cascade: on trusted refs (non-PR events), always build a branch-local
# validation image without trying the published one first, since trusted refs want to
# validate against exactly this branch's Dockerfile. On PR events, try the published
# image first and smoke-test it; only fall back to a branch-local build if the PR is
# same-repo (trusted). Forked PRs that fail the published image check get a hard error
# instead of a fallback build.
if [[ "$event_name" != "pull_request" ]]; then
  printf '::notice::Building a branch-local build-tools validation image for a trusted ref.\n' >&2
  # Wrapped (2026-07-29) after tracing current_dev's own `coverage (Rust)`
  # job failure to this exact unwrapped call: the golang:latest-toolchain-
  # internal panic documented in scripts/lib/docker-buildx-retry.sh actually
  # surfaced here, in this script's branch-local build-tools fallback build.
  docker_buildx_retry -- docker build --pull -t "$fallback_image" "$build_tools_context" >&2
  smoke_test_image "$fallback_image"
  printf '%s\n' "$fallback_image"
  exit 0
fi

if ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$published_image" >"$pull_log" 2>&1; then
  if smoke_test_image "$published_image"; then
    published_image_reference "$published_image"
    exit 0
  fi
  if [[ "$trusted_fallback_allowed" != "true" ]]; then
    cat "$pull_log" >&2
    fail "published build-tools image did not satisfy smoke checks and fallback builds are disabled for untrusted pull requests"
  fi
  printf '::notice::Published build-tools image did not satisfy smoke checks; using the controlled fallback path.\n' >&2
else
  if [[ "$trusted_fallback_allowed" != "true" ]]; then
    cat "$pull_log" >&2
    fail "published build-tools image could not be pulled and fallback builds are disabled for untrusted pull requests"
  fi
  printf '::notice::Published build-tools image is unavailable; using the controlled fallback path.\n' >&2
fi

if [[ "$trusted_fallback_allowed" != "true" ]]; then
  fail "published build-tools image is not usable and fallback builds are disabled for untrusted pull requests"
fi

printf '::notice::Building a branch-local build-tools validation image.\n' >&2
docker_buildx_retry -- docker build --pull -t "$fallback_image" "$build_tools_context" >&2
smoke_test_image "$fallback_image"
printf '%s\n' "$fallback_image"
