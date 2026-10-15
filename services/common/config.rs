//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: env, bool, DHCP, container, NATS and zone rules.
//! Why: one rule per value that several services read.
//! From: Issue #1683 | PR #1858

// What: an empty value counts as unset.
// Why: env files ship KEY= to mean unset.
// From: Issue #871 | PR #1858
pub fn non_empty(raw: Option<&str>) -> Option<&str> {
    raw.filter(|v| !v.is_empty())
}

// What: a variable from any reader; empty counts as unset.
// Why: ui, watchdog and tests read through one rule.
// From: Issue #1683 | PR #1905
pub fn opt(get: &dyn Fn(&str) -> Option<String>, name: &str) -> Option<String> {
    non_empty(get(name).as_deref()).map(str::to_string)
}

// What: the env name of the image's baked SOT defaults.
// Why: ci.sh passes runtime.defaults; images bake it.
// From: Issue #1683 | PR #1912
pub const RUNTIME_DEFAULTS_KEY: &str = "LANCACHE_RUNTIME_DEFAULTS";

// What: one name's value in a KEY=value list, if listed.
// Why: the SOT defaults travel as one pipe-joined list.
// From: Issue #1683 | PR #1912
pub fn default_in(list: &str, name: &str) -> Option<String> {
    list.split('|').find_map(|pair| {
        pair.split_once('=')
            .filter(|(key, _)| *key == name)
            .map(|(_, value)| value.to_string())
    })
}

// What: one variable of the process environment.
// Why: a set value wins; else the image's SOT default.
// From: Issue #1683 | PR #1905
pub fn process_env(name: &str) -> Option<String> {
    match std::env::var(name) {
        Ok(value) if !value.is_empty() => Some(value),
        other => std::env::var(RUNTIME_DEFAULTS_KEY)
            .ok()
            .and_then(|list| default_in(&list, name))
            .or(other.ok()),
    }
}

// What: the loopback address every local service binds.
// Why: the SOT owns it as LOOPBACK_BIND_IP; no literal.
// From: Issue #1683 | PR #1912
pub fn loopback() -> Result<String, String> {
    need(&process_env, "LOOPBACK_BIND_IP")
}

// What: the address that binds on every interface.
// Why: the SOT owns it as ANY_BIND_IP; no literal.
// From: Issue #1683 | PR #1912
pub fn any_bind(get: &dyn Fn(&str) -> Option<String>) -> Result<String, String> {
    need(get, "ANY_BIND_IP")
}

// What: env var as a String; empty counts as unset.
// Why: the live-env reader of the non_empty rule.
// From: Issue #871 | PR #1858
pub fn env_opt(name: &str) -> Option<String> {
    opt(&process_env, name)
}

// What: the LAN address a DHCP DNS key falls back to.
// Why: ui and dhcp share one rule; compose derives none.
// From: Issue #1683 | PR #1912
pub fn dhcp_dns_fallback(get: &dyn Fn(&str) -> Option<String>, key: &str) -> Option<String> {
    let lan = match key {
        "DHCP_DNS_PRIMARY" | "DHCP_DNS_SERVER_IP" => "IP_HTTP",
        "DHCP_DNS_SECONDARY" => "IP_HTTPS",
        _ => return None,
    };
    opt(get, lan)
}

// What: the error text of a variable nobody set.
// Why: one wording for need, Uint and the ui field checks.
// From: Issue #1683 | PR #1905
pub fn not_set(name: &str) -> String {
    format!("{name} is not set")
}

// What: a variable its owner must set; unset is an error.
// Why: owners hold every value; no service keeps a default.
// From: Issue #1683 | PR #1905
pub fn need(get: &dyn Fn(&str) -> Option<String>, name: &str) -> Result<String, String> {
    opt(get, name).ok_or_else(|| not_set(name))
}

// What: a boolean its owner must set; junk is an error.
// Why: a typo must not flip a gate to either side.
// From: Issue #1683 | PR #1905
pub fn need_flag(get: &dyn Fn(&str) -> Option<String>, name: &str) -> Result<bool, String> {
    let raw = need(get, name)?;
    parse_bool(&raw).ok_or_else(|| format!("{name} must be a boolean, got {raw:?}"))
}

// What: one KEY=value from the ui settings file, trimmed.
// Why: the ui saves live settings; services read them.
// From: Issue #1683
pub fn saved_setting(path: &std::path::Path, key: &str) -> Option<String> {
    let content = std::fs::read_to_string(path).ok()?;
    content.lines().map(str::trim).find_map(|line| {
        line.strip_prefix(key)
            .and_then(|rest| rest.strip_prefix('='))
            .map(|value| value.trim().to_string())
    })
}

// What: 1/true/yes/on or 0/false/no/off, trimmed, any case.
// Why: one boolean grammar for ui, watchdog, retention.
// From: Issue #1683 | PR #1905
pub fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

// What: how a value outside [min, max] is resolved.
// Why: limits differ per knob, parsing does not.
// From: Issue #1683 | PR #1905
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutOfRange {
    Clamp,
    Reject,
}

// What: one unsigned decimal knob and its limits.
// Why: the owner sets the number; Rust holds only limits.
// From: Issue #1683 | PR #1905
#[derive(Clone, Copy, Debug)]
pub struct Uint {
    pub name: &'static str,
    pub min: u64,
    pub max: u64,
    pub below: OutOfRange,
    pub above: OutOfRange,
}

impl Uint {
    // What: a knob that rejects values on both sides.
    // Why: knobs fail closed unless one side clamps.
    // From: Issue #1683 | PR #1912
    pub const fn strict(name: &'static str, min: u64, max: u64) -> Self {
        Self {
            name,
            min,
            max,
            below: OutOfRange::Reject,
            above: OutOfRange::Reject,
        }
    }

    // What: value of the knob, plus a warning if clamped.
    // Why: unset, junk or rejected values stop the start.
    // From: Issue #1683 | PR #1905
    pub fn parse(&self, raw: Option<&str>) -> Result<(u64, Option<String>), String> {
        let name = self.name;
        let raw = non_empty(raw.map(str::trim)).ok_or_else(|| not_set(name))?;
        // What: accept ASCII digits only.
        // Why: u64 parsing alone accepts a leading plus.
        // From: Issue #1683 | PR #1905
        if !raw.bytes().all(|b| b.is_ascii_digit()) {
            return Err(format!("{name}={raw} is not an unsigned decimal number"));
        }
        let value = raw
            .parse::<u64>()
            .map_err(|_| format!("{name}={raw} is too large"))?;
        let (limit, policy, side) = if value < self.min {
            (self.min, self.below, "below the minimum")
        } else if value > self.max {
            (self.max, self.above, "above the maximum")
        } else {
            return Ok((value, None));
        };
        match policy {
            OutOfRange::Reject => Err(format!("{name}={raw} is {side} ({limit})")),
            OutOfRange::Clamp => Ok((
                limit,
                Some(format!("{name}={raw} is {side} ({limit}); using {limit}")),
            )),
        }
    }
}

// What: a whole env number in min..=max, else an error.
// Why: every numeric env value takes the one Uint rule.
// From: Issue #1683 | PR #1912
pub fn uint(
    get: &dyn Fn(&str) -> Option<String>,
    name: &'static str,
    min: u64,
    max: u64,
) -> Result<u64, String> {
    let rule = Uint::strict(name, min, max);
    rule.parse(get(name).as_deref()).map(|(value, _)| value)
}

// What: the runtime uid/gid from LANCACHE_RUNTIME_GID.
// Why: ui and watchdog set shared files to one image id.
// From: Issue #1427 | PR #1912
pub fn runtime_gid() -> Result<u32, String> {
    uint(&process_env, "LANCACHE_RUNTIME_GID", 0, u32::MAX.into()).map(|g| g as u32)
}

// What: the proxy's syslog directory.
// Why: ui stats and netdata web_log share one path rule.
// From: Issue #1683 | PR #1912
pub fn proxy_log_dir(get: &dyn Fn(&str) -> Option<String>) -> Result<String, String> {
    let root = need(get, "SYSLOG_LOG_ROOT")?;
    Ok(std::path::Path::new(&root)
        .join(need(get, "CONTAINER_NAME_PROXY")?)
        .display()
        .to_string())
}

// What: KEEP_KNOWN_GOOD_CONFIGS, at least 1.
// Why: a rollback needs one good config to go back to.
// From: Issue #415 | PR #1912
pub fn keep_known_good(get: &dyn Fn(&str) -> Option<String>) -> Result<u32, String> {
    uint(get, "KEEP_KNOWN_GOOD_CONFIGS", 1, u32::MAX.into()).map(|v| v as u32)
}

// What: a port number 1 to 65535 from the env.
// Why: ui and watchdog read the SOT ports by one rule.
// From: Issue #1683 | PR #1912
pub fn port(get: &dyn Fn(&str) -> Option<String>, name: &'static str) -> Result<u16, String> {
    uint(get, name, 1, u16::MAX.into()).map(|p| p as u16)
}

// What: DHCP lease limits and the max-lifetime factor.
// Why: ui and watchdog apply one lease rule.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LeaseLimits {
    pub min: u32,
    pub max: u32,
    pub factor: u32,
}

impl LeaseLimits {
    // What: the three limits; junk or min above max fails.
    // Why: a lease rule that cannot hold stops the start.
    // From: Issue #1683 | PR #1912
    pub fn load(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        let num = |name| uint(get, name, 0, u32::MAX.into()).map(|v| v as u32);
        let limits = Self {
            min: num("DHCP_LEASE_TIME_MIN")?,
            max: num("DHCP_LEASE_TIME_MAX")?,
            factor: num("DHCP_MAX_LEASE_FACTOR")?,
        };
        if limits.min > limits.max || limits.factor == 0 {
            return Err(format!("DHCP lease limits do not fit: {limits:?}"));
        }
        Ok(limits)
    }

    // What: a lease from a reader, inside the limits.
    // Why: ui form, ui start and watchdog take one rule.
    // From: Issue #1683 | PR #1912
    pub fn lease(
        &self,
        get: &dyn Fn(&str) -> Option<String>,
        name: &'static str,
    ) -> Result<u32, String> {
        uint(get, name, self.min.into(), self.max.into()).map(|v| v as u32)
    }

    // What: Kea max-valid-lifetime of one lease.
    // Why: factor times the lease, capped at the maximum.
    // From: Issue #1683 | PR #1912
    pub fn max_lifetime(&self, lease: u32) -> u32 {
        lease.saturating_mul(self.factor).min(self.max)
    }
}

// What: SYSLOG_MAX_GB, the syslog store budget in GiB.
// Why: the ui shows and retention enforces one limit.
// From: Issue #633 | PR #1858
pub const SYSLOG_MAX_GB: Uint = Uint {
    name: "SYSLOG_MAX_GB",
    min: 1,
    max: 1_048_576,
    below: OutOfRange::Reject,
    above: OutOfRange::Clamp,
};

// What: the logging switches, as (key, container name key).
// Why: the SOT names the containers; syslog uses that name.
// From: Issue #1683 | PR #1912
pub const LOG_SWITCHES: [(&str, &str); 4] = [
    ("LOGGING_PROXY_ENABLED", "CONTAINER_NAME_PROXY"),
    ("LOGGING_DNS_ENABLED", "CONTAINER_NAME_DNS"),
    ("LOGGING_DHCP_ENABLED", "CONTAINER_NAME_DHCP"),
    ("LOGGING_UI_ENABLED", "CONTAINER_NAME_UI"),
];

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
    // What: every mode, the one list of valid mode names.
    // Why: ui validation and parse must not keep own lists.
    // From: Issue #1683 | PR #1905
    pub const ALL: [Self; 4] = [
        Self::Disabled,
        Self::Kea,
        Self::DnsmasqProxy,
        Self::DnsmasqRelay,
    ];

    // What: the mode whose text is exactly raw, or None.
    // Why: a form value is valid only as a known mode name.
    // From: Issue #1683 | PR #1905
    pub fn from_name(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.as_str() == raw)
    }

    // What: mode from text; unknown or empty is Disabled.
    // Why: unknown text must fail closed to Disabled.
    // From: Issue #844
    pub fn parse(raw: &str) -> Self {
        Self::from_name(&raw.trim().to_ascii_lowercase()).unwrap_or(Self::Disabled)
    }

    // What: the mode's text form, as DHCP_MODE spells it.
    // Why: the settings file and the ui use this text.
    // From: Issue #1683 | PR #1905
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
    // From: Issue #1683 | PR #1905
    pub fn is_kea(self) -> bool {
        matches!(self, Self::Kea)
    }

    // What: true for proxy and relay (one dnsmasq).
    // Why: both run dnsmasq with one config surface.
    // From: Issue #1683 | PR #1912
    pub fn is_dnsmasq(self) -> bool {
        matches!(self, Self::DnsmasqProxy | Self::DnsmasqRelay)
    }

    // What: true only for the relay variant of dnsmasq.
    // Why: relay has its own two settings, proxy has more.
    // From: Issue #1683 | PR #1905
    pub fn is_dnsmasq_relay(self) -> bool {
        matches!(self, Self::DnsmasqRelay)
    }
}

// What: one proxy access line as syslog-ng stores it.
// Why: the ui and netdata web_log parse it; one owner.
// From: Issue #1683 | PR #1912
pub const PROXY_ACCESS_LOG_PATTERN: &str = r#"^\S+ \S+ \S+: (?P<remote_addr>\S+) - \[(?P<time_local>[^\]]+)\] "(?P<request_method>\S+) (?P<request_uri>\S+) [^"]*" (?P<status>\d+) (?P<body_bytes_sent>\d+) "([^"]*)" "(?P<host>[^"]*)""#;

// What: marker file of the unsigned-DDNS switch.
// Why: the ui writes it; the dns supervisor restarts pdns.
// From: Issue #815
pub const DDNS_UNSIGNED_MARKER: &str = "ddns-allow-unsigned-updates";

// What: marker file of the AAAA filter switch.
// Why: the ui writes it; the recursor lua reads its path.
// From: Issue #1683 | PR #1912
pub const AAAA_FILTER_MARKER: &str = "aaaa-filter-enabled";

// What: the DNS stream and its subjects on NATS.
// Why: ui publishes, subscriber consumes; one spelling.
// From: Issue #1683 | PR #1905
pub const NATS_STREAM_DNS: &str = "LANCACHE_DNS";
pub const NATS_SUBJECT_DNS: &str = "lancache.dns.>";
pub const NATS_SUBJECT_RECORD: &str = "lancache.dns.record";
pub const NATS_SUBJECT_FLUSH: &str = "lancache.dns.flush";

// What: user and password of one static NATS role.
// Why: the password is Option so unset fails validation.
// From: Issue #1683 | PR #1912
pub struct NatsLogin {
    pub user: String,
    pub password: Option<String>,
}

// What: the four static NATS roles of the stack.
// Why: nats.conf, validation and callout share one list.
// From: Issue #1683 | PR #1912
pub struct NatsRoles {
    pub ui: NatsLogin,
    pub dns_writer: NatsLogin,
    pub callout: NatsLogin,
    pub sys: NatsLogin,
}

impl NatsRoles {
    // What: every role from its user and password keys.
    // Why: ui and dns read the same keys by their own rule.
    // From: Issue #1683 | PR #1912
    pub fn read(
        load: &dyn Fn(&str, &str) -> Result<NatsLogin, String>,
    ) -> Result<NatsRoles, String> {
        Ok(NatsRoles {
            ui: load("NATS_UI_USER", "NATS_UI_PASSWORD")?,
            dns_writer: load("NATS_DNS_WRITER_USER", "NATS_DNS_WRITER_PASSWORD")?,
            callout: load("NATS_CALLOUT_USER", "NATS_CALLOUT_PASSWORD")?,
            sys: load("NATS_SYS_USER", "NATS_SYS_PASSWORD")?,
        })
    }

    // What: the four roles with their display labels.
    // Why: validation and callout user list iterate them.
    // From: Issue #1683 | PR #1912
    pub fn labelled(&self) -> [(&'static str, &NatsLogin); 4] {
        [
            ("NATS UI", &self.ui),
            ("NATS DNS writer", &self.dns_writer),
            ("NATS auth-callout", &self.callout),
            ("NATS system account", &self.sys),
        ]
    }

    // What: every static role has valid credentials.
    // Why: nats.conf and the ui connection fail closed.
    // From: Issue #1683 | PR #1912
    pub fn validate(&self) -> Result<(), String> {
        self.labelled()
            .iter()
            .try_for_each(|(label, login)| validate_nats_login(label, login))
    }
}

// What: why a value cannot sit in a quoted NATS string.
// Why: a quote, backslash or control char breaks nats.conf.
// From: Issue #1683 | PR #1912
fn nats_text_problem(label: &str, value: &str) -> Option<String> {
    if value.is_empty() {
        Some(format!("{label} cannot be empty"))
    } else if value.chars().any(|c| (c as u32) < 32 || c as u32 == 127) {
        Some(format!("{label} contains control characters"))
    } else if value.contains('"') {
        Some(format!("{label} contains double quotes"))
    } else if value.contains('\\') {
        Some(format!("{label} contains backslashes"))
    } else {
        None
    }
}

// What: check one role's user name and password.
// Why: bad values must fail before nats.conf is written.
// From: Issue #1683 | PR #1912
fn validate_nats_login(label: &str, login: &NatsLogin) -> Result<(), String> {
    let problem = nats_text_problem("NATS username", &login.user)
        .or_else(|| {
            let allowed = |c: char| c.is_ascii_alphanumeric() || "_.-".contains(c);
            (!login.user.chars().all(allowed)).then(|| {
                format!(
                    "NATS username contains invalid characters (allowed: [A-Za-z0-9_.-]), got: {}",
                    login.user
                )
            })
        })
        .or_else(|| match login.password.as_deref() {
            Some(password) => nats_text_problem("NATS password", password),
            None => Some("NATS password cannot be empty".to_string()),
        });
    problem.map_or(Ok(()), |p| Err(format!("Invalid {label} credentials: {p}")))
}

// What: publish rights of every reader of the DNS stream.
// Why: static DNS roles and secondaries must grant alike.
// From: Issue #1683 | PR #1912
pub fn dns_reader_publish() -> Vec<String> {
    let stream = NATS_STREAM_DNS;
    [
        format!("$JS.API.STREAM.INFO.{stream}"),
        format!("$JS.API.CONSUMER.INFO.{stream}.>"),
        format!("$JS.API.CONSUMER.CREATE.{stream}.>"),
        format!("$JS.API.CONSUMER.DURABLE.CREATE.{stream}.>"),
        format!("$JS.API.CONSUMER.MSG.NEXT.{stream}.>"),
        format!("$JS.ACK.{stream}.>"),
    ]
    .into()
}

// What: subjects every reader of the DNS stream receives.
// Why: static DNS roles and secondaries must grant alike.
// From: Issue #1683 | PR #1912
pub fn dns_subscribe() -> [&'static str; 2] {
    [NATS_SUBJECT_DNS, "_INBOX.>"]
}

// What: a NATS list of double-quoted strings.
// Why: every subject list in nats.conf uses one syntax.
// From: Issue #1683 | PR #1912
fn nats_list<S: AsRef<str>>(items: &[S]) -> String {
    let quoted: Vec<String> = items
        .iter()
        .map(|s| format!("\"{}\"", s.as_ref()))
        .collect();
    format!("[{}]", quoted.join(", "))
}

// What: one static user block, rights only when given.
// Why: the callout user must have no subject rights.
// From: Issue #1683 | PR #1912
fn nats_role_block<P: AsRef<str>, S: AsRef<str>>(
    login: &NatsLogin,
    publish: &[P],
    subscribe: &[S],
) -> String {
    let password = login.password.as_deref().unwrap_or_default();
    let mut block = format!(
        "    {{\n      user: \"{}\"\n      password: \"{password}\"\n",
        login.user
    );
    if !publish.is_empty() {
        block.push_str("      permissions = {\n");
        block.push_str(&format!("        publish = {}\n", nats_list(publish)));
        if !subscribe.is_empty() {
            block.push_str(&format!("        subscribe = {}\n", nats_list(subscribe)));
        }
        block.push_str("      }\n");
    }
    block.push_str("    }\n");
    block
}

// What: the static nats.conf of the stack's fixed roles.
// Why: one owner of NATS users, rights and the include.
// From: Issue #1683 | PR #1858
pub fn render_nats_conf(
    roles: &NatsRoles,
    store_dir: &str,
    monitor_port: u16,
    conf_path: &str,
    fragment_path: &str,
) -> Result<String, String> {
    roles.validate()?;
    let fragment = std::path::Path::new(fragment_path);
    if fragment.parent() != std::path::Path::new(conf_path).parent() {
        return Err(format!("{fragment_path} must sit next to {conf_path}"));
    }
    let include = fragment
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| format!("{fragment_path} has no file name"))?;
    for (label, value) in [
        ("NATS store dir", store_dir),
        ("NATS fragment name", include),
    ] {
        if let Some(problem) = nats_text_problem(label, value) {
            return Err(problem);
        }
    }
    let writer_publish: Vec<String> = [NATS_SUBJECT_RECORD, NATS_SUBJECT_FLUSH]
        .into_iter()
        .map(str::to_string)
        .chain([format!("$JS.API.STREAM.CREATE.{NATS_STREAM_DNS}")])
        .chain(dns_reader_publish())
        .collect();
    let none: [&str; 0] = [];
    let users = [
        nats_role_block(&roles.ui, &[NATS_SUBJECT_RECORD, NATS_SUBJECT_FLUSH], &none),
        nats_role_block(&roles.dns_writer, &writer_publish, &dns_subscribe()),
        nats_role_block(&roles.callout, &none, &none),
    ]
    .concat();
    let sys = &roles.sys;
    let sys_password = sys.password.as_deref().unwrap_or_default();
    let sys_user = &sys.user;
    Ok(format!(
        "jetstream {{\n  store_dir: \"{store_dir}\"\n}}\n\
         http_port: {monitor_port}\n\
         authorization {{\n  users = [\n{users}  ]\n  include \"{include}\"\n}}\n\
         accounts {{\n  SYS: {{\n    users: [\n      \
         {{ user: \"{sys_user}\", password: \"{sys_password}\" }}\n    ]\n  }}\n}}\n\
         system_account: SYS\n"
    ))
}

// What: TTL of a record written without one, in seconds.
// Why: ui forms and the subscriber must default alike.
// From: Issue #1683 | PR #1905
pub const DEFAULT_RECORD_TTL: i32 = 300;

// What: the local zone name, as publishers spell it.
// Why: DHCP_DOMAIN is the one SOT owner of the name.
// From: Issue #1683 | PR #1912
pub fn lan_zone(get: &dyn Fn(&str) -> Option<String>) -> Result<String, String> {
    need(get, "DHCP_DOMAIN")
}

// What: the IPv4 reverse zones the stack provisions.
// Why: PTR records live in these; no lan name is involved.
// From: Issue #1683 | PR #1912
pub fn reverse_zones() -> Vec<String> {
    let fixed = ["10.in-addr.arpa.", "168.192.in-addr.arpa."].map(str::to_string);
    let rfc1918 = (16..=31).map(|n| format!("{n}.172.in-addr.arpa."));
    fixed.into_iter().chain(rfc1918).collect()
}

// What: zones with snapshots and rollbacks, dotted form.
// Why: dns creates, snapshots and rolls back these.
// From: Issue #1683 | PR #1905
pub fn rollback_zones(lan_zone: &str) -> Vec<String> {
    let lan = canonical_zone(lan_zone);
    let local = format!("local.{lan}");
    let ipv6 = ["c.f.ip6.arpa.", "d.f.ip6.arpa."];
    std::iter::once(lan)
        .chain(std::iter::once(local))
        .chain(reverse_zones())
        .chain(ipv6.iter().map(|z| z.to_string()))
        .collect()
}

// What: true for a zone with snapshots and rollback.
// Why: rpz and unknown zones must never be rolled back.
// From: Issue #1683 | PR #1905
pub fn is_rollback_zone(lan_zone: &str, zone: &str) -> bool {
    rollback_zones(lan_zone).iter().any(|z| z == zone)
}

// What: zone name in dotted form, as snapshot paths use it.
// Why: publishers send "lan", pdnsutil and arrays "lan.".
// From: Issue #1683 | PR #1905
pub fn canonical_zone(zone: &str) -> String {
    if zone.ends_with('.') {
        zone.to_string()
    } else {
        format!("{zone}.")
    }
}

// What: DNS name syntax without a trailing dot.
// Why: one rule for CDN, DHCP, LAN names and API zone ids.
// From: Issue #1683 | PR #1905
pub fn is_dns_name(name: &str, underscore: bool, wildcard: bool) -> bool {
    !name.is_empty()
        && name.len() <= 253
        && name.split('.').enumerate().all(|(index, label)| {
            (wildcard && index == 0 && label == "*")
                || (!label.is_empty()
                    && label.len() <= 63
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || b == b'-' || (underscore && b == b'_')
                    }))
        })
}

// What: a cdn-domains entry as (name, wildcard-only).
// Why: ui, dns and proxy share one rule; "." = wildcard.
// From: Issue #1683 | PR #1912
pub fn cdn_entry(text: &str) -> Option<(String, bool)> {
    let lower = text.trim().to_ascii_lowercase();
    let (wildcard, name) = match lower.strip_prefix('.') {
        Some(rest) => (true, rest),
        None => (false, lower.as_str()),
    };
    (name.contains('.') && is_dns_name(name, false, false)).then(|| (name.to_string(), wildcard))
}

// What: the path of PowerDNS's API below a server address.
// Why: ui and the dns supervisor append the same path.
// From: Issue #1683 | PR #1905
pub const PDNS_API_PATH: &str = "/api/v1/servers/localhost";

// What: URL of one zone below a PowerDNS API root.
// Why: a trailing dot in the path is a silent 404.
// From: Issue #1683 | PR #1905
pub fn zone_url(api_root: &str, zone: &str) -> String {
    format!("{api_root}/zones/{}", zone_api_id(zone))
}

// What: zone name as PowerDNS's HTTP API path spells it.
// Why: the API id has no trailing root dot.
// From: Issue #1683 | PR #1905
pub fn zone_api_id(zone: &str) -> &str {
    zone.trim_end_matches('.')
}

// What: option codes the dedicated subnet fields own.
// Why: routers 3, DNS 6, domain 15, NTP 42, search 119.
// From: Issue #1683 | PR #1912
pub const KEA_MANAGED_CODES: [u16; 5] = [3, 6, 15, 42, 119];

// What: option codes dnsmasq-proxy renders itself.
// Why: Kea's list without search; search stays custom.
// From: Issue #1683 | PR #1912
pub const DNSMASQ_MANAGED_CODES: &[u16] = KEA_MANAGED_CODES.split_at(4).0;

// What: lowest and highest code an operator may add.
// Why: 0 is padding and 255 is the end marker.
// From: Issue #1683 | PR #1912
pub const OPTION_CODE_MIN: u16 = 1;
pub const OPTION_CODE_MAX: u16 = 254;

// What: an option code from form text, range checked.
// Why: Kea and dnsmasq forms share one number rule.
// From: Issue #1683 | PR #1912
pub fn option_code(raw: &str) -> Result<u16, &'static str> {
    let code = raw
        .trim()
        .parse::<u16>()
        .map_err(|_| "option code must be a number")?;
    if !(OPTION_CODE_MIN..=OPTION_CODE_MAX).contains(&code) {
        return Err("option code must be between 1 and 254");
    }
    Ok(code)
}

// What: longest custom option value in bytes.
// Why: one form must not write unbounded data into Kea.
// From: Issue #1683 | PR #1912
pub const CUSTOM_OPTION_DATA_MAX: usize = 1024;

// What: one-line option data within the length limit.
// Why: values are opaque strings; only the shape counts.
// From: Issue #1683 | PR #1912
pub fn option_data(raw: &str) -> Result<String, &'static str> {
    let data = raw.trim();
    if data.is_empty() {
        return Err("option data must not be empty");
    }
    if data.len() > CUSTOM_OPTION_DATA_MAX {
        return Err("option data is too long");
    }
    if data.contains(['\n', '\r']) {
        return Err("option data must fit on one line");
    }
    Ok(data.to_string())
}

// What: parse "CODE:VALUE" lines into the stored form.
// Why: the file keeps one line; entries join by semicolon.
// From: Issue #1683 | PR #1912
pub fn parse_custom_options(raw: &str) -> Result<String, String> {
    let mut entries = Vec::new();
    for (index, line) in raw.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let at = |message: &str| format!("line {}: {message}", index + 1);
        let (code, data) = line
            .split_once(':')
            .ok_or_else(|| at("expected CODE:VALUE"))?;
        // What: refuse the four codes dnsmasq-proxy owns.
        // Why: dnsmasq renders router, DNS, domain, NTP.
        // From: Issue #1683 | PR #1912
        let code = option_code(code).map_err(at)?;
        if DNSMASQ_MANAGED_CODES.contains(&code) {
            return Err(at(
                "option code is managed by dedicated dnsmasq-proxy fields",
            ));
        }
        let data = option_data(data).map_err(at)?;
        // What: refuse a semicolon inside option data.
        // Why: it is the entry separator on the shell side.
        // From: Issue #1683 | PR #1912
        if data.contains(';') {
            return Err(at(
                "option data must not contain ';' (used as the entry separator)",
            ));
        }
        entries.push(format!("{code}:{data}"));
    }
    Ok(entries.join(";"))
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

    // What: a listed name gives its value; others none.
    // Why: the image's SOT defaults are one KEY=value list.
    // From: Issue #1683 | PR #1912
    #[test]
    fn default_in_finds_the_exact_name() {
        let list = "A_PORT=81|B_PORT=82|C=x=y|R=a b [c]";
        assert_eq!(default_in(list, "B_PORT"), Some("82".to_string()));
        assert_eq!(default_in(list, "C"), Some("x=y".to_string()));
        assert_eq!(default_in(list, "R"), Some("a b [c]".to_string()));
        assert_eq!(default_in(list, "A"), None);
        assert_eq!(default_in(list, "D"), None);
        assert_eq!(default_in("", "A_PORT"), None);
    }

    // What: a DHCP DNS key falls back to its LAN address.
    // Why: compose derives no fallback; the rule is here.
    // From: Issue #1683 | PR #1912
    #[test]
    fn dhcp_dns_keys_fall_back_to_the_lan_addresses() {
        let get = |name: &str| match name {
            "IP_HTTP" => Some("10.0.0.2".to_string()),
            "IP_HTTPS" => Some(String::new()),
            _ => None,
        };
        assert_eq!(
            dhcp_dns_fallback(&get, "DHCP_DNS_PRIMARY"),
            Some("10.0.0.2".to_string())
        );
        assert_eq!(
            dhcp_dns_fallback(&get, "DHCP_DNS_SERVER_IP"),
            Some("10.0.0.2".to_string())
        );
        assert_eq!(dhcp_dns_fallback(&get, "DHCP_DNS_SECONDARY"), None);
        assert_eq!(dhcp_dns_fallback(&get, "DHCP_GATEWAY"), None);
    }

    // What: the documented true and false sets parse.
    // Why: ui and watchdog must agree on what is on or off.
    // From: Issue #1683 | PR #1905
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

    // What: limits resolve by policy; unset and junk fail.
    // Why: one parser serves floors and ceilings alike.
    // From: Issue #1683 | PR #1905
    #[test]
    fn uint_knob_resolves_by_policy() {
        let knob = |below, above| Uint {
            name: "K",
            min: 1,
            max: 100,
            below,
            above,
        };
        let floor = knob(OutOfRange::Clamp, OutOfRange::Reject);
        assert!(floor.parse(None).unwrap_err().contains("not set"));
        assert!(floor.parse(Some("  ")).is_err());
        assert_eq!(floor.parse(Some(" 12 ")), Ok((12, None)));
        assert_eq!(floor.parse(Some("0")).unwrap().0, 1);
        assert!(floor.parse(Some("0")).unwrap().1.is_some());
        assert!(floor.parse(Some("101")).is_err());
        assert!(floor.parse(Some("99999999999999999999")).is_err());
        for junk in ["abc", "-5", "1x"] {
            assert!(floor.parse(Some(junk)).unwrap_err().contains(junk));
        }
        let ceiling = knob(OutOfRange::Reject, OutOfRange::Clamp);
        assert!(ceiling.parse(Some("0")).is_err());
        assert_eq!(ceiling.parse(Some("101")).unwrap().0, 100);
    }

    // What: each mode text maps to one mode.
    // Why: unknown text must not start a DHCP server.
    // From: Issue #844
    #[test]
    fn dhcp_mode_maps_text() {
        for mode in DhcpMode::ALL {
            assert_eq!(
                DhcpMode::parse(&format!(" {} ", mode.as_str().to_uppercase())),
                mode
            );
        }
        assert_eq!(DhcpMode::parse("bogus"), DhcpMode::Disabled);
        assert_eq!(DhcpMode::parse(""), DhcpMode::Disabled);
    }

    // What: the CDN entry rule agrees with the fixture.
    // Why: ui, dns and proxy must accept the same rows.
    // From: Issue #1683 | PR #1912
    #[test]
    fn cdn_entry_matches_the_fixture_and_the_list() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
        let fixture =
            std::fs::read_to_string(format!("{root}/tests/fixtures/domain-validation-cases.txt"))
                .expect("shared fixture");
        let mut cases = 0;
        for line in fixture.lines().map(str::trim_end) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (verdict, domain) = line.split_once(' ').expect("verdict and domain");
            assert_eq!(cdn_entry(domain).is_some(), verdict == "valid", "{line}");
            cases += 1;
        }
        assert!(cases > 0, "the fixture holds no cases");
        let list = std::fs::read_to_string(format!("{root}/services/dns/cdn-domains.txt"))
            .expect("cdn list");
        for line in list.lines().map(str::trim) {
            let row = line.strip_prefix('!').unwrap_or(line);
            if !row.is_empty() && !row.starts_with('#') {
                assert!(cdn_entry(row).is_some(), "cdn-domains.txt rejects {line:?}");
            }
        }
        let label = "a".repeat(63);
        let long = format!("{label}.{label}.{label}.{}.com", "a".repeat(57));
        assert_eq!(long.len(), 253);
        assert!(cdn_entry(&long).is_some() && cdn_entry(&format!("a{long}")).is_none());
        assert!(cdn_entry(&format!("{label}a.com")).is_none());
    }

    // What: the mode list holds the four names, none twice.
    // Why: ui validation reads it; a gap rejects a mode.
    // From: Issue #1683 | PR #1905
    #[test]
    fn dhcp_mode_names_are_the_four_known_ones() {
        let names: Vec<&str> = DhcpMode::ALL.iter().map(|m| m.as_str()).collect();
        assert_eq!(names, ["disabled", "kea", "dnsmasq-proxy", "dnsmasq-relay"]);
        assert_eq!(DhcpMode::from_name("kea"), Some(DhcpMode::Kea));
        assert_eq!(DhcpMode::from_name("Kea"), None);
        assert_eq!(DhcpMode::from_name(""), None);
    }

    // What: zone forms convert both ways, no doubled dots.
    // Why: a doubled or missing dot misses the API path.
    // From: Issue #1683 | PR #1905
    #[test]
    fn zone_names_convert_between_dotted_and_api_form() {
        assert_eq!(canonical_zone("lan"), "lan.");
        assert_eq!(canonical_zone("lan."), "lan.");
        assert_eq!(
            zone_api_id("1.168.192.in-addr.arpa."),
            "1.168.192.in-addr.arpa"
        );
        assert_eq!(zone_api_id("lan"), "lan");
        let lan = "home-zone";
        assert!(is_rollback_zone(lan, "31.172.in-addr.arpa.") && !is_rollback_zone(lan, "rpz."));
        assert!(is_rollback_zone(lan, &canonical_zone(lan)));
        assert!(!is_rollback_zone(lan, lan) && !is_rollback_zone(lan, "15.172.in-addr.arpa."));
    }

    // What: need and need_flag reject unset, empty, junk.
    // Why: no service runs on a value its owner never set.
    // From: Issue #1683 | PR #1905
    #[test]
    fn need_rejects_unset_empty_and_junk() {
        let get = |key: &str| match key {
            "SET" => Some("x".to_string()),
            "EMPTY" => Some(String::new()),
            "ON" => Some("on".to_string()),
            "JUNK" => Some("maybe".to_string()),
            _ => None,
        };
        assert_eq!(need(&get, "SET"), Ok("x".to_string()));
        assert!(need(&get, "EMPTY").is_err() && need(&get, "ABSENT").is_err());
        assert_eq!(need_flag(&get, "ON"), Ok(true));
        assert!(need_flag(&get, "JUNK").is_err() && need_flag(&get, "ABSENT").is_err());
    }

    // What: DNS names pass or fail by label rules.
    // Why: a zone name is spliced into an API URL path.
    // From: Issue #1683 | PR #1905
    #[test]
    fn dns_names_follow_the_label_rules() {
        assert!(is_dns_name("lan", false, false));
        assert!(is_dns_name("1.168.192.in-addr.arpa", false, false));
        assert!(is_dns_name("_srv.lan", true, false) && !is_dns_name("_srv.lan", false, false));
        assert!(is_dns_name("*.lan", false, true) && !is_dns_name("*.lan", false, false));
        for bad in [
            "", "a..b", "-a.lan", "a-.lan", "a/b", "a b", "a?x=1", "../x", "a%2Fb",
        ] {
            assert!(!is_dns_name(bad, true, true), "{bad:?} must fail");
        }
        assert!(!is_dns_name(&"a".repeat(64), false, false));
        assert!(!is_dns_name(
            &format!("{}.com", "a.".repeat(127)),
            false,
            false
        ));
    }

    // What: zone_url drops the trailing dot of the zone.
    // Why: a dotted zone in the API path is a silent 404.
    // From: Issue #1683 | PR #1905
    #[test]
    fn zone_url_uses_the_undotted_id() {
        assert_eq!(
            zone_url("http://pdns/api", "lan."),
            "http://pdns/api/zones/lan"
        );
        assert_eq!(
            zone_url("http://pdns/api", "lan"),
            "http://pdns/api/zones/lan"
        );
    }

    // What: the live-env readers see the real environment.
    // Why: they are the only readers of the process env.
    // From: Issue #871 | PR #1858
    #[test]
    fn live_env_readers_follow_the_process_environment() {
        let path = std::env::var("PATH").unwrap();
        assert_eq!(process_env("PATH"), Some(path.clone()));
        assert_eq!(env_opt("PATH"), Some(path));
        assert_eq!(process_env("LANCACHE_TEST_NEVER_SET"), None);
        assert_eq!(env_opt("LANCACHE_TEST_NEVER_SET"), None);
    }

    // What: limits are inclusive; one outside fails.
    // Why: an off-by-one would accept a forbidden value.
    // From: Issue #1683 | PR #1905
    #[test]
    fn uint_limits_are_inclusive() {
        let knob = Uint {
            name: "KNOB",
            min: 5,
            max: 10,
            below: OutOfRange::Reject,
            above: OutOfRange::Reject,
        };
        assert_eq!(knob.parse(Some("5")), Ok((5, None)));
        assert_eq!(knob.parse(Some("10")), Ok((10, None)));
        assert!(knob.parse(Some("4")).is_err());
        assert!(knob.parse(Some("11")).is_err());
    }

    // What: lease limits load, bound and cap one rule.
    // Why: ui and watchdog wrote Kea lifetimes apart.
    // From: Issue #1683 | PR #1912
    #[test]
    fn lease_limits_bound_and_cap_the_lifetime() {
        let env = |min: &'static str, max: &'static str, factor: &'static str| {
            move |key: &str| match key {
                "DHCP_LEASE_TIME_MIN" => Some(min.to_string()),
                "DHCP_LEASE_TIME_MAX" => Some(max.to_string()),
                "DHCP_MAX_LEASE_FACTOR" => Some(factor.to_string()),
                _ => None,
            }
        };
        let limits = LeaseLimits::load(&env("10", "100", "3")).expect("limits");
        let lease = |raw: &'static str| limits.lease(&move |_| Some(raw.into()), "DHCP_LEASE_TIME");
        assert_eq!((lease("10"), lease("100")), (Ok(10), Ok(100)));
        assert!(lease("9").is_err() && lease("101").is_err());
        assert_eq!(limits.max_lifetime(20), 60);
        assert_eq!(limits.max_lifetime(50), 100);
        assert_eq!(limits.max_lifetime(u32::MAX), 100);
        for bad in [
            env("100", "10", "3"),
            env("10", "100", "0"),
            env("x", "100", "3"),
        ] {
            assert!(LeaseLimits::load(&bad).is_err());
        }
    }

    // What: each DHCP mode answers the backend questions.
    // Why: services pick containers from these answers.
    // From: Issue #1683 | PR #1905
    #[test]
    fn dhcp_modes_answer_the_backend_questions() {
        let table = [
            (DhcpMode::Disabled, false, false, false),
            (DhcpMode::Kea, true, false, false),
            (DhcpMode::DnsmasqProxy, false, true, false),
            (DhcpMode::DnsmasqRelay, false, true, true),
        ];
        for (mode, kea, dnsmasq, relay) in table {
            assert_eq!(mode.is_kea(), kea);
            assert_eq!(mode.is_dnsmasq(), dnsmasq);
            assert_eq!(mode.is_dnsmasq_relay(), relay);
        }
    }

    fn login(user: &str, password: Option<&str>) -> NatsLogin {
        NatsLogin {
            user: user.to_string(),
            password: password.map(str::to_string),
        }
    }

    // What: the four roles, each with password pw-<user>.
    // Why: nats.conf and the callout list render from it.
    // From: Issue #1683 | PR #1912
    fn roles() -> NatsRoles {
        let users = [
            ("NATS_UI_USER", "ui"),
            ("NATS_DNS_WRITER_USER", "dnsw"),
            ("NATS_CALLOUT_USER", "callout"),
            ("NATS_SYS_USER", "sys"),
        ];
        NatsRoles::read(&|user_key, _| {
            let user = users.iter().find(|(k, _)| *k == user_key).unwrap().1;
            Ok(login(user, Some(&format!("pw-{user}"))))
        })
        .unwrap()
    }

    // What: unsafe NATS strings are named by their problem.
    // Why: a quote or control char breaks nats.conf.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nats_text_problems_are_named() {
        assert_eq!(
            nats_text_problem("L", ""),
            Some("L cannot be empty".to_string())
        );
        for control in ["a\nb", "a\u{7f}b", "a\u{1f}"] {
            let want = Some("L contains control characters".to_string());
            assert_eq!(nats_text_problem("L", control), want, "{control:?}");
        }
        let quote = nats_text_problem("L", "a\"b");
        assert_eq!(quote, Some("L contains double quotes".to_string()));
        let slash = nats_text_problem("L", "a\\b");
        assert_eq!(slash, Some("L contains backslashes".to_string()));
        assert_eq!(nats_text_problem("L", "fine value 1"), None);
        assert_eq!(nats_text_problem("L", " "), None);
    }

    // What: a role needs a plain user and a safe password.
    // Why: bad values must fail before nats.conf is made.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nats_logins_are_validated_with_a_role_label() {
        assert_eq!(
            validate_nats_login("R", &login("ui-1.a_b", Some("x"))),
            Ok(())
        );
        let cases = [
            (login("", Some("x")), "NATS username cannot be empty"),
            (login("ui", None), "NATS password cannot be empty"),
            (login("ui", Some("")), "NATS password cannot be empty"),
            (
                login("ui", Some("a\"b")),
                "NATS password contains double quotes",
            ),
            (
                login("bad user", Some("x")),
                "NATS username contains invalid characters (allowed: [A-Za-z0-9_.-]), got: bad user",
            ),
        ];
        for (bad, problem) in cases {
            let want = Err(format!("Invalid R credentials: {problem}"));
            assert_eq!(validate_nats_login("R", &bad), want);
        }
        let all = roles();
        assert_eq!(all.validate(), Ok(()));
        let labels: Vec<&str> = all.labelled().iter().map(|(label, _)| *label).collect();
        assert_eq!(
            labels,
            [
                "NATS UI",
                "NATS DNS writer",
                "NATS auth-callout",
                "NATS system account"
            ]
        );
        let mut no_password = roles();
        no_password.sys.password = None;
        assert_eq!(
            no_password.validate(),
            Err("Invalid NATS system account credentials: NATS password cannot be empty".into())
        );
    }

    // What: lists and role blocks use the nats.conf syntax.
    // Why: the callout user must have no subject rights.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nats_role_blocks_grant_rights_only_when_given() {
        assert_eq!(nats_list(&["a", "b.>"]), "[\"a\", \"b.>\"]");
        assert_eq!(nats_list::<&str>(&[]), "[]");
        let user = login("u", Some("p"));
        let none: [&str; 0] = [];
        assert_eq!(
            nats_role_block(&user, &none, &none),
            "    {\n      user: \"u\"\n      password: \"p\"\n    }\n"
        );
        assert_eq!(
            nats_role_block(&user, &["x"], &none),
            "    {\n      user: \"u\"\n      password: \"p\"\n      permissions = {\n        publish = [\"x\"]\n      }\n    }\n"
        );
        assert_eq!(
            nats_role_block(&user, &["x"], &["y"]),
            "    {\n      user: \"u\"\n      password: \"p\"\n      permissions = {\n        publish = [\"x\"]\n        subscribe = [\"y\"]\n      }\n    }\n"
        );
        assert_eq!(
            nats_role_block(&user, &none, &["y"]),
            "    {\n      user: \"u\"\n      password: \"p\"\n    }\n"
        );
    }

    // What: DNS readers get fixed publish and subscribe.
    // Why: static DNS roles and secondaries grant alike.
    // From: Issue #1683 | PR #1912
    #[test]
    fn dns_reader_rights_are_fixed() {
        assert_eq!(
            dns_reader_publish(),
            [
                "$JS.API.STREAM.INFO.LANCACHE_DNS",
                "$JS.API.CONSUMER.INFO.LANCACHE_DNS.>",
                "$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>",
                "$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>",
                "$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>",
                "$JS.ACK.LANCACHE_DNS.>",
            ]
        );
        assert_eq!(dns_subscribe(), ["lancache.dns.>", "_INBOX.>"]);
    }

    // What: the static nats.conf for the fixed roles.
    // Why: one owner of NATS users, rights and the include.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nats_conf_renders_roles_and_the_include() {
        let writer = "[\"lancache.dns.record\", \"lancache.dns.flush\", \"$JS.API.STREAM.CREATE.LANCACHE_DNS\", \"$JS.API.STREAM.INFO.LANCACHE_DNS\", \"$JS.API.CONSUMER.INFO.LANCACHE_DNS.>\", \"$JS.API.CONSUMER.CREATE.LANCACHE_DNS.>\", \"$JS.API.CONSUMER.DURABLE.CREATE.LANCACHE_DNS.>\", \"$JS.API.CONSUMER.MSG.NEXT.LANCACHE_DNS.>\", \"$JS.ACK.LANCACHE_DNS.>\"]";
        let reader = "[\"lancache.dns.>\", \"_INBOX.>\"]";
        let role = |user: &str, rights: &str| {
            format!(
                "    {{\n      user: \"{user}\"\n      password: \"pw-{user}\"\n{rights}    }}\n"
            )
        };
        let ui = "      permissions = {\n        publish = [\"lancache.dns.record\", \"lancache.dns.flush\"]\n      }\n";
        let dns = format!(
            "      permissions = {{\n        publish = {writer}\n        subscribe = {reader}\n      }}\n"
        );
        let want = format!(
            "jetstream {{\n  store_dir: \"/data\"\n}}\nhttp_port: 8222\nauthorization {{\n  users = [\n{}{}{}  ]\n  include \"auth.conf\"\n}}\naccounts {{\n  SYS: {{\n    users: [\n      {{ user: \"sys\", password: \"pw-sys\" }}\n    ]\n  }}\n}}\nsystem_account: SYS\n",
            role("ui", ui),
            role("dnsw", &dns),
            role("callout", ""),
        );
        let got = render_nats_conf(
            &roles(),
            "/data",
            8222,
            "/etc/nats/nats.conf",
            "/etc/nats/auth.conf",
        );
        assert_eq!(got, Ok(want));
    }

    // What: unsafe or misplaced nats.conf input is refused.
    // Why: a bad file would stop the broker on restart.
    // From: Issue #1683 | PR #1912
    #[test]
    fn nats_conf_refuses_bad_input() {
        let conf = "/etc/nats/nats.conf";
        let render =
            |store: &str, fragment: &str| render_nats_conf(&roles(), store, 8222, conf, fragment);
        assert_eq!(
            render("/data", "/other/auth.conf"),
            Err("/other/auth.conf must sit next to /etc/nats/nats.conf".into())
        );
        assert_eq!(
            render("/data", "/etc/nats/"),
            Err("/etc/nats/ must sit next to /etc/nats/nats.conf".into())
        );
        assert_eq!(
            render("/da\\ta", "/etc/nats/auth.conf"),
            Err("NATS store dir contains backslashes".into())
        );
        let mut bad = roles();
        bad.ui.user = "bad user".into();
        let user = render_nats_conf(&bad, "/data", 8222, conf, "/etc/nats/auth.conf").unwrap_err();
        assert!(user.starts_with("Invalid NATS UI credentials"), "{user}");
    }

    // What: option lines become the stored one-line form.
    // Why: the file keeps one line; entries join by ';'.
    // From: Issue #1683 | PR #1912
    #[test]
    fn proxy_option_lines_join_or_name_the_line() {
        assert_eq!(
            parse_custom_options("66:tftp\n\n 67 : boot.0 \n"),
            Ok("66:tftp;67:boot.0".to_string())
        );
        assert_eq!(parse_custom_options(""), Ok(String::new()));
        let cases = [
            ("66", "line 1: expected CODE:VALUE"),
            ("66:ok\nabc:x", "line 2: option code must be a number"),
            (
                "3:10.0.0.1",
                "line 1: option code is managed by dedicated dnsmasq-proxy fields",
            ),
            (
                "66:a;b",
                "line 1: option data must not contain ';' (used as the entry separator)",
            ),
            ("66: ", "line 1: option data must not be empty"),
        ];
        for (raw, message) in cases {
            assert_eq!(
                parse_custom_options(raw),
                Err(message.to_string()),
                "{raw:?}"
            );
        }
        assert!(parse_custom_options("119:search.lan").is_ok());
    }
}
