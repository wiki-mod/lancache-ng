
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: combined fluent-bit + syslog-ng container, replacing two separate
# services (`syslog`=fluent-bit, `syslog-ng`=central receiver).
# Why: the maintainer accepted crash-coupling/one-HEALTHCHECK-slot/no-
# independent-restart trade-offs for one image instead of two.
# From: Issue #1428 | PR #1431
#
# What: copies the pinned fluent-bit binary + its glibc shared-library
# closure into a private prefix, execed via an explicit ld-linux
# interpreter argument (never the kernel's own embedded-interpreter path).
# Why: Alpine stable never packages fluent-bit (only edge's unpinnable
# "testing" repo); an isolated glibc closure avoids gcompat's known
# coverage gaps for a binary this large, with no Alpine-musl ABI mixing.
# From: Issue #1428 | PR #1431
FROM cr.fluentbit.io/fluent/fluent-bit:3.2.10@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562 AS fluent-bit-src

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# What: pins the Alpine base to 3.24 (was 3.20); syslog-ng stays on Alpine's
# stable main repo (4.11.0-r0 on 3.24). bash provides `wait -n` for
# entrypoint.sh's fail-fast multi-child supervision.
# Why: 3.20 was an unintentional scaffold-commit inconsistency, not a
# deliberate choice -- every other first-party service already pins 3.24.
# From: Issue #1554 | PR #1555
RUN apk add --no-cache \
        syslog-ng \
        syslog-ng-json \
        bash \
        zstd \
        tzdata \
        libcap \
    # What: fixed uid/gid 10001, matching services/ui/Dockerfile's identity.
    # Why: syslog-ng writes files this uid needs to read back
    # (SYSLOG_NG_LOG_DIR); matching identities avoids a group workaround.
    # From: Issue #1428 | PR #1431
    && addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache lancache \
    && mkdir -p /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache \
    && chown -R lancache:lancache /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data /var/log/lancache
# What: pre-creates+chowns `/data`, `/var/log/lancache` (named volumes) and
# `/var/log/lancache-syslog-ng` (a real bind mount, SYSLOG_NG_LOG_DIR).
# Why: an image-absent path becomes an unwritable root:root dir for the
# non-root `lancache` uid -- the bind-mount case is the real bug
# data-loss-detector.sh guards against.
# From: Issue #1428 | PR #1431

# What: globs the `*-linux-gnu` triplet directory instead of hardcoding
# either arch's name, so this COPY matches both amd64 and arm64 unmodified.
# Why: an earlier hardcoded x86_64-linux-gnu path failed closed on arm64
# ("not found") -- Docker's COPY --from pattern is matched via Go's
# filepath.Match per path segment, so a glob needs no ARG TARGETARCH branch.
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
    # What: this container runs entirely as fixed non-root uid 10001, not a
    # root PID 1 that drops privilege for one child (su-exec, rejected).
    # Why: su-exec's setgroups() needs CAP_SETGID, and a root supervisor
    # without CAP_KILL cannot signal a different-uid child -- three added
    # capabilities this single-uid design avoids needing at all.
    # From: Issue #1428 | PR #1431
    #
    # What: setcap goes on $ld_interp (the dynamic-linker interpreter),
    # never on the fluent-bit binary itself.
    # Why: fluent-bit is invoked via an explicit ld-linux interpreter
    # argument, so the kernel's real execve() target -- and the only place
    # a FILE capability reaches a non-root process -- is the interpreter.
    # From: Issue #1428 | PR #1431
    #
    # What: grants CAP_DAC_READ_SEARCH only (not the broader DAC_OVERRIDE).
    # Why: sufficient for fluent-bit's read-only tailing of producer logs
    # it doesn't own (nginx/PowerDNS/Kea, root:root 0640); fixing every
    # producer's own ownership is separate follow-up, issue #1427.
    # From: Issue #1428 | PR #1431
    #
    # What: this setcap xattr is a HARD RUNTIME INVARIANT.
    # Why: `--cap-drop ALL` without a matching `--cap-add DAC_READ_SEARCH`
    # FAILS CLOSED at exec (exit 126), not a degraded start -- every
    # compose file/CI script starting this service must carry both together.
    # From: Issue #1428 | PR #1431
    && setcap cap_dac_read_search+eip "/opt/fluent-bit-glibc/lib/$ld_interp" \
    && apk del libcap

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
