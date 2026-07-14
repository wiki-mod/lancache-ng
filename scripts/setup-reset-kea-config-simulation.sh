#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end proof for #763's CLI-fallback item: `setup.sh
# reset-to-last-known-good-config kea` must actually roll a real, running Kea
# server back to an earlier config -- not just return success. Reuses the
# same real-Kea-container/real-Admin-UI topology
# scripts/dhcp-kea-ctrl-agent-mutation-simulation.sh already established for
# issue #634 (same image build, same bind-mounted kea-data volume, same
# session/CSRF technique), rather than inventing a second way to stand up
# Kea+the Admin UI for a test.
#
# What this script does:
#   1. Starts a real Kea container (this checkout's services/dhcp) and a real
#      Admin UI container (published stack image; this change does not touch
#      services/ui) sharing one bind-mounted kea-data directory, exactly like
#      docker-compose.yml shares that volume between the two services in
#      every real deployment.
#   2. Through the Admin UI's real HTTP routes, adds reservation A (creating
#      known-good snapshot S_A, the Admin UI's own post-config-write side
#      effect -- see services/ui/src/kea_snapshots.rs), then adds a SECOND,
#      unrelated reservation B (creating snapshot S_AB, since Kea's config
#      now holds both).
#   3. Runs the real `setup.sh reset-to-last-known-good-config kea` command
#      (--yes, so this runs non-interactively; the confirmation prompt itself
#      is a separate, deliberately interactive safety feature not under test
#      here) against S_A -- the CLI's config-test -> config-set ->
#      config-write chain against Kea's real Control Agent.
#   4. Confirms via a fresh `config-get` against the real Kea server that
#      reservation A is still present and reservation B is GONE -- proof the
#      command genuinely rolled Kea's live config back, not just that the API
#      calls returned success.
#
# What this script does NOT verify:
#   - The interactive confirmation prompt itself (ask()/confirm() read
#     /dev/tty, which setup-cli-simulation.sh already covers for other
#     subcommands via `expect`; --yes exists so this command can be driven
#     the same way scripted/automated recovery would use it).
#   - The 'dns'/'pdns' service target -- not yet implemented (depends on
#     issue #628's rollback listener); see cmd_reset_to_last_known_good_config
#     in setup.sh.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required (an image providing curl, e.g. the build-tools image)}"

# full-setup-deep-validate.yml's compute-validation-network job derives a
# COLLISION-FREE per-run subnet (e.g. 172.30.147.0/24), not always the fixed
# 172.30.99.0/24 dhcp-kea-ctrl-agent-mutation-simulation.sh's own comment
# describes -- that sibling script only gets away with a hardcoded subnet
# because it is manual-workflow-only (full-setup-validate.yml), where this
# job's env block does not thread VALIDATION_SUBNET through at all (#703).
# THIS script's job DOES thread it, so every address below must be derived
# from the real subnet in effect this run, not assumed fixed -- confirmed the
# hard way: a first version of this script hardcoded 172.30.99.x and failed
# with "no configured subnet contains IP address 172.30.99.21" the first time
# it actually ran against a per-run-derived, non-default subnet.
subnet_cidr="${VALIDATION_SUBNET:-172.30.99.0/24}"
subnet_prefix="${subnet_cidr%.*/*}"
ui_ip="${VALIDATION_UI_IP:-${subnet_prefix}.9}"
gateway_ip="${VALIDATION_GATEWAY:-${subnet_prefix}.1}"
# .2-.9 are already claimed by proxy/dns-standard/dns-ssl/watchdog/netdata/
# nats/ui in deploy/full-setup/docker-compose.yml (see compute-validation-network's
# derivation), .21 avoids dhcp-kea-ctrl-agent-mutation-simulation.sh's own .20
# so both could run concurrently on a shared runner without colliding.
kea_ip="${subnet_prefix}.21"
dhcp_pool_start="${subnet_prefix}.100"
dhcp_pool_end="${subnet_prefix}.150"
reservation_ip_a="${subnet_prefix}.223"
reservation_ip_b="${subnet_prefix}.224"

kea_ctrl_token="$(openssl rand -hex 32)"
ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"
kea_image_tag="lancache-ng-resetkea:$$"
kea_container="lancache-ng-resetkea-kea-$$"
ui_container="lancache-ng-resetkea-ui-$$"

work_dir="$repo_root/.setup-reset-kea-config-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared" "$work_dir/kea-data" "$work_dir/install"

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    docker rm -f "$ui_container" "$kea_container" >/dev/null 2>&1 || true
    LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    # Reported for real on a shared self-hosted runner (not hypothetical):
    # services/dhcp/entrypoint.sh runs as root inside the Kea container and
    # chowns kea-data/config-snapshots/ to the Admin UI's fixed unprivileged
    # uid (10001, see that entrypoint and dhcp-kea-ctrl-agent-mutation-
    # simulation.sh's identical comment on its own kea-data mount). Left
    # as-is, the plain `rm -rf "$work_dir"` below silently fails to remove
    # those now-root/10001-owned files, leaving them on disk under this
    # runner's own actions-runner work directory -- which then made a LATER
    # job's `actions/checkout` on the same runner slot fail outright trying
    # to clean its workspace (EACCES: permission denied, rmdir ...),
    # blocking an unrelated PR's CI run. Reset ownership back to this
    # process's own uid/gid via the already-built (no extra pull) Kea image
    # -- unconditionally, in this EXIT trap, so it runs whether the
    # simulation above succeeded or failed, not just on the happy path --
    # before ever touching rm -rf.
    if [[ -d "$work_dir" ]]; then
        # Reported explicitly (not just silently `|| true`-d) because the
        # first time this was fixed, the fix's own success was only ever
        # confirmed by *inference* (grepping a later run's log for the
        # absence of a "Permission denied" from the `rm -rf` below) --
        # good enough after the fact, but not something a future reviewer
        # of this same log could confirm at a glance without redoing that
        # archaeology. Printing the chown's own exit code makes "did the
        # ownership reset actually happen" a directly visible fact in
        # every run's log, success or failure, instead of an inference.
        if docker run --rm --entrypoint chown \
            -v "$work_dir:/reset-owner" \
            "$kea_image_tag" -R "$(id -u):$(id -g)" /reset-owner >/dev/null 2>&1; then
            echo "cleanup: reset ownership of $work_dir to $(id -u):$(id -g) -- ok"
        else
            echo "cleanup: WARNING -- resetting ownership of $work_dir failed (rc=$?); the rm -rf below may leave files behind on this runner" >&2
        fi
    fi
    docker rmi "$kea_image_tag" >/dev/null 2>&1 || true
    # `|| true`: confirmed for real that this exact command, unguarded, is
    # what turned a run where the simulation itself printed its own "passed:"
    # success message into a job CI still reported as failed -- `rm -rf`
    # still exits non-zero on a permission-denied removal (the chown step
    # above should prevent that now, but this is the second, independent
    # layer: this trap's whole point is to report the TEST's own outcome via
    # `exit "$status"` below, never let an incidental cleanup hiccup
    # overwrite that). Its own stderr is deliberately left unredirected (unlike
    # the chown step above) so a leftover permission-denied file still shows
    # up verbatim in the log even though it can no longer flip the job red.
    if rm -rf "$work_dir"; then
        echo "cleanup: removed $work_dir -- ok"
    else
        echo "cleanup: WARNING -- rm -rf $work_dir left files behind (see stderr above); this can block a LATER job's actions/checkout on this same runner slot" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
docker build -q -t "$kea_image_tag" services/dhcp >/dev/null

echo "== Starting docker-socket-proxy/proxy/nats from the published $image_tag images =="
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" up -d docker-socket-proxy proxy nats

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy nats; do
        cid="$("${compose[@]}" ps -q "$service")"
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    (( all_ready == 1 )) && break
    sleep 5
done
for service in proxy nats; do
    cid="$("${compose[@]}" ps -q "$service")"
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" ]]; then
        echo "::error::$service did not become healthy (status: $status)" >&2
        "${compose[@]}" logs --no-color "$service"
        exit 1
    fi
done
echo "proxy and nats are healthy."

echo "== Starting a real Kea container on the same compose network ($network_name, ip $kea_ip) =="
docker run -d --name "$kea_container" \
    --network "$network_name" --ip "$kea_ip" \
    --cap-add NET_ADMIN \
    -v "$work_dir/kea-data:/var/lib/kea" \
    -e DHCP_SUBNET="$subnet_cidr" \
    -e DHCP_RANGE_START="$dhcp_pool_start" \
    -e DHCP_RANGE_END="$dhcp_pool_end" \
    -e DHCP_GATEWAY="$gateway_ip" \
    -e DHCP_DOMAIN="lancache-resetkea-test.lan" \
    -e DHCP_LEASE_TIME=1800 \
    -e DHCP_NTP_SERVERS="" \
    -e DHCP_DNS_PRIMARY="$kea_ip" \
    -e DHCP_DNS_SECONDARY="$kea_ip" \
    -e KEA_CTRL_TOKEN="$kea_ctrl_token" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    -e DHCP_DNS_SERVER_IP="$kea_ip" \
    "$kea_image_tag" >/dev/null

echo "== Waiting for the Kea Control Agent API to answer =="
deadline=$((SECONDS + 60))
kea_ready=0
while (( SECONDS < deadline )); do
    if docker exec "$kea_container" sh -c '
        curl -sf -u "admin:$1" -H "Content-Type: application/json" \
            -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
            "http://127.0.0.1:8000/" | jq -e ".[0].result == 0" >/dev/null
    ' -- "$kea_ctrl_token" 2>/dev/null; then
        kea_ready=1
        break
    fi
    sleep 2
done
if [[ "$kea_ready" -ne 1 ]]; then
    echo "::error::Kea Control Agent API never became ready." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi
echo "Kea DHCPv4 server and Control Agent are up."

echo "== Starting the real Admin UI (published $image_tag image) pointed at this Kea Control Agent =="
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" run -d --name "$ui_container" \
    -v "$work_dir/kea-data:/var/lib/kea" \
    -e DHCP_MODE=kea \
    -e DHCP_API_URL="http://$kea_ip:8000" \
    -e DHCP_API_TOKEN="$kea_ctrl_token" \
    ui >/dev/null

deadline=$((SECONDS + 90))
ui_ready=0
while (( SECONDS < deadline )); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$ui_container" 2>/dev/null || echo "unknown")"
    if [[ "$status" = "healthy" ]]; then
        ui_ready=1
        break
    fi
    sleep 5
done
if [[ "$ui_ready" -ne 1 ]]; then
    echo "::error::Admin UI did not become healthy." >&2
    docker logs "$ui_container" >&2 || true
    exit 1
fi
echo "Admin UI is healthy."

run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://${ui_ip}:8080/dhcp'"
cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"
[[ -n "$cookie_value" ]] || { echo "::error::No lancache_ui_session cookie was set by GET /dhcp." >&2; exit 1; }
csrf_token="$(cut -d. -f3 <<<"$cookie_value")"
[[ -n "$csrf_token" ]] || { echo "::error::Could not extract a CSRF token from the session cookie." >&2; exit 1; }
echo "Session established, CSRF token extracted."

echo "== UI: adding reservation A (creates known-good snapshot S_A) =="
mac_a="02:11:22:33:55:$(printf '%02x' "$(( $$ % 256 ))")"
ip_a="$reservation_ip_a"
add_a_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-a-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$mac_a' \
    --data-urlencode 'ip=$ip_a' \
    --data-urlencode 'hostname=resetkea-a' \
    'http://${ui_ip}:8080/dhcp/static/add'")"
if [[ "$add_a_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add (reservation A) returned HTTP $add_a_code, expected 303." >&2
    run_client "cat /shared/add-a-response" || true
    exit 1
fi
echo "Reservation A added ($mac_a -> $ip_a)."

echo "== UI: adding reservation B (creates known-good snapshot S_AB) =="
mac_b="02:11:22:33:66:$(printf '%02x' "$(( $$ % 256 ))")"
ip_b="$reservation_ip_b"
add_b_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-b-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$mac_b' \
    --data-urlencode 'ip=$ip_b' \
    --data-urlencode 'hostname=resetkea-b' \
    'http://${ui_ip}:8080/dhcp/static/add'")"
if [[ "$add_b_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add (reservation B) returned HTTP $add_b_code, expected 303." >&2
    run_client "cat /shared/add-b-response" || true
    exit 1
fi
echo "Reservation B added ($mac_b -> $ip_b). Kea's live config now holds both A and B."

# Each successful config-write above records a fresh known-good snapshot
# (services/ui/src/kea_snapshots.rs), so the OLDEST (lowest-id, i.e. first in
# a plain sort of the fixed-width zero-padded nanosecond-timestamp directory
# names) snapshot on disk is the one captured right after reservation A was
# added -- before B ever existed. That is deliberately the id this test rolls
# back to.
snapshot_root="$work_dir/kea-data/config-snapshots"
mapfile -t snapshot_ids < <(find "$snapshot_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec basename {} \; | sort)
if [[ ${#snapshot_ids[@]} -lt 2 ]]; then
    echo "::error::Expected at least 2 known-good Kea snapshots under $snapshot_root after two successful reservation adds, found ${#snapshot_ids[@]}." >&2
    exit 1
fi
snapshot_after_a="${snapshot_ids[0]}"
echo "Snapshot ids on disk (oldest first): ${snapshot_ids[*]}"
echo "Rolling back to the snapshot captured right after reservation A: $snapshot_after_a"

echo "== Running the real 'setup.sh reset-to-last-known-good-config kea' CLI fallback =="
# A throwaway install-dir: this command only needs docker-compose.yml to
# exist (its own "is there a stack here" guard) and a .env carrying the same
# KEA_CTRL_TOKEN/KEA_CTRL_HOST/KEA_DATA_DIR this test's real Kea container
# and bind-mounted kea-data directory already use -- it does not need a real
# running compose stack of its own, since it talks to Kea's Control Agent
# directly over HTTP, exactly like a real operator's install would.
install_dir="$work_dir/install"
: > "$install_dir/docker-compose.yml"
cat > "$install_dir/.env" <<EOF
KEA_CTRL_TOKEN=${kea_ctrl_token}
KEA_CTRL_HOST=${kea_ip}
KEA_DATA_DIR=${work_dir}/kea-data
EOF

if ! reset_output=$(bash setup.sh reset-to-last-known-good-config kea "$install_dir" "$snapshot_after_a" --yes 2>&1); then
    echo "::error::setup.sh reset-to-last-known-good-config kea failed:" >&2
    echo "$reset_output" >&2
    exit 1
fi
echo "$reset_output"
echo "setup.sh reported success rolling back to snapshot $snapshot_after_a."

echo "== Verifying via a fresh config-get against the real Kea server =="
reservation_a_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$mac_a")"
reservation_b_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$mac_b")"

failed=0
if [[ "$reservation_a_present" != "yes" ]]; then
    echo "::error::After rollback, reservation A ($mac_a) is missing from Kea's live config-get -- the rollback should have PRESERVED it (it was already present in the snapshot rolled back to)." >&2
    failed=1
else
    echo "Reservation A ($mac_a) is present after rollback, as expected."
fi
if [[ "$reservation_b_present" != "no" ]]; then
    echo "::error::After rollback, reservation B ($mac_b) is STILL present in Kea's live config-get -- the rollback did not actually revert Kea's real state, only claimed success." >&2
    failed=1
else
    echo "Reservation B ($mac_b) is gone after rollback, as expected -- Kea's real, live config genuinely reverted."
fi

if [[ "$failed" -eq 1 ]]; then
    exit 1
fi

echo "setup-reset-kea-config-simulation passed: 'setup.sh reset-to-last-known-good-config kea' genuinely rolled a real, running Kea server back to an earlier known-good snapshot via config-test -> config-set -> config-write against its real Control Agent -- confirmed by a fresh config-get showing the pre-rollback reservation gone and the rolled-back-to reservation intact."
