
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Combined fluent-bit + syslog-ng container.
# Why: Accept crash-coupling/single-HEALTHCHECK tradeoff.
# From: Issue #1428 | PR #1431

# What: Pinned fluent-bit binary + glibc in isolated prefix.
# Why: Alpine stable lacks fluent-bit; isolated is safer.
# From: Issue #1428 | PR #1431

# What: Base image pins, consumed from version SOT.
# Why: build-manifest.yml is sole owner of both pins.
# From: Issue #1683
ARG ALPINE_IMAGE
ARG FLUENT_BIT_IMAGE
FROM ${FLUENT_BIT_IMAGE} AS fluent-bit-src

FROM ${ALPINE_IMAGE}

LABEL org.opencontainers.image.description="Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428)."

# What: Install syslog-ng and bash for core services.
# Why: syslog-ng in Alpine; bash for entrypoint supervision.
# From: Issue #1428 | PR #1431 | AG-REL-006

# What: Alpine base pin updated from 3.20 to 3.24.
# Why: Consistency with other services' Alpine 3.24 pin.
# From: Issue #1554 | PR #1555

# What: Switch apk repositories to plain http.
# Why: Squid proxy caches http; signing keeps integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: Declare APT_CACHE_BUST for this RUN block.
# Why: Prevents stale apk index replay on rebuild.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
        syslog-ng \
        syslog-ng-json \
        bash \
        zstd \
        tzdata \
        # What: Fixed uid/gid 10001 for syslog-ng user.
    # Why: Service needs to read files as non-root.
    # From: Issue #1428 | PR #1431
    && addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache lancache \
    && mkdir -p /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache \
    && chown -R lancache:lancache /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache
# What: Pre-create log and syslog-ng config directories.
# Why: Lancache user needs writable paths; prevent loss.
# From: Issue #1428 | PR #1431

# What: Glob *-linux-gnu paths for multiarch support.
# Why: Hardcoded path failed on arm64; glob works both.
# From: Issue #1428 | PR #1431
COPY --from=fluent-bit-src /fluent-bit/bin/fluent-bit /opt/fluent-bit-glibc/bin/fluent-bit
COPY --from=fluent-bit-src /lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/
COPY --from=fluent-bit-src /usr/lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/

COPY fluent-bit.conf /etc/fluent-bit/fluent-bit.conf
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY data-loss-detector.sh /usr/local/bin/data-loss-detector.sh

# What: Prepare fluent-bit binary for execution.
# Why: Dynamic linker varies by arch; make unprivileged.
# From: Issue #1428 | PR #1431
RUN chmod 755 /entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/data-loss-detector.sh \
        # discovers the dynamic-linker interpreter filename.
    && ld_interp="$(basename "$(ls /opt/fluent-bit-glibc/lib/ld-linux-*.so.* | head -n1)")" \
    && echo "$ld_interp" > /opt/fluent-bit-glibc/ld-interp-name \
    && chmod +x "/opt/fluent-bit-glibc/lib/$ld_interp" /opt/fluent-bit-glibc/bin/fluent-bit \
    && chown -R lancache:lancache /opt/fluent-bit-glibc

USER lancache:lancache

# What: syslog-ng receiver on port 6601 (not 601).
# Why: 601 privileged; container lacks CAP_NET_BIND_SERVICE.
# From: Issue #1428 | PR #1431
EXPOSE 6601/tcp 2020/tcp

# What: Healthcheck verifies fluent-bit and syslog-ng.
# Why: Single HEALTHCHECK slot; see healthcheck.sh logic.
# From: Issue #1428 | PR #1431
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
