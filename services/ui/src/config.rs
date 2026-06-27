use std::env;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HstsMode {
    Auto,
    Always,
    Never,
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
    pub proxy_standard_url: String,
    pub proxy_ssl_url: String,
    pub netdata_url: String,
    pub dns_standard_service: String,
    pub dns_ssl_service: String,
    pub proxy_ssl_service: String,
    pub standard_cache_max_gb: f64,
    pub ssl_cache_max_gb: f64,
    pub standard_ip: String,
    pub ssl_ip: String,
    pub dhcp_api_url: String,
    pub dhcp_api_token: String,
    pub auth_user: Option<String>,
    pub auth_password: Option<String>,
    pub security_headers_enabled: bool,
    pub hsts_mode: HstsMode,
    pub pdns_auth_url: String,
    pub pdns_rec_url: String,
    pub pdns_api_key: String,
    pub nats_url: String,
    pub nats_local_token: String,
    pub secondary_registration_token: String,
    pub nats_conf_path: String,
    pub nats_service: String,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            template_dir: env_str("TEMPLATE_DIR", "/templates"),
            cdn_domains_file: env_str("CDN_DOMAINS_FILE", "/data/cdn-domains.txt"),
            ssl_domains_file: env_str("SSL_DOMAINS_FILE", "/data/cdn-ssl-domains.txt"),
            standard_log: env_str("STANDARD_LOG", "/var/log/nginx/standard/access.log"),
            ssl_log: env_str("SSL_LOG", "/var/log/nginx/ssl/access.log"),
            standard_cache_dir: env_str("STANDARD_CACHE_DIR", "/var/cache/standard"),
            ssl_cache_dir: env_str("SSL_CACHE_DIR", "/var/cache/ssl"),
            proxy_standard_url: env_str("PROXY_STANDARD_URL", "http://proxy-standard"),
            proxy_ssl_url: env_str("PROXY_SSL_URL", "http://proxy-ssl"),
            netdata_url: env_str("NETDATA_URL", "http://netdata:19999"),
            dns_standard_service: env_str("DNS_STANDARD_SERVICE", "dns-standard"),
            dns_ssl_service: env_str("DNS_SSL_SERVICE", "dns-ssl"),
            proxy_ssl_service: env_str("PROXY_SSL_SERVICE", "proxy-ssl"),
            standard_cache_max_gb: env_f64("STANDARD_CACHE_MAX_GB", 10.0),
            ssl_cache_max_gb: env_f64("SSL_CACHE_MAX_GB", 10.0),
            standard_ip: env_str("STANDARD_IP", "192.168.234.10"),
            ssl_ip: env_str("SSL_IP", "192.168.234.11"),
            dhcp_api_url: env_str("DHCP_API_URL", "http://localhost:8000"),
            dhcp_api_token: env_str("DHCP_API_TOKEN", ""),
            auth_user: env_opt("UI_AUTH_USER"),
            auth_password: env_opt("UI_AUTH_PASSWORD"),
            security_headers_enabled: env_bool("UI_SECURITY_HEADERS", true),
            hsts_mode: env_hsts_mode("UI_HSTS_MODE", HstsMode::Auto),
            pdns_auth_url: env_str("PDNS_AUTH_URL", "http://dns-standard:8081"),
            pdns_rec_url: env_str("PDNS_REC_URL", "http://dns-standard:8082"),
            pdns_api_key: env_str("PDNS_API_KEY", ""),
            nats_url: env_str("NATS_URL", "nats://nats:4222"),
            nats_local_token: env_str("NATS_LOCAL_TOKEN", ""),
            secondary_registration_token: env_str("SECONDARY_REGISTRATION_TOKEN", ""),
            nats_conf_path: env_str("NATS_CONF_PATH", "/etc/nats/nats.conf"),
            nats_service: env_str("NATS_SERVICE", "nats"),
        }
    }
}

fn env_str(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_opt(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
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
