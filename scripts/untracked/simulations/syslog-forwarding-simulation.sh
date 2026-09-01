#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Real end-to-end proof for issue #453's last two comments: it is not enough
# to show a log line reaches syslog-ng on disk -- the maintainer's own
# clarification (and #822 Pattern G: "a check that never really looked")
# requires proving the operator can actually SEE that line through the real
# Admin UI read path (routes/logs.rs -> syslog_client::parse_syslog_tail),
# not a second direct read of the log file. Every earlier check in this
# project's CI (scripts/tracked/check-logging-matrix.sh, `docker compose config`)
# only validates presence/shape, never a live data flow all the way to the
# UI's own HTTP response.
#
# For each wired service this script drives ONE real, distinguishable event
# (a real HTTP request, a real Admin UI form submission, a real NATS client
# connection -- never a synthetic line written directly into a log file),
# tagged with a marker unique to this run, then polls the Admin UI's own
# `/logs` route (the exact HTTP surface an operator uses) until that marker
# appears in the rendered response.
#
# SCOPE (increment 2 of 2, issue #864 -- increment 1 above covered the 7
# services below; #453 is closed, #864 tracks this remainder): `dhcp` (Kea)
# and `dhcp-proxy` (dnsmasq) are now also covered, as Triggers 7/8 further
# down. Both run `network_mode: host` in deploy/quickstart/docker-compose.yml
# in production (needed for real broadcast DHCP on the operator's actual
# LAN) -- exercising that unmodified on a shared CI runner would leak real
# DHCPDISCOVER broadcast traffic onto the runner host's own LAN interface,
# the same risk scripts/untracked/simulations/dhcp-kea-lease-flow-simulation.sh and
# scripts/untracked/simulations/dhcp-proxy-pxe-simulation.sh already avoid by using their own
# isolated bridge-network containers instead of quickstart's host-network
# services. This script does the same for its two DHCP triggers: a
# per-run compose override (`$work_dir/dhcp-test-override.yml`, built below)
# uses Compose's `!reset` merge tag (supported by this project's runners,
# Compose v5.3.0+) to null out `dhcp`/`dhcp-proxy`'s `network_mode: host` and
# instead attach each to its own dedicated, per-run bridge network
# (`dhcp-test-net` / `dhcp-proxy-test-net`, kept separate from each other and
# from the stack's own `default` network so neither DHCP server's broadcast
# traffic can reach the other or any unrelated stack container). This was
# confirmed live before writing this script: both `dhcp` and `dhcp-proxy`
# start and log normally under this override, and a real dhclient exchange
# against `dhcp` completes a full Discover/Offer/Request/Ack over the
# isolated bridge with no host-network involvement at all -- the logging
# path this script proves (service -> log file -> fluent-bit tail ->
# syslog-ng -> Admin UI `/logs`) is identical regardless of network mode,
# so this loses no coverage of what #864 actually asks for (central-logging
# E2E visibility), while dhcp-kea-lease-flow-simulation.sh/
# dhcp-proxy-pxe-simulation.sh remain the authority on real host-network/PXE
# protocol behavior. Because neither DHCP server ever binds a host-level
# port under this override (each gets its own bridge-network namespace),
# the "sequential, never-simultaneous bring-up" constraint #864 originally
# raised for host-network port contention does not apply here -- both run
# concurrently, each on its own isolated network.
#
# CORRECTION to #864's own framing (surfaced per AG-DOC-008/009): the issue
# body names deploy/full-setup/docker-compose.yml's missing dhcp/dhcp-proxy
# + `logging` profile as "the gap", describing full-setup as "the CI-only
# validation harness every E2E simulation script builds on". That does not
# hold for this script, which has used deploy/quickstart/docker-compose.yml
# as its base since increment 1 (see the COMPOSE BASE paragraph below,
# unchanged from before) -- and full-setup's own dummy images (per
# docs/naming-conventions.md) could not emit real Kea/dnsmasq log content
# even if the profile existed there. Per AG-DOC-002 (current code/CI
# behavior over issue prose), this increment extends quickstart, matching
# this script's own established base, not full-setup. Whether full-setup
# should separately gain dhcp/dhcp-proxy for AG-VAL-027 health-gate coverage
# is a distinct question this script does not resolve.
#
# COMPOSE BASE: deploy/quickstart/docker-compose.yml, not deploy/full-setup
# (which every earlier simulation script under this same directory uses).
# full-setup has
# neither the `logging` profile (syslog-ng/fluent-bit) nor dhcp/dhcp-proxy
# defined at all -- extending it would mean testing an unguarded copy of the
# logging wiring instead of the real thing scripts/tracked/check-logging-matrix.sh
# actually guards (prod/quickstart -- deploy/dev was retired in v0.3.0,
# #766). quickstart already has every service and the full logging profile,
# and is the same compose file scripts/untracked/simulations/setup-cli-simulation.sh already
# drives concurrently in CI via a unique COMPOSE_PROJECT_NAME + loopback IP
# + retry-on-collision -- reused here directly rather than inventing a
# second isolation mechanism.
#
# Getting a correct, fully-populated .env (~50 required values: NATS
# credentials, PDNS_API_KEY, DDNS_TSIG_KEY, etc.) is done by driving the
# REAL setup.sh CLI through `expect`, exactly like setup-cli-simulation.sh's
# own Phase 1 -- hand-crafting that many secrets/values here would risk
# silently drifting from what setup.sh actually generates. `Start now? [Y/n]`
# is answered "n": this script brings the stack up itself afterward.
#
# The wizard's "Enable central logging? [Y/n]" prompt defaults to enabled
# and this script accepts that default, so COMPOSE_PROFILES already contains
# `logging` and SYSLOG_ENABLED needs no fixing up by the time Phase 1
# finishes. Phase 2 below still sets both explicitly as a defense-in-depth
# double-check (its dedup logic is a no-op if `logging` is already present)
# rather than relying solely on the wizard default never regressing
# silently: an independent, redundant assertion of the desired end state,
# not a fixup path this script depends on.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/setup-wizard-introspect.sh
source "$repo_root/scripts/lib/setup-wizard-introspect.sh"

: "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# Same reason as setup-cli-simulation.sh: this script runs inside the
# build-tools container against a bind-mounted checkout owned by the host
# runner's UID, which git otherwise refuses as "dubious ownership".
git config --global --add safe.directory "$repo_root"

work_dir="$repo_root/.syslog-forwarding-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"
if ! install_dir="$(mktemp -d "$work_dir/install.XXXXXX")"; then
    echo "::error::Failed to create a unique install directory under $work_dir via mktemp." >&2
    exit 1
fi

# Loopback-only addressing (127.0.0.0/8 routes locally with no real
# interface needed, same reasoning setup-cli-simulation.sh's own comment
# gives for 127.0.0.2): derive a per-run octet from GITHUB_RUN_ID/ATTEMPT so
# two concurrent runs on the same shared self-hosted host don't contend for
# the same address for this whole stack's lifetime (setup-cli-simulation.sh
# only ever brings up a much smaller, faster-torn-down stack on a fixed
# 127.0.0.2 -- this script's stack stays up for the whole 7-service
# trigger/verify sweep, so a fixed address would collide far more easily).
run_key="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}-$$"
# cksum's first field is a portable (non-bash-specific) unsigned checksum;
# %200 keeps the derived octet in a fixed, small range while +10 avoids the
# low, sometimes-special-cased octets (0/1) some tooling assumes.
octet=$(( $(printf '%s' "$run_key" | cksum | cut -d' ' -f1) % 200 + 10 ))
ip_standard="127.0.${octet}.2"
ip_ssl="127.0.${octet}.3"

# Mirrors setup-cli-simulation.sh's identical helper: Compose validates
# COMPOSE_PROJECT_NAME against ^[a-z0-9][a-z0-9_-]*$, so the mktemp
# basename (mixed case, a literal dot) must be sanitized, not used verbatim.
sim_compose_project_name() {
    printf 'lancache-ng-syslog-e2e-%s\n' "$(basename "$1" | tr 'A-Z.' 'a-z-')"
}
if ! compose_project="$(sim_compose_project_name "$install_dir")"; then
    echo "::error::Failed to derive a sanitized Compose project name from install_dir ($install_dir)." >&2
    exit 1
fi
export COMPOSE_PROJECT_NAME="$compose_project"
network_name="${compose_project}_default"

# Issue #1415: this script drives the SAME deploy/quickstart/docker-compose.yml
# setup-cli-simulation.sh does, deliberately CONCURRENTLY with it within the
# same PR's own CI run (see scripts/lib/quickstart-compose-lock.sh's own
# header for why both jobs share one flock) -- so it needs the identical
# per-run container-name isolation, not just its own distinct
# COMPOSE_PROJECT_NAME/loopback IP above. Without this, two concurrent
# instances of this script (or one of this script and one of
# setup-cli-simulation.sh) would still collide on deploy/quickstart's fixed
# container_name: values regardless of already having distinct project
# names, exactly as issue #1415 describes. See that compose file's own
# top-of-file LANCACHE_CONTAINER_SUFFIX comment.
sim_container_name_suffix() {
    printf -- '-syslog-e2e-%s\n' "$(basename "$1" | tr 'A-Z.' 'a-z-')"
}
if ! LANCACHE_CONTAINER_SUFFIX="$(sim_container_name_suffix "$install_dir")"; then
    echo "::error::Failed to derive a sanitized LANCACHE_CONTAINER_SUFFIX from install_dir ($install_dir)." >&2
    exit 1
fi
export LANCACHE_CONTAINER_SUFFIX

# Unique per-run marker prefix. Deliberately alphanumeric-only (no special
# characters): it flows through a domain-name validator (routes/domains.rs
# rejects anything with '.'-less-than-2-labels, which is exactly the
# property this script relies on for the ui trigger below -- see that
# section), a DNS record name, and raw HTML text inside Tera-rendered
# `<td>` cells, so it must be safe absolutely everywhere it lands with no
# escaping surprises. date +%s%N (nanosecond epoch) + PID is unique enough
# for one CI run without needing a UUID generator that might not be
# installed in every build-tools image variant.
if ! marker_base="lancachee2e$(date +%s%N)pid$$"; then
    echo "::error::Failed to generate the per-run marker base via date +%s%N." >&2
    exit 1
fi
marker_proxy="${marker_base}proxy"
marker_ui="${marker_base}ui"
marker_nats="${marker_base}nats"
marker_dns="${marker_base}dns"
# CHECK_INTERVAL must remain a plausible non-negative integer for
# watchdog.sh's own `sleep "$CHECK_INTERVAL"` -- a purely numeric marker
# (last 8 digits of the nanosecond timestamp) still satisfies that while
# staying unique to this run. The real interval magnitude doesn't matter
# for this test: the value is logged once in watchdog's own startup banner
# (see watchdog.sh's `log "Interval: ${CHECK_INTERVAL}s | ..."`, which fires
# immediately at container start, long before the loop's own sleep call
# ever uses it) -- this script never actually waits out that interval.
if ! marker_watchdog="$(date +%s%N | tail -c 9)"; then
    echo "::error::Failed to generate the watchdog CHECK_INTERVAL marker via date +%s%N | tail." >&2
    exit 1
fi

# dhcp/dhcp-proxy test subnets (issue #864, Triggers 7/8): reuses the same
# per-run $octet already derived above for ip_standard/ip_ssl instead of a
# second collision-avoidance scheme -- both DHCP test networks are dedicated,
# per-run-named bridge networks (via COMPOSE_PROJECT_NAME), so the only real
# collision risk is two concurrent runs deriving the same $octet, exactly
# the same risk already accepted for ip_standard/ip_ssl above. Split as two
# /25s of one /24 (172.29.<octet>.0/25 and .128/25) rather than two
# independently-chosen /24s: one octet lookup covers both networks with no
# possibility of the two ranges overlapping each other, and 172.29.0.0/16 is
# not used by any other script in this repo (deploy/dev's now-retired
# 172.28.0.0/16, full-setup-validate's 172.30.0.0/16, and
# dhcp-kea-lease-flow-simulation.sh's 172.31.0.0/16 are all distinct ranges).
dhcp_gateway="172.29.${octet}.1"
dhcp_range_start="172.29.${octet}.10"
dhcp_range_end="172.29.${octet}.100"
dhcp_proxy_gateway="172.29.${octet}.129"
# dhcp-proxy's own dhcp-range=...,proxy directive (dnsmasq.conf.template)
# takes a single representative IP inside the subnet it proxies for, not a
# CIDR or range -- confirmed by reading that template. Used directly as this
# trigger's per-run marker (see Trigger 8 below): a real, operator-configured
# value that only differs from run to run, the same marker technique already
# established for the watchdog trigger's CHECK_INTERVAL above.
dhcp_proxy_subnet_start="172.29.${octet}.140"

cleanup() {
    local status=$?
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
        # --profile flags on `down` (issue #864): confirmed empirically that
        # a bare `down -v --remove-orphans` with no `--profile` flags leaves
        # `dhcp`/`dhcp-proxy` specifically still running (their fixed
        # container names, `lancache-dhcp`/`lancache-dhcp-proxy`, and their
        # own dedicated dhcp-test-net/dhcp-proxy-test-net networks all
        # survived a bare `down` in a real, reproduced test run), even though
        # every other profile-gated service in the same stack (ssl/logging)
        # was torn down correctly by the same bare `down` call. The exact
        # internal reason wasn't fully isolated (possibly related to
        # dhcp/dhcp-proxy being the only services on custom, non-`default`
        # networks rather than purely a profile-visibility issue), but the
        # fix is directly confirmed: repeating `down` with the SAME
        # `--profile` flags used for `up` reliably removes both containers
        # and both networks, with no leak, across repeated real test runs.
        docker compose --project-directory "$install_dir" \
            -f "$install_dir/docker-compose.yml" \
            -f "$work_dir/logging-test-override.yml" \
            -f "$work_dir/dhcp-test-override.yml" \
            --env-file "$install_dir/.env" \
            --profile ssl --profile logging --profile dhcp-kea --profile dhcp-proxy \
            down -v --remove-orphans >/dev/null 2>&1 || true
        # Defense in depth: force-remove the two fixed container names
        # directly if the profile-aware `down` above somehow still left
        # either running, so a partial/unexpected compose failure can never
        # leak a real container onto a shared self-hosted runner host.
        # Issue #1415: these two names now carry this run's own
        # LANCACHE_CONTAINER_SUFFIX (set near the top of this script, still
        # in scope here since this function is defined and called within
        # the same shell, never a subshell) -- the bare literal would
        # silently no-op against the real (suffixed) container and leave it
        # running, defeating this exact safety net.
        docker rm -f "lancache-dhcp${LANCACHE_CONTAINER_SUFFIX:-}" "lancache-dhcp-proxy${LANCACHE_CONTAINER_SUFFIX:-}" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Phase 1: fresh install via the real setup.sh CLI (expect-driven, mirrors setup-cli-simulation.sh) =="

# SSL mode enabled (need dns-ssl for its own marker below). DHCP mode is left
# "disabled" in the main .env deliberately: dhcp/dhcp-proxy (Triggers 7/8
# below) are started via their own explicit `--profile dhcp-kea --profile
# dhcp-proxy` plus a dedicated override (dhcp-test-override.yml, built below)
# that fully replaces their environment -- the same "wizard has no prompt for
# this, set it directly" approach Phase 2 below still uses as a defense-in-
# depth double-check for the `logging` profile (which the wizard DOES now
# prompt for and default to enabled, see the file header's #1343 update), so
# the main .env's DHCP_MODE is never consulted for these two containers.
# Admin-UI auth disabled (ALLOW_INSECURE_UI=true) so every curl
# call below needs no login flow -- the same simplification the other
# full-setup simulation scripts get for free from their own validation-only
# compose file's insecure defaults.
# "Add now? (ip addr add ...)" is always answered "" (default N): this
# script must never mutate the runner host's real network configuration,
# only ever bind to already-existing loopback addresses.
#
# Issue #1176 (Angle 1): the expect_prompt sequence is generated by
# scripts/lib/setup-wizard-introspect.sh from a real `setup.sh list-prompts`
# run fed this exact reply sequence, instead of being hand-encoded a second
# time here (setup-cli-simulation.sh's own fresh-install phase does the
# same) -- a new prompt on any branch these replies actually walk (SSL on,
# DHCP disabled, Admin-UI unauthenticated) is picked up automatically.
setup_sim_fresh_install_channel="${SETUP_SIM_IMAGE_CHANNEL:-nightly}"
setup_sim_fresh_install_tag="${SETUP_SIM_IMAGE_TAG:-}"
setup_sim_answers_file="$work_dir/fresh-install-answers.txt"
if ! expect_prompt_block="$(
    LANCACHE_IMAGE_CHANNEL="$setup_sim_fresh_install_channel" \
    LANCACHE_IMAGE_TAG="$setup_sim_fresh_install_tag" \
    build_expect_prompt_block "$repo_root/setup.sh" "$setup_sim_answers_file" \
        "$ip_standard" "y" "$ip_ssl" "" "$install_dir" "" "" "" "" "disabled" "" "" "n" "y" "n"
)"; then
    echo "::error::Could not derive the fresh-install expect_prompt sequence from 'setup.sh list-prompts' (issue #1176). See the error above for which prompt/reply count mismatched." >&2
    exit 1
fi

LANCACHE_IMAGE_CHANNEL="$setup_sim_fresh_install_channel" \
LANCACHE_IMAGE_TAG="$setup_sim_fresh_install_tag" \
expect -f - <<EXPECT_SCRIPT
set timeout 60
log_user 1

proc expect_prompt {pattern reply} {
    expect {
        -re \$pattern { send "\$reply\r" }
        timeout { send_error "\n::error::syslog-forwarding-simulation timed out waiting for prompt matching: \$pattern\n"; exit 1 }
        eof { send_error "\n::error::setup.sh exited unexpectedly while waiting for prompt matching: \$pattern\n"; exit 1 }
    }
}

spawn bash setup.sh

$expect_prompt_block

set timeout 10
expect eof
lassign [wait] pid spawnid os_error_flag exit_code
if {\$exit_code != 0} {
    send_error "\n::error::setup.sh exited with code \$exit_code during fresh install\n"
    exit \$exit_code
}
EXPECT_SCRIPT

[[ -f "$install_dir/.env" ]] \
    || { echo "::error::Fresh install did not produce $install_dir/.env." >&2; exit 1; }
[[ -f "$install_dir/docker-compose.yml" ]] \
    || { echo "::error::Fresh install did not copy docker-compose.yml into $install_dir." >&2; exit 1; }

echo "== Phase 2: confirming logging and the static NATS marker identity =="

# The logging profile must be active for the real /logs path. SYSLOG_ENABLED
# separately enables the Admin UI's central-log reader, so assert both rather
# than relying on the setup wizard's current defaults.
if grep -q '^SYSLOG_ENABLED=' "$install_dir/.env"; then
    sed -i 's/^SYSLOG_ENABLED=.*/SYSLOG_ENABLED=true/' "$install_dir/.env"
else
    printf 'SYSLOG_ENABLED=true\n' >> "$install_dir/.env"
fi

# grep finding no COMPOSE_PROFILES= line at all is a legitimate, already-
# handled state -- the case/`:+` logic below treats an empty current_profiles
# the same whether the key was present-but-empty or missing outright. Under
# pipefail, grep's own no-match exit status would otherwise still fail this
# whole pipeline even though `cut` itself succeeds and yields the same empty
# output either way, so the trailing `|| true` neutralizes only that expected
# no-match case instead of turning it into an unrelated fatal error.
# grep runs to completion into a variable first (the `|| true` above still
# covers its own no-match case), then `head -1` reads that captured
# variable via a here-string instead of a live pipe from grep -- a live
# `grep ... | head -1` pipe can SIGPIPE grep if .env ever has more than one
# matching line (issue #1377's repo-wide pipefail/SIGPIPE audit).
compose_profiles_line="$(grep '^COMPOSE_PROFILES=' "$install_dir/.env" || true)"
current_profiles="$(head -1 <<<"$compose_profiles_line" | cut -d= -f2-)"
case ",${current_profiles}," in
    *,logging,*) ;;
    *)
        new_profiles="${current_profiles:+${current_profiles},}logging"
        sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=${new_profiles}/" "$install_dir/.env"
        ;;
esac
grep -qF 'SYSLOG_ENABLED=true' "$install_dir/.env" \
    || { echo "::error::Failed to set SYSLOG_ENABLED=true in .env." >&2; exit 1; }
grep -qF 'logging' "$install_dir/.env" \
    || { echo "::error::Failed to add the logging profile to COMPOSE_PROFILES in .env." >&2; exit 1; }

# Trigger 3 needs a marker produced by nats-server itself. With auth_callout
# enabled, an unknown username is delegated to the Admin UI responder and the
# responder intentionally returns a generic error that does not echo that
# username. Make this run's marker the real static callout-bypass username
# before the stack starts instead. nats-server then recognizes the marker in
# auth_users and keeps a wrong-password attempt on its local static-auth path,
# whose normal error log includes the attempted username.
if grep -q '^NATS_CALLOUT_USER=' "$install_dir/.env"; then
    sed -i "s/^NATS_CALLOUT_USER=.*/NATS_CALLOUT_USER=${marker_nats}/" "$install_dir/.env"
else
    echo "::error::Fresh install did not define NATS_CALLOUT_USER in .env." >&2
    exit 1
fi
grep -qF "NATS_CALLOUT_USER=${marker_nats}" "$install_dir/.env" \
    || { echo "::error::Failed to assign the per-run NATS marker to NATS_CALLOUT_USER." >&2; exit 1; }

# watchdog's CHECK_INTERVAL is a literal `30` in deploy/quickstart/
# docker-compose.yml (not `${CHECK_INTERVAL:-30}`), so it cannot be
# overridden via .env alone -- a compose override file is the correct,
# non-invasive way to change one service's environment for this run only,
# without editing the canonical quickstart compose file. Every other env
# key watchdog's real service block sets is re-declared here verbatim
# (docker-compose.yml:944-1009 as of this writing) purely for clarity/
# self-documentation, not because it is functionally required: CORRECTION
# (issue #864, verified live against this project's actual runners, Compose
# v5.3.0) -- Compose's `environment:` merge across `-f` files is a per-key
# MAP merge (later file's key wins, unmentioned keys from the base survive),
# the same behavior documented for `labels:`, not a full-list replace as
# this comment previously claimed. Confirmed directly: overriding only
# `CHECK_INTERVAL` on a scratch copy of this compose file left every other
# base-declared watchdog environment key intact in `docker compose config`'s
# resolved output. Re-declaring the full list here is therefore redundant
# but harmless as long as every re-declared value keeps matching the base
# file's own -- left as-is rather than removed, since removing it is
# unrelated to #864's actual scope. Issue #1415 found this assumption
# violated for real: CONTAINER_PROXY/CONTAINER_DNS_STANDARD/
# CONTAINER_DNS_SSL below had been hardcoded to their bare, unsuffixed
# literals from before deploy/quickstart/docker-compose.yml's base watchdog
# service gained `${LANCACHE_CONTAINER_SUFFIX:-}` -- this override, applied
# via `-f` AFTER the base file, then WON that per-key merge with the stale
# bare value, silently undoing the base file's suffix and making watchdog
# FATAL in this exact job (confirmed live: `CONTAINER_PROXY=lancache-proxy
# is not supported (expected 'lancache-proxy-syslog-e2e-...')`). Fixed by
# escaping the `${LANCACHE_CONTAINER_SUFFIX:-}` reference (`\$` below) so it
# passes through this heredoc literally, the same way SSL_ENABLED/
# SYSLOG_ENABLED/etc. already do -- resolved by `docker compose` itself at
# parse time, using the SAME shell-exported LANCACHE_CONTAINER_SUFFIX this
# script sets earlier, not by this script's own heredoc expansion.
cat > "$work_dir/logging-test-override.yml" <<EOF
services:
  watchdog:
    environment:
      - DOCKER_PROXY_URL=http://docker-socket-proxy:2375
      - CHECK_INTERVAL=${marker_watchdog}
      - RESTART_AFTER=3
      - DISK_WARN_PCT=85
      - DISK_ALARM_PCT=95
      - CACHE_VALID_DAYS=365
      - CACHE_DIR=/var/cache/lancache
      - CONTAINER_PROXY=lancache-proxy\${LANCACHE_CONTAINER_SUFFIX:-}
      - CONTAINER_DNS_STANDARD=lancache-dns-standard\${LANCACHE_CONTAINER_SUFFIX:-}
      - CONTAINER_DNS_SSL=lancache-dns-ssl\${LANCACHE_CONTAINER_SUFFIX:-}
      - SSL_ENABLED=\${SSL_ENABLED:-0}
      - SYSLOG_ENABLED=\${SYSLOG_ENABLED:-false}
      - SYSLOG_MAX_GB=\${SYSLOG_MAX_GB:-10}
      - SYSLOG_RETENTION_DAYS=\${SYSLOG_RETENTION_DAYS:-30}
EOF

# dhcp/dhcp-proxy (issue #864, Triggers 7/8): moves both off
# `network_mode: host` onto their own dedicated, per-run bridge networks
# (see this script's header comment for why) via Compose's `!reset` merge
# tag, which nulls out the base file's `network_mode: host` so `networks:`
# below can take effect instead -- confirmed live against this project's
# runners (Compose v5.3.0) before writing this override. Both services'
# `environment:` below sets only the keys this test actually needs
# (DHCP_MODE plus the test subnet/pool computed above); Compose merges
# `environment:` across `-f` files per-key (a key present in the base but
# not repeated here keeps the base's own resolved value, confirmed live --
# see the correction on the watchdog override's comment above), so the
# remaining optional variables (DHCP_PROXY_* PXE options, DDNS_TSIG_KEY,
# KEA_CTRL_TOKEN, etc.) fall through to whatever setup.sh's own fresh
# install left them as in $install_dir/.env -- unset/blank for a fresh
# install with DHCP left at its wizard default, which entrypoint.sh already
# handles gracefully (non-fatal warnings, no PXE options rendered), and this
# narrow logging-path proof does not exercise PXE options at all regardless.
# cap_add is re-declared explicitly in both blocks for clarity/
# self-documentation (it matches the base file's own values verbatim, so
# this is not asserted to change anything either way -- not independently
# re-verified here the way the environment merge behavior above was).
# `network_mode`/`networks` are the fields that genuinely need the explicit
# `!reset`/re-declaration treatment in this override, since one is being
# removed and the other is genuinely new for these two services.
cat > "$work_dir/dhcp-test-override.yml" <<EOF
services:
  dhcp:
    network_mode: !reset null
    networks:
      dhcp-test-net: {}
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
    environment:
      - DHCP_DNS_PRIMARY=${dhcp_gateway}
      - DHCP_DNS_SECONDARY=${dhcp_gateway}
      - DHCP_DNS_SERVER_IP=${ip_standard}
      - DHCP_DNS_SERVER_IP_SSL=${ip_ssl}
      - DDNS_TSIG_KEY=
      - KEA_CTRL_TOKEN=
      - DHCP_MODE=kea
      - DHCP_SUBNET=172.29.${octet}.0/25
      - DHCP_GATEWAY=${dhcp_gateway}
      - DHCP_RANGE_START=${dhcp_range_start}
      - DHCP_RANGE_END=${dhcp_range_end}
  dhcp-proxy:
    network_mode: !reset null
    networks:
      dhcp-proxy-test-net: {}
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
    environment:
      - DHCP_MODE=dnsmasq-proxy
      - DHCP_SUBNET_START=${dhcp_proxy_subnet_start}
      - DHCP_DNS_PRIMARY=${dhcp_proxy_gateway}
      - DHCP_DNS_SECONDARY=${dhcp_proxy_gateway}
      - UPSTREAM_DHCP_IP=${dhcp_proxy_gateway}
      - KEEP_KNOWN_GOOD_CONFIGS=3
networks:
  dhcp-test-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.${octet}.0/25
  dhcp-proxy-test-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.${octet}.128/25
EOF

compose=(docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" -f "$work_dir/logging-test-override.yml" -f "$work_dir/dhcp-test-override.yml" --env-file "$install_dir/.env")

echo "== Phase 3: bringing the stack up (ssl + logging + dhcp-kea + dhcp-proxy profiles) =="
"${compose[@]}" pull --quiet proxy dns-standard dns-ssl docker-socket-proxy watchdog nats ui netdata syslog dhcp dhcp-proxy
"${compose[@]}" --profile ssl --profile logging --profile dhcp-kea --profile dhcp-proxy up -d proxy dns-standard dns-ssl docker-socket-proxy watchdog nats ui netdata syslog dhcp dhcp-proxy

# nats and ui are back in this list: deploy/quickstart/docker-compose.yml now
# defines a real Docker HEALTHCHECK for both (nats: http_port 8222 + a wget
# probe against /healthz; ui: curl against services/ui/src/main.rs's /health
# route). Previously neither had one, so `docker inspect --format
# '{{.State.Health.Status}}'` always fell through to "unknown" and this wait
# loop could NEVER succeed for them, 100% deterministically, regardless of
# any real timing -- that was the actual cause of this job's own `nats`/`ui
# did not become healthy` failures, unrelated to the `ui`-triggered nats
# restart (see reload_nats_conf()/restart_service() in services/ui) that
# coincidentally also showed up in the same run's logs. Removing them from
# this list was only ever the correct fix for the no-healthcheck state, not
# a permanent exclusion -- see setup-cli-simulation.sh's matching list, which
# needed the same update once its own compose target (quickstart) gained
# real healthchecks.
# watchdog joins this list too (issue #822 pattern audit, 2026-07-17):
# deploy/quickstart/docker-compose.yml's watchdog service has always defined
# a real, freshness-based (mtime, not just existence) Docker HEALTHCHECK --
# unlike docker-socket-proxy/syslog/syslog-ng below, which genuinely have
# none. Leaving watchdog out of services_with_healthcheck silently
# downgraded it to the weaker "running + restart-count ceiling" check this
# script uses for services with no healthcheck at all, meaning a watchdog
# that never reaches "healthy" (e.g. main loop stalled, status.json stale)
# would never fail this job. Matches build-push.yml/full-setup-validate.yml/
# full-setup-deep-validate.yml's canonical list, which already included it.
# dhcp joins this list too (issue #864): deploy/quickstart/docker-compose.yml's
# dhcp (Kea) service has a real Docker HEALTHCHECK (Control Agent config-get
# probe, self-healing against the shared-secret KEA_CTRL_TOKEN per #858 --
# see docs/architecture-ng.md's logging matrix / that healthcheck block's own
# comment).
# docker-socket-proxy and dhcp-proxy join this list under #1169, which added
# real Docker HEALTHCHECKs for both (an HTTP probe against the Docker API's
# own /_ping for docker-socket-proxy; a PID-1-is-dnsmasq + `dnsmasq --test`
# liveness/config-integrity check for dhcp-proxy, since dnsmasq has no
# HTTP/control-socket API and this config disables DNS entirely). Neither had
# any Docker healthcheck before #1169.
# syslog joined this list under #1169 -- correcting a pre-existing,
# unrelated inaccuracy in this file rather than something #1169 itself
# introduced: it has had a real healthcheck since issue #633, well before
# #1169 existed. This script's own comment previously (incorrectly) grouped
# it with docker-socket-proxy as a service that "genuinely has none" --
# #1169's ground-truth compose-file audit caught the same stale claim.
#
# UPDATED (syslog+fluent-bit consolidation PR, 2026-08): `syslog` and
# `syslog-ng` used to be two separate Compose services, each with its own
# healthcheck (`fluent-bit -V` / `syslog-ng-ctl healthcheck` respectively,
# both entries in this list). They are now ONE combined container
# (`services/syslog/`) with ONE Compose service name (`syslog`) and ONE
# Docker HEALTHCHECK slot -- but that single check
# (`services/syslog/healthcheck.sh`) verifies both underlying processes
# independently and only reports healthy when both are, so this script's
# per-service health-wait loop still gets the same real, non-degraded
# coverage it always did, just through one list entry instead of two.
services_with_healthcheck="proxy dns-standard dns-ssl watchdog nats ui netdata dhcp docker-socket-proxy dhcp-proxy syslog"
all_services="$services_with_healthcheck"

deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in $services_with_healthcheck; do
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service' during health wait." >&2
            exit 1
        fi
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done

echo "::group::Final container status"
"${compose[@]}" ps
echo "::endgroup::"

failed=0
for service in $all_services; do
    if ! cid="$("${compose[@]}" ps -q "$service")"; then
        echo "::error::Could not query the compose container id for service '$service'." >&2
        exit 1
    fi
    if [[ -z "$cid" ]]; then
        echo "::error::$service has no running container" >&2
        failed=1
        continue
    fi
    if ! restart_count="$(docker inspect --format '{{.RestartCount}}' "$cid")"; then
        echo "::error::Failed to read RestartCount for $service (container $cid) via docker inspect." >&2
        exit 1
    fi
    if ! container_status="$(docker inspect --format '{{.State.Status}}' "$cid")"; then
        echo "::error::Failed to read container state for $service (container $cid) via docker inspect." >&2
        exit 1
    fi
    if [[ "$container_status" != "running" ]]; then
        echo "::error::$service is not running (state: $container_status)" >&2
        failed=1
    elif (( restart_count > 1 )); then
        echo "::error::$service has restarted $restart_count times (crash-loop suspected)" >&2
        failed=1
    fi
    if [[ " $services_with_healthcheck " == *" $service "* ]]; then
        # Loop 1 above and this per-service check are NOT one atomic
        # operation: it breaks the instant it observes every tracked
        # service healthy in a single pass, then this loop re-reads each
        # service's status again, moments later, one at a time. Any real
        # event that flips a service's health back to "starting" (Docker
        # only ever does this on an actual container restart) in that gap
        # would otherwise be reported as a fresh, unexplained failure here
        # instead of what it actually is: a health check that already
        # passed once, then got knocked over again by something between the
        # two loops. This short re-poll closes that gap without weakening
        # the check itself -- a service that is genuinely still unhealthy
        # after this additional wait still fails loudly below, exactly as
        # before.
        health_deadline=$((SECONDS + 15))
        health="unknown"
        while (( SECONDS < health_deadline )); do
            health="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
            [[ "$health" = "healthy" ]] && break
            sleep 2
        done
        [[ "$health" = "healthy" ]] \
            || { echo "::error::$service did not become healthy (status: $health, restarts: $restart_count)" >&2; failed=1; }
    fi
done

if [[ "$failed" -eq 1 ]]; then
    echo "::group::Failure diagnostics: per-service restart counts"
    # RestartCount alone can't distinguish "restarted once, by the known
    # ui-triggered reload_nats_conf() at boot" from "restarted again for an
    # unrelated, unexplained reason" -- but printing it for every service
    # here means a future occurrence of this failure has that number
    # attached, instead of needing to be reconstructed after the fact from
    # a job whose containers are long gone by the time anyone looks.
    for service in $all_services; do
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service' while collecting failure diagnostics." >&2
            exit 1
        fi
        [[ -n "$cid" ]] || continue
        echo "$service: RestartCount=$(docker inspect --format '{{.RestartCount}}' "$cid" 2>/dev/null || echo '?')"
    done
    echo "::endgroup::"

    echo "::group::Failure diagnostics: nats-server's own log"
    # nats-server's log_file directive (services/nats entrypoint in
    # deploy/quickstart/docker-compose.yml) sends its ENTIRE log to
    # /var/log/lancache-nats/nats.log, not stdout -- "compose logs" below
    # captures stdout/stderr only, so a nats-specific crash or an
    # unexpected second restart would otherwise be completely invisible in
    # this diagnostics dump.
    "${compose[@]}" exec -T nats sh -c 'cat /var/log/lancache-nats/nats.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's own Kea log"
    # What: dhcp emitted nothing at all in a real failing run.
    # Why: reads Kea's own log in case stdout stays empty.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c 'cat /var/log/kea/kea-dhcp4.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's own Kea Control Agent log"
    # What: healthcheck hits port 8000, a separate Kea process.
    # Why: kea-ctrl-agent logs to its own file, not kea-dhcp4.log.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c 'cat /var/log/kea/kea-ctrl-agent.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's Docker healthcheck output"
    # What: neither Kea log shows the healthcheck's own result.
    # Why: Docker keeps the real stdout/stderr of recent attempts.
    # From: PR #1775
    if dhcp_cid="$("${compose[@]}" ps -q dhcp)" && [[ -n "$dhcp_cid" ]]; then
        docker inspect --format '{{json .State.Health}}' "$dhcp_cid" | jq . || true
    fi
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp healthcheck request re-run verbose"
    # What: -sf swallows the real HTTP status/body on failure.
    # Why: same request, but without hiding the real HTTP error.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c '
        host="${KEA_CTRL_HOST:-127.0.0.1}"
        [ "$host" = "0.0.0.0" ] && host=127.0.0.1
        token="${KEA_CTRL_TOKEN:-}"
        norm="$(printf "%s" "$token" | tr "[:upper:]" "[:lower:]" | tr "-" "_")"
        case "$norm" in ""|change_me*|changeme*|your_*|*_here) token="" ;; esac
        [ -n "$token" ] || token="$(cat /var/lib/lancache-secrets/kea-ctrl-token 2>/dev/null)"
        echo "token source: $([ -n "${KEA_CTRL_TOKEN:-}" ] && echo env || echo file), length=${#token}"
        esc_token="$(printf "%s" "$token" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g")"
        printf "user = \"admin:%s\"\n" "$esc_token" | curl -sS -o /tmp/hc-body.$$ -w "HTTP status: %{http_code}\n" -K - \
            -H "Content-Type: application/json" \
            -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
            "http://$host:8000/"
        echo "response body:"
        cat /tmp/hc-body.$$ 2>/dev/null
        rm -f /tmp/hc-body.$$
    ' || true
    echo "::endgroup::"

    echo "::group::Logs from all services (failure diagnostics)"
    "${compose[@]}" logs --no-color
    echo "::endgroup::"
    exit 1
fi
echo "All 8 stack services (7 wired + docker-socket-proxy) are running and healthy."

# --network host (same reasoning as full-setup-validate.yml's identical
# fix for setup-cli-simulation.sh, issue #819): every call site below
# targets $ip_standard/$ip_ssl, the SAME loopback-published addresses
# (127.0.<octet>.2/3) a real operator's browser would use, deliberately --
# proving that exact address is reachable is the point (this script's own
# header: "the exact HTTP surface an operator uses"), not just that the
# service is reachable somehow. Loopback addresses are per-network-
# namespace: without --network host, this container gets its OWN isolated
# 127.0.0.0/8, completely separate from the runner host's, where the
# sibling `ui`/`proxy` containers actually publish their ports. Confirmed
# directly on a runner: the identical curl from a sibling container without
# --network host gets connection-refused (000) after 0ms, permanently,
# regardless of how long a caller waits, while the exact same curl WITH
# --network host succeeds immediately. Resolving by container/service name
# instead (e.g. http://ui:8080) would also be network-reachable, but would
# silently stop proving the loopback-published address itself works --
# exactly the address a real operator's LAN client depends on.
run_client() {
    docker run --rm --network host \
        -v "$work_dir/shared:/shared" \
        "$BUILD_TOOLS_IMAGE" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ip_standard:8080/domains'"
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Failed to read the session cookiejar at $work_dir/shared/cookiejar via awk." >&2
    exit 1
fi
[[ -n "$cookie_value" ]] || { echo "::error::No lancache_ui_session cookie was set by GET /domains." >&2; exit 1; }
if ! csrf_token="$(cut -d. -f3 <<<"$cookie_value")"; then
    echo "::error::Failed to extract the CSRF token field from the session cookie via cut." >&2
    exit 1
fi
[[ -n "$csrf_token" ]] || { echo "::error::Could not extract a CSRF token from the session cookie." >&2; exit 1; }
echo "Session established, CSRF token extracted."

# The single, authoritative proof point for every service below: the exact
# HTTP route (GET /logs) an operator actually uses, not a second direct
# read of /var/log/lancache-syslog-ng. Polls (rather than sleeping once)
# because there is no fixed delay between a real event and fluent-bit
# tailing + forwarding + syslog-ng writing it -- same reasoning as
# dns-zone-rollback-simulation.sh's verify_record_resolves. On timeout,
# dumps BOTH the raw HTML (to see exactly what the UI returned) and every
# forwarded per-host log file's tail (to tell "never reached syslog-ng at
# all" apart from "reached syslog-ng but the UI didn't show it" -- the
# precise distinction #453's last comment asked this test to make).
assert_marker_reaches_ui() {
    local marker="$1" description="$2" timeout="${3:-90}"
    local deadline=$((SECONDS + timeout)) body=""
    while (( SECONDS < deadline )); do
        if ! body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"; then
            echo "::error::Failed to fetch the Admin UI /logs route from $ip_standard while polling for the $description marker (run_client/docker invocation failed)." >&2
            exit 1
        fi
        if grep -qF "$marker" <<<"$body"; then
            echo "OK: $description marker ($marker) is visible via the real Admin UI /logs route."
            return 0
        fi
        sleep 3
    done
    echo "::error::$description marker ($marker) never appeared via the Admin UI /logs route within ${timeout}s." >&2
    echo "::group::Raw /logs HTML response (last poll)"
    printf '%s\n' "$body"
    echo "::endgroup::"
    echo "::group::Forwarded syslog-ng files (diagnosing UI-visibility vs. forwarding-pipeline failure)"
    "${compose[@]}" exec -T ui sh -c 'grep -r "" /var/log/lancache-syslog-ng/ 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"
    return 1
}

echo "== Trigger 1/8: proxy -- real HTTP GET with a unique request path =="
run_client "curl -sS -o /dev/null 'http://$ip_standard/e2e-marker-$marker_proxy'" || true
assert_marker_reaches_ui "$marker_proxy" "proxy (nginx access log)"

echo "== Trigger 2/8: ui -- real POST /domains/dns/add with an intentionally-invalid, marker-bearing domain =="
# parse_domain_entry (services/ui/src/routes/domains.rs) rejects any value
# with fewer than 2 dot-separated labels, logging the RAW submitted value
# via tracing::warn!(domain = %form.domain, "Rejected invalid dns domain")
# before returning 400 -- confirmed by reading that function. A marker with
# no '.' at all is guaranteed to hit this rejection path without ever
# writing to the real cdn-domains file.
run_client "curl -sS -o /dev/null -b /shared/cookiejar \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'domain=$marker_ui' \
    'http://$ip_standard:8080/domains/dns/add'" || true
assert_marker_reaches_ui "$marker_ui" "ui (Rejected invalid dns domain warning)"

echo "== Trigger 3/8: nats -- real static-user authentication failure carrying the per-run username =="
# The marker is the stack's real NATS_CALLOUT_USER for this test run. That
# identity is both a static user and an auth_users bypass identity, so a wrong
# password is rejected by nats-server's local static-auth path instead of being
# delegated to the Admin UI auth-callout responder. The resulting normal [ERR]
# authentication log contains the attempted username and therefore gives NATS
# its own unique marker without enabling protocol trace or fabricating a line.
#
# First prove the generated runtime config retained that contract. Also prove
# the marker is not already visible through /logs before the deliberate bad
# CONNECT, otherwise the post-trigger assertion could pass on unrelated output.
if ! "${compose[@]}" exec -T nats grep -Fq "user: \"$marker_nats\"" /etc/nats/nats.conf; then
    echo "::error::NATS runtime config does not contain the per-run static callout-bypass username ($marker_nats)." >&2
    exit 1
fi
if ! "${compose[@]}" exec -T nats grep -Fq "\"$marker_nats\"" /etc/nats/auth_callout.conf; then
    echo "::error::NATS auth_callout.conf does not list the per-run static username in auth_users ($marker_nats)." >&2
    exit 1
fi
if ! body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"; then
    echo "::error::Failed to fetch the Admin UI /logs route before triggering the NATS authentication marker." >&2
    exit 1
fi
if grep -qF "$marker_nats" <<<"$body"; then
    echo "::error::NATS marker ($marker_nats) was already visible via /logs before the deliberate authentication failure, so it would not prove the NATS trigger." >&2
    exit 1
fi

docker run --rm --network "$network_name" \
    -e "NATS_AUTH_MARKER=$marker_nats" \
    "$BUILD_TOOLS_IMAGE" bash -c '
        set +e
        exec 3<>/dev/tcp/nats/4222
        read -r -t 5 _ <&3
        printf "CONNECT {\"user\":\"%s\",\"pass\":\"wrong\",\"verbose\":false,\"pedantic\":false}\r\n" "$NATS_AUTH_MARKER" >&3
        read -r -t 3 _ <&3
        sleep 1
    ' >/dev/null 2>&1 || true
assert_marker_reaches_ui "$marker_nats" "nats (static-user authentication-error log line carrying the attempted username)"

echo "== Trigger 4/8 and 5/8: dns-standard + dns-ssl -- one real DNS record add via the Admin UI =="
# Both dns-standard's and dns-ssl's own nats-subscriber processes durably
# consume the same "lancache.dns.record" NATS subject (confirmed by reading
# services/dns/nats-subscriber/src/main.rs), so this single real write
# triggers BOTH services' own handle_dns_record -> println!("Updated DNS
# record: zone={} name={} type={} action={}", ...) -- one real UI action,
# independently proving both wired services' own logging paths.
run_client "curl -sS -o /dev/null -b /shared/cookiejar \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'name=$marker_dns' \
    --data-urlencode 'record_type=A' \
    --data-urlencode 'content=203.0.113.99' \
    --data-urlencode 'ttl=60' \
    'http://$ip_standard:8080/domains/lan/add'" || true
assert_marker_reaches_ui "$marker_dns" "dns-standard AND dns-ssl (nats-subscriber's own record-applied log line)"

echo "== Trigger 6/8: watchdog -- real startup banner carrying this run's overridden CHECK_INTERVAL =="
# No separate action needed: watchdog.sh unconditionally logs
# "Interval: ${CHECK_INTERVAL}s | ..." once, immediately at container start
# (watchdog.sh, just before its `while true` loop) -- already triggered by
# Phase 3 bringing the container up with the override file's marker value.
assert_marker_reaches_ui "$marker_watchdog" "watchdog (startup banner's CHECK_INTERVAL value)"

echo "== Trigger 7/8: dhcp (Kea) -- a real DHCPDISCOVER/OFFER/REQUEST/ACK lease over the isolated dhcp-test-net =="
# A real dhclient, on the dedicated dhcp-test-net bridge network (see the
# override built in Phase 2/3 above), negotiates a genuine lease against
# this run's own Kea container -- the identical Discover/Offer/Request/Ack
# exchange dhcp-kea-lease-flow-simulation.sh already proves in depth, driven
# here only far enough to produce a real, per-run-unique log line (the
# offered address, drawn from this run's own $dhcp_range_start-
# $dhcp_range_end pool) in kea-dhcp4.log -- confirmed live before writing
# this trigger that Kea's own DHCP4_LEASE_ALLOC log line names the leased
# address verbatim. `-sf /bin/true` (a no-op lease-apply script) means the
# lease is negotiated over the wire but never actually applied to this
# throwaway client container's own interface, the same safety technique
# dhcp-kea-lease-flow-simulation.sh's own real-dhclient test uses -- both
# scripts deliberately still use real `dhclient` for THIS isolated-network
# CI purpose (testing Kea's own server behavior), distinct from the Admin
# UI's own dhcp-probe container, which issue #1288 rewrote to a native
# Rust DHCP client with no dhclient dependency at all.
dhcp_client_container="lancachee2e-dhcp-client-$$"
docker run -d --name "$dhcp_client_container" \
    --network "${compose_project}_dhcp-test-net" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$work_dir/shared:/shared" \
    "$BUILD_TOOLS_IMAGE" \
    bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /shared/dhcp-client.pid -lf /shared/dhcp-client.leases eth0 >/shared/dhcp-client.out 2>&1; echo DONE >> /shared/dhcp-client.out' \
    >/dev/null

dhcp_lease_deadline=$((SECONDS + 30))
dhcp_lease_obtained=0
while (( SECONDS < dhcp_lease_deadline )); do
    # Same "wait for the closing brace, not just file existence" reasoning
    # as dhcp-kea-lease-flow-simulation.sh's own identical wait loop: the
    # lease file appears the moment dhclient starts writing it, well before
    # the record is complete.
    if [[ -s "$work_dir/shared/dhcp-client.leases" ]] && grep -q '^}' "$work_dir/shared/dhcp-client.leases" 2>/dev/null; then
        dhcp_lease_obtained=1
        break
    fi
    sleep 1
done
docker rm -f "$dhcp_client_container" >/dev/null 2>&1 || true

echo "::group::Trigger 7/8: raw dhclient output"
cat "$work_dir/shared/dhcp-client.out" 2>/dev/null || echo "(no client output captured)"
echo "::endgroup::"

if [[ "$dhcp_lease_obtained" -ne 1 ]]; then
    echo "::error::dhclient never obtained a real lease from this run's dhcp (Kea) container within 30s over dhcp-test-net." >&2
    "${compose[@]}" logs --no-color dhcp || true
    exit 1
fi

# A dhclient lease file can accumulate more than one "lease {...}" block
# across renewals, so grep runs to completion into a variable first, and
# `head -1` reads it via a here-string -- a live `grep | head -1` pipe
# could SIGPIPE grep once there is more than one fixed-address line (issue
# #1377's repo-wide pipefail/SIGPIPE audit).
if ! fixed_address_lines="$(grep -oE 'fixed-address [0-9.]+' "$work_dir/shared/dhcp-client.leases")"; then
    echo "::error::Could not parse the offered address out of the real dhclient lease file." >&2
    exit 1
fi
dhcp_offered_address="$(head -1 <<<"$fixed_address_lines" | cut -d' ' -f2)"
[[ -n "$dhcp_offered_address" ]] || { echo "::error::dhclient's lease file had no fixed-address field." >&2; exit 1; }
echo "Real lease obtained: $dhcp_offered_address (Kea's own DHCP4_LEASE_ALLOC log line names this address verbatim)."
# Marker is "lease <address> has been allocated" (Kea's own DHCP4_LEASE_ALLOC
# wording, confirmed live), not the bare address alone: a bare IPv4 address
# substring-matches other real lines in the same log (e.g. the pool's own
# end address ".100", or an unrelated subnet-declaration line) that would
# make this assertion pass even if the real lease-allocation line itself
# never arrived. Matching the surrounding wording proves the specific event
# this trigger claims to prove, not merely that this address appears
# somewhere in the log.
dhcp_lease_marker="lease ${dhcp_offered_address} has been allocated"
assert_marker_reaches_ui "$dhcp_lease_marker" "dhcp/Kea (DHCP4_LEASE_ALLOC log line naming the real leased address)"

echo "== Trigger 8/8: dhcp-proxy (dnsmasq) -- real DHCPDISCOVER over the isolated dhcp-proxy-test-net; per-run-unique proxy-subnet startup marker =="
# dnsmasq-proxy mode (RFC 4388 ProxyDHCP) only ever supplements PXE options
# alongside an existing, separate primary DHCP server -- it never completes
# a lease on its own, so there is no offered-address marker to parse the way
# Trigger 7 above has. Confirmed live before writing this trigger: without a
# paired primary DHCP server (out of scope to stand up here -- a separate,
# heavier scenario dhcp-proxy-pxe-simulation.sh is better positioned to
# cover if ever needed), a real DHCPDISCOVER received here only produces
# dnsmasq's own "no address range available for DHCP request via eth0" line,
# which carries no per-run marker. Instead, this trigger's marker is the
# real, operator-configured DHCP_SUBNET_START value this run's override set
# ($dhcp_proxy_subnet_start, see Phase 2/3 above) -- dnsmasq logs it
# verbatim in its own startup banner ("DHCP, proxy on subnet <value>",
# confirmed live), the same technique already established for the watchdog
# trigger's CHECK_INTERVAL above. The real DHCPDISCOVER below additionally
# proves the isolated network path itself is live end-to-end (a genuine
# client packet actually reaches dnsmasq), even though its own reply carries
# no marker.
dhcp_proxy_client_container="lancachee2e-dhcp-proxy-client-$$"
docker run -d --name "$dhcp_proxy_client_container" \
    --network "${compose_project}_dhcp-proxy-test-net" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    "$BUILD_TOOLS_IMAGE" \
    bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /tmp/dhcp-proxy-client.pid -lf /tmp/dhcp-proxy-client.leases eth0 >/tmp/dhcp-proxy-client.out 2>&1 || true; sleep 3' \
    >/dev/null
sleep 5
docker rm -f "$dhcp_proxy_client_container" >/dev/null 2>&1 || true
assert_marker_reaches_ui "$dhcp_proxy_subnet_start" "dhcp-proxy/dnsmasq (startup banner's DHCP_SUBNET_START value)"

echo "== netdata: non-blocking check (no operator-triggerable marker mechanism found) =="
# What: polls for netdata log line, never fails the run.
# Why: no operator-triggerable marker exists for netdata.
# From: Issue #1095
netdata_deadline=$((SECONDS + 90))
netdata_seen=0
while (( SECONDS < netdata_deadline )); do
    if ! body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"; then
        echo "::error::Failed to fetch the Admin UI /logs route from $ip_standard while polling for netdata's forwarded log line (run_client/docker invocation failed)." >&2
        exit 1
    fi
    if grep -qP '<td[^>]*>\s*netdata\s*</td>' <<<"$body"; then
        netdata_seen=1
        break
    fi
    sleep 3
done
if [[ "$netdata_seen" -ne 1 ]]; then
    echo "::warning::No line attributed to host 'netdata' appeared via the Admin UI /logs route within 90s -- non-blocking, see comment above." >&2
else
    echo "OK: netdata's forwarded logging path is visible via the real Admin UI /logs route (no per-event marker; see comment above for why)."
fi

echo "== fluent-bit self-log (issue #864): documented weaker check, same class as netdata above =="
# fluent-bit's own internal log has no operator-triggerable marker mechanism
# either -- there is no route or config surface that lets this script inject
# a distinguishing string into fluent-bit's own startup/error output, the
# same structural gap netdata's check above documents. What IS verified: the
# self-log tail input (tag=fluent-bit.selflog, see deploy/quickstart/
# docker-compose.yml's `-l /data/fluent-bit.log` flag) reliably produces at
# least fluent-bit's own real startup banner line within the wait below,
# proving the self-log path is wired end-to-end -- confirmed live before
# writing this check that a real run produces this line within seconds of
# container start, well inside this timeout.
selflog_deadline=$((SECONDS + 60))
selflog_seen=0
while (( SECONDS < selflog_deadline )); do
    if ! body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"; then
        echo "::error::Failed to fetch the Admin UI /logs route from $ip_standard while polling for fluent-bit's own forwarded self-log line (run_client/docker invocation failed)." >&2
        exit 1
    fi
    if grep -qP '<td[^>]*>\s*fluent-bit\s*</td>' <<<"$body"; then
        selflog_seen=1
        break
    fi
    sleep 3
done
if [[ "$selflog_seen" -ne 1 ]]; then
    echo "::error::No line attributed to ident 'fluent-bit' ever appeared via the Admin UI /logs route within 60s." >&2
    exit 1
fi
echo "OK: fluent-bit's own self-log is visible via the real Admin UI /logs route (no per-event marker; see comment above for why)."

echo "syslog-forwarding-simulation passed: proxy, ui, nats, dns-standard, dns-ssl, watchdog, dhcp (Kea), and dhcp-proxy (dnsmasq) were each proven end-to-end with a unique or real-event marker (real trigger -> syslog-ng file -> real Admin UI /logs response); fluent-bit's own self-log was proven present via a documented weaker check; netdata's forwarded log line was checked but is non-blocking (see comment above)."
