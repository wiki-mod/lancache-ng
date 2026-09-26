
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: cachehamster Steam cache-warming prefill (scaffold)
# Why: cred-store/stream-fetch primitives; deferred features
# From: Issue #871

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
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
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
COPY tools/pxe-client-probe/Cargo.toml tools/pxe-client-probe/Cargo.toml
# What: stub targets for workspace members not built here.
# Why: cargo loads every member manifest to resolve deps.
# From: Issue #1095
RUN mkdir -p services/ui/src services/watchdog/src \
      services/dns/nats-subscriber/src tools/pxe-client-probe/src \
    && printf 'fn main() {}\n' > services/ui/src/main.rs \
    && : > services/ui/src/lib.rs \
    && printf 'fn main() {}\n' > services/watchdog/src/main.rs \
    && : > services/watchdog/src/lib.rs \
    && printf 'fn main() {}\n' > services/dns/nats-subscriber/src/main.rs \
    && : > services/dns/nats-subscriber/src/lib.rs \
    && printf 'fn main() {}\n' > tools/pxe-client-probe/src/main.rs
COPY services/cachehamster/src services/cachehamster/src
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build cachehamster lancache-cachehamster

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="lancache-ng cachehamster: Steam cache-warming prefill daemon (scaffold, issue #871)."

# What: declares APT_CACHE_BUST before the apk RUN.
# Why: BuildKit cache expires to ensure fresh updates.
# From: Issue #871
ARG APT_CACHE_BUST=""

# What: the apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES

# What: bootstrap bash so the SHELL below is not busybox ash.
# Why: AG-REL-001 forbids ash; ci.sh apk-setup needs bash.
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: shared apk setup (repo-http+update+upgrade+add) via ci.sh.
# Why: one owner for the mandatory update+upgrade; SOT owns packages.
# From: Issue #871 | Issue #1683
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    : "apt-cache-bust=${APT_CACHE_BUST}" \
    && bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

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
