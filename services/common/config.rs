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

// What: the items of a list set apart by commas or blanks.
// Why: one splitter for every env list; empty items drop.
// From: Issue #1683
pub fn list_items(raw: &str) -> impl Iterator<Item = &str> {
    raw.split([',', ' ', '\r', '\n', '\t'])
        .filter(|item| !item.is_empty())
}

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
        // What: a value that is no UTF-8 is logged, unset.
        // Why: a default must not replace a broken value.
        // From: Issue #1683 | PR #1912
        Err(std::env::VarError::NotUnicode(_)) => {
            eprintln!("[config] WARNING: {name} is not valid UTF-8; ignored");
            None
        }
        other => match std::env::var(RUNTIME_DEFAULTS_KEY) {
            Ok(list) => default_in(&list, name).or(other.ok()),
            Err(std::env::VarError::NotPresent) => other.ok(),
            // What: broken defaults are logged, not used.
            // Why: an unreadable list must be visible.
            // From: Issue #1683 | PR #1912
            Err(e) => {
                eprintln!("[config] WARNING: {RUNTIME_DEFAULTS_KEY} not read: {e}");
                other.ok()
            }
        },
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
// From: Issue #1683 | PR #1912
pub fn saved_setting(path: &std::path::Path, key: &str) -> Result<Option<String>, String> {
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        // What: a missing file holds no saved setting.
        // Why: a fresh install has saved nothing yet.
        // From: Issue #1683 | PR #1912
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    Ok(content.lines().map(str::trim).find_map(|line| {
        line.strip_prefix(key)
            .and_then(|rest| rest.strip_prefix('='))
            .map(|value| value.trim().to_string())
    }))
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

// What: the syslog-ng template of every stored log line.
// Why: the watchdog writes the lines; the ui parses them.
// From: Issue #1683
pub const SYSLOG_LINE_TEMPLATE: &str = r"${ISODATE} ${HOST} ${PROGRAM}: ${MSGONLY}\n";

// What: a stored syslog line as time, program and message.
// Why: reverse of SYSLOG_LINE_TEMPLATE; one owner for both.
// From: Issue #1683
pub const SYSLOG_LINE_PATTERN: &str = r"^(\S+)\s+\S+\s+([^:]+):\s(.*)$";

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
    let username_label = format!("{label} username");
    let password_label = format!("{label} password");
    let problem = nats_text_problem(&username_label, &login.user)
        .or_else(|| {
            let allowed = |c: char| c.is_ascii_alphanumeric() || "_.-".contains(c);
            (!login.user.chars().all(allowed)).then(|| {
                format!(
                    "{} contains invalid characters (allowed: [A-Za-z0-9_.-]), got: {}",
                    username_label, login.user
                )
            })
        })
        .or_else(|| match login.password.as_deref() {
            Some(password) => nats_text_problem(&password_label, password),
            None => Some(format!("{password_label} cannot be empty")),
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
    if !publish.is_empty() || !subscribe.is_empty() {
        block.push_str("      permissions = {\n");
        if !publish.is_empty() {
            block.push_str(&format!("        publish = {}\n", nats_list(publish)));
        }
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

// What: DNS_LOCAL_REVERSE_ZONES: serve private PTR zones.
// Why: off by default; else PTR asks reach the LAN router.
// From: Issue #1918 | PR #1858
pub fn local_reverse(get: &dyn Fn(&str) -> Option<String>) -> Result<bool, String> {
    need_flag(get, "DNS_LOCAL_REVERSE_ZONES")
}

// What: zones with snapshots and rollbacks, dotted form.
// Why: dns creates these; reverse ones only if switched on
// From: Issue #1683 | PR #1905
pub fn rollback_zones(lan_zone: &str, reverse: bool) -> Vec<String> {
    let lan = canonical_zone(lan_zone);
    let local = format!("local.{lan}");
    let ipv6 = ["c.f.ip6.arpa.", "d.f.ip6.arpa."].map(str::to_string);
    let private = reverse_zones().into_iter().chain(ipv6);
    std::iter::once(lan)
        .chain(std::iter::once(local))
        .chain(private.filter(|_| reverse))
        .collect()
}

// What: true for a zone with snapshots and rollback.
// Why: rpz and unknown zones must never be rolled back.
// From: Issue #1683 | PR #1905
pub fn is_rollback_zone(lan_zone: &str, reverse: bool, zone: &str) -> bool {
    rollback_zones(lan_zone, reverse).iter().any(|z| z == zone)
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

// What: one DHCPv4 option a dedicated subnet field owns.
// Why: Kea names it, dnsmasq and option-data use its code.
// From: Issue #1683 | PR #1912
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ManagedOption {
    pub name: &'static str,
    pub code: u16,
}

// What: the five managed options, Kea name and DHCPv4 code.
// Why: one pair per option for the ui, Kea and dnsmasq.
// From: Issue #1683 | PR #1912
pub const OPTION_ROUTERS: ManagedOption = ManagedOption {
    name: "routers",
    code: 3,
};
pub const OPTION_DNS: ManagedOption = ManagedOption {
    name: "domain-name-servers",
    code: 6,
};
pub const OPTION_DOMAIN: ManagedOption = ManagedOption {
    name: "domain-name",
    code: 15,
};
pub const OPTION_NTP: ManagedOption = ManagedOption {
    name: "ntp-servers",
    code: 42,
};
pub const OPTION_SEARCH: ManagedOption = ManagedOption {
    name: "domain-search",
    code: 119,
};

// What: every managed option, in KEA_MANAGED_CODES order.
// Why: name checks and code lists read the same set.
// From: Issue #1683 | PR #1912
pub const MANAGED_OPTIONS: [ManagedOption; 5] = [
    OPTION_ROUTERS,
    OPTION_DNS,
    OPTION_DOMAIN,
    OPTION_NTP,
    OPTION_SEARCH,
];

// What: option codes the dedicated subnet fields own.
// Why: derived from MANAGED_OPTIONS for forms and pages.
// From: Issue #1683 | PR #1912
pub const KEA_MANAGED_CODES: [u16; 5] = [
    MANAGED_OPTIONS[0].code,
    MANAGED_OPTIONS[1].code,
    MANAGED_OPTIONS[2].code,
    MANAGED_OPTIONS[3].code,
    MANAGED_OPTIONS[4].code,
];

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
