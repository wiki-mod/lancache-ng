use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::response::{Html, Redirect};
use serde::Deserialize;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::sync::Arc;
use tera::Context;

#[derive(Deserialize)]
pub struct AddForm {
    pub domain: String,
}

#[derive(Deserialize)]
pub struct AaaaFilterForm {
    pub enabled: String,
}

pub async fn domains_page(State(state): State<Arc<AppState>>) -> Html<String> {
    let dns_domains = read_domain_file(&state.config.cdn_domains_file);
    let ssl_domains = read_domain_file(&state.config.ssl_domains_file);
    let aaaa_filter_enabled = is_aaaa_filter_enabled(&state.config.named_conf_options_file);

    let mut ctx = Context::new();
    ctx.insert("dns_domains", &dns_domains);
    ctx.insert("ssl_domains", &ssl_domains);
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
            restart_dns(&state).await;
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
        restart_dns(&state).await;
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

pub async fn toggle_aaaa_filter(
    State(state): State<Arc<AppState>>,
    Form(form): Form<AaaaFilterForm>,
) -> Redirect {
    let enable = form.enabled == "1";
    let result = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        update_aaaa_filter(&state.config.named_conf_options_file, enable)
    };
    if let Err(e) = result {
        tracing::error!("Failed to update AAAA filter: {}", e);
    } else {
        restart_dns(&state).await;
    }
    Redirect::to("/domains")
}

async fn restart_dns(state: &AppState) {
    for svc in [&state.config.dns_standard_service, &state.config.dns_ssl_service] {
        if let Err(e) = docker_client::restart_service(&state.docker, svc).await {
            tracing::error!("Restart {} failed: {}", svc, e);
        }
    }
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

fn is_aaaa_filter_enabled(path: &str) -> bool {
    let Ok(content) = fs::read_to_string(path) else {
        return false;
    };
    content.lines().any(|l| {
        let trimmed = l.trim();
        (trimmed.starts_with("filter-aaaa-on-v4") || trimmed.starts_with("filter-aaaa-on-v6"))
            && !trimmed.starts_with('#')
    })
}

fn update_aaaa_filter(path: &str, enable: bool) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let new: String = content
        .lines()
        .map(|l| {
            let trimmed = l.trim();
            if trimmed.starts_with("# filter-aaaa-on-v4") {
                if enable {
                    "    filter-aaaa-on-v4 yes;".to_string()
                } else {
                    l.to_string()
                }
            } else if trimmed.starts_with("# filter-aaaa-on-v6") {
                if enable {
                    "    filter-aaaa-on-v6 yes;".to_string()
                } else {
                    l.to_string()
                }
            } else if trimmed.starts_with("filter-aaaa-on-v4") && !enable {
                "    # filter-aaaa-on-v4 yes;".to_string()
            } else if trimmed.starts_with("filter-aaaa-on-v6") && !enable {
                "    # filter-aaaa-on-v6 yes;".to_string()
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(path, format!("{}\n", new))?;
    Ok(())
}
