
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

# What: upgrades base packages, installs curl + 9 other tools
# Why: apk installs register in the image's package db
# From: Issue #1781 | PR #1783
# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: without this, BuildKit cache has no wall-clock expiry.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
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
      ca-certificates

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
# Why: catches a broken/missing shared-lib chain at build time.
# From: Issue #1781
RUN curl --version >/dev/null
