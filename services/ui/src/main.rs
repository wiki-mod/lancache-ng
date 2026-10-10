//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! What: the Admin UI server, one-shot modes and clients.
//! Why: one binary serves pages and drives Docker/NATS/Kea.
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
use futures_util::StreamExt as _;
use lancache_ng::config::{
    self, CONTAINER_DHCP, CONTAINER_DHCP_PROBE, CONTAINER_DHCP_PROXY, CONTAINER_DNS_SSL,
    CONTAINER_DNS_STANDARD, CONTAINER_NATS, CONTAINER_NETDATA, CONTAINER_NTP, CONTAINER_PROXY,
    CONTAINER_SYSLOG, CONTAINER_UI, DEFAULT_RECORD_TTL, DhcpMode, LAN_ZONE, NATS_SUBJECT_FLUSH,
    NATS_SUBJECT_RECORD, NatsLogin, NatsRoles, OPTION_CODE_MAX, OPTION_CODE_MIN, OutOfRange,
    PDNS_API_PATH, PDNS_AUTH_PORT, Uint, canonical_zone, dns_reader_publish, dns_subscribe,
    is_container, is_dns_name, option_code, option_data, parse_bool, parse_custom_options,
    rollback_zones, zone_url,
};
use lancache_ng::{
    DesiredRunState, DesiredState, DnsRecord, DockerApi, DockerError, FlushRequest, Place,
    PowerDns, ProbeAnswer, ProbeReport, SnapshotStore, WatchdogStatus, ct_eq, df, die, hex32,
    http_client, is_placeholder, load_or_create, load_or_create_hex, resolve_shared_secret,
    shared_secret, shared_secret_file_name, shared_secret_is_placeholder, snapshot_created_unix,
    unix_secs, write_file, write_if_changed,
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
use std::process::Command;
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
    dhcp_api_user: String,
    ui_settings_file: String,
    startup_settings: HashMap<&'static str, String>,
    kea_config_snapshot_dir: String,
    dhcp_probe_request_file: String,
    dhcp_probe_result_file: String,
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
        let set = |key: &str| config::opt(env, key);
        let text = |key: &str, default: &str| set(key).unwrap_or_else(|| default.to_string());
        // What: a compose value; unset stops startup.
        // Why: compose owns it; Rust keeps no default.
        let need = |key: &str| config::need(env, key);
        // What: a compose bool; junk stops startup.
        // Why: as for need; a typo must not flip a gate.
        let need_flag = |key: &str| config::need_flag(env, key);
        let flag =
            |key: &str, default: bool| env(key).and_then(|v| parse_bool(&v)).unwrap_or(default);
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

        let standard_log = need("STANDARD_LOG")?;
        let proxy_standard_url = need("PROXY_STANDARD_URL")?;
        // What: both proxy addresses come from compose.
        // Why: no LAN address is hardcoded (AG-SEC-007).
        let standard_ip = need("STANDARD_IP")?;
        let ssl_ip = need("SSL_IP")?;
        // What: the Docker API URL comes from compose.
        // Why: compose owns the value; no second default.
        let nats_url = need("NATS_URL")?;
        let docker_proxy_url = need("DOCKER_PROXY_URL")?;
        let tag = need("LANCACHE_IMAGE_TAG")?;
        let channel = set("LANCACHE_IMAGE_CHANNEL")
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| derive_image_channel(&tag));
        let cache_max_gb = cache_max_gb_from(env)?;
        // What: DHCP_ENABLED is an optional legacy switch.
        // Why: the ui gets none; unset keeps DHCP off.
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
        let ttl = knob(
            "UI_SESSION_TTL_SECONDS",
            MAX_UI_SESSION_TTL_SECONDS,
            OutOfRange::Reject,
        )?;
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
            // Why: the ui gets none; the saved file sets.
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
            dhcp_api_user: need("DHCP_API_USER")?,
            ui_settings_file: need("UI_SETTINGS_FILE")?,
            startup_settings,
            kea_config_snapshot_dir: need("KEA_CONFIG_SNAPSHOT_DIR")?,
            dhcp_probe_request_file: need("DHCP_PROBE_REQUEST_FILE")?,
            dhcp_probe_result_file: need("DHCP_PROBE_RESULT_FILE")?,
            kea_keep_known_good_configs: knob(
                "KEEP_KNOWN_GOOD_CONFIGS",
                u32::MAX.into(),
                OutOfRange::Reject,
            )? as u32,
            auth_user: set("UI_AUTH_USER"),
            auth_password: set("UI_AUTH_PASSWORD"),
            allow_insecure_ui: need_flag("ALLOW_INSECURE_UI")?,
            ui_session_ttl_seconds: ttl,
            // What: security headers are on unless off.
            // Why: the ui gets none; safe is the default.
            security_headers_enabled: flag("UI_SECURITY_HEADERS", true),
            hsts_mode: hsts_mode_from(&text("UI_HSTS_MODE", "")),
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
            netdata_conf_file: set("NETDATA_CONF_FILE"),
            netdata_notify_file: set("NETDATA_NOTIFY_FILE"),
            netdata_token_file: set("NETDATA_TOKEN_FILE"),
            netdata_daemon_log: set("NETDATA_DAEMON_LOG"),
            netdata_health_log: set("NETDATA_HEALTH_LOG"),
            netdata_alarm_ui_url: set("NETDATA_ALARM_UI_URL"),
            netdata_alarm_max_time: set("NETDATA_ALARM_MAX_TIME"),
            netdata_alarm_recipient: set("NETDATA_ALARM_RECIPIENT"),
            // What: dev mode is an optional switch, off.
            // Why: the ui gets none; prod stays off.
            dev_mode: flag("LANCACHE_DEV_MODE", false),
            syslog_enabled: need_flag("SYSLOG_ENABLED")?,
            syslog_log_root: need("SYSLOG_LOG_ROOT")?,
            syslog_max_gb: read(config::SYSLOG_MAX_GB)? as u32,
            watchdog_status_file: need("WATCHDOG_STATUS_FILE")?,
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
        DhcpMode::parse(&self.setting("DHCP_MODE"), false)
    }

    // What: the cache size an operator requested, in GB.
    // Why: differs from cache_max_gb until proxy recreate.
    fn requested_cache_gb(&self) -> f64 {
        self.setting("CACHE_MAX_GB")
            .trim()
            .parse()
            .unwrap_or(self.cache_max_gb)
    }

    // What: save the settings file with changed values.
    // Why: one whole-file writer keeps other keys intact.
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

// What: CACHE_MAX_GB, or the matching legacy pair, or 50.
// Why: a malformed value must fail, not fall back.
fn cache_max_gb_from(env: &dyn Fn(&str) -> Option<String>) -> Result<f64, String> {
    let parse = |key: &str| -> Result<Option<f64>, String> {
        config::opt(env, key)
            .map(|raw| {
                raw.trim()
                    .parse::<f64>()
                    .ok()
                    .filter(|gb| gb.is_finite() && *gb >= 0.0)
                    .ok_or_else(|| format!("{key} must be a number of gigabytes, got {raw:?}"))
            })
            .transpose()
    };
    if let Some(value) = parse("CACHE_MAX_GB")? {
        return Ok(value);
    }
    let (standard, ssl) = (parse("STANDARD_CACHE_MAX_GB")?, parse("SSL_CACHE_MAX_GB")?);
    if let (Some(standard), Some(ssl)) = (standard, ssl)
        && (standard - ssl).abs() > f64::EPSILON
    {
        return Err(format!(
            "STANDARD_CACHE_MAX_GB ({standard}) and SSL_CACHE_MAX_GB ({ssl}) differ \
             without CACHE_MAX_GB; set CACHE_MAX_GB to one shared cache size."
        ));
    }
    Ok(standard.or(ssl).unwrap_or(50.0))
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
        let current = if shared_secret_is_placeholder(&configured) {
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
    docker: DockerApi,
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
    let csrf_token = hex::encode(rand::random::<[u8; 32]>());
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
// Why: brand assets cache for long, the stylesheet doesn't.
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
// What: services the ui may act on; no watchdog, no syslog.
// Why: the ui must never stop the monitor or the log sink.
// From: Issue #1486
const DOCKER_SERVICES: [&str; 9] = [
    CONTAINER_PROXY,
    CONTAINER_DNS_STANDARD,
    CONTAINER_DNS_SSL,
    CONTAINER_DHCP,
    CONTAINER_DHCP_PROXY,
    CONTAINER_DHCP_PROBE,
    CONTAINER_NATS,
    CONTAINER_NTP,
    CONTAINER_UI,
];

// What: time bound of one Docker call from the ui.
// Why: a stuck proxy must not hang a page request.
const DOCKER_TIMEOUT: Duration = Duration::from_secs(120);

// What: the container name of an allowlisted service.
// Why: any other name is refused before Docker sees it.
// From: Issue #1592
fn container_name(service: &str) -> anyhow::Result<&'static str> {
    DOCKER_SERVICES
        .into_iter()
        .find(|full| is_container(full, service))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "Docker service '{service}' is not in the lancache-ng socket-proxy allowlist"
            )
        })
}

// What: seconds a restarted container may take to stop.
// Why: nginx-style daemons need a moment to drain.
const RESTART_GRACE_SECS: u32 = 5;

// What: restart a service container after the grace.
// Why: every ui restart goes through one named service.
async fn docker_restart(docker: &DockerApi, service: &str) -> anyhow::Result<()> {
    docker
        .restart(
            container_name(service)?,
            RESTART_GRACE_SECS,
            Some(DOCKER_TIMEOUT),
        )
        .await
        .with_context(|| format!("Failed to restart '{service}'"))?;
    tracing::info!("Restarted service '{service}'");
    Ok(())
}

// What: start a service container.
// Why: the stop/start pairs of the mode switches need it.
async fn docker_start(docker: &DockerApi, service: &str) -> anyhow::Result<()> {
    docker
        .act(container_name(service)?, "start", Some(DOCKER_TIMEOUT))
        .await
        .with_context(|| format!("Failed to start '{service}'"))?;
    tracing::info!("Started service '{service}'");
    Ok(())
}

// What: stop a service; an absent container is fine.
// Why: a 404 means the wanted state already holds.
async fn docker_stop_if_present(docker: &DockerApi, service: &str) -> anyhow::Result<()> {
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
    if age > status.stale_after() {
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
    bytes as f64 / GIB as f64
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

// What: netdata custom_sender that POSTs alarms to the ui.
// Why: fields come from NetdataAlarm; no second list.
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

// What: the dotted reverse zone that owns an IPv4 address.
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

// What: ask addr:port for the lan. SOA over UDP.
// Why: a silent host is a status, not an error.
async fn probe_secondary_soa(addr: Ipv4Addr, port: u16) -> ProbeResult {
    const TIMEOUT: Duration = Duration::from_secs(4);
    let id: u16 = rand::random();
    let query = soa_query(id, LAN_ZONE);
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
// Why: revocation is the per-connect DB check, not expiry.
const USER_JWT_TTL_SECS: i64 = 90 * 24 * 60 * 60;

// What: sleep, then double the delay up to a cap.
// Why: one backoff step for every NATS retry loop.
// From: Issue #849
async fn backoff(delay: &mut Duration, max: Duration) {
    tokio::time::sleep(*delay).await;
    *delay = (*delay * 2).min(max);
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
    let mut delay = Duration::from_secs(1);
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
                backoff(&mut delay, Duration::from_secs(30)).await;
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
// Why: the dns supervisor restarts nats-server on a change.
// From: Issue #811 | Issue #1683
fn write_callout_fragment(state: &AppState) -> Result<(), String> {
    state.config.nats.validate()?;
    let fragment = render_auth_callout_fragment(
        &state.config,
        &state.nats_issuer_public_key,
        &state.nats_callout_xkey_public_key,
    );
    write_if_changed(
        Path::new(&state.config.nats_auth_callout_path),
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
// Why: only the hash is stored; plaintext is shown once.
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
    let mut delay = Duration::from_secs(1);
    loop {
        let client = match nats_connect(&state.config.nats_url, &state.config.nats.callout).await {
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
    let _ = client.drain().await;
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
// Why: plaintext is shown once; only its hash is stored.
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
    let hash = hash_nats_password(&nats_password).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
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
        proxy_ip: state.config.standard_ip.clone(),
        pdns_api_key: state.config.pdns_api_key.clone(),
        ddns_tsig_key,
        dns_xfr_primary: format!("{}:{PDNS_AUTH_PORT}", state.config.standard_ip),
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

// What: lease time shown when a subnet sets none, seconds.
// Why: equals the dhcp image default of DHCP_LEASE_TIME.
const DEFAULT_LEASE_TIME: u32 = 86_400;

// What: Kea error texts that mean "not found".
// Why: kea_modify maps exactly these to a 404.
const KEA_SUBNET_MISSING: &str = "subnet not found";
const KEA_OPTION_MISSING: &str = "custom option not found";

// What: option codes the dedicated subnet fields own.
// Why: routers 3, DNS 6, domain 15, NTP 42, search 119.
const KEA_MANAGED_CODES: [u16; 5] = [3, 6, 15, 42, 119];

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
// Why: Kea refuses its own hash key on config-test/-set.
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
// Why: a lost request is no refusal; it may have applied.
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

    // What: save the applied config as a good snapshot.
    // Why: a failed snapshot weakens rollback, not the edit
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
        // What: one retry if the write outcome is unknown.
        // Why: blind rollback could undo a landed write.
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
            KEA_SUBNET_MISSING | KEA_OPTION_MISSING => StatusCode::NOT_FOUND,
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
        // What: the default if the subnet sets no lifetime.
        // Why: the page shows the dhcp image default.
        lease_time: subnet
            .get("valid-lifetime")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_LEASE_TIME.into()) as u32,
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
                subnets = subnets_in(&config).iter().map(read_subnet).collect();
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
    if prefix != 0 && network & !mask != 0 {
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
) -> Result<(), &'static str> {
    // What: cap the maximum lifetime at seven days.
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

// What: create a subnet with the next free id.
// Why: ids need only be unique; max plus one never clashes.
async fn add_subnet(State(state): Shared, Form(f): Form<Fields>) -> Result<Redirect, HtmlError> {
    require_kea(&state)?;
    let (lease, cidr) = validate_subnet(&f).map_err(invalid)?;
    // What: resolve NTP names before the synchronous edit.
    // Why: the edit closure cannot await; bad name = 400.
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
    // Why: a blank hostname is a supported reservation.
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
    .await?;
    Ok(Redirect::to("/dhcp"))
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
    Ok(Redirect::to("/dhcp"))
}

// What: send a record delete event over NATS.
// Why: PowerDNS applies deletes from the subject of adds.
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
    // Why: lease4-del removes the record the name came from
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
            // What: clean DNS records after a release.
            // Why: best effort; the address is freed.
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
    // What: the LAN address if auto, else the default.
    // Why: auto off hands the option back to one value.
    let servers = if auto {
        state.config.standard_ip.clone()
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

// What: stop the containers a mode must not leave running.
// Why: runs before the save; a sub-mode switch restarts.
// From: Issue #1486
async fn stop_for_mode(
    state: &AppState,
    mode: DhcpMode,
    previous: DhcpMode,
) -> Result<(), HtmlError> {
    let mut stops: Vec<&str> = [CONTAINER_DHCP, CONTAINER_DHCP_PROXY]
        .into_iter()
        .filter(|container| Some(*container) != mode.container())
        .collect();
    // What: stop dhcp-proxy on a proxy/relay mode change.
    // Why: one container serves both; it must reread mode.
    if mode.is_dnsmasq() && previous.is_dnsmasq() && previous != mode {
        stops.push(CONTAINER_DHCP_PROXY);
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
    let Some(service) = mode.container() else {
        return Ok(());
    };
    let profile = if mode.is_kea() {
        "dhcp-kea"
    } else {
        "dhcp-proxy"
    };
    docker_start(&state.docker, service).await.map_err(|e| {
        // What: explain a container that was never created.
        // Why: the ui starts containers; it never creates.
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
    // What: push the NTP address to Kea after the switch.
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
    let Some(mode) = DhcpMode::from_name(&raw) else {
        return Err(dhcp_error(
            StatusCode::CONFLICT,
            "Invalid DHCP mode requested.",
        ));
    };
    let previous = state.config.dhcp_mode();

    // What: test the settings directory before any stop.
    // Why: a full or read-only volume must fail pre-stop.
    let check = Path::new(&state.config.ui_settings_file).with_file_name(".dhcp-mode-write-check");
    write_file(&check, b"", 0o600, Place::Replace).map_err(|e| {
        fail(format!(
            "DHCP settings file {} is not writable: {e}",
            state.config.ui_settings_file
        ))
    })?;
    // What: remove the probe file; a failure is ignored.
    // Why: the write passed; a leftover file is inert.
    let _ = fs::remove_file(&check);

    stop_for_mode(&state, mode, previous).await?;
    if let Err(saved) = save_dhcp_settings(&state, &[("DHCP_MODE", mode.as_str().to_string())]) {
        // What: restart the old mode after a failed save.
        // Why: the file still names the old mode.
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
    // What: check optional fields only when filled.
    // Why: blank means no dnsmasq.conf directive.
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

// What: ui wait limit for one probe answer.
// Why: worst case is 8 s of probing; 30 s covers a tick.
const PROBE_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

// What: ask the dhcp supervisor for one probe run.
// Why: the ui has no Docker; a request file starts it.
// From: Issue #947 | Issue #1683
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
    let _guard = state.file_lock.lock().unwrap_or_else(|e| e.into_inner());
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
    let zones = rollback_zones()
        .into_iter()
        .filter(|zone| zone.ends_with(".in-addr.arpa."));
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
            "/domains"
        }
        // What: a refusal is known; a lost request is not.
        // Why: an unknown outcome must not invite a retry.
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
    let list = fs::read_to_string(&cfg.cdn_domains_file).unwrap_or_else(|e| {
        tracing::error!("CDN domain list {} not read: {e}", cfg.cdn_domains_file);
        String::new()
    });
    let rows = domain_rows(&list);
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

// What: flush DNS and restart the SSL proxy after a change.
// Why: the proxy derives certs from the list at start.
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
    Ok(Redirect::to("/domains"))
}

// What: add or replace a LAN record through NATS.
// Why: the subscriber writes it on every DNS node.
async fn add_lan_record(State(state): Shared, Form(f): Form<Fields>) -> Redirect {
    let name = normalize_lan_name(f.get("name"));
    let ttl = f.number::<u32>("ttl").unwrap_or(DEFAULT_RECORD_TTL as u32);
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
// Why: any type may be deleted; the name must be in lan.
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

// What: marker file names the dns containers read.
// Why: the ui writes them; dns reads only their existence.
const AAAA_FILTER_MARKER: &str = "aaaa-filter-enabled";
const DDNS_UNSIGNED_MARKER: &str = "ddns-allow-unsigned-updates";

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
    // What: fail if either DNS instance lacks the state.
    // Why: the page must not claim what one node can't see.
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
    set_markers(&state, AAAA_FILTER_MARKER, f.get("enabled") == "1")?;
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
    set_markers(&state, DDNS_UNSIGNED_MARKER, enable)?;
    // What: restart both DNS services on a marker change.
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
    let ttl = f.number::<u32>("ttl").unwrap_or(DEFAULT_RECORD_TTL as u32);
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
    match tokio::task::spawn_blocking(move || job(&state)).await {
        Ok(value) => value,
        Err(e) => {
            tracing::error!("blocking job failed: {e}");
            T::default()
        }
    }
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
// Why: all collectors start at once; latency is the max.
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
    // Why: a pending resize must not look applied.
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
    // What: pending at a difference of 1 GB or more.
    // Why: a fraction of a GB is not shown as a resize.
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
// Why: the dashboard polls this without costly collectors.
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
// Why: once enabled, syslog-ng holds the fuller view.
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
            // What: accept only a host with a directory.
            // Why: the query value is caller input.
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

// What: normalize the upstream NTP list to spaces.
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
    let auto = !f.get("ntp_auto_dhcp").is_empty();
    let was_enabled = cfg.flag("NTP_ENABLED");
    let was_auto = was_enabled && cfg.flag("NTP_AUTO_DHCP");

    // What: stop NTP before saving if it was running.
    // Why: a restart before saving rereads the old list.
    if !enabled || was_enabled {
        docker_stop_if_present(&state.docker, CONTAINER_NTP)
            .await
            .map_err(|e| fail(format!("{e:#}")))?;
    }
    let saved = cfg.save_settings(&[
        ("NTP_ENABLED", bool_text(enabled)),
        ("NTP_UPSTREAM_SERVERS", servers),
        ("NTP_AUTO_DHCP", bool_text(auto)),
    ]);
    if let Err(save_err) = saved {
        // What: restart NTP if it ran before the failure.
        // Why: a failed save must not leave NTP stopped.
        // From: PR #1610
        if was_enabled && let Err(start_err) = docker_start(&state.docker, CONTAINER_NTP).await {
            return Err(fail(format!(
                "Failed to persist NTP settings ({save_err}), and restarting NTP after that \
                 failure also failed ({start_err:#}). NTP is now stopped and needs manual recovery."
            )));
        }
        return Err(fail(save_err.to_string()));
    }
    if enabled {
        docker_start(&state.docker, CONTAINER_NTP)
            .await
            .map_err(|e| fail(format!("{e:#}")))?;
    }
    // What: touch Kea's NTP option only when auto changes.
    // Why: a save leaving auto alone keeps subnet edits.
    if enabled && auto {
        sync_subnet_ntp(&state, true).await.map_err(fail)?;
    } else if was_auto {
        sync_subnet_ntp(&state, false).await.map_err(fail)?;
    }
    Ok(Redirect::to("/ntp"))
}

// What: the setup page with network hints and updates.
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
    Ok(Redirect::to("/setup"))
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
// Why: the restart ends this process; it runs out of line.
// From: Issue #1486
async fn restart_ui_service(State(state): Shared) -> Html<&'static str> {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(750)).await;
        if let Err(e) = docker_restart(&state.docker, CONTAINER_UI).await {
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
    // Why: two toggles at once must not drop each other.
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
    config::need(&config::process_env, "UI_LOG_FILE").unwrap_or_else(|e| container_start_fatal(&e))
}

// What: a real token as is, else a persisted random one.
// Why: placeholders crash-looped the ui; no rotation.
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
// Why: bad env must fail closed before NATS or state.
fn preflight(cfg: &Config) -> Result<Duration, String> {
    cfg.nats.validate()?;
    // What: auth must be fully set, or insecure chosen.
    // Why: a half-set pair would run without a login.
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

// What: a required numeric id from the image environment.
// Why: the Dockerfile owns the runtime uid/gid, not code.
// From: Issue #1427 | PR #1858
fn required_env_id(key: &'static str) -> u32 {
    let id = Uint {
        name: key,
        min: 0,
        max: u32::MAX.into(),
        below: OutOfRange::Reject,
        above: OutOfRange::Reject,
    };
    match id.parse(config::env_opt(key).as_deref()) {
        Ok((value, _)) => value as u32,
        Err(e) => container_start_fatal(&e),
    }
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
            PathBuf::from(&cfg.dns_standard_state_dir),
            PathBuf::from(&cfg.dns_ssl_state_dir),
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
// Why: the server must not run as root; volumes start root.
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

// What: resolve one prefix's secrets, then load Config.
// Why: Config reads a secret file only once it exists.
// From: Issue #1683 | PR #1858
fn prepared_config(gid: u32, prefix: &str) -> Result<Config, String> {
    let cfg = Config::from_env()?;
    ensure_shared_secrets(&cfg.shared_secret_dir, gid, prefix)?;
    Config::from_env()
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
        [target] if target == "netdata" => prepare_netdata(gid),
        [target, dirs @ ..] if target == "logs" && !dirs.is_empty() => {
            dirs.iter().try_for_each(|d| {
                open_log_dir_to_group(Path::new(d), gid).map_err(|e| format!("{d}: {e}"))
            })
        }
        _ => Err("usage: --prepare netdata | logs <dir>...".to_string()),
    };
    match done {
        Ok(()) => std::process::exit(0),
        Err(e) => container_start_fatal(&e),
    }
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

// What: the callout encryption key, from env seed or file.
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

// What: every route of the ui, public and protected.
// Why: the protected layer owns auth and CSRF.
fn router(state: Arc<AppState>) -> Router {
    // What: routes outside the login, each gated itself.
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
    let nats = connect_nats_with_retry(&cfg).await;
    let http = http_client()?;
    let state = Arc::new(AppState {
        templates: load_templates(&cfg),
        docker: DockerApi::new(&cfg.docker_proxy_url),
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
    if let Err(e) = write_callout_fragment(&state) {
        tracing::error!("Failed to write the auth_callout fragment: {e}");
    }
    // What: answer auth-callout requests while running.
    // Why: secondaries are checked per connect; no reload.
    tokio::spawn(run_auth_callout(state.clone(), issuer, xkey));
    let port = state.config.listen_port;
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!("LanCache Admin UI running on http://0.0.0.0:{port}");
    axum::serve(listener, router(state)).await?;
    Ok(())
}

// What: pick root prep or the server.
// Why: one-shots run as root as is; the server drops root.
// From: Issue #1288 | PR #1858
fn main() -> anyhow::Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("--prepare") => prepare_runtime(&std::env::args().skip(2).collect::<Vec<_>>()),
        _ => container_root_start(),
    }
    run()
}

// What: unit tests of pure rules; no files, sockets, mocks.
// Why: these rules guard data and security, not wiring.
#[cfg(test)]
mod tests {
    use super::*;
    use lancache_ng::{serve_canned, unique_temp_dir};

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

    // What: list edits keep CRLF, markers, disabled lines.
    // Why: a wrong rewrite would change the proxy's list.
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
    // Why: an edited or foreign cookie grants no token.
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
    // Why: a full cache disk stalls proxy and watchdog.
    // From: Issue #1069
    #[test]
    fn cache_size_check_keeps_the_buffer() {
        assert!(!cache_fits(50, 50 * 1024));
        assert!(cache_fits(10, 12 * 1024 + 2048));
        assert_eq!(largest_cache_gb(400), None);
        assert_eq!(largest_cache_gb(10 * 1024), Some(8));
    }

    // What: the upstream NTP list is cleaned or refused.
    // Why: entrypoint.sh needs at least one valid server.
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

    // What: HSTS text maps to a mode; unknown text is auto.
    // Why: plain HTTP must never get an HSTS header.
    #[test]
    fn hsts_text_maps_to_modes() {
        for on in ["always", "ALWAYS", " true ", "1", "on"] {
            assert_eq!(hsts_mode_from(on), HstsMode::Always, "{on:?}");
        }
        for off in ["never", "false", "0", "OFF"] {
            assert_eq!(hsts_mode_from(off), HstsMode::Never, "{off:?}");
        }
        for auto in ["", "auto", "maybe"] {
            assert_eq!(hsts_mode_from(auto), HstsMode::Auto, "{auto:?}");
        }
    }

    // What: cache size from the new key or the legacy pair.
    // Why: a bad value must fail; NaN would break the bar.
    // From: Issue #1069
    #[test]
    fn cache_size_reads_new_and_legacy_keys() {
        fn from(pairs: &[(&str, &str)]) -> Result<f64, String> {
            cache_max_gb_from(&|key: &str| {
                pairs
                    .iter()
                    .find(|(name, _)| *name == key)
                    .map(|(_, value)| value.to_string())
            })
        }
        assert_eq!(from(&[]), Ok(50.0));
        assert_eq!(from(&[("CACHE_MAX_GB", "120")]), Ok(120.0));
        let legacy = [("CACHE_MAX_GB", ""), ("SSL_CACHE_MAX_GB", "80")];
        assert_eq!(from(&legacy), Ok(80.0));
        let same = [("STANDARD_CACHE_MAX_GB", "70"), ("SSL_CACHE_MAX_GB", "70")];
        assert_eq!(from(&same), Ok(70.0));
        let split = [("STANDARD_CACHE_MAX_GB", "70"), ("SSL_CACHE_MAX_GB", "60")];
        assert!(from(&split).is_err());
        for bad in ["NaN", "inf", "-1", "abc"] {
            assert!(from(&[("CACHE_MAX_GB", bad)]).is_err(), "{bad:?} must fail");
        }
    }

    // What: the SOA query is the exact wire bytes.
    // Why: a wrong byte makes every secondary look silent.
    #[test]
    fn soa_query_has_the_wire_shape() {
        let want = [
            0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, b'l', b'a', b'n', 0, 0, 6, 0, 1,
        ];
        assert_eq!(soa_query(0x1234, "lan"), want);
        assert_eq!(soa_query(0x1234, "lan."), want);
        let two = soa_query(0, "a.lan");
        assert_eq!(&two[12..], &[1, b'a', 3, b'l', b'a', b'n', 0, 0, 6, 0, 1]);
    }

    // What: option codes parse in 1..=254, nothing else.
    // Why: both forms share this rule and its messages.
    #[test]
    fn option_codes_follow_one_range_rule() {
        assert_eq!(option_code(" 66 "), Ok(66));
        assert_eq!(option_code("1"), Ok(1));
        assert_eq!(option_code("254"), Ok(254));
        for bad in ["0", "255", "-1", "x", "", "65536"] {
            assert!(option_code(bad).is_err(), "{bad:?} must fail");
        }
        assert!(option_code("0").unwrap_err().contains("1 and 254"));
        let managed = custom_option_key("6").err();
        assert_eq!(
            managed,
            Some("option code is managed by dedicated subnet fields")
        );
    }

    // What: HMAC-SHA256 equals an independent test vector.
    // Why: the cookie signature is hand-rolled; pin it.
    #[test]
    fn hmac_matches_an_independent_vector() {
        let key: [u8; 32] = std::array::from_fn(|i| i as u8);
        let mac = hmac_sha256(&key, b"v1.123.abc");
        assert_eq!(
            hex::encode(mac),
            "e7b377574b0e1054869f123b91a243c1b915d9043d53a11dc0cf4dd44131d849"
        );
    }

    // What: LAN names become dotted FQDNs in the lan zone.
    // Why: the bare name "lan" is the zone root.
    #[test]
    fn lan_names_are_normalized_into_the_zone() {
        assert_eq!(normalize_lan_name("Host"), "host.lan.");
        assert_eq!(normalize_lan_name(" HOST.Lan "), "host.lan.");
        assert_eq!(normalize_lan_name("lan"), "lan.");
        assert_eq!(normalize_lan_name("a.b.lan."), "a.b.lan.");
        assert_eq!(normalize_lan_name("host.example.com."), "host.example.com.");
        assert!(is_lan_name("host.lan.", false) && is_lan_name("lan.", false));
        assert!(!is_lan_name("host.example.com.", false) && !is_lan_name("xlan.", false));
    }

    // What: LAN records pass by type, content, name, TTL.
    // Why: each type has its own syntax; bad input fails.
    #[test]
    fn lan_records_are_validated_by_type() {
        let ok = |name: &str, kind: &str, content: &str, ttl: u32| {
            validate_lan_record(name, kind, content, ttl)
        };
        assert_eq!(
            ok("h.lan.", "a", " 192.0.2.1 ", 300),
            Some(("A", "192.0.2.1".into()))
        );
        assert_eq!(
            ok("h.lan.", "AAAA", "2001:db8::1", 1),
            Some(("AAAA", "2001:db8::1".into()))
        );
        assert_eq!(
            ok("h.lan.", "CNAME", "other", 60),
            Some(("CNAME", "other".into()))
        );
        assert_eq!(
            ok("h.lan.", "MX", "10 mail", 60),
            Some(("MX", "10 mail".into()))
        );
        assert_eq!(ok("_k.lan.", "TXT", "v=1", 60), Some(("TXT", "v=1".into())));
        assert_eq!(ok("h.lan.", "A", "192.0.2.300", 300), None);
        assert_eq!(ok("h.lan.", "A", "192.0.2.1", 0), None);
        assert_eq!(ok("h.lan.", "A", "192.0.2.1", 2_147_483_648), None);
        assert_eq!(ok("h.example.com.", "A", "192.0.2.1", 300), None);
        assert_eq!(ok("_k.lan.", "A", "192.0.2.1", 300), None);
        assert_eq!(ok("h.lan.", "MX", "x mail", 300), None);
        assert_eq!(ok("h.lan.", "MX", "10 mail extra", 300), None);
        assert_eq!(ok("h.lan.", "TXT", "", 300), None);
        assert_eq!(ok("h.lan.", "SRV", "1 1 1 x", 300), None);
    }

    // What: delete accepts any record type of sound shape.
    // Why: odd types must stay removable; junk is refused.
    #[test]
    fn delete_types_are_checked_by_shape() {
        assert_eq!(delete_record_type(" a "), Some("A".to_string()));
        assert_eq!(delete_record_type("SRV"), Some("SRV".to_string()));
        assert_eq!(delete_record_type("type65"), Some("TYPE65".to_string()));
        assert_eq!(delete_record_type("TYPEx"), None);
        assert_eq!(delete_record_type("1A"), None);
        assert_eq!(delete_record_type("A;B"), None);
        assert_eq!(delete_record_type(&"A".repeat(17)), None);
    }

    // What: PTR rows come from enabled PTR records only.
    // Why: foreign names and disabled records stay out.
    #[test]
    fn ptr_rows_skip_disabled_and_other_types() {
        let rrsets = vec![
            json!({"name": "1.2.0.192.in-addr.arpa.", "type": "PTR", "ttl": 300,
                   "records": [{"content": "h.lan.", "disabled": false},
                               {"content": "off.lan.", "disabled": true}]}),
            json!({"name": "2.2.0.192.in-addr.arpa.", "type": "A", "ttl": 300,
                   "records": [{"content": "x", "disabled": false}]}),
            json!({"name": "example.com.", "type": "PTR", "ttl": 300,
                   "records": [{"content": "y.", "disabled": false}]}),
        ];
        let rows = ptr_rows(&rrsets);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            (rows[0].ip.as_str(), rows[0].hostname.as_str()),
            ("192.0.2.1", "h.lan.")
        );
        assert_eq!(rows[0].ttl, 300);
    }

    // What: a registration token is kept, made or refused.
    // Why: a placeholder must not become a live secret.
    #[test]
    fn registration_token_is_real_generated_or_refused() {
        let dir = unique_temp_dir("token");
        let file = dir.join("token").to_string_lossy().into_owned();
        let real = "r".repeat(32);
        assert_eq!(registration_token(&real, &file), Ok(real.clone()));
        assert!(registration_token("short-but-real", &file).is_err());
        let made = registration_token("CHANGE_ME_token", &file).unwrap();
        assert_eq!(made.len(), 64);
        assert_eq!(registration_token("", &file), Ok(made));
        fs::write(&file, "CHANGE_ME_x").unwrap();
        assert!(registration_token("", &file).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: malformed DNS answers are refused, not indexed.
    // Why: the probe reads bytes from an untrusted host.
    #[test]
    fn short_or_foreign_dns_answers_are_errors() {
        assert!(classify_soa(&[], 1).is_err());
        assert!(classify_soa(&[0; 11], 1).is_err());
        assert!(classify_soa(&[0, 2, 0x84, 0, 0, 0, 0, 0, 0, 0, 0, 0], 1).is_err());
    }

    // What: image tags map to a channel for display.
    // Why: only sha and version tags count as pinned.
    #[test]
    fn image_channels_follow_the_tag() {
        for same in ["dev", "nightly", "latest"] {
            assert_eq!(derive_image_channel(same), same);
        }
        for pinned in ["sha-abc123", "v1", "v2.0.1"] {
            assert_eq!(derive_image_channel(pinned), "pinned", "{pinned}");
        }
        for other in ["edge", "v", "vx", "1.2.3", "main", ""] {
            assert_eq!(derive_image_channel(other), "latest", "{other:?}");
        }
    }

    // What: HSTS is sent by mode, and by scheme in auto.
    // Why: plain HTTP must never get the header.
    #[test]
    fn hsts_is_sent_by_mode_and_scheme() {
        assert!(HstsMode::Auto.should_send(true));
        assert!(!HstsMode::Auto.should_send(false));
        assert!(HstsMode::Always.should_send(false));
        assert!(!HstsMode::Never.should_send(true));
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

    // What: the cookie signature equals a known vector.
    // Why: the signature binds expiry and token to a key.
    #[test]
    fn cookie_signature_equals_the_vector() {
        let key: [u8; 32] = std::array::from_fn(|i| i as u8);
        assert_eq!(
            cookie_signature(&key, 123, "abc"),
            "e7b377574b0e1054869f123b91a243c1b915d9043d53a11dc0cf4dd44131d849"
        );
    }

    // What: a cookie needs version, expiry, shape, sign.
    // Why: each broken part must fail on its own.
    #[test]
    fn session_cookie_checks_each_part() {
        let key = [3u8; 32];
        let later = unix_secs() + 1000;
        let sig = cookie_signature(&key, later, "tok");
        let good = format!("v1.{later}.tok.{sig}");
        let held = validate_session(&good, &key).expect("a fresh cookie holds");
        assert_eq!(held.csrf_token, "tok");
        assert_eq!(held.cookie_value, good);
        let past = cookie_signature(&key, 1, "tok");
        for bad in [
            format!("v2.{later}.tok.{sig}"),
            format!("v1.1.tok.{past}"),
            format!("v1.x.tok.{sig}"),
            format!("v1.{later}.tok"),
            format!("v1.{later}.other.{sig}"),
            String::new(),
        ] {
            assert!(validate_session(&bad, &key).is_none(), "{bad:?}");
        }
    }

    // What: a new session is random and bound to its ttl.
    // Why: every first request needs its own CSRF token.
    #[test]
    fn issued_sessions_are_random_and_expire_with_the_ttl() {
        let key = [5u8; 32];
        let before = unix_secs();
        let a = issue_session(&key, Duration::from_secs(3600));
        let b = issue_session(&key, Duration::from_secs(3600));
        let after = unix_secs();
        assert_ne!(a.csrf_token, b.csrf_token);
        assert_eq!(a.csrf_token.len(), 64);
        let parts: Vec<&str> = a.cookie_value.split('.').collect();
        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], "v1");
        let expires: u64 = parts[1].parse().unwrap();
        assert!((before + 3600..=after + 3600).contains(&expires));
        assert_eq!(parts[2], a.csrf_token);
        assert_eq!(parts[3], cookie_signature(&key, expires, parts[2]));
    }

    // What: the session cookie is found among others.
    // Why: cookies of other apps on the origin are ignored.
    #[test]
    fn session_cookie_is_found_among_others() {
        let mut headers = HeaderMap::new();
        assert_eq!(session_cookie(&headers), None);
        let own = "a=b; lancache_ui_session=v1.2.3.4; c=d";
        headers.insert(header::COOKIE, HeaderValue::from_static(own));
        assert_eq!(session_cookie(&headers), Some("v1.2.3.4"));
        let foreign = "xlancache_ui_session=1; other=2";
        headers.insert(header::COOKIE, HeaderValue::from_static(foreign));
        assert_eq!(session_cookie(&headers), None);
    }

    // What: only a first https hop counts as https.
    // Why: only a TLS-terminating proxy in front sets it.
    #[test]
    fn forwarded_proto_reads_the_first_hop() {
        let proto = |value: &'static str| {
            let mut headers = HeaderMap::new();
            headers.insert("x-forwarded-proto", HeaderValue::from_static(value));
            forwarded_proto_is_https(&headers)
        };
        assert!(proto("https"));
        assert!(proto(" HTTPS , http"));
        assert!(!proto("http"));
        assert!(!proto("http, https"));
        assert!(!forwarded_proto_is_https(&HeaderMap::new()));
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

    // What: HTML text is escaped in all five places.
    // Why: error pages echo operator input back.
    #[test]
    fn html_text_is_escaped() {
        assert_eq!(
            html_escape("<a href=\"x\">'&'</a>"),
            "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;"
        );
        assert_eq!(html_escape("plain"), "plain");
    }

    // What: an error page carries area, status and message.
    // Why: operators need the reason and a way back.
    #[tokio::test]
    async fn html_errors_render_area_status_and_escaped_text() {
        let error = HtmlError::new(StatusCode::BAD_REQUEST, &NTP_AREA, "bad <x>");
        let response = error.into_response();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
        assert_eq!(
            String::from_utf8(bytes.to_vec()).unwrap(),
            "<!DOCTYPE html>\n<html>\n<head><title>NTP Configuration Error</title></head>\n\
             <body><h1>NTP Configuration Error</h1>\n<p>bad &lt;x&gt;</p>\n\
             <p><a href=\"/ntp\">Return to NTP settings</a></p>\n</body>\n</html>"
        );
    }

    // What: assets carry a type; cached ones are public.
    // Why: brand assets cache long, the stylesheet not.
    #[test]
    fn assets_set_type_and_caching() {
        let plain = asset("text/css", false, b"x");
        assert_eq!(plain.headers()[header::CONTENT_TYPE], "text/css");
        assert!(plain.headers().get(header::CACHE_CONTROL).is_none());
        let cached = asset("image/png", true, b"x");
        assert_eq!(cached.headers()[header::CONTENT_TYPE], "image/png");
        assert_eq!(
            cached.headers()[header::CACHE_CONTROL],
            "public, max-age=31536000"
        );
    }

    // What: form fields are trimmed; absent ones are empty.
    // Why: a malformed number fails like a missing one.
    #[test]
    fn form_fields_trim_and_parse() {
        let fields = Fields(HashMap::from([
            ("a".to_string(), "  5 ".to_string()),
            ("b".to_string(), "x".to_string()),
        ]));
        assert_eq!(fields.get("a"), "5");
        assert_eq!(fields.get("none"), "");
        assert_eq!(fields.number::<u32>("a"), Some(5));
        assert_eq!(fields.number::<u32>("b"), None);
        assert_eq!(fields.number::<u32>("none"), None);
    }

    const TEXT_KEYS: [&str; 41] = [
        "STANDARD_LOG",
        "PROXY_STANDARD_URL",
        "STANDARD_IP",
        "SSL_IP",
        "NATS_URL",
        "DOCKER_PROXY_URL",
        "LANCACHE_IMAGE_TAG",
        "NTP_UPSTREAM_SERVERS",
        "TEMPLATE_DIR",
        "CDN_DOMAINS_FILE",
        "SSL_LOG",
        "CACHE_DIR",
        "DNS_STANDARD_STATE_DIR",
        "DNS_SSL_STATE_DIR",
        "PROXY_SSL_URL",
        "NETDATA_URL",
        "DNS_STANDARD_SERVICE",
        "DNS_SSL_SERVICE",
        "PROXY_SSL_SERVICE",
        "DHCP_API_URL",
        "DHCP_API_USER",
        "UI_SETTINGS_FILE",
        "KEA_CONFIG_SNAPSHOT_DIR",
        "DHCP_PROBE_REQUEST_FILE",
        "DHCP_PROBE_RESULT_FILE",
        "PDNS_AUTH_URL",
        "PDNS_REC_URL",
        "DNS_ROLLBACK_URL",
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
        "WATCHDOG_STATUS_FILE",
        "DESIRED_STATE_FILE",
        "LANCACHE_SHARED_SECRET_DIR",
    ];

    const NUMBER_KEYS: [(&str, &str); 5] = [
        ("UI_SESSION_TTL_SECONDS", "3600"),
        ("KEEP_KNOWN_GOOD_CONFIGS", "7"),
        ("UI_LOGS_MAX_ENTRIES", "250"),
        ("UI_LISTEN_PORT", "8081"),
        ("SYSLOG_MAX_GB", "3"),
    ];

    const FLAG_KEYS: [&str; 3] = ["SSL_ENABLED", "ALLOW_INSECURE_UI", "SYSLOG_ENABLED"];

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
        env
    }

    fn load_from(env: &HashMap<String, String>) -> Result<Config, String> {
        Config::load(&|key: &str| env.get(key).cloned())
    }

    // What: every key lands in its own config field.
    // Why: compose owns the values; a swap would misroute.
    #[test]
    fn config_load_maps_every_key_to_its_field() {
        let cfg = load_from(&full_env()).expect("a complete env loads");
        assert_eq!(cfg.standard_log, "v-STANDARD_LOG");
        assert_eq!(cfg.ssl_log, "v-SSL_LOG");
        assert_eq!(cfg.proxy_standard_url, "v-PROXY_STANDARD_URL");
        assert_eq!(cfg.proxy_ssl_url, "v-PROXY_SSL_URL");
        assert_eq!(cfg.standard_ip, "v-STANDARD_IP");
        assert_eq!(cfg.ssl_ip, "v-SSL_IP");
        assert_eq!(cfg.nats_url, "v-NATS_URL");
        assert_eq!(cfg.docker_proxy_url, "v-DOCKER_PROXY_URL");
        assert_eq!(cfg.lancache_image_tag, "v-LANCACHE_IMAGE_TAG");
        assert_eq!(cfg.template_dir, "v-TEMPLATE_DIR");
        assert_eq!(cfg.cdn_domains_file, "v-CDN_DOMAINS_FILE");
        assert_eq!(cfg.cache_dir, "v-CACHE_DIR");
        assert_eq!(cfg.dns_standard_state_dir, "v-DNS_STANDARD_STATE_DIR");
        assert_eq!(cfg.dns_ssl_state_dir, "v-DNS_SSL_STATE_DIR");
        assert_eq!(cfg.netdata_url, "v-NETDATA_URL");
        assert_eq!(cfg.dns_standard_service, "v-DNS_STANDARD_SERVICE");
        assert_eq!(cfg.dns_ssl_service, "v-DNS_SSL_SERVICE");
        assert_eq!(cfg.proxy_ssl_service, "v-PROXY_SSL_SERVICE");
        assert_eq!(cfg.dhcp_api_url, "v-DHCP_API_URL");
        assert_eq!(cfg.ui_settings_file, "v-UI_SETTINGS_FILE");
        assert_eq!(cfg.kea_config_snapshot_dir, "v-KEA_CONFIG_SNAPSHOT_DIR");
        assert_eq!(cfg.dhcp_probe_request_file, "v-DHCP_PROBE_REQUEST_FILE");
        assert_eq!(cfg.dhcp_probe_result_file, "v-DHCP_PROBE_RESULT_FILE");
        assert_eq!(
            cfg.pdns_auth_api,
            "v-PDNS_AUTH_URL/api/v1/servers/localhost"
        );
        assert_eq!(cfg.pdns_rec_api, "v-PDNS_REC_URL/api/v1/servers/localhost");
        assert_eq!(cfg.dns_rollback_url, "v-DNS_ROLLBACK_URL");
        assert_eq!(cfg.netdata_alarms_file, "v-NETDATA_ALARMS_FILE");
        assert_eq!(cfg.nats_issuer_seed_path, "v-NATS_ISSUER_SEED_PATH");
        assert_eq!(cfg.nats_xkey_seed_path, "v-NATS_XKEY_SEED_PATH");
        assert_eq!(cfg.lancache_image_registry, "v-LANCACHE_IMAGE_REGISTRY");
        assert_eq!(cfg.lancache_image_prefix, "v-LANCACHE_IMAGE_PREFIX");
        assert_eq!(cfg.nats_auth_callout_path, "v-NATS_AUTH_CALLOUT_PATH");
        assert_eq!(cfg.session_secret_file, "v-UI_SESSION_SECRET_FILE");
        assert_eq!(cfg.database_file, "v-UI_DATABASE_FILE");
        assert_eq!(
            cfg.registration_token_file,
            "v-SECONDARY_REGISTRATION_TOKEN_FILE"
        );
        assert_eq!(cfg.syslog_log_root, "v-SYSLOG_LOG_ROOT");
        assert_eq!(cfg.watchdog_status_file, "v-WATCHDOG_STATUS_FILE");
        assert_eq!(cfg.desired_state_file, "v-DESIRED_STATE_FILE");
        assert_eq!(cfg.shared_secret_dir, "v-LANCACHE_SHARED_SECRET_DIR");
        assert_eq!(cfg.ui_session_ttl_seconds, 3600);
        assert_eq!(cfg.kea_keep_known_good_configs, 7);
        assert_eq!(cfg.ui_logs_max_entries, 250);
        assert_eq!(cfg.listen_port, 8081);
        assert_eq!(cfg.syslog_max_gb, 3);
        assert!(cfg.ssl_enabled && cfg.allow_insecure_ui && cfg.syslog_enabled);
        assert_eq!(cfg.cache_max_gb, 50.0);
    }

    // What: unset optional keys take their default.
    // Why: the ui gets none of them from compose.
    #[test]
    fn config_load_defaults_for_optional_keys() {
        let cfg = load_from(&full_env()).unwrap();
        assert_eq!(cfg.auth_user, None);
        assert_eq!(cfg.auth_password, None);
        assert!(cfg.security_headers_enabled);
        assert_eq!(cfg.hsts_mode, HstsMode::Auto);
        assert!(!cfg.dev_mode);
        assert_eq!(cfg.secondary_registration_token, "");
        assert_eq!(cfg.advertised_nats_url, None);
        assert_eq!(cfg.nats.ui.user, "");
        assert_eq!(cfg.nats.ui.password, None);
        assert_eq!(cfg.lancache_image_channel, "latest");
        assert_eq!(cfg.pdns_api_key, "");
        assert_eq!(cfg.dhcp_api_token, "");
        assert_eq!(cfg.dhcp_mode(), DhcpMode::Disabled);
        let start = |key: &str| cfg.startup_settings[key].as_str();
        assert_eq!(start("DHCP_MODE"), "disabled");
        assert_eq!(start("DHCP_DNS_PRIMARY"), "v-STANDARD_IP");
        assert_eq!(start("DHCP_DNS_SECONDARY"), "v-SSL_IP");
        assert_eq!(start("NTP_UPSTREAM_SERVERS"), "v-NTP_UPSTREAM_SERVERS");
        assert_eq!(start("AUTO_UPDATE_ENABLED"), "0");
        assert_eq!(start("NTP_ENABLED"), "0");
        assert_eq!(start("NTP_AUTO_DHCP"), "0");
        assert_eq!(start("CACHE_MAX_GB"), "50");
        assert_eq!(start("LANCACHE_IMAGE_CHANNEL"), "latest");
        assert_eq!(start("DHCP_SUBNET_START"), "");
    }

    // What: set optional keys reach their fields.
    // Why: operators tune these without a code change.
    #[test]
    fn config_load_reads_optional_keys() {
        let mut env = full_env();
        let extra = [
            ("UI_AUTH_USER", "admin"),
            ("UI_AUTH_PASSWORD", "pw"),
            ("UI_SECURITY_HEADERS", "false"),
            ("UI_HSTS_MODE", "always"),
            ("LANCACHE_DEV_MODE", "1"),
            ("SECONDARY_REGISTRATION_TOKEN", "tok"),
            ("NATS_BIND_IP", "192.0.2.9"),
            ("NATS_UI_USER", "ui"),
            ("NATS_UI_PASSWORD", "ui-secret"),
            ("DHCP_API_TOKEN", "kea-token"),
            ("PDNS_API_KEY", "pdns-key"),
            ("NETDATA_ALARM_TOKEN", "alarm-token"),
            ("LANCACHE_IMAGE_CHANNEL", "nightly"),
            ("DHCP_MODE", "kea"),
            ("AUTO_UPDATE_ENABLED", "yes"),
            ("NTP_ENABLED", "on"),
            ("CACHE_MAX_GB", "75"),
            ("NETDATA_CONF_FILE", "/n/conf"),
            ("NETDATA_NOTIFY_FILE", "/n/notify"),
            ("NETDATA_TOKEN_FILE", "/n/token"),
            ("NETDATA_DAEMON_LOG", "/n/daemon"),
            ("NETDATA_HEALTH_LOG", "/n/health"),
            ("NETDATA_ALARM_UI_URL", "https://ui"),
            ("NETDATA_ALARM_MAX_TIME", "60"),
            ("NETDATA_ALARM_RECIPIENT", "ops"),
            ("NATS_ISSUER_SEED", "issuer"),
            ("NATS_XKEY_SEED", "xkey"),
        ];
        for (key, value) in extra {
            env.insert(key.to_string(), value.to_string());
        }
        let cfg = load_from(&env).unwrap();
        assert_eq!(cfg.auth_user.as_deref(), Some("admin"));
        assert_eq!(cfg.auth_password.as_deref(), Some("pw"));
        assert!(!cfg.security_headers_enabled);
        assert_eq!(cfg.hsts_mode, HstsMode::Always);
        assert!(cfg.dev_mode);
        assert_eq!(cfg.secondary_registration_token, "tok");
        assert_eq!(
            cfg.advertised_nats_url.as_deref(),
            None,
            "the internal v-NATS_URL has no port"
        );
        assert_eq!(cfg.nats.ui.user, "ui");
        assert_eq!(cfg.nats.ui.password.as_deref(), Some("ui-secret"));
        assert_eq!(cfg.dhcp_api_token, "kea-token");
        assert_eq!(cfg.pdns_api_key, "pdns-key");
        assert_eq!(cfg.netdata_alarm_token, "alarm-token");
        assert_eq!(cfg.lancache_image_channel, "nightly");
        assert_eq!(cfg.dhcp_mode(), DhcpMode::Kea);
        assert_eq!(cfg.startup_settings["AUTO_UPDATE_ENABLED"], "1");
        assert_eq!(cfg.startup_settings["NTP_ENABLED"], "1");
        assert_eq!(cfg.cache_max_gb, 75.0);
        assert_eq!(cfg.netdata_conf_file.as_deref(), Some("/n/conf"));
        assert_eq!(cfg.netdata_notify_file.as_deref(), Some("/n/notify"));
        assert_eq!(cfg.netdata_token_file.as_deref(), Some("/n/token"));
        assert_eq!(cfg.netdata_daemon_log.as_deref(), Some("/n/daemon"));
        assert_eq!(cfg.netdata_health_log.as_deref(), Some("/n/health"));
        assert_eq!(cfg.netdata_alarm_ui_url.as_deref(), Some("https://ui"));
        assert_eq!(cfg.netdata_alarm_max_time.as_deref(), Some("60"));
        assert_eq!(cfg.netdata_alarm_recipient.as_deref(), Some("ops"));
        assert_eq!(cfg.nats_issuer_seed.as_deref(), Some("issuer"));
        assert_eq!(cfg.nats_xkey_seed.as_deref(), Some("xkey"));
        env.insert("NATS_URL".to_string(), "nats://nats:4222".to_string());
        let cfg = load_from(&env).unwrap();
        assert_eq!(
            cfg.advertised_nats_url.as_deref(),
            Some("nats://192.0.2.9:4222")
        );
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

    // What: the saved setting beats the startup value.
    // Why: operators change settings live, no restart.
    #[test]
    fn saved_settings_beat_startup_values() {
        let dir = unique_temp_dir("settings");
        let file = dir.join("ui.conf");
        let mut env = full_env();
        env.insert(
            "UI_SETTINGS_FILE".to_string(),
            file.to_string_lossy().into_owned(),
        );
        env.insert("CACHE_MAX_GB".to_string(), "60".to_string());
        let cfg = load_from(&env).unwrap();
        assert_eq!(cfg.setting("DHCP_MODE"), "disabled");
        assert!(!cfg.flag("NTP_ENABLED"));
        assert_eq!(cfg.requested_cache_gb(), 60.0);
        assert_eq!(cfg.setting("NO_SUCH_KEY"), "");
        fs::write(
            &file,
            " DHCP_MODE=dnsmasq-proxy \nNTP_ENABLED = 1\nNTP_ENABLED=1\nCACHE_MAX_GB=abc\n",
        )
        .unwrap();
        assert_eq!(cfg.setting("DHCP_MODE"), "dnsmasq-proxy");
        assert_eq!(cfg.dhcp_mode(), DhcpMode::DnsmasqProxy);
        assert!(cfg.flag("NTP_ENABLED"));
        assert_eq!(cfg.requested_cache_gb(), 60.0);
        fs::write(&file, "CACHE_MAX_GB= 90 \nNTP_ENABLED=0\n").unwrap();
        assert_eq!(cfg.requested_cache_gb(), 90.0);
        assert!(!cfg.flag("NTP_ENABLED"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: saving rewrites known keys, keeps the others.
    // Why: one whole-file writer must not lose a setting.
    #[test]
    fn save_settings_rewrites_the_whole_file() {
        let dir = unique_temp_dir("save");
        let file = dir.join("ui.conf");
        let mut env = full_env();
        env.insert(
            "UI_SETTINGS_FILE".to_string(),
            file.to_string_lossy().into_owned(),
        );
        let cfg = load_from(&env).unwrap();
        cfg.save_settings(&[
            ("DHCP_MODE", " kea ".to_string()),
            ("DHCP_SUBNET_START", "   ".to_string()),
            ("NTP_ENABLED", "1".to_string()),
        ])
        .unwrap();
        let saved = fs::read_to_string(&file).unwrap();
        let mode = fs::metadata(&file).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o644);
        assert_eq!(
            saved,
            "DHCP_MODE=kea\nDHCP_DNS_PRIMARY=v-STANDARD_IP\nDHCP_DNS_SECONDARY=v-SSL_IP\n\
             LANCACHE_IMAGE_CHANNEL=latest\nAUTO_UPDATE_ENABLED=0\nNTP_ENABLED=1\n\
             NTP_UPSTREAM_SERVERS=v-NTP_UPSTREAM_SERVERS\nNTP_AUTO_DHCP=0\nCACHE_MAX_GB=50\n"
        );
        cfg.save_settings(&[("NTP_AUTO_DHCP", "1".to_string())])
            .unwrap();
        let again = fs::read_to_string(&file).unwrap();
        assert!(again.contains("DHCP_MODE=kea\n") && again.contains("NTP_AUTO_DHCP=1\n"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: Docker helpers act on allowlisted containers.
    // Why: an unlisted name is refused before Docker.
    // From: Issue #1592
    #[tokio::test]
    async fn docker_helpers_post_to_allowlisted_containers() {
        let replies = vec![
            (204, vec![]),
            (204, vec![]),
            (204, vec![]),
            (404, vec![]),
            (500, vec![]),
        ];
        let (base, server) = serve_canned(replies);
        let docker = DockerApi::new(&base);
        docker_restart(&docker, "proxy").await.unwrap();
        docker_start(&docker, "dns-ssl").await.unwrap();
        docker_stop_if_present(&docker, "lancache-nats")
            .await
            .unwrap();
        docker_stop_if_present(&docker, "ntp").await.unwrap();
        let failed = docker_stop_if_present(&docker, "ui").await.unwrap_err();
        assert!(format!("{failed:#}").contains("Failed to stop 'ui'"));
        for refused in ["watchdog", "syslog", "nope", ""] {
            assert!(container_name(refused).is_err(), "{refused:?}");
            assert!(docker_restart(&docker, refused).await.is_err());
            assert!(docker_start(&docker, refused).await.is_err());
            assert!(docker_stop_if_present(&docker, refused).await.is_err());
        }
        let seen = server.join().unwrap();
        let lines: Vec<&str> = seen.iter().filter_map(|r| r.lines().next()).collect();
        assert_eq!(
            lines,
            [
                "POST /containers/lancache-proxy/restart?t=5 HTTP/1.1",
                "POST /containers/lancache-dns-ssl/start HTTP/1.1",
                "POST /containers/lancache-nats/stop?t=10 HTTP/1.1",
                "POST /containers/lancache-ntp/stop?t=10 HTTP/1.1",
                "POST /containers/lancache-ui/stop?t=10 HTTP/1.1",
            ]
        );
    }

    // What: container_name maps short and full names.
    // Why: compose and the proxy policy spell both ways.
    #[test]
    fn container_names_resolve_short_and_full() {
        assert_eq!(container_name("proxy").unwrap(), "lancache-proxy");
        assert_eq!(container_name("lancache-ui").unwrap(), "lancache-ui");
        let err = container_name("watchdog").unwrap_err().to_string();
        assert!(err.contains("'watchdog'") && err.contains("allowlist"));
    }

    // What: only a Docker 404 reads as never created.
    // Why: a profile-gated service gives 404 on start.
    #[test]
    fn missing_containers_are_told_apart() {
        let missing = anyhow::Error::new(DockerError::Status(404)).context("start");
        assert!(container_never_created(&missing));
        let busy = anyhow::Error::new(DockerError::Status(500));
        assert!(!container_never_created(&busy));
        assert!(!container_never_created(&anyhow::anyhow!("other")));
    }

    // What: the watchdog document is fresh, stale, absent.
    // Why: the dashboard shows each case differently.
    // From: Issue #870
    #[test]
    fn watchdog_json_reports_fresh_stale_and_missing() {
        let dir = unique_temp_dir("watchdog-json");
        let file = dir.join("status.json");
        let path = file.to_string_lossy().into_owned();
        assert_eq!(watchdog_json(&path), json!({"state": "unavailable"}));
        fs::write(&file, "not json").unwrap();
        assert_eq!(watchdog_json(&path), json!({"state": "unavailable"}));
        let doc = r#"{"updated":"t1","interval_secs":30,"disk":{"cache":{"pct":10,"status":"green"}},
            "services":{"zeta":{"status":"red","health":"x","failures":2},
                        "lancache-ui":{"status":"green","health":"healthy","failures":0},
                        "alpha":{"status":"green","health":"","failures":0},
                        "lancache-proxy":{"status":"amber","health":"starting","failures":1}}}"#;
        fs::write(&file, doc).unwrap();
        let fresh = watchdog_json(&path);
        let names: Vec<&str> = fresh["services"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["lancache-proxy", "lancache-ui", "alpha", "zeta"]);
        assert_eq!(
            fresh["services"][0],
            json!({"name": "lancache-proxy", "label": "Proxy", "status": "amber",
                   "health": "starting", "failures": 1})
        );
        assert_eq!(fresh["services"][1]["label"], "Admin UI");
        assert_eq!(fresh["services"][2]["label"], "alpha");
        assert_eq!(fresh["state"], "fresh");
        assert_eq!(fresh["updated"], "t1");
        assert_eq!(fresh["disk"]["cache"]["pct"], 10);
        assert!(fresh.get("age_seconds").is_none());
        let old = SystemTime::now() - Duration::from_secs(1000);
        let handle = OpenOptions::new().write(true).open(&file).unwrap();
        handle.set_modified(old).unwrap();
        let stale = watchdog_json(&path);
        assert_eq!(stale["state"], "stale");
        let age = stale["age_seconds"].as_u64().unwrap();
        assert!((1000..1100).contains(&age), "age {age}");
        assert_eq!(stale["updated"], "t1");
        assert_eq!(stale["services"].as_array().unwrap().len(), 4);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: only absolute paths without dots-dots pass.
    // Why: the env supplies it; a relative path is a typo.
    #[test]
    fn paths_must_be_absolute_and_plain() {
        assert!(path_allowed("/a/b"));
        assert!(!path_allowed("a/b"));
        assert!(!path_allowed("/a/../b"));
        assert!(!path_allowed("/a..b"));
        assert!(!path_allowed(""));
    }

    // What: sizes and free space are read for real paths.
    // Why: a refused path reads 0 or unknown.
    #[test]
    fn cache_size_and_free_space_need_an_allowed_path() {
        let dir = unique_temp_dir("du");
        fs::write(dir.join("f"), vec![1u8; 4096]).unwrap();
        let path = dir.to_string_lossy().into_owned();
        let gb = du_gb(&path);
        assert!(gb > 0.0 && gb < 0.001, "{gb}");
        assert_eq!(du_gb("relative/dir"), 0.0);
        assert_eq!(du_gb("/no/such/dir/anywhere"), 0.0);
        assert!(cache_free_mib(&path).is_some());
        assert_eq!(cache_free_mib("relative/dir"), None);
        assert_eq!(cache_free_mib("/no/such/dir/anywhere"), None);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the cache buffer grows with the cache size.
    // Why: the cache manager overshoots max_size briefly.
    // From: Issue #1069
    #[test]
    fn cache_buffer_and_fit_have_exact_edges() {
        for (gb, buffer) in [
            (0, 512),
            (4, 512),
            (5, 1024),
            (6, 1024),
            (7, 2048),
            (900, 2048),
        ] {
            assert_eq!(cache_buffer_mib(gb), buffer, "{gb} GB");
        }
        assert!(cache_fits(10, 12 * 1024));
        assert!(!cache_fits(10, 12 * 1024 - 1));
        assert!(cache_fits(5, 6 * 1024));
        assert!(!cache_fits(5, 6 * 1024 - 1));
        assert!(cache_fits(1, 1536));
        assert!(!cache_fits(1, 1535));
        assert!(!cache_fits(1, 0));
        assert_eq!(largest_cache_gb(1536), Some(1));
        assert_eq!(largest_cache_gb(1535), None);
        assert_eq!(largest_cache_gb(0), None);
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

    // What: nginx stub_status text becomes typed counters.
    // Why: the dashboard shows a gap when nginx is down.
    #[tokio::test]
    async fn nginx_status_parses_the_stub_page() {
        let page = "Active connections: 291 \nserver accepts handled requests\n \
                    16630948 16630947 31070465 \nReading: 6 Writing: 179 Waiting: 106 \n";
        let (base, server) = serve_canned(vec![(200, page.as_bytes().to_vec())]);
        let client = http_client().unwrap();
        let status = nginx_status(&client, &base).await.expect("an answer");
        assert_eq!(
            serde_json::to_value(&status).unwrap(),
            json!({"active": 291, "accepts": 16630948, "handled": 16630947,
                   "requests": 31070465, "reading": 6, "writing": 179, "waiting": 106})
        );
        let seen = server.join().unwrap();
        assert!(seen[0].starts_with("GET /nginx_status HTTP/1.1"));
        let short = "Active connections: 1\nserver accepts handled requests\n 1 2\n";
        let (base, _server) = serve_canned(vec![(200, short.as_bytes().to_vec())]);
        let status = nginx_status(&client, &base).await.unwrap();
        assert_eq!((status.active, status.accepts, status.requests), (1, 0, 0));
        assert!(nginx_status(&client, "http://127.0.0.1:1").await.is_none());
    }

    // What: a log tail returns whole lines, oldest first.
    // Why: reading backwards must not cut the first line.
    #[test]
    fn log_tails_return_whole_lines_oldest_first() {
        let dir = unique_temp_dir("tail");
        let file = dir.join("log");
        let path = file.to_string_lossy().into_owned();
        assert!(tail_lines(&path, 5).is_empty());
        fs::write(&file, "a\nb\nc\nd\ne").unwrap();
        assert_eq!(tail_lines(&path, 3), ["c", "d", "e"]);
        assert_eq!(tail_lines(&path, 10), ["a", "b", "c", "d", "e"]);
        assert!(tail_lines(&path, 0).is_empty());
        let big: String = (0..5000)
            .map(|i| format!("line-{i:05} {}\n", "x".repeat(90)))
            .collect();
        fs::write(&file, &big).unwrap();
        let last = tail_lines(&path, 7);
        let first_wanted = format!("line-{:05} ", 4993);
        assert_eq!(last.len(), 7);
        assert!(last[0].starts_with(&first_wanted), "{:?}", last[0]);
        assert!(last[6].starts_with("line-04999 "));
        let all = tail_lines(&path, 6000);
        assert_eq!(all.len(), 5000);
        assert!(all[0].starts_with("line-00000 "));
        let _ = fs::remove_dir_all(&dir);
    }

    const HIT_LINE: &str = "192.0.2.1 - [10/Oct/2026:12:00:05 +0000] \"GET /a/b HTTP/1.1\" 200 2048 \"HIT\" \"steam.example\"";

    // What: an access-log line becomes a typed entry.
    // Why: the logs page renders fields, not raw text.
    #[test]
    fn access_log_lines_become_entries() {
        let dir = unique_temp_dir("parse-log");
        let file = dir.join("access.log");
        let path = file.to_string_lossy().into_owned();
        fs::write(&file, format!("garbage\n{HIT_LINE}\n")).unwrap();
        let entries = parse_log_tail(&path, 10);
        assert_eq!(entries.len(), 1);
        assert_eq!(
            serde_json::to_value(&entries[0]).unwrap(),
            json!({"ip": "192.0.2.1", "time": "10/Oct/2026:12:00:05 +0000", "method": "GET",
                   "path": "/a/b", "host": "steam.example", "status": 200,
                   "bytes_human": "2.0 KB", "cache_status": "HIT", "source": ""})
        );
        let _ = fs::remove_dir_all(&dir);
    }

    // What: nginx $time_local becomes epoch seconds.
    // Why: entries of two logs must order by real time.
    #[test]
    fn log_times_become_epoch_seconds() {
        assert_eq!(log_time_epoch("10/Oct/2026:12:00:00 +0000"), 1_791_633_600);
        assert_eq!(log_time_epoch("10/Oct/2026:12:00:00 +0200"), 1_791_626_400);
        assert_eq!(log_time_epoch("10/Oct/2026:12:00:00 -0130"), 1_791_639_000);
        assert_eq!(log_time_epoch("not a time"), 0);
    }

    fn log_line(second: u32, cache: &str, bytes: u64) -> String {
        format!(
            "192.0.2.1 - [10/Oct/2026:12:00:{second:02} +0000] \"GET /p{second} HTTP/1.1\" 200 {bytes} \"{cache}\" \"h\"\n"
        )
    }

    // What: two logs merge by time and carry their source.
    // Why: the cap applies after the merge.
    #[test]
    fn two_logs_merge_by_time_with_a_source_label() {
        let dir = unique_temp_dir("merge");
        let (standard, ssl) = (dir.join("std.log"), dir.join("ssl.log"));
        fs::write(
            &standard,
            format!("{}{}", log_line(5, "HIT", 1), log_line(1, "HIT", 1)),
        )
        .unwrap();
        fs::write(&ssl, log_line(3, "MISS", 1)).unwrap();
        let (std_path, ssl_path) = (
            standard.to_string_lossy().into_owned(),
            ssl.to_string_lossy().into_owned(),
        );
        let merged = merged_log_tail(&std_path, &ssl_path, 10);
        let seen: Vec<(&str, &str)> = merged
            .iter()
            .map(|e| (e.path.as_str(), e.source.as_str()))
            .collect();
        assert_eq!(
            seen,
            [("/p1", "Standard"), ("/p3", "SSL"), ("/p5", "Standard")]
        );
        let capped = merged_log_tail(&std_path, &ssl_path, 2);
        let paths: Vec<&str> = capped.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(paths, ["/p3", "/p5"]);
        let shared = merged_log_tail(&std_path, &std_path, 10);
        assert_eq!(shared.len(), 2);
        assert!(shared.iter().all(|e| e.source == "Shared"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: log totals count each line once per file.
    // Why: an identical path is counted once, not twice.
    #[test]
    fn log_stats_count_hits_and_bytes() {
        let dir = unique_temp_dir("stats");
        let (standard, ssl) = (dir.join("std.log"), dir.join("ssl.log"));
        let gib = 1_073_741_824;
        let mut text = String::new();
        text += &log_line(1, "HIT", gib);
        text += &log_line(2, "MISS", gib);
        text += &log_line(3, "EXPIRED", 0);
        text += &log_line(4, "BYPASS", 0);
        text += "not a log line\n";
        let mut bytes = text.into_bytes();
        bytes.extend_from_slice(b"\xff\xfe broken\n");
        bytes.extend_from_slice(log_line(6, "HIT", 0).as_bytes());
        fs::write(&standard, &bytes).unwrap();
        fs::write(&ssl, log_line(7, "MISS", 0)).unwrap();
        let (std_path, ssl_path) = (
            standard.to_string_lossy().into_owned(),
            ssl.to_string_lossy().into_owned(),
        );
        let stats = log_stats(&std_path, &ssl_path);
        assert_eq!(
            serde_json::to_value(&stats).unwrap(),
            json!({"hits": 2, "misses": 2, "expired": 1, "other": 1,
                   "total_bytes_gb": 2.0, "total_requests": 6, "hit_pct": 2.0 / 6.0 * 100.0})
        );
        let once = log_stats(&std_path, &std_path);
        assert_eq!(once.total_requests, 5);
        let none = log_stats("/no/such/log", "/no/such/log");
        assert_eq!((none.total_requests, none.hit_pct), (0, 0.0));
        let _ = fs::remove_dir_all(&dir);
    }

    fn syslog_entry(host: &str, timestamp: &str) -> SyslogEntry {
        SyslogEntry {
            timestamp: timestamp.to_string(),
            host: host.to_string(),
            program: "p".to_string(),
            message: format!("{host}-{timestamp}"),
        }
    }

    // What: a syslog line splits into time, program, text.
    // Why: a stack-trace line must not vanish.
    #[test]
    fn syslog_lines_split_or_stay_raw() {
        let line = "2026-10-10T10:00:00Z hostA prog[7]: the message: here";
        let parsed = parse_syslog_line("hostA", line).unwrap();
        assert_eq!(parsed.timestamp, "2026-10-10T10:00:00Z");
        assert_eq!(parsed.host, "hostA");
        assert_eq!(parsed.program, "prog[7]");
        assert_eq!(parsed.message, "the message: here");
        let raw = parse_syslog_line("hostB", "    at java.lang.Thread").unwrap();
        assert_eq!(raw.timestamp, "");
        assert_eq!(raw.program, "");
        assert_eq!(raw.host, "hostB");
        assert_eq!(raw.message, "    at java.lang.Thread");
        assert!(parse_syslog_line("h", "").is_none());
        assert!(parse_syslog_line("h", "   \t").is_none());
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

    // What: a merged tail keeps quiet hosts in view.
    // Why: a quiet host's only error must stay in view.
    // From: Issue #859
    #[test]
    fn fair_window_keeps_quiet_hosts() {
        assert!(fair_window(vec![], 5).is_empty());
        let mut entries: Vec<SyslogEntry> = (1..=5)
            .map(|n| syslog_entry("a", &format!("t{n}")))
            .collect();
        entries.push(syslog_entry("b", "t0"));
        let kept = fair_window(entries.clone(), 3);
        let seen: Vec<&str> = kept.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(seen, ["b-t0", "a-t4", "a-t5"]);
        let all = fair_window(entries.clone(), 100);
        assert_eq!(all.len(), 6);
        assert_eq!(all[0].message, "b-t0");
        assert_eq!(all[5].message, "a-t5");
        assert_eq!(fair_window(entries, 1).len(), 1);
        let many: Vec<SyslogEntry> = (0..30)
            .map(|n| syslog_entry("a", &format!("t{n:02}")))
            .collect();
        assert_eq!(fair_window(many, 25).len(), 25);
    }

    // What: host directories are listed sorted.
    // Why: the log page filter offers exactly these.
    #[test]
    fn syslog_hosts_are_the_sorted_directories() {
        let dir = unique_temp_dir("syslog-hosts");
        let root = dir.to_string_lossy().into_owned();
        fs::create_dir(dir.join("hostB")).unwrap();
        fs::create_dir(dir.join("hostA")).unwrap();
        fs::write(dir.join("stray-file"), "x").unwrap();
        assert_eq!(syslog_hosts(&root), ["hostA", "hostB"]);
        assert_eq!(
            syslog_host_dirs(&root),
            [dir.join("hostA"), dir.join("hostB")]
        );
        assert!(syslog_hosts("/no/such/store").is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the syslog tail merges hosts, checks the name.
    // Why: the URL gives the host; it must not escape.
    #[test]
    fn syslog_tail_merges_hosts_and_refuses_odd_names() {
        let dir = unique_temp_dir("syslog-tail");
        let root = dir.to_string_lossy().into_owned();
        for host in ["hostA", "hostB"] {
            fs::create_dir(dir.join(host)).unwrap();
        }
        let a = "2026-10-10T10:00:01Z hostA prog: a1\n2026-10-10T10:00:02Z hostA prog: a2\n";
        fs::write(dir.join("hostA/20261010.log"), a).unwrap();
        fs::write(
            dir.join("hostB/20261010.log"),
            "2026-10-10T10:00:03Z hostB prog: b1\n",
        )
        .unwrap();
        let messages = |entries: Vec<SyslogEntry>| -> Vec<String> {
            entries.into_iter().map(|e| e.message).collect()
        };
        assert_eq!(messages(syslog_tail(&root, None, 10)), ["a1", "a2", "b1"]);
        assert_eq!(messages(syslog_tail(&root, None, 2)), ["a2", "b1"]);
        assert_eq!(
            messages(syslog_tail(&root, Some("hostA"), 10)),
            ["a1", "a2"]
        );
        let host_b = syslog_tail(&root, Some("hostB"), 10);
        assert_eq!(
            (host_b[0].host.as_str(), host_b[0].program.as_str()),
            ("hostB", "prog")
        );
        assert!(syslog_tail(&root, None, 0).is_empty());
        for odd in ["", ".", "..", "a/b", "a\\b", "hostA\0"] {
            assert!(syslog_tail(&root, Some(odd), 10).is_empty(), "{odd:?}");
        }
        assert!(syslog_tail(&root, Some("nohost"), 10).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the early stop never hides a host with data.
    // Why: every host with files shows before the stop.
    // From: Issue #859
    #[test]
    fn syslog_tail_reads_every_host_before_stopping() {
        let dir = unique_temp_dir("syslog-stop");
        let root = dir.to_string_lossy().into_owned();
        for host in ["hostA", "hostB"] {
            fs::create_dir(dir.join(host)).unwrap();
        }
        let newer = "2026-10-10T10:00:05Z hostA prog: a5\n2026-10-10T10:00:06Z hostA prog: a6\n";
        fs::write(dir.join("hostA/20261011.log"), newer).unwrap();
        let older = "2026-10-10T10:00:01Z hostB prog: b1\n";
        fs::write(dir.join("hostB/20261010.log"), older).unwrap();
        let past = SystemTime::now() - Duration::from_secs(3600);
        let file = OpenOptions::new()
            .write(true)
            .open(dir.join("hostB/20261010.log"))
            .unwrap();
        file.set_modified(past).unwrap();
        let tail = syslog_tail(&root, None, 2);
        let messages: Vec<&str> = tail.iter().map(|e| e.message.as_str()).collect();
        assert_eq!(messages, ["b1", "a6"]);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: syslog stats count files, bytes and days.
    // Why: metadata only; the day is the name prefix.
    #[test]
    fn syslog_stats_count_files_bytes_and_days() {
        let dir = unique_temp_dir("syslog-stats");
        let root = dir.to_string_lossy().into_owned();
        fs::create_dir_all(dir.join("hostA/subdir")).unwrap();
        fs::write(dir.join("hostA/20261010.log"), "0123456789").unwrap();
        fs::write(dir.join("hostA/20261011.log.xz"), "01234").unwrap();
        fs::write(dir.join("hostA/20261011.log"), "0").unwrap();
        fs::write(dir.join("hostA/notes.txt"), "012").unwrap();
        fs::create_dir(dir.join("hostB")).unwrap();
        let stats = syslog_stats(&root);
        assert_eq!(
            serde_json::to_value(&stats).unwrap(),
            json!({"hosts": [
                {"host": "hostA", "files": 4, "size_bytes": 19, "days": 2, "size_human": "19 B"},
                {"host": "hostB", "files": 0, "size_bytes": 0, "days": 0, "size_human": "0 B"}],
                "total_files": 4, "total_size_bytes": 19})
        );
        let _ = fs::remove_dir_all(&dir);
    }

    fn alarm(id: i64) -> NetdataAlarm {
        NetdataAlarm {
            unique_id: id,
            name: format!("alarm-{id}"),
            ..NetdataAlarm::default()
        }
    }

    // What: stored alarms are newest first and capped.
    // Why: netdata resends; a burst must not grow the file.
    #[test]
    fn alarms_are_stored_once_newest_first_and_capped() {
        let dir = unique_temp_dir("alarms");
        let file = dir.join("alarms.json");
        let path = file.to_string_lossy().into_owned();
        assert!(read_alarms(&path).is_empty());
        fs::write(&file, "not json").unwrap();
        assert!(read_alarms(&path).is_empty());
        assert!(read_alarms(&dir.to_string_lossy()).is_empty());
        fs::remove_file(&file).unwrap();
        append_alarm(&path, alarm(1)).unwrap();
        append_alarm(&path, alarm(2)).unwrap();
        append_alarm(&path, alarm(1)).unwrap();
        let ids: Vec<i64> = read_alarms(&path).iter().map(|a| a.unique_id).collect();
        assert_eq!(ids, [2, 1]);
        assert_eq!(read_alarms(&path)[0], alarm(2));
        let mode = fs::metadata(&file).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o644);
        for id in 3..=60 {
            append_alarm(&path, alarm(id)).unwrap();
        }
        let kept = read_alarms(&path);
        assert_eq!(kept.len(), 50);
        assert_eq!(kept[0].unique_id, 60);
        assert_eq!(kept[49].unique_id, 11);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: alarm views carry a readable UTC time.
    // Why: this Tera version has no date filter.
    #[test]
    fn alarm_views_show_a_utc_time() {
        let mut first = alarm(7);
        first.when = 1_791_633_600;
        first.chart = "cpu".to_string();
        first.host = "h".to_string();
        first.status = "CRITICAL".to_string();
        first.value_string = "99%".to_string();
        first.info = "busy".to_string();
        let mut odd = alarm(8);
        odd.when = i64::MAX;
        let views = alarm_views(&[first, odd]);
        assert_eq!(
            views[0],
            json!({"unique_id": 7, "name": "alarm-7", "chart": "cpu", "host": "h",
                   "status": "CRITICAL", "value_string": "99%", "info": "busy",
                   "when_display": "2026-10-10T12:00:00Z"})
        );
        assert_eq!(views[1]["when_display"], "9223372036854775807");
        assert!(alarm_views(&[]).is_empty());
    }

    // What: the netdata sender script comes from fields.
    // Why: netdata and the ui must agree on the payload.
    // From: Issue #858
    #[test]
    fn alarm_sender_script_names_every_field() {
        let script = render_alarm_notify_conf("http://ui:8080", "/t/token", "30", "ops").unwrap();
        assert!(script.starts_with("SEND_CUSTOM=\"YES\"\nDEFAULT_RECIPIENT_CUSTOM=\"ops\"\n"));
        assert!(script.contains("token=\"$(cat \"/t/token\")\" || return 1"));
        assert!(script.contains("docurl --max-time 30 -X POST"));
        assert!(script.contains("-H \"X-Netdata-Alarm-Token: ${token}\""));
        assert!(script.contains("\"http://ui:8080/api/netdata-alarms\")\" || {"));
        assert!(script.contains("[ \"${httpcode}\" = \"200\" ] && return 0"));
        let fields = r#"-d "{\"alarm_id\":${alarm_id},\"chart\":\"$(_lancache_json_escape "${chart}")\",\"duration\":${duration},\"event_id\":${event_id},\"host\":\"$(_lancache_json_escape "${host}")\",\"info\":\"$(_lancache_json_escape "${info}")\",\"name\":\"$(_lancache_json_escape "${name}")\",\"old_status\":\"$(_lancache_json_escape "${old_status}")\",\"status\":\"$(_lancache_json_escape "${status}")\",\"unique_id\":${unique_id},\"units\":\"$(_lancache_json_escape "${units}")\",\"value_string\":\"$(_lancache_json_escape "${value_string}")\",\"when\":${when}}""#;
        assert!(script.contains(fields), "{script}");
        for (url, file, time, to) in [
            ("", "/t", "30", "ops"),
            ("http://ui", "", "30", "ops"),
            ("http://ui", "/t", "", "ops"),
            ("http://ui", "/t", "30", ""),
            ("http://ui", "/t y", "30", "ops"),
            ("http://ui", "/t", "30", "o\"ps"),
        ] {
            assert!(render_alarm_notify_conf(url, file, time, to).is_err());
        }
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

    // What: a test SOA answer for the lan. zone.
    // Why: the classifier reads real wire bytes.
    fn soa_response(id: u16, flags: [u8; 2], answers: u16, serial: u32) -> Vec<u8> {
        let mut msg = id.to_be_bytes().to_vec();
        msg.extend_from_slice(&flags);
        msg.extend_from_slice(&[0, 1]);
        msg.extend_from_slice(&answers.to_be_bytes());
        msg.extend_from_slice(&[0, 0, 0, 0]);
        msg.extend_from_slice(&[3, b'l', b'a', b'n', 0, 0, 6, 0, 1]);
        if answers > 0 {
            msg.extend_from_slice(&[0xC0, 12, 0, 6, 0, 1, 0, 0, 0, 60]);
            let mut rdata = vec![1, b'n', 0, 1, b'r', 0];
            rdata.extend_from_slice(&serial.to_be_bytes());
            rdata.extend_from_slice(&[0; 16]);
            msg.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
            msg.extend_from_slice(&rdata);
        }
        msg
    }

    // What: DNS names are skipped by labels and pointers.
    // Why: a bad label byte must end the parse.
    #[test]
    fn dns_names_are_skipped_by_labels_and_pointers() {
        assert_eq!(skip_dns_name(&[0], 0), Some(1));
        assert_eq!(skip_dns_name(&[3, b'a', b'b', b'c', 0], 0), Some(5));
        assert_eq!(skip_dns_name(&[9, 9, 2, b'a', b'b', 0], 2), Some(6));
        assert_eq!(skip_dns_name(&[0xC0, 12], 0), Some(2));
        assert_eq!(skip_dns_name(&[0x40, 1], 0), None);
        assert_eq!(skip_dns_name(&[0x80, 1], 0), None);
        assert_eq!(skip_dns_name(&[5, b'a'], 0), None);
        assert_eq!(skip_dns_name(&[], 0), None);
    }

    // What: the SOA serial is read from a good answer only.
    // Why: informational only; any oddity yields None.
    #[test]
    fn soa_serial_is_read_from_a_good_answer_only() {
        let good = soa_response(1, [0x84, 0], 1, 2_026_101_001);
        assert_eq!(soa_serial(&good), Some(2_026_101_001));
        assert_eq!(soa_serial(&good[..good.len() - 1]), Some(2_026_101_001));
        assert_eq!(soa_serial(&good[..good.len() - 17]), None);
        assert_eq!(soa_serial(&good[..30]), None);
        assert_eq!(soa_serial(&soa_response(1, [0x84, 0], 0, 0)), None);
        let mut wrong_type = good.clone();
        wrong_type[24] = 1;
        assert_eq!(soa_serial(&wrong_type), None);
        let mut short_rdata = good.clone();
        short_rdata[32] = 4;
        assert_eq!(soa_serial(&short_rdata), None);
        assert_eq!(soa_serial(&[]), None);
    }

    // What: each SOA answer maps to one operator status.
    // Why: AA flag and RCODE tell served-here from relayed.
    #[test]
    fn soa_answers_map_to_statuses() {
        let probe = |flags: [u8; 2], answers: u16| {
            classify_soa(&soa_response(9, flags, answers, 42), 9).unwrap()
        };
        let ok = probe([0x84, 0], 1);
        assert_eq!((ok.status, ok.serial), ("ok", Some(42)));
        assert_eq!(ok.detail, "answered authoritatively for lan. (SOA present)");
        let relayed = probe([0x80, 0], 1);
        assert_eq!(
            (relayed.status, relayed.serial),
            ("not_authoritative", Some(42))
        );
        let empty = probe([0x84, 0], 0);
        assert_eq!((empty.status, empty.serial), ("error", None));
        assert_eq!(empty.detail, "NOERROR but no answer for lan. SOA");
        let refused = probe([0x84, 5], 0);
        assert_eq!((refused.status, refused.serial), ("no_zone", None));
        let failed = probe([0x84, 2], 1);
        assert_eq!((failed.status, failed.serial), ("broken", None));
        let other = probe([0x84, 3], 0);
        assert_eq!(other.status, "error");
        assert_eq!(other.detail, "unexpected DNS response code (RCODE 3)");
        let wrong_id = classify_soa(&soa_response(9, [0x84, 0], 1, 1), 10);
        assert_eq!(
            wrong_id,
            Err("DNS response transaction id mismatch".to_string())
        );
        let query = classify_soa(&soa_response(9, [0x04, 0], 1, 1), 9);
        assert_eq!(
            query,
            Err("DNS message is not a response (QR bit unset)".to_string())
        );
        let short = classify_soa(&[0; 11], 0);
        assert_eq!(short, Err("short DNS response (<12 bytes)".to_string()));
    }

    // What: the SOA probe talks UDP and reports silence.
    // Why: a silent host is a status, not an error.
    #[tokio::test]
    async fn soa_probe_asks_over_udp_and_reports_the_answer() {
        let server = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let port = server.local_addr().unwrap().port();
        server
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 512];
            let (n, from) = server.recv_from(&mut buf).unwrap();
            let id = u16::from_be_bytes([buf[0], buf[1]]);
            server
                .send_to(&soa_response(id, [0x84, 0], 1, 77), from)
                .unwrap();
            buf[..n].to_vec()
        });
        let result = probe_secondary_soa(Ipv4Addr::LOCALHOST, port).await;
        assert_eq!((result.status, result.serial), ("ok", Some(77)));
        let query = handle.join().unwrap();
        assert_eq!(&query[2..], &soa_query(0, "lan")[2..]);
        let closed = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let free = closed.local_addr().unwrap().port();
        drop(closed);
        let gone = probe_secondary_soa(Ipv4Addr::LOCALHOST, free).await;
        assert_eq!(gone.status, "unreachable");
        assert!(
            gone.detail
                .starts_with(&format!("DNS query to 127.0.0.1:{free} failed"))
        );
    }

    // What: backoff doubles the delay up to a cap.
    // Why: one step serves every NATS retry loop.
    #[tokio::test(start_paused = true)]
    async fn backoff_doubles_up_to_the_cap() {
        let mut delay = Duration::from_secs(1);
        let max = Duration::from_secs(5);
        backoff(&mut delay, max).await;
        assert_eq!(delay, Duration::from_secs(2));
        backoff(&mut delay, max).await;
        assert_eq!(delay, Duration::from_secs(4));
        backoff(&mut delay, max).await;
        assert_eq!(delay, max);
    }

    // What: a Config with the five NATS roles filled in.
    // Why: nats.conf and the fragment render from it.
    fn nats_config() -> Config {
        load_from(&nats_env()).expect("a complete NATS env loads")
    }

    fn nats_env() -> HashMap<String, String> {
        let mut env = full_env();
        let extra = [
            ("NATS_UI_USER", "ui"),
            ("NATS_UI_PASSWORD", "pw-ui"),
            ("NATS_DNS_WRITER_USER", "dnsw"),
            ("NATS_DNS_WRITER_PASSWORD", "pw-dnsw"),
            ("NATS_DNS_REPLICA_USER", "dnsr"),
            ("NATS_DNS_REPLICA_PASSWORD", "pw-dnsr"),
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

    // What: a missing role password fails the whole set.
    // Why: nats.conf and the ui connection fail closed.
    #[test]
    fn a_role_without_a_password_fails_validation() {
        let mut env = full_env();
        env.insert("NATS_SYS_USER".to_string(), "sys".to_string());
        let cfg = load_from(&env).unwrap();
        let err = cfg.nats.validate().unwrap_err();
        assert_eq!(
            err,
            "Invalid NATS UI credentials: NATS username cannot be empty"
        );
    }

    // What: the auth_callout stanza lists the static users.
    // Why: static roles skip the callout; others use it.
    #[test]
    fn auth_callout_fragment_lists_every_static_user() {
        assert_eq!(
            render_auth_callout_fragment(&nats_config(), "ISS", "XK"),
            "auth_callout {\n  issuer: \"ISS\"\n  xkey: \"XK\"\n  auth_users: [\"ui\", \"dnsw\", \"dnsr\", \"callout\", \"sys\"]\n}\n"
        );
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

    // What: a JWT payload decodes or fails with a reason.
    // Why: the request is trusted by subject, no signature.
    #[test]
    fn jwt_payloads_decode_or_explain() {
        assert_eq!(decode_jwt_payload("a.e30.c"), Ok(json!({})));
        assert_eq!(
            decode_jwt_payload("a.b"),
            Err("malformed JWT: expected 3 dot-separated parts".to_string())
        );
        assert!(decode_jwt_payload("a.b.c.d").is_err());
        let bad_b64 = decode_jwt_payload("a.!!.c").unwrap_err();
        assert!(bad_b64.starts_with("failed to base64url-decode JWT payload"));
        let bad_json = decode_jwt_payload(&format!("a.{}.c", b64url(b"nope"))).unwrap_err();
        assert!(bad_json.starts_with("failed to parse JWT payload"));
    }

    // What: password hashes are Argon2id and verify.
    // Why: only the hash is stored; plaintext shows once.
    #[test]
    fn nats_passwords_hash_to_argon2id() {
        let hash = hash_nats_password("secret").unwrap();
        assert!(hash.starts_with("$argon2id$"), "{hash}");
        assert_ne!(hash, hash_nats_password("secret").unwrap());
        let parsed = PasswordHash::new(&hash).unwrap();
        assert!(
            Argon2::default()
                .verify_password(b"secret", &parsed)
                .is_ok()
        );
        assert!(
            Argon2::default()
                .verify_password(b"other", &parsed)
                .is_err()
        );
        let fresh = new_nats_password();
        assert_eq!(fresh.len(), 64);
        assert!(fresh.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_ne!(fresh, new_nats_password());
    }

    // What: the callout answer grants DNS-reader rights.
    // Why: a user JWT with reader rights, or an error.
    #[test]
    fn auth_callout_answers_grant_or_refuse() {
        let issuer = KeyPair::new_account();
        let now = unix_secs() as i64;
        let granted = auth_callout_response(&issuer, "srv", "UNKEY", Some("sec1")).unwrap();
        let outer = decode_jwt_payload(&granted).unwrap();
        assert_eq!(outer["iss"], issuer.public_key());
        assert_eq!(outer["sub"], "UNKEY");
        assert_eq!(outer["aud"], "srv");
        assert!((now..now + 5).contains(&outer["iat"].as_i64().unwrap()));
        assert_eq!(outer["nats"]["type"], "authorization_response");
        assert_eq!(outer["nats"]["version"], 2);
        assert!(outer["nats"].get("error").is_none());
        let user = decode_jwt_payload(outer["nats"]["jwt"].as_str().unwrap()).unwrap();
        assert_eq!(user["iss"], issuer.public_key());
        assert_eq!(user["sub"], "UNKEY");
        assert_eq!(user["aud"], "$G");
        assert_eq!(user["name"], "sec1");
        assert_eq!(
            user["exp"].as_i64().unwrap() - user["iat"].as_i64().unwrap(),
            7_776_000
        );
        assert_eq!(user["nats"]["pub"]["allow"], json!(dns_reader_publish()));
        assert_eq!(
            user["nats"]["sub"]["allow"],
            json!(["lancache.dns.>", "_INBOX.>"])
        );
        for key in ["subs", "data", "payload"] {
            assert_eq!(user["nats"][key], -1, "{key}");
        }
        assert_eq!(user["nats"]["type"], "user");
        assert_eq!(user["nats"]["version"], 2);
        let refused = auth_callout_response(&issuer, "srv", "UNKEY", None).unwrap();
        let outer = decode_jwt_payload(&refused).unwrap();
        assert_eq!(outer["nats"]["error"], "invalid secondary credentials");
        assert!(outer["nats"].get("jwt").is_none());
    }

    fn fields(pairs: &[(&str, &str)]) -> Fields {
        Fields(
            pairs
                .iter()
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect(),
        )
    }

    // What: Kea replies give a result code and text.
    // Why: Kea reports failures inside a 200 response.
    #[test]
    fn kea_replies_expose_code_and_text() {
        let ok = json!([{"result": 0, "text": "done"}]);
        assert_eq!((kea_code(&ok), kea_text(&ok)), (0, "done"));
        let bad = json!([{"result": 2}]);
        assert_eq!((kea_code(&bad), kea_text(&bad)), (2, "Kea error"));
        for odd in [json!([]), json!({}), json!([{"result": "x"}]), json!(null)] {
            assert_eq!(kea_code(&odd), 1, "{odd}");
            assert_eq!(kea_text(&odd), "Kea error");
        }
    }

    // What: subnet4 is found, edited or missing by level.
    // Why: each missing level gets its own debug message.
    #[test]
    fn subnet_lookup_names_the_missing_level() {
        let mut config = json!({"Dhcp4": {"subnet4": [{"id": 1}, {"id": 2, "subnet": "x"}]}});
        assert_eq!(subnets_in(&config).len(), 2);
        assert_eq!(subnets_mut(&mut config).unwrap().len(), 2);
        assert_eq!(find_subnet_mut(&mut config, 2).unwrap()["subnet"], "x");
        assert_eq!(
            find_subnet_mut(&mut config, 3).unwrap_err(),
            "subnet not found"
        );
        let mut none = json!({});
        assert!(subnets_in(&none).is_empty());
        assert_eq!(subnets_mut(&mut none).unwrap_err(), "Dhcp4 missing");
        let mut no_list = json!({"Dhcp4": {}});
        assert_eq!(subnets_mut(&mut no_list).unwrap_err(), "subnet4 missing");
        let mut bad = json!({"Dhcp4": {"subnet4": 5}});
        assert_eq!(subnets_mut(&mut bad).unwrap_err(), "subnet4 not an array");
        assert!(subnets_in(&bad).is_empty());
    }

    // What: options are told apart by space, name and code.
    // Why: dedicated fields own five; the rest are custom.
    #[test]
    fn dhcp_options_are_classified() {
        assert_eq!(text_of(&json!({"a": "x"}), "a", "d"), "x");
        assert_eq!(text_of(&json!({"a": 5}), "a", "d"), "d");
        assert_eq!(text_of(&json!({}), "a", "d"), "d");
        assert!(is_dhcp4_option(&json!({})));
        assert!(is_dhcp4_option(&json!({"space": "dhcp4"})));
        assert!(!is_dhcp4_option(&json!({"space": "vendor"})));
        for name in [
            "routers",
            "domain-name",
            "domain-search",
            "domain-name-servers",
            "ntp-servers",
        ] {
            assert!(is_managed_option(&json!({"name": name})), "{name}");
        }
        for code in [3, 6, 15, 42, 119] {
            assert!(is_managed_option(&json!({"code": code})), "{code}");
        }
        assert!(!is_managed_option(&json!({"code": 66})));
        assert!(!is_managed_option(
            &json!({"name": "routers", "space": "vendor"})
        ));
        assert!(!is_managed_option(&json!({"name": "tftp-server-name"})));
        let custom = |value: Value| is_custom_option(&value);
        assert!(custom(json!({"code": 66, "data": "tftp"})));
        assert!(custom(json!({"code": 1, "data": "x", "space": "dhcp4"})));
        assert!(custom(json!({"code": 254, "data": "x"})));
        assert!(!custom(json!({"code": 0, "data": "x"})));
        assert!(!custom(json!({"code": 255, "data": "x"})));
        assert!(!custom(json!({"code": 6, "data": "x"})));
        assert!(!custom(json!({"code": 66, "data": 5})));
        assert!(!custom(json!({"code": 66})));
        assert!(!custom(json!({"code": 66, "data": "x", "space": "vendor"})));
        assert_eq!(split_list("a, b  c,,d\te"), ["a", "b", "c", "d", "e"]);
        assert!(split_list(" , ").is_empty());
    }

    // What: a Kea subnet becomes the page read-model.
    // Why: options are found by name or code.
    #[test]
    fn kea_subnets_become_page_rows() {
        let subnet = json!({
            "id": 4, "subnet": "198.51.100.0/24", "valid-lifetime": 7200,
            "pools": [{"pool": "198.51.100.10 - 198.51.100.200"}],
            "option-data": [
                {"name": "routers", "data": "198.51.100.1"},
                {"code": 6, "data": "198.51.100.2, 198.51.100.3"},
                {"name": "domain-name", "data": "lan.example"},
                {"name": "ntp-servers", "data": "198.51.100.4"},
                {"space": "dhcp4", "code": 66, "data": "tftp"},
                {"space": "vendor", "name": "routers", "data": "wrong"}
            ]
        });
        let row = serde_json::to_value(read_subnet(&subnet)).unwrap();
        assert_eq!(
            row,
            json!({"id": 4, "subnet": "198.51.100.0/24", "pool_start": "198.51.100.10",
                   "pool_end": "198.51.100.200", "gateway": "198.51.100.1",
                   "dns_primary": "198.51.100.2", "dns_secondary": "198.51.100.3",
                   "ntp_servers": "198.51.100.4", "lease_time": 7200, "domain": "lan.example",
                   "custom_options": [{"code": 66, "data": "tftp"}]})
        );
        let bare = serde_json::to_value(read_subnet(&json!({}))).unwrap();
        assert_eq!(
            bare,
            json!({"id": 0, "subnet": "", "pool_start": "", "pool_end": "", "gateway": "",
                   "dns_primary": "", "dns_secondary": "", "ntp_servers": "",
                   "lease_time": 86400, "domain": "", "custom_options": []})
        );
        let single = json!({"pools": [{"pool": " 10.0.0.1 "}]});
        let one = read_subnet(&single);
        assert_eq!(
            (one.pool_start.as_str(), one.pool_end.as_str()),
            ("10.0.0.1", "")
        );
    }

    // What: reservations are listed flat with their subnet.
    // Why: Kea nests them per subnet; the page is flat.
    #[test]
    fn kea_reservations_are_listed_flat() {
        let config = json!({"Dhcp4": {"subnet4": [
            {"id": 1, "reservations": [
                {"hw-address": "AA-BB-CC-DD-EE-FF", "ip-address": "10.0.0.5", "hostname": "pc"},
                {}]},
            {"id": 2},
            {"id": 3, "reservations": [{"hw-address": "aabbccddeeff", "ip-address": "10.0.1.5"}]}
        ]}});
        let rows = serde_json::to_value(read_reservations(&config)).unwrap();
        assert_eq!(
            rows,
            json!([
                {"subnet_id": 1, "ip": "10.0.0.5", "mac": "aa:bb:cc:dd:ee:ff", "hostname": "pc"},
                {"subnet_id": 1, "ip": "?", "mac": "?", "hostname": ""},
                {"subnet_id": 3, "ip": "10.0.1.5", "mac": "aa:bb:cc:dd:ee:ff", "hostname": ""}
            ])
        );
        assert!(read_reservations(&json!({})).is_empty());
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
        assert_eq!(parse_cidr("10.1.2.3/0"), Some((0, 0)));
        for bad in [
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

    // What: interface and boot file names are plain.
    // Why: they land unquoted in dnsmasq's config lines.
    #[test]
    fn interface_and_boot_names_are_plain() {
        for good in ["eth0", " br-lan.100 ", "a_b"] {
            assert!(is_valid_interface_name(good), "{good}");
        }
        assert!(is_valid_interface_name(&"a".repeat(64)));
        for bad in ["", " ", "a b", "a/b", "a,b", "ä"] {
            assert!(!is_valid_interface_name(bad), "{bad:?}");
        }
        assert!(!is_valid_interface_name(&"a".repeat(65)));
        assert!(is_valid_boot_filename(" pxelinux.0 "));
        assert!(is_valid_boot_filename("dir/boot.efi"));
        assert!(is_valid_boot_filename(&"a".repeat(255)));
        for bad in ["", " ", "a,b", "a b", "a\tb", "a\u{7f}b", &"a".repeat(256)] {
            assert!(!is_valid_boot_filename(bad), "{bad:?}");
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

    fn form_with(key: &str, value: &str) -> Fields {
        let mut pairs = subnet_form();
        pairs.retain(|(k, _)| *k != key);
        pairs.push((key, value));
        fields(&pairs)
    }

    // What: the subnet form is checked field by field.
    // Why: pool, gateway and subnet depend on each other.
    #[test]
    fn subnet_form_is_validated_field_by_field() {
        let ok = validate_subnet(&fields(&subnet_form()));
        assert_eq!(ok, Ok((3600, (0xC633_6400, 0xFFFF_FF00))));
        let edge = validate_subnet(&form_with("lease_time", "60"));
        assert_eq!(edge.unwrap().0, 60);
        assert_eq!(
            validate_subnet(&form_with("lease_time", "604800"))
                .unwrap()
                .0,
            604_800
        );
        let lease_msg = Err("Lease time must be between 60 and 604800 seconds.");
        for bad in ["59", "604801", "x", ""] {
            assert_eq!(
                validate_subnet(&form_with("lease_time", bad)),
                lease_msg,
                "{bad:?}"
            );
        }
        let cidr_msg = "Invalid subnet: use a network such as 198.51.100.0/24 with host bits zero.";
        for bad in ["198.51.100.5/24", "x", ""] {
            assert_eq!(
                validate_subnet(&form_with("subnet", bad)),
                Err(cidr_msg),
                "{bad:?}"
            );
        }
        for (key, msg) in [
            ("pool_start", "Invalid pool start address."),
            ("pool_end", "Invalid pool end address."),
            ("gateway", "Invalid gateway address."),
            ("dns_primary", "Invalid primary DNS address."),
        ] {
            assert_eq!(validate_subnet(&form_with(key, "nope")), Err(msg), "{key}");
        }
        let secondary = validate_subnet(&form_with("dns_secondary", "nope"));
        assert_eq!(secondary, Err("Invalid secondary DNS address."));
        assert!(validate_subnet(&form_with("dns_secondary", "198.51.100.3")).is_ok());
        let range = "Pool and gateway must lie inside the subnet, and the pool start must not follow its end.";
        for (key, value) in [
            ("pool_start", "198.51.101.10"),
            ("pool_end", "198.51.101.200"),
            ("gateway", "198.51.101.1"),
            ("pool_start", "198.51.100.201"),
        ] {
            assert_eq!(
                validate_subnet(&form_with(key, value)),
                Err(range),
                "{key}={value}"
            );
        }
        let one = fields(&[
            ("subnet", "198.51.100.0/24"),
            ("pool_start", "198.51.100.9"),
            ("pool_end", "198.51.100.9"),
            ("gateway", "198.51.100.1"),
            ("dns_primary", "198.51.100.2"),
            ("lease_time", "60"),
        ]);
        assert!(validate_subnet(&one).is_ok());
        let ntp = validate_subnet(&form_with("ntp_servers", " , "));
        assert_eq!(
            ntp,
            Err("Invalid NTP servers: use a list of addresses or host names.")
        );
        assert!(validate_subnet(&form_with("ntp_servers", "198.51.100.4, pool.ntp.org")).is_ok());
        let domain = validate_subnet(&form_with("domain", "bad domain!"));
        assert_eq!(
            domain,
            Err("Invalid domain: use a plain DNS domain name (letters, digits, '-', '.').")
        );
        assert!(validate_subnet(&form_with("domain", "lan.example")).is_ok());
    }

    // What: the form values land in one subnet4 entry.
    // Why: add and edit share it; edit keeps options.
    #[test]
    fn subnet_form_is_written_into_the_entry() {
        let form = fields(&[
            ("subnet", "198.51.100.0/24"),
            ("pool_start", "198.51.100.10"),
            ("pool_end", "198.51.100.200"),
            ("gateway", "198.51.100.1"),
            ("dns_primary", "198.51.100.2"),
            ("dns_secondary", "198.51.100.3"),
            ("domain", "lan.example"),
        ]);
        let cidr = (0xC633_6400, 0xFFFF_FF00);
        let mut entry = json!({
            "id": 1, "interface": "eth0", "default-lease-time": 5, "max-lease-time": 6,
            "host-reservation-identifiers": ["hw-address"],
            "option-data": [
                {"name": "routers", "data": "old"},
                {"space": "dhcp4", "code": 66, "data": "tftp"}],
            "reservations": [
                {"ip-address": "198.51.100.50"}, {"ip-address": "192.0.2.5"}, {"hw-address": "x"}]
        });
        apply_subnet(&mut entry, &form, 7, 3600, "198.51.100.4", cidr).unwrap();
        assert_eq!(
            entry,
            json!({
                "id": 7, "interface": "eth0", "subnet": "198.51.100.0/24",
                "pools": [{"pool": "198.51.100.10 - 198.51.100.200"}],
                "valid-lifetime": 3600, "max-valid-lifetime": 7200,
                "option-data": [
                    {"space": "dhcp4", "code": 66, "data": "tftp"},
                    {"name": "routers", "data": "198.51.100.1"},
                    {"name": "domain-name-servers", "data": "198.51.100.2, 198.51.100.3"},
                    {"name": "domain-name", "data": "lan.example"},
                    {"name": "domain-search", "data": "lan.example"},
                    {"name": "ntp-servers", "data": "198.51.100.4"}],
                "reservations": [{"ip-address": "198.51.100.50"}, {"hw-address": "x"}]
            })
        );
        let mut plain = json!({});
        apply_subnet(&mut plain, &form, 1, 604_800, "", cidr).unwrap();
        assert_eq!(plain["max-valid-lifetime"], 604_800);
        assert!(plain.get("reservations").is_none());
        let names: Vec<&str> = plain["option-data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "routers",
                "domain-name-servers",
                "domain-name",
                "domain-search"
            ]
        );
        let same = fields(&[
            ("dns_primary", "198.51.100.2"),
            ("dns_secondary", "198.51.100.2"),
        ]);
        let mut dup = json!({});
        apply_subnet(&mut dup, &same, 1, 60, "", cidr).unwrap();
        assert_eq!(dup["option-data"][1]["data"], "198.51.100.2");
        let mut huge = json!({});
        let too_large = apply_subnet(&mut huge, &form, 1, u32::MAX, "", cidr);
        assert_eq!(too_large, Err("lease_time too large"));
        let mut scalar = json!(5);
        let not_object = apply_subnet(&mut scalar, &form, 1, 60, "", cidr);
        assert_eq!(not_object, Err("subnet not an object"));
    }

    // What: custom option keys, data and edits are checked.
    // Why: managed codes keep their own fields.
    #[test]
    fn custom_options_are_keyed_checked_and_edited() {
        assert!(matches!(
            custom_option_key(" 66 "),
            Ok(CustomOptionKey::Numeric(66))
        ));
        assert!(matches!(
            custom_option_key("next-server"),
            Ok(CustomOptionKey::Pxe("next-server"))
        ));
        assert!(matches!(
            custom_option_key("boot-file-name"),
            Ok(CustomOptionKey::Pxe("boot-file-name"))
        ));
        for managed in ["3", "6", "15", "42", "119"] {
            let err = custom_option_key(managed).err();
            assert_eq!(
                err,
                Some("option code is managed by dedicated subnet fields")
            );
        }
        assert_eq!(
            custom_option_key("0").err(),
            Some("option code must be between 1 and 254")
        );
        assert_eq!(
            custom_option_key("abc").err(),
            Some("option code must be a number")
        );
        assert_eq!(option_data("  x  "), Ok("x".to_string()));
        assert_eq!(option_data(" "), Err("option data must not be empty"));
        assert_eq!(option_data(&"a".repeat(1024)), Ok("a".repeat(1024)));
        assert_eq!(
            option_data(&"a".repeat(1025)),
            Err("option data is too long")
        );
        assert_eq!(option_data("a\nb"), Err("option data must fit on one line"));
        assert_eq!(option_data("a\rb"), Err("option data must fit on one line"));
        let next = CustomOptionKey::Pxe("next-server");
        assert_eq!(
            custom_option_data(next, " 10.0.0.9 "),
            Ok("10.0.0.9".to_string())
        );
        assert_eq!(
            custom_option_data(next, "host"),
            Err("next-server must be a valid IPv4 address")
        );
        let host = CustomOptionKey::Pxe("server-hostname");
        assert!(custom_option_data(host, &"h".repeat(64)).is_ok());
        assert_eq!(
            custom_option_data(host, &"h".repeat(65)),
            Err("value is too long for this field")
        );
        let file = CustomOptionKey::Pxe("boot-file-name");
        assert!(custom_option_data(file, &"f".repeat(128)).is_ok());
        assert_eq!(
            custom_option_data(file, &"f".repeat(129)),
            Err("value is too long for this field")
        );
        assert_eq!(
            custom_option_data(file, ""),
            Err("option data must not be empty")
        );
        let numeric = CustomOptionKey::Numeric(66);
        assert_eq!(
            custom_option_data(numeric, &"n".repeat(500)),
            Ok("n".repeat(500))
        );
        assert_eq!(
            custom_option_data(numeric, ""),
            Err("option data must not be empty")
        );
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

    // What: the NTP option is replaced, not rebuilt.
    // Why: the NTP sync must not touch gateway or DNS.
    #[test]
    fn subnet_ntp_is_replaced_in_place() {
        let mut subnet = json!({"option-data": [
            {"name": "routers", "data": "g"},
            {"name": "ntp-servers", "data": "old"},
            {"code": 42, "data": "old2"},
            {"space": "vendor", "code": 42, "data": "keep"}]});
        set_subnet_ntp(&mut subnet, "10.0.0.4").unwrap();
        assert_eq!(
            subnet["option-data"],
            json!([{"name": "routers", "data": "g"},
                   {"space": "vendor", "code": 42, "data": "keep"},
                   {"name": "ntp-servers", "data": "10.0.0.4"}])
        );
        set_subnet_ntp(&mut subnet, "").unwrap();
        assert_eq!(subnet["option-data"].as_array().unwrap().len(), 2);
        let mut none = json!({});
        assert_eq!(
            set_subnet_ntp(&mut none, "x"),
            Err("subnet option-data missing or not an array")
        );
    }

    // What: a reservation is added or updated by MAC.
    // Why: a repeated submit edits the device once.
    #[test]
    fn reservations_are_upserted_by_mac() {
        let mut subnet = json!({"id": 1});
        upsert_reservation(&mut subnet, "aa:bb:cc:dd:ee:ff", "10.0.0.5", "pc").unwrap();
        assert_eq!(
            subnet["reservations"],
            json!([{"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.0.5",
                    "hostname": "pc", "option-data": [], "client-classes": []}])
        );
        subnet["reservations"][0]["client-classes"] = json!(["x"]);
        subnet["reservations"][0]["hw-address"] = json!("AA-BB-CC-DD-EE-FF");
        upsert_reservation(&mut subnet, "aa:bb:cc:dd:ee:ff", "10.0.0.6", "pc2").unwrap();
        let list = subnet["reservations"].as_array().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(
            list[0],
            json!({"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.0.6",
                   "hostname": "pc2", "option-data": [], "client-classes": ["x"]})
        );
        upsert_reservation(&mut subnet, "11:22:33:44:55:66", "10.0.0.7", "").unwrap();
        assert_eq!(subnet["reservations"].as_array().unwrap().len(), 2);
        let mut scalar = json!(5);
        assert_eq!(
            upsert_reservation(&mut scalar, "m", "i", "h"),
            Err("subnet not an object")
        );
        let mut bad = json!({"reservations": 5});
        assert_eq!(
            upsert_reservation(&mut bad, "m", "i", "h"),
            Err("reservations not an array")
        );
        let mut odd = json!({"reservations": [{"hw-address": "aa:bb:cc:dd:ee:ff"}]});
        odd["reservations"][0] = json!("aa:bb:cc:dd:ee:ff");
        assert!(upsert_reservation(&mut odd, "aa:bb:cc:dd:ee:ff", "i", "h").is_ok());
    }

    // What: reservations need hw-address among the ids.
    // Why: such a reservation would never be matched.
    #[test]
    fn host_identifiers_must_include_hw_address() {
        assert!(identifiers_include_hw_address(&json!({})));
        assert!(identifiers_include_hw_address(&json!({"Dhcp4": {}})));
        let with = json!({"Dhcp4": {"host-reservation-identifiers": ["duid", "hw-address"]}});
        assert!(identifiers_include_hw_address(&with));
        let without = json!({"Dhcp4": {"host-reservation-identifiers": ["duid"]}});
        assert!(!identifiers_include_hw_address(&without));
        let scalar = json!({"Dhcp4": {"host-reservation-identifiers": "hw-address"}});
        assert!(!identifiers_include_hw_address(&scalar));
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

    // What: DHCP errors carry the DHCP area and a status.
    // Why: every DHCP failure returns to /dhcp alike.
    #[test]
    fn dhcp_errors_carry_status_and_area() {
        let bad = invalid("x");
        assert_eq!(bad.status, StatusCode::BAD_REQUEST);
        assert_eq!(bad.message, "x");
        assert_eq!(bad.area.href, "/dhcp");
        let broken = fail("y");
        assert_eq!(broken.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(broken.area.title, "DHCP Configuration Error");
        let custom = dhcp_error(StatusCode::CONFLICT, String::from("z"));
        assert_eq!(custom.status, StatusCode::CONFLICT);
    }

    const MARKER: &str = "# ==== lancache-ng: entries added via the Admin UI are appended below this exact line ====";

    fn cdn(text: &str) -> CdnDomain {
        parse_cdn_domain(text).expect("a valid entry")
    }

    // What: text splits into lines with their own endings.
    // Why: kept lines keep CRLF or LF; \r must not leak.
    #[test]
    fn text_splits_into_lines_with_terminators() {
        assert_eq!(
            split_terminated("a\r\nb\nc"),
            [("a", "\r\n"), ("b", "\n"), ("c", "")]
        );
        assert_eq!(split_terminated("\n"), [("", "\n")]);
        assert!(split_terminated("").is_empty());
    }

    // What: list lines parse to entries and print back.
    // Why: a leading ! marks a disabled shipped default.
    #[test]
    fn list_lines_parse_and_print_back() {
        let (domain, enabled) = stored_line(" !.steam.com ").unwrap();
        assert!(domain.wildcard_only && !enabled);
        assert_eq!(domain.domain, "steam.com");
        let (plain, on) = stored_line("Epic.COM").unwrap();
        assert!(!plain.wildcard_only && on);
        assert_eq!(plain.domain, "epic.com");
        for bad in ["com", "", "!!x.com", "bad_name.com", "# c.com"] {
            assert!(stored_line(bad).is_none(), "{bad:?}");
        }
        assert_eq!(stored_text(&cdn("steam.com"), true), "steam.com");
        assert_eq!(stored_text(&cdn("steam.com"), false), "!steam.com");
        assert_eq!(stored_text(&cdn(".steam.com"), true), ".steam.com");
        assert_eq!(stored_text(&cdn(".steam.com"), false), "!.steam.com");
    }

    // What: list rows split defaults from additions.
    // Why: no marker means an old file: all defaults.
    #[test]
    fn list_rows_split_defaults_from_additions() {
        let content = format!(
            "# comment\n\nsteam.com\n!epic.com\nbad_line!\n{MARKER}\n.custom.com\n!bad2\n  \n"
        );
        let rows = serde_json::to_value(domain_rows(&content)).unwrap();
        assert_eq!(
            rows,
            json!([
                {"raw": "steam.com", "display": "steam.com", "enabled": true, "is_default": true, "is_valid": true},
                {"raw": "!epic.com", "display": "epic.com", "enabled": false, "is_default": true, "is_valid": true},
                {"raw": "bad_line!", "display": "bad_line!", "enabled": true, "is_default": true, "is_valid": false},
                {"raw": ".custom.com", "display": ".custom.com", "enabled": true, "is_default": false, "is_valid": true},
                {"raw": "!bad2", "display": "bad2", "enabled": true, "is_default": false, "is_valid": false}
            ])
        );
        assert!(domain_rows("").is_empty());
    }

    // What: one entry is switched, once.
    // Why: a repeated click must not rewrite the file.
    #[test]
    fn list_entries_switch_once() {
        let text = "steam.com\n!epic.com\r\nweird line\n";
        assert_eq!(
            with_enabled(text, &cdn("epic.com"), true).as_deref(),
            Some("steam.com\nepic.com\r\nweird line\n")
        );
        assert_eq!(
            with_enabled(text, &cdn("steam.com"), false).as_deref(),
            Some("!steam.com\n!epic.com\r\nweird line\n")
        );
        assert_eq!(with_enabled(text, &cdn("steam.com"), true), None);
        assert_eq!(with_enabled(text, &cdn("epic.com"), false), None);
        assert_eq!(with_enabled(text, &cdn("other.com"), true), None);
        assert_eq!(with_enabled(text, &cdn(".steam.com"), false), None);
    }

    // What: an entry is added once, behind the marker.
    // Why: add re-enables a disabled entry, no repeat.
    #[test]
    fn list_entries_are_added_behind_the_marker() {
        let epic = cdn("epic.com");
        assert_eq!(
            with_added("", &epic).as_deref(),
            Some(format!("{MARKER}\nepic.com\n").as_str())
        );
        assert_eq!(
            with_added("steam.com\n", &epic).as_deref(),
            Some(format!("steam.com\n\n{MARKER}\nepic.com\n").as_str())
        );
        let marked = format!("steam.com\n\n{MARKER}\nold.com");
        assert_eq!(
            with_added(&marked, &epic).as_deref(),
            Some(format!("{marked}\nepic.com\n").as_str())
        );
        assert_eq!(
            with_added("!epic.com\n", &epic).as_deref(),
            Some("epic.com\n")
        );
        assert_eq!(with_added("epic.com\n", &epic), None);
        let wildcard = cdn(".epic.com");
        let both = with_added("epic.com\n", &wildcard).unwrap();
        assert!(both.ends_with(&format!("{MARKER}\n.epic.com\n")));
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

    // What: LAN names and records follow the zone rules.
    // Why: the ui may only touch records of its own zone.
    #[test]
    fn lan_names_and_records_follow_zone_rules() {
        assert_eq!(normalize_lan_name("xlan"), "xlan.lan.");
        assert_eq!(normalize_lan_name("a.LAN"), "a.lan.");
        assert!(is_lan_name("_k.lan.", true));
        assert!(!is_lan_name("_k.lan.", false));
        assert!(is_lan_name("*.lan.", false));
        assert!(!is_lan_name("lan", false));
        assert!(!is_lan_name("evil-lan.", false));
        let ok = |name: &str, kind: &str, content: &str, ttl: u32| {
            validate_lan_record(name, kind, content, ttl)
        };
        assert!(ok("h.lan.", "A", "10.0.0.1", 1).is_some());
        assert!(ok("h.lan.", "A", "10.0.0.1", 2_147_483_647).is_some());
        assert!(ok("h.lan.", "A", "10.0.0.1", 2_147_483_648).is_none());
        assert_eq!(
            ok("h.lan.", " mx ", "65535 mail", 60),
            Some(("MX", "65535 mail".to_string()))
        );
        assert!(ok("h.lan.", "MX", "65536 mail", 60).is_none());
        assert!(ok("h.lan.", "MX", "10 bad_name", 60).is_none());
        assert!(ok("h.lan.", "MX", "10", 60).is_none());
        assert!(ok("h.lan.", "CNAME", "bad_name", 60).is_none());
        assert!(ok("h.lan.", "CNAME", "", 60).is_none());
        assert!(ok("h.lan.", "AAAA", "10.0.0.1", 60).is_none());
        assert!(ok("h.lan.", "A", "2001:db8::1", 60).is_none());
        let long_ok = "t".repeat(64_986);
        assert!(ok("h.lan.", "TXT", &long_ok, 60).is_some());
        assert!(ok("h.lan.", "TXT", &"t".repeat(64_987), 60).is_none());
        assert!(ok("h.lan.", "TXT", "a\u{7}b", 60).is_none());
        assert!(ok("h.lan.", "PTR", "x", 60).is_none());
        assert_eq!(
            delete_record_type("TYPE65535"),
            Some("TYPE65535".to_string())
        );
        assert_eq!(delete_record_type("TYPE65536"), None);
        assert_eq!(delete_record_type("TYPE"), None);
        assert_eq!(delete_record_type(&"A".repeat(16)), Some("A".repeat(16)));
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

    // What: the resize refusal names the largest size.
    // Why: the operator needs a value that would pass.
    #[test]
    fn resize_refusals_name_the_largest_size() {
        assert_eq!(
            resize_rejection("/cache", 50, 10 * 1024),
            "50 GB would not leave a safety buffer at /cache (only 10 GB free there). \
             The largest value that currently passes is 8 GB."
        );
        assert_eq!(
            resize_rejection("/cache", 5, 1000),
            "Not enough free space at /cache for any cache size with a safety buffer (only 0 GB \
             free there). Free up disk space or choose a smaller size."
        );
        assert!(is_valid_ui_channel("stable") && is_valid_ui_channel("nightly"));
        for bad in ["edge", "latest", "", "Stable", "sha-1"] {
            assert!(!is_valid_ui_channel(bad), "{bad:?}");
        }
    }

    // What: a registration token is long enough in chars.
    // Why: this token alone gates remote registration.
    #[test]
    fn registration_tokens_need_thirty_two_characters() {
        let dir = unique_temp_dir("token-len");
        let file = dir.join("t").to_string_lossy().into_owned();
        let exact = "k".repeat(32);
        assert_eq!(registration_token(&exact, &file), Ok(exact));
        let short = registration_token(&"k".repeat(31), &file).unwrap_err();
        assert!(
            short.starts_with("SECONDARY_REGISTRATION_TOKEN is only 31 character(s)"),
            "{short}"
        );
        assert!(short.contains("minimum of 32"));
        let wide = "é".repeat(32);
        assert_eq!(registration_token(&wide, &file), Ok(wide));
        assert!(registration_token(&"é".repeat(31), &file).is_err());
        assert!(!Path::new(&file).exists(), "a real token creates no file");
        fs::write(&file, "short").unwrap();
        let kept = registration_token("", &file).unwrap_err();
        assert!(kept.contains("only 5 character(s)"), "{kept}");
        fs::write(&file, "CHANGE_ME_x").unwrap();
        let placeholder = registration_token("", &file).unwrap_err();
        assert!(
            placeholder.starts_with("secondary registration token:"),
            "{placeholder}"
        );
        assert!(placeholder.contains("placeholder; delete"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: start-up refuses half-set or missing auth.
    // Why: a half-set pair would run without a login.
    #[test]
    fn preflight_requires_auth_or_an_explicit_opt_out() {
        let with = |extra: &[(&str, &str)]| {
            let mut env = nats_env();
            for (key, value) in extra {
                env.insert(key.to_string(), value.to_string());
            }
            preflight(&load_from(&env).unwrap())
        };
        let both = [("UI_AUTH_USER", "admin"), ("UI_AUTH_PASSWORD", "pw")];
        assert_eq!(with(&both), Ok(Duration::from_secs(3600)));
        assert_eq!(
            with(&[("ALLOW_INSECURE_UI", "true")]),
            Ok(Duration::from_secs(3600))
        );
        let missing = with(&[("ALLOW_INSECURE_UI", "false")]).unwrap_err();
        assert!(
            missing.starts_with("Admin-UI authentication is required. Set UI_AUTH_USER"),
            "{missing}"
        );
        for half in [("UI_AUTH_USER", "admin"), ("UI_AUTH_PASSWORD", "pw")] {
            let err = with(&[half, ("ALLOW_INSECURE_UI", "true")]).unwrap_err();
            assert!(
                err.starts_with("UI_AUTH_USER and UI_AUTH_PASSWORD must either both be set"),
                "{err}"
            );
        }
        let broken =
            with(&[("NATS_UI_USER", "bad user"), ("ALLOW_INSECURE_UI", "true")]).unwrap_err();
        assert!(
            broken.starts_with("Invalid NATS UI credentials"),
            "{broken}"
        );
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
            ("DNS_STANDARD_STATE_DIR", "/s1"),
            ("DNS_SSL_STATE_DIR", "/s2"),
            ("KEA_CONFIG_SNAPSHOT_DIR", "/k"),
        ];
        for (key, value) in paths {
            env.insert(key.to_string(), value.to_string());
        }
        let cfg = load_from(&env).unwrap();
        let dirs = ui_written_dirs(&cfg, Path::new("/l/ui.log"));
        let want: Vec<PathBuf> = ["/a", "/b", "/c", "/d", "/k", "/l", "/s1", "/s2"]
            .iter()
            .map(PathBuf::from)
            .collect();
        assert_eq!(dirs, want);
        let bare = ui_written_dirs(&cfg, Path::new("ui.log"));
        assert_eq!(bare.len(), 7);
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

    // What: files are written only when they differ.
    // Why: reruns on every start must write nothing.
    #[test]
    fn prepared_files_are_written_once() {
        let dir = unique_temp_dir("put");
        let file = dir.join("conf");
        put(&file, "one", 0o600, None).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "one");
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        put(&file, "two", 0o644, None).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "two");
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o644
        );
        fs::write(dir.join("plain"), "x").unwrap();
        let blocked = put(&dir.join("plain/child"), "x", 0o644, None).unwrap_err();
        assert!(blocked.starts_with("cannot write "), "{blocked}");
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
        let http = lancache_ng::http_client().unwrap();
        let nats = async_nats::ConnectOptions::new()
            .retry_on_initial_connect()
            .connect("nats://127.0.0.1:1")
            .await
            .unwrap();
        let state = Arc::new(AppState {
            templates: load_templates(&cfg),
            docker: DockerApi::new(&cfg.docker_proxy_url),
            http_client: http.clone(),
            pdns: PowerDns::new(http, cfg.pdns_api_key.clone()),
            file_lock: Mutex::new(()),
            netdata_alarms_lock: Mutex::new(()),
            kea_config_lock: tokio::sync::Mutex::new(()),
            dhcp_probe_lock: tokio::sync::Mutex::new(()),
            nats,
            db: Mutex::new(open_database(&dir.join("ui.db").to_string_lossy()).unwrap()),
            ui_session_secret: [9u8; 32],
            ui_session_ttl: Duration::from_secs(3600),
            nats_issuer_public_key: String::new(),
            nats_callout_xkey_public_key: String::new(),
            config: cfg,
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(axum::serve(listener, router(state.clone())).into_future());
        (base, state, dir)
    }

    // What: open a session: cookie header and CSRF token.
    // Why: protected POSTs need both, like a browser has.
    async fn open_session(base: &str, state: &AppState) -> (String, String) {
        let response = reqwest::get(format!("{base}/static/admin.css"))
            .await
            .unwrap();
        let set = response.headers()[header::SET_COOKIE].to_str().unwrap();
        let pair = set.split(';').next().unwrap().to_string();
        let value = pair.strip_prefix("lancache_ui_session=").unwrap();
        let session = validate_session(value, &state.ui_session_secret).unwrap();
        (pair, session.csrf_token)
    }

    // What: the public routes and compiled-in assets.
    // Why: the probe and static files must not drift.
    #[tokio::test]
    async fn public_routes_serve_health_and_assets() {
        let (base, _state, dir) = test_server(|_| {}).await;
        let health = reqwest::get(format!("{base}/health")).await.unwrap();
        assert_eq!(health.status(), 200);
        assert_eq!(health.text().await.unwrap(), "ok");
        let cases = [
            ("/favicon.ico", "image/x-icon", true),
            ("/static/logo-icon.png", "image/png", true),
            ("/static/admin.css", "text/css; charset=utf-8", false),
            (
                "/static/chart.umd.min.js",
                "application/javascript; charset=utf-8",
                true,
            ),
        ];
        for (path, content_type, cached) in cases {
            let response = reqwest::get(format!("{base}{path}")).await.unwrap();
            assert_eq!(response.status(), 200, "{path}");
            assert_eq!(response.headers()[header::CONTENT_TYPE], content_type);
            assert_eq!(
                response.headers().get(header::CACHE_CONTROL).is_some(),
                cached,
                "{path}"
            );
            assert!(!response.bytes().await.unwrap().is_empty(), "{path}");
        }
        let _ = fs::remove_dir_all(&dir);
    }

    // What: security headers follow switch and scheme.
    // Why: HSTS over plain http would lock browsers out.
    #[tokio::test]
    async fn security_headers_follow_config_and_scheme() {
        let (base, _state, dir) = test_server(|_| {}).await;
        let client = reqwest::Client::new();
        let plain = client.get(format!("{base}/health")).send().await.unwrap();
        let headers = plain.headers();
        assert_eq!(headers["content-security-policy"], ADMIN_UI_CSP);
        assert_eq!(headers["x-content-type-options"], "nosniff");
        assert_eq!(headers["x-frame-options"], "DENY");
        assert_eq!(headers["referrer-policy"], "no-referrer");
        assert!(headers.get("strict-transport-security").is_none());
        let secure = client
            .get(format!("{base}/health"))
            .header("x-forwarded-proto", "https")
            .send()
            .await
            .unwrap();
        assert_eq!(
            secure.headers()["strict-transport-security"],
            "max-age=31536000; includeSubDomains"
        );
        let _ = fs::remove_dir_all(&dir);

        let (base, _state, dir) = test_server(|cfg| cfg.security_headers_enabled = false).await;
        let off = client.get(format!("{base}/health")).send().await.unwrap();
        assert!(off.headers().get("content-security-policy").is_none());
        assert!(off.headers().get("x-frame-options").is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    // What: Basic auth needs both parts to match.
    // Why: one correct half must never open the admin UI.
    #[tokio::test]
    async fn basic_auth_needs_user_and_password() {
        let (base, _state, dir) = test_server(|cfg| {
            cfg.auth_user = Some("op".to_string());
            cfg.auth_password = Some("pw".to_string());
        })
        .await;
        let client = reqwest::Client::new();
        let url = format!("{base}/static/admin.css");
        let denied = client.get(&url).send().await.unwrap();
        assert_eq!(denied.status(), 401);
        assert_eq!(
            denied.headers()[header::WWW_AUTHENTICATE],
            r#"Basic realm="LanCache Admin""#
        );
        for (user, pass) in [("op", "bad"), ("bad", "pw"), ("bad", "bad")] {
            let wrong = client
                .get(&url)
                .basic_auth(user, Some(pass))
                .send()
                .await
                .unwrap();
            assert_eq!(wrong.status(), 401, "{user}:{pass}");
        }
        let garbage = client
            .get(&url)
            .header(header::AUTHORIZATION, "Basic ***")
            .send()
            .await
            .unwrap();
        assert_eq!(garbage.status(), 401);
        let ok = client
            .get(&url)
            .basic_auth("op", Some("pw"))
            .send()
            .await
            .unwrap();
        assert_eq!(ok.status(), 200);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a session cookie is issued once, CSRF on POST.
    // Why: a post without the token must be refused.
    #[tokio::test]
    async fn sessions_and_csrf_gate_mutating_requests() {
        let (base, state, dir) = test_server(|_| {}).await;
        let client = reqwest::Client::new();
        let first = client
            .get(format!("{base}/static/admin.css"))
            .send()
            .await
            .unwrap();
        let set = first.headers()[header::SET_COOKIE].to_str().unwrap();
        assert!(set.starts_with("lancache_ui_session="));
        assert!(!set.contains("Secure"));
        let (cookie, csrf) = open_session(&base, &state).await;
        let again = client
            .get(format!("{base}/static/admin.css"))
            .header(header::COOKIE, &cookie)
            .send()
            .await
            .unwrap();
        assert!(again.headers().get(header::SET_COOKIE).is_none());
        let secure = client
            .get(format!("{base}/static/admin.css"))
            .header("x-forwarded-proto", "https")
            .send()
            .await
            .unwrap();
        assert!(
            secure.headers()[header::SET_COOKIE]
                .to_str()
                .unwrap()
                .contains("Secure")
        );

        let url = format!("{base}/api/secondary/none");
        let no_token = client
            .delete(&url)
            .header(header::COOKIE, &cookie)
            .send()
            .await
            .unwrap();
        assert_eq!(no_token.status(), 403);
        let wrong = client
            .delete(&url)
            .header(header::COOKIE, &cookie)
            .header("X-CSRF-Token", "nope")
            .send()
            .await
            .unwrap();
        assert_eq!(wrong.status(), 403);
        let by_header = client
            .delete(&url)
            .header(header::COOKIE, &cookie)
            .header("X-CSRF-Token", &csrf)
            .send()
            .await
            .unwrap();
        assert_eq!(by_header.status(), 404);
        let by_form = client
            .post(format!("{base}/api/secondary/none/rotate-token"))
            .header(header::COOKIE, &cookie)
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(format!("csrf_token={csrf}"))
            .send()
            .await
            .unwrap();
        assert_eq!(by_form.status(), 415);
        let bad_form = client
            .post(format!("{base}/api/secondary/none/rotate-token"))
            .header(header::COOKIE, &cookie)
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body("csrf_token=nope")
            .send()
            .await
            .unwrap();
        assert_eq!(bad_form.status(), 403);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: register a secondary with the shared token.
    // Why: a wrong token or half-set stack must not pass.
    #[tokio::test]
    async fn registration_checks_token_name_and_stack() {
        let (base, state, dir) = test_server(|cfg| {
            cfg.secondary_registration_token = "tok".to_string();
            cfg.advertised_nats_url = Some("nats://10.0.0.1:4222".to_string());
        })
        .await;
        let client = reqwest::Client::new();
        let url = format!("{base}/api/secondary/register");
        let post = |token: &str, name: &str, address: Option<&str>| {
            let body = json!({"token": token, "name": name, "address": address});
            client.post(&url).json(&body).send()
        };
        assert_eq!(post("tok", "sec-1", None).await.unwrap().status(), 503);
        fs::write(dir.join("ddns-tsig-key"), "  \n").unwrap();
        assert_eq!(post("tok", "sec-1", None).await.unwrap().status(), 503);
        fs::write(dir.join("ddns-tsig-key"), "tsigkey\n").unwrap();
        assert_eq!(post("bad", "sec-1", None).await.unwrap().status(), 401);
        for name in ["", "a_b", "a b", &"x".repeat(33)] {
            let response = post("tok", name, None).await.unwrap();
            assert_eq!(response.status(), 400, "{name:?}");
        }
        let long = "x".repeat(32);
        assert_eq!(post("tok", &long, None).await.unwrap().status(), 200);

        let ok = post("tok", "sec-1", Some("192.168.1.9")).await.unwrap();
        assert_eq!(ok.status(), 200);
        let body: Value = ok.json().await.unwrap();
        assert_eq!(body["nats_url"], "nats://10.0.0.1:4222");
        assert_eq!(body["nats_user"], "sec-1");
        assert_eq!(body["consumer_name"], "sec-1");
        assert_eq!(body["ddns_tsig_key"], "tsigkey");
        assert_eq!(body["proxy_ip"], "v-STANDARD_IP");
        assert_eq!(body["dns_xfr_primary"], "v-STANDARD_IP:5300");
        assert_eq!(body["pdns_api_key"], state.config.pdns_api_key.as_str());
        assert_eq!(body["image_registry"], "v-LANCACHE_IMAGE_REGISTRY");
        assert_eq!(body["image_prefix"], "v-LANCACHE_IMAGE_PREFIX");
        assert_eq!(
            body["image_channel"],
            state.config.lancache_image_channel.as_str()
        );
        assert_eq!(body["image_tag"], state.config.lancache_image_tag.as_str());
        let password = body["nats_password"].as_str().unwrap();
        assert_eq!(password.len(), 64);
        assert!(password.chars().all(|c| c.is_ascii_hexdigit()));
        let stored = |name: &str| -> Option<String> {
            with_db(&state, |db| {
                db.query_row(
                    "SELECT address FROM secondaries WHERE name = ?",
                    [name],
                    |row| row.get(0),
                )
            })
            .unwrap()
        };
        assert_eq!(stored("sec-1").as_deref(), Some("192.168.1.9"));
        // What: a public address is dropped, old one stays.
        let again = post("tok", "sec-1", Some("8.8.8.8")).await.unwrap();
        assert_eq!(again.status(), 200);
        assert_eq!(stored("sec-1").as_deref(), Some("192.168.1.9"));
        let _ = fs::remove_dir_all(&dir);

        let (base, _state, dir) = test_server(|cfg| {
            cfg.advertised_nats_url = Some("nats://10.0.0.1:4222".to_string());
        })
        .await;
        let open = reqwest::Client::new()
            .post(format!("{base}/api/secondary/register"))
            .json(&json!({"token": "", "name": "sec-1"}))
            .send()
            .await
            .unwrap();
        assert_eq!(open.status(), 401);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: no NATS URL means no registration.
    // Why: the internal URL is unreachable remotely.
    #[tokio::test]
    async fn registration_needs_an_advertised_nats_url() {
        let (base, _state, dir) = test_server(|cfg| {
            cfg.secondary_registration_token = "tok".to_string();
            cfg.advertised_nats_url = None;
        })
        .await;
        fs::write(dir.join("ddns-tsig-key"), "tsigkey").unwrap();
        let response = reqwest::Client::new()
            .post(format!("{base}/api/secondary/register"))
            .json(&json!({"token": "tok", "name": "sec-1"}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 503);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: manage registered secondaries over the router.
    // Why: address, token, health and removal edit one row.
    #[tokio::test]
    async fn secondaries_can_be_changed_and_removed() {
        let (base, state, dir) = test_server(|cfg| {
            cfg.secondary_registration_token = "tok".to_string();
            cfg.advertised_nats_url = Some("nats://10.0.0.1:4222".to_string());
        })
        .await;
        fs::write(dir.join("ddns-tsig-key"), "tsigkey").unwrap();
        let client = reqwest::Client::new();
        let register = client
            .post(format!("{base}/api/secondary/register"))
            .json(&json!({"token": "tok", "name": "sec-1"}))
            .send()
            .await
            .unwrap();
        assert_eq!(register.status(), 200);
        let (cookie, csrf) = open_session(&base, &state).await;
        let send = |method: reqwest::Method, path: &str, body: Value| {
            client
                .request(method, format!("{base}{path}"))
                .header(header::COOKIE, &cookie)
                .header("X-CSRF-Token", &csrf)
                .json(&body)
                .send()
        };
        let post = reqwest::Method::POST;

        let page = client
            .get(format!("{base}/secondaries"))
            .send()
            .await
            .unwrap();
        assert_eq!(page.status(), 200);
        assert!(page.text().await.unwrap().contains("sec-1"));

        let none = send(post.clone(), "/api/secondary/sec-1/health", json!({})).await;
        let none: Value = none.unwrap().json().await.unwrap();
        assert_eq!(none["status"], "no_address");
        let unknown = send(post.clone(), "/api/secondary/zzz/health", json!({})).await;
        assert_eq!(unknown.unwrap().status(), 404);

        let public = json!({"address": "8.8.8.8"});
        let refused = send(post.clone(), "/api/secondary/sec-1/address", public).await;
        assert_eq!(refused.unwrap().status(), 400);
        let lost = json!({"address": "10.0.0.5"});
        let missing = send(post.clone(), "/api/secondary/zzz/address", lost.clone()).await;
        assert_eq!(missing.unwrap().status(), 404);
        let set = send(post.clone(), "/api/secondary/sec-1/address", lost).await;
        let set: Value = set.unwrap().json().await.unwrap();
        assert_eq!(set, json!({"ok": true, "address": "10.0.0.5"}));

        let hash = |state: &AppState| -> String {
            with_db(state, |db| {
                db.query_row(
                    "SELECT nats_password_hash FROM secondaries WHERE name = 'sec-1'",
                    [],
                    |row| row.get(0),
                )
            })
            .unwrap()
        };
        let before = hash(&state);
        let bad = json!({"token": "bad"});
        let denied = send(post.clone(), "/api/secondary/sec-1/rotate-token", bad).await;
        assert_eq!(denied.unwrap().status(), 401);
        assert_eq!(hash(&state), before);
        let good = json!({"token": "tok"});
        let nobody = send(
            post.clone(),
            "/api/secondary/zzz/rotate-token",
            good.clone(),
        )
        .await;
        assert_eq!(nobody.unwrap().status(), 404);
        let rotated = send(post, "/api/secondary/sec-1/rotate-token", good).await;
        let rotated: Value = rotated.unwrap().json().await.unwrap();
        assert_eq!(rotated["nats_user"], "sec-1");
        assert_eq!(rotated["nats_password"].as_str().unwrap().len(), 64);
        assert_ne!(hash(&state), before);

        let delete = reqwest::Method::DELETE;
        let gone = send(delete.clone(), "/api/secondary/zzz", json!({})).await;
        assert_eq!(gone.unwrap().status(), 404);
        let removed = send(delete, "/api/secondary/sec-1", json!({})).await;
        let removed: Value = removed.unwrap().json().await.unwrap();
        assert_eq!(removed, json!({"ok": true}));
        let rows: i64 = with_db(&state, |db| {
            db.query_row("SELECT COUNT(*) FROM secondaries", [], |row| row.get(0))
        })
        .unwrap();
        assert_eq!(rows, 0);
        let _ = fs::remove_dir_all(&dir);
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
        let url = format!("{base}/api/netdata-alarms");
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
        assert_eq!(ok.status(), 200);
        let again = send(Some("secret-token"), alarm.to_string()).await.unwrap();
        assert_eq!(again.status(), 200);
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
            .post(format!("{base}/api/netdata-alarms"))
            .header("X-Netdata-Alarm-Token", "")
            .body(alarm.to_string())
            .send()
            .await
            .unwrap();
        assert_eq!(open.status(), 401);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: an unwritable alarm file is reported as 503.
    // Why: netdata retries instead of losing the alarm.
    #[tokio::test]
    async fn alarm_ingest_reports_a_store_failure() {
        let dir = unique_temp_dir("alarm-blocked");
        let blocker = dir.join("file").to_string_lossy().to_string();
        fs::write(&blocker, "x").unwrap();
        let (base, _state, dir) = test_server(|cfg| {
            cfg.netdata_alarm_token = "t".to_string();
            cfg.netdata_alarms_file = format!("{}/x/alarms.json", blocker);
        })
        .await;
        let response = reqwest::Client::new()
            .post(format!("{base}/api/netdata-alarms"))
            .header("X-Netdata-Alarm-Token", "t")
            .body(
                r#"{"unique_id": 1, "alarm_id": 1, "event_id": 1, "when": 1,
                "name": "n", "chart": "c", "host": "h", "status": "s",
                "old_status": "o", "value_string": "v", "units": "u",
                "info": "i", "duration": 1}"#,
            )
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 503);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the netdata proxy forwards two paths only.
    // Why: a client may not choose another upstream path.
    #[tokio::test]
    async fn netdata_proxy_forwards_data_and_charts_only() {
        let (upstream, seen) =
            serve_canned(vec![(200, b"{\"x\":1}".to_vec()), (404, b"gone".to_vec())]);
        let (base, _state, dir) = test_server(move |cfg| cfg.netdata_url = upstream).await;
        let client = reqwest::Client::new();
        let get = |path: &str| client.get(format!("{base}/api/netdata/{path}")).send();
        for bad in ["a..b", "a%2fb"] {
            assert_eq!(get(bad).await.unwrap().status(), 400, "{bad}");
        }
        assert_eq!(get("other").await.unwrap().status(), 404);
        assert_eq!(get("DATA").await.unwrap().status(), 404);
        let data = get("data?b=2&a=1").await.unwrap();
        assert_eq!(data.status(), 200);
        assert_eq!(data.headers()[header::CONTENT_TYPE], "application/json");
        assert_eq!(data.text().await.unwrap(), "{\"x\":1}");
        let charts = get("charts").await.unwrap();
        assert_eq!(charts.status(), 404);
        assert_eq!(charts.text().await.unwrap(), "gone");
        let requests = seen.join().unwrap();
        assert!(requests[0].starts_with("GET /api/v1/data?a=1&b=2 "));
        assert!(requests[1].starts_with("GET /api/v1/charts"));
        let _ = fs::remove_dir_all(&dir);
    }

    // What: the proxy caps the buffered upstream body.
    // Why: a wide chart range must not exhaust memory.
    #[tokio::test]
    async fn netdata_proxy_caps_the_body_at_16_mib() {
        const CAP: usize = 16 * 1024 * 1024;
        let (upstream, seen) = serve_canned(vec![(200, vec![b'x'; CAP])]);
        let (base, _state, dir) = test_server(move |cfg| cfg.netdata_url = upstream).await;
        let client = reqwest::Client::new();
        let at_cap = client
            .get(format!("{base}/api/netdata/data"))
            .send()
            .await
            .unwrap();
        assert_eq!(at_cap.status(), 200);
        assert_eq!(at_cap.bytes().await.unwrap().len(), CAP);
        seen.join().unwrap();
        let _ = fs::remove_dir_all(&dir);

        let (upstream, seen) = serve_canned(vec![(200, vec![b'x'; CAP + 1])]);
        let (base, _state, dir) = test_server(move |cfg| cfg.netdata_url = upstream).await;
        let over = client
            .get(format!("{base}/api/netdata/data"))
            .send()
            .await
            .unwrap();
        assert_eq!(over.status(), 502);
        let _ = seen.join();
        let _ = fs::remove_dir_all(&dir);

        let (base, _state, dir) =
            test_server(|cfg| cfg.netdata_url = "http://127.0.0.1:1".to_string()).await;
        let down = client
            .get(format!("{base}/api/netdata/charts"))
            .send()
            .await
            .unwrap();
        assert_eq!(down.status(), 502);
        let _ = fs::remove_dir_all(&dir);
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
    // Why: protected forms need both; redirects stay.
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
                .post(format!("{base}/api/services/{service}/desired-state"))
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
            let response = post_form(&base, &session, "/cache/resize", bad).await;
            assert_eq!(response.status(), 400, "{bad}");
            assert!(
                response
                    .text()
                    .await
                    .unwrap()
                    .contains("positive whole number")
            );
        }
        let huge = post_form(&base, &session, "/cache/resize", "cache_gb=99999999").await;
        assert_eq!(huge.status(), 400);
        assert!(
            huge.text()
                .await
                .unwrap()
                .contains("would not leave a safety buffer")
        );
        assert!(!conf.exists());
        let ok = post_form(&base, &session, "/cache/resize", "cache_gb=1").await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/");
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
        let unknown = post_form(&base, &session, "/cache/resize", "cache_gb=1").await;
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
            "/setup/update",
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
        let ok = post_form(&base, &session, "/setup/update", body).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/setup");
        let saved = fs::read_to_string(&conf).unwrap();
        assert!(saved.contains("LANCACHE_IMAGE_CHANNEL=nightly\n"));
        assert!(saved.contains("AUTO_UPDATE_ENABLED=1\n"));
        let off = post_form(
            &base,
            &session,
            "/setup/update",
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

    // What: NTP settings are checked, saved and applied.
    // Why: the container reads its settings only at start.
    #[tokio::test]
    async fn ntp_settings_stop_save_and_start_ntp() {
        let dir = unique_temp_dir("ntp-settings");
        let conf = dir.join("ui.conf");
        let settings = conf.to_string_lossy().to_string();
        let (docker, seen) = serve_canned(vec![(204, vec![]), (204, vec![])]);
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.ui_settings_file = settings;
            cfg.docker_proxy_url = docker;
        })
        .await;
        let session = open_session(&base, &state).await;
        let empty = post_form(&base, &session, "/ntp/settings", "ntp_upstream_servers=").await;
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
            "/ntp/settings",
            "ntp_upstream_servers=bad%20host!",
        )
        .await;
        assert_eq!(bad.status(), 400);
        assert!(bad.text().await.unwrap().contains("is not a valid"));
        assert!(!conf.exists());
        let on = "ntp_enabled=1&ntp_upstream_servers=pool.ntp.org%2C+10.0.0.1";
        let ok = post_form(&base, &session, "/ntp/settings", on).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/ntp");
        let saved = fs::read_to_string(&conf).unwrap();
        assert!(saved.contains("NTP_ENABLED=1\n"));
        assert!(saved.contains("NTP_UPSTREAM_SERVERS=pool.ntp.org 10.0.0.1\n"));
        assert!(saved.contains("NTP_AUTO_DHCP=0\n"));
        let off = post_form(
            &base,
            &session,
            "/ntp/settings",
            "ntp_upstream_servers=10.0.0.1",
        )
        .await;
        assert_eq!(off.status(), 303);
        assert!(
            fs::read_to_string(&conf)
                .unwrap()
                .contains("NTP_ENABLED=0\n")
        );
        let requests = seen.join().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].contains("/start "));
        assert!(requests[1].contains("/stop?t=10 "));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: AAAA and DDNS markers appear in both DNS dirs.
    // Why: both DNS nodes must see the requested state.
    #[tokio::test]
    async fn dns_marker_toggles_write_both_state_dirs() {
        let dir = unique_temp_dir("markers");
        let (standard, ssl) = (dir.join("standard"), dir.join("ssl"));
        fs::create_dir_all(&standard).unwrap();
        fs::create_dir_all(&ssl).unwrap();
        let (a, b) = (
            standard.to_string_lossy().to_string(),
            ssl.to_string_lossy().to_string(),
        );
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.dns_standard_state_dir = a;
            cfg.dns_ssl_state_dir = b;
        })
        .await;
        let session = open_session(&base, &state).await;
        let on = post_form(&base, &session, "/domains/aaaa-filter", "enabled=1").await;
        assert_eq!(on.status(), 303);
        assert_eq!(on.headers()[header::LOCATION], "/domains");
        for root in [&standard, &ssl] {
            assert_eq!(
                fs::read_to_string(root.join("aaaa-filter-enabled")).unwrap(),
                "1"
            );
        }
        let off = post_form(&base, &session, "/domains/aaaa-filter", "enabled=0").await;
        assert_eq!(off.status(), 303);
        for root in [&standard, &ssl] {
            assert!(!root.join("aaaa-filter-enabled").exists());
        }
        let again = post_form(&base, &session, "/domains/aaaa-filter", "enabled=0").await;
        assert_eq!(again.status(), 303);

        let blocked = post_form(
            &base,
            &session,
            "/domains/ddns-allow-unsigned-updates",
            "enabled=1",
        )
        .await;
        assert_eq!(
            blocked.headers()[header::LOCATION],
            "/domains?error=ddns_allow_unsigned_no_key"
        );
        assert!(!standard.join("ddns-allow-unsigned-updates").exists());
        fs::write(sdir.join("ddns-tsig-key"), "tsig").unwrap();
        let allowed = post_form(
            &base,
            &session,
            "/domains/ddns-allow-unsigned-updates",
            "enabled=1",
        )
        .await;
        assert_eq!(allowed.headers()[header::LOCATION], "/domains");
        for root in [&standard, &ssl] {
            assert!(root.join("ddns-allow-unsigned-updates").exists());
        }
        let revoked = post_form(
            &base,
            &session,
            "/domains/ddns-allow-unsigned-updates",
            "enabled=0",
        )
        .await;
        assert_eq!(revoked.headers()[header::LOCATION], "/domains");
        assert!(!standard.join("ddns-allow-unsigned-updates").exists());
        fs::remove_file(sdir.join("ddns-tsig-key")).unwrap();
        fs::write(sdir.join("ddns-tsig-key"), "").unwrap();
        let empty = post_form(
            &base,
            &session,
            "/domains/ddns-allow-unsigned-updates",
            "enabled=1",
        )
        .await;
        assert_eq!(
            empty.headers()[header::LOCATION],
            "/domains?error=ddns_allow_unsigned_no_key"
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
        let bad = post_form(&base, &session, "/dhcp/subnet/add", "subnet=x").await;
        assert_eq!(bad.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let ok = post_form(&base, &session, "/dhcp/subnet/add", &subnet_body()).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/dhcp");
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
        let off = post_form(&base, &session, "/dhcp/subnet/remove", "id=1").await;
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
        let none = post_form(&base, &session, "/dhcp/subnet/remove", "id=1").await;
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
        let missing = post_form(&base, &session, "/dhcp/subnet/remove", "x=1").await;
        assert_eq!(missing.status(), 400);
        let ok = post_form(&base, &session, "/dhcp/subnet/remove", "id=1").await;
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
            async move { post_form(&base, &session, "/dhcp/static/add", &body).await }
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
            "/dhcp/static/add",
            "mac=aa:bb:cc:dd:ee:ff&ip=198.51.100.50",
        )
        .await;
        assert_eq!(nosubnet.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let unknown = post_form(
            &base,
            &session,
            "/dhcp/static/add",
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
            async move { post_form(&base, &session, "/dhcp/static/remove", &body).await }
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
            "/dhcp/static/add",
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
        let failed = post_form(&base, &session, "/dhcp/subnet/remove", "id=1").await;
        assert_eq!(failed.status(), 500);
        assert!(failed.text().await.unwrap().contains("boom"));
        assert_eq!(kea_commands(&kea), ["config-get", "config-test"]);
        assert!(kea_store(&state.config).ids().unwrap().is_empty());
        let _ = fs::remove_dir_all(&dir);

        let (base, state, kea, dir) =
            kea_test_server(kea_config_sample(), vec![("config-write", refuse)]).await;
        let session = open_session(&base, &state).await;
        let failed = post_form(&base, &session, "/dhcp/subnet/remove", "id=1").await;
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
        let bad = post_form(&base, &session, "/dhcp/lease/release", "ip=nope").await;
        assert_eq!(bad.status(), 400);
        assert!(kea_commands(&kea).is_empty());
        let ok = post_form(&base, &session, "/dhcp/lease/release", "ip=198.51.100.20").await;
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
        let missing = post_form(&base, &session, "/dhcp/lease/release", "ip=198.51.100.20").await;
        assert_eq!(missing.status(), 404);
        assert!(missing.text().await.unwrap().contains("No active lease"));
        let _ = fs::remove_dir_all(&dir);

        let broken = json!([{"result": 1, "text": "kea broke"}]);
        let (base, state, _kea, dir) =
            kea_test_server(kea_config_sample(), vec![("lease4-del", broken)]).await;
        let session = open_session(&base, &state).await;
        let failed = post_form(&base, &session, "/dhcp/lease/release", "ip=198.51.100.20").await;
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
        let page = reqwest::get(format!("{base}/dhcp")).await.unwrap();
        assert_eq!(page.status(), 200);
        let html = page.text().await.unwrap();
        assert!(html.contains("198.51.100.20"));
        assert!(html.contains("198.51.100.0/24"));
        assert!(kea_commands(&kea).contains(&"config-get".to_string()));
        let _ = fs::remove_dir_all(&dir);

        let (base, _state, kea, dir) = kea_test_server(kea_config_sample(), vec![]).await;
        fs::write(dir.join("ui.conf"), "DHCP_MODE=disabled\n").unwrap();
        let page = reqwest::get(format!("{base}/dhcp")).await.unwrap();
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
        let unknown = post_form(
            &base,
            &session,
            "/dhcp/snapshot/rollback",
            "snapshot_id=nope",
        )
        .await;
        assert_eq!(unknown.status(), 409);
        assert!(kea_commands(&kea).is_empty());
        let body = format!("snapshot_id={id}");
        let ok = post_form(&base, &session, "/dhcp/snapshot/rollback", &body).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(kea.lock().unwrap().config, snapshot);
        let _ = fs::remove_dir_all(&dir);
    }

    // What: a DHCP mode switch stops, saves, starts.
    // Why: the order keeps a failed save from losing DHCP.
    #[tokio::test]
    async fn dhcp_mode_switch_stops_saves_then_starts() {
        let dir = unique_temp_dir("dhcp-mode");
        let conf = dir.join("ui.conf");
        fs::write(&conf, "DHCP_MODE=disabled\n").unwrap();
        let (docker, seen) = serve_canned(vec![(204, vec![]), (204, vec![])]);
        let (path, url) = (conf.to_string_lossy().to_string(), docker);
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.ui_settings_file = path;
            cfg.docker_proxy_url = url;
        })
        .await;
        let session = open_session(&base, &state).await;
        let bad = post_form(&base, &session, "/dhcp/mode", "dhcp_mode=bogus").await;
        assert_eq!(bad.status(), 409);
        let ok = post_form(&base, &session, "/dhcp/mode", "dhcp_mode=KEA").await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/dhcp");
        assert!(
            fs::read_to_string(&conf)
                .unwrap()
                .starts_with("DHCP_MODE=kea\n")
        );
        assert!(!dir.join(".dhcp-mode-write-check").exists());
        let requests = seen.join().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].starts_with("POST /containers/lancache-dhcp-proxy/stop?t=10 "));
        assert!(requests[1].starts_with("POST /containers/lancache-dhcp/start "));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: proxy to relay restarts the shared container.
    // Why: one container serves both and must reread mode.
    #[tokio::test]
    async fn dhcp_proxy_and_relay_switch_restarts_the_container() {
        let dir = unique_temp_dir("dhcp-relay");
        let conf = dir.join("ui.conf");
        fs::write(&conf, "DHCP_MODE=dnsmasq-proxy\n").unwrap();
        let replies = vec![(204, vec![]), (204, vec![]), (204, vec![])];
        let (docker, seen) = serve_canned(replies);
        let (path, url) = (conf.to_string_lossy().to_string(), docker);
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.ui_settings_file = path;
            cfg.docker_proxy_url = url;
        })
        .await;
        let session = open_session(&base, &state).await;
        let body = "dhcp_mode=dnsmasq-relay";
        let ok = post_form(&base, &session, "/dhcp/mode", body).await;
        assert_eq!(ok.status(), 303);
        let saved = fs::read_to_string(&conf).unwrap();
        assert!(saved.starts_with("DHCP_MODE=dnsmasq-relay\n"));
        let requests = seen.join().unwrap();
        assert_eq!(requests.len(), 3);
        assert!(requests[0].starts_with("POST /containers/lancache-dhcp/stop?t=10 "));
        assert!(requests[1].starts_with("POST /containers/lancache-dhcp-proxy/stop?t=10 "));
        assert!(requests[2].starts_with("POST /containers/lancache-dhcp-proxy/start "));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&sdir);
    }

    // What: a missing container, a bad volume are reported.
    // Why: the operator needs the fix, not a bare 500.
    #[tokio::test]
    async fn dhcp_mode_switch_reports_start_and_write_failures() {
        let dir = unique_temp_dir("dhcp-mode-fail");
        let conf = dir.join("ui.conf");
        fs::write(&conf, "DHCP_MODE=disabled\n").unwrap();
        let (docker, _seen) = serve_canned(vec![(204, vec![]), (404, vec![])]);
        let (path, url) = (conf.to_string_lossy().to_string(), docker);
        let (base, state, sdir) = test_server(move |cfg| {
            cfg.ui_settings_file = path;
            cfg.docker_proxy_url = url;
        })
        .await;
        let session = open_session(&base, &state).await;
        let never = post_form(&base, &session, "/dhcp/mode", "dhcp_mode=kea").await;
        assert_eq!(never.status(), 500);
        let text = never.text().await.unwrap();
        assert!(text.contains("has not been created yet"));
        assert!(text.contains("--profile dhcp-kea up -d lancache-dhcp"));
        let _ = fs::remove_dir_all(&sdir);

        let blocker = dir.join("file");
        fs::write(&blocker, "x").unwrap();
        let path = format!("{}/ui.conf", blocker.to_string_lossy());
        let (base, state, sdir) = test_server(move |cfg| cfg.ui_settings_file = path).await;
        let session = open_session(&base, &state).await;
        let ro = post_form(&base, &session, "/dhcp/mode", "dhcp_mode=kea").await;
        assert_eq!(ro.status(), 500);
        assert!(ro.text().await.unwrap().contains("is not writable"));
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
            (&[("dhcp_dns_primary", "")], "Invalid primary DNS"),
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
            let response = post_form(&base, &session, "/dhcp/proxy", &body(changes)).await;
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
            "/dhcp/proxy",
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
        let ok = post_form(&base, &session, "/dhcp/proxy", &full).await;
        assert_eq!(ok.status(), 303);
        assert_eq!(ok.headers()[header::LOCATION], "/dhcp");
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
