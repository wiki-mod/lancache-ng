# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# dnsmasq-based DHCP proxy/relay image. Runs alongside an existing DHCP
# server in dnsmasq's "proxy" mode, overriding only DNS options for clients
# (mutually exclusive with the Kea DHCP mode in services/dhcp).

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dnsmasq \
    gettext \
    nano \
    lsof \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY dnsmasq-relay.conf.template /etc/dnsmasq-relay.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
