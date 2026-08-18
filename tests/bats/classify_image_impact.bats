#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free, git-free unit coverage for scripts/untracked/classify-image-impact.sh
# (#819). Feeds canned changed-file lists (via CHANGED_FILES) and asserts the
# per-path booleans this script inherited verbatim from build-push.yml's
# detect-changes job, plus the additive IMAGE_IMPACT verdict the promote job's
# version-bump logic consumes. The per-path booleans are covered so the
# extraction stays byte-for-byte equivalent to the inline job it replaced; the
# IMAGE_IMPACT cases pin the "does this diff warrant a patch (Z) bump?" boundary.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/classify-image-impact.sh"
    files="$BATS_TEST_TMPDIR/changed.txt"
}

# Run the classifier against a canned file list and capture key=value stdout.
run_classify() {
    printf '%s\n' "$@" > "$files"
    CHANGED_FILES="$files" run bash "$script"
}

# Extract the value of a single output key from $output.
val() {
    printf '%s\n' "$output" | grep -E "^$1=" | cut -d= -f2-
}

# --- Per-path booleans (parity with the former inline detect-changes job) ---

@test "proxy change: proxy true, image impact true" {
    run_classify "services/proxy/nginx.conf"
    [ "$status" -eq 0 ]
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "cdn-domains.txt-only change also sets proxy=true (#771)" {
    run_classify "services/dns/cdn-domains.txt"
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "dns nats-subscriber path sets dns_rust and dns_image" {
    run_classify "services/dns/nats-subscriber/src/main.rs"
    [ "$(val dns_rust)" = "true" ]
    [ "$(val dns_image)" = "true" ]
}

@test "ui / watchdog / dhcp / dhcp-proxy flags are detected independently" {
    run_classify "services/ui/src/main.rs"
    [ "$(val ui)" = "true" ]
    [ "$(val watchdog)" = "false" ]

    run_classify "services/watchdog/entrypoint.sh"
    [ "$(val watchdog)" = "true" ]
    [ "$(val ui)" = "false" ]

    run_classify "services/dhcp/entrypoint.sh"
    [ "$(val dhcp)" = "true" ]
    [ "$(val dhcp_proxy)" = "false" ]

    run_classify "services/dhcp-proxy/entrypoint.sh"
    [ "$(val dhcp_proxy)" = "true" ]
    [ "$(val dhcp)" = "false" ]
}

# #1428: syslog is the combined fluent-bit+syslog-ng first-party image wired
# into the build matrix by this issue. Mirrors the independence check above
# for the other per-service booleans.
@test "syslog change: syslog true, other service flags stay false" {
    run_classify "services/syslog/entrypoint.sh"
    [ "$(val syslog)" = "true" ]
    [ "$(val proxy)" = "false" ]
    [ "$(val watchdog)" = "false" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "build-tools change: build_tools true" {
    run_classify "tools/build-tools/Dockerfile"
    [ "$(val build_tools)" = "true" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

# #1556: utilities is the shared non-compiler CLI-tools image
# (curl/nano/lsof/ripgrep/findutils/coreutils/gettext-envsubst/jq/
# ca-certificates/zstd) wired into the build matrix. Mirrors the
# independence check above for the other per-service booleans.
@test "utilities change: utilities true, other service flags stay false" {
    run_classify "services/utilities/Dockerfile"
    [ "$(val utilities)" = "true" ]
    [ "$(val proxy)" = "false" ]
    [ "$(val build_tools)" = "false" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "build-push.yml change sets workflow true; an unrelated workflow does not" {
    run_classify ".github/workflows/build-push.yml"
    [ "$(val workflow)" = "true" ]

    run_classify ".github/workflows/codeql.yml"
    [ "$(val workflow)" = "false" ]

    run_classify ".github/actions/derive-validation-network/action.yml"
    [ "$(val workflow)" = "true" ]
}

@test "docs flags: docs true, docs_only true for a pure docs diff" {
    run_classify "docs/install-ca-cert.md" "README.md"
    [ "$(val docs)" = "true" ]
    [ "$(val docs_only)" = "true" ]
}

@test "mixed docs + code: docs true but docs_only false" {
    run_classify "README.md" "services/ui/src/main.rs"
    [ "$(val docs)" = "true" ]
    [ "$(val docs_only)" = "false" ]
    [ "$(val ui)" = "true" ]
}

@test "governance: AGENTS.md sets governance true" {
    run_classify "AGENTS.md"
    [ "$(val governance)" = "true" ]

    run_classify ".github/AGENTS.md"
    [ "$(val governance)" = "true" ]
}

@test "setup.sh and scripts set setup_runtime; scripts also sets scripts" {
    run_classify "setup.sh"
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val scripts)" = "false" ]

    run_classify "scripts/untracked/simulations/ssl-mitm-cache-simulation.sh"
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val scripts)" = "true" ]
}

@test "deploy and release_contract flags" {
    run_classify "deploy/full-setup/docker-compose.yml"
    [ "$(val deploy)" = "true" ]

    run_classify "release/stack-images.yml"
    [ "$(val release_contract)" = "true" ]

    run_classify ".github/workflows/backfill-stack-latest.yml"
    [ "$(val release_contract)" = "true" ]
}

# --- IMAGE_IMPACT verdict boundary (the additive #819 layer) ---

@test "docs-only diff is NOT image impact" {
    run_classify "docs/install-ca-cert.md" "README.md"
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

@test "workflow-only diff is NOT image impact (never lands in an image digest)" {
    run_classify ".github/workflows/build-push.yml"
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

@test "tests-only diff is NOT image impact" {
    run_classify "tests/bats/classify_image_impact.bats"
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

@test "governance/*.md-only diff is NOT image impact" {
    run_classify "AGENTS.md"
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

@test "deploy-only diff IS image impact (operator-run behavior, even if no digest moves)" {
    run_classify "deploy/quickstart/docker-compose.yml"
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "setup.sh-only diff IS image impact (operator-run behavior)" {
    run_classify "setup.sh"
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "config-only diff IS image impact" {
    run_classify "config/prod/proxy.env"
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "mixed docs + workflow (both non-impacting) is NOT image impact" {
    run_classify "README.md" ".github/workflows/codeql.yml"
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

@test "mixed non-impacting + one service file IS image impact" {
    run_classify "README.md" ".github/workflows/codeql.yml" "services/dns/entrypoint.sh"
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "empty diff is not docs_only and not image impact" {
    : > "$files"
    CHANGED_FILES="$files" run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val docs_only)" = "false" ]
    [ "$(val IMAGE_IMPACT)" = "false" ]
}

# --- --all-changed push fail-safe (#1095) ---

# When build-push.yml's detect-changes push step cannot diff github.event.before
# (all-zeros first push, force-push, GC'd base), it calls the classifier with
# --all-changed so an undeterminable diff degrades to "rebuild/retest
# everything" instead of silently skipping a real change. Every per-service and
# per-path build/test-scoping boolean must come back true, IMAGE_IMPACT true.
@test "--all-changed forces every build/test-scoping boolean true" {
    run bash "$script" --all-changed
    [ "$status" -eq 0 ]
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val dns_rust)" = "true" ]
    [ "$(val ui)" = "true" ]
    [ "$(val watchdog)" = "true" ]
    [ "$(val dhcp)" = "true" ]
    [ "$(val dhcp_proxy)" = "true" ]
    [ "$(val build_tools)" = "true" ]
    [ "$(val syslog)" = "true" ]
    [ "$(val utilities)" = "true" ]
    [ "$(val workflow)" = "true" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

# docs_only must be false in the fallback: "everything changed" is never a
# docs-only skip, so no downstream consumer can treat the fail-safe as a
# reason to skip heavy work.
@test "--all-changed is never docs_only" {
    run bash "$script" --all-changed
    [ "$status" -eq 0 ]
    [ "$(val docs_only)" = "false" ]
}

# The fallback must not depend on (or read) any diff input: it stays correct
# even with a stale CHANGED_FILES pointing at a docs-only list in the
# environment, because --all-changed short-circuits before any file is read.
@test "--all-changed ignores a stale CHANGED_FILES docs-only list" {
    printf '%s\n' "README.md" > "$files"
    CHANGED_FILES="$files" run bash "$script" --all-changed
    [ "$status" -eq 0 ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
    [ "$(val docs_only)" = "false" ]
    [ "$(val ui)" = "true" ]
}

# --- CodeQL Rust relevance (AG-CODE-013 consolidation, PR #1523; previously
# tests/bats/classify_codeql_rust_relevance.bats, a separate file testing this
# same script's codeql_rust output key) ---
#
# These cases pin the boundary that lets codeql.yml consume this shared
# classifier instead of maintaining a second list of Rust and CI inputs.

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
