set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

services=(proxy dns watchdog dhcp dhcp-proxy ui build-tools)
short_sha="${COMMIT_SHA::7}"
source_tag="sha-${short_sha}"

# Same wording as this same file's build/build-arm64 matrix.description
# entries -- kept in sync manually, not sourced from one shared place,
# because merge-manifests has no matrix of its own to read
# matrix.description from directly. This is where the OCI
# org.opencontainers.image.description annotation is actually set
# (issue #620): per-platform images upstream stay unannotated on
# purpose (see build's "Build and push" step comment), and every
# `imagetools create` downstream of this one (promote's channel and
# stack-pointer moves) carbon-copies this index annotation forward
# untouched rather than re-declaring it, confirmed live to preserve
# both the annotation and the exact source digest unchanged.
declare -A service_descriptions=(
  [proxy]="nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic."
  [dns]="PowerDNS recursor, authoritative DNS, and NATS subscriber service for lancache-ng cache routing."
  [watchdog]="lancache-ng watchdog helper for runtime health checks and recovery hooks."
  [dhcp]="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."
  [dhcp-proxy]="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."
  [ui]="lancache-ng Admin UI and control-plane service for cache, DNS, DHCP, and secondary management."
  [build-tools]="Prebuilt lancache-ng CI and developer validation toolchain image."
)

# Duplicated rather than factored into a shared script/action:
# GitHub Actions workflow YAML has no import mechanism for shell
# functions across job steps, and this file's own convention (see
# build/build-tools-base-digests and promote's copies of this same
# helper) is a local copy per job over introducing a new composite
# action just for one function. Same quote-stripping as those.
#
# Wrapped in ghcr_retry (#822): this reads the digest of a manifest
# this same step just created a few lines below, so a transient
# GHCR 401/read failure here is a real retry candidate, not an
# "expected absent" probe -- unlike the amd64/arm64 existence
# checks further down, which intentionally stay unwrapped (see
# their own comment).
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

  # Deliberately NOT wrapped in ghcr_retry: an absent per-arch
  # staging tag here almost always means "this service's build was
  # legitimately skipped" (unchanged on a PR, or a fork/Dependabot
  # PR with no push permission), not a transient registry error.
  # Retrying 3x with a 30s backoff would turn every expected skip
  # into a ~90s stall per service, and worse, could misclassify a
  # genuine transient 401 as "not built" and silently skip merging
  # a service that actually was pushed -- the retry policy exists
  # to protect real registry-write operations below, not this
  # expected-failure control flow.
  if ! docker buildx imagetools inspect "$amd64_image" >/dev/null 2>&1; then
    echo "::notice::Skipping $service: no linux/amd64 image was published for this commit (likely unchanged on a pull request)."
    continue
  fi
  if ! docker buildx imagetools inspect "$arm64_image" >/dev/null 2>&1; then
    echo "::error::$service has a linux/amd64 image but no linux/arm64 image ($arm64_image); refusing to publish a single-platform tag under the multi-platform contract."
    exit 1
  fi

  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
    docker buildx imagetools create -t "$target_image" "$amd64_image" "$arm64_image" \
    --annotation "index:org.opencontainers.image.description=${service_descriptions[$service]}"
  GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
    bash scripts/require-image-platforms.sh "$target_image" "$REQUIRED_PLATFORMS"

  # Output key uses underscores (dhcp-proxy/build-tools contain
  # hyphens, which the expression syntax in the attest steps below
  # would otherwise parse as subtraction) so those steps can
  # reference steps.create-trusted-manifests.outputs.<service>_digest.
  merged_digest="$(digest_for_image "$target_image")"
  printf '%s_digest=%s\n' "${service//-/_}" "$merged_digest" >> "$GITHUB_OUTPUT"
done

