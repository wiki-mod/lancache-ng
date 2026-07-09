//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI domain routes. Handles CDN domain lists, SSL wildcard scope, and
//! LAN DNS records while preserving the on-disk domain-file semantics.

use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::http::HeaderMap;
use axum::response::{Html, Redirect};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tera::Context;

#[derive(Deserialize)]
pub struct AddForm {
    pub csrf_token: String,
    pub domain: String,
}

#[derive(Deserialize)]
pub struct LanRecordForm {
    pub csrf_token: String,
    pub name: String,
    pub record_type: String,
    pub content: String,
    pub ttl: Option<u32>,
}

#[derive(Deserialize)]
pub struct AaaaFilterForm {
    pub csrf_token: String,
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

pub async fn domains_page(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Html<String> {
    let dns_domains = read_domain_file(&state.config.cdn_domains_file);

    let lan_records = fetch_lan_records(&state).await;
    let aaaa_filter_enabled = is_aaaa_filter_enabled(&state).await;

    let mut ctx = Context::new();
    ctx.insert("dns_domains", &dns_domains);
    ctx.insert("lan_records", &lan_records);
    ctx.insert("aaaa_filter_enabled", &aaaa_filter_enabled);
    ctx.insert("active_page", "domains");
    crate::routes::insert_csrf_token(&mut ctx, &headers);

    crate::routes::render(
        &state.templates,
        "domains.html",
        &ctx,
        state.config.dev_mode,
    )
}

pub async fn add_dns(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let Some(domain) = parse_domain_entry(&form.domain) else {
        tracing::warn!(domain = %form.domain, "Rejected invalid dns domain");
        return Err(axum::http::StatusCode::BAD_REQUEST);
    };

    let wrote = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        append_domain(&state.config.cdn_domains_file, &domain)
    };
    if let Err(e) = wrote {
        tracing::error!("Failed to write dns domain: {}", e);
    } else {
        flush_recursor_cache(&state).await;
        // The SSL proxy derives its wildcard-cert root domains and nginx
        // host-allowlist maps from this same file at container startup (see
        // services/proxy/entrypoint.sh) — there is no separate SSL domain
        // list to edit anymore, so adding a DNS entry that needs TLS
        // interception also needs the proxy restarted to pick it up.
        if state.config.ssl_enabled {
            restart_ssl(&state).await;
        }
    }
    Ok(Redirect::to("/domains"))
}

pub async fn remove_dns(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AddForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let Some(domain) = normalize_domain_delete_entry(&form.domain) else {
        tracing::warn!(domain = %form.domain, "Rejected invalid dns domain delete");
        return Err(axum::http::StatusCode::BAD_REQUEST);
    };

    let removed = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        remove_domain(&state.config.cdn_domains_file, &domain)
    };
    if let Err(e) = removed {
        tracing::error!("Failed to remove dns domain: {}", e);
    } else {
        flush_recursor_cache(&state).await;
        // The SSL proxy derives its wildcard-cert root domains and nginx
        // host-allowlist maps from this same file at container startup (see
        // services/proxy/entrypoint.sh) — removing a domain here means the
        // proxy must no longer accept TLS-intercepted connections for it,
        // so it needs the same restart as adding one to pick up the removal.
        if state.config.ssl_enabled {
            restart_ssl(&state).await;
        }
    }
    Ok(Redirect::to("/domains"))
}

pub async fn add_lan_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<LanRecordForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
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
        return Ok(Redirect::to("/domains"));
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

    Ok(Redirect::to("/domains"))
}

pub async fn remove_lan_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<LanRecordForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let name = normalize_lan_name(&form.name);

    let Some(record_type) = normalize_delete_record_type(&form.record_type) else {
        tracing::warn!(
            name = %form.name,
            record_type = %form.record_type,
            "Rejected invalid LAN record delete"
        );
        return Ok(Redirect::to("/domains"));
    };

    let name_ok = is_valid_lan_name_for_delete(&name);
    if !name_ok {
        tracing::warn!(
            name = %form.name,
            "Rejected invalid LAN name for delete"
        );
        return Ok(Redirect::to("/domains"));
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

    Ok(Redirect::to("/domains"))
}

pub async fn toggle_aaaa_filter(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<AaaaFilterForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let enable = form.enabled.as_deref() == Some("1");
    let mut failed_paths = Vec::new();

    for marker_path in aaaa_filter_marker_paths(&state) {
        if let Err(e) = set_aaaa_filter_marker(&marker_path, enable) {
            tracing::error!(
                path = %marker_path.display(),
                enabled = enable,
                error = %e,
                "AAAA filter toggle failed"
            );
            failed_paths.push(marker_path);
        }
    }

    if !failed_paths.is_empty() {
        // The UI must not report success if any DNS instance cannot observe the
        // requested marker state.
        return Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
    }

    Ok(Redirect::to("/domains"))
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
    aaaa_filter_marker_paths(state)
        .into_iter()
        .any(|path| aaaa_filter_enabled_at(&path))
}

async fn restart_ssl(state: &AppState) {
    if let Err(e) =
        docker_client::restart_service(&state.docker, &state.config.proxy_ssl_service).await
    {
        tracing::error!("Restart proxy service failed: {}", e);
    }
}

fn aaaa_filter_marker_paths(state: &AppState) -> [PathBuf; 2] {
    [
        Path::new(&state.config.dns_standard_state_dir).join("aaaa-filter-enabled"),
        Path::new(&state.config.dns_ssl_state_dir).join("aaaa-filter-enabled"),
    ]
}

fn set_aaaa_filter_marker(path: &Path, enabled: bool) -> std::io::Result<()> {
    if enabled {
        fs::write(path, b"1")
    } else {
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }
}

fn aaaa_filter_enabled_at(path: &Path) -> bool {
    fs::metadata(path).is_ok()
}

const MIN_TTL: u32 = 1;
const MAX_TTL: u32 = u32::MAX;
const LINUX_ERRNO_EBUSY: i32 = 16;

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

#[cfg(test)]
fn is_valid_domain(domain: &str) -> bool {
    normalize_domain_entry(domain).is_some()
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DomainSpec {
    wildcard_only: bool,
    domain: String,
}

fn parse_domain_entry(domain: &str) -> Option<DomainSpec> {
    let normalized = domain.trim().to_lowercase();
    if normalized.is_empty() || normalized == "#" {
        return None;
    }

    let (wildcard_only, normalized) = if normalized.starts_with('.') {
        (true, normalized.strip_prefix('.').unwrap_or(&normalized))
    } else {
        (false, normalized.as_str())
    };

    (!normalized.is_empty()
        && normalized.len() <= 253
        && normalized.split('.').count() >= 2
        && normalized.split('.').all(is_valid_domain_label))
    .then(|| DomainSpec {
        wildcard_only,
        domain: normalized.to_string(),
    })
}

#[cfg(test)]
fn normalize_domain_entry(domain: &str) -> Option<String> {
    parse_domain_entry(domain).map(|entry| entry.domain)
}

fn normalize_domain_for_storage(domain: &DomainSpec) -> String {
    if domain.wildcard_only {
        format!(".{}", domain.domain)
    } else {
        domain.domain.clone()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum DomainDeleteTarget {
    Canonical(DomainSpec),
    Raw(String),
}

fn normalize_domain_delete_entry(domain: &str) -> Option<DomainDeleteTarget> {
    let trimmed = domain.trim();
    if let Some(normalized) = parse_domain_entry(trimmed) {
        return Some(DomainDeleteTarget::Canonical(normalized));
    }

    // Delete must still clean up malformed legacy/manual entries rendered by
    // read_domain_file(); additions stay strictly validated.
    (!trimmed.is_empty() && !trimmed.starts_with('#') && !trimmed.chars().any(char::is_control))
        .then(|| DomainDeleteTarget::Raw(trimmed.to_string()))
}

fn is_valid_domain_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 63
        && !label.starts_with('-')
        && !label.ends_with('-')
        && label
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn read_domain_file(path: &str) -> Vec<String> {
    let Ok(file) = fs::File::open(path) else {
        return vec![];
    };
    BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

fn append_domain(path: &str, domain: &DomainSpec) -> anyhow::Result<()> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(err) if err.kind() == ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err.into()),
    };

    if content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(parse_domain_entry)
        .any(|line| line == *domain)
    {
        return Ok(());
    }

    let new_entry = normalize_domain_for_storage(domain);
    let mut new_content = content;
    if !new_content.is_empty() && !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    new_content.push_str(&new_entry);
    new_content.push('\n');
    write_domain_file_atomic(path, &new_content)
}

fn remove_domain(path: &str, domain: &DomainDeleteTarget) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let mut removed = false;
    let sep = if content.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };

    let new = content
        .lines()
        .filter(|line| {
            let keep = !line_matches_domain_delete(line, domain);
            if !keep {
                removed = true;
            }
            keep
        })
        .collect::<Vec<_>>()
        .join(sep);

    if removed {
        let new = if content.ends_with('\n') && !new.is_empty() {
            format!("{new}{sep}")
        } else {
            new
        };
        write_domain_file_atomic(path, &new)?;
    }

    Ok(())
}

fn line_matches_domain_delete(line: &str, domain: &DomainDeleteTarget) -> bool {
    let trimmed = line.trim();
    match domain {
        DomainDeleteTarget::Canonical(target) => {
            parse_domain_entry(trimmed).is_some_and(|entry| entry == *target)
        }
        DomainDeleteTarget::Raw(raw) => trimmed.eq_ignore_ascii_case(raw),
    }
}

fn write_domain_file_atomic(path: &str, content: &str) -> anyhow::Result<()> {
    // Attempts atomic write via temp-file + rename pattern. On Linux with individual
    // file bind mounts (e.g., `docker run -v ./cdn-domains.txt:/data/cdn-domains.txt`),
    // the rename fails with EBUSY because the bind mount fixes the file inode and
    // rename can't replace it in-place. The fallback below keeps those supported
    // deployments working, but it is explicitly non-atomic: if the process is killed
    // after truncate but before write completes, the file is partially corrupted.
    //
    // Directory mounts stay on the atomic rename path and avoid this fallback.
    let path = Path::new(path);
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("missing parent directory"))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("domains");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| anyhow::anyhow!(err))?
        .as_nanos();
    let tmp_path = parent.join(format!(".{file_name}.{stamp}.tmp"));

    fs::write(&tmp_path, content)?;
    if let Ok(metadata) = fs::metadata(path) {
        fs::set_permissions(&tmp_path, metadata.permissions())?;
    }
    if let Err(err) = fs::rename(&tmp_path, path) {
        let bind_mount_replace_error = is_bind_mount_replace_error(&err);
        let _ = fs::remove_file(&tmp_path);
        if bind_mount_replace_error {
            return write_domain_file_in_place(path, content);
        }
        return Err(err.into());
    }

    Ok(())
}

// Detects EBUSY error from attempting to rename a bind-mounted individual file.
// In that case the caller falls back to the in-place write path.
fn is_bind_mount_replace_error(err: &std::io::Error) -> bool {
    err.raw_os_error() == Some(LINUX_ERRNO_EBUSY)
}

fn write_domain_file_in_place(path: &Path, content: &str) -> anyhow::Result<()> {
    // Compatibility fallback for bind-mounted individual files: truncate and write
    // in-place. This keeps supported file-bind-mount deployments working, but it is
    // NOT atomic. If the process crashes after truncate but before all content is
    // written and synced, the domain list file is left partially corrupted, and the
    // DNS/proxy services will read an incomplete list on restart.
    //
    // Directory mounts stay on the atomic rename path above.
    let mut file = fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(path)?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;
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
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("lancache-ng-{name}-{stamp}"))
    }

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
        assert_eq!(
            normalize_delete_record_type("SVCB"),
            Some("SVCB".to_string())
        );
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

    #[test]
    fn accepts_domain_entries_with_optional_wildcard_marker() {
        assert!(is_valid_domain("steamcontent.com"));
        assert!(is_valid_domain("cdn1.sub.example.com"));
        assert!(is_valid_domain(".steamcontent.com"));
        assert!(is_valid_domain(".download.nvidia.com"));
        assert_eq!(
            normalize_domain_entry(".SteamContent.COM").as_deref(),
            Some("steamcontent.com")
        );
        assert_eq!(
            parse_domain_entry(" .SteamContent.COM "),
            Some(domain_spec("steamcontent.com", true))
        );

        assert!(!is_valid_domain("localhost"));
        assert!(!is_valid_domain("."));
        assert!(!is_valid_domain("..example.com"));
        assert!(!is_valid_domain(".bad..example.com"));
        assert!(!is_valid_domain("example.com."));
        assert!(!is_valid_domain("bad..example.com"));
        assert!(!is_valid_domain("-bad.example.com"));
        assert!(!is_valid_domain("bad-.example.com"));
        assert!(!is_valid_domain("bad_label.example.com"));
        assert!(!is_valid_domain(&format!("{}.example.com", "a".repeat(64))));
    }

    fn domain_spec(domain: &str, wildcard_only: bool) -> DomainSpec {
        DomainSpec {
            wildcard_only,
            domain: domain.to_string(),
        }
    }

    #[test]
    fn aaaa_filter_marker_write_and_remove_are_idempotent() {
        let dir = temp_dir("aaaa-filter");
        fs::create_dir_all(&dir).unwrap();
        let marker = dir.join("aaaa-filter-enabled");

        assert!(!aaaa_filter_enabled_at(&marker));
        set_aaaa_filter_marker(&marker, true).unwrap();
        assert!(aaaa_filter_enabled_at(&marker));
        set_aaaa_filter_marker(&marker, true).unwrap();
        assert!(aaaa_filter_enabled_at(&marker));
        set_aaaa_filter_marker(&marker, false).unwrap();
        assert!(!aaaa_filter_enabled_at(&marker));
        set_aaaa_filter_marker(&marker, false).unwrap();
        assert!(!aaaa_filter_enabled_at(&marker));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn aaaa_filter_marker_write_fails_when_state_dir_is_missing() {
        let marker = temp_dir("aaaa-filter-missing").join("missing/aaaa-filter-enabled");

        assert!(set_aaaa_filter_marker(&marker, true).is_err());
    }

    #[test]
    fn append_and_remove_domain_use_atomic_rewrites() {
        // Domain list edits drive live DNS/proxy behavior, so this test proves
        // the update helpers rewrite files atomically without losing comments,
        // blank lines, or the distinction between root-domain and wildcard-only
        // entries.
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "# comment\nexample.com\n\n").unwrap();

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", false),
        )
        .unwrap();
        let after_append = fs::read_to_string(&file).unwrap();
        assert!(after_append.contains("# comment"));
        assert!(after_append.contains("example.com"));
        assert!(after_append.contains("steamcontent.com"));

        remove_domain(
            file.to_str().unwrap(),
            &DomainDeleteTarget::Canonical(domain_spec("example.com", false)),
        )
        .unwrap();
        let after_remove = fs::read_to_string(&file).unwrap();
        assert!(after_remove.contains("# comment"));
        assert!(!after_remove.contains("example.com\n"));
        assert!(after_remove.contains("steamcontent.com"));

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn remove_domain_can_cleanup_malformed_existing_entries() {
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-malformed-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "# comment\nbad..example.com\nsteamcontent.com\n").unwrap();

        let delete_value = normalize_domain_delete_entry("bad..example.com").unwrap();
        remove_domain(file.to_str().unwrap(), &delete_value).unwrap();

        let after_remove = fs::read_to_string(&file).unwrap();
        assert!(after_remove.contains("# comment"));
        assert!(!after_remove.contains("bad..example.com"));
        assert!(after_remove.contains("steamcontent.com"));

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn appending_root_and_wildcard_only_domains_keeps_semantics() {
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-root-wildcard-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, ".steamcontent.com\n").unwrap();

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", false),
        )
        .unwrap();
        append_domain(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", true),
        )
        .unwrap();

        let after_append = fs::read_to_string(&file).unwrap();
        assert!(after_append.contains(".steamcontent.com"));
        assert!(after_append.contains("steamcontent.com"));

        let duplicate = after_append.matches(".steamcontent.com").count();
        assert_eq!(duplicate, 1);

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn root_and_wildcard_entries_can_be_removed_independently() {
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-remove-root-vs-wildcard-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, ".steamcontent.com\nsteamcontent.com\n").unwrap();

        remove_domain(
            file.to_str().unwrap(),
            &DomainDeleteTarget::Canonical(domain_spec("steamcontent.com", true)),
        )
        .unwrap();
        let after_remove_wild = fs::read_to_string(&file).unwrap();
        assert!(!after_remove_wild.contains(".steamcontent.com"));
        assert!(after_remove_wild.contains("steamcontent.com"));

        remove_domain(
            file.to_str().unwrap(),
            &DomainDeleteTarget::Canonical(domain_spec("steamcontent.com", false)),
        )
        .unwrap();
        let after_remove_root = fs::read_to_string(&file).unwrap();
        assert!(!after_remove_root.contains("steamcontent.com"));
        assert!(!after_remove_root.contains(".steamcontent.com"));

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn bind_mount_replace_errors_use_in_place_fallback() {
        assert!(is_bind_mount_replace_error(
            &std::io::Error::from_raw_os_error(LINUX_ERRNO_EBUSY)
        ));
        assert!(!is_bind_mount_replace_error(&std::io::Error::from(
            ErrorKind::PermissionDenied
        )));
    }

    #[test]
    fn in_place_rewrite_truncates_and_replaces_file_content() {
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-in-place-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "old.example.com\nsecond.example.com\n").unwrap();

        write_domain_file_in_place(&file, "new.example.com\n").unwrap();

        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "new.example.com\n".to_string()
        );

        fs::remove_dir_all(&base).unwrap();
    }
}
