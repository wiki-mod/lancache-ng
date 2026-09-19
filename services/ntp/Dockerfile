
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine chrony NTP (chrony-nts, bash, envsubst)
# Why: C daemon; no Rust builder; Alpine package splits
# From: Issue #815

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="LanCache-NG-NTP: chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy


# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: APT_CACHE_BUST invalidates BuildKit's upgrade cache.
# Why: without this, BuildKit replays stale cache forever.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: trust proxy CA for this RUN, restore after
# Why: secret mount never persists; temporary trust only
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    ca-certificates \
    chrony-nts \
    curl \
    gettext-envsubst && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verify apk binaries execute, not just exist
# Why: library deps fail at runtime, not during apk add
# From: Issue #1613 | Issue #1781 | PR #1783
RUN set -euo pipefail; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    curl --version >/dev/null

COPY chrony.conf /etc/chrony/chrony.conf.template
COPY entrypoint.sh /entrypoint.sh

# What: chmod entrypoint.sh; mkdir chrony log and lib
# Why: chronyd needs root for UDP/123; drops to chrony user
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/lib/chrony /var/log/chrony

# What: final apk upgrade pass, no packages added.
# Why: patches CVEs fixed after package installs
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
