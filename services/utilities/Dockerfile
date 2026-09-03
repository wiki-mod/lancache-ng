
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: shared image with curl + 9 CLI tools, COPY --from=.
# Why: avoids each service installing its own copy.
# From: Issue #1556

# What: reverts the self-compiled static curl-builder stage
# Why: curl is apk-installed with the other 9 tools
# From: Issue #1781 | PR #1783
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# What: explicit proxy build-args, no default value set
# Why: routes self-hosted downloads via the LAN proxy
# From: Issue #1781 | PR #1783
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# What: upgrades base packages, installs curl + 9 other tools
# Why: apk installs register in the image's package db
# From: Issue #1781 | PR #1783
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit cache has no wall-clock expiry.
# From: Issue #1095
ARG APT_CACHE_BUST=""
# What: trusts the proxy's CA for this RUN, never in a layer.
# Why: a secret mount never persists; bundle restored below.
# From: Issue #1781 | PR #1783
RUN --mount=type=secret,id=proxy_ca \
    if [ -s /run/secrets/proxy_ca ]; then \
      cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-bundle.orig && \
      cat /run/secrets/proxy_ca >> /etc/ssl/certs/ca-certificates.crt; \
    fi && \
    : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
      curl \
      nano \
      lsof \
      ripgrep \
      findutils \
      coreutils \
      gettext-envsubst \
      jq \
      zstd \
      ca-certificates && \
    if [ -s /run/secrets/proxy_ca ]; then mv /tmp/ca-bundle.orig /etc/ssl/certs/ca-certificates.crt; fi

# What: verifies coreutils/findutils commands still resolve.
# Why: coreutils overwrites some BusyBox symlinks.
# From: Issue #1556
RUN set -euo pipefail; \
    for expected in basename cp date dirname install mktemp mv rm sort realpath base64 od find xargs; do \
      command -v "$expected" >/dev/null 2>&1 || { echo "ERROR: expected coreutils/findutils binary missing: $expected" >&2; exit 1; }; \
    done

# What: ships the shared version-banner smoke check.
# Why: dedupes the lsof-banner check six Dockerfiles carried.
# From: Issue #1613
COPY verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: verifies the apk-packaged curl actually runs.
# Why: catches broken shared libs at build, not runtime exec.
# From: Issue #1781
RUN curl --version >/dev/null
