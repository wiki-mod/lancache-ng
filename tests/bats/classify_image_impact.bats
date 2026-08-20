#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free unit coverage for scripts/untracked/classify-image-impact.sh
# (#819). Most cases feed canned changed-file lists (via CHANGED_FILES, no git
# repo needed) and assert the per-path booleans this script inherited verbatim
# from build-push.yml's detect-changes job, plus the additive IMAGE_IMPACT
# verdict the promote job's version-bump logic consumes. The per-path booleans
# are covered so the extraction stays byte-for-byte equivalent to the inline
# job it replaced; the IMAGE_IMPACT cases pin the "does this diff warrant a
# patch (Z) bump?" boundary.
#
# The "content-aware workflow diff" section near the end (issue #1095, G14) is
# the one part of this file that is NOT git-free: workflow_diff_is_comment_only
# only activates in the script's <base_ref> <head_ref> git-diff invocation
# form, which has no CHANGED_FILES equivalent to fake -- those cases build a
# real disposable git repo (mirroring tests/bats/push_reuse.bats's own
# git-repo-per-test convention) and run the script against real commits.

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

# --- Content-aware workflow diff (issue #1095, G14) ---
#
# workflow_diff_is_comment_only only has real diff content to read in the
# script's <base_ref> <head_ref> form (see this file's own header comment for
# why), so these cases build a real disposable git repo per test -- mirroring
# tests/bats/push_reuse.bats's own git-repo-per-test convention -- instead of
# feeding a canned CHANGED_FILES list like every case above.

# Creates an empty git repo under a fresh temp dir and points $git_dir at it.
# Called explicitly only by the cases below, not automatically by setup(),
# since every other case in this file has no need to pay for a real git repo.
setup_git_repo() {
    git_dir="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$git_dir/.github/workflows"
    git -C "$git_dir" init -q
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
}

# Runs the classifier in <base_ref> <head_ref> form from inside $git_dir and
# captures key=value stdout/status, the same way run_classify does above for
# the CHANGED_FILES form.
run_classify_git() {
    cd "$git_dir"
    run bash "$script" "$1" "$2"
}

@test "G14: comment-only build-push.yml diff sets workflow=false" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    printf 'jobs:\n  build:\n    steps:\n      # explains why the step below exists\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m comment_only
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "false" ]
}

@test "G14: a real build-push.yml logic-line change still sets workflow=true" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi there\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m real_change
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

# A trailing comment edited on an otherwise-unchanged code line is NOT
# recognized as comment-only (the whole line differs, and it does not itself
# start with '#') -- deliberately conservative/fail-closed, not exhaustive:
# this script's own header comment documents that only whole blank/'#' lines
# are proven safe, not every possible shape of a comment-only edit.
@test "G14: an edited trailing same-line comment still sets workflow=true (conservative, not exhaustive)" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi # now with a trailing note\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m trailing_comment_edit
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

@test "G14: comment-only workflow diff alongside a real unrelated service change still reports the service change; workflow stays false" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    mkdir -p "$git_dir/services/ntp"
    printf 'ntp code\n' > "$git_dir/services/ntp/entrypoint.sh"
    printf 'jobs:\n  build:\n    steps:\n      # a second, also-safe comment\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m mixed
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val ntp)" = "true" ]
    [ "$(val workflow)" = "false" ]
    [ "$(val IMAGE_IMPACT)" = "true" ]
}

@test "G14: a new composite action file with real content still sets workflow=true" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    mkdir -p "$git_dir/.github/actions/new-action"
    printf "name: 'new-action'\nruns:\n  using: composite\n  steps:\n    - run: echo built\n      shell: bash\n" > "$git_dir/.github/actions/new-action/action.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m new_action
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

@test "G14: a comment-only .github/actions/ diff also sets workflow=false" {
    setup_git_repo
    mkdir -p "$git_dir/.github/actions/new-action"
    printf "name: 'new-action'\nruns:\n  using: composite\n  steps:\n    - run: echo built\n      shell: bash\n" > "$git_dir/.github/actions/new-action/action.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    printf "name: 'new-action'\n# why this step exists\nruns:\n  using: composite\n  steps:\n    - run: echo built\n      shell: bash\n" > "$git_dir/.github/actions/new-action/action.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m comment_only
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "false" ]
}

# touches_codeql_rust() ORs in touches_build_workflow() (a build-affecting
# workflow file is also a CodeQL-relevant input), so this content-aware
# refinement changes codeql_rust too, not only workflow -- a real, deliberate
# side effect (a comment-only build-push.yml diff cannot affect what CodeQL
# extracts either), not an accidental one, but it needs its own coverage in
# the git-diff form since the existing CHANGED_FILES-mode codeql_rust cases
# above are untouched by this change and would not have caught a regression.
@test "G14: a comment-only build-push.yml diff also sets codeql_rust=false (no other CodeQL-relevant path touched)" {
    setup_git_repo
    printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m base
    base="$(git -C "$git_dir" rev-parse HEAD)"

    printf 'jobs:\n  build:\n    steps:\n      # explains why the step below exists\n      - run: echo hi\n' > "$git_dir/.github/workflows/build-push.yml"
    git -C "$git_dir" add -A && git -C "$git_dir" commit -q -m comment_only
    head_rev="$(git -C "$git_dir" rev-parse HEAD)"

    run_classify_git "$base" "$head_rev"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "false" ]
    [ "$(val codeql_rust)" = "false" ]
}
