#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Tests CLI reset-to-last-known-good-config Kea.
# Why: Verify CLI command rolls back Kea live config.
# From: Issue #763
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"
build_tools_image="${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required (an image providing curl, e.g. the build-tools image)}"

# What: Load per-run VALIDATION_SUBNET from environment.
# Why: Job threads subnet; addresses must be derived.
# From: Issue #703
subnet_cidr="${VALIDATION_SUBNET:-172.30.99.0/27}"
# What: Parse subnet prefix and base octet dynamically.
# Why: /27 base varies; /24 assumption no longer valid.
# From: Issue #832
subnet_no_prefixlen="${subnet_cidr%/*}"          # e.g. 172.30.147.96
subnet_prefix="${subnet_no_prefixlen%.*}"        # e.g. 172.30.147
subnet_base_octet="${subnet_no_prefixlen##*.}"   # e.g. 96
ui_ip="${VALIDATION_UI_IP:-${subnet_prefix}.$((subnet_base_octet + 9))}"
gateway_ip="${VALIDATION_GATEWAY:-${subnet_prefix}.$((subnet_base_octet + 1))}"
# What: Reserve base+21..base+29; avoid mutation script.
# Why: Allows concurrent runs without IP collision.
kea_ip="${subnet_prefix}.$((subnet_base_octet + 21))"
dhcp_pool_start="${subnet_prefix}.$((subnet_base_octet + 22))"
dhcp_pool_end="${subnet_prefix}.$((subnet_base_octet + 27))"
reservation_ip_a="${subnet_prefix}.$((subnet_base_octet + 28))"
reservation_ip_b="${subnet_prefix}.$((subnet_base_octet + 29))"

# What: Wrap secret generation with error handling.
# Why: Bare assignments abort silently; wrap shows errors.
if ! kea_ctrl_token="$(openssl rand -hex 32)"; then
    echo "::error::Failed to generate the Kea Control Agent auth token (openssl rand -hex 32)." >&2
    exit 1
fi
if ! ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"; then
    echo "::error::Failed to generate the DDNS TSIG key (openssl rand -base64 32 | tr -d '\\n')." >&2
    exit 1
fi
kea_image_tag="lancache-ng-resetkea:$$"
kea_container="lancache-ng-resetkea-kea-$$"
ui_container="lancache-ng-resetkea-ui-$$"

# What: Work directory outside git worktree.
# Why: Prevents uid-10001 dirs from poisoning future CI.
# From: Issue #1123
work_dir="${TMPDIR:-/tmp}/lancache-ng-setup-reset-kea-config.$$"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared" "$work_dir/kea-data" "$work_dir/install"

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    docker rm -f "$ui_container" "$kea_container" >/dev/null 2>&1 || true
    LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    # What: Reset uid-10001 dirs to current user.
    # Why: Kea creates uid-10001 files; rm fails.
    # From: Issue #1123
    if [[ -d "$work_dir" ]]; then
        # What: Report chown result explicitly to stdout.
        # Why: Absence of error doesn't prove success.
        if docker run --rm --entrypoint chown \
            -v "$work_dir:/reset-owner" \
            "$kea_image_tag" -R "$(id -u):$(id -g)" /reset-owner >/dev/null 2>&1; then
            echo "cleanup: reset ownership of $work_dir to $(id -u):$(id -g) -- ok"
        else
            echo "cleanup: WARNING -- resetting ownership of $work_dir failed (rc=$?); the rm -rf below may leave files behind on this runner" >&2
        fi
    fi
    docker rmi "$kea_image_tag" >/dev/null 2>&1 || true
    # What: Remove work dir with explicit error reporting.
    # Why: Avoid spurious failures from cleanup errors.
    if rm -rf "$work_dir"; then
        echo "cleanup: removed $work_dir -- ok"
    else
        echo "cleanup: WARNING -- rm -rf $work_dir left files behind (see stderr above); harmless to other jobs now that work_dir lives under \$TMPDIR outside the checkout, but it should not normally happen after the ownership reset above" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
# What: passes shared-scripts as a named build context.
# Why: else COPY --from=shared-scripts triggers a bad pull.
# From: Issue #1095
docker build -q -t "$kea_image_tag" --build-context "shared-scripts=$repo_root/scripts/lib" services/dhcp >/dev/null

echo "== Starting docker-socket-proxy/proxy/nats from the published $image_tag images =="
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" up -d docker-socket-proxy proxy nats

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy nats; do
        # What: Wrap assignment to catch cmd errors.
        # Why: Bare assignment triggers errexit silently.
        if ! cid="$("${compose[@]}" ps -q "$service")"; then
            echo "::error::Could not query the compose container id for service '$service'." >&2
            exit 1
        fi
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
        [[ "$status" = "healthy" ]] || all_ready=0
    done
    (( all_ready == 1 )) && break
    sleep 5
done
for service in proxy nats; do
    if ! cid="$("${compose[@]}" ps -q "$service")"; then
        echo "::error::Could not query the compose container id for service '$service'." >&2
        exit 1
    fi
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

# What: Reuse /shared for persistent cookiejar.
# Why: /shared bind-mounts from host; survives.
run_client() {
    docker run --rm --network "$network_name" \
        -v "$work_dir/shared:/shared" \
        "$build_tools_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://${ui_ip}:8080/dhcp'"
# What: Wrap awk assignment in error check.
# Why: Bare assignment triggers errexit silently.
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Failed to read the cookiejar file to extract the lancache_ui_session cookie." >&2
    exit 1
fi
[[ -n "$cookie_value" ]] || { echo "::error::No lancache_ui_session cookie was set by GET /dhcp." >&2; exit 1; }
if ! csrf_token="$(cut -d. -f3 <<<"$cookie_value")"; then
    echo "::error::Failed to extract the CSRF token segment from the session cookie value." >&2
    exit 1
fi
[[ -n "$csrf_token" ]] || { echo "::error::Could not extract a CSRF token from the session cookie." >&2; exit 1; }
echo "Session established, CSRF token extracted."

echo "== UI: adding reservation A (creates known-good snapshot S_A) =="
# A fixed, locally-administered (0x02 high nibble) test MAC -- never a real
# vendor OUI, and unique enough per run (low bits from this run's PID) that
# concurrent local runs of this script don't collide on the same reservation.
mac_a="02:11:22:33:55:$(printf '%02x' "$(( $$ % 256 ))")"
ip_a="$reservation_ip_a"
if ! add_a_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-a-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$mac_a' \
    --data-urlencode 'ip=$ip_a' \
    --data-urlencode 'hostname=resetkea-a' \
    'http://${ui_ip}:8080/dhcp/static/add'")"; then
    echo "::error::run_client/curl invocation for POST /dhcp/static/add (reservation A) failed outright." >&2
    exit 1
fi
if [[ "$add_a_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add (reservation A) returned HTTP $add_a_code, expected 303." >&2
    run_client "cat /shared/add-a-response" || true
    exit 1
fi
echo "Reservation A added ($mac_a -> $ip_a)."

echo "== UI: adding reservation B (creates known-good snapshot S_AB) =="
mac_b="02:11:22:33:66:$(printf '%02x' "$(( $$ % 256 ))")"
ip_b="$reservation_ip_b"
if ! add_b_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-b-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$mac_b' \
    --data-urlencode 'ip=$ip_b' \
    --data-urlencode 'hostname=resetkea-b' \
    'http://${ui_ip}:8080/dhcp/static/add'")"; then
    echo "::error::run_client/curl invocation for POST /dhcp/static/add (reservation B) failed outright." >&2
    exit 1
fi
if [[ "$add_b_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add (reservation B) returned HTTP $add_b_code, expected 303." >&2
    run_client "cat /shared/add-b-response" || true
    exit 1
fi
echo "Reservation B added ($mac_b -> $ip_b). Kea's live config now holds both A and B."

# What: Use oldest snapshot for rollback test.
# Why: Oldest is first after A, before B existed.
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
# What: Create minimal install-dir stub.
# Why: Only needs docker-compose.yml and .env.
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
# What: Wrap docker exec to catch errors.
# Why: Bare exec triggers errexit without diagnostic.
if ! reservation_a_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$mac_a")"; then
    echo "::error::Failed to query Kea's config-get for reservation A ($mac_a) via docker exec against $kea_container." >&2
    exit 1
fi
if ! reservation_b_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$mac_b")"; then
    echo "::error::Failed to query Kea's config-get for reservation B ($mac_b) via docker exec against $kea_container." >&2
    exit 1
fi

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
