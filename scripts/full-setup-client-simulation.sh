#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Full-setup client simulation: runs a real client container on the validation
# network and verifies client-facing DNS/HTTP behavior after Compose health
# checks pass. This intentionally uses the project build-tools image for dig
# and curl instead of incidental host tools.

set -euo pipefail

compose_file="${FULL_SETUP_COMPOSE_FILE:-deploy/full-setup/docker-compose.yml}"
client_tools_image="${FULL_SETUP_CLIENT_TOOLS_IMAGE:-ghcr.io/wiki-mod/lancache-ng/build-tools:latest}"
domain_file="${FULL_SETUP_DOMAIN_FILE:-services/dns/cdn-domains.txt}"
client_domain="${FULL_SETUP_CLIENT_DOMAIN:-}"
proxy_ip="${VALIDATION_PROXY_IP:-172.30.99.2}"
dns_standard_ip="${VALIDATION_DNS_STANDARD_IP:-172.30.99.3}"
dns_ssl_ip="${VALIDATION_DNS_SSL_IP:-172.30.99.5}"
# Must track deploy/full-setup/docker-compose.yml's dns-standard PROXY_IP
# default exactly (issue #668): this job never threads a real per-run
# VALIDATION_STANDARD_SHIM_IP (the standard-passthrough-shim service it
# names is Compose-profile-gated and only started by
# scripts/ssl-mitm-cache-simulation.sh's own `docker compose up` call), so
# dns-standard here always answers with this literal default -- this
# variable just has to agree with that default, not resolve to anything
# actually reachable in THIS job's stack.
standard_shim_ip="${VALIDATION_STANDARD_SHIM_IP:-172.30.99.10}"

if [[ -z "$client_domain" ]]; then
    client_domain="$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "$domain_file")"
fi

[[ -n "$client_domain" ]] \
    || { echo "::error::Could not select a client simulation CDN domain from $domain_file."; exit 1; }

dns_container="$(docker compose -f "$compose_file" ps -q dns-standard)"
[[ -n "$dns_container" ]] \
    || { echo "::error::dns-standard is not running in the full-setup validation stack."; exit 1; }

mapfile -t validation_networks < <(
    docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$dns_container"
)
validation_network=""
for network in "${validation_networks[@]}"; do
    if [[ "$network" == *_validation ]]; then
        validation_network="$network"
        break
    fi
done
validation_network="${validation_network:-${validation_networks[0]:-}}"
[[ -n "$validation_network" ]] \
    || { echo "::error::Could not determine the validation Docker network for dns-standard."; exit 1; }

docker pull "$client_tools_image" >/dev/null

docker run --rm \
    --network "$validation_network" \
    -e FULL_SETUP_CLIENT_DOMAIN="$client_domain" \
    -e VALIDATION_PROXY_IP="$proxy_ip" \
    -e VALIDATION_DNS_STANDARD_IP="$dns_standard_ip" \
    -e VALIDATION_DNS_SSL_IP="$dns_ssl_ip" \
    -e VALIDATION_STANDARD_SHIM_IP="$standard_shim_ip" \
    "$client_tools_image" \
    bash -ceu '
        domain="${FULL_SETUP_CLIENT_DOMAIN:?}"
        proxy_ip="${VALIDATION_PROXY_IP:?}"
        standard_shim_ip="${VALIDATION_STANDARD_SHIM_IP:?}"

        check_dns() {
            local label="$1" server_ip="$2" expected_ip="$3" response
            response="$(dig +time=3 +tries=2 +short @"$server_ip" A "$domain" | awk "NF { print }" | sort -u)"
            printf "%s DNS response for %s: %s\n" "$label" "$domain" "${response:-<empty>}"
            if ! printf "%s\n" "$response" | grep -Fx "$expected_ip" >/dev/null; then
                echo "::error::$label DNS did not resolve $domain to expected IP $expected_ip."
                exit 1
            fi
        }

        # dns-ssl resolves to the proxy container own address (the
        # interception listener, proxy:443) -- unchanged. dns-standard now
        # resolves to the standard-passthrough-shim address instead (issue
        # #668): a real, separate endpoint whose port 443 forwards to the
        # proxy SNI-passthrough listener (proxy:8443), so the two
        # nameservers genuinely no longer share one answer. This job does
        # not itself start that shim (it is Compose-profile-gated; only
        # scripts/ssl-mitm-cache-simulation.sh names it explicitly), so this
        # check only proves the DNS answer is correct here, not that the
        # target is reachable -- the full endpoint-behavior proof (that each
        # answer leads to a genuinely different, correctly-behaving TLS
        # listener) lives in scripts/ssl-mitm-cache-simulation.sh, which does
        # start the shim.
        check_dns dns-standard "$VALIDATION_DNS_STANDARD_IP" "$standard_shim_ip"
        check_dns dns-ssl "$VALIDATION_DNS_SSL_IP" "$proxy_ip"

        curl --connect-timeout 5 --max-time 10 -fsS "http://${proxy_ip}/healthz" >/dev/null \
            || { echo "::error::Client could not reach proxy HTTP health endpoint."; exit 1; }
        curl --connect-timeout 5 --max-time 10 -fsS "http://ui:8080/health" >/dev/null \
            || { echo "::error::Client could not reach Admin UI health endpoint."; exit 1; }

        echo "Full-setup client simulation passed."
    '
