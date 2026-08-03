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
#   - reaps stale per-branch Trivy cache directories (`/var/tmp/lancache-ng-
#     trivy-cache/<service>-<arch>-<ref>`, build-push.yml's `container-scan`
#     job), by mtime, once a branch stops being scanned (merged, deleted, or
#     abandoned) -- confirmed 2026-07-31: 18-38 GB per host, unbounded, since
#     nothing else ever revisits a dead ref's directory to reclaim it.
#
# buildx_buildkit_*_state volumes are pruned the same as any other volume: every
# CI job that creates a buildx builder tears it down (`docker buildx rm`)
# immediately after its last use, so any that survive are either in use by an
# in-flight job (protected by the "no container references this volume" check
# below) or leaked by a job whose teardown never ran -- exactly what to reclaim.
# The reap above now also removes the leaked *container* itself (not just its
# volume), since a leaked buildx builder container otherwise keeps its own
# state volume permanently referenced and un-prunable.
#
# Trivy cache dirs (`/var/tmp/lancache-ng-trivy-cache/<service>-<arch>-<ref>`,
# build-push.yml's `container-scan` job) are pruned by mtime, host-side, for a
# reason the workflow's own per-push "Enforce Trivy cache generation retention"
# step (14-day generation-reset) cannot cover: that step only resets a ref's
# cache dir on that ref's OWN next scan, so a branch that stops being pushed
# (merged, deleted, an abandoned scratch/feature branch) leaves its directory
# on disk forever -- nothing ever scans that ref again to trigger the reset.
# Confirmed live, 2026-07-31: 18-38 GB per host, including dirs for branches
# already gone from `git ls-remote` days earlier. A directory's own mtime IS a
# valid staleness signal here (unlike the workflow step's own deliberate
# choice not to use mtime for a different reason -- it wants "time since last
# forced reset" for an *actively reused* dir, not "time since last touched")
# since an abandoned branch's dir mtime genuinely stops advancing once no scan
# ever writes into it again, while an active branch's keeps refreshing on
# every push. Trivy's local cache is a pure re-downloadable cache of the
# public vulnerability DB (the workflow's own comment already establishes
# this), so removing a whole stale dir is always safe -- worst case, the next
# scan of that ref (if it ever happens) pays one cold-cache DB re-download.
#
# Default threshold is 1 day (REAP_TRIVY_CACHE_AFTER_DAYS), deliberately more
# aggressive than the workflow's own 14-day TRIVY_CACHE_MAX_AGE_DAYS
# generation-reset -- a maintainer decision (2026-07-31) prioritizing bounded
# disk usage over cache-hit rate. Real tradeoff, accepted knowingly: CI jobs
# route round-robin across runner hosts, not deterministically per branch, so
# even an actively-developed branch (master/current_dev) can go >24h without
# a job landing on any one specific host -- that host's next scan of that
# branch then pays one cold-cache DB re-download instead of reusing a warm
# cache. Confirmed live, 2026-07-31: at the 14-day threshold nothing had
# actually gone stale yet (this project's branches turn over faster than
# that), so a 14-day default reclaimed nothing for a long time in practice;
# 1 day trades some redundant re-downloads for actually bounding growth.
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

# Removes Trivy cache directories (one per service+arch+ref, see build-push.yml's
# `container-scan` job) whose own mtime is older than the given day threshold --
# these belong to a branch that has stopped being scanned (merged, deleted, or an
# abandoned scratch branch) and would otherwise never be reclaimed, since the
# workflow's own generation-reset logic only fires on that ref's next scan.
# $1 = cache root directory, $2 = age threshold days.
#
# Uses `-mmin`, not `-mtime`: GNU find's `-mtime +n` truncates elapsed time to
# whole 24h periods *before* comparing, so `-mtime +1` actually requires more
# than 2 days elapsed (~48h), not 1 -- a well-known find gotcha. Confirmed
# live, 2026-07-31: with REAP_TRIVY_CACHE_AFTER_DAYS=1, `-mtime +1` silently
# skipped a host whose oldest directories were a real 26-27h old (true age
# under the intended 24h threshold, but under `-mtime`'s effective ~48h one).
# `-mmin +$((threshold_days * 1440))` compares on whole minutes instead, so
# the configured day threshold means what it says.
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
