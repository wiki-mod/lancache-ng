//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI domain routes. Handles CDN domain lists, SSL wildcard scope, and
//! LAN DNS records while preserving the on-disk domain-file semantics.

use crate::{docker_client, AppState};
use axum::extract::{Form, Query, State};
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

#[derive(Deserialize)]
pub struct ToggleDomainForm {
    pub csrf_token: String,
    // The canonical (envelope-free) domain form, e.g. "steamcontent.com" or
    // ".steamcontent.com" -- the same shape add_dns/remove_dns already
    // accept, deliberately never the raw on-disk "!"-prefixed line. Reusing
    // parse_domain_entry here means an operator/forged request can never
    // smuggle a "!" through this field.
    pub domain: String,
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

// Query params this page reads back after a redirect from one of its own
// forms (add_dns's validation-failure path below). Deliberately just this
// one optional field, not a general flash-message mechanism: this UI has no
// site-wide flash/banner system today (see routes/dns_snapshots.rs's own
// doc comment on that gap), and building one is a bigger change than this
// one page's error display needs.
#[derive(Deserialize)]
pub struct DomainsPageQuery {
    #[serde(default)]
    pub error: Option<String>,
}

// Maps a known `?error=` code to the exact, safe, human-readable banner text
// -- never renders the query parameter's raw value directly. This keeps the
// set of possible messages fixed and reviewable instead of turning an
// operator-controlled (or link-shared) URL parameter into arbitrary page
// text. An unrecognized code (a stale bookmark from a future/older version,
// or a manually-edited URL) is treated as no error rather than guessed at.
fn domains_page_error_message(code: &str) -> Option<&'static str> {
    match code {
        "invalid_domain" => Some(
            "That domain was not added: CDN entries need a real domain name, not just a bare \
             top-level domain (e.g. \"steamcontent.com\", not \"com\"). A leading \".\" for a \
             wildcard/subdomain-only scope is fine (e.g. \".steamcontent.com\").",
        ),
        _ => None,
    }
}

pub async fn domains_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<DomainsPageQuery>,
) -> Html<String> {
    let dns_domains = read_domain_entries(&state.config.cdn_domains_file);

    let lan_records = fetch_lan_records(&state).await;
    // #1077: all PTR rows across the provisioned reverse zones (manual +
    // Kea-DDNS-auto-created; they are indistinguishable in PowerDNS).
    let ptr_records = fetch_ptr_records(&state).await;
    let aaaa_filter_enabled = is_aaaa_filter_enabled(&state).await;
    // #628: zone/record known-good snapshot rollback -- see
    // routes/dns_snapshots.rs's module doc comment for why this is a thin
    // HTTP call to nats-subscriber's own listener, not logic living here.
    let zone_snapshot_groups =
        crate::routes::dns_snapshots::fetch_zone_snapshot_groups(&state).await;

    let mut ctx = Context::new();
    ctx.insert("dns_domains", &dns_domains);
    ctx.insert("lan_records", &lan_records);
    ctx.insert("ptr_records", &ptr_records);
    ctx.insert("aaaa_filter_enabled", &aaaa_filter_enabled);
    ctx.insert("zone_snapshot_groups", &zone_snapshot_groups);
    ctx.insert(
        "domain_error_message",
        &query.error.as_deref().and_then(domains_page_error_message),
    );
    // Retention count shown on the zone-snapshot panel: the same
    // KEEP_KNOWN_GOOD_CONFIGS variable and default this adapter shares with
    // every other known-good-snapshot adapter (docs/known-good-config-
    // snapshots.md's contract) -- reusing the field the Kea adapter already
    // reads rather than adding a second config field with an identical
    // value.
    ctx.insert(
        "zone_snapshot_retention",
        &state.config.kea_keep_known_good_configs,
    );
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
        // Redirect back to the page with an in-app error banner instead of a
        // bare 400: this handler is reached by a plain HTML form POST (no
        // JS/fetch error handling on the client), so returning a raw
        // StatusCode here used to navigate the browser to an unstyled error
        // page -- reported during field testing for the bare-TLD case (e.g.
        // typing "com"), which parse_domain_entry already correctly rejects
        // (it requires at least two labels), just without a usable error
        // surface. See domains_page_error_message for the fixed, safe set of
        // messages this can redirect to.
        return Ok(Redirect::to("/domains?error=invalid_domain"));
    };

    let wrote = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        append_domain(&state.config.cdn_domains_file, &domain)
    };
    // The UI must not report success if the CDN domain file itself was never
    // updated -- unlike the best-effort recursor-flush/proxy-restart calls
    // below, this write is the actual mutation the request represents (same
    // reasoning as toggle_aaaa_filter's marker-write check further down in
    // this file).
    dns_write_result_to_response(wrote, "write")?;
    flush_recursor_cache(&state, &domain.domain).await;
    // The SSL proxy derives its wildcard-cert root domains and nginx
    // host-allowlist maps from this same file at container startup (see
    // services/proxy/entrypoint.sh) — there is no separate SSL domain
    // list to edit anymore, so adding a DNS entry that needs TLS
    // interception also needs the proxy restarted to pick it up.
    if state.config.ssl_enabled {
        restart_ssl(&state).await;
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
    // Same reasoning as add_dns: the CDN domain file write is the request's
    // actual mutation, so a failed write must not redirect as success.
    dns_write_result_to_response(removed, "remove")?;
    let flushed_domain = match &domain {
        DomainDeleteTarget::Canonical(spec) => spec.domain.clone(),
        DomainDeleteTarget::Raw(raw) => raw.clone(),
    };
    flush_recursor_cache(&state, &flushed_domain).await;
    // The SSL proxy derives its wildcard-cert root domains and nginx
    // host-allowlist maps from this same file at container startup (see
    // services/proxy/entrypoint.sh) — removing a domain here means the
    // proxy must no longer accept TLS-intercepted connections for it,
    // so it needs the same restart as adding one to pick up the removal.
    if state.config.ssl_enabled {
        restart_ssl(&state).await;
    }
    Ok(Redirect::to("/domains"))
}

// Enable/disable a pre-shipped "Default CDN" cdn-domains.txt entry in place,
// without removing it from the file (#1073). Deliberately a separate route
// from add_dns/remove_dns: the custom-domain add/remove flow always writes a
// fully add/removed line, whereas this route only ever flips the leading
// "!" disabled marker on an existing line -- it can never create or delete a
// domain entry outright. See parse_stored_domain_line/set_domain_enabled's
// doc comments for the on-disk envelope format this manipulates.
pub async fn toggle_default_domain(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<ToggleDomainForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let Some(target) = parse_domain_entry(&form.domain) else {
        tracing::warn!(domain = %form.domain, "Rejected invalid dns domain toggle");
        return Err(axum::http::StatusCode::BAD_REQUEST);
    };
    let enable = form.enabled.as_deref() == Some("1");

    let toggled = {
        let _guard = state.file_lock.lock().expect("file lock poisoned");
        set_domain_enabled(&state.config.cdn_domains_file, &target, enable)
    };
    // Same reasoning as add_dns/remove_dns: the CDN domain file write is the
    // request's actual mutation, so a failed write must not redirect as
    // success.
    dns_write_result_to_response(toggled, "toggle")?;

    // Toggling a default entry has the exact same downstream generation
    // dependency as adding/removing a custom one (both DNS RPZ generation
    // and the SSL proxy's cert/nginx-map generation only read
    // cdn-domains.txt fresh at container startup -- see
    // docs/dns-admin-ui-scope.md), so this mirrors add_dns/remove_dns's own
    // recursor-flush/proxy-restart wiring exactly rather than silently being
    // a no-op until an unrelated restart happens to pick the change up.
    flush_recursor_cache(&state, &target.domain).await;
    if state.config.ssl_enabled {
        restart_ssl(&state).await;
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
    flush_recursor_cache(&state, &name).await;

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
    flush_recursor_cache(&state, &name).await;

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

async fn flush_recursor_cache(state: &AppState, domain: &str) {
    // PowerDNS Recursor's cache/flush endpoint requires a `domain` query
    // parameter and only flushes an exact name match, not a subtree --
    // confirmed live while building issue #400's integration test:
    // `?type=packet` (the previous call) always returned 422 Unprocessable
    // Entity, and even `?domain=.` or `?domain=lan.` leave a just-deleted
    // leaf record (e.g. `host.lan.`) resolving from cache until its TTL
    // naturally expires. The caller must pass the exact name that changed.
    // PowerDNS also requires canonical (dot-terminated) form, or the flush
    // itself is rejected outright ("DNS Name '' is not canonical") --
    // ensure that here so callers don't all need to remember it themselves.
    let canonical_domain = if domain.ends_with('.') {
        domain.to_string()
    } else {
        format!("{domain}.")
    };
    let url = format!(
        "{}/api/v1/servers/localhost/cache/flush?domain={}",
        state.config.pdns_rec_url, canonical_domain
    );
    state
        .http_client
        .put(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
        .ok();

    // Also publish flush event so all recursor instances clear their cache
    // for this same domain, not just the one this UI instance talks to.
    state
        .nats
        .publish(
            "lancache.dns.flush",
            json!({"domain": canonical_domain}).to_string().into(),
        )
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

// Maps the CDN domain file write's own Result to the operator-facing
// response. `action` names the operation in the log line ("write"/"remove")
// so add_dns/remove_dns keep their own distinct log message while sharing
// this decision: on failure, log and report 500 instead of the success
// redirect the caller would otherwise send -- the write is the actual
// mutation the request represents, so a failure here can never look like a
// success to the operator, same as toggle_aaaa_filter's marker-write check.
fn dns_write_result_to_response(
    result: anyhow::Result<()>,
    action: &str,
) -> Result<(), axum::http::StatusCode> {
    result.map_err(|e| {
        tracing::error!("Failed to {action} dns domain: {e}");
        axum::http::StatusCode::INTERNAL_SERVER_ERROR
    })
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

// Marks the boundary between the pre-shipped "Default CDN" section of
// cdn-domains.txt and entries an operator has added themselves via the
// Admin UI's Add form (#1073). Everything above this exact line (trimmed)
// is treated as a default entry (toggle-able but never removable from the
// UI); everything below it is a custom entry (add/remove-able, never
// toggle-able). It is an ordinary "#"-prefixed comment as far as every
// existing consumer of this file is concerned (DNS RPZ generation, proxy
// cert generation, the Rust domain-add dedup check) -- only
// read_domain_entries()/append_domain() below give it special meaning.
// Deliberately distinct wording/formatting from the vendor section headers
// already in the shipped file (e.g. "# ---- Steam ----") so it can never be
// mistaken for one of those by the exact-match comparison in
// read_domain_entries().
const CUSTOM_DOMAINS_MARKER: &str =
    "# ==== lancache-ng: entries added via the Admin UI are appended below this exact line ====";

// A single cdn-domains.txt line's full on-disk envelope: the validated
// domain/wildcard-scope pair (DomainSpec) plus the enabled/disabled bit
// encoded by an optional leading "!" (#1073). Kept as a separate type from
// DomainSpec on purpose -- DomainSpec's derived Eq is load-bearing for
// dedup (append_domain) and delete matching (line_matches_domain_delete),
// and folding `enabled` into that equality would make a disabled entry stop
// matching its own enabled counterpart there.
#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredDomainLine {
    spec: DomainSpec,
    enabled: bool,
}

// Parses one raw cdn-domains.txt line's stored form: an optional leading
// "!" (disabled marker) wrapping the same "optional '.' + domain" syntax
// parse_domain_entry already validates. This is intentionally a distinct
// function from parse_domain_entry rather than folding "!" support into it:
// parse_domain_entry also validates fresh operator input typed into the Add
// form, which must never be allowed to smuggle a "!" through as if it were
// part of the hostname -- keeping the two parsers separate makes that
// impossible by construction instead of relying on a caller to remember not
// to pass user input through the disabled-aware path.
fn parse_stored_domain_line(line: &str) -> Option<StoredDomainLine> {
    let trimmed = line.trim();
    let (enabled, rest) = match trimmed.strip_prefix('!') {
        Some(stripped) => (false, stripped),
        None => (true, trimmed),
    };
    parse_domain_entry(rest).map(|spec| StoredDomainLine { spec, enabled })
}

// Renders a StoredDomainLine back to its on-disk textual form, the inverse
// of parse_stored_domain_line.
fn stored_line_to_storage(entry: &StoredDomainLine) -> String {
    let base = normalize_domain_for_storage(&entry.spec);
    if entry.enabled {
        base
    } else {
        format!("!{base}")
    }
}

// One row of the CDN domain list as rendered by the Admin UI (#1073).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct DomainListEntry {
    // The exact trimmed on-disk line. Used verbatim as the hidden form value
    // for the custom-entry Remove flow (matching remove_dns's pre-existing
    // Raw fallback for malformed lines), so removal stays byte-exact
    // regardless of display formatting.
    raw: String,
    // Human-readable domain text with the "!" disabled envelope stripped
    // (but the "." wildcard-only marker, if any, kept) -- what the template
    // shows, and also the value the toggle form posts back through
    // parse_domain_entry.
    display: String,
    enabled: bool,
    // True for entries shipped above CUSTOM_DOMAINS_MARKER (or for any file
    // with no marker at all, e.g. a pre-migration mount -- see
    // read_domain_entries), false for operator-added entries below it.
    is_default: bool,
    // False for a malformed/legacy line that doesn't parse as a DomainSpec
    // (see remove_domain_can_cleanup_malformed_existing_entries's test):
    // such a row still needs to be visible and removable, but has no
    // DomainSpec to toggle, so the template must fall back to the Remove
    // control for it even in the default section.
    is_valid: bool,
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
    // read_domain_entries(); additions stay strictly validated.
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

// Reads cdn-domains.txt into the Admin UI's row-level representation
// (#1073): each line's enabled state (leading "!") and whether it belongs to
// the pre-shipped "Default CDN" section or the operator-managed "custom"
// section below CUSTOM_DOMAINS_MARKER. A file with no marker at all (an
// older mount predating this feature, or a bare test fixture) is treated as
// entirely default -- there is no custom section to speak of yet, matching
// how every existing entry behaved before this change.
fn read_domain_entries(path: &str) -> Vec<DomainListEntry> {
    let Ok(file) = fs::File::open(path) else {
        return vec![];
    };
    let mut is_default = true;
    BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter_map(|raw_line| {
            let trimmed = raw_line.trim().to_string();
            // Checked before the generic comment skip below: the marker
            // line is itself a "#"-prefixed comment, so it must flip
            // is_default before the empty/comment filter would otherwise
            // discard it unnoticed.
            if trimmed == CUSTOM_DOMAINS_MARKER {
                is_default = false;
                return None;
            }
            if trimmed.is_empty() || trimmed.starts_with('#') {
                return None;
            }

            Some(match parse_stored_domain_line(&trimmed) {
                Some(stored) => DomainListEntry {
                    raw: trimmed,
                    display: normalize_domain_for_storage(&stored.spec),
                    enabled: stored.enabled,
                    is_default,
                    is_valid: true,
                },
                // Malformed/legacy entry: still surfaced (pre-existing
                // behavior kept, see remove_domain's Raw delete fallback)
                // so an operator can still clean it up via Remove, just
                // without a toggle control since there's no DomainSpec to
                // flip enabled on.
                None => {
                    let display = trimmed.strip_prefix('!').unwrap_or(&trimmed).to_string();
                    DomainListEntry {
                        raw: trimmed,
                        display,
                        enabled: true,
                        is_default,
                        is_valid: false,
                    }
                }
            })
        })
        .collect()
}

fn append_domain(path: &str, domain: &DomainSpec) -> anyhow::Result<()> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(err) if err.kind() == ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err.into()),
    };

    // Spec-aware, not parse_domain_entry-based: a disabled default entry's
    // stored line ("!steamcontent.com") does not parse via
    // parse_domain_entry at all (it never expects a "!" envelope), so a
    // naive dedup check would miss it and let Add append a second, duplicate
    // line for the same domain/scope right alongside a disabled default one
    // (#1073 -- caught before this shipped, not a later fix). Using
    // parse_stored_domain_line here means a disabled default is correctly
    // recognized as "this domain already has a row."
    let existing_entry = content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(parse_stored_domain_line)
        .find(|stored| stored.spec == *domain);

    match existing_entry {
        // Already present and enabled: nothing to do.
        Some(stored) if stored.enabled => return Ok(()),
        // Present but disabled (most commonly a pre-shipped default the
        // operator previously turned off via the toggle): Add re-enables it
        // in place instead of appending a duplicate second line for the
        // same domain -- "add this domain" reads most naturally as "make
        // sure it's present and active," not "silently do nothing" or
        // "create a second, conflicting row."
        Some(_) => return set_domain_enabled(path, domain, true),
        None => {}
    }

    let new_entry = normalize_domain_for_storage(domain);
    let mut new_content = content;
    if !new_content.is_empty() && !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    // Converge older/pre-migration files (and bare test fixtures) that
    // predate the default-vs-custom split (#1073): insert
    // CUSTOM_DOMAINS_MARKER once, before appending, so this entry (and every
    // future one) is correctly classified as operator-added by
    // read_domain_entries instead of silently being counted as a pre-shipped
    // default. A file that already has the marker is left untouched here --
    // this only ever adds the marker, never duplicates or moves it, so a
    // repeated add_dns call stays idempotent per AG-OP-006.
    if !new_content.contains(CUSTOM_DOMAINS_MARKER) {
        if !new_content.is_empty() {
            new_content.push('\n');
        }
        new_content.push_str(CUSTOM_DOMAINS_MARKER);
        new_content.push('\n');
    }
    new_content.push_str(&new_entry);
    new_content.push('\n');
    write_domain_file_atomic(path, &new_content)
}

// Flips a specific stored domain entry's enabled/disabled state in place
// (#1073's toggle route), rewriting only the matched line -- root and
// wildcard-only variants of the same domain are independent lines/specs
// (see appending_root_and_wildcard_only_domains_keeps_semantics), so `target`
// must match on the full DomainSpec, not just the domain string. Uses the
// same terminator-preserving rewrite as remove_domain so surviving lines
// never get silently normalized to a different line ending (#656).
fn set_domain_enabled(path: &str, target: &DomainSpec, enable: bool) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let mut changed = false;

    let new: String = split_lines_preserve_terminators(&content)
        .into_iter()
        .map(|(line, terminator)| match parse_stored_domain_line(line) {
            Some(stored) if stored.spec == *target && stored.enabled != enable => {
                changed = true;
                let rewritten = stored_line_to_storage(&StoredDomainLine {
                    spec: stored.spec,
                    enabled: enable,
                });
                format!("{rewritten}{terminator}")
            }
            _ => format!("{line}{terminator}"),
        })
        .collect();

    // Idempotent: a toggle request that already matches the file's current
    // state (e.g. a repeated click, or two browser tabs) does not rewrite
    // the file at all, matching remove_domain's own "only write if something
    // actually changed" pattern.
    if changed {
        write_domain_file_atomic(path, &new)?;
    }

    Ok(())
}

fn remove_domain(path: &str, domain: &DomainDeleteTarget) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)?;
    let mut removed = false;

    // Previously this picked ONE separator for the whole file (CRLF if the
    // file contained CRLF *anywhere*, else LF) and rejoined every retained
    // line with it. A file with mixed endings (e.g. a CRLF header hand-edited
    // on Windows followed by LF domain entries appended from Linux/the
    // container) would then have every surviving LF line rewritten with a
    // spurious trailing \r. $domain is read verbatim by the proxy/DNS
    // entrypoints, so that stray \r leaked into generated nginx map/cert
    // names and stream targets (#656). Preserving each line's own original
    // terminator instead avoids rewriting any line that wasn't removed.
    let new: String = split_lines_preserve_terminators(&content)
        .into_iter()
        .filter(|(line, _terminator)| {
            let keep = !line_matches_domain_delete(line, domain);
            if !keep {
                removed = true;
            }
            keep
        })
        .map(|(line, terminator)| format!("{line}{terminator}"))
        .collect();

    if removed {
        write_domain_file_atomic(path, &new)?;
    }

    Ok(())
}

// Splits file content into (line, terminator) pairs without normalizing line
// endings, so a caller that drops some lines and rejoins the rest reproduces
// each surviving line's own original terminator ("\r\n", "\n", or "" for a
// final line with no trailing newline at all) instead of forcing one
// separator across the whole file. See remove_domain's comment (#656) for why
// that distinction matters here.
fn split_lines_preserve_terminators(content: &str) -> Vec<(&str, &str)> {
    let mut lines = Vec::new();
    let mut rest = content;
    while !rest.is_empty() {
        if let Some(idx) = rest.find('\n') {
            let (line_with_lf, remainder) = rest.split_at(idx + 1);
            let without_lf = &line_with_lf[..line_with_lf.len() - 1];
            if let Some(stripped) = without_lf.strip_suffix('\r') {
                lines.push((stripped, "\r\n"));
            } else {
                lines.push((without_lf, "\n"));
            }
            rest = remainder;
        } else {
            lines.push((rest, ""));
            rest = "";
        }
    }
    lines
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

// ── Manual PTR (reverse DNS) records (#1077) ─────────────────────────────
//
// Unlike the forward LAN-record flow above (which publishes to NATS so the
// change replicates to every DNS node), manual PTR writes go DIRECTLY to the
// primary's PowerDNS authoritative API via `pdns_auth_url` -- the write path
// the maintainer confirmed for #1077, with NATS-based replication of manual
// PTR edits to the other DNS instances (the primary's dns-ssl, and the
// secondaries) deliberately left as a follow-up pending the still-open
// reverse-zone replication decision (see #770). The reverse zones themselves
// are provisioned identically on every instance and Kea writes its automatic
// PTRs to each directly, so this only affects manual edits.

#[derive(Deserialize)]
pub struct PtrRecordForm {
    pub csrf_token: String,
    // Operator-facing "IP address" input, e.g. `192.168.1.50` -- translated to
    // the reversed `in-addr.arpa` record name here, so the operator never sees
    // raw reverse-zone syntax (matching this project's simple-fields pattern).
    pub ip: String,
    // The PTR target hostname, e.g. `printer.lan.` (trailing dot optional on
    // input; normalized below).
    pub hostname: String,
    pub ttl: Option<u32>,
}

#[derive(Deserialize)]
pub struct PtrDeleteForm {
    pub csrf_token: String,
    // A PTR is keyed by its IP: removal deletes the whole PTR rrset for this
    // address, so only the IP is needed.
    pub ip: String,
}

// One row of the PTR display table. Note (#1077): PowerDNS stores no provenance
// distinguishing a Kea-DDNS-auto-created PTR from a manually-created one (same
// rrset type, same zone), so this view deliberately shows ALL reverse-zone
// PTRs uniformly. A consequence surfaced in the UI/PR: removing a
// DDNS-managed PTR here may simply be recreated by Kea on the next lease event.
#[derive(Serialize)]
pub struct PtrRecordView {
    pub ip: String,
    pub hostname: String,
    pub ttl: u32,
    // Numeric form of `ip` for a stable numeric sort of the table; not rendered.
    #[serde(skip)]
    sort_key: u32,
}

// The 18 IPv4 private reverse zones this project provisions (see
// services/dns/entrypoint.sh's PRIVATE_REVERSE_ZONES / nats-subscriber's
// ROLLBACK_ZONES). Generated from the same ranges `reverse_dns` maps into,
// rather than a second hand-maintained literal list, so the two cannot drift.
// The IPv6 ULA reverse zones (`c.f.ip6.arpa.`/`d.f.ip6.arpa.`) are intentionally
// excluded: no IPv6 PTR management is offered here (Kea emits no IPv6 PTRs).
fn provisioned_ipv4_reverse_zones() -> Vec<String> {
    let mut zones = vec![
        "10.in-addr.arpa".to_string(),
        "168.192.in-addr.arpa".to_string(),
    ];
    for second_octet in 16..=31u8 {
        zones.push(format!("{second_octet}.172.in-addr.arpa"));
    }
    zones
}

// Normalizes and validates a PTR target hostname: trims, lowercases, ensures
// the trailing dot PowerDNS expects, and requires a valid concrete FQDN
// (no wildcard, no underscore -- a PTR must point at a real host name).
fn normalize_ptr_target(hostname: &str) -> Option<String> {
    let host = hostname.trim().to_ascii_lowercase();
    if host.is_empty() {
        return None;
    }
    let fqdn = if host.ends_with('.') {
        host
    } else {
        format!("{host}.")
    };
    if is_valid_dns_fqdn_impl(&fqdn, false, false) {
        Some(fqdn)
    } else {
        None
    }
}

// Validates a PTR add request, returning (reverse zone id, PTR record name,
// normalized target FQDN) on success. Rejects (returns None) an unparseable or
// non-provisioned-range IP, an out-of-range TTL, or an invalid target host --
// the caller then soft-fails back to /domains, matching add_lan_record.
fn validate_ptr_add(ip: &str, hostname: &str, ttl: u32) -> Option<(String, String, String)> {
    if !(MIN_TTL..=MAX_TTL).contains(&ttl) {
        return None;
    }
    let addr: Ipv4Addr = ip.trim().parse().ok()?;
    let zone = crate::reverse_dns::reverse_zone_for_ipv4(addr)?;
    let ptr_name = crate::reverse_dns::ptr_name_for_ipv4(addr);
    let target = normalize_ptr_target(hostname)?;
    Some((zone, ptr_name, target))
}

// Validates a PTR delete request (IP only), returning (reverse zone id, PTR
// record name). Same range validation as add: an IP with no provisioned
// reverse zone is rejected rather than producing a PATCH that would 404.
fn validate_ptr_ip(ip: &str) -> Option<(String, String)> {
    let addr: Ipv4Addr = ip.trim().parse().ok()?;
    let zone = crate::reverse_dns::reverse_zone_for_ipv4(addr)?;
    let ptr_name = crate::reverse_dns::ptr_name_for_ipv4(addr);
    Some((zone, ptr_name))
}

// PATCHes one reverse zone on the primary's PowerDNS (pdns_auth_url), mirroring
// nats-subscriber's handle_dns_record write shape (the canonical PowerDNS-write
// shape in this repo). Returns whether PowerDNS accepted the change (2xx).
async fn patch_reverse_zone(state: &AppState, zone: &str, body: String) -> bool {
    let url = format!(
        "{}/api/v1/servers/localhost/zones/{}",
        state.config.pdns_auth_url, zone
    );
    match state
        .http_client
        .patch(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(e) => {
            tracing::error!("PTR PATCH to reverse zone {zone} failed: {e}");
            false
        }
    }
}

pub async fn add_ptr_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<PtrRecordForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;
    let ttl = form.ttl.unwrap_or(300);

    let Some((zone, ptr_name, target)) = validate_ptr_add(&form.ip, &form.hostname, ttl) else {
        tracing::warn!(ip = %form.ip, hostname = %form.hostname, "Rejected invalid PTR record");
        return Ok(Redirect::to("/domains"));
    };

    let body = json!({
        "rrsets": [{
            "name": ptr_name,
            "type": "PTR",
            "ttl": ttl,
            "changetype": "REPLACE",
            "records": [{"content": target, "disabled": false}]
        }]
    })
    .to_string();

    // Only flush the recursor cache once PowerDNS actually accepted the write,
    // so a failed PATCH doesn't advertise a change that never happened.
    if patch_reverse_zone(&state, &zone, body).await {
        flush_recursor_cache(&state, &ptr_name).await;
    } else {
        tracing::error!(ip = %form.ip, "PowerDNS rejected PTR add");
    }

    Ok(Redirect::to("/domains"))
}

pub async fn remove_ptr_record(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<PtrDeleteForm>,
) -> Result<Redirect, axum::http::StatusCode> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)?;

    let Some((zone, ptr_name)) = validate_ptr_ip(&form.ip) else {
        tracing::warn!(ip = %form.ip, "Rejected invalid PTR delete");
        return Ok(Redirect::to("/domains"));
    };

    // DELETE changetype removes the whole PTR rrset for this name; ttl/records
    // are omitted, exactly as remove_lan_record's delete message does.
    let body = json!({
        "rrsets": [{
            "name": ptr_name,
            "type": "PTR",
            "changetype": "DELETE"
        }]
    })
    .to_string();

    if patch_reverse_zone(&state, &zone, body).await {
        flush_recursor_cache(&state, &ptr_name).await;
    } else {
        tracing::error!(ip = %form.ip, "PowerDNS rejected PTR delete");
    }

    Ok(Redirect::to("/domains"))
}

// Extracts displayable PTR rows from one PowerDNS zone export's `rrsets` array.
// Skips non-PTR rrsets, disabled records, and any name that does not parse as a
// four-label IPv4 in-addr.arpa name, so a malformed/foreign entry is left out
// of the IP-addressed table rather than shown as a broken row.
fn parse_ptr_views(rrsets: &serde_json::Value) -> Vec<PtrRecordView> {
    let mut views = Vec::new();
    let Some(arr) = rrsets.as_array() else {
        return views;
    };
    for rrset in arr {
        if rrset.get("type").and_then(|v| v.as_str()) != Some("PTR") {
            continue;
        }
        let Some(name) = rrset.get("name").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(addr) = crate::reverse_dns::ipv4_from_ptr_name(name) else {
            continue;
        };
        let ttl = rrset.get("ttl").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        if let Some(records) = rrset.get("records").and_then(|v| v.as_array()) {
            for record in records {
                if record.get("disabled").and_then(|v| v.as_bool()) == Some(true) {
                    continue;
                }
                if let Some(content) = record.get("content").and_then(|v| v.as_str()) {
                    views.push(PtrRecordView {
                        ip: addr.to_string(),
                        hostname: content.to_string(),
                        ttl,
                        sort_key: u32::from(addr),
                    });
                }
            }
        }
    }
    views
}

async fn fetch_ptr_records_for_zone(state: &AppState, zone: &str) -> Vec<PtrRecordView> {
    let url = format!(
        "{}/api/v1/servers/localhost/zones/{}",
        state.config.pdns_auth_url, zone
    );
    match state
        .http_client
        .get(&url)
        .header("X-API-Key", &state.config.pdns_api_key)
        .send()
        .await
    {
        Ok(resp) => match resp.json::<serde_json::Value>().await {
            Ok(data) => parse_ptr_views(data.get("rrsets").unwrap_or(&serde_json::Value::Null)),
            Err(_) => vec![],
        },
        Err(_) => vec![],
    }
}

// Reads every provisioned IPv4 reverse zone from the primary's PowerDNS and
// returns all PTR rows (manual AND Kea-DDNS-auto-created -- they are
// indistinguishable, see PtrRecordView), sorted by IP. The per-zone GETs run
// concurrently because there are up to 18 of them and doing them serially on
// every /domains render would be needlessly slow.
async fn fetch_ptr_records(state: &AppState) -> Vec<PtrRecordView> {
    let zones = provisioned_ipv4_reverse_zones();
    let per_zone =
        futures_util::future::join_all(zones.iter().map(|z| fetch_ptr_records_for_zone(state, z)))
            .await;
    let mut all: Vec<PtrRecordView> = per_zone.into_iter().flatten().collect();
    all.sort_by(|a, b| {
        a.sort_key
            .cmp(&b.sort_key)
            .then_with(|| a.hostname.cmp(&b.hostname))
    });
    all
}

#[cfg(test)]
mod tests {
    use super::*;

    // #1077: a valid PTR add resolves to the correct reverse zone id, the
    // reversed dot-terminated PTR name, and a normalized dot-terminated target.
    // This is the exact tuple the handler feeds into the PowerDNS PATCH, so a
    // wrong mapping here would write to the wrong zone/name.
    #[test]
    fn validate_ptr_add_accepts_private_ip_and_host() {
        assert_eq!(
            validate_ptr_add("192.168.1.50", "printer.lan", 300),
            Some((
                "168.192.in-addr.arpa".to_string(),
                "50.1.168.192.in-addr.arpa.".to_string(),
                "printer.lan.".to_string()
            ))
        );
        // Trailing dot on the host and a 172.16/12 address also work.
        assert_eq!(
            validate_ptr_add("172.20.0.7", "nas.lan.", 600),
            Some((
                "20.172.in-addr.arpa".to_string(),
                "7.0.20.172.in-addr.arpa.".to_string(),
                "nas.lan.".to_string()
            ))
        );
    }

    // #1077: inputs that must be rejected (soft-fail) rather than PATCHed --
    // a public IP has no provisioned reverse zone; TTL 0 is out of range; a
    // wildcard or empty target is not a valid concrete PTR host. Each would
    // otherwise cause a bad or nonsensical PowerDNS write.
    #[test]
    fn validate_ptr_add_rejects_bad_ip_ttl_and_host() {
        assert_eq!(validate_ptr_add("8.8.8.8", "host.lan", 300), None);
        assert_eq!(validate_ptr_add("not-an-ip", "host.lan", 300), None);
        assert_eq!(validate_ptr_add("192.168.1.50", "host.lan", 0), None);
        assert_eq!(validate_ptr_add("192.168.1.50", "*.lan", 300), None);
        assert_eq!(validate_ptr_add("192.168.1.50", "", 300), None);
    }

    // #1077: delete validation keys off the IP alone and applies the same
    // provisioned-range gate as add, so a delete for an unprovisioned IP is
    // rejected instead of issuing a PATCH that would 404.
    #[test]
    fn validate_ptr_ip_maps_or_rejects() {
        assert_eq!(
            validate_ptr_ip("10.1.2.3"),
            Some((
                "10.in-addr.arpa".to_string(),
                "3.2.1.10.in-addr.arpa.".to_string()
            ))
        );
        assert_eq!(validate_ptr_ip("203.0.113.1"), None);
    }

    // #1077: the generated reverse-zone list must be exactly the 18 IPv4
    // private zones PowerDNS provisions (10, 168.192, and 16..=31.172), so the
    // display view GETs the right zones and never an unprovisioned one.
    #[test]
    fn provisioned_reverse_zones_match_the_18_ipv4_zones() {
        let zones = provisioned_ipv4_reverse_zones();
        assert_eq!(zones.len(), 18);
        assert!(zones.contains(&"10.in-addr.arpa".to_string()));
        assert!(zones.contains(&"168.192.in-addr.arpa".to_string()));
        assert!(zones.contains(&"16.172.in-addr.arpa".to_string()));
        assert!(zones.contains(&"31.172.in-addr.arpa".to_string()));
        assert!(!zones.contains(&"15.172.in-addr.arpa".to_string()));
        assert!(!zones.contains(&"32.172.in-addr.arpa".to_string()));
    }

    // #1077: the display parser must turn a real PowerDNS zone export into IP
    // rows -- keeping PTR rrsets, resolving the reversed name back to an IP,
    // and skipping non-PTR rrsets (SOA/NS), disabled records, and any name that
    // is not a four-label IPv4 in-addr.arpa name -- so the table shows exactly
    // the reverse mappings and nothing malformed.
    #[test]
    fn parse_ptr_views_extracts_only_valid_ptr_rows() {
        let rrsets = json!([
            {"name": "50.1.168.192.in-addr.arpa.", "type": "PTR", "ttl": 300,
             "records": [{"content": "printer.lan.", "disabled": false}]},
            {"name": "168.192.in-addr.arpa.", "type": "SOA", "ttl": 3600,
             "records": [{"content": "ns.lan. admin.lan. 1 2 3 4 5", "disabled": false}]},
            {"name": "9.1.168.192.in-addr.arpa.", "type": "PTR", "ttl": 60,
             "records": [{"content": "old.lan.", "disabled": true}]}
        ]);
        let views = parse_ptr_views(&rrsets);
        assert_eq!(views.len(), 1, "only the enabled PTR rrset is kept");
        assert_eq!(views[0].ip, "192.168.1.50");
        assert_eq!(views[0].hostname, "printer.lan.");
        assert_eq!(views[0].ttl, 300);
    }
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

    // Bare-TLD regression guard (#1068 item 17): confirms parse_domain_entry
    // already correctly rejects a single-label entry like "com" (with or
    // without the leading-dot wildcard marker) before add_dns ever runs --
    // the reported bug was never server-side validation accepting a bare
    // TLD, it was the Admin UI's plain-HTML-form POST surfacing that
    // (correct) rejection as a raw, unstyled browser-level HTTP 400 instead
    // of an in-app error. See add_dns's own redirect-with-error-code fix and
    // domains_page_error_message below for the UX half of this fix.
    #[test]
    fn rejects_bare_top_level_domain() {
        assert!(!is_valid_domain("com"));
        assert!(!is_valid_domain(".com"));
        assert!(parse_domain_entry("com").is_none());
        assert!(parse_domain_entry(".com").is_none());
    }

    // domains_page_error_message must only ever return one of the fixed,
    // reviewed strings for a known code, and None for anything else --
    // guarding against a future change accidentally reflecting the raw query
    // parameter value back into the page (see the function's own doc
    // comment for why that would be an XSS/hygiene concern).
    #[test]
    fn domains_page_error_message_only_recognizes_known_codes() {
        assert_eq!(
            domains_page_error_message("invalid_domain"),
            Some(
                "That domain was not added: CDN entries need a real domain name, not just a bare \
                 top-level domain (e.g. \"steamcontent.com\", not \"com\"). A leading \".\" for a \
                 wildcard/subdomain-only scope is fine (e.g. \".steamcontent.com\")."
            )
        );
        assert_eq!(domains_page_error_message("unknown_code"), None);
        assert_eq!(domains_page_error_message(""), None);
        assert_eq!(
            domains_page_error_message("<script>alert(1)</script>"),
            None
        );
    }

    // Cross-language parity guard (issue #822 pattern audit): this
    // validator's bash counterpart (_is_valid_domain in
    // scripts/lib/domain-validation.sh, embedded byte-identically into
    // services/proxy/entrypoint.sh and services/dns/entrypoint.sh) is a
    // fully independent implementation, with nothing enforcing the two
    // agree. Both this test and
    // tests/bats/domain_validation_parity.bats's "bash _is_valid_domain
    // agrees with the shared parity fixture on every case" iterate the same
    // shared fixture file, so a change to either validator that silently
    // starts disagreeing with the other fails one of the two test suites
    // instead of shipping unnoticed.
    //
    // Dynamically generated length-boundary cases (a 64-char label, a
    // >253-char total domain) are intentionally not in the shared fixture --
    // they can't be expressed as static fixture lines -- and stay covered
    // separately by accepts_domain_entries_with_optional_wildcard_marker
    // above and the bash side's tests/bats/proxy_cert_generation.bats.
    #[test]
    fn is_valid_domain_matches_shared_parity_fixture() {
        // Runtime fs::read_to_string via CARGO_MANIFEST_DIR (this crate's
        // own established pattern, see main.rs's TEMPLATE_DIR test setup),
        // not include_str!: the fixture lives outside this crate's source
        // tree (tests/fixtures/ at the repo root, shared with the bash
        // side), so a compile-time embed would bake an out-of-crate path
        // into the build; a runtime read gives a clear "fixture missing"
        // failure instead.
        let fixture_path = format!(
            "{}/../../tests/fixtures/domain-validation-cases.txt",
            env!("CARGO_MANIFEST_DIR")
        );
        let contents = std::fs::read_to_string(&fixture_path)
            .unwrap_or_else(|e| panic!("could not read shared parity fixture {fixture_path}: {e}"));

        let mut total = 0usize;
        let mut mismatches: Vec<String> = Vec::new();

        for line in contents.lines() {
            // Same skip rule as the bash reader's
            // `[[ -z "$line" || "$line" == \#* ]]`: blank lines and comment
            // lines are not cases. This must match the bash side's skip
            // logic exactly, or the two readers would silently disagree on
            // which lines even count as fixture cases.
            let line = line.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            let Some((expect, domain)) = line.split_once(' ') else {
                panic!("malformed shared parity fixture line (expected \"valid|invalid <domain>\"): {line:?}");
            };
            total += 1;

            let actual = if is_valid_domain(domain) {
                "valid"
            } else {
                "invalid"
            };
            if actual != expect {
                mismatches.push(format!("'{domain}' expected={expect} actual={actual}"));
            }
        }

        // Fail closed if the fixture itself is empty/unreadable-but-present
        // (e.g. header-only) -- a vacuous loop would make this test pass
        // without checking anything.
        assert!(total > 0, "shared parity fixture had zero usable cases");
        assert!(
            mismatches.is_empty(),
            "{} of {total} shared parity fixture case(s) disagreed with the Rust validator:\n{}",
            mismatches.len(),
            mismatches.join("\n")
        );
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
    fn split_lines_preserve_terminators_keeps_each_lines_own_ending() {
        // Directly exercises the pure splitting helper with every terminator
        // shape remove_domain must round-trip: CRLF, LF, and a final line
        // with no trailing newline at all.
        let content = "a\r\nb\nc";
        assert_eq!(
            split_lines_preserve_terminators(content),
            vec![("a", "\r\n"), ("b", "\n"), ("c", "")]
        );

        // Trailing newline on the last line must also be preserved, not lost.
        let content_trailing_nl = "a\nb\n";
        assert_eq!(
            split_lines_preserve_terminators(content_trailing_nl),
            vec![("a", "\n"), ("b", "\n")]
        );

        assert_eq!(
            split_lines_preserve_terminators(""),
            Vec::<(&str, &str)>::new()
        );
    }

    #[test]
    fn remove_domain_preserves_each_surviving_lines_own_terminator_on_mixed_endings() {
        // Reproduces #656: a CRLF header/comment followed by LF domain
        // entries plus one CRLF domain entry (the realistic "hand-edited on
        // Windows, then appended to from Linux/the container" scenario).
        // Removing one LF entry must not rewrite the OTHER surviving LF/CRLF
        // lines to match a single globally-chosen separator.
        let base = std::env::temp_dir().join(format!(
            "lancache-domains-mixed-endings-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        let mixed = "# comment\r\nexample.com\nsteamcontent.com\r\nkeep-lf.example.com\n";
        fs::write(&file, mixed.as_bytes()).unwrap();

        remove_domain(
            file.to_str().unwrap(),
            &DomainDeleteTarget::Canonical(domain_spec("example.com", false)),
        )
        .unwrap();

        let after_remove = fs::read_to_string(&file).unwrap();
        // Exact byte-for-byte expectation: only the matched line is gone,
        // every surviving line keeps its OWN original terminator (CRLF
        // header, CRLF domain entry, LF domain entry) -- none of them get
        // normalized to whatever separator the old single-`sep` logic would
        // have picked for the whole file.
        assert_eq!(
            after_remove,
            "# comment\r\nsteamcontent.com\r\nkeep-lf.example.com\n"
        );

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

    // add_dns/remove_dns must never log a failed CDN-file write and still
    // return the success redirect. dns_write_result_to_response is the
    // exact mapping both handlers apply via `?`, so pinning its Ok/Err
    // behavior here covers that handler-level error mapping without needing
    // a fully wired AppState (Docker/NATS/SQLite), which no other route test
    // in this file constructs either.
    #[test]
    fn dns_write_result_to_response_reports_ok_on_success() {
        assert_eq!(dns_write_result_to_response(Ok(()), "write"), Ok(()));
    }

    #[test]
    fn dns_write_result_to_response_reports_500_on_failure() {
        let err = anyhow::anyhow!("disk full");
        assert_eq!(
            dns_write_result_to_response(Err(err), "write"),
            Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
        );
    }

    #[test]
    fn add_dns_write_failure_maps_to_error_not_success() {
        // Reproduces the real failure add_dns feeds through
        // dns_write_result_to_response: append_domain errors when its
        // target's parent directory does not exist (the temp-file it writes
        // before renaming has nowhere to land).
        let base = temp_dir("add-dns-missing-parent");
        let file = base.join("missing-subdir").join("cdn-domains.txt");
        let domain = domain_spec("steamcontent.com", false);

        let wrote = append_domain(file.to_str().unwrap(), &domain);
        assert!(wrote.is_err());
        assert_eq!(
            dns_write_result_to_response(wrote, "write"),
            Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
        );
    }

    // Success-path counterpart to add_dns_write_failure_maps_to_error_not_success:
    // guards that dns_write_result_to_response's error mapping never turns a
    // genuinely successful write into a false failure.
    #[test]
    fn add_dns_write_success_maps_to_ok() {
        let base = temp_dir("add-dns-success");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        let domain = domain_spec("steamcontent.com", false);

        let wrote = append_domain(file.to_str().unwrap(), &domain);
        assert!(wrote.is_ok());
        assert_eq!(dns_write_result_to_response(wrote, "write"), Ok(()));

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn remove_dns_write_failure_maps_to_error_not_success() {
        // remove_domain's first step reads the CDN file; a missing file (the
        // same class of on-disk problem the write-side test above covers)
        // fails immediately.
        let base = temp_dir("remove-dns-missing-file");
        let file = base.join("cdn-domains.txt");
        let target = DomainDeleteTarget::Canonical(domain_spec("steamcontent.com", false));

        let removed = remove_domain(file.to_str().unwrap(), &target);
        assert!(removed.is_err());
        assert_eq!(
            dns_write_result_to_response(removed, "remove"),
            Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
        );
    }

    // Success-path counterpart to remove_dns_write_failure_maps_to_error_not_success:
    // guards that dns_write_result_to_response's error mapping never turns a
    // genuinely successful removal into a false failure.
    #[test]
    fn remove_dns_write_success_maps_to_ok() {
        let base = temp_dir("remove-dns-success");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\n").unwrap();
        let target = DomainDeleteTarget::Canonical(domain_spec("steamcontent.com", false));

        let removed = remove_domain(file.to_str().unwrap(), &target);
        assert!(removed.is_ok());
        assert_eq!(dns_write_result_to_response(removed, "remove"), Ok(()));

        fs::remove_dir_all(&base).unwrap();
    }

    // ── #1073: enabled/disabled default-CDN entries ─────────────────────

    #[test]
    fn parse_stored_domain_line_recognizes_disabled_marker_on_root_and_wildcard_entries() {
        assert_eq!(
            parse_stored_domain_line("steamcontent.com"),
            Some(StoredDomainLine {
                spec: domain_spec("steamcontent.com", false),
                enabled: true,
            })
        );
        assert_eq!(
            parse_stored_domain_line("!steamcontent.com"),
            Some(StoredDomainLine {
                spec: domain_spec("steamcontent.com", false),
                enabled: false,
            })
        );
        assert_eq!(
            parse_stored_domain_line(".steamcontent.com"),
            Some(StoredDomainLine {
                spec: domain_spec("steamcontent.com", true),
                enabled: true,
            })
        );
        assert_eq!(
            parse_stored_domain_line("!.steamcontent.com"),
            Some(StoredDomainLine {
                spec: domain_spec("steamcontent.com", true),
                enabled: false,
            })
        );
        // A bare "!" with nothing after it, or "!" wrapping a malformed
        // domain, must not parse -- same strictness as parse_domain_entry.
        assert_eq!(parse_stored_domain_line("!"), None);
        assert_eq!(parse_stored_domain_line("!localhost"), None);
    }

    #[test]
    fn stored_line_to_storage_round_trips_through_parse_stored_domain_line() {
        for (spec, enabled) in [
            (domain_spec("steamcontent.com", false), true),
            (domain_spec("steamcontent.com", false), false),
            (domain_spec("steamcontent.com", true), true),
            (domain_spec("steamcontent.com", true), false),
        ] {
            let entry = StoredDomainLine {
                spec: spec.clone(),
                enabled,
            };
            let text = stored_line_to_storage(&entry);
            assert_eq!(parse_stored_domain_line(&text), Some(entry));
        }
    }

    #[test]
    fn read_domain_entries_classifies_default_vs_custom_and_enabled_state() {
        let base = temp_dir("read-domain-entries-classify");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(
            &file,
            format!(
                "# header comment\n\
                 steamcontent.com\n\
                 !disabled-default.example.com\n\
                 {marker}\n\
                 custom-added.example.com\n",
                marker = CUSTOM_DOMAINS_MARKER
            ),
        )
        .unwrap();

        let entries = read_domain_entries(file.to_str().unwrap());
        assert_eq!(entries.len(), 3);

        assert_eq!(entries[0].display, "steamcontent.com");
        assert!(entries[0].enabled);
        assert!(entries[0].is_default);
        assert!(entries[0].is_valid);

        assert_eq!(entries[1].display, "disabled-default.example.com");
        assert!(!entries[1].enabled);
        assert!(entries[1].is_default);
        assert!(entries[1].is_valid);
        // raw must keep the "!" verbatim -- it's the on-disk line, not the
        // display form.
        assert_eq!(entries[1].raw, "!disabled-default.example.com");

        assert_eq!(entries[2].display, "custom-added.example.com");
        assert!(entries[2].enabled);
        assert!(!entries[2].is_default);
        assert!(entries[2].is_valid);

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn read_domain_entries_treats_a_file_with_no_marker_as_entirely_default() {
        // Pre-migration files (and bare test fixtures elsewhere in this
        // suite) never had a custom-domains marker; every entry in them
        // must still classify as a default, matching how they all behaved
        // before #1073 introduced the split.
        let base = temp_dir("read-domain-entries-no-marker");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\nepicgames.com\n").unwrap();

        let entries = read_domain_entries(file.to_str().unwrap());
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().all(|entry| entry.is_default));
    }

    #[test]
    fn read_domain_entries_surfaces_malformed_lines_as_invalid_but_visible() {
        // Malformed/legacy entries must stay visible so an operator can
        // still remove them (see remove_domain_can_cleanup_malformed_
        // existing_entries), just without a toggle control.
        let base = temp_dir("read-domain-entries-malformed");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "bad..example.com\nsteamcontent.com\n").unwrap();

        let entries = read_domain_entries(file.to_str().unwrap());
        assert_eq!(entries.len(), 2);
        assert!(!entries[0].is_valid);
        assert_eq!(entries[0].display, "bad..example.com");
        assert!(entries[1].is_valid);

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn set_domain_enabled_disables_and_re_enables_a_default_entry() {
        let base = temp_dir("set-domain-enabled-toggle");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\nepicgames.com\n").unwrap();
        let target = domain_spec("steamcontent.com", false);

        set_domain_enabled(file.to_str().unwrap(), &target, false).unwrap();
        let after_disable = fs::read_to_string(&file).unwrap();
        assert_eq!(after_disable, "!steamcontent.com\nepicgames.com\n");

        set_domain_enabled(file.to_str().unwrap(), &target, true).unwrap();
        let after_enable = fs::read_to_string(&file).unwrap();
        assert_eq!(after_enable, "steamcontent.com\nepicgames.com\n");

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn set_domain_enabled_only_touches_the_matching_wildcard_scope() {
        // Root and wildcard-only entries for the same domain are independent
        // lines (see appending_root_and_wildcard_only_domains_keeps_semantics
        // above) -- disabling one must not affect the other.
        let base = temp_dir("set-domain-enabled-scope");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, ".steamcontent.com\nsteamcontent.com\n").unwrap();

        set_domain_enabled(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", true),
            false,
        )
        .unwrap();

        let after = fs::read_to_string(&file).unwrap();
        assert_eq!(after, "!.steamcontent.com\nsteamcontent.com\n");
    }

    #[test]
    fn set_domain_enabled_is_idempotent_and_does_not_rewrite_an_unchanged_file() {
        let base = temp_dir("set-domain-enabled-idempotent");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\n").unwrap();
        let target = domain_spec("steamcontent.com", false);

        // Already enabled; requesting "enabled=true" again must be a no-op,
        // not an error and not a spurious rewrite.
        set_domain_enabled(file.to_str().unwrap(), &target, true).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "steamcontent.com\n");
    }

    #[test]
    fn set_domain_enabled_preserves_mixed_line_terminators_on_untouched_lines() {
        // Same #656 concern remove_domain's own terminator test guards
        // against: rewriting one matched line must not normalize every
        // other surviving line to a single separator.
        let base = temp_dir("set-domain-enabled-mixed-endings");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        let mixed = "# comment\r\nsteamcontent.com\r\nepicgames.com\n";
        fs::write(&file, mixed.as_bytes()).unwrap();

        set_domain_enabled(
            file.to_str().unwrap(),
            &domain_spec("epicgames.com", false),
            false,
        )
        .unwrap();

        let after = fs::read_to_string(&file).unwrap();
        assert_eq!(after, "# comment\r\nsteamcontent.com\r\n!epicgames.com\n");
    }

    #[test]
    fn append_domain_re_enables_an_existing_disabled_entry_instead_of_duplicating_it() {
        let base = temp_dir("append-domain-re-enable-disabled");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "!steamcontent.com\nepicgames.com\n").unwrap();

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", false),
        )
        .unwrap();

        let after = fs::read_to_string(&file).unwrap();
        assert_eq!(after, "steamcontent.com\nepicgames.com\n");
        // Exactly one row for steamcontent.com, not a second appended line.
        assert_eq!(after.matches("steamcontent.com").count(), 1);

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn append_domain_is_still_a_no_op_for_an_already_enabled_entry() {
        let base = temp_dir("append-domain-already-enabled-noop");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\n").unwrap();

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("steamcontent.com", false),
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "steamcontent.com\n".to_string()
        );

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn append_domain_inserts_custom_domains_marker_when_missing_then_stays_idempotent() {
        let base = temp_dir("append-domain-marker-convergence");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\n").unwrap();

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("first-custom.example.com", false),
        )
        .unwrap();
        let after_first = fs::read_to_string(&file).unwrap();
        assert_eq!(after_first.matches(CUSTOM_DOMAINS_MARKER).count(), 1);
        assert!(after_first.contains("first-custom.example.com"));

        append_domain(
            file.to_str().unwrap(),
            &domain_spec("second-custom.example.com", false),
        )
        .unwrap();
        let after_second = fs::read_to_string(&file).unwrap();
        // The marker must never be duplicated by a repeated add -- otherwise
        // read_domain_entries' is_default flip would trigger more than once.
        assert_eq!(after_second.matches(CUSTOM_DOMAINS_MARKER).count(), 1);
        assert!(after_second.contains("first-custom.example.com"));
        assert!(after_second.contains("second-custom.example.com"));

        // Both newly-added entries must classify as custom, and the
        // pre-existing entry must stay default.
        let entries = read_domain_entries(file.to_str().unwrap());
        let default_domains: Vec<_> = entries
            .iter()
            .filter(|e| e.is_default)
            .map(|e| e.display.as_str())
            .collect();
        let custom_domains: Vec<_> = entries
            .iter()
            .filter(|e| !e.is_default)
            .map(|e| e.display.as_str())
            .collect();
        assert_eq!(default_domains, vec!["steamcontent.com"]);
        assert_eq!(
            custom_domains,
            vec!["first-custom.example.com", "second-custom.example.com"]
        );

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn toggle_domain_write_failure_maps_to_error_not_success() {
        // Reproduces the same class of failure add_dns/remove_dns already
        // guard against: set_domain_enabled errors when the file doesn't
        // exist at all.
        let base = temp_dir("toggle-domain-missing-file");
        let file = base.join("cdn-domains.txt");
        let target = domain_spec("steamcontent.com", false);

        let toggled = set_domain_enabled(file.to_str().unwrap(), &target, false);
        assert!(toggled.is_err());
        assert_eq!(
            dns_write_result_to_response(toggled, "toggle"),
            Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
        );
    }

    #[test]
    fn toggle_domain_write_success_maps_to_ok() {
        let base = temp_dir("toggle-domain-success");
        fs::create_dir_all(&base).unwrap();
        let file = base.join("cdn-domains.txt");
        fs::write(&file, "steamcontent.com\n").unwrap();
        let target = domain_spec("steamcontent.com", false);

        let toggled = set_domain_enabled(file.to_str().unwrap(), &target, false);
        assert!(toggled.is_ok());
        assert_eq!(dns_write_result_to_response(toggled, "toggle"), Ok(()));

        fs::remove_dir_all(&base).unwrap();
    }
}
