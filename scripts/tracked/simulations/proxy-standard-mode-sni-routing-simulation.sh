#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Real TLS-handshake simulation for services/proxy/entrypoint.sh's standard-
# mode (SNI-passthrough) stream-target map generation loop over
# _UNIQUE_DOMAINS (the "$stream_backend" map written to
# stream.d/00-stream-targets.conf). Everything else covering this file's
# map-generation logic (tests/bats/proxy_collect_domain_rows.bats) stops at
# bash-level unit coverage of which domains land in which array -- none of
# it starts a real proxy image, real nginx, or performs a real TLS handshake
# through the generated map, which is exactly where this bug (issue #1297,
# folded into #1276) lived: the map's *values*, not which domains it lists.
#
# The bug: a matched registrable-root wildcard key (e.g. "*.example.com")
# forwarded to "${domain}:443" -- the literal derived root -- instead of
# "$ssl_preread_server_name:443" (the actual requested SNI). A listed
# "sub.example.com" (root "example.com") would forward standard-mode
# passthrough traffic to "example.com:443", not "sub.example.com:443", even
# though DNS correctly spoofed "sub.example.com" to the proxy in the first
# place. This is silent and undetectable from config-generation review alone
# unless the real target host actually serves *different* content than the
# root -- which is exactly what this script proves with two distinguishable
# backends.
#
# Deliberately a standalone script rather than an extension of
# scripts/tracked/simulations/proxy-deep-wildcard-tls-simulation.sh: that script validates
# SSL-mode certificate *selection* (which cert nginx presents for a given
# SNI, terminated by nginx itself). This script validates standard-mode SNI
# *passthrough routing* (which real backend nginx's stream module forwards
# the raw TLS bytes to, with nginx never terminating the connection at all)
# -- a different nginx context (stream's own listener on :8443, not the
# http block's :443) and a different failure mode (wrong destination host,
# not wrong certificate). It also needs two independently-addressable fake
# origins, which the deep-wildcard script's single-image setup has no
# reason to provide.
#
# Fake-origin mechanism: two backend containers on the same throwaway
# Docker network, each given a Docker "--network-alias" equal to the
# hostname under test ("example.com" / "sub.example.com" -- both reserved,
# non-routable per RFC 2606, never the real internet domain). Docker's
# embedded per-network DNS resolver (127.0.0.11, confirmed live on a real
# Debian-based container to resolve a multi-label alias correctly) answers
# for these aliases inside the network; the proxy container's
# NGINX_UPSTREAM_RESOLVER is pointed at that same embedded resolver instead
# of a real public DNS server, so nginx's own dynamic proxy_pass resolution
# reaches our fake origins instead of the real internet -- this mirrors how
# NGINX_UPSTREAM_RESOLVER is a real, documented override point in
# production (see AG-OP-002), just aimed at a throwaway network instead of
# 8.8.8.8. Each backend runs a real "openssl s_server" presenting a
# distinct, self-signed certificate (CN=backend-root / CN=backend-sub) --
# the CN that comes back from a real TLS handshake through the proxy is
# the only reliable, real proof of which backend the passthrough actually
# reached.
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

# Synthetic, non-production, RFC 2606-reserved domain -- never touches the
# real services/dns/cdn-domains.txt. A BARE entry (no leading dot) exactly
# one label past its registrable root ("example.com") is the specific shape
# that exercises the bug: services/proxy/entrypoint.sh's
# _proxy_is_one_label_past excludes it from _EXTRA_EXACT_HOSTS (that array
# is only for a bare entry MORE than one label past root), so its only
# route through the generated map is the _UNIQUE_DOMAINS wildcard/root-exact
# branch this fix targets -- the same branch the issue's own concrete
# example ("drivers.amd.com", root "amd.com") falls into.
printf '%s\n' 'sub.example.com' > "$work_dir/fixture/cdn-domains.txt"

# Minimal but complete env for a standalone (non-Compose) proxy container.
# SSL_ENABLED=0: this bug lives entirely in standard-mode passthrough
# (stream.d/00-stream-targets.conf), generated unconditionally regardless of
# SSL_ENABLED (see entrypoint.sh's own comment on why _bounded_cert_name is
# defined outside the SSL_ENABLED block) -- SSL_ENABLED=0 is the faithful
# fixture for what this script actually tests and avoids needing CA/cert
# generation at all. PROXY_SECURITY_MODE=strict is required: in the default
# lazy mode the map is just "default $ssl_preread_server_name:443" for
# every SNI and this bug cannot exist (there is no per-domain map entry to
# get wrong). NGINX_UPSTREAM_RESOLVER points at Docker's own embedded
# per-network DNS resolver (127.0.0.11:53) instead of a real public
# resolver -- see this script's header comment for why.
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
# Run through $build_tools_image, NOT a bare host "openssl" call -- self-
# hosted runners (and any GitHub-hosted fallback) must be assumed not to
# provide project validation tools at all (AG-CI-001); every other
# openssl/cert operation in this file and its sibling script already goes
# through the container for the same reason.
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 1 -subj '/CN=backend-root' 2>/dev/null" >/dev/null
docker run --rm -v "$work_dir:/certs" -w /certs "$build_tools_image" bash -c \
    "openssl req -x509 -newkey rsa:2048 -nodes -keyout sub.key -out sub.crt -days 1 -subj '/CN=backend-sub' 2>/dev/null" >/dev/null

echo "== Building throwaway proxy image with synthetic cdn-domains.txt fixture (sub.example.com) =="
docker build -q -t "$proxy_image" --build-context "dns-domains=$work_dir/fixture" services/proxy >/dev/null

docker network create "$network_name" >/dev/null

echo "== Starting fake origin backends (real openssl s_server, one per hostname alias) =="
# --network-alias makes each backend independently resolvable within this
# network under the EXACT hostname it fakes being the origin for --
# "example.com" (the registrable root) and "sub.example.com" (the listed
# CDN entry). -naccept bounds how many connections each server answers
# before exiting on its own, rather than running forever as an unreaped
# background process (AG-CI-016). Deliberately generous (200, not a tight
# count matching this script's own handful of real handshakes): every
# wait_for_tcp() /dev/tcp probe below against a backend ALSO consumes one
# -naccept slot (a raw TCP connect is still an "accept" to s_server, even
# though no TLS data follows), and a slow-starting backend on a loaded
# runner can burn through several retries before the container is even
# reachable -- a too-tight -naccept could exhaust itself on startup probing
# alone and make the real handshake later fail with "no certificate at
# all", which would misleadingly look like a #1297 regression rather than
# what it actually is (a test-harness budget, not a proxy bug).
docker run -d --name "$backend_root_container" --network "$network_name" --network-alias example.com \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/root.crt -key /certs/root.key -naccept 200 -quiet" >/dev/null
docker run -d --name "$backend_sub_container" --network "$network_name" --network-alias sub.example.com \
    -v "$work_dir:/certs:ro" "$build_tools_image" bash -c \
    "openssl s_server -accept 443 -cert /certs/sub.crt -key /certs/sub.key -naccept 200 -quiet" >/dev/null

# handshake_cn <target_host> <target_port> <sni>
# Performs a real TLS handshake from a build-tools client container against
# <target_host>:<target_port> with SNI <sni> and prints the CN of whatever
# certificate actually comes back, or an empty string if the handshake or
# certificate parse failed for any reason (dead backend, connection
# refused, no cert returned). Deliberately does NOT use
# -verify_hostname/-CAfile (unlike the sibling deep-wildcard script): both
# backend certs here are self-signed and untrusted on purpose -- the CN
# itself is the only signal this script needs, since it identifies which
# real backend the passthrough connection actually reached.
#
# The trailing "|| true" is required, not decorative: under this script's
# own "set -e", a bare "var=\"\$(handshake_cn ...)\"" assignment aborts the
# whole script immediately if "openssl x509" exits non-zero (e.g. because
# "openssl s_client" produced no certificate at all) -- silently, with none
# of this script's own ::error:: messages ever printed, since errexit fires
# before the caller gets a chance to inspect the result. Every call site
# below checks for an empty return explicitly instead, so a dead-backend
# failure and an actual #1297-style wrong-backend failure produce two
# distinguishable, readable error messages rather than one indistinguishable
# silent abort.
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
