#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end Watchtower verification (issue #611, sub-item of #398).
# Watchtower is a documented, supported optional feature (COMPOSE_PROFILES=
# watchtower; README.md, docs/release-external-images.md,
# docs/backup-restore.md) whose actual runtime behavior -- detect a new
# image, pull it, restart just the affected container, come back healthy --
# had never been exercised against this project's real compose stack. This
# script drives that flow for real against deploy/full-setup/docker-compose.yml
# (reusing the same project/health-wait pattern already proven in
# ssl-mitm-cache-simulation.sh and ui-nats-dns-integration-simulation.sh).
#
# Watchtower's real update mechanism needs the digest of an image reference a
# running container already uses to genuinely change. This project's mutable
# channels (edge/dev/latest) can't safely be flipped mid-CI -- other jobs and
# real operators rely on those tags staying put. Instead this script runs a
# throwaway local registry on 127.0.0.1 (Docker treats 127.0.0.0/8 registries
# as insecure/plain-HTTP automatically, confirmed directly: push and pull
# both succeeded against a fresh registry:2 container with zero daemon.json
# changes on this exact runner tier) and points only the proxy service at it,
# never touching a real GHCR channel tag.
#
# The mirror is seeded with the real, currently-published proxy:$LANCACHE_IMAGE_TAG
# image, then a "generation 2" image is built FROM that same real image with
# one added LABEL. A real historical commit's proxy image would also produce
# a genuine digest change, but would tie this test's reliability to GHCR's
# retention of old sha-* tags and could vary in unrelated ways (entrypoint or
# healthcheck changes between versions) that have nothing to do with
# Watchtower's own update mechanism. Deriving generation 2 directly from
# generation 1 holds everything constant except the digest -- exactly the one
# thing Watchtower keys its update decision on -- while guaranteeing the
# recreated container still runs the real, currently-tested proxy entrypoint
# and healthcheck. The two image IDs are compared and asserted different
# below, not assumed.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
compose_file="deploy/full-setup/docker-compose.yml"
compose=(docker compose -p "$compose_project" -f "$compose_file")

upstream_registry="${LANCACHE_IMAGE_REGISTRY:-ghcr.io}"
upstream_prefix="${LANCACHE_IMAGE_PREFIX:-wiki-mod/lancache-ng}"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"

mirror_port="${WATCHTOWER_SIM_REGISTRY_PORT:-5511}"
mirror_registry="127.0.0.1:${mirror_port}"
mirror_prefix="watchtower-sim"
mirror_tag="watchtower-test"
mirror_ref="${mirror_registry}/${mirror_prefix}/proxy:${mirror_tag}"
# Known tracked gap: the registry container name, host port, and compose
# project name are fixed constants shared with the sibling validation
# scripts, so two runs on the same host collide instead of isolating per run
# via a per-run VALIDATION_SUBNET. This is deliberately not fixed here to keep
# this review pass scoped; the systemic fix across all three scripts is
# tracked in issue #661.
registry_container="lancache-ng-watchtower-sim-registry"

work_dir="$repo_root/.watchtower-update-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

cleanup() {
    local status=$?
    "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f "$registry_container" >/dev/null 2>&1 || true
    docker rmi "$mirror_ref" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Starting a throwaway local registry mirror on 127.0.0.1:${mirror_port} =="
docker rm -f "$registry_container" >/dev/null 2>&1 || true
docker run -d --name "$registry_container" -p "127.0.0.1:${mirror_port}:5000" registry:2 >/dev/null

echo "== Seeding the mirror with the real, currently published proxy:$image_tag image (generation 1) =="
docker pull "${upstream_registry}/${upstream_prefix}/proxy:${image_tag}"
docker tag "${upstream_registry}/${upstream_prefix}/proxy:${image_tag}" "$mirror_ref"
# `docker run -d` above returns when the registry container is created, not
# when the registry process inside it is accepting connections. The upstream
# pull+tag usually masks that startup gap, but a warm image cache can make the
# pull return almost instantly and race the very first push against a registry
# that is not listening yet. Retry the first push (the push is both the
# readiness probe and the operation that races) until it succeeds, giving the
# registry a bounded window to come up instead of relying on incidental
# timing. A docker-only wait avoids adding a host `curl`/`wget` dependency that
# this script family never assumes (its other HTTP probes all run inside
# containers).
push_deadline=$((SECONDS + 30))
until docker push "$mirror_ref" >/dev/null 2>&1; do
    if (( SECONDS >= push_deadline )); then
        echo "::error::first push to ${mirror_registry} did not succeed within 30s -- the local registry never became ready." >&2
        docker logs "$registry_container" 2>&1 | tail -n 20 >&2 || true
        exit 1
    fi
    sleep 1
done
v1_image_id="$(docker image inspect --format '{{.Id}}' "$mirror_ref")"
echo "Mirror seeded at generation 1: $v1_image_id"

echo "== Starting proxy + netdata from the mirror-pointed compose stack =="
# proxy is the only full-setup service whose image reference is parameterized
# by LANCACHE_IMAGE_REGISTRY/PREFIX/TAG, so pointing those at the local
# mirror only affects proxy. netdata (third-party, digest-pinned, its own
# healthcheck, no dependency on nats) is left on its real image untouched and
# serves as the "Watchtower must not restart unrelated containers" control.
LANCACHE_IMAGE_REGISTRY="$mirror_registry" \
LANCACHE_IMAGE_PREFIX="$mirror_prefix" \
LANCACHE_IMAGE_TAG="$mirror_tag" \
    "${compose[@]}" up -d proxy netdata

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy netdata; do
        cid="$("${compose[@]}" ps -q "$service")"
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
        [[ "$status" = healthy ]] || all_ready=0
    done
    [[ "$all_ready" -eq 1 ]] && break
    sleep 5
done
for service in proxy netdata; do
    cid="$("${compose[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
    if [[ "$status" != healthy ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy and netdata are healthy."

proxy_cid_before="$("${compose[@]}" ps -q proxy)"
proxy_name="$(docker inspect --format '{{.Name}}' "$proxy_cid_before" | sed 's#^/##')"
netdata_cid_before="$("${compose[@]}" ps -q netdata)"
netdata_name="$(docker inspect --format '{{.Name}}' "$netdata_cid_before" | sed 's#^/##')"

# Recreating the proxy container must reattach the same persistent proxy-cache
# named volume, never spin up a fresh (empty) one. That volume holds every
# cached byte an operator has accumulated, and docs/backup-restore.md treats
# its survival as the reason Watchtower is safe to enable -- so a recreate that
# silently swapped, dropped, or re-created it would destroy real cache with no
# error surfaced. Capture the volume's identity (name + host source) and its
# creation timestamp before the update to compare afterwards. CreatedAt is
# captured too because it catches a same-name delete+recreate that a name-only
# check would miss (a fresh volume of the same name would be empty).
proxy_cache_dest="/var/cache/nginx/lancache"
cache_mount_before="$(docker inspect \
    --format "{{range .Mounts}}{{if eq .Destination \"$proxy_cache_dest\"}}{{.Name}}|{{.Source}}{{end}}{{end}}" \
    "$proxy_cid_before")"
cache_volume_name="${cache_mount_before%%|*}"
if [[ -z "$cache_volume_name" ]]; then
    echo "::error::proxy container has no named volume mounted at $proxy_cache_dest before the update -- cannot verify the cache survives the recreate." >&2
    exit 1
fi
cache_created_before="$(docker volume inspect --format '{{.CreatedAt}}' "$cache_volume_name")"

echo "== Building a minimally-derived generation-2 image to force a genuine digest change =="
printf 'FROM %s\nLABEL lancache.watchtower-simulation-generation=2\n' "$mirror_ref" \
    | docker build -t "$mirror_ref" - >/dev/null
docker push "$mirror_ref" >/dev/null
v2_image_id="$(docker image inspect --format '{{.Id}}' "$mirror_ref")"
if [[ "$v1_image_id" == "$v2_image_id" ]]; then
    echo "::error::generation-2 image ID is identical to generation 1 ($v1_image_id) -- the derived image did not actually change, so this test cannot prove anything." >&2
    exit 1
fi
echo "Mirror now serves generation 2 ($v2_image_id), confirmed different from generation 1 ($v1_image_id)."

echo "== Running Watchtower once, scoped by the real full-setup compose enable label =="
# --label-enable plus explicit container names is a real AND, not an
# either/or -- confirmed directly: naming a container that lacks the
# com.centurylinklabs.watchtower.enable label still yields a
# "scanned=0 updated=0" no-op, it is never touched. This means the enable
# label on proxy/netdata in docker-compose.yml is load-bearing for this test:
# remove or misspell it there and Watchtower silently skips the container,
# which the assertions below will catch.
#
# No WATCHTOWER_SCHEDULE override is needed alongside --run-once -- confirmed
# directly that the schedule env (as set on the real watchtower service
# above) has no effect on a --run-once invocation; it just runs once and
# exits.
#
# --network host is not needed either: Watchtower's own registry manifest
# check always assumes HTTPS and fails against our plain-HTTP mirror
# regardless of network reachability (confirmed directly, with both a
# "connection refused" and, once reachable, a "server gave HTTP response to
# HTTPS client" error) -- but Watchtower falls back to a real `docker pull`
# through the Docker daemon (which does respect the 127.0.0.0/8 insecure
# default, and always has host network access regardless of Watchtower's own
# container network mode) and compares the resulting local image ID before
# and after. Confirmed this fallback path alone is sufficient end-to-end,
# without --network host, before relying on it here. This does mean this
# script exercises Watchtower's update mechanism via its fallback-pull path
# rather than the cheap manifest-HEAD path production traffic against real
# HTTPS registries like ghcr.io would normally take -- that HEAD-based path
# is Watchtower's own upstream code, out of scope for this project's
# integration; the recreate/health/restart-count behavior verified below is
# identical either way.
"${compose[@]}" --profile watchtower run --rm watchtower \
    --run-once --label-enable "$proxy_name" "$netdata_name"

echo "== Waiting for the recreated proxy container to become healthy =="
deadline=$((SECONDS + 90))
proxy_cid_after=""
while (( SECONDS < deadline )); do
    proxy_cid_after="$("${compose[@]}" ps -q proxy)"
    if [[ -n "$proxy_cid_after" ]]; then
        status="$(docker inspect --format '{{.State.Health.Status}}' "$proxy_cid_after" 2>/dev/null || echo unknown)"
        [[ "$status" = healthy ]] && break
    fi
    sleep 5
done
status="$(docker inspect --format '{{.State.Health.Status}}' "${proxy_cid_after:-}" 2>/dev/null || echo unknown)"
if [[ -z "$proxy_cid_after" || "$status" != healthy ]]; then
    echo "::error::proxy did not become healthy after the Watchtower update (status: ${status:-missing})" >&2
    "${compose[@]}" logs --no-color proxy || true
    exit 1
fi

failed=0

if [[ "$proxy_cid_after" == "$proxy_cid_before" ]]; then
    echo "::error::proxy's container ID did not change ($proxy_cid_before) -- Watchtower did not recreate it." >&2
    failed=1
else
    echo "proxy was recreated: $proxy_cid_before -> $proxy_cid_after (stop+recreate, not an in-place restart)."
fi

proxy_image_after="$(docker inspect --format '{{.Image}}' "$proxy_cid_after")"
if [[ "$proxy_image_after" != "$v2_image_id" ]]; then
    echo "::error::recreated proxy container is running image $proxy_image_after, expected generation-2 image $v2_image_id." >&2
    failed=1
else
    echo "Recreated proxy container is genuinely running the new (generation 2) image."
fi

proxy_restarts_after="$(docker inspect --format '{{.RestartCount}}' "$proxy_cid_after")"
if (( proxy_restarts_after > 1 )); then
    echo "::error::recreated proxy container's RestartCount is $proxy_restarts_after -- this would misfire full-setup-validate.yml's crash-loop heuristic." >&2
    failed=1
else
    echo "Recreated proxy container's RestartCount is $proxy_restarts_after -- a fresh container, not a crash loop. full-setup-validate.yml's 'RestartCount > 1' heuristic would not misfire on a legitimate Watchtower update."
fi

cache_mount_after="$(docker inspect \
    --format "{{range .Mounts}}{{if eq .Destination \"$proxy_cache_dest\"}}{{.Name}}|{{.Source}}{{end}}{{end}}" \
    "$proxy_cid_after")"
cache_volume_name_after="${cache_mount_after%%|*}"
cache_created_after=""
if [[ -n "$cache_volume_name_after" ]]; then
    cache_created_after="$(docker volume inspect --format '{{.CreatedAt}}' "$cache_volume_name_after" 2>/dev/null || echo "")"
fi
if [[ "$cache_mount_after" != "$cache_mount_before" || "$cache_created_after" != "$cache_created_before" ]]; then
    echo "::error::proxy's persistent cache volume did not survive the recreate intact (before: $cache_mount_before @ $cache_created_before, after: ${cache_mount_after:-missing} @ ${cache_created_after:-missing}) -- a Watchtower update that swaps, drops, or re-creates the cache volume would silently wipe an operator's accumulated cache." >&2
    failed=1
else
    echo "proxy's persistent cache volume survived the recreate intact ($cache_volume_name, created $cache_created_before) -- Watchtower reattached the same named volume, so operators' cached data is preserved across the update."
fi

netdata_cid_after="$("${compose[@]}" ps -q netdata)"
if [[ "$netdata_cid_after" != "$netdata_cid_before" ]]; then
    echo "::error::netdata's container ID changed ($netdata_cid_before -> $netdata_cid_after) -- Watchtower restarted a container whose image never changed." >&2
    failed=1
else
    echo "netdata was correctly left untouched: Watchtower only restarts the container whose image actually changed, not every labeled container."
fi

if [[ "$failed" -eq 1 ]]; then
    exit 1
fi

echo "watchtower-update-simulation passed: Watchtower detected a genuine digest change via the real full-setup compose enable label, recreated only the proxy container with its persistent cache volume reattached intact, it came back healthy with RestartCount $proxy_restarts_after (the crash-loop heuristic tolerates up to 1), and the unrelated netdata container was left untouched."
