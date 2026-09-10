#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: E2E proof logs reach Admin UI via pipeline.
# Why: Validates live UI flow, not just presence/shape.
# From: Issue #864
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/setup-wizard-introspect.sh
source "$repo_root/scripts/lib/setup-wizard-introspect.sh"

: "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# What: marks repo_root safe for git (foreign-UID mount).
# Why: else git refuses it as "dubious ownership".
git config --global --add safe.directory "$repo_root"

work_dir="$repo_root/.syslog-forwarding-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"
if ! install_dir="$(mktemp -d "$work_dir/install.XXXXXX")"; then
    echo "::error::Failed to create a unique install directory under $work_dir via mktemp." >&2
    exit 1
fi

# What: derives unique loopback IP per CI run.
# Why: avoids address collisions across concurrent runs.
run_key="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}-$$"
# What: derives unique octet from run key.
# Why: cksum portable, %200 avoids low octets.
octet=$(( $(printf '%s' "$run_key" | cksum | cut -d' ' -f1) % 200 + 10 ))
ip_standard="127.0.${octet}.2"
ip_ssl="127.0.${octet}.3"

# What: sanitizes the mktemp basename into a project name.
# Why: Compose requires ^[a-z0-9][a-z0-9_-]*$ for the name.
sim_compose_project_name() {
    printf 'lancache-ng-syslog-e2e-%s\n' "$(basename "$1" | tr 'A-Z.' 'a-z-')"
}
if ! compose_project="$(sim_compose_project_name "$install_dir")"; then
    echo "::error::Failed to derive a sanitized Compose project name from install_dir ($install_dir)." >&2
    exit 1
fi
export COMPOSE_PROJECT_NAME="$compose_project"
network_name="${compose_project}_default"

# What: derives per-run container name suffix.
# Why: avoids collision on fixed container names.
# From: Issue #1415
sim_container_name_suffix() {
    printf -- '-syslog-e2e-%s\n' "$(basename "$1" | tr 'A-Z.' 'a-z-')"
}
if ! LANCACHE_CONTAINER_SUFFIX="$(sim_container_name_suffix "$install_dir")"; then
    echo "::error::Failed to derive a sanitized LANCACHE_CONTAINER_SUFFIX from install_dir ($install_dir)." >&2
    exit 1
fi
export LANCACHE_CONTAINER_SUFFIX

# What: generates alphanumeric-only per-run marker.
# Why: must pass domain validator and HTML rendering.
if ! marker_base="lancachee2e$(date +%s%N)pid$$"; then
    echo "::error::Failed to generate the per-run marker base via date +%s%N." >&2
    exit 1
fi
marker_proxy="${marker_base}proxy"
marker_ui="${marker_base}ui"
marker_nats="${marker_base}nats"
marker_dns="${marker_base}dns"
# What: 8-digit numeric watchdog CHECK_INTERVAL marker.
# Why: startup banner logs it; found later in /logs.
# From: PR #1836
if ! marker_watchdog="$(date +%s%N | tail -c 9)"; then
    echo "::error::Failed to generate the watchdog CHECK_INTERVAL marker via date +%s%N | tail." >&2
    exit 1
fi
# What: validates digits and lifts a leading zero to 9.
# Why: watchdog logs it as int; 0-pad would mismatch.
# From: PR #1836
case "$marker_watchdog" in
    ''|*[!0-9]*)
        echo "::error::watchdog CHECK_INTERVAL marker is not all-digits: '$marker_watchdog'." >&2
        exit 1
        ;;
    0*) marker_watchdog="9${marker_watchdog#?}" ;;
esac

# What: allocates isolated DHCP test subnets.
# Why: avoids collision with production IP ranges.
# From: Issue #864
dhcp_gateway="172.29.${octet}.1"
dhcp_range_start="172.29.${octet}.10"
dhcp_range_end="172.29.${octet}.100"
dhcp_proxy_gateway="172.29.${octet}.129"
# What: sets dhcp-proxy subnet start for marker.
# Why: dnsmasq logs this value in startup banner.
# From: Issue #864
dhcp_proxy_subnet_start="172.29.${octet}.140"

cleanup() {
    local status=$?
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
        # What: tears down stack with profile flags.
        # Why: bare down leaves dhcp/dhcp-proxy running.
        # From: Issue #864
        docker compose --project-directory "$install_dir" \
            -f "$install_dir/docker-compose.yml" \
            -f "$work_dir/logging-test-override.yml" \
            -f "$work_dir/dhcp-test-override.yml" \
            --env-file "$install_dir/.env" \
            --profile ssl --profile logging --profile dhcp-kea --profile dhcp-proxy \
            down -v --remove-orphans >/dev/null 2>&1 || true
        # What: force-removes containers by suffix.
        # Why: defense-in-depth against failures.
        # From: Issue #1415
        docker rm -f "lancache-dhcp${LANCACHE_CONTAINER_SUFFIX:-}" "lancache-dhcp-proxy${LANCACHE_CONTAINER_SUFFIX:-}" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Phase 1: fresh install via the real setup.sh CLI (expect-driven, mirrors setup-cli-simulation.sh) =="

# What: enables SSL, disables DHCP in main env.
# Why: DHCP started via profile override later.
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

# What: forces SYSLOG_ENABLED and the logging profile.
# Why: doesn't rely on the setup wizard's current default.
if grep -q '^SYSLOG_ENABLED=' "$install_dir/.env"; then
    sed -i 's/^SYSLOG_ENABLED=.*/SYSLOG_ENABLED=true/' "$install_dir/.env"
else
    printf 'SYSLOG_ENABLED=true\n' >> "$install_dir/.env"
fi

# What: greps PROFILES line via variable binding.
# Why: avoids SIGPIPE under pipefail with >1 match.
# From: Issue #1377
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

# What: sets NATS_CALLOUT_USER to per-run marker.
# Why: auth error log includes attempted username.
if grep -q '^NATS_CALLOUT_USER=' "$install_dir/.env"; then
    sed -i "s/^NATS_CALLOUT_USER=.*/NATS_CALLOUT_USER=${marker_nats}/" "$install_dir/.env"
else
    echo "::error::Fresh install did not define NATS_CALLOUT_USER in .env." >&2
    exit 1
fi
grep -qF "NATS_CALLOUT_USER=${marker_nats}" "$install_dir/.env" \
    || { echo "::error::Failed to assign the per-run NATS marker to NATS_CALLOUT_USER." >&2; exit 1; }

# What: overrides watchdog env via compose file.
# Why: CHECK_INTERVAL hardcoded in base, needs override.
# From: Issue #1415
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

# What: moves dhcp/dhcp-proxy off host net via !reset.
# Why: real secrets stay in .env, avoiding split-brain.
# From: Issue #864
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

# What: lists services with Docker HEALTHCHECKs.
# Why: health-wait loop requires this list.
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
        # What: re-polls health for a short window.
        # Why: closes the gap left by the bulk wait.
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
    # What: prints each service's RestartCount on failure.
    # Why: containers are gone by the time anyone looks.
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
    # What: dumps nats-server's own log file, not stdout.
    # Why: nats's log_file directive sends it there only.
    "${compose[@]}" exec -T nats sh -c 'cat /var/log/lancache-nats/nats.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's own Kea log"
    # What: reads Kea's log in case stdout empty.
    # Why: dhcp had no stdout in a failing run.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c 'cat /var/log/kea/kea-dhcp4.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's own Kea Control Agent log"
    # What: reads kea-ctrl-agent log separately.
    # Why: healthcheck hits port 8000 on separate process.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c 'cat /var/log/kea/kea-ctrl-agent.log 2>/dev/null | tail -n 200' || true
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp's Docker healthcheck output"
    # What: dumps Docker healthcheck status.
    # Why: Kea logs don't show healthcheck result.
    # From: PR #1775
    if dhcp_cid="$("${compose[@]}" ps -q dhcp)" && [[ -n "$dhcp_cid" ]]; then
        docker inspect --format '{{json .State.Health}}' "$dhcp_cid" | jq . || true
    fi
    echo "::endgroup::"

    echo "::group::Failure diagnostics: dhcp healthcheck request re-run verbose"
    # What: re-run healthcheck without swallowing error.
    # Why: -sf hides real HTTP status/body on failure.
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

    echo "::group::Failure diagnostics: kea-ctrl-token file vs rendered conf"
    # What: compares token file to rendered conf.
    # Why: 401 with real token implies split-brain.
    # From: PR #1775
    "${compose[@]}" exec -T dhcp sh -c '
        file_sum="$(md5sum /var/lib/lancache-secrets/kea-ctrl-token 2>/dev/null | cut -d" " -f1)"
        conf_tok="$(sed -n "s/.*\"password\": \"\([^\"]*\)\".*/\1/p" /var/lib/kea/kea-ctrl-agent.conf 2>/dev/null)"
        conf_sum="$(printf "%s" "$conf_tok" | md5sum | cut -d" " -f1)"
        echo "shared-secrets file md5: $file_sum"
        echo "rendered conf token md5: $conf_sum (len=${#conf_tok})"
        [ "$file_sum" = "$conf_sum" ] && echo "MATCH" || echo "MISMATCH"
    ' || true
    echo "::endgroup::"

    echo "::group::Logs from all services (failure diagnostics)"
    "${compose[@]}" logs --no-color
    echo "::endgroup::"
    exit 1
fi
echo "All 8 stack services (7 wired + docker-socket-proxy) are running and healthy."

# What: runs a client via docker on the host network.
# Why: --network host reaches the loopback address.
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

# What: polls /logs for the marker until it appears.
# Why: distinguishes UI-visible from forwarding failure.
assert_marker_reaches_ui() {
    local marker="$1" description="$2" timeout="${3:-90}"
    shift $(( $# < 3 ? $# : 3 ))
    local -a source_containers=("$@")
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
    if (( ${#source_containers[@]} > 0 )); then
        # What: dumps each source container's raw logs.
        # Why: not-logged vs. forwarded (AG-INT-002).
        # From: Issue #1095 (PR #1836)
        echo "::group::raw container logs (${source_containers[*]}): did any emit the marker?"
        "${compose[@]}" logs --no-color --tail=100 "${source_containers[@]}" 2>&1 || true
        echo "::endgroup::"
    fi
    return 1
}

echo "== Trigger 1/8: proxy -- real HTTP GET with a unique request path =="
run_client "curl -sS -o /dev/null 'http://$ip_standard/e2e-marker-$marker_proxy'" || true
assert_marker_reaches_ui "$marker_proxy" "proxy (nginx access log)" 90 proxy

echo "== Trigger 2/8: ui -- real POST /domains/dns/add with an intentionally-invalid, marker-bearing domain =="
# What: rejects a domain with no '.' before writing.
# Why: guarantees a marker with no real state changed.
run_client "curl -sS -o /dev/null -b /shared/cookiejar \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'domain=$marker_ui' \
    'http://$ip_standard:8080/domains/dns/add'" || true
assert_marker_reaches_ui "$marker_ui" "ui (Rejected invalid dns domain warning)" 90 ui

echo "== Trigger 3/8: nats -- real static-user authentication failure carrying the per-run username =="
# What: NATS_CALLOUT_USER doubles as this trigger's marker.
# Why: a bad password fails on nats-server's local path.
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

# What: reports raw CONNECT probe failure.
# Why: swallowed failure looked like real bug.
# From: Issue #1095
nats_probe_status=0
nats_probe_out="$(docker run --rm --network "$network_name" \
    -e "NATS_AUTH_MARKER=$marker_nats" \
    "$BUILD_TOOLS_IMAGE" bash -c '
        exec 3<>/dev/tcp/nats/4222 || { echo "CONNECT_FAILED: cannot open /dev/tcp/nats/4222"; exit 1; }
        read -r -t 5 info <&3
        printf "CONNECT {\"user\":\"%s\",\"pass\":\"wrong\",\"verbose\":false,\"pedantic\":false}\r\n" "$NATS_AUTH_MARKER" >&3
        read -r -t 3 err <&3
        sleep 1
        printf "server-info: %s\nserver-reply: %s\n" "$info" "$err"
    ' 2>&1)" || nats_probe_status=$?
if [ "$nats_probe_status" -ne 0 ]; then
    echo "::warning::NATS raw-TCP auth probe itself failed (exit $nats_probe_status); the marker below is not expected to appear. Probe output:" >&2
    printf '%s\n' "$nats_probe_out" >&2
fi
assert_marker_reaches_ui "$marker_nats" "nats (static-user authentication-error log line carrying the attempted username)" 90 nats

echo "== Trigger 4/8 and 5/8: dns-standard + dns-ssl -- one real DNS record add via the Admin UI =="
# What: dns-standard and dns-ssl share one NATS subject.
# Why: one real UI write proves both services' log paths.
run_client "curl -sS -o /dev/null -b /shared/cookiejar \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'name=$marker_dns' \
    --data-urlencode 'record_type=A' \
    --data-urlencode 'content=203.0.113.99' \
    --data-urlencode 'ttl=60' \
    'http://$ip_standard:8080/domains/lan/add'" || true
assert_marker_reaches_ui "$marker_dns" "dns-standard AND dns-ssl (nats-subscriber's own record-applied log line)" 90 dns-standard dns-ssl

echo "== Trigger 6/8: watchdog -- real startup banner carrying this run's overridden CHECK_INTERVAL =="
# What: watchdog logs CHECK_INTERVAL once at startup.
# Why: already triggered by Phase 3's container start.
assert_marker_reaches_ui "$marker_watchdog" "watchdog (startup banner's CHECK_INTERVAL value)" 90 watchdog

echo "== Trigger 7/8: dhcp (Kea) -- a real DHCPDISCOVER/OFFER/REQUEST/ACK lease over the isolated dhcp-test-net =="
# What: runs a real dhclient lease over dhcp-test-net.
# Why: proves Kea's own DHCP4_LEASE_ALLOC log line.
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
    # What: waits for the lease file's closing brace.
    # Why: the file exists before dhclient finishes writing.
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

# What: captures fixed-address lines before piping to head.
# Why: avoids SIGPIPE under pipefail with >1 match.
# From: Issue #1377
if ! fixed_address_lines="$(grep -oE 'fixed-address [0-9.]+' "$work_dir/shared/dhcp-client.leases")"; then
    echo "::error::Could not parse the offered address out of the real dhclient lease file." >&2
    exit 1
fi
dhcp_offered_address="$(head -1 <<<"$fixed_address_lines" | cut -d' ' -f2)"
[[ -n "$dhcp_offered_address" ]] || { echo "::error::dhclient's lease file had no fixed-address field." >&2; exit 1; }
echo "Real lease obtained: $dhcp_offered_address (Kea's own DHCP4_LEASE_ALLOC log line names this address verbatim)."
# What: matches the full DHCP4_LEASE_ALLOC wording.
# Why: a bare IP substring-matches unrelated log lines.
dhcp_lease_marker="lease ${dhcp_offered_address} has been allocated"
assert_marker_reaches_ui "$dhcp_lease_marker" "dhcp/Kea (DHCP4_LEASE_ALLOC log line naming the real leased address)" 90 dhcp

echo "== Trigger 8/8: dhcp-proxy (dnsmasq) -- real DHCPDISCOVER over the isolated dhcp-proxy-test-net; per-run-unique proxy-subnet startup marker =="
# What: dnsmasq-proxy never completes a lease on its own.
# Why: marker is its startup banner's subnet-start value.
dhcp_proxy_client_container="lancachee2e-dhcp-proxy-client-$$"
docker run -d --name "$dhcp_proxy_client_container" \
    --network "${compose_project}_dhcp-proxy-test-net" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    "$BUILD_TOOLS_IMAGE" \
    bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /tmp/dhcp-proxy-client.pid -lf /tmp/dhcp-proxy-client.leases eth0 >/tmp/dhcp-proxy-client.out 2>&1 || true; sleep 3' \
    >/dev/null
sleep 5
docker rm -f "$dhcp_proxy_client_container" >/dev/null 2>&1 || true
assert_marker_reaches_ui "$dhcp_proxy_subnet_start" "dhcp-proxy/dnsmasq (startup banner's DHCP_SUBNET_START value)" 90 dhcp-proxy

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
# What: waits for fluent-bit's own startup line in /logs.
# Why: no operator-triggerable marker exists for its log.
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
