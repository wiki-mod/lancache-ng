#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker HEALTHCHECK for the watchdog container. Existence-only ("test -f
# status.json") is not enough: watchdog.sh's main loop writes status.json
# once per cycle, but a stall (e.g. a hung docker-socket-proxy before the
# --max-time curl fix, or any future stuck step) leaves the file sitting
# there from the last successful cycle -- "exists" stays true forever even
# though the daemon behind it is wedged. This checks the file's mtime
# instead: it must have been refreshed within a bounded multiple of
# CHECK_INTERVAL, or the container is reported unhealthy.
set -euo pipefail

STATUS_FILE="${STATUS_FILE:-/var/run/watchdog/status.json}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

# Same digit-only guard watchdog.sh itself applies to CHECK_INTERVAL: this
# script runs as its own process (Docker HEALTHCHECK), so it does not
# inherit watchdog.sh's already-validated in-memory value, only the raw
# environment variable.
case "$CHECK_INTERVAL" in
    ''|*[!0-9]*) CHECK_INTERVAL=30 ;;
esac

# 3x CHECK_INTERVAL, floored at 60s: generous enough that a single slow
# cycle (e.g. three sequential --max-time-bounded curl calls) never causes a
# false-positive unhealthy report, while still catching a genuinely stuck
# main loop well before an operator would otherwise notice. Before #842's
# retention-engine extraction, watchdog.sh's own main loop also ran the
# potentially minutes-long maybe_purge()/maybe_prune_syslog() scans inline
# and had to re-run write_status() a second time afterward so this file's
# mtime wouldn't age out during that scan. Since #842, those scans run in
# retention.sh's own separate process and can no longer block this loop at
# all -- the margin here is now pure safety margin for the curl calls
# check_and_maybe_restart()/probe_docker_socket_proxy() make, not a purge
# workaround.
#
# `10#` forces base-10 evaluation (found live, 2026-07-31, PR #1347's CI):
# the digit-only guard above accepts ANY all-digits string, including one
# with a leading zero -- CHECK_INTERVAL is routinely set to exactly such a
# value by scripts/tracked/simulations/syslog-forwarding-simulation.sh, which deliberately uses
# the last 8 digits of a nanosecond timestamp as a unique per-run marker
# (see that script's own comment). Without the `10#` prefix, Bash's `$(( ))`
# treats a leading-zero numeric literal as octal, and a marker whose
# remaining digits happen to include an 8 or a 9 (invalid in octal, e.g.
# "00563179") makes this arithmetic expansion itself fail ("value too great
# for base") -- under this script's own `set -euo pipefail`, that aborts the
# healthcheck with a nonzero exit, which Docker reports as "unhealthy" even
# though watchdog's own main loop is running completely normally. Confirmed
# live: `bash -c 'set -euo pipefail; CHECK_INTERVAL="00563179"; max_age=$((
# CHECK_INTERVAL * 3 ))'` fails with exactly that error; the same line with
# `10#$CHECK_INTERVAL` computes 1689537 correctly. This is a ~1-in-13 chance
# per run given the marker's random last-8-digits shape, which is why it
# surfaced as an intermittent "watchdog did not become healthy" CI failure
# rather than a deterministic one.
max_age=$(( 10#$CHECK_INTERVAL * 3 ))
if [ "$max_age" -lt 60 ]; then
    max_age=60
fi

mtime=$(stat -c %Y "$STATUS_FILE" 2>/dev/null) || {
    echo "watchdog healthcheck: $STATUS_FILE does not exist yet" >&2
    exit 1
}

now=$(date +%s)
age=$(( now - mtime ))
if [ "$age" -lt 0 ]; then
    age=0
fi

if [ "$age" -ge "$max_age" ]; then
    echo "watchdog healthcheck: $STATUS_FILE is ${age}s old (max ${max_age}s) -- main loop looks stalled" >&2
    exit 1
fi

exit 0
