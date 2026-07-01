FROM mirror.gcr.io/library/rust:slim@sha256:6abf73f05806f36362d0ff2722f2250c6153398831edd0455e0e0baa1f78ecc7 AS subscriber-builder

# Keep sccache source-built and version-pinned, but only enable the cache
# backends this project wires: Redis and sccache-dist client support.
ARG DISTCC_PUMP_PACKAGE_VERSION=3.4+really3.4-12
RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    distcc_pump_tmp=""; \
    cleanup_builder_apt() { \
        if [ -n "$distcc_pump_tmp" ]; then rm -rf "$distcc_pump_tmp"; fi; \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_builder_apt EXIT; \
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        distcc \
        libssl-dev \
        pkg-config \
        procps \
        python3; \
    distcc_pump_tmp="$(mktemp -d)"; \
    chmod 0755 "$distcc_pump_tmp"; \
    chown _apt:root "$distcc_pump_tmp"; \
    (cd "$distcc_pump_tmp" && apt-get download "distcc-pump=$DISTCC_PUMP_PACKAGE_VERSION"); \
    dpkg --unpack "$distcc_pump_tmp"/distcc-pump_*.deb; \
    distcc_pump_parser="/usr/lib/python3/dist-packages/include_server/parse_command.py"; \
    grep -F "'-Wa,(%s\\.s)'" "$distcc_pump_parser" >/dev/null; \
    grep -F "'-Wa,\\[(%s\\.s)\\]'" "$distcc_pump_parser" >/dev/null; \
    sed -i \
        -e 's/%s\\.s/%s\\\\.s/g' \
        -e 's/-Wa,\\\[/-Wa,\\\\[/g' \
        -e 's/)\\\]/)\\\\]/g' \
        "$distcc_pump_parser"; \
    grep -F "'-Wa,(%s\\\\.s)'" "$distcc_pump_parser" >/dev/null; \
    grep -F "'-Wa,\\\\[(%s\\\\.s)\\\\]'" "$distcc_pump_parser" >/dev/null; \
    python3 -Werror::SyntaxWarning -m py_compile "$distcc_pump_parser"; \
    dpkg --configure distcc-pump; \
    python3 -Werror::SyntaxWarning -m compileall -q /usr/lib/python3/dist-packages/include_server; \
    rm -rf /var/lib/apt/lists/*; \
    cargo install sccache --version 0.16.0 --no-default-features --features redis,dist-client --root /usr/local

ARG CARGO_BUILD_JOBS=

WORKDIR /build
COPY nats-subscriber/ .
RUN --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    set -eu; \
    configure_sccache() { \
      if [ -s /run/secrets/sccache_redis_url ] || [ -s /run/secrets/sccache_dist_config ]; then \
        unset CARGO_MAKEFLAGS MAKEFLAGS; \
        export RUSTC_WRAPPER=sccache SCCACHE_REDIS_KEY_PREFIX=lancache-dns; \
        if [ -s /run/secrets/sccache_redis_url ]; then \
          export SCCACHE_REDIS="$(cat /run/secrets/sccache_redis_url)"; \
        fi; \
        if [ -s /run/secrets/sccache_dist_config ]; then \
          export SCCACHE_CONF=/run/secrets/sccache_dist_config; \
          sccache --dist-status; \
        fi; \
      fi; \
    }; \
    configure_distcc() { \
      if [ -s /run/secrets/distcc_potential_hosts ]; then \
        export DISTCC_POTENTIAL_HOSTS="$(cat /run/secrets/distcc_potential_hosts)"; \
        export PATH="/usr/lib/distcc:$PATH" CC=distcc GCC=distcc CXX=distcc GXX=distcc; \
        eval `distcc-pump --startup`; \
        trap 'distcc-pump --shutdown' EXIT; \
      fi; \
    }; \
    resolve_cargo_jobs() { \
      jobs="${CARGO_BUILD_JOBS:-}"; \
      if [ -z "$jobs" ]; then \
        cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 2)"; \
        jobs=$((cores - 2)); \
        if [ "$jobs" -lt 2 ]; then jobs=2; fi; \
      fi; \
      case "$jobs" in ''|*[!0-9]*) echo "CARGO_BUILD_JOBS must be a positive integer" >&2; exit 1;; esac; \
      if [ "$jobs" -le 0 ]; then echo "CARGO_BUILD_JOBS must be greater than zero" >&2; exit 1; fi; \
      printf '%s\n' "$jobs"; \
    }; \
    configure_sccache; \
    configure_distcc; \
    cargo_jobs="$(resolve_cargo_jobs)"; \
    cargo build -j "$cargo_jobs" --release --locked

FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

# Debian package triggers try to start services during image builds; the entrypoint starts PDNS instead.
RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    cleanup_invoke_rc_d() { \
        rm -f /usr/sbin/invoke-rc.d; \
        if [ -x /usr/sbin/invoke-rc.d.real ]; then mv /usr/sbin/invoke-rc.d.real /usr/sbin/invoke-rc.d; fi; \
    }; \
    trap cleanup_invoke_rc_d EXIT; \
    if [ -x /usr/sbin/invoke-rc.d ]; then mv /usr/sbin/invoke-rc.d /usr/sbin/invoke-rc.d.real; fi; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/invoke-rc.d; \
    chmod +x /usr/sbin/invoke-rc.d; \
    apt-get update && apt-get install -y --no-install-recommends \
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
