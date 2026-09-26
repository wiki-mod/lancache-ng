# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine Kea DHCP suite; apk install image-local.
# Why: image-local apk; ci.sh builds via the generic path.
# From: Issue #815 | Issue #1683

# What: base image, supplied by ci.sh from the SOT pin.
# Why: non-authoritative fallback keeps FROM valid (AG-CI-008).
# From: Issue #1683
ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."

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
# What: image-local apk install of the Kea suite + tools.
# Why: http repos let Squid cache; signed indices keep integrity.
# From: Issue #815 | Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories \
    && : "apt-cache-bust=${APT_CACHE_BUST}" \
    && apk update --no-cache \
    && apk upgrade --no-cache \
    && apk add --no-cache \
        kea-dhcp4 \
        kea-ctrl-agent \
        kea-dhcp-ddns \
        kea-admin \
        kea-hook-lease-cmds \
        bash \
        nmap \
        openssl \
        jq \
        iptables \
        nano \
        curl \
        findutils \
        gettext-envsubst \
        lsof \
        ripgrep

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# What: Kea config templates, expanded on first boot.
# Why: entrypoint renders /var/lib/kea from these.
# From: Issue #815
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

# What: /run/kea (mode 750) + /var/lib/kea for Kea.
# Why: internal control sockets; no world access needed.
# From: Issue #1683
RUN mkdir -p /var/lib/kea && install -d -m 750 /run/kea

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
