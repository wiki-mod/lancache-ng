FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    kea-dhcp4-server \
    kea-ctrl-agent \
    kea-dhcp-ddns-server \
    kea-admin \
    gettext \
    openssl \
    curl \
    nmap \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Config templates — expanded once into /var/lib/kea/ on first boot
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/kea /var/run/kea

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
