use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::response::{Html, Redirect};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Write};
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
    pub enabled: String,
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

    let payload = json!({
        "rrsets": [{
            "name": name,
            "type": form.record_type,
            "ttl": ttl,
            "changetype": "REPLACE",
            "records": [{"content": form.content, "disabled": false}]
        }]
    });

    let url = format!("{}/api/v1/servers/localhost/zones/lan", state.config.pdns_auth_url);
    state.http_client
        .patch(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .json(&payload)
        .send()
        .await
        .ok();

    Redirect::to("/domains")
}

pub async fn remove_lan_record(
    State(state): State<Arc<AppState>>,
    Form(form): Form<LanRecordForm>,
) -> Redirect {
    let name = normalize_lan_name(&form.name);

    let payload = json!({
        "rrsets": [{
            "name": name,
            "type": form.record_type,
            "changetype": "DELETE"
        }]
    });

    let url = format!("{}/api/v1/servers/localhost/zones/lan", state.config.pdns_auth_url);
    state.http_client
        .patch(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .json(&payload)
        .send()
        .await
        .ok();

    Redirect::to("/domains")
}

pub async fn toggle_aaaa_filter(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AaaaFilterForm>,
) -> Redirect {
    let enable = form.enabled == "1";
    let cmd = if enable {
        vec!["touch", "/var/lib/powerdns/aaaa-filter-enabled"]
    } else {
        vec!["rm", "-f", "/var/lib/powerdns/aaaa-filter-enabled"]
    };
    for svc in [&state.config.dns_standard_service, &state.config.dns_ssl_service] {
        if let Err(e) = docker_client::exec_in_container(&state.docker, svc, cmd.clone()).await {
            tracing::error!("AAAA filter toggle on {}: {}", svc, e);
        }
    }
    Redirect::to("/domains")
}

async fn flush_recursor_cache(state: &AppState) {
    let url = format!("{}/api/v1/servers/localhost/cache/flush?type=packet", state.config.pdns_rec_url);
    state.http_client
        .put(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
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
    if let Err(e) = docker_client::restart_service(&state.docker, &state.config.proxy_ssl_service).await {
        tracing::error!("Restart proxy-ssl failed: {}", e);
    }
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
    let mut file = fs::OpenOptions::new().append(true).create(true).open(path)?;
    writeln!(file, "{}", domain)?;
    Ok(())
}

fn remove_domain(path: &str, domain: &str) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let new: String = content
        .lines()
        .filter(|l| l.trim() != domain)
        .map(|l| format!("{}\n", l))
        .collect();
    fs::write(path, new)?;
    Ok(())
}

async fn fetch_lan_records(state: &AppState) -> Vec<RRset> {
    let url = format!("{}/api/v1/servers/localhost/zones/lan", state.config.pdns_auth_url);

    match state.http_client
        .get(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
    {
        Ok(resp) => {
            match resp.json::<serde_json::Value>().await {
                Ok(data) => {
                    if let Some(rrsets) = data.get("rrsets").and_then(|v| v.as_array()) {
                        rrsets.iter()
                            .filter_map(|r| serde_json::from_value(r.clone()).ok())
                            .collect()
                    } else {
                        vec![]
                    }
                }
                Err(_) => vec![],
            }
        }
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
