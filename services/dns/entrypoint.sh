#!/bin/bash
set -euo pipefail

CHROOT="/var/lib/named"
DOMAINS_FILE="/etc/bind/cdn-domains.txt"
PROXY_IP="${PROXY_IP:?PROXY_IP is required - set it to the host LAN IP}"
PROXY_IPV6="${PROXY_IPV6:-}"
LOG_QUERIES="${LOG_QUERIES:-${DNSMASQ_LOG_QUERIES:-0}}"

echo "[lancache-dns] Proxy IPv4: $PROXY_IP"
[ -n "$PROXY_IPV6" ] && echo "[lancache-dns] Proxy IPv6: $PROXY_IPV6"

# ── 1. Populate chroot with static configs ────────────────────────────────────
mkdir -p \
    "$CHROOT/etc/bind/zones" \
    "$CHROOT/var/cache/bind" \
    "$CHROOT/var/run/named"

cp  /etc/bind/named.conf         "$CHROOT/etc/bind/named.conf"
cp  /etc/bind/named.conf.options "$CHROOT/etc/bind/named.conf.options"
cp  /etc/bind/named.conf.local   "$CHROOT/etc/bind/named.conf.local"
cp -r /etc/bind/zones/.          "$CHROOT/etc/bind/zones/"

# ── 2. Generate logging config ────────────────────────────────────────────────
SEVERITY="warning"
[ "$LOG_QUERIES" = "1" ] && SEVERITY="info"

cat > "$CHROOT/etc/bind/named.conf.logging" <<EOF
logging {
    channel default_stderr {
        stderr;
        severity $SEVERITY;
        print-severity yes;
        print-time     yes;
        print-category yes;
    };
    category default { default_stderr; };
    category queries { default_stderr; };
};
EOF

# ── 3. Generate RPZ zone from cdn-domains.txt ─────────────────────────────────
SERIAL=$(date +%Y%m%d01)
RPZ_FILE="$CHROOT/var/cache/bind/db.rpz"

{
    echo "\$ORIGIN rpz.lancache.lan."
    echo "\$TTL 60"
    echo "@ SOA localhost. admin.lancache.lan. $SERIAL 3600 900 604800 60"
    echo "@ NS  localhost."
    echo ""
    while IFS= read -r domain || [ -n "$domain" ]; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        printf "%s A %s\n"   "${domain}" "${PROXY_IP}"
        printf "*.%s A %s\n" "${domain}" "${PROXY_IP}"
        if [ -n "$PROXY_IPV6" ]; then
            printf "%s AAAA %s\n"   "${domain}" "${PROXY_IPV6}"
            printf "*.%s AAAA %s\n" "${domain}" "${PROXY_IPV6}"
        fi
    done < "$DOMAINS_FILE"
} > "$RPZ_FILE"

count=$(grep -c "^[a-zA-Z*]" "$RPZ_FILE" 2>/dev/null || true)
echo "[lancache-dns] RPZ zone: ${count:-0} records written."

chown -R bind:bind "$CHROOT/var"

# ── 3b. Generate LAN zones config (TSIG key + allow-update if DDNS_TSIG_KEY set) ─
DDNS_TSIG_KEY="${DDNS_TSIG_KEY:-}"
LAN_ZONES_FILE="$CHROOT/etc/bind/named.conf.lan-zones"

{
    if [ -n "$DDNS_TSIG_KEY" ]; then
        echo "key \"lancache-ddns-key\" {"
        echo "    algorithm hmac-sha256;"
        echo "    secret \"$DDNS_TSIG_KEY\";"
        echo "};"
        echo ""
        ALLOW_UPDATE='    allow-update { key "lancache-ddns-key"; };'
    else
        ALLOW_UPDATE=""
    fi
    echo "zone \"lan\" {"
    echo "    type primary;"
    echo "    file \"/etc/bind/zones/db.lan\";"
    [ -n "$ALLOW_UPDATE" ] && echo "$ALLOW_UPDATE"
    echo "};"
    echo ""
    echo "zone \"local.lan\" {"
    echo "    type primary;"
    echo "    file \"/etc/bind/zones/db.local.lan\";"
    echo "};"
} > "$LAN_ZONES_FILE"

if [ -n "$DDNS_TSIG_KEY" ]; then
    echo "[lancache-dns] DDNS enabled — TSIG key configured for zone 'lan'."
else
    echo "[lancache-dns] DDNS disabled — DDNS_TSIG_KEY not set."
fi

# ── 4. Validate config ─────────────────────────────────────────────────────────
echo "[lancache-dns] Validating BIND9 config..."
named-checkconf -t "$CHROOT" /etc/bind/named.conf
named-checkzone rpz.lancache.lan "$RPZ_FILE"

# ── 5. Start BIND9 ─────────────────────────────────────────────────────────────
echo "[lancache-dns] Starting BIND9..."
exec named -f -u bind -t "$CHROOT"
