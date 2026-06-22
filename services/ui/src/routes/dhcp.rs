use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::response::{Html, Redirect};
use axum::http::StatusCode;
use serde::{Deserialize, Serialize};
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

#[derive(Serialize, Deserialize, Debug)]
pub struct KeaResponse {
    result: u32,
    text: Option<String>,
}

pub async fn dhcp_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "dhcp");
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);

    // TODO: fetch leases and reservations from Kea API
    ctx.insert("leases", &Vec::<String>::new());
    ctx.insert("reservations", &Vec::<String>::new());

    crate::routes::render(&state.templates, "dhcp.html", &ctx)
}

pub async fn update_subnet(
    State(state): State<Arc<AppState>>,
    Form(form): Form<SubnetForm>,
) -> Result<Redirect, StatusCode> {
    // Validate CIDR format and IP addresses
    if !is_valid_cidr(&form.subnet) {
        return Err(StatusCode::BAD_REQUEST);
    }
    if !is_valid_ip(&form.pool_start) || !is_valid_ip(&form.pool_end) || !is_valid_ip(&form.gateway) {
        return Err(StatusCode::BAD_REQUEST);
    }

    // TODO: Update DHCP config and restart Kea
    // For now, just redirect back
    Ok(Redirect::to("/dhcp"))
}

pub async fn add_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<StaticReservationForm>,
) -> Result<Redirect, StatusCode> {
    if !is_valid_mac(&form.mac) || !is_valid_ip(&form.ip) {
        return Err(StatusCode::BAD_REQUEST);
    }

    // TODO: Call Kea API to add reservation
    // POST to {dhcp_api_url} with command "reservation-add"

    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<StaticReservationForm>,
) -> Result<Redirect, StatusCode> {
    // TODO: Call Kea API to remove reservation
    // POST to {dhcp_api_url} with command "reservation-del"

    Ok(Redirect::to("/dhcp"))
}

pub async fn check_dhcp_conflict(State(state): State<Arc<AppState>>) -> Html<String> {
    // TODO: Run dhcping or nmap to detect other DHCP servers
    let html = r#"{"dhcp_found": false, "server_ip": null}"#;
    Html(html.to_string())
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
