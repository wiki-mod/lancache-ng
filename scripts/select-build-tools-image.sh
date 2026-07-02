#!/usr/bin/env bash
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

trusted_fallback_allowed=false
if [[ "$event_name" = "pull_request" ]]; then
  [[ -n "$head_repository" && "$head_repository" = "$base_repository" ]] \
    && trusted_fallback_allowed=true
else
  trusted_fallback_allowed=true
fi

if [[ "$require_published" = "true" ]]; then
  if docker pull "$published_image" >"$pull_log" 2>&1 && smoke_test_image "$published_image"; then
    printf '%s\n' "$published_image"
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
    printf '%s\n' "$published_image"
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
