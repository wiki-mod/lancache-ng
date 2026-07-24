//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! IPv4 reverse-DNS (PTR) helpers for the Admin UI's manual PTR record
//! management (#1077). Converts an operator-entered IPv4 address into the
//! `in-addr.arpa` PTR record name and the containing PowerDNS reverse zone
//! (restricted to the private reverse zones this project actually provisions:
//! `10.in-addr.arpa`, `168.192.in-addr.arpa`, and `16`–`31`.`172.in-addr.arpa`),
//! and parses a stored PTR rrset name back to a displayable IPv4 address for
//! the read/display half of the feature.
//!
//! IPv6 (`ip6.arpa`) is intentionally out of scope: this project provisions no
//! IPv6 reverse zones, so a manual PTR there would have no authoritative zone
//! to live in. The helpers reject anything outside the supported IPv4 ranges
//! rather than silently constructing a name for a zone that does not exist.

use std::net::Ipv4Addr;

/// The PowerDNS reverse zone id (no trailing dot — matching how PowerDNS zone
/// ids are addressed on the API path) that owns `ip`'s PTR record, or `None`
/// if `ip` is not in one of the private ranges this project provisions reverse
/// zones for. The three provisioned ranges map as:
/// - `10.0.0.0/8`        -> `10.in-addr.arpa`
/// - `192.168.0.0/16`    -> `168.192.in-addr.arpa`
/// - `172.16.0.0/12`     -> `{second-octet}.172.in-addr.arpa` (16..=31)
pub fn reverse_zone_for_ipv4(ip: Ipv4Addr) -> Option<String> {
    let [a, b, _, _] = ip.octets();
    match a {
        10 => Some("10.in-addr.arpa".to_string()),
        192 if b == 168 => Some("168.192.in-addr.arpa".to_string()),
        172 if (16..=31).contains(&b) => Some(format!("{b}.172.in-addr.arpa")),
        _ => None,
    }
}

/// The fully-qualified PTR record name for `ip` (e.g. `192.168.1.50` ->
/// `50.1.168.192.in-addr.arpa.`), with the trailing dot PowerDNS uses for
/// rrset names. `in-addr.arpa` reverses the octet order, hence `d.c.b.a`.
pub fn ptr_name_for_ipv4(ip: Ipv4Addr) -> String {
    let [a, b, c, d] = ip.octets();
    format!("{d}.{c}.{b}.{a}.in-addr.arpa.")
}

/// Parses a PTR rrset name as PowerDNS returns it (e.g.
/// `50.1.168.192.in-addr.arpa.`) back to the IPv4 address it represents, for
/// the display view. Returns `None` for anything that is not a well-formed
/// four-label IPv4 `in-addr.arpa` name — e.g. an `ip6.arpa` name or a
/// classless-delegation / partial name — so the caller keeps it out of the
/// IP-addressed table rather than showing a broken row.
pub fn ipv4_from_ptr_name(name: &str) -> Option<Ipv4Addr> {
    let trimmed = name.trim_end_matches('.').to_ascii_lowercase();
    let rest = trimmed.strip_suffix(".in-addr.arpa")?;
    let labels: Vec<&str> = rest.split('.').collect();
    if labels.len() != 4 {
        return None;
    }
    // in-addr.arpa stores the octets reversed (d.c.b.a), so label[0] is the
    // last address octet. Reject any label that is not a plain 0-255 integer
    // (u8::from_str rejects leading '+', overflow, and non-digits), which also
    // filters out empty labels from a malformed name.
    let mut octets = [0u8; 4];
    for (i, label) in labels.iter().enumerate() {
        octets[3 - i] = label.parse::<u8>().ok()?;
    }
    Some(Ipv4Addr::from(octets))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The three provisioned private ranges must each map to the exact PowerDNS
    // zone id the reverse zones are created under, and the 172.16/12 range must
    // pick the correct per-second-octet zone. This is the mapping the whole
    // feature relies on to PATCH the right zone; a wrong zone id would 404 or,
    // worse, write into an unexpected zone.
    #[test]
    fn reverse_zone_covers_each_provisioned_private_range() {
        assert_eq!(
            reverse_zone_for_ipv4("10.1.2.3".parse().unwrap()).as_deref(),
            Some("10.in-addr.arpa")
        );
        assert_eq!(
            reverse_zone_for_ipv4("192.168.1.50".parse().unwrap()).as_deref(),
            Some("168.192.in-addr.arpa")
        );
        assert_eq!(
            reverse_zone_for_ipv4("172.16.0.9".parse().unwrap()).as_deref(),
            Some("16.172.in-addr.arpa")
        );
        assert_eq!(
            reverse_zone_for_ipv4("172.31.255.254".parse().unwrap()).as_deref(),
            Some("31.172.in-addr.arpa")
        );
        assert_eq!(
            reverse_zone_for_ipv4("172.20.5.5".parse().unwrap()).as_deref(),
            Some("20.172.in-addr.arpa")
        );
    }

    // Addresses outside the provisioned private ranges (public IPs, and the
    // 172.0-15 / 172.32+ edges just outside 172.16/12) must return None so the
    // handler can reject them with a clear error instead of constructing a PTR
    // name for a reverse zone that does not exist in PowerDNS.
    #[test]
    fn reverse_zone_rejects_unprovisioned_ranges() {
        assert_eq!(reverse_zone_for_ipv4("8.8.8.8".parse().unwrap()), None);
        assert_eq!(reverse_zone_for_ipv4("192.167.1.1".parse().unwrap()), None);
        assert_eq!(reverse_zone_for_ipv4("172.15.0.1".parse().unwrap()), None);
        assert_eq!(reverse_zone_for_ipv4("172.32.0.1".parse().unwrap()), None);
        assert_eq!(reverse_zone_for_ipv4("11.0.0.1".parse().unwrap()), None);
    }

    // The PTR rrset name must reverse the octets and carry the trailing dot
    // PowerDNS expects on rrset names; a name without the trailing dot or in
    // forward order would not match the record PowerDNS actually stores.
    #[test]
    fn ptr_name_reverses_octets_with_trailing_dot() {
        assert_eq!(
            ptr_name_for_ipv4("192.168.1.50".parse().unwrap()),
            "50.1.168.192.in-addr.arpa."
        );
        assert_eq!(
            ptr_name_for_ipv4("10.0.0.1".parse().unwrap()),
            "1.0.0.10.in-addr.arpa."
        );
    }

    // Round-trip: a name built by ptr_name_for_ipv4 must parse back to the same
    // address, and a PowerDNS-style name (trailing dot, any case) must parse.
    // This is what the display view relies on to turn stored PTR rrsets back
    // into the IP column.
    #[test]
    fn ptr_name_round_trips_to_ipv4() {
        for ip in ["192.168.1.50", "10.255.255.254", "172.20.0.7"] {
            let addr: Ipv4Addr = ip.parse().unwrap();
            assert_eq!(ipv4_from_ptr_name(&ptr_name_for_ipv4(addr)), Some(addr));
        }
        assert_eq!(
            ipv4_from_ptr_name("50.1.168.192.IN-ADDR.ARPA."),
            Some("192.168.1.50".parse().unwrap())
        );
    }

    // Malformed or non-IPv4 reverse names must return None so they are skipped
    // in the IP-addressed display rather than rendered as a broken/empty row:
    // an ip6.arpa name, a too-short name, an out-of-range octet, and an empty
    // label are all rejected.
    #[test]
    fn ipv4_from_ptr_name_rejects_malformed_and_ipv6() {
        assert_eq!(
            ipv4_from_ptr_name(
                "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa."
            ),
            None
        );
        assert_eq!(ipv4_from_ptr_name("1.168.192.in-addr.arpa."), None);
        assert_eq!(ipv4_from_ptr_name("999.1.168.192.in-addr.arpa."), None);
        assert_eq!(ipv4_from_ptr_name("50..168.192.in-addr.arpa."), None);
        assert_eq!(ipv4_from_ptr_name("not-a-ptr-name"), None);
    }
}
