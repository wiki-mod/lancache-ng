#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/untracked/check-pr-tracking-metadata.sh (AG-GH-008): the CI
# guard that validates a pull request carries labels, a milestone, and (when
# a project-read token is configured) Project-board placement.
#
# No bats coverage existed for this script before issue #1278. That issue
# removed the script's former blanket `dependabot[bot]` exemption (it used
# to short-circuit straight to an explicit pass, see #1061-#1064) once
# build-push.yml gained a dedicated step that auto-assigns Dependabot PRs a
# real milestone instead. These fixtures invoke the script the same way
# build-push.yml's pr-tracking-metadata-check/-hosted jobs do: env vars only,
# no file argument.
#
# GH_TOKEN is deliberately left unset in every fixture below so the
# project-board branch takes its documented no-token warn path instead of
# making a real network call to api.github.com -- these tests must stay
# fully offline.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/untracked/check-pr-tracking-metadata.sh"
}

# --- Pass cases ---------------------------------------------------------

@test "passes: labels and milestone both set (no GH_TOKEN -- project-board check warns, not blocks)" {
    PR_LABELS_JSON='[{"name":"ci"}]' PR_MILESTONE_TITLE='v0.3.0' PR_DRAFT=false \
        PR_NUMBER=1 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

# --- Fail cases (non-draft) ----------------------------------------------

@test "fails: no labels set" {
    PR_LABELS_JSON='[]' PR_MILESTONE_TITLE='v0.3.0' PR_DRAFT=false \
        PR_NUMBER=1 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"AG-GH-008"* ]]
    [[ "$output" == *"No labels set"* ]]
}

@test "fails: no milestone set" {
    PR_LABELS_JSON='[{"name":"ci"}]' PR_MILESTONE_TITLE='' PR_DRAFT=false \
        PR_NUMBER=1 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No milestone set"* ]]
}

# --- Draft-PR non-blocking behavior ---------------------------------------

@test "draft PR: missing labels and milestone warns but exits 0 (non-blocking)" {
    PR_LABELS_JSON='[]' PR_MILESTONE_TITLE='' PR_DRAFT=true \
        PR_NUMBER=1 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft PR"* ]]
}

# --- Fork PR project-board warning -----------------------------------------

@test "fork PR: no GH_TOKEN warns with the fork-specific explanation, but labels/milestone still enforced" {
    PR_LABELS_JSON='[{"name":"ci"}]' PR_MILESTONE_TITLE='v0.3.0' PR_DRAFT=false \
        PR_NUMBER=1 REPO='wiki-mod/lancache-ng' PR_IS_FORK=true \
        run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}

# --- Dependabot regression coverage (issue #1278) --------------------------
# Before #1278, PR_AUTHOR == "dependabot[bot]" short-circuited this whole
# script to an explicit pass regardless of labels/milestone. That exemption
# is gone: build-push.yml now auto-assigns a milestone to Dependabot PRs
# before this script runs, so a Dependabot PR with no milestone is now a
# real, actionable failure like any other PR -- not a silently-skipped case.

@test "dependabot[bot] PR with no milestone now FAILS -- exemption removed (#1278)" {
    PR_LABELS_JSON='[{"name":"dependencies"}]' PR_MILESTONE_TITLE='' PR_DRAFT=false \
        PR_NUMBER=1270 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        PR_AUTHOR='dependabot[bot]' \
        run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No milestone set"* ]]
}

@test "dependabot[bot] PR with labels and milestone set passes the real check like any other PR" {
    PR_LABELS_JSON='[{"name":"dependencies"}]' PR_MILESTONE_TITLE='LanCache-NG Roadmap' PR_DRAFT=false \
        PR_NUMBER=1270 REPO='wiki-mod/lancache-ng' PR_IS_FORK=false \
        PR_AUTHOR='dependabot[bot]' \
        run bash "$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *"passed"* ]]
}
