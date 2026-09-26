# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine dnsmasq DHCP proxy; apk install image-local.
# Why: image-local apk; ci.sh builds via the generic path.
# From: Issue #815 | Issue #1683

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

# What: APT_CACHE_BUST invalidates BuildKit's apk layer cache.
# Why: without it BuildKit replays a stale layer forever.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: image-local apk install of the SOT-listed dnsmasq + tools.
# Why: http repos let Squid cache; GNU find/date for kgs logic.
# From: Issue #815 | Issue #840 | Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories \
    && : "apt-cache-bust=${APT_CACHE_BUST}" \
    && apk update --no-cache \
    && apk upgrade --no-cache \
    && apk add --no-cache ${APK_PACKAGES}

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# What: dnsmasq relay/proxy config templates.
# Why: entrypoint renders the active one on first boot.
# From: Issue #815
COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY dnsmasq-relay.conf.template /etc/dnsmasq-relay.conf.template
COPY entrypoint.sh /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
