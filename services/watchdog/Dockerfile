
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Health-check/restart daemon + file-retention sidecar (Rust).

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE

# What: builder image, supplied by ci.sh from the SOT.
# Why: no mutable default; CI resolves the immutable ref.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${BUILD_TOOLS_IMAGE:-scratch} AS watchdog-builder

# What: musl cross-target, supplied by ci.sh per platform.
# Why: ci.sh owns arch mapping; no uname -m in the image.
# From: Issue #1683
ARG MUSL_TARGET
# What: workspace crate, supplied by ci.sh from the SOT.
# Why: the SOT owns the crate; rust-build receives it.
# From: Issue #1683 | PR #1858
ARG RUST_CRATE

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
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build watchdog "${RUST_CRATE}"

# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="lancache-ng watchdog: compiled Rust health-check/restart daemon plus the separate file-retention sidecar entrypoint."

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: Install bash before SHELL directive
# Why: AG-REL-001 forbids ash; RUN needs bash
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: shared package setup via ci.sh.
# Why: ci.sh owns repos, proxy CA, update+upgrade, add.
# From: Issue #1683 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

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

# What: default ENTRYPOINT is the compiled Rust binary now.
# Why: maintainer decision authorized the ENTRYPOINT swap.
# From: Issue #842
ENTRYPOINT ["/usr/local/bin/lancache-watchdog"]
