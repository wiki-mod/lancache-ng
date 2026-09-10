#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Tests proxy standard-mode SNI passthrough routing.
# Why: Verify wildcard routes to SNI, not derived root.
# From: Issue #1297
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# Unique per-invocation suffix for every Docker resource this script creates
# -- avoids name collisions with a concurrent run of this same script (or
# the sibling deep-wildcard script) on a shared self-hosted runner host, the
# same reasoning as that script's own header comment.
run_id="$(date +%s)-$$"
network_name="proxy-sni-route-sim-${run_id}"
proxy_image="proxy-sni-route-sim:fixture-${run_id}"
backend_root_container="proxy-sni-route-sim-root-${run_id}"
backend_sub_container="proxy-sni-route-sim-sub-${run_id}"
proxy_container="proxy-sni-route-sim-proxy-${run_id}"
work_dir="$repo_root/.proxy-sni-route-sim-tmp-${run_id}"

cleanup() {
    local status=$?
    docker rm -f "$backend_root_container" "$backend_sub_container" "$proxy_container" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$proxy_image" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$work_dir/fixture"

# What: Use RFC 2606 reserved domain for test.
# Why: Exercises one-label-past-root SNI routing bug.
printf '%s\n' 'sub.example.com' > "$work_dir/fixture/cdn-domains.txt"

# What: Configure standalone proxy container env.
# Why: Test SNI routing in standard-mode strict passthrough.
proxy_env=(
    -e IP_STANDARD=10.10.10.10
    -e IP_SSL=10.10.10.11
    -e SSL_ENABLED=0
    -e PROXY_SECURITY_MODE=strict
    -e NGINX_UPSTREAM_RESOLVER="127.0.0.11:53"
    -e CACHE_MAX_SIZE=1g
    -e CACHE_MEM_MB=64
    -e CACHE_SLICE_SIZE=1m
    -e CACHE_VALID_HIT=1d
    -e CACHE_VALID_ANY=1m
    -e CACHE_INACTIVE=1d
)

echo "== Generating two distinguishable self-signed backend certs =="
# What: Use build-tools container for cert generation.
# Why: Runners may lack project tools (AG-CI-001).
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 1 -subj '/CN=backend-root' 2>/dev/null" >/dev/null
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout sub.key -out sub.crt -days 1 -subj '/CN=backend-sub' 2>/dev/null" >/dev/null

echo "== Building throwaway proxy image with synthetic cdn-domains.txt fixture (sub.example.com) =="
docker build -q -t "$proxy_image" --build-context "dns-domains=$work_dir/fixture" --build-context "shared-scripts=$repo_root/scripts/lib" services/proxy >/dev/null

docker network create "$network_name" >/dev/null

echo "== Starting fake origin backends (real openssl s_server, one per hostname alias) =="
# What: Start test backend servers with network aliases.
# Why: Test SNI routing between root and subdomain origins.
docker run -d --name "$backend_root_container" --network "$network_name" --network-alias example.com \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/root.crt -key /certs/root.key -naccept 200 -quiet" >/dev/null
docker run -d --name "$backend_sub_container" --network "$network_name" --network-alias sub.example.com \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/sub.crt -key /certs/sub.key -naccept 200 -quiet" >/dev/null

# handshake_cn <target_host> <target_port> <sni>
# What: Perform TLS handshake and return CN of cert.
# Why: Identifies which backend SNI routing reaches.
handshake_cn() {
    local target="$1" port="$2" sni="$3"
    docker run --rm --network "$network_name" "$build_tools_image" bash -c \
        "echo | timeout 10 openssl s_client -connect ${target}:${port} -servername ${sni} 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" || true
}

wait_for_tcp() {
    local container="$1" port="$2"
    local deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then # pipefail-safe: docker inspect --format on one field of one container always emits exactly one line (issue #1377)
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

wait_for_tcp "$backend_root_container" 443
wait_for_tcp "$backend_sub_container" 443

echo "== Sanity check: dialing each fake origin directly returns its own distinct cert =="
root_direct="$(handshake_cn "$backend_root_container" 443 example.com)"
sub_direct="$(handshake_cn "$backend_sub_container" 443 sub.example.com)"
if [[ -z "$root_direct" ]]; then
    echo "::error::Handshake against $backend_root_container directly produced no certificate at all (dead backend / connection refused / -naccept exhausted), not a wrong-CN mismatch. Container logs:" >&2
    docker logs "$backend_root_container" 2>&1 | tail -30 >&2
    exit 1
fi
if [[ "$root_direct" != "subject=CN=backend-root" ]]; then
    echo "::error::Expected backend-root's own cert (CN=backend-root) dialing it directly, got: $root_direct" >&2
    exit 1
fi
if [[ -z "$sub_direct" ]]; then
    echo "::error::Handshake against $backend_sub_container directly produced no certificate at all (dead backend / connection refused / -naccept exhausted), not a wrong-CN mismatch. Container logs:" >&2
    docker logs "$backend_sub_container" 2>&1 | tail -30 >&2
    exit 1
fi
if [[ "$sub_direct" != "subject=CN=backend-sub" ]]; then
    echo "::error::Expected backend-sub's own cert (CN=backend-sub) dialing it directly, got: $sub_direct" >&2
    exit 1
fi
echo "OK: both fake origins present their own distinct, expected certs."

echo "== Starting the real proxy container (strict standard-mode SNI passthrough) =="
docker run -d --name "$proxy_container" --network "$network_name" "${proxy_env[@]}" "$proxy_image" >/dev/null
wait_for_tcp "$proxy_container" 8443

echo "== Verifying the generated stream-target map forwards the registrable-root match to \$ssl_preread_server_name:443, not a hardcoded root literal (issue #1297) =="
stream_map="$(docker exec "$proxy_container" cat /etc/nginx/stream.d/00-stream-targets.conf)"
if ! grep -qE '^\s*\*\.example\.com\s+\$ssl_preread_server_name:443;' <<<"$stream_map"; then
    echo "::error::Expected the *.example.com stream-target map entry to forward to \$ssl_preread_server_name:443 (the actual requested SNI), not to a hardcoded root literal. Generated map:" >&2
    echo "$stream_map" >&2
    exit 1
fi
echo "OK: *.example.com forwards to \$ssl_preread_server_name:443 (the requested SNI), not to example.com:443."

echo "== Real handshake through the proxy's standard-mode listener (:8443) with SNI sub.example.com must reach backend-sub, NOT backend-root (issue #1297's exact bug: drivers.amd.com forwarding to amd.com) =="
routed_cn="$(handshake_cn "$proxy_container" 8443 sub.example.com)"
if [[ -z "$routed_cn" ]]; then
    echo "::error::Handshake through the proxy for SNI 'sub.example.com' produced no certificate at all (dead backend, proxy_pass failure, or a backend's -naccept budget exhausted) -- this is a test-infrastructure failure, NOT evidence either way for the #1297 routing bug. Proxy logs:" >&2
    docker logs "$proxy_container" 2>&1 | tail -30 >&2
    exit 1
fi
if [[ "$routed_cn" != "subject=CN=backend-sub" ]]; then
    echo "::error::Expected the passthrough for SNI 'sub.example.com' to reach backend-sub (CN=backend-sub), but got: $routed_cn -- this is exactly the #1297 registrable-root routing bug (forwarding to the derived root's own backend instead of the requested SNI's real origin)." >&2
    exit 1
fi
echo "OK: SNI 'sub.example.com' correctly routes to backend-sub ($routed_cn), not the registrable root's own backend."

echo "proxy-standard-mode-sni-routing-simulation passed: the strict-mode stream-target map now forwards a matched registrable root to the actual requested SNI, and a real TLS handshake through the standard-mode passthrough listener reaches the correct real origin, not the derived root's own backend."
