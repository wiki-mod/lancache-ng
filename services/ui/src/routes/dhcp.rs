use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::response::{Html, Redirect};
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use tera::Context;

#[derive(Deserialize)]
pub struct SubnetForm {
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
    pub lease_time: String,
    pub domain: String,
    pub ntp_servers: String,
}

#[derive(Deserialize)]
pub struct StaticReservationForm {
    pub mac: String,
    pub ip: String,
    pub hostname: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Lease {
    pub ip: String,
    pub mac: String,
    pub hostname: String,
    pub expires: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Reservation {
    pub ip: String,
    pub mac: String,
    pub hostname: String,
}

pub async fn dhcp_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "dhcp");
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);

    let mut leases = Vec::new();
    let mut reservations = Vec::new();

    // Fetch leases from Kea API
    if !state.config.dhcp_api_url.is_empty() {
        if let Ok(lease_list) = fetch_leases(&state).await {
            leases = lease_list;
        }
        if let Ok(res_list) = fetch_reservations(&state).await {
            reservations = res_list;
        }
    }

    ctx.insert("leases", &leases);
    ctx.insert("reservations", &reservations);

    crate::routes::render(&state.templates, "dhcp.html", &ctx)
}

pub async fn update_subnet(
    State(_state): State<Arc<AppState>>,
    Form(form): Form<SubnetForm>,
) -> Result<Redirect, StatusCode> {
    // Validate CIDR format and IP addresses
    if !is_valid_cidr(&form.subnet) {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !is_valid_ip(&form.pool_start) || !is_valid_ip(&form.pool_end) || !is_valid_ip(&form.gateway) {
        return Err(StatusCode::BAD_REQUEST);
    }

    // TODO: Update DHCP config via Kea Control Agent
    // This would involve: 1) modifying the config, 2) reloading via config-set, 3) restarting

    Ok(Redirect::to("/dhcp"))
}

pub async fn add_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<StaticReservationForm>,
) -> Result<Redirect, StatusCode> {
    if !is_valid_mac(&form.mac) || !is_valid_ip(&form.ip) {
        return Err(StatusCode::BAD_REQUEST);
    }

    if call_kea_reservation_add(&state, &form.mac, &form.ip, &form.hostname)
        .await
        .is_ok()
    {
        Ok(Redirect::to("/dhcp"))
    } else {
        Err(StatusCode::INTERNAL_SERVER_ERROR)
    }
}

pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<StaticReservationForm>,
) -> Result<Redirect, StatusCode> {
    if call_kea_reservation_del(&state, &form.mac).await.is_ok() {
        Ok(Redirect::to("/dhcp"))
    } else {
        Err(StatusCode::INTERNAL_SERVER_ERROR)
    }
}

pub async fn check_dhcp_conflict(State(state): State<Arc<AppState>>) -> Html<String> {
    // Try to detect other DHCP servers via docker exec dhcping
    let conflict_result = check_other_dhcp(&state).await;
    let json = json!({
        "dhcp_found": conflict_result.is_some(),
        "server_ip": conflict_result
    });
    Html(json.to_string())
}

// ─── Kea API Helpers ───

async fn fetch_leases(state: &AppState) -> Result<Vec<Lease>, Box<dyn std::error::Error>> {
    let url = format!("{}/", state.config.dhcp_api_url);
    let cmd = json!({
        "command": "lease4-get-all",
        "service": ["dhcp4"]
    });

    let resp = state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?
        .json::<Value>()
        .await?;

    let mut leases = Vec::new();
    if let Some(result) = resp.get(0).and_then(|r| r.get("arguments")).and_then(|a| a.get("leases")) {
        if let Some(lease_array) = result.as_array() {
            for lease in lease_array {
                leases.push(Lease {
                    ip: lease.get("ip-address").and_then(|v| v.as_str()).unwrap_or("?").to_string(),
                    mac: lease.get("hw-address").and_then(|v| v.as_str()).unwrap_or("?").to_string(),
                    hostname: lease.get("hostname").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    expires: lease.get("cltt").and_then(|v| v.as_i64()).unwrap_or(0).to_string(),
                });
            }
        }
    }

    Ok(leases)
}

async fn fetch_reservations(state: &AppState) -> Result<Vec<Reservation>, Box<dyn std::error::Error>> {
    let url = format!("{}/", state.config.dhcp_api_url);
    let cmd = json!({
        "command": "reservation-get-all",
        "service": ["dhcp4"]
    });

    let resp = state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?
        .json::<Value>()
        .await?;

    let mut reservations = Vec::new();
    if let Some(result) = resp.get(0).and_then(|r| r.get("arguments")).and_then(|a| a.get("reservations")) {
        if let Some(res_array) = result.as_array() {
            for res in res_array {
                reservations.push(Reservation {
                    ip: res.get("ip-address").and_then(|v| v.as_str()).unwrap_or("?").to_string(),
                    mac: res.get("hw-address").and_then(|v| v.as_str()).unwrap_or("?").to_string(),
                    hostname: res.get("hostname").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                });
            }
        }
    }

    Ok(reservations)
}

async fn call_kea_reservation_add(
    state: &AppState,
    mac: &str,
    ip: &str,
    hostname: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let url = format!("{}/", state.config.dhcp_api_url);
    let cmd = json!({
        "command": "reservation-add",
        "service": ["dhcp4"],
        "arguments": {
            "reservation": {
                "hw-address": mac,
                "ip-address": ip,
                "hostname": hostname
            }
        }
    });

    state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?;

    Ok(())
}

async fn call_kea_reservation_del(
    state: &AppState,
    mac: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let url = format!("{}/", state.config.dhcp_api_url);
    let cmd = json!({
        "command": "reservation-del",
        "service": ["dhcp4"],
        "arguments": {
            "reservation": {
                "hw-address": mac
            }
        }
    });

    state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(&cmd)
        .send()
        .await?;

    Ok(())
}

async fn check_other_dhcp(_state: &AppState) -> Option<String> {
    // TODO: Detect other DHCP servers via dhcping in the DHCP container
    // For now, always return None (no conflict detected)
    // This will be implemented later with proper docker exec support
    None
}

fn is_valid_cidr(cidr: &str) -> bool {
    // Simple validation: should be like 10.0.0.0/24
    let parts: Vec<&str> = cidr.split('/').collect();
    if parts.len() != 2 {
        return false;
    }
    is_valid_ip(parts[0]) && parts[1].parse::<u8>().ok().map_or(false, |n| n <= 32)
}

fn is_valid_ip(ip: &str) -> bool {
    ip.split('.')
        .filter_map(|octet| octet.parse::<u8>().ok())
        .count()
        == 4
}

fn is_valid_mac(mac: &str) -> bool {
    // MAC address: AA:BB:CC:DD:EE:FF or AABBCCDDEEFF
    let cleaned = mac.to_uppercase().replace(":", "").replace("-", "");
    cleaned.len() == 12 && cleaned.chars().all(|c| c.is_ascii_hexdigit())
}
