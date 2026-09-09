#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Test dhcp-proxy ProxyDHCP/PXE mode.
# Why: Missing test coverage for root cause.
# From: Issue #705
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$repo_root"

# shellcheck source=scripts/lib/dhcp-lease-parse.sh
source "$repo_root/scripts/lib/dhcp-lease-parse.sh"
# shellcheck source=scripts/lib/reserve-validation-subnet.sh
source "$repo_root/scripts/lib/reserve-validation-subnet.sh"

client_tool_image="${DHCP_PXE_SIMULATION_CLIENT_IMAGE:?DHCP_PXE_SIMULATION_CLIENT_IMAGE is required (an image providing the Rust toolchain to compile tools/pxe-client-probe and tcpdump to capture the reply, e.g. the build-tools image)}"
# What: Validate cargo build env vars.
# Why: script runs cargo build like Dockerfile.
# From: Issue #1095
project_cargo_lto="${PROJECT_CARGO_LTO:?PROJECT_CARGO_LTO is required (no in-file/script default; Issue #1095, PR #1796 review 5109560874)}"
case "$project_cargo_lto" in off|thin|fat|true|false) ;; *) echo "PROJECT_CARGO_LTO must be one of: off, thin, fat, true, false (got '$project_cargo_lto')" >&2; exit 1;; esac
project_cargo_codegenunit="${PROJECT_CARGO_CODEGENUNIT:?PROJECT_CARGO_CODEGENUNIT is required (no in-file/script default; Issue #1095, PR #1796 review 5109560874)}"
case "$project_cargo_codegenunit" in ''|*[!0-9]*) echo "PROJECT_CARGO_CODEGENUNIT must be a positive integer (got '$project_cargo_codegenunit')" >&2; exit 1;; esac
[ "$project_cargo_codegenunit" -gt 0 ] || { echo "PROJECT_CARGO_CODEGENUNIT must be greater than zero" >&2; exit 1; }

work_dir="$repo_root/.dhcp-proxy-pxe-simulation-tmp"
rm -rf "$work_dir"
mkdir -p "$work_dir"
# What: Make work dir world-writable.
# Why: Container needs write for binary/pcap.
chmod 0777 "$work_dir"

# What: Use $$ for collision-free names.
# Why: Shared runner may run multiple tests.
network_name="lancache-ng-dhcp705-$$"
dhcp_container="lancache-ng-dhcp705-proxy-$$"
client_container="lancache-ng-dhcp705-client-$$"
image_tag="lancache-ng-dhcp705-proxy:$$"

# What: Capture status; order teardown carefully.
# Why: Sequence matters for network/image cleanup.
cleanup() {
    local status=$?
    docker rm -f "$dhcp_container" "$client_container" >/dev/null 2>&1 || true
    # What: Retry network rm vs active endpoint race.
    # Why: Cleanup must handle timing/race conditions.
    validation_network_teardown "$network_name" || true
    docker rmi "$image_tag" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    # What: Release subnet-octet lock holder.
    # Why: Safe no-op if reservation never locked.
    validation_subnet_release "${subnet_lock_holder_pid:-}"
    exit "$status"
}
trap cleanup EXIT

echo "== Building the dhcp-proxy image from this checkout's services/dhcp-proxy =="
docker build -q -t "$image_tag" --build-context "shared-scripts=$repo_root/scripts/lib" services/dhcp-proxy >/dev/null

# What: Use 172.29.0.0/16 with flock+retry.
# Why: Avoid collision on shared runner; RFC1918.
subnet_lock_root="/tmp/lancache-validation-locks-dhcp-proxy-pxe"
subnet_max_attempts=10
subnet_run_id="${GITHUB_RUN_ID:-local}-$$-${RANDOM:-0}-pxe"
subnet_run_attempt="${GITHUB_RUN_ATTEMPT:-1}"

octet=""
subnet_lock_holder_pid=""
subnet_next_attempt=1
while [[ -z "$octet" && "$subnet_next_attempt" -le "$subnet_max_attempts" ]]; do
    reservation="$(validation_subnet_reserve "$subnet_lock_root" "$subnet_run_id" "$subnet_run_attempt" "$subnet_next_attempt" "$subnet_max_attempts")" || {
        echo "::error::Could not lock a free validation subnet octet after $subnet_max_attempts attempts." >&2
        exit 1
    }
    # What: Parse output via here-string, not pipe.
    # Why: Avoids pipefail/SIGPIPE silent failure.
    if ! attempt="$(sed -n 's/^attempt=//p' <<<"$reservation")"; then
        echo "::error::Could not parse 'attempt' out of the subnet reservation output." >&2
        exit 1
    fi
    if ! candidate_octet="$(sed -n 's/^octet=//p' <<<"$reservation")"; then
        echo "::error::Could not parse 'octet' out of the subnet reservation output." >&2
        exit 1
    fi
    if ! candidate_pid="$(sed -n 's/^holder_pid=//p' <<<"$reservation")"; then
        echo "::error::Could not parse 'holder_pid' out of the subnet reservation output." >&2
        exit 1
    fi

    candidate_subnet="172.29.${candidate_octet}.0/24"
    if ! conflict="$(validation_subnet_conflicts "$candidate_subnet")"; then
        echo "::error::Subnet-conflict check failed for candidate subnet $candidate_subnet." >&2
        exit 1
    fi
    if [[ -n "$conflict" ]]; then
        echo "Octet $candidate_octet's subnet $candidate_subnet overlaps existing host/Docker state ($conflict); releasing and trying the next candidate."
        validation_subnet_release "$candidate_pid"
        subnet_next_attempt=$((attempt + 1))
        continue
    fi

    echo "== Creating isolated bridge network $network_name ($candidate_subnet, no host interface involved) (attempt $attempt) =="
    if create_output="$(docker network create \
        --driver bridge \
        --subnet "$candidate_subnet" \
        --gateway "172.29.${candidate_octet}.1" \
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

# What: Compute addrs after octet is locked.
# Why: Octet only known after network create.
subnet="172.29.${octet}.0/24"
gateway="172.29.${octet}.1"
dhcp_proxy_ip="172.29.${octet}.2"
dns_primary="172.29.${octet}.10"
dns_secondary="172.29.${octet}.11"
# What: Point to external PXE boot server.
# Why: Never start real server; only test pointer.
pxe_boot_server="172.29.${octet}.50"
bios_boot_filename="lancache-pxe705-bios.0"
uefi_boot_filename="lancache-pxe705-uefi.efi"
echo "Validation network is up on subnet $subnet (lock held by PID $subnet_lock_holder_pid)."

echo "== Starting a real dhcp-proxy container, PXE boot-pointer configured =="
# What: Add NET_ADMIN/NET_RAW capabilities.
# Why: ProxyDHCP needs raw socket for DHCP.
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
    # What: Capture logs via here-string, not pipe.
    # Why: Avoid SIGPIPE early-exit on grep match.
    dhcp_log="$(docker logs "$dhcp_container" 2>&1 || true)"
    if grep -q 'DHCP, proxy on subnet' <<<"$dhcp_log"; then
        dhcp_ready=1
        break
    fi
    # `--filter name=<exact>$` anchors on the one container name this
    # script itself created, so `docker ps -q` can only ever produce 0 or 1
    # lines here (pipefail-safe construct).
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

echo "== Compiling the synthetic PXE client probe (tools/pxe-client-probe) with the build-tools image =="
# What: Mount repo; pass cargo build env vars.
# Why: Workspace needs root Cargo.lock.
# From: Issue #1095
docker run --rm \
    -v "$repo_root:/repo:ro" \
    -v "$work_dir:/out" \
    -e CARGO_TARGET_DIR=/build-target \
    -e CARGO_PROFILE_RELEASE_LTO="$project_cargo_lto" \
    -e CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$project_cargo_codegenunit" \
    "$client_tool_image" \
    bash -c 'set -euo pipefail; cargo build --release --locked --manifest-path /repo/tools/pxe-client-probe/Cargo.toml -p pxe-client-probe; cp /build-target/release/pxe-client-probe /out/pxe-client-probe'

echo "== Starting the synthetic PXE client container =="
# What: Add NET_RAW/NET_ADMIN capabilities.
# Why: Probe needs raw socket; tcpdump needs capture.
docker run -d --name "$client_container" \
    --network "$network_name" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "$work_dir:/work" \
    "$client_tool_image" \
    sleep 300 >/dev/null

# What: Run synthetic PXE probe in container.
# Why: Execute probe; output KEY='value' pairs.
run_probe() {
    local label="$1"
    shift
    echo "== PXE probe: $label ==" >&2
    docker exec "$client_container" \
        /work/pxe-client-probe --iface eth0 --pcap-out "/work/${label}.pcap" "$@"
}

fail=0

# What: Check probe result before proceeding.
# Why: Catch early exit failures with diagnostics.
if ! bios_result="$(run_probe bios --arch 0)"; then
    echo "::error::PXE probe 'bios' (arch 0) failed to run inside the client container." >&2
    exit 1
fi
echo "$bios_result"
if ! uefi_x8664_result="$(run_probe uefi-x8664 --arch 7)"; then
    echo "::error::PXE probe 'uefi-x8664' (arch 7) failed to run inside the client container." >&2
    exit 1
fi
echo "$uefi_x8664_result"
if ! uefi_arm64_result="$(run_probe uefi-arm64 --arch 11)"; then
    echo "::error::PXE probe 'uefi-arm64' (arch 11) failed to run inside the client container." >&2
    exit 1
fi
echo "$uefi_arm64_result"
if ! negative_result="$(run_probe negative-no-pxe --no-pxe)"; then
    echo "::error::PXE probe 'negative-no-pxe' (no PXE tag) failed to run inside the client container." >&2
    exit 1
fi
echo "$negative_result"

# assert_pxe_reply <label> <parsed_result> <expected_filename>
# Shared assertion for the three positive (PXE-tagged) scenarios: a reply
# was received at all, it carries both configured LanCache NG DNS
# servers (option 6), it points at the
# operator-configured external PXE boot server address (not dnsmasq's own
# address), and it carries the
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

# What: Format probe result for readability.
# Why: got_reply always emitted; check value not presence.
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
== DHCP proxy PXE simulation result ==
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
