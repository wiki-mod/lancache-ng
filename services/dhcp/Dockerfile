FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    kea-dhcp4-server \
    kea-ctrl-agent \
    kea-dhcp-ddns-server \
    kea-admin \
    gettext \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY kea-dhcp4.conf /etc/kea/
COPY kea-ctrl-agent.conf /etc/kea/
COPY kea-dhcp-ddns.conf /etc/kea/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
