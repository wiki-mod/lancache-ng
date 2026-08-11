
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Runtime health-check and recovery service for lancache-ng containers.
#
# Alpine base (issue #815, watchdog carve-out): #815 itself deliberately
# excluded this service from its phased Alpine rollout because issue #842
# (maintainer decision, 2026-07-25) said watchdog.sh will eventually be
# rewritten as a real Rust service, and migrating the CURRENT bash image
# seemed like immediately-obsoleted work. Revisited and approved anyway
# (maintainer decision, 2026-07-31): at the time, #842's rewrite had not
# started -- only the decision was recorded, no implementation -- and had
# no scheduled timeline, while this migration was trivial (no builder
# stage, no compiled binary, a plain apt->apk package-name swap) and
# brought real value (smaller image, smaller package-count attack surface)
# on its own, entirely independent of whatever base-image decision the
# eventual Rust rewrite makes for itself.
#
# STATUS (2026-08-01): the health-check/restart core's Rust rewrite now
# exists as a scaffold (services/watchdog/Cargo.toml + src/), covering that
# core (see that crate's own src/lib.rs module doc comment for exactly
# what is and isn't ported yet). It is NOT wired into this Dockerfile --
# `ENTRYPOINT` below still runs the bash `watchdog.sh`, and this image
# still builds nothing from the Rust crate. The three filesystem-retention
# passes (maybe_purge/maybe_prune_syslog/maybe_rotate_fluent_bit_selflog)
# are NOT a prerequisite for this ENTRYPOINT swap: they already run
# independently of it, extracted into their own retention.sh and now their
# own dedicated `retention` Compose service/container (see below and
# deploy/*/docker-compose.yml's `retention:` service block), not inside
# whatever process this Dockerfile's health-monitor `ENTRYPOINT` runs.
# Whether/when this Dockerfile switches that health-monitor `ENTRYPOINT` to
# a compiled Rust binary remains an open, not-yet-made maintainer decision
# for other reasons (this crate's own remaining scope, and full-stack
# validation), independent of whatever base-image choice this file makes
# for itself. All seven packages this Dockerfile previously installed
# on `debian:13-slim` were confirmed present on Alpine 3.24 during #815's own
# research (curl 8.21.0-r0, jq 1.8.1-r0, ca-certificates 20260611-r0, nano
# 9.1-r0, lsof 4.99.6-r0, ripgrep 15.1.0-r0, zstd 1.5.7-r2) -- no
# package-availability blocker exists. Same Alpine 3.24 digest already
# pinned by services/dhcp/Dockerfile and services/dhcp-proxy/Dockerfile,
# kept identical across all three migrated services rather than pinning a
# separately-resolved digest for the same tag.
#
# `bash` is installed explicitly because watchdog.sh/healthcheck.sh/
# retention.sh all declare `#!/bin/bash` and rely on real Bash-only syntax
# (`local -n` namerefs in watchdog.sh's
# check_and_maybe_restart()/probe_docker_socket_proxy(), `${var,,}`
# lowercasing in is_truthy(), `set -o pipefail` in all three) that Alpine's
# default `/bin/sh` (busybox ash) does not support -- see Rule-Ref: AG-REL-006.
# Verified available, bash 5.3.9-r1, which is well past the 4.3 baseline
# `local -n` needs. retention.sh (the three file-retention functions
# extracted out of watchdog.sh into their own script/process for
# blast-radius separation, see that file's own header) is a separate script
# that ships in this same built image, but does not run inside the plain
# `watchdog` container -- it now runs as its own dedicated `retention`
# Compose service/container (see deploy/*/docker-compose.yml's `retention:`
# service block and retention-entrypoint.sh), with its own tighter,
# non-root/capability-scoped lockdown. Both scripts still ship in this one
# image (see this Dockerfile's own `ENTRYPOINT` comment further below) so a
# single build serves either role, chosen entirely by which Compose service
# invokes it.
#
# `findutils` (GNU find) is installed explicitly, and is the one real
# GNU-vs-BusyBox behavioral gap found in this migration (checked for, not
# just assumed, per this migration's own review instructions): both
# maybe_prune_syslog()'s size-budget pass and
# maybe_rotate_fluent_bit_selflog()'s rotation-count cleanup sort files by
# mtime via `find ... -printf '%T@\t%p\n'`. Confirmed live on a real
# alpine:3.24 container (2026-07-31) that BusyBox's own bundled `find`
# applet does not support `-printf` at all ("find: unrecognized: -printf")
# -- it is a GNU findutils extension, not a POSIX `find` action. `coreutils`
# (see below) would NOT have fixed this: `find` ships in GNU findutils, not
# GNU coreutils. Every other command these two scripts call (`date -u`,
# `stat -c`, `du -sb`, `awk`'s `gsub`/`NR`, `df -P`, `sort -n`, `wc -l`,
# `mktemp`, `cp --`/`rm --`/`basename --`) was verified live, side by side,
# to behave identically between BusyBox's applets and GNU's -- notably
# `du -sb` (byte-exact apparent size, checked against a file of a known
# exact byte count) and `stat -c '%s'/'%Y'` (byte size / mtime-epoch format
# specifiers), both of which this migration cannot silently get subtly
# wrong given maybe_prune_syslog()'s and maybe_rotate_fluent_bit_selflog()'s
# disk-budget math depends on them. Installing `findutils` swaps only
# `find`/`xargs` to their GNU builds (confirmed: `apk info -a findutils`
# lists exactly `cmd:find`/`cmd:xargs`, nothing else).
#
# `coreutils` (#842 Teil 1 hardening, 2026-08-01) is installed for a second,
# distinct GNU-vs-BusyBox gap found while building retention.sh's fail-closed
# path validation (validate_retention_dir()): that function relies on
# `realpath -m` to canonicalize an env-controlled directory path without
# requiring it to already exist (a not-yet-created FLUENT_BIT_SELFLOG_DIR
# mount is a normal state). Confirmed live on this exact image (2026-08-01)
# that BusyBox's bundled `realpath` applet does not support the `-m` flag at
# all, nor even a `--` end-of-options marker -- it treats every argument,
# flags included, as a path to resolve, and exits nonzero the moment one of
# them doesn't exist ("realpath: -m: No such file or directory"), which
# would have made every call to validate_retention_dir() fail closed on
# every path, including perfectly valid ones -- a functional regression, not
# a security one, but one that would have silently disabled all three
# retention functions in production. Installing `coreutils` replaces
# `/usr/bin/realpath` with the GNU build, which supports `-m` correctly
# (confirmed: `realpath -m -- /nonexistent/../foo` correctly resolves without
# requiring the path to exist).
FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.description="lancache-ng watchdog helper for runtime health checks and recovery hooks."

# `apk upgrade --no-cache` (before the package install, same layer) upgrades
# packages already baked into the alpine:3.24 base layer itself (musl,
# busybox, apk-tools) -- see services/dhcp-proxy/Dockerfile's identical
# comment/block for the full rationale and the real verification behind it.
RUN apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    curl \
    jq \
    ca-certificates \
    findutils \
    coreutils \
    util-linux \
    nano \
    lsof \
    ripgrep \
    zstd
# nano/lsof/ripgrep: in-container troubleshooting tools -- see
# services/proxy/Dockerfile's identical comment for the full rationale.
# zstd (#1236): maybe_rotate_fluent_bit_selflog() compresses rotated
# fluent-bit self-log backups with it, matching the compression tool the
# syslog-ng service already uses for its own rotation loop (see
# deploy/*/docker-compose.yml). Installed at build time here rather than
# syslog-ng's runtime `apk add` pattern: that pattern exists there because
# syslog-ng's official image can't be given a custom Dockerfile, while this
# project owns this Dockerfile directly, so a guaranteed build-time install
# is simpler and doesn't depend on network egress at container start.
#
# util-linux (#842 Teil 2, 2026-08-01): provides `setpriv`, which
# retention-entrypoint.sh uses to drop the `retention` sidecar container from
# root to the unprivileged `lancache` user while carrying exactly one Linux
# capability (CAP_DAC_OVERRIDE) across that privilege drop via its
# `--ambient-caps` support -- see that file's own header for the full
# empirical reasoning (a bare `cap_add` + non-root `user:` does NOT hand a
# usable capability to a non-root process; confirmed via `/proc/self/status`
# on a real runner). Alpine's BusyBox ships no equivalent tool. `shadow` is
# NOT needed alongside it: BusyBox's own `addgroup`/`adduser` applets already
# support every flag the `lancache` account creation below needs (`-g`, `-D`,
# `-H`, `-G`, `-s`), confirmed directly against this exact base image.
ENV EDITOR=nano
ENV VISUAL=$EDITOR
COPY watchdog.sh /watchdog.sh
COPY healthcheck.sh /healthcheck.sh
COPY retention.sh /retention.sh
COPY retention-entrypoint.sh /retention-entrypoint.sh
RUN chmod +x /watchdog.sh /healthcheck.sh /retention.sh /retention-entrypoint.sh
VOLUME ["/var/run/watchdog"]

# `lancache` account (#842 Teil 2, 2026-08-01): fixed uid/gid 10001,
# matching services/ui/Dockerfile's own existing account of the same name --
# the maintainer's explicit instruction was to reuse this project-wide
# convention rather than mint a new dedicated identity for this container.
# Only the `retention` compose service actually runs as this user (via
# retention-entrypoint.sh's root-to-lancache privilege drop, see that file);
# the plain `watchdog` service still runs as root, unchanged -- Teil 2 of
# #842 scoped the lockdown to retention.sh's own execution environment, not
# watchdog.sh's, and extending it there is deliberately left as a follow-up,
# not built speculatively here.
#
# /var/lib/lancache-retention-state (#842 Teil 2): retention.sh's own
# PURGE_STAMP/SYSLOG_PRUNE_STAMP now live on their own dedicated volume,
# separate from /var/run/watchdog's status.json (watchdog.sh's, read by the
# Admin UI) -- the architecture decision from #842's own comment thread was
# to stop sharing that volume between the health-check state and retention's
# rate-limiting stamps, since they belong to genuinely different containers
# now. Pre-chowning it here at build time is belt-and-suspenders: a fresh
# named volume's first mount inherits an empty directory's ownership from the
# image, but retention-entrypoint.sh ALSO re-chowns it at container start
# (matching services/ui/docker-entrypoint.sh's identical reasoning) since a
# bind-mount override or a volume that already existed from an older install
# would not get this image-time ownership at all.
RUN addgroup -g 10001 lancache && \
    adduser -D -H -u 10001 -G lancache -s /sbin/nologin lancache && \
    mkdir -p /var/lib/lancache-retention-state && \
    chown lancache:lancache /var/lib/lancache-retention-state

# Default ENTRYPOINT: plain watchdog.sh, unchanged from before #842 Teil 2
# split retention out into its own sidecar container/service. The
# `retention` compose service overrides this with `entrypoint:
# ["/retention-entrypoint.sh"]` (see deploy/*/docker-compose.yml's own
# `retention:` service block) -- both scripts ship in this one image so a
# single build serves either role, chosen entirely by which compose service
# invokes it.
ENTRYPOINT ["/watchdog.sh"]
