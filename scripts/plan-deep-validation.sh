#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Planning step for the full-setup deep validation gate (#715). Resolves,
# from the triggering event, the single image tag the whole deep suite should
# validate against, whether the PR is eligible for its own staging tag, and
# (for a pull_request) the per-service touched flags + should_run gate. Writes
# all of it as key=value lines to $GITHUB_OUTPUT so downstream jobs can gate
# off one place. Kept as a script (not inline YAML) so the tag maths stay
# easy to lint cleanly and unit-tested via scripts/lib/validation-image-tag.sh.
#
# Required env: EVENT_NAME, REPOSITORY, GITHUB_OUTPUT. For a pull_request:
# BASE_REF, BASE_SHA, PR_NUMBER, BUILD_SHA (github.sha), ACTOR, HEAD_REPO. For
# workflow_dispatch: DISPATCH_TAG (the image_tag input; defaults to edge).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation-image-tag.sh
source "$script_dir/lib/validation-image-tag.sh"

: "${EVENT_NAME:?EVENT_NAME is required}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

base_ref="${BASE_REF:-}"
base_channel_tag="$(vit_base_channel_tag "$base_ref")"
pr_staging_available="$(vit_pr_staging_available "$EVENT_NAME" "${ACTOR:-}" "${HEAD_REPO:-}" "$REPOSITORY")"
image_tag="$(vit_resolve_tag "$EVENT_NAME" "$base_ref" "${PR_NUMBER:-}" "${BUILD_SHA:-}" "${ACTOR:-}" "${HEAD_REPO:-}" "$REPOSITORY" "${DISPATCH_TAG:-}")"

{
    printf 'base_channel_tag=%s\n' "$base_channel_tag"
    printf 'pr_staging_available=%s\n' "$pr_staging_available"
    printf 'image_tag=%s\n' "$image_tag"
} >> "$GITHUB_OUTPUT"

if [[ "$EVENT_NAME" == "pull_request" ]]; then
    # Per-service touched flags + should_run come from the real diff; the
    # detector appends its own key=value lines to $GITHUB_OUTPUT.
    bash "$script_dir/detect-full-setup-changes.sh"
else
    # Manual dispatch: always run, validate the operator's chosen tag. No PR
    # staging tag exists, so per-service flags are irrelevant
    # (ensure-pr-staging-images is skipped on non-PR events).
    {
        printf 'should_run=true\n'
        printf 'workflow=false\n'
        printf 'proxy=false\n'
        printf 'dns_image=false\n'
        printf 'watchdog=false\n'
        printf 'ui=false\n'
        printf 'build_tools=false\n'
    } >> "$GITHUB_OUTPUT"
fi

echo "Deep validation plan: tag=$image_tag pr_staging_available=$pr_staging_available" >&2
