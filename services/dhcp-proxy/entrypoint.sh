#!/bin/bash
set -e

: "${DHCP_SUBNET_START:?DHCP_SUBNET_START is required for dnsmasq proxy mode.}"
: "${DHCP_DNS_PRIMARY:?DHCP_DNS_PRIMARY is required for dnsmasq proxy mode.}"
: "${DHCP_DNS_SECONDARY:=$DHCP_DNS_PRIMARY}"
: "${UPSTREAM_DHCP_IP:?UPSTREAM_DHCP_IP is required for dnsmasq proxy mode.}"

export DHCP_SUBNET_START DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY UPSTREAM_DHCP_IP

envsubst < /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

echo "Starting dnsmasq DHCP proxy (subnet: $DHCP_SUBNET_START, DNS: $DHCP_DNS_PRIMARY, $DHCP_DNS_SECONDARY)..."
exec dnsmasq -k -C /etc/dnsmasq.conf
