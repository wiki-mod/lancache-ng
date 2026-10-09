//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: the Admin UI server, its one-shot modes and clients.
//! Why: one binary serves pages and drives Docker, NATS, Kea.
//! From: Issue #1683 | PR #1858

#![deny(warnings)]

use anyhow::Context as _;
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::Router;
use axum::body::{Body, Bytes, to_bytes};
use axum::extract::{Form, Path as AxPath, Query, Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, header};
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Json, Redirect, Response};
use axum::routing::{MethodRouter, delete, get, post};
use base64::Engine as _;
use dhcproto::v4::{DhcpOption, Flags, Message, MessageType, OptionCode};
use dhcproto::{Decodable, Decoder, Encodable, Encoder};
use futures_util::StreamExt as _;
use lancache_ng::config::{
    self, CONTAINER_DHCP, CONTAINER_DHCP_PROBE, CONTAINER_DHCP_PROXY, CONTAINER_DNS_SSL,
    CONTAINER_DNS_STANDARD, CONTAINER_NATS, CONTAINER_NETDATA, CONTAINER_NTP, CONTAINER_PROXY,
    CONTAINER_SYSLOG, CONTAINER_UI, DhcpMode, LAN_ZONE, NATS_STREAM_DNS, NATS_SUBJECT_DNS,
    NATS_SUBJECT_FLUSH, NATS_SUBJECT_RECORD, OutOfRange, PDNS_API_PATH, Uint, canonical_zone,
    parse_bool, rollback_zones, zone_url,
};
use lancache_ng::{
    DesiredRunState, DesiredState, DnsRecord, DockerError, DockerProxy, FlushRequest, Place,
    PowerDns, SnapshotStore, WatchdogStatus, ct_eq, df, die, http_client, is_placeholder,
    load_or_create, load_or_create_hex, snapshot_created_unix, unix_secs, write_file,
    write_file_as, write_if_changed,
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
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, UdpSocket};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};
use tera::{Context, Tera};
use tracing_subscriber::layer::SubscriberExt as _;
use tracing_subscriber::util::SubscriberInitExt as _;

// What: UI-settings keys, in the order the file lists them.
// Why: every save rewrites the whole file; setup.sh reads it.
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
const SHARED_SECRET_VARS: [&str; 8] = [
    "PDNS_API_KEY",
    "NETDATA_ALARM_TOKEN",
    "KEA_CTRL_TOKEN",
    "NATS_UI_PASSWORD",
    "NATS_DNS_WRITER_PASSWORD",
    "NATS_DNS_REPLICA_PASSWORD",
    "NATS_CALLOUT_PASSWORD",
    "NATS_SYS_PASSWORD",
];

// What: when the ui sends Strict-Transport-Security.
// Why: plain-HTTP installs must never receive an HSTS header.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HstsMode {
    Auto,
    Always,
    Never,
}

impl HstsMode {
    // What: send HSTS for this request or not.
    // Why: Auto follows the request scheme, the rest force it.
    fn should_send(self, is_https: bool) -> bool {
        match self {
            Self::Auto => is_https,
            Self::Always => true,
            Self::Never => false,
        }
    }
}

// What: user and password of one static NATS role.
// Why: the password is Option so unset fails validation.
struct NatsLogin {
    user: String,
    password: Option<String>,
}

// What: every startup value of the ui, read once.
// Why: no Debug impl, so a log line can never print a secret.
struct Config {
    template_dir: String,
    cdn_domains_file: String,
    standard_log: String,
    ssl_log: String,
    cache_dir: String,
    dns_standard_state_dir: String,
    dns_ssl_state_dir: String,
    shared_secret_dir: String,
    proxy_standard_url: String,
    proxy_ssl_url: String,
    netdata_url: String,
    dns_standard_service: String,
    dns_ssl_service: String,
    proxy_ssl_service: String,
    docker_proxy_url: String,
    ssl_enabled: bool,
    cache_max_gb: f64,
    standard_ip: String,
    ssl_ip: String,
    dhcp_api_url: String,
    dhcp_api_token: String,
    ui_settings_file: String,
    startup_settings: HashMap<&'static str, String>,
    kea_config_snapshot_dir: String,
    kea_keep_known_good_configs: u32,
    auth_user: Option<String>,
    auth_password: Option<String>,
    allow_insecure_ui: bool,
    ui_session_ttl_seconds: u64,
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
    nats_ui: NatsLogin,
    nats_dns_writer: NatsLogin,
    nats_dns_replica: NatsLogin,
    nats_callout: NatsLogin,
    nats_sys: NatsLogin,
    nats_issuer_seed_path: String,
    nats_issuer_seed: Option<String>,
    nats_xkey_seed_path: String,
    nats_xkey_seed: Option<String>,
    secondary_registration_token: String,
    lancache_image_registry: String,
    lancache_image_prefix: String,
    lancache_image_channel: String,
    lancache_image_tag: String,
    nats_conf_path: String,
    nats_auth_callout_path: String,
    nats_service: String,
    nats_log_file: String,
    // What: where the session secret persists.
    // Why: a recreate must not invalidate every open session.
    // From: Issue #1683 | PR #1858
    session_secret_file: String,
    // What: the SQLite file of the secondary nodes.
    // Why: runtime state stays in PowerDNS, Kea, NATS and Docker.
    database_file: String,
    // What: where a generated registration token persists.
    // Why: a restart must not rotate the token secondaries hold.
    registration_token_file: String,
    // What: TCP port the server binds inside the container.
    // Why: the Dockerfile owns it; the primary URL reuses it.
    listen_port: u16,
    nats_store_dir: Option<String>,
    nats_monitor_port: Option<String>,
    netdata_conf_file: Option<String>,
    netdata_notify_file: Option<String>,
    netdata_token_file: Option<String>,
    netdata_daemon_log: Option<String>,
    netdata_health_log: Option<String>,
    netdata_alarm_ui_url: Option<String>,
    netdata_alarm_max_time: Option<String>,
    netdata_alarm_recipient: Option<String>,
    dev_mode: bool,
    syslog_enabled: bool,
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
        let text = |key: &str, default: &str| env(key).unwrap_or_else(|| default.to_string());
        let set = |key: &str| config::opt(env, key);
        // What: a value compose must supply; unset stops startup.
        // Why: compose owns it; Rust keeps no second default.
        let need = |key: &str| config::need(env, key);
        // What: a bool compose must supply; junk stops startup.
        // Why: same owner as need; a typo must not flip a gate.
        let need_flag = |key: &str| config::need_flag(env, key);
        let flag =
            |key: &str, default: bool| env(key).and_then(|v| parse_bool(&v)).unwrap_or(default);
        let knob = |name: &'static str, max: u64, above: OutOfRange| -> Result<u64, String> {
            let spec = Uint {
                name,
                min: 1,
                max,
                below: OutOfRange::Reject,
                above,
            };
            let (value, warning) = spec.parse(env(name).as_deref())?;
            if let Some(warning) = warning {
                eprintln!("[lancache-ui] {warning}");
            }
            Ok(value)
        };

        let standard_log = need("STANDARD_LOG")?;
        let proxy_standard_url = need("PROXY_STANDARD_URL")?;
        // What: both proxy addresses must come from the operator.
        // Why: no LAN address may be hardcoded (AG-SEC-007).
        let standard_ip = set("STANDARD_IP").ok_or("STANDARD_IP must be set")?;
        let ssl_ip = set("SSL_IP").ok_or("SSL_IP must be set")?;
        // What: the Docker API entry point must come from compose.
        // Why: compose owns the value; no second default here.
        let nats_url = need("NATS_URL")?;
        let docker_proxy_url = set("DOCKER_PROXY_URL").ok_or("DOCKER_PROXY_URL must be set")?;
        let tag = need("LANCACHE_IMAGE_TAG")?;
        let channel = set("LANCACHE_IMAGE_CHANNEL")
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| derive_image_channel(&tag));
        let cache_max_gb = cache_max_gb_from(env)?;
        // What: DHCP_ENABLED is an optional legacy switch, off.
        // Why: no owner sets it; unset must never enable DHCP.
        let dhcp_mode = DhcpMode::parse(
            &env("DHCP_MODE").unwrap_or_default(),
            flag("DHCP_ENABLED", false),
        );
        let secret_dir = need("LANCACHE_SHARED_SECRET_DIR")?;
        let secret = |var: &str| shared_secret(&secret_dir, var, env);
        let login = |user_key: &str, password_key: &str| -> Result<NatsLogin, String> {
            Ok(NatsLogin {
                user: text(user_key, ""),
                password: Some(secret(password_key)?).filter(|p| !p.is_empty()),
            })
        };
        let dhcp_api_token = match env("DHCP_API_TOKEN") {
            Some(v) if !shared_secret_is_placeholder(&v) => v,
            _ => secret("KEA_CTRL_TOKEN")?,
        };
        let ttl = need("UI_SESSION_TTL_SECONDS").and_then(|v| {
            v.trim().parse::<u64>().map_err(|_| {
                format!("UI_SESSION_TTL_SECONDS must be an unsigned integer of seconds, got {v:?}")
            })
        })?;
        let startup_settings = HashMap::from([
            ("DHCP_MODE", dhcp_mode.as_str().to_string()),
            ("DHCP_SUBNET_START", text("DHCP_SUBNET_START", "")),
            ("DHCP_DNS_PRIMARY", text("DHCP_DNS_PRIMARY", &standard_ip)),
            ("DHCP_DNS_SECONDARY", text("DHCP_DNS_SECONDARY", &ssl_ip)),
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
            // What: optional switches, off when unset.
            // Why: no owner sets them; the ui settings file does.
            (
                "AUTO_UPDATE_ENABLED",
                bool_text(flag("AUTO_UPDATE_ENABLED", false)),
            ),
            ("NTP_ENABLED", bool_text(flag("NTP_ENABLED", false))),
            ("NTP_UPSTREAM_SERVERS", need("NTP_UPSTREAM_SERVERS")?),
            ("NTP_AUTO_DHCP", bool_text(flag("NTP_AUTO_DHCP", false))),
            ("CACHE_MAX_GB", cache_max_gb.to_string()),
        ]);

        Ok(Self {
            template_dir: need("TEMPLATE_DIR")?,
            shared_secret_dir: secret_dir.clone(),
            cdn_domains_file: need("CDN_DOMAINS_FILE")?,
            ssl_log: need("SSL_LOG")?,
            standard_log,
            cache_dir: need("CACHE_DIR")?,
            dns_standard_state_dir: need("DNS_STANDARD_STATE_DIR")?,
            dns_ssl_state_dir: need("DNS_SSL_STATE_DIR")?,
            proxy_ssl_url: need("PROXY_SSL_URL")?,
            proxy_standard_url,
            netdata_url: need("NETDATA_URL")?,
            dns_standard_service: need("DNS_STANDARD_SERVICE")?,
            dns_ssl_service: need("DNS_SSL_SERVICE")?,
            proxy_ssl_service: need("PROXY_SSL_SERVICE")?,
            docker_proxy_url,
            ssl_enabled: need_flag("SSL_ENABLED")?,
            cache_max_gb,
            standard_ip,
            ssl_ip,
            dhcp_api_url: need("DHCP_API_URL")?,
            dhcp_api_token,
            ui_settings_file: need("UI_SETTINGS_FILE")?,
            startup_settings,
            kea_config_snapshot_dir: need("KEA_CONFIG_SNAPSHOT_DIR")?,
            kea_keep_known_good_configs: knob(
                "KEEP_KNOWN_GOOD_CONFIGS",
                u32::MAX.into(),
                OutOfRange::Reject,
            )? as u32,
            auth_user: set("UI_AUTH_USER"),
            auth_password: set("UI_AUTH_PASSWORD"),
            allow_insecure_ui: need_flag("ALLOW_INSECURE_UI")?,
            ui_session_ttl_seconds: ttl,
            // What: security headers are on unless switched off.
            // Why: no owner sets it; the safe state is the default.
            security_headers_enabled: flag("UI_SECURITY_HEADERS", true),
            hsts_mode: match text("UI_HSTS_MODE", "")
                .trim()
                .to_ascii_lowercase()
                .as_str()
            {
                "always" | "true" | "1" | "on" => HstsMode::Always,
                "never" | "false" | "0" | "off" => HstsMode::Never,
                _ => HstsMode::Auto,
            },
            ui_logs_max_entries: knob("UI_LOGS_MAX_ENTRIES", u64::MAX, OutOfRange::Reject)?
                as usize,
            pdns_auth_api: format!("{}{PDNS_API_PATH}", need("PDNS_AUTH_URL")?),
            pdns_rec_api: format!("{}{PDNS_API_PATH}", need("PDNS_REC_URL")?),
            dns_rollback_url: need("DNS_ROLLBACK_URL")?,
            pdns_api_key: secret("PDNS_API_KEY")?,
            netdata_alarm_token: secret("NETDATA_ALARM_TOKEN")?,
            netdata_alarms_file: need("NETDATA_ALARMS_FILE")?,
            nats_url: nats_url.clone(),
            advertised_nats_url: advertised_nats_url(
                &text("NATS_ADVERTISE_URL", ""),
                &text("NATS_BIND_IP", ""),
                &nats_url,
            ),
            nats_ui: login("NATS_UI_USER", "NATS_UI_PASSWORD")?,
            nats_dns_writer: login("NATS_DNS_WRITER_USER", "NATS_DNS_WRITER_PASSWORD")?,
            nats_dns_replica: login("NATS_DNS_REPLICA_USER", "NATS_DNS_REPLICA_PASSWORD")?,
            nats_callout: login("NATS_CALLOUT_USER", "NATS_CALLOUT_PASSWORD")?,
            nats_sys: login("NATS_SYS_USER", "NATS_SYS_PASSWORD")?,
            nats_issuer_seed_path: need("NATS_ISSUER_SEED_PATH")?,
            nats_issuer_seed: set("NATS_ISSUER_SEED"),
            nats_xkey_seed_path: need("NATS_XKEY_SEED_PATH")?,
            nats_xkey_seed: set("NATS_XKEY_SEED"),
            secondary_registration_token: text("SECONDARY_REGISTRATION_TOKEN", ""),
            lancache_image_registry: need("LANCACHE_IMAGE_REGISTRY")?,
            lancache_image_prefix: need("LANCACHE_IMAGE_PREFIX")?,
            lancache_image_channel: channel,
            lancache_image_tag: tag,
            nats_conf_path: need("NATS_CONF_PATH")?,
            nats_auth_callout_path: need("NATS_AUTH_CALLOUT_PATH")?,
            nats_service: need("NATS_SERVICE")?,
            nats_log_file: need("NATS_LOG_FILE")?,
            session_secret_file: need("UI_SESSION_SECRET_FILE")?,
            database_file: need("UI_DATABASE_FILE")?,
            registration_token_file: need("SECONDARY_REGISTRATION_TOKEN_FILE")?,
            listen_port: need("UI_LISTEN_PORT").and_then(|v| {
                v.parse::<u16>()
                    .map_err(|_| format!("UI_LISTEN_PORT must be a port number, got {v:?}"))
            })?,
            nats_store_dir: set("NATS_STORE_DIR"),
            nats_monitor_port: set("NATS_MONITOR_PORT"),
            netdata_conf_file: set("NETDATA_CONF_FILE"),
            netdata_notify_file: set("NETDATA_NOTIFY_FILE"),
            netdata_token_file: set("NETDATA_TOKEN_FILE"),
            netdata_daemon_log: set("NETDATA_DAEMON_LOG"),
            netdata_health_log: set("NETDATA_HEALTH_LOG"),
            netdata_alarm_ui_url: set("NETDATA_ALARM_UI_URL"),
            netdata_alarm_max_time: set("NETDATA_ALARM_MAX_TIME"),
            netdata_alarm_recipient: set("NETDATA_ALARM_RECIPIENT"),
            // What: dev mode is an optional switch, off.
            // Why: no owner sets it; production must not enable it.
            dev_mode: flag("LANCACHE_DEV_MODE", false),
            syslog_enabled: need_flag("SYSLOG_ENABLED")?,
            syslog_log_root: need("SYSLOG_LOG_ROOT")?,
            syslog_max_gb: knob("SYSLOG_MAX_GB", 1_048_576, OutOfRange::Clamp)? as u32,
            watchdog_status_file: need("WATCHDOG_STATUS_FILE")?,
            desired_state_file: need("DESIRED_STATE_FILE")?,
        })
    }

    // What: a setting; the saved value wins over the startup one.
    // Why: operators change settings live, without a restart.
    fn setting(&self, key: &str) -> String {
        fs::read_to_string(&self.ui_settings_file)
            .ok()
            .and_then(|content| {
                content.lines().map(str::trim).find_map(|line| {
                    line.strip_prefix(key)
                        .and_then(|rest| rest.strip_prefix('='))
                        .map(|value| value.trim().to_string())
                })
            })
            .unwrap_or_else(|| self.startup_settings.get(key).cloned().unwrap_or_default())
    }

    // What: a setting stored as 1 for on.
    // Why: the file and setup.sh share the 1/0 spelling.
    fn flag(&self, key: &str) -> bool {
        self.setting(key).trim() == "1"
    }

    // What: the DHCP mode in effect now.
    // Why: the saved mode has no legacy flag to fall back on.
    fn dhcp_mode(&self) -> DhcpMode {
        DhcpMode::parse(&self.setting("DHCP_MODE"), false)
    }

    // What: the cache size an operator requested, in GB.
    // Why: differs from cache_max_gb until the proxy is recreated.
    fn requested_cache_gb(&self) -> f64 {
        self.setting("CACHE_MAX_GB")
            .trim()
            .parse()
            .unwrap_or(self.cache_max_gb)
    }

    // What: save the settings file with some values changed.
    // Why: one whole-file writer keeps every other key intact.
    fn save_settings(&self, changes: &[(&str, String)]) -> io::Result<()> {
        let mut content = String::new();
        for key in SETTING_KEYS {
            let value = match changes.iter().find(|(name, _)| *name == key) {
                Some((_, value)) => value.clone(),
                None => self.setting(key),
            };
            if !value.trim().is_empty() {
                content.push_str(&format!("{key}={}\n", value.trim()));
            }
        }
        write_file(
            Path::new(&self.ui_settings_file),
            content.as_bytes(),
            0o644,
            Place::Replace,
        )
    }
}

// What: 1 or 0 for a bool.
// Why: the settings file stores flags this way.
fn bool_text(value: bool) -> String {
    if value { "1" } else { "0" }.to_string()
}

// What: the channel an image tag belongs to, for display.
// Why: edge was renamed; it is deliberately not an alias.
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

// What: CACHE_MAX_GB, or the matching legacy pair, or 50.
// Why: a malformed value must fail, never fall back silently.
fn cache_max_gb_from(env: &dyn Fn(&str) -> Option<String>) -> Result<f64, String> {
    let parse = |key: &str| -> Result<Option<f64>, String> {
        env(key)
            .map(|raw| {
                raw.trim()
                    .parse::<f64>()
                    .map_err(|_| format!("{key} must be a number of gigabytes, got {raw:?}"))
            })
            .transpose()
    };
    if let Some(value) = parse("CACHE_MAX_GB")? {
        return Ok(value);
    }
    match (parse("STANDARD_CACHE_MAX_GB")?, parse("SSL_CACHE_MAX_GB")?) {
        (Some(standard), Some(ssl)) if (standard - ssl).abs() > f64::EPSILON => Err(format!(
            "STANDARD_CACHE_MAX_GB ({standard}) and SSL_CACHE_MAX_GB ({ssl}) differ \
             without CACHE_MAX_GB; set CACHE_MAX_GB to one shared cache size."
        )),
        (Some(value), _) | (None, Some(value)) => Ok(value),
        (None, None) => Ok(50.0),
    }
}

// What: the NATS URL a remote secondary can dial, or None.
// Why: an unreachable internal URL must never be handed out.
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

// What: true for empty or a shared-secret placeholder.
// Why: mirrors the shell library; dev secrets stay real.
// From: Issue #967
fn shared_secret_is_placeholder(value: &str) -> bool {
    let normalized = value.to_ascii_lowercase().replace('-', "_");
    normalized.is_empty()
        || normalized.starts_with("change_me")
        || normalized.starts_with("changeme")
        || normalized.starts_with("your_")
        || normalized.ends_with("_here")
}

// What: shared-secret file name of a variable (A_B -> a-b).
// Why: one naming rule replaces any per-secret name list.
// From: Issue #858
fn shared_secret_file_name(var: &str) -> String {
    var.to_ascii_lowercase().replace('_', "-")
}

// What: a real env value, else its shared-secret file.
// Why: backends write the file; the ui only reads it.
// From: Issue #858
fn shared_secret(
    dir: &str,
    var: &str,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<String, String> {
    let configured = env(var).unwrap_or_default();
    if !shared_secret_is_placeholder(&configured) {
        return Ok(configured);
    }
    let path = Path::new(dir).join(shared_secret_file_name(var));
    match fs::read_to_string(&path) {
        Ok(value) => Ok(value.replace('\n', "")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read {var} from {}: {e}", path.display())),
    }
}

// What: first-writer-wins read-or-create of one secret file.
// Why: independent starters must never split-brain a secret.
// From: Issue #858
fn resolve_shared_secret(
    dir: &Path,
    name: &str,
    current: &str,
    gid: u32,
) -> Result<String, String> {
    let file = dir.join(name);
    let on_disk = || {
        fs::read_to_string(&file)
            .ok()
            .map(|v| v.replace('\n', ""))
            .filter(|v| !v.is_empty())
    };
    if let Some(existing) = on_disk()
        && (current.is_empty() || existing == current)
    {
        return Ok(existing);
    }
    // What: a configured value survives a failed write.
    // Why: only a disagreeing file makes it unsafe to use.
    // From: PR #1775
    let keep_current = || {
        let conflict = match on_disk() {
            Some(v) => v != current,
            None => file.exists(),
        };
        !current.is_empty() && !conflict
    };
    let value = if current.is_empty() {
        hex::encode(rand::random::<[u8; 32]>())
    } else {
        current.to_string()
    };
    let place = if current.is_empty() {
        Place::Exclusive
    } else {
        Place::Replace
    };
    // What: try with the reader group, then without it.
    // Why: some volumes refuse chgrp; 0640 stays either way.
    let written = write_file_as(
        &file,
        value.as_bytes(),
        0o640,
        place,
        Some((None, Some(gid))),
    )
    .or_else(|_| write_file_as(&file, value.as_bytes(), 0o640, place, None));
    if written.is_ok() {
        return Ok(value);
    }
    if current.is_empty()
        && let Some(existing) = on_disk()
    {
        return Ok(existing);
    }
    if keep_current() {
        return Ok(current.to_string());
    }
    Err(format!("cannot place {}", file.display()))
}

// What: read-or-create the secret files named by a prefix.
// Why: each starter makes only its own; "" means all.
// From: Issue #858
fn ensure_shared_secrets(dir: &str, gid: u32, prefix: &str) -> Result<(), String> {
    for var in SHARED_SECRET_VARS.iter().filter(|v| v.starts_with(prefix)) {
        let configured = config::env_opt(var).unwrap_or_default();
        let current = if shared_secret_is_placeholder(&configured) {
            ""
        } else {
            configured.as_str()
        };
        resolve_shared_secret(Path::new(dir), &shared_secret_file_name(var), current, gid)
            .map_err(|e| format!("{var}: {e}"))?;
    }
    Ok(())
}
// What: names and limits of CSRF, session and token file.
// Why: one spelling for the middleware and its callers.
const CSRF_HEADER_NAME: &str = "X-CSRF-Token";
const CSRF_FORM_FIELD: &str = "csrf_token";
const MAX_CSRF_BODY_BYTES: usize = 1024 * 1024;
const MAX_UI_SESSION_TTL_SECONDS: u64 = 365 * 24 * 60 * 60;
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
    docker: DockerProxy,
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
    nats_issuer_public_key: String,
    nats_callout_xkey_public_key: String,
}

// What: handler state extractor over the shared AppState.
// Why: every handler takes the same Arc-wrapped state.
type Shared = State<Arc<AppState>>;

// What: a submitted form as text values by field name.
// Why: every form handler reads text and numbers the same way.
#[derive(Deserialize)]
#[serde(transparent)]
struct Fields(HashMap<String, String>);

impl Fields {
    // What: one field trimmed; an absent field reads as empty.
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
// Why: the cookie never authenticates; it binds a CSRF token.
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
    let csrf_token = hex::encode(rand::random::<[u8; 32]>());
    let expires = unix_secs() + ttl.as_secs();
    let signature = cookie_signature(secret, expires, &csrf_token);
    Session {
        cookie_value: format!("v1.{expires}.{csrf_token}.{signature}"),
        csrf_token,
    }
}

// What: the session a cookie value proves, if any.
// Why: expired, edited or foreign cookies get a new session.
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
// Why: only a TLS-terminating proxy in front sets this header.
fn forwarded_proto_is_https(headers: &HeaderMap) -> bool {
    headers
        .get("x-forwarded-proto")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .is_some_and(|proto| proto.trim().eq_ignore_ascii_case("https"))
}

// What: security headers on every response.
// Why: the policy is on by default and optional for debugging.
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
    if let (Some(user), Some(pass)) = (&state.config.auth_user, &state.config.auth_password) {
        let valid = req
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Basic "))
            .and_then(|enc| base64::engine::general_purpose::STANDARD.decode(enc).ok())
            .and_then(|dec| String::from_utf8(dec).ok())
            .and_then(|creds| {
                let (u, p) = creds.split_once(':')?;
                Some(ct_eq(u, user) & ct_eq(p, pass))
            })
            .unwrap_or(false);
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
                if submitted.is_some_and(|token| ct_eq(&session.csrf_token, &token)) {
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

// What: a template context with the page name and CSRF token.
// Why: every page's forms need the token of the live session.
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
    ctx
}

// What: render a template; a failure is a real HTTP 500.
// Why: monitors read the status; dev mode shows the cause.
fn render(state: &AppState, name: &str, ctx: &Context) -> Response {
    match state.templates.render(name, ctx) {
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
// Why: one error type serves cache, NTP, settings and DHCP.
struct ErrorArea {
    title: &'static str,
    href: &'static str,
    back: &'static str,
}

// What: the error-page areas of HtmlError.
// Why: each area names its title and back link.
const CACHE_AREA: ErrorArea = ErrorArea {
    title: "Cache Resize Error",
    href: "/",
    back: "Return to dashboard",
};
const NTP_AREA: ErrorArea = ErrorArea {
    title: "NTP Configuration Error",
    href: "/ntp",
    back: "Return to NTP settings",
};
const DHCP_AREA: ErrorArea = ErrorArea {
    title: "DHCP Configuration Error",
    href: "/dhcp",
    back: "Return to DHCP settings",
};
const SETTINGS_AREA: ErrorArea = ErrorArea {
    title: "Settings Error",
    href: "/setup",
    back: "Return to setup",
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
    // Why: a failed form post shows a reason and a way back.
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
// Why: brand assets are long-cacheable, the stylesheet is not.
fn asset(content_type: &'static str, cached: bool, body: &'static [u8]) -> Response {
    let headers = [(header::CONTENT_TYPE, content_type)];
    if cached {
        let cache = [(header::CACHE_CONTROL, "public, max-age=31536000")];
        return (headers, cache, body).into_response();
    }
    (headers, body).into_response()
}

// What: liveness answer, always ok.
// Why: a constant answer shows only that the process serves.
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

// What: load every template and the image template functions.
// Why: a broken template is a deploy defect; fail early.
fn load_templates(cfg: &Config) -> Tera {
    let mut tera = Tera::default();
    tera.autoescape_on(vec!["html"]);
    // What: register functions before adding templates.
    // Why: Tera checks function calls when it parses a template.
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
// What: services the ui may act on; no watchdog, no syslog.
// Why: the ui must never stop the monitor or the log sink.
// From: Issue #1486
const DOCKER_SERVICES: [(&str, &str); 9] = [
    ("proxy", CONTAINER_PROXY),
    ("dns-standard", CONTAINER_DNS_STANDARD),
    ("dns-ssl", CONTAINER_DNS_SSL),
    ("dhcp", CONTAINER_DHCP),
    ("dhcp-proxy", CONTAINER_DHCP_PROXY),
    ("dhcp-probe", CONTAINER_DHCP_PROBE),
    ("nats", CONTAINER_NATS),
    ("ntp", CONTAINER_NTP),
    ("ui", CONTAINER_UI),
];

// What: time bound of one Docker call from the ui.
// Why: a stuck proxy must not hang a page request.
const DOCKER_TIMEOUT: Duration = Duration::from_secs(120);

// What: the container name of an allowlisted service.
// Why: any other name is refused before Docker sees it.
// From: Issue #1592
fn container_name(service: &str) -> anyhow::Result<&'static str> {
    DOCKER_SERVICES
        .iter()
        .find(|(short, full)| *short == service || *full == service)
        .map(|(_, full)| *full)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "Docker service '{service}' is not in the lancache-ng socket-proxy allowlist"
            )
        })
}

// What: restart a service container after a 5 s grace.
// Why: nginx-style daemons need a moment to drain.
async fn docker_restart(docker: &DockerProxy, service: &str) -> anyhow::Result<()> {
    docker
        .act(
            container_name(service)?,
            "restart?t=5",
            Some(DOCKER_TIMEOUT),
        )
        .await
        .with_context(|| format!("Failed to restart '{service}'"))?;
    tracing::info!("Restarted service '{service}'");
    Ok(())
}

// What: start a service container.
// Why: the stop/start pairs of the mode switches need it.
async fn docker_start(docker: &DockerProxy, service: &str) -> anyhow::Result<()> {
    docker
        .act(container_name(service)?, "start", Some(DOCKER_TIMEOUT))
        .await
        .with_context(|| format!("Failed to start '{service}'"))?;
    tracing::info!("Started service '{service}'");
    Ok(())
}

// What: stop a service; an absent container is fine.
// Why: a 404 means the wanted state already holds.
async fn docker_stop_if_present(docker: &DockerProxy, service: &str) -> anyhow::Result<()> {
    match docker
        .act(container_name(service)?, "stop?t=10", Some(DOCKER_TIMEOUT))
        .await
    {
        Ok(()) => {
            tracing::info!("Stopped service '{service}'");
            Ok(())
        }
        Err(DockerError::Status(404)) => Ok(()),
        Err(err) => Err(err).with_context(|| format!("Failed to stop '{service}'")),
    }
}

// What: true when a start failed because it never existed.
// Why: only a profile-gated service gives 404; hint it.
fn container_never_created(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<DockerError>(),
            Some(DockerError::Status(404))
        )
    })
}

// What: services in watchdog display order, with labels.
// Why: restart-capable ones sort before alert-only ones.
// From: Issue #1437
const WATCHDOG_LABELS: [(&str, &str); 10] = [
    (CONTAINER_PROXY, "Proxy"),
    (CONTAINER_DNS_STANDARD, "DNS (standard)"),
    (CONTAINER_DNS_SSL, "DNS (SSL)"),
    (CONTAINER_NATS, "NATS"),
    (CONTAINER_UI, "Admin UI"),
    (CONTAINER_DHCP, "DHCP (Kea)"),
    (CONTAINER_DHCP_PROXY, "DHCP (proxy/relay)"),
    (CONTAINER_NTP, "NTP"),
    (CONTAINER_SYSLOG, "Central logging"),
    (CONTAINER_NETDATA, "Netdata"),
];

// What: the watchdog document as the dashboard shows it.
// Why: fresh, stale and missing data look different.
// From: Issue #870
fn watchdog_json(path: &str) -> Value {
    let stale_after = Duration::from_secs(90);
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
    let mut services: Vec<(usize, Value)> = status
        .services
        .iter()
        .map(|(name, health)| {
            let slot = WATCHDOG_LABELS.iter().position(|(n, _)| n == name);
            let label = slot.map_or(name.as_str(), |i| WATCHDOG_LABELS[i].1);
            let entry = json!({
                "name": name,
                "label": label,
                "status": health.status,
                "health": health.health,
                "failures": health.failures,
            });
            (slot.unwrap_or(WATCHDOG_LABELS.len()), entry)
        })
        .collect();
    services.sort_by(|a, b| (a.0, a.1["name"].as_str()).cmp(&(b.0, b.1["name"].as_str())));
    let services: Vec<Value> = services.into_iter().map(|(_, entry)| entry).collect();
    if age > stale_after {
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

// What: size of an allowed directory in GiB, 0 if refused.
// Why: du beats a Rust walk over hundreds of GB of files.
fn du_gb(path: &str) -> f64 {
    if !path_allowed(path) {
        return 0.0;
    }
    let bytes: u64 = Command::new("du")
        .args(["-sb", path])
        .output()
        .ok()
        .and_then(|out| {
            String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .next()
                .and_then(|n| n.parse().ok())
        })
        .unwrap_or(0);
    bytes as f64 / 1_073_741_824.0
}

// What: free MiB on the cache filesystem; None if unknown.
// Why: callers must fail closed, never assume unlimited space.
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
    const KB: u64 = 1_024;
    const MB: u64 = 1_048_576;
    const GB: u64 = 1_073_741_824;
    match bytes {
        GB.. => format!("{:.1} GB", bytes as f64 / GB as f64),
        MB.. => format!("{:.1} MB", bytes as f64 / MB as f64),
        KB.. => format!("{:.1} KB", bytes as f64 / KB as f64),
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
    source: String,
}

// What: totals over the parsed access-log lines.
// Why: the stats page shows one aggregate per request.
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

// What: the access-log line pattern of nginx.conf.
// Why: groups: ip time method path status bytes cache host
fn log_regex() -> &'static Regex {
    static LOG_REGEX: OnceLock<Regex> = OnceLock::new();
    LOG_REGEX.get_or_init(|| {
        Regex::new(r#"^(\S+) - \[([^\]]+)\] "(\S+) (\S+) [^"]+" (\d+) (\d+) "([^"]*)" "([^"]*)""#)
            .expect("log regex is valid")
    })
}

// What: the last `limit` lines of a file, oldest first.
// Why: reading backwards keeps a multi-GB log cheap to tail.
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
    // What: stop only once more than `limit` newlines were read.
    // Why: the first segment may be cut and is dropped below.
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
fn parse_log_tail(path: &str, limit: usize) -> Vec<LogEntry> {
    tail_lines(path, limit)
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
                source: String::new(),
            })
        })
        .collect()
}

// What: nginx $time_local as epoch seconds.
// Why: entries of two logs must order by real time.
fn log_time_epoch(time_local: &str) -> i64 {
    const FORMAT: &[time::format_description::BorrowedFormatItem<'static>] = time::macros::format_description!(
        "[day]/[month repr:short]/[year]:[hour]:[minute]:[second] [offset_hour sign:mandatory][offset_minute]"
    );
    time::OffsetDateTime::parse(time_local, FORMAT)
        .map(|t| t.unix_timestamp())
        .unwrap_or(0)
}

// What: tail of the standard and ssl log, merged by time.
// Why: each source is read in full; the cap applies after.
fn merged_log_tail(standard: &str, ssl: &str, limit: usize) -> Vec<LogEntry> {
    let label = |mut entries: Vec<LogEntry>, source: &str| {
        entries
            .iter_mut()
            .for_each(|e| e.source = source.to_string());
        entries
    };
    if standard == ssl {
        return label(parse_log_tail(standard, limit), "Shared");
    }
    let mut merged = label(parse_log_tail(standard, limit), "Standard");
    merged.extend(label(parse_log_tail(ssl, limit), "SSL"));
    merged.sort_by_key(|entry| log_time_epoch(&entry.time));
    let excess = merged.len().saturating_sub(limit);
    merged.drain(..excess);
    merged
}

// What: hit, miss and byte totals over both access logs.
// Why: an identical path is counted once, not twice.
fn log_stats(standard: &str, ssl: &str) -> LogStats {
    let mut stats = LogStats::default();
    let mut total_bytes: u64 = 0;
    let mut paths = vec![standard];
    if ssl != standard {
        paths.push(ssl);
    }
    for path in paths {
        let Ok(file) = File::open(path) else { continue };
        // What: read raw lines, decode each lossily.
        // Why: one non-UTF-8 byte must not hide later requests.
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
    stats.total_bytes_gb = total_bytes as f64 / 1_073_741_824.0;
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
        .unwrap_or_default();
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

// What: file content, decompressed by extension.
// Why: rotated files may be plain, zstd or gzip.
fn read_syslog_file(path: &Path) -> Option<String> {
    let raw = fs::read(path).ok()?;
    let bytes = match path.extension().and_then(|e| e.to_str()) {
        Some("zst") => {
            let mut out = Vec::new();
            zstd::stream::copy_decode(&raw[..], &mut out).ok()?;
            out
        }
        Some("gz") => {
            let mut out = Vec::new();
            flate2::read::GzDecoder::new(&raw[..])
                .read_to_end(&mut out)
                .ok()?;
            out
        }
        _ => raw,
    };
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// What: one syslog line as an entry; odd lines are kept raw.
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
// Why: every host with data must show before the early stop.
fn syslog_tail(root: &str, host: Option<&str>, limit: usize) -> Vec<SyslogEntry> {
    if limit == 0 {
        return vec![];
    }
    // What: a host must be one bare directory name.
    // Why: the value comes from the URL and must not escape root.
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

// What: merge hosts into `limit` lines, quiet hosts included.
// Why: a plain sort-and-cut drops a quiet host's only error.
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
// Why: metadata only; decompressing every file costs too much.
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
            // What: the leading YYYYMMDD of <day>.log[...] names.
            // Why: the number of days is the retention in view.
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

// What: header and path of the netdata alarm webhook.
// Why: netdata and the ui must spell both the same way.
const ALARM_TOKEN_HEADER: &str = "X-Netdata-Alarm-Token";
const ALARM_INGEST_PATH: &str = "/api/netdata-alarms";

// What: stored alarm history cap, newest kept.
// Why: a burst of alarms must not grow the file unbounded.
const MAX_ALARMS: usize = 50;

// What: one alarm; the names are custom_sender's variables.
// Why: the sender script is rendered from these fields.
// From: Issue #849
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct NetdataAlarm {
    unique_id: i64,
    alarm_id: i64,
    event_id: i64,
    when: i64,
    name: String,
    chart: String,
    host: String,
    status: String,
    old_status: String,
    value_string: String,
    units: String,
    info: String,
    duration: i64,
}

// What: stored alarms, newest first; any failure is empty.
// Why: the dashboard must render even with a broken file.
fn read_alarms(path: &str) -> Vec<NetdataAlarm> {
    fs::read_to_string(path)
        .ok()
        .and_then(|content| serde_json::from_str(&content).ok())
        .unwrap_or_default()
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

// What: netdata custom_sender that POSTs alarms to the ui.
// Why: fields come from NetdataAlarm; there is no second list.
// From: Issue #858
fn render_alarm_notify_conf(
    ui_url: &str,
    token_file: &str,
    max_time: &str,
    recipient: &str,
) -> Result<String, String> {
    for value in [ui_url, token_file, max_time, recipient] {
        let plain = |c: char| c.is_ascii_alphanumeric() || "-._:/".contains(c);
        if value.is_empty() || !value.chars().all(plain) {
            return Err(format!("{value:?} is no plain URL or path"));
        }
    }
    let sample = serde_json::to_value(NetdataAlarm::default()).map_err(|e| e.to_string())?;
    let fields = sample.as_object().ok_or("alarm is no JSON object")?;
    let json: Vec<String> = fields
        .iter()
        .map(|(key, value)| {
            if value.is_string() {
                format!("\\\"{key}\\\":\\\"$(_lancache_json_escape \"${{{key}}}\")\\\"")
            } else {
                format!("\\\"{key}\\\":${{{key}}}")
            }
        })
        .collect();
    let json = json.join(",");
    let ok = StatusCode::OK.as_u16();
    Ok(format!(
        r#"SEND_CUSTOM="YES"
DEFAULT_RECIPIENT_CUSTOM="{recipient}"
_lancache_json_escape() {{
  printf '%s' "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}}
custom_sender() {{
  local token httpcode
  token="$(cat "{token_file}")" || return 1
  httpcode="$(docurl --max-time {max_time} -X POST -H "Content-Type: application/json" -H "{ALARM_TOKEN_HEADER}: ${{token}}" -d "{{{json}}}" "{ui_url}{ALARM_INGEST_PATH}")" || {{
    error "lancache-ui alarm POST failed: HTTP ${{httpcode}}"
    return 1
  }}
  [ "${{httpcode}}" = "{ok}" ] && return 0
  error "lancache-ui alarm POST returned HTTP ${{httpcode}}"
  return 1
}}
"#
    ))
}

// What: store an alarm sent by netdata's custom_sender.
// Why: the token header gates it; an unset token rejects all.
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
        let _guard = state
            .netdata_alarms_lock
            .lock()
            .expect("alarms lock poisoned");
        append_alarm(&state.config.netdata_alarms_file, alarm)
    };
    match stored {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::warn!("failed to persist netdata alarm: {e}");
            StatusCode::SERVICE_UNAVAILABLE
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

// What: the reverse zone (dotted) that owns an IPv4 address.
// Why: only zones the stack provisions may hold a PTR.
fn reverse_zone_for_ipv4(ip: Ipv4Addr) -> Option<String> {
    let [a, b, _, _] = ip.octets();
    let zones = rollback_zones();
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
// Why: stored probe targets must never become an SSRF lever.
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

// What: ask addr:port for the lan. SOA over UDP.
// Why: a silent host is a status, not an error.
async fn probe_secondary_soa(addr: Ipv4Addr, port: u16) -> ProbeResult {
    const TIMEOUT: Duration = Duration::from_secs(4);
    let id: u16 = rand::random();
    // What: a one-question query for lan. SOA, no flags.
    // Why: any answer with a serial proves the zone is served.
    let mut query = id.to_be_bytes().to_vec();
    query.extend_from_slice(&[
        0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, b'l', b'a', b'n', 0, 0, 6, 0, 1,
    ]);
    let exchange = async {
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
// Why: revocation is the per-connect DB check, not the expiry.
const USER_JWT_TTL_SECS: i64 = 90 * 24 * 60 * 60;

// What: sleep, then double the delay up to a cap.
// Why: one backoff step for every NATS retry loop.
// From: Issue #849
async fn backoff(delay: &mut Duration, max: Duration) {
    tokio::time::sleep(*delay).await;
    *delay = (*delay * 2).min(max);
}

// What: connect to NATS as one static role.
// Why: every ui connection authenticates by user and password.
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
    let mut delay = Duration::from_secs(1);
    loop {
        match nats_connect(&cfg.nats_url, &cfg.nats_ui).await {
            Ok(client) => {
                tracing::info!("Connected to NATS at {}", cfg.nats_url);
                return client;
            }
            Err(err) => {
                tracing::warn!(
                    "Cannot connect to NATS at {}: {err}. Retrying in {delay:?}",
                    cfg.nats_url
                );
                backoff(&mut delay, Duration::from_secs(30)).await;
            }
        }
    }
}

// What: why a value cannot sit in a quoted NATS string.
// Why: a quote, backslash or control char breaks nats.conf.
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

// What: the five static roles with their display labels.
// Why: nats.conf, validation and callout users share one list.
fn nats_roles(cfg: &Config) -> [(&'static str, &NatsLogin); 5] {
    [
        ("NATS UI", &cfg.nats_ui),
        ("NATS DNS writer", &cfg.nats_dns_writer),
        ("NATS DNS replica", &cfg.nats_dns_replica),
        ("NATS auth-callout", &cfg.nats_callout),
        ("NATS system account", &cfg.nats_sys),
    ]
}

// What: every static role has valid credentials.
// Why: nats.conf and the ui connection fail closed on bad env.
fn validate_nats_credentials(cfg: &Config) -> Result<(), String> {
    nats_roles(cfg)
        .iter()
        .try_for_each(|(label, login)| validate_nats_login(label, login))
}

// What: publish rights of every reader of the DNS stream.
// Why: static DNS roles and secondaries must grant alike.
fn dns_reader_publish() -> Vec<String> {
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
fn dns_subscribe() -> [&'static str; 2] {
    [NATS_SUBJECT_DNS, "_INBOX.>"]
}

// What: a NATS list of double-quoted strings.
// Why: every subject list in nats.conf uses one syntax.
fn nats_list<S: AsRef<str>>(items: &[S]) -> String {
    let quoted: Vec<String> = items
        .iter()
        .map(|s| format!("\"{}\"", s.as_ref()))
        .collect();
    format!("[{}]", quoted.join(", "))
}

// What: one static user block, rights only when given.
// Why: the callout user must have no subject rights.
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
fn render_nats_conf(cfg: &Config) -> Result<String, String> {
    validate_nats_credentials(cfg)?;
    let store_dir = cfg
        .nats_store_dir
        .as_deref()
        .ok_or("NATS_STORE_DIR is not set")?;
    let raw_port = cfg
        .nats_monitor_port
        .as_deref()
        .ok_or("NATS_MONITOR_PORT is not set")?;
    let monitor_port: u16 = raw_port
        .parse()
        .map_err(|_| format!("NATS_MONITOR_PORT={raw_port} is not a TCP port"))?;
    let fragment = Path::new(&cfg.nats_auth_callout_path);
    if fragment.parent() != Path::new(&cfg.nats_conf_path).parent() {
        return Err(format!(
            "{} must sit next to {}",
            cfg.nats_auth_callout_path, cfg.nats_conf_path
        ));
    }
    let include = fragment
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| format!("{} has no file name", cfg.nats_auth_callout_path))?;
    for (label, value) in [
        ("NATS store dir", store_dir),
        ("NATS log file", cfg.nats_log_file.as_str()),
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
        nats_role_block(
            &cfg.nats_ui,
            &[NATS_SUBJECT_RECORD, NATS_SUBJECT_FLUSH],
            &none,
        ),
        nats_role_block(&cfg.nats_dns_writer, &writer_publish, &dns_subscribe()),
        nats_role_block(&cfg.nats_dns_replica, &writer_publish, &dns_subscribe()),
        nats_role_block(&cfg.nats_callout, &none, &none),
    ]
    .concat();
    let log_file = &cfg.nats_log_file;
    let sys = &cfg.nats_sys;
    let sys_password = sys.password.as_deref().unwrap_or_default();
    let sys_user = &sys.user;
    Ok(format!(
        "jetstream {{\n  store_dir: \"{store_dir}\"\n}}\n\
         http_port: {monitor_port}\n\
         log_file: \"{log_file}\"\n\
         authorization {{\n  users = [\n{users}  ]\n  include \"{include}\"\n}}\n\
         accounts {{\n  SYS: {{\n    users: [\n      \
         {{ user: \"{sys_user}\", password: \"{sys_password}\" }}\n    ]\n  }}\n}}\n\
         system_account: SYS\n"
    ))
}

// What: the auth_callout stanza nats.conf includes.
// Why: only the ui knows the issuer and xkey public keys.
// From: Issue #811 | PR #1858
fn render_auth_callout_fragment(cfg: &Config, issuer: &str, xkey: &str) -> String {
    let users: Vec<String> = nats_roles(cfg)
        .iter()
        .map(|(_, l)| format!("\"{}\"", l.user))
        .collect();
    format!(
        "auth_callout {{\n  issuer: \"{issuer}\"\n  xkey: \"{xkey}\"\n  auth_users: [{}]\n}}\n",
        users.join(", ")
    )
}

// What: write the fragment; restart NATS only on a change.
// Why: nats-server cannot hot-reload; restart drops clients.
// From: Issue #811
async fn reload_nats_conf(state: &AppState) -> Result<(), String> {
    validate_nats_credentials(&state.config)?;
    let fragment = render_auth_callout_fragment(
        &state.config,
        &state.nats_issuer_public_key,
        &state.nats_callout_xkey_public_key,
    );
    let changed = write_if_changed(
        Path::new(&state.config.nats_auth_callout_path),
        fragment.as_bytes(),
        0o644,
        None,
    )
    .map_err(|e| e.to_string())?;
    if !changed {
        return Ok(());
    }
    docker_restart(&state.docker, &state.config.nats_service)
        .await
        .map_err(|e| format!("Failed to restart NATS service: {e:#}"))
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
// Why: the request is trusted by subject, not signature.
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

// What: Argon2id PHC hash of a secondary's NATS password.
// Why: only the hash is stored; the plaintext is shown once.
fn hash_nats_password(password: &str) -> Result<String, String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|hash| hash.to_string())
        .map_err(|e| format!("failed to hash secondary password with Argon2id: {e}"))
}

// What: the secondary a user and password belong to.
// Why: a missing row and a wrong password look the same.
fn authorize_secondary(state: &AppState, nats_user: &str, password: &str) -> Option<String> {
    let stored: String = state
        .db
        .lock()
        .ok()?
        .query_row(
            "SELECT nats_password_hash FROM secondaries WHERE nats_user = ?1",
            [nats_user],
            |row| row.get(0),
        )
        .ok()?;
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
    // What: a request is sealed when nats-server sends its xkey.
    // Why: no local switch; an unsealed request still works.
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

// What: serve $SYS.REQ.USER.AUTH for the life of the process.
// Why: the row is checked per connect; removal is instant.
// From: Issue #583
async fn run_auth_callout(state: Arc<AppState>, issuer: KeyPair, xkey: XKey) {
    let mut delay = Duration::from_secs(1);
    loop {
        let client = match nats_connect(&state.config.nats_url, &state.config.nats_callout).await {
            Ok(client) => {
                delay = Duration::from_secs(1);
                client
            }
            Err(err) => {
                tracing::warn!(
                    "auth-callout: cannot connect to NATS: {err}. Retrying in {delay:?}"
                );
                backoff(&mut delay, Duration::from_secs(30)).await;
                continue;
            }
        };
        let mut sub = match client.subscribe("$SYS.REQ.USER.AUTH").await {
            Ok(sub) => sub,
            Err(err) => {
                tracing::error!("auth-callout: failed to subscribe: {err}");
                backoff(&mut delay, Duration::from_secs(30)).await;
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
    if state.config.nats_sys.user.is_empty() {
        return Err("NATS_SYS_USER is not configured".to_string());
    }
    let client = tokio::time::timeout(
        STEP,
        nats_connect(&state.config.nats_url, &state.config.nats_sys),
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
    let _ = client.drain().await;
    Ok(kicked)
}

// What: kick in the background after the DB change committed.
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
    proxy_ip: String,
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
    let conn = state
        .db
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    f(&conn).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

// What: true for the configured registration token.
// Why: an unset token must never mean open registration.
fn registration_token_ok(state: &AppState, presented: &str) -> bool {
    let token = &state.config.secondary_registration_token;
    !token.is_empty() && ct_eq(presented, token)
}

// What: a fresh 32-byte hex NATS password.
// Why: the plaintext is shown once; only its hash is stored.
fn new_nats_password() -> String {
    hex::encode(rand::random::<[u8; 32]>())
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
    .unwrap_or_default();
    let mut ctx = page_ctx(&headers, "secondaries");
    ctx.insert("secondaries", &secondaries);
    ctx.insert(
        "primary_url",
        &format!(
            "http://{}:{}",
            state.config.standard_ip, state.config.listen_port
        ),
    );
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
    // Why: the internal URL is unreachable for a remote node.
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
    let hash = hash_nats_password(&nats_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let reported = form
        .address
        .as_deref()
        .and_then(parse_private_ipv4)
        .map(|ip| ip.to_string());
    // What: keep a stored address when none is reported.
    // Why: a re-registration must not wipe a manual override.
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
        proxy_ip: state.config.standard_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
        ddns_tsig_key,
        dns_xfr_primary: format!("{}:5300", state.config.standard_ip),
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
// Why: the probe address is set by hand when none was found.
#[derive(Deserialize)]
struct SetAddressForm {
    address: String,
}

// What: set a secondary's probe address by hand.
// Why: the fallback when detection found none; private only.
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
            rusqlite::params![addr.to_string(), name],
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
    // What: probe port 53, the secondary's own DNS.
    // Why: 5300 is only the primary's AXFR listener.
    let result = probe_secondary_soa(addr, 53).await;
    if result.status == "ok" {
        let _ = with_db(&state, |db| {
            db.execute(
                "UPDATE secondaries SET last_seen = ? WHERE name = ?",
                rusqlite::params![unix_secs() as i64, name],
            )
        });
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
// Why: the old hash is overwritten, so it stops working now.
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
    let hash = hash_nats_password(&nats_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
// What: lease time limits in seconds.
// Why: Kea needs a floor; seven days is the documented cap.
const MIN_LEASE_TIME: u32 = 60;
const MAX_LEASE_TIME: u32 = 604_800;

// What: longest custom option value in bytes.
// Why: one form must not write unbounded data into Kea.
const CUSTOM_OPTION_DATA_MAX: usize = 1024;

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
// Why: the page needs plain fields, not Kea's option arrays.
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
// Why: the page never gets the config itself, only a handle.
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

// What: write DHCP settings; a failure is a DHCP error page.
// Why: save_settings keeps every other key of the file intact.
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
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&body)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json::<Value>()
        .await
        .map_err(|e| e.to_string())
}

// What: the result code of Kea's first reply; 1 if absent.
// Why: Kea reports failures inside a 200 response.
fn kea_code(reply: &Value) -> i64 {
    reply
        .get(0)
        .and_then(|r| r.get("result"))
        .and_then(Value::as_i64)
        .unwrap_or(1)
}

// What: the text of Kea's first reply.
// Why: it names the reason when the result code is not 0.
fn kea_text(reply: &Value) -> &str {
    reply
        .get(0)
        .and_then(|r| r.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("Kea error")
}

// What: send a command and require result code 0.
// Why: config-get, -test and -set all share this rule.
async fn kea_run(
    state: &AppState,
    command: &str,
    arguments: Option<&Value>,
) -> Result<Value, String> {
    let reply = kea_post(state, command, arguments).await?;
    if kea_code(&reply) != 0 {
        return Err(kea_text(&reply).to_string());
    }
    Ok(reply)
}

// What: Kea's running config without the hash key.
// Why: Kea refuses its own hash key on config-test and -set.
async fn kea_config(state: &AppState) -> Result<Value, String> {
    let reply = kea_run(state, "config-get", None).await?;
    let mut config = reply
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?;
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

// What: the three outcomes of Kea's config-write.
// Why: a lost request is not a refusal; it may have applied.
enum Written {
    Done,
    Refused(String),
    Unknown(String),
}

// What: persist the running config to disk.
// Why: the caller branches on the three-way outcome.
async fn kea_write(state: &AppState) -> Written {
    match kea_post(state, "config-write", None).await {
        Ok(reply) if kea_code(&reply) == 0 => Written::Done,
        Ok(reply) => Written::Refused(kea_text(&reply).to_string()),
        Err(e) => Written::Unknown(e),
    }
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

    // What: record the applied config as a known-good snapshot.
    // Why: a failed snapshot weakens rollback, not the edit.
    let record = || {
        let keep = state.config.kea_keep_known_good_configs;
        if let Err(e) = kea_store(&state.config).create(&config, keep) {
            tracing::warn!(error = %e, "failed to record a known-good Kea snapshot");
        }
    };
    match kea_write(state).await {
        Written::Done => {
            record();
            Ok(())
        }
        Written::Refused(e) => {
            tracing::warn!(error = %e, "DHCP config-write failed; rolling back");
            kea_rollback(state, &old, &e).await
        }
        // What: one retry when the write outcome is unknown.
        // Why: rolling back blindly could undo a write that landed.
        Written::Unknown(first) => match kea_write(state).await {
            Written::Done => {
                record();
                Ok(())
            }
            Written::Refused(retry) => Err(format!(
                "Config applied at runtime but the first config-write result was ambiguous, \
                 and a retry returned a Kea failure. Runtime and persisted config may now \
                 differ. First error: {first}. Retry error: {retry}"
            )),
            Written::Unknown(retry) => Err(format!(
                "Config applied at runtime but config-write could not be confirmed after \
                 retry. Runtime and persisted config may now differ. First error: {first}. \
                 Retry error: {retry}"
            )),
        },
    }
}

// What: kea_apply with errors as DHCP error pages.
// Why: a missing subnet or option is a 404, not a failure.
async fn kea_modify(
    state: &AppState,
    change: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
) -> Result<(), HtmlError> {
    kea_apply(state, change).await.map_err(|message| {
        let status = match message.as_str() {
            "subnet not found" | "custom option not found" => StatusCode::NOT_FOUND,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        dhcp_error(status, message)
    })
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
// Why: each missing level gets its own message for debugging.
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
// Why: "subnet not found" maps to a 404 in kea_modify.
fn find_subnet_mut(config: &mut Value, id: u32) -> Result<&mut Value, &'static str> {
    subnets_mut(config)?
        .iter_mut()
        .find(|s| s["id"].as_u64() == Some(u64::from(id)))
        .ok_or("subnet not found")
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
    let by_code = matches!(
        option.get("code").and_then(Value::as_u64),
        Some(3 | 6 | 15 | 42 | 119)
    );
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
            .is_some_and(|code| (1..=254).contains(&code))
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
fn read_subnet(subnet: &Value) -> Subnet {
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
        // What: 86400 s when the subnet sets no lifetime.
        // Why: equals Kea's own default valid-lifetime.
        lease_time: subnet
            .get("valid-lifetime")
            .and_then(Value::as_u64)
            .unwrap_or(86_400) as u32,
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
    let reply = kea_post(state, "lease4-get-all", None).await?;
    Ok(reply
        .get(0)
        .and_then(|r| r.get("arguments"))
        .and_then(|a| a.get("leases"))
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
                // Why: the page shows an absolute expiry time.
                expires: (seconds("cltt") + seconds("valid-lft")).to_string(),
            }
        })
        .collect())
}

// What: the settings page with live Kea data when reachable.
// Why: an unreachable Kea renders empty tables, not an error.
async fn dhcp_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "dhcp");
    ctx.insert("dhcp_mode", cfg.dhcp_mode().as_str());
    ctx.insert("dhcp_has_kea", &cfg.dhcp_mode().is_kea());
    ctx.insert("dhcp_api_url", &cfg.dhcp_api_url);
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
        // Why: a Kea with many leases would load the page slowly.
        let (config, found) = tokio::join!(kea_config(&state), kea_leases(&state));
        if let Ok(config) = config {
            subnets = subnets_in(&config).iter().map(read_subnet).collect();
            ddns = config["Dhcp4"]["dhcp-ddns"]["enable-updates"]
                .as_bool()
                .unwrap_or(false);
            reservations = read_reservations(&config);
        }
        leases = found.unwrap_or_default();
    }
    ctx.insert("subnets", &subnets);
    ctx.insert("dhcp_ddns_enabled", &ddns);
    ctx.insert("leases", &leases);
    ctx.insert("reservations", &reservations);

    // What: snapshots newest first, with creation times.
    // Why: operators pick a rollback target from the newest.
    let snapshots: Vec<SnapshotSummary> = kea_store(cfg)
        .ids()
        .unwrap_or_default()
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

// What: a MAC with 12 hex digits, colons or hyphens allowed.
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
    if prefix != 0 && network & !mask != 0 {
        return None;
    }
    Some((network & mask, mask))
}

// What: a short interface name such as eth0 or br-lan.100.
// Why: the value lands unquoted in dnsmasq's interface line.
fn is_valid_interface_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

// What: a PXE boot file name without separators or controls.
// Why: a comma would shift fields in dhcp-boot=file,,server.
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
fn validate_subnet(f: &Fields) -> Result<(u32, (u32, u32)), &'static str> {
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
            "Pool and gateway must lie inside the subnet, and the pool start must not follow its end.",
        );
    }
    let ntp = f.get("ntp_servers");
    if !ntp.is_empty() && split_list(ntp).is_empty() {
        return Err("Invalid NTP servers: use a list of addresses or host names.");
    }
    let domain = f.get("domain");
    if !domain.is_empty() && !is_valid_domain_name(domain) {
        return Err("Invalid domain: use a plain DNS domain name (letters, digits, '-', '.').");
    }
    let lease = f
        .number::<u32>("lease_time")
        .filter(|t| (MIN_LEASE_TIME..=MAX_LEASE_TIME).contains(t))
        .ok_or("Lease time must be between 60 and 604800 seconds.")?;
    Ok((lease, cidr))
}

// What: NTP entries as one list of IPv4 literals.
// Why: Kea option 42 takes addresses; names are resolved here.
// From: Issue #670
async fn resolve_ntp_servers(raw: &str) -> Result<String, String> {
    let mut resolved = Vec::new();
    for entry in split_list(raw) {
        let address = match entry.parse::<Ipv4Addr>() {
            Ok(address) => address,
            // What: reject digits-and-dots that are no address.
            // Why: a typo like 1.2.3 must fail, not reach DNS.
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
) -> Result<(), &'static str> {
    // What: cap the maximum lifetime at the seven-day limit.
    // Why: doubling a seven-day lease would exceed the cap.
    let max_lifetime = lease
        .checked_mul(2)
        .ok_or("lease_time too large")?
        .min(MAX_LEASE_TIME);
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
    // What: keep reservations that still fit the new subnet.
    // Why: Kea rejects a subnet holding foreign reservations.
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
    // What: drop a subnet-level reservation identifier list.
    // Why: Kea accepts that key only globally and rejects it here.
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
// Why: the five managed codes must use their own fields only.
fn custom_option_key(raw: &str) -> Result<CustomOptionKey, &'static str> {
    let raw = raw.trim();
    if let Some(field) = PXE_FIELDS.into_iter().find(|field| *field == raw) {
        return Ok(CustomOptionKey::Pxe(field));
    }
    let code = raw
        .parse::<u16>()
        .map_err(|_| "option code must be a number")?;
    if code == 0 || code > 254 {
        return Err("option code must be between 1 and 254");
    }
    if matches!(code, 3 | 6 | 15 | 42 | 119) {
        return Err("option code is managed by dedicated subnet fields");
    }
    Ok(CustomOptionKey::Numeric(code))
}

// What: one-line option data within the length limit.
// Why: values are stored as opaque strings; only shape counts.
fn option_data(raw: &str) -> Result<String, &'static str> {
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

// What: option data checked against what the key accepts.
// Why: next-server needs an IPv4; BOOTP fields have size caps.
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
// Why: add and remove share the option and PXE key handling.
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
                // What: clear only a field still holding the value.
                // Why: a stale page must not remove a changed value.
                (false, true) => object.remove(field),
                (false, false) => return Err("custom option not found"),
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
                // Why: a double submit would otherwise apply both.
                if options.iter().any(same) {
                    return Err("custom option already exists");
                }
                options.push(json!({"space": "dhcp4", "code": code, "data": data}));
            } else {
                let before = options.len();
                options.retain(|o| !same(o));
                if options.len() == before {
                    return Err("custom option not found");
                }
            }
        }
    }
    Ok(())
}

// What: set the ntp-servers option of one subnet.
// Why: the NTP sync must not rebuild gateway, DNS or domain.
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

// What: true unless a global identifier list lacks hw-address.
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
// Why: a repeated submit edits the device, never duplicates.
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

// What: create a subnet with the next free id.
// Why: ids only need to be unique; max plus one never clashes.
async fn add_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let (lease, cidr) = validate_subnet(&f).map_err(invalid)?;
    // What: resolve NTP names before the synchronous edit.
    // Why: the edit closure cannot await; a bad name is a 400.
    let ntp = resolve_ntp_servers(f.get("ntp_servers"))
        .await
        .map_err(invalid)?;
    kea_modify(&state, move |config| {
        let subnets = subnets_mut(config)?;
        let id = subnets
            .iter()
            .filter_map(|s| s["id"].as_u64())
            .max()
            .map_or(1, |max| max + 1) as u32;
        let mut entry = json!({});
        apply_subnet(&mut entry, &f, id, lease, &ntp, cidr)?;
        subnets.push(entry);
        Ok(())
    })
    .await?;
    Ok(Redirect::to("/dhcp"))
}

// What: edit one subnet in place, found by id.
// Why: custom options and fitting reservations carry over.
async fn update_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let id = f
        .number::<u32>("id")
        .ok_or_else(|| invalid("Missing subnet id."))?;
    let (lease, cidr) = validate_subnet(&f).map_err(invalid)?;
    let ntp = resolve_ntp_servers(f.get("ntp_servers"))
        .await
        .map_err(invalid)?;
    kea_modify(&state, move |config| {
        apply_subnet(find_subnet_mut(config, id)?, &f, id, lease, &ntp, cidr)
    })
    .await?;
    Ok(Redirect::to("/dhcp"))
}

// What: delete a subnet with its pools and reservations.
// Why: the last known-good snapshot is the way back.
async fn remove_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let id = f
        .number::<u32>("id")
        .ok_or_else(|| invalid("Missing subnet id."))?;
    kea_modify(&state, move |config| {
        subnets_mut(config)?.retain(|s| s["id"].as_u64() != Some(u64::from(id)));
        Ok(())
    })
    .await?;
    Ok(Redirect::to("/dhcp"))
}

// What: add or remove a custom option, matched by code+data.
// Why: both need the same parsing so the values compare equal.
async fn change_subnet_option(
    state: &AppState,
    f: Fields,
    add: bool,
) -> Result<Redirect, HtmlError> {
    require_kea(state)?;
    let wrong = |m: &str| invalid(format!("Invalid DHCP option: {m}"));
    let key = custom_option_key(f.get("code")).map_err(wrong)?;
    let data = custom_option_data(key, f.get("data")).map_err(wrong)?;
    let id = f
        .number::<u32>("subnet_id")
        .ok_or_else(|| invalid("Missing subnet id."))?;
    kea_modify(state, move |config| {
        edit_custom_option(find_subnet_mut(config, id)?, key, &data, add)
    })
    .await?;
    Ok(Redirect::to("/dhcp"))
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
    // Why: a blank hostname is a supported reservation state.
    if !hostname.is_empty() && !is_valid_domain_name(hostname) {
        return Err(invalid(
            "Invalid hostname: use a plain DNS domain name (letters, digits, '-', '.').",
        ));
    }
    let id = f
        .number::<u32>("subnet_id")
        .ok_or_else(|| invalid("Missing subnet id."))?;
    let (mac, ip, hostname) = (normalize_mac(mac), ip.to_string(), hostname.to_string());
    kea_modify(&state, move |config| {
        // What: refuse when Kea ignores hw-address reservations.
        // Why: a hand-edited global list would make this dead.
        if !identifiers_include_hw_address(config) {
            return Err(
                "cannot add a hw-address reservation: this Kea config's global \
                 Dhcp4.host-reservation-identifiers list does not include \
                 \"hw-address\", so Kea would never match it",
            );
        }
        upsert_reservation(find_subnet_mut(config, id)?, &mac, &ip, &hostname)
    })
    .await?;
    Ok(Redirect::to("/dhcp"))
}

// What: remove a static reservation by MAC; none is no error.
// Why: the end state, no reservation, is the same either way.
async fn remove_reservation(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    if !is_valid_mac(f.get("mac")) {
        return Err(invalid("Invalid MAC address."));
    }
    let id = f
        .number::<u32>("subnet_id")
        .ok_or_else(|| invalid("Missing subnet id."))?;
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
    .await?;
    Ok(Redirect::to("/dhcp"))
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
    .await?;
    Ok(Redirect::to("/dhcp"))
}

// What: roll Kea back to a chosen known-good snapshot.
// Why: only ids found on disk are accepted, never raw input.
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
    Ok(Redirect::to("/dhcp"))
}

// What: send a record delete event over NATS.
// Why: PowerDNS applies deletes from the same subject as adds.
async fn publish_delete(state: &AppState, zone: &str, name: &str, kind: &str) {
    let record = DnsRecord {
        action: "delete".into(),
        zone: zone.into(),
        name: name.into(),
        record_type: kind.into(),
        ttl: None,
        records: None,
    };
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
    // What: the forward record only for a hostname with a zone.
    // Why: a bare host name has no parent zone to delete from.
    if let Some(host) = hostname {
        let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
        if let Some((_, zone)) = host.split_once('.').filter(|(_, zone)| !zone.is_empty()) {
            publish_delete(state, zone, &format!("{host}."), "A").await;
        }
    }
    // What: the reverse record only inside a provisioned zone.
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
    // Why: lease4-del removes the record the name comes from.
    let hostname = kea_post(&state, "lease4-get", Some(&arguments))
        .await
        .ok()
        .and_then(|reply| {
            let name = reply
                .get(0)?
                .get("arguments")?
                .get("hostname")?
                .as_str()?
                .trim();
            (!name.is_empty()).then(|| name.to_string())
        });
    let reply = kea_post(&state, "lease4-del", Some(&arguments))
        .await
        .map_err(fail)?;
    match kea_code(&reply) {
        0 => {
            // What: clean DNS records after a successful release.
            // Why: best effort; the address is already freed.
            cleanup_lease_records(&state, address, hostname.as_deref()).await;
            Ok(Redirect::to("/dhcp"))
        }
        // What: code 3 means no such lease.
        // Why: an expired lease is a race, not a failure.
        3 => Err(dhcp_error(
            StatusCode::NOT_FOUND,
            format!(
                "No active lease found for {ip}; it may have already expired or been released."
            ),
        )),
        _ => Err(fail(kea_text(&reply))),
    }
}

// What: point every Kea subnet at the right NTP servers.
// Why: the NTP auto toggle owns that option while it is on.
// From: Issue #1079
async fn sync_subnet_ntp(state: &AppState, auto: bool) -> Result<(), String> {
    if !kea_available(state) {
        return Ok(());
    }
    // What: the LAN address when auto, else the DHCP default.
    // Why: turning auto off hands the option back to one value.
    let servers = if auto {
        state.config.standard_ip.clone()
    } else {
        resolve_ntp_servers(&state.config.setting("DHCP_NTP_SERVERS"))
            .await
            .unwrap_or_default()
    };
    kea_apply(state, move |config| {
        for subnet in subnets_mut(config)?.iter_mut() {
            set_subnet_ntp(subnet, &servers)?;
        }
        Ok(())
    })
    .await
}

// What: stop the containers a mode must not leave running.
// Why: runs before the save; a sub-mode switch restarts.
// From: Issue #1486
async fn stop_for_mode(
    state: &AppState,
    mode: DhcpMode,
    previous: DhcpMode,
) -> Result<(), HtmlError> {
    let mut stops = match mode {
        DhcpMode::Disabled => vec!["dhcp", "dhcp-proxy"],
        DhcpMode::Kea => vec!["dhcp-proxy"],
        DhcpMode::DnsmasqProxy | DhcpMode::DnsmasqRelay => vec!["dhcp"],
    };
    // What: stop dhcp-proxy for a proxy/relay sub-mode change.
    // Why: one container serves both; it must reread its mode.
    if mode.is_dnsmasq() && previous.is_dnsmasq() && previous != mode {
        stops.push("dhcp-proxy");
    }
    for service in stops {
        docker_stop_if_present(&state.docker, service)
            .await
            .map_err(|e| fail(format!("{e:#}")))?;
    }
    Ok(())
}

// What: start the container a mode needs; sync Kea NTP.
// Why: runs after the save so it reads the new mode.
async fn start_for_mode(state: &AppState, mode: DhcpMode) -> Result<(), HtmlError> {
    let (service, profile) = match mode {
        DhcpMode::Disabled => return Ok(()),
        DhcpMode::Kea => ("dhcp", "dhcp-kea"),
        DhcpMode::DnsmasqProxy | DhcpMode::DnsmasqRelay => ("dhcp-proxy", "dhcp-proxy"),
    };
    docker_start(&state.docker, service).await.map_err(|e| {
        // What: explain a container that was never created.
        // Why: the ui may start containers but never create them.
        if container_never_created(&e) {
            fail(format!(
                "The '{service}' container has not been created yet: this Compose stack was \
                 never started with the '{profile}' profile active, so Docker has no container \
                 for the Admin UI to start (it is only allowed to start/stop existing \
                 containers, never create new ones). Fix: in the lancache-ng install \
                 directory, run `docker compose --profile {profile} up -d {service}` once to \
                 create it, then switch DHCP mode again here. If a `lancache-converge.timer` is \
                 installed, it will also pick this up automatically within a few minutes after \
                 that."
            ))
        } else {
            fail(format!("{e:#}"))
        }
    })?;
    // What: push the NTP address into Kea right after the switch.
    // Why: best effort; Kea may still be starting up.
    if mode.is_kea()
        && state.config.flag("NTP_ENABLED")
        && state.config.flag("NTP_AUTO_DHCP")
        && let Err(e) = sync_subnet_ntp(state, true).await
    {
        tracing::warn!(error = %e, "failed to push the NTP address into Kea subnets; the next NTP or DHCP save retries");
    }
    Ok(())
}

// What: switch the stack between the DHCP backends.
// Why: stop, save, start in that order, with a way back.
async fn update_dhcp_mode(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    let raw = f.get("dhcp_mode").to_ascii_lowercase();
    if !["disabled", "kea", "dnsmasq-proxy", "dnsmasq-relay"].contains(&raw.as_str()) {
        return Err(dhcp_error(
            StatusCode::CONFLICT,
            "Invalid DHCP mode requested.",
        ));
    }
    let mode = DhcpMode::parse(&raw, false);
    let previous = state.config.dhcp_mode();

    // What: test the settings directory before any stop.
    // Why: a full or read-only volume must fail before any stop.
    let check = Path::new(&state.config.ui_settings_file).with_file_name(".dhcp-mode-write-check");
    write_file(&check, b"", 0o600, Place::Replace).map_err(|e| {
        fail(format!(
            "DHCP settings file {} is not writable: {e}",
            state.config.ui_settings_file
        ))
    })?;
    let _ = fs::remove_file(&check);

    stop_for_mode(&state, mode, previous).await?;
    if let Err(saved) = save_dhcp_settings(&state, &[("DHCP_MODE", mode.as_str().to_string())]) {
        // What: restart the previous mode after a failed save.
        // Why: the file still says previous; its start rereads it.
        if mode != previous
            && let Err(restarted) = start_for_mode(&state, previous).await
        {
            return Err(fail(format!(
                "Failed to persist DHCP mode ({}), and rolling the '{}' containers back to the \
                 previous '{}' mode also failed ({}). DHCP containers are now stopped but the \
                 UI may still report '{}' until this is resolved manually.",
                saved.message,
                mode.as_str(),
                previous.as_str(),
                restarted.message,
                previous.as_str()
            )));
        }
        return Err(saved);
    }
    start_for_mode(&state, mode).await?;
    Ok(Redirect::to("/dhcp"))
}

// What: parse "CODE:VALUE" lines into the stored form.
// Why: the file keeps one line; entries join with semicolons.
fn parse_custom_options(raw: &str) -> Result<String, String> {
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
        // What: refuse the four codes dnsmasq-proxy fields own.
        // Why: dnsmasq renders router, DNS, domain and NTP itself.
        let code = code
            .trim()
            .parse::<u16>()
            .map_err(|_| at("option code must be a number"))?;
        if code == 0 || code > 254 {
            return Err(at("option code must be between 1 and 254"));
        }
        if matches!(code, 3 | 6 | 15 | 42) {
            return Err(at(
                "option code is managed by dedicated dnsmasq-proxy fields",
            ));
        }
        let data = option_data(data).map_err(at)?;
        // What: refuse a semicolon inside option data.
        // Why: it is the entry separator on the shell side.
        if data.contains(';') {
            return Err(at(
                "option data must not contain ';' (used as the entry separator)",
            ));
        }
        entries.push(format!("{code}:{data}"));
    }
    Ok(entries.join(";"))
}

// What: validate and save the dnsmasq-proxy settings.
// Why: a typo should fail here, not when dnsmasq starts.
// From: Issue #450
async fn update_dhcp_proxy(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, HtmlError> {
    // What: an IPv4 address check and a list-of-addresses check.
    // Why: the optional-field table below takes plain functions.
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
    let required: [(&str, &str); 3] = [
        (
            "dhcp_subnet_start",
            "Invalid relay subnet start: must be an IPv4 address.",
        ),
        (
            "dhcp_dns_primary",
            "Invalid primary DNS: must be an IPv4 address.",
        ),
        (
            "upstream_dhcp_ip",
            "Invalid upstream DHCP server: must be an IPv4 address.",
        ),
    ];
    for (key, message) in required {
        if !address(f.get(key)) {
            return Err(invalid(message));
        }
    }
    // What: check optional fields only when they are filled.
    // Why: blank means no directive in dnsmasq.conf, no error.
    let optional: [(&str, &str, Check); 7] = [
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
    Ok(Redirect::to("/dhcp"))
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
        return Err(invalid(
            "Upstream DHCP server must be a valid IPv4 address.",
        ));
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
    Ok(Redirect::to("/dhcp"))
}
// What: DHCP client and server UDP ports (RFC 2131).
// Why: the probe binds the client port and talks to servers.
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_SERVER_PORT: u16 = 67;

// What: how long offers are collected after a DISCOVER.
// Why: every offering server counts, so the window runs out.
const DISCOVER_WINDOW: Duration = Duration::from_secs(5);

// What: how long the REQUEST waits for an ACK or NAK.
// Why: a server that just offered should answer at once.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

// What: DISCOVER sends within one window, spread evenly.
// Why: one dropped broadcast must not read as a clear LAN.
const DISCOVER_RETRANSMITS: u32 = 3;

// What: container wait limit for one probe run.
// Why: worst case is 8 s of probing; 30 s covers start-up.
const PROBE_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

// What: bytes of probe output kept on a timeout.
// Why: enough to diagnose, never an unbounded reason text.
const PROBE_LOG_TAIL_BYTES: usize = 2000;

// What: marker lines of the probe's output.
// Why: the parent drops older runs and finds the result line.
const PROBE_START_MARKER: &str = "__LANCACHE_DHCP_PROBE_START__";
const PROBE_RESULT_MARKER: &str = "__LANCACHE_DHCP_PROBE_RESULT_JSON__";

// What: option fields shown per offer, as (label, code).
// Why: None is the offered address; the rest are options.
const OFFER_FIELDS: [(&str, Option<OptionCode>); 10] = [
    ("Server Identifier", Some(OptionCode::ServerIdentifier)),
    ("IP Offered", None),
    (
        "IP Address Lease Time (seconds)",
        Some(OptionCode::AddressLeaseTime),
    ),
    ("Renewal Time (seconds)", Some(OptionCode::Renewal)),
    ("Rebinding Time (seconds)", Some(OptionCode::Rebinding)),
    ("Subnet Mask", Some(OptionCode::SubnetMask)),
    ("Router", Some(OptionCode::Router)),
    ("Domain Name Server", Some(OptionCode::DomainNameServer)),
    ("Domain Name", Some(OptionCode::DomainName)),
    ("Broadcast Address", Some(OptionCode::BroadcastAddr)),
];

// What: one label and value row of an offer or ACK.
// Why: servers differ in fields; the page lists what exists.
#[derive(Clone, Deserialize, Serialize)]
struct Detail {
    label: String,
    value: String,
}

// What: result of the rogue DHCP server check.
// Why: the status tag is the shape the page script reads.
#[derive(Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum ConflictCheck {
    Found {
        output: String,
        details: Vec<Detail>,
    },
    NotFound,
    Unavailable {
        reason: String,
    },
}

// What: result of the client dry run.
// Why: a failed run has no lease data, so no details.
#[derive(Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum ClientCheck {
    Passed {
        output: String,
        details: Vec<Detail>,
    },
    Failed {
        output: String,
    },
    Unavailable {
        reason: String,
    },
}

// What: both checks of one probe run.
// Why: the probe prints it as JSON, the ui reads it back.
#[derive(Deserialize, Serialize)]
struct ProbeReport {
    conflict: ConflictCheck,
    client: ClientCheck,
}

impl ProbeReport {
    // What: a report where neither check could run.
    // Why: both checks share the one reason they did not run.
    fn unavailable(reason: String) -> Self {
        Self {
            conflict: ConflictCheck::Unavailable {
                reason: reason.clone(),
            },
            client: ClientCheck::Unavailable { reason },
        }
    }

    // What: one status word for the whole report.
    // Why: severity order; a found server beats everything.
    fn overall(&self) -> &'static str {
        match (&self.conflict, &self.client) {
            (ConflictCheck::Found { .. }, _) => "conflict_found",
            (ConflictCheck::Unavailable { .. }, _) | (_, ClientCheck::Unavailable { .. }) => {
                "unavailable"
            }
            (_, ClientCheck::Failed { .. }) => "client_failed",
            (_, ClientCheck::Passed { .. }) => "verified",
        }
    }
}

// What: what the probe keeps of one OFFER or ACK.
// Why: REQUEST needs address and server; the page needs rows.
struct Offer {
    address: Option<Ipv4Addr>,
    server: Option<Ipv4Addr>,
    details: Vec<Detail>,
}

// What: read an OFFER or ACK into address, server, rows.
// Why: both message types carry the same option set.
fn read_offer(msg: &Message) -> Offer {
    let opts = msg.opts();
    let address = Some(msg.yiaddr()).filter(|a| !a.is_unspecified());
    let option_text = |code: OptionCode| -> Option<String> {
        Some(match opts.get(code)? {
            DhcpOption::ServerIdentifier(a)
            | DhcpOption::SubnetMask(a)
            | DhcpOption::BroadcastAddr(a) => a.to_string(),
            DhcpOption::AddressLeaseTime(s) | DhcpOption::Renewal(s) | DhcpOption::Rebinding(s) => {
                s.to_string()
            }
            DhcpOption::Router(list) => list.first()?.to_string(),
            DhcpOption::DomainNameServer(list) => list
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(", "),
            DhcpOption::DomainName(name) => name.clone(),
            _ => return None,
        })
    };
    let details = OFFER_FIELDS
        .iter()
        .filter_map(|(label, code)| {
            let value = match code {
                Some(code) => option_text(*code),
                None => address.map(|a| a.to_string()),
            }?;
            (!value.is_empty()).then(|| Detail {
                label: label.to_string(),
                value,
            })
        })
        .collect();
    let server = match opts.get(OptionCode::ServerIdentifier) {
        Some(DhcpOption::ServerIdentifier(a)) => Some(*a),
        _ => None,
    };
    Offer {
        address,
        server,
        details,
    }
}

// What: true when a message has the given DHCP type.
// Why: replies of other types on the segment are ignored.
fn is_kind(msg: &Message, kind: MessageType) -> bool {
    matches!(msg.opts().get(OptionCode::MessageType), Some(DhcpOption::MessageType(t)) if t == &kind)
}

// What: build a DHCP message of one type.
// Why: DISCOVER, REQUEST and RELEASE differ only in options.
fn dhcp_message(
    xid: u32,
    chaddr: &[u8; 6],
    ciaddr: Ipv4Addr,
    kind: MessageType,
    options: Vec<DhcpOption>,
) -> Message {
    let none = Ipv4Addr::UNSPECIFIED;
    let mut msg = Message::new_with_id(xid, ciaddr, none, none, none, chaddr);
    // What: set the broadcast flag on all but the RELEASE.
    // Why: the client holds no address, so replies must broadcast.
    if !matches!(kind, MessageType::Release) {
        msg.set_flags(Flags::default().set_broadcast());
    }
    msg.opts_mut().insert(DhcpOption::MessageType(kind));
    for option in options {
        msg.opts_mut().insert(option);
    }
    msg
}

// What: the options asked of every server.
// Why: exactly the fields the probe can show.
fn request_list() -> DhcpOption {
    DhcpOption::ParameterRequestList(
        OFFER_FIELDS
            .iter()
            .filter_map(|(_, code)| *code)
            .filter(|code| !matches!(code, OptionCode::ServerIdentifier))
            .collect(),
    )
}

// What: encode and send one message.
// Why: all probe traffic goes out through this one path.
fn send_dhcp(socket: &UdpSocket, msg: &Message, to: SocketAddrV4) -> io::Result<()> {
    let mut buffer = Vec::new();
    msg.encode(&mut Encoder::new(&mut buffer))
        .map_err(io::Error::other)?;
    socket.send_to(&buffer, to).map(|_| ())
}

// What: feed replies of one exchange to a handler.
// Why: stops at the deadline or when the handler says done.
fn listen(
    socket: &UdpSocket,
    xid: u32,
    until: Instant,
    mut handle: impl FnMut(&Message) -> bool,
) -> io::Result<()> {
    let mut buffer = [0u8; 1500];
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(());
        }
        socket.set_read_timeout(Some(left))?;
        match socket.recv_from(&mut buffer) {
            // What: skip datagrams that are not ours.
            // Why: other clients share the broadcast domain.
            Ok((n, _)) => {
                if let Ok(msg) = Message::decode(&mut Decoder::new(&buffer[..n]))
                    && msg.xid() == xid
                    && handle(&msg)
                {
                    return Ok(());
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(());
            }
            Err(e) => return Err(e),
        }
    }
}

// What: REQUEST the first offer, wait for the ACK, release.
// Why: proves a client can get a lease; the lease is returned.
fn dry_run(
    socket: &UdpSocket,
    xid: u32,
    chaddr: &[u8; 6],
    offer: &Offer,
    destination: SocketAddrV4,
) -> ClientCheck {
    let (Some(address), Some(server)) = (offer.address, offer.server) else {
        return ClientCheck::Failed {
            output: "the DHCPOFFER was missing a requested IP or server identifier, \
                     so no DHCPREQUEST could be built"
                .into(),
        };
    };
    let request = dhcp_message(
        xid,
        chaddr,
        Ipv4Addr::UNSPECIFIED,
        MessageType::Request,
        vec![
            DhcpOption::RequestedIpAddress(address),
            DhcpOption::ServerIdentifier(server),
            request_list(),
        ],
    );
    if let Err(e) = send_dhcp(socket, &request, destination) {
        return ClientCheck::Unavailable {
            reason: format!("failed to send DHCPREQUEST: {e}"),
        };
    }
    let mut verdict: Result<Offer, &str> = Err("no ACK received before the timeout");
    let heard = listen(socket, xid, Instant::now() + REQUEST_TIMEOUT, |msg| {
        if is_kind(msg, MessageType::Ack) {
            let ack = read_offer(msg);
            if ack.server == Some(server) {
                verdict = Ok(ack);
                return true;
            }
            verdict = Err("received an ACK, but not from the expected server identifier");
        } else if is_kind(msg, MessageType::Nak) {
            verdict = Err("server sent DHCPNAK for the requested address");
            return true;
        }
        false
    });
    if let Err(e) = heard {
        return ClientCheck::Unavailable {
            reason: format!("failed while waiting for DHCPACK: {e}"),
        };
    }
    let ack = match verdict {
        Ok(ack) => ack,
        Err(reason) => {
            return ClientCheck::Failed {
                output: reason.into(),
            };
        }
    };
    // What: return the leased address to the server's pool.
    // Why: best effort; the lease would expire on its own.
    if let Some(leased) = ack.address {
        let release = dhcp_message(
            rand::random(),
            chaddr,
            leased,
            MessageType::Release,
            vec![DhcpOption::ServerIdentifier(server)],
        );
        let _ = send_dhcp(
            socket,
            &release,
            SocketAddrV4::new(server, DHCP_SERVER_PORT),
        );
    }
    ClientCheck::Passed {
        output: match ack.address {
            Some(ip) => format!("DHCP client dry-run succeeded, assigned {ip}"),
            None => "DHCP client dry-run succeeded".into(),
        },
        details: ack.details,
    }
}

// What: one broadcast round answering both checks.
// Why: offers expose rogue servers; the first drives a dry run
fn run_probe() -> ProbeReport {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, DHCP_CLIENT_PORT)).and_then(|socket| {
        socket.set_broadcast(true)?;
        Ok(socket)
    });
    let socket = match socket {
        Ok(socket) => socket,
        Err(e) => {
            return ProbeReport::unavailable(format!(
                "could not open a DHCP broadcast socket: {e}"
            ));
        }
    };
    let destination = SocketAddrV4::new(Ipv4Addr::BROADCAST, DHCP_SERVER_PORT);
    // What: one transaction id for DISCOVER and REQUEST.
    // Why: a server only honours a REQUEST for its own offer.
    let xid: u32 = rand::random();
    // What: a random locally administered unicast MAC.
    // Why: the probe must not look like a real device.
    let mut chaddr: [u8; 6] = rand::random();
    chaddr[0] = (chaddr[0] | 0x02) & !0x01;

    let discover = dhcp_message(
        xid,
        &chaddr,
        Ipv4Addr::UNSPECIFIED,
        MessageType::Discover,
        vec![request_list()],
    );
    let end = Instant::now() + DISCOVER_WINDOW;
    let mut offers: Vec<Offer> = Vec::new();
    for attempt in 1..=DISCOVER_RETRANSMITS {
        if let Err(e) = send_dhcp(&socket, &discover, destination) {
            return ProbeReport::unavailable(format!("failed to broadcast DHCPDISCOVER: {e}"));
        }
        let slice = Instant::now() + DISCOVER_WINDOW / DISCOVER_RETRANSMITS;
        let until = if attempt == DISCOVER_RETRANSMITS {
            end
        } else {
            slice.min(end)
        };
        // What: a failed read ends this slice, not the probe.
        // Why: later retransmits may still collect offers.
        let _ = listen(&socket, xid, until, |msg| {
            if is_kind(msg, MessageType::Offer) {
                let offer = read_offer(msg);
                // What: count a server once across retransmits.
                // Why: answering twice is no second rogue server.
                let seen = offers
                    .iter()
                    .any(|o| o.server.is_some() && o.server == offer.server);
                if !seen {
                    offers.push(offer);
                }
            }
            false
        });
    }

    let conflict = match offers.first() {
        None => ConflictCheck::NotFound,
        Some(first) => ConflictCheck::Found {
            output: first
                .server
                .map_or_else(|| "unknown".to_string(), |ip| ip.to_string()),
            details: offers.iter().flat_map(|o| o.details.clone()).collect(),
        },
    };
    let client = match offers.first() {
        None => ClientCheck::Failed {
            output: format!(
                "no DHCPOFFER received within {:.0}s",
                DISCOVER_WINDOW.as_secs_f64()
            ),
        },
        Some(first) => dry_run(&socket, xid, &chaddr, first, destination),
    };
    ProbeReport { conflict, client }
}

// What: the probe container's whole job: print the result.
// Why: every outcome exits 0; the update gate needs that.
// From: Issue #1288
fn print_probe_report() {
    let report = run_probe();
    println!("{PROBE_START_MARKER}");
    // What: an empty line if serializing ever failed.
    // Why: the ui then reports a malformed result, not a hang.
    let json = serde_json::to_string(&report).unwrap_or_default();
    println!("{PROBE_RESULT_MARKER} {json}");
}

// What: the last bytes of a text, cut at a char boundary.
// Why: a byte slice mid-character would panic the diagnosis.
fn tail_bytes(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.len() <= max {
        return text.to_string();
    }
    let start = (text.len() - max..=text.len())
        .find(|i| text.is_char_boundary(*i))
        .unwrap_or(text.len());
    format!("...(truncated)... {}", text[start..].trim())
}

// What: the output of the newest run in a log text.
// Why: Docker's since filter is coarse; old runs can leak in.
fn current_run(logs: &str) -> &str {
    logs.rsplit_once(PROBE_START_MARKER)
        .map_or(logs, |(_, current)| current)
}

// What: run the probe container once; return its output.
// Why: the proxy only allows start, wait and logs.
async fn run_dhcp_probe(docker: &DockerProxy) -> Result<String, String> {
    let failed = |e: anyhow::Error| format!("Failed to execute DHCP check: {e:#}");
    let container = container_name("dhcp-probe").map_err(failed)?;
    docker_stop_if_present(docker, "dhcp-probe")
        .await
        .map_err(failed)?;
    // What: remember the start second for the log filter.
    // Why: the logs call must not read the previous run.
    let since = unix_secs();
    docker_start(docker, "dhcp-probe").await.map_err(failed)?;

    let begun = Instant::now();
    let exit_code = match docker.wait(container, Some(PROBE_WAIT_TIMEOUT)).await {
        Ok(code) => code,
        // What: keep the output and stop a container that hangs.
        // Why: a bare timeout must say what the probe was doing.
        Err(DockerError::Timeout) => {
            let tail = match docker.logs(container, since, Some(DOCKER_TIMEOUT)).await {
                Ok(logs) => match tail_bytes(current_run(&logs), PROBE_LOG_TAIL_BYTES) {
                    tail if tail.is_empty() => {
                        "(none -- the container produced no output before the timeout)".to_string()
                    }
                    tail => tail,
                },
                Err(e) => format!("(failed to capture probe container logs: {e})"),
            };
            let stopped = match docker_stop_if_present(docker, "dhcp-probe").await {
                Ok(()) => "the presumed-stuck container was stopped".to_string(),
                Err(e) => format!("stopping the presumed-stuck container also failed: {e:#}"),
            };
            return Err(format!(
                "DHCP probe timed out after {:.0}s with no result from the container ({stopped}). \
                 Captured probe output up to the timeout: {tail}",
                begun.elapsed().as_secs_f64()
            ));
        }
        Err(e) => {
            return Err(format!(
                "Failed to execute DHCP check: read DHCP probe wait response: {e}"
            ));
        }
    };
    let logs = docker
        .logs(container, since, Some(DOCKER_TIMEOUT))
        .await
        .map_err(|e| format!("Failed to execute DHCP check: read DHCP probe logs: {e}"))?;
    let output = current_run(&logs).to_string();
    if exit_code != 0 {
        return Err(format!(
            "DHCP probe container exited with code {exit_code}: {}",
            output.trim()
        ));
    }
    Ok(output)
}

// What: run one probe and read its JSON result line.
// Why: the last result line wins over any stale one.
async fn check_dhcp_probe(state: &AppState) -> ProbeReport {
    // What: serialize probe runs on the one container.
    // Why: concurrent runs would restart it under each other.
    let _guard = state.dhcp_probe_lock.lock().await;
    let output = match run_dhcp_probe(&state.docker).await {
        Ok(output) => output,
        Err(reason) => return ProbeReport::unavailable(reason),
    };
    let Some(json) = output
        .lines()
        .rev()
        .find_map(|line| line.trim().strip_prefix(PROBE_RESULT_MARKER).map(str::trim))
    else {
        return ProbeReport::unavailable("dhcp-probe produced no JSON result line".into());
    };
    serde_json::from_str(json)
        .unwrap_or_else(|e| ProbeReport::unavailable(format!("malformed dhcp-probe result: {e}")))
}

// What: run the DHCP conflict check; POST because it acts.
// Why: starting a container is no safe GET; CSRF covers POST.
// From: Issue #947
async fn check_dhcp_conflict(State(state): Shared) -> Json<Value> {
    let report = check_dhcp_probe(&state).await;
    Json(json!({
        "status": report.overall(),
        "conflict": report.conflict,
        "client": report.client,
    }))
}
// What: TTL limits for operator records, in seconds.
// Why: 2^31-1 is the RFC 2181 ceiling; above it reads as 0.
const MAX_TTL: u32 = 2_147_483_647;

// What: longest TXT content the ui accepts, in bytes.
// Why: a DNS message is 65535 bytes less 549 for framing.
const MAX_TXT_BYTES: usize = 64_986;

// What: the line that splits shipped from added entries.
// Why: shipped defaults can toggle; added entries can remove.
// From: Issue #1073
const CUSTOM_DOMAINS_MARKER: &str =
    "# ==== lancache-ng: entries added via the Admin UI are appended below this exact line ====";

// What: one CDN list entry; wildcard_only drops the root.
// Why: root and wildcard-only lines are independent entries.
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
// Why: a URL parameter must never become arbitrary page text.
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

// What: DNS name syntax without a trailing dot.
// Why: one rule for CDN, DHCP and LAN names; flags widen it.
fn is_dns_name(name: &str, underscore: bool, wildcard: bool) -> bool {
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
// Why: two labels at least; a leading dot means wildcard-only.
fn parse_cdn_domain(text: &str) -> Option<CdnDomain> {
    let lower = text.trim().to_lowercase();
    let (wildcard_only, domain) = match lower.strip_prefix('.') {
        Some(rest) => (true, rest),
        None => (false, lower.as_str()),
    };
    (domain.contains('.') && is_valid_domain_name(domain)).then(|| CdnDomain {
        wildcard_only,
        domain: domain.to_string(),
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
// Why: the inverse of stored_line; the proxy reads this file.
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

// What: the list rows of a file, defaults before the marker.
// Why: no marker means an old file; all entries are defaults.
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

// What: the text with one entry switched; None if unchanged.
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
    // What: add the marker once before the first added entry.
    // Why: old files get split into defaults and added entries.
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
// Why: additions are strict; removal also cleans legacy lines.
fn delete_target(text: &str) -> Option<DeleteTarget> {
    let text = text.trim();
    if let Some(domain) = parse_cdn_domain(text) {
        return Some(DeleteTarget::Domain(domain));
    }
    (!text.is_empty() && !text.starts_with('#') && !text.chars().any(char::is_control))
        .then(|| DeleteTarget::Raw(text.to_string()))
}

// What: the text without matching lines; None if none match.
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
    let _guard = state.file_lock.lock().unwrap_or_else(|e| e.into_inner());
    let path = Path::new(&state.config.cdn_domains_file);
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(e) if create && e.kind() == io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e.into()),
    };
    if let Some(text) = change(&content) {
        // What: keep the file's current permissions.
        // Why: the proxy and dns containers read it as other users.
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
// Why: zone, type and content let a node confirm AXFR first.
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
    // What: ignore a failed flush; entries expire anyway.
    // Why: the record change itself already happened.
    let _ = state.pdns.call(reqwest::Method::PUT, &url, None).await;
    let request = FlushRequest { domain, ..request };
    if let Ok(payload) = serde_json::to_vec(&request) {
        let _ = state.nats.publish(NATS_SUBJECT_FLUSH, payload.into()).await;
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

// What: restart the SSL proxy.
// Why: it reads the domain list only at start.
async fn restart_ssl(state: &AppState) {
    if let Err(e) = docker_restart(&state.docker, &state.config.proxy_ssl_service).await {
        tracing::error!("Restart proxy service failed: {e:#}");
    }
}

// What: a LAN record name as a dotted FQDN in zone lan.
// Why: the bare name "lan" is the zone root, not lan.lan.
fn normalize_lan_name(name: &str) -> String {
    let name = name.trim().to_lowercase();
    if name.ends_with('.') {
        name
    } else if name == LAN_ZONE || name.ends_with(&format!(".{LAN_ZONE}")) {
        format!("{name}.")
    } else {
        format!("{name}.{LAN_ZONE}.")
    }
}

// What: true for an FQDN inside the lan zone.
// Why: the ui may only touch records of its own zone.
fn is_lan_name(name: &str, underscore: bool) -> bool {
    let zone = canonical_zone(LAN_ZONE);
    is_fqdn(name, underscore, true) && (name == zone || name.ends_with(&format!(".{zone}")))
}

// What: type and content of a valid LAN record, or None.
// Why: each record type has its own content syntax.
fn validate_lan_record(
    name: &str,
    record_type: &str,
    content: &str,
    ttl: u32,
) -> Option<(&'static str, String)> {
    if !(1..=MAX_TTL).contains(&ttl) {
        return None;
    }
    let kind = match record_type.trim().to_ascii_uppercase().as_str() {
        "A" => "A",
        "AAAA" => "AAAA",
        "CNAME" => "CNAME",
        "MX" => "MX",
        "TXT" => "TXT",
        _ => return None,
    };
    if !is_lan_name(name, kind == "TXT") {
        return None;
    }
    let content = content.trim();
    let valid = match kind {
        "A" => content.parse::<Ipv4Addr>().is_ok(),
        "AAAA" => content.parse::<Ipv6Addr>().is_ok(),
        "CNAME" => is_fqdn(&normalize_lan_name(content), false, true),
        "MX" => {
            let mut parts = content.split_whitespace();
            matches!(
                (parts.next(), parts.next(), parts.next()),
                (Some(priority), Some(exchange), None)
                    if priority.parse::<u16>().is_ok()
                        && is_fqdn(&normalize_lan_name(exchange), false, true)
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
// Why: any type may be removed, so only its shape is checked.
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
    let zones = rollback_zones()
        .into_iter()
        .filter(|zone| zone.ends_with(".in-addr.arpa."));
    let per_zone = futures_util::future::join_all(zones.map(|zone| async move {
        let rrsets = state
            .pdns
            .zone_rrsets(&state.config.pdns_auth_api, &zone)
            .await;
        ptr_rows(&rrsets.unwrap_or_default())
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
// Why: an unreachable listener shows none, not a broken page.
async fn fetch_zone_groups(state: &AppState) -> Vec<ZoneSnapshotGroup> {
    let response = state
        .http_client
        .get(format!("{}/snapshots", state.config.dns_rollback_url))
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await;
    let Ok(response) = response.and_then(reqwest::Response::error_for_status) else {
        return Vec::new();
    };
    let Ok(body) = response.json::<Value>().await else {
        return Vec::new();
    };
    let Some(zones) = body.get("zones").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut groups: Vec<ZoneSnapshotGroup> = zones
        .iter()
        .map(|(zone, list)| ZoneSnapshotGroup {
            zone: zone.clone(),
            // What: skip entries without an id.
            // Why: an older listener degrades to fewer rows.
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
            // What: log a degraded rollback; the page still succeeds.
            // Why: no inline channel exists for a partial failure.
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
            "/domains"
        }
        // What: a refusal is known; a lost request is not.
        // Why: an unknown outcome must not invite a blind retry.
        Ok(response) => {
            tracing::error!(status = %response.status(), zone, snapshot_id, "zone rollback rejected by nats-subscriber");
            "/domains?error=zone_rollback_failed"
        }
        Err(e) => {
            tracing::error!(error = %e, zone, snapshot_id, "zone rollback request failed to reach nats-subscriber");
            "/domains?error=zone_rollback_unknown"
        }
    };
    Redirect::to(target)
}

// What: the domains page with lists, records and snapshots.
// Why: the three remote reads run at the same time.
async fn domains_page(
    State(state): Shared,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let cfg = &state.config;
    let rows = domain_rows(&fs::read_to_string(&cfg.cdn_domains_file).unwrap_or_default());
    let (lan, ptr, groups) = tokio::join!(
        async {
            state
                .pdns
                .zone_rrsets(&state.config.pdns_auth_api, LAN_ZONE)
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
    let marker_set = |file: &str| {
        [&cfg.dns_standard_state_dir, &cfg.dns_ssl_state_dir]
            .iter()
            .any(|dir| Path::new(dir).join(file).exists())
    };
    let mut ctx = page_ctx(&headers, "domains");
    ctx.insert("dns_domains", &rows);
    ctx.insert("lan_records", &lan);
    ctx.insert("ptr_records", &ptr);
    ctx.insert("aaaa_filter_enabled", &marker_set("aaaa-filter-enabled"));
    ctx.insert(
        "ddns_unsigned_updates_allowed",
        &marker_set("ddns-allow-unsigned-updates"),
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
// Why: the dns side writes it; an empty file does not count.
// From: Issue #858
fn tsig_key_configured(config: &Config) -> bool {
    fs::metadata(Path::new(&config.shared_secret_dir).join("ddns-tsig-key"))
        .is_ok_and(|m| m.len() > 0)
}

// What: write a failed list edit to the log as a 500.
// Why: the file write is the mutation; failure is no success.
fn write_failed(action: &str, e: anyhow::Error) -> StatusCode {
    tracing::error!("Failed to {action} dns domain: {e:#}");
    StatusCode::INTERNAL_SERVER_ERROR
}

// What: flush DNS and restart the SSL proxy after a change.
// Why: the proxy derives certificates from the list at start.
async fn after_domain_change(state: &AppState, domain: &str) {
    flush_recursor_cache(state, flush_name(domain)).await;
    if state.config.ssl_enabled {
        restart_ssl(state).await;
    }
}

// What: add a CDN domain, or re-enable a disabled one.
// Why: a bad entry returns to the page with a banner.
async fn add_dns(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, StatusCode> {
    let Some(entry) = parse_cdn_domain(f.get("domain")) else {
        tracing::warn!(domain = %f.get("domain"), "Rejected invalid dns domain");
        return Ok(Redirect::to("/domains?error=invalid_domain"));
    };
    edit_domains(&state, true, |text| with_added(text, &entry))
        .map_err(|e| write_failed("write", e))?;
    after_domain_change(&state, &entry.domain).await;
    Ok(Redirect::to("/domains"))
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
    Ok(Redirect::to("/domains"))
}

// What: switch a shipped default entry on or off.
// Why: it flips the ! marker only; it never adds or deletes.
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
    Ok(Redirect::to("/domains"))
}

// What: add or replace a LAN record through NATS.
// Why: the subscriber writes it on every DNS node.
async fn add_lan_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let name = normalize_lan_name(f.get("name"));
    let ttl = f.number::<u32>("ttl").unwrap_or(300);
    let Some((kind, content)) =
        validate_lan_record(&name, f.get("record_type"), f.get("content"), ttl)
    else {
        tracing::warn!(name = %f.get("name"), record_type = %f.get("record_type"), "Rejected invalid LAN record");
        return Redirect::to("/domains");
    };
    let record = DnsRecord {
        action: "replace".into(),
        zone: LAN_ZONE.into(),
        name: name.clone(),
        record_type: kind.into(),
        ttl: Some(ttl as i32),
        records: Some(vec![HashMap::from([
            ("content".to_string(), json!(content)),
            ("disabled".to_string(), json!(false)),
        ])]),
    };
    if let Err(e) = publish_record(&state, &record).await {
        tracing::error!("NATS publish failed: {e}");
    }
    let request = FlushRequest {
        zone: Some(LAN_ZONE.into()),
        record_type: Some(kind.into()),
        expected_content: Some(vec![content]),
        expected_ttl: Some(ttl as i32),
        ..flush_name(&name)
    };
    flush_recursor_cache(&state, request).await;
    Redirect::to("/domains")
}

// What: delete a LAN record set through NATS.
// Why: any type may be deleted; the name must be in zone lan.
async fn remove_lan_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let name = normalize_lan_name(f.get("name"));
    let (Some(kind), true) = (
        delete_record_type(f.get("record_type")),
        is_lan_name(&name, true),
    ) else {
        tracing::warn!(name = %f.get("name"), record_type = %f.get("record_type"), "Rejected invalid LAN record delete");
        return Redirect::to("/domains");
    };
    let record = DnsRecord {
        action: "delete".into(),
        zone: LAN_ZONE.into(),
        name: name.clone(),
        record_type: kind.clone(),
        ttl: None,
        records: None,
    };
    if let Err(e) = publish_record(&state, &record).await {
        tracing::error!("NATS publish failed: {e}");
    }
    let request = FlushRequest {
        zone: Some(LAN_ZONE.into()),
        record_type: Some(kind),
        ..flush_name(&name)
    };
    flush_recursor_cache(&state, request).await;
    Redirect::to("/domains")
}

// What: set or clear a marker file in both DNS state dirs.
// Why: the dns containers read the marker's existence.
fn set_markers(state: &AppState, file: &str, enabled: bool) -> Result<(), StatusCode> {
    let mut failed = false;
    for dir in [
        &state.config.dns_standard_state_dir,
        &state.config.dns_ssl_state_dir,
    ] {
        let path = Path::new(dir).join(file);
        let result = if enabled {
            write_file(&path, b"1", 0o644, Place::Replace)
        } else {
            match fs::remove_file(&path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                other => other,
            }
        };
        if let Err(e) = result {
            tracing::error!(path = %path.display(), enabled, error = %e, "{file} toggle failed");
            failed = true;
        }
    }
    // What: report failure if either DNS instance lacks the state.
    // Why: the page must not claim a state one node cannot see.
    if failed {
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    Ok(())
}

// What: turn the AAAA filter marker on or off.
// Why: every DNS instance must see the requested state.
async fn toggle_aaaa_filter(
    State(state): Shared,
    Form(f): Form<Fields>,
) -> Result<Redirect, StatusCode> {
    set_markers(&state, "aaaa-filter-enabled", f.get("enabled") == "1")?;
    Ok(Redirect::to("/domains"))
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
        return Ok(Redirect::to("/domains?error=ddns_allow_unsigned_no_key"));
    }
    set_markers(&state, "ddns-allow-unsigned-updates", enable)?;
    // What: restart both DNS services after a marker change.
    // Why: without it the click waits for the next restart.
    for service in [
        &state.config.dns_standard_service,
        &state.config.dns_ssl_service,
    ] {
        if let Err(e) = docker_restart(&state.docker, service).await {
            tracing::error!(
                "Restart {service} for ddns-allow-unsigned-updates toggle failed: {e:#}"
            );
        }
    }
    Ok(Redirect::to("/domains"))
}

// What: set a manual PTR record in the reverse zone.
// Why: the flush follows only an accepted write.
async fn add_ptr_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let ttl = f.number::<u32>("ttl").unwrap_or(300);
    let (Some((zone, name)), Some(target), true) = (
        ptr_location(f.get("ip")),
        normalize_ptr_target(f.get("hostname")),
        (1..=MAX_TTL).contains(&ttl),
    ) else {
        tracing::warn!(ip = %f.get("ip"), hostname = %f.get("hostname"), "Rejected invalid PTR record");
        return Redirect::to("/domains");
    };
    let body = json!({"rrsets": [{
        "name": name, "type": "PTR", "ttl": ttl, "changetype": "REPLACE",
        "records": [{"content": target, "disabled": false}]
    }]});
    if patch_reverse_zone(&state, &zone, body).await {
        let request = FlushRequest {
            zone: Some(zone),
            record_type: Some("PTR".into()),
            expected_content: Some(vec![target]),
            expected_ttl: Some(ttl as i32),
            ..flush_name(&name)
        };
        flush_recursor_cache(&state, request).await;
    } else {
        tracing::error!(ip = %f.get("ip"), "PowerDNS rejected PTR add");
    }
    Redirect::to("/domains")
}

// What: delete the PTR record set of an address.
// Why: the key is the address; no other field is needed.
async fn remove_ptr_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let Some((zone, name)) = ptr_location(f.get("ip")) else {
        tracing::warn!(ip = %f.get("ip"), "Rejected invalid PTR delete");
        return Redirect::to("/domains");
    };
    let body = json!({"rrsets": [{"name": name, "type": "PTR", "changetype": "DELETE"}]});
    if patch_reverse_zone(&state, &zone, body).await {
        let request = FlushRequest {
            zone: Some(zone),
            record_type: Some("PTR".into()),
            ..flush_name(&name)
        };
        flush_recursor_cache(&state, request).await;
    } else {
        tracing::error!(ip = %f.get("ip"), "PowerDNS rejected PTR delete");
    }
    Redirect::to("/domains")
}

// What: log lines the recent-activity widget shows.
// Why: a short list keeps the page cheap to render.
const RECENT_LOGS: usize = 10;

// What: run a blocking job off the async workers.
// Why: du and log reads must not stall other requests.
async fn blocking<T: Default + Send + 'static>(
    state: &Arc<AppState>,
    job: impl FnOnce(&AppState) -> T + Send + 'static,
) -> T {
    let state = state.clone();
    tokio::task::spawn_blocking(move || job(&state))
        .await
        .unwrap_or_default()
}

// What: nginx counters of the standard and ssl proxy.
// Why: an ssl proxy sharing the standard URL is read once.
async fn proxy_statuses(state: &AppState) -> (Option<NginxStatus>, Option<NginxStatus>) {
    let cfg = &state.config;
    let distinct = cfg.ssl_enabled && cfg.proxy_standard_url != cfg.proxy_ssl_url;
    let (standard, ssl) = tokio::join!(
        nginx_status(&state.http_client, &cfg.proxy_standard_url),
        async {
            if distinct {
                nginx_status(&state.http_client, &cfg.proxy_ssl_url).await
            } else {
                None
            }
        }
    );
    let ssl = match (cfg.ssl_enabled, distinct) {
        (false, _) => None,
        (true, true) => ssl,
        (true, false) => standard.clone(),
    };
    (standard, ssl)
}

// What: the dashboard page.
// Why: all collectors start at once; latency is the slowest.
async fn dashboard(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let (proxy, cache_used_gb, stats, recent, syslog_gb, syslog, alarms) = tokio::join!(
        proxy_statuses(&state),
        blocking(&state, |s| du_gb(&s.config.cache_dir)),
        blocking(&state, |s| log_stats(
            &s.config.standard_log,
            &s.config.ssl_log
        )),
        blocking(&state, |s| {
            merged_log_tail(&s.config.standard_log, &s.config.ssl_log, RECENT_LOGS)
        }),
        blocking(&state, |s| {
            if s.config.syslog_enabled {
                du_gb(&s.config.syslog_log_root)
            } else {
                0.0
            }
        }),
        blocking(&state, |s| {
            if s.config.syslog_enabled {
                syslog_stats(&s.config.syslog_log_root)
            } else {
                SyslogStats::default()
            }
        }),
        blocking(&state, |s| read_alarms(&s.config.netdata_alarms_file)),
    );
    // What: the cache bar follows the running size.
    // Why: a pending resize must not look like an applied one.
    let requested_gb = cfg.requested_cache_gb();
    let percent = if cfg.cache_max_gb > 0.0 {
        (cache_used_gb / cfg.cache_max_gb * 100.0).min(100.0) as u64
    } else {
        0
    };
    let mode = cfg.dhcp_mode();
    let mut ctx = page_ctx(&headers, "dashboard");
    ctx.insert("ssl_enabled", &cfg.ssl_enabled);
    ctx.insert("dhcp_mode", mode.as_str());
    ctx.insert("dhcp_mode_has_kea", &mode.is_kea());
    ctx.insert("standard_status", &proxy.0);
    ctx.insert("ssl_status", &proxy.1);
    ctx.insert("cache_dir", &cfg.cache_dir);
    ctx.insert("cache_used_gb", &format!("{cache_used_gb:.1}"));
    ctx.insert("cache_max_gb", &cfg.cache_max_gb);
    ctx.insert("cache_pct", &percent);
    ctx.insert(
        "cache_resize_pending",
        &((requested_gb - cfg.cache_max_gb).abs() >= 1.0),
    );
    ctx.insert("effective_cache_max_gb", &format!("{requested_gb:.0}"));
    ctx.insert("log_stats", &stats);
    ctx.insert("recent_logs", &recent);
    ctx.insert("syslog_enabled", &cfg.syslog_enabled);
    ctx.insert("syslog_size_gb", &format!("{syslog_gb:.1}"));
    ctx.insert("syslog_max_gb", &cfg.syslog_max_gb);
    ctx.insert("syslog_stats", &syslog);
    ctx.insert("watchdog_status", &watchdog_json(&cfg.watchdog_status_file));
    ctx.insert("netdata_alarms", &alarm_views(&alarms));
    render(&state, "dashboard.html", &ctx)
}

// What: the connection counters alone, as JSON.
// Why: the dashboard polls this without the costly collectors.
async fn metrics_api(State(state): Shared) -> Json<Value> {
    let (standard, ssl) = proxy_statuses(&state).await;
    Json(json!({
        "standard": standard,
        "ssl_enabled": state.config.ssl_enabled,
        "ssl": ssl,
    }))
}

// What: the watchdog document as JSON.
// Why: the dashboard polls the health lights from here.
// From: Issue #870
async fn watchdog_status_api(State(state): Shared) -> Json<Value> {
    Json(watchdog_json(&state.config.watchdog_status_file))
}

// What: the statistics page.
// Why: its charts load their data from the netdata proxy.
async fn stats_page(State(state): Shared, headers: HeaderMap) -> Response {
    render(&state, "stats.html", &page_ctx(&headers, "stats"))
}

// What: the log page, from syslog-ng or the nginx logs.
// Why: syslog-ng, once enabled, holds the more complete view.
// From: Issue #633
async fn logs_page(
    State(state): Shared,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let max = state.config.ui_logs_max_entries;
    let mut ctx = page_ctx(&headers, "logs");
    if state.config.syslog_enabled {
        let requested = params.get("host").cloned().unwrap_or_default();
        let (mut entries, hosts, selected) = blocking(&state, move |s| {
            let root = &s.config.syslog_log_root;
            let hosts = syslog_hosts(root);
            // What: honour only a host that really has a directory.
            // Why: the query value is caller-controlled input.
            let selected = Some(requested).filter(|h| hosts.contains(h));
            let entries = syslog_tail(root, selected.as_deref(), max);
            (entries, hosts, selected)
        })
        .await;
        entries.reverse();
        ctx.insert("syslog_mode", &true);
        ctx.insert("syslog_logs", &entries);
        ctx.insert("syslog_hosts", &hosts);
        ctx.insert("selected_host", &selected);
        // What: an empty nginx list in syslog mode.
        // Why: Tera fails on a variable the template reads.
        ctx.insert("logs", &Vec::<LogEntry>::new());
        return render(&state, "logs.html", &ctx);
    }
    let mut entries = blocking(&state, move |s| {
        merged_log_tail(&s.config.standard_log, &s.config.ssl_log, max)
    })
    .await;
    entries.reverse();
    if let Some(wanted) = params.get("filter") {
        entries.retain(|entry| &entry.cache_status == wanted);
    }
    ctx.insert("syslog_mode", &false);
    ctx.insert("logs", &entries);
    render(&state, "logs.html", &ctx)
}

// What: the refusal text for a cache size that does not fit.
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
// Why: only the host's converge run can apply it to the proxy.
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
    Ok(Redirect::to("/"))
}

// What: the NTP settings page.
// Why: shows the saved values, not the startup ones.
async fn ntp_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "ntp");
    ctx.insert("ntp_enabled", &cfg.flag("NTP_ENABLED"));
    ctx.insert("ntp_upstream_servers", &cfg.setting("NTP_UPSTREAM_SERVERS"));
    ctx.insert("ntp_auto_dhcp", &cfg.flag("NTP_AUTO_DHCP"));
    ctx.insert("standard_ip", &cfg.standard_ip);
    ctx.insert("dhcp_has_kea", &cfg.dhcp_mode().is_kea());
    render(&state, "ntp.html", &ctx)
}

// What: normalize the upstream NTP list to space separators.
// Why: entrypoint.sh must get at least one valid server.
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
    // Why: chrony takes them although the Kea side is IPv4 only.
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
// Why: the container reads its settings only at start.
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
    // What: keep the saved auto flag outside Kea mode.
    // Why: the browser never submits the disabled checkbox.
    let auto = if cfg.dhcp_mode().is_kea() {
        !f.get("ntp_auto_dhcp").is_empty()
    } else {
        cfg.flag("NTP_AUTO_DHCP")
    };
    let was_enabled = cfg.flag("NTP_ENABLED");
    let was_auto = was_enabled && cfg.flag("NTP_AUTO_DHCP");

    // What: stop NTP before the save when it is or was running.
    // Why: a restart before the save would reread the old list.
    if !enabled || was_enabled {
        docker_stop_if_present(&state.docker, "ntp")
            .await
            .map_err(|e| fail(format!("{e:#}")))?;
    }
    let saved = cfg.save_settings(&[
        ("NTP_ENABLED", bool_text(enabled)),
        ("NTP_UPSTREAM_SERVERS", servers),
        ("NTP_AUTO_DHCP", bool_text(auto)),
    ]);
    if let Err(save_err) = saved {
        // What: restart NTP if it was running before the failure.
        // Why: a failed save must not leave NTP stopped silently.
        // From: PR #1610
        if was_enabled && let Err(start_err) = docker_start(&state.docker, "ntp").await {
            return Err(fail(format!(
                "Failed to persist NTP settings ({save_err}), and restarting NTP after that \
                 failure also failed ({start_err:#}). NTP is now stopped and needs manual recovery."
            )));
        }
        return Err(fail(save_err.to_string()));
    }
    if enabled {
        docker_start(&state.docker, "ntp")
            .await
            .map_err(|e| fail(format!("{e:#}")))?;
    }
    // What: touch Kea's NTP option only when auto changes state.
    // Why: a save that leaves auto alone keeps per-subnet edits.
    if enabled && auto {
        sync_subnet_ntp(&state, true).await.map_err(fail)?;
    } else if was_auto {
        sync_subnet_ntp(&state, false).await.map_err(fail)?;
    }
    Ok(Redirect::to("/ntp"))
}

// What: the setup page with network hints and update settings.
// Why: operators copy the client settings from here.
async fn setup_page(State(state): Shared, headers: HeaderMap) -> Response {
    let cfg = &state.config;
    let mut ctx = page_ctx(&headers, "setup");
    ctx.insert("standard_ip", &cfg.standard_ip);
    ctx.insert("ssl_ip", &cfg.ssl_ip);
    ctx.insert(
        "lancache_image_channel",
        &cfg.setting("LANCACHE_IMAGE_CHANNEL"),
    );
    ctx.insert("auto_update_enabled", &cfg.flag("AUTO_UPDATE_ENABLED"));
    render(&state, "setup.html", &ctx)
}

// What: true for a channel an operator may pick.
// Why: pinned tags and the retired edge name are not choices.
// From: Issue #819
fn is_valid_ui_channel(value: &str) -> bool {
    matches!(value, "stable" | "nightly")
}

// What: save the release channel and the auto-update flag.
// Why: the host's converge run applies both; no Docker needed.
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
    Ok(Redirect::to("/setup"))
}

// What: the page shown while the ui restarts itself.
// Why: a redirect cannot work; this process is about to end.
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
  fetch('/health', { cache: 'no-store' }).then(function (res) {
    if (res.ok && sawDown) { window.location.href = '/setup'; return; }
    sawDown = sawDown || !res.ok;
    setTimeout(pollHealth, 1000);
  }).catch(function () { sawDown = true; setTimeout(pollHealth, 1000); });
}
setTimeout(pollHealth, 1500);
</script></body></html>
"##;

// What: answer with the wait page, then restart the ui.
// Why: the restart ends this process, so it runs out of line.
// From: Issue #1486
async fn restart_ui_service(State(state): Shared) -> Html<&'static str> {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(750)).await;
        if let Err(e) = docker_restart(&state.docker, "ui").await {
            tracing::error!("operator-requested Admin UI self-restart failed: {e:#}");
        }
    });
    Html(RESTART_UI_PAGE)
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
    // Why: two toggles at once must not drop each other's key.
    let _guard = state.file_lock.lock().unwrap_or_else(|e| e.into_inner());
    let mut desired = DesiredState::read(path);
    if service == "dhcp" {
        desired.dhcp = Some(run_state);
    } else {
        desired.ntp = Some(run_state);
    }
    let written = serde_json::to_vec_pretty(&desired)
        .map_err(io::Error::other)
        .and_then(|json| write_file(path, &json, 0o644, Place::Replace));
    match written {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(e) => {
            tracing::error!("failed to persist desired state for {service}: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}
// What: minimum registration token length, in characters.
// Why: this token alone gates remote registration.
const MIN_REGISTRATION_TOKEN_LEN: usize = 32;

// What: the ui log file from UI_LOG_FILE; unset is fatal.
// Why: tracing and the root start must agree on one path.
// From: Issue #633 | PR #1858
fn ui_log_file() -> String {
    config::env_opt("UI_LOG_FILE")
        .unwrap_or_else(|| container_start_fatal("UI_LOG_FILE is not set"))
}

// What: a real token as is, else a persisted random one.
// Why: placeholders crash-looped the ui; it must not rotate.
fn registration_token(configured: &str, token_file: &str) -> Result<String, String> {
    let token = if is_placeholder(configured) {
        let path = Path::new(token_file);
        load_or_create(
            path,
            || {
                // What: log that a token was generated.
                // Why: operators must know where to read it.
                tracing::warn!(
                    "SECONDARY_REGISTRATION_TOKEN was unset or a placeholder; generated a \
                     persistent random token at {}",
                    path.display()
                );
                let token = hex::encode(rand::random::<[u8; 32]>());
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
// Why: bad env must fail closed before NATS or durable state.
fn preflight(cfg: &Config) -> Result<Duration, String> {
    let ttl = cfg.ui_session_ttl_seconds;
    if ttl == 0 || ttl > MAX_UI_SESSION_TTL_SECONDS {
        return Err(format!(
            "UI_SESSION_TTL_SECONDS ({ttl}) must be between 1 and {MAX_UI_SESSION_TTL_SECONDS} seconds"
        ));
    }
    validate_nats_credentials(cfg)?;
    // What: auth must be fully set, or insecure mode chosen.
    // Why: a half-set pair would silently run without a login.
    match (&cfg.auth_user, &cfg.auth_password) {
        (Some(_), Some(_)) => {}
        (None, None) if cfg.allow_insecure_ui => {
            tracing::warn!("ALLOW_INSECURE_UI=true: starting Admin-UI without authentication");
        }
        (None, None) => {
            return Err("Admin-UI authentication is required. Set UI_AUTH_USER and \
                        UI_AUTH_PASSWORD, or explicitly set ALLOW_INSECURE_UI=true if you \
                        understand the risk."
                .to_string());
        }
        _ => {
            return Err(
                "UI_AUTH_USER and UI_AUTH_PASSWORD must either both be set or both be \
                        empty."
                    .to_string(),
            );
        }
    }
    Ok(Duration::from_secs(ttl))
}

// What: send logs to stdout and to UI_LOG_FILE if openable.
// Why: a missing log dir must not stop the ui from starting.
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

// What: a required numeric id from the image environment.
// Why: the Dockerfile owns the runtime uid/gid, not code.
// From: Issue #1427 | PR #1858
fn required_env_id(key: &str) -> u32 {
    let raw =
        config::env_opt(key).unwrap_or_else(|| container_start_fatal(&format!("{key} is not set")));
    raw.parse()
        .unwrap_or_else(|_| container_start_fatal(&format!("{key}={raw} is not an id")))
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
        &cfg.nats_conf_path,
    ];
    let mut dirs: Vec<PathBuf> = files
        .iter()
        .filter_map(|file| Path::new(file.as_str()).parent().map(Path::to_path_buf))
        .chain([
            PathBuf::from(&cfg.dns_standard_state_dir),
            PathBuf::from(&cfg.dns_ssl_state_dir),
        ])
        .chain(log_file.parent().map(Path::to_path_buf))
        .filter(|dir| !dir.as_os_str().is_empty())
        .collect();
    dirs.sort();
    dirs.dedup();
    dirs
}

// What: lchown a tree recursively, never following links.
// Why: a symlink in a volume must not redirect root's chown.
// From: Issue #1427
fn chown_tree(path: &Path, uid: u32, gid: u32) -> io::Result<()> {
    std::os::unix::fs::lchown(path, Some(uid), Some(gid))?;
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
    std::os::unix::fs::lchown(dir, None, Some(gid))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o2775))?;
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let meta = fs::symlink_metadata(&path)?;
        if meta.is_file() {
            std::os::unix::fs::lchown(&path, None, Some(gid))?;
            fs::set_permissions(&path, fs::Permissions::from_mode(meta.mode() | 0o040))?;
        }
    }
    Ok(())
}

// What: as root: secrets, ownership, then exec as user.
// Why: the server must never run as root; volumes start root.
// From: Issue #858 | PR #1858
fn container_root_start() {
    let euid = fs::metadata("/proc/self")
        .unwrap_or_else(|e| container_start_fatal(&format!("cannot read /proc/self: {e}")))
        .uid();
    if euid != 0 {
        return;
    }
    let uid = required_env_id("UI_RUNTIME_UID");
    let gid = required_env_id("UI_RUNTIME_GID");
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

// What: write a file when it differs; owner is (uid, gid).
// Why: reruns on every start must write nothing.
// From: Issue #1683 | PR #1858
fn put(path: &Path, content: &str, mode: u32, owner: Option<(u32, u32)>) -> Result<(), String> {
    let owner = owner.map(|(uid, gid)| (Some(uid), Some(gid)));
    write_if_changed(path, content.as_bytes(), mode, owner)
        .map(|_| ())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

// What: an empty file only when none exists yet.
// Why: the ui owns the fragment; a rerun never clobbers it.
// From: Issue #811 | PR #1858
fn create_if_absent(path: &Path, mode: u32, owner: Option<(u32, u32)>) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => put(path, "", mode, owner),
        Err(e) => Err(format!("cannot stat {}: {e}", path.display())),
    }
}

// What: resolve one prefix's secrets, then load Config.
// Why: Config reads a secret file only once it exists.
// From: Issue #1683 | PR #1858
fn prepared_config(gid: u32, prefix: &str) -> Result<Config, String> {
    let cfg = Config::from_env()?;
    ensure_shared_secrets(&cfg.shared_secret_dir, gid, prefix)?;
    Config::from_env()
}

// What: nats.conf, the fragment stub and the nats log dir.
// Why: nats-server reads all of them at its first start.
// From: Issue #1683 | PR #1858
fn prepare_nats(gid: u32) -> Result<(), String> {
    let owner = Some((required_env_id("UI_RUNTIME_UID"), gid));
    let cfg = prepared_config(gid, "NATS_")?;
    put(
        Path::new(&cfg.nats_conf_path),
        &render_nats_conf(&cfg)?,
        0o600,
        owner,
    )?;
    create_if_absent(Path::new(&cfg.nats_auth_callout_path), 0o644, owner)?;
    let dir = Path::new(&cfg.nats_log_file)
        .parent()
        .ok_or_else(|| format!("NATS_LOG_FILE={} has no directory", cfg.nats_log_file))?;
    open_log_dir_to_group(dir, gid).map_err(|e| format!("{}: {e}", dir.display()))
}

// What: alarm token, sender, log config and log dir.
// Why: the upstream netdata image has no hook of ours.
// From: Issue #1683 | PR #1858
fn prepare_netdata(gid: u32) -> Result<(), String> {
    let cfg = prepared_config(gid, "NETDATA_")?;
    if cfg.netdata_alarm_token.is_empty() {
        return Err("NETDATA_ALARM_TOKEN resolved to an empty value".to_string());
    }
    let need =
        |value: &Option<String>, key: &str| value.clone().ok_or_else(|| config::not_set(key));
    let token = need(&cfg.netdata_token_file, "NETDATA_TOKEN_FILE")?;
    let notify = need(&cfg.netdata_notify_file, "NETDATA_NOTIFY_FILE")?;
    let conf = need(&cfg.netdata_conf_file, "NETDATA_CONF_FILE")?;
    let daemon_log = need(&cfg.netdata_daemon_log, "NETDATA_DAEMON_LOG")?;
    let health_log = need(&cfg.netdata_health_log, "NETDATA_HEALTH_LOG")?;
    let sender = render_alarm_notify_conf(
        &need(&cfg.netdata_alarm_ui_url, "NETDATA_ALARM_UI_URL")?,
        &token,
        &need(&cfg.netdata_alarm_max_time, "NETDATA_ALARM_MAX_TIME")?,
        &need(&cfg.netdata_alarm_recipient, "NETDATA_ALARM_RECIPIENT")?,
    )?;
    // What: refuse a log path with a line break.
    // Why: it would inject a line into the netdata config.
    if [&daemon_log, &health_log]
        .iter()
        .any(|p| p.contains(['\n', '\r']))
    {
        return Err("a netdata log path holds a line break".to_string());
    }
    let mut log_dirs: Vec<&Path> = [&daemon_log, &health_log]
        .iter()
        .map(|p| Path::new(p.as_str()).parent())
        .collect::<Option<_>>()
        .ok_or("a netdata log path has no directory")?;
    log_dirs.dedup();
    put(Path::new(&token), &cfg.netdata_alarm_token, 0o600, None)?;
    put(Path::new(&notify), &sender, 0o644, None)?;
    put(
        Path::new(&conf),
        &format!("[logs]\ndaemon = {daemon_log}\nhealth = {health_log}\n"),
        0o644,
        None,
    )?;
    log_dirs.iter().try_for_each(|dir| {
        open_log_dir_to_group(dir, gid).map_err(|e| format!("{}: {e}", dir.display()))
    })
}

// What: one-shot root prep for an image we do not build.
// Why: compose holds no logic; the files are written here.
// From: Issue #1683 | PR #1858
fn prepare_runtime(args: &[String]) -> ! {
    let gid = required_env_id("UI_RUNTIME_GID");
    let done = match args {
        [target] if target == "nats" => prepare_nats(gid),
        [target] if target == "netdata" => prepare_netdata(gid),
        [target, dirs @ ..] if target == "logs" && !dirs.is_empty() => {
            dirs.iter().try_for_each(|d| {
                open_log_dir_to_group(Path::new(d), gid).map_err(|e| format!("{d}: {e}"))
            })
        }
        _ => Err("usage: --prepare nats | netdata | logs <dir>...".to_string()),
    };
    match done {
        Ok(()) => std::process::exit(0),
        Err(e) => container_start_fatal(&e),
    }
}

// What: open the secondaries database and bring it up to date.
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

// What: the issuer key, from its env seed or its file.
// Why: the public key is needed for the callout fragment.
// From: Issue #583
fn issuer_keypair(cfg: &Config) -> Result<KeyPair, String> {
    if let Some(seed) = &cfg.nats_issuer_seed {
        return KeyPair::from_seed(seed)
            .map_err(|e| format!("NATS_ISSUER_SEED is not a valid NKey seed: {e}"));
    }
    let path = Path::new(&cfg.nats_issuer_seed_path);
    load_or_create(
        path,
        || {
            let pair = KeyPair::new_account();
            // What: a generated key always has a seed.
            // Why: only a public-only key lacks one.
            let seed = pair.seed().expect("a generated key has a seed");
            (seed, pair)
        },
        |text| {
            KeyPair::from_seed(text).map_err(|e| {
                anyhow::anyhow!("issuer NKey seed at {} is invalid: {e}", path.display())
            })
        },
    )
    .map_err(|e| format!("{e:#}"))
}

// What: the callout encryption key, from its env seed or file.
// Why: a separate X25519 key; its rotation is its own.
// From: Issue #682
fn callout_xkey(cfg: &Config) -> Result<XKey, String> {
    if let Some(seed) = &cfg.nats_xkey_seed {
        return XKey::from_seed(seed)
            .map_err(|e| format!("NATS_XKEY_SEED is not a valid NKey seed: {e}"));
    }
    let path = Path::new(&cfg.nats_xkey_seed_path);
    load_or_create(
        path,
        || {
            let pair = XKey::new();
            // What: a generated key always has a seed.
            // Why: only a public-only key lacks one.
            let seed = pair.seed().expect("a generated key has a seed");
            (seed, pair)
        },
        |text| {
            XKey::from_seed(text)
                .map_err(|e| anyhow::anyhow!("xkey seed at {} is invalid: {e}", path.display()))
        },
    )
    .map_err(|e| format!("{e:#}"))
}

// What: write the callout fragment; restart NATS on change.
// Why: the docker proxy may not be ready at ui start.
// From: Issue #811 | PR #1610
async fn apply_callout_fragment(state: &AppState) {
    const ATTEMPTS: u32 = 8;
    let mut delay = Duration::from_secs(1);
    for attempt in 1..=ATTEMPTS {
        match reload_nats_conf(state).await {
            Ok(()) => return,
            Err(e) if attempt == ATTEMPTS => tracing::error!(
                "Failed to apply the auth_callout fragment after {ATTEMPTS} attempts; NATS keeps \
                 its previous fragment and may reject callout responses: {e}"
            ),
            Err(e) => {
                tracing::warn!(
                    "Could not apply the auth_callout fragment (attempt {attempt}/{ATTEMPTS}): \
                     {e}. Retrying in {delay:?}"
                );
                backoff(&mut delay, Duration::from_secs(8)).await;
            }
        }
    }
}

// What: every route of the ui, public and protected.
// Why: the protected layer owns auth and CSRF.
fn router(state: Arc<AppState>) -> Router {
    // What: routes outside the login, each gated on its own.
    // Why: no session cookie may ride on cacheable assets.
    let public: Vec<(&str, MethodRouter<Arc<AppState>>)> = vec![
        ("/health", get(health)),
        ("/api/secondary/register", post(register_secondary)),
        (ALARM_INGEST_PATH, post(ingest_alarm)),
        ("/favicon.ico", get(favicon_ico)),
        ("/static/logo-icon.png", get(logo_icon)),
    ];
    let protected: Vec<(&str, MethodRouter<Arc<AppState>>)> = vec![
        ("/", get(dashboard)),
        ("/dhcp", get(dhcp_page)),
        ("/dhcp/mode", post(update_dhcp_mode)),
        ("/dhcp/ddns", post(update_dhcp_ddns)),
        ("/dhcp/proxy", post(update_dhcp_proxy)),
        ("/dhcp/relay", post(update_dhcp_relay)),
        ("/dhcp/subnet/add", post(add_subnet)),
        ("/dhcp/subnet/update", post(update_subnet)),
        ("/dhcp/subnet/remove", post(remove_subnet)),
        ("/dhcp/subnet/option/add", post(add_subnet_option)),
        ("/dhcp/subnet/option/remove", post(remove_subnet_option)),
        ("/dhcp/static/add", post(add_reservation)),
        ("/dhcp/static/remove", post(remove_reservation)),
        ("/dhcp/lease/release", post(release_lease)),
        ("/dhcp/snapshot/rollback", post(rollback_kea_snapshot)),
        ("/api/dhcp/check", post(check_dhcp_conflict)),
        ("/ntp", get(ntp_page)),
        ("/ntp/settings", post(update_ntp_settings)),
        ("/domains", get(domains_page)),
        ("/domains/dns/add", post(add_dns)),
        ("/domains/dns/remove", post(remove_dns)),
        ("/domains/dns/toggle", post(toggle_default_domain)),
        ("/domains/lan/add", post(add_lan_record)),
        ("/domains/lan/remove", post(remove_lan_record)),
        ("/domains/ptr/add", post(add_ptr_record)),
        ("/domains/ptr/remove", post(remove_ptr_record)),
        ("/domains/aaaa-filter", post(toggle_aaaa_filter)),
        (
            "/domains/ddns-allow-unsigned-updates",
            post(toggle_ddns_allow_unsigned_updates),
        ),
        ("/domains/zones/rollback", post(rollback_zone_snapshot)),
        ("/stats", get(stats_page)),
        ("/logs", get(logs_page)),
        ("/setup", get(setup_page)),
        ("/setup/update", post(update_stack_settings)),
        ("/setup/restart-ui", post(restart_ui_service)),
        (
            "/api/services/{service}/desired-state",
            post(set_service_desired_state),
        ),
        ("/cache/resize", post(resize_cache)),
        ("/api/metrics", get(metrics_api)),
        ("/api/watchdog-status", get(watchdog_status_api)),
        ("/api/netdata/{*path}", get(netdata_proxy)),
        ("/static/admin.css", get(admin_css)),
        ("/static/chart.umd.min.js", get(chart_js)),
        ("/secondaries", get(secondaries_page)),
        ("/api/secondary/{name}", delete(remove_secondary)),
        ("/api/secondary/{name}/rotate-token", post(rotate_token)),
        ("/api/secondary/{name}/health", post(check_secondary_health)),
        ("/api/secondary/{name}/address", post(set_secondary_address)),
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
// Why: it serves nothing until NATS is up; retry beats exit.
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
    let nats = connect_nats_with_retry(&cfg).await;
    let http = http_client()?;
    let state = Arc::new(AppState {
        templates: load_templates(&cfg),
        docker: DockerProxy::new(&cfg.docker_proxy_url),
        http_client: http.clone(),
        pdns: PowerDns::new(http, cfg.pdns_api_key.clone()),
        file_lock: Mutex::new(()),
        netdata_alarms_lock: Mutex::new(()),
        kea_config_lock: tokio::sync::Mutex::new(()),
        dhcp_probe_lock: tokio::sync::Mutex::new(()),
        nats,
        db: Mutex::new(open_database(&cfg.database_file)?),
        ui_session_secret: load_or_create_hex::<32>(Path::new(&cfg.session_secret_file))?,
        ui_session_ttl,
        nats_issuer_public_key: issuer.public_key(),
        nats_callout_xkey_public_key: xkey.public_key(),
        config: cfg,
    });
    apply_callout_fragment(&state).await;
    // What: answer auth-callout requests for the process life.
    // Why: secondaries are checked per connect; no reload.
    tokio::spawn(run_auth_callout(state.clone(), issuer, xkey));
    let port = state.config.listen_port;
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!("LanCache Admin UI running on http://0.0.0.0:{port}");
    axum::serve(listener, router(state)).await?;
    Ok(())
}

// What: pick root prep, the DHCP probe, or the server.
// Why: the one-shots run as root as is; the server drops root.
// From: Issue #1288 | PR #1858
fn main() -> anyhow::Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("--prepare") => prepare_runtime(&std::env::args().skip(2).collect::<Vec<_>>()),
        Some("--dhcp-probe") => {
            print_probe_report();
            return Ok(());
        }
        _ => container_root_start(),
    }
    run()
}

// What: unit tests of pure rules; no files, sockets or mocks.
// Why: these rules guard data and security, not wiring.
#[cfg(test)]
mod tests {
    use super::*;

    // What: the domain rule agrees with the shared fixture.
    // Why: the shell validator reads the same cases.
    // From: Issue #822
    #[test]
    fn is_valid_domain_matches_shared_parity_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/fixtures/domain-validation-cases.txt"
        );
        let fixture = fs::read_to_string(path).expect("shared fixture is readable");
        let mut cases = 0;
        for line in fixture.lines().map(str::trim_end) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (verdict, domain) = line.split_once(' ').expect("verdict and domain");
            assert_eq!(
                parse_cdn_domain(domain).is_some(),
                verdict == "valid",
                "fixture case: {line}"
            );
            cases += 1;
        }
        assert!(cases > 0, "the fixture holds no cases");
    }

    // What: list edits keep CRLF, markers and disabled lines.
    // Why: a wrong rewrite would silently change the proxy's list.
    #[test]
    fn domain_list_edits_keep_line_endings_and_markers() {
        let steam = parse_cdn_domain("steam.com").expect("valid entry");
        assert_eq!(
            with_enabled("!steam.com\r\nepic.com\n", &steam, true).as_deref(),
            Some("steam.com\r\nepic.com\n")
        );
        assert_eq!(with_enabled("steam.com\n", &steam, true), None);
        assert_eq!(
            without_domain(
                "steam.com\r\nepic.com\r\n",
                &DeleteTarget::Domain(steam.clone())
            )
            .as_deref(),
            Some("epic.com\r\n")
        );
        assert_eq!(with_added("steam.com\n", &steam), None);
        let epic = parse_cdn_domain(".epic.com").expect("valid entry");
        assert_eq!(
            with_added("steam.com", &epic).as_deref(),
            Some(concat!(
                "steam.com\n\n",
                "# ==== lancache-ng: entries added via the Admin UI are appended below this ",
                "exact line ====\n",
                ".epic.com\n"
            ))
        );
    }

    // What: a session cookie holds only for its own secret.
    // Why: an edited or foreign cookie must not grant a token.
    #[test]
    fn session_cookie_rejects_edits_and_other_secrets() {
        let secret = [7u8; 32];
        let session = issue_session(&secret, Duration::from_secs(3600));
        let valid = validate_session(&session.cookie_value, &secret).expect("fresh cookie holds");
        assert_eq!(valid.csrf_token, session.csrf_token);
        assert!(validate_session(&session.cookie_value, &[8u8; 32]).is_none());
        assert!(validate_session(&format!("{}0", session.cookie_value), &secret).is_none());
        assert!(validate_session("v1.1.abc.def", &secret).is_none());
    }

    // What: the cache size check keeps its safety buffer.
    // Why: a full cache disk stalls the proxy and the watchdog.
    // From: Issue #1069
    #[test]
    fn cache_size_check_keeps_the_buffer() {
        assert!(!cache_fits(50, 50 * 1024));
        assert!(cache_fits(10, 12 * 1024 + 2048));
        assert_eq!(largest_cache_gb(400), None);
        assert_eq!(largest_cache_gb(10 * 1024), Some(8));
    }

    // What: the upstream NTP list is cleaned or refused.
    // Why: entrypoint.sh must get at least one valid server.
    #[test]
    fn ntp_upstream_list_is_cleaned_or_refused() {
        assert_eq!(
            ntp_upstream_servers("0.debian.pool.ntp.org, time.cloudflare.com\r\n192.0.2.1"),
            Ok("0.debian.pool.ntp.org time.cloudflare.com 192.0.2.1".to_string())
        );
        assert!(ntp_upstream_servers(",, ,").is_err());
        assert!(ntp_upstream_servers("not a valid host!!").is_err());
        assert!(ntp_upstream_servers("2606:4700:f1::1").is_ok());
    }

    // What: malformed DNS answers are refused, never indexed.
    // Why: the probe reads bytes from an untrusted LAN host.
    #[test]
    fn short_or_foreign_dns_answers_are_errors() {
        assert!(classify_soa(&[], 1).is_err());
        assert!(classify_soa(&[0; 11], 1).is_err());
        assert!(classify_soa(&[0, 2, 0x84, 0, 0, 0, 0, 0, 0, 0, 0, 0], 1).is_err());
    }
}
