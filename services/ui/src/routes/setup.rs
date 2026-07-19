//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
//! First-run setup wizard displaying network configuration details, plus the
//! ongoing release-channel / scheduled-update settings control (#819).
//!
//! Unlike DHCP mode (routes/dhcp.rs), saving here never touches Docker at
//! all: both settings are consumed entirely on the host, by setup.sh's
//! lancache-converge.service, which already runs every 5 minutes with full
//! systemctl authority and polls the same ui-data volume this write targets.
//! That's a deliberate, lower-risk alternative to giving this container a new
//! docker-socket-proxy path to manage a host systemd unit directly -- see the
//! #819 issue thread for the full reasoning. Saving here therefore only ever
//! needs to persist a settings file; there is nothing to reconcile/roll back
//! synchronously the way update_dhcp_mode has to.

use crate::AppState;
use axum::extract::{Form, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use serde::Deserialize;
use std::sync::Arc;
use tera::Context;

pub async fn setup_page(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("standard_ip", &state.config.standard_ip);
    ctx.insert("ssl_ip", &state.config.ssl_ip);
    ctx.insert("dhcp_mode", &state.config.effective_dhcp_mode().as_str());
    ctx.insert(
        "lancache_image_channel",
        &state.config.effective_lancache_image_channel_override(),
    );
    ctx.insert(
        "auto_update_enabled",
        &state.config.effective_auto_update_enabled(),
    );
    ctx.insert("active_page", "setup");
    crate::routes::insert_csrf_token(&mut ctx, &headers);
    crate::routes::render(&state.templates, "setup.html", &ctx, state.config.dev_mode)
}

// ─── Error handling ───

// Deliberately separate from routes/dhcp.rs's DhcpError: that type's
// constructors are private to that module, and this handler's failure modes
// (bad channel input, an unwritable settings file) don't need DHCP's
// rollback-on-persist-failure machinery, since there is no Docker mutation
// here to roll back in the first place.
#[derive(Debug)]
pub struct SettingsError {
    status: StatusCode,
    message: String,
}

impl SettingsError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for SettingsError {}

impl IntoResponse for SettingsError {
    fn into_response(self) -> Response {
        let body = format!(
            "<!DOCTYPE html>\n<html>\n<head><title>Settings Error</title></head>\n\
             <body><h1>Settings Error</h1>\n<p>{}</p>\n\
             <p><a href=\"/setup\">Return to setup</a></p>\n</body>\n</html>",
            // No user input is ever interpolated into this body (both error
            // paths below use fixed messages), so this never needs to escape
            // untrusted content -- unlike routes/dhcp.rs's DhcpError, which
            // does define its own html_escape for exactly that reason.
            self.message
        );
        (self.status, Html(body)).into_response()
    }
}

#[derive(Deserialize)]
pub struct UpdateStackSettingsForm {
    pub csrf_token: String,
    pub lancache_image_channel: String,
    // Rendered from an HTML checkbox: present (any value) means checked,
    // absent means unchecked -- axum's Form extractor errors on a missing
    // field with no #[serde(default)], so this must default rather than be
    // required, same reasoning as UpdateDhcpProxyForm's optional fields in
    // routes/dhcp.rs.
    #[serde(default)]
    pub auto_update_enabled: String,
}

// Only the two end-user-facing channels from #819 are selectable here.
// "dev" is out of scope for this issue (split into #825), and "pinned" is
// never a channel an operator picks from this control -- it's what
// setup.sh's own resolve_lancache_image_channel() reports when
// LANCACHE_IMAGE_TAG is set to a fixed sha/version tag outside the channel
// system entirely, which this control does not touch.
fn is_valid_ui_channel(value: &str) -> bool {
    matches!(value, "stable" | "edge")
}

// Saves the release channel and scheduled-update settings to the same
// ui-data-backed settings file routes/dhcp.rs's persist_ui_settings writes,
// via the identical whitelisted-key/temp-file-then-rename mechanism (see
// write_ui_settings_file below). Every existing DHCP key already in that
// file must be re-included here (and, symmetrically, every key this handler
// introduces must be re-included in routes/dhcp.rs's own persist_ui_settings
// calls) -- the settings file is a single whole-file overwrite per save, not
// a per-key patch, so leaving a key out of any one save silently drops it
// back to its env default. See write_ui_settings_file's own comment for the
// authoritative whitelist this depends on.
pub async fn update_stack_settings(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<UpdateStackSettingsForm>,
) -> Result<Redirect, SettingsError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)
        .map_err(|status| SettingsError::new(status, "Invalid or missing CSRF token."))?;

    if !is_valid_ui_channel(&form.lancache_image_channel) {
        return Err(SettingsError::new(
            StatusCode::BAD_REQUEST,
            "Invalid release channel requested.",
        ));
    }
    let auto_update_enabled = !form.auto_update_enabled.trim().is_empty();

    crate::routes::dhcp::persist_stack_settings(
        &state,
        &form.lancache_image_channel,
        auto_update_enabled,
    )
    .map_err(|err| SettingsError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    Ok(Redirect::to("/setup"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_stable_and_edge_are_accepted() {
        assert!(is_valid_ui_channel("stable"));
        assert!(is_valid_ui_channel("edge"));
        assert!(!is_valid_ui_channel("dev"));
        assert!(!is_valid_ui_channel("pinned"));
        assert!(!is_valid_ui_channel("latest"));
        assert!(!is_valid_ui_channel(""));
        assert!(!is_valid_ui_channel("STABLE"));
    }
}
