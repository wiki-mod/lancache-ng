#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/staging-poll-defaults.sh
    source "$repo_root/scripts/lib/staging-poll-defaults.sh"
}

@test "normal staging defaults leave a real producer-state probe window" {
    staging_poll_set_defaults_for_workflow_changed false

    [ "$default_poll_timeout_seconds" -eq 900 ]
    [ "$default_poll_hard_ceiling_seconds" -eq 1200 ]
    [ "$default_poll_timeout_seconds" -lt "$default_poll_hard_ceiling_seconds" ]
}

@test "workflow-change staging defaults keep full-rebuild headroom but probe before hard ceiling" {
    staging_poll_set_defaults_for_workflow_changed true

    [ "$default_poll_timeout_seconds" -eq 1500 ]
    [ "$default_poll_hard_ceiling_seconds" -eq 3600 ]
    [ "$default_poll_timeout_seconds" -lt "$default_poll_hard_ceiling_seconds" ]
}
