use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::response::{Html, Redirect};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::Arc;
use tera::Context;

#[derive(Deserialize)]
pub struct AddForm {
    pub domain: String,
}

#[derive(Deserialize)]
pub struct LanRecordForm {
    pub name: String,
    pub record_type: String,
    pub content: String,
    pub ttl: Option<u32>,
}

#[derive(Deserialize)]
pub struct AaaaFilterForm {
    #[serde(default)]
    pub enabled: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct RRset {
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: String,
    pub ttl: u32,
    pub records: Vec<Record>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Record {
    pub content: String,
    pub disabled: bool,
}

pub async fn domains_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let dns_domains = read_domain_file(&state.config.cdn_domains_file);
    let ssl_domains = read_domain_file(&state.config.ssl_domains_file);

    let lan_records = fetch_lan_records(&state).await;
    let aaaa_filter_enabled = is_aaaa_filter_enabled(&state).await;

    let mut ctx = Context::new();
    ctx.insert("dns_domains", &dns_domains);
    ctx.insert("ssl_domains", &ssl_domains);
    ctx.insert("lan_records", &lan_records);
    ctx.insert("aaaa_filter_enabled", &aaaa_filter_enabled);
    ctx.insert("active_page", "domains");

    crate::routes::render(&state.templates, "domains.html", &ctx)
}

pub async fn add_dns(State(state): State<Arc<AppState>>, Form(form): Form<AddForm>) -> Redirect {
    let domain = form.domain.trim().to_lowercase();
    if is_valid_domain(&domain) {
        let wrote = {
            let _guard = state.file_lock.lock().expect("file lock poisoned");
            append_domain(&state.config.cdn_domains_file, &domain)
        };
        if let Err(e) = wrote {
            tracing::error!("Failed to write dns domain: {}", e);
        } else {
            flush_recursor_cache(&state).await;
        }
    }
    Redirect::to("/domains")
}

pub async fn remove_dns(State(state): State<Arc<AppState>>, Form(form): Form<AddForm>) -> Redirect {
    let domain = form.domain.trim().to_string();
    let removed = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        remove_domain(&state.config.cdn_domains_file, &domain)
    };
    if let Err(e) = removed {
        tracing::error!("Failed to remove dns domain: {}", e);
    } else {
        flush_recursor_cache(&state).await;
    }
    Redirect::to("/domains")
}

pub async fn add_ssl(State(state): State<Arc<AppState>>, Form(form): Form<AddForm>) -> Redirect {
    let domain = form.domain.trim().to_lowercase();
    if is_valid_domain(&domain) {
        let wrote = {
            let _guard = state.file_lock.lock().expect("file lock poisoned");
            append_domain(&state.config.ssl_domains_file, &domain)
        };
        if let Err(e) = wrote {
            tracing::error!("Failed to write ssl domain: {}", e);
        } else {
            restart_ssl(&state).await;
        }
    }
    Redirect::to("/domains")
}

pub async fn remove_ssl(State(state): State<Arc<AppState>>, Form(form): Form<AddForm>) -> Redirect {
    let domain = form.domain.trim().to_string();
    let removed = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        remove_domain(&state.config.ssl_domains_file, &domain)
    };
    if let Err(e) = removed {
        tracing::error!("Failed to remove ssl domain: {}", e);
    } else {
        restart_ssl(&state).await;
    }
    Redirect::to("/domains")
}

pub async fn add_lan_record(
    State(state): State<Arc<AppState>>,
    Form(form): Form<LanRecordForm>,
) -> Redirect {
    let name = normalize_lan_name(&form.name);
    let ttl = form.ttl.unwrap_or(300);

    let Some((record_type, content)) =
        validate_lan_record(&name, &form.record_type, &form.content, ttl)
    else {
        tracing::warn!(
            name = %form.name,
            record_type = %form.record_type,
            "Rejected invalid LAN record"
        );
        return Redirect::to("/domains");
    };

    let msg = json!({
        "action": "replace",
        "zone": "lan",
        "name": name,
        "type": record_type,
        "ttl": ttl,
        "records": [{"content": content, "disabled": false}]
    });
    if let Err(e) = state
        .nats
        .publish(
            "lancache.dns.record",
            serde_json::to_vec(&msg).unwrap().into(),
        )
        .await
    {
        tracing::error!("NATS publish failed: {}", e);
    }
    flush_recursor_cache(&state).await;

    Redirect::to("/domains")
}

pub async fn remove_lan_record(
    State(state): State<Arc<AppState>>,
    Form(form): Form<LanRecordForm>,
) -> Redirect {
    let name = normalize_lan_name(&form.name);

    let Some(record_type) = normalize_delete_record_type(&form.record_type) else {
        tracing::warn!(
            name = %form.name,
            record_type = %form.record_type,
            "Rejected invalid LAN record delete"
        );
        return Redirect::to("/domains");
    };

    let name_ok = is_valid_lan_name_for_delete(&name);
    if !name_ok {
        tracing::warn!(
            name = %form.name,
            "Rejected invalid LAN name for delete"
        );
        return Redirect::to("/domains");
    }

    let msg = json!({
        "action": "delete",
        "zone": "lan",
        "name": name,
        "type": record_type
    });
    if let Err(e) = state
        .nats
        .publish(
            "lancache.dns.record",
            serde_json::to_vec(&msg).unwrap().into(),
        )
        .await
    {
        tracing::error!("NATS publish failed: {}", e);
    }
    flush_recursor_cache(&state).await;

    Redirect::to("/domains")
}

pub async fn toggle_aaaa_filter(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AaaaFilterForm>,
) -> Redirect {
    let enable = form.enabled.as_deref() == Some("1");
    let cmd = if enable {
        vec!["touch", "/var/lib/powerdns/aaaa-filter-enabled"]
    } else {
        vec!["rm", "-f", "/var/lib/powerdns/aaaa-filter-enabled"]
    };
    for svc in [
        &state.config.dns_standard_service,
        &state.config.dns_ssl_service,
    ] {
        if let Err(e) = docker_client::exec_in_container(&state.docker, svc, cmd.clone()).await {
            tracing::error!("AAAA filter toggle on {}: {}", svc, e);
        }
    }
    Redirect::to("/domains")
}

async fn flush_recursor_cache(state: &AppState) {
    let url = format!(
        "{}/api/v1/servers/localhost/cache/flush?type=packet",
        state.config.pdns_rec_url
    );
    state
        .http_client
        .put(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
        .ok();

    // Also publish flush event so all recursor instances clear their cache
    state
        .nats
        .publish("lancache.dns.flush", "{}".into())
        .await
        .ok();
}

async fn is_aaaa_filter_enabled(state: &AppState) -> bool {
    let result = docker_client::exec_in_container(
        &state.docker,
        &state.config.dns_standard_service,
        vec!["test", "-f", "/var/lib/powerdns/aaaa-filter-enabled"],
    )
    .await;
    result.is_ok()
}

async fn restart_ssl(state: &AppState) {
    if let Err(e) =
        docker_client::restart_service(&state.docker, &state.config.proxy_ssl_service).await
    {
        tracing::error!("Restart proxy-ssl failed: {}", e);
    }
}

const MIN_TTL: u32 = 1;
const MAX_TTL: u32 = u32::MAX;

fn normalize_record_type(record_type: &str) -> Option<&'static str> {
    match record_type.trim().to_ascii_uppercase().as_str() {
        "A" => Some("A"),
        "AAAA" => Some("AAAA"),
        "CNAME" => Some("CNAME"),
        "MX" => Some("MX"),
        "TXT" => Some("TXT"),
        _ => None,
    }
}

fn normalize_delete_record_type(record_type: &str) -> Option<String> {
    let record_type = record_type.trim().to_ascii_uppercase();

    if let Some(code) = record_type.strip_prefix("TYPE") {
        return code.parse::<u16>().ok().map(|_| record_type);
    }

    if !record_type.is_empty()
        && record_type.len() <= 16
        && record_type
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
        && record_type.chars().all(|c| c.is_ascii_alphanumeric())
    {
        Some(record_type)
    } else {
        None
    }
}

fn is_valid_dns_fqdn(name: &str) -> bool {
    is_valid_dns_fqdn_impl(name, false, true)
}

fn is_valid_dns_fqdn_allow_underscore(name: &str) -> bool {
    is_valid_dns_fqdn_impl(name, true, true)
}

fn is_valid_dns_fqdn_impl(name: &str, allow_underscore: bool, allow_wildcard: bool) -> bool {
    let name = name.trim();

    if name.is_empty() || name.len() > 253 || !name.ends_with('.') {
        return false;
    }

    name.trim_end_matches('.')
        .split('.')
        .enumerate()
        .all(|(index, label)| {
            (allow_wildcard && index == 0 && label == "*")
                || (!label.is_empty()
                    && label.len() <= 63
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label.chars().all(|c| {
                        c.is_ascii_lowercase()
                            || c.is_ascii_digit()
                            || c == '-'
                            || (allow_underscore && c == '_')
                    }))
        })
}

fn is_lan_zone_name(name: &str) -> bool {
    name == "lan." || name.ends_with(".lan.")
}

fn is_valid_lan_name(name: &str) -> bool {
    is_valid_dns_fqdn(name) && is_lan_zone_name(name)
}

fn is_valid_lan_name_txt(name: &str) -> bool {
    is_valid_dns_fqdn_allow_underscore(name) && is_lan_zone_name(name)
}

fn is_valid_lan_name_for_delete(name: &str) -> bool {
    is_valid_dns_fqdn_allow_underscore(name) && is_lan_zone_name(name)
}

fn is_valid_txt_content(content: &str) -> bool {
    let content = content.trim();

    !content.is_empty() && !content.chars().any(char::is_control)
}

fn is_valid_mx_content(content: &str) -> bool {
    let mut parts = content.split_whitespace();

    let Some(priority) = parts.next() else {
        return false;
    };
    let Some(exchange) = parts.next() else {
        return false;
    };

    parts.next().is_none()
        && priority.parse::<u16>().is_ok()
        && is_valid_dns_fqdn(&normalize_lan_name(exchange))
}

fn validate_lan_record(
    name: &str,
    record_type: &str,
    content: &str,
    ttl: u32,
) -> Option<(&'static str, String)> {
    if !(MIN_TTL..=MAX_TTL).contains(&ttl) {
        return None;
    }

    let record_type = normalize_record_type(record_type)?;

    let name_valid = if record_type == "TXT" {
        is_valid_lan_name_txt(name)
    } else {
        is_valid_lan_name(name)
    };
    if !name_valid {
        return None;
    }
    let content = content.trim();

    let valid_content = match record_type {
        "A" => content.parse::<Ipv4Addr>().is_ok(),
        "AAAA" => content.parse::<Ipv6Addr>().is_ok(),
        "CNAME" => is_valid_dns_fqdn(&normalize_lan_name(content)),
        "MX" => is_valid_mx_content(content),
        "TXT" => is_valid_txt_content(content),
        _ => false,
    };

    valid_content.then(|| (record_type, content.to_string()))
}

fn is_valid_domain(domain: &str) -> bool {
    !domain.is_empty()
        && domain.len() <= 253
        && domain
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
        && !domain.starts_with('-')
        && !domain.ends_with('-')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
}

fn read_domain_file(path: &str) -> Vec<String> {
    let Ok(file) = fs::File::open(path) else {
        return vec![];
    };
    BufReader::new(file)
        .lines()
        .filter_map(|l| l.ok())
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

fn append_domain(path: &str, domain: &str) -> anyhow::Result<()> {
    let existing = read_domain_file(path);
    if existing.iter().any(|d| d == domain) {
        return Ok(());
    }
    let mut file = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)?;
    writeln!(file, "{}", domain)?;
    Ok(())
}

fn remove_domain(path: &str, domain: &str) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let new: String = content
        .lines()
        .filter(|l| !l.trim().is_empty() && l.trim() != domain)
        .map(|l| format!("{}\n", l))
        .collect();
    fs::write(path, new)?;
    Ok(())
}

async fn fetch_lan_records(state: &AppState) -> Vec<RRset> {
    let url = format!(
        "{}/api/v1/servers/localhost/zones/lan",
        state.config.pdns_auth_url
    );

    match state
        .http_client
        .get(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
    {
        Ok(resp) => match resp.json::<serde_json::Value>().await {
            Ok(data) => {
                if let Some(rrsets) = data.get("rrsets").and_then(|v| v.as_array()) {
                    rrsets
                        .iter()
                        .filter_map(|r| serde_json::from_value(r.clone()).ok())
                        .collect()
                } else {
                    vec![]
                }
            }
            Err(_) => vec![],
        },
        Err(_) => vec![],
    }
}

fn normalize_lan_name(name: &str) -> String {
    let trimmed = name.trim().to_lowercase();
    if trimmed.ends_with('.') {
        trimmed
    } else if trimmed.ends_with(".lan") {
        format!("{}.", trimmed)
    } else {
        format!("{}.lan.", trimmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_supported_lan_record_edge_cases() {
        assert!(validate_lan_record("*.dev.lan.", "A", "192.0.2.10", 604_800).is_some());
        assert!(validate_lan_record("lan.", "MX", "10 mail.lan.", 172_800).is_some());
        assert!(validate_lan_record("_dmarc.lan.", "TXT", "v=DMARC1; p=none", 300).is_some());
        assert!(
            validate_lan_record("_acme-challenge.lan.", "TXT", &"x".repeat(512), 300).is_some()
        );
    }

    #[test]
    fn rejects_invalid_lan_record_names_and_ttl_zero() {
        assert!(validate_lan_record("_ssh.lan.", "A", "192.0.2.10", 300).is_none());
        assert!(validate_lan_record("dev.example.", "A", "192.0.2.10", 300).is_none());
        assert!(validate_lan_record("api.lan.", "A", "192.0.2.10", 0).is_none());
        assert!(validate_lan_record("api.lan.", "SRV", "0 0 443 api.lan.", 300).is_none());
    }

    #[test]
    fn allows_deleting_existing_lan_rrsets_outside_add_whitelist() {
        assert_eq!(normalize_delete_record_type("srv"), Some("SRV".to_string()));
        assert_eq!(normalize_delete_record_type("CAA"), Some("CAA".to_string()));
        assert_eq!(normalize_delete_record_type("DS"), Some("DS".to_string()));
        assert_eq!(
            normalize_delete_record_type("DNSKEY"),
            Some("DNSKEY".to_string())
        );
        assert_eq!(
            normalize_delete_record_type("NAPTR"),
            Some("NAPTR".to_string())
        );
        assert_eq!(normalize_delete_record_type("LOC"), Some("LOC".to_string()));
        assert_eq!(
            normalize_delete_record_type("HTTPS"),
            Some("HTTPS".to_string())
        );
        assert_eq!(normalize_delete_record_type("SVCB"), Some("SVCB".to_string()));
        assert_eq!(
            normalize_delete_record_type("TYPE257"),
            Some("TYPE257".to_string())
        );
        assert_eq!(
            normalize_delete_record_type("TYPE65535"),
            Some("TYPE65535".to_string())
        );
        assert!(normalize_delete_record_type("TYPE65536").is_none());
        assert!(normalize_delete_record_type("bad-type").is_none());
        assert!(normalize_delete_record_type("123").is_none());
        assert!(is_valid_lan_name_for_delete("_sip._tcp.lan."));
        assert!(is_valid_lan_name_for_delete("*.dev.lan."));
        assert!(is_valid_lan_name_for_delete("lan."));
    }
}
