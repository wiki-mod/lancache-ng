#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free, git-free unit coverage for scripts/classify-image-impact.sh
# (#819). Feeds canned changed-file lists (via CHANGED_FILES) and asserts the
# per-path booleans this script inherited verbatim from build-push.yml's
# detect-changes job, plus the additive IMAGE_IMPACT verdict the promote job's
# version-bump logic consumes. The per-path booleans are covered so the
# extraction stays byte-for-byte equivalent to the inline job it replaced; the
# IMAGE_IMPACT cases pin the "does this diff warrant a patch (Z) bump?" boundary.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/classify-image-impact.sh"
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

@test "build-tools change: build_tools true" {
    run_classify "tools/build-tools/Dockerfile"
    [ "$(val build_tools)" = "true" ]
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

    run_classify "scripts/ssl-mitm-cache-simulation.sh"
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
