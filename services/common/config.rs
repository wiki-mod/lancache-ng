//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: env, bool, DHCP rules, container names, NATS, zones.
//! Why: one rule per value that several services read.
//! From: Issue #1683 | PR #1858

// What: an empty value counts as unset.
// Why: env files ship KEY= to mean unset.
// From: Issue #871 | PR #1858
pub fn non_empty(raw: Option<&str>) -> Option<&str> {
    raw.filter(|v| !v.is_empty())
}

// What: env var as a String; empty counts as unset.
// Why: the live-env reader of the non_empty rule.
// From: Issue #871 | PR #1858
pub fn env_opt(name: &str) -> Option<String> {
    non_empty(std::env::var(name).ok().as_deref()).map(str::to_string)
}

// What: 1/true/yes/on or 0/false/no/off, trimmed, any case.
// Why: one boolean grammar for ui, watchdog, retention.sh.
pub fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

// What: how a value outside [min, max] is resolved.
// Why: limits differ per knob, parsing does not.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutOfRange {
    Clamp,
    Default,
}

// What: one unsigned decimal knob and its limits.
// Why: every service parses numeric env values alike.
#[derive(Clone, Copy, Debug)]
pub struct Uint {
    pub name: &'static str,
    pub default: u64,
    pub min: u64,
    pub max: u64,
    pub below: OutOfRange,
    pub above: OutOfRange,
}

impl Uint {
    // What: value of the knob, plus a warning if rejected.
    // Why: blank is no warning; junk never crashes.
    pub fn parse(&self, raw: Option<&str>) -> (u64, Option<String>) {
        let Some(raw) = non_empty(raw.map(str::trim)) else {
            return (self.default, None);
        };
        let rejected = || {
            (
                self.default,
                Some(format!(
                    "Invalid {}={raw}; using default {}",
                    self.name, self.default
                )),
            )
        };
        if !raw.bytes().all(|b| b.is_ascii_digit()) {
            return rejected();
        }
        let Ok(value) = raw.parse::<u64>() else {
            return rejected();
        };
        let (limit, policy, side) = if value < self.min {
            (self.min, self.below, "below the minimum")
        } else if value > self.max {
            (self.max, self.above, "above the maximum")
        } else {
            return (value, None);
        };
        match policy {
            OutOfRange::Default => rejected(),
            OutOfRange::Clamp => (
                limit,
                Some(format!(
                    "{}={raw} is {side} ({limit}); using {limit}",
                    self.name
                )),
            ),
        }
    }
}

// What: the DHCP backend an install runs, or none.
// Why: ui and watchdog must read DHCP_MODE the same way.
// From: Issue #844
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DhcpMode {
    Disabled,
    Kea,
    DnsmasqProxy,
    DnsmasqRelay,
}

impl DhcpMode {
    // What: mode from text; empty uses the legacy flag.
    // Why: unknown text must fail closed to Disabled.
    // From: Issue #844
    pub fn parse(raw: &str, legacy_enabled: bool) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "kea" => Self::Kea,
            "dnsmasq-proxy" => Self::DnsmasqProxy,
            "dnsmasq-relay" => Self::DnsmasqRelay,
            "" if legacy_enabled => Self::Kea,
            _ => Self::Disabled,
        }
    }

    // What: the mode's text form, as DHCP_MODE spells it.
    // Why: the settings file and the ui use this text.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Kea => "kea",
            Self::DnsmasqProxy => "dnsmasq-proxy",
            Self::DnsmasqRelay => "dnsmasq-relay",
        }
    }

    // What: true only for the Kea backend.
    // Why: Kea alone has a control API to manage.
    pub fn is_kea(self) -> bool {
        matches!(self, Self::Kea)
    }

    // What: true for proxy and relay (one container).
    // Why: both run in dhcp-proxy with one config surface.
    pub fn is_dnsmasq(self) -> bool {
        matches!(self, Self::DnsmasqProxy | Self::DnsmasqRelay)
    }

    // What: true only for the relay variant of dnsmasq.
    // Why: relay has its own two settings, proxy has more.
    pub fn is_dnsmasq_relay(self) -> bool {
        matches!(self, Self::DnsmasqRelay)
    }

    // What: the one DHCP container this mode provisions.
    // Why: monitoring an absent container is a false alarm.
    pub fn container(self) -> Option<&'static str> {
        match self {
            Self::Kea => Some(CONTAINER_DHCP),
            Self::DnsmasqProxy | Self::DnsmasqRelay => Some(CONTAINER_DHCP_PROXY),
            Self::Disabled => None,
        }
    }
}

// What: fixed container names of the stack.
// Why: compose, the socket-proxy policy and services agree.
pub const CONTAINER_PROXY: &str = "lancache-proxy";
pub const CONTAINER_DNS_STANDARD: &str = "lancache-dns-standard";
pub const CONTAINER_DNS_SSL: &str = "lancache-dns-ssl";
pub const CONTAINER_NATS: &str = "lancache-nats";
pub const CONTAINER_UI: &str = "lancache-ui";
pub const CONTAINER_NETDATA: &str = "lancache-netdata";
pub const CONTAINER_DHCP: &str = "lancache-dhcp";
pub const CONTAINER_DHCP_PROXY: &str = "lancache-dhcp-proxy";
pub const CONTAINER_DHCP_PROBE: &str = "lancache-dhcp-probe";
pub const CONTAINER_SYSLOG: &str = "lancache-syslog";
pub const CONTAINER_NTP: &str = "lancache-ntp";
pub const CONTAINER_DOCKER_SOCKET_PROXY: &str = "lancache-docker-socket-proxy";

// What: the DNS stream and its subjects on NATS.
// Why: ui publishes, nats-subscriber consumes; one spelling.
pub const NATS_STREAM_DNS: &str = "LANCACHE_DNS";
pub const NATS_SUBJECT_DNS: &str = "lancache.dns.>";
pub const NATS_SUBJECT_RECORD: &str = "lancache.dns.record";
pub const NATS_SUBJECT_FLUSH: &str = "lancache.dns.flush";

// What: zones that get snapshots and rollbacks, dotted form.
// Why: equals DDNS_UPDATE_ZONES in dns/entrypoint.sh.
pub fn rollback_zones() -> Vec<String> {
    let fixed = [
        "lan.",
        "local.lan.",
        "10.in-addr.arpa.",
        "168.192.in-addr.arpa.",
    ];
    let rfc1918 = (16..=31).map(|n| format!("{n}.172.in-addr.arpa."));
    let ipv6 = ["c.f.ip6.arpa.", "d.f.ip6.arpa."];
    let all = fixed.iter().map(|z| z.to_string());
    all.chain(rfc1918)
        .chain(ipv6.iter().map(|z| z.to_string()))
        .collect()
}

// What: true for a zone with snapshots and rollback.
// Why: rpz and unknown zones must never be rolled back.
pub fn is_rollback_zone(zone: &str) -> bool {
    rollback_zones().iter().any(|z| z == zone)
}

// What: zone name in dotted form, as snapshot paths use it.
// Why: publishers send "lan", pdnsutil and the arrays "lan.".
pub fn canonical_zone(zone: &str) -> String {
    if zone.ends_with('.') {
        zone.to_string()
    } else {
        format!("{zone}.")
    }
}

// What: zone name as PowerDNS's HTTP API path spells it.
// Why: the API id has no trailing root dot.
pub fn zone_api_id(zone: &str) -> &str {
    zone.trim_end_matches('.')
}

#[cfg(test)]
mod tests {
    use super::*;

    // What: empty and absent are unset; other values pass.
    // Why: blank KEY= falls back like a missing key.
    // From: Issue #871 | PR #1858
    #[test]
    fn empty_value_counts_as_unset() {
        assert_eq!(non_empty(Some("")), None);
        assert_eq!(non_empty(None), None);
        assert_eq!(non_empty(Some("persistent")), Some("persistent"));
    }

    // What: the documented true and false sets parse.
    // Why: ui and watchdog must agree on what is on or off.
    #[test]
    fn parse_bool_matches_documented_sets() {
        for v in ["1", "true", "TRUE", "yes", "on", " on ", "\ttrue\n"] {
            assert_eq!(parse_bool(v), Some(true), "expected {v:?} true");
        }
        for v in ["0", "false", "no", "OFF", " off "] {
            assert_eq!(parse_bool(v), Some(false), "expected {v:?} false");
        }
        for v in ["", "garbage", "2", "onn"] {
            assert_eq!(parse_bool(v), None, "expected {v:?} unknown");
        }
    }

    // What: limits resolve by policy, junk falls back.
    // Why: one parser serves floors, ceilings and defaults.
    #[test]
    fn uint_knob_resolves_by_policy() {
        let knob = |below, above| Uint {
            name: "K",
            default: 30,
            min: 1,
            max: 100,
            below,
            above,
        };
        let floor = knob(OutOfRange::Clamp, OutOfRange::Default);
        assert_eq!(floor.parse(None), (30, None));
        assert_eq!(floor.parse(Some("  ")), (30, None));
        assert_eq!(floor.parse(Some(" 12 ")), (12, None));
        assert_eq!(floor.parse(Some("0")).0, 1);
        assert_eq!(floor.parse(Some("101")).0, 30);
        assert_eq!(floor.parse(Some("99999999999999999999")).0, 30);
        for junk in ["abc", "-5", "1x"] {
            let (value, warning) = floor.parse(Some(junk));
            assert_eq!(value, 30);
            assert!(warning.is_some_and(|w| w.contains(junk)));
        }
        let ceiling = knob(OutOfRange::Default, OutOfRange::Clamp);
        assert_eq!(ceiling.parse(Some("0")).0, 30);
        assert_eq!(ceiling.parse(Some("101")).0, 100);
    }

    // What: each mode text maps to one mode and container.
    // Why: unknown text must not select a DHCP container.
    // From: Issue #844
    #[test]
    fn dhcp_mode_maps_text_and_container() {
        assert_eq!(
            DhcpMode::parse("kea", false).container(),
            Some(CONTAINER_DHCP)
        );
        for text in ["dnsmasq-proxy", "dnsmasq-relay"] {
            let mode = DhcpMode::parse(text, false);
            assert_eq!(mode.as_str(), text);
            assert_eq!(mode.container(), Some(CONTAINER_DHCP_PROXY));
        }
        assert_eq!(DhcpMode::parse("disabled", false).container(), None);
        assert_eq!(DhcpMode::parse("bogus", true), DhcpMode::Disabled);
        assert_eq!(DhcpMode::parse("", true), DhcpMode::Kea);
        assert_eq!(DhcpMode::parse("", false), DhcpMode::Disabled);
    }

    // What: zone forms convert both ways without doubling dots.
    // Why: a doubled or missing dot misses the API path.
    #[test]
    fn zone_names_convert_between_dotted_and_api_form() {
        assert_eq!(canonical_zone("lan"), "lan.");
        assert_eq!(canonical_zone("lan."), "lan.");
        assert_eq!(
            zone_api_id("1.168.192.in-addr.arpa."),
            "1.168.192.in-addr.arpa"
        );
        assert_eq!(zone_api_id("lan"), "lan");
        assert!(is_rollback_zone("31.172.in-addr.arpa.") && !is_rollback_zone("rpz."));
        assert!(!is_rollback_zone("lan") && !is_rollback_zone("15.172.in-addr.arpa."));
    }

    // What: the zone list equals the entrypoint.sh zone arrays.
    // Why: no automated check ties the shell list to this one.
    #[test]
    fn rollback_zones_match_the_entrypoint_arrays() {
        let path = format!("{}/../dns/entrypoint.sh", env!("CARGO_MANIFEST_DIR"));
        let script = std::fs::read_to_string(&path).expect("services/dns/entrypoint.sh");
        let start = script.find("LAN_ZONES=(").expect("LAN_ZONES array");
        let end = script
            .find("DDNS_UPDATE_ZONES=")
            .expect("DDNS_UPDATE_ZONES");
        let in_script: Vec<&str> = script[start..end]
            .lines()
            .map(str::trim)
            .filter(|l| l.ends_with('.') && !l.contains(['=', '(', ')', ' ']))
            .collect();
        assert_eq!(rollback_zones(), in_script);
        assert!(!rollback_zones().contains(&"rpz.".to_string()));
    }
}
