#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Sets default_poll_timeout_seconds/default_poll_hard_ceiling_seconds for the
# given workflow_changed value, used by scripts/ensure-pr-staging-images.sh.
#
# The normal timeout is deliberately LOWER than the hard ceiling. That gap is
# load-bearing: after the normal timeout, ensure-pr-staging-images.sh probes
# whether build-push.yml still has an incomplete run for this PR head. A live
# producer is allowed to keep working until the hard ceiling; a producer that
# has already finished without publishing the required staging tag fails the
# consumer early instead of holding a runner for the rest of the ceiling.
# Equal values make that producer-state probe unreachable because the caller
# checks the absolute hard ceiling first.
#
# Normal PRs use a 900s normal budget and a 1200s absolute ceiling. The 1200s
# ceiling preserves the maintainer-directed cut from the former 5400s wait;
# the earlier 900s producer-state probe turns the final five minutes into
# congestion headroom only when a real build-push run is still active.
#
# A separate, larger pair applies when workflow_changed is true: a workflow/
# composite-action change forces every runtime service to rebuild on the
# scarce heavy-runner tier. Real measured durations for this exact category
# (2026-08-06, five consecutive current_dev full-rebuild runs) were
# 17/23/48/37/27 minutes. A 1500s normal budget lets the common 17/23-minute
# cases finish without an API probe, while the 3600s hard ceiling still covers
# the measured 48-minute case when build-push is positively confirmed active.
#
# Kept in its own file so Bats can verify both the selected values and the
# baseline-before-ceiling invariant without sourcing the top-level staging
# script, which immediately starts its real staging flow when loaded.
# shellcheck disable=SC2034
# Both values are consumed by ensure-pr-staging-images.sh after sourcing.
staging_poll_set_defaults_for_workflow_changed() {
    local workflow_changed_flag="$1"
    if [[ "$workflow_changed_flag" == "true" ]]; then
        default_poll_timeout_seconds=1500
        default_poll_hard_ceiling_seconds=3600
    else
        default_poll_timeout_seconds=900
        default_poll_hard_ceiling_seconds=1200
    fi
}
