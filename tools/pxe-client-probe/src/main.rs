//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Synthetic PXE-client DHCPDISCOVER probe for scripts/dhcp-proxy-pxe-
//! simulation.sh (issue #705). No off-the-shelf DHCP client (dhclient,
//! udhcpc, ...) can be made to send a real PXE-tagged DHCPDISCOVER (DHCP
//! option 60=PXEClient, option 93=client-system-architecture) -- that is
//! exactly the packet shape a real PXE ROM sends and the shape this
//! project's services/dhcp-proxy code path (dnsmasq ProxyDHCP mode) only
//! ever reacts to, so the original issue's own suggested approach (and this
//! investigation's confirmation of the underlying bug) both required
//! crafting one directly. The frame is built by hand and sent raw over the
//! interface via pnet_datalink's layer-2 channel; replies are captured
//! separately via a tcpdump-written pcap file rather than any live
//! in-process capture -- see tools/build-tools/Dockerfile's comment on the
//! tcpdump package for why: an in-process live sniff was confirmed, during
//! this issue's investigation, to miss real replies from this project's
//! exact dnsmasq build that tcpdump itself captured without any trouble. The
//! flakiness was always a *capture* problem, never a *send* problem, so
//! replacing the former scapy sendp with a raw pnet_datalink send is
//! faithful and keeping tcpdump for capture preserves the exact workaround.
//!
//! Prints the parsed result as shell-safe KEY='value' lines on stdout, one
//! recognized field per line, mirroring the convention
//! scripts/lib/dhcp-lease-parse.sh already established for the Kea
//! lease-flow simulation -- a key is simply absent from the output if this
//! probe never received it, callers must not assume every key is present.
//!
//! Recognized output keys:
//!   got_reply     -- "1" if any BOOTP/DHCP reply matching this probe's own
//!                    xid was captured at all (op=BOOTREPLY), "0" otherwise.
//!   message_type  -- raw numeric DHCP message-type option (53), e.g. "2"
//!                    for DHCPOFFER. Left as the raw wire byte, not decoded
//!                    to a keyword; "2" is DHCPOFFER regardless.
//!   server_id     -- option 54 (server identifier), the IP address of the
//!                    dnsmasq container that answered.
//!   dns_servers   -- option 6 (domain-name-servers), comma-separated. The
//!                    option value is parsed in 4-byte chunks so every
//!                    configured server is emitted, not just the first --
//!                    the DNS-injection check is the base ask of issue #705.
//!   siaddr        -- the reply's BOOTP "next server" (siaddr) field, only
//!                    printed when non-zero. This is where dnsmasq's
//!                    dhcp-boot directive (tag-matched by client
//!                    architecture) puts the operator-configured external
//!                    PXE boot server address.
//!   file          -- the reply's BOOTP "file" field (boot filename),
//!                    trimmed of trailing NUL padding, only printed when
//!                    non-empty. This is where dhcp-boot puts the
//!                    operator-configured, architecture-specific boot
//!                    filename.

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use pnet_datalink::Channel::Ethernet;
use pnet_datalink::NetworkInterface;

// BOOTP fixed-header field offsets into the UDP payload (RFC 951 / RFC 2131).
const BOOTP_OP: usize = 0;
const BOOTP_XID: usize = 4;
const BOOTP_SIADDR: usize = 20;
const BOOTP_CHADDR: usize = 28;
const BOOTP_FILE: usize = 108;
const BOOTP_FILE_LEN: usize = 128;
// The BOOTP fixed header is 236 bytes, immediately followed by the 4-byte
// DHCP magic cookie and then the variable option list.
const BOOTP_HEADER_LEN: usize = 236;
const DHCP_MAGIC_COOKIE: [u8; 4] = [0x63, 0x82, 0x53, 0x63];
const BOOTREPLY: u8 = 2;

struct Args {
    iface: String,
    arch: u16,
    no_pxe: bool,
    pcap_out: PathBuf,
    wait_seconds: f64,
}

fn parse_args() -> Result<Args> {
    let mut iface: Option<String> = None;
    let mut arch: u16 = 0;
    let mut no_pxe = false;
    let mut pcap_out: Option<PathBuf> = None;
    let mut wait_seconds: f64 = 5.0;

    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        // next_value pulls the argument that follows a flag, failing with the
        // flag's name rather than a bare "missing value" so a malformed
        // invocation from the simulation script reports which flag broke.
        let mut next_value = |name: &str| -> Result<String> {
            it.next().ok_or_else(|| anyhow!("{name} requires a value"))
        };
        match flag.as_str() {
            "--iface" => iface = Some(next_value("--iface")?),
            "--arch" => {
                arch = next_value("--arch")?
                    .parse()
                    .context("--arch must be an integer in the range 0-65535")?
            }
            "--no-pxe" => no_pxe = true,
            "--pcap-out" => pcap_out = Some(PathBuf::from(next_value("--pcap-out")?)),
            "--wait-seconds" => {
                wait_seconds = next_value("--wait-seconds")?
                    .parse()
                    .context("--wait-seconds must be a number")?
            }
            other => bail!("unrecognized argument: {other}"),
        }
    }

    Ok(Args {
        iface: iface.ok_or_else(|| anyhow!("--iface is required"))?,
        arch,
        no_pxe,
        pcap_out: pcap_out.ok_or_else(|| anyhow!("--pcap-out is required"))?,
        wait_seconds,
    })
}

// The internet checksum (RFC 1071): 16-bit one's-complement sum of the data,
// then complemented. A trailing odd byte is padded with a zero low byte.
fn internet_checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut chunks = data.chunks_exact(2);
    for pair in &mut chunks {
        sum += u16::from_be_bytes([pair[0], pair[1]]) as u32;
    }
    if let [last] = chunks.remainder() {
        sum += (*last as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn ipv4_header_checksum(header: &[u8]) -> u16 {
    internet_checksum(header)
}

fn udp_checksum(src: [u8; 4], dst: [u8; 4], udp_segment: &[u8]) -> u16 {
    // UDP over IPv4 checksums a pseudo-header (src, dst, zero, protocol,
    // udp-length) prepended to the UDP segment itself.
    let mut buf = Vec::with_capacity(12 + udp_segment.len());
    buf.extend_from_slice(&src);
    buf.extend_from_slice(&dst);
    buf.push(0);
    buf.push(17); // IPPROTO_UDP
    buf.extend_from_slice(&(udp_segment.len() as u16).to_be_bytes());
    buf.extend_from_slice(udp_segment);
    let sum = internet_checksum(&buf);
    // A computed UDP checksum of 0x0000 must be transmitted as 0xffff so the
    // receiver does not read it as "checksum disabled" (RFC 768).
    if sum == 0 {
        0xffff
    } else {
        sum
    }
}

// Builds the full broadcast Ethernet+IPv4+UDP+BOOTP+DHCP DISCOVER frame.
//
// flags=0x8000 (broadcast bit): this probe has no IP of its own yet
// (ciaddr/yiaddr both 0.0.0.0), exactly the real state of a PXE ROM before
// it has a lease -- the broadcast bit tells dnsmasq to reply to the all-ones
// broadcast address rather than attempt (and fail) a unicast reply to an
// address that does not exist yet.
fn build_discover(mac: [u8; 6], arch: u16, send_pxe_options: bool, xid: u32) -> Vec<u8> {
    let mut options: Vec<u8> = Vec::new();
    options.extend_from_slice(&[53, 1, 1]); // option 53 message-type = 1 (DISCOVER)
    if send_pxe_options {
        options.push(60); // vendor-class-identifier
        options.push(9);
        options.extend_from_slice(b"PXEClient");
        // Option 93 (RFC 4578 client-system-architecture): the field
        // dnsmasq's dhcp-match/pxe-service architecture matching keys off. A
        // 2-byte big-endian integer per the RFC.
        options.push(93);
        options.push(2);
        options.extend_from_slice(&arch.to_be_bytes());
        // Option 94 (client network device interface): a real PXE ROM always
        // sends this alongside option 93; included for realism even though
        // this project's dnsmasq config does not key off it. Value: UNDI,
        // major 2, minor 1 -- an arbitrary but RFC-valid NDI version, matching
        // what this issue's own investigation already sent successfully.
        options.push(94);
        options.push(3);
        options.extend_from_slice(&[0x01, 0x02, 0x01]);
    }
    options.push(255); // option 255 = end

    let mut bootp = vec![0u8; BOOTP_HEADER_LEN];
    bootp[BOOTP_OP] = 1; // op = BOOTREQUEST
    bootp[1] = 1; // htype = Ethernet
    bootp[2] = 6; // hlen = 6
    bootp[BOOTP_XID..BOOTP_XID + 4].copy_from_slice(&xid.to_be_bytes());
    bootp[10..12].copy_from_slice(&0x8000u16.to_be_bytes()); // flags: broadcast
    bootp[BOOTP_CHADDR..BOOTP_CHADDR + 6].copy_from_slice(&mac);

    let mut dhcp_payload = bootp;
    dhcp_payload.extend_from_slice(&DHCP_MAGIC_COOKIE);
    dhcp_payload.extend_from_slice(&options);

    let src_ip = [0u8, 0, 0, 0];
    let dst_ip = [255u8, 255, 255, 255];

    // UDP header (checksum field zeroed, then filled in).
    let udp_len = 8 + dhcp_payload.len();
    let mut udp = Vec::with_capacity(udp_len);
    udp.extend_from_slice(&68u16.to_be_bytes()); // sport (BOOTP client)
    udp.extend_from_slice(&67u16.to_be_bytes()); // dport (BOOTP server)
    udp.extend_from_slice(&(udp_len as u16).to_be_bytes());
    udp.extend_from_slice(&[0, 0]); // checksum placeholder
    udp.extend_from_slice(&dhcp_payload);
    let udp_ck = udp_checksum(src_ip, dst_ip, &udp);
    udp[6..8].copy_from_slice(&udp_ck.to_be_bytes());

    // IPv4 header (checksum field zeroed, then filled in).
    let total_len = 20 + udp.len();
    let mut ip = Vec::with_capacity(20);
    ip.push(0x45); // version 4, IHL 5
    ip.push(0x00); // DSCP/ECN
    ip.extend_from_slice(&(total_len as u16).to_be_bytes());
    ip.extend_from_slice(&[0, 0]); // identification
    ip.extend_from_slice(&[0, 0]); // flags + fragment offset
    ip.push(64); // TTL
    ip.push(17); // protocol = UDP
    ip.extend_from_slice(&[0, 0]); // header checksum placeholder
    ip.extend_from_slice(&src_ip);
    ip.extend_from_slice(&dst_ip);
    let ip_ck = ipv4_header_checksum(&ip);
    ip[10..12].copy_from_slice(&ip_ck.to_be_bytes());

    let mut frame = Vec::with_capacity(14 + ip.len() + udp.len());
    frame.extend_from_slice(&[0xff; 6]); // dst MAC: broadcast
    frame.extend_from_slice(&mac); // src MAC
    frame.extend_from_slice(&[0x08, 0x00]); // ethertype: IPv4
    frame.extend_from_slice(&ip);
    frame.extend_from_slice(&udp);
    frame
}

fn find_interface(name: &str) -> Result<NetworkInterface> {
    pnet_datalink::interfaces()
        .into_iter()
        .find(|iface| iface.name == name)
        .ok_or_else(|| anyhow!("interface {name} not found"))
}

fn interface_mac(iface: &NetworkInterface) -> Result<[u8; 6]> {
    let mac = iface
        .mac
        .ok_or_else(|| anyhow!("interface {} has no MAC address", iface.name))?;
    Ok([mac.0, mac.1, mac.2, mac.3, mac.4, mac.5])
}

fn send_frame(iface: &NetworkInterface, frame: &[u8]) -> Result<()> {
    let (mut tx, _rx) = match pnet_datalink::channel(iface, Default::default())
        .with_context(|| format!("opening a datalink channel on {}", iface.name))?
    {
        Ethernet(tx, rx) => (tx, rx),
        _ => bail!("interface {} did not yield an Ethernet channel", iface.name),
    };
    tx.send_to(frame, None)
        .ok_or_else(|| anyhow!("datalink send returned no result"))?
        .context("sending the DISCOVER frame")
}

// Stops the tcpdump capture, mirroring the Python version's terminate()-then-
// kill() sequence: SIGTERM first for a clean pcap flush, escalating to
// SIGKILL only if it does not exit within a few seconds.
fn stop_tcpdump(child: &mut std::process::Child) {
    // SAFETY: kill(2) with a pid this process just spawned and a standard
    // signal number is a well-defined libc call with no memory effects.
    unsafe {
        libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => sleep(Duration::from_millis(100)),
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

// Returns the IPv4 packet bytes carried by one captured link-layer frame, or
// None if it is not IPv4. linktype 1 (EN10MB) is the normal case for a
// tcpdump `-i eth0` capture; linktype 113 (LINUX_SLL) is handled defensively
// in case the capture ever runs on a cooked-mode interface, since silently
// returning None there would look identical to "no reply arrived".
fn ipv4_payload(linktype: u32, frame: &[u8]) -> Option<&[u8]> {
    match linktype {
        1 => {
            if frame.len() < 14 {
                return None;
            }
            let mut ethertype = u16::from_be_bytes([frame[12], frame[13]]);
            let mut offset = 14;
            // Skip a single 802.1Q VLAN tag if present.
            if ethertype == 0x8100 && frame.len() >= 18 {
                ethertype = u16::from_be_bytes([frame[16], frame[17]]);
                offset = 18;
            }
            if ethertype != 0x0800 {
                return None;
            }
            frame.get(offset..)
        }
        113 => {
            if frame.len() < 16 {
                return None;
            }
            if u16::from_be_bytes([frame[14], frame[15]]) != 0x0800 {
                return None;
            }
            frame.get(16..)
        }
        _ => None,
    }
}

// Returns the UDP payload (the BOOTP/DHCP bytes) of an IPv4/UDP packet.
fn udp_payload(ipv4: &[u8]) -> Option<&[u8]> {
    if ipv4.len() < 20 || (ipv4[0] >> 4) != 4 {
        return None;
    }
    let ihl = ((ipv4[0] & 0x0f) as usize) * 4;
    if ipv4[9] != 17 || ipv4.len() < ihl + 8 {
        return None; // not UDP, or truncated
    }
    ipv4.get(ihl + 8..)
}

// Scans a captured pcap for the first BOOTREPLY (op=2) whose xid matches this
// probe's own, returning its BOOTP/DHCP payload. Filtering on op=2 discards
// the probe's own DISCOVER (op=1), which the same capture also holds because
// tcpdump listens on both port 67 and 68 for the full exchange.
fn parse_reply(pcap: &[u8], xid: u32) -> Result<Option<Vec<u8>>> {
    if pcap.len() < 24 {
        bail!("pcap file is shorter than its 24-byte global header");
    }
    // Classic pcap magic identifies byte order (and us/ns timestamp
    // precision, which this probe does not use).
    let (little_endian, _nanos) = match pcap[0..4] {
        [0xd4, 0xc3, 0xb2, 0xa1] => (true, false),
        [0xa1, 0xb2, 0xc3, 0xd4] => (false, false),
        [0x4d, 0x3c, 0xb2, 0xa1] => (true, true),
        [0xa1, 0xb2, 0x3c, 0x4d] => (false, true),
        _ => bail!("unrecognized pcap magic number"),
    };
    let read_u32 = |bytes: &[u8]| -> u32 {
        if little_endian {
            u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
        } else {
            u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
        }
    };
    let linktype = read_u32(&pcap[20..24]);

    let mut pos = 24;
    while pos + 16 <= pcap.len() {
        let incl_len = read_u32(&pcap[pos + 8..pos + 12]) as usize;
        let data_start = pos + 16;
        let data_end = data_start + incl_len;
        if data_end > pcap.len() {
            break; // truncated final record
        }
        let frame = &pcap[data_start..data_end];
        pos = data_end;

        let Some(ipv4) = ipv4_payload(linktype, frame) else {
            continue;
        };
        let Some(payload) = udp_payload(ipv4) else {
            continue;
        };
        if payload.len() < BOOTP_HEADER_LEN {
            continue;
        }
        if payload[BOOTP_OP] != BOOTREPLY {
            continue;
        }
        let reply_xid = u32::from_be_bytes([
            payload[BOOTP_XID],
            payload[BOOTP_XID + 1],
            payload[BOOTP_XID + 2],
            payload[BOOTP_XID + 3],
        ]);
        if reply_xid == xid {
            return Ok(Some(payload.to_vec()));
        }
    }
    Ok(None)
}

// Returns the value bytes of the first occurrence of a DHCP option in the
// option list (everything after the magic cookie). Pad (0) options are
// skipped and End (255) terminates the scan.
fn dhcp_option(options: &[u8], code: u8) -> Option<&[u8]> {
    let mut pos = 0;
    while pos < options.len() {
        let opt = options[pos];
        if opt == 0 {
            pos += 1;
            continue;
        }
        if opt == 255 {
            break;
        }
        if pos + 1 >= options.len() {
            break;
        }
        let len = options[pos + 1] as usize;
        let value_start = pos + 2;
        let value_end = value_start + len;
        if value_end > options.len() {
            break;
        }
        if opt == code {
            return Some(&options[value_start..value_end]);
        }
        pos = value_end;
    }
    None
}

fn format_ipv4(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| b.to_string())
        .collect::<Vec<_>>()
        .join(".")
}

fn emit(key: &str, value: &str) {
    // DHCP field values here (IP addresses, filenames, message-type codes)
    // never contain a single quote, so no escaping beyond wrapping in one is
    // needed -- matching scripts/lib/dhcp-lease-parse.sh's own emit helper.
    println!("{key}='{value}'");
}

// Emits the recognized KEY='value' fields of a captured reply. Split out from
// main so it can be unit-tested against a canned BOOTP/DHCP payload without a
// live capture.
fn emit_reply_fields(payload: &[u8]) {
    let options = &payload[BOOTP_HEADER_LEN..];
    // The option list starts after the 4-byte magic cookie; a reply without a
    // valid cookie carries no options this probe can read.
    let options = if options.len() >= 4 && options[0..4] == DHCP_MAGIC_COOKIE {
        &options[4..]
    } else {
        &[][..]
    };

    if let Some(mt) = dhcp_option(options, 53) {
        if let Some(code) = mt.first() {
            emit("message_type", &code.to_string());
        }
    }
    if let Some(sid) = dhcp_option(options, 54) {
        if sid.len() == 4 {
            emit("server_id", &format_ipv4(sid));
        }
    }
    if let Some(dns) = dhcp_option(options, 6) {
        // Option 6 packs one or more 4-byte servers into a single TLV. Emit
        // every 4-byte chunk, comma-joined -- dropping all but the first is
        // exactly the bug issue #705's DNS check exists to catch.
        let servers: Vec<String> = dns.chunks_exact(4).map(format_ipv4).collect();
        if !servers.is_empty() {
            emit("dns_servers", &servers.join(","));
        }
    }

    let siaddr = &payload[BOOTP_SIADDR..BOOTP_SIADDR + 4];
    if siaddr != [0u8; 4] {
        emit("siaddr", &format_ipv4(siaddr));
    }

    let file_field = &payload[BOOTP_FILE..BOOTP_FILE + BOOTP_FILE_LEN];
    let trimmed: &[u8] = match file_field.iter().rposition(|&b| b != 0) {
        Some(last) => &file_field[..=last],
        None => &[],
    };
    if !trimmed.is_empty() {
        emit("file", &String::from_utf8_lossy(trimmed));
    }
}

fn run(args: Args) -> Result<()> {
    let iface = find_interface(&args.iface)?;
    let mac = interface_mac(&iface)?;

    // A time-derived, non-zero xid uniquely tags this probe's exchange so its
    // own reply can be told apart from any other DHCP traffic on the segment,
    // without pulling in an RNG dependency.
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(1);
    let xid = nanos | 1;

    let frame = build_discover(mac, args.arch, !args.no_pxe, xid);

    let pcap_out = args
        .pcap_out
        .to_str()
        .ok_or_else(|| anyhow!("--pcap-out path is not valid UTF-8"))?;
    // -U (packet-buffered) so the pcap file is flushed to disk as packets
    // arrive rather than only on tcpdump's own internal buffer/exit -- this
    // probe stops the process well before any such buffer would naturally
    // flush otherwise, and reading a not-yet-flushed pcap file would silently
    // look identical to "no reply was ever sent".
    let mut tcpdump = Command::new("tcpdump")
        .args([
            "-i",
            &args.iface,
            "-w",
            pcap_out,
            "-U",
            "port",
            "67",
            "or",
            "port",
            "68",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to spawn tcpdump")?;

    // Give tcpdump time to actually attach to the interface before the
    // DISCOVER goes out -- sending immediately risks a race where the reply
    // arrives before the capture has started.
    sleep(Duration::from_secs(1));
    let send_result = send_frame(&iface, &frame);
    // Always give the reply a chance to land and always stop tcpdump, even if
    // the send itself failed, so the capture file is finalized before it is
    // read (and so a spawned tcpdump is never left running).
    if send_result.is_ok() {
        sleep(Duration::from_secs_f64(args.wait_seconds));
    }
    stop_tcpdump(&mut tcpdump);
    send_result?;

    let pcap = fs::read(&args.pcap_out)
        .with_context(|| format!("reading capture file {}", args.pcap_out.display()))?;
    let reply = parse_reply(&pcap, xid)?;
    match reply {
        None => emit("got_reply", "0"),
        Some(payload) => {
            emit("got_reply", "1");
            emit_reply_fields(&payload);
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    run(parse_args()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Builds a minimal BOOTREPLY BOOTP/DHCP payload for the parser tests:
    // siaddr, boot filename, and options 53/54/6 (the last carrying two DNS
    // servers) -- the exact fields the simulation script asserts on.
    fn sample_reply(xid: u32) -> Vec<u8> {
        let mut payload = vec![0u8; BOOTP_HEADER_LEN];
        payload[BOOTP_OP] = BOOTREPLY;
        payload[BOOTP_XID..BOOTP_XID + 4].copy_from_slice(&xid.to_be_bytes());
        payload[BOOTP_SIADDR..BOOTP_SIADDR + 4].copy_from_slice(&[172, 29, 5, 50]);
        let name = b"lancache-pxe705-uefi.efi";
        payload[BOOTP_FILE..BOOTP_FILE + name.len()].copy_from_slice(name);
        payload.extend_from_slice(&DHCP_MAGIC_COOKIE);
        payload.extend_from_slice(&[53, 1, 2]); // DHCPOFFER
        payload.extend_from_slice(&[54, 4, 172, 29, 5, 2]); // server id
        payload.extend_from_slice(&[6, 8, 172, 29, 5, 10, 172, 29, 5, 11]); // two DNS
        payload.push(255);
        payload
    }

    // Verifies option 6 with two packed servers yields BOTH addresses
    // comma-joined -- the specific multi-value case the former scapy probe
    // silently truncated and the core check of issue #705.
    #[test]
    fn dns_servers_option_keeps_every_value() {
        let payload = sample_reply(0x11223344);
        let options = &payload[BOOTP_HEADER_LEN + 4..];
        let dns = dhcp_option(options, 6).expect("option 6 present");
        let servers: Vec<String> = dns.chunks_exact(4).map(format_ipv4).collect();
        assert_eq!(servers.join(","), "172.29.5.10,172.29.5.11");
    }

    // Verifies single-value options 53 (message-type) and 54 (server id) and
    // the BOOTP siaddr/file fixed fields decode to the expected wire values.
    #[test]
    fn single_value_options_and_bootp_fields_decode() {
        let payload = sample_reply(0x1);
        let options = &payload[BOOTP_HEADER_LEN + 4..];
        assert_eq!(dhcp_option(options, 53).unwrap(), &[2]);
        assert_eq!(format_ipv4(dhcp_option(options, 54).unwrap()), "172.29.5.2");
        assert_eq!(
            format_ipv4(&payload[BOOTP_SIADDR..BOOTP_SIADDR + 4]),
            "172.29.5.50"
        );
        let file_field = &payload[BOOTP_FILE..BOOTP_FILE + BOOTP_FILE_LEN];
        let last = file_field.iter().rposition(|&b| b != 0).unwrap();
        assert_eq!(&file_field[..=last], b"lancache-pxe705-uefi.efi");
    }

    // Wraps a frame in a valid little-endian classic-pcap container so
    // parse_reply can be exercised end to end without a live tcpdump capture.
    fn wrap_pcap(linktype: u32, frame: &[u8]) -> Vec<u8> {
        let mut pcap = Vec::new();
        pcap.extend_from_slice(&[0xd4, 0xc3, 0xb2, 0xa1]); // LE magic
        pcap.extend_from_slice(&2u16.to_le_bytes()); // version major
        pcap.extend_from_slice(&4u16.to_le_bytes()); // version minor
        pcap.extend_from_slice(&0u32.to_le_bytes()); // thiszone
        pcap.extend_from_slice(&0u32.to_le_bytes()); // sigfigs
        pcap.extend_from_slice(&65535u32.to_le_bytes()); // snaplen
        pcap.extend_from_slice(&linktype.to_le_bytes());
        pcap.extend_from_slice(&0u32.to_le_bytes()); // ts_sec
        pcap.extend_from_slice(&0u32.to_le_bytes()); // ts_usec
        pcap.extend_from_slice(&(frame.len() as u32).to_le_bytes()); // incl_len
        pcap.extend_from_slice(&(frame.len() as u32).to_le_bytes()); // orig_len
        pcap.extend_from_slice(frame);
        pcap
    }

    // Wraps a BOOTP/DHCP payload in Ethernet/IPv4/UDP so the full capture
    // parse path (linktype -> ethertype -> IHL -> UDP -> BOOTP) is covered.
    fn ethernet_udp_frame(payload: &[u8]) -> Vec<u8> {
        let mut frame = Vec::new();
        frame.extend_from_slice(&[0xff; 6]); // dst MAC
        frame.extend_from_slice(&[0x02, 0, 0, 0, 0, 1]); // src MAC
        frame.extend_from_slice(&[0x08, 0x00]); // IPv4
        let udp_len = 8 + payload.len();
        let mut ip = vec![0x45, 0x00];
        ip.extend_from_slice(&((20 + udp_len) as u16).to_be_bytes());
        ip.extend_from_slice(&[0, 0, 0, 0, 64, 17, 0, 0]);
        ip.extend_from_slice(&[172, 29, 5, 2]); // src
        ip.extend_from_slice(&[255, 255, 255, 255]); // dst
        frame.extend_from_slice(&ip);
        frame.extend_from_slice(&67u16.to_be_bytes()); // sport
        frame.extend_from_slice(&68u16.to_be_bytes()); // dport
        frame.extend_from_slice(&(udp_len as u16).to_be_bytes());
        frame.extend_from_slice(&[0, 0]); // udp checksum (unchecked on read)
        frame.extend_from_slice(payload);
        frame
    }

    // parse_reply must return the reply whose xid matches and ignore both a
    // request (op=1) and a reply carrying a different xid, since the same
    // capture legitimately holds all three.
    #[test]
    fn parse_reply_matches_only_own_xid_and_bootreply() {
        let xid = 0xAABBCCDD;
        let reply = sample_reply(xid);
        let pcap = wrap_pcap(1, &ethernet_udp_frame(&reply));
        let found = parse_reply(&pcap, xid).unwrap().expect("reply found");
        assert_eq!(found[BOOTP_OP], BOOTREPLY);

        // Wrong xid -> no match.
        assert!(parse_reply(&pcap, 0x00000001).unwrap().is_none());

        // Same xid but a BOOTREQUEST (op=1) -> no match.
        let mut request = sample_reply(xid);
        request[BOOTP_OP] = 1;
        let req_pcap = wrap_pcap(1, &ethernet_udp_frame(&request));
        assert!(parse_reply(&req_pcap, xid).unwrap().is_none());
    }

    // The IPv4 header and UDP checksums the DISCOVER carries must verify to
    // zero when re-summed including the checksum field -- proof dnsmasq will
    // accept the crafted frame rather than drop it as corrupt.
    #[test]
    fn discover_checksums_are_valid() {
        let frame = build_discover([0x02, 0, 0, 0, 0, 1], 7, true, 0x1234);
        let ip = &frame[14..34];
        assert_eq!(internet_checksum(ip), 0);

        let udp = &frame[34..];
        let mut pseudo = Vec::new();
        pseudo.extend_from_slice(&[0, 0, 0, 0]); // src 0.0.0.0
        pseudo.extend_from_slice(&[255, 255, 255, 255]); // dst
        pseudo.push(0);
        pseudo.push(17);
        pseudo.extend_from_slice(&(udp.len() as u16).to_be_bytes());
        pseudo.extend_from_slice(udp);
        assert_eq!(internet_checksum(&pseudo), 0);
    }
}
