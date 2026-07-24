#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Guards the `services_with_healthcheck="..."` literal against silent
# divergence (issue #822 pattern audit, 2026-07-17).
#
# There are two distinct groups, deliberately NOT held to the same value:
#
# 1. The three workflow entry points that all wait on the SAME full-setup
#    compose target (deploy/full-setup/docker-compose.yml) -- build-push.yml,
#    full-setup-validate.yml, full-setup-deep-validate.yml. Before issue #1112
#    each one copy-pasted an identical "Wait for the stack to stabilize and
#    check container health" step inline, and this test compared the three
#    literals byte-for-byte. #1112 (ci: extract shared full-setup jobs into
#    reusable workflow + composite actions) replaced all three copies with one
#    shared source: build-push.yml's own full-setup-validate job now calls the
#    `.github/actions/wait-validation-stack-health` composite action directly,
#    and full-setup-validate.yml/full-setup-deep-validate.yml each delegate
#    their full-setup-validate job to the `.github/workflows/full-setup-sims.yml`
#    reusable workflow, whose own full-setup-validate job calls that same
#    composite action. The three-file byte-identity check this test used to
#    run is now structurally impossible to violate (there is only one place
#    left to hold the list), so the check below instead asserts the shape that
#    replaced it: the composite action carries a real, non-empty
#    services_with_healthcheck list, and all three original entry points still
#    route to it (directly or via full-setup-sims.yml) instead of any of them
#    silently regaining an inline, independently-drifting copy (issue #1171).
#    Scoped to current_dev's post-#1112 topology only -- master and any
#    archived vY.X.Z branch still predate #1112 and keep the original
#    byte-for-byte-across-three-files shape, so this rewrite is not
#    cherry-picked there.
# 2. scripts/setup-cli-simulation.sh and scripts/syslog-forwarding-
#    simulation.sh wait on a DIFFERENT compose target
#    (deploy/quickstart/docker-compose.yml) with different profiles enabled
#    (minimal vs. ssl+logging), so they legitimately track a different,
#    smaller/larger subset of services that declare a real healthcheck in
#    THAT profile. These are intentionally NOT compared against group 1 or
#    each other for full equality -- each has its own documented rationale
#    inline. This test only guards against the failure mode actually found
#    during this audit: a service that DOES declare a real Docker
#    HEALTHCHECK in the relevant compose file silently missing from the
#    matching services_with_healthcheck list (which downgrades its
#    verification to the weaker "running + restart-count ceiling" check
#    meant for services with no healthcheck at all).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# Extracts the RHS of the first `services_with_healthcheck="..."` (or
# `local services_with_healthcheck="..."`) assignment in a file.
extract_services_with_healthcheck() {
    grep -oE '(local )?services_with_healthcheck="[^"]*"' "$1" | head -1 | sed -E 's/^(local )?services_with_healthcheck="//; s/"$//'
}

@test "build-push.yml, full-setup-validate.yml, full-setup-deep-validate.yml all route to the shared wait-validation-stack-health composite action that carries services_with_healthcheck" {
    action_file="$repo_root/.github/actions/wait-validation-stack-health/action.yml"
    [ -f "$action_file" ] || fail "$action_file not found"

    hc="$(extract_services_with_healthcheck "$action_file")"
    [ -n "$hc" ] || fail "wait-validation-stack-health/action.yml: services_with_healthcheck not found"

    # build-push.yml's own full-setup-validate job calls the composite action
    # directly (it does not go through full-setup-sims.yml).
    grep -q 'uses: \./\.github/actions/wait-validation-stack-health' "$repo_root/.github/workflows/build-push.yml" \
        || fail "build-push.yml no longer calls the wait-validation-stack-health composite action -- may have regressed to an inline, independently-drifting copy"

    # full-setup-validate.yml and full-setup-deep-validate.yml each delegate
    # their full-setup-validate job to the shared full-setup-sims.yml reusable
    # workflow, so verify both the delegation and that full-setup-sims.yml
    # itself still calls the composite action -- closing the full chain from
    # either caller down to the one real source of the list.
    grep -q 'uses: \./\.github/workflows/full-setup-sims\.yml' "$repo_root/.github/workflows/full-setup-validate.yml" \
        || fail "full-setup-validate.yml no longer calls the shared full-setup-sims.yml reusable workflow"
    grep -q 'uses: \./\.github/workflows/full-setup-sims\.yml' "$repo_root/.github/workflows/full-setup-deep-validate.yml" \
        || fail "full-setup-deep-validate.yml no longer calls the shared full-setup-sims.yml reusable workflow"
    grep -q 'uses: \./\.github/actions/wait-validation-stack-health' "$repo_root/.github/workflows/full-setup-sims.yml" \
        || fail "full-setup-sims.yml no longer calls the wait-validation-stack-health composite action -- full-setup-validate.yml/full-setup-deep-validate.yml would no longer be covered by it"
}

@test "syslog-forwarding-simulation.sh includes watchdog in services_with_healthcheck (regression guard)" {
    # deploy/quickstart/docker-compose.yml's watchdog service defines a real,
    # freshness-based (mtime) HEALTHCHECK -- it was previously omitted here
    # and silently downgraded to the weaker "running + restart-count" check
    # this script uses for services with no healthcheck at all (e.g.
    # docker-socket-proxy, syslog, syslog-ng). This test fails if that
    # regresses.
    list="$(extract_services_with_healthcheck "$repo_root/scripts/syslog-forwarding-simulation.sh")"
    [ -n "$list" ] || fail "syslog-forwarding-simulation.sh: services_with_healthcheck not found"
    [[ " $list " == *" watchdog "* ]] || fail "syslog-forwarding-simulation.sh's services_with_healthcheck ('$list') no longer includes watchdog, despite deploy/quickstart/docker-compose.yml's watchdog service defining a real HEALTHCHECK"
}

@test "syslog-forwarding-simulation.sh does not double-list watchdog between all_services and services_with_healthcheck" {
    all_line="$(grep -oE '^all_services="[^"]*"' "$repo_root/scripts/syslog-forwarding-simulation.sh" | head -1)"
    [ -n "$all_line" ] || fail "syslog-forwarding-simulation.sh: all_services assignment not found"
    # The static prefix before the interpolated $services_with_healthcheck
    # must not itself list watchdog a second time.
    prefix="$(printf '%s\n' "$all_line" | sed -E 's/^all_services="//; s/\$\{?services_with_healthcheck\}?.*$//; s/"$//')"
    [[ " $prefix " != *" watchdog "* ]] || fail "watchdog is listed both in all_services' static prefix ('$prefix') and services_with_healthcheck -- would appear twice in the loop"
}

@test "setup-cli-simulation.sh's smaller services_with_healthcheck list stays intentional (sanity: still a subset of all_services)" {
    # Not compared against the other files (deliberately a different,
    # smaller quickstart-minimal-profile list, per its own inline comment) --
    # this only guards the weaker invariant that every service claimed to
    # have a healthcheck is also a service this script actually starts.
    hc="$(extract_services_with_healthcheck "$repo_root/scripts/setup-cli-simulation.sh")"
    all="$(grep -oE 'local all_services="[^"]*"' "$repo_root/scripts/setup-cli-simulation.sh" | head -1 | sed -E 's/^local all_services="//; s/"$//')"
    [ -n "$hc" ] || fail "setup-cli-simulation.sh: services_with_healthcheck not found"
    [ -n "$all" ] || fail "setup-cli-simulation.sh: all_services not found"
    for svc in $hc; do
        [[ " $all " == *" $svc "* ]] || fail "setup-cli-simulation.sh: '$svc' is in services_with_healthcheck but not in all_services"
    done
}
