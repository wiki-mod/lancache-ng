//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI DHCP routes. Renders Kea DHCP subnets, leases, reservations, and
//! dual DHCP probe checks, and applies guarded DHCP config mutations through
//! the Kea control-agent with rollback handling for failed persistence.
//!
//! Docker exec is intentionally not used here. The UI talks to a narrowed
//! Docker socket proxy, so DHCP conflict discovery runs through a predeclared
//! one-shot helper container that can only be started, waited on, and logged.

use crate::{docker_client, AppState};
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
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tera::Context;

// ─── Constants ───

const MIN_LEASE_TIME: u32 = 60;
const MAX_LEASE_TIME: u32 = 604_800; // 7 days

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
    ctx.insert("active_page", "dhcp");
    ctx.insert("dhcp_mode", &dhcp_mode.as_str());
    ctx.insert("dhcp_has_kea", &dhcp_has_kea);
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);
    ctx.insert("dhcp_dns_primary", &dhcp_dns_primary);
    ctx.insert("dhcp_dns_secondary", &dhcp_dns_secondary);
    ctx.insert("dhcp_ntp_servers", &dhcp_ntp_servers);
    ctx.insert("dhcp_proxy_subnet_start", &dhcp_proxy_subnet_start);
    ctx.insert("dhcp_upstream_dhcp_ip", &dhcp_upstream_dhcp_ip);
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
            (
                "DHCP_NTP_SERVERS",
                state.config.effective_dhcp_ntp_servers(),
            ),
        ],
    )?;
    Ok(Redirect::to("/dhcp"))
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
            reservation_identifiers: default_reservation_identifiers(),
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
        let reservation_identifiers = reservation_identifiers_for_subnet(entry, &reservations);
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
                reservation_identifiers,
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
        let subnets = dhcp4_subnets_mut(config)?;
        let subnet = subnets
            .iter_mut()
            .find(|s| s["id"].as_u64() == Some(form.subnet_id as u64))
            .ok_or("subnet not found")?;
        ensure_subnet_reservation_identifier(subnet, "hw-address")?;
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

pub async fn check_dhcp_conflict(State(state): State<Arc<AppState>>) -> Json<Value> {
    let report = check_dhcp_probe(&state).await;
    Json(json!({
        "status": report.overall_status(),
        "conflict": report.conflict,
        "client": report.client,
    }))
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
async fn kea_config_modify<F>(state: &AppState, modify: F) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
{
    kea_config_modify_with_post(&state.kea_config_lock, |cmd| kea_post(state, cmd), modify).await
}

async fn kea_config_modify_with_post<F, P, Fut>(
    lock: &tokio::sync::Mutex<()>,
    mut post: P,
    modify: F,
) -> KeaResult
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
    P: FnMut(Value) -> Fut + Send,
    Fut: Future<Output = KeaResponse> + Send,
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

    // Step 2: Save old config for potential rollback
    let old_config = config.clone();

    // Step 3: Apply modifications
    modify(&mut config).map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;

    // Step 4: Validate new config
    let test_resp =
        post(json!({"command": "config-test", "service": ["dhcp4"], "arguments": config.clone()}))
            .await?;
    kea_result(&test_resp)?;

    // Step 5: Apply new config at runtime
    let set_resp =
        post(json!({"command": "config-set", "service": ["dhcp4"], "arguments": config})).await?;
    kea_result(&set_resp)?;

    // Step 6: Persist config to disk.
    match kea_write_config(&mut post).await {
        KeaWriteOutcome::Success => Ok(()),
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
                KeaWriteOutcome::Success => Ok(()),
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
    let dns_secondary_addr = if input.dns_secondary.trim().is_empty() {
        dns_primary_addr
    } else {
        parse_ipv4(input.dns_secondary).ok_or(StatusCode::BAD_REQUEST)?
    };

    if !ipv4_in_cidr(subnet_addr, prefix_len, pool_start_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, pool_end_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, gateway_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, dns_primary_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, dns_secondary_addr)
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
    reservation_identifiers: Vec<Value>,
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
    let reservation_identifiers = if input.reservation_identifiers.is_empty() {
        default_reservation_identifiers()
    } else {
        input.reservation_identifiers
    };
    entry.insert(
        "host-reservation-identifiers".to_string(),
        Value::Array(reservation_identifiers),
    );
    entry.remove("default-lease-time");
    entry.remove("max-lease-time");

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

fn is_dhcp4_option_space(option: &Value) -> bool {
    option
        .get("space")
        .and_then(|value| value.as_str())
        .map(|space| space == "dhcp4")
        .unwrap_or(true)
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
    }
}

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

fn default_reservation_identifiers() -> Vec<Value> {
    vec![json!("hw-address")]
}

fn reservation_identifiers_for_subnet(subnet: &Value, reservations: &[Value]) -> Vec<Value> {
    let mut identifiers = subnet
        .get("host-reservation-identifiers")
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();

    for (field, identifier) in [
        ("hw-address", "hw-address"),
        ("duid", "duid"),
        ("client-id", "client-id"),
        ("circuit-id", "circuit-id"),
    ] {
        if reservations
            .iter()
            .any(|reservation| reservation.get(field).is_some())
        {
            push_identifier_once(&mut identifiers, identifier);
        }
    }

    if identifiers.is_empty() {
        default_reservation_identifiers()
    } else {
        identifiers
    }
}

fn ensure_subnet_reservation_identifier(
    subnet: &mut Value,
    identifier: &str,
) -> Result<(), &'static str> {
    let inferred_identifiers = reservation_identifiers_for_subnet(
        subnet,
        subnet
            .get("reservations")
            .and_then(|value| value.as_array())
            .map(|reservations| reservations.as_slice())
            .unwrap_or(&[]),
    );
    let subnet = subnet.as_object_mut().ok_or("subnet not an object")?;
    if !subnet.contains_key("host-reservation-identifiers") {
        subnet.insert(
            "host-reservation-identifiers".to_string(),
            Value::Array(inferred_identifiers),
        );
    }
    let identifiers = subnet
        .get_mut("host-reservation-identifiers")
        .and_then(|value| value.as_array_mut())
        .ok_or("host-reservation-identifiers not an array")?;
    push_identifier_once(identifiers, identifier);
    Ok(())
}

fn push_identifier_once(identifiers: &mut Vec<Value>, identifier: &str) {
    if !identifiers
        .iter()
        .any(|value| value.as_str() == Some(identifier))
    {
        identifiers.push(json!(identifier));
    }
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

        let result = kea_config_modify_with_post(&lock, post, modify).await;
        let calls = calls.lock().await.clone();
        (result, calls)
    }

    fn kea_success_response() -> Value {
        json!([{ "result": 0 }])
    }

    fn kea_config_get_response(config: Value) -> Value {
        json!([{ "result": 0, "arguments": config }])
    }

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
            reservation_identifiers: default_reservation_identifiers(),
        })
        .expect("subnet value");

        assert_eq!(subnet["valid-lifetime"], MAX_LEASE_TIME);
        assert_eq!(subnet["max-valid-lifetime"], MAX_LEASE_TIME);
    }

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
            reservation_identifiers: default_reservation_identifiers(),
        })
        .expect("subnet value");

        assert_eq!(subnet["id"], 3);
        assert_eq!(subnet["valid-lifetime"], 3600);
        assert_eq!(subnet["max-valid-lifetime"], 7200);
        assert_eq!(subnet["reservations"], Value::Array(reservations));
    }

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
                reservation_identifiers: default_reservation_identifiers(),
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
            reservation_identifiers: default_reservation_identifiers(),
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
            reservation_identifiers: default_reservation_identifiers(),
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

    #[test]
    fn reservation_identifiers_keep_existing_and_present_reservation_types() {
        let subnet = json!({
            "host-reservation-identifiers": ["client-id"],
        });
        let reservations = vec![
            json!({"hw-address": "aa:bb:cc:dd:ee:ff"}),
            json!({"duid": "00:01:00:01"}),
        ];

        let identifiers = reservation_identifiers_for_subnet(&subnet, &reservations);

        assert_eq!(identifiers[0], "client-id");
        assert!(identifiers
            .iter()
            .any(|identifier| identifier.as_str() == Some("hw-address")));
        assert!(identifiers
            .iter()
            .any(|identifier| identifier.as_str() == Some("duid")));
    }

    #[test]
    fn ensure_subnet_reservation_identifier_adds_hw_address_for_mac_reservations() {
        let mut subnet = json!({
            "host-reservation-identifiers": ["client-id"]
        });

        ensure_subnet_reservation_identifier(&mut subnet, "hw-address")
            .expect("reservation identifier");

        let identifiers = subnet["host-reservation-identifiers"]
            .as_array()
            .expect("identifiers");
        assert!(identifiers
            .iter()
            .any(|identifier| identifier.as_str() == Some("client-id")));
        assert!(identifiers
            .iter()
            .any(|identifier| identifier.as_str() == Some("hw-address")));
    }

    #[test]
    fn ensure_subnet_reservation_identifier_preserves_implicit_identifiers() {
        let mut subnet = json!({
            "reservations": [
                {"client-id": "01:02:03", "ip-address": "10.0.0.50"},
                {"duid": "00:01:00:01", "ip-address": "10.0.0.51"},
                {"circuit-id": "uplink-1", "ip-address": "10.0.0.52"}
            ]
        });

        ensure_subnet_reservation_identifier(&mut subnet, "hw-address")
            .expect("reservation identifier");

        let identifiers = subnet["host-reservation-identifiers"]
            .as_array()
            .expect("identifiers");
        for expected in ["client-id", "duid", "circuit-id", "hw-address"] {
            assert!(identifiers
                .iter()
                .any(|identifier| identifier.as_str() == Some(expected)));
        }
    }
}
