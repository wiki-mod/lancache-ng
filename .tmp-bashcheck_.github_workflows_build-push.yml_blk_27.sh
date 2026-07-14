set -euo pipefail

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$GITHUB_WORKSPACE/scripts/lib/ghcr-retry.sh"

# Mirrors build/build-arm64's "Determine whether this service
# needs building" should-build override exactly: a workflow/CI-
# contract change forces every service except build-tools to be
# treated as touched, because build-tools' own detect-changes
# scoping (tools/build-tools/** only) is intentionally narrower.
service_should_have_staging_tag() {
  local service="$1" touched="$2"
  if [[ "$WORKFLOW_CHANGED" == "true" && "$service" != "build-tools" ]]; then
    echo true
  else
    echo "$touched"
  fi
}

declare -A touched_map=(
  [proxy]="$PROXY_TOUCHED"
  [dns]="$DNS_TOUCHED"
  [watchdog]="$WATCHDOG_TOUCHED"
  [ui]="$UI_TOUCHED"
  [build-tools]="$BUILD_TOOLS_TOUCHED"
)

# The services deploy/full-setup/docker-compose.yml references,
# plus build-tools (used by the client-simulation step further
# down, not by the compose file itself). dhcp and dhcp-proxy are
# part of neither and are intentionally excluded.
#
# Decide touched-or-not FIRST, before looking at whether a pr_image
# already exists. A prior run of this exact PR head (a manual
# re-run, or this job simply running twice for the same commit) may
# already have back-filled an untouched service's pr-<N>-sha-<short>
# tag from whatever the base channel pointed at THEN. If the base
# channel (edge/dev) has since moved -- another PR merged in the
# meantime -- an existence check alone would see the stale alias,
# assume it's still correct, and `continue` without refreshing it:
# this job would then validate a deploy/workflow-only PR that
# doesn't touch that service against an old, no-longer-current
# base image, silently. So an untouched service is unconditionally
# (re)pointed at whatever the base channel resolves to RIGHT NOW --
# `imagetools create` is a cheap registry-side manifest write, not
# a rebuild, so refreshing it even when nothing actually changed
# costs nothing worth optimizing away.
full_setup_services=(proxy dns watchdog ui build-tools)
for service in "${full_setup_services[@]}"; do
  pr_image="ghcr.io/${REPOSITORY}/${service}:${PR_TAG}"
  should_exist="$(service_should_have_staging_tag "$service" "${touched_map[$service]}")"

  if [[ "$should_exist" == "true" ]]; then
    # Wrapped in ghcr_retry: unlike merge-manifests' per-arch
    # probes, a missing tag here is always a real error (this job
    # runs after merge-manifests, so a touched service's PR staging
    # tag is expected to already exist) -- retrying protects
    # against a transient 401 being misreported as "never pushed".
    if ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- docker buildx imagetools inspect "$pr_image" >/dev/null 2>&1; then
      echo "::notice::$service already has a staging image at $PR_TAG (this PR touched it)."
      continue
    fi
    echo "::error::$service's PR staging tag ($pr_image) is missing even though detect-changes says this PR touched it (or a workflow/CI-contract file changed). Refusing to fall back to base-channel content for a touched service -- that would silently reintroduce #626's bug behind a tag name that looks PR-specific. Check whether build/build-arm64 actually pushed $service successfully for this commit."
    exit 1
  fi

  base_image="ghcr.io/${REPOSITORY}/${service}:${BASE_CHANNEL_TAG}"
  echo "::notice::$service is untouched by this PR; (re)pointing $PR_TAG at the current $BASE_CHANNEL_TAG channel ($base_image)."
  ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
    docker buildx imagetools create --prefer-index=false -t "$pr_image" "$base_image"
done

