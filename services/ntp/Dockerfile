
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# LanCache-NG-NTP image: chrony (chronyd) disciplining its own clock against
# a curated set of public NTP servers and serving that time to LAN clients
# on UDP/123. No Rust builder stage is needed here (unlike services/dns/ or
# services/ui/) -- this image is a plain package install plus a shell
# entrypoint, the same shape as services/dhcp/Dockerfile and (since its own
# Alpine migration, issue #815) services/dhcp-proxy/Dockerfile.
#
# Alpine base (issue #815 Part B, staged Alpine migration for
# proxy/ntp/watchdog/ui -- ntp picked first as this evaluation's lowest-risk
# of the four: a plain C daemon with no Rust builder stage and no
# musl-compiled-binary question at all, unlike services/ui's Rust runtime or
# services/dns's still-open nats-subscriber retarget). Confirmed live on
# alpine:3.24 (2026-07-31): installs `chrony-nts` (4.8-r7), NOT the plain
# `chrony` package -- Alpine deliberately splits chrony into a default build
# with no NTS/SHA/AES support at all (no libgnutls/libnettle dependency) and
# this separate `chrony-nts` variant, same upstream version, that pulls in
# libgnutls/libnettle for NTS. services/ntp/chrony.conf does not configure
# NTS today, so both packages would work unchanged right now, but installing
# `chrony-nts` keeps a future NTS-hardening effort from being silently
# foreclosed by having picked the wrong package name during this migration.
# `/etc/chrony/`, `conf.d/`, and `sources.d/` match this project's existing
# expectations exactly (verified live) -- no path translation needed.
# `bash` is installed explicitly because entrypoint.sh uses real Bash-only
# syntax (`${var// /}` parameter substitution) that Alpine's default
# `/bin/sh` (busybox ash) does not support -- see AG-REL-006. `gettext-base`
# -> `gettext-envsubst`: Alpine splits envsubst out of the base gettext
# package, matching the same finding already made for the other three
# already-migrated/being-migrated services in this project.

# What: source stage for tools copied into final image.
# Why: mutable `:latest` tag for build flexibility.
# From: Issue #1095
ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest
FROM ${UTILITIES_IMAGE} AS utilities-tools

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="LanCache-NG-NTP: chrony-based NTP server, disciplined against public NTP servers, serving LAN clients on UDP/123."

# `apk upgrade --no-cache` (before the package install, same layer) upgrades
# packages already baked into the alpine:3.24 base layer itself -- `apk add
# --no-cache` only fetches a fresh index for the packages it is asked to
# install, it does not touch already-installed packages. See
# services/dhcp-proxy/Dockerfile's matching comment for the fuller
# rationale and live verification of this behavior.

# What: curl/envsubst binaries from shared utilities image.
# Why: same Alpine base digest ensures binary compatibility.
# From: Issue #1556
COPY --from=utilities-tools /usr/local/bin/curl /usr/local/bin/curl
COPY --from=utilities-tools /usr/bin/envsubst /usr/bin/envsubst
COPY --from=utilities-tools /usr/lib/libintl.so.8 /usr/lib/libintl.so.8

# What: verifies copied binaries work on target system.
# Why: shared libraries fail at runtime, not copy time.
# From: Issue #1556
RUN set -euo pipefail; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    curl --version >/dev/null

# What: ca-certificates package enables curl's CA bundle.
# Why: copied curl has fixed CA path; package generates it.
# From: Issue #1556
# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: APT_CACHE_BUST invalidates BuildKit's upgrade cache.
# Why: without this, BuildKit replays stale cache forever.
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    ca-certificates \
    chrony-nts

COPY chrony.conf /etc/chrony/chrony.conf.template
COPY entrypoint.sh /entrypoint.sh

# This entrypoint still execs chronyd as root as its own initial PID 1 (it
# needs root to bind UDP/123 and to perform its own internal user switch
# below) -- but least-privilege hardening (issue #1358) makes the eventual
# drop explicit rather than relying on an unwritten default. CAP_SYS_TIME
# is needed to actually step/slew the container HOST's real system clock
# (containers share one kernel clock -- there is no per-container clock
# namespace), and Docker's default capability bounding set excludes
# CAP_SYS_TIME regardless of any file capability the package may set on
# the binary. The compose files grant a narrow, explicit `cap_add` list on
# top of `cap_drop: [ALL]` (see their comments for the full, empirically
# verified set and the host-wide-clock operational tradeoff CAP_SYS_TIME
# itself implies). chronyd's own compiled-in `+PRIVDROP` support (confirmed
# live via `chronyd -v`'s reported feature list, unchanged by the Alpine
# migration) is what makes it drop privileges to the packaged `chrony`
# system user/group once it no longer needs root -- services/ntp/chrony.conf
# now sets this via chrony's own documented `user chrony` directive
# instead of leaving the target user as this project's own unverified
# inference about PRIVDROP's compiled-in default (the earlier state of
# this comment made exactly that inference, which issue #1358 flagged as
# the anti-pattern AG-VAL-023 warns against). Alpine's chrony-nts pulls the
# `chrony` user/group in via its chrony-common dependency; its numeric
# uid/gid, 100/101, is identical to Debian's own `_chrony` user, confirmed
# live -- so a pre-existing volume's ownership carries over cleanly across
# this migration. Because that drop happens after this entrypoint's own
# `mkdir -p` below (which runs as root), `/var/log/chrony` and
# `/var/lib/chrony` can end up root-owned and unwritable by the
# dropped-privilege chronyd -- entrypoint.sh's own chown call fixes this up
# at container start; see its comment for the real, reproducible bug this
# validation pass found (present identically pre-migration on Debian too).
# Seccomp (`-F 2` -- downgraded from an original `-F 1`, see entrypoint.sh's
# own comment on its final `exec` for the real, reproduced kernel-version-
# dependent crash that caused the downgrade, issue #1296): `libseccomp` is
# pulled in automatically as a real transitive dependency of `chrony-nts`
# on this base (confirmed live in this image's own `apk add` output, and
# via `chronyd -v` reporting `+SCFILTER`), not something this Dockerfile
# opts into explicitly.
#
# CAP_SYS_TIME graceful-degradation dependency (issue #1296): entrypoint.sh's
# clock_control_available() probes via `adjtimex`, which is NOT a separate
# package added by this Dockerfile -- it is one of Alpine's base `busybox`
# binary's own built-in applets (confirmed live: present with no extra
# `apk add`). If a future base-image change ever drops or renames it,
# clock_control_available() fails closed with its own loud, distinct error
# (see that function's comment) rather than silently misreporting clock
# control as available -- but keep this comment in sync if that dependency
# ever needs to become an explicit package instead.
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/lib/chrony /var/log/chrony

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
