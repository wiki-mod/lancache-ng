#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI helper that picks which utilities image the seven real consumers build
# against: prefers the published ghcr.io utilities image, smoke-tested for
# the structural shape those consumers' COPY lines actually need, and falls
# back to building a branch-local image only for trusted refs (pushes, or
# same-repo pull requests) -- untrusted forked pull requests never trigger a
# fallback build. Prints the chosen image reference on stdout.
#
# What: closes the gap the curl restructure left open, which
#   AGENTS.md's AG-KD-010 already anticipated ("BUILD_TOOLS_IMAGE's own
#   resolution mechanism ... was never extended to it [utilities]"): a PR
#   that changes both services/utilities/Dockerfile's internal layout and
#   consumer COPY paths in the same commit cannot validate consumers
#   against ITS OWN utilities build within that same PR's CI run (GitHub
#   Actions matrix entries in one job cannot depend on a sibling entry) --
#   the published :latest/:nightly tag consumers actually resolve against
#   is always the LAST-PROMOTED one, from before this PR's own utilities
#   change. Before this script, a structural change like this (curl moves
#   from /usr/local/bin/curl to /usr/bin/curl, plus twelve new shared
#   libraries that do not exist in the old image at all) would make every
#   consumer's
#   COPY --from=utilities-tools fail with a raw "not found" error against the
#   stale published image, on every affected PR's first build, until
#   current_dev merges and republishes. This script does not eliminate that
#   race (a full fix needs the seven consumers' own matrix entries to depend
#   on the SAME PR's own utilities build, a materially larger CI-graph
#   change out of this script's scope) -- it turns the failure from a raw
#   Docker COPY error into a smoke-tested, explicit "the published image is
#   stale for this structural change" signal, and self-heals via the same
#   trusted branch-local fallback build already established for
#   BUILD_TOOLS_IMAGE by select-build-tools-image.sh, whose overall shape
#   this script deliberately mirrors.
#
# IMPORTANT: unlike select-build-tools-image.sh, this script's own fallback
# build is also pushed to ghcr.io and resolved to a digest-qualified
# reference exactly like the published-image path (see the push step below
# for why a purely local tag cannot work here). Every exit path -- published
# or fallback -- returns an immutable digest-qualified reference; there is
# no bare/mutable-tag output to expect from this script.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/../lib/ghcr-retry.sh"
# shellcheck source=scripts/lib/docker-buildx-retry.sh
source "$script_dir/../lib/docker-buildx-retry.sh"

repository="${GITHUB_REPOSITORY:-wiki-mod/lancache-ng}"
published_image="ghcr.io/${repository}/utilities:latest"
# What: :latest has never actually been published (see build-push.yml's own
#   "Resolve utilities image digest" step comment this replaces) -- :nightly
#   is the real, currently-live channel, tried second so a future :latest
#   publication is still preferred the moment it exists.
published_fallback_image="ghcr.io/${repository}/utilities:nightly"
utilities_context="${UTILITIES_CONTEXT:-services/utilities}"
# What: a ghcr.io tag, not a bare local one (see push below).
# Why: the downstream buildx builder cannot see a local tag.
# From: Issue #1781 | PR #1783
fallback_image="${FALLBACK_IMAGE:-ghcr.io/${repository}/utilities:validation-${GITHUB_SHA:-local}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
event_name="${GITHUB_EVENT_NAME:-${EVENT_NAME:-}}"
head_repository="${GITHUB_EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME:-${HEAD_REPOSITORY:-}}"
base_repository="${GITHUB_REPOSITORY:-${BASE_REPOSITORY:-}}"
pull_log="$(mktemp)"

cleanup() {
  rm -f "$pull_log"
}
trap cleanup EXIT

fail() {
  printf 'select-utilities-image: %s\n' "$1" >&2
  exit 1
}

# smoke_test_image verifies the candidate image has curl at the path and
# with the shared-library set every consumer's COPY --from=utilities-tools
# lines actually expect (the current, apk-installed structural shape) --
# not just "curl exists somewhere", which the older static-binary image
# also satisfied at a different, now-wrong path.
smoke_test_image() {
  local image="$1"
  docker run --rm "$image" sh -c '
    set -eu
    [ -x /usr/bin/curl ]
    /usr/bin/curl --version >/dev/null
    for lib in libcurl.so.4 libz.so.1 libcares.so.2 libnghttp2.so.14 \
               libidn2.so.0 libpsl.so.5 libssl.so.3 libcrypto.so.3 \
               libzstd.so.1 libbrotlidec.so.1 libunistring.so.5 \
               libbrotlicommon.so.1; do
      [ -e "/usr/lib/$lib" ]
    done
  '
}

published_image_reference() {
  local image="$1" digest=""
  if digest="$(resolve_manifest_digest "$image" "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}")"; then
    printf '%s@%s\n' "${image%:*}" "$digest"
  else
    fail "could not resolve multi-platform manifest digest for $image"
  fi
}

# select_utilities_trusted_fallback_allowed mirrors
# select-build-tools-image.sh's identically-named-in-spirit function and its
# same case-insensitive same-repo-PR trust boundary (issue #842 PR #1360) --
# a forked pull request must never trigger a build of this branch's own
# Dockerfile as part of this project's trusted CI infrastructure.
select_utilities_trusted_fallback_allowed() {
  local event_name="$1" head_repository="$2" base_repository="$3"
  if [[ "$event_name" = "pull_request" ]]; then
    [[ -n "$head_repository" && "${head_repository,,}" = "${base_repository,,}" ]]
  else
    return 0
  fi
}

trusted_fallback_allowed=false
if select_utilities_trusted_fallback_allowed "$event_name" "$head_repository" "$base_repository"; then
  trusted_fallback_allowed=true
fi

for candidate in "$published_image" "$published_fallback_image"; do
  if ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$candidate" >"$pull_log" 2>&1; then
    if smoke_test_image "$candidate"; then
      published_image_reference "$candidate"
      exit 0
    fi
    printf '::notice::%s did not satisfy the smoke test (built before the curl restructure); trying the next candidate.\n' "$candidate" >&2
  else
    printf '::notice::%s could not be pulled; trying the next candidate.\n' "$candidate" >&2
  fi
done

if [[ "$trusted_fallback_allowed" != "true" ]]; then
  cat "$pull_log" >&2
  fail "no published utilities image satisfies the smoke test and fallback builds are disabled for untrusted pull requests"
fi

# What: no --platform pin -- this builds for the runner's own
#   native architecture only (this script always runs on a self-hosted amd64
#   runner, matching validate-compose's own runner). A downstream
#   build-arm64 job resolving this same fallback reference on a real
#   (non-emulated) arm64 runner gets a clean "no match for platform in
#   manifest" failure rather than a wrong-architecture binary silently
#   landing in an arm64 image -- BuildKit's own platform-aware pull
#   refuses a single-platform image built for a different platform, it
#   does not fall back to using it anyway. Not solved here (this
#   self-hosted runner has no arm64 cross-build/QEMU setup to solve it
#   with); flagged, not silently accepted as new -- select-build-tools-
#   image.sh's own fallback has carried this identical limitation since
#   it was introduced, unrelated to this script.
#
# What: builds AND pushes to ghcr.io, not purely local.
# Why: the downstream build uses a separate buildx builder --
#   docker/setup-buildx-action's own isolated docker-container instance (a
#   fresh one per job -- see scripts/lib/docker-buildx-retry.sh's own header
#   for that isolation) -- it cannot see this job's local Docker image store,
#   only what a registry can hand it. A locally-tagged-only image here is
#   invisible to that later `FROM ${UTILITIES_IMAGE}`; it only ever
#   resolves as (and fails to pull as) a bare docker.io/library/* name.
#   Requires this job to hold packages: write on ghcr.io (see
#   build-push.yml's validate-compose job permissions).
#
# Not yet covered: gc-sha-retention-audit.sh / gc-pr-staging-images.sh only
# match `^sha-...`/`^pr-<N>-sha-...` tag shapes, so a validation-* tag
# pushed here is never swept by either existing retention job -- flagged,
# not fixed, in the interest of unblocking the build this pass exists to
# fix; a future pass should either teach one of those scripts this tag
# shape or add a narrow dedicated GC for it.
printf '::notice::Building and pushing a branch-local utilities validation image.\n' >&2
if [[ -n "${GHCR_RETRY_USERNAME:-}" && -n "${GHCR_RETRY_PASSWORD:-}" ]]; then
  ghcr_relogin ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD"
fi
docker_buildx_retry -- docker buildx build --pull --push -t "$fallback_image" "$utilities_context" >&2
ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker pull "$fallback_image" >&2
smoke_test_image "$fallback_image"
published_image_reference "$fallback_image"
