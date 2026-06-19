FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    locales \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY dnsmasq.conf /etc/dnsmasq.conf
COPY cdn-domains.txt /etc/dnsmasq.d/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/entrypoint.sh"]
