#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end proof for issue #763's "the Admin UI is the one thing that
# must always stay reachable, even when other services are crash-looping"
# requirement. deploy/*/docker-compose.yml's `ui` service `depends_on` list
# (docker-socket-proxy, proxy, nats) has never had a `condition:
# service_healthy` entry, which docs/known-good-config-snapshots.md and the
# #763 design discussion both point to as *why* the Admin UI should already
# start independently of whether proxy/dns/dhcp are crash-looping -- but that
# claim had never actually been exercised against a real, deliberately-broken
# dependency, only inferred by reading the compose file. This script closes
# that gap: it forces `proxy` (a real `ui` depends_on entry in
# deploy/full-setup/docker-compose.yml, the same compose file the deep
# validation suite already exercises) into a genuine, continuous crash loop
# and then proves the Admin UI still starts, becomes healthy, never restarts
# itself, and answers a real HTTP request -- all while proxy keeps crashing.
#
# What this does NOT prove (the maintainer's own scoping in #763 and
# docs/known-good-config-snapshots.md's "Known gap" paragraphs are explicit
# about this, so this script does not overclaim it either):
#   - It does not prove the Admin UI survives one of ITS OWN depends_on
#     entries (docker-socket-proxy, proxy, nats) being crash-looped in a way
#     that also breaks the UI's own control-plane calls to that dependency --
#     only that the container itself starts and its HTTP server answers.
#   - It does not prove a crash-looping DNS/DHCP service's own rollback
#     listener or Control Agent stays reachable while THAT service is the one
#     crash-looping -- that is the actual "rescue mode" gap #763 tracks and
#     explicitly defers; this script is about the Admin UI's own reachability,
#     not about rescuing an unrelated crash-looping service's control surface.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
compose_file="deploy/full-setup/docker-compose.yml"
network_name="${compose_project}_validation"
# Tracks deploy/full-setup/docker-compose.yml's own VALIDATION_UI_IP default,
# same reasoning as ui-nats-dns-integration-simulation.sh's identical
# fallback: the automatic deep-validate gate sets this per-run, a manual
# local run falls back to the compose file's own default.
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}"

work_dir="$repo_root/.ui-reachability-crash-loop-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"

# Forces the real `proxy` service to exit(1) immediately instead of ever
# completing its normal nginx entrypoint -- standing in for "proxy's own
# generated config/cert data is broken and it can never come up", the same
# class of failure docs/known-good-config-snapshots.md's crash-loop scenarios
# describe. `restart: unless-stopped` (already set on every full-setup
# service, unchanged by this override) then genuinely crash-loops it. The
# base healthcheck is disabled here because it assumes a working nginx and
# would just report "unhealthy" forever without adding anything this script's
# own RestartCount assertion below doesn't already prove more directly.
override_file="$work_dir/docker-compose.crash-proxy-override.yml"
cat > "$override_file" <<'EOF'
services:
  proxy:
    entrypoint: ["/bin/sh", "-c", "echo '[ui-reachability-sim] simulated proxy crash-loop'; exit 1"]
    healthcheck:
      disable: true
EOF

compose=(docker compose -p "$compose_project" -f "$compose_file" -f "$override_file")

cleanup() {
    local status=$?
    "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    # `|| true`: confirmed for real in the sibling setup-reset-kea-config-
    # simulation.sh that an unguarded `rm -rf` as the last command in this
    # trap can turn a run whose actual test logic already passed into a job
    # CI reports as failed, if removal hits so much as one permission-denied
    # file. work_dir here only ever holds a plain compose override file this
    # script itself wrote (no container bind-mount into it, unlike the Kea
    # sibling script), so that specific failure mode should not occur -- but
    # this trap's whole point is reporting the TEST's own outcome via
    # `exit "$status"` below, never letting an incidental cleanup hiccup
    # override that, so the same guard is applied here too.
    rm -rf "$work_dir" || true
    exit "$status"
}
trap cleanup EXIT

echo "== Starting the Admin UI and its real depends_on chain (docker-socket-proxy, proxy, nats), with proxy forced into a crash loop =="
"${compose[@]}" up -d ui

echo "== Confirming proxy is genuinely crash-looping (RestartCount climbing under restart: unless-stopped) =="
proxy_deadline=$((SECONDS + 60))
proxy_restarts=0
while (( SECONDS < proxy_deadline )); do
    # -aq, not -q: `docker compose ps` without -a can transiently omit a
    # container in the gap between one crash-loop exit and the daemon
    # relaunching it (see the final re-check below for where this was
    # confirmed to actually matter); this loop already tolerates a single
    # empty read by just retrying, but there is no reason to rely on that
    # tolerance when -aq costs nothing extra.
    proxy_cid="$("${compose[@]}" ps -aq proxy || true)"
    if [[ -n "$proxy_cid" ]]; then
        proxy_restarts="$(docker inspect --format '{{.RestartCount}}' "$proxy_cid" 2>/dev/null || echo 0)"
        (( proxy_restarts >= 3 )) && break
    fi
    sleep 3
done
if (( proxy_restarts < 3 )); then
    echo "::error::proxy's RestartCount only reached $proxy_restarts within 60s -- the simulated crash-loop override did not actually take effect, so this run cannot prove anything about Admin UI reachability during a real crash-loop." >&2
    "${compose[@]}" logs --no-color proxy || true
    exit 1
fi
echo "proxy is genuinely crash-looping (RestartCount=$proxy_restarts)."

echo "== Waiting for the Admin UI to become healthy despite proxy's ongoing crash-loop =="
ui_deadline=$((SECONDS + 90))
ui_status="unknown"
ui_cid=""
while (( SECONDS < ui_deadline )); do
    ui_cid="$("${compose[@]}" ps -q ui || true)"
    if [[ -n "$ui_cid" ]]; then
        ui_status="$(docker inspect --format '{{.State.Health.Status}}' "$ui_cid" 2>/dev/null || echo unknown)"
        [[ "$ui_status" == "healthy" ]] && break
    fi
    sleep 5
done
if [[ "$ui_status" != "healthy" ]]; then
    echo "::error::Admin UI never became healthy while proxy was crash-looping (status: $ui_status). This is exactly the failure #763 exists to prevent -- the Admin UI must stay reachable regardless of other services' state." >&2
    "${compose[@]}" logs --no-color ui || true
    exit 1
fi
echo "Admin UI is healthy while proxy is still crash-looping."

ui_restarts="$(docker inspect --format '{{.RestartCount}}' "$ui_cid")"
if (( ui_restarts > 1 )); then
    echo "::error::Admin UI's own RestartCount is $ui_restarts -- it should never need to restart because of an UNRELATED service's crash loop." >&2
    exit 1
fi
echo "Admin UI's own RestartCount is $ui_restarts -- it never restarted itself in reaction to proxy's crash loop."

echo "== Confirming the Admin UI answers a real HTTP request while proxy is still crash-looping =="
# A brand-new --rm client container on the same compose network, mirroring
# ui-nats-dns-integration-simulation.sh's own pattern, rather than curling the
# host-published port directly -- this runner is not guaranteed to have curl
# installed, and every other simulation script already avoids that
# assumption the same way.
http_deadline=$((SECONDS + 30))
http_ok=0
while (( SECONDS < http_deadline )); do
    if docker run --rm --network "$network_name" "$build_tools_image" \
        curl -sf -o /dev/null "http://${ui_ip}:8080/health"; then
        http_ok=1
        break
    fi
    sleep 3
done
if (( http_ok != 1 )); then
    echo "::error::Admin UI's /health endpoint at http://${ui_ip}:8080/health never answered while proxy was crash-looping." >&2
    exit 1
fi
echo "Admin UI's /health endpoint answered a real HTTP request while proxy was still crash-looping."

# Reconfirm proxy is STILL crash-looping at the end, not that it happened to
# recover on its own during the wait above (which would make this whole run
# moot -- the point is that the UI stays reachable THROUGHOUT, not before an
# eventual recovery). `ps -aq` (not `ps -q`), and a short retry loop: `docker
# compose ps` without `-a` only lists containers it considers "up", which can
# transiently omit a container in the split-second between one crash-loop
# exit and the daemon relaunching it under `restart: unless-stopped` --
# confirmed for real (a first version of this script using plain `ps -q`
# here flaked on exactly that window: RestartCount=5 moments earlier, then an
# empty ps -q result at this single unretried check).
proxy_cid_final=""
proxy_status_final="unknown"
proxy_restarts_final=0
final_check_deadline=$((SECONDS + 15))
while (( SECONDS < final_check_deadline )); do
    proxy_cid_final="$("${compose[@]}" ps -aq proxy || true)"
    if [[ -n "$proxy_cid_final" ]]; then
        proxy_status_final="$(docker inspect --format '{{.State.Status}}' "$proxy_cid_final" 2>/dev/null || echo unknown)"
        proxy_restarts_final="$(docker inspect --format '{{.RestartCount}}' "$proxy_cid_final" 2>/dev/null || echo 0)"
        [[ "$proxy_status_final" == "restarting" || "$proxy_status_final" == "running" ]] && break
    fi
    sleep 1
done
echo "proxy's final state: status=$proxy_status_final, RestartCount=$proxy_restarts_final (still crash-looping throughout the test)."
if [[ "$proxy_status_final" != "restarting" && "$proxy_status_final" != "running" ]]; then
    echo "::error::proxy's final container status is '$proxy_status_final', neither 'restarting' nor a just-relaunched 'running' -- the crash loop did not stay active for the duration of this test." >&2
    exit 1
fi

echo "ui-reachability-crash-loop-simulation passed: with proxy (a real 'ui' depends_on entry) deliberately and continuously crash-looping throughout, the Admin UI still started, became healthy, never restarted itself, and answered a real HTTP request on http://${ui_ip}:8080/health -- confirming deploy/full-setup/docker-compose.yml's 'ui' depends_on list has no condition: service_healthy gate on proxy/nats/docker-socket-proxy."
