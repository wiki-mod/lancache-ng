#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real TLS-handshake simulation for services/proxy/entrypoint.sh's deep
# leading-dot wildcard cert path (_collect_domain_rows' _EXTRA_WILDCARD_BASES/
# _bounded_cert_name/_sign_cert machinery). Everything else covering this
# path (tests/bats/proxy_collect_domain_rows.bats,
# tests/bats/proxy_sign_cert.bats) stops at bash-level unit coverage of the
# collection/naming/signing logic in isolation -- none of it ever builds a
# real proxy image, starts real nginx, or performs a real TLS handshake
# through the generated cert-selection map. That gap matters here
# specifically because the failure modes this path guards against are all
# runtime-only: an nginx map that selects the wrong cert, a cert whose SAN
# doesn't validate for the SNI it was meant to cover, or a startup crash from
# an over-length CN/filename -- none of which a stubbed bash function call
# can reproduce.
#
# Deliberately a standalone script rather than an extension of
# scripts/ssl-mitm-cache-simulation.sh: that script intentionally never
# builds a custom image (it pulls the real published proxy/dns images and
# relies on a CDN hostname -- deb.debian.org -- already baked into
# services/dns/cdn-domains.txt at image-build time, see its own header
# comment for why an earlier custom-build attempt was abandoned). This
# path needs specific, synthetic multi-label domains that do NOT exist in
# the real cdn-domains.txt, so it needs its own locally-built proxy image
# using a throwaway cdn-domains.txt via the "dns-domains" named build
# context (see services/proxy/Dockerfile's own comment on that context).
# It also does not need the full docker-compose stack (DNS/NATS/UI) at all:
# a TLS handshake against the proxy's own :443 listener needs nothing but
# the proxy container itself.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

# Unique per-invocation suffix for every Docker resource this script creates
# (network, images, containers) -- avoids name collisions with a concurrent
# run of this same script on a shared self-hosted runner host. $$ (this
# script's own PID) is combined with the current time so two runs started in
# the same second by two different wrapper processes still can't collide.
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

# Synthetic, non-production domains rooted at "example.com" (IANA-reserved
# for documentation/testing, RFC 2606) -- never touches the real
# services/dns/cdn-domains.txt, so this can't accidentally affect real CDN
# coverage or collide with a real operator's domain list.
#
# fixture-a: only the depth-1 leading-dot entry. Exercises the base case
# (_EXTRA_WILDCARD_BASES' "*.deep.example.com" cert, one label of coverage)
# and the documented residual gap one level deeper (any SNI two labels below
# "deep.example.com", e.g. "a.b.deep.example.com", cannot validate against a
# single-label X.509 wildcard SAN -- RFC 6125 -- even though nginx's own
# "hostnames" map matching selects that cert for it regardless of depth).
printf '%s\n' '.deep.example.com' > "$work_dir/fixture-a/cdn-domains.txt"
# fixture-b: the SAME base entry, plus the mitigation an operator can apply
# today for a SPECIFIC deeper subdomain that actually needs coverage: list
# that one extra level explicitly. nginx's hostnames map picks the more
# specific of two matching wildcard keys (see entrypoint.sh's own comment on
# the map-generation loop), so once ".b.deep.example.com" is also listed,
# "a.b.deep.example.com" resolves to ITS cert instead of the shallower one.
printf '%s\n%s\n' '.deep.example.com' '.b.deep.example.com' > "$work_dir/fixture-b/cdn-domains.txt"

# Minimal but complete env for a standalone (non-Compose) proxy container --
# matches config/prod/proxy.env's defaults, scaled down since this never
# serves real traffic. IP_STANDARD/IP_SSL are placeholders (only used for
# the default cert's SAN and startup validation, never dialed here).
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
docker build -q -t "$image_a" --build-context "dns-domains=$work_dir/fixture-a" services/proxy >/dev/null
docker build -q -t "$image_b" --build-context "dns-domains=$work_dir/fixture-b" services/proxy >/dev/null

docker network create "$network_name" >/dev/null

# handshake <container> <sni> <expect: ok|mismatch>
# Runs a real TLS handshake from a build-tools client container against
# <container>:443 with SNI <sni>, verifying the presented cert chains to
# that proxy's own CA AND that <sni> itself validates against the
# presented cert's SAN (via -verify_hostname, which openssl's plain chain
# verification does NOT check on its own -- a cert can chain-verify fine
# while still not covering the requested hostname at all). Fails loudly
# (non-zero exit, printing what actually happened) if the observed result
# doesn't match <expect>.
handshake() {
    local container="$1" sni="$2" expect="$3" ca_path="$4"
    local out
    out="$(docker run --rm --network "$network_name" \
        -v "$ca_path:/ca.crt:ro" \
        "$build_tools_image" bash -c \
        "timeout 10 openssl s_client -connect ${container}:443 -servername ${sni} -CAfile /ca.crt -verify_hostname ${sni} -verify_return_error < /dev/null 2>&1" || true)"

    if [[ "$expect" == "ok" ]]; then
        if ! grep -q '^Verify return code: 0 (ok)' <<<"$out"; then
            echo "::error::Expected a successful, hostname-verified TLS handshake for SNI '$sni' against $container, but it did not succeed. Full openssl output:" >&2
            echo "$out" >&2
            return 1
        fi
        echo "OK: SNI '$sni' against $container handshakes and verifies cleanly (chain + hostname)."
    else
        if ! grep -q 'hostname mismatch' <<<"$out"; then
            echo "::error::Expected SNI '$sni' against $container to fail with a hostname mismatch (documenting the known single-label wildcard SAN limitation), but it did not. Full openssl output:" >&2
            echo "$out" >&2
            return 1
        fi
        echo "EXPECTED MISMATCH: SNI '$sni' against $container correctly fails hostname verification (RFC 6125 single-label wildcard SAN limitation)."
    fi
}

# wait_for_tls <container>
# nginx's proxy Dockerfile has no built-in HEALTHCHECK for a standalone
# (non-Compose) run -- retries the handshake itself rather than requiring a
# separate readiness probe, so a slow cert-generation/nginx-start window on a
# loaded runner doesn't produce a spurious failure.
wait_for_tls() {
    local container="$1"
    local deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
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

echo "== depth-2 SNI (two labels below the leading-dot entry) must currently fail hostname verification (documented RFC 6125 limitation, not a bug this PR introduces) =="
handshake "$container_a" "a.b.deep.example.com" "mismatch" "$work_dir/ca-a.crt"

docker rm -f "$container_a" >/dev/null 2>&1

echo "== Starting proxy container with fixture-b (adds the specific deeper entry .b.deep.example.com) =="
docker run -d --name "$container_b" --network "$network_name" "${proxy_env[@]}" "$image_b" >/dev/null
wait_for_tls "$container_b"
docker cp "$container_b:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca-b.crt"

echo "== depth-2 SNI now succeeds once the operator lists that specific deeper level explicitly (the real, working mitigation path) =="
handshake "$container_b" "a.b.deep.example.com" "ok" "$work_dir/ca-b.crt"

echo "== depth-3 SNI still fails -- confirms the limitation is inherent to single-label X.509 wildcard matching (RFC 6125), not something one extra cdn-domains.txt entry permanently closes =="
handshake "$container_b" "c.a.b.deep.example.com" "mismatch" "$work_dir/ca-b.crt"

echo "proxy-deep-wildcard-tls-simulation passed: strict-mode wildcard-base routing, fixed placeholder CN, real depth-1 TLS handshake through the generated cert-selection map, and the documented depth>1 limitation (and its working per-entry mitigation) all verified against a real proxy image and real nginx."
