#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sets default_poll_timeout_seconds/default_poll_hard_ceiling_seconds for the
# staging wait used by scripts/untracked/ensure-pr-staging-images.sh. The
# caller still invokes this helper with the old workflow flag for call-site
# compatibility, but the flag no longer changes the result: both branches now
# share the same service-scoped defaults. That keeps workflow-only edits from
# inheriting a full-rebuild wait budget when no service was actually touched.
#
# Kept in its own file (not inlined in ensure-pr-staging-images.sh) so a bats
# test can source just this function and check the selected defaults
# directly, instead of sourcing the whole caller script (which runs its own
# top-level staging-check flow immediately on load) or actually waiting out a
# real poll to observe the value.
# shellcheck disable=SC2034 # both set here for the caller (ensure-pr-staging-images.sh,
# which sources this file) to read after calling this function -- shellcheck
# analyzes this file in isolation and cannot see that cross-file use.
staging_poll_set_defaults_for_workflow_changed() {
    default_poll_timeout_seconds=1500
    default_poll_hard_ceiling_seconds=1200
}
