#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# main loop well before an operator would otherwise notice. watchdog.sh's
# main loop also re-runs write_status() a second time after maybe_purge()/
# maybe_prune_syslog() specifically so the once-daily long-running purge
# scan doesn't age this file out on its own.
max_age=$(( CHECK_INTERVAL * 3 ))
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
