#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Process supervisor for the combined fluent-bit + syslog-ng container.
# Replaces the previous two separate services (`syslog` = fluent-bit,
# `syslog-ng` = central receiver) with one container running both, per the
# maintainer's explicit decision to accept the crash-coupling/healthcheck-
# granularity/version-currency trade-offs a single container brings, in
# exchange for one image to build/scan/patch instead of two. See this PR's
# body for the full real-vs-POC comparison (fluent-bit binary strategy,
# capability posture, the two-privileged-port findings) and for why each
# trade-off below is accepted rather than silently ignored.
#
# WHY a hand-rolled trap/wait loop, not tini/s6-overlay/supervisord: for
# four long-running children with a single dependency ordering (syslog-ng
# before fluent-bit's first connection attempt) and one shared fail-fast
# policy (any child exiting tears the whole container down -- see below),
# a real init system adds a second piece of software's own semantics/CVE
# surface without changing this container's actual supervision behavior.
# Revisit if a future requirement needs independent per-process restart
# (see the "Nachteise"/trade-offs section of this PR's body for why that
# is NOT implemented here).
set -eu

SYSLOG_MAX_FILE_MB="${SYSLOG_MAX_FILE_MB:-100}"
SYSLOG_COMPRESSION_LEVEL="${SYSLOG_COMPRESSION_LEVEL:-19}"
SYSLOG_NG_ROTATE_INTERVAL_SECONDS="${SYSLOG_NG_ROTATE_INTERVAL_SECONDS:-300}"
# Mandatory hardening (task requirement, not optional): periodic check that
# syslog-ng's own "processed" stats counter and the real bytes on disk under
# LOG_ROOT actually agree -- see data-loss-detector.sh's header comment for
# the full reasoning and the real reproduction this was verified against.
DATA_LOSS_CHECK_INTERVAL_SECONDS="${DATA_LOSS_CHECK_INTERVAL_SECONDS:-60}"

LOG_ROOT="/var/log/lancache-syslog-ng"
STATE_DIR="/var/lib/lancache-syslog-data"
SYSLOG_NG_CTL="${STATE_DIR}/syslog-ng.ctl"
DATA_LOSS_LOG="${STATE_DIR}/data-loss-detector.log"
DATA_LOSS_ALERT_FILE="${STATE_DIR}/data-loss-alert-active"

# --- Start syslog-ng first (fluent-bit's syslog output would otherwise fail
# its first connection attempt). Config is a static file baked into the
# image (services/syslog/syslog-ng.conf) -- nothing in it varies per
# deployment, unlike production's previous inline-heredoc version, which
# only needed to be generated at runtime because it ran as root and had to
# inject a root-only gid workaround (see that file's own header comment for
# why this container no longer needs that workaround at all).
#
# --persist-file/--pidfile/--control: redirected to STATE_DIR (baked into
# the image, owned by this container's fixed uid at build time -- see
# Dockerfile) instead of syslog-ng's own defaults under /run, which is not
# writable by a non-root uid in this base image.
syslog-ng -F --no-caps \
    --persist-file="${STATE_DIR}/syslog-ng.persist" \
    --pidfile="${STATE_DIR}/syslog-ng.pid" \
    --control="$SYSLOG_NG_CTL" &
SYSLOG_NG_PID=$!

# Give syslog-ng a moment to bind its port before fluent-bit's first
# connection attempt -- a fixed sleep is an accepted simplification here
# (matching the POC's own documented choice): fluent-bit's syslog output
# retries its own connection on failure (confirmed live, see this PR's
# verification log), so a slow-starting syslog-ng delays first delivery
# rather than losing data outright.
sleep 1

# --- fluent-bit: the pinned production binary (cr.fluentbit.io/fluent/
# fluent-bit:3.2.10, the EXACT digest deploy/prod/docker-compose.yml already
# used before this PR) invoked through its own bundled glibc interpreter
# (see Dockerfile's COPY --from=fluent-bit-src stage and its own comment for
# why: Alpine's only native fluent-bit package lives in the unpinnable
# edge/testing repo, and this project's pinning discipline does not accept
# that). Static config baked into the image (services/syslog/fluent-bit.conf,
# a 1:1 port of the previous ~600-line CLI-flag pipeline).
#
# The interpreter's filename is architecture-dependent (ld-linux-x86-64.so.2
# on amd64, ld-linux-aarch64.so.1 on arm64, confirmed live for both) -- this
# was a real bug in this file's first version, which hardcoded the amd64
# name and only ever ran on amd64 during this PR's own verification (see
# this PR's report for that gap being named honestly). Read the discovered
# name the Dockerfile's build-time RUN step wrote to
# ld-interp-name (see Dockerfile's own comment on that step) instead of
# hardcoding either arch's filename here.
ld_interp="$(cat /opt/fluent-bit-glibc/ld-interp-name)"
"/opt/fluent-bit-glibc/lib/$ld_interp" \
    --library-path /opt/fluent-bit-glibc/lib \
    /opt/fluent-bit-glibc/bin/fluent-bit -c /etc/fluent-bit/fluent-bit.conf &
FLUENT_BIT_PID=$!

# --- Rotation + zstd compression loop: same fixed-threshold logic as the
# previous production syslog-ng service, with ONE portability fix ported
# from the POC (verified again here, not merely copy-pasted): `find -size
# +100M` is GNU-find-only syntax -- BusyBox find (Alpine's default) and even
# a from-source GNU find would still not matter here, since Alpine's find
# only documents a byte/kbyte/block `-size` suffix, no `M` suffix at all, so
# the pattern would silently never match (no error; rotation just never
# fires). Replaced with a plain `stat -c%s` byte-count comparison, which
# both BusyBox and GNU stat support identically.
rotate_loop() {
    limit_bytes=$((SYSLOG_MAX_FILE_MB * 1024 * 1024))
    while true; do
        sleep "$SYSLOG_NG_ROTATE_INTERVAL_SECONDS"
        find "$LOG_ROOT" -type f -name '*.log' 2>/dev/null | while read -r f; do
            size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
            if [ "$size" -gt "$limit_bytes" ]; then
                ts="$(date -u +%Y%m%dT%H%M%SZ)"
                mv "$f" "${f}.${ts}"
                # Same-uid signal (both this loop and syslog-ng itself run
                # as the container's one fixed uid, see Dockerfile's USER):
                # needs no CAP_KILL, unlike a cross-uid signal would.
                kill -HUP "$SYSLOG_NG_PID" 2>/dev/null || true
                zstd -q -T0 "-${SYSLOG_COMPRESSION_LEVEL}" --rm "${f}.${ts}" 2>/dev/null || true
            fi
        done
    done
}
rotate_loop &
ROTATE_PID=$!

# --- Silent-data-loss detector loop (mandatory hardening, not optional --
# see this PR's task description): runs data-loss-detector.sh back-to-back
# (its own sleep IS the check interval, so this loop adds no extra delay),
# appending its own stdout/stderr to DATA_LOSS_LOG so fluent-bit's own
# data-loss-detector.syslog input (see fluent-bit.conf) forwards every
# ALERT through the same Admin UI-visible pipeline as every other source.
# On a real alert, also touches DATA_LOSS_ALERT_FILE (mtime-checked by
# healthcheck.sh) so a future Admin UI/watchdog integration can surface the
# condition without parsing this log file's text.
data_loss_detector_loop() {
    while true; do
        if ! /usr/local/bin/data-loss-detector.sh "$SYSLOG_NG_CTL" "$LOG_ROOT" "$DATA_LOSS_CHECK_INTERVAL_SECONDS" >> "$DATA_LOSS_LOG" 2>&1; then
            date -u +%FT%TZ > "$DATA_LOSS_ALERT_FILE"
        fi
    done
}
data_loss_detector_loop &
DETECTOR_PID=$!

# --- Signal forwarding + fail-fast supervision: if ANY of the four
# supervised processes exits, the whole container is treated as failed (not
# silently restarted in place) -- matching the POC's own documented,
# deliberate choice not to invent a per-process restart policy for two
# independent daemons sharing one container. Docker's own `restart:` policy
# on the outer container is what recovers from this, restarting all four
# together. This is the accepted crash-coupling trade-off named in this PR's
# body, not an oversight: this container's rotation and detector loops are
# both unconditional `while true` loops with no expected exit path, so their
# death (like fluent-bit's or syslog-ng's) always indicates a real bug,
# never a normal condition -- there is no "acceptable" subset of the four to
# exclude from fail-fast.
term_handler() {
    kill "$SYSLOG_NG_PID" "$FLUENT_BIT_PID" "$ROTATE_PID" "$DETECTOR_PID" 2>/dev/null || true
    # `|| true`, deliberately: under this script's own `set -eu`, a bare
    # `wait` that reaps a child which itself exited non-zero (e.g. a process
    # that received SIGTERM and exited via its own signal-death convention)
    # would otherwise trigger errexit INSIDE this trap handler and abort it
    # before reaching `exit 0` below -- confirmed live (2026-08-06, AG-VAL-030):
    # the sibling fail-fast path a few lines down hit exactly this failure
    # mode first (a bare `wait -n` there silently skipped its own follow-up
    # log line and cleanup kill once a child died non-zero), which is what
    # prompted defending this trap the same way rather than assuming it was
    # already safe.
    wait 2>/dev/null || true
    exit 0
}
trap term_handler TERM INT

# `|| true`: same `set -eu`/errexit hazard as term_handler above, confirmed
# live (2026-08-06) with a real reproduction, not just reasoned through --
# `wait -n` returning the dead child's own (non-zero, e.g. 137 for a
# SIGKILLed process) exit status otherwise aborts this script immediately
# via errexit, silently skipping the FATAL log line and the explicit
# cleanup kill below (Docker's container teardown still happens regardless,
# since PID 1 exiting always tears down every remaining process in the
# container, but without ever explaining why in `docker logs`, and with an
# accidental rather than deliberate exit code). `wait -n` itself is still
# the right primitive (it blocks until the FIRST of these four processes
# exits, for ANY reason -- exactly the fail-fast trigger this container
# wants, since none of the four ever exits during normal operation); only
# its exit status needs to be discarded here, not its blocking behavior.
wait -n "$SYSLOG_NG_PID" "$FLUENT_BIT_PID" "$ROTATE_PID" "$DETECTOR_PID" || true
echo "FATAL: a supervised process exited -- tearing down the combined container (fail-fast, no independent per-process restart)" >&2
kill "$SYSLOG_NG_PID" "$FLUENT_BIT_PID" "$ROTATE_PID" "$DETECTOR_PID" 2>/dev/null || true
exit 1
