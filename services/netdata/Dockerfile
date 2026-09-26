
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: First-party netdata on Alpine with static musl
# Why: no Alpine image; static build works natively
# From: Issue #815

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE
FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="First-party Alpine + netdata's official static musl build, replacing the pulled third-party netdata/netdata (Debian) image."

# What: curl 8.20.0 bundled in netdata static build
# Why: Trivy cannot detect curl; check-pin enforces version
# From: Issue #1304 | PR #1662
ARG NETDATA_VERSION=v2.11.0
ARG NETDATA_X86_64_SHA256=b42d9937807f28812502a967906d370cff9ab443453813656b99ff6a9b3c5649
# What: arm64 static-build checksum from SOT
# Why: both architectures required; SOT carries this value
# From: Issue #1683
ARG NETDATA_AARCH64_SHA256=8cd056d64078c109409c08e30d55324c82e3855f9d8e4b304cacc7c612610e09

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: select netdata release asset by architecture
# Why: one static .gz.run per arch; no apk package
# From: Issue #1683
RUN set -eu; export TMPDIR=/var/tmp; \
    apk add --no-cache bash ca-certificates; \
    case "$(uname -m)" in \
      x86_64) netdata_arch="x86_64"; netdata_sha256="${NETDATA_X86_64_SHA256}"; ;; \
      aarch64) netdata_arch="aarch64"; netdata_sha256="${NETDATA_AARCH64_SHA256}"; ;; \
      *) echo "Unsupported architecture for netdata static build: $(uname -m)" >&2; exit 1; ;; \
    esac; \
    wget -q -O /var/tmp/netdata.gz.run \
      "https://github.com/netdata/netdata/releases/download/${NETDATA_VERSION}/netdata-${netdata_arch}-${NETDATA_VERSION}.gz.run"; \
    echo "${netdata_sha256}  /var/tmp/netdata.gz.run" | sha256sum -c -; \
    chmod +x /var/tmp/netdata.gz.run; \
    /var/tmp/netdata.gz.run --accept -- --dont-start-it --disable-telemetry --stable-channel; \
    rm -f /var/tmp/netdata.gz.run; \
    rm -rf /var/tmp/netdata-updater* /var/tmp/netdata-installer*

EXPOSE 19999

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
