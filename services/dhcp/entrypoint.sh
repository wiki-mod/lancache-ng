#!/bin/bash
set -e

# Create necessary directories
mkdir -p /var/run/kea /var/lib/kea

# Defaults
: ${DHCP_SUBNET:=10.0.0.0/24}
: ${DHCP_RANGE_START:=10.0.0.128}
: ${DHCP_RANGE_END:=10.0.0.254}
: ${DHCP_GATEWAY:=10.0.0.1}
: ${DHCP_DOMAIN:=lan}
: ${DHCP_LEASE_TIME:=86400}
: ${DHCP_NTP_SERVERS:=time.nist.gov}
: ${DHCP_DNS_PRIMARY:=127.0.0.1}
: ${DHCP_DNS_SECONDARY:=127.0.0.1}
: ${KEA_CTRL_TOKEN:=lancache-dhcp-secret}

# Generate TSIG key if not set (for DDNS)
if [ -z "$DDNS_TSIG_KEY" ]; then
    DDNS_TSIG_KEY=$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')
    echo "Generated TSIG key: $DDNS_TSIG_KEY"
    export DDNS_TSIG_KEY
fi

# Calculate max lease time (2x the default)
export DHCP_MAX_LEASE_TIME=$((DHCP_LEASE_TIME * 2))

# Export all vars for envsubst
export DHCP_SUBNET DHCP_RANGE_START DHCP_RANGE_END DHCP_GATEWAY DHCP_DOMAIN DHCP_LEASE_TIME DHCP_NTP_SERVERS DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY KEA_CTRL_TOKEN DHCP_MAX_LEASE_TIME

# Replace env variables in configs
for conf in /etc/kea/kea-dhcp4.conf /etc/kea/kea-ctrl-agent.conf /etc/kea/kea-dhcp-ddns.conf; do
    if [ -f "$conf" ]; then
        envsubst < "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi
done

# Start Kea DHCPv4 server
echo "Starting Kea DHCPv4 server (Subnet: $DHCP_SUBNET, Pool: $DHCP_RANGE_START - $DHCP_RANGE_END)..."
kea-dhcp4 -c /etc/kea/kea-dhcp4.conf &
DHCP_PID=$!

# Start Kea Control Agent
echo "Starting Kea Control Agent on 0.0.0.0:8000..."
kea-ctrl-agent -c /etc/kea/kea-ctrl-agent.conf &
AGENT_PID=$!

# Start Kea DHCP DDNS server (optional, for DNS updates)
if command -v kea-dhcp-ddns &> /dev/null; then
    echo "Starting Kea DHCP DDNS server..."
    kea-dhcp-ddns -c /etc/kea/kea-dhcp-ddns.conf &
    DDNS_PID=$!
fi

# Wait for all processes (trap to handle signals)
trap "kill $DHCP_PID $AGENT_PID $DDNS_PID 2>/dev/null || true" EXIT TERM
wait
