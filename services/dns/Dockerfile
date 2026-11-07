
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: dns image: PowerDNS auth and two recursors.
# Why: OpenRC keeps each SOT process alive.
# From: Issue #1683 | PR #1980

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: final image on the SOT Alpine pin.
# Why: scratch only fails a build without the arg.
# From: Issue #1683 | PR #1980
FROM ${ALPINE_IMAGE:-scratch}

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale layer.
# From: Issue #1683 | PR #1980
ARG BUILD_IDENTITY
ARG APK_PACKAGES
ARG APK_BOOTSTRAP
# What: bash first; every later RUN uses it.
# Why: ci.sh is bash; ash is not allowed.
# From: Issue #1683 | PR #1980
RUN apk add --no-cache ${APK_BOOTSTRAP}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
ARG CI_DOWNLOAD_CONNECT_TIMEOUT
ARG CI_DOWNLOAD_STALL_SECONDS
# What: packages and accounts through ci.sh.
# Why: ci.sh owns repos, proxy CA, users and dirs.
# From: Issue #1683 | PR #1980
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}
ARG IMAGE_SETUP
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh image-setup

# What: shared gid, SOT defaults and SOT schema.
# Why: the programs read them as env; compose names none.
# From: Issue #1683 | PR #1980
ARG LANCACHE_RUNTIME_GID
ARG LANCACHE_RUNTIME_DEFAULTS
ARG LANCACHE_RUNTIME_SCHEMA
ENV LANCACHE_RUNTIME_GID=${LANCACHE_RUNTIME_GID} \
    LANCACHE_RUNTIME_DEFAULTS=${LANCACHE_RUNTIME_DEFAULTS} \
    LANCACHE_RUNTIME_SCHEMA=${LANCACHE_RUNTIME_SCHEMA}

# What: one supervise-daemon script per SOT process.
# Why: OpenRC restarts crashes; @KEY@ e.g. CONFIG_DIR.
# From: Issue #1683 | PR #1980
ARG LANCACHE_PROCESSES
ARG LANCACHE_PROCESS_PRE
ARG LANCACHE_INIT_PRE
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh openrc-setup

# What: OpenRC as PID 1; compose may name a runlevel.
# Why: openrc-init reaps zombies and stops on SIGTERM.
# From: Issue #1683 | PR #1980
ENTRYPOINT ["/usr/local/bin/lancache-init"]
