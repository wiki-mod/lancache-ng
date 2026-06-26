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

# The Control Agent config is not modified by the UI, but it is persisted on
# the Kea data volume. Regenerate it when KEA_CTRL_TOKEN or KEA_CTRL_HOST
# changes so upgrades do not leave the API using stale credentials.
CTRL_AGENT_TEMPLATE="/etc/kea/kea-ctrl-agent.conf.template"
CTRL_AGENT_RUNTIME="/var/lib/kea/kea-ctrl-agent.conf"
CTRL_AGENT_NEXT="$(mktemp)"
envsubst "$ENVSUBST_VARS" < "$CTRL_AGENT_TEMPLATE" > "$CTRL_AGENT_NEXT"
if ! cmp -s "$CTRL_AGENT_NEXT" "$CTRL_AGENT_RUNTIME"; then
    mv "$CTRL_AGENT_NEXT" "$CTRL_AGENT_RUNTIME"
    echo "Updated $CTRL_AGENT_RUNTIME from current Kea Control Agent settings"
else
    rm -f "$CTRL_AGENT_NEXT"
fi

# Restrict Kea Control Agent API (port 8000) to Docker-internal networks.
# Without this, network_mode:host exposes the API on all LAN interfaces.
if command -v iptables >/dev/null 2>&1; then
    KEA_CTRL_CHAIN="LANCACHE_KEA_CTRL"

    # Create or reset the managed chain. Keeping the chain stable avoids
    # failures when duplicate jump rules from previous starts still reference it.
    iptables -N "$KEA_CTRL_CHAIN" 2>/dev/null || true
    iptables -F "$KEA_CTRL_CHAIN"

    # Remove every managed jump and every legacy inline rule from old
    # implementations, so hosts with pre-existing duplicates self-heal.
    while iptables -D INPUT -p tcp --dport 8000 -j "$KEA_CTRL_CHAIN" 2>/dev/null; do
        :
    done
    while iptables -D INPUT -j "$KEA_CTRL_CHAIN" 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -s 172.16.0.0/12 -j ACCEPT 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -s 127.0.0.0/8 -j ACCEPT 2>/dev/null; do
        :
    done
    while iptables -D INPUT -p tcp --dport 8000 -j DROP 2>/dev/null; do
        :
    done

    # Insert one scoped jump near the top of INPUT before broader accept rules.
    iptables -I INPUT 1 -p tcp --dport 8000 -j "$KEA_CTRL_CHAIN"

    # Rebuild intended policy in the managed chain (order matters: ACCEPT before DROP).
    iptables -A "$KEA_CTRL_CHAIN" -s 172.16.0.0/12 -j ACCEPT
    iptables -A "$KEA_CTRL_CHAIN" -s 127.0.0.0/8 -j ACCEPT
    iptables -A "$KEA_CTRL_CHAIN" -j DROP

    echo "Kea Control Agent API restricted to Docker-internal access (using managed chain)"
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

trap '
    # Kill all background processes
    kill $DHCP_PID $AGENT_PID ${DDNS_PID:-} 2>/dev/null || true

    # Clean up iptables chain if it exists
    if command -v iptables >/dev/null 2>&1; then
        # Remove all managed jump rules from INPUT. Include the old unscoped
        # form for compatibility with previous entrypoint versions.
        while iptables -D INPUT -p tcp --dport 8000 -j LANCACHE_KEA_CTRL 2>/dev/null; do
            :
        done
        while iptables -D INPUT -j LANCACHE_KEA_CTRL 2>/dev/null; do
            :
        done

        # Flush and delete the custom chain
        iptables -F LANCACHE_KEA_CTRL 2>/dev/null || true
        iptables -X LANCACHE_KEA_CTRL 2>/dev/null || true
    fi
' EXIT TERM
wait
