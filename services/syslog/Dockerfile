
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: combined fluent-bit + syslog-ng container, replacing two separate
# services (`syslog`=fluent-bit, `syslog-ng`=central receiver).
# Why: the maintainer accepted crash-coupling/one-HEALTHCHECK-slot/no-
# independent-restart trade-offs for one image instead of two.
# From: Issue #1428 | PR #1431
#
# What: copies the pinned fluent-bit binary + glibc closure into a
# private prefix, execed via an explicit ld-linux interpreter argument.
# Why: Alpine stable never packages fluent-bit (only edge's unpinnable
# repo); an isolated closure avoids gcompat's known gaps for this binary.
# From: Issue #1428 | PR #1431
FROM cr.fluentbit.io/fluent/fluent-bit:3.2.10@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562 AS fluent-bit-src

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428)."

# syslog-ng ships in Alpine's STABLE main repo (confirmed live: 4.7.1-r1) --
# the POC's own Dockerfile comment already established this; only fluent-bit
# needed the edge/testing repo, which this image never touches. bash is this
# project's default shell (AG-REL-006) and provides `wait -n` for
# entrypoint.sh's fail-fast multi-child supervision; su-exec is NOT used here
# (see the capability-posture comment on the fluent-bit interpreter's setcap
# step below for why a runtime privilege-drop design was tried and rejected).
#
# What: pins the Alpine base to 3.24 (was 3.20).
# Why: 3.20 was an unintentional scaffold-commit inconsistency -- every
# other first-party service already pins 3.24.
# From: Issue #1554 | PR #1555
RUN apk add --no-cache \
        syslog-ng \
        syslog-ng-json \
        bash \
        zstd \
        tzdata \
    # What: fixed uid/gid 10001, matching services/ui/Dockerfile's identity.
    # Why: syslog-ng writes files this uid needs to read back
    # (SYSLOG_NG_LOG_DIR); matching identities avoids a group workaround.
    # From: Issue #1428 | PR #1431
    && addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache lancache \
    && mkdir -p /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache \
    && chown -R lancache:lancache /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache
# What: pre-creates+chowns `/data`, `/var/log/lancache` (named volumes) and
# `/var/log/lancache-syslog-ng` (bind mount, SYSLOG_NG_LOG_DIR).
# Why: an image-absent path becomes an unwritable root:root dir for uid
# 10001 -- the bind-mount case is the bug data-loss-detector.sh guards.
# From: Issue #1428 | PR #1431

# What: globs the `*-linux-gnu` triplet directory instead of hardcoding
# either arch's name, matching both amd64 and arm64 unmodified.
# Why: an earlier hardcoded x86_64-linux-gnu path failed closed on arm64;
# Docker's COPY --from pattern matches via Go's filepath.Match per segment.
# From: Issue #1428 | PR #1431
COPY --from=fluent-bit-src /fluent-bit/bin/fluent-bit /opt/fluent-bit-glibc/bin/fluent-bit
COPY --from=fluent-bit-src /lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/
COPY --from=fluent-bit-src /usr/lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/

COPY fluent-bit.conf /etc/fluent-bit/fluent-bit.conf
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY data-loss-detector.sh /usr/local/bin/data-loss-detector.sh

RUN chmod 755 /entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/data-loss-detector.sh \
    # What: discovers the dynamic-linker interpreter's real filename
    # instead of hardcoding an arch (see the COPY step's own comment).
    # Why: an empty glob makes `ls` exit non-zero, aborting this `set -e`
    # RUN loudly rather than silently proceeding with no interpreter.
    # From: Issue #1428 | PR #1431
    && ld_interp="$(basename "$(ls /opt/fluent-bit-glibc/lib/ld-linux-*.so.* | head -n1)")" \
    && echo "$ld_interp" > /opt/fluent-bit-glibc/ld-interp-name \
    && chmod +x "/opt/fluent-bit-glibc/lib/$ld_interp" /opt/fluent-bit-glibc/bin/fluent-bit \
    && chown -R lancache:lancache /opt/fluent-bit-glibc \
    # What: runs entirely as fixed non-root uid 10001 (su-exec rejected).
    # Why: su-exec's setgroups() needs CAP_SETGID, and a root supervisor
    # without CAP_KILL cannot signal a different-uid child -- three added
    # capabilities this single-uid design avoids needing at all.
    # From: Issue #1428 | PR #1431
    #
    # What: keeps the bundled fluent-bit closure entirely unprivileged.
    # Why: issue #1427 moved every first-party producer log to gid-10001-readable creation, so file capabilities are no longer needed to tail them.
    # From: Issue #1427

USER lancache:lancache

# What: syslog-ng's receiver is 6601 (renumbered from 601).
# Why: 601 is a genuinely privileged port and this container has no
# CAP_NET_BIND_SERVICE grant; 601 was never published/documented externally.
# From: Issue #1428 | PR #1431
EXPOSE 6601/tcp 2020/tcp

# What: healthcheck.sh checks BOTH fluent-bit and syslog-ng independently.
# Why: only one Docker HEALTHCHECK slot exists for two processes; see
# healthcheck.sh's own header for the per-process status-file mechanism.
# From: Issue #1428 | PR #1431
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
