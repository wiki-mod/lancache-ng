#!/bin/sh
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Entrypoint for the first-party netdata image (services/netdata/Dockerfile).
# Plain POSIX sh, not bash: this script only needs `cat`/a heredoc and
# `exec`, none of which need bash-specific features (Rule-Ref: AG-REL-006).
#
# Central logging pipeline (#633, #847) parity: the previously pulled
# Debian-based netdata/netdata image's own log paths under /var/log/netdata
# were symlinks to /dev/stdout|stderr by default, so the old entrypoint
# override (see git history of deploy/prod/docker-compose.yml's netdata
# service `command:`) had to convert daemon/health specifically into real
# files for fluent-bit to tail. This static build's own defaults are the
# opposite problem: verified empirically (2026-07-31) that with no [logs]
# section at all, EVERY stream (daemon, health, collector, access, debug)
# defaults to a real, ever-growing file under /var/log/netdata -- including
# collector/access/debug, which this project deliberately does not want in
# the shared bounded /logs view (collector is extremely high-rate internal
# diagnostics, access is high-rate API chatter, debug is empty unless
# enabled -- same rationale the old command override already documented).
# The syslog (fluent-bit) service tails this same volume (mounted
# read-only at /var/log/lancache-netdata) via a `*.log` glob, which does
# not distinguish by filename beyond the extension -- so leaving
# collector/access/debug as real files here would silently start
# forwarding them into the shared log view, a real regression this
# override exists to prevent. Written on every container start (not just
# once): the netdataconfig volume is only auto-seeded from this image by
# Docker on its first-ever use, so a long-lived volume from a prior run
# could otherwise carry a stale or hand-edited netdata.conf missing this
# section.
# mkdir -p defensively: /var/log/netdata is normally created by Docker as
# an empty mount point for the netdata-logs volume, but this guards against
# a plain `docker run` (or any future compose profile) that doesn't mount
# one -- without this, netdata falls back to stderr-only logging silently,
# which would be a confusing, hard-to-notice degradation rather than a
# hard failure.
#
# What: Set directory gid 10001 and repair file permissions.
# Why: Non-root syslog must read logs on volume reopen.
# From: Issue #1427
mkdir -p /var/log/netdata
chown netdata:10001 /var/log/netdata
chmod 2750 /var/log/netdata
find /var/log/netdata -maxdepth 1 -type f -exec chown netdata:10001 {} \; -exec chmod g+r {} \;

cat > /opt/netdata/etc/netdata/netdata.conf <<'CONF'
[logs]
    daemon = /var/log/netdata/daemon.file.log
    health = /var/log/netdata/health.file.log
    collector = /dev/stdout
    access = /dev/stdout
    debug = /dev/null
CONF

# Docker-socket group membership: found during this image's own real
# validation (2026-07-31), not carried over from the previous Debian-based
# netdata/netdata image. That image's official entrypoint auto-detects the
# mounted docker.sock's group and adds its `netdata` user to a matching
# group (see packaging/docker/README.md upstream, "DOCKER_HOST and PGID")
# so the daemon -- which drops privileges from root to the unprivileged
# `netdata` user for its main process -- can still read the socket. This
# image has no such logic of its own, and without it the go.d Docker
# service-discovery collector fails outright with "permission denied while
# trying to connect to the Docker daemon socket" (confirmed via a real
# docker-compose run replicating deploy/prod's netdata service: pid: host,
# the same volumes, and the real /var/run/docker.sock bind mount). Fix:
# replicate the same group-membership trick ourselves, scoped to plain
# Docker only (this project has no balenaEngine usage, so that half of the
# official entrypoint's detection logic is intentionally not reproduced).
if [ -S /var/run/docker.sock ]; then
    docker_sock_gid="$(stat -c '%g' /var/run/docker.sock)"
    docker_sock_group="$(getent group "${docker_sock_gid}" | cut -d: -f1)"
    if [ -z "${docker_sock_group}" ]; then
        # No existing group owns this GID on the host side of the mount --
        # create one so `addgroup netdata <name>` below has a name to
        # target (Alpine's addgroup needs an existing group, not a bare
        # GID, to add a user to).
        docker_sock_group="dockerhost"
        addgroup -g "${docker_sock_gid}" "${docker_sock_group}"
    fi
    addgroup netdata "${docker_sock_group}"
fi

# -D: stay in the foreground as PID 1 instead of the traditional
# double-forking daemon behavior -- standard for any process meant to be a
# container's main process.
exec /opt/netdata/usr/sbin/netdata -D
