# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine chrony NTP; apk install orchestrated by ci.sh.
# Why: ci.sh owns apk/CA/smoke policy; Dockerfile orchestrates.
# From: Issue #815 | Issue #1683

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="LanCache-NG-NTP: chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123."

# What: explicit proxy build-args, no default value set.
# Why: routes self-hosted downloads via the LAN proxy.
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
# What: bootstrap bash, then ci.sh owns the apk install.
# Why: ci.sh is the one apk/CA/smoke owner; needs the bash engine.
# From: Issue #1683 | Issue #1095 | Issue #1781
RUN --mount=type=bind,source=.github/scripts/ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=bind,source=.github/yaml/build-manifest.yml,target=/usr/local/share/ci/build-manifest.yml \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    sed -i 's|^https://|http://|' /etc/apk/repositories \
    && apk add --no-cache bash \
    && : "apt-cache-bust=${APT_CACHE_BUST}" \
    && CI_MANIFEST=/usr/local/share/ci/build-manifest.yml bash /usr/local/bin/ci.sh apk-build ntp

COPY services/ntp/chrony.conf /etc/chrony/chrony.conf.template
COPY services/ntp/entrypoint.sh /entrypoint.sh

# What: chrony log and lib dirs; entrypoint drops privileges.
# Why: chronyd needs root for UDP/123; dirs pre-created here.
# From: Issue #815
RUN mkdir -p /var/lib/chrony /var/log/chrony

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
