#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DNS/HTTP/HTTPS caching test against a genuinely fetchable target
# (issue #597, part of #557 scenario 1). Game CDN domains in cdn-domains.txt
# mostly need signed/session URLs and won't serve a plain curl request --
# but this project already caches Linux distro mirrors too (see the
# "Debian"/"Fedora"/etc. sections of services/dns/cdn-domains.txt), and
# deb.debian.org is one of them. That means this test needs no custom-built
# images at all: it uses the real, already-published dns/proxy images
# (matching the LANCACHE_IMAGE_CHANNEL default full-setup-validate.yml uses)
# and reuses deploy/full-setup/docker-compose.yml as-is for everything
# (NATS, networking, healthchecks already proven there).
#
# (An earlier version of this script built throwaway images with a domain
# appended to a test-only cdn-domains.txt copy, before noticing
# deb.debian.org was already a real entry -- that approach also hit a
# missing-buildx-plugin gap in the build-tools image. Not needed now, but
# worth remembering if a *different* test domain is ever needed here: that
# file is baked into the dns/proxy images at build time, no runtime
# override exists.)
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

test_domain="deb.debian.org"
test_path="/debian/README"
# A second, distinct real path on the same host for the SSL-mode leg: the
# cache key is $host$uri (see CLAUDE.md), shared between HTTP and HTTPS on
# the same proxy container, so reusing test_path here found it already
# cached by the standard-mode test above and reported HIT on its supposedly
# fresh first request -- confirmed directly. A different path guarantees an
# independent, genuinely fresh cache entry for this leg.
ssl_test_path="/debian/dists/stable/Release"
work_dir="$repo_root/.ssl-mitm-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
proxy_ip="172.30.99.2"
dns_standard_ip="172.30.99.3"
dns_ssl_ip="172.30.99.5"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"

cleanup() {
    local status=$?
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
        down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Starting proxy/dns-standard/dns-ssl/nats from the published $image_tag images =="

LANCACHE_IMAGE_TAG="$image_tag" \
    docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml \
    up -d proxy dns-standard dns-ssl nats

# Mirrors the health-wait pattern already proven in full-setup-validate.yml
# and scripts/setup-cli-simulation.sh.
compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy dns-standard dns-ssl; do
        cid="$("${compose[@]}" ps -q "$service")"
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy dns-standard dns-ssl; do
    cid="$("${compose[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy, dns-standard, and dns-ssl are healthy."

proxy_cid="$("${compose[@]}" ps -q proxy)"
docker cp "$proxy_cid:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca.crt"

# Each call is a brand new --rm container, so /tmp inside it never survives
# past that one call -- confirmed directly: comparing files written by two
# separate run_client calls always "failed" because neither file existed in
# either of the (also separate) containers doing the comparing. /shared is
# bind-mounted from work_dir (a real, persistent host directory) so files
# written by one call are actually still there for a later call, and so
# cmp/test below can run directly on the host instead of needing yet
# another container.
mkdir -p "$work_dir/shared"
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/ca.crt:/ca.crt:ro" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

# Both dns-standard and dns-ssl are asserted against the SAME $proxy_ip here
# (issue #668). This intentionally does not mirror prod's DNS answers: prod's
# config/prod/dns-standard.env and dns-ssl.env point at two genuinely
# different LAN addresses (IP_STANDARD, IP_SSL), because prod's single proxy
# container is reachable at two separate host NIC IPs, each Docker-port-
# published to a different container port (IP_STANDARD:443 -> container
# 8443, the SNI-passthrough stream listener; IP_SSL:443 -> container 443,
# the TLS-interception listener; see services/proxy/entrypoint.sh's "Docker
# routes IP_SSL:443->container:443 and IP_STANDARD:443->container:8443"
# comment). That host-IP-scoped port-publish translation only applies to
# traffic entering through the Docker host's published ports -- it has no
# effect on this validation harness's containers, which all talk to the
# proxy directly over the `validation` bridge network and therefore always
# reach its real listening ports (80, 443, 8443) regardless of which address
# they dialed. nginx itself listens on 0.0.0.0 for all three and does not
# branch on destination IP, so giving the proxy container a second bridge
# address here would not exercise any additional code path -- it would just
# be a second name for the same listener. This DNS check can therefore pass
# even if dns-ssl's PROXY_IP were wrongly wired to the standard-mode
# address, and the HTTPS leg below only exercises the TLS-interception
# listener (container port 443), never the SNI-passthrough listener
# (container port 8443) that prod's IP_STANDARD:443 forwards to. Faithfully
# distinguishing the two would require reproducing prod's host-level
# secondary-IP port-publish setup rather than plain container-to-container
# bridge traffic, which is out of scope for this lightweight harness. See
# https://github.com/wiki-mod/lancache-ng/issues/668 for the full
# discussion.
echo "== DNS: verifying $test_domain resolves to the proxy on both dns-standard and dns-ssl =="

for label_ip in "dns-standard:$dns_standard_ip" "dns-ssl:$dns_ssl_ip"; do
    label="${label_ip%%:*}"
    ip="${label_ip##*:}"
    # sort -u: PowerDNS RPZ answered this domain with the same A record on
    # two lines during development (see the earlier duplicate-domain note
    # above) -- tolerate a duplicate answer rather than assuming exactly
    # one line, since the substantive check is "every answer is the proxy",
    # not "there is exactly one answer".
    resolved="$(run_client "dig +time=3 +tries=2 +short @$ip A $test_domain" | sort -u)"
    if [[ "$resolved" != "$proxy_ip" ]]; then
        echo "::error::$label resolved $test_domain to '$resolved', expected only $proxy_ip." >&2
        exit 1
    fi
    echo "$label correctly resolves $test_domain to the proxy."
done

echo "== Standard mode: HTTP MISS then HIT for a real file =="

http_status_1="$(run_client "curl -sS -o /shared/body1 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request was not a MISS." >&2; echo "$http_status_1" >&2; exit 1; }

http_status_2="$(run_client "curl -sS -o /shared/body2 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
grep -qi '^X-Cache-Status: HIT' <<<"$http_status_2" \
    || { echo "::error::Second standard-mode HTTP request was not a HIT." >&2; echo "$http_status_2" >&2; exit 1; }

cmp -s "$work_dir/shared/body1" "$work_dir/shared/body2" \
    || { echo "::error::Standard-mode MISS and HIT responses had different bodies." >&2; exit 1; }
[[ -s "$work_dir/shared/body1" ]] \
    || { echo "::error::Standard-mode response body was empty." >&2; exit 1; }
echo "Standard mode: MISS then HIT confirmed, with identical real file content on both requests."

echo "== SSL mode: HTTPS MITM MISS then HIT for a real file =="

https_status_1="$(run_client "curl -sS --resolve $test_domain:443:$proxy_ip --cacert /ca.crt -o /shared/sbody1 -D - 'https://$test_domain$ssl_test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request was not a MISS." >&2; echo "$https_status_1" >&2; exit 1; }

https_status_2="$(run_client "curl -sS --resolve $test_domain:443:$proxy_ip --cacert /ca.crt -o /shared/sbody2 -D - 'https://$test_domain$ssl_test_path'")"
grep -qi '^X-Cache-Status: HIT' <<<"$https_status_2" \
    || { echo "::error::Second SSL-mode HTTPS request was not a HIT." >&2; echo "$https_status_2" >&2; exit 1; }

cmp -s "$work_dir/shared/sbody1" "$work_dir/shared/sbody2" \
    || { echo "::error::SSL-mode MISS and HIT responses had different bodies." >&2; exit 1; }
[[ -s "$work_dir/shared/sbody1" ]] \
    || { echo "::error::SSL-mode response body was empty." >&2; exit 1; }
echo "SSL mode: MITM MISS then HIT confirmed -- the proxy decrypted, cached, and re-served a real file over HTTPS using our own CA."

echo "ssl-mitm-cache-simulation passed: DNS redirect, standard-mode HTTP caching, and SSL-mode MITM caching all verified against a real, fetchable file."
