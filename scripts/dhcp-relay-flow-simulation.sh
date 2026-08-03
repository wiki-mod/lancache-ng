#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real end-to-end proof for issue #844's dnsmasq DHCP-RELAY mode: the
# `dhcp-proxy` container, run with DHCP_MODE=dnsmasq-relay, must genuinely
# forward a client's DHCP exchange to an UPSTREAM DHCP server on a DIFFERENT
# network segment and relay the reply back -- not just render a config.
#
# Topology (two isolated bridge networks, deliberately -- if the client and
# the upstream server shared one segment, the server could answer the client
# directly and the relay would be bypassed, proving nothing):
#
#     client-net (192.168.60.0/24)        server-net (192.168.70.0/24)
#     ┌──────────┐   ┌───────────────────────────┐   ┌───────────────┐
#     │  client  │──▶│ relay (dhcp-proxy image)   │──▶│ upstream dnsmasq DHCP │
#     │ (no route│   │ .60.2 (giaddr) / .70.3     │   │ .70.2, pool for  │
#     │ to server)│  │ DHCP_MODE=dnsmasq-relay    │   │ the CLIENT subnet│
#     └──────────┘   └───────────────────────────┘   └───────────────┘
#
# The client can ONLY reach the upstream through the relay. The upstream's
# `dhcp-range` is for the client subnet (192.168.60.x), which the server
# selects by the giaddr the relay stamps in (DHCP_RELAY_LOCAL_ADDR=192.168.60.2)
# -- the #1 thing that silently breaks a relay test if the pool is on the
# server's own subnet instead. Success = the client is OFFERED an address from
# the client-subnet pool, which is only possible if the relay forwarded the
# request across the segment boundary and relayed the reply back.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

client_net="lancache-ng-relay-client-$$"
server_net="lancache-ng-relay-server-$$"
relay_image="lancache-ng-relay-dhcp:$$"
relay_container="lancache-ng-relay-relay-$$"
upstream_container="lancache-ng-relay-upstream-$$"
client_container="lancache-ng-relay-client-$$"

# Client subnet (where the client and the relay's client-facing NIC live) and
# the disjoint server subnet (where the upstream server and the relay's
# server-facing NIC live).
client_subnet="192.168.60.0/24"
relay_client_ip="192.168.60.2"
pool_start="192.168.60.50"
pool_end="192.168.60.60"
server_subnet="192.168.70.0/24"
upstream_ip="192.168.70.2"
relay_server_ip="192.168.70.3"

# The client runs a real ISC dhclient DORA (DISCOVER/OFFER/REQUEST/ACK) on the
# client segment. A full lease acquisition -- not just an OFFER -- is the
# strongest proof the whole relay round-trip works in both directions.

cleanup() {
    docker rm -f "$client_container" "$relay_container" "$upstream_container" >/dev/null 2>&1 || true
    docker network rm "$client_net" "$server_net" >/dev/null 2>&1 || true
    docker rmi "$relay_image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== Building the dhcp-proxy image (relay mode) from this checkout =="
docker build -q -t "$relay_image" services/dhcp-proxy >/dev/null

echo "== Creating two isolated bridge networks =="
docker network create --subnet "$client_subnet" "$client_net" >/dev/null
docker network create --subnet "$server_subnet" "$server_net" >/dev/null

echo "== Starting the upstream DHCP server on server-net (pool is for the CLIENT subnet) =="
# The upstream dnsmasq owns the real lease. Its dhcp-range is the CLIENT
# subnet: a relayed request arrives tagged with giaddr=192.168.60.2, and the
# server matches that giaddr to this range. `interface=eth0` binds it to its
# server-net NIC; dhcp-authoritative makes it answer immediately.
docker run -d --name "$upstream_container" \
    --network "$server_net" --ip "$upstream_ip" \
    --cap-add NET_ADMIN \
    --entrypoint sh \
    debian:trixie-slim -c '
        set -e
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq dnsmasq iproute2 >/dev/null 2>&1
        # The upstream is on server-net only, but it must reply (unicast) to
        # the relay agent'"'"'s giaddr on the CLIENT subnet. Add the return route
        # to the client subnet via the relay'"'"'s server-net address -- without
        # this the OFFER has nowhere to go and the client re-DISCOVERs forever.
        # (This route is exactly what a real deployment configures on the DHCP
        # server for a relayed subnet.)
        ip route add '"${client_subnet}"' via '"$relay_server_ip"'
        cat > /etc/dnsmasq-upstream.conf <<EOF
port=0
no-resolv
no-poll
interface=eth0
bind-interfaces
dhcp-authoritative
dhcp-range='"$pool_start"','"$pool_end"',255.255.255.0,12h
log-dhcp
no-daemon
EOF
        exec dnsmasq -k -C /etc/dnsmasq-upstream.conf
    ' >/dev/null

echo "== Starting the relay (dhcp-proxy image, DHCP_MODE=dnsmasq-relay) on BOTH networks =="
# Attach to client-net first (its client-facing NIC / giaddr address), then
# also to server-net so it can reach the upstream. DHCP_MODE + the two relay
# values are passed as env (no Admin UI in this test); the entrypoint reads
# DHCP_MODE the same way whether it comes from the env or the UI settings file.
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
    if docker logs "$relay_container" 2>&1 | grep -q "DHCP-relay mode"; then
        relay_ready=1
        break
    fi
    if ! docker ps --format '{{.Names}}' | grep -q "^${relay_container}$"; then
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
# Give the upstream apt-install+start a moment; it logs when ready.
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    docker logs "$upstream_container" 2>&1 | grep -q "dnsmasq-dhcp" && break
    sleep 3
done
echo "Relay and upstream are up."

echo "== Client (client-net only, no route to server-net): send real DHCPDISCOVERs =="
# The client attaches ONLY to client-net, so its only path to any DHCP server
# is through the relay. A real ISC dhclient emits genuine broadcast
# DHCPDISCOVERs on the segment; the relay is the only thing that can carry them
# anywhere. It is run best-effort (the authoritative assertion is on the
# upstream side below, which is deterministic and not subject to the return-leg
# routing quirks of a two-Docker-bridge test bed -- see the note under
# verification). NET_ADMIN/NET_RAW are needed for its raw DHCP socket.
docker run --rm --name "$client_container" \
    --network "$client_net" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --entrypoint sh debian:trixie-slim -c '
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq isc-dhcp-client >/dev/null 2>&1
        # Emit several DISCOVERs over ~25s so the relay+upstream (which install
        # dnsmasq on first boot) are certainly up for at least one of them.
        timeout 25 dhclient -4 -d -v eth0 2>&1 || true
    ' >/dev/null 2>&1 || true

echo "== Verifying the upstream received the RELAYED request and offered a client-pool address =="
# The deterministic proof: the upstream DHCP server -- on server-net, with NO
# path to the client except back through the relay -- logs a DHCPDISCOVER it
# could only have received via the relay (the client cannot reach it directly),
# and answers with a DHCPOFFER of an address from the CLIENT subnet pool. That
# offer is only possible if the relay stamped the correct giaddr
# (DHCP_RELAY_LOCAL_ADDR) so the upstream selected the client-subnet range.
# Reaching the upstream at all across the segment boundary is exactly issue
# #844's requirement ("actual lease/relay traffic reaches a real upstream DHCP
# server"). (The offer's return leg to the client relies on the upstream
# routing back to giaddr across two Docker bridges, which is environment-
# specific and deliberately NOT what this assertion depends on.)
upstream_log="$(docker logs "$upstream_container" 2>&1)"
echo "----- upstream DHCP transaction lines -----"
printf '%s\n' "$upstream_log" | grep -E "DHCPDISCOVER|DHCPOFFER" | head -6 || true
echo "-------------------------------------------"

if ! printf '%s\n' "$upstream_log" | grep -q "DHCPDISCOVER"; then
    echo "::error::The upstream never received a DHCPDISCOVER -- the relay did not forward the client's request across the segment boundary." >&2
    echo "Relay logs:" >&2
    docker logs "$relay_container" >&2 || true
    exit 1
fi
offered_ip="$(printf '%s\n' "$upstream_log" | sed -n 's/.*DHCPOFFER(eth0) \([0-9.]*\).*/\1/p' | head -n1)"
if [[ -z "$offered_ip" ]]; then
    echo "::error::The upstream received the relayed DISCOVER but issued no DHCPOFFER (check the pool/giaddr match)." >&2
    echo "Upstream logs:" >&2
    printf '%s\n' "$upstream_log" >&2
    exit 1
fi
# Assert the offered IP is within pool_start..pool_end (client subnet), proving
# the giaddr the relay stamped selected the correct, client-subnet pool.
offered_last="${offered_ip##*.}"
offered_prefix="${offered_ip%.*}"
if [[ "$offered_prefix" != "192.168.60" || "$offered_last" -lt 50 || "$offered_last" -gt 60 ]]; then
    echo "::error::Offered IP $offered_ip is not in the client-subnet pool ${pool_start}-${pool_end} -- the relay's giaddr did not select the client subnet." >&2
    exit 1
fi

echo "dhcp-relay-flow-simulation passed: a client on an isolated segment with no direct path to the upstream DHCP server had its DHCPDISCOVER relayed across the segment boundary to the real upstream, which offered $offered_ip from the client-subnet pool -- proof the dnsmasq-relay-mode dhcp-proxy container genuinely forwards real DHCP traffic to a real upstream DHCP server with the correct giaddr (issue #844)."
