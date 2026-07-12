#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real Kea Control Agent mutation round-trip test (issue #634, the "static
# host reservations" gap explicitly left open by
# scripts/dhcp-kea-lease-flow-simulation.sh -- see docs/dhcp-modes.md). That
# script drives a real DHCP client against our Kea service, but never mutates
# Kea's config; this script drives a real mutation THROUGH the Admin UI's
# actual HTTP route (POST /dhcp/static/add, the same route
# services/ui/src/routes/dhcp.rs's `add_reservation` handler serves, which
# calls `kea_config_modify()` -- the exact function whose
# config-get/config-test/config-set/config-write sequence had a real,
# previously-undetected bug: Kea 2.6.3's config-get response includes a
# `hash` field that config-test/config-set reject outright, and every
# `cargo test` for that function mocked Kea's response without ever including
# that field, so the mismatch went unnoticed until it broke every DHCP
# mutation route in production (fixed in the same change as the regression
# test `kea_config_modify_strips_hash_from_config_get_before_reuse`, which is
# still mock-based). This script is the real, no-mocks equivalent: it proves
# the Rust code's understanding of Kea's actual response shape is still
# correct, and -- per the issue's own acceptance criteria -- that the
# mutation is not just "the API call returned 200" but genuinely changes what
# a SUBSEQUENT real DHCP lease request receives.
#
# What this script does:
#   1. Starts a real Kea container from this checkout's services/dhcp, and a
#      real Admin UI container from the already-published stack image (this
#      change does not touch services/ui, so the published image already has
#      whatever Rust code is under test), both on the same Docker network
#      deploy/full-setup/docker-compose.yml already defines -- the identical
#      project/network/fixed-IP pattern scripts/ui-nats-dns-integration-simulation.sh
#      already established for driving the Admin UI from a sibling
#      container. docker-socket-proxy/proxy/nats are started too because the
#      Admin UI blocks ALL requests (even /health) until it can reach NATS
#      (see connect_nats_with_retry in services/ui/src/main.rs) -- dns-standard
#      /dns-ssl are deliberately NOT started, since nothing on the DHCP pages
#      touches DNS.
#   2. Establishes a real Admin UI session and CSRF token (GET /dhcp), then
#      requests a baseline DHCP lease for a fixed test MAC address BEFORE any
#      mutation, confirming it lands in the ordinary dynamic pool.
#   3. POSTs a real static host reservation for that same MAC to a fixed,
#      out-of-pool address via /dhcp/static/add, and confirms Kea's own
#      config-get afterward shows the reservation (the issue's "ideally...
#      reflected in a follow-up config-get" criterion).
#   4. Requests a SECOND lease for the same MAC and asserts the offered
#      address is now the reserved one, not just any pool address -- this is
#      the actual round-trip proof the issue asks for.
#   5. Removes the reservation via /dhcp/static/remove, confirms config-get no
#      longer shows it, and requests a THIRD lease for the same MAC, asserting
#      it is back in the ordinary dynamic pool (proving the removal also
#      really took effect on a subsequent request, not just in the file).
#
# Safety model, matching dhcp-kea-lease-flow-simulation.sh's own: every DHCP
# client run uses `dhclient -sf /bin/true` (negotiates a real lease over the
# wire, never applies it to any interface), and every container here lives on
# the throwaway compose project's own bridge network, never a host interface.
#
# What this script does NOT verify:
#   - Subnet-level or custom-option mutations (only the reservation add/remove
#     round trip); those routes share the same kea_config_modify() code path,
#     so this script's coverage of that function is representative, not
#     route-by-route exhaustive.
#   - DHCP-DDNS lease-event follow-through -- Refs #557, same scope carve-out
#     as dhcp-kea-lease-flow-simulation.sh.
#   - The dnsmasq-proxy DHCP mode -- entirely different code path, no
#     Kea/Admin-UI Control Agent interaction at all.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

client_tool_image="${DHCP_CTRL_AGENT_CLIENT_IMAGE:?DHCP_CTRL_AGENT_CLIENT_IMAGE is required (an image providing dhclient/curl/jq, e.g. the build-tools image)}"
image_tag="${LANCACHE_IMAGE_TAG:-edge}"

# Same fixed compose project/network/IPs as scripts/ui-nats-dns-integration-simulation.sh
# and scripts/ssl-mitm-cache-simulation.sh -- safe because full-setup-validate.yml
# chains all of these jobs serially (`needs:`/`if: always()`) on the same
# self-hosted runner tier, so they never run concurrently with each other.
compose_project="lancache-ng-validation"
network_name="${compose_project}_validation"
ui_ip="172.30.99.9"
# .2-.9 are already claimed by proxy/dns-standard/dns-ssl/watchdog/netdata/nats/ui
# in deploy/full-setup/docker-compose.yml; .20 is unused by any of them.
kea_ip="172.30.99.20"
pool_start="172.30.99.100"
pool_end="172.30.99.150"
# Deliberately outside the dynamic pool above: the whole point of a static
# reservation is that Kea must hand it out even though ordinary dynamic
# allocation never would.
reserved_ip="172.30.99.222"
# A fixed, locally-administered (0x02 high nibble) test MAC -- never a real
# vendor OUI, and unique enough per run (low bits from this run's PID) that
# concurrent local runs of this script don't collide on the same reservation.
test_mac="$(printf '02:11:22:33:44:%02x' "$(( $$ % 256 ))")"
reserved_hostname="ctrl-agent-mutation-test"

kea_ctrl_token="$(openssl rand -hex 32)"
ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"
kea_image_tag="lancache-ng-dhcp634-kea:$$"
kea_container="lancache-ng-dhcp634-kea-$$"
ui_container="lancache-ng-dhcp634-ui-$$"

work_dir="$repo_root/.dhcp-kea-ctrl-agent-mutation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/shared"

compose=(docker compose -p "$compose_project" -f deploy/full-setup/docker-compose.yml)

cleanup() {
    local status=$?
    docker rm -f "$ui_container" "$kea_container" >/dev/null 2>&1 || true
    LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    docker rmi "$kea_image_tag" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
docker build -q -t "$kea_image_tag" services/dhcp >/dev/null

echo "== Starting docker-socket-proxy/proxy/nats from the published $image_tag images =="
# ui's own /health does not answer at all until NATS is reachable (see
# connect_nats_with_retry in services/ui/src/main.rs); docker-socket-proxy and
# proxy are started to mirror ui-nats-dns-integration-simulation.sh's own
# dependency set even though neither is on the /dhcp code path, keeping this
# script's stack topology recognizable/consistent with that sibling job.
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
    -e DHCP_SUBNET="172.30.99.0/24" \
    -e DHCP_RANGE_START="$pool_start" \
    -e DHCP_RANGE_END="$pool_end" \
    -e DHCP_GATEWAY="172.30.99.1" \
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
echo "Kea DHCPv4 server and Control Agent are up (Subnet: 172.30.99.0/24, Pool: $pool_start - $pool_end)."

echo "== Starting the real Admin UI (published $image_tag image) pointed at this Kea Control Agent =="
# `compose run` (not `up`) so this one-off container's DHCP_MODE/DHCP_API_URL/
# DHCP_API_TOKEN overrides don't require editing the shared
# deploy/full-setup/docker-compose.yml (which hardcodes DHCP_MODE=disabled
# for every other job that reuses this same file). No --service-ports: the
# curl client below reaches it over the compose network directly, exactly
# like ui-nats-dns-integration-simulation.sh already does for $ui_ip:8080.
LANCACHE_IMAGE_TAG="$image_tag" "${compose[@]}" run -d --name "$ui_container" \
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
# Same technique as ui-nats-dns-integration-simulation.sh: a plain GET against
# a protected route establishes the session cookie
# (v1.<expires>.<csrf_token>.<signature>), whose third dot-separated field is
# the CSRF token every mutating request must echo back.
run_client "curl -sS -c /shared/cookiejar -o /dev/null 'http://$ui_ip:8080/dhcp'"
cookie_value="$(awk -F'\t' '$6 == "lancache_ui_session" {print $7}' "$work_dir/shared/cookiejar")"
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
# Runs one fresh, one-shot dhclient container for $test_mac and prints the
# offered IPv4 address (empty if none was obtained within the deadline). A
# fresh container/state dir per call, matching
# dhcp-kea-lease-flow-simulation.sh's own established technique, so each call
# is a genuinely new DISCOVER, never a stale renewal of a previous attempt.
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

    echo "::group::$label: raw dhclient output"
    cat "$work_dir/$state_subdir/dhclient.out" 2>/dev/null || echo "(no client output captured)"
    echo "::endgroup::"

    if [[ "$lease_obtained" -ne 1 ]]; then
        echo "::error::$label: dhclient never obtained a lease within ${lease_deadline}s." >&2
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
baseline_address="$(request_lease "baseline" "client-state-baseline")"
if [[ "$(address_in_range "$baseline_address" "$pool_start" "$pool_end")" != "yes" ]]; then
    echo "::error::Baseline address '$baseline_address' is not in the dynamic pool ($pool_start - $pool_end)." >&2
    exit 1
fi
echo "Baseline lease $baseline_address is a normal dynamic-pool address, as expected before any reservation exists."

echo "== UI: adding a real static DHCP reservation via POST /dhcp/static/add (kea_config_modify round trip) =="
add_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/add-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$test_mac' \
    --data-urlencode 'ip=$reserved_ip' \
    --data-urlencode 'hostname=$reserved_hostname' \
    'http://$ui_ip:8080/dhcp/static/add'")"
if [[ "$add_http_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/add returned HTTP $add_http_code, expected 303 (redirect to /dhcp)." >&2
    run_client "cat /shared/add-response" || true
    docker logs "$ui_container" >&2 || true
    exit 1
fi
echo "Admin UI accepted the reservation add (303 redirect) -- config-test/config-set/config-write all succeeded against real Kea."

echo "== Verifying the reservation is observable in a follow-up config-get against real Kea =="
reservation_present="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" --arg ip "$3" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase) and ."ip-address" == $ip)]
        | length > 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$test_mac" "$reserved_ip")"
if [[ "$reservation_present" != "yes" ]]; then
    echo "::error::Kea's own config-get does not show the reservation that was just added via the Admin UI." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation ($test_mac -> $reserved_ip) is present."

echo "== Requesting a SECOND lease for $test_mac: must now receive the reserved address =="
reserved_address="$(request_lease "post-add" "client-state-post-add")"
if [[ "$reserved_address" != "$reserved_ip" ]]; then
    echo "::error::After adding the reservation, dhclient received '$reserved_address', expected the reserved address $reserved_ip." >&2
    exit 1
fi
echo "Confirmed: a real, subsequent DHCP request for $test_mac now receives the reserved address $reserved_ip -- the mutation genuinely changed what Kea hands out, not just the config file."

echo "== UI: removing the reservation via POST /dhcp/static/remove =="
remove_http_code="$(run_client "curl -sS -b /shared/cookiejar -o /shared/remove-response -w '%{http_code}' \
    --data-urlencode 'csrf_token=$csrf_token' \
    --data-urlencode 'subnet_id=1' \
    --data-urlencode 'mac=$test_mac' \
    'http://$ui_ip:8080/dhcp/static/remove'")"
if [[ "$remove_http_code" != "303" ]]; then
    echo "::error::POST /dhcp/static/remove returned HTTP $remove_http_code, expected 303 (redirect to /dhcp)." >&2
    run_client "cat /shared/remove-response" || true
    docker logs "$ui_container" >&2 || true
    exit 1
fi
echo "Admin UI accepted the reservation removal (303 redirect)."

reservation_gone="$(docker exec "$kea_container" sh -c '
    curl -sf -u "admin:$1" -H "Content-Type: application/json" \
        -d "{\"command\":\"config-get\",\"service\":[\"dhcp4\"]}" \
        "http://127.0.0.1:8000/" \
    | jq -e --arg mac "$2" '"'"'
        [.[0].arguments.Dhcp4.subnet4[].reservations[]?
         | select((."hw-address"|ascii_downcase) == ($mac|ascii_downcase))]
        | length == 0
    '"'"' >/dev/null && echo yes || echo no
' -- "$kea_ctrl_token" "$test_mac")"
if [[ "$reservation_gone" != "yes" ]]; then
    echo "::error::Kea's own config-get still shows the reservation after removal via the Admin UI." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation for $test_mac is gone."

echo "== Requesting a THIRD lease for $test_mac: must be back in the dynamic pool =="
post_remove_address="$(request_lease "post-remove" "client-state-post-remove")"
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
