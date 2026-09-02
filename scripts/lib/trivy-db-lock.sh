#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: mkdir-based mutex around a Trivy DB cache-dir write
# Why: two writers must never race on the shared BoltDB file
# From: Issue #1780 | Issue #1095
#
# Extracted out of trivy-db-ensure-fresh/action.yml's own inline lock loop
# so trivy-db-scheduled-refresh.yml's cold-cache download can acquire the
# identical lock instead of a second, divergent implementation (AG-CODE-011)
# -- both a bootstrap caller (trivy-db-ensure-fresh, reached on a cold or
# stale cache) and the scheduled writer's own first-ever run can otherwise
# both observe an empty cache-dir and race to write it at the same time.
#
# mkdir, not flock: this repo's shared cache-dir is commonly a soft-mounted
# NFS path, which does not reliably support flock's byte-range locking; an
# atomic mkdir against the same directory does not depend on that guarantee.
#
# Pure functions, no top-level executable code, sourced directly by
# `run:` steps -- same convention as ghcr-retry.sh/promote-lock.sh in this
# same directory.

# trivy_db_locked_run <cache_dir> <lock_timeout_seconds> <stale_after_seconds> -- <command...>
# Runs <command...> with the lock held. MUST be called as an `if`/`&&`/`||`
# condition (never as a bare statement) by a caller running under
# `set -e`: bash suppresses errexit for the entire duration of a function
# invoked as such a condition, which is what lets this function's own
# internal `"$@"` failure reach its `trap ... RETURN` cleanup below instead
# of the whole calling script being torn down mid-function by errexit
# before that trap can fire, leaking the lock directory forever.
# Return codes:
#   0        = lock acquired, wrapped command exited 0
#   2        = could not acquire the lock before <lock_timeout_seconds>
#   anything else = lock acquired, wrapped command's own real exit code
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
