#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Real end-to-end simulation for services/proxy's SSL-mode stream-level SNI
# depth-dispatch and symmetric two-relay client-IP fix (issues #1276/#1322).
#
# The bug this closes: a leading-dot cdn-domains.txt entry DNS-spoofs
# arbitrary depth below it (services/dns/entrypoint.sh's RPZ generation,
# #1072), but a pre-generated X.509 wildcard cert only ever covers exactly
# one label of depth (RFC 6125) -- a client two or more labels below such an
# entry got served a certificate that does not validate for its SNI, and
# the TLS handshake failed outright even though DNS resolution worked
# (proven by the sibling scripts/tracked/simulations/proxy-deep-wildcard-tls-simulation.sh,
# which still documents that residual RFC 6125 gap, now via config-content
# assertions instead of a live mismatch handshake). This script proves the
# fix itself: a stream-level dispatcher reads the SNI via ssl_preread before
# any TLS termination and routes depth-covered SNI to a real MITM cert path,
# or depth-uncovered (but still DNS-spoofed) SNI to a passthrough relay that
# blind-forwards to the real origin instead of failing.
#
# Also proves the reason a single new relay wasn't enough: proxy_protocol
# (needed to preserve the real client IP across the stream-level hop, for
# $lancache_client_allowed/PROXY_ALLOWED_CLIENT_CIDRS and access logging)
# applies per stream server block, not per destination -- a symmetric
# two-relay design (one per branch) is required so the passthrough branch's
# raw bytes to a real external origin are never touched by it. Confirmed
# live during this fix's own development that a single-relay version does
# NOT work: the outer dispatcher's own connection to whichever relay it
# picked showed up as 127.0.0.1, not the real client, regardless of what
# was configured on the relay alone.
#
# This script deliberately does NOT bake a live negative control (building
# an old pre-fix commit and proving it reproduces the original bug) into
# this permanent, standing CI job -- neither sibling simulation in this
# directory (proxy-standard-mode-sni-routing-simulation.sh,
# proxy-deep-wildcard-tls-simulation.sh) does that either, and for the same
# reason: once this fix is merged into the base branch, EVERY future PR's
# checkout has the fix as part of its own inherited history, so there is no
# longer a stable, branch-independent "pre-fix" commit to compute on demand
# (a `git merge-base HEAD origin/<base>` against a moving base-branch tip
# that already contains the fix resolves to whatever ancestor two unrelated
# branches happen to share -- not a defined pre-fix state, and in practice
# produced three different, unpredictable failure modes across three real
# CI runs instead of one stable pre-fix behavior). The negative control
# for this fix was instead performed once, live, by hand, against a real
# pre-fix checkout on the runner, with full openssl output recorded in
# issue #1276's own comment thread -- matching how this project has proven
# every prior fix in this same family. What this script keeps permanently
# asserting is the fix's own current, positive behavior: the dispatch map
# content itself (regex-anchored, not nginx "hostnames" mode), the depth-1
# MITM handshake, and -- as the strongest ongoing regression guard -- the
# depth-2 handshake reaching the real, distinct backend-two-real certificate
# (a pre-fix build could never produce that subject for this SNI; it would
# either fail the handshake outright or return this proxy's own generated
# cert instead, either of which the assertion below already treats as a
# failure).
#
# Fake-origin/network-alias mechanism, RFC 2606-reserved test domain, and
# Docker embedded-DNS resolver technique all mirror
# scripts/tracked/simulations/proxy-standard-mode-sni-routing-simulation.sh's own header
# comment -- see that file for the full rationale, not repeated here.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

run_id="$(date +%s)-$$"
network_name="proxy-two-relay-sim-${run_id}"
proxy_image="proxy-two-relay-sim:fixture-${run_id}"
backend_one_container="proxy-two-relay-sim-one-${run_id}"
backend_two_container="proxy-two-relay-sim-two-${run_id}"
proxy_container="proxy-two-relay-sim-proxy-${run_id}"
client_allow_container="proxy-two-relay-sim-allow-${run_id}"
client_deny_container="proxy-two-relay-sim-deny-${run_id}"
work_dir="$repo_root/.proxy-two-relay-sim-tmp-${run_id}"

cleanup() {
    local status=$?
    docker rm -f "$backend_one_container" "$backend_two_container" "$proxy_container" \
        "$client_allow_container" "$client_deny_container" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$proxy_image" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$work_dir/fixture"

# A root-level leading-dot entry (domain == its own registrable root, RFC
# 2606-reserved "example.net") -- the specific shape entrypoint.sh's
# _ROOT_HAS_WILDCARD_ENTRY tracks, distinct from a deeper leading-dot base
# (_EXTRA_WILDCARD_BASES), and the shape scripts/proxy-deep-wildcard-tls-
# simulation.sh's own fixtures do not cover (its ".steamcontent.com"-style
# root-level case has no depth>1 test at all). "one.example.net" is one
# label below (must reach the MITM relay/real cert); "two.levels.example.net"
# is two labels below (must reach the passthrough relay instead).
printf '%s\n' '.example.net' > "$work_dir/fixture/cdn-domains.txt"

echo "== Generating two distinguishable self-signed backend certs =="
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout one.key -out one.crt -days 1 -subj '/CN=backend-one-real' 2>/dev/null" >/dev/null
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout two.key -out two.crt -days 1 -subj '/CN=backend-two-real' 2>/dev/null" >/dev/null

echo "== Building the real proxy image (this fix applied) =="
docker build -q -t "$proxy_image" --build-context "dns-domains=$work_dir/fixture" services/proxy >/dev/null

docker network create --subnet 172.29.77.0/24 "$network_name" >/dev/null

# Fixed IPs so PROXY_ALLOWED_CLIENT_CIDRS can be scoped to exactly one of
# these two clients below -- addresses are this script's own throwaway
# network's own subnet, not a real LAN.
allow_ip="172.29.77.10"
deny_ip="172.29.77.20"

echo "== Starting fake origin backends (real openssl s_server, one per hostname alias) =="
docker run -d --name "$backend_one_container" --network "$network_name" --network-alias one.example.net \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/one.crt -key /certs/one.key -naccept 200 -quiet -www" >/dev/null
docker run -d --name "$backend_two_container" --network "$network_name" --network-alias two.levels.example.net \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/two.crt -key /certs/two.key -naccept 200 -quiet -www" >/dev/null

wait_for_tcp() {
    local container="$1" port="$2"
    local deadline=$((SECONDS + 60))
    local container_running_state
    while (( SECONDS < deadline )); do
        # Captured into a variable first, then grep applied via here-string,
        # rather than `docker inspect ... | grep -q true`: eliminates the
        # live producer/early-exiting-consumer pipe entirely (issue #1377's
        # repo-wide pipefail/SIGPIPE audit, AG-VAL-032 -- caught as a fresh
        # instance after this script itself landed via PR #1411, later than
        # the original audit pass).
        container_running_state="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
        if ! grep -q true <<<"$container_running_state"; then
            echo "::error::$container is not running (crashed during startup). Logs:" >&2
            docker logs "$container" 2>&1 | tail -60 >&2
            return 1
        fi
        if docker run --rm --network "$network_name" "$build_tools_image" \
            bash -c "timeout 3 bash -c '</dev/tcp/${container}/${port}'" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "::error::$container never became reachable on :$port within 60s. Logs:" >&2
    docker logs "$container" 2>&1 | tail -60 >&2
    return 1
}

wait_for_tcp "$backend_one_container" 443
wait_for_tcp "$backend_two_container" 443

echo "== Starting the real proxy container (this fix applied), PROXY_ALLOWED_CLIENT_CIDRS scoped to ${allow_ip}/32 =="
docker run -d --name "$proxy_container" --network "$network_name" \
    -e IP_STANDARD=10.10.10.10 -e IP_SSL=10.10.10.11 -e SSL_ENABLED=1 -e PROXY_SECURITY_MODE=strict \
    -e NGINX_UPSTREAM_RESOLVER="127.0.0.11:53" \
    -e "PROXY_ALLOWED_CLIENT_CIDRS=${allow_ip}/32" \
    -e CACHE_MAX_SIZE=1g -e CACHE_MEM_MB=64 -e CACHE_SLICE_SIZE=1m \
    -e CACHE_VALID_HIT=1d -e CACHE_VALID_ANY=1m -e CACHE_INACTIVE=1d \
    "$proxy_image" >/dev/null
wait_for_tcp "$proxy_container" 443

# Started here, ahead of the depth-1/depth-2 TLS probes below: PROXY_ALLOWED_
# CLIENT_CIDRS is scoped to allow_ip/32 from the proxy container's own
# startup above, and entrypoint.sh's "2b." stream-level ACL gates ALL
# external connections to this container's :443 dispatcher, including these
# probes -- an ephemeral, arbitrary-IP throwaway container is not a usable
# TLS client against this fixture; only a client whose source address is
# actually inside PROXY_ALLOWED_CLIENT_CIDRS can reach ssl_preread at all.
# client_deny_container is also started here, alongside
# client_allow_container, for the same fixed-topology reason even though its
# own first use is still later below.
echo "== Starting two fixed-IP clients to prove real client-IP preservation through the two-relay chain =="
docker run -d --name "$client_allow_container" --network "$network_name" --ip "$allow_ip" \
    "$build_tools_image" sleep 120 >/dev/null
docker run -d --name "$client_deny_container" --network "$network_name" --ip "$deny_ip" \
    "$build_tools_image" sleep 120 >/dev/null
sleep 1

echo "== Verifying the generated dispatch map routes depth-1 to the MITM relay and depth-2 to the passthrough relay (regex-anchored, not nginx 'hostnames' mode) =="
dispatch_map="$(docker exec "$proxy_container" cat /etc/nginx/stream.d/01-ssl-dispatch.conf)"
if ! grep -qE '"~\^\[\^\.\]\+\\\.example\\\.net\$"\s+127\.0\.0\.1:9445;' <<<"$dispatch_map"; then
    echo "::error::Expected a depth-1 regex entry for example.net routing to the MITM relay (127.0.0.1:9445). Generated map:" >&2
    echo "$dispatch_map" >&2
    exit 1
fi
if ! grep -qE '"~\^\.\+\\\.example\\\.net\$"\s+127\.0\.0\.1:9446;' <<<"$dispatch_map"; then
    echo "::error::Expected a depth>=2 catch-all entry for example.net routing to the passthrough relay (127.0.0.1:9446). Generated map:" >&2
    echo "$dispatch_map" >&2
    exit 1
fi
echo "OK: dispatch map correctly separates depth-1 (MITM relay) from depth>=2 (passthrough relay) for the root-level wildcard entry."

echo "== Real TLS handshake: depth-1 SNI (one.example.net) must terminate at the internal MITM listener with OUR generated cert =="
ca_crt="$(docker exec "$proxy_container" cat /etc/nginx/ssl/ca/ca.crt)"
printf '%s' "$ca_crt" > "$work_dir/ca.crt"
docker cp "$work_dir/ca.crt" "$client_allow_container:/ca.crt" >/dev/null
# Run via `docker exec` against the fixed-IP allow-listed client, not an
# ephemeral `docker run --rm` container: the latter would get an arbitrary
# IP the outer dispatcher's stream-level ACL (scoped to allow_ip/32 only)
# rejects before ssl_preread ever runs, failing this handshake for a reason
# unrelated to what this probe is actually proving.
depth1_out="$(docker exec "$client_allow_container" bash -c \
    "timeout 10 openssl s_client -connect ${proxy_container}:443 -servername one.example.net -CAfile /ca.crt -verify_hostname one.example.net -verify_return_error < /dev/null 2>&1" || true)"
if ! grep -q '^Verify return code: 0 (ok)' <<<"$depth1_out"; then
    echo "::error::Expected depth-1 SNI 'one.example.net' to handshake and verify cleanly against our own CA (MITM path). Full openssl output:" >&2
    echo "$depth1_out" >&2
    exit 1
fi
echo "OK: depth-1 SNI terminates at the MITM relay with our own CA-signed cert, hostname-verified."

echo "== Real TLS handshake: depth-2 SNI (two.levels.example.net) must be blind-forwarded to the REAL distinct backend, not our cert =="
depth2_subject="$(docker exec "$client_allow_container" bash -c \
    "echo | timeout 10 openssl s_client -connect ${proxy_container}:443 -servername two.levels.example.net 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" || true)"
if [[ -z "$depth2_subject" ]]; then
    echo "::error::Handshake for depth-2 SNI 'two.levels.example.net' produced no certificate at all (dead backend or passthrough relay failure) -- test-infrastructure failure, not evidence either way." >&2
    docker logs "$proxy_container" 2>&1 | tail -40 >&2
    exit 1
fi
if [[ "$depth2_subject" != "subject=CN=backend-two-real" ]]; then
    echo "::error::Expected depth-2 SNI to reach the real backend-two (CN=backend-two-real) via the passthrough relay, got: $depth2_subject" >&2
    exit 1
fi
echo "OK: depth-2 SNI is blind-forwarded to the real distinct backend ($depth2_subject), not a mismatched local cert -- this is exactly the connectivity gap #1276/#1322 closes."

proxy_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${network_name}\").IPAddress}}" "$proxy_container")"

echo "== Allowed client (${allow_ip}, inside PROXY_ALLOWED_CLIENT_CIDRS) requesting the MITM-covered host must NOT be blocked by \$lancache_client_allowed =="
allow_status="$(docker exec "$client_allow_container" curl -s -o /dev/null -w '%{http_code}' -k --resolve "one.example.net:443:${proxy_ip}" "https://one.example.net/" --max-time 10 || true)"
if [[ "$allow_status" == "403" ]]; then
    echo "::error::Expected the allowed client (${allow_ip}) to NOT receive HTTP 403 from \$lancache_client_allowed, but it did -- client-IP preservation through the two-relay chain is broken (real client IP not reaching the internal MITM listener)." >&2
    exit 1
fi
echo "OK: allowed client (${allow_ip}) was not blocked by the geo allowlist (HTTP $allow_status -- any non-403 proves \$remote_addr correctly matched PROXY_ALLOWED_CLIENT_CIDRS; the exact non-403 code depends on this script's own throwaway backend's upstream TLS trust, not the fix under test)."

echo "== Denied client (${deny_ip}, outside PROXY_ALLOWED_CLIENT_CIDRS) requesting the same MITM-covered host MUST be rejected at the stream level, before any TLS handshake or HTTP response =="
# entrypoint.sh's "2b." enforces PROXY_ALLOWED_CLIENT_CIDRS via
# ngx_stream_access_module's plain allow/deny at the outer :443 dispatcher,
# checked before ssl_preread even runs -- not the http-context
# $lancache_client_allowed geo variable, which cannot cross the http{}/
# stream{} boundary and would require a completed TLS handshake first
# regardless. A denied connection is therefore refused/reset at the TCP
# level and never produces any HTTP response at all: curl's own documented
# behavior for "-w '%{http_code}'" is to print the literal string "000"
# when no HTTP response was received, which is what this assertion checks
# for -- not "403" (that status code implies a completed handshake that
# never happens for a denied client at this dispatch point).
deny_status="$(docker exec "$client_deny_container" curl -s -o /dev/null -w '%{http_code}' -k --resolve "one.example.net:443:${proxy_ip}" "https://one.example.net/" --max-time 10 || true)"
if [[ "$deny_status" != "000" ]]; then
    echo "::error::Expected the denied client (${deny_ip}) to be rejected at the TCP/stream level (curl status '000', no HTTP response received at all), got HTTP status: $deny_status -- either the stream-level ACL isn't running, or \$remote_addr does not reflect the real client IP through the two-relay chain." >&2
    exit 1
fi
echo "OK: denied client (${deny_ip}) was rejected at the stream level before any TLS handshake or HTTP response -- proves \$remote_addr through the two-relay chain reflects the REAL client IP (confirms the entire point of the symmetric two-relay design), and that the stream-level ACL takes effect ahead of ssl_preread."

echo "== Confirming the access log itself shows the allowed client's real IP, not 127.0.0.1 (the relay's own loopback) =="
# The denied client is deliberately NOT expected here: its connection is
# rejected at the outer stream dispatcher before ever reaching the MITM
# relay's own HTTP-layer vhost that writes this log, so it never gets an
# access-log entry at all -- a TCP-level rejection point, not an HTTP-layer
# 403, and therefore no log line to find.
access_log="$(docker exec "$proxy_container" cat /var/log/nginx/access.log)"
if ! grep -q "^${allow_ip} " <<<"$access_log"; then
    echo "::error::Expected the proxy's own access log to show the allowed client's real IP (${allow_ip}), not the relay's loopback address. Access log:" >&2
    echo "$access_log" >&2
    exit 1
fi
if grep -q "^${deny_ip} " <<<"$access_log"; then
    echo "::error::Denied client (${deny_ip}) unexpectedly reached the HTTP-layer access log -- it should have been rejected earlier, at the stream-level ACL, before ever reaching the MITM relay's vhost. Access log:" >&2
    echo "$access_log" >&2
    exit 1
fi
echo "OK: access log shows the allowed client's real IP directly, and correctly has no entry at all for the denied client (rejected before the HTTP layer)."

echo "== Healthcheck: dedicated non-PROXY-protocol port (8445) must work; the PROXY-protocol-only internal MITM port (8444) must NOT accept a plain connection =="
if ! docker exec "$proxy_container" curl -ksf https://127.0.0.1:8445/healthz >/dev/null; then
    echo "::error::Expected the dedicated healthcheck port 8445 to serve /healthz successfully." >&2
    exit 1
fi
if docker exec "$proxy_container" curl -ksf --max-time 5 https://127.0.0.1:8444/healthz >/dev/null 2>&1; then
    echo "::error::Expected port 8444 (mandatory PROXY protocol) to reject a plain curl connection with no PROXY protocol preamble -- if this unexpectedly succeeds, port 8444's 'listen ... proxy_protocol' requirement silently stopped applying." >&2
    exit 1
fi
echo "OK: healthcheck port 8445 works; 8444 correctly requires a real PROXY protocol preamble (curl alone cannot reach it, confirming port 8445 is genuinely needed, not redundant)."

echo "proxy-ssl-mode-two-relay-dispatch-simulation passed: regex-anchored depth dispatch correctly separates MITM-covered from passthrough-only SNI (including the root-level leading-dot case), the symmetric two-relay design preserves the real client IP end to end for \$lancache_client_allowed and access logging, and the dedicated healthcheck port works while the PROXY-protocol-only internal port correctly rejects a plain connection."
