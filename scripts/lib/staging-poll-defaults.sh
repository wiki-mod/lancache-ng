#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sets default_poll_timeout_seconds/default_poll_hard_ceiling_seconds for the
# given workflow_changed value, used by scripts/tracked/ensure-pr-staging-images.sh.
# A separate, larger pair applies when it is "true": a workflow/composite-
# action change forces every one of the 9 services to rebuild at once on the
# scarce heavy-runner tier (build-push.yml's own "workflow or composite-
# action changes are treated as touching runtime services" fail-safe), a
# structurally slower category than a normal single/few-service PR. Real
# measured durations for this exact category (2026-08-06, 5 consecutive
# current_dev full-rebuild runs): 17/23/48/37/27 minutes -- the normal
# 1500s/1200s pair doesn't cover the 48-minute sample even once. 3600s covers
# the worst real sample with margin. This widens only the narrow,
# identifiable full-rebuild case; it does not reopen the general "just raise
# the number" cut described in ensure-pr-staging-images.sh's own #895 note,
# which was about the common per-PR case.
#
# Kept in its own file (not inlined in ensure-pr-staging-images.sh) so a bats
# test can source just this function and check the selected defaults
# directly, instead of sourcing the whole caller script (which runs its own
# top-level staging-check flow immediately on load) or actually waiting out a
# real 3600s poll to observe the value.
# shellcheck disable=SC2034 # both set here for the caller (ensure-pr-staging-images.sh,
# which sources this file) to read after calling this function -- shellcheck
# analyzes this file in isolation and cannot see that cross-file use.
staging_poll_set_defaults_for_workflow_changed() {
    local workflow_changed_flag="$1"
    if [[ "$workflow_changed_flag" == "true" ]]; then
        default_poll_timeout_seconds=3600
        default_poll_hard_ceiling_seconds=3600
    else
        default_poll_timeout_seconds=1500
        default_poll_hard_ceiling_seconds=1200
    fi
}
