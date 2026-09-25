
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: cachehamster Steam cache-warming prefill (scaffold)
# Why: cred-store/stream-fetch primitives; deferred features
# From: Issue #871

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: builder image, supplied by ci.sh from the SOT.
# Why: no mutable default; CI resolves the immutable ref.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
FROM ${BUILD_TOOLS_IMAGE} AS cachehamster-builder

# What: musl cross-target, supplied by ci.sh per platform.
# Why: ci.sh owns arch mapping; no uname -m in the image.
# From: Issue #1683
ARG MUSL_TARGET

# What: verify build-tools Rust/musl contract
# Why: fail closed on missing tools or targets
# From: Issue #871
RUN set -eu; \
    for tool in cargo rustc rustup; do \
      command -v "$tool" >/dev/null; \
    done; \
    command -v musl-gcc >/dev/null; \
    [ -n "${MUSL_TARGET}" ] || { echo "MUSL_TARGET build-arg is required" >&2; exit 1; }; \
    printf '%s\n' "${MUSL_TARGET}" > /tmp/musl-target; \
    installed_musl_targets="$(rustup target list --installed)"; \
    grep -qx "$(cat /tmp/musl-target)" <<<"${installed_musl_targets}"

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/

# What: cargo build with CC/GCC/CXX/GXX export and proxy CA
# Why: C-dep (ring); selfhosted proxy; no build acceleration
# From: Issue #871 | Issue #1671
RUN --mount=type=secret,id=project_selfhosted_proxy_ca set -eu; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig; \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    export CC=cc GCC=gcc CXX=c++ GXX=g++; \
    musl_target="$(cat /tmp/musl-target)"; \
    cargo build --release --locked --target "$musl_target"; \
    cp "target/${musl_target}/release/lancache-cachehamster" /build/lancache-cachehamster-out; \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="lancache-ng cachehamster: Steam cache-warming prefill daemon (scaffold, issue #871)."

# What: declares APT_CACHE_BUST before apk upgrade/add RUN
# Why: BuildKit cache expires to ensure fresh updates
# From: Issue #871
ARG APT_CACHE_BUST=""

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: apk upgrade base-layer; add ca-certs for public CDN
# Why: ca-certs needed for Steam CDN via rustls-tls
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache ca-certificates

COPY --from=cachehamster-builder /build/lancache-cachehamster-out /usr/local/bin/lancache-cachehamster

# What: adduser lancache 10001; mount /data; set user
# Why: unprivileged account, matches ui/watchdog lancache
RUN addgroup -g 10001 lancache && \
    adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache && \
    mkdir -p /data && \
    chown lancache:lancache /data
VOLUME ["/data"]
USER lancache

ENTRYPOINT ["/usr/local/bin/lancache-cachehamster"]
