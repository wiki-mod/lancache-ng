
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Health-check/restart daemon + file-retention sidecar (Rust).

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: builder image, supplied by ci.sh from the SOT.
# Why: no mutable default; CI resolves the immutable ref.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
FROM ${BUILD_TOOLS_IMAGE} AS watchdog-builder

# What: musl cross-target, supplied by ci.sh per platform.
# Why: ci.sh owns arch mapping; no uname -m in the image.
# From: Issue #1683
ARG MUSL_TARGET

# What: cargo tuning args, consumed by ci.sh rust-build.
# Why: PROJECT_CARGO_*/CARGO_BUILD_JOBS own these.
# From: Issue #1683
ARG CARGO_BUILD_JOBS=
ARG PROJECT_CARGO_LTO=
ARG PROJECT_CARGO_CODEGENUNIT=
# What: redeclare BUILD_TOOLS_IMAGE for the RUN stage.
# Why: ci.sh rust-build folds it into the ccache key.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
COPY tools/pxe-client-probe/Cargo.toml tools/pxe-client-probe/Cargo.toml
# What: stub targets for workspace members not built here.
# Why: cargo loads every member manifest to resolve deps.
# From: Issue #1095
RUN mkdir -p services/ui/src services/cachehamster/src \
      services/dns/nats-subscriber/src tools/pxe-client-probe/src \
    && printf 'fn main() {}\n' > services/ui/src/main.rs \
    && : > services/ui/src/lib.rs \
    && printf 'fn main() {}\n' > services/cachehamster/src/main.rs \
    && : > services/cachehamster/src/lib.rs \
    && printf 'fn main() {}\n' > services/dns/nats-subscriber/src/main.rs \
    && : > services/dns/nats-subscriber/src/lib.rs \
    && printf 'fn main() {}\n' > tools/pxe-client-probe/src/main.rs
COPY services/watchdog/src/ ./services/watchdog/src/
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build watchdog lancache-watchdog

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="lancache-ng watchdog: compiled Rust health-check/restart daemon plus the separate file-retention sidecar entrypoint."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: shared version-banner, not a per-service copy.
# Why: named build context avoids a per-service copy.
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: declares APT_CACHE_BUST before the busting RUN.
# Why: BuildKit cache has no wall-clock expiry.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: trust proxy CA, upgrade, apk install runtime tools.
# Why: CA restored (no leak); retention.sh needs these.
# From: Issue #1556 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    util-linux \
    nano \
    zstd \
    curl \
    findutils \
    lsof \
    ripgrep && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verify apk binaries execute, not just exist.
# Why: missing libs fail at runtime, not at apk add.
# From: Issue #1613 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY --from=watchdog-builder /build/lancache-watchdog-out /usr/local/bin/lancache-watchdog
COPY services/watchdog/healthcheck.sh /healthcheck.sh
COPY services/watchdog/retention.sh /retention.sh
COPY services/watchdog/retention-entrypoint.sh /retention-entrypoint.sh
RUN chmod +x /healthcheck.sh /retention.sh /retention-entrypoint.sh
VOLUME ["/var/run/watchdog"]

# What: lancache account, fixed uid/gid 10001.
# Why: only the retention sidecar drops to this user.
# From: Issue #842
RUN addgroup -g 10001 lancache && \
    adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache && \
    mkdir -p /var/lib/lancache-retention-state && \
    chown lancache:lancache /var/lib/lancache-retention-state

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in a published service image
# From: Issue #1781 | PR #1783
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

# What: final apk upgrade pass, no packages added.
# Why: patches CVEs fixed after the installs above.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

# What: default ENTRYPOINT is the compiled Rust binary now.
# Why: maintainer decision authorized the ENTRYPOINT swap.
# From: Issue #842
ENTRYPOINT ["/usr/local/bin/lancache-watchdog"]
