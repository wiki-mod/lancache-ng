#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# CI guard against the exact regression issue #1169 was filed for: a service
# defined in deploy/*/docker-compose.yml with no `healthcheck:` block at all,
# so `docker inspect --format '{{.State.Health.Status}}'` reads `.State.Health`
# as entirely absent ("none") rather than merely "starting"/"unhealthy" --
# invisible to any watchdog-style monitoring by construction, not just
# unmonitored. Before #1169, `dhcp-proxy`, `ntp`, `netdata`, and
# `docker-socket-proxy` had exactly this gap across one or more deploy
# profiles; this script fails CI the moment a service (existing or newly
# added) regresses back into it. Mirrors scripts/untracked/check-file-headers.sh's
# CI-enforced-convention shape (grep-based text scan, not a semantic parser,
# with an explicit, commented exclusion list) per issue #1169's own pointer.
#
# Deliberately NOT implemented as `docker compose config --format json` piped
# to a JSON query, for two independent reasons found while scoping this
# script:
#   1. Profiles: `dhcp`, `dhcp-proxy`, `ntp`, `syslog`, `syslog-ng` are all
#      gated behind a Compose `profiles:` key. `docker compose config` omits
#      a profile-gated service unless that exact profile is active, so a
#      naive invocation would never even see dhcp-proxy/ntp -- silently
#      "passing" while enforcing nothing on precisely the services #1169
#      exists for.
#   2. Required env: deploy/prod and deploy/quickstart reference `:?`-guarded
#      variables (e.g. `${IP_STANDARD}`, `${LISTEN_IP:?...}` in
#      deploy/secondary), so `docker compose config` errors out on a bare
#      checkout with no populated `.env`, rather than producing something
#      this script could inspect.
# A direct text scan of the `services:` block sidesteps both: it sees every
# declared service regardless of profile gating or environment interpolation.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

# Optional first argument: an alternate root directory to scan instead of
# this repo's own root, so tests/bats/check_compose_healthchecks.bats can
# point this at a small throwaway deploy/*/docker-compose.yml fixture tree
# instead of requiring a full repo checkout -- same optional-override
# convention scripts/untracked/check-workflow-service-lists.sh already uses for the
# same reason. CI's real invocation passes no argument.
target_root="${1:-$repo_root}"
cd "$target_root"

# nullglob: without it, an UNMATCHED glob expands to its own literal pattern
# string ("deploy/*/docker-compose.yml") as a single array element instead of
# zero elements, so the "${#compose_files[@]} -eq 0" fail-closed check just
# below could never actually be true -- confirmed live: an empty target_root
# still produced a 1-element array, silently proceeding into the loop where
# `[[ -f "$f" ]] || continue` skipped the non-existent literal path, which
# only then fell through to this script's OTHER fail-closed check (`checked`
# staying 0). Both checks are fail-closed either way, but leaving the first
# one unreachable dead code (indistinguishable from a working guard by
# reading it alone) is exactly the AG-VAL-024 class of bug -- a real failing
# input must exercise a fail-closed branch, not just a passing run.
shopt -s nullglob

# Exactly this glob (not "docker-compose*.yml"): deploy/prod also ships
# docker-compose.nats-secondary.yml, an intentionally partial override file
# (see its own header) that redeclares only `nats:`'s `ports:` -- it has no
# `healthcheck:` of its own because it isn't meant to (the base file's nats
# healthcheck still applies once Compose merges the two), and scanning it
# directly would misreport that fragment as a service missing a healthcheck.
compose_files=(deploy/*/docker-compose.yml)

if [ "${#compose_files[@]}" -eq 0 ]; then
    echo "No deploy/*/docker-compose.yml files found; refusing to run a vacuous check." >&2
    exit 1
fi

# Services deliberately excluded from the healthcheck mandate, keyed by
# "<file>:<service>" so an exclusion is scoped to the exact file it was
# verified against rather than silently applying repo-wide. Each entry must
# be backed by a concrete, documented reason here -- this is a narrow,
# reasoned carve-out (matching AGENTS.md's "Documented Exceptions" format),
# not a way to quietly grow the excluded set.
#
# dhcp-probe (deploy/prod, deploy/quickstart): a one-shot, on-demand helper
# the Admin UI starts and stops itself to run a single DHCP-conflict probe
# (`restart: "no"`, confirmed the only service in any deploy/*/docker-
# compose.yml using that restart policy) -- never a long-running daemon, so a
# liveness healthcheck has no meaningful state to probe between "just
# started" and "already exited". Matches this project's existing precedent
# for the same container in docs/architecture-ng.md's logging matrix ("Not
# applicable ... no persistent process").
#
# syslog-logs-permissions (deploy/prod, deploy/quickstart): a one-shot
# ownership-migration init container (`restart: "no"`, `network_mode: none`,
# `read_only: true` root filesystem) that chowns the shared `logs` volume to
# the non-root syslog uid/gid before `syslog` starts, gated purely through
# `depends_on: condition: service_completed_successfully` -- same shape as
# dhcp-probe above: it runs to completion and exits, so there is no
# "healthy vs. degraded" state between "just started" and "already exited"
# for a liveness check to distinguish.
#
# retention (deploy/prod, deploy/quickstart, deploy/full-setup; #842 Teil 2,
# 2026-08-01): a deliberate choice, not an oversight -- this container's own
# liveness was intentionally never folded into the health-check/restart
# state machine (that separation from watchdog.sh is the whole point of
# #842's process split: a bug in file-retention logic must not be able to
# influence what the health-check reports or restarts). Inventing a
# heartbeat-file-based liveness probe here would be new scope beyond what
# this issue asked for. `restart: always` (`unless-stopped` in full-setup,
# matching that profile's own convention) still recovers a crashed or
# OOM-killed container the same way this project already accepts for other
# unmonitored services (dhcp-probe above, netdata). A lightweight heartbeat
# check is a reasonable future follow-up, tracked as such in PR #1360, not
# built speculatively here.
declare -A EXCLUDED_SERVICES=(
    ["deploy/prod/docker-compose.yml:dhcp-probe"]=1
    ["deploy/quickstart/docker-compose.yml:dhcp-probe"]=1
    ["deploy/prod/docker-compose.yml:syslog-logs-permissions"]=1
    ["deploy/quickstart/docker-compose.yml:syslog-logs-permissions"]=1
    ["deploy/prod/docker-compose.yml:retention"]=1
    ["deploy/quickstart/docker-compose.yml:retention"]=1
    ["deploy/full-setup/docker-compose.yml:retention"]=1
)

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

violations=0
checked=0

# check_file <path>
# Scans <path>'s top-level `services:` block, line by line, for service
# start markers and per-service `healthcheck:` blocks. State is tracked with
# two flags rather than a single regex pass over the whole file because
# top-level `networks:`/`volumes:` sections use the exact same 2-space-
# indented `name:` shape as a service name -- without confining the scan to
# between `services:` and the next top-level key, a network/volume entry
# (e.g. `docker-api:`, `proxy-cache:`) would be misreported as a service
# missing a healthcheck.
check_file() {
    local file="$1"
    local in_services=0 current_service="" current_has_hc=0
    local line lineno=0

    # finish_service: called when a new service starts (or the services
    # block ends) to record a verdict for whatever service was just scanned.
    finish_service() {
        [[ -n "$current_service" ]] || return 0
        checked=$((checked + 1))
        if [[ "$current_has_hc" -eq 0 ]]; then
            if [[ -n "${EXCLUDED_SERVICES["${file}:${current_service}"]:-}" ]]; then
                return 0
            fi
            fail_service "$file" "$current_service"
        fi
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        if [[ "$in_services" -eq 0 ]]; then
            # Deliberately an `if`, not `[[ "$line" == "services:" ]] &&
            # in_services=1`: under `set -e`, a bare "`cond && action`"
            # statement whose condition is legitimately false most of the
            # time (true only) would make THIS STATEMENT's own exit status
            # the false one on every other line, aborting the whole script
            # right here via errexit before it ever reaches the `continue`
            # below -- silently, with no error message. Confirmed live: this
            # exact shape killed an earlier version of this script after
            # processing only the first compose file. See AG-VAL-024 for the
            # same class of `set -e` footgun found elsewhere in this repo.
            if [[ "$line" == "services:" ]]; then
                in_services=1
            fi
            continue
        fi

        # A top-level key (column 0, e.g. "networks:", "volumes:", "name:")
        # ends the services block. Blank lines and comments never end it.
        if [[ "$line" =~ ^[A-Za-z] ]]; then
            finish_service
            in_services=0
            continue
        fi

        # New service start: exactly "  <name>:" (2-space indent, nothing
        # else on the line -- distinguishes it from a 2-space-indented list
        # item, a deeper property, or a value-bearing "  key: value" line).
        if [[ "$line" =~ ^\ \ [A-Za-z0-9_-]+:$ ]]; then
            finish_service
            current_service="${line#  }"
            current_service="${current_service%:}"
            current_has_hc=0
            continue
        fi

        # A service's own `healthcheck:` key always sits at exactly 4-space
        # indent (one level under the 2-space service name) in every
        # deploy/*/docker-compose.yml file in this repo -- deeper embedded
        # content (heredoc script bodies under `command: |`, etc.) is
        # indented 6+ spaces, so anchoring on exactly 4 spaces avoids a false
        # match on literal text that merely contains the word "healthcheck"
        # inside such a block.
        if [[ -n "$current_service" && "$line" == "    healthcheck:" ]]; then
            current_has_hc=1
        fi
    done < "$file"

    # EOF while still inside services: (no trailing top-level key after the
    # last service) -- finish whatever was being scanned. Same `if`-not-`&&`
    # reasoning as above: this is check_file's own last statement, so a bare
    # `&&` here would make a false condition (the normal, expected case: the
    # services: block already properly closed into networks:/volumes: before
    # EOF) this whole FUNCTION's exit status, which then kills the entire
    # script the moment the caller's own bare `check_file "$f"` statement
    # (below) observes it under `set -e`.
    if [[ "$in_services" -eq 1 ]]; then
        finish_service
    fi
}

fail_service() {
    local file="$1" service="$2"
    printf "%b[COMPOSE HEALTHCHECKS]%b %s: service '%s' has no healthcheck: block.\n" "$RED" "$NC" "$file" "$service" >&2
    violations=$((violations + 1))
}

for f in "${compose_files[@]}"; do
    [[ -f "$f" ]] || continue
    check_file "$f"
done

if [[ "$checked" -eq 0 ]]; then
    echo "No services found across ${compose_files[*]}; refusing to run a vacuous check." >&2
    exit 1
fi

if [[ "$violations" -gt 0 ]]; then
    printf "%b✗ %d service(s) missing a healthcheck: block.%b Every service in deploy/*/docker-compose.yml must define a real, specific healthcheck (see docs/architecture-ng.md's health-checks list for the established per-service patterns), or be added to this script's own documented EXCLUDED_SERVICES with a concrete reason; see issue #1169.\n" "$RED" "$violations" "$NC" >&2
    exit 1
fi

printf "%b✓ All %d checked service(s) across %s define a healthcheck (or are documented exclusions).%b\n" "$GREEN" "$checked" "${compose_files[*]}" "$NC"
exit 0
