#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Unit coverage for scripts/untracked/classify-image-impact.sh (#819). Most
# cases feed canned changed-file lists (via CHANGED_FILES) and assert the
# per-path booleans this script inherited verbatim from build-push.yml's
# detect-changes job, plus the additive IMAGE_IMPACT verdict the promote
# job's version-bump logic consumes. The workflow_diff_is_comment_only
# section (G14) instead builds a small real git repo, since that function
# diffs the touched build-workflow paths against actual git history.

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
}

# G15: a full-setup-validate-only action must set validation_infra, not the
# global workflow signal -- it has no build-image consumer at all, and PR
# #1634 showed the old blanket ".github/actions/* -> workflow=true" rule
# forces every service to rebuild for a change that only affects the
# full-setup validation stack.
@test "G15: full-setup-validate-only action sets validation_infra, not workflow" {
    run_classify ".github/actions/derive-validation-network/action.yml"
    [ "$(val validation_infra)" = "true" ]
    [ "$(val workflow)" = "false" ]

    run_classify ".github/actions/reserve-validation-subnet-stack/action.yml"
    [ "$(val validation_infra)" = "true" ]
    [ "$(val workflow)" = "false" ]

    run_classify ".github/actions/wait-validation-stack-health/action.yml"
    [ "$(val validation_infra)" = "true" ]
    [ "$(val workflow)" = "false" ]
}

# What: rust-acceleration-preflight changes set only dns/ui/watchdog image
#   flags in the `build` job's matrix.rust, never the other services.
# Why: guards against the PR #1634 regression shape, where a change to one
#   shared action forced all 10 services to rebuild.
# From: Issue #1095
@test "G15: rust-acceleration-preflight change sets only dns_image/ui/watchdog, workflow false" {
    run_classify ".github/actions/rust-acceleration-preflight/action.yml"
    [ "$(val dns_image)" = "true" ]
    [ "$(val ui)" = "true" ]
    [ "$(val watchdog)" = "true" ]
    [ "$(val dns_rust)" = "false" ]
    [ "$(val proxy)" = "false" ]
    [ "$(val dhcp)" = "false" ]
    [ "$(val build_tools)" = "false" ]
    [ "$(val workflow)" = "false" ]
}

# G15: configure-rust-sccache/cargo-with-sccache-fallback are used by
# dns/ui/watchdog's own quality/test/cargo-audit jobs, never by the image
# build itself -- must not force proxy/dhcp/etc. to rebuild.
@test "G15: configure-rust-sccache change sets only dns_rust/ui/watchdog, workflow false" {
    run_classify ".github/actions/configure-rust-sccache/action.yml"
    [ "$(val dns_rust)" = "true" ]
    [ "$(val ui)" = "true" ]
    [ "$(val watchdog)" = "true" ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val proxy)" = "false" ]
    [ "$(val build_tools)" = "false" ]
    [ "$(val workflow)" = "false" ]

    run_classify ".github/actions/cargo-with-sccache-fallback/action.yml"
    [ "$(val dns_rust)" = "true" ]
    [ "$(val ui)" = "true" ]
    [ "$(val watchdog)" = "true" ]
    [ "$(val workflow)" = "false" ]
}

# G15: build-tools-candidate-smoke only validates a candidate build-tools
# image -- must not force the 9 product services to rebuild.
@test "G15: build-tools-candidate-smoke change sets only build_tools, workflow false" {
    run_classify ".github/actions/build-tools-candidate-smoke/action.yml"
    [ "$(val build_tools)" = "true" ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val ui)" = "false" ]
    [ "$(val watchdog)" = "false" ]
    [ "$(val workflow)" = "false" ]
}

# G15: a genuinely global action (consumed unconditionally by the shared
# build/merge-manifests/promote pipeline for every service) must still force
# workflow=true -- this is the one blast radius PR #1634's incident shape is
# actually correct for.
@test "G15: a genuinely global action change still sets workflow true" {
    run_classify ".github/actions/ghcr-build-push-retry/action.yml"
    [ "$(val workflow)" = "true" ]

    run_classify ".github/actions/trivy-scan-exact-digest/action.yml"
    [ "$(val workflow)" = "true" ]

    run_classify ".github/actions/ghcr-attest-retry/action.yml"
    [ "$(val workflow)" = "true" ]

    run_classify ".github/actions/buildx-setup-retry/action.yml"
    [ "$(val workflow)" = "true" ]

    run_classify ".github/actions/ghcr-attest-with-cache/action.yml"
    [ "$(val workflow)" = "true" ]
}

# G15: a pure PR-gate action (zero build/image relevance) must not force any
# service to rebuild.
@test "G15: a pure PR-gate action change does not set workflow or any service flag" {
    run_classify ".github/actions/file-headers-check/action.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val ui)" = "false" ]
    [ "$(val build_tools)" = "false" ]
    [ "$(val validation_infra)" = "false" ]
}

# G15 fail-closed case: a brand-new, never-before-seen action directory has
# no established consumer yet, so its blast radius is unknown -- must default
# to the maximal verdict (workflow=true) until a maintainer categorizes it,
# per this script's own touches_unmapped_action().
@test "G15: an unmapped/brand-new action directory fails closed to workflow true" {
    run_classify ".github/actions/brand-new-thing/some-file.yml"
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
    [ "$(val validation_infra)" = "true" ]
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

# --- workflow_diff_is_comment_only: content-aware workflow signal (G14, PR #1609 review) ---
#
# Needs real base/head refs to diff the touched build-workflow path with, so
# each case builds a tiny disposable repo instead of using run_classify's
# CHANGED_FILES path. Covers both Codex findings on the original #1609
# implementation: a leading '#' inside a YAML block-scalar body is real data,
# not a parsed comment (P1), and a binary or mode-only change carries no +/-
# content line to inspect at all (P2) -- both must fail closed, not default
# to "no violation found".

setup_g14_repo() {
    repo_dir="$BATS_TEST_TMPDIR/g14-repo"
    mkdir -p "$repo_dir/.github/workflows" "$repo_dir/.github/actions/some-action"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email test@example.com
    git -C "$repo_dir" config user.name test
    # The script resolves merge-base/diff against its own process cwd (it has
    # no --git-dir override), so every G14 case must run from inside the
    # disposable repo, not bats' own working directory.
    cd "$repo_dir" || return 1
}

commit_workflow_file() {
    # $1 = file content (heredoc-fed), $2 = commit message.
    cat > "$repo_dir/.github/workflows/build-push.yml"
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -q -m "$1"
    git -C "$repo_dir" rev-parse HEAD
}

commit_action_file() {
    # $1 = action directory name, $2 = commit message, stdin = file content.
    mkdir -p "$repo_dir/.github/actions/$1"
    cat > "$repo_dir/.github/actions/$1/action.yml"
    git -C "$repo_dir" add -A
    git -C "$repo_dir" commit -q -m "$2"
    git -C "$repo_dir" rev-parse HEAD
}

@test "G14: a changed '#' line inside a run: heredoc body is NOT comment-only" {
    setup_g14_repo
    base_sha="$(commit_workflow_file base <<'YAML'
jobs:
  build:
    steps:
      - run: |
          cat <<'EOF' > file.txt
          # marker-v1
          EOF
YAML
)"
    head_sha="$(commit_workflow_file head <<'YAML'
jobs:
  build:
    steps:
      - run: |
          cat <<'EOF' > file.txt
          # marker-v2
          EOF
YAML
)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

@test "G14: a genuine top-level comment-only change IS comment-only" {
    setup_g14_repo
    base_sha="$(commit_workflow_file base <<'YAML'
jobs:
  build:
    # a comment line v1
    steps:
      - run: echo hi
YAML
)"
    head_sha="$(commit_workflow_file head <<'YAML'
jobs:
  build:
    # a comment line v2, still just a comment
    steps:
      - run: echo hi
YAML
)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "false" ]
}

@test "G14: a blank-line-only change IS comment-only" {
    setup_g14_repo
    base_sha="$(commit_workflow_file base <<'YAML'
jobs:
  build:
    steps:
      - run: echo hi
YAML
)"
    head_sha="$(commit_workflow_file head <<'YAML'
jobs:
  build:

    steps:
      - run: echo hi
YAML
)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "false" ]
}

@test "G14: a binary change under .github/actions/ is NOT comment-only" {
    setup_g14_repo
    printf '\x00\x01binary-v1' > "$repo_dir/.github/actions/some-action/blob.bin"
    git -C "$repo_dir" add -A && git -C "$repo_dir" commit -q -m base
    base_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    printf '\x00\x01binary-v2-different' > "$repo_dir/.github/actions/some-action/blob.bin"
    git -C "$repo_dir" add -A && git -C "$repo_dir" commit -q -m head
    head_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

@test "G14: a mode-only change under .github/actions/ is NOT comment-only" {
    setup_g14_repo
    printf 'name: test\n' > "$repo_dir/.github/actions/some-action/action.yml"
    git -C "$repo_dir" add -A && git -C "$repo_dir" commit -q -m base
    base_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    # update-index --chmod is used instead of a filesystem chmod so this case
    # is exercised the same way on every runner OS, not only ones with real
    # POSIX executable bits.
    git -C "$repo_dir" update-index --chmod=+x .github/actions/some-action/action.yml
    git -C "$repo_dir" commit -q -m head
    head_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

@test "G14: an added (not modified) build-workflow file is NOT comment-only" {
    setup_g14_repo
    git -C "$repo_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    printf 'name: new\n' > "$repo_dir/.github/actions/some-action/action.yml"
    git -C "$repo_dir" add -A && git -C "$repo_dir" commit -q -m head
    head_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow)" = "true" ]
}

# --- Per-action comment-only awareness (G14 extended to touches_action) ---
#
# touches_action() applies the identical G14 content-diff check as
# workflow_diff_is_comment_only, scoped to one action directory, so a
# comment-only edit to a mapped action (e.g. a compression pass) does not
# force a rebuild for that action's consumers either.

@test "G14 per-action: a comment-only change to a mapped action does not touch its consumers" {
    setup_g14_repo
    base_sha="$(commit_action_file rust-acceleration-preflight base <<'YAML'
name: test
# a comment line v1
runs:
  using: composite
  steps: []
YAML
)"
    head_sha="$(commit_action_file rust-acceleration-preflight head <<'YAML'
name: test
# a comment line v2, still just a comment
runs:
  using: composite
  steps: []
YAML
)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val ui)" = "false" ]
    [ "$(val workflow)" = "false" ]
}

@test "G14 per-action: a substantive change to a mapped action DOES touch its consumers" {
    setup_g14_repo
    base_sha="$(commit_action_file rust-acceleration-preflight base <<'YAML'
name: test
runs:
  using: composite
  steps: []
YAML
)"
    head_sha="$(commit_action_file rust-acceleration-preflight head <<'YAML'
name: test
runs:
  using: composite
  steps:
    - run: echo hi
YAML
)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val ui)" = "true" ]
}

# --- workflow_reuse_scope: G14's job-scoped narrowing (a separate output
#     key from "workflow" -- see classify-image-impact.sh's own comment on
#     touches_build_workflow_reuse_scope for why the two are not merged) ---
#
# A realistic file with all 5 build-affecting jobs (preamble +
# detect-changes + determine-push-reuse-scope + determine-build-admission +
# build + build-arm64) present is required so the region extraction
# actually succeeds instead of failing closed -- proving the real
# narrowing, not the fail-closed fallback the G14 comment-only cases above
# already exercise incidentally with their minimal single-job fixtures.

realistic_build_push_yml() {
    # $1 = a marker string inserted into the named region ($2): "preamble",
    # "detect-changes", "build", or "merge-manifests" (a non-build-affecting
    # job, standing in for the real file's post-build jobs).
    local marker="$1" region="$2"
    cat <<YAML
on:
  push:
    branches: [current_dev]
env:
  MARKER: "$( [ "$region" = preamble ] && printf '%s' "$marker" || printf base )"
jobs:
  detect-changes:
    name: detect changed paths
    steps:
      - run: echo "$( [ "$region" = detect-changes ] && printf '%s' "$marker" || printf base )"
  determine-push-reuse-scope:
    name: determine push reuse scope
    steps:
      - run: echo base
  determine-build-admission:
    name: determine build admission
    steps:
      - run: echo base
  build:
    name: build
    steps:
      - run: echo "$( [ "$region" = build ] && printf '%s' "$marker" || printf base )"
  build-arm64:
    name: build-arm64
    steps:
      - run: echo base
  merge-manifests:
    name: merge multi-platform manifests
    steps:
      - run: echo "$( [ "$region" = merge-manifests ] && printf '%s' "$marker" || printf base )"
YAML
}

@test "G14 job-scoping: a merge-manifests-only change does NOT set workflow_reuse_scope (PR #1642 shape), but still sets workflow" {
    setup_g14_repo
    base_sha="$(realistic_build_push_yml v1 merge-manifests | commit_workflow_file base)"
    head_sha="$(realistic_build_push_yml v2 merge-manifests | commit_workflow_file head)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "false" ]
    [ "$(val workflow)" = "true" ]
}

@test "G14 job-scoping: a build-job-only change DOES set workflow_reuse_scope" {
    setup_g14_repo
    base_sha="$(realistic_build_push_yml v1 build | commit_workflow_file base)"
    head_sha="$(realistic_build_push_yml v2 build | commit_workflow_file head)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "true" ]
}

@test "G14 job-scoping: a detect-changes-only change DOES set workflow_reuse_scope" {
    setup_g14_repo
    base_sha="$(realistic_build_push_yml v1 detect-changes | commit_workflow_file base)"
    head_sha="$(realistic_build_push_yml v2 detect-changes | commit_workflow_file head)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "true" ]
}

@test "G14 job-scoping: a preamble-only change (env:/on:) DOES set workflow_reuse_scope" {
    setup_g14_repo
    base_sha="$(realistic_build_push_yml v1 preamble | commit_workflow_file base)"
    head_sha="$(realistic_build_push_yml v2 preamble | commit_workflow_file head)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "true" ]
}

@test "G14 job-scoping: a renamed build-affecting job fails closed to workflow_reuse_scope true" {
    setup_g14_repo
    base_sha="$(realistic_build_push_yml v1 build | commit_workflow_file base)"
    head_sha="$(realistic_build_push_yml v1 build | sed 's/^  build:$/  build-renamed:/' | commit_workflow_file head)"
    run bash "$script" "$base_sha" "$head_sha"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "true" ]
}

@test "G14 job-scoping: CHANGED_FILES mode (no ref context) still fails closed to workflow_reuse_scope true" {
    setup_g14_repo
    printf '.github/workflows/build-push.yml\n' > "$BATS_TEST_TMPDIR/changed.txt"
    CHANGED_FILES="$BATS_TEST_TMPDIR/changed.txt" run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val workflow_reuse_scope)" = "true" ]
}
