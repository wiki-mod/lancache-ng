
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
# What: extra apk repos and keys (nginx.org), from SOT.
# Why: apk-setup reads them; empty for other images.
# From: Issue #1683 | PR #1980
ARG APK_TAGGED_REPOS
ARG APK_KEYS
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

# What: NGINX_LINK_PARTS point into NGINX_CONF_DIR.
# Why: ui renders them; plain nginx -t sees the live file
# From: Issue #1683 | PR #1980
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
    done

# What: nginx in the foreground as the main program.
# Why: a crash ends the container; Docker restarts it.
# From: Issue #1683 | PR #1980
ENTRYPOINT ["nginx", "-g", "daemon off;"]
