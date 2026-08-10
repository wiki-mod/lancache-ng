//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
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
///
/// `discover_dest` is where every DISCOVER retransmit is actually sent --
/// [`run_probe`] always passes the real limited-broadcast target
/// (`255.255.255.255:67`); this is a caller-supplied parameter rather than a
/// constant computed in here specifically so the test suite can substitute a
/// loopback fake-server address instead. Real broadcast delivery cannot be
/// exercised deterministically inside this project's own build-tools
/// container test run (that run is unprivileged per Rule-Ref: AG-VAL-016,
/// and actual L2 broadcast delivery depends on host/container network
/// configuration this test suite does not control either way) -- making the
/// destination a parameter is what lets the retransmission-count and
/// xid-propagation logic be proven against a real UDP socket round trip
/// instead of being mocked away entirely. See the `tests` module below.
fn collect_offers(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    window: Duration,
    discover_dest: SocketAddrV4,
) -> io::Result<Vec<LeaseInfo>> {
    let deadline = Instant::now() + window;
    let retransmit_interval = window / DISCOVER_RETRANSMITS;
    let mut offers = Vec::new();
    let mut seen_servers: std::collections::HashSet<Ipv4Addr> = std::collections::HashSet::new();
    let mut recv_buf = [0u8; 1500];

    for attempt in 0..DISCOVER_RETRANSMITS {
        let discover = build_discover(xid, chaddr);
        let mut send_buf = Vec::new();
        discover
            .encode(&mut Encoder::new(&mut send_buf))
            .map_err(io::Error::other)?;
        socket.send_to(&send_buf, discover_dest)?;

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
///
/// `request_dest` is where the DHCPREQUEST is sent -- [`run_probe`] always
/// passes the same real limited-broadcast target [`collect_offers`] used for
/// the DISCOVER; it is a parameter here for the same test-substitution
/// reason documented on [`collect_offers`]. The DHCPRELEASE below
/// deliberately does NOT reuse `request_dest`'s address (RFC 2131 4.4.4
/// requires RELEASE to be unicast to the specific leasing server, not
/// broadcast) -- only its port is reused, since RELEASE still goes to the
/// same well-known DHCP server port as everything else, just at the
/// server's own unicast address instead of the broadcast one.
fn perform_client_dry_run(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    offer: &LeaseInfo,
    timeout: Duration,
    request_dest: SocketAddrV4,
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
    if let Err(e) = socket.send_to(&buf, request_dest) {
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
            // Unicast to the server's own address, not `request_dest` --
            // only the port is shared with request_dest (the well-known DHCP
            // server port), never the address (see this function's own doc
            // comment on why RELEASE must not go to the broadcast target).
            let release_addr = SocketAddrV4::new(server_id, request_dest.port());
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

    // The one real destination every DISCOVER and REQUEST is sent to in
    // production -- see collect_offers/perform_client_dry_run's own
    // comments on why this is passed in rather than hardcoded inside them.
    let broadcast_dest = SocketAddrV4::new(Ipv4Addr::BROADCAST, DHCP_SERVER_PORT);
    run_probe_on_socket(&socket, discover_window, request_timeout, broadcast_dest)
}

/// The actual probe sequence, taking an already-bound socket and the
/// destination every DISCOVER/REQUEST is sent to as parameters, split out
/// from [`run_probe`] (which only adds the real privileged-port bind and
/// the real broadcast destination) for the same test-substitution reason
/// documented on [`collect_offers`]/[`perform_client_dry_run`]: this is the
/// level at which the ONE shared `xid` -- generated once here and passed
/// unchanged to both `collect_offers` and `perform_client_dry_run` below --
/// can be observed end-to-end over a real loopback socket pair, rather than
/// only checking that `perform_client_dry_run` forwards whatever `xid` it
/// was individually given (a regression that stopped generating a fresh xid
/// inside `perform_client_dry_run` but started generating one HERE instead
/// would still pass a test that only exercised that one function in
/// isolation -- see the `tests` module's
/// `run_probe_on_socket_reuses_one_xid_across_discover_and_request`).
fn run_probe_on_socket(
    socket: &UdpSocket,
    discover_window: Duration,
    request_timeout: Duration,
    server_dest: SocketAddrV4,
) -> ProbeReport {
    // Every DISCOVER retransmit, and the REQUEST that follows the first
    // offer, share this ONE transaction ID -- see perform_client_dry_run's
    // own comment on why the REQUEST specifically must not generate a new
    // one of its own.
    let xid = rand::random();
    let chaddr = random_locally_administered_mac();

    let offers = match collect_offers(socket, xid, &chaddr, discover_window, server_dest) {
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
        Some(first_offer) => perform_client_dry_run(
            socket,
            xid,
            &chaddr,
            first_offer,
            request_timeout,
            server_dest,
        ),
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

    // ---- Real-socket regression coverage for the three review-pass fixes
    // (issue #1288, PR #1336's follow-up): REQUEST xid-chaining (RFC 2131
    // 4.3.2), unicast RELEASE targeting (RFC 2131 4.4.4), and bounded
    // DISCOVER retransmission. All three live in collect_offers/
    // perform_client_dry_run, which only take an already-bound `socket` and
    // now a caller-supplied destination address (see those two functions'
    // own doc comments) -- so unlike the tests above, these bind real
    // ephemeral-port loopback UDP sockets and run the actual wire logic
    // through a real send/receive round trip, rather than only building and
    // decoding an in-memory Message. They do not exercise real network
    // broadcast (255.255.255.255) or the real privileged DHCP ports
    // (67/68): both require root/host-network-level guarantees this
    // project's own build-tools container test run does not have (Rule-Ref:
    // AG-VAL-016 runs tests as a non-root user), which is exactly why
    // `discover_dest`/`request_dest` exist as parameters in the first place.
    use std::net::SocketAddr;
    use std::sync::mpsc;
    use std::thread;

    /// Binds an ephemeral-port UDP socket on the given loopback address.
    /// The whole 127.0.0.0/8 block is loopback on Linux with no extra host
    /// configuration needed, so tests below can use several distinct
    /// addresses (not just 127.0.0.1) to stand in for "the real DHCP
    /// server's own address" versus "wherever DISCOVER/REQUEST are sent",
    /// without needing a real second network interface.
    fn bind_loopback(ip: Ipv4Addr) -> UdpSocket {
        UdpSocket::bind(SocketAddrV4::new(ip, 0))
            .expect("binding an ephemeral loopback UDP port must not fail")
    }

    /// Reads back the actual port the OS assigned a loopback-bound socket --
    /// used to point a second, separately-bound socket at "the same port,
    /// different address" without a fixed magic-number port that could
    /// collide with another test running concurrently (`cargo test` runs
    /// tests in parallel by default).
    fn loopback_port(socket: &UdpSocket) -> u16 {
        match socket.local_addr().expect("bound socket has a local addr") {
            SocketAddr::V4(addr) => addr.port(),
            SocketAddr::V6(_) => {
                unreachable!("a socket bound to a V4 loopback address never yields a V6 local_addr")
            }
        }
    }

    #[test]
    // Regression coverage for the RFC 2131 4.3.2 xid-chaining fix:
    // perform_client_dry_run's DHCPREQUEST must carry the EXACT SAME xid it
    // was given (the transaction ID the prior DISCOVER/OFFER exchange
    // already used), never a freshly generated one -- a real server has no
    // reason to honor a REQUEST under a transaction ID it never offered
    // anything for (see the function's own doc comment). Proven over a real
    // UDP socket round trip: a fake-server thread decodes the actual
    // REQUEST bytes that were sent on the wire and reports the xid it truly
    // saw back to this test over a channel, rather than this test only
    // inspecting build_request's in-memory return value in isolation.
    fn perform_client_dry_run_request_reuses_the_given_xid() {
        let client_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_port = loopback_port(&server_socket);
        let server_ip = Ipv4Addr::LOCALHOST;
        let request_dest = SocketAddrV4::new(server_ip, server_port);

        let expected_xid: u32 = 0xCAFE_BABE;
        let (xid_tx, xid_rx) = mpsc::channel();
        let server_thread = thread::spawn(move || {
            server_socket
                .set_read_timeout(Some(Duration::from_secs(2)))
                .expect("setting a read timeout must not fail");
            let mut buf = [0u8; 1500];
            let (n, from) = server_socket
                .recv_from(&mut buf)
                .expect("must receive the DHCPREQUEST perform_client_dry_run sends");
            let request = Message::decode(&mut Decoder::new(&buf[..n]))
                .expect("must decode a well-formed DHCPREQUEST");
            xid_tx
                .send(request.xid())
                .expect("test thread must still be listening for the observed xid");

            // Reply with a real DHCPACK so perform_client_dry_run reports
            // Passed -- this test's assertion is the xid seen above, but a
            // Failed/Unavailable outcome here would itself be a sign
            // something upstream broke, so it is checked too.
            // Message::new_with_id's address params are (ciaddr, yiaddr,
            // siaddr, giaddr) in that order -- the granted lease address
            // belongs in yiaddr (3rd), matching how a real server's ACK is
            // shaped and how lease_info_from_message reads it back via
            // msg.yiaddr(), not ciaddr (which this client never has bound).
            let mut ack = Message::new_with_id(
                request.xid(),
                Ipv4Addr::UNSPECIFIED,
                Ipv4Addr::new(192, 168, 50, 77),
                Ipv4Addr::UNSPECIFIED,
                Ipv4Addr::UNSPECIFIED,
                request.chaddr(),
            );
            ack.opts_mut()
                .insert(DhcpOption::MessageType(MessageType::Ack));
            ack.opts_mut()
                .insert(DhcpOption::ServerIdentifier(server_ip));
            let mut ack_buf = Vec::new();
            ack.encode(&mut Encoder::new(&mut ack_buf))
                .expect("a freshly-built ACK must always encode");
            server_socket
                .send_to(&ack_buf, from)
                .expect("sending the ACK back must not fail");
        });

        let offer = LeaseInfo {
            offered_ip: Some(Ipv4Addr::new(192, 168, 50, 1)),
            server_identifier: Some(server_ip),
            ..Default::default()
        };
        let chaddr = [0x02, 9, 9, 9, 9, 9];
        let outcome = perform_client_dry_run(
            &client_socket,
            expected_xid,
            &chaddr,
            &offer,
            Duration::from_secs(2),
            request_dest,
        );

        let observed_xid = xid_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("the fake server thread must report the xid it decoded");
        server_thread
            .join()
            .expect("fake server thread must not panic");

        assert_eq!(
            observed_xid, expected_xid,
            "the REQUEST on the wire must carry the same xid as the exchange it is answering, \
             not a freshly generated one"
        );
        assert!(
            matches!(outcome, ClientOutcome::Passed { .. }),
            "a matching xid/server-identifier ACK must be accepted as a passed dry-run, got {outcome:?}"
        );
    }

    #[test]
    // Regression coverage for the RFC 2131 4.4.4 unicast-RELEASE fix:
    // perform_client_dry_run must send the DHCPRELEASE as a unicast
    // datagram addressed directly to the leasing server
    // (offer.server_identifier), never to the same broadcast/request
    // destination DISCOVER/REQUEST used (see the function's own doc
    // comment). Proven with two separate real UDP listeners on different
    // loopback aliases sharing one port: one stands in for "wherever
    // DISCOVER/REQUEST go" (request_dest, on 127.0.0.1), the other for the
    // server's own real identity (server_identifier, on 127.0.0.2). If the
    // RELEASE were mistakenly sent to request_dest instead of the server's
    // own address, the server-identity listener below would time out
    // waiting for it, and this test would fail exactly as designed.
    fn perform_client_dry_run_release_is_unicast_to_the_server_identifier() {
        let client_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let request_listener = bind_loopback(Ipv4Addr::LOCALHOST);
        let shared_port = loopback_port(&request_listener);
        let request_dest = SocketAddrV4::new(Ipv4Addr::LOCALHOST, shared_port);

        // A distinct loopback alias from 127.0.0.1 -- not just a different
        // port -- so the two listeners are unambiguously different
        // destinations, matching how a real broadcast address and a real
        // specific server address are genuinely different IPs on a LAN.
        let server_ip = Ipv4Addr::new(127, 0, 0, 2);
        let release_listener = UdpSocket::bind(SocketAddrV4::new(server_ip, shared_port))
            .expect("binding the server-identity loopback alias on the shared port must not fail");
        release_listener
            .set_read_timeout(Some(Duration::from_millis(800)))
            .expect("setting a read timeout must not fail");

        let xid: u32 = 0x1111_2222;
        let chaddr = [0x02, 8, 8, 8, 8, 8];
        let request_thread = thread::spawn(move || {
            request_listener
                .set_read_timeout(Some(Duration::from_secs(2)))
                .expect("setting a read timeout must not fail");
            let mut buf = [0u8; 1500];
            let (n, from) = request_listener
                .recv_from(&mut buf)
                .expect("must receive the DHCPREQUEST");
            let request = Message::decode(&mut Decoder::new(&buf[..n]))
                .expect("must decode a well-formed DHCPREQUEST");

            // See the xid-chaining test's own comment: the granted lease
            // address belongs in yiaddr (3rd positional arg), not ciaddr.
            let mut ack = Message::new_with_id(
                request.xid(),
                Ipv4Addr::UNSPECIFIED,
                Ipv4Addr::new(192, 168, 77, 5),
                Ipv4Addr::UNSPECIFIED,
                Ipv4Addr::UNSPECIFIED,
                request.chaddr(),
            );
            ack.opts_mut()
                .insert(DhcpOption::MessageType(MessageType::Ack));
            ack.opts_mut()
                .insert(DhcpOption::ServerIdentifier(server_ip));
            let mut ack_buf = Vec::new();
            ack.encode(&mut Encoder::new(&mut ack_buf))
                .expect("a freshly-built ACK must always encode");
            request_listener
                .send_to(&ack_buf, from)
                .expect("sending the ACK back must not fail");
        });

        let offer = LeaseInfo {
            offered_ip: Some(Ipv4Addr::new(192, 168, 77, 1)),
            server_identifier: Some(server_ip),
            ..Default::default()
        };
        let outcome = perform_client_dry_run(
            &client_socket,
            xid,
            &chaddr,
            &offer,
            Duration::from_secs(2),
            request_dest,
        );
        request_thread
            .join()
            .expect("fake server thread must not panic");
        assert!(
            matches!(outcome, ClientOutcome::Passed { .. }),
            "the dry-run must pass before a RELEASE is even attempted, got {outcome:?}"
        );

        let mut release_buf = [0u8; 1500];
        let (n, _from) = release_listener.recv_from(&mut release_buf).expect(
            "the DHCPRELEASE must arrive at the server-identifier loopback alias -- if this \
             times out, the RELEASE was sent to request_dest (the broadcast target) instead \
             of unicast to the server",
        );
        let release = Message::decode(&mut Decoder::new(&release_buf[..n]))
            .expect("must decode a well-formed DHCPRELEASE");
        assert!(matches!(
            release.opts().get(OptionCode::MessageType),
            Some(DhcpOption::MessageType(MessageType::Release))
        ));
        assert_eq!(
            release.ciaddr(),
            Ipv4Addr::new(192, 168, 77, 5),
            "the RELEASE's ciaddr must be the address the ACK actually granted"
        );
    }

    #[test]
    // Regression coverage for the bounded-DISCOVER-retransmission fix:
    // collect_offers must retransmit exactly DISCOVER_RETRANSMITS times
    // within one window, never more (an unbounded retry loop, or an
    // off-by-one in the loop bound, is exactly the failure mode that
    // constant's own doc comment exists to prevent). Proven by literally
    // counting real DISCOVER datagrams a fake-server socket receives over
    // one full (shortened, for test speed) window -- a regression that
    // changes the real retransmit count changes what this test observes,
    // it does not just move alongside a re-read of the same constant.
    fn collect_offers_retransmits_the_bounded_number_of_times() {
        let client_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_port = loopback_port(&server_socket);
        let discover_dest = SocketAddrV4::new(Ipv4Addr::LOCALHOST, server_port);

        let xid: u32 = 0x0BAD_F00D;
        let chaddr = [0x02, 7, 7, 7, 7, 7];
        // collect_offers takes `window` as a caller-supplied parameter
        // specifically so callers -- including this test -- can shorten it;
        // this test only cares how many DISCOVERs arrive, not the
        // production 5s window's real-world timing.
        let window = Duration::from_millis(300);

        let (count_tx, count_rx) = mpsc::channel();
        let server_thread = thread::spawn(move || {
            // Never replies: collect_offers must keep retransmitting for
            // the whole window regardless of whether an offer already came
            // in (see the module doc comment: every offering server
            // matters, not just the first) -- a silent server is what
            // proves the retransmit count, rather than an early-exit-on
            // -first-offer shortcut this test could otherwise be fooled by.
            server_socket
                .set_read_timeout(Some(window + Duration::from_millis(500)))
                .expect("setting a read timeout must not fail");
            let mut count = 0u32;
            let mut buf = [0u8; 1500];
            while let Ok((n, _from)) = server_socket.recv_from(&mut buf) {
                if let Ok(msg) = Message::decode(&mut Decoder::new(&buf[..n]))
                    && msg.xid() == xid
                {
                    count += 1;
                }
            }
            let _ = count_tx.send(count);
        });

        let offers = collect_offers(&client_socket, xid, &chaddr, window, discover_dest)
            .expect("collect_offers must not hard-fail against a live loopback socket");
        assert!(
            offers.is_empty(),
            "a silent fake server must yield no offers"
        );

        let observed = count_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("the fake server thread must report a retransmit count");
        server_thread
            .join()
            .expect("fake server thread must not panic");

        assert_eq!(
            observed, DISCOVER_RETRANSMITS,
            "collect_offers must retransmit exactly DISCOVER_RETRANSMITS times per window, \
             no more (unbounded) and no fewer (under-retrying)"
        );
    }

    #[test]
    // Regression coverage for the OTHER half of the xid-chaining fix:
    // run_probe_on_socket generates exactly one xid and passes the SAME
    // value to both collect_offers and perform_client_dry_run (see that
    // function's own doc comment on why this needs a test distinct from
    // perform_client_dry_run_request_reuses_the_given_xid above -- that
    // test only proves perform_client_dry_run forwards whatever xid it is
    // individually given; it cannot catch a regression where
    // run_probe_on_socket itself started generating two different xids and
    // handing the wrong one to each call). Proven end-to-end: a single
    // fake-server thread handles both the DISCOVER and the later REQUEST on
    // one dispatching receive loop (not two sequential one-shot recv_from
    // calls, since collect_offers always waits its full window before
    // perform_client_dry_run's REQUEST follows), and reports both xids it
    // actually saw on the wire back to this test.
    fn run_probe_on_socket_reuses_one_xid_across_discover_and_request() {
        let client_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_socket = bind_loopback(Ipv4Addr::LOCALHOST);
        let server_port = loopback_port(&server_socket);
        let server_ip = Ipv4Addr::new(127, 0, 0, 3);
        let server_dest = SocketAddrV4::new(Ipv4Addr::LOCALHOST, server_port);

        let (xid_tx, xid_rx) = mpsc::channel();
        let server_thread = thread::spawn(move || {
            server_socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .expect("setting a read timeout must not fail");
            let mut buf = [0u8; 1500];
            let mut discover_xid = None;

            loop {
                let (n, from) = server_socket
                    .recv_from(&mut buf)
                    .expect("must receive a DHCP message from run_probe_on_socket");
                let Ok(msg) = Message::decode(&mut Decoder::new(&buf[..n])) else {
                    continue;
                };
                match msg.opts().get(OptionCode::MessageType) {
                    Some(DhcpOption::MessageType(MessageType::Discover)) => {
                        discover_xid = Some(msg.xid());
                        let mut offer = Message::new_with_id(
                            msg.xid(),
                            Ipv4Addr::UNSPECIFIED,
                            Ipv4Addr::new(192, 168, 60, 20),
                            Ipv4Addr::UNSPECIFIED,
                            Ipv4Addr::UNSPECIFIED,
                            msg.chaddr(),
                        );
                        offer
                            .opts_mut()
                            .insert(DhcpOption::MessageType(MessageType::Offer));
                        offer
                            .opts_mut()
                            .insert(DhcpOption::ServerIdentifier(server_ip));
                        let mut offer_buf = Vec::new();
                        offer
                            .encode(&mut Encoder::new(&mut offer_buf))
                            .expect("a freshly-built OFFER must always encode");
                        server_socket
                            .send_to(&offer_buf, from)
                            .expect("sending the OFFER back must not fail");
                    }
                    Some(DhcpOption::MessageType(MessageType::Request)) => {
                        let discover_xid =
                            discover_xid.expect("a REQUEST must not arrive before a DISCOVER");
                        xid_tx
                            .send((discover_xid, msg.xid()))
                            .expect("test thread must still be listening");
                        let mut ack = Message::new_with_id(
                            msg.xid(),
                            Ipv4Addr::UNSPECIFIED,
                            Ipv4Addr::new(192, 168, 60, 20),
                            Ipv4Addr::UNSPECIFIED,
                            Ipv4Addr::UNSPECIFIED,
                            msg.chaddr(),
                        );
                        ack.opts_mut()
                            .insert(DhcpOption::MessageType(MessageType::Ack));
                        ack.opts_mut()
                            .insert(DhcpOption::ServerIdentifier(server_ip));
                        let mut ack_buf = Vec::new();
                        ack.encode(&mut Encoder::new(&mut ack_buf))
                            .expect("a freshly-built ACK must always encode");
                        server_socket
                            .send_to(&ack_buf, from)
                            .expect("sending the ACK back must not fail");
                        return;
                    }
                    _ => continue,
                }
            }
        });

        // A short discover window keeps this test fast -- run_probe_on_socket
        // takes it as a parameter for exactly this reason (see
        // collect_offers' own doc comment).
        let report = run_probe_on_socket(
            &client_socket,
            Duration::from_millis(300),
            Duration::from_secs(2),
            server_dest,
        );

        let (discover_xid, request_xid) = xid_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("the fake server thread must report both xids it observed");
        server_thread
            .join()
            .expect("fake server thread must not panic");

        assert_eq!(
            discover_xid, request_xid,
            "run_probe_on_socket must reuse the SAME xid for the REQUEST that it used for the \
             DISCOVER/OFFER exchange -- generating a second, independent xid at this level \
             would make every real-server dry-run fail even though perform_client_dry_run \
             itself correctly forwards whatever xid it is given"
        );
        assert!(
            matches!(report.client, ClientOutcome::Passed { .. }),
            "a matching xid/server-identifier ACK must be accepted as a passed dry-run, got {:?}",
            report.client
        );
    }
}
