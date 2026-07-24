//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Active DNS health probe for registered secondaries (#1084). Sends a real
//! `lan.` SOA query (a genuine query/response probe per AG-VAL-018, not a mere
//! reachability ping) to a secondary's own DNS server and classifies the
//! result into an operator-facing status.
//!
//! This deliberately checks *observable DNS behavior* -- "does this host answer
//! authoritatively for `lan.`?" -- rather than any zone-transfer/slave state.
//! In this project every DNS node is locally authoritative for `lan.` and
//! receives records via the NATS subscriber applying them, not via AXFR, so an
//! authoritative SOA answer is the meaningful "the zone is configured and being
//! served" signal. The SOA serial is reported for information only; because
//! each node's PowerDNS manages its own serial under NATS replication, a serial
//! mismatch is NOT a reliable staleness verdict and is not treated as one here.
//!
//! ## Why a hand-rolled query instead of a DNS client crate
//! This started on `hickory-client`, but its transitive `hickory-proto` 0.25.2
//! carries two open advisories -- RUSTSEC-2026-0119 (encoding CPU exhaustion,
//! fixed only in the not-yet-stable 0.26 line) and RUSTSEC-2026-0118 (NSEC3
//! validation loop, with *no* fixed release at any version) -- so no current
//! `hickory-client` passes this project's `cargo audit --deny warnings` gate.
//! A single outbound SOA query needs only a tiny, fully-controlled slice of the
//! DNS wire format, so it is hand-built here over `tokio::net::UdpSocket`. The
//! encode/decode is pure and unit-tested against fixed byte arrays.
//!
//! Security: the probe target address is attacker-influenceable (secondary
//! registration is token-gated but unauthenticated, and an operator can
//! override the stored address), and the primary then fires UDP at it. To keep
//! this from becoming an SSRF lever, the target is restricted to private
//! (RFC1918) IPv4 addresses via `parse_private_ipv4`, consistent with the LAN
//! scope of the whole feature.

use serde::Serialize;
use std::net::Ipv4Addr;
use std::time::Duration;

/// Hard upper bound on a single probe so a black-hole/unresponsive target
/// cannot hang the request handler.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// The zone every correctly-configured DNS node in this project is
/// authoritative for; its SOA is the universal "is the zone served?" probe.
const LAN_ZONE_LABELS: &[&str] = &["lan"];

/// DNS numeric constants used by the single query this module builds.
const QTYPE_SOA: u16 = 6;
const QCLASS_IN: u16 = 1;

/// Operator-facing outcome of one health probe, serialized to JSON for the
/// Admin UI's async "check now" action.
#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct ProbeResult {
    /// Stable status code the UI maps to a label/color:
    /// `ok`, `not_authoritative`, `no_zone`, `broken`, `unreachable`, `error`.
    pub status: &'static str,
    /// The secondary's reported `lan.` SOA serial, when it answered with one
    /// (informational only -- see the module docs on why it is not a staleness
    /// verdict under NATS replication).
    pub serial: Option<u32>,
    /// Human-readable detail for the UI tooltip / operator diagnosis.
    pub detail: String,
}

/// Parses `s` as a private (RFC1918) IPv4 address, returning `None` for
/// anything unparseable or outside the private ranges. Used at registration,
/// on manual address override, and immediately before probing, so a non-private
/// or malformed address can never become a probe (SSRF) target. `is_private()`
/// is exactly `10/8`, `172.16/12`, and `192.168/16`.
pub fn parse_private_ipv4(s: &str) -> Option<Ipv4Addr> {
    let addr: Ipv4Addr = s.trim().parse().ok()?;
    if addr.is_private() {
        Some(addr)
    } else {
        None
    }
}

/// Builds a standard DNS query message for the `lan.` SOA record with the given
/// transaction id. RD (recursion desired) is deliberately left off: we query an
/// authoritative server for its own zone and want its authoritative answer, not
/// recursion.
fn build_soa_query(id: u16) -> Vec<u8> {
    let mut msg = Vec::with_capacity(21);
    msg.extend_from_slice(&id.to_be_bytes());
    msg.extend_from_slice(&0x0000u16.to_be_bytes()); // flags: QR=0, opcode=0, RD=0
    msg.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    msg.extend_from_slice(&0u16.to_be_bytes()); // ANCOUNT
    msg.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    msg.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    for label in LAN_ZONE_LABELS {
        msg.push(label.len() as u8);
        msg.extend_from_slice(label.as_bytes());
    }
    msg.push(0); // root label terminates QNAME
    msg.extend_from_slice(&QTYPE_SOA.to_be_bytes());
    msg.extend_from_slice(&QCLASS_IN.to_be_bytes());
    msg
}

/// Advances past a DNS name starting at `pos`, returning the offset of the byte
/// after the name. A compression pointer (top two bits set) terminates the name
/// in two bytes; a zero-length label terminates it; a reserved length is
/// rejected. Bounds-checked against a truncated/malicious message.
fn skip_name(buf: &[u8], mut pos: usize) -> Option<usize> {
    loop {
        let len = *buf.get(pos)?;
        if len == 0 {
            return Some(pos + 1);
        }
        match len & 0xC0 {
            0x00 => pos += 1 + len as usize,
            0xC0 => return Some(pos + 2), // pointer: name ends here
            _ => return None,             // 0x40/0x80 are reserved
        }
    }
}

/// Best-effort extraction of the SOA serial from the first answer record. The
/// serial is informational, so any parse difficulty (compression we don't
/// follow into, a truncated record, a non-SOA first answer) simply yields
/// `None` rather than failing the whole probe.
fn extract_soa_serial(buf: &[u8]) -> Option<u32> {
    // Skip the fixed 12-byte header + the single question.
    let mut pos = skip_name(buf, 12)?;
    pos += 4; // QTYPE + QCLASS

    // First answer record: NAME, then TYPE(2) CLASS(2) TTL(4) RDLENGTH(2).
    pos = skip_name(buf, pos)?;
    let rtype = u16::from_be_bytes([*buf.get(pos)?, *buf.get(pos + 1)?]);
    if rtype != QTYPE_SOA {
        return None;
    }
    let rdlength = u16::from_be_bytes([*buf.get(pos + 8)?, *buf.get(pos + 9)?]) as usize;
    let rdata_start = pos + 10;
    let rdata_end = rdata_start.checked_add(rdlength)?;

    // SOA RDATA = MNAME RNAME SERIAL(4) REFRESH RETRY EXPIRE MINIMUM.
    let after_mname = skip_name(buf, rdata_start)?;
    let after_rname = skip_name(buf, after_mname)?;
    let serial = buf.get(after_rname..after_rname + 4)?;
    if after_rname + 4 > rdata_end {
        return None;
    }
    Some(u32::from_be_bytes([
        serial[0], serial[1], serial[2], serial[3],
    ]))
}

/// Parses a DNS response for the fields the health check needs: the RCODE, the
/// authoritative (AA) flag, whether any answer was returned, and (best effort)
/// the SOA serial. Pure and socket-free so it can be unit-tested with fixed
/// bytes. Rejects a response whose id does not match the query, or that is not
/// actually a response (QR unset).
fn parse_soa_response(
    expected_id: u16,
    buf: &[u8],
) -> Result<(u8, bool, u16, Option<u32>), String> {
    if buf.len() < 12 {
        return Err("short DNS response (<12 bytes)".to_string());
    }
    let id = u16::from_be_bytes([buf[0], buf[1]]);
    if id != expected_id {
        return Err("DNS response transaction id mismatch".to_string());
    }
    if buf[2] & 0x80 == 0 {
        return Err("DNS message is not a response (QR bit unset)".to_string());
    }
    let authoritative = buf[2] & 0x04 != 0;
    let rcode = buf[3] & 0x0F;
    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    let serial = if ancount > 0 {
        extract_soa_serial(buf)
    } else {
        None
    };
    Ok((rcode, authoritative, ancount, serial))
}

/// Maps a parsed `lan.` SOA response into a `ProbeResult`. Pure and network-free
/// so the status mapping (the part with real branching) is unit-tested without
/// a live DNS server. RCODEs: 0 = NoError, 2 = ServFail, 5 = Refused.
fn classify(
    rcode: u8,
    authoritative: bool,
    has_answer: bool,
    soa_serial: Option<u32>,
) -> ProbeResult {
    match rcode {
        0 if authoritative && has_answer => ProbeResult {
            status: "ok",
            serial: soa_serial,
            detail: "answered authoritatively for lan. (SOA present)".to_string(),
        },
        // Answered with an SOA but without the AA bit: the host serves the
        // record but not as an authority (e.g. a recursor passthrough), which
        // is not the "configured as an authoritative node" state we confirm.
        0 if has_answer => ProbeResult {
            status: "not_authoritative",
            serial: soa_serial,
            detail: "returned an lan. answer but without the authoritative (AA) flag".to_string(),
        },
        0 => ProbeResult {
            status: "error",
            serial: None,
            detail: "NOERROR but no answer for lan. SOA".to_string(),
        },
        5 => ProbeResult {
            status: "no_zone",
            serial: None,
            detail: "REFUSED -- host is not authoritative for lan. (zone not configured?)"
                .to_string(),
        },
        2 => ProbeResult {
            status: "broken",
            serial: None,
            detail: "SERVFAIL -- lan. zone present but the host failed to answer".to_string(),
        },
        other => ProbeResult {
            status: "error",
            serial: None,
            detail: format!("unexpected DNS response code (RCODE {other})"),
        },
    }
}

/// Probes `addr:port` with a real `lan.` SOA query and returns the classified
/// result. Any socket/parse failure or timeout maps to `unreachable` rather
/// than propagating an error, so the caller always has a displayable status.
pub async fn probe_secondary_soa(addr: Ipv4Addr, port: u16) -> ProbeResult {
    match tokio::time::timeout(PROBE_TIMEOUT, query_soa(addr, port)).await {
        Err(_) => ProbeResult {
            status: "unreachable",
            serial: None,
            detail: format!("no response from {addr}:{port} within {PROBE_TIMEOUT:?}"),
        },
        Ok(Err(e)) => ProbeResult {
            status: "unreachable",
            serial: None,
            detail: format!("DNS query to {addr}:{port} failed: {e}"),
        },
        Ok(Ok((rcode, authoritative, ancount, serial))) => {
            classify(rcode, authoritative, ancount > 0, serial)
        }
    }
}

/// Sends the SOA query over UDP and parses the reply. 512 bytes is the classic
/// DNS UDP message size and is ample for a single SOA answer.
async fn query_soa(addr: Ipv4Addr, port: u16) -> Result<(u8, bool, u16, Option<u32>), String> {
    let query_id: u16 = rand::random();
    let query = build_soa_query(query_id);

    let socket = tokio::net::UdpSocket::bind(("0.0.0.0", 0))
        .await
        .map_err(|e| e.to_string())?;
    socket
        .connect((addr, port))
        .await
        .map_err(|e| e.to_string())?;
    socket.send(&query).await.map_err(|e| e.to_string())?;

    let mut buf = [0u8; 512];
    let n = socket.recv(&mut buf).await.map_err(|e| e.to_string())?;
    parse_soa_response(query_id, &buf[..n])
}

#[cfg(test)]
mod tests {
    use super::*;

    // #1084: only a private (RFC1918) IPv4 may become a probe target, so an
    // attacker-influenceable registration/override address cannot coerce the
    // primary into firing UDP at an arbitrary public host (SSRF).
    #[test]
    fn parse_private_ipv4_accepts_only_rfc1918() {
        assert_eq!(
            parse_private_ipv4("192.168.1.20"),
            Some("192.168.1.20".parse().unwrap())
        );
        assert_eq!(
            parse_private_ipv4("10.9.8.7"),
            Some("10.9.8.7".parse().unwrap())
        );
        assert_eq!(
            parse_private_ipv4(" 172.16.0.1 "),
            Some("172.16.0.1".parse().unwrap())
        );
        assert_eq!(parse_private_ipv4("8.8.8.8"), None);
        assert_eq!(parse_private_ipv4("172.32.0.1"), None);
        assert_eq!(parse_private_ipv4("not-an-ip"), None);
        assert_eq!(parse_private_ipv4("::1"), None);
    }

    // #1084: the query must be a well-formed `lan.` SOA question -- correct
    // header counts, the `lan` label + root terminator, and QTYPE=SOA/QCLASS=IN
    // -- or a real server would not answer it.
    #[test]
    fn build_soa_query_is_a_valid_lan_soa_question() {
        let q = build_soa_query(0xABCD);
        assert_eq!(&q[0..2], &[0xAB, 0xCD], "transaction id");
        assert_eq!(&q[2..4], &[0x00, 0x00], "flags: RD off");
        assert_eq!(&q[4..6], &[0x00, 0x01], "QDCOUNT=1");
        assert_eq!(&q[6..8], &[0x00, 0x00], "ANCOUNT=0");
        // QNAME "lan." = 0x03 'l' 'a' 'n' 0x00
        assert_eq!(&q[12..18], &[0x03, b'l', b'a', b'n', 0x00, 0x00]);
        // ...followed by QTYPE=6 (SOA), QCLASS=1 (IN).
        assert_eq!(&q[17..21], &[0x00, 0x06, 0x00, 0x01]);
    }

    // Builds a minimal but real SOA response for `lan.` with the given id, AA
    // flag, and rcode, so the parser is tested against actual wire bytes
    // (including a compression pointer in the answer name, as PowerDNS emits).
    fn soa_response(id: u16, aa: bool, rcode: u8, serial: u32) -> Vec<u8> {
        let mut m = Vec::new();
        m.extend_from_slice(&id.to_be_bytes());
        let flags_hi = 0x80 | if aa { 0x04 } else { 0x00 }; // QR + optional AA
        m.push(flags_hi);
        m.push(rcode & 0x0F);
        m.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
        m.extend_from_slice(&1u16.to_be_bytes()); // ANCOUNT
        m.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
        m.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
                                                  // Question: lan. SOA IN
        m.extend_from_slice(&[0x03, b'l', b'a', b'n', 0x00, 0x00, 0x06, 0x00, 0x01]);
        // Answer: name = compression pointer to offset 12 (the question name).
        m.extend_from_slice(&[0xC0, 0x0C]);
        m.extend_from_slice(&QTYPE_SOA.to_be_bytes()); // TYPE SOA
        m.extend_from_slice(&QCLASS_IN.to_be_bytes()); // CLASS IN
        m.extend_from_slice(&3600u32.to_be_bytes()); // TTL
                                                     // RDATA: mname=ns.lan. rname=hostmaster.lan. serial refresh retry expire minimum
        let mut rdata = Vec::new();
        rdata.extend_from_slice(&[0x02, b'n', b's', 0xC0, 0x0C]); // ns + ptr to lan.
        rdata.extend_from_slice(&[0x0A]);
        rdata.extend_from_slice(b"hostmaster");
        rdata.extend_from_slice(&[0xC0, 0x0C]); // ptr to lan.
        rdata.extend_from_slice(&serial.to_be_bytes());
        rdata.extend_from_slice(&[0u8; 16]); // refresh/retry/expire/minimum
        m.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        m.extend_from_slice(&rdata);
        m
    }

    // #1084: an authoritative NOERROR SOA answer parses to the exact fields the
    // classifier needs -- rcode 0, AA set, an answer present, and the real
    // serial extracted through the answer's compression pointer.
    #[test]
    fn parse_soa_response_reads_rcode_aa_and_serial() {
        let resp = soa_response(0x1234, true, 0, 20260723);
        let (rcode, aa, ancount, serial) = parse_soa_response(0x1234, &resp).unwrap();
        assert_eq!(rcode, 0);
        assert!(aa);
        assert_eq!(ancount, 1);
        assert_eq!(serial, Some(20260723));
    }

    // #1084: a response whose transaction id does not match the query must be
    // rejected (a stray/forged datagram), not parsed as this probe's answer.
    #[test]
    fn parse_soa_response_rejects_id_mismatch() {
        let resp = soa_response(0x1111, true, 0, 1);
        assert!(parse_soa_response(0x2222, &resp).is_err());
    }

    // #1084: an authoritative NOERROR answer is the healthy state and surfaces
    // the serial.
    #[test]
    fn classify_authoritative_answer_is_ok_with_serial() {
        let r = classify(0, true, true, Some(42));
        assert_eq!(r.status, "ok");
        assert_eq!(r.serial, Some(42));
    }

    // #1084: an answer without the AA bit is flagged distinctly -- the host
    // answers but is not acting as an authority for lan.
    #[test]
    fn classify_non_authoritative_answer_is_flagged() {
        let r = classify(0, false, true, Some(7));
        assert_eq!(r.status, "not_authoritative");
    }

    // #1084: the distinct failure modes the issue asks to tell apart -- REFUSED
    // (not authoritative / zone missing) vs SERVFAIL (zone broken) vs a NOERROR
    // with no answer -- must map to distinct statuses.
    #[test]
    fn classify_distinguishes_refused_servfail_and_empty_noerror() {
        assert_eq!(classify(5, false, false, None).status, "no_zone");
        assert_eq!(classify(2, false, false, None).status, "broken");
        assert_eq!(classify(0, true, false, None).status, "error");
    }
}
