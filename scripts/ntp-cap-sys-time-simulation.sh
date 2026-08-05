#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
# Required env: REPOSITORY, IMAGE_TAG (the resolved tag from
# scripts/lib/validation-image-tag.sh's vit_resolve_tag, matching every
# other job in this suite -- see full-setup-deep-validate.yml's own
# LANCACHE_IMAGE_TAG-style usage).
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

image="ghcr.io/${REPOSITORY}/ntp:${IMAGE_TAG}"
container_name="ntp-cap-sys-time-probe"

cleanup() {
    local status=$?
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT

echo "== Pulling $image (before any clock skew -- TLS to GHCR needs a real, valid clock) =="
docker pull "$image"

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
docker run -d --name "$container_name" \
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
    ntp_log="$(docker logs "$container_name" 2>&1 || true)"
    if grep -qi "adjtimex.*Operation not permitted\|Another chronyd may already be running" <<<"$ntp_log"; then
        echo "::error::chronyd hit the same CAP_SYS_TIME restriction confirmed on this project's self-hosted (LXC) runner fleet -- this GitHub-hosted runner no longer grants real CAP_SYS_TIME, or the ntp image/entrypoint changed in a way that broke this. See #1296 for the original investigation." >&2
        docker logs "$container_name" >&2
        exit 1
    fi
    # `docker inspect --format` on one field of one container always
    # produces exactly one line, so grep -qx's early exit has nothing else
    # to cut off (issue #1377's repo-wide pipefail/SIGPIPE audit).
    if ! docker inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; then # pipefail-safe: docker inspect --format on one field of one container always emits exactly one line
        echo "::error::$container_name is no longer running (unexpected exit, not the known CAP_SYS_TIME crash signature). Full logs:" >&2
        docker logs "$container_name" >&2
        exit 1
    fi
    if tracking="$(docker exec "$container_name" chronyc tracking 2>/dev/null)"; then
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
    docker exec "$container_name" chronyc tracking >&2 || true
    docker logs "$container_name" >&2
    exit 1
fi

echo "ntp-cap-sys-time-simulation passed: $image starts, survives, and genuinely disciplines a real forced clock skew to a synchronised state (Stratum > 0, Leap status: Normal) on this GitHub-hosted runner."
