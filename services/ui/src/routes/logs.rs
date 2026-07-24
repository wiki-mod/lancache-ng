//! lancache-ng (https://github.com/wiki-mod/lancache-ng)
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
use axum::response::Html;
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
    Query(params): Query<LogFilter>,
) -> Html<String> {
    let mut ctx = Context::new();
    ctx.insert("active_page", "logs");

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
        // Split the budget across both sources so the combined, reversed,
        // truncated result below still tops out at max_entries overall.
        let per_source = max_entries / 2;
        let (standard_logs, ssl_logs) = tokio::join!(
            tokio::task::spawn_blocking({
                let p = state.config.standard_log.clone();
                move || nginx_client::parse_log_tail(&p, per_source)
            }),
            tokio::task::spawn_blocking({
                let p = state.config.ssl_log.clone();
                move || nginx_client::parse_log_tail(&p, per_source)
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

        standard_logs.into_iter().chain(ssl_logs).collect()
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
