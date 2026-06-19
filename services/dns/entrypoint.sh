#!/bin/bash
set -euo pipefail

DOMAINS_FILE="/etc/dnsmasq.d/cdn-domains.txt"
OUTPUT_FILE="/etc/dnsmasq.d/cdn-addresses.conf"
PROXY_IP="${PROXY_IP:?PROXY_IP is required — set it to the host machine's LAN IP}"
PROXY_IPV6="${PROXY_IPV6:-}"

echo "[lancache-dns] Proxy IPv4: $PROXY_IP"
[ -n "$PROXY_IPV6" ] && echo "[lancache-dns] Proxy IPv6: $PROXY_IPV6"

{
    echo "# Auto-generated — do not edit"
    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        echo "address=/$domain/$PROXY_IP"
        [ -n "$PROXY_IPV6" ] && echo "address=/$domain/$PROXY_IPV6"
    done < "$DOMAINS_FILE"
} > "$OUTPUT_FILE"

count=$(grep -c "^address=" "$OUTPUT_FILE" || true)
echo "[lancache-dns] ${count} address records written."

LOG_QUERIES=""
[ "${DNSMASQ_LOG_QUERIES:-0}" = "1" ] && LOG_QUERIES="--log-queries"

exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf $LOG_QUERIES
