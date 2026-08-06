#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker HEALTHCHECK for the combined syslog+fluent-bit container.
#
# WHY per-process checks, not just "is the container running": Docker's
# HEALTHCHECK mechanism only ever reports ONE exit code for the whole
# container, but this container supervises two independent daemons
# (fluent-bit, syslog-ng) that can each fail without killing the other's
# process directly (only entrypoint.sh's fail-fast supervisor loop, on
# noticing one is gone, tears the whole container down -- see that script's
# own comment for why). This check proves BOTH are actually alive and
# responsive on every interval, rather than trusting that "the container
# process is still running" implies both children are healthy.
#
# fluent-bit: `pgrep -f` against the full command line, NOT `pgrep -x
# fluent-bit` -- confirmed live (on amd64; the same reasoning applies
# unchanged on arm64, see Dockerfile/entrypoint.sh's arm64-portability
# comments) that /proc/<pid>/comm for this process stays the bundled
# ld-linux interpreter's own basename ("ld-linux-x86-64" on amd64,
# "ld-linux-aarch64" on arm64) for its entire lifetime, never "fluent-bit",
# because comm reflects the ORIGINAL execve() target. Since fluent-bit is
# invoked through an EXPLICIT ld-linux interpreter argument (see
# Dockerfile/entrypoint.sh's own comments on why: bundling fluent-bit's
# glibc closure into Alpine), the kernel's execve() target really is the
# interpreter, not fluent-bit itself -- ld.so manually loads and jumps to
# fluent-bit's entry point within the SAME process without ever calling
# execve() again, so the kernel-level bookkeeping never updates. `pgrep -x`
# (exact comm match) is therefore structurally unable to find this process;
# matching the full cmdline (which does contain the real fluent-bit config
# path) is the correct equivalent of today's production `fluent-bit -V`
# exec-form check here: it proves the process exists, not that its internal
# pipeline is flowing.
#
# syslog-ng: `syslog-ng-ctl stats` (not just process presence) is a REAL
# probe against the running daemon's own control socket, matching
# AG-VAL-018's "must use a real query/response probe" spirit and today's
# production `syslog-ng-ctl healthcheck --timeout 5` check exactly.
#
# Structured status file (advisor-recommended, mirrors
# services/watchdog/healthcheck.sh's own status.json convention): written on
# every invocation so a future Admin UI/watchdog integration can show
# PER-PROCESS state instead of only the container's single pass/fail exit
# code, without needing a second healthcheck mechanism. Path is under
# /var/lib/lancache-syslog-data (uid-10001-owned at build time, matching the
# uid this script itself runs as -- see Dockerfile's USER), not the /data
# named volume fluent-bit's own storage/self-log share, to avoid any
# ownership assumption about that volume's first-use population.
set -uo pipefail
# NOT `set -e`: this script deliberately continues checking syslog-ng even
# if the fluent-bit check already failed, so the status file and final exit
# code reflect BOTH processes' real state in one pass rather than stopping
# at the first failure (see AG-VAL-030 -- this exact "does a failing
# sub-check abort the rest of the script" question needs to be a deliberate
# choice, not an accident of `set -e`).

STATUS_FILE="${SYSLOG_HEALTH_STATUS_FILE:-/var/lib/lancache-syslog-data/health-status.json}"
CTL_SOCKET="${SYSLOG_NG_CTL_SOCKET:-/var/lib/lancache-syslog-data/syslog-ng.ctl}"
DATA_LOSS_ALERT_FILE="${DATA_LOSS_ALERT_FILE:-/var/lib/lancache-syslog-data/data-loss-alert-active}"
# Same margin reasoning as services/watchdog/healthcheck.sh's max_age: wide
# enough that a single slow detector cycle doesn't flap this field, narrow
# enough that a stale alert marker from an outage that has since cleared
# doesn't linger forever. DATA_LOSS_CHECK_INTERVAL_SECONDS is entrypoint.sh's
# own interval for the SAME detector loop that touches this marker file, so
# reusing it here keeps the two in sync without a second tunable.
data_loss_check_interval="${DATA_LOSS_CHECK_INTERVAL_SECONDS:-60}"
case "$data_loss_check_interval" in
    ''|*[!0-9]*) data_loss_check_interval=60 ;;
esac
alert_max_age=$(( 10#$data_loss_check_interval * 3 ))
if [ "$alert_max_age" -lt 60 ]; then
    alert_max_age=60
fi

fluent_bit_ok=0
if pgrep -f '/opt/fluent-bit-glibc/bin/fluent-bit' >/dev/null 2>&1; then
    fluent_bit_ok=1
fi

syslog_ng_ok=0
if syslog-ng-ctl stats --control="$CTL_SOCKET" >/dev/null 2>&1; then
    syslog_ng_ok=1
fi

data_loss_alert_active=0
if [ -f "$DATA_LOSS_ALERT_FILE" ]; then
    alert_mtime=$(stat -c %Y "$DATA_LOSS_ALERT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    alert_age=$(( now - alert_mtime ))
    if [ "$alert_age" -ge 0 ] && [ "$alert_age" -lt "$alert_max_age" ]; then
        data_loss_alert_active=1
    fi
fi

# Best-effort write: a failure here (e.g. the status directory temporarily
# unwritable) must not itself flip an otherwise-healthy container to
# unhealthy -- the actual pass/fail signal is the exit code below, driven
# only by the two process checks, never by this file's own write success.
cat > "$STATUS_FILE" 2>/dev/null <<JSON || true
{
  "checked_at": $(date +%s),
  "fluent_bit": "$( [ "$fluent_bit_ok" -eq 1 ] && echo up || echo down )",
  "syslog_ng": "$( [ "$syslog_ng_ok" -eq 1 ] && echo up || echo down )",
  "data_loss_alert_active": $( [ "$data_loss_alert_active" -eq 1 ] && echo true || echo false )
}
JSON

if [ "$fluent_bit_ok" -ne 1 ]; then
    echo "syslog-combined healthcheck: fluent-bit process not found" >&2
fi
if [ "$syslog_ng_ok" -ne 1 ]; then
    echo "syslog-combined healthcheck: syslog-ng-ctl stats probe failed against $CTL_SOCKET" >&2
fi

# Data-loss alerts deliberately do NOT fail this healthcheck (documented
# design decision, not an oversight): both supervised processes are still
# genuinely alive and running normally when this condition fires -- the
# problem is a bad bind-mount owner, a full disk, or a runtime permission
# change on the log-root, none of which a container restart fixes. Failing
# the healthcheck here would only crash-loop a container that isn't actually
# down, without addressing the real cause; the alert is instead surfaced
# through fluent-bit's own forwarded pipeline (see fluent-bit.conf's
# data-loss-detector.syslog input) and this status file's own
# data_loss_alert_active field for a future Admin UI/watchdog integration.
if [ "$fluent_bit_ok" -eq 1 ] && [ "$syslog_ng_ok" -eq 1 ]; then
    exit 0
fi
exit 1
