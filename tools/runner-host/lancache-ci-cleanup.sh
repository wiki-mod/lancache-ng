#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# CI runner host maintenance: scheduled docker cleanup for self-hosted runner
# hosts. Keeps every runner host from accumulating build cache, unused images,
# orphaned anonymous volumes, and -- new in this versioned copy -- stopped
# containers and *long-orphaned running build-tools containers* indefinitely.
#
# This is the repository-versioned source of truth for the cleanup that used to
# live only in host-local /usr/local/sbin (AG-CI-016: any cleanup CI depends on
# must live in the repo, PR-reviewable and consistent across all hosts). Deploy
# it identically to EVERY self-hosted runner host (see README.md in this dir) --
# a prior host-local copy ran only on a subset of hosts, which is why one host
# accumulated ~40 GB of unreclaimed images/build cache while others were fine.
#
# Coverage vs. the old host-local script:
#   - adds `docker container prune` (stopped containers were never reaped)
#   - adds a conservative reap of *running* build-tools-image containers older
#     than REAP_BUILD_TOOLS_AFTER_HOURS (default 2h). Normal build-tools runs
#     (shellcheck/actionlint lint, bats, shellspec) complete in minutes; a
#     build-tools container alive for hours is an orphaned/hung CI job (the exact
#     leak class of the 2026-07-25 actionlint deadlock that exhausted the light
#     runner tier). The actionlint SIGKILL guard (AG-CI-016) fixes that leak at
#     the source; this reap is a defense-in-depth net for any future signal-deaf
#     hang from another tool.
#   - measures disk usage BEFORE and AFTER and logs the delta (AG-CI-016:
#     measure -> clean -> re-measure, so a run that reclaimed nothing is visible
#     rather than assumed successful).
#
# buildx_buildkit_*_state volumes are pruned the same as any other volume: every
# CI job that creates a buildx builder tears it down (`docker buildx rm`)
# immediately after its last use, so any that survive are either in use by an
# in-flight job (protected by the "no container references this volume" check
# below) or leaked by a job whose teardown never ran -- exactly what to reclaim.
set -euo pipefail

LOG_FILE="${LANCACHE_CI_CLEANUP_LOG:-/var/log/lancache-ci-cleanup.log}"
MAX_LOG_BYTES=$((5 * 1024 * 1024))
REAP_BUILD_TOOLS_AFTER_HOURS="${REAP_BUILD_TOOLS_AFTER_HOURS:-2}"
BUILD_TOOLS_IMAGE_MATCH="${BUILD_TOOLS_IMAGE_MATCH:-build-tools}"

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
    tail -c "$MAX_LOG_BYTES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

{
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) lancache-ci-cleanup start ==="

    before_used="$(df -P / | awk 'NR==2 {print $3}')"
    echo "--- disk usage before cleanup ---"
    df -h /

    # Reap long-orphaned running build-tools containers (hung/leaked CI jobs).
    # Conservative: only the build-tools image, only past the age threshold.
    echo "--- reap orphaned build-tools containers older than ${REAP_BUILD_TOOLS_AFTER_HOURS}h ---"
    reap_before_epoch=$(( $(date +%s) - REAP_BUILD_TOOLS_AFTER_HOURS * 3600 ))
    for cid in $(docker ps -q); do
        image="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || echo '')"
        case "$image" in
            *"$BUILD_TOOLS_IMAGE_MATCH"*) ;;
            *) continue ;;
        esac
        started="$(docker inspect --format '{{.State.StartedAt}}' "$cid" 2>/dev/null || echo '')"
        [ -n "$started" ] || continue
        started_epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
        if [ "$started_epoch" -gt 0 ] && [ "$started_epoch" -lt "$reap_before_epoch" ]; then
            echo "reaping hung build-tools container $cid (image $image, started $started)"
            docker rm -f "$cid" >/dev/null 2>&1 || true
        fi
    done

    echo "--- docker container prune (stopped containers) ---"
    docker container prune -f

    echo "--- docker builder prune ---"
    docker builder prune -af

    echo "--- docker image prune ---"
    docker image prune -af

    echo "--- docker volume prune (unreferenced only) ---"
    for v in $(docker volume ls -q); do
        if [ -z "$(docker ps -a --filter "volume=$v" -q)" ]; then
            docker volume rm "$v" >/dev/null 2>&1 || true
        fi
    done

    after_used="$(df -P / | awk 'NR==2 {print $3}')"
    echo "--- disk usage after cleanup ---"
    df -h /
    reclaimed_kb=$(( before_used - after_used ))
    echo "reclaimed: ${reclaimed_kb} KiB ($(( reclaimed_kb / 1024 )) MiB) on /"

    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) lancache-ci-cleanup done ==="
} >> "$LOG_FILE" 2>&1
