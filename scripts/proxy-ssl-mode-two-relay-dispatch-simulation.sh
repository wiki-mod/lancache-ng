#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# (proven by the sibling scripts/proxy-deep-wildcard-tls-simulation.sh,
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
# Includes a real negative control: builds the immediately-prior commit's
# proxy image (this fix not yet applied) and proves live that the exact
# same depth-2 SNI gets served a real, CA-verifiable but hostname-mismatched
# certificate there -- this test would have caught the original bug, not
# just documented its absence after the fact.
#
# Fake-origin/network-alias mechanism, RFC 2606-reserved test domain, and
# Docker embedded-DNS resolver technique all mirror
# scripts/proxy-standard-mode-sni-routing-simulation.sh's own header
# comment -- see that file for the full rationale, not repeated here.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

run_id="$(date +%s)-$$"
network_name="proxy-two-relay-sim-${run_id}"
proxy_image="proxy-two-relay-sim:fixture-${run_id}"
before_image="proxy-two-relay-sim:before-${run_id}"
backend_one_container="proxy-two-relay-sim-one-${run_id}"
backend_two_container="proxy-two-relay-sim-two-${run_id}"
proxy_container="proxy-two-relay-sim-proxy-${run_id}"
before_container="proxy-two-relay-sim-before-${run_id}"
client_allow_container="proxy-two-relay-sim-allow-${run_id}"
client_deny_container="proxy-two-relay-sim-deny-${run_id}"
work_dir="$repo_root/.proxy-two-relay-sim-tmp-${run_id}"

cleanup() {
    local status=$?
    docker rm -f "$backend_one_container" "$backend_two_container" "$proxy_container" \
        "$before_container" "$client_allow_container" "$client_deny_container" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$proxy_image" "$before_image" >/dev/null 2>&1 || true
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

echo "== Building the negative-control proxy image (this fix NOT applied, from the immediately-prior commit) =="
before_ref="$(git rev-parse HEAD)"
git worktree add -q --detach "$work_dir/before-checkout" "${before_ref}^" 2>/dev/null \
    || git worktree add -q --detach "$work_dir/before-checkout" "$before_ref" # fallback: first commit in a shallow history has no parent
docker build -q -t "$before_image" --build-context "dns-domains=$work_dir/fixture" "$work_dir/before-checkout/services/proxy" >/dev/null

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
    while (( SECONDS < deadline )); do
        if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
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
depth1_out="$(docker run --rm --network "$network_name" -v "$work_dir/ca.crt:/ca.crt:ro" "$build_tools_image" bash -c \
    "timeout 10 openssl s_client -connect ${proxy_container}:443 -servername one.example.net -CAfile /ca.crt -verify_hostname one.example.net -verify_return_error < /dev/null 2>&1" || true)"
if ! grep -q '^Verify return code: 0 (ok)' <<<"$depth1_out"; then
    echo "::error::Expected depth-1 SNI 'one.example.net' to handshake and verify cleanly against our own CA (MITM path). Full openssl output:" >&2
    echo "$depth1_out" >&2
    exit 1
fi
echo "OK: depth-1 SNI terminates at the MITM relay with our own CA-signed cert, hostname-verified."

echo "== Real TLS handshake: depth-2 SNI (two.levels.example.net) must be blind-forwarded to the REAL distinct backend, not our cert =="
depth2_subject="$(docker run --rm --network "$network_name" "$build_tools_image" bash -c \
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

echo "== Starting two fixed-IP clients to prove real client-IP preservation through the two-relay chain =="
docker run -d --name "$client_allow_container" --network "$network_name" --ip "$allow_ip" \
    "$build_tools_image" sleep 120 >/dev/null
docker run -d --name "$client_deny_container" --network "$network_name" --ip "$deny_ip" \
    "$build_tools_image" sleep 120 >/dev/null
sleep 1

proxy_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${network_name}\").IPAddress}}" "$proxy_container")"

echo "== Allowed client (${allow_ip}, inside PROXY_ALLOWED_CLIENT_CIDRS) requesting the MITM-covered host must NOT be blocked by \$lancache_client_allowed =="
allow_status="$(docker exec "$client_allow_container" curl -s -o /dev/null -w '%{http_code}' -k --resolve "one.example.net:443:${proxy_ip}" "https://one.example.net/" --max-time 10 || true)"
if [[ "$allow_status" == "403" ]]; then
    echo "::error::Expected the allowed client (${allow_ip}) to NOT receive HTTP 403 from \$lancache_client_allowed, but it did -- client-IP preservation through the two-relay chain is broken (real client IP not reaching the internal MITM listener)." >&2
    exit 1
fi
echo "OK: allowed client (${allow_ip}) was not blocked by the geo allowlist (HTTP $allow_status -- any non-403 proves \$remote_addr correctly matched PROXY_ALLOWED_CLIENT_CIDRS; the exact non-403 code depends on this script's own throwaway backend's upstream TLS trust, not the fix under test)."

echo "== Denied client (${deny_ip}, outside PROXY_ALLOWED_CLIENT_CIDRS) requesting the same MITM-covered host MUST be blocked with HTTP 403 =="
deny_status="$(docker exec "$client_deny_container" curl -s -o /dev/null -w '%{http_code}' -k --resolve "one.example.net:443:${proxy_ip}" "https://one.example.net/" --max-time 10 || true)"
if [[ "$deny_status" != "403" ]]; then
    echo "::error::Expected the denied client (${deny_ip}) to receive HTTP 403 from \$lancache_client_allowed, got: $deny_status -- either the geo check isn't running, or \$remote_addr does not reflect the real client IP through the two-relay chain." >&2
    exit 1
fi
echo "OK: denied client (${deny_ip}) correctly received HTTP 403 -- \$remote_addr through the two-relay chain reflects the REAL client IP, not the relay's own loopback address (confirms the entire point of the symmetric two-relay design)."

echo "== Confirming the access log itself shows the real client IPs, not 127.0.0.1 (the relay's own loopback) =="
access_log="$(docker exec "$proxy_container" cat /var/log/nginx/access.log)"
if ! grep -q "^${allow_ip} " <<<"$access_log" || ! grep -q "^${deny_ip} " <<<"$access_log"; then
    echo "::error::Expected the proxy's own access log to show both real client IPs (${allow_ip}, ${deny_ip}), not the relay's loopback address. Access log:" >&2
    echo "$access_log" >&2
    exit 1
fi
echo "OK: access log shows the real client IPs directly."

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

echo "== Negative control: the SAME depth-2 SNI against the pre-fix image must get a mismatched LOCAL cert (the original #1322 bug), not real backend content =="
docker run -d --name "$before_container" --network "$network_name" \
    -e IP_STANDARD=10.10.10.10 -e IP_SSL=10.10.10.12 -e SSL_ENABLED=1 -e PROXY_SECURITY_MODE=strict \
    -e NGINX_UPSTREAM_RESOLVER="127.0.0.11:53" \
    -e CACHE_MAX_SIZE=1g -e CACHE_MEM_MB=64 -e CACHE_SLICE_SIZE=1m \
    -e CACHE_VALID_HIT=1d -e CACHE_VALID_ANY=1m -e CACHE_INACTIVE=1d \
    "$before_image" >/dev/null
wait_for_tcp "$before_container" 443
# Each proxy container generates its OWN independent CA at first boot (no
# shared volume between the "after" and "before" containers) -- reusing the
# "after" container's ca.crt here would fail with "unable to get local
# issuer certificate" regardless of hostname matching, which is a
# different, misleading failure mode from the actual bug this negative
# control needs to reproduce. Fetch the "before" container's own CA
# instead, exactly as the real client-facing setup docs require per
# container.
before_ca="$(docker exec "$before_container" cat /etc/nginx/ssl/ca/ca.crt)"
printf '%s' "$before_ca" > "$work_dir/before-ca.crt"
before_out="$(docker run --rm --network "$network_name" -v "$work_dir/before-ca.crt:/ca.crt:ro" "$build_tools_image" bash -c \
    "timeout 10 openssl s_client -connect ${before_container}:443 -servername two.levels.example.net -CAfile /ca.crt -verify_hostname two.levels.example.net -verify_return_error < /dev/null 2>&1" || true)"
if ! grep -q 'hostname mismatch' <<<"$before_out"; then
    echo "::error::Expected the PRE-FIX image to reproduce the original bug (a hostname-mismatched local cert for depth-2 SNI) as a negative control, but it did not. This means either the 'before' checkout is not actually pre-fix, or something else changed. Full openssl output:" >&2
    echo "$before_out" >&2
    exit 1
fi
echo "OK: negative control confirms the pre-fix image reproduces the original bug live (hostname mismatch against our own CA for the identical depth-2 SNI) -- proving this test actually detects the bug this PR fixes, not just documenting its absence."

echo "proxy-ssl-mode-two-relay-dispatch-simulation passed: regex-anchored depth dispatch correctly separates MITM-covered from passthrough-only SNI (including the root-level leading-dot case), the symmetric two-relay design preserves the real client IP end to end for \$lancache_client_allowed and access logging, the dedicated healthcheck port works while the PROXY-protocol-only internal port correctly rejects a plain connection, and a live negative control against the pre-fix image confirms this test detects the original bug."
