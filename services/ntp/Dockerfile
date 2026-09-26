# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine chrony NTP server for LAN clients on UDP/123.
# Why: image-local apk install; ci.sh builds via the generic path.
# From: Issue #815 | Issue #1683

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="LanCache-NG-NTP: chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123."

# What: explicit proxy build-args, no default value set.
# Why: routes self-hosted apk fetches via the LAN proxy.
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: APT_CACHE_BUST invalidates BuildKit's apk layer cache.
# Why: without it BuildKit replays a stale layer forever.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: bootstrap bash so the SHELL below is not busybox ash.
# Why: AG-REL-001 forbids ash; ci.sh apk-setup needs bash.
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: shared apk setup (repo-http+update+upgrade+add) via ci.sh.
# Why: one owner for the mandatory update+upgrade; SOT owns packages.
# From: Issue #815 | Issue #1683
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    : "apt-cache-bust=${APT_CACHE_BUST}" \
    && bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

COPY chrony.conf /etc/chrony/chrony.conf.template
COPY entrypoint.sh /entrypoint.sh

# What: chrony log and lib dirs; entrypoint drops privileges.
# Why: chronyd needs root for UDP/123; dirs pre-created here.
# From: Issue #815
RUN mkdir -p /var/lib/chrony /var/log/chrony

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
