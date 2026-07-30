#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# CI runner host maintenance: scheduled docker cleanup for self-hosted runner
# hosts. Keeps every runner host from accumulating build cache, unused images,
# orphaned anonymous volumes, and -- new in this versioned copy -- stopped
# containers and *long-orphaned running containers of known leak-prone kinds*
# indefinitely.
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
#   - adds a conservative reap of *running* containers of specific known
#     leak-prone kinds, each past its own age threshold (table below). A
#     container from one of these kinds alive past its threshold is an
#     orphaned/hung/crashed CI job whose own teardown step never ran --
#     normal runs of any of these complete in minutes, not hours:
#       * build-tools-image containers (2026-07-25 actionlint-deadlock leak
#         class that exhausted the light runner tier -- the actionlint SIGKILL
#         guard, AG-CI-016, fixes that leak at the source; this reap is
#         defense-in-depth for any future signal-deaf hang from another tool)
#       * lancache-ng-validation-* containers (full-setup-deep-validate
#         compose stacks left running after their owning job was cancelled or
#         crashed before its own `docker compose down` teardown step)
#       * buildx_buildkit_builder-* containers (buildx docker-container
#         builders left running after their owning job was cancelled or
#         crashed before its own `docker buildx rm`/"Remove buildx builder"
#         step -- that step already runs with `if: always()`, but a hard
#         cancel or a dead runner process can skip it entirely; confirmed
#         2026-07-30: 19 orphaned containers, mostly this kind and the
#         validation kind above, had accumulated on one host over 6 days,
#         going undetected because neither kind was covered by this reap)
#   - measures disk usage BEFORE and AFTER and logs the delta (AG-CI-016:
#     measure -> clean -> re-measure, so a run that reclaimed nothing is visible
#     rather than assumed successful).
#
# buildx_buildkit_*_state volumes are pruned the same as any other volume: every
# CI job that creates a buildx builder tears it down (`docker buildx rm`)
# immediately after its last use, so any that survive are either in use by an
# in-flight job (protected by the "no container references this volume" check
# below) or leaked by a job whose teardown never ran -- exactly what to reclaim.
# The reap above now also removes the leaked *container* itself (not just its
# volume), since a leaked buildx builder container otherwise keeps its own
# state volume permanently referenced and un-prunable.
set -euo pipefail

LOG_FILE="${LANCACHE_CI_CLEANUP_LOG:-/var/log/lancache-ci-cleanup.log}"
MAX_LOG_BYTES=$((5 * 1024 * 1024))
REAP_BUILD_TOOLS_AFTER_HOURS="${REAP_BUILD_TOOLS_AFTER_HOURS:-2}"
BUILD_TOOLS_IMAGE_MATCH="${BUILD_TOOLS_IMAGE_MATCH:-build-tools}"
REAP_VALIDATION_AFTER_HOURS="${REAP_VALIDATION_AFTER_HOURS:-2}"
VALIDATION_NAME_MATCH="${VALIDATION_NAME_MATCH:-lancache-ng-validation-}"
REAP_BUILDX_BUILDER_AFTER_HOURS="${REAP_BUILDX_BUILDER_AFTER_HOURS:-3}"
BUILDX_BUILDER_NAME_MATCH="${BUILDX_BUILDER_NAME_MATCH:-buildx_buildkit_builder-}"

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
    tail -c "$MAX_LOG_BYTES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Reaps running containers of one known leak-prone kind, past its own age
# threshold. $1 = human label (for log lines), $2 = match field ("image" or
# "name"), $3 = substring pattern for that field, $4 = age threshold hours.
# Conservative by construction: only containers matching the given kind, only
# past its own threshold -- never a blanket sweep of everything running.
reap_orphaned_running_containers() {
    local label="$1" match_field="$2" pattern="$3" threshold_hours="$4"
    local reap_before_epoch
    reap_before_epoch=$(( $(date +%s) - threshold_hours * 3600 ))
    echo "--- reap orphaned ${label} containers older than ${threshold_hours}h ---"
    for cid in $(docker ps -q); do
        local field_value
        case "$match_field" in
            image) field_value="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || echo '')" ;;
            name) field_value="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || echo '')" ;;
            *) continue ;;
        esac
        case "$field_value" in
            *"$pattern"*) ;;
            *) continue ;;
        esac
        local started started_epoch
        started="$(docker inspect --format '{{.State.StartedAt}}' "$cid" 2>/dev/null || echo '')"
        [ -n "$started" ] || continue
        started_epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
        if [ "$started_epoch" -gt 0 ] && [ "$started_epoch" -lt "$reap_before_epoch" ]; then
            echo "reaping hung ${label} container $cid (${match_field}=${field_value}, started $started)"
            docker rm -f "$cid" >/dev/null 2>&1 || true
        fi
    done
}

{
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) lancache-ci-cleanup start ==="

    before_used="$(df -P / | awk 'NR==2 {print $3}')"
    echo "--- disk usage before cleanup ---"
    df -h /

    reap_orphaned_running_containers "build-tools" image "$BUILD_TOOLS_IMAGE_MATCH" "$REAP_BUILD_TOOLS_AFTER_HOURS"
    reap_orphaned_running_containers "validation" name "$VALIDATION_NAME_MATCH" "$REAP_VALIDATION_AFTER_HOURS"
    reap_orphaned_running_containers "buildx-builder" name "$BUILDX_BUILDER_NAME_MATCH" "$REAP_BUILDX_BUILDER_AFTER_HOURS"

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
