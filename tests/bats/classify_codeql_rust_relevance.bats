#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Focused coverage for the shared CodeQL Rust relevance verdict. These cases
# pin the boundary that lets codeql.yml consume the common path classifier
# instead of maintaining a second list of Rust and CI inputs.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/classify-image-impact.sh"
    files="$BATS_TEST_TMPDIR/changed.txt"
}

run_classify() {
    printf '%s\n' "$@" > "$files"
    CHANGED_FILES="$files" run bash "$script"
}

val() {
    printf '%s\n' "$output" | grep -E "^$1=" | cut -d= -f2-
}

# DNS Rust source is part of the CodeQL Rust database, while non-Rust DNS
# configuration is not enough on its own to justify a Rust extraction.
@test "CodeQL Rust relevance distinguishes DNS Rust from other DNS files" {
    run_classify "services/dns/nats-subscriber/src/main.rs"
    [ "$status" -eq 0 ]
    [ "$(val codeql_rust)" = "true" ]

    run_classify "services/dns/entrypoint.sh"
    [ "$status" -eq 0 ]
    [ "$(val codeql_rust)" = "false" ]
}

# UI and watchdog are Rust crates at their service roots, so any path below
# those roots can change their build inputs and must keep the Rust gate live.
@test "UI and watchdog changes are CodeQL Rust relevant" {
    run_classify "services/ui/src/main.rs"
    [ "$(val codeql_rust)" = "true" ]

    run_classify "services/watchdog/watchdog.sh"
    [ "$(val codeql_rust)" = "true" ]
}

# Shared build actions can change how the Rust crates are compiled even when
# no crate source moves, so CodeQL must follow the same workflow-wide signal.
@test "shared build workflow inputs are CodeQL Rust relevant" {
    run_classify ".github/workflows/build-push.yml"
    [ "$(val codeql_rust)" = "true" ]

    run_classify ".github/actions/configure-rust-sccache/action.yml"
    [ "$(val codeql_rust)" = "true" ]
}

# CodeQL's own workflow and query configuration are analysis inputs and must
# rerun Rust even though the general build workflow verdict stays false.
@test "CodeQL workflow and config are independently Rust relevant" {
    run_classify ".github/workflows/codeql.yml"
    [ "$(val codeql_rust)" = "true" ]
    [ "$(val workflow)" = "false" ]

    run_classify ".github/codeql/codeql-config.yml"
    [ "$(val codeql_rust)" = "true" ]
}

# Documentation-only changes are deliberately excluded by the workflow trigger
# and must not become Rust-relevant through the classifier either.
@test "documentation-only change is not CodeQL Rust relevant" {
    run_classify "docs/release-versioning.md"
    [ "$status" -eq 0 ]
    [ "$(val codeql_rust)" = "false" ]
}

# An undeterminable push diff is fail-closed: the shared classifier treats all
# paths as changed, so CodeQL Rust must run rather than silently skip analysis.
@test "all-changed fallback forces CodeQL Rust relevance" {
    run bash "$script" --all-changed
    [ "$status" -eq 0 ]
    [ "$(val codeql_rust)" = "true" ]
}
