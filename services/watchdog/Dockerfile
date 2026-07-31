# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Runtime health-check and recovery service for lancache-ng containers.
#
# Alpine base (issue #815, watchdog carve-out): #815 itself deliberately
# excluded this service from its phased Alpine rollout because issue #842
# (maintainer decision, 2026-07-25) said watchdog.sh will eventually be
# rewritten as a real Rust service, and migrating the CURRENT bash image
# seemed like immediately-obsoleted work. Revisited and approved anyway
# (maintainer decision, 2026-07-31): #842's rewrite has not started -- only
# the decision is recorded, no implementation -- and has no scheduled
# timeline, while this migration is trivial (no builder stage, no compiled
# binary, a plain apt->apk package-name swap) and brings real value
# (smaller image, smaller package-count attack surface) on its own, entirely
# independent of whatever base-image decision the eventual Rust rewrite
# makes for itself. All seven packages this Dockerfile previously installed
# on `debian:13-slim` were confirmed present on Alpine 3.24 during #815's own
# research (curl 8.21.0-r0, jq 1.8.1-r0, ca-certificates 20260611-r0, nano
# 9.1-r0, lsof 4.99.6-r0, ripgrep 15.1.0-r0, zstd 1.5.7-r2) -- no
# package-availability blocker exists. Same Alpine 3.24 digest already
# pinned by services/dhcp/Dockerfile and services/dhcp-proxy/Dockerfile,
# kept identical across all three migrated services rather than pinning a
# separately-resolved digest for the same tag.
#
# `bash` is installed explicitly because watchdog.sh/healthcheck.sh both
# declare `#!/bin/bash` and rely on real Bash-only syntax (`local -n`
# namerefs in watchdog.sh's check_and_maybe_restart()/probe_docker_socket_proxy(),
# `${var,,}` lowercasing in is_truthy()) that Alpine's default `/bin/sh`
# (busybox ash) does not support -- see AG-REL-006. Verified available,
# bash 5.3.9-r1, which is well past the 4.3 baseline `local -n` needs.
#
# `findutils` (GNU find) is installed explicitly, and is the one real
# GNU-vs-BusyBox behavioral gap found in this migration (checked for, not
# just assumed, per this migration's own review instructions): both
# maybe_prune_syslog()'s size-budget pass and
# maybe_rotate_fluent_bit_selflog()'s rotation-count cleanup sort files by
# mtime via `find ... -printf '%T@\t%p\n'`. Confirmed live on a real
# alpine:3.24 container (2026-07-31) that BusyBox's own bundled `find`
# applet does not support `-printf` at all ("find: unrecognized: -printf")
# -- it is a GNU findutils extension, not a POSIX `find` action. The
# `coreutils` package (suggested as the general fallback for a GNU-vs-BusyBox
# gap) would NOT have fixed this: `find` ships in GNU findutils, not GNU
# coreutils. Every other command these two scripts call (`date -u`, `stat -c`,
# `du -sb`, `awk`'s `gsub`/`NR`, `df -P`, `sort -n`, `wc -l`, `mktemp`,
# `cp --`/`rm --`/`basename --`) was verified live, side by side, to behave
# identically between BusyBox's applets and GNU's -- notably `du -sb`
# (byte-exact apparent size, checked against a file of a known exact byte
# count) and `stat -c '%s'/'%Y'` (byte size / mtime-epoch format specifiers),
# both of which this migration cannot silently get subtly wrong given
# maybe_prune_syslog()'s and maybe_rotate_fluent_bit_selflog()'s disk-budget
# math depends on them. Installing `findutils` swaps only `find`/`xargs` to
# their GNU builds (confirmed: `apk info -a findutils` lists exactly
# `cmd:find`/`cmd:xargs`, nothing else) -- a narrower, more targeted fix than
# pulling in the full `coreutils` package for a gap that isn't actually a
# coreutils gap.
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
ENV EDITOR=nano
ENV VISUAL=$EDITOR
COPY watchdog.sh /watchdog.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /watchdog.sh /healthcheck.sh
VOLUME ["/var/run/watchdog"]
ENTRYPOINT ["/watchdog.sh"]
