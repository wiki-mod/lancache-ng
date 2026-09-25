
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks."

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: shared version-banner, not a per-service copy.
# Why: named build context avoids a per-service copy.
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: declares APT_CACHE_BUST before the busting RUN.
# Why: BuildKit cache has no wall-clock expiry.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: trust proxy CA, upgrade, apk install Kea + tools.
# Why: CA restored (no leak); lease-cmds hook separate.
# From: Issue #815
RUN --mount=type=secret,id=project_selfhosted_proxy_ca \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /var/tmp/ca-bundle.orig && \
      cat /run/secrets/project_selfhosted_proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && apk update --no-cache && apk upgrade --no-cache && apk add --no-cache \
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
    ripgrep && \
    if [ -s /run/secrets/project_selfhosted_proxy_ca ]; then mv /var/tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verify apk binaries execute, not just exist.
# Why: missing libs fail at runtime, not at apk add.
# From: Issue #1613 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    curl --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

ENV EDITOR=nano
ENV VISUAL=$EDITOR

# Config templates — expanded once into /var/lib/kea/ on first boot
COPY kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.template
COPY kea-ctrl-agent.conf /etc/kea/kea-ctrl-agent.conf.template
COPY kea-dhcp-ddns.conf /etc/kea/kea-dhcp-ddns.conf.template
COPY entrypoint.sh /entrypoint.sh

# What: /run/kea (mode 750) holds Kea control sockets.
# Why: internal control channels, no world access needed.
# From: Issue #1683
RUN chmod +x /entrypoint.sh && mkdir -p /var/lib/kea && install -d -m 750 /run/kea

# What: final apk upgrade pass, no packages added.
# Why: patches CVEs fixed after the installs above.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 67/udp 8000

ENTRYPOINT ["/entrypoint.sh"]
