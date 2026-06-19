FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    && rm -rf /var/lib/apt/lists/*

COPY dnsmasq.conf /etc/dnsmasq.conf
COPY cdn-domains.txt /etc/dnsmasq.d/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/entrypoint.sh"]
