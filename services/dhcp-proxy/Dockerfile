
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# dnsmasq-based DHCP proxy/relay image. Runs alongside an existing DHCP
# server in dnsmasq's "proxy" mode, overriding only DNS options for clients
# (mutually exclusive with the Kea DHCP mode in services/dhcp).
#
# Alpine base (issue #815, staged Alpine migration, dnsmasq-first): this
# service has no builder stage and no compiled binary, so the migration is a
# straightforward apt->apk package swap. Confirmed on Alpine 3.24: dnsmasq
# 2.92_p2-r0 (vs. Debian trixie's 2.91), no known musl-specific dnsmasq
# issues (dnsmasq implements its own UDP/TCP packet handling, it does not
# route DHCP/DNS serving through musl's client-side resolver). `bash` is
# installed explicitly because entrypoint.sh uses real Bash-only syntax
# (arrays, C-style `for ((...))` loops, `${var//pat/repl}`) that Alpine's
# default `/bin/sh` (busybox ash) does not support -- see AG-REL-006.
# `envsubst` ships in the separate `gettext-envsubst` sub-package on this
# Alpine version, not the base `gettext` package (verified: `apk info
# gettext-envsubst` on alpine:3.24).

FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments."

# `apk upgrade --no-cache` (before the package install, same layer) upgrades
# packages already baked into the alpine:3.24 base layer itself (e.g. musl,
# busybox) -- `apk add --no-cache` only fetches a fresh index for the
# packages it is asked to install, it does not touch already-installed
# packages. Verified on a real alpine:3.24 container (2026-07-30): apk-tools
# and libapk ship in the base layer at 3.0.6-r0 while 3.0.7-r0 is already
# available from the v3.24 branch's own repo; `apk upgrade --no-cache` alone
# (no separate `apk update` needed, mirroring `apk add --no-cache`'s own
# convention) picks it up and, per a real `find /var/cache/apk` check
# afterward, leaves no persistent index cache behind either.
#
# `findutils` and `coreutils` (issue #840, found while validating a later,
# unrelated Alpine migration for services/watchdog -- PR #1346): this
# Dockerfile's original Alpine migration (this PR) omitted both, and two
# real, silent regressions resulted in entrypoint.sh's known-good-config
# snapshot machinery (docs/known-good-config-snapshots.md, #614):
#
# 1. `kgs_list_snapshots()` uses `find ... -printf '%f\n'` to sort snapshot
#    ids by name. Confirmed live on a real `alpine:3.24` container: BusyBox's
#    bundled `find` does not support the GNU-findutils-only `-printf` action
#    at all ("find: unrecognized: -printf"), fails with exit 1, and writes
#    that error to stderr -- which the function's own `2>/dev/null` silently
#    swallows, leaving `sort` with empty input and the function silently
#    returning an empty snapshot list. `findutils` installs GNU `find`/
#    `xargs` at `/usr/bin/find`, ahead of BusyBox's own `find` applet earlier
#    in `$PATH` -- the same fix already verified and shipped for
#    `services/watchdog` (PR #1346).
# 2. `kgs_new_snapshot_id()` uses `date -u +%Y%m%dT%H%M%S.%N` for
#    "practically collision-free" snapshot ids. Confirmed live: BusyBox's
#    `date` does not error on the unsupported `%N` (nanoseconds) specifier --
#    it silently produces empty output for it instead, so every id generated
#    on Alpine ended in a bare `.` with no nanosecond suffix, and the
#    collision-avoidance the comment claims no longer held (two snapshots
#    created within the same whole second collided on the same id).
#    `coreutils` (GNU coreutils, which `date` ships as part of, not
#    `findutils`) installs a real `date` binary at `/bin/date` that
#    correctly implements `%N` -- confirmed live: `date -u
#    +%Y%m%dT%H%M%S.%N` produces a real 9-digit nanosecond suffix, not an
#    empty one. Installing the full `coreutils` package (rather than trying
#    to cherry-pick just `date`, which Alpine does not package standalone)
#    also replaces several other BusyBox applets in this image (`basename`,
#    `cp`, `install`, `mktemp`, `mv`, `rm`, `sort`, etc.) with their real GNU
#    equivalents. `apk add coreutils` itself installs cleanly with no
#    conflicts; every external command this entrypoint actually calls
#    (`basename`, `cp`, `date`, `envsubst`, `find`, `install`, `mktemp`,
#    `mv`, `rm`, `sort`, `xargs` -- confirmed by grepping the whole file, not
#    guessed) was confirmed present and resolving to the expected GNU/
#    findutils binary on the real built image, and the full known-good-
#    snapshot lifecycle that exercises most of them (`kgs_snapshot_create`/
#    `kgs_snapshot_apply`/`kgs_snapshot_prune`, including the
#    "no snapshot validates, restore the original live file" backup path)
#    was run end-to-end against a real `dnsmasq --test` validator and
#    behaved identically to the pre-migration Debian image.
# What: shared version-banner check script, not a service-local file.
# Why: named build context avoids duplicating it into every service.
# From: Issue #1781 | PR #1783
COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh

# What: switches apk's own repositories to plain http.
# Why: Squid caches http; signed indices keep integrity.
# From: Issue #1095
RUN sed -i 's|^https://|http://|' /etc/apk/repositories

# What: declares APT_CACHE_BUST right before the RUN it busts.
# Why: BuildKit's cache needs wall-clock expiry for fresh packages
# From: Issue #1095
ARG APT_CACHE_BUST=""
RUN : "apt-cache-bust=${APT_CACHE_BUST}" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    dnsmasq \
    coreutils \
    nano \
    findutils \
    gettext-envsubst \
    lsof \
    ripgrep

# nano: in-container troubleshooting tool -- see services/proxy/Dockerfile's
# identical comment for the full rationale; lsof/ripgrep are apk-installed
# above but serve the same troubleshooting purpose.

# What: verifies apk-installed binaries execute, not just exist.
# Why: missing library dependencies fail at runtime, not apk add.
# From: Issue #1613 | Issue #1781 | PR #1783
RUN set -euo pipefail; \
    find . -maxdepth 0 -printf '%f\n' >/dev/null; \
    printf '%s' '$FOO' | FOO=bar envsubst >/dev/null; \
    rg --version >/dev/null; \
    sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v

ENV EDITOR=nano
ENV VISUAL=$EDITOR

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY dnsmasq-relay.conf.template /etc/dnsmasq-relay.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# What: final apk upgrade pass, no packages added.
# Why: patches any CVE fixed after this file's earlier package installs.
# From: Issue #1781 | PR #1783
RUN apk upgrade --no-cache

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
