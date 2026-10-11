
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: the services image; one supervisor runs it all.
# Why: five-container decision; watchdog owns the image.
# From: Issue #1683

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
FROM ${BUILD_TOOLS_IMAGE:-scratch} AS services-builder

# What: musl cross-target, supplied by ci.sh per platform.
# Why: ci.sh owns arch mapping; no uname -m in the image.
# From: Issue #1683
ARG MUSL_TARGET
# What: workspace crates, supplied by ci.sh from the SOT.
# Why: the SOT owns the crates; rust-build receives them.
# From: Issue #1683 | PR #1858
ARG RUST_CRATES

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
# What: compiler VAR=driver pairs, supplied by ci.sh.
# Why: the builder has no SOT; rust-build reads the env.
# From: Issue #1683 | PR #1858
ARG CI_TOOLCHAIN_COMPILERS

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
# What: shared crate manifest and sources, copied whole.
# Why: real sources before any build; no stale stub rlib.
# From: Issue #1683 | PR #1858
COPY services/common services/common
COPY services/watchdog/src/ ./services/watchdog/src/
COPY services/cachehamster/src/ ./services/cachehamster/src/
# What: retry policy for ci.sh, from SOT stage_variables
# Why: this stage has no SOT; ci.sh reads them from env
# From: Issue #1683 | PR #1858
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
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
    bash /usr/local/bin/ci.sh rust-build services "${RUST_CRATES}"

# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="LanCache-NG services: supervisor for watchdog, retention, syslog-ng, chrony and Netdata."

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
# What: retry policy for ci.sh, from SOT stage_variables
# Why: this stage has no SOT; ci.sh reads them from env
# From: Issue #1683 | PR #1858
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
# What: shared package setup via ci.sh.
# Why: ci.sh owns repos, proxy CA, update+upgrade, add.
# From: Issue #1683 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# What: syslog-ng files belong to this reader group.
# Why: the ui (gid 10001) and netdata web_log read them.
# From: Issue #1246 | Issue #1683
ENV LOG_READER_GROUP=lancache
RUN addgroup -g 10001 "${LOG_READER_GROUP}" && addgroup netdata "${LOG_READER_GROUP}"

COPY --from=services-builder /build/lancache-watchdog-out /usr/local/bin/lancache-watchdog
COPY --from=services-builder /build/lancache-cachehamster-out /usr/local/bin/lancache-cachehamster

# What: processes the supervisor runs, from the SOT.
# Why: ci.sh passes the list; the image holds no copy.
# From: Issue #1683
ARG LANCACHE_PROCESSES
ENV LANCACHE_PROCESSES=${LANCACHE_PROCESSES}

# What: the supervisor is the entrypoint; no shell script.
# Why: entrypoint.sh is legacy; Rust starts every process.
# From: Issue #1683
ENTRYPOINT ["/usr/local/bin/lancache-watchdog", "supervise"]
