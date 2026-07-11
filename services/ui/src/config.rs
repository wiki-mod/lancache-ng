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
    pub pdns_auth_url: String,
    pub pdns_rec_url: String,
    pub pdns_api_key: String,
    pub nats_url: String,
    pub nats_ui_user: String,
    pub nats_ui_password: String,
    pub nats_dns_writer_user: String,
    pub nats_dns_writer_password: String,
    // Static role for the primary's own co-located dns-ssl container (issue
    // #583 renamed this from nats_dns_reader_*: unlike external secondaries,
    // there is always exactly one dns-ssl instance on the primary host, so a
    // fixed static credential never hits the #52 scaling problem -- only the
    // *external, dynamically-registered* secondaries needed to move off a
    // shared credential). Subscribe-only, same permission scope the old
    // reader role had.
    pub nats_dns_replica_user: String,
    pub nats_dns_replica_password: String,
    // Static bypass identity the auth-callout responder (issue #583) itself
    // connects as, to subscribe to $SYS.REQ.USER.AUTH. Distinct from
    // nats_ui_user: that one publishes DNS records, this one only answers
    // authorization requests for secondaries and needs no other permissions.
    pub nats_callout_user: String,
    pub nats_callout_password: String,
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
    pub lancache_image_tag: String,
    pub nats_conf_path: String,
    pub nats_service: String,
    pub dev_mode: bool,
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
            .field("pdns_auth_url", &self.pdns_auth_url)
            .field("pdns_rec_url", &self.pdns_rec_url)
            .field("pdns_api_key", &"***REDACTED***")
            .field("nats_url", &self.nats_url)
            .field("nats_ui_user", &self.nats_ui_user)
            .field("nats_ui_password", &"***REDACTED***")
            .field("nats_dns_writer_user", &self.nats_dns_writer_user)
            .field("nats_dns_writer_password", &"***REDACTED***")
            .field("nats_dns_replica_user", &self.nats_dns_replica_user)
            .field("nats_dns_replica_password", &"***REDACTED***")
            .field("nats_callout_user", &self.nats_callout_user)
            .field("nats_callout_password", &"***REDACTED***")
            .field("nats_issuer_seed_path", &self.nats_issuer_seed_path)
            .field(
                "nats_issuer_seed",
                &self.nats_issuer_seed.as_ref().map(|_| "***REDACTED***"),
            )
            .field("secondary_registration_token", &"***REDACTED***")
            .field("lancache_image_registry", &self.lancache_image_registry)
            .field("lancache_image_prefix", &self.lancache_image_prefix)
            .field("lancache_image_channel", &self.lancache_image_channel)
            .field("lancache_image_tag", &self.lancache_image_tag)
            .field("nats_conf_path", &self.nats_conf_path)
            .field("nats_service", &self.nats_service)
            .field("dev_mode", &self.dev_mode)
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
            pdns_auth_url: env_str("PDNS_AUTH_URL", "http://dns-standard:8081"),
            pdns_rec_url: env_str("PDNS_REC_URL", "http://dns-standard:8082"),
            pdns_api_key: env_str("PDNS_API_KEY", ""),
            nats_url: env_str("NATS_URL", "nats://nats:4222"),
            nats_ui_user: env_str("NATS_UI_USER", ""),
            nats_ui_password: env_str("NATS_UI_PASSWORD", ""),
            nats_dns_writer_user: env_str("NATS_DNS_WRITER_USER", ""),
            nats_dns_writer_password: env_str("NATS_DNS_WRITER_PASSWORD", ""),
            nats_dns_replica_user: env_str("NATS_DNS_REPLICA_USER", ""),
            nats_dns_replica_password: env_str("NATS_DNS_REPLICA_PASSWORD", ""),
            nats_callout_user: env_str("NATS_CALLOUT_USER", ""),
            nats_callout_password: env_str("NATS_CALLOUT_PASSWORD", ""),
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
            lancache_image_tag,
            nats_conf_path: env_str("NATS_CONF_PATH", "/etc/nats/nats.conf"),
            nats_service: env_str("NATS_SERVICE", "nats"),
            dev_mode: env_bool("LANCACHE_DEV_MODE", false),
        })
    }
}

// Guesses which release channel (see docs/release-versioning.md) the
// currently-running image tag belongs to, for display in the Admin UI only
// (LANCACHE_IMAGE_CHANNEL should normally be set explicitly by the deploy
// tooling; this is a best-effort fallback when it isn't). `dev`/`edge`/
// `latest` tags map straight to their channel name. A `v`- or `sha-`-prefixed
// tag means a specific release or commit was pinned deliberately, which this
// function can't distinguish from any other channel, so it reports "pinned"
// rather than guessing wrong. Anything else defaults to "latest".
fn derive_lancache_image_channel(tag: &str) -> String {
    if tag == "dev" || tag == "edge" || tag == "latest" {
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

    #[test]
    fn hsts_auto_only_sends_for_https_requests() {
        assert!(HstsMode::Auto.should_send(true));
        assert!(!HstsMode::Auto.should_send(false));
    }

    #[test]
    fn hsts_always_and_never_ignore_request_scheme() {
        assert!(HstsMode::Always.should_send(true));
        assert!(HstsMode::Always.should_send(false));
        assert!(!HstsMode::Never.should_send(true));
        assert!(!HstsMode::Never.should_send(false));
    }

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

    #[test]
    fn cache_dir_is_read_directly_with_no_legacy_split_key_fallback() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("CACHE_DIR", "/cache/shared");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_dir, "/cache/shared");

        env::remove_var("CACHE_DIR");
    }

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

    #[test]
    fn shared_cache_limit_default_is_50_gb() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");

        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.cache_max_gb, 50.0);
    }

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
        env::set_var("LANCACHE_IMAGE_CHANNEL", "edge");
        env::set_var("LANCACHE_IMAGE_TAG", "v1.2.3");
        let cfg = Config::from_env().unwrap();
        assert_eq!(cfg.lancache_image_registry, "registry.example.test:5000");
        assert_eq!(cfg.lancache_image_prefix, "mirror/lancache-ng");
        assert_eq!(cfg.lancache_image_channel, "edge");
        assert_eq!(cfg.lancache_image_tag, "v1.2.3");

        env::remove_var("LANCACHE_IMAGE_REGISTRY");
        env::remove_var("LANCACHE_IMAGE_PREFIX");
        env::remove_var("LANCACHE_IMAGE_CHANNEL");
        env::remove_var("LANCACHE_IMAGE_TAG");
    }

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

    #[test]
    fn derive_lancache_image_channel_resolves_semantic_tags() {
        // Test mutable channel tags: "dev", "edge", and "latest"
        // are passed through unchanged.
        assert_eq!(derive_lancache_image_channel("dev"), "dev");
        assert_eq!(derive_lancache_image_channel("edge"), "edge");
        assert_eq!(derive_lancache_image_channel("latest"), "latest");

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
}
