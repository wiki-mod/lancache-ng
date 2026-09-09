#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Test dhcp-proxy DHCP-RELAY mode.
# Why: Proof relay forwards across segments.
# From: Issue #844
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

client_net="lancache-ng-relay-client-$$"
server_net="lancache-ng-relay-server-$$"
relay_image="lancache-ng-relay-dhcp:$$"
relay_container="lancache-ng-relay-relay-$$"
upstream_container="lancache-ng-relay-upstream-$$"
client_container="lancache-ng-relay-client-$$"

# What: Full lease acquisition (DORA).
# Why: Strongest proof relay works both directions.
cleanup() {
    docker rm -f "$client_container" "$relay_container" "$upstream_container" >/dev/null 2>&1 || true
    docker network rm "$client_net" "$server_net" >/dev/null 2>&1 || true
    docker rmi "$relay_image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== Building the dhcp-proxy image (relay mode) from this checkout =="
docker build -q -t "$relay_image" --build-context "shared-scripts=$repo_root/scripts/lib" services/dhcp-proxy >/dev/null

# What: derives two /28s from the reserved /27 slot.
# Why: reuses the shared pool, not a new hardcoded range.
# From: Issue #822
validation_subnet="${VALIDATION_SUBNET:-172.30.99.0/27}"
subnet_no_prefixlen="${validation_subnet%/*}"      # e.g. 172.30.147.64
subnet_prefix="${subnet_no_prefixlen%.*}"          # e.g. 172.30.147
subnet_base_octet="${subnet_no_prefixlen##*.}"     # e.g. 64

# What: Split /27 into two /28s within reserved range.
# Why: Base always multiple of 32; allocation is natural.
client_base=$(( subnet_base_octet + 0 ))
server_base=$(( subnet_base_octet + 16 ))

echo "== Creating two isolated bridge networks =="
docker network create --subnet "${subnet_prefix}.${client_base}/28" "$client_net" >/dev/null
docker network create --subnet "${subnet_prefix}.${server_base}/28" "$server_net" >/dev/null

# What: Define client/server subnets from /28s.
# Why: Pool (base+5..+10) stays within 14-host /28.
client_subnet="${subnet_prefix}.${client_base}/28"
relay_client_ip="${subnet_prefix}.$((client_base + 2))"
pool_start="${subnet_prefix}.$((client_base + 5))"
pool_end="${subnet_prefix}.$((client_base + 10))"
upstream_ip="${subnet_prefix}.$((server_base + 2))"
relay_server_ip="${subnet_prefix}.$((server_base + 3))"

echo "== Starting the upstream DHCP server on server-net (pool is for the CLIENT subnet) =="
# What: Configure upstream DHCP server.
# Why: Pool matched by giaddr; range for client subnet.
docker run -d --name "$upstream_container" \
    --network "$server_net" --ip "$upstream_ip" \
    --cap-add NET_ADMIN \
    --entrypoint sh \
    debian:trixie-slim -c '
        set -e
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq dnsmasq iproute2 >/dev/null 2>&1
        # What: Add return route to client subnet.
        # Why: Upstream must route replies back via relay.
        ip route add '"${client_subnet}"' via '"$relay_server_ip"'
        cat > /etc/dnsmasq-upstream.conf <<EOF
port=0
no-resolv
no-poll
interface=eth0
bind-interfaces
dhcp-authoritative
dhcp-range='"$pool_start"','"$pool_end"',255.255.255.240,12h
log-dhcp
no-daemon
EOF
        exec dnsmasq -k -C /etc/dnsmasq-upstream.conf
    ' >/dev/null

echo "== Starting the relay (dhcp-proxy image, DHCP_MODE=dnsmasq-relay) on BOTH networks =="
# What: Attach relay to both client and server nets.
# Why: giaddr on client; reach upstream on server net.
docker run -d --name "$relay_container" \
    --network "$client_net" --ip "$relay_client_ip" \
    --cap-add NET_ADMIN \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.rp_filter=0 \
    --sysctl net.ipv4.conf.all.accept_local=1 \
    -e DHCP_MODE=dnsmasq-relay \
    -e DHCP_RELAY_LOCAL_ADDR="$relay_client_ip" \
    -e UPSTREAM_DHCP_IP="$upstream_ip" \
    "$relay_image" >/dev/null
docker network connect --ip "$relay_server_ip" "$server_net" "$relay_container" >/dev/null

echo "== Waiting for the relay and upstream to come up =="
deadline=$((SECONDS + 60))
relay_ready=0
while (( SECONDS < deadline )); do
    # What: Capture logs/ps to variable before grep.
    # Why: Avoids docker CLI SIGPIPE on match.
    relay_log="$(docker logs "$relay_container" 2>&1 || true)"
    if grep -q "DHCP-relay mode" <<<"$relay_log"; then
        relay_ready=1
        break
    fi
    running_names="$(docker ps --format '{{.Names}}' || true)"
    if ! grep -q "^${relay_container}$" <<<"$running_names"; then
        echo "::error::Relay container exited early." >&2
        docker logs "$relay_container" >&2 || true
        exit 1
    fi
    sleep 2
done
if [[ "$relay_ready" -ne 1 ]]; then
    echo "::error::Relay did not report starting in DHCP-relay mode." >&2
    docker logs "$relay_container" >&2 || true
    exit 1
fi
# What: Wait for upstream DHCP to start.
# Why: Apt install + boot async; logs when ready.
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    # What: Capture logs to variable before grep.
    # Why: Avoid SIGPIPE if grep exits early on match.
    upstream_boot_log="$(docker logs "$upstream_container" 2>&1 || true)"
    grep -q "dnsmasq-dhcp" <<<"$upstream_boot_log" && break
    sleep 3
done
echo "Relay and upstream are up."

echo "== Client (client-net only, no route to server-net): send real DHCPDISCOVERs =="
# What: Emit real DHCP DISCOVERs from isolated client.
# Why: Only relay can carry them; proves real forwarding.
docker run --rm --name "$client_container" \
    --network "$client_net" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --entrypoint sh debian:trixie-slim -c '
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq isc-dhcp-client >/dev/null 2>&1
        # What: Emit DISCOVERs over ~25s.
        # Why: Async startup; cover race window.
        timeout 25 dhclient -4 -d -v eth0 2>&1 || true
    ' >/dev/null 2>&1 || true

echo "== Verifying the upstream received the RELAYED request and offered a client-pool address =="
# What: Check upstream logs for DISCOVER+OFFER.
# Why: Proves relay forwarded; giaddr selected pool.
upstream_log="$(docker logs "$upstream_container" 2>&1)"
echo "----- upstream DHCP transaction lines -----"
# What: Capture grep output to variable before head.
# Why: Avoid SIGPIPE when >6 lines match.
upstream_dhcp_lines="$(grep -E "DHCPDISCOVER|DHCPOFFER" <<<"$upstream_log" || true)"
head -6 <<<"$upstream_dhcp_lines" || true
echo "-------------------------------------------"

if ! grep -q "DHCPDISCOVER" <<<"$upstream_log"; then
    echo "::error::The upstream never received a DHCPDISCOVER -- the relay did not forward the client's request across the segment boundary." >&2
    echo "Relay logs:" >&2
    docker logs "$relay_container" >&2 || true
    exit 1
fi
# What: Extract offered IP via sed into here-string.
# Why: Avoids piping issues with early grep exit.
offered_lines="$(sed -n 's/.*DHCPOFFER(eth0) \([0-9.]*\).*/\1/p' <<<"$upstream_log")"
offered_ip="$(head -n1 <<<"$offered_lines")"
if [[ -z "$offered_ip" ]]; then
    echo "::error::The upstream received the relayed DISCOVER but issued no DHCPOFFER (check the pool/giaddr match)." >&2
    echo "Upstream logs:" >&2
    printf '%s\n' "$upstream_log" >&2
    exit 1
fi
# What: Verify offered IP is in client-subnet pool range.
# Why: Proves relay's giaddr selected correct subnet.
offered_last="${offered_ip##*.}"
offered_prefix="${offered_ip%.*}"
if [[ "$offered_prefix" != "$subnet_prefix" || "$offered_last" -lt $((client_base + 5)) || "$offered_last" -gt $((client_base + 10)) ]]; then
    echo "::error::Offered IP $offered_ip is not in the client-subnet pool ${pool_start}-${pool_end} -- the relay's giaddr did not select the client subnet." >&2
    exit 1
fi

echo "dhcp-relay-flow-simulation passed: relayed DHCPDISCOVER across segment boundary to upstream server, received $offered_ip from client-subnet pool with correct giaddr."
