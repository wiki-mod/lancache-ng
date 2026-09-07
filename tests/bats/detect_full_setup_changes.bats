#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#


setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/detect-full-setup-changes.sh"
    classifier="$repo_root/scripts/untracked/classify-image-impact.sh"
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

# Extract the value of a single output key from an arbitrary captured text
# blob, not just the current $output -- needed below where two different
# scripts' outputs must be compared against each other in the same test.
value_from() {
    local text="$1" wanted="$2" line
    while IFS= read -r line; do
        if [[ "$line" == "$wanted="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done <<< "$text"
    return 1
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
    [ "$(val workflow_reuse_scope)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "syslog change: syslog touched, should_run true, docs_only false (#1428)" {
    run_detect "services/syslog/entrypoint.sh"
    [ "$status" -eq 0 ]
    [ "$(val syslog)" = "true" ]
    [ "$(val proxy)" = "false" ]
    [ "$(val should_run)" = "true" ]
    [ "$(val docs_only)" = "false" ]
}

@test "this deep workflow itself runs the suite but does NOT force the staging guard" {

    run_detect ".github/workflows/full-setup-deep-validate.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val workflow_reuse_scope)" = "false" ]
    [ "$(val should_run)" = "true" ]
}


@test "full-setup-validate-only composite action runs the suite but does not force workflow" {
    run_detect ".github/actions/derive-validation-network/action.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val workflow_reuse_scope)" = "false" ]
    [ "$(val should_run)" = "true" ]
}

@test "an unrelated workflow change runs the suite but does not force the guard" {
    run_detect ".github/workflows/codeql.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val workflow_reuse_scope)" = "false" ]
    [ "$(val should_run)" = "true" ]
}

@test "setup.sh change: setup_runtime true, should_run true" {
    run_detect "setup.sh"
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "scripts change: scripts + setup_runtime true, should_run true" {
    run_detect "scripts/untracked/simulations/ssl-mitm-cache-simulation.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val should_run)" = "true" ]
}


@test "CI-tooling-only script change alone does not force should_run" {
    run_detect "AGENTS.md" "scripts/tracked/check-pr-title-convention.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val should_run)" = "false" ]
}


@test "scripts/ci/ci.sh alone does not force should_run (exact-file allowlist)" {
    run_detect "scripts/ci/ci.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val should_run)" = "false" ]
}


@test "a mix of scripts/ci/ci.sh and an unclassified script still runs the suite" {
    run_detect "scripts/ci/ci.sh" "scripts/some-brand-new-script-not-yet-classified.sh"
    [ "$(val should_run)" = "true" ]
}


@test "ci_tooling_only_scripts array holds exactly the verified scripts/ci/ci.sh entry" {
    : > "$files"
    array_contents="$(CHANGED_FILES="$files" bash -c '
        set -euo pipefail
        # shellcheck disable=SC1090
        source "'"$script"'" >/dev/null
        printf "%d\n" "${#ci_tooling_only_scripts[@]}"
        printf "%s\n" "${ci_tooling_only_scripts[@]}"
    ')"
    [ "$(printf '%s' "$array_contents" | sed -n 1p)" = "1" ]
    [ "$(printf '%s' "$array_contents" | sed -n 2p)" = "scripts/ci/ci.sh" ]
}

@test "a mix of an allowlisted CI-tooling script and a real simulation script still runs the suite" {

    run_detect "scripts/tracked/check-pr-title-convention.sh" "scripts/untracked/simulations/ssl-mitm-cache-simulation.sh"
    [ "$(val should_run)" = "true" ]
}

@test "an unclassified/new scripts/ file still fails closed to should_run true" {
    run_detect "scripts/some-brand-new-script-not-yet-classified.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

@test "scripts/lib/ changes still fail closed to should_run true (allowlist never widens to a prefix)" {
    run_detect "scripts/lib/ghcr-retry.sh"
    [ "$(val should_run)" = "true" ]
}

@test "any path under scripts/tracked/ is recognized as CI-tooling-only, even without an array entry" {
    run_detect "scripts/tracked/some-newly-migrated-guard.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val should_run)" = "false" ]
}

@test "scripts/untracked/ gets no special prefix handling and still fails closed to should_run true" {
    run_detect "scripts/untracked/some-utility.sh"
    [ "$(val scripts)" = "true" ]
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

@test "ntp change: ntp touched, should_run true (#1296)" {

    run_detect "services/ntp/entrypoint.sh"
    [ "$(val ntp)" = "true" ]
    [ "$(val dhcp)" = "false" ]
    [ "$(val dhcp_proxy)" = "false" ]
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

    run_detect "services/dns/cdn-domains.txt"
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

# --- Parity with the shared classify-image-impact.sh (AG-CODE-013

@test "full-setup shared verdicts exactly match the common classifier" {
    cat > "$files" <<'EOF'
services/dns/cdn-domains.txt
services/syslog/entrypoint.sh
tools/build-tools/Dockerfile
.github/actions/configure-rust-sccache/action.yml
setup.sh
deploy/full-setup/docker-compose.yml
EOF

    CHANGED_FILES="$files" GITHUB_OUTPUT="" run bash "$script"
    [ "$status" -eq 0 ]
    detector_output="$output"

    CHANGED_FILES="$files" run bash "$classifier"
    [ "$status" -eq 0 ]
    classifier_output="$output"

    shared_keys=(
        proxy dns_image ui watchdog dhcp dhcp_proxy ntp syslog build_tools
        deploy scripts setup_runtime workflow workflow_reuse_scope docs_only
    )
    for key in "${shared_keys[@]}"; do
        detector_value="$(value_from "$detector_output" "$key")"
        classifier_value="$(value_from "$classifier_output" "$key")"
        [ "$detector_value" = "$classifier_value" ]
    done

    [ "$(value_from "$detector_output" should_run)" = "true" ]
}
