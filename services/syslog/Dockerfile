
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Combined fluent-bit and syslog-ng logging
# Why: Alpine lacks fluent-bit; pin binary in prefix
# From: PR #1431

# What: base images, supplied by ci.sh from the SOT pins.
# Why: SOT base_images is the sole owner (AG-CI-006).
# From: Issue #1683
ARG ALPINE_IMAGE
ARG FLUENT_BIT_IMAGE
# What: scratch only when ci.sh passed no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${FLUENT_BIT_IMAGE:-scratch} AS fluent-bit-src

FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428)."

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY
# What: apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES
# What: Install bash before SHELL directive
# Why: AG-REL-001 forbids ash; ci.sh needs bash
# From: Issue #1683
RUN apk add --no-cache bash
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# What: retry policy for ci.sh, from SOT stage_variables
# Why: this stage has no SOT; ci.sh reads them from env
# From: Issue #1683 | PR #1858
ARG CI_RETRY_MAX_ATTEMPTS
ARG CI_RETRY_BACKOFF_BASE_SECONDS
# What: shared apk setup via ci.sh
# Why: centralized owner for upgrade/package add
# From: Issue #1428
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

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

# What: Resolve glibc dynamic linker path
# Why: Filename varies by arch; must be executable
# From: Issue #1428
RUN set -- /opt/fluent-bit-glibc/lib/ld-linux-*.so.* \
    && [ -e "$1" ] \
    && ld_interp="$(basename "$1")" \
    && echo "$ld_interp" > /opt/fluent-bit-glibc/ld-interp-name \
    && chmod +x "/opt/fluent-bit-glibc/lib/$ld_interp" /opt/fluent-bit-glibc/bin/fluent-bit \
    && chown -R lancache:lancache /opt/fluent-bit-glibc

USER lancache:lancache

# What: Expose syslog-ng (6601) and fluent-bit (2020)
# Why: Port 601 requires root; container lacks CAP
# From: Issue #1428
EXPOSE 6601/tcp 2020/tcp

# What: Single HEALTHCHECK for both services
# Why: One slot; script checks both processes
# From: Issue #1428
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
