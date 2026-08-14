#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Silent-data-loss detector for the combined syslog-ng + fluent-bit
# container. Run in a loop by entrypoint.sh (as the same uid as syslog-ng,
# 10001, since it only needs read access to syslog-ng's own control socket
# and destination tree -- both already owned by that uid) alongside the
# rotation loop.
#
# WHY this exists: real, reproduced bug (see this PR's closing report for
# the exact commands) -- a syslog-ng destination directory whose bind-mount
# host path is owned root:root (Docker's own default when the host directory
# doesn't already exist before first container start) silently swallows
# every message a non-root syslog-ng receives: `syslog-ng-ctl stats` still
# increments the destination's `processed` counter, syslog-ng logs no error
# at all, and zero bytes ever reach disk. An operator watching `docker logs`
# or the stats counter alone would see a perfectly healthy-looking pipeline
# while every log line is silently discarded.
#
# WHY a stats-vs-disk comparison, not a permission check: the failure mode
# above is cause-agnostic in production -- a bad bind-mount owner is only ONE
# way to trigger it; a disk that fills up mid-run, or an operator changing
# permissions on a live mount, produce the identical silent symptom (stats
# says processed, disk says otherwise). Checking for a specific cause (e.g.
# "is the directory owned by 10001") would miss the other two, so this
# compares syslog-ng's own belief (the stats counter) against physical
# reality (actual bytes on disk) instead, and treats a live mismatch as the
# signal regardless of why it happened.
#
# Verified real (2026-08-06, on a self-hosted runner): reproduced the exact
# bind-mount-ownership condition above (log-root left root:root 0755, real
# syslog-ng 4.7.1-r1 from Alpine 3.20 running as uid 10001 under
# `--cap-drop ALL`) and confirmed this script's comparison correctly reports
# `processed_delta=1 bytes_delta=0` and exits non-zero; a matched control run
# against a correctly-owned (10001:10001) log-root delivered the same message
# and reported `bytes_delta=71` with exit 0 -- proving both a true positive
# and no false positive on the healthy path, not just the alerting logic in
# isolation.
#
# Re-verified live on the 3.24 base (issue #1554, syslog-ng 4.11.0-r0): a
# real end-to-end run (nginx-style tail input -> fluent-bit -> syslog-ng
# RFC5424 delivery, `--cap-drop ALL`/`--cap-add DAC_READ_SEARCH`) produced no
# false alert -- `data_loss_alert_active: false` in health-status.json with
# bytes actually landing on disk -- confirming this script's control-path
# behavior held across the base-image bump.
set -euo pipefail

CTL_SOCKET="${1:?usage: data-loss-detector.sh <ctl-socket-path> <log-root>}"
LOG_ROOT="${2:?usage: data-loss-detector.sh <ctl-socket-path> <log-root>}"

# Extract the `processed` counter for the d_lancache destination from
# syslog-ng-ctl's semicolon-delimited stats format (confirmed live,
# 2026-08-05: header is
# `SourceName;SourceId;SourceInstance;State;Type;Number`, and the
# destination's own row is `destination;d_lancache;;<state>;processed;<N>` --
# not assumed from syslog-ng's docs alone, read directly off a real running
# instance).
processed_count() {
    syslog-ng-ctl stats --control="$CTL_SOCKET" 2>/dev/null \
        | awk -F';' '$1 == "destination" && $2 == "d_lancache" && $5 == "processed" {print $6}'
}

# Total bytes actually present under the log root right now. A plain `find
# ... -exec stat -c%s {} +` sum (not `du`, which reports block-rounded disk
# usage and would mask a small real write inside a large block) so a single
# byte landing on disk is visible as a non-zero delta.
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
