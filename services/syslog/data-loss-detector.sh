#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: silent-data-loss detector; compares syslog-ng's stats counter
# against real bytes on disk, run in a loop by entrypoint.sh as uid 10001.
# Why: a root:root bind-mount destination silently swallows messages with
# no error logged; stats-vs-disk also catches a full disk or perm change.
# From: Issue #1428 | PR #1431
set -euo pipefail

CTL_SOCKET="${1:?usage: data-loss-detector.sh <ctl-socket-path> <log-root>}"
LOG_ROOT="${2:?usage: data-loss-detector.sh <ctl-socket-path> <log-root>}"

# What: extracts the `processed` counter for the d_lancache destination
# from syslog-ng-ctl's semicolon-delimited stats format.
# Why: field layout confirmed live against a real running instance
# (`destination;d_lancache;;<state>;processed;<N>`), not assumed from docs.
# From: Issue #1428 | PR #1431
processed_count() {
    syslog-ng-ctl stats --control="$CTL_SOCKET" 2>/dev/null \
        | awk -F';' '$1 == "destination" && $2 == "d_lancache" && $5 == "processed" {print $6}'
}

# What: sums real bytes under the log root via `find -exec stat -c%s`.
# Why: not `du`, whose block-rounded output would mask a small real write
# inside a large block -- a single byte landing must show as a nonzero delta.
# From: Issue #1428 | PR #1431
disk_bytes() {
    find "$LOG_ROOT" -type f -exec stat -c%s {} + 2>/dev/null \
        | awk '{s+=$1} END {print s+0}'
}

before_processed="$(processed_count)"
before_bytes="$(disk_bytes)"
sleep "${3:-5}"
after_processed="$(processed_count)"
after_bytes="$(disk_bytes)"

processed_delta=$(( after_processed - before_processed ))
bytes_delta=$(( after_bytes - before_bytes ))

echo "processed_delta=${processed_delta} bytes_delta=${bytes_delta}"
if (( processed_delta > 0 && bytes_delta <= 0 )); then
    echo "ALERT: silent data loss detected -- syslog-ng processed ${processed_delta} new message(s) but the destination tree grew ${bytes_delta} bytes"
    exit 1
fi
echo "OK: no silent data loss detected"
