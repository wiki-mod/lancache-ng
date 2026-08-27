#!/bin/bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Force-removes buildx_buildkit_* containers older than 3h.
#
# Single source for the byte-identical cleanup step that was copy-pasted
# across all 7 self-hosted Buildx-setup sites in build-push.yml (issue
# #1095). A crashed job also skips its own removal step, leaving a
# buildx_buildkit_* container running indefinitely on that self-hosted
# runner (same reused-workspace failure class as this file's checkout-lock
# fix); 3h clears the file's longest self-hosted job timeout (150m) with
# real margin.

set -uo pipefail

now=$(date +%s)
ids=$(docker ps -a --filter "name=^/buildx_buildkit_" --format '{{.ID}}' 2>/dev/null || true)
for cid in $ids; do
    cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)
    case "$cname" in
        /buildx_buildkit_*) ;;
        *) continue ;;
    esac
    created=$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null || true)
    [ -n "$created" ] || continue
    created_epoch=$(date -d "$created" +%s 2>/dev/null || true)
    [ -n "$created_epoch" ] || continue
    age=$(( now - created_epoch ))
    if [ "$age" -gt 10800 ]; then
        echo "::warning::removing stale buildx builder $cname (age ${age}s)"
        docker rm -f "$cid" || true
    fi
done
