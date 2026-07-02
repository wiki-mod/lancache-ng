use crate::docker_client::exec_in_container;
use crate::AppState;
use axum::extract::{Form, State};
use axum::http::StatusCode;
use axum::response::{Html, Redirect};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::Ipv4Addr;
use std::str::FromStr;
use std::sync::Arc;
use tera::Context;

// ─── Constants ───

const MIN_LEASE_TIME: u32 = 60;
const MAX_LEASE_TIME: u32 = 604_800; // 7 days

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

    crate::routes::render(&state.templates, "dhcp.html", &ctx)
}

pub async fn add_subnet(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AddSubnetForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
    let lease_time = validate_dhcp_form(
        &form.subnet,
        &form.pool_start,
        &form.pool_end,
        &form.gateway,
        &form.lease_time,
    )?;

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
            domain: form.domain,
            lease_time,
            preserved_options: Vec::new(),
            reservations: None,
            reservation_identifiers: default_reservation_identifiers(),
        })?);
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
    let lease_time = validate_dhcp_form(
        &form.subnet,
        &form.pool_start,
        &form.pool_end,
        &form.gateway,
        &form.lease_time,
    )?;
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
        let preserved_options = preserved_subnet_options(entry);
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
                domain: form.domain,
                lease_time,
                preserved_options,
                reservations: Some(reservations),
                reservation_identifiers,
            },
        )?;
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
                "hostname": form.hostname
            }),
        )?;
        Ok(())
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Redirect::to("/dhcp"))
}

pub async fn remove_reservation(
    State(state): State<Arc<AppState>>,
    Form(form): Form<RemoveReservationForm>,
) -> Result<Redirect, StatusCode> {
    crate::routes::verify_csrf_token(&state, &form.csrf_token)?;
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
    let _guard = state.kea_config_lock.lock().await;

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

async fn fetch_dhcp_config(
    state: &AppState,
) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
    let resp = kea_post(
        state,
        &json!({"command": "config-get", "service": ["dhcp4"]}),
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
) -> Result<Vec<Reservation>, Box<dyn std::error::Error + Send + Sync>> {
    Ok(fetch_reservations_from_config(
        &fetch_dhcp_config(state).await?,
    ))
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

    // Parse "Server Identifier: 198.51.100.1" from nmap output
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

fn is_valid_ip(ip: &str) -> bool {
    parse_ipv4(ip).is_some()
}

fn is_valid_mac(mac: &str) -> bool {
    let cleaned = mac.to_uppercase().replace([':', '-'], "");
    cleaned.len() == 12 && cleaned.chars().all(|c| c.is_ascii_hexdigit())
}

fn validate_dhcp_form(
    subnet: &str,
    pool_start: &str,
    pool_end: &str,
    gateway: &str,
    lease_time: &str,
) -> Result<u32, StatusCode> {
    let (subnet_addr, prefix_len) = parse_cidr(subnet).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_start_addr = parse_ipv4(pool_start).ok_or(StatusCode::BAD_REQUEST)?;
    let pool_end_addr = parse_ipv4(pool_end).ok_or(StatusCode::BAD_REQUEST)?;
    let gateway_addr = parse_ipv4(gateway).ok_or(StatusCode::BAD_REQUEST)?;

    if !ipv4_in_cidr(subnet_addr, prefix_len, pool_start_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, pool_end_addr)
        || !ipv4_in_cidr(subnet_addr, prefix_len, gateway_addr)
        || ipv4_to_u32(pool_start_addr) > ipv4_to_u32(pool_end_addr)
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    let lease_time = lease_time
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
    domain: String,
    lease_time: u32,
    preserved_options: Vec<Value>,
    reservations: Option<Vec<Value>>,
    reservation_identifiers: Vec<Value>,
}

fn build_subnet_value(input: SubnetValue) -> Result<Value, &'static str> {
    let mut subnet_value = json!({});
    apply_subnet_value(&mut subnet_value, input)?;
    Ok(subnet_value)
}

fn apply_subnet_value(entry: &mut Value, input: SubnetValue) -> Result<(), &'static str> {
    let max_valid_lifetime = input
        .lease_time
        .checked_mul(2)
        .ok_or("lease_time too large")?;
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
            input.preserved_options,
            input.gateway,
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
    mut preserved_options: Vec<Value>,
    gateway: String,
    domain: String,
) -> Vec<Value> {
    preserved_options.retain(|option| !is_ui_managed_subnet_option(option));

    preserved_options.push(json!({"name": "routers", "data": gateway}));
    preserved_options.push(json!({"name": "domain-name", "data": domain}));
    preserved_options.push(json!({"name": "domain-search", "data": domain}));
    preserved_options
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
        .map(|name| matches!(name, "routers" | "domain-name" | "domain-search"))
        .unwrap_or(false);
    let managed_by_code = option
        .get("code")
        .and_then(|value| value.as_u64())
        .map(|code| matches!(code, 3 | 15 | 119))
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

    #[test]
    fn accepts_valid_dhcp_form() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "86400",
        );

        assert_eq!(lease_time.unwrap(), 86400);
    }

    #[test]
    fn rejects_pool_outside_subnet() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.101.100",
            "198.51.101.200",
            "198.51.100.1",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_reversed_pool_range() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.200",
            "198.51.100.100",
            "198.51.100.1",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_invalid_lease_time() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "not-a-number",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_gateway_outside_subnet() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.101.1",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_non_network_cidr() {
        let lease_time = validate_dhcp_form(
            "198.51.100.5/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "86400",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_zero_lease_time() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "0",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_lease_time_below_minimum() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "59",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn accepts_lease_time_at_minimum() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "60",
        );

        assert_eq!(lease_time.unwrap(), 60);
    }

    #[test]
    fn accepts_lease_time_at_maximum() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "604800",
        );

        assert_eq!(lease_time.unwrap(), 604800);
    }

    #[test]
    fn rejects_lease_time_above_maximum() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "604801",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn rejects_huge_lease_time() {
        let lease_time = validate_dhcp_form(
            "198.51.100.0/24",
            "198.51.100.100",
            "198.51.100.200",
            "198.51.100.1",
            "999999999",
        );

        assert_eq!(lease_time, Err(StatusCode::BAD_REQUEST));
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
            domain: "lan.example".to_string(),
            lease_time: 3600,
            preserved_options: Vec::new(),
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
                domain: "new.lan".to_string(),
                lease_time: 7200,
                preserved_options,
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
                && option["data"] == "10.0.0.2, 10.0.0.3"));
        assert!(options
            .iter()
            .any(|option| option["name"] == "ntp-servers" && option["data"] == "10.0.0.4"));
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
                {"code": 15, "data": "lan.example"}
            ],
            "valid-lifetime": 3600
        });

        let parsed = parse_subnet_entry(&subnet);

        assert_eq!(parsed.gateway, "10.0.0.1");
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
            domain: "new.lan".to_string(),
            lease_time: 3600,
            preserved_options: Vec::new(),
            reservations: None,
            reservation_identifiers: default_reservation_identifiers(),
        })
        .expect("subnet value");

        let options = subnet["option-data"].as_array().expect("option-data array");
        assert_eq!(options.len(), 3);
        assert!(options
            .iter()
            .any(|option| option["name"] == "routers" && option["data"] == "10.0.2.1"));
        assert!(!options.iter().any(|option| option["name"] == "ntp-servers"));
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
