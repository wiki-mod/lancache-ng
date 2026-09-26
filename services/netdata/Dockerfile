
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: First-party netdata on Alpine with static musl
# Why: no Alpine image; static build works natively
# From: Issue #815

# What: base image pin, supplied by ci.sh from the SOT.
# Why: SOT base_images.alpine is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="First-party Alpine + netdata's official static musl build, replacing the pulled third-party netdata/netdata (Debian) image."

# What: netdata version+arch+digest, supplied by ci.sh from SOT.
# Why: SOT owns external_versions.netdata; consumer bakes none.
# From: Issue #1683
ARG NETDATA_VERSION
ARG NETDATA_ARCH
ARG NETDATA_SHA256

# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: bootstrap bash so the SHELL below is not busybox ash.
# Why: AG-REL-001 forbids ash; the installer RUN is bash logic.
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: shared apk setup (repo-http+update+upgrade+add) via ci.sh.
# Why: one owner for the mandatory update+upgrade; SOT owns packages.
# From: Issue #1683
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

# What: install the pinned netdata static build for this arch.
# Why: one static .gz.run per arch; ci.sh selects the digest.
# From: Issue #1683
RUN set -eu; export TMPDIR=/var/tmp; \
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
