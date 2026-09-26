# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Combined fluent-bit + syslog-ng central logging.
# Why: Alpine lacks fluent-bit; pin its binary in a prefix.
# From: Issue #1428 | PR #1431 | Issue #1683

# What: base images, supplied by ci.sh from the SOT pins.
# Why: SOT base_images is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
ARG FLUENT_BIT_IMAGE
FROM ${FLUENT_BIT_IMAGE} AS fluent-bit-src

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428)."

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
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: bootstrap bash so the SHELL below is not busybox ash.
# Why: AG-REL-001 forbids ash; ci.sh apk-setup needs bash.
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: shared apk setup (repo-http+update+upgrade+add) via ci.sh.
# Why: one owner for the mandatory update+upgrade; SOT owns packages.
# From: Issue #1428 | Issue #1095
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    : "apt-cache-bust=${APT_CACHE_BUST}" \
    && bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

# What: fixed uid/gid 10001 + writable dirs for syslog-ng.
# Why: service reads files as non-root; dirs must pre-exist.
# From: Issue #1428 | PR #1431
RUN addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache lancache \
    && mkdir -p /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache \
    && chown -R lancache:lancache /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache

# What: pinned fluent-bit binary + its glibc libs, isolated.
# Why: glob *-linux-gnu handles both amd64 and arm64 paths.
# From: Issue #1428 | PR #1431
COPY --from=fluent-bit-src /fluent-bit/bin/fluent-bit /opt/fluent-bit-glibc/bin/fluent-bit
COPY --from=fluent-bit-src /lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/
COPY --from=fluent-bit-src /usr/lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/

COPY fluent-bit.conf /etc/fluent-bit/fluent-bit.conf
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY data-loss-detector.sh /usr/local/bin/data-loss-detector.sh

# What: resolve the glibc dynamic linker; own the prefix.
# Why: interpreter filename varies by arch; must be executable.
# From: Issue #1428 | PR #1431
RUN ld_interp="$(basename "$(ls /opt/fluent-bit-glibc/lib/ld-linux-*.so.* | head -n1)")" \
    && echo "$ld_interp" > /opt/fluent-bit-glibc/ld-interp-name \
    && chmod +x "/opt/fluent-bit-glibc/lib/$ld_interp" /opt/fluent-bit-glibc/bin/fluent-bit \
    && chown -R lancache:lancache /opt/fluent-bit-glibc

USER lancache:lancache

# What: syslog-ng receiver on 6601; fluent-bit http on 2020.
# Why: 601 is privileged; container lacks CAP_NET_BIND_SERVICE.
# From: Issue #1428 | PR #1431
EXPOSE 6601/tcp 2020/tcp

# What: single HEALTHCHECK verifies fluent-bit + syslog-ng.
# Why: one slot; healthcheck.sh checks both processes.
# From: Issue #1428 | PR #1431
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
