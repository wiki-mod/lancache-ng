# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Kea DHCP image: DHCPv4 server, control agent (API on :8000), and DHCP-DDNS
# service for lancache-ng managed networks.

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

LABEL org.opencontainers.image.description="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    kea-dhcp4-server \
    kea-ctrl-agent \
    kea-dhcp-ddns-server \
    kea-admin \
    nmap \
    gettext \
    openssl \
    curl \
    jq \
    iptables \
    nano \
    lsof \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

# Config templates — expanded once into /var/lib/kea/ on first boot
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/kea && install -d -m 750 /run/kea

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
