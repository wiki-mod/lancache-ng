set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

short_sha="${GITHUB_SHA::7}"
amd64_image="${BUILD_TOOLS_IMAGE}:sha-${short_sha}-standalone-amd64"
arm64_image="${BUILD_TOOLS_IMAGE}:sha-${short_sha}-standalone-arm64"
source_tag="${BUILD_TOOLS_IMAGE}:sha-${short_sha}"

# Same description text as build-push.yml's own build-tools
# matrix.description entry -- kept in sync manually, not sourced
# from one shared place, same reasoning as that file's
# merge-manifests job. This is where the index-level
# org.opencontainers.image.description annotation actually gets
# attached (issue #620): the per-platform build-tools/
# build-tools-arm64 jobs above stay unannotated on purpose (see
# their "Build and push" step comments), and "Promote mutable
# tags" below carbon-copies this index annotation forward
# untouched rather than re-declaring it, same pattern as
# build-push.yml's promote job.
build_tools_description="Prebuilt lancache-ng CI and developer validation toolchain image."

ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
  docker buildx imagetools create -t "$source_tag" "$amd64_image" "$arm64_image" \
  --annotation "index:org.opencontainers.image.description=${build_tools_description}"

printf 'source-tag=%s\n' "$source_tag" >> "$GITHUB_OUTPUT"

