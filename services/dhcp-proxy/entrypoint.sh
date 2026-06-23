#!/bin/bash
set -e

: ${DHCP_SUBNET_START:=10.0.0.0}
: ${DHCP_DNS_PRIMARY:=192.168.1.10}
: ${DHCP_DNS_SECONDARY:=192.168.1.11}
: ${UPSTREAM_DHCP_IP:=192.168.1.1}

export DHCP_SUBNET_START DHCP_DNS_PRIMARY DHCP_DNS_SECONDARY UPSTREAM_DHCP_IP

envsubst < /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

echo "Starting dnsmasq DHCP proxy (subnet: $DHCP_SUBNET_START, DNS: $DHCP_DNS_PRIMARY, $DHCP_DNS_SECONDARY)..."
exec dnsmasq -k -C /etc/dnsmasq.conf
