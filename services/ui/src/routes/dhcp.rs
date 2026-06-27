use crate::docker_client::exec_in_container;
use crate::AppState;
use axum::extract::{Form, State};
use axum::http::StatusCode;
use axum::response::{Html, Redirect};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use tera::Context;

// ─── Data Structures ───

#[derive(Debug)]
enum DhcpCheckStatus {
    Found(String),
    NotFound,
    Unavailable(String),
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Subnet {
    pub id: u32,
    pub subnet: String,
    pub pool_start: String,
    pub pool_end: String,
    pub gateway: String,
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

// ─── Handlers ───

pub async fn dhcp_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "dhcp");
    ctx.insert("csrf_token", &state.csrf_token);
    ctx.insert("dhcp_api_url", &state.config.dhcp_api_url);
    crate::routes::insert_csrf_token(&mut ctx, &state);

    if !state.config.dhcp_api_url.is_empty() {
        let subnets = fetch_subnets(&state).await.unwrap_or_default();
        let (leases, reservations) = tokio::join!(
            fetch_leases(&state),
            fetch_all_reservations(&state, &subnets)
        );
        ctx.insert("subnets", &subnets);
        ctx.insert("leases", &leases.unwrap_or_default());
        ctx.insert("reservations", &reservations.unwrap_or_default());
    } else {
        let empty: Vec<Subnet> = Vec::new();
        ctx.insert("subnets", &empty);
        ctx.insert("leases", &Vec::<Lease>::new());
        ctx.insert("reservations", &Vec::<Reservation>::new());
    }

    crate::routes::render(&state.templates, "dhcp.html", &ctx)
}

pub async fn add_subnet(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AddSubnetForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
    if !is_valid_cidr(&form.subnet)
        || !is_valid_ip(&form.pool_start)
        || !is_valid_ip(&form.pool_end)
        || !is_valid_ip(&form.gateway)
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let lease_time: u32 = form.lease_time.parse().unwrap_or(86400);

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

        subnets.push(json!({
            "id": next_id,
            "subnet": form.subnet,
            "pools": [{"pool": format!("{} - {}", form.pool_start, form.pool_end)}],
            "option-data": [
                {"name": "routers", "data": form.gateway},
                {"name": "domain-name", "data": form.domain},
                {"name": "domain-search", "data": form.domain}
            ],
            "default-lease-time": lease_time,
            "max-lease-time": lease_time * 2,
            "host-reservation-identifiers": ["hw-address"]
        }));
        Ok(())
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn update_subnet(
    State(state): State<Arc<AppState>>,
    Form(form): Form<UpdateSubnetForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
    if !is_valid_cidr(&form.subnet)
        || !is_valid_ip(&form.pool_start)
        || !is_valid_ip(&form.pool_end)
        || !is_valid_ip(&form.gateway)
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let lease_time: u32 = form.lease_time.parse().unwrap_or(86400);
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

        *entry = json!({
            "id": subnet_id,
            "subnet": form.subnet,
            "pools": [{"pool": format!("{} - {}", form.pool_start, form.pool_end)}],
            "option-data": [
                {"name": "routers", "data": form.gateway},
                {"name": "domain-name", "data": form.domain},
                {"name": "domain-search", "data": form.domain}
            ],
            "default-lease-time": lease_time,
            "max-lease-time": lease_time * 2,
            "host-reservation-identifiers": ["hw-address"]
        });
        Ok(())
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_subnet(
    State(state): State<Arc<AppState>>,
    Form(form): Form<RemoveSubnetForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
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
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Redirect::to("/dhcp"))
}

pub async fn add_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AddReservationForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
    if !is_valid_mac(&form.mac) || !is_valid_ip(&form.ip) {
        return Err(StatusCode::BAD_REQUEST);
    }
    call_kea_reservation_add(&state, form.subnet_id, &form.mac, &form.ip, &form.hostname)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<RemoveReservationForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
    call_kea_reservation_del(&state, form.subnet_id, &form.mac)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn check_dhcp_conflict(State(state): State<Arc<AppState>>) -> Json<Value> {
    let status = check_other_dhcp(&state).await;
    match status {
        DhcpCheckStatus::Found(ip) => Json(json!({
            "status": "found",
            "output": ip
        })),
        DhcpCheckStatus::NotFound => Json(json!({
            "status": "not_found"
        })),
        DhcpCheckStatus::Unavailable(reason) => Json(json!({
            "status": "unavailable",
            "reason": reason
        })),
    }
}

// ─── Kea API Core ───

async fn kea_post(
    state: &AppState,
    cmd: &Value,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("{}/", state.config.dhcp_api_url);
    Ok(state
        .http_client
        .post(&url)
        .header("Content-Type", "application/json")
        .basic_auth("admin", Some(&state.config.dhcp_api_token))
        .json(cmd)
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
async fn kea_config_modify<F>(
    state: &AppState,
    modify: F,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    F: FnOnce(&mut Value) -> Result<(), &'static str> + Send,
{
    let resp = kea_post(
        state,
        &json!({"command": "config-get", "service": ["dhcp4"]}),
    )
    .await?;
    kea_result(&resp)?;

    let mut config = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .cloned()
        .ok_or("config-get: missing arguments")?;

    modify(&mut config).map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;

    let test_resp = kea_post(
        state,
        &json!({"command": "config-test", "service": ["dhcp4"], "arguments": config.clone()}),
    )
    .await?;
    kea_result(&test_resp)?;

    let set_resp = kea_post(
        state,
        &json!({"command": "config-set", "service": ["dhcp4"], "arguments": config}),
    )
    .await?;
    kea_result(&set_resp)?;

    let write_resp = kea_post(
        state,
        &json!({"command": "config-write", "service": ["dhcp4"]}),
    )
    .await?;
    kea_result(&write_resp)?;

    Ok(())
}

// ─── Data Fetchers ───

async fn fetch_subnets(
    state: &AppState,
) -> Result<Vec<Subnet>, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        &json!({"command": "config-get", "service": ["dhcp4"]}),
    )
    .await?;
    kea_result(&resp)?;

    let subnets_json = resp
        .get(0)
        .and_then(|r| r.get("arguments"))
        .and_then(|a| a.get("Dhcp4"))
        .and_then(|d| d.get("subnet4"))
        .and_then(|s| s.as_array())
        .cloned()
        .unwrap_or_default();

    Ok(subnets_json
        .iter()
        .map(|s| {
            let pool = s
                .get("pools")
                .and_then(|p| p.get(0))
                .and_then(|p| p.get("pool"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let pool_parts: Vec<&str> = pool.splitn(2, " - ").collect();

            let opt = |name: &str| {
                s.get("option-data")
                    .and_then(|od| od.as_array())
                    .and_then(|arr| {
                        arr.iter()
                            .find(|o| o.get("name").and_then(|v| v.as_str()) == Some(name))
                    })
                    .and_then(|o| o.get("data"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            };

            Subnet {
                id: s.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
                subnet: s
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
                gateway: opt("routers"),
                lease_time: s
                    .get("default-lease-time")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(86400) as u32,
                domain: opt("domain-name"),
            }
        })
        .collect())
}

async fn fetch_leases(
    state: &AppState,
) -> Result<Vec<Lease>, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        &json!({"command": "lease4-get-all", "service": ["dhcp4"]}),
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
    subnets: &[Subnet],
) -> Result<Vec<Reservation>, Box<dyn std::error::Error + Send + Sync>> {
    let mut all = Vec::new();
    for subnet in subnets {
        let resp = kea_post(
            state,
            &json!({
                "command": "reservation-get-all",
                "service": ["dhcp4"],
                "arguments": {"subnet-id": subnet.id}
            }),
        )
        .await?;

        if let Some(res_array) = resp
            .get(0)
            .and_then(|r| r.get("arguments"))
            .and_then(|a| a.get("reservations"))
            .and_then(|r| r.as_array())
        {
            for res in res_array {
                all.push(Reservation {
                    subnet_id: subnet.id,
                    ip: res
                        .get("ip-address")
                        .and_then(|v| v.as_str())
                        .unwrap_or("?")
                        .to_string(),
                    mac: res
                        .get("hw-address")
                        .and_then(|v| v.as_str())
                        .unwrap_or("?")
                        .to_string(),
                    hostname: res
                        .get("hostname")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                });
            }
        }
    }
    Ok(all)
}

async fn call_kea_reservation_add(
    state: &AppState,
    subnet_id: u32,
    mac: &str,
    ip: &str,
    hostname: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        &json!({
            "command": "reservation-add",
            "service": ["dhcp4"],
            "arguments": {
                "reservation": {
                    "subnet-id": subnet_id,
                    "hw-address": mac,
                    "ip-address": ip,
                    "hostname": hostname
                }
            }
        }),
    )
    .await?;
    kea_result(&resp)
}

async fn call_kea_reservation_del(
    state: &AppState,
    subnet_id: u32,
    mac: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        &json!({
            "command": "reservation-del",
            "service": ["dhcp4"],
            "arguments": {
                "subnet-id": subnet_id,
                "identifier-type": "hw-address",
                "identifier": normalize_mac(mac)
            }
        }),
    )
    .await?;
    kea_result(&resp)
}

async fn check_other_dhcp(state: &AppState) -> DhcpCheckStatus {
    let output = match exec_in_container(
        &state.docker,
        "dhcp",
        vec![
            "nmap",
            "--script",
            "broadcast-dhcp-discover",
            "-e",
            "any",
            "--script-args",
            "broadcast-dhcp-discover.timeout=5",
        ],
    )
    .await
    {
        Ok(out) => out,
        Err(e) => {
            // Check if the error is due to nmap not being found
            let err_msg = e.to_string();
            if err_msg.contains("nmap")
                || err_msg.contains("not found")
                || err_msg.contains("No such file")
            {
                return DhcpCheckStatus::Unavailable(
                    "nmap is not installed in the DHCP container".to_string(),
                );
            }
            return DhcpCheckStatus::Unavailable(format!(
                "Failed to execute DHCP check: {}",
                err_msg
            ));
        }
    };

    // Parse "Server Identifier: 192.168.1.1" from nmap output
    for line in output.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Server Identifier:") {
            let ip = rest.trim().to_string();
            if !ip.is_empty() {
                return DhcpCheckStatus::Found(ip);
            }
        }
    }
    DhcpCheckStatus::NotFound
}

// ─── Validators ───

fn normalize_mac(mac: &str) -> String {
    let hex: String = mac
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();
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

fn is_valid_cidr(cidr: &str) -> bool {
    let parts: Vec<&str> = cidr.split('/').collect();
    if parts.len() != 2 {
        return false;
    }
    is_valid_ip(parts[0]) && parts[1].parse::<u8>().ok().is_some_and(|n| n <= 32)
}

fn is_valid_ip(ip: &str) -> bool {
    ip.split('.').filter_map(|o| o.parse::<u8>().ok()).count() == 4
}

fn is_valid_mac(mac: &str) -> bool {
    let cleaned = mac.to_uppercase().replace([':', '-'], "");
    cleaned.len() == 12 && cleaned.chars().all(|c| c.is_ascii_hexdigit())
}
