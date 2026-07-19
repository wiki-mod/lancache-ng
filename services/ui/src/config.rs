//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Runtime configuration for the Admin UI service: loads and validates
//! settings from the process environment (auth, DHCP mode, HSTS mode,
//! session TTL, and related toggles) plus the UI's persisted `/data`
//! overrides into a typed `Config`.

use std::env;
use std::fmt;
use std::fs;

const DEFAULT_UI_SESSION_TTL_SECONDS: u64 = 24 * 60 * 60;
const DEFAULT_UI_SETTINGS_FILE: &str = "/data/lancache-ui-settings.env";

// Upper bound for SYSLOG_MAX_GB, matching watchdog.sh's maybe_prune_syslog()
// magnitude guard (`[ "$max_gb" -gt 1048576 ]`). Without a matching ceiling
// here, an operator-set SYSLOG_MAX_GB above this value would display as its
// literal (unclamped) size in the Admin UI while watchdog silently enforced
// only this much lower budget -- the dashboard would show a far larger
// number than what retention actually allows.
const SYSLOG_MAX_GB_CEILING: u32 = 1_048_576;

// Controls whether the Admin UI sends `Strict-Transport-Security` on a
// response. `Auto` (the default) sends it only when the current request
// itself arrived over HTTPS, so plain-HTTP deployments never get an HSTS
// header. `Always`/`Never` override that per-request check for setups that
// terminate TLS elsewhere (a reverse proxy) or intentionally never want HSTS
// enforced, regardless of what this process sees.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HstsMode {
    Auto,
    Always,
    Never,
}

// Which DHCP service, if any, this deployment runs -- mutually exclusive
// with each other since both `Kea` and `DnsmasqProxy` bind DHCP port 67/udp.
// `Disabled`: no DHCP here, the existing LAN router/DHCP server is
// untouched. `Kea`: full DHCP server (isc-kea), this deployment owns
// leases/reservations for the LAN. `DnsmasqProxy`: a proxy-DHCP relay that
// runs *alongside* an existing DHCP server and only answers PXE/network-boot
// clients -- it does not lease addresses or reliably replace DNS options for
// ordinary clients (see docs/dhcp-modes.md).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DhcpMode {
    Disabled,
    Kea,
    DnsmasqProxy,
}

impl DhcpMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Kea => "kea",
            Self::DnsmasqProxy => "dnsmasq-proxy",
        }
    }

    pub fn is_kea(self) -> bool {
        matches!(self, Self::Kea)
    }
}

impl HstsMode {
    pub fn should_send(self, is_https: bool) -> bool {
        match self {
            Self::Auto => is_https,
            Self::Always => true,
            Self::Never => false,
        }
    }
}

pub struct Config {
    pub template_dir: String,
    pub cdn_domains_file: String,
    pub standard_log: String,
    pub ssl_log: String,
    pub cache_dir: String,
    pub dns_standard_state_dir: String,
    pub dns_ssl_state_dir: String,
    pub proxy_standard_url: String,
    pub proxy_ssl_url: String,
    pub netdata_url: String,
    pub dns_standard_service: String,
    pub dns_ssl_service: String,
    pub proxy_ssl_service: String,
    pub ssl_enabled: bool,
    pub cache_max_gb: f64,
    pub standard_ip: String,
    pub ssl_ip: String,
    pub dhcp_dns_primary: String,
    pub dhcp_dns_secondary: String,
    pub dhcp_ntp_servers: String,
    pub dhcp_proxy_subnet_start: String,
    pub dhcp_upstream_dhcp_ip: String,
    pub dhcp_proxy_interface: String,
    pub dhcp_proxy_router: String,
    pub dhcp_proxy_domain: String,
    pub dhcp_proxy_boot_filename: String,
    pub dhcp_proxy_boot_server: String,
    pub dhcp_proxy_custom_options: String,
    pub dhcp_mode: DhcpMode,
    pub dhcp_api_url: String,
    pub ui_settings_file: String,
    pub dhcp_api_token: String,
    pub kea_config_snapshot_dir: String,
    pub kea_keep_known_good_configs: u32,
    pub auth_user: Option<String>,
    pub auth_password: Option<String>,
    pub allow_insecure_ui: bool,
    pub ui_session_ttl_seconds: u64,
    pub security_headers_enabled: bool,
    pub hsts_mode: HstsMode,
    pub ui_logs_max_entries: usize,
    pub pdns_auth_url: String,
    pub pdns_rec_url: String,
    // Zone/record known-good snapshot rollback listener (#628), a new
    // process-local HTTP API `services/dns/nats-subscriber` exposes
    // alongside PowerDNS's own pdns_auth_url/pdns_rec_url ports. Scoped to
    // dns-standard only for now, matching pdns_auth_url/pdns_rec_url's own
    // single-primary default -- see routes/dns_snapshots.rs's module doc
    // comment for why dns-ssl isn't wired up here yet.
    pub dns_rollback_url: String,
    pub pdns_api_key: String,
    pub nats_url: String,
    // Issue #866: nats_url above is correct for every *internal* NATS client
    // in this deployment -- this container's own connection (main.rs),
    // dns-standard/dns-ssl's co-located subscribers -- because they all sit
    // on the same Docker network as the `nats` service. It is never
    // reachable from a genuinely remote secondary DNS node, though: before
    // this fix, routes/secondaries.rs::register_secondary handed that same
    // internal-only value back to `setup.sh secondary` as `nats_url` in its
    // JSON response, which wrote it verbatim into the remote host's `.env`,
    // where it could never resolve.
    //
    // These two fields let an operator supply a real, externally-reachable
    // address instead, without touching nats_url itself (still correct for
    // every internal caller above). See `advertised_nats_url()` for the
    // precedence between them -- and why it returns None, not a fallback to
    // nats_url, when neither is configured: register_secondary only ever
    // runs for a genuine remote-secondary registration, so silently handing
    // back the internal address there would just reproduce the #866 bug
    // under a different name.
    //
    // nats_bind_ip mirrors the same NATS_BIND_IP value
    // `deploy/prod/docker-compose.nats-secondary.yml` already requires to
    // publish NATS on a trusted LAN/VPN interface for remote secondaries
    // (see docs/architecture-ng.md's "Remote secondary NATS access") --
    // reusing it here means an operator who has already set it up for that
    // override gets a correct advertised URL for free, with nothing new to
    // configure.
    pub nats_bind_ip: String,
    // Explicit escape hatch, highest precedence: covers setups nats_bind_ip
    // alone cannot express, e.g. a non-default port, a `tls://` scheme
    // through a NATS-aware reverse proxy, or a VPN hostname instead of a
    // literal IP. Empty (the default) means "no explicit override" -- never
    // a real value that could silently mask a misconfiguration.
    pub nats_advertise_url: String,
    pub nats_ui_user: String,
    // Option, not String-with-empty-default: an empty-string sentinel for
    // "unset" reads to CodeQL's rust/hard-coded-cryptographic-value query as
    // a hard-coded credential flowing into validate_nats_credentials (it
    // cannot see that the runtime check rejects it) -- None sidesteps that
    // false positive and is the more honest representation anyway.
    pub nats_ui_password: Option<String>,
    pub nats_dns_writer_user: String,
    pub nats_dns_writer_password: Option<String>,
    // Static role for the primary's own co-located dns-ssl container (issue
    // #583 renamed this from nats_dns_reader_*: unlike external secondaries,
    // there is always exactly one dns-ssl instance on the primary host, so a
    // fixed static credential never hits the #52 scaling problem -- only the
    // *external, dynamically-registered* secondaries needed to move off a
    // shared credential). Subscribe-only, same permission scope the old
    // reader role had.
    pub nats_dns_replica_user: String,
    pub nats_dns_replica_password: Option<String>,
    // Static bypass identity the auth-callout responder (issue #583) itself
    // connects as, to subscribe to $SYS.REQ.USER.AUTH. Distinct from
    // nats_ui_user: that one publishes DNS records, this one only answers
    // authorization requests for secondaries and needs no other permissions.
    pub nats_callout_user: String,
    pub nats_callout_password: Option<String>,
    // Where the auth-callout issuer NKey seed is persisted (generated on
    // first run, mirrors ui_session_secret's file-based persistence). This
    // keypair signs every per-secondary user JWT the callout responder
    // issues; see nats_auth_callout.rs's module docs for the full mechanism.
    // Ignored if nats_issuer_seed is set.
    pub nats_issuer_seed_path: String,
    // Optional literal seed value, taking precedence over
    // nats_issuer_seed_path when set. Exists for ephemeral/deterministic
    // deployments (e.g. deploy/full-setup's validation harness) that need a
    // fixed, pre-known issuer keypair baked into nats.conf ahead of time and
    // have no persistent /data volume to read a generated one back from --
    // not intended for dev/prod, which use the file-based path instead.
    pub nats_issuer_seed: Option<String>,
    pub secondary_registration_token: String,
    pub lancache_image_registry: String,
    pub lancache_image_prefix: String,
    pub lancache_image_channel: String,
    // Whether the host's scheduled-update timer (lancache-auto-update.timer,
    // installed by setup.sh) is meant to be running. This mirrors .env's
    // AUTO_UPDATE_ENABLED at container start; the Admin UI's own toggle
    // (routes/setup.rs) never edits this field directly, only the
    // ui_settings_file override effective_auto_update_enabled() reads on top
    // of it -- see that function's comment for why a host systemd timer can't
    // be flipped synchronously from inside this container (#819).
    pub auto_update_enabled: bool,
    pub lancache_image_tag: String,
    pub nats_conf_path: String,
    // Path to the auth_callout fragment the Admin UI is the SOLE writer of
    // (issue #811). It is `include`d by the nats container's own nats.conf and
    // holds only the `auth_callout {}` stanza (issuer + auth_users). Splitting
    // it out of nats.conf is what lets the nats entrypoint keep idempotently
    // regenerating its static config on every restart without clobbering the
    // callout -- see routes/secondaries.rs::update_nats_conf and the nats
    // service's entrypoint comment in deploy/*/docker-compose.yml. Defaults to
    // the include target that entrypoint resolves relative to /etc/nats.
    pub nats_auth_callout_path: String,
    pub nats_service: String,
    // Central logging pipeline (#633): written into nats.conf's top-level
    // `log_file:` directive by the nats service's own entrypoint (since #811
    // the Admin UI no longer writes nats.conf, only the auth_callout fragment;
    // this field is retained for the connection/preflight code paths that
    // still surface the configured log path) so
    // fluent-bit can tail it. nats-server logs to exactly one destination at
    // a time -- setting `log_file` means `docker logs` on this container
    // stops showing nats-server's own output while the `logging` compose
    // profile is active (same accepted, documented trade-off as dhcp-proxy's
    // dnsmasq `log-facility=`; there is no dual-output config for either).
    pub nats_log_file: String,
    pub dev_mode: bool,
    // Central syslog-ng reader (#633 PR4, depends on PR3's watchdog.sh
    // retention-engine contract for the exact env var names/semantics these
    // mirror). Fail-closed default: syslog_enabled=false means
    // routes/logs.rs and routes/dashboard.rs never touch syslog_log_root at
    // all, so installs that never opt into `docker compose --profile
    // logging` see byte-identical behavior to before this PR.
    pub syslog_enabled: bool,
    pub syslog_log_root: String,
    pub syslog_max_gb: u32,
    pub syslog_retention_days: u32,
}

// Redacts every secret-bearing field (tokens, passwords, API keys) so a stray
// `{:?}` in a log line or panic message can never leak a credential.
impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("template_dir", &self.template_dir)
            .field("cdn_domains_file", &self.cdn_domains_file)
            .field("standard_log", &self.standard_log)
            .field("ssl_log", &self.ssl_log)
            .field("cache_dir", &self.cache_dir)
            .field("dns_standard_state_dir", &self.dns_standard_state_dir)
            .field("dns_ssl_state_dir", &self.dns_ssl_state_dir)
            .field("proxy_standard_url", &self.proxy_standard_url)
            .field("proxy_ssl_url", &self.proxy_ssl_url)
            .field("netdata_url", &self.netdata_url)
            .field("dns_standard_service", &self.dns_standard_service)
            .field("dns_ssl_service", &self.dns_ssl_service)
            .field("proxy_ssl_service", &self.proxy_ssl_service)
            .field("ssl_enabled", &self.ssl_enabled)
            .field("cache_max_gb", &self.cache_max_gb)
            .field("standard_ip", &self.standard_ip)
            .field("ssl_ip", &self.ssl_ip)
            .field("dhcp_dns_primary", &self.dhcp_dns_primary)
            .field("dhcp_dns_secondary", &self.dhcp_dns_secondary)
            .field("dhcp_ntp_servers", &self.dhcp_ntp_servers)
            .field("dhcp_proxy_subnet_start", &self.dhcp_proxy_subnet_start)
            .field("dhcp_upstream_dhcp_ip", &self.dhcp_upstream_dhcp_ip)
            .field("dhcp_proxy_interface", &self.dhcp_proxy_interface)
            .field("dhcp_proxy_router", &self.dhcp_proxy_router)
            .field("dhcp_proxy_domain", &self.dhcp_proxy_domain)
            .field("dhcp_proxy_boot_filename", &self.dhcp_proxy_boot_filename)
            .field("dhcp_proxy_boot_server", &self.dhcp_proxy_boot_server)
            .field("dhcp_proxy_custom_options", &self.dhcp_proxy_custom_options)
            .field("dhcp_mode", &self.dhcp_mode.as_str())
            .field("dhcp_api_url", &self.dhcp_api_url)
            .field("ui_settings_file", &self.ui_settings_file)
            .field("dhcp_api_token", &"***REDACTED***")
            .field("kea_config_snapshot_dir", &self.kea_config_snapshot_dir)
            .field(
                "kea_keep_known_good_configs",
                &self.kea_keep_known_good_configs,
            )
            .field(
                "auth_user",
                &self.auth_user.as_ref().map(|_| "***REDACTED***"),
            )
            .field(
                "auth_password",
                &self.auth_password.as_ref().map(|_| "***REDACTED***"),
            )
            .field("allow_insecure_ui", &self.allow_insecure_ui)
            .field("ui_session_ttl_seconds", &self.ui_session_ttl_seconds)
            .field("ui_logs_max_entries", &self.ui_logs_max_entries)
            .field("pdns_auth_url", &self.pdns_auth_url)
            .field("pdns_rec_url", &self.pdns_rec_url)
            .field("dns_rollback_url", &self.dns_rollback_url)
            .field("pdns_api_key", &"***REDACTED***")
            .field("nats_url", &self.nats_url)
            .field("nats_bind_ip", &self.nats_bind_ip)
            .field("nats_advertise_url", &self.nats_advertise_url)
            .field("nats_ui_user", &self.nats_ui_user)
            .field(
                "nats_ui_password",
                &self.nats_ui_password.as_ref().map(|_| "***REDACTED***"),
            )
            .field("nats_dns_writer_user", &self.nats_dns_writer_user)
            .field(
                "nats_dns_writer_password",
                &self
                    .nats_dns_writer_password
                    .as_ref()
                    .map(|_| "***REDACTED***"),
            )
            .field("nats_dns_replica_user", &self.nats_dns_replica_user)
            .field(
                "nats_dns_replica_password",
                &self
                    .nats_dns_replica_password
                    .as_ref()
                    .map(|_| "***REDACTED***"),
            )
            .field("nats_callout_user", &self.nats_callout_user)
            .field(
                "nats_callout_password",
                &self
                    .nats_callout_password
                    .as_ref()
                    .map(|_| "***REDACTED***"),
            )
            .field("nats_issuer_seed_path", &self.nats_issuer_seed_path)
            .field(
                "nats_issuer_seed",
                &self.nats_issuer_seed.as_ref().map(|_| "***REDACTED***"),
            )
            .field("secondary_registration_token", &"***REDACTED***")
            .field("lancache_image_registry", &self.lancache_image_registry)
            .field("lancache_image_prefix", &self.lancache_image_prefix)
            .field("lancache_image_channel", &self.lancache_image_channel)
            .field("auto_update_enabled", &self.auto_update_enabled)
            .field("lancache_image_tag", &self.lancache_image_tag)
            .field("nats_conf_path", &self.nats_conf_path)
            .field("nats_auth_callout_path", &self.nats_auth_callout_path)
            .field("nats_service", &self.nats_service)
            .field("nats_log_file", &self.nats_log_file)
            .field("dev_mode", &self.dev_mode)
            .field("syslog_enabled", &self.syslog_enabled)
            .field("syslog_log_root", &self.syslog_log_root)
            .field("syslog_max_gb", &self.syslog_max_gb)
            .field("syslog_retention_days", &self.syslog_retention_days)
            .finish()
    }
}

impl fmt::Display for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Config {{ template_dir: {:?}, cdn_domains_file: {:?}, ... }}",
            self.template_dir, self.cdn_domains_file
        )
    }
}

// The `effective_*` methods below implement a two-layer config model: the
// `Config` struct itself holds the container's *startup* values (from env
// vars, fixed for the process lifetime), while the Admin UI lets an operator
// change DHCP settings at runtime without a container restart by writing
// `KEY=value` lines to `ui_settings_file` (see `read_ui_override`). Every
// `effective_*` getter checks that persisted override file first and only
// falls back to the startup env value if no override line exists.
impl Config {
    // Issue #866: the one NATS URL that must be reachable from OUTSIDE this
    // container's own Docker network -- handed to a genuinely remote
    // secondary DNS node by routes/secondaries.rs::register_secondary, never
    // used for any connection this process makes itself (main.rs keeps
    // using self.nats_url directly for that, unconditionally correct since
    // this container always sits on the same Docker network as `nats`).
    //
    // Returns None, deliberately, when neither override is configured --
    // NOT a fallback to nats_url. register_secondary is reached exactly
    // once per real invocation of `setup.sh secondary`, i.e. only when an
    // operator is actively registering a genuinely remote secondary; there
    // is no "install that never uses remote secondaries" path through this
    // function, so silently handing back nats_url's Docker-internal value
    // here would reproduce the exact bug #866 reports (an operator runs
    // `setup.sh secondary`, it writes an unreachable NATS_URL into the new
    // secondary's .env, starts the container, and prints "is running" with
    // no signal anything is wrong -- see setup.sh's cmd_secondary). Callers
    // that hit None must refuse the registration instead of degrading to
    // that silent-failure value.
    //
    // Precedence when Some, highest first:
    // 1. `nats_advertise_url` -- an explicit operator override. Covers
    //    anything nats_bind_ip alone can't express (non-default port, a
    //    `tls://` scheme, a VPN hostname). Never validated as an IP literal
    //    here -- it may legitimately be a hostname, and the operator who set
    //    it explicitly is asserting it is already correct.
    // 2. `nats_bind_ip` -- the same trusted LAN/VPN IP
    //    `docker-compose.nats-secondary.yml` already requires to publish
    //    NATS's host port for remote secondaries. If an operator has that
    //    override active at all, port 4222 on that IP is -- by construction
    //    -- already reachable from wherever a remote secondary can reach
    //    this primary, so deriving `nats://<ip>:4222` from it needs no
    //    separate configuration step.
    //
    //    Two corrections applied when nats_bind_ip parses as an IP literal:
    //
    //    - IPv6 literals must be bracketed (`nats://[::1]:4222`, not
    //      `nats://::1:4222` -- the latter is ambiguous/unparsable as a
    //      host:port pair since the literal's own colons collide with the
    //      port separator).
    //    - A wildcard listen address (`0.0.0.0`, `::`) must NOT be echoed
    //      back as the advertised address: it is only meaningful as a bind
    //      address (docs/architecture-ng.md documents binding to `0.0.0.0`
    //      behind an external firewall/VPN as a supported case), never as
    //      something a remote secondary could dial. Handing it out would
    //      make registration look successful while the secondary still has
    //      no reachable address -- reproducing #866 under a different
    //      config. An operator in that situation needs the explicit,
    //      routable `NATS_ADVERTISE_URL` instead, so this falls through to
    //      the same fail-closed `None` that register_secondary already
    //      turns into an HTTP 503 refusal.
    //
    //    A value that does not parse as an IP literal at all (e.g. a
    //    hostname) is passed through unchanged, same as before.
    pub fn advertised_nats_url(&self) -> Option<String> {
        let explicit = self.nats_advertise_url.trim();
        if !explicit.is_empty() {
            return Some(explicit.to_string());
        }
        let bind_ip = self.nats_bind_ip.trim();
        if bind_ip.is_empty() {
            return None;
        }
        // Docker Compose documents both the bare (`::`) and the
        // square-bracketed (`[::]`) form for an IPv6 host-port bind address.
        // Strip a single matching bracket pair before parsing so `[::]`
        // parses to the same unspecified address as `::`, rather than
        // failing IpAddr::parse (which never accepts brackets) and silently
        // falling through to the hostname branch as an unrejected opaque
        // string.
        let unbracketed = bind_ip
            .strip_prefix('[')
            .and_then(|inner| inner.strip_suffix(']'))
            .unwrap_or(bind_ip);
        match unbracketed.parse::<std::net::IpAddr>() {
            // 0.0.0.0 / :: (bracketed or not) are listen wildcards, not a
            // routable address a remote secondary could dial.
            Ok(std::net::IpAddr::V4(v4)) if v4.is_unspecified() => None,
            Ok(std::net::IpAddr::V6(v6)) if v6.is_unspecified() => None,
            // A remote secondary is, by definition, not the primary host
            // itself -- it can never dial 127.0.0.1/::1 there, even though
            // the literal parses fine and "looks like" a real bind address.
            // Reject it the same way as a wildcard rather than handing out
            // an address that is guaranteed unreachable from anywhere else.
            Ok(std::net::IpAddr::V4(v4)) if v4.is_loopback() => None,
            Ok(std::net::IpAddr::V6(v6)) if v6.is_loopback() => None,
            Ok(std::net::IpAddr::V6(v6)) => Some(format!("nats://[{v6}]:4222")),
            Ok(std::net::IpAddr::V4(v4)) => Some(format!("nats://{v4}:4222")),
            // NATS_BIND_IP feeds Compose's port `HOST` field, which is an
            // IP/port bind, not a resolvable hostname -- a value that is not
            // a parsable IP literal (a hostname, a reverse-proxy name, ...)
            // cannot be assumed reachable at the same address `nats`
            // actually publishes on. Require the operator to set
            // NATS_ADVERTISE_URL explicitly for that case instead of
            // guessing a URL that looks valid but may not be reachable.
            Err(_) => None,
        }
    }

    // The `effective_*` getters let a value the operator changed live in the
    // Admin UI (persisted to `ui_settings_file`, see `read_ui_override`) win over
    // the value `from_env()` captured at process start, without requiring a
    // container restart to pick up new env vars.
    pub fn effective_dhcp_mode(&self) -> DhcpMode {
        read_dhcp_mode_override(&self.ui_settings_file).unwrap_or(self.dhcp_mode)
    }

    pub fn effective_dhcp_dns_primary(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_DNS_PRIMARY")
            .unwrap_or_else(|| self.dhcp_dns_primary.clone())
    }

    pub fn effective_dhcp_dns_secondary(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_DNS_SECONDARY")
            .unwrap_or_else(|| self.dhcp_dns_secondary.clone())
    }

    pub fn effective_dhcp_ntp_servers(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_NTP_SERVERS")
            .unwrap_or_else(|| self.dhcp_ntp_servers.clone())
    }

    pub fn effective_dhcp_proxy_subnet_start(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_SUBNET_START")
            .unwrap_or_else(|| self.dhcp_proxy_subnet_start.clone())
    }

    pub fn effective_dhcp_upstream_dhcp_ip(&self) -> String {
        read_ui_override(&self.ui_settings_file, "UPSTREAM_DHCP_IP")
            .unwrap_or_else(|| self.dhcp_upstream_dhcp_ip.clone())
    }

    // Issue #450: additional optional dnsmasq relay/proxy fields. All of
    // these ride the supplemental ProxyDHCP/PXE exchange, same as
    // DHCP_DNS_PRIMARY/SECONDARY above -- see docs/dhcp-modes.md and
    // services/dhcp-proxy/entrypoint.sh's
    // `_dhcp_proxy_render_optional_directives` for what that actually means
    // for delivery to ordinary (non-PXE) clients.
    pub fn effective_dhcp_proxy_interface(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_INTERFACE")
            .unwrap_or_else(|| self.dhcp_proxy_interface.clone())
    }

    pub fn effective_dhcp_proxy_router(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_ROUTER")
            .unwrap_or_else(|| self.dhcp_proxy_router.clone())
    }

    pub fn effective_dhcp_proxy_domain(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_DOMAIN")
            .unwrap_or_else(|| self.dhcp_proxy_domain.clone())
    }

    pub fn effective_dhcp_proxy_boot_filename(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_BOOT_FILENAME")
            .unwrap_or_else(|| self.dhcp_proxy_boot_filename.clone())
    }

    pub fn effective_dhcp_proxy_boot_server(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_BOOT_SERVER")
            .unwrap_or_else(|| self.dhcp_proxy_boot_server.clone())
    }

    pub fn effective_dhcp_proxy_custom_options(&self) -> String {
        read_ui_override(&self.ui_settings_file, "DHCP_PROXY_CUSTOM_OPTIONS")
            .unwrap_or_else(|| self.dhcp_proxy_custom_options.clone())
    }

    // Release channel / scheduled-update settings (#819). Unlike DHCP mode,
    // neither of these two values takes effect inside this container at all
    // -- both are consumed entirely on the host by setup.sh's
    // lancache-converge.service, which polls the same ui_settings_file this
    // container writes to (routes/setup.rs's update_stack_settings) via a
    // throwaway `docker run --rm -v ui-data:/volume:ro alpine cat ...`
    // (chosen over a bind-mount migration -- see the #819 issue thread for
    // why). Effects therefore land on the NEXT convergence tick (currently
    // every 5 minutes), never synchronously with the save -- the Admin UI's
    // own copy for this control must say so plainly rather than implying an
    // instant effect it cannot deliver.
    pub fn effective_lancache_image_channel_override(&self) -> String {
        read_ui_override(&self.ui_settings_file, "LANCACHE_IMAGE_CHANNEL")
            .unwrap_or_else(|| self.lancache_image_channel.clone())
    }

    pub fn effective_auto_update_enabled(&self) -> bool {
        read_ui_override(&self.ui_settings_file, "AUTO_UPDATE_ENABLED")
            .map(|value| value.trim() == "1")
            .unwrap_or(self.auto_update_enabled)
    }

    // Renders the current effective DHCP settings back into the same
    // `KEY=value` line format `read_ui_override` parses, so this is what
    // gets written to `ui_settings_file` whenever the operator saves DHCP
    // changes from the Admin UI. Empty values are omitted rather than
    // written as `KEY=`, so a cleared override falls back to the env default
    // on the next read instead of pinning an empty string.
    pub fn ui_override_lines(&self) -> Vec<String> {
        let mut lines = vec![format!("DHCP_MODE={}", self.effective_dhcp_mode().as_str())];
        let proxy_subnet_start = self.effective_dhcp_proxy_subnet_start();
        if !proxy_subnet_start.trim().is_empty() {
            lines.push(format!("DHCP_SUBNET_START={}", proxy_subnet_start.trim()));
        }
        let dhcp_dns_primary = self.effective_dhcp_dns_primary();
        if !dhcp_dns_primary.trim().is_empty() {
            lines.push(format!("DHCP_DNS_PRIMARY={}", dhcp_dns_primary.trim()));
        }
        let dhcp_dns_secondary = self.effective_dhcp_dns_secondary();
        if !dhcp_dns_secondary.trim().is_empty() {
            lines.push(format!("DHCP_DNS_SECONDARY={}", dhcp_dns_secondary.trim()));
        }
        let upstream_dhcp_ip = self.effective_dhcp_upstream_dhcp_ip();
        if !upstream_dhcp_ip.trim().is_empty() {
            lines.push(format!("UPSTREAM_DHCP_IP={}", upstream_dhcp_ip.trim()));
        }
        let dhcp_ntp_servers = self.effective_dhcp_ntp_servers();
        if !dhcp_ntp_servers.trim().is_empty() {
            lines.push(format!("DHCP_NTP_SERVERS={}", dhcp_ntp_servers.trim()));
        }
        let dhcp_proxy_interface = self.effective_dhcp_proxy_interface();
        if !dhcp_proxy_interface.trim().is_empty() {
            lines.push(format!(
                "DHCP_PROXY_INTERFACE={}",
                dhcp_proxy_interface.trim()
            ));
        }
        let dhcp_proxy_router = self.effective_dhcp_proxy_router();
        if !dhcp_proxy_router.trim().is_empty() {
            lines.push(format!("DHCP_PROXY_ROUTER={}", dhcp_proxy_router.trim()));
        }
        let dhcp_proxy_domain = self.effective_dhcp_proxy_domain();
        if !dhcp_proxy_domain.trim().is_empty() {
            lines.push(format!("DHCP_PROXY_DOMAIN={}", dhcp_proxy_domain.trim()));
        }
        let dhcp_proxy_boot_filename = self.effective_dhcp_proxy_boot_filename();
        if !dhcp_proxy_boot_filename.trim().is_empty() {
            lines.push(format!(
                "DHCP_PROXY_BOOT_FILENAME={}",
                dhcp_proxy_boot_filename.trim()
            ));
        }
        let dhcp_proxy_boot_server = self.effective_dhcp_proxy_boot_server();
        if !dhcp_proxy_boot_server.trim().is_empty() {
            lines.push(format!(
                "DHCP_PROXY_BOOT_SERVER={}",
                dhcp_proxy_boot_server.trim()
            ));
        }
        let dhcp_proxy_custom_options = self.effective_dhcp_proxy_custom_options();
        if !dhcp_proxy_custom_options.trim().is_empty() {
            lines.push(format!(
                "DHCP_PROXY_CUSTOM_OPTIONS={}",
                dhcp_proxy_custom_options.trim()
            ));
        }
        lines
    }

    pub fn from_env() -> Result<Self, String> {
        let proxy_service = env_or("PROXY_SERVICE", "proxy".to_string());
        let standard_log = env_or("STANDARD_LOG", "/var/log/nginx/access.log".to_string());
        let ssl_log = env_or("SSL_LOG", standard_log.clone());
        let cache_dir = resolve_cache_dir();
        let proxy_standard_url = env_or("PROXY_STANDARD_URL", format!("http://{proxy_service}"));
        let proxy_ssl_url = env_or("PROXY_SSL_URL", proxy_standard_url.clone());
        let proxy_ssl_service = env_or("PROXY_SSL_SERVICE", proxy_service.clone());
        let ssl_enabled = env_bool("SSL_ENABLED", true);
        let cache_max_gb = resolve_cache_max_gb();
        let standard_ip = env_str("STANDARD_IP", "192.168.234.10");
        let ssl_ip = env_str("SSL_IP", "192.168.234.11");
        let dhcp_mode = env_dhcp_mode("DHCP_MODE", env_bool("DHCP_ENABLED", false));
        let dhcp_api_url = env_str("DHCP_API_URL", "http://localhost:8000");
        let dhcp_dns_primary = env::var("DHCP_DNS_PRIMARY").unwrap_or_else(|_| standard_ip.clone());
        let dhcp_dns_secondary = env::var("DHCP_DNS_SECONDARY").unwrap_or_else(|_| ssl_ip.clone());
        let dhcp_ntp_servers = env_str("DHCP_NTP_SERVERS", "");
        let dhcp_proxy_subnet_start = env_str("DHCP_SUBNET_START", "");
        let dhcp_upstream_dhcp_ip = env_str("UPSTREAM_DHCP_IP", "");
        let dhcp_proxy_interface = env_str("DHCP_PROXY_INTERFACE", "");
        let dhcp_proxy_router = env_str("DHCP_PROXY_ROUTER", "");
        let dhcp_proxy_domain = env_str("DHCP_PROXY_DOMAIN", "");
        let dhcp_proxy_boot_filename = env_str("DHCP_PROXY_BOOT_FILENAME", "");
        let dhcp_proxy_boot_server = env_str("DHCP_PROXY_BOOT_SERVER", "");
        let dhcp_proxy_custom_options = env_str("DHCP_PROXY_CUSTOM_OPTIONS", "");

        let lancache_image_tag = env_str("LANCACHE_IMAGE_TAG", "latest");
        let lancache_image_channel = env::var("LANCACHE_IMAGE_CHANNEL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| derive_lancache_image_channel(&lancache_image_tag));
        let auto_update_enabled = env_bool("AUTO_UPDATE_ENABLED", false);

        Ok(Self {
            template_dir: env_str("TEMPLATE_DIR", "/templates"),
            cdn_domains_file: env_str("CDN_DOMAINS_FILE", "/data/cdn-domains.txt"),
            standard_log,
            ssl_log,
            cache_dir,
            dns_standard_state_dir: env_str("DNS_STANDARD_STATE_DIR", "/var/lib/powerdns-state"),
            dns_ssl_state_dir: env_str("DNS_SSL_STATE_DIR", "/var/lib/powerdns-state"),
            proxy_standard_url,
            proxy_ssl_url,
            netdata_url: env_str("NETDATA_URL", "http://netdata:19999"),
            dns_standard_service: env_str("DNS_STANDARD_SERVICE", "dns-standard"),
            dns_ssl_service: env_str("DNS_SSL_SERVICE", "dns-ssl"),
            proxy_ssl_service,
            ssl_enabled,
            cache_max_gb,
            standard_ip,
            ssl_ip,
            dhcp_dns_primary,
            dhcp_dns_secondary,
            dhcp_ntp_servers,
            dhcp_proxy_subnet_start,
            dhcp_upstream_dhcp_ip,
            dhcp_proxy_interface,
            dhcp_proxy_router,
            dhcp_proxy_domain,
            dhcp_proxy_boot_filename,
            dhcp_proxy_boot_server,
            dhcp_proxy_custom_options,
            dhcp_mode,
            dhcp_api_url,
            ui_settings_file: env_str("UI_SETTINGS_FILE", DEFAULT_UI_SETTINGS_FILE),
            dhcp_api_token: env_str("DHCP_API_TOKEN", ""),
            kea_config_snapshot_dir: env_str(
                "KEA_CONFIG_SNAPSHOT_DIR",
                "/var/lib/kea/config-snapshots",
            ),
            kea_keep_known_good_configs: env_u32_clamped("KEEP_KNOWN_GOOD_CONFIGS", 3),
            auth_user: env_opt("UI_AUTH_USER"),
            auth_password: env_opt("UI_AUTH_PASSWORD"),
            allow_insecure_ui: env_bool("ALLOW_INSECURE_UI", false),
            ui_session_ttl_seconds: env_u64(
                "UI_SESSION_TTL_SECONDS",
                DEFAULT_UI_SESSION_TTL_SECONDS,
            )?,
            security_headers_enabled: env_bool("UI_SECURITY_HEADERS", true),
            hsts_mode: env_hsts_mode("UI_HSTS_MODE", HstsMode::Auto),
            ui_logs_max_entries: env_usize_clamped("UI_LOGS_MAX_ENTRIES", 200),
            pdns_auth_url: env_str("PDNS_AUTH_URL", "http://dns-standard:8081"),
            pdns_rec_url: env_str("PDNS_REC_URL", "http://dns-standard:8082"),
            dns_rollback_url: env_str("DNS_ROLLBACK_URL", "http://dns-standard:8083"),
            pdns_api_key: env_str("PDNS_API_KEY", ""),
            nats_url: env_str("NATS_URL", "nats://nats:4222"),
            // Issue #866: no defaults for either -- an unset value must mean
            // "not configured", not a placeholder that could quietly stand
            // in for a real address. See advertised_nats_url() for how
            // these combine with nats_url above.
            nats_bind_ip: env_str("NATS_BIND_IP", ""),
            nats_advertise_url: env_str("NATS_ADVERTISE_URL", ""),
            nats_ui_user: env_str("NATS_UI_USER", ""),
            // env_opt, not env_str with a "" default: the real value always
            // comes from setup.sh's `get_or_generate_secret ... hex32` (a
            // genuine per-deployment random secret, persisted to .env on
            // first run) or generate_nats_password()'s CSPRNG for
            // per-secondary credentials. There is no placeholder/vendor
            // value here on purpose -- an unset var must fail startup via
            // validate_runtime_nats_credentials, never silently run with an
            // empty password.
            nats_ui_password: env_opt("NATS_UI_PASSWORD"),
            nats_dns_writer_user: env_str("NATS_DNS_WRITER_USER", ""),
            nats_dns_writer_password: env_opt("NATS_DNS_WRITER_PASSWORD"),
            nats_dns_replica_user: env_str("NATS_DNS_REPLICA_USER", ""),
            nats_dns_replica_password: env_opt("NATS_DNS_REPLICA_PASSWORD"),
            nats_callout_user: env_str("NATS_CALLOUT_USER", ""),
            nats_callout_password: env_opt("NATS_CALLOUT_PASSWORD"),
            nats_issuer_seed_path: env_str(
                "NATS_ISSUER_SEED_PATH",
                "/data/lancache-nats-issuer.seed",
            ),
            nats_issuer_seed: env_opt("NATS_ISSUER_SEED"),
            secondary_registration_token: env_str("SECONDARY_REGISTRATION_TOKEN", ""),
            // Kept as separate fields so the UI can display the running
            // release/channel without reconstructing image references from
            // hardcoded GHCR assumptions.
            lancache_image_registry: env_str("LANCACHE_IMAGE_REGISTRY", "ghcr.io"),
            lancache_image_prefix: env_str("LANCACHE_IMAGE_PREFIX", "wiki-mod/lancache-ng"),
            lancache_image_channel,
            auto_update_enabled,
            lancache_image_tag,
            nats_conf_path: env_str("NATS_CONF_PATH", "/etc/nats/nats.conf"),
            // Must match the `include "auth_callout.conf"` target the nats
            // entrypoint writes into nats.conf (resolved relative to /etc/nats).
            nats_auth_callout_path: env_str(
                "NATS_AUTH_CALLOUT_PATH",
                "/etc/nats/auth_callout.conf",
            ),
            nats_service: env_str("NATS_SERVICE", "nats"),
            nats_log_file: env_str("NATS_LOG_FILE", "/var/log/lancache-nats/nats.log"),
            dev_mode: env_bool("LANCACHE_DEV_MODE", false),
            // Mirrors watchdog.sh's maybe_prune_syslog() contract (PR3/#757)
            // exactly: same 4 env var names, same defaults (10 GB / 30
            // days). env_u32_clamped's `n >= 1` floor used to be a documented
            // divergence from watchdog.sh's bash clamp, which let a literal
            // "0" through unchanged (it is all-digits) -- that was worse than
            // a harmless display-only mismatch: a real SYSLOG_MAX_GB=0 made
            // watchdog's size pass treat every file as over budget and delete
            // everything it could. watchdog.sh now applies the same `n >= 1`
            // floor (falling back to the default of 10 GB, exactly like this
            // field does), and env_u32_clamped_with_max's ceiling below
            // matches watchdog.sh's own upper magnitude guard, so the two
            // are aligned in both directions. SYSLOG_ENABLED parsing is
            // likewise shared in spirit with watchdog.sh's is_truthy()
            // helper -- see env_bool()'s doc comment below.
            syslog_enabled: env_bool("SYSLOG_ENABLED", false),
            syslog_log_root: env_str("SYSLOG_LOG_ROOT", "/var/log/lancache-syslog-ng"),
            syslog_max_gb: env_u32_clamped_with_max("SYSLOG_MAX_GB", 10, SYSLOG_MAX_GB_CEILING),
            syslog_retention_days: env_u32_clamped("SYSLOG_RETENTION_DAYS", 30),
        })
    }
}

// Guesses which release channel (see docs/release-versioning.md) the
// currently-running image tag belongs to, for display in the Admin UI only
// (LANCACHE_IMAGE_CHANNEL should normally be set explicitly by the deploy
// tooling; this is a best-effort fallback when it isn't). `dev`/`nightly`/
// `latest` tags map straight to their channel name. The old `edge` channel was
// renamed to `nightly` in v0.3.0 (#1056) and hard-cut, not aliased -- `edge` is
// deliberately NOT recognized here, so an image somehow still tagged `edge`
// falls through to the generic "latest" default rather than being silently
// treated as a synonym for `nightly`. A `v`- or `sha-`-prefixed tag means a
// specific release or commit was pinned deliberately, which this function can't
// distinguish from any other channel, so it reports "pinned" rather than
// guessing wrong. Anything else defaults to "latest".
fn derive_lancache_image_channel(tag: &str) -> String {
    if tag == "dev" || tag == "nightly" || tag == "latest" {
        tag.to_string()
    } else if tag.starts_with("sha-") || tag.starts_with('v') {
        "pinned".to_string()
    } else {
        "latest".to_string()
    }
}

fn env_str(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

// Unlike `env_str`, treats an explicitly-set-but-empty env var the same as an
// unset one. Used for values that legitimately fall back to another field
// (e.g. PROXY_SSL_URL defaulting to PROXY_STANDARD_URL) when left blank in
// deployment .env files rather than omitted outright.
fn env_or(key: &str, default: String) -> String {
    env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or(default)
}

// Same empty-string-means-unset treatment as `env_or`, for optional values with
// no sensible string default (e.g. UI_AUTH_USER, where "unset" must stay
// distinguishable from "set to an empty string").
fn env_opt(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
}

// CACHE_DIR is the only runtime cache path as of v0.2.0. The pre-v0.2.0 split
// keys (CACHE_DIR_STANDARD/CACHE_DIR_SSL, migrated by setup.sh) are a hard
// cut: setup.sh's migration folds them into CACHE_DIR before the UI ever
// starts, so this function does not accept them as a fallback. An earlier
// revision of this function *did* read a split-key fallback here, but under
// the wrong names (STANDARD_CACHE_DIR/SSL_CACHE_DIR, reversed from the real
// CACHE_DIR_STANDARD/CACHE_DIR_SSL used by setup.sh and every other service),
// so it silently never matched real migrated installs anyway.
fn resolve_cache_dir() -> String {
    env_opt("CACHE_DIR").unwrap_or_else(|| "/var/cache/proxy".to_string())
}

// Keep CACHE_MAX_GB canonical while tolerating matching legacy values on old
// installs. Diverging legacy size keys only matter when CACHE_MAX_GB is absent.
fn resolve_cache_max_gb() -> f64 {
    if let Some(cache_max_gb) = env::var("CACHE_MAX_GB")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
    {
        return cache_max_gb;
    }

    match (
        env::var("STANDARD_CACHE_MAX_GB").ok(),
        env::var("SSL_CACHE_MAX_GB").ok(),
    ) {
        (Some(standard), Some(ssl)) => {
            let standard: f64 = standard.parse().unwrap_or(50.0);
            let ssl: f64 = ssl.parse().unwrap_or(standard);
            if (standard - ssl).abs() > f64::EPSILON {
                panic!(
                    "STANDARD_CACHE_MAX_GB and SSL_CACHE_MAX_GB differ without CACHE_MAX_GB; set CACHE_MAX_GB to one shared cache size."
                );
            }
            standard
        }
        (Some(standard), None) => standard.parse().unwrap_or(50.0),
        (None, Some(ssl)) => ssl.parse().unwrap_or(50.0),
        (None, None) => 50.0,
    }
}

fn env_u64(key: &str, default: u64) -> Result<u64, String> {
    match env::var(key) {
        Ok(value) => value.trim().parse::<u64>().map_err(|_| {
            format!("{key} must be an unsigned integer number of seconds, got {value:?}")
        }),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(env::VarError::NotUnicode(_)) => {
            Err(format!("{key} must be a valid UTF-8 integer value"))
        }
    }
}

// Mirrors scripts/lib/known-good-snapshots.sh's `kgs_snapshot_prune` clamping
// of KEEP_KNOWN_GOOD_CONFIGS: a missing, non-numeric, or non-positive value
// (e.g. "0", empty, "abc") silently falls back to `default` rather than
// failing startup (like `env_u64` would) or disabling retention outright.
// This is deliberately lenient because the shell adapters treat a
// misconfigured retention count the same way; the Kea Rust adapter follows
// the same documented contract (docs/known-good-config-snapshots.md).
fn env_u32_clamped(key: &str, default: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|&n| n >= 1)
        .unwrap_or(default)
}

// Same floor semantics as `env_u32_clamped` (a missing/non-numeric/zero
// value falls back to `default`), plus an explicit ceiling. Used only for
// SYSLOG_MAX_GB, which watchdog.sh's maybe_prune_syslog() also caps at
// SYSLOG_MAX_GB_CEILING -- `env_u32_clamped` alone has no ceiling, so a
// value that fits in a u32 but exceeds watchdog's own magnitude guard (e.g.
// 2_000_000) previously passed through here unclamped while watchdog capped
// its own budget at the ceiling, making the Admin UI display a budget far
// larger than what was actually enforced. Parsing as u64 first (instead of
// u32) matters too: a value large enough to overflow u32 (>= 4_294_967_296)
// used to fail `parse::<u32>()` outright and fall back to `default` here,
// while watchdog.sh's bash arithmetic (64-bit, so nowhere near overflowing
// on any plausible operator input) clamped the same value to its ceiling --
// parsing as u64 lets both an in-range-but-over-ceiling value and a
// u32-overflowing value converge on the same ceiling result watchdog.sh
// produces, instead of silently falling back to `default` only on this side.
fn env_u32_clamped_with_max(key: &str, default: u32, max: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(|n| {
            if n < 1 {
                default
            } else if n > u64::from(max) {
                max
            } else {
                n as u32
            }
        })
        .unwrap_or(default)
}

// The Admin UI /logs view is a bounded tail. A missing, non-numeric, or zero
// value falls back to `default` rather than failing UI startup: this is a
// display convenience knob, not a fail-closed security value, and zero would
// silently blank the page. Kept as usize so parse_log_tail/parse_syslog_tail
// limits and the final Vec::truncate need no casts.
fn env_usize_clamped(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|&n| n >= 1)
        .unwrap_or(default)
}

// Canonical truthy-parsing contract for boolean-style env vars in this
// project. `SYSLOG_ENABLED` is also read by services/watchdog/watchdog.sh's
// maybe_prune_syslog(), which implements the identical 1/true/yes/on
// (case-insensitive, trimmed) rule via its own `is_truthy()` shell function
// -- the two cannot literally share one function body across the Rust/Bash
// boundary, but must not drift again the way they did before this file's
// truthy parsing was unified with watchdog.sh's (watchdog used to only
// accept the literal string "true"). See
// `syslog_enabled_truthy_parsing_matches_watchdog_contract` below and
// tests/bats/watchdog_truthy_parsing.bats for parity tests run against the
// exact same input tables on both sides.
fn env_bool(key: &str, default: bool) -> bool {
    env::var(key)
        .ok()
        .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        })
        .unwrap_or(default)
}

// DHCP_MODE (kea/dnsmasq-proxy/disabled) is the current setting. DHCP_ENABLED
// is the older boolean flag from before Kea and dnsmasq-proxy were separate
// choices; `legacy_enabled` is only honored when DHCP_MODE is unset (empty),
// so an explicit DHCP_MODE always wins and old installs that never set
// DHCP_MODE keep working (DHCP_ENABLED=true implied Kea, the only mode that
// existed at the time). `read_dhcp_mode_override` (the persisted Admin-UI
// value) never had a legacy boolean, so it always passes `false` here.
fn parse_dhcp_mode(raw: &str, legacy_enabled: bool) -> DhcpMode {
    match raw.trim().to_ascii_lowercase().as_str() {
        "kea" => DhcpMode::Kea,
        "dnsmasq-proxy" => DhcpMode::DnsmasqProxy,
        "disabled" => DhcpMode::Disabled,
        "" if legacy_enabled => DhcpMode::Kea,
        _ => DhcpMode::Disabled,
    }
}

fn env_dhcp_mode(key: &str, legacy_enabled: bool) -> DhcpMode {
    let raw = env::var(key).unwrap_or_default();
    parse_dhcp_mode(&raw, legacy_enabled)
}

fn read_dhcp_mode_override(path: &str) -> Option<DhcpMode> {
    read_ui_override(path, "DHCP_MODE").map(|value| parse_dhcp_mode(&value, false))
}

// Reads a single `KEY=value` line from the Admin UI's persisted settings
// file (plain text, not a full env-file parser: no quoting, no escaping,
// first non-comment match for `key` wins). This file only exists once an
// operator has changed a DHCP setting from the UI; a missing file or a
// missing key both just mean "no override, use the env default."
fn read_ui_override(path: &str, key: &str) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    let prefix = format!("{key}=");
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(value) = line.strip_prefix(&prefix) {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn env_hsts_mode(key: &str, default: HstsMode) -> HstsMode {
    env::var(key)
        .ok()
        .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
            "auto" | "https" | "forwarded" => Some(HstsMode::Auto),
            "always" | "true" | "1" | "on" => Some(HstsMode::Always),
            "never" | "false" | "0" | "off" => Some(HstsMode::Never),
            _ => None,
        })
        .unwrap_or(default)
}

// Shared across the crate's test suites (this module's own tests plus
// main.rs's tests that call `Config::from_env()`). `cargo test` runs tests in
// parallel threads by default, and `std::env::set_var`/`env::var` are
// process-global, so any test that reads or writes CACHE_DIR/CACHE_MAX_GB (or
// their legacy split-key fallbacks) must hold this lock for its whole
// env-mutation-and-assert window, or it can observe another thread's
// in-flight legacy values and hit `resolve_cache_dir`/`resolve_cache_max_gb`'s
// fail-closed panic spuriously.
#[cfg(test)]
pub(crate) fn env_test_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Auto mode's entire purpose is to gate HSTS on the request's actual
    // scheme -- a plain-HTTP deployment must never receive
    // Strict-Transport-Security, or browsers would start requiring HTTPS for
    // a site that doesn't actually terminate TLS here.
    #[test]
    fn hsts_auto_only_sends_for_https_requests() {
        assert!(HstsMode::Auto.should_send(true));
        assert!(!HstsMode::Auto.should_send(false));
    }

    // Always/Never exist for setups where TLS terminates elsewhere (a
    // reverse proxy) and this process's own view of the request scheme is
    // unreliable or irrelevant -- both overrides must ignore is_https
    // entirely rather than only mostly ignoring it.
    #[test]
    fn hsts_always_and_never_ignore_request_scheme() {
        assert!(HstsMode::Always.should_send(true));
        assert!(HstsMode::Always.should_send(false));
        assert!(!HstsMode::Never.should_send(true));
        assert!(!HstsMode::Never.should_send(false));
    }

    // Pins the three canonical documented UI_HSTS_MODE strings, and that an
    // unrecognized value falls back to the caller-supplied default rather
    // than silently coercing to one specific mode (e.g. always defaulting to
    // Auto regardless of what the caller asked for).
    #[test]
    fn hsts_mode_parser_accepts_documented_values() {
        let key = "LANCACHE_TEST_UI_HSTS_MODE_DOCUMENTED";

        env::set_var(key, "auto");
        assert_eq!(env_hsts_mode(key, HstsMode::Never), HstsMode::Auto);

        env::set_var(key, "always");
        assert_eq!(env_hsts_mode(key, HstsMode::Never), HstsMode::Always);

        env::set_var(key, "never");
        assert_eq!(env_hsts_mode(key, HstsMode::Always), HstsMode::Never);

        env::set_var(key, "unexpected");
        assert_eq!(env_hsts_mode(key, HstsMode::Always), HstsMode::Always);

        env::remove_var(key);
    }

    // Pins env_bool's alias handling for the UI_SECURITY_HEADERS toggle: both
    // "off" and "no" must disable it (not just the canonical "false"/"0"),
    // and an unrecognized value must fall back to the given default instead
    // of being misread as true or false by a naive string comparison.
    #[test]
    fn security_header_toggle_parser_accepts_documented_values() {
        let key = "LANCACHE_TEST_UI_SECURITY_HEADERS_DOCUMENTED";

        env::set_var(key, "true");
        assert!(env_bool(key, false));

        env::set_var(key, "off");
        assert!(!env_bool(key, true));

        env::set_var(key, "no");
        assert!(!env_bool(key, true));

        env::set_var(key, "invalid");
        assert!(env_bool(key, true));

        env::remove_var(key);
    }

    // Broad smoke test for the whole proxy/cache default surface when nothing
    // is configured -- in particular that proxy_ssl_url/proxy_ssl_service
    // derive from proxy_standard_url/PROXY_SERVICE rather than a separate
    // hardcoded string, so the two modes stay pointed at the same proxy by
    // default instead of silently diverging.
    #[test]
    fn cache_dir_fallbacks_match_current_runtime_layout() {
        let _guard = env_test_lock().lock().unwrap();

        for key in [
            "PROXY_SERVICE",
            "PROXY_STANDARD_URL",
            "PROXY_SSL_URL",
            "PROXY_SSL_SERVICE",
            "SSL_ENABLED",
            "STANDARD_LOG",
            "SSL_LOG",
            "CACHE_DIR",
            "CACHE_MAX_GB",
            "STANDARD_CACHE_MAX_GB",
            "SSL_CACHE_MAX_GB",
        ] {
            env::remove_var(key);
        }

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.proxy_standard_url, "http://proxy");
        assert_eq!(cfg.proxy_ssl_url, "http://proxy");
        assert_eq!(cfg.proxy_ssl_service, "proxy");
        assert!(cfg.ssl_enabled);
        assert_eq!(cfg.standard_log, "/var/log/nginx/access.log");
        assert_eq!(cfg.ssl_log, "/var/log/nginx/access.log");
        assert_eq!(cfg.cache_dir, "/var/cache/proxy");
        assert_eq!(cfg.cache_max_gb, 50.0);
    }

    // Confirms CACHE_DIR alone drives cache_dir on the current runtime
    // layout. resolve_cache_dir() deliberately does not accept the
    // pre-v0.2.0 split keys as a fallback here -- setup.sh's migration folds
    // them into CACHE_DIR before the UI ever starts, so re-adding that
    // fallback would just mask a broken migration instead of catching it.
    #[test]
    fn cache_dir_is_read_directly_with_no_legacy_split_key_fallback() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("CACHE_DIR", "/cache/shared");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_dir, "/cache/shared");

        env::remove_var("CACHE_DIR");
    }

    // Old installs that never set the newer explicit
    // PROXY_STANDARD_URL/PROXY_SSL_URL/PROXY_SSL_SERVICE vars must still get
    // working defaults derived from the legacy PROXY_SERVICE alone --
    // dropping this fallback would silently break every install that hasn't
    // migrated its .env yet.
    #[test]
    fn legacy_proxy_service_env_still_drives_runtime_fallbacks() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("PROXY_SERVICE", "legacy-proxy");
        env::remove_var("PROXY_STANDARD_URL");
        env::remove_var("PROXY_SSL_URL");
        env::remove_var("PROXY_SSL_SERVICE");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.proxy_standard_url, "http://legacy-proxy");
        assert_eq!(cfg.proxy_ssl_url, "http://legacy-proxy");
        assert_eq!(cfg.proxy_ssl_service, "legacy-proxy");

        env::remove_var("PROXY_SERVICE");
    }

    // ssl_enabled defaults to true when unset, and both the "0" and "false"
    // aliases must be honored to disable it, not just one particular
    // spelling -- a narrower parser here would silently leave SSL mode
    // enabled for an operator who used the "wrong" alias.
    #[test]
    fn ssl_enabled_accepts_disabled_env_values() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("SSL_ENABLED", "0");
        assert!(!Config::from_env().unwrap().ssl_enabled);

        env::set_var("SSL_ENABLED", "false");
        assert!(!Config::from_env().unwrap().ssl_enabled);

        env::remove_var("SSL_ENABLED");
        assert!(Config::from_env().unwrap().ssl_enabled);
    }

    // The canonical CACHE_MAX_GB must short-circuit the legacy split-value
    // reconciliation entirely -- even mismatched STANDARD_CACHE_MAX_GB/
    // SSL_CACHE_MAX_GB values (which would otherwise panic, see
    // mismatched_legacy_cache_limits_fail_closed below) must not block
    // startup once the canonical key is present.
    #[test]
    fn cache_max_gb_wins_over_legacy_values() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("STANDARD_CACHE_MAX_GB", "77");
        env::set_var("SSL_CACHE_MAX_GB", "88");
        env::set_var("CACHE_MAX_GB", "42.5");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_max_gb, 42.5);

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");
    }

    // For pre-canonical-key installs, matching STANDARD_CACHE_MAX_GB and
    // SSL_CACHE_MAX_GB values must still be accepted as the shared cache-size
    // fallback when CACHE_MAX_GB is absent, rather than requiring an operator
    // to add the new canonical key just to keep an already-consistent old
    // config working.
    #[test]
    fn matching_legacy_cache_limits_can_drive_shared_fallback() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::set_var("STANDARD_CACHE_MAX_GB", "88");
        env::set_var("SSL_CACHE_MAX_GB", "88");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_max_gb, 88.0);

        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");
    }

    // Locks the documented 50 GB default that applies when no cache-size env
    // var (canonical or legacy) is set at all -- a change to this fallback
    // would silently resize the cache for every fresh install that never
    // touches CACHE_MAX_GB.
    #[test]
    fn shared_cache_limit_default_is_50_gb() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_max_gb, 50.0);
    }

    // Guards the deliberate fail-closed design: when the two legacy
    // STANDARD_CACHE_MAX_GB/SSL_CACHE_MAX_GB values disagree and no canonical
    // CACHE_MAX_GB resolves the ambiguity, resolve_cache_max_gb() must panic
    // rather than silently picking one of the two conflicting sizes.
    #[test]
    fn mismatched_legacy_cache_limits_fail_closed() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::set_var("STANDARD_CACHE_MAX_GB", "88");
        env::set_var("SSL_CACHE_MAX_GB", "99");

        let result = std::panic::catch_unwind(Config::from_env);

        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");

        assert!(result.is_err());
    }

    // Unlike the other numeric env parsers in this file (env_u32_clamped,
    // env_usize_clamped), UI_SESSION_TTL_SECONDS must fail startup with a
    // specific error message on a malformed value instead of silently
    // falling back to the default -- a bad session lifetime is a security
    // setting, not a display convenience, so it must not degrade quietly.
    #[test]
    fn ui_session_ttl_defaults_when_unset_and_rejects_invalid_values() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("UI_SESSION_TTL_SECONDS");
        assert_eq!(
            Config::from_env().unwrap().ui_session_ttl_seconds,
            DEFAULT_UI_SESSION_TTL_SECONDS
        );

        env::set_var("UI_SESSION_TTL_SECONDS", "3600s");
        let err = Config::from_env().unwrap_err();
        assert_eq!(
            err,
            "UI_SESSION_TTL_SECONDS must be an unsigned integer number of seconds, got \"3600s\""
        );

        env::set_var("UI_SESSION_TTL_SECONDS", "abc");
        let err = Config::from_env().unwrap_err();
        assert_eq!(
            err,
            "UI_SESSION_TTL_SECONDS must be an unsigned integer number of seconds, got \"abc\""
        );

        env::remove_var("UI_SESSION_TTL_SECONDS");
    }

    // Locks the precedence between an explicit LANCACHE_IMAGE_CHANNEL and the
    // tag-derived fallback (derive_lancache_image_channel): the channel must
    // be derived from the tag only when LANCACHE_IMAGE_CHANNEL is unset, and
    // an explicit channel value must win even when it disagrees with what
    // the tag alone would suggest.
    #[test]
    fn lancache_image_tag_defaults_to_latest_and_accepts_release_tag() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("LANCACHE_IMAGE_REGISTRY");
        env::remove_var("LANCACHE_IMAGE_PREFIX");
        env::remove_var("LANCACHE_IMAGE_CHANNEL");
        env::remove_var("LANCACHE_IMAGE_TAG");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.lancache_image_registry, "ghcr.io");
        assert_eq!(cfg.lancache_image_prefix, "wiki-mod/lancache-ng");
        assert_eq!(cfg.lancache_image_channel, "latest");
        assert_eq!(cfg.lancache_image_tag, "latest");

        env::set_var("LANCACHE_IMAGE_TAG", "sha-deadbeef");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.lancache_image_channel, "pinned");
        assert_eq!(cfg.lancache_image_tag, "sha-deadbeef");

        env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        env::set_var("LANCACHE_IMAGE_CHANNEL", "nightly");
        env::set_var("LANCACHE_IMAGE_TAG", "v1.2.3");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.lancache_image_registry, "registry.example.test:5000");
        assert_eq!(cfg.lancache_image_prefix, "mirror/lancache-ng");
        assert_eq!(cfg.lancache_image_channel, "nightly");
        assert_eq!(cfg.lancache_image_tag, "v1.2.3");

        env::remove_var("LANCACHE_IMAGE_REGISTRY");
        env::remove_var("LANCACHE_IMAGE_PREFIX");
        env::remove_var("LANCACHE_IMAGE_CHANNEL");
        env::remove_var("LANCACHE_IMAGE_TAG");
    }

    // An explicit DHCP_MODE must always win over the legacy DHCP_ENABLED
    // interpretation, including when its value is unrecognized -- an invalid
    // DHCP_MODE must fail closed to Disabled rather than falling through to
    // the legacy flag's Kea-implying behavior, since both Kea and
    // DnsmasqProxy bind the same DHCP port and silently picking the wrong one
    // would conflict with whatever the operator actually intended.
    #[test]
    fn dhcp_mode_prefers_explicit_config_when_present() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("DHCP_MODE", "dnsmasq-proxy");
        env::remove_var("DHCP_ENABLED");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::DnsmasqProxy
        ));

        env::set_var("DHCP_MODE", "kea");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::Kea
        ));

        env::set_var("DHCP_MODE", "disabled");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::Disabled
        ));

        env::set_var("DHCP_MODE", "invalid");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::Disabled
        ));

        env::remove_var("DHCP_MODE");
    }

    // Locks the pre-split legacy interpretation for installs that never set
    // DHCP_MODE: DHCP_ENABLED implied Kea back when Kea was the only DHCP
    // mode this project had, so that mapping must be preserved exactly for
    // old configs rather than defaulting an unmigrated install to Disabled.
    #[test]
    fn dhcp_mode_defaults_from_legacy_enabled_flag() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("DHCP_ENABLED", "1");
        env::remove_var("DHCP_MODE");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::Kea
        ));

        env::set_var("DHCP_ENABLED", "0");
        assert!(matches!(
            Config::from_env().unwrap().dhcp_mode,
            DhcpMode::Disabled
        ));

        env::remove_var("DHCP_ENABLED");
    }

    // dhcp_api_url must stay independent of dhcp_mode: changing the mode via
    // env, or via the persisted Admin UI override that effective_dhcp_mode()
    // reads, must never implicitly change which DHCP API endpoint the UI
    // talks to -- the two are configured separately on purpose.
    #[test]
    fn dhcp_api_url_is_loaded_from_env_and_mode_can_be_overridden() {
        let _guard = env_test_lock().lock().unwrap();
        let settings_path =
            std::env::temp_dir().join(format!("lancache-ui-settings-{}.env", std::process::id()));

        env::set_var("UI_SETTINGS_FILE", &settings_path);
        env::set_var("DHCP_MODE", "dnsmasq-proxy");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().unwrap().dhcp_api_url, "http://dhcp:8000");

        env::set_var("DHCP_MODE", "disabled");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().unwrap().dhcp_api_url, "http://dhcp:8000");

        env::set_var("DHCP_MODE", "kea");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().unwrap().dhcp_api_url, "http://dhcp:8000");

        fs::write(&settings_path, "DHCP_MODE=dnsmasq-proxy\n").unwrap();
        let cfg = Config::from_env().unwrap();
        assert!(matches!(cfg.effective_dhcp_mode(), DhcpMode::DnsmasqProxy));
        assert_eq!(cfg.dhcp_api_url, "http://dhcp:8000");

        env::remove_var("DHCP_MODE");
        env::remove_var("DHCP_API_URL");
        env::remove_var("UI_SETTINGS_FILE");
        let _ = fs::remove_file(settings_path);
    }

    // Pins the documented default snapshot directory and retention count,
    // and confirms both are independently overridable -- kea_keep_known_good_configs
    // feeds env_u32_clamped's silent-fallback parsing, so a wrong default
    // here would silently change snapshot retention for every Kea install
    // that never sets KEEP_KNOWN_GOOD_CONFIGS explicitly.
    #[test]
    fn kea_config_snapshot_settings_load_from_env_with_documented_defaults() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("KEA_CONFIG_SNAPSHOT_DIR");
        env::remove_var("KEEP_KNOWN_GOOD_CONFIGS");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.kea_config_snapshot_dir, "/var/lib/kea/config-snapshots");
        assert_eq!(cfg.kea_keep_known_good_configs, 3);

        env::set_var("KEA_CONFIG_SNAPSHOT_DIR", "/custom/kea-snapshots");
        env::set_var("KEEP_KNOWN_GOOD_CONFIGS", "5");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.kea_config_snapshot_dir, "/custom/kea-snapshots");
        assert_eq!(cfg.kea_keep_known_good_configs, 5);

        env::remove_var("KEA_CONFIG_SNAPSHOT_DIR");
        env::remove_var("KEEP_KNOWN_GOOD_CONFIGS");
    }

    // Confirms both the default values and env overrides for all four syslog
    // settings, since a drift between this Rust side and watchdog.sh's own
    // reading of the same four env vars would make the Admin UI display a
    // retention/enabled state that does not match what watchdog actually
    // enforces.
    #[test]
    fn syslog_settings_load_from_env_with_documented_defaults_matching_watchdog_contract() {
        // Defaults here must match watchdog.sh's maybe_prune_syslog() (PR3/#757)
        // exactly, since both read the same 4 env vars against the same
        // `docker compose --profile logging` deployment.
        let _guard = env_test_lock().lock().unwrap();

        for key in [
            "SYSLOG_ENABLED",
            "SYSLOG_LOG_ROOT",
            "SYSLOG_MAX_GB",
            "SYSLOG_RETENTION_DAYS",
        ] {
            env::remove_var(key);
        }
        let cfg = Config::from_env().unwrap();
        assert!(!cfg.syslog_enabled);
        assert_eq!(cfg.syslog_log_root, "/var/log/lancache-syslog-ng");
        assert_eq!(cfg.syslog_max_gb, 10);
        assert_eq!(cfg.syslog_retention_days, 30);

        env::set_var("SYSLOG_ENABLED", "true");
        env::set_var("SYSLOG_LOG_ROOT", "/custom/syslog-root");
        env::set_var("SYSLOG_MAX_GB", "25");
        env::set_var("SYSLOG_RETENTION_DAYS", "7");
        let cfg = Config::from_env().unwrap();
        assert!(cfg.syslog_enabled);
        assert_eq!(cfg.syslog_log_root, "/custom/syslog-root");
        assert_eq!(cfg.syslog_max_gb, 25);
        assert_eq!(cfg.syslog_retention_days, 7);

        for key in [
            "SYSLOG_ENABLED",
            "SYSLOG_LOG_ROOT",
            "SYSLOG_MAX_GB",
            "SYSLOG_RETENTION_DAYS",
        ] {
            env::remove_var(key);
        }
    }

    // Proves env_bool()'s SYSLOG_ENABLED parsing agrees with watchdog.sh's
    // is_truthy() (services/watchdog/watchdog.sh) on the exact same input
    // tables that tests/bats/watchdog_truthy_parsing.bats and
    // tests/bats/watchdog_syslog_prune.bats exercise against the shell side.
    // watchdog.sh previously only accepted the literal string "true" here,
    // so "1"/"yes"/"on" showed as enabled in the Admin UI while watchdog's
    // maybe_prune_syslog() silently never ran. If either side's accepted-value
    // set is ever edited without updating the other, this test and its bats
    // counterparts stop agreeing on at least one of these inputs.
    #[test]
    fn syslog_enabled_truthy_parsing_matches_watchdog_contract() {
        let _guard = env_test_lock().lock().unwrap();
        let key = "LANCACHE_TEST_UI_SYSLOG_ENABLED_WATCHDOG_PARITY";

        for value in [
            "1", "true", "TRUE", "True", "yes", "YES", "Yes", "on", "ON", "On", " true ", "\ton\t",
        ] {
            env::set_var(key, value);
            assert!(
                env_bool(key, false),
                "expected SYSLOG_ENABLED={value:?} to be truthy"
            );
        }

        for value in [
            "0",
            "false",
            "FALSE",
            "no",
            "NO",
            "off",
            "OFF",
            "",
            "   ",
            "garbage",
            "1x",
            "truex",
            "yesplease",
        ] {
            env::set_var(key, value);
            assert!(
                !env_bool(key, false),
                "expected SYSLOG_ENABLED={value:?} to be falsy"
            );
        }

        env::remove_var(key);
    }

    // A literal "0" parses fine as a u32 but is semantically wrong for a
    // retention count (e.g. KEEP_KNOWN_GOOD_CONFIGS=0), so it must fall back
    // to the default the same as a non-numeric value -- matching the shell
    // side's kgs_snapshot_prune clamping instead of silently accepting "keep
    // zero snapshots".
    #[test]
    fn env_u32_clamped_falls_back_to_default_for_invalid_or_non_positive_values() {
        let _guard = env_test_lock().lock().unwrap();
        let key = "LANCACHE_TEST_UI_KEEP_KNOWN_GOOD_CONFIGS_CLAMP";

        env::remove_var(key);
        assert_eq!(env_u32_clamped(key, 3), 3);

        for invalid in ["0", "", "abc", "-1"] {
            env::set_var(key, invalid);
            assert_eq!(
                env_u32_clamped(key, 3),
                3,
                "expected default for invalid value {invalid:?}"
            );
        }

        env::set_var(key, "7");
        assert_eq!(env_u32_clamped(key, 3), 7);

        env::remove_var(key);
    }

    // Parity test for SYSLOG_MAX_GB's ceiling against watchdog.sh's own
    // magnitude guard (`[ "$max_gb" -gt 1048576 ]` in maybe_prune_syslog()).
    // tests/bats/watchdog_syslog_prune.bats exercises the same SYSLOG_MAX_GB
    // values against the real shell function and asserts the same clamped
    // budget appears in its log output, so both sides agree this value, not
    // just "does not crash", is what each component actually enforces.
    #[test]
    fn syslog_max_gb_oversized_value_clamps_to_watchdog_ceiling() {
        let _guard = env_test_lock().lock().unwrap();
        let key = "LANCACHE_TEST_UI_SYSLOG_MAX_GB_CEILING";

        // In-range for u32 but above watchdog.sh's ceiling: env_u32_clamped
        // alone (no max) would have returned this value unclamped, while
        // watchdog.sh's own guard already capped its budget at the ceiling.
        env::set_var(key, "2000000");
        assert_eq!(
            env_u32_clamped_with_max(key, 10, SYSLOG_MAX_GB_CEILING),
            SYSLOG_MAX_GB_CEILING
        );

        // Overflows u32 (>= 4_294_967_296): plain `parse::<u32>()` fails
        // outright here, but watchdog.sh's 64-bit bash arithmetic does not
        // overflow at this magnitude and clamps to the same ceiling instead
        // of falling back to its own default -- this must match, not fall
        // back to `default` the way env_u32_clamped alone would.
        env::set_var(key, "9999999999");
        assert_eq!(
            env_u32_clamped_with_max(key, 10, SYSLOG_MAX_GB_CEILING),
            SYSLOG_MAX_GB_CEILING
        );

        // A literal 0 still falls back to `default`, same floor as
        // env_u32_clamped.
        env::set_var(key, "0");
        assert_eq!(env_u32_clamped_with_max(key, 10, SYSLOG_MAX_GB_CEILING), 10);

        // An in-range, under-ceiling value passes through unchanged.
        env::set_var(key, "25");
        assert_eq!(env_u32_clamped_with_max(key, 10, SYSLOG_MAX_GB_CEILING), 25);

        env::remove_var(key);
    }

    // A "0" value for UI_LOGS_MAX_ENTRIES must fall back to the default
    // rather than being accepted literally -- an actual zero-entry limit
    // would silently blank the Admin UI's /logs tail view instead of showing
    // the intended bounded history.
    #[test]
    fn env_usize_clamped_falls_back_to_default_for_invalid_or_non_positive_values() {
        let _guard = env_test_lock().lock().unwrap();
        let key = "LANCACHE_TEST_UI_LOGS_MAX_ENTRIES_CLAMP";

        env::remove_var(key);
        assert_eq!(env_usize_clamped(key, 200), 200);

        for invalid in ["0", "", "abc", "-1"] {
            env::set_var(key, invalid);
            assert_eq!(
                env_usize_clamped(key, 200),
                200,
                "expected default for invalid value {invalid:?}"
            );
        }

        env::set_var(key, "500");
        assert_eq!(env_usize_clamped(key, 200), 500);

        env::remove_var(key);
    }

    // Verifies the optional dnsmasq relay/proxy fields follow the same
    // env-then-UI-override precedence as the older DHCP_SUBNET_START/
    // UPSTREAM_DHCP_IP fields, including that a partial override file (only
    // some keys present) still falls back to env for the fields it omits
    // rather than clearing them.
    #[test]
    fn dhcp_proxy_optional_fields_load_from_env_and_ui_override_wins() {
        // Issue #450: the new optional dnsmasq relay/proxy fields follow the
        // same two-layer effective_* pattern as the pre-existing
        // DHCP_SUBNET_START/UPSTREAM_DHCP_IP fields -- verify both the env
        // load and that a persisted Admin UI override takes precedence.
        let _guard = env_test_lock().lock().unwrap();
        let settings_path = std::env::temp_dir().join(format!(
            "lancache-ui-settings-dhcp-proxy-optional-{}.env",
            std::process::id()
        ));
        let _ = fs::remove_file(&settings_path);
        env::set_var("UI_SETTINGS_FILE", &settings_path);

        env::set_var("DHCP_PROXY_INTERFACE", "eth0");
        env::set_var("DHCP_PROXY_ROUTER", "10.0.0.1");
        env::set_var("DHCP_PROXY_DOMAIN", "lan.local");
        env::set_var("DHCP_PROXY_BOOT_FILENAME", "pxelinux.0");
        env::set_var("DHCP_PROXY_BOOT_SERVER", "10.0.0.5");
        env::set_var("DHCP_PROXY_CUSTOM_OPTIONS", "60:PXEClient");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.dhcp_proxy_interface, "eth0");
        assert_eq!(cfg.dhcp_proxy_router, "10.0.0.1");
        assert_eq!(cfg.dhcp_proxy_domain, "lan.local");
        assert_eq!(cfg.dhcp_proxy_boot_filename, "pxelinux.0");
        assert_eq!(cfg.dhcp_proxy_boot_server, "10.0.0.5");
        assert_eq!(cfg.dhcp_proxy_custom_options, "60:PXEClient");
        assert_eq!(cfg.effective_dhcp_proxy_interface(), "eth0");
        assert_eq!(cfg.effective_dhcp_proxy_router(), "10.0.0.1");
        assert_eq!(cfg.effective_dhcp_proxy_domain(), "lan.local");
        assert_eq!(cfg.effective_dhcp_proxy_boot_filename(), "pxelinux.0");
        assert_eq!(cfg.effective_dhcp_proxy_boot_server(), "10.0.0.5");
        assert_eq!(cfg.effective_dhcp_proxy_custom_options(), "60:PXEClient");

        fs::write(
            &settings_path,
            "DHCP_PROXY_INTERFACE=eth1\nDHCP_PROXY_ROUTER=10.0.0.254\n",
        )
        .unwrap();
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.effective_dhcp_proxy_interface(), "eth1");
        assert_eq!(cfg.effective_dhcp_proxy_router(), "10.0.0.254");
        // Fields not present in the override file still fall back to env.
        assert_eq!(cfg.effective_dhcp_proxy_domain(), "lan.local");

        for key in [
            "DHCP_PROXY_INTERFACE",
            "DHCP_PROXY_ROUTER",
            "DHCP_PROXY_DOMAIN",
            "DHCP_PROXY_BOOT_FILENAME",
            "DHCP_PROXY_BOOT_SERVER",
            "DHCP_PROXY_CUSTOM_OPTIONS",
            "UI_SETTINGS_FILE",
        ] {
            env::remove_var(key);
        }
        let _ = fs::remove_file(&settings_path);
    }

    // Guards that leaving the optional proxy fields unset produces true
    // empty strings, not some other placeholder value -- ui_override_lines's
    // "omit the line when empty" logic (see below) depends on exactly this
    // empty-string default to detect an unconfigured field.
    #[test]
    fn dhcp_proxy_optional_fields_default_empty() {
        let _guard = env_test_lock().lock().unwrap();

        for key in [
            "DHCP_PROXY_INTERFACE",
            "DHCP_PROXY_ROUTER",
            "DHCP_PROXY_DOMAIN",
            "DHCP_PROXY_BOOT_FILENAME",
            "DHCP_PROXY_BOOT_SERVER",
            "DHCP_PROXY_CUSTOM_OPTIONS",
        ] {
            env::remove_var(key);
        }

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.dhcp_proxy_interface, "");
        assert_eq!(cfg.dhcp_proxy_router, "");
        assert_eq!(cfg.dhcp_proxy_domain, "");
        assert_eq!(cfg.dhcp_proxy_boot_filename, "");
        assert_eq!(cfg.dhcp_proxy_boot_server, "");
        assert_eq!(cfg.dhcp_proxy_custom_options, "");
    }

    // An unset optional proxy field must not be persisted as a literal
    // "KEY=" line in ui_settings_file: writing an empty override would pin
    // an empty string instead of correctly falling back to the env default
    // on the next read, silently breaking any env value set after the
    // override file was written.
    #[test]
    fn ui_override_lines_omit_empty_optional_dhcp_proxy_fields() {
        let _guard = env_test_lock().lock().unwrap();
        let settings_path = std::env::temp_dir().join(format!(
            "lancache-ui-settings-override-lines-{}.env",
            std::process::id()
        ));
        let _ = fs::remove_file(&settings_path);
        env::set_var("UI_SETTINGS_FILE", &settings_path);
        env::set_var("DHCP_MODE", "dnsmasq-proxy");
        for key in [
            "DHCP_PROXY_INTERFACE",
            "DHCP_PROXY_ROUTER",
            "DHCP_PROXY_DOMAIN",
            "DHCP_PROXY_BOOT_FILENAME",
            "DHCP_PROXY_BOOT_SERVER",
            "DHCP_PROXY_CUSTOM_OPTIONS",
        ] {
            env::remove_var(key);
        }

        let cfg = Config::from_env().unwrap();
        let lines = cfg.ui_override_lines();
        for key in [
            "DHCP_PROXY_INTERFACE",
            "DHCP_PROXY_ROUTER",
            "DHCP_PROXY_DOMAIN",
            "DHCP_PROXY_BOOT_FILENAME",
            "DHCP_PROXY_BOOT_SERVER",
            "DHCP_PROXY_CUSTOM_OPTIONS",
        ] {
            assert!(
                !lines
                    .iter()
                    .any(|line| line.starts_with(&format!("{key}="))),
                "expected no {key} line when unset, got {lines:?}"
            );
        }

        env::remove_var("DHCP_MODE");
        env::remove_var("UI_SETTINGS_FILE");
        let _ = fs::remove_file(&settings_path);
    }

    // Pins the full decision table for guessing a channel from an image tag
    // when LANCACHE_IMAGE_CHANNEL isn't set explicitly -- in particular that
    // any release/SHA-pinned tag reports "pinned" rather than a wrong guess
    // of "latest", and that an unrecognized tag shape never panics, only
    // defaults to "latest".
    #[test]
    fn derive_lancache_image_channel_resolves_semantic_tags() {
        // Test mutable channel tags: "dev", "nightly", and "latest"
        // are passed through unchanged.
        assert_eq!(derive_lancache_image_channel("dev"), "dev");
        assert_eq!(derive_lancache_image_channel("nightly"), "nightly");
        assert_eq!(derive_lancache_image_channel("latest"), "latest");

        // The old "edge" channel was renamed to "nightly" and hard-cut in
        // v0.3.0 (#1056): "edge" is deliberately not recognized as a channel
        // anymore, so an image somehow still tagged "edge" falls through to the
        // generic "latest" default rather than being aliased back to "nightly".
        assert_eq!(derive_lancache_image_channel("edge"), "latest");

        // Test immutable pinned references: tags starting with "sha-"
        // (commit SHAs) or "v" (semantic versions) resolve to "pinned".
        assert_eq!(derive_lancache_image_channel("sha-deadbeef"), "pinned");
        assert_eq!(derive_lancache_image_channel("sha-abc123def456"), "pinned");
        assert_eq!(derive_lancache_image_channel("v1.2.3"), "pinned");
        assert_eq!(derive_lancache_image_channel("v0.2.0"), "pinned");

        // Test release-candidate tags are also immutable pinned references.
        assert_eq!(derive_lancache_image_channel("v1.2.3-rc.1"), "pinned");

        // Test unknown tags default to "latest" to maintain compatibility
        // with image registries that may introduce new tag formats in the future.
        assert_eq!(derive_lancache_image_channel("custom-tag"), "latest");
        assert_eq!(derive_lancache_image_channel("nightly"), "latest");
        assert_eq!(derive_lancache_image_channel("main"), "latest");
    }

    // Issue #866: register_secondary must never hand a remote secondary the
    // Docker-internal nats_url as-is -- neither directly nor as a silent
    // fallback -- when there is no real externally-reachable address
    // configured; it must refuse instead (see advertised_nats_url's own doc
    // comment for why None, not a fallback to nats_url, is the correct
    // "unconfigured" result). These tests exercise
    // Config::advertised_nats_url directly through Config::from_env, the
    // same way it's actually populated at process start, rather than
    // hand-building a Config literal (the struct has no Default impl and
    // dozens of unrelated fields).
    #[test]
    fn advertised_nats_url_is_none_when_neither_override_is_configured() {
        let _guard = env_test_lock().lock().unwrap();
        for key in ["NATS_URL", "NATS_BIND_IP", "NATS_ADVERTISE_URL"] {
            env::remove_var(key);
        }

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.nats_url, "nats://nats:4222");
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "with neither override set there is no reachable address to \
             advertise -- register_secondary must refuse the registration, \
             never fall back to the Docker-internal nats_url that #866 \
             reports as unreachable from every real remote secondary"
        );

        env::remove_var("NATS_URL");
    }

    // Confirms the second-highest-precedence branch: reusing NATS_BIND_IP
    // (already required by docker-compose.nats-secondary.yml) is enough on
    // its own, with no separate NATS_ADVERTISE_URL configuration needed.
    #[test]
    fn advertised_nats_url_derives_from_nats_bind_ip_when_no_explicit_override() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "192.168.1.5");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            Some("nats://192.168.1.5:4222".to_string()),
            "nats_bind_ip is the same trusted LAN/VPN IP already used to \
             publish NATS's host port for remote secondaries -- deriving the \
             advertised URL from it needs no separate configuration step"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // Confirms the documented precedence order itself: with both set at
    // once, the explicit override must win, not the derived one.
    #[test]
    fn advertised_nats_url_explicit_override_wins_over_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::set_var("NATS_BIND_IP", "192.168.1.5");
        env::set_var("NATS_ADVERTISE_URL", "tls://nats.vpn.example:4333");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            Some("tls://nats.vpn.example:4333".to_string()),
            "an explicit NATS_ADVERTISE_URL must win over a derived \
             nats_bind_ip URL -- it's the only way to express a non-default \
             port, a tls:// scheme, or a VPN hostname"
        );

        env::remove_var("NATS_BIND_IP");
        env::remove_var("NATS_ADVERTISE_URL");
    }

    // Confirms an operator who sets NATS_BIND_IP/NATS_ADVERTISE_URL to
    // whitespace (e.g. a stray blank-string .env line) gets the same
    // fail-closed None result as leaving it unset entirely, not a bogus
    // "nats://   :4222"-shaped Some.
    #[test]
    fn advertised_nats_url_treats_whitespace_only_overrides_as_unset() {
        let _guard = env_test_lock().lock().unwrap();
        env::set_var("NATS_BIND_IP", "   ");
        env::set_var("NATS_ADVERTISE_URL", "   ");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "a whitespace-only env value must not be mistaken for a real \
             override, the same way other optional string fields in this \
             module treat it as unset (see e.g. effective_dhcp_ntp_servers's \
             callers in ui_override_lines) -- it must still resolve to None, \
             not a false-positive Some"
        );

        env::remove_var("NATS_BIND_IP");
        env::remove_var("NATS_ADVERTISE_URL");
    }

    // An IPv6 NATS_BIND_IP literal must be bracketed in the derived URL --
    // `nats://2001:db8::5:4222` is not a parsable host:port pair (the
    // literal's own colons collide with the port separator), so a remote
    // secondary handed that value could never connect even though
    // registration itself "succeeded".
    #[test]
    fn advertised_nats_url_brackets_ipv6_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "2001:db8::5");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            Some("nats://[2001:db8::5]:4222".to_string()),
            "an IPv6 NATS_BIND_IP literal must be bracketed when deriving \
             the advertised URL, or the result is not a valid, parsable \
             NATS URL"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // The happy-path counterpart to the bracketed-wildcard-rejection test
    // below: a bracketed IPv6 *literal* (not a wildcard) NATS_BIND_IP must
    // still resolve to a working, bracketed advertised URL after the
    // bracket-stripping fix, not accidentally get treated as an opaque
    // hostname or double-bracketed.
    #[test]
    fn advertised_nats_url_brackets_bracketed_ipv6_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "[2001:db8::5]");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            Some("nats://[2001:db8::5]:4222".to_string()),
            "a NATS_BIND_IP already written in Compose's bracketed IPv6 \
             form must resolve the same as the bare form, not be treated \
             as an opaque hostname"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // An explicit NATS_ADVERTISE_URL is never IP-parsed or reformatted --
    // an operator who set it explicitly may legitimately want a bracketed
    // IPv6 literal, a hostname, or a non-default scheme/port, and is
    // asserting the value is already correct.
    #[test]
    fn advertised_nats_url_leaves_explicit_override_untouched_for_ipv6() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_BIND_IP");
        env::set_var("NATS_ADVERTISE_URL", "nats://[2001:db8::5]:4333");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            Some("nats://[2001:db8::5]:4333".to_string()),
            "an explicit NATS_ADVERTISE_URL must be returned exactly as \
             configured, never reparsed/reformatted"
        );

        env::remove_var("NATS_ADVERTISE_URL");
    }

    // A wildcard NATS_BIND_IP (0.0.0.0) is a valid *listen* address --
    // docs/architecture-ng.md documents binding to it behind an external
    // firewall/VPN as supported -- but is never a routable address a
    // remote secondary could dial. Echoing it back as the advertised URL
    // would make registration look successful while leaving the secondary
    // with an unreachable address, reproducing #866 under a different
    // config; this must fail closed to None (register_secondary turns that
    // into an HTTP 503 refusal) instead.
    #[test]
    fn advertised_nats_url_rejects_ipv4_wildcard_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "0.0.0.0");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "0.0.0.0 is a listen wildcard, not a routable address a remote \
             secondary could dial -- it must not be advertised"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // Same as the IPv4 case above, for the IPv6 wildcard/unspecified
    // address `::`.
    #[test]
    fn advertised_nats_url_rejects_ipv6_wildcard_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "::");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            ":: is the IPv6 listen wildcard, not a routable address a \
             remote secondary could dial -- it must not be advertised"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // A NATS_BIND_IP that is a hostname (not an IP literal at all) must be
    // rejected, not passed through: NATS_BIND_IP feeds Compose's port `HOST`
    // field, which is an IP/port bind, not a resolvable name -- there is no
    // guarantee a hostname value is actually reachable at the address `nats`
    // publishes on. The operator must set NATS_ADVERTISE_URL explicitly for
    // a hostname/reverse-proxy case instead.
    #[test]
    fn advertised_nats_url_rejects_hostname_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "nats.vpn.example");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "a hostname NATS_BIND_IP is not a parsable IP literal and cannot \
             be assumed reachable at whatever address 'nats' actually \
             publishes on -- it must fail closed to None, requiring an \
             explicit NATS_ADVERTISE_URL instead"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // Docker Compose documents the square-bracketed IPv6 wildcard form
    // (`[::]`) as valid for a port `HOST` field alongside the bare `::`.
    // Before the bracket-stripping fix, `"[::]".parse::<IpAddr>()` failed
    // (IpAddr::parse never accepts brackets) and fell through to the
    // hostname branch, producing `nats://[::]:4222` instead of the intended
    // fail-closed rejection -- reproducing the exact wildcard-advertised bug
    // the plain `::` test above already guards against, just spelled with
    // brackets.
    #[test]
    fn advertised_nats_url_rejects_bracketed_ipv6_wildcard_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "[::]");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "the bracketed IPv6 wildcard form [::] must be recognized as \
             the same unspecified address as bare :: and rejected, not \
             treated as an opaque hostname"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // A remote secondary cannot dial loopback on the primary -- accepting
    // 127.0.0.1 here would report the fail-closed check as satisfied while
    // reproducing the original #866 silent-sync-failure under a config that
    // merely looks valid.
    #[test]
    fn advertised_nats_url_rejects_ipv4_loopback_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "127.0.0.1");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "127.0.0.1 can never be dialed by a genuinely remote secondary \
             -- it must not be advertised, the same as a wildcard bind"
        );

        env::remove_var("NATS_BIND_IP");
    }

    // Same as the IPv4 loopback case above, for `::1`.
    #[test]
    fn advertised_nats_url_rejects_ipv6_loopback_nats_bind_ip() {
        let _guard = env_test_lock().lock().unwrap();
        env::remove_var("NATS_ADVERTISE_URL");
        env::set_var("NATS_BIND_IP", "::1");

        let cfg = Config::from_env().unwrap();
        assert_eq!(
            cfg.advertised_nats_url(),
            None,
            "::1 can never be dialed by a genuinely remote secondary -- it \
             must not be advertised, the same as a wildcard bind"
        );

        env::remove_var("NATS_BIND_IP");
    }
}
