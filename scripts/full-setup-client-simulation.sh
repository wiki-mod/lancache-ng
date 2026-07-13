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
    "$client_tools_image" \
    bash -ceu '
        domain="${FULL_SETUP_CLIENT_DOMAIN:?}"
        proxy_ip="${VALIDATION_PROXY_IP:?}"

        check_dns() {
            local label="$1" server_ip="$2" response
            response="$(dig +time=3 +tries=2 +short @"$server_ip" A "$domain" | awk "NF { print }" | sort -u)"
            printf "%s DNS response for %s: %s\n" "$label" "$domain" "${response:-<empty>}"
            if ! printf "%s\n" "$response" | grep -Fx "$proxy_ip" >/dev/null; then
                echo "::error::$label DNS did not resolve $domain to expected proxy IP $proxy_ip."
                exit 1
            fi
        }

        # dns-standard and dns-ssl are both checked against the same
        # $proxy_ip on purpose in this harness (issue #668) -- see the long
        # comment above the equivalent check in
        # scripts/ssl-mitm-cache-simulation.sh for why prod uses two
        # distinct LAN addresses (host-IP-scoped Docker port publishing)
        # while this bridge-network validation topology cannot reach the
        # proxy any other way than through its one real container address.
        check_dns dns-standard "$VALIDATION_DNS_STANDARD_IP"
        check_dns dns-ssl "$VALIDATION_DNS_SSL_IP"

        curl --connect-timeout 5 --max-time 10 -fsS "http://${proxy_ip}/healthz" >/dev/null \
            || { echo "::error::Client could not reach proxy HTTP health endpoint."; exit 1; }
        curl --connect-timeout 5 --max-time 10 -fsS "http://ui:8080/health" >/dev/null \
            || { echo "::error::Client could not reach Admin UI health endpoint."; exit 1; }

        echo "Full-setup client simulation passed."
    '
