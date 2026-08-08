#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-bats-path-filter-coverage.sh"
    repo_root="$BATS_TEST_DIRNAME/../.."
}

@test "real repository bats dependencies are covered by smoke workflow filters" {
    run bash "$script" "$repo_root"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&3
    fi
    [ "$status" -eq 0 ]
}
