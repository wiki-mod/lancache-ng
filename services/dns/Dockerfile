
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: PowerDNS auth, two recursors, chrony on Alpine.
# Why: OpenRC (Alpine init.d) starts every program.
# From: Issue #1683

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE

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

# What: OpenRC services of this image, from the SOT.
# Why: package init.d scripts start them; no own starter.
# From: Issue #1683 | PR #1858
ARG OPENRC_SERVICES
RUN sed -i 's/^#\?rc_sys=.*/rc_sys="docker"/' /etc/rc.conf \
 && for s in ${OPENRC_SERVICES}; do rc-update add "$s" default; done

# What: the shared gid of the stack's secret files.
# Why: ci.sh passes it from the SOT; compose names none.
# From: Issue #1683 | PR #1912
ARG LANCACHE_RUNTIME_GID
ENV LANCACHE_RUNTIME_GID=${LANCACHE_RUNTIME_GID}

# What: the SOT default values, one pipe-joined list.
# Why: ci.sh passes the list; binaries read it as env.
# From: Issue #1683 | PR #1912
ARG LANCACHE_RUNTIME_DEFAULTS
ENV LANCACHE_RUNTIME_DEFAULTS=${LANCACHE_RUNTIME_DEFAULTS}

# What: OpenRC as PID 1.
# Why: native init; reaps children and stops on SIGTERM.
# From: Issue #1683 | PR #1858
ENTRYPOINT ["/sbin/openrc-init"]
