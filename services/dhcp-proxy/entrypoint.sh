#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# dnsmasq DHCP proxy entrypoint. Validates required env vars, renders
# dnsmasq.conf.template via envsubst, and starts dnsmasq in proxy mode.

set -e

if [ -f /data/lancache-ui-settings.env ]; then
    # shellcheck disable=SC1091
    . /data/lancache-ui-settings.env
fi

: "${DHCP_SUBNET_START:?DHCP_SUBNET_START is required for dnsmasq proxy mode.}"
: "${DHCP_DNS_PRIMARY:?DHCP_DNS_PRIMARY is required for dnsmasq proxy mode.}"
: "${DHCP_DNS_SECONDARY:=$DHCP_DNS_PRIMARY}"
: "${UPSTREAM_DHCP_IP:?UPSTREAM_DHCP_IP is required for dnsmasq proxy mode.}"

export DHCP_SUBNET_START DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY UPSTREAM_DHCP_IP

envsubst < /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

echo "Starting dnsmasq DHCP proxy (subnet: $DHCP_SUBNET_START, DNS: $DHCP_DNS_PRIMARY, $DHCP_DNS_SECONDARY)..."
exec dnsmasq -k -C /etc/dnsmasq.conf
