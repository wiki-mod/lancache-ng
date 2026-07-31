//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Native DHCPv4 probe (issue #1288): replaces the former `dhcp-probe.sh`
//! script's dependence on two now-EOL/no-longer-packaged external tools --
//! `nmap --script broadcast-dhcp-discover` (rogue/conflicting DHCP server
//! detection) and ISC `dhclient -1` (a bounded, non-binding client dry-run)
//! -- with a from-scratch DHCPv4 client speaking the wire protocol
//! directly. `dhcproto` (a pure DHCPv4/v6 wire-format encode/decode crate,
//! not a client with its own socket/state-machine handling -- see
//! Cargo.toml's dependency comment for why this was chosen over `mozim`,
//! the issue's other researched candidate) handles message encode/decode;
//! this module owns broadcast UDP socket lifecycle, timeouts, and result
//! extraction.
//!
//! ISC DHCP (including `dhclient`) reached end-of-life at the end of 2022
//! (ISC's own words: "should not be used in production any longer"), and
//! `dhclient`/`isc-dhcp-client`/`nmap` have since been dropped from current
//! Alpine package repos entirely -- see issue #1288 for the full
//! background and the maintainer's decision to go fully native rather than
//! swap in a different external tool.
//!
//! ## Both required checks come from ONE broadcast round
//!
//! The original script ran two *sequential* tools: nmap's own 5s broadcast
//! scan, then a separate `dhclient` invocation with its own up-to-60s
//! no-offer timeout -- up to ~65s worst case (see routes/dhcp.rs's own
//! `DHCP_PROBE_WAIT_TIMEOUT` comment, since renumbered for this change).
//! This module instead performs ONE discovery phase (a handful of broadcast
//! DHCPDISCOVER retransmits sharing one transaction ID, all within one
//! bounded window -- see [`DISCOVER_RETRANSMITS`]) and reuses its results
//! for both checks, a deliberate improvement, not just a reimplementation:
//! - every DHCPOFFER received within `DISCOVER_WINDOW` answers the
//!   rogue/conflict-detection requirement (nmap's former role), and
//! - a REQUEST/ACK exchange against the FIRST offer received (matching
//!   normal DHCP client behavior, and `dhclient`'s own "accept the first
//!   offer" default) answers the client-dry-run requirement (dhclient's
//!   former role).
//!
//! A successfully-negotiated dry-run lease is released (DHCPRELEASE)
//! immediately after being confirmed, rather than left allocated in the
//! server's pool for its full lease time as `dhclient -1`'s dry-run always
//! did -- a deliberate hygiene improvement over the previous behavior, not
//! parity with it (see issue #1288's implementation notes).
//!
//! Never binds the negotiated lease to a real network interface: this
//! module only ever reads/writes UDP socket bytes -- it never calls into
//! any interface-configuration API -- matching `dhclient -1 -sf
//! /bin/true`'s existing "never touches the real interface config"
//! property (see the former dhcp-probe.sh's own comment on that
//! invocation).
//!
//! ## Wire boundary to routes/dhcp.rs
//!
//! This binary is invoked as the `dhcp-probe` container's entrypoint via
//! `lancache-ui --dhcp-probe` (see main.rs), replacing the compose file's
//! former `dhcp-probe.sh` entrypoint override. It prints exactly two lines
//! to stdout: `DHCP_PROBE_START_MARKER` (kept for parity with
//! routes/dhcp.rs's existing `current_probe_output` staleness guard, which
//! discards any container log content from a previous run still visible
//! through Docker's own second-granularity `since` log filter -- see
//! run_dhcp_probe's comment there) followed by one line containing
//! `DHCP_PROBE_RESULT_MARKER` and a single-line JSON-encoded [`ProbeReport`].
//! routes/dhcp.rs deserializes that JSON directly into this same
//! [`ProbeReport`] type -- real Rust types on both sides of the process
//! boundary, not text-marker scraping -- and maps it onto the existing
//! `DhcpCheckReport`/`DhcpConflictCheckStatus`/`DhcpClientCheckStatus`
//! types the Admin UI template already renders, so `dhcp.html` needed no
//! changes.

use dhcproto::v4::{DhcpOption, Flags, Message, MessageType, OptionCode};
use dhcproto::{Decodable, Decoder, Encodable, Encoder};
use serde::{Deserialize, Serialize};
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::time::{Duration, Instant};

/// Client UDP port a DHCPv4 client sends from / listens on (RFC 2131).
const DHCP_CLIENT_PORT: u16 = 68;
/// Server UDP port every DHCPv4 server/relay listens on (RFC 2131).
const DHCP_SERVER_PORT: u16 = 67;

/// How long to keep listening for DHCPOFFERs after the broadcast
/// DHCPDISCOVER (see the module doc comment: this window must be waited in
/// full every run, not cut short by the first response, since collecting
/// EVERY offering server -- not just the fastest one -- is the whole point
/// of the rogue/conflict-detection check). Matches nmap's own
/// `broadcast-dhcp-discover.timeout=5` default that the former
/// dhcp-probe.sh set explicitly, so this pass keeps the same real-world
/// wait time an operator was already used to.
pub const DISCOVER_WINDOW: Duration = Duration::from_secs(5);

/// Bound on the REQUEST/ACK dry-run exchange that follows a received offer.
/// A real DHCP server that just answered a broadcast DISCOVER within the
/// same few seconds should ACK a REQUEST almost immediately; 3s leaves
/// comfortable margin over LAN latency without meaningfully lengthening a
/// worst-case run (worst case is now DISCOVER_WINDOW + REQUEST_TIMEOUT ≈
/// 8s total, versus the former script's ~65s worst case -- see
/// routes/dhcp.rs's `DHCP_PROBE_WAIT_TIMEOUT` comment for the container-wait
/// ceiling this feeds into).
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

/// Marker line printed before the JSON result line, kept only so
/// routes/dhcp.rs's existing `current_probe_output` staleness guard (a
/// second layer of defense behind Docker's own second-granularity `since`
/// log filter -- see run_dhcp_probe's comment) keeps working unchanged.
pub const DHCP_PROBE_START_MARKER: &str = "__LANCACHE_DHCP_PROBE_START__";
/// Prefix of the single line carrying this run's JSON-encoded [`ProbeReport`].
pub const DHCP_PROBE_RESULT_MARKER: &str = "__LANCACHE_DHCP_PROBE_RESULT_JSON__";

/// One negotiated/offered lease's fields -- the union of what the former
/// nmap-offer-detail table (`DHCP_OFFER_DETAIL_LABELS`) and
/// dhclient-lease-detail table (`DHCP_LEASE_DETAIL_LABELS`) in
/// routes/dhcp.rs each captured from two differently-formatted text
/// sources. Kept as a single struct here (rather than two, as those two
/// label tables were) because a decoded DHCPOFFER and a decoded DHCPACK
/// both come from the exact same `dhcproto::v4::Message` option set --
/// only the *display* label wording differs by call site, which
/// routes/dhcp.rs still owns via its own two label tables.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct LeaseInfo {
    pub offered_ip: Option<Ipv4Addr>,
    pub server_identifier: Option<Ipv4Addr>,
    pub subnet_mask: Option<Ipv4Addr>,
    pub router: Option<Ipv4Addr>,
    pub dns_servers: Vec<Ipv4Addr>,
    pub domain_name: Option<String>,
    pub broadcast_address: Option<Ipv4Addr>,
    pub lease_time_secs: Option<u32>,
    pub renewal_time_secs: Option<u32>,
    pub rebinding_time_secs: Option<u32>,
}

/// Rogue/conflict-detection outcome (nmap's former role). Mirrors
/// routes/dhcp.rs's `DhcpConflictCheckStatus` shape (`Found`/`NotFound`/
/// `Unavailable`) deliberately, so mapping one onto the other there is a
/// direct field copy, not a re-derivation.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ConflictOutcome {
    Found { offers: Vec<LeaseInfo> },
    NotFound,
    Unavailable { reason: String },
}

/// Client-dry-run outcome (dhclient's former role). Mirrors
/// routes/dhcp.rs's `DhcpClientCheckStatus` shape for the same reason as
/// [`ConflictOutcome`] above.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ClientOutcome {
    Passed { lease: LeaseInfo },
    Failed { reason: String },
    Unavailable { reason: String },
}

/// Full result of one probe run -- the JSON payload printed after
/// [`DHCP_PROBE_RESULT_MARKER`] and deserialized directly by
/// routes/dhcp.rs's `parse_dhcp_probe_report`.
#[derive(Debug, Serialize, Deserialize)]
pub struct ProbeReport {
    pub conflict: ConflictOutcome,
    pub client: ClientOutcome,
}

/// Generates a random, locally-administered, unicast Ethernet address for
/// this probe run's `chaddr`. A real interface MAC is deliberately NOT read
/// here: with the DHCP broadcast flag set (see `build_discover`), a
/// conforming server replies via L2/L3 broadcast, not a unicast frame
/// addressed to our MAC, so no real hardware address is needed for the
/// response to reach us -- and using a synthetic, per-run address avoids
/// any chance of this diagnostic probe being confused with a real device
/// requesting/holding a lease under its own identity. Setting the
/// locally-administered bit (the second-least-significant bit of the first
/// octet, IEEE 802-2014 §8.2.1) and clearing the multicast bit (the
/// least-significant bit) marks this as a valid unicast address in the
/// space IEEE reserves for exactly this kind of non-vendor-assigned,
/// software-generated use.
fn random_locally_administered_mac() -> [u8; 6] {
    let mut mac: [u8; 6] = rand::random();
    mac[0] = (mac[0] | 0x02) & !0x01;
    mac
}

/// Builds the standard PRL (Parameter Request List) this probe asks every
/// offering server for -- exactly the fields [`LeaseInfo`] can carry, so
/// nothing requested here goes unused and nothing [`lease_info_from_message`]
/// reads is left unrequested (a server MAY include unrequested options
/// anyway, but SHOULD prioritize the PRL -- RFC 2132 §9.8).
fn parameter_request_list() -> Vec<OptionCode> {
    vec![
        OptionCode::SubnetMask,
        OptionCode::Router,
        OptionCode::DomainNameServer,
        OptionCode::DomainName,
        OptionCode::BroadcastAddr,
        OptionCode::AddressLeaseTime,
        OptionCode::Renewal,
        OptionCode::Rebinding,
    ]
}

/// Builds a DHCPDISCOVER: broadcast flag set (required, since this client
/// has no IP yet and cannot receive a unicast reply -- RFC 2131 §4.1), no
/// requested IP (this is a first-contact discovery, not a renewal).
fn build_discover(xid: u32, chaddr: &[u8; 6]) -> Message {
    let mut msg = Message::new_with_id(
        xid,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        chaddr,
    );
    msg.set_flags(Flags::default().set_broadcast());
    msg.opts_mut()
        .insert(DhcpOption::MessageType(MessageType::Discover));
    msg.opts_mut()
        .insert(DhcpOption::ParameterRequestList(parameter_request_list()));
    msg
}

/// Builds a DHCPREQUEST in the RFC 2131 §4.3.2 "SELECTING" state: answers a
/// specific server's DHCPOFFER by name (server identifier option) and asks
/// for the specific address it offered (requested IP address option).
/// `ciaddr` stays 0.0.0.0 and the broadcast flag stays set for the same
/// reason as the DISCOVER above -- this client never has a real bound
/// address at any point in this exchange. Returns `None` if the offer is
/// missing either field a SELECTING-state REQUEST requires -- the caller
/// treats that as a failed dry-run rather than sending a malformed request.
fn build_request(xid: u32, chaddr: &[u8; 6], offer: &LeaseInfo) -> Option<Message> {
    let requested_ip = offer.offered_ip?;
    let server_id = offer.server_identifier?;

    let mut msg = Message::new_with_id(
        xid,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        chaddr,
    );
    msg.set_flags(Flags::default().set_broadcast());
    msg.opts_mut()
        .insert(DhcpOption::MessageType(MessageType::Request));
    msg.opts_mut()
        .insert(DhcpOption::RequestedIpAddress(requested_ip));
    msg.opts_mut()
        .insert(DhcpOption::ServerIdentifier(server_id));
    msg.opts_mut()
        .insert(DhcpOption::ParameterRequestList(parameter_request_list()));
    Some(msg)
}

/// Builds a DHCPRELEASE for the lease this dry-run just confirmed --
/// returns the address to the server's pool instead of leaving it allocated
/// for its full lease time (see the module doc comment's "hygiene
/// improvement" note). Unlike DISCOVER/REQUEST, a RELEASE is unicast with a
/// real `ciaddr` per RFC 2131 §4.4.4 -- but this probe never binds that
/// address to a real interface (it only ever appears inside this one UDP
/// payload), so the "never touches the real interface config" property
/// above still holds.
fn build_release(xid: u32, chaddr: &[u8; 6], client_ip: Ipv4Addr, server_id: Ipv4Addr) -> Message {
    let mut msg = Message::new_with_id(
        xid,
        client_ip,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        Ipv4Addr::UNSPECIFIED,
        chaddr,
    );
    msg.opts_mut()
        .insert(DhcpOption::MessageType(MessageType::Release));
    msg.opts_mut()
        .insert(DhcpOption::ServerIdentifier(server_id));
    msg
}

/// Extracts every field [`LeaseInfo`] carries from a decoded DHCPOFFER or
/// DHCPACK message's options -- both message types carry the same option
/// set for these purposes, so one extractor serves both call sites (see
/// the struct's own doc comment).
fn lease_info_from_message(msg: &Message) -> LeaseInfo {
    let opts = msg.opts();

    let offered_ip = (msg.yiaddr() != Ipv4Addr::UNSPECIFIED).then_some(msg.yiaddr());

    let ip_opt = |code: OptionCode| -> Option<Ipv4Addr> {
        match opts.get(code) {
            Some(DhcpOption::ServerIdentifier(addr)) => Some(*addr),
            Some(DhcpOption::SubnetMask(addr)) => Some(*addr),
            Some(DhcpOption::BroadcastAddr(addr)) => Some(*addr),
            _ => None,
        }
    };
    let ip_list_first = |code: OptionCode| -> Option<Ipv4Addr> {
        match opts.get(code) {
            Some(DhcpOption::Router(addrs)) => addrs.first().copied(),
            _ => None,
        }
    };
    let dns_servers = match opts.get(OptionCode::DomainNameServer) {
        Some(DhcpOption::DomainNameServer(addrs)) => addrs.clone(),
        _ => Vec::new(),
    };
    let domain_name = match opts.get(OptionCode::DomainName) {
        Some(DhcpOption::DomainName(name)) => Some(name.clone()),
        _ => None,
    };
    let u32_opt = |code: OptionCode| -> Option<u32> {
        match opts.get(code) {
            Some(DhcpOption::AddressLeaseTime(secs)) => Some(*secs),
            Some(DhcpOption::Renewal(secs)) => Some(*secs),
            Some(DhcpOption::Rebinding(secs)) => Some(*secs),
            _ => None,
        }
    };

    LeaseInfo {
        offered_ip,
        server_identifier: ip_opt(OptionCode::ServerIdentifier),
        subnet_mask: ip_opt(OptionCode::SubnetMask),
        router: ip_list_first(OptionCode::Router),
        dns_servers,
        domain_name,
        broadcast_address: ip_opt(OptionCode::BroadcastAddr),
        lease_time_secs: u32_opt(OptionCode::AddressLeaseTime),
        renewal_time_secs: u32_opt(OptionCode::Renewal),
        rebinding_time_secs: u32_opt(OptionCode::Rebinding),
    }
}

/// Opens this probe's one broadcast UDP socket: binds to the well-known
/// DHCP client port (68, a privileged port -- the dhcp-probe container
/// already runs as root for this exact reason, see issue #1288's
/// container/privilege-model background) and enables the socket-level
/// broadcast permission needed to send to 255.255.255.255 at all. This is
/// the ONLY interface-adjacent syscall this module makes; there is no
/// ioctl/netlink call anywhere in this file that could bind an address to a
/// real interface.
///
/// KNOWN OPEN RISK (STATUS: as of 2026-07-31, not yet ruled out on a real
/// target host): `std::net::UdpSocket` cannot set `SO_REUSEPORT` before
/// bind, so if the host's own network stack already has a process bound to
/// UDP port 68 (e.g. a host-level DHCP client actively managing the LAN
/// interface -- NetworkManager's internal client, `dhcpcd`,
/// `systemd-networkd`), this bind fails with `EADDRINUSE` and BOTH checks
/// report Unavailable. The former nmap/dhclient tools did not have this
/// exact failure mode (nmap's script and dhclient use raw/packet sockets,
/// not a bound UDP 68 listener). Checked directly on this project's own
/// runner hosts (192.168.1.229, 192.168.1.240) via `ss -ulpn`: neither had
/// anything bound to port 68 at the time of checking, so this has not been
/// observed in practice on this project's current fleet -- but it has not
/// been verified against every real deployment target either. Adding
/// `SO_REUSEPORT` support would require a new dependency (`socket2` or raw
/// `libc` calls), which is a deliberate decision to make later with real
/// evidence of the problem, not something to add speculatively here.
fn bind_probe_socket() -> io::Result<UdpSocket> {
    let socket = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, DHCP_CLIENT_PORT))?;
    socket.set_broadcast(true)?;
    Ok(socket)
}

/// How many times the DISCOVER is (re)transmitted within one
/// `DISCOVER_WINDOW`, spaced evenly across it. A single UDP broadcast can
/// legitimately be dropped (no transport-level retry, an overloaded switch,
/// a momentarily busy server) -- and for this probe's rogue-detection
/// purpose, a false "not_found" from one dropped packet is the dangerous
/// direction of error (an operator would wrongly conclude the LAN segment
/// is clear). `dhclient` mitigated this with its own internal retry loop
/// across its up-to-60s budget; this constant is this native probe's
/// equivalent within its much shorter window. Retransmitting does not
/// lengthen the overall window -- all sends and all listening happen inside
/// the same `DISCOVER_WINDOW`, so the worst-case timing math in
/// routes/dhcp.rs's `DHCP_PROBE_WAIT_TIMEOUT` comment is unaffected.
const DISCOVER_RETRANSMITS: u32 = 3;

/// Broadcasts up to [`DISCOVER_RETRANSMITS`] DHCPDISCOVERs (all sharing the
/// same `xid`, spaced evenly across `window`) and returns every distinct
/// DHCPOFFER received in response, deduplicated by server identifier so a
/// server that answers more than one retransmit isn't double-counted (not
/// just the first offer -- see the module doc comment on why the full
/// window is always used). A read timeout is (re-)armed to exactly the
/// remaining budget before each `recv_from`, since `set_read_timeout` bounds
/// a single call, not a whole loop. Decode failures and messages that don't
/// match our xid/aren't OFFERs are silently skipped, not treated as errors
/// -- a shared broadcast domain can carry unrelated DHCP traffic (other
/// clients' own DISCOVERs/ACKs) that this probe must ignore rather than
/// choke on. Returns `Err` only for a real socket-level send/configure
/// failure; a receive timeout is normal completion, not an error.
fn collect_offers(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    window: Duration,
) -> io::Result<Vec<LeaseInfo>> {
    let deadline = Instant::now() + window;
    let retransmit_interval = window / DISCOVER_RETRANSMITS;
    let broadcast_addr = SocketAddrV4::new(Ipv4Addr::BROADCAST, DHCP_SERVER_PORT);
    let mut offers = Vec::new();
    let mut seen_servers: std::collections::HashSet<Ipv4Addr> = std::collections::HashSet::new();
    let mut recv_buf = [0u8; 1500];

    for attempt in 0..DISCOVER_RETRANSMITS {
        let discover = build_discover(xid, chaddr);
        let mut send_buf = Vec::new();
        discover
            .encode(&mut Encoder::new(&mut send_buf))
            .map_err(io::Error::other)?;
        socket.send_to(&send_buf, broadcast_addr)?;

        // The last retransmit listens all the way to `deadline`; earlier
        // ones only listen until their own slice of the window ends, then
        // move on to sending the next retransmit -- `.min(deadline)` guards
        // against `retransmit_interval`'s integer-division rounding ever
        // pushing an earlier attempt's slice past the real deadline.
        let listen_until = if attempt + 1 == DISCOVER_RETRANSMITS {
            deadline
        } else {
            (Instant::now() + retransmit_interval).min(deadline)
        };

        loop {
            let remaining = listen_until.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            if socket.set_read_timeout(Some(remaining)).is_err() {
                break;
            }
            match socket.recv_from(&mut recv_buf) {
                Ok((n, _src)) => {
                    let Ok(msg) = Message::decode(&mut Decoder::new(&recv_buf[..n])) else {
                        continue;
                    };
                    if msg.xid() != xid {
                        continue;
                    }
                    let is_offer = matches!(
                        msg.opts().get(OptionCode::MessageType),
                        Some(DhcpOption::MessageType(MessageType::Offer))
                    );
                    if !is_offer {
                        continue;
                    }
                    let lease = lease_info_from_message(&msg);
                    match lease.server_identifier {
                        // A server answering a retransmit it already
                        // answered is expected DHCP behavior, not a second
                        // rogue server -- dedupe by server identifier so it
                        // is not double-listed.
                        Some(server) if !seen_servers.insert(server) => {}
                        _ => offers.push(lease),
                    }
                }
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::TimedOut =>
                {
                    break;
                }
                // Any other recv error (e.g. the socket was closed out from
                // under us) ends collection early with whatever was already
                // gathered rather than looping on a persistent error.
                Err(_) => break,
            }
        }
    }

    Ok(offers)
}

/// Waits up to `timeout` for a DHCPACK or DHCPNAK matching `xid` from
/// `expected_server`, after a DHCPREQUEST has already been sent. Returns
/// `Ok(Some(lease))` on ACK, `Ok(None)` on NAK or timeout (both are a
/// legitimate "the dry-run did not succeed" outcome, distinguished by the
/// caller for its own failure-reason text), and `Err` only for a real
/// socket-level failure.
fn wait_for_ack(
    socket: &UdpSocket,
    xid: u32,
    expected_server: Ipv4Addr,
    timeout: Duration,
) -> io::Result<Result<LeaseInfo, &'static str>> {
    let deadline = Instant::now() + timeout;
    let mut buf = [0u8; 1500];
    let mut saw_mismatched_ack = false;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(Err(if saw_mismatched_ack {
                "received an ACK, but not from the expected server identifier"
            } else {
                "no ACK received before the timeout"
            }));
        }
        socket.set_read_timeout(Some(remaining))?;
        match socket.recv_from(&mut buf) {
            Ok((n, _src)) => {
                let Ok(msg) = Message::decode(&mut Decoder::new(&buf[..n])) else {
                    continue;
                };
                if msg.xid() != xid {
                    continue;
                }
                match msg.opts().get(OptionCode::MessageType) {
                    Some(DhcpOption::MessageType(MessageType::Ack)) => {
                        let lease = lease_info_from_message(&msg);
                        // A NAK-less ACK should still genuinely come from
                        // the server we requested against -- a mismatched
                        // server identifier here would mean either a
                        // misbehaving server or a race with an unrelated
                        // exchange sharing the same broadcast domain. Noted
                        // (not just silently ignored) so a timeout that
                        // follows one still gets a specific reason instead
                        // of the generic "no ACK at all" text below.
                        if lease.server_identifier == Some(expected_server) {
                            return Ok(Ok(lease));
                        }
                        saw_mismatched_ack = true;
                    }
                    Some(DhcpOption::MessageType(MessageType::Nak)) => {
                        return Ok(Err("server sent DHCPNAK for the requested address"));
                    }
                    _ => {}
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                return Ok(Err(if saw_mismatched_ack {
                    "received an ACK, but not from the expected server identifier"
                } else {
                    "no ACK received before the timeout"
                }));
            }
            Err(e) => return Err(e),
        }
    }
}

/// Runs the REQUEST/ACK dry-run against `offer` (the first DHCPOFFER
/// collected by [`collect_offers`]), then releases the resulting lease --
/// see the module doc comment for why this differs from `dhclient -1`'s
/// leak-the-lease behavior.
///
/// `xid` MUST be the exact same transaction ID the DISCOVER/OFFER exchange
/// already used, per RFC 2131 §4.3.2 -- a SELECTING-state REQUEST is how a
/// client tells a specific server "I'm answering the OFFER you already sent
/// me for THIS transaction"; a server has no reason to honor a REQUEST
/// under a transaction ID it never offered anything for, and a conforming
/// server may silently ignore or NAK it. A fresh random xid here would
/// make every real-server dry-run fail while still passing every unit test
/// that only exercises this function's own request-building logic in
/// isolation.
fn perform_client_dry_run(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    offer: &LeaseInfo,
    timeout: Duration,
) -> ClientOutcome {
    let Some(request) = build_request(xid, chaddr, offer) else {
        return ClientOutcome::Failed {
            reason: "the DHCPOFFER was missing a requested IP or server identifier, \
                     so no DHCPREQUEST could be built"
                .to_string(),
        };
    };

    let mut buf = Vec::new();
    if let Err(e) = request.encode(&mut Encoder::new(&mut buf)) {
        return ClientOutcome::Unavailable {
            reason: format!("failed to encode DHCPREQUEST: {e}"),
        };
    }
    let broadcast_addr = SocketAddrV4::new(Ipv4Addr::BROADCAST, DHCP_SERVER_PORT);
    if let Err(e) = socket.send_to(&buf, broadcast_addr) {
        return ClientOutcome::Unavailable {
            reason: format!("failed to send DHCPREQUEST: {e}"),
        };
    }

    // server_identifier is guaranteed present here: build_request already
    // returned None above if it were missing from `offer`.
    let server_id = offer.server_identifier.expect("checked by build_request");
    let ack = match wait_for_ack(socket, xid, server_id, timeout) {
        Ok(Ok(lease)) => lease,
        Ok(Err(reason)) => {
            return ClientOutcome::Failed {
                reason: reason.to_string(),
            };
        }
        Err(e) => {
            return ClientOutcome::Unavailable {
                reason: format!("failed while waiting for DHCPACK: {e}"),
            };
        }
    };

    if let Some(client_ip) = ack.offered_ip {
        // Best-effort hygiene cleanup (see module doc comment); a failure
        // to send the RELEASE does not change the dry-run's own PASSED
        // result -- the client path itself was already proven to work by
        // the ACK above, and the server's own lease-expiry timer is a safe
        // fallback if this datagram is lost. Sent as a fresh transaction
        // (a new xid, unlike the REQUEST above): RFC 2131 §4.4.4 specifies
        // RELEASE as unicast, addressed directly to the leasing server
        // (not broadcast, unlike DISCOVER/REQUEST -- this client already
        // knows exactly which server to tell, so there is no need for
        // every other DHCP server on the segment to see it too).
        let release = build_release(rand::random(), chaddr, client_ip, server_id);
        let mut release_buf = Vec::new();
        if release.encode(&mut Encoder::new(&mut release_buf)).is_ok() {
            let release_addr = SocketAddrV4::new(server_id, DHCP_SERVER_PORT);
            let _ = socket.send_to(&release_buf, release_addr);
        }
    }

    ClientOutcome::Passed { lease: ack }
}

/// Runs the full probe: a bounded, retransmitted broadcast DHCPDISCOVER
/// phase (answers the rogue/conflict check), then a REQUEST/ACK dry-run
/// against the first offer, reusing the same transaction ID (answers the
/// client-dry-run check). Every failure path returns a fully-populated [`ProbeReport`]
/// rather than an `Err` -- this function must never fail to produce a
/// result, since main.rs's `--dhcp-probe` mode always exits 0 regardless of
/// outcome (see issues #1155/#1156: the ordered update health gate in
/// setup.sh depends on this one-shot container exiting 0 for every real
/// outcome, "unavailable" included, not just success).
pub fn run_probe(discover_window: Duration, request_timeout: Duration) -> ProbeReport {
    let socket = match bind_probe_socket() {
        Ok(socket) => socket,
        Err(e) => {
            let reason = format!("could not open a DHCP broadcast socket: {e}");
            return ProbeReport {
                conflict: ConflictOutcome::Unavailable {
                    reason: reason.clone(),
                },
                client: ClientOutcome::Unavailable { reason },
            };
        }
    };

    // Every DISCOVER retransmit, and the REQUEST that follows the first
    // offer, share this ONE transaction ID -- see perform_client_dry_run's
    // own comment on why the REQUEST specifically must not generate a new
    // one of its own.
    let xid = rand::random();
    let chaddr = random_locally_administered_mac();

    let offers = match collect_offers(&socket, xid, &chaddr, discover_window) {
        Ok(offers) => offers,
        Err(e) => {
            let reason = format!("failed to broadcast DHCPDISCOVER: {e}");
            return ProbeReport {
                conflict: ConflictOutcome::Unavailable {
                    reason: reason.clone(),
                },
                client: ClientOutcome::Unavailable { reason },
            };
        }
    };

    let conflict = if offers.is_empty() {
        ConflictOutcome::NotFound
    } else {
        ConflictOutcome::Found {
            offers: offers.clone(),
        }
    };

    let client = match offers.first() {
        None => ClientOutcome::Failed {
            reason: format!(
                "no DHCPOFFER received within {:.0}s",
                discover_window.as_secs_f64()
            ),
        },
        Some(first_offer) => {
            perform_client_dry_run(&socket, xid, &chaddr, first_offer, request_timeout)
        }
    };

    ProbeReport { conflict, client }
}

/// Entry point for `lancache-ui --dhcp-probe` (see main.rs). Runs the
/// blocking socket probe on a dedicated OS thread (this binary is normally
/// `#[tokio::main]`-async, but the probe itself has no need for async I/O)
/// and prints the two-line stdout contract documented in this module's own
/// doc comment. Always returns `Ok(())` -- see [`run_probe`]'s own comment
/// on why every outcome, including internal failures, must still exit 0.
pub fn run_cli_and_print() {
    let report = run_probe(DISCOVER_WINDOW, REQUEST_TIMEOUT);
    println!("{DHCP_PROBE_START_MARKER}");
    match serde_json::to_string(&report) {
        Ok(json) => println!("{DHCP_PROBE_RESULT_MARKER} {json}"),
        Err(e) => {
            // Only reachable if serde_json itself fails to serialize a
            // struct made entirely of Option/Vec/String/primitive fields --
            // effectively unreachable, but printed as an Unavailable-shaped
            // line (not a panic) so routes/dhcp.rs's parser still gets a
            // well-formed, if maximally-pessimistic, result to deserialize.
            let fallback = ProbeReport {
                conflict: ConflictOutcome::Unavailable {
                    reason: format!("failed to serialize probe result: {e}"),
                },
                client: ClientOutcome::Unavailable {
                    reason: format!("failed to serialize probe result: {e}"),
                },
            };
            // unwrap: this fallback value only contains Strings, so it
            // cannot fail to serialize the way the original report did.
            println!(
                "{DHCP_PROBE_RESULT_MARKER} {}",
                serde_json::to_string(&fallback).unwrap()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // A locally-administered, unicast address is required (see
    // random_locally_administered_mac's own comment on why): confirms both
    // bits land correctly regardless of the random byte's own value, by
    // running the check against many random samples rather than one.
    fn random_locally_administered_mac_sets_required_bits() {
        for _ in 0..100 {
            let mac = random_locally_administered_mac();
            assert_eq!(mac[0] & 0x02, 0x02, "locally-administered bit must be set");
            assert_eq!(mac[0] & 0x01, 0x00, "multicast bit must be clear");
        }
    }

    #[test]
    // A DHCPDISCOVER must round-trip through real wire encode/decode with
    // its message type, broadcast flag, and PRL intact -- this is the exact
    // packet a real DHCP server on the LAN will receive, so any mismatch
    // here (a wrong option code, an unset broadcast flag) would silently
    // break the whole probe against real hardware while still "compiling
    // fine".
    fn build_discover_encodes_and_decodes_with_expected_fields() {
        let xid = 0x1234_5678;
        let chaddr = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55];
        let msg = build_discover(xid, &chaddr);

        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf))
            .expect("a freshly-built DISCOVER must always encode");
        let decoded =
            Message::decode(&mut Decoder::new(&buf)).expect("must decode what was just encoded");

        assert_eq!(decoded.xid(), xid);
        assert!(decoded.flags().broadcast(), "broadcast flag must be set");
        assert_eq!(decoded.chaddr(), &chaddr);
        assert!(matches!(
            decoded.opts().get(OptionCode::MessageType),
            Some(DhcpOption::MessageType(MessageType::Discover))
        ));
        assert!(matches!(
            decoded.opts().get(OptionCode::ParameterRequestList),
            Some(DhcpOption::ParameterRequestList(_))
        ));
    }

    #[test]
    // build_request must refuse to build a malformed SELECTING-state
    // REQUEST when the offer it's answering is missing either field RFC
    // 2131 requires -- sending a request with a made-up/zero IP would be
    // actively worse than not sending one at all.
    fn build_request_returns_none_without_offered_ip_or_server_identifier() {
        let chaddr = [0x02, 0, 0, 0, 0, 1];
        let offer_missing_ip = LeaseInfo {
            server_identifier: Some(Ipv4Addr::new(192, 168, 1, 1)),
            ..Default::default()
        };
        assert!(build_request(1, &chaddr, &offer_missing_ip).is_none());

        let offer_missing_server = LeaseInfo {
            offered_ip: Some(Ipv4Addr::new(192, 168, 1, 50)),
            ..Default::default()
        };
        assert!(build_request(1, &chaddr, &offer_missing_server).is_none());
    }

    #[test]
    // A complete offer round-trips into a real DHCPREQUEST carrying the
    // exact requested-IP and server-identifier options a real DHCP server
    // requires to match this REQUEST back to its own earlier OFFER.
    fn build_request_encodes_requested_ip_and_server_identifier() {
        let chaddr = [0x02, 0, 0, 0, 0, 2];
        let offer = LeaseInfo {
            offered_ip: Some(Ipv4Addr::new(192, 168, 1, 50)),
            server_identifier: Some(Ipv4Addr::new(192, 168, 1, 1)),
            ..Default::default()
        };
        let msg =
            build_request(42, &chaddr, &offer).expect("a complete offer must build a request");

        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf)).unwrap();
        let decoded = Message::decode(&mut Decoder::new(&buf)).unwrap();

        assert!(matches!(
            decoded.opts().get(OptionCode::RequestedIpAddress),
            Some(DhcpOption::RequestedIpAddress(ip)) if *ip == Ipv4Addr::new(192, 168, 1, 50)
        ));
        assert!(matches!(
            decoded.opts().get(OptionCode::ServerIdentifier),
            Some(DhcpOption::ServerIdentifier(ip)) if *ip == Ipv4Addr::new(192, 168, 1, 1)
        ));
    }

    #[test]
    // extract_dhcp_offer_details's native replacement: every known field
    // this probe cares about must survive a real encode/decode round-trip
    // through a synthetic-but-realistic OFFER, not just be readable off the
    // in-memory Message this test built (that would not prove the wire
    // format itself is handled correctly).
    fn lease_info_from_message_extracts_all_known_fields_from_a_real_offer() {
        let chaddr = [0x02, 1, 2, 3, 4, 5];
        let mut msg = Message::new_with_id(
            7,
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::new(192, 168, 1, 50),
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::UNSPECIFIED,
            &chaddr,
        );
        msg.opts_mut()
            .insert(DhcpOption::MessageType(MessageType::Offer));
        msg.opts_mut()
            .insert(DhcpOption::ServerIdentifier(Ipv4Addr::new(192, 168, 1, 1)));
        msg.opts_mut()
            .insert(DhcpOption::SubnetMask(Ipv4Addr::new(255, 255, 255, 0)));
        msg.opts_mut()
            .insert(DhcpOption::Router(vec![Ipv4Addr::new(192, 168, 1, 1)]));
        msg.opts_mut().insert(DhcpOption::DomainNameServer(vec![
            Ipv4Addr::new(192, 168, 1, 1),
            Ipv4Addr::new(1, 1, 1, 1),
        ]));
        msg.opts_mut()
            .insert(DhcpOption::DomainName("lan.example".to_string()));
        msg.opts_mut()
            .insert(DhcpOption::BroadcastAddr(Ipv4Addr::new(192, 168, 1, 255)));
        msg.opts_mut().insert(DhcpOption::AddressLeaseTime(3600));
        msg.opts_mut().insert(DhcpOption::Renewal(1800));
        msg.opts_mut().insert(DhcpOption::Rebinding(3150));

        let mut buf = Vec::new();
        msg.encode(&mut Encoder::new(&mut buf)).unwrap();
        let decoded = Message::decode(&mut Decoder::new(&buf)).unwrap();

        let lease = lease_info_from_message(&decoded);
        assert_eq!(lease.offered_ip, Some(Ipv4Addr::new(192, 168, 1, 50)));
        assert_eq!(lease.server_identifier, Some(Ipv4Addr::new(192, 168, 1, 1)));
        assert_eq!(lease.subnet_mask, Some(Ipv4Addr::new(255, 255, 255, 0)));
        assert_eq!(lease.router, Some(Ipv4Addr::new(192, 168, 1, 1)));
        assert_eq!(
            lease.dns_servers,
            vec![Ipv4Addr::new(192, 168, 1, 1), Ipv4Addr::new(1, 1, 1, 1)]
        );
        assert_eq!(lease.domain_name.as_deref(), Some("lan.example"));
        assert_eq!(
            lease.broadcast_address,
            Some(Ipv4Addr::new(192, 168, 1, 255))
        );
        assert_eq!(lease.lease_time_secs, Some(3600));
        assert_eq!(lease.renewal_time_secs, Some(1800));
        assert_eq!(lease.rebinding_time_secs, Some(3150));
    }

    #[test]
    // A message with yiaddr left at 0.0.0.0 (the "no address" sentinel --
    // e.g. a DHCPNAK) must not be misreported as "offering" the unspecified
    // address; every other optional field is independently absent too when
    // never inserted, and filter_map-style extraction must not panic on an
    // all-empty option set.
    fn lease_info_from_message_treats_unspecified_yiaddr_as_no_offer() {
        let chaddr = [0x02, 0, 0, 0, 0, 9];
        let msg = Message::new_with_id(
            1,
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::UNSPECIFIED,
            &chaddr,
        );
        let lease = lease_info_from_message(&msg);
        assert_eq!(lease, LeaseInfo::default());
    }

    #[test]
    // ProbeReport (the actual process-boundary wire type) must round-trip
    // through serde_json exactly, for every outcome variant -- this is the
    // one contract routes/dhcp.rs's parser depends on, so a silent
    // serde-shape drift here would break the Admin UI's probe results
    // without any compile error on either side of the process boundary.
    fn probe_report_json_round_trips_for_every_outcome_variant() {
        let report = ProbeReport {
            conflict: ConflictOutcome::Found {
                offers: vec![LeaseInfo {
                    server_identifier: Some(Ipv4Addr::new(10, 0, 0, 1)),
                    ..Default::default()
                }],
            },
            client: ClientOutcome::Passed {
                lease: LeaseInfo {
                    offered_ip: Some(Ipv4Addr::new(10, 0, 0, 50)),
                    ..Default::default()
                },
            },
        };
        let json = serde_json::to_string(&report).unwrap();
        let round_tripped: ProbeReport = serde_json::from_str(&json).unwrap();
        assert!(matches!(
            round_tripped.conflict,
            ConflictOutcome::Found { offers } if offers.len() == 1
        ));
        assert!(matches!(
            round_tripped.client,
            ClientOutcome::Passed { lease } if lease.offered_ip == Some(Ipv4Addr::new(10, 0, 0, 50))
        ));

        let unavailable = ProbeReport {
            conflict: ConflictOutcome::Unavailable {
                reason: "no interface".to_string(),
            },
            client: ClientOutcome::Unavailable {
                reason: "no interface".to_string(),
            },
        };
        let json = serde_json::to_string(&unavailable).unwrap();
        let round_tripped: ProbeReport = serde_json::from_str(&json).unwrap();
        assert!(matches!(
            round_tripped.conflict,
            ConflictOutcome::Unavailable { reason } if reason == "no interface"
        ));
    }
}
