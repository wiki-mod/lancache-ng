#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Pure (Docker-free, registry-free) helpers for deciding WHICH image tag the
# full-setup deep validation suite should test, and whether a PR is eligible
# for its own per-PR staging tag. Sourced by
# scripts/ensure-pr-staging-images.sh and by the deep-validate workflow, and
# unit-tested directly by tests/bats/validation_image_tag.bats so the tag
# maths stay honest without needing a runner with Docker.
#
# SOURCE OF TRUTH NOTE (updated 2026-07-17, issue #822 pattern audit):
# .github/workflows/build-push.yml's "validate full-setup image" job
# (channel resolution + pr-staging-available + the service_should_have_
# staging_tag override), established by #626/#627, now calls
# vit_base_channel_tag/vit_pr_staging_available/vit_resolve_tag/
# vit_service_should_have_staging_tag directly instead of reimplementing
# the same decisions inline a second time. This file is the single
# implementation both build-push.yml and scripts/ensure-pr-staging-images.sh
# (plus this file's own tests/bats/validation_image_tag.bats) share --
# agreement is now structural, not a "keep in sync by hand" invariant.
# #715's own original clarification ("deliberately left that job untouched")
# was about not disrupting #715's separate, larger full-setup-validate.yml
# absorption work in progress at the time, not a permanent ban on ever
# deduplicating this specific helper logic -- see #822 for the narrower
# follow-up that made this the single implementation. The whole point of
# #715 is to REUSE that exact pr-<N>-sha-<short> mechanism, never invent a
# second, divergent one.

# Map a base ref (the PR's target branch, or a push's own ref) to the release
# channel it publishes to. Mirrors build-push.yml's promote/validate mapping:
# master publishes nightly, a vX.Y.Z pre-release integration branch publishes
# dev, and everything else falls back to latest (the stable-release-only
# channel). `latest` is intentionally never the default for a live branch --
# see build-push.yml's own comment on why validating a pre-release branch
# against latest checks the wrong image.
vit_base_channel_tag() {
    local base_ref="$1"
    if [[ "$base_ref" == "master" ]]; then
        printf 'nightly\n'
    elif [[ "$base_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'dev\n'
    else
        printf 'latest\n'
    fi
}

# A PR gets its own pushed staging tag only when build/build-arm64 in
# build-push.yml were actually able to push for it: a same-repo, non-
# Dependabot PR. Dependabot and fork PRs run with a read-only GITHUB_TOKEN
# (confirmed in GitHub's own docs for Dependabot), so no PR staging tag ever
# exists for them and the suite must fall back to the base channel -- exactly
# the pre-#626 behaviour. Echoes "true" or "false".
vit_pr_staging_available() {
    local event_name="$1" actor="$2" head_repo="$3" repository="$4"
    if [[ "$event_name" == "pull_request" && "$actor" != "dependabot[bot]" && "$head_repo" == "$repository" ]]; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

# Resolve the single LANCACHE_IMAGE_TAG the whole deep suite should validate
# against for this event. workflow_dispatch honours the operator's chosen
# channel/tag input (the existing ad-hoc, published-channel use case that
# #715 explicitly preserves). A same-repo PR resolves to its OWN
# pr-<N>-sha-<short> staging tag so the sims test the PR's real commits, not
# whatever the base branch last published -- the inconsistency #715 calls out
# where the deep sims previously always tested "nightly" regardless of intent. A
# Dependabot/fork PR falls back to the base channel. Echoes the tag.
#
# build_sha is github.sha (for a pull_request event, the synthetic
# base+head merge commit that was actually built), NOT the PR head sha:
# build-push.yml keys the staging tag on github.sha for the merge-result
# reasons documented at length in its own "Determine validation image
# channel" step, and this MUST match byte-for-byte or the suite would look
# for a tag build-push never pushed.
vit_resolve_tag() {
    local event_name="$1" base_ref="$2" pr_number="$3" build_sha="$4"
    local actor="$5" head_repo="$6" repository="$7" dispatch_tag="$8"

    if [[ "$event_name" == "workflow_dispatch" ]]; then
        printf '%s\n' "${dispatch_tag:-nightly}"
        return 0
    fi

    if [[ "$(vit_pr_staging_available "$event_name" "$actor" "$head_repo" "$repository")" == "true" ]]; then
        printf 'pr-%s-sha-%s\n' "$pr_number" "${build_sha:0:7}"
        return 0
    fi

    vit_base_channel_tag "$base_ref"
}

# Whether a given full-setup service is expected to already have a pushed
# staging image for this PR. Mirrors build/build-arm64's should-build
# override exactly: a workflow/CI-contract change forces every service EXCEPT
# build-tools to be treated as touched (build-tools' own detect-changes
# scoping, tools/build-tools/** only, is intentionally narrower). Echoes
# "true"/"false". Used by the fail-closed guard so a touched service whose
# build genuinely failed is caught, while a legitimately untouched service is
# allowed the cheap base-channel back-fill.
vit_service_should_have_staging_tag() {
    local service="$1" touched="$2" workflow_changed="$3"
    if [[ "$workflow_changed" == "true" && "$service" != "build-tools" ]]; then
        printf 'true\n'
    else
        printf '%s\n' "$touched"
    fi
}
