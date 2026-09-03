#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: mkdir-based mutex around a Trivy DB cache-dir write
# Why: two writers must never race on the shared BoltDB file
# From: Issue #1780 | Issue #1095

# What: runs cmd under the lock; call as if/&&/|| condition
# Why: keeps errexit off so the RETURN trap always fires
# From: Issue #1780 | Issue #1095
trivy_db_locked_run() {
    local cache_dir="$1" lock_timeout="$2" stale_after="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    local lock_dir="$cache_dir/.trivy-db-update.lock"
    local poll_interval=5 waited=0
    local lock_mtime age

    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [[ -d "$lock_dir" ]]; then
            lock_mtime="$(stat -c %Y "$lock_dir" 2>/dev/null || echo 0)"
            age=$(( $(date +%s) - lock_mtime ))
            if (( age > stale_after )); then
                echo "::warning::Reclaiming stale Trivy DB refresh lock '$lock_dir' (age ${age}s > ${stale_after}s) -- previous holder almost certainly crashed or was cancelled mid-download." >&2
                rm -rf -- "$lock_dir"
                continue
            fi
        fi
        if (( waited >= lock_timeout )); then
            echo "::warning::Timed out after ${lock_timeout}s waiting for the Trivy DB refresh lock held by another concurrent caller." >&2
            return 2
        fi
        sleep "$poll_interval"
        waited=$(( waited + poll_interval ))
    done

    # What: releases lock on any return path from this call
    # Why: an unreleased lock wedges every later caller
    # From: Issue #1780 | Issue #1095
    # shellcheck disable=SC2064
    trap "rm -rf -- '$lock_dir'" RETURN

    echo "::notice::Holding Trivy DB refresh lock on '$lock_dir'." >&2
    "$@"
}
