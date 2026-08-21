//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! First-run setup wizard displaying network configuration details, the
//! ongoing release-channel / scheduled-update settings control (#819), and
//! the Admin UI's own self-restart control (#1486).
//!
//! Unlike DHCP mode (routes/dhcp.rs), the release-channel/auto-update save
//! never touches Docker at all: both settings are consumed entirely on the
//! host, by setup.sh's lancache-converge.service, which already runs every 5
//! minutes with full systemctl authority and polls the same ui-data volume
//! this write targets. That's a deliberate, lower-risk alternative to giving
//! this container a new docker-socket-proxy path to manage a host systemd
//! unit directly -- see the #819 issue thread for the full reasoning. Saving
//! here therefore only ever needs to persist a settings file; there is
//! nothing to reconcile/roll back synchronously the way update_dhcp_mode has
//! to. restart_ui_service below is the one handler in this file that DOES
//! touch Docker -- see its own doc comment.

use crate::{AppState, docker_client};
use axum::extract::{Form, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use serde::Deserialize;
use std::sync::Arc;
use tera::Context;

pub async fn setup_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let mut ctx = Context::new();
    ctx.insert("standard_ip", &state.config.standard_ip);
    ctx.insert("ssl_ip", &state.config.ssl_ip);
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
            // There are three SettingsError::new(...) construction sites in
            // update_stack_settings below (a CSRF failure, an
            // invalid-channel rejection, and a settings-persist failure),
            // and the third one is not a fixed string at all -- it
            // formats `err.to_string()` from persist_stack_settings'
            // Result::Err. That value is still safe to leave unescaped today
            // (it's an io::Error-derived message describing a local file-write
            // failure, never anything built from this form's own
            // attacker-controlled fields), but "no user input is ever
            // interpolated" overstated the actual guarantee -- the real
            // invariant this body relies on is "every message reaching here is
            // either a fixed literal or a value with no attacker-controlled
            // content," not "always a fixed literal." A future fourth error
            // path that ever does interpolate request-derived text into this
            // struct's `message` field would need routes/dhcp.rs's DhcpError
            // html_escape treatment, not this file's current bare interpolation.
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
    matches!(value, "stable" | "nightly")
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

#[derive(Deserialize)]
pub struct RestartUiServiceForm {
    pub csrf_token: String,
}

// The page served in place of a redirect after a self-restart request: the
// browser cannot follow a normal redirect here, since the process serving it
// is about to disappear. Poll /health (this service's own unauthenticated
// liveness probe, see main.rs) until it responds, then navigate to /setup --
// the same bounded-handoff shape the maintainer decided on for issue #1486.
// The first poll attempt is deliberately delayed so the operator sees this
// page for a moment rather than an instant flash if the still-running old
// process happens to answer /health before the restart below has landed.
const RESTART_UI_PAGE: &str = r##"<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Admin-UI wird neu gestartet</title>
<style>
  body { background:#0f172a; color:#e2e8f0; font-family: system-ui, sans-serif;
         display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
  .box { text-align:center; max-width: 28rem; padding: 2rem; }
  .spinner { width:2rem; height:2rem; border:3px solid #334155; border-top-color:#3b82f6;
             border-radius:50%; margin:0 auto 1rem; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  h1 { font-size:1.125rem; font-weight:600; margin:0 0 0.5rem; }
  p { font-size: 0.875rem; color:#94a3b8; margin:0; }
</style>
</head>
<body>
<div class="box">
  <div class="spinner"></div>
  <h1>Admin-UI wird neu gestartet&hellip;</h1>
  <p>Diese Seite leitet automatisch weiter, sobald die Admin-UI wieder erreichbar ist.</p>
</div>
<script>
// What: only treats a 200 as recovery once a prior poll has already
//   observed the instance down (non-ok or unreachable).
// Why: a 200 alone does not prove the restart happened -- the old process
//   may still answer /health if the restart was rejected or hasn't stopped it.
// From: Codex review on PR #1610
var sawDown = false;
function pollHealth() {
  fetch('/health', { cache: 'no-store' }).then(function (res) {
    if (res.ok && sawDown) { window.location.href = '/setup'; return; }
    sawDown = sawDown || !res.ok;
    setTimeout(pollHealth, 1000);
  }).catch(function () { sawDown = true; setTimeout(pollHealth, 1000); });
}
setTimeout(pollHealth, 1500);
</script>
</body>
</html>
"##;

// What: validates the request, hands back the bounded-handoff page, then
//   restarts `ui` from a detached background task.
// Why: this process is about to be killed by its own restart, so the restart
//   must run out-of-line, or the response could never be sent at all.
// From: Issue #1486
pub async fn restart_ui_service(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<RestartUiServiceForm>,
) -> Result<Html<&'static str>, SettingsError> {
    crate::routes::verify_csrf_token(&headers, &form.csrf_token)
        .map_err(|status| SettingsError::new(status, "Invalid or missing CSRF token."))?;

    let restart_state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(750)).await;
        if let Err(err) = docker_client::restart_service(
            &restart_state.docker,
            "ui",
            &restart_state.config.container_suffix,
        )
        .await
        {
            tracing::error!(
                error = %err,
                "operator-requested Admin UI self-restart failed"
            );
        }
    });

    Ok(Html(RESTART_UI_PAGE))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The two end-user-facing channels are "stable" and "nightly". "edge" was
    // the old name of "nightly" (renamed and hard-cut in v0.3.0, #1056) and is
    // explicitly rejected now, not accepted as a synonym, so a stale pre-rename
    // form submission gets a clean 400 rather than silently selecting nightly.
    #[test]
    fn only_stable_and_nightly_are_accepted() {
        assert!(is_valid_ui_channel("stable"));
        assert!(is_valid_ui_channel("nightly"));
        assert!(!is_valid_ui_channel("edge"));
        assert!(!is_valid_ui_channel("dev"));
        assert!(!is_valid_ui_channel("pinned"));
        assert!(!is_valid_ui_channel("latest"));
        assert!(!is_valid_ui_channel(""));
        assert!(!is_valid_ui_channel("STABLE"));
    }
}
