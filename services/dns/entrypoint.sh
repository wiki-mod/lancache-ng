#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# PowerDNS container entrypoint. Generates RPZ zones from cdn-domains.txt
# (with monotonic serial handling), renders the recursor/authoritative config
# templates, configures DDNS TSIG auth (configure_ddns_tsig), and starts the
# authoritative server, recursor, and NATS subscriber in one container so DNS
# records stay aligned with Admin UI changes.
set -euo pipefail

# ── Setup Variables ──────────────────────────────────────────────────────────
PROXY_IP="${PROXY_IP:?PROXY_IP is required - set it to the host LAN IP}"
PROXY_IPV6="${PROXY_IPV6:-}"
PDNS_API_KEY="${PDNS_API_KEY:-CHANGE_ME_PDNS_API_KEY}"
DDNS_ALLOW_FROM="${DDNS_ALLOW_FROM:-127.0.0.1}"
DDNS_TSIG_KEY="${DDNS_TSIG_KEY:-}"
DDNS_TSIG_NAME="${DDNS_TSIG_NAME:-lancache-ddns-key}"
DDNS_TSIG_ALGORITHM="${DDNS_TSIG_ALGORITHM:-hmac-sha256}"
LOG_QUERIES="${LOG_QUERIES:-${DNSMASQ_LOG_QUERIES:-0}}"
ROOT_ZONE_MIRROR="${ROOT_ZONE_MIRROR:-1}"
NATS_URL="${NATS_URL:-nats://nats:4222}"
NATS_USER="${NATS_USER:-}"
NATS_PASSWORD="${NATS_PASSWORD:-}"
NATS_TOKEN="${NATS_TOKEN:-}"
NATS_CONSUMER="${NATS_CONSUMER:-}"
NATS_RECONCILER="${NATS_RECONCILER:-0}"

# Fail if PDNS_API_KEY is a known placeholder value
case "$PDNS_API_KEY" in
    CHANGE_ME_PDNS_API_KEY|changeme-pdns-api-key-change-this|changeme*)
        echo "[lancache-dns] FATAL: PDNS_API_KEY is still set to a default placeholder ('$PDNS_API_KEY')"
        echo "[lancache-dns] This is a security issue — the API key must be changed before deployment."
        echo "[lancache-dns] Generate a strong key with: openssl rand -hex 32"
        exit 1
        ;;
esac

# Fail if PDNS_API_KEY is too short (weak) — checked for all values, not just placeholders
if [ ${#PDNS_API_KEY} -lt 16 ]; then
    echo "[lancache-dns] FATAL: PDNS_API_KEY is too short (${#PDNS_API_KEY} characters, minimum 16 required)"
    echo "[lancache-dns] Generate a strong key with: openssl rand -hex 32"
    exit 1
fi

export PDNS_API_KEY DDNS_ALLOW_FROM ROOT_ZONE_MIRROR NATS_URL NATS_USER NATS_PASSWORD NATS_TOKEN NATS_CONSUMER NATS_RECONCILER

LAN_ZONES=(
    lan.
    local.lan.
)

PRIVATE_REVERSE_ZONES=(
    10.in-addr.arpa.
    168.192.in-addr.arpa.
    16.172.in-addr.arpa.
    17.172.in-addr.arpa.
    18.172.in-addr.arpa.
    19.172.in-addr.arpa.
    20.172.in-addr.arpa.
    21.172.in-addr.arpa.
    22.172.in-addr.arpa.
    23.172.in-addr.arpa.
    24.172.in-addr.arpa.
    25.172.in-addr.arpa.
    26.172.in-addr.arpa.
    27.172.in-addr.arpa.
    28.172.in-addr.arpa.
    29.172.in-addr.arpa.
    30.172.in-addr.arpa.
    31.172.in-addr.arpa.
    c.f.ip6.arpa.
    d.f.ip6.arpa.
)

DDNS_UPDATE_ZONES=("${LAN_ZONES[@]}" "${PRIVATE_REVERSE_ZONES[@]}")

configure_ddns_tsig() {
    case "$DDNS_TSIG_KEY" in
        "")
            echo "[lancache-dns] DDNS_TSIG_KEY is not set; TSIG-authenticated DNS updates are not configured."
            return
            ;;
        CHANGE_ME*|changeme*)
            echo "[lancache-dns] FATAL: DDNS_TSIG_KEY is still set to a default placeholder."
            printf '%s\n' "[lancache-dns] Generate a shared key with: openssl rand -base64 32 | tr -d '\\n'"
            exit 1
            ;;
    esac

    pdnsutil --config-dir=/etc/pdns/auth import-tsig-key \
        "$DDNS_TSIG_NAME" "$DDNS_TSIG_ALGORITHM" "$DDNS_TSIG_KEY" >/dev/null

    for zone in "${DDNS_UPDATE_ZONES[@]}"; do
        pdnsutil --config-dir=/etc/pdns/auth set-meta "$zone" TSIG-ALLOW-DNSUPDATE "$DDNS_TSIG_NAME" >/dev/null
    done

    echo "[lancache-dns] Configured TSIG-authenticated DDNS updates for LAN zones."
}

echo "[lancache-dns] Proxy IPv4: $PROXY_IP"
[ -n "$PROXY_IPV6" ] && echo "[lancache-dns] Proxy IPv6: $PROXY_IPV6"

# ── 1. Generate Recursor Config ──────────────────────────────────────────────
echo "[lancache-dns] Generating recursor.conf..."
# shellcheck disable=SC2016 # envsubst needs the literal variable name.
envsubst '${PDNS_API_KEY}' < /etc/pdns/recursor.conf.template > /tmp/recursor.conf && \
    mv /tmp/recursor.conf /etc/pdns/recursor.conf

if [ "$LOG_QUERIES" = "1" ]; then
    echo "[lancache-dns] Enabling query logging..."
    sed -i 's/^  loglevel: 3$/  loglevel: 6/' /etc/pdns/recursor.conf
fi

# ── 2. Generate Authoritative Config ─────────────────────────────────────────
echo "[lancache-dns] Generating pdns.conf..."
# shellcheck disable=SC2016 # envsubst needs the literal variable names.
envsubst '${PDNS_API_KEY}:${DDNS_ALLOW_FROM}' < /etc/pdns/auth/pdns.conf.template > /tmp/pdns.conf && \
    mv /tmp/pdns.conf /etc/pdns/auth/pdns.conf

# ── 3. Initialize SQLite Database ────────────────────────────────────────────
if [ ! -f /var/lib/powerdns/pdns.sqlite3 ]; then
    echo "[lancache-dns] Initializing SQLite database..."
    SCHEMA=$(find /usr/share -name 'schema.sqlite3.sql' -print -quit 2>/dev/null)
    if [ -z "$SCHEMA" ]; then
        echo "[lancache-dns] FATAL: sqlite schema not found in /usr/share"
        exit 1
    fi
    echo "[lancache-dns] Using schema: $SCHEMA"
    sqlite3 /var/lib/powerdns/pdns.sqlite3 < "$SCHEMA"
    chown pdns:pdns /var/lib/powerdns/pdns.sqlite3
fi

# ── 4. Migrate Legacy AAAA Filter Marker ─────────────────────────────────────
# The AAAA filter marker moved from this container's own data volume
# (toggled via `docker exec` before the Docker socket proxy was narrowed) to
# the shared /var/lib/powerdns-state volume the Admin UI now toggles instead.
# This container is the only one that can ever see the old marker (it lived
# in this container's own /var/lib/powerdns), so it owns migrating it forward
# one time; the Admin UI has no access to /var/lib/powerdns to do this itself.
LEGACY_AAAA_FILTER_MARKER="/var/lib/powerdns/aaaa-filter-enabled"
AAAA_FILTER_STATE_DIR="/var/lib/powerdns-state"
AAAA_FILTER_MARKER="${AAAA_FILTER_STATE_DIR}/aaaa-filter-enabled"
if [ -f "$LEGACY_AAAA_FILTER_MARKER" ] && [ ! -f "$AAAA_FILTER_MARKER" ]; then
    echo "[lancache-dns] Migrating legacy AAAA filter marker to shared state volume..."
    mkdir -p "$AAAA_FILTER_STATE_DIR"
    touch "$AAAA_FILTER_MARKER"
    rm -f "$LEGACY_AAAA_FILTER_MARKER"
fi

# ── 5. Create LAN Zones ──────────────────────────────────────────────────────
echo "[lancache-dns] Creating LAN zones in authoritative database..."

# Create LAN zones (will not error if already exist)
for zone in "${LAN_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done

# Create empty reverse zones for privacy (prevent external PTR leakage)
for zone in "${PRIVATE_REVERSE_ZONES[@]}"; do
    pdnsutil --config-dir=/etc/pdns/auth create-zone "$zone" || true
done

configure_ddns_tsig

# ── 6. Generate RPZ Zone from cdn-domains.txt ────────────────────────────────
echo "[lancache-dns] Generating RPZ zone from cdn-domains.txt..."
SERIAL=$(date +%s | tail -c 11)
RPZ_FILE="/var/lib/powerdns/rpz.zone"

# Preserve monotonic RPZ SOA serials: ensure SERIAL doesn't go backwards
if [ -f "$RPZ_FILE" ]; then
    OLD_SERIAL=$(grep -oP '^\s*@\s+SOA\s+[^\s]+\s+[^\s]+\s+\K\d+' "$RPZ_FILE" 2>/dev/null || echo 0)
    if [ "$SERIAL" -le "$OLD_SERIAL" ]; then
        SERIAL=$(( OLD_SERIAL + 1 ))
        echo "[lancache-dns] Monotonic serial: new=$SERIAL (was $OLD_SERIAL)"
    fi
fi

{
    echo "\$ORIGIN rpz."
    echo "\$TTL 60"
    echo "@ SOA localhost. admin.rpz. $SERIAL 3600 900 604800 60"
    echo "@ NS localhost."
    echo ""
    while IFS= read -r domain || [ -n "$domain" ]; do
        domain="${domain#"${domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        is_wildcard_only=0
        if [[ "$domain" == .* ]]; then
            is_wildcard_only=1
            domain="${domain#.}"
        fi
        [[ -z "$domain" ]] && continue
        if [ "$is_wildcard_only" -eq 0 ]; then
            printf "%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        fi
        printf "*.%s 60 IN A %s\n" "${domain}" "${PROXY_IP}"
        if [ -n "$PROXY_IPV6" ]; then
            if [ "$is_wildcard_only" -eq 0 ]; then
                printf "%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
            fi
            printf "*.%s 60 IN AAAA %s\n" "${domain}" "${PROXY_IPV6}"
        fi
    done < /etc/pdns/cdn-domains.txt
} > "$RPZ_FILE"

count=$(grep -c "^[a-zA-Z*]" "$RPZ_FILE" 2>/dev/null || true)
echo "[lancache-dns] RPZ zone: ${count:-0} records written."
chown pdns:pdns "$RPZ_FILE"

# ── 7. Start Both Processes (with restart loops) ─────────────────────────────
echo "[lancache-dns] Starting PowerDNS Authoritative and Recursor..."

run_auth() {
    while true; do
        pdns_server --config-dir=/etc/pdns/auth --guardian=no --daemon=no || true
        echo "[lancache-dns] pdns_server exited, restarting in 3s..."
        sleep 3
    done
}

run_recursor() {
    mkdir -p /var/run/pdns-recursor
    while true; do
        pdns_recursor --config-dir=/etc/pdns || true
        echo "[lancache-dns] pdns_recursor exited, restarting in 3s..."
        sleep 3
    done
}

# Start auth server first
run_auth &
AUTH_PID=$!

# Wait for pdns_server to be ready before starting recursor (polling with timeout)
READY=0
for i in {1..10}; do
    if pdns_control rping >/dev/null 2>&1; then
        echo "[lancache-dns] pdns_server is ready (attempt $i)"
        READY=1
        break
    fi
    sleep 0.5
done
if [ $READY -eq 0 ]; then
    echo "[lancache-dns] WARNING: pdns_server did not respond to ping; recursor will start anyway"
fi

# Start recursor
run_recursor &
REC_PID=$!

# ── 8. Start NATS Subscriber ────────────────────────────────────────────────
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
trap 'kill $AUTH_PID $REC_PID $NATS_PID 2>/dev/null || true' EXIT TERM INT

# Wait indefinitely
wait
