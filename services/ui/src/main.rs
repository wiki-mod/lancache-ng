//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: the Admin UI server, one-shot modes and clients.
//! Why: one binary serves pages and drives NATS/Kea.
//! From: Issue #1683 | PR #1858

#![deny(warnings)]

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::Router;
use axum::body::{Body, Bytes, to_bytes};
use axum::extract::{Form, Path as AxPath, Query, Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, header};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Json, Redirect, Response};
use axum::routing::{MethodRouter, delete, get, post};
use base64::Engine as _;
use futures_util::StreamExt as _;
use lancache_ng::config::{
    self, AAAA_FILTER_MARKER, DDNS_UNSIGNED_MARKER, DEFAULT_RECORD_TTL, DhcpMode,
    KEA_MANAGED_CODES, LeaseLimits, NATS_SUBJECT_FLUSH, NATS_SUBJECT_RECORD, NatsLogin, NatsRoles,
    OPTION_CODE_MAX, OPTION_CODE_MIN, OutOfRange, PDNS_API_PATH, PROXY_ACCESS_LOG_PATTERN, Uint,
    canonical_zone, dns_reader_publish, dns_subscribe, is_dns_name, option_code, option_data,
    parse_bool, parse_custom_options, reverse_zones, zone_url,
};
use lancache_ng::{
    ALARM_INGEST_PATH, ALARM_TOKEN_HEADER, Backoff, DesiredRunState, DesiredState, DnsRecord,
    FlushRequest, NetdataAlarm, Place, PowerDns, ProbeAnswer, ProbeReport, SnapshotStore,
    WatchdogStatus, ct_eq, df, die, error_chain, files_under, hex32, http_client, is_placeholder,
    load_or_create, load_or_create_hex, need_secs, own, probe_health, resolve_shared_secret,
    shared_secret, shared_secret_file_name, snapshot_created_unix, unix_secs, write_file,
    write_if_changed,
};
use nkeys::{KeyPair, XKey};
use regex::Regex;
use rusqlite::{Connection, OptionalExtension as _};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256, Sha512_256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use tera::{Context, Tera};
use tracing_subscriber::layer::SubscriberExt as _;
use tracing_subscriber::util::SubscriberInitExt as _;

// What: UI-settings keys, in the order the file lists them.
// Why: every save rewrites the file; setup.sh reads it.
// From: Issue #819
const SETTING_KEYS: [&str; 19] = [
    "DHCP_MODE",
    "DHCP_SUBNET_START",
    "DHCP_DNS_PRIMARY",
    "DHCP_DNS_SECONDARY",
    "UPSTREAM_DHCP_IP",
    "DHCP_RELAY_LOCAL_ADDR",
    "DHCP_NTP_SERVERS",
    "DHCP_PROXY_INTERFACE",
    "DHCP_PROXY_ROUTER",
    "DHCP_PROXY_DOMAIN",
    "DHCP_PROXY_BOOT_FILENAME",
    "DHCP_PROXY_BOOT_SERVER",
    "DHCP_PROXY_CUSTOM_OPTIONS",
    "LANCACHE_IMAGE_CHANNEL",
    "AUTO_UPDATE_ENABLED",
    "NTP_ENABLED",
    "NTP_UPSTREAM_SERVERS",
    "NTP_AUTO_DHCP",
    "CACHE_MAX_GB",
];

// What: shared-secret variables the ui reads or creates.
// Why: one inventory for the root start and the reader.
// From: Issue #858
const SHARED_SECRET_VARS: [&str; 7] = [
    "PDNS_API_KEY",
    "NETDATA_ALARM_TOKEN",
    "KEA_CTRL_TOKEN",
    "NATS_UI_PASSWORD",
    "NATS_DNS_WRITER_PASSWORD",
    "NATS_CALLOUT_PASSWORD",
    "NATS_SYS_PASSWORD",
];

// What: when the ui sends Strict-Transport-Security.
// Why: plain-HTTP installs must never get an HSTS header.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HstsMode {
    Auto,
    Always,
    Never,
}

impl HstsMode {
    // What: send HSTS for this request or not.
    // Why: Auto follows the request scheme; others force.
    fn should_send(self, is_https: bool) -> bool {
        match self {
            Self::Auto => is_https,
            Self::Always => true,
            Self::Never => false,
        }
    }
}

// What: every startup value of the ui, read once.
// Why: no Debug impl, so no log line can print a secret.
struct Config {
    template_dir: String,
    cdn_domains_file: String,
    // What: the proxy's syslog-ng directory.
    // Why: nginx logs to stdout; syslog-ng stores it.
    proxy_log_dir: String,
    // What: the local DNS zone name, from DHCP_DOMAIN.
    // Why: the SOT owns it; the ui holds no literal.
    lan_zone: String,
    // What: the UDP port the NTP server answers on.
    // Why: the ntp page names it; the SOT owns it.
    ntp_port: String,
    // What: where a secondary host fetches setup.sh.
    // Why: the SOT owns host and path; the page prints it.
    setup_script_url: String,
    // What: the repository address the pages link to.
    // Why: the SOT owns it; templates hold no address.
    repo_url: String,
    // What: refresh timings, chart points, timer minutes.
    // Why: the SOT owns them; templates hold no number.
    page_numbers: [(&'static str, u64); 5],
    // What: the syslog program of each logging switch.
    // Why: same order as LOG_SWITCHES; the SOT names each.
    log_programs: Vec<String>,
    cache_dir: String,
    dns_state_dir: String,
    shared_secret_dir: String,
    proxy_status_url: String,
    netdata_url: String,
    https_enabled: bool,
    cache_max_gb: f64,
    // What: the lease seconds a subnet without one shows.
    // Why: the SOT owns DHCP_LEASE_TIME; no copy in Rust.
    dhcp_lease_time: u32,
    // What: lease limits of the subnet form and Kea.
    // Why: the SOT owns them; watchdog applies the same.
    dhcp_lease_limits: LeaseLimits,
    http_ip: String,
    https_ip: String,
    pdns_auth_port: u16,
    retry_backoff: Backoff,
    dns_port: u16,
    dhcp_api_url: String,
    dhcp_api_token: String,
    dhcp_api_user: String,
    ui_settings_file: String,
    startup_settings: HashMap<&'static str, String>,
    kea_config_snapshot_dir: String,
    dhcp_probe_request_file: String,
    dhcp_probe_result_file: String,
    kea_keep_known_good_configs: u32,
    auth_user: Option<String>,
    auth_password_hash: Option<String>,
    allow_insecure_ui: bool,
    ui_session_ttl_seconds: u64,
    watchdog_miss_limit: u32,
    security_headers_enabled: bool,
    hsts_mode: HstsMode,
    ui_logs_max_entries: usize,
    pdns_auth_api: String,
    pdns_rec_api: String,
    dns_rollback_url: String,
    pdns_api_key: String,
    netdata_alarm_token: String,
    netdata_alarms_file: String,
    nats_url: String,
    advertised_nats_url: Option<String>,
    nats: NatsRoles,
    nats_issuer_seed_path: String,
    nats_issuer_seed: Option<String>,
    nats_xkey_seed_path: String,
    nats_xkey_seed: Option<String>,
    secondary_registration_token: String,
    lancache_image_registry: String,
    lancache_image_prefix: String,
    lancache_image_channel: String,
    lancache_image_tag: String,
    nats_auth_callout_path: String,
    // What: where the session secret persists.
    // Why: a recreate must not invalidate open sessions.
    // From: Issue #1683 | PR #1858
    session_secret_file: String,
    // What: the SQLite file of the secondary nodes.
    // Why: runtime state stays in the backing services.
    database_file: String,
    // What: where a generated registration token persists.
    // Why: a restart must not rotate secondaries' token.
    registration_token_file: String,
    // What: TCP port the server binds inside the container.
    // Why: Dockerfile owns it; the primary URL reuses it.
    listen_port: u16,
    // What: the stack CA file name shown for clients.
    // Why: the SOT owns it; the setup page names it.
    ca_cert_file: String,
    // What: the server's bind address, every interface.
    // Why: the SOT owns it as ANY_BIND_IP; no literal.
    any_bind: String,
    dev_mode: bool,
    syslog_log_root: String,
    syslog_max_gb: u32,
    watchdog_status_file: String,
    desired_state_file: String,
}

impl Config {
    // What: the config from the process environment.
    // Why: tests pass their own reader to load instead.
    fn from_env() -> Result<Self, String> {
        Self::load(&config::process_env)
    }

    // What: build the config from any variable reader.
    // Why: a reader closure makes every default observable.
    fn load(env: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        let set = |key: &str| config::opt(env, key);
        let text = |key: &str, default: &str| set(key).unwrap_or_else(|| default.to_string());
        // What: a compose value; unset stops startup.
        // Why: compose owns it; Rust keeps no default.
        let need = |key: &str| config::need(env, key);
        // What: a compose bool; junk stops startup.
        // Why: as for need; a typo must not flip a gate.
        let need_flag = |key: &str| config::need_flag(env, key);
        // What: the dns container's URL plus one SOT port.
        // Why: compose names the host; the SOT owns ports.
        // From: Issue #1683 | PR #1912
        let dns_api = |port_key: &str| -> Result<String, String> {
            Ok(format!("{}:{}", need("DNS_URL")?, need(port_key)?))
        };
        // What: a compose number of 1 or more; junk stops.
        // Why: as for need; the SOT owns the value.
        let number = |key: &'static str| config::uint(env, key, 1, u64::MAX);
        let read = |spec: Uint| -> Result<u64, String> {
            let (value, warning) = spec.parse(env(spec.name).as_deref())?;
            if let Some(warning) = warning {
                eprintln!("[lancache-ui] {warning}");
            }
            Ok(value)
        };
        let knob = |name: &'static str, max: u64, above: OutOfRange| {
            read(Uint {
                name,
                min: 1,
                max,
                below: OutOfRange::Reject,
                above,
            })
        };

        // What: both proxy addresses come from compose.
        // Why: no LAN address is hardcoded (AG-SEC-007).
        let http_ip = need("IP_HTTP")?;
        let https_ip = need("IP_HTTPS")?;
        let nats_url = need("NATS_URL")?;
        let tag = need("LANCACHE_IMAGE_TAG")?;
        let channel = set("LANCACHE_IMAGE_CHANNEL")
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| derive_image_channel(&tag));
        let cache_max_gb = cache_max_gb_from(env)?;
        let dhcp_mode = DhcpMode::parse(&env("DHCP_MODE").unwrap_or_default());
        let secret_dir = need("LANCACHE_SHARED_SECRET_DIR")?;
        let secret = |var: &str| shared_secret(&secret_dir, var, env);
        let login = |user_key: &str, password_key: &str| -> Result<NatsLogin, String> {
            Ok(NatsLogin {
                user: text(user_key, ""),
                password: Some(secret(password_key)?).filter(|p| !p.is_empty()),
            })
        };
        // What: a DHCP DNS key or its shared fallback.
        // Why: config::dhcp_dns_fallback owns the rule.
        let dhcp_dns = |key: &str| {
            set(key)
                .or_else(|| config::dhcp_dns_fallback(env, key))
                .unwrap_or_default()
        };
        let dhcp_api_token = match env("DHCP_API_TOKEN") {
            Some(v) if !is_placeholder(&v) => v,
            _ => secret("KEA_CTRL_TOKEN")?,
        };
        let dhcp_lease_limits = LeaseLimits::load(env)?;
        let dhcp_lease_time = dhcp_lease_limits.lease(env, "DHCP_LEASE_TIME")?;
        let ttl_max = config::uint(env, "UI_SESSION_TTL_MAX_SECONDS", 1, u64::MAX)?;
        let ttl = knob("UI_SESSION_TTL_SECONDS", ttl_max, OutOfRange::Reject)?;
        let startup_settings = HashMap::from([
            ("DHCP_MODE", dhcp_mode.as_str().to_string()),
            ("DHCP_SUBNET_START", text("DHCP_SUBNET_START", "")),
            ("DHCP_DNS_PRIMARY", dhcp_dns("DHCP_DNS_PRIMARY")),
            ("DHCP_DNS_SECONDARY", dhcp_dns("DHCP_DNS_SECONDARY")),
            ("UPSTREAM_DHCP_IP", text("UPSTREAM_DHCP_IP", "")),
            ("DHCP_RELAY_LOCAL_ADDR", text("DHCP_RELAY_LOCAL_ADDR", "")),
            ("DHCP_NTP_SERVERS", text("DHCP_NTP_SERVERS", "")),
            ("DHCP_PROXY_INTERFACE", text("DHCP_PROXY_INTERFACE", "")),
            ("DHCP_PROXY_ROUTER", text("DHCP_PROXY_ROUTER", "")),
            ("DHCP_PROXY_DOMAIN", text("DHCP_PROXY_DOMAIN", "")),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                text("DHCP_PROXY_BOOT_FILENAME", ""),
            ),
            ("DHCP_PROXY_BOOT_SERVER", text("DHCP_PROXY_BOOT_SERVER", "")),
            (
                "DHCP_PROXY_CUSTOM_OPTIONS",
                text("DHCP_PROXY_CUSTOM_OPTIONS", ""),
            ),
            ("LANCACHE_IMAGE_CHANNEL", channel.clone()),
            // What: switches; SOT default is in the image.
            // Why: no Rust fallback; no typo flips one.
            // From: Issue #1683 | PR #1912
            (
                "AUTO_UPDATE_ENABLED",
                bool_text(need_flag("AUTO_UPDATE_ENABLED")?),
            ),
            ("NTP_ENABLED", bool_text(need_flag("NTP_ENABLED")?)),
            ("NTP_UPSTREAM_SERVERS", need("NTP_UPSTREAM_SERVERS")?),
            ("NTP_AUTO_DHCP", bool_text(need_flag("NTP_AUTO_DHCP")?)),
            ("CACHE_MAX_GB", cache_max_gb.to_string()),
        ]);
        // What: the logging switches, from the strict env.
        // Why: the SOT owns the default; no typo may flip.
        // From: Issue #1683 | PR #1912
        let mut startup_settings = startup_settings;
        let mut log_programs = Vec::new();
        for (key, program_key) in config::LOG_SWITCHES {
            startup_settings.insert(key, bool_text(need_flag(key)?));
            log_programs.push(need(program_key)?);
        }
        let proxy_log_dir = config::proxy_log_dir(env)?;

        Ok(Self {
            template_dir: need("TEMPLATE_DIR")?,
            shared_secret_dir: secret_dir.clone(),
            cdn_domains_file: need("CDN_DOMAINS_FILE")?,
            proxy_log_dir,
            lan_zone: config::lan_zone(env)?,
            ntp_port: need("NTP_PORT")?,
            setup_script_url: format!(
                "{}/{}",
                need("RAW_CONTENT_URL")?,
                need("SETUP_SCRIPT_PATH")?
            ),
            repo_url: need("LANCACHE_REPO_URL")?,
            page_numbers: [
                ("watchdog_refresh_ms", number("UI_WATCHDOG_REFRESH_MS")?),
                ("dashboard_refresh_ms", number("UI_DASHBOARD_REFRESH_MS")?),
                ("stats_refresh_ms", number("UI_STATS_REFRESH_MS")?),
                ("stats_points", number("UI_STATS_POINTS")?),
                (
                    "converge_minutes",
                    number("CONVERGE_TIMER_INTERVAL_MINUTES")?,
                ),
            ],
            log_programs,
            cache_dir: need("CACHE_DIR")?,
            dns_state_dir: need("DNS_STATE_DIR")?,
            proxy_status_url: need("PROXY_STATUS_URL")?,
            netdata_url: need("NETDATA_URL")?,
            https_enabled: need_flag("HTTPS_ENABLED")?,
            cache_max_gb,
            dhcp_lease_time,
            dhcp_lease_limits,
            http_ip,
            https_ip,
            pdns_auth_port: config::port(env, "PDNS_AUTH_PORT")?,
            retry_backoff: Backoff::load(env)?,
            dns_port: config::port(env, "DNS_PORT")?,
            dhcp_api_url: format!(
                "http://{}:{}",
                need("DHCP_API_HOST")?,
                need("KEA_CTRL_PORT")?
            ),
            dhcp_api_token,
            dhcp_api_user: need("KEA_CTRL_USER")?,
            ui_settings_file: need("UI_SETTINGS_FILE")?,
            startup_settings,
            kea_config_snapshot_dir: need("KEA_CONFIG_SNAPSHOT_DIR")?,
            dhcp_probe_request_file: need("DHCP_PROBE_REQUEST_FILE")?,
            dhcp_probe_result_file: need("DHCP_PROBE_RESULT_FILE")?,
            kea_keep_known_good_configs: config::keep_known_good(env)?,
            auth_user: set("UI_AUTH_USER"),
            auth_password_hash: set("UI_AUTH_PASSWORD_HASH")
                .map(|v| decode_password_hash(&v))
                .transpose()?,
            allow_insecure_ui: need_flag("ALLOW_INSECURE_UI")?,
            ui_session_ttl_seconds: ttl,
            // What: missed watchdog cycles before stale.
            // Why: one owner with the restart rule.
            watchdog_miss_limit: knob("RESTART_AFTER", u32::MAX.into(), OutOfRange::Reject)? as u32,
            // What: security headers switch; unset fails.
            // Why: compose owns the value; no Rust default.
            security_headers_enabled: need_flag("UI_SECURITY_HEADERS")?,
            hsts_mode: hsts_mode_from(&text("UI_HSTS_MODE", "")),
            ui_logs_max_entries: knob("UI_LOGS_MAX_ENTRIES", u64::MAX, OutOfRange::Reject)?
                as usize,
            pdns_auth_api: format!("{}{PDNS_API_PATH}", dns_api("PDNS_AUTH_API_PORT")?),
            pdns_rec_api: format!("{}{PDNS_API_PATH}", dns_api("PDNS_HTTP_API_PORT")?),
            dns_rollback_url: dns_api("DNS_ROLLBACK_PORT")?,
            pdns_api_key: secret("PDNS_API_KEY")?,
            netdata_alarm_token: secret("NETDATA_ALARM_TOKEN")?,
            netdata_alarms_file: need("NETDATA_ALARMS_FILE")?,
            nats_url: nats_url.clone(),
            advertised_nats_url: advertised_nats_url(
                &text("NATS_ADVERTISE_URL", ""),
                &text("NATS_BIND_IP", ""),
                &nats_url,
            ),
            nats: NatsRoles::read(&login)?,
            nats_issuer_seed_path: need("NATS_ISSUER_SEED_PATH")?,
            nats_issuer_seed: set("NATS_ISSUER_SEED"),
            nats_xkey_seed_path: need("NATS_XKEY_SEED_PATH")?,
            nats_xkey_seed: set("NATS_XKEY_SEED"),
            secondary_registration_token: text("SECONDARY_REGISTRATION_TOKEN", ""),
            lancache_image_registry: need("LANCACHE_IMAGE_REGISTRY")?,
            lancache_image_prefix: need("LANCACHE_IMAGE_PREFIX")?,
            lancache_image_channel: channel,
            lancache_image_tag: tag,
            nats_auth_callout_path: need("NATS_AUTH_CALLOUT_PATH")?,
            session_secret_file: need("UI_SESSION_SECRET_FILE")?,
            database_file: need("UI_DATABASE_FILE")?,
            registration_token_file: need("SECONDARY_REGISTRATION_TOKEN_FILE")?,
            listen_port: knob("UI_LISTEN_PORT", u16::MAX.into(), OutOfRange::Reject)? as u16,
            any_bind: config::any_bind(env)?,
            ca_cert_file: need("CA_CERT_FILE")?,
            // What: switch for dev mode; unset stops start.
            // Why: compose owns the value; no Rust default.
            dev_mode: need_flag("LANCACHE_DEV_MODE")?,
            syslog_log_root: need("SYSLOG_LOG_ROOT")?,
            syslog_max_gb: read(config::SYSLOG_MAX_GB)? as u32,
            watchdog_status_file: need("STATUS_FILE")?,
            desired_state_file: need("DESIRED_STATE_FILE")?,
        })
    }

    // What: a setting; the saved value beats startup's.
    // Why: operators change settings live, no restart.
    fn setting(&self, key: &str) -> String {
        config::saved_setting(Path::new(&self.ui_settings_file), key)
            .unwrap_or_else(|| self.startup_settings.get(key).cloned().unwrap_or_default())
    }

    // What: a setting stored as 1 for on.
    // Why: the file and setup.sh share the 1/0 spelling.
    fn flag(&self, key: &str) -> bool {
        self.setting(key).trim() == "1"
    }

    // What: the DHCP mode in effect now.
    // Why: the saved mode has no legacy flag fallback.
    fn dhcp_mode(&self) -> DhcpMode {
        DhcpMode::parse(&self.setting("DHCP_MODE"))
    }

    // What: the cache size an operator requested, in GB.
    // Why: differs from cache_max_gb until proxy recreate.
    fn requested_cache_gb(&self) -> f64 {
        self.setting("CACHE_MAX_GB")
            .trim()
            .parse()
            .unwrap_or(self.cache_max_gb)
    }

    // What: save changed values; keep other saved keys.
    // Why: no env value or SOT default enters the file.
    // From: Issue #1683 | PR #1912
    fn save_settings(&self, changes: &[(&str, String)]) -> io::Result<()> {
        let mut content = String::new();
        let file = Path::new(&self.ui_settings_file);
        let log_keys = config::LOG_SWITCHES.iter().map(|(key, _)| *key);
        for key in SETTING_KEYS.into_iter().chain(log_keys) {
            let value = match changes.iter().find(|(name, _)| *name == key) {
                Some((_, value)) => value.clone(),
                None => config::saved_setting(file, key).unwrap_or_default(),
            };
            if !value.trim().is_empty() {
                content.push_str(&format!("{key}={}\n", value.trim()));
            }
        }
        write_file(file, content.as_bytes(), 0o644, Place::Replace)
    }
}

// What: 1 or 0 for a bool.
// Why: the settings file stores flags this way.
fn bool_text(value: bool) -> String {
    if value { "1" } else { "0" }.to_string()
}

// What: the channel an image tag belongs to, for display.
// Why: no aliases; an edge tag shows as latest.
// From: Issue #1056
fn derive_image_channel(tag: &str) -> String {
    let pinned = tag.starts_with("sha-")
        || tag
            .strip_prefix('v')
            .and_then(|rest| rest.chars().next())
            .is_some_and(|c| c.is_ascii_digit());
    match tag {
        "dev" | "nightly" | "latest" => tag.to_string(),
        _ if pinned => "pinned".to_string(),
        _ => "latest".to_string(),
    }
}

// What: HSTS mode from text; always, never, or a boolean.
// Why: booleans parse as config::parse_bool; else auto.
fn hsts_mode_from(raw: &str) -> HstsMode {
    match raw.trim().to_ascii_lowercase().as_str() {
        "always" => HstsMode::Always,
        "never" => HstsMode::Never,
        other => match parse_bool(other) {
            Some(true) => HstsMode::Always,
            Some(false) => HstsMode::Never,
            None => HstsMode::Auto,
        },
    }
}

// What: CACHE_MAX_GB, else CACHE_MAX_SIZE in GB.
// Why: the SOT owns the size; a bad value must fail.
fn cache_max_gb_from(env: &dyn Fn(&str) -> Option<String>) -> Result<f64, String> {
    match config::opt(env, "CACHE_MAX_GB") {
        Some(raw) => raw
            .trim()
            .parse::<f64>()
            .ok()
            .filter(|gb| gb.is_finite() && *gb >= 0.0)
            .ok_or_else(|| format!("CACHE_MAX_GB must be a number of gigabytes, got {raw:?}")),
        None => {
            let size = config::need(env, "CACHE_MAX_SIZE")?;
            let size = size.trim();
            let (digits, per_gb) = if let Some(n) = size.strip_suffix(['g', 'G']) {
                (n, 1.0)
            } else if let Some(n) = size.strip_suffix(['m', 'M']) {
                (n, 1024.0)
            } else if let Some(n) = size.strip_suffix(['t', 'T']) {
                (n, 1.0 / 1024.0)
            } else {
                return Err(format!(
                    "CACHE_MAX_SIZE must end in m, g or t, got {size:?}"
                ));
            };
            digits
                .parse::<f64>()
                .ok()
                .filter(|n| n.is_finite() && *n >= 0.0)
                .map(|n| n / per_gb)
                .ok_or_else(|| format!("CACHE_MAX_SIZE must be a number and a unit, got {size:?}"))
        }
    }
}

// What: the NATS URL a remote secondary can dial, or None.
// Why: an unreachable internal URL must not be handed out.
// From: Issue #866
fn advertised_nats_url(explicit: &str, bind_ip: &str, nats_url: &str) -> Option<String> {
    let explicit = explicit.trim();
    if !explicit.is_empty() {
        return Some(explicit.to_string());
    }
    let bind_ip = bind_ip.trim();
    let bare = bind_ip
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(bind_ip);
    match bare.parse::<IpAddr>().ok()? {
        ip if ip.is_unspecified() || ip.is_loopback() => None,
        IpAddr::V6(v6) => Some(format!("nats://[{v6}]:{}", nats_port(nats_url)?)),
        IpAddr::V4(v4) => Some(format!("nats://{v4}:{}", nats_port(nats_url)?)),
    }
}

// What: the port of the NATS URL the ui connects to.
// Why: NATS_URL owns the port; the advertise URL reuses it.
fn nats_port(nats_url: &str) -> Option<&str> {
    let (_, port) = nats_url.trim_end_matches('/').rsplit_once(':')?;
    (!port.is_empty() && port.bytes().all(|b| b.is_ascii_digit())).then_some(port)
}

// What: read-or-create the secret files named by a prefix.
// Why: each starter makes only its own; "" means all.
// From: Issue #858
fn ensure_shared_secrets(dir: &str, gid: u32, prefix: &str) -> Result<(), String> {
    for var in SHARED_SECRET_VARS.iter().filter(|v| v.starts_with(prefix)) {
        let configured = config::env_opt(var).unwrap_or_default();
        let current = if is_placeholder(&configured) {
            ""
        } else {
            configured.as_str()
        };
        resolve_shared_secret(
            Path::new(dir),
            &shared_secret_file_name(var),
            current,
            gid,
            hex32,
        )
        .map_err(|e| format!("{var}: {e}"))?;
    }
    Ok(())
}

// What: names and limits of CSRF and the session cookie.
// Why: one spelling for the middleware and its callers.
const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;
const SESSION_COOKIE_NAME: &str = "lancache_ui_session";
const INTERNAL_CSRF_HEADER: &str = "x-lancache-ui-csrf-token";

// What: the templates the ui loads at startup.
// Why: a template missing here fails every render of it.
const TEMPLATE_NAMES: &[&str] = &[
    "base.html",
    "dashboard.html",
    "dhcp.html",
    "domains.html",
    "ntp.html",
    "secondaries.html",
    "stats.html",
    "logs.html",
    "setup.html",
];

// What: the content security policy of every page.
// Why: templates use inline handlers, so those are allowed.
const ADMIN_UI_CSP: &str = "default-src 'self'; base-uri 'self'; object-src 'none'; \
     frame-ancestors 'none'; form-action 'self'; script-src 'self' 'unsafe-inline'; \
     style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; \
     font-src 'self' data:";

// What: everything the handlers share.
// Why: one state value behind an Arc serves all requests.
struct AppState {
    templates: Tera,
    config: Config,
    http_client: reqwest::Client,
    pdns: PowerDns,
    file_lock: Mutex<()>,
    netdata_alarms_lock: Mutex<()>,
    kea_config_lock: tokio::sync::Mutex<()>,
    dhcp_probe_lock: tokio::sync::Mutex<()>,
    nats: async_nats::Client,
    db: Mutex<Connection>,
    ui_session_secret: [u8; 32],
    ui_session_ttl: Duration,
}

impl AppState {
    // What: state from its inputs; locks start free.
    // Why: one owner for the server and the test server.
    // From: Issue #1683 | PR #1912
    fn new(
        config: Config,
        http_client: reqwest::Client,
        nats: async_nats::Client,
        db: Connection,
        ui_session_secret: [u8; 32],
        ui_session_ttl: Duration,
    ) -> Self {
        Self {
            templates: load_templates(&config),
            pdns: PowerDns::new(http_client.clone(), config.pdns_api_key.clone()),
            http_client,
            file_lock: Mutex::new(()),
            netdata_alarms_lock: Mutex::new(()),
            kea_config_lock: tokio::sync::Mutex::new(()),
            dhcp_probe_lock: tokio::sync::Mutex::new(()),
            nats,
            db: Mutex::new(db),
            ui_session_secret,
            ui_session_ttl,
            config,
        }
    }
}

// What: handler state extractor over the shared AppState.
// Why: every handler takes the same Arc-wrapped state.
type Shared = State<Arc<AppState>>;

// What: a submitted form as text values by field name.
// Why: every form handler reads text and numbers alike.
#[derive(Deserialize)]
#[serde(transparent)]
struct Fields(HashMap<String, String>);

impl Fields {
    // What: one field trimmed; an absent one reads empty.
    // Why: handlers validate emptiness, never absence.
    fn get(&self, key: &str) -> &str {
        self.0.get(key).map_or("", |value| value.trim())
    }

    // What: one field parsed as a number.
    // Why: a malformed number fails like a missing one.
    fn number<T: FromStr>(&self, key: &str) -> Option<T> {
        self.get(key).parse().ok()
    }
}

// What: one browser session's CSRF token and cookie value.
// Why: the cookie only binds a CSRF token, never logs in.
struct Session {
    csrf_token: String,
    cookie_value: String,
}

// What: HMAC-SHA256 of a payload, by hand.
// Why: the hmac crate is not a workspace dependency.
fn hmac_sha256(secret: &[u8; 32], payload: &[u8]) -> [u8; 32] {
    let mut inner_pad = [0x36u8; 64];
    let mut outer_pad = [0x5cu8; 64];
    for (i, byte) in secret.iter().enumerate() {
        inner_pad[i] ^= byte;
        outer_pad[i] ^= byte;
    }
    let inner = Sha256::new()
        .chain_update(inner_pad)
        .chain_update(payload)
        .finalize();
    Sha256::new()
        .chain_update(outer_pad)
        .chain_update(inner)
        .finalize()
        .into()
}

// What: the signature of a cookie's expiry and CSRF token.
// Why: a forged or edited cookie must not validate.
fn cookie_signature(secret: &[u8; 32], expires: u64, csrf_token: &str) -> String {
    hex::encode(hmac_sha256(
        secret,
        format!("v1.{expires}.{csrf_token}").as_bytes(),
    ))
}

// What: a fresh session valid for ttl.
// Why: every first request gets its own random CSRF token.
fn issue_session(secret: &[u8; 32], ttl: Duration) -> Session {
    let csrf_token = hex32();
    let expires = unix_secs() + ttl.as_secs();
    let signature = cookie_signature(secret, expires, &csrf_token);
    Session {
        cookie_value: format!("v1.{expires}.{csrf_token}.{signature}"),
        csrf_token,
    }
}

// What: the session a cookie value proves, if any.
// Why: expired, edited or foreign cookies get a new one.
fn validate_session(cookie_value: &str, secret: &[u8; 32]) -> Option<Session> {
    let parts: Vec<&str> = cookie_value.split('.').collect();
    let [version, expires, csrf_token, signature] = parts.as_slice() else {
        return None;
    };
    let expires: u64 = expires.parse().ok()?;
    let now = unix_secs();
    let valid = *version == "v1"
        && now != 0
        && now < expires
        && ct_eq(signature, &cookie_signature(secret, expires, csrf_token));
    valid.then(|| Session {
        csrf_token: csrf_token.to_string(),
        cookie_value: cookie_value.to_string(),
    })
}

// What: the session cookie from request headers.
// Why: other cookies on the origin must be ignored.
fn session_cookie(headers: &HeaderMap) -> Option<&str> {
    let prefix = format!("{SESSION_COOKIE_NAME}=");
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|cookie| cookie.trim().strip_prefix(&prefix))
}

// What: attach the session cookie to a response.
// Why: SameSite=Strict and HttpOnly keep scripts out.
fn attach_session_cookie(response: &mut Response, session: &Session, ttl: Duration, secure: bool) {
    let secure = if secure { "; Secure" } else { "" };
    let cookie = format!(
        "{SESSION_COOKIE_NAME}={}; Path=/; SameSite=Strict; HttpOnly; Max-Age={}{secure}",
        session.cookie_value,
        ttl.as_secs()
    );
    match HeaderValue::from_str(&cookie) {
        Ok(value) => {
            response.headers_mut().insert(header::SET_COOKIE, value);
        }
        Err(err) => tracing::error!(error = %err, "failed to build session cookie header"),
    }
}

// What: true when the request came in over HTTPS.
// Why: only a TLS-terminating proxy in front sets it.
fn forwarded_proto_is_https(headers: &HeaderMap) -> bool {
    headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .is_some_and(|proto| proto.trim().eq_ignore_ascii_case("https"))
}

// What: security headers on every response.
// Why: the policy is default-on and optional for debugging.
async fn security_headers(State(state): Shared, req: Request, next: Next) -> Response {
    let is_https = forwarded_proto_is_https(req.headers());
    let mut response = next.run(req).await;
    if !state.config.security_headers_enabled {
        return response;
    }
    let headers = response.headers_mut();
    let mut set = |name: &'static str, value: &'static str| {
        headers.insert(
            HeaderName::from_static(name),
            HeaderValue::from_static(value),
        );
    };
    set("content-security-policy", ADMIN_UI_CSP);
    set("x-content-type-options", "nosniff");
    set("x-frame-options", "DENY");
    set("referrer-policy", "no-referrer");
    if state.config.hsts_mode.should_send(is_https) {
        set(
            "strict-transport-security",
            "max-age=31536000; includeSubDomains",
        );
    }
    response
}

// What: Basic auth, session cookie and CSRF in one layer.
// Why: auth is checked per request; the cookie binds CSRF.
async fn basic_auth(State(state): Shared, mut req: Request, next: Next) -> Response {
    if let (Some(user), Some(hash)) = (&state.config.auth_user, &state.config.auth_password_hash) {
        let presented = req
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Basic "))
            .and_then(|enc| base64::engine::general_purpose::STANDARD.decode(enc).ok())
            .and_then(|dec| String::from_utf8(dec).ok())
            .and_then(|creds| {
                let (u, p) = creds.split_once(':')?;
                Some((u.to_owned(), p.to_owned()))
            });
        // What: the Argon2id check runs off the async pool.
        // Why: it is CPU and memory heavy by design.
        let valid = match presented {
            Some((u, p)) => {
                let hash = hash.clone();
                let user_ok = ct_eq(&u, user);
                tokio::task::spawn_blocking(move || password_matches(&hash, &p))
                    .await
                    .unwrap_or(false)
                    & user_ok
            }
            None => false,
        };
        if !valid {
            return (
                StatusCode::UNAUTHORIZED,
                [(header::WWW_AUTHENTICATE, r#"Basic realm="LanCache Admin""#)],
                "Unauthorized",
            )
                .into_response();
        }
    }

    let secure_cookie = forwarded_proto_is_https(req.headers());
    let existing = session_cookie(req.headers())
        .and_then(|cookie| validate_session(cookie, &state.ui_session_secret));
    let needs_cookie = existing.is_none();
    let session =
        existing.unwrap_or_else(|| issue_session(&state.ui_session_secret, state.ui_session_ttl));
    if let Ok(value) = HeaderValue::from_str(&session.csrf_token) {
        req.headers_mut()
            .insert(HeaderName::from_static(INTERNAL_CSRF_HEADER), value);
    }

    let mutating = matches!(
        *req.method(),
        Method::POST | Method::PUT | Method::PATCH | Method::DELETE
    );
    let mut response = if mutating {
        let (parts, body) = req.into_parts();
        match to_bytes(body, MAX_CSRF_BODY_BYTES).await {
            Err(err) => {
                tracing::warn!(error = %err, "failed to read request body for csrf validation");
                StatusCode::BAD_REQUEST.into_response()
            }
            Ok(bytes) => {
                let submitted = parts
                    .headers
                    .get(CSRF_HEADER_NAME)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned)
                    .or_else(|| {
                        form_urlencoded::parse(&bytes)
                            .find_map(|(k, v)| (k == CSRF_FORM_FIELD).then(|| v.into_owned()))
                    });
                if submitted.is_some_and(|token| ct_eq(&token, &session.csrf_token)) {
                    next.run(Request::from_parts(parts, Body::from(bytes)))
                        .await
                } else {
                    StatusCode::FORBIDDEN.into_response()
                }
            }
        }
    } else {
        next.run(req).await
    };
    if needs_cookie {
        attach_session_cookie(&mut response, &session, state.ui_session_ttl, secure_cookie);
    }
    response
}

// What: the URL path of each ui page.
// Why: router, redirects, errors, nav read one owner.
// From: Issue #1683 | PR #1912
const PAGE_DASHBOARD: &str = "/";
const PAGE_DHCP: &str = "/dhcp";
const PAGE_NTP: &str = "/ntp";
const PAGE_DOMAINS: &str = "/domains";
const PAGE_SECONDARIES: &str = "/secondaries";
const PAGE_STATS: &str = "/stats";
const PAGE_LOGS: &str = "/logs";
const PAGE_SETUP: &str = "/setup";

// What: the URL path of each other ui route.
// Why: router, forms, scripts, tests read one owner.
// From: Issue #1683 | PR #1912
const ROUTE_HEALTH: &str = "/health";
const ROUTE_SECONDARY_REGISTER: &str = "/api/secondary/register";
const ROUTE_FAVICON: &str = "/favicon.ico";
const ROUTE_LOGO_ICON: &str = "/static/logo-icon.png";
const ROUTE_DHCP_MODE: &str = "/dhcp/mode";
const ROUTE_DHCP_DDNS: &str = "/dhcp/ddns";
const ROUTE_DHCP_PROXY: &str = "/dhcp/proxy";
const ROUTE_DHCP_RELAY: &str = "/dhcp/relay";
const ROUTE_SUBNET_ADD: &str = "/dhcp/subnet/add";
const ROUTE_SUBNET_UPDATE: &str = "/dhcp/subnet/update";
const ROUTE_SUBNET_REMOVE: &str = "/dhcp/subnet/remove";
const ROUTE_SUBNET_OPTION_ADD: &str = "/dhcp/subnet/option/add";
const ROUTE_SUBNET_OPTION_REMOVE: &str = "/dhcp/subnet/option/remove";
const ROUTE_STATIC_ADD: &str = "/dhcp/static/add";
const ROUTE_STATIC_REMOVE: &str = "/dhcp/static/remove";
const ROUTE_LEASE_RELEASE: &str = "/dhcp/lease/release";
const ROUTE_KEA_ROLLBACK: &str = "/dhcp/snapshot/rollback";
const ROUTE_DHCP_CHECK: &str = "/api/dhcp/check";
const ROUTE_NTP_SETTINGS: &str = "/ntp/settings";
const ROUTE_DNS_ADD: &str = "/domains/dns/add";
const ROUTE_DNS_REMOVE: &str = "/domains/dns/remove";
const ROUTE_DNS_TOGGLE: &str = "/domains/dns/toggle";
const ROUTE_LAN_ADD: &str = "/domains/lan/add";
const ROUTE_LAN_REMOVE: &str = "/domains/lan/remove";
const ROUTE_PTR_ADD: &str = "/domains/ptr/add";
const ROUTE_PTR_REMOVE: &str = "/domains/ptr/remove";
const ROUTE_AAAA_FILTER: &str = "/domains/aaaa-filter";
const ROUTE_DDNS_UNSIGNED: &str = "/domains/ddns-allow-unsigned-updates";
const ROUTE_ZONE_ROLLBACK: &str = "/domains/zones/rollback";
const ROUTE_LOGS_SETTINGS: &str = "/logs/settings";
const ROUTE_SETUP_UPDATE: &str = "/setup/update";
const ROUTE_RESTART_UI: &str = "/setup/restart-ui";
const ROUTE_DESIRED_STATE: &str = "/api/services/{service}/desired-state";
const ROUTE_CACHE_RESIZE: &str = "/cache/resize";
const ROUTE_METRICS: &str = "/api/metrics";
const ROUTE_WATCHDOG_STATUS: &str = "/api/watchdog-status";
const ROUTE_NETDATA: &str = "/api/netdata/{*path}";
const ROUTE_ADMIN_CSS: &str = "/static/admin.css";
const ROUTE_CHART_JS: &str = "/static/chart.umd.min.js";
const ROUTE_SECONDARY: &str = "/api/secondary/{name}";
const ROUTE_SECONDARY_ROTATE: &str = "/api/secondary/{name}/rotate-token";
const ROUTE_SECONDARY_HEALTH: &str = "/api/secondary/{name}/health";
const ROUTE_SECONDARY_ADDRESS: &str = "/api/secondary/{name}/address";

// What: the domains page URL with an error code.
// Why: one owner for each domains error redirect.
// From: Issue #1683 | PR #1912
fn domains_error(code: &str) -> String {
    format!("{PAGE_DOMAINS}?error={code}")
}

// What: take a unit lock; a poisoned one is taken anyway.
// Why: a Mutex<()> guards order only, no data to lose.
// From: Issue #1683 | PR #1912
fn hold(lock: &Mutex<()>) -> std::sync::MutexGuard<'_, ()> {
    lock.lock().unwrap_or_else(|e| e.into_inner())
}

// What: a template context with page name and CSRF token.
// Why: every page's forms need the live session's token.
fn page_ctx(headers: &HeaderMap, active: &str) -> Context {
    let token = headers
        .get(INTERNAL_CSRF_HEADER)
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            tracing::error!("page rendered without a session CSRF token");
            ""
        });
    let mut ctx = Context::new();
    ctx.insert("active_page", active);
    ctx.insert("csrf_token", token);
    // What: form limits from their one Rust owner.
    // Why: AG-CODE-011: templates repeat no number.
    // From: Issue #1683 | PR #1912
    ctx.insert("lan_record_types", &LAN_RECORD_TYPES);
    ctx.insert("record_ttl_default", &DEFAULT_RECORD_TTL);
    ctx.insert("ttl_max", &MAX_TTL);
    ctx.insert("txt_max_bytes", &MAX_TXT_BYTES);
    ctx.insert("option_code_min", &OPTION_CODE_MIN);
    ctx.insert("option_code_max", &OPTION_CODE_MAX);
    // What: each page path from its one Rust owner.
    // Why: nav and links follow the router path.
    // From: Issue #1683 | PR #1912
    const PAGES: [(&str, &str); 8] = [
        ("dashboard", PAGE_DASHBOARD),
        ("dhcp", PAGE_DHCP),
        ("ntp", PAGE_NTP),
        ("domains", PAGE_DOMAINS),
        ("secondaries", PAGE_SECONDARIES),
        ("stats", PAGE_STATS),
        ("logs", PAGE_LOGS),
        ("setup", PAGE_SETUP),
    ];
    // What: each route path from its one Rust owner.
    // Why: forms and scripts follow the router path.
    // From: Issue #1683 | PR #1912
    const ROUTES: [(&str, &str); 43] = [
        ("health", ROUTE_HEALTH),
        ("secondary_register", ROUTE_SECONDARY_REGISTER),
        ("favicon", ROUTE_FAVICON),
        ("logo_icon", ROUTE_LOGO_ICON),
        ("dhcp_mode", ROUTE_DHCP_MODE),
        ("dhcp_ddns", ROUTE_DHCP_DDNS),
        ("dhcp_proxy", ROUTE_DHCP_PROXY),
        ("dhcp_relay", ROUTE_DHCP_RELAY),
        ("subnet_add", ROUTE_SUBNET_ADD),
        ("subnet_update", ROUTE_SUBNET_UPDATE),
        ("subnet_remove", ROUTE_SUBNET_REMOVE),
        ("subnet_option_add", ROUTE_SUBNET_OPTION_ADD),
        ("subnet_option_remove", ROUTE_SUBNET_OPTION_REMOVE),
        ("static_add", ROUTE_STATIC_ADD),
        ("static_remove", ROUTE_STATIC_REMOVE),
        ("lease_release", ROUTE_LEASE_RELEASE),
        ("kea_rollback", ROUTE_KEA_ROLLBACK),
        ("dhcp_check", ROUTE_DHCP_CHECK),
        ("ntp_settings", ROUTE_NTP_SETTINGS),
        ("dns_add", ROUTE_DNS_ADD),
        ("dns_remove", ROUTE_DNS_REMOVE),
        ("dns_toggle", ROUTE_DNS_TOGGLE),
        ("lan_add", ROUTE_LAN_ADD),
        ("lan_remove", ROUTE_LAN_REMOVE),
        ("ptr_add", ROUTE_PTR_ADD),
        ("ptr_remove", ROUTE_PTR_REMOVE),
        ("aaaa_filter", ROUTE_AAAA_FILTER),
        ("ddns_unsigned", ROUTE_DDNS_UNSIGNED),
        ("zone_rollback", ROUTE_ZONE_ROLLBACK),
        ("logs_settings", ROUTE_LOGS_SETTINGS),
        ("setup_update", ROUTE_SETUP_UPDATE),
        ("restart_ui", ROUTE_RESTART_UI),
        ("desired_state", ROUTE_DESIRED_STATE),
        ("cache_resize", ROUTE_CACHE_RESIZE),
        ("metrics", ROUTE_METRICS),
        ("watchdog_status", ROUTE_WATCHDOG_STATUS),
        ("netdata", ROUTE_NETDATA),
        ("admin_css", ROUTE_ADMIN_CSS),
        ("chart_js", ROUTE_CHART_JS),
        ("secondary", ROUTE_SECONDARY),
        ("secondary_rotate", ROUTE_SECONDARY_ROTATE),
        ("secondary_health", ROUTE_SECONDARY_HEALTH),
        ("secondary_address", ROUTE_SECONDARY_ADDRESS),
    ];
    for (name, table) in [("pages", &PAGES[..]), ("routes", &ROUTES[..])] {
        ctx.insert(name, &table.iter().copied().collect::<BTreeMap<_, _>>());
    }
    ctx
}

// What: render a template; a failure is a real HTTP 500.
// Why: monitors read the status; dev mode shows the cause.
fn render(state: &AppState, name: &str, ctx: &Context) -> Response {
    // What: SOT numbers and the repo address for pages.
    // Why: every page and base.html read them here.
    let mut page = ctx.clone();
    for (key, value) in &state.config.page_numbers {
        page.insert(*key, value);
    }
    page.insert("repo_url", &state.config.repo_url);
    match state.templates.render(name, &page) {
        Ok(html) => Html(html).into_response(),
        Err(e) => {
            tracing::error!(template = name, error = %e, "template rendering failed");
            let detail = if state.config.dev_mode {
                format!("Template error: {name}: {e}")
            } else {
                "Template Rendering Failed: see the application logs.".to_string()
            };
            let body = format!(
                "<html><body style='background:#0f172a;color:#f87171;font-family:monospace;\
                 padding:2rem'><h2>{}</h2></body></html>",
                html_escape(&detail)
            );
            (StatusCode::INTERNAL_SERVER_ERROR, Html(body)).into_response()
        }
    }
}

// What: escape text for an HTML body.
// Why: error pages echo operator input back.
fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

// What: the title and return link of one error page family.
// Why: one error type serves cache, NTP, DHCP, setup, logs.
struct ErrorArea {
    title: &'static str,
    href: &'static str,
    back: &'static str,
}

// What: the error-page areas of HtmlError.
// Why: each area names its title and back link.
const CACHE_AREA: ErrorArea = ErrorArea {
    title: "Cache Resize Error",
    href: PAGE_DASHBOARD,
    back: "Return to dashboard",
};
const NTP_AREA: ErrorArea = ErrorArea {
    title: "NTP Configuration Error",
    href: PAGE_NTP,
    back: "Return to NTP settings",
};
const DHCP_AREA: ErrorArea = ErrorArea {
    title: "DHCP Configuration Error",
    href: PAGE_DHCP,
    back: "Return to DHCP settings",
};
const SETTINGS_AREA: ErrorArea = ErrorArea {
    title: "Settings Error",
    href: PAGE_SETUP,
    back: "Return to setup",
};
const LOGS_AREA: ErrorArea = ErrorArea {
    title: "Logging Settings Error",
    href: PAGE_LOGS,
    back: "Return to logs",
};

// What: a failed form action shown as an HTML page.
// Why: operators need the reason, not a bare status code.
struct HtmlError {
    status: StatusCode,
    area: &'static ErrorArea,
    message: String,
}

impl HtmlError {
    // What: build an HtmlError for one area.
    // Why: callers pass status, area and message only.
    fn new(status: StatusCode, area: &'static ErrorArea, message: impl Into<String>) -> Self {
        Self {
            status,
            area,
            message: message.into(),
        }
    }
}

impl IntoResponse for HtmlError {
    // What: render an HtmlError as a small HTML page.
    // Why: a failed post shows a reason and a way back.
    fn into_response(self) -> Response {
        let ErrorArea { title, href, back } = self.area;
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>{title}</title></head>\n\
             <body><h1>{title}</h1>\n<p>{}</p>\n<p><a href=\"{href}\">{back}</a></p>\n\
             </body>\n</html>",
            html_escape(&self.message)
        );
        (self.status, Html(body)).into_response()
    }
}

// What: a static file response; cached ones are public.
// Why: scripts and icons cache long, the css does not.
fn asset(content_type: &'static str, cached: bool, body: &'static [u8]) -> Response {
    let headers = [(header::CONTENT_TYPE, content_type)];
    if cached {
        let cache = [(header::CACHE_CONTROL, "public, max-age=31536000")];
        return (headers, cache, body).into_response();
    }
    (headers, body).into_response()
}

// What: liveness answer, always ok.
// Why: a constant answer shows only that the process runs.
async fn health() -> &'static str {
    "ok"
}

// What: serve the compiled-in admin stylesheet.
// Why: assets ship in the binary; no file read at runtime.
async fn admin_css() -> Response {
    asset(
        "text/css; charset=utf-8",
        false,
        include_bytes!("static/admin.css"),
    )
}

// What: serve the compiled-in chart script.
// Why: assets ship in the binary; no file read at runtime.
async fn chart_js() -> Response {
    asset(
        "application/javascript; charset=utf-8",
        true,
        include_bytes!("static/chart.umd.min.js"),
    )
}

// What: serve the compiled-in favicon.
// Why: assets ship in the binary; no file read at runtime.
async fn favicon_ico() -> Response {
    asset("image/x-icon", true, include_bytes!("static/favicon.ico"))
}

// What: serve the compiled-in logo image.
// Why: assets ship in the binary; no file read at runtime.
async fn logo_icon() -> Response {
    asset("image/png", true, include_bytes!("static/logo-icon.png"))
}

// What: load every template and the image functions.
// Why: a broken template is a deploy defect; fail early.
fn load_templates(cfg: &Config) -> Tera {
    let mut tera = Tera::default();
    tera.autoescape_on(vec!["html"]);
    // What: register functions before adding templates.
    // Why: Tera checks function calls at parse time.
    for (name, value) in [
        ("lancache_image_registry", &cfg.lancache_image_registry),
        ("lancache_image_prefix", &cfg.lancache_image_prefix),
        ("lancache_image_channel", &cfg.lancache_image_channel),
        ("lancache_image_tag", &cfg.lancache_image_tag),
    ] {
        let value = value.clone();
        tera.register_function(name, move |_: tera::Kwargs, _: &tera::State<'_>| {
            value.clone()
        });
    }
    for name in TEMPLATE_NAMES {
        let path = format!("{}/{}", cfg.template_dir, name);
        let content = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("Cannot read template {path}: {e}"));
        tera.add_raw_template(name, &content)
            .unwrap_or_else(|e| panic!("Cannot parse template {name}: {e}"));
    }
    tera
}
// What: the watchdog document as the dashboard shows it.
// Why: fresh, stale and missing data look different.
// From: Issue #870
fn watchdog_json(path: &str, cycles: u32) -> Value {
    let age = fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .map(|modified| {
            SystemTime::now()
                .duration_since(modified)
                .unwrap_or_default()
        });
    let status: Option<WatchdogStatus> = fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok());
    let (Some(status), Some(age)) = (status, age) else {
        return json!({ "state": "unavailable" });
    };
    // What: compose service names, sorted by name.
    // Why: the SOT names them; the ui keeps no own list.
    let mut names: Vec<&String> = status.services.keys().collect();
    names.sort();
    let services: Vec<Value> = names
        .into_iter()
        .map(|name| {
            let health = &status.services[name];
            json!({
                "name": name,
                "status": health.status,
                "health": health.health,
                "failures": health.failures,
            })
        })
        .collect();
    if age > status.stale_after(cycles) {
        json!({
            "state": "stale",
            "updated": status.updated,
            "age_seconds": age.as_secs(),
            "services": services,
            "disk": status.disk,
        })
    } else {
        json!({
            "state": "fresh",
            "updated": status.updated,
            "services": services,
            "disk": status.disk,
        })
    }
}

// What: true for an absolute path without "..".
// Why: the env supplies it; a relative path is a typo.
fn path_allowed(path: &str) -> bool {
    Path::new(path).is_absolute() && !path.contains("..")
}

// What: bytes in a KiB, MiB and GiB.
// Why: one spelling for every size conversion.
const KIB: u64 = 1_024;
const MIB: u64 = 1_048_576;
const GIB: u64 = 1_073_741_824;

// What: size of an allowed directory in GiB, 0 if refused.
// Why: the shared tree walk sums it; no links.
fn du_gb(path: &str) -> f64 {
    if !path_allowed(path) {
        return 0.0;
    }
    match files_under(Path::new(path)) {
        Ok(files) => files.iter().map(|(_, meta)| meta.len()).sum::<u64>() as f64 / GIB as f64,
        Err(e) => {
            tracing::warn!("{path} not read for its size: {e}");
            0.0
        }
    }
}

// What: free MiB on the cache filesystem; None if unknown.
// Why: callers must fail closed, not assume unlimited.
fn cache_free_mib(path: &str) -> Option<u64> {
    path_allowed(path)
        .then(|| df(Path::new(path)))
        .flatten()
        .map(|space| space.avail_kib / 1024)
}

// What: MiB that must stay free after a cache of this size.
// Why: nginx's cache manager overshoots max_size briefly.
// From: Issue #1069
fn cache_buffer_mib(cache_gb: u64) -> i64 {
    match cache_gb {
        7.. => 2048,
        5..=6 => 1024,
        _ => 512,
    }
}

// What: true if cache_gb GiB leaves the buffer free.
// Why: signed maths; a nearly full disk must not wrap.
// From: Issue #1069
fn cache_fits(cache_gb: u64, avail_mib: u64) -> bool {
    avail_mib as i64 - cache_buffer_mib(cache_gb) >= cache_gb as i64 * 1024
}

// What: the largest whole-GiB cache size that fits.
// Why: the rejection message names it for the operator.
fn largest_cache_gb(avail_mib: u64) -> Option<u64> {
    (1..=avail_mib / 1024)
        .rev()
        .find(|gb| cache_fits(*gb, avail_mib))
}

// What: bytes as a short human string.
// Why: logs and stats show sizes in one spelling.
fn format_bytes(bytes: u64) -> String {
    match bytes {
        GIB.. => format!("{:.1} GB", bytes as f64 / GIB as f64),
        MIB.. => format!("{:.1} MB", bytes as f64 / MIB as f64),
        KIB.. => format!("{:.1} KB", bytes as f64 / KIB as f64),
        _ => format!("{bytes} B"),
    }
}

// What: nginx stub_status counters for the dashboard.
// Why: the dashboard JSON needs a typed, defaulted shape.
#[derive(Debug, Serialize, Default, Clone)]
struct NginxStatus {
    active: u64,
    accepts: u64,
    handled: u64,
    requests: u64,
    reading: u64,
    writing: u64,
    waiting: u64,
}

// What: nginx connection counters; None if unreachable.
// Why: the dashboard shows a gap rather than stale numbers.
async fn nginx_status(client: &reqwest::Client, base_url: &str) -> Option<NginxStatus> {
    let text = client
        .get(format!("{base_url}/nginx_status"))
        .timeout(Duration::from_secs(3))
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;
    let number = |token: Option<&str>| token.and_then(|t| t.parse().ok()).unwrap_or(0);
    let mut status = NginxStatus::default();
    let mut lines = text.lines();
    while let Some(line) = lines.next() {
        let words: Vec<&str> = line.split_whitespace().collect();
        if line.starts_with("Active connections:") {
            status.active = number(words.last().copied());
        } else if line.contains("accepts") && line.contains("handled") {
            let counts: Vec<u64> = lines
                .next()
                .unwrap_or_default()
                .split_whitespace()
                .filter_map(|n| n.parse().ok())
                .collect();
            if let [accepts, handled, requests, ..] = counts[..] {
                (status.accepts, status.handled, status.requests) = (accepts, handled, requests);
            }
        } else if line.starts_with("Reading:") {
            status.reading = number(words.get(1).copied());
            status.writing = number(words.get(3).copied());
            status.waiting = number(words.get(5).copied());
        }
    }
    Some(status)
}

// What: one parsed nginx access-log line.
// Why: the logs page renders fields, not raw text.
#[derive(Debug, Serialize, Clone)]
struct LogEntry {
    ip: String,
    time: String,
    method: String,
    path: String,
    host: String,
    status: u16,
    bytes_human: String,
    cache_status: String,
}

// What: totals over the parsed access-log lines.
// Why: the dashboard reads these totals directly.
#[derive(Debug, Serialize, Default, Clone)]
struct LogStats {
    hits: u64,
    misses: u64,
    expired: u64,
    other: u64,
    total_bytes_gb: f64,
    total_requests: u64,
    hit_pct: f64,
}

// What: the proxy access line pattern from common.
// Why: two callers index the groups by number.
fn log_regex() -> &'static Regex {
    static LOG_REGEX: OnceLock<Regex> = OnceLock::new();
    LOG_REGEX.get_or_init(|| Regex::new(PROXY_ACCESS_LOG_PATTERN).expect("log regex is valid"))
}

// What: the proxy's plain day files, oldest first.
// Why: closed days are xz; the open ones are read.
fn proxy_log_files(dir: &str) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "log") && p.is_file())
        .collect();
    files.sort();
    files
}

// What: the last `limit` lines of a file, oldest first.
// Why: reading backwards keeps multi-GB logs cheap to tail.
fn tail_lines(path: &str, limit: usize) -> Vec<String> {
    const CHUNK: u64 = 64 * 1024;
    let Ok(mut file) = File::open(path) else {
        return vec![];
    };
    let Ok(mut pos) = file.seek(SeekFrom::End(0)) else {
        return vec![];
    };
    let mut buffer: Vec<u8> = Vec::new();
    let mut newlines = 0;
    // What: stop once more than `limit` newlines were read.
    // Why: the first segment may be cut and is dropped.
    while pos > 0 && newlines <= limit {
        let len = CHUNK.min(pos);
        pos -= len;
        let mut chunk = vec![0u8; len as usize];
        if file.seek(SeekFrom::Start(pos)).is_err() || file.read_exact(&mut chunk).is_err() {
            break;
        }
        newlines += chunk.iter().filter(|&&b| b == b'\n').count();
        chunk.extend_from_slice(&buffer);
        buffer = chunk;
    }
    let text = String::from_utf8_lossy(&buffer);
    let mut lines: Vec<&str> = text.lines().collect();
    if pos > 0 && !lines.is_empty() {
        lines.remove(0);
    }
    let start = lines.len().saturating_sub(limit);
    lines[start..].iter().map(|l| l.to_string()).collect()
}

// What: the last `limit` parsed access-log entries.
// Why: oldest first, so callers reverse for newest-first.
fn parse_log_tail(dir: &str, limit: usize) -> Vec<LogEntry> {
    let Some(newest) = proxy_log_files(dir).pop() else {
        return vec![];
    };
    tail_lines(&newest.to_string_lossy(), limit)
        .iter()
        .filter_map(|line| {
            let caps = log_regex().captures(line)?;
            Some(LogEntry {
                ip: caps[1].to_string(),
                time: caps[2].to_string(),
                method: caps[3].to_string(),
                path: caps[4].to_string(),
                host: caps[8].to_string(),
                status: caps[5].parse().unwrap_or(0),
                bytes_human: format_bytes(caps[6].parse().unwrap_or(0)),
                cache_status: caps[7].to_string(),
            })
        })
        .collect()
}

// What: hit, miss and byte totals over the open days.
// Why: closed days are xz; the dashboard stays cheap.
fn log_stats(dir: &str) -> LogStats {
    let mut stats = LogStats::default();
    let mut total_bytes: u64 = 0;
    for path in proxy_log_files(dir) {
        let Ok(file) = File::open(path) else { continue };
        // What: read raw lines, decode each lossily.
        // Why: a non-UTF-8 byte must not hide later lines.
        for raw in BufReader::new(file).split(b'\n').map_while(Result::ok) {
            let line = String::from_utf8_lossy(&raw);
            let Some(caps) = log_regex().captures(&line) else {
                continue;
            };
            stats.total_requests += 1;
            total_bytes += caps[6].parse::<u64>().unwrap_or(0);
            match &caps[7] {
                "HIT" => stats.hits += 1,
                "MISS" => stats.misses += 1,
                "EXPIRED" => stats.expired += 1,
                _ => stats.other += 1,
            }
        }
    }
    stats.total_bytes_gb = total_bytes as f64 / GIB as f64;
    if stats.total_requests > 0 {
        stats.hit_pct = stats.hits as f64 / stats.total_requests as f64 * 100.0;
    }
    stats
}

// What: one syslog line with its timestamp.
// Why: the logs page lists central syslog entries.
#[derive(Debug, Serialize, Clone)]
struct SyslogEntry {
    timestamp: String,
    host: String,
    program: String,
    message: String,
}

// What: file, size and day counts of one syslog host.
// Why: the stats page shows storage per host.
#[derive(Debug, Serialize, Default, Clone)]
struct SyslogHostStats {
    host: String,
    files: u64,
    size_bytes: u64,
    days: u64,
    size_human: String,
}

// What: syslog storage totals per host.
// Why: one typed value feeds the syslog page.
#[derive(Debug, Serialize, Default, Clone)]
struct SyslogStats {
    hosts: Vec<SyslogHostStats>,
    total_files: u64,
    total_size_bytes: u64,
}

// What: lines each host keeps in a merged tail at least.
// Why: a noisy host must not push a quiet one out of view.
// From: Issue #859
const PER_HOST_FLOOR: usize = 10;

// What: the host directories under the store root.
// Why: one host per directory, named by syslog-ng.
fn syslog_host_dirs(root: &str) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(root)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.is_dir())
                .collect()
        })
        .unwrap_or_else(|e| {
            tracing::warn!("syslog store {root} not listed: {e}");
            Vec::new()
        });
    dirs.sort();
    dirs
}

// What: host names that have a directory in the store.
// Why: the log page filter offers exactly these.
fn syslog_hosts(root: &str) -> Vec<String> {
    syslog_host_dirs(root)
        .iter()
        .filter_map(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .collect()
}

// What: file content; .xz files are decompressed.
// Why: the watchdog compresses closed log files to xz.
// From: Issue #1683
fn read_syslog_file(path: &Path) -> Option<String> {
    let raw = fs::read(path).ok()?;
    let bytes = match path.extension().and_then(|e| e.to_str()) {
        Some("xz") => {
            let mut out = Vec::new();
            liblzma::read::XzDecoder::new(&raw[..])
                .read_to_end(&mut out)
                .ok()?;
            out
        }
        _ => raw,
    };
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// What: one syslog line as an entry; odd lines stay raw.
// Why: a stack-trace line must not vanish from the view.
fn parse_syslog_line(host: &str, line: &str) -> Option<SyslogEntry> {
    static SYSLOG_LINE: OnceLock<Regex> = OnceLock::new();
    if line.trim().is_empty() {
        return None;
    }
    let re = SYSLOG_LINE
        .get_or_init(|| Regex::new(r"^(\S+)\s+\S+\s+([^:]+):\s(.*)$").expect("syslog regex"));
    Some(match re.captures(line) {
        Some(c) => SyslogEntry {
            timestamp: c[1].to_string(),
            host: host.to_string(),
            program: c[2].to_string(),
            message: c[3].to_string(),
        },
        None => SyslogEntry {
            timestamp: String::new(),
            host: host.to_string(),
            program: String::new(),
            message: line.to_string(),
        },
    })
}

// What: up to `limit` entries from the newest files.
// Why: every host with data shows before the early stop.
fn syslog_tail(root: &str, host: Option<&str>, limit: usize) -> Vec<SyslogEntry> {
    if limit == 0 {
        return vec![];
    }
    // What: a host must be one bare directory name.
    // Why: the URL gives the value; it must not escape.
    let dirs = match host {
        Some(h) if !h.is_empty() && h != "." && h != ".." && !h.contains(['/', '\\', '\0']) => {
            vec![Path::new(root).join(h)]
        }
        Some(_) => vec![],
        None => syslog_host_dirs(root),
    };
    let mut files: Vec<(PathBuf, SystemTime)> = dirs
        .iter()
        .filter_map(|dir| fs::read_dir(dir).ok())
        .flat_map(|entries| entries.flatten())
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            meta.is_file()
                .then(|| (e.path(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)))
        })
        .collect();
    files.sort_by_key(|(_, mtime)| std::cmp::Reverse(*mtime));
    let hosts_with_data: HashSet<PathBuf> = files
        .iter()
        .filter_map(|(p, _)| p.parent().map(PathBuf::from))
        .collect();
    let mut seen: HashSet<PathBuf> = HashSet::new();
    let mut collected = Vec::new();
    for (path, _) in files {
        let dir = path.parent().map(PathBuf::from).unwrap_or_default();
        let name = dir.file_name().map(|n| n.to_string_lossy().into_owned());
        seen.insert(dir);
        let Some(content) = read_syslog_file(&path) else {
            continue;
        };
        collected.extend(
            content
                .lines()
                .filter_map(|line| parse_syslog_line(&name.clone().unwrap_or_default(), line)),
        );
        if collected.len() >= limit && seen.len() >= hosts_with_data.len() {
            break;
        }
    }
    fair_window(collected, limit)
}

// What: merge hosts into `limit` lines, quiet ones too.
// Why: sort-and-cut would drop a quiet host's only error.
// From: Issue #859
fn fair_window(collected: Vec<SyslogEntry>, limit: usize) -> Vec<SyslogEntry> {
    let mut by_host: BTreeMap<String, Vec<SyslogEntry>> = BTreeMap::new();
    for entry in collected {
        by_host.entry(entry.host.clone()).or_default().push(entry);
    }
    if by_host.is_empty() {
        return vec![];
    }
    for entries in by_host.values_mut() {
        entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    }
    let floor = (limit / by_host.len()).clamp(1, PER_HOST_FLOOR);
    let mut kept: Vec<SyslogEntry> = Vec::new();
    let mut taken: HashMap<String, usize> = HashMap::new();
    'rounds: for round in 0..floor {
        for (host, entries) in &by_host {
            if kept.len() >= limit {
                break 'rounds;
            }
            if let Some(entry) = entries.get(round) {
                kept.push(entry.clone());
                *taken.entry(host.clone()).or_default() += 1;
            }
        }
    }
    let mut rest: Vec<&SyslogEntry> = by_host
        .iter()
        .flat_map(|(host, entries)| entries.iter().skip(taken.get(host).copied().unwrap_or(0)))
        .collect();
    rest.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    let need = limit.saturating_sub(kept.len());
    kept.extend(rest.into_iter().take(need).cloned());
    kept.sort_by(|a, b| a.timestamp.cmp(&b.timestamp));
    kept
}

// What: per-host file count, size and distinct days.
// Why: metadata only; decompressing every file is costly.
fn syslog_stats(root: &str) -> SyslogStats {
    let mut stats = SyslogStats::default();
    for dir in syslog_host_dirs(root) {
        let mut host = SyslogHostStats {
            host: dir
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            ..Default::default()
        };
        let mut days: HashSet<String> = HashSet::new();
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_file() {
                continue;
            }
            host.files += 1;
            host.size_bytes += meta.len();
            // What: the YYYYMMDD start of <day>.log names.
            // Why: the day count is the retention in view.
            let name = entry.file_name().to_string_lossy().into_owned();
            let day = name.split('.').next().unwrap_or_default().to_string();
            if day.len() == 8 && day.bytes().all(|b| b.is_ascii_digit()) {
                days.insert(day);
            }
        }
        host.days = days.len() as u64;
        host.size_human = format_bytes(host.size_bytes);
        stats.total_files += host.files;
        stats.total_size_bytes += host.size_bytes;
        stats.hosts.push(host);
    }
    stats
}

// What: stored alarm history cap, newest kept.
// Why: a burst of alarms must not grow the file unbounded.
const MAX_ALARMS: usize = 50;

// What: stored alarms, newest first; any failure is empty.
// Why: the dashboard must render even with a broken file.
fn read_alarms(path: &str) -> Vec<NetdataAlarm> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => {
            tracing::warn!("alarm file {path} not read: {e}");
            return Vec::new();
        }
    };
    serde_json::from_str(&content).unwrap_or_else(|e| {
        tracing::warn!("alarm file {path} is not valid JSON: {e}");
        Vec::new()
    })
}

// What: store one alarm unless its unique_id is known.
// Why: netdata resends; the caller holds the alarms lock.
fn append_alarm(path: &str, alarm: NetdataAlarm) -> io::Result<()> {
    let mut alarms = read_alarms(path);
    if alarms.iter().any(|a| a.unique_id == alarm.unique_id) {
        return Ok(());
    }
    alarms.insert(0, alarm);
    alarms.truncate(MAX_ALARMS);
    let json = serde_json::to_vec_pretty(&alarms).map_err(io::Error::other)?;
    write_if_changed(Path::new(path), &json, 0o644, None).map(|_| ())
}

// What: alarms with a readable UTC time for the template.
// Why: this Tera version has no date filter.
fn alarm_views(alarms: &[NetdataAlarm]) -> Vec<Value> {
    alarms
        .iter()
        .map(|a| {
            let when = time::OffsetDateTime::from_unix_timestamp(a.when)
                .ok()
                .and_then(|t| {
                    t.format(&time::format_description::well_known::Rfc3339)
                        .ok()
                })
                .unwrap_or_else(|| a.when.to_string());
            json!({
                "unique_id": a.unique_id, "name": a.name, "chart": a.chart,
                "host": a.host, "status": a.status, "value_string": a.value_string,
                "info": a.info, "when_display": when,
            })
        })
        .collect()
}

// What: store an alarm sent by netdata's custom_sender.
// Why: the token header gates it; no token rejects all.
// From: Issue #858
async fn ingest_alarm(State(state): Shared, headers: HeaderMap, body: Bytes) -> StatusCode {
    let token = &state.config.netdata_alarm_token;
    let presented = headers
        .get(ALARM_TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    if token.is_empty() || !ct_eq(presented, token) {
        return StatusCode::UNAUTHORIZED;
    }
    let alarm: NetdataAlarm = match serde_json::from_slice(&body) {
        Ok(alarm) => alarm,
        Err(e) => {
            tracing::warn!("rejecting malformed netdata alarm payload: {e}");
            return StatusCode::BAD_REQUEST;
        }
    };
    // What: hold the alarms lock over read-modify-write.
    // Why: two concurrent posts must not lose an update.
    let stored = {
        let _guard = hold(&state.netdata_alarms_lock);
        append_alarm(&state.config.netdata_alarms_file, alarm)
    };
    stored_status("netdata alarm", stored)
}

// What: the answer to a client write of a state file.
// Why: senders only tell 2xx from failure; one rule.
// From: Issue #1683 | PR #1912
fn stored_status(what: &str, written: io::Result<()>) -> StatusCode {
    match written {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(e) => {
            tracing::error!("failed to persist {what}: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

// What: forward a chart request to netdata.
// Why: only data and charts, never a client-chosen path.
async fn netdata_proxy(
    State(state): Shared,
    AxPath(path): AxPath<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Response, StatusCode> {
    // What: cap the buffered upstream body.
    // Why: a wide chart range must not exhaust memory.
    const MAX_BODY: usize = 16 * 1024 * 1024;
    if path.is_empty() || path.contains('/') || path.contains("..") {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !["data", "charts"].contains(&path.as_str()) {
        return Err(StatusCode::NOT_FOUND);
    }
    let mut url = reqwest::Url::parse(&state.config.netdata_url)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    url.path_segments_mut()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .pop_if_empty()
        .extend(["api", "v1", &path]);
    let mut pairs: Vec<(&String, &String)> = params.iter().collect();
    pairs.sort();
    url.query_pairs_mut().extend_pairs(pairs);

    let upstream = state
        .http_client
        .get(url)
        .send()
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
    let status = upstream.status().as_u16();
    let content_type = upstream
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.trim().is_empty())
        .unwrap_or("application/json")
        .to_string();
    let mut body = Vec::new();
    let mut stream = upstream.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| StatusCode::BAD_GATEWAY)?;
        if body.len() + chunk.len() > MAX_BODY {
            return Err(StatusCode::BAD_GATEWAY);
        }
        body.extend_from_slice(&chunk);
    }
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(body))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

// What: the dotted reverse zone that owns an IPv4 address.
// Why: only zones the stack provisions may hold a PTR.
fn reverse_zone_for_ipv4(ip: Ipv4Addr) -> Option<String> {
    let [a, b, _, _] = ip.octets();
    let zones = reverse_zones();
    [
        format!("{a}.in-addr.arpa."),
        format!("{b}.{a}.in-addr.arpa."),
    ]
    .into_iter()
    .find(|zone| zones.contains(zone))
}

// What: the PTR record name of an IPv4 address.
// Why: in-addr.arpa lists the octets in reverse order.
fn ptr_name_for_ipv4(ip: Ipv4Addr) -> String {
    let [a, b, c, d] = ip.octets();
    format!("{d}.{c}.{b}.{a}.in-addr.arpa.")
}

// What: the IPv4 address behind a PTR record name.
// Why: names of other shapes stay out of the address table.
fn ipv4_from_ptr_name(name: &str) -> Option<Ipv4Addr> {
    let lower = name.trim_end_matches('.').to_ascii_lowercase();
    let labels: Vec<&str> = lower.strip_suffix(".in-addr.arpa")?.split('.').collect();
    let [d, c, b, a] = labels.as_slice() else {
        return None;
    };
    Some(Ipv4Addr::new(
        a.parse().ok()?,
        b.parse().ok()?,
        c.parse().ok()?,
        d.parse().ok()?,
    ))
}

// What: a private IPv4 address, or None.
// Why: stored probe targets must not become an SSRF lever.
fn parse_private_ipv4(text: &str) -> Option<Ipv4Addr> {
    text.trim()
        .parse::<Ipv4Addr>()
        .ok()
        .filter(Ipv4Addr::is_private)
}

// What: outcome of one secondary SOA probe.
// Why: the page shows a status, never a raw error string.
#[derive(Serialize, Debug, PartialEq, Eq)]
struct ProbeResult {
    status: &'static str,
    serial: Option<u32>,
    detail: String,
}

// What: skip a DNS name; returns the offset after it.
// Why: compression pointers end a name after two bytes.
fn skip_dns_name(buf: &[u8], mut pos: usize) -> Option<usize> {
    loop {
        let len = *buf.get(pos)?;
        match len & 0xC0 {
            _ if len == 0 => return Some(pos + 1),
            0x00 => pos += 1 + len as usize,
            0xC0 => return Some(pos + 2),
            _ => return None,
        }
    }
}

// What: the SOA serial of the first answer, if parseable.
// Why: informational only; any oddity yields None.
fn soa_serial(buf: &[u8]) -> Option<u32> {
    let mut pos = skip_dns_name(buf, 12)? + 4;
    pos = skip_dns_name(buf, pos)?;
    if u16::from_be_bytes([*buf.get(pos)?, *buf.get(pos + 1)?]) != 6 {
        return None;
    }
    let rdata = pos + 10;
    let end = rdata + u16::from_be_bytes([*buf.get(pos + 8)?, *buf.get(pos + 9)?]) as usize;
    let at = skip_dns_name(buf, skip_dns_name(buf, rdata)?)?;
    (at + 4 <= end).then_some(())?;
    Some(u32::from_be_bytes(buf.get(at..at + 4)?.try_into().ok()?))
}

// What: classify an lan. SOA answer for the operator.
// Why: AA flag and RCODE tell served-here from relayed.
fn classify_soa(buf: &[u8], expected_id: u16) -> Result<ProbeResult, String> {
    if buf.len() < 12 {
        return Err("short DNS response (<12 bytes)".to_string());
    }
    if u16::from_be_bytes([buf[0], buf[1]]) != expected_id {
        return Err("DNS response transaction id mismatch".to_string());
    }
    if buf[2] & 0x80 == 0 {
        return Err("DNS message is not a response (QR bit unset)".to_string());
    }
    let authoritative = buf[2] & 0x04 != 0;
    let answers = u16::from_be_bytes([buf[6], buf[7]]) > 0;
    let serial = if answers { soa_serial(buf) } else { None };
    let (status, detail, serial) = match buf[3] & 0x0F {
        0 if authoritative && answers => (
            "ok",
            "answered authoritatively for lan. (SOA present)".to_string(),
            serial,
        ),
        0 if answers => (
            "not_authoritative",
            "returned an lan. answer but without the authoritative (AA) flag".to_string(),
            serial,
        ),
        0 => (
            "error",
            "NOERROR but no answer for lan. SOA".to_string(),
            None,
        ),
        5 => (
            "no_zone",
            "REFUSED -- host is not authoritative for lan. (zone not configured?)".to_string(),
            None,
        ),
        2 => (
            "broken",
            "SERVFAIL -- lan. zone present but the host failed to answer".to_string(),
            None,
        ),
        other => (
            "error",
            format!("unexpected DNS response code (RCODE {other})"),
            None,
        ),
    };
    Ok(ProbeResult {
        status,
        serial,
        detail,
    })
}

// What: a one-question DNS query for a zone's SOA.
// Why: any answer with a serial proves the zone serves.
fn soa_query(id: u16, zone: &str) -> Vec<u8> {
    let mut query = id.to_be_bytes().to_vec();
    query.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in zone.trim_end_matches('.').split('.') {
        query.push(label.len() as u8);
        query.extend_from_slice(label.as_bytes());
    }
    query.extend_from_slice(&[0, 0, 6, 0, 1]);
    query
}

// What: ask addr:port for the LAN zone SOA over UDP.
// Why: a silent host is a status, not an error.
async fn probe_secondary_soa(any: &str, addr: Ipv4Addr, port: u16, lan_zone: &str) -> ProbeResult {
    const TIMEOUT: Duration = Duration::from_secs(4);
    let id: u16 = rand::random();
    let query = soa_query(id, lan_zone);
    let exchange = async {
        let socket = tokio::net::UdpSocket::bind((any, 0))
            .await
            .map_err(|e| e.to_string())?;
        socket
            .connect((addr, port))
            .await
            .map_err(|e| e.to_string())?;
        socket.send(&query).await.map_err(|e| e.to_string())?;
        let mut buf = [0u8; 512];
        let n = socket.recv(&mut buf).await.map_err(|e| e.to_string())?;
        classify_soa(&buf[..n], id)
    };
    let unreachable = |detail: String| ProbeResult {
        status: "unreachable",
        serial: None,
        detail,
    };
    match tokio::time::timeout(TIMEOUT, exchange).await {
        Err(_) => unreachable(format!("no response from {addr}:{port} within {TIMEOUT:?}")),
        Ok(Err(e)) => unreachable(format!("DNS query to {addr}:{port} failed: {e}")),
        Ok(Ok(result)) => result,
    }
}
// What: account every issued user JWT names in aud.
// Why: a missing or wrong aud makes nats-server reject it.
const TARGET_ACCOUNT: &str = "$G";

// What: lifetime of an issued user JWT.
// Why: revocation is the per-connect DB check, not expiry.
const USER_JWT_TTL_SECS: i64 = 90 * 24 * 60 * 60;

// What: sleep, then take the next Backoff delay.
// Why: one backoff step for every NATS retry loop.
// From: Issue #849 | PR #1912
async fn backoff(delay: &mut Duration, policy: &Backoff) {
    tokio::time::sleep(*delay).await;
    *delay = policy.next(*delay);
}

// What: connect to NATS as one static role.
// Why: every ui connection authenticates by user/password.
async fn nats_connect(url: &str, login: &NatsLogin) -> Result<async_nats::Client, String> {
    async_nats::ConnectOptions::with_user_and_password(
        login.user.clone(),
        login.password.clone().unwrap_or_default(),
    )
    .connect(url)
    .await
    .map_err(|e| e.to_string())
}

// What: connect as the ui role, retrying without end.
// Why: the ui is useless until NATS is up; retry, not exit.
async fn connect_nats_with_retry(cfg: &Config) -> async_nats::Client {
    let mut delay = cfg.retry_backoff.start;
    loop {
        match nats_connect(&cfg.nats_url, &cfg.nats.ui).await {
            Ok(client) => {
                tracing::info!("Connected to NATS at {}", cfg.nats_url);
                return client;
            }
            Err(err) => {
                tracing::warn!(
                    "Cannot connect to NATS at {}: {err}. Retrying in {delay:?}",
                    cfg.nats_url
                );
                backoff(&mut delay, &cfg.retry_backoff).await;
            }
        }
    }
}

// What: the auth_callout stanza nats.conf includes.
// Why: only the ui knows the issuer and xkey public keys.
// From: Issue #811 | PR #1858
fn render_auth_callout_fragment(cfg: &Config, issuer: &str, xkey: &str) -> String {
    let users: Vec<String> = cfg
        .nats
        .labelled()
        .iter()
        .map(|(_, l)| format!("\"{}\"", l.user))
        .collect();
    format!(
        "auth_callout {{\n  issuer: \"{issuer}\"\n  xkey: \"{xkey}\"\n  auth_users: [{}]\n}}\n",
        users.join(", ")
    )
}

// What: write the auth_callout fragment when it changed.
// Why: nats-server starts only after this file exists.
// From: Issue #811 | PR #1912
fn write_callout_fragment(cfg: &Config, issuer: &str, xkey: &str) -> Result<(), String> {
    cfg.nats.validate()?;
    let fragment = render_auth_callout_fragment(cfg, issuer, xkey);
    write_if_changed(
        Path::new(&cfg.nats_auth_callout_path),
        fragment.as_bytes(),
        0o644,
        None,
    )
    .map(|_| ())
    .map_err(|e| e.to_string())
}

// What: base64url without padding.
// Why: the auth callout JWT uses exactly this alphabet.
fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

// What: a compact NATS JWT v2 signed with the issuer key.
// Why: no crate covers the auth-callout envelope.
fn encode_nats_jwt(mut claims: Value, signer: &KeyPair) -> Result<String, String> {
    claims["jti"] = json!("");
    let unsigned = serde_json::to_string(&claims).map_err(|e| e.to_string())?;
    claims["jti"] =
        json!(data_encoding::BASE32_NOPAD.encode(&Sha512_256::digest(unsigned.as_bytes())));
    let payload = serde_json::to_string(&claims).map_err(|e| e.to_string())?;
    let signing_input = format!(
        "{}.{}",
        b64url(br#"{"typ":"JWT","alg":"ed25519-nkey"}"#),
        b64url(payload.as_bytes())
    );
    let signature = signer
        .sign(signing_input.as_bytes())
        .map_err(|e| format!("failed to sign JWT: {e}"))?;
    Ok(format!("{signing_input}.{}", b64url(&signature)))
}

// What: the payload of a compact JWT, unverified.
// Why: user and password decide; no signature check.
fn decode_jwt_payload(token: &str) -> Result<Value, String> {
    let parts: Vec<&str> = token.split('.').collect();
    let [_, payload, _] = parts.as_slice() else {
        return Err("malformed JWT: expected 3 dot-separated parts".to_string());
    };
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|e| format!("failed to base64url-decode JWT payload: {e}"))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("failed to parse JWT payload: {e}"))
}

// What: Argon2id PHC hash of one password.
// Why: only the hash is stored; plaintext is shown once.
fn hash_password(password: &str) -> Result<String, String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|hash| hash.to_string())
        .map_err(|e| format!("failed to hash the password with Argon2id: {e}"))
}

// What: the PHC hash from its base64url env form.
// Why: a PHC string holds dollar signs; .env must not.
fn decode_password_hash(value: &str) -> Result<String, String> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .ok_or_else(|| "UI_AUTH_PASSWORD_HASH is no base64url value".to_string())
}

// What: true when the password matches the Argon2id hash.
// Why: the login compares against a hash only.
fn password_matches(stored_hash: &str, password: &str) -> bool {
    PasswordHash::new(stored_hash).is_ok_and(|hash| {
        Argon2::default()
            .verify_password(password.as_bytes(), &hash)
            .is_ok()
    })
}

// What: the secondary a user and password belong to.
// Why: a missing row and a wrong password look the same.
fn authorize_secondary(state: &AppState, nats_user: &str, password: &str) -> Option<String> {
    // What: no row is a quiet no; a DB fault is logged.
    // Why: AG-INT-002: a lock or query error stays visible.
    // From: Issue #1683 | PR #1912
    let stored: String = with_db(state, |db| {
        db.query_row(
            "SELECT nats_password_hash FROM secondaries WHERE nats_user = ?1",
            [nats_user],
            |row| row.get(0),
        )
        .optional()
    })
    .ok()??;
    let hash = PasswordHash::new(&stored).ok()?;
    Argon2::default()
        .verify_password(password.as_bytes(), &hash)
        .ok()
        .map(|()| nats_user.to_string())
}

// What: the signed authorization response for one request.
// Why: a user JWT with DNS-reader rights, or an error.
fn auth_callout_response(
    issuer: &KeyPair,
    server_id: &str,
    user_nkey: &str,
    authorized: Option<&str>,
) -> Result<String, String> {
    let now = unix_secs() as i64;
    if now == 0 {
        return Err("system clock is set before the Unix epoch".to_string());
    }
    let nats = match authorized {
        Some(name) => {
            let user_jwt = encode_nats_jwt(
                json!({
                    "iss": issuer.public_key(),
                    "sub": user_nkey,
                    "aud": TARGET_ACCOUNT,
                    "name": name,
                    "iat": now,
                    "exp": now + USER_JWT_TTL_SECS,
                    "nats": {
                        "pub": {"allow": dns_reader_publish()},
                        "sub": {"allow": dns_subscribe()},
                        "subs": -1, "data": -1, "payload": -1,
                        "type": "user", "version": 2
                    }
                }),
                issuer,
            )?;
            json!({"jwt": user_jwt, "type": "authorization_response", "version": 2})
        }
        None => json!({
            "error": "invalid secondary credentials",
            "type": "authorization_response", "version": 2
        }),
    };
    encode_nats_jwt(
        json!({
            "iss": issuer.public_key(),
            "sub": user_nkey,
            "aud": server_id,
            "iat": now,
            "nats": nats
        }),
        issuer,
    )
}

// What: answer one auth-callout request.
// Why: an xkey-sealed request gets a response sealed back.
async fn answer_auth_callout(
    state: &AppState,
    issuer: &KeyPair,
    xkey: &XKey,
    client: &async_nats::Client,
    msg: async_nats::Message,
) -> Result<(), String> {
    let reply = msg.reply.clone().ok_or("request with no reply subject")?;
    // What: sealed when nats-server sends its xkey.
    // Why: no local switch; an unsealed request works.
    // From: Issue #682
    let sender = match msg.headers.as_ref().and_then(|h| h.get("Nats-Server-Xkey")) {
        Some(key) => Some(
            XKey::from_public_key(key.as_str())
                .map_err(|e| format!("invalid Nats-Server-Xkey header: {e}"))?,
        ),
        None => None,
    };
    let plain = match &sender {
        Some(sender) => xkey
            .open(&msg.payload, sender)
            .map_err(|e| format!("failed to open sealed request: {e}"))?,
        None => msg.payload.to_vec(),
    };
    let request = decode_jwt_payload(&String::from_utf8_lossy(&plain))?;
    let nats = &request["nats"];
    let field = |value: &Value| value.as_str().unwrap_or_default().to_string();
    let user = field(&nats["connect_opts"]["user"]);
    let authorized = authorize_secondary(state, &user, &field(&nats["connect_opts"]["pass"]));
    tracing::info!(
        "auth-callout: connect attempt user={user} authorized={}",
        authorized.is_some()
    );
    let response = auth_callout_response(
        issuer,
        &field(&nats["server_id"]["id"]),
        &field(&nats["user_nkey"]),
        authorized.as_deref(),
    )?;
    let payload = match &sender {
        Some(sender) => xkey
            .seal(response.as_bytes(), sender)
            .map_err(|e| format!("failed to seal response: {e}"))?,
        None => response.into_bytes(),
    };
    client
        .publish(reply, payload.into())
        .await
        .map_err(|e| format!("failed to publish response: {e}"))
}

// What: serve $SYS.REQ.USER.AUTH for the process life.
// Why: the row is checked per connect; removal is instant.
// From: Issue #583
async fn run_auth_callout(state: Arc<AppState>, issuer: KeyPair, xkey: XKey) {
    let policy = state.config.retry_backoff;
    let mut delay = policy.start;
    loop {
        let client = match nats_connect(&state.config.nats_url, &state.config.nats.callout).await {
            Ok(client) => {
                delay = policy.start;
                client
            }
            Err(err) => {
                tracing::warn!(
                    "auth-callout: cannot connect to NATS: {err}. Retrying in {delay:?}"
                );
                backoff(&mut delay, &policy).await;
                continue;
            }
        };
        let mut sub = match client.subscribe("$SYS.REQ.USER.AUTH").await {
            Ok(sub) => sub,
            Err(err) => {
                tracing::error!("auth-callout: failed to subscribe: {err}");
                backoff(&mut delay, &policy).await;
                continue;
            }
        };
        tracing::info!("auth-callout: responder ready");
        while let Some(msg) = sub.next().await {
            if let Err(err) = answer_auth_callout(&state, &issuer, &xkey, &client, msg).await {
                tracing::warn!("auth-callout: {err}");
            }
        }
        tracing::warn!("auth-callout: subscription ended, reconnecting");
    }
}

// What: disconnect every live connection of one NATS user.
// Why: a removed secondary would keep its connection.
// From: Issue #681
async fn kick_secondary(state: &AppState, nats_user: &str) -> Result<usize, String> {
    const STEP: Duration = Duration::from_secs(5);
    if state.config.nats.sys.user.is_empty() {
        return Err("NATS_SYS_USER is not configured".to_string());
    }
    let client = tokio::time::timeout(
        STEP,
        nats_connect(&state.config.nats_url, &state.config.nats.sys),
    )
    .await
    .map_err(|_| "timed out connecting to NATS as the system account".to_string())??;
    let ask = |subject: String, body: Value| {
        let client = client.clone();
        async move {
            let reply = tokio::time::timeout(
                STEP,
                client.request(subject, body.to_string().into_bytes().into()),
            )
            .await
            .map_err(|_| "request timed out".to_string())?
            .map_err(|e| format!("request failed: {e}"))?;
            serde_json::from_slice::<Value>(&reply.payload).map_err(|e| format!("bad reply: {e}"))
        }
    };
    let connz = ask(
        "$SYS.REQ.SERVER.PING.CONNZ".to_string(),
        json!({"auth": true, "user": nats_user}),
    )
    .await?;
    if let Some(err) = connz.get("error").filter(|e| !e.is_null()) {
        return Err(format!("CONNZ request returned an error: {err}"));
    }
    let server_id = connz["server"]["id"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let mut kicked = 0;
    for conn in connz["data"]["connections"]
        .as_array()
        .into_iter()
        .flatten()
    {
        let Some(cid) = conn["cid"].as_u64() else {
            continue;
        };
        match ask(
            format!("$SYS.REQ.SERVER.{server_id}.KICK"),
            json!({"cid": cid}),
        )
        .await
        {
            Ok(reply) if reply.get("error").is_none_or(Value::is_null) => kicked += 1,
            Ok(reply) => tracing::warn!("nats_kick: KICK for cid {cid} returned {reply}"),
            Err(err) => tracing::warn!("nats_kick: KICK for cid {cid} failed: {err}"),
        }
    }
    if let Err(err) = client.drain().await {
        tracing::warn!("nats_kick: drain failed: {err}");
    }
    Ok(kicked)
}

// What: kick in the background once the DB change commits.
// Why: the DB write revokes; NATS must not delay the reply.
fn kick_in_background(state: &Arc<AppState>, name: &str, action: &'static str) {
    let (state, name) = (Arc::clone(state), name.to_string());
    tokio::spawn(async move {
        match kick_secondary(&state, &name).await {
            Ok(0) => tracing::debug!("nats_kick: {action} secondary {name} had no live connection"),
            Ok(n) => tracing::info!(
                "nats_kick: disconnected {n} connection(s) of {action} secondary {name}"
            ),
            Err(err) => tracing::warn!("nats_kick: failed for {action} secondary {name}: {err}"),
        }
    });
}

// What: form fields of a secondary registration.
// Why: the token proves the operator issued the request.
#[derive(Deserialize)]
struct RegisterForm {
    token: String,
    name: String,
    #[serde(default)]
    address: Option<String>,
}

// What: what a secondary receives after registering.
// Why: it needs the NATS endpoint and its own credentials.
#[derive(Serialize)]
struct RegisterResponse {
    nats_url: String,
    nats_user: String,
    nats_password: String,
    consumer_name: String,
    ip_http: String,
    pdns_api_key: String,
    ddns_tsig_key: String,
    dns_xfr_primary: String,
    image_registry: String,
    image_prefix: String,
    image_channel: String,
    image_tag: String,
}

// What: one registered secondary for the page.
// Why: the template needs name, address and probe state.
#[derive(Serialize, Clone)]
struct Secondary {
    name: String,
    consumer_name: String,
    registered_at: i64,
    last_seen: Option<i64>,
    address: Option<String>,
}

// What: run a DB statement; any failure is HTTP 500.
// Why: the lock and error mapping repeat in every handler.
fn with_db<T>(
    state: &AppState,
    f: impl FnOnce(&Connection) -> rusqlite::Result<T>,
) -> Result<T, StatusCode> {
    // What: log the cause before it becomes a bare 500.
    // Why: AG-INT-002: the DB error must stay visible.
    // From: Issue #1683 | PR #1912
    let conn = state.db.lock().map_err(|e| {
        tracing::error!("database lock poisoned: {e}");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    f(&conn).map_err(|e| {
        tracing::error!("database statement failed: {e}");
        StatusCode::INTERNAL_SERVER_ERROR
    })
}

// What: true for the configured registration token.
// Why: an unset token must never mean open registration.
fn registration_token_ok(state: &AppState, presented: &str) -> bool {
    let token = &state.config.secondary_registration_token;
    !token.is_empty() && ct_eq(presented, token)
}

// What: a fresh NATS password.
// Why: plaintext is shown once; only its hash is stored.
fn new_nats_password() -> String {
    hex32()
}

// What: render the secondaries page.
// Why: operators see registrations and probe status here.
async fn secondaries_page(
    State(state): Shared,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let secondaries = with_db(&state, |db| {
        db.prepare(
            "SELECT name, consumer_name, registered_at, last_seen, address \
             FROM secondaries ORDER BY registered_at DESC",
        )?
        .query_map([], |row| {
            Ok(Secondary {
                name: row.get(0)?,
                consumer_name: row.get(1)?,
                registered_at: row.get(2)?,
                last_seen: row.get(3)?,
                address: row.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()
    })
    .unwrap_or_else(|e| {
        tracing::error!("secondaries not read: {e}");
        Vec::new()
    });
    let mut ctx = page_ctx(&headers, "secondaries");
    ctx.insert("secondaries", &secondaries);
    ctx.insert(
        "primary_url",
        &format!(
            "http://{}:{}",
            state.config.http_ip, state.config.listen_port
        ),
    );
    ctx.insert("primary_ip", &state.config.http_ip);
    ctx.insert("setup_script_url", &state.config.setup_script_url);
    ctx.insert(
        "registration_token",
        &state.config.secondary_registration_token,
    );
    Ok(render(&state, "secondaries.html", &ctx))
}

// What: register a secondary and hand out its NATS login.
// Why: setup.sh secondary calls it, gated by the token.
// From: Issue #583
async fn register_secondary(
    State(state): Shared,
    Json(form): Json<RegisterForm>,
) -> Result<Json<RegisterResponse>, StatusCode> {
    if !registration_token_ok(&state, &form.token) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let valid_name = !form.name.is_empty()
        && form.name.len() <= 32
        && form
            .name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !valid_name {
        return Err(StatusCode::BAD_REQUEST);
    }
    // What: fail before any side effect without a NATS URL.
    // Why: the internal URL is unreachable remotely.
    // From: Issue #866
    let Some(nats_url) = state.config.advertised_nats_url.clone() else {
        tracing::error!(
            secondary_name = %form.name,
            "refusing secondary registration: neither NATS_ADVERTISE_URL nor NATS_BIND_IP is set"
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    };
    let tsig_path = Path::new(&state.config.shared_secret_dir).join("ddns-tsig-key");
    let ddns_tsig_key = fs::read_to_string(&tsig_path)
        .map(|key| key.trim().to_string())
        .ok()
        .filter(|key| !key.is_empty())
        .ok_or_else(|| {
            tracing::error!(path = %tsig_path.display(), "refusing secondary registration: no shared DDNS TSIG key");
            StatusCode::SERVICE_UNAVAILABLE
        })?;
    let nats_password = new_nats_password();
    let hash = hash_password(&nats_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let reported = form
        .address
        .as_deref()
        .and_then(parse_private_ipv4)
        .map(|ip| ip.to_string());
    // What: keep a stored address when none is reported.
    // Why: re-registration must not wipe a manual override.
    // From: Issue #1084
    with_db(&state, |db| {
        db.execute(
            "INSERT OR REPLACE INTO secondaries \
             (name, consumer_name, nats_token, nats_user, nats_password_hash, registered_at, last_seen, address) \
             VALUES (?1, ?1, '', ?1, ?2, ?3, NULL, \
             COALESCE(?4, (SELECT address FROM secondaries WHERE name = ?1)))",
            rusqlite::params![form.name, hash, unix_secs() as i64, reported],
        )
    })?;
    Ok(Json(RegisterResponse {
        nats_url,
        nats_user: form.name.clone(),
        nats_password,
        consumer_name: form.name,
        ip_http: state.config.http_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
        ddns_tsig_key,
        dns_xfr_primary: format!("{}:{}", state.config.http_ip, state.config.pdns_auth_port),
        image_registry: state.config.lancache_image_registry.clone(),
        image_prefix: state.config.lancache_image_prefix.clone(),
        image_channel: state.config.lancache_image_channel.clone(),
        image_tag: state.config.lancache_image_tag.clone(),
    }))
}

// What: delete a secondary and kick its connection.
// Why: a removed secondary must lose its live session.
async fn remove_secondary(
    State(state): Shared,
    AxPath(name): AxPath<String>,
) -> Result<Json<Value>, StatusCode> {
    let removed = with_db(&state, |db| {
        db.execute("DELETE FROM secondaries WHERE name = ?", [&name])
    })?;
    if removed == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    kick_in_background(&state, &name, "removed");
    Ok(Json(json!({"ok": true})))
}

// What: form field of a secondary address change.
// Why: the probe address is set by hand if none was found.
#[derive(Deserialize)]
struct SetAddressForm {
    address: String,
}

// What: set a secondary's probe address by hand.
// Why: the fallback if detection found none; private only.
// From: Issue #1084
async fn set_secondary_address(
    State(state): Shared,
    AxPath(name): AxPath<String>,
    Json(form): Json<SetAddressForm>,
) -> Result<Json<Value>, StatusCode> {
    let addr = parse_private_ipv4(&form.address).ok_or(StatusCode::BAD_REQUEST)?;
    let changed = with_db(&state, |db| {
        db.execute(
            "UPDATE secondaries SET address = ? WHERE name = ?",
            [addr.to_string(), name.clone()],
        )
    })?;
    if changed == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(json!({"ok": true, "address": addr.to_string()})))
}

// What: probe a secondary's DNS and report the status.
// Why: a healthy answer is the only writer of last_seen.
// From: Issue #1084
async fn check_secondary_health(
    State(state): Shared,
    AxPath(name): AxPath<String>,
) -> Result<Json<Value>, StatusCode> {
    let stored = with_db(&state, |db| {
        db.query_row(
            "SELECT address FROM secondaries WHERE name = ?",
            [&name],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
    })?
    .ok_or(StatusCode::NOT_FOUND)?;
    let Some(addr) = stored.as_deref().and_then(parse_private_ipv4) else {
        return Ok(Json(json!({
            "status": "no_address",
            "serial": Value::Null,
            "detail": "no reachable address on record for this secondary -- set one to enable the health check",
        })));
    };
    // What: probe DNS_PORT, the secondary's own DNS.
    // Why: PDNS_AUTH_PORT is the primary's PowerDNS port.
    let result = probe_secondary_soa(
        &state.config.any_bind,
        addr,
        state.config.dns_port,
        &state.config.lan_zone,
    )
    .await;
    if result.status == "ok" {
        // What: a lost last_seen write is logged.
        // Why: the probe succeeded; the reply says so.
        // From: Issue #1683 | PR #1912
        if let Err(status) = with_db(&state, |db| {
            db.execute(
                "UPDATE secondaries SET last_seen = ? WHERE name = ?",
                rusqlite::params![unix_secs() as i64, name],
            )
        }) {
            tracing::warn!("last_seen of secondary {name} not updated: {status}");
        }
    }
    Ok(Json(json!({
        "status": result.status,
        "serial": result.serial,
        "detail": result.detail,
    })))
}

// What: form field of a secondary token rotation.
// Why: the registration token authorizes the rotation.
#[derive(Deserialize)]
struct RotateForm {
    token: String,
}

// What: give one secondary a new NATS password.
// Why: the old hash is overwritten, so it stops working.
// From: Issue #583
async fn rotate_token(
    State(state): Shared,
    AxPath(name): AxPath<String>,
    Json(form): Json<RotateForm>,
) -> Result<Json<Value>, StatusCode> {
    if !registration_token_ok(&state, &form.token) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let nats_password = new_nats_password();
    let hash = hash_password(&nats_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let changed = with_db(&state, |db| {
        db.execute(
            "UPDATE secondaries SET nats_password_hash = ? WHERE name = ?",
            [&hash, &name],
        )
    })?;
    if changed == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    kick_in_background(&state, &name, "rotated");
    Ok(Json(
        json!({"nats_user": name, "nats_password": nats_password}),
    ))
}

// What: Kea error texts that mean "not found".
// Why: kea_modify maps exactly these to a 404.
const KEA_SUBNET_MISSING: &str = "subnet not found";
const KEA_OPTION_MISSING: &str = "custom option not found";

// What: BOOTP subnet fields shown as custom options.
// Why: Kea keeps them top-level, not in option-data.
const PXE_FIELDS: [&str; 3] = ["next-server", "server-hostname", "boot-file-name"];

// What: settings the /dhcp page shows, as (context, key).
// Why: one list feeds both the page and the template names.
const PAGE_SETTINGS: [(&str, &str); 11] = [
    ("dhcp_dns_primary", "DHCP_DNS_PRIMARY"),
    ("dhcp_dns_secondary", "DHCP_DNS_SECONDARY"),
    ("dhcp_ntp_servers", "DHCP_NTP_SERVERS"),
    ("dhcp_proxy_subnet_start", "DHCP_SUBNET_START"),
    ("dhcp_upstream_dhcp_ip", "UPSTREAM_DHCP_IP"),
    ("dhcp_relay_local_addr", "DHCP_RELAY_LOCAL_ADDR"),
    ("dhcp_proxy_interface", "DHCP_PROXY_INTERFACE"),
    ("dhcp_proxy_router", "DHCP_PROXY_ROUTER"),
    ("dhcp_proxy_domain", "DHCP_PROXY_DOMAIN"),
    ("dhcp_proxy_boot_filename", "DHCP_PROXY_BOOT_FILENAME"),
    ("dhcp_proxy_boot_server", "DHCP_PROXY_BOOT_SERVER"),
];

// What: one subnet as the /dhcp page shows it.
// Why: the page needs plain fields, not Kea option arrays.
#[derive(Serialize)]
struct Subnet {
    id: u32,
    subnet: String,
    pool_start: String,
    pool_end: String,
    gateway: String,
    dns_primary: String,
    dns_secondary: String,
    ntp_servers: String,
    lease_time: u32,
    domain: String,
    custom_options: Vec<CustomOption>,
}

// What: one custom DHCP option of a subnet.
// Why: the page lists them with a remove button each.
#[derive(Serialize)]
struct CustomOption {
    code: u16,
    data: String,
}

// What: one active lease; expires is a Unix time string.
// Why: the page formats the time in the browser.
#[derive(Serialize)]
struct Lease {
    subnet_id: u32,
    ip: String,
    mac: String,
    hostname: String,
    expires: String,
}

// What: one static reservation as the page shows it.
// Why: Kea nests them in subnets; the page lists them flat.
#[derive(Serialize)]
struct Reservation {
    subnet_id: u32,
    ip: String,
    mac: String,
    hostname: String,
}

// What: id and creation time of one Kea snapshot.
// Why: the page never gets the config, only a handle.
#[derive(Serialize)]
struct SnapshotSummary {
    id: String,
    created_unix: u64,
}

// What: a DHCP error page with a status.
// Why: every DHCP failure returns to /dhcp the same way.
fn dhcp_error(status: StatusCode, message: impl Into<String>) -> HtmlError {
    HtmlError::new(status, &DHCP_AREA, message)
}

// What: a 400 for input the operator can fix.
// Why: the form was readable; the values were not valid.
fn invalid(message: impl Into<String>) -> HtmlError {
    dhcp_error(StatusCode::BAD_REQUEST, message)
}

// What: a 500 for a backend that did not do its job.
// Why: the request was fine; the server side failed.
fn fail(message: impl Into<String>) -> HtmlError {
    dhcp_error(StatusCode::INTERNAL_SERVER_ERROR, message)
}

// What: true when Kea mode is on and its API URL is set.
// Why: a half-configured Kea must count as not available.
fn kea_available(state: &AppState) -> bool {
    state.config.dhcp_mode().is_kea() && !state.config.dhcp_api_url.is_empty()
}

// What: refuse a Kea change outside Kea mode.
// Why: a clear 409 beats an obscure Kea API failure.
fn require_kea(state: &AppState) -> Result<(), HtmlError> {
    if kea_available(state) {
        return Ok(());
    }
    Err(dhcp_error(
        StatusCode::CONFLICT,
        "DHCP mutations require Kea mode with a configured Kea API URL.",
    ))
}

// What: write DHCP settings; a failure shows a DHCP error.
// Why: save_settings keeps every other key intact.
fn save_dhcp_settings(state: &AppState, changes: &[(&str, String)]) -> Result<(), HtmlError> {
    state.config.save_settings(changes).map_err(|e| {
        fail(format!(
            "Failed to persist DHCP settings to {}: {e}",
            state.config.ui_settings_file
        ))
    })
}

// What: send one Kea command; transport errors become text.
// Why: callers must tell a lost request from a Kea refusal.
async fn kea_post(
    state: &AppState,
    command: &str,
    arguments: Option<&Value>,
) -> Result<Value, String> {
    let mut body = json!({"command": command, "service": ["dhcp4"]});
    if let Some(arguments) = arguments {
        body["arguments"] = arguments.clone();
    }
    state
        .http_client
        .post(format!("{}/", state.config.dhcp_api_url))
        .basic_auth(
            &state.config.dhcp_api_user,
            Some(&state.config.dhcp_api_token),
        )
        .json(&body)
        .send()
        .await
        .map_err(|e| error_chain(&e))?
        .json::<Value>()
        .await
        .map_err(|e| error_chain(&e))
}

// What: the outcome of one Kea command.
// Why: one owner reads Kea's result, text and arguments.
// From: Issue #1683 | PR #1912
#[derive(Debug, PartialEq)]
enum Kea {
    // What: result 0, with the reply's arguments.
    // Why: the caller reads its answer from the arguments.
    Done(Value),
    // What: result 3, Kea's "nothing found".
    // Why: an empty search is not an error.
    Empty(String),
    // What: any other result, with Kea's text.
    // Why: the text tells the operator what Kea rejected.
    Refused(String),
    // What: no answer: transport or JSON error.
    // Why: a lost request may still have applied.
    Lost(String),
}

// What: map Kea's first reply to one outcome.
// Why: Kea answers a list and reports errors in a 200.
// From: Issue #1683 | PR #1912
fn kea_outcome(reply: &Value) -> Kea {
    let first = reply.get(0);
    let text = first
        .and_then(|r| r.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("Kea error")
        .to_string();
    match first.and_then(|r| r.get("result")).and_then(Value::as_i64) {
        Some(0) => Kea::Done(
            first
                .and_then(|r| r.get("arguments"))
                .cloned()
                .unwrap_or(Value::Null),
        ),
        Some(3) => Kea::Empty(text),
        _ => Kea::Refused(text),
    }
}

// What: send a command and read its outcome.
// Why: every Kea caller branches on this one type.
// From: Issue #1683 | PR #1912
async fn kea_send(state: &AppState, command: &str, arguments: Option<&Value>) -> Kea {
    match kea_post(state, command, arguments).await {
        Ok(reply) => kea_outcome(&reply),
        Err(e) => Kea::Lost(e),
    }
}

// What: send a command and require result code 0.
// Why: config-get, -test and -set all share this rule.
async fn kea_run(
    state: &AppState,
    command: &str,
    arguments: Option<&Value>,
) -> Result<Value, String> {
    match kea_send(state, command, arguments).await {
        Kea::Done(arguments) => Ok(arguments),
        Kea::Empty(e) | Kea::Refused(e) | Kea::Lost(e) => Err(e),
    }
}

// What: Kea's running config without the hash key.
// Why: Kea refuses its own hash key on config-test/-set.
async fn kea_config(state: &AppState) -> Result<Value, String> {
    let mut config = kea_run(state, "config-get", None).await?;
    if config.is_null() {
        return Err("config-get: missing arguments".into());
    }
    if let Some(map) = config.as_object_mut() {
        map.remove("hash");
    }
    Ok(config)
}

// What: the snapshot store of Kea configs.
// Why: ui writes it, the dhcp container shares the volume.
fn kea_store(config: &Config) -> SnapshotStore {
    SnapshotStore::new(
        PathBuf::from(&config.kea_config_snapshot_dir),
        "dhcp4.json",
        "kea",
    )
}

// What: put the old config back after a refused write.
// Why: runtime and disk must not silently disagree.
async fn kea_rollback(state: &AppState, old: &Value, write_error: &str) -> Result<(), String> {
    match kea_run(state, "config-set", Some(old)).await {
        Ok(_) => {
            tracing::warn!(error = %write_error, "DHCP config rollback succeeded");
            Err("Config change failed to persist and was rolled back; no change was made.".into())
        }
        Err(e) => {
            let message = format!(
                "Config applied at runtime but NOT persisted to disk — runtime and persisted \
                 config may now differ. Write failed: {write_error}. Rollback also failed: {e}"
            );
            tracing::error!(error = %message, "DHCP config rollback failed");
            Err(message)
        }
    }
}

// What: change Kea's config: get, edit, test, set, write.
// Why: one locked chain with rollback keeps Kea consistent.
async fn kea_apply(
    state: &AppState,
    change: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
) -> Result<(), String> {
    // What: hold the lock for the whole chain.
    // Why: two concurrent edits would overwrite each other.
    let _guard = state.kea_config_lock.lock().await;

    let mut config = kea_config(state).await?;
    let old = config.clone();
    change(&mut config)?;
    kea_run(state, "config-test", Some(&config)).await?;
    kea_run(state, "config-set", Some(&config)).await?;

    // What: save the applied config as a good snapshot.
    // Why: a failed snapshot weakens rollback, not the edit
    let record = || {
        let keep = state.config.kea_keep_known_good_configs;
        if let Err(e) = kea_store(&state.config).create(&config, keep) {
            tracing::warn!(error = %e, "failed to record a known-good Kea snapshot");
        }
    };
    // What: persist the running config to disk.
    // Why: a lost request may have applied; no refusal.
    match kea_send(state, "config-write", None).await {
        Kea::Done(_) => {
            record();
            Ok(())
        }
        Kea::Empty(e) | Kea::Refused(e) => {
            tracing::warn!(error = %e, "DHCP config-write failed; rolling back");
            kea_rollback(state, &old, &e).await
        }
        // What: one retry if the write outcome is unknown.
        // Why: blind rollback could undo a landed write.
        Kea::Lost(first) => match kea_send(state, "config-write", None).await {
            Kea::Done(_) => {
                record();
                Ok(())
            }
            Kea::Empty(retry) | Kea::Refused(retry) => Err(format!(
                "Config applied at runtime but the first config-write result was ambiguous, \
                 and a retry returned a Kea failure. Runtime and persisted config may now \
                 differ. First error: {first}. Retry error: {retry}"
            )),
            Kea::Lost(retry) => Err(format!(
                "Config applied at runtime but config-write could not be confirmed after \
                 retry. Runtime and persisted config may now differ. First error: {first}. \
                 Retry error: {retry}"
            )),
        },
    }
}

// What: kea_apply, then back to the DHCP page.
// Why: a missing subnet or option is a 404, not a failure.
// From: Issue #1683 | PR #1912
async fn kea_modify(
    state: &AppState,
    change: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
) -> Result<Redirect, HtmlError> {
    kea_apply(state, change).await.map_err(|message| {
        let status = match message.as_str() {
            KEA_SUBNET_MISSING | KEA_OPTION_MISSING => StatusCode::NOT_FOUND,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        dhcp_error(status, message)
    })?;
    Ok(Redirect::to(PAGE_DHCP))
}

// What: the subnet4 entries of a config; none if malformed.
// Why: display paths show nothing rather than an error.
fn subnets_in(config: &Value) -> &[Value] {
    config
        .get("Dhcp4")
        .and_then(|d| d.get("subnet4"))
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

// What: the editable subnet4 array of a config.
// Why: each missing level gets its own debug message.
fn subnets_mut(config: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    config
        .get_mut("Dhcp4")
        .ok_or("Dhcp4 missing")?
        .get_mut("subnet4")
        .ok_or("subnet4 missing")?
        .as_array_mut()
        .ok_or("subnet4 not an array")
}

// What: one editable subnet by id.
// Why: a missing subnet maps to a 404 in kea_modify.
fn find_subnet_mut(config: &mut Value, id: u32) -> Result<&mut Value, &'static str> {
    subnets_mut(config)?
        .iter_mut()
        .find(|s| s["id"].as_u64() == Some(u64::from(id)))
        .ok_or(KEA_SUBNET_MISSING)
}

// What: a text field of a JSON object, or a default.
// Why: Kea JSON is read defensively; a wrong type is empty.
fn text_of<'a>(value: &'a Value, key: &str, default: &'a str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or(default)
}

// What: true for an option in the dhcp4 option space.
// Why: Kea omits "space" for dhcp4, so absence means yes.
fn is_dhcp4_option(option: &Value) -> bool {
    option
        .get("space")
        .and_then(Value::as_str)
        .is_none_or(|s| s == "dhcp4")
}

// What: true for an option a dedicated subnet field owns.
// Why: routers, DNS, domain and NTP have their own inputs.
fn is_managed_option(option: &Value) -> bool {
    let by_name = matches!(
        text_of(option, "name", ""),
        "routers" | "domain-name" | "domain-search" | "domain-name-servers" | "ntp-servers"
    );
    let by_code = option
        .get("code")
        .and_then(Value::as_u64)
        .is_some_and(|code| KEA_MANAGED_CODES.iter().any(|m| u64::from(*m) == code));
    is_dhcp4_option(option) && (by_name || by_code)
}

// What: true for an operator-added numbered option.
// Why: only those are listed, added and removed by code.
fn is_custom_option(option: &Value) -> bool {
    is_dhcp4_option(option)
        && !is_managed_option(option)
        && option
            .get("code")
            .and_then(Value::as_u64)
            .is_some_and(|code| {
                (u64::from(OPTION_CODE_MIN)..=u64::from(OPTION_CODE_MAX)).contains(&code)
            })
        && option.get("data").is_some_and(Value::is_string)
}

// What: split a Kea option list at commas and spaces.
// Why: Kea writes commas; operators paste whitespace lists.
fn split_list(raw: &str) -> Vec<String> {
    raw.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

// What: a subnet4 entry as the page read-model.
// Why: options are found by name or code; both are legal.
fn read_subnet(subnet: &Value, default_lease: u32) -> Subnet {
    let pool = subnet
        .get("pools")
        .and_then(|p| p.get(0))
        .map_or("", |p| text_of(p, "pool", ""));
    let (pool_start, pool_end) = pool.split_once(" - ").unwrap_or((pool, ""));
    let option = |name: &str, code: u64| -> String {
        subnet
            .get("option-data")
            .and_then(Value::as_array)
            .and_then(|options| {
                options.iter().find(|o| {
                    is_dhcp4_option(o)
                        && (text_of(o, "name", "") == name
                            || o.get("code").and_then(Value::as_u64) == Some(code))
                })
            })
            .map_or("", |o| text_of(o, "data", ""))
            .to_string()
    };
    let dns = split_list(&option("domain-name-servers", 6));
    let custom_options = subnet
        .get("option-data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|o| is_custom_option(o))
        .filter_map(|o| {
            Some(CustomOption {
                code: u16::try_from(o.get("code")?.as_u64()?).ok()?,
                data: o.get("data")?.as_str()?.to_string(),
            })
        })
        .collect();
    Subnet {
        id: subnet.get("id").and_then(Value::as_u64).unwrap_or(0) as u32,
        subnet: text_of(subnet, "subnet", "").to_string(),
        pool_start: pool_start.trim().to_string(),
        pool_end: pool_end.trim().to_string(),
        gateway: option("routers", 3),
        dns_primary: dns.first().cloned().unwrap_or_default(),
        dns_secondary: dns.get(1).cloned().unwrap_or_default(),
        ntp_servers: option("ntp-servers", 42),
        // What: default lease time if the subnet sets none.
        // Why: the page shows what dhcp would hand out.
        lease_time: subnet
            .get("valid-lifetime")
            .and_then(Value::as_u64)
            .unwrap_or(default_lease.into()) as u32,
        domain: option("domain-name", 15),
        custom_options,
    }
}

// What: all reservations of a config, tagged by subnet.
// Why: the page lists them flat; Kea nests them per subnet.
fn read_reservations(config: &Value) -> Vec<Reservation> {
    subnets_in(config)
        .iter()
        .flat_map(|subnet| {
            let subnet_id = subnet.get("id").and_then(Value::as_u64).unwrap_or(0) as u32;
            subnet
                .get("reservations")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(move |r| Reservation {
                    subnet_id,
                    ip: text_of(r, "ip-address", "?").to_string(),
                    mac: r
                        .get("hw-address")
                        .and_then(Value::as_str)
                        .map_or_else(|| "?".to_string(), normalize_mac),
                    hostname: text_of(r, "hostname", "").to_string(),
                })
        })
        .collect()
}

// What: all active leases from Kea's lease database.
// Why: leases are runtime state, not part of the config.
async fn kea_leases(state: &AppState) -> Result<Vec<Lease>, String> {
    // What: Empty is Kea's "0 leases found".
    // Why: any other refusal must not look like no lease.
    // From: Issue #1683 | PR #1912
    let arguments = match kea_send(state, "lease4-get-all", None).await {
        Kea::Done(arguments) => arguments,
        Kea::Empty(_) => return Ok(Vec::new()),
        Kea::Refused(e) | Kea::Lost(e) => return Err(e),
    };
    Ok(arguments
        .get("leases")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|lease| {
            let seconds = |key: &str| lease.get(key).and_then(Value::as_i64).unwrap_or(0);
            Lease {
                subnet_id: lease.get("subnet-id").and_then(Value::as_u64).unwrap_or(0) as u32,
                ip: text_of(lease, "ip-address", "?").to_string(),
                mac: text_of(lease, "hw-address", "?").to_string(),
                hostname: text_of(lease, "hostname", "").to_string(),
                // What: last renewal plus lease length.
                // Why: the page shows an absolute expiry.
                expires: (seconds("cltt") + seconds("valid-lft")).to_string(),
            }
        })
        .collect())
}

// What: the settings page with live Kea data if reachable.
// Why: an unreachable Kea renders empty tables, no error.
async fn dhcp_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "dhcp");
    ctx.insert("dhcp_mode", cfg.dhcp_mode().as_str());
    ctx.insert("dhcp_has_kea", &cfg.dhcp_mode().is_kea());
    ctx.insert("dhcp_api_url", &cfg.dhcp_api_url);
    ctx.insert("default_lease_time", &cfg.dhcp_lease_time);
    ctx.insert("dhcp_domain", &cfg.lan_zone);
    for (name, key) in PAGE_SETTINGS {
        ctx.insert(name, &cfg.setting(key));
    }
    // What: show stored options one per line.
    // Why: the storage form joins them with semicolons.
    let options_form = cfg
        .setting("DHCP_PROXY_CUSTOM_OPTIONS")
        .split(';')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    ctx.insert("dhcp_proxy_custom_options_form", &options_form);
    ctx.insert(
        "ntp_auto_dhcp_active",
        &(cfg.flag("NTP_ENABLED") && cfg.flag("NTP_AUTO_DHCP")),
    );

    let (mut subnets, mut ddns, mut reservations) = (Vec::new(), false, Vec::new());
    let mut leases = Vec::new();
    if kea_available(&state) {
        // What: read config and leases at the same time.
        // Why: a Kea with many leases loads slowly.
        let (config, found) = tokio::join!(kea_config(&state), kea_leases(&state));
        match config {
            Ok(config) => {
                subnets = subnets_in(&config)
                    .iter()
                    .map(|subnet| read_subnet(subnet, state.config.dhcp_lease_time))
                    .collect();
                ddns = config["Dhcp4"]["dhcp-ddns"]["enable-updates"]
                    .as_bool()
                    .unwrap_or(false);
                reservations = read_reservations(&config);
            }
            Err(e) => tracing::warn!("Kea config not read for the DHCP page: {e}"),
        }
        leases = found.unwrap_or_else(|e| {
            tracing::warn!("Kea leases not read for the DHCP page: {e}");
            Vec::new()
        });
    }
    ctx.insert("subnets", &subnets);
    ctx.insert("dhcp_ddns_enabled", &ddns);
    ctx.insert("leases", &leases);
    ctx.insert("reservations", &reservations);

    // What: snapshots newest first, with creation times.
    // Why: operators pick a rollback target, newest first.
    let snapshots: Vec<SnapshotSummary> = kea_store(cfg)
        .ids()
        .unwrap_or_else(|e| {
            tracing::warn!("Kea snapshots not listed: {e}");
            Vec::new()
        })
        .into_iter()
        .rev()
        .map(|id| SnapshotSummary {
            created_unix: snapshot_created_unix(&id).unwrap_or(0),
            id,
        })
        .collect();
    ctx.insert("kea_snapshots", &snapshots);
    ctx.insert("kea_snapshot_retention", &cfg.kea_keep_known_good_configs);
    render(&state, "dhcp.html", &ctx)
}

// What: an IPv4 address from text, or None.
// Why: every address field uses this one strict parse.
fn ipv4(text: &str) -> Option<Ipv4Addr> {
    text.trim().parse().ok()
}

// What: a MAC of 12 hex digits, colons or hyphens allowed.
// Why: both spellings are common copy-paste sources.
fn is_valid_mac(mac: &str) -> bool {
    let digits: Vec<char> = mac.chars().filter(|c| !matches!(c, ':' | '-')).collect();
    digits.len() == 12 && digits.iter().all(char::is_ascii_hexdigit)
}

// What: a MAC as lowercase colon-separated hex pairs.
// Why: Kea reservations and form input must compare equal.
fn normalize_mac(mac: &str) -> String {
    let digits: Vec<char> = mac
        .chars()
        .filter(char::is_ascii_hexdigit)
        .map(|c| c.to_ascii_lowercase())
        .collect();
    digits
        .chunks(2)
        .map(|pair| pair.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(":")
}

// What: a network address and mask from "a.b.c.d/N".
// Why: host bits must be zero so the field names a network.
fn parse_cidr(text: &str) -> Option<(u32, u32)> {
    let (address, prefix) = text.split_once('/')?;
    let network = u32::from(ipv4(address)?);
    let prefix: u32 = prefix.parse().ok().filter(|p| *p <= 32)?;
    let mask = u32::MAX.checked_shl(32 - prefix).unwrap_or(0);
    if network & !mask != 0 {
        return None;
    }
    Some((network & mask, mask))
}

// What: a short interface name such as eth0 or br-lan.100.
// Why: the value lands unquoted in dnsmasq's interface line
fn is_valid_interface_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

// What: a PXE boot file name without separators/controls.
// Why: a comma would shift fields in dhcp-boot=file,,server
fn is_valid_boot_filename(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 255
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c == ',' || c.is_control())
}

// What: check the subnet form; return lease time and CIDR.
// Why: pool, gateway and subnet depend on each other.
fn validate_subnet(f: &Fields, limits: &LeaseLimits) -> Result<(u32, (u32, u32)), String> {
    let cidr = parse_cidr(f.get("subnet"))
        .ok_or("Invalid subnet: use a network such as 198.51.100.0/24 with host bits zero.")?;
    let address = |key: &str, message: &'static str| ipv4(f.get(key)).ok_or(message);
    let start = address("pool_start", "Invalid pool start address.")?;
    let end = address("pool_end", "Invalid pool end address.")?;
    let gateway = address("gateway", "Invalid gateway address.")?;
    address("dns_primary", "Invalid primary DNS address.")?;
    if !f.get("dns_secondary").is_empty() {
        address("dns_secondary", "Invalid secondary DNS address.")?;
    }
    let inside = |ip: Ipv4Addr| u32::from(ip) & cidr.1 == cidr.0;
    if !(inside(start) && inside(end) && inside(gateway)) || u32::from(start) > u32::from(end) {
        return Err(
            "Pool and gateway must lie inside the subnet, and the pool start must not follow its end."
                .into(),
        );
    }
    let ntp = f.get("ntp_servers");
    if !ntp.is_empty() && split_list(ntp).is_empty() {
        return Err("Invalid NTP servers: use a list of addresses or host names.".into());
    }
    let domain = f.get("domain");
    if !domain.is_empty() && !is_valid_domain_name(domain) {
        return Err(
            "Invalid domain: use a plain DNS domain name (letters, digits, '-', '.').".into(),
        );
    }
    let lease = limits
        .lease(&|_| Some(f.get("lease_time").to_string()), "lease_time")
        .map_err(|_| {
            format!(
                "Lease time must be between {} and {} seconds.",
                limits.min, limits.max
            )
        })?;
    Ok((lease, cidr))
}

// What: NTP entries as one list of IPv4 literals.
// Why: Kea option 42 takes addresses; names resolve here.
// From: Issue #670
async fn resolve_ntp_servers(raw: &str) -> Result<String, String> {
    let mut resolved = Vec::new();
    for entry in split_list(raw) {
        let address = match entry.parse::<Ipv4Addr>() {
            Ok(address) => address,
            // What: reject non-address dotted digits.
            // Why: a typo like 1.2.3 must not reach DNS.
            Err(_) if entry.chars().all(|c| c.is_ascii_digit() || c == '.') => {
                return Err(format!("NTP server '{entry}' is not a valid IPv4 address"));
            }
            Err(_) => tokio::net::lookup_host(format!("{entry}:0"))
                .await
                .map_err(|_| {
                    format!("NTP server '{entry}' is not an IPv4 address and could not be resolved via DNS")
                })?
                .find_map(|found| match found.ip() {
                    IpAddr::V4(v4) => Some(v4),
                    IpAddr::V6(_) => None,
                })
                .ok_or_else(|| format!("NTP server '{entry}' resolved but has no IPv4 address"))?,
        };
        resolved.push(address.to_string());
    }
    Ok(resolved.join(", "))
}

// What: write the form's values into one subnet4 entry.
// Why: add and edit share it; edit keeps custom options.
fn apply_subnet(
    entry: &mut Value,
    f: &Fields,
    id: u32,
    lease: u32,
    ntp: &str,
    cidr: (u32, u32),
    limits: &LeaseLimits,
) -> Result<(), &'static str> {
    let max_lifetime = limits.max_lifetime(lease);
    let mut options: Vec<Value> = entry
        .get("option-data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|o| !is_managed_option(o))
        .cloned()
        .collect();
    let (primary, secondary) = (f.get("dns_primary"), f.get("dns_secondary"));
    // What: omit a blank or repeated second DNS server.
    // Why: a duplicate would imply two distinct servers.
    let dns = if secondary.is_empty() || secondary == primary {
        primary.to_string()
    } else {
        format!("{primary}, {secondary}")
    };
    options.push(json!({"name": "routers", "data": f.get("gateway")}));
    options.push(json!({"name": "domain-name-servers", "data": dns}));
    options.push(json!({"name": "domain-name", "data": f.get("domain")}));
    options.push(json!({"name": "domain-search", "data": f.get("domain")}));
    if !ntp.is_empty() {
        options.push(json!({"name": "ntp-servers", "data": ntp}));
    }
    // What: keep reservations that fit the new subnet.
    // Why: Kea rejects a subnet with foreign reservations.
    let reservations = entry
        .get("reservations")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|r| {
                    r.get("ip-address")
                        .and_then(Value::as_str)
                        .and_then(ipv4)
                        .is_none_or(|ip| u32::from(ip) & cidr.1 == cidr.0)
                })
                .cloned()
                .collect::<Vec<_>>()
        });
    let object = entry.as_object_mut().ok_or("subnet not an object")?;
    object.insert("id".into(), json!(id));
    object.insert("subnet".into(), json!(f.get("subnet")));
    object.insert(
        "pools".into(),
        json!([{"pool": format!("{} - {}", f.get("pool_start"), f.get("pool_end"))}]),
    );
    object.insert("option-data".into(), Value::Array(options));
    object.insert("valid-lifetime".into(), json!(lease));
    object.insert("max-valid-lifetime".into(), json!(max_lifetime));
    object.remove("default-lease-time");
    object.remove("max-lease-time");
    // What: drop a subnet-level reservation id list.
    // Why: Kea accepts that key only globally, not here.
    object.remove("host-reservation-identifiers");
    if let Some(reservations) = reservations {
        object.insert("reservations".into(), Value::Array(reservations));
    }
    Ok(())
}

// What: a custom option key: option number or PXE field.
// Why: both share one form field and one set of routes.
#[derive(Clone, Copy)]
enum CustomOptionKey {
    Numeric(u16),
    Pxe(&'static str),
}

// What: parse the code field of a custom option form.
// Why: the five managed codes use their own fields only.
fn custom_option_key(raw: &str) -> Result<CustomOptionKey, &'static str> {
    let raw = raw.trim();
    if let Some(field) = PXE_FIELDS.into_iter().find(|field| *field == raw) {
        return Ok(CustomOptionKey::Pxe(field));
    }
    let code = option_code(raw)?;
    if KEA_MANAGED_CODES.contains(&code) {
        return Err("option code is managed by dedicated subnet fields");
    }
    Ok(CustomOptionKey::Numeric(code))
}

// What: option data checked against what the key accepts.
// Why: next-server needs an IPv4; BOOTP fields are capped.
fn custom_option_data(key: CustomOptionKey, raw: &str) -> Result<String, &'static str> {
    match key {
        CustomOptionKey::Pxe("next-server") => ipv4(raw)
            .map(|ip| ip.to_string())
            .ok_or("next-server must be a valid IPv4 address"),
        CustomOptionKey::Pxe(field) => {
            let data = option_data(raw)?;
            let max = if field == "server-hostname" { 64 } else { 128 };
            if data.len() > max {
                return Err("value is too long for this field");
            }
            Ok(data)
        }
        CustomOptionKey::Numeric(_) => option_data(raw),
    }
}

// What: add or remove one custom option on a subnet.
// Why: add and remove share option and PXE key handling.
fn edit_custom_option(
    subnet: &mut Value,
    key: CustomOptionKey,
    data: &str,
    add: bool,
) -> Result<(), &'static str> {
    let object = subnet.as_object_mut().ok_or("subnet not an object")?;
    match key {
        CustomOptionKey::Pxe(field) => {
            let current = object.get(field).and_then(Value::as_str);
            match (add, current == Some(data)) {
                (true, true) => return Err("custom option already exists"),
                (true, false) => object.insert(field.to_string(), json!(data)),
                // What: clear a field only if unchanged.
                // Why: stale pages must not undo edits.
                (false, true) => object.remove(field),
                (false, false) => return Err(KEA_OPTION_MISSING),
            };
        }
        CustomOptionKey::Numeric(code) => {
            let options = object
                .entry("option-data")
                .or_insert_with(|| json!([]))
                .as_array_mut()
                .ok_or("option-data not an array")?;
            let same = |o: &Value| {
                is_custom_option(o)
                    && o.get("code").and_then(Value::as_u64) == Some(u64::from(code))
                    && o.get("data").and_then(Value::as_str) == Some(data)
            };
            if add {
                // What: refuse an identical option twice.
                // Why: a double submit would apply both.
                if options.iter().any(same) {
                    return Err("custom option already exists");
                }
                options.push(json!({"space": "dhcp4", "code": code, "data": data}));
            } else {
                let before = options.len();
                options.retain(|o| !same(o));
                if options.len() == before {
                    return Err(KEA_OPTION_MISSING);
                }
            }
        }
    }
    Ok(())
}

// What: set the ntp-servers option of one subnet.
// Why: the NTP sync must not rebuild gateway/DNS/domain.
fn set_subnet_ntp(subnet: &mut Value, servers: &str) -> Result<(), &'static str> {
    let options = subnet
        .get_mut("option-data")
        .and_then(Value::as_array_mut)
        .ok_or("subnet option-data missing or not an array")?;
    options.retain(|o| {
        !(is_dhcp4_option(o)
            && (text_of(o, "name", "") == "ntp-servers"
                || o.get("code").and_then(Value::as_u64) == Some(42)))
    });
    if !servers.is_empty() {
        options.push(json!({"name": "ntp-servers", "data": servers}));
    }
    Ok(())
}

// What: true unless a global id list lacks hw-address.
// Why: such a reservation would be saved but never matched.
fn identifiers_include_hw_address(config: &Value) -> bool {
    match config["Dhcp4"].get("host-reservation-identifiers") {
        None => true,
        Some(list) => list
            .as_array()
            .is_some_and(|ids| ids.iter().any(|id| id.as_str() == Some("hw-address"))),
    }
}

// What: add a reservation or update the one for that MAC.
// Why: a repeated submit edits the device, no duplicate.
fn upsert_reservation(
    subnet: &mut Value,
    mac: &str,
    ip: &str,
    hostname: &str,
) -> Result<(), &'static str> {
    let list = subnet
        .as_object_mut()
        .ok_or("subnet not an object")?
        .entry("reservations")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or("reservations not an array")?;
    let same_mac = |r: &Value| {
        r.get("hw-address")
            .and_then(Value::as_str)
            .map(normalize_mac)
            .as_deref()
            == Some(mac)
    };
    match list.iter_mut().find(|r| same_mac(r)) {
        // What: touch only address, name and MAC spelling.
        // Why: Kea keeps its own fields on the entry.
        Some(existing) => {
            let object = existing
                .as_object_mut()
                .ok_or("existing reservation not an object")?;
            object.insert("hw-address".into(), json!(mac));
            object.insert("ip-address".into(), json!(ip));
            object.insert("hostname".into(), json!(hostname));
        }
        None => list.push(json!({
            "hw-address": mac,
            "ip-address": ip,
            "hostname": hostname,
            "option-data": [],
            "client-classes": []
        })),
    }
    Ok(())
}

// What: the subnet id in form field key; 400 if missing.
// Why: one owner for subnet, option, reservation forms.
// From: Issue #1683 | PR #1912
fn subnet_id(f: &Fields, key: &str) -> Result<u32, HtmlError> {
    f.number::<u32>(key)
        .ok_or_else(|| invalid("Missing subnet id."))
}

// What: limits, lease, CIDR and NTP list of a subnet form.
// Why: NTP names resolve before the sync edit; bad = 400.
// From: Issue #1683 | PR #1912
async fn read_subnet_form(
    state: &AppState,
    f: &Fields,
) -> Result<(LeaseLimits, u32, (u32, u32), String), HtmlError> {
    let limits = state.config.dhcp_lease_limits;
    let (lease, cidr) = validate_subnet(f, &limits).map_err(invalid)?;
    let ntp = resolve_ntp_servers(f.get("ntp_servers"))
        .await
        .map_err(invalid)?;
    Ok((limits, lease, cidr, ntp))
}

// What: create a subnet with the next free id.
// Why: ids need only be unique; max plus one never clashes.
async fn add_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let (limits, lease, cidr, ntp) = read_subnet_form(&state, &f).await?;
    kea_modify(&state, move |config| {
        let subnets = subnets_mut(config)?;
        let id = subnets
            .iter()
            .filter_map(|s| s["id"].as_u64())
            .max()
            .map_or(1, |max| max + 1) as u32;
        let mut entry = json!({});
        apply_subnet(&mut entry, &f, id, lease, &ntp, cidr, &limits)?;
        subnets.push(entry);
        Ok(())
    })
    .await
}

// What: edit one subnet in place, found by id.
// Why: custom options and fitting reservations carry over.
async fn update_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let id = subnet_id(&f, "id")?;
    let (limits, lease, cidr, ntp) = read_subnet_form(&state, &f).await?;
    kea_modify(&state, move |config| {
        apply_subnet(
            find_subnet_mut(config, id)?,
            &f,
            id,
            lease,
            &ntp,
            cidr,
            &limits,
        )
    })
    .await
}

// What: delete a subnet with its pools and reservations.
// Why: the last known-good snapshot is the way back.
async fn remove_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let id = subnet_id(&f, "id")?;
    kea_modify(&state, move |config| {
        subnets_mut(config)?.retain(|s| s["id"].as_u64() != Some(u64::from(id)));
        Ok(())
    })
    .await
}

// What: add or remove a custom option, matched by code+data
// Why: both need the same parsing so values compare equal
async fn change_subnet_option(
    state: &AppState,
    f: Fields,
    add: bool,
) -> Result<Redirect, HtmlError> {
    require_kea(state)?;
    let wrong = |m: &str| invalid(format!("Invalid DHCP option: {m}"));
    let key = custom_option_key(f.get("code")).map_err(wrong)?;
    let data = custom_option_data(key, f.get("data")).map_err(wrong)?;
    let id = subnet_id(&f, "subnet_id")?;
    kea_modify(state, move |config| {
        edit_custom_option(find_subnet_mut(config, id)?, key, &data, add)
    })
    .await
}

// What: add one custom option to a subnet.
// Why: the shared handler needs only the add flag.
async fn add_subnet_option(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    change_subnet_option(&state, f, true).await
}

// What: remove one custom option from a subnet.
// Why: the shared handler needs only the add flag.
async fn remove_subnet_option(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    change_subnet_option(&state, f, false).await
}

// What: add or update a static reservation by MAC.
// Why: a repeated submit must edit, never duplicate.
async fn add_reservation(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let (mac, ip, hostname) = (f.get("mac"), f.get("ip"), f.get("hostname"));
    if !is_valid_mac(mac) || ipv4(ip).is_none() {
        return Err(invalid("Invalid MAC or IPv4 address."));
    }
    // What: validate a hostname only when one is given.
    // Why: a blank hostname is a supported reservation.
    if !hostname.is_empty() && !is_valid_domain_name(hostname) {
        return Err(invalid(
            "Invalid hostname: use a plain DNS domain name (letters, digits, '-', '.').",
        ));
    }
    let id = subnet_id(&f, "subnet_id")?;
    let (mac, ip, hostname) = (normalize_mac(mac), ip.to_string(), hostname.to_string());
    kea_modify(&state, move |config| {
        // What: refuse if Kea ignores hw-address entries.
        // Why: a hand-edited global list defeats this.
        if !identifiers_include_hw_address(config) {
            return Err(
                "cannot add a hw-address reservation: this Kea config's global \
                 Dhcp4.host-reservation-identifiers list does not include \
                 \"hw-address\", so Kea would never match it",
            );
        }
        upsert_reservation(find_subnet_mut(config, id)?, &mac, &ip, &hostname)
    })
    .await
}

// What: remove a static reservation by MAC; none is fine.
// Why: the end state, no reservation, is the same.
async fn remove_reservation(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    if !is_valid_mac(f.get("mac")) {
        return Err(invalid("Invalid MAC address."));
    }
    let id = subnet_id(&f, "subnet_id")?;
    let mac = normalize_mac(f.get("mac"));
    kea_modify(&state, move |config| {
        let subnet = find_subnet_mut(config, id)?;
        if let Some(list) = subnet.get_mut("reservations").and_then(Value::as_array_mut) {
            list.retain(|r| {
                r.get("hw-address")
                    .and_then(Value::as_str)
                    .map(normalize_mac)
                    .as_deref()
                    != Some(mac.as_str())
            });
        }
        Ok(())
    })
    .await
}

// What: switch Kea's DDNS master switch.
// Why: DDNS is a different decision from issuing addresses.
// From: Issue #1076
async fn update_dhcp_ddns(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let enabled = parse_bool(f.get("enabled")).unwrap_or(false);
    kea_modify(&state, move |config| {
        let ddns = config
            .get_mut("Dhcp4")
            .and_then(Value::as_object_mut)
            .ok_or("Dhcp4 missing")?
            .entry("dhcp-ddns")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or("dhcp-ddns not an object")?;
        ddns.insert("enable-updates".into(), json!(enabled));
        Ok(())
    })
    .await
}

// What: roll Kea back to a chosen known-good snapshot.
// Why: only ids found on disk are accepted, no raw input.
async fn rollback_kea_snapshot(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let store = kea_store(&state.config);
    let id = f.get("snapshot_id");
    let known = store.ids().map_err(|e| {
        fail(format!(
            "Failed to list known-good Kea config snapshots: {e}"
        ))
    })?;
    if !known.iter().any(|known_id| known_id == id) {
        return Err(dhcp_error(
            StatusCode::CONFLICT,
            "Unknown or no-longer-available config snapshot.",
        ));
    }
    let snapshot = store.read(id).map_err(|e| {
        store.log(
            "REJECT",
            &format!("rejected known-good snapshot {id}: unreadable ({e:#})"),
        );
        fail(format!("Stored config snapshot could not be read: {e:#}"))
    })?;
    kea_apply(&state, move |config| {
        *config = snapshot;
        Ok(())
    })
    .await
    .map_err(|e| {
        store.log(
            "REJECT",
            &format!("rejected known-good snapshot {id}: failed validation/apply ({e})"),
        );
        fail(format!("Rollback to snapshot {id} failed: {e}"))
    })?;
    store.log(
        "SELECT",
        &format!("selected known-good snapshot {id} for rollback"),
    );
    Ok(Redirect::to(PAGE_DHCP))
}

// What: send a record delete event over NATS.
// Why: PowerDNS applies deletes from the subject of adds.
async fn publish_delete(state: &AppState, zone: &str, name: &str, kind: &str) {
    let record = record_event(zone.into(), name.into(), kind.into(), None);
    if let Err(e) = publish_record(state, &record).await {
        tracing::error!(
            zone,
            name,
            kind,
            "NATS publish of DDNS record delete failed: {e}"
        );
    }
}

// What: delete the A and PTR records of a released lease.
// Why: Kea's lease4-del sends no DDNS removal on its own.
// From: Issue #1083
async fn cleanup_lease_records(state: &AppState, ip: Ipv4Addr, hostname: Option<&str>) {
    // What: the forward record only for a host with a zone.
    // Why: a bare host name has no parent zone.
    if let Some(host) = hostname {
        let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
        if let Some((_, zone)) = host.split_once('.').filter(|(_, zone)| !zone.is_empty()) {
            publish_delete(state, zone, &format!("{host}."), "A").await;
        }
    }
    // What: the reverse record only in a provisioned zone.
    // Why: no PowerDNS zone exists for other addresses.
    if let Some(zone) = reverse_zone_for_ipv4(ip) {
        publish_delete(state, &zone, &ptr_name_for_ipv4(ip), "PTR").await;
    }
}

// What: end an active lease early via lease4-del.
// Why: a runtime action needs no config-modify chain.
async fn release_lease(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let ip = f.get("ip");
    let address = ipv4(ip).ok_or_else(|| invalid("Lease release requires a valid IPv4 address"))?;
    let arguments = json!({"ip-address": ip});
    // What: read the lease's hostname before deleting it.
    // Why: only the A-record cleanup below needs the name.
    let hostname = match kea_send(&state, "lease4-get", Some(&arguments)).await {
        Kea::Done(lease) => lease
            .get("hostname")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_string),
        // What: no lease; lease4-del answers below.
        // Why: a missing lease is not a failure here.
        Kea::Empty(_) => None,
        Kea::Refused(e) | Kea::Lost(e) => {
            tracing::warn!(ip, error = %e, "lease hostname not read; A record kept");
            None
        }
    };
    match kea_send(&state, "lease4-del", Some(&arguments)).await {
        Kea::Done(_) => {
            // What: clean DNS records after a release.
            // Why: best effort; the address is freed.
            cleanup_lease_records(&state, address, hostname.as_deref()).await;
            Ok(Redirect::to(PAGE_DHCP))
        }
        // What: Empty means no such lease.
        // Why: an expired lease is a race, not a failure.
        Kea::Empty(_) => Err(dhcp_error(
            StatusCode::NOT_FOUND,
            format!(
                "No active lease found for {ip}; it may have already expired or been released."
            ),
        )),
        Kea::Refused(e) | Kea::Lost(e) => Err(fail(e)),
    }
}

// What: point every Kea subnet at the right NTP servers.
// Why: the NTP auto toggle owns that option while it is on.
// From: Issue #1079
async fn sync_subnet_ntp(state: &AppState, auto: bool) -> Result<(), String> {
    if !kea_available(state) {
        return Ok(());
    }
    // What: the LAN address if auto, else the default.
    // Why: auto off hands the option back to one value.
    let servers = if auto {
        state.config.http_ip.clone()
    } else {
        resolve_ntp_servers(&state.config.setting("DHCP_NTP_SERVERS"))
            .await
            .unwrap_or_else(|e| {
                tracing::warn!("DHCP_NTP_SERVERS not resolved, none set: {e}");
                String::new()
            })
    };
    kea_apply(state, move |config| {
        for subnet in subnets_mut(config)?.iter_mut() {
            set_subnet_ntp(subnet, &servers)?;
        }
        Ok(())
    })
    .await
}

// What: switch the stack between the DHCP backends.
// Why: the ui saves; the dhcp supervisor starts the mode.
// From: Issue #1486 | PR #1912
async fn update_dhcp_mode(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    let raw = f.get("dhcp_mode").to_ascii_lowercase();
    let Some(mode) = DhcpMode::from_name(&raw) else {
        return Err(dhcp_error(
            StatusCode::CONFLICT,
            "Invalid DHCP mode requested.",
        ));
    };
    save_dhcp_settings(&state, &[("DHCP_MODE", mode.as_str().to_string())])?;
    // What: push the NTP address to Kea after the switch.
    // Why: best effort; Kea may still be starting up.
    if mode.is_kea()
        && state.config.flag("NTP_ENABLED")
        && state.config.flag("NTP_AUTO_DHCP")
        && let Err(e) = sync_subnet_ntp(&state, true).await
    {
        tracing::warn!(error = %e, "failed to push the NTP address into Kea subnets; the next NTP or DHCP save retries");
    }
    Ok(Redirect::to(PAGE_DHCP))
}

// What: the error text of a bad upstream DHCP server.
// Why: proxy and relay forms check the same field alike.
const UPSTREAM_DHCP_INVALID: &str = "Invalid upstream DHCP server: must be an IPv4 address.";

// What: validate and save the dnsmasq-proxy settings.
// Why: a typo should fail here, not at dnsmasq start.
// From: Issue #450
async fn update_dhcp_proxy(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    // What: an IPv4 check and a list-of-addresses check.
    // Why: the optional-field table below takes functions.
    fn address(value: &str) -> bool {
        ipv4(value).is_some()
    }
    type Check = fn(&str) -> bool;
    fn address_list(value: &str) -> bool {
        value
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .all(address)
    }
    let required: [(&str, &str); 2] = [
        (
            "dhcp_subnet_start",
            "Invalid relay subnet start: must be an IPv4 address.",
        ),
        ("upstream_dhcp_ip", UPSTREAM_DHCP_INVALID),
    ];
    for (key, message) in required {
        if !address(f.get(key)) {
            return Err(invalid(message));
        }
    }
    // What: check optional fields only when filled.
    // Why: blank takes config::dhcp_dns_fallback.
    let optional: [(&str, &str, Check); 8] = [
        (
            "dhcp_dns_primary",
            "Invalid primary DNS: must be an IPv4 address.",
            address,
        ),
        (
            "dhcp_dns_secondary",
            "Invalid secondary DNS: must be an IPv4 address.",
            address,
        ),
        (
            "dhcp_proxy_interface",
            "Invalid relay/proxy listen interface: use only letters, digits, '.', '-', or '_'.",
            is_valid_interface_name,
        ),
        (
            "dhcp_proxy_router",
            "Invalid router/gateway option: must be a valid IPv4 address.",
            address,
        ),
        (
            "dhcp_ntp_servers",
            "Invalid NTP servers option: must be a comma-separated list of IPv4 addresses.",
            address_list,
        ),
        (
            "dhcp_proxy_domain",
            "Invalid domain option: use a plain DNS domain name (letters, digits, '-', '.').",
            is_valid_domain_name,
        ),
        (
            "dhcp_proxy_boot_filename",
            "Invalid PXE boot filename: no whitespace, commas, or control characters.",
            is_valid_boot_filename,
        ),
        (
            "dhcp_proxy_boot_server",
            "Invalid PXE boot server address: must be a valid IPv4 address.",
            address,
        ),
    ];
    for (key, message, valid) in optional {
        if !f.get(key).is_empty() && !valid(f.get(key)) {
            return Err(invalid(message));
        }
    }
    // What: a boot server needs a boot filename.
    // Why: dhcp-boot= would otherwise lack its file field.
    if !f.get("dhcp_proxy_boot_server").is_empty() && f.get("dhcp_proxy_boot_filename").is_empty() {
        return Err(invalid(
            "A PXE boot server address requires a boot filename; a server address alone is not meaningful.",
        ));
    }
    let custom = parse_custom_options(f.get("dhcp_proxy_custom_options"))
        .map_err(|m| invalid(format!("Invalid custom DHCP option: {m}")))?;
    let text = |key: &str| f.get(key).to_string();
    save_dhcp_settings(
        &state,
        &[
            ("DHCP_SUBNET_START", text("dhcp_subnet_start")),
            ("DHCP_DNS_PRIMARY", text("dhcp_dns_primary")),
            ("DHCP_DNS_SECONDARY", text("dhcp_dns_secondary")),
            ("UPSTREAM_DHCP_IP", text("upstream_dhcp_ip")),
            ("DHCP_NTP_SERVERS", text("dhcp_ntp_servers")),
            ("DHCP_PROXY_INTERFACE", text("dhcp_proxy_interface")),
            ("DHCP_PROXY_ROUTER", text("dhcp_proxy_router")),
            ("DHCP_PROXY_DOMAIN", text("dhcp_proxy_domain")),
            ("DHCP_PROXY_BOOT_FILENAME", text("dhcp_proxy_boot_filename")),
            ("DHCP_PROXY_BOOT_SERVER", text("dhcp_proxy_boot_server")),
            ("DHCP_PROXY_CUSTOM_OPTIONS", custom),
        ],
    )?;
    Ok(Redirect::to(PAGE_DHCP))
}

// What: validate and save the DHCP relay settings.
// Why: the relay has its own two fields, apart from proxy.
// From: Issue #844
async fn update_dhcp_relay(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    if ipv4(f.get("dhcp_relay_local_addr")).is_none() {
        return Err(invalid(
            "Relay local address must be a valid IPv4 address (this relay's own IP on the client network).",
        ));
    }
    if ipv4(f.get("upstream_dhcp_ip")).is_none() {
        return Err(invalid(UPSTREAM_DHCP_INVALID));
    }
    save_dhcp_settings(
        &state,
        &[
            ("UPSTREAM_DHCP_IP", f.get("upstream_dhcp_ip").to_string()),
            (
                "DHCP_RELAY_LOCAL_ADDR",
                f.get("dhcp_relay_local_addr").to_string(),
            ),
        ],
    )?;
    Ok(Redirect::to(PAGE_DHCP))
}

// What: ui wait limit for one probe answer.
// Why: worst case is 8 s of probing; 30 s covers a tick.
const PROBE_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

// What: ask the dhcp supervisor for one probe run.
// Why: the ui has no Docker; a request file starts it.
// From: Issue #947 | PR #1912
async fn check_dhcp_conflict(State(state): Shared) -> Json<Value> {
    // What: one probe request at a time.
    // Why: a second request would replace the first id.
    let _guard = state.dhcp_probe_lock.lock().await;
    let unavailable = |reason: String| Json(ProbeReport::unavailable(reason).page());
    let id = hex32();
    let request = Path::new(&state.config.dhcp_probe_request_file);
    if let Err(e) = write_file(request, id.as_bytes(), 0o644, Place::Replace) {
        return unavailable(format!("cannot write {}: {e}", request.display()));
    }
    let deadline = Instant::now() + PROBE_WAIT_TIMEOUT;
    while Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let answer = fs::read_to_string(&state.config.dhcp_probe_result_file)
            .ok()
            .and_then(|raw| serde_json::from_str::<ProbeAnswer>(&raw).ok());
        if let Some(answer) = answer.filter(|a| a.id == id) {
            return Json(answer.page);
        }
    }
    unavailable(format!(
        "no DHCP probe answer within {}s; is the dhcp container running?",
        PROBE_WAIT_TIMEOUT.as_secs()
    ))
}
// What: TTL limits for operator records, in seconds.
// Why: 2^31-1 is the RFC 2181 ceiling; above it reads as 0.
const MAX_TTL: u32 = 2_147_483_647;

// What: longest TXT content the ui accepts, in bytes.
// Why: a DNS message is 65535 bytes less 549 for framing.
const MAX_TXT_BYTES: usize = 64_986;

// What: the line that splits shipped from added entries.
// Why: shipped defaults toggle; added entries can remove.
// From: Issue #1073
const CUSTOM_DOMAINS_MARKER: &str =
    "# ==== lancache-ng: entries added via the Admin UI are appended below this exact line ====";

// What: one CDN list entry; wildcard_only drops the root.
// Why: root and wildcard-only lines are independent entries
#[derive(Clone, PartialEq, Eq)]
struct CdnDomain {
    wildcard_only: bool,
    domain: String,
}

// What: which lines a removal deletes.
// Why: malformed legacy lines must stay removable by text.
enum DeleteTarget {
    Domain(CdnDomain),
    Raw(String),
}

// What: one CDN list row as the page shows it.
// Why: invalid lines stay visible so they can be removed.
#[derive(Serialize)]
struct DomainRow {
    raw: String,
    display: String,
    enabled: bool,
    is_default: bool,
    is_valid: bool,
}

// What: one LAN record set from PowerDNS.
// Why: the page lists name, type, ttl and each content.
#[derive(Clone, Deserialize, Serialize)]
struct RRset {
    name: String,
    #[serde(rename = "type")]
    record_type: String,
    ttl: u32,
    records: Vec<RecordContent>,
}

// What: one record of a set.
// Why: disabled records are shown but not served.
#[derive(Clone, Deserialize, Serialize)]
struct RecordContent {
    content: String,
    disabled: bool,
}

// What: one PTR row; sort_key orders by address.
// Why: PowerDNS cannot tell manual from DDNS-made PTRs.
// From: Issue #1077
#[derive(Serialize)]
struct PtrRow {
    ip: String,
    hostname: String,
    ttl: u32,
    #[serde(skip)]
    sort_key: u32,
}

// What: one zone's snapshots for the rollback table.
// Why: the table groups by zone, newest snapshot first.
#[derive(Serialize)]
struct ZoneSnapshotGroup {
    zone: String,
    snapshots: Vec<SnapshotSummary>,
}

// What: a fixed banner text for an error code, or None.
// Why: a URL parameter must never become page text.
fn domain_error_message(code: &str) -> Option<&'static str> {
    match code {
        "invalid_domain" => Some(
            "That domain was not added: CDN entries need a real domain name, not just a bare \
             top-level domain (e.g. \"steamcontent.com\", not \"com\"). A leading \".\" for a \
             wildcard/subdomain-only scope is fine (e.g. \".steamcontent.com\").",
        ),
        "ddns_allow_unsigned_no_key" => Some(
            "Allowing unsigned DNS updates was not enabled: no real DDNS_TSIG_KEY is currently \
             configured, so no zone actually has TSIG-based update enforcement to relax yet \
             -- this toggle would have no effect. Configure DDNS_TSIG_KEY first (see \
             docs/threat-model.md), then try again.",
        ),
        "zone_rollback_failed" => Some(
            "The zone rollback did not complete: nats-subscriber rejected the request outright \
             (a non-2xx response). No known-good snapshot was applied. Check the DNS service \
             logs for the exact reason, then try again.",
        ),
        "zone_rollback_unknown" => Some(
            "The zone rollback request timed out or the connection was lost before a result \
             could be confirmed. It may have already been applied on the DNS service side \
             despite this uncertain result -- check the DNS service logs to confirm the actual \
             outcome before retrying, to avoid an unnecessary duplicate rollback.",
        ),
        _ => None,
    }
}

// What: a plain domain name as DHCP and NTP forms take it.
// Why: letters, digits and hyphens; no trailing dot.
fn is_valid_domain_name(raw: &str) -> bool {
    is_dns_name(raw, false, false)
}

// What: a fully qualified name: ends in a dot, 253 bytes.
// Why: PowerDNS record names and targets need the dot.
fn is_fqdn(name: &str, underscore: bool, wildcard: bool) -> bool {
    name.len() <= 253
        && name
            .strip_suffix('.')
            .is_some_and(|bare| is_dns_name(bare, underscore, wildcard))
}

// What: a CDN entry from text, or None.
// Why: two labels at least; a leading dot is wildcard-only
fn parse_cdn_domain(text: &str) -> Option<CdnDomain> {
    config::cdn_entry(text).map(|(domain, wildcard_only)| CdnDomain {
        wildcard_only,
        domain,
    })
}

// What: a list line as entry and enabled flag.
// Why: a leading ! marks a disabled shipped default.
fn stored_line(line: &str) -> Option<(CdnDomain, bool)> {
    let line = line.trim();
    let (enabled, rest) = match line.strip_prefix('!') {
        Some(rest) => (false, rest),
        None => (true, line),
    };
    parse_cdn_domain(rest).map(|domain| (domain, enabled))
}

// What: the on-disk text of an entry.
// Why: the inverse of stored_line; the proxy reads the file
fn stored_text(domain: &CdnDomain, enabled: bool) -> String {
    format!(
        "{}{}{}",
        if enabled { "" } else { "!" },
        if domain.wildcard_only { "." } else { "" },
        domain.domain
    )
}

// What: split text into (line, terminator) pairs.
// Why: kept lines keep their own CRLF or LF; \r would leak.
fn split_terminated(content: &str) -> Vec<(&str, &str)> {
    content
        .split_inclusive('\n')
        .map(|piece| {
            let Some(line) = piece.strip_suffix('\n') else {
                return (piece, "");
            };
            match line.strip_suffix('\r') {
                Some(line) => (line, "\r\n"),
                None => (line, "\n"),
            }
        })
        .collect()
}

// What: the list rows of a file, defaults before the marker
// Why: no marker means an old file; entries are defaults.
fn domain_rows(content: &str) -> Vec<DomainRow> {
    let mut is_default = true;
    content
        .lines()
        .filter_map(|line| {
            let raw = line.trim();
            if raw == CUSTOM_DOMAINS_MARKER {
                is_default = false;
                return None;
            }
            if raw.is_empty() || raw.starts_with('#') {
                return None;
            }
            Some(match stored_line(raw) {
                Some((domain, enabled)) => DomainRow {
                    raw: raw.to_string(),
                    display: stored_text(&domain, true),
                    enabled,
                    is_default,
                    is_valid: true,
                },
                None => DomainRow {
                    raw: raw.to_string(),
                    display: raw.strip_prefix('!').unwrap_or(raw).to_string(),
                    enabled: true,
                    is_default,
                    is_valid: false,
                },
            })
        })
        .collect()
}

// What: the text with one entry switched; None if unchanged
// Why: a repeated click must not rewrite the file.
fn with_enabled(content: &str, target: &CdnDomain, enable: bool) -> Option<String> {
    let mut changed = false;
    let text: String = split_terminated(content)
        .into_iter()
        .map(|(line, terminator)| match stored_line(line) {
            Some((domain, enabled)) if domain == *target && enabled != enable => {
                changed = true;
                format!("{}{terminator}", stored_text(&domain, enable))
            }
            _ => format!("{line}{terminator}"),
        })
        .collect();
    changed.then_some(text)
}

// What: the text with an entry added; None if present.
// Why: add re-enables a disabled entry, never repeats it.
fn with_added(content: &str, entry: &CdnDomain) -> Option<String> {
    match content
        .lines()
        .filter_map(stored_line)
        .find(|(d, _)| d == entry)
    {
        Some((_, true)) => return None,
        Some(_) => return with_enabled(content, entry, true),
        None => {}
    }
    let mut text = content.to_string();
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    // What: add the marker once before the first addition.
    // Why: old files split into defaults and additions.
    if !text.contains(CUSTOM_DOMAINS_MARKER) {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(CUSTOM_DOMAINS_MARKER);
        text.push('\n');
    }
    text.push_str(&stored_text(entry, true));
    text.push('\n');
    Some(text)
}

// What: the target of a removal request, or None.
// Why: additions are strict; removal also cleans legacy.
fn delete_target(text: &str) -> Option<DeleteTarget> {
    let text = text.trim();
    if let Some(domain) = parse_cdn_domain(text) {
        return Some(DeleteTarget::Domain(domain));
    }
    (!text.is_empty() && !text.starts_with('#') && !text.chars().any(char::is_control))
        .then(|| DeleteTarget::Raw(text.to_string()))
}

// What: the text without matching lines; None if none match
// Why: only a real removal rewrites the file.
fn without_domain(content: &str, target: &DeleteTarget) -> Option<String> {
    let mut removed = false;
    let text: String = split_terminated(content)
        .into_iter()
        .filter(|(line, _)| {
            let line = line.trim();
            let hit = match target {
                DeleteTarget::Domain(domain) => {
                    parse_cdn_domain(line).is_some_and(|found| found == *domain)
                }
                DeleteTarget::Raw(raw) => line.eq_ignore_ascii_case(raw),
            };
            removed |= hit;
            !hit
        })
        .map(|(line, terminator)| format!("{line}{terminator}"))
        .collect();
    removed.then_some(text)
}

// What: read the list, apply a pure edit, write if changed.
// Why: one lock and one writer for every list change.
fn edit_domains(
    state: &AppState,
    create: bool,
    change: impl FnOnce(&str) -> Option<String>,
) -> anyhow::Result<()> {
    let _guard = hold(&state.file_lock);
    let path = Path::new(&state.config.cdn_domains_file);
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(e) if create && e.kind() == io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e.into()),
    };
    if let Some(text) = change(&content) {
        // What: keep the file's current permissions.
        // Why: proxy and dns containers read it as others.
        let mode = fs::metadata(path).map_or(0o644, |m| m.permissions().mode() & 0o7777);
        write_file(path, text.as_bytes(), mode, Place::Replace)?;
    }
    Ok(())
}

// What: send one record event to every DNS node.
// Why: the subscriber applies it to PowerDNS everywhere.
async fn publish_record(state: &AppState, record: &DnsRecord) -> Result<(), String> {
    let payload = serde_json::to_vec(record).map_err(|e| e.to_string())?;
    state
        .nats
        .publish(NATS_SUBJECT_RECORD, payload.into())
        .await
        .map_err(|e| e.to_string())
}

// What: flush a name from the local and every recursor.
// Why: zone, type, content let a node confirm AXFR first.
// From: Issue #1095
async fn flush_recursor_cache(state: &AppState, request: FlushRequest) {
    // What: the name in its dotted form.
    // Why: PowerDNS's flush matches the exact dotted name.
    // From: Issue #400
    let domain = canonical_zone(&request.domain);
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("domain", &domain)
        .finish();
    let url = format!("{}/cache/flush?{query}", state.config.pdns_rec_api);
    // What: a failed flush is logged; entries expire.
    // Why: the record change itself already happened.
    if let Err(err) = state.pdns.call(reqwest::Method::PUT, &url, None).await {
        tracing::warn!("cache flush of {url} failed: {err}");
    }
    let request = FlushRequest { domain, ..request };
    match serde_json::to_vec(&request) {
        Ok(payload) => {
            if let Err(err) = state.nats.publish(NATS_SUBJECT_FLUSH, payload.into()).await {
                tracing::warn!("flush publish failed: {err}");
            }
        }
        Err(err) => tracing::warn!("flush request not encoded: {err}"),
    }
}

// What: a flush request for a name only.
// Why: CDN changes have no zone or record to confirm.
fn flush_name(domain: &str) -> FlushRequest {
    FlushRequest {
        domain: domain.to_string(),
        zone: None,
        record_type: None,
        expected_content: None,
        expected_ttl: None,
    }
}

// What: a flush that names the changed record set.
// Why: a node confirms the set (content, ttl) first.
// From: Issue #1683 | PR #1912
fn record_flush(
    name: &str,
    zone: String,
    record_type: String,
    value: Option<(String, u32)>,
) -> FlushRequest {
    let (content, ttl) = value.map(|(c, t)| (vec![c], t as i32)).unzip();
    FlushRequest {
        zone: Some(zone),
        record_type: Some(record_type),
        expected_content: content,
        expected_ttl: ttl,
        ..flush_name(name)
    }
}

// What: the ttl form field, else the record default.
// Why: one owner for the LAN and PTR add forms.
// From: Issue #1683 | PR #1912
fn form_ttl(f: &Fields) -> u32 {
    f.number::<u32>("ttl").unwrap_or(DEFAULT_RECORD_TTL as u32)
}

// What: a replace (Some) or delete (None) record event.
// Why: one owner for LAN edits and DDNS lease cleanup.
// From: Issue #1683 | PR #1912
fn record_event(
    zone: String,
    name: String,
    kind: String,
    value: Option<(String, u32)>,
) -> DnsRecord {
    DnsRecord {
        action: if value.is_some() { "replace" } else { "delete" }.into(),
        zone,
        name,
        record_type: kind,
        ttl: value.as_ref().map(|(_, ttl)| *ttl as i32),
        records: value.map(|(content, _)| {
            vec![HashMap::from([
                ("content".to_string(), json!(content)),
                ("disabled".to_string(), json!(false)),
            ])]
        }),
    }
}

// What: set (Some) or delete (None) a LAN record set.
// Why: publish to every node, then flush the name.
// From: Issue #1683 | PR #1912
async fn set_lan_record(
    state: &AppState,
    name: String,
    kind: String,
    value: Option<(String, u32)>,
) {
    let record = record_event(state.config.lan_zone.clone(), name, kind, value.clone());
    if let Err(e) = publish_record(state, &record).await {
        tracing::error!("NATS publish failed: {e}");
    }
    let flush = record_flush(&record.name, record.zone, record.record_type, value);
    flush_recursor_cache(state, flush).await;
}

// What: set (Some) or delete (None) the PTR of an address.
// Why: the flush follows only an accepted write.
// From: Issue #1683 | PR #1912
async fn set_ptr_record(
    state: &AppState,
    ip: &str,
    zone: String,
    name: String,
    value: Option<(String, u32)>,
) {
    let body = match &value {
        Some((target, ttl)) => json!({"rrsets": [{
            "name": name, "type": "PTR", "ttl": ttl, "changetype": "REPLACE",
            "records": [{"content": target, "disabled": false}]
        }]}),
        None => json!({"rrsets": [{"name": name, "type": "PTR", "changetype": "DELETE"}]}),
    };
    let action = if value.is_some() { "add" } else { "delete" };
    if patch_reverse_zone(state, &zone, body).await {
        let flush = record_flush(&name, zone, "PTR".into(), value);
        flush_recursor_cache(state, flush).await;
    } else {
        tracing::error!(ip, "PowerDNS rejected PTR {action}");
    }
}

// What: a LAN record name as a dotted FQDN in zone lan.
// Why: the bare name "lan" is the zone root, not lan.lan.
fn normalize_lan_name(name: &str, lan_zone: &str) -> String {
    let name = name.trim().to_lowercase();
    if name.ends_with('.') {
        name
    } else if name == lan_zone || name.ends_with(&format!(".{lan_zone}")) {
        format!("{name}.")
    } else {
        format!("{name}.{lan_zone}.")
    }
}

// What: true for an FQDN inside the lan zone.
// Why: the ui may only touch records of its own zone.
fn is_lan_name(name: &str, underscore: bool, lan_zone: &str) -> bool {
    let zone = canonical_zone(lan_zone);
    is_fqdn(name, underscore, true) && (name == zone || name.ends_with(&format!(".{zone}")))
}

// What: the record types the LAN forms accept.
// Why: validation and the type list of the page share it.
const LAN_RECORD_TYPES: [&str; 5] = ["A", "AAAA", "CNAME", "MX", "TXT"];

// What: type and content of a valid LAN record, or None.
// Why: each record type has its own content syntax.
fn validate_lan_record(
    name: &str,
    record_type: &str,
    content: &str,
    ttl: u32,
    lan_zone: &str,
) -> Option<(&'static str, String)> {
    if !(1..=MAX_TTL).contains(&ttl) {
        return None;
    }
    let wanted = record_type.trim().to_ascii_uppercase();
    let kind = LAN_RECORD_TYPES.into_iter().find(|t| *t == wanted)?;
    if !is_lan_name(name, kind == "TXT", lan_zone) {
        return None;
    }
    let content = content.trim();
    let valid = match kind {
        "A" => content.parse::<Ipv4Addr>().is_ok(),
        "AAAA" => content.parse::<Ipv6Addr>().is_ok(),
        "CNAME" => is_fqdn(&normalize_lan_name(content, lan_zone), false, true),
        "MX" => {
            let mut parts = content.split_whitespace();
            matches!(
                (parts.next(), parts.next(), parts.next()),
                (Some(priority), Some(exchange), None)
                    if priority.parse::<u16>().is_ok()
                        && is_fqdn(&normalize_lan_name(exchange, lan_zone), false, true)
            )
        }
        _ => {
            !content.is_empty()
                && content.len() <= MAX_TXT_BYTES
                && !content.chars().any(char::is_control)
        }
    };
    valid.then(|| (kind, content.to_string()))
}

// What: a record type name for a delete, or None.
// Why: any type may be removed, so only shape is checked.
fn delete_record_type(record_type: &str) -> Option<String> {
    let kind = record_type.trim().to_ascii_uppercase();
    if let Some(code) = kind.strip_prefix("TYPE") {
        return code.parse::<u16>().ok().map(|_| kind);
    }
    (kind.len() <= 16
        && kind.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && kind.chars().all(|c| c.is_ascii_alphanumeric()))
    .then_some(kind)
}

// What: reverse zone and PTR name of an address, or None.
// Why: only provisioned zones exist; others would 404.
fn ptr_location(ip: &str) -> Option<(String, String)> {
    let address = ipv4(ip)?;
    Some((reverse_zone_for_ipv4(address)?, ptr_name_for_ipv4(address)))
}

// What: a PTR target as a dotted FQDN, or None.
// Why: a PTR names a real host: no wildcard, no underscore.
fn normalize_ptr_target(hostname: &str) -> Option<String> {
    let mut host = hostname.trim().to_ascii_lowercase();
    if !host.ends_with('.') {
        host.push('.');
    }
    is_fqdn(&host, false, false).then_some(host)
}

// What: PATCH a reverse zone; true when PowerDNS accepts.
// Why: manual PTRs go straight to the primary's PowerDNS.
// From: Issue #1077
async fn patch_reverse_zone(state: &AppState, zone: &str, body: Value) -> bool {
    let url = zone_url(&state.config.pdns_auth_api, zone);
    match state
        .pdns
        .call(reqwest::Method::PATCH, &url, Some(body.to_string()))
        .await
    {
        Ok(response) => response.status().is_success(),
        Err(e) => {
            tracing::error!("PTR PATCH to reverse zone {zone} failed: {e}");
            false
        }
    }
}

// What: PTR rows of one zone's rrsets.
// Why: foreign names and disabled records stay out.
fn ptr_rows(rrsets: &[Value]) -> Vec<PtrRow> {
    let mut rows = Vec::new();
    for rrset in rrsets {
        let name = rrset.get("name").and_then(Value::as_str);
        let address = name.and_then(ipv4_from_ptr_name);
        if rrset.get("type").and_then(Value::as_str) != Some("PTR") {
            continue;
        }
        let Some(address) = address else { continue };
        let ttl = rrset.get("ttl").and_then(Value::as_u64).unwrap_or(0) as u32;
        for record in rrset
            .get("records")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if record.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            if let Some(content) = record.get("content").and_then(Value::as_str) {
                rows.push(PtrRow {
                    ip: address.to_string(),
                    hostname: content.to_string(),
                    ttl,
                    sort_key: u32::from(address),
                });
            }
        }
    }
    rows
}

// What: all PTR rows of the provisioned IPv4 reverse zones.
// Why: up to 18 zones are read at once; one by one is slow.
async fn fetch_ptr_records(state: &AppState) -> Vec<PtrRow> {
    let zones = reverse_zones().into_iter();
    let per_zone = futures_util::future::join_all(zones.map(|zone| async move {
        let rrsets = state
            .pdns
            .zone_rrsets(&state.config.pdns_auth_api, &zone)
            .await;
        match rrsets {
            Ok(rrsets) => ptr_rows(&rrsets),
            Err(e) => {
                tracing::warn!("PTR records of {zone} not read: {e}");
                Vec::new()
            }
        }
    }))
    .await;
    let mut rows: Vec<PtrRow> = per_zone.into_iter().flatten().collect();
    rows.sort_by(|a, b| {
        a.sort_key
            .cmp(&b.sort_key)
            .then_with(|| a.hostname.cmp(&b.hostname))
    });
    rows
}

// What: every managed zone's snapshots from the listener.
// Why: an unreachable listener shows none, not a bad page.
async fn fetch_zone_groups(state: &AppState) -> Vec<ZoneSnapshotGroup> {
    let response = state
        .http_client
        .get(format!("{}/snapshots", state.config.dns_rollback_url))
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await;
    let response = match response.and_then(reqwest::Response::error_for_status) {
        Ok(response) => response,
        Err(e) => {
            tracing::warn!("zone snapshots not read: {e}");
            return Vec::new();
        }
    };
    let body = match response.json::<Value>().await {
        Ok(body) => body,
        Err(e) => {
            tracing::warn!("zone snapshot list not decoded: {e}");
            return Vec::new();
        }
    };
    let Some(zones) = body.get("zones").and_then(Value::as_object) else {
        tracing::warn!("zone snapshot list has no zones object");
        return Vec::new();
    };
    let mut groups: Vec<ZoneSnapshotGroup> = zones
        .iter()
        .map(|(zone, list)| ZoneSnapshotGroup {
            zone: zone.clone(),
            // What: skip entries without an id.
            // Why: an old listener degrades to fewer rows.
            snapshots: list
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|entry| {
                    Some(SnapshotSummary {
                        id: entry.get("id")?.as_str()?.to_string(),
                        created_unix: entry
                            .get("created_unix")
                            .and_then(Value::as_u64)
                            .unwrap_or(0),
                    })
                })
                .collect(),
        })
        .collect();
    groups.sort_by(|a, b| a.zone.cmp(&b.zone));
    groups
}

// What: forward a chosen rollback to the listener.
// Why: the listener validates; the ui shows how it went.
// From: Issue #628
async fn rollback_zone_snapshot(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let (zone, snapshot_id) = (f.get("zone"), f.get("snapshot_id"));
    let result = state
        .http_client
        .post(format!("{}/rollback", state.config.dns_rollback_url))
        .header("X-API-Key", &state.config.pdns_api_key)
        .json(&json!({"zone": zone, "snapshot_id": snapshot_id}))
        .send()
        .await;
    let target = match result {
        Ok(response) if response.status().is_success() => {
            // What: log a degraded rollback; page is ok.
            // Why: no inline channel for partial failures.
            match response.json::<Value>().await {
                Ok(body) => {
                    if body.get("flush_ok").and_then(Value::as_bool) == Some(false) {
                        tracing::error!(
                            zone, snapshot_id,
                            flush_failed_names = %body.get("flush_failed_names").cloned().unwrap_or(json!([])),
                            "zone rollback applied but the cache flush failed for some names; clients may see stale answers until TTL expiry"
                        );
                    }
                    if body.get("zone_check_passed").and_then(Value::as_bool) == Some(false) {
                        tracing::error!(
                            zone,
                            snapshot_id,
                            "zone rollback applied but pdnsutil check-zone failed; inspect the zone manually"
                        );
                    }
                }
                Err(e) => tracing::error!(
                    error = %e, zone, snapshot_id,
                    "zone rollback succeeded but its response could not be decoded; flush and zone-check status unknown"
                ),
            }
            PAGE_DOMAINS.to_string()
        }
        // What: a refusal is known; a lost request is not.
        // Why: an unknown outcome must not invite a retry.
        Ok(response) => {
            tracing::error!(status = %response.status(), zone, snapshot_id, "zone rollback rejected by nats-subscriber");
            domains_error("zone_rollback_failed")
        }
        Err(e) => {
            tracing::error!(error = %e, zone, snapshot_id, "zone rollback request failed to reach nats-subscriber");
            domains_error("zone_rollback_unknown")
        }
    };
    Redirect::to(&target)
}

// What: the domains page with lists, records and snapshots.
// Why: the three remote reads run at the same time.
async fn domains_page(
    State(state): Shared,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let cfg = &state.config;
    let list = fs::read_to_string(&cfg.cdn_domains_file).unwrap_or_else(|e| {
        tracing::error!("CDN domain list {} not read: {e}", cfg.cdn_domains_file);
        String::new()
    });
    let rows = domain_rows(&list);
    let (lan, ptr, groups) = tokio::join!(
        async {
            state
                .pdns
                .zone_rrsets(&state.config.pdns_auth_api, &state.config.lan_zone)
                .await
                .map(|sets| {
                    sets.into_iter()
                        .filter_map(|set| serde_json::from_value::<RRset>(set).ok())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_else(|e| {
                    tracing::error!("failed to fetch LAN records: {e}");
                    Vec::new()
                })
        },
        fetch_ptr_records(&state),
        fetch_zone_groups(&state),
    );
    let marker_set = |file: &str| Path::new(&cfg.dns_state_dir).join(file).exists();
    let mut ctx = page_ctx(&headers, "domains");
    ctx.insert("dns_domains", &rows);
    ctx.insert("lan_records", &lan);
    ctx.insert("ptr_records", &ptr);
    ctx.insert("aaaa_filter_enabled", &marker_set(AAAA_FILTER_MARKER));
    ctx.insert(
        "ddns_unsigned_updates_allowed",
        &marker_set(DDNS_UNSIGNED_MARKER),
    );
    ctx.insert("ddns_tsig_key_configured", &tsig_key_configured(cfg));
    ctx.insert("zone_snapshot_groups", &groups);
    ctx.insert(
        "domain_error_message",
        &query
            .get("error")
            .and_then(|code| domain_error_message(code)),
    );
    ctx.insert("zone_snapshot_retention", &cfg.kea_keep_known_good_configs);
    render(&state, "domains.html", &ctx)
}

// What: true when a real DDNS TSIG key file exists.
// Why: the dns side writes it; an empty file is void.
// From: Issue #858
fn tsig_key_configured(config: &Config) -> bool {
    fs::metadata(Path::new(&config.shared_secret_dir).join("ddns-tsig-key"))
        .is_ok_and(|m| m.len() > 0)
}

// What: write a failed list edit to the log as a 500.
// Why: the write is the mutation; failure is no success.
fn write_failed(action: &str, e: anyhow::Error) -> StatusCode {
    tracing::error!("Failed to {action} dns domain: {e:#}");
    StatusCode::INTERNAL_SERVER_ERROR
}

// What: flush DNS after a domain list change.
// Why: the proxy supervisor watches the list itself.
async fn after_domain_change(state: &AppState, domain: &str) {
    flush_recursor_cache(state, flush_name(domain)).await;
}

// What: add a CDN domain, or re-enable a disabled one.
// Why: a bad entry returns to the page with a banner.
async fn add_dns(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, StatusCode> {
    let Some(entry) = parse_cdn_domain(f.get("domain")) else {
        tracing::warn!(domain = %f.get("domain"), "Rejected invalid dns domain");
        return Ok(Redirect::to(&domains_error("invalid_domain")));
    };
    edit_domains(&state, true, |text| with_added(text, &entry))
        .map_err(|e| write_failed("write", e))?;
    after_domain_change(&state, &entry.domain).await;
    Ok(Redirect::to(PAGE_DOMAINS))
}

// What: remove a CDN domain line, even a legacy one.
// Why: a malformed line must stay removable by its text.
async fn remove_dns(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, StatusCode> {
    let Some(target) = delete_target(f.get("domain")) else {
        tracing::warn!(domain = %f.get("domain"), "Rejected invalid dns domain delete");
        return Err(StatusCode::BAD_REQUEST);
    };
    edit_domains(&state, false, |text| without_domain(text, &target))
        .map_err(|e| write_failed("remove", e))?;
    let domain = match &target {
        DeleteTarget::Domain(domain) => &domain.domain,
        DeleteTarget::Raw(raw) => raw,
    };
    after_domain_change(&state, domain).await;
    Ok(Redirect::to(PAGE_DOMAINS))
}

// What: switch a shipped default entry on or off.
// Why: it flips the ! marker only; no add or delete.
async fn toggle_default_domain(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, StatusCode> {
    let Some(target) = parse_cdn_domain(f.get("domain")) else {
        tracing::warn!(domain = %f.get("domain"), "Rejected invalid dns domain toggle");
        return Err(StatusCode::BAD_REQUEST);
    };
    let enable = f.get("enabled") == "1";
    edit_domains(&state, false, |text| with_enabled(text, &target, enable))
        .map_err(|e| write_failed("toggle", e))?;
    after_domain_change(&state, &target.domain).await;
    Ok(Redirect::to(PAGE_DOMAINS))
}

// What: add or replace a LAN record through NATS.
// Why: the subscriber writes it on every DNS node.
async fn add_lan_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let name = normalize_lan_name(f.get("name"), &state.config.lan_zone);
    let ttl = form_ttl(&f);
    let Some((kind, content)) = validate_lan_record(
        &name,
        f.get("record_type"),
        f.get("content"),
        ttl,
        &state.config.lan_zone,
    ) else {
        tracing::warn!(name = %f.get("name"), record_type = %f.get("record_type"), "Rejected invalid LAN record");
        return Redirect::to(PAGE_DOMAINS);
    };
    set_lan_record(&state, name, kind.into(), Some((content, ttl))).await;
    Redirect::to(PAGE_DOMAINS)
}

// What: delete a LAN record set through NATS.
// Why: any type may be deleted; the name must be in lan.
async fn remove_lan_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let name = normalize_lan_name(f.get("name"), &state.config.lan_zone);
    let (Some(kind), true) = (
        delete_record_type(f.get("record_type")),
        is_lan_name(&name, true, &state.config.lan_zone),
    ) else {
        tracing::warn!(name = %f.get("name"), record_type = %f.get("record_type"), "Rejected invalid LAN record delete");
        return Redirect::to(PAGE_DOMAINS);
    };
    set_lan_record(&state, name, kind, None).await;
    Redirect::to(PAGE_DOMAINS)
}

// What: set or clear a marker file in the DNS state dir.
// Why: the dns container reads the marker's existence.
fn set_markers(state: &AppState, file: &str, enabled: bool) -> Result<(), StatusCode> {
    let path = Path::new(&state.config.dns_state_dir).join(file);
    let result = if enabled {
        write_file(&path, b"1", 0o644, Place::Replace)
    } else {
        match fs::remove_file(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    };
    result.map_err(|e| {
        tracing::error!(path = %path.display(), enabled, error = %e, "{file} toggle failed");
        StatusCode::INTERNAL_SERVER_ERROR
    })
}

// What: turn the AAAA filter marker on or off.
// Why: every DNS instance must see the requested state.
async fn toggle_aaaa_filter(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, StatusCode> {
    set_markers(&state, AAAA_FILTER_MARKER, f.get("enabled") == "1")?;
    Ok(Redirect::to(PAGE_DOMAINS))
}

// What: allow or forbid unsigned DDNS updates.
// Why: with no TSIG key there is nothing to relax.
// From: Issue #815
async fn toggle_ddns_allow_unsigned_updates(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, StatusCode> {
    let enable = f.get("enabled") == "1";
    if enable && !tsig_key_configured(&state.config) {
        return Ok(Redirect::to(&domains_error("ddns_allow_unsigned_no_key")));
    }
    // What: pdns watches the marker and restarts itself.
    // Why: the ui has no Docker; the supervisor converges.
    set_markers(&state, DDNS_UNSIGNED_MARKER, enable)?;
    Ok(Redirect::to(PAGE_DOMAINS))
}

// What: set a manual PTR record in the reverse zone.
// Why: the flush follows only an accepted write.
async fn add_ptr_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let ttl = form_ttl(&f);
    let (Some((zone, name)), Some(target), true) = (
        ptr_location(f.get("ip")),
        normalize_ptr_target(f.get("hostname")),
        (1..=MAX_TTL).contains(&ttl),
    ) else {
        tracing::warn!(ip = %f.get("ip"), hostname = %f.get("hostname"), "Rejected invalid PTR record");
        return Redirect::to(PAGE_DOMAINS);
    };
    set_ptr_record(&state, f.get("ip"), zone, name, Some((target, ttl))).await;
    Redirect::to(PAGE_DOMAINS)
}

// What: delete the PTR record set of an address.
// Why: the key is the address; no other field is needed.
async fn remove_ptr_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let Some((zone, name)) = ptr_location(f.get("ip")) else {
        tracing::warn!(ip = %f.get("ip"), "Rejected invalid PTR delete");
        return Redirect::to(PAGE_DOMAINS);
    };
    set_ptr_record(&state, f.get("ip"), zone, name, None).await;
    Redirect::to(PAGE_DOMAINS)
}

// What: log lines the recent-activity widget shows.
// Why: a short list keeps the page cheap to render.
const RECENT_LOGS: usize = 10;

// What: run a blocking job off the async workers.
// Why: size walks and log reads must not stall requests.
async fn blocking<T: Default + Send + 'static>(
    state: &Arc<AppState>,
    job: impl FnOnce(&AppState) -> T + Send + 'static,
) -> T {
    let state = state.clone();
    match tokio::task::spawn_blocking(move || job(&state)).await {
        Ok(value) => value,
        Err(e) => {
            tracing::error!("blocking job failed: {e}");
            T::default()
        }
    }
}

// What: nginx counters of the http and https side.
// Why: one nginx serves both sides; its page is read once.
async fn proxy_statuses(state: &AppState) -> (Option<NginxStatus>, Option<NginxStatus>) {
    let cfg = &state.config;
    let http = nginx_status(&state.http_client, &cfg.proxy_status_url).await;
    let https = if cfg.https_enabled {
        http.clone()
    } else {
        None
    };
    (http, https)
}

// What: the dashboard page.
// Why: all collectors start at once; latency is the max.
async fn dashboard(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let (proxy, cache_used_gb, stats, recent, syslog_gb, syslog, alarms) = tokio::join!(
        proxy_statuses(&state),
        blocking(&state, |s| du_gb(&s.config.cache_dir)),
        blocking(&state, |s| log_stats(&s.config.proxy_log_dir)),
        blocking(&state, |s| parse_log_tail(
            &s.config.proxy_log_dir,
            RECENT_LOGS
        )),
        blocking(&state, |s| du_gb(&s.config.syslog_log_root)),
        blocking(&state, |s| syslog_stats(&s.config.syslog_log_root)),
        blocking(&state, |s| read_alarms(&s.config.netdata_alarms_file)),
    );
    // What: the cache bar follows the running size.
    // Why: a pending resize must not look applied.
    let requested_gb = cfg.requested_cache_gb();
    let percent = if cfg.cache_max_gb > 0.0 {
        (cache_used_gb / cfg.cache_max_gb * 100.0).min(100.0) as u64
    } else {
        0
    };
    let mode = cfg.dhcp_mode();
    let mut ctx = page_ctx(&headers, "dashboard");
    ctx.insert("https_enabled", &cfg.https_enabled);
    ctx.insert("dhcp_mode", mode.as_str());
    ctx.insert("dhcp_mode_has_kea", &mode.is_kea());
    ctx.insert("http_status", &proxy.0);
    ctx.insert("https_status", &proxy.1);
    ctx.insert("cache_dir", &cfg.cache_dir);
    ctx.insert("cache_used_gb", &format!("{cache_used_gb:.1}"));
    ctx.insert("cache_max_gb", &cfg.cache_max_gb);
    ctx.insert("cache_pct", &percent);
    // What: pending at a difference of 1 GB or more.
    // Why: a fraction of a GB is not shown as a resize.
    ctx.insert(
        "cache_resize_pending",
        &((requested_gb - cfg.cache_max_gb).abs() >= 1.0),
    );
    ctx.insert("effective_cache_max_gb", &format!("{requested_gb:.0}"));
    ctx.insert("log_stats", &stats);
    ctx.insert("recent_logs", &recent);
    ctx.insert("syslog_size_gb", &format!("{syslog_gb:.1}"));
    ctx.insert("syslog_max_gb", &cfg.syslog_max_gb);
    ctx.insert("syslog_stats", &syslog);
    ctx.insert(
        "watchdog_status",
        &watchdog_json(&cfg.watchdog_status_file, cfg.watchdog_miss_limit),
    );
    ctx.insert("netdata_alarms", &alarm_views(&alarms));
    render(&state, "dashboard.html", &ctx)
}

// What: the connection counters alone, as JSON.
// Why: the dashboard polls this without costly collectors.
async fn metrics_api(State(state): Shared) -> Json<Value> {
    let (http, https) = proxy_statuses(&state).await;
    Json(json!({
        "http": http,
        "https_enabled": state.config.https_enabled,
        "https": https,
    }))
}

// What: the watchdog document as JSON.
// Why: the dashboard polls the health lights from here.
// From: Issue #870
async fn watchdog_status_api(State(state): Shared) -> Json<Value> {
    Json(watchdog_json(
        &state.config.watchdog_status_file,
        state.config.watchdog_miss_limit,
    ))
}

// What: the statistics page.
// Why: its charts load their data from the netdata proxy.
async fn stats_page(State(state): Shared, headers: HeaderMap) -> Response {
    render(&state, "stats.html", &page_ctx(&headers, "stats"))
}

// What: the log page, from the central syslog-ng store.
// Why: every container logs there; one view covers all.
// From: Issue #633 | PR #1912
async fn logs_page(
    State(state): Shared,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let max = state.config.ui_logs_max_entries;
    let mut ctx = page_ctx(&headers, "logs");
    ctx.insert("logs_max_entries", &max);
    let requested = params.get("host").cloned().unwrap_or_default();
    let (mut entries, hosts, selected) = blocking(&state, move |s| {
        let root = &s.config.syslog_log_root;
        let hosts = syslog_hosts(root);
        // What: accept only a host with a directory.
        // Why: the query value is caller input.
        let selected = Some(requested).filter(|h| hosts.contains(h));
        let entries = syslog_tail(root, selected.as_deref(), max);
        (entries, hosts, selected)
    })
    .await;
    entries.reverse();
    ctx.insert("syslog_logs", &entries);
    ctx.insert("syslog_hosts", &hosts);
    ctx.insert("selected_host", &selected);
    let switches: Vec<Value> = config::LOG_SWITCHES
        .iter()
        .zip(&state.config.log_programs)
        .map(|((key, _), program)| {
            serde_json::json!({
                "key": key,
                "program": program,
                "on": state.config.flag(key),
            })
        })
        .collect();
    ctx.insert("log_switches", &switches);
    render(&state, "logs.html", &ctx)
}

// What: save which services write to the central log.
// Why: the ui only writes; the watchdog filters syslog-ng.
// From: Issue #1683 | PR #1912
async fn update_logging_settings(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    let changes: Vec<(&str, String)> = config::LOG_SWITCHES
        .iter()
        .map(|(key, _)| (*key, bool_text(!f.get(key).is_empty())))
        .collect();
    state.config.save_settings(&changes).map_err(|e| {
        HtmlError::new(StatusCode::INTERNAL_SERVER_ERROR, &LOGS_AREA, e.to_string())
    })?;
    Ok(Redirect::to(PAGE_LOGS))
}

// What: the refusal text for a cache size that won't fit.
// Why: it names the largest size that would pass.
fn resize_rejection(cache_dir: &str, cache_gb: u64, avail_mib: u64) -> String {
    let avail_gb = avail_mib / 1024;
    match largest_cache_gb(avail_mib) {
        Some(largest) => format!(
            "{cache_gb} GB would not leave a safety buffer at {cache_dir} (only {avail_gb} GB \
             free there). The largest value that currently passes is {largest} GB."
        ),
        None => format!(
            "Not enough free space at {cache_dir} for any cache size with a safety buffer (only \
             {avail_gb} GB free there). Free up disk space or choose a smaller size."
        ),
    }
}

// What: check a cache size against free space and save it.
// Why: only the host's converge run applies it to proxy.
// From: Issue #1069
async fn resize_cache(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    let area = |status, message: String| HtmlError::new(status, &CACHE_AREA, message);
    let dir = &state.config.cache_dir;
    let gb = f
        .number::<u64>("cache_gb")
        .filter(|gb| *gb > 0)
        .ok_or_else(|| {
            area(
                StatusCode::BAD_REQUEST,
                "Please enter a positive whole number of GB.".into(),
            )
        })?;
    // What: refuse when the free space is unknown.
    // Why: a failed df must never read as unlimited space.
    let avail_mib = cache_free_mib(dir).ok_or_else(|| {
        let message = format!("Could not determine free disk space at {dir}. Refusing to resize.");
        area(StatusCode::INTERNAL_SERVER_ERROR, message)
    })?;
    if !cache_fits(gb, avail_mib) {
        return Err(area(
            StatusCode::BAD_REQUEST,
            resize_rejection(dir, gb, avail_mib),
        ));
    }
    state
        .config
        .save_settings(&[("CACHE_MAX_GB", gb.to_string())])
        .map_err(|e| area(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Redirect::to(PAGE_DASHBOARD))
}

// What: the NTP settings page.
// Why: shows the saved values, not the startup ones.
async fn ntp_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "ntp");
    ctx.insert("ntp_enabled", &cfg.flag("NTP_ENABLED"));
    ctx.insert("ntp_upstream_servers", &cfg.setting("NTP_UPSTREAM_SERVERS"));
    ctx.insert("ntp_auto_dhcp", &cfg.flag("NTP_AUTO_DHCP"));
    ctx.insert("http_ip", &cfg.http_ip);
    ctx.insert("ntp_port", &cfg.ntp_port);
    ctx.insert("dhcp_has_kea", &cfg.dhcp_mode().is_kea());
    render(&state, "ntp.html", &ctx)
}

// What: normalize the upstream NTP list to spaces.
// Why: chrony must get at least one valid server.
fn ntp_upstream_servers(raw: &str) -> Result<String, String> {
    let entries: Vec<&str> = raw
        .split([',', ' ', '\n', '\t'])
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect();
    if entries.is_empty() {
        return Err(
            "At least one upstream NTP server is required; LanCache-NG-NTP never \
                    operates as a standalone time source."
                .to_string(),
        );
    }
    // What: accept IPv6 literals by their colon.
    // Why: chrony takes them though Kea is IPv4 only.
    if let Some(bad) = entries
        .iter()
        .find(|e| !(e.contains(':') || ipv4(e).is_some() || is_valid_domain_name(e)))
    {
        return Err(format!(
            "'{bad}' is not a valid IPv4/IPv6 address or hostname."
        ));
    }
    Ok(entries.join(" "))
}

// What: save the NTP settings and apply them.
// Why: the watchdog reads the saved NTP keys.
// From: Issue #1486
async fn update_ntp_settings(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    let fail =
        |message: String| HtmlError::new(StatusCode::INTERNAL_SERVER_ERROR, &NTP_AREA, message);
    let servers = ntp_upstream_servers(f.get("ntp_upstream_servers"))
        .map_err(|m| HtmlError::new(StatusCode::BAD_REQUEST, &NTP_AREA, m))?;
    let cfg = &state.config;
    let enabled = !f.get("ntp_enabled").is_empty();
    let auto = !f.get("ntp_auto_dhcp").is_empty();
    let was_auto = cfg.flag("NTP_ENABLED") && cfg.flag("NTP_AUTO_DHCP");

    // What: writes the NTP keys to the settings file.
    // Why: the watchdog reads NTP_ENABLED from that file.
    cfg.save_settings(&[
        ("NTP_ENABLED", bool_text(enabled)),
        ("NTP_UPSTREAM_SERVERS", servers),
        ("NTP_AUTO_DHCP", bool_text(auto)),
    ])
    .map_err(|e| fail(e.to_string()))?;
    // What: sets Kea's NTP option to LAN or default.
    // Why: auto off before and after keeps subnet edits.
    if enabled && auto {
        sync_subnet_ntp(&state, true).await.map_err(fail)?;
    } else if was_auto {
        sync_subnet_ntp(&state, false).await.map_err(fail)?;
    }
    Ok(Redirect::to(PAGE_NTP))
}

// What: the setup page with network hints and updates.
// Why: operators copy the client settings from here.
async fn setup_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "setup");
    ctx.insert("http_ip", &cfg.http_ip);
    ctx.insert("https_ip", &cfg.https_ip);
    ctx.insert("ca_cert_file", &cfg.ca_cert_file);
    ctx.insert(
        "lancache_image_channel",
        &cfg.setting("LANCACHE_IMAGE_CHANNEL"),
    );
    ctx.insert("auto_update_enabled", &cfg.flag("AUTO_UPDATE_ENABLED"));
    render(&state, "setup.html", &ctx)
}

// What: true for a channel an operator may pick.
// Why: pinned tags and the retired edge name are no choice.
// From: Issue #819
fn is_valid_ui_channel(value: &str) -> bool {
    matches!(value, "stable" | "nightly")
}

// What: save the release channel and the auto-update flag.
// Why: the host's converge run applies both; no Docker.
// From: Issue #819
async fn update_stack_settings(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    let channel = f.get("lancache_image_channel");
    if !is_valid_ui_channel(channel) {
        return Err(HtmlError::new(
            StatusCode::BAD_REQUEST,
            &SETTINGS_AREA,
            "Invalid release channel requested.",
        ));
    }
    let auto_update = !f.get("auto_update_enabled").is_empty();
    state
        .config
        .save_settings(&[
            ("LANCACHE_IMAGE_CHANNEL", channel.to_string()),
            ("AUTO_UPDATE_ENABLED", bool_text(auto_update)),
        ])
        .map_err(|e| {
            HtmlError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                &SETTINGS_AREA,
                e.to_string(),
            )
        })?;
    Ok(Redirect::to(PAGE_SETUP))
}

// What: the page shown while the ui restarts itself.
// Why: a redirect cannot work; this process is ending.
const RESTART_UI_PAGE: &str = r##"<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8"><title>Admin-UI wird neu gestartet</title>
<style>body{background:#0f172a;color:#e2e8f0;font-family:system-ui,sans-serif;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0}
.box{text-align:center;max-width:28rem;padding:2rem}h1{font-size:1.125rem;margin:0 0 .5rem}
p{font-size:.875rem;color:#94a3b8;margin:0}</style></head><body><div class="box">
<h1>Admin-UI wird neu gestartet&hellip;</h1>
<p>Diese Seite leitet automatisch weiter, sobald die Admin-UI wieder erreichbar ist.</p></div>
<script>
// What: treat 200 as recovery only after instance down
// Why: 200 doesn't prove restart; old process may answer
// From: PR #1610
var sawDown = false;
function pollHealth() {
  fetch('@ROUTE_HEALTH@', { cache: 'no-store' }).then(function (res) {
    if (res.ok && sawDown) { window.location.href = '@PAGE_SETUP@'; return; }
    sawDown = sawDown || !res.ok;
    setTimeout(pollHealth, 1000);
  }).catch(function () { sawDown = true; setTimeout(pollHealth, 1000); });
}
setTimeout(pollHealth, 1500);
</script></body></html>
"##;

// What: answer with the wait page, then end the ui.
// Why: compose "restart: always" starts it; no Docker.
// From: Issue #1486 | PR #1912
async fn restart_ui_service() -> Html<String> {
    tokio::spawn(async {
        tokio::time::sleep(Duration::from_millis(750)).await;
        tracing::info!("operator-requested Admin UI restart");
        std::process::exit(0);
    });
    Html(
        RESTART_UI_PAGE
            .replace("@PAGE_SETUP@", PAGE_SETUP)
            .replace("@ROUTE_HEALTH@", ROUTE_HEALTH),
    )
}

// What: the body of a desired-state request.
// Why: base.html sends {"state": "running" | "stopped"}.
#[derive(Deserialize)]
struct DesiredStateBody {
    state: String,
}

// What: record whether dhcp or ntp should run.
// Why: the ui only writes; the watchdog starts and stops.
// From: Issue #1437
async fn set_service_desired_state(
    State(state): Shared,
    AxPath(service): AxPath<String>,
    Json(body): Json<DesiredStateBody>,
) -> StatusCode {
    if !matches!(service.as_str(), "dhcp" | "ntp") {
        return StatusCode::NOT_FOUND;
    }
    let run_state = match body.state.as_str() {
        "running" => DesiredRunState::Running,
        "stopped" => DesiredRunState::Stopped,
        _ => return StatusCode::BAD_REQUEST,
    };
    let path = Path::new(&state.config.desired_state_file);
    // What: hold the lock over the read-modify-write.
    // Why: two toggles at once must not drop each other.
    let _guard = hold(&state.file_lock);
    let mut desired = DesiredState::read(path);
    if service == "dhcp" {
        desired.dhcp = Some(run_state);
    } else {
        desired.ntp = Some(run_state);
    }
    let written = serde_json::to_vec_pretty(&desired)
        .map_err(io::Error::other)
        .and_then(|json| write_file(path, &json, 0o644, Place::Replace));
    stored_status(&format!("desired state for {service}"), written)
}
// What: minimum registration token length, in characters.
// Why: this token alone gates remote registration.
const MIN_REGISTRATION_TOKEN_LEN: usize = 32;

// What: the ui log file from UI_LOG_FILE; unset is fatal.
// Why: tracing and the root start must agree on one path.
// From: Issue #633 | PR #1858
fn ui_log_file() -> String {
    config::need(&config::process_env, "UI_LOG_FILE").unwrap_or_else(|e| container_start_fatal(&e))
}

// What: a real token as is, else a persisted random one.
// Why: a generated token is stored and reused.
fn registration_token(configured: &str, token_file: &str) -> Result<String, String> {
    let token = if is_placeholder(configured) {
        let path = Path::new(token_file);
        load_or_create(
            path,
            || {
                // What: log that a token was generated.
                // Why: operators must know where it is.
                tracing::warn!(
                    "SECONDARY_REGISTRATION_TOKEN was unset or a placeholder; generated a \
                     persistent random token at {}",
                    path.display()
                );
                let token = hex32();
                (token.clone(), token)
            },
            |text| {
                anyhow::ensure!(
                    !is_placeholder(text),
                    "the persisted token is empty or a placeholder; delete {} to regenerate it, \
                     or set SECONDARY_REGISTRATION_TOKEN to a real secret",
                    path.display()
                );
                Ok(text.to_string())
            },
        )
        .map_err(|e| format!("secondary registration token: {e:#}"))?
    } else {
        configured.to_string()
    };
    let length = token.chars().count();
    if length < MIN_REGISTRATION_TOKEN_LEN {
        return Err(format!(
            "SECONDARY_REGISTRATION_TOKEN is only {length} character(s), below the required \
             minimum of {MIN_REGISTRATION_TOKEN_LEN}; generate one with: openssl rand -hex 32"
        ));
    }
    Ok(token)
}

// What: the session lifetime, after all start-up checks.
// Why: bad env must fail closed before NATS or state.
fn preflight(cfg: &Config) -> Result<Duration, String> {
    cfg.nats.validate()?;
    // What: auth must be fully set, or insecure chosen.
    // Why: a half-set pair would run without a login.
    match (&cfg.auth_user, &cfg.auth_password_hash) {
        (Some(_), Some(hash)) => {
            // What: the stored value is an Argon2id hash.
            // Why: anything else fails closed.
            let parsed = PasswordHash::new(hash)
                .map_err(|e| format!("UI_AUTH_PASSWORD_HASH is no PHC hash: {e}"))?;
            if parsed.algorithm.as_str() != "argon2id" {
                return Err("UI_AUTH_PASSWORD_HASH must be an Argon2id hash.".to_string());
            }
        }
        (None, None) if cfg.allow_insecure_ui => {
            tracing::warn!("ALLOW_INSECURE_UI=true: starting Admin-UI without authentication");
        }
        (None, None) => {
            return Err("Admin-UI authentication is required. Set UI_AUTH_USER and \
                        UI_AUTH_PASSWORD_HASH, or explicitly set ALLOW_INSECURE_UI=true if you \
                        understand the risk."
                .to_string());
        }
        _ => {
            return Err(
                "UI_AUTH_USER and UI_AUTH_PASSWORD_HASH must either both be set or both be \
                        empty."
                    .to_string(),
            );
        }
    }
    Ok(Duration::from_secs(cfg.ui_session_ttl_seconds))
}

// What: send logs to stdout and to UI_LOG_FILE if openable.
// Why: a missing log dir must not stop the ui starting.
// From: Issue #849
fn init_tracing() {
    let path = ui_log_file();
    let file_layer = match OpenOptions::new().create(true).append(true).open(&path) {
        Ok(file) => Some(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(Mutex::new(file)),
        ),
        Err(e) => {
            eprintln!("warning: could not open UI_LOG_FILE at {path:?}: {e} (stdout-only logging)");
            None
        }
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "lancache_ui=info,warn".into());
    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer())
        .with(file_layer)
        .init();
}

// What: print a FATAL start error and exit 1.
// Why: the start fails closed before the server runs.
// From: Issue #858
fn container_start_fatal(message: &str) -> ! {
    die("lancache-ui", message)
}

// What: dirs the ui writes, derived from its own config.
// Why: chown follows the configured paths, no second list.
// From: Issue #1427 | PR #1858
fn ui_written_dirs(cfg: &Config, log_file: &Path) -> Vec<PathBuf> {
    let files = [
        &cfg.cdn_domains_file,
        &cfg.netdata_alarms_file,
        &cfg.nats_xkey_seed_path,
        &cfg.desired_state_file,
        &cfg.nats_auth_callout_path,
        &cfg.dhcp_probe_request_file,
    ];
    let mut dirs: Vec<PathBuf> = files
        .iter()
        .filter_map(|file| Path::new(file.as_str()).parent().map(Path::to_path_buf))
        .chain([
            PathBuf::from(&cfg.dns_state_dir),
            PathBuf::from(&cfg.kea_config_snapshot_dir),
        ])
        .chain(log_file.parent().map(Path::to_path_buf))
        .filter(|dir| !dir.as_os_str().is_empty())
        .collect();
    dirs.sort();
    dirs.dedup();
    dirs
}

// What: lchown a tree recursively, never following links.
// Why: a symlink in a volume must not redirect the chown.
// From: Issue #1427
fn chown_tree(path: &Path, uid: u32, gid: u32) -> io::Result<()> {
    own(path, Some(uid), Some(gid), None)?;
    if fs::symlink_metadata(path)?.is_dir() {
        for entry in fs::read_dir(path)? {
            chown_tree(&entry?.path(), uid, gid)?;
        }
    }
    Ok(())
}

// What: log dir and files in gid; setgid dir, files g+r.
// Why: the shared log reader gid must keep read access.
// From: Issue #1427 | PR #1670
fn open_log_dir_to_group(dir: &Path, gid: u32) -> io::Result<()> {
    own(dir, None, Some(gid), Some(0o2775))?;
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let meta = fs::symlink_metadata(&path)?;
        if meta.is_file() {
            own(&path, None, Some(gid), Some(meta.mode() | 0o040))?;
        }
    }
    Ok(())
}

// What: as root: secrets, ownership, then exec as user.
// Why: the server must not run as root; volumes start root.
// From: Issue #858 | PR #1858
fn container_root_start() {
    let euid = fs::metadata("/proc/self")
        .unwrap_or_else(|e| container_start_fatal(&format!("cannot read /proc/self: {e}")))
        .uid();
    if euid != 0 {
        return;
    }
    // What: the runtime uid equals the one runtime gid.
    // Why: the image gives user and group the same one id.
    // From: Issue #1427 | PR #1912
    let gid = config::runtime_gid().unwrap_or_else(|e| container_start_fatal(&e));
    let uid = gid;
    let cfg = Config::from_env().unwrap_or_else(|e| container_start_fatal(&e));
    if let Err(e) = ensure_shared_secrets(&cfg.shared_secret_dir, gid, "") {
        container_start_fatal(&format!(
            "cannot resolve shared secret {e}. Mount the shared-secrets volume \
             or set the variable to the value its backend uses."
        ));
    }
    let log_file = PathBuf::from(ui_log_file());
    for dir in ui_written_dirs(&cfg, &log_file) {
        if fs::symlink_metadata(&dir).is_ok()
            && let Err(e) = chown_tree(&dir, uid, gid)
        {
            container_start_fatal(&format!("cannot chown {}: {e}", dir.display()));
        }
    }
    if let Some(log_dir) = log_file.parent()
        && log_dir.exists()
        && let Err(e) = open_log_dir_to_group(log_dir, gid)
    {
        container_start_fatal(&format!("cannot set {} modes: {e}", log_dir.display()));
    }
    let exe = std::env::current_exe()
        .unwrap_or_else(|e| container_start_fatal(&format!("cannot locate own binary: {e}")));
    let mut args = std::env::args_os();
    let argv0 = args.next().unwrap_or_else(|| exe.clone().into_os_string());
    let err = std::process::Command::new(&exe)
        .arg0(argv0)
        .args(args)
        .uid(uid)
        .gid(gid)
        .exec();
    container_start_fatal(&format!("cannot exec as uid {uid}: {err}"));
}

// What: open the secondaries DB and bring it up to date.
// Why: old installs lack columns; additive changes only.
// From: Issue #583
fn open_database(path: &str) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS secondaries (
            name TEXT PRIMARY KEY,
            nats_token TEXT NOT NULL,
            consumer_name TEXT NOT NULL UNIQUE,
            registered_at INTEGER NOT NULL,
            last_seen INTEGER
        );",
    )?;
    let have: Vec<String> = conn
        .prepare("PRAGMA table_info(secondaries)")?
        .query_map([], |row| row.get(1))?
        .collect::<rusqlite::Result<_>>()?;
    // What: add the callout identity and address columns.
    // Why: nats_token stays; SQLite cannot drop it cheaply.
    for column in ["nats_user", "nats_password_hash", "address"] {
        if !have.iter().any(|name| name == column) {
            conn.execute(
                &format!("ALTER TABLE secondaries ADD COLUMN {column} TEXT"),
                [],
            )?;
        }
    }
    // What: a UNIQUE index on nats_user.
    // Why: two rows must never share one NATS identity.
    // From: Issue #849
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_secondaries_nats_user ON secondaries(nats_user)",
        [],
    )?;
    Ok(conn)
}

// What: an NKey from its env seed, else its seed file.
// Why: one owner for the issuer key and the callout key.
// From: Issue #1683 | PR #1912
fn nkey_from_seed<K>(
    (env, env_seed): (&str, Option<&String>),
    path: &str,
    label: &str,
    new: fn() -> K,
    from_seed: fn(&str) -> Result<K, nkeys::error::Error>,
    seed_of: fn(&K) -> Result<String, nkeys::error::Error>,
) -> Result<K, String> {
    if let Some(seed) = env_seed {
        return from_seed(seed).map_err(|e| format!("{env} is not a valid NKey seed: {e}"));
    }
    let path = Path::new(path);
    load_or_create(
        path,
        || {
            let pair = new();
            // What: a generated key always has a seed.
            // Why: only a public-only key lacks one.
            let seed = seed_of(&pair).expect("a generated key has a seed");
            (seed, pair)
        },
        |text| {
            from_seed(text)
                .map_err(|e| anyhow::anyhow!("{label} seed at {} is invalid: {e}", path.display()))
        },
    )
    .map_err(|e| format!("{e:#}"))
}

// What: the issuer key, from its env seed or its file.
// Why: the public key is needed for the callout fragment.
// From: Issue #583
fn issuer_keypair(cfg: &Config) -> Result<KeyPair, String> {
    nkey_from_seed(
        ("NATS_ISSUER_SEED", cfg.nats_issuer_seed.as_ref()),
        &cfg.nats_issuer_seed_path,
        "issuer NKey",
        KeyPair::new_account,
        KeyPair::from_seed,
        KeyPair::seed,
    )
}

// What: the callout encryption key, from env seed or file.
// Why: a separate X25519 key; its rotation is its own.
// From: Issue #682
fn callout_xkey(cfg: &Config) -> Result<XKey, String> {
    nkey_from_seed(
        ("NATS_XKEY_SEED", cfg.nats_xkey_seed.as_ref()),
        &cfg.nats_xkey_seed_path,
        "xkey",
        XKey::new,
        XKey::from_seed,
        XKey::seed,
    )
}

// What: every route of the ui, public and protected.
// Why: the protected layer owns auth and CSRF.
fn router(state: Arc<AppState>) -> Router {
    // What: routes outside the login layer.
    // Why: probes, tokens, icons need no browser session.
    let public: Vec<(&str, MethodRouter<Arc<AppState>>)> = vec![
        (ROUTE_HEALTH, get(health)),
        (ROUTE_SECONDARY_REGISTER, post(register_secondary)),
        (ALARM_INGEST_PATH, post(ingest_alarm)),
        (ROUTE_FAVICON, get(favicon_ico)),
        (ROUTE_LOGO_ICON, get(logo_icon)),
    ];
    let protected: Vec<(&str, MethodRouter<Arc<AppState>>)> = vec![
        (PAGE_DASHBOARD, get(dashboard)),
        (PAGE_DHCP, get(dhcp_page)),
        (ROUTE_DHCP_MODE, post(update_dhcp_mode)),
        (ROUTE_DHCP_DDNS, post(update_dhcp_ddns)),
        (ROUTE_DHCP_PROXY, post(update_dhcp_proxy)),
        (ROUTE_DHCP_RELAY, post(update_dhcp_relay)),
        (ROUTE_SUBNET_ADD, post(add_subnet)),
        (ROUTE_SUBNET_UPDATE, post(update_subnet)),
        (ROUTE_SUBNET_REMOVE, post(remove_subnet)),
        (ROUTE_SUBNET_OPTION_ADD, post(add_subnet_option)),
        (ROUTE_SUBNET_OPTION_REMOVE, post(remove_subnet_option)),
        (ROUTE_STATIC_ADD, post(add_reservation)),
        (ROUTE_STATIC_REMOVE, post(remove_reservation)),
        (ROUTE_LEASE_RELEASE, post(release_lease)),
        (ROUTE_KEA_ROLLBACK, post(rollback_kea_snapshot)),
        (ROUTE_DHCP_CHECK, post(check_dhcp_conflict)),
        (PAGE_NTP, get(ntp_page)),
        (ROUTE_NTP_SETTINGS, post(update_ntp_settings)),
        (PAGE_DOMAINS, get(domains_page)),
        (ROUTE_DNS_ADD, post(add_dns)),
        (ROUTE_DNS_REMOVE, post(remove_dns)),
        (ROUTE_DNS_TOGGLE, post(toggle_default_domain)),
        (ROUTE_LAN_ADD, post(add_lan_record)),
        (ROUTE_LAN_REMOVE, post(remove_lan_record)),
        (ROUTE_PTR_ADD, post(add_ptr_record)),
        (ROUTE_PTR_REMOVE, post(remove_ptr_record)),
        (ROUTE_AAAA_FILTER, post(toggle_aaaa_filter)),
        (
            ROUTE_DDNS_UNSIGNED,
            post(toggle_ddns_allow_unsigned_updates),
        ),
        (ROUTE_ZONE_ROLLBACK, post(rollback_zone_snapshot)),
        (PAGE_STATS, get(stats_page)),
        (PAGE_LOGS, get(logs_page)),
        (ROUTE_LOGS_SETTINGS, post(update_logging_settings)),
        (PAGE_SETUP, get(setup_page)),
        (ROUTE_SETUP_UPDATE, post(update_stack_settings)),
        (ROUTE_RESTART_UI, post(restart_ui_service)),
        (ROUTE_DESIRED_STATE, post(set_service_desired_state)),
        (ROUTE_CACHE_RESIZE, post(resize_cache)),
        (ROUTE_METRICS, get(metrics_api)),
        (ROUTE_WATCHDOG_STATUS, get(watchdog_status_api)),
        (ROUTE_NETDATA, get(netdata_proxy)),
        (ROUTE_ADMIN_CSS, get(admin_css)),
        (ROUTE_CHART_JS, get(chart_js)),
        (PAGE_SECONDARIES, get(secondaries_page)),
        (ROUTE_SECONDARY, delete(remove_secondary)),
        (ROUTE_SECONDARY_ROTATE, post(rotate_token)),
        (ROUTE_SECONDARY_HEALTH, post(check_secondary_health)),
        (ROUTE_SECONDARY_ADDRESS, post(set_secondary_address)),
    ];
    let mount = |routes: Vec<(&str, MethodRouter<Arc<AppState>>)>| {
        routes
            .into_iter()
            .fold(Router::new(), |router, (path, handler)| {
                router.route(path, handler)
            })
    };
    mount(public)
        .merge(mount(protected).layer(axum::middleware::from_fn_with_state(
            state.clone(),
            basic_auth,
        )))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            security_headers,
        ))
        .with_state(state)
}

// What: the whole Admin UI server.
// Why: it serves nothing until NATS is up; retry, not exit.
#[tokio::main]
async fn run() -> anyhow::Result<()> {
    init_tracing();
    let mut cfg = Config::from_env().unwrap_or_else(|e| container_start_fatal(&e));
    let ui_session_ttl = preflight(&cfg).unwrap_or_else(|e| container_start_fatal(&e));
    cfg.secondary_registration_token = registration_token(
        &cfg.secondary_registration_token,
        &cfg.registration_token_file,
    )
    .unwrap_or_else(|e| container_start_fatal(&e));
    let issuer = issuer_keypair(&cfg).unwrap_or_else(|e| container_start_fatal(&e));
    let xkey = callout_xkey(&cfg).unwrap_or_else(|e| container_start_fatal(&e));
    // What: fragment written before the NATS connect.
    // Why: dns nats-server waits for it; no deadlock.
    // From: Issue #811 | PR #1912
    if let Err(e) = write_callout_fragment(&cfg, &issuer.public_key(), &xkey.public_key()) {
        tracing::error!("Failed to write the auth_callout fragment: {e}");
    }
    let nats = connect_nats_with_retry(&cfg).await;
    let http = http_client(&config::process_env).map_err(anyhow::Error::msg)?;
    let db = open_database(&cfg.database_file)?;
    let secret = load_or_create_hex::<32>(Path::new(&cfg.session_secret_file))?;
    let state = Arc::new(AppState::new(cfg, http, nats, db, secret, ui_session_ttl));
    // What: answer auth-callout requests while running.
    // Why: secondaries are checked per connect; no reload.
    tokio::spawn(run_auth_callout(state.clone(), issuer, xkey));
    let port = state.config.listen_port;
    let any = state.config.any_bind.clone();
    let listener = tokio::net::TcpListener::bind((any.as_str(), port)).await?;
    tracing::info!("LanCache Admin UI running on http://{any}:{port}");
    axum::serve(listener, router(state)).await?;
    Ok(())
}

// What: Ok when the local server answers its health page.
// Why: the healthcheck runs this binary; no curl, no shell.
// From: Issue #1683 | PR #1912
#[tokio::main]
async fn healthcheck() -> Result<(), String> {
    let port = config::need(&config::process_env, "UI_LISTEN_PORT")?;
    let loopback = config::loopback()?;
    let wait = need_secs(&config::process_env, "HEALTH_PROBE_TIMEOUT")?;
    probe_health(&format!("http://{loopback}:{port}{ROUTE_HEALTH}"), wait).await
}

// What: drop root, then run the server.
// Why: the server must not run as root.
// From: Issue #1288 | PR #1858
fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        return healthcheck().map_err(anyhow::Error::msg);
    }
    if std::env::args().nth(1).as_deref() == Some("hash-password") {
        let phc = hash_password_from_stdin().map_err(anyhow::Error::msg)?;
        println!(
            "{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(phc)
        );
        return Ok(());
    }
    container_root_start();
    run()
}

// What: Argon2id hash of the first stdin line (PHC form).
// Why: setup.sh stores only this hash, never the password.
// From: Issue #1683 | PR #1912
fn hash_password_from_stdin() -> Result<String, String> {
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| format!("cannot read the password: {e}"))?;
    let password = line.trim_end_matches(['\r', '\n']);
    if password.is_empty() {
        return Err("the password on stdin is empty".to_string());
    }
    hash_password(password)
}

// What: unit and handler tests; files and sockets used.
// Why: the rules guard data and security.
#[cfg(test)]
mod tests {
    use super::*;
    use lancache_ng::unique_temp_dir;

    // What: cache GB from CACHE_MAX_GB or CACHE_MAX_SIZE.
    // Why: a bad value must fail; NaN would break the bar.
    // From: Issue #1069
    #[test]
    fn cache_size_reads_gb_then_size() {
        fn from(pairs: &[(&str, &str)]) -> Result<f64, String> {
            cache_max_gb_from(&|key: &str| {
                pairs
                    .iter()
                    .find(|(name, _)| *name == key)
                    .map(|(_, value)| value.to_string())
            })
        }
        assert!(from(&[]).is_err());
        assert_eq!(from(&[("CACHE_MAX_SIZE", "50g")]), Ok(50.0));
        assert_eq!(from(&[("CACHE_MAX_SIZE", "2T")]), Ok(2048.0));
        assert_eq!(from(&[("CACHE_MAX_SIZE", "512m")]), Ok(0.5));
        assert_eq!(from(&[("CACHE_MAX_GB", "120")]), Ok(120.0));
        assert_eq!(
            from(&[("CACHE_MAX_GB", ""), ("CACHE_MAX_SIZE", "30g")]),
            Ok(30.0)
        );
        for bad in ["50", "g", "xg", "-1g"] {
            assert!(
                from(&[("CACHE_MAX_SIZE", bad)]).is_err(),
                "{bad:?} must fail"
            );
        }
        for bad in ["NaN", "inf", "-1", "abc"] {
            assert!(from(&[("CACHE_MAX_GB", bad)]).is_err(), "{bad:?} must fail");
        }
    }

    // What: flags are written as 1 and 0.
    // Why: setup.sh reads the settings file this way.
    #[test]
    fn bools_are_written_as_digits() {
        assert_eq!(bool_text(true), "1");
        assert_eq!(bool_text(false), "0");
    }

    // What: the advertised NATS URL is explicit or derived.
    // Why: an unreachable internal URL must not go out.
    // From: Issue #866
    #[test]
    fn advertised_nats_url_is_explicit_or_derived() {
        let internal = "nats://nats:4222";
        assert_eq!(
            advertised_nats_url(" nats://x:1 ", "", ""),
            Some("nats://x:1".to_string())
        );
        assert_eq!(
            advertised_nats_url("", " 192.0.2.5 ", internal),
            Some("nats://192.0.2.5:4222".to_string())
        );
        let v6 = Some("nats://[2001:db8::1]:4222".to_string());
        assert_eq!(advertised_nats_url("", "[2001:db8::1]", internal), v6);
        assert_eq!(advertised_nats_url("", "2001:db8::1", internal), v6);
        for none in ["", "0.0.0.0", "::", "127.0.0.1", "::1", "no-ip"] {
            assert_eq!(advertised_nats_url("", none, internal), None, "{none:?}");
        }
        assert_eq!(advertised_nats_url("", "192.0.2.5", "nats://nats"), None);
    }

    // What: the NATS port is the digits after the colon.
    // Why: anything else must not become an advertised URL.
    #[test]
    fn nats_port_needs_digits_after_the_last_colon() {
        assert_eq!(nats_port("nats://h:4222"), Some("4222"));
        assert_eq!(nats_port("nats://h:4222//"), Some("4222"));
        for bad in ["nats://h", "nats://h:", "nats://h:42a", "h:-1", ""] {
            assert_eq!(nats_port(bad), None, "{bad:?}");
        }
    }

    // What: the session cookie header has fixed attributes.
    // Why: SameSite=Strict and HttpOnly keep scripts out.
    #[test]
    fn session_cookie_header_has_fixed_attributes() {
        let session = Session {
            csrf_token: "t".to_string(),
            cookie_value: "v1.9.t.s".to_string(),
        };
        let ttl = Duration::from_secs(60);
        let set = |secure: bool| {
            let mut response = Response::new(Body::empty());
            attach_session_cookie(&mut response, &session, ttl, secure);
            let value = response.headers().get(header::SET_COOKIE).unwrap();
            value.to_str().unwrap().to_string()
        };
        let plain = "lancache_ui_session=v1.9.t.s; Path=/; SameSite=Strict; HttpOnly; Max-Age=60";
        assert_eq!(set(false), plain);
        assert_eq!(set(true), format!("{plain}; Secure"));
    }

    const TEXT_KEYS: [&str; 42] = [
        "LANCACHE_REPO_URL",
        "ANY_BIND_IP",
        "CA_CERT_FILE",
        "NTP_PORT",
        "DHCP_DOMAIN",
        "RAW_CONTENT_URL",
        "SETUP_SCRIPT_PATH",
        "CONTAINER_NAME_PROXY",
        "CONTAINER_NAME_DNS",
        "CONTAINER_NAME_DHCP",
        "CONTAINER_NAME_UI",
        "PROXY_STATUS_URL",
        "IP_HTTP",
        "IP_HTTPS",
        "NATS_URL",
        "LANCACHE_IMAGE_TAG",
        "NTP_UPSTREAM_SERVERS",
        "TEMPLATE_DIR",
        "CDN_DOMAINS_FILE",
        "CACHE_DIR",
        "DNS_STATE_DIR",
        "NETDATA_URL",
        "DHCP_API_HOST",
        "KEA_CTRL_USER",
        "UI_SETTINGS_FILE",
        "KEA_CONFIG_SNAPSHOT_DIR",
        "DHCP_PROBE_REQUEST_FILE",
        "DHCP_PROBE_RESULT_FILE",
        "DNS_URL",
        "NETDATA_ALARMS_FILE",
        "NATS_ISSUER_SEED_PATH",
        "NATS_XKEY_SEED_PATH",
        "LANCACHE_IMAGE_REGISTRY",
        "LANCACHE_IMAGE_PREFIX",
        "NATS_AUTH_CALLOUT_PATH",
        "UI_SESSION_SECRET_FILE",
        "UI_DATABASE_FILE",
        "SECONDARY_REGISTRATION_TOKEN_FILE",
        "SYSLOG_LOG_ROOT",
        "STATUS_FILE",
        "DESIRED_STATE_FILE",
        "LANCACHE_SHARED_SECRET_DIR",
    ];

    const NUMBER_KEYS: [(&str, &str); 24] = [
        ("UI_WATCHDOG_REFRESH_MS", "11"),
        ("UI_DASHBOARD_REFRESH_MS", "12"),
        ("UI_STATS_REFRESH_MS", "13"),
        ("UI_STATS_POINTS", "14"),
        ("CONVERGE_TIMER_INTERVAL_MINUTES", "15"),
        ("RESTART_AFTER", "3"),
        ("DHCP_LEASE_TIME_MIN", "60"),
        ("DHCP_LEASE_TIME_MAX", "604800"),
        ("DHCP_MAX_LEASE_FACTOR", "2"),
        ("PDNS_AUTH_PORT", "5300"),
        ("DNS_PORT", "53"),
        ("PDNS_AUTH_API_PORT", "8081"),
        ("PDNS_HTTP_API_PORT", "8082"),
        ("DNS_ROLLBACK_PORT", "8083"),
        ("KEA_CTRL_PORT", "8000"),
        ("DHCP_LEASE_TIME", "86400"),
        ("UI_SESSION_TTL_SECONDS", "3600"),
        ("UI_SESSION_TTL_MAX_SECONDS", "31536000"),
        ("RETRY_BACKOFF_START", "1"),
        ("RETRY_BACKOFF_MAX", "30"),
        ("KEEP_KNOWN_GOOD_CONFIGS", "7"),
        ("UI_LOGS_MAX_ENTRIES", "250"),
        ("UI_LISTEN_PORT", "8081"),
        ("SYSLOG_MAX_GB", "3"),
    ];

    const FLAG_KEYS: [&str; 11] = [
        "HTTPS_ENABLED",
        "UI_SECURITY_HEADERS",
        "LANCACHE_DEV_MODE",
        "AUTO_UPDATE_ENABLED",
        "NTP_ENABLED",
        "NTP_AUTO_DHCP",
        "ALLOW_INSECURE_UI",
        "LOGGING_PROXY_ENABLED",
        "LOGGING_DNS_ENABLED",
        "LOGGING_DHCP_ENABLED",
        "LOGGING_UI_ENABLED",
    ];

    // What: a complete env; each text value names its key.
    // Why: a swapped field then shows in the value.
    fn full_env() -> HashMap<String, String> {
        let mut env: HashMap<String, String> = HashMap::new();
        for key in TEXT_KEYS {
            env.insert(key.to_string(), format!("v-{key}"));
        }
        for (key, value) in NUMBER_KEYS {
            env.insert(key.to_string(), value.to_string());
        }
        for key in FLAG_KEYS {
            env.insert(key.to_string(), "true".to_string());
        }
        env.insert("CACHE_MAX_SIZE".to_string(), "50g".to_string());
        env
    }

    fn load_from(env: &HashMap<String, String>) -> Result<Config, String> {
        Config::load(&|key: &str| env.get(key).cloned())
    }

    // What: each missing or bad key stops the start.
    // Why: compose owns every value; no silent default.
    #[test]
    fn config_load_names_the_missing_or_bad_key() {
        let all = TEXT_KEYS
            .iter()
            .copied()
            .chain(NUMBER_KEYS.iter().map(|(key, _)| *key))
            .chain(FLAG_KEYS);
        for key in all {
            let mut env = full_env();
            env.remove(key);
            let err = load_from(&env).err().unwrap_or_default();
            assert!(err.contains(key), "{key}: {err:?}");
        }
        for key in FLAG_KEYS {
            let mut env = full_env();
            env.insert(key.to_string(), "maybe".to_string());
            assert!(load_from(&env).is_err(), "{key} junk");
        }
        for (key, junk) in [
            ("UI_SESSION_TTL_SECONDS", "31536001"),
            ("UI_LISTEN_PORT", "65536"),
            ("KEEP_KNOWN_GOOD_CONFIGS", "0"),
            ("DHCP_LEASE_TIME", "59"),
            ("DHCP_LEASE_TIME", "604801"),
            ("CACHE_MAX_SIZE", "50"),
        ] {
            let mut env = full_env();
            env.insert(key.to_string(), junk.to_string());
            assert!(load_from(&env).is_err(), "{key}={junk}");
        }
        let mut env = full_env();
        env.insert("SYSLOG_MAX_GB".to_string(), "9999999".to_string());
        assert_eq!(
            load_from(&env).unwrap().syslog_max_gb as u64,
            config::SYSLOG_MAX_GB.max
        );
    }

    // What: the watchdog document is fresh, stale, absent.
    // Why: the dashboard shows each case differently.
    // From: Issue #870
    #[test]
    fn watchdog_json_reports_fresh_stale_and_missing() {
        let dir = unique_temp_dir("watchdog-json");
        let file = dir.join("status.json");
        let path = file.to_string_lossy().into_owned();
        assert_eq!(watchdog_json(&path, 3), json!({"state": "unavailable"}));
        fs::write(&file, "not json").unwrap();
        assert_eq!(watchdog_json(&path, 3), json!({"state": "unavailable"}));
        let doc = r#"{"updated":"t1","interval_secs":30,"disk":{"cache":{"pct":10,"status":"green"}},
            "services":{"zeta":{"status":"red","health":"x","failures":2},
                        "ui":{"status":"green","health":"healthy","failures":0},
                        "alpha":{"status":"green","health":"","failures":0},
                        "proxy":{"status":"amber","health":"starting","failures":1}}}"#;
        fs::write(&file, doc).unwrap();
        let fresh = watchdog_json(&path, 3);
        let names: Vec<&str> = fresh["services"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["alpha", "proxy", "ui", "zeta"]);
        assert_eq!(
            fresh["services"][1],
            json!({"name": "proxy", "status": "amber", "health": "starting", "failures": 1})
        );
        assert_eq!(fresh["state"], "fresh");
        assert_eq!(fresh["updated"], "t1");
        assert_eq!(fresh["disk"]["cache"]["pct"], 10);
        assert!(fresh.get("age_seconds").is_none());
        let old = SystemTime::now() - Duration::from_secs(1000);
        let handle = OpenOptions::new().write(true).open(&file).unwrap();
        handle.set_modified(old).unwrap();
        let stale = watchdog_json(&path, 3);
        assert_eq!(stale["state"], "stale");
        let age = stale["age_seconds"].as_u64().unwrap();
        assert!((1000..1100).contains(&age), "age {age}");
        assert_eq!(stale["updated"], "t1");
        assert_eq!(stale["services"].as_array().unwrap().len(), 4);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: byte counts print in B, KB, MB and GB.
    // Why: logs and stats show sizes in one spelling.
    #[test]
    fn byte_counts_print_in_the_right_unit() {
        for (bytes, text) in [
            (0, "0 B"),
            (1023, "1023 B"),
            (1024, "1.0 KB"),
            (1536, "1.5 KB"),
            (1_048_575, "1024.0 KB"),
            (1_048_576, "1.0 MB"),
            (1_073_741_823, "1024.0 MB"),
            (1_073_741_824, "1.0 GB"),
            (1_610_612_736, "1.5 GB"),
        ] {
            assert_eq!(format_bytes(bytes), text, "{bytes}");
        }
    }

    fn syslog_entry(host: &str, timestamp: &str) -> SyslogEntry {
        SyslogEntry {
            timestamp: timestamp.to_string(),
            host: host.to_string(),
            program: "p".to_string(),
            message: format!("{host}-{timestamp}"),
        }
    }

    // What: syslog files are read plain or from xz.
    // Why: closed files are xz; junk xz reads as None.
    #[test]
    fn syslog_files_are_decompressed_by_extension() {
        use std::io::Write as _;
        let dir = unique_temp_dir("syslog-read");
        fs::write(dir.join("a.log"), "plain\n").unwrap();
        let mut xz = liblzma::write::XzEncoder::new(Vec::new(), 6);
        xz.write_all(b"xz data\n").unwrap();
        fs::write(dir.join("b.log.xz"), xz.finish().unwrap()).unwrap();
        fs::write(dir.join("d.log.xz"), "not xz").unwrap();
        fs::write(dir.join("f.log"), b"bad \xff byte").unwrap();
        let read = |name: &str| read_syslog_file(&dir.join(name));
        assert_eq!(read("a.log").as_deref(), Some("plain\n"));
        assert_eq!(read("b.log.xz").as_deref(), Some("xz data\n"));
        assert_eq!(read("d.log.xz"), None);
        assert_eq!(read("missing.log"), None);
        assert_eq!(read("f.log").as_deref(), Some("bad \u{fffd} byte"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: IPv4 addresses map to PTR names and zones.
    // Why: only zones the stack provisions may hold a PTR.
    #[test]
    fn ptr_names_and_reverse_zones_follow_the_address() {
        let ip = |text: &str| text.parse::<Ipv4Addr>().unwrap();
        assert_eq!(
            ptr_name_for_ipv4(ip("192.0.2.17")),
            "17.2.0.192.in-addr.arpa."
        );
        assert_eq!(
            ipv4_from_ptr_name("17.2.0.192.in-addr.arpa."),
            Some(ip("192.0.2.17"))
        );
        assert_eq!(
            ipv4_from_ptr_name("17.2.0.192.IN-ADDR.ARPA"),
            Some(ip("192.0.2.17"))
        );
        for bad in [
            "2.0.192.in-addr.arpa.",
            "x.2.0.192.in-addr.arpa.",
            "1.2.0.192.example.",
            "256.2.0.192.in-addr.arpa.",
        ] {
            assert_eq!(ipv4_from_ptr_name(bad), None, "{bad}");
        }
        for (addr, zone) in [
            ("10.1.2.3", Some("10.in-addr.arpa.")),
            ("192.168.5.5", Some("168.192.in-addr.arpa.")),
            ("172.16.0.1", Some("16.172.in-addr.arpa.")),
            ("172.31.0.1", Some("31.172.in-addr.arpa.")),
            ("172.15.0.1", None),
            ("172.32.0.1", None),
            ("8.8.8.8", None),
        ] {
            assert_eq!(reverse_zone_for_ipv4(ip(addr)).as_deref(), zone, "{addr}");
        }
        assert_eq!(parse_private_ipv4(" 10.0.0.5 "), Some(ip("10.0.0.5")));
        assert_eq!(parse_private_ipv4("192.168.1.1"), Some(ip("192.168.1.1")));
        for public in ["8.8.8.8", "127.0.0.1", "x", ""] {
            assert_eq!(parse_private_ipv4(public), None, "{public:?}");
        }
    }

    // What: backoff doubles the delay up to a cap.
    // Why: one step serves every NATS retry loop.
    #[tokio::test(start_paused = true)]
    async fn backoff_doubles_up_to_the_cap() {
        let policy = Backoff {
            start: Duration::from_secs(1),
            max: Duration::from_secs(5),
        };
        let mut delay = policy.start;
        backoff(&mut delay, &policy).await;
        assert_eq!(delay, Duration::from_secs(2));
        backoff(&mut delay, &policy).await;
        assert_eq!(delay, Duration::from_secs(4));
        backoff(&mut delay, &policy).await;
        assert_eq!(delay, policy.max);
    }

    fn nats_env() -> HashMap<String, String> {
        let mut env = full_env();
        let extra = [
            ("NATS_UI_USER", "ui"),
            ("NATS_UI_PASSWORD", "pw-ui"),
            ("NATS_DNS_WRITER_USER", "dnsw"),
            ("NATS_DNS_WRITER_PASSWORD", "pw-dnsw"),
            ("NATS_CALLOUT_USER", "callout"),
            ("NATS_CALLOUT_PASSWORD", "pw-callout"),
            ("NATS_SYS_USER", "sys"),
            ("NATS_SYS_PASSWORD", "pw-sys"),
        ];
        for (key, value) in extra {
            env.insert(key.to_string(), value.to_string());
        }
        env
    }

    // What: a signed JWT has header, claims, a valid sig.
    // Why: nats-server rejects any unsigned or altered JWT.
    #[test]
    fn nats_jwt_is_signed_and_carries_its_claims() {
        let signer = KeyPair::new_account();
        let token = encode_nats_jwt(json!({"sub": "s", "n": 1}), &signer).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(b64url(br#"{"typ":"JWT","alg":"ed25519-nkey"}"#), parts[0]);
        let claims = decode_jwt_payload(&token).unwrap();
        assert_eq!(claims["sub"], "s");
        assert_eq!(claims["n"], 1);
        let jti = claims["jti"].as_str().unwrap();
        assert_eq!(jti.len(), 52);
        assert!(
            jti.bytes()
                .all(|b| b.is_ascii_uppercase() || (b'2'..=b'7').contains(&b))
        );
        let signature = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[2])
            .unwrap();
        let input = format!("{}.{}", parts[0], parts[1]);
        assert!(signer.verify(input.as_bytes(), &signature).is_ok());
        assert!(signer.verify(b"other", &signature).is_err());
        let other = encode_nats_jwt(json!({"sub": "t"}), &signer).unwrap();
        let other_jti = decode_jwt_payload(&other).unwrap()["jti"].clone();
        assert_ne!(other_jti, claims["jti"]);
        assert_eq!(b64url(&[0xfb, 0xff, 0xfe]), "-__-");
    }

    // What: addresses, MACs and CIDRs follow strict shapes.
    // Why: Kea entries and form input must compare equal.
    #[test]
    fn address_text_follows_strict_shapes() {
        assert_eq!(ipv4(" 10.0.0.1 "), Some(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(ipv4("10.0.0"), None);
        for good in ["aa:bb:cc:dd:ee:ff", "AA-BB-CC-DD-EE-FF", "aabbccddeeff"] {
            assert!(is_valid_mac(good), "{good}");
            assert_eq!(normalize_mac(good), "aa:bb:cc:dd:ee:ff");
        }
        for bad in [
            "",
            "aa:bb:cc:dd:ee",
            "aa:bb:cc:dd:ee:fg",
            "aa:bb:cc:dd:ee:ff:00",
            "aabbccddeeff0",
        ] {
            assert!(!is_valid_mac(bad), "{bad}");
        }
        assert_eq!(normalize_mac("A"), "a");
        assert_eq!(
            parse_cidr("198.51.100.0/24"),
            Some((0xC633_6400, 0xFFFF_FF00))
        );
        assert_eq!(parse_cidr(" 10.0.0.0/8"), Some((0x0A00_0000, 0xFF00_0000)));
        assert_eq!(parse_cidr("10.0.0.0/32"), Some((0x0A00_0000, u32::MAX)));
        assert_eq!(parse_cidr("0.0.0.0/0"), Some((0, 0)));
        for bad in [
            "10.1.2.3/0",
            "10.0.0.1/24",
            "10.0.0.0/33",
            "10.0.0.0",
            "x/24",
            "10.0.0.0/-1",
            "10.0.0.0/ 24",
            "10.0.0.0/",
        ] {
            assert_eq!(parse_cidr(bad), None, "{bad}");
        }
    }

    fn subnet_form() -> Vec<(&'static str, &'static str)> {
        vec![
            ("subnet", "198.51.100.0/24"),
            ("pool_start", "198.51.100.10"),
            ("pool_end", "198.51.100.200"),
            ("gateway", "198.51.100.1"),
            ("dns_primary", "198.51.100.2"),
            ("dns_secondary", ""),
            ("ntp_servers", ""),
            ("domain", ""),
            ("lease_time", "3600"),
        ]
    }

    // What: custom options are added and removed once.
    // Why: a double submit must not apply both.
    #[test]
    fn custom_option_edits_add_and_remove_once() {
        let mut subnet = json!({"id": 1});
        let key = CustomOptionKey::Numeric(66);
        edit_custom_option(&mut subnet, key, "tftp", true).unwrap();
        assert_eq!(
            subnet["option-data"],
            json!([{"space": "dhcp4", "code": 66, "data": "tftp"}])
        );
        assert_eq!(
            edit_custom_option(&mut subnet, key, "tftp", true),
            Err("custom option already exists")
        );
        edit_custom_option(&mut subnet, key, "other", true).unwrap();
        assert_eq!(subnet["option-data"].as_array().unwrap().len(), 2);
        edit_custom_option(&mut subnet, key, "tftp", false).unwrap();
        assert_eq!(
            subnet["option-data"],
            json!([{"space": "dhcp4", "code": 66, "data": "other"}])
        );
        assert_eq!(
            edit_custom_option(&mut subnet, key, "tftp", false),
            Err("custom option not found")
        );
        let other_code = CustomOptionKey::Numeric(67);
        assert_eq!(
            edit_custom_option(&mut subnet, other_code, "other", false),
            Err("custom option not found")
        );
        let pxe = CustomOptionKey::Pxe("next-server");
        edit_custom_option(&mut subnet, pxe, "10.0.0.9", true).unwrap();
        assert_eq!(subnet["next-server"], "10.0.0.9");
        assert_eq!(
            edit_custom_option(&mut subnet, pxe, "10.0.0.9", true),
            Err("custom option already exists")
        );
        edit_custom_option(&mut subnet, pxe, "10.0.0.8", true).unwrap();
        assert_eq!(subnet["next-server"], "10.0.0.8");
        assert_eq!(
            edit_custom_option(&mut subnet, pxe, "10.0.0.9", false),
            Err("custom option not found")
        );
        assert_eq!(subnet["next-server"], "10.0.0.8");
        edit_custom_option(&mut subnet, pxe, "10.0.0.8", false).unwrap();
        assert!(subnet.get("next-server").is_none());
        let mut scalar = json!(5);
        assert_eq!(
            edit_custom_option(&mut scalar, key, "x", true),
            Err("subnet not an object")
        );
        let mut bad = json!({"option-data": 5});
        assert_eq!(
            edit_custom_option(&mut bad, key, "x", true),
            Err("option-data not an array")
        );
    }

    // What: banner codes map to fixed text only.
    // Why: a URL parameter must never become page text.
    #[test]
    fn domain_error_banners_are_fixed_text() {
        for code in [
            "invalid_domain",
            "ddns_allow_unsigned_no_key",
            "zone_rollback_failed",
            "zone_rollback_unknown",
        ] {
            assert!(domain_error_message(code).is_some(), "{code}");
        }
        assert!(
            domain_error_message("invalid_domain")
                .unwrap()
                .starts_with("That domain was not added:")
        );
        assert!(
            domain_error_message("zone_rollback_failed")
                .unwrap()
                .starts_with("The zone rollback did not complete:")
        );
        assert!(
            domain_error_message("zone_rollback_unknown")
                .unwrap()
                .starts_with("The zone rollback request timed out")
        );
        assert!(
            domain_error_message("ddns_allow_unsigned_no_key")
                .unwrap()
                .starts_with("Allowing unsigned DNS updates")
        );
        assert_eq!(domain_error_message("<script>"), None);
        assert_eq!(domain_error_message(""), None);
    }

    fn cdn(text: &str) -> CdnDomain {
        parse_cdn_domain(text).expect("a valid entry")
    }

    // What: a removal request targets a domain or raw text.
    // Why: malformed legacy lines must stay removable.
    #[test]
    fn removal_targets_cover_legacy_lines() {
        assert!(
            matches!(delete_target(" Steam.com "), Some(DeleteTarget::Domain(d)) if d.domain == "steam.com")
        );
        assert!(matches!(delete_target("com"), Some(DeleteTarget::Raw(raw)) if raw == "com"));
        assert!(matches!(
            delete_target("bad_line!"),
            Some(DeleteTarget::Raw(_))
        ));
        for refused in ["", "  ", "# note", "a\u{7}b"] {
            assert!(delete_target(refused).is_none(), "{refused:?}");
        }
        let text = "steam.com\r\n!steam.com\n.steam.com\nBad_Line!\nkeep.com\n";
        let by_domain = DeleteTarget::Domain(cdn("steam.com"));
        assert_eq!(
            without_domain(text, &by_domain).as_deref(),
            Some("!steam.com\n.steam.com\nBad_Line!\nkeep.com\n")
        );
        let by_raw = DeleteTarget::Raw("bad_line!".to_string());
        assert_eq!(
            without_domain(text, &by_raw).as_deref(),
            Some("steam.com\r\n!steam.com\n.steam.com\nkeep.com\n")
        );
        assert_eq!(
            without_domain(text, &DeleteTarget::Raw("none".to_string())),
            None
        );
    }

    // What: a flush for a name has no zone or record data.
    // Why: CDN changes have no record to confirm.
    #[test]
    fn name_flushes_carry_the_name_only() {
        let request = flush_name("steam.com");
        assert_eq!(request.domain, "steam.com");
        assert!(request.zone.is_none() && request.record_type.is_none());
        assert!(request.expected_content.is_none() && request.expected_ttl.is_none());
    }

    // What: PTR targets and locations follow the zones.
    // Why: only provisioned zones exist; others would 404.
    #[test]
    fn ptr_targets_and_locations_follow_the_zones() {
        assert_eq!(
            ptr_location("10.1.2.3"),
            Some((
                "10.in-addr.arpa.".to_string(),
                "3.2.1.10.in-addr.arpa.".to_string()
            ))
        );
        assert_eq!(ptr_location("8.8.8.8"), None);
        assert_eq!(ptr_location("x"), None);
        assert_eq!(
            normalize_ptr_target(" Host.Example.com "),
            Some("host.example.com.".to_string())
        );
        assert_eq!(
            normalize_ptr_target("host.lan."),
            Some("host.lan.".to_string())
        );
        for bad in ["", "_x.lan", "*.lan", "bad name"] {
            assert_eq!(normalize_ptr_target(bad), None, "{bad:?}");
        }
        let rrsets = vec![json!({"name": "5.0.0.10.in-addr.arpa.", "type": "PTR",
            "records": [{"content": "a.lan."}, {"content": "b.lan.", "disabled": false}, {"disabled": false}]})];
        let rows = ptr_rows(&rrsets);
        let seen: Vec<(&str, &str, u32, u32)> = rows
            .iter()
            .map(|r| (r.ip.as_str(), r.hostname.as_str(), r.ttl, r.sort_key))
            .collect();
        assert_eq!(
            seen,
            [
                ("10.0.0.5", "a.lan.", 0, 0x0A00_0005),
                ("10.0.0.5", "b.lan.", 0, 0x0A00_0005)
            ]
        );
        assert!(ptr_rows(&[json!({"name": "x", "type": "PTR"})]).is_empty());
    }

    // What: the dirs the ui writes follow its own config.
    // Why: chown follows the configured paths, no 2nd list.
    #[test]
    fn written_dirs_follow_the_configured_paths() {
        let mut env = nats_env();
        let paths = [
            ("CDN_DOMAINS_FILE", "/a/cdn.txt"),
            ("NETDATA_ALARMS_FILE", "/b/alarms.json"),
            ("NATS_XKEY_SEED_PATH", "/c/xkey"),
            ("DESIRED_STATE_FILE", "/a/desired.json"),
            ("NATS_AUTH_CALLOUT_PATH", "/d/auth.conf"),
            ("DHCP_PROBE_REQUEST_FILE", "/a/probe"),
            ("DNS_STATE_DIR", "/s"),
            ("KEA_CONFIG_SNAPSHOT_DIR", "/k"),
        ];
        for (key, value) in paths {
            env.insert(key.to_string(), value.to_string());
        }
        let cfg = load_from(&env).unwrap();
        let dirs = ui_written_dirs(&cfg, Path::new("/l/ui.log"));
        let want: Vec<PathBuf> = ["/a", "/b", "/c", "/d", "/k", "/l", "/s"]
            .iter()
            .map(PathBuf::from)
            .collect();
        assert_eq!(dirs, want);
        let bare = ui_written_dirs(&cfg, Path::new("ui.log"));
        assert_eq!(bare.len(), 6);
    }

    // What: ownership and modes are set on a log tree.
    // Why: the shared log reader gid must keep read access.
    #[test]
    fn log_dirs_open_to_the_group_without_following_links() {
        let dir = unique_temp_dir("chown");
        let own = fs::metadata(&dir).unwrap();
        let (uid, gid) = (own.uid(), own.gid());
        fs::create_dir(dir.join("sub")).unwrap();
        fs::write(dir.join("sub/f"), "x").unwrap();
        chown_tree(&dir, uid, gid).unwrap();
        assert_eq!(fs::metadata(dir.join("sub/f")).unwrap().gid(), gid);
        assert!(chown_tree(&dir.join("missing"), uid, gid).is_err());
        let logs = dir.join("logs");
        fs::create_dir(&logs).unwrap();
        fs::write(logs.join("a.log"), "x").unwrap();
        fs::set_permissions(logs.join("a.log"), fs::Permissions::from_mode(0o600)).unwrap();
        fs::create_dir(logs.join("inner")).unwrap();
        open_log_dir_to_group(&logs, gid).unwrap();
        assert_eq!(
            fs::metadata(&logs).unwrap().permissions().mode() & 0o7777,
            0o2775
        );
        assert_eq!(
            fs::metadata(logs.join("a.log"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o640
        );
        assert_eq!(fs::metadata(logs.join("a.log")).unwrap().gid(), gid);
        assert_ne!(
            fs::metadata(logs.join("inner"))
                .unwrap()
                .permissions()
                .mode()
                & 0o7777,
            0o2775
        );
        assert!(open_log_dir_to_group(&dir.join("missing"), gid).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the secondaries DB is created and upgraded.
    // Why: old installs lack columns; additive changes.
    // From: Issue #583
    #[test]
    fn the_database_is_created_and_upgraded() {
        let dir = unique_temp_dir("db");
        let path = dir.join("ui.db").to_string_lossy().into_owned();
        let columns = |conn: &Connection| -> Vec<String> {
            let mut stmt = conn.prepare("PRAGMA table_info(secondaries)").unwrap();
            stmt.query_map([], |row| row.get(1))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        let want = [
            "name",
            "nats_token",
            "consumer_name",
            "registered_at",
            "last_seen",
            "nats_user",
            "nats_password_hash",
            "address",
        ];
        let conn = open_database(&path).unwrap();
        assert_eq!(columns(&conn), want);
        drop(conn);
        let conn = open_database(&path).unwrap();
        assert_eq!(columns(&conn), want);
        let insert = |name: &str, user: Option<&str>| {
            conn.execute(
                "INSERT INTO secondaries (name, nats_token, consumer_name, registered_at, nats_user) VALUES (?1, 't', ?1, 1, ?2)",
                rusqlite::params![name, user],
            )
        };
        insert("a", Some("u1")).unwrap();
        assert!(
            insert("b", Some("u1")).is_err(),
            "one NATS identity per row"
        );
        insert("c", None).unwrap();
        insert("d", None).unwrap();
        let old = dir.join("old.db").to_string_lossy().into_owned();
        let legacy = Connection::open(&old).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE secondaries (name TEXT PRIMARY KEY, nats_token TEXT NOT NULL, consumer_name TEXT NOT NULL UNIQUE, registered_at INTEGER NOT NULL, last_seen INTEGER);
                 INSERT INTO secondaries VALUES ('old', 'tok', 'cons', 5, NULL);",
            )
            .unwrap();
        drop(legacy);
        let upgraded = open_database(&old).unwrap();
        assert_eq!(columns(&upgraded), want);
        let kept: String = upgraded
            .query_row(
                "SELECT nats_token FROM secondaries WHERE name='old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(kept, "tok");
        assert!(open_database("/no/such/dir/ui.db").is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the issuer and xkey come from seed or file.
    // Why: a restart must not rotate either of them.
    // From: Issue #583
    #[test]
    fn nats_keys_come_from_a_seed_or_a_persisted_file() {
        let dir = unique_temp_dir("keys");
        let mut env = nats_env();
        let issuer_file = dir.join("issuer.seed").to_string_lossy().into_owned();
        let xkey_file = dir.join("xkey.seed").to_string_lossy().into_owned();
        env.insert("NATS_ISSUER_SEED_PATH".to_string(), issuer_file.clone());
        env.insert("NATS_XKEY_SEED_PATH".to_string(), xkey_file.clone());
        let cfg = load_from(&env).unwrap();
        let first = issuer_keypair(&cfg).unwrap();
        assert!(first.public_key().starts_with('A'));
        assert_eq!(
            issuer_keypair(&cfg).unwrap().public_key(),
            first.public_key()
        );
        assert_eq!(
            fs::read_to_string(&issuer_file).unwrap(),
            first.seed().unwrap()
        );
        let xkey = callout_xkey(&cfg).unwrap();
        assert!(xkey.public_key().starts_with('X'));
        assert_eq!(callout_xkey(&cfg).unwrap().public_key(), xkey.public_key());
        let seeded = KeyPair::new_account();
        env.insert("NATS_ISSUER_SEED".to_string(), seeded.seed().unwrap());
        let x_seeded = XKey::new();
        env.insert("NATS_XKEY_SEED".to_string(), x_seeded.seed().unwrap());
        let cfg = load_from(&env).unwrap();
        assert_eq!(
            issuer_keypair(&cfg).unwrap().public_key(),
            seeded.public_key()
        );
        assert_eq!(
            callout_xkey(&cfg).unwrap().public_key(),
            x_seeded.public_key()
        );
        env.insert("NATS_ISSUER_SEED".to_string(), "junk".to_string());
        env.insert("NATS_XKEY_SEED".to_string(), "junk".to_string());
        let cfg = load_from(&env).unwrap();
        assert!(
            issuer_keypair(&cfg)
                .unwrap_err()
                .starts_with("NATS_ISSUER_SEED is not a valid NKey seed:")
        );
        assert!(
            callout_xkey(&cfg)
                .err()
                .unwrap()
                .starts_with("NATS_XKEY_SEED is not a valid NKey seed:")
        );
        env.remove("NATS_ISSUER_SEED");
        env.remove("NATS_XKEY_SEED");
        fs::write(&issuer_file, "junk").unwrap();
        fs::write(&xkey_file, "junk").unwrap();
        let cfg = load_from(&env).unwrap();
        assert!(
            issuer_keypair(&cfg)
                .unwrap_err()
                .contains("issuer NKey seed at")
        );
        assert!(callout_xkey(&cfg).err().unwrap().contains("xkey seed at"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a UI on a free port with an offline NATS.
    // Why: handler tests then pass the real router.
    async fn test_server(
        tweak: impl FnOnce(&mut Config),
    ) -> (String, Arc<AppState>, std::path::PathBuf) {
        let dir = unique_temp_dir("ui-server");
        let mut cfg = load_from(&full_env()).expect("a complete env loads");
        cfg.shared_secret_dir = dir.to_string_lossy().to_string();
        cfg.hsts_mode = HstsMode::Auto;
        cfg.template_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/src/templates").to_string();
        tweak(&mut cfg);
        let http = lancache_ng::http_client(&lancache_ng::test_http_env).unwrap();
        let nats = async_nats::ConnectOptions::new()
            .retry_on_initial_connect()
            .connect("nats://127.0.0.1:1")
            .await
            .unwrap();
        let db = open_database(&dir.join("ui.db").to_string_lossy()).unwrap();
        let state = Arc::new(AppState::new(
            cfg,
            http,
            nats,
            db,
            [9u8; 32],
            Duration::from_secs(3600),
        ));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(axum::serve(listener, router(state.clone())).into_future());
        (base, state, dir)
    }

    // What: open a session: cookie header and CSRF token.
    // Why: protected POSTs need both, like a browser has.
    async fn open_session(base: &str, state: &AppState) -> (String, String) {
        let response = reqwest::get(format!("{base}{ROUTE_ADMIN_CSS}"))
            .await
            .unwrap();
        let set = response.headers()[header::SET_COOKIE].to_str().unwrap();
        let pair = set.split(';').next().unwrap().to_string();
        let value = pair.strip_prefix("lancache_ui_session=").unwrap();
        let session = validate_session(value, &state.ui_session_secret).unwrap();
        (pair, session.csrf_token)
    }

    // What: alarms are stored only with the right token.
    // Why: an unset token must reject every sender.
    #[tokio::test]
    async fn alarm_ingest_checks_token_and_payload() {
        let dir = unique_temp_dir("alarm-ingest");
        let file = dir.join("alarms.json").to_string_lossy().to_string();
        let path = file.clone();
        let (base, _state, sdir) = test_server(move |cfg| {
            cfg.netdata_alarm_token = "secret-token".to_string();
            cfg.netdata_alarms_file = path;
        })
        .await;
        let client = reqwest::Client::new();
        let url = format!("{base}{ALARM_INGEST_PATH}");
        let alarm = json!({
            "unique_id": 5, "alarm_id": 1, "event_id": 2, "when": 100,
            "name": "disk", "chart": "c", "host": "h", "status": "CRITICAL",
            "old_status": "WARNING", "value_string": "9", "units": "%",
            "info": "full", "duration": 3
        });
        let send = |token: Option<&str>, body: String| {
            let mut request = client.post(&url).body(body);
            if let Some(token) = token {
                request = request.header("X-Netdata-Alarm-Token", token);
            }
            request.send()
        };
        let none = send(None, alarm.to_string()).await.unwrap();
        assert_eq!(none.status(), 401);
        let wrong = send(Some("bad"), alarm.to_string()).await.unwrap();
        assert_eq!(wrong.status(), 401);
        let empty = send(Some(""), alarm.to_string()).await.unwrap();
        assert_eq!(empty.status(), 401);
        let malformed = send(Some("secret-token"), "{".to_string()).await.unwrap();
        assert_eq!(malformed.status(), 400);
        assert!(read_alarms(&file).is_empty());
        let ok = send(Some("secret-token"), alarm.to_string()).await.unwrap();
        assert_eq!(ok.status(), 204);
        let again = send(Some("secret-token"), alarm.to_string()).await.unwrap();
        assert_eq!(again.status(), 204);
        let stored = read_alarms(&file);
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].unique_id, 5);
        assert_eq!(stored[0].name, "disk");
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);

        let (base, _state, sdir) = test_server(|cfg| {
            cfg.netdata_alarm_token = String::new();
        })
        .await;
        let open = client
            .post(format!("{base}{ALARM_INGEST_PATH}"))
            .header("X-Netdata-Alarm-Token", "")
            .body(alarm.to_string())
            .send()
            .await
            .unwrap();
        assert_eq!(open.status(), 401);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: NTP entries must be IPv4 literals or names.
    // Why: a typo like 1.2.3 must not reach DNS.
    #[tokio::test]
    async fn ntp_servers_resolve_or_are_rejected() {
        let ok = resolve_ntp_servers("192.168.1.1, localhost").await;
        assert_eq!(ok, Ok("192.168.1.1, 127.0.0.1".to_string()));
        for bad in ["1.2.3", "300.1.1.1", "12345", "1.2.3.4.5"] {
            let err = resolve_ntp_servers(bad).await.unwrap_err();
            assert_eq!(
                err,
                format!("NTP server '{bad}' is not a valid IPv4 address")
            );
        }
        assert_eq!(resolve_ntp_servers("").await, Ok(String::new()));
    }

    // What: a 12-byte DNS answer is complete, not short.
    // Why: the header alone is a valid, answer-less reply.
    #[test]
    fn a_header_only_dns_answer_is_not_short() {
        let mut header = vec![0x12, 0x34, 0x84, 0x00, 0, 0, 0, 0, 0, 0, 0, 0];
        let result = classify_soa(&header, 0x1234).unwrap();
        assert_eq!(result.status, "error");
        assert_eq!(result.detail, "NOERROR but no answer for lan. SOA");
        header.truncate(11);
        let short = classify_soa(&header, 0x1234).unwrap_err();
        assert_eq!(short, "short DNS response (<12 bytes)");
    }

    // What: the fair window shares lines among busy hosts.
    // Why: a busy host must not push others out of view.
    #[test]
    fn fair_window_shares_lines_between_busy_hosts() {
        let mut entries: Vec<SyslogEntry> = (4..=9)
            .map(|n| syslog_entry("a", &format!("t0{n}")))
            .collect();
        entries.extend((1..=3).map(|n| syslog_entry("b", &format!("t0{n}"))));
        let kept: Vec<String> = fair_window(entries, 6)
            .into_iter()
            .map(|e| e.timestamp)
            .collect();
        assert_eq!(kept, ["t01", "t02", "t03", "t07", "t08", "t09"]);
    }

    // What: only YYYYMMDD names count as retention days.
    // Why: a stray file must not inflate the day count.
    #[test]
    fn syslog_stats_count_only_dated_files() {
        let dir = unique_temp_dir("syslog-stats");
        let host = dir.join("host1");
        fs::create_dir_all(&host).unwrap();
        for name in [
            "20260101.log",
            "20260101.log.xz",
            "20260102.log",
            "2026010x.log",
            "123.log",
            "notes",
        ] {
            fs::write(host.join(name), "12345").unwrap();
        }
        let stats = syslog_stats(&dir.to_string_lossy());
        assert_eq!(stats.hosts.len(), 1);
        assert_eq!(stats.hosts[0].host, "host1");
        assert_eq!(stats.hosts[0].files, 6);
        assert_eq!(stats.hosts[0].days, 2);
        assert_eq!(stats.hosts[0].size_bytes, 30);
        assert_eq!(stats.total_files, 6);
        assert_eq!(stats.total_size_bytes, 30);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a placeholder DHCP token uses the Kea one.
    // Why: a shipped example must never be the secret.
    #[test]
    fn a_placeholder_dhcp_token_is_ignored() {
        let mut env = full_env();
        env.insert("KEA_CTRL_TOKEN".to_string(), "kea-ctrl".to_string());
        env.insert("DHCP_API_TOKEN".to_string(), "change-me".to_string());
        let cfg = load_from(&env).unwrap();
        assert_eq!(cfg.dhcp_api_token, "kea-ctrl");
        env.insert("DHCP_API_TOKEN".to_string(), "real-token".to_string());
        let cfg = load_from(&env).unwrap();
        assert_eq!(cfg.dhcp_api_token, "real-token");
    }

    // What: post a form with session cookie and CSRF token.
    // Why: redirects are not followed; the 303 is checked.
    async fn post_form(
        base: &str,
        session: &(String, String),
        path: &str,
        fields: &str,
    ) -> reqwest::Response {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        client
            .post(format!("{base}{path}"))
            .header(header::COOKIE, &session.0)
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(format!("{fields}&csrf_token={}", session.1))
            .send()
            .await
            .unwrap()
    }

    // What: dhcp and ntp record whether they should run.
    // Why: the watchdog starts and stops from this file.
    #[tokio::test]
    async fn desired_state_is_recorded_per_service() {
        let dir = unique_temp_dir("desired");
        let file = dir.join("desired.json");
        let path = file.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.desired_state_file = path).await;
        let (cookie, csrf) = open_session(&base, &state).await;
        let client = reqwest::Client::new();
        let put = |service: &str, value: &str| {
            client
                .post(format!(
                    "{base}{}",
                    ROUTE_DESIRED_STATE.replace("{service}", service)
                ))
                .header(header::COOKIE, &cookie)
                .header("X-CSRF-Token", &csrf)
                .json(&json!({"state": value}))
                .send()
        };
        assert_eq!(put("web", "running").await.unwrap().status(), 404);
        assert_eq!(put("dhcp", "paused").await.unwrap().status(), 400);
        assert_eq!(put("dhcp", "running").await.unwrap().status(), 204);
        assert_eq!(put("ntp", "stopped").await.unwrap().status(), 204);
        let desired = DesiredState::read(&file);
        assert_eq!(desired.dhcp, Some(DesiredRunState::Running));
        assert_eq!(desired.ntp, Some(DesiredRunState::Stopped));
        assert_eq!(put("dhcp", "stopped").await.unwrap().status(), 204);
        let desired = DesiredState::read(&file);
        assert_eq!(desired.dhcp, Some(DesiredRunState::Stopped));
        assert_eq!(desired.ntp, Some(DesiredRunState::Stopped));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: a cache size is checked, then saved.
    // Why: a size that does not fit must never be stored.
    #[tokio::test]
    async fn cache_resize_checks_space_before_saving() {
        let dir = unique_temp_dir("resize");
        let (cache, conf) = (dir.to_string_lossy().to_string(), dir.join("ui.conf"));
        let settings = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.cache_dir = cache;
            cfg.ui_settings_file = settings;
        })
        .await;
        let session = open_session(&base, &state).await;
        for bad in ["cache_gb=0", "cache_gb=abc", "cache_gb="] {
            let response = post_form(&base, &session, ROUTE_CACHE_RESIZE, bad).await;
            assert_eq!(response.status(), 400, "{bad}");
            assert!(
                response
                    .text()
                    .await
                    .unwrap()
                    .contains("positive whole number")
            );
        }
        let huge = post_form(&base, &session, ROUTE_CACHE_RESIZE, "cache_gb=99999999").await;
        assert_eq!(huge.status(), 400);
        assert!(
            huge.text()
                .await
                .unwrap()
                .contains("would not leave a safety buffer")
        );
        assert!(!conf.exists());
        let ok = post_form(&base, &session, ROUTE_CACHE_RESIZE, "cache_gb=1").await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_DASHBOARD);
        assert!(
            fs::read_to_string(&conf)
                .unwrap()
                .contains("CACHE_MAX_GB=1\n")
        );
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);

        let (base, state, sdir) =
            test_server(|cfg| cfg.cache_dir = "relative/cache".to_string()).await;
        let session = open_session(&base, &state).await;
        let unknown = post_form(&base, &session, ROUTE_CACHE_RESIZE, "cache_gb=1").await;
        assert_eq!(unknown.status(), 500);
        assert!(unknown.text().await.unwrap().contains("Refusing to resize"));
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: stack settings take two known channels only.
    // Why: pinned tags and the old edge name are no choice.
    #[tokio::test]
    async fn stack_settings_save_channel_and_auto_update() {
        let dir = unique_temp_dir("stack");
        let conf = dir.join("ui.conf");
        let settings = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = settings).await;
        let session = open_session(&base, &state).await;
        let bad = post_form(
            &base,
            &session,
            ROUTE_SETUP_UPDATE,
            "lancache_image_channel=edge",
        )
        .await;
        assert_eq!(bad.status(), 400);
        assert!(
            bad.text()
                .await
                .unwrap()
                .contains("Invalid release channel")
        );
        assert!(!conf.exists());
        let body = "lancache_image_channel=nightly&auto_update_enabled=1";
        let ok = post_form(&base, &session, ROUTE_SETUP_UPDATE, body).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_SETUP);
        let saved = fs::read_to_string(&conf).unwrap();
        assert!(saved.contains("LANCACHE_IMAGE_CHANNEL=nightly\n"));
        assert!(saved.contains("AUTO_UPDATE_ENABLED=1\n"));
        let off = post_form(
            &base,
            &session,
            ROUTE_SETUP_UPDATE,
            "lancache_image_channel=stable",
        )
        .await;
        assert_eq!(off.status(), 303);
        assert!(
            fs::read_to_string(&conf)
                .unwrap()
                .contains("AUTO_UPDATE_ENABLED=0\n")
        );
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: each logging switch is saved on its own.
    // Why: the watchdog filters syslog-ng by this file.
    // From: Issue #1683 | PR #1912
    #[tokio::test]
    async fn logging_switches_are_saved_per_service() {
        let dir = unique_temp_dir("logsw");
        let conf = dir.join("ui.conf");
        let settings = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = settings).await;
        let session = open_session(&base, &state).await;
        let page = reqwest::get(format!("{base}{PAGE_LOGS}")).await.unwrap();
        assert_eq!(page.status(), 200);
        let page = page.text().await.unwrap();
        assert!(page.contains("name=\"LOGGING_PROXY_ENABLED\""), "{page}");
        let body = "LOGGING_DNS_ENABLED=1&LOGGING_UI_ENABLED=1";
        let ok = post_form(&base, &session, ROUTE_LOGS_SETTINGS, body).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_LOGS);
        let saved = fs::read_to_string(&conf).unwrap();
        for row in [
            "LOGGING_PROXY_ENABLED=0\n",
            "LOGGING_DNS_ENABLED=1\n",
            "LOGGING_DHCP_ENABLED=0\n",
            "LOGGING_UI_ENABLED=1\n",
        ] {
            assert!(saved.contains(row), "{row}: {saved}");
        }
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: NTP settings are checked, then saved.
    // Why: the services supervisor follows the saved file.
    #[tokio::test]
    async fn ntp_settings_are_checked_then_saved() {
        let dir = unique_temp_dir("ntp-settings");
        let conf = dir.join("ui.conf");
        let settings = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = settings).await;
        let session = open_session(&base, &state).await;
        let empty = post_form(&base, &session, ROUTE_NTP_SETTINGS, "ntp_upstream_servers=").await;
        assert_eq!(empty.status(), 400);
        assert!(
            empty
                .text()
                .await
                .unwrap()
                .contains("At least one upstream")
        );
        let bad = post_form(
            &base,
            &session,
            ROUTE_NTP_SETTINGS,
            "ntp_upstream_servers=bad%20host!",
        )
        .await;
        assert_eq!(bad.status(), 400);
        assert!(bad.text().await.unwrap().contains("is not a valid"));
        assert!(!conf.exists());
        let on = "ntp_enabled=1&ntp_upstream_servers=pool.ntp.org%2C+10.0.0.1";
        let ok = post_form(&base, &session, ROUTE_NTP_SETTINGS, on).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_NTP);
        let saved = fs::read_to_string(&conf).unwrap();
        assert!(saved.contains("NTP_ENABLED=1\n"));
        assert!(saved.contains("NTP_UPSTREAM_SERVERS=pool.ntp.org 10.0.0.1\n"));
        assert!(saved.contains("NTP_AUTO_DHCP=0\n"));
        let off = post_form(
            &base,
            &session,
            ROUTE_NTP_SETTINGS,
            "ntp_upstream_servers=10.0.0.1",
        )
        .await;
        assert_eq!(off.status(), 303);
        assert!(
            fs::read_to_string(&conf)
                .unwrap()
                .contains("NTP_ENABLED=0\n")
        );
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: AAAA and DDNS markers appear in the DNS dir.
    // Why: the dns container reads the requested state.
    #[tokio::test]
    async fn dns_marker_toggles_write_the_state_dir() {
        let dir = unique_temp_dir("markers");
        let path = dir.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.dns_state_dir = path).await;
        let session = open_session(&base, &state).await;
        let on = post_form(&base, &session, ROUTE_AAAA_FILTER, "enabled=1").await;
        assert_eq!(on.status(), 303);
        assert_eq!(on.headers()[header::LOCATION], PAGE_DOMAINS);
        assert_eq!(
            fs::read_to_string(dir.join(AAAA_FILTER_MARKER)).unwrap(),
            "1"
        );
        let off = post_form(&base, &session, ROUTE_AAAA_FILTER, "enabled=0").await;
        assert_eq!(off.status(), 303);
        assert!(!dir.join(AAAA_FILTER_MARKER).exists());
        let again = post_form(&base, &session, ROUTE_AAAA_FILTER, "enabled=0").await;
        assert_eq!(again.status(), 303);

        let blocked = post_form(&base, &session, ROUTE_DDNS_UNSIGNED, "enabled=1").await;
        assert_eq!(
            blocked.headers()[header::LOCATION],
            domains_error("ddns_allow_unsigned_no_key").as_str()
        );
        assert!(!dir.join(DDNS_UNSIGNED_MARKER).exists());
        fs::write(sdir.join("ddns-tsig-key"), "tsig").unwrap();
        let allowed = post_form(&base, &session, ROUTE_DDNS_UNSIGNED, "enabled=1").await;
        assert_eq!(allowed.headers()[header::LOCATION], PAGE_DOMAINS);
        assert!(dir.join(DDNS_UNSIGNED_MARKER).exists());
        let revoked = post_form(&base, &session, ROUTE_DDNS_UNSIGNED, "enabled=0").await;
        assert_eq!(revoked.headers()[header::LOCATION], PAGE_DOMAINS);
        assert!(!dir.join(DDNS_UNSIGNED_MARKER).exists());
        fs::remove_file(sdir.join("ddns-tsig-key")).unwrap();
        fs::write(sdir.join("ddns-tsig-key"), "").unwrap();
        let empty = post_form(&base, &session, ROUTE_DDNS_UNSIGNED, "enabled=1").await;
        assert_eq!(
            empty.headers()[header::LOCATION],
            domains_error("ddns_allow_unsigned_no_key").as_str()
        );
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: the state of a stand-in Kea control agent.
    // Why: tests read the commands sent and the config.
    struct FakeKea {
        config: Value,
        replies: HashMap<String, Value>,
        log: Vec<Value>,
    }

    // What: answer one Kea command from the fake's state.
    // Why: config-set must change what config-get returns.
    async fn fake_kea_answer(
        State(kea): State<Arc<Mutex<FakeKea>>>,
        Json(request): Json<Value>,
    ) -> Json<Value> {
        let mut kea = kea.lock().unwrap();
        kea.log.push(request.clone());
        let command = request["command"].as_str().unwrap_or_default().to_string();
        if let Some(reply) = kea.replies.get(&command) {
            return Json(reply.clone());
        }
        Json(match command.as_str() {
            "config-get" => json!([{"result": 0, "arguments": kea.config.clone()}]),
            "config-set" => {
                kea.config = request["arguments"].clone();
                json!([{"result": 0}])
            }
            _ => json!([{"result": 0}]),
        })
    }

    // What: a Kea config with one subnet, no reservations.
    // Why: the handlers edit it; the fake keeps the result.
    fn kea_config_sample() -> Value {
        json!({"Dhcp4": {
            "host-reservation-identifiers": ["hw-address"],
            "subnet4": [{
                "id": 1, "subnet": "198.51.100.0/24",
                "pools": [{"pool": "198.51.100.10 - 198.51.100.200"}],
                "option-data": [], "reservations": []
            }]
        }})
    }

    // What: a ui in Kea mode in front of a stand-in Kea.
    // Why: DHCP handlers run their whole Kea command chain.
    async fn kea_test_server(
        config: Value,
        replies: Vec<(&str, Value)>,
    ) -> (
        String,
        Arc<AppState>,
        Arc<Mutex<FakeKea>>,
        std::path::PathBuf,
    ) {
        let kea = Arc::new(Mutex::new(FakeKea {
            config,
            replies: replies
                .into_iter()
                .map(|(command, reply)| (command.to_string(), reply))
                .collect(),
            log: Vec::new(),
        }));
        let app = Router::new()
            .route("/", post(fake_kea_answer))
            .with_state(kea.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(axum::serve(listener, app).into_future());
        let dir = unique_temp_dir("kea-ui");
        let (snapshots, settings) = (dir.join("snapshots"), dir.join("ui.conf"));
        fs::write(&settings, "DHCP_MODE=kea\n").unwrap();
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.dhcp_api_url = url;
            cfg.kea_config_snapshot_dir = snapshots.to_string_lossy().to_string();
            cfg.ui_settings_file = settings.to_string_lossy().to_string();
        })
        .await;
        let _ = fs::remove_dir_all(&sdir);
        (base, state, kea, dir)
    }

    // What: the commands a stand-in Kea received, in order.
    // Why: the chain order is part of the contract.
    fn kea_commands(kea: &Arc<Mutex<FakeKea>>) -> Vec<String> {
        let kea = kea.lock().unwrap();
        let name = |r: &Value| r["command"].as_str().unwrap().to_string();
        kea.log.iter().map(name).collect()
    }

    fn subnet_body() -> String {
        subnet_form()
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&")
    }

    // What: adding a subnet runs get, test, set and write.
    // Why: the new subnet gets the next id and a snapshot.
    #[tokio::test]
    async fn adding_a_subnet_runs_the_whole_kea_chain() {
        let (base, state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        let session = open_session(&base, &state).await;
        let bad = post_form(&base, &session, ROUTE_SUBNET_ADD, "subnet=x").await;
        assert_eq!(bad.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let ok = post_form(&base, &session, ROUTE_SUBNET_ADD, &subnet_body()).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_DHCP);
        assert_eq!(
            kea_commands(&kea),
            ["config-get", "config-test", "config-set", "config-write"]
        );
        let config = kea.lock().unwrap().config.clone();
        let subnets = config["Dhcp4"]["subnet4"].as_array().unwrap();
        assert_eq!(subnets.len(), 2);
        assert_eq!(subnets[1]["id"], 2);
        assert_eq!(subnets[1]["subnet"], "198.51.100.0/24");
        assert_eq!(kea_store(&state.config).ids().unwrap().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: Kea changes need Kea mode and its API URL.
    // Why: a clear 409 beats an obscure Kea API failure.
    #[tokio::test]
    async fn kea_changes_are_refused_outside_kea_mode() {
        let (base, state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        let session = open_session(&base, &state).await;
        assert!(kea_available(&state));
        fs::write(&state.config.ui_settings_file, "DHCP_MODE=disabled\n").unwrap();
        assert!(!kea_available(&state));
        let off = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "id=1").await;
        assert_eq!(off.status(), 409);
        assert!(kea_commands(&kea).is_empty());
        let _ = fs::remove_dir_all(&dir);

        let settings = dir.join("kea.conf");
        fs::create_dir_all(&dir).unwrap();
        fs::write(&settings, "DHCP_MODE=kea\n").unwrap();
        let path = settings.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.ui_settings_file = path;
            cfg.dhcp_api_url = String::new();
        })
        .await;
        assert!(!kea_available(&state));
        let session = open_session(&base, &state).await;
        let none = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "id=1").await;
        assert_eq!(none.status(), 409);
        let _ = fs::remove_dir_all(&sdir);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: removing a subnet keeps the others.
    // Why: only the chosen id may leave the config.
    #[tokio::test]
    async fn removing_a_subnet_drops_only_that_id() {
        let mut config = kea_config_sample();
        let second = json!({"id": 2, "subnet": "203.0.113.0/24"});
        config["Dhcp4"]["subnet4"]
            .as_array_mut()
            .unwrap()
            .push(second);
        let (base, state, kea, dir) = kea_test_server(config, vec![]).await;
        let session = open_session(&base, &state).await;
        let missing = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "x=1").await;
        assert_eq!(missing.status(), 400);
        let ok = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "id=1").await;
        assert_eq!(ok.status(), 303);
        let config = kea.lock().unwrap().config.clone();
        let ids: Vec<u64> = config["Dhcp4"]["subnet4"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["id"].as_u64().unwrap())
            .collect();
        assert_eq!(ids, [2]);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: static reservations are added, edited, removed.
    // Why: a repeated submit must edit, never duplicate.
    #[tokio::test]
    async fn reservations_are_upserted_and_removed_by_mac() {
        let (base, state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        let session = open_session(&base, &state).await;
        let add = |extra: &str| {
            let body = format!("subnet_id=1&{extra}");
            let (base, session) = (base.clone(), session.clone());
            async move { post_form(&base, &session, ROUTE_STATIC_ADD, &body).await }
        };
        for bad in [
            "mac=zz&ip=198.51.100.50",
            "mac=aa:bb:cc:dd:ee:ff&ip=nope",
            "mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.50&hostname=bad_host!",
        ] {
            assert_eq!(add(bad).await.status(), 400, "{bad}");
        }
        let nosubnet = post_form(
            &base,
            &session,
            ROUTE_STATIC_ADD,
            "mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.50",
        )
        .await;
        assert_eq!(nosubnet.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let unknown = post_form(
            &base,
            &session,
            ROUTE_STATIC_ADD,
            "subnet_id=9&mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.50",
        )
        .await;
        assert_eq!(unknown.status(), 404);
        let first = add("mac=AA-BB-CC-DD-EE-FF&ip=198.51.100.50&hostname=pc1").await;
        assert_eq!(first.status(), 303);
        let second = add("mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.51").await;
        assert_eq!(second.status(), 303);
        let list = kea.lock().unwrap().config["Dhcp4"]["subnet4"][0]["reservations"].clone();
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["hw-address"], "aa:bb:cc:dd:ee:ff");
        assert_eq!(list[0]["ip-address"], "198.51.100.51");
        assert_eq!(list[0]["hostname"], "");
        let remove = |body: &str| {
            let (base, session, body) = (base.clone(), session.clone(), body.to_string());
            async move { post_form(&base, &session, ROUTE_STATIC_REMOVE, &body).await }
        };
        assert_eq!(remove("subnet_id=1&mac=zz").await.status(), 400);
        assert_eq!(remove("mac=aa:bb:cc:dd:ee:ff").await.status(), 400);
        assert_eq!(
            remove("subnet_id=1&mac=11:22:33:44:55:66").await.status(),
            303
        );
        let kept = kea.lock().unwrap().config["Dhcp4"]["subnet4"][0]["reservations"].clone();
        assert_eq!(kept.as_array().unwrap().len(), 1);
        assert_eq!(
            remove("subnet_id=1&mac=AA-BB-CC-DD-EE-FF").await.status(),
            303
        );
        let gone = kea.lock().unwrap().config["Dhcp4"]["subnet4"][0]["reservations"].clone();
        assert!(gone.as_array().unwrap().is_empty());
        let _ = fs::remove_dir_all(&dir);

        let mut config = kea_config_sample();
        config["Dhcp4"]["host-reservation-identifiers"] = json!(["duid"]);
        let (base, state, _kea, dir) = kea_test_server(config, vec![]).await;
        let session = open_session(&base, &state).await;
        let refused = post_form(
            &base,
            &session,
            ROUTE_STATIC_ADD,
            "subnet_id=1&mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.50",
        )
        .await;
        assert_eq!(refused.status(), 500);
        assert!(
            refused
                .text()
                .await
                .unwrap()
                .contains("host-reservation-identifiers")
        );
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a refused Kea step stops the chain.
    // Why: a failed step must not leave a half edit.
    #[tokio::test]
    async fn kea_failures_stop_or_roll_back_the_change() {
        let refuse = json!([{"result": 1, "text": "boom"}]);
        let (base, state, kea, dir) =
            kea_test_server(kea_config_sample(), vec![("config-test", refuse.clone())]).await;
        let session = open_session(&base, &state).await;
        let failed = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "id=1").await;
        assert_eq!(failed.status(), 500);
        assert!(failed.text().await.unwrap().contains("boom"));
        assert_eq!(kea_commands(&kea), ["config-get", "config-test"]);
        assert!(kea_store(&state.config).ids().unwrap().is_empty());
        let _ = fs::remove_dir_all(&dir);

        let (base, state, kea, dir) =
            kea_test_server(kea_config_sample(), vec![("config-write", refuse)]).await;
        let session = open_session(&base, &state).await;
        let failed = post_form(&base, &session, ROUTE_SUBNET_REMOVE, "id=1").await;
        assert_eq!(failed.status(), 500);
        assert!(failed.text().await.unwrap().contains("rolled back"));
        assert_eq!(
            kea_commands(&kea),
            [
                "config-get",
                "config-test",
                "config-set",
                "config-write",
                "config-set"
            ]
        );
        let restored = kea.lock().unwrap().config.clone();
        assert_eq!(restored["Dhcp4"]["subnet4"].as_array().unwrap().len(), 1);
        assert!(kea_store(&state.config).ids().unwrap().is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a lease release maps Kea's result codes.
    // Why: an expired lease is a race, not a failure.
    #[tokio::test]
    async fn lease_release_maps_kea_result_codes() {
        let (base, state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        let session = open_session(&base, &state).await;
        let bad = post_form(&base, &session, ROUTE_LEASE_RELEASE, "ip=nope").await;
        assert_eq!(bad.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let ok = post_form(&base, &session, ROUTE_LEASE_RELEASE, "ip=198.51.100.20").await;
        assert_eq!(ok.status(), 303);
        assert_eq!(kea_commands(&kea), ["lease4-get", "lease4-del"]);
        assert_eq!(
            kea.lock().unwrap().log[1]["arguments"],
            json!({"ip-address": "198.51.100.20"})
        );
        let _ = fs::remove_dir_all(&dir);

        let gone = json!([{"result": 3, "text": "no lease"}]);
        let (base, state, _kea, dir) =
            kea_test_server(kea_config_sample(), vec![("lease4-del", gone)]).await;
        let session = open_session(&base, &state).await;
        let missing = post_form(&base, &session, ROUTE_LEASE_RELEASE, "ip=198.51.100.20").await;
        assert_eq!(missing.status(), 404);
        assert!(missing.text().await.unwrap().contains("No active lease"));
        let _ = fs::remove_dir_all(&dir);

        let broken = json!([{"result": 1, "text": "kea broke"}]);
        let (base, state, _kea, dir) =
            kea_test_server(kea_config_sample(), vec![("lease4-del", broken)]).await;
        let session = open_session(&base, &state).await;
        let failed = post_form(&base, &session, ROUTE_LEASE_RELEASE, "ip=198.51.100.20").await;
        assert_eq!(failed.status(), 500);
        assert!(failed.text().await.unwrap().contains("kea broke"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: leases are read with their expiry time.
    // Why: the page shows an absolute expiry.
    #[tokio::test]
    async fn leases_and_the_dhcp_page_come_from_kea() {
        let leases = json!([{"result": 0, "arguments": {"leases": [{
            "ip-address": "198.51.100.20", "hw-address": "aa:bb:cc:dd:ee:ff",
            "hostname": "pc1", "subnet-id": 1, "cltt": 1000, "valid-lft": 3600
        }]}}]);
        let (base, state, kea, dir) =
            kea_test_server(kea_config_sample(), vec![("lease4-get-all", leases)]).await;
        let found = kea_leases(&state).await.unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].subnet_id, 1);
        assert_eq!(found[0].ip, "198.51.100.20");
        assert_eq!(found[0].mac, "aa:bb:cc:dd:ee:ff");
        assert_eq!(found[0].hostname, "pc1");
        assert_eq!(found[0].expires, "4600");
        let page = reqwest::get(format!("{base}{PAGE_DHCP}")).await.unwrap();
        assert_eq!(page.status(), 200);
        let html = page.text().await.unwrap();
        assert!(html.contains("198.51.100.20"));
        assert!(html.contains("198.51.100.0/24"));
        assert!(kea_commands(&kea).contains(&"config-get".to_string()));
        let _ = fs::remove_dir_all(&dir);

        let (base, _state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        fs::write(dir.join("ui.conf"), "DHCP_MODE=disabled\n").unwrap();
        let page = reqwest::get(format!("{base}{PAGE_DHCP}")).await.unwrap();
        assert_eq!(page.status(), 200);
        assert!(!page.text().await.unwrap().contains("198.51.100.0/24"));
        assert!(kea_commands(&kea).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a rollback applies a stored snapshot.
    // Why: only ids found on disk are accepted.
    #[tokio::test]
    async fn a_kea_rollback_applies_a_stored_snapshot() {
        let (base, state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        let session = open_session(&base, &state).await;
        let snapshot = json!({"Dhcp4": {"subnet4": []}});
        let store = kea_store(&state.config);
        store.create(&snapshot, 3).unwrap();
        let id = store.ids().unwrap().remove(0);
        let unknown = post_form(&base, &session, ROUTE_KEA_ROLLBACK, "snapshot_id=nope").await;
        assert_eq!(unknown.status(), 409);
        assert!(kea_commands(&kea).is_empty());
        let body = format!("snapshot_id={id}");
        let ok = post_form(&base, &session, ROUTE_KEA_ROLLBACK, &body).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(kea.lock().unwrap().config, snapshot);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a DHCP mode switch only saves the mode.
    // Why: the dhcp supervisor starts what the file names.
    // From: Issue #1486 | PR #1912
    #[tokio::test]
    async fn dhcp_mode_switch_saves_the_mode() {
        let dir = unique_temp_dir("dhcp-mode");
        let conf = dir.join("ui.conf");
        fs::write(&conf, "DHCP_MODE=disabled\n").unwrap();
        let path = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = path).await;
        let session = open_session(&base, &state).await;
        let bad = post_form(&base, &session, ROUTE_DHCP_MODE, "dhcp_mode=bogus").await;
        assert_eq!(bad.status(), 409);
        for mode in ["KEA", "dnsmasq-proxy", "dnsmasq-relay"] {
            let body = format!("dhcp_mode={mode}");
            let ok = post_form(&base, &session, ROUTE_DHCP_MODE, &body).await;
            assert_eq!(ok.status(), 303);
            assert_eq!(ok.headers()[header::LOCATION], PAGE_DHCP);
            let saved = fs::read_to_string(&conf).unwrap();
            let want = format!("DHCP_MODE={}\n", mode.to_lowercase());
            assert!(saved.starts_with(&want), "{saved}");
        }
        let _ = fs::remove_dir_all(&sdir);

        let blocker = dir.join("file");
        fs::write(&blocker, "x").unwrap();
        let path = format!("{}/ui.conf", blocker.to_string_lossy());
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = path).await;
        let session = open_session(&base, &state).await;
        let ro = post_form(&base, &session, ROUTE_DHCP_MODE, "dhcp_mode=kea").await;
        assert_eq!(ro.status(), 500);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: the proxy form is checked, then saved.
    // Why: a typo should fail here, not at dnsmasq start.
    #[tokio::test]
    async fn dhcp_proxy_form_is_validated_then_saved() {
        let dir = unique_temp_dir("dhcp-proxy");
        let conf = dir.join("ui.conf");
        let path = conf.to_string_lossy().to_string();
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = path).await;
        let session = open_session(&base, &state).await;
        let base_form = [
            ("dhcp_subnet_start", "192.168.1.100"),
            ("dhcp_dns_primary", "192.168.1.2"),
            ("upstream_dhcp_ip", "192.168.1.1"),
        ];
        let body = |changes: &[(&str, &str)]| {
            let mut pairs: Vec<(&str, &str)> = base_form.to_vec();
            for (key, value) in changes {
                pairs.retain(|(k, _)| k != key);
                pairs.push((key, value));
            }
            pairs
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join("&")
        };
        let cases: [(&[(&str, &str)], &str); 11] = [
            (&[("dhcp_subnet_start", "x")], "Invalid relay subnet start"),
            (&[("dhcp_dns_primary", "x")], "Invalid primary DNS"),
            (
                &[("upstream_dhcp_ip", "1.2.3")],
                "Invalid upstream DHCP server",
            ),
            (&[("dhcp_dns_secondary", "x")], "Invalid secondary DNS"),
            (
                &[("dhcp_proxy_interface", "e t h")],
                "Invalid relay/proxy listen interface",
            ),
            (
                &[("dhcp_proxy_router", "x")],
                "Invalid router/gateway option",
            ),
            (
                &[("dhcp_ntp_servers", "1.1.1.1,x")],
                "Invalid NTP servers option",
            ),
            (
                &[("dhcp_proxy_domain", "bad_domain!")],
                "Invalid domain option",
            ),
            (
                &[("dhcp_proxy_boot_filename", "a b")],
                "Invalid PXE boot filename",
            ),
            (
                &[("dhcp_proxy_boot_server", "x")],
                "Invalid PXE boot server address",
            ),
            (
                &[("dhcp_proxy_boot_server", "192.168.1.9")],
                "requires a boot filename",
            ),
        ];
        for (changes, message) in cases {
            let response = post_form(&base, &session, ROUTE_DHCP_PROXY, &body(changes)).await;
            assert_eq!(response.status(), 400, "{message}");
            assert!(
                response.text().await.unwrap().contains(message),
                "{message}"
            );
            assert!(!conf.exists());
        }
        let custom = post_form(
            &base,
            &session,
            ROUTE_DHCP_PROXY,
            &body(&[("dhcp_proxy_custom_options", "nocolon")]),
        )
        .await;
        assert_eq!(custom.status(), 400);
        assert!(
            custom
                .text()
                .await
                .unwrap()
                .contains("Invalid custom DHCP option")
        );
        let full = body(&[
            ("dhcp_dns_secondary", "192.168.1.3"),
            ("dhcp_proxy_interface", "eth0"),
            ("dhcp_proxy_router", "192.168.1.1"),
            ("dhcp_ntp_servers", "192.168.1.5,192.168.1.6"),
            ("dhcp_proxy_domain", "lan.example"),
            ("dhcp_proxy_boot_filename", "pxelinux.0"),
            ("dhcp_proxy_boot_server", "192.168.1.9"),
        ]);
        let ok = post_form(&base, &session, ROUTE_DHCP_PROXY, &full).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], PAGE_DHCP);
        let saved = fs::read_to_string(&conf).unwrap();
        for line in [
            "DHCP_SUBNET_START=192.168.1.100",
            "DHCP_DNS_PRIMARY=192.168.1.2",
            "DHCP_DNS_SECONDARY=192.168.1.3",
            "UPSTREAM_DHCP_IP=192.168.1.1",
            "DHCP_NTP_SERVERS=192.168.1.5,192.168.1.6",
            "DHCP_PROXY_INTERFACE=eth0",
            "DHCP_PROXY_ROUTER=192.168.1.1",
            "DHCP_PROXY_DOMAIN=lan.example",
            "DHCP_PROXY_BOOT_FILENAME=pxelinux.0",
            "DHCP_PROXY_BOOT_SERVER=192.168.1.9",
        ] {
            assert!(saved.lines().any(|l| l == line), "{line}");
        }
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }
}
