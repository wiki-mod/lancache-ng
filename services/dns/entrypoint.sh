#!/bin/bash
set -euo pipefail

# ── Setup Variables ──────────────────────────────────────────────────────────
PROXY_IP="${PROXY_IP:?PROXY_IP is required - set it to the host LAN IP}"
PROXY_IPV6="${PROXY_IPV6:-}"
PDNS_API_KEY="${PDNS_API_KEY:-lancache-pdns-secret}"
DDNS_ALLOW_FROM="${DDNS_ALLOW_FROM:-127.0.0.1}"
LOG_QUERIES="${LOG_QUERIES:-${DNSMASQ_LOG_QUERIES:-0}}"
ROOT_ZONE_MIRROR="${ROOT_ZONE_MIRROR:-1}"
NATS_URL="${NATS_URL:-nats://nats:4222}"
NATS_TOKEN="${NATS_TOKEN:-}"
NATS_CONSUMER="${NATS_CONSUMER:-}"
NATS_RECONCILER="${NATS_RECONCILER:-0}"

export PDNS_API_KEY DDNS_ALLOW_FROM ROOT_ZONE_MIRROR NATS_URL NATS_TOKEN NATS_CONSUMER NATS_RECONCILER

echo "[lancache-dns] Proxy IPv4: $PROXY_IP"
[ -n "$PROXY_IPV6" ] && echo "[lancache-dns] Proxy IPv6: $PROXY_IPV6"

# ── 1. Generate Recursor Config ──────────────────────────────────────────────
echo "[lancache-dns] Generating recursor.conf..."
envsubst '${PDNS_API_KEY}' < /etc/pdns/recursor.conf.template > /tmp/recursor.conf && \
    mv /tmp/recursor.conf /etc/pdns/recursor.conf

if [ "$LOG_QUERIES" = "1" ]; then
    echo "[lancache-dns] Enabling query logging..."
    sed -i 's/^loglevel=3$/loglevel=6/' /etc/pdns/recursor.conf
fi

# ── 2. Generate Authoritative Config ─────────────────────────────────────────
echo "[lancache-dns] Generating pdns.conf..."
envsubst '${PDNS_API_KEY}:${DDNS_ALLOW_FROM}' < /etc/pdns/auth/pdns.conf.template > /tmp/pdns.conf && \
    mv /tmp/pdns.conf /etc/pdns/auth/pdns.conf

# ── 3. Initialize SQLite Database ────────────────────────────────────────────
if [ ! -f /var/lib/powerdns/pdns.sqlite3 ]; then
    echo "[lancache-dns] Initializing SQLite database..."
    SCHEMA=$(find /usr/share -name 'schema.sqlite3.sql' 2>/dev/null | head -1)
    if [ -z "$SCHEMA" ]; then
        echo "[lancache-dns] FATAL: sqlite schema not found in /usr/share"
        exit 1
    fi
    echo "[lancache-dns] Using schema: $SCHEMA"
    sqlite3 /var/lib/powerdns/pdns.sqlite3 < "$SCHEMA"
    chown pdns:pdns /var/lib/powerdns/pdns.sqlite3
fi

# ── 4. Create LAN Zones ──────────────────────────────────────────────────────
echo "[lancache-dns] Creating LAN zones in authoritative database..."

# Create LAN zones (will not error if already exist)
pdnsutil --config-dir=/etc/pdns/auth create-zone lan. || true
pdnsutil --config-dir=/etc/pdns/auth create-zone local.lan. || true

# Create empty reverse zones for privacy (prevent external PTR leakage)
for zone in \
    10.in-addr.arpa \
    168.192.in-addr.arpa \
    16.172.in-addr.arpa \
    17.172.in-addr.arpa \
    18.172.in-addr.arpa \
    19.172.in-addr.arpa \
    20.172.in-addr.arpa \
    21.172.in-addr.arpa \
    22.172.in-addr.arpa \
    23.172.in-addr.arpa \
    24.172.in-addr.arpa \
    25.172.in-addr.arpa \
    26.172.in-addr.arpa \
    27.172.in-addr.arpa \
    28.172.in-addr.arpa \
    29.172.in-addr.arpa \
    30.172.in-addr.arpa \
    31.172.in-addr.arpa \
    c.f.ip6.arpa \
    d.f.ip6.arpa; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone." || true
done

# ── 5. Generate RPZ Zone from cdn-domains.txt ────────────────────────────────
echo "[lancache-dns] Generating RPZ zone from cdn-domains.txt..."
SERIAL=$(date +%Y%m%d01)
RPZ_FILE="/var/lib/powerdns/rpz.zone"

{
    echo "\$ORIGIN rpz."
    echo "\$TTL 60"
    echo "@ SOA localhost. admin.rpz. $SERIAL 3600 900 604800 60"
    echo "@ NS localhost."
    echo ""
    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        printf "%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        printf "*.%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        if [ -n "$PROXY_IPV6" ]; then
            printf "%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
            printf "*.%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
        fi
    done < /etc/pdns/cdn-domains.txt
} > "$RPZ_FILE"

count=$(grep -c "^[a-zA-Z*]" "$RPZ_FILE" 2>/dev/null || true)
echo "[lancache-dns] RPZ zone: ${count:-0} records written."
chown pdns:pdns "$RPZ_FILE"

# ── 6. Start Both Processes (with restart loops) ─────────────────────────────
echo "[lancache-dns] Starting PowerDNS Authoritative and Recursor..."

run_auth() {
    while true; do
        pdns_server --config-dir=/etc/pdns/auth --guardian=no --daemon=no || true
        echo "[lancache-dns] pdns_server exited, restarting in 3s..."
        sleep 3
    done
}

run_recursor() {
    while true; do
        pdns_recursor --config-dir=/etc/pdns || true
        echo "[lancache-dns] pdns_recursor exited, restarting in 3s..."
        sleep 3
    done
}

# Start auth server first
run_auth &
AUTH_PID=$!

# Give auth time to come up before recursor starts
sleep 2

# Start recursor
run_recursor &
REC_PID=$!

# ── 7. Start NATS Subscriber ────────────────────────────────────────────────
run_nats_subscriber() {
    while true; do
        nats-subscriber || true
        echo "[lancache-dns] nats-subscriber exited, restarting in 3s..."
        sleep 3
    done
}

run_nats_subscriber &
NATS_PID=$!

# Handle termination
trap "kill $AUTH_PID $REC_PID $NATS_PID 2>/dev/null || true" EXIT TERM

# Wait indefinitely
wait
