#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DNS/HTTP/HTTPS caching test against a genuinely fetchable target
# (issue #597, part of #557 scenario 1). Game CDN domains in the real
# cdn-domains.txt need signed/session URLs and won't serve a plain curl
# request, so this test adds a Debian mirror hostname to a test-only copy
# of that domain list and builds throwaway dns/proxy images from it --
# cdn-domains.txt is COPY-ed into both images at build time (see
# services/dns/Dockerfile, services/proxy/Dockerfile), there is no runtime
# override. Reuses deploy/full-setup/docker-compose.yml for everything else
# (NATS, networking, healthchecks already proven there) via an image-only
# override file. Meant to run inside the build-tools container against the
# mounted Docker socket, same pattern as scripts/setup-cli-simulation.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
git config --global --add safe.directory "$repo_root"

test_domain="deb.debian.org"
test_path="/debian/README"
run_id="mitm-sim-$$"
work_dir="$repo_root/.ssl-mitm-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

compose_project="lancache-ng-validation"
network_name="${compose_project}_validation"
proxy_ip="172.30.99.2"
dns_standard_ip="172.30.99.3"
dns_ssl_ip="172.30.99.5"

cleanup() {
    local status=$?
    docker compose -p "$compose_project" \
        -f deploy/full-setup/docker-compose.yml -f "$work_dir/image-override.yml" \
        down -v --remove-orphans >/dev/null 2>&1 || true
    docker rmi "lancache-ng-mitm-sim-dns:$run_id" "lancache-ng-mitm-sim-proxy:$run_id" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Building test-scoped dns/proxy images with $test_domain added =="

dns_context="$work_dir/dns-context"
cp -a services/dns "$dns_context"
printf '\n# Added by scripts/ssl-mitm-cache-simulation.sh for issue #597 -- not a real CDN domain, never committed.\n%s\n' \
    "$test_domain" >> "$dns_context/cdn-domains.txt"

# Plain `docker build` uses the legacy builder, which does not understand
# the dns Dockerfile's `RUN --mount=type=secret` lines (BuildKit-only) --
# confirmed directly: "the --mount option requires BuildKit". buildx is
# already set up on this runner (used elsewhere in this project's CI, e.g.
# the container-scan job); --load makes the result available to `docker
# run`/`docker compose` afterward, same as a normal build.
docker buildx build --load --pull -q \
    --build-arg "BUILD_TOOLS_IMAGE=${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
    -t "lancache-ng-mitm-sim-dns:$run_id" \
    "$dns_context" >/dev/null

docker buildx build --load --pull -q \
    --build-context "dns-domains=$dns_context" \
    -t "lancache-ng-mitm-sim-proxy:$run_id" \
    services/proxy >/dev/null

cat > "$work_dir/image-override.yml" <<EOF
services:
  proxy:
    image: lancache-ng-mitm-sim-proxy:$run_id
  dns-standard:
    image: lancache-ng-mitm-sim-dns:$run_id
  dns-ssl:
    image: lancache-ng-mitm-sim-dns:$run_id
EOF

echo "== Starting the full-setup stack with the test images =="

docker compose -p "$compose_project" \
    -f deploy/full-setup/docker-compose.yml -f "$work_dir/image-override.yml" \
    up -d proxy dns-standard dns-ssl nats

# Mirrors the health-wait pattern already proven in full-setup-validate.yml
# and scripts/setup-cli-simulation.sh.
compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml -f "$work_dir/image-override.yml")
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
echo "proxy, dns-standard, and dns-ssl are healthy with the test images."

proxy_cid="$("${compose[@]}" ps -q proxy)"
docker cp "$proxy_cid:/etc/nginx/ssl/ca/ca.crt" "$work_dir/ca.crt"

run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/ca.crt:/ca.crt:ro" \
        "$BUILD_TOOLS_IMAGE" bash -c "$1"
}

echo "== DNS: verifying $test_domain resolves to the proxy on both dns-standard and dns-ssl =="

for label_ip in "dns-standard:$dns_standard_ip" "dns-ssl:$dns_ssl_ip"; do
    label="${label_ip%%:*}"
    ip="${label_ip##*:}"
    resolved="$(run_client "dig +time=3 +tries=2 +short @$ip A $test_domain")"
    if [[ "$resolved" != "$proxy_ip" ]]; then
        echo "::error::$label resolved $test_domain to '$resolved', expected $proxy_ip." >&2
        exit 1
    fi
    echo "$label correctly resolves $test_domain to the proxy."
done

echo "== Standard mode: HTTP MISS then HIT for a real file =="

http_status_1="$(run_client "curl -sS -o /tmp/body1 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$http_status_1" \
    || { echo "::error::First standard-mode HTTP request was not a MISS." >&2; echo "$http_status_1" >&2; exit 1; }

http_status_2="$(run_client "curl -sS -o /tmp/body2 -D - -H 'Host: $test_domain' 'http://$proxy_ip$test_path'")"
grep -qi '^X-Cache-Status: HIT' <<<"$http_status_2" \
    || { echo "::error::Second standard-mode HTTP request was not a HIT." >&2; echo "$http_status_2" >&2; exit 1; }

run_client "cmp -s /tmp/body1 /tmp/body2" \
    || { echo "::error::Standard-mode MISS and HIT responses had different bodies." >&2; exit 1; }
run_client "[ -s /tmp/body1 ]" \
    || { echo "::error::Standard-mode response body was empty." >&2; exit 1; }
echo "Standard mode: MISS then HIT confirmed, with identical real file content on both requests."

echo "== SSL mode: HTTPS MITM MISS then HIT for the same real file =="

https_status_1="$(run_client "curl -sS --resolve $test_domain:443:$proxy_ip --cacert /ca.crt -o /tmp/sbody1 -D - 'https://$test_domain$test_path'")"
grep -qi '^X-Cache-Status: MISS' <<<"$https_status_1" \
    || { echo "::error::First SSL-mode HTTPS request was not a MISS." >&2; echo "$https_status_1" >&2; exit 1; }

https_status_2="$(run_client "curl -sS --resolve $test_domain:443:$proxy_ip --cacert /ca.crt -o /tmp/sbody2 -D - 'https://$test_domain$test_path'")"
grep -qi '^X-Cache-Status: HIT' <<<"$https_status_2" \
    || { echo "::error::Second SSL-mode HTTPS request was not a HIT." >&2; echo "$https_status_2" >&2; exit 1; }

run_client "cmp -s /tmp/sbody1 /tmp/sbody2" \
    || { echo "::error::SSL-mode MISS and HIT responses had different bodies." >&2; exit 1; }
run_client "cmp -s /tmp/body1 /tmp/sbody1" \
    || { echo "::error::Standard-mode and SSL-mode responses had different content for the same file." >&2; exit 1; }
echo "SSL mode: MITM MISS then HIT confirmed -- the proxy decrypted, cached, and re-served the real file over HTTPS using our own CA."

echo "ssl-mitm-cache-simulation passed: DNS redirect, standard-mode HTTP caching, and SSL-mode MITM caching all verified against a real, fetchable file."
