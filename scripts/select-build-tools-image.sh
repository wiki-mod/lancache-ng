#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# CI helper that picks which build-tools image a job should use: prefers the
# published ghcr.io build-tools image (smoke-tested for the required Rust/CI
# tooling), and falls back to building a branch-local image only for trusted
# refs (pushes, or same-repo pull requests) — untrusted forked pull requests
# never trigger a fallback build. Prints the chosen image reference on stdout.
set -euo pipefail

repository="${GITHUB_REPOSITORY:-wiki-mod/lancache-ng}"
published_image="ghcr.io/${repository}/build-tools:latest"
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

smoke_test_image() {
  local image="$1"

  docker run --rm "$image" bash -lc '
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
    )

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

trusted_fallback_allowed=false
if [[ "$event_name" = "pull_request" ]]; then
  [[ -n "$head_repository" && "$head_repository" = "$base_repository" ]] \
    && trusted_fallback_allowed=true
else
  trusted_fallback_allowed=true
fi

if [[ "$require_published" = "true" ]]; then
  if docker pull "$published_image" >"$pull_log" 2>&1 && smoke_test_image "$published_image"; then
    published_image_reference "$published_image"
    exit 0
  fi
  cat "$pull_log" >&2
  fail "published build-tools image is required for downstream jobs but was not pullable or did not satisfy smoke checks"
fi

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
