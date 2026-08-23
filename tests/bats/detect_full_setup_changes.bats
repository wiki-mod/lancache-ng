#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free, git-free unit coverage for scripts/untracked/detect-full-setup-changes.sh
# (#715). Feeds canned changed-file lists (via CHANGED_FILES) and asserts the
# per-service flags + should_run gate + docs_only handling, so the deep gate's
# "run or skip, and which services need a staging image" decisions stay
# correct as paths are added. Mirrors build-push.yml's detect-changes rules.

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
    # A change to this file must run the suite (should_run) yet leave workflow
    # false: build-push does not rebuild services for it, so forcing the
    # staging guard would fail closed on tags that were never pushed.
    run_detect ".github/workflows/full-setup-deep-validate.yml"
    [ "$(val workflow)" = "false" ]
    [ "$(val should_run)" = "true" ]
}

@test "a genuinely global composite action change counts as a workflow change (guard + run)" {
    run_detect ".github/actions/ghcr-build-push-retry/action.yml"
    [ "$(val workflow)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

# derive-validation-network is narrowed to the shared classifier's own
# validation_infra output, not workflow (#1095 Holzhammer fix) -- should_run
# still goes true via this detector's own broad .github/actions/ prefix
# check below, independent of the narrower shared workflow verdict.
@test "a narrowly-scoped composite action still runs the suite without forcing the workflow guard" {
    run_detect ".github/actions/derive-validation-network/action.yml"
    [ "$(val workflow)" = "false" ]
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
    run_detect "scripts/untracked/simulations/ssl-mitm-cache-simulation.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val setup_runtime)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

# Issue #1095: a CI-tooling-only script (verified zero stack
# dependency, now living under scripts/tracked/ -- see that directory's own
# README and detect-full-setup-changes.sh's header comment for the full
# history) must no longer force the deep suite to run on its own. Reproduces
# the real, confirmed regression (PR #1333, run 30616274721: touching only
# AGENTS.md + the then-flat scripts/check-pr-title-convention.sh ran the
# full ~15-job simulation suite) so this test fails again if the narrowing
# regresses. This now exercises the scripts/tracked/ prefix match, not the
# (now-empty) ci_tooling_only_scripts array -- see the dedicated array-is-
# empty test below for that.
@test "CI-tooling-only script change alone does not force should_run" {
    run_detect "AGENTS.md" "scripts/tracked/check-pr-title-convention.sh"
    [ "$(val scripts)" = "true" ]
    [ "$(val should_run)" = "false" ]
}

# Follow-up (post-v0.3.0-release execution, issue #1095): once every
# individually-verified CI-tooling-only script actually moved into
# scripts/tracked/ (git mv, not a fresh add), the by-name
# ci_tooling_only_scripts array became redundant -- scripts/tracked/'s own
# directory-prefix match (exercised above and by the dedicated prefix test
# below) covers every one of them already. Asserts the array is genuinely
# empty, not merely unused, so a future accidental re-population (e.g. a
# careless revert) is caught here rather than silently reintroducing
# by-name maintenance the directory-prefix design was meant to retire.
@test "ci_tooling_only_scripts array is empty now that scripts/tracked/ is populated" {
    # The script has no "am I sourced" guard -- it always runs emit() at the
    # bottom -- so source it (rather than exec it) inside a subshell with a
    # real CHANGED_FILES fixture, redirecting emit()'s own stdout away, then
    # read the array variable back directly. This is a stronger check than
    # grepping the script's source text for array entries: it reads the
    # variable's real runtime state after the script's own declaration ran.
    : > "$files"
    array_count="$(CHANGED_FILES="$files" bash -c '
        set -euo pipefail
        # shellcheck disable=SC1090
        source "'"$script"'" >/dev/null
        printf "%d" "${#ci_tooling_only_scripts[@]}"
    ')"
    [ "$array_count" = "0" ]
}

@test "a mix of an allowlisted CI-tooling script and a real simulation script still runs the suite" {
    # Not every touched scripts/ path is on the allowlist here, so should_run
    # must stay true -- the allowlist only narrows the all-safe case, never a
    # mixed diff.
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
    # Mirrors the dhcp/dhcp-proxy test above: a services/ntp/ change must set
    # ntp=true (and only ntp, not the unrelated dhcp flags) so
    # ensure-pr-staging-images.sh's fail-closed guard treats a PR that
    # actually changes the ntp container as touched, instead of silently
    # backfilling it from the base commit.
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
    # services/proxy/Dockerfile COPYs this exact file into the proxy image
    # (the dns-domains named build context), so a domain-list-only change
    # must force a proxy rebuild too, not just dns_image -- otherwise the
    # proxy image's baked-in /etc/nginx/cdn-domains.txt goes stale.
    run_detect "services/dns/cdn-domains.txt"
    [ "$(val proxy)" = "true" ]
    [ "$(val dns_image)" = "true" ]
    [ "$(val should_run)" = "true" ]
}

# --- Parity with the shared classify-image-impact.sh (AG-CODE-013
# consolidation, PR #1523; previously
# tests/bats/detect_full_setup_classifier_parity.bats, a separate file) ---
#
# Locks this detector's shared output contract to the authoritative
# image-impact classifier so future path additions cannot silently drift.

# This mixed diff exercises the special DNS-domain proxy dependency, a second
# service, build-tools, a shared action, setup runtime, and deploy assembly in
# one fixture. Every overlapping verdict must be byte-for-byte identical.
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
        deploy scripts setup_runtime workflow docs_only
    )
    for key in "${shared_keys[@]}"; do
        detector_value="$(value_from "$detector_output" "$key")"
        classifier_value="$(value_from "$classifier_output" "$key")"
        [ "$detector_value" = "$classifier_value" ]
    done

    # The full-setup-only policy remains deliberately local and must still run
    # for this runtime/build/deploy-affecting mixed diff.
    [ "$(value_from "$detector_output" should_run)" = "true" ]
}
