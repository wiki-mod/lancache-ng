FROM rust:slim AS subscriber-builder
WORKDIR /build
COPY nats-subscriber/ .
RUN cargo build --release

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    pdns-recursor \
    pdns-server \
    pdns-backend-sqlite3 \
    sqlite3 \
    gettext-base \
    locales \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN mkdir -p /etc/pdns/auth /var/lib/powerdns /var/run/pdns \
    && chown -R pdns:pdns /var/lib/powerdns /var/run/pdns

COPY --from=subscriber-builder /build/target/release/nats-subscriber /usr/local/bin/nats-subscriber

COPY recursor.conf.template /etc/pdns/recursor.conf.template
COPY pdns.conf.template /etc/pdns/auth/pdns.conf.template
COPY recursor.lua /etc/pdns/recursor.lua
COPY filter-aaaa.lua /etc/pdns/filter-aaaa.lua
COPY cdn-domains.txt /etc/pdns/cdn-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp 8081 8082

ENTRYPOINT ["/entrypoint.sh"]
