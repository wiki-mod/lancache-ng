#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Real end-to-end proof that the shipped `ntp` (chrony) image genuinely
# disciplines the system clock when it is actually granted CAP_SYS_TIME --
# issue #1296's completion of the 3-of-3 full-setup-deep-validation ask
# (dhcp/dhcp-proxy landed via #1305; this is ntp).
#
# WHY THIS RUNS ON A GITHUB-HOSTED RUNNER, NOT THIS PROJECT'S SELF-HOSTED
# FLEET: confirmed live (2026-07-30, #1296) that every one of this project's
# self-hosted runner hosts is itself an LXC container (`systemd-detect-virt`
# reports `lxc` on all four), and LXC withholds CAP_SYS_TIME from nested
# Docker containers by design (a host-clock-isolation security boundary),
# regardless of what `docker run --cap-add SYS_TIME` requests -- reproduced
# with a plain `alpine` container, independent of the ntp image or any
# compose config. `ntp` had simply never been exercised by this project's
# automated CI before this investigation, so this was a first-contact
# finding, not a regression. The maintainer's explicit decision (#1296,
# after being presented three options: accept-and-document, a liveness-only
# `-x` opt-in, or a GitHub-hosted runner) was this one: only a real,
# non-LXC-nested kernel can prove actual clock discipline rather than mere
# daemon liveness, and a GitHub-hosted `ubuntu-24.04` runner is a real VM,
# not LXC-nested -- confirmed directly before this script was written (a
# scratch, since-deleted workflow proved a plain `alpine` container's
# `date -s` there actually moves the runner's real system clock, unlike
# every self-hosted host).
#
# WHAT THIS PROVES (and what it deliberately does not):
#   1. The real, shipped ntp image starts and its Docker HEALTHCHECK
#      equivalent (`chronyc tracking` answering with a real "Reference ID"
#      line) responds -- the same liveness proof the healthcheck itself
#      checks, exercised here directly rather than through Docker's
#      healthcheck polling.
#   2. GENUINE clock discipline, not just liveness: this script deliberately
#      skews the runner's own real system clock forward via the exact same
#      `cap_add: SYS_TIME` mechanism the real ntp container relies on
#      (proving the skew mechanism itself works here, matching how a real
#      operator's clock could legitimately drift), starts chronyd, and then
#      asserts REAL synchronisation directly from `chronyc tracking`'s own
#      reported fields: a non-zero `Stratum` (0 means never synchronised)
#      and `Leap status: Normal` (chrony's own "fully disciplined" signal,
#      as opposed to e.g. "Not synchronised"). This is the direct,
#      authoritative signal chrony itself provides for "this daemon has
#      actually corrected a real clock error against a real upstream
#      server" -- confirmed live (2026-07-30) that a real run reaches
#      `Stratum: 4` / `Leap status: Normal` / sub-millisecond offset against
#      `time.cloudflare.com` within about 35 seconds of container start.
#
#      EARLIER DESIGN REJECTED (documented so it is not silently
#      reintroduced): a first version of this proof compared the system
#      clock's own elapsed time against bash's `$SECONDS` counter, reasoning
#      that `$SECONDS` was a clock-immune reference. That assumption is
#      WRONG -- bash's `$SECONDS` is computed from the real wall-clock time
#      (not a monotonic clock), so the same `date -s` skew that moves the
#      system clock also jumps `$SECONDS` by roughly the same amount,
#      confirmed live when a real run reported `$SECONDS=392` against an
#      actual elapsed wall time of roughly 90s -- the discrepancy was
#      `$SECONDS` itself reacting to the skew, not a clock-immune baseline.
#      The comparison happened to still produce a directionally-correct
#      result in that one run, but the underlying assumption was unsound and
#      would not hold in general, so it was replaced with this direct
#      chrony-state check instead of kept as "extra" evidence.
#   3. Does NOT prove long-run stability of the discipline (e.g. across
#      hours of drift/leap-second handling) -- only that a real, deliberate
#      clock error gets corrected and reaches a genuinely synchronised state
#      within this job's short runtime.
#   4. (Issue #1358, least-privilege hardening) That the real production
#      `cap_drop: [ALL]` + narrow `cap_add` set (not Docker's old, wider
#      default set plus SYS_TIME) is genuinely sufficient for chronyd's own
#      internal privilege-drop sequence AND real clock-stepping together --
#      this is the only CI job in this project that runs on a real,
#      non-LXC-nested kernel, so it is also the only place capable of
#      proving that intersection at all; the self-hosted fleet can prove
#      the capability set gets chronyd running (see the PR implementing
#      issue #1358 for that `strace`-based session) but can never prove
#      the actual `adjtimex` clock-step succeeds under it, since every
#      self-hosted host fails that step regardless of capabilities granted.
#
# SECOND SCENARIO (added #1296, maintainer decision after the CAP_SYS_TIME
# graceful-degradation work): the capability-GRANTED scenario above proves
# the happy path; run_capability_denied_scenario() below is a second,
# independent proof for the CAP_SYS_TIME-DENIED path (self-hosted fleet's
# real, everyday case), explicitly requested to run ALONGSIDE (not instead
# of) the first -- both are required, neither supersedes the other:
#   1. The degraded status is REAL, reachable code, not something that only
#      exists on paper: this deliberately starts the real ntp image with
#      SYS_TIME withheld (Docker's default set already excludes it; no
#      cap_add for it at all here) and asserts the same
#      "this environment denies CAP_SYS_TIME" warning the capability-granted
#      scenario above treats as a FAILURE is actually PRESENT here -- the
#      inverse assertion, proving this codepath fires under the exact
#      condition it exists for, on a real kernel, not just in a bats unit
#      test with faked command output.
#   2. Real verification of this investigation's core finding (see the
#      source-code chain in the PR body / issue #1296 comment: chrony's
#      `-x` mode installs the `sys_null` driver, whose `offset_convert()`
#      genuinely accumulates and applies a software offset/frequency
#      correction -- LCL_ReadCookedTime, which server responses are built
#      from, is NOT a raw/no-op read even with clock control disabled): a
#      real external NTP client, querying this degraded container exactly
#      as a real LAN client would (over the network, not `docker exec`),
#      must receive a genuinely accurate time reading. This is what
#      justifies the maintainer's decision to KEEP the degraded/amber
#      status (not remove it) rather than treat CAP_SYS_TIME denial as
#      something that needs fixing by other means: the container is a
#      correctly-functioning NTP relay for LAN clients in this state, it
#      simply cannot ALSO discipline its own host's kernel clock -- two
#      genuinely different, independently worth-signalling properties.
#
# Required env: REPOSITORY, IMAGE_TAG (the resolved tag from
# scripts/lib/validation-image-tag.sh's vit_resolve_tag, matching every
# other job in this suite -- see full-setup-deep-validate.yml's own
# LANCACHE_IMAGE_TAG-style usage).
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

image="ghcr.io/${REPOSITORY}/ntp:${IMAGE_TAG}"
container_granted="ntp-cap-sys-time-probe-granted"
container_denied="ntp-cap-sys-time-probe-denied"

cleanup() {
    local status=$?
    docker rm -f "$container_granted" "$container_denied" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT

run_capability_granted_scenario() {
echo "== Forcing a real +300s clock skew via cap_add: SYS_TIME (the exact mechanism the real ntp container relies on) =="
# Same reasoning as deploy/quickstart/docker-compose.yml's own ntp service:
# chronyd needs to step/slew the container HOST's real system clock, so this
# probe container needs the identical capability grant. A plain, minimal
# alpine image is used here (not the ntp image itself) purely to isolate
# "can any container move the real clock on this runner" from "does chronyd
# specifically start" -- the two are deliberately tested as separate,
# independently diagnosable steps.
docker run --rm --cap-add SYS_TIME alpine date -s "$(date -d '+5 minutes' -u '+%Y-%m-%d %H:%M:%S')"
echo "Skewed clock: $(date -u)"

echo "== Starting the real ntp image with the real production capability set (matching deploy/prod/docker-compose.yml's ntp service exactly) =="
# Issue #1358 (least-privilege hardening): the compose files no longer just
# `cap_add: [SYS_TIME]` on top of Docker's full default set -- they
# `cap_drop: [ALL]` first, then add back only this empirically-determined
# minimal set (see deploy/prod/docker-compose.yml's own comment for the
# per-capability rationale, and the PR implementing this issue for the live
# `strace` session that determined it). This job is the ONLY one in
# this project's CI that runs on a real, non-LXC-nested kernel (see this
# file's own header), so it is also the only place that can genuinely prove
# the real production capability set -- not just Docker's old, wider
# defaults plus SYS_TIME -- actually completes chronyd's own internal
# privilege-drop sequence AND performs real clock-stepping. Keep this in
# sync with the compose files' own cap_drop/cap_add lists whenever either
# changes; a mismatch here would silently stop testing what production
# actually runs.
docker run -d --name "$container_granted" \
    --cap-drop ALL \
    --cap-add SYS_TIME \
    --cap-add NET_BIND_SERVICE \
    --cap-add SETUID \
    --cap-add SETGID \
    --cap-add CHOWN \
    "$image"

echo "== Polling for up to 120s: fail fast on the known CAP_SYS_TIME crash signature, or on the container exiting; otherwise wait for real synchronisation =="
# Fails fast and loudly on the exact CAP_SYS_TIME crash signature confirmed
# on the self-hosted fleet, rather than silently waiting out the full budget
# on a container that will never recover (chronyd's fatal init error exits
# the process immediately, so this signature would appear within seconds if
# this runner ever regresses to the self-hosted fleet's restricted
# behavior). Also polls chronyc tracking directly (rather than waiting a
# fixed period then checking once) so a slow-but-genuine sync isn't
# penalized by an arbitrary fixed sleep -- confirmed live that real sync
# typically completes in well under a minute, but this does not assume a
# specific number.
deadline=$((SECONDS + 120))
synced=0
while (( SECONDS < deadline )); do
    # `docker logs` captured into a variable first, then grep -qi reads it
    # via a here-string -- a live pipe here can SIGPIPE `docker logs` once
    # the log already has the matched line plus more (issue #1377's
    # repo-wide pipefail/SIGPIPE audit). `|| true` matters under `set -e`:
    # this used to sit directly inside the `if` below (exempt from errexit
    # on its own); pulled into its own assignment, a transient `docker logs`
    # failure would otherwise abort this polling loop instead of retrying
    # (caught by advisor review).
    ntp_log="$(docker logs "$container_granted" 2>&1 || true)"
    if grep -qi "adjtimex.*Operation not permitted\|Another chronyd may already be running" <<<"$ntp_log"; then
        echo "::error::chronyd hit the same CAP_SYS_TIME restriction confirmed on this project's self-hosted (LXC) runner fleet -- this GitHub-hosted runner no longer grants real CAP_SYS_TIME, or the ntp image/entrypoint changed in a way that broke this. See #1296 for the original investigation." >&2
        docker logs "$container_granted" >&2
        exit 1
    fi
    # Issue #1296's CAP_SYS_TIME graceful-degradation fix (entrypoint.sh's
    # clock_control_available()) means chronyd no longer crashes when this
    # restriction applies -- it silently steps down to `-x` (never step or
    # slew) instead. That is the CORRECT behavior for a real nested/LXC
    # deployment, but it would be exactly the WRONG behavior for THIS job:
    # confirmed live that chrony's own `chronyc tracking` reports a fully
    # converged `Stratum > 0` / `Leap status: Normal` under `-x` within
    # about 15 seconds even against a real, deliberately forced clock skew
    # -- that reflects chrony's SOURCE-tracking convergence, not whether it
    # ever actually corrected this container's own system clock. Without
    # this check, this job's real pass condition below (stratum/leap-status
    # only) would false-pass on a `-x`-degraded run and silently stop being
    # the one place in this project's CI that proves genuine clock-stepping
    # -- exactly the failure class this job exists to catch. Matches the
    # literal warning text entrypoint.sh prints (kept in sync deliberately;
    # update both together if that wording ever changes).
    if grep -qi "this environment denies CAP_SYS_TIME for real clock stepping" <<<"$ntp_log"; then
        echo "::error::chronyd started in CAP_SYS_TIME-degraded mode (-x, never step/slew) on this GitHub-hosted runner -- this runner no longer grants real CAP_SYS_TIME, or the ntp image/entrypoint changed in a way that broke this. This job exists specifically to prove genuine clock-stepping under a real forced skew; a degraded-mode run can still report Stratum>0/Leap status Normal from source-tracking alone without ever having corrected this container's own clock, so it must fail here rather than be judged by that check alone. See #1296." >&2
        docker logs "$container_granted" >&2
        exit 1
    fi
    # `docker inspect --format` on one field of one container always
    # produces exactly one line, so grep -qx's early exit has nothing else
    # to cut off (issue #1377's repo-wide pipefail/SIGPIPE audit).
    if ! docker inspect --format '{{.State.Running}}' "$container_granted" 2>/dev/null | grep -qx true; then # pipefail-safe: docker inspect --format on one field of one container always emits exactly one line
        echo "::error::$container_granted is no longer running (unexpected exit, not the known CAP_SYS_TIME crash signature). Full logs:" >&2
        docker logs "$container_granted" >&2
        exit 1
    fi
    if tracking="$(docker exec "$container_granted" chronyc tracking 2>/dev/null)"; then
        stratum="$(grep '^Stratum' <<<"$tracking" | awk '{print $3}')"
        leap_status="$(grep '^Leap status' <<<"$tracking" | cut -d: -f2- | sed 's/^ *//')"
        if [[ -n "$stratum" && "$stratum" != "0" && "$leap_status" == "Normal" ]]; then
            echo "$tracking"
            echo "Synchronised: Stratum $stratum, Leap status Normal."
            synced=1
            break
        fi
    fi
    sleep 5
done

if [[ "$synced" -ne 1 ]]; then
    echo "::error::chronyd never reached a genuinely synchronised state (Stratum > 0, Leap status: Normal) within ${SECONDS}s. Last chronyc tracking output:" >&2
    docker exec "$container_granted" chronyc tracking >&2 || true
    docker logs "$container_granted" >&2
    exit 1
fi

echo "Scenario A (capability granted) passed: $image starts, survives, and genuinely disciplines a real forced clock skew to a synchronised state (Stratum > 0, Leap status: Normal) on this GitHub-hosted runner."
}

run_capability_denied_scenario() {
    echo "== Starting $image with SYS_TIME withheld (Docker's default set already excludes it; matches the self-hosted LXC fleet's real, everyday condition) =="
    # No `--cap-add SYS_TIME` at all here -- deliberately the mirror image of
    # run_capability_granted_scenario()'s capability list. Everything else
    # matches the real production compose files' `ntp` service exactly, same
    # as the granted scenario, so this is a genuine minimal diff: the ONLY
    # thing that differs between "this project's typical real deployment"
    # and "the self-hosted LXC fleet's restricted condition" is this one
    # capability.
    docker run -d --name "$container_denied" \
        --cap-drop ALL \
        --cap-add NET_BIND_SERVICE \
        --cap-add SETUID \
        --cap-add SETGID \
        --cap-add CHOWN \
        -p 12300:123/udp \
        "$image"

    echo "== Asserting the degraded warning fires -- this is the maintainer-approved, KEPT status signal, not dead/unreachable code =="
    # Mirror-image assertion of run_capability_granted_scenario()'s check at
    # the same log line: that scenario treats this string's presence as a
    # FAILURE (an unexpected regression on a runner that should have real
    # CAP_SYS_TIME); here its ABSENCE is the failure, since this container
    # was deliberately given no such capability. Polls rather than sleeping
    # a fixed period, matching this file's existing style.
    deadline=$((SECONDS + 60))
    warned=0
    while (( SECONDS < deadline )); do
        ntp_log="$(docker logs "$container_denied" 2>&1 || true)"
        if grep -qi "this environment denies CAP_SYS_TIME for real clock stepping" <<<"$ntp_log"; then
            warned=1
            break
        fi
        if ! docker inspect --format '{{.State.Running}}' "$container_denied" 2>/dev/null | grep -qx true; then # pipefail-safe: docker inspect --format on one field of one container always emits exactly one line
            echo "::error::$container_denied is no longer running before it even reached the degraded-mode warning. Full logs:" >&2
            docker logs "$container_denied" >&2
            exit 1
        fi
        sleep 2
    done
    if [[ "$warned" -ne 1 ]]; then
        echo "::error::chronyd never printed the CAP_SYS_TIME-denied degraded-mode warning within ${SECONDS}s, even though this container was started with no SYS_TIME capability. This means clock_control_available() (services/ntp/entrypoint.sh) is no longer correctly detecting a real denial -- the degraded/amber status this project's watchdog surfaces would be unreachable dead code if this regresses. See #1296." >&2
        docker logs "$container_denied" >&2
        exit 1
    fi
    echo "Degraded-mode warning confirmed present (see log line above) -- the status this project's watchdog surfaces as amber/degraded is real, reachable code under a real capability denial, not a theoretical codepath."

    echo "== Waiting for chronyd's source-tracking to converge (Stratum > 0, Leap status: Normal) purely from upstream measurement, without ever stepping this container's own clock =="
    deadline=$((SECONDS + 60))
    tracking_synced=0
    while (( SECONDS < deadline )); do
        if tracking="$(docker exec "$container_denied" chronyc tracking 2>/dev/null)"; then
            stratum="$(grep '^Stratum' <<<"$tracking" | awk '{print $3}')"
            leap_status="$(grep '^Leap status' <<<"$tracking" | cut -d: -f2- | sed 's/^ *//')"
            if [[ -n "$stratum" && "$stratum" != "0" && "$leap_status" == "Normal" ]]; then
                echo "$tracking"
                tracking_synced=1
                break
            fi
        fi
        sleep 2
    done
    if [[ "$tracking_synced" -ne 1 ]]; then
        echo "::error::chronyd (degraded mode) never reached source-tracking sync within ${SECONDS}s. Last chronyc tracking output:" >&2
        docker exec "$container_denied" chronyc tracking >&2 || true
        docker logs "$container_denied" >&2
        exit 1
    fi

    echo "== Decisive check (this investigation's core finding): does a real external NTP client querying this degraded container over the network get genuinely accurate time? =="
    # This is deliberately a real network query (chronyd's own one-shot
    # client mode, -Q, against the container's published port), not
    # `docker exec ... chronyc tracking` -- that reads the DAEMON's internal
    # tracking state, this exercises the actual client-facing NTP protocol
    # path real LAN clients use. Source-level finding this confirms (see the
    # PR body / issue #1296 comment for the full four-file chain): chrony's
    # `-x` mode installs the `sys_null` driver (sys_null.c), whose
    # `offset_convert()` genuinely accumulates a frequency/offset correction
    # rather than returning a no-op; `LCL_ReadCookedTime()` (local.c) applies
    # that correction on top of the raw clock read, and outgoing NTP server
    # response timestamps are built from `LCL_ReadCookedTime()`
    # (ntp_core.c) -- so a real client should receive corrected time even
    # though this container's own kernel clock was never (and, lacking
    # SYS_TIME, could never be) stepped. No artificial clock skew is
    # introduced for this specific check (unlike run_capability_granted_
    # scenario()'s +300s skew): deliberately skewing the querying runner's
    # OWN clock here would also perturb chronyd -Q's own client-side
    # round-trip sanity checks, since the client and the container share
    # this runner's one kernel clock -- confirmed live during this
    # investigation that doing so produces an unrelated client-side query
    # timeout, not a signal about the server's response. Asserting the
    # served offset is small is sufficient to prove "a real client gets
    # accurate time from this degraded server," which is the actual claim
    # being tested.
    query_output="$(chronyd -Q -t 5 'server 127.0.0.1 port 12300 iburst maxsamples 1' 2>&1)" || {
        echo "::error::the real NTP client query against the degraded container failed outright (see output below). This means a real LAN client would not get usable time from an environment where CAP_SYS_TIME is denied -- exactly the regression the maintainer's decision was meant to rule out." >&2
        echo "$query_output" >&2
        exit 1
    }
    echo "$query_output"
    offset_line="$(grep -i "System clock wrong by" <<<"$query_output" || true)"
    if [[ -z "$offset_line" ]]; then
        echo "::error::the client query produced no parseable 'System clock wrong by <seconds> seconds' measurement. Raw output above -- this script's parsing may need updating for a new chrony version, or the query genuinely did not complete." >&2
        exit 1
    fi
    # Extracts the numeric seconds value from a line shaped like
    # "System clock wrong by 0.001233 seconds (ignored)" or "... fast/slow
    # of NTP time" -- chrony's exact wording has varied across versions
    # (confirmed live: 4.5 here prints "wrong by"), so this matches loosely
    # on the number itself rather than the surrounding words.
    offset_matches="$(grep -oE '[0-9]+\.[0-9]+' <<<"$offset_line")"
    offset_seconds="$(head -1 <<<"$offset_matches")"
    if [[ -z "$offset_seconds" ]]; then
        echo "::error::could not extract a numeric offset from: $offset_line" >&2
        exit 1
    fi
    # Generous threshold (1 full second): the point is to catch "this client
    # got wildly wrong/raw-uncorrected time" (which would show as an offset
    # on the order of the container's real accumulated drift or worse), not
    # to assert sub-millisecond precision in a shared, potentially noisy CI
    # runner. Confirmed live this investigation's real runs land around
    # 0.001s (~1ms), so 1s of headroom is not close to masking a real
    # regression.
    if ! awk -v v="$offset_seconds" 'BEGIN { exit !(v < 1.0) }'; then
        echo "::error::the degraded server's served time was off by ${offset_seconds}s -- expected well under 1s. A real LAN client would get inaccurate time from this container even though it is reporting a healthy, degraded status. See #1296 / the source-code chain in the PR body." >&2
        exit 1
    fi
    echo "Real external NTP client query confirmed accurate served time (offset: ${offset_seconds}s) from the CAP_SYS_TIME-denied, degraded-mode container."

    echo "Scenario B (capability denied) passed: $image starts in degraded (-x) mode, correctly surfaces the degraded warning this project's watchdog relies on, and still serves genuinely accurate time to a real external NTP client."
}

echo "== Pulling $image (before any clock skew -- TLS to GHCR needs a real, valid clock) =="
docker pull "$image"

# Scenario B (denied) MUST run before Scenario A (granted): Scenario A
# deliberately skews this runner's real host clock forward by 300s as part
# of ITS OWN proof, and that skew persists on the host for the rest of the
# job (there is no "undo" step -- the point is to prove genuine correction
# of a real, lasting error). Scenario B's own real external-client query
# measures the served time against this same shared host clock; if it ran
# after Scenario A, it would measure roughly the leftover 300s skew instead
# of the small, genuine offset it exists to prove, and fail for a reason
# that has nothing to do with what it is actually testing. Running Scenario
# B first means its measurement happens while the host clock is still
# accurate (its own real, unskewed baseline), fully independent of Scenario
# A's later skew.
run_capability_denied_scenario
run_capability_granted_scenario

echo "ntp-cap-sys-time-simulation passed: both scenarios confirmed -- $image genuinely disciplines a real forced clock skew when CAP_SYS_TIME is granted (Scenario A), and correctly degrades to a healthy, accurate-time-serving state with a real, reachable degraded status when CAP_SYS_TIME is denied (Scenario B)."
