#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Tests real Discover/Offer/Request/Ack flow for Kea.
# Why: Verifies lease logic and Control Agent API behavior.
# From: Issue #448
set -euo pipefail

if ! repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); then
    echo "::error::Could not resolve the repository root directory from this script's own path." >&2
    exit 1
fi
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"
# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

client_tool_image="${DHCP_LEASE_FLOW_CLIENT_IMAGE:?DHCP_LEASE_FLOW_CLIENT_IMAGE is required (an image providing dhclient or udhcpc/busybox, e.g. the build-tools image)}"

# What: fails closed if PROJECT_CARGO_LTO/CODEGENUNIT unset.
# Why: services/dns/Dockerfile defines no in-file default.
# From: Issue #1095 | PR #1796
project_cargo_lto="${PROJECT_CARGO_LTO:?PROJECT_CARGO_LTO is required (no in-file/script default; Issue #1095, PR #1796 review 5109560874)}"
case "$project_cargo_lto" in off|thin|fat|true|false) ;; *) echo "PROJECT_CARGO_LTO must be one of: off, thin, fat, true, false (got '$project_cargo_lto')" >&2; exit 1;; esac
project_cargo_codegenunit="${PROJECT_CARGO_CODEGENUNIT:?PROJECT_CARGO_CODEGENUNIT is required (no in-file/script default; Issue #1095, PR #1796 review 5109560874)}"
case "$project_cargo_codegenunit" in ''|*[!0-9]*) echo "PROJECT_CARGO_CODEGENUNIT must be a positive integer (got '$project_cargo_codegenunit')" >&2; exit 1;; esac
[ "$project_cargo_codegenunit" -gt 0 ] || { echo "PROJECT_CARGO_CODEGENUNIT must be greater than zero" >&2; exit 1; }

work_dir="$repo_root/.dhcp-kea-lease-flow-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/client-state"

# What: Runtime-selects dhclient or udhcpc for DHCP.
# Why: Alpine lacks ISC dhclient; udhcpc needs -x hostname.
read -r -d '' dhcp_client_capture_script <<'CLIENT_SCRIPT' || true
set -u
if command -v dhclient >/dev/null 2>&1; then
    dhclient -4 -1 -v -d -sf /bin/true -pf /dhcp-test/dhclient.pid -lf /dhcp-test/dhclient.leases eth0 >/dhcp-test/dhclient.out 2>&1
elif command -v udhcpc >/dev/null 2>&1 || command -v busybox >/dev/null 2>&1; then
    cat > /tmp/udhcpc-lease-capture.sh <<'HOOK_SCRIPT'
#!/bin/sh
# See dhcp_client_capture_script's own comment in
# dhcp-kea-lease-flow-simulation.sh for why this hook exists and why it
# never mutates interface/route state: it contains no ip/ifconfig/route
# call at all, only ever appending option values to a file.
[ "$1" = "bound" ] || [ "$1" = "renew" ] || exit 0
csv() { printf '%s' "$1" | tr ' ' ','; }
{
    echo "lease {"
    [ -n "${ip:-}" ] && echo "  fixed-address ${ip};"
    [ -n "${router:-}" ] && echo "  option routers ${router};"
    [ -n "${serverid:-}" ] && echo "  option dhcp-server-identifier ${serverid};"
    [ -n "${dns:-}" ] && echo "  option domain-name-servers $(csv "${dns}");"
    [ -n "${ntpsrv:-}" ] && echo "  option ntp-servers $(csv "${ntpsrv}");"
    [ -n "${lease:-}" ] && echo "  option dhcp-lease-time ${lease};"
    [ -n "${domain:-}" ] && echo "  option domain-name \"${domain}\";"
    [ -n "${subnet:-}" ] && echo "  option subnet-mask ${subnet};"
    echo "}"
} >> /dhcp-test/dhclient.leases
HOOK_SCRIPT
    chmod +x /tmp/udhcpc-lease-capture.sh
    # Two separate command lines, not one built from a dynamically-quoted
    # variable: `udhcpc_bin="busybox udhcpc"` followed by `"$udhcpc_bin" ...`
    # would quote the whole two-word string into a single argv[0], which
    # exec(2) would then look for as one literal (and nonexistent) binary
    # named "busybox udhcpc" -- a real bug caught before this shipped, not
    # a hypothetical one; word-splitting an unquoted variable would dodge
    # it too, but at the cost of shellcheck's SC2086 flagging the very
    # thing this comment would then have to justify. Alpine's own busybox
    # package always symlinks each enabled applet (udhcpc included) to a
    # standalone binary, so the `command -v udhcpc` branch is what actually
    # runs on the alpine-final image this dispatch exists for; the bare
    # `busybox udhcpc` fallback below only matters for a hypothetical image
    # that ships busybox without that symlink.
    if command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i eth0 -s /tmp/udhcpc-lease-capture.sh -x hostname:"$(hostname)" -q -n -f >/dhcp-test/dhclient.out 2>&1
    else
        busybox udhcpc -i eth0 -s /tmp/udhcpc-lease-capture.sh -x hostname:"$(hostname)" -q -n -f >/dhcp-test/dhclient.out 2>&1
    fi
else
    echo "::error::Neither dhclient nor udhcpc/busybox is available in this image; cannot run a real DHCP client." >&2
    exit 1
fi
echo DONE >> /dhcp-test/dhclient.out
CLIENT_SCRIPT
readonly dhcp_client_capture_script

# What: Makes client-state directory world-writable.
# Why: dhclient drops privileges; needs write after drop.
# From: Issue #712
chmod 0777 "$work_dir/client-state"

# What: Sets test domain distinct from production "lan".
# Why: Assert detects if Kea applies configured value.
dhcp_test_domain="lancache-dhcp448-test.lan"

# What: Adds PID to Docker names for collision avoidance.
# Why: Shared runners run concurrent jobs with one daemon.
network_name="lancache-ng-dhcp448-$$"
kea_container="lancache-ng-dhcp448-kea-$$"
image_tag="lancache-ng-dhcp448-kea:$$"
# dns_container/dns_image_tag (issue #706): the real PowerDNS container the
# DDNS verification section further below builds and queries. Named
# alongside the Kea names above for the same collision-avoidance reason.
dns_container="lancache-ng-dhcp448-dns-$$"
dns_image_tag="lancache-ng-dhcp448-dns:$$"

# What: Generates random ephemeral test run credentials.
# Why: Kea and PowerDNS entrypoints reject default values.
# From: Issue #706
if ! kea_ctrl_token="$(openssl rand -hex 32)"; then
    echo "::error::Could not generate a random KEA_CTRL_TOKEN via openssl rand." >&2
    exit 1
fi
if ! ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"; then
    echo "::error::Could not generate a random DDNS_TSIG_KEY via openssl rand." >&2
    exit 1
fi
if ! pdns_api_key="$(openssl rand -hex 32)"; then
    echo "::error::Could not generate a random PDNS_API_KEY via openssl rand." >&2
    exit 1
fi

# What: Captures exit code before teardown alters it.
# Why: Cleanup must not mask the original result.
cleanup() {
    local status=$?
    docker rm -f "$kea_container" >/dev/null 2>&1 || true
    # What: Tears down PowerDNS container alongside Kea.
    # Why: Network can't be removed while attached.
    # From: Issue #706
    docker rm -f "${dns_container:-}" >/dev/null 2>&1 || true
    # What: Uses wait+retry for teardown, not blind rm.
    # Why: Daemon reports rm before unwiring endpoints.
    validation_network_teardown "$network_name" || true
    docker rmi "$image_tag" >/dev/null 2>&1 || true
    docker rmi "${dns_image_tag:-}" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    # What: Releases subnet-octet lock for concurrent reuse.
    # Why: Concurrent runs need collision-free subnets.
    # From: Issue #820
    validation_subnet_release "${subnet_lock_holder_pid:-}"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
docker build -q -t "$image_tag" --build-context "shared-scripts=$repo_root/scripts/lib" services/dhcp >/dev/null

# What: Uses flock+retry for dynamic subnet allocation.
# Why: Concurrent jobs collide; needs distributed lock.
# From: Issue #820
subnet_lock_root="/tmp/lancache-validation-locks-dhcp-kea"
subnet_max_attempts=10
subnet_run_id="${GITHUB_RUN_ID:-local}-$$-${RANDOM:-0}"
subnet_run_attempt="${GITHUB_RUN_ATTEMPT:-1}"

octet=""
subnet_lock_holder_pid=""
subnet_next_attempt=1
while [[ -z "$octet" && "$subnet_next_attempt" -le "$subnet_max_attempts" ]]; do
    reservation="$(validation_subnet_reserve "$subnet_lock_root" "$subnet_run_id" "$subnet_run_attempt" "$subnet_next_attempt" "$subnet_max_attempts")" || {
        echo "::error::Could not lock a free validation subnet octet after $subnet_max_attempts attempts." >&2
        exit 1
    }
    # What: Uses here-strings to avoid second writer.
    # Why: Consistent with pipefail; see issue #1377.
    if ! attempt="$(sed -n 's/^attempt=//p' <<<"$reservation")"; then
        echo "::error::Could not parse the 'attempt=' field out of validation_subnet_reserve's output." >&2
        exit 1
    fi
    if ! candidate_octet="$(sed -n 's/^octet=//p' <<<"$reservation")"; then
        echo "::error::Could not parse the 'octet=' field out of validation_subnet_reserve's output." >&2
        exit 1
    fi
    if ! candidate_pid="$(sed -n 's/^holder_pid=//p' <<<"$reservation")"; then
        echo "::error::Could not parse the 'holder_pid=' field out of validation_subnet_reserve's output." >&2
        exit 1
    fi

    candidate_subnet="172.31.${candidate_octet}.0/24"
    if ! conflict="$(validation_subnet_conflicts "$candidate_subnet")"; then
        echo "::error::Could not check candidate subnet $candidate_subnet for conflicts against existing Docker networks/host interfaces." >&2
        exit 1
    fi
    if [[ -n "$conflict" ]]; then
        echo "Octet $candidate_octet's subnet $candidate_subnet overlaps existing host/Docker state ($conflict); releasing and trying the next candidate."
        validation_subnet_release "$candidate_pid"
        subnet_next_attempt=$((attempt + 1))
        continue
    fi

    echo "== Creating isolated bridge network $network_name ($candidate_subnet, no host interface involved) (attempt $attempt) =="
    # What: --ip-range confines Docker IPAM to first half.
    # Why: Prevents DHCP pool overlap with container IPs.
    if create_output="$(docker network create \
        --driver bridge \
        --subnet "$candidate_subnet" \
        --gateway "172.31.${candidate_octet}.1" \
        --ip-range "172.31.${candidate_octet}.0/25" \
        "$network_name" 2>&1)"; then
        octet="$candidate_octet"
        subnet_lock_holder_pid="$candidate_pid"
        break
    fi

    echo "$create_output"
    validation_subnet_release "$candidate_pid"
    if ! validation_subnet_output_is_collision "$create_output"; then
        echo "::error::docker network create failed for a reason unrelated to a subnet collision; not retrying." >&2
        exit 1
    fi
    echo "docker network create failed with a network-overlap error on attempt $attempt, retrying with a different subnet."
    subnet_next_attempt=$((attempt + 1))
done

if [[ -z "$octet" ]]; then
    echo "::error::Could not reserve a free validation subnet and create the network after $subnet_max_attempts attempts." >&2
    exit 1
fi

# What: Computes /24 addresses after octet is locked in.
# Why: Addresses unknown until subnet allocation succeeds.
subnet="172.31.${octet}.0/24"
gateway="172.31.${octet}.1"
kea_ip="172.31.${octet}.2"
# What: Reserves PowerDNS IP outside DHCP pool.
# Why: Static address for DDNS server responses.
# From: Issue #706
pdns_ip="172.31.${octet}.3"
pool_start="172.31.${octet}.128"
pool_end="172.31.${octet}.200"
echo "Validation network is up on subnet $subnet (lock held by PID $subnet_lock_holder_pid)."

echo "== Building the PowerDNS image from this checkout's services/dns (issue #706) =="
# What: Pins DNS image build to resolved build-tools image.
# Why: Prevents silent divergence from :latest moving tag.
# From: PR #769
docker build -q -t "$dns_image_tag" --build-arg "BUILD_TOOLS_IMAGE=${client_tool_image}" \
    --build-arg "PROJECT_CARGO_LTO=${project_cargo_lto}" \
    --build-arg "PROJECT_CARGO_CODEGENUNIT=${project_cargo_codegenunit}" \
    --build-context "shared-scripts=$repo_root/scripts/lib" \
    -f services/dns/Dockerfile "$repo_root" >/dev/null

echo "== Starting a real PowerDNS container on the isolated network (issue #706) =="
# What: Configures PowerDNS with DDNS, TSIG, and proxy.
# Why: Tests real DDNS flow; production-like key exchange.
# From: Issue #706
docker run -d --name "$dns_container" \
    --network "$network_name" --ip "$pdns_ip" \
    -e PROXY_IP="203.0.113.1" \
    -e PDNS_API_KEY="$pdns_api_key" \
    -e DDNS_ALLOW_FROM="$kea_ip" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    "$dns_image_tag" >/dev/null

echo "== Waiting for PowerDNS to finish TSIG/zone setup and start serving (issue #706) =="
# What: Waits for both TSIG log and dig probe to succeed.
# Why: TSIG setup ≠ ready; both needed for confidence.
dns_ready_deadline=$((SECONDS + 60))
dns_ready=0
while (( SECONDS < dns_ready_deadline )); do
    # What: Stores logs to var, then greps locally.
    # Why: Avoids SIGPIPE when grep matches early.
    # From: Issue #1377 | PR #1374
    dns_log="$(docker logs "$dns_container" 2>&1 || true)"
    if grep -q "Configured TSIG-authenticated DDNS updates for LAN zones." <<<"$dns_log" \
        && docker exec "$dns_container" dig +short +time=2 +tries=1 @127.0.0.1 -p 5300 lan. SOA >/dev/null 2>&1; then
        dns_ready=1
        break
    fi
    sleep 2
done
if [[ "$dns_ready" -ne 1 ]]; then
    echo "::error::PowerDNS container never finished TSIG/zone setup and became ready." >&2
    docker logs "$dns_container" >&2 || true
    exit 1
fi
echo "PowerDNS authoritative is up and TSIG-authenticated DDNS updates are configured for zone lan. (source: $kea_ip)."

echo "== Creating this run's forward test zone in PowerDNS (issue #706) =="
# What: Creates test zone for kea-dhcp-ddns.
# Why: Prod zones exist; test needs bootstrap.
# From: Issue #706
docker exec "$dns_container" pdnsutil --config-dir=/etc/pdns/auth create-zone "${dhcp_test_domain}." >/dev/null
docker exec "$dns_container" pdnsutil --config-dir=/etc/pdns/auth set-meta "${dhcp_test_domain}." TSIG-ALLOW-DNSUPDATE lancache-ddns-key >/dev/null
# What: Runs pdns_control rediscover after zone creation.
# Why: Reload clears cache; avoids stale race.
# From: Issue #706
docker exec "$dns_container" pdns_control rediscover >/dev/null

echo "== Starting a real Kea container on the isolated network =="
# What: Adds NET_ADMIN cap; sets DHCP_DDNS_ENABLED=true.
# Why: NET_ADMIN for iptables; verify DDNS works.
docker run -d --name "$kea_container" \
    --network "$network_name" --ip "$kea_ip" \
    --cap-add NET_ADMIN \
    -e DHCP_SUBNET="$subnet" \
    -e DHCP_RANGE_START="$pool_start" \
    -e DHCP_RANGE_END="$pool_end" \
    -e DHCP_GATEWAY="$gateway" \
    -e DHCP_DOMAIN="$dhcp_test_domain" \
    -e DHCP_LEASE_TIME=3600 \
    -e DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1" \
    -e DHCP_DNS_PRIMARY="$kea_ip" \
    -e DHCP_DNS_SECONDARY="$kea_ip" \
    -e KEA_CTRL_TOKEN="$kea_ctrl_token" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    -e DHCP_DNS_SERVER_IP="$pdns_ip" \
    -e DHCP_DDNS_ENABLED=true \
    "$image_tag" >/dev/null

echo "== Waiting for the Kea Control Agent API to answer =="
# What: Polls config-get as readiness probe for Kea API.
# Why: Read-only; no side effects; safe to poll repeatedly.
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
echo "Kea DHCPv4 server is up (Subnet: $subnet, Pool: $pool_start - $pool_end)."

echo "== Running a real DHCP client (dhclient or udhcpc, whichever \$client_tool_image provides) against Kea: Discover/Offer/Request/Ack =="
# What: Runs real DHCP client; polls for lease.
# Why: Neither dhclient nor udhcpc reliably exits.
client_container="lancache-ng-dhcp448-client-${octet}-$$"

# What: Uses default -cf; adds NET_RAW/NET_ADMIN for DHCP.
# Why: Default sends hostname; raw socket and ARP need caps.
# From: Issue #706
docker run -d --name "$client_container" \
    --network "$network_name" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$work_dir/client-state:/dhcp-test" \
    "$client_tool_image" \
    bash -c "$dhcp_client_capture_script" \
    >/dev/null

# What: Stores timeout apart from deadline.
# Why: Error message reports actual wait time.
lease_timeout_seconds=30
lease_deadline=$((SECONDS + lease_timeout_seconds))
lease_obtained=0
while (( SECONDS < lease_deadline )); do
    # What: Checks -s (exists) and } (complete).
    # Why: File exists before write ends; } atomic.
    if [[ -s "$work_dir/client-state/dhclient.leases" ]] && grep -q '^}' "$work_dir/client-state/dhclient.leases" 2>/dev/null; then
        lease_obtained=1
        break
    fi
    sleep 1
done

docker rm -f "$client_container" >/dev/null 2>&1 || true

echo "::group::Raw DHCP client output"
cat "$work_dir/client-state/dhclient.out" 2>/dev/null || echo "(no client output captured)"
echo "::endgroup::"

if [[ "$lease_obtained" -ne 1 ]]; then
    echo "::error::The DHCP client never obtained a lease from the Kea container within ${lease_timeout_seconds}s." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi

parsed="$(dhcp_lease_parse_latest "$work_dir/client-state/dhclient.leases")" || {
    echo "::error::A lease file was written but could not be parsed." >&2
    exit 1
}

offered_address="$(dhcp_lease_field "$parsed" address || true)"
server_identifier="$(dhcp_lease_field "$parsed" server_identifier || true)"
router="$(dhcp_lease_field "$parsed" router || true)"
dns_servers="$(dhcp_lease_field "$parsed" dns_servers || true)"
ntp_servers="$(dhcp_lease_field "$parsed" ntp_servers || true)"
lease_time="$(dhcp_lease_field "$parsed" lease_time || true)"
domain_name="$(dhcp_lease_field "$parsed" domain_name || true)"

echo "== Verifying the granted lease matches the configured Kea subnet =="

# What: Uses Python for IPv4 range check.
# Why: Readable; avoids hand-rolled math.
if ! address_in_pool="$(python3 - "$offered_address" "$pool_start" "$pool_end" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
)"; then
    echo "::error::Could not check whether offered address $offered_address falls inside the configured pool ($pool_start - $pool_end) (python3 invocation failed)." >&2
    exit 1
fi

fail=0
if [[ "$address_in_pool" != "yes" ]]; then
    echo "::error::Offered address $offered_address is outside the configured pool ($pool_start - $pool_end)." >&2
    fail=1
fi
if [[ "$server_identifier" != "$kea_ip" ]]; then
    echo "::error::Server identifier '$server_identifier' does not match the Kea container's own IP ($kea_ip)." >&2
    fail=1
fi
if [[ "$router" != "$gateway" ]]; then
    echo "::error::Router option '$router' does not match the configured gateway ($gateway)." >&2
    fail=1
fi
if [[ "$dns_servers" != "$kea_ip,$kea_ip" ]]; then
    echo "::error::DNS servers option '$dns_servers' does not match the configured DHCP_DNS_PRIMARY/SECONDARY ($kea_ip,$kea_ip)." >&2
    fail=1
fi
if [[ "$ntp_servers" != "8.8.8.8,1.1.1.1" ]]; then
    echo "::error::NTP servers option '$ntp_servers' does not match the configured DHCP_NTP_SERVERS (8.8.8.8,1.1.1.1)." >&2
    fail=1
fi
if [[ "$lease_time" != "3600" ]]; then
    echo "::error::Lease time option '$lease_time' does not match the configured DHCP_LEASE_TIME (3600)." >&2
    fail=1
fi
if [[ "$domain_name" != "$dhcp_test_domain" ]]; then
    echo "::error::Domain name option '$domain_name' does not match the configured DHCP_DOMAIN ($dhcp_test_domain)." >&2
    fail=1
fi

echo "== Verifying Kea's DDNS update produced a matching PowerDNS A record (issue #706) =="

# assert_ddns_record_matches_lease <fqdn> <expected_ip>
# What: Polls PowerDNS for A record matching leased IP.
# Why: DDNS is async; record not guaranteed immediate.
assert_ddns_record_matches_lease() {
    local fqdn="$1" expected_ip="$2" resolved_ip=""
    local ddns_deadline=$((SECONDS + 30))
    while (( SECONDS < ddns_deadline )); do
        # What: Ignores dig failure; retries on empty.
        # Why: Transient failures normal in polling; safe.
        resolved_ip="$(docker exec "$dns_container" dig +short +time=2 +tries=1 @127.0.0.1 -p 5300 "$fqdn" A 2>/dev/null | tail -n1)"
        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo "DDNS verification passed: PowerDNS authoritative has an A record for $fqdn -> $resolved_ip, matching the lease Kea just granted."
            return 0
        fi
        sleep 2
    done
    echo "::error::PowerDNS authoritative never produced an A record for '$fqdn' matching the leased address ($expected_ip); last resolved value: '${resolved_ip:-<none>}'." >&2
    echo "::group::kea-dhcp-ddns / PowerDNS container logs" >&2
    docker logs "$kea_container" >&2 2>&1 || true
    docker logs "$dns_container" >&2 2>&1 || true
    echo "::endgroup::" >&2
    return 1
}

# What: Kea generates FQDN as dhcp-<dashed-ip>.<domain>.
# Why: "when-present" means REPLACE client name, not use it.
ddns_expected_fqdn="dhcp-${offered_address//./-}.${domain_name}."
ddns_status="FAILED (see ::error above)"
if assert_ddns_record_matches_lease "$ddns_expected_fqdn" "$offered_address"; then
    ddns_status="verified: ${ddns_expected_fqdn} -> ${offered_address} (TSIG-signed nsupdate from kea-dhcp-ddns)"
else
    fail=1
fi

echo "== Verifying Kea's DDNS update produced a matching PowerDNS PTR record (issue #768) =="

# assert_ptr_record_matches_lease <ip> <expected_fqdn>
# What: Polls PowerDNS for PTR record matching FQDN.
# Why: DDNS is async; PTR not guaranteed after A record.
assert_ptr_record_matches_lease() {
    local ip="$1" expected_fqdn="$2" resolved_fqdn=""
    local ptr_deadline=$((SECONDS + 30))
    while (( SECONDS < ptr_deadline )); do
        # What: Ignores dig failure; retries on empty.
        # Why: Transient failures normal in polling; safe.
        resolved_fqdn="$(docker exec "$dns_container" dig +short +time=2 +tries=1 @127.0.0.1 -p 5300 -x "$ip" 2>/dev/null | tail -n1)"
        if [[ "$resolved_fqdn" == "$expected_fqdn" ]]; then
            echo "Reverse DDNS verification passed: PowerDNS authoritative has a PTR record for $ip -> $resolved_fqdn, matching the lease Kea just granted."
            return 0
        fi
        sleep 2
    done
    echo "::error::PowerDNS authoritative never produced a PTR record for '$ip' matching the leased hostname ($expected_fqdn); last resolved value: '${resolved_fqdn:-<none>}'." >&2
    echo "::group::kea-dhcp-ddns / PowerDNS container logs" >&2
    docker logs "$kea_container" >&2 2>&1 || true
    docker logs "$dns_container" >&2 2>&1 || true
    echo "::endgroup::" >&2
    return 1
}

# What: PTR points to same FQDN as A record.
# Why: Forward/reverse from lease event.
ptr_status="FAILED (see ::error above)"
if assert_ptr_record_matches_lease "$offered_address" "$ddns_expected_fqdn"; then
    ptr_status="verified: ${offered_address} -> ${ddns_expected_fqdn} (TSIG-signed nsupdate from kea-dhcp-ddns)"
else
    fail=1
fi

# ─── Static host reservation scenario (issue #707) ───
#
# What: Uses fixed locally-admin MACs.
# Why: PID-suffixed to avoid collisions.
if ! reserved_mac="$(printf '02:07:07:aa:bb:%02x' "$(( $$ % 256 ))")"; then
    echo "::error::Could not format the reserved test MAC address." >&2
    exit 1
fi
if ! other_mac="$(printf '02:07:07:cc:dd:%02x' "$(( $$ % 256 ))")"; then
    echo "::error::Could not format the unrelated test MAC address." >&2
    exit 1
fi
# What: Reserved IP outside dynamic pool and Docker range.
# Why: Static reservation needs unused address.
reserved_ip="172.31.${octet}.210"

# kea_ctrl_command <json_command_body>
# What: POSTs JSON to Control Agent; prints response.
# Why: Transport primitive; avoids quoting tangles.
kea_ctrl_command() {
    docker exec -i "$kea_container" sh -c '
        curl -sf -u "admin:$1" -H "Content-Type: application/json" -d @- "http://127.0.0.1:8000/"
    ' -- "$kea_ctrl_token" <<<"$1"
}

# kea_ctrl_result_ok <response_json>
# What: Returns 0 if response result field is 0 (success).
# Why: Standard Kea Control Agent convention.
kea_ctrl_result_ok() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if d and d[0].get("result") == 0 else 1)
' "$1"
}

# What: Adds reservation via Control Agent API.
# Why: Same as Admin UI; tests Kea API directly.
# From: Issue #693
kea_ctrl_add_reservation() {
    local mac="$1" ip="$2" get_resp modified_args resp

    get_resp="$(kea_ctrl_command '{"command":"config-get","service":["dhcp4"]}')"
    if ! kea_ctrl_result_ok "$get_resp"; then
        echo "config-get failed: $get_resp" >&2
        return 1
    fi

    modified_args="$(GET_RESP="$get_resp" python3 - "$mac" "$ip" <<'PYEOF'
import json, os, sys
mac, ip = sys.argv[1], sys.argv[2]
resp = json.loads(os.environ["GET_RESP"])
args = resp[0]["arguments"]
args.pop("hash", None)  # see kea_ctrl_add_reservation's own comment above
for subnet in args["Dhcp4"]["subnet4"]:
    if subnet.get("id") == 1:
        subnet.setdefault("reservations", []).append({"hw-address": mac, "ip-address": ip})
print(json.dumps(args))
PYEOF
    )"

    for cmd in config-test config-set; do
        resp="$(kea_ctrl_command "{\"command\":\"$cmd\",\"service\":[\"dhcp4\"],\"arguments\":${modified_args}}")"
        if ! kea_ctrl_result_ok "$resp"; then
            echo "$cmd failed: $resp" >&2
            return 1
        fi
    done

    resp="$(kea_ctrl_command '{"command":"config-write","service":["dhcp4"]}')"
    if ! kea_ctrl_result_ok "$resp"; then
        echo "config-write failed: $resp" >&2
        return 1
    fi
}

# What: Prints yes/no for reservation status.
# Why: Verifies reservation persisted.
# From: Issue #634
kea_ctrl_reservation_present() {
    local mac="$1" ip="$2" get_resp
    get_resp="$(kea_ctrl_command '{"command":"config-get","service":["dhcp4"]}')"
    MAC="$mac" IP="$ip" python3 -c '
import json, os, sys
resp = json.loads(sys.argv[1])
mac, ip = os.environ["MAC"].lower(), os.environ["IP"]
subnets = resp[0]["arguments"]["Dhcp4"]["subnet4"]
found = any(
    r.get("hw-address", "").lower() == mac and r.get("ip-address") == ip
    for s in subnets
    for r in s.get("reservations", [])
)
print("yes" if found else "no")
' "$get_resp"
}

# What: Runs DHCP client; returns offered IP.
# Why: Tests if Kea honors reservation.
assert_static_reservation_honored() {
    local label="$1" mac="$2" state_subdir="$3" client_container
    client_container="lancache-ng-dhcp448-client-${state_subdir}-${octet}-$$"
    mkdir -p "$work_dir/$state_subdir"
    chmod 0777 "$work_dir/$state_subdir"

    docker run -d --name "$client_container" \
        --network "$network_name" --mac-address "$mac" \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        -v "$work_dir/$state_subdir:/dhcp-test" \
        "$client_tool_image" \
        bash -c "$dhcp_client_capture_script" \
        >/dev/null

    local deadline=$((SECONDS + 30)) obtained=0
    while (( SECONDS < deadline )); do
        if [[ -s "$work_dir/$state_subdir/dhclient.leases" ]] && grep -q '^}' "$work_dir/$state_subdir/dhclient.leases" 2>/dev/null; then
            obtained=1
            break
        fi
        sleep 1
    done
    docker rm -f "$client_container" >/dev/null 2>&1 || true

    # What: Diagnostics to stderr via block redirect.
    # Why: stdout captured for offered address.
    {
        echo "::group::$label: raw DHCP client output"
        cat "$work_dir/$state_subdir/dhclient.out" 2>/dev/null || echo "(no client output captured)"
        echo "::endgroup::"
    } >&2

    if [[ "$obtained" -ne 1 ]]; then
        echo "::error::$label: the DHCP client never obtained a lease for $mac within 30s." >&2
        return 1
    fi

    local parsed
    parsed="$(dhcp_lease_parse_latest "$work_dir/$state_subdir/dhclient.leases")" || {
        echo "::error::$label: a lease file was written but could not be parsed." >&2
        return 1
    }
    dhcp_lease_field "$parsed" address || true
}

echo "== Adding a real static host reservation ($reserved_mac -> $reserved_ip) via Kea's Control Agent API =="
if ! kea_ctrl_add_reservation "$reserved_mac" "$reserved_ip"; then
    echo "::error::Failed to add the static reservation directly through Kea's Control Agent API." >&2
    docker logs "$kea_container" >&2 || true
    exit 1
fi

if ! reservation_present="$(kea_ctrl_reservation_present "$reserved_mac" "$reserved_ip")"; then
    echo "::error::Could not query Kea's own config-get to confirm the static reservation ($reserved_mac -> $reserved_ip) is present." >&2
    exit 1
fi
if [[ "$reservation_present" != "yes" ]]; then
    echo "::error::Kea's own config-get does not show the reservation that was just added ($reserved_mac -> $reserved_ip)." >&2
    exit 1
fi
echo "Kea's live config-get confirms the reservation ($reserved_mac -> $reserved_ip) is present."

echo "== Positive case: requesting a lease for the reserved MAC -- must receive the reserved address =="
reserved_offered="$(assert_static_reservation_honored "reserved-mac" "$reserved_mac" "client-state-reserved")" || {
    docker logs "$kea_container" >&2 || true
    exit 1
}
reservation_honored=0
if [[ "$reserved_offered" == "$reserved_ip" ]]; then
    reservation_honored=1
    echo "Confirmed: a real DHCP request for the reserved MAC $reserved_mac received the reserved address $reserved_ip."
else
    echo "::error::Reserved MAC $reserved_mac received '${reserved_offered:-<none>}', expected the reserved address $reserved_ip." >&2
    fail=1
fi

echo "== Negative case: requesting a lease for an unrelated MAC -- must NOT receive the reserved address =="
other_offered="$(assert_static_reservation_honored "other-mac" "$other_mac" "client-state-other")" || {
    docker logs "$kea_container" >&2 || true
    exit 1
}
if ! other_in_pool="$(python3 - "$other_offered" "$pool_start" "$pool_end" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
)"; then
    echo "::error::Could not check whether the unrelated MAC's offered address $other_offered falls inside the dynamic pool ($pool_start - $pool_end) (python3 invocation failed)." >&2
    exit 1
fi
reservation_isolated=0
if [[ "$other_offered" != "$reserved_ip" && "$other_in_pool" == "yes" ]]; then
    reservation_isolated=1
    echo "Confirmed: a real DHCP request for the unrelated MAC $other_mac received an ordinary dynamic-pool address ($other_offered), not the reservation."
elif [[ "$other_offered" == "$reserved_ip" ]]; then
    echo "::error::Unrelated MAC $other_mac was also handed the reserved address $reserved_ip -- the reservation leaked to a client it does not belong to." >&2
    fail=1
else
    echo "::error::Unrelated MAC $other_mac received '${other_offered:-<none>}', which is outside the dynamic pool ($pool_start - $pool_end)." >&2
    fail=1
fi

report=$(cat <<REPORT
== DHCP Kea lease-flow result (issue #448) ==
Offered address:      ${offered_address:-<none>}
Server identifier:    ${server_identifier:-<none>}
Router:               ${router:-<none>}
DNS servers:          ${dns_servers:-<none>}
NTP servers:          ${ntp_servers:-<none>}
Lease time (s):       ${lease_time:-<none>}
Domain name:          ${domain_name:-<none>}
DDNS A record:        ${ddns_status}
DDNS PTR record:      ${ptr_status}

== Static host reservation result (issue #707) ==
Reserved MAC:          ${reserved_mac} -> ${reserved_ip}
Reserved-MAC lease:    ${reserved_offered:-<none>} $( [[ "$reservation_honored" -eq 1 ]] && echo "(reserved address received -- honored)" || echo "(MISMATCH)" )
Unrelated MAC:         ${other_mac}
Unrelated-MAC lease:   ${other_offered:-<none>} $( [[ "$reservation_isolated" -eq 1 ]] && echo "(ordinary pool address -- reservation did not leak)" || echo "(MISMATCH)" )

Verified: a real Discover/Offer/Request/Ack flow completed against our own
Kea service on an isolated Docker bridge network, and the address/server-
identifier/router/DNS/NTP/lease-time/domain-name options above matched what
this run configured Kea with. Also verified: a static host reservation added
directly through Kea's own Control Agent API (the same config-get/
config-test/config-set/config-write sequence the Admin UI's
kea_config_modify() drives) was honored by a real, subsequent DHCP lease
request for the reserved MAC, and a second, unrelated MAC still received an
ordinary dynamic-pool address rather than the reservation. Also verified:
the granted lease produced a matching PowerDNS A record via a real
TSIG-authenticated DDNS update from kea-dhcp-ddns to a real PowerDNS
authoritative server, using this project's real DDNS transport/config
wiring (see the header comment above for the one test-only zone-bootstrap
shim this run needed and why). Also verified (issue #768): the same lease
produced a matching PowerDNS PTR record, proving Kea's reverse-ddns fix
(one ddns-domains entry per real private reverse zone, instead of the old
non-existent "in-addr.arpa." catch-all) actually resolves against a real
PowerDNS instance -- no test-only zone-bootstrap shim needed for this half,
since this script's subnet always falls inside a zone
services/dns/entrypoint.sh creates unconditionally.

NOT verified by this script (see header comment / docs/dhcp-modes.md):
the dnsmasq-proxy DHCP mode (out of scope here).
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

if [[ "$fail" -ne 0 ]]; then
    echo "::error::dhcp-kea-lease-flow-simulation FAILED: one or more offered options or the static reservation scenario did not match expectations." >&2
    exit 1
fi

echo "dhcp-kea-lease-flow-simulation passed: real lease flow, static reservation (positive case), and reservation isolation (negative case) all completed and matched expectations."
