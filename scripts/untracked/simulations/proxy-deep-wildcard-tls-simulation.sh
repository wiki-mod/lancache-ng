#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Test deep wildcard cert TLS handshake.
# Why: Runtime-only failures not covered by unit tests.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# What: Unique ID per invocation: timestamp + PID.
# Why: Avoids collisions on concurrent runs on shared host.
run_id="$(date +%s)-$$"
network_name="proxy-deep-wc-sim-${run_id}"
image_a="proxy-deep-wc-sim:fixture-a-${run_id}"
image_b="proxy-deep-wc-sim:fixture-b-${run_id}"
container_a="proxy-deep-wc-sim-a-${run_id}"
container_b="proxy-deep-wc-sim-b-${run_id}"
work_dir="$repo_root/.proxy-deep-wc-sim-tmp-${run_id}"

cleanup() {
    local status=$?
    docker rm -f "$container_a" "$container_b" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$image_a" "$image_b" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$work_dir/fixture-a" "$work_dir/fixture-b"

# What: Create synthetic domain fixtures for test.
# Why: Test deep wildcard; don't affect real domains.
printf '%s\n' '.deep.example.com' > "$work_dir/fixture-a/cdn-domains.txt"
printf '%s\n%s\n' '.deep.example.com' '.b.deep.example.com' > "$work_dir/fixture-b/cdn-domains.txt"

# What: Set up standalone proxy env variables.
# Why: Placeholders only; never serve real traffic.
proxy_env=(
    -e IP_STANDARD=10.10.10.10
    -e IP_SSL=10.10.10.11
    -e SSL_ENABLED=1
    -e PROXY_SECURITY_MODE=strict
    -e NGINX_UPSTREAM_RESOLVER="8.8.8.8 8.8.4.4"
    -e CACHE_MAX_SIZE=1g
    -e CACHE_MEM_MB=64
    -e CACHE_SLICE_SIZE=1m
    -e CACHE_VALID_HIT=1d
    -e CACHE_VALID_ANY=1m
    -e CACHE_INACTIVE=1d
)

echo "== Building throwaway proxy images with synthetic cdn-domains.txt fixtures =="
docker build -q -t "$image_a" --build-context "dns-domains=$work_dir/fixture-a" --build-context "shared-scripts=$repo_root/scripts/lib" services/proxy >/dev/null
docker build -q -t "$image_b" --build-context "dns-domains=$work_dir/fixture-b" --build-context "shared-scripts=$repo_root/scripts/lib" services/proxy >/dev/null

docker network create "$network_name" >/dev/null

# What: Run TLS handshake with hostname verify.
# Why: Check both cert chain AND SAN match SNI.
handshake() {
    local container="$1" sni="$2" expect="$3" ca_path="$4"
    local out
    out="$(docker run --rm --network "$network_name" \
        -v "$ca_path:/ca.crt:ro" \
        "$build_tools_image" bash -c \
        "timeout 10 openssl s_client -connect ${container}:443 -servername ${sni} -CAfile /ca.crt -verify_hostname ${sni} -verify_return_error < /dev/null 2>&1" || true)"

    if [[ "$expect" != "ok" ]]; then
        echo "::error::handshake() only supports expect=ok now -- see dispatch_routes_to_passthrough() for the depth>1 case." >&2
        return 1
    fi
    if ! grep -q '^Verify return code: 0 (ok)' <<<"$out"; then
        echo "::error::Expected a successful, hostname-verified TLS handshake for SNI '$sni' against $container, but it did not succeed. Full openssl output:" >&2
        echo "$out" >&2
        return 1
    fi
    echo "OK: SNI '$sni' against $container handshakes and verifies cleanly (chain + hostname)."
}

# What: Check SNI routes to passthrough relay.
# Why: Depth>1 SNI no longer reaches MITM cert path.
dispatch_routes_to_passthrough() {
    local container="$1" sni="$2"
    local map
    map="$(docker exec "$container" cat /etc/nginx/stream.d/01-ssl-dispatch.conf)"
    local matched_port=""
    # What: Use default IFS for two-field reads.
    # Why: IFS="" would leave port empty on read.
    while read -r pattern port; do
        [[ -z "$pattern" ]] && continue
        # What: Strip quoting/anchoring from pattern.
        # Why: Convert to plain grep -P regex for matching.
        local bare="${pattern#\"}"
        bare="${bare%\"}"
        bare="${bare#\~}"
        # What: Use here-string instead of pipe.
        # Why: Avoid producer/consumer SIGPIPE early exit.
        if grep -Pq "$bare" <<<"$sni"; then
            matched_port="$port"
            break
        fi
    done < <(grep -oE '"[^"]+"[[:space:]]+127\.0\.0\.1:[0-9]+' <<<"$map" | sed -E 's/^"([^"]+)"[[:space:]]+127\.0\.0\.1:([0-9]+)/\1 \2/')

    if [[ "$matched_port" != "9446" ]]; then
        echo "::error::Expected SNI '$sni' to route to the passthrough relay (127.0.0.1:9446) in the generated dispatch map, but matched port '${matched_port:-<none>}'. Full map:" >&2
        echo "$map" >&2
        return 1
    fi
    echo "OK: SNI '$sni' routes to the passthrough relay (127.0.0.1:9446) in the generated dispatch map."
}

# What: Poll until TLS port reachable.
# Why: Cert gen/nginx startup may be slow.
wait_for_tls() {
    local container="$1"
    local deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then # pipefail-safe: docker inspect --format on one field of one container always emits exactly one line
            echo "::error::$container is not running (crashed during startup). Logs:" >&2
            docker logs "$container" 2>&1 | tail -60 >&2
            return 1
        fi
        if docker run --rm --network "$network_name" "$build_tools_image" \
            bash -c "timeout 3 bash -c '</dev/tcp/${container}/443'" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "::error::$container never became reachable on :443 within 60s. Logs:" >&2
    docker logs "$container" 2>&1 | tail -60 >&2
    return 1
}

echo "== Starting proxy container with fixture-a (single depth-1 leading-dot entry) =="
docker run -d --name "$container_a" --network "$network_name" "${proxy_env[@]}" "$image_a" >/dev/null
wait_for_tls "$container_a"
docker cp "$container_a:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca-a.crt"

echo "== Verifying the stream-target map forwards the extra wildcard base to the requested SNI, not the base itself (finding: strict-mode wildcard-base routing) =="
stream_map="$(docker exec "$container_a" cat /etc/nginx/stream.d/00-stream-targets.conf)"
if ! grep -qE '^\s*\*\.deep\.example\.com\s+\$ssl_preread_server_name:443;' <<<"$stream_map"; then
    echo "::error::Expected the *.deep.example.com stream-target map entry to forward to \$ssl_preread_server_name:443 (the actual requested SNI), not to the wildcard base's own name. Generated map:" >&2
    echo "$stream_map" >&2
    exit 1
fi
echo "OK: *.deep.example.com forwards to \$ssl_preread_server_name:443 (the requested SNI), not to deep.example.com:443."

echo "== Verifying the deep wildcard cert's CN is the fixed placeholder, not the real hostname (finding: CN-length startup crash) =="
default_subject="$(docker run --rm --network "$network_name" \
    -v "$work_dir/ca-a.crt:/ca.crt:ro" "$build_tools_image" bash -c \
    "timeout 10 openssl s_client -connect ${container_a}:443 -servername x.deep.example.com < /dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null")"
if [[ "$default_subject" != "subject=CN=lancache-ng" ]]; then
    echo "::error::Expected the deep wildcard cert's subject to be the fixed placeholder 'CN=lancache-ng', got: $default_subject" >&2
    exit 1
fi
echo "OK: deep wildcard cert subject is the fixed placeholder ($default_subject), not the real (potentially >64-byte) hostname."

echo "== depth-1 SNI (one label below the leading-dot entry) must handshake and verify cleanly =="
handshake "$container_a" "x.deep.example.com" "ok" "$work_dir/ca-a.crt"

echo "== depth-2 SNI (two labels below the leading-dot entry) is routed to the passthrough relay, not this MITM cert path (fixed connectivity gap, #1276/#1322 -- previously reached this path anyway with a mismatched cert) =="
dispatch_routes_to_passthrough "$container_a" "a.b.deep.example.com"

docker rm -f "$container_a" >/dev/null 2>&1

echo "== Starting proxy container with fixture-b (adds the specific deeper entry .b.deep.example.com) =="
docker run -d --name "$container_b" --network "$network_name" "${proxy_env[@]}" "$image_b" >/dev/null
wait_for_tls "$container_b"
docker cp "$container_b:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca-b.crt"

echo "== depth-2 SNI now succeeds once the operator lists that specific deeper level explicitly (the real, working mitigation path) =="
handshake "$container_b" "a.b.deep.example.com" "ok" "$work_dir/ca-b.crt"

echo "== depth-3 SNI is routed to the passthrough relay -- confirms the single-label X.509 wildcard limitation (RFC 6125) is inherent and not something one extra cdn-domains.txt entry permanently closes, but also confirms it no longer breaks the connection outright (#1276/#1322) =="
dispatch_routes_to_passthrough "$container_b" "c.a.b.deep.example.com"

echo "proxy-deep-wildcard-tls-simulation passed: strict-mode wildcard-base routing, fixed placeholder CN, real depth-1 TLS handshakes through the generated cert-selection map (including the per-entry mitigation path), and correct passthrough-relay dispatch for every depth beyond what a static cert can cover -- all verified against a real proxy image and real nginx."
