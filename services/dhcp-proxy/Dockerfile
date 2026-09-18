
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine dnsmasq DHCP proxy image with bash/envsubst
# Why: entrypoint.sh requires Bash-specific syntax
# From: Issue #815

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

# What: shared version-banner script, no per-service copy.
# Why: build context avoids per-service duplication.
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: declares APT_CACHE_BUST before the RUN command.
# Why: BuildKit cache expires to ensure fresh updates.
# From: Issue #1095
ARG APT_CACHE_BUST=""

# What: apk upgrade base-layer pkgs, add findutils/coreutils
# Why: GNU find -printf, date for kgs snapshot logic
# From: Issue #840
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    dnsmasq \
    coreutils \
    nano \
    findutils \
    gettext-envsubst \
    lsof \
    ripgrep

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are apk-installed
# above but serve the same troubleshooting purpose.

# What: verifies apk binaries execute, not just exist.
# Why: library deps fail at runtime, not during apk add.
# From: Issue #1613 | Issue #1781 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY dnsmasq-relay.conf.template /etc/dnsmasq-relay.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# What: final apk upgrade pass, no packages added.
# Why: patches CVEs fixed after package installs.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
