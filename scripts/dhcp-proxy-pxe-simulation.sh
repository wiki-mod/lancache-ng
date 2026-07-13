#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Real DHCP behavior test for services/dhcp-proxy's ProxyDHCP/PXE mode
# (issue #705) -- the dnsmasq-proxy DHCP mode that
# scripts/dhcp-kea-lease-flow-simulation.sh's own header comment
# explicitly calls out as "entirely different code path, out of scope
# for this script." This script is that missing coverage.
#
# What this proves, end to end, against a real dnsmasq container built
# from this checkout (not a mock or a unit test of entrypoint.sh alone):
#   - A synthetic PXE client sending a DHCPDISCOVER with DHCP option 60
#     (vendor class) = "PXEClient" and option 93 (client-system-
#     architecture) = 0 (legacy BIOS) receives a real DHCPOFFER carrying
#     the operator-configured external PXE boot server address and
#     BIOS-specific boot filename, plus the base LanCache NG DNS servers
#     (option 6) -- the original ask of issue #705.
#   - The same, for architecture 7 (x86-64 UEFI) and architecture 11
#     (ARM64 UEFI), each receiving the UEFI-specific boot filename.
#   - An ordinary DHCPDISCOVER carrying neither option (no PXE tag at
#     all) receives NO reply whatsoever -- confirming dnsmasq's ProxyDHCP
#     mode still answers only PXE-tagged clients, exactly as
#     docs/dhcp-modes.md documents, and does not somehow start replying
#     to every DHCP client on the segment once PXE support is enabled.
#
# This is also, unavoidably, the regression test for the root-cause bug
# issue #705 found and services/dhcp-proxy/entrypoint.sh now fixes:
# without a `pxe-service` directive present, dnsmasq's ProxyDHCP mode
# does not reply to ANY DHCPDISCOVER, PXE-tagged or not (confirmed
# directly during this issue's investigation, and the reason every
# scenario above -- including the architecture-specific ones, which are
# actually delivered via dhcp-boot/dhcp-match, not pxe-service itself --
# depends on the opt-in DHCP_PROXY_PXE_BOOT_SERVER/_FILENAME_* variables
# this script sets being present at all).
#
# See scripts/lib/pxe-client-probe.py for how the synthetic PXE client
# itself is built (scapy, since no off-the-shelf DHCP client can be made
# to send a real PXE-tagged DISCOVER) and why reply capture goes through
# a tcpdump-written pcap file rather than scapy's own live sniff.
#
# Safety model, mirroring scripts/dhcp-kea-lease-flow-simulation.sh's own
# (see that script's header comment for the fuller rationale): both the
# dnsmasq-proxy server and the synthetic PXE client run as ordinary
# Docker containers on a throwaway, per-run bridge network this script
# creates and destroys itself, never bridged to any host interface or the
# runner's real LAN. Nothing here ever calls `ip addr add`/`ip route` on
# any interface; the synthetic client only ever sends/receives via scapy
# on its own container's already-Docker-assigned interface.
#
# What this script does NOT verify: PXE boot menu behavior (this project
# deliberately implements none -- dnsmasq's role is only to point a PXE
# client at an operator's own external boot server, never to serve boot
# files or menus itself, see docs/dhcp-modes.md) and an actual TFTP/HTTP
# boot-file transfer against that external server (out of scope by
# design -- the external server is entirely outside this project and, in
# this script, is never even a real listening service, just a
# configured address the DHCPOFFER is asserted to point at).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"

client_tool_image="${DHCP_PXE_SIMULATION_CLIENT_IMAGE:?DHCP_PXE_SIMULATION_CLIENT_IMAGE is required (an image providing python3-scapy and tcpdump, e.g. the build-tools image)}"

work_dir="$repo_root/.dhcp-proxy-pxe-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"
# world-writable for the same reason
# dhcp-kea-lease-flow-simulation.sh's own client-state directory is:
# a throwaway, per-run temp directory scoped to this one invocation, not
# a shared or security-sensitive path, and the client container's own
# unprivileged runtime user needs to write the pcap files scapy/tcpdump
# produce into it.
chmod 0777 "$work_dir"

# A fixed subnet would collide across concurrent runs sharing one of this
# project's self-hosted runner hosts. Mirror
# dhcp-kea-lease-flow-simulation.sh's own per-run derivation, on a
# dedicated 172.29.0.0/16 range unused by deploy/dev's 172.28.0.0/16,
# full-setup-validate's 172.30.0.0/16, and
# dhcp-kea-lease-flow-simulation's own 172.31.0.0/16. Deliberately NOT
# 172.32.0.0/16: RFC 1918's 172.16.0.0/12 private block ends at
# 172.31.255.255, so 172.32.0.0/16 is public address space -- creating a
# Docker bridge route there could hijack traffic to a real public
# 172.32.*  destination on a self-hosted runner for the duration of the
# job (and on a failed cleanup, until the route is removed). 172.29.0.0/16
# stays inside 172.16.0.0/12 and is not claimed by any other script/compose
# file in this repo (confirmed via a repo-wide grep for other 172.16-31.x.x
# usages), found in PR #765 review.
run_identity="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$}-${RANDOM:-0}-pxe"
digest="$(printf '%s' "$run_identity" | sha256sum | cut -c1-8)"
octet=$(( (16#$digest % 252) + 2 )) # 2..253
subnet="172.29.${octet}.0/24"
gateway="172.29.${octet}.1"
dhcp_proxy_ip="172.29.${octet}.2"
dns_primary="172.29.${octet}.10"
dns_secondary="172.29.${octet}.11"
# The external PXE boot server this run's DHCPOFFERs are asserted to
# point at. Deliberately never started as a real listening service
# anywhere -- per this project's #705 scope, lancache-ng only ever hands
# out a pointer to an operator's own existing PXE/TFTP infrastructure, it
# never hosts boot files itself, so this script only needs to prove the
# pointer's address/filename are correct, not that a real TFTP transfer
# against it would succeed.
pxe_boot_server="172.29.${octet}.50"
bios_boot_filename="lancache-pxe705-bios.0"
uefi_boot_filename="lancache-pxe705-uefi.efi"

network_name="lancache-ng-dhcp705-${octet}-$$"
dhcp_container="lancache-ng-dhcp705-proxy-${octet}-$$"
client_container="lancache-ng-dhcp705-client-${octet}-$$"
image_tag="lancache-ng-dhcp705-proxy:${octet}-$$"

# See dhcp-kea-lease-flow-simulation.sh's own cleanup() comment for why
# `local status=$?` is captured first and the docker teardown commands
# are ordered deliberately (containers before the network they're
# attached to, before the image they reference) -- identical reasoning
# applies here.
cleanup() {
    local status=$?
    docker rm -f "$dhcp_container" "$client_container" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker rmi "$image_tag" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the dhcp-proxy image from this checkout's services/dhcp-proxy =="
docker build -q -t "$image_tag" services/dhcp-proxy >/dev/null

echo "== Creating isolated bridge network $network_name ($subnet, no host interface involved) =="
docker network create \
    --driver bridge \
    --subnet "$subnet" \
    --gateway "$gateway" \
    "$network_name" >/dev/null

echo "== Starting a real dhcp-proxy container on the isolated network, PXE boot-pointer configured for both BIOS and UEFI (issue #705) =="
# --cap-add NET_ADMIN/NET_RAW: dnsmasq's ProxyDHCP mode binds a raw DHCP
# socket, matching the same capability requirement
# dhcp-kea-lease-flow-simulation.sh already documents for its own Kea
# container.
docker run -d --name "$dhcp_container" \
    --network "$network_name" --ip "$dhcp_proxy_ip" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -e DHCP_SUBNET_START="172.29.${octet}.0" \
    -e DHCP_DNS_PRIMARY="$dns_primary" \
    -e DHCP_DNS_SECONDARY="$dns_secondary" \
    -e UPSTREAM_DHCP_IP="$gateway" \
    -e DHCP_PROXY_PXE_BOOT_SERVER="$pxe_boot_server" \
    -e DHCP_PROXY_PXE_BOOT_FILENAME_BIOS="$bios_boot_filename" \
    -e DHCP_PROXY_PXE_BOOT_FILENAME_UEFI="$uefi_boot_filename" \
    "$image_tag" >/dev/null

echo "== Waiting for dnsmasq to report it is serving the proxy subnet =="
deadline=$((SECONDS + 30))
dhcp_ready=0
while (( SECONDS < deadline )); do
    if docker logs "$dhcp_container" 2>&1 | grep -q 'DHCP, proxy on subnet'; then
        dhcp_ready=1
        break
    fi
    if ! docker ps -q --filter "name=${dhcp_container}$" | grep -q .; then
        echo "::error::dhcp-proxy container exited before it started serving. Logs:" >&2
        docker logs "$dhcp_container" >&2 || true
        exit 1
    fi
    sleep 1
done
if [[ "$dhcp_ready" -ne 1 ]]; then
    echo "::error::dhcp-proxy container never reported it was serving the proxy subnet within 30s." >&2
    docker logs "$dhcp_container" >&2 || true
    exit 1
fi
echo "dhcp-proxy is up (subnet: 172.29.${octet}.0, PXE boot server: $pxe_boot_server)."

echo "== Starting the synthetic PXE client container =="
# NET_RAW/NET_ADMIN: scapy needs a raw socket to craft and send an
# arbitrary Ethernet/IP/UDP/BOOTP frame, and to receive on the interface
# via the separate tcpdump capture scripts/lib/pxe-client-probe.py drives
# -- matching dhcp-kea-lease-flow-simulation.sh's own dhclient client
# container capability rationale.
docker run -d --name "$client_container" \
    --network "$network_name" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$repo_root/scripts/lib:/pxe-lib:ro" \
    -v "$work_dir:/work" \
    "$client_tool_image" \
    sleep 300 >/dev/null

# run_probe <label> <extra pxe-client-probe.py args...>
# Runs one synthetic-client probe inside $client_container and prints its
# raw KEY='value' output to stdout, capturing nothing else -- callers
# parse the result with dhcp_lease_field (sourced above), which works
# against any KEY='value' text, not just a real DHCP lease file, since it
# only ever scans for "${key}=" line prefixes.
run_probe() {
    local label="$1"
    shift
    echo "== PXE probe: $label ==" >&2
    docker exec "$client_container" \
        python3 /pxe-lib/pxe-client-probe.py --iface eth0 --pcap-out "/work/${label}.pcap" "$@"
}

fail=0

bios_result="$(run_probe bios --arch 0)"
echo "$bios_result"
uefi_x8664_result="$(run_probe uefi-x8664 --arch 7)"
echo "$uefi_x8664_result"
uefi_arm64_result="$(run_probe uefi-arm64 --arch 11)"
echo "$uefi_arm64_result"
negative_result="$(run_probe negative-no-pxe --no-pxe)"
echo "$negative_result"

# assert_pxe_reply <label> <parsed_result> <expected_filename>
# Shared assertion for the three positive (PXE-tagged) scenarios: a reply
# was received at all, it carries both configured LanCache NG DNS
# servers (option 6 -- the original issue #705 ask), it points at the
# operator-configured external PXE boot server address (not dnsmasq's own
# address -- the specific wire-level pitfall this issue's investigation
# found and documented in entrypoint.sh), and it carries the
# architecture-appropriate boot filename.
assert_pxe_reply() {
    local label="$1" parsed="$2" expected_filename="$3"
    local got_reply dns_servers siaddr file

    got_reply="$(dhcp_lease_field "$parsed" got_reply || true)"
    if [[ "$got_reply" != "1" ]]; then
        echo "::error::[$label] expected a DHCPOFFER reply, got none." >&2
        fail=1
        return
    fi

    dns_servers="$(dhcp_lease_field "$parsed" dns_servers || true)"
    if [[ "$dns_servers" != "${dns_primary},${dns_secondary}" ]]; then
        echo "::error::[$label] DNS servers option '$dns_servers' does not match the configured DHCP_DNS_PRIMARY/SECONDARY (${dns_primary},${dns_secondary})." >&2
        fail=1
    fi

    siaddr="$(dhcp_lease_field "$parsed" siaddr || true)"
    if [[ "$siaddr" != "$pxe_boot_server" ]]; then
        echo "::error::[$label] boot server address '$siaddr' does not match the configured external DHCP_PROXY_PXE_BOOT_SERVER ($pxe_boot_server) -- got dnsmasq's own address instead of the operator-configured external one?" >&2
        fail=1
    fi

    file="$(dhcp_lease_field "$parsed" file || true)"
    if [[ "$file" != "$expected_filename" ]]; then
        echo "::error::[$label] boot filename '$file' does not match the expected architecture-specific filename ($expected_filename)." >&2
        fail=1
    fi
}

assert_pxe_reply "BIOS (arch 0, x86PC)" "$bios_result" "$bios_boot_filename"
assert_pxe_reply "UEFI x86-64 (arch 7)" "$uefi_x8664_result" "$uefi_boot_filename"
assert_pxe_reply "UEFI ARM64 (arch 11)" "$uefi_arm64_result" "$uefi_boot_filename"

negative_got_reply="$(dhcp_lease_field "$negative_result" got_reply || true)"
if [[ "$negative_got_reply" != "0" ]]; then
    echo "::error::[ordinary DISCOVER, no PXE tag] expected NO reply (dnsmasq's ProxyDHCP mode must only answer PXE-tagged clients), but got one." >&2
    fail=1
fi

# summarize_probe <parsed_result>
# Formats one probe's result for the human-readable report below. Checks
# the got_reply field's actual VALUE ("1" vs "0"), not merely whether the
# field is present -- got_reply is always emitted by
# scripts/lib/pxe-client-probe.py (unlike file/siaddr, which are only
# printed when non-empty), so testing for presence alone would always be
# true and never report "<no reply>" even when a probe correctly found
# none.
summarize_probe() {
    local parsed="$1"
    if [[ "$(dhcp_lease_field "$parsed" got_reply || true)" == "1" ]]; then
        printf 'reply, file=%s, siaddr=%s' \
            "$(dhcp_lease_field "$parsed" file || echo '<none>')" \
            "$(dhcp_lease_field "$parsed" siaddr || echo '<none>')"
    else
        printf '<no reply>'
    fi
}

report=$(cat <<REPORT
== DHCP proxy PXE simulation result (issue #705) ==
BIOS (arch 0):        $(summarize_probe "$bios_result")
UEFI x86-64 (arch 7):  $(summarize_probe "$uefi_x8664_result")
UEFI ARM64 (arch 11):  $(summarize_probe "$uefi_arm64_result")
Ordinary DISCOVER (no PXE tag): $([[ "$negative_got_reply" == "0" ]] && echo "correctly got no reply" || echo "unexpectedly got a reply")

Verified: a synthetic PXE client's DHCPDISCOVER (option 60=PXEClient,
option 93=client-system-architecture) against our own dnsmasq-proxy
service, configured with DHCP_PROXY_PXE_BOOT_SERVER/_FILENAME_BIOS/
_FILENAME_UEFI, receives a real DHCPOFFER carrying the configured
external boot server address, the architecture-appropriate boot
filename, and the LanCache NG DNS servers -- for legacy BIOS and both
covered UEFI architecture codes -- while an ordinary DISCOVER with no PXE
tag at all still receives no reply.

NOT verified by this script: PXE boot menu behavior (this project
implements none) and an actual TFTP/HTTP transfer against the external
boot server (outside this project's scope; see docs/dhcp-modes.md).
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
    echo "::error::dhcp-proxy-pxe-simulation FAILED: one or more PXE probes did not match the expected result." >&2
    exit 1
fi

echo "dhcp-proxy-pxe-simulation passed: real PXE-tagged DHCPOFFERs matched configuration for BIOS and both covered UEFI architectures, and ordinary clients still receive no reply."
