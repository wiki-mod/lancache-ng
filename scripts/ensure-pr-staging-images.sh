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
#
# #895: a fixed poll timeout does not "scale with runner congestion" -- under
# heavy concurrent load on the self-hosted fleet, build-push's own pipeline
# for a single service can legitimately take longer than any single fixed
# budget, so a slow-but-healthy run failed this gate identically to a truly
# broken one (confirmed live incident: PRs #877/#878/#880/#881/#882/#886 all
# timed out within minutes of each other while 23 orphaned validation
# containers sat on the runner fleet; the #877/watchdog tag existed in GHCR,
# it just arrived ~9 minutes after the 1500s poll gave up). Rather than
# blindly raising the fixed number (which only pushes the same failure mode
# further out and would hide a genuinely stuck build behind a much longer
# silent wait), wait_for_touched_image() now asks a concrete question once
# the normal budget is exceeded: is build-push.yml's OWN run for this exact
# commit still active? If yes, that's real evidence of congestion, not a
# stuck build, so the wait extends (up to a hard, still-finite ceiling). If
# that run has already finished without producing the tag, no amount of
# further waiting will help, so this fails immediately instead of idling out
# the rest of the budget. See build_push_run_active() below.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation-image-tag.sh
source "$script_dir/lib/validation-image-tag.sh"
# shellcheck source=scripts/lib/ghcr-retry.sh
source "$script_dir/lib/ghcr-retry.sh"

: "${REPOSITORY:?REPOSITORY is required}"
: "${PR_TAG:?PR_TAG (pr-<N>-sha-<short>) is required}"
: "${BASE_CHANNEL_TAG:?BASE_CHANNEL_TAG is required}"

workflow_changed="${WORKFLOW_CHANGED:-false}"
# The commit build-push.yml built and tagged for this PR (github.sha on a
# pull_request event -- see full-setup-deep-validate.yml's own BUILD_SHA
# comment in the "plan" job for why this must be the synthetic merge commit,
# not the PR head). Intentionally optional, not `:?`-required: this only
# feeds the best-effort congestion probe below, and a caller that omits it
# (e.g. an older invocation, or a test) must still get the pre-#895
# fail-at-baseline behavior, not a hard error for a var it never needed
# before.
build_sha="${BUILD_SHA:-}"

# Bounded wait for build-push to finish pushing this PR's touched-service
# staging tags. build/build-arm64 run on the scarce lancache-heavy tier
# (Rust compile + multi-arch image builds) and merge-manifests after them, so
# they can legitimately take many minutes; this is the "normal" budget past
# which we start asking whether build-push's own run is still active rather
# than failing outright (see #895 note above). Overridable for tests.
poll_timeout_seconds="${STAGING_POLL_TIMEOUT_SECONDS:-1500}"
poll_interval_seconds="${STAGING_POLL_INTERVAL_SECONDS:-15}"

# #895: absolute hard ceiling, independent of what the congestion probe
# reports. Even a build-push run that genuinely never stops (a hung job, a
# runner that died without ever marking its run failed) must not be allowed
# to hold this runner forever -- this is what keeps the fix "bounded and
# reasoned about" rather than an unbounded wait. 5400s/90min is chosen as
# generous headroom over the confirmed real-world worst case so far (#895's
# incident: ~34min actual end-to-end build-push time against the old 25min
# budget), not an arbitrary large number picked to make failures rarer.
poll_hard_ceiling_seconds="${STAGING_POLL_HARD_CEILING_SECONDS:-5400}"
# A misconfigured ceiling below the normal budget would make the extension
# logic self-contradicting (deadline already past hard ceiling on entry), so
# clamp it up rather than silently produce a negative wait window.
if (( poll_hard_ceiling_seconds < poll_timeout_seconds )); then
    poll_hard_ceiling_seconds=$poll_timeout_seconds
fi

# How often to actually call the congestion probe once past the normal
# budget, so a long extension doesn't hammer the GitHub API once per
# poll_interval_seconds tick.
congestion_check_interval_seconds="${STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS:-60}"

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

# #822 ("Pattern D"): this real `imagetools create` write is the exact
# operation observed failing live three times in one day with
# "401 Unauthorized: unauthenticated" (PRs #804/#817/#824, "ensure PR staging
# images" job) -- it previously ran once with no retry at all. GHCR_RETRY_
# USERNAME/PASSWORD are optional (ghcr_retry backs off and retries even
# without them, just without a fresh relogin -- see that function's own
# comment), so this still works if a caller runs the script without setting
# them, same as scripts/require-image-platforms.sh.
backfill_from_base() {
    local pr_image="$1" base_image="$2"
    if [[ -n "${STAGING_BACKFILL_CMD:-}" ]]; then
        "$STAGING_BACKFILL_CMD" "$pr_image" "$base_image"
    else
        ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- \
            docker buildx imagetools create --prefer-index=false -t "$pr_image" "$base_image"
    fi
}

# #895 congestion probe: reports whether build-push.yml's own run for
# $build_sha is still active (any status other than "completed" -- verified
# live against this repo's real Actions API that an in-flight run can report
# "pending", not only "queued"/"in_progress", so this deliberately checks
# for the one terminal state rather than enumerating non-terminal ones).
# Indirection so tests can stub the GitHub API call. Intentionally
# fail-safe: if BUILD_SHA is unset, `gh` isn't available, or the API call
# fails for any reason, this returns non-zero (treated as "not active") so
# the caller falls back to the original pre-#895 fail-at-baseline behavior
# instead of ever hanging on a broken probe.
build_push_run_active() {
    if [[ -n "${STAGING_BUILD_RUN_STATUS_CMD:-}" ]]; then
        "$STAGING_BUILD_RUN_STATUS_CMD"
        return $?
    fi
    if [[ -z "$build_sha" ]] || ! command -v gh >/dev/null 2>&1; then
        return 1
    fi
    local status
    status="$(gh api "repos/${REPOSITORY}/actions/workflows/build-push.yml/runs?head_sha=${build_sha}&event=pull_request&per_page=1" \
        --jq '.workflow_runs[0].status // empty' 2>/dev/null)" || return 1
    [[ -n "$status" && "$status" != "completed" ]]
}

wait_for_touched_image() {
    local pr_image="$1" service="$2"
    local start_time=$SECONDS
    local baseline_deadline=$((start_time + poll_timeout_seconds))
    local hard_deadline=$((start_time + poll_hard_ceiling_seconds))
    local warned_congestion=false
    # Force the first congestion probe (once the baseline is crossed) to
    # fire immediately instead of waiting a full interval -- matters both for
    # real runs (don't waste a whole interval before the first useful check)
    # and for tests that set STAGING_POLL_TIMEOUT_SECONDS=0.
    local last_congestion_check=$((start_time - congestion_check_interval_seconds))

    while true; do
        if image_exists "$pr_image"; then
            echo "::notice::$service staging image is present at $pr_image (waited $((SECONDS - start_time))s)."
            return 0
        fi

        if (( SECONDS >= hard_deadline )); then
            echo "::error::$service staging image ($pr_image) hit the hard ${poll_hard_ceiling_seconds}s ceiling. Even if build-push's run for this commit is still active, this gate refuses to wait any longer -- a run this slow needs its own investigation rather than an ever-longer poll."
            return 1
        fi

        if (( SECONDS >= baseline_deadline )) && (( SECONDS - last_congestion_check >= congestion_check_interval_seconds )); then
            last_congestion_check=$SECONDS
            if build_push_run_active; then
                if [[ "$warned_congestion" == false ]]; then
                    echo "::warning::$service staging image ($pr_image) has not appeared within the normal ${poll_timeout_seconds}s budget, but build-push's own run for commit $build_sha is still active -- extending the wait (up to ${poll_hard_ceiling_seconds}s total). This is expected under heavy self-hosted runner congestion (#895), not evidence of a stuck build."
                    warned_congestion=true
                fi
            else
                echo "::notice::build-push's run for commit $build_sha has already finished (or could not be found) and $service's staging tag still hasn't appeared -- further waiting cannot help, so treating this as a real failure now instead of idling until the ${poll_hard_ceiling_seconds}s hard ceiling."
                return 1
            fi
        fi

        echo "Waiting for $service staging image ($pr_image) from build-push (elapsed $((SECONDS - start_time))s, normal budget ${poll_timeout_seconds}s, hard ceiling ${poll_hard_ceiling_seconds}s)..."
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
        echo "::error::$service's PR staging tag ($pr_image) never appeared even though this PR touched it (or a workflow/CI-contract file changed) -- waited past the normal ${poll_timeout_seconds}s budget (and, if build-push's own run was still active, up to the ${poll_hard_ceiling_seconds}s hard ceiling; see the notice/warning lines above for which applied). Refusing to fall back to base-channel content for a touched service -- that would silently revalidate the stale image #626 exists to stop testing, behind a tag name that looks PR-specific. Check whether build-push actually built and pushed $service for this commit."
        exit 1
    fi

    base_image="ghcr.io/${REPOSITORY}/${service}:${BASE_CHANNEL_TAG}"
    echo "::notice::$service is untouched by this PR; (re)pointing $PR_TAG at the current $BASE_CHANNEL_TAG channel ($base_image)."
    backfill_from_base "$pr_image" "$base_image"
done

echo "All full-setup staging images are ready at tag $PR_TAG."
