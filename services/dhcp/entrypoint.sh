#!/bin/bash
set -e

mkdir -p /var/run/kea /var/lib/kea

# Defaults
: "${DHCP_SUBNET:=10.0.0.0/24}"
: "${DHCP_RANGE_START:=10.0.0.128}"
: "${DHCP_RANGE_END:=10.0.0.254}"
: "${DHCP_GATEWAY:=10.0.0.1}"
: "${DHCP_DOMAIN:=lan}"
: "${DHCP_LEASE_TIME:=86400}"
: "${DHCP_NTP_SERVERS:=time.nist.gov}"
: "${DHCP_DNS_PRIMARY:=127.0.0.1}"
: "${DHCP_DNS_SECONDARY:=127.0.0.1}"
: "${KEA_CTRL_TOKEN:=}"
: "${DHCP_DNS_SERVER_IP:=127.0.0.1}"
: "${DHCP_DNS_SERVER_IP_SSL:=127.0.0.1}"
: "${DHCP_DDNS_PORT:=53}"
: "${KEA_CTRL_HOST:=0.0.0.0}"

# Verify KEA_CTRL_TOKEN is set to a non-default secret.
case "$KEA_CTRL_TOKEN" in
    ""|"CHANGE_ME_KEA_CTRL_TOKEN"|"lancache-dhcp-secret"|"lancache-dhcp-dev-secret"|"lancache-dhcp-prod-secret")
        echo "ERROR: KEA_CTRL_TOKEN must be set to a strong generated secret."
        echo "Generate one with: openssl rand -hex 32"
        exit 1
        ;;
esac

# Generate TSIG key if not set (for DDNS) — stored in the runtime config on first boot
if [ -z "$DDNS_TSIG_KEY" ]; then
    DDNS_TSIG_KEY=$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')
    export DDNS_TSIG_KEY
fi

export DHCP_MAX_LEASE_TIME=$((DHCP_LEASE_TIME * 2))
export DHCP_SUBNET DHCP_RANGE_START DHCP_RANGE_END DHCP_GATEWAY DHCP_DOMAIN \
       DHCP_LEASE_TIME DHCP_NTP_SERVERS DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY \
       KEA_CTRL_TOKEN DHCP_MAX_LEASE_TIME DHCP_DNS_SERVER_IP DHCP_DNS_SERVER_IP_SSL \
       DHCP_DDNS_PORT KEA_CTRL_HOST

ENVSUBST_VARS='${DHCP_SUBNET}${DHCP_RANGE_START}${DHCP_RANGE_END}${DHCP_GATEWAY}${DHCP_DOMAIN}${DHCP_LEASE_TIME}${DHCP_NTP_SERVERS}${DHCP_DNS_PRIMARY}${DHCP_DNS_SECONDARY}${KEA_CTRL_TOKEN}${DHCP_MAX_LEASE_TIME}${DDNS_TSIG_KEY}${DHCP_DNS_SERVER_IP}${DHCP_DNS_SERVER_IP_SSL}${DHCP_DDNS_PORT}${KEA_CTRL_HOST}'

# Generate runtime configs from templates on first boot only.
# Once generated, the files live on the mounted volume and survive restarts.
# Changes via UI (config-set + config-write) update /var/lib/kea/kea-dhcp4.conf directly.
for name in kea-dhcp4 kea-ctrl-agent kea-dhcp-ddns; do
    TEMPLATE="/etc/kea/${name}.conf.template"
    RUNTIME="/var/lib/kea/${name}.conf"
    if [ ! -f "$RUNTIME" ]; then
        envsubst "$ENVSUBST_VARS" < "$TEMPLATE" > "$RUNTIME"
        echo "First boot: generated $RUNTIME"
    fi
done

# Restrict Kea Control Agent API (port 8000) to Docker-internal networks.
# Without this, network_mode:host exposes the API on all LAN interfaces.
if command -v iptables >/dev/null 2>&1; then
    # Check and add rules only if they don't exist (prevents accumulation on restart)
    # ACCEPT rules must come before DROP (rules are evaluated top-to-bottom)
    iptables -C INPUT -p tcp --dport 8000 -s 172.16.0.0/12 -j ACCEPT  2>/dev/null || iptables -A INPUT -p tcp --dport 8000 -s 172.16.0.0/12 -j ACCEPT
    iptables -C INPUT -p tcp --dport 8000 -s 127.0.0.0/8   -j ACCEPT  2>/dev/null || iptables -A INPUT -p tcp --dport 8000 -s 127.0.0.0/8   -j ACCEPT
    iptables -C INPUT -p tcp --dport 8000                   -j DROP    2>/dev/null || iptables -A INPUT -p tcp --dport 8000                   -j DROP
    echo "Kea Control Agent API restricted to Docker-internal access"
fi

echo "Starting Kea DHCPv4 server (Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START - $DHCP_RANGE_END)..."
kea-dhcp4 -c /var/lib/kea/kea-dhcp4.conf &
DHCP_PID=$!

echo "Starting Kea Control Agent on $KEA_CTRL_HOST:8000..."
kea-ctrl-agent -c /var/lib/kea/kea-ctrl-agent.conf &
AGENT_PID=$!

if command -v kea-dhcp-ddns &> /dev/null; then
    echo "Starting Kea DHCP DDNS server..."
    kea-dhcp-ddns -c /var/lib/kea/kea-dhcp-ddns.conf &
    DDNS_PID=$!
fi

trap "kill $DHCP_PID $AGENT_PID ${DDNS_PID:-} 2>/dev/null || true" EXIT TERM
wait
