
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: dhcp image: Kea or dnsmasq, picked by runlevel.
# Why: compose passes DHCP_MODE as the runlevel.
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
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh openrc-setup

# What: start script: seed /run, runlevel from mode.
# Why: /run is tmpfs; the image dirs must be put back.
# From: Issue #1683 | PR #1980
RUN set -e; \
    declare -A v; IFS='|' read -ra kv <<< "${LANCACHE_RUNTIME_DEFAULTS}"; \
    for p in "${kv[@]}"; do v["${p%%=*}"]="${p#*=}"; done; \
    : "${v[OPENRC_STATE_DIR]:?}" "${v[KEA_SOCKET_DIR]:?}" "${v[KEA_SOCKET_DIR_MODE]:?}" "${v[RUN_DIR]:?}"; \
    tar -C "${v[RUN_DIR]}" -cpf "${v[RUN_DIR]}.tar" .; \
    f="${v[DHCP_MODE_FILE]}"; \
    while [[ "${f}" =~ @([A-Z0-9_]+)@ ]]; do \
      k="${BASH_REMATCH[1]}"; f="${f//@${k}@/${v[${k}]}}"; \
    done; \
    printf '%s\n' '#!/bin/bash' \
      "tar -C '${v[RUN_DIR]}' -xpf '${v[RUN_DIR]}.tar'" \
      "rm -rf '${v[OPENRC_STATE_DIR]}'; rm -f '${v[KEA_SOCKET_DIR]}'/*.pid" \
      "mkdir -p '${v[KEA_SOCKET_DIR]}'; chmod '${v[KEA_SOCKET_DIR_MODE]}' '${v[KEA_SOCKET_DIR]}'" \
      "mode=\"\$(cat '${f}' 2>/dev/null || true)\"" \
      "exec openrc-init \"\${mode:-${v[DHCP_MODE]}}\"" \
      > /usr/local/bin/lancache-init; \
    chmod 0755 /usr/local/bin/lancache-init

# What: the start script runs openrc-init as PID 1.
# Why: exec keeps zombie reaping and SIGTERM stop.
# From: Issue #1683 | PR #1980
ENTRYPOINT ["/usr/local/bin/lancache-init"]
