#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free, git-free unit coverage for scripts/detect-full-setup-changes.sh
# (#715). Feeds canned changed-file lists (via CHANGED_FILES) and asserts the
# per-service flags + should_run gate + docs_only handling, so the deep gate's
# "run or skip, and which services need a staging image" decisions stay
# correct as paths are added. Mirrors build-push.yml's detect-changes rules.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/detect-full-setup-changes.sh"
    files="$BATS_TEST_TMPDIR/changed.txt"
}

# Run the detector against a canned file list and capture key=value stdout.
run_detect() {
    printf '%s\n' "$@" > "$files"
    CHANGED_FILES="$files" GITHUB_OUTPUT="" run bash "$script"
}

# Extract the value of a single output key from $output.
val() {
    printf '%s\n' "$output" | grep -E "^$1=" | cut -d= -f2-
}

@test "proxy change: proxy touched, should_run true, docs_only false" {
    run_detect "services/proxy/nginx.conf"
    [ "$status" -eq 0 ]
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "false" ]
    [ "$(val should_run)" = "true" ]
    [ "$(val docs_only)" = "false" ]
}

@test "docs-only change: should_run false, docs_only true" {
    run_detect "docs/install-ca-cert.md" "README.md"
    [ "$(val should_run)" = "false" ]
    [ "$(val docs_only)" = "true" ]
    [ "$(val proxy)" = "false" ]
}

@test "mixed docs + code: not docs_only, should_run true" {
    run_detect "README.md" "services/ui/src/main.rs"
    [ "$(val docs_only)" = "false" ]
    [ "$(val ui)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "deploy change: deploy touched drives should_run" {
    run_detect "deploy/full-setup/docker-compose.yml"
    [ "$(val deploy)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "workflow change: workflow true forces should_run" {
    run_detect ".github/workflows/build-push.yml"
    [ "$(val workflow)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "this deep workflow itself runs the suite but does NOT force the staging guard" {
    # A change to this file must run the suite (should_run) yet leave workflow
    # false: build-push does not rebuild services for it, so forcing the
    # staging guard would fail closed on tags that were never pushed.
    run_detect ".github/workflows/full-setup-deep-validate.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val should_run)" = "true" ]
}

@test "composite action change counts as a workflow change (guard + run)" {
    run_detect ".github/actions/derive-validation-network/action.yml"
    [ "$(val workflow)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "an unrelated workflow change runs the suite but does not force the guard" {
    run_detect ".github/workflows/codeql.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val should_run)" = "true" ]
}

@test "setup.sh change: setup_runtime true, should_run true" {
    run_detect "setup.sh"
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "scripts change: scripts + setup_runtime true, should_run true" {
    run_detect "scripts/ssl-mitm-cache-simulation.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "dhcp and dhcp-proxy flags are detected independently" {
    run_detect "services/dhcp/entrypoint.sh"
    [ "$(val dhcp)" = "true" ]
    [ "$(val dhcp_proxy)" = "false" ]
    [ "$(val should_run)" = "true" ]

    run_detect "services/dhcp-proxy/entrypoint.sh"
    [ "$(val dhcp)" = "false" ]
    [ "$(val dhcp_proxy)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "build-tools change: build_tools true, should_run true" {
    run_detect "tools/build-tools/Dockerfile"
    [ "$(val build_tools)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "empty diff is not docs_only and does not run" {
    : > "$files"
    CHANGED_FILES="$files" GITHUB_OUTPUT="" run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(val docs_only)" = "false" ]
    [ "$(val should_run)" = "false" ]
}

@test "dns nats-subscriber path still counts as a dns_image change" {
    run_detect "services/dns/nats-subscriber/src/main.rs"
    [ "$(val dns_image)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "cdn-domains.txt-only change also sets proxy=true (#771)" {
    # services/proxy/Dockerfile COPYs this exact file into the proxy image
    # (the dns-domains named build context), so a domain-list-only change
    # must force a proxy rebuild too, not just dns_image -- otherwise the
    # proxy image's baked-in /etc/nginx/cdn-domains.txt goes stale.
    run_detect "services/dns/cdn-domains.txt"
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val should_run)" = "true" ]
}
