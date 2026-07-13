#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Makes the PR-scoped staging images the full-setup deep validation suite
# needs actually present before the sims run, on a pull_request event. This
# is where the deep gate REUSES the #626/#627 pr-<N>-sha-<short> mechanism
# rather than inventing its own:
#
#   1. For every full-setup service this PR TOUCHED (or every service but
#      build-tools if a workflow/CI-contract file changed), POLL the registry
#      until build-push.yml's build/build-arm64/merge-manifests have pushed
#      that service's pr-<N>-sha-<short> tag -- this poll IS the cross-
#      workflow wait, since a separate workflow cannot express `needs:` on
#      build-push's jobs. If the tag never appears within the timeout, FAIL
#      CLOSED: a touched service with no staging image means its build failed
#      (or the registry is unreachable), and silently validating stale
#      base-channel content behind a PR-looking tag is exactly #626's bug.
#   2. For every service this PR did NOT touch, (re)point pr-<N>-sha-<short>
#      at whatever the base channel resolves to RIGHT NOW via a cheap
#      registry-side `imagetools create` (never a rebuild) -- the correct
#      image to validate an untouched service against, refreshed every run so
#      a base channel that moved since a prior re-run can't leave a stale
#      alias. Mirrors build-push.yml's "Ensure PR staging tags exist" step.
#
# Doing our own back-fill (rather than relying on build-push's own validate
# job to have done it) keeps this workflow self-sufficient: it is correct
# even for a services-only PR where build-push's shallow validate job skips.
#
# SOURCE OF TRUTH NOTE: the touched-vs-untouched decision and the fail-closed
# guard mirror build-push.yml's "validate full-setup image" job (untouched
# per #715 clarification). Keep in sync by hand.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation-image-tag.sh
source "$script_dir/lib/validation-image-tag.sh"

: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_TAG:?PR_TAG (pr-<N>-sha-<short>) is required}"
: "${BASE_CHANNEL_TAG:?BASE_CHANNEL_TAG is required}"

workflow_changed="${WORKFLOW_CHANGED:-false}"

# Bounded wait for build-push to finish pushing this PR's touched-service
# staging tags. build/build-arm64 run on the scarce lancache-heavy tier
# (Rust compile + multi-arch image builds) and merge-manifests after them, so
# they can legitimately take many minutes; the default ceiling is generous
# but finite so a genuinely failed/absent build fails this gate instead of
# hanging a runner forever. Overridable for tests.
poll_timeout_seconds="${STAGING_POLL_TIMEOUT_SECONDS:-1500}"
poll_interval_seconds="${STAGING_POLL_INTERVAL_SECONDS:-15}"

# The services deploy/full-setup/docker-compose.yml references, plus
# build-tools (used by the client-simulation steps, not the compose file
# itself). dhcp and dhcp-proxy are intentionally NOT here: they are not part
# of the full-setup compose project. dhcp gets its real coverage from the
# from-source dhcp-kea-lease-flow simulation; dhcp-proxy has no deep job yet
# (tracked in #705) and so still has no coverage here -- calling it out
# rather than pretending the compose-service list covers it.
full_setup_services=(proxy dns watchdog ui build-tools)

declare -A touched_map=(
    [proxy]="${PROXY_TOUCHED:-false}"
    [dns]="${DNS_TOUCHED:-false}"
    [watchdog]="${WATCHDOG_TOUCHED:-false}"
    [ui]="${UI_TOUCHED:-false}"
    [build-tools]="${BUILD_TOOLS_TOUCHED:-false}"
)

# Indirection so tests can stub the registry probe without a real daemon.
image_exists() {
    local image="$1"
    if [[ -n "${STAGING_IMAGE_EXISTS_CMD:-}" ]]; then
        "$STAGING_IMAGE_EXISTS_CMD" "$image"
    else
        docker buildx imagetools inspect "$image" >/dev/null 2>&1
    fi
}

backfill_from_base() {
    local pr_image="$1" base_image="$2"
    if [[ -n "${STAGING_BACKFILL_CMD:-}" ]]; then
        "$STAGING_BACKFILL_CMD" "$pr_image" "$base_image"
    else
        docker buildx imagetools create --prefer-index=false -t "$pr_image" "$base_image"
    fi
}

wait_for_touched_image() {
    local pr_image="$1" service="$2"
    local deadline=$((SECONDS + poll_timeout_seconds))
    while true; do
        if image_exists "$pr_image"; then
            echo "::notice::$service staging image is present at $pr_image."
            return 0
        fi
        if (( SECONDS >= deadline )); then
            return 1
        fi
        echo "Waiting for $service staging image ($pr_image) from build-push (up to ${poll_timeout_seconds}s)..."
        sleep "$poll_interval_seconds"
    done
}

for service in "${full_setup_services[@]}"; do
    pr_image="ghcr.io/${REPOSITORY}/${service}:${PR_TAG}"
    should_exist="$(vit_service_should_have_staging_tag "$service" "${touched_map[$service]}" "$workflow_changed")"

    if [[ "$should_exist" == "true" ]]; then
        if wait_for_touched_image "$pr_image" "$service"; then
            continue
        fi
        echo "::error::$service's PR staging tag ($pr_image) never appeared within ${poll_timeout_seconds}s even though this PR touched it (or a workflow/CI-contract file changed). Refusing to fall back to base-channel content for a touched service -- that would silently revalidate the stale image #626 exists to stop testing, behind a tag name that looks PR-specific. Check whether build-push actually built and pushed $service for this commit."
        exit 1
    fi

    base_image="ghcr.io/${REPOSITORY}/${service}:${BASE_CHANNEL_TAG}"
    echo "::notice::$service is untouched by this PR; (re)pointing $PR_TAG at the current $BASE_CHANNEL_TAG channel ($base_image)."
    backfill_from_base "$pr_image" "$base_image"
done

echo "All full-setup staging images are ready at tag $PR_TAG."
