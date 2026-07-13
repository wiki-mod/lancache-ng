#!/usr/bin/env python3
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Synthetic PXE-client DHCPDISCOVER probe for scripts/dhcp-proxy-pxe-
# simulation.sh (issue #705). No off-the-shelf DHCP client (dhclient,
# udhcpc, ...) can be made to send a real PXE-tagged DHCPDISCOVER (DHCP
# option 60=PXEClient, option 93=client-system-architecture) -- that is
# exactly the packet shape a real PXE ROM sends and the shape this
# project's services/dhcp-proxy code path (dnsmasq ProxyDHCP mode) only
# ever reacts to, so the original issue's own suggested approach (and this
# investigation's confirmation of the underlying bug) both required
# crafting one directly. scapy is used only to build and *send* the packet
# here (`sendp`); replies are captured separately via a tcpdump-written
# pcap file rather than scapy's own live sniff (`srp1`/`sniff`) -- see
# tools/build-tools/Dockerfile's comment on the python3-scapy/tcpdump
# packages for why: scapy's live sniff was confirmed, during this issue's
# investigation, to miss real replies from this project's exact dnsmasq
# build that tcpdump itself captured without any trouble.
#
# Prints the parsed result as shell-safe KEY='value' lines on stdout, one
# recognized field per line, mirroring the convention
# scripts/lib/dhcp-lease-parse.sh already established for the Kea
# lease-flow simulation -- a key is simply absent from the output if this
# probe never received it, callers must not assume every key is present.
#
# Recognized output keys:
#   got_reply     -- "1" if any BOOTP/DHCP reply matching this probe's own
#                    xid was captured at all (op=BOOTREPLY), "0" otherwise.
#   message_type  -- raw numeric DHCP message-type option (53), e.g. "2"
#                    for DHCPOFFER (scapy does not decode this to a
#                    keyword when dissecting an incoming packet's option
#                    list, only when constructing one from Python).
#   server_id     -- option 54 (server identifier), the IP address of the
#                    dnsmasq container that answered.
#   dns_servers   -- option 6 (domain-name-servers), comma-separated --
#                    this is the base DNS-injection feature the original
#                    issue #705 asked to have verified.
#   siaddr        -- the reply's BOOTP "next server" (siaddr) field, only
#                    printed when non-zero. This is where dnsmasq's
#                    dhcp-boot directive (tag-matched by client
#                    architecture) puts the operator-configured external
#                    PXE boot server address.
#   file          -- the reply's BOOTP "file" field (boot filename),
#                    trimmed of trailing NUL padding, only printed when
#                    non-empty. This is where dhcp-boot puts the
#                    operator-configured, architecture-specific boot
#                    filename.
import argparse
import random
import subprocess
import sys
import time

from scapy.all import BOOTP, DHCP, Ether, IP, UDP, get_if_hwaddr, rdpcap, sendp


def build_discover(iface: str, arch: int, send_pxe_options: bool, xid: int):
    mac = get_if_hwaddr(iface)
    chaddr = [bytes.fromhex(mac.replace(":", ""))]

    dhcp_options = [("message-type", "discover")]
    if send_pxe_options:
        dhcp_options += [
            ("vendor_class_id", b"PXEClient"),
            # Option 93 (RFC 4578 client-system-architecture): the field
            # dnsmasq's dhcp-match/pxe-service architecture matching keys
            # off. A 2-byte big-endian integer per the RFC.
            (93, arch.to_bytes(2, "big")),
            # Option 94 (client network device interface): a real PXE ROM
            # always sends this alongside option 93; included for realism
            # even though this project's dnsmasq config does not key off
            # it. Value: UNDI, major 2, minor 1 -- an arbitrary but
            # RFC-valid NDI version, matching what this issue's own
            # investigation already sent successfully.
            (94, b"\x01\x02\x01"),
        ]
    dhcp_options.append("end")

    # flags=0x8000 (broadcast bit): this probe has no IP of its own yet
    # (ciaddr/yiaddr both 0.0.0.0), exactly the real state of a PXE ROM
    # before it has a lease -- the broadcast bit tells dnsmasq to reply to
    # the all-ones broadcast address rather than attempt (and fail) a
    # unicast reply to an address that does not exist yet.
    return (
        Ether(src=mac, dst="ff:ff:ff:ff:ff:ff")
        / IP(src="0.0.0.0", dst="255.255.255.255")
        / UDP(sport=68, dport=67)
        / BOOTP(chaddr=chaddr, xid=xid, flags=0x8000)
        / DHCP(options=dhcp_options)
    )


def parse_reply(pcap_path: str, xid: int):
    packets = rdpcap(pcap_path)
    for pkt in packets:
        # op=2 is BOOTREPLY -- filters out this probe's own DISCOVER
        # (op=1, BOOTREQUEST), which the same capture also contains since
        # it listens on both port 67 and 68 for the full exchange.
        if BOOTP in pkt and int(pkt[BOOTP].xid) == xid and int(pkt[BOOTP].op) == 2:
            return pkt
    return None


def emit(key: str, value: str) -> None:
    # DHCP field values here (IP addresses, filenames, message-type
    # keywords) never contain a single quote, so no escaping beyond
    # wrapping in one is needed -- matching
    # scripts/lib/dhcp-lease-parse.sh's own `emit` helper.
    print(f"{key}='{value}'")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iface", required=True, help="interface to send on and capture from")
    parser.add_argument(
        "--arch",
        type=int,
        default=0,
        help="DHCP option 93 client-system-architecture code to send (ignored with --no-pxe)",
    )
    parser.add_argument(
        "--no-pxe",
        action="store_true",
        help="send an ordinary DISCOVER with no PXE vendor-class/architecture options at all "
        "(the negative-case probe: dnsmasq's ProxyDHCP mode must never reply to this)",
    )
    parser.add_argument("--pcap-out", required=True, help="path tcpdump writes the capture to")
    parser.add_argument(
        "--wait-seconds",
        type=float,
        default=5.0,
        help="how long to wait for a reply after sending before giving up",
    )
    args = parser.parse_args()

    xid = random.randint(1, 0xFFFFFFFF)
    pkt = build_discover(args.iface, args.arch, not args.no_pxe, xid)

    # -U (packet-buffered) so the pcap file is flushed to disk as packets
    # arrive rather than only on tcpdump's own internal buffer/exit --
    # this script kills the process well before any such buffer would
    # naturally flush otherwise, and reading a not-yet-flushed pcap file
    # would silently look identical to "no reply was ever sent".
    tcpdump = subprocess.Popen(
        ["tcpdump", "-i", args.iface, "-w", args.pcap_out, "-U", "port", "67", "or", "port", "68"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # Give tcpdump time to actually attach to the interface before the
        # DISCOVER goes out -- sending immediately risks a race where the
        # reply arrives before the capture has started.
        time.sleep(1)
        sendp(pkt, iface=args.iface, verbose=False)
        time.sleep(args.wait_seconds)
    finally:
        tcpdump.terminate()
        try:
            tcpdump.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tcpdump.kill()
            tcpdump.wait(timeout=5)

    reply = parse_reply(args.pcap_out, xid)
    if reply is None:
        emit("got_reply", "0")
        return 0

    emit("got_reply", "1")
    dhcp_layer = reply[DHCP]
    # Each entry in dhcp_layer.options is a tuple of (name, *values) --
    # NOT (name, value): confirmed directly that scapy represents an
    # option carrying more than one same-typed value (e.g. option 6 with
    # both a primary and secondary DNS server packed into one TLV) as
    # extra trailing tuple elements rather than a single list-valued
    # second element, e.g. ('name_server', '172.29.198.10',
    # '172.29.198.11'). Capturing opt[1:] instead of just opt[1] is what
    # makes the dns_servers extraction below see both configured LanCache
    # DNS IPs instead of silently dropping every one but the first.
    opts = {opt[0]: opt[1:] for opt in dhcp_layer.options if isinstance(opt, tuple)}

    if "message-type" in opts:
        # Left as dnsmasq's raw numeric DHCP message-type code (2=Offer)
        # rather than decoded to a keyword: confirmed directly that scapy
        # does not apply its own ByteEnumField-name mapping when
        # dissecting an option list off the wire this way, only when a
        # packet is constructed from Python. "2" is DHCPOFFER regardless.
        emit("message_type", str(opts["message-type"][0]))
    if "server_id" in opts:
        emit("server_id", str(opts["server_id"][0]))
    if "name_server" in opts:
        emit("dns_servers", ",".join(str(v) for v in opts["name_server"]))

    siaddr = reply[BOOTP].siaddr
    if siaddr and siaddr != "0.0.0.0":
        emit("siaddr", siaddr)

    file_field = reply[BOOTP].file
    if isinstance(file_field, bytes):
        file_field = file_field.rstrip(b"\x00").decode("ascii", errors="replace")
    if file_field:
        emit("file", file_field)

    return 0


if __name__ == "__main__":
    sys.exit(main())
