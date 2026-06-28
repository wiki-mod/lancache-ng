FROM rust:slim@sha256:6abf73f05806f36362d0ff2722f2250c6153398831edd0455e0e0baa1f78ecc7 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates pkg-config libssl-dev distcc distcc-pump procps \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install sccache --locked --version 0.16.0 --root /usr/local

ARG SCCACHE_REDIS_URL=
ARG DISTCC_POTENTIAL_HOSTS=
ARG SCCACHE_DIST_SCHEDULER_URL=
ENV CARGO_BUILD_JOBS=6

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
# Pre-cache dependencies (sccache used only when Redis or scheduler build args are provided)
RUN if [ -n "${SCCACHE_REDIS_URL}" ] || [ -n "${SCCACHE_DIST_SCHEDULER_URL}" ]; then \
      unset CARGO_MAKEFLAGS MAKEFLAGS; \
      export RUSTC_WRAPPER=sccache SCCACHE_REDIS_KEY_PREFIX=lancache-ui; \
      if [ -n "${SCCACHE_REDIS_URL}" ]; then \
        export SCCACHE_REDIS=${SCCACHE_REDIS_URL}; \
      fi; \
      if [ -n "${SCCACHE_DIST_SCHEDULER_URL}" ]; then \
        export SCCACHE_DIST_SCHEDULER_URL=${SCCACHE_DIST_SCHEDULER_URL}; \
      fi; \
    fi \
    && if [ -n "${DISTCC_POTENTIAL_HOSTS}" ]; then \
      export DISTCC_POTENTIAL_HOSTS=${DISTCC_POTENTIAL_HOSTS} CC=distcc CXX=distcc; \
      eval `distcc-pump --startup`; \
      trap 'distcc-pump --shutdown' EXIT; \
    fi \
    && mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release --locked 2>&1 \
    && rm -rf src

COPY src ./src
RUN if [ -n "${SCCACHE_REDIS_URL}" ] || [ -n "${SCCACHE_DIST_SCHEDULER_URL}" ]; then \
      unset CARGO_MAKEFLAGS MAKEFLAGS; \
      export RUSTC_WRAPPER=sccache SCCACHE_REDIS_KEY_PREFIX=lancache-ui; \
      if [ -n "${SCCACHE_REDIS_URL}" ]; then \
        export SCCACHE_REDIS=${SCCACHE_REDIS_URL}; \
      fi; \
      if [ -n "${SCCACHE_DIST_SCHEDULER_URL}" ]; then \
        export SCCACHE_DIST_SCHEDULER_URL=${SCCACHE_DIST_SCHEDULER_URL}; \
      fi; \
    fi \
    && if [ -n "${DISTCC_POTENTIAL_HOSTS}" ]; then \
      export DISTCC_POTENTIAL_HOSTS=${DISTCC_POTENTIAL_HOSTS} CC=distcc CXX=distcc; \
      eval `distcc-pump --startup`; \
      trap 'distcc-pump --shutdown' EXIT; \
    fi \
    && touch src/main.rs \
    && cargo build --release --locked

# ── Runtime image ──────────────────────────────────────────────────────────────
FROM debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    locales \
    util-linux \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY --from=builder /build/target/release/lancache-ui /usr/local/bin/lancache-ui
COPY src/templates /templates
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN groupadd --system --gid 10001 lancache \
    && useradd --system --uid 10001 --gid lancache --home-dir /nonexistent --shell /usr/sbin/nologin lancache \
    && mkdir -p /data /etc/nats \
    && chown -R lancache:lancache /data /etc/nats \
    && chmod +x /usr/local/bin/docker-entrypoint.sh


EXPOSE 8080

ENV TEMPLATE_DIR=/templates \
    CDN_DOMAINS_FILE=/data/cdn-domains.txt \
    SSL_DOMAINS_FILE=/data/cdn-ssl-domains.txt \
    STANDARD_LOG=/var/log/nginx/standard/access.log \
    SSL_LOG=/var/log/nginx/ssl/access.log \
    STANDARD_CACHE_DIR=/var/cache/standard \
    SSL_CACHE_DIR=/var/cache/ssl \
    PROXY_STANDARD_URL=http://proxy-standard \
    PROXY_SSL_URL=http://proxy-ssl \
    NETDATA_URL=http://netdata:19999 \
    DNS_STANDARD_SERVICE=dns-standard \
    DNS_SSL_SERVICE=dns-ssl \
    PROXY_SSL_SERVICE=proxy-ssl \
    STANDARD_CACHE_MAX_GB=10 \
    SSL_CACHE_MAX_GB=10

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["lancache-ui"]
