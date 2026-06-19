FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bind9 \
    bind9-dnsutils \
    gettext-base \
    locales \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Pre-create chroot skeleton — entrypoint fills in the rest at runtime
RUN mkdir -p \
    /var/lib/named/etc/bind/zones \
    /var/lib/named/var/cache/bind \
    /var/lib/named/var/run/named \
    && chown -R bind:bind /var/lib/named/var

COPY named.conf          /etc/bind/named.conf
COPY named.conf.options  /etc/bind/named.conf.options
COPY named.conf.local    /etc/bind/named.conf.local
COPY zones/              /etc/bind/zones/
COPY cdn-domains.txt     /etc/bind/cdn-domains.txt
COPY entrypoint.sh       /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/entrypoint.sh"]
