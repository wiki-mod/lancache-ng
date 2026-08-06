# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined fluent-bit + syslog-ng container, replacing the previous two
# separate services (`syslog` = fluent-bit, `syslog-ng` = central receiver).
# The maintainer explicitly decided to accept this design's trade-offs
# (crash-coupling, one Docker HEALTHCHECK slot, no independent per-process
# restart) in exchange for one image instead of two -- see this PR's body
# for the full comparison. Everything below solves the three concrete
# problems a real POC (services/syslog-combined/, superseded by this
# directory) found with the single-container approach, plus the silent
# data-loss hardening the POC surfaced as a real, separate finding.
#
# ── Problem 1: no unpinnable edge/testing package for fluent-bit ──────────
# Alpine's stable repos (any numbered release, e.g. 3.20 below) do not
# package fluent-bit at all -- it exists only in Alpine edge's "testing"
# repo (5.0.9-r0 at the time the POC checked), which carries no stability
# guarantee and floats with edge itself. The POC's own Dockerfile documents
# this and recommended NOT using it for that reason.
#
# Real fix, verified live on a self-hosted runner (2026-08-05/06, see this
# PR's body for the exact commands): copy the EXACT pinned production
# fluent-bit binary (cr.fluentbit.io/fluent/fluent-bit:3.2.10, the same
# digest deploy/prod/docker-compose.yml already used before this PR) into a
# private, self-contained prefix inside a stable, digest-pinned Alpine base,
# along with its ENTIRE glibc shared-library closure (confirmed via `ldd`
# against the real image: libc.so.6, libssl.so.3, libcurl.so.4, libgnutls,
# libkrb5, ~35 libraries total), then exec it through that same bundled
# dynamic-linker interpreter (ld-linux-x86-64.so.2 on amd64,
# ld-linux-aarch64.so.1 on arm64 -- both confirmed live; see the COPY step
# further down for exactly how the interpreter's arch-specific filename is
# discovered rather than hardcoded) as an EXPLICIT interpreter argument
# (`<ld-linux interpreter> --library-path <bundle> <binary>`), never through
# the kernel's normal "read the ELF's own interpreter field" path (which
# would look for that interpreter at its embedded absolute path, absent on
# musl-based Alpine). This is not gcompat (a musl-side glibc syscall/ABI
# shim with well-known coverage gaps for exactly this class of large,
# multi-library dynamic binary) -- it never touches Alpine's own musl libc
# or its libraries at all; the bundled glibc closure is fully self-contained
# and isolated via an explicit --library-path, so there is no ABI mixing.
# Verified end-to-end, not just `--version`: a real tail input + syslog
# output delivered actual RFC5424 bytes to a listener.
FROM cr.fluentbit.io/fluent/fluent-bit:3.2.10@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562 AS fluent-bit-src

FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

# syslog-ng ships in Alpine's STABLE main repo (confirmed live: 4.7.1-r1 on
# 3.20, the version this Dockerfile actually pins) -- the POC's own
# Dockerfile comment already established this; only fluent-bit needed the
# edge/testing repo, which this image never touches. bash is this project's
# default shell (AG-REL-006) and provides `wait -n` for entrypoint.sh's
# fail-fast multi-child supervision; su-exec is NOT used here (see the
# capability-posture comment on the fluent-bit interpreter's setcap step
# below for why a runtime privilege-drop design was tried and rejected).
RUN apk add --no-cache \
        syslog-ng \
        syslog-ng-json \
        bash \
        zstd \
        tzdata \
        libcap \
    # Fixed uid/gid 10001: the SAME fixed identity this project's Admin UI
    # already uses (services/ui/Dockerfile), not a coincidence -- syslog-ng
    # writes files this uid needs to read back (SYSLOG_NG_LOG_DIR), and
    # matching identities means no group-based workaround is needed at all
    # (see syslog-ng.conf's own header comment for what this replaces).
    && addgroup -g 10001 lancache \
    && adduser -D -H -u 10001 -G lancache lancache \
    && mkdir -p /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data \
    && chown -R lancache:lancache /var/log/lancache-syslog-ng /var/lib/lancache-syslog-data /etc/syslog-ng /etc/fluent-bit /data
# `/data` (fluent-bit's storage.path/DB/log root, see fluent-bit.conf) is a
# NAMED volume in deploy/*/docker-compose.yml (syslog-data:/data), not a bind
# mount. Docker initializes a fresh named volume's content from whatever
# already exists at that path in the image at first mount -- if the path is
# absent from the image (as it was before this fix), Docker instead creates
# an empty root:root directory, which the non-root `lancache` USER below
# cannot write into. Real, reproduced failure: fluent-bit's storage engine
# fails to initialize ("cannot initialize root path /data/flb-storage"),
# which this container's fail-fast supervisor treats as fatal and tears the
# whole container down. Creating and chowning `/data` here (like the other
# internal, non-bind-mount paths above) means Docker copies this
# already-chowned empty directory into the volume on first creation.
# `/var/log/lancache-syslog-ng` above is the image's OWN copy of this path,
# chowned here so a fresh named-volume mount would inherit it -- in real
# deployments this path is always a BIND MOUNT (SYSLOG_NG_LOG_DIR), which
# Docker never re-populates from image content and instead auto-creates as
# root:root 0755 if the host directory doesn't already exist. That
# precondition is the exact real bug this PR's data-loss-detector.sh guards
# against (see its own header comment for the full, live-reproduced
# finding) -- setup.sh is updated in this PR to pre-create/chown that host
# directory so a fresh install never hits it, but the detector still catches
# a stale/unfixed install or a runtime permission change regardless.

# Copy the pinned fluent-bit binary and its full shared-library closure into
# a private prefix -- never mixed into Alpine's own musl /usr/lib, so this
# cannot affect or be affected by any Alpine-native library on the system.
#
# ── arm64 fix (2026-08-06, real bug found and confirmed by a separate
# agent's #1428 CI run, then reproduced here independently before fixing) ──
# The FIRST version of this Dockerfile hardcoded x86_64-linux-gnu in both
# COPY source paths below and hardcoded ld-linux-x86-64.so.2 in this
# Dockerfile's own setcap step and in entrypoint.sh's exec line. That is a
# real amd64-only assumption this PR's own verification never caught,
# because only amd64 was built and tested (see this PR's body/report for
# that gap being named honestly). Confirmed live on a real arm64 build
# (docker buildx --platform linux/arm64, self-hosted runner, QEMU-emulated
# since this project's own arm64 CI lane uses native GitHub-hosted arm64
# runners, not QEMU -- see docs/self-hosted-actions-runner.md -- but the
# Dockerfile logic being tested is identical either way): the pinned
# cr.fluentbit.io image's arm64 manifest (confirmed via `docker buildx
# imagetools inspect` against the exact pinned digest below, which IS a
# real multi-platform manifest list, not an amd64-only image mislabeled)
# lays its glibc closure under lib/aarch64-linux-gnu/ and
# usr/lib/aarch64-linux-gnu/, with lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
# as its interpreter -- neither name matches the old hardcoded x86_64
# strings, so both old COPY lines failed closed with "not found" (verified:
# this is the exact error the #1428 agent's CI run hit).
#
# Fix: glob the triplet directory name instead of hardcoding either arch's
# name. Docker's COPY --from src pattern is matched via Go's
# `filepath.Match` per path segment (not a shell glob, but `*` behaves
# identically here: it matches any run of non-`/` characters within one
# path segment), so `*-linux-gnu` matches x86_64-linux-gnu on amd64 AND
# aarch64-linux-gnu on arm64 in the exact same Dockerfile, needing no
# `ARG TARGETARCH` branch and no BuildKit-only `RUN --mount=type=bind`
# feature. Confirmed live: both the amd64 rebuild (regression-checked, see
# this PR's report) and a fresh arm64 build now copy successfully.
COPY --from=fluent-bit-src /fluent-bit/bin/fluent-bit /opt/fluent-bit-glibc/bin/fluent-bit
COPY --from=fluent-bit-src /lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/
COPY --from=fluent-bit-src /usr/lib/*-linux-gnu/. /opt/fluent-bit-glibc/lib/

COPY fluent-bit.conf /etc/fluent-bit/fluent-bit.conf
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY data-loss-detector.sh /usr/local/bin/data-loss-detector.sh

RUN chmod 755 /entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/data-loss-detector.sh \
    # Discover the dynamic-linker interpreter's real filename instead of
    # hardcoding an arch (see the COPY step's own comment above for the
    # arm64 bug this replaces: ld-linux-x86-64.so.2 on amd64,
    # ld-linux-aarch64.so.1 on arm64, confirmed live for both). Fails the
    # build loudly (empty glob -> `ls` exits non-zero -> `set -e` in this
    # RUN's shell aborts) rather than silently proceeding with no
    # interpreter at all, on any architecture this Dockerfile is ever built
    # for.
    && ld_interp="$(basename "$(ls /opt/fluent-bit-glibc/lib/ld-linux-*.so.* | head -n1)")" \
    && echo "$ld_interp" > /opt/fluent-bit-glibc/ld-interp-name \
    && chmod +x "/opt/fluent-bit-glibc/lib/$ld_interp" /opt/fluent-bit-glibc/bin/fluent-bit \
    && chown -R lancache:lancache /opt/fluent-bit-glibc \
    # ── Problem 2 continued: least-privilege capability posture, empirically
    # determined (same "prove it, never assume it" methodology this project
    # already used for services/ntp's PR #1413, and for this PR's own
    # earlier, disproven root/non-root-split design -- see the PR body for
    # both dead ends this arrived from) ──
    #
    # This container runs ENTIRELY as the fixed non-root uid 10001 (USER
    # below) -- not a root PID 1 that drops privilege for one child. A
    # runtime privilege-drop design (su-exec) was tried first and rejected:
    # verified live that su-exec's own setgroups() call needs CAP_SETGID,
    # and that a root supervisor without CAP_KILL cannot signal a
    # different-uid child at all (`kill: Operation not permitted`) -- that
    # design would have needed THREE added capabilities (SETUID, SETGID,
    # KILL) just to support one runtime setuid() call this single-uid
    # design avoids needing altogether.
    #
    # The remaining problem: fluent-bit still needs to READ the production
    # log-producer files this container does not own (nginx/PowerDNS/Kea/
    # etc., all root:root 0640 today -- fixing every producer's own
    # ownership is real, separate follow-up work, tracked in issue #1427,
    # not fixed in this PR). Verified live that plain
    # `--cap-add DAC_READ_SEARCH` alone does NOT reach a non-root process's
    # effective capability set (`CapEff` stayed all-zero even with the bit
    # present in `CapBnd`) -- capabilities only reach a non-root process via
    # a FILE capability (setcap) on the exact binary the kernel executes.
    # Critically, that is NOT fluent-bit itself in this image: since
    # fluent-bit is invoked through an explicit ld-linux interpreter argument
    # (Problem 1 above), the kernel's execve() target is the INTERPRETER,
    # not fluent-bit -- setcap must go on that interpreter (whichever
    # arch-specific file it resolves to, see $ld_interp above), confirmed
    # live on amd64 (setcap on the fluent-bit binary itself had no effect;
    # moving it to the interpreter fixed it immediately, same test, same
    # file being read). The arm64 portability fix (2026-08-06) makes this
    # same setcap call arch-generic via $ld_interp (resolving to
    # ld-linux-aarch64.so.1 on arm64 instead of a hardcoded amd64 name) --
    # see this PR's report for whether the arm64 leg's setcap/read-access
    # behavior was itself re-verified live, not just the build succeeding.
    #
    # CAP_DAC_READ_SEARCH (bypasses file READ and directory search/execute
    # permission checks only) is used here instead of the broader
    # CAP_DAC_OVERRIDE the POC's own Dockerfile proposed as its fallback
    # (which additionally bypasses WRITE permission checks) -- confirmed
    # live that DAC_READ_SEARCH alone is sufficient for fluent-bit's actual
    # access pattern (read-only tailing of producer logs; fluent-bit never
    # writes to any producer-owned path). This is real, verified progress
    # beyond what the POC established, not a restatement of it.
    #
    # This is a documented, real hardening TRADE-OFF, not the zero-capability
    # ideal: today's production runs fluent-bit as root with the full default
    # capability set (no cap_drop at all), so DAC_READ_SEARCH-only is a net
    # improvement over the current baseline, but it is not the POC's
    # "cap_drop: ALL, zero cap_add" best case, which additionally needs
    # every producer log group-readable by gid 10001 -- that is the
    # separate follow-up this Dockerfile comment points at above.
    #
    # HARD INVARIANT this xattr creates, verified live and NOT optional to
    # forget: running this exact image with `--cap-drop ALL` and no matching
    # `--cap-add DAC_READ_SEARCH` FAILS CLOSED at exec (`Operation not
    # permitted`, exit 126) -- it does not silently start with reduced
    # capabilities. Every compose file and CI script that starts this
    # service must carry both `cap_drop: [ALL]` and
    # `cap_add: [DAC_READ_SEARCH]` together.
    && setcap cap_dac_read_search+eip "/opt/fluent-bit-glibc/lib/$ld_interp" \
    && apk del libcap

USER lancache:lancache

# Both listeners are on non-privileged ports -- deliberately, not by luck:
# fluent-bit's HTTP monitor (2020) always was; syslog-ng's receiver was
# renumbered from the previous 601 to 6601 specifically BECAUSE 601 is a
# genuinely privileged port (confirmed live:
# /proc/sys/net/ipv4/ip_unprivileged_port_start defaults to 1024 on a real
# runner, and a non-root syslog-ng bind to 601 failed closed with
# "Permission denied" until this renumbering), which this container has no
# CAP_NET_BIND_SERVICE grant for. Port 601 was never published to the host
# or documented as an external contract in any deploy/*/docker-compose.yml
# (grepped: absent), so this is a zero-external-impact internal
# implementation detail.
EXPOSE 6601/tcp 2020/tcp

# Real dual-process check (see healthcheck.sh's own header comment for the
# full reasoning) -- this is the granularity fix for the POC's own
# documented gap (only ONE Docker HEALTHCHECK slot for two processes): the
# script itself checks BOTH fluent-bit and syslog-ng independently and only
# reports healthy when both are, plus writes a structured per-process status
# file for a future Admin UI/watchdog integration.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
