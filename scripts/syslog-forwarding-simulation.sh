#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end proof for issue #453's last two comments: it is not enough
# to show a log line reaches syslog-ng on disk -- the maintainer's own
# clarification (and #822 Pattern G: "a check that never really looked")
# requires proving the operator can actually SEE that line through the real
# Admin UI read path (routes/logs.rs -> syslog_client::parse_syslog_tail),
# not a second direct read of the log file. Every earlier check in this
# project's CI (scripts/check-logging-matrix.sh, `docker compose config`)
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
# SCOPE (increment 1 of 2, tracked on #453): the 7 services below. `dhcp`
# and `dhcp-proxy` are deliberately NOT covered here -- both run with
# `network_mode: host` in deploy/quickstart/docker-compose.yml (confirmed by
# reading the compose file), so bringing both up simultaneously in a shared
# CI runner risks a real DHCP/host-network port conflict, and running even
# one of them this way is untested territory for this project's CI (the
# existing scripts/dhcp-kea-lease-flow-simulation.sh and
# scripts/dhcp-proxy-pxe-simulation.sh deliberately avoid quickstart's
# host-network services entirely, using their own isolated bridge-network
# containers instead). Covering dhcp/dhcp-proxy here needs its own careful,
# sequential (never simultaneous) design and live CI confirmation of the
# exact log-visibility mechanism -- tracked as explicit follow-up work on
# #453, not silently dropped from the "all 9 services" requirement.
#
# COMPOSE BASE: deploy/quickstart/docker-compose.yml, not deploy/full-setup
# (which every earlier `scripts/*-simulation.sh` uses). full-setup has
# neither the `logging` profile (syslog-ng/fluent-bit) nor dhcp/dhcp-proxy
# defined at all -- extending it would mean testing an unguarded copy of the
# logging wiring instead of the real thing scripts/check-logging-matrix.sh
# actually guards (dev/prod/quickstart). quickstart already has every
# service and the full logging profile, and is the same compose file
# scripts/setup-cli-simulation.sh already drives concurrently in CI via a
# unique COMPOSE_PROJECT_NAME + loopback IP + retry-on-collision -- reused
# here directly rather than inventing a second isolation mechanism.
#
# Getting a correct, fully-populated .env (~50 required values: NATS
# credentials, PDNS_API_KEY, DDNS_TSIG_KEY, etc.) is done by driving the
# REAL setup.sh CLI through `expect`, exactly like setup-cli-simulation.sh's
# own Phase 1 -- hand-crafting that many secrets/values here would risk
# silently drifting from what setup.sh actually generates. `Start now? [Y/n]`
# is answered "n": this script brings the stack up itself afterward with the
# additional `logging` profile and SYSLOG_ENABLED=true, which setup.sh's own
# wizard has no prompt for at all (logging is a manual opt-in per
# docs/architecture-ng.md, not part of the guided install flow).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

: "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# Same reason as setup-cli-simulation.sh: this script runs inside the
# build-tools container against a bind-mounted checkout owned by the host
# runner's UID, which git otherwise refuses as "dubious ownership".
git config --global --add safe.directory "$repo_root"

work_dir="$repo_root/.syslog-forwarding-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"
install_dir="$(mktemp -d "$work_dir/install.XXXXXX")"

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
compose_project="$(sim_compose_project_name "$install_dir")"
export COMPOSE_PROJECT_NAME="$compose_project"
network_name="${compose_project}_default"

# Unique per-run marker prefix. Deliberately alphanumeric-only (no special
# characters): it flows through a domain-name validator (routes/domains.rs
# rejects anything with '.'-less-than-2-labels, which is exactly the
# property this script relies on for the ui trigger below -- see that
# section), a DNS record name, and raw HTML text inside Tera-rendered
# `<td>` cells, so it must be safe absolutely everywhere it lands with no
# escaping surprises. date +%s%N (nanosecond epoch) + PID is unique enough
# for one CI run without needing a UUID generator that might not be
# installed in every build-tools image variant.
marker_base="lancachee2e$(date +%s%N)pid$$"
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
marker_watchdog="$(date +%s%N | tail -c 9)"

cleanup() {
    local status=$?
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
        docker compose --project-directory "$install_dir" \
            -f "$install_dir/docker-compose.yml" \
            -f "$work_dir/logging-test-override.yml" \
            --env-file "$install_dir/.env" \
            down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Phase 1: fresh install via the real setup.sh CLI (expect-driven, mirrors setup-cli-simulation.sh) =="

# SSL mode enabled (need dns-ssl for its own marker below), DHCP disabled
# (out of scope this increment, see header comment), Admin-UI auth disabled
# (ALLOW_INSECURE_UI=true) so every curl call below needs no login flow --
# the same simplification the other full-setup simulation scripts get for
# free from their own validation-only compose file's insecure defaults.
# "Add now? (ip addr add ...)" is always answered "" (default N): this
# script must never mutate the runner host's real network configuration,
# only ever bind to already-existing loopback addresses.
LANCACHE_IMAGE_CHANNEL="${SETUP_SIM_IMAGE_CHANNEL:-edge}" \
LANCACHE_IMAGE_TAG="${SETUP_SIM_IMAGE_TAG:-}" \
SETUP_SIM_INSTALL_DIR="$install_dir" \
expect -f - <<EXPECT_SCRIPT
set timeout 60
log_user 1
set install_dir "$install_dir"
set ip_standard "$ip_standard"
set ip_ssl "$ip_ssl"

proc expect_prompt {pattern reply} {
    expect {
        -re \$pattern { send "\$reply\r" }
        timeout { send_error "\n::error::syslog-forwarding-simulation timed out waiting for prompt matching: \$pattern\n"; exit 1 }
        eof { send_error "\n::error::setup.sh exited unexpectedly while waiting for prompt matching: \$pattern\n"; exit 1 }
    }
}

spawn bash setup.sh

expect_prompt {Server IP \(Standard mode\)} \$ip_standard
expect_prompt {Enable SSL mode\? \[y/N\]} "y"
expect_prompt {SSL mode IP} \$ip_ssl
expect_prompt {Add now\?[^\n]*ip addr add} ""
expect_prompt {Directory[^\n]*\[} \$install_dir
expect_prompt {Cache directory \(absolute path\)} ""
expect_prompt {Cache size in GiB} ""
expect_prompt {Cache RAM buffer in MB} ""
expect_prompt {Enable scheduled automatic updates\?} ""
expect_prompt {DHCP mode \(disabled, kea, dnsmasq-proxy\)} "disabled"
expect_prompt {Protect Admin-UI with password\? \[Y/n\]} "n"
expect_prompt {Allow Admin-UI without authentication\? \[y/N\]} "y"
expect_prompt {Start now\? \[Y/n\]} "n"

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

echo "== Phase 2: enabling the logging profile (SYSLOG_ENABLED, COMPOSE_PROFILES+=logging) =="

# setup.sh's own wizard has no prompt for this (logging is a manual,
# documented opt-in per docs/architecture-ng.md, not part of the guided
# install flow) -- these two keys are appended/updated directly, exactly
# the same direct-.env-mutation technique setup-cli-simulation.sh's own
# Phase 2/3 already use for scenarios setup.sh's wizard doesn't cover.
if grep -q '^SYSLOG_ENABLED=' "$install_dir/.env"; then
    sed -i 's/^SYSLOG_ENABLED=.*/SYSLOG_ENABLED=true/' "$install_dir/.env"
else
    printf 'SYSLOG_ENABLED=true\n' >> "$install_dir/.env"
fi

current_profiles="$(grep '^COMPOSE_PROFILES=' "$install_dir/.env" | head -1 | cut -d= -f2-)"
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

# watchdog's CHECK_INTERVAL is a literal `30` in deploy/quickstart/
# docker-compose.yml (not `${CHECK_INTERVAL:-30}`), so it cannot be
# overridden via .env alone -- a compose override file is the correct,
# non-invasive way to change one service's environment for this run only,
# without editing the canonical quickstart compose file. Every other env
# key watchdog's real service block sets is re-declared here verbatim
# (docker-compose.yml:944-1009 as of this writing) because Compose's list-
# form `environment:` merge fully replaces the base file's list for a
# service, it does not merge per-key -- omitting any of these would silently
# strip a real, required watchdog setting for this run.
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
      - CONTAINER_PROXY=lancache-proxy
      - CONTAINER_DNS_STANDARD=lancache-dns-standard
      - CONTAINER_DNS_SSL=lancache-dns-ssl
      - SSL_ENABLED=\${SSL_ENABLED:-0}
      - SYSLOG_ENABLED=\${SYSLOG_ENABLED:-false}
      - SYSLOG_MAX_GB=\${SYSLOG_MAX_GB:-10}
      - SYSLOG_RETENTION_DAYS=\${SYSLOG_RETENTION_DAYS:-30}
EOF

compose=(docker compose --project-directory "$install_dir" -f "$install_dir/docker-compose.yml" -f "$work_dir/logging-test-override.yml" --env-file "$install_dir/.env")

echo "== Phase 3: bringing the stack up (ssl + logging profiles; dhcp disabled this increment) =="
"${compose[@]}" pull --quiet proxy dns-standard dns-ssl docker-socket-proxy watchdog nats ui netdata syslog syslog-ng
"${compose[@]}" --profile ssl --profile logging up -d proxy dns-standard dns-ssl docker-socket-proxy watchdog nats ui netdata syslog syslog-ng

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
services_with_healthcheck="proxy dns-standard dns-ssl watchdog nats ui netdata"
all_services="docker-socket-proxy syslog syslog-ng $services_with_healthcheck"

deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in $services_with_healthcheck; do
        cid="$("${compose[@]}" ps -q "$service")"
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
    cid="$("${compose[@]}" ps -q "$service")"
    if [[ -z "$cid" ]]; then
        echo "::error::$service has no running container" >&2
        failed=1
        continue
    fi
    restart_count="$(docker inspect --format '{{.RestartCount}}' "$cid")"
    container_status="$(docker inspect --format '{{.State.Status}}' "$cid")"
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
        cid="$("${compose[@]}" ps -q "$service")"
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
cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"
[[ -n "$cookie_value" ]] || { echo "::error::No lancache_ui_session cookie was set by GET /domains." >&2; exit 1; }
csrf_token="$(cut -d. -f3 <<<"$cookie_value")"
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
        body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"
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

echo "== Trigger 1/6: proxy -- real HTTP GET with a unique request path =="
run_client "curl -sS -o /dev/null 'http://$ip_standard/e2e-marker-$marker_proxy'" || true
assert_marker_reaches_ui "$marker_proxy" "proxy (nginx access log)"

echo "== Trigger 2/6: ui -- real POST /domains/dns/add with an intentionally-invalid, marker-bearing domain =="
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

echo "== Trigger 3/6: nats -- a real authentication failure carrying a unique username =="
# An earlier version of this trigger created a durable JetStream consumer
# named after the marker (via the real nats-subscriber binary) and expected
# nats-server's own log to mention that name -- confirmed directly (live,
# against the real nats:2-alpine image) that it never does, at any log
# level short of full protocol trace (`trace: true`, which logs every
# message's raw payload). That was a 100%-reproducible design gap, not a
# timing race: the consumer name is only ever printed by the short-lived
# CLIENT process, whose stdout this script already discards, never by
# nats-server itself at a verbosity this project's real quickstart
# nats.conf would ever enable in production (trace-level payload logging
# would flood the forwarded logging pipeline with every real DNS record
# synced over NATS).
#
# nats-server DOES log a real, default-verbosity [ERR] line for a failed
# authentication attempt, including the attempted username verbatim --
# confirmed directly: `authentication error - User "<value>"`. Authenticating
# with the marker AS the username (and a wrong password) is a genuine,
# unmodified-nats.conf, production-observable event nats-server already logs
# on its own, not a fabricated line. Implemented as a raw NATS protocol
# CONNECT over bash's own /dev/tcp (no new client tool or image, matching
# this project's own no-new-runtime-language stance): read the server's INFO
# banner, send a CONNECT carrying the marker as the username, then give the
# server a moment to log the resulting authentication error before the
# container exits.
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
assert_marker_reaches_ui "$marker_nats" "nats (authentication-error log line carrying the attempted username)"

echo "== Trigger 4/6 and 5/6: dns-standard + dns-ssl -- one real DNS record add via the Admin UI =="
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

echo "== Trigger 6/6: watchdog -- real startup banner carrying this run's overridden CHECK_INTERVAL =="
# No separate action needed: watchdog.sh unconditionally logs
# "Interval: ${CHECK_INTERVAL}s | ..." once, immediately at container start
# (watchdog.sh, just before its `while true` loop) -- already triggered by
# Phase 3 bringing the container up with the override file's marker value.
assert_marker_reaches_ui "$marker_watchdog" "watchdog (startup banner's CHECK_INTERVAL value)"

echo "== netdata: documented weaker check (no operator-triggerable marker mechanism found) =="
# netdata is a third-party image (docs/architecture-ng.md's logging matrix);
# no repo-managed config or route was found that lets an operator inject a
# distinguishing string into its forwarded logs. Unlike
# watchdog/nats/ui/proxy/dns-standard/dns-ssl, this is a structural gap, not
# a convenience shortcut -- mirrors dhcp-probe's existing documented "Not
# applicable" treatment in the logging matrix. What IS verified: netdata's
# daemon/health logs -- the only netdata streams deploy/*/docker-compose.yml
# deliberately redirect to real, fluent-bit-tailable files; the far
# higher-rate collector stream is intentionally left on its stdout default
# and NOT forwarded, so it cannot flood the bounded /logs view and bury
# every other service's marker -- reliably produce at least one real
# forwarded line within the first minute of normal operation, so this still
# proves netdata's logging path is wired end-to-end, just without per-run
# marker discrimination.
netdata_deadline=$((SECONDS + 90))
netdata_seen=0
while (( SECONDS < netdata_deadline )); do
    body="$(run_client "curl -sS 'http://$ip_standard:8080/logs'")"
    if grep -qP '<td[^>]*>\s*netdata\s*</td>' <<<"$body"; then
        netdata_seen=1
        break
    fi
    sleep 3
done
if [[ "$netdata_seen" -ne 1 ]]; then
    echo "::error::No line attributed to host 'netdata' ever appeared via the Admin UI /logs route within 90s." >&2
    exit 1
fi
echo "OK: netdata's forwarded logging path is visible via the real Admin UI /logs route (no per-event marker; see comment above for why)."

echo "syslog-forwarding-simulation passed: proxy, ui, nats, dns-standard, dns-ssl, and watchdog were each proven end-to-end with a unique marker (real trigger -> syslog-ng file -> real Admin UI /logs response); netdata was proven present via a documented weaker check. dhcp and dhcp-proxy remain tracked follow-up work on #453 (see this script's header comment)."
