
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Admin UI Rust binary on Alpine.
# Why: compose mounts its templates at TEMPLATE_DIR.

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
ARG RUST_CRATES

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
# What: compiler pairs and cache key prefix, from ci.sh.
# Why: the builder has no SOT; rust-build reads the env.
# From: Issue #1683 | PR #1912
ARG CI_TOOLCHAIN_COMPILERS
ARG CI_CACHE_PREFIX
# What: cargo home, root of the cargo cache mounts.
# Why: §39 registry and git caches; the SOT owns it.
# From: Issue #1683 | PR #1912
ARG CI_CARGO_HOME

WORKDIR /build
# What: mount point of the build context, from the SOT.
# Why: rust-build reads the tree there; no COPY list.
# From: Issue #1683 | PR #1858
ARG CI_RUST_SOURCE_DIR
# What: retry and download bounds, SOT stage_variables
# Why: this stage has no SOT; ci.sh reads them from env
# From: Issue #1683 | PR #1858
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
ARG CI_DOWNLOAD_CONNECT_TIMEOUT
ARG CI_DOWNLOAD_STALL_SECONDS
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=bind,target=${CI_RUST_SOURCE_DIR},rw \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_policy \
    --mount=type=secret,id=sccache_gha \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    --mount=type=cache,target=${CI_CARGO_HOME}/registry,sharing=locked \
    --mount=type=cache,target=${CI_CARGO_HOME}/git,sharing=locked \
    bash /usr/local/bin/ci.sh rust-build ui "${RUST_CRATES}"

# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: bootstrap apk list, supplied from the SOT.
# Why: AG-REL-001 forbids ash; ci.sh apk-setup needs bash.
# From: Issue #1683 | PR #1912
ARG APK_BOOTSTRAP
RUN apk add --no-cache ${APK_BOOTSTRAP}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: retry and download bounds, SOT stage_variables
# Why: this stage has no SOT; ci.sh reads them from env
# From: Issue #1683 | PR #1858
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
ARG CI_DOWNLOAD_CONNECT_TIMEOUT
ARG CI_DOWNLOAD_STALL_SECONDS
# What: shared package setup via ci.sh.
# Why: ci.sh owns repos, proxy CA, update+upgrade, add.
# From: Issue #1683 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

# What: accounts and dirs of this image, from the SOT.
# Why: ci.sh creates them; the Dockerfile names none.
# From: Issue #1683 | PR #1912
ARG IMAGE_SETUP
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh image-setup

COPY --from=builder /build/lancache-ui-out /usr/local/bin/lancache-ui

# What: one runtime uid/gid for the user and the binary.
# Why: nginx logs share it; the root start drops to it.
# From: Issue #1427 | PR #1912
ARG LANCACHE_RUNTIME_GID
ENV LANCACHE_RUNTIME_GID=${LANCACHE_RUNTIME_GID}

# What: the SOT default values, one pipe-joined list.
# Why: ci.sh passes the list; binaries read it as env.
# From: Issue #1683 | PR #1912
ARG LANCACHE_RUNTIME_DEFAULTS
ENV LANCACHE_RUNTIME_DEFAULTS=${LANCACHE_RUNTIME_DEFAULTS}

# What: the UI listen port, from the SOT.
# Why: the validate step needs one exposed TCP port.
# From: Issue #1683 | PR #1912
ARG UI_LISTEN_PORT
EXPOSE ${UI_LISTEN_PORT}

# What: the binary, via PATH; it does the root start itself.
# Why: no wrapper; secrets, chown and uid drop are in Rust.
# From: Issue #858 | PR #1858
ENTRYPOINT ["lancache-ui"]
