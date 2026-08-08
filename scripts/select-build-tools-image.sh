#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Selects a validated build-tools image for CI consumers. Published channel
# tags are resolved to immutable digests before they leave this helper.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/build-tools-channel.sh
source "$script_dir/lib/build-tools-channel.sh"
# shellcheck source=scripts/lib/docker-buildx-retry.sh
source "$script_dir/lib/docker-buildx-retry.sh"

repository="${GITHUB_REPOSITORY:-wiki-mod/lancache-ng}"
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

smoke_test_image() {
  local image="$1"

  # The outer workflow timeout alone cannot kill a hung process inside an
  # already-running container deterministically, so keep an in-container kill
  # deadline around this read-only capability check as well.
  docker run --rm \
    -e "EXTRA_REQUIRED_TOOLS=${EXTRA_REQUIRED_TOOLS:-}" \
    "$image" \
    timeout --kill-after=30 300 bash -lc '
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
      docker buildx version >/dev/null
      shellcheck --version >/dev/null
      actionlint --version >/dev/null
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
  local image="$1" raw_digest="" digest=""

  # Pull success does not prove that the later manifest lookup will also reach
  # the registry. Keep the final identity lookup inside the same GHCR retry and
  # fresh-login contract instead of converting a transport/auth failure into a
  # misleading generic "digest missing" result.
  raw_digest="$(
    ghcr_retry ghcr.io \
      "${GHCR_RETRY_USERNAME:-}" \
      "${GHCR_RETRY_PASSWORD:-}" \
      -- docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}'
  )" || fail "could not resolve multi-platform manifest digest for $image"

  digest="${raw_digest%\"}"
  digest="${digest#\"}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "registry returned an invalid multi-platform manifest digest for $image: ${digest:-<empty>}"
  printf '%s@%s\n' "${image%:*}" "$digest"
}

# Same-repository pull requests may use the controlled local fallback. Forked
# pull requests may not build and execute an arbitrary replacement Dockerfile
# on trusted project infrastructure. Repository identity is case-insensitive.
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

if [[ "$require_published" = "true" ]]; then
  if ghcr_retry ghcr.io \
      "${GHCR_RETRY_USERNAME:-}" \
      "${GHCR_RETRY_PASSWORD:-}" \
      -- docker pull "$published_image" >"$pull_log" 2>&1 \
      && smoke_test_image "$published_image"; then
    published_image_reference "$published_image"
    exit 0
  fi
  cat "$pull_log" >&2
  fail "published build-tools image is required for downstream jobs but was not pullable or did not satisfy smoke checks"
fi

# Trusted non-PR refs validate the branch-local Dockerfile directly.
if [[ "$event_name" != "pull_request" ]]; then
  printf '::notice::Building a branch-local build-tools validation image for a trusted ref.\n' >&2
  docker_buildx_retry -- docker build --pull -t "$fallback_image" "$build_tools_context" >&2
  smoke_test_image "$fallback_image"
  printf '%s\n' "$fallback_image"
  exit 0
fi

if ghcr_retry ghcr.io \
    "${GHCR_RETRY_USERNAME:-}" \
    "${GHCR_RETRY_PASSWORD:-}" \
    -- docker pull "$published_image" >"$pull_log" 2>&1; then
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

[[ "$trusted_fallback_allowed" == "true" ]] \
  || fail "published build-tools image is not usable and fallback builds are disabled for untrusted pull requests"

printf '::notice::Building a branch-local build-tools validation image.\n' >&2
docker_buildx_retry -- docker build --pull -t "$fallback_image" "$build_tools_context" >&2
smoke_test_image "$fallback_image"
printf '%s\n' "$fallback_image"
