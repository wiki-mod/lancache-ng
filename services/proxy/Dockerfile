
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: proxy image: nginx cache for HTTP and HTTPS.
# Why: nginx is the only program; compose adds tini.
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
# What: accounts first, then packages, through ci.sh.
# Why: nginx keeps its SOT uid; its package reuses it.
# From: Issue #1683 | PR #2017
ARG IMAGE_SETUP
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh image-setup
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

# What: shared gid, SOT defaults and SOT schema.
# Why: the programs read them as env; compose names none.
# From: Issue #1683 | PR #1980
ARG LANCACHE_RUNTIME_GID
ARG LANCACHE_RUNTIME_DEFAULTS
ARG LANCACHE_RUNTIME_SCHEMA
ENV LANCACHE_RUNTIME_GID=${LANCACHE_RUNTIME_GID} \
    LANCACHE_RUNTIME_DEFAULTS=${LANCACHE_RUNTIME_DEFAULTS} \
    LANCACHE_RUNTIME_SCHEMA=${LANCACHE_RUNTIME_SCHEMA}

# What: links into NGINX_CONF_DIR; own nginx.conf loads.
# Why: module lines first, then the ui's live nginx.conf.
# From: Issue #1683 | PR #2017
RUN set -e; \
    declare -A v; IFS='|' read -ra kv <<< "${LANCACHE_RUNTIME_DEFAULTS}"; \
    for p in "${kv[@]}"; do v["${p%%=*}"]="${p#*=}"; done; \
    x() { local t="$1" k; \
      while [[ "${t}" =~ @([A-Z0-9_]+)@ ]]; do \
        k="${BASH_REMATCH[1]}"; t="${t//@${k}@/${v[${k}]}}"; \
      done; printf '%s' "${t}"; }; \
    src="$(x "${v[NGINX_DIR]}")"; dst="$(x "${v[NGINX_CONF_DIR]}")"; \
    for part in ${v[NGINX_LINK_PARTS]}; do \
      rm -rf "${src:?}/${part}"; ln -s "${dst}/${part}" "${src}/${part}"; \
    done; \
    rm -f "${src}/nginx.conf"; \
    printf 'include %s/modules/*.conf;\ninclude %s/nginx.conf;\n' \
      "${src}" "${dst}" > "${src}/nginx.conf"

# What: one supervise-daemon script per SOT process.
# Why: OpenRC restarts crashes; @KEY@ e.g. CONFIG_DIR.
# From: Issue #1683
ARG LANCACHE_PROCESSES
ARG LANCACHE_PROCESS_PRE
ARG LANCACHE_INIT_PRE
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh openrc-setup

# What: OpenRC as PID 1.
# Why: openrc-init reaps zombies and stops on SIGTERM.
# From: Issue #1683
ENTRYPOINT ["/usr/local/bin/lancache-init"]
