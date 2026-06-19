FROM rust:1.79-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Cargo.toml ./
# Pre-cache dependencies
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs
RUN cargo build --release 2>&1; rm -rf src

COPY src ./src
RUN touch src/main.rs && cargo build --release

# ── Runtime image ──────────────────────────────────────────────────────────────
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/lancache-ui /usr/local/bin/lancache-ui
COPY src/templates /templates

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

CMD ["lancache-ui"]
