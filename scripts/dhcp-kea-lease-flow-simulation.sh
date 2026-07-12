#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DHCP behavior test for our own Kea service (issue #448) -- distinct
# from services/ui/dhcp-probe.sh's existing #377 conflict-discovery check.
# dhcp-probe.sh answers "does any DHCP server answer on the LAN segment,
# and does a host-interface dry-run also succeed" and is intentionally left
# unchanged by this script. This script answers a different question: does
# OUR Kea service, when driven by a completely real DHCP client, actually
# complete Discover/Offer/Request/Ack and hand out the address range,
# router, DNS, NTP, and lease-time options the operator configured?
#
# Safety model (see the issue's acceptance criteria: "must not modify the
# host's active network configuration" by default):
#   - Both the Kea server and the DHCP client run as ordinary Docker
#     containers on a throwaway bridge network created and destroyed by
#     this script. Every container already gets its own network namespace
#     from Docker, and this network is never bridged to any host interface
#     or attached to the runner's real LAN -- it is exactly the "isolated
#     network namespace ... or veth pair" approach the issue asks for, not
#     a stretch reading of it.
#   - The client's own veth/eth0 is left exactly as Docker's IPAM
#     configured it: dhclient runs with `-sf /bin/true` (a no-op "apply
#     the lease" script), the same technique services/ui/dhcp-probe.sh
#     already relies on -- a real lease is negotiated over the wire, but
#     nothing ever calls `ip addr add`/`ip route` to actually apply it.
#   - Docker's own container-address allocation is confined to a small
#     sub-range (see --ip-range below) that never overlaps the Kea pool,
#     so there is no possibility of the test's own plumbing colliding with
#     the addresses under test.
#   - This script has no invasive/host-interface mode at all -- there was
#     nothing to gate behind an opt-in flag. It only ever runs via
#     workflow_dispatch (full-setup-validate.yml), never on every PR.
#
# What this script does NOT verify (documented per the issue's "must
# document what is verified and what is not verified" criterion):
#   - DHCP-DDNS lease-event follow-through (a real PowerDNS TSIG update
#     firing from the granted lease) -- Refs #557, which scopes that
#     specifically as part of its own DHCP Kea end-to-end scenario.
#   - Static host reservations (a known MAC receiving its reserved,
#     out-of-pool address) -- also Refs #557 for the same reason.
#   - The dnsmasq-proxy DHCP mode (services/dhcp-proxy) -- entirely
#     different code path, out of scope for this script.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

client_tool_image="${DHCP_LEASE_FLOW_CLIENT_IMAGE:?DHCP_LEASE_FLOW_CLIENT_IMAGE is required (an image providing dhclient, e.g. the build-tools image)}"

work_dir="$repo_root/.dhcp-kea-lease-flow-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir/client-state"

# ISC dhclient (4.4.x, the Debian isc-dhcp-client package) binds the raw DHCP
# socket as root, then permanently drops privileges to an unprivileged,
# package-hardcoded system account before opening this script's own -pf/-lf
# paths or exec'ing the -sf lease-apply script below. dhclient.out keeps
# being written fine regardless (its fd was already open, inherited from
# this script's own shell redirect, before that privilege drop happens --
# writing through an already-open fd needs no further permission check), but
# any *new* file dhclient itself tries to create afterward in
# client-state/ gets EACCES from that unprivileged identity. Confirmed
# directly (issue #712): a real run showed "can't create
# .../dhclient.leases: Permission denied" and "Can't create
# .../dhclient.pid: Permission denied" interleaved with a fully successful
# DHCPACK/bound-to exchange -- the lease negotiation itself was never the
# problem, dhclient just couldn't persist it to disk. Making this directory
# world-writable is safe here: it is a throwaway, per-run temp directory
# scoped to this one script invocation, not a shared or security-sensitive
# path, and this is what lets dhclient's post-privilege-drop identity
# actually write the lease file the rest of this script depends on.
chmod 0777 "$work_dir/client-state"

# A fixed subnet would collide across concurrent runs sharing one of this
# project's self-hosted runner hosts, exactly like the full-setup validation
# network did before #623's per-run derivation. Mirror that fix here: derive
# the third octet of a dedicated 172.31.0.0/16 range (unused by
# deploy/dev's 172.28.0.0/16 and full-setup-validate's 172.30.0.0/16) from
# this run's own identity, with a random fallback so an operator can still
# run this script directly (not just via GitHub Actions).
run_identity="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$}-${RANDOM:-0}"
digest="$(printf '%s' "$run_identity" | sha256sum | cut -c1-8)"
octet=$(( (16#$digest % 252) + 2 )) # 2..253
subnet="172.31.${octet}.0/24"
gateway="172.31.${octet}.1"
kea_ip="172.31.${octet}.2"
pool_start="172.31.${octet}.128"
pool_end="172.31.${octet}.200"

# $work_dir above needs no per-run uniqueness of its own: $repo_root is
# already GitHub Actions' own per-run workspace checkout (or, run locally,
# just this one operator's own checkout), so a fixed subdirectory name under
# it can never collide with another run. Docker objects are different: the
# daemon on a shared self-hosted runner host is one process serving every
# concurrent workflow run and every operator's local invocation, so object
# *names* need their own collision avoidance independent of the subnet. The
# octet alone is not enough for that (only 252 buckets, so two concurrent
# runs can still land on the same octet); appending this shell's own PID
# ($$) is what actually guarantees the docker network/container/image names
# themselves never collide, even when the subnet-derived octet does.
network_name="lancache-ng-dhcp448-${octet}-$$"
kea_container="lancache-ng-dhcp448-kea-${octet}-$$"
image_tag="lancache-ng-dhcp448-kea:${octet}-$$"

# services/dhcp/entrypoint.sh refuses to start Kea at all if KEA_CTRL_TOKEN
# or DDNS_TSIG_KEY is empty or one of its known placeholder defaults (it
# exists to catch a real deployment left on a default secret). This is a
# disposable, per-run test instance torn down at the end of this script, so
# there is no need to persist these values anywhere -- generating a fresh
# random one each run only has to satisfy that startup check and match what
# this script itself sends back to the Control Agent API below.
kea_ctrl_token="$(openssl rand -hex 32)"
ddns_tsig_key="$(openssl rand -base64 32 | tr -d '\n')"

# `local status=$?` captures the script's real exit code before any cleanup
# command below can overwrite $? with its own (success or failure), so
# `exit "$status"` at the end still reports the original pass/fail result to
# the caller (e.g. GitHub Actions) instead of whatever the last cleanup
# command happened to return. The three docker teardown commands are also
# ordered deliberately, not just alphabetically: the network can't be
# removed while $kea_container is still attached to it, and the image can't
# be removed while $kea_container still exists and references it -- doing
# it in the reverse order would leave a dangling network or image behind on
# every run. Each is still `|| true` regardless, so a problem tearing down
# one of them never masks the script's real result or skips the others.
cleanup() {
    local status=$?
    docker rm -f "$kea_container" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$image_tag" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the Kea DHCP image from this checkout's services/dhcp =="
docker build -q -t "$image_tag" services/dhcp >/dev/null

echo "== Creating isolated bridge network $network_name ($subnet, no host interface involved) =="
# --ip-range confines Docker's OWN container-address bookkeeping to the
# first half of the subnet, so it can never overlap the Kea pool
# ($pool_start-$pool_end) that this script is actually testing.
docker network create \
    --driver bridge \
    --subnet "$subnet" \
    --gateway "$gateway" \
    --ip-range "172.31.${octet}.0/25" \
    "$network_name" >/dev/null

echo "== Starting a real Kea container on the isolated network =="
# --cap-add NET_ADMIN: services/dhcp/entrypoint.sh runs iptables on every
# start to restrict the Control Agent API to Docker-internal networks (see
# that file's own comment). Without NET_ADMIN those iptables calls fail and
# the entrypoint would not behave the same way it does in a real deployment.
docker run -d --name "$kea_container" \
    --network "$network_name" --ip "$kea_ip" \
    --cap-add NET_ADMIN \
    -e DHCP_SUBNET="$subnet" \
    -e DHCP_RANGE_START="$pool_start" \
    -e DHCP_RANGE_END="$pool_end" \
    -e DHCP_GATEWAY="$gateway" \
    -e DHCP_DOMAIN="lancache-dhcp448-test.lan" \
    -e DHCP_LEASE_TIME=3600 \
    -e DHCP_NTP_SERVERS="8.8.8.8 1.1.1.1" \
    -e DHCP_DNS_PRIMARY="$kea_ip" \
    -e DHCP_DNS_SECONDARY="$kea_ip" \
    -e KEA_CTRL_TOKEN="$kea_ctrl_token" \
    -e DDNS_TSIG_KEY="$ddns_tsig_key" \
    -e DHCP_DNS_SERVER_IP="$kea_ip" \
    "$image_tag" >/dev/null

echo "== Waiting for the Kea Control Agent API to answer =="
# config-get is used purely as the readiness probe because it is a
# read-only Kea command: it cannot change anything Kea already loaded from
# its own config file, so polling it repeatedly here has no side effects on
# the DHCPv4 configuration this script later relies on being untouched.
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

echo "== Running a real DHCP client (dhclient) against Kea: Discover/Offer/Request/Ack =="
# -sf /bin/true: negotiate a real lease over the wire but never apply it to
# this container's own interface (see the safety-model comment above).
# dhclient does not reliably exit on its own after -1 on every distro build
# once bound (confirmed directly during development of this script) so this
# polls for the lease file instead of trusting dhclient's own exit code, and
# force-kills it once a lease has actually been written.
client_container="lancache-ng-dhcp448-client-${octet}-$$"
# NET_RAW: before a lease is granted this container has no IP of its own,
# so dhclient must send/receive DHCP over a raw broadcast socket rather than
# a normal bound UDP socket -- that needs CAP_NET_RAW regardless of -sf's
# no-op lease-apply step. NET_ADMIN is added alongside it because dhclient
# also touches interface-level state (e.g. ARP) while negotiating, before
# it ever gets to the point of calling -sf.
docker run -d --name "$client_container" \
    --network "$network_name" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$work_dir/client-state:/dhcp-test" \
    "$client_tool_image" \
    bash -c 'dhclient -4 -1 -v -d -sf /bin/true -pf /dhcp-test/dhclient.pid -lf /dhcp-test/dhclient.leases eth0 >/dhcp-test/dhclient.out 2>&1; echo DONE >> /dhcp-test/dhclient.out' \
    >/dev/null

# lease_timeout_seconds is kept separate from lease_deadline (an absolute
# SECONDS-based cutoff) so the error message below can report the actual
# wait duration instead of a shifting absolute value -- $lease_deadline
# itself is meaningless to a reader, since $SECONDS keeps advancing for the
# rest of the script's own runtime.
lease_timeout_seconds=30
lease_deadline=$((SECONDS + lease_timeout_seconds))
lease_obtained=0
while (( SECONDS < lease_deadline )); do
    # `-s` alone is not enough: the lease file appears the moment dhclient
    # starts writing it, well before the record is complete. The trailing
    # `^}` (a closing brace at column 0) is what ISC dhclient writes only
    # once a lease record is fully committed to the file, so checking for it
    # is what actually distinguishes "lease negotiation still in progress,
    # file exists but is partially written" from "lease obtained and safe to
    # parse" -- reading the file one poll iteration too early would hand
    # dhcp_lease_parse_latest below a truncated record.
    if [[ -s "$work_dir/client-state/dhclient.leases" ]] && grep -q '^}' "$work_dir/client-state/dhclient.leases" 2>/dev/null; then
        lease_obtained=1
        break
    fi
    sleep 1
done

docker rm -f "$client_container" >/dev/null 2>&1 || true

echo "::group::Raw dhclient output"
cat "$work_dir/client-state/dhclient.out" 2>/dev/null || echo "(no client output captured)"
echo "::endgroup::"

if [[ "$lease_obtained" -ne 1 ]]; then
    echo "::error::dhclient never obtained a lease from the Kea container within ${lease_timeout_seconds}s." >&2
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

# Address-in-pool check done in Python (not bash arithmetic) for the same
# reason build-push.yml's own subnet-collision check uses it: correct,
# readable IPv4 range comparison without hand-rolled octet math.
address_in_pool="$(python3 - "$offered_address" "$pool_start" "$pool_end" <<'PYEOF'
import ipaddress, sys
addr, start, end = (ipaddress.ip_address(a) for a in sys.argv[1:4])
print("yes" if start <= addr <= end else "no")
PYEOF
)"

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
if [[ "$domain_name" != "lancache-dhcp448-test.lan" ]]; then
    echo "::error::Domain name option '$domain_name' does not match the configured DHCP_DOMAIN (lancache-dhcp448-test.lan)." >&2
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

Verified: a real Discover/Offer/Request/Ack flow completed against our own
Kea service on an isolated Docker bridge network, and the address/server-
identifier/router/DNS/NTP/lease-time/domain-name options above matched what
this run configured Kea with.

NOT verified by this script (see header comment / docs/dhcp-modes.md):
static host reservations and DHCP-DDNS lease-event follow-through (Refs
#557), and the dnsmasq-proxy DHCP mode (out of scope here).
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
    echo "::error::dhcp-kea-lease-flow-simulation FAILED: one or more offered options did not match configuration." >&2
    exit 1
fi

echo "dhcp-kea-lease-flow-simulation passed: real lease flow completed and all reported options matched configuration."
