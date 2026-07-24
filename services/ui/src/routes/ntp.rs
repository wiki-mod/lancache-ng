//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//!
//! Admin UI routes for LanCache-NG-NTP: enable/disable the chrony-based NTP
//! container, edit its upstream public NTP server list, and toggle whether
//! this container's LAN address is auto-populated into Kea's DHCP
//! ntp-servers option. The DHCP-side reconcile logic itself (pushing/
//! restoring the option across every Kea subnet) lives in routes/dhcp.rs
//! (apply_ntp_lan_ip_to_all_subnets/restore_default_ntp_on_all_subnets) --
//! this module only decides WHEN to call it, based on whether this save
//! actually changed the auto-populate state.

use crate::{docker_client, AppState};
use axum::extract::{Form, State};
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse, Redirect, Response};
use serde::Deserialize;
use std::sync::Arc;
use tera::Context;

// ─── Error handling ───
//
// Deliberately separate from routes/dhcp.rs's DhcpError (same reasoning as
// routes/setup.rs's own SettingsError): that type's constructors are private
// to routes/dhcp.rs, and this module's own failure modes (bad upstream
// server input, a settings-file write failure, a Docker start/stop failure)
// don't need DHCP's rollback-on-persist-failure machinery.
#[derive(Debug)]
pub struct NtpError {
    status: StatusCode,
    message: String,
}

impl NtpError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn config_error(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }
}

impl From<StatusCode> for NtpError {
    fn from(status: StatusCode) -> Self {
        Self::new(status, format!("HTTP {}", status.as_u16()))
    }
}

impl std::fmt::Display for NtpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for NtpError {}

impl IntoResponse for NtpError {
    fn into_response(self) -> Response {
        // Manual escaping, matching routes/dhcp.rs's DhcpError: this error's
        // message can include operator-supplied text (e.g. an invalid
        // upstream server entry echoed back), unlike routes/setup.rs's
        // SettingsError, which only ever uses fixed messages.
        let escaped = self
            .message
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&#39;");
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>NTP Configuration Error</title></head>\n\
             <body><h1>NTP Configuration Error</h1>\n<p>{escaped}</p>\n\
             <p><a href=\"/ntp\">Return to NTP settings</a></p>\n</body>\n</html>"
        );
        (self.status, Html(body)).into_response()
    }
}

// ─── Handlers ───

pub async fn ntp_page(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "ntp");
    ctx.insert("ntp_enabled", &state.config.effective_ntp_enabled());
    ctx.insert(
        "ntp_upstream_servers",
        &state.config.effective_ntp_upstream_servers(),
    );
    ctx.insert("ntp_auto_dhcp", &state.config.effective_ntp_auto_dhcp());
    ctx.insert("standard_ip", &state.config.standard_ip);
    ctx.insert("dhcp_has_kea", &state.config.effective_dhcp_mode().is_kea());
    crate::routes::insert_csrf_token(&mut ctx, &headers);
    crate::routes::render(&state.templates, "ntp.html", &ctx, state.config.dev_mode)
}

#[derive(Deserialize)]
pub struct UpdateNtpSettingsForm {
    pub csrf_token: String,
    // Rendered from HTML checkboxes: present (any value) means checked,
    // absent means unchecked -- axum's Form extractor errors on a missing
    // field with no #[serde(default)], same reasoning as
    // routes/dhcp.rs's UpdateDhcpProxyForm optional fields.
    #[serde(default)]
    pub ntp_enabled: String,
    pub ntp_upstream_servers: String,
    #[serde(default)]
    pub ntp_auto_dhcp: String,
}

// One upstream server entry is valid if it is either an IPv4 literal or a
// syntactically valid DNS hostname -- chrony accepts both (see
// services/ntp/entrypoint.sh's is_ip_literal classification, which this
// mirrors from the Admin UI side) and this project already has both
// validators in routes/dhcp.rs (parse_ipv4/is_valid_domain_name), reused
// here rather than duplicated. IPv6 literals are intentionally also
// accepted via a plain colon check, matching entrypoint.sh's own classifier,
// even though this project's DHCP/Kea side is IPv4-only -- chronyd itself
// is not.
fn is_valid_ntp_upstream_entry(entry: &str) -> bool {
    if entry.contains(':') {
        return true;
    }
    crate::routes::dhcp::parse_ipv4(entry).is_some()
        || crate::routes::dhcp::is_valid_domain_name(entry)
}

// Validates and normalizes the operator-submitted upstream server list
// (whitespace/comma-separated, matching entrypoint.sh's own parsing) into
// the space-separated form NTP_UPSTREAM_SERVERS/services/ntp/entrypoint.sh
// expect. Requirement 1 (see the issue this page was built for) requires at
// least one entry -- an empty list would let the container start with
// nothing to sync against (services/ntp/entrypoint.sh's own fail-closed
// check would then refuse to start chronyd entirely), so this is rejected
// here with a clear, immediate 400 instead of only surfacing as a crash-loop
// after the operator's save appears to succeed.
fn validate_ntp_upstream_servers(raw: &str) -> Result<String, String> {
    let entries: Vec<&str> = raw
        .split([',', ' ', '\n', '\t'])
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect();

    if entries.is_empty() {
        return Err(
            "At least one upstream NTP server is required; LanCache-NG-NTP never operates as a standalone time source.".to_string(),
        );
    }
    for entry in &entries {
        if !is_valid_ntp_upstream_entry(entry) {
            return Err(format!(
                "'{entry}' is not a valid IPv4/IPv6 address or hostname."
            ));
        }
    }

    Ok(entries.join(" "))
}

// Saves LanCache-NG-NTP's settings: starts/stops the container to match the
// enable/disable toggle, persists all three settings, and reconciles Kea's
// ntp-servers option across every subnet exactly when this save actually
// changes whether auto-populate is active -- never on a save that leaves it
// unchanged, so an operator's own per-subnet customization (set while
// auto-populate was off) is never touched by an unrelated settings save.
pub async fn update_ntp_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateNtpSettingsForm>,
) -> Result<Redirect, NtpError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token).map_err(NtpError::from)?;

    let ntp_enabled = !form.ntp_enabled.trim().is_empty();
    let ntp_auto_dhcp = !form.ntp_auto_dhcp.trim().is_empty();
    let ntp_upstream_servers = validate_ntp_upstream_servers(&form.ntp_upstream_servers)
        .map_err(|message| NtpError::new(StatusCode::BAD_REQUEST, message))?;

    // Captured before reconcile_ntp_container/persist below so the
    // auto-populate transition (see this handler's own doc comment) is
    // computed against the state this save is actually changing FROM, not
    // whatever the settings file already holds by the time the reconcile
    // call below runs.
    let was_auto_populating =
        state.config.effective_ntp_enabled() && state.config.effective_ntp_auto_dhcp();
    let will_auto_populate = ntp_enabled && ntp_auto_dhcp;

    reconcile_ntp_container(&state, ntp_enabled).await?;

    crate::routes::dhcp::persist_ntp_settings(
        &state,
        ntp_enabled,
        &ntp_upstream_servers,
        ntp_auto_dhcp,
    )
    .map_err(|err| NtpError::config_error(err.to_string()))?;

    if will_auto_populate {
        crate::routes::dhcp::apply_ntp_lan_ip_to_all_subnets(&state)
            .await
            .map_err(|err| NtpError::config_error(err.to_string()))?;
    } else if was_auto_populating {
        crate::routes::dhcp::restore_default_ntp_on_all_subnets(&state)
            .await
            .map_err(|err| NtpError::config_error(err.to_string()))?;
    }

    Ok(Redirect::to("/ntp"))
}

// Starts/stops the predeclared `ntp` Compose service to match the enable/
// disable toggle, mirroring routes/dhcp.rs's reconcile_dhcp_mode. A missing
// container (the `ntp` Compose profile was never activated, e.g. a fresh
// install that left LanCache-NG-NTP disabled at setup.sh time) surfaces as a
// visible operator error rather than silently diverging from the persisted
// toggle state -- same tradeoff reconcile_dhcp_mode already accepts for
// `dhcp`/`dhcp-proxy`.
async fn reconcile_ntp_container(state: &AppState, ntp_enabled: bool) -> Result<(), NtpError> {
    if ntp_enabled {
        docker_client::start_service(&state.docker, "ntp")
            .await
            .map_err(|err| NtpError::config_error(err.to_string()))?;
    } else {
        docker_client::stop_service_if_present(&state.docker, "ntp")
            .await
            .map_err(|err| NtpError::config_error(err.to_string()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Requirement 1: an empty upstream list must be rejected here, not just
    // left to services/ntp/entrypoint.sh's own fail-closed check to catch
    // after the container is already restarting.
    #[test]
    fn validate_ntp_upstream_servers_rejects_empty_input() {
        assert!(validate_ntp_upstream_servers("").is_err());
        assert!(validate_ntp_upstream_servers("   ").is_err());
        assert!(validate_ntp_upstream_servers(",, ,").is_err());
    }

    // Mirrors services/ntp/entrypoint.sh's own accepted separators (spaces
    // and commas) plus newlines/tabs a textarea submission could carry.
    #[test]
    fn validate_ntp_upstream_servers_normalizes_separators_to_spaces() {
        let result =
            validate_ntp_upstream_servers("0.debian.pool.ntp.org, time.cloudflare.com\n192.0.2.1")
                .expect("valid input must be accepted");
        assert_eq!(
            result,
            "0.debian.pool.ntp.org time.cloudflare.com 192.0.2.1"
        );
    }

    // A malformed entry must be rejected with a message naming the entry,
    // not silently dropped or passed through to chronyd unresolved.
    #[test]
    fn validate_ntp_upstream_servers_rejects_malformed_entry() {
        let err = validate_ntp_upstream_servers("not a valid host!!")
            .expect_err("malformed entry must be rejected");
        assert!(err.contains("not"));
    }

    // IPv6 literals are accepted even though this project's DHCP/Kea side is
    // IPv4-only -- chronyd itself is not, and entrypoint.sh's own classifier
    // treats any colon-containing entry as a literal.
    #[test]
    fn validate_ntp_upstream_servers_accepts_ipv6_literal() {
        assert!(validate_ntp_upstream_servers("2606:4700:f1::1").is_ok());
    }
}
