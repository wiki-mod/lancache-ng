
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Admin UI Rust binary plus Tera templates, Alpine.
# Why: the binary reads its templates from /templates.

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
FROM ${BUILD_TOOLS_IMAGE:-scratch} AS builder

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
# What: redeclare BUILD_TOOLS_IMAGE for the RUN stages.
# Why: ci.sh rust-build folds it into the ccache key.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
# What: compiler VAR=driver pairs, supplied by ci.sh.
# Why: the builder has no SOT; rust-build reads the env.
# From: Issue #1683 | PR #1858
ARG CI_TOOLCHAIN_COMPILERS

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
# What: shared crate manifest and sources, copied whole.
# Why: real sources before any build; no stale stub rlib.
# From: Issue #1683 | PR #1858
COPY services/common services/common
# What: dep pre-cache; ci.sh stubs and removes the srcs.
# Why: layer-caches deps so only real src changes rebuild.
# From: Issue #1533 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_policy \
    --mount=type=secret,id=sccache_gha \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build ui "${RUST_CRATE}" deps
COPY services/ui/src ./services/ui/src
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_policy \
    --mount=type=secret,id=sccache_gha \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build ui "${RUST_CRATE}"

# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="lancache-ng Admin UI and control-plane service for cache, DNS, DHCP, and secondary management."

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

COPY --from=builder /build/lancache-ui-out /usr/local/bin/lancache-ui
COPY services/ui/src/templates /templates

# What: the ui's own file layout, handed to it as environment.
# Why: this image creates these paths; Rust keeps no copy.
# From: Issue #1683
ENV TEMPLATE_DIR=/templates \
    CDN_DOMAINS_FILE=/data/cdn-domains.txt \
    UI_SETTINGS_FILE=/data/lancache-ui-settings.env \
    NETDATA_ALARMS_FILE=/data/netdata-alarms.json \
    NATS_ISSUER_SEED_PATH=/data/lancache-nats-issuer.seed \
    NATS_XKEY_SEED_PATH=/data/lancache-nats-xkey.seed \
    NATS_CONF_PATH=/etc/nats/nats.conf \
    NATS_AUTH_CALLOUT_PATH=/etc/nats/auth_callout.conf \
    UI_SESSION_SECRET_FILE=/data/lancache-ui-session.secret \
    UI_DATABASE_FILE=/data/lancache-ui.db \
    SECONDARY_REGISTRATION_TOKEN_FILE=/data/lancache-secondary-registration.token \
    UI_LOG_FILE=/var/log/lancache-ui/ui.log \
    UI_LISTEN_PORT=8080

# What: one ui runtime uid/gid for user and binary.
# Why: nginx logs share it; the root start drops to it.
# From: Issue #1427 | PR #1858
ARG UI_RUNTIME_ID=10001
ENV UI_RUNTIME_UID=${UI_RUNTIME_ID} \
    UI_RUNTIME_GID=${UI_RUNTIME_ID}
RUN addgroup -g "${UI_RUNTIME_ID}" lancache \
    && adduser -D -H -u "${UI_RUNTIME_ID}" -G lancache -s /sbin/nologin lancache \
    && mkdir -p /data /etc/nats \
    && chown -R lancache:lancache /data /etc/nats

EXPOSE ${UI_LISTEN_PORT}

# What: the binary, via PATH; it does the root start itself.
# Why: no wrapper; secrets, chown and uid drop are in Rust.
# From: Issue #858 | PR #1858
ENTRYPOINT ["lancache-ui"]
