//!
//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)
//! SPDX-License-Identifier: AGPL-3.0-or-later
//! Route for viewing and filtering logs: the nginx access-log tail by
//! default, or -- once an install opts into `docker compose --profile
//! logging` (SYSLOG_ENABLED=true) -- the central syslog-ng store instead
//! (#633 PR4). The two sources are mutually exclusive per request, not
//! merged: syslog-ng's own `logging` profile forwards proxy/nginx traffic
//! alongside every other wired service (PR2/#756), so once enabled it is
//! the more complete view and the direct-nginx-read path is left untouched
//! for installs that never opt in.

use crate::{AppState, nginx_client, syslog_client};
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use serde::Deserialize;
use std::sync::Arc;
use tera::Context;

#[derive(Deserialize)]
pub struct LogFilter {
    // Cache-status filter (HIT/MISS/EXPIRED/...), consumed only by the
    // nginx-log branch below. Left as a distinct field from `host` (rather
    // than reusing one name for both modes' filters) because the two mean
    // different things -- a bookmarked/shared `?filter=HIT` URL would be
    // silently reinterpreted as a (nonexistent) host named "HIT" if syslog
    // mode were later enabled on the same install, and vice versa.
    pub filter: Option<String>,
    // Host filter, consumed only by the syslog-mode branch below (#848):
    // restricts parse_syslog_tail to one wired host's subdirectory instead
    // of merging every host under SYSLOG_LOG_ROOT.
    pub host: Option<String>,
}

pub async fn logs_page(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(params): Query<LogFilter>,
) -> impl IntoResponse {
    let mut ctx = Context::new();
    ctx.insert("active_page", "logs");
    // What: makes the beambar's restart-ui form's token valid here
    // Why: base.html now renders that form on every page (was dashboard-only)
    // From: Issue #1437
    crate::routes::insert_csrf_token(&mut ctx, &headers);

    let max_entries = state.config.ui_logs_max_entries;

    if state.config.syslog_enabled {
        let log_root = state.config.syslog_log_root.clone();
        let requested_host = params.host.filter(|h| !h.is_empty());
        let (mut syslog_logs, syslog_hosts, selected_host) = {
            let log_root = log_root.clone();
            tokio::task::spawn_blocking(move || {
                // Always list every wired host (not just the selected one),
                // otherwise the dropdown below would shrink to a single
                // option after the first filtered request.
                let hosts = syslog_client::list_syslog_hosts(&log_root);
                // `?host=` is caller-controlled (HTTP query parameter), so
                // only ever honor a value that is actually one of the real,
                // known host directories -- parse_syslog_tail itself also
                // rejects a traversal-shaped host defensively, but this
                // allowlist check is what keeps an unrecognized/typo'd host
                // silently falling back to "all hosts" instead of a
                // confusing empty result.
                let selected = requested_host.filter(|h| hosts.contains(h));
                let entries =
                    syslog_client::parse_syslog_tail(&log_root, selected.as_deref(), max_entries);
                (entries, hosts, selected)
            })
            .await
            .unwrap_or_default()
        };

        // Show most recent first, matching the nginx branch below.
        syslog_logs.reverse();

        ctx.insert("syslog_mode", &true);
        ctx.insert("syslog_logs", &syslog_logs);
        ctx.insert("syslog_hosts", &syslog_hosts);
        ctx.insert("selected_host", &selected_host);
        // Tera errors on an undefined variable, so both branches must
        // populate every key the template reads regardless of which one
        // renders -- `logs` is only read by the nginx branch of logs.html,
        // but must still exist here.
        ctx.insert("logs", &Vec::<nginx_client::LogEntry>::new());
        return crate::routes::render(&state.templates, "logs.html", &ctx, state.config.dev_mode);
    }

    let mut all_logs = if state.config.standard_log == state.config.ssl_log {
        let mut shared_logs = tokio::task::spawn_blocking({
            let path = state.config.standard_log.clone();
            move || nginx_client::parse_log_tail(&path, max_entries)
        })
        .await
        .unwrap_or_default();

        for entry in &mut shared_logs {
            entry.source = "Shared".to_string();
        }

        shared_logs
    } else {
        // Each source is read up to the FULL max_entries budget, not a
        // pre-split half of it -- the combined, reversed, truncated result
        // below is what actually enforces the max_entries cap. Splitting the
        // budget up front (e.g. max_entries / 2 per source) would silently
        // drop entries whenever one source supplies more than half of the
        // globally newest requests: with a limit of 200 and the newest 200
        // requests all in one source, a half-each cap would only load 100 of
        // them and show up to 100 older entries from the other source
        // instead. Matches the same shape routes/dashboard.rs's
        // merge_recent_logs already uses for the same reason.
        let (standard_logs, ssl_logs) = tokio::join!(
            tokio::task::spawn_blocking({
                let p = state.config.standard_log.clone();
                move || nginx_client::parse_log_tail(&p, max_entries)
            }),
            tokio::task::spawn_blocking({
                let p = state.config.ssl_log.clone();
                move || nginx_client::parse_log_tail(&p, max_entries)
            }),
        );

        let mut standard_logs = standard_logs.unwrap_or_default();
        for entry in &mut standard_logs {
            entry.source = "Standard".to_string();
        }

        let mut ssl_logs = ssl_logs.unwrap_or_default();
        for entry in &mut ssl_logs {
            entry.source = "SSL".to_string();
        }

        // A plain `.chain()` would put every Standard entry before every
        // SSL entry (or vice versa, depending on iteration order) regardless of their
        // real timestamps -- after the `.reverse()` below, that means one
        // source's entire block always displayed before the other's,
        // rather than the two interleaving by actual recency. Both inputs
        // are already individually chronological (parse_log_tail's own
        // contract); merging by parsed timestamp preserves each source's
        // internal order while interleaving the two sources by recency.
        nginx_client::merge_log_entries_chronologically(standard_logs, ssl_logs)
    };

    // Show most recent first
    all_logs.reverse();
    all_logs.truncate(max_entries);

    // Apply cache status filter if provided
    if let Some(filter) = &params.filter {
        all_logs.retain(|entry| &entry.cache_status == filter);
    }

    ctx.insert("syslog_mode", &false);
    ctx.insert("logs", &all_logs);
    crate::routes::render(&state.templates, "logs.html", &ctx, state.config.dev_mode)
}
