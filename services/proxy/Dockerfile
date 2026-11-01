
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: nginx caching proxy, nginx is PID 1.
# Why: nginx.org has stream; the ui renders the config.
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
# What: apk packages, nginx.org repo and key from the SOT.
# Why: the SOT owns them; this stage only consumes them.
# From: Issue #1683 | PR #1858
ARG APK_PACKAGES
ARG APK_TAGGED_REPOS
ARG APK_KEYS
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
# Why: ci.sh owns repos, keys, proxy CA and apk steps.
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

# What: the SOT default values, one pipe-joined list.
# Why: ci.sh passes the list; binaries read it as env.
# From: Issue #1683 | PR #1912
ARG LANCACHE_RUNTIME_DEFAULTS
ENV LANCACHE_RUNTIME_DEFAULTS=${LANCACHE_RUNTIME_DEFAULTS}

# What: nginx in the foreground as PID 1.
# Why: config comes from the ui volume; HUP reloads it.
# From: Issue #1683 | PR #1858
ENTRYPOINT ["nginx", "-g", "daemon off;"]
