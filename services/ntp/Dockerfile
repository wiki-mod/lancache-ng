# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine chrony NTP server for LAN clients on UDP/123.
# Why: image-local apk install; ci.sh builds via the generic path.
# From: Issue #815 | Issue #1683

# What: base image, supplied by ci.sh from the SOT pin.
# Why: non-authoritative fallback keeps FROM valid (AG-CI-008).
# From: Issue #1683
ARG ALPINE_IMAGE=alpine:3.24
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
# What: image-local apk install of the chrony runtime deps.
# Why: http repos let Squid cache; signed indices keep integrity.
# From: Issue #815 | Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories \
    && : "apt-cache-bust=${APT_CACHE_BUST}" \
    && apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        ca-certificates \
        chrony-nts \
        curl \
        gettext-envsubst

COPY services/ntp/chrony.conf /etc/chrony/chrony.conf.template
COPY services/ntp/entrypoint.sh /entrypoint.sh

# What: chrony log and lib dirs; entrypoint drops privileges.
# Why: chronyd needs root for UDP/123; dirs pre-created here.
# From: Issue #815
RUN mkdir -p /var/lib/chrony /var/log/chrony

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
