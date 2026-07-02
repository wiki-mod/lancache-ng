FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    gettext \
    && rm -rf /var/lib/apt/lists/*

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
