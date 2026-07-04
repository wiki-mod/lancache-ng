//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Runtime configuration for the Admin UI service: loads and validates
//! settings from the process environment (auth, DHCP mode, HSTS mode,
//! session TTL, and related toggles) into a typed `Config`.

use std::env;
use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HstsMode {
    Auto,
    Always,
    Never,
}

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
    pub ssl_domains_file: String,
    pub standard_log: String,
    pub ssl_log: String,
    pub standard_cache_dir: String,
    pub ssl_cache_dir: String,
    pub dns_standard_state_dir: String,
    pub dns_ssl_state_dir: String,
    pub proxy_standard_url: String,
    pub proxy_ssl_url: String,
    pub netdata_url: String,
    pub dns_standard_service: String,
    pub dns_ssl_service: String,
    pub proxy_ssl_service: String,
    pub ssl_enabled: bool,
    pub standard_cache_max_gb: f64,
    pub ssl_cache_max_gb: f64,
    pub standard_ip: String,
    pub ssl_ip: String,
    pub dhcp_mode: DhcpMode,
    pub dhcp_api_url: String,
    pub dhcp_api_token: String,
    pub auth_user: Option<String>,
    pub auth_password: Option<String>,
    pub allow_insecure_ui: bool,
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
    pub nats_dns_reader_user: String,
    pub nats_dns_reader_password: String,
    pub secondary_registration_token: String,
    pub lancache_image_registry: String,
    pub lancache_image_prefix: String,
    pub lancache_image_channel: String,
    pub lancache_image_tag: String,
    pub nats_conf_path: String,
    pub nats_service: String,
    pub dev_mode: bool,
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("template_dir", &self.template_dir)
            .field("cdn_domains_file", &self.cdn_domains_file)
            .field("ssl_domains_file", &self.ssl_domains_file)
            .field("standard_log", &self.standard_log)
            .field("ssl_log", &self.ssl_log)
            .field("standard_cache_dir", &self.standard_cache_dir)
            .field("ssl_cache_dir", &self.ssl_cache_dir)
            .field("dns_standard_state_dir", &self.dns_standard_state_dir)
            .field("dns_ssl_state_dir", &self.dns_ssl_state_dir)
            .field("proxy_standard_url", &self.proxy_standard_url)
            .field("proxy_ssl_url", &self.proxy_ssl_url)
            .field("netdata_url", &self.netdata_url)
            .field("dns_standard_service", &self.dns_standard_service)
            .field("dns_ssl_service", &self.dns_ssl_service)
            .field("proxy_ssl_service", &self.proxy_ssl_service)
            .field("ssl_enabled", &self.ssl_enabled)
            .field("standard_cache_max_gb", &self.standard_cache_max_gb)
            .field("ssl_cache_max_gb", &self.ssl_cache_max_gb)
            .field("standard_ip", &self.standard_ip)
            .field("ssl_ip", &self.ssl_ip)
            .field("dhcp_mode", &self.dhcp_mode.as_str())
            .field("dhcp_api_url", &self.dhcp_api_url)
            .field("dhcp_api_token", &"***REDACTED***")
            .field(
                "auth_user",
                &self.auth_user.as_ref().map(|_| "***REDACTED***"),
            )
            .field(
                "auth_password",
                &self.auth_password.as_ref().map(|_| "***REDACTED***"),
            )
            .field("allow_insecure_ui", &self.allow_insecure_ui)
            .field("pdns_auth_url", &self.pdns_auth_url)
            .field("pdns_rec_url", &self.pdns_rec_url)
            .field("pdns_api_key", &"***REDACTED***")
            .field("nats_url", &self.nats_url)
            .field("nats_ui_user", &self.nats_ui_user)
            .field("nats_ui_password", &"***REDACTED***")
            .field("nats_dns_writer_user", &self.nats_dns_writer_user)
            .field("nats_dns_writer_password", &"***REDACTED***")
            .field("nats_dns_reader_user", &self.nats_dns_reader_user)
            .field("nats_dns_reader_password", &"***REDACTED***")
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

impl Config {
    pub fn from_env() -> Self {
        let proxy_service = env_or("PROXY_SERVICE", "proxy".to_string());
        let standard_log = env_or("STANDARD_LOG", "/var/log/nginx/access.log".to_string());
        let ssl_log = env_or("SSL_LOG", standard_log.clone());
        let standard_cache_dir = env_or("STANDARD_CACHE_DIR", "/var/cache/proxy".to_string());
        let ssl_cache_dir = env_or("SSL_CACHE_DIR", standard_cache_dir.clone());
        let proxy_standard_url = env_or("PROXY_STANDARD_URL", format!("http://{proxy_service}"));
        let proxy_ssl_url = env_or("PROXY_SSL_URL", proxy_standard_url.clone());
        let proxy_ssl_service = env_or("PROXY_SSL_SERVICE", proxy_service.clone());
        let ssl_enabled = env_bool("SSL_ENABLED", true);
        let cache_max_gb_set = env_present("CACHE_MAX_GB");
        let shared_cache_max_gb = if cache_max_gb_set {
            env_f64("CACHE_MAX_GB", 50.0)
        } else {
            env_f64("STANDARD_CACHE_MAX_GB", env_f64("SSL_CACHE_MAX_GB", 50.0))
        };
        let dhcp_mode = env_dhcp_mode("DHCP_MODE", env_bool("DHCP_ENABLED", false));
        let dhcp_api_url = if dhcp_mode.is_kea() {
            env_str("DHCP_API_URL", "http://localhost:8000")
        } else {
            String::new()
        };

        let lancache_image_tag = env_str("LANCACHE_IMAGE_TAG", "latest");
        let lancache_image_channel = env::var("LANCACHE_IMAGE_CHANNEL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| derive_lancache_image_channel(&lancache_image_tag));

        Self {
            template_dir: env_str("TEMPLATE_DIR", "/templates"),
            cdn_domains_file: env_str("CDN_DOMAINS_FILE", "/data/cdn-domains.txt"),
            ssl_domains_file: env_str("SSL_DOMAINS_FILE", "/data/cdn-ssl-domains.txt"),
            standard_log,
            ssl_log,
            standard_cache_dir,
            ssl_cache_dir,
            dns_standard_state_dir: env_str("DNS_STANDARD_STATE_DIR", "/var/lib/powerdns-state"),
            dns_ssl_state_dir: env_str("DNS_SSL_STATE_DIR", "/var/lib/powerdns-state"),
            proxy_standard_url,
            proxy_ssl_url,
            netdata_url: env_str("NETDATA_URL", "http://netdata:19999"),
            dns_standard_service: env_str("DNS_STANDARD_SERVICE", "dns-standard"),
            dns_ssl_service: env_str("DNS_SSL_SERVICE", "dns-ssl"),
            proxy_ssl_service,
            ssl_enabled,
            standard_cache_max_gb: if cache_max_gb_set {
                shared_cache_max_gb
            } else {
                env_f64("STANDARD_CACHE_MAX_GB", shared_cache_max_gb)
            },
            ssl_cache_max_gb: if cache_max_gb_set {
                shared_cache_max_gb
            } else {
                env_f64("SSL_CACHE_MAX_GB", shared_cache_max_gb)
            },
            standard_ip: env_str("STANDARD_IP", "192.168.234.10"),
            ssl_ip: env_str("SSL_IP", "192.168.234.11"),
            dhcp_mode,
            dhcp_api_url,
            dhcp_api_token: env_str("DHCP_API_TOKEN", ""),
            auth_user: env_opt("UI_AUTH_USER"),
            auth_password: env_opt("UI_AUTH_PASSWORD"),
            allow_insecure_ui: env_bool("ALLOW_INSECURE_UI", false),
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
            nats_dns_reader_user: env_str("NATS_DNS_READER_USER", ""),
            nats_dns_reader_password: env_str("NATS_DNS_READER_PASSWORD", ""),
            secondary_registration_token: env_str("SECONDARY_REGISTRATION_TOKEN", ""),
            lancache_image_registry: env_str("LANCACHE_IMAGE_REGISTRY", "ghcr.io"),
            lancache_image_prefix: env_str("LANCACHE_IMAGE_PREFIX", "wiki-mod/lancache-ng"),
            lancache_image_channel,
            lancache_image_tag,
            nats_conf_path: env_str("NATS_CONF_PATH", "/etc/nats/nats.conf"),
            nats_service: env_str("NATS_SERVICE", "nats"),
            dev_mode: env_bool("LANCACHE_DEV_MODE", false),
        }
    }
}

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

fn env_or(key: &str, default: String) -> String {
    env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or(default)
}

fn env_opt(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
}

fn env_present(key: &str) -> bool {
    env::var(key)
        .ok()
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

fn env_f64(key: &str, default: f64) -> f64 {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
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

fn env_dhcp_mode(key: &str, legacy_enabled: bool) -> DhcpMode {
    let raw = env::var(key)
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    match raw.as_str() {
        "kea" => DhcpMode::Kea,
        "dnsmasq-proxy" => DhcpMode::DnsmasqProxy,
        "disabled" => DhcpMode::Disabled,
        "" if legacy_enabled => DhcpMode::Kea,
        _ => DhcpMode::Disabled,
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

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
    fn single_proxy_fallbacks_match_current_runtime_layout() {
        let _guard = env_test_lock().lock().unwrap();

        for key in [
            "PROXY_SERVICE",
            "PROXY_STANDARD_URL",
            "PROXY_SSL_URL",
            "PROXY_SSL_SERVICE",
            "SSL_ENABLED",
            "STANDARD_LOG",
            "SSL_LOG",
            "STANDARD_CACHE_DIR",
            "SSL_CACHE_DIR",
        ] {
            env::remove_var(key);
        }

        let cfg = Config::from_env();
        assert_eq!(cfg.proxy_standard_url, "http://proxy");
        assert_eq!(cfg.proxy_ssl_url, "http://proxy");
        assert_eq!(cfg.proxy_ssl_service, "proxy");
        assert!(cfg.ssl_enabled);
        assert_eq!(cfg.standard_log, "/var/log/nginx/access.log");
        assert_eq!(cfg.ssl_log, "/var/log/nginx/access.log");
        assert_eq!(cfg.standard_cache_dir, "/var/cache/proxy");
        assert_eq!(cfg.ssl_cache_dir, "/var/cache/proxy");
    }

    #[test]
    fn legacy_proxy_service_env_still_drives_runtime_fallbacks() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("PROXY_SERVICE", "legacy-proxy");
        env::remove_var("PROXY_STANDARD_URL");
        env::remove_var("PROXY_SSL_URL");
        env::remove_var("PROXY_SSL_SERVICE");

        let cfg = Config::from_env();
        assert_eq!(cfg.proxy_standard_url, "http://legacy-proxy");
        assert_eq!(cfg.proxy_ssl_url, "http://legacy-proxy");
        assert_eq!(cfg.proxy_ssl_service, "legacy-proxy");

        env::remove_var("PROXY_SERVICE");
    }

    #[test]
    fn ssl_enabled_accepts_disabled_env_values() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("SSL_ENABLED", "0");
        assert!(!Config::from_env().ssl_enabled);

        env::set_var("SSL_ENABLED", "false");
        assert!(!Config::from_env().ssl_enabled);

        env::remove_var("SSL_ENABLED");
        assert!(Config::from_env().ssl_enabled);
    }

    #[test]
    fn shared_cache_limit_env_wins_over_legacy_values() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("STANDARD_CACHE_MAX_GB", "77");
        env::set_var("SSL_CACHE_MAX_GB", "88");
        env::set_var("CACHE_MAX_GB", "42.5");

        let cfg = Config::from_env();
        assert_eq!(cfg.standard_cache_max_gb, 42.5);
        assert_eq!(cfg.ssl_cache_max_gb, 42.5);

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");
    }

    #[test]
    fn legacy_ssl_cache_limit_can_drive_shared_cache_fallback() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::set_var("SSL_CACHE_MAX_GB", "88");

        let cfg = Config::from_env();
        assert_eq!(cfg.standard_cache_max_gb, 88.0);
        assert_eq!(cfg.ssl_cache_max_gb, 88.0);

        env::remove_var("SSL_CACHE_MAX_GB");
    }

    #[test]
    fn shared_cache_limit_default_is_50_gb() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("CACHE_MAX_GB");
        env::remove_var("STANDARD_CACHE_MAX_GB");
        env::remove_var("SSL_CACHE_MAX_GB");

        let cfg = Config::from_env();
        assert_eq!(cfg.standard_cache_max_gb, 50.0);
        assert_eq!(cfg.ssl_cache_max_gb, 50.0);
    }

    #[test]
    fn lancache_image_tag_defaults_to_latest_and_accepts_release_tag() {
        let _guard = env_test_lock().lock().unwrap();

        env::remove_var("LANCACHE_IMAGE_REGISTRY");
        env::remove_var("LANCACHE_IMAGE_PREFIX");
        env::remove_var("LANCACHE_IMAGE_CHANNEL");
        env::remove_var("LANCACHE_IMAGE_TAG");
        let cfg = Config::from_env();
        assert_eq!(cfg.lancache_image_registry, "ghcr.io");
        assert_eq!(cfg.lancache_image_prefix, "wiki-mod/lancache-ng");
        assert_eq!(cfg.lancache_image_channel, "latest");
        assert_eq!(cfg.lancache_image_tag, "latest");

        env::set_var("LANCACHE_IMAGE_TAG", "sha-deadbeef");
        let cfg = Config::from_env();
        assert_eq!(cfg.lancache_image_channel, "pinned");
        assert_eq!(cfg.lancache_image_tag, "sha-deadbeef");

        env::set_var("LANCACHE_IMAGE_REGISTRY", "registry.example.test:5000");
        env::set_var("LANCACHE_IMAGE_PREFIX", "mirror/lancache-ng");
        env::set_var("LANCACHE_IMAGE_CHANNEL", "edge");
        env::set_var("LANCACHE_IMAGE_TAG", "v1.2.3");
        let cfg = Config::from_env();
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
            Config::from_env().dhcp_mode,
            DhcpMode::DnsmasqProxy
        ));

        env::set_var("DHCP_MODE", "kea");
        assert!(matches!(Config::from_env().dhcp_mode, DhcpMode::Kea));

        env::set_var("DHCP_MODE", "disabled");
        assert!(matches!(Config::from_env().dhcp_mode, DhcpMode::Disabled));

        env::set_var("DHCP_MODE", "invalid");
        assert!(matches!(Config::from_env().dhcp_mode, DhcpMode::Disabled));

        env::remove_var("DHCP_MODE");
    }

    #[test]
    fn dhcp_mode_defaults_from_legacy_enabled_flag() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("DHCP_ENABLED", "1");
        env::remove_var("DHCP_MODE");
        assert!(matches!(Config::from_env().dhcp_mode, DhcpMode::Kea));

        env::set_var("DHCP_ENABLED", "0");
        assert!(matches!(Config::from_env().dhcp_mode, DhcpMode::Disabled));

        env::remove_var("DHCP_ENABLED");
    }

    #[test]
    fn dhcp_api_url_is_disabled_for_non_kea_modes() {
        let _guard = env_test_lock().lock().unwrap();

        env::set_var("DHCP_MODE", "dnsmasq-proxy");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().dhcp_api_url, "");

        env::set_var("DHCP_MODE", "disabled");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().dhcp_api_url, "");

        env::set_var("DHCP_MODE", "kea");
        env::set_var("DHCP_API_URL", "http://dhcp:8000");
        assert_eq!(Config::from_env().dhcp_api_url, "http://dhcp:8000");

        env::remove_var("DHCP_MODE");
        env::remove_var("DHCP_API_URL");
    }
}
