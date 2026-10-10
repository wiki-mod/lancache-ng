
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: PowerDNS, nats-subscriber and Lua RPZ on Alpine.
# Why: record ingest ships in the same image as the DNS.

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
FROM ${BUILD_TOOLS_IMAGE:-scratch} AS subscriber-builder

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
# What: compiler VAR=driver pairs, supplied by ci.sh.
# Why: the builder has no SOT; rust-build reads the env.
# From: Issue #1683 | PR #1858
ARG CI_TOOLCHAIN_COMPILERS

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY services/dns/nats-subscriber/Cargo.toml services/dns/nats-subscriber/Cargo.toml
COPY services/ui/Cargo.toml services/ui/Cargo.toml
COPY services/cachehamster/Cargo.toml services/cachehamster/Cargo.toml
COPY services/watchdog/Cargo.toml services/watchdog/Cargo.toml
# What: shared crate manifest and sources, copied whole.
# Why: real sources before any build; no stale stub rlib.
# From: Issue #1683 | PR #1858
COPY services/common services/common
COPY services/dns/nats-subscriber/src services/dns/nats-subscriber/src
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
    bash /usr/local/bin/ci.sh rust-build dns "${RUST_CRATE}"

# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="PowerDNS recursor, authoritative DNS, and NATS subscriber service for lancache-ng cache routing."

# What: dns owns domain-validation.sh; copied from its dir.
# Why: dns is the arch owner; no shared-scripts indirection.
# From: Issue #1683
COPY services/dns/domain-validation.sh /usr/local/lib/domain-validation.sh
# What: copy the shared-secret bootstrap lib.
# Why: entrypoint uses it; no duplicate copy.
# From: Issue #1683
COPY --from=shared-secret shared-secret-bootstrap.sh /usr/local/lib/shared-secret-bootstrap.sh
# What: copy the known-good-snapshot library.
# Why: entrypoint uses it; no duplicate copy.
# From: Issue #1683
COPY --from=known-good known-good-snapshots.sh /usr/local/lib/known-good-snapshots.sh

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: bootstrap bash for SHELL compatibility.
# Why: AG-REL-001 forbids ash; ci.sh apk-setup needs bash.
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

# What: pdns user/group comes from the package pre-install.
# Why: no separate useradd step is needed on Alpine.
# From: Issue #815
RUN mkdir -p /etc/pdns/auth /var/lib/powerdns /var/run/pdns \
    && chown -R pdns:pdns /var/lib/powerdns /var/run/pdns

COPY --from=subscriber-builder /build/nats-subscriber-out /usr/local/bin/nats-subscriber

COPY services/dns/recursor.conf.template /etc/pdns/recursor.conf.template
COPY services/dns/pdns.conf.template /etc/pdns/auth/pdns.conf.template
COPY services/dns/recursor.lua /etc/pdns/recursor.lua
COPY services/dns/filter-aaaa.lua /etc/pdns/filter-aaaa.lua
COPY services/dns/cdn-domains.txt /etc/pdns/cdn-domains.txt
# What: vendored gsqlite3 schema for pdns-backend-sqlite3.
# Why: the Alpine package ships no schema file.
# From: Issue #815
COPY services/dns/schema.sqlite3.sql /usr/share/lancache-ng/schema.sqlite3.sql
COPY services/dns/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 53/udp 53/tcp 8081 8082 8083

ENTRYPOINT ["/entrypoint.sh"]
