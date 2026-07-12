//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI DHCP routes. Renders Kea DHCP subnets, leases, reservations, and
//! dual DHCP probe checks, and applies guarded DHCP config mutations through
//! the Kea control-agent with rollback handling for failed persistence.
//!
//! Docker exec is intentionally not used here. The UI talks to a narrowed
//! Docker socket proxy, so DHCP conflict discovery runs through a predeclared
//! one-shot helper container that can only be started, waited on, and logged.

use crate::{docker_client, kea_snapshots, AppState};
use anyhow::Context as AnyhowContext;
use axum::extract::{Form, State};
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Json;
use bollard::container::LogOutput;
// The DHCP probe path deliberately uses only start/stop/wait/logs operations
// because Docker exec and generic container creation are banned from the UI's
// Docker API surface for security reasons.
use bollard::query_parameters::{
    LogsOptionsBuilder, StartContainerOptionsBuilder, StopContainerOptionsBuilder,
    WaitContainerOptionsBuilder,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::future::Future;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tera::Context;

// ─── Constants ───

const MIN_LEASE_TIME: u32 = 60;
const MAX_LEASE_TIME: u32 = 604_800; // 7 days
const CUSTOM_DHCP_OPTION_DATA_MAX_LEN: usize = 1024;

// ─── Error Handling ───

/// Error type for DHCP configuration operations that carries a message
/// and HTTP status code, suitable for surfacing to HTTP responses.
#[derive(Debug)]
pub struct DhcpError {
    status: StatusCode,
    message: String,
}

impl DhcpError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn config_error(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }

    fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, message)
    }
}

impl From<StatusCode> for DhcpError {
    fn from(status: StatusCode) -> Self {
        Self::new(status, format!("HTTP {}", status.as_u16()))
    }
}

impl std::fmt::Display for DhcpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for DhcpError {}

impl IntoResponse for DhcpError {
    fn into_response(self) -> Response {
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>DHCP Configuration Error</title></head>\n\
             <body><h1>DHCP Configuration Error</h1>\n<p>{}</p>\n\
             <p><a href=\"/dhcp\">Return to DHCP settings</a></p>\n</body>\n</html>",
            html_escape(&self.message)
        );
        (self.status, Html(body)).into_response()
    }
}

#[derive(Debug)]
enum KeaWriteOutcome {
    Success,
    ConfirmedFailure(String),
    AmbiguousFailure(String),
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

// ─── Data Structures ───

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum DhcpConflictCheckStatus {
    Found { output: String },
    NotFound,
    Unavailable { reason: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum DhcpClientCheckStatus {
    Passed { output: String },
    Failed { output: String },
    Unavailable { reason: String },
}

#[derive(Debug)]
struct DhcpCheckReport {
    conflict: DhcpConflictCheckStatus,
    client: DhcpClientCheckStatus,
}

impl DhcpCheckReport {
    fn overall_status(&self) -> &'static str {
        match (&self.conflict, &self.client) {
            (DhcpConflictCheckStatus::Found { .. }, _) => "conflict_found",
            (DhcpConflictCheckStatus::Unavailable { .. }, _) => "unavailable",
            (_, DhcpClientCheckStatus::Unavailable { .. }) => "unavailable",
            (_, DhcpClientCheckStatus::Failed { .. }) => "client_failed",
            (_, DhcpClientCheckStatus::Passed { .. }) => "verified",
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Subnet {
    pub id: u32,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: u32,
    pub domain: String,
    pub custom_options: Vec<DhcpOption>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct DhcpOption {
    pub code: u16,
    pub data: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Lease {
    pub subnet_id: u32,
    pub ip: String,
    pub mac: String,
    pub hostname: String,
    pub expires: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Reservation {
    pub subnet_id: u32,
    pub ip: String,
    pub mac: String,
    pub hostname: String,
}

// ─── Form Structs ───

#[derive(Deserialize)]
pub struct AddSubnetForm {
    pub csrf_token: String,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: String,
    pub domain: String,
}

#[derive(Deserialize)]
pub struct UpdateSubnetForm {
    pub csrf_token: String,
    pub id: u32,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub dns_primary: String,
    pub dns_secondary: String,
    pub ntp_servers: String,
    pub lease_time: String,
    pub domain: String,
}

#[derive(Deserialize)]
pub struct RemoveSubnetForm {
    pub csrf_token: String,
    pub id: u32,
}

#[derive(Deserialize)]
pub struct AddSubnetOptionForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub code: String,
    pub data: String,
}

#[derive(Deserialize)]
pub struct RemoveSubnetOptionForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub code: String,
    pub data: String,
}

#[derive(Deserialize)]
pub struct AddReservationForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub mac: String,
    pub ip: String,
    pub hostname: String,
}

#[derive(Deserialize)]
pub struct RemoveReservationForm {
    pub csrf_token: String,
    pub subnet_id: u32,
    pub mac: String,
}

#[derive(Deserialize)]
pub struct ReleaseLeaseForm {
    pub csrf_token: String,
    pub ip: String,
}

#[derive(Deserialize)]
pub struct UpdateDhcpModeForm {
    pub csrf_token: String,
    pub dhcp_mode: String,
}

#[derive(Deserialize)]
pub struct UpdateDhcpProxyForm {
    pub csrf_token: String,
    pub dhcp_subnet_start: String,
    pub dhcp_dns_primary: String,
    pub dhcp_dns_secondary: String,
    pub upstream_dhcp_ip: String,
    // Issue #450: additional optional dnsmasq relay/proxy fields. All are
    // allowed to be empty (the feature they configure is simply not
    // rendered into dnsmasq.conf, see entrypoint.sh's
    // `_dhcp_proxy_render_optional_directives`); only non-empty values are
    // validated for shape.
    #[serde(default)]
    pub dhcp_proxy_interface: String,
    #[serde(default)]
    pub dhcp_proxy_router: String,
    #[serde(default)]
    pub dhcp_ntp_servers: String,
    #[serde(default)]
    pub dhcp_proxy_domain: String,
    #[serde(default)]
    pub dhcp_proxy_boot_filename: String,
    #[serde(default)]
    pub dhcp_proxy_boot_server: String,
    #[serde(default)]
    pub dhcp_proxy_custom_options: String,
}

#[derive(Deserialize)]
pub struct RollbackKeaSnapshotForm {
    pub csrf_token: String,
    pub snapshot_id: String,
}

// A known-good Kea config snapshot as rendered in the Admin UI (#614). Only
// the id (for the rollback form) and a Unix-epoch-seconds timestamp (for
// client-side display via the same `Intl.DateTimeFormat`/`.dhcp-expiry`
// pattern `formatDhcpExpiries()` already uses for lease expiries) are
// exposed -- never the config payload itself, which can be arbitrarily large.
#[derive(Debug, Serialize)]
struct KeaSnapshotSummary {
    id: String,
    created_unix: u64,
}

// ─── Handlers ───

pub async fn dhcp_page(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Html<String> {
    let mut ctx = Context::new();
    let dhcp_mode = state.config.effective_dhcp_mode();
    let dhcp_has_kea = dhcp_mode.is_kea();
    let dhcp_dns_primary = state.config.effective_dhcp_dns_primary();
    let dhcp_dns_secondary = state.config.effective_dhcp_dns_secondary();
    let dhcp_ntp_servers = state.config.effective_dhcp_ntp_servers();
    let dhcp_proxy_subnet_start = state.config.effective_dhcp_proxy_subnet_start();
    let dhcp_upstream_dhcp_ip = state.config.effective_dhcp_upstream_dhcp_ip();
    let dhcp_proxy_interface = state.config.effective_dhcp_proxy_interface();
    let dhcp_proxy_router = state.config.effective_dhcp_proxy_router();
    let dhcp_proxy_domain = state.config.effective_dhcp_proxy_domain();
    let dhcp_proxy_boot_filename = state.config.effective_dhcp_proxy_boot_filename();
    let dhcp_proxy_boot_server = state.config.effective_dhcp_proxy_boot_server();
    let dhcp_proxy_custom_options_form =
        custom_options_storage_to_form(&state.config.effective_dhcp_proxy_custom_options());
    ctx.insert("active_page", "dhcp");
    ctx.insert("dhcp_mode", &dhcp_mode.as_str());
    ctx.insert("dhcp_has_kea", &dhcp_has_kea);
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);
    ctx.insert("dhcp_dns_primary", &dhcp_dns_primary);
    ctx.insert("dhcp_dns_secondary", &dhcp_dns_secondary);
    ctx.insert("dhcp_ntp_servers", &dhcp_ntp_servers);
    ctx.insert("dhcp_proxy_subnet_start", &dhcp_proxy_subnet_start);
    ctx.insert("dhcp_upstream_dhcp_ip", &dhcp_upstream_dhcp_ip);
    ctx.insert("dhcp_proxy_interface", &dhcp_proxy_interface);
    ctx.insert("dhcp_proxy_router", &dhcp_proxy_router);
    ctx.insert("dhcp_proxy_domain", &dhcp_proxy_domain);
    ctx.insert("dhcp_proxy_boot_filename", &dhcp_proxy_boot_filename);
    ctx.insert("dhcp_proxy_boot_server", &dhcp_proxy_boot_server);
    ctx.insert(
        "dhcp_proxy_custom_options_form",
        &dhcp_proxy_custom_options_form,
    );
    crate::routes::insert_csrf_token(&mut ctx, &headers);

    if kea_api_available(
        state.config.effective_dhcp_mode(),
        &state.config.dhcp_api_url,
    ) {
        let subnets = fetch_subnets(&state).await.unwrap_or_default();
        let (leases, reservations) =
            tokio::join!(fetch_leases(&state), fetch_all_reservations(&state));
        ctx.insert("subnets", &subnets);
        ctx.insert("leases", &leases.unwrap_or_default());
        ctx.insert("reservations", &reservations.unwrap_or_default());
    } else {
        let empty: Vec<Subnet> = Vec::new();
        ctx.insert("subnets", &empty);
        ctx.insert("leases", &Vec::<Lease>::new());
        ctx.insert("reservations", &Vec::<Reservation>::new());
    }

    ctx.insert("kea_snapshots", &fetch_kea_snapshot_summaries(&state));
    ctx.insert(
        "kea_snapshot_retention",
        &state.config.kea_keep_known_good_configs,
    );

    crate::routes::render(&state.templates, "dhcp.html", &ctx, state.config.dev_mode)
}

fn require_kea_mode(state: &AppState) -> Result<(), DhcpError> {
    if kea_api_available(
        state.config.effective_dhcp_mode(),
        &state.config.dhcp_api_url,
    ) {
        Ok(())
    } else {
        Err(DhcpError::conflict(
            "DHCP mutations require Kea mode with a configured Kea API URL.",
        ))
    }
}

fn kea_api_available(mode: crate::config::DhcpMode, api_url: &str) -> bool {
    mode.is_kea() && !api_url.is_empty()
}

fn parse_dhcp_mode_input(value: &str) -> Option<crate::config::DhcpMode> {
    match value.trim().to_ascii_lowercase().as_str() {
        "disabled" => Some(crate::config::DhcpMode::Disabled),
        "kea" => Some(crate::config::DhcpMode::Kea),
        "dnsmasq-proxy" => Some(crate::config::DhcpMode::DnsmasqProxy),
        _ => None,
    }
}

async fn reconcile_dhcp_mode(
    state: &AppState,
    mode: crate::config::DhcpMode,
) -> Result<(), DhcpError> {
    // Only predeclared Compose services are controlled here. Missing profile
    // containers stay a visible operator error instead of silently diverging
    // from the UI's persisted DHCP mode.
    match mode {
        crate::config::DhcpMode::Disabled => {
            docker_client::stop_service_if_present(&state.docker, "dhcp")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
            docker_client::stop_service_if_present(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
        }
        crate::config::DhcpMode::Kea => {
            docker_client::stop_service_if_present(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
            docker_client::start_service(&state.docker, "dhcp")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
        }
        crate::config::DhcpMode::DnsmasqProxy => {
            docker_client::stop_service_if_present(&state.docker, "dhcp")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
            docker_client::start_service(&state.docker, "dhcp-proxy")
                .await
                .map_err(|err| DhcpError::config_error(err.to_string()))?;
        }
    }
    Ok(())
}

fn persist_ui_settings(state: &AppState, values: &[(&str, String)]) -> Result<(), DhcpError> {
    let mut map = BTreeMap::new();
    for (key, value) in values {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            map.insert((*key).to_string(), trimmed.to_string());
        }
    }

    let mut content = String::new();
    for key in [
        "DHCP_MODE",
        "DHCP_SUBNET_START",
        "DHCP_DNS_PRIMARY",
        "DHCP_DNS_SECONDARY",
        "UPSTREAM_DHCP_IP",
        "DHCP_NTP_SERVERS",
        "DHCP_PROXY_INTERFACE",
        "DHCP_PROXY_ROUTER",
        "DHCP_PROXY_DOMAIN",
        "DHCP_PROXY_BOOT_FILENAME",
        "DHCP_PROXY_BOOT_SERVER",
        "DHCP_PROXY_CUSTOM_OPTIONS",
    ] {
        if let Some(value) = map.get(key) {
            content.push_str(key);
            content.push('=');
            content.push_str(value);
            content.push('\n');
        }
    }

    let target = Path::new(&state.config.ui_settings_file);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|err| {
            DhcpError::config_error(format!(
                "Failed to prepare settings directory {}: {}",
                parent.display(),
                err
            ))
        })?;
    }
    let tmp_path = target.with_extension("tmp");
    fs::write(&tmp_path, content).map_err(|err| {
        DhcpError::config_error(format!(
            "Failed to persist DHCP mode to {}: {}",
            tmp_path.display(),
            err
        ))
    })?;
    fs::rename(&tmp_path, target).map_err(|err| {
        DhcpError::config_error(format!(
            "Failed to finalize DHCP mode settings at {}: {}",
            target.display(),
            err
        ))
    })
}

pub async fn update_dhcp_mode(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateDhcpModeForm>,
) -> Result<Redirect, DhcpError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let mode = parse_dhcp_mode_input(&form.dhcp_mode)
        .ok_or_else(|| DhcpError::conflict("Invalid DHCP mode requested."))?;

    reconcile_dhcp_mode(&state, mode).await?;
    persist_ui_settings(
        &state,
        &[
            ("DHCP_MODE", mode.as_str().to_string()),
            (
                "DHCP_SUBNET_START",
                state.config.effective_dhcp_proxy_subnet_start(),
            ),
            (
                "DHCP_DNS_PRIMARY",
                state.config.effective_dhcp_dns_primary(),
            ),
            (
                "DHCP_DNS_SECONDARY",
                state.config.effective_dhcp_dns_secondary(),
            ),
            (
                "UPSTREAM_DHCP_IP",
                state.config.effective_dhcp_upstream_dhcp_ip(),
            ),
            (
                "DHCP_NTP_SERVERS",
                state.config.effective_dhcp_ntp_servers(),
            ),
            (
                "DHCP_PROXY_INTERFACE",
                state.config.effective_dhcp_proxy_interface(),
            ),
            (
                "DHCP_PROXY_ROUTER",
                state.config.effective_dhcp_proxy_router(),
            ),
            (
                "DHCP_PROXY_DOMAIN",
                state.config.effective_dhcp_proxy_domain(),
            ),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                state.config.effective_dhcp_proxy_boot_filename(),
            ),
            (
                "DHCP_PROXY_BOOT_SERVER",
                state.config.effective_dhcp_proxy_boot_server(),
            ),
            (
                "DHCP_PROXY_CUSTOM_OPTIONS",
                state.config.effective_dhcp_proxy_custom_options(),
            ),
        ],
    )?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn update_dhcp_proxy(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateDhcpProxyForm>,
) -> Result<Redirect, DhcpError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if form.dhcp_subnet_start.trim().is_empty() || parse_ipv4(&form.dhcp_subnet_start).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if parse_ipv4(&form.dhcp_dns_primary).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if !form.dhcp_dns_secondary.trim().is_empty() && parse_ipv4(&form.dhcp_dns_secondary).is_none()
    {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    if parse_ipv4(&form.upstream_dhcp_ip).is_none() {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }

    // Issue #450: additional optional fields. Each is only validated when
    // non-empty -- leaving one blank simply means entrypoint.sh renders no
    // directive for it (see `_dhcp_proxy_render_optional_directives`), it is
    // never a form error. This is friendly early feedback only; the
    // authoritative fail-closed gate is still `dnsmasq --test` plus the
    // known-good-snapshot rollback in services/dhcp-proxy/entrypoint.sh.
    if !form.dhcp_proxy_interface.trim().is_empty()
        && !is_valid_interface_name(&form.dhcp_proxy_interface)
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid relay/proxy listen interface: use only letters, digits, '.', '-', or '_'.",
        ));
    }
    if !form.dhcp_proxy_router.trim().is_empty() && parse_ipv4(&form.dhcp_proxy_router).is_none() {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid router/gateway option: must be a valid IPv4 address.",
        ));
    }
    if !form.dhcp_ntp_servers.trim().is_empty()
        && !form
            .dhcp_ntp_servers
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .all(|s| parse_ipv4(s).is_some())
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid NTP servers option: must be a comma-separated list of IPv4 addresses.",
        ));
    }
    if !form.dhcp_proxy_domain.trim().is_empty() && !is_valid_domain_name(&form.dhcp_proxy_domain) {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid domain option: use a plain DNS domain name (letters, digits, '-', '.').",
        ));
    }
    if !form.dhcp_proxy_boot_filename.trim().is_empty()
        && !is_valid_boot_filename(&form.dhcp_proxy_boot_filename)
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid PXE boot filename: no whitespace, commas, or control characters.",
        ));
    }
    if !form.dhcp_proxy_boot_server.trim().is_empty()
        && parse_ipv4(&form.dhcp_proxy_boot_server).is_none()
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Invalid PXE boot server address: must be a valid IPv4 address.",
        ));
    }
    if !form.dhcp_proxy_boot_server.trim().is_empty()
        && form.dhcp_proxy_boot_filename.trim().is_empty()
    {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "A PXE boot server address requires a boot filename; a server address alone is not meaningful.",
        ));
    }
    let custom_options_storage = parse_custom_options_form(&form.dhcp_proxy_custom_options)
        .map_err(|message| {
            DhcpError::new(
                StatusCode::BAD_REQUEST,
                format!("Invalid custom DHCP option: {message}"),
            )
        })?;

    persist_ui_settings(
        &state,
        &[
            (
                "DHCP_MODE",
                state.config.effective_dhcp_mode().as_str().to_string(),
            ),
            ("DHCP_SUBNET_START", form.dhcp_subnet_start),
            ("DHCP_DNS_PRIMARY", form.dhcp_dns_primary),
            ("DHCP_DNS_SECONDARY", form.dhcp_dns_secondary),
            ("UPSTREAM_DHCP_IP", form.upstream_dhcp_ip),
            ("DHCP_NTP_SERVERS", form.dhcp_ntp_servers.trim().to_string()),
            (
                "DHCP_PROXY_INTERFACE",
                form.dhcp_proxy_interface.trim().to_string(),
            ),
            (
                "DHCP_PROXY_ROUTER",
                form.dhcp_proxy_router.trim().to_string(),
            ),
            (
                "DHCP_PROXY_DOMAIN",
                form.dhcp_proxy_domain.trim().to_string(),
            ),
            (
                "DHCP_PROXY_BOOT_FILENAME",
                form.dhcp_proxy_boot_filename.trim().to_string(),
            ),
            (
                "DHCP_PROXY_BOOT_SERVER",
                form.dhcp_proxy_boot_server.trim().to_string(),
            ),
            ("DHCP_PROXY_CUSTOM_OPTIONS", custom_options_storage),
        ],
    )?;
    Ok(Redirect::to("/dhcp"))
}

// ─── dnsmasq relay/proxy field validators (issue #450) ───

// Network interface names are short host-controlled identifiers (e.g.
// `eth0`, `br-lan.100`), never arbitrary text -- reject anything containing
// characters that would be meaningless (or unsafe to place unquoted into
// dnsmasq's `interface=` directive).
fn is_valid_interface_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

fn is_valid_domain_name(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 253
        && name
            .split('.')
            .all(|label| !label.is_empty() && label.len() <= 63 && is_valid_dns_label(label))
}

fn is_valid_dns_label(label: &str) -> bool {
    let bytes = label.as_bytes();
    let alnum_or_hyphen = |b: u8| b.is_ascii_alphanumeric() || b == b'-';
    bytes.iter().all(|&b| alnum_or_hyphen(b))
        && !bytes.first().is_some_and(|&b| b == b'-')
        && !bytes.last().is_some_and(|&b| b == b'-')
}

// PXE boot filenames are paths like `pxelinux.0` or `efi/bootx64.efi`. They
// are rendered straight into `dhcp-boot=<filename>,,<server>`, a comma-
// delimited directive, so a comma in the filename would silently misparse
// into the server-name field instead of erroring -- reject it explicitly
// rather than let that happen. Newlines are rejected as they are elsewhere
// in this file (would corrupt the rendered config file).
fn is_valid_boot_filename(raw: &str) -> bool {
    let name = raw.trim();
    !name.is_empty()
        && name.len() <= 255
        && !name
            .chars()
            .any(|c| c.is_whitespace() || c == ',' || c.is_control())
}

// Parses the Admin UI's one-entry-per-line custom option textarea
// (`CODE:VALUE` per line) into the `;`-separated single-line form persisted
// to DHCP_PROXY_CUSTOM_OPTIONS (env/settings files are simple `KEY=value`
// lines with no embedded newlines, matching the constraint
// `validate_custom_dhcp_option_data` already enforces for Kea's per-subnet
// custom options). Reuses the exact same code/data validators as Kea's
// custom subnet options, including the exclusion of codes 3/6/15/42/119 --
// those are already covered by this page's dedicated router/DNS/domain/NTP
// fields, so routing them through the free-form custom list instead would
// create two divergent ways to set the same option.
fn parse_custom_options_form(raw: &str) -> Result<String, String> {
    let mut rendered = Vec::new();
    for (line_no, line) in raw.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (code_raw, data_raw) = line
            .split_once(':')
            .ok_or_else(|| format!("line {}: expected CODE:VALUE", line_no + 1))?;
        let code = parse_custom_dhcp_option_code(code_raw)
            .map_err(|message| format!("line {}: {message}", line_no + 1))?;
        let data = validate_custom_dhcp_option_data(data_raw)
            .map_err(|message| format!("line {}: {message}", line_no + 1))?;
        // ';' is the top-level entry separator for the persisted
        // DHCP_PROXY_CUSTOM_OPTIONS value (see the storage format doc
        // comment above and entrypoint.sh's `_dhcp_proxy_render_custom_options`);
        // allowing it inside a value would let one entry's data silently
        // split into two entries on the shell side.
        if data.contains(';') {
            return Err(format!(
                "line {}: option data must not contain ';' (used as the entry separator)",
                line_no + 1
            ));
        }
        rendered.push(format!("{code}:{data}"));
    }
    Ok(rendered.join(";"))
}

// Inverse of the storage join above, for redisplaying the persisted value in
// the Admin UI's textarea as one CODE:VALUE per line.
fn custom_options_storage_to_form(stored: &str) -> String {
    stored
        .split(';')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

pub async fn add_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let lease_time = validate_dhcp_form(DhcpFormValidation {
        subnet: &form.subnet,
        pool_start: &form.pool_start,
        pool_end: &form.pool_end,
        gateway: &form.gateway,
        dns_primary: &form.dns_primary,
        dns_secondary: &form.dns_secondary,
        ntp_servers: &form.ntp_servers,
        lease_time: &form.lease_time,
    })
    .map_err(DhcpError::from)?;

    kea_config_modify(&state, move |config| {
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        let next_id = subnets
            .iter()
            .filter_map(|s| s["id"].as_u64())
            .max()
            .map(|m| m + 1)
            .unwrap_or(1) as u32;

        subnets.push(build_subnet_value(SubnetValue {
            id: next_id,
            subnet: form.subnet,
            pool_start: form.pool_start,
            pool_end: form.pool_end,
            gateway: form.gateway,
            dns_primary: form.dns_primary,
            dns_secondary: form.dns_secondary,
            ntp_servers: form.ntp_servers,
            domain: form.domain,
            lease_time,
            editable_options: Vec::new(),
            reservations: None,
        })?);
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn update_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let lease_time = validate_dhcp_form(DhcpFormValidation {
        subnet: &form.subnet,
        pool_start: &form.pool_start,
        pool_end: &form.pool_end,
        gateway: &form.gateway,
        dns_primary: &form.dns_primary,
        dns_secondary: &form.dns_secondary,
        ntp_servers: &form.ntp_servers,
        lease_time: &form.lease_time,
    })
    .map_err(DhcpError::from)?;
    let subnet_id = form.id;

    kea_config_modify(&state, move |config| {
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        let entry = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(subnet_id as u64))
            .ok_or("subnet not found")?;
        let reservations = compatible_reservations_for_subnet(entry, &form.subnet)?;
        apply_subnet_value(
            entry,
            SubnetValue {
                id: subnet_id,
                subnet: form.subnet,
                pool_start: form.pool_start,
                pool_end: form.pool_end,
                gateway: form.gateway,
                dns_primary: form.dns_primary,
                dns_secondary: form.dns_secondary,
                ntp_servers: form.ntp_servers,
                domain: form.domain,
                lease_time,
                editable_options: preserved_subnet_options(entry),
                reservations: Some(reservations),
            },
        )?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_subnet(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveSubnetForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let subnet_id = form.id;
    kea_config_modify(&state, move |config| {
        let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
        let subnets = dhcp4
            .get_mut("subnet4")
            .ok_or("subnet4 missing")?
            .as_array_mut()
            .ok_or("subnet4 not an array")?;

        subnets.retain(|s| s["id"].as_u64() != Some(subnet_id as u64));
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn add_subnet_option(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddSubnetOptionForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let code = parse_custom_dhcp_option_code(&form.code).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let data = validate_custom_dhcp_option_data(&form.data).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let subnet_id = form.subnet_id;

    kea_config_modify(&state, move |config| {
        let subnet = find_subnet_mut(config, subnet_id)?;
        add_custom_subnet_option(subnet, code, &data)?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_subnet_option(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveSubnetOptionForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let code = parse_custom_dhcp_option_code(&form.code).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let data = validate_custom_dhcp_option_data(&form.data).map_err(|message| {
        DhcpError::new(
            StatusCode::BAD_REQUEST,
            format!("Invalid DHCP option: {message}"),
        )
    })?;
    let subnet_id = form.subnet_id;

    kea_config_modify(&state, move |config| {
        let subnet = find_subnet_mut(config, subnet_id)?;
        remove_custom_subnet_option(subnet, code, &data)?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn add_reservation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddReservationForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if !is_valid_mac(&form.mac) || !is_valid_ip(&form.ip) {
        return Err(DhcpError::from(StatusCode::BAD_REQUEST));
    }
    let mac = normalize_mac(&form.mac);
    kea_config_modify(&state, move |config| {
        // Codex review finding on this same PR: if an operator has hand-edited
        // the *global* Dhcp4.host-reservation-identifiers list to something
        // that excludes "hw-address" (e.g. ["client-id"]), Kea would accept
        // this config-set call but then silently never match the reservation
        // we're about to add -- config-set succeeds, the form redirects as if
        // it worked, and the reservation is permanently dead. This project's
        // own shipped kea-dhcp4.conf never sets this key (relies entirely on
        // Kea's compiled-in default, which does include "hw-address"), so the
        // gap only bites a manually-edited config -- but "silently accepted,
        // never actually works" is exactly the failure class this project
        // refuses to ship (see AG-OP-005: do not silently invert defaults).
        // Fail loudly instead of writing a reservation Kea will never honor.
        if !global_reservation_identifiers_include_hw_address(config) {
            return Err(
                "cannot add a hw-address reservation: this Kea config's global \
                 Dhcp4.host-reservation-identifiers list does not include \
                 \"hw-address\", so Kea would never match it",
            );
        }
        let subnets = dhcp4_subnets_mut(config)?;
        let subnet = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(form.subnet_id as u64))
            .ok_or("subnet not found")?;
        // No per-subnet `host-reservation-identifiers` write here (there
        // used to be one): real Kea rejects that parameter at subnet scope
        // outright (see apply_subnet_value's own comment on this), and
        // Kea's compiled-in global default already includes "hw-address" --
        // the only identifier type this form ever submits -- so hw-address
        // reservations already match without this code touching anything.
        let reservations = subnet_reservations_mut(subnet)?;
        upsert_reservation(
            reservations,
            json!({
                "hw-address": mac,
                "ip-address": form.ip,
                "hostname": form.hostname,
                "option-data": [],
                "client-classes": []
            }),
        )?;
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RemoveReservationForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    let mac = normalize_mac(&form.mac);
    kea_config_modify(&state, move |config| {
        let subnets = dhcp4_subnets_mut(config)?;
        let subnet = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(form.subnet_id as u64))
            .ok_or("subnet not found")?;
        let reservations = subnet_reservations_mut(subnet)?;
        remove_reservation_entry(reservations, &mac);
        Ok(())
    })
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn release_lease(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<ReleaseLeaseForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;
    if !is_valid_ip(&form.ip) {
        return Err(DhcpError::new(
            StatusCode::BAD_REQUEST,
            "Lease release requires a valid IPv4 address",
        ));
    }

    let resp = kea_post(
        &state,
        json!({
            "command": "lease4-del",
            "service": ["dhcp4"],
            "arguments": {
                "ip-address": form.ip
            }
        }),
    )
    .await
    .map_err(|e| DhcpError::config_error(e.to_string()))?;

    match kea_lease_del_result(&resp) {
        LeaseDelOutcome::Released => Ok(Redirect::to("/dhcp")),
        // Kea's CONTROL_RESULT_EMPTY (3) for lease4-del means no lease matched
        // the given address -- an ordinary race (the lease expired or was
        // already released between page render and this request), not a
        // server-side failure. Surface it as 404, not 500.
        LeaseDelOutcome::NotFound => Err(DhcpError::new(
            StatusCode::NOT_FOUND,
            format!(
                "No active lease found for {}; it may have already expired or been released.",
                form.ip
            ),
        )),
        LeaseDelOutcome::Error(msg) => Err(DhcpError::config_error(msg)),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum LeaseDelOutcome {
    Released,
    NotFound,
    Error(String),
}

// lease4-del uses Kea's generic control-channel result codes: 0 = success,
// 3 = CONTROL_RESULT_EMPTY (no matching lease), anything else = error. This
// is distinct from kea_result() below, which treats any nonzero as failure --
// that's correct for config-modify commands, where "empty" has no special
// meaning, but wrong for lease4-del's "already gone" case.
fn kea_lease_del_result(resp: &Value) -> LeaseDelOutcome {
    let rc = resp
        .get(0)
        .and_then(|r| r.get("result"))
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    match rc {
        0 => LeaseDelOutcome::Released,
        3 => LeaseDelOutcome::NotFound,
        _ => {
            let msg = resp
                .get(0)
                .and_then(|r| r.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("Kea error");
            LeaseDelOutcome::Error(msg.to_string())
        }
    }
}

pub async fn check_dhcp_conflict(State(state): State<Arc<AppState>>) -> Json<Value> {
    let report = check_dhcp_probe(&state).await;
    Json(json!({
        "status": report.overall_status(),
        "conflict": report.conflict,
        "client": report.client,
    }))
}

// Rolls the live DHCPv4 config back to an operator-selected known-good
// snapshot (#614, follow-up to #415). Unlike the nginx/dnsmasq/PowerDNS
// shell adapters -- which automatically search their stored snapshots
// newest-to-oldest at container startup, because "the config this container
// is about to start with is invalid" is their only rollback trigger -- Kea
// has no equivalent startup moment: its config only ever changes through
// this Admin UI, live, one operator-driven mutation at a time. So this
// route is a single, explicit, operator-selected rollback rather than an
// automatic search: the operator picks one snapshot from the list rendered
// on `/dhcp`, and only that snapshot is validated and applied.
//
// The `known_ids` membership check below is this handler's path-traversal
// guard (see `kea_snapshots::read_snapshot`'s doc comment): `form.snapshot_id`
// is untrusted request input, but it is never used to build a filesystem
// path unless it exactly matches an id `list_snapshot_ids` already found on
// disk.
//
// Reusing `kea_config_modify` for the apply step gives this rollback the
// same `config-test` (validate the selected snapshot) -> `config-set` ->
// `config-write` chain, and the same confirmed/ambiguous-failure handling
// from PR #380, that every other DHCP mutation route already gets --
// including a fresh known-good snapshot of the restored config on success,
// so `docs/known-good-config-snapshots.md`'s "every successful config-write
// is snapshotted" rule has no special case for rollbacks. "Verify runtime
// and persisted state after rollback" (the issue's acceptance criterion) is
// satisfied by that same chain: `config-set` returning success is Kea's own
// confirmation the runtime accepted the restored config, and
// `config-write`'s confirmed/ambiguous handling is exactly the persisted-
// state verification PR #380 already established -- deliberately not
// re-implemented here as a second, fuzzy `config-get` diff, since Kea can
// reorder/normalize JSON on read in ways that would make such a diff noisy
// rather than trustworthy.
pub async fn rollback_kea_snapshot(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RollbackKeaSnapshotForm>,
) -> Result<Redirect, DhcpError> {
    require_kea_mode(&state)?;
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(DhcpError::from)?;

    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let known_ids = kea_snapshots::list_snapshot_ids(&snapshot_root).map_err(|e| {
        DhcpError::config_error(format!(
            "Failed to list known-good Kea config snapshots: {e}"
        ))
    })?;
    if !known_ids.iter().any(|id| id == &form.snapshot_id) {
        return Err(DhcpError::conflict(
            "Unknown or no-longer-available config snapshot.",
        ));
    }

    let snapshot_config =
        kea_snapshots::read_snapshot(&snapshot_root, &form.snapshot_id).map_err(|e| {
            kea_snapshots::kgs_log(
                "REJECT",
                &format!(
                    "rejected known-good snapshot {}: unreadable ({e})",
                    form.snapshot_id
                ),
            );
            DhcpError::config_error(format!("Stored config snapshot could not be read: {e}"))
        })?;

    kea_config_modify(&state, move |config| {
        *config = snapshot_config;
        Ok(())
    })
    .await
    .map_err(|e| {
        kea_snapshots::kgs_log(
            "REJECT",
            &format!(
                "rejected known-good snapshot {}: failed validation/apply ({e})",
                form.snapshot_id
            ),
        );
        DhcpError::config_error(format!(
            "Rollback to snapshot {} failed: {e}",
            form.snapshot_id
        ))
    })?;

    kea_snapshots::kgs_log(
        "SELECT",
        &format!(
            "selected known-good snapshot {} for rollback",
            form.snapshot_id
        ),
    );
    Ok(Redirect::to("/dhcp"))
}

// ─── Kea API Core ───

type KeaResponse = Result<Value, Box<dyn std::error::Error + Send + Sync>>;
type KeaResult = Result<(), Box<dyn std::error::Error + Send + Sync>>;

async fn kea_post(state: &AppState, cmd: Value) -> KeaResponse {
    let url = format!("{}/", state.config.dhcp_api_url);
    Ok(state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?
        .json::<Value>()
        .await?)
}

fn kea_result(resp: &Value) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let rc = resp
        .get(0)
        .and_then(|r| r.get("result"))
        .and_then(|v| v.as_i64())
        .unwrap_or(1);
    if rc == 0 {
        Ok(())
    } else {
        let msg = resp
            .get(0)
            .and_then(|r| r.get("text"))
            .and_then(|v| v.as_str())
            .unwrap_or("Kea error");
        Err(msg.to_string().into())
    }
}

// config-get → modify → config-test → config-set → config-write (persists to /var/lib/kea/kea-dhcp4.conf)
// This function implements config rollback logic: if config-write fails after config-set succeeds,
// it attempts to restore the previous config to maintain consistency between runtime and persisted state.
//
// On a confirmed config-write success, it also records a persisted,
// multi-generation known-good snapshot of the applied config (#614, follow-up
// to #415) via `kea_snapshots::create_snapshot`. That snapshot step is
// best-effort: a failure there is logged as a WARNING (rollback protection
// degraded until it succeeds again) rather than turned into an error for
// this call, mirroring the nginx/dnsmasq shell adapters' own non-fatal
// treatment of a failed `kgs_snapshot_create` -- the config mutation itself
// already succeeded and persisted; the only thing at risk is a future
// rollback's baseline, not this request.
async fn kea_config_modify<F>(state: &AppState, modify: F) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
{
    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let keep_n = state.config.kea_keep_known_good_configs;
    kea_config_modify_with_post(
        &state.kea_config_lock,
        |cmd| kea_post(state, cmd),
        modify,
        move |applied_config: &Value| {
            if let Err(e) = kea_snapshots::create_snapshot(&snapshot_root, keep_n, applied_config)
            {
                tracing::warn!(
                    error = %e,
                    "failed to record this valid DHCP config as a known-good snapshot; rollback protection is degraded until this succeeds"
                );
            }
        },
    )
    .await
}

async fn kea_config_modify_with_post<F, P, Fut, S>(
    lock: &tokio::sync::Mutex<()>,
    mut post: P,
    modify: F,
    on_write_success: S,
) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
    S: FnOnce(&Value) + Send,
{
    let _guard = lock.lock().await;

    // Step 1: Fetch current config
    let resp = post(json!({"command": "config-get", "service": ["dhcp4"]})).await?;
    kea_result(&resp)?;

    let mut config = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?;

    // config-get's response is `{"Dhcp4": {...}, "hash": "<config hash>"}` on
    // the real Kea Control Agent (observed live against Kea 2.6.3, the
    // version this project's `services/dhcp` image ships) -- `hash` is a
    // server-computed digest of the loaded config, not an accepted input.
    // Feeding it straight back as `arguments` to config-test/config-set (as
    // this function previously did) makes Kea reject the request with
    // "Unsupported 'hash' parameter." on every single call, even when the
    // config is otherwise byte-identical to what config-get just returned.
    // Stripped once, immediately after the fetch, so every downstream user
    // of `config` (the `modify` closure, `old_config`'s own rollback
    // config-set, config-test/config-set's request bodies, and the
    // known-good snapshot payload captured further down) works with the
    // clean `{"Dhcp4": {...}}` shape Kea actually accepts back.
    if let Some(map) = config.as_object_mut() {
        map.remove("hash");
    }

    // Step 2: Save old config for potential rollback
    let old_config = config.clone();

    // Step 3: Apply modifications
    modify(&mut config).map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;

    // Step 4: Validate new config
    let test_resp =
        post(json!({"command": "config-test", "service": ["dhcp4"], "arguments": config.clone()}))
            .await?;
    kea_result(&test_resp)?;

    // Captured before Step 5 moves `config` into the config-set request body,
    // so the exact validated-and-applied config is available for the
    // known-good snapshot on a confirmed config-write success below.
    let snapshot_candidate = config.clone();

    // Step 5: Apply new config at runtime
    let set_resp =
        post(json!({"command": "config-set", "service": ["dhcp4"], "arguments": config})).await?;
    kea_result(&set_resp)?;

    // Step 6: Persist config to disk.
    match kea_write_config(&mut post).await {
        KeaWriteOutcome::Success => {
            on_write_success(&snapshot_candidate);
            Ok(())
        }
        KeaWriteOutcome::ConfirmedFailure(write_err) => {
            tracing::warn!(error = %write_err, "DHCP config-write failed; attempting rollback to previous config");
            rollback_kea_config(&mut post, old_config, &write_err).await
        }
        KeaWriteOutcome::AmbiguousFailure(write_err) => {
            tracing::warn!(
                error = %write_err,
                "DHCP config-write outcome could not be confirmed; retrying before rollback"
            );
            match kea_write_config(&mut post).await {
                KeaWriteOutcome::Success => {
                    on_write_success(&snapshot_candidate);
                    Ok(())
                }
                KeaWriteOutcome::ConfirmedFailure(retry_err) => {
                    let msg = format!(
                        "Config applied at runtime but the first config-write result was ambiguous, \
                         and a retry returned a Kea failure. Runtime and persisted config may now differ. \
                         First error: {}. Retry error: {}",
                        write_err, retry_err
                    );
                    tracing::error!(
                        error = %msg,
                        "DHCP config-write retry failed after ambiguous first write; not rolling back blindly"
                    );
                    Err(msg.into())
                }
                KeaWriteOutcome::AmbiguousFailure(retry_err) => {
                    let msg = format!(
                        "Config applied at runtime but config-write could not be confirmed after retry. \
                         Runtime and persisted config may now differ. First error: {}. Retry error: {}",
                        write_err, retry_err
                    );
                    tracing::error!(error = %msg, "DHCP config-write remained ambiguous after retry");
                    Err(msg.into())
                }
            }
        }
    }
}

async fn kea_write_config<P, Fut>(post: &mut P) -> KeaWriteOutcome
where
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
{
    match post(json!({"command": "config-write", "service": ["dhcp4"]})).await {
        Ok(resp) => match kea_result(&resp) {
            Ok(_) => KeaWriteOutcome::Success,
            Err(err) => KeaWriteOutcome::ConfirmedFailure(err.to_string()),
        },
        Err(err) => KeaWriteOutcome::AmbiguousFailure(err.to_string()),
    }
}

async fn rollback_kea_config<P, Fut>(post: &mut P, old_config: Value, write_err: &str) -> KeaResult
where
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
{
    let rollback_result = post(json!({
        "command": "config-set",
        "service": ["dhcp4"],
        "arguments": old_config
    }))
    .await;

    match rollback_result {
        Ok(resp) => match kea_result(&resp) {
            Ok(_) => {
                let msg =
                    "Config change failed to persist and was rolled back; no change was made."
                        .to_string();
                tracing::warn!(error = %write_err, "DHCP config rollback succeeded");
                Err(msg.into())
            }
            Err(rollback_err) => {
                let msg = format!(
                    "Config applied at runtime but NOT persisted to disk — runtime and persisted config may now differ. \
                     Write failed: {}. Rollback also failed: {}",
                    write_err, rollback_err
                );
                tracing::error!(error = %msg, "DHCP config rollback failed");
                Err(msg.into())
            }
        },
        Err(rollback_err) => {
            let msg = format!(
                "Config applied at runtime but NOT persisted to disk — runtime and persisted config may now differ. \
                 Write failed: {}. Rollback request also failed: {}",
                write_err, rollback_err
            );
            tracing::error!(error = %msg, "DHCP config rollback request failed");
            Err(msg.into())
        }
    }
}

// ─── Data Fetchers ───

async fn fetch_dhcp_config(
    state: &AppState,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        json!({"command": "config-get", "service": ["dhcp4"]}),
    )
    .await?;
    kea_result(&resp)?;

    Ok(resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?)
}

fn fetch_subnets_from_config(config: &Value) -> Vec<Subnet> {
    dhcp4_subnets(config)
        .map(|subnets| subnets.iter().map(parse_subnet_entry).collect())
        .unwrap_or_default()
}

fn fetch_reservations_from_config(config: &Value) -> Vec<Reservation> {
    dhcp4_subnets(config)
        .map(|subnets| {
            subnets
                .iter()
                .flat_map(|subnet| {
                    let subnet_id = subnet.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                    subnet
                        .get("reservations")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(move |reservation| {
                            parse_reservation_entry(subnet_id, reservation)
                        })
                })
                .collect()
        })
        .unwrap_or_default()
}

async fn fetch_subnets(
    state: &AppState,
) -> Result<Vec<Subnet>, Box<dyn std::error::Error + Send + Sync>> {
    Ok(fetch_subnets_from_config(&fetch_dhcp_config(state).await?))
}

// Lists known-good Kea config snapshots (#614) for the DHCP settings page,
// newest first (the order an operator picking a rollback target cares
// about). Missing/unreadable snapshot storage renders as "no snapshots yet"
// rather than failing the whole page -- the same fail-open treatment
// `dhcp_page` already gives `fetch_subnets`/`fetch_leases`/
// `fetch_all_reservations` when the Kea API itself is unavailable.
fn fetch_kea_snapshot_summaries(state: &AppState) -> Vec<KeaSnapshotSummary> {
    let snapshot_root = PathBuf::from(&state.config.kea_config_snapshot_dir);
    let mut ids = kea_snapshots::list_snapshot_ids(&snapshot_root).unwrap_or_default();
    ids.reverse(); // newest first for display
    ids.into_iter()
        .map(|id| KeaSnapshotSummary {
            created_unix: kea_snapshots::snapshot_created_unix(&id).unwrap_or(0),
            id,
        })
        .collect()
}

async fn fetch_leases(
    state: &AppState,
) -> Result<Vec<Lease>, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        json!({"command": "lease4-get-all", "service": ["dhcp4"]}),
    )
    .await?;

    let mut leases = Vec::new();
    if let Some(lease_array) = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .and_then(|a| a.get("leases"))
        .and_then(|l| l.as_array())
    {
        for lease in lease_array {
            let cltt = lease.get("cltt").and_then(|v| v.as_i64()).unwrap_or(0);
            let valid_lft = lease.get("valid-lft").and_then(|v| v.as_i64()).unwrap_or(0);
            leases.push(Lease {
                subnet_id: lease.get("subnet-id").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                ip: lease
                    .get("ip-address")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                mac: lease
                    .get("hw-address")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string(),
                hostname: lease
                    .get("hostname")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                expires: (cltt + valid_lft).to_string(),
            });
        }
    }
    Ok(leases)
}

async fn fetch_all_reservations(
    state: &AppState,
) -> Result<Vec<Reservation>, Box<dyn std::error::Error + Send + Sync>> {
    Ok(fetch_reservations_from_config(
        &fetch_dhcp_config(state).await?,
    ))
}

async fn check_dhcp_probe(state: &AppState) -> DhcpCheckReport {
    // Serializes probe requests against the single predeclared dhcp-probe
    // container — concurrent /api/dhcp/check calls would otherwise race to
    // restart/attach/inspect the same container.
    let _guard = state.dhcp_probe_lock.lock().await;

    let output = match run_dhcp_probe(&state.docker).await {
        Ok(out) => out,
        Err(e) => {
            return DhcpCheckReport {
                conflict: DhcpConflictCheckStatus::Unavailable {
                    reason: format!("Failed to execute DHCP check: {}", e),
                },
                client: DhcpClientCheckStatus::Unavailable {
                    reason: "probe container did not complete".to_string(),
                },
            };
        }
    };

    parse_dhcp_probe_report(&output)
}

fn normalize_nmap_line(line: &str) -> &str {
    line.trim_start_matches(|ch: char| ch == '|' || ch == '_' || ch.is_whitespace())
        .trim_end()
}

const DHCP_PROBE_SERVICE: &str = "dhcp-probe";
const DHCP_PROBE_START_MARKER: &str = "__LANCACHE_DHCP_PROBE_START__";
const DHCP_CONFLICT_RESULT_MARKER: &str = "__LANCACHE_DHCP_CONFLICT_RESULT__";
const DHCP_CLIENT_RESULT_MARKER: &str = "__LANCACHE_DHCP_CLIENT_RESULT__";

async fn run_dhcp_probe(docker: &bollard::Docker) -> Result<String, anyhow::Error> {
    let id = docker_client::container_name_for_service(DHCP_PROBE_SERVICE)
        .context("resolve DHCP probe container")?;

    stop_container_if_running(docker, id).await?;
    let started_since = unix_timestamp_seconds();

    docker
        .start_container(id, Some(StartContainerOptionsBuilder::default().build()))
        .await
        .context("start DHCP probe container")?;

    let mut wait = docker.wait_container(
        id,
        Some(
            WaitContainerOptionsBuilder::default()
                .condition("not-running")
                .build(),
        ),
    );
    let wait_result = wait
        .next()
        .await
        .context("wait for DHCP probe container")?
        .context("read DHCP probe wait response")?;

    let output = collect_container_logs_since(docker, id, started_since)
        .await
        .context("read DHCP probe logs")?;
    let output = current_probe_output(&output);

    if wait_result.status_code != 0 {
        return Err(anyhow::anyhow!(
            "DHCP probe container exited with code {}: {}",
            wait_result.status_code,
            output.trim()
        ));
    }

    Ok(output)
}

fn parse_dhcp_probe_report(output: &str) -> DhcpCheckReport {
    DhcpCheckReport {
        conflict: parse_conflict_probe_result(output),
        client: parse_client_probe_result(output),
    }
}

fn parse_conflict_probe_result(output: &str) -> DhcpConflictCheckStatus {
    if let Some((status, detail)) = parse_probe_result_line(output, DHCP_CONFLICT_RESULT_MARKER) {
        return match status {
            "found" if !detail.is_empty() => DhcpConflictCheckStatus::Found {
                output: detail.to_string(),
            },
            "not_found" => DhcpConflictCheckStatus::NotFound,
            "unavailable" => DhcpConflictCheckStatus::Unavailable {
                reason: if detail.is_empty() {
                    "nmap did not return a summary".to_string()
                } else {
                    detail.to_string()
                },
            },
            _ => DhcpConflictCheckStatus::Unavailable {
                reason: format!("unexpected conflict summary: {} {}", status, detail),
            },
        };
    }

    for line in output.lines() {
        let line = normalize_nmap_line(line);
        if let Some(rest) = line.strip_prefix("Server Identifier:") {
            let ip = rest.trim().to_string();
            if !ip.is_empty() {
                return DhcpConflictCheckStatus::Found { output: ip };
            }
        }
    }

    DhcpConflictCheckStatus::NotFound
}

fn parse_client_probe_result(output: &str) -> DhcpClientCheckStatus {
    if let Some((status, detail)) = parse_probe_result_line(output, DHCP_CLIENT_RESULT_MARKER) {
        return match status {
            "passed" => DhcpClientCheckStatus::Passed {
                output: if detail.is_empty() {
                    "dhclient dry-run succeeded".to_string()
                } else {
                    detail.to_string()
                },
            },
            "failed" => DhcpClientCheckStatus::Failed {
                output: if detail.is_empty() {
                    "dhclient dry-run failed".to_string()
                } else {
                    detail.to_string()
                },
            },
            "unavailable" => DhcpClientCheckStatus::Unavailable {
                reason: if detail.is_empty() {
                    "dhclient dry-run unavailable".to_string()
                } else {
                    detail.to_string()
                },
            },
            _ => DhcpClientCheckStatus::Unavailable {
                reason: format!("unexpected client summary: {} {}", status, detail),
            },
        };
    }

    DhcpClientCheckStatus::Unavailable {
        reason: "dhclient summary missing".to_string(),
    }
}

fn parse_probe_result_line<'a>(output: &'a str, marker: &str) -> Option<(&'a str, &'a str)> {
    output.lines().rev().find_map(|line| {
        let line = line.trim();
        let rest = line.strip_prefix(marker)?;
        let rest = rest.trim_start();
        let (status, detail) = rest.split_once(' ').unwrap_or((rest, ""));
        Some((status.trim(), detail.trim()))
    })
}

async fn collect_container_logs_since(
    docker: &bollard::Docker,
    id: &str,
    since: i32,
) -> Result<String, anyhow::Error> {
    let mut logs = docker.logs(
        id,
        Some(
            LogsOptionsBuilder::default()
                .stdout(true)
                .stderr(true)
                .since(since)
                .build(),
        ),
    );

    let mut output = String::new();
    while let Some(chunk) = logs.next().await {
        match chunk.context("read container log chunk")? {
            LogOutput::StdOut { message } | LogOutput::StdErr { message } => {
                output.push_str(&String::from_utf8_lossy(&message));
            }
            _ => {}
        }
    }

    Ok(output)
}

fn current_probe_output(output: &str) -> String {
    output
        .rsplit_once(DHCP_PROBE_START_MARKER)
        .map(|(_, current)| current.to_string())
        .unwrap_or_else(|| output.to_string())
}

fn unix_timestamp_seconds() -> i32 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i32::MAX as u64) as i32)
        .unwrap_or_default()
}

async fn stop_container_if_running(
    docker: &bollard::Docker,
    id: &str,
) -> Result<(), anyhow::Error> {
    if let Err(e) = docker
        .stop_container(
            id,
            Some(StopContainerOptionsBuilder::default().t(5).build()),
        )
        .await
    {
        // Docker returns "not modified" if the one-shot helper is already
        // stopped. That is the expected steady state before a probe run.
        let message = e.to_string();
        if !message.contains("304") && !message.to_ascii_lowercase().contains("not modified") {
            return Err(e).context("stop DHCP probe container");
        }
    }

    Ok(())
}

// ─── Validators ───

fn normalize_mac(mac: &str) -> String {
    // Accept common operator input styles (`aa:bb`, `aa-bb`, `aabb`) by keeping
    // only hex digits, then rebuild the canonical colon-separated form used by
    // Kea reservations. Validation remains separate below, so this helper does
    // not silently accept malformed lengths.
    let hex: String = mac
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();

    // Reinsert a colon before every byte boundary after the first byte.
    hex.chars()
        .enumerate()
        .flat_map(|(i, c)| {
            if i > 0 && i % 2 == 0 {
                vec![':', c]
            } else {
                vec![c]
            }
        })
        .collect()
}

fn is_valid_ip(ip: &str) -> bool {
    parse_ipv4(ip).is_some()
}

fn is_valid_mac(mac: &str) -> bool {
    let cleaned = mac.to_uppercase().replace([':', '-'], "");
    cleaned.len() == 12 && cleaned.chars().all(|c| c.is_ascii_hexdigit())
}

struct DhcpFormValidation<'a> {
    subnet: &'a str,
    pool_start: &'a str,
    pool_end: &'a str,
    gateway: &'a str,
    dns_primary: &'a str,
    dns_secondary: &'a str,
    ntp_servers: &'a str,
    lease_time: &'a str,
}

fn validate_dhcp_form(input: DhcpFormValidation<'_>) -> Result<u32, StatusCode> {
    let (subnet_addr, prefix_len) = parse_cidr(input.subnet).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_start_addr = parse_ipv4(input.pool_start).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_end_addr = parse_ipv4(input.pool_end).ok_or(StatusCode::BAD_REQUEST)?;
    let gateway_addr = parse_ipv4(input.gateway).ok_or(StatusCode::BAD_REQUEST)?;
    let dns_primary_addr = parse_ipv4(input.dns_primary).ok_or(StatusCode::BAD_REQUEST)?;
    let _dns_secondary_addr = if input.dns_secondary.trim().is_empty() {
        dns_primary_addr
    } else {
        parse_ipv4(input.dns_secondary).ok_or(StatusCode::BAD_REQUEST)?
    };

    if !ipv4_in_cidr(subnet_addr, prefix_len, pool_start_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, pool_end_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, gateway_addr)
        || ipv4_to_u32(pool_start_addr) > ipv4_to_u32(pool_end_addr)
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    if !input.ntp_servers.trim().is_empty() && parse_ntp_server_list(input.ntp_servers).is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    let lease_time = input
        .lease_time
        .parse::<u32>()
        .map_err(|_| StatusCode::BAD_REQUEST)?;
    if !(MIN_LEASE_TIME..=MAX_LEASE_TIME).contains(&lease_time) {
        return Err(StatusCode::BAD_REQUEST);
    }

    Ok(lease_time)
}

fn parse_ipv4(ip: &str) -> Option<Ipv4Addr> {
    Ipv4Addr::from_str(ip).ok()
}

fn parse_cidr(cidr: &str) -> Option<(Ipv4Addr, u8)> {
    let (addr, prefix) = cidr.split_once('/')?;
    let network = parse_ipv4(addr)?;
    let prefix_len = prefix.parse::<u8>().ok()?;
    if prefix_len > 32 {
        return None;
    }
    let network_u32 = ipv4_to_u32(network);
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    if prefix_len != 0 && network_u32 & !mask != 0 {
        return None;
    }
    Some((Ipv4Addr::from(network_u32 & mask), prefix_len))
}

fn ipv4_in_cidr(network: Ipv4Addr, prefix_len: u8, ip: Ipv4Addr) -> bool {
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    ipv4_to_u32(network) & mask == ipv4_to_u32(ip) & mask
}

fn ipv4_to_u32(ip: Ipv4Addr) -> u32 {
    u32::from(ip)
}

fn dhcp4_subnets(config: &Value) -> Option<&Vec<Value>> {
    config
        .get("Dhcp4")
        .and_then(|dhcp4| dhcp4.get("subnet4"))
        .and_then(|subnets| subnets.as_array())
}

fn dhcp4_subnets_mut(config: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    config
        .get_mut("Dhcp4")
        .ok_or("Dhcp4 missing")?
        .get_mut("subnet4")
        .ok_or("subnet4 missing")?
        .as_array_mut()
        .ok_or("subnet4 not an array")
}

// Absence of this key means Kea falls back to its own compiled-in default
// list, which includes "hw-address" -- only an explicit, hand-edited global
// list can exclude it (see the call site in add_reservation for why this
// matters: a hw-address reservation Kea will never actually match).
fn global_reservation_identifiers_include_hw_address(config: &Value) -> bool {
    match config
        .get("Dhcp4")
        .and_then(|dhcp4| dhcp4.get("host-reservation-identifiers"))
    {
        None => true,
        Some(value) => value
            .as_array()
            .map(|identifiers| {
                identifiers
                    .iter()
                    .any(|identifier| identifier.as_str() == Some("hw-address"))
            })
            .unwrap_or(false),
    }
}

fn find_subnet_mut(config: &mut Value, subnet_id: u32) -> Result<&mut Value, &'static str> {
    dhcp4_subnets_mut(config)?
        .iter_mut()
        .find(|subnet| subnet["id"].as_u64() == Some(subnet_id as u64))
        .ok_or("subnet not found")
}

struct SubnetValue {
    id: u32,
    subnet: String,
    pool_start: String,
    pool_end: String,
    gateway: String,
    dns_primary: String,
    dns_secondary: String,
    ntp_servers: String,
    domain: String,
    lease_time: u32,
    editable_options: Vec<Value>,
    reservations: Option<Vec<Value>>,
}

fn build_subnet_value(input: SubnetValue) -> Result<Value, &'static str> {
    let mut subnet_value = json!({});
    apply_subnet_value(&mut subnet_value, input)?;
    Ok(subnet_value)
}

fn apply_subnet_value(entry: &mut Value, input: SubnetValue) -> Result<(), &'static str> {
    // Clamp to MAX_LEASE_TIME: doubling the form value alone would let a
    // client at the advertised 7-day cap request up to 14 days from Kea.
    let max_valid_lifetime = input
        .lease_time
        .checked_mul(2)
        .ok_or("lease_time too large")?
        .min(MAX_LEASE_TIME);
    let entry = entry.as_object_mut().ok_or("subnet not an object")?;

    entry.insert("id".to_string(), json!(input.id));
    entry.insert("subnet".to_string(), json!(input.subnet));
    entry.insert(
        "pools".to_string(),
        json!([{"pool": format!("{} - {}", input.pool_start, input.pool_end)}]),
    );
    entry.insert(
        "option-data".to_string(),
        Value::Array(build_subnet_options(
            input.editable_options,
            input.gateway,
            input.dns_primary,
            input.dns_secondary,
            input.ntp_servers,
            input.domain,
        )),
    );
    entry.insert("valid-lifetime".to_string(), json!(input.lease_time));
    entry.insert("max-valid-lifetime".to_string(), json!(max_valid_lifetime));
    entry.remove("default-lease-time");
    entry.remove("max-lease-time");
    // `host-reservation-identifiers` is a Dhcp4-GLOBAL-only parameter in real
    // Kea (confirmed directly against Kea 2.6.3, the version this project
    // ships): setting it here, on the per-subnet object, makes Kea reject
    // the whole config-test/config-set call outright with "spurious
    // 'host-reservation-identifiers' parameter" -- every add_subnet/
    // update_subnet call was broken against real Kea until this was removed.
    // Nothing needs to be written in its place: Kea's own compiled-in
    // global default already includes "hw-address" (confirmed via a live
    // config-get), which is the only identifier type this project's
    // reservation form ever uses, and `kea_config_modify`'s config-get ->
    // config-set round trip already carries that default straight through
    // untouched. The explicit `remove` below is defense-in-depth in case a
    // config ever has this key at subnet scope (e.g. a hand-edited file, or
    // a future regression reintroducing the old write) -- Kea would reject
    // an update to that subnet either way, so stripping it here keeps
    // add_subnet/update_subnet self-healing instead of permanently stuck.
    entry.remove("host-reservation-identifiers");

    if let Some(reservations) = input.reservations {
        entry.insert("reservations".to_string(), Value::Array(reservations));
    }

    Ok(())
}

fn build_subnet_options(
    mut editable_options: Vec<Value>,
    gateway: String,
    dns_primary: String,
    dns_secondary: String,
    ntp_servers: String,
    domain: String,
) -> Vec<Value> {
    editable_options.retain(|option| !is_ui_managed_subnet_option(option));

    editable_options.push(json!({"name": "routers", "data": gateway}));
    editable_options.push(json!({
        "name": "domain-name-servers",
        "data": format_dns_server_option(&dns_primary, &dns_secondary)
    }));
    editable_options.push(json!({"name": "domain-name", "data": domain}));
    editable_options.push(json!({"name": "domain-search", "data": domain}));
    if let Some(data) = format_ntp_server_option(&ntp_servers) {
        editable_options.push(json!({"name": "ntp-servers", "data": data}));
    }
    editable_options
}

fn preserved_subnet_options(subnet: &Value) -> Vec<Value> {
    subnet
        .get("option-data")
        .and_then(|value| value.as_array())
        .map(|options| {
            options
                .iter()
                .filter(|option| !is_ui_managed_subnet_option(option))
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

fn is_ui_managed_subnet_option(option: &Value) -> bool {
    if !is_dhcp4_option_space(option) {
        return false;
    }

    let managed_by_name = option
        .get("name")
        .and_then(|value| value.as_str())
        .map(|name| {
            matches!(
                name,
                "routers" | "domain-name" | "domain-search" | "domain-name-servers" | "ntp-servers"
            )
        })
        .unwrap_or(false);
    let managed_by_code = option
        .get("code")
        .and_then(|value| value.as_u64())
        .map(|code| matches!(code, 3 | 6 | 15 | 42 | 119))
        .unwrap_or(false);

    managed_by_name || managed_by_code
}

fn is_ui_managed_subnet_option_code(code: u16) -> bool {
    matches!(code, 3 | 6 | 15 | 42 | 119)
}

// Kea's own convention: an option-data entry inside a Dhcp4 subnet with no
// explicit "space" field implicitly belongs to the "dhcp4" space (that's the
// only space that makes sense there). Absence must default to true, not
// false, or every option this project itself writes without an explicit
// "space" (see build_subnet_options) would be misclassified as non-dhcp4 by
// this same check the moment it reads its own output back.
fn is_dhcp4_option_space(option: &Value) -> bool {
    option
        .get("space")
        .and_then(|value| value.as_str())
        .map(|space| space == "dhcp4")
        .unwrap_or(true)
}

fn parse_custom_dhcp_option_code(raw: &str) -> Result<u16, &'static str> {
    let code = raw
        .trim()
        .parse::<u16>()
        .map_err(|_| "option code must be a number")?;
    if code == 0 || code > 254 {
        return Err("option code must be between 1 and 254");
    }
    if is_ui_managed_subnet_option_code(code) {
        return Err("option code is managed by dedicated subnet fields");
    }
    Ok(code)
}

fn validate_custom_dhcp_option_data(raw: &str) -> Result<String, &'static str> {
    let data = raw.trim();
    if data.is_empty() {
        return Err("option data must not be empty");
    }
    if data.len() > CUSTOM_DHCP_OPTION_DATA_MAX_LEN {
        return Err("option data is too long");
    }
    if data.chars().any(|ch| ch == '\n' || ch == '\r') {
        return Err("option data must fit on one line");
    }
    Ok(data.to_string())
}

fn is_custom_dhcp4_option(option: &Value) -> bool {
    is_dhcp4_option_space(option)
        && !is_ui_managed_subnet_option(option)
        && option
            .get("code")
            .and_then(|value| value.as_u64())
            .map(|code| (1..=254).contains(&code))
            .unwrap_or(false)
        && option
            .get("data")
            .and_then(|value| value.as_str())
            .is_some()
}

fn custom_subnet_options(subnet: &Value) -> Vec<DhcpOption> {
    subnet
        .get("option-data")
        .and_then(|value| value.as_array())
        .map(|options| {
            options
                .iter()
                .filter(|option| is_custom_dhcp4_option(option))
                .filter_map(|option| {
                    let code = option.get("code")?.as_u64()?;
                    Some(DhcpOption {
                        code: u16::try_from(code).ok()?,
                        data: option.get("data")?.as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn subnet_options_mut(subnet: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if !subnet.contains_key("option-data") {
        subnet.insert("option-data".to_string(), Value::Array(Vec::new()));
    }
    subnet
        .get_mut("option-data")
        .and_then(|value| value.as_array_mut())
        .ok_or("option-data not an array")
}

fn add_custom_subnet_option(subnet: &mut Value, code: u16, data: &str) -> Result<(), &'static str> {
    let options = subnet_options_mut(subnet)?;
    if options.iter().any(|option| {
        is_custom_dhcp4_option(option)
            && option.get("code").and_then(|value| value.as_u64()) == Some(code as u64)
            && option.get("data").and_then(|value| value.as_str()) == Some(data)
    }) {
        return Err("custom option already exists");
    }
    options.push(json!({"space": "dhcp4", "code": code, "data": data}));
    Ok(())
}

fn remove_custom_subnet_option(
    subnet: &mut Value,
    code: u16,
    data: &str,
) -> Result<(), &'static str> {
    let options = subnet_options_mut(subnet)?;
    let before = options.len();
    options.retain(|option| {
        !(is_custom_dhcp4_option(option)
            && option.get("code").and_then(|value| value.as_u64()) == Some(code as u64)
            && option.get("data").and_then(|value| value.as_str()) == Some(data))
    });
    if options.len() == before {
        return Err("custom option not found");
    }
    Ok(())
}

fn split_option_list(raw: &str) -> Vec<String> {
    raw.split(|ch: char| ch == ',' || ch.is_whitespace())
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_string)
        .collect()
}

fn format_dns_server_option(primary: &str, secondary: &str) -> String {
    if secondary.trim().is_empty() || secondary.trim() == primary.trim() {
        primary.trim().to_string()
    } else {
        format!("{}, {}", primary.trim(), secondary.trim())
    }
}

fn format_ntp_server_option(ntp_servers: &str) -> Option<String> {
    let servers = parse_ntp_server_list(ntp_servers);
    if servers.is_empty() {
        None
    } else {
        Some(servers.join(", "))
    }
}

fn parse_ntp_server_list(raw: &str) -> Vec<String> {
    split_option_list(raw)
}

fn parse_subnet_entry(subnet: &Value) -> Subnet {
    let pool = subnet
        .get("pools")
        .and_then(|p| p.get(0))
        .and_then(|p| p.get("pool"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let pool_parts: Vec<&str> = pool.splitn(2, " - ").collect();

    let opt = |name: &str, code: u64| {
        subnet
            .get("option-data")
            .and_then(|od| od.as_array())
            .and_then(|arr| {
                arr.iter().find(|o| {
                    is_dhcp4_option_space(o)
                        && (o.get("name").and_then(|v| v.as_str()) == Some(name)
                            || o.get("code").and_then(|v| v.as_u64()) == Some(code))
                })
            })
            .and_then(|o| o.get("data"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let dns_servers = split_option_list(&opt("domain-name-servers", 6));
    let ntp_servers = opt("ntp-servers", 42);

    Subnet {
        id: subnet.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        subnet: subnet
            .get("subnet")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        pool_start: pool_parts
            .first()
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        pool_end: pool_parts
            .get(1)
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        gateway: opt("routers", 3),
        dns_primary: dns_servers.first().cloned().unwrap_or_default(),
        dns_secondary: dns_servers.get(1).cloned().unwrap_or_default(),
        ntp_servers,
        lease_time: subnet
            .get("valid-lifetime")
            .and_then(|v| v.as_u64())
            .unwrap_or(86400) as u32,
        domain: opt("domain-name", 15),
        custom_options: custom_subnet_options(subnet),
    }
}

// Called from update_subnet when an operator narrows/moves a subnet's CIDR:
// drops any reservation whose static IP would fall outside the new range,
// since Kea rejects a subnet whose own reservations aren't contained in it.
// A reservation with no parseable `ip-address` (e.g. a client-id-only entry
// with no fixed address of its own) has nothing to check against the new
// CIDR, so `.unwrap_or(true)` keeps it rather than dropping it -- there is
// no "outside the subnet" for an entry that was never tied to a specific
// address to begin with.
fn compatible_reservations_for_subnet(
    subnet: &Value,
    cidr: &str,
) -> Result<Vec<Value>, &'static str> {
    let (network, prefix_len) = parse_cidr(cidr).ok_or("invalid subnet")?;
    Ok(subnet
        .get("reservations")
        .and_then(|value| value.as_array())
        .map(|reservations| {
            reservations
                .iter()
                .filter(|reservation| {
                    reservation
                        .get("ip-address")
                        .and_then(|value| value.as_str())
                        .and_then(parse_ipv4)
                        .map(|ip| ipv4_in_cidr(network, prefix_len, ip))
                        .unwrap_or(true)
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default())
}

fn parse_reservation_entry(subnet_id: u32, reservation: &Value) -> Option<Reservation> {
    Some(Reservation {
        subnet_id,
        ip: reservation
            .get("ip-address")
            .and_then(|v| v.as_str())
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "?".to_string()),
        mac: reservation
            .get("hw-address")
            .and_then(|v| v.as_str())
            .map(normalize_mac)
            .unwrap_or_else(|| "?".to_string()),
        hostname: reservation
            .get("hostname")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

fn subnet_reservations_mut(subnet: &mut Value) -> Result<&mut Vec<Value>, &'static str> {
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if !subnet.contains_key("reservations") {
        subnet.insert("reservations".to_string(), Value::Array(Vec::new()));
    }
    subnet
        .get_mut("reservations")
        .and_then(|value| value.as_array_mut())
        .ok_or("reservations not an array")
}

fn upsert_reservation(
    reservations: &mut Vec<Value>,
    reservation: Value,
) -> Result<(), &'static str> {
    let normalized_mac = reservation
        .get("hw-address")
        .and_then(|value| value.as_str())
        .map(normalize_mac)
        .ok_or("reservation missing hw-address")?;

    if let Some(existing) = reservations.iter_mut().find(|existing| {
        existing
            .get("hw-address")
            .and_then(|value| value.as_str())
            .map(normalize_mac)
            == Some(normalized_mac.clone())
    }) {
        let existing = existing
            .as_object_mut()
            .ok_or("existing reservation not an object")?;
        existing.insert("hw-address".to_string(), json!(normalized_mac));
        existing.insert(
            "ip-address".to_string(),
            reservation
                .get("ip-address")
                .cloned()
                .ok_or("reservation missing ip-address")?,
        );
        existing.insert(
            "hostname".to_string(),
            reservation
                .get("hostname")
                .cloned()
                .ok_or("reservation missing hostname")?,
        );
    } else {
        reservations.push(reservation);
    }

    Ok(())
}

fn remove_reservation_entry(reservations: &mut Vec<Value>, mac: &str) {
    let normalized = normalize_mac(mac);
    reservations.retain(|reservation| {
        reservation
            .get("hw-address")
            .and_then(|value| value.as_str())
            .map(normalize_mac)
            != Some(normalized.clone())
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::error::Error;
    use std::sync::Arc;

    macro_rules! validate_test_dhcp_form {
        (
            $subnet:expr,
            $pool_start:expr,
            $pool_end:expr,
            $gateway:expr,
            $dns_primary:expr,
            $dns_secondary:expr,
            $ntp_servers:expr,
            $lease_time:expr $(,)?
        ) => {
            validate_dhcp_form(DhcpFormValidation {
                subnet: $subnet,
                pool_start: $pool_start,
                pool_end: $pool_end,
                gateway: $gateway,
                dns_primary: $dns_primary,
                dns_secondary: $dns_secondary,
                ntp_servers: $ntp_servers,
                lease_time: $lease_time,
            })
        };
    }

    #[derive(Debug)]
    enum MockStep {
        Response(Value),
        Transport(&'static str),
    }

    async fn run_kea_config_modify_with_steps(
        steps: Vec<MockStep>,
        modify: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
    ) -> (Result<(), Box<dyn Error + Send + Sync>>, Vec<Value>) {
        run_kea_config_modify_with_steps_and_sink(steps, modify, |_applied: &Value| {}).await
    }

    // Same mock `post` plumbing as `run_kea_config_modify_with_steps`, but
    // also exposes the `on_write_success` snapshot-sink hook so tests can
    // assert exactly when (#614's) known-good snapshot creation is invoked
    // relative to the confirmed/ambiguous/rollback write outcomes.
    async fn run_kea_config_modify_with_steps_and_sink<S>(
        steps: Vec<MockStep>,
        modify: impl FnOnce(&mut Value) -> Result<(), &'static str> + Send,
        on_write_success: S,
    ) -> (Result<(), Box<dyn Error + Send + Sync>>, Vec<Value>)
    where
        S: FnOnce(&Value) + Send,
    {
        let calls = Arc::new(tokio::sync::Mutex::new(Vec::<Value>::new()));
        let steps = Arc::new(tokio::sync::Mutex::new(VecDeque::from(steps)));
        let lock = tokio::sync::Mutex::new(());

        let calls_for_post = Arc::clone(&calls);
        let steps_for_post = Arc::clone(&steps);
        let post = move |cmd: Value| {
            let calls = Arc::clone(&calls_for_post);
            let steps = Arc::clone(&steps_for_post);
            async move {
                calls.lock().await.push(cmd);
                match steps
                    .lock()
                    .await
                    .pop_front()
                    .expect("unexpected Kea command")
                {
                    MockStep::Response(resp) => Ok(resp),
                    MockStep::Transport(message) => Err(std::io::Error::other(message).into()),
                }
            }
        };

        let result = kea_config_modify_with_post(&lock, post, modify, on_write_success).await;
        let calls = calls.lock().await.clone();
        (result, calls)
    }

    fn kea_success_response() -> Value {
        json!([{ "result": 0 }])
    }

    fn kea_config_get_response(config: Value) -> Value {
        json!([{ "result": 0, "arguments": config }])
    }

    // The probe's two result markers (conflict scan, dhclient dry-run) are
    // parsed independently and can disagree (e.g. a conflict found but the
    // client check still passes) -- overall_status() must reflect whichever
    // signal is worse, not just the last one parsed.
    #[test]
    fn parses_dual_dhcp_probe_report_with_conflict_and_client_success() {
        let report = parse_dhcp_probe_report(
            "__LANCACHE_DHCP_PROBE_START__ 1\n\
             __LANCACHE_DHCP_CONFLICT_RESULT__ found 192.168.1.1\n\
             __LANCACHE_DHCP_CLIENT_RESULT__ passed dhclient succeeded on eth0\n",
        );

        assert_eq!(report.overall_status(), "conflict_found");
        match report.conflict {
            DhcpConflictCheckStatus::Found { output } => assert_eq!(output, "192.168.1.1"),
            other => panic!("unexpected conflict result: {:?}", other),
        }
        match report.client {
            DhcpClientCheckStatus::Passed { output } => {
                assert_eq!(output, "dhclient succeeded on eth0")
            }
            other => panic!("unexpected client result: {:?}", other),
        }
    }

    // A probe run that never reaches the dhclient stage (e.g. the container
    // crashed after the conflict scan) must render as "unavailable", not as
    // a silent pass -- an operator must not read a missing client check as
    // "no problems found".
    #[test]
    fn parses_dual_dhcp_probe_report_marks_missing_client_summary_unavailable() {
        let report = parse_dhcp_probe_report("__LANCACHE_DHCP_PROBE_START__ 1\n");

        assert_eq!(report.overall_status(), "unavailable");
        assert!(matches!(report.conflict, DhcpConflictCheckStatus::NotFound));
        assert!(matches!(
            report.client,
            DhcpClientCheckStatus::Unavailable { .. }
        ));
    }

    // Every DHCP-mutating route calls require_kea_mode() first; if this
    // guard ever accepted DnsmasqProxy/Disabled mode or an empty API URL, a
    // mutation route would try to POST to Kea's control agent with no
    // reachable target instead of failing with a clear "wrong mode" error.
    #[test]
    fn kea_mutation_guard_requires_kea_mode_and_api_url() {
        assert!(kea_api_available(
            crate::config::DhcpMode::Kea,
            "http://dhcp:8000"
        ));
        assert!(!kea_api_available(crate::config::DhcpMode::Kea, ""));
        assert!(!kea_api_available(
            crate::config::DhcpMode::Disabled,
            "http://dhcp:8000"
        ));
        assert!(!kea_api_available(
            crate::config::DhcpMode::DnsmasqProxy,
            "http://dhcp:8000"
        ));
    }

    #[test]
    fn parse_dhcp_mode_input_round_trips_supported_modes() {
        use crate::config::DhcpMode;
        // The mode-switch form is the only writer of DHCP_MODE from the UI, so
        // every supported value must parse back to its enum, and unknown input
        // must be rejected rather than silently coerced to a default.
        for mode in [DhcpMode::Disabled, DhcpMode::Kea, DhcpMode::DnsmasqProxy] {
            assert_eq!(parse_dhcp_mode_input(mode.as_str()), Some(mode));
        }
        // Case/whitespace tolerance mirrors the setup.sh prompt handling.
        assert_eq!(
            parse_dhcp_mode_input("  Dnsmasq-Proxy "),
            Some(DhcpMode::DnsmasqProxy)
        );
        assert_eq!(parse_dhcp_mode_input("dnsmasq"), None);
        assert_eq!(parse_dhcp_mode_input(""), None);
    }

    // validate_dhcp_form's containment/range checks are exactly the kind of
    // logic an off-by-one silently breaks (an inclusive bound written as
    // exclusive, or vice versa) without any compiler help to catch it. This
    // group exhaustively pins every boundary: pool/gateway must sit inside
    // the subnet CIDR, the pool range must not be reversed, and
    // MIN_LEASE_TIME/MAX_LEASE_TIME are both inclusive bounds (60s avoids
    // renewal-storm-inducing leases that are too short; 7 days avoids a
    // lease outliving an operator's ability to reclaim an address from a
    // now-offline device).
    #[test]
    fn accepts_valid_dhcp_form() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    #[test]
    fn accepts_routed_dns_servers_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "10.0.0.10",
            "203.0.113.53",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    #[test]
    fn rejects_pool_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.101.100",
            "198.51.101.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_reversed_pool_range() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.200",
            "198.51.100.100",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_invalid_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "not-a-number",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_gateway_outside_subnet() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.101.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_non_network_cidr() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.5/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_zero_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "0",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_lease_time_below_minimum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "59",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn accepts_lease_time_at_minimum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "60",
        );

        assert_eq!(lease_time.unwrap(), 60);
    }

    #[test]
    fn accepts_lease_time_at_maximum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "604800",
        );

        assert_eq!(lease_time.unwrap(), 604800);
    }

    #[test]
    fn rejects_lease_time_above_maximum() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "604801",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_huge_lease_time() {
        let lease_time = validate_test_dhcp_form!(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "198.51.100.2",
            "198.51.100.3",
            "198.51.100.4",
            "999999999",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    // This test opens the cluster covering kea_config_modify_with_post's
    // whole write-outcome state machine: a confirmed failure (Kea's own
    // error response) always rolls back, but an ambiguous failure (the
    // request itself errored, so it's unknown whether Kea actually applied
    // it) gets a retry first -- rolling back on an ambiguous failure risks
    // reverting a config-write that actually succeeded, and never retrying
    // risks leaving a genuinely-failed write unconfirmed forever. Each test
    // in this cluster pins one path through that decision tree via the mock
    // command sequence it feeds in.
    #[tokio::test]
    async fn kea_config_modify_succeeds_without_rollback() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls.len(), 4);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    // #614's snapshot creation is wired in as a single choke-point hook
    // (`on_write_success`) rather than duplicated into every mutation route,
    // so this locks in both that the hook actually fires on a confirmed
    // config-write success, and that it receives the real applied config
    // (post-modify, post-config-test) -- not the stale pre-modify config --
    // since a snapshot of the wrong generation would make rollback silently
    // restore an older, unintended state.
    #[tokio::test]
    async fn kea_config_modify_invokes_snapshot_sink_with_applied_config_on_success() {
        let initial_config = json!({"Dhcp4": {"subnet4": [{"id": 1}]}});
        let sink_calls: Arc<std::sync::Mutex<Vec<Value>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_calls_for_closure = Arc::clone(&sink_calls);

        let (result, _calls) = run_kea_config_modify_with_steps_and_sink(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
            move |applied: &Value| {
                sink_calls_for_closure.lock().unwrap().push(applied.clone());
            },
        )
        .await;

        assert!(result.is_ok());
        let sink_calls = sink_calls.lock().unwrap();
        assert_eq!(
            sink_calls.len(),
            1,
            "the snapshot sink must run exactly once on a confirmed config-write success"
        );
        assert_eq!(
            sink_calls[0]["Dhcp4"]["subnet4"][1]["id"],
            json!(2),
            "the sink must see the same applied config that was validated and set, not the pre-modify config"
        );
    }

    // A config-write that gets rolled back was, by definition, just proven
    // to fail persisting -- if the snapshot sink fired anyway, a rejected
    // config would get recorded as "known-good" and poison every future
    // rollback target with something that was never actually good.
    #[tokio::test]
    async fn kea_config_modify_does_not_invoke_snapshot_sink_on_rollback() {
        let initial_config = json!({"Dhcp4": {"subnet4": [{"id": 1}]}});
        let sink_calls: Arc<std::sync::Mutex<Vec<Value>>> =
            Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_calls_for_closure = Arc::clone(&sink_calls);

        let (result, _calls) = run_kea_config_modify_with_steps_and_sink(
            vec![
                MockStep::Response(kea_config_get_response(initial_config)),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(json!([{ "result": 1, "text": "write failed" }])),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
            move |applied: &Value| {
                sink_calls_for_closure.lock().unwrap().push(applied.clone());
            },
        )
        .await;

        assert!(result.is_err());
        assert!(
            sink_calls.lock().unwrap().is_empty(),
            "a rolled-back config-write must never be recorded as a known-good snapshot"
        );
    }

    // Regression test for a bug found via live verification against a real
    // Kea 2.6.3 Control Agent (not caught by any prior test, since all of
    // them mock config-get without a `hash` field): the real Control Agent's
    // config-get response is `{"Dhcp4": {...}, "hash": "<digest>"}`, and
    // feeding that whole object straight back as config-test/config-set's
    // `arguments` makes Kea reject the request with
    // "Unsupported 'hash' parameter." on every call. This asserts `hash` is
    // stripped before it reaches either request body (and is absent from the
    // config the `modify` closure receives).
    #[tokio::test]
    async fn kea_config_modify_strips_hash_from_config_get_before_reuse() {
        let config_get_with_hash = json!([{
            "result": 0,
            "arguments": {
                "Dhcp4": {"subnet4": [{"id": 1}]},
                "hash": "0123456789abcdef0123456789abcdef01234567"
            }
        }]);

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(config_get_with_hash),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                assert!(
                    config.get("hash").is_none(),
                    "the modify closure must never see a leftover hash field"
                );
                config["Dhcp4"]["subnet4"]
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?
                    .push(json!({"id": 2}));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        assert!(
            calls[1]["arguments"].get("hash").is_none(),
            "config-test's arguments must not carry the config-get hash field"
        );
        assert!(
            calls[2]["arguments"].get("hash").is_none(),
            "config-set's arguments must not carry the config-get hash field"
        );
    }

    #[tokio::test]
    async fn kea_config_modify_rolls_back_on_confirmed_write_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(json!([{ "result": 1, "text": "write failed" }])),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("write failure should return error");
        let error_message = error.to_string();

        assert!(error_message.contains("rolled back"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-set");
        assert_eq!(calls[4]["arguments"], initial_config);
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    #[tokio::test]
    async fn kea_config_modify_accepts_successful_write_retry_after_ambiguous_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });
        let expected_modified = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    },
                    {
                        "id": 2,
                        "valid-lifetime": 7200
                    }
                ]
            }
        });

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[0]["command"], "config-get");
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "successful write retry should not rollback",
        );
        assert_eq!(calls[1]["arguments"], expected_modified);
        assert_eq!(calls[2]["arguments"], expected_modified);
    }

    #[tokio::test]
    async fn kea_config_modify_does_not_rollback_when_write_retry_confirms_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Response(json!([{ "result": 1, "text": "write failed on retry" }])),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("confirmed retry failure after ambiguous write should error");
        let error_message = error.to_string();

        assert!(error_message.contains("first config-write result was ambiguous"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "confirmed retry failure after ambiguous first write should not rollback blindly",
        );
    }

    #[tokio::test]
    async fn kea_config_modify_does_not_rollback_on_ambiguous_write_failure() {
        let initial_config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 1,
                        "valid-lifetime": 3600
                    }
                ]
            }
        });

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(kea_config_get_response(initial_config.clone())),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Transport("config-write transport failure"),
                MockStep::Transport("config-write transport failure"),
            ],
            |config| {
                let dhcp4 = config.get_mut("Dhcp4").ok_or("Dhcp4 missing")?;
                let subnets = dhcp4
                    .get_mut("subnet4")
                    .ok_or("subnet4 missing")?
                    .as_array_mut()
                    .ok_or("subnet4 not an array")?;
                subnets.push(json!({
                    "id": 2,
                    "valid-lifetime": 7200
                }));
                Ok(())
            },
        )
        .await;

        let error = result.expect_err("ambiguous write should return error");
        let error_message = error.to_string();

        assert!(error_message.contains("could not be confirmed after retry"));
        assert_eq!(calls.len(), 5);
        assert_eq!(calls[3]["command"], "config-write");
        assert_eq!(calls[4]["command"], "config-write");
        assert!(
            !calls.iter().any(|cmd| cmd["command"] == "config-set"
                && cmd.get("arguments") == Some(&initial_config)),
            "ambiguous write failure should not rollback blindly",
        );
    }

    // Reservations live nested inside each subnet4 entry in Kea's config, not
    // in one flat top-level list -- this pins that fetch_reservations_from_config
    // flattens across every subnet (including one with none at all) while
    // still tagging each result with its owning subnet_id, and that a
    // missing hostname renders as "" rather than panicking.
    #[test]
    fn collect_reservations_reads_nested_subnet_entries() {
        let config = json!({
            "Dhcp4": {
                "subnet4": [
                    {
                        "id": 7,
                        "reservations": [
                            {
                                "hw-address": "AA-BB-CC-DD-EE-FF",
                                "ip-address": "10.0.0.50",
                                "hostname": "desktop"
                            },
                            {
                                "hw-address": "11:22:33:44:55:66",
                                "ip-address": "10.0.0.51"
                            }
                        ]
                    },
                    {"id": 8}
                ]
            }
        });

        let reservations = fetch_reservations_from_config(&config);

        assert_eq!(reservations.len(), 2);
        assert_eq!(reservations[0].subnet_id, 7);
        assert_eq!(reservations[0].mac, "aa:bb:cc:dd:ee:ff");
        assert_eq!(reservations[0].hostname, "desktop");
        assert_eq!(reservations[1].mac, "11:22:33:44:55:66");
        assert_eq!(reservations[1].hostname, "");
    }

    // add_reservation's "update by MAC" path (upsert_reservation) must
    // preserve fields it doesn't itself set (option-data, client-classes)
    // when overwriting an existing entry's ip-address/hostname -- otherwise
    // editing a reservation through the Admin UI would silently drop any
    // manually-added Kea options on that host. Matching is by normalized
    // MAC, so "AA-BB-..." must still find "aa:bb:...".
    #[test]
    fn reservation_upsert_and_remove_keep_subnet_state_consistent() {
        let mut subnet = json!({
            "id": 12,
            "reservations": [
                {
                    "hw-address": "aa:bb:cc:dd:ee:ff",
                    "ip-address": "10.0.0.50",
                    "hostname": "old",
                    "option-data": [{"name": "boot-file-name", "data": "pxelinux.0"}],
                    "client-classes": ["known"]
                }
            ]
        });

        {
            let reservations = subnet_reservations_mut(&mut subnet).expect("reservations array");
            upsert_reservation(
                reservations,
                json!({
                    "hw-address": "AA-BB-CC-DD-EE-FF",
                    "ip-address": "10.0.0.60",
                    "hostname": "new"
                }),
            )
            .expect("upsert reservation");
        }

        let reservations = subnet
            .get("reservations")
            .and_then(|value| value.as_array())
            .expect("reservations array");
        assert_eq!(reservations.len(), 1);
        assert_eq!(reservations[0]["ip-address"], "10.0.0.60");
        assert_eq!(reservations[0]["hostname"], "new");
        assert_eq!(reservations[0]["option-data"][0]["data"], "pxelinux.0");
        assert_eq!(reservations[0]["client-classes"][0], "known");

        {
            let reservations = subnet_reservations_mut(&mut subnet).expect("reservations array");
            remove_reservation_entry(reservations, "AA-BB-CC-DD-EE-FF");
        }

        let reservations = subnet
            .get("reservations")
            .and_then(|value| value.as_array())
            .expect("reservations array");
        assert!(reservations.is_empty());
    }

    // max-valid-lifetime must never be computed as double the requested
    // lease time when that would overflow past this project's own
    // MAX_LEASE_TIME cap -- Kea accepts max-valid-lifetime > valid-lifetime,
    // so an uncapped doubling would silently let leases renew past the
    // operator-intended maximum instead of erroring or clamping.
    #[test]
    fn build_subnet_value_clamps_max_valid_lifetime_to_lease_time_cap() {
        let subnet = build_subnet_value(SubnetValue {
            id: 4,
            subnet: "10.0.0.0/24".to_string(),
            pool_start: "10.0.0.10".to_string(),
            pool_end: "10.0.0.200".to_string(),
            gateway: "10.0.0.1".to_string(),
            dns_primary: "10.0.0.2".to_string(),
            dns_secondary: "10.0.0.3".to_string(),
            ntp_servers: "10.0.0.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: MAX_LEASE_TIME,
            editable_options: Vec::new(),
            reservations: None,
        })
        .expect("subnet value");

        assert_eq!(subnet["valid-lifetime"], MAX_LEASE_TIME);
        assert_eq!(subnet["max-valid-lifetime"], MAX_LEASE_TIME);
    }

    // build_subnet_value is only called from add_subnet (new subnet, always
    // reservations: None) and update_subnet (existing subnet, reservations
    // carried through from compatible_reservations_for_subnet) -- this pins
    // that the Some(...) path actually writes the given reservations into
    // the built JSON rather than silently dropping them on update.
    #[test]
    fn build_subnet_value_preserves_reservations_when_present() {
        let reservations = vec![json!({
            "hw-address": "aa:bb:cc:dd:ee:ff",
            "ip-address": "10.0.0.50",
            "hostname": "host"
        })];
        let subnet = build_subnet_value(SubnetValue {
            id: 3,
            subnet: "10.0.0.0/24".to_string(),
            pool_start: "10.0.0.10".to_string(),
            pool_end: "10.0.0.200".to_string(),
            gateway: "10.0.0.1".to_string(),
            dns_primary: "10.0.0.2".to_string(),
            dns_secondary: "10.0.0.3".to_string(),
            ntp_servers: "10.0.0.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: Some(reservations.clone()),
        })
        .expect("subnet value");

        assert_eq!(subnet["id"], 3);
        assert_eq!(subnet["valid-lifetime"], 3600);
        assert_eq!(subnet["max-valid-lifetime"], 7200);
        assert_eq!(subnet["reservations"], Value::Array(reservations));
    }

    // update_subnet only ever sends the fields the Admin UI's edit form
    // actually exposes -- anything Kea/an operator set outside that form
    // (ddns-qualifying-suffix, relay, a vendor-space option, reservations)
    // must survive an unrelated edit untouched, not get silently erased by
    // this function rewriting the whole subnet object from scratch. The
    // vendor-space option (code 3 under "vendor-foo", not "dhcp4") is the
    // key case: it shares a numeric code with the UI-managed "routers"
    // option but must never be treated as the same option.
    #[test]
    fn apply_subnet_value_preserves_unmanaged_kea_fields_and_options() {
        let mut subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"code": 3, "data": "10.0.0.254"},
                {"name": "domain-name-servers", "data": "10.0.0.2, 10.0.0.3"},
                {"name": "ntp-servers", "data": "10.0.0.4"},
                {"name": "domain-name", "data": "old.lan"},
                {"code": 15, "data": "old-by-code.lan"},
                {"name": "domain-search", "data": "old.lan"},
                {"code": 119, "data": "old-search-by-code.lan"},
                {"space": "vendor-foo", "code": 3, "data": "keep-vendor-route"}
            ],
            "valid-lifetime": 3600,
            "reservations": [
                {
                    "hw-address": "aa:bb:cc:dd:ee:ff",
                    "ip-address": "10.0.0.50"
                }
            ],
            "ddns-qualifying-suffix": "lan",
            "relay": {"ip-addresses": ["10.0.0.1"]}
        });

        let preserved_options = preserved_subnet_options(&subnet);

        apply_subnet_value(
            &mut subnet,
            SubnetValue {
                id: 3,
                subnet: "10.0.1.0/24".to_string(),
                pool_start: "10.0.1.10".to_string(),
                pool_end: "10.0.1.200".to_string(),
                gateway: "10.0.1.1".to_string(),
                dns_primary: "10.0.1.2".to_string(),
                dns_secondary: "10.0.1.3".to_string(),
                ntp_servers: "10.0.1.4".to_string(),
                domain: "new.lan".to_string(),
                lease_time: 7200,
                editable_options: preserved_options,
                reservations: None,
            },
        )
        .expect("apply subnet value");

        assert_eq!(subnet["subnet"], "10.0.1.0/24");
        assert_eq!(subnet["valid-lifetime"], 7200);
        assert_eq!(subnet["max-valid-lifetime"], 14400);
        assert_eq!(subnet["reservations"][0]["ip-address"], "10.0.0.50");
        assert_eq!(subnet["ddns-qualifying-suffix"], "lan");
        assert_eq!(subnet["relay"]["ip-addresses"][0], "10.0.0.1");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert!(!options
            .iter()
            .any(|option| option["code"] == 3 && is_dhcp4_option_space(option)));
        assert!(!options
            .iter()
            .any(|option| option["code"] == 15 && is_dhcp4_option_space(option)));
        assert!(!options
            .iter()
            .any(|option| option["code"] == 119 && is_dhcp4_option_space(option)));
        assert!(options.iter().any(|option| option["space"] == "vendor-foo"
            && option["code"] == 3
            && option["data"] == "keep-vendor-route"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name-servers"
                && option["data"] == "10.0.1.2, 10.0.1.3"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "ntp-servers" && option["data"] == "10.0.1.4"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.1.1"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name" && option["data"] == "new.lan"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-search" && option["data"] == "new.lan"));
    }

    // Kea's own config-get response identifies well-known options by numeric
    // code, not the human-readable "name" the Admin UI writes -- parse_subnet_entry
    // must recognize both forms, or a subnet fetched straight from Kea (as
    // opposed to one this project itself just wrote) would render its
    // gateway/DNS/NTP/domain fields as empty on the settings page.
    #[test]
    fn parse_subnet_entry_reads_managed_options_by_numeric_code() {
        let subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"code": 3, "data": "10.0.0.1"},
                {"code": 6, "data": "10.0.0.2, 10.0.0.3"},
                {"code": 15, "data": "lan.example"},
                {"code": 42, "data": "10.0.0.4"}
            ],
            "valid-lifetime": 3600
        });

        let parsed = parse_subnet_entry(&subnet);

        assert_eq!(parsed.gateway, "10.0.0.1");
        assert_eq!(parsed.dns_primary, "10.0.0.2");
        assert_eq!(parsed.dns_secondary, "10.0.0.3");
        assert_eq!(parsed.ntp_servers, "10.0.0.4");
        assert_eq!(parsed.domain, "lan.example");
    }

    // Companion to the numeric-code test above: a vendor-space option that
    // happens to share code 3 (or the "domain-name" name) with a managed
    // dhcp4 option must NOT be misread as that managed option -- otherwise
    // an unrelated vendor option's data could silently overwrite the parsed
    // gateway/domain shown in the Admin UI.
    #[test]
    fn parse_subnet_entry_ignores_non_dhcp4_matching_option_codes() {
        let subnet = json!({
            "id": 3,
            "subnet": "10.0.0.0/24",
            "pools": [{"pool": "10.0.0.10 - 10.0.0.200"}],
            "option-data": [
                {"space": "vendor-foo", "code": 3, "data": "not-a-router"},
                {"space": "vendor-foo", "name": "domain-name", "data": "not-a-domain"},
                {"space": "dhcp4", "code": 3, "data": "10.0.0.1"},
                {"name": "domain-name", "data": "lan.example"}
            ],
            "valid-lifetime": 3600
        });

        let parsed = parse_subnet_entry(&subnet);

        assert_eq!(parsed.gateway, "10.0.0.1");
        assert_eq!(parsed.domain, "lan.example");
    }

    // build_subnet_value starts from an empty editable_options list (unlike
    // apply_subnet_value, which is handed the PREVIOUS subnet's preserved
    // options) -- a fresh subnet must only ever get the fields its own form
    // submitted (here: no NTP servers were given, so no ntp-servers option
    // should appear), never carry over state from an unrelated subnet.
    #[test]
    fn build_subnet_value_does_not_inherit_unmanaged_options_from_other_subnets() {
        let subnet = build_subnet_value(SubnetValue {
            id: 4,
            subnet: "10.0.2.0/24".to_string(),
            pool_start: "10.0.2.10".to_string(),
            pool_end: "10.0.2.200".to_string(),
            gateway: "10.0.2.1".to_string(),
            dns_primary: "10.0.2.2".to_string(),
            dns_secondary: "10.0.2.3".to_string(),
            ntp_servers: String::new(),
            domain: "new.lan".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: None,
        })
        .expect("subnet value");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert_eq!(options.len(), 4);
        assert!(options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.2.1"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "domain-name-servers"
                && option["data"] == "10.0.2.2, 10.0.2.3"));
        assert!(!options.iter().any(|option| option["name"] == "ntp-servers"));
    }

    // editable_options (custom, non-UI-managed options like boot-file-name
    // or an arbitrary vendor option) must pass through build_subnet_value
    // unchanged, on top of the UI-managed fields the form itself sets --
    // proves the two option sources are merged, not mutually exclusive.
    #[test]
    fn build_subnet_value_preserves_editable_extra_option_data() {
        let subnet = build_subnet_value(SubnetValue {
            id: 5,
            subnet: "10.0.3.0/24".to_string(),
            pool_start: "10.0.3.10".to_string(),
            pool_end: "10.0.3.200".to_string(),
            gateway: "10.0.3.1".to_string(),
            dns_primary: "10.0.3.2".to_string(),
            dns_secondary: "10.0.3.3".to_string(),
            ntp_servers: "10.0.3.4".to_string(),
            domain: "new.lan".to_string(),
            lease_time: 7200,
            editable_options: vec![
                json!({"name": "boot-file-name", "data": "pxelinux.0"}),
                json!({"name": "vendor-foo", "data": "keep-me"}),
            ],
            reservations: None,
        })
        .expect("subnet value");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert!(options
            .iter()
            .any(|option| option["name"] == "boot-file-name" && option["data"] == "pxelinux.0"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "vendor-foo" && option["data"] == "keep-me"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "ntp-servers" && option["data"] == "10.0.3.4"));
    }

    // The custom-option form (add_subnet_option) must refuse the 5 codes
    // the dedicated gateway/DNS/domain/NTP fields already own -- otherwise
    // an operator could set the same option two conflicting ways, and
    // whichever write happened last would silently win.
    #[test]
    fn custom_dhcp_option_validation_rejects_managed_codes() {
        for code in ["3", "6", "15", "42", "119"] {
            assert!(parse_custom_dhcp_option_code(code).is_err());
        }

        assert_eq!(
            parse_custom_dhcp_option_code("66").expect("custom code"),
            66
        );
        assert!(validate_custom_dhcp_option_data("pxelinux.0").is_ok());
        assert!(validate_custom_dhcp_option_data("").is_err());
        assert!(validate_custom_dhcp_option_data("line\nbreak").is_err());
    }

    // ─── Issue #450: dnsmasq relay/proxy field validators ───
    //
    // These three validators are this project's only defense before an
    // operator-submitted value is rendered unquoted into dnsmasq.conf
    // directives -- the "junk" cases in each test below (a shell metachar,
    // an embedded space/comma/newline) are exactly the inputs that could
    // otherwise corrupt the generated config or, worse, inject a second
    // directive. `dnsmasq --test` is still the authoritative fail-closed
    // gate (see entrypoint.sh), but these validators exist so the Admin UI
    // gives immediate feedback instead of a config-write failure much later.

    #[test]
    fn interface_name_validator_accepts_typical_names_and_rejects_junk() {
        assert!(is_valid_interface_name("eth0"));
        assert!(is_valid_interface_name("br-lan.100"));
        assert!(is_valid_interface_name("eno1_2"));
        assert!(!is_valid_interface_name(""));
        assert!(!is_valid_interface_name("eth0;rm -rf /"));
        assert!(!is_valid_interface_name("eth 0"));
        assert!(!is_valid_interface_name(&"a".repeat(65)));
    }

    #[test]
    fn domain_name_validator_accepts_typical_domains_and_rejects_junk() {
        assert!(is_valid_domain_name("lan.local"));
        assert!(is_valid_domain_name("example.com"));
        assert!(is_valid_domain_name("a"));
        assert!(!is_valid_domain_name(""));
        assert!(!is_valid_domain_name("-lan.local"));
        assert!(!is_valid_domain_name("lan-.local"));
        assert!(!is_valid_domain_name("lan..local"));
        assert!(!is_valid_domain_name("lan local"));
    }

    #[test]
    fn boot_filename_validator_accepts_paths_and_rejects_whitespace_or_commas() {
        assert!(is_valid_boot_filename("pxelinux.0"));
        assert!(is_valid_boot_filename("efi/bootx64.efi"));
        assert!(!is_valid_boot_filename(""));
        assert!(!is_valid_boot_filename("pxelinux 0"));
        assert!(!is_valid_boot_filename("pxelinux.0,evil"));
        // Trailing/leading whitespace is trimmed before the check (same as
        // is_valid_domain_name), so an *embedded* newline is the meaningful
        // rejection case, not a merely-trailing one.
        assert!(!is_valid_boot_filename("pxelinux\n.0"));
    }

    // The Admin UI's textarea (one CODE:VALUE per line) and the persisted
    // DHCP_PROXY_CUSTOM_OPTIONS storage format (';'-joined single line) are
    // two different shapes for the same data -- this proves converting
    // form -> storage -> form is lossless, and that blank lines in the
    // textarea are simply skipped rather than producing an empty entry.
    #[test]
    fn custom_options_form_parses_valid_lines_and_round_trips_through_storage() {
        let storage = parse_custom_options_form("60:PXEClient\n93:0\n\n").unwrap();
        assert_eq!(storage, "60:PXEClient;93:0");

        let form = custom_options_storage_to_form(&storage);
        assert_eq!(form, "60:PXEClient\n93:0");
    }

    #[test]
    fn custom_options_form_rejects_managed_codes_and_malformed_lines() {
        assert!(
            parse_custom_options_form("3:10.0.0.1").is_err(),
            "router code is managed by a dedicated field"
        );
        assert!(parse_custom_options_form("60").is_err(), "missing colon");
        assert!(
            parse_custom_options_form("abc:foo").is_err(),
            "non-numeric code"
        );
        assert!(parse_custom_options_form("60:").is_err(), "empty data");
        assert!(
            parse_custom_options_form("60:foo;bar").is_err(),
            "';' inside option data must be rejected -- it is the entry separator in storage"
        );
    }

    // An operator who has never used the custom-option textarea (or clears
    // it entirely) must get back an empty DHCP_PROXY_CUSTOM_OPTIONS value,
    // not an error or a spurious single empty entry.
    #[test]
    fn custom_options_form_empty_input_yields_empty_storage() {
        assert_eq!(parse_custom_options_form("").unwrap(), "");
        assert_eq!(parse_custom_options_form("   \n  \n").unwrap(), "");
        assert_eq!(custom_options_storage_to_form(""), "");
    }

    // The Admin UI's "custom options" list must show exactly the options
    // this project doesn't already manage through a dedicated field or a
    // different space -- excludes the "routers" name-managed option and a
    // non-dhcp4-space option (vendor-foo), and only ever includes entries
    // that carry an explicit numeric dhcp4 "code": a name-only entry like
    // this fixture's "boot-file-name" (no "code" field at all) never shows
    // up here as if it were a free custom option. Code 66, unmanaged by any
    // dedicated field, IS expected to show through.
    #[test]
    fn custom_subnet_options_only_expose_free_dhcp4_code_options() {
        let subnet = json!({
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"code": 6, "data": "10.0.0.2"},
                {"space": "dhcp4", "code": 66, "data": "10.0.0.20"},
                {"space": "vendor-foo", "code": 67, "data": "vendor-value"},
                {"name": "boot-file-name", "data": "legacy-name-only"}
            ]
        });

        let options = custom_subnet_options(&subnet);

        assert_eq!(options.len(), 1);
        assert_eq!(options[0].code, 66);
        assert_eq!(options[0].data, "10.0.0.20");
    }

    // add/remove_custom_subnet_option must operate on option-data as a
    // shared array without disturbing entries neither call touches (the
    // managed "routers" option, and a different custom option this call
    // isn't removing) -- and adding the exact same code+data twice must be
    // rejected, not silently duplicated.
    #[test]
    fn custom_subnet_option_add_and_remove_preserve_managed_options() {
        let mut subnet = json!({
            "option-data": [
                {"name": "routers", "data": "10.0.0.1"},
                {"space": "dhcp4", "code": 67, "data": "bootx64.efi"}
            ]
        });

        add_custom_subnet_option(&mut subnet, 66, "10.0.0.20").expect("add option");
        assert!(add_custom_subnet_option(&mut subnet, 66, "10.0.0.20").is_err());

        let options = custom_subnet_options(&subnet);
        assert_eq!(options.len(), 2);
        assert!(options
            .iter()
            .any(|option| option.code == 66 && option.data == "10.0.0.20"));

        remove_custom_subnet_option(&mut subnet, 67, "bootx64.efi").expect("remove option");
        let raw_options = subnet["option-data"].as_array().expect("option-data array");
        assert!(raw_options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.0.1"));
        assert!(!raw_options.iter().any(|option| option["code"] == 67));
    }

    // Pins kea_lease_del_result's own documented distinction: Kea's
    // CONTROL_RESULT_EMPTY (3) means "no matching lease" -- an ordinary
    // race, not a server error -- and must map to a different outcome than
    // a genuine error response, so release_lease can return 404 instead of
    // 500 for the empty case.
    #[test]
    fn kea_lease_del_result_reports_success_not_found_and_error_distinctly() {
        let success = json!([{"result": 0, "text": "Lease deleted."}]);
        assert_eq!(kea_lease_del_result(&success), LeaseDelOutcome::Released);

        let empty = json!([{"result": 3, "text": "No lease found."}]);
        assert_eq!(kea_lease_del_result(&empty), LeaseDelOutcome::NotFound);

        let error = json!([{"result": 1, "text": "unable to communicate with the daemon"}]);
        assert_eq!(
            kea_lease_del_result(&error),
            LeaseDelOutcome::Error("unable to communicate with the daemon".to_string())
        );
    }

    // Exercises compatible_reservations_for_subnet's own documented contract
    // (see that function's comment): an in-range reservation is kept, an
    // out-of-range one is dropped, and the client-id-only entry (no
    // ip-address at all) is kept unconditionally since there is nothing to
    // check it against the new CIDR.
    #[test]
    fn compatible_reservations_drop_addresses_outside_new_subnet() {
        let subnet = json!({
            "reservations": [
                {"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.2.50"},
                {"hw-address": "11:22:33:44:55:66", "ip-address": "10.0.3.50"},
                {"client-id": "01:02:03"}
            ]
        });

        let reservations =
            compatible_reservations_for_subnet(&subnet, "10.0.2.0/24").expect("reservations");

        assert_eq!(reservations.len(), 2);
        assert!(reservations
            .iter()
            .any(|reservation| reservation["ip-address"] == "10.0.2.50"));
        assert!(!reservations
            .iter()
            .any(|reservation| reservation["ip-address"] == "10.0.3.50"));
        assert!(reservations
            .iter()
            .any(|reservation| reservation["client-id"] == "01:02:03"));
    }

    // Regression coverage for a real bug found by driving real Kea 2.6.3
    // (not a mock): a previous version of apply_subnet_value wrote a
    // "host-reservation-identifiers" array directly onto the per-subnet
    // JSON object. Confirmed live against Kea's actual Control Agent that
    // this is rejected outright -- "spurious 'host-reservation-identifiers'
    // parameter" -- because that parameter only exists at Dhcp4-GLOBAL
    // scope in Kea's real schema, never per subnet. Every existing test for
    // this function mocked Kea's config-test/config-set responses as a bare
    // `{"result": 0}` regardless of what was actually sent, so none of them
    // could have caught a schema violation like this -- mirroring exactly
    // how the earlier `hash`-field regression in kea_config_modify_with_post
    // went undetected the same way (a mocked config-get response that never
    // included that field). This test asserts directly on the built subnet
    // JSON (not through a mock), matching the shape a real Kea instance
    // would receive and validate.
    #[test]
    fn build_subnet_value_never_sets_host_reservation_identifiers_at_subnet_scope() {
        let subnet = build_subnet_value(SubnetValue {
            id: 6,
            subnet: "10.0.4.0/24".to_string(),
            pool_start: "10.0.4.10".to_string(),
            pool_end: "10.0.4.200".to_string(),
            gateway: "10.0.4.1".to_string(),
            dns_primary: "10.0.4.2".to_string(),
            dns_secondary: "10.0.4.3".to_string(),
            ntp_servers: "10.0.4.4".to_string(),
            domain: "lan.example".to_string(),
            lease_time: 3600,
            editable_options: Vec::new(),
            reservations: Some(vec![json!({
                "hw-address": "aa:bb:cc:dd:ee:ff",
                "ip-address": "10.0.4.50"
            })]),
        })
        .expect("subnet value");

        assert!(
            subnet.get("host-reservation-identifiers").is_none(),
            "subnet4 entries must never carry host-reservation-identifiers -- \
             real Kea rejects it at subnet scope"
        );
    }

    // Same regression, but for an existing subnet that already (incorrectly,
    // from before this fix) has the key set at subnet scope -- apply_subnet_value
    // must actively strip it, not just avoid adding a new one, so an
    // operator's next edit through the Admin UI self-heals instead of
    // staying permanently broken.
    #[test]
    fn apply_subnet_value_strips_pre_existing_host_reservation_identifiers_at_subnet_scope() {
        let mut subnet = json!({
            "id": 6,
            "host-reservation-identifiers": ["hw-address"]
        });

        apply_subnet_value(
            &mut subnet,
            SubnetValue {
                id: 6,
                subnet: "10.0.4.0/24".to_string(),
                pool_start: "10.0.4.10".to_string(),
                pool_end: "10.0.4.200".to_string(),
                gateway: "10.0.4.1".to_string(),
                dns_primary: "10.0.4.2".to_string(),
                dns_secondary: "10.0.4.3".to_string(),
                ntp_servers: "10.0.4.4".to_string(),
                domain: "lan.example".to_string(),
                lease_time: 3600,
                editable_options: Vec::new(),
                reservations: None,
            },
        )
        .expect("apply subnet value");

        assert!(subnet.get("host-reservation-identifiers").is_none());
    }

    // End-to-end regression through the exact real Kea command sequence
    // add_reservation drives (config-get -> config-test -> config-set ->
    // config-write), asserting neither config-test's nor config-set's
    // request body ever contains host-reservation-identifiers on the
    // subnet -- the same assertion style
    // kea_config_modify_strips_hash_from_config_get_before_reuse already
    // uses for the `hash`-field regression, applied to this bug instead.
    #[tokio::test]
    async fn kea_config_modify_reservation_add_never_sends_host_reservation_identifiers_at_subnet_scope(
    ) {
        let config_get_response = kea_config_get_response(json!({
            "Dhcp4": {
                "subnet4": [{"id": 1, "reservations": []}]
            }
        }));

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![
                MockStep::Response(config_get_response),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
                MockStep::Response(kea_success_response()),
            ],
            |config| {
                let subnets = dhcp4_subnets_mut(config)?;
                let subnet = subnets
                    .iter_mut()
                    .find(|s| s["id"].as_u64() == Some(1))
                    .ok_or("subnet not found")?;
                let reservations = subnet_reservations_mut(subnet)?;
                upsert_reservation(
                    reservations,
                    json!({"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.4.50"}),
                )?;
                Ok(())
            },
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(calls[1]["command"], "config-test");
        assert_eq!(calls[2]["command"], "config-set");
        for call in &calls[1..=2] {
            let subnet = &call["arguments"]["Dhcp4"]["subnet4"][0];
            assert!(
                subnet.get("host-reservation-identifiers").is_none(),
                "{} must not send host-reservation-identifiers on the subnet -- real Kea rejects it there",
                call["command"]
            );
        }
    }

    // Regression coverage for a Codex review finding on this same PR: removing
    // the per-subnet write (above) means correctness now depends entirely on
    // the *global* Dhcp4.host-reservation-identifiers list still including
    // "hw-address". This project's own shipped config never sets that key
    // (relies on Kea's compiled-in default), but nothing stopped an operator
    // from hand-editing it to something narrower -- these three cases pin the
    // helper's behavior for each state that key can be in.
    #[test]
    fn global_reservation_identifiers_include_hw_address_when_key_absent() {
        let config = json!({"Dhcp4": {"subnet4": []}});
        assert!(global_reservation_identifiers_include_hw_address(&config));
    }

    #[test]
    fn global_reservation_identifiers_include_hw_address_when_explicitly_listed() {
        let config = json!({
            "Dhcp4": {"host-reservation-identifiers": ["duid", "hw-address"]}
        });
        assert!(global_reservation_identifiers_include_hw_address(&config));
    }

    #[test]
    fn global_reservation_identifiers_exclude_hw_address_when_narrowed() {
        let config = json!({
            "Dhcp4": {"host-reservation-identifiers": ["client-id"]}
        });
        assert!(!global_reservation_identifiers_include_hw_address(&config));
    }

    // End-to-end: add_reservation's guard must reject the request *before*
    // ever sending config-test/config-set -- otherwise the write would still
    // race Kea's own silent (non-)matching behavior the Codex finding warned
    // about. Only a config-get call should happen; asserting `calls.len()`
    // pins that config-test/config-set are never reached.
    #[tokio::test]
    async fn kea_config_modify_rejects_reservation_add_when_global_identifiers_exclude_hw_address()
    {
        let config_get_response = kea_config_get_response(json!({
            "Dhcp4": {
                "host-reservation-identifiers": ["client-id"],
                "subnet4": [{"id": 1, "reservations": []}]
            }
        }));

        let (result, calls) = run_kea_config_modify_with_steps(
            vec![MockStep::Response(config_get_response)],
            |config| {
                if !global_reservation_identifiers_include_hw_address(config) {
                    return Err(
                        "cannot add a hw-address reservation: this Kea config's global \
                         Dhcp4.host-reservation-identifiers list does not include \
                         \"hw-address\", so Kea would never match it",
                    );
                }
                let subnets = dhcp4_subnets_mut(config)?;
                let subnet = subnets
                    .iter_mut()
                    .find(|s| s["id"].as_u64() == Some(1))
                    .ok_or("subnet not found")?;
                let reservations = subnet_reservations_mut(subnet)?;
                upsert_reservation(
                    reservations,
                    json!({"hw-address": "aa:bb:cc:dd:ee:ff", "ip-address": "10.0.4.50"}),
                )?;
                Ok(())
            },
        )
        .await;

        assert!(result.is_err());
        assert_eq!(calls.len(), 1, "only config-get should have been called");
        assert_eq!(calls[0]["command"], "config-get");
    }
}
