#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI helper that picks which build-tools image a job should use: prefers the
# published ghcr.io build-tools image (smoke-tested for the required Rust/CI
# tooling), and falls back to building a branch-local image only for trusted
# refs (pushes, or same-repo pull requests) — untrusted forked pull requests
# never trigger a fallback build. Prints the chosen image reference on stdout.
#
# IMPORTANT: This script resolves the mutable channel tag it selects (`:dev`
# or `:edge`, see channel_ref below) to its immutable digest-qualified
# reference before returning. Do not call this script expecting a mutable tag
# in the output; the returned reference is always pinned to a digest or a
# branch-local validation image.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-wiki-mod/lancache-ng}"

# Resolves to the mutable channel tag build-push.yml's own promote job would
# have just written for this exact ref, instead of hardcoding `:latest`.
# `:latest` only moves on a stable vX.Y.Z release tag (release/stack-
# images.yml) -- and this project has not cut one yet (see
# full-setup-validate.yml's own image_tag comment) -- so it can sit stale for
# weeks while `:dev` (written on every push to a v[0-9]* integration branch
# such as v0.2.0) and `:edge` (written on every push to master) stay current.
# Confirmed directly during issue #775's investigation: `:latest` was still
# pinned to a build predating the Dockerfile's dhclient/expect additions
# while `:dev` already had them, which is exactly why a job asking for
# `BUILD_TOOLS_REQUIRE_PUBLISHED=true` kept silently getting a stale image.
# GITHUB_BASE_REF (set only for pull_request events, to the PR's target
# branch) takes priority over GITHUB_REF_NAME so a PR opened from a feature
# branch still resolves against what it will actually merge into, not the
# feature branch's own name.
channel_ref="${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-}}"
case "$channel_ref" in
  master)
    build_tools_channel="edge"
    ;;
  *)
    # Every other ref this script is realistically invoked against --
    # v0.2.0 itself, or a feature/claude/* branch forked from it without an
    # open PR yet (e.g. a manual workflow_dispatch run) -- is v0.2.0-line
    # work, so `dev` (the channel v0.2.0 pushes actually promote) is the
    # correct default rather than the stable-only `latest`.
    build_tools_channel="dev"
    ;;
esac
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
# rustc, distcc, docker, etc.) before it is trusted. The published channel tag (:dev or
# :edge) is mutable and could become stale, broken, or missing tools between publication
# and use, so explicit verification is preferable to assuming the tag is current and valid.
smoke_test_image() {
  local image="$1"

  # EXTRA_REQUIRED_TOOLS lets a specific caller (e.g. the coverage job, which
  # needs cargo-tarpaulin) widen this check without forcing every other
  # consumer of this script (cargo-audit jobs, the plain compose-validation
  # path) to also require a tool they never use.
  docker run --rm -e "EXTRA_REQUIRED_TOOLS=${EXTRA_REQUIRED_TOOLS:-}" "$image" bash -lc '
    set -euo pipefail

    required_tools=(
      bash
      cargo
      rustc
      rustup
      rustfmt
      clippy-driver
      sccache
      cargo-audit
      shellcheck
      actionlint
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
    shellcheck --version >/dev/null
    actionlint --version >/dev/null
    cargo-audit --version >/dev/null
    sccache --version >/dev/null
    distcc --version >/dev/null
    distcc-pump --help >/dev/null
    expect -v >/dev/null

    # python3-scapy has no standalone binary worth checking via command -v
    # (see tools/build-tools/Dockerfile'\''s own verification step for the
    # same caveat) -- verify the importable module scripts/dhcp-proxy-pxe-
    # simulation.sh actually depends on instead.
    python3 -c "import scapy.all"
  '
}

published_image_reference() {
  local image="$1" digest=""

  digest="$(docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}' 2>/dev/null || true)"
  digest="${digest%\"}"
  digest="${digest#\"}"
  if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
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
trusted_fallback_allowed=false
if [[ "$event_name" = "pull_request" ]]; then
  [[ -n "$head_repository" && "$head_repository" = "$base_repository" ]] \
    && trusted_fallback_allowed=true
else
  trusted_fallback_allowed=true
fi

# Strict mode (require_published=true): some callers opt in to use only the published
# image or fail outright — no silent fallback to a branch-local build. This is the right
# trade-off for jobs where an unvalidated fallback image would be worse than a hard failure.
if [[ "$require_published" = "true" ]]; then
  if docker pull "$published_image" >"$pull_log" 2>&1 && smoke_test_image "$published_image"; then
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
  docker build --pull -t "$fallback_image" "$build_tools_context" >&2
  smoke_test_image "$fallback_image"
  printf '%s\n' "$fallback_image"
  exit 0
fi

if docker pull "$published_image" >"$pull_log" 2>&1; then
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
docker build --pull -t "$fallback_image" "$build_tools_context" >&2
smoke_test_image "$fallback_image"
printf '%s\n' "$fallback_image"
