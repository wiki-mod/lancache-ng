#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Guards the `services_with_healthcheck="..."` literal against silent
# divergence (issue #822 pattern audit, 2026-07-17).
#
# There are two distinct groups, deliberately NOT held to the same value:
#
# 1. The three workflow jobs that all wait on the SAME full-setup compose
#    target (deploy/full-setup/docker-compose.yml) -- build-push.yml,
#    full-setup-validate.yml, full-setup-deep-validate.yml -- copy-pasted
#    the identical "Wait for the stack to stabilize and check container
#    health" step three times with no guard preventing one copy's service
#    list from silently drifting from the other two while a service
#    gains/loses a real Docker healthcheck. These three MUST stay
#    byte-identical.
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

@test "build-push.yml, full-setup-validate.yml, full-setup-deep-validate.yml agree byte-for-byte on services_with_healthcheck" {
    bp="$(extract_services_with_healthcheck "$repo_root/.github/workflows/build-push.yml")"
    fsv="$(extract_services_with_healthcheck "$repo_root/.github/workflows/full-setup-validate.yml")"
    fsdv="$(extract_services_with_healthcheck "$repo_root/.github/workflows/full-setup-deep-validate.yml")"

    [ -n "$bp" ] || fail "build-push.yml: services_with_healthcheck not found"
    [ -n "$fsv" ] || fail "full-setup-validate.yml: services_with_healthcheck not found"
    [ -n "$fsdv" ] || fail "full-setup-deep-validate.yml: services_with_healthcheck not found"

    [ "$bp" = "$fsv" ] || fail "build-push.yml ('$bp') diverges from full-setup-validate.yml ('$fsv')"
    [ "$fsv" = "$fsdv" ] || fail "full-setup-validate.yml ('$fsv') diverges from full-setup-deep-validate.yml ('$fsdv')"
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
