#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: reaps stale CI leftovers, prunes docker, logs disk
# Why: [AG-CI-016]; unpruned images and cache fill disks
set -euo pipefail

LOG_FILE="${LANCACHE_CI_CLEANUP_LOG:-/var/log/lancache-ci-cleanup.log}"
MAX_LOG_BYTES=$((5 * 1024 * 1024))
REAP_BUILD_TOOLS_AFTER_HOURS="${REAP_BUILD_TOOLS_AFTER_HOURS:-2}"
BUILD_TOOLS_IMAGE_MATCH="${BUILD_TOOLS_IMAGE_MATCH:-build-tools}"
REAP_VALIDATION_AFTER_HOURS="${REAP_VALIDATION_AFTER_HOURS:-2}"
VALIDATION_NAME_MATCH="${VALIDATION_NAME_MATCH:-lancache-ng-validation-}"
REAP_BUILDX_BUILDER_AFTER_HOURS="${REAP_BUILDX_BUILDER_AFTER_HOURS:-3}"
BUILDX_BUILDER_NAME_MATCH="${BUILDX_BUILDER_NAME_MATCH:-buildx_buildkit_builder-}"
TRIVY_CACHE_ROOT="${TRIVY_CACHE_ROOT:-/var/tmp/lancache-ng-trivy-cache}"
REAP_TRIVY_CACHE_AFTER_DAYS="${REAP_TRIVY_CACHE_AFTER_DAYS:-1}"

if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
    tail -c "$MAX_LOG_BYTES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# What: removes running containers of one kind past age
# Why: restart policy resets StartedAt; .Created does not
# From: Issue #1095 | PR #1426
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
        local created created_epoch
        created="$(docker inspect --format '{{.Created}}' "$cid" 2>/dev/null || echo '')"
        [ -n "$created" ] || continue
        created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
        if [ "$created_epoch" -gt 0 ] && [ "$created_epoch" -lt "$reap_before_epoch" ]; then
            echo "reaping hung ${label} container $cid (${match_field}=${field_value}, created $created)"
            docker rm -f "$cid" >/dev/null 2>&1 || true
        fi
    done
}

# What: rm empty validation networks older than N hours
# Why: an empty network can be mid-bringup, not orphaned
# From: PR #1426
reap_orphaned_validation_networks() {
    local name_match="$1" threshold_hours="$2"
    local reap_before_epoch
    reap_before_epoch=$(( $(date +%s) - threshold_hours * 3600 ))
    echo "--- reap orphaned validation networks older than ${threshold_hours}h (0 attached containers, matching ${name_match}) ---"
    for network_name in $(docker network ls --filter "name=${name_match}" --format '{{.Name}}' 2>/dev/null); do
        local attached
        attached="$(docker network inspect "$network_name" --format '{{len .Containers}}' 2>/dev/null || echo '')"
        [ "$attached" = "0" ] || continue
        local created created_epoch
        created="$(docker network inspect "$network_name" --format '{{.Created}}' 2>/dev/null || echo '')"
        [ -n "$created" ] || continue
        # What: drops zone word from .Created before date -d
        # Why: GNU date rejects the zone word
        created_epoch="$(date -d "${created% *}" +%s 2>/dev/null || echo 0)"
        if [ "$created_epoch" -gt 0 ] && [ "$created_epoch" -lt "$reap_before_epoch" ]; then
            echo "reaping orphaned validation network $network_name (0 attached containers, created $created)"
            docker network rm "$network_name" >/dev/null 2>&1 || true
        fi
    done
}

# What: rm top-level Trivy cache dirs older than N days
# Why: -mtime floors ages to whole days; -mmin is exact
# From: PR #1334
reap_stale_trivy_cache_dirs() {
    local root="$1" threshold_days="$2" threshold_minutes
    threshold_minutes=$(( threshold_days * 1440 ))
    echo "--- reap stale Trivy cache dirs under ${root} older than ${threshold_days}d (${threshold_minutes}min) ---"
    [ -d "$root" ] || { echo "(no ${root} on this host, skipping)"; return 0; }
    find "$root" -mindepth 1 -maxdepth 1 -type d -mmin "+${threshold_minutes}" -print0 |
        while IFS= read -r -d '' dir; do
            echo "reaping stale Trivy cache dir $dir"
            rm -rf -- "$dir"
        done
}

{
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) lancache-ci-cleanup start ==="

    before_used="$(df -P / | awk 'NR==2 {print $3}')"
    echo "--- disk usage before cleanup ---"
    df -h /

    reap_orphaned_running_containers "build-tools" image "$BUILD_TOOLS_IMAGE_MATCH" "$REAP_BUILD_TOOLS_AFTER_HOURS"
    reap_orphaned_running_containers "validation" name "$VALIDATION_NAME_MATCH" "$REAP_VALIDATION_AFTER_HOURS"
    reap_orphaned_validation_networks "$VALIDATION_NAME_MATCH" "$REAP_VALIDATION_AFTER_HOURS"
    reap_orphaned_running_containers "buildx-builder" name "$BUILDX_BUILDER_NAME_MATCH" "$REAP_BUILDX_BUILDER_AFTER_HOURS"
    reap_stale_trivy_cache_dirs "$TRIVY_CACHE_ROOT" "$REAP_TRIVY_CACHE_AFTER_DAYS"

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
