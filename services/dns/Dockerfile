FROM mirror.gcr.io/library/rust:slim@sha256:6abf73f05806f36362d0ff2722f2250c6153398831edd0455e0e0baa1f78ecc7 AS subscriber-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install sccache --locked --version 0.16.0 --root /usr/local

WORKDIR /build
COPY nats-subscriber/ .
RUN --mount=type=secret,id=sccache_redis_url \
    if [ -s /run/secrets/sccache_redis_url ]; then \
      unset CARGO_MAKEFLAGS MAKEFLAGS; \
      export RUSTC_WRAPPER=sccache SCCACHE_REDIS_KEY_PREFIX=lancache-dns; \
      export SCCACHE_REDIS="$(cat /run/secrets/sccache_redis_url)"; \
    fi \
    && cargo build --release --locked

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

# Debian package triggers try to start services during image builds; the entrypoint starts PDNS instead.
RUN set -eu; \
    cleanup_invoke_rc_d() { \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_invoke_rc_d EXIT; \
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    pdns-recursor \
    pdns-server \
    pdns-backend-sqlite3 \
    dnsutils \
    sqlite3 \
    gettext-base \
    iproute2 \
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
