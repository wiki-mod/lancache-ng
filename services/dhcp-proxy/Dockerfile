FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    gettext \
    && rm -rf /var/lib/apt/lists/*

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
