
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: First-party netdata on Alpine with static musl
# Why: no Alpine image; static build works natively
# From: Issue #815

# What: base image, supplied by ci.sh from the SOT pin.
# Why: non-authoritative fallback keeps FROM valid (AG-CI-008).
# From: Issue #1683
ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="First-party Alpine + netdata's official static musl build, replacing the pulled third-party netdata/netdata (Debian) image."

# What: netdata version+arch+digest, supplied by ci.sh from SOT.
# Why: SOT owns external_versions.netdata; consumer bakes none.
# From: Issue #1683
ARG NETDATA_VERSION
ARG NETDATA_ARCH
ARG NETDATA_SHA256

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: install the pinned netdata static build for this arch.
# Why: one static .gz.run per arch; ci.sh selects the digest.
# From: Issue #1683
RUN set -eu; export TMPDIR=/var/tmp; \
    apk add --no-cache bash ca-certificates; \
    wget -q -O /var/tmp/netdata.gz.run \
      "https://github.com/netdata/netdata/releases/download/${NETDATA_VERSION}/netdata-${NETDATA_ARCH}-${NETDATA_VERSION}.gz.run"; \
    echo "${NETDATA_SHA256}  /var/tmp/netdata.gz.run" | sha256sum -c -; \
    chmod +x /var/tmp/netdata.gz.run; \
    /var/tmp/netdata.gz.run --accept -- --dont-start-it --disable-telemetry --stable-channel; \
    rm -f /var/tmp/netdata.gz.run; \
    rm -rf /var/tmp/netdata-updater* /var/tmp/netdata-installer*

EXPOSE 19999

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
