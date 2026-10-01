# syntax=docker/dockerfile:1
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Admin UI: Rust binary + Tera templates on Alpine.

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE

# What: builder image, supplied by ci.sh from the SOT.
# Why: no mutable default; CI resolves the immutable ref.
# From: Issue #1683
ARG BUILD_TOOLS_IMAGE
FROM ${BUILD_TOOLS_IMAGE} AS builder

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

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
COPY tools/pxe-client-probe/Cargo.toml tools/pxe-client-probe/Cargo.toml
# What: stub targets for workspace members not built here.
# Why: cargo loads every member manifest to resolve deps.
# From: Issue #1095
RUN mkdir -p services/watchdog/src services/cachehamster/src \
      services/dns/nats-subscriber/src tools/pxe-client-probe/src \
    && printf 'fn main() {}\n' > services/watchdog/src/main.rs \
    && : > services/watchdog/src/lib.rs \
    && printf 'fn main() {}\n' > services/cachehamster/src/main.rs \
    && : > services/cachehamster/src/lib.rs \
    && printf 'fn main() {}\n' > services/dns/nats-subscriber/src/main.rs \
    && : > services/dns/nats-subscriber/src/lib.rs \
    && printf 'fn main() {}\n' > tools/pxe-client-probe/src/main.rs
# What: dep pre-cache: compile deps against a stub ui src.
# Why: layer-caches deps so only real src changes rebuild.
# From: Issue #1533
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    mkdir -p services/ui/src \
    && printf 'fn main() {}\n' > services/ui/src/main.rs \
    && : > services/ui/src/lib.rs \
    && bash /usr/local/bin/ci.sh rust-build ui "${RUST_CRATE}" deps \
    && rm -rf services/ui/src
COPY services/ui/src ./services/ui/src
# What: ci.sh owns the rust build accel policy (one owner).
# Why: AG-CI-005/022/023; bind-mounted, never baked in.
# From: Issue #1683
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=sccache_redis_url \
    --mount=type=secret,id=sccache_dist_config \
    --mount=type=secret,id=distcc_potential_hosts \
    --mount=type=secret,id=ccache_redis_url \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh rust-build ui "${RUST_CRATE}"

FROM ${ALPINE_IMAGE}

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
# What: Setup proxy CA and packages with apk
# Why: CA restored; mandatory update+upgrade required
# From: Issue #1683
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    sed -i 's|^https://|http://|' /etc/apk/repositories && \
    apk update --no-cache && \
    apk upgrade --no-cache && \
    apk add --no-cache ${APK_PACKAGES} && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY --from=builder /build/lancache-ui-out /usr/local/bin/lancache-ui
COPY services/ui/src/templates /templates

# What: the one ui runtime uid/gid (10001) for user and binary.
# Why: nginx logs share this gid; the root start drops to it.
# From: Issue #1427 | PR #1858
ARG UI_RUNTIME_ID=10001
ENV UI_RUNTIME_UID=${UI_RUNTIME_ID} \
    UI_RUNTIME_GID=${UI_RUNTIME_ID}
RUN addgroup -g "${UI_RUNTIME_ID}" lancache \
    && adduser -D -H -u "${UI_RUNTIME_ID}" -G lancache -s /sbin/nologin lancache \
    && mkdir -p /data /etc/nats \
    && chown -R lancache:lancache /data /etc/nats

# What: fail build if CI proxy CA leaked into image
# Why: CA must never persist in a published service image
# From: Issue #1781 | PR #1783
RUN if [ -e /usr/local/share/ca-certificates/lancache-ci-proxy-ca.crt ]; then \
      echo "SECURITY: CI proxy CA persisted in final image" >&2; exit 1; \
    fi

EXPOSE 8080

# What: the binary, via PATH; it does the root start itself.
# Why: no wrapper; secrets, chown and uid drop are in Rust.
# From: Issue #858 | PR #1858
ENTRYPOINT ["lancache-ui"]
