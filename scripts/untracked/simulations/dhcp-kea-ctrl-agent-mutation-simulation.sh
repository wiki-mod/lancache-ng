#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Tests static reservation add/remove via Admin UI.
# Why: Verifies kea_config_modify() Rust code against Kea.
# From: Issue #634
#
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

client_tool_image="${DHCP_CTRL_AGENT_CLIENT_IMAGE:?DHCP_CTRL_AGENT_CLIENT_IMAGE is required (an image providing dhclient/curl/jq, e.g. the build-tools image)}"
image_tag="${LANCACHE_IMAGE_TAG:-nightly}"

# What: Load validation subnet from CI environment.
# Why: Per-run /27 subnet avoids collision.
# From: Issue #820
validation_subnet="${VALIDATION_SUBNET:-172.30.99.0/27}"
# What: Parse subnet prefix and base octet dynamically.
# Why: /27 base varies; /24 assumption no longer valid.
# From: Issue #832
subnet_no_prefixlen="${validation_subnet%/*}"      # e.g. 172.30.147.64
subnet_prefix="${subnet_no_prefixlen%.*}"          # e.g. 172.30.147
subnet_base_octet="${subnet_no_prefixlen##*.}"     # e.g. 64
gateway_ip="${VALIDATION_GATEWAY:-172.30.99.1}"
compose_project="${COMPOSE_PROJECT_NAME:-lancache-ng-validation}"
network_name="${compose_project}_validation"
ui_ip="${VALIDATION_UI_IP:-172.30.99.9}"
# What: Reserve IP range base+11..base+30 for this script.
# Why: Allows concurrent runs with setup-reset script.
kea_ip="${subnet_prefix}.$((subnet_base_octet + 11))"
pool_start="${subnet_prefix}.$((subnet_base_octet + 12))"
pool_end="${subnet_prefix}.$((subnet_base_octet + 19))"
# What: Reserve static IP outside dynamic pool.
# Why: Tests Kea static reservation functionality.
reserved_ip="${subnet_prefix}.$((subnet_base_octet + 20))"
# What: Generate test MAC from PID for uniqueness.
# Why: Prevents concurrent runs from colliding.
test_mac="$(printf '02:11:22:33:44:%02x' "$(( $$ % 256 ))")"
reserved_hostname="ctrl-agent-mutation-test"

kea_ctrl_token="$(openssl rand -hex 32)"
ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"
kea_image_tag="lancache-ng-dhcp634-kea:$$"
kea_container="lancache-ng-dhcp634-kea-$$"
ui_container="lancache-ng-dhcp634-ui-$$"

# What: Work directory outside git worktree.
# Why: Prevents uid-10001 dirs from poisoning future CI.
# From: Issue #1123
work_dir="${TMPDIR:-/tmp}/lancache-ng-dhcp-kea-ctrl-agent-mutation.$$"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"
# What: Shared kea-data volume for snapshots.
# Why: Admin UI needs to persist known-good config.
mkdir -p "$work_dir/kea-data"

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    docker rm -f "$ui_container" "$kea_container" >/dev/null 2>&1 || true
    LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    # What: Reset uid-10001 dirs to current user.
    # Why: Kea entrypoint creates uid-10001 files; rm fails.
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
docker build -q -t "$kea_image_tag" --build-context "shared-scripts=$repo_root/scripts/lib" services/dhcp >/dev/null

echo "== Starting docker-socket-proxy/proxy/nats from the published $image_tag images =="
# What: Start docker-socket-proxy, proxy, nats services.
# Why: UI health requires NATS; mirrors sibling scripts.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" up -d docker-socket-proxy proxy nats

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    all_ready=1
    for service in proxy nats; do
        # What: Wrap to capture and report errors.
        # Why: Bare assignments abort; check shows cause.
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
    -e DHCP_SUBNET="$validation_subnet" \
    -e DHCP_RANGE_START="$pool_start" \
    -e DHCP_RANGE_END="$pool_end" \
    -e DHCP_GATEWAY="$gateway_ip" \
    -e DHCP_DOMAIN="lancache-dhcp634-test.lan" \
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
echo "Kea DHCPv4 server and Control Agent are up (Subnet: $validation_subnet, Pool: $pool_start - $pool_end)."

echo "== Starting the real Admin UI (published $image_tag image) pointed at this Kea Control Agent =="
# What: Use 'compose run' not 'up' for one-off container.
# Why: Allows per-call env overrides without editing yaml.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" run -d --name "$ui_container" \
    -v "$work_dir/kea-data:/var/lib/kea" \
    -e DHCP_MODE=kea \
    -e DHCP_API_URL="http://$kea_ip:8000" \
    -e DHCP_API_TOKEN="$kea_ctrl_token" \
    ui >/dev/null

echo "== Waiting for the Admin UI to become healthy =="
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
        "$client_tool_image" bash -c "$1"
}

echo "== UI: establishing a session and extracting its CSRF token =="
# What: Extract CSRF token from session cookie field 3.
# Why: Required for all Admin UI mutating POST requests.
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/dhcp'"
if ! cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"; then
    echo "::error::Could not read the session cookie back from $work_dir/shared/cookiejar." >&2
    exit 1
fi
if [[ -z "$cookie_value" ]]; then
    echo "::error::No lancache_ui_session cookie was set by GET /dhcp." >&2
    exit 1
fi
csrf_token="$(cut -d. -f3 <<<"$cookie_value")"
if [[ -z "$csrf_token" ]]; then
    echo "::error::Could not extract a CSRF token from the session cookie." >&2
    exit 1
fi
echo "Session established, CSRF token extracted."

# request_lease <label> <state_subdir>
# What: Request fresh DHCP lease in isolated container.
# Why: Ensures fresh DISCOVER, not stale renewal.
request_lease() {
    local label="$1" state_subdir="$2" client_container
    client_container="lancache-ng-dhcp634-client-${state_subdir}-$$"
    mkdir -p "$work_dir/$state_subdir"

    docker run -d --name "$client_container" \
        --network "$network_name" --mac-address "$test_mac" \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        -v "$work_dir/$state_subdir:/dhcp-test" \
        "$client_tool_image" \
        bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /dhcp-test/dhclient.pid -lf /dhcp-test/dhclient.leases eth0 >/dhcp-test/dhclient.out 2>&1; echo DONE >> /dhcp-test/dhclient.out' \
        >/dev/null

    local lease_deadline=$((SECONDS + 30)) lease_obtained=0
    while (( SECONDS < lease_deadline )); do
        if [[ -s "$work_dir/$state_subdir/dhclient.leases" ]] && grep -q '^}' "$work_dir/$state_subdir/dhclient.leases" 2>/dev/null; then
            lease_obtained=1
            break
        fi
        sleep 1
    done
    docker rm -f "$client_container" >/dev/null 2>&1 || true

    # What: Send diagnostics to stderr; stdout is IP only.
    # Why: stdout substitution must contain single address.
    {
        echo "::group::$label: raw dhclient output"
        cat "$work_dir/$state_subdir/dhclient.out" 2>/dev/null || echo "(no client output captured)"
        echo "::endgroup::"
    } >&2

    if [[ "$lease_obtained" -ne 1 ]]; then
        echo "::error::$label: dhclient never obtained a lease within 30s." >&2
        return 1
    fi

    local parsed
    parsed="$(dhcp_lease_parse_latest "$work_dir/$state_subdir/dhclient.leases")" || {
        echo "::error::$label: a lease file was written but could not be parsed." >&2
        return 1
    }
    dhcp_lease_field "$parsed" address || true
}

address_in_range() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
}

echo "== Baseline: requesting a lease for $test_mac before any mutation =="
if ! baseline_address="$(request_lease "baseline" "client-state-baseline")"; then
    echo "::error::request_lease failed outright for the baseline lease (e.g. the underlying docker run could not even start)." >&2
    exit 1
fi
if [[ "$(address_in_range "$baseline_address" "$pool_start" "$pool_end")" != "yes" ]]; then
    echo "::error::Baseline address '$baseline_address' is not in the dynamic pool ($pool_start - $pool_end)." >&2
    exit 1
fi
echo "Baseline lease $baseline_address is a normal dynamic-pool address, as expected before any reservation exists."

echo "== UI: adding a real static DHCP reservation via POST /dhcp/static/add (kea_config_modify round trip) =="
if ! add_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$test_mac' \
    --data-urlencode 'ip=$reserved_ip' \
    --data-urlencode 'hostname=$reserved_hostname' \
    'http://$ui_ip:8080/dhcp/static/add'")"; then
    echo "::error::POST /dhcp/static/add via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
if [[ "$add_http_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add returned HTTP $add_http_code, expected 303 (redirect to /dhcp)." >&2
    run_client "cat /shared/add-response" || true
    docker logs "$ui_container" >&2 || true
    exit 1
fi
echo "Admin UI accepted the reservation add (303 redirect) -- config-test/config-set/config-write all succeeded against real Kea."

echo "== Verifying the reservation is observable in a follow-up config-get against real Kea =="
if ! reservation_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" --arg ip "$3" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase) and ."ip-address" == $ip)]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$test_mac" "$reserved_ip")"; then
    echo "::error::Could not run the config-get reservation-present check against Kea's Control Agent ($kea_container)." >&2
    exit 1
fi
if [[ "$reservation_present" != "yes" ]]; then
    echo "::error::Kea's own config-get does not show the reservation that was just added via the Admin UI." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation ($test_mac -> $reserved_ip) is present."

echo "== Requesting a SECOND lease for $test_mac: must now receive the reserved address =="
if ! reserved_address="$(request_lease "post-add" "client-state-post-add")"; then
    echo "::error::request_lease failed outright for the post-add lease (e.g. the underlying docker run could not even start)." >&2
    exit 1
fi
if [[ "$reserved_address" != "$reserved_ip" ]]; then
    echo "::error::After adding the reservation, dhclient received '$reserved_address', expected the reserved address $reserved_ip." >&2
    exit 1
fi
echo "Confirmed: a real, subsequent DHCP request for $test_mac now receives the reserved address $reserved_ip -- the mutation genuinely changed what Kea hands out, not just the config file."

echo "== UI: removing the reservation via POST /dhcp/static/remove =="
if ! remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/remove-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$test_mac' \
    'http://$ui_ip:8080/dhcp/static/remove'")"; then
    echo "::error::POST /dhcp/static/remove via run_client failed outright (curl/docker invocation error)." >&2
    exit 1
fi
if [[ "$remove_http_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/remove returned HTTP $remove_http_code, expected 303 (redirect to /dhcp)." >&2
    run_client "cat /shared/remove-response" || true
    docker logs "$ui_container" >&2 || true
    exit 1
fi
echo "Admin UI accepted the reservation removal (303 redirect)."

if ! reservation_gone="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length == 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$test_mac")"; then
    echo "::error::Could not run the config-get reservation-gone check against Kea's Control Agent ($kea_container)." >&2
    exit 1
fi
if [[ "$reservation_gone" != "yes" ]]; then
    echo "::error::Kea's own config-get still shows the reservation after removal via the Admin UI." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation for $test_mac is gone."

# What: Delete orphaned lease before verifying removal.
# Why: Removed reservations don't auto-expire active leases.
# From: Issue #634
echo "== Clearing the now-orphaned active Kea lease for $reserved_ip before the next request =="
if ! lease_del_result="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"lease4-del\",\"service\":[\"dhcp4\"],\"arguments\":{\"ip-address\":\"$2\"}}" \
        "http://127.0.0.1:8000/" | jq -r ".[0].result"
' -- "$kea_ctrl_token" "$reserved_ip")"; then
    echo "::error::Could not run lease4-del for $reserved_ip against Kea's Control Agent ($kea_container)." >&2
    exit 1
fi
# What: Accept codes 0 (deleted) and 3 (empty lease).
# Why: Both mean no active lease; others indicate failure.
if [[ "$lease_del_result" != "0" && "$lease_del_result" != "3" ]]; then
    echo "::error::lease4-del for $reserved_ip returned unexpected Kea result code '$lease_del_result'." >&2
    exit 1
fi
echo "Active lease for $reserved_ip cleared from Kea's lease database (lease4-del result: $lease_del_result)."

echo "== Requesting a THIRD lease for $test_mac: must be back in the dynamic pool =="
if ! post_remove_address="$(request_lease "post-remove" "client-state-post-remove")"; then
    echo "::error::request_lease failed outright for the post-remove lease (e.g. the underlying docker run could not even start)." >&2
    exit 1
fi
if [[ "$post_remove_address" == "$reserved_ip" ]]; then
    echo "::error::After removing the reservation, dhclient still received the reserved address $reserved_ip." >&2
    exit 1
fi
if [[ "$(address_in_range "$post_remove_address" "$pool_start" "$pool_end")" != "yes" ]]; then
    echo "::error::After removing the reservation, dhclient received '$post_remove_address', which is not in the dynamic pool ($pool_start - $pool_end)." >&2
    exit 1
fi
echo "Confirmed: removing the reservation also genuinely took effect on a subsequent DHCP request -- $test_mac is back to an ordinary dynamic-pool address ($post_remove_address)."

report=$(cat <<REPORT
== Kea Control Agent mutation round-trip result (issue #634) ==
Test MAC:                    $test_mac
Baseline lease (pre-add):    $baseline_address (dynamic pool)
Lease after reservation add: $reserved_address (reserved address)
Lease after reservation del: $post_remove_address (dynamic pool)

Verified: a real static host reservation was added and removed through the
actual Admin UI HTTP route (POST /dhcp/static/add, /dhcp/static/remove),
which calls the exact kea_config_modify() Rust code path
(config-get -> config-test -> config-set -> config-write) against a real Kea
Control Agent -- not a direct Kea API call bypassing that code. Both the
config-get-visible state AND a subsequent real DHCP lease request reflected
each mutation, not just the persisted config file.

NOT verified by this script (see header comment / docs/dhcp-modes.md):
subnet/custom-option mutation routes beyond reservations (same underlying
code path, not route-by-route exhaustive), DHCP-DDNS lease-event
follow-through, and the dnsmasq-proxy DHCP mode (Refs #557 for the first two).
REPORT
)
echo "$report"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo '```text'
        echo "$report"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

echo "dhcp-kea-ctrl-agent-mutation-simulation passed: real reservation add+remove round-tripped through the Admin UI's Kea Control Agent code path and both changes were reflected in subsequent real DHCP lease requests."
