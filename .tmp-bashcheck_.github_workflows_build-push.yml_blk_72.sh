set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)
short_sha="${BUILD_SHA::7}"
source_tag="pr-${PR_NUMBER}-sha-${short_sha}"

# Same helper as the trusted-ref step above (and promote's own
# copy) -- kept duplicated per step/job rather than shared, which
# is the existing convention in this file. Same ghcr_retry
# reasoning as that step's copy: this reads a manifest just
# created below, not an expected-absence probe.
digest_for_image() {
  local image=$1
  local digest

  if ! digest="$(ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}' 2>/dev/null)"; then
    return 1
  fi
  digest="${digest%\"}"
  digest="${digest#\"}"
  [[ -n "$digest" && "$digest" != "null" ]]
  printf '%s\n' "$digest"
}

for service in "${services[@]}"; do
  amd64_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}-amd64"
  arm64_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}-arm64"
  target_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}"

  # Same "do not retry an expected-absence probe" reasoning as the
  # trusted-ref step above.
  if ! docker buildx imagetools inspect "$amd64_image" >/dev/null 2>&1; then
    echo "::notice::Skipping $service: no linux/amd64 PR staging image (not touched by this PR, or a fork PR)."
    continue
  fi
  if ! docker buildx imagetools inspect "$arm64_image" >/dev/null 2>&1; then
    echo "::error::$service has a linux/amd64 PR staging image but no linux/arm64 one ($arm64_image); build and build-arm64 disagreed on whether this service needed building."
    exit 1
  fi

  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
    docker buildx imagetools create -t "$target_image" "$amd64_image" "$arm64_image"
  GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
    bash scripts/require-image-platforms.sh "$target_image" "$REQUIRED_PLATFORMS"

  # Same underscore-key reasoning as the trusted-ref step above.
  # This PR staging manifest is the exact tag full-setup-validate
  # pulls and runs for this PR's commits, not a throwaway build
  # artifact, so it gets the same provenance attestation.
  merged_digest="$(digest_for_image "$target_image")"
  printf '%s_digest=%s\n' "${service//-/_}" "$merged_digest" >> "$GITHUB_OUTPUT"
done

